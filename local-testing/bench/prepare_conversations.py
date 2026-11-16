#!/usr/bin/env python3
"""Generate private local conversation-benchmark inputs without network access."""

import argparse
import ipaddress
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import zipfile


CLIENT_ID = "fred-bench-local"


def local_issuer(value):
    value = value.rstrip("/")
    parsed = urlsplit(value)
    hostname = parsed.hostname or ""
    try:
        local = ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        # These two aliases are the issuer names in factory's k3d/docker values;
        # operators must resolve them locally as documented by those stacks.
        local = hostname in ("keycloak", "app-keycloak", "localhost") or hostname.endswith(".localhost")
    try:
        parsed.port
    except ValueError:
        local = False
    if (
        not local
        or parsed.scheme not in ("http", "https")
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not re.fullmatch(r"/realms/[A-Za-z0-9_-]+", parsed.path)
    ):
        raise ValueError("issuer must be a local factory Keycloak realm URL")
    return value


def name(value):
    if (
        not value
        or len(value) > 255
        or value.strip() != value
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise ValueError("space names must be nonempty canonical names")
    return value


def write_json(path, value):
    # The parent is private too; exclusive creation never replaces a credential.
    with path.open("x", encoding="utf-8") as output:
        path.chmod(0o600)
        json.dump(value, output, indent=2, ensure_ascii=False)
        output.write("\n")


def client_declaration(secret):
    return {
        "clientId": CLIENT_ID,
        "name": "Local synthetic conversation benchmark",
        "description": "Local test exception only; disable after the benchmark.",
        "protocol": "openid-connect",
        "enabled": True,
        "publicClient": False,
        "clientAuthenticatorType": "client-secret",
        "secret": secret,
        "directAccessGrantsEnabled": True,
        "standardFlowEnabled": False,
        "implicitFlowEnabled": False,
        "serviceAccountsEnabled": False,
        "fullScopeAllowed": False,
        "redirectUris": [],
        "webOrigins": [],
        "defaultClientScopes": ["profile", "email"],
        "optionalClientScopes": [],
        "attributes": {"use.refresh.tokens": "true"},
        "protocolMappers": [{
            "name": "fred-user-audience",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-audience-mapper",
            "config": {
                "included.client.audience": "app",
                "access.token.claim": "true",
                "id.token.claim": "false",
            },
        }, {
            # Recent Keycloak versions put sub in the optional basic scope.
            # Keep the restricted scopes while identifying the real person.
            "name": "sub",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-sub-mapper",
            "config": {"access.token.claim": "true"},
        }],
    }


def generate(args):
    issuer = local_issuer(args.issuer)
    if not 1 <= args.users <= 10000:
        raise ValueError("users must be between 1 and 10000")
    prefix = args.prefix or "bench-" + secrets.token_hex(6)
    if not re.fullmatch(r"bench-[a-z0-9][a-z0-9-]{0,39}", prefix):
        raise ValueError("prefix must start with bench- and use lowercase ASCII letters/digits/hyphens")
    swift_team = name(args.swift_team)
    organization = name(args.weaver_organization)
    weaver_team = name(args.weaver_team)
    packager = args.fred_source / "apps/control-plane/tools/build_provisioning_bundle.py"
    if not packager.is_file():
        raise ValueError("fred-source must contain the Weaver provisioning packager")

    # No exist_ok: existing directories, files and symlinks are all collisions.
    args.output.mkdir(mode=0o700)
    try:
        args.output.chmod(0o700)
        users = [
            {
                "label": f"user-{i:04d}",
                "username": f"{prefix}-{i:04d}",
                "password": "Aa1_" + secrets.token_urlsafe(24),
            }
            for i in range(1, args.users + 1)
        ]
        secret = secrets.token_urlsafe(32)
        write_json(args.output / "credentials.json", {
            "schema_version": 1,
            "issuer": issuer,
            "client_id": CLIENT_ID,
            "client_secret": secret,
            "users": users,
        })
        write_json(args.output / "keycloak-client.json", client_declaration(secret))
        identities = [
            {
                "username": user["username"],
                "email": user["username"] + "@bench.invalid",
                "first_name": "Benchmark",
                "last_name": user["label"],
                "password": user["password"],
                "platform_roles": [],
            }
            for user in users
        ]
        swift = {
            "manifest.json": {
                "format_version": 1,
                "users_schema_version": 1,
                "source_platform": "swift",
                "tables": {},
                "content_keys": [],
            },
            "users.json": [dict(user, teams=[swift_team], team_roles={
                "team_member": [swift_team],
            }) for user in identities],
        }
        # Same two entries as Swift's build-demo-bundle Make target.
        with (args.output / "swift-provisioning.zip").open("xb") as output:
            (args.output / "swift-provisioning.zip").chmod(0o600)
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for filename, value in swift.items():
                    archive.writestr(filename, json.dumps(value, ensure_ascii=False))

        roles = {user["username"]: ["member"] for user in users}
        weaver = {
            "manifest": {"format_version": 2, "users_schema_version": 2, "source_platform": "swift"},
            "users": identities,
            "organizations": [{"ref": "organization", "name": organization, "roles": roles}],
            "teams": [{"ref": "team", "name": weaver_team, "organization": "organization", "roles": roles}],
            "projects": [],
        }
        with tempfile.TemporaryDirectory(dir=args.output) as staging:
            for filename, value in weaver.items():
                write_json(Path(staging) / (filename + ".json"), value)
            # Use Weaver's canonical archive writer; capture all output because
            # external failures must not leak generated fixture contents.
            subprocess.run([
                sys.executable, str(packager.resolve()), staging,
                str((args.output / "weaver-provisioning.zip").resolve()),
            ], check=True, capture_output=True)
        (args.output / "weaver-provisioning.zip").chmod(0o600)
    except BaseException:
        shutil.rmtree(args.output)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--users", type=int, required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--swift-team", required=True, help="existing Swift team name")
    parser.add_argument("--weaver-organization", required=True, help="existing Weaver organization name")
    parser.add_argument("--weaver-team", required=True, help="existing Weaver team name")
    parser.add_argument("--fred-source", type=Path, required=True, help="Weaver Fred checkout")
    parser.add_argument("--prefix", help="optional unique bench- prefix; random by default")
    parser.add_argument("--output", type=Path, required=True, help="new private directory; parent must exist")
    args = parser.parse_args(argv)
    try:
        generate(args)
    except FileExistsError:
        print("Preparation refused: output already exists; nothing replaced.", file=sys.stderr)
        return 1
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Preparation failed: check local inputs and the Weaver packager; no bundle retained.", file=sys.stderr)
        return 1
    print(f"Prepared {args.users} synthetic identities, two bundles and one local OAuth client. No network operations performed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
