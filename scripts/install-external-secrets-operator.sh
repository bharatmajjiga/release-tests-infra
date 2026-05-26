#!/usr/bin/env bash
set -euo pipefail

VAULT_TOKEN="${1:-}"
if [[ -z "$VAULT_TOKEN" ]]; then
  echo "Usage: $0 <vault-token>"
  echo ""
  echo "  Provide a Vault token to configure the External Secrets Operator."
  echo "  The token is used to authenticate with https://vault.ci.openshift.org"
  exit 1
fi

ESO_NS="external-secrets-operator"
SECRETS_NS="${SECRETS_NS:-osp-ci-secrets}"
TARGET_NS="${TARGET_NS:-pipelines-ci}"
CHANNEL="${CHANNEL:-stable-v1}"
TIMEOUT="${TIMEOUT:-300}"

echo "=== Installing External Secrets Operator ==="
echo "  Vault secret store namespace: $SECRETS_NS"
echo "  Target secrets namespace:     $TARGET_NS"

# --- Namespaces ---
for ns in "$ESO_NS" "$SECRETS_NS" "$TARGET_NS"; do
  if oc get namespace "$ns" &>/dev/null; then
    echo "  Namespace '$ns' already exists"
  else
    echo "  Creating namespace '$ns'"
    oc create namespace "$ns"
  fi
done

# --- OperatorGroup ---
if oc get operatorgroup -n "$ESO_NS" 2>/dev/null | grep -q external-secrets; then
  echo "  OperatorGroup already exists"
else
  echo "  Creating OperatorGroup"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: external-secrets-operator
  namespace: $ESO_NS
spec:
  targetNamespaces: []
  upgradeStrategy: Default
EOF
fi

# --- Subscription ---
if oc get subscription openshift-external-secrets-operator -n "$ESO_NS" &>/dev/null; then
  echo "  Subscription already exists"
else
  echo "  Creating Subscription (channel: $CHANNEL)"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-external-secrets-operator
  namespace: $ESO_NS
spec:
  channel: $CHANNEL
  name: openshift-external-secrets-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
fi

# --- Wait for CSV ---
echo ""
echo "  Waiting for operator to install (timeout: ${TIMEOUT}s)..."
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  CSV=$(oc get subscription openshift-external-secrets-operator -n "$ESO_NS" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
  if [[ -n "$CSV" ]]; then
    PHASE=$(oc get csv "$CSV" -n "$ESO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Succeeded" ]]; then
      echo "  Operator installed: $CSV"
      break
    fi
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  printf "  ... %ds\n" "$ELAPSED"
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "  ERROR: Timed out waiting for operator. Check:"
  echo "    oc get csv -n $ESO_NS"
  exit 1
fi

# --- Verify operator pods ---
echo ""
echo "=== Operator pods ==="
oc get pods -n "$ESO_NS" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready --no-headers | sed 's/^/  /'

# --- ExternalSecretsConfig ---
echo ""
echo "=== Creating ExternalSecretsConfig ==="
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  name: cluster
spec: {}
EOF

# --- NetworkPolicy ---
echo ""
echo "=== Creating NetworkPolicy for Vault egress ==="
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-vault-egress-for-main-controller
  namespace: external-secrets
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: external-secrets
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 443
          protocol: TCP
EOF

# --- Vault token secret in SECRETS_NS ---
echo ""
echo "=== Creating Vault token secret in $SECRETS_NS ==="
if oc get secret vault-token -n "$SECRETS_NS" &>/dev/null; then
  oc delete secret vault-token -n "$SECRETS_NS"
fi
oc create secret generic vault-token \
  --from-literal=token="${VAULT_TOKEN}" \
  -n "$SECRETS_NS"

# --- SecretStore in SECRETS_NS ---
echo ""
echo "=== Creating SecretStore in $SECRETS_NS ==="
oc apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: $SECRETS_NS
spec:
  provider:
    vault:
      server: "https://vault.ci.openshift.org"
      path: "kv"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
EOF

echo "  Waiting for SecretStore to become ready..."
ELAPSED=0
READY=""
while [[ $ELAPSED -lt 120 ]]; do
  READY=$(oc get secretstore vault-backend -n "$SECRETS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$READY" == "True" ]]; then
    echo "  SecretStore is ready"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ "$READY" != "True" ]]; then
  echo "  WARNING: SecretStore not ready yet. Check:"
  echo "    oc get secretstore vault-backend -n $SECRETS_NS"
  oc get secretstore vault-backend -n "$SECRETS_NS" 2>/dev/null | sed 's/^/    /'
  exit 1
fi

# --- ExternalSecret: cluster-creds in SECRETS_NS ---
echo ""
echo "=== Creating ExternalSecret (cluster-creds) in $SECRETS_NS ==="
oc apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cluster-creds
  namespace: $SECRETS_NS
spec:
  refreshInterval: 30m
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: cluster-creds
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: selfservice/openshift-pipelines/osp-ci-secrets
EOF

echo "  Waiting for ExternalSecret to sync..."
ELAPSED=0
SYNC_STATUS=""
while [[ $ELAPSED -lt 120 ]]; do
  SYNC_STATUS=$(oc get externalsecret cluster-creds -n "$SECRETS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
  if [[ "$SYNC_STATUS" == "SecretSynced" ]]; then
    echo "  ExternalSecret synced successfully"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ "$SYNC_STATUS" != "SecretSynced" ]]; then
  echo "  WARNING: ExternalSecret not synced yet. Check:"
  echo "    oc get externalsecret cluster-creds -n $SECRETS_NS"
  oc get externalsecret cluster-creds -n "$SECRETS_NS" 2>/dev/null | sed 's/^/    /'
  exit 1
fi

# --- Create individual secrets in TARGET_NS from cluster-creds ---
echo ""
echo "=== Creating individual secrets in $TARGET_NS from cluster-creds ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_NS="$SECRETS_NS" NAMESPACE="$TARGET_NS" "$SCRIPT_DIR/create-secrets.sh"

echo ""
echo "=== External Secrets Operator installed and configured ==="
echo "  SecretStore & ExternalSecret in: $SECRETS_NS"
echo "  Individual secrets created in:   $TARGET_NS"
oc get secretstore,externalsecret -n "$SECRETS_NS" | sed 's/^/  /'
