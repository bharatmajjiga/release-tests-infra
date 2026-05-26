#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-pipelines-ci}"

echo "=== Create cluster secret in namespace: $NAMESPACE ==="
echo ""

if [[ $# -ge 1 ]]; then
  CLUSTER_NAME="$1"
  API_URL="${2:-$(oc whoami --show-server)}"
  ADMIN_NAME="${3:-kubeadmin}"
  ADMIN_PASSWORD="${4:-$(oc whoami -t)}"
else
  read -rp "Cluster name: " CLUSTER_NAME
  DEFAULT_API=$(oc whoami --show-server 2>/dev/null || echo "")
  read -rp "Cluster API URL [${DEFAULT_API}]: " API_URL
  API_URL="${API_URL:-$DEFAULT_API}"
  read -rp "Admin name [kubeadmin]: " ADMIN_NAME
  ADMIN_NAME="${ADMIN_NAME:-kubeadmin}"
  read -rsp "Admin password (leave empty to use current token): " ADMIN_PASSWORD
  echo ""
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(oc whoami -t)}"
fi

SECRET_NAME="cluster-${CLUSTER_NAME}"

if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'."
  read -rp "Overwrite? [y/N]: " OVERWRITE
  if [[ "${OVERWRITE,,}" != "y" ]]; then
    echo "Skipping secret creation."
    exit 0
  fi
  oc delete secret "$SECRET_NAME" -n "$NAMESPACE"
fi

oc create secret generic "$SECRET_NAME" \
  --from-literal=admin-name="${ADMIN_NAME}" \
  --from-literal=api-url="${API_URL}" \
  --from-literal=insecure-skip-tls-verify=true \
  --from-literal=installer=none \
  --from-literal=kubeadmin-password="${ADMIN_PASSWORD}" \
  --from-literal=admin-token="${ADMIN_PASSWORD}" \
  --from-literal=user-password=user \
  --from-literal=mirror-reg=quay.io \
  -n "$NAMESPACE"

oc label secret "$SECRET_NAME" keep-cluster=true -n "$NAMESPACE"

echo ""
echo "Secret '$SECRET_NAME' created in namespace '$NAMESPACE'."
echo ""
echo "Verify with:"
echo "  oc get secret $SECRET_NAME -n $NAMESPACE -o yaml"
