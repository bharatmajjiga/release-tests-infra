#!/usr/bin/env bash

echo "Updating the 'builder' service account for the skopeo-copy cluster task"
oc patch sa builder -n pipelines-ci -p '{"secrets": [{"name": "skopeo-copy-quay-creds"}]}'