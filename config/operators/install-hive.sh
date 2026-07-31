echo "Installing OpenShift Hive operator"

CHANNEL=${CHANNEL:-alpha}
CATALOG_SOURCE=${CATALOG_SOURCE:-community-operators}
OPERATOR_GROUP=${OPERATOR_GROUP:-hive-operator-group}
NAMESPACE=${NAMESPACE:-hive}

echo -e "Create operator group"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $OPERATOR_GROUP
  namespace: $NAMESPACE
spec: 
  targetNamespaces: 
    - $NAMESPACE
  upgradeStrategy: Default
EOF

echo -e "Ensure hive subscription exists"
oc get subscriptions.operators.coreos.com hive-operator -n hive 2>/dev/null || \
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hive-operator
  namespace: $NAMESPACE
spec:
  channel: $CHANNEL
  installPlanApproval: Automatic
  name: hive-operator
  source: $CATALOG_SOURCE
  sourceNamespace: openshift-marketplace
EOF

sleep 180

echo -e "Create hive config"
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: HiveConfig
metadata:
  name: hive
  namespace: $NAMESPACE
spec:
  logLevel: debug
  targetNamespace: $NAMESPACE
  globalPullSecretRef:
    name: global-pull-secret
EOF

function verify_pod_exists() {
  pod=$1
  label=$2
  for i in {1..150}; do  # timeout after 5 minutes
    pods="$(oc get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l)"
    if [[ "${pods}" -ge 1 ]]; then
      echo -e "\nWaiting for $pod pod"
      oc wait --for=condition=Ready -n $NAMESPACE -l $label pod --timeout=5m
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
  sleep 5
}

verify_pod_exists "operator" "control-plane=hive-operator"
sleep 180
verify_pod_exists "controller" "control-plane=controller-manager"
verify_pod_exists "clustersync" "control-plane=clustersync"
verify_pod_exists "hiveadmission" "app=hiveadmission"