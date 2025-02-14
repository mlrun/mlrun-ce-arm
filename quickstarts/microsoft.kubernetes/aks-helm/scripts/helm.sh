#!/bin/bash
set -e



###################################################
##### WAIT for aks cluster to be in Succeeded state
###################################################

wait_period=0

while ! [ "${cluster_status}" == "Succeeded" ] ; do
  echo -n "wait cluster in state: ${cluster_status}"

    wait_period=$(($wait_period+10))
    if [ $wait_period -gt 600 ];then
       echo "The script successfully ran for 10 minutes, exiting now.."
       break
    else
       sleep 10
       cluster_status=$(az aks list --output table | grep -w ${CLUSTER_NAME}| awk '{print $5}')
    fi
done

###################################################
#####  and get aks cred
###################################################

az aks install-cli
az aks get-credentials --resource-group $RESOURCEGROUP --name $CLUSTER_NAME


###################################################
##### Download and install Helm
###################################################
wget -O helm.tgz https://get.helm.sh/helm-v3.9.3-linux-amd64.tar.gz
tar -xvf helm.tgz
mv linux-amd64/helm  .

###################################################
##### create mlrun namespace
###################################################
NAMESPACE="mlrun"
kubectl create namespace $NAMESPACE




###################################################
##### install ingress cluster
###################################################

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.4/deploy/static/provider/cloud/deploy.yaml
sleep 130
IP=`kubectl get svc -n ingress-nginx ingress-nginx-controller  | grep LoadBalancer  | awk '{print $4}'`
sleep 20


###################################################
##### update dns domain
###################################################
RESOURCEGROUP_DNS_PREFIX=`az network dns zone list  --query "[?name=='${DNS_PREFIX}']" | jq  .[].resourceGroup | tr -d '"'`
PUBLICIPID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$IP')].[id]" --output tsv)
az network dns record-set a create -g ${RESOURCEGROUP_DNS_PREFIX}  -n *.${CLUSTER_NAME} -z ${DNS_PREFIX} --target-resource ${PUBLICIPID}



###################################################
##### install cert-manager
###################################################
# Install CRDs with kubectl
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.crds.yaml
# Create the namespace for cert-manager
kubectl create namespace cert-manager
# Label the cert-manager namespace to disable resource validation
kubectl label namespace cert-manager cert-manager.io/disable-validation=true
# Add the Jetstack Helm repository
./helm repo add jetstack https://charts.jetstack.io
# Update your local Helm chart repository cache
./helm repo update
# Install the cert-manager Helm chart
./helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.11.0


###################################################
##### create  ClusterIssuer
###################################################
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:

    # You must replace this email address with your own.
    # Let's Encrypt will use this to contact you about expiring
    # certificates, and issues related to your account.
    email: ${USER_EMAIL}

    # ACME server URL for Let’s Encrypt’s staging environment.
    # The staging environment will not issue trusted certificates but is
    # used to ensure that the verification process is working properly
    # before moving to production
    server: https://acme-v02.api.letsencrypt.org/directory

    privateKeySecretRef:
      # Secret resource used to store the account's private key.
      name: letsencrypt

    # Enable the HTTP-01 challenge provider
    # you prove ownership of a domain by ensuring that a particular
    # file is present at the domain
    solvers:
    - http01:
        ingress:
            class: nginx
EOF




###################################################
##### create  secret for ACR registry
###################################################

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





###################################################
##### set  connection param and create secret
###################################################
STORAGE_CONNECTION_STRING=$(az storage account show-connection-string --name ${CLUSTER_NAME} --resource-group ${RESOURCEGROUP}   --query=connectionString| tr -d '"')
kubectl create secret generic azure-storage-connection --from-literal=connectionstring=${STORAGE_CONNECTION_STRING}  -n mlrun
STORAGE_CONNECTION_STRING_BASE64=$(echo {\"AZURE_STORAGE_CONNECTION_STRING\":\"${STORAGE_CONNECTION_STRING}\"}| base64  -w 0)




###################################################
##### create overide-env.yaml
###################################################

CONTAINER_REGISTRY_NAME="$CLUSTER_NAME.azurecr.io"

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
      - name: MLRUN_STORAGE__AUTO_MOUNT_TYPE
        value: env
      - name: MLRUN_STORAGE__AUTO_MOUNT_PARAMS
        value: "${STORAGE_CONNECTION_STRING_BASE64}"
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
    - name: MLRUN_STORAGE__AUTO_MOUNT_TYPE
      value: env
    - name: MLRUN_STORAGE__AUTO_MOUNT_PARAMS
      value: "${STORAGE_CONNECTION_STRING_BASE64}"
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


###################################################
#####  Install mlrun ce  Helm Chart
###################################################


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



###################################################
##### update aks attach-acr
###################################################
az aks update -n $CLUSTER_NAME -g $RESOURCEGROUP --attach-acr $CLUSTER_NAME


###################################################
#####  create ingress for mlrun ce
###################################################

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: "${REMOTE_ACCESS_CIDR}"
  name: mlrun-ingress
  namespace: mlrun
spec:
  tls:
  - hosts:
    - "mlrun.${CLUSTER_NAME}.${DNS_PREFIX}"
    secretName: mlrun-${CLUSTER_NAME}
  - hosts:
    - "mlrun-api.${CLUSTER_NAME}.${DNS_PREFIX}"
    secretName: mlrun-api-${CLUSTER_NAME}
  - hosts:
    - "nuclio.${CLUSTER_NAME}.${DNS_PREFIX}"
    secretName: nuclio-${CLUSTER_NAME}
  - hosts:
    - "jupyter.${CLUSTER_NAME}.${DNS_PREFIX}"
    secretName: jupyter-${CLUSTER_NAME}
  - hosts:
    - "grafana.${CLUSTER_NAME}.${DNS_PREFIX}"
    secretName: grafana-${CLUSTER_NAME}
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




###################################################
#####  set output
###################################################




echo \{\"Test\":\"TESA\"\,\"Status\":\"Complete\"\} > $AZ_SCRIPTS_OUTPUT_PATH
