"""Offline checks for the local Fred log-mode launcher."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

LAUNCHER = Path(__file__).resolve().parents[1] / "bin/fred-local-logs.py"
spec = importlib.util.spec_from_file_location("fred_local_logs", LAUNCHER)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LocalLoggingTests(unittest.TestCase):
    def test_config_switch_preserves_source_and_anchors_relative_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "control-plane"
            (app / "config").mkdir(parents=True)
            source = app / "config/configuration_prod.yaml"
            original = "app:\n  log_format: text\n  log_level: info\npolicies:\n  purge_catalog_path: ./config/lifecycle_policy_catalog.yaml\n"
            source.write_text(original)
            output = Path(temporary) / "generated.yaml"
            launcher.prepare_config(source, output, "json")
            self.assertEqual(source.read_text(), original)
            self.assertIn("log_format: json", output.read_text())
            self.assertIn(
                f"purge_catalog_path: {app}/config/lifecycle_policy_catalog.yaml",
                output.read_text(),
            )
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            launcher.prepare_config(source, output, "text")
            self.assertIn("log_format: text", output.read_text())

    def test_missing_log_setting_fails_without_changing_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.yaml"
            source.write_text("app:\n  log_level: info\n")
            with self.assertRaises(ValueError):
                launcher.prepare_config(source, Path(temporary) / "out.yaml", "json")
            self.assertEqual(source.read_text(), "app:\n  log_level: info\n")

    def test_components_match_the_weaver_checkout_commands(self):
        self.assertEqual(
            [(name, target) for name, _, target, _ in launcher.COMPONENTS],
            [
                ("control-plane", "run"),
                ("knowledge-flow-backend", "run"),
                ("knowledge-flow-worker", "run"),
                ("fred-agents", "run"),
                ("fred-agents-worker", "run-worker"),
                ("frontend", "run"),
            ],
        )

    def test_unprepared_checkout_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "fred/apps/control-plane"
            app.mkdir(parents=True)
            (app / "Makefile").write_text("")
            result = subprocess.run(
                [sys.executable, str(LAUNCHER), "--checkout", str(Path(temporary) / "fred"),
                 "--log-dir", str(Path(temporary) / "logs"), "--component", "control-plane"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("make docker-prepare", result.stderr)

    def run_worker(self, directory, mode):
        checkout = directory / "fred"
        app = checkout / "apps/knowledge-flow-worker"
        (app / "config").mkdir(parents=True)
        (app / "config/.env").write_text("")
        (app / "config/configuration_worker.yaml").write_text(
            "app:\n  log_format: text\n"
        )
        (app / "worker.py").write_text("""import json, os, subprocess, sys, time
from pathlib import Path
mode = 'json' if 'log_format: json' in Path(os.environ['CONFIG_FILE']).read_text() else 'text'
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
print(json.dumps({'mode': mode, 'child_pid': child.pid}) if mode == 'json' else 'TEXT child_pid=' + str(child.pid), flush=True)
time.sleep(120)
""")
        (app / "Makefile").write_text(f"run:\n\t@{sys.executable} worker.py\n")
        logs = directory / "logs"
        process = subprocess.Popen(
            [
                sys.executable,
                "bin/fred-local-logs.py",
                "--checkout",
                str(checkout),
                "--log-dir",
                str(logs),
                "--component",
                "knowledge-flow-worker",
                "--mode",
                mode,
            ],
            cwd=LAUNCHER.parents[1],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        return process, logs

    def test_json_shutdown_cleans_descendants_and_temporary_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            process, logs = self.run_worker(Path(temporary), "json")
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    output = logs / "knowledge-flow-worker.log"
                    if output.exists() and output.read_text():
                        break
                    time.sleep(0.05)
                event = json.loads(output.read_text())
                self.assertEqual(event["mode"], "json")
                self.assertEqual(logs.stat().st_mode & 0o777, 0o700)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                manifest = json.loads((logs / "session.json").read_text())
                env = (
                    Path(f"/proc/{manifest['processes'][0]['pid']}/environ")
                    .read_bytes()
                    .split(b"\0")
                )
                config = Path(
                    next(
                        item.split(b"=", 1)[1].decode()
                        for item in env
                        if item.startswith(b"CONFIG_FILE=")
                    )
                )
                duplicate = subprocess.run(
                    [
                        sys.executable,
                        str(LAUNCHER),
                        "--checkout",
                        str(Path(temporary) / "fred"),
                        "--log-dir",
                        str(logs),
                        "--component",
                        "knowledge-flow-worker",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertNotEqual(duplicate.returncode, 0)
                stop = subprocess.run(
                    [
                        "make",
                        "fred-stop",
                        f"FRED_CHECKOUT={Path(temporary) / 'fred'}",
                        f"FRED_LOG_DIR={logs}",
                    ],
                    cwd=LAUNCHER.parents[1],
                    capture_output=True,
                    text=True,
                    timeout=25,
                )
                self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)
                process.communicate(timeout=20)
                self.assertEqual(process.returncode, 0)
                self.assertFalse(config.exists())
                self.assertFalse((logs / "session.json").exists())
                status = Path(f"/proc/{event['child_pid']}/status")
                self.assertTrue(
                    not status.exists() or "\nState:\tZ" in status.read_text()
                )
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    process.communicate(timeout=20)

    def test_text_mode_prints_to_terminal_and_does_not_write_json_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            process, logs = self.run_worker(Path(temporary), "text")
            try:
                deadline = time.monotonic() + 5
                while (
                    not (logs / "session.json").exists() and time.monotonic() < deadline
                ):
                    time.sleep(0.05)
                time.sleep(0.2)
                process.send_signal(signal.SIGTERM)
                output, _ = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 0)
                self.assertIn("TEXT child_pid=", output)
                self.assertFalse((logs / "knowledge-flow-worker.log").exists())
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    process.communicate(timeout=20)

    def test_stop_refuses_an_unrelated_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "session.json"
            manifest.write_text(json.dumps({"supervisor_pid": os.getpid()}))
            with self.assertRaises(RuntimeError):
                launcher.stop_session(manifest)


if __name__ == "__main__":
    unittest.main()
