# Fred Deployment Factory

Run Fred on your machine, from this directory. Pick one:

- **k3d**: Fred deployed as in production. Swift and Weaver side by side.
- **Docker Compose**: Weaver only, run from your checkout. The fast loop to debug.

They use the same ports: run only one at a time.

Once: install Docker (and for k3d: k3d, kubectl, Helm, Helmfile) and your checkout's build
tools, add `127.0.0.1 keycloak swift.localhost weaver.localhost` to `/etc/hosts`, and keep
your Mistral key in a file that contains only the key.

## k3d

```bash
make k3d-up
kubectl --context k3d-fred -n fred-<line> create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/path/to/key-file            # once per line: swift or weaver
make k3d-app FRED=weaver APP=fred DIR=/path/to/fred       # Weaver: your checkout
make k3d-app FRED=swift APP=fred                          # Swift: the published release
```

Open <http://weaver.localhost:8088> or <http://swift.localhost:8088>.

| I want to | Run |
| --- | --- |
| Redeploy Fred | The same `make k3d-app` again |
| Pause / resume | `make k3d-stop` / `make k3d-start` |
| Find out what is wrong | `make k3d-health` |
| **Start over (deletes everything)** | **`make k3d-wipe`**, then `make k3d-up` |

## Docker Compose

```bash
make docker-up
make docker-app FRED=weaver APP=fred DIR=/path/to/fred KEY_FILE=/path/to/key-file
```

Open <http://localhost:5173>.

| I want to | Run |
| --- | --- |
| Restart Fred | The same `make docker-app` again (`KEY_FILE` only to change the key) |
| Pause / resume | `make docker-stop` / `make docker-start` |
| **Start over (deletes everything)** | **`make docker-wipe`**, then `make docker-up` |

## First login

Both `make k3d-app` and `make docker-app` print how to read the bootstrap token. Then
follow Fred's [first start](https://github.com/ThalesGroup/fred/blob/weaver/deploy/k3d/README.md#first-start):
platform admin, demo bundle, models, first answer from documents.

## More

- [How it works](docs/HOW-IT-WORKS.md): every k3d option (`RELEASE`, `VALUES`, other applications)
- [Swift and Weaver side by side](docs/SWIFT-WEAVER.md): what is isolated, what is shared
- [Technical reference](docs/LOCAL-DEVELOPMENT.md): Docker Compose details, tests, identity providers
