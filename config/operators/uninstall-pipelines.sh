#!/usr/bin/env bash
# Uninstall OpenShift Pipelines operator and all related cluster resources.
# Usage:
#   ./uninstall-pipelines.sh          # normal uninstall
#   ./uninstall-pipelines.sh --force  # force delete CRDs, patch finalizers, nuke everything
set -euo pipefail

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

die() { echo "ERROR: $*" >&2; exit 1; }

wait_absent() {
  local desc wait_secs deadline
  desc=$1
  wait_secs=${2:-300}
  deadline=$((SECONDS + wait_secs))
  shift 2
  while (( SECONDS < deadline )); do
    if ! "$@" >/dev/null 2>&1; then return 0; fi
    echo "  waiting for ${desc}..." >&2
    sleep 5
  done
  if [[ "$FORCE" == true ]]; then
    echo "  WARNING: timeout waiting for ${desc} — continuing (--force)" >&2
    return 0
  fi
  die "timeout waiting for ${desc} removal"
}

has_any() { oc get "$1" --no-headers 2>/dev/null | grep -q .; }

force_delete() {
  local kind=$1 name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    oc patch "$name" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    oc delete "$name" --ignore-not-found --grace-period=0 --force --timeout=60s 2>/dev/null || true
  done < <(oc get "$kind" -o name 2>/dev/null || true)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    oc patch "$name" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    oc delete "$name" --ignore-not-found --grace-period=0 --force 2>/dev/null || true
  done < <(oc get "$kind" -o name 2>/dev/null || true)
}

echo "=== Uninstalling OpenShift Pipelines operator${FORCE:+ (--force)} ==="

# Step 1: Delete TektonConfig and sub-CRs
for cr in tektonconfig/config tektonaddon/addon tektonpipeline/pipeline tektontrigger/trigger \
          tektonchain/chain tektonresult/result tektonpruner/pruner \
          openshiftpipelinesascode/pipelines-as-code manualapprovalgate/manual-approval-gate; do
  oc patch "$cr" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  oc delete "$cr" --ignore-not-found --timeout=120s 2>/dev/null || true
done
wait_absent TektonConfig 120 oc get tektonconfig config

# Step 2: Delete InstallerSets and remaining CRs
for kind in tektoninstallersets tektonpipelines tektontriggers tektonchains tektonresults \
            tektonpruners tektonaddons tektonhubs openshiftpipelinesascodes \
            manualapprovalgates syncerservices tektonschedulers tektonmulticlusterproxyaaes; do
  if has_any "$kind"; then
    echo "Deleting ${kind}..."
    force_delete "$kind"
  fi
done
if has_any tektoninstallersets; then
  echo "Force deleting remaining tektoninstallersets..."
  force_delete tektoninstallersets
fi
wait_absent TektonInstallerSets 120 bash -c 'oc get tektoninstallersets --no-headers 2>/dev/null | grep -q .'

# Step 3: Delete subscription + CSV + InstallPlans
oc delete subscription openshift-pipelines-operator-rh -n openshift-operators --ignore-not-found --timeout=60s
for ns in openshift-operators pipelines-ci; do
  while IFS= read -r csv; do
    [[ -n "$csv" ]] || continue
    echo "Deleting ${csv} in ${ns}"
    oc delete "$csv" -n "$ns" --ignore-not-found --timeout=120s || true
  done < <(oc get csv -n "$ns" -o name 2>/dev/null | grep openshift-pipelines-operator || true)
done
while IFS= read -r ip; do
  [[ -n "$ip" ]] || continue
  oc delete "$ip" -n openshift-operators --ignore-not-found 2>/dev/null || true
done < <(oc get installplan -n openshift-operators -o name 2>/dev/null || true)

# Step 4: Delete openshift-pipelines namespace
if oc get namespace openshift-pipelines >/dev/null 2>&1; then
  echo "Deleting namespace openshift-pipelines..."
  oc delete all --all -n openshift-pipelines --force --grace-period=0 2>/dev/null || true
  oc delete sa,rolebinding,role,configmap,secret --all -n openshift-pipelines --ignore-not-found 2>/dev/null || true
  oc delete namespace openshift-pipelines --ignore-not-found --timeout=120s 2>/dev/null || true
  if oc get namespace openshift-pipelines >/dev/null 2>&1; then
    echo "Clearing finalizers on openshift-pipelines..."
    oc get namespace openshift-pipelines -o json \
      | python3 -c 'import json,sys; n=json.load(sys.stdin); n["spec"]["finalizers"]=[]; print(json.dumps(n))' \
      | oc replace --raw "/api/v1/namespaces/openshift-pipelines/finalize" -f - 2>/dev/null || true
  fi
  wait_absent openshift-pipelines-namespace 120 oc get namespace openshift-pipelines
fi

# Step 5 (--force only): Delete CRDs, ClusterRoles, webhooks
if [[ "$FORCE" == true ]]; then
  echo "=== Force: Deleting Tekton CRDs ==="
  for crd in $(oc get crd -o name 2>/dev/null | grep -E 'tekton|pipelines-as-code'); do
    echo "  patching + deleting ${crd##*/}"
    oc patch "$crd" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    oc delete "$crd" --force --grace-period=0 --timeout=30s 2>/dev/null || true
  done
  # Second pass for any stuck CRDs
  for crd in $(oc get crd -o name 2>/dev/null | grep -E 'tekton|pipelines-as-code'); do
    oc patch "$crd" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    oc delete "$crd" --force --grace-period=0 2>/dev/null || true
  done

  echo "=== Force: Deleting ClusterRoles/Bindings ==="
  oc get clusterrolebinding -o name 2>/dev/null | grep -iE 'tekton|pipelines|openshift-pipelines' \
    | while read -r crb; do oc delete "$crb" --ignore-not-found 2>/dev/null || true; done
  oc get clusterrole -o name 2>/dev/null | grep -iE 'tekton|pipelines|openshift-pipelines' \
    | while read -r cr; do oc delete "$cr" --ignore-not-found 2>/dev/null || true; done

  echo "=== Force: Deleting webhooks ==="
  oc get validatingwebhookconfigurations -o name 2>/dev/null | grep -i tekton \
    | while read -r w; do oc delete "$w" --ignore-not-found 2>/dev/null || true; done
  oc get mutatingwebhookconfigurations -o name 2>/dev/null | grep -i tekton \
    | while read -r w; do oc delete "$w" --ignore-not-found 2>/dev/null || true; done
fi

# Verify
echo "=== Verifying uninstall ==="
left=""
if [[ "$FORCE" == true ]]; then
  n=$(oc get crd 2>/dev/null | grep -c tekton || echo 0)
  [[ "$n" -eq 0 ]] || left+="crds(${n}) "
fi
for kind in tektonconfigs tektoninstallersets tektonpipelines tektontriggers tektonchains tektonresults; do
  n=$(oc get "$kind" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${n:-0}" -eq 0 ]] || left+="${kind}(${n}) "
done
for ns in openshift-operators pipelines-ci; do
  oc get csv -n "$ns" -o name 2>/dev/null | grep -q openshift-pipelines-operator && left+="csv(${ns}) "
done
oc get namespace openshift-pipelines >/dev/null 2>&1 && left+="openshift-pipelines-ns "
oc get subscription openshift-pipelines-operator-rh -n openshift-operators >/dev/null 2>&1 && left+="subscription "

[[ -z "$left" ]] || die "resources remain: ${left}"
echo "OK: all OpenShift Pipelines operator resources removed"
