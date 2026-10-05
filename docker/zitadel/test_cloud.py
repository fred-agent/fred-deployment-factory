"""Offline checks for the ZITADEL Cloud k3d overlay."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[2] / "bin/k3d-zitadel-cloud.py"
spec = importlib.util.spec_from_file_location("k3d_zitadel_cloud", MODULE_PATH)
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)


class CloudValuesTests(unittest.TestCase):
    def test_private_bundle_allows_tester_deployment_without_pat(self):
        issuer = "https://example.zitadel.cloud"
        fred_url = "http://localhost:5173"
        services = {name: {"clientId": name, "clientSecret": "secret"} for name in cloud.APPS.values()}
        state = {
            "issuer": issuer,
            "fred_url": fred_url,
            "project": {"id": "project-id"},
            "spa": {"clientId": "spa-id"},
            **{"secret-" + name: credential for name, credential in services.items()},
        }
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "cloud.json"
            bundle.write_text(json.dumps(state))
            with patch.object(cloud, "STATE", bundle), patch.object(
                cloud, "api", return_value={"issuer": issuer}
            ), patch.object(cloud, "check_workloads", return_value=5400) as check:
                result = cloud.provision(issuer, fred_url, "")
        scope = "urn:zitadel:iam:org:project:id:project-id:aud"
        self.assertEqual(result, ("project-id", "spa-id", services, scope, 5400))
        check.assert_called_once_with(issuer, services, "project-id", scope)

    def test_only_local_fred_origin_and_https_issuer_are_accepted(self):
        self.assertEqual(
            cloud.checked_urls("https://example.zitadel.cloud/", "http://localhost:5173/"),
            ("https://example.zitadel.cloud", "http://localhost:5173"),
        )
        for issuer, fred_url in (
            ("http://example.zitadel.cloud", "http://localhost:5173"),
            ("https://example.zitadel.cloud", "http://public.example"),
        ):
            with self.subTest(issuer=issuer, fred_url=fred_url):
                with self.assertRaises(RuntimeError):
                    cloud.checked_urls(issuer, fred_url)

    def test_overlay_uses_cloud_oidc_local_directory_and_no_keycloak_ingress(self):
        services = {
            "agentic": {"clientId": "agent-id"},
            "knowledge-flow": {"clientId": "knowledge-id"},
            "control-plane": {"clientId": "control-id"},
        }
        with tempfile.TemporaryDirectory() as directory:
            values = Path(directory) / "values.json"
            with patch.object(cloud, "VALUES", values):
                cloud.render(
                    "https://example.zitadel.cloud", "http://localhost:5173",
                    "project-id", "spa-id", services,
                    "urn:zitadel:iam:org:project:id:project-id:aud",
                )
            apps = json.loads(values.read_text())["applications"]
        for app in ("fred-agents", "knowledge-flow-backend", "control-plane-backend",
                    "knowledge-flow-worker", "control-plane-worker"):
            security = apps[app]["configuration"]["security"]
            self.assertEqual(security["user_directory"], "local")
            self.assertEqual(security["user"]["provider"], "oidc")
            self.assertEqual(security["user"]["realm_url"], "https://example.zitadel.cloud")
            self.assertEqual(security["user"]["client_id"], "spa-id")
            self.assertFalse(security["delegation"]["service_accounts_only"])
            self.assertEqual(apps[app]["configuration"]["app"]["gcu_version"], "v1")
            env_names = {item["name"] for item in apps[app]["extraEnvVars"]}
            # Only knowledge-flow's startup check alias may keep a Keycloak name.
            self.assertFalse(any(
                name.startswith("KEYCLOAK_") and name != "KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET"
                for name in env_names
            ))
            self.assertTrue(any(name.startswith("ZITADEL_") for name in env_names))
        self.assertEqual(
            apps["frontend"]["configuration"]["config_json"]["backend_url_api"],
            "http://localhost:5173",
        )
        paths = apps["frontend"]["ingress"]["hosts"][0]["paths"]
        self.assertFalse(any(path["path"] in ("/realms", "/resources") for path in paths))
        self.assertTrue(any(path["path"] == "/control-plane" for path in paths))


if __name__ == "__main__":
    unittest.main()
