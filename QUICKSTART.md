# RabbitMQ Cluster Quick Start Guide

This guide will help you set up a 3-node RabbitMQ cluster on Rocky Linux 8 using Podman, plus a test application to verify message durability and high availability.

## Prerequisites

- 4 Rocky Linux 8 servers with SSH access
- Servers can communicate with each other
- Root or sudo access on all servers

## Network Setup

For this example, we'll assume your servers have these IP addresses:
- Server 1 (rmq1): 192.168.1.101
- Server 2 (rmq2): 192.168.1.102  
- Server 3 (rmq3): 192.168.1.103
- Server 4 (test): 192.168.1.104

## Step 1: Download Files to All Servers

On **each of the first 3 servers** (rmq1, rmq2, rmq3), download the cluster files:

```bash
# Create project directory
mkdir -p ~/rabbitmq-cluster
cd ~/rabbitmq-cluster

# Copy the files: rmq.sh, rabbitmq.conf, .env.example
# (Use scp, wget, or manually copy the files from this repository)
```

## Step 2: Configure Environment

On **each of the first 3 servers**, configure the environment:

```bash
cd ~/rabbitmq-cluster

# Copy the example environment file
cp .env.example .env

# Edit .env with your actual server IP addresses
vim .env
```

Update the IP addresses in `.env`:
```bash
RMQ1_HOST=192.168.1.101
RMQ2_HOST=192.168.1.102
RMQ3_HOST=192.168.1.103
TEST_HOST=192.168.1.104

# Generate a secure Erlang cookie (same on all servers!)
ERLANG_COOKIE=$(openssl rand -base64 32)
```

**IMPORTANT:** Use the same `ERLANG_COOKIE` value on all three RabbitMQ servers!

## Step 3: Prepare Each RabbitMQ Server

Run this on **each of the 3 RabbitMQ servers**:

```bash
cd ~/rabbitmq-cluster

# Make script executable
chmod +x rmq.sh

# Prepare the system (install Podman, configure firewall)
./rmq.sh prep
```

## Step 4: Start RabbitMQ Nodes

### On Server 1 (rmq1 - 192.168.1.101):
```bash
cd ~/rabbitmq-cluster
./rmq.sh up rmq1
```

Wait for the message "RabbitMQ node rmq1 is ready!" before proceeding.

### On Server 2 (rmq2 - 192.168.1.102):
```bash
cd ~/rabbitmq-cluster  
./rmq.sh up rmq2
```

### On Server 3 (rmq3 - 192.168.1.103):
```bash
cd ~/rabbitmq-cluster
./rmq.sh up rmq3
```

## Step 5: Join Nodes to Cluster

### On Server 2 (rmq2):
```bash
./rmq.sh join rmq2 rmq1
```

### On Server 3 (rmq3):
```bash
./rmq.sh join rmq3 rmq1
```

## Step 6: Apply Quorum Queue Policy

On **any RabbitMQ server** (we'll use rmq1):
```bash
./rmq.sh policy
```

## Step 7: Verify Cluster

Check the cluster status from any node:
```bash
./rmq.sh status rmq1
```

You should see all 3 nodes in the cluster status output.

## Step 8: Access Management UI

Open your browser and visit any of the RabbitMQ management UIs:
- http://192.168.1.101:15672 (rmq1)
- http://192.168.1.102:15672 (rmq2)  
- http://192.168.1.103:15672 (rmq3)

Login with:
- Username: `admin`
- Password: `secure_password_123` (or whatever you set in .env)

## Step 9: Set Up Test Application

On **Server 4** (192.168.1.104), set up the Python test application:

```bash
# Create test directory
mkdir -p ~/rabbitmq-test
cd ~/rabbitmq-test

# Copy test files: test/ directory with Dockerfile, producer.py, consumer.py
# (Copy from the repository)
```

### Configure Test Environment

Create `.env` file for the test application:
```bash
cd ~/rabbitmq-test
cat > .env << EOF
RABBITMQ_HOST=192.168.1.101
RABBITMQ_PORT=5672
RABBITMQ_USERNAME=admin
RABBITMQ_PASSWORD=secure_password_123
RABBITMQ_VHOST=/
EOF
```

### Build Test Container

```bash
cd ~/rabbitmq-test/test
sudo dnf install -y podman
podman build -t rabbitmq-test .
```

## Step 10: Test Message Durability and High Availability

### Start Consumer (in background)

```bash
cd ~/rabbitmq-test
podman run -d --name consumer --env-file .env rabbitmq-test python consumer.py
```

### Send Test Messages

```bash
podman run --rm --env-file .env rabbitmq-test python producer.py
```

### Monitor Consumer

```bash
podman logs -f consumer
```

### Test High Availability

1. **Stop one RabbitMQ node** (on server 2):
   ```bash
   # On rmq2 server
   cd ~/rabbitmq-cluster
   ./rmq.sh down rmq2
   ```

2. **Send more messages** (on test server):
   ```bash
   podman run --rm --env-file .env rabbitmq-test python producer.py
   ```

3. **Verify consumption continues** - check consumer logs:
   ```bash
   podman logs consumer
   ```

4. **Restart the stopped node** (on server 2):
   ```bash
   # On rmq2 server
   ./rmq.sh up rmq2
   ./rmq.sh join rmq2 rmq1
   ```

5. **Check cluster status**:
   ```bash
   # On any RabbitMQ server
   ./rmq.sh status
   ```

## Expected Results

After completing these steps, you should have:

✅ **3-node RabbitMQ cluster** running with quorum queues
✅ **Management UI accessible** on all nodes
✅ **Message durability** - messages survive node failures  
✅ **High availability** - consumption continues when 1 node is down
✅ **Automatic recovery** - cluster reforms when node rejoins

## Troubleshooting

### Check cluster status:
```bash
./rmq.sh status rmq1
```

### Check container logs:
```bash
podman logs rabbitmq-rmq1
```

### Restart a problematic node:
```bash
./rmq.sh down rmq2
./rmq.sh up rmq2
./rmq.sh join rmq2 rmq1
```

### Completely reset a node:
```bash
./rmq.sh wipe rmq2  # WARNING: This deletes all data!
./rmq.sh up rmq2
./rmq.sh join rmq2 rmq1
```

### Check firewall:
```bash
sudo firewall-cmd --list-ports
```

### Test connectivity between nodes:
```bash
# From rmq2, test connection to rmq1
telnet 192.168.1.101 5672
```

## Useful Commands

### View all running containers:
```bash
podman ps
```

### Stop all RabbitMQ nodes:
```bash
./rmq.sh down rmq1
./rmq.sh down rmq2  
./rmq.sh down rmq3
```

### Check node resource usage:
```bash
podman stats
```

### Access RabbitMQ shell:
```bash
podman exec -it rabbitmq-rmq1 bash
```

## Next Steps

- Monitor cluster health with the Management UI
- Set up log aggregation for production use
- Configure TLS for secure communication
- Implement backup strategies for message persistence
- Set up monitoring and alerting