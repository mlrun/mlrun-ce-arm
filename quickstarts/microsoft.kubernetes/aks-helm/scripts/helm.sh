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


cat << EOF > overide-env.yaml
global:
  registry:
    url: "${CONTAINER_REGISTRY_NAME}"
nuclio:
  platform:
    kube:
      defaultFunctionServiceAccount: mlrun-jobs-sa
  registry:
    pushPullUrl: "${CONTAINER_REGISTRY_NAME}"
  dashboard:
    containerBuilderKind: kaniko
    imageNamePrefixTemplate: "${CLUSTER_NAME}-{{ .ProjectName }}-{{ .FunctionName }}-"
mlrun:
  serviceAccounts:
    api:
      create: false
      name: mlrun-api-aws
  nuclio:
    uiURL:  "https://nuclio.${CLUSTER_NAME}.${DNS_PREFIX}"
  storage: filesystem
  api:
    fullnameOverride: mlrun-api
    persistence:
      enabled: true
      annotations: ~
      storageClass: azurefile-csi
    envFrom:
      - configMapRef:
          name: mlrun-override-env
          optional: true
    extraEnv:
      - name: S3_NON_ANONYMOUS
        value: "true"
      - name: MLRUN_DEFAULT_TENSORBOARD_LOGS_PATH
        value: /home/jovyan/data/tensorboard/{{ `{{project}} `}}
      - name: MLRUN_CE__MODE
        value: full
      - name: MLRUN_SPARK_OPERATOR_VERSION
        value: spark-3
      - name: MLRUN_STORAGE__AUTO_MOUNT_TYPE
        value: s3
      - name: MLRUN_STORAGE__AUTO_MOUNT_PARAMS
        value: "non_anonymous=True"
      - name: MLRUN_FUNCTION__SPEC__SERVICE_ACCOUNT__DEFAULT
        value: mlrun-jobs-sa
      - name: MLRUN_HTTPDB__PROJECTS__FOLLOWERS
        value: nuclio
      - name: MLRUN_HTTPDB__REAL_PATH
        value: s3://
      - name: MLRUN_ARTIFACT_PATH
        value: s3://${MlrunBucket}/
      - name: MLRUN_SPARK_APP_IMAGE
        value: gcr.io/iguazio/spark-app
      - name: MLRUN_SPARK_APP_IMAGE_TAG
        value: v3.2.1-mlk
      - name: MLRUN_KFP_URL
        value: http://ml-pipeline.mlrun.svc.cluster.local:8888
      - name: MLRUN_REDIS_URL
        value: ${REDISUrl}
  db:
    persistence:
      enabled: true
      annotations: ~
      storageClass: aws-efs
  httpDB:
    dbType: mysql
    dsn: mysql+pymysql://root@mlrun-db:3306/mlrun
    oldDsn: sqlite:////mlrun/db/mlrun.db?check_same_thread=false
jupyterNotebook:
  awsInstall: true
  serviceAccount: mlrun-jobs-sa
  mlrunUIURL:  https://mlrun.${EKSClusterName}.${ClusterDomain}
  persistence:
    enabled: true
    annotations: ~
    storageClass: aws-efs
  extraEnv:
      - name: S3_NON_ANONYMOUS
        value: "true"
      - name: MLRUN_HTTPDB__REAL_PATH
        value: s3://
      - name: MLRUN_STORAGE__AUTO_MOUNT_TYPE
        value: s3
      - name: MLRUN_STORAGE__AUTO_MOUNT_PARAMS
        value: "non_anonymous=True"
      - name: MLRUN_FUNCTION__SPEC__SERVICE_ACCOUNT__DEFAULT
        value: mlrun-jobs-sa
      - name: MLRUN_ARTIFACT_PATH
        value: s3://${MlrunBucket}/
      - name: MLRUN_CE
        value: "true"
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
    storageClass: aws-efs
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
    storageClass: aws-efs
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
  enabled: false
  alertmanager:
    enabled: false
  grafana:
    persistence:
      type: pvc
      enabled: true
      size: 10Gi
      storageClassName: aws-efs
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
