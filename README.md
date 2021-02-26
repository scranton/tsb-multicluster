# tsb-multicluster
This project is meant to automate the paving of TSB Multi-cluster environments for common demo scenarios.  At the end of the installation you'll end up with TSB deployed and configured, a sample application deployed across 2 mult-region clusters, a VM integrated into one of the meshes serving app traffic, and a Tier 1 Gateway handling edge ingress and load balancing.  

Is should look like this:
![](https://raw.githubusercontent.com/adamzwickey/tsb-multicluster/main/images/demo.png "arch")

## Prerequisites
This demo install is opinionated in that it fully utilizes GCP services.  It also makes the following assumptions:

- A GCP account key json stored to local disk
- A GCP Cloud DNS zone created for use in DNS of management and demo application.
- A certificate generated for you application traffic (e.g. a cert, private key, root, and cert-chain)
- tctl CLI installed
- Docker installed and logged into your private repository you will utilize for TSB images
- gcloud CLI installed and initialized
- kubectl installed
- yq version 3.4.1 installed

## Installation
The installation script should be completely idempotent.  There are cases where things time out or it takes a little to long for pods to start up and the script gets into a bad state.  Simply kill the script and restart it.

- Make a copy of `var.yaml.example` named `vars.yaml`.  In reality you can name this anything, but .gitignore is configured ignore vars.yaml.  You must set an environment variable indicating where your vars.yaml is located.
```bash
export VARS_YAML=~/dev/tsb-multicluster/vars.yaml 
```
- Update `vars.yaml` to reflect your GCP environment and desired configuration.
- Execute the install script
```bash
source ./scripts/install.sh
```