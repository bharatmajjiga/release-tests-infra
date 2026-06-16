#!/usr/bin/env bash
cluster_platforms() {
  [[ "$(printf '%s' "${CLUSTER_PLATFORMS:-false}" | tr '[:upper:]' '[:lower:]')" == true ]]
}

cluster_platforms_flag() {
  cluster_platforms && echo true || echo false
}

validate_cluster_env() {
  [[ -n "${APISERVER:-}" ]] || { echo "ERROR: APISERVER required in .env" >&2; return 1; }

  if cluster_platforms; then
    [[ -n "${OC_TOKEN:-}" ]] || {
      echo "ERROR: CLUSTER_PLATFORMS=true requires OC_TOKEN in .env" >&2
      return 1
    }
    [[ -n "${CLUSTER_CA_CERT:-}" ]] || {
      echo "ERROR: CLUSTER_PLATFORMS=true requires CLUSTER_CA_CERT in .env" >&2
      return 1
    }
    local ca="${CLUSTER_CA_CERT}" root="${REPO_ROOT:-.}"
    [[ "$ca" != /* ]] && ca="${root}/${ca}"
    [[ -f "$ca" ]] || {
      echo "ERROR: CLUSTER_CA_CERT file not found: $ca" >&2
      return 1
    }
  else
    [[ -n "${KUBEADMIN_PASSWORD:-}" ]] || {
      echo "ERROR: CLUSTER_PLATFORMS=false requires KUBEADMIN_PASSWORD in .env" >&2
      return 1
    }
  fi
}

cluster_ca_path() {
  local root="${REPO_ROOT:-.}" ca="${CLUSTER_CA_CERT:-}"
  [[ -n "$ca" ]] || return 1
  [[ "$ca" != /* ]] && ca="${root}/${ca}"
  [[ -f "$ca" ]] || return 1
  printf '%s' "$ca"
}

cluster_login() {
  validate_cluster_env || return 1

  if cluster_platforms; then
    local ca
    ca=$(cluster_ca_path) || return 1
    echo "Logging in to ${APISERVER} with OC_TOKEN (CLUSTER_PLATFORMS=true)..."
    oc login --server="${APISERVER}" --token="${OC_TOKEN}" --certificate-authority="${ca}"
    echo "  Authenticated as $(oc whoami)"
  else
    echo "Logging in to ${APISERVER} as ${KUBEADMIN_USER:-kubeadmin}..."
    oc login -u "${KUBEADMIN_USER:-kubeadmin}" -p "$KUBEADMIN_PASSWORD" \
      "$APISERVER" --insecure-skip-tls-verify=true
  fi
}

cluster_admin_name() {
  if cluster_platforms; then
    oc whoami 2>/dev/null || echo "cluster-admin"
  else
    echo "${KUBEADMIN_USER:-kubeadmin}"
  fi
}

cluster_admin_token() {
  validate_cluster_env || return 1
  if cluster_platforms; then
    printf '%s' "$OC_TOKEN"
  else
    oc whoami -t
  fi
}

cluster_insecure_tls() {
  cluster_platforms && echo false || echo true
}

secret_cluster_platforms() {
  local name=$1 ns=$2
  oc get secret "$name" -n "$ns" \
    -o go-template='{{index .data "cluster-platforms" | base64decode}}' 2>/dev/null || true
}

# cluster-rzlgf for CLUSTER_NAME=rzlgf (strips accidental cluster- prefix from .env)
cluster_secret_name() {
  [[ -n "${CLUSTER_NAME:-}" ]] || return 1
  local name="${CLUSTER_NAME#cluster-}"
  printf 'cluster-%s' "$name"
}

cluster_secret_exists() {
  local secret ns="${1:-${NAMESPACE:-pipelines-ci}}"
  secret="$(cluster_secret_name)" || return 1
  oc get secret "$secret" -n "$ns" &>/dev/null
}
