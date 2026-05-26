#!/usr/bin/env bash

echo "Image pruner enabled and scheduled to run nightly"
kubectl patch imagepruners.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"schedule":"0 0 * * *", "suspend": false}}'

