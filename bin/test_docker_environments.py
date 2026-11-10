"""Render the real Compose configurations; no Docker daemon or containers needed."""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECTS = (
    "postgres", "keycloak", "seaweedfs", "opensearch", "openfga", "temporal",
    "clickhouse", "langfuse", "prometheus", "grafana", "logging", "zabbix",
)


def make(*args, env_overrides=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("DOCKER_")}
    for key in ("MAKEFLAGS", "MAKELEVEL", "MFLAGS", "ENV", "STACK"):
        env.pop(key, None)
    env.update(env_overrides or {})
    return subprocess.run(
        ["make", "--no-print-directory", *args], cwd=ROOT, env=env,
        text=True, capture_output=True, check=True,
    ).stdout


def resources(configs, field):
    return {
        item["name"] for config in configs.values()
        for item in config.get(field, {}).values()
    }


def host_ports(configs):
    return {
        int(port["published"]) for config in configs.values()
        for service in config["services"].values()
        for port in service.get("ports", [])
    }


class DockerEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.configs = {
            variant: {
                project: json.loads(make(
                    "-s", "docker-config", f"DOCKER_ENV={variant}",
                    f"SVC={project}", "DOCKER_ENV_FILE=docker/.env.template",
                    "DOCKER_SHARED_ENV_FILE=docker/.env.template",
                )) for project in PROJECTS if variant == "swift" or project != "openfga"
            } for variant in ("swift", "weaver")
        }

    def test_swift_keeps_existing_projects_and_volumes(self):
        swift = self.configs["swift"]
        for project, config in swift.items():
            self.assertEqual(config["name"], project)
            for key, volume in config.get("volumes", {}).items():
                self.assertEqual(volume["name"], f"{project}_{key}")
        self.assertEqual(swift["postgres"]["services"]["postgres"]["container_name"], "app-postgres")
        self.assertEqual(resources(swift, "networks"), {"fred-shared-network"})
        self.assertEqual(host_ports(swift), {
            5432, 8080, 9333, 8081, 8888, 8333, 9200, 5601, 9080, 9081,
            3000, 7233, 8233, 8123, 9002, 3001, 3030, 9090, 3002, 3100, 12345, 8085,
        })

    def test_data_volumes_are_distinct_and_ports_are_identical(self):
        swift, weaver = self.configs["swift"], self.configs["weaver"]
        for project in PROJECTS:
            if project == "openfga":
                self.assertNotIn(project, weaver)
                continue
            if project == "keycloak":
                self.assertEqual(swift[project], weaver[project])
                continue
            config = weaver[project]
            self.assertEqual(config["name"], f"weaver-{project}")
            self.assertTrue(resources({project: swift[project]}, "volumes").isdisjoint(
                resources({project: config}, "volumes")))
            self.assertEqual(host_ports({project: swift[project]}), host_ports({project: config}))
        self.assertEqual(resources(weaver, "networks"), {"fred-shared-network"})
        self.assertEqual(host_ports(weaver), host_ports(swift) - {9080, 9081, 3000})

    def test_each_postgres_bootstraps_only_its_own_application_databases(self):
        for variant in ("swift", "weaver"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                for name in ("psql", "create_env.sh"):
                    command = directory / name
                    command.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ["CALLS"], "a") as output:
    output.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + "\\n")
if Path(sys.argv[0]).name == "psql":
    sql = sys.stdin.read()
    assert "CREATE DATABASE %I" in sql and "REVOKE ALL" in sql
