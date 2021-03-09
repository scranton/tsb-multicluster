#!/usr/bin/env bash

: "${VARS_YAML:? "Need to set VARS_YAML environment variable"}"

echo 'config YAML:'
cat "${VARS_YAML}"

mkdir -p generated/mgmt
mkdir -p generated/cluster1
mkdir -p generated/cluster2
mkdir -p generated/bookinfo

GCP_PROJECT_ID="$(yq eval '.gcp.env' "${VARS_YAML}")"
PRIVATE_DOCKER_REGISTRY=$(yq eval '.tetrate.registry' "${VARS_YAML}")

ISTIO_CERT_DIR=$(yq eval '.k8s.istioCertDir' "${VARS_YAML}")
BOOKINFO_CERT_DIR=$(yq eval '.k8s.bookinfoCertDir' "${VARS_YAML}")

MGMT_FQDN=$(yq eval '.gcp.mgmt.fqdn' "${VARS_YAML}")
BOOKINFO_FQDN=$(yq eval '.bookinfo.fqdn' "${VARS_YAML}")

echo 'Deploying mgmt cluster...'

GCP_MGMT_CLUSTER_NAME="$(yq eval '.gcp.mgmt.clusterName' "${VARS_YAML}")"
GCP_MGMT_REGION="$(yq eval '.gcp.mgmt.region' "${VARS_YAML}")"
GCP_MGMT_MACHINE_TYPE="$(yq eval '.gcp.mgmt.machineType' "${VARS_YAML}")"

gcloud container clusters create "${GCP_MGMT_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_MGMT_REGION}" \
    --machine-type="${GCP_MGMT_MACHINE_TYPE}" \
    --num-nodes=1 \
    --min-nodes=0 \
    --max-nodes=6 \
    --enable-autoscaling \
    --enable-network-policy \
    --release-channel='regular'
gcloud container clusters get-credentials "${GCP_MGMT_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_MGMT_REGION}"

echo 'Installing TSB mgmt cluster...'

SKIP_IMAGES=$(yq eval '.tetrate.skipImages' "${VARS_YAML}")
if [ "${SKIP_IMAGES}" = "false" ]; then
    echo 'Syncing bintray images'

    BINTRAY_USERNAME=$(yq eval '.tetrate.apiUser' "${VARS_YAML}")
    BINTRAY_API_KEY=$(yq eval '.tetrate.apiKey' "${VARS_YAML}")

    tctl install image-sync \
        --username="${BINTRAY_USERNAME}" \
        --apikey="${BINTRAY_API_KEY}" \
        --registry="${PRIVATE_DOCKER_REGISTRY}"
else
    echo 'Skipping image sync'
fi

kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole='cluster-admin' \
    --user="$(gcloud config get-value core/account)"

GCP_ACCOUNT_JSON_KEY_FILE="$(yq eval '.gcp.accountJsonKey' "${VARS_YAML}")"

kubectl apply --filename='https://github.com/jetstack/cert-manager/releases/download/v1.2.0/cert-manager.yaml'
kubectl create secret generic clouddns-dns01-solver-svc-acct \
    --namespace='cert-manager' \
    --from-file="${GCP_ACCOUNT_JSON_KEY_FILE}"

# Wait until Cert Manager is ready
until [[ $(kubectl get pods --namespace='cert-manager' | grep -c Running) -ge 3 ]]
do
    echo 'Cert Manager is not yet ready'
    sleep 5s
done

cp cluster-issuer.yaml generated/mgmt/cluster-issuer.yaml

yq eval "(select(di == 0) | .spec.acme.email) |= \"$(yq eval '.gcp.acme.email' "${VARS_YAML}")\"" \
    --inplace generated/mgmt/cluster-issuer.yaml
yq eval "(select(di == 0) | .spec.acme.solvers[0].dns01.cloudDNS.project) |= \"${GCP_PROJECT_ID}\"" \
    --inplace generated/mgmt/cluster-issuer.yaml
yq eval "(select(di == 0) | .spec.acme.solvers[0].selector.dnsZones[0]) |= \"$(yq eval '.gcp.acme.dnsZone' "${VARS_YAML}")\"" \
    --inplace generated/mgmt/cluster-issuer.yaml
