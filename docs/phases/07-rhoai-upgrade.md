# Phase 7 — RHOAI 3.5 Upgrade (RHCL pinned)

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.
> See also: [RHCL version pin](../reference/rhcl-version-pin.md) |
> [MaaS Troubleshooting](../reference/maas-troubleshooting.md)

**Goal:** Upgrade the Red Hat OpenShift AI operator from **3.4.0** (installed in Phase 3) to **3.5.x**, while **keeping RHCL pinned to 1.3.x**. Required before [EvalHub demos](../demos/evalhub-demo.md) and other RHOAI 3.5-only features.

**When to run:** After [Phase 6](06-maas.md) by default — validate the full llm-d + MaaS stack on 3.4.0 first, then upgrade. An early upgrade after Phase 3 is possible but skips MaaS validation on 3.4; not recommended.

---

## Pre-flight

Confirm Phases 0–6 are complete and the cluster is healthy:

```bash
# RHOAI operator and instance
oc get csv -n redhat-ods-operator | grep rhods-operator
oc get dsc default-dsc -o jsonpath='{.status.phase}{"\n"}'

# RHCL must still be 1.3.x — do not proceed if already on 1.4.x without downgrade
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
./scripts/check-operators.sh

# MaaS baseline (recommended before upgrade)
oc get gateway maas-default-gateway -n openshift-ingress
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
oc get llminferenceservice -A
```

**Human gate (pre-upgrade):** `default-dsc` is `Ready`, RHCL CSV is **1.3.x**, and the Phase 6 MaaS smoke test passed (API key HTTP 201, model call HTTP 200).

---

## Step 1 — Discover the 3.5.x CSV

Query the catalog in your cluster region — CSV names can differ slightly by build:

```bash
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\t"}{.currentCSV}{"\n"}{end}' \
  | grep -E '^stable'
```

Set the target (example — use the CSV from the command above):

```bash
export RHOAI_TARGET_CSV=rhods-operator.3.5.0
echo "Target: ${RHOAI_TARGET_CSV}"
```

> **Repo pin (optional, for reproducibility):** After a successful upgrade, update
> `gitops/operators/rhoai/values.yaml` preset `stable.startingCSV` to match
> `${RHOAI_TARGET_CSV}` so future greenfield installs start on 3.5.x.

---

## Step 2 — Patch the RHOAI subscription

Phase 3 installed the operator with `installPlanApproval: Manual`. Patch the subscription to target 3.5.x:

```bash
oc patch subscription rhods-operator -n redhat-ods-operator --type merge -p "{
  \"spec\": {
    \"installPlanApproval\": \"Manual\",
    \"startingCSV\": \"${RHOAI_TARGET_CSV}\"
  }
}"
```

List pending InstallPlans in the RHOAI namespace:

```bash
oc get installplan -n redhat-ods-operator
```

Approve **only** the InstallPlan that installs `${RHOAI_TARGET_CSV}`:

```bash
# Replace <installplan-name> with the plan that lists rhods-operator.3.5.x
oc patch installplan <installplan-name> -n redhat-ods-operator \
  --type merge -p '{"spec":{"approved":true}}'
```

Wait for the new CSV:

```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  "csv/${RHOAI_TARGET_CSV}" -n redhat-ods-operator --timeout=600s

oc get csv -n redhat-ods-operator | grep rhods-operator
```

---

## Step 3 — Guard RHCL during the upgrade (critical)

RHOAI upgrades often trigger **pending RHCL 1.4.x InstallPlans** in `openshift-operators`.
**Do not bulk-approve** openshift-operators plans.

```bash
./scripts/approve-rhcl-installplan.sh
# REJECT lines for rhcl-operator.v1.4.x — leave those InstallPlans unapproved

./scripts/approve-rhcl-installplan.sh --approve
# Approves only safe 1.3.x RHCL/Kuadrant-stack plans
```

Verify RHCL stayed on 1.3.x:

```bash
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
./scripts/check-operators.sh
# RHCL line must show OK (1.3.x), not WARN
```

If RHCL jumped to 1.4.x, stop and follow [RHCL downgrade](../reference/rhcl-version-pin.md) before continuing.

---

## Step 4 — Wait for DataScienceCluster reconcile

The RHOAI operator upgrades operand images and reconciles `default-dsc`:

