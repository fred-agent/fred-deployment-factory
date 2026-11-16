"""Real Helm/kubectl/OpenSSL against a disposable HTTP API, never a real cluster."""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def decode_resource(data, kind):
    """Accept kubectl's JSON or Kubernetes protobuf Namespace/Secret writes.

    The fake API needs only ObjectMeta and Secret.data; it does not implement a
    protobuf serializer or any other Kubernetes resource.
    """
    if not data.startswith(b"k8s\x00"):
        return json.loads(data)

    def fields(message):
        offset = 0
        result = {}

        def varint():
            nonlocal offset
            value, shift = 0, 0
            while True:
                byte = message[offset]
                offset += 1
                value |= (byte & 127) << shift
                if byte < 128:
                    return value
                shift += 7

        while offset < len(message):
            tag = varint()
            wire = tag & 7
            if wire == 0:
                value = varint()
            else:
                size = varint() if wire == 2 else {1: 8, 5: 4}[wire]
                value = message[offset:offset + size]
                offset += size
            result.setdefault(tag >> 3, []).append(value)
        return result

    # runtime.Unknown.raw contains the core/v1 message. Both resource types use
    # field 1 for ObjectMeta; Secret.data is repeated map entries at field 2.
    resource = fields(fields(data[4:])[2][0])
    metadata = fields(resource[1][0])
    body = {"apiVersion": "v1", "kind": kind, "metadata": {"name": metadata[1][0].decode()}}
    if metadata.get(3):
        body["metadata"]["namespace"] = metadata[3][0].decode()
    if kind == "Secret":
        entries = [fields(entry) for entry in resource.get(2, [])]
        body["data"] = {entry[1][0].decode(): base64.b64encode(entry[2][0]).decode() for entry in entries}
    return body


class TLSRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.material = tempfile.TemporaryDirectory()
        directory = Path(cls.material.name)

        def openssl(*args):
            subprocess.run(["openssl", *args], cwd=directory, check=True, capture_output=True)

        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                "-subj", "/CN=Test CA", "-keyout", "ca.key", "-out", "ca.crt")
        openssl("req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=opensearch",
                "-keyout", "tls.key", "-out", "server.csr")
        (directory / "extensions").write_text(
            "subjectAltName=DNS:opensearch\nextendedKeyUsage=serverAuth\n"
        )
        openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
                "-set_serial", "1", "-days", "1", "-extfile", "extensions", "-out", "tls.crt")
        cls.ca = (directory / "ca.crt").read_text()

    @classmethod
    def tearDownClass(cls):
        cls.material.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.certificates = self.directory / "certificates"
        self.leaf = self.certificates / "2026-11-13"
        self.leaf.mkdir(parents=True)
        for name in ("tls.crt", "tls.key"):
            shutil.copy(Path(self.material.name) / name, self.leaf / name)
        self.events = []
        self.secret = None
        self.namespace = False
        self.forbidden = False
        state = self

        class API(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def reply(self, body, code=200):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                if path == "/api":
                    return self.reply({"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]})
                if path == "/apis":
                    return self.reply({"kind": "APIGroupList", "apiVersion": "v1", "groups": [{
                        "name": "apps", "versions": [{"groupVersion": "apps/v1", "version": "v1"}],
                        "preferredVersion": {"groupVersion": "apps/v1", "version": "v1"},
                    }]})
                if path in ("/api/v1", "/apis/apps/v1"):
                    resources = [("deployments", "Deployment", True)] if path.startswith("/apis/") else [
                        ("services", "Service", True), ("configmaps", "ConfigMap", True),
                        ("secrets", "Secret", True), ("namespaces", "Namespace", False),
                    ]
                    return self.reply({
                        "kind": "APIResourceList", "apiVersion": "v1",
                        "groupVersion": "apps/v1" if path.startswith("/apis/") else "v1",
                        "resources": [{"name": n, "kind": k, "namespaced": ns,
                                       "verbs": ["get", "create"]} for n, k, ns in resources],
                    })
                if path == "/api/v1/namespaces/fred-infra" and state.namespace:
                    return self.reply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "fred-infra"}})
                if "/secrets/" in path:
                    if state.forbidden:
                        return self.reply({"kind": "Status", "apiVersion": "v1", "status": "Failure",
                                           "reason": "Forbidden", "code": 403}, 403)
                    if state.secret:
                        return self.reply(state.secret)
                self.reply({"kind": "Status", "apiVersion": "v1", "status": "Failure",
                            "reason": "NotFound", "code": 404}, 404)

            def do_POST(self):
                kind = "Secret" if "/secrets" in self.path else "Namespace"
                body = decode_resource(self.rfile.read(int(self.headers["Content-Length"])), kind)
                state.events.append(body)
                if body["kind"] == "Namespace":
                    state.namespace = True
                elif body["kind"] == "Secret":
                    state.secret = body
                else:
                    return self.reply({"message": "unexpected mutation"}, 400)
                self.reply(body, 201)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), API)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()

        def stop():
            self.server.shutdown()
            self.server.server_close()
            thread.join()

        self.addCleanup(stop)
        config = self.directory / "kubeconfig.json"
        config.write_text(json.dumps({
            "apiVersion": "v1", "kind": "Config", "current-context": "k3d-fred",
            "clusters": [{"name": "fake", "cluster": {"server": f"http://127.0.0.1:{self.server.server_port}"}}],
            "contexts": [{"name": "k3d-fred", "context": {"cluster": "fake", "user": "fake"}}],
            "users": [{"name": "fake", "user": {}}],
        }))
        self.env = {k: v for k, v in os.environ.items() if k not in (
            "FRED", "VALUES", "MAKEFLAGS", "MAKELEVEL", "MFLAGS", "K3D_TLS_CERT_DIR",
        )}
        self.env["KUBECONFIG"] = str(config)
        self.values = self.write_values("values.json")

    def write_values(self, name, secret="test-http", ca=None):
        path = self.directory / name
        path.write_text(json.dumps({"opensearch": {"httpTls": {
            "existingSecret": secret, "caBundle": self.ca if ca is None else ca,
        }}}))
        return path

    def run_restore(self, *values):
        args = [str(ROOT / "bin/k3d-restore-tls"), str(self.certificates)]
        for path in values or (self.values,):
            args += ["--values", str(path)]
        return subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=30)

    def test_restore_and_repeat_preserve_certificate_and_secret(self):
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["kind"] for e in self.events], ["Namespace", "Secret"])
        secret = self.secret
        self.assertEqual(secret["metadata"]["name"], "test-http")
        self.assertEqual(secret["metadata"]["namespace"], "fred-infra")
        self.assertEqual(set(secret["data"]), {"tls.crt", "tls.key", "ca.crt"})
        self.assertEqual(base64.b64decode(secret["data"]["tls.key"]), (self.leaf / "tls.key").read_bytes())
        self.assertEqual(base64.b64decode(secret["data"]["ca.crt"]).decode(), self.ca)
        self.assertNotIn("PRIVATE KEY", result.stdout + result.stderr)
        shutil.rmtree(self.certificates)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("keeping existing Secret", result.stdout)
        self.assertEqual(len(self.events), 2)

    def test_without_tls_does_not_create_resources(self):
        result = self.run_restore(self.write_values("disabled.json", secret="", ca=""))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events, [])

    def test_values_override_selects_effective_secret(self):
        result = self.run_restore(self.values, self.write_values("override.json", secret="renewed-http"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.secret["metadata"]["name"], "renewed-http")

    def test_missing_or_mismatched_material_fails_without_mutation(self):
        for mode in ("missing", "mismatch", "untrusted"):
            with self.subTest(mode=mode):
                shutil.copy(Path(self.material.name) / "tls.key", self.leaf / "tls.key")
                values = self.values
                if mode == "missing":
                    (self.leaf / "tls.key").unlink()
                elif mode == "mismatch":
                    shutil.copy(Path(self.material.name) / "ca.key", self.leaf / "tls.key")
                else:
                    values = self.write_values("bad-trust.json", ca="not a certificate")
                result = self.run_restore(values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no matching certificate", result.stderr)
                self.assertEqual(self.events, [])

    def test_ambiguity_requires_explicit_selection(self):
        shutil.copytree(self.leaf, self.certificates / "another")
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Several certificates", result.stderr)
        self.assertEqual(self.events, [])
        self.env["K3D_TLS_CERT_DIR"] = str(self.leaf)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.secret["metadata"]["name"], "test-http")

    def test_forbidden_is_not_treated_as_missing(self):
        self.forbidden = True
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events, [])

    def test_existing_namespace_is_not_recreated(self):
        self.namespace = True
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["kind"] for e in self.events], ["Secret"])

    def test_make_restores_before_sync_and_stops_on_invalid_material(self):
        wrappers = self.directory / "bin"
        wrappers.mkdir()
        marker = self.directory / "sync"
        for name, body in {
            "docker": "exit 0",
            "k3d": '[ "$2" != get ]',
            "helmfile": 'kubectl --context k3d-fred -n fred-infra get secret test-http >/dev/null || exit 1\n: > "$SYNC_MARKER"',
        }.items():
            path = wrappers / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        self.env.update({"PATH": f"{wrappers}:{os.environ['PATH']}", "SYNC_MARKER": str(marker),
                         "K3D_TLS_CERT_DIR": str(self.leaf)})
        command = ["make", "--no-print-directory", "k3d-up", f"VALUES={self.values}"]
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists())
        marker.unlink()
        self.secret = None
        self.events.clear()
        (self.leaf / "tls.key").unlink()
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertEqual(self.events, [])


if __name__ == "__main__":
    unittest.main()
