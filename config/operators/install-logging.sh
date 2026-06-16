#!/usr/bin/env bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=$(oc get clusterversion version -o go-template='{{.status.desired.version}}')
if [[ -z "$VERSION" ]]; then
  CHANNEL=${1:-"stable-6.3"}
elif [[ $VERSION =~ ^4\.(2[2-9]|[3-9][0-9]|[0-9]{3,}).*$ ]]; then
  CHANNEL="stable-6.5"
elif [[ $VERSION =~ ^4\.2[0-1].* ]]; then
  CHANNEL="stable-6.4"
else
  CHANNEL="stable-6.3"
fi

apply_minio_statefulset() {
  if [ -n "${PRODUCTION:-}" ]; then
    sed "s/storage: .*Gi/storage: 1Gi/" "$DIR/minio-statefulset.yaml"
  else
    local digest
    digest=$(skopeo inspect --override-os linux docker://quay.io/minio/minio | jq -r '.Digest')
    if [[ -z "$digest" || "$digest" == "null" ]]; then
      echo "WARN: skopeo digest lookup failed, using :latest tag"
      cat "$DIR/minio-statefulset.yaml"
    else
      sed "s|quay.io/minio/minio:latest|quay.io/minio/minio@${digest}|" "$DIR/minio-statefulset.yaml"
    fi
  fi | oc apply -f -
}

install_subscription() {
  local ns=$1 sub=$2 pkg=$3
  oc create namespace "$ns" 2>/dev/null || true
  oc get operatorgroup -n "$ns" 2>/dev/null | grep -q "$ns" || oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: ${ns}-
  namespace: ${ns}
EOF
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${sub}
  namespace: ${ns}
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: ${pkg}
  channel: ${CHANNEL}
EOF
  oc label ns "$ns" openshift.io/cluster-monitoring=true --overwrite
}

wait_for_operator_pod() {
  local ns=$1 label=$2 grep_pat=$3 desc=$4
  echo "Check if ${desc} pod is ready"
  for i in {1..150}; do
    local pods
    pods=$(oc get pods -n "$ns" --no-headers -l "$label" 2>/dev/null | grep "$grep_pat" | wc -l)
    if [[ "${pods}" -ge 1 ]]; then
      echo -e "\nWaiting for ${desc} pod"
      oc wait --for=condition=Ready -n "$ns" -l "$label" pod --timeout=5m
      retval=$?
      [[ "${retval}" -gt 0 ]] && exit "${retval}"
      return 0
    fi
    [[ "${i}" -eq 150 ]] && { echo "Timeout: pod was not created."; exit 2; }
    echo -n "."
    sleep 2
  done
}

create_minio_bucket() {
  local endpoint=$1 bucket=$2
  oc run minio-bucket-setup --rm -i --restart=Never -n minio \
    --image=quay.io/minio/mc:latest \
    --overrides="{
      \"spec\":{\"containers\":[{
        \"name\":\"minio-bucket-setup\",
        \"image\":\"quay.io/minio/mc:latest\",
        \"command\":[\"sh\",\"-c\",\"mc alias set myminio ${endpoint} minioadmin minioadmin && mc mb --ignore-existing myminio/${bucket}\"],
        \"env\":[{\"name\":\"HOME\",\"value\":\"/tmp\"}],
        \"securityContext\":{\"allowPrivilegeEscalation\":false,\"runAsNonRoot\":true,\"capabilities\":{\"drop\":[\"ALL\"]},\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}
      }]}
    }"
}

# --- MinIO ---
echo "Configuring MinIO"
oc create namespace minio 2>/dev/null || true
apply_minio_statefulset
oc apply -f "$DIR/minio-service.yaml"
oc expose svc/minio -n minio 2>/dev/null || true
oc wait pod minio-0 --for=condition=Ready --timeout=120s -n minio
MINIO_ROUTE="http://$(oc get route minio -n minio -o jsonpath='{.spec.host}')"

echo -e "\nCreating MinIO bucket 'loki' via route: ${MINIO_ROUTE}"
create_minio_bucket "${MINIO_ROUTE}" loki

# --- Loki operator ---
echo -e "\nInstalling Loki operator"
install_subscription openshift-operators-redhat loki-operator loki-operator
wait_for_operator_pod openshift-operators-redhat name=loki-operator-controller-manager loki "Loki operator"

# --- OpenShift Logging operator ---
echo -e "\nInstalling OpenShift Logging operator"
install_subscription openshift-logging cluster-logging cluster-logging
wait_for_operator_pod openshift-logging name=cluster-logging-operator logging-operator "Openshift Logging operator"

# --- LokiStack resources ---
echo -e "\nCreating secret logging-loki-minio in namespace openshift-logging"
oc create secret generic logging-loki-minio -n openshift-logging \
  --from-literal=bucketnames=loki \
  --from-literal=endpoint="${MINIO_ROUTE}" \
  --from-literal=access_key_id=minioadmin \
  --from-literal=access_key_secret=minioadmin \
  --dry-run=client -o yaml | oc apply -f -

echo -e "\nCreating LokiStack"
LOKISTACK_FILE="$DIR/lokistack-$([ -n "${PRODUCTION:-}" ] && echo prod || echo test).yaml"
sed "s/storageClassName.*/storageClassName: $(oc get storageclass | grep default | cut -d ' ' -f1)/g" \
  "$LOKISTACK_FILE" | oc apply -f -

echo -e "\nCreating service account and configuring roles"
oc create sa collector -n openshift-logging 2>/dev/null || true
oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:collector
oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:collector
oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:collector
oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:collector

echo -e "\nCreating cluster log forwarder"
oc apply -f "$DIR/clusterlogforwarder.yaml"
