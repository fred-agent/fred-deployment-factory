# Fred Deployment Factory

Run Fred on your machine, from this directory. Pick one:

- **k3d**: Fred deployed as in production. Swift and Weaver side by side.
- **Docker Compose**: Swift or Weaver, run from separate checkouts. The fast loop to debug.

They use the same ports: run only one at a time.

Once: install Docker (and for k3d: k3d, kubectl, Helm, Helmfile) and your checkout's build
tools, add `127.0.0.1 keycloak app-keycloak swift.localhost weaver.localhost` to `/etc/hosts`,
and export your **Mistral** key in your shell profile, for example `~/.bashrc`:

```bash
export MISTRAL_API_KEY=...    # required: the demo organizations Acme and Globex use Mistral
export OPENAI_API_KEY=...     # optional: a real OpenAI key (sk-...), only for the k3d choice below
```

Never put a Mistral key in `OPENAI_API_KEY` (Swift's old convention): Weaver reads each key
under its provider's name. After a change: `make docker-prepare` again, then restart Fred.

## Docker Compose

Weaver:

```bash
make docker-up                          # the backing services: PostgreSQL, Keycloak, OpenSearch, Temporal...
make docker-prepare DIR=/path/to/fred   # prepares your checkout, starts nothing, prints the bootstrap token
make -C /path/to/fred run               # every Fred process in this terminal
```

Instead of `make run`, start each component in its own terminal
(`make -C /path/to/fred/apps/<component> run`), or ask your coding assistant to start Fred.
`docker-prepare` lists both. Then open <http://localhost:5173>.

To explore the logs in Grafana instead: `make fred-json FRED_CHECKOUT=/path/to/fred`, then open
<http://localhost:3002/d/fred-local-logs/fred-logs> ([details](docker/README.md#local-structured-logs)).

Swift, in support: `make docker-swift-up`, then `make run` in the Swift checkout.

Stop the application processes before switching. Weaver to Swift: `make docker-down`, then
`make docker-swift-up`. Swift to Weaver: `make docker-swift-down`, then `make docker-up`.
Each stack keeps its own PostgreSQL and persistent data; Keycloak and its database stay
shared. Ports stay the same; switching requires no wipe.

| I want to | Run |
| --- | --- |
| Restart Fred | `make -C /path/to/fred run` again |
| Change or add a model key | Export it, then `make docker-prepare` again |
| Pause / resume | `make docker-stop` / `make docker-start` |
| **Reset Weaver data** | **`make docker-wipe`**, then `make docker-up` |

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

Swift, unlike Weaver, reads its Mistral key under the name `OPENAI_API_KEY`, from a
secret created once:
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
