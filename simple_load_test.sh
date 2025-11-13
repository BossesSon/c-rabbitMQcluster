#!/usr/bin/env bash
################################################################################
# SIMPLE RABBITMQ LOAD TEST - Rewritten for simplicity and reliability
################################################################################
#
# This script:
# - Checks RabbitMQ health and detects alarms BEFORE testing
# - Detects and handles queue type mismatches automatically
# - Runs producer and consumer in Docker/Podman containers
# - Shows real-time output (no more missing logs!)
# - Handles errors gracefully with clear messages
#
################################################################################

set -euo pipefail  # Exit on error, undefined variable, or pipe failure

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_header() {
    echo ""
    echo "================================================================================"
    echo "$1"
    echo "================================================================================"
}

################################################################################
# STEP 1: Load configuration
################################################################################

print_header "STEP 1: Loading Configuration"

# Check if config file exists
if [[ ! -f "simple_load_test.conf" ]]; then
    print_error "Configuration file 'simple_load_test.conf' not found!"
    exit 1
fi

# Source the config file
source simple_load_test.conf

print_success "Configuration loaded"
print_info "Target rate: ${MESSAGES_PER_SECOND} msg/s"
print_info "Message size: ${MESSAGE_SIZE_KB} KB"
print_info "Test duration: ${TEST_DURATION_SECONDS}s"
print_info "Queue: ${TEST_QUEUE_NAME}"

################################################################################
# STEP 2: Check prerequisites
################################################################################

print_header "STEP 2: Checking Prerequisites"

# Detect container engine
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    print_success "Found Podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    print_success "Found Docker"
else
    print_error "Neither Docker nor Podman found!"
    print_info "Install Podman: sudo dnf install -y podman"
    exit 1
fi

# Check for curl
if ! command -v curl &> /dev/null; then
    print_error "curl not found (needed for RabbitMQ API)"
    print_info "Install curl: sudo dnf install -y curl"
    exit 1
fi

print_success "All prerequisites satisfied"

################################################################################
# STEP 3: Test RabbitMQ connectivity
################################################################################

print_header "STEP 3: Testing RabbitMQ Connectivity"

MGMT_URL="http://${RMQ1_HOST}:${RABBITMQ_MGMT_PORT}"
API_AUTH="${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}"

print_info "Testing connection to ${RMQ1_HOST}:${RABBITMQ_MGMT_PORT}..."

if ! curl -sf -u "${API_AUTH}" "${MGMT_URL}/api/overview" > /dev/null; then
    print_error "Cannot connect to RabbitMQ Management API!"
    print_info "URL: ${MGMT_URL}"
    print_info "Check that:"
    print_info "  1. RabbitMQ is running: ./rmq.sh status rmq1"
    print_info "  2. Management plugin is enabled"
    print_info "  3. Credentials are correct in simple_load_test.conf"
    print_info "  4. Firewall allows port ${RABBITMQ_MGMT_PORT}"
    exit 1
fi

print_success "Connected to RabbitMQ Management API"

################################################################################
# STEP 4: Check for alarms (memory/disk)
################################################################################

print_header "STEP 4: Checking for RabbitMQ Alarms"

ALARMS=$(curl -sf -u "${API_AUTH}" "${MGMT_URL}/api/health/checks/alarms" || echo "error")

if [[ "$ALARMS" == *"\"status\":\"ok\""* ]]; then
    print_success "No alarms detected - RabbitMQ is healthy"
elif [[ "$ALARMS" == "error" ]]; then
    print_warning "Could not check alarms (API might not be available)"
    print_info "Proceeding anyway..."
else
    print_error "RabbitMQ has ACTIVE ALARMS!"
    print_info "This means connections will be BLOCKED (memory or disk limit exceeded)"
    print_info ""
    print_info "To fix:"
    print_info "  1. Check memory usage in RabbitMQ Management UI"
    print_info "  2. Check disk space: df -h"
    print_info "  3. Increase memory limit in rabbitmq.conf (vm_memory_high_watermark)"
    print_info "  4. Clear old messages/queues"
    print_info ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Aborting. Fix alarms first."
        exit 1
    fi
