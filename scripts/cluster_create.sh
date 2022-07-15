#!/bin/bash
clusterNames=("worker1" "worker2" "worker3" "worker4" "worker5")
echo "Generating YAML to create ${#clusterNames[@]}" clusters

mkdir -p deploy/management/clusters

for clusterName in "${clusterNames[@]}" ; do
    clusterctl generate cluster "$clusterName" \
    --kubernetes-version v1.22.6 \
    --control-plane-machine-count=3 \
    --worker-machine-count=3 \
    > deploy/management/clusters/"$clusterName".yaml

    echo "$clusterName"
done

echo "\n All Done."
