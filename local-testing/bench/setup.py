#!/usr/bin/env python3
"""Prepare this factory's conversation lab. Offline by default; --apply is explicit."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from prepare_conversations import generate, local_issuer

OFFER = {"source_id": "bench-mock", "upstream_model_id": "gpt-4o"}
AGENT_NAME = "Bench conversations"
PROMPT = "You are a helpful, knowledgeable, and concise assistant. Answer questions clearly and directly. Do not use tools or external data."


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class API:
    def __init__(self, root, token_file):
        self.root = root.rstrip("/")
        path = Path(token_file)
        if path.stat().st_mode & 0o077:
            raise ValueError("Token files must be private (chmod 600)")
        self.token = path.read_text().strip()
        if not self.token or any(c.isspace() for c in self.token):
            raise ValueError("Token file must contain only the bearer token")
        self.opener = build_opener(NoRedirect())

    def request(self, method, path, body=None, content_type="application/json"):
        data = body if isinstance(body, bytes) else None if body is None else json.dumps(body).encode()
        req = Request(self.root + path, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": content_type})
        try:
            with self.opener.open(req, timeout=120) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except HTTPError as exc:
            # Never echo a server body, tokens, identities or request payload.
            raise ValueError(f"{method} {path.split('?')[0]} returned HTTP {exc.code}; inspect application administration") from None


def origin(value):
    parsed = urlsplit(value)
    local_issuer(value.rstrip("/") + "/realms/app")
    if parsed.path not in ("", "/"):
        raise ValueError("Fred origin must have no path")
    return value.rstrip("/")


def private_json(path, value):
    # Atomic private progress file: replay resumes the accepted import, not a second POST.
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as file:
        os.chmod(tmp, 0o600)
        json.dump(value, file, indent=2)
        file.write("\n")
    tmp.replace(path)


def items(value):
    return value if isinstance(value, list) else value["items"]


def policy_with_mock(policy):
    body = {key: policy[key] for key in ("permitted", "reasoning_enabled", "default", "fallback", "title", "embedding", "vision")}
    body["expected_revision"] = policy["revision"]
    body["permitted"] = list(body["permitted"])
    if OFFER not in body["permitted"]:
        body["permitted"].append(OFFER)
    return body


def agent_body(target, template_id):
    body = {"template_id": template_id, "display_name": AGENT_NAME,
            "description": "Local synthetic conversation benchmark; mock model only.",
            "role": "Plain chat benchmark", "usage_statement": "Local synthetic conversation tests. No real documents, tools or consequential decisions.",
            "tuning_field_values": {"prompts.system": PROMPT},
            "capability_ids": [], "capability_config_values": {}}
    if target == "weaver":
        body.update(recommended_model=OFFER, model_options={"temperature": 0})
    else:
        body["recommended_chat_profile_id"] = "bench.chat.mock"
    return body


def ensure_agent(api, target, scope, template_id):
    path = scope + "/agent-instances"
    page = api.request("GET", path)
    found = list(items(page))
    seen = set()
    while isinstance(page, dict) and page.get("next_cursor"):
        cursor = page["next_cursor"]
        if cursor in seen:
            raise ValueError("Repeated agent pagination cursor")
        seen.add(cursor)
        page = api.request("GET", path + "?after=" + quote(cursor, safe=""))
        found.extend(items(page))
    existing = [x for x in found if x["display_name"].casefold() == AGENT_NAME.casefold()]
    if len(existing) > 1:
        raise ValueError("Ambiguous benchmark agent; inspect the team's instances")
    body = agent_body(target, template_id)
    if not existing:
        return api.request("POST", path, body)
    saved = api.request("GET", path + "/" + existing[0]["agent_instance_id"])
    for key in ("template_id", "recommended_model" if target == "weaver" else "recommended_chat_profile_id", "tuning_field_values"):
        if saved.get(key) != body[key]:
            raise ValueError("Existing benchmark agent differs; inspect it rather than overwriting")
    if target == "weaver" and saved.get("model_options") != body["model_options"]:
        raise ValueError("Existing benchmark agent model options differ; inspect it")
    if saved.get("selected_capability_ids", saved.get("capability_ids", [])):
        raise ValueError("Existing benchmark agent has capabilities; inspect it")
    return saved


def import_users(api, target, output):
    state_file = output / (target + "-import-state.json")
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    if state.get("complete"):
        return
    if not state:
        filename = target + "-provisioning.zip"
        boundary = "fredbench" + secrets.token_hex(12)
        data = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: application/zip\r\n\r\n'.encode()
                + (output / filename).read_bytes() + f"\r\n--{boundary}--\r\n".encode())
        result = api.request("POST", "/import-export/import", data, "multipart/form-data; boundary=" + boundary)
        state = {"task_id": result.get("task_id"), "complete": target == "weaver"}
        private_json(state_file, state)
    if target == "swift":
        if not state.get("task_id"):
            raise ValueError("Swift import did not return its task ID")
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            tasks = api.request("GET", "/tasks?scope=user&task_id=" + quote(state["task_id"]))["tasks"]
            if tasks:
                task = tasks[0]
                if task["state"] == "succeeded":
                    detail = task.get("detail") or {}
                    result = detail.get("result") or {}
                    if detail.get("failed", 0) or result.get("users_skipped") or result.get("team_roles_skipped"):
                        raise ValueError("Swift import skipped users or roles; inspect its task before replay")
                    state["complete"] = True
                    private_json(state_file, state)
                    return
                if task["state"] in ("failed", "cancelled", "canceled"):
                    raise ValueError("Swift import failed; inspect the recorded task before replay")
            time.sleep(2)
        raise ValueError("Swift import still pending; rerun to resume waiting for the same task")


def apply(config, output):
    saved = json.loads((output / "setup.json").read_text())
    # IDs/names and destinations bind imports to the originally reviewed preparation.
    for key in ("issuer", "users", "swift", "weaver"):
        left, right = config[key], saved[key]
        if isinstance(left, dict):
            left = {k: v for k, v in left.items() if k != "operator_token_file"}
            right = {k: v for k, v in right.items() if k != "operator_token_file"}
        if left != right:
            raise ValueError("Preparation scope changed; reuse its saved setup.json")
    issuer = local_issuer(config["issuer"])
    keycloak_root, realm = issuer.rsplit("/realms/", 1)
    kc = API(keycloak_root + "/admin/realms/" + quote(realm), config["keycloak_admin_token_file"])
    apis, scopes, templates = {}, {}, {}
    # Read-only preflight precedes client/import/policy/agent mutations.
    for target in ("swift", "weaver"):
        cfg = config[target]
        apis[target] = api = API(origin(cfg["origin"]) + "/control-plane/v1", cfg["operator_token_file"])
        onboarding = api.request("GET", "/me/onboarding" if target == "weaver" else "/platform-access/status")
        terms_missing = onboarding.get("cgu_required", False) if target == "swift" else (
            onboarding.get("gcu_version") is not None
            and (onboarding.get("acceptance") or {}).get("version") != onboarding["gcu_version"]
        )
        if not onboarding.get("admitted") or onboarding.get("root_bootstrap_required", False) or terms_missing:
            raise ValueError(f"{target}: operator must personally complete onboarding/terms in the UI")
        scopes[target] = scope = ("/spaces/" if target == "weaver" else "/teams/") + quote(cfg["team_id"], safe="")
        if target == "swift":
            team = api.request("GET", scope)
            if team["name"] != cfg["team_name"]:
                raise ValueError("Swift team ID/name mismatch")
        else:
            memberships = api.request("GET", "/me/spaces")
            team = next((x for x in memberships if x["id"] == cfg["team_id"]), None)
            if team is None or team["name"] != cfg["team_name"] or team["organization_id"] != cfg["organization_id"]:
                raise ValueError("Weaver operator must be a member of the named team in the selected organization")
            organization = api.request("GET", "/admin/organizations/" + quote(cfg["organization_id"], safe=""))
            if organization["organization"]["name"] != cfg["organization_name"]:
                raise ValueError("Weaver organization ID/name mismatch")
        catalog = items(api.request("GET", scope + "/agent-templates"))
        matches = [x for x in catalog if x.get("source_agent_id") == "fred.github.assistant" and x.get("source_runtime_id") == "fred-agents" and x.get("status", "available") == "available"]
        if len(matches) != 1:
            raise ValueError(f"{target}: enable fred.github.assistant for this organization/team in normal administration first")
        templates[target] = matches[0]["template_id"]
        api.request("GET", scope + "/agent-instances")
    declaration = json.loads((output / "keycloak-client.json").read_text())
    clients = kc.request("GET", "/clients?clientId=" + quote(declaration["clientId"]))
    if clients:
        if len(clients) != 1:
            raise ValueError("Ambiguous benchmark OAuth client")
        client = kc.request("GET", "/clients/" + clients[0]["id"])
        secret = kc.request("GET", "/clients/" + clients[0]["id"] + "/client-secret")
        for key in ("defaultClientScopes", "optionalClientScopes"):
            if sorted(client.get(key, [])) != sorted(declaration[key]):
                raise ValueError("Existing benchmark OAuth client scopes differ")
        normalize = lambda mappings: sorted([{k: m.get(k) for k in ("name", "protocol", "protocolMapper", "config")} for m in mappings], key=lambda m: m["name"])
        if normalize(client.get("protocolMappers", [])) != normalize(declaration["protocolMappers"]):
            raise ValueError("Existing benchmark OAuth client mappers differ")
        if secret.get("value") != declaration["secret"] or any(client.get(k) != declaration[k] for k in ("enabled", "publicClient", "directAccessGrantsEnabled", "serviceAccountsEnabled", "standardFlowEnabled", "implicitFlowEnabled", "fullScopeAllowed")):
            raise ValueError("Existing benchmark OAuth client differs: reuse its original inputs; do not rotate it")
    else:
        kc.request("POST", "/clients", declaration)
    for target in ("swift", "weaver"):
        print(f"{target}: importing synthetic memberships (same bundle reused on replay)", flush=True)
        import_users(apis[target], target, output)
    organization = config["weaver"]["organization_id"]
    api = apis["weaver"]
    org_path = "/organizations/" + quote(organization, safe="")
    api.request("POST", org_path + "/model-sources/bench-mock/refresh")
    policy = api.request("GET", org_path + "/model-policy")
    if OFFER not in policy["permitted"]:
        api.request("PUT", org_path + "/model-policy", policy_with_mock(policy))
    local = api.request("GET", scopes["weaver"] + "/models")["policy"]
    if OFFER in local["disabled"]:
        raise ValueError("This space explicitly disables the mock offer; change its policy deliberately in administration")
    result = {}
    for target in ("swift", "weaver"):
        saved = ensure_agent(apis[target], target, scopes[target], templates[target])
        result[target] = {"team_id": config[target]["team_id"], "agent_instance_id": saved["agent_instance_id"]}
    private_json(output / "agents.json", result)
    print("Setup complete. agents.json records the IDs. Run the separate identity/terms and runtime preflight before any conversation.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        config = json.loads(args.config.read_text())
        output = Path(config["output"])
        for target in ("swift", "weaver"):
            origin(config[target]["origin"])
        if args.apply:
            if output.stat().st_mode & 0o077:
                raise ValueError("Output must remain private (chmod 700)")
            apply(config, output)
        else:
            generate(SimpleNamespace(users=config["users"], issuer=config["issuer"],
                swift_team=config["swift"]["team_name"], weaver_organization=config["weaver"]["organization_name"],
                weaver_team=config["weaver"]["team_name"], fred_source=Path(config["fred_source"]),
                output=output, prefix=None))
            private_json(output / "setup.json", config)
            print("Private inputs generated offline. Review setup.json, bootstrap/terms and IDs, then repeat with APPLY=1.")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        message = str(exc) if isinstance(exc, ValueError) else "Check configuration, private files and deployment CLI; no credentials printed."
        print("Setup stopped: " + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
