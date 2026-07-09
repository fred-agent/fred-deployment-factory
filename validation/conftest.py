# Copyright Thales 2026
#
# Licensed under the Apache License, Version 2.0 (the "License").

"""
Shared fixtures for the platform validation suite.

Logs each deployment-factory user in with the Keycloak password grant — reusing
the CLI machinery (`fred_core.cli.auth`) — and exposes a per-user control-plane
client. The user/role/team matrix and endpoints live in `factory_config.py`.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import httpx
import pytest
from fred_core.cli.auth import KeycloakLoginConfig, KeycloakUserSessionManager

from factory_config import CLIENT_ID, CP_URL, KF_URL, PASSWORD, REALM_URL, USERS, FactoryUser


@pytest.fixture(scope="session")
def users() -> dict[str, FactoryUser]:
    return USERS


@pytest.fixture(scope="session", autouse=True)
def _require_stack() -> None:
    """Fail fast with a clear message when the expected stack is not reachable."""
    try:
        httpx.get(f"{CP_URL}/healthz", timeout=3.0).raise_for_status()
    except Exception as exc:  # noqa: BLE001
        pytest.fail(
            f"Control-plane not reachable at {CP_URL}/healthz ({exc}). "
            f"Start the complete Docker stack before running validation.",
            pytrace=False,
        )


_TOKEN_CACHE: dict[str, str] = {}


def login(username: str) -> str:
    """Password-grant login for one user (cached). Reuses the CLI session manager."""
    if username in _TOKEN_CACHE:
        return _TOKEN_CACHE[username]
    cfg = KeycloakLoginConfig(realm_url=REALM_URL, client_id=CLIENT_ID)
    cache_file = Path(tempfile.mkdtemp(prefix=f"fredval-{username}-")) / "session.json"
    mgr = KeycloakUserSessionManager(
        config=cfg, cache_file=cache_file, log_prefix=f"[val:{username}]"
    )
    try:
        mgr.login(username=username, password=PASSWORD)
        token = mgr.get_access_token()
    except Exception as exc:  # noqa: BLE001 - turn raw HTTP errors into a clear diagnostic
        body = ""
        resp = getattr(exc, "response", None)
        if resp is not None:
            body = f"\n  response: {resp.text[:200]}"
        pytest.fail(
            f"Keycloak password-grant login failed for {username!r} on client "
            f"{CLIENT_ID!r} at {REALM_URL}:\n  {type(exc).__name__}: {exc}{body}\n"
            f"→ Most likely the '{CLIENT_ID}' client does not allow direct grants. "
            f"Set \"directAccessGrantsEnabled\": true on it (TEST realm only) and "
            f"re-import the realm. See validation/README.md.",
            pytrace=False,
        )
    finally:
        mgr.close()
    if not token:
        pytest.fail(f"No token returned for {username!r} (client {CLIENT_ID!r}).", pytrace=False)
    _TOKEN_CACHE[username] = token
    return token


@pytest.fixture(scope="session")
def token_for():
    """Callable username -> access_token (cached per user)."""
    return login


class CP:
    """Thin control-plane client bound to one user's bearer token."""

    def __init__(self, username: str) -> None:
        self.username = username
        self._client = httpx.Client(
            base_url=CP_URL,
            headers={"Authorization": f"Bearer {login(username)}"},
            timeout=15.0,
        )

    def get(self, path: str, **kw) -> httpx.Response:
        return self._client.get(path, **kw)

    def post(self, path: str, **kw) -> httpx.Response:
        return self._client.post(path, **kw)

    def delete(self, path: str, **kw) -> httpx.Response:
        return self._client.delete(path, **kw)

    def close(self) -> None:
        self._client.close()


@pytest.fixture(scope="session")
def cp():
    """Factory `cp(username) -> CP` (one client per user, auto-closed)."""
    clients: dict[str, CP] = {}

    def _factory(username: str) -> CP:
        if username not in clients:
            clients[username] = CP(username)
        return clients[username]

    yield _factory
    for c in clients.values():
        c.close()


