#!/usr/bin/env python3
"""Import Fred's template and configure local development exporters in Zabbix."""

import argparse
import json
import os
from pathlib import Path
from time import monotonic, sleep
from urllib.error import URLError
from urllib.request import Request, urlopen


HOSTS = {
    "Fred Agents API dev": "http://host.docker.internal:9000/metrics",
    "Fred Knowledge Flow API dev": "http://host.docker.internal:9111/metrics",
    "Fred Knowledge Flow worker dev": "http://host.docker.internal:9112/metrics",
    "Fred Control Plane API dev": "http://host.docker.internal:9222/metrics",
}
TEMPLATE_NAME = "Fred Prometheus by HTTP"
HOST_GROUP = "Fred development"
URL_MACRO = "{$FRED.METRICS.URL}"


def zabbix_port():
    if "ZABBIX_PORT" in os.environ:
        return os.environ["ZABBIX_PORT"]
    env_file = Path(__file__).resolve().parents[1] / "docker/.env"
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() == "ZABBIX_PORT":
                return value.strip().strip("\"'")
    return "8085"


def api_call(url, method, params, token=None):
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    if token:
        payload["auth"] = token
    request = Request(
        url,
        json.dumps(payload).encode(),
        {"Content-Type": "application/json-rpc"},
    )
    with urlopen(request, timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        error = result["error"]
        raise RuntimeError(f"Zabbix {method}: {error.get('data', error.get('message', error))}")
    return result["result"]


def login_when_ready(url, username, password, wait_seconds):
    deadline = monotonic() + wait_seconds
    waiting = False
    while True:
        try:
            return api_call(url, "user.login", {"username": username, "password": password})
        except (URLError, TimeoutError, json.JSONDecodeError, RuntimeError) as exc:
            if isinstance(exc, RuntimeError) and "incorrect user name or password" in str(exc).lower():
                raise
            remaining = deadline - monotonic()
            if remaining <= 0:
                raise RuntimeError(f"Zabbix API did not become ready: {exc}") from exc
            if not waiting:
                print("Waiting for Zabbix API to finish initialization...", flush=True)
                waiting = True
            sleep(min(2, remaining))


def provision(url, template_file, username, password, wait_seconds):
    token = login_when_ready(url, username, password, wait_seconds)
    if template_file.is_file():
        rules = {
            name: {"createMissing": True, "updateExisting": True}
            for name in ("template_groups", "templates", "items", "discoveryRules")
        }
        api_call(
            url,
            "configuration.import",
            {"format": "yaml", "source": template_file.read_text(), "rules": rules},
            token,
        )
    else:
        print(f"Template file not found: {template_file}; checking the installed Zabbix template")
    templates = api_call(
        url, "template.get", {"output": ["templateid"], "filter": {"host": TEMPLATE_NAME}}, token
    )
    if len(templates) != 1:
        raise RuntimeError(
            f"Expected one template named {TEMPLATE_NAME!r}; provide its YAML via ZABBIX_TEMPLATE_FILE"
        )
    template_id = templates[0]["templateid"]

    groups = api_call(
        url, "hostgroup.get", {"output": ["groupid"], "filter": {"name": HOST_GROUP}}, token
    )
    if groups:
        group_id = groups[0]["groupid"]
    else:
        group_id = api_call(url, "hostgroup.create", {"name": HOST_GROUP}, token)["groupids"][0]

    for name, metrics_url in HOSTS.items():
        hosts = api_call(
            url,
            "host.get",
            {
                "output": ["hostid", "host"],
                "filter": {"host": name},
                "selectParentTemplates": ["templateid"],
                "selectMacros": ["macro", "value"],
            },
            token,
        )
        if hosts:
            host = hosts[0]
            linked = {item["templateid"] for item in host["parentTemplates"]}
            macros = {item["macro"]: item["value"] for item in host["macros"]}
            if template_id not in linked or macros.get(URL_MACRO) != metrics_url:
                raise RuntimeError(f"Host {name!r} exists with different template or URL; inspect it in Zabbix")
            action = "already configured"
        else:
            api_call(
                url,
                "host.create",
                {
                    "host": name,
                    "groups": [{"groupid": group_id}],
                    "templates": [{"templateid": template_id}],
                    "macros": [{"macro": URL_MACRO, "value": metrics_url}],
                },
                token,
            )
            action = "created"
        print(f"{name}: {action} - {metrics_url}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--wait-seconds", type=int, default=180)
    args = parser.parse_args()
    if args.wait_seconds < 0:
        parser.error("--wait-seconds must be non-negative")

    url = os.environ.get("ZABBIX_API_URL", f"http://127.0.0.1:{zabbix_port()}/api_jsonrpc.php")
    username = os.environ.get("ZABBIX_ADMIN_USER", "Admin")
    password = os.environ.get("ZABBIX_ADMIN_PASSWORD", "zabbix")
    try:
        provision(url, args.template, username, password, args.wait_seconds)
    except (RuntimeError, URLError) as exc:
        parser.exit(1, f"Zabbix provisioning failed: {exc}\n")


if __name__ == "__main__":
    main()
