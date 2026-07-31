#!/usr/bin/env bash
# Setup GCS bucket for CI artifact storage (free tier optimized).
# Creates bucket, lifecycle rule, service account, and K8s secret.
#
# Prerequisites:
#   - gcloud CLI authenticated (gcloud auth login)
#   - oc logged in to management cluster
#
# Usage:
#   ./scripts/hack/setup-gcs-artifacts.sh                    # Interactive setup
#   GCS_PROJECT=pipelines-qe ./scripts/hack/setup-gcs-artifacts.sh  # Non-interactive
#   ./scripts/hack/setup-gcs-artifacts.sh --create-secret    # Only create K8s secret (bucket exists)
#   ./scripts/hack/setup-gcs-artifacts.sh --verify           # Verify setup and upload test artifact
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACE="${NAMESPACE:-pipelines-ci}"

# Defaults (free-tier optimized: us-east1, us-west1, or us-central1)
GCS_PROJECT="${GCS_PROJECT:-pipelines-qe}"
GCS_BUCKET="${GCS_BUCKET:-ospqa-ci-artifacts}"
GCS_LOCATION="${GCS_LOCATION:-us-east1}"
GCS_SA_NAME="${GCS_SA_NAME:-ci-artifacts-uploader}"
GCS_RETENTION_DAYS="${GCS_RETENTION_DAYS:-30}"
SA_KEY_FILE="${SA_KEY_FILE:-${REPO_ROOT}/.gcs-sa-key.json}"

die() { echo "ERROR: $*" >&2; exit 1; }

create_secret_only=false
verify_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-secret) create_secret_only=true; shift ;;
    --verify) verify_only=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--create-secret | --verify]"
      echo ""
      echo "  (no args)       Full setup: bucket + SA + lifecycle + K8s secret"
      echo "  --create-secret Only create K8s secret (requires SA key at ${SA_KEY_FILE})"
      echo "  --verify        Verify GCS setup, upload test artifact, print URL"
      echo ""
      echo "Environment:"
      echo "  GCS_PROJECT        GCP project (default: pipelines-qe)"
      echo "  GCS_BUCKET         Bucket name (default: ospqa-ci-artifacts)"
      echo "  GCS_LOCATION       Bucket location (default: us-east1, free-tier eligible)"
      echo "  GCS_RETENTION_DAYS Auto-delete after N days (default: 30)"
      echo "  SA_KEY_FILE        Path to SA key file (default: .gcs-sa-key.json)"
      echo "  NAMESPACE          K8s namespace (default: pipelines-ci)"
      exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

# --- Verify mode ---
if [[ "$verify_only" == true ]]; then
  echo "=== Verifying GCS artifact storage setup ==="

  echo "1. Checking gcloud auth..."
  gcloud auth list --filter=status:ACTIVE --format="value(account)" || die "gcloud not authenticated"

  echo "2. Checking bucket gs://${GCS_BUCKET}..."
  gcloud storage ls "gs://${GCS_BUCKET}/" >/dev/null 2>&1 || die "Bucket gs://${GCS_BUCKET} not accessible"
  echo "   OK: bucket exists and is accessible"

  echo "3. Checking lifecycle rules..."
  lifecycle=$(gcloud storage buckets describe "gs://${GCS_BUCKET}" --format="json(lifecycle)" 2>/dev/null)
  if echo "$lifecycle" | grep -q "Delete"; then
    echo "   OK: lifecycle delete rule configured"
  else
    echo "   WARNING: no delete lifecycle rule found"
  fi

  echo "4. Checking K8s secret..."
  if oc get secret gcs-artifacts -n "$NAMESPACE" &>/dev/null; then
    echo "   OK: secret gcs-artifacts exists in ${NAMESPACE}"
  else
    echo "   WARNING: secret gcs-artifacts not found in ${NAMESPACE}"
  fi

  echo "5. Uploading test artifact..."
  test_file=$(mktemp)
  echo "test-upload: pass ($(date -u '+%Y-%m-%d %H:%M UTC'))" > "$test_file"
  gcloud storage cp "$test_file" "gs://${GCS_BUCKET}/CI/_verify/test.result" --quiet
  rm -f "$test_file"

  VERIFY_URL="https://storage.googleapis.com/${GCS_BUCKET}/CI/_verify/test.result"
  echo ""
  echo "=== VERIFICATION COMPLETE ==="
  echo "  Test artifact: ${VERIFY_URL}"
  echo ""
  if curl -sf "$VERIFY_URL" >/dev/null 2>&1; then
    echo "  Public access: OK (accessible without auth)"
  else
    echo "  Public access: NOT configured (requires gcloud auth to view)"
    echo "  To enable: gcloud storage buckets add-iam-policy-binding gs://${GCS_BUCKET} --member=allUsers --role=roles/storage.objectViewer"
  fi

  echo ""
  echo "  Cleaning up test artifact..."
  gcloud storage rm "gs://${GCS_BUCKET}/CI/_verify/test.result" --quiet 2>/dev/null || true
  echo "  Done."
  exit 0
