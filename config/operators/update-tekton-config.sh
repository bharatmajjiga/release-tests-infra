#!/usr/bin/env bash

echo "Updating TektonConfig - scope when expressions to task"
oc patch tektonconfig config --type=merge -p '{"spec":{"pipeline":{"scope-when-expressions-to-task":true}}}'

echo "Updating TektonConfig with tekton-pruner"
oc patch tektonconfig config --type=merge -p '{"spec":{"pruner":{"disabled":true}}}'
oc patch tektonconfig config --type=merge -p '{"spec":{"tektonpruner":{"disabled":false,"global-config":{"enforcedConfigLevel":"global","ttlSecondsAfterFinished":259200}}}}'

echo "Updating TektonConfig - run on infra nodes"
oc patch tektonconfig config --type=merge -p '{"spec":{"config":{"nodeSelector":{"node-role.kubernetes.io/master":""},"tolerations":[{"key":"node-role.kubernetes.io/master","effect":"NoSchedule","operator":"Exists"}]}}}'

echo "Updating TektonConfig - stateful set"
oc patch tektonconfig config --type=merge -p '{"spec":{"pipeline":{"performance":{"disable-ha":false,"statefulset-ordinals":true,"replicas":2,"buckets":2}}}}'

echo "Updating TektonConfig - results"
oc patch tektonconfig config --type=merge -p '{"spec":{"result":{"auth_disable":true,"disabled":false,"log_level":"debug","loki_stack_name":"logging-loki","loki_stack_namespace":"openshift-logging","options":{"configMaps":{"config-results-retention-policy":{"data":{"runAt":"3 5 * * 0","maxRetention":"30"}}}}}}}'

echo "Run Tekton Chains only in namespace pipelines-ci"
oc patch tektonconfig config --type=merge -p '{"spec":{"chain":{"disabled":false,"options":{"deployments":{"tekton-chains-controller":{"spec":{"template":{"spec":{"containers":[{"args":["--namespace=pipelines-ci"],"name":"tekton-chains-controller"}]}}}}}}}}}'
