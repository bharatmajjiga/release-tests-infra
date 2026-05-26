# release-tests-infra — Repository Guide

Always read this file before making any changes to this repository.

## What This Repo Does

Decentralized CI for OpenShift Pipelines acceptance testing. Runs Gauge tests on any cluster (amd64, arm64, ppc64le, s390x). All configuration flows from a single `env.template` / `.env` file.

## Workflow

```
.env (from env.template)
  ↓
run-workflow.sh
  1. Clone release-tests-infra + release-tests repos
  2. Install operator: CATALOG_SOURCE=... CHANNEL=... gauge run --tags install specs/olm.spec
  3. Install ESO + Vault secrets (if VAULT_TOKEN set)
  4. Create individual K8s secrets from Vault cluster-creds
  5. Setup pipelines-ci namespace + tasks + pipeline
```

## Single Source of Truth: env.template

ALL configuration lives in `env.template`. This includes:
- Cluster connection (APISERVER, ADMIN_TOKEN)
- Operator config (OPERATOR_VERSION, CATALOG_SOURCE, CHANNEL, ARCH, OPERATOR_ENVIRONMENT)
- Git branches (GIT_RELEASE_TESTS_BRANCH, GIT_INFRA_BRANCH)
- Container image (IMAGE)
- Konflux index (KONFLUX_INDEX_IMAGE)
- TKN CLI (TKN_DOWNLOAD_URL)
- Vault token (VAULT_TOKEN)
- All secret values (GitHub, GitLab, Quay, AWS, Brew, Polarion, etc.)

**When adding new config**, always add it to `env.template` first, then reference from scripts/PipelineRun.

**PipelineRun values must match `.env`** — `acceptance-tests-install.yaml` params mirror env.template.

## Critical Files (DO NOT break)

### Workflow entry point
- `scripts/run-workflow.sh` — orchestrates the full workflow, sources `.env`

### Tekton CI
- `ci/pipelines/acceptance-tests.yaml` — main pipeline
- `ci/pipelineruns/acceptance-tests-install.yaml` — PipelineRun (values from env.template)
- `ci/tasks/release-tests.yaml` — runs gauge tests, installs oc + gauge
- `ci/tasks/setup-testing-accounts.yaml` — creates test users
- `ci/tasks/configure-operator.yaml` — applies CatalogSource
- `ci/tasks/generate-build-artifacts.yaml` — generates CatalogSource YAML

### Scripts
- `scripts/setup-pipelines-ci.sh` — namespace + cluster secret + tasks + pipeline
- `scripts/create-secrets.sh` — individual K8s secrets from Vault cluster-creds
- `scripts/install-external-secrets-operator.sh` — ESO + Vault + ExternalSecret

### Config (used by Tekton)
- `config/auth/01-test-auth.sh` — only config file referenced by pipeline
- `config/auth/users.htpasswd` — test user password hashes
- `config/auth/test-oauth.yaml` — HTPasswd OAuth CR

## Key Design Decisions

### env.template is the single source of truth
- All scripts source `.env` (copied from `env.template`)
- PipelineRun YAML params should mirror `.env` values
- Never hardcode config values in scripts — read from env vars

### Multi-arch support
- Image: `registry.access.redhat.com/ubi9/go-toolset:latest` (amd64, arm64, ppc64le, s390x)
- Tools installed at runtime to `$HOME/bin` (non-root compatible)
- `oc` CLI version matched to cluster's OpenShift version
- `gauge` installed via `go install` (all architectures)
- Pre-compilation (`go build ./...`) required before `gauge run`

### Secrets architecture
- Vault → `osp-ci-secrets/cluster-creds` (ExternalSecret)
- `create-secrets.sh` reads cluster-creds, creates 16 individual secrets in `pipelines-ci`
- `release-tests.yaml` uses `envFrom: cluster-creds` for bulk env injection
- Per-cluster secret `cluster-<name>` provides APISERVER, ADMIN_TOKEN (overrides envFrom)

### Tekton when expressions
- CEL is NOT enabled — use standard `input/operator/values` syntax

## File Categories

### ACTIVE (wired into automation)
```
env.template                 — single source of truth
scripts/run-workflow.sh      — full workflow orchestration
scripts/setup-pipelines-ci.sh
scripts/create-secrets.sh
scripts/install-external-secrets-operator.sh
ci/                          — Tekton pipeline, tasks, pipelineruns
secrets/                     — K8s Secret YAML templates
config/auth/01-test-auth.sh  — test user setup (called by pipeline)
config/auth/users.htpasswd
config/auth/test-oauth.yaml
```

### MANUAL (run by hand, not in pipeline)
```
config/auth/01-prod-auth.sh, prod-oauth.yaml, admin-group.yaml
config/install-pac.sh, configure-results.sh, update-tekton-config.sh
config/operators/install-*.sh, uninstall-*.sh
config/roles/, config/chrony/
```

### REFERENCE
```
ci-config.yaml — version matrix (not consumed by scripts)
```

## Rules for Changes

1. **New config values**: Add to `env.template` first, then reference via `$VAR` in scripts
2. **PipelineRun changes**: Keep params in sync with `env.template`
3. **Pipeline param changes**: Ensure Pipeline and PipelineRun params match
4. **Task image**: Default is `quay.io/openshift-pipeline/ci`, overridden to `ubi9/go-toolset` via IMAGE param
5. **Secrets**: Never commit actual values. Templates in `secrets/` use `$VAR` placeholders
6. **Namespace**: Default `pipelines-ci`, override via `NAMESPACE` env var
7. **When expressions**: Standard Tekton syntax only, NOT CEL
