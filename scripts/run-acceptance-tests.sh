#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-pipelines-ci}"
PIPELINERUN_FILE="${1:-$REPO_ROOT/ci/pipelineruns/acceptance-tests-install.yaml}"

echo "=== Pre-flight checks ==="

CLUSTER_NAME=$(grep 'name: CLUSTER_NAME' -A1 "$PIPELINERUN_FILE" | tail -1 | awk '{print $2}' | tr -d '"')
SECRET_NAME="cluster-${CLUSTER_NAME}"

if ! oc get pipeline acceptance-tests -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Pipeline 'acceptance-tests' not found in namespace '$NAMESPACE'."
  echo "Run ./scripts/setup-pipelines-ci.sh first."
  exit 1
fi

if ! oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'."
  echo "Run ./scripts/create-cluster-secret.sh first."
  exit 1
fi

echo "  Pipeline:       acceptance-tests"
echo "  Cluster secret: $SECRET_NAME"
echo "  PipelineRun:    $PIPELINERUN_FILE"
echo "  Namespace:      $NAMESPACE"
echo ""

PIPELINERUN_NAME=$(oc create -f "$PIPELINERUN_FILE" -n "$NAMESPACE" -o name)
echo "=== PipelineRun created: $PIPELINERUN_NAME ==="
echo ""
echo "Watch progress with:"
echo "  tkn pipelinerun logs ${PIPELINERUN_NAME#*/} -f -n $NAMESPACE"
echo ""
echo "Or check status with:"
echo "  oc get $PIPELINERUN_NAME -n $NAMESPACE"
echo "  tkn pipelinerun describe ${PIPELINERUN_NAME#*/} -n $NAMESPACE"
