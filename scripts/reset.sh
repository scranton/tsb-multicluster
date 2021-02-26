#!/usr/bin/env bash
: ${VARS_YAML?"Need to set VARS_YAML environment variable"}
echo config YAML:
cat $VARS_YAML

# Delete TSB Objects
tctl delete -f bookinfo/tsb.yaml

# Reset clusters with some baseline traffic
gcloud container clusters get-credentials $(yq r $VARS_YAML gcp.mgmt.clusterName) \
   --region $(yq r $VARS_YAML gcp.mgmt.region) --project $(yq r $VARS_YAML gcp.env)
export T1_GATEWAY_IP=$(kubectl get service tsb-tier1 -n t1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl apply -f bookinfo/tmp1.yaml
for i in {1..50}
do
   curl -vv http://$T1_GATEWAY_IP
done
kubectl delete -f bookinfo/tmp1.yaml
sleep 10
kubectl delete po --selector='app=tsb-tier1'

gcloud container clusters get-credentials $(yq r $VARS_YAML gcp.workload1.clusterName) \
   --region $(yq r $VARS_YAML gcp.workload1.region) --project $(yq r $VARS_YAML gcp.env)
export GATEWAY_IP=$(kubectl get service tsb-gateway-bookinfo -n bookinfo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl apply -n bookinfo -f bookinfo/bookinfo.yaml
while kubectl get po -n bookinfo | grep Running | wc -l | grep 7 ; [ $? -ne 0 ]; do
    echo Bookinfo is not yet ready
    sleep 5s
done
kubectl apply -f bookinfo/tmp.yaml
for i in {1..50}
do
   curl -vv http://$GATEWAY_IP/productpage\?u=normal
done
kubectl delete -f bookinfo/tmp.yaml
kubectl apply -n bookinfo -f bookinfo/bookinfo-multi.yaml
k delete po -n bookinfo -l app=tsb-gateway-bookinfo

gcloud container clusters get-credentials $(yq r $VARS_YAML gcp.workload2.clusterName) \
   --region $(yq r $VARS_YAML gcp.workload2.region) --project $(yq r $VARS_YAML gcp.env)
export GATEWAY_IP=$(kubectl get service tsb-gateway-bookinfo -n bookinfo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl apply -n bookinfo -f bookinfo/bookinfo.yaml
while kubectl get po -n bookinfo | grep Running | wc -l | grep 7 ; [ $? -ne 0 ]; do
    echo Bookinfo is not yet ready
    sleep 5s
done
kubectl apply -f bookinfo/tmp.yaml
for i in {1..50}
do
   curl -vv http://$GATEWAY_IP/productpage\?u=normal
done
kubectl delete -f bookinfo/tmp.yaml
kubectl apply -n bookinfo -f bookinfo/bookinfo-multi.yaml
k delete po -n bookinfo -l app=tsb-gateway-bookinfo

# VM
gcloud container clusters get-credentials $(yq r $VARS_YAML gcp.workload1.clusterName) \
   --region $(yq r $VARS_YAML gcp.workload1.region) --project $(yq r $VARS_YAML gcp.env)
kubectl delete -f generated/bookinfo/vm.yaml
gcloud beta compute --project=$(yq r $VARS_YAML gcp.env) instances delete $(yq r $VARS_YAML gcp.vm.name) \
  --zone=$(yq r $VARS_YAML gcp.vm.networkZone) --quiet
rm -rf ~/.ssh/known_hosts
gcloud beta compute --project=$(yq r $VARS_YAML gcp.env) instances create $(yq r $VARS_YAML gcp.vm.name) \
--zone=$(yq r $VARS_YAML gcp.vm.networkZone) --subnet=$(yq r $VARS_YAML gcp.vm.network) \
--metadata=ssh-keys="$(yq r $VARS_YAML gcp.vm.gcpPublicKey)" \
--tags=$(yq r $VARS_YAML gcp.vm.tag) \
--image=ubuntu-1804-bionic-v20210119a --image-project=ubuntu-os-cloud --machine-type=e2-medium
export EXTERNAL_IP=$(gcloud beta compute --project=$(yq r $VARS_YAML gcp.env) instances describe $(yq r $VARS_YAML gcp.vm.name) --zone $(yq r $VARS_YAML gcp.vm.networkZone) | grep natIP | cut -d ":" -f 2 | tr -d ' ')  
export INTERNAL_IP=$(gcloud beta compute --project=$(yq r $VARS_YAML gcp.env) instances describe $(yq r $VARS_YAML gcp.vm.name) --zone $(yq r $VARS_YAML gcp.vm.networkZone) | grep networkIP | cut -d ":" -f 2 | tr -d ' ')  
sleep 30s #need to let ssh wake up
# Prepare VM
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null scripts/mesh-expansion.sh $EXTERNAL_IP:~
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $EXTERNAL_IP ./mesh-expansion.sh

# Update YAMLs
cp bookinfo/vm.yaml generated/bookinfo/
yq write generated/bookinfo/vm.yaml -i "spec.address" $INTERNAL_IP
yq write generated/bookinfo/vm.yaml -i 'metadata.annotations."sidecar-bootstrap.istio.io/proxy-instance-ip"' $INTERNAL_IP
yq write generated/bookinfo/vm.yaml -i 'metadata.annotations."sidecar-bootstrap.istio.io/ssh-host"' $EXTERNAL_IP
yq write generated/bookinfo/vm.yaml -i 'metadata.annotations."sidecar-bootstrap.istio.io/ssh-user"' $(yq r $VARS_YAML gcp.vm.sshUser)