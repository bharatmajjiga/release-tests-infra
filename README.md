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
./scripts/hack/run-upgrade-tests.sh
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
│   └── hack/                    # Helper scripts
│       ├── setup-pipelines-ci.sh      # Namespace + cluster secret + Tekton apply
│       ├── create-secrets.sh          # Secrets from .env or Vault
│       ├── create-pipelinerun.sh      # Create acceptance-tests PipelineRun
│       ├── run-upgrade-tests.sh       # Create upgrade-tests PipelineRun (AWS IPI)
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
