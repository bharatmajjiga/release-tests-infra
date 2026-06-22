# release-tests-infra — Repository Guide

Read this before changing automation in this repository.

## Purpose

Run OpenShift Pipelines acceptance tests (Gauge or Ginkgo) via Tekton on any test cluster. Configuration flows from `env.template` / `.env`.

## Workflow

```
.env
  → scripts/run-workflow.sh
      → scripts/hack/create-secrets.sh
      → scripts/hack/setup-pipelines-ci.sh
      → scripts/hack/create-pipelinerun.sh
```

Tekton clones repos, runs tests, evaluates results, optionally posts Slack, then schedules PipelineRun deletion.

## Active automation

| Path | Role |
|------|------|
| `env.template` / `.env` | All configuration (do not hardcode values in scripts) |
| `scripts/run-workflow.sh` | Entry point: orchestrates secrets → setup → PipelineRun |
| `scripts/hack/setup-pipelines-ci.sh` | Namespace, `cluster-<name>` secret, operator install (optional), Tekton apply |
| `scripts/hack/create-secrets.sh` | K8s secrets from `.env` or Vault |
| `scripts/hack/create-pipelinerun.sh` | Builds acceptance-tests PipelineRun from `.env` |
| `scripts/hack/run-upgrade-tests.sh` | Upgrade-tests PipelineRun (AWS IPI provision + destroy) |
| `scripts/hack/cluster-login.sh` | `INSTALLER` / kubeadmin login helpers |
| `scripts/hack/cleanup-pipeline-pvcs.sh` | Delete per-run workspace PVCs |
| `scripts/hack/cleanup-orphan-clusters.sh` | Destroy orphaned AWS IPI clusters via tags |
| `ci/pipelines/acceptance-tests.yaml` | Acceptance pipeline (existing cluster) |
| `ci/pipelines/upgrade-tests.yaml` | Upgrade pipeline (provision → pre-upgrade → upgrade → test → destroy) |
| `ci/pipelines/destroy-cluster.yaml` | Manual cluster destruction pipeline |
| `ci/tasks/*.yaml` | Tekton tasks applied by setup |
| `ci/tasks/provision-cluster.yaml` | AWS IPI cluster provisioning via openshift-install |
| `ci/tasks/destroy-cluster.yaml` | AWS IPI cluster destruction + orphan scan |
| `ci/cronjobs/cleanup-orphan-clusters.yaml` | Hourly orphan cluster cleanup CronJob |
| `config/auth/01-test-auth.sh` | HTPasswd test users (setup-testing-accounts task) |
| `config/auth/users.htpasswd`, `test-oauth.yaml` | Used by 01-test-auth.sh |
| `config/operators/install-pipelines.sh` | Optional pre-Tekton operator install |
| `config/cluster-configs/` | CA file when `INSTALLER=cluster-platforms` |
| `secrets/*.yaml` | Secret templates for create-secrets.sh |

## Pipeline layout

- **Workspace**: per-PipelineRun PVC (`data`) with subPaths: `infra-git`, `release-tests-git`, `gomod-cache`, `results`, `build-artifacts`
- **Post-test**: optional `send-slack-notification` (after evaluate/uninstall), then `cleanup-pipelinerun` in finally
- **When expressions**: standard Tekton `input/operator/values` only (no CEL)

## Rules for changes

1. New config → add to `env.template` first, read via `$VAR` in scripts
2. PipelineRun params → set in `scripts/hack/create-pipelinerun.sh`, not duplicated in static YAML
3. Do not commit `.env` or secret values
4. Default namespace: `pipelines-ci` (`NAMESPACE` override)

## INSTALLER modes

| Value | Behavior |
|-------|----------|
| `cluster-platforms` | Existing cluster (OC_TOKEN + CA cert login) |
| `none` | Existing cluster (kubeadmin login) |
| `aws-ipi` | Provisions AWS IPI cluster, tests, destroys in finally. Tags all AWS resources for orphan cleanup. |

## Not in scope (removed / out of tree)

- Static `ci/pipelineruns/*.yaml` — use `scripts/hack/create-pipelinerun.sh`
- Upload artifacts / ReportPortal pipeline tasks (reverted; env vars may remain for future use)
- Shared `toolchain-cache` PVC — gomod cache is per-run under `data/gomod-cache`
- Hive ClusterPools (requires long-lived management cluster; use aws-ipi instead)
