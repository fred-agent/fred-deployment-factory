---
name: fred-memory-diagnostics
description: Diagnose a suspected memory leak or unexplained RSS growth in any live Fred component (control-plane, fred-agents, knowledge-flow API/worker, or a third-party agent pod on fred-runtime), on any platform (docker-compose, k3d, GKE/fredlab). Use when memory is climbing, a pod keeps getting evicted/OOMKilled, or you need to tell "real Python leak" apart from "allocator/scheduling artifact" before proposing a fix.
user-invocable: true
argument-hint: [component name, e.g. knowledge-flow-worker]
---

# Fred memory diagnostics (`fred_core.diagnostics`)

Not a read-only skill like `fredlab-observability` — it deliberately sends a signal to a live
process (`SIGUSR1`/`SIGUSR2`) to force `gc.collect()` and log a report. That's benign (no
persisted state changes, idempotent, safe to run repeatedly) but it's a real action on a real
process, so treat it with the same care as any other live-process command, not as pure
observation. Platform-agnostic on purpose: the technique is identical on docker-compose, k3d, and
GKE — only the "get a shell in the container" command differs (see below). Born from a real,
day-long investigation on fredlab 2026-07-31/08-01 (ISSUE-006 through 010,
`ThalesGroup/fred#2188`/`#2198`) — read those for the full worked example if you want the reasoning
behind every step here, not just the recipe.

## Step 0 — does this component even have it wired in?

`fred_core.diagnostics.install_gc_diagnostics()` must have been called at startup for any of this
to work. As of this writing it's wired into:

- `knowledge_flow_backend/main_worker.py` and `main.py` (worker + API)
- `control_plane_backend/main.py` and `main_worker.py` (API + worker)
- `fred_runtime/app/agent_app.py`'s `create_agent_app()` lifespan — so **every** agent pod built
  on fred-runtime gets it automatically, including third-party pods, with zero code on their side

