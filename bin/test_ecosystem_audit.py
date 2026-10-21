"""Tests of bin/ecosystem-audit on fake checkouts; offline, never PyPI or npm."""

import importlib.machinery
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_loader = importlib.machinery.SourceFileLoader("ecosystem_audit", str(ROOT / "bin/ecosystem-audit"))
_spec = importlib.util.spec_from_loader("ecosystem_audit", _loader)
audit_module = importlib.util.module_from_spec(_spec)
_loader.exec_module(audit_module)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def commit(repo):
    """A checkout whose HEAD is origin/swift, as after a clone."""
    run = lambda *args: subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
    run("init", "-q", "-b", "swift")
    run("add", "-A")
    run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init")
    run("update-ref", "refs/remotes/origin/swift", "HEAD")


SWITCH = "FRED_LIBS ?= pypi\nexport UV_NO_SYNC := 1\ndev-local:\n\ttrue\n"


def app(root, name, spec, locked, npm=None, npm_locked=None):
    repo = root / name
    write(repo / "pyproject.toml", f'[project]\nname = "{name}"\ndependencies = ["fred-sdk{spec}"]\n')
    write(repo / "uv.lock", f'[[package]]\nname = "fred-sdk"\nversion = "{locked}"\n')
    write(repo / "Makefile", SWITCH)
    if npm:
        write(repo / "ui/package.json", json.dumps({"dependencies": {"@fred-oss/ui": npm}}))
        write(repo / "ui/package-lock.json", json.dumps(
            {"packages": {"node_modules/@fred-oss/ui": {"version": npm_locked or npm}}}))
    commit(repo)


class EcosystemAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        fred = self.root / "fred"
        write(fred / "libs/fred-sdk/pyproject.toml", '[project]\nname = "fred-sdk"\nversion = "4.5.0"\n')
        write(fred / "libs/frontend/ui/package.json", json.dumps({"name": "@fred-oss/ui", "version": "0.2.0"}))
        commit(fred)

    def tearDown(self):
        self.tmp.cleanup()

    def run_audit(self):
        report = audit_module.audit(self.root, "swift", fetch=False, offline=True)
        return report, "\n".join(line for lines in report.lines.values() for line in lines)

    def test_aligned_workspace_has_no_error(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0", npm="0.1.0")
        app(self.root, "app-b", ">=4.4,<5", "4.5.0", npm="0.1.0")
        report, text = self.run_audit()
        self.assertEqual(report.errors, 0, text)

    def test_stale_lock_and_excluding_constraint(self):
        app(self.root, "app-a", "==4.4.3", "4.4.3")
        _, text = self.run_audit()
        self.assertIn("fred-sdk==4.4.3 excludes 4.5.0", text)
        self.assertIn("app-a/uv.lock: 4.4.3 (fred-sdk), expected 4.5.0", text)

    def add_library(self, name, version):
        write(self.root / f"fred/libs/{name}/pyproject.toml", f'[project]\nname = "{name}"\nversion = "{version}"\n')

    def multi_app(self, locked):
        """An application on several Fred libraries, locked at the given versions."""
        repo = self.root / "app-m"
        deps = ", ".join(f'"{name}>=4.0"' for name in locked)
        write(repo / "pyproject.toml", f'[project]\nname = "app-m"\ndependencies = [{deps}]\n')
        write(repo / "uv.lock", "".join(f'[[package]]\nname = "{n}"\nversion = "{v}"\n' for n, v in locked.items()))
        write(repo / "Makefile", SWITCH)
        commit(repo)

    def test_each_library_has_its_own_version(self):
        self.add_library("fred-pod", "4.4.1")
        self.multi_app({"fred-sdk": "4.5.0", "fred-pod": "4.4.1"})
        report, text = self.run_audit()
        self.assertEqual(report.errors, 0, text)

        self.multi_app({"fred-sdk": "4.5.0", "fred-pod": "4.4.0"})
        report, text = self.run_audit()
        self.assertIn("app-m/uv.lock: 4.4.0 (fred-pod), expected 4.4.1", text)
        self.assertEqual(report.errors, 1, text)

    def test_reference_is_the_latest_on_pypi_for_each_library(self):
        self.add_library("fred-pod", "4.4.2")
        self.add_library("fred-new", "0.1.0")
        self.multi_app({"fred-sdk": "4.5.0", "fred-pod": "4.4.1"})
        pypi = {"fred-sdk": "4.5.1", "fred-pod": "4.4.1", "fred-new": None}
        original = audit_module.latest_pypi, audit_module.latest_npm
        audit_module.latest_pypi, audit_module.latest_npm = pypi.get, lambda name: "0.2.0"
        try:
            report = audit_module.audit(self.root, "swift", fetch=False, offline=False)
        finally:
            audit_module.latest_pypi, audit_module.latest_npm = original
        text = "\n".join(line for lines in report.lines.values() for line in lines)
        self.assertIn("fred-sdk: 4.5.0 in the source, behind PyPI (4.5.1)", text)
        self.assertIn("fred-pod: 4.4.2 in the source, not yet on PyPI (latest 4.4.1)", text)
        self.assertIn("fred-new: 0.1.0 in the source, never published", text)
        self.assertIn("app-m/uv.lock: 4.5.0 (fred-sdk), expected 4.5.1", text)
        self.assertEqual(report.errors, 1, text)

    def test_committed_merge_conflict_is_reported(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0")
        write(self.root / "app-a/uv.lock", "<<<<<<< HEAD\n")
        report, text = self.run_audit()
        self.assertIn("app-a/uv.lock: Invalid statement", text)
        self.assertEqual(report.errors, 1, text)

    def test_copy_of_fred_is_set_apart(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0")
        write(self.root / "app-a/vendored/pyproject.toml", '[project]\nname = "fred-sdk"\nversion = "1.0"\n')
        write(self.root / "app-a/old/pyproject.toml",
              '[project]\nname = "old"\ndependencies = ["fred-sdk"]\n'
              '[tool.uv.sources]\nfred-sdk = { path = "../vendored", editable = true }\n')
        write(self.root / "app-a/old/uv.lock", '[[package]]\nname = "fred-sdk"\nversion = "1.0"\n')
        report, text = self.run_audit()
        self.assertIn("app-a/old/pyproject.toml: uses fred-sdk -> ../vendored", text)
        self.assertIn("app-a/vendored/pyproject.toml: a copy of fred-sdk", text)
        self.assertEqual(report.errors, 0, text)

    def test_committed_fred_source_is_refused(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0")
        write(self.root / "app-a/pyproject.toml",
              '[project]\nname = "app-a"\ndependencies = ["fred-sdk>=4.5.0"]\n'
              '[tool.uv.sources]\nfred-sdk = { path = "../fred/libs/fred-sdk", editable = true }\n')
        report, text = self.run_audit()
        self.assertIn("ERROR app-a/pyproject.toml: [tool.uv.sources] fred-sdk -> ../fred/libs/fred-sdk", text)
        self.assertEqual(report.errors, 1, text)

    def test_fred_source_switch_in_makefile_dockerfile_and_helmfile(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0")
        repo = self.root / "app-a"
        write(repo / "Makefile", "dev:\n\ttrue\n")
        write(repo / "Dockerfile", "FROM python\nRUN uv sync --frozen\n")
        write(repo / "deploy/k3d/helmfile.yaml.gotmpl", "releases:\n  - chart: oci://ghcr.io/thalesgroup/fred-helm/agent-pod\n")
        _, text = self.run_audit()
        self.assertIn("app-a: no Makefile with FRED_LIBS and dev-local", text)
        self.assertIn("app-a/Dockerfile: no ARG FRED_LIBS", text)
        self.assertIn("app-a/deploy/k3d/helmfile.yaml.gotmpl: a fred chart without the FRED_LIBS switch", text)

        write(repo / "Makefile", "FRED_LIBS ?= pypi\ndev-local:\n\ttrue\n")
        _, text = self.run_audit()
        self.assertIn("app-a/Makefile: dev-local without UV_NO_SYNC", text)

        write(repo / "Makefile", "FRED_REPO ?= $(abspath ../fred)\n" + SWITCH)
        _, text = self.run_audit()
        self.assertIn("app-a/Makefile: FRED_REPO has a default", text)

        write(repo / "make/fred.mk", "FRED_REPO ?=\n" + SWITCH)
        write(repo / "Makefile", "include make/fred.mk\n")
        write(repo / "Dockerfile", "ARG FRED_LIBS=pypi\nFROM python\nRUN uv sync --frozen\n")
        write(repo / "deploy/k3d/helmfile.yaml.gotmpl", '{{ if eq (env "FRED_LIBS") "local" }}{{ end }}fred-helm/agent-pod\n')
        report, text = self.run_audit()
        self.assertNotIn("Fred source switch", text)

    def test_npm_versions_disagree(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0", npm="0.1.0")
        app(self.root, "app-b", ">=4.5.0", "4.5.0", npm="0.1.1", npm_locked="0.1.0")
        _, text = self.run_audit()
        self.assertIn("@fred-oss/ui: several versions declared ['0.1.0', '0.1.1']", text)
        self.assertIn("app-b/ui/package-lock.json: @fred-oss/ui locked at 0.1.0", text)

    def test_checkout_behind_its_branch(self):
        app(self.root, "app-a", ">=4.5.0", "4.5.0")
        repo = self.root / "app-a"
        write(repo / "new", "x")
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "ahead")
        git("update-ref", "refs/remotes/origin/swift", "HEAD")
        git("reset", "-q", "--hard", "HEAD~1")
        _, text = self.run_audit()
        self.assertIn("ERROR app-a: on swift, 1 behind origin/swift", text)


class AdmitsTest(unittest.TestCase):
    def test_specifiers(self):
        admits = audit_module.admits
        self.assertTrue(admits(">=4.4.3", "4.5.0"))
        self.assertFalse(admits("==4.4.3", "4.5.0"))
        self.assertTrue(admits(">=4.0.0,<5.0.0", "4.5.0"))
        self.assertFalse(admits(">=4.0.0,<5.0.0", "5.0.0"))
        self.assertTrue(admits("~=4.4", "4.5.0"))
        self.assertFalse(admits("~=4.4.3", "4.5.0"))
        self.assertTrue(admits("==4.*", "4.5.0"))
        self.assertFalse(admits(">=4.5.0", "4.5.0rc1"))


if __name__ == "__main__":
    unittest.main()
