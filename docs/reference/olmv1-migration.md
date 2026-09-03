# OLMv1 on OCP 4.21+ — Operator Install Method

> Part of the [llm-d-guide](../../README.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full install sequence.

## Background

OpenShift Container Platform 4.21 introduces **OLMv1** (Operator Lifecycle Manager v1) as the default operator management system. OLMv0 (the classic `Subscription` + `InstallPlan` + `CSV` flow) remains fully supported through the OCP 4 lifecycle but is deprecated.

This guide supports both:
- **OCP 4.20** — OLMv0 (`operator.yaml` / Helm with default values)
- **OCP 4.21+** — OLMv1 (`cluster-extension.yaml` / Helm with `--set olmVersion=v1`)

## Key Differences

| Aspect | OLMv0 (OCP 4.20) | OLMv1 (OCP 4.21+) |
|---|---|---|
| Install API | `Subscription` + `InstallPlan` + `CSV` + `OperatorGroup` | `ClusterExtension` (single resource) |
| API group | `operators.coreos.com/v1alpha1` | `olm.operatorframework.io/v1` |
| Scope | Namespace or cluster-scoped | Always cluster-scoped |
| Security model | Automatic broad permissions | Explicit `ServiceAccount` + `ClusterRoleBinding` |
| Catalog resource | `CatalogSource` (in `openshift-marketplace`) | `ClusterCatalog` (cluster-scoped) |
| Version control | `startingCSV` pin | Semver ranges, channel selection |
| Approval | `installPlanApproval: Manual/Automatic` | Continuous reconciliation (no InstallPlan) |
| Wait condition | `CSV` phase = `Succeeded` | `ClusterExtension` condition `Installed = True` |

## ClusterExtension Anatomy

A `ClusterExtension` replaces four OLMv0 resources (`Subscription`, `InstallPlan`, `CSV`, `OperatorGroup`) with one:

```yaml
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: nfd
spec:
  namespace: openshift-nfd                    # where operator pods run
  serviceAccount:
    name: nfd-installer                       # pre-created SA with RBAC
  source:
    sourceType: Catalog
    catalog:
      packageName: nfd                        # same as OLMv0 Subscription .spec.name
      channels:                               # optional — omit to use default channel
      - stable
  install:
    preflight:
      crdUpgradeSafety:
        disabled: false                       # safety check for CRD schema changes
```

### Required Supporting Resources

Unlike OLMv0, OLMv1 does **not** auto-grant permissions. Each operator needs:

1. **Namespace** — same as before (unchanged)
2. **ServiceAccount** — pre-created in the operator namespace
3. **ClusterRoleBinding** — binds the SA to a `ClusterRole` with sufficient permissions

This guide uses `cluster-admin` for the SA, which matches the effective permissions OLMv0 auto-grants. Production environments should scope the RBAC to the specific resources each operator manages.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfd-installer
  namespace: openshift-nfd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nfd-installer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: nfd-installer
  namespace: openshift-nfd
```

## Catalog Mapping

OLMv1 uses `ClusterCatalog` resources instead of `CatalogSource`. The default catalogs on OCP 4.21:

| OLMv0 `CatalogSource` | OLMv1 `ClusterCatalog` | Operators |
|---|---|---|
| `redhat-operators` | `openshift-redhat-operators` | NFD, RHCL, Tempo, OTel, COO, RHOAI, cert-manager, LWS |
| `certified-operators` | `openshift-certified-operators` | NVIDIA GPU Operator |

The `ClusterExtension` does not explicitly reference a catalog — the OLMv1 resolver finds the package across all active `ClusterCatalog` resources automatically.

## How This Guide Handles Both Paths

### Detecting the OCP Version

```bash
OCP_MINOR=$(oc version -o json | jq -r '.openshiftVersion' | cut -d. -f2)
```

This is auto-derived at Phase 0 and determines the install method for all subsequent phases.

### Plain-YAML Operators

Each operator directory contains both files:

```
gitops/operators/<operator>/
  operator.yaml              # OLMv0 — Namespace + OperatorGroup + Subscription
  cluster-extension.yaml     # OLMv1 — Namespace + ServiceAccount + ClusterRoleBinding + ClusterExtension
```

Apply the correct file based on OCP version:

```bash
# OCP 4.20 (OLMv0):
oc apply -f gitops/operators/<operator>/operator.yaml

# OCP 4.21+ (OLMv1):
oc apply -f gitops/operators/<operator>/cluster-extension.yaml
```

### Helm Charts (cert-manager, RHOAI)

Pass `--set olmVersion=v1` on OCP 4.21+:

```bash
# OCP 4.20 (OLMv0) — default:
helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -

# OCP 4.21+ (OLMv1):
helm template rhoai-operator ./gitops/operators/rhoai --set olmVersion=v1 | oc apply -f -
```

The Helm chart renders either a `Subscription` + `OperatorGroup` (v0) or a `ServiceAccount` + `ClusterRoleBinding` + `ClusterExtension` (v1) based on this value.

### install.sh Scripts (NFD, NVIDIA)

The `install.sh` scripts for NFD and NVIDIA auto-detect the OCP version:

```bash
./gitops/operators/nfd/install.sh      # auto-detects 4.20 vs 4.21+
./gitops/operators/nvidia/install.sh   # auto-detects 4.20 vs 4.21+
```

On 4.20, they query `packagemanifest` for the channel/CSV and apply `operator.yaml`. On 4.21+, they apply `cluster-extension.yaml` directly (channel resolution is handled by the OLMv1 resolver).

## Wait Conditions

The wait condition after installing an operator differs between OLMv0 and OLMv1:

```bash
# OCP 4.20 — wait for CSV:
oc get csv -n <namespace> -w
# Look for: phase = Succeeded

# OCP 4.21+ — wait for ClusterExtension:
oc get clusterextension <name> -w
# Look for: Installed condition = True
```

Programmatic check for OLMv1:

```bash
oc wait --for=condition=Installed clusterextension/<name> --timeout=300s
```

## Operator Reference

| Operator | Package Name | ClusterExtension Name | Namespace | File |
|---|---|---|---|---|
| cert-manager | `openshift-cert-manager-operator` | `openshift-cert-manager-operator` | `cert-manager-operator` | Helm (`--set olmVersion=v1`) |
| NFD | `nfd` | `nfd` | `openshift-nfd` | `cluster-extension.yaml` |
| NVIDIA GPU | `gpu-operator-certified` | `gpu-operator-certified` | `nvidia-gpu-operator` | `cluster-extension.yaml` |
| Connectivity Link | `rhcl-operator` | `rhcl-operator` | `openshift-operators` | `cluster-extension.yaml` |
| LeaderWorkerSet | `leader-worker-set` | `leader-worker-set` | `openshift-lws-operator` | `cluster-extension.yaml` |
| Tempo | `tempo-product` | `tempo-product` | `openshift-tempo-operator` | `cluster-extension.yaml` |
| OpenTelemetry | `opentelemetry-product` | `opentelemetry-product` | `openshift-opentelemetry-operator` | `cluster-extension.yaml` |
| COO | `cluster-observability-operator` | `cluster-observability-operator` | `openshift-cluster-observability-operator` | `cluster-extension.yaml` |
| RHOAI | `rhods-operator` | `rhods-operator` | `redhat-ods-operator` | Helm (`--set olmVersion=v1`) |

## Forward-Looking: OCP 4.22+

Red Hat has indicated that the Marketplace `CatalogSource` resources (used by OLMv0) may be removed in OCP 4.22. When that happens:

- All `packagemanifest` lookups will stop working
- `Subscription`-based installs will no longer resolve packages
- Migration to `ClusterExtension` CRs will be mandatory

This guide's OLMv1 path (`cluster-extension.yaml` files and `--set olmVersion=v1`) is forward-compatible with that change. The OLMv0 path (`operator.yaml`) will require removal in a future guide update.

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| `ClusterExtension` stuck in `Progressing` | ServiceAccount missing or insufficient RBAC | Verify SA exists and has `cluster-admin` binding |
| `no package found` error | ClusterCatalog not available or package name mismatch | `oc get clustercatalog` — all should show `Available`; verify `packageName` matches the catalog entry |
| Both `Subscription` and `ClusterExtension` exist for same operator | Mixed install — one blocks the other | Delete the one you don't want; never manage the same operator with both OLM versions |
| CRD upgrade safety check blocks update | Schema change detected in CRD | Review the change; if safe, set `install.preflight.crdUpgradeSafety.disabled: true` temporarily |
| `ClusterExtension` shows `Installed=True` but no pods running | Namespace does not exist or SA lacks permissions in target namespace | Ensure the namespace was created before applying the ClusterExtension |

## References

- [OLMv1 Documentation (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/operators/olm-v1)
- [Extensions Guide (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index)
- [ClusterExtension API Reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/operatorhub_apis/clusterextension-olm-operatorframework-io-v1)
