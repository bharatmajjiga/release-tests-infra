#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

if [ -z $1 ]; then
  echo "This script will create a new dev namespace on CI cluster and configure it for use."
  echo -e "This script should be run by users who can unlock secrets in this repository and are cluster admins.\n"
  echo "Usage:"
  echo "  $0 <username>"
  echo "  $0 <username> <namespace>"
  exit 1
fi
USERNAME=$1

if [ -z $2 ]; then
  NAMESPACE=${USERNAME}
else
  NAMESPACE=$2
fi

echo "Ensure namespace $NAMESPACE exists"
oc get ns "$NAMESPACE" 2>/dev/null && oc project $NAMESPACE || {

cat <<EOF | oc apply -f -
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  annotations:
    openshift.io/requester: ${USERNAME}
  creationTimestamp: null
  name: ${NAMESPACE}
spec: {}
status: {}
EOF

cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  creationTimestamp: null
  name: admin
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${USERNAME}
EOF
}

oc apply -f "$DIR/../ci/pipelines" -n "$NAMESPACE" --as $USERNAME
oc apply -f "$DIR/../ci/tasks" -n "$NAMESPACE" --as $USERNAME

grep -qsPa "\x00GITCRYPT"  $(git crypt status | grep -v '^not' | awk '{print $2}')

if [ $? = 0 ]; then
  echo -e "Seems your credentials are locked, unlock the git repo now!"
  git crypt unlock
fi

sed -i "s/artifacts.ospqa.com/artifacts-stage.ospqa.com/" "$DIR/secrets/secrets.env"
oc project $NAMESPACE
sh "$DIR/secrets/secrets.sh"
git checkout "$DIR/secrets/secrets.env"
