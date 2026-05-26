#!/usr/bin/env bash

echo "Uninstalling OpenShift Pipelines operator"

# Delete instance (name: cluster) of config.operator.tekton.dev
oc delete tektonaddons.operator.tekton.dev addon --cascade=true
oc delete tektonconfigs.operator.tekton.dev config --cascade=true
oc delete tektonpipelines.operator.tekton.dev pipeline --cascade=true
oc delete tektontriggers.operator.tekton.dev trigger --cascade=true

# Add some wait, before deleting the controller, as it could handle the event
sleep 30

# Delete ClusterServiceVersion (CSV)
oc delete $(oc get csv  -n openshift-operators -o name | grep openshift-pipelines-operator) -n openshift-operators --cascade=true

# Delete InstallPlan
oc delete -n openshift-operators installplan $(oc get subscription openshift-pipelines-operator-rh -n openshift-operators -o jsonpath='{.status.installplan.name}')  --cascade=true

# Delete Pipelines operator subscription
oc delete subscription openshift-pipelines-operator-rh -n openshift-operators
