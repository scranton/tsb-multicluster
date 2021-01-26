#!/usr/bin/env bash
: ${VARS_YAML?"Need to set VARS_YAML environment variable"}
echo config YAML:
cat $VARS_YAML

mkdir -p generated/mgmt
mkdir -p generated/cluster1
mkdir -p generated/cluster2
mkdir -p generated/bookinfo


echo "Deploying mgmt cluster..."
gcloud container clusters create $(yq r $VARS_YAML gcp.mgmt.clusterName) \
    --region $(yq r $VARS_YAML gcp.mgmt.region) \
    --machine-type=$(yq r $VARS_YAML gcp.mgmt.machineType) \
    --num-nodes=1 --min-nodes 0 --max-nodes 6 \
    --enable-autoscaling --enable-network-policy --release-channel=regular

echo "Installing TSB mgmt cluster..."
ENABLED=$(yq r $VARS_YAML tetrate.skipImages)
if [ "$ENABLED" = "false" ];
then
  echo "Syncing bintray images"
  tctl install image-sync --username $(yq r $VARS_YAML tetrate.apiUser) \
    --apikey $(yq r $VARS_YAML tetrate.apiKey) \
    --registry $(yq r $VARS_YAML tetrate.registry)
else
  echo "skipping image sync"
fi

kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.1.0/cert-manager.yaml
kubectl create secret generic clouddns-dns01-solver-svc-acct -n cert-manager \
    --from-file=$(yq r $VARS_YAML gcp.accountJsonKey)
while kubectl get po -n cert-manager | grep Running | wc -l | grep 3 ; [ $? -ne 0 ]; do
    echo Cert Manager is not yet ready
    sleep 5s
done

kubectl create ns tsb
cp cluster-issuer.yaml generated/mgmt/cluster-issuer.yaml
yq write generated/mgmt/cluster-issuer.yaml -i "spec.acme.email" $(yq r $VARS_YAML gcp.acme.email)
yq write generated/mgmt/cluster-issuer.yaml -i "spec.acme.solvers[0].dns01.cloudDNS.project" $(yq r $VARS_YAML gcp.env)
yq write generated/mgmt/cluster-issuer.yaml -i "spec.acme.solvers[0].selector.dnsZones[0]" $(yq r $VARS_YAML gcp.acme.dnsZone)
yq write generated/mgmt/cluster-issuer.yaml -d1 -i "spec.dnsNames[0]" $(yq r $VARS_YAML gcp.mgmt.fqdn)
kubectl apply -f generated/mgmt/cluster-issuer.yaml 
while kubectl get certificates.cert-manager.io -n tsb tsb-certs | grep True; [ $? -ne 0 ]; do
	echo TSB Certificate is not yet ready
	sleep 5s
done

tctl install manifest management-plane-operator --registry $(yq r $VARS_YAML tetrate.registry) > generated/mgmt/mp-operator.yaml
kubectl apply -f generated/mgmt/mp-operator.yaml
while kubectl get po -n tsb | grep Running | wc -l | grep 1 ; [ $? -ne 0 ]; do
    echo TSB Operator is not yet ready
    sleep 5s
done

tctl install manifest management-plane-secrets \
    --elastic-password tsb-elastic-password --elastic-username tsb \
    --ldap-bind-dn cn=admin,dc=tetrate,dc=io --ldap-bind-password admin \
    --postgres-password tsb-postgres-password --postgres-username tsb \
    --tsb-admin-password $(yq r $VARS_YAML gcp.mgmt.password) --tsb-server-certificate aaa --tsb-server-key bbb \
    --xcp-certs > generated/mgmt/mp-secrets.yaml
#We're not going to use tsb cert since we already have one we're generating from cert-manager
sed -i '' s/tsb-certs/tsb-cert-old/ generated/mgmt/mp-secrets.yaml 
kubectl apply -f generated/mgmt/mp-secrets.yaml 

echo "Deploying mgmt plane"
sleep 10 # Dig into why this is needed
cp mgmt-mp.yaml generated/mgmt/mp.yaml
yq write generated/mgmt/mp.yaml -i "spec.hub" $(yq r $VARS_YAML tetrate.registry)
kubectl apply -f generated/mgmt/mp.yaml
while kubectl get po -n tsb | grep Running | wc -l | grep 16 ; [ $? -ne 0 ]; do
    echo TSB mgmt plane is not yet ready
    sleep 5s
