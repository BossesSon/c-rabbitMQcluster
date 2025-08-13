# RabbitMQ High-Performance Load Test Guide

This guide covers running a comprehensive load test targeting **150,000 messages/second** at **100KB per message** for **100 seconds** with full monitoring.

## Test Specifications

- **Target Throughput**: 150,000 messages/second
- **Message Size**: 100KB (102,400 bytes)
- **Test Duration**: 100 seconds
- **Total Messages**: 15,000,000 messages
- **Total Data**: ~1.43 TB
- **Hardware Requirements**: 15GB RAM, 80GB storage per node

## Quick Start

1. **Setup RabbitMQ Cluster** (if not already running):
   ```bash
   ./rmq.sh prep
   ./rmq.sh up rmq1
   ./rmq.sh up rmq2
   ./rmq.sh join rmq2 rmq1
   ./rmq.sh up rmq3
   ./rmq.sh join rmq3 rmq1
   ./rmq.sh policy
   ```

2. **Run Complete Load Test** (recommended):
   ```bash
   ./load_test.sh full
   ```

3. **Monitor Results**:
   - Grafana Dashboard: http://localhost:3000 (admin/admin123)
   - Prometheus Metrics: http://localhost:9090

## Load Test Commands

### Full Load Test (Recommended)
```bash
./load_test.sh full
```
Sets up monitoring, runs the test, and generates a comprehensive report.

### Test Only (No Monitoring)
```bash
./load_test.sh test-only
```
Runs just the load test without setting up monitoring infrastructure.

### Setup Monitoring Only
```bash
./load_test.sh monitor
```
Sets up Prometheus, Grafana, and other monitoring tools.

### Generate Report
```bash
./load_test.sh report
```
Generates a test report from existing log files.

### Cleanup
```bash
./load_test.sh cleanup
```
Stops and removes monitoring containers.

## Configuration

### Environment Variables

Create or modify your `.env` file with these load test specific settings:

```bash
# Load Test Configuration
TARGET_RATE=150000              # Messages per second
MESSAGE_SIZE=102400             # Message size in bytes (100KB)
LOAD_TEST_DURATION=100          # Test duration in seconds
NUM_PRODUCER_WORKERS=8          # Producer processes (typically CPU cores)
NUM_CONSUMER_WORKERS=4          # Consumer processes
PRODUCER_CONNECTIONS=50         # Connections per producer
CONSUMER_CONNECTIONS=20         # Connections per consumer
CHANNELS_PER_CONNECTION=10      # Channels per connection

# RabbitMQ Cluster (same as normal setup)
RMQ1_HOST=192.168.1.101
RMQ2_HOST=192.168.1.102
RMQ3_HOST=192.168.1.103
RABBITMQ_ADMIN_USER=admin
RABBITMQ_ADMIN_PASSWORD=secure_password_123
ERLANG_COOKIE=your-secure-erlang-cookie
```

### RabbitMQ Configuration

The `rabbitmq.conf` has been optimized for high throughput with:

- **Multiple AMQP listeners** (ports 5672-5675) for load balancing
- **Aggressive memory management** (70% of 15GB RAM)
- **TCP optimizations** for high throughput
- **Quorum queue optimizations** for reliability
- **Disabled statistics collection** during load test

Key optimizations:
```conf
# Multiple listeners for load balancing
listeners.tcp.1 = 0.0.0.0:5672
listeners.tcp.2 = 0.0.0.0:5673
listeners.tcp.3 = 0.0.0.0:5674
listeners.tcp.4 = 0.0.0.0:5675

# Aggressive memory management
vm_memory_high_watermark.relative = 0.7
disk_free_limit.absolute = 10GB

# High throughput TCP settings
tcp_listen_options.sndbuf = 1048576
tcp_listen_options.recbuf = 1048576
num_acceptors.tcp = 50

# Disable statistics during load test
collect_statistics = none
```

## Architecture

### Load Test Components

1. **High-Performance Producer** (`test/load_test_producer.py`):
   - Multi-process architecture (8 workers by default)
   - 50 connections per worker across multiple ports
   - 10 channels per connection
   - Batch publishing with publisher confirms
   - Real-time rate limiting and statistics

2. **High-Performance Consumer** (`test/load_test_consumer.py`):
   - Multi-process architecture (4 workers by default)
   - 20 connections per worker
   - Batch acknowledgments for performance
   - Automatic reconnection and error handling
   - Throughput monitoring and reporting

3. **Orchestration Script** (`load_test.sh`):
   - Complete test lifecycle management
   - System optimization (file descriptors, TCP settings)
   - Monitoring setup and teardown
   - Report generation

### Monitoring Stack

- **Prometheus**: Metrics collection and storage
- **Grafana**: Real-time dashboards and visualization
- **Node Exporter**: System metrics (CPU, memory, disk, network)
- **RabbitMQ Exporter**: Detailed RabbitMQ metrics
- **cAdvisor**: Container resource monitoring

## Expected Performance

### Target Metrics
- **Message Rate**: 150,000 messages/second
- **Data Throughput**: ~14.3 GB/second
- **Network Throughput**: ~114 Gbps (theoretical)
- **Total Test Data**: ~1.43 TB

