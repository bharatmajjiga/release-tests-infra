#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$REPO_ROOT/secrets"
NAMESPACE="${NAMESPACE:-pipelines-ci}"
SOURCE_NS="${SOURCE_NS:-$NAMESPACE}"
SOURCE_SECRET="${SOURCE_SECRET:-cluster-creds}"

# --- Load env vars from .env (locally) or cluster-creds (Vault) ---
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "Loading env vars from .env"
  set -a; source "$REPO_ROOT/.env"; set +a
elif oc get secret "$SOURCE_SECRET" -n "$SOURCE_NS" &>/dev/null; then
  echo "Loading env vars from $SOURCE_SECRET in $SOURCE_NS"
  eval "$(oc get secret "$SOURCE_SECRET" -n "$SOURCE_NS" -o jsonpath='{.data}' \
    | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
for k, v in d.items():
    if not k.replace('_','').isalnum(): continue
    val = base64.b64decode(v).decode().replace('\"','\\\\\"').replace('\n','\\\\n')
    print(f'export {k}=\"{val}\"')
" 2>/dev/null)" || true
else
  echo "ERROR: No .env file or $SOURCE_SECRET secret found in $SOURCE_NS."
  echo "Create .env from env.template or set up the External Secrets Operator first."
  exit 1
fi

# --- Derived values ---
if [[ "$OSTYPE" == "darwin"* ]]; then
  ENCODE_BASE64="base64"
else
  ENCODE_BASE64="base64 -w 0"
fi

QUAY_AUTH=$(echo -n "${QUAY_USER:-}:${QUAY_PASS:-}" | $ENCODE_BASE64)

echo ""
echo "=== Creating secrets in namespace: $NAMESPACE ==="

echo -e "\nConfiguring AWS credentials"
sed -e "s/\$AWS_ACCESS_KEY_ID/${AWS_ACCESS_KEY:-}/" \
    -e "s/\$AWS_SECRET_ACCESS_KEY/${AWS_ACCESS_SECRET:-}/" \
    "$SECRETS_DIR/aws.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring GitHub secret"
sed -e "s|\$GITHUB_TOKEN|${GITHUB_TOKEN:-}|" \
    "$SECRETS_DIR/github.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring PAC GitHub token secret"
sed -e "s|\$PAC_GITHUB_TOKEN|${PAC_GITHUB_TOKEN:-}|" \
    -e "s|\$PAC_GITHUB_ORG|${PAC_GITHUB_ORG:-}|" \
    -e "s|\$PAC_GITHUB_WEBHOOK_TOKEN|${PAC_GITHUB_WEBHOOK_TOKEN:-}|" \
    "$SECRETS_DIR/pac-github-token.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring GitLab PAC secret"
sed -e "s/\$GITLAB_TOKEN/${GITLAB_TOKEN:-}/" \
    -e "s/\$GITLAB_GROUP_NAMESPACE/${GITLAB_GROUP_NAMESPACE:-}/" \
    -e "s/\$GITLAB_PROJECT_ID/${GITLAB_PROJECT_ID:-}/" \
    -e "s/\$GITLAB_WEBHOOK_TOKEN/${GITLAB_WEBHOOK_TOKEN:-}/" \
    "$SECRETS_DIR/pac-gitlab.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring GitLab SSH key"
ENCODED_GITLAB_SSH_PRIVATE_KEY=$(echo -n "${ssh_privatekey:-}" | $ENCODE_BASE64 2>/dev/null || echo "")
sed -e "s/\$ENCODED_GITLAB_SSH_PRIVATE_KEY/${ENCODED_GITLAB_SSH_PRIVATE_KEY:-}/" \
    "$SECRETS_DIR/gitlab-ssh-private-key.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring GitHub app secret (PAC)"
