#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="${WORKSPACE:-/tmp/release-tests-workspace}"

# --- Load .env ---
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a; source "$REPO_ROOT/.env"; set +a
else
  echo "ERROR: .env not found. Copy env.template and fill in values:"
  echo "  cp env.template .env"
  exit 1
fi

echo "============================================================"
echo "  release-tests-infra workflow"
echo "============================================================"
echo "  Operator version:  ${OPERATOR_VERSION}"
echo "  Release tests:     ${GIT_RELEASE_TESTS_BRANCH}"
echo "  Catalog source:    ${CATALOG_SOURCE}"
echo "  Channel:           ${CHANNEL}"
echo "  Image:             ${IMAGE}"
echo "  Arch:              ${ARCH}"
echo "  Environment:       ${OPERATOR_ENVIRONMENT}"
echo "============================================================"
echo ""

# --- Step 1: Clone repos ---
echo "=== Step 1: Clone repositories ==="
mkdir -p "$WORKSPACE"

INFRA_DIR="$WORKSPACE/release-tests-infra"
TESTS_DIR="$WORKSPACE/release-tests"

if [[ -d "$INFRA_DIR/.git" ]]; then
  echo "  release-tests-infra already cloned, pulling latest..."
  git -C "$INFRA_DIR" checkout "${GIT_INFRA_BRANCH:-main}" && git -C "$INFRA_DIR" pull || true
else
  echo "  Cloning release-tests-infra (${GIT_INFRA_BRANCH:-main})..."
  git clone -b "${GIT_INFRA_BRANCH:-main}" https://github.com/openshift-pipelines/release-tests-infra.git "$INFRA_DIR"
fi

if [[ -d "$TESTS_DIR/.git" ]]; then
  echo "  release-tests already cloned, pulling latest..."
  git -C "$TESTS_DIR" checkout "${GIT_RELEASE_TESTS_BRANCH}" && git -C "$TESTS_DIR" pull || true
else
  echo "  Cloning release-tests (${GIT_RELEASE_TESTS_BRANCH})..."
  git clone -b "${GIT_RELEASE_TESTS_BRANCH}" https://github.com/openshift-pipelines/release-tests.git "$TESTS_DIR"
fi

# --- Step 2: Install operator via gauge ---
echo ""
echo "=== Step 2: Install operator (gauge run --tags install) ==="

cd "$TESTS_DIR"

if ! command -v gauge &>/dev/null; then
  echo "  Installing gauge..."
  go install github.com/getgauge/gauge@latest
fi

go mod download
gauge install go 2>&1 || true

echo "  Pre-compiling test code..."
go build ./...

echo "  Running install spec..."
export OSP_VERSION="${OPERATOR_VERSION}"
CATALOG_SOURCE="${CATALOG_SOURCE}" \
CHANNEL="${CHANNEL}" \
IS_DISCONNECTED="false" \
  gauge run --log-level=debug --verbose --tags install specs/olm.spec

echo "  Operator installed successfully"
cd "$REPO_ROOT"

# --- Step 3: Install External Secrets Operator ---
echo ""
echo "=== Step 3: External Secrets Operator ==="

if [[ -n "${VAULT_TOKEN:-}" ]]; then
  "$SCRIPT_DIR/install-external-secrets-operator.sh" "$VAULT_TOKEN"
else
  echo "  VAULT_TOKEN not set, skipping ESO installation."
  echo "  Set VAULT_TOKEN in .env to enable Vault-backed secrets."
fi

# --- Step 4: Create secrets ---
echo ""
echo "=== Step 4: Create secrets ==="

if [[ -n "${VAULT_TOKEN:-}" ]]; then
  SOURCE_NS="${SOURCE_NS:-osp-ci-secrets}" "$SCRIPT_DIR/create-secrets.sh"
else
  echo "  Skipping (no Vault token). Secrets can be created manually later."
fi

# --- Step 5: Setup pipelines-ci ---
echo ""
echo "=== Step 5: Setup pipelines-ci ==="
"$SCRIPT_DIR/setup-pipelines-ci.sh"

echo ""
echo "============================================================"
echo "  Workflow complete"
echo "============================================================"
echo ""
echo "  Operator ${OPERATOR_VERSION} installed from ${CATALOG_SOURCE} (${CHANNEL})"
echo "  Tekton tasks and pipeline applied to pipelines-ci"
echo ""
echo "  Run acceptance tests:"
echo "    oc create -f ci/pipelineruns/acceptance-tests-install.yaml -n pipelines-ci"
echo ""
echo "  Or run locally:"
echo "    cd $TESTS_DIR"
echo "    source $REPO_ROOT/.env"
echo "    gauge run --tags install --log-level=debug --verbose specs/olm.spec"
