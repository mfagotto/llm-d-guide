#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OCP_MINOR=$(oc version -o json | jq -r '.openshiftVersion' | cut -d. -f2)

if [[ "${OCP_MINOR}" -ge 21 ]]; then
  echo "OCP 4.${OCP_MINOR} detected — installing NVIDIA GPU Operator via OLMv1 (ClusterExtension)"
  oc apply -f "${DIR}/cluster-extension.yaml"
else
  PACKAGE=gpu-operator-certified
  CHANNEL=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}')
  CSV=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
    -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")
  echo "OCP 4.${OCP_MINOR} — installing NVIDIA GPU Operator via OLMv0 (Subscription): channel=${CHANNEL} csv=${CSV}"
  sed "s/NVIDIA_CHANNEL_PLACEHOLDER/${CHANNEL}/" "${DIR}/operator.yaml" | oc apply -f -
  oc patch subscription gpu-operator-certified -n nvidia-gpu-operator --type merge -p \
    "{\"spec\":{\"startingCSV\":\"${CSV}\"}}"
fi
