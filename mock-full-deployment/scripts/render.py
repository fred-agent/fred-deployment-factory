"""Rend les bundles des deux VMs dans build/<vm>/, à l'image de leur système de fichiers.

Entrées : config.env, images.tsv, secrets/ (generated.env, llm.env, pki/), le fichier
entra.env du kit Entra et les configuration_prod.yaml du dépôt Fred. Les configurations
Fred sont validées contre leur schéma JSON. build/<vm>/.perms liste mode et propriétaire
de chaque fichier sensible ; scripts/deliver.sh les applique dans la VM.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("'\"")
    return values


def write(vm: str, rel: str, content: str, perms: list[str], mode: str = "0644", owner: str = "root:root") -> None:
    path = BUILD / vm / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    perms.append(f"{mode} {owner} /{rel}")


def env_file(values: dict[str, str]) -> str:
    return "".join(f"{k}={v}\n" for k, v in values.items())


def copy_tree(src: Path, vm: str) -> None:
    shutil.copytree(src, BUILD / vm, dirs_exist_ok=True)


def require(values: dict[str, str], keys: list[str], source: str) -> None:
    missing = [k for k in keys if not values.get(k)]
    if missing:
        sys.exit(f"ERREUR : {source} : valeur(s) manquante(s) : {', '.join(missing)}")


# --------------------------------------------------------------------------- Fred
def fred_configs(cfg: dict[str, str], entra: dict[str, str]) -> dict[str, dict]:
    repo = Path(cfg["FRED_REPO"])
    issuer = f"https://login.microsoftonline.com/{entra['TENANT_ID']}/v2.0"
    s3 = {"endpoint": f"https://{cfg['STO_FQDN']}:8333", "access_key": cfg["S3_ACCESS_KEY"], "secure": True}
    m2m_ids = {
        "control-plane-backend": entra["CP_CLIENT_ID"],
        "knowledge-flow-backend": entra["KF_CLIENT_ID"],
        "fred-agents": entra["RUNTIME_CLIENT_ID"],
    }
    out = {}
    for app, m2m_id in m2m_ids.items():
        c = yaml.safe_load((repo / "apps" / app / "config" / "configuration_prod.yaml").read_text())
        runtime = app == "fred-agents"

        # Entra ID : mêmes valeurs que values-entra.example.yaml et que generer-configs.sh du kit.
        sec = c["security"]
        sec["user_directory"] = "local"
        sec["user"] = {
            "enabled": True, "provider": "oidc", "realm_url": issuer,
            "client_id": entra["UI_CLIENT_ID"], "audience": entra["API_APP_ID"],
            "scope": f"{entra['API_URI']}/access_as_user",
            "roles_claim": ["roles"], "claims": {"uid": "oid"},
        }
        sec["m2m"] = {
            "enabled": True, "provider": "oidc", "realm_url": issuer, "client_id": m2m_id,
            "scope": f"{entra['API_URI']}/.default", "secret_env_var": sec["m2m"]["secret_env_var"],
        }
        sec["delegation"] = {
            "act_for_people": runtime, "accept_delegated_calls": not runtime,
            "caller_roles_claim": ["roles"], "audience": entra["API_APP_ID"],
            "service_accounts_only": False,
        }
        sec["authorized_origins"] = [cfg["PUBLIC_URL"]]
        sec["rebac"]["api_url"] = "http://openfga:8080"

        # Stockage : Postgres distant en TLS, pas d'OpenSearch. Les logs partent sur la
        # sortie standard (journald) ; log_store n'est que la copie consultable dans
        # l'UI : tampon mémoire, "stdout" étant déclaré au schéma mais refusé au boot.
        st = c["storage"]
        st["postgres"].update({"host": cfg["STO_FQDN"], "port": 5432, "database": "fred", "username": "fred"})
        st.pop("opensearch", None)
        st["log_store"] = {"type": "in_memory"}

        if app == "control-plane-backend":
            c["app"].pop("bootstrap_token_file", None)
            c["app"]["bootstrap_token_env_var"] = "FRED_BOOTSTRAP_TOKEN"
            c["scheduler"]["temporal"]["host"] = "temporal:7233"
            st["content_storage"].update(s3)
            c["policies"]["purge_catalog_path"] = "/etc/fred/config/conversation_policy_catalog.yaml"
            plat = c["platform"]
            plat["frontend"]["feature_flags"] = {"enableInformationSystems": False, "enableApplications": False}
            plat["knowledge_flow_base_url"] = "http://knowledge-flow-backend:8111/knowledge-flow/v1"
            plat["runtime_catalog_sources"] = [{
                "runtime_id": "fred-agents", "base_url": "http://fred-agents:8000/fred/agents/v2",
                "enabled": True, "ingress_prefix": "/fred/agents/v2",
            }]
            plat["application_sources"] = []
        elif app == "knowledge-flow-backend":
            c["app"]["address"] = "0.0.0.0"
            c["scheduler"]["temporal"]["host"] = "temporal:7233"
            c["content_storage"].update(s3)
            c["filesystem"].update(s3)
            st["vector_store"] = {"type": "pgvector"}
            c["mcp"]["opensearch_ops_enabled"] = False
            # Modèle de reranking embarqué dans l'image (HF_HUB_OFFLINE), comme dans le chart.
            c["crossencoder_model"]["settings"].update(
                {"online": False, "local_path": "/home/fred-user/.cache/huggingface/hub"}
            )
        else:
            c["ai"]["knowledge_flow_url"] = "http://knowledge-flow-backend:8111/knowledge-flow/v1"
            c["platform"]["control_plane_url"] = "http://control-plane-backend:8222/control-plane/v1"
            st["object_store"].update(s3)

        schema = json.loads((repo / "apps" / app / "config" / "schema" / "configuration.schema.json").read_text())
        jsonschema.validate(c, schema)
        out[app] = c
    return out


def main() -> None:
    cfg = read_env(ROOT / "config.env")
    gen = read_env(ROOT / "secrets" / "generated.env")
    llm = read_env(ROOT / "secrets" / "llm.env")
    entra = read_env(Path(cfg["ENTRA_ENV"]))
    require(entra, ["TENANT_ID", "API_APP_ID", "API_URI", "UI_CLIENT_ID", "RUNTIME_CLIENT_ID",
                    "RUNTIME_SECRET", "KF_CLIENT_ID", "KF_SECRET", "CP_CLIENT_ID", "CP_SECRET"], cfg["ENTRA_ENV"])
    require(llm, ["OPENAI_API_KEY"], "secrets/llm.env")
    pki = ROOT / "secrets" / "pki"
    repo = Path(cfg["FRED_REPO"])

    images = {}
    for line in (ROOT / "images.tsv").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            var, _src, target = line.split("\t")
            images[var] = f"{cfg['REGISTRY_HOST']}/{target}"

    shutil.rmtree(BUILD, ignore_errors=True)

    # ------------------------------------------------------------ fred-sto-01
    vm, perms = "fred-sto-01", []
    copy_tree(ROOT / "bundles" / "common", vm)
    copy_tree(ROOT / "bundles" / vm, vm)
    hba = BUILD / vm / "etc/fred/postgres/pg_hba.conf"
    hba.write_text(hba.read_text().replace("@APP_IP@", cfg["APP_IP"]))
    write(vm, "opt/fred/.env", env_file({
        "POSTGRES_IMAGE": images["POSTGRES_IMAGE"], "SEAWEEDFS_IMAGE": images["SEAWEEDFS_IMAGE"],
        "STO_IP": cfg["STO_IP"],
    }), perms)
    write(vm, "etc/fred/secrets/postgres.env", env_file({
        "POSTGRES_PASSWORD": gen["POSTGRES_PASSWORD"], "FRED_DB_PASSWORD": gen["FRED_DB_PASSWORD"],
        "OPENFGA_DB_PASSWORD": gen["OPENFGA_DB_PASSWORD"], "TEMPORAL_DB_PASSWORD": gen["TEMPORAL_DB_PASSWORD"],
    }), perms, "0600")
    s3_json = {"identities": [{
        "name": cfg["S3_ACCESS_KEY"],
        "credentials": [{"accessKey": cfg["S3_ACCESS_KEY"], "secretKey": gen["S3_SECRET_KEY"]}],
        "actions": ["Admin", "Read", "Write", "List", "Tagging"],
    }]}
    write(vm, "etc/fred/seaweedfs/s3.json", json.dumps(s3_json, indent=2) + "\n", perms, "0600",
          f"{cfg['SEAWEED_UID']}:{cfg['SEAWEED_UID']}")
    write(vm, "etc/fred/tls/ca.crt", (pki / "ca.crt").read_text(), perms)
    for svc, owner in (("postgres", f"{cfg['PG_UID']}:{cfg['PG_UID']}"),
                       ("seaweedfs", f"{cfg['SEAWEED_UID']}:{cfg['SEAWEED_UID']}")):
        write(vm, f"etc/fred/tls/{svc}/server.crt", (pki / "fred-sto-01.crt").read_text(), perms, "0644", owner)
        write(vm, f"etc/fred/tls/{svc}/server.key", (pki / "fred-sto-01.key").read_text(), perms, "0600", owner)
    perms += ["0755 root:root /opt/fred/bin/fred-deploy.sh",
              "0755 root:root /etc/fred/postgres/initdb/10-fred-databases.sh",
              f"0700 {cfg['PG_UID']}:{cfg['PG_UID']} /var/lib/fred/postgres",
              f"0700 {cfg['SEAWEED_UID']}:{cfg['SEAWEED_UID']} /var/lib/fred/seaweedfs",
              "0700 root:root /etc/fred/secrets"]
    (BUILD / vm / ".perms").write_text("\n".join(perms) + "\n")

    # ------------------------------------------------------------ fred-app-01
    vm, perms = "fred-app-01", []
    copy_tree(ROOT / "bundles" / "common", vm)
    copy_tree(ROOT / "bundles" / vm, vm)
    write(vm, "opt/fred/.env", env_file({
        **{k: v for k, v in images.items() if k not in ("POSTGRES_IMAGE", "SEAWEEDFS_IMAGE")},
        "STO_FQDN": cfg["STO_FQDN"], "APP_IP": cfg["APP_IP"],
        "APP_PODMAN_SUBNET": cfg["APP_PODMAN_SUBNET"], "TEMPORAL_IP": cfg["TEMPORAL_IP"],
    }), perms)
    temporal_yaml = BUILD / vm / "etc/fred/temporal/temporal.yaml"
    temporal_yaml.write_text(temporal_yaml.read_text()
                             .replace("@STO_FQDN@", cfg["STO_FQDN"]).replace("@TEMPORAL_IP@", cfg["TEMPORAL_IP"]))
    for app, c in fred_configs(cfg, entra).items():
        write(vm, f"etc/fred/config/{app}.yaml", yaml.safe_dump(c, sort_keys=False, allow_unicode=True), perms)
    cp_cfg = repo / "apps/control-plane-backend/config"
    write(vm, "etc/fred/config/conversation_policy_catalog.yaml",
          (cp_cfg / "conversation_policy_catalog.yaml").read_text(), perms)
    agents_cfg = repo / "apps/fred-agents/config"
    write(vm, "etc/fred/config/models_catalog.yaml", (agents_cfg / "models_catalog.yaml").read_text(), perms)
    write(vm, "etc/fred/config/mcp_catalog.yaml",
          (agents_cfg / "mcp_catalog.yaml").read_text().replace(
              "http://localhost:8111/", "http://knowledge-flow-backend:8111/"), perms)
    write(vm, "etc/fred/tls/ca.crt", (pki / "ca.crt").read_text(), perms)

    secret = lambda rel, values: write(vm, f"etc/fred/secrets/{rel}", env_file(values), perms, "0600")  # noqa: E731
    secret("common.env", {
        "FRED_POSTGRES_PASSWORD": gen["FRED_DB_PASSWORD"],
        "MINIO_SECRET_KEY": gen["S3_SECRET_KEY"],
        "OPENFGA_API_TOKEN": gen["OPENFGA_PRESHARED_KEY"],
    })
    # Les secrets Entra gardent leurs noms historiques KEYCLOAK_* (secret_env_var).
    secret("control-plane.env", {
        "KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET": entra["CP_SECRET"],
        "FRED_BOOTSTRAP_TOKEN": gen["FRED_BOOTSTRAP_TOKEN"],
    })
    secret("knowledge-flow.env", {
        "KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET": entra["KF_SECRET"],
        "OPENAI_API_KEY": llm["OPENAI_API_KEY"],
    })
    secret("fred-agents.env", {
        "KEYCLOAK_AGENTIC_CLIENT_SECRET": entra["RUNTIME_SECRET"],
        "OPENAI_API_KEY": llm["OPENAI_API_KEY"],
    })
    secret("openfga.env", {
        "OPENFGA_DATASTORE_URI": (
            f"postgres://openfga:{gen['OPENFGA_DB_PASSWORD']}@{cfg['STO_FQDN']}:5432/openfga"
            "?sslmode=verify-full&sslrootcert=/etc/fred/tls/ca.crt"
        ),
        "OPENFGA_AUTHN_PRESHARED_KEYS": gen["OPENFGA_PRESHARED_KEY"],
    })
    # POSTGRES_PWD pour temporal.yaml (serveur), SQL_PASSWORD pour temporal-sql-tool (jobs).
    secret("temporal.env", {"POSTGRES_PWD": gen["TEMPORAL_DB_PASSWORD"], "SQL_PASSWORD": gen["TEMPORAL_DB_PASSWORD"]})
    perms += ["0755 root:root /opt/fred/bin/fred-deploy.sh", "0755 root:root /opt/fred/bin/fred-jobs.sh",
              "0700 root:root /etc/fred/secrets"]
    (BUILD / vm / ".perms").write_text("\n".join(perms) + "\n")

    for vm in ("fred-sto-01", "fred-app-01"):
        print(f"OK build/{vm}/")


if __name__ == "__main__":
    main()
