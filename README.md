# release-tests-infra

CI infrastructure for OpenShift Pipelines acceptance and upgrade tests. Runs on any cluster (amd64, arm64, ppc64le, s390x).


## Prerequisites

Required for acceptance and upgrade tests on an existing cluster:

| Tool | Purpose |
|------|---------|
| `oc` | OpenShift CLI |
| `python3` + `pyyaml` | ci-config.yaml parsing |
| `jq` | JSON processing (Logging install, PVC cleanup) |
| `skopeo` | Image digest lookup (Logging/MinIO install) |


### Optional tools

| Tool | When |
|------|------|
| `vault` | `CRED_SOURCE=vault` (request OpenShift Pipelines Vault access) |
| `aws` | Orphan AWS cleanup; local `provision-cluster-local.sh` |
| `gcloud` | One-time GCS bucket setup (`setup-gcs-artifacts.sh`) |
| `openshift-install` | Local provision/destroy (the provision script can download it) |
| `podman` or `docker` | Local FIPS provision; building the CI image |
| `az` | ARO — used in the pipeline task, not as a local CLI |

## Configuration

All values live in `env/env.template`, copied to `env/.env.acceptance` or `env/.env.upgrade`. Pass the file with `ENV_FILE=` when running scripts. Key variables:

| Variable | Description |
|----------|-------------|
| `INSTALLER` | `cluster-platforms, cp`, `aws-ipi`, `aro`, `none` |
| `OPERATOR_VERSION` | Pipelines operator version (e.g. `1.23.1`) |
| `OPERATOR_ENVIRONMENT` | `prod`, `stage`, `pre-stage` |
| `CATALOG_SOURCE` | `redhat-operators` (prod) or `custom-operators` |
| `KONFLUX_INDEX_IMAGE` | Required for stage/pre-stage |
| `TEST_FRAMEWORK` | `gauge` or `ginkgo` |
| `TAGS` | Label filter (e.g. `e2e`, `sanity`) |
| `TEST_SUITES` | Comma-separated list of suites to run |
| `CRED_SOURCE` | `local` (from `ENV_FILE`) or `vault` (from Vault) |

## Running acceptance tests

Copy `env/env.template` to `env/.env.acceptance`, fill in cluster creds and operator version, then run:

```bash
cp env/env.template env/.env.acceptance
ENV_FILE=env/.env.acceptance ./scripts/run-workflow.sh
```

This:

1. `create-secrets.sh` — K8s secrets from `ENV_FILE` or Vault
2. `setup-pipelines-ci.sh` — namespace, cluster secret, Tekton tasks + pipelines
3. `create-pipelinerun.sh` — submits the `acceptance-tests` PipelineRun

## Running upgrade tests

Copy `env/env.template` to `env/.env.upgrade`, fill in cluster creds and pre-upgrade / upgrade versions, then run:

```bash
cp env/env.template env/.env.upgrade
ENV_FILE=env/.env.upgrade ./scripts/run-upgrade-tests.sh
```

This:

1. `create-secrets.sh` — K8s secrets from `ENV_FILE` or Vault
2. `setup-pipelines-ci.sh` — namespace, cluster secret, Tekton tasks + pipelines
3. `run-upgrade-tests.sh` — submits the `upgrade-tests` PipelineRun

## Test Suite Isolation

Each suite maps to a ginkgo test directory and label filter:

| TEST_SUITES value | Ginkgo Dir | Label Filter |
|-------------------|------------|-------------|
| release-tests-versions | `tests/versions/` | `e2e` |
| release-tests-pipelines | `tests/pipelines/` | `e2e` |
| release-tests-triggers | `tests/triggers/` | `e2e && !tls` |
| release-tests-triggers-tls | `tests/triggers/` | `tls && e2e` |
| release-tests-chains | `tests/chains/` | `e2e` |
| release-tests-pac | `tests/pac/` | `e2e` |
| release-tests-pac-github | `tests/pac/` | `sanity` |
| release-tests-pac-gitlab | `tests/pac/` | `sanity` |
| release-tests-results | `tests/results/` | `e2e` |
| release-tests-metrics | `tests/metrics/` | `e2e` |
| release-tests-rbac | `tests/operator/` | `e2e && rbac` |
| release-tests-addon | `tests/operator/` | `e2e && addon` |
| release-tests-auto-prune | `tests/operator/` | `e2e && auto-prune` |
| release-tests-tekton-pruner | `tests/operator/` | `e2e && tekton-pruner` |
| release-tests-manual-approval | `tests/mag/` | `e2e` |
| release-tests-ecosystem | `tests/ecosystem/` | `e2e` |
| release-tests-ecosystem-multiarch | `tests/ecosystem/` | `ARCH && e2e` |
| release-tests-ecosystem-s2i | `tests/ecosystem/` | `e2e && s2i` |

On connected clusters (`IS_DISCONNECTED=false`, the default), `&& !disconnected` is automatically appended to every filter. On disconnected clusters, it is omitted so disconnected-labeled tests also run.

Suites sharing `tests/operator/` are isolated by injecting suite-specific labels (`rbac`, `addon`, `auto-prune`, `tekton-pruner`) via `ginkgo_label_filter()` based on the SPECS parameter.

### ci-config.yaml

Maps operator versions to subscription channels and git branches. When `CHANNEL` or `GIT_RELEASE_TESTS_BRANCH` are empty, they are auto-resolved:

```yaml
'1.23':
  channel: pipelines-1.23
  release-tests:
    revision: release-v1.23
  release-tests-ginkgo:
    revision: main
```

## Secrets

```bash
# From Vault (recommended)
ENV_FILE=env/.env.acceptance CRED_SOURCE=vault ./scripts/hack/create-secrets.sh

# From ENV_FILE variables
ENV_FILE=env/.env.acceptance CRED_SOURCE=local ./scripts/hack/create-secrets.sh

# First-time Vault login
ENV_FILE=env/.env.acceptance ./scripts/hack/create-secrets.sh --vault-login
```

## Artifact Storage (GCS)

Test results are uploaded to GCS in the pipeline's `finally` block.

```
https://storage.googleapis.com/<bucket>/CI/<version>/<pipelinerun>/index.html
```

## Multi-arch

The CI image supports amd64, arm64, ppc64le, and s390x. GCS uploads use `curl` + OAuth2 JWT (no `gcloud` dependency). The `provision-cluster` task maps `m5.*` to `m6g.*` (Graviton) for arm64.

## Cleanup

```bash
# Workspace PVCs
ENV_FILE=env/.env.acceptance ./scripts/hack/cleanup-pipeline-pvcs.sh --finished

# Orphaned AWS clusters
./scripts/hack/cleanup-orphan-clusters.sh
```
