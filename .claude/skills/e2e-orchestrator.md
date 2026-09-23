---
name: e2e-orchestrator
description: >-
  End-to-end orchestrator for OpenShift Pipelines CI: provision cluster →
  configure infrastructure → run acceptance or upgrade tests → monitor →
  analyze results → report → cleanup. Single invocation, fully interactive.
---

# End-to-End Test Orchestrator

## When to activate

Use this skill when the user asks to:
- Run a full test cycle end-to-end
- "Run acceptance tests on OCP X.Y with version Z"
- "Run upgrade tests from X to Y"
- "Provision a cluster and run tests"
- "Set up and run the full pipeline"
- Any request that combines cluster setup + test execution + results

For single operations (just analyze, just provision, just check status), use the `run-tests` skill instead.

---

## Overview

Six phases, executed in order. Each phase gates the next — if a phase fails, stop and offer remediation before continuing.

```
Phase 1: Plan        → Determine operation, collect inputs
Phase 2: Cluster     → Provision or connect to cluster
Phase 3: Infra       → Secrets, namespace, Tekton resources, optional operators
Phase 4: Execute     → Submit PipelineRun
Phase 5: Monitor     → Track progress until completion
Phase 6: Report      → Analyze results, present report, offer next actions
```

---

## Phase 1: Plan

### 1.1 Determine operation type

Use AskQuestion if the user hasn't specified:

```
AskQuestion:
  question: "What type of test run?"
  header: "Test type"
  options:
    - label: "Acceptance tests (Recommended)"
      description: "Run full e2e acceptance suite on existing or new cluster"
    - label: "Upgrade tests"
      description: "Install pre-upgrade version, upgrade, then run post-upgrade tests"
```

Set internal state:
- Acceptance → env file: `env/.env.acceptance`, script: `scripts/run-workflow.sh`
- Upgrade → env file: `env/.env.upgrade`, script: `scripts/run-upgrade-tests.sh`

### 1.2 Read or create the env file

Check if the target env file exists. If not, copy from `env/env.template`:

```bash
cp env/env.template env/.env.acceptance   # or env/.env.upgrade
```

If `env/.env` exists and user said "env details are in env/.env", use that file directly:
```bash
ENV_FILE=env/.env
```

Read the env file and extract current values.

### 1.3 Collect missing inputs

Check required fields based on operation type. Use AskQuestion to collect ALL missing values in ONE prompt (max 4 questions per call — batch into multiple calls if needed).

#### For acceptance tests:

| # | Field | Type | When required |
|---|-------|------|---------------|
| 1 | `INSTALLER` | Options: `none` (Rec), `cluster-platforms`, `aws-ipi` | Always |
| 2 | `CLUSTER_NAME` | Free text | Always |
| 3 | `APISERVER` | Free text | If INSTALLER=none or cluster-platforms |
| 4 | `KUBEADMIN_PASSWORD` | Free text | If INSTALLER=none |
| 5 | `OPERATOR_VERSION` | Free text (e.g., 1.22.6) | Always |
| 6 | `OPERATOR_ENVIRONMENT` | Options: `pre-stage` (Rec), `prod`, `stage` | Always |
| 7 | `KONFLUX_INDEX_IMAGE` | Free text | If pre-stage or stage |
| 8 | `TAGS` | Options: `e2e` (Rec), `sanity` | Always |
| 9 | `TEST_FRAMEWORK` | Options: `gauge` (Rec), `ginkgo` | Always |
| 10 | `TEST_SUITES` | Use full e2e suite from profile | Always |

#### For upgrade tests:

| # | Field | Type | When required |
|---|-------|------|---------------|
| 1 | `INSTALLER` | Options: `none` (Rec), `aws-ipi` | Always |
| 2 | `CLUSTER_NAME` | Free text | Always |
| 3 | `APISERVER` | Free text | If INSTALLER=none |
| 4 | `KUBEADMIN_PASSWORD` | Free text | If INSTALLER=none |
| 5 | `PRE_UPGRADE_VERSION` | Free text (e.g., 1.21.3) | Always |
| 6 | `PRE_UPGRADE_OPERATOR_ENVIRONMENT` | Options: `prod` (Rec), `pre-stage` | Always |
| 7 | `PRE_UPGRADE_KONFLUX_INDEX_IMAGE` | Free text | If pre-stage |
| 8 | `UPGRADE_VERSION` | Free text (e.g., 1.22.6) | Always |
| 9 | `UPGRADE_OPERATOR_ENVIRONMENT` | Options: `pre-stage` (Rec), `prod`, `stage` | Always |
| 10 | `UPGRADE_KONFLUX_INDEX_IMAGE` | Free text | If pre-stage or stage |

