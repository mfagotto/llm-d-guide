#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NFD bundle does not support AllNamespaces install mode,
# so OLMv1 ClusterExtension cannot be used (fails with
# "unsupported bundle: bundle does not support AllNamespaces install mode").
# Always use OLMv0 until the bundle is updated.

PACKAGE=nfd
CHANNEL=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}')
CSV=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")
echo "Installing NFD via OLMv0 (Subscription): channel=${CHANNEL} csv=${CSV}"
oc apply -f "${DIR}/operator.yaml"
oc patch subscription nfd -n openshift-nfd --type merge -p \
  "{\"spec\":{\"channel\":\"${CHANNEL}\",\"startingCSV\":\"${CSV}\"}}"
