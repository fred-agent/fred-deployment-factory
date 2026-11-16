# Local conversation benchmark identities

This preparation is for N distinct synthetic people with identical ordinary rights
on one existing team, using one existing agent. Generate the largest desired pool
once, then reuse it for the 1-person/N-conversation reference and N-person runs.
Each conversation has ten sequential turns; scheduling belongs to the Go client.
This is separate from the authorization fan-out scenario in [README.md](README.md).

## Offline preparation

Python 3.10+ and a Weaver Fred checkout are the only dependencies. This command
does not contact Keycloak, Fred, a cluster or a database:

```bash
python3 local-testing/bench/prepare_conversations.py \
  --users 500 \
  --issuer http://keycloak:8080/realms/app \
  --swift-team 'Existing Swift Team' \
  --weaver-organization 'Existing Organization' \
  --weaver-team 'Existing Weaver Team' \
  --fred-source /absolute/path/to/weaver/fred \
  --output /tmp/fred-conversation-inputs
```

The output must not exist and its parent must exist. Its mode is 0700; all four
files are 0600. Usernames receive a random `bench-` prefix by default. An explicit
`--prefix bench-unique-campaign` is available for controlled preparation; it must
not collide with existing realm accounts. Passwords and the client secret are
random. No password, secret or token is printed. Do not commit or share the files.

| File | Purpose |
| --- | --- |
| `swift-provisioning.zip` | Existing Swift v1 manifest/users format; `team_member` only |
| `weaver-provisioning.zip` | Existing Weaver v2 format, built by Fred's canonical packager; `member` on both organization and team |
| `keycloak-client.json` | Dedicated confidential OAuth client `fred-bench-local`, audience `app` |
| `credentials.json` | Private inputs for the Go benchmark, contract below |

Neither bundle grants a platform, editor, analyst or owner role, creates an agent,
nor accepts CGU. Teams and organization must already exist: the bundles deliberately
contain no administrator/owner seed. Existing identity passwords are preserved by
the importers, so a username collision can leave generated credentials unusable.
Offline generation cannot detect remote collisions. Reuse the original output
after a partial import instead of regenerating passwords for the same usernames.

Allowed issuer hosts are `keycloak`, `app-keycloak`, `localhost`, names ending in
`.localhost`, and literal loopback IP addresses (`127.0.0.0/8`, `::1`). Only HTTP(S)
with `/realms/<realm>` and no credentials, query or fragment is accepted. The realm
name uses ASCII letters, digits, `_` or `-`. No DNS request is made during generation.
The factory's k3d issuer is `http://keycloak:8080/realms/app`; docker uses
`http://app-keycloak:8080/realms/app`. These aliases must resolve to the local stack
(normally `127.0.0.1` in the operator's hosts file); a hostname allowlist is not
proof of where DNS resolves. Do not substitute `localhost` if Fred trusts a
different issuer. See [local development](../../docs/LOCAL-DEVELOPMENT.md) and
[docker setup](../../docker/README.md).

## Explicit operator setup, later

These steps mutate the selected local environment. Generation does not execute
them, and the benchmark must never run them implicitly.

1. Open the local Keycloak Admin Console, select realm `app`, then **Clients**.
   First check that `fred-bench-local` does not already exist. If it exists, retain
   its original preparation/secret; do not overwrite it with a newly generated
   file. Otherwise use **Import client** with `keycloak-client.json`. Verify the
   imported client ID and confidential client authentication, Direct Access Grants
   enabled, and standard/implicit/service-account flows disabled. Do not edit `app`
   or change realm/session/token lifetimes. Check that audience mapper `app` and
   only `profile`/`email` default scopes were imported. The explicit `sub` mapper
   identifies the authenticated person without adding the `basic` scope required
   for that claim by recent Keycloak defaults.
2. Sign in to Swift as an existing platform administrator and import
   `swift-provisioning.zip` through **Admin > Migration**. Wait for the import task
   to finish successfully and inspect its result, not just the 202 launch response.
   Sign in to Weaver as its existing platform administrator, personally accept
   active CGU if needed, and import `weaver-provisioning.zip` through
   **Admin > Provisioning**. The public API equivalent for both is multipart
   `POST /control-plane/v1/import-export/import`, field `file`, operator bearer.
   Imports create missing Keycloak identities and reconcile application grants;
   shared Keycloak means the second import reuses the same identities. No separate
   `keycloak-add-user.sh` step is needed. Partial failures are not rollbacks:
   inspect, correct, then replay the same ZIP.
3. Before measured work, authenticate each synthetic account and explicitly accept
   its own active CGU through the ordinary flow if required. Weaver exposes
   `GET /control-plane/v1/frontend/config`, `GET /control-plane/v1/me/onboarding`
   and `POST /control-plane/v1/gcu` with `{"version":"<active version>"}` under
   that account's bearer. Import never means acceptance. Preflight every account's
   membership and access to the selected existing agent through normal public APIs.
   Use a real admitted person, never a workload token or an invented user ID.
4. Only after setup and preflight, run the separately configured benchmark. Login
   belongs outside measurements. Keep password, access-token and refresh-token
   contents out of reports, command-line arguments and logs. Disable the dedicated
   client in Keycloak when finished; preserve `app` and the other clients.

The dedicated Direct Grant client is an explicit local-test exception for disposable
identities. [Keycloak discourages this flow for applications](https://www.keycloak.org/securing-apps/oidc-layers):
the tool handles passwords, and interactive required actions/identity brokering are
unsupported. Accounts must satisfy the existing password policy and have no pending
required action; do not relax realm policy to get a successful login. The client
does not itself restrict which realm users can submit credentials. Keep its secret
and endpoint local. No service account, admin role, delegated audience or offline
access is enabled; application authorization still comes from the ordinary grants.

## Credentials contract for the Go consumer

```json
{
  "schema_version": 1,
  "issuer": "http://keycloak:8080/realms/app",
  "client_id": "fred-bench-local",
  "client_secret": "<private generated secret>",
  "users": [
    {"label": "user-0001", "username": "bench-<random>-0001", "password": "<private generated password>"}
  ]
}
```

The token endpoint is exactly `<issuer>/protocol/openid-connect/token`; it is not
a separately supplied destination. If discovery is used, verify issuer and token
endpoint equality. Refuse redirects. Initial `grant_type=password` authenticates
each real person with the confidential client; subsequent `grant_type=refresh_token`
uses the same client authentication. Do not persist access/refresh tokens. A pool
entry must remain bound to its verified `sub`; labels are local reporting handles,
not server identities. Reports should use campaign-scoped pseudonyms.

Serialize refresh per identity, including the one-person baseline sharing many
conversations; atomically replace rotating access/refresh tokens and refresh before
expiry. Terminal refresh failure ends that identity's work, without replaying an
ambiguous conversation POST. Session maximum lifetime still applies. Authentication
preparation/refresh time must be distinguishable from measured conversation latency.
The generator supplies inputs only; it does not implement or attest these consumer
behaviors or successful authentication against a deployed stack.

## Offline checks

```bash
FRED_WEAVER_SOURCE=/absolute/path/to/weaver/fred \
  python3 -m unittest discover -s local-testing/bench -p 'test_prepare_conversations.py' -v
```

Checks cover actual ZIP packaging, exact ordinary roles/shared identities, private
file modes, output collisions, restricted client declaration, local issuer parsing,
redaction and removal of partial outputs. They launch no services or load campaign.
