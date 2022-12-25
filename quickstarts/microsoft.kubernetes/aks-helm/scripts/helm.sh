#!/bin/bash
set -e

# Download and install Helm
wget -O helm.tgz https://get.helm.sh/helm-v3.9.3-linux-amd64.tar.gz
tar -zxvf helm.tgz
mv linux-amd64/helm /usr/local/bin/helm
# Install kubectl
az aks install-cli

# Get cluster credentials
az aks get-credentials -g $RESOURCEGROUP -n $CLUSTER_NAME

# Create Namespace
NAMESPACE="mlrun"
kubectl create namespace $NAMESPACE

# Install Simple Helm Chart https://github.com/bitnami/mlrun-marketplace-charts

helm repo add \
    $HELM_REPO \
    $HELM_REPO_URL

helm search repo \
    $HELM_REPO

helm install \
    $HELM_APP_NAME \
    $HELM_APP \
    -n $NAMESPACE \
    --set global.imagePullSecrets={emptysecret}

echo \{\"Status\":\"Complete\"\} > $AZ_SCRIPTS_OUTPUT_PATH
