#!/usr/bin/env bash

echo "Installing Container Security operator"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: container-security-operator
  namespace: openshift-operators
spec:
  channel: stable-3.6
  name: container-security-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
