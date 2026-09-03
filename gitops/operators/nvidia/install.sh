#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NVIDIA GPU Operator bundle does not support AllNamespaces install mode,
# so OLMv1 ClusterExtension cannot be used (fails with
# "unsupported bundle: bundle does not support AllNamespaces install mode").
# Always use OLMv0 until the bundle is updated.

PACKAGE=gpu-operator-certified
CHANNEL=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}')
CSV=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")
echo "Installing NVIDIA GPU Operator via OLMv0 (Subscription): channel=${CHANNEL} csv=${CSV}"
sed "s/NVIDIA_CHANNEL_PLACEHOLDER/${CHANNEL}/" "${DIR}/operator.yaml" | oc apply -f -
oc patch subscription gpu-operator-certified -n nvidia-gpu-operator --type merge -p \
  "{\"spec\":{\"startingCSV\":\"${CSV}\"}}"
