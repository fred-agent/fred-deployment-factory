# Copyright Thales 2026
#
# Licensed under the Apache License, Version 2.0 (the "License").

"""
AUTHZ-05 §25a - organization-scoped content capability, not yet team-scoped.

Known, NOT YET FIXED gap in `fred`'s knowledge-flow-backend: several content
endpoints gate on `OrganizationPermission.CAN_READ_CONTENT` / `CAN_PROCESS_CONTENT`
against the singleton organization object only - there is no team_id in the
authorization decision at all. Verified directly against
`knowledge_flow_backend/features/corpus_manager/corpus_manager_controller.py`:

    async def _auth(self, user, permission=OrganizationPermission.CAN_READ_CONTENT):
        await get_rebac_engine().check_user_permission_or_raise(user, permission, ORGANIZATION_ID)

    @router.get("/corpus/capabilities")
    async def capabilities(user=Depends(get_current_user)):
        await self._auth(user, OrganizationPermission.CAN_READ_CONTENT)
        ...

Net effect today: any Keycloak `viewer` gets this content-management capability
regardless of team membership - the endpoint never checks *which* team's content
is being managed. This is a real, broader gap than the escalation bug fixed in
test_platform_role_isolation.py: it needs no `admin` role, no team relation
anywhere, just the baseline `viewer` app role every demo user already has.

These scenarios are marked `xfail(strict=True)` on purpose - they currently PASS
the vulnerability (the endpoint answers 200 with no team check), so the assertion
below is written for the FIXED world and is expected to fail today. `strict=True`
means the day this is fixed upstream and someone forgets to touch this file, the
run turns red (XPASS) instead of quietly staying green on a vulnerability nobody
re-checked. See `fred`'s FRED-AUTHORIZATION-TARGET-MODEL-RFC.md §25a.

`raises=AssertionError` on both markers matters: without it, xfail also swallows
*any* exception raised during fixture setup - including "knowledge-flow-backend
unreachable" from the `kf` fixture's own reachability check - and reports that as
XFAIL too, exactly the false-green this suite's own design principle forbids.
Scoping to AssertionError means only the specific status-code check is treated as
the known, accepted gap; an unreachable stack is still a loud ERROR.

Needs knowledge-flow-backend running and reachable at FRED_KNOWLEDGE_FLOW_URL
(see validation/README.md) - not required by any other scenario in this suite.
"""

from __future__ import annotations

import pytest

from factory_config import USERS


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason=(
        "AUTHZ-05 §25a: /corpus/capabilities gates on the org-level "
        "can_read_content capability with no team scoping. Un-xfail this the day "
        "that endpoint (and its ~30 siblings across knowledge-flow-backend) "
        "becomes team-scoped."
    ),
)
def test_global_admin_with_no_team_can_read_content_capabilities_platform_wide(kf) -> None:
    """oscar (global admin, member of no team) must not read platform content capabilities."""
    # oscar, not priya: priya deliberately has zero app_roles (she's the pure
    # AUTHZ-05 platform_admin user, and platform_admin is not - yet - wired into
    # can_read_content), so she'd be denied for an unrelated reason and this
    # test would pass for the wrong cause. oscar's `admin` app_role cascades to
    # `viewer` in the OpenFGA graph (viewer: [user] or editor or admin), which
    # is exactly what `can_read_content` checks - and he has zero team relation
    # anywhere, so this isolates the org-vs-team-scope gap cleanly.
    resp = kf("oscar").get("/corpus/capabilities")
    assert resp.status_code in (403, 404), (
        f"expected 403/404 for a caller with no team relation, got {resp.status_code}: "
        f"{resp.text[:200]}"
    )


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason=(
        "AUTHZ-05 §25a: same gap as above, demonstrated with an ordinary demo user "
        "(liam - viewer, member of swiftpost only) rather than a synthetic identity."
    ),
)
def test_team_scoped_viewer_can_read_content_capabilities_of_teams_they_are_not_in(kf) -> None:
    """liam (viewer, swiftpost only) must not read content capabilities scoped to other teams."""
    assert "swiftpost" in USERS["liam"].teams and "fredlab" not in USERS["liam"].teams, (
        "fixture drift: this scenario assumes liam is in swiftpost but not fredlab - "
        "check configuration.yaml if this fails."
    )
    resp = kf("liam").get("/corpus/capabilities")
    assert resp.status_code in (403, 404), (
        f"liam has no relation to any team other than swiftpost, yet {resp.status_code} "
        f"from /corpus/capabilities: {resp.text[:200]} - his bare 'viewer' app role reaches "
        f"a content capability with no team check at all."
    )
