#!/usr/bin/env python3
"""Retire the known stateless manager release before Fred takes over its resources."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

HERE = Path(__file__).resolve().parent
OWNED = {
    ("ServiceAccount", "fred-manager"),
    ("ServiceAccount", "fred-manager-worker"),
    ("Secret", "fred-manager-env"),
    ("ConfigMap", "fred-manager-back"),
    ("ConfigMap", "fred-manager-catalog"),
    ("Service", "fred-manager"),
    ("Deployment", "fred-manager"),
    ("Deployment", "fred-manager-worker"),
    ("Ingress", "fred-manager"),
}
WORKLOADS = {"fred-manager", "fred-manager-worker", "knowledge-flow-backend", "knowledge-flow-worker", "frontend"}


def integrated():
    checkout = os.environ.get("K3D_APP_CHECKOUT")
    if not checkout:
        return False
    path = Path(checkout) / "deploy/charts/fred/values.yaml"
    return path.is_file() and "fred-manager" in yaml.safe_load(path.read_text()).get("applications", {})


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed during manager transition; no dependency output is printed")
    return result.stdout


def documents(text):
    return [d for d in yaml.safe_load_all(text) if d]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def migrate():
    if not integrated():
        return
    context, namespace = os.environ["KUBE_CONTEXT"], os.environ.get("K3D_NAMESPACE", "fred")
    require(context.startswith("k3d-"), "manager transition requires an explicit k3d context")
    helm = ["helm", "--kube-context", context, "-n", namespace]
    kube = ["kubectl", "--context", context, "-n", namespace]
    releases = json.loads(run([*helm, "list", "--all", "--filter", "^fred-manager$", "-o", "json"]))
    if not releases:
        return
    require(len(releases) == 1 and releases[0]["status"] == "deployed", "resolve the standalone manager release state before migrating")
    manifest = run([*helm, "get", "manifest", "fred-manager"])
    old = documents(manifest)
    require(len(old) == len(OWNED) and {(d["kind"], d["metadata"]["name"]) for d in old} == OWNED,
            "standalone manager owns unexpected or persistent resources; automatic migration refused")
    require(not documents(run([*helm, "get", "hooks", "fred-manager"])), "standalone manager has unexpected hooks")
    live_docs = []
    for item in old:
        meta = item["metadata"]
        require(meta.get("namespace", namespace) == namespace, "standalone manager contains a foreign namespace")
        live = json.loads(run([*kube, "get", item["kind"], meta["name"], "-o", "json"]))
        live_docs.append(live)
        annotations = live["metadata"].get("annotations", {})
        require(annotations.get("meta.helm.sh/release-name") == "fred-manager"
                and annotations.get("meta.helm.sh/release-namespace") == namespace,
                "standalone resource ownership changed; migration refused")
        if item["kind"] == "Deployment":
            require(all("configMap" in v or "secret" in v for v in live["spec"]["template"]["spec"].get("volumes", [])),
                    "standalone manager has persistent or custom volumes")
        if item["kind"] == "Secret":
            require(set(live.get("data", {})) <= {".env"}
                    and not base64.b64decode(live.get("data", {}).get(".env", "")).strip(),
                    "standalone manager has custom env secrets; transfer their references before migrating")
    claims = json.loads(run([*kube, "get", "pvc", "-o", "json"]))
    require(not any(p["metadata"].get("annotations", {}).get("meta.helm.sh/release-name") == "fred-manager" for p in claims["items"]),
            "standalone manager owns a persistent claim")
    command = ["helmfile", "--file", str(HERE / "helmfile.yaml.gotmpl"), "--kube-context", context,
               "--namespace", namespace, "template", "--skip-deps"]
    command += json.loads(os.environ.get("K3D_APP_VALUES_JSON", "[]"))
    new = documents(run(command))
    require({d["metadata"]["name"] for d in new if d["kind"] == "Deployment"} == WORKLOADS,
            "rendered Fred composition is not the expected five workloads")

    def config(docs):
        cfg = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "fred-manager-back")
        return yaml.safe_load(cfg["data"]["configuration.yaml"])

    before, after = config(live_docs), config(new)
    require(before["storage"] == after["storage"]
            and before["security"]["rebac"]["api_url"] == after["security"]["rebac"]["api_url"]
            and before["security"]["rebac"].get("store_name", "fred-manager") == after["security"]["rebac"].get("store_name", "fred-manager")
            and before["security"]["user"] == after["security"]["user"]
            and before["security"]["m2m"] == after["security"]["m2m"]
            and before["app"].get("gcu_version") == after["app"].get("gcu_version")
            and before["app"].get("bootstrap_token_env_var") == after["app"].get("bootstrap_token_env_var")
            and before.get("scheduler") == after.get("scheduler")
            and before.get("policies") == after.get("policies"),
            "manager storage, identity or consent configuration would change; migration refused")
    def catalog(docs):
        return next(d["data"] for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "fred-manager-catalog")

    require(catalog(live_docs) == catalog(new), "manager lifecycle catalog would change; migration refused")
    for name in ("fred-manager", "fred-manager-worker"):
        def credentials(docs):
            deployment = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
            container = deployment["spec"]["template"]["spec"]["containers"][0]
            return {e["name"]: e for e in container.get("env", [])}, container.get("envFrom", [])
        require(credentials(live_docs) == credentials(new), "manager environment or credential sources would change; migration refused")
    backup = Path(tempfile.mkdtemp(prefix="manager-release-", dir=os.environ["K3D_APP_OUT"]))
    os.chmod(backup, 0o700)
    for name, content in {
        "manifest.yaml": manifest,
        "values.yaml": run([*helm, "get", "values", "fred-manager", "--all", "-o", "yaml"]),
        "recovery.txt": "Data is unchanged. Retry the coordinated Fred deployment. The saved manifest and values are inspection artifacts, not an automatic rollback. Keep the same checkout and factory revision for retry; do not run both owners.\n",
    }.items():
        path = backup / name
        with path.open("x") as stream:
            os.chmod(path, 0o600)
            stream.write(content)
    print(f"Migrating the stateless manager release into Fred; protected recovery files: {backup}", flush=True)
    run([*helm, "uninstall", "fred-manager", "--wait", "--cascade", "foreground", "--timeout", "120s"])
    print("Standalone manager removed; the following Fred sync installs its replacement. On sync failure, retry the same command; data and foundation secrets remain intact.", flush=True)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--is-integrated"]:
            sys.exit(0 if integrated() else 1)
        migrate()
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, yaml.YAMLError) as error:
        # Parsing and command exceptions may contain secrets; only our static errors are printable.
        print(str(error) if isinstance(error, RuntimeError) else "manager transition input could not be validated", file=sys.stderr)
        sys.exit(1)
