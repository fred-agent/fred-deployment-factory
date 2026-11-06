# Fred Deployment Factory

Run Fred on your machine. Swift and Weaver can run side by side.

Run every command from this directory.

## 1. Prepare your machine (once)

Install Docker, k3d, kubectl, Helm and Helmfile. To deploy a checkout, also install its build tools.

Add this line to `/etc/hosts`:

```text
127.0.0.1 keycloak swift.localhost weaver.localhost
```

If Docker Compose is running, stop it: `make docker-stop`.

## 2. Start the infrastructure

```bash
make k3d-up
```

## 3. Deploy Fred

### I want Swift

Give it your Mistral API key, stored in a file that contains only the key (once per cluster):

```bash
kubectl --context k3d-fred -n fred-swift create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/key-file
```

Then choose one:

| I want | Run |
| --- | --- |
| The default release | `make k3d-app FRED=swift APP=fred` |
| A specific release | `make k3d-app FRED=swift APP=fred RELEASE=3.10.0` |
| My checkout | `make k3d-app FRED=swift APP=fred DIR=/absolute/path/to/fred` |

Open <http://swift.localhost:8088>.

### I want Weaver

Give it your Mistral API key, stored in a file that contains only the key (once per cluster):

```bash
kubectl --context k3d-fred -n fred-weaver create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/key-file
```

Then deploy your checkout (Weaver has no published release yet):

```bash
make k3d-app FRED=weaver APP=fred DIR=/absolute/path/to/fred
```

Open <http://weaver.localhost:8088>.

## 4. Log in the first time

1. Open the address above. **Not `localhost:8088`: it answers 404.**
2. Sign in, or register your administrator account.
3. Fred asks for a bootstrap token. Get it with:

```bash
# Swift
kubectl --context k3d-fred -n fred-swift get secret fred-secrets \
  -o jsonpath="{.data.CONTROL_PLANE_BOOTSTRAP_TOKEN}" | base64 -d; echo

# Weaver
kubectl --context k3d-fred -n fred-weaver get secret fred-secrets \
  -o jsonpath="{.data.CONTROL_PLANE_BOOTSTRAP_TOKEN}" | base64 -d; echo
```

Done.

## Everyday commands

`<line>` is `swift` or `weaver`. On Weaver, `make k3d-app-validate` and
`make k3d-app-uninstall` also need `DIR=/absolute/path/to/fred`.

| I want to | Run |
| --- | --- |
| Redeploy Fred | The same `make k3d-app` command again |
| Update the infrastructure | `make k3d-up` |
| Pause, keeping my data | `make k3d-stop` |
| Resume | `make k3d-start` |
| See what is running | `make k3d-status` |
| Find out what is wrong | `make k3d-health` |
| Check the infrastructure without deploying | `make k3d-validate` |
| Check Fred without deploying | `make k3d-app-validate FRED=<line> APP=fred` |
| Remove Fred from a line | `make k3d-app-uninstall FRED=<line> APP=fred` |
| Add the evaluator (Swift only) | `make k3d-app FRED=swift APP=fred-evaluator` |
| Add the WebDAV knowledge base (Swift only) | `make k3d-app FRED=swift APP=webdav-kb` |
| Add my own values | Add `VALUES=/path/to/values.yaml` to the command |
| **Start over: deletes all accounts, documents and keys** | **`make k3d-wipe`**, then go back to step 2 |

## If something goes wrong

| You see | Do this |
| --- | --- |
| `404 page not found` on `localhost:8088` | Open <http://swift.localhost:8088> or <http://weaver.localhost:8088> |
| `namespaces "fred-swift" not found` | Run `make k3d-up` first |
| The deployment stops because `fred-model-credentials` is missing | Create the key, see step 3 |
| `FRED is set in your shell` | Run `unset FRED` |
| `is not a checkout of Fred` | `DIR` and `FRED` do not match: use a Swift checkout with `FRED=swift`, a Weaver one with `FRED=weaver` |
| `make k3d-up` refuses a cluster with a namespace `fred` | It is an old cluster: save what you need, run `make k3d-wipe`, then `make k3d-up` |
| Helm reports another operation in progress | `helm --kube-context k3d-fred -n <namespace> rollback <release>` |

## Understand

- [How it works](docs/HOW-IT-WORKS.md): what `FRED` selects, what `make k3d-up` prepares, every option
- [Swift and Weaver side by side](docs/SWIFT-WEAVER.md): what is isolated, what is shared
- [Technical reference](docs/LOCAL-DEVELOPMENT.md): application contract, tests, retained Docker tools
