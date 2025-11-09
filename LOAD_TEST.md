# RabbitMQ Load Test Guide

Simplified guide for load testing your RabbitMQ cluster with customizable parameters.

## Table of Contents
1. [Quick Start](#quick-start)
2. [Prerequisites](#prerequisites)
3. [Configuration](#configuration)
4. [Running Tests](#running-tests)
5. [Monitoring](#monitoring)
6. [Troubleshooting](#troubleshooting)

---

## Quick Start

**TL;DR: Four simple steps to run a load test**

```bash
# 1. One-time setup
./load_test.sh prep

# 2. Configure test (edit load_test_params.env)
# Set MESSAGE_SIZE_BYTES, MESSAGES_PER_SECOND, TEST_DURATION_SECONDS

# 3. Validate everything is ready
./load_test.sh validate

# 4. Run the test
./load_test.sh test
```

Results will be saved in `load_test_results/` with logs and a summary report.

---

## Prerequisites

### Required (Must Have)

#### 1. RabbitMQ Cluster Running
Ensure your 3-node RabbitMQ cluster is up and healthy:

```bash
./rmq.sh status
```

You should see all 3 nodes running. If not, start the cluster:

```bash
./rmq.sh up rmq1
./rmq.sh up rmq2
./rmq.sh join rmq2 rmq1
./rmq.sh up rmq3
./rmq.sh join rmq3 rmq1
./rmq.sh policy
```

#### 2. Configuration Files
- **`.env`** - Copy from `.env.example` and configure:
  - RabbitMQ node IPs (RMQ1_HOST, RMQ2_HOST, RMQ3_HOST, TEST_HOST)
  - Admin credentials (RABBITMQ_ADMIN_USER, RABBITMQ_ADMIN_PASSWORD)
  - Erlang cookie (RABBITMQ_ERLANG_COOKIE)

- **`load_test_params.env`** - Created by the prep command, configure:
  - MESSAGE_SIZE_BYTES (e.g., 1024 = 1KB, 102400 = 100KB)
  - MESSAGES_PER_SECOND (e.g., 1000, 10000, 150000)
  - TEST_DURATION_SECONDS (e.g., 10, 60, 100)

#### 3. System Dependencies
- Podman or Docker installed
- curl installed
- Bash shell

### Optional (For Full Monitoring)

#### Node Exporters on RabbitMQ Nodes
For complete system metrics, install node-exporter on each RabbitMQ server:

**On each RabbitMQ node (rmq1, rmq2, rmq3):**

```bash
# Download and install node-exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-amd64.tar.gz
tar xvfz node_exporter-1.6.1.linux-amd64.tar.gz
sudo mv node_exporter-1.6.1.linux-amd64/node_exporter /usr/local/bin/

# Create systemd service
sudo tee /etc/systemd/system/node-exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

# Start service
sudo systemctl daemon-reload
sudo systemctl enable node-exporter
sudo systemctl start node-exporter

# Open firewall
sudo firewall-cmd --permanent --add-port=9100/tcp
sudo firewall-cmd --reload
```

**Verify exporters are accessible:**
```bash
curl http://RMQ1_HOST:9100/metrics
curl http://RMQ2_HOST:9100/metrics
curl http://RMQ3_HOST:9100/metrics
```

If exporters are not installed, the test will still run but monitoring will have incomplete data.

---

## Configuration

### 1. RabbitMQ Cluster Configuration (.env)

Edit `.env` file with your cluster details:

```bash
# RabbitMQ Cluster Nodes
RMQ1_HOST=192.168.1.101
RMQ2_HOST=192.168.1.102
RMQ3_HOST=192.168.1.103
TEST_HOST=192.168.1.104

# RabbitMQ Credentials
RABBITMQ_ADMIN_USER=admin
RABBITMQ_ADMIN_PASSWORD=secure_password_123

# Erlang Cookie (must match cluster)
RABBITMQ_ERLANG_COOKIE=your-secure-cookie-here

# Optional: Grafana Admin Password
GRAFANA_ADMIN_PASSWORD=admin123
```

### 2. Load Test Parameters (load_test_params.env)

This file is created by `./load_test.sh prep`. Edit it to configure your test:

#### Core Test Parameters

```bash
# Message size in bytes
MESSAGE_SIZE_BYTES=102400  # 100KB

# Target message rate (messages per second)
MESSAGES_PER_SECOND=10000  # 10K msg/s

# Test duration in seconds
TEST_DURATION_SECONDS=60   # 1 minute
```

**Example Configurations:**

**Quick Test (Sanity Check)**
```bash
MESSAGE_SIZE_BYTES=1024
MESSAGES_PER_SECOND=1000
TEST_DURATION_SECONDS=10
PRODUCER_WORKERS=1
CONSUMER_WORKERS=1
```
*Total: 10,000 messages, ~10MB data*

**Medium Test (Configuration Validation)**
```bash
MESSAGE_SIZE_BYTES=10240
MESSAGES_PER_SECOND=10000
TEST_DURATION_SECONDS=60
PRODUCER_WORKERS=2
CONSUMER_WORKERS=2
```
*Total: 600,000 messages, ~6GB data*

**Full Load Test (Maximum Throughput)**
```bash
MESSAGE_SIZE_BYTES=102400
MESSAGES_PER_SECOND=150000
TEST_DURATION_SECONDS=100
PRODUCER_WORKERS=8
CONSUMER_WORKERS=4
```
*Total: 15,000,000 messages, ~1.43TB data*

#### Producer Configuration

```bash
PRODUCER_WORKERS=4                      # Number of producer processes
PRODUCER_CONNECTIONS_PER_WORKER=10      # Connections per worker
PRODUCER_CHANNELS_PER_CONNECTION=5      # Channels per connection
PUBLISHER_CONFIRMS=true                 # Guaranteed delivery
PRODUCER_BATCH_SIZE=100                 # Messages per batch
```

#### Consumer Configuration

```bash
CONSUMER_WORKERS=2                      # Number of consumer processes
CONSUMER_CONNECTIONS_PER_WORKER=10      # Connections per worker
CONSUMER_PREFETCH_COUNT=200             # Messages to prefetch
CONSUMER_BATCH_ACK_SIZE=50              # Acknowledge every N messages
CONSUMER_PROCESSING_DELAY_MS=0          # Simulated processing time
```

#### Queue Configuration

```bash
QUEUE_NAME=load_test_queue              # Queue name
QUEUE_TYPE=quorum                       # quorum or classic
QUEUE_DURABLE=true                      # Survive broker restart
MESSAGE_DELIVERY_MODE=2                 # 1=non-persistent, 2=persistent
```

---

## Running Tests

### Step 1: Prepare Environment (One-Time Setup)

```bash
./load_test.sh prep
```

This command:
- Validates configuration files (.env)
- Builds test container images
- Generates Prometheus configuration from template
- Creates results directory
- Validates system dependencies

**Expected Output:**
```
[INFO] Loading configuration files...
[SUCCESS] Loaded .env and load_test_params.env
[INFO] Validating system dependencies...
[SUCCESS]   podman found
[SUCCESS]   curl found
[SUCCESS] All dependencies satisfied
...
[SUCCESS] === Preparation Complete ===
```

### Step 2: Configure Test Parameters

Edit `load_test_params.env`:

```bash
# Use your preferred text editor
nano load_test_params.env
# or
vi load_test_params.env
```

Set the three main parameters:
1. `MESSAGE_SIZE_BYTES` - How big each message is
2. `MESSAGES_PER_SECOND` - How fast to send messages
3. `TEST_DURATION_SECONDS` - How long to run the test

### Step 3: Validate Prerequisites

```bash
./load_test.sh validate
```

This command checks:
- RabbitMQ cluster is running (3 nodes)
- All nodes are accessible
- Configuration files are valid
- Node exporters are accessible (warns if missing)

**Expected Output:**
```
[INFO] Validating RabbitMQ cluster...
[SUCCESS] RabbitMQ cluster is healthy (3 nodes running)
[INFO] Validating monitoring exporters (manual prerequisites)...
[SUCCESS]   Node Exporter (rmq1) is accessible at 192.168.1.101:9100
[SUCCESS]   Node Exporter (rmq2) is accessible at 192.168.1.102:9100
[SUCCESS]   Node Exporter (rmq3) is accessible at 192.168.1.103:9100
[SUCCESS] === All Prerequisites Satisfied ===
```

### Step 4: Run Load Test

```bash
./load_test.sh test
```

This command:
1. Starts monitoring stack (Prometheus, Grafana)
2. Creates test queue
3. Starts consumer workers
4. Starts producer workers
5. Monitors progress with real-time progress bar
6. Collects logs from all workers
7. Stops test containers
8. Generates comprehensive report

**During the Test:**
```
[INFO] Test running for 60 seconds...
[INFO] Monitor progress at:
  - Grafana: http://localhost:3000
  - Prometheus: http://localhost:9090
  - RabbitMQ Management: http://192.168.1.101:15672
  Progress: [##########################                        ] 52% (31/60 seconds)
```

**After the Test:**
```
[SUCCESS] === Load Test Complete ===
[INFO] Results saved to: load_test_results/20250102_143022
[INFO] View report: cat load_test_results/20250102_143022/report.txt
```

### Step 5: View Results

```bash
./load_test.sh report
```

Or manually view the report:

```bash
cat load_test_results/TIMESTAMP/report.txt
```

---

## Monitoring

### Grafana Dashboard

Access Grafana at **http://localhost:3000**

**Default Credentials:**
- Username: `admin`
- Password: `admin123` (or value from .env: GRAFANA_ADMIN_PASSWORD)

**Pre-configured Dashboard:**
- Navigate to Dashboards → RabbitMQ Load Test
- View real-time metrics:
  - Message rates (publish/consume)
  - Queue depth
  - Connection counts
  - Memory usage per node
  - CPU utilization
  - Network throughput

### Prometheus

Access Prometheus at **http://localhost:9090**

**Useful Queries:**

**Message publish rate:**
```promql
rate(rabbitmq_global_messages_published_total[1m])
```

**Message consume rate:**
```promql
rate(rabbitmq_global_messages_consumed_total[1m])
```

**Queue depth:**
```promql
rabbitmq_queue_messages{queue="load_test_queue"}
```

**Node memory usage:**
```promql
rabbitmq_node_mem_used{node=~"rabbit@.*"}
```

### RabbitMQ Management UI

Access at **http://RMQ1_HOST:15672**

- View queue statistics
- Monitor connection counts
- Check node health
- View message rates

---

## Additional Commands

### Start Monitoring Only

```bash
./load_test.sh monitor-start
```

Starts only the monitoring stack without running a test. Useful for:
- Viewing historical data
- Monitoring cluster during manual operations
- Testing monitoring setup

### Stop Monitoring

```bash
./load_test.sh monitor-stop
```

Stops the monitoring stack. **Note:** This does not delete historical data stored in volumes.

### Cleanup Test Artifacts

```bash
./load_test.sh cleanup
```

This command:
- Stops and removes test containers
- Deletes test queue from RabbitMQ
- Removes temporary files (test/.env)

**Note:** Monitoring stack remains running. Use `monitor-stop` to stop it.

### Help

```bash
./load_test.sh help
```

Shows all available commands and usage information.

---

## Troubleshooting

### Issue: "Cannot reach RabbitMQ nodes"

**Symptoms:**
```
[ERROR] Cannot reach RabbitMQ nodes:
  - 192.168.1.101:15672
```

**Solutions:**
1. Verify cluster is running:
   ```bash
   ./rmq.sh status
   ```

2. Check network connectivity:
   ```bash
   curl http://RMQ1_HOST:15672/api/overview -u admin:password
   ```

3. Verify .env file has correct IPs and credentials

### Issue: "Node exporters not accessible"

**Symptoms:**
```
[WARNING]   Node Exporter (rmq1) is NOT accessible at 192.168.1.101:9100
[WARNING] Some exporters are not accessible
```

**Solutions:**
1. This is a WARNING, not an ERROR - test will still run
2. For complete monitoring, install node-exporter (see [Prerequisites](#optional-for-full-monitoring))
3. Verify firewall allows port 9100:
   ```bash
   sudo firewall-cmd --list-ports | grep 9100
   ```

### Issue: "Failed to build container image"

**Symptoms:**
```
[ERROR] Failed to build container image
```

**Solutions:**
1. Check Docker/Podman is running:
   ```bash
   podman --version
   # or
   docker --version
   ```

2. Verify test/Dockerfile exists:
   ```bash
   ls test/Dockerfile
   ```

3. Check test/requirements.txt exists:
   ```bash
   ls test/requirements.txt
   ```

4. Try building manually to see detailed error:
   ```bash
   cd test/
   podman build -t rabbitmq-load-test .
   ```

### Issue: "Monitoring stack failed to start"

**Symptoms:**
```
[ERROR] Failed to start monitoring stack
```

**Solutions:**
1. Check if ports are already in use:
   ```bash
   sudo netstat -tlnp | grep -E '3000|9090|9091'
   ```

2. Stop any existing monitoring containers:
   ```bash
   cd monitoring/
   podman-compose down
   # or
   docker-compose down
   ```

3. Check docker-compose.yml exists:
   ```bash
   ls monitoring/docker-compose.yml
   ```

4. Verify prometheus.yml was generated:
   ```bash
   ls monitoring/prometheus.yml
   ```

### Issue: Test runs but no messages are processed

**Symptoms:**
- Test completes successfully
- Logs show 0 messages produced/consumed
- RabbitMQ queue is empty

**Solutions:**
1. Check producer logs:
   ```bash
   cat load_test_results/TIMESTAMP/producer_1.log
   ```

2. Check consumer logs:
   ```bash
   cat load_test_results/TIMESTAMP/consumer_1.log
   ```

3. Verify test environment file was created:
   ```bash
   cat test/.env
   ```

4. Check RabbitMQ connection:
   ```bash
   curl -u admin:password http://RMQ1_HOST:15672/api/connections
   ```

### Issue: Load test is slower than expected

**Symptoms:**
- Configured for 10,000 msg/s but only achieving 1,000 msg/s
- Large queue depth building up

**Solutions:**
1. **Increase consumer workers** in `load_test_params.env`:
   ```bash
   CONSUMER_WORKERS=4  # Increase this
   ```

2. **Increase prefetch count**:
   ```bash
   CONSUMER_PREFETCH_COUNT=500  # Increase from 200
   ```

3. **Check system resources**:
   - CPU utilization: `top` or `htop`
   - Memory usage: `free -h`
   - Disk I/O: `iostat -x 1`

4. **Check network bandwidth**:
   ```bash
   iftop  # Real-time network usage
   ```

5. **Review RabbitMQ logs** for errors:
   ```bash
   podman logs rmq1
   ```

### Issue: Out of memory or disk space

**Symptoms:**
```
RabbitMQ logs show: "Disk space alarm"
RabbitMQ logs show: "Memory alarm"
```

**Solutions:**
1. **Stop the test immediately**:
   ```bash
   ./load_test.sh cleanup
   ```

2. **Clear the test queue**:
   ```bash
   curl -u admin:password -X DELETE \
     http://RMQ1_HOST:15672/api/queues/%2F/load_test_queue
   ```

3. **Reduce test parameters**:
   ```bash
   MESSAGE_SIZE_BYTES=10240  # Smaller messages
   MESSAGES_PER_SECOND=1000  # Lower rate
   TEST_DURATION_SECONDS=30  # Shorter test
   ```

4. **Check available resources**:
   ```bash
   df -h  # Disk space
   free -h  # Memory
   ```

---

## Performance Tips

### For Maximum Throughput

1. **Use non-persistent messages** (faster but not durable):
   ```bash
   MESSAGE_DELIVERY_MODE=1
   ```

2. **Use classic queues instead of quorum**:
   ```bash
   QUEUE_TYPE=classic
   ```

3. **Disable publisher confirms**:
   ```bash
   PUBLISHER_CONFIRMS=false
   ```

4. **Increase batch sizes**:
   ```bash
   PRODUCER_BATCH_SIZE=500
   CONSUMER_BATCH_ACK_SIZE=200
   ```

5. **Reduce prefetch for memory**:
   ```bash
   CONSUMER_PREFETCH_COUNT=100
   ```

### For Maximum Durability

1. **Use persistent messages**:
   ```bash
   MESSAGE_DELIVERY_MODE=2
   ```

2. **Use quorum queues**:
   ```bash
   QUEUE_TYPE=quorum
   ```

3. **Enable publisher confirms**:
   ```bash
   PUBLISHER_CONFIRMS=true
   ```

### For Balanced Performance

Use the default parameters in `load_test_params.env` - they provide a good balance between throughput and durability.

---

## Understanding Results

### Report File Structure

```
load_test_results/
└── 20250102_143022/
    ├── report.txt          # Summary report
    ├── producer_1.log      # Producer worker 1 logs
    ├── producer_2.log      # Producer worker 2 logs
    ├── consumer_1.log      # Consumer worker 1 logs
    └── consumer_2.log      # Consumer worker 2 logs
```

### Report Contents

```
================================================================================
RabbitMQ Load Test Report
================================================================================
Generated: Tue Jan  2 14:35:45 UTC 2025

Test Configuration:
------------------
Message Size: 102400 bytes
Target Rate: 10000 msg/s
Duration: 60 seconds
Producer Workers: 4
Consumer Workers: 2

Expected Results:
----------------
Total Messages: 600000
Total Data: ~57 GB

RabbitMQ Cluster:
----------------
Node 1: 192.168.1.101
Node 2: 192.168.1.102
Node 3: 192.168.1.103
```

### Log Analysis

**Producer logs** show:
- Connection establishment
- Message publishing rates
- Publisher confirm responses
- Errors or warnings

**Consumer logs** show:
- Connection establishment
- Message consumption rates
- Acknowledgment batching
- Processing statistics
- Errors or warnings

---

## Advanced Configuration

### Custom Worker Distribution

For very high throughput, you may want to tune the worker distribution:

```bash
# More producers than consumers (fast publishing, slower processing)
PRODUCER_WORKERS=8
CONSUMER_WORKERS=2

# Equal producers and consumers (balanced)
PRODUCER_WORKERS=4
CONSUMER_WORKERS=4

# More consumers than producers (catch up on backlog)
PRODUCER_WORKERS=2
CONSUMER_WORKERS=6
```

### Connection Tuning

```bash
# Many connections with few channels (simpler but more overhead)
PRODUCER_CONNECTIONS_PER_WORKER=20
PRODUCER_CHANNELS_PER_CONNECTION=2

# Few connections with many channels (more complex, less overhead)
PRODUCER_CONNECTIONS_PER_WORKER=5
PRODUCER_CHANNELS_PER_CONNECTION=10
```

### Queue Tuning

```bash
# For maximum throughput (low latency)
CONSUMER_PREFETCH_COUNT=50
CONSUMER_BATCH_ACK_SIZE=10

# For high throughput (higher latency acceptable)
CONSUMER_PREFETCH_COUNT=500
CONSUMER_BATCH_ACK_SIZE=100
```

---

## Files Reference

- **load_test.sh** - Main test orchestration script
- **load_test_params.env** - Test configuration parameters
- **.env** - Cluster connection configuration
- **monitoring/prometheus.yml.template** - Prometheus config template
- **monitoring/prometheus.yml** - Generated Prometheus config (do not edit)
- **monitoring/docker-compose.yml** - Monitoring stack definition
- **test/Dockerfile** - Test container image definition
- **test/requirements.txt** - Python dependencies
- **test/load_test_producer.py** - High-performance producer
- **test/load_test_consumer.py** - High-performance consumer
- **LOAD_TEST.md** - This documentation

---

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Review test logs in `load_test_results/TIMESTAMP/`
3. Check RabbitMQ logs: `podman logs rmq1`
4. Verify cluster health: `./rmq.sh status`

---

## Summary Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. Prerequisites                                           │
│     - RabbitMQ cluster running                              │
│     - .env file configured                                  │
│     - Node exporters installed (optional)                   │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Prepare (one-time)                                      │
│     $ ./load_test.sh prep                                   │
│     - Builds containers                                     │
│     - Generates configs                                     │
│     - Validates system                                      │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Configure                                               │
│     Edit load_test_params.env:                              │
│     - MESSAGE_SIZE_BYTES                                    │
│     - MESSAGES_PER_SECOND                                   │
│     - TEST_DURATION_SECONDS                                 │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  4. Validate                                                │
│     $ ./load_test.sh validate                               │
│     - Checks cluster health                                 │
│     - Verifies exporters                                    │
│     - Validates config                                      │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  5. Run Test                                                │
│     $ ./load_test.sh test                                   │
│     - Starts monitoring                                     │
│     - Runs load test                                        │
│     - Collects results                                      │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  6. Analyze Results                                         │
│     - View Grafana: http://localhost:3000                   │
│     - Read report: load_test_results/TIMESTAMP/report.txt   │
│     - Check logs: load_test_results/TIMESTAMP/*.log         │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  7. Cleanup                                                 │
│     $ ./load_test.sh cleanup                                │
│     - Removes test containers                               │
│     - Deletes test queue                                    │
│     $ ./load_test.sh monitor-stop  # Optional               │
│     - Stops monitoring stack                                │
└─────────────────────────────────────────────────────────────┘
```

Happy load testing!
