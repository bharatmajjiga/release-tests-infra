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
# Edit .env — cluster, operator, test branches, secrets

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
├── secrets/                     # Secret templates ($VAR placeholders)
└── config/
    ├── auth/                    # Test users (used by setup-testing-accounts task)
    ├── cluster-configs/         # Optional CA for INSTALLER=cluster-platforms
    └── operators/               # install-pipelines.sh, uninstall-pipelines.sh
```

## Secrets

```
.env (CRED_SOURCE=local)  or  Vault (CRED_SOURCE=vault)
  → scripts/hack/create-secrets.sh
  → pipelines-ci namespace
  → release-tests task (PAC, GitHub, GitLab, …)
```

## Multi-arch

Test runner image `ubi9/go-toolset:latest` supports amd64, arm64, ppc64le, s390x. `oc`, `gauge`, and `ginkgo` are installed at runtime in the pipeline.
