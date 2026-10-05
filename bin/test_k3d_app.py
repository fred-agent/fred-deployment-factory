"""Command-level tests; these do not establish a working Kubernetes deployment."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAKE = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write(json.dumps([name, *args]) + "\\n")
if name == "helmfile" and "template" in args:
    if os.environ.get("FAIL_RENDER") == "1" or (os.environ.get("FAIL_FINAL_RENDER") == "1" and os.environ.get("FRED_IMAGE_VALUES")):
        sys.exit(1)
if name == "helm" and "status" in args:
    print(json.dumps({"info": {"status": os.environ.get("RELEASE_STATUS", "deployed")}}))
if name == "helm" and "history" in args:
    print("[]")
if name == "kubectl" and "pvc" in args:
    print(json.dumps({"items": [{"metadata": {"name": "data", "annotations": {"meta.helm.sh/release-name": "fred-app"}}}]}))
"""


class LocalDeploymentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="local helm ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.factory = self.root / "factory checkout"
        self.fred = self.root / "fred checkout"
        (self.factory / "bin").mkdir(parents=True)
        (self.fred / "deploy/k3d").mkdir(parents=True)
        (self.fred / "deploy/charts/fred").mkdir(parents=True)
        (self.fred / "deploy/charts/fred/Chart.yaml").write_text("name: fred\n")
        (self.factory / "instance values.yaml").write_text("{}\n")
        for name in ("k3d-app-deploy.sh", "k3d-helm-recover.sh"):
            shutil.copy(ROOT / "bin" / name, self.factory / "bin" / name)
        shutil.copy(ROOT / "helmfile.yaml.gotmpl", self.factory)
        (self.factory / "bin/k3d-prefetch-images.sh").write_text(
            '#!/bin/bash\nprintf \'["import"]\\n\' >> "$CALLS"\n'
        )
        (self.factory / "bin/k3d-prefetch-images.sh").chmod(0o755)
        (self.fred / "deploy/k3d/build-images.py").write_text("""import os, sys
from pathlib import Path
with open(os.environ["CALLS"], "a") as f: f.write('["build"]\\n')
if os.environ.get("FAIL_BUILD"): sys.exit(1)
p = Path(__file__).resolve().parents[2] / ".cache/k3d"
p.mkdir(parents=True)
(p / "images.json").write_text('{}')
(p / "images.txt").write_text('fred:test\\n')
""")
        (self.fred / "deploy/k3d/configure.sh").write_text(
            'printf \'["configure", "%s"]\\n\' "$1" >> "$CALLS"\n'
        )
        fakebin = self.root / "commands"
        fakebin.mkdir()
        for name in ("helm", "helmfile", "kubectl", "docker", "make"):
            path = fakebin / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{fakebin}:{os.environ['PATH']}",
            CALLS=str(self.root / "calls"),
            FRED_DIR="../fred checkout",
            FRED_VALUES="instance values.yaml",
            K3D_CLUSTER="other",
        )
        for name in ("FRED_IMAGE_VALUES", "FRED_RELEASE", "K3D_NAMESPACE"):
            self.env.pop(name, None)

    def run_deploy(
        self, mode: str = "deploy", **env: str
    ) -> tuple[subprocess.CompletedProcess, list]:
        result = subprocess.run(
            ["bash", str(self.factory / "bin/k3d-app-deploy.sh"), mode],
            cwd="/",
            env=self.env | env,
            capture_output=True,
            text=True,
        )
        log = self.root / "calls"
        calls = (
            [json.loads(line) for line in log.read_text().splitlines()]
            if log.exists()
            else []
        )
        return result, calls

    def test_validate_has_no_build_or_cluster_calls(self) -> None:
        result, calls = self.run_deploy("validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["helmfile", "helmfile"])
        self.assertIn("installation values only", result.stdout)

    def test_missing_values_fail_before_commands(self) -> None:
        result, calls = self.run_deploy(FRED_VALUES="missing file")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_build_and_render_failures_stop_before_mutations(self) -> None:
        for failure in ("FAIL_RENDER", "FAIL_FINAL_RENDER", "FAIL_BUILD"):
            with self.subTest(failure=failure):
                (self.root / "calls").unlink(missing_ok=True)
                result, calls = self.run_deploy(**{failure: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    any(
                        c[0] in ("import", "configure", "helm") or "sync" in c
                        for c in calls
                    )
                )
                if failure == "FAIL_RENDER":
                    self.assertNotIn(["build"], calls)

    def test_order_and_explicit_context(self) -> None:
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        build = calls.index(["build"])
        imported = calls.index(["import"])
        sync = next(i for i, c in enumerate(calls) if "sync" in c)
        renders = [i for i, c in enumerate(calls) if "template" in c]
        self.assertLess(renders[0], build)
        self.assertLess(build, renders[1])
        self.assertLess(renders[1], imported)
        self.assertLess(imported, calls.index(["configure", "key"]))
        self.assertLess(calls.index(["configure", "key"]), sync)
        self.assertLess(sync, calls.index(["configure", "finish"]))
        for call in calls:
            if call[0] in ("helm", "kubectl"):
                self.assertEqual(call[2], "k3d-other")
            self.assertNotIn("use-context", call)

    def test_recovery_refuses_to_delete_persistent_claims(self) -> None:
        result, calls = self.run_deploy(RELEASE_STATUS="failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owns volumes", result.stderr)
        self.assertFalse(any("uninstall" in c or "sync" in c for c in calls))


if __name__ == "__main__":
    unittest.main()
