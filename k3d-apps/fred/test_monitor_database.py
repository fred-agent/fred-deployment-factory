"""Canonical bootstrap and per-component credentials, without a cluster."""

import base64
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader(
    "monitor_database", str(Path(__file__).with_name("monitor-database"))
)
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class MonitorDatabaseTests(unittest.TestCase):
    def provision(self, stored=None, infra="test"):
        calls = []
        secret = stored or {
            "metadata": {"resourceVersion": "42"},
            "data": {"POSTGRES_FRED_DB": base64.b64encode(b"fred").decode()},
        }

        def run(command, *, body=None):
            calls.append((command, body))
            self.assertEqual(
                command[:5],
                [
                    "kubectl",
                    "--context",
                    "k3d-test",
                    "-n",
                    infra if "exec" in command else "test",
                ],
            )
            return json.dumps(secret) if "get" in command else ""

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bootstrap.sql"
            source.write_text("-- exact canonical source\n")
            with (
                patch.dict(
                    os.environ,
                    KUBE_CONTEXT="k3d-test",
                    K3D_NAMESPACE="test",
                    K3D_INFRA_NAMESPACE=infra,
                ),
                patch.object(module, "run", side_effect=run),
            ):
                module.provision(source)
        return calls, secret

    def test_credentials_are_distinct_persisted_and_reused_without_argv_exposure(self):
        calls, secret = self.provision()
        operations = json.loads(next(body for cmd, body in calls if "patch" in cmd))
        self.assertEqual(
            operations[0],
            {"op": "test", "path": "/metadata/resourceVersion", "value": "42"},
        )
        for op in operations[1:]:
            secret["data"][op["path"].split("/")[-1]] = op["value"]
        passwords = [
            base64.b64decode(secret["data"][k]).decode()
            for k in module.PASSWORD_KEYS.values()
        ]
        self.assertEqual(len(set(passwords)), 4)
        again, _ = self.provision(secret)
        self.assertFalse(any("patch" in cmd for cmd, _ in again))
        sql = next(body for cmd, body in again if "exec" in cmd)
        self.assertTrue(sql.startswith("-- exact canonical source\n"))
        self.assertNotIn("GRANT", sql)
        for password in passwords:
            self.assertIn(password, sql)
            for command, _ in calls + again:
                self.assertNotIn(password, " ".join(command))
        uri = base64.b64decode(secret["data"]["POSTGRES_MONITOR_DATABASE_URL"]).decode()
        self.assertTrue(uri.startswith("postgresql://fred_monitor:"))

    def test_cross_namespace_bootstrap_keeps_credentials_in_application_namespace(self):
        secret = {
            "metadata": {"resourceVersion": "42"},
            "data": {"POSTGRES_FRED_DB": base64.b64encode(b"fred_weaver").decode()},
        }
        calls, _ = self.provision(secret, infra="foundation")
        sql_command = next(command for command, _ in calls if "exec" in command)
        self.assertEqual(sql_command[-1], "fred_weaver")
        patch_command = next(command for command, _ in calls if "patch" in command)
        self.assertEqual(patch_command[4], "test")

    def test_refuse_non_k3d_before_reading_or_mutating_anything(self):
        with (
            patch.dict(os.environ, KUBE_CONTEXT="production"),
            patch.object(module, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "explicit k3d context"):
                module.provision("missing")
            run.assert_not_called()

    def test_passwords_are_quoted_and_statement_logging_is_disabled(self):
        sql = module.password_sql(
            {key: "pass'word" for key in module.PASSWORD_KEYS.values()}
        )
        self.assertIn("PASSWORD 'pass''word'", sql)
        self.assertTrue(sql.startswith("SET log_statement='none'"))


if __name__ == "__main__":
    unittest.main()
