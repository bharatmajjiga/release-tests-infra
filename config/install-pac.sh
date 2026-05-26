#!/usr/bin/env bash

echo "Configuring OpenShift PAC"

WEBHOOK_PROXY_URL=${WEBHOOK_PROXY_URL:-https://hook.pipelinesascode.com/oLHu7IjUV4wGm2tJ}
PAC_CONTROLLER_ROUTE=https://$(oc get route -n openshift-pipelines pipelines-as-code-controller -o jsonpath='{.spec.host}')

echo "PAC controller route: $PAC_CONTROLLER_ROUTE"

echo "Configure event forwarding between the PROXY url and the OpenShift cluster"
cat <<EOF | oc apply -f -
kind: Deployment
apiVersion: apps/v1
metadata:
  name: gosmee
  namespace: openshift-pipelines
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gosmee
  template:
    metadata:
      creationTimestamp: null
      labels:
        app: gosmee
    spec:
      containers:
        - name: gosmee
          image: 'ghcr.io/chmouel/gosmee:v0.24.0'
          args:
            - client
            - '--saveDir'
            - /tmp/save
            - $WEBHOOK_PROXY_URL
            - $PAC_CONTROLLER_ROUTE
          resources: {}
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: File
          imagePullPolicy: IfNotPresent
      restartPolicy: Always
      terminationGracePeriodSeconds: 30
      dnsPolicy: ClusterFirst
      securityContext: {}
      schedulerName: default-scheduler
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
      maxSurge: 25%
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
EOF

echo "Create repository CR"
cat <<EOF | oc apply -f -
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: release-tests-paac
  namespace: pipelines-ci
spec:
  url: "https://github.com/openshift-pipelines/release-tests"
EOF