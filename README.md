# release-tests-infra

Decentralized CI for OpenShift Pipelines acceptance tests on any cluster (amd64, arm64, ppc64le, s390x).

## Workflow

```
.env (from env.template)
      │
      ▼
scripts/run-workflow.sh
  1. scripts/hack/create-secrets.sh     — K8s secrets from .env or Vault
  2. scripts/hack/setup-pipelines-ci.sh — namespace, cluster secret, Tekton tasks + pipeline
  3. scripts/hack/create-pipelinerun.sh — PipelineRun from .env (no static YAML to maintain)
```

## Prerequisites

### Required CLI tools

| Tool | Purpose | Install |
|------|---------|---------|
| `oc` | OpenShift CLI | [mirror.openshift.com](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/) |
| `python3` + `pyyaml` | ci-config.yaml parsing, pull-secret updates | `pip3 install pyyaml` |
| `jq` | JSON processing | `brew install jq` / `dnf install jq` |
| `curl`, `git` | Downloads, repo cloning | Pre-installed on most systems |

### Optional CLI tools

| Tool | When needed | Install |
|------|-------------|---------|
| `vault` | Automated credential management (`CRED_SOURCE=vault`) | [vaultproject.io](https://developer.hashicorp.com/vault/install) |
| `aws` | AWS IPI cluster provisioning (`INSTALLER=aws-ipi`) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| `docker` / `podman` | FIPS cluster provisioning, CI image builds | `brew install podman` |
| `skopeo` | Image inspection, registry auth testing | `brew install skopeo` |

### Cluster access

One of the following:
- **kubeadmin credentials**: `KUBEADMIN_PASSWORD` + `APISERVER` in `.env`
- **SA token**: `OC_TOKEN` + `CLUSTER_CA_CERT` in `.env` (for `INSTALLER=cluster-platforms`)
- **AWS credentials**: `AWS_ACCESS_KEY` + `AWS_ACCESS_SECRET` for `INSTALLER=aws-ipi`

### Vault access (recommended)

Vault provides centralized credential management. When `CRED_SOURCE=vault`, all secrets (GitHub, GitLab, Quay, Brew, stage registry, etc.) are pulled automatically.

**Vault details:**
- URL: `https://vault.ci.openshift.org`
- Auth method: OIDC via Red Hat SSO

**Request access:**
1. Ensure you have a Red Hat SSO account (Kerberos ID)
2. Request access to the `selfservice/openshift-pipelines` Vault path via your team lead or [Vault self-service](https://vault.ci.openshift.org)

**Login and verify:**

```bash
export VAULT_ADDR=https://vault.ci.openshift.org
vault login -method=oidc
```

**Use with scripts:**

```bash
# Set in .env
CRED_SOURCE=vault
VAULT_ADDR=https://vault.ci.openshift.org

### Optional
# Scripts auto-pull credentials from Vault
./scripts/hack/create-secrets.sh
```

## Quick Start

```bash
cp env.template .env
# Edit .env — set OPERATOR_VERSION, cluster creds, secrets
# CHANNEL and git branches are auto-resolved from ci-config.yaml

./scripts/run-workflow.sh
```

Or step by step:

```bash
source .env
./scripts/hack/create-secrets.sh
./scripts/hack/setup-pipelines-ci.sh
./scripts/hack/create-pipelinerun.sh
```

## Configuration

All values live in `env.template` / `.env`. See `env.template` for the full list.

### ci-config.yaml — Version-to-Branch Mapping

The `ci-config.yaml` file maps `OPERATOR_VERSION` to subscription channels and git branches, following the same pattern as the plumbing repo. When `CHANNEL`, `GIT_RELEASE_TESTS_BRANCH`, or `GIT_RELEASE_TESTS_GINKGO_BRANCH` are empty in `.env`, they are auto-resolved from this file.

```yaml
'1.23':
  channel: pipelines-1.23
  release-tests:
    revision: release-v1.23
  release-tests-ginkgo:
    revision: main
```

Explicit `.env` values always override `ci-config.yaml` defaults.

## Running Tests

### Acceptance tests (existing cluster)

PipelineRuns are created dynamically by `create-pipelinerun.sh` (reads `.env`, per-run workspace PVC).

```bash
./scripts/hack/create-pipelinerun.sh
oc get pipelinerun -n pipelines-ci -w
```

### Upgrade tests (AWS IPI — provisions + destroys cluster)

Set `INSTALLER=aws-ipi` in `.env` with upgrade-specific vars, then:

```bash
./scripts/run-upgrade-tests.sh
```

The pipeline provisions an AWS IPI cluster, installs the pre-upgrade operator version, runs pre-upgrade tests, upgrades the operator, runs all post-upgrade suites, then destroys the cluster in the finally block.

Required `.env` vars: `PRE_UPGRADE_VERSION`, `UPGRADE_VERSION`, `AWS_ACCESS_KEY`, `AWS_ACCESS_SECRET`, `PULL_SECRET`, `SSH_PUBLIC_KEY`.

### Cleanup

Workspace PVCs:

```bash
./scripts/hack/cleanup-pipeline-pvcs.sh --finished
./scripts/hack/cleanup-pipeline-pvcs.sh --pipelinerun acceptance-tests-abc12
```

Orphaned AWS clusters (from any machine with AWS creds):

```bash
./scripts/hack/cleanup-orphan-clusters.sh
DRY_RUN=true MAX_AGE_HOURS=12 ./scripts/hack/cleanup-orphan-clusters.sh
```

## Repository Structure

```
release-tests-infra/
├── ci-config.yaml               # Version-to-branch mapping (channels, git branches)
├── env.template / .env          # Configuration (not committed)
├── scripts/
│   ├── run-workflow.sh          # Entry point (orchestrates everything)
│   ├── run-upgrade-tests.sh          # Create upgrade-tests PipelineRun (AWS IPI)
│   └── hack/                    # Helper scripts
│       ├── setup-pipelines-ci.sh      # Namespace + cluster secret + Tekton apply
│       ├── create-secrets.sh          # Secrets from .env or Vault
│       ├── create-pipelinerun.sh      # Create acceptance-tests PipelineRun
│       ├── cluster-login.sh           # Shared oc login helpers
│       ├── cleanup-pipeline-pvcs.sh   # Remove per-run workspace PVCs
│       └── cleanup-orphan-clusters.sh # Destroy orphaned AWS IPI clusters
├── ci/
│   ├── pipelines/
│   │   ├── acceptance-tests.yaml  # Tests on existing cluster
│   │   ├── upgrade-tests.yaml     # Provision + upgrade + test + destroy
│   │   └── destroy-cluster.yaml   # Manual cluster destruction
│   ├── tasks/                     # Tekton tasks (release-tests, provision, destroy, …)
│   └── cronjobs/                  # Hourly orphan cluster cleanup
├── images/
│   └── ci/
│       ├── Dockerfile             # Multi-arch CI image (amd64, arm64, ppc64le, s390x)
│       └── build.sh               # Build + push script
├── secrets/                     # Secret templates ($VAR placeholders)
└── config/
    ├── auth/                    # Test users (used by setup-testing-accounts task)
    ├── cluster-configs/         # Optional CA for INSTALLER=cluster-platforms
    └── operators/               # install-pipelines.sh, uninstall-pipelines.sh
```

## Artifact Storage (GCS)

PipelineRun test results (XML reports, logs, pass/fail status) are automatically uploaded to Google Cloud Storage in the pipeline's `finally` block and retained for 30 days before auto-deletion.

**Cost:** $0.00/month (within GCS 5GB always-free tier).

### Setup (one-time)

```bash
# Full setup: creates bucket, service account, lifecycle rule, K8s secret
./scripts/hack/setup-gcs-artifacts.sh

# Or step-by-step:
# 1. Ensure gcloud is authenticated: gcloud auth login
# 2. Set GCS_PROJECT in .env (default: pipelines-qe)
# 3. Run the setup script
GCS_PROJECT=pipelines-qe GCS_BUCKET=ospqa-ci-artifacts ./scripts/hack/setup-gcs-artifacts.sh
```

The script:
1. Creates a GCS bucket in `us-east1` (free-tier eligible region)
2. Configures a 30-day auto-delete lifecycle rule
3. Creates a service account with Storage Object Admin
4. Enables public read access (team can browse via URL)
5. Creates the `gcs-artifacts` K8s secret in `pipelines-ci`

### Viewing artifacts

After any PipelineRun completes (pass or fail), the upload task prints the artifact URL:

```
============================================================
  ARTIFACTS UPLOADED: 12 files
============================================================

  View results: https://storage.googleapis.com/ospqa-ci-artifacts/CI/1.23.0/acceptance-tests-abc123/index.html

  Direct files: https://storage.googleapis.com/ospqa-ci-artifacts/CI/1.23.0/acceptance-tests-abc123/
  GCP Console:  https://console.cloud.google.com/storage/browser/ospqa-ci-artifacts/CI/1.23.0/acceptance-tests-abc123

  Auto-delete:  These artifacts expire in 30 days.
============================================================
```

URL pattern: `https://storage.googleapis.com/<bucket>/CI/<version>/<pipelinerun-name>/index.html`

### Testing the upload

```bash
# Apply the task
oc apply -f ci/tasks/upload-artifacts-gcs.yaml -n pipelines-ci

# Run the test PipelineRun (generates sample artifacts and uploads)
oc create -f ci/pipelineruns/upload-artifacts-gcs-test.yaml -n pipelines-ci

# Watch progress
oc get pipelinerun -n pipelines-ci --sort-by=.metadata.creationTimestamp | tail -3
```

### Verify setup

```bash
./scripts/hack/setup-gcs-artifacts.sh --verify
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GCS_PROJECT` | `pipelines-qe` | GCP project ID |
| `GCS_BUCKET` | `ospqa-ci-artifacts` | Bucket name |
| `GCS_LOCATION` | `us-east1` | Region (must be free-tier eligible) |
| `GCS_RETENTION_DAYS` | `30` | Days before auto-deletion |
| `GCS_SA_KEY_FILE` | `.gcs-sa-key.json` | SA key file (auto-created, gitignored) |

### Free-tier limits

| Resource | Free Allowance | CI Usage |
|----------|----------------|----------|
| Storage | 5 GB/month | ~500 MB (30-day window) |
| Class A ops (PUT) | 5,000/month | ~5,000 |
| Class B ops (GET) | 50,000/month | ~10,000 |
| Egress | 1 GB/month | ~1 GB |

## Multi-arch

The CI image (`images/ci/Dockerfile`) is built on `ubi9/go-toolset:latest` and supports amd64, arm64, ppc64le, and s390x. Pre-installed tools:

| Tool | amd64/arm64 | ppc64le/s390x |
|------|:-----------:|:-------------:|
| gauge | Pre-built binary or `go install` | `go install` from source |
| ginkgo | `go install` | `go install` |
| golangci-lint | Pre-built tarball | Pre-built tarball |
| MinIO mc | Direct binary | Direct binary |
| ROSA CLI | Built from source | Built from source |
| Azure CLI | pip install | Skipped (no wheels) |
| yq, jq, cosign, rekor-cli | Pre-built binary | Pre-built binary |

The image runs as non-root (UID 1001) by default.

### ARM64 cluster provisioning

The `provision-cluster` task automatically maps `m5.*` instance types to `m6g.*` (Graviton) when `ARCH=linux/arm64`. Cross-architecture provisioning (e.g., running an amd64 pod to create an arm64 cluster) is supported via multi-arch release images.

## Test Execution Model

### go-mod-cache task

A shared `go-mod-cache` task runs once before all test suites. It:
- Downloads Go modules (`GOMODCACHE`) to a shared PVC
- Warms the Go build cache (`GOCACHE`) with `go build ./...`
- Copies pre-installed gauge/ginkgo binaries from the CI image
- Installs gauge plugins (go runner, html-report, xml-report)
- Downloads `oc` and `tkn` CLIs matching the cluster version

All parallel test tasks reuse these cached artifacts.

### Parallel test execution

Test suites run in parallel after operator installation. To prevent CPU starvation from 17 simultaneous Go compilations:

- **Startup jitter**: each suite sleeps a random 0-120s before starting (`sleep $((RANDOM % 120))`)
- **Shared build cache**: pre-warmed `GOCACHE` on PVC reduces recompilation
- **Vet disabled**: `GOFLAGS=-vet=off` skips expensive vetting during test runs
- **Isolated GOPATH**: each pod uses a temp `GOPATH` to avoid cross-pod contention
- **Auto-retry**: gauge runs with `--max-retries-count=3` for transient failures

## Secrets

```
.env (CRED_SOURCE=local)  or  Vault (CRED_SOURCE=vault)
  → scripts/hack/create-secrets.sh
  → pipelines-ci namespace
  → release-tests task (PAC, GitHub, GitLab, …)
```

## AI Agent Skills (Cursor / Claude Code)

This repo includes skills and MCP integration that enable AI agents to run CI operations via natural language.

```
User (natural language)
    │
    ▼
AI Agent (reads SKILL.md)
    │
    ├── reads env/.env.acceptance (or .env.upgrade) → prompts for missing values
    ├── Tekton MCP server → list/get/create pipeline resources directly
    └── runs scripts/run-workflow.sh (or individual scripts)
         │
         ▼
    Same shell scripts → same cluster
```

**Skill location** (shared by both Cursor and Claude Code):
- `.claude/skills/SKILL.md`

### Per-operation env files

Each operation has its own env file in `env/` — the agent prompts for missing values on first run and reuses them after:

| Operation | Env file | Command |
|-----------|----------|---------|
| Acceptance | `env/.env.acceptance` | `ENV_FILE=env/.env.acceptance ./scripts/run-workflow.sh` |
| Upgrade | `env/.env.upgrade` | `ENV_FILE=env/.env.upgrade ./scripts/run-upgrade-tests.sh` |

### Tekton MCP Server (Optional)

The [tektoncd/mcp-server](https://github.com/tektoncd/mcp-server) gives agents native Tekton API access — list pipelines, get task logs, create runs — without parsing `oc` output. This is **not configured by default** — set it up manually if you want AI agents to interact directly with Tekton resources.

**Setup steps:**

1. Install the MCP server binary:
   ```bash
   go install github.com/tektoncd/mcp-server/cmd/tekton-mcp-server@latest
   ```

2. Configure for your current cluster (auto-detects kubeconfig):
   ```bash
   ./scripts/hack/configure-mcp.sh
   ```

3. Or point to a specific kubeconfig:
   ```bash
   ./scripts/hack/configure-mcp.sh ~/.kube/my-cluster
   ```

4. Remove when cluster is destroyed:
   ```bash
   ./scripts/hack/configure-mcp.sh --remove
   ```

This creates `.claude/settings.json` (gitignored), which is read by both Cursor and Claude Code. The MCP server runs locally and authenticates via `KUBECONFIG`.

**MCP tools available to agents:**

| Tool | What it does |
|------|-------------|
| `list_pipelineruns` | List PipelineRuns with filtering |
| `list_taskruns` | List TaskRuns with filtering |
| `get_pipelinerun` | Get PipelineRun details (YAML/JSON) |
| `get_taskrun_logs` | Get logs for a TaskRun |
| `create_pipelinerun` | Create a PipelineRun |
| `start_pipeline` | Start a Pipeline |
| `delete_all_pipelineruns` | Bulk delete PipelineRuns |
| `list_artifacthub_tasks` | Discover tasks from Artifact Hub |

**Example MCP prompts** (tell the agent):

> "List all failed pipeline runs in pipelines-ci"

> "Show me the logs for the release-tests-triggers task"

> "What's the status of the latest acceptance test pipeline?"

> "Delete all completed pipeline runs"

### Example: Full setup on a fresh cluster

Tell the agent:

> "Set up and run acceptance tests on cluster zfvzt at api.cluster-zfvzt.sandbox3465.opentlc.com:6443, password jjL3f-uHnvg, redhat-operator 1.23.0 prod"

The agent will:
1. Update `.env` with cluster details and operator config
2. Run `./scripts/run-workflow.sh` (secrets → operator install → pipeline)
3. Monitor operator readiness and pipeline progress
4. Report per-suite pass/fail results

### Example: Run acceptance tests

> "Run acceptance tests with e2e tags"

The agent will:
1. Verify `.env` has `OPERATOR_VERSION`, `APISERVER`, etc.
2. Run `./scripts/hack/create-pipelinerun.sh`
3. Monitor with `oc get taskrun`

### Example: Run upgrade tests

> "Run upgrade tests from 1.22.3 prod to 1.23.0 pre-stage"

The agent will:
1. Set `PRE_UPGRADE_VERSION=1.22.3`, `UPGRADE_VERSION=1.23.0`, etc. in `.env`
2. Run `./scripts/run-upgrade-tests.sh` (auto-creates secrets, installs pre-upgrade operator, triggers pipeline)
3. Monitor upgrade pipeline progress

### Example: Provision and manage clusters

> "Provision an arm64 FIPS cluster"

```bash
# Agent runs:
ARCH=arm64 FIPS=true ./scripts/hack/provision-cluster-local.sh
```

> "Clean up unused AWS resources"

```bash
# Agent runs:
./scripts/hack/cleanup-orphan-clusters.sh
```

### Example: Configure .env via natural language

Instead of manually editing `.env`, tell the agent what you want:

> "Switch to prod environment with operator 1.22.3 on redhat-operators"

The agent updates `.env`:
```
OPERATOR_VERSION=1.23.0       →  OPERATOR_VERSION=1.22.3
OPERATOR_ENVIRONMENT=pre-stage →  OPERATOR_ENVIRONMENT=prod
CATALOG_SOURCE=custom-operators → CATALOG_SOURCE=redhat-operators
KONFLUX_INDEX_IMAGE=quay.io/... → KONFLUX_INDEX_IMAGE=
```

> "Use cluster abc123 at api.abc123.example.com with password xyz"

The agent updates `.env`:
```
CLUSTER_NAME=abc123
APISERVER=https://api.abc123.example.com:6443
KUBEADMIN_PASSWORD=xyz
INSTALLER=none
```

> "Run only versions and pipelines tests with sanity tags"

The agent updates `.env`:
```
TEST_SUITES=release-tests-versions,release-tests-pipelines
TAGS=sanity
```

> "Set up for disconnected testing"

The agent updates `.env`:
```
IS_DISCONNECTED=true
TAGS=sanity
TEST_SUITES=release-tests-versions,release-tests-pipelines,...  (disconnected profile)
```

> "Configure upgrade from 1.22.3 prod to 1.23.0 pre-stage"

The agent updates `.env`:
```
PRE_UPGRADE_VERSION=1.22.3
PRE_UPGRADE_OPERATOR_ENVIRONMENT=prod
PRE_UPGRADE_CATALOG_SOURCE=redhat-operators
UPGRADE_VERSION=1.23.0
UPGRADE_OPERATOR_ENVIRONMENT=pre-stage
UPGRADE_CATALOG_SOURCE=custom-operators
UPGRADE_KONFLUX_INDEX_IMAGE=quay.io/openshift-pipeline/pipelines-index-4.21:v1.23.0
```

The agent reads `env.template` profiles and `ci-config.yaml` to auto-resolve channels and git branches — you only need to specify what changes.

### Example: Diagnose failures

> "Why did release-tests-triggers fail?"

The agent will:
1. Find the latest PipelineRun
2. Get the TaskRun status and pod name
3. Read the logs: `oc logs -n pipelines-ci <pod> -c step-run --tail=30`
4. Identify the root cause and suggest a fix
