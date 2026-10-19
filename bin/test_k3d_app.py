"""Command-level tests of bin/k3d-app.sh with fake commands; never a real cluster."""

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
    built = Path(os.environ["K3D_IMAGE_VALUES"]).read_text().strip() != "{}"
    if os.environ.get("FAIL_RENDER") == "1" or (os.environ.get("FAIL_FINAL_RENDER") == "1" and built):
        sys.exit(1)
if name == "helmfile" and "sync" in args and os.environ.get("FAIL_SYNC") == "1":
    sys.exit(1)
if name == "helmfile" and "list" in args:
    print(json.dumps([{"name": "app-a", "namespace": "", "enabled": True},
                      {"name": "app-b", "namespace": "other-ns", "enabled": True},
                      {"name": "off", "namespace": "", "enabled": False}]))
if name == "helm" and "status" in args:
    print(json.dumps({"info": {"status": os.environ.get("RELEASE_STATUS", "deployed")}}))
if name == "helm" and "history" in args:
    print("[]")
if name == "kubectl" and "pvc" in args:
    print(json.dumps({"items": [{"metadata": {"name": "data", "annotations": {"meta.helm.sh/release-name": "app-a"}}}]}))
"""
HOOK = """#!/bin/bash
printf '["%s", "%s", "%s", "%s", "%s", "%s", "%s"]\\n' "$(basename "$0")" "$KUBE_CONTEXT" "$PWD" "$FRED_LIBS" "${FRED_REPO:-}" "${K3D_APP_CHECKOUT:-}" "${RELEASE:-}" >> "$CALLS"
if [[ "$(basename "$0")" == build ]]; then
  [[ -n "${FAIL_BUILD:-}" ]] && exit 1
  echo 'app:k3d-1' > "$K3D_APP_OUT/images.txt"
  echo 'image: {tag: k3d-1}' > "$K3D_APP_OUT/images.yaml"
