#!/bin/bash
apt-get update
apt-get install -y docker.io docker-compose
systemctl start docker
systemctl enable docker

# Create docker-compose for ThingsBoard
mkdir -p /opt/thingsboard
cat > /opt/thingsboard/docker-compose.yml << 'TB'
version: '3'
services:
  postgres:
    image: postgres:13
    environment:
      POSTGRES_DB: thingsboard
      POSTGRES_USER: thingsboard
      POSTGRES_PASSWORD: thingsboard2024
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: always

  thingsboard:
    image: thingsboard/tb-postgres
    depends_on:
      - postgres
    ports:
      - "8080:9090"
      - "1883:1883"
      - "5683:5683/udp"
    environment:
      DATABASE_TS_TYPE: sql
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/thingsboard
      SPRING_DATASOURCE_USERNAME: thingsboard
      SPRING_DATASOURCE_PASSWORD: thingsboard2024
    volumes:
      - thingsboard_data:/data
      - thingsboard_logs:/var/log/thingsboard
    restart: always

volumes:
  postgres_data:
  thingsboard_data:
  thingsboard_logs:
TB

cd /opt/thingsboard && docker-compose up -d
