#!/usr/bin/env python3
"""Provision Fred's ZITADEL Cloud project and render the private k3d overlay."""

import argparse
import base64
import json
import os
import shutil
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

import yaml

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "docker/zitadel/state/cloud.json"
VALUES = ROOT / "docker/zitadel/state/cloud-values.json"
# Tracked on purpose: the fred-lab tester bundle, so a checkout deploys with OPENAI_API_KEY only.
LAB_BUNDLE = ROOT / "docker/zitadel/fred-lab-bundle.json"
LAB_DISCLAIMER = (
    "PUBLIC LAB CREDENTIALS, NOT A SECRET STORE. These fred-lab ZITADEL service-account "
    "secrets are deliberately public so that anyone can run a local Fred test instance. "
    "Use them only with Fred bound to localhost; never expose its port or use them in production."
)
APPS = {
    "fred-agents": "agentic",
    "knowledge-flow-backend": "knowledge-flow",
    "control-plane-backend": "control-plane",
}
ISSUER_DEFAULT = "https://fred-lab-instance-qeuzio.ch1.zitadel.cloud"


def fail(message):
    raise RuntimeError(message)


def checked_urls(issuer, fred_url):
    issuer, fred_url = issuer.rstrip("/"), fred_url.rstrip("/")
    idp, app = urlsplit(issuer), urlsplit(fred_url)
    if idp.scheme != "https" or not idp.hostname or idp.path or idp.query or idp.fragment:
        fail("ZITADEL_ISSUER must be the HTTPS origin of the Cloud instance")
    if app.scheme != "http" or app.hostname != "localhost" or app.query or app.fragment or app.path:
        fail("FRED_URL must be a local HTTP origin, for example http://localhost:5173")
    return issuer, fred_url


