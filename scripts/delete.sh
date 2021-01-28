#!/usr/bin/env bash
: ${VARS_YAML?"Need to set VARS_YAML environment variable"}
echo config YAML:
cat $VARS_YAML

echo "Destroying cluster1..."
gcloud container clusters delete $(yq r $VARS_YAML gcp.workload1.clusterName) \
   --region $(yq r $VARS_YAML gcp.workload1.region) --quiet
echo "Destroying cluster2..."
gcloud container clusters delete $(yq r $VARS_YAML gcp.workload2.clusterName) \
   --region $(yq r $VARS_YAML gcp.workload2.region) --quiet
echo "Destroying mgmt cluster..."
gcloud container clusters delete $(yq r $VARS_YAML gcp.mgmt.clusterName) \
   --region $(yq r $VARS_YAML gcp.mgmt.region) --quiet
gcloud beta compute --project=$(yq r $VARS_YAML gcp.env) instances delete $(yq r $VARS_YAML gcp.vm.name) \
  --zone=$(yq r $VARS_YAML gcp.vm.networkZone) --quiet
rm -rf ~/.ssh/known_hosts