fi
exit 0
"""


class K3dAppTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="k3d app ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.factory = self.root / "factory checkout"
        (self.factory / "bin").mkdir(parents=True)
        for name in ("k3d-app.sh", "k3d-helm-recover.sh", "k3d-identities"):
            shutil.copy(ROOT / "bin" / name, self.factory / "bin" / name)
        realm = self.factory / "k3d/files/keycloak"
        realm.mkdir(parents=True)
        shutil.copy(ROOT / "k3d/files/keycloak/app-realm.json.template", realm)
        prefetch = self.factory / "bin/k3d-prefetch-images.sh"
        prefetch.write_text('#!/bin/bash\nprintf \'["import", "%s"]\\n\' "$2" >> "$CALLS"\n')
        prefetch.chmod(0o755)
        self.app = self.root / "some app/deploy/k3d"
        self.app.mkdir(parents=True)
        (self.app / "helmfile.yaml.gotmpl").write_text("releases: []\n")
        for hook in ("build", "prepare", "finish"):
            (self.app / hook).write_text(HOOK)
            (self.app / hook).chmod(0o755)
        (self.root / "extra-values.yaml").write_text("{}\n")
        fakebin = self.root / "commands"
        fakebin.mkdir()
        for name in ("helm", "helmfile", "kubectl"):
            (fakebin / name).write_text(FAKE)
            (fakebin / name).chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{fakebin}:{os.environ['PATH']}",
            CALLS=str(self.root / "calls"),
            DIR="some app",
            K3D_CLUSTER="other",
        )
        for name in ("VALUES", "K3D_NAMESPACE", "KUBE_CONTEXT", "FRED_LIBS", "FRED_REPO",
                     "APP", "RELEASE", "K3D_APP_CHECKOUT"):
            self.env.pop(name, None)
        # An application defined in this repository: no build of its own.
        self.defined = self.factory / "k3d-apps/my-app"
        self.defined.mkdir(parents=True)
        (self.defined / "helmfile.yaml.gotmpl").write_text("releases: []\n")
        for hook in ("prepare", "finish"):
            (self.defined / hook).write_text(HOOK)
            (self.defined / hook).chmod(0o755)

    def run_app(self, mode: str = "deploy", **env: str) -> tuple[subprocess.CompletedProcess, list]:
        (self.root / "calls").unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", str(self.factory / "bin/k3d-app.sh"), mode],
            cwd=self.root,
            env=self.env | env,
            capture_output=True,
            text=True,
        )
        log = self.root / "calls"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_dir_resolves_the_checkout_or_the_directory_itself(self) -> None:
        for directory in ("some app", "some app/deploy/k3d"):
            with self.subTest(directory=directory):
                result, _ = self.run_app("validate", DIR=directory)
                self.assertEqual(result.returncode, 0, result.stderr)
        result, calls = self.run_app("validate", DIR=".")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("helmfile.yaml.gotmpl", result.stderr)
        self.assertEqual(calls, [])

    def test_fred_libs_selects_which_fred_the_hooks_build_against(self) -> None:
        result, calls = self.run_app()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({tuple(c[3:5]) for c in calls if c[0] == "build"}, {("pypi", "")})
        self.assertIn("FRED_LIBS=pypi", result.stdout)

        fred = self.root / "fred checkout"
        (fred / "libs").mkdir(parents=True)
        (fred / "deploy/charts").mkdir(parents=True)
        result, calls = self.run_app(FRED_LIBS="local", FRED_REPO=str(fred))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({tuple(c[3:5]) for c in calls if c[0] == "build"}, {("local", str(fred))})
        self.assertIn(f"libraries and charts from {fred}", result.stdout)

    def test_fred_libs_refuses_what_it_cannot_build_against(self) -> None:
        for env, message in (
            ({"FRED_LIBS": "main"}, "must be pypi or local"),
            ({"FRED_LIBS": "local"}, "needs FRED_REPO, the path of YOUR fred checkout"),
            ({"FRED_LIBS": "local", "FRED_REPO": str(self.root / "nowhere")}, "no such directory"),
            ({"FRED_LIBS": "local", "FRED_REPO": str(self.root)}, "is not a fred checkout"),
        ):
            with self.subTest(env=env):
                result, calls = self.run_app("validate", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(calls, [])

    def test_validate_has_no_build_or_cluster_calls(self) -> None:
        result, calls = self.run_app("validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["helmfile", "helmfile"])
        self.assertIn("own images", result.stdout)

    def test_missing_values_fail_before_commands(self) -> None:
        result, calls = self.run_app(VALUES="missing.yaml")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_extra_values_reach_every_render_and_the_sync(self) -> None:
        result, calls = self.run_app(VALUES="extra-values.yaml")
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in calls:
            if call[0] == "helmfile" and ("template" in call or "sync" in call):
                self.assertIn(str(self.root / "extra-values.yaml"), call)

    def test_normalized_values_reach_hooks_after_directory_change(self) -> None:
        hook = self.app / "prepare"
        hook.write_text(HOOK.replace("exit 0", 'printf %s "$K3D_APP_VALUES_JSON" > "$CALLS.normalized"\nexit 0'))
        result, _ = self.run_app(VALUES="extra-values.yaml")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "calls.normalized").read_text()), ["--values", str(self.root / "extra-values.yaml")])

    def test_failed_sync_does_not_finish_and_retry_succeeds(self) -> None:
        result, calls = self.run_app(FAIL_SYNC="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(c[0] == "prepare" for c in calls))
        self.assertFalse(any(c[0] == "finish" for c in calls))
        result, calls = self.run_app()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[0] == "finish" for c in calls))

    def test_failures_stop_before_mutations(self) -> None:
        for failure in ("FAIL_RENDER", "FAIL_FINAL_RENDER", "FAIL_BUILD"):
            with self.subTest(failure=failure):
                result, calls = self.run_app(**{failure: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    any(c[0] in ("import", "prepare", "helm") or "sync" in c for c in calls)
                )
                if failure == "FAIL_RENDER":
                    self.assertFalse(any(c[0] == "build" for c in calls))

    def test_order_context_and_hooks(self) -> None:
        result, calls = self.run_app()
        self.assertEqual(result.returncode, 0, result.stderr)
        names = [c[0] if c[0] != "helmfile" else c[-1] if "list" in c else next(
            a for a in c if a in ("lint", "template", "sync", "list")) for c in calls]
        build, imported = names.index("build"), names.index("import")
        renders = [i for i, n in enumerate(names) if n == "template"]
        self.assertLess(renders[0], build)
        self.assertLess(build, renders[1])
        self.assertLess(renders[1], imported)
        self.assertLess(imported, names.index("prepare"))
        self.assertLess(names.index("prepare"), names.index("sync"))
        self.assertLess(names.index("sync"), names.index("finish"))
        self.assertEqual(calls[imported], ["import", "app:k3d-1"])
        for call in calls:
            if call[0] in ("build", "prepare", "finish"):
                self.assertEqual(call[1:3], ["k3d-other", str(self.app)])
            if call[0] == "helmfile":
                self.assertEqual(call[3:5], ["--kube-context", "k3d-other"])
            if call[0] in ("helm", "kubectl"):
                self.assertEqual(call[2], "k3d-other")
            self.assertNotIn("use-context", call)
        # Every enabled release is recovered, in its own namespace or the default one.
        statuses = [c for c in calls if c[0] == "helm" and "status" in c]
        self.assertEqual([(c[4], c[6]) for c in statuses], [("app-a", "fred"), ("app-b", "other-ns")])

    def test_recovery_refuses_to_delete_persistent_claims(self) -> None:
        result, calls = self.run_app(RELEASE_STATUS="failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owns volumes", result.stderr)
        self.assertFalse(any("uninstall" in c or "sync" in c for c in calls))

    def test_refused_identities_stop_before_any_command(self) -> None:
        (self.app / "identities.yaml").write_text(
            "clients:\n  - id: app\n    secret: APP_SECRET\n    grants: [realm-management/realm-admin]\n"
        )
        for mode in ("validate", "deploy"):
            with self.subTest(mode=mode):
                result, calls = self.run_app(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("platform client", result.stderr)
                self.assertIn("realm-management/realm-admin refused", result.stderr)
                # At most the read-only check that fred-secrets exists.
                self.assertTrue(all(c[0] == "kubectl" and "get" in c for c in calls), calls)

    def test_valid_identities_pass_the_check(self) -> None:
        (self.app / "identities.yaml").write_text(
            "clients:\n  - id: my-worker\n    secret: MY_WORKER_SECRET\n    grants: [app/service_agent]\n"
        )
        result, _ = self.run_app("validate")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_app_deploys_its_published_release_without_a_build(self) -> None:
        # An earlier development build must not leak its images into a release.
        result, _ = self.run_app(APP="my-app", DIR="some app")
        self.assertEqual(result.returncode, 0, result.stderr)
        for env in ({}, {"RELEASE": "3.6.0"}):
            with self.subTest(env=env):
                result, calls = self.run_app(APP="my-app", DIR="", **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(c[0] in ("build", "import") for c in calls))
                hooks = [c for c in calls if c[0] in ("prepare", "finish")]
                self.assertEqual([c[0] for c in hooks], ["prepare", "finish"])
                for call in hooks:
                    self.assertEqual(call[2:3] + call[5:], [str(self.defined), "", env.get("RELEASE", "")])
                (images,) = (self.factory / ".cache/k3d-apps").glob("my-app-*/images.yaml")
                self.assertEqual(images.read_text().strip(), "{}")

    def test_app_with_dir_builds_the_checkout(self) -> None:
        result, calls = self.run_app(APP="my-app")
        self.assertEqual(result.returncode, 0, result.stderr)
        checkout = str(self.root / "some app")
        build = next(c for c in calls if c[0] == "build")
        self.assertEqual(build[2], str(self.app))
        self.assertEqual(build[5], checkout)
        self.assertIn(["import", "app:k3d-1"], calls)
        for call in calls:
            if call[0] in ("prepare", "finish"):
                self.assertEqual([call[2], call[5]], [str(self.defined), checkout])

    def test_app_refuses_what_it_cannot_deploy(self) -> None:
        for env, message in (
            ({"APP": "nowhere"}, "APP=nowhere is not defined here; defined: my-app"),
            ({"APP": "../my-app"}, "is not defined here"),
            ({"APP": "my-app", "RELEASE": "latest", "DIR": ""}, "must be a release version"),
            ({"APP": "my-app", "RELEASE": "3.6.0"}, "choose one"),
            ({"APP": "my-app", "DIR": "."}, "has no executable deploy/k3d/build"),
            ({"DIR": ""}, "APP or DIR is required"),
        ):
            with self.subTest(env=env):
                result, calls = self.run_app("validate", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(calls, [])

    def test_uninstall_refuses_a_release_owning_volumes(self) -> None:
        result, calls = self.run_app("uninstall")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owns volumes", result.stderr)
        self.assertFalse(any("destroy" in c for c in calls))


if __name__ == "__main__":
    unittest.main()
