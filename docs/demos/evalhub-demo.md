# EvalHub Demo (Level 1) — First Evaluation Run

> **Goal:** Run a first end-to-end EvalHub evaluation in a dedicated namespace (`evalhub-demo`) with clear validation and cleanup.
>
> **Scope in this document:** **Level 1 only** (core flow).  
> After this is validated together, proceed with:
>
> - Level 2: CI/CD gate + OCI immutable artifacts
> - Level 3: Kueue scaling + protected production model auth

This demo is intentionally practical and educational: you will install/check prerequisites, run one evaluation, inspect results, and clean up safely.

---

## Figure 1 — EvalHub architecture

Figure 1 illustrates the EvalHub architecture referenced in the upstream article.

Figure 1: The EvalHub service orchestrates evaluation jobs by managing data in PostgreSQL and tracking experiment runs in MLflow.

---



## 0) Demo variables

```bash
export EVALHUB_NS=evalhub-demo
export EVALHUB_NAME=evalhub
export EVALHUB_CLIENT_SA=evalhub-demo-client
export EVAL_COLLECTION_NAME=demo-general-assistant-v1
export EVALHUB_PWD=changeme   # PostgreSQL user password + EvalHub db-url secret
export MAAS_API_KEY=REPLACE_ME   # MaaS API key for protected model endpoint (Phase 6)
```

---



## 1) Hard prerequisites check

Run this block first. It produces a **GO/NO-GO** decision and tells you exactly what to do next.

```bash
echo "=== Cluster access ==="
oc whoami
oc version | rg 'Client Version|Server Version'

missing=0

echo
echo "=== Check 1: TrustyAI/EvalHub CRDs ==="
if oc get crd | rg -qi 'trustyai|evalhub'; then
  echo "PASS: Found TrustyAI/EvalHub CRDs"
else
  echo "FAIL: Missing TrustyAI/EvalHub CRDs"
  missing=$((missing+1))
fi

echo
echo "=== Check 2: EvalHub CR exists ==="
if oc get evalhub -A >/tmp/evalhub-crs.txt 2>/dev/null && [[ -s /tmp/evalhub-crs.txt ]]; then
  echo "PASS: EvalHub CR(s) found"
  cat /tmp/evalhub-crs.txt
else
  echo "FAIL: No EvalHub CR found"
  missing=$((missing+1))
fi

echo
echo "=== Check 3: EvalHub service endpoint exists ==="
if oc get svc -A | rg -qi 'evalhub|trustyai'; then
  echo "PASS: Found candidate EvalHub/TrustyAI service(s)"
  oc get svc -A | rg -i 'evalhub|trustyai'
else
  echo "FAIL: No EvalHub/TrustyAI service found"
  missing=$((missing+1))
fi

echo
echo "=== Check 4: MLflow service presence ==="
if oc get svc -A | rg -qi 'mlflow'; then
  echo "PASS: Found MLflow service(s)"
  oc get svc -A | rg -i 'mlflow'
else
  echo "FAIL: No MLflow service found"
  missing=$((missing+1))
fi

echo
if [[ "$missing" -eq 0 ]]; then
  echo "GO: Prerequisites satisfied. Skip Section 2 and continue with Section 3."
else
  echo "NO-GO: ${missing} prerequisite check(s) failed."
  echo "Proceed to Section 2: Install missing prerequisites."
fi
```

**Gate rule to proceed with Level 1:**

- `EvalHub` CRD exists.
- PostgreSQL is running in `${EVALHUB_NS}` (Section 2.2).
- At least one `EvalHub` instance is running.
- EvalHub service reachable in-cluster.
- MLflow endpoint reachable by EvalHub (or configured during install).

---



## 2) Install missing prerequisites (if checks fail)

> The product docs place EvalHub under TrustyAI on OpenShift AI 3.4.  
> TrustyAI is managed by the Red Hat OpenShift AI operator via `DataScienceCluster`.



### 2.0 Preferred path on OpenShift AI 3.4: check TrustyAI in DSC

```bash
oc get dsc default-dsc -n redhat-ods-operator -o jsonpath='{.spec.components.trustyai.managementState}{"\n"}'
```

If TrustyAI is not managed, patch DSC first:

