#!/bin/bash
apt-get update
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Create FRP config
mkdir -p /opt/frp
cat > /opt/frp/frps.ini << 'FRP'
[common]
bind_port = 7000
dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = jupiter2024
token = jupiter-frp-token
FRP

# Run FRP server
docker run -d --name frp --restart always \
  -p 7000:7000 -p 7500:7500 \
  -v /opt/frp:/etc/frp \
  snowdreamtech/frps
