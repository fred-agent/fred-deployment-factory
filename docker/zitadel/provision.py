#!/usr/bin/env python3
"""Provision the isolated local provider and generate Fred configs, without logging secrets."""

import argparse
import base64
import json
import os
import secrets
import shlex
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

import jsonschema
import yaml

ISSUER = "http://localhost:8091"
HERE = Path(__file__).resolve().parent
DEFAULT_FRED_ROOT = HERE.parents[2] / "fred"
APPS = {
    "control-plane-backend": "control-plane",
    "knowledge-flow-backend": "knowledge-flow",
    "fred-agents": "agentic",
}
HTTP = build_opener(ProxyHandler({}))


def request(path, body=None, method="POST", token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    payload = json.dumps(body).encode() if body is not None else None
    try:
        with HTTP.open(
            Request(ISSUER + path, payload, headers, method=method), timeout=20
        ) as response:
            return json.load(response)
    except HTTPError as error:
        if path.startswith("/management/v1/flows/") and error.code == 400:
            failure = json.load(error)
            if any(
                detail.get("id") == "COMMAND-Nfh52"
                for detail in failure.get("details", [])
            ):
                return {}  # The identical action is already attached to this trigger.
        raise RuntimeError(
            f"ZITADEL {method} {path}: HTTP {error.code}; inspect provider logs"
        ) from None


def workload_scope(name, audience_scope):
    roles = ["service_agent"] + (["delegation_caller"] if name == "agentic" else [])
    return (
        "openid "
        + audience_scope
        + " "
        + " ".join("urn:zitadel:iam:org:project:role:" + role for role in roles)
    )


def check_workload_tokens(services, scope, audience):
    for name, credentials in services.items():
        payload = urlencode(
            {
                "grant_type": "client_credentials",
                "scope": workload_scope(name, scope),
                "client_id": credentials["clientId"],
                "client_secret": credentials["clientSecret"],
            }
        ).encode()
        req = Request(
            ISSUER + "/oauth/v2/token",
            payload,
            {"Content-Type": "application/x-www-form-urlencoded"},
        )
        try:
            with HTTP.open(req, timeout=20) as response:
                token = json.load(response)["access_token"]
            # Structural smoke check; Fred validates signatures when it starts.
            part = token.split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        except (HTTPError, KeyError, IndexError, ValueError):
            raise RuntimeError(f"Workload token issuance failed for {name}") from None
        audiences = claims.get("aud", [])
        if isinstance(audiences, str):
            audiences = [audiences]
        roles = set(claims.get("roles", []))
        required = {"service_agent"} | (
            {"delegation_caller"} if name == "agentic" else set()
        )
        if (
            claims.get("iss") != ISSUER
            or audience not in audiences
            or not required <= roles
        ):
            raise RuntimeError(f"Unexpected issuer, audience or roles for {name}")
        if (claims.get("azp") or claims.get("client_id")) != credentials["clientId"]:
            raise RuntimeError(f"Unexpected client identity for {name}")
        if name != "agentic" and "delegation_caller" in roles:
            raise RuntimeError(f"Unexpected delegation privilege for {name}")
        print(f"Workload token claims checked: {name} (token not displayed)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fred-root", type=Path, default=DEFAULT_FRED_ROOT)
    parser.add_argument(
        "--output-dir", type=Path, default=Path("/tmp/fred-idp-tests/zitadel")
    )
    args = parser.parse_args()
    root, output = args.fred_root.resolve(), args.output_dir.resolve()
    os.umask(0o077)
    token = (HERE / "state/operator.pat").read_text().strip()
    if not token:
        raise RuntimeError("Missing bootstrap operator PAT")
    # Fred rejects tokens whose issued lifetime exceeds its admission ceiling.
    settings = request("/admin/v1/settings/oidc", method="GET", token=token)["settings"]
    if any(
        settings.get(field) != "3600s"
        for field in ("accessTokenLifetime", "idTokenLifetime")
    ):
        request(
            "/admin/v1/settings/oidc",
            {
                "accessTokenLifetime": "3600s",
                "idTokenLifetime": "3600s",
                "refreshTokenIdleExpiration": settings["refreshTokenIdleExpiration"],
                "refreshTokenExpiration": settings["refreshTokenExpiration"],
            },
            method="PUT",
            token=token,
        )
    state_file = HERE / "state/provision.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}

    def ensure(key, path, body, method="POST"):
        if key not in state:
            state[key] = request("/management/v1" + path, body, method, token)
            state_file.write_text(json.dumps(state, indent=2))
        return state[key]

    login_file = HERE / "state/admin-login.json"
    if not login_file.exists():
        login_file.write_text(
            json.dumps(
                {
                    "username": "fred-admin@zitadel.localhost",
                    "password": "Fred!" + secrets.token_hex(20),
                }
            )
        )
    login = json.loads(login_file.read_text())
    admin = ensure(
        "console-admin",
        "/users/human",
        {
            "userName": "fred-admin",
            "profile": {"firstName": "Fred", "lastName": "Local Admin"},
            "email": {"email": "fred-admin@example.test", "isEmailVerified": True},
            "initialPassword": login["password"],
        },
    )["userId"]
    if "console-admin-role" not in state:
        state["console-admin-role"] = request(
            "/admin/v1/members", {"userId": admin, "roles": ["IAM_OWNER"]}, token=token
        )
        state_file.write_text(json.dumps(state, indent=2))
    admin_user = request("/management/v1/users/" + admin, method="GET", token=token)[
        "user"
    ]
    login["username"] = admin_user["preferredLoginName"]
    login_file.write_text(json.dumps(login, indent=2))

    project = ensure(
        "project",
        "/projects",
        {"name": "Fred local OIDC", "projectRoleAssertion": True},
    )["id"]
    # Refuse stale provisioning state after the isolated provider was wiped.
    request("/management/v1/projects/" + project, method="GET", token=token)
    for role in ("service_agent", "delegation_caller"):
        ensure(
            "role-" + role,
            f"/projects/{project}/roles",
            {"roleKey": role, "displayName": role},
        )
    spa = ensure(
        "spa",
        f"/projects/{project}/apps/oidc",
        {
            "name": "Fred SPA",
            "redirectUris": ["http://localhost:5173/"],
            "postLogoutRedirectUris": ["http://localhost:5173/"],
            "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
            "grantTypes": [
                "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
                "OIDC_GRANT_TYPE_REFRESH_TOKEN",
            ],
            "appType": "OIDC_APP_TYPE_USER_AGENT",
            "authMethodType": "OIDC_AUTH_METHOD_TYPE_NONE",
            "accessTokenType": "OIDC_TOKEN_TYPE_JWT",
            "accessTokenRoleAssertion": True,
            "idTokenUserinfoAssertion": True,
            "devMode": True,
        },
    )["clientId"]
    services = {}
    for name in APPS.values():
        user = ensure(
            "user-" + name,
            "/users/machine",
            {
                "userName": name,
                "name": name,
                "accessTokenType": "ACCESS_TOKEN_TYPE_JWT",
            },
        )["userId"]
        services[name] = ensure("secret-" + name, f"/users/{user}/secret", {}, "PUT")
        roles = ["service_agent"] + (["delegation_caller"] if name == "agentic" else [])
        ensure(
            "grant-" + name,
            f"/users/{user}/grants",
            {"projectId": project, "roleKeys": roles},
        )
    action = (HERE / "claims.js").read_text().replace("FRED_PROJECT_ID", project)
    client_ids = {
        state["user-" + name]["userId"]: values["clientId"]
        for name, values in services.items()
    }
    action = action.replace("FRED_SERVICE_CLIENTS", json.dumps(client_ids))
    action_id = ensure(
        "action",
        "/actions",
        {
            "name": "fredClaims",
            "script": action,
            "timeout": "5s",
            "allowedToFail": False,
        },
    )["id"]
    for trigger in ("4", "5"):
        request(
            f"/management/v1/flows/2/trigger/{trigger}",
            {"actionIds": [action_id]},
            token=token,
        )
    scope = f"urn:zitadel:iam:org:project:id:{project}:aud"
    # Verify the discovered issuer before publishing configurations.
    discovery = request("/.well-known/openid-configuration", method="GET")
    if discovery.get("issuer") != ISSUER:
        raise RuntimeError("Discovered issuer does not match localhost:8091")
    check_workload_tokens(services, scope, project)
    pending = []
    for app, service in APPS.items():
        config_dir = root / "apps" / app / "config"
        config = yaml.safe_load((config_dir / "configuration_prod.yaml").read_text())
        config["app"]["gcu_version"] = "v1"
        security = config["security"]
        security["user_directory"] = "local"
        security["user"].update(
            provider="oidc",
            realm_url=ISSUER,
            client_id=spa,
            audience=project,
            scope=scope,
            roles_claim=["roles"],
        )
        secret_var = "ZITADEL_" + service.upper().replace("-", "_") + "_CLIENT_SECRET"
        security["m2m"].update(
            provider="oidc",
            realm_url=ISSUER,
            client_id=services[service]["clientId"],
            scope=workload_scope(service, scope),
            secret_env_var=secret_var,
        )
        security["delegation"].update(
            act_for_people=app == "fred-agents",
            accept_delegated_calls=app != "fred-agents",
            caller_roles_claim=["roles"],
            audience=project,
            service_accounts_only=False,
        )
        jsonschema.validate(
            config,
            json.loads((config_dir / "schema/configuration.schema.json").read_text()),
        )
        pending.append(
            (
                output / f"configuration_{app}.yaml",
                yaml.safe_dump(config, sort_keys=False),
            )
        )
    catalog = (
        root / "apps/control-plane-backend/config/conversation_policy_catalog.yaml"
    )
    pending.append((output / catalog.name, catalog.read_text()))
    credentials = (
        "\n".join(
            "export ZITADEL_"
            + name.upper().replace("-", "_")
            + "_CLIENT_SECRET="
            + shlex.quote(value["clientSecret"])
            for name, value in services.items()
        )
        + "\n"
    )
    pending.append((output / "service-credentials.env", credentials))
    output.mkdir(parents=True, exist_ok=True)
    for path, content in pending:
        path.write_text(content)
        path.chmod(0o600)
    print(f"ZITADEL configured; Fred configs and private service environment: {output}")
    print(
        "Console: http://localhost:8091/ui/console — login details: docker/zitadel/state/admin-login.json"
    )


if __name__ == "__main__":
    main()
