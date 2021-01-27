#!/usr/bin/env bash
sudo apt-get update

sudo apt-get -y install \
   apt-transport-https \
   ca-certificates \
   curl \
   gnupg-agent \
   software-properties-common

sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"

sudo apt-get update

sudo apt-get -y install -y docker-ce docker-ce-cli containerd.io jq

sudo usermod -aG docker $USER
sudo mkdir -p /etc/istio-proxy && \
sudo chmod 775 /etc/istio-proxy && \
sudo chown $USER:$USER /etc/istio-proxy

sudo docker run -d --name ratings -p 127.0.0.1:9080:9080 docker.io/istio/examples-bookinfo-ratings-v1:1.16.2
