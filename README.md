# release-tests-infra

CI infrastructure for OpenShift Pipelines acceptance and upgrade tests. Runs on any cluster (amd64, arm64, ppc64le, s390x).

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

## Pipeline Execution Order

### Acceptance tests

```
provision-cluster → clone repos + go-mod-cache
      │
install-pipelines-operator
      │
 ┌────┴──────────────────────────────────┐
 │          PARALLEL SUITES              │
 │  versions   pipelines   triggers      │
 │  triggers-tls  chains   pac           │
 │  pac-github  pac-gitlab  results      │
 │  metrics     rbac        addon        │
 │  manual-approval  ecosystem           │
 │  ecosystem-multiarch  ecosystem-s2i   │
 └────┬──────────────────────────────────┘
      │
 auto-prune          (sequential)
      │
 tekton-pruner       (sequential)
      │
 evaluate-test-suites → uninstall (optional) → slack
      │
 finally: upload-artifacts-gcs → destroy-cluster → cleanup
```

### Upgrade tests

Same structure with additional phases: install pre-upgrade version → pre-upgrade tests → upgrade operator → parallel post-upgrade suites → auto-prune → tekton-pruner → evaluate.

## Test Suite Isolation

Each suite maps to a ginkgo test directory and label filter. `ginkgo_label_filter()` builds the filter from TAGS + SPECS:

| TEST_SUITES value | SPECS | Ginkgo Dir | Label Filter |
|-------------------|-------|------------|-------------|
| release-tests-versions | `specs/versions.spec` | `tests/versions/` | `e2e` |
| release-tests-pipelines | `specs/pipelines/` | `tests/pipelines/` | `e2e` |
| release-tests-triggers | `specs/triggers/` | `tests/triggers/` | `e2e && !tls` |
| release-tests-triggers-tls | `specs/triggers/eventlistener.spec` | `tests/triggers/` | `tls && e2e` |
| release-tests-chains | `specs/chains/` | `tests/chains/` | `e2e` |
| release-tests-pac | `specs/pac/` | `tests/pac/` | `e2e` |
| release-tests-pac-github | `specs/pac/pac-github.spec` | `tests/pac/` | `sanity` |
| release-tests-pac-gitlab | `specs/pac/pac-gitlab.spec` | `tests/pac/` | `sanity` |
| release-tests-results | `specs/results/` | `tests/results/` | `e2e` |
| release-tests-metrics | `specs/metrics/` | `tests/metrics/` | `e2e` |
| release-tests-rbac | `specs/operator/rbac.spec` | `tests/operator/` | `e2e && rbac` |
| release-tests-addon | `specs/operator/addon.spec` | `tests/operator/` | `e2e && addon` |
| release-tests-auto-prune | `specs/operator/auto-prune.spec` | `tests/operator/` | `e2e && auto-prune` |
| release-tests-tekton-pruner | `specs/operator/tekton-pruner.spec` | `tests/operator/` | `e2e && tekton-pruner` |
| release-tests-manual-approval | `specs/manualapprovalgate/` | `tests/mag/` | `e2e` |
| release-tests-ecosystem | `specs/ecosystem/ecosystem.spec` | `tests/ecosystem/` | `e2e` |
| release-tests-ecosystem-multiarch | `specs/ecosystem/ecosystem-multiarch.spec` | `tests/ecosystem/` | `ARCH && e2e` |
| release-tests-ecosystem-s2i | `specs/ecosystem/ecosystem-s2i.spec` | `tests/ecosystem/` | `e2e && s2i` |

On connected clusters (`IS_DISCONNECTED=false`, the default), `&& !disconnected` is automatically appended to every filter. On disconnected clusters, it is omitted so disconnected-labeled tests also run.

Suites sharing `tests/operator/` are isolated by injecting suite-specific labels (`rbac`, `addon`, `auto-prune`, `tekton-pruner`) via `ginkgo_label_filter()` based on the SPECS parameter.

## Configuration

