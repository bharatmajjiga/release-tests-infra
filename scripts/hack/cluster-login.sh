#!/usr/bin/env bash
cluster_platforms() {
  [[ "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" == cluster-platforms ]]
}

validate_cluster_env() {
  [[ -n "${APISERVER:-}" ]] || { echo "ERROR: APISERVER required in .env" >&2; return 1; }

  if cluster_platforms; then
    [[ -n "${OC_TOKEN:-}" ]] || {
      echo "ERROR: INSTALLER=cluster-platforms requires OC_TOKEN in .env" >&2
      return 1
    }
    [[ -n "${CLUSTER_CA_CERT:-}" ]] || {
      echo "ERROR: INSTALLER=cluster-platforms requires CLUSTER_CA_CERT in .env" >&2
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
      echo "ERROR: INSTALLER=${INSTALLER:-none} requires KUBEADMIN_PASSWORD in .env" >&2
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
    echo "Logging in to ${APISERVER} with OC_TOKEN (INSTALLER=cluster-platforms)..."
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

cluster_installer() {
  cluster_platforms && echo cluster-platforms || echo "${INSTALLER:-none}"
}

is_provisioned_installer() {
  case "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" in
    aws-ipi|rosa|aro) return 0 ;; *) return 1 ;; esac
}

validate_cluster_env_or_provisioned() {
  if is_provisioned_installer; then
    echo "INSTALLER=${INSTALLER} — cluster will be provisioned by pipeline"
    return 0
  fi
  validate_cluster_env
}

secret_installer() {
  local name=$1 ns=$2 val legacy
  val=$(oc get secret "$name" -n "$ns" \
    -o go-template='{{index .data "installer" | base64decode}}' 2>/dev/null || true)
  if [[ -n "$val" && "$val" != none ]]; then
    printf '%s' "$val"
    return 0
  fi
  legacy=$(oc get secret "$name" -n "$ns" \
    -o go-template='{{index .data "cluster-platforms" | base64decode}}' 2>/dev/null || true)
  if [[ "$(printf '%s' "$legacy" | tr '[:upper:]' '[:lower:]')" == true ]]; then
    echo cluster-platforms
  else
    echo none
  fi
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
