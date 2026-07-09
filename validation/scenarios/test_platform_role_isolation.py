# Copyright Thales 2026
#
# Licensed under the Apache License, Version 2.0 (the "License").

"""
AUTHZ-05 platform-role isolation validation.

`fred`'s FRED-AUTHORIZATION-TARGET-MODEL-RFC.md central rule (§2.2): a platform
role must never grant team data visibility. On 2026-07-09 a live escalation bug
was found and fixed in fred-core's schema.fga: `team.owner` used to include
`admin from organization`, so any Keycloak `admin` was an implicit owner of every
team. This file proves the fix, using identities that could not previously be
proven correct with the existing fixture (alice, the only prior `admin`, is also
manager of every team - she can't demonstrate a negative).

Users exercised (config/configuration.yaml):
  oscar  - legacy Keycloak `admin`, member of NO team          -> pure escalation stress case
  derek  - legacy Keycloak `admin`, manager of northbridge ONLY -> the fix must not overshoot:
           northbridge access stays legitimate, fredlab/swiftpost stay denied
  priya  - AUTHZ-05 target `platform_admin`, zero teams        -> the new relation, isolated
  quinn  - AUTHZ-05 target `platform_observer`, zero teams     -> read-only platform role,
           still zero team access

nina (zero app_roles, zero teams - the floor case) needs no dedicated scenario here:
`test_user_sees_exactly_their_teams` and `test_user_can_enroll_agent_in_their_personal_team`
in test_runtime_team_isolation.py already parametrize over every user in USERS, so nina is
covered automatically the moment she exists in configuration.yaml.
"""

from __future__ import annotations

import pytest

from factory_config import TEST_TEAM, USERS


def _resolve_team_id(cp, admin_username: str, team_name: str) -> str:
    """Resolve a team name to its id via an admin's /teams (alice is manager everywhere)."""
    teams = cp(admin_username).get("/teams").json()
    by_name = {t.get("name"): t for t in teams}
    item = by_name.get(team_name)
    if item is None:
        pytest.fail(
            f"Team {team_name!r} is not visible to {admin_username!r} in /teams.\n"
            f"Teams returned: {sorted(n for n in by_name if n)}\n"
            f"-> Is configuration.yaml seeded (make docker-up / make openfga-post-install)?",
            pytrace=False,
        )
    return str(item.get("id") or item.get("name"))


@pytest.fixture(scope="module")
def fredlab_id(cp) -> str:
    return _resolve_team_id(cp, "alice", TEST_TEAM)


@pytest.fixture(scope="module")
def northbridge_id(cp) -> str:
    return _resolve_team_id(cp, "alice", "northbridge")


# --- oscar: legacy admin, member of nothing -----------------------------------


def test_legacy_admin_without_any_team_membership_cannot_read_team_catalog(fredlab_id, cp) -> None:
    """oscar (legacy Keycloak admin, member of no team) cannot read {team}'s agent catalog."""
    resp = cp("oscar").get(f"/teams/{fredlab_id}/agent-templates")
    assert resp.status_code in (403, 404), (
        f"oscar has no team relation on {TEST_TEAM!r} yet got {resp.status_code} from "
        f"/teams/{fredlab_id}/agent-templates - platform-role escalation regression "
        f"(AUTHZ-05 §24.2: 'admin from organization' must not resurrect in team.owner)."
    )


def test_legacy_admin_without_any_team_membership_sees_no_collaborative_team(cp) -> None:
    """oscar (legacy Keycloak admin, member of no team) sees zero collaborative teams."""
    items = cp("oscar").get("/teams").json()
    collaborative = [t for t in items if not str(t.get("id", "")).startswith("personal-")]
    assert not collaborative, (
        f"oscar (admin app role, no team_roles anywhere) unexpectedly sees collaborative "
        f"teams: {[t.get('name') for t in collaborative]!r}"
    )


# --- derek: legacy admin, legitimate manager of northbridge ONLY ---------------


def test_legacy_admin_who_is_also_a_real_manager_keeps_that_teams_access(northbridge_id, cp) -> None:
    """derek (admin app role, real manager of northbridge only) can still read northbridge's catalog."""
    resp = cp("derek").get(f"/teams/{northbridge_id}/agent-templates")
    assert resp.status_code == 200, (
        f"derek is a real manager of northbridge, yet {resp.status_code} from "
        f"/teams/{northbridge_id}/agent-templates: {resp.text[:200]} - the AUTHZ-05 fix must "
        f"not remove legitimate, explicitly-granted team access."
    )


def test_legacy_admin_who_is_also_a_real_manager_cannot_reach_other_teams(fredlab_id, cp) -> None:
    """derek (admin app role, manager of northbridge only) is denied {team}'s catalog."""
    resp = cp("derek").get(f"/teams/{fredlab_id}/agent-templates")
    assert resp.status_code in (403, 404), (
        f"derek has no team relation on {TEST_TEAM!r} (only on northbridge) yet got "
        f"{resp.status_code} from /teams/{fredlab_id}/agent-templates - his admin app role "
        f"is leaking into an unrelated team."
    )


# --- priya / quinn: AUTHZ-05 target relations, isolated ------------------------


@pytest.mark.parametrize("username", ["priya", "quinn"])
def test_platform_role_alone_grants_no_team_data(username: str, fredlab_id, cp) -> None:
    """{username} (AUTHZ-05 platform_admin or platform_observer, zero teams) cannot read {team}'s catalog."""
    resp = cp(username).get(f"/teams/{fredlab_id}/agent-templates")
    assert resp.status_code in (403, 404), (
        f"{username} holds only the new AUTHZ-05 platform relation and no team relation, "
        f"yet got {resp.status_code} from /teams/{fredlab_id}/agent-templates - a platform "
        f"role must never grant team data visibility (RFC §2.2)."
    )


@pytest.mark.parametrize("username", ["priya", "quinn"])
def test_platform_role_alone_sees_no_collaborative_team(username: str, cp) -> None:
    """{username} (AUTHZ-05 platform_admin or platform_observer, zero teams) sees zero collaborative teams."""
    items = cp(username).get("/teams").json()
    collaborative = [t for t in items if not str(t.get("id", "")).startswith("personal-")]
    assert not collaborative, (
        f"{username} unexpectedly sees collaborative teams: "
        f"{[t.get('name') for t in collaborative]!r}"
    )


def test_all_new_matrix_users_are_registered(cp) -> None:
    """Sanity check: the complete-matrix users this file depends on are actually in USERS."""
    expected = {"oscar", "nina", "derek", "priya", "quinn"}
    missing = expected - set(USERS)
    assert not missing, (
        f"Expected demo users {sorted(missing)} missing from configuration.yaml - "
        f"this file's scenarios cannot run without them."
    )
