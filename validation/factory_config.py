# Copyright Thales 2026
#
# Licensed under the Apache License, Version 2.0 (the "License").

"""
Source of truth for the validation suite: parses ../config/configuration.yaml
(the same file that seeds Keycloak + OpenFGA) into a typed user/role/team matrix,
plus the env-configurable endpoints. Imported by both conftest.py and the tests so
there is no fragile `import conftest`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# --- endpoints (env vars, local docker-compose defaults) ---------------------

REALM_URL = os.getenv("FRED_REALM_URL", "http://localhost:8080/realms/app")
CLIENT_ID = os.getenv("FRED_CLIENT_ID", "app")
PASSWORD = os.getenv("FRED_USER_PASSWORD", "Azerty123_")
CP_URL = os.getenv(
    "FRED_CONTROL_PLANE_URL", "http://localhost:8222/control-plane/v1"
).rstrip("/")


RUNTIME_PUBLIC_BASE = os.getenv("FRED_RUNTIME_PUBLIC_BASE", "http://localhost:8000").rstrip("/")
CONFIG_PATH = Path(
    os.getenv(
        "FRED_CONFIG_PATH",
        str(Path(__file__).parent.parent / "config" / "configuration.yaml"),
    )
)

# --- the agent the runtime / enroll scenarios exercise -----------------------
# SINGLE SOURCE OF TRUTH. Change it here (or via env) and every scenario name and
# every failure message follows automatically (see conftest's {agent} token).
# Requirements for this agent:
#   - VISIBLE / UI-deployable (public=True) so the catalog check is meaningful;
#     NOT the hidden 'fred.github.self_test' (public=False).
#   - ideally LLM-free, so enroll → runtime stream stays deterministic.
TEST_TEAM = os.getenv("FRED_TEST_TEAM", "fredlab")
TEST_AGENT_ID = os.getenv("FRED_TEST_AGENT_ID", "fred.github.test_assistant")
TEST_AGENT_LABEL = os.getenv("FRED_TEST_AGENT_LABEL", "Test Assistant (no LLM)")
# Compact human tag woven into test names and messages, e.g.
#   'Test Assistant (no LLM)' [fred.github.test_assistant]
AGENT_TAG = f"{TEST_AGENT_LABEL!r} [{TEST_AGENT_ID}]"


@dataclass(frozen=True)
class FactoryUser:
    username: str
    app_roles: tuple[str, ...]
    teams: tuple[str, ...]
    team_roles: dict[str, str]  # team -> owner/manager (membership is implicit)

    @property
    def is_global_admin(self) -> bool:
        return "admin" in self.app_roles

    def relation_in(self, team: str) -> str | None:
        """owner > manager > member (member implied by membership in `teams`)."""
        if team in self.team_roles:
            return self.team_roles[team]
        return "member" if team in self.teams else None

    def can_enroll_in(self, team: str) -> bool:
        # can_update_agents = manager or owner (docker OpenFGA: owner ⊃ manager).
        return self.relation_in(team) in ("manager", "owner")


def load_users() -> dict[str, FactoryUser]:
    raw: dict[str, Any] = yaml.safe_load(CONFIG_PATH.read_text())  # JSON is valid YAML
    out: dict[str, FactoryUser] = {}
    for u in raw.get("users", []):
        roles_by_team: dict[str, str] = {}
        for relation, teams in (u.get("team_roles") or {}).items():
            for t in teams:
                roles_by_team[t] = relation
        out[u["username"]] = FactoryUser(
            username=u["username"],
            app_roles=tuple(u.get("app_roles", [])),
            teams=tuple(u.get("teams", [])),
            team_roles=roles_by_team,
        )
    return out


USERS = load_users()
ALL_TEAMS = sorted({t for u in USERS.values() for t in u.teams})
