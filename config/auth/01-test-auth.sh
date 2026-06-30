#!/bin/bash
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

echo "=== Setting up htpasswd test accounts ==="

# --- Step 1: Create or update htpass-secret ---
if oc get secret htpass-secret -n openshift-config -o jsonpath='{.data.htpasswd}' &>/dev/null; then
  echo "Secret htpass-secret exists — merging test users"
  EXISTING=$(oc get secret htpass-secret -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 -d)
  MERGED=$(mktemp)
  echo "$EXISTING" > "$MERGED"
  while IFS= read -r line; do
    user="${line%%:*}"
    if ! grep -q "^${user}:" "$MERGED"; then
      echo "$line" >> "$MERGED"
    fi
  done < "$DIR/users.htpasswd"
  oc create secret generic htpass-secret \
    --from-file=htpasswd="$MERGED" -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  rm -f "$MERGED"
else
  echo "Creating htpass-secret"
  oc create secret generic htpass-secret \
    --from-file=htpasswd="$DIR/users.htpasswd" -n openshift-config
fi

# --- Step 2: Add htpasswd identity provider (preserve existing providers) ---
EXISTING_PROVIDERS=$(oc get oauth cluster -o json | python3 -c "
import json, sys
oauth = json.load(sys.stdin)
providers = oauth.get('spec', {}).get('identityProviders', [])
has_htpasswd = any(p.get('name') == 'htpasswd' for p in providers)
if has_htpasswd:
    print('EXISTS')
else:
    print('MISSING')
" 2>/dev/null || echo "MISSING")

if [[ "$EXISTING_PROVIDERS" == "EXISTS" ]]; then
  echo "htpasswd identity provider already configured"
else
  echo "Adding htpasswd identity provider (preserving existing providers)"
  HTPASSWD_PROVIDER='{"name":"htpasswd","challenge":true,"login":true,"mappingMethod":"add","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}'
  HAS_ARRAY=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders}' 2>/dev/null)
  if [[ -z "$HAS_ARRAY" || "$HAS_ARRAY" == "null" ]]; then
    oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":[${HTPASSWD_PROVIDER}]}}"
  else
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${HTPASSWD_PROVIDER}}]"
  fi
fi

# Set long-lived tokens for CI
oc patch oauth cluster --type=merge -p '{"spec":{"tokenConfig":{"accessTokenMaxAgeSeconds":8640000}}}'

# --- Step 3: Create cluster/namespace role bindings ---
oc get clusterrolebinding pipelinesdeveloper_basic_user &>/dev/null \
  || oc create clusterrolebinding pipelinesdeveloper_basic_user --clusterrole=basic-user --user=pipelinesdeveloper
oc get clusterrolebinding consoledeveloper_self_provisioner &>/dev/null \
  || oc create clusterrolebinding consoledeveloper_self_provisioner --clusterrole=self-provisioner --user=consoledeveloper
oc get clusterrolebinding consoledeveloper_view &>/dev/null \
  || oc create clusterrolebinding consoledeveloper_view --clusterrole=view --user=consoledeveloper

# non-admin test users need edit access to openshift-pipelines for creating
# Tekton resources (TriggerTemplates, PipelineRuns, etc.) during test execution
for ns in openshift-pipelines; do
  for u in user user1 user2 user3 user4 user5 user6 user7 user8 user9 test pipelinesdeveloper; do
    oc get rolebinding "${u}-edit" -n "$ns" &>/dev/null 2>&1 \
      || oc create rolebinding "${u}-edit" --clusterrole=edit --user="$u" -n "$ns" 2>/dev/null || true
  done
done
echo "Non-admin edit bindings created in openshift-pipelines"

# --- Step 4: Wait for OAuth rollout ---
echo "Waiting for authentication operator to apply changes..."
oc wait co/authentication --for=condition=Progressing=True --timeout=60s 2>/dev/null || true
oc wait co/authentication --for=condition=Progressing=False --timeout=5m 2>/dev/null || true
oc wait co/authentication --for=condition=Available=True --timeout=5m

# --- Step 5: Verify non-admin login ---
echo "Verifying htpasswd users can authenticate..."
APISERVER=$(oc whoami --show-server)
retries=0
while (( retries < 12 )); do
  if oc login -u user -p user "$APISERVER" --insecure-skip-tls-verify=true &>/dev/null; then
    echo "  user login: OK"
    break
  fi
  retries=$((retries + 1))
  echo "  user login not ready yet (attempt ${retries}/12)..."
  sleep 15
done

if (( retries >= 12 )); then
  echo "WARNING: user login still failing after 3 minutes — OAuth may need more time"
else
  oc login -u pipelinesdeveloper -p developer "$APISERVER" --insecure-skip-tls-verify=true &>/dev/null \
    && echo "  pipelinesdeveloper login: OK" || echo "  WARNING: pipelinesdeveloper login failed"
  oc login -u consoledeveloper -p developer "$APISERVER" --insecure-skip-tls-verify=true &>/dev/null \
    && echo "  consoledeveloper login: OK" || echo "  WARNING: consoledeveloper login failed"
fi

# Re-login as admin
oc login -u "$(oc whoami 2>/dev/null || echo kubeadmin)" "$APISERVER" --insecure-skip-tls-verify=true &>/dev/null 2>&1 || true
echo "=== Test accounts ready ==="
