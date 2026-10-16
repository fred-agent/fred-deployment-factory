# Fred Deployment Factory

Runs [Fred](https://github.com/ThalesGroup/fred) and the applications built on it on your
machine. On k3d, this repository alone deploys the published releases of Fred and the
evaluation application. To run your own code, clone this repository **next to** `fred` and
the applications you work on (agent pods, Knowledge Bases, the evaluator...): the commands
below refer to them as `../<repository>`.

There are two ways to run. Pick one per session:

| | **Docker** | **k3d** |
| --- | --- | --- |
| What runs where | the infrastructure (Keycloak, Postgres, OpenFGA, OpenSearch, Temporal...) in containers; Fred and the applications from their checkouts, with `make run` | everything in a local Kubernetes cluster: the infrastructure, then Fred and each application deployed with its Helm chart |
| Use it to | debug an application quickly (breakpoints, reload) | test as production deploys: charts, images, identities, observability |

**Once, for Docker:** in your `fred` checkout, run `make setup-env` (it creates each backend's
`config/.env` and asks for your model API key). On k3d, the key is a Kubernetes Secret, as in
production (below).

---

## Docker

**Once:** Docker, and for the browser:

```bash
grep -q 'app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

**Then:**

```bash
make docker-up                                   # here: the infrastructure
cd ../fred && make run                           # Fred: control plane, agents, knowledge flow, frontend
cd apps/control-plane-backend && make bootstrap-local BOOTSTRAP_USER=<you> BOOTSTRAP_PASSWORD=<your password>
```

`bootstrap-local` runs once per platform: it waits while you register that account in
Keycloak, then makes you `platform_admin`.

Fred is on <http://localhost:5173>.

**An application** (agent pod, Knowledge Base, evaluator): in its checkout, make
`config/.env` point `CONFIG_FILE` at the configuration that targets the Docker services
(its README names it), then `make run`.

**Day to day:** `make docker-stop` / `make docker-start` (containers and data kept).
`make docker-wipe` deletes the containers **and every volume**.

---

## k3d

**Once:** Docker, [`k3d`](https://k3d.io), `kubectl`, `helm`,
[Helmfile](https://github.com/helmfile/helmfile/releases) and `jq`, and for the browser:

```bash
grep -qw keycloak /etc/hosts || echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

**Then, from this repository:**

```bash
make k3d-up                                 # the infrastructure and the observability
kubectl --context k3d-fred -n fred create secret generic fred-model-credentials \
  --from-literal=OPENAI_API_KEY=<key>       # your model key, once per cluster, as in production
make k3d-app APP=fred                       # Fred's published release
make k3d-app APP=fred-evaluator             # the evaluation application's published release
make k3d-app APP=fred DIR=../fred           # or build and deploy your checkout; rerun after any change
make k3d-app DIR=../<application>           # an application defined in its repository, e.g. ../dt-agents
make k3d-health                             # what needs attention, on one screen
```

`make k3d-app APP=fred` ends with the command that prints the **bootstrap token**. Open
<http://localhost:8088>, **Register** on the login page, and paste that token where Fred
asks for it: you are `platform_admin` (once per platform). Then enable what you need in
**Admin > Features**.

**Integration tests:** before running `cd ../fred && make integration-test-k3d`,
follow [Prepare k3d for Fred integration tests](docs/LOCAL-DEVELOPMENT.md#prepare-k3d-for-fred-integration-tests).
The suite logs in as the demo users without a browser: it needs Keycloak Direct
access grants, plus the test agent, document capability and configured model
allowed for the test team. Browser login alone does not establish these
prerequisites. Make selects the URLs; it does not enable permissions.

| URL | What | Login |
| --- | --- | --- |
| <http://localhost:8088> | Fred and its applications | your account |
| <http://localhost:3002> | Grafana, folder **Fred** | `admin` / `Azerty123_` |
| <http://localhost:5601> | OpenSearch Dashboards: every pod's logs (`k3d-logs*`) | `admin` / `FredOpensearch123!!` |
| <http://localhost:8233> | Temporal | — |
| <http://keycloak:8080> | Keycloak (realm `master`) | `admin` / `Azerty123_` |

**I want to...** `make k3d-app` converges: the first run installs, the next ones upgrade in
place, keeping the data. You choose an application (`APP=fred`, `APP=fred-evaluator`, or
`DIR=` a repository that defines its own) and a version (none: the release this repository
pins, bumped by a Renovate PR after each release; `RELEASE=x.y.z`; or `DIR=` your checkout).

| I want to... | Run |
| --- | --- |
| Install everything on a new cluster | `make k3d-up`, the model key Secret, `make k3d-app APP=fred`, `make k3d-app APP=fred-evaluator` |
| Upgrade to the new release, once its Renovate PR is merged | `git pull`, then `make k3d-app APP=fred` (data kept) |
| Run another published release | `make k3d-app APP=fred RELEASE=x.y.z` |
| Test my fred code | `make k3d-app APP=fred DIR=../fred`, rerun after any change |
| Go back to the published release | `make k3d-app APP=fred` (no `DIR`) |
| Deploy my own application | `make k3d-app DIR=../<application>` |
| Stop the cluster, keeping the data | `make k3d-down`, then `make k3d-up` to resume |
| Start over | `make k3d-wipe`, then `make k3d-up`: **deletes every volume: accounts, documents, runs** |

Going back to an older release in place is not supported: database migrations do not
downgrade, and the older chart may refuse the current values. Start over instead.

---

## Work on unreleased fred (both modes)

fred publishes its libraries and charts only when it releases. To run the applications
against your fred checkout instead (the latest `swift`, or your own branch):

```bash
export FRED_LIBS=local
export FRED_REPO=/path/to/your/fred          # required: no default
```

Then `make dev-local` in an application (Docker mode) and `make k3d-app` (k3d) take fred's
libraries, images and charts from that checkout; `make k3d-app` prints which one. Unset
`FRED_LIBS` to go back to the released fred.

---

## More

| For | Read |
| --- | --- |
| Every detail of both modes, the k3d application contract, unreleased fred | [`docs/LOCAL-DEVELOPMENT.md`](docs/LOCAL-DEVELOPMENT.md) |
| Whether fred and the applications next to it agree | `make ecosystem-audit` |
| Finding what is wrong on k3d | `make k3d-health`, then `bin/k3d-observe` (`trace`, `logs`, `kpi`) |
| Test data: the demo teams and their users, large-scale benches | [`local-testing/demo/README.md`](local-testing/demo/README.md), [`local-testing/README.md`](local-testing/README.md) |
| Contributing to this repository | [`CLAUDE.md`](CLAUDE.md) |
