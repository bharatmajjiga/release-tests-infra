#!/usr/bin/env bash
# Scan AWS for orphaned clusters tagged with pipelines-ci=true and destroy them.
# Runnable from any machine with AWS CLI credentials and openshift-install.
set -euo pipefail

MAX_AGE_HOURS="${MAX_AGE_HOURS:-6}"
AWS_REGION="${AWS_REGION:-us-east-2}"
DRY_RUN="${DRY_RUN:-false}"
ARCH="${ARCH:-amd64}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v aws >/dev/null || die "aws CLI required"

echo "=== Scanning AWS ${AWS_REGION} for orphaned pipelines-ci clusters older than ${MAX_AGE_HOURS}h ==="

instances_json=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:pipelines-ci,Values=true" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,Tags:Tags}' \
  --output json 2>/dev/null || echo "[]")

declare -A clusters_seen
now_epoch=$(date -u +%s)

while IFS= read -r instance; do
  [[ -z "$instance" || "$instance" == "null" ]] && continue

  cluster_name=$(echo "$instance" | python3 -c "
import sys, json
tags = {t['Key']: t['Value'] for t in json.load(sys.stdin).get('Tags', [])}
print(tags.get('cluster-name', ''))
" 2>/dev/null || true)

  [[ -z "$cluster_name" ]] && continue
  [[ -n "${clusters_seen[$cluster_name]:-}" ]] && continue
  clusters_seen[$cluster_name]=1

  created_at=$(echo "$instance" | python3 -c "
import sys, json
tags = {t['Key']: t['Value'] for t in json.load(sys.stdin).get('Tags', [])}
print(tags.get('created-at', ''))
" 2>/dev/null || true)

  if [[ -z "$created_at" ]]; then
    echo "  SKIP ${cluster_name}: no created-at tag"
    continue
  fi

  created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo 0)
  age_hours=$(( (now_epoch - created_epoch) / 3600 ))

  if (( age_hours < MAX_AGE_HOURS )); then
    echo "  SKIP ${cluster_name}: ${age_hours}h old (< ${MAX_AGE_HOURS}h threshold)"
    continue
  fi

  echo "  ORPHAN ${cluster_name}: ${age_hours}h old — will destroy"

  infra_id=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:cluster-name,Values=${cluster_name}" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[0].Instances[0].Tags' --output json 2>/dev/null \
    | python3 -c "
import sys, json
tags = {t['Key']: t['Value'] for t in json.load(sys.stdin)}
for k in tags:
    if k.startswith('kubernetes.io/cluster/'):
        print(k.split('/')[-1])
        break
" 2>/dev/null || true)

  if [[ -z "$infra_id" ]]; then
    echo "    WARNING: could not determine infraID for ${cluster_name} — skipping"
    continue
  fi

  echo "    infraID: ${infra_id}"
  echo "    region:  ${AWS_REGION}"

  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "    DRY_RUN: would destroy ${cluster_name} (infraID=${infra_id})"
    continue
  fi

  tmpdir=$(mktemp -d)
  cat > "${tmpdir}/metadata.json" <<EOMETA
{
  "clusterName": "${cluster_name}",
  "infraID": "${infra_id}",
  "aws": {
    "region": "${AWS_REGION}",
    "identifier": [
      {"kubernetes.io/cluster/${infra_id}": "owned"}
    ]
  }
}
EOMETA

  if ! command -v openshift-install &>/dev/null; then
    MIRROR="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/stable"
    echo "    Downloading openshift-install..."
    curl -sL "${MIRROR}/openshift-install-linux.tar.gz" | tar xz -C /usr/local/bin openshift-install
  fi

  echo "    Running openshift-install destroy cluster..."
  openshift-install destroy cluster --dir="${tmpdir}" --log-level=info 2>&1 | tail -20 || {
    echo "    WARNING: destroy failed for ${cluster_name}"
  }

  rm -rf "${tmpdir}"
  echo "    Destroyed ${cluster_name}"
done < <(echo "$instances_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for inst in data:
    print(json.dumps(inst))
" 2>/dev/null)

echo "=== Orphan scan complete ==="