''')
                    command.chmod(0o755)
                calls = directory / "calls.jsonl"
                job = self.configs[variant]["postgres"]["services"]["postgres-post-install-job"]
                subprocess.run(
                    [*job["entrypoint"], *(c.replace("$$", "$") for c in job["command"])], check=True,
                    env={**os.environ, **job["environment"],
                         "PATH": f"{directory}:{os.environ['PATH']}", "CALLS": str(calls)},
                    capture_output=True, text=True,
                )
                commands = [json.loads(line) for line in calls.read_text().splitlines()]
                databases = {c[c.index("--database") + 1] for c in commands if c[0] == "create_env.sh"}
                common = {"langfuse", "temporal", "temporal_visibility"}
                self.assertEqual(databases, common if variant == "weaver" else common | {"fred", "data", "openfga", "evaluation"})
                sql = [c for c in commands if c[0] == "psql"]
                self.assertEqual(len(sql), int(variant == "weaver"))
                if sql:
                    self.assertIn("database=fred_weaver", sql[0])

    def test_weaver_preserves_internal_dns_aliases(self):
        for project, config in self.configs["weaver"].items():
            if project == "keycloak":
                continue
            for service in config["services"].values():
                name = service.get("container_name")
                if name:
                    self.assertTrue(name.startswith("weaver-"))
                    self.assertIn(name.removeprefix("weaver-"), service["networks"]["app-network"]["aliases"])

    def test_shared_keycloak_has_its_own_database_without_a_host_port(self):
        config = self.configs["weaver"]["keycloak"]
        self.assertEqual(config["name"], "keycloak")
        keycloak = config["services"]["keycloak"]
        self.assertEqual(keycloak["container_name"], "app-keycloak")
        self.assertEqual(keycloak["image"], "mirror.gcr.io/keycloak/keycloak:26.3.0")
        self.assertEqual(keycloak["environment"]["KC_DB_URL"], "jdbc:postgresql://keycloak-postgres:5432/keycloak")
        self.assertNotIn("ports", config["services"]["keycloak-postgres"])
        for variant in ("swift", "weaver"):
            self.assertTrue(resources({"keycloak": config}, "volumes").isdisjoint(
                resources({"postgres": self.configs[variant]["postgres"]}, "volumes")))
            job = self.configs[variant]["postgres"]["services"]["postgres-post-install-job"]
            self.assertNotIn("POSTGRES_KEYCLOAK_DB", job["environment"])

    def test_oidc_keeps_the_existing_hostnames_and_ports(self):
        configs = self.configs["weaver"]
        ui = configs["temporal"]["services"]["temporal-ui"]["environment"]
        self.assertEqual(ui["TEMPORAL_AUTH_ISSUER_URL"], "http://app-keycloak:8080/realms/app")
        self.assertEqual(ui["TEMPORAL_AUTH_CALLBACK_URL"], "http://localhost:8233/auth/sso/callback")
        opensearch = configs["opensearch"]["services"]["opensearch-pre-install-job"]["environment"]
        self.assertEqual(opensearch["KEYCLOAK_HOST"], "app-keycloak")

    def test_extended_stack_keeps_existing_endpoints_and_local_databases(self):
        services = self.configs["weaver"]["langfuse"]["services"]
        env = services["langfuse-web"]["environment"]
        self.assertEqual(env["NEXTAUTH_URL"], "http://localhost:3001")
        self.assertEqual(env["LANGFUSE_S3_BATCH_EXPORT_EXTERNAL_ENDPOINT"], "http://localhost:8333")
        self.assertIn("@app-postgres:5432/langfuse", env["DATABASE_URL"])

    def test_env_setup_creates_once_and_preserves_custom_values(self):
        with tempfile.TemporaryDirectory(prefix="compose env ") as tmp:
            path = Path(tmp) / ".env"
            args = ("-s", "env-setup", f"DOCKER_ENV_FILE={path}")
            make(*args)
            self.assertEqual(path.read_text(), (ROOT / "docker/.env.template").read_text())
            path.write_text("POSTGRES_FRED_DB=my_custom_database\n")
            make(*args)
            self.assertEqual(path.read_text(), "POSTGRES_FRED_DB=my_custom_database\n")

    def test_explicit_launcher_selects_its_own_env_file(self):
        self.assertIn(f"Env file: {ROOT}/docker/.env\n", make("-s", "docker-env"))
        self.assertIn(f"Env file: {ROOT}/docker/.env.weaver\n", make("-s", "docker-weaver-env"))

    def test_switch_prepares_shared_auth_then_stops_other_stack(self):
        for variant, prefix, other in (("swift", "", "weaver"), ("weaver", "weaver-", "swift")):
            with self.subTest(variant=variant):
                commands = make("-sn", "docker-up", f"DOCKER_ENV={variant}")
                auth = commands.index("bash docker/keycloak/up-shared.sh")
                stop = commands.index(f"make DOCKER_ENV={other} docker-stop")
                start = commands.index(f"-p {prefix}postgres up -d --wait postgres")
                self.assertLess(auth, stop)
                self.assertLess(stop, start)
                self.assertIn(f"docker wait {prefix}app-postgres-post-install-job", commands)
                self.assertIn('OPENFGA_URL="http://localhost:9080"', commands)
                self.assertNotIn("weaver-app-keycloak", commands)

    def test_two_make_commands_switch_in_both_directions_without_deleting_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            docker = directory / "docker"
            docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as output:
    output.write(json.dumps(args) + "\\n")
if args[0] == "inspect":
    print("pgvector/pgvector:pg15")
elif args[0] == "exec":
    print("t")
elif args[0] == "wait":
    print("0")
''')
            docker.chmod(0o755)
            bash = directory / "bash"
            bash.write_text('''#!/bin/sh
case "$1" in
    bin/fred-preflight.sh|docker/openfga/openfga-post-install.sh|docker/keycloak/keycloak-post-install.sh) exit 0 ;;
    *) exec /bin/bash "$@" ;;
esac
''')
            bash.chmod(0o755)
            calls = directory / "calls.jsonl"
            env = {"PATH": f"{directory}:{os.environ['PATH']}", "CALLS": str(calls)}
            config = ("DOCKER_ENV_FILE=docker/.env.template", "DOCKER_SHARED_ENV_FILE=docker/.env.template")
            for down, up, prefix in (("docker-down", "docker-weaver-up", "weaver-"),
                                      ("docker-weaver-down", "docker-up", "")):
                with self.subTest(up=up):
                    calls.write_text("")
                    make("-s", down, *config, env_overrides=env)
                    make("-s", up, *config, env_overrides=env)
                    commands = [json.loads(line) for line in calls.read_text().splitlines()]
                    compose = [c for c in commands if c[0] == "compose"]
                    removed = [c[c.index("-p") + 1] for c in compose if "down" in c]
                    self.assertTrue(removed)
                    self.assertNotIn("keycloak", removed)
                    for command in commands:
                        self.assertNotIn("-v", command)
                        self.assertNotIn("--rmi", command)
                        self.assertNotEqual(command[:2], ["network", "rm"])
                    launched = {c[c.index("-p") + 1] for c in compose if "up" in c}
                    expected = {prefix + p for p in ("postgres", "seaweedfs", "opensearch", "temporal")}
                    if not prefix:
                        expected.add("openfga")
                    self.assertEqual(launched, expected | {"keycloak"})

    def test_weaver_prepare_checks_weaver_postgres_before_preparing_the_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "apps/control-plane").mkdir(parents=True)
            (directory / "apps/control-plane/Cargo.toml").touch()
            config = directory / "apps/fred-agents/config"
            config.mkdir(parents=True)
            (config / ".env").write_text("OPENAI_API_KEY=test\n")
            (directory / "apps/control-plane/config").mkdir(parents=True)
            (directory / "apps/control-plane/config/.env").write_text('FRED_BOOTSTRAP_TOKEN="t"\n')
            docker = directory / "docker"
            docker.write_text('''#!/bin/sh
if [ "$RUNNING_CONTAINER" = "$4" ]; then echo healthy; else exit 1; fi
''')
            docker.chmod(0o755)
            fake_make = directory / "make"
            fake_make.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