All values live in `env/env.template`, copied to `env/.env.acceptance` or `env/.env.upgrade`. Pass the file with `ENV_FILE=` when running scripts. Key variables:

| Variable | Description |
|----------|-------------|
| `INSTALLER` | `cluster-platforms`, `aws-ipi`, `aro`, `none` |
| `OPERATOR_VERSION` | Pipelines operator version (e.g. `1.23.1`) |
| `OPERATOR_ENVIRONMENT` | `prod`, `stage`, `pre-stage` |
| `CATALOG_SOURCE` | `redhat-operators` (prod) or `custom-operators` |
| `KONFLUX_INDEX_IMAGE` | Required for stage/pre-stage |
| `TEST_FRAMEWORK` | `gauge` or `ginkgo` |
| `TAGS` | Label filter (e.g. `e2e`, `sanity`) |
| `TEST_SUITES` | Comma-separated list of suites to run |
| `CRED_SOURCE` | `local` (from `ENV_FILE`) or `vault` (from Vault) |

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

Secrets created: `aws-creds`, `github`, `pac-github-token`, `pac-gitlab`, `p12n`, `quay-io-dockerconfig`, `gcs-artifacts`, `cluster-<name>`, and others based on available credentials.

The GCS service account key is stored in Vault as `GCS-TOKEN` and pulled automatically by `create-secrets.sh`.

## Artifact Storage (GCS)

Test results are uploaded to GCS in the pipeline's `finally` block (30-day auto-deletion, free tier).

```
https://storage.googleapis.com/<bucket>/CI/<version>/<pipelinerun>/index.html
```

Setup: `./scripts/hack/setup-gcs-artifacts.sh`
Verify: `./scripts/hack/setup-gcs-artifacts.sh --verify`

| Variable | Default |
|----------|---------|
| `GCS_PROJECT` | `pipelines-qe` |
| `GCS_BUCKET` | `ospqa-ci-artifacts` |

## Repository Structure

```
release-tests-infra/
├── ci-config.yaml                    # Version → channel/branch mapping
├── env.template                      # Configuration template
├── env/
│   ├── .env.acceptance               # Acceptance test config
│   └── .env.upgrade                  # Upgrade test config
├── ci/
│   ├── pipelines/
│   │   ├── acceptance-tests.yaml     # Parallel suites → sequential pruner → evaluate
│   │   ├── upgrade-tests.yaml        # Install → pre-upgrade → upgrade → post-upgrade suites
│   │   └── destroy-cluster.yaml
│   ├── tasks/
│   │   ├── release-tests.yaml        # Core test runner (gauge/ginkgo)
│   │   ├── provision-cluster.yaml    # AWS IPI / ARO / Flexy provisioning
│   │   ├── destroy-cluster.yaml
│   │   ├── configure-operator.yaml
│   │   ├── generate-build-artifacts.yaml
│   │   ├── go-mod-cache.yaml         # Shared module + build cache
│   │   ├── upload-artifacts-gcs.yaml # GCS upload (curl-based, all architectures)
│   │   └── ...
│   └── cronjobs/                     # Orphan cluster cleanup
├── scripts/
│   ├── run-workflow.sh               # Acceptance tests entry point
│   ├── run-upgrade-tests.sh          # Upgrade tests entry point
│   └── hack/
│       ├── create-secrets.sh         # Secrets from ENV_FILE or Vault
│       ├── setup-pipelines-ci.sh     # Namespace + Tekton apply
│       ├── create-pipelinerun.sh     # Submit acceptance PipelineRun
│       ├── cluster-login.sh          # Shared login helpers
│       ├── setup-gcs-artifacts.sh    # GCS bucket + SA setup
│       ├── cleanup-pipeline-pvcs.sh
│       └── cleanup-orphan-clusters.sh
├── secrets/                          # Secret YAML templates
├── images/ci/
│   ├── Dockerfile                    # Multi-arch CI image
│   └── build.sh
└── config/
    ├── auth/                         # Test user setup
    └── operators/                    # Operator install/uninstall scripts
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
