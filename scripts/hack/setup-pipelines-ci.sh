#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACE="${NAMESPACE:-pipelines-ci}"
FORCE=false MODE=full

while [[ $# -gt 0 ]]; do
  case $1 in
    --pvc-only)
      echo "NOTE: shared toolchain PVC removed; use ./scripts/hack/cleanup-pipeline-pvcs.sh --legacy-only"
      exec "$SCRIPT_DIR/cleanup-pipeline-pvcs.sh" --legacy-only --namespace "$NAMESPACE"
      ;;
    --cluster-secret-only) MODE=cluster; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--cluster-secret-only] [--force]

  default:               cluster secret + Tekton tasks/pipeline
  --cluster-secret-only: cluster-\${CLUSTER_NAME} secret only (from .env)
  --force:               recreate cluster secret if it exists
  --pvc-only:            (deprecated) run ./scripts/hack/cleanup-pipeline-pvcs.sh --legacy-only

  INSTALLER=cluster-platforms → cluster-ca-cert, OC_TOKEN in secret
  INSTALLER=none            → skips update if secret already has installer=cluster-platforms

  INSTALL_PIPELINES_OPERATOR=true runs operator install before Tekton apply (default from .env)
EOF
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -f "$REPO_ROOT/.env" ]] || die "missing $REPO_ROOT/.env"
set -a; source "$REPO_ROOT/.env"; set +a
NAMESPACE="${NAMESPACE:-pipelines-ci}"
command -v oc >/dev/null || die "oc CLI required"
# shellcheck source=cluster-login.sh
source "$SCRIPT_DIR/cluster-login.sh"

ensure_namespace() {
  oc get namespace "$NAMESPACE" &>/dev/null \
    && echo "Namespace ${NAMESPACE} exists" \
    || { echo "Creating namespace ${NAMESPACE}..."; oc new-project "$NAMESPACE"; }
  oc project "$NAMESPACE" >/dev/null
}

create_cluster_secret() {
  [[ -n "${CLUSTER_NAME:-}" ]] || die "CLUSTER_NAME required in .env"
  [[ -n "${APISERVER:-}" ]] || die "APISERVER required in .env"
  local secret existing args installer
  secret="$(cluster_secret_name)" || die "CLUSTER_NAME required in .env"

  echo "Checking for secret ${secret} in ${NAMESPACE}..."
  if cluster_secret_exists "$NAMESPACE"; then
    existing="$(secret_installer "$secret" "$NAMESPACE")"
    if ! cluster_platforms && [[ "$existing" == cluster-platforms ]]; then
      echo "Secret ${secret} has installer=cluster-platforms; .env INSTALLER=${INSTALLER:-none} — skipping"
      return 0
    fi
    [[ "$FORCE" == true ]] || { echo "Secret ${secret} already exists in ${NAMESPACE} (use --force to recreate)"; return 0; }
    echo "Deleting secret ${secret}..."
    oc delete secret "$secret" -n "$NAMESPACE"
  fi

  validate_cluster_env || die "cluster env validation failed"
  echo "=== Verifying cluster login ==="
  cluster_login || die "cluster login failed"

  installer=$(cluster_installer)
  echo "=== Creating secret ${secret} (installer=${installer}) ==="

  args=(
    --from-literal=admin-name="$(cluster_admin_name)"
    --from-literal=api-url="${APISERVER}"
    --from-literal=admin-token="$(cluster_admin_token)"
    --from-literal=kubeadmin-password="${KUBEADMIN_PASSWORD:-}"
    --from-literal=user-password="${USER_PASSWORD:-user}"
    --from-literal=insecure-skip-tls-verify="$(cluster_insecure_tls)"
    --from-literal=installer="${installer}"
    --from-literal=mirror-reg=quay.io
  )
  cluster_platforms && args+=(--from-file=cluster-ca-cert="$(cluster_ca_path)")

  oc create secret generic "$secret" "${args[@]}" -n "$NAMESPACE"
  oc label secret "$secret" keep-cluster=true -n "$NAMESPACE" --overwrite
  echo "Created secret ${secret}"
}

