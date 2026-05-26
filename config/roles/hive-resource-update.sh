#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

echo "Creating a cluster role and role binding for hive resource update"
oc apply -f $DIR/hive-resource-update.yaml -n hive

