#!/usr/bin/env bash

echo "Installing OpenShift Pipelines operator"

CHANNEL=${CHANNEL:-stable}
CATALOG_SOURCE=${CATALOG_SOURCE:-redhat-operators}

echo -e "Ensure pipelines subscription exists"
oc get subscription openshift-pipelines-operator-rh -n openshift-operators 2>/dev/null || \
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: $CHANNEL
  config:
    nodeSelector:
      node-role.kubernetes.io/master: ''
    tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
  installPlanApproval: Manual
  name: openshift-pipelines-operator-rh
  source: $CATALOG_SOURCE
  sourceNamespace: openshift-marketplace
EOF

sleep 2
echo "Approve initial installplan"
installplan=$(oc get -n openshift-operators installplan -l operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators -o name)
oc patch ${installplan} \
    --namespace openshift-operators \
    --type merge \
    --patch '{"spec":{"approved":true}}'

for i in {1..150}; do  # timeout after 5 minutes
  pods="$(oc get pods -n openshift-operators --no-headers 2>/dev/null | wc -l)"
  if [[ "${pods}" -ge 1 ]]; then
    echo -e "\nWaiting for Pipelines operator pod"
    oc wait --for=condition=Ready -n openshift-operators -l name=openshift-pipelines-operator pod --timeout=5m
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
  pods="$(oc get pods -n openshift-pipelines --no-headers 2>/dev/null | wc -l)"
  if [[ "${pods}" -ge 4 ]]; then
    echo -e "\nWaiting for Pipelines and Triggers pods"
    oc wait --for=condition=Ready -n openshift-pipelines pod --timeout=5m \
      -l 'app in (tekton-pipelines-controller,tekton-pipelines-webhook,tekton-triggers-controller,
      tekton-triggers-webhook)'
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
