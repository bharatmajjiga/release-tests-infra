#!/usr/bin/env bash
set -euo pipefail

echo "Installing OpenShift Pipelines operator"
CHANNEL=${CHANNEL:-stable}
CATALOG_SOURCE=${CATALOG_SOURCE:-redhat-operators}
OPERATOR_VERSION="${OPERATOR_VERSION:-${OSP_VERSION:-}}"
CSV_NAME=""
if [[ -n "$OPERATOR_VERSION" ]]; then
  CSV_NAME="openshift-pipelines-operator-rh.v${OPERATOR_VERSION}"
fi

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

csv_matches_requested() {
  local installed=$1
  [[ -z "$OPERATOR_VERSION" ]] && return 0
  [[ "$installed" == "$CSV_NAME" || "$installed" == *".v${OPERATOR_VERSION}" ]]
}

# Skip only when the installed CSV is the requested version (not merely "latest on channel").
existing_csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
  -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
existing_state=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
  -o jsonpath='{.status.state}' 2>/dev/null || true)

# Skip when the requested CSV is already Succeeded. Do not require AtLatestKnown:
# Manual + startingCSV leaves UpgradePending when a newer z-stream exists on the
# channel (expected for upgrade tests). Wiping would break acceptance re-runs.
if [[ -n "$existing_csv" ]] && csv_matches_requested "$existing_csv"; then
  phase=$(oc get "csv/${existing_csv}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" == Succeeded ]]; then
    echo "Operator ${existing_csv} already installed (${existing_state:-unknown}, ${CATALOG_SOURCE}/${CHANNEL})"
    exit 0
  fi
fi

echo "Ensure pipelines subscription exists"
if oc get subscription openshift-pipelines-operator-rh -n openshift-operators &>/dev/null; then
  echo "Removing existing subscription for clean install..."
  oc delete subscription openshift-pipelines-operator-rh -n openshift-operators --wait=false 2>/dev/null || true
  if [[ -n "$existing_csv" ]]; then
    oc delete csv "$existing_csv" -n openshift-operators --wait=false 2>/dev/null || true
  fi
  oc delete installplan -n openshift-operators --all 2>/dev/null || true
  sleep 10
fi

STARTING_CSV_LINE=""
if [[ -n "$CSV_NAME" ]]; then
  STARTING_CSV_LINE="  startingCSV: ${CSV_NAME}"
  echo "Pinning startingCSV=${CSV_NAME} on ${CATALOG_SOURCE}/${CHANNEL}"
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
${STARTING_CSV_LINE}
EOF

echo "Waiting for InstallPlan..."
deadline=$((SECONDS + 300))
installplan=""
while (( SECONDS < deadline )); do
  installplan=$(oc get installplan -n openshift-operators \
    -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null || true)
  [[ -n "$installplan" ]] && break
  csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  if [[ -n "$csv" ]]; then
    if [[ -n "$OPERATOR_VERSION" ]] && ! csv_matches_requested "$csv"; then
      echo "  subscription currentCSV=${csv} does not match ${OPERATOR_VERSION}, waiting..."
    else
      phase=$(oc get "csv/${csv}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [[ "$phase" == Succeeded ]]; then
        echo "Operator ${csv} already installed"
        exit 0
      fi
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
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  [[ -z "$csv" ]] && csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  if [[ -n "$csv" ]]; then
    if [[ -n "$OPERATOR_VERSION" ]] && ! csv_matches_requested "$csv"; then
      echo "  got ${csv}, want ${CSV_NAME}..."
      csv=""
    else
      break
    fi
  fi
  echo "  waiting for currentCSV..." >&2
  sleep 5
done
[[ -n "$csv" ]] || { echo "ERROR: subscription CSV not set (wanted ${CSV_NAME:-latest on ${CHANNEL}})" >&2; exit 1; }
echo "  subscription CSV=${csv}"

wait_csv_succeeded "$csv" openshift-operators 10m
echo "Operator ${csv} installed"
