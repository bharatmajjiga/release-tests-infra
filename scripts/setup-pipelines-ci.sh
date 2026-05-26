#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-pipelines-ci}"

echo "=== Setting up namespace: $NAMESPACE ==="

oc get namespace "$NAMESPACE" &>/dev/null || oc new-project "$NAMESPACE"
oc project "$NAMESPACE"

echo ""
echo "=== Applying Tekton Tasks ==="
oc apply -f "$REPO_ROOT/ci/tasks/" -n "$NAMESPACE"

echo ""
echo "=== Applying Tekton Pipeline ==="
oc apply -f "$REPO_ROOT/ci/pipelines/" -n "$NAMESPACE"

echo ""
echo "=== Verifying resources ==="
echo "Tasks:"
oc get tasks -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name --no-headers | sed 's/^/  /'
echo ""
echo "Pipelines:"
oc get pipelines -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name --no-headers | sed 's/^/  /'

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Create a cluster secret:  ./scripts/create-cluster-secret.sh"
echo "  2. Run acceptance tests:     ./scripts/run-acceptance-tests.sh"
