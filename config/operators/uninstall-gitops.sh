#!/usr/bin/env bash

echo "Uninstalling OpenShift Gitops operator"

oc delete gitopsservice cluster -n openshift-gitops

# Add some wait, before deleting the controller, as it could handle the event
sleep 30

# Delete ClusterServiceVersion (CSV)
oc delete $(oc get csv -n openshift-operators -o name | grep openshift-gipops) -n openshift-operators --cascade=true

# Delete InstallPlan
oc delete -n openshift-operators installplan $(oc get subscription openshift-gitops-operator -n openshift-operators -o jsonpath='{.status.installplan.name}')  --cascade=true

# Delete Pipelines operator subscription
oc delete subscription openshift-gitops-operator -n openshift-operators
