# release-tests-infra — Repository Guide

Read this before changing automation in this repository.

## Purpose

Run OpenShift Pipelines acceptance tests (Gauge or Ginkgo) via Tekton on any test cluster. Configuration flows from `env.template` / `.env`.

## Workflow

```
.env
  → run-workflow.sh
      → create-secrets.sh
      → setup-pipelines-ci.sh
      → create-pipelinerun.sh
```

Tekton clones repos, runs tests, evaluates results, optionally posts Slack, then schedules PipelineRun deletion.

## Active automation

| Path | Role |
|------|------|
| `env.template` / `.env` | All configuration (do not hardcode values in scripts) |
| `scripts/run-workflow.sh` | Orchestrates secrets → setup → PipelineRun |
| `scripts/setup-pipelines-ci.sh` | Namespace, `cluster-<name>` secret, operator install (optional), Tekton apply |
| `scripts/create-secrets.sh` | K8s secrets from `.env` or Vault |
| `scripts/create-pipelinerun.sh` | Builds PipelineRun from `.env` (preferred over static YAML) |
| `scripts/cluster-login.sh` | `CLUSTER_PLATFORMS` / kubeadmin login helpers |
| `scripts/cleanup-pipeline-pvcs.sh` | Delete per-run workspace PVCs |
| `ci/pipelines/acceptance-tests.yaml` | Main pipeline |
| `ci/tasks/*.yaml` | Tekton tasks applied by setup |
| `config/auth/01-test-auth.sh` | HTPasswd test users (setup-testing-accounts task) |
| `config/auth/users.htpasswd`, `test-oauth.yaml` | Used by 01-test-auth.sh |
| `config/operators/install-pipelines.sh` | Optional pre-Tekton operator install |
| `config/cluster-ca/` | CA file when `CLUSTER_PLATFORMS=true` |
| `secrets/*.yaml` | Secret templates for create-secrets.sh |

## Pipeline layout

- **Workspace**: per-PipelineRun PVC (`data`) with subPaths: `infra-git`, `release-tests-git`, `gomod-cache`, `results`, `build-artifacts`
- **Post-test**: optional `send-slack-notification` (after evaluate/uninstall), then `cleanup-pipelinerun` in finally
- **When expressions**: standard Tekton `input/operator/values` only (no CEL)

## Rules for changes

1. New config → add to `env.template` first, read via `$VAR` in scripts
2. PipelineRun params → set in `create-pipelinerun.sh`, not duplicated in static YAML
3. Do not commit `.env` or secret values
4. Default namespace: `pipelines-ci` (`NAMESPACE` override)

## Not in scope (removed / out of tree)

- Static `ci/pipelineruns/*.yaml` — use `create-pipelinerun.sh`
- Upload artifacts / ReportPortal pipeline tasks (reverted; env vars may remain for future use)
- Shared `toolchain-cache` PVC — gomod cache is per-run under `data/gomod-cache`
- Plumbing cluster-provisioning scripts (hive, gitops, logging, minio, …)
