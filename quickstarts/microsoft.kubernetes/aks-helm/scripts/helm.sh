#!/bin/bash
set -e

sleep 60
echo "debug1"

az aks update -n $CLUSTER_NAME -g $RESOURCEGROUP --attach-acr $CLUSTER_NAME
echo "debug2"


az aks install-cli
echo "debug3"

az aks get-credentials --resource-group $RESOURCEGROUP --name $CLUSTER_NAME
echo "debug4"

# install helm
# Download and install Helm
wget -O helm.tgz https://get.helm.sh/helm-v3.9.3-linux-amd64.tar.gz
tar -xvf helm.tgz
mv linux-amd64/helm  .


echo "debug5"
CONTAINER_REGISTRY_NAME="$CLUSTER_NAME.azurecr.io"


# Create Namespace
NAMESPACE="mlrun"
kubectl create namespace $NAMESPACE

echo "debug6"



cat << EOF > overide-env.yaml
global:
  registry:
    url: "${CONTAINER_REGISTRY_NAME}"
nuclio:
  registry:
    pushPullUrl: "${CONTAINER_REGISTRY_NAME}"
  dashboard:
    containerBuilderKind: kaniko
    imageNamePrefixTemplate: ${CLUSTER_NAME}-{{ .ProjectName }}-{{ .FunctionName }}-
mlrun:
  nuclio:
    uiURL:  https://nuclio.${CLUSTER_NAME}.${DNS_PREFIX}
  storage: filesystem
  api:
    fullnameOverride: mlrun-api
    persistence:
      enabled: true
      annotations: ~
      storageClass: azurefile-csi
  db:
    persistence:
      enabled: true
      annotations: ~
      storageClass: azurefile-csi
jupyterNotebook:
  mlrunUIURL:  https://mlrun.${CLUSTER_NAME}.${DNS_PREFIX}
  persistence:
    enabled: true
    annotations: ~
    storageClass: azurefile-csi
minio:
  enabled: true
  rootUser: minio
  rootPassword: minio123
  mode: distributed
  replicas: 4
  resources:
    requests:
      memory: 0.5Gi
  persistence:
    enabled: true
    storageClass: azurefile-csi
    size: 1Gi
  buckets: []
  users: []
spark-operator:
  enabled: true
  fullnameOverride: spark-operator
  webhook:
     enable: true
pipelines:
  enabled: true
  name: pipelines
  persistence:
    enabled: true
    existingClaim:
    storageClass: azurefile-csi
    accessMode: "ReadWriteOnce"
    size: "20Gi"
    annotations: ~
  db:
    username: root
  minio:
    enabled: true
    accessKey: "minio"
    secretKey: "minio123"
    endpoint: "minio.mlrun.svc.cluster.local"
    endpointPort: "9000"
    bucket: "mlrun"
  images:
    argoexec:
      repository: gcr.io/ml-pipeline/argoexec
      tag: v3.3.8-license-compliance
    workflowController:
      repository: gcr.io/ml-pipeline/workflow-controller
      tag: v3.3.8-license-compliance
    apiServer:
      repository: gcr.io/ml-pipeline/api-server
      tag: 1.8.3
    persistenceagent:
      repository: gcr.io/ml-pipeline/persistenceagent
      tag: 1.8.3
    scheduledworkflow:
      repository: gcr.io/ml-pipeline/scheduledworkflow
      tag: 1.8.3
    ui:
      repository: gcr.io/ml-pipeline/frontend
      tag: 1.8.3
    viewerCrdController:
      repository: gcr.io/ml-pipeline/viewer-crd-controller
      tag: 1.8.3
    visualizationServer:
      repository: gcr.io/ml-pipeline/visualization-server
      tag: 1.8.3
    metadata:
      container:
        repository: gcr.io/tfx-oss-public/ml_metadata_store_server
        tag: 1.5.0
    metadataEnvoy:
      repository: gcr.io/ml-pipeline/metadata-envoy
      tag: 1.8.3
    metadataWriter:
      repository: gcr.io/ml-pipeline/metadata-writer
      tag: 1.8.3
    mysql:
      repository: mysql
      tag: 5.7-debian
    cacheImage:
      repository: gcr.io/google-containers/busybox
      tag: latest
kube-prometheus-stack:
  fullnameOverride: monitoring
  enabled: true
  alertmanager:
    enabled: false
  grafana:
    persistence:
      type: pvc
      enabled: true
      size: 10Gi
      storageClassName: azurefile-csi
    grafana.ini:
      auth.anonymous:
        enabled: true
        org_role: Editor
      security:
        disable_initial_admin_creation: true
    fullnameOverride: grafana
    enabled: true
    service:
      type: NodePort
      nodePort: 30110
  prometheus:
    enabled: true
  kube-state-metrics:
    fullnameOverride: state-metrics
  prometheus-node-exporter:
    fullnameOverride: node-exporter

EOF






# Install Simple Helm Chart https://github.com/bitnami/mlrun-marketplace-charts

./helm repo add \
    $HELM_REPO \
    $HELM_REPO_URL

./helm search repo \
    $HELM_REPO

./helm install \
    $HELM_APP_NAME \
    $HELM_APP \
    -n $NAMESPACE \
    --set global.imagePullSecrets={emptysecret} \
    -f overide-env.yaml

echo \{\"Status\":\"Complete\"\} > $AZ_SCRIPTS_OUTPUT_PATH
