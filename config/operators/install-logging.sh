#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

VERSION=$(oc get clusterversion version -o go-template='{{.status.desired.version}}')

# Determine channel based on OCP version, with fallback to $1 if version retrieval fails
if [[ -z "$VERSION" ]]; then
  # Error case: VERSION is empty, use $1 parameter or default
  CHANNEL=${1:-"stable-6.3"}
elif [[ $VERSION =~ ^4\.(2[0-9]|[3-9][0-9]|[0-9]{3,}).*$ ]]; then
  # OCP 4.20 or above
  CHANNEL="stable-6.4"
else
  # OCP versions below 4.20
  CHANNEL="stable-6.3"
fi

echo "Configuring MinIO"
oc create namespace minio 2> /dev/null

if [ ! -z $PRODUCTION ]; then
  sed -i "s/storage: .*Gi/storage: 100Gi/" $DIR/minio-statefulset.yaml | oc apply -f -
else
  # use sha256 digest so that it works also in disconnected environment
  MINIO_DIGEST=$(skopeo inspect docker://quay.io/minio/minio | jq -r '.Digest')
  sed -i "s|quay.io/minio/minio:latest|quay.io/minio/minio@${MINIO_DIGEST}|" $DIR/minio-statefulset.yaml | oc apply -f -
fi

oc apply -f $DIR/minio-service.yaml
oc expose svc/minio -n minio

oc wait pod "minio-0" --for="condition=Ready" --timeout="120s" -n minio
MINIO_URL=$(oc get route minio -n minio -o jsonpath={.spec.host})

echo -e "\nConfiguring alias myminio in MinIO client"
mc alias set myminio http://${MINIO_URL} minioadmin minioadmin --insecure
echo "Creating MinIO bucket myminio/loki"
mc ls myminio/loki && echo "MinIO bucket myminio/loki already exists" || mc mb myminio/loki

echo -e "\nInstalling Loki operator"
OPERATOR_NAMESPACE=openshift-operators-redhat
oc create namespace $OPERATOR_NAMESPACE 2> /dev/null

oc get operatorgroup -n $OPERATOR_NAMESPACE | grep $OPERATOR_NAMESPACE || cat <<-EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: $OPERATOR_NAMESPACE-
  namespace: $OPERATOR_NAMESPACE
EOF

cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: loki-operator
  channel: $CHANNEL
EOF

oc label ns $OPERATOR_NAMESPACE openshift.io/cluster-monitoring=true

echo "Check if Loki operator pod is ready"
for i in {1..150}; do  # timeout after 5 minutes
  pods="$(oc get pods -n ${OPERATOR_NAMESPACE} --no-headers -l name=loki-operator-controller-manager 2>/dev/null |grep loki | wc -l)"
  if [[ "${pods}" -ge 1 ]]; then
    echo -e "\nWaiting for Loki operator pod"
    oc wait --for=condition=Ready -n ${OPERATOR_NAMESPACE} -l name=loki-operator-controller-manager pod --timeout=5m
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

echo -e "\nInstalling OpenShift Logging operator"
OPERATOR_NAMESPACE=openshift-logging
oc create namespace $OPERATOR_NAMESPACE 2> /dev/null

oc get operatorgroup -n $OPERATOR_NAMESPACE | grep $OPERATOR_NAMESPACE || cat <<-EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: $OPERATOR_NAMESPACE-
  namespace: $OPERATOR_NAMESPACE
EOF

cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: $OPERATOR_NAMESPACE
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: cluster-logging
  channel: $CHANNEL
EOF

oc label ns $OPERATOR_NAMESPACE openshift.io/cluster-monitoring=true

echo "Check if Openshift Logging operator pod is ready"
for i in {1..150}; do  # timeout after 5 minutes
  pods="$(oc get pods -n ${OPERATOR_NAMESPACE} --no-headers -l name=cluster-logging-operator 2>/dev/null |grep logging-operator | wc -l)"
  if [[ "${pods}" -ge 1 ]]; then
    echo -e "\nWaiting for Logging operator pod"
    oc wait --for=condition=Ready -n ${OPERATOR_NAMESPACE} -l name=cluster-logging-operator pod --timeout=5m
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

echo -e "\nCreating secret logging-loki-minio in namespace openshift-logging"
oc create secret generic logging-loki-minio -n openshift-logging \
   --from-literal=bucketnames="loki" \
   --from-literal=endpoint="http://${MINIO_URL}" \
   --from-literal=access_key_id="minioadmin" \
   --from-literal=access_key_secret="minioadmin"

echo -e "\nCreating LokiStack"
if [ ! -z $PRODUCTION ]; then
  LOKISTACK_FILE=$DIR/lokistack-prod.yaml
else
  LOKISTACK_FILE=$DIR/lokistack-test.yaml
fi
sed "s/storageClassName.*/storageClassName: $(oc get storageclass | grep default | cut -d ' ' -f1)/g" $LOKISTACK_FILE | oc apply -f -

echo -e "\nCreating a new service account and configuring roles"
oc create sa collector -n openshift-logging
oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:collector
oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:collector
oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:collector
oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:collector

echo -e "\nCreating cluster log forwarder"
oc apply -f $DIR/clusterlogforwarder.yaml
