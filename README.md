# Fred Deployment Factory

Install Fred locally. Follow **k3d** to run Fred in Kubernetes, or **Docker** to
run the Fred processes on your machine. Weaver comes first; Swift is optional.

## k3d

### 1. Prerequisites

Install **Git, Docker, k3d, kubectl, Helm, Helmfile, Make, Python 3 and OpenSSL**.
Docker must be running.

Clone this repository and run the following commands from it:

```bash
git clone --branch weaver https://github.com/fred-agent/fred-deployment-factory.git
cd fred-deployment-factory
```

Add this line to `/etc/hosts`:

```text
127.0.0.1 keycloak app-keycloak weaver.localhost swift.localhost
```

### 2. Start the infrastructure

```bash
make k3d-up
```

This creates the cluster and prepares the shared services, including OpenSearch
certificates. Certificates are created once and reused on subsequent starts.
No manual TLS setup is needed on a new machine.

Weaver and Swift can run side by side: `fred-weaver` and `fred-swift` are their
namespaces; `fred-infra` holds the shared infrastructure.
If Docker Compose is already running, stop it first with `make docker-stop`.

### 3. Set your model API keys

**Weaver reads its keys from the Kubernetes Secret `fred-model-credentials`:**

Export `MISTRAL_API_KEY` and `OPENAI_API_KEY` in your shell, for example in
`~/.bashrc`. If you just edited that file, run `source ~/.bashrc`, then create
the Secret from those variables:

```bash
kubectl --context k3d-fred -n fred-weaver create secret generic fred-model-credentials \
  --from-literal=MISTRAL_API_KEY="$MISTRAL_API_KEY" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY"
```

Keep both lines to use both providers, or keep only the one you need.
Use double quotes so the shell substitutes the variable values.
**The current demo uses Mistral**, including for document embeddings: provide a
Mistral key to follow the demo as supplied. An OpenAI key alone requires changing
the initial model configuration.

**If you want Swift**, create its separate Secret. The current Swift profile uses
Mistral but expects its key under the name `OPENAI_API_KEY`:

```bash
kubectl --context k3d-fred -n fred-swift create secret generic fred-model-credentials \
  --from-literal=OPENAI_API_KEY="$MISTRAL_API_KEY"
```

### 4. Install Fred

**Weaver, using published images:**

```bash
make k3d-app FRED=weaver APP=fred
```

This selects the latest published `5.0.0-dev.<run-id>.<attempt>` chart, including
monitor and the exact image digests from that successful build. Run the same
command again to consume the next build; publication alone does not deploy it.
The platform still needs its Secrets and instance values. Fresh installations
only: an incompatible development database must be recreated deliberately.

To build from a local Weaver checkout instead:

```bash
make k3d-app FRED=weaver APP=fred DIR=~/Work/weaver/fred
```

`DIR` builds the images from your checkout and installs them in k3d. The first
build can take several minutes.

**If you want Swift**, use its published images:

```bash
make k3d-app FRED=swift APP=fred
```

Or build your local Swift checkout:

```bash
make k3d-app FRED=swift APP=fred DIR=~/Work/swift/fred
```

To select a specific published version, add `RELEASE=<version>` instead of `DIR`.

### 5. Become the platform administrator

1. Open [Weaver](http://weaver.localhost:8088).
2. Register an account, for example `admin` / `Azerty123_` for this local installation.
3. Retrieve the bootstrap token:

   ```bash
   kubectl --context k3d-fred -n fred-weaver get secret fred-secrets \
     -o jsonpath='{.data.CONTROL_PLANE_BOOTSTRAP_TOKEN}' | base64 -d; echo
   ```

4. Sign in, enter the token in the bootstrap screen, then accept the terms.
   Your account is now **platform administrator**.

**For Swift**, open [Swift](http://swift.localhost:8088), reuse your login or create one, and
retrieve its own token with the same command using `-n fred-swift`.
Swift has teams, without Weaver's organization → team → project hierarchy.

### 6. Import the demo

Use the prepared bundles in this repository: `demo/weaver-v5-demo.zip` or
`demo/swift-v3-demo.zip`. No Fred checkout or bundle generation is needed.

- **Weaver:** **Admin → Provisioning** → select `weaver-v5-demo.zip` → import → wait for success.
- **Swift:** **Admin → Migration** → select `swift-v3-demo.zip` → import → wait for success.

**All done!** Sign out of `admin`, then sign in as `alice` or `bob`, password
`Azerty123_`, and accept that account's terms. Explore Fred, configure an assistant
and start a conversation. On Weaver, Alice manages Acme; Bob works in Research.

### Everyday commands

| Action | Command |
| --- | --- |
| Stop, keeping data | `make k3d-stop` |
| Resume | `make k3d-start` |
| Update Fred | Repeat your step 4 command |
| Check health | `make k3d-health` |
| Delete the cluster and all its data, including Swift and Weaver | `make k3d-wipe` |

After a wipe, repeat steps 2–6. Local certificates are retained and restored.

Optional: [Deploy and register an organization's evaluator](docs/APPLICATIONS.md) ·
[Benchmarks and diagnostic traces](docs/BENCHMARKS.md).

## Docker

This development workflow runs the infrastructure in Docker Compose and the Fred
processes on your machine. It requires a Fred checkout.

### 1. Prerequisites

Install Docker with Compose, Make, Bash, jq, curl, Rust, uv and Node, using the
versions required by your Fred checkout. Use the `/etc/hosts` entry above.
If k3d is running, stop it first with `make k3d-stop`.

### 2. Start Weaver

From this repository, set the model keys you use, then start the infrastructure
and prepare your checkout:

```bash
export MISTRAL_API_KEY='your-mistral-key'
export OPENAI_API_KEY='your-openai-key'
make docker-up
make docker-prepare DIR=~/Work/weaver/fred
make -C ~/Work/weaver/fred run
```

`docker-prepare` prints the bootstrap token. Open [Fred](http://localhost:5173),
register, enter that token and accept the terms. Import `weaver-v5-demo.zip` through
**Admin → Provisioning**, then sign in as `alice` or `bob` / `Azerty123_`.

**For Swift**, stop the running Fred processes, run `make docker-stop`, then
`make docker-swift-up` and `make -C ~/Work/swift/fred run` with a configured Swift
checkout. [Swift host configuration](docker/README.md).
Docker runs one line at a time; use k3d to run both side by side.

### Everyday commands

| Action | Weaver | Swift |
| --- | --- | --- |
| Stop infrastructure, keeping data | `make docker-stop` | `make docker-stop` |
| Resume infrastructure | `make docker-start` | `make docker-swift-start` |
| Start Fred processes | `make -C ~/Work/weaver/fred run` | `make -C ~/Work/swift/fred run` |

## Technical reference

Only for troubleshooting or maintaining the installation:
[Infrastructure and TLS](docs/LOCAL-DEVELOPMENT.md) ·
[Swift/Weaver boundaries](docs/SWIFT-WEAVER.md) ·
[Deployment configuration](docs/HOW-IT-WORKS.md).