ENCODED_GITHUB_APP_ID=${ENCODED_GITHUB_APP_ID:-}
ENCODED_GITHUB_APP_PRIVATE_KEY=${ENCODED_GITHUB_APP_PRIVATE_KEY:-}
ENCODED_GITHUB_WEBHOOK_SECRET=${ENCODED_GITHUB_WEBHOOK_SECRET:-}
sed -e "s/\$ENCODED_GITHUB_APP_PRIVATE_KEY/${ENCODED_GITHUB_APP_PRIVATE_KEY}/" \
    -e "s/\$ENCODED_GITHUB_WEBHOOK_SECRET/${ENCODED_GITHUB_WEBHOOK_SECRET}/" \
    -e "s/\$ENCODED_GITHUB_APP_ID/${ENCODED_GITHUB_APP_ID}/" \
    "$SECRETS_DIR/pac-github.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring p12n secrets"
sed -e "s/\$BREW_USER/${BREW_USER:-}/" \
    -e "s/\$BREW_PASS/${BREW_PASS:-}/" \
    -e "s/\$QUAY_USER/${QUAY_USER:-}/" \
    -e "s/\$QUAY_PASS/${QUAY_PASS:-}/" \
    -e "s/\$QUAY_API_TOKEN/${QUAY_API_TOKEN:-}/" \
    "$SECRETS_DIR/p12n.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring Quay docker config"
sed -e "s/\$QUAY_AUTH/${QUAY_AUTH}/" \
    "$SECRETS_DIR/quay-io-dockerconfig.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring Skopeo Quay credentials"
sed -e "s/\$QUAY_USER/${QUAY_USER:-}/" \
    -e "s/\$QUAY_PASS/${QUAY_PASS:-}/" \
    "$SECRETS_DIR/skopeo-copy-quay-creds.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring Mac mini credentials"
sed -e "s|\$MAC_HOSTNAME|${MAC_HOSTNAME:-}|" \
    -e "s|\$MAC_USERNAME|${MAC_USERNAME:-}|" \
    -e "s|\$MAC_PASSWORD|${MAC_PASSWORD:-}|" \
    "$SECRETS_DIR/mac-mini.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring Polarion secrets"
sed -e "s/\$POLARION_USERNAME/${POLARION_USERNAME:-}/" \
    -e "s/\$POLARION_PASSWORD/${POLARION_PASSWORD:-}/" \
    -e "s/\$POLARION_PROJECT/${POLARION_PROJECT:-}/" \
    "$SECRETS_DIR/polarion.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring ReportPortal credentials"
sed -e "s|\$RP_URL|${RP_URL:-}|" \
    -e "s|\$RP_ROBOT_UUID|${RP_ROBOT_UUID:-}|" \
    -e "s|\$RP_PROJECT|${RP_PROJECT:-}|" \
    -e "s|\$RP_SUPERADMIN_UUID|${RP_SUPERADMIN_UUID:-}|" \
    "$SECRETS_DIR/reportportal.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring RHEL subscription secret"
sed -e "s|\$SUBSCRIPTION_USERNAME|${SUBSCRIPTION_USERNAME:-}|" \
    -e "s|\$SUBSCRIPTION_PASSWORD|${SUBSCRIPTION_PASSWORD:-}|" \
    "$SECRETS_DIR/rhel-subscription.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring Slack webhook secret"
sed -e "s|\$SLACK_WEBHOOK_URL|${SLACK_WEBHOOK_URL:-}|" \
    "$SECRETS_DIR/slack.yaml" | oc apply -n "$NAMESPACE" -f -

echo -e "\nConfiguring Uploader secrets"
sed -e "s|\$UPLOADER_USERNAME|${UPLOADER_USERNAME:-}|" \
    -e "s|\$UPLOADER_PASSWORD|${UPLOADER_PASSWORD:-}|" \
    -e "s|\$UPLOADER_HOST|${UPLOADER_HOST:-}|" \
    "$SECRETS_DIR/uploader.yaml" | oc apply -n "$NAMESPACE" -f -

echo ""
echo "=== Secrets in $NAMESPACE ==="
oc get secrets -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name --no-headers \
  | grep -v -E "^(builder|default|deployer|pipeline)-dockercfg" | sed 's/^/  /'
