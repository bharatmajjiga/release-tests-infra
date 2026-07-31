#!/usr/bin/env bash

echo "Installing OpenShift Serverless operator"

CHANNEL=${1:-stable}
CATALOG_SOURCE=${2:-redhat-operators}
OPERATOR_NAMESPACE=${3:-openshift-operators}

cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  source: $CATALOG_SOURCE
  sourceNamespace: openshift-marketplace
  name: serverless-operator
  channel: $CHANNEL
EOF

echo "Check if Openshift Serverless Operator pod is ready"
for i in {1..150}; do  # timeout after 5 minutes
  pods="$(oc get pods -n ${OPERATOR_NAMESPACE} --no-headers -l name=knative-operator 2>/dev/null |grep knative-operator | wc -l)"
  if [[ "${pods}" -ge 1 ]]; then
    echo -e "\nWaiting for Serverless operator pod"
    oc wait --for=condition=Ready -n ${OPERATOR_NAMESPACE} -l name=knative-operator pod --timeout=5m
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
echo "Openshift Serverless Operator is installed and Running!"

echo "Start Installation of Knative Serving"
sleep 20

cat <<-EOF | oc apply -f -
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec: {}
EOF

sleep 10
echo "Waiting for Knative Serving's condition DependenciesInstalled"
oc wait --for=condition=DependenciesInstalled knativeserving.operator.knative.dev/knative-serving -n knative-serving --timeout=10m

echo "Waiting for Knative Serving's condition DeploymentsAvailable"
oc wait --for=condition=DeploymentsAvailable knativeserving.operator.knative.dev/knative-serving -n knative-serving --timeout=10m

echo "Waiting for Knative Serving's condition InstallSucceeded"
oc wait --for=condition=InstallSucceeded knativeserving.operator.knative.dev/knative-serving -n knative-serving --timeout=10m

echo "Waiting for Knative Serving's condition Ready"
oc wait --for=condition=Ready knativeserving.operator.knative.dev/knative-serving -n knative-serving --timeout=10m
