# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a **RabbitMQ Cluster Setup** for Rocky Linux 8 using Podman. It provides scripts and configurations to deploy a 3-node RabbitMQ cluster with high availability and message durability testing.

## Key Components

### Core Files
- **rmq.sh**: Main cluster management script with commands for prep, up, join, policy, status, down, wipe
- **rmq_ultra_short.sh**: Simplified cluster management script (alternative to rmq.sh)
- **rabbitmq.conf**: RabbitMQ configuration with clustering, quorum queues, and management settings
- **.env.example**: Environment template with all required variables (copy to .env before use)
- **QUICKSTART.md**: Complete step-by-step setup guide

### Test Applications
- **test/producer.py**: Basic persistent message publisher with publisher confirms
- **test/consumer.py**: Basic message consumer with manual acks and throughput reporting
- **test/simple_multiprocess_producer.py**: Multi-process producer for simple load tests (classic queues)
- **test/simple_multiprocess_consumer.py**: Multi-process consumer using basic_consume (push-based)
- **test/load_test_producer.py**: High-performance producer (400 connections, 150K msg/s)
- **test/load_test_consumer.py**: High-performance consumer with batch processing
- **test/Dockerfile**: Python 3 + pika container environment

## Architecture

- **3-node RabbitMQ cluster** using quorum queues with replication factor 3
- **Rootless Podman containers** using official rabbitmq:3.13-management image
- **Classic config peer discovery** with shared Erlang cookie
- **High availability testing** with node failure simulation

## Common Development Tasks

### Cluster Management
```bash
./rmq.sh prep                 # Install Podman, configure firewall
./rmq.sh up rmq1             # Start RabbitMQ node
./rmq.sh join rmq2 rmq1      # Join node to cluster
./rmq.sh policy              # Apply quorum queue policy
./rmq.sh status              # Check cluster status
./rmq.sh down rmq1           # Stop node
./rmq.sh wipe rmq1           # Delete all node data (WARNING: destructive!)
```

### Basic Test Application
```bash
cd test/
podman build -t rabbitmq-test .
podman run --rm --env-file ../.env rabbitmq-test python producer.py
podman run -d --name consumer --env-file ../.env rabbitmq-test python consumer.py
```

### Simple Load Test
```bash
# Edit configuration first (set MESSAGES_PER_SECOND and MESSAGE_SIZE_KB)
nano simple_load_test.conf

# With ADAPTIVE_WORKERS=true (default), just set target rate:
# MESSAGES_PER_SECOND=10000
# System automatically calculates optimal workers and connections!

# Run test (detects alarms, handles queue type mismatches)
chmod +x simple_load_test.sh
./simple_load_test.sh

# View results
cat /tmp/producer.log
cat /tmp/consumer.log

# Test adaptive calculation logic
./test_adaptive_calc.sh
```

## Environment Configuration

Copy `.env.example` to `.env` and configure:
- Server IP addresses (RMQ1_HOST, RMQ2_HOST, RMQ3_HOST, TEST_HOST)
- RabbitMQ credentials (RABBITMQ_ADMIN_USER, RABBITMQ_ADMIN_PASSWORD)
- Shared Erlang cookie (generate with `openssl rand -base64 32`)

## Network Requirements

**Firewall ports**: 5672 (AMQP), 15672 (Management UI), 4369 (EPMD), 25672 (Inter-node)

## Expected Infrastructure

- 4 Rocky Linux 8 servers with SSH access (15GB RAM, 80GB storage each)
- Servers 1-3: RabbitMQ cluster nodes
- Server 4: Test application host
- Network connectivity between all servers

## Load Testing

### Simple Load Test (Recommended for Initial Testing)
Lightweight test using classic queues with automatic health checks:
- **Configuration**: `simple_load_test.conf`
- **Adaptive Worker Mode**: Automatically calculates optimal workers and connections based on target rate
- **Pre-flight checks**: Detects memory/disk alarms before testing
- **Queue type detection**: Automatically handles queue type mismatches
- **Real-time output**: Shows producer/consumer logs as they happen

```bash
# Configure test parameters (with adaptive mode, just set target rate!)
nano simple_load_test.conf
# Set: ADAPTIVE_WORKERS=true, MESSAGES_PER_SECOND=10000, MESSAGE_SIZE_KB=10
# System automatically calculates everything else!

# Run (script guides you through any issues)
./simple_load_test.sh
```

**Adaptive Mode** (ADAPTIVE_WORKERS=true, default):
- Calculates optimal worker count based on available CPU cores
- Determines connections needed based on target message rate
- Adjusts for message size (large messages are network-limited)
- Warns if target exceeds estimated capacity
- Just set MESSAGES_PER_SECOND - no need to manually tune workers/connections!

See `SIMPLE_LOAD_TEST_GUIDE.md` for complete documentation.

### High-Performance Load Test
Comprehensive load test setup for extreme throughput:
- **Capacity**: 150,000 messages/second at 100KB each
- **Duration**: 100-second test (~1.43TB total data)
- **Architecture**: 400 producer connections, 20 consumer workers
- **Monitoring**: Prometheus + Grafana with pre-configured dashboard

```bash
./load_test.sh full          # Complete load test with monitoring
./load_test.sh test-only     # Load test without monitoring setup
./load_test.sh monitor       # Setup monitoring stack only
./load_test.sh cleanup       # Remove monitoring containers
```

### Load Test Components
- **High-performance producer**: `test/load_test_producer.py` (40 processes × 10 connections each)
- **High-performance consumer**: `test/load_test_consumer.py` (batch processing, auto-reconnect)
- **Monitoring stack**: Prometheus + Grafana + exporters (`monitoring/`)
- **Optimized RabbitMQ config**: Enhanced `rabbitmq.conf` for extreme throughput