resolve_channel() {
  [[ -n "${OPERATOR_VERSION:-}" ]] || die "OPERATOR_VERSION required for operator install"
  if [[ -z "${CHANNEL:-}" || "${CHANNEL}" == latest ]]; then
    CHANNEL="pipelines-${OPERATOR_VERSION%.*}"
    export CHANNEL
    echo "CHANNEL=${CHANNEL} (from OPERATOR_VERSION=${OPERATOR_VERSION})"
  fi
}

apply_custom_catalog() {
  local env="${OPERATOR_ENVIRONMENT:-pre-stage}" src="${CATALOG_SOURCE:-redhat-operators}" pod yaml
  [[ "$env" == prod || "$src" == redhat-operators ]] && return 0
  [[ -n "${KONFLUX_INDEX_IMAGE:-}" ]] || die "KONFLUX_INDEX_IMAGE required when OPERATOR_ENVIRONMENT != prod"

  yaml=$(mktemp "${TMPDIR:-/tmp}/catalog.XXXXXX")
  cat >"$yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${src}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${KONFLUX_INDEX_IMAGE}
  displayName: ${src}
  updateStrategy:
    registryPoll:
      interval: 30m
EOF
  echo "Applying CatalogSource ${src} (${KONFLUX_INDEX_IMAGE})"
  oc apply -f "$yaml"
  rm -f "$yaml"
  echo "Waiting for CatalogSource ${src}..."
  if ! oc wait "catalogsource/${src}" -n openshift-marketplace --for=condition=Ready --timeout=5m 2>/dev/null; then
    pod=$(oc get pods -n openshift-marketplace --sort-by='{.metadata.creationTimestamp}' -o name \
      | grep "${src}" | tail -1 || true)
    [[ -n "$pod" ]] || die "no catalog pod for ${src}"
    oc wait --for=condition=Ready -n openshift-marketplace "$pod" --timeout=5m
  fi
}

