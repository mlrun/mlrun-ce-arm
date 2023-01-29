#!/bin/bash
set -e

sleep 120

az aks update -n $CLUSTER_NAME -g $RESOURCEGROUP --attach-acr $CLUSTER_NAME
az aks install-cli
az aks get-credentials --resource-group $RESOURCEGROUP --name $CLUSTER_NAME
# install helm
# Download and install Helm
wget -O helm.tgz https://get.helm.sh/helm-v3.9.3-linux-amd64.tar.gz
tar -xvf helm.tgz
mv linux-amd64/helm  .

CONTAINER_REGISTRY_NAME="$CLUSTER_NAME.azurecr.io"


# Create Namespace
NAMESPACE="mlrun"
kubectl create namespace $NAMESPACE



# install ingress cluster
RESOURCEGROUP_DNS_PREFIX=`az network dns zone list  --query "[?name=='${DNS_PREFIX}']" | jq  .[].resourceGroup | tr -d '"'`

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.4/deploy/static/provider/cloud/deploy.yaml
sleep 130
IP=`kubectl get svc -n ingress-nginx ingress-nginx-controller  | grep LoadBalancer  | awk '{print $4}'`
sleep 10
PUBLICIPID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$IP')].[id]" --output tsv)
az network dns record-set a create -g ${RESOURCEGROUP_DNS_PREFIX}  -n *.${CLUSTER_NAME} -z ${DNS_PREFIX} --target-resource ${PUBLICIPID}




# get  ACR CRED
ACR_NAME=${CLUSTER_NAME}.azurecr.io
ACR_USER=$(az acr credential show --name  ${CLUSTER_NAME} --resource-group $RESOURCEGROUP  --query="username" -o tsv)
ACR_PASSWD=$(az acr credential show --name  ${CLUSTER_NAME} --resource-group $RESOURCEGROUP --query="passwords[0].value" -o tsv)

# create ACR CRED
kubectl --namespace mlrun  create secret docker-registry registry-credentials \
  --docker-server=$ACR_NAME \
  --docker-username=$ACR_USER \
  --docker-password=$ACR_PASSWD \
  --docker-email=${USER_EMAIL}




STORAGE_CONNECTION_STRING=$(az storage account show-connection-string --name ${CLUSTER_NAME} --resource-group ${RESOURCEGROUP}   --query=connectionString| tr -d '"')

kubectl create secret generic azure-storage-connection --from-literal=connectionstring=${STORAGE_CONNECTION_STRING}  -n mlrun

cat << EOF > overide-env.yaml
global:
  registry:
    url: "${CONTAINER_REGISTRY_NAME}"
    secretName: registry-credentials
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
      storageClass: managed
    envFrom:
      - configMapRef:
          name: mlrun-override-env
          optional: true
    extraEnv:
      - name: MLRUN_HTTPDB__REAL_PATH
        value: az://
      - name: MLRUN_ARTIFACT_PATH
        value: az://mlrun-ce/
      - name: MLRUN_DEFAULT_TENSORBOARD_LOGS_PATH
        value: /home/jovyan/data/tensorboard/{{ `{{project}} `}}
      - name: MLRUN_CE__MODE
        value: full
      - name: MLRUN_SPARK_OPERATOR_VERSION
        value: spark-3
      - name: MLRUN_HTTPDB__PROJECTS__FOLLOWERS
        value: nuclio
      - name: MLRUN_SPARK_APP_IMAGE
        value: gcr.io/iguazio/spark-app
      - name: MLRUN_SPARK_APP_IMAGE_TAG
        value: v3.2.1-mlk
      - name: MLRUN_KFP_URL
        value: http://ml-pipeline.mlrun.svc.cluster.local:8888
      - name: MLRUN_REDIS_URL
        value: ${REDISUrl}
      - name: AZURE_STORAGE_CONNECTION_STRING
        valueFrom:
          secretKeyRef:
            name: azure-storage-connection
            key: connectionstring
  db:
    persistence:
      enabled: true
      annotations: ~
      storageClass: managed
jupyterNotebook:
  azureInstall: true
  mlrunUIURL:  https://mlrun.${CLUSTER_NAME}.${DNS_PREFIX}
  persistence:
    enabled: true
    annotations: ~
    storageClass: managed
  extraEnv:
    - name: MLRUN_HTTPDB__REAL_PATH
      value: az://
    - name: MLRUN_ARTIFACT_PATH
      value: az://mlrun-ce/
    - name: AZURE_STORAGE_CONNECTION_STRING
      valueFrom:
        secretKeyRef:
          name: azure-storage-connection
          key: connectionstring
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
    storageClass: managed
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
    storageClass: managed
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
      storageClassName: managed
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
    -f overide-env.yaml



sleep 60


cat << EOF > mlrun-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: "${REMOTE_ACCESS_CIDR}"
  name: mlrun-ingress
  namespace: mlrun
spec:
  rules:
  - host: mlrun.${CLUSTER_NAME}.${DNS_PREFIX}
    http:
      paths:
      - backend:
          service:
            name: mlrun-ui
            port:
              number: 80
        path: /*
        pathType: ImplementationSpecific
  - host: mlrun-api.${CLUSTER_NAME}.${DNS_PREFIX}
    http:
      paths:
      - backend:
          service:
            name: mlrun-api
            port:
              number: 8080
        path: /*
        pathType: ImplementationSpecific
  - host: nuclio.${CLUSTER_NAME}.${DNS_PREFIX}
    http:
      paths:
      - backend:
          service:
            name: nuclio-dashboard
            port:
              number: 8070
        path: /*
        pathType: ImplementationSpecific
  - host: jupyter.${CLUSTER_NAME}.${DNS_PREFIX}
    http:
      paths:
      - backend:
          service:
            name: mlrun-jupyter
            port:
              number: 8888
        path: /*
        pathType: ImplementationSpecific
  - host: grafana.${CLUSTER_NAME}.${DNS_PREFIX}
    http:
      paths:
      - backend:
          service:
            name: grafana
            port:
              number: 80
        path: /*
        pathType: ImplementationSpecific
EOF



kubectl apply -f mlrun-ingress.yaml





echo \{\"Status\":\"Complete\"\} > $AZ_SCRIPTS_OUTPUT_PATH
