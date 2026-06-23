# RFC 0001 — Protect admin UIs with Google sign-in (IAP)

- **Status:** Proposed
- **Date:** 2026-06-23
- **Authors:** Dimitri Tombroff (with Claude Code)
- **Executor (Google-side setup):** Sebastien Ehling
- **Scope:** `helm/fredlab-infra` — admin web UIs exposed through the GKE Ingress

---

## 1. Problem

Fred's operational/admin web UIs need to be reachable as **normal browser URLs** so the
team can easily monitor and operate the platform:

- **Temporal UI** — already exposed today.
- **OpenSearch Dashboards** — planned (not deployed yet).
- (Keycloak admin console — special case, see §7.)

Today the Temporal UI is meant to sit behind a Cloud Armor IP allowlist
(`fredlab-admin-ui-allowlist`), but **the policy is never created by any script** and the
`adminAccess.allowedOperatorCidrs` values are empty placeholders. The Keycloak admin
console is currently **publicly reachable**, protected only by the bootstrap admin
password.

We want a **cloud-native, identity-based** front door: open the URL, sign in with a
`@fredlab.dev` Google account, done. We explicitly do **not** want IP allowlists or
`kubectl port-forward` as the operating model.

## 2. Decision

Use **Google Cloud Identity-Aware Proxy (IAP)** in front of the admin backends, on the
**GKE Ingress HTTPS load balancer that already exists**. IAP presents a Google login and
authorises access via IAM (`roles/iap.httpsResourceAccessor`) granted to `@fredlab.dev`
identities (ideally a Google group).

This is viable because `fredlab.dev` is a **Google Workspace organization**
(org ID `1091253924600`, customer `C03zrbjym`), so the OAuth consent screen can be set to
**Internal** — only `@fredlab.dev` accounts can authenticate.

## 3. Why IAP (and not the alternatives)

| Approach | Identity model | Operating model | Verdict |
| --- | --- | --- | --- |
| **IAP** | Google `@fredlab.dev` account (+ MFA, audit logs) | Browser URL + Google sign-in | ✅ Chosen |
| Cloud Armor IP allowlist | Source IP address | Browser URL, but breaks on dynamic IPs; no per-user identity | ❌ Rejected |
| `kubectl port-forward` | Cluster RBAC | Terminal tunnel each time; not a real URL | ❌ Rejected |

Cost note: IAP attaches to the **existing** global HTTPS load balancer created by the
Ingress. It adds **no new load balancer** and IAP itself has no extra service charge —
the LB cost is already incurred today regardless.

## 4. Architecture

```
Browser ──HTTPS──▶ [existing GKE Ingress LB]
                        │
            ┌───────────┴────────────┐
            ▼                         ▼
   BackendConfig (IAP on)     BackendConfig (no IAP)
   Temporal UI / OS Dash       Fred frontend (public app)
            │
            ▼
   IAP: "Sign in with Google" → IAM check
        (roles/iap.httpsResourceAccessor on @fredlab.dev group)
```

IAP is enabled per-backend via the GKE `BackendConfig` CRD
(`spec.iap.enabled: true` + an OAuth client secret). The public Fred frontend backend is
**not** wrapped in IAP and stays public.

## 5. Responsibility split (keeps the cluster reproducible)

The Google-console / `gcloud` identity setup is inherently one-time and cannot live in the
Helm chart. The cluster wiring stays in code.

- **Sebastien (Google-side, one-time):** enable IAP API, configure the Internal OAuth
  consent screen, create the OAuth client, grant the `@fredlab.dev` group access. Hands
  the **OAuth Client ID + secret** back to Dimitri.
- **Dimitri / chart (in code, reproducible):** store the client ID/secret as a Kubernetes
  secret, enable `iap` on the Temporal UI `BackendConfig`, reuse the same pattern for
  OpenSearch Dashboards when added.

## 6. Runbook — Google-side setup (Sebastien)

> Replace `<PROJECT_ID>` with the GCP project ID. `<BRAND_NAME>` is printed by the brand
> step.

1. **Enable the IAP API**
   ```bash
   gcloud services enable iap.googleapis.com --project=<PROJECT_ID>
   ```

2. **Configure the OAuth consent screen as Internal**
   Console → APIs & Services → OAuth consent screen → **User type: Internal** →
   app name `Fredlab Admin`, support email = a `@fredlab.dev` address.
   (Internal = only `@fredlab.dev` accounts can authenticate.)

3. **Create the OAuth client for IAP**
   ```bash
   # Brand (skip if one already exists):
   gcloud iap oauth-brands create \
     --application_title="Fredlab Admin" \
     --support_email=sebastien.ehling@fredlab.dev \
     --project=<PROJECT_ID>

   # OAuth client (record the Client ID + secret it returns):
   gcloud iap oauth-clients create <BRAND_NAME> \
     --display_name="Fredlab IAP" \
     --project=<PROJECT_ID>
   ```
   → **Send the `Client ID` + `Client secret` to Dimitri securely** (they get wired into
   the Helm chart, not committed to Git).

4. **Grant who may access the admin UIs**
   Preferred: a Google group (e.g. `fred-admins@fredlab.dev`) containing Dimitri, Simon,
   Sebastien.
   ```bash
   gcloud projects add-iam-policy-binding <PROJECT_ID> \
     --member="group:fred-admins@fredlab.dev" \
     --role="roles/iap.httpsResourceAccessor"
   ```
   (Can be scoped per backend-service later; project-level is fine to start.)

## 7. Keycloak — explicitly out of scope here

Keycloak's hostname serves **both** the public OIDC login (every end user needs it) **and**
the admin console. IAP guards a whole backend, so it cannot protect "only `/admin`" on that
single hostname. Keycloak admin protection is deferred to a separate RFC; options on the
table are: split the admin console onto its own hostname/backend and IAP that, or a
path-scoped rule. **Not part of this change.**

## 8. Out of scope / non-goals

- ❌ `kubectl port-forward` as the operating model.
- ❌ IP allowlists / Cloud Armor for these UIs.
- ❌ Protecting the public Fred frontend (it must stay public).
- ❌ Keycloak admin console (separate RFC).

## 9. Follow-ups once §6 is done

- [ ] Store OAuth client ID/secret as a Kubernetes secret (chart).
- [ ] Add `spec.iap` to the Temporal UI `BackendConfig` referencing that secret.
- [ ] Remove the dead `adminAccess.allowedOperatorCidrs` placeholders (Cloud Armor path
      abandoned for admin UIs).
- [ ] Document the same IAP opt-in for OpenSearch Dashboards when that backend is added.