fi

################################################################################
# STEP 5: Check existing queue
################################################################################

print_header "STEP 5: Checking Existing Queue"

QUEUE_INFO=$(curl -sf -u "${API_AUTH}" "${MGMT_URL}/api/queues/%2F/${TEST_QUEUE_NAME}" 2>/dev/null || echo "")

if [[ -z "$QUEUE_INFO" ]]; then
    print_info "Queue '${TEST_QUEUE_NAME}' does not exist (will be created)"
else
    QUEUE_TYPE=$(echo "$QUEUE_INFO" | grep -o '"type":"[^"]*"' | cut -d'"' -f4 || echo "classic")
    QUEUE_MESSAGES=$(echo "$QUEUE_INFO" | grep -o '"messages":[0-9]*' | cut -d':' -f2 || echo "0")

    print_info "Queue '${TEST_QUEUE_NAME}' already exists"
    print_info "  Type: ${QUEUE_TYPE}"
    print_info "  Messages: ${QUEUE_MESSAGES}"

    if [[ "$QUEUE_TYPE" != "classic" ]]; then
        print_warning "Queue type is '${QUEUE_TYPE}' but scripts expect 'classic'"
        print_warning "This will cause PRECONDITION_FAILED errors!"
        print_info ""
        print_info "Delete queue and recreate as classic? (Recommended)"
        read -p "Delete queue '${TEST_QUEUE_NAME}'? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting queue..."
            if curl -sf -u "${API_AUTH}" -X DELETE "${MGMT_URL}/api/queues/%2F/${TEST_QUEUE_NAME}" > /dev/null; then
                print_success "Queue deleted successfully"
            else
                print_error "Failed to delete queue"
                exit 1
            fi
        else
            print_warning "Proceeding with existing queue (errors likely)"
        fi
    fi

    if [[ "$QUEUE_MESSAGES" -gt 0 ]]; then
        print_info "Queue has ${QUEUE_MESSAGES} existing messages"
        read -p "Purge these messages before test? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Purging queue..."
            curl -sf -u "${API_AUTH}" -X DELETE "${MGMT_URL}/api/queues/%2F/${TEST_QUEUE_NAME}/contents" > /dev/null
            print_success "Queue purged"
        fi
    fi
fi

################################################################################
# STEP 6: Build test container
################################################################################

print_header "STEP 6: Building Test Container"

# Create Dockerfile if it doesn't exist
if [[ ! -f "test/Dockerfile" ]]; then
    print_info "Creating Dockerfile..."
    cat > test/Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir pika
COPY *.py /app/
CMD ["python", "-u", "simple_multiprocess_producer.py"]
EOF
    print_success "Dockerfile created"
fi

print_info "Building container image..."
cd test
${CONTAINER_CMD} build -t rabbitmq-simple-test . > /dev/null 2>&1
cd ..
print_success "Container image built: rabbitmq-simple-test"

################################################################################
# STEP 7: Create environment file
################################################################################

print_header "STEP 7: Preparing Environment"

# Build RABBITMQ_HOSTS from config
RABBITMQ_HOSTS="${RMQ1_HOST},${RMQ2_HOST},${RMQ3_HOST}"

cat > /tmp/simple_load_test.env << EOF
RABBITMQ_HOSTS=${RABBITMQ_HOSTS}
RABBITMQ_PORT=${RABBITMQ_PORT}
RABBITMQ_ADMIN_USER=${RABBITMQ_ADMIN_USER}
RABBITMQ_ADMIN_PASSWORD=${RABBITMQ_ADMIN_PASSWORD}
TEST_QUEUE_NAME=${TEST_QUEUE_NAME}
MESSAGE_SIZE_KB=${MESSAGE_SIZE_KB}
MESSAGES_PER_SECOND=${MESSAGES_PER_SECOND}
TEST_DURATION_SECONDS=${TEST_DURATION_SECONDS}
PRODUCER_WORKERS=${PRODUCER_WORKERS}
PRODUCER_CONNECTIONS_PER_WORKER=${PRODUCER_CONNECTIONS_PER_WORKER}
CONSUMER_WORKERS=${CONSUMER_WORKERS}
CONSUMER_PREFETCH_COUNT=${CONSUMER_PREFETCH_COUNT}
EOF

