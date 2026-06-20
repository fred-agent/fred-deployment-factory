# Fredlab Infra Helm Chart

Minimal GKE Autopilot chart for the Fredlab playground infrastructure layer:

- PostgreSQL with a `standard-rwo` 10Gi persistent disk
- Keycloak connected to PostgreSQL
- `ClusterIP` services only
- GKE Ingress mapping `https://keycloak.fredlab.dev` to Keycloak
- Existing Google-managed certificate: `fredlab-infra-cert`

The chart intentionally has no privileged containers, no privileged initContainers,
no node-level `sysctl`, and no `chown` init job.

## Render

```bash
helm template fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

## Install

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

## Static IP

The reserved address is `8.233.26.38`, but GKE Ingress expects the GCP global
address resource name in the annotation `kubernetes.io/ingress.global-static-ip-name`.

Set it at deploy time when you know the resource name:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set ingress.staticIpName=<gcp-global-address-resource-name>
```

## Secrets

The chart is safe to commit: `values.yaml` contains no password.

Keep the real playground credentials in:

```text
helm/fredlab-infra/fredlab-secrets.values.yaml
```

That file is ignored by Git. A committed template is available at:

```text
helm/fredlab-infra/fredlab-secrets.values.example.yaml
```

If the secrets file is missing, Helm rendering fails instead of deploying empty
passwords.
