#!/usr/bin/env bash

echo "Add certificate for Upshift registry"
oc create configmap registry-cas -n openshift-config --from-file=docker-registry.upshift.redhat.com=config/redhat-internal.crt

oc patch image.config.openshift.io/cluster --patch '{"spec":{"additionalTrustedCA":{"name":"registry-cas"}}}' --type=merge

