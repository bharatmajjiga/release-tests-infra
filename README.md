# release-tests-infra

Decentralized CI for OpenShift Pipelines acceptance tests on any cluster (amd64, arm64, ppc64le, s390x).

## Workflow

```
.env (from env.template)
      │
      ▼
run-workflow.sh
  1. create-secrets.sh     — K8s secrets from .env or Vault
  2. setup-pipelines-ci.sh — namespace, cluster secret, Tekton tasks + pipeline
  3. create-pipelinerun.sh — PipelineRun from .env (no static YAML to maintain)
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
./scripts/create-secrets.sh
./scripts/setup-pipelines-ci.sh
./scripts/create-pipelinerun.sh
```

## Configuration

All values live in `env.template` / `.env`. See `env.template` for the full list.

## Running Tests

PipelineRuns are created dynamically by `create-pipelinerun.sh` (reads `.env`, per-run workspace PVC).

```bash
./scripts/create-pipelinerun.sh
oc get pipelinerun -n pipelines-ci -w
```

Cleanup workspace PVCs after runs:

```bash
./scripts/cleanup-pipeline-pvcs.sh --finished
./scripts/cleanup-pipeline-pvcs.sh --pipelinerun acceptance-tests-abc12
```

## Repository Structure

```
release-tests-infra/
├── env.template / .env          # Configuration (not committed)
├── scripts/
│   ├── run-workflow.sh          # Full workflow
│   ├── setup-pipelines-ci.sh    # Namespace + cluster secret + Tekton apply
│   ├── create-secrets.sh        # Secrets from .env or Vault
│   ├── create-pipelinerun.sh    # Create PipelineRun from .env
│   ├── cluster-login.sh         # Shared oc login helpers
│   └── cleanup-pipeline-pvcs.sh # Remove per-run workspace PVCs
├── ci/
│   ├── pipelines/acceptance-tests.yaml
│   └── tasks/                   # Tekton tasks (release-tests, evaluate, …)
├── secrets/                     # Secret templates ($VAR placeholders)
└── config/
    ├── auth/                    # Test users (used by setup-testing-accounts task)
    ├── cluster-ca/              # Optional CA for CLUSTER_PLATFORMS=true
    └── operators/               # install-pipelines.sh, uninstall-pipelines.sh
```

## Secrets

```
.env (CRED_SOURCE=local)  or  Vault (CRED_SOURCE=vault)
  → create-secrets.sh
  → pipelines-ci namespace
  → release-tests task (PAC, GitHub, GitLab, …)
```

## Multi-arch

Test runner image `ubi9/go-toolset:latest` supports amd64, arm64, ppc64le, s390x. `oc`, `gauge`, and `ginkgo` are installed at runtime in the pipeline.
