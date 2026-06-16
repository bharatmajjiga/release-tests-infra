#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$REPO_ROOT/.env" ]] || { echo "ERROR: .env not found (cp env.template .env)" >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

# shellcheck source=cluster-login.sh
source "$SCRIPT_DIR/cluster-login.sh"
validate_cluster_env || exit 1

echo "============================================================"
echo "  release-tests-infra workflow"
echo "  Operator: ${OPERATOR_VERSION}  Catalog: ${CATALOG_SOURCE}/${CHANNEL:-pipelines-${OPERATOR_VERSION%.*}}"
echo "  Environment: ${OPERATOR_ENVIRONMENT:-pre-stage}"
echo "  Framework: ${TEST_FRAMEWORK:-gauge}"
echo "============================================================"

cluster_login

echo "=== Step 1: Create secrets ==="
"$SCRIPT_DIR/create-secrets.sh"

is_enabled() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;; *) return 1 ;; esac
}

if is_enabled "${INSTALL_LOGGING_OPERATOR:-false}"; then
  echo "=== Installing Logging operator ==="
  bash "$REPO_ROOT/config/operators/install-logging.sh"
fi

if is_enabled "${INSTALL_SERVERLESS_OPERATOR:-false}"; then
  echo "=== Installing Serverless operator ==="
  bash "$REPO_ROOT/config/operators/install-serverless.sh"
fi

echo "=== Setting up Tekton pipelines-ci ==="
"$SCRIPT_DIR/setup-pipelines-ci.sh"

echo "=== Creating PipelineRun ==="
"$SCRIPT_DIR/create-pipelinerun.sh"

echo "=== Workflow complete ==="
