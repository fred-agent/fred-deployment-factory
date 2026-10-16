"""Exercise Fred's k3d hooks with fake commands, never a real cluster."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

FAKE = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write(json.dumps([name, *args]) + "\\n")
if name == "curl": print('{"root_bootstrap_required": true}')
if name == "kubectl":
    if "secret" in args and "get" in args: print(os.environ.get("MODEL_KEY", ""))
    if "configmap" in args and "get" in args:
        p = Path(os.environ["CALLS"] + ".count")
        count = int(p.read_text()) if p.exists() else 0
        p.write_text(str(count + 1))
        print(count if os.environ.get("DASHBOARD_CHANGED") else "same")
    if "apply" in args: sys.stdin.read()
"""
STORED_KEY = "dGVzdC1vbmx5LXNlY3JldA=="  # what kubectl returns: the key, base64


class HookTests(unittest.TestCase):
    def run_hook(
        self,
        hook: str,
        model_key: str = STORED_KEY,
        dashboards_changed: bool = False,
        checkout: bool = True,
    ) -> tuple[subprocess.CompletedProcess, list]:
        with tempfile.TemporaryDirectory(prefix="fred hooks ") as directory:
            root = Path(directory)
            (root / "deploy/grafana").mkdir(parents=True)
            (root / "deploy/grafana/dashboard.json").write_text(
                '{"datasource": "${DS_PROMETHEUS}"}'
            )
            fakebin = root / "bin"
            fakebin.mkdir()
            for name in ("kubectl", "curl", "getent"):
                command = fakebin / name
                command.write_text(FAKE)
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", str(Path(__file__).with_name(hook))],
                env=dict(
                    os.environ,
                    PATH=f"{fakebin}:{os.environ['PATH']}",
                    CALLS=str(root / "calls"),
                    KUBE_CONTEXT="k3d-test",
                    K3D_NAMESPACE="test",
                    MODEL_KEY=model_key,
                    DASHBOARD_CHANGED="1" if dashboards_changed else "",
                    K3D_APP_CHECKOUT=str(root) if checkout else "",
                ),
                capture_output=True,
                text=True,
            )
            log = root / "calls"
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            output = result.stdout + result.stderr
            self.assertNotIn(STORED_KEY, output)
            self.assertFalse(
                any("CONTROL_PLANE_BOOTSTRAP_TOKEN" in str(c) for c in calls)
            )
            for call in calls:
                if call[0] == "kubectl":
                    self.assertEqual(call[1:3], ["--context", "k3d-test"])
            return result, calls

    def test_prepare_only_reads_the_operator_secret(self) -> None:
        result, calls = self.run_hook("prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [c[3:6] for c in calls], [["get", "secret", "fred-model-credentials"]]
        )

    def test_prepare_without_the_model_key_stops_and_says_how(self) -> None:
        result, calls = self.run_hook("prepare", model_key="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "create secret generic fred-model-credentials --from-literal=OPENAI_API_KEY=",
            result.stderr,
        )
        self.assertFalse(any(a in c for c in calls for a in ("create", "patch")))

    def test_changed_dashboards_restart_grafana(self) -> None:
        result, calls = self.run_hook("finish", dashboards_changed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            any("deployment/grafana" in c and "restart" in c for c in calls)
        )
        self.assertIn("get secret fred-secrets", result.stdout)

    def test_unchanged_dashboards_do_not_restart(self) -> None:
        _, calls = self.run_hook("finish")
        self.assertFalse(any("restart" in c for c in calls))

    def test_published_release_loads_no_dashboards(self) -> None:
        _, calls = self.run_hook("finish", dashboards_changed=True, checkout=False)
        self.assertFalse(
            any("configmap" in c or "deployment/grafana" in c for c in calls)
        )


if __name__ == "__main__":
    unittest.main()