### Key Optimizations for High-Performance Testing
- Multiple AMQP listeners (ports 5672-5675) for load balancing
- Aggressive memory management (70% of 15GB RAM)
- TCP buffer optimizations for high throughput
- Quorum queues with performance tuning
- Statistics collection disabled during load test

### Monitoring Access
- **Grafana**: http://localhost:3000 (admin/admin123)
- **Prometheus**: http://localhost:9090
- **Load Test Dashboard**: Pre-configured for real-time monitoring

See `LOAD_TEST.md` for complete high-performance load testing documentation.

## Important Architecture Decisions

### Queue Types
- **Quorum Queues**: Used in production cluster (default policy applies to all queues)
  - 3x replication across nodes
  - High durability, survives node failures
  - Configured via policy in `rmq.sh policy`

- **Classic Queues**: Used in simple load test
  - Single-node storage, no replication
  - Higher performance, lower durability
  - Suitable for testing and development

### Container Strategy
- **Rootless Podman containers**: Security-focused approach (no root required)
- **Host networking mode**: Direct port exposure (5672, 15672, 4369, 25672)
- **Persistent storage**: `/var/lib/rabbitmq/{node_name}/` for data persistence
- **Configuration mounting**: `rabbitmq.conf` mounted read-only into containers

### Cluster Discovery
- **Classic config peer discovery**: Nodes specified in `rabbitmq.conf`
- **Shared Erlang cookie**: Required for inter-node authentication (in `.env`)
- **Automatic rejoin**: Nodes automatically rejoin cluster on restart

### Producer Reliability Patterns
- **Publisher confirms**: ALWAYS enable with `channel.confirm_delivery()`
  - Without confirms, Pika buffers messages and may silently drop them
  - Critical fix documented in `DEPLOY_INSTRUCTIONS.md` and `SOLUTION_FOUND.md`
- **Connection blocking detection**: Producers must handle `connection.blocked` events
  - RabbitMQ blocks connections when memory/disk alarms trigger
  - Simple load test demonstrates proper blocking detection and pause behavior

### Adaptive Worker Calculation (Simple Load Test)
- **Performance model**: ~5000 msg/s per connection (empirically determined)
- **Network considerations**: For messages ≥100KB, network bandwidth becomes bottleneck
  - Adjusted to ~400 msg/s per connection for 100KB messages
  - Calculation: 40 MB/s per connection / message_size_KB
- **Worker distribution**: Spreads connections across available CPU cores
  - Auto-detects cores via `/proc/cpuinfo` or `nproc`
  - Respects MAX_WORKERS configuration if set
- **Connection limits**: Caps at 10 connections per worker for stability
  - If more needed, increases worker count instead
- **Capacity warnings**: Alerts if target rate exceeds estimated maximum throughput

## RabbitMQ Python Pika Best Practices

See **`RABBITMQ_DOCUMENTATION.md`** for comprehensive RabbitMQ Python Pika reference including:
- **Message persistence** (persistent messages, durable queues)
- **Consumer patterns** (basic_consume vs basic_get)
- **Performance best practices** (prefetch, batch acknowledgments)
- **Common issues and solutions**

**CRITICAL**: Always use `basic_consume` (push-based) for consumers, NOT `basic_get` (polling). The `basic_get` approach is highly inefficient and discouraged by RabbitMQ official documentation.

**CRITICAL**: Always enable publisher confirms with `channel.confirm_delivery()`. Without this, messages may be silently dropped by the Pika client library.

## Common Troubleshooting Patterns

### Connection Blocked Issues
**Symptoms**: Producer logs show "BLOCKED" warnings, Management UI shows red alarm
**Causes**:
- Memory usage >70% of 15GB (10.5GB threshold)
- Disk space <5GB free
**Solutions**:
1. Reduce producer rate in configuration files
2. Increase memory watermark in `rabbitmq.conf`: `vm_memory_high_watermark.relative = 0.9`
3. Purge queues via Management UI or API
4. Let consumers catch up (queue depth decreases → memory freed)

### Queue Type Mismatch
**Symptoms**: Producer runs but no connections visible in Management UI
**Cause**: Existing queue type doesn't match producer's queue declaration
**Solution**: `simple_load_test.sh` automatically detects and prompts to delete mismatched queues

### Messages Sent But Queue Shows 0
**Normal Scenario**: Consumer is keeping pace with producer (✓ Good!)
**Verify**: Check consumer logs for "Messages received" output
**Problem Scenario**: Connection blocked or queue type mismatch (see above)

### Node Won't Start
**Common causes**:
- Port already in use (check with `netstat -tulpn | grep 5672`)
- Data directory permission errors (fix with `chown -R $(id -u):$(id -g) /var/lib/rabbitmq/rmq1`)
- Corrupted data (use `./rmq.sh wipe rmq1` to delete and restart)

### Cluster Partition
**Symptoms**: `./rmq.sh status` shows nodes not communicating
**Solution**: Stop all nodes, start primary, then join others sequentially

## Documentation Reference

- **QUICKSTART.md**: Initial cluster setup guide
- **CLUSTER_USER_GUIDE.md**: Complete operations and usage guide
- **SIMPLE_LOAD_TEST_GUIDE.md**: Simple load test detailed documentation
- **LOAD_TEST.md**: High-performance load test guide
- **RABBITMQ_DOCUMENTATION.md**: RabbitMQ Python Pika reference
- **DEPLOY_INSTRUCTIONS.md**: Quick deployment and file transfer guide
- **SOLUTION_FOUND.md**: Publisher confirms critical fix documentation