def api(issuer, path, token=None, body=None, method=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    req = Request(issuer + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        detail = error.read().decode(errors="replace")[:300]
        fail(f"ZITADEL {method or 'GET'} {path}: HTTP {error.code} {detail}; check PAT rights and Cloud settings")
    except URLError as error:
        fail(f"Cannot reach ZITADEL at {issuer}: {error.reason}")


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_suffix(".tmp")
    with temporary.open("w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(state, stream, indent=2)
    temporary.replace(STATE)


def ensure(state, key, issuer, pat, path, body, method="POST"):
    if key not in state:
        state[key] = api(issuer, "/management/v1" + path, pat, body, method)
        save_state(state)
    return state[key]


def workload_scope(name, audience_scope):
    roles = ["service_agent"] + (["delegation_caller"] if name == "agentic" else [])
    return "openid " + audience_scope + " " + " ".join(
        "urn:zitadel:iam:org:project:role:" + role for role in roles
    )


def check_workloads(issuer, services, audience, audience_scope):
    max_lifetime = 0
    for name, credential in services.items():
        data = urlencode({
            "grant_type": "client_credentials",
            "scope": workload_scope(name, audience_scope),
            "client_id": credential["clientId"],
            "client_secret": credential["clientSecret"],
        }).encode()
        req = Request(
            issuer + "/oauth/v2/token",
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        try:
            with urlopen(req, timeout=30) as response:
                token = json.load(response)["access_token"]
            part = token.split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        except (HTTPError, URLError, KeyError, IndexError, ValueError):
            fail(f"ZITADEL did not issue a usable workload token for {name}")
        audiences = claims.get("aud", [])
        if isinstance(audiences, str):
            audiences = [audiences]
        roles = set(claims.get("roles", []))
        required = {"service_agent"} | ({"delegation_caller"} if name == "agentic" else set())
        if (
            claims.get("iss") != issuer
            or audience not in audiences
            or not required <= roles
            or not isinstance(claims.get("sub"), str)
            or not claims["sub"]
            or (claims.get("azp") or claims.get("client_id")) != credential["clientId"]
            or (name != "agentic" and "delegation_caller" in roles)
        ):
            fail(f"ZITADEL workload claims are incomplete for {name}")
        lifetime = claims.get("exp", 0) - claims.get("iat", 0)
        if lifetime <= 0 or lifetime > 86400:
            fail(f"ZITADEL workload token lifetime for {name} is {lifetime}s; set Cloud access tokens to at most 24h")
        max_lifetime = max(max_lifetime, lifetime)
        print(f"Checked ZITADEL workload token: {name}")
    return max(5400, max_lifetime + 60)


def provision(issuer, fred_url, pat):
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    if state and (state.get("issuer"), state.get("fred_url")) != (issuer, fred_url):
        fail(f"Existing {STATE} belongs to another issuer or Fred URL; inspect before changing it")
    if not pat and not state:
        fail(f"Provide ZITADEL_PAT for initial setup or a private deployment bundle at {STATE}")
    discovery = api(issuer, "/.well-known/openid-configuration")
    if discovery.get("issuer") != issuer:
        fail("ZITADEL discovery issuer differs from ZITADEL_ISSUER")
    if not pat:
        try:
            project = state["project"]["id"]
            spa = state["spa"]["clientId"]
            services = {name: state["secret-" + name] for name in APPS.values()}
        except KeyError:
            fail(f"Deployment bundle {STATE} is incomplete; ask its owner to rerun provisioning")
        scope = f"urn:zitadel:iam:org:project:id:{project}:aud"
        lifetime = check_workloads(issuer, services, project, scope)
        return project, spa, services, scope, lifetime
    org = api(issuer, "/management/v1/orgs/me", pat).get("org", {})
    expected_org = os.environ.get("ZITADEL_ORG_NAME", "fred-lab")
    if org.get("name", "").casefold() != expected_org.casefold():
        fail(f"PAT belongs to organization {org.get('name', '<unknown>')!r}, expected {expected_org!r}")
    login_policy = api(issuer, "/management/v1/policies/login", pat).get("policy", {})
    if not login_policy.get("allowRegister"):
        fail("Enable 'Register allowed' for the fred-lab organization in ZITADEL before deploying")
    if not state:
        state = {"issuer": issuer, "fred_url": fred_url}
        save_state(state)
    project = ensure(
        state, "project", issuer, pat, "/projects",
        {"name": "Fred local k3d", "projectRoleAssertion": True},
    )["id"]
    api(issuer, "/management/v1/projects/" + project, pat)
    for role in ("service_agent", "delegation_caller"):
        ensure(
            state, "role-" + role, issuer, pat, f"/projects/{project}/roles",
            {"roleKey": role, "displayName": role},
        )
    spa = ensure(
        state, "spa", issuer, pat, f"/projects/{project}/apps/oidc",
        {
            "name": "Fred local browser",
            "redirectUris": [fred_url + "/"],
            "postLogoutRedirectUris": [fred_url + "/"],
            "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
            "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
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
        user_id = ensure(
            state, "user-" + name, issuer, pat, "/users/machine",
            {"userName": "fred-k3d-" + name, "name": "Fred k3d " + name,
             "accessTokenType": "ACCESS_TOKEN_TYPE_JWT"},
        )["userId"]
        services[name] = ensure(
            state, "secret-" + name, issuer, pat, f"/users/{user_id}/secret", {}, "PUT"
        )
        roles = ["service_agent"] + (["delegation_caller"] if name == "agentic" else [])
        ensure(
            state, "grant-" + name, issuer, pat, f"/users/{user_id}/grants",
            {"projectId": project, "roleKeys": roles},
        )
    source = (ROOT / "docker/zitadel/claims.js").read_text()
    client_ids = {
        state["user-" + name]["userId"]: credential["clientId"]
        for name, credential in services.items()
    }
    source = source.replace("FRED_PROJECT_ID", project)
    source = source.replace("FRED_SERVICE_CLIENTS", json.dumps(client_ids))
    source = source.replace("FRED_SPA_CLIENT_ID", spa)
    # ZITADEL runs the script function named like the action: keep both "fredClaims".
    action_body = {"name": "fredClaims", "script": source, "timeout": "5s", "allowedToFail": False}
    action = ensure(state, "action", issuer, pat, "/actions", action_body)["id"]
    try:
        api(issuer, "/management/v1/actions/" + action, pat, action_body, "PUT")
    except RuntimeError as error:
        if "ACTION-dg4t2" not in str(error):  # "No changes": the action is already up to date
            raise
    for trigger in ("4", "5"):
        ensure(
            state, "trigger-" + trigger, issuer, pat, f"/flows/2/trigger/{trigger}",
            {"actionIds": [action]},
        )
    audience_scope = f"urn:zitadel:iam:org:project:id:{project}:aud"
    jwt_lifetime = check_workloads(issuer, services, project, audience_scope)
    return project, spa, services, audience_scope, jwt_lifetime


def secret_env(name):
    return "ZITADEL_" + name.upper().replace("-", "_") + "_CLIENT_SECRET"


def render(issuer, fred_url, project, spa, services, audience_scope, jwt_lifetime=5400):
    base = yaml.safe_load((ROOT / "k3d-apps/fred/values.yaml").read_text())
    overlay = {"applications": {}}
    for app, name in APPS.items():
        security = {
            "user_directory": "local",
            "user": {
                "provider": "oidc", "realm_url": issuer, "client_id": spa,
                "audience": project, "scope": audience_scope, "roles_claim": ["roles"],
            },
            "m2m": {
                "provider": "oidc", "realm_url": issuer,
                "client_id": services[name]["clientId"],
                "scope": workload_scope(name, audience_scope),
                "secret_env_var": secret_env(name),
            },
            "delegation": {
                "caller_roles_claim": ["roles"], "audience": project,
                "service_accounts_only": False,
            },
            "authorized_origins": [fred_url],
        }
        env = []
        for item in base["applications"][app]["extraEnvVars"]:
            if item["name"].startswith("KEYCLOAK_"):
                env.append({
                    "name": secret_env(name),
                    "valueFrom": {"secretKeyRef": {
                        "name": "fred-secrets", "key": secret_env(name), "optional": False,
                    }},
                })
            else:
                env.append(item)
        if name == "knowledge-flow":
            # Knowledge-flow's startup check still names the Keycloak variable, whatever
            # m2m.secret_env_var says: expose the same secret under that name too.
            env.append({
                "name": "KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET",
                "valueFrom": {"secretKeyRef": {
                    "name": "fred-secrets", "key": secret_env(name), "optional": False,
                }},
            })
        # fred_core reads the ceiling from the process environment at import time, before
        # the .env file is loaded: it must be a container variable, not a dotenv entry.
        env.append({"name": "FRED_JWT_MAX_LIFETIME_SECONDS", "value": str(jwt_lifetime)})
        cloud_app = {
            "configuration": {"security": security, "app": {"gcu_version": "v1"}},
            "extraEnvVars": env,
        }
        overlay["applications"][app] = cloud_app
        if app != "fred-agents":
            worker = app.replace("-backend", "-worker")
            overlay["applications"][worker] = {
                "configuration": {"security": security, "app": {"gcu_version": "v1"}},
                "extraEnvVars": [item for item in env if item["name"] != "FRED_BOOTSTRAP_TOKEN"],
            }
    frontend = base["applications"]["frontend"]
    frontend_env = [dict(item) for item in frontend["env"]]
    for item in frontend_env:
        if item["name"] == "VITE_BACKEND_URL_KNOWLEDGE":
            item["value"] = fred_url
    paths = [path for path in frontend["ingress"]["hosts"][0]["paths"]
             if path["path"] not in ("/realms", "/resources")]
    overlay["applications"]["frontend"] = {
        "env": frontend_env,
        "ingress": {"hosts": [{"host": "", "paths": paths}]},
        "configuration": {"config_json": {
            "backend_url_api": fred_url,
            "backend_url_knowledge": fred_url,
            "websocket_url": fred_url.replace("http://", "ws://") + "/fred/chatbot/query",
        }},
    }
    VALUES.parent.mkdir(parents=True, exist_ok=True)
    with VALUES.open("w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(overlay, stream, indent=2)
    return VALUES


def prepare_chart(source, destination):
    """Make a temporary chart copy with defaults compatible with this instance overlay.

    Helm deep-merges maps. Fred's chart defaults still carry DuckDB/local-only
    fields after this instance selects PostgreSQL and MinIO, which fails its
    own oneOf schema validation. Only the temporary deployment copy is changed.
    """
    if not (source / "Chart.yaml").is_file():
        fail(f"FRED_CHART must be a local chart directory: {source}")
    shutil.copytree(source, destination)
    values_file = destination / "values.yaml"
    values = yaml.safe_load(values_file.read_text())
    for app in ("knowledge-flow-backend", "knowledge-flow-worker"):
        configuration = values["applications"][app]["configuration"]
        configuration["content_storage"].pop("root_path", None)
        for store in ("resource_store", "tag_store", "metadata_store"):
            configuration["storage"][store].pop("duckdb_path", None)
    for app in ("control-plane-backend", "control-plane-worker"):
        values["applications"][app]["configuration"]["storage"]["content_storage"].pop(
            "root_path", None
        )
    values_file.write_text(yaml.safe_dump(values, sort_keys=False))


def export_bundle(output):
    """Write what a tester needs to deploy without a PAT: no admin credential inside."""
    state = json.loads(STATE.read_text())
    keys = ["issuer", "fred_url", "project", "spa"] + ["secret-" + name for name in APPS.values()]
    bundle = {key: state[key] for key in keys}
    bundle["project"] = {"id": state["project"]["id"]}
    bundle["spa"] = {"clientId": state["spa"]["clientId"]}
    bundle = {"_disclaimer": LAB_DISCLAIMER, **bundle}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(bundle, indent=2) + "\n")
    print(f"Tester bundle written to {output}: it is committed and therefore public")


def import_bundle(source):
    bundle = json.loads(source.read_text())
    if "action" in bundle or "user-agentic" in bundle:
        fail(f"{source} is an administrator state, not a tester bundle")
    if STATE.exists() and json.loads(STATE.read_text()) != bundle:
        fail(f"{STATE} already exists: this machine is already set up, run make k3d-zitadel-cloud")
    save_state(bundle)
    print(f"Tester bundle installed: {STATE}")


def purge(issuer, pat):
    """Delete what provision() created in ZITADEL Cloud, then the local state."""
    if not pat:
        fail("ZITADEL_PAT is required to delete the ZITADEL Cloud objects")
    state = json.loads(STATE.read_text())

    def delete(path, method="DELETE"):
        try:
            api(issuer, "/management/v1" + path, pat, {} if method == "POST" else None, method)
        except RuntimeError as error:
            if "HTTP 404" not in str(error):
                raise

    if "action" in state:
        # The complement-token flow is cleared first: it would otherwise point at a deleted action.
        delete("/flows/2/_clear", "POST")
        delete("/actions/" + state["action"]["id"])
    for name in APPS.values():
        if "user-" + name in state:
            delete("/users/" + state["user-" + name]["userId"])
    if "project" in state:
        delete("/projects/" + state["project"]["id"])
    for path in (STATE, VALUES, LAB_BUNDLE):
        path.unlink(missing_ok=True)
    print("ZITADEL Cloud objects, local state and the lab bundle deleted: provision anew with "
          "ZITADEL_PAT, then make k3d-zitadel-cloud-bundle and commit the new bundle")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("prepare", "secret-patch", "prepare-chart", "bundle", "join", "purge"),
    )
    parser.add_argument("--chart", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    if args.command == "bundle":
        export_bundle(args.output or LAB_BUNDLE)
        return
    if args.command == "join":
        if not args.bundle:
            fail("join requires --bundle (ZITADEL_BUNDLE=<file>)")
        import_bundle(args.bundle)
        return
    if args.command == "prepare-chart":
        if not args.chart or not args.output:
            fail("prepare-chart requires --chart and --output")
        prepare_chart(args.chart.resolve(), args.output.resolve())
        return
    issuer, fred_url = checked_urls(
        os.environ.get("ZITADEL_ISSUER", ISSUER_DEFAULT),
        os.environ.get("FRED_URL", "http://localhost:5173"),
    )
    if args.command == "purge":
        purge(issuer, os.environ.get("ZITADEL_PAT", ""))
        return
    if args.command == "prepare":
        project, spa, services, audience_scope, jwt_lifetime = provision(
            issuer, fred_url, os.environ.get("ZITADEL_PAT", "")
        )
        path = render(issuer, fred_url, project, spa, services, audience_scope, jwt_lifetime)
        print(f"Fred Cloud overlay prepared: {path}")
        print(f"Fred JWT admission lifetime: {jwt_lifetime}s (measured from Cloud workload tokens)")
    else:
        state = json.loads(STATE.read_text())
        if (state.get("issuer"), state.get("fred_url")) != (issuer, fred_url):
            fail("ZITADEL Cloud state does not match the requested issuer and Fred URL")
        data = {
            secret_env(name): base64.b64encode(
                state["secret-" + name]["clientSecret"].encode()
            ).decode()
            for name in APPS.values()
        }
        json.dump({"data": data}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, OSError, ValueError) as error:
        print(f"k3d-zitadel-cloud: {error}", file=sys.stderr)
        sys.exit(1)
