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

# Check if operator is already installed and healthy
existing_csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
  -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
existing_state=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
  -o jsonpath='{.status.state}' 2>/dev/null || true)

if [[ -n "$existing_csv" && "$existing_state" == AtLatestKnown ]]; then
  phase=$(oc get "csv/${existing_csv}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" == Succeeded ]]; then
    echo "Operator ${existing_csv} already installed and healthy (${CATALOG_SOURCE}/${CHANNEL})"
    # Ensure subscription points to correct source/channel
    oc patch subscription openshift-pipelines-operator-rh -n openshift-operators --type merge \
      -p "{\"spec\":{\"channel\":\"${CHANNEL}\",\"source\":\"${CATALOG_SOURCE}\",\"sourceNamespace\":\"openshift-marketplace\"}}" 2>/dev/null || true
    exit 0
  fi
fi

echo "Ensure pipelines subscription exists"
if oc get subscription openshift-pipelines-operator-rh -n openshift-operators &>/dev/null; then
  # Delete subscription + CSV for clean reinstall
  echo "Removing existing subscription for clean install..."
  oc delete subscription openshift-pipelines-operator-rh -n openshift-operators --wait=false 2>/dev/null || true
  if [[ -n "$existing_csv" ]]; then
    oc delete csv "$existing_csv" -n openshift-operators --wait=false 2>/dev/null || true
  fi
  oc delete installplan -n openshift-operators --all 2>/dev/null || true
  sleep 10
fi

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: ${CHANNEL}
  installPlanApproval: Manual
  name: openshift-pipelines-operator-rh
  source: ${CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for InstallPlan..."
deadline=$((SECONDS + 300))
installplan=""
while (( SECONDS < deadline )); do
  installplan=$(oc get installplan -n openshift-operators \
    -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null || true)
  [[ -n "$installplan" ]] && break
  # Also check if already approved/installed
  csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  if [[ -n "$csv" ]]; then
    phase=$(oc get "csv/${csv}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == Succeeded ]]; then
      echo "Operator ${csv} already installed"
      exit 0
    fi
  fi
  echo "  waiting for InstallPlan..."
  sleep 10
done

if [[ -n "$installplan" ]]; then
  echo "Approving installplan.operators.coreos.com/${installplan}"
  oc patch "installplan/${installplan}" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
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
