#!/usr/bin/env bash

: "${VARS_YAML:? "Need to set VARS_YAML environment variable"}"

echo 'config YAML:'
cat "${VARS_YAML}"

GCP_PROJECT_ID="$(yq eval '.gcp.env' "${VARS_YAML}")"

echo 'Destroying cluster1...'

GCP_WORKLOAD1_CLUSTER_NAME=$(yq eval '.gcp.workload1.clusterName' "${VARS_YAML}")
GCP_WORKLOAD1_REGION=$(yq eval '.gcp.workload1.region' "${VARS_YAML}")

gcloud container clusters delete "${GCP_WORKLOAD1_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_WORKLOAD1_REGION}" \
    --quiet

echo 'Destroying cluster2...'

GCP_WORKLOAD2_CLUSTER_NAME=$(yq eval '.gcp.workload2.clusterName' "${VARS_YAML}")
GCP_WORKLOAD2_REGION=$(yq eval '.gcp.workload2.region' "${VARS_YAML}")

gcloud container clusters delete "${GCP_WORKLOAD2_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_WORKLOAD2_REGION}" \
    --quiet

echo 'Destroying mgmt cluster...'

GCP_MGMT_CLUSTER_NAME="$(yq eval '.gcp.mgmt.clusterName' "${VARS_YAML}")"
GCP_MGMT_REGION="$(yq eval '.gcp.mgmt.region' "${VARS_YAML}")"

gcloud container clusters delete "${GCP_MGMT_CLUSTER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_MGMT_REGION}" \
    --quiet

echo 'Destroying VM...'

EXTERNAL_IP=$(gcloud beta compute --project="${GCP_PROJECT_ID}" instances describe "${VM_NAME}" --zone="${GCP_VM_ZONE}" | grep natIP | cut -d ":" -f 2 | tr -d ' ')

# Cleanup SSH known_hosts
ssh-keygen -R "${EXTERNAL_IP}"

VM_NAME=$(yq eval '.gcp.vm.name' "${VARS_YAML}")
GCP_VM_ZONE=$(yq eval '.gcp.vm.networkZone' "${VARS_YAML}")

gcloud beta compute instances delete "${VM_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --zone="${GCP_VM_ZONE}" \
    --quiet
