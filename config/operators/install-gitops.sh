#!/usr/bin/env bash

echo "Installing OpenShift GitOps operator"

CHANNEL=${1:-latest}
CATALOG_SOURCE=${2:-redhat-operators}

echo -e "Ensure gitops subscription exists"
oc get subscription openshift-gitops-operator -n openshift-operators 2>/dev/null || \
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: $CHANNEL
  tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
  installPlanApproval: Manual
  name: openshift-gitops-operator
  source: $CATALOG_SOURCE
  sourceNamespace: openshift-marketplace
EOF

sleep 2
echo "Approve initial installplan"
installplan=$(oc get -n openshift-operators installplan -l operators.coreos.com/openshift-gitops-operator.openshift-operators -o name)
oc patch ${installplan} \
    --namespace openshift-operators \
    --type merge \
    --patch '{"spec":{"approved":true}}'

sleep 5
for i in {1..150}; do  # timeout after 5 minutes
  pods="$(oc get pods -n openshift-operators --no-headers 2>/dev/null | wc -l)"
  if [[ "${pods}" -ge 1 ]]; then
    echo -e "\nWaiting for GitOps operator pod"
    oc wait --for=condition=Ready -n openshift-operators -l control-plane=gitops-operator pod --timeout=5m
    retval=$?
    if [[ "${retval}" -gt 0 ]]; then exit "${retval}"; else break; fi
  fi
  if [[ "${i}" -eq 150 ]]; then
    echo "Timeout: pod was not created."
    exit 2
  fi
  echo -n "."
  sleep 2
done

for i in {1..150}; do  # timeout after 5 minutes
  pods="$(oc get pods -n openshift-gitops --no-headers 2>/dev/null | wc -l)"
  if [[ "${pods}" -ge 4 ]]; then
    echo -e "\nWaiting for GitOps pods"
    oc wait --for=condition=Ready -n openshift-gitops pod --timeout=5m \
      -l 'app.kubernetes.io/name in (cluster,kam,openshift-gitops-application-controller,
      openshift-gitops-applicationset-controller,openshift-gitops-dex-server,
      openshift-gitops-redis,openshift-gitops-repo-server,openshift-gitops-server)'
    retval=$?
    if [[ "${retval}" -gt 0 ]]; then exit "${retval}"; else break; fi
  fi
  if [[ "${i}" -eq 150 ]]; then
    echo "Timeout: pod was not created."
    exit 2
  fi
  echo -n "."
  sleep 2
done

oc patch argocd openshift-gitops -n openshift-gitops --patch '{"spec":{"rbac":{"defaultPolicy":"role:readonly","policy":"g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\ng, tekton-team, role:admin"}}}' --type=merge
