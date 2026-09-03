# Migration Notes — RHOAI 3.4 → 3.5

These notes document breaking changes, required actions, and gotchas discovered during the validated upgrade from RHOAI 3.4 to 3.5 on OCP 4.21.

---

## Breaking changes

### DSC v2 API — MaaS field migration

The MaaS toggle moved from `kserve.modelsAsService` to `aigateway.modelsAsAService`. The old field is deprecated but respected through RHOAI 3.6.

```yaml
# 3.4 (deprecated)
kserve:
  modelsAsService:
    managementState: Managed

# 3.5 (new)
aigateway:
  managementState: Managed
  modelsAsAService:
    managementState: Managed
```

**Action:** Re-apply the RHOAI instance chart (`helm template rhoai ./gitops/instance/rhoai | oc apply -f -`). The updated chart uses `aigateway.modelsAsAService`. A dry-run warning confirms the old field is deprecated but still functional.

### DSC v2 API — new and renamed components

| 3.4 component | 3.5 replacement | Notes |
|---|---|---|
| `llamastackoperator` | `ogx` | OGX replaces LlamaStack |
| — | `trainer` | New (default: Removed) |
| — | `mcplifecycleoperator` | New (default: Removed) |
| — | `aigateway` | New — hosts `modelsAsAService` |
| — | `mlflowoperator` | New — MLflow operator + instance CR |

### EPP API group rename

The `EndpointPickerConfig` and `InferenceObjective` API group changed:

```
inference.networking.x-k8s.io/v1alpha1  →  llm-d.ai/v1alpha1
```

Both CRDs exist on the cluster during transition, but new deployments must use `llm-d.ai`. The inference chart template has been updated.

### EPP metrics prefix

The EPP metrics prefix changed from `inference_extension_` to `llm_d_epp_`. Update any custom Prometheus dashboards, alerts, or Grafana panels that reference the old prefix.

---

## MaaS infrastructure namespace change

The MaaS infrastructure namespace moved from `redhat-ods-applications` to `redhat-ai-gateway-infra`. The `maas-db-config` secret, `maas-api` deployment, and `maas-api-route` HTTPRoute all live in this new namespace.

**Impact on upgrades:** The MaaS gateway's `allowedRoutes` must include `redhat-ai-gateway-infra`. Gateways deployed from the 3.4 chart only allow `redhat-ods-applications`, causing the `maas-api-route` HTTPRoute to be rejected with `NotAllowedByListeners`. The MaaS API returns 404 for all paths (`/v1/api-keys`, `/v1/models`, etc.).

**Fix:** Re-apply the MaaS gateway chart — the 3.5 chart includes the new namespace:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
helm template gitops/instance/maas/gateway --name-template maas-gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set "gateway.modelNamespaces={llm-d-demo}" | oc apply -f -
```

Verify the HTTPRoute is accepted:

```bash
oc get httproute maas-api-route -n redhat-ai-gateway-infra \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True
```

### Tenant CR deprecation

The `Tenant` CR is deprecated in 3.5 — it will be replaced by `AITenant` + `MaasTenantConfig` in a future release. The `Tenant` CR still works in 3.5; no action required yet.

---

## vLLM changes

### Access-log flag deprecation

`--disable-uvicorn-access-log` is deprecated in favor of `--disable-access-log-for-endpoints=/health,/metrics,/ping`. The old flag still works on vLLM 0.18.0 (generates a `Found duplicate keys` warning) but may be removed in a future release. All per-model values files in the chart have been updated.

### New EPP scheduler scorers

The default EPP scheduler adds two new scorers alongside the existing ones:

| Scorer | Weight | New in 3.5 |
|---|---|---|
| `prefix-cache-scorer` | 3.0 | No (weight changed from 2.0) |
| `queue-scorer` | 2.0 | No (weight changed from 1.0) |
| `kv-cache-utilization-scorer` | 1.0 | Yes |
| `no-hit-lru-scorer` | 1.0 | Yes |

No action required unless you use a custom scorer configuration.

---

## OLMv1 support (OCP 4.21+)

RHOAI 3.5 on OCP 4.21 supports both OLMv0 and OLMv1. Each operator directory now ships both `operator.yaml` (OLMv0) and `cluster-extension.yaml` (OLMv1). Helm charts accept `--set olmVersion=v1`. The `install.sh` scripts for NFD and NVIDIA auto-detect the OCP version.

See [OLMv1 Migration Reference](olmv1-migration.md) for full details.

**`check-operators.sh`** has been updated to detect operators installed via either OLMv0 (CSV) or OLMv1 (ClusterExtension).

---

## LLMInferenceService API version

Both `v1alpha1` (served) and `v1alpha2` (served + storage) are available on the CRD. The inference chart uses `v1alpha2` because it is the storage version. Resources at either version are accepted.

---

## Upgrade checklist

1. [ ] Update RHOAI operator to 3.5 (stable channel auto-upgrades)
2. [ ] Re-apply RHOAI instance chart (DSC v2 with `aigateway.modelsAsAService`)
3. [ ] Re-apply MaaS gateway chart (adds `redhat-ai-gateway-infra` to allowedRoutes)
4. [ ] Update per-model values files (`--disable-uvicorn-access-log` → `--disable-access-log-for-endpoints=...`)
5. [ ] Re-deploy LLMInferenceServices (picks up new EPP scorers and API group)
6. [ ] Verify `check-operators.sh` passes
7. [ ] Clean up stale resources in `redhat-ods-applications` if MaaS was previously deployed there
