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

import base64
import json
import tempfile
from pathlib import Path

import httpx
import pytest
from fred_core.cli.auth import KeycloakLoginConfig, KeycloakUserSessionManager

from factory_config import (
    ALL_TEAMS,
    CLIENT_ID,
    CP_URL,
    KF_URL,
    PASSWORD,
    REALM_URL,
    USERS,
    FactoryUser,
)


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
        pytest.fail(
            f"No token returned for {username!r} (client {CLIENT_ID!r}).",
            pytrace=False,
        )
    _TOKEN_CACHE[username] = token
    return token


def _jwt_sub(token: str) -> str:
    """Extract the Keycloak subject from a JWT already obtained from Keycloak."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        decoded = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except Exception as exc:  # noqa: BLE001 - validation diagnostic
        pytest.fail(
            f"Could not decode JWT subject: {type(exc).__name__}: {exc}",
            pytrace=False,
        )
    sub = decoded.get("sub")
    if not isinstance(sub, str) or not sub:
        pytest.fail("JWT does not contain a usable 'sub' claim.", pytrace=False)
    return sub


def _team_identifiers(team_item: dict) -> set[str]:
    return {
        str(team_item.get(k))
        for k in ("id", "name", "team_id")
        if team_item.get(k)
    }


def _configured_relations(username: str, team_name: str) -> frozenset[str]:
    return USERS[username].relations_in(team_name)


def _configured_team_admins(team_name: str) -> list[str]:
    return sorted(username for username in USERS if USERS[username].is_team_admin_in(team_name))


def _platform_admin_username() -> str:
    for username, user in sorted(USERS.items()):
        if user.is_platform_admin:
            return username
    pytest.fail(
        "No platform_admin user found in validation configuration; cannot bootstrap Swift teams.",
        pytrace=False,
    )


@pytest.fixture(scope="session", autouse=True)
def _bootstrap_collaborative_teams(_require_stack) -> None:
    """Create the configured collaborative teams through the Swift API if missing.

    `make docker-up` seeds identities and OpenFGA, but in Swift the authoritative
    team registry lives in the control-plane `team_metadata` table. A fresh local
    stack therefore needs the validation suite to create its test teams through
    the same platform-admin bootstrap endpoint the UI uses, then apply the
    configured team roles through the team-admin membership endpoint.
    """
    if not ALL_TEAMS:
        return

    admin_username = _platform_admin_username()
    admin_token = login(admin_username)
    admin_client = httpx.Client(
        base_url=CP_URL,
        headers={"Authorization": f"Bearer {admin_token}"},
        timeout=15.0,
    )
    try:
        existing_resp = admin_client.get("/teams/all")
        existing_resp.raise_for_status()
        existing_items = existing_resp.json()
        if not isinstance(existing_items, list):
            pytest.fail(
                f"Unexpected /teams/all response shape: {existing_items!r}",
                pytrace=False,
            )
        teams_by_name_or_id: dict[str, dict] = {}
        for item in existing_items:
            if isinstance(item, dict):
                for ident in _team_identifiers(item):
                    teams_by_name_or_id[ident] = item

        for team_name in ALL_TEAMS:
            item = teams_by_name_or_id.get(team_name)
            if item is None:
                admin_usernames = _configured_team_admins(team_name)
                if not admin_usernames:
                    pytest.fail(
                        f"Configured team {team_name!r} has no team_admin; "
                        "cannot bootstrap it safely.",
                        pytrace=False,
                    )
                payload = {
                    "name": team_name,
                    "initial_team_admin_ids": [
                        _jwt_sub(login(username)) for username in admin_usernames
                    ],
                }
                create_resp = admin_client.post("/teams", json=payload)
                if create_resp.status_code == 409:
                    refresh_resp = admin_client.get("/teams/all")
                    refresh_resp.raise_for_status()
                    for refreshed in refresh_resp.json():
                        if isinstance(refreshed, dict):
                            for ident in _team_identifiers(refreshed):
                                teams_by_name_or_id[ident] = refreshed
                    item = teams_by_name_or_id.get(team_name)
                    if item is None:
                        pytest.fail(
                            f"Team {team_name!r} already exists by name but "
                            "is not visible in /teams/all.",
                            pytrace=False,
                        )
                else:
                    create_resp.raise_for_status()
                    item = create_resp.json()
                    for ident in _team_identifiers(item):
                        teams_by_name_or_id[ident] = item

            team_id = str(item.get("id") or item.get("team_id") or "")
            if not team_id:
                pytest.fail(
                    f"Team {team_name!r} has no id in bootstrap response: {item!r}",
                    pytrace=False,
                )

            admin_usernames = _configured_team_admins(team_name)
            acting_admin = admin_usernames[0]
            team_admin_client = httpx.Client(
                base_url=CP_URL,
                headers={"Authorization": f"Bearer {login(acting_admin)}"},
                timeout=15.0,
            )
            try:
                members_resp = team_admin_client.get(f"/teams/{team_id}/members")
                members_resp.raise_for_status()
                current_relations_by_user: dict[str, set[str]] = {}
                for member in members_resp.json():
                    user_id = str((member.get("user") or {}).get("id") or "")
                    if user_id:
                        current_relations_by_user[user_id] = set(member.get("relations") or [])

                # Roles are cumulative (AUTHZ-06): grant EVERY configured relation for
                # this user on this team, not just one. `team_admin`/`owner` are already
                # covered by `initial_team_admin_ids` at team creation above.
                for username in sorted(USERS):
                    relations = sorted(_configured_relations(username, team_name) - {"owner", "team_admin"})
                    if not relations:
                        continue
                    user_id = _jwt_sub(login(username))
                    held = current_relations_by_user.get(user_id, set())
                    for relation in relations:
                        if relation in held:
                            continue
                        if user_id in current_relations_by_user:
                            grant_resp = team_admin_client.post(
                                f"/teams/{team_id}/members/{user_id}/roles",
                                json={"relation": relation},
                            )
                        else:
                            grant_resp = team_admin_client.post(
                                f"/teams/{team_id}/members",
                                json={"user_id": user_id, "relation": relation},
                            )
                        if grant_resp.status_code not in (200, 201, 202, 204, 409):
                            pytest.fail(
                                f"Could not grant {username!r} the {relation!r} relation on "
                                f"{team_name!r} ({team_id}): HTTP {grant_resp.status_code} "
                                f"{grant_resp.text[:500]}",
                                pytrace=False,
                            )
                        if grant_resp.status_code == 409:
                            # A 409 here is ambiguous: it means "the relation is
                            # already held" ONLY if that is actually true. Re-read
                            # the confirmed state instead of assuming - a 409 for
                            # any other reason (e.g. a validation error reported as
                            # a conflict) must fail loudly, not be swallowed.
                            refreshed_members_resp = team_admin_client.get(f"/teams/{team_id}/members")
                            refreshed_members_resp.raise_for_status()
                            refreshed_relations: set[str] = set()
                            for member in refreshed_members_resp.json():
                                if str((member.get("user") or {}).get("id") or "") == user_id:
                                    refreshed_relations = set(member.get("relations") or [])
                                    break
                            if relation not in refreshed_relations:
                                pytest.fail(
                                    f"Granting {username!r} the {relation!r} relation on "
                                    f"{team_name!r} ({team_id}) returned 409, but re-reading "
                                    f"/teams/{team_id}/members shows {username!r} holds "
                                    f"{sorted(refreshed_relations)!r} - the 409 was not "
                                    "'already held', it hid a real failure: "
                                    f"{grant_resp.text[:500]}",
                                    pytrace=False,
                                )
                            current_relations_by_user[user_id] = refreshed_relations
                        else:
                            current_relations_by_user.setdefault(user_id, set()).add(relation)
            finally:
                team_admin_client.close()
    finally:
        admin_client.close()


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

    def put(self, path: str, **kw) -> httpx.Response:
        return self._client.put(path, **kw)

    def patch(self, path: str, **kw) -> httpx.Response:
        return self._client.patch(path, **kw)

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
