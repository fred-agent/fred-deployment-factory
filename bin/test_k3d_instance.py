"""Coexistence provisioning guards; no cluster access."""

import base64
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader(
    "instance", str(Path(__file__).with_name("k3d-instance"))
)
spec = importlib.util.spec_from_loader(loader.name, loader)
instance = importlib.util.module_from_spec(spec)
loader.exec_module(instance)


def encoded(value):
    return base64.b64encode(value.encode()).decode()


class InstanceTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(
            os.environ,
            KUBE_CONTEXT="k3d-test",
            K3D_NAMESPACE="fred-weaver",
            K3D_INFRA_NAMESPACE="fred",
            K3D_DATABASE="fred_weaver",
            K3D_TEMPORAL_NAMESPACE="fred-weaver",
            K3D_KEYCLOAK_HOST="keycloak",
        )
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_refuses_shared_database_before_writes(self):
        with (
            patch.dict(os.environ, K3D_DATABASE="fred"),
            patch.object(instance, "run") as run,
        ):
            run.return_value = json.dumps(
                {"data": {"POSTGRES_FRED_DB": encoded("fred")}}
            )
            with self.assertRaisesRegex(RuntimeError, "Swift database"):
                instance.prepare()
            self.assertEqual(run.call_count, 1)

    def test_refuses_shared_namespace_before_access(self):
        with (
            patch.dict(os.environ, K3D_NAMESPACE="fred"),
            patch.object(instance, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "separate application namespace"):
                instance.prepare()
            run.assert_not_called()

    def test_refuses_shared_worker_namespace_before_access(self):
        with (
            patch.dict(os.environ, K3D_TEMPORAL_NAMESPACE="default"),
            patch.object(instance, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "separate Temporal namespace"):
                instance.prepare()
            run.assert_not_called()

    def test_refuses_existing_weaver_roles_before_writes(self):
        with patch.object(
            instance,
            "run",
            side_effect=[
                json.dumps({"data": {"POSTGRES_FRED_DB": encoded("fred")}}),
                "another_weaver_database\n",
            ],
        ) as run:
            with self.assertRaisesRegex(RuntimeError, "already belong"):
                instance.prepare()
            self.assertEqual(run.call_count, 2)
            self.assertTrue(run.call_args.args[1].startswith("SELECT"))

    def test_replay_preserves_application_credentials_and_source(self):
        applied = []
        calls = []
        stored = {
            "POSTGRES_FRED_DB": encoded("fred_weaver"),
            "POSTGRES_CP_PASSWORD": encoded("application-password"),
            "CONTROL_PLANE_BOOTSTRAP_TOKEN": encoded("application-token"),
        }

        def run(command, body=None):
            calls.append((command, body))
            if "get" in command and "namespace" in command:
                return json.dumps(
                    {
                        "metadata": {
                            "labels": {"fred-deployment-factory/instance": "weaver"}
                        }
                    }
                )
            if "get" in command and "secret" in command:
                data = (
                    stored
                    if command[command.index("-n") + 1] == "fred-weaver"
                    else {
                        "POSTGRES_FRED_DB": encoded("fred"),
                        "POSTGRES_FRED_PASSWORD": encoded("source-password"),
                        "KEYCLOAK_AGENTIC_CLIENT_SECRET": encoded(
                            "existing-realm-client"
                        ),
                        "CONTROL_PLANE_BOOTSTRAP_TOKEN": encoded("source-token"),
                    }
                )
                return json.dumps({"metadata": {"resourceVersion": "42"}, "data": data})
            if "apply" in command:
                applied.append(json.loads(body))
            if "list" in command:
                return json.dumps([{"namespaceInfo": {"name": "fred-weaver"}}])
            return ""

        with patch.object(instance, "run", side_effect=run):
            instance.prepare()
        secret = next(item for item in applied if item["kind"] == "Secret")
        self.assertEqual(secret["metadata"]["namespace"], "fred-weaver")
        self.assertEqual(secret["metadata"]["resourceVersion"], "42")
        self.assertEqual({key: secret["data"][key] for key in stored}, stored)
        self.assertNotIn("POSTGRES_FRED_PASSWORD", secret["data"])
        self.assertTrue(
            all(
                item["metadata"].get("namespace", "fred-weaver") == "fred-weaver"
                for item in applied
            )
        )
        sql = next(body for _, body in calls if body and "CREATE DATABASE" in body)
        self.assertIn("CREATE DATABASE fred_weaver", sql)
        self.assertNotIn("DROP", sql)
        self.assertFalse(any("create" in cmd for cmd, _ in calls))


if __name__ == "__main__":
    unittest.main()
