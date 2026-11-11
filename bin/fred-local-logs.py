#!/usr/bin/env python3
"""Run the local Fred processes with terminal text or collector-ready JSON."""

from __future__ import annotations

import argparse
import contextlib
import json
import fcntl
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

# name, application directory, make target, configuration read by that target.
# The commands and configurations are those of a Fred Weaver checkout prepared by
# `make docker-prepare`; the launcher only selects the log format.
COMPONENTS = (
    ("control-plane", "control-plane", "run", "configuration_prod.yaml"),
    ("knowledge-flow-backend", "knowledge-flow-backend", "run", "configuration_prod.yaml"),
    ("knowledge-flow-worker", "knowledge-flow-worker", "run", "configuration_worker.yaml"),
    ("fred-agents", "fred-agents", "run", "configuration_prod.yaml"),
    ("fred-agents-worker", "fred-agents", "run-worker", "configuration_prod.yaml"),
    ("frontend", "frontend", "run", None),
)
# Ports the APIs and the frontend publish with their tracked configuration.
PORTS = {"control-plane": 8222, "knowledge-flow-backend": 8111, "fred-agents": 8000, "frontend": 5173}


def prepare_config(source: Path, output: Path, mode: str) -> None:
    """Copy one configuration, changing only `app.log_format`.

    Relative paths resolve against the application directory, the process's
    working directory, so the copy anchors them there.
    """
    text = source.read_text()
    text, count = re.subn(r"(?m)^(  log_format:)\s*[^\n]*$", rf"\1 {mode}", text)
    if count != 1:
        raise ValueError(f"Expected one app.log_format in {source}")
    app_dir = source.parent.parent
    text = re.sub(r"(?m)^(\s*[A-Za-z_]+:\s+)\./", lambda m: f"{m.group(1)}{app_dir}/", text)
    output.write_text(text)
    output.chmod(0o600)


def signal_group(process: subprocess.Popen[bytes], sig: int) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, sig)


def stop_session(manifest: Path) -> int:
    if not manifest.exists():
        print("No recorded Fred session is running.")
        return 0
    data = json.loads(manifest.read_text())
    pid = data["supervisor_pid"]
    command = Path(f"/proc/{pid}/cmdline")
    if not command.exists():
        print("The recorded Fred session is no longer running.")
        return 0
    # Never signal a reused PID belonging to an unrelated application.
    args = command.read_bytes().split(b"\0")
    process_cwd = Path(f"/proc/{pid}/cwd").resolve()
    script = Path(__file__).resolve()
    if not any(
        (process_cwd / os.fsdecode(arg)).resolve() == script
        for arg in args[1:]
        if arg and not arg.startswith(b"-")
    ):
        raise RuntimeError("Recorded PID no longer belongs to this launcher")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 25
    while manifest.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    if manifest.exists():
        raise RuntimeError(
            "Fred shutdown has not completed; do not start another session yet"
        )
    print("Stopped the recorded Fred session.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--mode", choices=("json", "text"), default="json")
    parser.add_argument("--component", choices=[item[0] for item in COMPONENTS])
    parser.add_argument(
        "--log-dir", type=Path, default=Path("/tmp/fred-structured-logs")
    )
    parser.add_argument("--stop", action="store_true")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    log_dir = args.log_dir.resolve()
    log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    log_dir.chmod(0o700)
    manifest = log_dir / "session.json"
    if args.stop:
        return stop_session(manifest)
    if manifest.exists():
        prior = json.loads(manifest.read_text())
        if Path(f"/proc/{prior['supervisor_pid']}").exists():
            raise RuntimeError(
                "A recorded Fred session is running; stop it before switching modes"
            )
    lock = (log_dir / "session.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError("A Fred launcher already owns this log directory") from None
    selected = [
        item for item in COMPONENTS if not args.component or item[0] == args.component
    ]
    for name, app, target, config in selected:
        cwd = checkout / "apps" / app
        if not (cwd / "Makefile").exists():
            raise ValueError(f"{checkout} is not a Fred Weaver checkout: no apps/{app}")
        if config and not (cwd / "config/.env").exists():
            raise ValueError(
                f"{name}: no config/.env; prepare the checkout first: "
                f"make docker-prepare DIR={checkout}"
            )
        port = PORTS.get(name)
        if port:
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    probe.bind(("0.0.0.0", port))
                except OSError:
                    raise RuntimeError(
                        f"{name}: port {port} is occupied; stop the existing process first"
                    ) from None
    processes: list[subprocess.Popen[bytes]] = []
    stopping = False

    def request_stop(signum: int, frame: object) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    session = {
        "supervisor_pid": os.getpid(),
        "checkout": str(checkout),
        "mode": args.mode,
        "processes": [],
    }
    with (
        tempfile.TemporaryDirectory(prefix="fred-log-config-") as config_dir,
        contextlib.ExitStack() as stack,
    ):
        try:
            for name, app, target, config in selected:
                if stopping:
                    break
                cwd = checkout / "apps" / app
                env = os.environ.copy()
                env.update(
                    PYTHONUNBUFFERED="1",
                    NO_PROXY="localhost,127.0.0.1,::1",
                    no_proxy="localhost,127.0.0.1,::1",
                )
                if config:
                    copy = Path(config_dir) / f"{name}.yaml"
                    prepare_config(cwd / "config" / config, copy, args.mode)
                    # The process environment takes precedence over config/.env.
                    env["CONFIG_FILE"] = str(copy)
                command = ["make", target]
                output = (
                    stack.enter_context(
                        os.fdopen(
                            os.open(
                                log_dir / f"{name}.log",
                                os.O_WRONLY | os.O_CREAT | os.O_APPEND,
                                0o600,
                            ),
                            "ab",
                        )
                    )
                    if args.mode == "json"
                    else None
                )
                if output is not None:
                    os.fchmod(output.fileno(), 0o600)
                process = subprocess.Popen(
                    command,
                    cwd=cwd,
                    env=env,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                processes.append(process)
                session["processes"].append(
                    {
                        "name": name,
                        "pid": process.pid,
                        "command": command,
                        "log": str(log_dir / f"{name}.log") if output else None,
                    }
                )
                print(f"Started {name}: PID {process.pid}", flush=True)
            manifest.write_text(json.dumps(session, indent=2))
            manifest.chmod(0o600)
            print(
                "JSON logs: http://localhost:3002/d/fred-local-logs/fred-logs"
                if args.mode == "json"
                else "Text logs: this terminal",
                flush=True,
            )
            print(
                "Fred UI: http://localhost:5173 — Ctrl+C stops this session", flush=True
            )
            while not stopping:
                for name, process in zip((item[0] for item in selected), processes):
                    if process.poll() is not None:
                        print(
                            f"{name} exited with status {process.returncode}; stopping the session.",
                            file=sys.stderr,
                        )
                        return process.returncode or 1
                time.sleep(0.5)
            return 0
        finally:
            for process in processes:
                signal_group(process, signal.SIGTERM)
            deadline = time.monotonic() + 15
            while (
                any(process.poll() is None for process in processes)
                and time.monotonic() < deadline
            ):
                time.sleep(0.2)
            for process in processes:
                signal_group(process, signal.SIGKILL)
                process.wait()
            manifest.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Fred launcher: {error}", file=sys.stderr)
        raise SystemExit(1)
