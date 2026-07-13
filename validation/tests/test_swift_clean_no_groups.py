# Copyright Thales 2026
#
# Licensed under the Apache License, Version 2.0 (the "License").

"""
Static regression guards for the swift-clean / kea-legacy separation
(AUTHZ-05/06). Pure file I/O against the tracked Keycloak realm export
templates and OpenFGA model files - no running stack required (see
tests/conftest.py).

These exist because the actual bug class here is invisible to `bash -n` or
`jq` validity checks: a syntactically valid realm-import JSON can still bake
in demo groups, group memberships, or group-admin Keycloak client roles that
silently reintroduce a Keycloak-groups-as-teams shape into the swift-clean
starting state. Each check below pins one specific claim from the AUTHZ-05/06
convergence pass so a future edit to these large, hand-maintained JSON files
cannot regress it unnoticed.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]

SWIFT_REALM_TEMPLATES = [
    REPO_ROOT / "docker-compose/keycloak/app-realm.json.template",
    REPO_ROOT / "helm/fred-stack/files/keycloak/app-realm.json.template",
]

# Both backends share ONE realm-import template for both authz modes - a
# Swift team is never a Keycloak group in either mode's *starting* state
# (kea-legacy's post-install script creates its own groups at runtime from
# config/configuration.kea.yaml). So these templates must never bake in a
# demo group, a per-user group membership, or a default groups-scope - not
# because they are "the Swift template", but because post-install (not the
# import) is the sole owner of authz-mode-specific state.
GROUP_SCOPED_SERVICE_ACCOUNTS = (
    "service-account-agentic",
    "service-account-knowledge-flow",
    "service-account-control-plane",
)


def _load(path: Path) -> dict:
    assert path.is_file(), f"{path} not found"
    return json.loads(path.read_text())


@pytest.mark.parametrize("template_path", SWIFT_REALM_TEMPLATES, ids=lambda p: p.name)
def test_realm_template_has_no_demo_groups(template_path: Path) -> None:
    """The shared realm-import template defines zero groups."""
    realm = _load(template_path)
    assert realm.get("groups", []) == [], (
        f"{template_path} bakes in group(s) {realm.get('groups')!r} - a Swift team is never a "
        f"Keycloak group; kea-legacy's post-install creates its own groups at runtime"
    )


@pytest.mark.parametrize("template_path", SWIFT_REALM_TEMPLATES, ids=lambda p: p.name)
def test_realm_template_users_have_no_group_membership(template_path: Path) -> None:
    """No user in the shared realm-import template belongs to any group."""
    realm = _load(template_path)
    offenders = {
        u.get("username"): u.get("groups")
        for u in realm.get("users", [])
        if u.get("groups")
    }
    assert not offenders, f"{template_path}: users with non-empty groups: {offenders!r}"


@pytest.mark.parametrize("template_path", SWIFT_REALM_TEMPLATES, ids=lambda p: p.name)
def test_realm_template_app_client_has_no_default_groups_scope(template_path: Path) -> None:
    """The 'app' client does not default to groups-scope at import time."""
    realm = _load(template_path)
    app_clients = [c for c in realm.get("clients", []) if c.get("clientId") == "app"]
    assert len(app_clients) == 1, f"{template_path}: expected exactly one 'app' client, found {len(app_clients)}"
    default_scopes = app_clients[0].get("defaultClientScopes", [])
    assert "groups-scope" not in default_scopes, (
        f"{template_path}: 'app' client defaults to groups-scope - only kea-legacy's "
        f"post-install should ever attach it, never the import itself"
    )


@pytest.mark.parametrize("template_path", SWIFT_REALM_TEMPLATES, ids=lambda p: p.name)
def test_realm_template_service_accounts_have_no_group_admin_roles(template_path: Path) -> None:
    """No FRED service account is baked in with a Keycloak group-admin role.

    No app in the fred product (agentic/knowledge-flow/control-plane) calls
    a Keycloak group-admin API - confirmed against fred's source during the
    AUTHZ-05/06 pass. query-groups/view-groups/account:view-groups are
    therefore never a legitimate grant for these service accounts, in either
    authz mode.
    """
    realm = _load(template_path)
    offenders: dict[str, list[str]] = {}
    for user in realm.get("users", []):
        username = user.get("username")
        if username not in GROUP_SCOPED_SERVICE_ACCOUNTS:
            continue
        client_roles = user.get("clientRoles", {})
        bad_roles = [
            r for r in client_roles.get("realm-management", []) if r in ("query-groups", "view-groups")
        ] + [r for r in client_roles.get("account", []) if r == "view-groups"]
        if bad_roles:
            offenders[username] = bad_roles
    assert not offenders, f"{template_path}: service accounts with group-admin roles baked in: {offenders!r}"


KEA_MODEL_PATHS = [
    REPO_ROOT / "docker-compose/openfga/openfga-model.kea.json",
    REPO_ROOT / "helm/fred-stack/files/openfga/openfga-model.kea.json",
]


@pytest.mark.parametrize("model_path", KEA_MODEL_PATHS, ids=lambda p: p.name)
def test_kea_model_keeps_legacy_team_vocabulary(model_path: Path) -> None:
    """The Kea OpenFGA model still defines the legacy member/manager/owner team relations."""
    model = _load(model_path)
    team_type = next((t for t in model.get("type_definitions", []) if t.get("type") == "team"), None)
    assert team_type is not None, f"{model_path}: no 'team' type definition"
    relations = set(team_type.get("relations", {}).keys())
    missing = {"member", "manager", "owner"} - relations
    assert not missing, f"{model_path}: Kea model is missing legacy team relations {missing!r} - has it been overwritten by the Swift model?"


SWIFT_MODEL_PATHS = [
    REPO_ROOT / "docker-compose/openfga/openfga-model.json",
    REPO_ROOT / "helm/fred-stack/files/openfga/openfga-model.json",
]


@pytest.mark.parametrize("model_path", SWIFT_MODEL_PATHS, ids=lambda p: p.name)
def test_swift_model_has_no_legacy_team_vocabulary(model_path: Path) -> None:
    """The Swift OpenFGA model never carries the legacy member/manager/owner team relations."""
    model = _load(model_path)
    team_type = next((t for t in model.get("type_definitions", []) if t.get("type") == "team"), None)
    assert team_type is not None, f"{model_path}: no 'team' type definition"
    relations = set(team_type.get("relations", {}).keys())
    leaked = relations & {"member", "manager", "owner"}
    assert not leaked, f"{model_path}: Swift model carries legacy team relations {leaked!r} - has it been overwritten by the Kea model?"
