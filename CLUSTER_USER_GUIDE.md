# RabbitMQ Cluster - User Guide

**Complete guide for using and managing the 3-node RabbitMQ cluster**

---

## 📋 Table of Contents

1. [Cluster Overview](#cluster-overview)
2. [Access Information](#access-information)
3. [Quick Start](#quick-start)
4. [Management UI](#management-ui)
5. [Running Load Tests](#running-load-tests)
6. [Common Operations](#common-operations)
7. [Monitoring](#monitoring)
8. [Troubleshooting](#troubleshooting)
9. [Architecture Details](#architecture-details)
10. [File Reference](#file-reference)

---

## 🏗️ Cluster Overview

**3-node RabbitMQ cluster** running on Rocky Linux 8 using Podman containers:

- **High Availability**: Quorum queues with 3x replication
- **Message Persistence**: All messages survive node failures
- **Tested Capacity**: 150,000 messages/second at 100KB each
- **Management UI**: Web interface for monitoring and management
- **Load Testing**: Built-in scripts for testing cluster performance

---

## 🔐 Access Information

### Server Details

| Server | Hostname/IP | Role | Ports |
|--------|-------------|------|-------|
| RMQ1 | 172.23.12.11 | Primary RabbitMQ Node | 5672, 15672, 4369, 25672 |
| RMQ2 | 172.23.12.12 | RabbitMQ Node | 5672, 15672, 4369, 25672 |
| RMQ3 | 172.23.12.13 | RabbitMQ Node | 5672, 15672, 4369, 25672 |
| TEST | 172.23.12.14 | Test Application Host | - |

### Credentials

**RabbitMQ Admin User:**
```
Username: admin
Password: secure_password_123
```

**Management UI URLs:**
- http://172.23.12.11:15672 (Node 1)
- http://172.23.12.12:15672 (Node 2)
- http://172.23.12.13:15672 (Node 3)

**Erlang Cookie** (for cluster communication):
```
See .env file: ERLANG_COOKIE variable
```

### Port Reference

| Port | Service | Description |
|------|---------|-------------|
| 5672 | AMQP | Main messaging port (client connections) |
| 15672 | Management | Web UI and HTTP API |
| 4369 | EPMD | Erlang Port Mapper Daemon |
| 25672 | Inter-node | Cluster communication |

---

## 🚀 Quick Start

### Checking Cluster Status

SSH to any RabbitMQ node and run:

```bash
cd ~/c#rabbitMQcluster
./rmq.sh status
```

**Expected output:**
```
✓ rmq1 is running
✓ rmq2 is running
✓ rmq3 is running
Cluster status: All nodes connected
```

### Starting a Stopped Node

```bash
./rmq.sh up rmq1
```

### Stopping a Node (Maintenance)

```bash
./rmq.sh down rmq1
```

### Viewing Node Logs

```bash
podman logs rmq1        # Recent logs
podman logs -f rmq1     # Follow logs in real-time
```

---

## 🖥️ Management UI

### Accessing the UI

Open any of these URLs in your browser:
- http://172.23.12.11:15672
- http://172.23.12.12:15672
- http://172.23.12.13:15672

**Login:**
- Username: `admin`
- Password: `secure_password_123`

### Key Pages

1. **Overview** - Cluster health, message rates, resource usage
2. **Connections** - Active client connections
3. **Channels** - AMQP channels (one per connection typically)
4. **Queues** - All queues, their messages, consumers
5. **Admin** - Users, virtual hosts, policies

### Important Metrics to Monitor

- **Memory Usage**: Should stay below 10.5 GB (70% of 15GB)
- **Disk Space**: Should have at least 5GB free
- **Message Rate**: Shows publish/deliver rates
- **Queue Depth**: Number of messages waiting in queues
- **Connections**: Should see producer/consumer connections when running tests

### Alarms

**Red alarm in top-right corner means:**
- 🚨 **Memory alarm**: RabbitMQ using >70% of 15GB RAM
- 🚨 **Disk alarm**: Free disk space <5GB

**Action**: Connections will be blocked until alarm clears. See [Troubleshooting](#troubleshooting).

---

## 🧪 Running Load Tests

### Simple Load Test (Quick Verification)

**Purpose**: Quick test to verify cluster is working

**Steps:**

1. SSH to test host (172.23.12.14)
2. Navigate to cluster directory:
   ```bash
   cd ~/c#rabbitMQcluster
   ```

3. **(Optional)** Edit configuration:
   ```bash
   nano simple_load_test.conf
   ```
   Recommended starting values:
   ```bash
   MESSAGES_PER_SECOND=1000    # 1K msg/s
   MESSAGE_SIZE_KB=10          # 10 KB messages
   TEST_DURATION_SECONDS=30    # 30 second test
   ```

4. Run the test:
   ```bash
   chmod +x simple_load_test.sh
   ./simple_load_test.sh
   ```

5. Watch for:
   - ✓ "Connected successfully" from all workers
   - ✓ "First message sent successfully"
   - ✓ Milestone messages showing progress
   - ⚠️ "BLOCKED" warnings (if these appear, reduce load)

**Results:**
- Logs saved to: `/tmp/producer.log`, `/tmp/consumer.log`
- Check RabbitMQ UI to see queue statistics

---

### Full Load Test (Performance Testing)

**Purpose**: Test cluster at high load (150,000 msg/s)

**⚠️ WARNING**: This test uses ~1.43 TB of data over 100 seconds!

**Steps:**

1. SSH to test host (172.23.12.14)
2. Navigate to cluster directory:
   ```bash
   cd ~/c#rabbitMQcluster
   ```

3. Run full load test with monitoring:
   ```bash
   chmod +x load_test.sh
   ./load_test.sh full
   ```

4. Access Grafana dashboard:
   - URL: http://172.23.12.14:3000
   - Username: `admin`
   - Password: `admin123`
   - Navigate to "RabbitMQ Load Test" dashboard

**Test Components:**
- **Producer**: 40 workers × 10 connections each = 400 total connections
- **Consumer**: 20 workers consuming messages
- **Duration**: 100 seconds
- **Target Rate**: 150,000 messages/second
- **Message Size**: 100 KB each

**Expected Results:**
- ~15 million messages published
- ~1.43 TB of data transferred
- Queue depth should drain to near-zero
- No memory/disk alarms (if configured correctly)

---

## 🛠️ Common Operations

### Viewing Cluster Status

```bash
./rmq.sh status
```

Shows:
- Which nodes are running
- Container status
- Management UI URLs

### Restarting a Node

```bash
./rmq.sh down rmq1
./rmq.sh up rmq1
```

**Note**: Node will automatically rejoin cluster when started.

### Adding/Checking Policies

Quorum queue policy (already applied):

```bash
./rmq.sh policy
```

This ensures all queues use quorum type with 3x replication.

### Purging a Queue (Delete All Messages)

**Via Management UI:**
1. Go to "Queues" tab
2. Click the queue name
3. Scroll down → "Purge Messages" button
4. Confirm

**Via API:**
```bash
curl -u admin:secure_password_123 -X DELETE \
  http://172.23.12.11:15672/api/queues/%2F/QUEUE_NAME/contents
```

### Deleting a Queue

**Via Management UI:**
1. Go to "Queues" tab
2. Click the queue name
3. Scroll down → "Delete" button
4. Confirm

**Via API:**
```bash
curl -u admin:secure_password_123 -X DELETE \
  http://172.23.12.11:15672/api/queues/%2F/QUEUE_NAME
```

### Checking Disk Space

On any RabbitMQ node:

```bash
df -h /var/lib/rabbitmq
```

Should show **at least 5GB free** to avoid disk alarms.

### Checking Memory Usage

In Management UI:
- Look at "Memory" section on Overview page
- Should be below 10.5 GB (70% of 15GB)

Or via command line:
```bash
podman stats rmq1 rmq2 rmq3
```

---

## 📊 Monitoring

### Grafana Dashboard

If monitoring stack is running:

**Access:**
- URL: http://172.23.12.14:3000
- Username: `admin`
- Password: `admin123`

**Dashboard**: "RabbitMQ Load Test" shows:
- Message rates (publish/consume)
- Queue depths
- Memory usage per node
- Connection counts
- Disk I/O

### Prometheus

Raw metrics available at:
- http://172.23.12.14:9090

### Setting Up Monitoring

If not already running:

```bash
cd ~/c#rabbitMQcluster
./load_test.sh monitor
```

### Stopping Monitoring

```bash
./load_test.sh cleanup
```

---

## 🔧 Troubleshooting

### Problem: "Connection Blocked" or Red Alarm in UI

**Symptoms:**
- Red alarm icon in Management UI
- Producer logs show "⚠️ BLOCKED"
- Connections refuse to send messages

**Cause 1: Memory Alarm**

RabbitMQ using >70% of 15GB RAM (10.5 GB).

**Fix:**
1. Let consumers catch up (queue depth decreases → memory freed)
2. Reduce producer rate in test config
3. Purge queues if needed
4. Increase memory limit:
   - Edit `rabbitmq.conf`: `vm_memory_high_watermark.relative = 0.9`
   - Restart node: `./rmq.sh down rmq1 && ./rmq.sh up rmq1`

**Cause 2: Disk Alarm**

Free disk space <5GB on node.

**Fix:**
1. Check disk space: `df -h /var/lib/rabbitmq`
2. Delete old logs: `sudo rm -rf /var/lib/rabbitmq/rmq1/log/*`
3. Increase disk space on host machine

---

### Problem: "No Connections or Channels Visible"

**Symptoms:**
- Producer/consumer scripts run but no connections in Management UI
- No messages in queue

**Cause 1: Queue Type Mismatch**

Queue exists as quorum but producer declares as classic (or vice versa).

**Fix:**
1. Delete the queue in Management UI
2. Re-run test (will recreate correctly)

**Cause 2: Container Stopped**

Producer/consumer container exited immediately.

**Fix:**
1. Check logs: `podman logs simple-producer`
2. Look for connection errors, import errors
3. Rebuild container: `cd test && podman build -t rabbitmq-simple-test .`

---

### Problem: Messages Sent but Queue Shows 0

**Possible Reasons:**

1. **Consumer eating messages immediately** (✅ Good!)
   - Check consumer logs: should show "Messages received"
   - This is normal - consumer is keeping up with producer

2. **Queue type mismatch** (❌ Bad!)
   - Delete queue and recreate

3. **Connection blocked** (❌ Bad!)
   - Check for alarms (memory/disk)

---

### Problem: Low Throughput

**Expected Rates:**
- Simple test: ~1,000-5,000 msg/s (configurable)
- Full load test: ~150,000 msg/s

**If lower than expected:**

1. **Check worker count** in config:
   - `simple_load_test.conf`: `PRODUCER_WORKERS=4` (increase to 8-16)
   - `load_test.conf`: `PRODUCER_WORKERS=40`

2. **Check message size**:
   - Larger messages = lower message rate (but higher data rate)

3. **Check for alarms**:
   - Memory/disk alarms throttle performance

4. **Check network**:
   - Run `iftop` on RabbitMQ nodes to see network usage
   - Should see ~150-200 Mbps during simple test

---

### Problem: Node Won't Start

**Symptoms:**
```bash
./rmq.sh up rmq1
# Container exits immediately
```

**Causes:**

1. **Port already in use**:
   ```bash
   sudo netstat -tulpn | grep 5672
   # If something else using port, stop it or change RabbitMQ port
   ```

2. **Data directory permission error**:
   ```bash
   sudo chown -R $(id -u):$(id -g) /var/lib/rabbitmq/rmq1
   ```

3. **Corrupted data**:
   ```bash
   ./rmq.sh wipe rmq1  # ⚠️ Deletes all data!
   ./rmq.sh up rmq1
   ./rmq.sh join rmq1 rmq2  # Rejoin cluster
   ```

---

### Problem: Cluster Partition (Nodes Disconnected)

**Symptoms:**
- `./rmq.sh status` shows some nodes not communicating
- Management UI shows only some nodes

**Fix:**

1. Stop all nodes:
   ```bash
   ./rmq.sh down rmq1
   ./rmq.sh down rmq2
   ./rmq.sh down rmq3
   ```

2. Start primary node:
   ```bash
   ./rmq.sh up rmq1
   ```

3. Join other nodes:
   ```bash
   ./rmq.sh join rmq2 rmq1
   ./rmq.sh join rmq3 rmq1
   ```

4. Verify cluster:
   ```bash
   ./rmq.sh status
   ```

---

## 🏛️ Architecture Details

### Container Setup

Each RabbitMQ node runs as a **rootless Podman container**:

- **Image**: `rabbitmq:3.13-management`
- **Data Directory**: `/var/lib/rabbitmq/{node_name}/`
- **Config File**: Mounted from `./rabbitmq.conf`
- **Network Mode**: Host networking (ports exposed directly)

### Cluster Discovery

Uses **classic config peer discovery**:
- Nodes specified in `rabbitmq.conf`: `cluster_formation.classic_config.nodes`
- Shared Erlang cookie for authentication
- Automatic rejoin on restart

### Queue Types

**Quorum Queues** (default via policy):
- 3x replication across all nodes
- Data survives node failures
- Higher durability, lower performance than classic

**Classic Queues** (used in simple load test):
- Single-node storage (no replication)
- Higher performance
- Suitable for testing, not production HA

### Data Flow

```
Producer → RabbitMQ Node → Queue → Consumer
            ↓              ↓
       (confirms)    (persistence)
```

1. **Producer** connects to any node (round-robin)
2. **Message** routed to queue (may be on different node)
3. **Queue** replicates to other nodes (if quorum)
4. **Consumer** connects to any node, receives message
5. **Acknowledgment** sent back after processing

### High Availability

- **Node Failure**: Other nodes continue serving
- **Queue Replication**: Quorum queues survive 1 node failure
- **Client Reconnection**: Clients should retry on connection loss

---

## 📁 File Reference

### Configuration Files

| File | Purpose | Location |
|------|---------|----------|
| `.env` | Environment variables (credentials, IPs) | Repository root |
| `rabbitmq.conf` | RabbitMQ server configuration | Repository root |
| `simple_load_test.conf` | Simple test parameters | Repository root |
| `load_test.conf` | Full load test parameters | Repository root |

### Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `rmq.sh` | Cluster management | `./rmq.sh <command>` |
| `simple_load_test.sh` | Simple load test runner | `./simple_load_test.sh` |
| `load_test.sh` | Full load test runner | `./load_test.sh full` |

### Test Applications

| File | Purpose | Location |
|------|---------|----------|
| `test/simple_multiprocess_producer.py` | Simple test producer | `test/` directory |
| `test/simple_multiprocess_consumer.py` | Simple test consumer | `test/` directory |
| `test/load_test_producer.py` | High-performance producer | `test/` directory |
| `test/load_test_consumer.py` | High-performance consumer | `test/` directory |

### Documentation

| File | Purpose |
|------|---------|
| `QUICKSTART.md` | Initial setup guide |
| `SIMPLE_LOAD_TEST_GUIDE.md` | Simple test detailed guide |
| `LOAD_TEST.md` | Full load test guide |
| `RABBITMQ_DOCUMENTATION.md` | RabbitMQ Python reference |
| `CLUSTER_USER_GUIDE.md` | This file (operations guide) |

---

## 🆘 Getting Help

### Check Logs First

**RabbitMQ Node Logs:**
```bash
podman logs rmq1
podman logs rmq2
podman logs rmq3
```

**Test Container Logs:**
```bash
podman logs simple-producer
podman logs simple-consumer
# Or check saved logs:
cat /tmp/producer.log
cat /tmp/consumer.log
```

### Management UI

Check Overview page for:
- Alarms (red icon)
- Memory usage (should be <10.5 GB)
- Disk space (should be >5 GB)
- Message rates (should match test expectations)

### Common Commands

**View running containers:**
```bash
podman ps
```

**View all containers (including stopped):**
```bash
podman ps -a
```

**Restart everything:**
```bash
./rmq.sh down rmq1 && ./rmq.sh down rmq2 && ./rmq.sh down rmq3
./rmq.sh up rmq1
sleep 5
./rmq.sh join rmq2 rmq1
./rmq.sh join rmq3 rmq1
./rmq.sh policy
./rmq.sh status
```

---

## 📞 Contact

For issues or questions, contact the cluster administrator at: **[INSERT CONTACT INFO]**

---

**Document Version**: 1.0
**Last Updated**: 2025-11-13
**Cluster Version**: RabbitMQ 3.13 / Rocky Linux 8
