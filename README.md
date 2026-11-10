# Fred Deployment Factory

Run Fred on your machine, from this directory. Pick one:

- **k3d**: Fred deployed as in production. Swift and Weaver side by side.
- **Docker Compose**: Swift or Weaver, run from separate checkouts. The fast loop to debug.

They use the same ports: run only one at a time.

Once: install Docker (and for k3d: k3d, kubectl, Helm, Helmfile) and your checkout's build
tools, add `127.0.0.1 keycloak app-keycloak swift.localhost weaver.localhost` to `/etc/hosts`,
and export your model key in your shell profile, for example `~/.bashrc`:

```bash
export MISTRAL_API_KEY=...    # and/or
export OPENAI_API_KEY=...
```

Fred Weaver accepts either or both. An organization owner chooses chat models and the
documents' embedding model in **Models**; a provider without its key stays unavailable.

## Docker Compose

Weaver:

```bash
make docker-weaver-up                   # the backing services: PostgreSQL, Keycloak, OpenSearch, Temporal...
make docker-prepare DIR=/path/to/fred   # prepares your checkout, starts nothing, prints the bootstrap token
make -C /path/to/fred run               # every Fred process in this terminal
```

Instead of `make run`, start each component in its own terminal
(`make -C /path/to/fred/apps/<component> run`), or ask your coding assistant to start Fred.
`docker-prepare` lists both. Then open <http://localhost:5173>.

Swift: `make docker-up`, then `make run` in the Swift checkout.

Stop the application processes before switching. Swift to Weaver: `make docker-down`, then
`make docker-weaver-up`. Weaver to Swift: `make docker-weaver-down`, then `make docker-up`.
Each stack keeps its own PostgreSQL and persistent data; Keycloak and its database stay
shared. Ports stay the same; switching requires no wipe.

| I want to | Run |
| --- | --- |
| Restart Fred | `make -C /path/to/fred run` again |
| Change or add a model key | Export it, then `make docker-prepare` again |
| Pause / resume Weaver | `make docker-weaver-stop` / `make docker-weaver-start` |
| **Reset Weaver data** | **`make docker-weaver-wipe`**, then `make docker-weaver-up` |

Optional Zabbix 7.0 LTS monitoring: `make docker-up USE_ZABBIX=true` (and
`make docker-start USE_ZABBIX=true` after stopping), or `make zabbix-up` on an existing
stack. Follow the [Zabbix Compose procedure](docker/README.md#optional-zabbix-70-lts).

## k3d

```bash
make k3d-up
make k3d-app FRED=weaver APP=fred DIR=/path/to/fred       # Weaver: your checkout, your exported keys
make k3d-app FRED=swift APP=fred                          # Swift: the published release
```

Weaver initializes the demo organizations on Mistral. Choose another provider
explicitly, with the keys it needs exported:
`VALUES=k3d-apps/fred/models-openai.yaml` (OpenAI only) or
`VALUES=k3d-apps/fred/models-mistral-openai.yaml` (Acme on Mistral, Globex on OpenAI).
Choose before the first deployment: the policy is initialized once, then administered in
**Models**.

Swift reads its Mistral key from a secret created once:
`kubectl --context k3d-fred -n fred-swift create secret generic fred-model-credentials --from-file=OPENAI_API_KEY=/path/to/key-file`.
Open <http://weaver.localhost:8088> or <http://swift.localhost:8088>.

| I want to | Run |
| --- | --- |
| Redeploy Fred | The same `make k3d-app` again |
| Pause / resume | `make k3d-stop` / `make k3d-start` |
| Find out what is wrong | `make k3d-health` |
| **Start over (deletes everything)** | **`make k3d-wipe`**, then `make k3d-up` |

## First login

1. Open Fred and register: the realm starts empty.
2. Paste the bootstrap token when Fred asks for it, then accept the terms. `make docker-prepare`
   prints it; on k3d, `make k3d-app` prints the command that reads it.
3. Continue with Fred's [first start](https://github.com/ThalesGroup/fred/blob/weaver/deploy/k3d/README.md#first-start):
   demo bundle, models, first answer from documents.

## More

- [How it works](docs/HOW-IT-WORKS.md): every k3d option (`RELEASE`, `VALUES`, other applications)
- [Swift and Weaver side by side](docs/SWIFT-WEAVER.md): what is isolated, what is shared
- [Technical reference](docs/LOCAL-DEVELOPMENT.md): Docker Compose details, tests, identity providers
