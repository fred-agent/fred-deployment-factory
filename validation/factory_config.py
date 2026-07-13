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
# knowledge-flow-backend, started manually per validation/README.md like the other
# swift apps. Default matches its documented standalone port/base_url (README.md,
# configuration_local_mock.yaml): 8111 / "/knowledge-flow/v1".
KF_URL = os.getenv("FRED_KNOWLEDGE_FLOW_URL", "http://localhost:8111/knowledge-flow/v1").rstrip("/")
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


_ADMIN_RELATIONS = frozenset({"owner", "team_admin"})
_EDITOR_RELATIONS = frozenset({"manager", "team_editor"})
_ENROLL_RELATIONS = _ADMIN_RELATIONS | _EDITOR_RELATIONS


@dataclass(frozen=True)
class FactoryUser:
    username: str
    app_roles: tuple[str, ...]
    teams: tuple[str, ...]
    # team -> the FULL set of relations held there. Roles are cumulative
    # (AUTHZ-06, RFC Part 7 §33-39): a user may hold team_admin, team_editor
    # AND team_analyst on the same team at once, each independently granted.
    team_roles: dict[str, frozenset[str]]
    # AUTHZ-05 target model (fred FRED-AUTHORIZATION-TARGET-MODEL-RFC): stored-only
    # OpenFGA relations on the singleton organization, never derived from app_roles.
    # Values: "admin" -> platform_admin, "observer" -> platform_observer.
    platform_roles: tuple[str, ...] = ()

    @property
    def is_global_admin(self) -> bool:
        """Legacy Keycloak `admin` app role - NOT the AUTHZ-05 target `platform_admin`.

        A global admin is not automatically a team owner/manager (see AUTHZ-05
        §24.2); use `relations_in`/`can_enroll_in` for team-scoped questions.
        """
        return "admin" in self.app_roles

    @property
    def is_platform_admin(self) -> bool:
        """AUTHZ-05 target `platform_admin` relation (stored, not Keycloak-derived)."""
        return "admin" in self.platform_roles

    @property
    def is_platform_observer(self) -> bool:
        """AUTHZ-05 target `platform_observer` relation (stored, not Keycloak-derived)."""
        return "observer" in self.platform_roles

    def relations_in(self, team: str) -> frozenset[str]:
        """Return every direct team relation this user holds on `team` (cumulative)."""
        relations = self.team_roles.get(team, frozenset())
        if not relations and team in self.teams:
            return frozenset({"team_member"})
        return relations

    def can_enroll_in(self, team: str) -> bool:
        return bool(self.relations_in(team) & _ENROLL_RELATIONS)

    def is_team_admin_in(self, team: str) -> bool:
        return bool(self.relations_in(team) & _ADMIN_RELATIONS)

    def is_team_editor_in(self, team: str) -> bool:
        return bool(self.relations_in(team) & _EDITOR_RELATIONS)


def load_users() -> dict[str, FactoryUser]:
    raw: dict[str, Any] = yaml.safe_load(CONFIG_PATH.read_text())  # JSON is valid YAML
    out: dict[str, FactoryUser] = {}
    for u in raw.get("users", []):
        roles_by_team: dict[str, set[str]] = {}
        for relation, teams in (u.get("team_roles") or {}).items():
            for t in teams:
                roles_by_team.setdefault(t, set()).add(relation)
        out[u["username"]] = FactoryUser(
            username=u["username"],
            app_roles=tuple(u.get("app_roles", [])),
            teams=tuple(u.get("teams", [])),
            team_roles={t: frozenset(rs) for t, rs in roles_by_team.items()},
            platform_roles=tuple(u.get("platform_roles", [])),
        )
    return out


USERS = load_users()
ALL_TEAMS = sorted({t for u in USERS.values() for t in u.teams})
TEAM_OPERATOR_USERNAME = next(
    (username for username, user in sorted(USERS.items()) if user.can_enroll_in(TEST_TEAM)),
    None,
)
