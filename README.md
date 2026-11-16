# Fred Deployment Factory

Install and run **Fred Weaver locally with k3d**. Run the commands below from this
repository. Replace `/path/to/weaver/fred` with your Weaver checkout.

## k3d

### Install and run Weaver

**1. Prepare your machine.** Install Docker, k3d, kubectl, Helm, Helmfile, Make,
Python 3 and the checkout's build prerequisites. Have a Weaver checkout available.
Add this entry to `/etc/hosts`:

```text
127.0.0.1 keycloak app-keycloak weaver.localhost
```

Export your Mistral API key (the default model provider):

```bash
export MISTRAL_API_KEY=your-key
```

**2. Start the infrastructure.** If Docker Compose is running, stop it first with
`make docker-stop`.

```bash
make k3d-up
```

On the first installation, complete the one-time
[OpenSearch HTTPS preparation](docs/LOCAL-DEVELOPMENT.md#new-installation-renewal-and-rollback)
before deploying Weaver. An installation already configured for HTTPS reuses its
saved configuration automatically.

**3. Deploy Weaver.** This builds and installs your checkout; the first build can
take several minutes.

```bash
make k3d-app FRED=weaver APP=fred DIR=/path/to/weaver/fred
```

**4. Open [Weaver](http://weaver.localhost:8088).** Register your account, use the
bootstrap-token command printed by deployment, paste the token when asked, and
accept the terms. Continue with Fred's
[first start](https://github.com/ThalesGroup/fred/blob/weaver/deploy/k3d/README.md#first-start)
to add example data and configure your first assistant.

| I want to | Run |
| --- | --- |
| Pause, keeping data | `make k3d-stop` |
| Resume, including after a reboot | `make k3d-start` |
| Deploy updated Weaver code | Repeat the `make k3d-app FRED=weaver ...` command above |
| Diagnose a problem | `make k3d-health` |

### Advanced: Swift and Weaver side by side

For Fred developers comparing the two versions. Add Swift to the existing cluster
using the [side-by-side guide](docs/SWIFT-WEAVER.md). Installing Swift is optional;
Weaver works on its own.

### Advanced: concurrency benchmarks

For developers testing parallel requests and contention. Follow the
[benchmark guide](docs/BENCHMARKS.md) to deploy the shared mock, connect the model
and prepare the load client. `BENCH=reference` opts into the versioned mock setup;
the guide covers first installation and full redeployment. This is separate from
normal Weaver installation.

## Other workflows and reference

- [Docker Compose](docs/LOCAL-DEVELOPMENT.md#docker-compose-quickstart): run Fred processes on the host for debugging.
- [How it works](docs/HOW-IT-WORKS.md): model-provider options, deployment settings and data lifecycle.
- [Technical reference](docs/LOCAL-DEVELOPMENT.md): TLS, infrastructure and diagnostics.