#### Auto-set fields (NEVER ask):

- `CATALOG_SOURCE`: `redhat-operators` if prod, `custom-operators` if pre-stage/stage
- `CHANNEL`: auto-resolved from `ci-config.yaml`
- `GIT_RELEASE_TESTS_BRANCH`: auto-resolved from `ci-config.yaml`
- `INSTALL_PIPELINES_OPERATOR`: `true`
- `SEND_SLACK_NOTIFICATION`: `false` (unless user asks)

#### Konflux index image pattern:

When the user provides operator version + environment + OCP version, auto-suggest the index image:

- **pre-stage**: `quay.io/openshift-pipeline/pipelines-index-<ocp_major.minor>:v<operator_version>`
- **stage**: `quay.io/openshift-pipeline/pipelines-index-<ocp_major.minor>:v<operator_version>-stage`

Example: OCP 4.18, operator 1.22.6, pre-stage → `quay.io/openshift-pipeline/pipelines-index-4.18:v1.22.6`

### 1.4 Write and verify

Write collected values to the env file. Re-read to confirm all required fields are populated.

### 1.5 Display plan summary

Print a clear summary before proceeding:

```
╔══════════════════════════════════════════════╗
  E2E Test Plan
  ─────────────────────────────────────────────
  Operation:   Acceptance Tests
  Cluster:     ocp418bbk86 (OCP 4.18)
  Operator:    1.22.6 (pre-stage)
  Index Image: quay.io/openshift-pipeline/pipelines-index-4.18:v1.22.6
  Framework:   gauge
  Tags:        e2e
  Suites:      17 suites (full e2e)
  Env file:    env/.env.acceptance
╚══════════════════════════════════════════════╝
```

Ask for confirmation before proceeding:

```
AskQuestion:
  question: "Proceed with this test plan?"
  header: "Confirm"
  options:
    - label: "Yes, run it (Recommended)"
      description: "Start the full end-to-end workflow"
    - label: "Edit settings"
      description: "Modify one or more settings before running"
    - label: "Dry run"
      description: "Show what would be executed without running"
```

---

## Phase 2: Cluster

### 2.1 Connect or provision

**If INSTALLER=none or cluster-platforms** (existing cluster):

```bash
oc login -u kubeadmin -p "$KUBEADMIN_PASSWORD" "$APISERVER" --insecure-skip-tls-verify=true
```

Verify connectivity:
```bash
oc whoami
oc get clusterversion version -o jsonpath='{.status.desired.version}'
```

**If INSTALLER=aws-ipi** (provision new cluster):

The pipeline handles provisioning — skip to Phase 3. But verify AWS credentials exist:
```bash
oc get secret aws-creds -n pipelines-ci
```

### 2.2 Cluster health pre-flight (existing clusters only)

Run these checks and report any issues before proceeding:

```bash
# Node readiness
oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status'

# OpenShift Pipelines operator status
oc get csv -n openshift-pipelines --no-headers 2>/dev/null

# Available storage classes
oc get sc --no-headers

# Check if pipelines-ci namespace exists
oc get namespace pipelines-ci 2>/dev/null
```

If any nodes are NotReady or cluster is unreachable, stop and report.

---

## Phase 3: Infrastructure Setup

### 3.1 Secrets

```bash
ENV_FILE=<env-file> ./scripts/hack/create-secrets.sh
```

If `CRED_SOURCE=vault` and the Vault token is expired, prompt:

```
AskQuestion:
  question: "Vault token appears expired. How to proceed?"
  header: "Vault auth"
  options:
    - label: "Re-login to Vault (Recommended)"
      description: "Run create-secrets.sh --vault-login for OIDC login"
    - label: "Provide new token"
      description: "Paste a fresh Vault token"
    - label: "Switch to local creds"
      description: "Use credentials from the env file instead"
```

### 3.2 Setup Tekton CI

```bash
ENV_FILE=<env-file> ./scripts/hack/setup-pipelines-ci.sh
```

### 3.3 Optional operators

If `INSTALL_LOGGING_OPERATOR=true`:
```bash
bash config/operators/install-logging.sh
```

If `INSTALL_SERVERLESS_OPERATOR=true`:
```bash
bash config/operators/install-serverless.sh
```

---

## Phase 4: Execute

### 4.1 Submit the PipelineRun

