"""Offline contract checks; no Keycloak, database or Fred process is contacted."""

import argparse
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

import prepare_conversations as prepare


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = Path(os.environ.get(
            "FRED_WEAVER_SOURCE", Path(__file__).resolve().parents[3] / "fred"
        ))
        self.args = argparse.Namespace(
            users=3, issuer="http://localhost:8080/realms/app", prefix="bench-test",
            swift_team="Existing Swift Team", weaver_organization="Existing Org",
            weaver_team="Existing Weaver Team", fred_source=source,
            output=self.root / "private inputs",
        )

    def read_zip(self, name):
        with zipfile.ZipFile(self.args.output / name) as archive:
            return {name: json.loads(archive.read(name)) for name in archive.namelist()}

    def test_bundles_share_exact_identities_with_only_ordinary_roles(self):
        prepare.generate(self.args)
        credentials = json.loads((self.args.output / "credentials.json").read_text())
        self.assertEqual(set(credentials), {
            "schema_version", "issuer", "client_id", "client_secret", "users",
        })
        self.assertEqual(credentials["schema_version"], 1)
        self.assertEqual(credentials["issuer"], self.args.issuer)
        self.assertEqual(credentials["client_id"], "fred-bench-local")
        swift = self.read_zip("swift-provisioning.zip")
        weaver = self.read_zip("weaver-provisioning.zip")
        self.assertEqual(set(swift), {"manifest.json", "users.json"})
        self.assertEqual(set(weaver), {
            "manifest.json", "users.json", "organizations.json", "teams.json", "projects.json",
        })
        for bundle, version in ((swift, 1), (weaver, 2)):
            self.assertEqual(bundle["manifest.json"]["format_version"], version)
            self.assertEqual(bundle["manifest.json"]["users_schema_version"], version)
            self.assertEqual(bundle["manifest.json"]["source_platform"], "swift")
        expected_roles = {}
        for index, (credential, swift_user, weaver_user) in enumerate(zip(
            credentials["users"], swift["users.json"], weaver["users.json"], strict=True
        ), 1):
            username = f"bench-test-{index:04d}"
            self.assertEqual(set(credential), {"label", "username", "password"})
            self.assertEqual(credential["label"], f"user-{index:04d}")
            self.assertEqual(credential["username"], username)
            self.assertGreaterEqual(len(credential["password"]), 32)
            self.assertEqual(swift_user.pop("teams"), [self.args.swift_team])
            self.assertEqual(swift_user.pop("team_roles"), {"team_member": [self.args.swift_team]})
            self.assertEqual(swift_user, weaver_user)
            self.assertEqual(weaver_user["password"], credential["password"])
            self.assertEqual(weaver_user["platform_roles"], [])
            expected_roles[username] = ["member"]
        self.assertEqual(weaver["organizations.json"], [{
            "ref": "organization", "name": self.args.weaver_organization, "roles": expected_roles,
        }])
        self.assertEqual(weaver["teams.json"], [{
            "ref": "team", "name": self.args.weaver_team,
            "organization": "organization", "roles": expected_roles,
        }])
        self.assertEqual(weaver["projects.json"], [])
        self.assertEqual(len({u["password"] for u in credentials["users"]}), 3)

    def test_private_outputs_and_restricted_client(self):
        prepare.generate(self.args)
        self.assertEqual(stat.S_IMODE(self.args.output.stat().st_mode), 0o700)
        self.assertEqual(len(list(self.args.output.iterdir())), 4)
        for path in self.args.output.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        client = json.loads((self.args.output / "keycloak-client.json").read_text())
        credentials = json.loads((self.args.output / "credentials.json").read_text())
        self.assertEqual(client["clientId"], "fred-bench-local")
        self.assertNotEqual(client["clientId"], "app")
        self.assertEqual(client["secret"], credentials["client_secret"])
        self.assertGreaterEqual(len(client["secret"]), 32)
        for setting in ("publicClient", "standardFlowEnabled", "implicitFlowEnabled",
                        "serviceAccountsEnabled", "fullScopeAllowed"):
            self.assertIs(client[setting], False)
        self.assertIs(client["directAccessGrantsEnabled"], True)
        self.assertEqual(client["redirectUris"], [])
        self.assertEqual(client["webOrigins"], [])
        self.assertEqual(client["optionalClientScopes"], [])
        self.assertEqual(client["defaultClientScopes"], ["profile", "email"])
        self.assertEqual(client["protocolMappers"][0]["config"], {
            "included.client.audience": "app", "access.token.claim": "true", "id.token.claim": "false",
        })
        self.assertEqual(client["protocolMappers"][1], {
            "name": "sub", "protocol": "openid-connect",
            "protocolMapper": "oidc-sub-mapper",
            "config": {"access.token.claim": "true"},
        })
        self.assertNotIn("roles", client)

    def test_existing_output_and_symlink_never_overwritten(self):
        for kind in ("directory", "file", "symlink"):
            with self.subTest(kind=kind):
                existing = self.root / kind
                if kind == "directory":
                    existing.mkdir()
                    (existing / "preserve").write_text("keep")
                elif kind == "file":
                    existing.write_text("keep")
                else:
                    existing.symlink_to(self.root / "absent")
                self.args.output = existing
                with self.assertRaises(FileExistsError):
                    prepare.generate(self.args)
                if kind == "directory":
                    self.assertEqual((existing / "preserve").read_text(), "keep")
                elif kind == "file":
                    self.assertEqual(existing.read_text(), "keep")
                else:
                    self.assertTrue(existing.is_symlink())

    def test_invalid_inputs_produce_no_artifacts(self):
        cases = [
            ("users", 0), ("users", 10001), ("prefix", "admin"),
            ("prefix", "bench-UPPER"), ("swift_team", " Team"),
            ("weaver_team", "Team\n"), ("weaver_organization", ""),
            ("issuer", "https://keycloak.example/realms/app"),
            ("issuer", "http://localhost.evil/realms/app"),
            ("issuer", "http://user:secret@localhost/realms/app"),
            ("issuer", "http://localhost/realms/app?secret=value"),
            ("issuer", "http://localhost/realms/../app"),
        ]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                args = argparse.Namespace(**vars(self.args))
                setattr(args, field, value)
                with self.assertRaises(ValueError):
                    prepare.generate(args)
                self.assertFalse(args.output.exists())

    def test_factory_issuer_aliases_and_loopback_are_supported(self):
        for host in ("keycloak", "app-keycloak", "localhost", "keycloak.localhost",
                     "127.0.0.1", "127.0.0.2", "[::1]"):
            issuer = f"http://{host}:8080/realms/app"
            self.assertEqual(prepare.local_issuer(issuer + "/"), issuer)
        for host in ("keycloak.evil", "app-keycloak.evil", "192.168.1.2",
                     "keycloak.127.0.0.1.nip.io"):
            with self.assertRaises(ValueError):
                prepare.local_issuer(f"http://{host}:8080/realms/app")

    def test_packager_failure_is_redacted_and_removes_partial_secrets(self):
        fake = self.root / "source/apps/control-plane/tools"
        fake.mkdir(parents=True)
        (fake / "build_provisioning_bundle.py").write_text(
            "import sys\nprint('secret-from-packager')\n"
            "print('secret-from-packager', file=sys.stderr)\nraise SystemExit(1)\n"
        )
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            status = prepare.main([
                "--users", "1", "--issuer", self.args.issuer,
                "--swift-team", "S", "--weaver-organization", "O", "--weaver-team", "W",
                "--fred-source", str(self.root / "source"), "--output", str(self.args.output),
            ])
        self.assertEqual(status, 1)
        self.assertNotIn("secret-from-packager", output.getvalue())
        self.assertFalse(self.args.output.exists())

    def test_random_default_prefix_is_distinct_and_success_logs_no_secrets(self):
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            status = prepare.main([
                "--users", "2", "--issuer", self.args.issuer,
                "--swift-team", "S", "--weaver-organization", "O", "--weaver-team", "W",
                "--fred-source", str(self.args.fred_source), "--output", str(self.args.output),
            ])
        self.assertEqual(status, 0)
        first = json.loads((self.args.output / "credentials.json").read_text())
        self.args.prefix = None
        self.args.output = self.root / "second"
        prepare.generate(self.args)
        second = json.loads((self.args.output / "credentials.json").read_text())
        self.assertNotEqual(first["users"][0]["username"], second["users"][0]["username"])
        for value in [first["client_secret"], *[u["password"] for u in first["users"]]]:
            self.assertNotIn(value, output.getvalue())


if __name__ == "__main__":
    unittest.main()