class KF:
    """Thin knowledge-flow-backend client bound to one user's bearer token.

    Mirrors `CP`. Separate from it because knowledge-flow-backend is a distinct
    process (its own port/base_url, see `factory_config.KF_URL`) - a test that
    doesn't need it shouldn't require it running.
    """

    def __init__(self, username: str) -> None:
        self.username = username
        self._client = httpx.Client(
            base_url=KF_URL,
            headers={"Authorization": f"Bearer {login(username)}"},
            timeout=15.0,
        )

    def get(self, path: str, **kw) -> httpx.Response:
        return self._client.get(path, **kw)

    def post(self, path: str, **kw) -> httpx.Response:
        return self._client.post(path, **kw)

    def close(self) -> None:
        self._client.close()


@pytest.fixture(scope="session")
def kf():
    """Factory `kf(username) -> KF` (one client per user, auto-closed).

    Unlike `cp`, reachability is checked lazily on first use (not at session
    start) - knowledge-flow-backend is only required by the scenarios that
    actually import this fixture.
    """
    clients: dict[str, KF] = {}
    checked = False

    def _factory(username: str) -> KF:
        nonlocal checked
        if not checked:
            try:
                httpx.get(f"{KF_URL}/healthz", timeout=3.0).raise_for_status()
            except Exception as exc:  # noqa: BLE001
                pytest.fail(
                    f"knowledge-flow-backend not reachable at {KF_URL}/healthz ({exc}). "
                    f"Start it manually (see validation/README.md) or set "
                    f"FRED_KNOWLEDGE_FLOW_URL if it runs elsewhere.",
                    pytrace=False,
                )
            checked = True
        if username not in clients:
            clients[username] = KF(username)
        return clients[username]

    yield _factory
    for c in clients.values():
        c.close()


def pytest_report_header(config) -> list[str]:
    """Print the 'world under test' at the top of every run, so a failing run is
    understood at a glance — which stack, which team, which agent."""
    from factory_config import AGENT_TAG, CP_URL, KF_URL, REALM_URL, TEST_TEAM, USERS

    return [
        "fred platform validation — world under test:",
        f"  control-plane : {CP_URL}",
        f"  knowledge-flow: {KF_URL} (only required by content-scope scenarios)",
        f"  keycloak realm: {REALM_URL}",
        f"  users         : {', '.join(sorted(USERS))}",
        f"  test team     : {TEST_TEAM}",
        f"  test agent    : {AGENT_TAG}",
    ]


CLAIM_GROUPS_FILE = Path(__file__).parent / ".claim_groups.json"


def pytest_collection_modifyitems(items) -> None:
    """Show each scenario as a plain-English sentence (its docstring) instead of the
    function name — e.g. 'bob (member) CANNOT enroll in a collaborative team'.

    Docstrings may use the tokens {agent} and {team} (single source of truth in
    factory_config), plus {<param>} for any of the test's own parametrize
    arguments (e.g. {username} on a `@pytest.mark.parametrize("username", ...)`
    test) — substituted from that test instance's own callspec, so the concrete
    value shows up in the sentence itself instead of only in the trailing
    `[username=...]` summary.

    Also writes a small sidecar mapping display-name -> source file
    (.claim_groups.json), since overwriting `item._nodeid` below loses the
    file/classname info the JUnit XML plugin would otherwise use for grouping.
    `generate_report.py` reads this to group results by claim area without
    needing any change to the test files themselves."""
    from factory_config import AGENT_TAG, TEST_TEAM

    claim_groups: dict[str, str] = {}
    for item in items:
        doc = (getattr(item.obj, "__doc__", "") or "").strip()
        desc = " ".join(doc.split()) if doc else item.name
        desc = desc.replace("{agent}", AGENT_TAG).replace("{team}", TEST_TEAM)
        callspec = getattr(item, "callspec", None)
        if callspec is not None and callspec.params:
            for key, value in callspec.params.items():
                desc = desc.replace("{" + key + "}", str(value))
            desc += " [" + ", ".join(f"{k}={v}" for k, v in callspec.params.items()) + "]"
        claim_groups[desc] = Path(item.location[0]).name
        item._nodeid = desc
    CLAIM_GROUPS_FILE.write_text(json.dumps(claim_groups, indent=2))
