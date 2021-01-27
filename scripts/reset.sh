#!/usr/bin/env bash
: ${VARS_YAML?"Need to set VARS_YAML environment variable"}
echo config YAML:
cat $VARS_YAML

# Delete TSB Objects
tctl delete -f bookinfo/tsb.yaml

# Reset clusters with some baseline traffic
gcloud container clusters get-credentials $(yq r $VARS_YAML gcp.mgmt.clusterName) \
   --region $(yq r $VARS_YAML gcp.mgmt.region) --project $(yq r $VARS_YAML gcp.env)
export T1_GATEWAY_IP=$(kubectl get service tsb-tier1 -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl apply -f bookinfo/tmp1.yaml
for i in {1..50}
do
   curl -vv http://$T1_GATEWAY_IP
done
kubectl delete -f bookinfo/tmp1.yaml

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
k delete po -l app=tsb-gateway-bookinfo

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
k delete po -l app=tsb-gateway-bookinfo

# VM
gcloud container clusters get-credentials $(yq r $VARS_YAML gcp.workload1.clusterName) \
   --region $(yq r $VARS_YAML gcp.workload1.region) --project $(yq r $VARS_YAML gcp.env)