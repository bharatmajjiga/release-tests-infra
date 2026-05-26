#!/usr/bin/env bash

set +x

export NAMESPACE="openshift-pipelines"

oc create route -n ${NAMESPACE} passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080
