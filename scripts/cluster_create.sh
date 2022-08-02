#!/bin/bash
usage() {
    echo "Usage:
    $0 --name|-n CLUSTER_NAME  --location|-l CLUSTER_LOCATION
    e.g. CLUSTER_NAME=cluster01 CLUSTER_LOCATION=westus2 $0
    Environment Variables        Arguments      Description
    ---------------------------------------------------------------------------
    [required] CLUSTER_NAME      --name|-n      Cluster Name (max 10 characters)
    [required] CLUSTER_LOCATION  --location|-l  Cluster Location
    "
}

DEPLOY_DIR="deploy/clusters"

while [ $# -gt 0 ]; do
    opt="$1" value="$2"
    case "$opt" in
        -n|--name)
            CLUSTER_NAME=$value;shift 1;;
        -l|--location)
            CLUSTER_LOCATION="$value";shift 1;;
        -h|--help)
            usage;exit 0;;
        *)
            usage; exit 1;;
    esac
    shift 1
done
# Check variables
[[  -z ${CLUSTER_NAME} ||
    -z ${CLUSTER_LOCATION} ]] && echo "Make sure all parameters have been passed.">&2 && usage && exit 1
[[ ! $CLUSTER_NAME =~ ^[a-zA-Z0-9]{3,10}$ ]] && echo "Cluster Name must be alphanumeric and between 3-10 characters long.">&2 && usage && exit 1
[[ ! $CLUSTER_LOCATION =~ ^(eastus|eastus2|centralus|southcentralus|westus2|westus3)$ ]] && echo "Cluster Location must be one of eastus|eastus2|centralus|southcentralus|westus2|westus3">&2 && usage && exit 1

echo "Creating HelmRelease for worker cluster $CLUSTER_NAME in $CLUSTER_LOCATION ..."

mkdir -p $DEPLOY_DIR
CLUSTER_NAME=$CLUSTER_NAME CLUSTER_LOCATION=$CLUSTER_LOCATION envsubst < templates/aks-cluster-helmrelease.yaml > "$DEPLOY_DIR"/"$CLUSTER_NAME"-"$CLUSTER_LOCATION".yaml

echo "Pushing HelmRelease to upstream ..."

git add "$DEPLOY_DIR"/"$CLUSTER_NAME"-"$CLUSTER_LOCATION".yaml
git commit -m "Added cluster $CLUSTER_NAME"
git push

echo "Flux Reconcile..."

flux reconcile kustomization flux-system --with-source
sleep 5
flux reconcile kustomization clusters

echo "All Done."
