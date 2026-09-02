# RHCL version pin (1.3.x) — install guardrails and downgrade

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md).
> See [Phase 3](../phases/03-operators-rhoai.md) and [MaaS troubleshooting](maas-troubleshooting.md).

## Why pin?

RHOAI 3.4 + MaaS is validated against **Red Hat Connectivity Link (RHCL) 1.3.x**.
**RHCL 1.4.0+** has a known Wasm shim regression that can break Authorino on MaaS gateways
(`AUTH_FAILURE`, HTTP 500 on API keys).

The Subscription in `gitops/operators/connectivity-link/operator.yaml` sets:

- `startingCSV: rhcl-operator.v1.3.6`
- `installPlanApproval: Manual`

**Important:** `startingCSV` only selects the *initial* install target. On channel `stable`,
OLM still proposes **upgrade** InstallPlans to the channel head (currently 1.4.x). Approving
those plans upgrades RHCL even though `startingCSV` still shows `1.3.6` in the spec.

## Safe InstallPlan approval (Phase 3)

**Never** bulk-approve every pending InstallPlan in `openshift-operators`.

Use the guard script instead:

```bash
# List pending plans and whether each is safe to approve
./scripts/approve-rhcl-installplan.sh

# Approve only RHCL / Kuadrant-stack plans that stay on 1.3.x
./scripts/approve-rhcl-installplan.sh --approve
```

After approval, verify:

```bash
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
# RHCL must be rhcl-operator.v1.3.6 (or another 1.3.x CSV), NOT 1.4.x
```

Re-run `./scripts/check-operators.sh` — it warns if RHCL is above 1.3.x.

### What the script rejects

- Any InstallPlan that installs `rhcl-operator.v1.4.x` or higher
- Kuadrant-stack CSVs (`authorino-operator`, `limitador-operator`, `dns-operator`) at **1.4.x**
  when pinning the 1.3.x line

### What assistants must not do

- `oc get installplan ... | xargs oc patch ... approved:true` across all operators
- Auto-approve every Manual InstallPlan during Phase 3 without reading CSV names

Other operators (COO, Tempo, etc.) have their own namespaces and pinned versions — approve those
**individually** per their phase guide, not via a global openshift-operators loop.

---

## Downgrade procedure (1.4.x → 1.3.6)

> **Impact:** MaaS auth and rate limiting stop working until Kuadrant operands and
> Phase 6 Authorino TLS are re-verified. Schedule a maintenance window.

### 1. Record current state

```bash
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
oc get subscription -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
./scripts/approve-rhcl-installplan.sh
```

### 2. Remove Kuadrant operands (keeps CRDs)

```bash
oc delete kuadrant kuadrant -n kuadrant-system --wait=true --ignore-not-found=true
oc get pods -n kuadrant-system
```

### 3. Remove 1.4.x operator subscriptions and CSVs

OLM-created dependency subscriptions must be deleted with RHCL, or they will pull 1.4.x again.

```bash
NS=openshift-operators

for sub in \
  rhcl-operator \
  authorino-operator-stable-redhat-operators-openshift-marketplace \
  limitador-operator-stable-redhat-operators-openshift-marketplace \
  dns-operator-stable-redhat-operators-openshift-marketplace
do
  oc delete subscription "$sub" -n "$NS" --ignore-not-found=true
done

for csv in \
  rhcl-operator.v1.4.2 \
  authorino-operator.v1.4.2 \
  limitador-operator.v1.4.1 \
  dns-operator.v1.4.1
do
  oc delete csv "$csv" -n "$NS" --ignore-not-found=true
done
```

Adjust CSV names if your cluster installed a different 1.4.x build.

### 4. Re-apply the pinned subscription

```bash
oc apply -k gitops/operators/connectivity-link
./scripts/approve-rhcl-installplan.sh
./scripts/approve-rhcl-installplan.sh --approve
```

If a **1.4.x** plan appears, **do not approve it**. Delete the plan or fix the subscription;
see troubleshooting below.

### 5. Wait for 1.3.6 CSVs

```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv/rhcl-operator.v1.3.6 -n openshift-operators --timeout=600s

oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
```

Expect RHCL **1.3.6** and Kuadrant dependency operators at **1.3.x** (exact builds depend on catalog).

### 6. Restore Kuadrant CR and re-check MaaS

```bash
helm template gitops/instance/maas/connectivity-link \
  --name-template maas-connectivity-link | oc apply -f -

oc get pods -n kuadrant-system
oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m || true
```

If MaaS is already deployed, **re-run Phase 6 Step 4** (Authorino TLS + gateway annotation)
and verify:

```bash
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
```

Then repeat the MaaS smoke test (API key HTTP 201, model call HTTP 200).

### 7. Block future 1.4.x upgrades

Whenever OLM creates a pending InstallPlan:

```bash
./scripts/approve-rhcl-installplan.sh
# REJECT lines for rhcl-operator.v1.4.x are expected — leave them unapproved
```

---

## Troubleshooting

| Symptom | Cause | Action |
|---------|-------|--------|
| `startingCSV: 1.3.6` but `installedCSV: 1.4.2` | Upgrade InstallPlan was approved | Follow downgrade procedure above |
| Pending plan only offers 1.4.2 | Channel head is 1.4.x | Delete CSVs/subscriptions; re-apply pin; approve only via script |
| MaaS 500 after downgrade | Authorino TLS / EnvoyFilter stale | Re-run Phase 6 Step 4; restart `odh-model-controller` if needed |
| `check-operators.sh` RHCL WARN | Installed version > 1.3.x | Downgrade or accept risk for lab-only demos |

## References

- Subscription pin: `gitops/operators/connectivity-link/operator.yaml`
- Phase 3 install: [docs/phases/03-operators-rhoai.md](../phases/03-operators-rhoai.md)
- Phase 7 RHOAI upgrade (keep RHCL pinned): [docs/phases/07-rhoai-upgrade.md](../phases/07-rhoai-upgrade.md)
- MaaS auth: [maas-troubleshooting.md](maas-troubleshooting.md)
