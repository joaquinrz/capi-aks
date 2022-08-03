# AKS Multi-Cluster Fleet using Cluster API + Flux

> Setup a Kubernetes Multi-cluster fleet using Cluster API and CAPZ

![License](https://img.shields.io/badge/license-MIT-green.svg)

## Overview

The following is a sample implementation using Codespaces for setting up an Azure Kubernetes Service (AKS) multi-cluster fleet using Cluster API and Flux. This setup is intended for learning and development purposes and is not production-ready.

## Open with Codespaces

> To use you must have Codespaces enabled in your current organization.

- Click the `Code` button on this repo
- Click the `Codespaces` tab
- Click `Create codespace on main`

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

To get started, you will need to create an AKS cluster that will manage the lifecycle of all your fleet clusters. For this setup we will be creating a vanilla AKS cluster with the Bring Your Own CNI (BYOCNI) feature enabled. This will help us install Cilium CNI.

```bash
# Set the name of your new resource group in Azure.
export AZURE_RG_NAME=capi-aks
export AZURE_LOCATION=southcentralus

# Check if the resource group name is not already in use
az group list -o table | grep $AZURE_RG_NAME

# Create the new resource group
az group create -n $AZURE_RG_NAME -l $AZURE_LOCATION

# Set name for management cluster
export AZURE_MGT_CLUSTER_NAME=capi-management

# Create the AKS Cluster with no CNI (this will take 5 to 10 minutes)
az aks create -g $AZURE_RG_NAME \
  -n $AZURE_MGT_CLUSTER_NAME \
  --node-count 1 \
  --generate-ssh-keys \
  --network-plugin none

# Connect to the AKS cluster
az aks get-credentials --resource-group $AZURE_RG_NAME --name $AZURE_MGT_CLUSTER_NAME

# Verify AKS node
kubectl get nodes

# You will see the nodepool is in NotReady state, this is expected since there is no CNI installed.

# NAME                                STATUS   ROLES   AGE     VERSION
# aks-nodepool1-34273201-vmss000000   NotReady agent   2m15s   v1.22.11
```

## Install Cilium CNI on Management Cluster

For the Nodepools to be in Ready state, a Container Network Interface(CNI) must be installed. The `cilum` cli has already been pre-installed in this codespace.

```bash
cilium install --azure-resource-group $AZURE_RG_NAME

# Verify AKS node
kubectl get nodes

# You will see the nodepool is now Ready

# NAME                                STATUS   ROLES   AGE     VERSION
# aks-nodepool1-34273201-vmss000000   Ready    agent   6m4s    v1.22.11
```

## Initialize the Management Cluster with Cluster API

Now that the AKS cluster is created with Cilium, it needs to be initialized with Cluster API to become the management cluster. The management cluster allows you to control and maintain the fleet of worker clusters

```bash

# Enable support for managed topologies and experimental features
export CLUSTER_TOPOLOGY=true
export EXP_AKS=true
export EXP_MACHINE_POOL=true

# TODO : Create an Azure Service Principal in the Azure portal. (Note: Make sure this Service Principal has access to the resource group)
# # Create an Azure Service Principal
# export AZURE_SP_NAME="<ServicePrincipalName>"

# az ad sp create-for-rbac \
#   --name $AZURE_SP_NAME \
#   --role contributor \
#   --scopes="/subscriptions/${AZURE_SUBSCRIPTION_ID}"

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

# Create kustomization for clusters
flux create kustomization "clusters" \
    --source GitRepository/flux-system \
    --path "/deploy/clusters" \
    --namespace flux-system \
    --prune true \
    --interval 1m \
    --export > deploy/management/bootstrap/clusters-kustomization.yaml

git add deploy/management/bootstrap/clusters-kustomization.yaml
git commit -m 'Added clusters kustomization'
git push

# Force Flux reconcile
flux reconcile source git flux-system

flux reconcile kustomization flux-system
```

## Enable BYOCNI Support for Managmenet Cluster

```bash
# Install Custom CRD for Azure Managed Control Planes (--network-plugin none)
kubectl apply -f byocni/manifests/infrastructure.cluster.x-k8s.io_azuremanagedcontrolplanes.yaml

# Update CAPZ deployment image for a custom forked image that supports BYONCI
kubectl set image deployment/capz-controller-manager \
  manager=ghcr.io/joaquinrz/cluster-api-azure-controller:beta \
  -n capz-system
```

## Deploy worker cluster using Cluster API and Flux v2

Now that the management cluster has been initialized with CAPI and Flux, let us generate a few cluster crds using our helper script.

```bash
# Wait for new capz-controller manager to be ready
watch kubectl get pods -n capz-system

# Set Cluster prefix and location
export CLUSTER_PREFIX=cluster10
export CLUSTER_LOCATION=southcentralus
export WORKER_CLUSTERS_RG=capi-aks-clusters

# This script will generate a new HelmRelease file under deploy/management/clusters. This file will then be reconciled by Flux and deploy a new worker cluster.
./scripts/cluster_create_aks.sh -n $CLUSTER_PREFIX -l $CLUSTER_LOCATION

export CLUSTER_NAME=aks-$CLUSTER_LOCATION-$CLUSTER_PREFIX

# Wait for the cluster to be provisioned (this takes around 6 minutes)
watch kubectl get clusters

# Generate kubeconfig for cluster
mkdir -p kubeconfig
clusterctl get kubeconfig $CLUSTER_NAME  > kubeconfig/$CLUSTER_NAME.kubeconfig

# Check worker cluster nodes
KUBECONFIG=kubeconfig/$CLUSTER_NAME.kubeconfig kubectl get nodes

#Install Cilium
KUBECONFIG=kubeconfig/$CLUSTER_NAME.kubeconfig \
  cilium install \
  --azure-resource-group $WORKER_CLUSTERS_RG

# Verify Cilium installation
KUBECONFIG=kubeconfig/$CLUSTER_NAME.kubeconfig kubectl get nodes

KUBECONFIG=kubeconfig/$CLUSTER_NAME.kubeconfig cilium status

```

## Deleting a worker cluster

Removing a worker cluster is as simple as deleting the cluster HelmRelease file under deploy/management/clusters and applying a flux reconcile

```bash
export CLUSTER_NAME=aks-southcentralus-cluster01
rm deploy/clusters/$CLUSTER_NAME.yaml
rm kubeconfig/$CLUSTER_NAME.kubeconfig

git add deploy/clusters/$CLUSTER_NAME.yaml

git commit -m "Removed cluster $CLUSTER_NAME"

git push

flux reconcile kustomization flux-system --with-source

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
