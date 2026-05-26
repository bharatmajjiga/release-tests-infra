#!/bin/sh

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

HTPASS_SECRET=$(oc get secret -n openshift-config htpass-secret -o jsonpath={.data.htpasswd} 2> /dev/null)
if [ $? == 0 ]; then
  echo "Secret 'htpass-secret' found. This is expected on CRC or Flexy-provisioned clusters."

  HTPASSWD_FILE=$(mktemp /tmp/htpasswd.XXX)
  echo $HTPASS_SECRET | base64 -d >> "$HTPASSWD_FILE"
  cat $DIR/users.htpasswd >> "$HTPASSWD_FILE"

  echo "Updating secret htpass-secret"
  PATCH="{\"data\":{\"htpasswd\":\"$(cat $HTPASSWD_FILE | base64 -w 0)\"}}"
  oc patch secret htpass-secret -n openshift-config -p=$PATCH -v=1
  rm "$HTPASSWD_FILE"
else
  echo "Creating secret htpass-secret"
  oc create secret generic htpass-secret --from-file=htpasswd="$DIR/users.htpasswd" -n openshift-config
fi

echo "Creating a htpasswd identity provider"
oc apply -f $DIR/test-oauth.yaml

echo "Creating cluster role bindings"
oc get clusterrolebinding pipelinesdeveloper_basic_user &> /dev/null
if [ $? != 0 ]; then
    oc create clusterrolebinding pipelinesdeveloper_basic_user --clusterrole=basic-user --user=pipelinesdeveloper
fi

oc get clusterrolebinding consoledeveloper_self_provisioner &> /dev/null
if [ $? != 0 ]; then
    oc create clusterrolebinding consoledeveloper_self_provisioner --clusterrole=self-provisioner --user=consoledeveloper
fi

oc get clusterrolebinding consoledeveloper_view &> /dev/null
if [ $? != 0 ]; then
    oc create clusterrolebinding consoledeveloper_view --clusterrole=view --user=consoledeveloper
fi