```bash
oc wait --for=jsonpath='{.status.phase}'=Ready \
  dsc/default-dsc --timeout=900s

oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'

# Controller pods should return to Running
oc get pods -n redhat-ods-applications | grep -E 'odh-model-controller|maas-controller|maas-api'
```

If `default-dsc` is stuck `Not Ready` on `modelsasservice`, see [Phase 6 troubleshooting](06-maas.md#troubleshooting) — the gateway and database must still exist from Phase 6.

---

## Step 5 — Post-upgrade verification

### 5a — MLflow tracking URI (RHOAI 3.5)

RHOAI 3.5 requires the `/mlflow` path suffix in tracking URIs (EvalHub, notebooks):

```bash
oc get mlflow mlflow -n redhat-ods-applications \
  -o jsonpath='{.status.address.url}{"\n"}'
# Expect: https://mlflow.redhat-ods-applications.svc:8443/mlflow
```

### 5b — MaaS smoke test

Re-run the Phase 6 smoke test to confirm MaaS survived the operator upgrade:

```bash
export MAAS_GW=$(oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}')
export MAAS_MODEL_URL="https://${MAAS_GW}/v1/qwen3-8b"   # adjust model path if needed

# Mint a short-lived key (replace <htpasswd-user> / <password> from Phase 6)
export MAAS_API_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -u '<htpasswd-user>:<password>' \
  -H 'Content-Type: application/json' \
  -d '{"name":"post-upgrade-check","expiresInDays":1}' | jq -r '.key // .apiKey')

curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer ${MAAS_API_KEY}" \
  "${MAAS_MODEL_URL}/models"
# Expect: 200
```

If API keys return **500** or **AUTH_FAILURE**, re-check Authorino TLS and Kuadrant:

```bash
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
oc get kuadrant kuadrant -n kuadrant-system
```

See [MaaS troubleshooting](../reference/maas-troubleshooting.md) and [Phase 6 Step 4](06-maas.md#step-4--authorino-tls-for-maas).

### 5c — Dashboard

Open the OpenShift AI dashboard (`rh-ai.apps.<cluster-domain>`). Confirm Gen AI Studio and MaaS tabs load. Known 3.5 limitation: the embedded MLflow tab may 404 on webpack chunks while **Launch MLflow** (`/mlflow`) works — EvalHub jobs use the in-cluster URI and are unaffected.

---

## Step 6 — Optional: enable TrustyAI (EvalHub prerequisite)

EvalHub demos require TrustyAI. Enable via the instance chart and re-apply:

```bash
helm template rhoai ./gitops/instance/rhoai \
  --set trustyai=true | oc apply -f -

oc wait --for=condition=Available trustyaiservice/trustyai-service \
  -n redhat-ods-applications --timeout=600s 2>/dev/null || \
oc get pods -n redhat-ods-applications -l app=trustyai-service
```

Then follow [EvalHub Demo (Level 1)](../demos/evalhub-demo.md).

---

## Troubleshooting

| Symptom | Cause | Action |
|---------|-------|--------|
| RHCL at 1.4.x after upgrade | RHCL 1.4.x InstallPlan approved | [RHCL downgrade](../reference/rhcl-version-pin.md); re-run Phase 6 Step 4 |
| `default-dsc` Not Ready | Operand rollout in progress or MaaS deps missing | Wait; check `oc describe dsc`; verify gateway + `maas-db-config` |
| MaaS 500 on API keys post-upgrade | Authorino TLS / EnvoyFilter stale | Re-run Phase 6 Step 4; restart `odh-model-controller` if needed |
| Pending RHCL 1.4.x only | Channel head is 1.4.x | **Leave unapproved** — pin is intentional |
| EvalHub MLflow 404 at job submit | URI missing `/mlflow` suffix | Use full `status.address.url` from MLflow CR (Step 5a) |

---

**End of Phase 7:** Stop here and report upgrade results to the user:

1. RHOAI CSV version (`rhods-operator.3.5.x` `Succeeded`)
2. RHCL still 1.3.x (`check-operators.sh` OK)
3. `default-dsc` `Ready`
4. MaaS smoke test HTTP 201 + 200

Optional next steps: [EvalHub Demo](../demos/evalhub-demo.md), [MaaS Demo](../demos/maas-demo.md), or ArgoCD (OpenShift GitOps).
