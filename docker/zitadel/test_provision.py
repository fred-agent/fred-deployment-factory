"""Offline checks for local provisioning and workload claim admission."""

import base64
import io
import json
import secrets
import unittest
from unittest.mock import patch

import provision


class TokenClaimsTests(unittest.TestCase):
    def test_workload_claims_are_required_before_configs_are_published(self):
        credentials = {"clientId": "test-client", "clientSecret": secrets.token_hex(16)}
        claims = {
            "iss": provision.ISSUER,
            "sub": "service-user-id",
            "aud": ["project"],
            "roles": ["service_agent"],
            "client_id": "test-client",
        }

        def response(*args, **kwargs):
            part = (
                base64.urlsafe_b64encode(json.dumps(claims).encode())
                .decode()
                .rstrip("=")
            )
            return io.BytesIO(
                json.dumps({"access_token": "header." + part + ".signature"}).encode()
            )

        with patch.object(provision.HTTP, "open", response):
            provision.check_workload_tokens(
                {"knowledge-flow": credentials}, "scope", "project"
            )
            for field, wrong in (
                ("iss", "wrong"),
                ("sub", ""),
                ("aud", []),
                ("roles", []),
                ("client_id", "other"),
            ):
                previous = claims[field]
                claims[field] = wrong
                with self.subTest(field=field), self.assertRaises(RuntimeError):
                    provision.check_workload_tokens(
                        {"knowledge-flow": credentials}, "scope", "project"
                    )
                claims[field] = previous
            with self.assertRaises(RuntimeError):
                provision.check_workload_tokens(
                    {"agentic": credentials}, "scope", "project"
                )
            claims["roles"].append("delegation_caller")
            provision.check_workload_tokens(
                {"agentic": credentials}, "scope", "project"
            )
            with self.assertRaises(RuntimeError):
                provision.check_workload_tokens(
                    {"knowledge-flow": credentials}, "scope", "project"
                )


if __name__ == "__main__":
    unittest.main()
