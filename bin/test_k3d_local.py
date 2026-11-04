"""Operator contract tests. All deployment commands are mocked; no real cluster."""

import importlib.machinery
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("local", str(Path(__file__).with_name("k3d-local")))
spec = importlib.util.spec_from_loader(loader.name, loader)
local = importlib.util.module_from_spec(spec)
loader.exec_module(local)


class LocalTests(unittest.TestCase):
    def test_environment_selectors_are_rejected_even_when_empty(self):
        for key in ("ENV", "INSTANCE", "MODE", "PROFILE", "STACK", "DIR", "K3D_NAMESPACE", "K3D_REUSE_IMAGES"):
            with self.subTest(key=key), patch.dict(os.environ, {key: ""}, clear=True):
                with self.assertRaisesRegex(ValueError, key):
                    local.environment()

    def test_namespace_database_and_url_are_derived_together(self):
        for name, namespace, database in (("swift", "fred", "fred"), ("weaver", "fred-weaver", "fred_weaver")):
            env = local.app_environment({}, name)
            self.assertEqual(env["K3D_NAMESPACE"], namespace)
            self.assertEqual(env["K3D_DATABASE"], database)
            self.assertEqual(env["K3D_PUBLIC_URL"], f"http://{local.APPLICATIONS[name][1]}:8088")
        self.assertIn("openfga.enabled=false", local.infrastructure_args(("weaver",)))
        self.assertIn("openfga.enabled=true", local.infrastructure_args(("swift", "weaver")))

    def test_solo_transitions_cannot_remove_an_application(self):
        for present in ({"swift"}, {"weaver"}, {"swift", "weaver"}):
            local.require_superset(("swift", "weaver"), present)
        for requested, present in ((("swift",), {"weaver"}), (("weaver",), {"swift"}), (("swift",), {"swift", "weaver"})):
            with self.assertRaisesRegex(ValueError, "make k3d-up,"):
                local.require_superset(requested, present)

    def test_unreachable_cluster_is_not_treated_as_empty(self):
        with patch.object(local, "run", side_effect=[
            '[{"name":"fred"}]', subprocess.CalledProcessError(1, ["kubectl"]),
        ]):
            with self.assertRaises(subprocess.CalledProcessError):
                local.existing_installation({})

    def test_partial_installation_is_protected_before_releases_exist(self):
        # "migration" is what clusters prepared before k3d-up recorded.
        for recorded in ("both", "migration"):
            with self.subTest(recorded=recorded), patch.object(local, "run", side_effect=[
                '[{"name":"fred"}]', json.dumps({"data": {"installation": recorded}}), '[]', '',
            ]):
                self.assertEqual(local.existing_installation({}), {"swift", "weaver"})

    def test_legacy_helm_releases_are_not_lost_without_marker(self):
        with patch.object(local, "run", side_effect=[
            '[{"name":"fred"}]', '', '[{"namespace":"fred"}]', 'namespace/fred-weaver',
        ]):
            self.assertEqual(local.existing_installation({}), {"swift", "weaver"})

    def test_unknown_recorded_state_fails_closed(self):
        with patch.object(local, "run", side_effect=[
            '[{"name":"fred"}]', '{"data":{"installation":"unknown"}}',
        ]):
            with self.assertRaisesRegex(ValueError, "Unknown"):
                local.existing_installation({})

    def test_application_inputs_are_allowed_only_for_application_commands(self):
        for key in local.APP_INPUTS & local.SELECTORS:
            with self.subTest(key=key), patch.dict(os.environ, {key: "value"}, clear=True):
                self.assertEqual(local.environment(application=True)[key], "value")
                with self.assertRaisesRegex(ValueError, key):
                    local.environment()
        for key in ("ENV", "INSTANCE", "K3D_NAMESPACE"):
            with self.subTest(key=key), patch.dict(os.environ, {key: ""}, clear=True):
                with self.assertRaisesRegex(ValueError, key):
                    local.environment(application=True)

    def test_application_placement_follows_checkout_and_preserves_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift, weaver = root / "swift", root / "weaver"
            swift.mkdir()
            (weaver / "apps/control-plane").mkdir(parents=True)
            (weaver / "apps/control-plane/Cargo.toml").write_text("[package]\n")
            for path, namespace in ((swift, "fred"), (weaver, "fred-weaver")):
                for operation, action in local.APP_OPERATIONS.items():
                    with self.subTest(path=path, operation=operation), patch.object(local, "run") as run:
                        env = {"APP": "fred", "DIR": str(path), "VALUES": "/extra.yaml"}
                        local.application(operation, env)
                        run.assert_called_once()
                        command, context = run.call_args.args
                        self.assertEqual(command, [str(local.ROOT / "bin/k3d-app.sh"), action])
                        self.assertEqual(context["K3D_NAMESPACE"], namespace)
                        self.assertTrue(env.items() <= context.items())

    def test_make_application_command_passes_inputs_and_uses_checkout_placement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "k3d").mkdir()
            for name in ("Makefile", "bin/k3d-local", "k3d/local.env"):
                shutil.copy(local.ROOT / name, root / name)
            engine = root / "bin/k3d-app.sh"
            engine.write_text(
                "#!/usr/bin/env python3\nimport json, os, sys\n"
                "print(json.dumps([sys.argv[1], os.environ['APP'], os.environ['DIR'], os.environ['K3D_NAMESPACE']]))\n"
            )
            engine.chmod(0o755)
            checkout = root / "weaver checkout"
            (checkout / "apps/control-plane").mkdir(parents=True)
            (checkout / "apps/control-plane/Cargo.toml").write_text("[package]\n")
            env = {key: value for key, value in os.environ.items()
                   if key not in local.SELECTORS and not key.startswith("K3D_")
                   and key not in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES")}
            result = subprocess.run(
                ["make", "--no-print-directory", "k3d-app", "APP=fred", f"DIR={checkout}"],
                cwd=root, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), ["deploy", "fred", str(checkout), "fred-weaver"])

    def test_published_application_does_not_require_a_checkout(self):
        with patch.object(local, "run") as run:
            local.application("k3d-app", {"APP": "fred", "RELEASE": "3.6.0"})
            self.assertEqual(run.call_args.args[1]["K3D_NAMESPACE"], "fred")
            self.assertEqual(run.call_args.args[1]["RELEASE"], "3.6.0")

    def test_validate_never_reads_cluster_or_calls_provisioning(self):
        with (
            patch.object(local.shutil, "which", return_value="tool"),
            patch.object(local, "existing_installation") as existing,
            patch.object(local, "run", return_value="") as run,
        ):
            local.install("k3d-validate", {})
            existing.assert_not_called()
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual([command[:2] for command in commands], [["helm", "lint"], ["helm", "template"]])

    def test_render_failure_happens_before_any_mutation(self):
        with (
            patch.object(local.shutil, "which", return_value="tool"),
            patch.object(local, "existing_installation", return_value=set()),
            patch.object(local, "run", side_effect=subprocess.CalledProcessError(1, ["helm"])) as run,
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                local.install("k3d-up-weaver", {})
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:2], ["helm", "lint"])

    def test_infrastructure_up_needs_neither_checkout_nor_model_key_and_never_deploys_apps(self):
        for operation, installation in (("k3d-up", "both"), ("k3d-up-swift", "swift"), ("k3d-up-weaver", "weaver")):
            with (
                tempfile.TemporaryDirectory() as directory,
                self.subTest(installation=installation),
                patch.object(local, "ROOT", Path(directory)),
                patch.object(local.shutil, "which", return_value="tool"),
                patch.object(local, "existing_installation", return_value=set()),
                patch.object(local, "run", return_value="") as run,
            ):
                local.install(operation, {})
                commands = [call.args[0] for call in run.call_args_list]
                self.assertFalse(any("k3d-app.sh" in " ".join(command) for command in commands))
                self.assertFalse(any("fred-model-credentials" in command for command in commands))
                self.assertTrue(any(command[0] == "make" and command[-1] == "up" for command in commands))
                self.assertEqual(any(command[0].endswith("k3d-instance") for command in commands), installation != "swift")
                marker = next(call.kwargs["body"] for call in run.call_args_list if "body" in call.kwargs)
                self.assertEqual(json.loads(marker)["data"]["installation"], installation)

    def test_k3d_up_prepares_both_applications_and_the_old_name_is_removed(self):
        self.assertEqual(local.INFRASTRUCTURE["k3d-up"], ("up", "both"))
        self.assertEqual(local.INSTALLATIONS["both"], ("swift", "weaver"))
        self.assertNotIn("k3d-up-migration", local.OPERATIONS)
        result = subprocess.run(
            ["make", "--no-print-directory", "k3d-up-migration"],
            cwd=local.ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("make k3d-up", result.stderr)

    def test_wipe_is_scoped_and_does_not_deploy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            owned = root / ".cache/k3d-apps/fred"
            other = root / ".cache/k3d-apps/other"
            owned.mkdir(parents=True)
            other.mkdir()
            with (
                patch.object(local, "ROOT", root),
                patch.object(local.tempfile, "gettempdir", return_value=directory),
                patch.object(local.sys, "argv", ["k3d-local", "k3d-wipe"]),
                patch.object(local, "environment", return_value={}),
                patch.object(local, "run") as run,
            ):
                local.main()
            run.assert_called_once_with(["k3d", "cluster", "delete", "fred"], {})
            self.assertFalse(owned.exists())
            self.assertTrue(other.exists())


if __name__ == "__main__":
    unittest.main()
