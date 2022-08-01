# AKS Multi-Cluster Fleet using Cluster API + Flux

> Setup a Kubernetes Multi-cluster fleet using Cluster API and Azure

![License](https://img.shields.io/badge/license-MIT-green.svg)

## Overview

The following is a sample implementation using Codespaces for setting up an Azure Kubernetes Service (AKS) multi-cluster fleet using Cluster API and Flux. This setup is intended for learning and development purposes and is not production-ready.

## Open with Codespaces

> To use you must have Codespaces enabled in your current organization.

- Click the `Code` button on this repo
- Click the `Codespaces` tab
- Click `New Codespace`
- Choose the `4 core` option

![Create Codespace](./images/OpenWithCodespaces.jpg)

## Stopping a Codespace

- Codespaces will shutdown automatically after being idle for 30 minutes
- To shutdown a codespace immediately
  - Click `Codespaces` in the lower left of the browser window
  - Choose `Stop Current Codespace` from the context menu

- You can also rebuild the container that is running your Codespace
  - Any changes in `/workspaces` will be retained
  - Other directories will be reset
  - Click `Codespaces` in the lower left of the browser window
  - Choose `Rebuild Container` from the context menu
  - Confirm your choice

- To delete a Codespace
  - <https://github.com/codespaces>
  - Use the context menu to delete the Codespace
  - Please delete your Codespace once you complete the lab
    - Creating a new Codespace only takes about 45 seconds!

## Azure login

Log in to the Azure subscription used to deploy the management cluster.

```bash
export AZURE_SUBSCRIPTION_ID=<yourSubscriptionId>
az login --use-device-code
az account set --subscription $AZURE_SUBSCRIPTION_ID
```

## Create the Azure Kubernetes Service (AKS) Cluster

To get started, you will need to create an AKS cluster that will manage the lifecycle of all your fleet clusters. The following instructions will guide you on how to deploy the AKS cluster.

```bash
# Set the name of your new resource group in Azure.
export AZURE_RG_NAME=capi-aks
export AZURE_LOCATION=southcentralus

# Check if the resource group name is not already in use
az group list -o table | grep $AZURE_RG_NAME

# Create the new resource group
az group create -n $AZURE_RG_NAME -l $AZURE_LOCATION

# Create the AKS Cluster (this will take around 5 to 10 minutes)
az aks create -g $AZURE_RG_NAME -n capi-management --node-count 1 --generate-ssh-keys

# Connect to the AKS cluster
az aks get-credentials --resource-group $AZURE_RG_NAME --name capi-management

# Verify AKS node is ready
kubectl get nodes

# You should be able to see the nodepool to be in Ready state

# NAME                                STATUS   ROLES   AGE     VERSION
# aks-nodepool1-34273201-vmss000000   Ready    agent   4m15s   v1.22.11
```

## Initialize the Management Cluster with Cluster API

Now that the AKS cluster is created, it will be initialized with Cluster API to become the management cluster. The management cluster allows you to control and maintain the fleet of worker clusters

```bash

# Enable support for managed topologies and experimental features
export CLUSTER_TOPOLOGY=true
export EXP_AKS=true
export EXP_MACHINE_POOL=true

# Create an Azure Service Principal in the Azure portal. (Note: Make sure this Service Principal has access to the resource group)
# TODO: Automate the service principal creation using the Azure CLI

export AZURE_TENANT_ID="<Tenant>"
export AZURE_CLIENT_ID="<AppId>"
export AZURE_CLIENT_SECRET="<Password>"

# Base64 encode the variables
export AZURE_SUBSCRIPTION_ID_B64="$(echo -n "$AZURE_SUBSCRIPTION_ID" | base64 | tr -d '\n')"
export AZURE_TENANT_ID_B64="$(echo -n "$AZURE_TENANT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_ID_B64="$(echo -n "$AZURE_CLIENT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_SECRET_B64="$(echo -n "$AZURE_CLIENT_SECRET" | base64 | tr -d '\n')"

# Settings needed for AzureClusterIdentity used by the AzureCluster
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

# Create a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"

# Initialize the management cluster for azure
clusterctl init --infrastructure azure

# Create and apply an AzureClusterIdentity
envsubst < templates/aks-cluster-identity.yaml | kubectl apply -f -
```

## Install and Configure Flux in the Management Cluster

Bootstrapping the management cluster with Flux will facilitate the deployment of worker clusters.

```bash
# Install Flux
flux install

# Verify Flux install
flux check

# For flux to work, you will need to create a personal access token (PAT) that has repo read access
export GIT_PAT=<yourGitPat>
export GIT_BRANCH=`git config user.name | sed 's/ //g'`$RANDOM
export GIT_REPO=`git config remote.origin.url`

git checkout -b $GIT_BRANCH
git push --set-upstream origin $GIT_BRANCH

# Flux bootstrap (set $GITHUB_PAT for the cluster to use)
flux bootstrap git \
  --url ${GIT_REPO}\
  --branch ${GIT_BRANCH} \
  --token-auth \
  --password ${GIT_PAT} \
  --path "/deploy/management/bootstrap"

# Pull latest changes
git pull

# Force Flux reconcile
flux reconcile source git flux-system

flux reconcile kustomization flux-system
```

## Deploy worker cluster using Cluster API and Flux v2

Now that the management cluster has been initialized with CAPI and Flux, let us generate a few cluster crds using our helper script.

```bash
# Set Cluster prefix and location
export CLUSTER_PREFIX=cluster01
export CLUSTER_LOCATION=southcentralus

# This script will generate a new HelmRelease file under deploy/management/clusters. This file will then be reconciled by Flux and deploy a new worker cluster.
./scripts/cluster_create.sh -n $CLUSTER_PREFIX -l $CLUSTER_LOCATION

# Note: It takes about 6 minutes for the cluster to be provisioned, you may check the status of the deployment by running
kubectl get clusters

export CLUSTER_NAME=$CLUSTER_LOCATION-$CLUSTER_PREFIX-aks

# Shows a hierachical view of dependencies
clusterctl describe cluster $CLUSTER_NAME

# Generate kubeconfig for cluster
clusterctl get kubeconfig $CLUSTER_NAME  > kubeconfig/$CLUSTER_NAME.kubeconfig

# Check worker cluster nodes
kubectl --kubeconfig=kubeconfig/$CLUSTER_NAME.kubeconfig get nodes
```

## Deleting a worker cluster

Removing a worker cluster is as simple as deleting the cluster HelmRelease file under deploy/management/clusters and applying a flux reconcile

```bash
rm deploy/management/clusters/<clusterName>.yaml

git add deploy/management/clusters/<clusterName>.yaml

git commit -m 'Removed cluster'

git push

flux reconcile kustomization flux-system --with-source

flux reconcile kustomization clusters

kubectl get clusters # You will see now that the cluster is being deleted
```

### Engineering Docs

- Team Working [Agreement](.github/WorkingAgreement.md)
- Team [Engineering Practices](.github/EngineeringPractices.md)
- CSE Engineering Fundamentals [Playbook](https://github.com/Microsoft/code-with-engineering-playbook)

## How to file issues and get help

This project uses GitHub Issues to track bugs and feature requests. Please search the existing issues before filing new issues to avoid duplicates. For new issues, file your bug or feature request as a new issue.

For help and questions about using this project, please open a GitHub issue.

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us the rights to use your contribution. For details, visit <https://cla.opensource.microsoft.com>

When you submit a pull request, a CLA bot will automatically determine whether you need to provide a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services.

Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).

Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.

Any use of third-party trademarks or logos are subject to those third-party's policies.
