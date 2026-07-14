#!/usr/bin/env python3
"""Plan, apply, and validate the additive OpenFGA role migration for Swift.

This tool is intentionally conservative:

- it never deletes OpenFGA tuples;
- it writes only target Swift tuples;
- it maps platform admins only from explicit operator input;
- it validates that every migrated team user still has a target team tuple.

Expected local flow:

  make docker-up
  python3 bin/fredlab-authz-migrate-swift.py plan \
    --platform-admin <admin-user-or-keycloak-id> \
    --platform-admin <admin-user-or-keycloak-id> \
    --out dumps/authz/swift-authz-plan.json
  python3 bin/fredlab-authz-migrate-swift.py install-model \
    --model-file docker/openfga/openfga-model.json
  python3 bin/fredlab-authz-migrate-swift.py apply --plan dumps/authz/swift-authz-plan.json
  python3 bin/fredlab-authz-migrate-swift.py validate --plan dumps/authz/swift-authz-plan.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_ENV_FILE = Path("docker/.env")
DEFAULT_OPENFGA_URL = "http://localhost:9080"
DEFAULT_OPENFGA_STORE = "fred"
DEFAULT_OPENFGA_TOKEN = "Azerty123_"
DEFAULT_KEYCLOAK_URL = "http://localhost:8080"
DEFAULT_KEYCLOAK_REALM = "app"
DEFAULT_KEYCLOAK_ADMIN_USER = "admin"
DEFAULT_KEYCLOAK_ADMIN_PASSWORD = "Azerty123_"
DEFAULT_KEYCLOAK_CLIENT_ID = "app"
ORGANIZATION_OBJECT = "organization:fred"
LEGACY_TEAM_RELATIONS = ("owner", "manager", "member")
PLATFORM_RELATIONS = ("platform_admin", "platform_observer")


class MigrationError(RuntimeError):
    """Expected operator-facing failure."""


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()


def load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        env[key.strip()] = value
    return env


def first_setting(env_file: dict[str, str], names: tuple[str, ...], default: str) -> str:
    for name in names:
        value = os.environ.get(name) or env_file.get(name)
        if value:
            return value
    return default


def json_request(
    method: str,
    url: str,
    *,
    token: str | None = None,
    data: Any | None = None,
    form: dict[str, str] | None = None,
) -> Any:
    headers: dict[str, str] = {"Accept": "application/json"}
    body: bytes | None = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        body = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            if not raw:
                return {}
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise MigrationError(f"{method} {url} failed with HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise MigrationError(f"{method} {url} failed: {exc.reason}") from exc


class KeycloakClient:
    def __init__(self, base_url: str, realm: str, admin_user: str, admin_password: str, client_id: str):
        self.base_url = base_url.rstrip("/")
        self.realm = realm
        self.admin_user = admin_user
        self.admin_password = admin_password
        self.client_id = client_id
        self._token: str | None = None
        self._client_uuid: str | None = None

    @property
    def token(self) -> str:
        if self._token is None:
            response = json_request(
                "POST",
                f"{self.base_url}/realms/master/protocol/openid-connect/token",
                form={
                    "grant_type": "password",
                    "client_id": "admin-cli",
                    "username": self.admin_user,
                    "password": self.admin_password,
                },
            )
            self._token = response["access_token"]
        return self._token

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        query = ""
        if params:
            query = "?" + urllib.parse.urlencode(params)
        return json_request("GET", f"{self.base_url}/admin/realms/{self.realm}{path}{query}", token=self.token)

    def list_users(self) -> list[dict[str, Any]]:
        users: list[dict[str, Any]] = []
        first = 0
        page_size = 100
        while True:
            page = self.get(
                "/users",
                {
                    "first": first,
                    "max": page_size,
                    "briefRepresentation": "false",
                },
            )
            if not page:
                break
            users.extend(page)
            if len(page) < page_size:
                break
            first += page_size
        return users

    def client_uuid(self) -> str:
        if self._client_uuid is None:
            clients = self.get("/clients", {"clientId": self.client_id})
            if not clients:
                raise MigrationError(f"Keycloak client {self.client_id!r} was not found")
            self._client_uuid = clients[0]["id"]
        return self._client_uuid

    def user_client_roles(self, user_id: str) -> list[str]:
        try:
            roles = self.get(f"/users/{user_id}/role-mappings/clients/{self.client_uuid()}")
        except MigrationError as exc:
            print(f"warning: could not read client roles for user {user_id}: {exc}", file=sys.stderr)
            return []
        return sorted(role["name"] for role in roles)

    def list_groups(self) -> list[dict[str, Any]]:
        roots = self.get("/groups", {"briefRepresentation": "false"})
        groups: list[dict[str, Any]] = []

        def visit(group: dict[str, Any], parent_path: str = "") -> None:
            path = group.get("path") or f"{parent_path}/{group.get('name', group['id'])}"
            groups.append(
                {
                    "id": group["id"],
                    "name": group.get("name") or group["id"],
                    "path": path,
                }
            )
            for child in group.get("subGroups") or []:
                visit(child, path)

        for root in roots:
            visit(root)
        return groups

    def group_members(self, group_id: str) -> list[dict[str, Any]]:
        members: list[dict[str, Any]] = []
        first = 0
        page_size = 100
        while True:
            page = self.get(
                f"/groups/{group_id}/members",
                {
                    "first": first,
                    "max": page_size,
                    "briefRepresentation": "true",
                },
            )
            if not page:
                break
            members.extend(page)
            if len(page) < page_size:
                break
            first += page_size
        return members


class OpenFGAClient:
    def __init__(self, base_url: str, store_name: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.store_name = store_name
        self.token = token
        self._store_id: str | None = None
        self._model_id: str | None = None
        self._model: dict[str, Any] | None = None

    def request(self, method: str, path: str, data: Any | None = None) -> Any:
        return json_request(method, f"{self.base_url}{path}", token=self.token, data=data)

    def store_id(self) -> str:
        if self._store_id is None:
            stores = self.request("GET", "/stores").get("stores", [])
            for store in stores:
                if store.get("name") == self.store_name:
                    self._store_id = store["id"]
                    break
            if self._store_id is None:
                raise MigrationError(f"OpenFGA store {self.store_name!r} was not found")
        return self._store_id

    def latest_model_id(self) -> str:
        if self._model_id is None:
            response = self.request(
                "GET",
                f"/stores/{self.store_id()}/authorization-models?page_size=1",
            )
            models = response.get("authorization_models", [])
            if not models:
                raise MigrationError(f"OpenFGA store {self.store_name!r} has no authorization model")
            self._model = models[0]
            self._model_id = models[0]["id"]
        return self._model_id

    def latest_model(self) -> dict[str, Any]:
        self.latest_model_id()
        assert self._model is not None
        return self._model

    def create_authorization_model(self, model: dict[str, Any]) -> str:
        response = self.request("POST", f"/stores/{self.store_id()}/authorization-models", model)
        model_id = response.get("authorization_model_id")
        if not model_id:
            raise MigrationError("OpenFGA did not return an authorization_model_id")
        self._model_id = None
        self._model = None
        return model_id

    def tuple_exists(self, user: str, relation: str, object_: str) -> bool:
        response = self.request(
            "POST",
            f"/stores/{self.store_id()}/read",
            {
                "tuple_key": {
                    "user": user,
                    "relation": relation,
                    "object": object_,
                },
                "page_size": 1,
            },
        )
        return bool(response.get("tuples"))

    def list_tuples(self) -> list[dict[str, str]]:
        tuples: list[dict[str, str]] = []
        token = ""
        while True:
            payload: dict[str, Any] = {"page_size": 200}
            if token:
                payload["continuation_token"] = token
            response = self.request("POST", f"/stores/{self.store_id()}/read", payload)
            for entry in response.get("tuples", []):
                key = entry.get("key") or {}
                if {"user", "relation", "object"} <= set(key):
                    tuples.append(
                        {
                            "user": key["user"],
                            "relation": key["relation"],
                            "object": key["object"],
                        }
                    )
            token = response.get("continuation_token") or ""
            if not token:
                break
        return tuples

    def write_tuples(self, tuples: list[dict[str, str]]) -> int:
        if not tuples:
            return 0
        batch_size = 50
        written = 0
        model_id = self.latest_model_id()
        for start in range(0, len(tuples), batch_size):
            batch = tuples[start : start + batch_size]
            self.request(
                "POST",
                f"/stores/{self.store_id()}/write",
                {
                    "authorization_model_id": model_id,
                    "writes": {"tuple_keys": batch},
                },
            )
            written += len(batch)
        return written

    def model_has_relation(self, type_name: str, relation: str) -> bool:
        for type_def in self.latest_model().get("type_definitions", []):
            if type_def.get("type") == type_name:
                return relation in (type_def.get("relations") or {})
        return False


def normalize_authorization_model(model: dict[str, Any]) -> str:
    normalized = json.loads(json.dumps(model, sort_keys=True))
    normalized.pop("id", None)
    normalized.pop("authorization_model_id", None)
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def model_payload_has_relation(model: dict[str, Any], type_name: str, relation: str) -> bool:
    for type_def in model.get("type_definitions", []):
        if type_def.get("type") == type_name:
            return relation in (type_def.get("relations") or {})
    return False


def target_model_requirements(args: argparse.Namespace) -> list[tuple[str, str]]:
    return [
        ("team", args.target_team_admin_relation),
        ("team", args.target_team_editor_relation),
        ("team", args.target_team_member_relation),
        ("organization", "platform_admin"),
        ("organization", "platform_observer"),
    ]


def user_ref(user_id: str) -> str:
    return f"user:{user_id}"


def team_object(team_id: str) -> str:
    return f"team:{team_id}"


def parse_user_object(ref: str) -> str | None:
    if not ref.startswith("user:"):
        return None
    subject = ref.removeprefix("user:")
    if "#" in subject:
        return None
    return subject


def parse_team_object(ref: str) -> str | None:
    if not ref.startswith("team:"):
        return None
    return ref.removeprefix("team:")


def unique_tuple(items: list[dict[str, Any]], item: dict[str, Any]) -> None:
    key = (item["user"], item["relation"], item["object"])
    if any((existing["user"], existing["relation"], existing["object"]) == key for existing in items):
        return
    items.append(item)


def resolve_user(
    user_input: str,
    users_by_id: dict[str, dict[str, Any]],
    users_by_username: dict[str, dict[str, Any]],
) -> dict[str, Any] | None:
    clean = user_input.removeprefix("user:")
    return users_by_id.get(clean) or users_by_username.get(clean)


def collect_inventory(args: argparse.Namespace) -> dict[str, Any]:
    env_file = load_env_file(Path(args.env_file))
    keycloak = KeycloakClient(
        args.keycloak_url or first_setting(env_file, ("KEYCLOAK_SERVER_URL",), DEFAULT_KEYCLOAK_URL),
        args.realm or first_setting(env_file, ("KEYCLOAK_REALM",), DEFAULT_KEYCLOAK_REALM),
        args.kc_admin_user
        or first_setting(env_file, ("KC_BOOTSTRAP_ADMIN_USERNAME", "KEYCLOAK_ADMIN"), DEFAULT_KEYCLOAK_ADMIN_USER),
        args.kc_admin_password
        or first_setting(
            env_file,
            ("KC_BOOTSTRAP_ADMIN_PASSWORD", "KEYCLOAK_ADMIN_PASSWORD"),
            DEFAULT_KEYCLOAK_ADMIN_PASSWORD,
        ),
        args.client_id or first_setting(env_file, ("KEYCLOAK_CLIENT_ID",), DEFAULT_KEYCLOAK_CLIENT_ID),
    )
    openfga = OpenFGAClient(
        args.openfga_url or first_setting(env_file, ("OPENFGA_URL",), DEFAULT_OPENFGA_URL),
        args.openfga_store or first_setting(env_file, ("OPENFGA_STORE_NAME",), DEFAULT_OPENFGA_STORE),
        args.openfga_token or first_setting(env_file, ("OPENFGA_API_TOKEN",), DEFAULT_OPENFGA_TOKEN),
    )

    users = keycloak.list_users()
    users_by_id = {user["id"]: user for user in users}
    users_by_username = {user["username"]: user for user in users if user.get("username")}

    role_map: dict[str, list[str]] = {}
    for user in users:
        role_map[user["id"]] = keycloak.user_client_roles(user["id"])

    groups = keycloak.list_groups()
    group_members: dict[str, list[str]] = {}
    for group in groups:
        members = keycloak.group_members(group["id"])
        group_members[group["id"]] = [member["id"] for member in members if member.get("id")]

    fga_tuples = openfga.list_tuples()
    legacy_by_team_user: dict[tuple[str, str], set[str]] = {}
    unknown_subjects: list[str] = []
    for item in fga_tuples:
        team_id = parse_team_object(item["object"])
        subject = parse_user_object(item["user"])
        if not team_id or subject is None or item["relation"] not in LEGACY_TEAM_RELATIONS:
            continue
        resolved = resolve_user(subject, users_by_id, users_by_username)
        if not resolved:
            unknown_subjects.append(item["user"])
            continue
        legacy_by_team_user.setdefault((team_id, resolved["id"]), set()).add(item["relation"])

    model_warnings = []
    for relation in (args.target_team_admin_relation, args.target_team_editor_relation, args.target_team_member_relation):
        if not openfga.model_has_relation("team", relation):
            model_warnings.append(f"OpenFGA model does not expose team relation {relation!r}")
    for relation in PLATFORM_RELATIONS:
        if not openfga.model_has_relation("organization", relation):
            model_warnings.append(f"OpenFGA model does not expose organization relation {relation!r}")

    return {
        "created_at": utc_now(),
        "source": {
            "keycloak_url": keycloak.base_url,
            "realm": keycloak.realm,
            "client_id": keycloak.client_id,
            "openfga_url": openfga.base_url,
            "openfga_store": openfga.store_name,
            "openfga_store_id": openfga.store_id(),
            "openfga_model_id": openfga.latest_model_id(),
        },
        "users": [
            {
                "id": user["id"],
                "username": user.get("username"),
                "email": user.get("email"),
                "enabled": user.get("enabled"),
                "client_roles": role_map.get(user["id"], []),
            }
            for user in sorted(users, key=lambda item: item.get("username") or item["id"])
        ],
        "teams": [
            {
                "id": group["id"],
                "name": group["name"],
                "path": group["path"],
                "keycloak_member_ids": sorted(group_members.get(group["id"], [])),
            }
            for group in sorted(groups, key=lambda item: item.get("path") or item["id"])
        ],
        "legacy_team_roles": [
            {
                "team_id": team_id,
                "user_id": user_id,
                "relations": sorted(relations),
            }
            for (team_id, user_id), relations in sorted(legacy_by_team_user.items())
        ],
        "unknown_legacy_subjects": sorted(set(unknown_subjects)),
        "model_warnings": model_warnings,
    }


def build_plan(args: argparse.Namespace) -> dict[str, Any]:
    inventory = collect_inventory(args)
    users_by_id = {user["id"]: user for user in inventory["users"]}
    users_by_username = {user["username"]: user for user in inventory["users"] if user.get("username")}
    team_by_id = {team["id"]: team for team in inventory["teams"]}
    legacy_by_team_user = {
        (entry["team_id"], entry["user_id"]): set(entry["relations"])
        for entry in inventory["legacy_team_roles"]
    }
    all_team_ids = set(team_by_id)
    all_team_ids.update(team_id for team_id, _user_id in legacy_by_team_user)

    planned: list[dict[str, Any]] = []
    warnings = list(inventory["model_warnings"])
    errors: list[str] = []

    def add_tuple(user_id: str, relation: str, object_: str, reason: str) -> None:
        user = users_by_id[user_id]
        unique_tuple(
            planned,
            {
                "user": user_ref(user_id),
                "relation": relation,
                "object": object_,
                "reason": reason,
                "username": user.get("username"),
            },
        )

    for raw_admin in args.platform_admin:
        user = resolve_user(raw_admin, users_by_id, users_by_username)
        if not user:
            errors.append(f"platform admin {raw_admin!r} does not match a Keycloak user id or username")
            continue
        add_tuple(user["id"], "platform_admin", ORGANIZATION_OBJECT, "explicit operator platform admin")

    for raw_observer in args.platform_observer:
        user = resolve_user(raw_observer, users_by_id, users_by_username)
        if not user:
            errors.append(f"platform observer {raw_observer!r} does not match a Keycloak user id or username")
            continue
        add_tuple(user["id"], "platform_observer", ORGANIZATION_OBJECT, "explicit operator platform observer")

    if not args.platform_admin:
        warnings.append("no platform admin was provided; Swift may start with no platform admin")

    for team_id in sorted(all_team_ids):
        team = team_by_id.get(team_id)
        team_members = set(team["keycloak_member_ids"]) if team else set()
        legacy_members = {user_id for current_team_id, user_id in legacy_by_team_user if current_team_id == team_id}
        user_ids = sorted(team_members | legacy_members)
        team_admin_count = 0

        for user_id in user_ids:
            if user_id not in users_by_id:
                errors.append(f"team {team_id} references unknown Keycloak user {user_id}")
                continue
            legacy_relations = legacy_by_team_user.get((team_id, user_id), set())
            client_roles = set(users_by_id[user_id].get("client_roles", []))
            object_ = team_object(team_id)

            if "owner" in legacy_relations:
                add_tuple(user_id, args.target_team_admin_relation, object_, "legacy owner -> team admin")
                team_admin_count += 1
            if "manager" in legacy_relations or (
                args.map_keycloak_editor_to_team_editor
                and "editor" in client_roles
                and user_id in team_members
            ):
                add_tuple(user_id, args.target_team_editor_relation, object_, "legacy manager/editor -> team editor")
            if legacy_relations or user_id in team_members:
                add_tuple(user_id, args.target_team_member_relation, object_, "team membership preserved")

        if not team:
            warnings.append(f"team {team_id} exists in legacy OpenFGA tuples but not in Keycloak groups")
        if team_admin_count == 0 and not args.allow_zero_team_admin:
            errors.append(f"team {team_id} has no legacy owner to migrate to team admin")

    openfga = OpenFGAClient(
        inventory["source"]["openfga_url"],
        inventory["source"]["openfga_store"],
        args.openfga_token or first_setting(load_env_file(Path(args.env_file)), ("OPENFGA_API_TOKEN",), DEFAULT_OPENFGA_TOKEN),
    )
    for item in planned:
        item["status"] = "exists" if openfga.tuple_exists(item["user"], item["relation"], item["object"]) else "missing"

    plan = {
        "version": 1,
        "created_at": utc_now(),
        "mode": "additive-openfga-rbac-rebac-migration",
        "source": inventory["source"],
        "target_relations": {
            "team_admin": args.target_team_admin_relation,
            "team_editor": args.target_team_editor_relation,
            "team_member": args.target_team_member_relation,
            "platform_admin": "platform_admin",
            "platform_observer": "platform_observer",
        },
        "options": {
            "map_keycloak_editor_to_team_editor": args.map_keycloak_editor_to_team_editor,
            "allow_zero_team_admin": args.allow_zero_team_admin,
        },
        "users": inventory["users"],
        "teams": inventory["teams"],
        "legacy_team_roles": inventory["legacy_team_roles"],
        "tuples": sorted(planned, key=lambda item: (item["object"], item["relation"], item["user"])),
        "warnings": sorted(set(warnings)),
        "errors": sorted(set(errors)),
        "unknown_legacy_subjects": inventory["unknown_legacy_subjects"],
    }
    return plan


def load_plan(path: str) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        plan = json.load(handle)
    if plan.get("version") != 1:
        raise MigrationError(f"unsupported plan version in {path}")
    return plan


def openfga_from_plan(args: argparse.Namespace, plan: dict[str, Any]) -> OpenFGAClient:
    env_file = load_env_file(Path(args.env_file))
    return OpenFGAClient(
        args.openfga_url or plan["source"]["openfga_url"],
        args.openfga_store or plan["source"]["openfga_store"],
        args.openfga_token or first_setting(env_file, ("OPENFGA_API_TOKEN",), DEFAULT_OPENFGA_TOKEN),
    )


def assert_target_model(args: argparse.Namespace, openfga: OpenFGAClient, plan: dict[str, Any]) -> list[str]:
    missing: list[str] = []
    target = plan.get("target_relations", {})
    for type_name, relation in (
        ("team", target.get("team_admin")),
        ("team", target.get("team_editor")),
        ("team", target.get("team_member")),
        ("organization", target.get("platform_admin")),
        ("organization", target.get("platform_observer")),
    ):
        if relation and not openfga.model_has_relation(type_name, relation):
            missing.append(f"{type_name}#{relation}")
    if missing and not args.allow_missing_target_relations:
        raise MigrationError(
            "current OpenFGA model does not contain target relations: "
            + ", ".join(missing)
            + ". Install the Swift OpenFGA model first, then rerun apply."
        )
    return missing


def install_model(args: argparse.Namespace) -> dict[str, Any]:
    model_path = Path(args.model_file)
    if not model_path.exists():
        raise MigrationError(f"model file was not found: {model_path}")
    model = json.loads(model_path.read_text(encoding="utf-8"))

    missing_from_file = [
        f"{type_name}#{relation}"
        for type_name, relation in target_model_requirements(args)
        if not model_payload_has_relation(model, type_name, relation)
    ]
    if missing_from_file and not args.allow_missing_target_relations:
        raise MigrationError(
            f"model file {model_path} is missing target relations: "
            + ", ".join(missing_from_file)
            + ". Update the canonical schema in fred first, regenerate schema.fga.json, "
            + "then run make sync-openfga-model."
        )

    env_file = load_env_file(Path(args.env_file))
    openfga = OpenFGAClient(
        args.openfga_url or first_setting(env_file, ("OPENFGA_URL",), DEFAULT_OPENFGA_URL),
        args.openfga_store or first_setting(env_file, ("OPENFGA_STORE_NAME",), DEFAULT_OPENFGA_STORE),
        args.openfga_token or first_setting(env_file, ("OPENFGA_API_TOKEN",), DEFAULT_OPENFGA_TOKEN),
    )

    current_id = ""
    current_model: dict[str, Any] | None = None
    try:
        current_id = openfga.latest_model_id()
        current_model = openfga.latest_model()
    except MigrationError as exc:
        if "has no authorization model" not in str(exc):
            raise

    changed = current_model is None or normalize_authorization_model(current_model) != normalize_authorization_model(model)
    new_model_id = current_id
    if changed and not args.dry_run:
        new_model_id = openfga.create_authorization_model(model)

    return {
        "model_file": str(model_path),
        "store": openfga.store_name,
        "store_id": openfga.store_id(),
        "previous_model_id": current_id,
        "authorization_model_id": new_model_id,
        "changed": changed,
        "dry_run": args.dry_run,
        "missing_from_file": missing_from_file,
    }


def apply_plan(args: argparse.Namespace) -> dict[str, Any]:
    plan = load_plan(args.plan)
    if plan.get("errors"):
        raise MigrationError("plan contains errors; fix them or regenerate the plan before apply")
    openfga = openfga_from_plan(args, plan)
    missing_relations = assert_target_model(args, openfga, plan)
    tuples_to_write: list[dict[str, str]] = []

    for item in plan["tuples"]:
        key = {
            "user": item["user"],
            "relation": item["relation"],
            "object": item["object"],
        }
        if openfga.tuple_exists(key["user"], key["relation"], key["object"]):
            continue
        tuples_to_write.append(key)

    if args.dry_run:
        written = 0
    else:
        written = openfga.write_tuples(tuples_to_write)

    return {
        "checked": len(plan["tuples"]),
        "to_write": len(tuples_to_write),
        "written": written,
        "dry_run": args.dry_run,
        "missing_model_relations": missing_relations,
    }


def validate_plan(args: argparse.Namespace) -> dict[str, Any]:
    plan = load_plan(args.plan)
    openfga = openfga_from_plan(args, plan)
    missing_relations = assert_target_model(args, openfga, plan)
    missing_tuples = []
    for item in plan["tuples"]:
        if not openfga.tuple_exists(item["user"], item["relation"], item["object"]):
            missing_tuples.append(
                {
                    "user": item["user"],
                    "relation": item["relation"],
                    "object": item["object"],
                    "username": item.get("username"),
                }
            )

    team_member_relation = plan["target_relations"]["team_member"]
    migrated_team_members = {
        (item["object"], item["user"])
        for item in plan["tuples"]
        if item["object"].startswith("team:") and item["relation"] == team_member_relation
    }
    team_group_members = {
        (team_object(team["id"]), user_ref(user_id))
        for team in plan["teams"]
        for user_id in team.get("keycloak_member_ids", [])
    }
    lost_members = sorted(team_group_members - migrated_team_members)

    team_admin_relation = plan["target_relations"]["team_admin"]
    teams_without_admin = []
    if not plan["options"].get("allow_zero_team_admin"):
        for team in plan["teams"]:
            object_ = team_object(team["id"])
            if not any(
                item["object"] == object_ and item["relation"] == team_admin_relation
                for item in plan["tuples"]
            ):
                teams_without_admin.append({"id": team["id"], "name": team.get("name")})

    ok = not missing_tuples and not lost_members and not teams_without_admin and not missing_relations
    return {
        "ok": ok,
        "planned_tuples": len(plan["tuples"]),
        "missing_tuples": missing_tuples,
        "lost_team_members": [{"object": item[0], "user": item[1]} for item in lost_members],
        "teams_without_admin": teams_without_admin,
        "missing_model_relations": missing_relations,
    }


def print_plan_summary(plan: dict[str, Any]) -> None:
    missing = sum(1 for item in plan["tuples"] if item.get("status") == "missing")
    existing = sum(1 for item in plan["tuples"] if item.get("status") == "exists")
    print("Swift authz migration plan")
    print(f"  users: {len(plan['users'])}")
    print(f"  teams: {len(plan['teams'])}")
    print(f"  tuples: {len(plan['tuples'])} ({missing} missing, {existing} already present)")
    print(f"  warnings: {len(plan['warnings'])}")
    print(f"  errors: {len(plan['errors'])}")
    for message in plan["warnings"][:10]:
        print(f"  warning: {message}")
    for message in plan["errors"][:10]:
        print(f"  error: {message}")
    if plan["unknown_legacy_subjects"]:
        print(f"  unknown legacy subjects: {len(plan['unknown_legacy_subjects'])}")


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE), help="env file to read defaults from")
    parser.add_argument("--keycloak-url", default=None, help="Keycloak base URL")
    parser.add_argument("--realm", default=None, help="Keycloak realm")
    parser.add_argument("--client-id", default=None, help="Keycloak client id that contains legacy app roles")
    parser.add_argument("--kc-admin-user", default=None, help="Keycloak admin username")
    parser.add_argument("--kc-admin-password", default=None, help="Keycloak admin password")
    parser.add_argument("--openfga-url", default=None, help="OpenFGA base URL")
    parser.add_argument("--openfga-store", default=None, help="OpenFGA store name")
    parser.add_argument("--openfga-token", default=None, help="OpenFGA bearer token")
    parser.add_argument("--allow-missing-target-relations", action="store_true", help=argparse.SUPPRESS)


def add_planning_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--platform-admin", action="append", default=[], help="Keycloak username/id to map as platform_admin")
    parser.add_argument(
        "--platform-observer",
        action="append",
        default=[],
        help="Keycloak username/id to map as platform_observer",
    )
    parser.add_argument(
        "--target-team-admin-relation",
        default="team_admin",
        help="target OpenFGA relation for team admins",
    )
    parser.add_argument(
        "--target-team-editor-relation",
        default="team_editor",
        help="target OpenFGA relation for team editors",
    )
    parser.add_argument(
        "--target-team-member-relation",
        default="team_member",
        help="target OpenFGA relation for team members",
    )
    parser.add_argument(
        "--no-keycloak-editor-mapping",
        dest="map_keycloak_editor_to_team_editor",
        action="store_false",
        help="do not map Keycloak editor app-role users to team_editor within their Keycloak teams",
    )
    parser.set_defaults(map_keycloak_editor_to_team_editor=True)
    parser.add_argument(
        "--allow-zero-team-admin",
        action="store_true",
        help="allow teams that have no legacy owner/team_admin candidate",
    )


def add_target_relation_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--target-team-admin-relation",
        default="team_admin",
        help="target OpenFGA relation for team admins",
    )
    parser.add_argument(
        "--target-team-editor-relation",
        default="team_editor",
        help="target OpenFGA relation for team editors",
    )
    parser.add_argument(
        "--target-team-member-relation",
        default="team_member",
        help="target OpenFGA relation for team members",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Additive OpenFGA authz migration helper for Swift.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory = subparsers.add_parser("inventory", help="read Keycloak/OpenFGA inventory and print JSON")
    add_common_args(inventory)

    install = subparsers.add_parser("install-model", help="install an OpenFGA model JSON file")
    add_common_args(install)
    add_target_relation_args(install)
    install.add_argument(
        "--model-file",
        default="docker/openfga/openfga-model.json",
        help="OpenFGA authorization model JSON file to upload",
    )
    install.add_argument("--dry-run", action="store_true", help="validate and compare without uploading")

    plan = subparsers.add_parser("plan", help="build an additive migration plan")
    add_common_args(plan)
    add_planning_args(plan)
    plan.add_argument("--out", required=True, help="path where the JSON plan should be written")

    apply = subparsers.add_parser("apply", help="apply missing tuples from a plan")
    add_common_args(apply)
    apply.add_argument("--plan", required=True, help="plan JSON produced by the plan command")
    apply.add_argument("--dry-run", action="store_true", help="show how many tuples would be written")

    validate = subparsers.add_parser("validate", help="validate live OpenFGA against a plan")
    add_common_args(validate)
    validate.add_argument("--plan", required=True, help="plan JSON produced by the plan command")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "inventory":
            print(json.dumps(collect_inventory(args), indent=2, sort_keys=True))
            return 0
        if args.command == "install-model":
            result = install_model(args)
            print("Swift authz model install")
            print(f"  model_file: {result['model_file']}")
            print(f"  store: {result['store']} ({result['store_id']})")
            print(f"  previous_model_id: {result['previous_model_id']}")
            print(f"  authorization_model_id: {result['authorization_model_id']}")
            print(f"  changed: {result['changed']}")
            print(f"  dry_run: {result['dry_run']}")
            return 0
        if args.command == "plan":
            plan = build_plan(args)
            output_path = Path(args.out)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print_plan_summary(plan)
            print(f"  wrote: {output_path}")
            return 1 if plan["errors"] else 0
        if args.command == "apply":
            result = apply_plan(args)
            print("Swift authz migration apply")
            print(f"  checked: {result['checked']}")
            print(f"  to_write: {result['to_write']}")
            print(f"  written: {result['written']}")
            print(f"  dry_run: {result['dry_run']}")
            return 0
        if args.command == "validate":
            result = validate_plan(args)
            print("Swift authz migration validation")
            print(f"  ok: {result['ok']}")
            print(f"  planned_tuples: {result['planned_tuples']}")
            print(f"  missing_tuples: {len(result['missing_tuples'])}")
            print(f"  lost_team_members: {len(result['lost_team_members'])}")
            print(f"  teams_without_admin: {len(result['teams_without_admin'])}")
            return 0 if result["ok"] else 1
        parser.error(f"unknown command {args.command}")
        return 2
    except MigrationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