print_success "Environment file created: /tmp/simple_load_test.env"

################################################################################
# STEP 8: Clean up old containers
################################################################################

print_header "STEP 8: Cleaning Up Old Containers"

for container in simple-producer simple-consumer; do
    if ${CONTAINER_CMD} ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_info "Removing old container: ${container}"
        ${CONTAINER_CMD} rm -f ${container} > /dev/null 2>&1 || true
    fi
done

print_success "Cleanup complete"

################################################################################
# STEP 9: Run the load test
################################################################################

print_header "STEP 9: Running Load Test"

print_info "Starting producer..."
${CONTAINER_CMD} run -d \
    --name simple-producer \
    --env-file /tmp/simple_load_test.env \
    rabbitmq-simple-test \
    python -u simple_multiprocess_producer.py

print_success "Producer started"

sleep 2

print_info "Starting consumer..."
${CONTAINER_CMD} run -d \
    --name simple-consumer \
    --env-file /tmp/simple_load_test.env \
    rabbitmq-simple-test \
    python -u simple_multiprocess_consumer.py

print_success "Consumer started"

print_info ""
print_info "Test will run for ${TEST_DURATION_SECONDS} seconds"
print_info "Showing producer output (press Ctrl+C to stop viewing, test will continue)..."
print_info "================================================================================"
print_info ""

# Show producer logs in real-time (follow mode)
${CONTAINER_CMD} logs -f simple-producer &
LOGS_PID=$!

# Wait for test duration (or user interrupt)
sleep ${TEST_DURATION_SECONDS} || true

# Stop following logs
kill $LOGS_PID 2>/dev/null || true

print_info ""
print_info "================================================================================"
print_info "Test duration complete, waiting for containers to finish..."

# Wait for containers to exit
${CONTAINER_CMD} wait simple-producer simple-consumer > /dev/null 2>&1 || true

################################################################################
# STEP 10: Collect results
################################################################################

print_header "STEP 10: Collecting Results"

print_info "Saving logs..."
${CONTAINER_CMD} logs simple-producer > /tmp/producer.log 2>&1
${CONTAINER_CMD} logs simple-consumer > /tmp/consumer.log 2>&1

print_success "Producer log: /tmp/producer.log"
print_success "Consumer log: /tmp/consumer.log"

print_info ""
print_info "=== CONSUMER OUTPUT ==="
tail -20 /tmp/consumer.log

print_info ""
print_info "=== FINAL QUEUE STATUS ==="
FINAL_QUEUE_INFO=$(curl -sf -u "${API_AUTH}" "${MGMT_URL}/api/queues/%2F/${TEST_QUEUE_NAME}" 2>/dev/null || echo "")
if [[ -n "$FINAL_QUEUE_INFO" ]]; then
    FINAL_MESSAGES=$(echo "$FINAL_QUEUE_INFO" | grep -o '"messages":[0-9]*' | cut -d':' -f2 || echo "0")
    print_info "Messages remaining in queue: ${FINAL_MESSAGES}"
else
    print_warning "Could not fetch queue info"
fi

################################################################################
# CLEANUP
################################################################################

print_header "Cleaning Up"

print_info "Removing containers..."
${CONTAINER_CMD} rm -f simple-producer simple-consumer > /dev/null 2>&1 || true

print_success "Cleanup complete"

print_header "TEST COMPLETE"

print_info "Review full logs:"
print_info "  Producer: /tmp/producer.log"
print_info "  Consumer: /tmp/consumer.log"
print_info ""
print_info "Check RabbitMQ UI: ${MGMT_URL}"
print_info ""

exit 0