done
kubectl create job -n tsb teamsync-bootstrap --from=cronjob/teamsync

echo "Configuring DNS for TSB mgmt cluster..."
export TSB_IP_OLD=$(nslookup $(yq r $VARS_YAML gcp.mgmt.fqdn) | grep 'Address:' | tail -n1 | awk '{print $2}')
export TSB_IP=$(kubectl get svc -n tsb envoy -o json --output jsonpath='{.status.loadBalancer.ingress[0].ip}')  
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction start --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction remove $TSB_IP_OLD --name=$(yq r $VARS_YAML gcp.mgmt.fqdn). --ttl=300 --type=A --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction add $TSB_IP --name=$(yq r $VARS_YAML gcp.mgmt.fqdn). --ttl=300 --type=A --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction execute --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
echo “Old tsb ip: $TSB_IP_OLD“
echo “New tsb ip: $TSB_IP“

while nslookup $(yq r $VARS_YAML gcp.mgmt.fqdn) | grep $TSB_IP ; [ $? -ne 0 ]; do
	echo TSB DNS is not yet propagated
	sleep 5s
done

echo "Logging into TSB mgmt cluster..."
tctl config clusters set default --bridge-address $(yq r $VARS_YAML gcp.mgmt.fqdn):8443
tctl login --org tetrate --tenant tetrate --username admin --password $(yq r $VARS_YAML gcp.mgmt.password)
sleep 3
tctl get Clusters

tctl install manifest cluster-operator \
    --registry $(yq r $VARS_YAML tetrate.registry) > generated/mgmt/cp-operator.yaml
kubectl create ns istio-system
kubectl create secret generic cacerts -n istio-system \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/ca-cert.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/ca-key.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/root-cert.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/cert-chain.pem
kubectl apply -f generated/mgmt/cp-operator.yaml
cp mgmt-cluster.yaml generated/mgmt/mgmt-cluster.yaml
tctl apply -f generated/mgmt/mgmt-cluster.yaml
tctl install cluster-certs --cluster mgmt-cluster > generated/mgmt/mgmt-cluster-certs.yaml
tctl install manifest control-plane-secrets --cluster mgmt-cluster \
   --allow-defaults > generated/mgmt/mgmt-cluster-secrets.yaml
kubectl apply -f generated/mgmt/mgmt-cluster-certs.yaml
kubectl apply -f generated/mgmt/mgmt-cluster-secrets.yaml
sleep 30 # Dig into why this is needed
cp mgmt-cp.yaml generated/mgmt/mgmt-cp.yaml
yq write generated/mgmt/mgmt-cp.yaml -i "spec.hub" $(yq r $VARS_YAML tetrate.registry)
yq write generated/mgmt/mgmt-cp.yaml -i "spec.telemetryStore.elastic.host" $(yq r $VARS_YAML gcp.mgmt.fqdn)
yq write generated/mgmt/mgmt-cp.yaml -i "spec.managementPlane.host" $(yq r $VARS_YAML gcp.mgmt.fqdn)
kubectl apply -f generated/mgmt/mgmt-cp.yaml
while kubectl get po -n istio-system | grep Running | wc -l | grep 8 ; [ $? -ne 0 ]; do
    echo TSB control plane is not yet ready
    sleep 5s
done

#Bookinfo
kubectl create secret tls bookinfo-certs -n default \
    --key $(yq r $VARS_YAML k8s.bookinfoCertDir)/privkey.pem \
    --cert $(yq r $VARS_YAML k8s.bookinfoCertDir)/fullchain.pem
kubectl apply -f bookinfo/cluster-t1.yaml
while kubectl get svc tsb-tier1 -n default | grep pending | wc -l | grep 0 ; [ $? -ne 0 ]; do
    echo Tier 1 Gateway IP not assigned
    sleep 5s
