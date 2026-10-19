"""Command fixtures for a data-preserving Helm release transition; no cluster access."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import yaml

spec = importlib.util.spec_from_file_location("transition", Path(__file__).with_name("manager-transition.py"))
transition = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transition)


class TransitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = patch.dict(os.environ, KUBE_CONTEXT="k3d-test", K3D_NAMESPACE="test", K3D_APP_OUT=self.temp.name, K3D_APP_VALUES_JSON="[]")
        self.env.start()
        self.addCleanup(self.env.stop)
        self.calls = []
        self.releases = [{"status": "deployed"}]
        self.old = [{"kind": kind, "metadata": {"name": name, "namespace": "test"}} for kind, name in sorted(transition.OWNED)]
        cfg = {"storage": {"postgres": {"host": "postgres"}}, "security": {
            "rebac": {"api_url": "http://openfga:9080", "store_name": "fred-manager"},
            "user": {"client_id": "app"}, "m2m": {"client_id": "fred-manager"}}, "app": {"gcu_version": "v1"}}
        for doc in self.old:
            if doc["kind"] == "Deployment":
                doc["spec"] = {"template": {"spec": {"containers": [{"env": [{"name": "FRED_POSTGRES_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "fred-secrets", "key": "POSTGRES_FRED_PASSWORD"}}}]}], "volumes": [{"name": "config", "configMap": {"name": "fred-manager-back"}}]}}}
            if doc["kind"] == "Secret":
                doc["data"] = {".env": ""}
            if doc["metadata"]["name"] == "fred-manager-back":
                doc["data"] = {"configuration.yaml": yaml.safe_dump(cfg)}
        next(d for d in self.old if d["metadata"]["name"] == "fred-manager-catalog")["data"] = {"lifecycle_policy_catalog.yaml": "version: v1"}
        self.live = copy.deepcopy(self.old)
        self.new = copy.deepcopy(self.old)
        self.new += [{"kind": "Deployment", "metadata": {"name": name}} for name in transition.WORKLOADS - {"fred-manager", "fred-manager-worker"}]
        self.claims = []
        self.hooks = ""
        self.bad_owner = False
        self.fail = None
        self.active = patch.object(transition, "integrated", return_value=True)
        self.active.start()
        self.addCleanup(self.active.stop)
        self.commands = patch.object(transition, "run", side_effect=self.run_command)
        self.commands.start()
        self.addCleanup(self.commands.stop)

    def run_command(self, args):
        self.calls.append(args)
        if self.fail and self.fail(args):
            raise RuntimeError("injected failure")
        if args[0] == "helmfile":
            return yaml.safe_dump_all(self.new)
        self.assertEqual(args[1:3], ["--kube-context" if args[0] == "helm" else "--context", "k3d-test"])
        if "list" in args:
            return json.dumps(self.releases)
        if "manifest" in args:
            return yaml.safe_dump_all(self.old)
        if "hooks" in args:
            return self.hooks
        if "values" in args:
            return "private recovery value"
        if "uninstall" in args:
            self.releases = []
            return ""
        if "pvc" in args:
            return json.dumps({"items": self.claims})
        kind, name = args[6:8]
        live = copy.deepcopy(next(d for d in self.live if (d["kind"], d["metadata"]["name"]) == (kind, name)))
        live["metadata"]["annotations"] = {"meta.helm.sh/release-name": "other" if self.bad_owner else "fred-manager", "meta.helm.sh/release-namespace": "test"}
        return json.dumps(live)

    def assert_no_removal(self):
        self.assertFalse(any("uninstall" in args for args in self.calls))

    def test_transition_preserves_recovery_and_rerun_converges(self):
        transition.migrate()
        transition.migrate()
        removal = [c for c in self.calls if "uninstall" in c]
        self.assertEqual(len(removal), 1)
        self.assertIn("--wait", removal[0])
        self.assertEqual(removal[0][-4:-2], ["--cascade", "foreground"])
        backup = next(Path(self.temp.name).iterdir())
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        for path in backup.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertIn("private recovery value", (backup / "values.yaml").read_text())

    def test_normalized_values_are_reused_from_invocation(self):
        args = ["--values", "/invocation/relative/values.yaml"]
        with patch.dict(os.environ, K3D_APP_VALUES_JSON=json.dumps(args)):
            transition.migrate()
        render = next(c for c in self.calls if c[0] == "helmfile")
        self.assertEqual(render[-2:], args)

    def test_live_lifecycle_drift_is_refused_before_removal(self):
        cfg = next(d for d in self.live if d["metadata"]["name"] == "fred-manager-back")
        cfg["data"]["configuration.yaml"] += "scheduler: {lifecycle: {enabled: true}}\n"
        with self.assertRaisesRegex(RuntimeError, "configuration"):
            transition.migrate()
        self.assert_no_removal()

    def test_live_catalog_drift_is_refused_before_removal(self):
        next(d for d in self.live if d["metadata"]["name"] == "fred-manager-catalog")["data"] = {"custom": "policy"}
        with self.assertRaisesRegex(RuntimeError, "catalog"):
            transition.migrate()
        self.assert_no_removal()

    def test_live_credentials_drift_is_refused_before_removal(self):
        deployment = next(d for d in self.live if d["kind"] == "Deployment")
        deployment["spec"]["template"]["spec"]["containers"][0]["env"][0]["valueFrom"]["secretKeyRef"]["name"] = "custom"
        with self.assertRaisesRegex(RuntimeError, "credential"):
            transition.migrate()
        self.assert_no_removal()

    def test_overlay_preserves_standalone_secret_references(self):
        overlay = yaml.safe_load(Path(__file__).with_name("manager-values.yaml").read_text())
        for name in ("fred-manager", "fred-manager-worker"):
            env = overlay["applications"][name]["extraEnvVars"]
            for e in env:
                self.assertIs(e["valueFrom"]["secretKeyRef"]["optional"], False)
            for docs in (self.live, self.new):
                deployment = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
                deployment["spec"]["template"]["spec"]["containers"][0]["env"] = copy.deepcopy(env)
        transition.migrate()

    def test_fresh_install_does_not_remove_anything(self):
        self.releases = []
        transition.migrate()
        self.assert_no_removal()

    def test_unexpected_resource_or_pvc_is_refused(self):
        self.old.append({"kind": "PersistentVolumeClaim", "metadata": {"name": "data"}})
        with self.assertRaisesRegex(RuntimeError, "persistent resources"):
            transition.migrate()
        self.assert_no_removal()

    def test_orphaned_pvc_is_refused(self):
        self.claims = [{"metadata": {"annotations": {"meta.helm.sh/release-name": "fred-manager"}}}]
        with self.assertRaisesRegex(RuntimeError, "persistent claim"):
            transition.migrate()
        self.assert_no_removal()

    def test_foreign_owner_is_refused(self):
        self.bad_owner = True
        with self.assertRaisesRegex(RuntimeError, "ownership"):
            transition.migrate()
        self.assert_no_removal()

    def test_hooks_are_refused(self):
        self.hooks = "kind: Job\nmetadata: {name: cleanup}"
        with self.assertRaisesRegex(RuntimeError, "hooks"):
            transition.migrate()
        self.assert_no_removal()

    def test_data_destination_change_is_refused(self):
        cfg = next(d for d in self.new if d["metadata"]["name"] == "fred-manager-back")
        cfg["data"]["configuration.yaml"] = cfg["data"]["configuration.yaml"].replace("postgres", "different")
        with self.assertRaisesRegex(RuntimeError, "configuration"):
            transition.migrate()
        self.assert_no_removal()

    def test_render_failure_precedes_removal(self):
        self.fail = lambda args: args[0] == "helmfile"
        with self.assertRaisesRegex(RuntimeError, "injected"):
            transition.migrate()
        self.assert_no_removal()

    def test_failed_uninstall_retains_recovery(self):
        self.fail = lambda args: "uninstall" in args
        with self.assertRaisesRegex(RuntimeError, "injected"):
            transition.migrate()
        self.assertTrue(list(Path(self.temp.name).glob("*/manifest.yaml")))

    def test_extra_legacy_workload_is_refused(self):
        self.new.append({"kind": "Deployment", "metadata": {"name": "control-plane-backend"}})
        with self.assertRaisesRegex(RuntimeError, "five workloads"):
            transition.migrate()
        self.assert_no_removal()


if __name__ == "__main__":
    unittest.main()