yq eval "(select(di == 1) | .spec.dnsNames[0]) = \"${MGMT_FQDN}\"" \
    --inplace generated/mgmt/cluster-issuer.yaml

kubectl create namespace tsb
kubectl apply --filename='generated/mgmt/cluster-issuer.yaml'

# Wait until TSB Certificate is ready
until kubectl get certificates.cert-manager.io --namespace='tsb' tsb-certs | grep True
do
    echo 'TSB Certificate is not yet ready'
    sleep 5s
done

tctl install manifest management-plane-operator --registry "${PRIVATE_DOCKER_REGISTRY}" >generated/mgmt/mp-operator.yaml
kubectl apply --filename='generated/mgmt/mp-operator.yaml'

until [[ $(kubectl get pods --namespace='tsb' -l name=tsb-operator | grep -c Running) -ge 1 ]]
do
    echo 'TSB Operator is not yet ready'
    sleep 5s
done

MGMT_ADMIN_PASSWORD=$(yq eval '.gcp.mgmt.password' "${VARS_YAML}")

tctl install manifest management-plane-secrets \
    --elastic-password tsb-elastic-password \
    --elastic-username tsb \
    --ldap-bind-dn cn=admin,dc=tetrate,dc=io \
    --ldap-bind-password admin \
    --postgres-password tsb-postgres-password \
    --postgres-username tsb \
    --tsb-admin-password "${MGMT_ADMIN_PASSWORD}" \
    --tsb-server-certificate aaa \
    --tsb-server-key bbb \
    --xcp-certs >generated/mgmt/mp-secrets.yaml

# We're not going to use tsb cert since we already have one we're generating from cert-manager
sed --in-place 's/tsb-certs/tsb-cert-old/' generated/mgmt/mp-secrets.yaml
kubectl apply --filename='generated/mgmt/mp-secrets.yaml'

echo 'Deploying mgmt plane'

sleep 30 # TODO: Dig into why this is needed

cp mgmt-mp.yaml generated/mgmt/mp.yaml

yq eval ".spec.hub = \"${PRIVATE_DOCKER_REGISTRY}\"" \
    --inplace generated/mgmt/mp.yaml

kubectl apply --filename='generated/mgmt/mp.yaml'

until [[ $(kubectl get pods --namespace='tsb' | grep -c Running) -ge 16 ]]
do
    echo 'TSB mgmt plane is not yet ready'
    sleep 5s
done

kubectl create job --namespace='tsb' teamsync-bootstrap --from='cronjob/teamsync'

echo 'Configuring DNS for TSB mgmt cluster...'