```bash
oc patch datasciencecluster default-dsc -n redhat-ods-operator --type=merge -p '{
  "spec": {
    "components": {
      "trustyai": {
        "managementState": "Managed"
      }
    }
  }
}'
```

Verify TrustyAI reconciliation:

```bash
# Must print: Managed
oc get dsc default-dsc -n redhat-ods-operator -o jsonpath='{.spec.components.trustyai.managementState}{"\n"}'

# Wait for TrustyAI operator deployment and pod readiness
echo "Wait for TrustyAI operator deployment and pod readiness"
oc wait --for=condition=Available deployment/trustyai-service-operator-controller-manager \
  -n redhat-ods-applications --timeout=300s
oc get pods -n redhat-ods-applications | rg 'trustyai-service-operator-controller-manager'
```

Only proceed when:

- `managementState` is `Managed`
- `trustyai-service-operator-controller-manager` is `Running`



### 2.1 Create EvalHub project

Let's create a dedicated project for this demo to keep EvalHub isolated from llm-d demo resources. On OpenShift, prefer `oc new-project` over `oc create namespace` — it creates the project, sets your current context, and applies default SCCs.

```bash
oc new-project "${EVALHUB_NS}" 2>/dev/null || oc project "${EVALHUB_NS}"

# Register the namespace as an EvalHub tenant (label value is intentionally empty).
oc label namespace "${EVALHUB_NS}" evalhub.trustyai.opendatahub.io/tenant= --overwrite
```



### 2.2 Deploy PostgreSQL (EvalHub backing store)

EvalHub requires PostgreSQL. Deploy a single-instance database in `${EVALHUB_NS}` using the same dev/test chart as MaaS (not intended for production).

`EVALHUB_PWD` from Section 0 is used for the database user password. The chart creates a bootstrap Secret for the PostgreSQL pod; EvalHub reads a separate Secret with a `db-url` key in the next step.

```bash
helm template evalhub-database ./gitops/instance/maas/database \
  --namespace "${EVALHUB_NS}" \
  --set db.name=evalhub \
  --set db.user=evalhub \
  --set db.password="${EVALHUB_PWD}" \
  --set db.service.name=postgresql \
  --set db.secretName=postgresql-init \
  | oc apply -f -

oc wait --for=condition=ready pod -l app=postgresql \
  -n "${EVALHUB_NS}" --timeout=120s

oc get pods,svc -n "${EVALHUB_NS}" | rg -i postgresql
```



### 2.3 Create EvalHub database secret and `EvalHub` CR

Create a Secret containing the PostgreSQL connection string. The Secret must contain a `db-url` key with a valid PostgreSQL connection URI pointing at the in-cluster service from Section 2.2.

Replace `MLFLOW_TRACKING_URI` with your working MLflow service. Product docs emphasize MLflow as the experiment store for EvalHub runs.

