#!/bin/bash
apt-get update
apt-get install -y docker.io docker-compose
systemctl start docker
systemctl enable docker

# Create signaling service
cat > /opt/signaling-server.js << 'SIGNALING'
const express = require('express');
const app = express();
const server = require('http').createServer(app);
const io = require('socket.io')(server);

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

io.on('connection', (socket) => {
  console.log('Client connected:', socket.id);
  
  socket.on('offer', (data) => {
    socket.broadcast.emit('offer', data);
  });
  
  socket.on('answer', (data) => {
    socket.broadcast.emit('answer', data);
  });
  
  socket.on('ice-candidate', (data) => {
    socket.broadcast.emit('ice-candidate', data);
  });
});

server.listen(3000, '0.0.0.0', () => {
  console.log('Signaling server running on port 3000');
});
SIGNALING

# Run with Docker
docker run -d --name signaling --restart always -p 3000:3000 -v /opt:/app -w /app node:18 sh -c "npm install express socket.io && node signaling-server.js"
