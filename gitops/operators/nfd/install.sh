#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OCP_MINOR=$(oc version -o json | jq -r '.openshiftVersion' | cut -d. -f2)

if [[ "${OCP_MINOR}" -ge 21 ]]; then
  echo "OCP 4.${OCP_MINOR} detected — installing NFD via OLMv1 (ClusterExtension)"
  oc apply -f "${DIR}/cluster-extension.yaml"
else
  PACKAGE=nfd
  CHANNEL=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}')
  CSV=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
    -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")
  echo "OCP 4.${OCP_MINOR} — installing NFD via OLMv0 (Subscription): channel=${CHANNEL} csv=${CSV}"
  oc apply -f "${DIR}/operator.yaml"
  oc patch subscription nfd -n openshift-nfd --type merge -p \
    "{\"spec\":{\"channel\":\"${CHANNEL}\",\"startingCSV\":\"${CSV}\"}}"
fi