done
export T1_GATEWAY_IP=$(kubectl get service tsb-tier1 -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export T1_GATEWAY_IP_OLD=$(nslookup $(yq r $VARS_YAML bookinfo.fqdn) | grep 'Address:' | tail -n1 | awk '{print $2}')
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction start --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction remove $T1_GATEWAY_IP_OLD --name=$(yq r $VARS_YAML bookinfo.fqdn). --ttl=300 --type=A --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction add $T1_GATEWAY_IP --name=$(yq r $VARS_YAML bookinfo.fqdn). --ttl=300 --type=A --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
gcloud beta dns --project=$(yq r $VARS_YAML gcp.env) record-sets transaction execute --zone=$(yq r $VARS_YAML gcp.acme.dnsZoneId)
echo “Old Tier 1 ip: $T1_GATEWAY_IP_OLD
echo “New Tier 1 ip: $T1_GATEWAY_IP

kubectl apply -f bookinfo/tmp1.yaml
for i in {1..50}
do
   curl -vv http://$T1_GATEWAY_IP
done
kubectl delete -f bookinfo/tmp1.yaml

while nslookup $(yq r $VARS_YAML bookinfo.fqdn) | grep $T1_GATEWAY_IP ; [ $? -ne 0 ]; do
	echo TSB DNS is not yet propagated
	sleep 5s
done


tctl install manifest cluster-operator \
    --registry $(yq r $VARS_YAML tetrate.registry) > generated/cluster1/cp-operator.yaml
tctl install manifest cluster-operator \
    --registry $(yq r $VARS_YAML tetrate.registry) > generated/cluster2/cp-operator.yaml
cp cluster1.yaml generated/cluster1/
yq write generated/cluster1/cluster1.yaml -i "spec.locality.region" $(yq r $VARS_YAML gcp.workload1.region)
tctl apply -f generated/cluster1/cluster1.yaml
cp cluster2.yaml generated/cluster2/
yq write generated/cluster2/cluster2.yaml -i "spec.locality.region" $(yq r $VARS_YAML gcp.workload2.region)
tctl apply -f generated/cluster2/cluster2.yaml
tctl install cluster-certs --cluster gke1-cluster > generated/cluster1/cluster-certs.yaml
tctl install cluster-certs --cluster gke2-cluster > generated/cluster2/cluster-certs.yaml
tctl install manifest control-plane-secrets --cluster gke1-cluster \
   --allow-defaults > generated/cluster1/cluster-secrets.yaml
tctl install manifest control-plane-secrets --cluster gke2-cluster \
   --allow-defaults > generated/cluster2/cluster-secrets.yaml

echo "Deploying workload cluster 1..."
gcloud container clusters create $(yq r $VARS_YAML gcp.workload1.clusterName) \
    --region $(yq r $VARS_YAML gcp.workload1.region) \
    --machine-type=$(yq r $VARS_YAML gcp.workload1.machineType) \
    --num-nodes=1 --min-nodes 0 --max-nodes 6 \
    --enable-autoscaling --enable-network-policy --release-channel=regular
kubectl create ns istio-system
kubectl create secret generic cacerts -n istio-system \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/ca-cert.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/ca-key.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/root-cert.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/cert-chain.pem
kubectl apply -f generated/cluster1/cp-operator.yaml
kubectl apply -f generated/cluster1/cluster-certs.yaml
kubectl apply -f generated/cluster1/cluster-secrets.yaml
while kubectl get po -n istio-system | grep Running | wc -l | grep 1 ; [ $? -ne 0 ]; do
    echo XCP Operator is not yet ready
    sleep 5s
done
sleep 30 # Dig into why this is needed
cp cluster1-cp.yaml generated/cluster1/
yq write generated/cluster1/cluster1-cp.yaml -i "spec.hub" $(yq r $VARS_YAML tetrate.registry)
yq write generated/cluster1/cluster1-cp.yaml -i "spec.telemetryStore.elastic.host" $(yq r $VARS_YAML gcp.mgmt.fqdn)
yq write generated/cluster1/cluster1-cp.yaml -i "spec.managementPlane.host" $(yq r $VARS_YAML gcp.mgmt.fqdn)
kubectl apply -f generated/cluster1/cluster1-cp.yaml
while kubectl get po -n istio-system | grep Running | wc -l | grep 8 ; [ $? -ne 0 ]; do
    echo TSB control plane is not yet ready
    sleep 5s
done
#Bookinfo
kubectl create ns bookinfo
kubectl apply -n bookinfo -f bookinfo/bookinfo.yaml
kubectl apply -n bookinfo -f bookinfo/cluster-ingress-gw.yaml
kubectl -n bookinfo create secret tls bookinfo-certs \
    --key $(yq r $VARS_YAML k8s.bookinfoCertDir)/privkey.pem \
    --cert $(yq r $VARS_YAML k8s.bookinfoCertDir)/fullchain.pem
while kubectl get po -n bookinfo | grep Running | wc -l | grep 7 ; [ $? -ne 0 ]; do
    echo Cert Manager is not yet ready
    sleep 5s
done
while kubectl get service tsb-gateway-bookinfo -n bookinfo | grep pending | wc -l | grep 0 ; [ $? -ne 0 ]; do
    echo Gateway IP not assigned
    sleep 5s
done
export GATEWAY_IP=$(kubectl get service tsb-gateway-bookinfo -n bookinfo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl apply -f bookinfo/tmp.yaml
for i in {1..50}
do
   curl -vv http://$GATEWAY_IP/productpage\?u=normal
done
kubectl delete -f bookinfo/tmp.yaml
kubectl apply -n bookinfo -f bookinfo/bookinfo-multi.yaml

echo "Deploying workload cluster 2..."
gcloud container clusters create $(yq r $VARS_YAML gcp.workload2.clusterName) \
    --region $(yq r $VARS_YAML gcp.workload2.region) \
    --machine-type=$(yq r $VARS_YAML gcp.workload2.machineType) \
    --num-nodes=1 --min-nodes 0 --max-nodes 6 \
    --enable-autoscaling --enable-network-policy --release-channel=regular
 kubectl create ns istio-system
 kubectl create secret generic cacerts -n istio-system \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/ca-cert.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/ca-key.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/root-cert.pem \
  --from-file=$(yq r $VARS_YAML k8s.istioCertDir)/cert-chain.pem
kubectl apply -f generated/cluster2/cp-operator.yaml
kubectl apply -f generated/cluster2/cluster-certs.yaml
kubectl apply -f generated/cluster2/cluster-secrets.yaml
while kubectl get po -n istio-system | grep Running | wc -l | grep 1 ; [ $? -ne 0 ]; do
    echo XCP Operator is not yet ready
    sleep 5s
done
sleep 10 # Dig into why this is needed
cp cluster2-cp.yaml generated/cluster2/
yq write generated/cluster2/cluster2-cp.yaml -i "spec.hub" $(yq r $VARS_YAML tetrate.registry)
yq write generated/cluster2/cluster2-cp.yaml -i "spec.telemetryStore.elastic.host" $(yq r $VARS_YAML gcp.mgmt.fqdn)
yq write generated/cluster2/cluster2-cp.yaml -i "spec.managementPlane.host" $(yq r $VARS_YAML gcp.mgmt.fqdn)
kubectl apply -f generated/cluster2/cluster2-cp.yaml
while kubectl get po -n istio-system | grep Running | wc -l | grep 8 ; [ $? -ne 0 ]; do
    echo TSB control plane is not yet ready
    sleep 5s
done
#Bookinfo
kubectl create ns bookinfo
kubectl apply -n bookinfo -f bookinfo/bookinfo.yaml
kubectl apply -n bookinfo -f bookinfo/cluster-ingress-gw.yaml
kubectl -n bookinfo create secret tls bookinfo-certs \
    --key $(yq r $VARS_YAML k8s.bookinfoCertDir)/privkey.pem \
    --cert $(yq r $VARS_YAML k8s.bookinfoCertDir)/fullchain.pem
while kubectl get po -n bookinfo | grep Running | wc -l | grep 7 ; [ $? -ne 0 ]; do
    echo Cert Manager is not yet ready
    sleep 5s
done
while kubectl get service tsb-gateway-bookinfo -n bookinfo | grep pending | wc -l | grep 0 ; [ $? -ne 0 ]; do
    echo Gateway IP not assigned
    sleep 5s
done
export GATEWAY_IP=$(kubectl get service tsb-gateway-bookinfo -n bookinfo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl apply -f bookinfo/tmp.yaml
for i in {1..50}
do
   curl -vv http://$GATEWAY_IP/productpage\?u=normal
done
kubectl delete -f bookinfo/tmp.yaml
kubectl apply -n bookinfo -f bookinfo/bookinfo-multi.yaml

#Setup TSB Objects
tctl apply -f bookinfo/workspace.yaml
cp bookinfo/tsb.yaml generated/bookinfo/tsb.yaml
yq write generated/bookinfo/tsb.yaml -d2 -i "spec.http[0].hostname" $(yq r $VARS_YAML bookinfo.fqdn)
yq write generated/bookinfo/tsb.yaml -d3 -i "spec.externalServers[0].hostname" $(yq r $VARS_YAML bookinfo.fqdn)

#don't apply this so we can demo
#tctl apply -f generated/bookinfo/tsb.yaml  