**Acceptance tests:**
```bash
ENV_FILE=<env-file> ./scripts/run-workflow.sh
```

**Upgrade tests:**
```bash
ENV_FILE=<env-file> ./scripts/run-upgrade-tests.sh
```

### 4.2 Capture the PipelineRun name

Parse the script output for the PipelineRun name (pattern: `pipelinerun.tekton.dev/<name>`). Store it for monitoring.

---

## Phase 5: Monitor

### 5.1 Track progress

Poll every 60-90 seconds until the PipelineRun completes. Display a live task tracker:

```bash
# PipelineRun status
oc get pipelinerun -n pipelines-ci <pr-name> -o jsonpath='{.status.conditions[0].reason}'

# Task-level progress
oc get taskrun -n pipelines-ci -l tekton.dev/pipelineRun=<pr-name> \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason,STARTED:.status.startTime'
```

### 5.2 Progress display format

Show a compact task tracker on each poll:

```
⏳ PipelineRun: acceptance-tests-cp-1226-prestage-on-418-abc12
   Duration: 42m | Status: Running

   ✅ provision-cluster          (2m)
   ✅ clone-release-tests-git    (1m)
   ✅ go-mod-cache-gauge         (5m)
   ✅ setup-testing-accounts     (1m)
   ✅ configure-operator         (3m)
   ✅ release-tests-versions     (8m)
   ✅ release-tests-pipelines    (12m)
   🔄 release-tests-triggers    (running 4m...)
   ⏸  release-tests-chains      (pending)
   ⏸  release-tests-pac         (pending)
   ...
   Progress: 7/17 tasks complete
```

### 5.3 Early failure detection

If any task fails, immediately report it but continue monitoring — other parallel tasks may still be running. The pipeline's `finally` block handles cleanup.

### 5.4 Completion

When `status.conditions[0].reason` is `Succeeded`, `Failed`, or `PipelineRunTimeout`, move to Phase 6.

---

## Phase 6: Report & Next Actions

### 6.1 Gather results

```bash
# Full PipelineRun status
oc get pipelinerun -n pipelines-ci <pr-name> -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool

# All TaskRuns with timing
oc get taskrun -n pipelines-ci -l tekton.dev/pipelineRun=<pr-name> \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason,START:.status.startTime,END:.status.completionTime'
```

### 6.2 For failed tasks, pull logs

```bash
# Get pod name
pod=$(oc get taskrun -n pipelines-ci <taskrun-name> -o jsonpath='{.status.podName}')

# Get logs from all steps
for step in $(oc get pod -n pipelines-ci "$pod" -o jsonpath='{.spec.containers[*].name}'); do
  echo "=== $step ==="
  oc logs -n pipelines-ci "$pod" -c "$step" --tail=100
done
```

### 6.3 Correlate with known errors

Check failure logs against the known error patterns:

| Pattern in logs | Root cause | Fix |
|----------------|-----------|-----|
| `exec format error` on gauge-go | Wrong arch binary | Delete gomod-cache PVC, retrigger |
| `ImagePullBackOff` on `registry.stage.redhat.io` | Missing/expired stage creds | Run `create-secrets.sh` with Vault |
| `VpcLimitExceeded` | Too many AWS VPCs | Run `cleanup-orphan-clusters.sh` |
| `InstalledStatus: False` | Operator install stuck | Restart stuck pods in openshift-pipelines |
| `kube:admin` auth error | Wrong admin username | Patch cluster secret: use `kubeadmin` |
| Task timeout (no error in logs) | Slow go module download | Check go-mod-cache completed; verify GOCACHE |
| `CatalogSource not ready` | Index image pull failed | Verify KONFLUX_INDEX_IMAGE exists in registry |
| `subscription not found` | Wrong CHANNEL for version | Check ci-config.yaml channel mapping |
| `context deadline exceeded` | Cluster API timeout | Check node health, cluster load |
| `no matches for kind` | CRD not installed | Operator install may have failed silently |
| `pods "xxx" is forbidden` | RBAC / service account issue | Check setup-testing-accounts task logs |
| `PipelineRunTimeout` | 3h pipeline timeout exceeded | Check which task was slow; increase timeout or reduce suites |

### 6.4 Present the report