TSB_IP_OLD=$(nslookup "${MGMT_FQDN}" | grep 'Address:' | tail -n1 | awk '{print $2}')
TSB_IP=$(kubectl get services --namespace='tsb' envoy --output=jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Old tsb ip: ${TSB_IP_OLD}"
echo "New tsb ip: ${TSB_IP}"

GCP_DNS_ZONE_ID=$(yq eval '.gcp.acme.dnsZoneId' "${VARS_YAML}")

gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction start --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction remove "${TSB_IP_OLD}" --name="${MGMT_FQDN}." --ttl=300 --type=A --zone=$"${GCP_DNS_ZONE_ID}"
gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction add "${TSB_IP}" --name="${MGMT_FQDN}." --ttl=300 --type=A --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction execute --zone="${GCP_DNS_ZONE_ID}"

until nslookup "${MGMT_FQDN}" | grep "${TSB_IP}"
do
    echo 'TSB DNS is not yet propagated'
    sleep 5s
done

echo 'Logging into TSB mgmt cluster...'

tctl config clusters set default --bridge-address "${MGMT_FQDN}":443
tctl login --org tetrate --tenant tetrate --username admin --password "${MGMT_ADMIN_PASSWORD}"

sleep 3

tctl get Clusters

tctl install manifest cluster-operator \
    --registry "${PRIVATE_DOCKER_REGISTRY}" >generated/mgmt/cp-operator.yaml

kubectl create namespace istio-system
kubectl create secret generic cacerts \
    --namespace='istio-system' \
    --from-file="${ISTIO_CERT_DIR}/ca-cert.pem" \
    --from-file="${ISTIO_CERT_DIR}/ca-key.pem" \
    --from-file="${ISTIO_CERT_DIR}/root-cert.pem" \
    --from-file="${ISTIO_CERT_DIR}/cert-chain.pem"
kubectl apply --filename='generated/mgmt/cp-operator.yaml'

cp mgmt-cluster.yaml generated/mgmt/mgmt-cluster.yaml

tctl apply -f generated/mgmt/mgmt-cluster.yaml
tctl install cluster-certs --cluster mgmt-cluster >generated/mgmt/mgmt-cluster-certs.yaml
tctl install manifest control-plane-secrets --cluster mgmt-cluster \
    --allow-defaults >generated/mgmt/mgmt-cluster-secrets.yaml

kubectl apply --filename='generated/mgmt/mgmt-cluster-certs.yaml'
kubectl apply --filename='generated/mgmt/mgmt-cluster-secrets.yaml'

sleep 30 # TODO: Dig into why this is needed

cp mgmt-cp.yaml generated/mgmt/mgmt-cp.yaml

yq eval ".spec.hub = \"${PRIVATE_DOCKER_REGISTRY}\"" --inplace generated/mgmt/mgmt-cp.yaml
yq eval ".spec.telemetryStore.elastic.host = \"${MGMT_FQDN}\"" --inplace generated/mgmt/mgmt-cp.yaml
yq eval ".spec.managementPlane.host = \"${MGMT_FQDN}\"" --inplace generated/mgmt/mgmt-cp.yaml

kubectl apply --filename='generated/mgmt/mgmt-cp.yaml'
kubectl patch ControlPlane controlplane --namespace='istio-system' --patch '{"spec":{"meshExpansion":{}}}' --type merge

# Edge is last thing to start
until [[ $(kubectl get pods --namespace='istio-system' -l app=edge | grep -c Running) -ge 1 ]]
do
    echo 'Istio control plane is not yet ready'
    sleep 5s
done

# Bookinfo
kubectl create secret tls bookinfo-certs \
    --namespace='t1' \
    --key "${BOOKINFO_CERT_DIR}/privkey.pem" \
    --cert "${BOOKINFO_CERT_DIR}/fullchain.pem"
kubectl apply --filename='bookinfo/cluster-t1.yaml'

until [[ $(kubectl get service tsb-tier1 --namespace='t1' | grep -c pending) -eq 0 ]]
do
    echo 'Tier 1 Gateway IP not assigned'
    sleep 5s
done

T1_GATEWAY_IP=$(kubectl get service tsb-tier1 --namespace='t1' --output=jsonpath='{.status.loadBalancer.ingress[0].ip}')
T1_GATEWAY_IP_OLD=$(nslookup "${BOOKINFO_FQDN}" | grep 'Address:' | tail -n1 | awk '{print $2}')

gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction start --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction remove "${T1_GATEWAY_IP_OLD}" --name="${BOOKINFO_FQDN}." --ttl=300 --type=A --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction add "${T1_GATEWAY_IP}" --name="${BOOKINFO_FQDN}." --ttl=300 --type=A --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns --project="${GCP_PROJECT_ID}" record-sets transaction execute --zone="${GCP_DNS_ZONE_ID}"

echo "Old Tier 1 ip: ${T1_GATEWAY_IP_OLD}"
echo "New Tier 1 ip: ${T1_GATEWAY_IP}"

kubectl apply --filename='bookinfo/tmp1.yaml'
for i in {1..50}; do
    curl -vv "http://${T1_GATEWAY_IP}"
done
kubectl delete --filename='bookinfo/tmp1.yaml'

until nslookup "${BOOKINFO_FQDN}" | grep "${T1_GATEWAY_IP}"
do
    echo 'Tier1 Gateway DNS is not yet propagated'
    sleep 5s
done

tctl install manifest cluster-operator \
    --registry "${PRIVATE_DOCKER_REGISTRY}" >generated/cluster1/cp-operator.yaml
tctl install manifest cluster-operator \
    --registry "${PRIVATE_DOCKER_REGISTRY}" >generated/cluster2/cp-operator.yaml

GCP_WORKLOAD1_REGION=$(yq eval '.gcp.workload1.region' "${VARS_YAML}")
GCP_WORKLOAD2_REGION=$(yq eval '.gcp.workload2.region' "${VARS_YAML}")

cp cluster1.yaml generated/cluster1/
yq eval ".spec.locality.region = \"${GCP_WORKLOAD1_REGION}\"" --inplace generated/cluster1/cluster1.yaml
tctl apply -f generated/cluster1/cluster1.yaml

cp cluster2.yaml generated/cluster2/
yq eval ".spec.locality.region = \"${GCP_WORKLOAD2_REGION}\"" --inplace generated/cluster2/cluster2.yaml
tctl apply -f generated/cluster2/cluster2.yaml

tctl install cluster-certs --cluster gke1-cluster >generated/cluster1/cluster-certs.yaml
tctl install cluster-certs --cluster gke2-cluster >generated/cluster2/cluster-certs.yaml

tctl install manifest control-plane-secrets --cluster gke1-cluster \
    --allow-defaults >generated/cluster1/cluster-secrets.yaml
tctl install manifest control-plane-secrets --cluster gke2-cluster \
    --allow-defaults >generated/cluster2/cluster-secrets.yaml

echo 'Deploying workload cluster 1...'

GCP_WORKLOAD1_CLUSTER_NAME=$(yq eval '.gcp.workload1.clusterName' "${VARS_YAML}")
GCP_WORKLOAD1_MACHINE_TYPE=$(yq eval '.gcp.workload1.machineType' "${VARS_YAML}")

gcloud container clusters create "${GCP_WORKLOAD1_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_WORKLOAD1_REGION}" \
    --machine-type="${GCP_WORKLOAD1_MACHINE_TYPE}" \
    --num-nodes=1 \
    --min-nodes=0 \
    --max-nodes=6 \
    --enable-autoscaling \
    --enable-network-policy \
    --release-channel='regular'
gcloud container clusters get-credentials "${GCP_WORKLOAD1_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_WORKLOAD1_REGION}"

kubectl create namespace istio-system
kubectl create secret generic cacerts \
    --namespace='istio-system' \
    --from-file="${ISTIO_CERT_DIR}/ca-cert.pem" \
    --from-file="${ISTIO_CERT_DIR}/ca-key.pem" \
    --from-file="${ISTIO_CERT_DIR}/root-cert.pem" \
    --from-file="${ISTIO_CERT_DIR}/cert-chain.pem"

kubectl apply --filename='generated/cluster1/cp-operator.yaml'
kubectl apply --filename='generated/cluster1/cluster-certs.yaml'
kubectl apply --filename='generated/cluster1/cluster-secrets.yaml'

until [[ $(kubectl get pods --namespace='istio-system' -l name=tsb-operator | grep -c Running) -ge 1 ]]
do
    echo 'TSB Operator is not yet ready'
    sleep 5s
done

sleep 30 # TODO: Dig into why this is needed

cp cluster1-cp.yaml generated/cluster1/
yq eval ".spec.hub = \"${PRIVATE_DOCKER_REGISTRY}\"" --inplace generated/cluster1/cluster1-cp.yaml
yq eval ".spec.telemetryStore.elastic.host = \"${MGMT_FQDN}\"" --inplace generated/cluster1/cluster1-cp.yaml
yq eval ".spec.managementPlane.host = \"${MGMT_FQDN}\"" --inplace generated/cluster1/cluster1-cp.yaml
kubectl apply --filename='generated/cluster1/cluster1-cp.yaml'

# Edge Pod is the last thing to start
until [[ $(kubectl get pods --namespace='istio-system' -l app=edge | grep -c Running) -ge 1 ]]
do
    echo 'Istio control plane is not yet ready'
    sleep 5s
done

kubectl patch ControlPlane controlplane --namespace='istio-system' --patch '{"spec":{"meshExpansion":{}}}' --type merge

# Bookinfo
kubectl create namespace bookinfo
kubectl apply --namespace='bookinfo' --filename='bookinfo/bookinfo.yaml'
kubectl apply --namespace='bookinfo' --filename='bookinfo/cluster-ingress-gw.yaml'
kubectl create secret tls bookinfo-certs \
    --namespace='bookinfo' \
    --key="${BOOKINFO_CERT_DIR}/privkey.pem" \
    --cert="${BOOKINFO_CERT_DIR}/fullchain.pem"

until [[ $(kubectl get pods --namespace'bookinfo' | grep -c Running) -ge 7 ]]
do
    echo 'Bookinfo is not yet ready'
    sleep 5s
done

until [[ $(kubectl get service tsb-gateway-bookinfo --namespace='bookinfo' | grep -c pending) -eq 0 ]]
do
    echo 'Gateway IP not assigned'
    sleep 5s
done

GATEWAY_IP=$(kubectl get service tsb-gateway-bookinfo --namespace='bookinfo' --output=jsonpath='{.status.loadBalancer.ingress[0].ip}')

kubectl apply --filename='bookinfo/tmp.yaml'
for i in {1..50}; do
    curl -vv "http://${GATEWAY_IP}/productpage\?u=normal"
done
kubectl delete --filename='bookinfo/tmp.yaml'

kubectl apply --namespace='bookinfo' --filename='bookinfo/bookinfo-multi.yaml'

echo 'Deploying workload cluster 2...'

GCP_WORKLOAD2_CLUSTER_NAME=$(yq eval '.gcp.workload2.clusterName' "${VARS_YAML}")
GCP_WORKLOAD2_MACHINE_TYPE=$(yq eval '.gcp.workload2.machineType' "${VARS_YAML}")

gcloud container clusters create "${GCP_WORKLOAD2_CLUSTER_NAME}" \
    --project "${GCP_PROJECT_ID}" \
    --region "${GCP_WORKLOAD2_REGION}" \
    --machine-type="${GCP_WORKLOAD2_MACHINE_TYPE}" \
    --num-nodes=1 \
    --min-nodes=0 \
    --max-nodes=6 \
    --enable-autoscaling \
    --enable-network-policy \
    --release-channel='regular'
gcloud container clusters get-credentials "${GCP_WORKLOAD2_CLUSTER_NAME}" \
    --project "${GCP_PROJECT_ID}" \
    --region "${GCP_WORKLOAD2_REGION}"

kubectl create namespace istio-system
kubectl create secret generic cacerts \
    --namespace='istio-system' \
    --from-file="${ISTIO_CERT_DIR}/ca-cert.pem" \
    --from-file="${ISTIO_CERT_DIR}/ca-key.pem" \
    --from-file="${ISTIO_CERT_DIR}/root-cert.pem" \
    --from-file="${ISTIO_CERT_DIR}/cert-chain.pem"

kubectl apply --filename='generated/cluster2/cp-operator.yaml'
kubectl apply --filename='generated/cluster2/cluster-certs.yaml'
kubectl apply --filename='generated/cluster2/cluster-secrets.yaml'

until [[ $(kubectl get pods --namespace='istio-system' -l name=tsb-operator | grep -c Running) -ge 1 ]]
do
    echo 'TSB Operator is not yet ready'
    sleep 5s
done

sleep 10 # Dig into why this is needed

cp cluster2-cp.yaml generated/cluster2/
yq eval ".spec.hub = \"${PRIVATE_DOCKER_REGISTRY}\"" --inplace generated/cluster2/cluster2-cp.yaml
yq eval ".spec.telemetryStore.elastic.host = \"${MGMT_FQDN}\"" --inplace generated/cluster2/cluster2-cp.yaml
yq eval ".spec.managementPlane.host = \"${MGMT_FQDN}\"" --inplace generated/cluster2/cluster2-cp.yaml
kubectl apply --filename='generated/cluster2/cluster2-cp.yaml'

# Edge Pod is the last thing to start
until [[ $(kubectl get pods --namespace='istio-system' -l app=edge | grep -c Running) -ge 1 ]]
do
    echo 'Istio control plane is not yet ready'
    sleep 5s
done

kubectl patch ControlPlane controlplane --namespace='istio-system' --patch '{"spec":{"meshExpansion":{}}}' --type merge

# Bookinfo
kubectl create namespace bookinfo
kubectl apply --namespace='bookinfo' --filename='bookinfo/bookinfo.yaml'
kubectl apply --namespace='bookinfo' --filename='bookinfo/cluster-ingress-gw.yaml'
kubectl create secret tls bookinfo-certs \
    --namespace='bookinfo' \
    --key="${BOOKINFO_CERT_DIR}/privkey.pem" \
    --cert="${BOOKINFO_CERT_DIR}/fullchain.pem"

until [[ $(kubectl get pods --namespace='bookinfo' | grep -c Running) -ge 7 ]]
do
    echo 'Bookinfo is not yet ready'
    sleep 5s
done

until [[ $(kubectl get service tsb-gateway-bookinfo --namespace='bookinfo' | grep -c pending) -eq 0 ]]
do
    echo 'Gateway IP not assigned'
    sleep 5s
done

GATEWAY_IP=$(kubectl get service tsb-gateway-bookinfo --namespace='bookinfo' --output=jsonpath='{.status.loadBalancer.ingress[0].ip}')

kubectl apply --filename='bookinfo/tmp.yaml'
for i in {1..50}; do
    curl -vv "http://${GATEWAY_IP}/productpage\?u=normal"
done
kubectl delete --filename='bookinfo/tmp.yaml'

kubectl apply --namespace='bookinfo' --filename='bookinfo/bookinfo-multi.yaml'

# Setup TSB Objects
tctl apply -f bookinfo/workspace.yaml

cp bookinfo/tsb.yaml generated/bookinfo/tsb.yaml
yq eval ".spec.http[0].hostname = \"${BOOKINFO_FQDN}\"" --inplace generated/bookinfo/tsb.yaml
yq eval ".spec.externalServers[0].hostname = \"${BOOKINFO_FQDN}\"" --inplace generated/bookinfo/tsb.yaml

# Prepare VM Expansion
# Create VM

VM_NAME=$(yq eval '.gcp.vm.name' "${VARS_YAML}")
GCP_VM_ZONE=$(yq eval '.gcp.vm.networkZone' "${VARS_YAML}")
GCP_VM_SUBNET=$(yq eval '.gcp.vm.network' "${VARS_YAML}")
PUBLIC_KEY=$(yq eval '.gcp.vm.gcpPublicKey' "${VARS_YAML}")
GCP_VM_TAG=$(yq eval '.gcp.vm.tag' "${VARS_YAML}")

gcloud beta compute instances create "${VM_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --zone="${GCP_VM_ZONE}" \
    --subnet="${GCP_VM_SUBNET}" \
    --metadata=ssh-keys="${PUBLIC_KEY}" \
    --tags="${GCP_VM_TAG}" \
    --image='ubuntu-1804-bionic-v20210119a' \
    --image-project='ubuntu-os-cloud' \
    --machine-type='e2-medium'

EXTERNAL_IP=$(gcloud beta compute --project="${GCP_PROJECT_ID}" instances describe "${VM_NAME}" --zone="${GCP_VM_ZONE}" | grep natIP | cut -d ":" -f 2 | tr -d ' ')
INTERNAL_IP=$(gcloud beta compute --project="${GCP_PROJECT_ID}" instances describe "${VM_NAME}" --zone="${GCP_VM_ZONE}" | grep networkIP | cut -d ":" -f 2 | tr -d ' ')

sleep 30s # need to let ssh wake up

# Prepare VM
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null scripts/mesh-expansion.sh "${EXTERNAL_IP}:~"
ssh "${EXTERNAL_IP}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ./mesh-expansion.sh

# Update YAMLs
VM_SSH_USER=$(yq eval '.gcp.vm.sshUser' "${VARS_YAML}")

cp bookinfo/vm.yaml generated/bookinfo/
yq eval ".spec.address = \"${INTERNAL_IP}\"" --inplace generated/bookinfo/vm.yaml
yq eval ".metadata.annotations.\"sidecar-bootstrap.istio.io/proxy-instance-ip\" = \"${INTERNAL_IP}\"" --inplace generated/bookinfo/vm.yaml
yq eval ".metadata.annotations.\"sidecar-bootstrap.istio.io/ssh-host\" = \"${EXTERNAL_IP}\"" --inplace generated/bookinfo/vm.yaml
yq eval ".metadata.annotations.\"sidecar-bootstrap.istio.io/ssh-user\" = \"${VM_SSH_USER}\"" --inplace generated/bookinfo/vm.yaml

#don't apply this so we can demo
#tctl apply -f generated/bookinfo/tsb.yaml