''')
            fake_make.chmod(0o755)
            calls = directory / "calls"
            for running in ("app-postgres", "weaver-app-postgres"):
                with self.subTest(running=running):
                    result = subprocess.run(
                        ["bash", "bin/docker-prepare"], cwd=ROOT,
                        env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                             "DIR": str(directory),
                             "RUNNING_CONTAINER": running, "CALLS": str(calls)},
                        capture_output=True, text=True,
                    )
                    if running == "app-postgres":
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("make docker-weaver-up first", result.stderr)
                        self.assertFalse(calls.exists())
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual([line.split()[-1] for line in calls.read_text().splitlines()],
                                         ["setup-env", "docker-prepare"])

    def test_stop_down_and_wipe_leave_shared_authentication_alone(self):
        for variant, prefix in (("swift", ""), ("weaver", "weaver-")):
            for action in ("stop", "down", "wipe", "destroy"):
                with self.subTest(variant=variant, action=action):
                    commands = make("-sn", f"docker-{action}", f"DOCKER_ENV={variant}")
                    projects = re.findall(r" -p (\S+)", commands)
                    self.assertTrue(projects)
                    if action == "stop":
                        self.assertIn(f"-p {prefix}$project stop", commands)
                        self.assertNotIn("for project in postgres keycloak", commands)
                    else:
                        self.assertTrue(set(projects) <= {f"{prefix}{name}" for name in PROJECTS if name != "keycloak"})
                    self.assertNotIn("keycloak", projects)
                    self.assertNotIn("weaver-keycloak", projects)
                    self.assertNotIn("docker network rm", commands)
                    self.assertNotIn("up-shared.sh", commands)

    def test_resume_starts_only_weaver_persistent_containers(self):
        with tempfile.TemporaryDirectory(prefix="compose commands ") as tmp:
            directory = Path(tmp)
            docker = directory / "docker"
            docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as output:
    output.write(json.dumps(args) + "\\n")
if args[0] == "exec":
    print("t")
elif args[0] == "ps":
    label = args[args.index("--filter") + 1]
    project = label.rsplit("=", 1)[1]
    if project.startswith("weaver-"):
        name = "weaver-app-" + project.removeprefix("weaver-")
        print(name)
        print(name + "-post-install-job")
elif args[0] == "inspect":
    if "RestartPolicy" in args[args.index("--format") + 1]:
        print("no" if args[-1].endswith("-job") else "unless-stopped")
    else:
        print("healthy")
''')
            docker.chmod(0o755)
            calls = directory / "calls.jsonl"
            make("-s", "docker-start", "DOCKER_ENV=weaver",
                 "DOCKER_ENV_FILE=docker/.env.template",
                 "DOCKER_SHARED_ENV_FILE=docker/.env.template", env_overrides={
                     "PATH": f"{directory}:{os.environ['PATH']}", "CALLS": str(calls),
                 })
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            started = [name for command in commands if command[0] == "start" for name in command[1:]]
            self.assertEqual(set(started), {f"weaver-app-{project}" for project in PROJECTS[:6] if project not in {"keycloak", "openfga"}})
            self.assertFalse(any(name.endswith("-job") for name in started))
            stop_commands = [c for c in commands if c[0] == "compose" and c[-1] == "stop"]
            self.assertEqual({c[c.index("-p") + 1] for c in stop_commands}, set(PROJECTS) - {"keycloak"})
            first_start = next(i for i, c in enumerate(commands) if c[0] == "start")
            self.assertLess(max(i for i, c in enumerate(commands) if c in stop_commands), first_start)

    def test_swift_checkpoints_cannot_be_used_against_weaver(self):
        for script in ("checkpoint-save.sh", "checkpoint-restore.sh"):
            result = subprocess.run(
                ["bash", str(ROOT / "bin" / script), "unused"],
                env={**os.environ, "DOCKER_ENV": "weaver"},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("support DOCKER_ENV=swift only", result.stderr)


class SharedKeycloakMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shared keycloak ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        keycloak = self.root / "docker/keycloak"
        keycloak.mkdir(parents=True)
        shutil.copy(ROOT / "docker/keycloak/up-shared.sh", keycloak)
        (keycloak / "keycloak-post-install.sh").write_text(
            '#!/bin/bash\nprintf \'["provision"]\\n\' >> "$CALLS"\n'
        )
        commands = self.root / "commands"
        commands.mkdir()
        fake = commands / "docker"
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as output:
    output.write(json.dumps(args) + "\\n")
text = " ".join(args)
if args[0] == "compose":
    image = os.environ.get("KEYCLOAK_DEFAULT_POSTGRES_IMAGE", "")
    if not image or any(c.isspace() for c in image):
        print("invalid reference format", file=sys.stderr)
        sys.exit(1)
    with open(os.environ["CALLS"] + ".image", "a") as output:
        output.write(image + "\\n")
if args[0] == "volume":
    sys.exit(0 if os.environ.get("LEGACY_VOLUME") == "1" else 1)
elif args[0] == "inspect":
    if ".Config.Image" in text:
        if args[-1] in os.environ.get("MISSING_IMAGE_CONTAINERS", "").split(","):
            # Docker inspect emits a blank stdout line even when lookup fails.
            print()
            sys.exit(1)
        print("pgvector/pgvector:pg15")
    else:
        variable = {"app-postgres": "SOURCE_RUNNING", "weaver-app-postgres": "WEAVER_RUNNING"}.get(args[-1])
        print(os.environ.get(variable, "true") if variable else "true")
elif args[0] == "compose" and "config" in args:
    print(json.dumps({"services": {"keycloak": {"environment": {"KC_DB_URL": "jdbc:postgresql://keycloak-postgres:5432/keycloak"}}}}))
elif args[0] == "exec":
    if args[-2:] == ["postgres", "--version"]:
        major = os.environ.get("SOURCE_MAJOR", "15") if args[1] == "app-postgres" else "15"
        print("postgres (PostgreSQL) " + major + ".12")
    elif "pg_dump" in text:
        print("database archive")
    elif "pg_restore" in text:
        assert sys.stdin.read().strip() == "database archive"
        sys.exit(1 if os.environ.get("FAIL_RESTORE") == "1" else 0)
    elif "SELECT datname" in text:
        print("postgres\\nkeycloak")
    elif "to_regclass" in text:
        if args[1] == "app-keycloak-postgres":
            print(os.environ.get("TARGET_READY", "t"))
        elif os.environ.get("FAIL_SOURCE_QUERY") == "1":
            sys.exit(1)
        else:
            print("t")
''')
        fake.chmod(0o755)
        self.env = {
            **os.environ, "PATH": f"{commands}:{os.environ['PATH']}",
            "CALLS": str(self.root / "calls.jsonl"),
            "DOCKER_SHARED_ENV_FILE": str(self.root / ".env"),
        }

    def run_bootstrap(self, **flags):
        result = subprocess.run(
            ["bash", str(self.root / "docker/keycloak/up-shared.sh")],
            env={**self.env, **flags}, capture_output=True, text=True,
        )
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        return result, calls

    def test_existing_shared_realm_is_never_reimported_or_reprovisioned(self):
        result, calls = self.run_bootstrap(LEGACY_VOLUME="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] in {"volume", "stop", "provision"} for c in calls))
        self.assertFalse(any("pg_restore" in " ".join(c) for c in calls))

    def test_missing_shared_container_does_not_add_a_newline_to_legacy_image(self):
        result, _ = self.run_bootstrap(MISSING_IMAGE_CONTAINERS="app-keycloak-postgres")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls.jsonl.image").read_text().splitlines()[0], "pgvector/pgvector:pg15")

    def test_missing_containers_use_the_default_image_without_blank_lines(self):
        result, _ = self.run_bootstrap(MISSING_IMAGE_CONTAINERS="app-keycloak-postgres,app-postgres")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls.jsonl.image").read_text().splitlines()[0], "pgvector/pgvector:pg15")

    def test_legacy_realm_is_copied_atomically_after_stopping_old_keycloak(self):
        result, calls = self.run_bootstrap(TARGET_READY="f", LEGACY_VOLUME="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        dump = next(i for i, c in enumerate(calls) if "pg_dump" in " ".join(c))
        restore = next(i for i, c in enumerate(calls) if "pg_restore" in " ".join(c))
        self.assertLess(calls.index(["stop", "app-keycloak"]), dump)
        self.assertLess(dump, restore)
        self.assertIn("--single-transaction", " ".join(calls[restore]))
        self.assertNotIn(["provision"], calls)
        self.assertFalse(any("DROP DATABASE" in " ".join(c) for c in calls))

    def test_failed_restore_restarts_the_legacy_keycloak(self):
        result, calls = self.run_bootstrap(TARGET_READY="f", LEGACY_VOLUME="1", FAIL_RESTORE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls[-1], ["start", "app-keycloak"])
        self.assertNotIn(["provision"], calls)

    def test_source_query_failure_cannot_silently_create_a_fresh_realm(self):
        result, calls = self.run_bootstrap(TARGET_READY="f", LEGACY_VOLUME="1", FAIL_SOURCE_QUERY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(["stop", "app-keycloak"], calls)
        self.assertNotIn(["provision"], calls)

    def test_newer_source_is_rejected_before_keycloak_is_stopped(self):
        result, calls = self.run_bootstrap(TARGET_READY="f", LEGACY_VOLUME="1", SOURCE_MAJOR="17")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("KEYCLOAK_POSTGRES_IMAGE", result.stderr)
        self.assertNotIn(["stop", "app-keycloak"], calls)

    def test_a_new_installation_provisions_the_empty_shared_realm(self):
        result, calls = self.run_bootstrap(TARGET_READY="f")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], ["provision"])

    def test_stopped_legacy_postgres_releases_weaver_port_before_starting(self):
        result, calls = self.run_bootstrap(TARGET_READY="f", LEGACY_VOLUME="1", SOURCE_RUNNING="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        source_start = next(i for i, c in enumerate(calls) if c[0] == "compose" and c[-1] == "postgres")
        self.assertLess(calls.index(["stop", "weaver-app-postgres"]), source_start)


if __name__ == "__main__":
    unittest.main()
