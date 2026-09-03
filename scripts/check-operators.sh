#!/bin/bash

OCP_MINOR=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion' | cut -d. -f2)

FAILURES=0

check_operator() {
  local label="$1"
  local csv_pattern="$2"
  local csv_namespace="$3"
  local ce_name="$4"
  local required="${5:-true}"

  echo -n "${label}: "

  if oc get csv -n "${csv_namespace}" 2>/dev/null | grep -q "${csv_pattern}"; then
    echo "OK (OLMv0)"
    return 0
  fi

  if [[ -n "${ce_name}" ]] && oc get clusterextension "${ce_name}" &>/dev/null; then
    local installed
    installed=$(oc get clusterextension "${ce_name}" -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null)
    if [[ "${installed}" == "True" ]]; then
      echo "OK (OLMv1)"
      return 0
    else
      echo "INSTALLING (OLMv1 — Installed=${installed})"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
  fi

  if [[ "${required}" == "true" ]]; then
    echo "MISSING"
    FAILURES=$((FAILURES + 1))
  else
    echo "MISSING (optional)"
  fi
  return 0
}

echo "=== Checking Required Operators (OCP 4.${OCP_MINOR}) ==="

check_operator "Cert Manager" "cert-manager" "cert-manager-operator" "cert-manager-operator"
check_operator "Service Mesh 3" "servicemesh" "openshift-operators" ""
check_operator "Connectivity Link" "rhcl-operator" "openshift-operators" "rhcl-operator"
check_operator "OpenShift AI" "rhods" "redhat-ods-operator" "rhods-operator"
check_operator "Leader Worker Set" "leader-worker-set" "openshift-lws-operator" "leader-worker-set"
check_operator "Node Feature Discovery" "nfd" "openshift-nfd" "nfd"
check_operator "NVIDIA GPU Operator" "gpu-operator" "nvidia-gpu-operator" "gpu-operator-certified"

echo ""
echo "=== Monitoring Operators ==="

check_operator "Cluster Observability Operator" "cluster-observability" "openshift-cluster-observability-operator" "cluster-observability-operator"
check_operator "Tempo Operator" "tempo" "openshift-tempo-operator" "tempo-product"
check_operator "OpenTelemetry Operator" "opentelemetry" "openshift-opentelemetry-operator" "opentelemetry-product"
check_operator "Grafana Operator" "grafana" "grafana-operator" "" "false"

exit ${FAILURES}