```
╔══════════════════════════════════════════════════════════╗
  Test Run Report
  ─────────────────────────────────────────────────────────
  PipelineRun:  acceptance-tests-cp-1226-prestage-on-418-abc12
  Result:       ❌ FAILED
  Duration:     1h 42m
  Pass/Fail:    14/17 tasks passed

  ✅ Passed Tasks (14):
     provision-cluster, clone-release-tests-git, go-mod-cache-gauge,
     setup-testing-accounts, configure-operator, release-tests-versions,
     release-tests-pipelines, release-tests-triggers,
     release-tests-triggers-tls, release-tests-chains,
     release-tests-pac, release-tests-results, release-tests-metrics,
     release-tests-rbac

  ❌ Failed Tasks (3):
     1. release-tests-addon
        Error: context deadline exceeded
        Root cause: Test timed out waiting for addon configuration
        Duration: 30m (timeout)

     2. release-tests-ecosystem
        Error: exec format error
        Root cause: Wrong arch binary in go-mod-cache
        Fix: Delete gomod-cache PVC and retrigger

     3. release-tests-manual-approval
        Error: no matches for kind "ManualApprovalGate"
        Root cause: MAG CRD not installed
        Fix: Check configure-operator task logs

  ⏭  Skipped Tasks (0): none

  📦 Artifacts:
     https://storage.googleapis.com/ospqa-ci-artifacts/CI/1.22.6/acceptance-tests-cp-1226-prestage-on-418-abc12/index.html
╚══════════════════════════════════════════════════════════╝
```

### 6.5 Offer next actions

```
AskQuestion:
  question: "What would you like to do next?"
  header: "Next action"
  options:
    - label: "Retry failed suites only (Recommended)"
      description: "Re-run only the 3 failed test suites on the same cluster"
    - label: "Show full logs for failed tasks"
      description: "Display complete step logs for each failed task"
    - label: "Restart entire PipelineRun"
      description: "Create a new PipelineRun with same parameters"
    - label: "Cleanup and finish"
      description: "Clean up PVCs and optionally destroy the cluster"
```

### Retry failed suites

If user picks "Retry failed suites only":

1. Extract the failed suite names from the report
2. Create a new env file or modify TEST_SUITES to only include failed suites
3. Re-run Phase 4-6 with the reduced suite list

```bash
# Override TEST_SUITES for retry
TEST_SUITES="release-tests-addon,release-tests-ecosystem,release-tests-manual-approval" \
  ENV_FILE=<env-file> ./scripts/hack/create-pipelinerun.sh
```

### Cleanup

If user picks "Cleanup and finish":

```bash
# Clean up workspace PVCs
ENV_FILE=<env-file> ./scripts/hack/cleanup-pipeline-pvcs.sh --finished

# If aws-ipi provisioned cluster and KEEP_CLUSTER=false
# Pipeline's finally block handles this automatically
```

---

## Namespace discovery

Pipeline runs may exist in different namespaces depending on the operation:
- Acceptance tests: `pipelines-ci` (default)
- Upgrade tests: `pipelines-ci` (default) or `releasetest-upgrade-pipelines`

When searching for pipeline runs, check both:
```bash
for ns in pipelines-ci releasetest-upgrade-pipelines; do
  oc get pipelinerun -n "$ns" --sort-by=.metadata.creationTimestamp \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].reason' 2>/dev/null
done
```

If no pipeline runs found, check events for recently cleaned-up runs:
```bash
oc get events -n pipelines-ci --sort-by='.lastTimestamp' --field-selector reason=Started 2>/dev/null | tail -10
```

---

## Auto-resolution from ci-config.yaml

`ci-config.yaml` maps operator major.minor to:
- `channel` → OLM subscription channel (e.g., `pipelines-1.22`)
- `release-tests.revision` → gauge test branch (e.g., `release-v1.22`)
- `release-tests-ginkgo.revision` → ginkgo test branch (e.g., `main`)

Never ask the user for CHANNEL or GIT_RELEASE_TESTS_BRANCH unless they explicitly want to override.

---

## Error recovery

If any phase fails, do NOT proceed to the next phase. Instead:

1. Report what failed and why
2. Offer remediation via AskQuestion
3. After remediation, resume from the failed phase (not from the beginning)

Common phase failures and recovery:

| Phase | Failure | Recovery |
|-------|---------|----------|
| Cluster | Login failed | Check APISERVER/password, retry login |
| Cluster | Nodes NotReady | Wait for nodes, or provision a new cluster |
| Infra | Vault token expired | Re-login with `--vault-login` |
| Infra | setup-pipelines-ci failed | Check namespace permissions, retry |
| Execute | Script validation error | Fix the env file field, re-run |
| Monitor | PipelineRun stuck (no progress >15m) | Check pod events, node resources |
| Report | Failed tasks | Retry failed suites or investigate |
