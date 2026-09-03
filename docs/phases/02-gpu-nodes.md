# Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Add GPU worker nodes and install the hardware detection and driver stack.

**Before starting Phase 2 — ask the user:**
> "How many availability zones do you want GPU nodes in?
> - **All 3 AZs** (a, b, c) — recommended for production; 3 GPU nodes total (1 per AZ).
> - **Single AZ** — sufficient for a single-model test; cheaper, faster to provision.
> Which would you like?"

Do NOT decide this yourself — the number of GPU nodes affects cost and scheduling decisions that belong to the user.

**Install order:**
1. GPU MachineSets (AWS only) — start node provisioning first so nodes are ready by the time operators finish installing:
   ```bash
   export INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
   export AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
   export AMI_ID=$(oc get machineset -n openshift-machine-api \
     -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}')
   export AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:=g5.2xlarge}"
   export AWS_INSTANCES_PER_AZ=1

   # All 3 AZs → 3 MachineSets, one per AZ (3 GPU nodes total)
   # Single AZ → replace "a b c" with just "a" (or the user's chosen AZ)
   for AZ in a b c; do
     helm template gpu-worker ./gitops/instance/machine-sets/gpu-worker \
       --set infrastructureId="${INFRA_ID}" \
       --set region=${AWS_REGION} \
       --set instanceType=${AWS_INSTANCE_TYPE} \
       --set amiId="${AMI_ID}" \
       --set devicePluginConfig="" \
       --set az=${AZ} | oc apply -f -
   done
   ```
   Use the AZ choice the user confirmed above. **Do not default to a single AZ** without explicit user approval — 3 AZs means 3 separate MachineSets, 3 GPU nodes.

2. NFD + NVIDIA GPU operators:

   > **OLMv0 vs OLMv1:** The `install.sh` scripts auto-detect the OCP version. On OCP 4.20 they apply
   > `operator.yaml` (OLMv0 Subscription); on OCP 4.21+ they apply `cluster-extension.yaml` (OLMv1
   > ClusterExtension). The wait commands differ between the two — use the one matching your cluster.

   ```bash
   # Install NFD operator (auto-detects OCP version)
   bash gitops/operators/nfd/install.sh

   # OCP 4.20 — wait for NFD CSV to reach Succeeded:
   oc get csv -n openshift-nfd -w | grep nfd
   oc wait --for=jsonpath='{.status.phase}'=Succeeded csv \
     -n openshift-nfd -l operators.coreos.com/nfd.openshift-nfd= --timeout=300s

   # OCP 4.21+ — wait for NFD ClusterExtension:
   oc get clusterextension nfd -w

   # Install NVIDIA GPU operator (auto-detects OCP version)
   bash gitops/operators/nvidia/install.sh

   # OCP 4.20 — wait for NVIDIA GPU operator CSV to reach Succeeded:
   oc get csv -n nvidia-gpu-operator -w | grep gpu-operator
   oc wait --for=jsonpath='{.status.phase}'=Succeeded csv \
     -n nvidia-gpu-operator -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator= --timeout=300s

   # OCP 4.21+ — wait for NVIDIA GPU operator ClusterExtension:
   oc get clusterextension gpu-operator-certified -w
   ```

3. Apply the instance CRs (after both operators are installed -- CSVs `Succeeded` on 4.20, ClusterExtensions `Installed` on 4.21+):
   ```bash
   # Apply NFD instance (NodeFeatureDiscovery CR)
   oc apply -k gitops/instance/nfd

   # Wait for NFD labels to appear on nodes before applying ClusterPolicy
   oc wait --for=condition=Established crd/nodefeaturediscoveries.nfd.openshift.io --timeout=120s

   # Apply NVIDIA instance (ClusterPolicy CR)
   oc apply -k gitops/instance/nvidia

   # Wait for the ClusterPolicy to reach ready state (all GPU daemonsets deployed)
   oc wait --for=jsonpath='{.status.state}'=ready clusterpolicy/gpu-cluster-policy --timeout=600s
   ```

**Key wait conditions:**
```bash
# NFD labels applied to GPU nodes
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true

# NVIDIA device plugin running on GPU nodes
oc get pods -n nvidia-gpu-operator -w

# GPU capacity visible on nodes
oc get nodes -o json | jq '.items[].status.capacity | select(."nvidia.com/gpu")'
```

**Human gate:** Confirm that at least one GPU Machine is `Provisioned` and both operators are installed — on OCP 4.20 both CSVs must be `Succeeded`; on OCP 4.21+ both ClusterExtensions must show `Installed`. You do **not** need to wait for all GPU nodes to be `Ready` or for `nvidia.com/gpu` capacity to appear — Phases 3 and 4 install operators that have no GPU dependency. GPU capacity is only required at Phase 5 (llm-d deployment).

> **Tip:** GPU node provisioning (10–15 min on AWS) and NVIDIA driver installation run in the background while you work through Phases 3–4. By the time you reach Phase 5, nodes will typically be ready. If not, Phase 5 will prompt you to wait.

**Known gotcha:** The ClusterPolicy webhook may reject the CR if the NFD labels aren't present yet. Apply NFD first, wait for labels, then apply nvidia.

**End of Phase 2:** Report GPU MachineSet status and operator install state (CSV on OCP 4.20, ClusterExtension on OCP 4.21+) to the user. Wait for confirmation before proceeding to [Phase 3](03-operators-rhoai.md).
