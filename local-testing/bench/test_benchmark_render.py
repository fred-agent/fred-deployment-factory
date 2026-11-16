"""Render the real charts offline, proving the benchmark changes only its additions.

FRED_WEAVER_SOURCE=... FRED_SWIFT_SOURCE=... MOCK_OPENAI_SOURCE=... python3 -m unittest ...
Requires the same Helm/Helmfile tools as deployment, and PyYAML for assertions.
"""
import os
from pathlib import Path
import subprocess
import unittest

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[2]


def render(target, checkout, bench=""):
    env = {**os.environ, "DIR": checkout, "BENCH": bench, "K3D_IMAGE_VALUES": ""}
    helmfile = ROOT / "k3d-apps/fred/helmfile.yaml.gotmpl" if target != "bench" else Path(checkout) / "deploy/k3d/helmfile.yaml.gotmpl"
    cmd = ["helmfile", "-f", str(helmfile), "-e", target, "template"]
    if target == "bench" and bench:
        cmd += ["--values", str(ROOT / "k3d-apps/bench" / (bench + ".yaml"))]
    raw = subprocess.run(cmd, env=env, check=True, capture_output=True, text=True).stdout
    return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(raw) if isinstance(d, dict) and "kind" in d}


@unittest.skipUnless(yaml is not None, "render assertions require PyYAML")
class RenderTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("FRED_SWIFT_SOURCE"), "set FRED_SWIFT_SOURCE")
    def test_swift_only_appends_dedicated_profile_and_inherits_workers(self):
        normal = render("swift", os.environ["FRED_SWIFT_SOURCE"])
        bench = render("swift", os.environ["FRED_SWIFT_SOURCE"], "reference")
        seen = []
        for key, original in normal.items():
            actual = bench[key]
            if key[0] == "ConfigMap" and "models_catalog.yaml" in original.get("data", {}):
                before = yaml.safe_load(original["data"]["models_catalog.yaml"])
                after = yaml.safe_load(actual["data"]["models_catalog.yaml"])
                if key[1].startswith("fred-agents"):
                    self.assertEqual(after["profiles"][:-1], before["profiles"])
                    self.assertEqual(after["profiles"][-1]["profile_id"], "bench.chat.mock")
                    after["profiles"].pop()
                    self.assertEqual(after, before)
                    seen.append(key[1])
            if key[0] == "Deployment":
                self.assertEqual(original["spec"]["template"]["spec"], actual["spec"]["template"]["spec"])
        self.assertIn("fred-agents-catalog", seen)

    @unittest.skipUnless(os.environ.get("FRED_WEAVER_SOURCE"), "set FRED_WEAVER_SOURCE")
    def test_weaver_only_appends_source_credentials_and_leaves_kf_untouched(self):
        normal = render("weaver", os.environ["FRED_WEAVER_SOURCE"])
        bench = render("weaver", os.environ["FRED_WEAVER_SOURCE"], "reference")
        for key, original in normal.items():
            actual = bench[key]
            if key[0] == "ConfigMap" and "configuration.yaml" in original.get("data", {}):
                before = yaml.safe_load(original["data"]["configuration.yaml"])
                after = yaml.safe_load(actual["data"]["configuration.yaml"])
                if key[1] == "control-plane-backend-back":
                    platform = after["platform"]
                    self.assertEqual(platform["model_sources"][-1]["source_id"], "bench-mock")
                    platform["model_sources"].pop()
                    platform["inference_credentials"].pop()
                    self.assertEqual(platform["organization_models"], [])
                    platform["organization_models"] = before["platform"]["organization_models"]
                elif key[1] in ("fred-agents-back", "fred-agents-worker-back"):
                    self.assertEqual(after["inference_credentials"][-1]["credential_binding"], "bench-mock")
                    after["inference_credentials"].pop()
                self.assertEqual(after, before, key)
            if key[0] == "Deployment" and key[1] in ("control-plane-backend", "fred-agents", "fred-agents-worker"):
                a = actual["spec"]["template"]["spec"]["containers"][0]
                b = original["spec"]["template"]["spec"]["containers"][0]
                self.assertIn({"name": "BENCH_MOCK_API_KEY", "value": "key-1"}, a["env"])
                a["env"].remove({"name": "BENCH_MOCK_API_KEY", "value": "key-1"})
                self.assertEqual(a, b)

    @unittest.skipUnless(os.environ.get("MOCK_OPENAI_SOURCE"), "set MOCK_OPENAI_SOURCE")
    def test_mock_profiles_are_managed_by_helm(self):
        for profile in ("", "reference", "streaming"):
            rendered = render("bench", os.environ["MOCK_OPENAI_SOURCE"], profile)
            env = rendered[("Deployment", "mock-openai-server")]["spec"]["template"]["spec"]["containers"][0]["env"]
            self.assertEqual(next(x["value"] for x in env if x["name"] == "MOCK_BENCHMARK_PROFILE"), profile)


if __name__ == "__main__":
    unittest.main()
