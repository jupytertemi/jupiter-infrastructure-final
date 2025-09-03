#!/bin/bash
apt-get update
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Run COTURN
docker run -d --name coturn --restart always --network host \
  -e TURN_USER=jupiter \
  -e TURN_SECRET=jupyter-turn-2024 \
  -e REALM=video.jupyter.com.au \
  coturn/coturn \
  -n --log-file=stdout \
  --external-ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) \
  --listening-port=3478 \
  --tls-listening-port=3479 \
  --realm=video.jupyter.com.au \
  --user=jupiter:jupyter-turn-2024
