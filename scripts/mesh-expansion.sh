#!/usr/bin/env bash
 
sudo su -

apt-get update

apt-get install \
   apt-transport-https \
   ca-certificates \
   curl \
   gnupg-agent \
   software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"

apt-get update

apt-get install -y docker-ce docker-ce-cli containerd.io jq
exit

sudo usermod -aG docker $USER
sudo mkdir -p /etc/istio-proxy && \
sudo chmod 775 /etc/istio-proxy && \
sudo chown $USER:$USER /etc/istio-proxy

sudo docker run -d   --name ratings   -p 127.0.0.1:9080:9080   docker.io/istio/examples-bookinfo-ratings-v1:1.16.2 
