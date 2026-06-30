#!/usr/bin/env bash
cluster_platforms() {
  case "$(printf '%s' "${INSTALLER:-none}" | tr '[:upper:]' '[:lower:]')" in
    cluster-platforms|cp) return 0 ;; *) return 1 ;; esac
}

validate_cluster_env() {
  [[ -n "${APISERVER:-}" ]] || { echo "ERROR: APISERVER required in .env" >&2; return 1; }

  [[ -n "${KUBEADMIN_PASSWORD:-}" || -n "${OC_TOKEN:-}" ]] || {
    echo "ERROR: KUBEADMIN_PASSWORD or OC_TOKEN required in .env" >&2
    return 1
  }

  if cluster_platforms && [[ -n "${OC_TOKEN:-}" && -n "${CLUSTER_CA_CERT:-}" ]]; then
    local ca="${CLUSTER_CA_CERT}" root="${REPO_ROOT:-.}"
    [[ "$ca" != /* ]] && ca="${root}/${ca}"
    [[ -f "$ca" ]] || {
      echo "ERROR: CLUSTER_CA_CERT file not found: $ca" >&2
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

  if [[ -n "${KUBEADMIN_PASSWORD:-}" ]]; then
    echo "Logging in to ${APISERVER} as ${KUBEADMIN_USER:-kubeadmin}..."
    oc login -u "${KUBEADMIN_USER:-kubeadmin}" -p "$KUBEADMIN_PASSWORD" \
      "$APISERVER" --insecure-skip-tls-verify=true
  elif [[ -n "${OC_TOKEN:-}" ]]; then
    local ca_flag="--insecure-skip-tls-verify=true"
    local ca
    if ca=$(cluster_ca_path 2>/dev/null); then
      ca_flag="--certificate-authority=${ca}"
    fi
    echo "Logging in to ${APISERVER} with OC_TOKEN..."
    oc login --server="${APISERVER}" --token="${OC_TOKEN}" ${ca_flag}
  fi
  echo "  Authenticated as $(oc whoami)"
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
  if [[ -n "${OC_TOKEN:-}" ]]; then
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

validate_operator_env() {
  local env="${OPERATOR_ENVIRONMENT:-prod}" src="${CATALOG_SOURCE:-redhat-operators}"
  local idx="${KONFLUX_INDEX_IMAGE:-}"
  case "${env,,}" in
    prod)
      if [[ "$src" != "redhat-operators" ]]; then
        echo "ERROR: OPERATOR_ENVIRONMENT=prod requires CATALOG_SOURCE=redhat-operators (got: ${src})" >&2
        return 1
      fi
      ;;
    stage|pre-stage)
      if [[ "$src" == "redhat-operators" ]]; then
        echo "ERROR: OPERATOR_ENVIRONMENT=${env} requires CATALOG_SOURCE=custom-operators (got: ${src})" >&2
        return 1
      fi
      if [[ -z "$idx" ]]; then
        echo "ERROR: OPERATOR_ENVIRONMENT=${env} requires KONFLUX_INDEX_IMAGE to be set" >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR: OPERATOR_ENVIRONMENT must be prod, stage, or pre-stage (got: ${env})" >&2
      return 1
      ;;
  esac
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
