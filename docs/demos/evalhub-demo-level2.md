# EvalHub Demo (Level 2) — CI/CD Gate + OCI Immutable Artifacts

> **Goal:** Turn the Level 1 EvalHub setup into an automated **quality gate** and persist **tamper-evident evaluation evidence** as OCI artifacts.
>
> **Prerequisites:** Complete [EvalHub Demo (Level 1)](evalhub-demo.md) first — EvalHub running in `evalhub-demo`, CLI configured, MaaS model auth working, and at least one successful evaluation job.
>
> **Scope in this document:** **Level 2 only** (pipeline gate + OCI export). After validation, proceed with:
>
> - Level 3: Kueue scaling + protected production model auth ([Part 8](https://developers.redhat.com/articles/2026/06/18/manage-llm-evaluation-workloads-scale-evalhub-and-kueue), [Part 9](https://developers.redhat.com/articles/2026/06/23/connect-evalhub-protected-production-model-servers))

This demo follows [Part 6: Add automated AI evaluations to your CI/CD pipeline](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline) and [Part 7: Store immutable AI evaluation records with EvalHub and OCI](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci).

**Conceptual flow:**

```
CI trigger → evalhub eval run --wait → pass/fail gate
                    ↓ (on success)
              OCI push (content-addressed digest)
                    ↓
         artifact ref stored in deployment record / SBOM
```

MLflow remains the **queryable** experiment store; OCI adds **immutable, digest-verified** evidence for audits.

---

## 0) Demo variables

Re-source Level 1 variables, then add Level 2 settings:

```bash
# From Level 1 (adjust if your names differ)
export EVALHUB_NS=evalhub-demo
export EVALHUB_CLIENT_SA=evalhub-demo-client
export MAAS_API_KEY=REPLACE_ME

# MaaS model endpoint (same as Level 1 Section 3.3)
export MAAS_GW=$(oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}')
export MAAS_MODEL_URL="https://${MAAS_GW}/llm-d-demo/qwen3-8b/v1"

# Level 2 — gate collection and CI metadata
export GATE_COLLECTION_NAME=demo-ci-gate-v1
export GATE_JOB_NAME=qwen3-8b-pr-gate
export GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "local-demo")
export PR_NUMBER=${PR_NUMBER:-demo}

# Level 2 — OCI export target (OpenShift internal registry; see Section 2)
export OCI_HOST=image-registry.openshift-image-registry.svc:5000
export OCI_REPOSITORY=${EVALHUB_NS}/eval-results
export OCI_CONNECTION_SECRET=evalhub-oci-push

# EvalHub API (reconnect CLI if needed)
export EVALHUB_URL="https://$(oc get route evalhub -n "${EVALHUB_NS}" -o jsonpath='{.spec.host}')"
export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_NS}" --duration=24h)
evalhub config set base_url "${EVALHUB_URL}"
evalhub config set token "${TOKEN}"
evalhub config set tenant "${EVALHUB_NS}"
evalhub config set insecure true   # lab clusters with reencrypt Routes
```

---

## 1) Hard prerequisites check

```bash
echo "=== Level 1 baseline ==="
evalhub health
oc get evalhub -n "${EVALHUB_NS}"
oc get secret evalhub-model-auth -n "${EVALHUB_NS}" >/dev/null && echo "PASS: model auth secret" || echo "FAIL: evalhub-model-auth missing"

echo
echo "=== Level 2: OCI registry ==="
oc get svc image-registry -n openshift-image-registry >/dev/null && echo "PASS: internal registry Service" || echo "FAIL: no image-registry Service"
oc get imagestream -n "${EVALHUB_NS}" eval-results >/dev/null 2>&1 && echo "PASS: eval-results ImageStream" || echo "WARN: eval-results ImageStream not created yet (Section 2)"

echo
echo "=== Level 2: evaluation job ServiceAccount ==="
oc get sa evalhub-${EVALHUB_NS}-job -n "${EVALHUB_NS}" >/dev/null && echo "PASS: job SA exists" || echo "FAIL: job SA missing"
```

**Gate rule to proceed:**

- Level 1 EvalHub instance is Ready and `evalhub health` succeeds.
- `evalhub-model-auth` Secret exists and the API client SA can submit jobs.
- OpenShift internal image registry is available (`managementState: Managed`).
- You can create an ImageStream in `${EVALHUB_NS}` for evaluation artifacts.

---

## 2) Prepare the OCI artifact registry

EvalHub pushes results at job completion when `exports.oci` is set in the job spec ([Part 7](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)). In Kubernetes mode, the adapter uses a sidecar that authenticates with the Secret named in `exports.oci.k8s.connection`.

### 2.1 Create an ImageStream (OpenShift internal registry)

```bash
oc project "${EVALHUB_NS}"
oc create imagestream eval-results --dry-run=client -o yaml | oc apply -f -
```

Artifacts land at references like:

```text
image-registry.openshift-image-registry.svc:5000/evalhub-demo/eval-results:evalhub-<tag>@sha256:<digest>
```

The **digest** is the tamper-evident fingerprint; the tag is human-navigable indexing.

> **Alternative:** Use an external registry (for example `quay.io/my-org/eval-results`) by changing `OCI_HOST` and `OCI_REPOSITORY`. The `exports.oci` block structure is identical; only credentials and push RBAC differ.

### 2.2 Create registry push credentials

Create a `kubernetes.io/dockerconfigjson` Secret the evaluation job sidecar can use:

```bash
JOB_SA="evalhub-${EVALHUB_NS}-job"

# Allow the job ServiceAccount to push to ImageStreams in this namespace
oc policy add-role-to-user system:image-builder "system:serviceaccount:${EVALHUB_NS}:${JOB_SA}" -n "${EVALHUB_NS}"

oc create secret docker-registry "${OCI_CONNECTION_SECRET}" \
  --docker-server="${OCI_HOST}" \
  --docker-username="system:serviceaccount:${EVALHUB_NS}:${JOB_SA}" \
  --docker-password="$(oc create token "${JOB_SA}" -n "${EVALHUB_NS}" --duration=8760h)" \
  -n "${EVALHUB_NS}" \
  --dry-run=client -o yaml | oc apply -f -
```

Grant the job ServiceAccount permission to read the Secret (EvalHub mounts it by name at job runtime):

```bash
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-oci-push-reader
  namespace: ${EVALHUB_NS}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["${OCI_CONNECTION_SECRET}"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-oci-push-reader
  namespace: ${EVALHUB_NS}
subjects:
  - kind: ServiceAccount
    name: ${JOB_SA}
    namespace: ${EVALHUB_NS}
roleRef:
  kind: Role
  name: evalhub-oci-push-reader
  apiGroup: rbac.authorization.k8s.io
EOF

oc auth can-i get secret/${OCI_CONNECTION_SECRET} -n "${EVALHUB_NS}" \
  --as "system:serviceaccount:${EVALHUB_NS}:${JOB_SA}"
# Expected: yes
```

---

## 3) Create a gate collection (pass/fail criteria)

A **collection** with `pass_criteria` is the EvalHub-native quality gate ([Part 4](https://developers.redhat.com/articles/2026/06/04/understanding-evaluation-collections-evalhub)). When scores fall below the threshold, the job fails and `evalhub eval run --wait` exits non-zero — blocking your pipeline ([Part 6](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline)).

Pick **one** collection below. Option A is recommended for Level 2 because it finishes in minutes and is ideal for pipeline gates.

### Option A — Fast CI gate (Garak `quick`, recommended)

```bash
cat > /tmp/evalhub-gate-collection.yaml <<EOF
name: ${GATE_COLLECTION_NAME}
category: ci-gate
description: Pre-merge quality gate for qwen3-8b on MaaS (Level 2 demo)
tags:
  - demo
  - level2
  - ci-gate
pass_criteria:
  threshold: 0.0
benchmarks:
  - id: quick
    provider_id: garak
    weight: 1.0
EOF

evalhub collections create --file /tmp/evalhub-gate-collection.yaml --format json \
  | tee /tmp/evalhub-gate-collection-create.json
export GATE_COLLECTION_ID=$(jq -r '.[0].resource.id' /tmp/evalhub-gate-collection-create.json)
echo "GATE_COLLECTION_ID=${GATE_COLLECTION_ID}"
```

### Option B — Accuracy gate (lm-eval `leaderboard_ifeval`, capped)

Use this when you want the same benchmark narrative as Level 1, but keep runtime pipeline-friendly.

> **Important:** The lm-eval adapter reads **`num_examples`** on the job spec (top-level), not `parameters.limit`. The Level 1 field `parameters.limit` is stored in the job JSON but **ignored** by the adapter — progress will show `N/541` instead of `N/20`. For capped lm-eval gates, prefer Garak for Level 2 or confirm `Examples limit:` in adapter startup logs before relying on a cap.

```bash
export GATE_DEMO_EXAMPLES=20

cat > /tmp/evalhub-gate-collection.yaml <<EOF
name: ${GATE_COLLECTION_NAME}
category: ci-gate
description: IFEval accuracy gate for qwen3-8b (capped for CI)
tags:
  - demo
  - level2
  - ci-gate
pass_criteria:
  threshold: 0.5
benchmarks:
  - id: leaderboard_ifeval
    provider_id: lm_evaluation_harness
    weight: 1.0
    primary_score:
      metric: inst_level_strict_acc
      lower_is_better: false
    pass_criteria:
      threshold: 0.5
    parameters:
      num_examples: ${GATE_DEMO_EXAMPLES}
      tokenizer: RedHatAI/Qwen3-8B-FP8-dynamic
      num_fewshot: 0
      batch_size: 1
      num_concurrent: 4
      gen_kwargs:
        max_gen_toks: 256
        do_sample: false
EOF

evalhub collections create --file /tmp/evalhub-gate-collection.yaml --format json \
  | tee /tmp/evalhub-gate-collection-create.json
export GATE_COLLECTION_ID=$(jq -r '.[0].resource.id' /tmp/evalhub-gate-collection-create.json)
```

Verify the collection and threshold:

```bash
evalhub collections describe "${GATE_COLLECTION_ID}"
```

---

## 4) Define the gate job spec (`eval-gate.yaml`)

Commit-friendly job spec combining the gate collection, model auth, MLflow experiment tags, and OCI export ([Part 7](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)).

```bash
cat > /tmp/eval-gate.yaml <<EOF
name: ${GATE_JOB_NAME}
description: Pre-merge evaluation gate with OCI artifact export (Level 2 demo)

model:
  url: ${MAAS_MODEL_URL}
  name: alibaba/qwen3-8b
  auth:
    secret_ref: evalhub-model-auth

collection:
  id: ${GATE_COLLECTION_ID}

experiment:
  name: evalhub-level2-ci-gate
  tags:
    - key: environment
      value: staging
    - key: trigger
      value: pre-merge
    - key: git-commit
      value: "${GIT_COMMIT}"
    - key: pr-number
      value: "${PR_NUMBER}"

exports:
  oci:
    coordinates:
      oci_host: "${OCI_HOST}"
      oci_repository: "${OCI_REPOSITORY}"
      annotations:
        environment: staging
        git-commit: "${GIT_COMMIT}"
        pr-number: "${PR_NUMBER}"
        collection: "${GATE_COLLECTION_NAME}"
    k8s:
      connection: "${OCI_CONNECTION_SECRET}"
EOF
```

Inspect the rendered spec:

```bash
cat /tmp/eval-gate.yaml
```

---

## 5) Run the CI/CD gate locally (shell script)

This script mirrors [Part 6](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline): health check → submit → wait → capture results → record OCI reference.

Save as `scripts/evalhub-gate.sh` (or run inline):

```bash
cat > /tmp/evalhub-gate.sh <<'SCRIPT'
#!/usr/bin/env bash
# evalhub-gate.sh — Submit an EvalHub evaluation and gate on the result.
set -euo pipefail

EVAL_CONFIG="${1:-/tmp/eval-gate.yaml}"
TIMEOUT="${2:-3600}"
RESULTS_JSON="${3:-/tmp/evalhub-gate-results.json}"

: "${EVALHUB_URL:?Set EVALHUB_URL or evalhub config}"
: "${TOKEN:?Set TOKEN or evalhub config}"

echo "==> Checking EvalHub connectivity"
evalhub health

echo "==> Submitting evaluation gate: ${EVAL_CONFIG}"
JOB_ID=$(evalhub eval run --config "${EVAL_CONFIG}" --format json | jq -r '.[0].resource.id // .[0].id')
echo "    Job ID: ${JOB_ID}"

echo "==> Waiting for completion (timeout: ${TIMEOUT}s)"
if ! evalhub eval status "${JOB_ID}" --watch --poll-interval 15; then
  echo "==> GATE FAILED (job did not complete successfully)"
  exit 1
fi

echo "==> Fetching results"
evalhub eval results "${JOB_ID}" --format json | tee "${RESULTS_JSON}"
evalhub eval results "${JOB_ID}" --format table

# OCI artifact reference (field name varies by API version)
ARTIFACT_REF=$(jq -r '
  .[0].artifacts.oci_reference //
  .[0].artifacts.oci_ref //
  .[0].oci_artifact.oci_ref //
  empty
' "${RESULTS_JSON}")

if [[ -n "${ARTIFACT_REF}" && "${ARTIFACT_REF}" != "null" ]]; then
  echo "==> OCI artifact: ${ARTIFACT_REF}"
  echo "${ARTIFACT_REF}" > /tmp/evalhub-gate-artifact.ref
else
  echo "WARN: No OCI artifact reference in results — check adapter logs and registry push RBAC"
  exit 1
fi

echo "==> GATE PASSED"
SCRIPT

chmod +x /tmp/evalhub-gate.sh
```

Run the gate (prefer `--wait` on a single submission):

```bash
evalhub health

evalhub eval run --config /tmp/eval-gate.yaml --wait --timeout 3600 \
  --format json | tee /tmp/evalhub-gate-submit.json

export JOB_ID=$(jq -r '.[0].resource.id // .[0].id' /tmp/evalhub-gate-submit.json)
echo "JOB_ID=${JOB_ID}"

evalhub eval results "${JOB_ID}" --format json | tee /tmp/evalhub-gate-results.json
evalhub eval results "${JOB_ID}" --format table

export ARTIFACT_REF=$(jq -r '
  .[0].artifacts.oci_reference //
  .[0].artifacts.oci_ref //
  .[0].oci_artifact.oci_ref //
  empty
' /tmp/evalhub-gate-results.json)
echo "ARTIFACT_REF=${ARTIFACT_REF}"
```

**Pipeline semantics ([Part 6](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline)):**

| Exit code | Meaning |
|---|---|
| `0` | Job completed; gate passed |
| `1` | Job failed (benchmark error or collection gate threshold not met) |
| `2` | Timeout waiting for completion |

In CI, set `EVALHUB_BASE_URL`, `EVALHUB_TOKEN`, and `EVALHUB_TENANT` from your secret store instead of a config file ([Part 6 environment variable table](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline)).

---

## 6) Verify the immutable OCI artifact

### 6.1 Confirm digest in EvalHub results

```bash
jq -r '.[0].artifacts // .[0].oci_artifact // .' /tmp/evalhub-gate-results.json

evalhub eval status "${JOB_ID}" --format json | jq '.[0].results // .results'
```

Expected: a pullable `oci_ref` and a `sha256:` digest written alongside the MLflow run ([Part 7](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)).

### 6.2 Pull and inspect with ORAS (from a machine with registry access)

Install [ORAS](https://oras.land/) on your workstation, log in to the registry, then pull by digest:

```bash
# External pull requires registry route or port-forward; example with port-forward:
oc port-forward -n openshift-image-registry svc/image-registry 5000:5000 &
sleep 2

oras pull "${ARTIFACT_REF}" --output /tmp/evalhub-retrieved

# List files in the artifact
find /tmp/evalhub-retrieved -type f
```

The digest check proves integrity: if file contents were altered after push, the digest would no longer match ([Part 7 verification steps](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)).

### 6.3 Record the reference in your deployment audit trail

Store `ARTIFACT_REF` in the change record that approved model promotion:

```bash
cat <<EOF | tee /tmp/evalhub-gate-audit-record.txt
git-commit: ${GIT_COMMIT}
pr-number: ${PR_NUMBER}
evalhub-job: ${JOB_ID}
oci-artifact: ${ARTIFACT_REF}
model: alibaba/qwen3-8b
maas-url: ${MAAS_MODEL_URL}
EOF
```

This closes the provenance chain: **evaluation run → MLflow experiment (queryable) → OCI artifact (immutable)** ([Part 7](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)).

---

## 7) Wire into CI/CD (examples)

These examples adapt [Part 6](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline) and [Part 7](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci) to this demo's variables.

### 7.1 GitHub Actions (outline)

```yaml
# .github/workflows/model-eval-gate.yaml
name: Model Evaluation Gate

on:
  pull_request:
    paths:
      - 'gitops/instance/llm-d/**'
      - 'prompts/**'
      - 'eval-gate.yaml'

jobs:
  evaluate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install EvalHub CLI
        run: pip install "eval-hub-sdk[cli]"

      - name: Run evaluation gate with OCI export
        env:
          EVALHUB_BASE_URL: ${{ secrets.EVALHUB_BASE_URL }}
          EVALHUB_TOKEN: ${{ secrets.EVALHUB_TOKEN }}
          EVALHUB_TENANT: evalhub-demo
        run: |
          evalhub health
          sed -i "s/\${GIT_COMMIT}/${{ github.sha }}/g" eval-gate.yaml
          sed -i "s/\${PR_NUMBER}/${{ github.event.number }}/g" eval-gate.yaml
          evalhub eval run --config eval-gate.yaml --wait --timeout 3600

      - name: Capture immutable artifact reference
        if: success()
        env:
          EVALHUB_BASE_URL: ${{ secrets.EVALHUB_BASE_URL }}
          EVALHUB_TOKEN: ${{ secrets.EVALHUB_TOKEN }}
          EVALHUB_TENANT: evalhub-demo
        run: |
          JOB_ID=$(evalhub eval status --status completed --since 1h --format json \
            | jq -r '.[0].resource.id')
          ARTIFACT_REF=$(evalhub eval results "$JOB_ID" --format json \
            | jq -r '.[0].artifacts.oci_reference // .[0].oci_artifact.oci_ref')
          echo "EVAL_ARTIFACT_REF=$ARTIFACT_REF" >> "$GITHUB_ENV"
          echo "Evaluation artifact: $ARTIFACT_REF"
```

### 7.2 OpenShift Pipelines / Tekton task (outline)

Run the same `evalhub eval run --config eval-gate.yaml --wait` inside a cluster Task, mounting the ServiceAccount token as `EVALHUB_TOKEN`. Store `ARTIFACT_REF` in a Tekton result or a ConfigMap for the release pipeline to consume before promoting a model tier.

> **Tip:** Keep `eval-gate.yaml` in Git and substitute `${GIT_COMMIT}` / `${PR_NUMBER}` at pipeline runtime so OCI annotations link evidence to the source revision ([Part 7 pipeline integration](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)).

---

## 8) Validation checklist (must pass)

- [ ] Gate collection registered (`evalhub collections describe "${GATE_COLLECTION_ID}"`).
- [ ] `evalhub eval run --config /tmp/eval-gate.yaml --wait` exits `0` on a passing model.
- [ ] `evalhub eval results "${JOB_ID}" --format json` includes an OCI artifact reference with `sha256:` digest.
- [ ] ImageStream `eval-results` in `${EVALHUB_NS}` shows a new tag after the job completes.
- [ ] `ARTIFACT_REF` saved to `/tmp/evalhub-gate-audit-record.txt` (or your change-management system).
- [ ] Deliberately lower `pass_criteria.threshold` above the observed score and confirm the gate fails (exit code `1`).

---

## 9) Troubleshooting

### Gate job completes but no OCI artifact reference

- Confirm `exports.oci` is present in `/tmp/eval-gate.yaml`.
- Check adapter logs for OCI push errors:

```bash
POD=$(oc get pods -n "${EVALHUB_NS}" -l job-id="${JOB_ID}" -o jsonpath='{.items[0].metadata.name}')
oc logs "${POD}" -n "${EVALHUB_NS}" -c adapter | rg -i 'oci|oras|push|digest|error'
oc logs "${POD}" -n "${EVALHUB_NS}" -c oci-proxy 2>/dev/null || oc logs "${POD}" -n "${EVALHUB_NS}" --all-containers | rg -i oci
```

- Verify job SA can read the push Secret (Section 2.2).
- Verify `system:image-builder` role on `${EVALHUB_NS}` for `evalhub-${EVALHUB_NS}-job`.

### `401` / `403` pushing to internal registry

- Recreate `${OCI_CONNECTION_SECRET}` with a fresh token (`oc create token ...`).
- Confirm `OCI_HOST` matches the in-cluster Service (`image-registry.openshift-image-registry.svc:5000`), not an external hostname, for pods pushing from inside the cluster.

### `--wait` exits `1` but metrics look acceptable

- Collection-level and benchmark-level `pass_criteria` both apply — inspect which threshold failed:

```bash
evalhub eval status "${JOB_ID}" --format json | jq '.[0].status // .status'
evalhub eval results "${JOB_ID}" --format json | jq '.[0].metrics'
```

- For lm-eval gates, confirm adapter startup shows `Examples limit: 20` (not `None`) if you capped examples.

### MaaS rate limits during gate runs

See Level 1 Section 5 (`429 Too Many Requests`) — raise token rate limits before running uncapped lm-eval gates.

---

## 10) Cleanup

```bash
evalhub eval cancel "${JOB_ID}" --hard-delete --yes 2>/dev/null || true
evalhub collections delete "${GATE_COLLECTION_ID}" --yes 2>/dev/null || true

oc delete secret "${OCI_CONNECTION_SECRET}" -n "${EVALHUB_NS}" --ignore-not-found=true
oc delete role evalhub-oci-push-reader -n "${EVALHUB_NS}" --ignore-not-found=true
oc delete rolebinding evalhub-job-oci-push-reader -n "${EVALHUB_NS}" --ignore-not-found=true

rm -f /tmp/evalhub-gate-collection.yaml /tmp/evalhub-gate-collection-create.json \
      /tmp/eval-gate.yaml /tmp/evalhub-gate-submit.json \
      /tmp/evalhub-gate-results.json /tmp/evalhub-gate-artifact.ref \
      /tmp/evalhub-gate-audit-record.txt
```

To remove pushed artifacts from the internal registry, delete the corresponding tag from the `eval-results` ImageStream in the OpenShift console or with `oc delete istag`.

---

## 11) What to do next

After validating Level 2:

1. **Level 3:** Kueue queueing/preemption + protected production endpoint auth — see [Part 8](https://developers.redhat.com/articles/2026/06/18/manage-llm-evaluation-workloads-scale-evalhub-and-kueue) and [Part 9](https://developers.redhat.com/articles/2026/06/23/connect-evalhub-protected-production-model-servers).

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
- [Part 6: Add automated AI evaluations to your CI/CD pipeline](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline) — **Level 2 primary**
- [Part 7: Store immutable AI evaluation records with EvalHub and OCI](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci) — **Level 2 primary**
- [Part 8: Manage LLM evaluation workloads at scale with EvalHub and Kueue](https://developers.redhat.com/articles/2026/06/18/manage-llm-evaluation-workloads-scale-evalhub-and-kueue)
- [Part 9: Connect EvalHub to protected production model servers](https://developers.redhat.com/articles/2026/06/23/connect-evalhub-protected-production-model-servers)

### Related demo docs

- [EvalHub Demo (Level 1)](evalhub-demo.md)
