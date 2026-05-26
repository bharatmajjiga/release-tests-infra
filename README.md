# release-tests-infra

Decentralized CI infrastructure for running OpenShift Pipelines acceptance tests on any cluster (amd64, arm64, ppc64le, s390x).

## Workflow

```
env.template (.env)  ← single source of truth for all configuration
      │
      ▼
┌─────────────────────────────────────────────────────┐
│  run-workflow.sh                                    │
│                                                     │
│  1. Clone release-tests-infra + release-tests repos │
│  2. Install operator via gauge                      │
│     CATALOG_SOURCE=... CHANNEL=... gauge run        │
│       --tags install specs/olm.spec                 │
│  3. Install External Secrets Operator (Vault)       │
│  4. Create individual K8s secrets from Vault        │
│  5. Setup pipelines-ci (namespace + tasks + pipeline│
└─────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Configure
cp env.template .env
# Edit .env — set APISERVER, ADMIN_TOKEN, OPERATOR_VERSION, etc.

# 2. Run the full workflow
./scripts/run-workflow.sh
```

This will:
- Clone `release-tests` at the branch matching your `OPERATOR_VERSION`
- Install the operator using gauge (`CATALOG_SOURCE` + `CHANNEL` from `.env`)
- Set up Vault-backed secrets (if `VAULT_TOKEN` is set)
- Apply Tekton tasks and pipeline to `pipelines-ci`

## Configuration (env.template)

All values are defined in `env.template`. Copy to `.env` and fill in:

| Variable | Description | Example |
|----------|-------------|---------|
| `APISERVER` | Cluster API URL | `https://api.mycluster.example.com:6443` |
| `ADMIN_TOKEN` | Admin token (`oc whoami -t`) | `sha256~xxx` |
| `ARCH` | Cluster architecture | `linux/arm64` |
| `CATALOG_SOURCE` | OLM CatalogSource name | `custom-operators` |
| `CHANNEL` | Operator subscription channel | `latest` |
| `OPERATOR_VERSION` | Pipelines operator version | `1.22.0` |
| `OPERATOR_ENVIRONMENT` | Environment (prod/stage/pre-stage) | `prod` |
| `GIT_RELEASE_TESTS_BRANCH` | release-tests branch | `release-v1.22` |
| `GIT_INFRA_BRANCH` | release-tests-infra branch | `main` |
| `IMAGE` | Container image for test runner | `registry.access.redhat.com/ubi9/go-toolset:latest` |
| `KONFLUX_INDEX_IMAGE` | Konflux index image URL | `quay.io/openshift-pipeline/pipelines-index-4.21:v1.20.5` |
| `TKN_DOWNLOAD_URL` | TKN CLI download URL | `https://developers.qa.redhat.com/...` |
| `VAULT_TOKEN` | Vault token for secrets | `hvs.xxx` |

See `env.template` for the full list including GitHub, GitLab, Quay, Brew, AWS, Polarion, ReportPortal, etc.

## Running Tests

### Option 1: Full workflow (recommended)
```bash
source .env
./scripts/run-workflow.sh
```

### Option 2: Tekton PipelineRun
```bash
# After setup-pipelines-ci.sh has run:
oc create -f ci/pipelineruns/acceptance-tests-install.yaml -n pipelines-ci
```
Values in `acceptance-tests-install.yaml` should mirror your `.env`.

### Option 3: Local gauge run
```bash
source .env
cd /path/to/release-tests
go mod download && go build ./...
CATALOG_SOURCE=$CATALOG_SOURCE CHANNEL=$CHANNEL \
  gauge run --log-level=debug --verbose --tags install specs/olm.spec
```

## Repository Structure

```
release-tests-infra/
├── env.template                     # Single source of truth for all config
├── .env                             # Local copy (gitignored)
│
├── scripts/
│   ├── run-workflow.sh              # Full workflow: clone → install → ESO → secrets → setup
│   ├── setup-pipelines-ci.sh        # Namespace + cluster secret + tasks + pipeline
│   ├── install-external-secrets-operator.sh  # ESO + Vault SecretStore + ExternalSecret
│   └── create-secrets.sh            # Individual K8s secrets from Vault cluster-creds
│
├── ci/
│   ├── pipelines/
│   │   └── acceptance-tests.yaml    # Main Tekton pipeline
│   ├── pipelineruns/
│   │   └── acceptance-tests-install.yaml  # PipelineRun (values from env.template)
│   └── tasks/
│       ├── release-tests.yaml            # Runs gauge tests
│       ├── setup-testing-accounts.yaml   # Creates test users
│       ├── configure-operator.yaml       # Applies CatalogSource
│       └── generate-build-artifacts.yaml # Generates CatalogSource YAML
│
├── secrets/                         # K8s Secret YAML templates (sed-substituted)
│   ├── aws.yaml, github.yaml, pac-gitlab.yaml, ...
│   └── (16 secret templates)
│
├── config/                          # Cluster configuration
│   ├── auth/                        # Authentication (01-test-auth.sh used by Tekton)
│   ├── operators/                   # Manual operator install scripts
│   ├── roles/                       # RBAC helpers
│   └── chrony/                      # NTP MachineConfigs
│
└── ci-config.yaml                   # Version matrix reference
```

## Secrets Flow

```
Vault (vault.ci.openshift.org)
  ↓ VAULT_TOKEN
osp-ci-secrets/cluster-creds (synced via ExternalSecret)
  ↓ create-secrets.sh
pipelines-ci/ (16 individual K8s secrets)
  ↓ envFrom + secretKeyRef
release-tests task (gauge tests)
```

## Multi-arch Support

The test runner image `ubi9/go-toolset:latest` supports amd64, arm64, ppc64le, s390x. Tools (`oc`, `gauge`) are auto-installed at runtime:
- `oc` version is matched to the cluster's OpenShift version
- `gauge` is built from source via `go install` (works on all architectures)
