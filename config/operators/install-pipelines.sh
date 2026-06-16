#!/usr/bin/env bash
set -euo pipefail

echo "Installing OpenShift Pipelines operator"
CHANNEL=${CHANNEL:-stable}
CATALOG_SOURCE=${CATALOG_SOURCE:-redhat-operators}

wait_csv_succeeded() {
  local csv=$1 ns=${2:-openshift-operators} timeout=${3:-10m} phase
  echo "Waiting for ${csv} phase=Succeeded..."
  if oc wait "csv/${csv}" -n "$ns" --for=jsonpath='{.status.phase}'=Succeeded --timeout="$timeout" 2>/dev/null; then
    return 0
  fi
  local deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    phase=$(oc get "csv/${csv}" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase" == Succeeded ]] && return 0
    echo "  CSV ${csv} phase=${phase:-Unknown}..." >&2
    sleep 10
  done
  echo "ERROR: ${csv} did not reach Succeeded (last phase=${phase:-Unknown})" >&2
  return 1
}

echo "Ensure pipelines subscription exists"
if oc get subscription openshift-pipelines-operator-rh -n openshift-operators &>/dev/null; then
  oc patch subscription openshift-pipelines-operator-rh -n openshift-operators --type merge \
    -p "{\"spec\":{\"channel\":\"${CHANNEL}\",\"source\":\"${CATALOG_SOURCE}\",\"sourceNamespace\":\"openshift-marketplace\"}}"
else
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: ${CHANNEL}
  config:
    nodeSelector:
      node-role.kubernetes.io/master: ''
    tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
  installPlanApproval: Manual
  name: openshift-pipelines-operator-rh
  source: ${CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF
fi

echo "Waiting for InstallPlan..."
if ! oc wait subscription/openshift-pipelines-operator-rh -n openshift-operators \
  --for=condition=InstallPlanPending --timeout=2m 2>/dev/null; then
  csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators -o jsonpath='{.status.currentCSV}')
  if [[ -n "$csv" ]] && wait_csv_succeeded "$csv" openshift-operators 2m; then
    echo "Operator ${csv} already installed"
    exit 0
  fi
  echo "ERROR: InstallPlan not pending and operator not installed" >&2
  exit 1
fi
installplan=$(oc get -n openshift-operators installplan \
  -l operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators \
  -o name | head -1)
[[ -n "$installplan" ]] || { echo "ERROR: InstallPlan not found" >&2; exit 1; }

if [[ "$(oc get "$installplan" -n openshift-operators -o jsonpath='{.spec.approved}')" != true ]]; then
  echo "Approving ${installplan}"
  oc patch "$installplan" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
fi

echo "Waiting for operator CSV..."
csv=""
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  [[ -n "$csv" ]] && break
  echo "  waiting for currentCSV..." >&2
  sleep 5
done
[[ -n "$csv" ]] || { echo "ERROR: subscription currentCSV not set" >&2; exit 1; }
echo "  subscription currentCSV=${csv}"

wait_csv_succeeded "$csv" openshift-operators 10m
echo "Operator ${csv} installed"