If unsure, `grep -rn "install_gc_diagnostics" <component>/` in the `fred` monorepo before assuming
the signals will do anything. No handler installed → `kill -USR1`/`-USR2` just does nothing (no
crash, no log line — don't mistake silence for "nothing to report").

## Step 1 — get a shell into the pod/container

| Platform | Command |
|---|---|
| GKE (fredlab) | `kubectl -n fred-demo exec <pod> -- kill -USR1 1` (namespace is `fred-demo`, not `default`) |
| k3d | `kubectl -n <namespace> exec <pod> -- kill -USR1 1` — same as GKE, just a different context/namespace |
| docker-compose (local) | `docker exec <container> kill -USR1 1` |

`1` is the PID to signal because these are single-process containers (PID 1 is the Python
interpreter itself) — don't go looking for the "real" PID.

## Step 2 — trigger, from lightest to heaviest

1. **`kill -USR1 1`** — `collect_and_trim()`: one forced `gc.collect()` + `malloc_trim(0)`, logs
   `[GC][SIGUSR1] collected=N uncollectable=N trimmed=bool RSS beforeKi -> afterKi (delta)`. Cheap,
   safe to run as often as you want. Start here.
2. **`kill -USR2 1`** — runs `collect_and_trim`'s heavier sibling `collect_and_report_types()`
   (same idea, but reports which object *types* make up the collected cyclic garbage — this is
   what found ISSUE-010's `ValidatorIterator` cycle) **and** `live_object_census()` back to back
   (added in `#2198`) — a full census of every object the GC currently tracks (not just garbage),
   top types by count and by shallow size. Two log lines: `[GC][types] ...` then
   `[GC][census] ...`. Heavier (walks the whole live object graph) but still safe.
3. If `KF_WORKER_GC_INTERVAL_SEC` (or the shared `FRED_GC_DIAGNOSTICS_INTERVAL_SEC`) is set on the
   component, `[GC][periodic] ...` lines already fire on their own on that interval — check
   existing logs before manually triggering anything:
   `kubectl -n fred-demo logs <pod> --since=1h | grep '\[GC\]'`.

## Step 3 — read the numbers, in order

1. **`collected` / `uncollectable`** (every `[GC]` line). `uncollectable > 0` is the one truly
   alarming reading — it means something with a `__del__` is stuck in a cycle Python refuses to
   even try to free; everything seen live on fredlab so far has been `uncollectable=0` (real cyclic
   garbage, genuinely freed, not a hard leak). `collected` scales with recent activity (documents
   processed, requests served) — a big number right after a batch is normal; what matters is
   whether it goes back down near a small, stable floor once idle (see step 4).
2. **`[GC][types] top_types`** — only meaningful if `collected` was non-trivial. Look for anything
   that's clearly *application* data (a Fred model class, not `tuple`/`dict`/`CDLL`-type
   ctypes/stdlib noise) repeating in proportion to load — that's the "which class is cycling"
   signal that cracked ISSUE-010.
3. **`[GC][census] total_objects` / `total_bytes_shallow` / `top_by_count` / `top_by_size`** —
   answers a *different* question than 1-2: not "what's uncollected garbage" but "what's reachable
   and heavy right now", including memory nothing is wrong with (still legitimately in use).
   **Caveat that matters**: sizes are shallow (`sys.getsizeof()`) — a `dict` holding huge values
   looks small; the values show up under their own type instead. `top_by_count` is usually more
   telling than `top_by_size` for that reason. Also: `gc.get_objects()` only tracks
   container-shaped objects (anything that could join a cycle) — plain `bytes`/`str`/most raw
   buffers, and often native tensor storage, are invisible here even at gigabyte scale. If
   `total_bytes_shallow` is a small fraction of the process's real RSS, that's expected, not a bug
   in the tool.

## Step 4 — the actual decision tree

Trigger once mid/right-after load, then again once idle (CPU back near 0, ideally after the next
periodic cycle if one's configured) so you have a before/after to compare — a single reading tells
you much less than two.

- **`collected` returns to a small stable floor at idle, RSS baseline returns to the same value
  batch after batch** → healthy. Nothing to do.
- **`uncollectable > 0` at idle** → real hard leak via a cyclic `__del__`. Rare; dig into
  `top_types` immediately, this is the one case that's unambiguously a code bug.
- **`collected` stays low/flat at idle (no cyclic garbage accumulating) but the idle RSS baseline
  keeps climbing batch over batch anyway** → NOT a Python-level leak — `live_object_census()`
  proved this live on fredlab 2026-08-01 (`total_bytes_shallow` and even PyTorch's
  `UntypedStorage` stayed byte-for-byte flat across a 10-document batch while RSS visibly grew).
  Root cause found that day: **glibc allocates a separate malloc arena per thread**, and
  `malloc_trim(0)` only ever reclaims the *main* arena — never per-thread arenas. Any component
  whose activities/requests are handled by a small, long-lived, reused thread pool (check for
  `concurrent.futures.ThreadPoolExecutor` passed as a Temporal `activity_executor`, or similar) is
  exposed to this. Fix: set `MALLOC_ARENA_MAX=1` as an env var on that component (no image
  rebuild — pure deployment config). See `gcp-c1/argocd/fred-apps/values.yaml`'s
  `knowledgeFlowWorker.mallocArenaMax` for the wired, working example (chart default unset —
  opt-in per component only where the symptom is confirmed, don't set it blind).
- **`live_object_census()`'s `total_bytes_shallow` (or one specific type in `top_by_count`) itself
  keeps growing cycle over cycle at idle** → a real, if rare, Python-level leak (something
  genuinely still referenced, not cyclic). Neither `collect_and_trim` nor
  `collect_and_report_types` can catch this — only the census can. Follow `top_by_count`'s growing
  type back to its construction site.

## Worked example

`ThalesGroup/fred#2188` (ISSUE-006 through 010: several uncached-per-call factories, then the real
root cause — `KPIEvent.labels` typed `Iterable[str]` in `fred-core`, causing a `ValidatorIterator`
reference cycle on every KPI emission, platform-wide) and `#2198` (`live_object_census()` itself,
plus the `MALLOC_ARENA_MAX` follow-up, both found live-validating the first fix on fredlab). Read
the PR descriptions for the full evidence trail — every number in this doc's decision tree came
from a real reading during that investigation.
