"""Prove omitted/invalid BENCH cannot roll out a release already using the mock."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GuardTests(unittest.TestCase):
    def test_existing_benchmark_refuses_omission_before_render_or_build(self):
        for target, app in (("weaver", {"control-plane-backend": {"configuration": {"platform": {"model_sources": [{"source_id": "bench-mock"}]}}}}),
                            ("swift", {"fred-agents": {"models_catalog": {"profiles": [{"profile_id": "bench.chat.mock"}]}}})):
            with tempfile.TemporaryDirectory() as directory:
                p = Path(directory)
                (p / "previous.json").write_text(json.dumps({"applications": app}))
                helm = p / "helm"
                helm.write_text('#!/bin/sh\ncase "$*" in\n*" list "*) echo "[{\\"name\\":\\"fred-app\\"}]";;\n*) cat "$STUB_VALUES";;\nesac\n')
                helm.chmod(0o700)
                env = {**os.environ, "PATH": str(p) + os.pathsep + os.environ["PATH"], "STUB_VALUES": str(p / "previous.json"),
                       "APP": "fred", "FRED": target, "BENCH": "", "DIR": "", "RELEASE": "", "VALUES": ""}
                result = subprocess.run([str(ROOT / "bin/k3d-app"), "sync"], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Repeat the deployment with BENCH=reference", result.stderr)
                self.assertNotIn("Templating", result.stderr)

    def test_none_cannot_bypass_the_guard(self):
        result = subprocess.run([str(ROOT / "bin/k3d-app"), "sync"], env={**os.environ, "BENCH": "none"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BENCH must be reference or streaming", result.stderr)


if __name__ == "__main__":
    unittest.main()
