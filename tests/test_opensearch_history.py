"""Offline regressions; requires helm, openssl and PyYAML. Never contacts Kubernetes."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(values):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(values))
        result = subprocess.run(
            ["helm", "template", "fred-stack", str(ROOT / "k3d"),
             "--namespace", "fred-infra", "-f", str(path)],
            capture_output=True, text=True, check=True,
        )
        return {(d["kind"], d["metadata"].get("namespace", "fred-infra"),
                 d["metadata"]["name"]): d
                for d in yaml.safe_load_all(result.stdout) if d}


class HistoryManifests(unittest.TestCase):
    def test_http_only_identity_and_public_trust(self):
        values = {"opensearch": {"httpTls": {
            "existingSecret": "http-version-1", "caBundle": "PUBLIC-CA"}}}
        manifests = render(values)
        deployment = manifests["Deployment", "fred-infra", "opensearch"]
        self.assertEqual(deployment["spec"]["strategy"]["type"], "Recreate")
        self.assertIsNone(deployment["spec"]["strategy"]["rollingUpdate"])
        pod = deployment["spec"]["template"]["spec"]
        server = pod["containers"][0]
        tls_args = [arg for arg in server["args"] if "plugins.security" in arg]
        self.assertEqual(tls_args, [
            "-Eplugins.security.ssl.http.pemcert_filepath=http-tls/tls.crt",
            "-Eplugins.security.ssl.http.pemkey_filepath=http-tls/tls.key",
        ])
        env = {item["name"]: item for item in server["env"]}
        self.assertEqual(env["DISABLE_INSTALL_DEMO_CONFIG"]["value"], "false")
        volumes = {item["name"]: item for item in pod["volumes"]}
        self.assertEqual(volumes["opensearch-data"]["persistentVolumeClaim"]["claimName"],
                         "opensearch-data")
        self.assertEqual(volumes["opensearch-http-tls"]["secret"]["secretName"],
                         "http-version-1")
        for ns in ("fred-infra", "fred-weaver"):
            self.assertEqual(manifests["ConfigMap", ns, "opensearch-http-ca"]["data"],
                             {"ca.crt": "PUBLIC-CA"})
        self.assertNotIn(("ConfigMap", "fred-swift", "opensearch-http-ca"), manifests)
        for name in ("opensearch-identities", "opensearch-post-install"):
            job = manifests["Job", "fred-infra", name]
            script = job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
            self.assertIn("--cacert /etc/opensearch-ca/ca.crt", script)
            self.assertNotIn("-k ", script)
        identities = json.loads(manifests[
            "Secret", "fred-infra", "fred-opensearch-identities"]["stringData"]["identities.json"])
        reader = identities["fred-analytics-reader"]
        self.assertEqual(reader["role"], {
            "cluster_permissions": [], "index_permissions": [{
                "index_patterns": ["weaver-kpi"],
                "allowed_actions": ["indices:data/read/search*", "indices:admin/mappings/get"],
            }],
        })
        secret = manifests["Secret", "fred-weaver", "fred-analytics-reader"]
        # Do not include passwords in assertion output.
        self.assertTrue(reader["password"] == secret["stringData"]["password"])
        self.assertEqual(secret["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
        # Certificate generation is external: two offline renders keep the pod identical.
        # Live reader-password lookup idempotence needs the separate acceptance check.
        self.assertEqual(deployment, render(values)["Deployment", "fred-infra", "opensearch"])

    def test_default_does_not_switch_the_shared_certificate(self):
        manifests = render({})
        server = manifests["Deployment", "fred-infra", "opensearch"][
            "spec"]["template"]["spec"]["containers"][0]
        self.assertFalse(any("ssl.http.pem" in arg for arg in server["args"]))
        self.assertNotIn(("ConfigMap", "fred-weaver", "opensearch-http-ca"), manifests)
        self.assertNotIn(("Secret", "fred-weaver", "fred-analytics-reader"), manifests)
        identities = json.loads(manifests[
            "Secret", "fred-infra", "fred-opensearch-identities"]["stringData"]["identities.json"])
        self.assertNotIn("fred-analytics-reader", identities)

    def test_weaver_keeps_existing_trust_and_uses_reader_secret(self):
        values = yaml.safe_load((ROOT / "k3d-apps/fred/values-weaver.yaml").read_text())
        app = values["applications"]["control-plane-backend"]
        history = app["configuration"]["storage"]["history"]
        self.assertEqual(history, {
            "url": "https://opensearch:9200", "index": "weaver-kpi",
            "username": "fred-analytics-reader", "password_env_var": "FRED_HISTORY_PASSWORD",
        })
        env = {item["name"]: item for item in app["extraEnvVars"]}
        self.assertEqual(env["SSL_CERT_FILE"]["value"], "/etc/fred/node-ca/ca-certificates.crt")
        self.assertEqual(env["SSL_CERT_DIR"]["value"], "/etc/fred/opensearch-ca")
        self.assertEqual(env["FRED_HISTORY_PASSWORD"]["valueFrom"]["secretKeyRef"],
                         {"name": "fred-analytics-reader", "key": "password"})
        self.assertFalse(any("secret" in volume for volume in app["extraVolumes"]))


class CertificateVerification(unittest.TestCase):
    def test_correct_ca_wrong_ca_wrong_name(self):
        with tempfile.TemporaryDirectory() as directory:
            def openssl(*args, success=True):
                result = subprocess.run(["openssl", *args], cwd=directory,
                                        capture_output=True, text=True)
                if success:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                return result

            for name in ("ca", "wrong-ca"):
                openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", name + ".key", "-out", name + ".crt",
                        "-subj", "/CN=" + name,
                        "-addext", "basicConstraints=critical,CA:TRUE",
                        "-addext", "keyUsage=critical,keyCertSign,cRLSign")
            openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
                    "-out", "server.csr", "-subj", "/CN=opensearch")
            Path(directory, "extensions").write_text(
                "basicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n"
                "subjectAltName=DNS:opensearch,DNS:opensearch.fred-infra.svc.cluster.local\n")
            openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
                    "-set_serial", "1", "-days", "1", "-extfile", "extensions", "-out", "server.crt")
            for ca, name, success in (("ca", "opensearch", True),
                                      ("wrong-ca", "opensearch", False),
                                      ("ca", "wrong-name", False)):
                openssl("verify", "-CAfile", ca + ".crt", "-purpose", "sslserver",
                        "-verify_hostname", name, "server.crt", success=success)


if __name__ == "__main__":
    unittest.main()
