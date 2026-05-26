#!/bin/sh

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

echo "Creating a secret for Red Hat SSO"
oc create secret generic redhat-sso --from-literal=clientSecret=$(cat $DIR/../secrets/redhat-sso) -n openshift-config

echo "Creating an SSO identity provider"
oc apply -f $DIR/prod-oauth.yaml

echo "Creating group for admins"
oc apply -f $DIR/admin-group.yaml

echo "Adding cluster-admin role to the group tekton-team-admins"
oc adm policy add-cluster-role-to-group cluster-admin tekton-team-admins

echo "Adding admin role to the group tekton-team in namespace \"pipelines-ci\""
oc adm policy add-role-to-group admin tekton-team -n pipelines-ci

echo "Deleting kubeadmin acccount"
oc delete secrets kubeadmin -n kube-system

