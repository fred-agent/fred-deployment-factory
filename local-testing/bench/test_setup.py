"""Offline regression checks for policy preservation and replay; no cluster/load."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from setup import OFFER, agent_body, apply, ensure_agent, import_users, policy_with_mock
from prepare_conversations import client_declaration


class SetupTests(unittest.TestCase):
    def test_append_offer_preserves_every_real_selection_and_revision(self):
        real = {"source_id": "real", "upstream_model_id": "chat"}
        policy = {"revision": 7, "permitted": [real], "reasoning_enabled": [real],
                  "default": real, "fallback": None, "title": real,
                  "embedding": {"source_id": "real", "upstream_model_id": "embed"}, "vision": real}
        before = copy.deepcopy(policy)
        body = policy_with_mock(policy)
        self.assertEqual(policy, before)
        self.assertEqual(body["expected_revision"], 7)
        self.assertEqual(body["permitted"], [real, OFFER])
        for key in ("default", "fallback", "title", "embedding", "vision", "reasoning_enabled"):
            self.assertEqual(body[key], before[key])
        body["revision"] = 8
        self.assertEqual(policy_with_mock(body)["permitted"], [real, OFFER])

    def test_completed_import_replay_sends_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            (output / "swift-import-state.json").write_text('{"complete": true}')
            with patch("setup.API") as api:
                import_users(api, "swift", output)
                api.request.assert_not_called()

    def test_accepted_swift_import_resumes_same_task_and_checks_skips(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            (output / "swift-import-state.json").write_text('{"task_id": "existing"}')
            with patch("setup.API") as api:
                api.request.return_value = {"tasks": [{"state": "succeeded", "detail": {"result": {"users_skipped": ["a"]}}}]}
                with self.assertRaises(ValueError):
                    import_users(api, "swift", output)
                self.assertEqual(api.request.call_args.args, ("GET", "/tasks?scope=user&task_id=existing"))
                self.assertNotIn("complete", json.loads((output / "swift-import-state.json").read_text()))

    def test_apply_twice_preserves_policy_and_reuses_client_imports_agents(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            config = {"issuer": "http://keycloak:8080/realms/app", "users": 1, "keycloak_admin_token_file": "unused"}
            for target in ("swift", "weaver"):
                config[target] = {"origin": f"http://{target}.localhost:8088", "team_id": "team", "team_name": "Team", "operator_token_file": "unused"}
                (output / (target + "-provisioning.zip")).write_bytes(b"fixture")
            config["weaver"].update(organization_id="org", organization_name="Org")
            (output / "setup.json").write_text(json.dumps(config))
            declaration = client_declaration("test-secret")
            (output / "keycloak-client.json").write_text(json.dumps(declaration))
            calls, clients, agents = [], [], {}
            policy = {"revision": 2, "permitted": [], "reasoning_enabled": [], "default": None, "fallback": None, "title": None, "embedding": None, "vision": None}

            class FakeAPI:
                def __init__(self, root, token):
                    self.target = "keycloak" if "/admin/realms/" in root else "swift" if "swift.localhost" in root else "weaver"

                def request(self, method, path, body=None, *args):
                    target = self.target
                    calls.append((target, method, path))
                    if target == "keycloak":
                        if path.startswith("/clients?"):
                            return clients
                        if path == "/clients" and method == "POST":
                            clients.append({"id": "client"})
                            return None
                        if path.endswith("/client-secret"):
                            return {"value": "test-secret"}
                        return dict(declaration, protocolMappers=[dict(m, id="generated", consentRequired=False) for m in declaration["protocolMappers"]])
                    if path == "/platform-access/status":
                        return {"admitted": True, "cgu_required": False}
                    if path == "/me/onboarding":
                        return {"admitted": True, "gcu_version": "v1", "acceptance": {"version": "v1"}, "root_bootstrap_required": False}
                    if path == "/teams/team":
                        return {"name": "Team"}
                    if path == "/me/spaces":
                        return [{"id": "team", "name": "Team", "kind": "team", "organization_id": "org"}]
                    if path == "/admin/organizations/org":
                        return {"organization": {"name": "Org"}}
                    if path.endswith("/agent-templates"):
                        return [{"template_id": "template", "source_runtime_id": "fred-agents", "source_agent_id": "fred.github.assistant", "status": "available"}]
                    if path.endswith("/agent-instances"):
                        if method == "POST":
                            agents[target] = dict(body, agent_instance_id=target, selected_capability_ids=[])
                            return agents[target]
                        return [agents[target]] if target in agents else []
                    if "/agent-instances/" in path:
                        return agents[target]
                    if path == "/import-export/import":
                        return {"task_id": "task"} if target == "swift" else {"grants_acknowledged": 2}
                    if path.startswith("/tasks?"):
                        return {"tasks": [{"state": "succeeded", "detail": {"failed": 0, "result": {}}}]}
                    if path.endswith("/refresh"):
                        return None
                    if path.endswith("/model-policy"):
                        if method == "PUT":
                            policy.update({k: v for k, v in body.items() if k != "expected_revision"})
                            policy["revision"] += 1
                        return copy.deepcopy(policy)
                    if path.endswith("/models"):
                        return {"policy": {"disabled": []}}
                    raise AssertionError((target, method, path))

            with patch("setup.API", FakeAPI), patch("setup.subprocess.run") as cli:
                apply(config, output)
                apply(config, output)
                self.assertEqual(cli.call_count, 2)  # native CLI itself is idempotent
            writes = [call for call in calls if call[1] in ("POST", "PUT")]
            self.assertEqual(writes.count(("keycloak", "POST", "/clients")), 1)
            for target in ("swift", "weaver"):
                self.assertEqual(writes.count((target, "POST", "/import-export/import")), 1)
                self.assertEqual(sum(x[0] == target and x[2].endswith("/agent-instances") for x in writes), 1)
            self.assertEqual(writes.count(("weaver", "PUT", "/organizations/org/model-policy")), 1)
            self.assertEqual(policy["permitted"], [OFFER])
            self.assertIsNone(policy["default"])

    def test_agent_replay_reuses_same_instance_and_rejects_drift(self):
        for target in ("swift", "weaver"):
            body = agent_body(target, "template")
            saved = dict(body, agent_instance_id="saved", selected_capability_ids=[])
            with patch("setup.API") as api:
                api.request.side_effect = [[saved], saved]
                self.assertEqual(ensure_agent(api, target, "/scope", "template"), saved)
                self.assertTrue(all(call.args[0] == "GET" for call in api.request.call_args_list))
            changed = dict(saved, tuning_field_values={"prompts.system": "other"})
            with patch("setup.API") as api:
                api.request.side_effect = [[changed], changed]
                with self.assertRaises(ValueError):
                    ensure_agent(api, target, "/scope", "template")
                self.assertTrue(all(call.args[0] == "GET" for call in api.request.call_args_list))


if __name__ == "__main__":
    unittest.main()
