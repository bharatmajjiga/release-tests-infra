#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-pipelines-ci}"

# --- Load .env ---
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

# --- Resolve values (env > prompt) ---
API_URL="${APISERVER:-$(oc whoami --show-server 2>/dev/null || echo "")}"
KUBE_PASS="${KUBEADMIN_PASSWORD:-}"
KUBE_USER="${KUBEADMIN_USER:-kubeadmin}"
CLUSTER_NAME="${CLUSTER_NAME:-$(echo "$API_URL" | sed -n 's|https\{0,1\}://api\.\([^.]*\)\..*|\1|p')}"
if [[ -z "$CLUSTER_NAME" ]]; then
  read -rp "Cluster name: " CLUSTER_NAME
fi

echo "=== Setting up namespace: $NAMESPACE ==="
oc get namespace "$NAMESPACE" &>/dev/null || oc new-project "$NAMESPACE"
oc project "$NAMESPACE"

# --- Cluster secret ---
SECRET_NAME="cluster-${CLUSTER_NAME}"
echo "Cluster: $CLUSTER_NAME"

if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'. Skipping creation."
else
  if [[ -z "$KUBE_PASS" ]]; then
    echo "ERROR: KUBEADMIN_PASSWORD not set. Add it to .env"
    exit 1
  fi

  echo "=== Verifying cluster login ==="
  oc login -u "${KUBE_USER}" -p "${KUBE_PASS}" "${API_URL}" --insecure-skip-tls-verify=true
  OC_TOKEN=$(oc whoami -t)
  echo "  Login successful ($(oc whoami) @ ${API_URL})"

  oc create secret generic "$SECRET_NAME" \
    --from-literal=admin-name="${KUBE_USER}" \
    --from-literal=api-url="${API_URL}" \
    --from-literal=admin-token="${OC_TOKEN}" \
    --from-literal=kubeadmin-password="${KUBE_PASS}" \
    --from-literal=user-password="${USER_PASSWORD:-user}" \
    --from-literal=insecure-skip-tls-verify=true \
    --from-literal=installer=none \
    --from-literal=mirror-reg=quay.io \
    -n "$NAMESPACE"
  oc label secret "$SECRET_NAME" keep-cluster=true -n "$NAMESPACE"
  echo "Created secret '$SECRET_NAME'"
fi

# --- Tekton resources ---
echo "=== Applying Tekton Tasks & Pipeline ==="
oc apply -f "$REPO_ROOT/ci/tasks/" -n "$NAMESPACE"
oc apply -f "$REPO_ROOT/ci/pipelines/" -n "$NAMESPACE"

oc get tasks,pipelines -n "$NAMESPACE" -o custom-columns=KIND:.kind,NAME:.metadata.name --no-headers | sed 's/^/  /'

echo "=== Setup complete ==="
echo "Run acceptance tests:"
echo "  oc create -f ci/pipelineruns/acceptance-tests-install.yaml -n $NAMESPACE"
