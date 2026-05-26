#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

echo "Creating a service account, cluster role and role binding for cloud resource pruner"
oc apply -f $DIR/cloud-pruner.yaml

echo "Adding new service account to the pipelines-scc-rolebinding"
oc patch rolebinding pipelines-scc-rolebinding -n pipelines-ci --type=merge -p '{"subjects":[{"kind":"ServiceAccount","name":"cloud-pruner","namespace":"pipelines-ci"},{"kind":"ServiceAccount","name":"pipeline","namespace":"pipelines-ci"}]}'