### Resource Utilization (Per Node)
- **Memory Usage**: 8-12 GB (out of 15 GB)
- **CPU Usage**: 60-80% during peak load
- **Network I/O**: High sustained throughput
- **Disk I/O**: Moderate (primarily for persistence)

## Monitoring and Dashboards

### Grafana Dashboard Panels

1. **Message Throughput**: Real-time publish/consume rates
2. **Queue Metrics**: Queue lengths, unacked messages
3. **System Resources**: Memory, CPU, disk I/O
4. **Network I/O**: Bandwidth utilization
5. **RabbitMQ Internals**: Connections, channels, errors
6. **Error Rates**: Failed, returned, redelivered messages

### Key Metrics to Watch

- **Publish Rate**: Should maintain 150K msg/s
- **Consume Rate**: Should match publish rate closely
- **Queue Length**: Should remain relatively stable
- **Memory Usage**: Should stay below 70% threshold
- **Error Rates**: Should remain near zero
- **Network Throughput**: Should show high sustained I/O

## Troubleshooting

### Performance Issues

1. **Low Message Rate**:
   ```bash
   # Check system resources
   top
   iostat -x 1
   
   # Check RabbitMQ status
   ./rmq.sh status
   
   # Check network connectivity
   ./rmq.sh test-network
   ```

2. **High Memory Usage**:
   ```bash
   # Check RabbitMQ memory usage
   podman exec rabbitmq-rmq1 rabbitmqctl status
   
   # Reduce queue lengths if needed
   # Consider increasing consumer workers
   ```

3. **Network Bottlenecks**:
   ```bash
   # Check network interface utilization
   iftop
   
   # Monitor packet drops
   netstat -i
   ```

### Common Issues

1. **Connection Failures**:
   - Check firewall ports: 5672-5675, 15672, 4369, 25672
   - Verify RabbitMQ cluster is running
   - Check file descriptor limits: `ulimit -n`

2. **Queue Buildup**:
   - Increase consumer workers: `NUM_CONSUMER_WORKERS=8`
   - Increase prefetch count: `PREFETCH_COUNT=2000`
   - Check consumer processing delays

3. **Memory Pressure**:
   - Monitor Grafana memory dashboard
   - Check for queue growth
   - Verify quorum queue configuration

### Log Files

- **Producer Logs**: `test/producer.log`
- **Consumer Logs**: `test/consumer.log`
- **RabbitMQ Logs**: `podman logs rabbitmq-rmq1`
- **Load Test Report**: `load_test_report_YYYYMMDD_HHMMSS.txt`

## Performance Tuning

### System Level

1. **File Descriptor Limits**:
   ```bash
   # Temporary
   ulimit -n 65536
   
   # Permanent (add to /etc/security/limits.conf)
   * soft nofile 65536
   * hard nofile 65536
   ```

2. **TCP Buffer Sizes**:
   ```bash
   # Applied automatically by load_test.sh
   sudo sysctl -w net.core.rmem_max=16777216
   sudo sysctl -w net.core.wmem_max=16777216
   ```

### Application Level

1. **Increase Producer Workers**:
   ```bash
   export NUM_PRODUCER_WORKERS=12
   ```

2. **Optimize Connection Distribution**:
   ```bash
   export PRODUCER_CONNECTIONS=100
   export CHANNELS_PER_CONNECTION=5
   ```

3. **Batch Size Tuning**:
   ```bash
   export BATCH_SIZE=200
   export BATCH_ACK_SIZE=200
   ```

## Security Considerations

- **Network Security**: Ensure firewall rules are properly configured
- **Authentication**: Use strong passwords for RabbitMQ admin user
- **Monitoring Access**: Restrict access to Grafana/Prometheus in production
- **Resource Limits**: Monitor system resources to prevent DoS conditions

## Post-Test Analysis

### Performance Report

After the test completes, check:

1. **Test Summary**: Generated report file
2. **Grafana Dashboards**: Historical performance data
3. **Log Analysis**: Detailed producer/consumer statistics
4. **System Impact**: Resource utilization patterns

### Cleanup

1. **Stop Monitoring**:
   ```bash
   ./load_test.sh cleanup
   ```

2. **Clean Test Data** (optional):
   ```bash
   # Clear all queues
   ./rmq.sh down rmq1
   ./rmq.sh down rmq2  
   ./rmq.sh down rmq3
   ./rmq.sh wipe rmq1
   ./rmq.sh wipe rmq2
   ./rmq.sh wipe rmq3
   ```

## Advanced Configuration

### Custom Load Patterns

Modify the producer to create different load patterns:

```python
# Ramp up load gradually
# Burst patterns
# Variable message sizes
# Different queue distributions
```

### Multi-Node Testing

For testing across multiple physical machines:

1. Deploy producers on separate test machines
2. Coordinate timing across nodes
3. Aggregate metrics collection
4. Network latency considerations

## Best Practices

1. **Pre-Test Validation**:
   - Verify cluster health before testing
   - Check resource availability
   - Confirm monitoring setup

2. **During Test**:
   - Monitor all key metrics continuously
   - Be prepared to stop test if issues arise
   - Document any anomalies observed

3. **Post-Test**:
   - Generate comprehensive reports
   - Analyze performance bottlenecks
   - Plan optimizations for next iteration

This load test represents an extreme performance scenario. Actual results will depend on hardware specifications, network configuration, and system tuning.