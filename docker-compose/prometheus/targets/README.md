Add extra Prometheus target groups here as `*.yml` files.

When a target runs on the Docker host itself, do not use `127.0.0.1` here.
From inside the Prometheus container, `127.0.0.1` points to the container, not the host.
Use `host.docker.internal:<port>` instead, and make sure the process is reachable from the host gateway interface.
In practice, that usually means listening on `0.0.0.0`, not only on `127.0.0.1`.

Example:

```yaml
- targets:
    - app-my-service:8080
  labels:
    job: my-service
```

Current localhost example configured in this repository:

```yaml
- targets:
    - host.docker.internal:9005 # agentic-backend
    - host.docker.internal:9111 # knowledge-flow backend
  labels:
    job: localhost-metrics
```