fi

# --- Create K8s secret only ---
if [[ "$create_secret_only" == true ]]; then
  [[ -f "$SA_KEY_FILE" ]] || die "SA key file not found: ${SA_KEY_FILE}\n  Run full setup first, or provide SA_KEY_FILE=/path/to/key.json"
  echo "=== Creating K8s secret gcs-artifacts in ${NAMESPACE} ==="
  oc create secret generic gcs-artifacts \
    --from-file=sa-key.json="$SA_KEY_FILE" \
    --from-literal=bucket="$GCS_BUCKET" \
    --from-literal=project="$GCS_PROJECT" \
    --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
  echo "  Secret gcs-artifacts created/updated in ${NAMESPACE}"
  exit 0
fi

# --- Full setup ---
echo "=== GCS Artifact Storage Setup (Free Tier Optimized) ==="
echo "  Project:   ${GCS_PROJECT}"
echo "  Bucket:    gs://${GCS_BUCKET}"
echo "  Location:  ${GCS_LOCATION} (free-tier eligible)"
echo "  Retention: ${GCS_RETENTION_DAYS} days (auto-delete)"
echo ""

command -v gcloud >/dev/null || die "gcloud CLI required — https://cloud.google.com/sdk/docs/install"
command -v oc >/dev/null || die "oc CLI required"

echo "1. Setting GCP project..."
gcloud config set project "$GCS_PROJECT" --quiet

echo "2. Creating bucket gs://${GCS_BUCKET} (if not exists)..."
if gcloud storage ls "gs://${GCS_BUCKET}/" >/dev/null 2>&1; then
  echo "   Bucket already exists, skipping creation."
else
  gcloud storage buckets create "gs://${GCS_BUCKET}" \
    --location="$GCS_LOCATION" \
    --uniform-bucket-level-access \
    --default-storage-class=STANDARD \
    --quiet
  echo "   Bucket created."
fi

echo "3. Configuring lifecycle rule (delete after ${GCS_RETENTION_DAYS} days)..."
LIFECYCLE_FILE=$(mktemp)
cat > "$LIFECYCLE_FILE" <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {"age": ${GCS_RETENTION_DAYS}}
      }
    ]
  }
}
EOF
gcloud storage buckets update "gs://${GCS_BUCKET}" --lifecycle-file="$LIFECYCLE_FILE" --quiet
rm -f "$LIFECYCLE_FILE"
echo "   Lifecycle rule: auto-delete after ${GCS_RETENTION_DAYS} days."

echo "4. Creating service account ${GCS_SA_NAME}..."
SA_EMAIL="${GCS_SA_NAME}@${GCS_PROJECT}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  echo "   Service account already exists."
else
  gcloud iam service-accounts create "$GCS_SA_NAME" \
    --display-name="CI Artifacts Uploader" \
    --description="Uploads PipelineRun test results to GCS (release-tests-infra)" \
    --quiet
  echo "   Service account created: ${SA_EMAIL}"
fi

echo "5. Granting Storage Object Admin on bucket..."
gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" \
  --quiet 2>/dev/null || true
echo "   Permission granted."

echo "6. Generating service account key..."
if [[ -f "$SA_KEY_FILE" ]]; then
  echo "   Key file already exists at ${SA_KEY_FILE}, skipping."
else
  gcloud iam service-accounts keys create "$SA_KEY_FILE" \
    --iam-account="$SA_EMAIL" --quiet
  echo "   Key saved to ${SA_KEY_FILE}"
  echo "   IMPORTANT: Add .gcs-sa-key.json to .gitignore!"
fi

echo "7. Enabling public read access (team can view artifacts via URL)..."
gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="allUsers" \
  --role="roles/storage.objectViewer" \
  --quiet 2>/dev/null || true
echo "   Public read enabled."

echo "8. Creating K8s secret gcs-artifacts in ${NAMESPACE}..."
oc create secret generic gcs-artifacts \
  --from-file=sa-key.json="$SA_KEY_FILE" \
  --from-literal=bucket="$GCS_BUCKET" \
  --from-literal=project="$GCS_PROJECT" \
  --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
echo "   Secret created/updated."

echo ""
echo "============================================================"
echo "  GCS ARTIFACT STORAGE — SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  Bucket:     gs://${GCS_BUCKET}"
echo "  Browse:     https://storage.googleapis.com/${GCS_BUCKET}/CI/"
echo "  Console:    https://console.cloud.google.com/storage/browser/${GCS_BUCKET}"
echo "  Retention:  ${GCS_RETENTION_DAYS} days (auto-delete)"
echo "  Cost:       ~\$0.00/month (within GCS 5GB free tier)"
echo ""
echo "  K8s secret: gcs-artifacts (namespace: ${NAMESPACE})"
echo "  SA key:     ${SA_KEY_FILE} (DO NOT commit to git)"
echo ""
echo "  Verify:     $0 --verify"
echo "============================================================"
