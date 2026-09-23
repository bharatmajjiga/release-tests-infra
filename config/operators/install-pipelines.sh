#!/usr/bin/env bash
set -euo pipefail

echo "Installing OpenShift Pipelines operator"
CHANNEL=${CHANNEL:-stable}
CATALOG_SOURCE=${CATALOG_SOURCE:-redhat-operators}
OPERATOR_VERSION="${OPERATOR_VERSION:-${OSP_VERSION:-}}"

is_nightly() {
  case "$(printf '%s' "${NIGHTLY:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;;
  esac
  [[ "${KONFLUX_INDEX_IMAGE:-}" == *:nightly ]]
}

NIGHTLY_INSTALL=false
if is_nightly; then
  NIGHTLY_INSTALL=true
  echo "Nightly install: channel-head on ${CATALOG_SOURCE}/${CHANNEL} (no startingCSV pin)"
fi

CSV_NAME=""
if [[ -n "$OPERATOR_VERSION" && "$NIGHTLY_INSTALL" != true ]]; then
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
  [[ -z "$OPERATOR_VERSION" || "$NIGHTLY_INSTALL" == true ]] && return 0
  [[ "$installed" == "$CSV_NAME" || "$installed" == *".v${OPERATOR_VERSION}" ]]
}

# Approve Manual InstallPlans until the subscription's installedCSV reaches Succeeded
# (channel head — used for nightly where the CSV is 5.0.5-<random>).
# Sets APPROVED_CSV on success.
approve_latest_installplan() {
  local deadline=$((SECONDS + 900))
  local ip names phase approved installed
  APPROVED_CSV=""
  echo "Waiting for latest CSV on ${CHANNEL} (approving Manual InstallPlans)..."
  while (( SECONDS < deadline )); do
    installed=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "$installed" ]]; then
      phase=$(oc get csv "$installed" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [[ "$phase" == Succeeded ]]; then
        echo "Installed ${installed} (phase=Succeeded)"
        APPROVED_CSV="$installed"
        return 0
      fi
    fi
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      names=$(oc get installplan "$ip" -n openshift-operators \
        -o jsonpath='{.spec.clusterServiceVersionNames[*]}' 2>/dev/null || true)
      approved=$(oc get installplan "$ip" -n openshift-operators \
        -o jsonpath='{.spec.approved}' 2>/dev/null || true)
      if [[ "$names" == *openshift-pipelines-operator-rh* && "$approved" != true ]]; then
        echo "Approving InstallPlan ${ip} (${names})"
        oc patch installplan "$ip" -n openshift-operators --type merge -p '{"spec":{"approved":true}}' || true
      fi
    done < <(oc get installplan -n openshift-operators --no-headers 2>/dev/null | awk '{print $1}')
    echo "  operator CSV installed=${installed:-none} phase=${phase:-none}..."
    sleep 10
  done
  echo "ERROR: operator did not reach Succeeded on channel ${CHANNEL}" >&2
  oc get subscription,csv,installplan -n openshift-operators || true
  return 1
}

# Skip only when the installed CSV is the requested version (not merely "latest on channel").
existing_csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
  -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
existing_state=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
  -o jsonpath='{.status.state}' 2>/dev/null || true)

# Skip when the requested CSV is already Succeeded. Do not require AtLatestKnown:
# Manual + startingCSV leaves UpgradePending when a newer z-stream exists on the
# channel (expected for upgrade tests). Wiping would break acceptance re-runs.
# Nightly: skip only when some CSV on the channel is already Succeeded.
if [[ -n "$existing_csv" ]]; then
  phase=$(oc get "csv/${existing_csv}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" == Succeeded ]]; then
    if [[ "$NIGHTLY_INSTALL" == true ]] || csv_matches_requested "$existing_csv"; then
      echo "Operator ${existing_csv} already installed (${existing_state:-unknown}, ${CATALOG_SOURCE}/${CHANNEL})"
      echo "INSTALLED_OSP_VERSION=${existing_csv#openshift-pipelines-operator-rh.v}"
      exit 0
    fi
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
elif [[ "$NIGHTLY_INSTALL" == true ]]; then
  echo "Omitting startingCSV (nightly channel-head install on ${CATALOG_SOURCE}/${CHANNEL})"
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

if [[ "$NIGHTLY_INSTALL" == true ]]; then
  approve_latest_installplan || exit 1
  csv="$APPROVED_CSV"
  echo "Operator ${csv} installed"
  echo "INSTALLED_OSP_VERSION=${csv#openshift-pipelines-operator-rh.v}"
  exit 0
fi

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
        echo "INSTALLED_OSP_VERSION=${csv#openshift-pipelines-operator-rh.v}"
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
echo "INSTALLED_OSP_VERSION=${csv#openshift-pipelines-operator-rh.v}"