install_pipelines_operator() {
  [[ "$(printf '%s' "${INSTALL_PIPELINES_OPERATOR:-false}" | tr '[:upper:]' '[:lower:]')" == true ]] || {
    echo "Skipping operator install (INSTALL_PIPELINES_OPERATOR=${INSTALL_PIPELINES_OPERATOR:-false})"
    return 0
  }

  resolve_channel
  validate_cluster_env || die "cluster env validation failed"
  cluster_login || die "cluster login failed"

  local csv phase
  csv=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  if [[ -n "$csv" && "$csv" == *"${OPERATOR_VERSION}"* ]]; then
    phase=$(oc get "csv/${csv}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == Succeeded ]]; then
      echo "Operator ${OPERATOR_VERSION} already installed (${csv})"
      return 0
    fi
  fi

  echo "=== Installing OpenShift Pipelines operator (${OPERATOR_VERSION}, ${CATALOG_SOURCE}/${CHANNEL}) ==="
  apply_custom_catalog
  CHANNEL="${CHANNEL}" CATALOG_SOURCE="${CATALOG_SOURCE:-redhat-operators}" \
    bash "$REPO_ROOT/config/operators/install-pipelines.sh"
}

verify_pipelines_install() {
  local n deadline=$((SECONDS + 600))
  echo "=== Verifying OpenShift Pipelines install ==="
  while (( SECONDS < deadline )); do
    if oc get tektonconfig config &>/dev/null; then
      oc wait tektonconfig/config --for=condition=Ready --timeout=60s 2>/dev/null && break
    else
      echo "  waiting for TektonConfig..." >&2
    fi
  done
  oc get tektonconfig config 2>/dev/null || die "TektonConfig config not found — operator install incomplete"
  [[ "$(oc get tektonconfig config --no-headers | awk '{print $3}')" == True ]] \
    || die "TektonConfig not Ready"
  n=$(oc get tektoninstallersets --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${n:-0}" -gt 0 ]] || die "no TektonInstallerSets found"
  echo "OK: TektonConfig Ready; ${n} TektonInstallerSet(s) present"
}

enable_pipelines_console_plugin() {
  [[ "$(printf '%s' "${INSTALL_PIPELINES_OPERATOR:-false}" | tr '[:upper:]' '[:lower:]')" == true ]] || return 0

  local env="${OPERATOR_ENVIRONMENT:-pre-stage}" plugin=pipelines-console-plugin
  if [[ "$env" == prod ]]; then
    echo "Skipping console plugin patch (OPERATOR_ENVIRONMENT=prod — enabled by default)"
    return 0
  fi

  if oc get consoles.operator.openshift.io cluster -o jsonpath='{range .spec.plugins[*]}{.}{"\n"}{end}' 2>/dev/null \
    | grep -qxF "$plugin"; then
    echo "Console plugin ${plugin} already enabled"
    return 0
  fi

  echo "=== Enabling ${plugin} on OpenShift console ==="
  oc patch consoles.operator.openshift.io cluster \
    -p '{"spec":{"plugins":["pipelines-console-plugin"]}}' \
    --type=merge
  echo "Console plugin ${plugin} enabled"
}

case "$MODE" in
  cluster) ensure_namespace; create_cluster_secret; exit 0 ;;
esac

ensure_namespace
create_cluster_secret

# Add Quay credentials to global pull-secret for stage/pre-stage index images
if [[ -n "${QUAY_USER:-}" && -n "${QUAY_PASS:-}" ]]; then
  echo "=== Updating global pull-secret with Quay credentials ==="
  _tmpps=$(mktemp)
  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
    | base64 -d > "$_tmpps"
  if [[ -s "$_tmpps" ]]; then
    export QUAY_B64=$(echo -n "${QUAY_USER}:${QUAY_PASS}" | base64)
    python3 -c "
import json, os
with open('$_tmpps') as f:
    d = json.load(f)
d['auths']['quay.io'] = {'auth': os.environ['QUAY_B64']}
with open('$_tmpps', 'w') as f:
    json.dump(d, f)
" && \
    oc set data secret/pull-secret -n openshift-config --from-literal=".dockerconfigjson=$(cat "$_tmpps")" && \
    echo "  quay.io auth added (${QUAY_USER})" || \
    echo "  WARNING: failed to update global pull-secret"
    unset QUAY_B64
  fi
  rm -f "$_tmpps"
fi

install_pipelines_operator
verify_pipelines_install
enable_pipelines_console_plugin

echo "=== Applying Tekton Tasks & Pipeline ==="
oc apply -f "$REPO_ROOT/ci/tasks/" -n "$NAMESPACE"
oc apply -f "$REPO_ROOT/ci/pipelines/" -n "$NAMESPACE"
oc get tasks,pipelines -n "$NAMESPACE" -o custom-columns=KIND:.kind,NAME:.metadata.name --no-headers | sed 's/^/  /'

if oc get secret aws-creds -n "$NAMESPACE" &>/dev/null; then
  echo "=== Applying orphan cleanup triggers (hourly) ==="
  oc apply -f "$REPO_ROOT/ci/triggertemplates/" -n "$NAMESPACE"
  oc apply -f "$REPO_ROOT/ci/triggerbindings/" -n "$NAMESPACE"
  oc apply -f "$REPO_ROOT/ci/eventlisteners/" -n "$NAMESPACE"
  oc apply -f "$REPO_ROOT/ci/routes/" -n "$NAMESPACE"
  oc apply -f "$REPO_ROOT/ci/cronjobs/" -n "$NAMESPACE"
  echo "  EventListener: el-cleanup-orphan-clusters"
  echo "  CronJob: cleanup-orphan-clusters (hourly POST to EventListener)"
fi

echo "=== Setup complete ==="
echo "Run acceptance tests:"
echo "  ./scripts/hack/create-pipelinerun.sh"
echo "Run upgrade tests (INSTALLER=aws-ipi):"
echo "  ./scripts/hack/run-upgrade-tests.sh"
