# Weaver applications

An application is a separate product (its own chart, images and database) that Fred Weaver
shows inside a team. This page installs the evaluator, `fred-agent-evaluator`, and makes it
visible. Start with a working [k3d installation](../README.md#k3d), Weaver deployed and its
bootstrap done. Run commands from this repository.

## 1. Deploy the evaluator

The judge and the analysis use Mistral: `fred-model-credentials` in `fred-weaver` must hold
`MISTRAL_API_KEY` ([installation step 3](../README.md#3-set-your-model-api-keys)).

```bash
make k3d-app FRED=weaver APP=fred-evaluator \
  DIR=~/Work/common/fred-agent-evaluator \
  FRED_LIBS=local FRED_REPO=~/Work/weaver/fred
```

`DIR` builds the API, worker and UI images from the checkout. Weaver's Fred libraries are not
published yet: `FRED_LIBS=local FRED_REPO=...` builds them from your Fred checkout. The
infrastructure already provides the `evaluation` database, its credentials and the worker's
Keycloak client. Check the pods, then print the values to register:

```bash
kubectl --context k3d-fred -n fred-weaver get pods | grep fred-evaluator
helm --kube-context k3d-fred -n fred-weaver get notes fred-evaluator
```

Do not run a Swift and a Weaver evaluator at the same time: they share the `evaluation` database.

## 2. Make it visible in Fred

Fred stores the registration in its database. No Fred values, redeployment or restart.

**As the platform administrator — Administration → Applications → Register application.**
Copy the fields from the chart notes:

| Field | Value |
| --- | --- |
| Application key | `evaluation` |
| Name | `Evaluation` (French: `Évaluation`) |
| Version | `1.3.0` (the notes give the deployed one) |
| Icon | `fact_check` |
| Internal UI destination | `http://fred-evaluator-ui.fred-weaver.svc.cluster.local:8080/apps/evaluation/` |
| Internal API destination | `http://fred-evaluator-api.fred-weaver.svc.cluster.local:8336/` |
| Permission required | **Run evaluations** |

A new registration is disabled. Check the destinations, then turn on **Enabled on the platform**.

**As the organization Owner — select the organization, then Administration → Features → Apps.**
Turn on **Enabled for all** for Evaluation, or choose teams with **Manage by team**.

**Optional, as the team Owner — Settings → Tools and applications.** Only to restrict a team
below its organization; by default a team follows its organization.

**Each person** needs the **Owner** or **Analyst** role in the team; an Editor or Member is
refused. The app then appears under the team's **Apps**. Personal spaces never show applications.
Enabling an application grants no access to business data.

## Update or remove

Redeploy with the same `make k3d-app` command after a change in the evaluator checkout. When
its version changes, edit the registration's **Version** in Administration → Applications.

```bash
make k3d-app-uninstall FRED=weaver APP=fred-evaluator DIR=~/Work/common/fred-agent-evaluator
```

Uninstalling leaves the registration: disable it in Administration → Applications first.