On **RHOAI 3.4** (this guide's stack), MLflow runs in `redhat-ods-applications`, not in `${EVALHUB_NS}`. The in-cluster Service listens on **8443 with HTTPS** — do not use `http://` or port `5000` (that causes `EOF` / `mlflow_request_failed` at job submit).

Verify the Service and MLflow CR address before applying:

```bash
oc get svc mlflow -n redhat-ods-applications
oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.address.url}{"\n"}'
# Expected: https://mlflow.redhat-ods-applications.svc:8443
```

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: evalhub-db-credentials
  namespace: ${EVALHUB_NS}
type: Opaque
stringData:
  db-url: "postgres://evalhub:${EVALHUB_PWD}@postgresql.${EVALHUB_NS}.svc:5432/evalhub?sslmode=disable"
EOF
```

Apply the `EvalHub` CR:

```bash
cat <<EOF | oc apply -f -
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: EvalHub
metadata:
  name: ${EVALHUB_NAME}
  namespace: ${EVALHUB_NS}
spec:
  replicas: 1
  database:
    type: postgresql
    secret: evalhub-db-credentials
  providers:
    - lm-evaluation-harness
    - garak
    - guidellm
  collections:
    - safety-and-fairness-v1
  env:
    - name: MLFLOW_TRACKING_URI
      value: "https://mlflow.redhat-ods-applications.svc:8443"
EOF
```



### 2.4 Wait for EvalHub readiness

```bash
oc wait evalhub/"${EVALHUB_NAME}" -n "${EVALHUB_NS}" \
  --for=jsonpath='{.status.ready}'=True --timeout=300s
```

When the `EvalHub` CR reports Ready, verify pods and that the operator created the Route:

```bash
oc get pods -n "${EVALHUB_NS}" -l app=eval-hub
oc wait --for=condition=ready pod -l app=eval-hub \
  -n "${EVALHUB_NS}" --timeout=300s

oc get route evalhub -n "${EVALHUB_NS}"
```

Proceed to Section 3 when the `evalhub` Route exists and pods are Ready.

---



## 3) Level 1 demo run (core path)

EvalHub is multi-tenant. Every API call **except** `/api/v1/health` requires:

- `Authorization: Bearer ${TOKEN}` — use a **ServiceAccount** token (product docs default for API/CI access)
- `X-Tenant: ${EVALHUB_NS}` — scopes the request to the tenant namespace

Create a dedicated API client ServiceAccount and grant EvalHub virtual-resource access (product docs Section 2.27):

```bash
oc create sa "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_NS}" --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-evaluator
  namespace: ${EVALHUB_NS}
rules:
  - apiGroups: ["trustyai.opendatahub.io"]
    resources: ["evaluations", "collections", "providers"]
    verbs: ["get", "list", "create", "update", "delete"]
  - apiGroups: ["mlflow.kubeflow.org"]
    resources: ["experiments"]
    verbs: ["create", "get"]
  # Required when job specs use model.auth.secret_ref (Section 3.3 Step 4): EvalHub checks
  # that the API caller can read the referenced Secret before accepting the job.
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["evalhub-model-auth"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${EVALHUB_CLIENT_SA}-access
  namespace: ${EVALHUB_NS}
subjects:
  - kind: ServiceAccount
    name: ${EVALHUB_CLIENT_SA}
    namespace: ${EVALHUB_NS}
roleRef:
  kind: Role
  name: evalhub-evaluator
  apiGroup: rbac.authorization.k8s.io
EOF

export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_NS}" --duration=24h)
```

> **Note:** `evalhub-${EVALHUB_NS}-job` is operator-provisioned for evaluation Job pods — do not reuse it for API calls. Interactive `oc whoami -t` also works, but ServiceAccount tokens match how CI/CD and automation clients authenticate.



### 3.1 Reach the EvalHub API (operator Route)

The TrustyAI operator exposes EvalHub automatically — no manual Route, Ingress, or port-forward is required. When the `EvalHub` CR is Ready, the operator creates a Route named `evalhub` in `${EVALHUB_NS}`.

Confirm the Route and note `reencrypt` termination on port `https`:

```bash
oc get route -n "${EVALHUB_NS}"
```

Example (host varies by cluster):

```text
NAME      HOST/PORT                                                    PATH   SERVICES   PORT    TERMINATION          WILDCARD
evalhub   evalhub-evalhub-demo.apps.<cluster-domain>                          evalhub    https   reencrypt/Redirect   None
```

Set the API base URL from the route host and verify health (the only **unauthenticated** endpoint):

```bash
export EVALHUB_URL="https://$(oc get route evalhub -n "${EVALHUB_NS}" -o jsonpath='{.spec.host}')"
echo "EVALHUB_URL=${EVALHUB_URL}"

curl -s "${EVALHUB_URL}/api/v1/health" | jq .
```



### 3.2 Install EvalHub CLI and list providers

At this point our evalhub project is ready, let's now install the CLI and point it at the Route, ServiceAccount token, and tenant namespace from the steps above:

```bash
pip install "eval-hub-sdk[cli]"

evalhub config set base_url "${EVALHUB_URL}"
evalhub config set token "${TOKEN}"
evalhub config set tenant "${EVALHUB_NS}"

# OpenShift reencrypt Routes can trigger Python/httpx SSL handshake errors
# (e.g. UNEXPECTED_EOF_WHILE_READING) even when curl works. For lab clusters:
evalhub config set insecure true

evalhub health

evalhub providers list
evalhub providers describe lm_evaluation_harness
```

List providers and benchmarks of a provider via REST API (optional cross-check):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" -H "X-Tenant: ${EVALHUB_NS}" \
  "${EVALHUB_URL}/api/v1/evaluations/providers" | jq .

curl -s -H "Authorization: Bearer ${TOKEN}" -H "X-Tenant: ${EVALHUB_NS}"   "${EVALHUB_URL}/api/v1/evaluations/providers/lm_evaluation_harness" | jq .benchmarks

```



### 3.3 Run an evaluation (EvalHub CLI)

> **Resume checkpoint (next session):** After the cluster is back up, re-source Section 0 vars (`cluster.env` + `EVALHUB_`*), confirm EvalHub is healthy (Sections 2.4 + 3.1–3.2: Route, `evalhub health`, `providers list`), then **start here at Section 3.3 Step 0**.

The steps below use only the EvalHub CLI. They follow product docs §2.8 (submit job), §2.10 (status/results), §2.11 (cancel/delete), §2.12–§2.13 (collections), and §2.14 (model API key auth).

Derive the MaaS model URL once:

```bash
export MAAS_GW=$(oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}')
export MAAS_MODEL_URL="https://${MAAS_GW}/llm-d-demo/qwen3-8b/v1"
```



#### Step 0 — Configure API key authentication for model endpoints

Create a Secret in the tenant namespace with your MaaS API key (product docs §2.14). EvalHub evaluation Job pods read this Secret via `model.auth.secret_ref` in the job spec.

```bash
oc create secret generic evalhub-model-auth -n "${EVALHUB_NS}" \
  --from-literal=api-key="${MAAS_API_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

oc get secret evalhub-model-auth -n "${EVALHUB_NS}" -o jsonpath='{.data}' | jq 'keys'
```

The output must include `api-key`.

If you created the Role in Section 3 **before** this rule was added, patch it in place:

```bash
oc patch role evalhub-evaluator -n "${EVALHUB_NS}" --type=json -p '[
  {"op":"add","path":"/rules/-","value":{
    "apiGroups":[""],
    "resources":["secrets"],
    "resourceNames":["evalhub-model-auth"],
    "verbs":["get"]
  }}
]'
```

Then mint a fresh token (RBAC changes apply to new tokens):

```bash
export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_NS}" --duration=24h)
evalhub config set token "${TOKEN}"
```



#### Step 1 — Describe built-in collections

The EvalHub CR (Section 2.3) loads built-in collections at startup. List them, then inspect one:

```bash
evalhub collections list
evalhub collections describe safety-and-fairness-v1
```



#### Step 2 — Create a custom collection

Create a single-benchmark collection spec file, then register it with the CLI (product docs §2.13):

```bash
cat > /tmp/evalhub-collection.yaml <<EOF
name: ${EVAL_COLLECTION_NAME}
category: demo
description: Single-benchmark starter gate for EvalHub Level 1 demo
tags:
  - demo
  - level1
pass_criteria:
  threshold: 0.5
benchmarks:
  - id: arc_easy
    provider_id: lm_evaluation_harness
    weight: 1.0
    primary_score:
      metric: inst_level_strict_acc
      lower_is_better: false
    pass_criteria:
      threshold: 0.5
EOF

evalhub collections create --file /tmp/evalhub-collection.yaml --format json | tee  /tmp/evalhub-collection-create.json
#export COLLECTION_ID=$(jq -r '.[0].resource.id' /tmp/evalhub-collection-create.json)
export COLLECTION_ID='' ##<insert value here>
```



#### Step 3 — Describe the custom collection

```bash
evalhub collections describe "${COLLECTION_ID}"
```



#### Step 4 — Submit an evaluation job

Pick **one** path below. Use the Garak quick smoke test first when you want a fast end-to-end check (~10 min timeout); use the Level 1 lm-eval job for the main demo narrative.

**Option A — Fast smoke test (Garak** `quick`**, ~minutes)**

Verifies MaaS auth, EvalHub job scheduling, and Garak adapter in one short run. No custom collection required.

```bash
evalhub eval run \
  --name garak_quick \
  --model-url "${MAAS_MODEL_URL}" \
  --model-name alibaba/qwen3-8b \
  --provider garak \
  --benchmark quick \
  --model-auth-secret evalhub-model-auth \
  --experiment evalhub-level1-demo-quick \
  --format json | tee /tmp/evalhub-garak-quick.json

export JOB_ID=$(jq -r '.[0].resource.id' /tmp/evalhub-garak-quick.json)
echo "JOB_ID=${JOB_ID}"
```

**Option B — Level 1 demo job (lm-eval** `leaderboard_ifeval`**, ~10–15 min with cap)**

Reference the custom collection and the model-auth Secret in a job spec file.

> **Demo timing:** to get an evaluation job that runs in reasonable time withing the demo we are using arc_easy as benchmark. large collections with complexe benchmarks might require several hours. 

```bash

cat > /tmp/evalhub-job.yaml <<EOF
name: evalhub-level1-demo-job
model:
  url: ${MAAS_MODEL_URL}
  # MaaS/vLLM OpenAI "model" id (LLMInferenceService spec.model.name)
  name: alibaba/qwen3-8b
  auth:
    secret_ref: evalhub-model-auth
collection:
  id: ${COLLECTION_ID}
  benchmarks:
    - id: arc_easy
      provider_id: lm_evaluation_harness
      parameters:
        # HF tokenizer id — separate from the MaaS model id above
        tokenizer: RedHatAI/Qwen3-8B-FP8-dynamic
        num_fewshot: 0
        batch_size: 1
        num_concurrent: 4
experiment:
  name: evalhub-level1-demo-exp
EOF

evalhub eval run --config /tmp/evalhub-job.yaml --format json | tee /tmp/evalhub-job-submit.json
export JOB_ID=$(jq -r '.[0].resource.id' /tmp/evalhub-job-submit.json)
echo "JOB_ID=${JOB_ID}"
```



#### Step 5 — Track job status

Option A usually finishes in **a few minutes**; Option B expect **~10–15 minutes** with `EVAL_DEMO_LIMIT=20`.

```bash
evalhub eval status "${JOB_ID}" --watch
```



#### Step 6 — Retrieve formatted results

When the job reaches `completed`:

```bash
evalhub eval results "${JOB_ID}" --format table
```



#### Step 7 — Cancel or permanently delete the job

Soft-cancel a running job (preserves the record for audit):

```bash
evalhub eval cancel "${JOB_ID}" --yes
evalhub eval status "${JOB_ID}"
```

Permanently delete the job record (cannot be undone):

```bash
evalhub eval cancel "${JOB_ID}" --hard-delete --yes
```

To remove the custom collection after the demo:

```bash
evalhub collections delete "${COLLECTION_ID}" --yes
```

---



## 4) Validation checklist (must pass)

- EvalHub CLI connects (`evalhub health` in Section 3.2).
- Built-in collection is visible (`evalhub collections describe safety-and-fairness-v1`).
- Custom collection is created and describable (`COLLECTION_ID` set).
- Job reaches `completed` within ~15 minutes using `EVAL_DEMO_LIMIT=20` (`evalhub eval status --watch`).
- Results table shows benchmark score(s) (`evalhub eval results --format table`).
- MLflow experiment URL appears in results (if MLflow is configured).

---



## 5) Troubleshooting quick fixes



### 401 Unauthorized from EvalHub API

- Mint a fresh ServiceAccount token:
`export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_NS}" --duration=24h)`
- Confirm the RoleBinding exists:
`oc get rolebinding ${EVALHUB_CLIENT_SA}-access -n "${EVALHUB_NS}"`



### 400 Bad request — missing `X-Tenant`

- Add `-H "X-Tenant: ${EVALHUB_NS}"` to every request except `/api/v1/health`



### 500 on `evalhub eval run` — not permitted to access secret `evalhub-model-auth`

EvalHub validates that the **API client** ServiceAccount (`${EVALHUB_CLIENT_SA}`) can `get` the
Secret named in `model.auth.secret_ref` **at job submit time** — before evaluation Job pods start.

- Confirm the Role includes the scoped rule from Section 3 (or run the Step 0 patch block).
- Confirm binding: `oc auth can-i get secret/evalhub-model-auth -n "${EVALHUB_NS}" --as "system:serviceaccount:${EVALHUB_NS}:${EVALHUB_CLIENT_SA}"`
— must print `yes`.
- Mint a fresh token after patching RBAC and update `evalhub config set token`.



### 401 Unauthorized from model endpoint

- Confirm `evalhub-model-auth` exists and contains the `api-key` key.
- Verify `${MAAS_API_KEY}` is valid for the MaaS route and model path.
- If using protected internal model: add RoleBinding for the evaluation job ServiceAccount to the model view role.



### 429 Too Many Requests from model endpoint

EvalHub jobs hammer the MaaS route with hundreds or thousands of inference calls. The Phase 6 example subscription (`1000` tokens / `24h`) is far too low.

- Check the active limit: `oc get maassubscription default-subscription -n models-as-a-service -o yaml | rg -A3 tokenRateLimits`
- Raise it before running evals (example for demos):

```bash
oc patch maassubscription default-subscription -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [{
      "name": "qwen3-8b",
      "namespace": "llm-d-demo",
      "tokenRateLimits": [{"window": "1h", "limit": 10000000}]
    }]
  }
}'
```

- Verify Limitador picked it up: `oc get tokenratelimitpolicy maas-trlp-qwen3-8b -n llm-d-demo -o yaml | rg -A2 'limit:|window:'`
- Cancel stuck jobs, then re-submit after the limit increase.

---



## 6) Cleanup



### 6.1 Soft cleanup (keep EvalHub installed)

Run Step 7 from Section 3.3 if you have not already, then remove local files:

```bash
evalhub eval cancel "${JOB_ID}" --hard-delete --yes 2>/dev/null || true
evalhub collections delete "${COLLECTION_ID}" --yes 2>/dev/null || true

rm -f /tmp/evalhub-collection.yaml /tmp/evalhub-collection-create.json \
      /tmp/evalhub-job.yaml /tmp/evalhub-job-submit.json

oc delete secret evalhub-model-auth -n "${EVALHUB_NS}" --ignore-not-found=true
```



### 6.2 Full cleanup (remove demo namespace/resources)

```bash
oc delete evalhub "${EVALHUB_NAME}" -n "${EVALHUB_NS}" --ignore-not-found=true
oc delete namespace "${EVALHUB_NS}" --ignore-not-found=true
```

---



## 7) What to do next

After we validate this Level 1 demo together, proceed with:

1. **Level 2:** CI/CD gate + OCI immutable artifact persistence — [evalhub-demo-level2.md](evalhub-demo-level2.md).
2. **Level 3:** Kueue queueing/preemption + protected production endpoint auth patterns.

---



## References



### Primary product docs

- [Red Hat OpenShift AI Self-Managed 3.4: Evaluating AI systems (PDF)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/pdf/evaluating_ai_systems/Red_Hat_OpenShift_AI_Self-Managed-3.4-Evaluating_AI_systems-en-US.pdf)



### EvalHub blog series

- [Part 1: How EvalHub manages two-layer Kubernetes control planes](https://developers.redhat.com/articles/2026/05/12/how-evalhub-manages-two-layer-kubernetes-control-planes)
- [Part 2: EvalHub: Because "looks good to me" isn't a benchmark](https://developers.redhat.com/articles/2026/05/19/evalhub-because-looks-good-me-isnt-benchmark)
- [Part 3: Evaluation-driven development with EvalHub](https://developers.redhat.com/articles/2026/06/02/evaluation-driven-development-evalhub)
- [Part 4: Understanding evaluation collections in EvalHub](https://developers.redhat.com/articles/2026/06/04/understanding-evaluation-collections-evalhub)
- [Part 5: Bring your own evaluation framework to EvalHub](https://developers.redhat.com/articles/2026/06/09/bring-your-own-evaluation-framework-evalhub)
- [Part 6: Add automated AI evaluations to your CI/CD pipeline](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline)
- [Part 7: Store immutable AI evaluation records with EvalHub and OCI](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)
- [Part 8: Manage LLM evaluation workloads at scale with EvalHub and Kueue](https://developers.redhat.com/articles/2026/06/18/manage-llm-evaluation-workloads-scale-evalhub-and-kueue)
- [Part 9: Connect EvalHub to protected production model servers](https://developers.redhat.com/articles/2026/06/23/connect-evalhub-protected-production-model-servers)

