#!/bin/bash

################################################################################
# SIMPLE LOAD TEST FOR RABBITMQ CLUSTER
################################################################################
#
# PURPOSE:
#   This script runs a high-performance load test on your RabbitMQ cluster
#   and provides comprehensive statistics about producer/consumer capacity.
#
# FOR BEGINNERS:
#   - This is a bash script (a file containing Linux commands)
#   - Lines starting with # are comments (explanations)
#   - The script does everything automatically
#   - You just need to run: ./simple_load_test.sh
#
# WHAT IT DOES:
#   1. Checks that you have required software (Docker/Podman, Python)
#   2. Reads your configuration from simple_load_test.conf
#   3. Validates connection to RabbitMQ
#   4. Builds a Docker container with the test programs
#   5. Runs producer and consumer in parallel
#   6. Collects detailed statistics every few seconds
#   7. Shows comprehensive final report
#
################################################################################

# Exit immediately if any command fails (safety feature)
set -e

# Color codes for pretty output (optional, makes it easier to read)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# HELPER FUNCTIONS
################################################################################

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "================================================================================"
    echo "$1"
    echo "================================================================================"
}

################################################################################
# STEP 1: CHECK PREREQUISITES
################################################################################

check_prerequisites() {
    print_header "STEP 1: Checking Prerequisites"

    # Check if running on Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        print_warning "This script is designed for Linux. You're running: $OSTYPE"
    fi

    # Check for Docker or Podman
    print_info "Checking for Docker or Podman..."
    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
        print_success "Found Podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        print_success "Found Docker"
    else
        print_error "Neither Docker nor Podman found!"
        print_info "Installing Podman..."
        sudo dnf install -y podman
        CONTAINER_CMD="podman"
    fi

    # Check for curl (used to call RabbitMQ API)
    if ! command -v curl &> /dev/null; then
        print_error "curl not found!"
        print_info "Installing curl..."
        sudo dnf install -y curl
    fi

    print_success "All prerequisites satisfied"
}

################################################################################
# STEP 2: LOAD CONFIGURATION
################################################################################

load_configuration() {
    print_header "STEP 2: Loading Configuration"

    # Check if config file exists
    if [[ ! -f "simple_load_test.conf" ]]; then
        print_error "Configuration file 'simple_load_test.conf' not found!"
        print_info "Please create it first. See SIMPLE_LOAD_TEST_GUIDE.md for help."
        exit 1
    fi

    # Load configuration (source the file to import all variables)
    print_info "Reading simple_load_test.conf..."
    source simple_load_test.conf

    # Display configuration
    print_success "Configuration loaded:"
    echo "  Target Rate:        ${MESSAGES_PER_SECOND} messages/second"
    echo "  Message Size:       ${MESSAGE_SIZE_KB} KB"
    echo "  Test Duration:      ${TEST_DURATION_SECONDS} seconds"
    echo "  Producer Workers:   ${PRODUCER_WORKERS}"
    echo "  Consumer Workers:   ${CONSUMER_WORKERS}"
    echo "  RabbitMQ Nodes:     ${RMQ1_HOST}, ${RMQ2_HOST}, ${RMQ3_HOST}"
    echo "  Queue Name:         ${TEST_QUEUE_NAME}"
}

################################################################################
# STEP 3: VALIDATE RABBITMQ CONNECTIVITY
################################################################################

validate_rabbitmq() {
    print_header "STEP 3: Validating RabbitMQ Connectivity"

    # Test connection to each RabbitMQ node
    RABBITMQ_AVAILABLE=false

    for host in "${RMQ1_HOST}" "${RMQ2_HOST}" "${RMQ3_HOST}"; do
        print_info "Testing connection to ${host}:${RABBITMQ_MGMT_PORT}..."

        # Try to reach RabbitMQ Management API
        if curl -s -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}" \
           "http://${host}:${RABBITMQ_MGMT_PORT}/api/overview" > /dev/null 2>&1; then
            print_success "Connected to ${host}"
            RABBITMQ_AVAILABLE=true
        else
            print_warning "Could not connect to ${host}"
        fi
    done

    if [[ "${RABBITMQ_AVAILABLE}" == "false" ]]; then
        print_error "Could not connect to any RabbitMQ node!"
        print_info "Please check:"
        print_info "  1. RabbitMQ is running on the nodes"
        print_info "  2. IP addresses in simple_load_test.conf are correct"
        print_info "  3. Firewall allows connections on ports ${RABBITMQ_PORT} and ${RABBITMQ_MGMT_PORT}"
        print_info "  4. Username and password are correct"
        exit 1
    fi

    print_success "RabbitMQ connectivity validated"
}

################################################################################
# STEP 4: BUILD TEST CONTAINER
################################################################################

build_container() {
    print_header "STEP 4: Building Test Container"

    # Check if Dockerfile exists
    if [[ ! -f "test/Dockerfile" ]]; then
        print_error "test/Dockerfile not found!"
        exit 1
    fi

    # Build the container image
    print_info "Building container image (this may take a minute)..."

    cd test
    ${CONTAINER_CMD} build -t rabbitmq-simple-test . || {
        print_error "Failed to build container!"
        exit 1
    }
    cd ..

    print_success "Container image built successfully"
}

################################################################################
# STEP 5: PREPARE ENVIRONMENT
################################################################################

prepare_environment() {
    print_header "STEP 5: Preparing Test Environment"

    # Create environment file for containers
    # This passes configuration to the Python scripts
    cat > /tmp/simple_load_test.env <<EOF
RABBITMQ_HOSTS=${RMQ1_HOST},${RMQ2_HOST},${RMQ3_HOST}
RABBITMQ_PORT=${RABBITMQ_PORT}
RABBITMQ_ADMIN_USER=${RABBITMQ_ADMIN_USER}
RABBITMQ_ADMIN_PASSWORD=${RABBITMQ_ADMIN_PASSWORD}
TEST_QUEUE_NAME=${TEST_QUEUE_NAME}
MESSAGE_SIZE_KB=${MESSAGE_SIZE_KB}
MESSAGES_PER_SECOND=${MESSAGES_PER_SECOND}
TEST_DURATION_SECONDS=${TEST_DURATION_SECONDS}
PRODUCER_WORKERS=${PRODUCER_WORKERS}
CONSUMER_WORKERS=${CONSUMER_WORKERS}
PRODUCER_CONNECTIONS_PER_WORKER=${PRODUCER_CONNECTIONS_PER_WORKER}
CONSUMER_CONNECTIONS_PER_WORKER=${CONSUMER_CONNECTIONS_PER_WORKER}
CONSUMER_PREFETCH_COUNT=${CONSUMER_PREFETCH_COUNT}
EOF

    print_success "Environment prepared"
}

################################################################################
# STEP 6: GET INITIAL QUEUE STATS
################################################################################

get_queue_stats() {
    # Query RabbitMQ API for queue statistics
    # Returns: message_count,messages_ready,messages_unacknowledged
    local host=$1

    local response=$(curl -s -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}" \
        "http://${host}:${RABBITMQ_MGMT_PORT}/api/queues/%2F/${TEST_QUEUE_NAME}")

    if [[ -z "$response" ]]; then
        echo "0,0,0"
        return
    fi

    # Parse JSON response (simple extraction, works if jq not available)
    local messages=$(echo "$response" | grep -o '"messages":[0-9]*' | head -1 | cut -d':' -f2)
    local ready=$(echo "$response" | grep -o '"messages_ready":[0-9]*' | head -1 | cut -d':' -f2)
    local unacked=$(echo "$response" | grep -o '"messages_unacknowledged":[0-9]*' | head -1 | cut -d':' -f2)

    # Handle empty responses
    messages=${messages:-0}
    ready=${ready:-0}
    unacked=${unacked:-0}

    echo "${messages},${ready},${unacked}"
}

################################################################################
# STEP 7: RUN LOAD TEST
################################################################################

run_load_test() {
    print_header "STEP 7: Running Load Test"

    # Calculate expected totals
    local expected_messages=$((MESSAGES_PER_SECOND * TEST_DURATION_SECONDS))
    local expected_data_mb=$((expected_messages * MESSAGE_SIZE_KB / 1024))

    print_info "Test will send approximately:"
    echo "  Messages: ${expected_messages}"
    echo "  Data:     ${expected_data_mb} MB"
    echo ""

    # Get initial queue depth
    print_info "Getting initial queue depth..."
    local initial_stats=$(get_queue_stats "${RMQ1_HOST}")
    local initial_depth=$(echo "$initial_stats" | cut -d',' -f1)
    print_info "Initial queue depth: ${initial_depth} messages"

    # Start timestamp
    local start_time=$(date +%s)

    print_info "Starting producer..."
    ${CONTAINER_CMD} run -d \
        --name simple-producer \
        --env-file /tmp/simple_load_test.env \
        -e PYTHONUNBUFFERED=1 \
        rabbitmq-simple-test \
        python -u simple_multiprocess_producer.py > /tmp/producer.log 2>&1

    sleep 2  # Give producer time to start

    print_info "Starting consumer..."
    ${CONTAINER_CMD} run -d \
        --name simple-consumer \
        --env-file /tmp/simple_load_test.env \
        -e PYTHONUNBUFFERED=1 \
        rabbitmq-simple-test \
        python -u simple_multiprocess_consumer.py > /tmp/consumer.log 2>&1

    print_success "Producer and consumer started"
    print_info "Test will run for ${TEST_DURATION_SECONDS} seconds..."
    print_info "Monitoring progress (updates every ${REPORT_INTERVAL_SECONDS} seconds)..."
    echo ""

    # Monitor progress
    local last_messages=0
    local last_time=$start_time
    local max_queue_depth=0

    for ((i=0; i<${TEST_DURATION_SECONDS}; i+=${REPORT_INTERVAL_SECONDS})); do
        sleep ${REPORT_INTERVAL_SECONDS}

        # Get current queue stats
        local current_stats=$(get_queue_stats "${RMQ1_HOST}")
        local current_depth=$(echo "$current_stats" | cut -d',' -f1)

        # Track max queue depth
        if [[ $current_depth -gt $max_queue_depth ]]; then
            max_queue_depth=$current_depth
        fi

        # Calculate throughput since last check
        local current_time=$(date +%s)
        local elapsed=$((current_time - last_time))
        local messages_diff=$((current_depth - last_messages))
        local msg_per_sec=$((messages_diff / elapsed))

        # Display progress
        local elapsed_total=$((current_time - start_time))
        echo "  [${elapsed_total}s] Queue depth: ${current_depth} messages (max: ${max_queue_depth})"

        last_messages=$current_depth
        last_time=$current_time
    done

    print_info "Test duration complete, waiting for containers to finish..."

    # Wait for containers to finish (with timeout)
    ${CONTAINER_CMD} wait simple-producer --timeout=${TEST_DURATION_SECONDS} || true
    ${CONTAINER_CMD} wait simple-consumer --timeout=${TEST_DURATION_SECONDS} || true

    # Get final queue depth
    sleep 2
    local final_stats=$(get_queue_stats "${RMQ1_HOST}")
    local final_depth=$(echo "$final_stats" | cut -d',' -f1)

    print_success "Load test completed"

    # Collect logs
    print_info "Collecting results..."
    ${CONTAINER_CMD} logs simple-producer > /tmp/producer_full.log 2>&1
    ${CONTAINER_CMD} logs simple-consumer > /tmp/consumer_full.log 2>&1

    # Parse producer logs for statistics
    local producer_messages=$(grep -o "Worker [0-9]* Finished: [0-9]* messages" /tmp/producer_full.log | \
        grep -o "[0-9]* messages" | grep -o "[0-9]*" | awk '{sum+=$1} END {print sum}')
    producer_messages=${producer_messages:-0}

    # Parse consumer logs for statistics
    local consumer_messages=$(grep -o "Worker [0-9]* Finished: [0-9]* messages" /tmp/consumer_full.log | \
        grep -o "[0-9]* messages" | grep -o "[0-9]*" | awk '{sum+=$1} END {print sum}')
    consumer_messages=${consumer_messages:-0}

    # Calculate actual duration
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))

    # Store results for final report
    PRODUCER_MESSAGES=$producer_messages
    CONSUMER_MESSAGES=$consumer_messages
    ACTUAL_DURATION=$actual_duration
    INITIAL_QUEUE_DEPTH=$initial_depth
    FINAL_QUEUE_DEPTH=$final_depth
    MAX_QUEUE_DEPTH=$max_queue_depth
}

################################################################################
# STEP 8: CLEANUP
################################################################################

cleanup() {
    print_header "STEP 8: Cleaning Up"

    print_info "Stopping and removing containers..."
    ${CONTAINER_CMD} stop simple-producer simple-consumer 2>/dev/null || true
    ${CONTAINER_CMD} rm simple-producer simple-consumer 2>/dev/null || true

    print_success "Cleanup complete"
}

################################################################################
# STEP 9: GENERATE COMPREHENSIVE REPORT
################################################################################

generate_report() {
    print_header "COMPREHENSIVE LOAD TEST REPORT"

    echo ""
    echo "================================================================================"
    echo "TEST CONFIGURATION"
    echo "================================================================================"
    echo "Target Rate:              ${MESSAGES_PER_SECOND} msg/s"
    echo "Message Size:             ${MESSAGE_SIZE_KB} KB"
    echo "Configured Duration:      ${TEST_DURATION_SECONDS} seconds"
    echo "Actual Duration:          ${ACTUAL_DURATION} seconds"
    echo "Producer Workers:         ${PRODUCER_WORKERS}"
    echo "Consumer Workers:         ${CONSUMER_WORKERS}"
    echo "Total Connections:        $((PRODUCER_WORKERS * PRODUCER_CONNECTIONS_PER_WORKER + CONSUMER_WORKERS * CONSUMER_CONNECTIONS_PER_WORKER))"
    echo ""

    echo "================================================================================"
    echo "PRODUCER PERFORMANCE (PUSH CAPACITY)"
    echo "================================================================================"
    local producer_msg_per_sec=$((PRODUCER_MESSAGES / ACTUAL_DURATION))
    local producer_mb_per_sec=$((producer_msg_per_sec * MESSAGE_SIZE_KB / 1024))
    local producer_pct=$((producer_msg_per_sec * 100 / MESSAGES_PER_SECOND))

    printf "Total Messages Sent:      %'d messages\n" $PRODUCER_MESSAGES
    echo "Throughput:               ${producer_msg_per_sec} msg/s"
    echo "Data Rate:                ${producer_mb_per_sec} MB/s"
    echo "Target Achievement:       ${producer_pct}%"

    if [[ $producer_msg_per_sec -ge $MESSAGES_PER_SECOND ]]; then
        echo "Status:                   ✓ TARGET ACHIEVED"
    elif [[ $producer_pct -ge 90 ]]; then
        echo "Status:                   ⚠ CLOSE TO TARGET (${producer_pct}%)"
    else
        echo "Status:                   ✗ BELOW TARGET (${producer_pct}%)"
    fi
    echo ""

    echo "================================================================================"
    echo "CONSUMER PERFORMANCE (POP CAPACITY)"
    echo "================================================================================"
    local consumer_msg_per_sec=$((CONSUMER_MESSAGES / ACTUAL_DURATION))
    local consumer_mb_per_sec=$((consumer_msg_per_sec * MESSAGE_SIZE_KB / 1024))

    printf "Total Messages Received:  %'d messages\n" $CONSUMER_MESSAGES
    echo "Throughput:               ${consumer_msg_per_sec} msg/s"
    echo "Data Rate:                ${consumer_mb_per_sec} MB/s"

    # Calculate if consumer kept up with producer
    local consumer_producer_ratio=$((CONSUMER_MESSAGES * 100 / (PRODUCER_MESSAGES + 1)))

    if [[ $consumer_producer_ratio -ge 95 ]]; then
        echo "Status:                   ✓ KEEPING UP WITH PRODUCER"
    elif [[ $consumer_producer_ratio -ge 80 ]]; then
        echo "Status:                   ⚠ FALLING SLIGHTLY BEHIND"
    else
        echo "Status:                   ✗ FALLING BEHIND"
    fi
    echo ""

    echo "================================================================================"
    echo "QUEUE ANALYSIS"
    echo "================================================================================"
    printf "Initial Queue Depth:      %'d messages\n" $INITIAL_QUEUE_DEPTH
    printf "Maximum Queue Depth:      %'d messages\n" $MAX_QUEUE_DEPTH
    printf "Final Queue Depth:        %'d messages\n" $FINAL_QUEUE_DEPTH
    local queue_growth=$((FINAL_QUEUE_DEPTH - INITIAL_QUEUE_DEPTH))
    printf "Net Queue Growth:         %'d messages\n" $queue_growth

    if [[ $queue_growth -le 1000 ]]; then
        echo "Status:                   ✓ QUEUE STABLE (consumer keeping pace)"
    elif [[ $queue_growth -le 10000 ]]; then
        echo "Status:                   ⚠ QUEUE GROWING SLOWLY"
    else
        echo "Status:                   ✗ QUEUE GROWING RAPIDLY"
    fi
    echo ""

    echo "================================================================================"
    echo "BOTTLENECK ANALYSIS"
    echo "================================================================================"

    # Determine bottleneck
    if [[ $producer_msg_per_sec -lt $((MESSAGES_PER_SECOND * 95 / 100)) ]]; then
        echo "⚠ Producer did not achieve target rate"
        echo "  Recommendation: Increase PRODUCER_WORKERS or PRODUCER_CONNECTIONS_PER_WORKER"
    else
        echo "✓ Producer achieved target rate"
    fi

    if [[ $consumer_msg_per_sec -lt $producer_msg_per_sec ]]; then
        echo "⚠ Consumer slower than producer"
        echo "  Recommendation: Increase CONSUMER_WORKERS or CONSUMER_CONNECTIONS_PER_WORKER"
    else
        echo "✓ Consumer keeping up with producer"
    fi

    if [[ $MAX_QUEUE_DEPTH -gt 100000 ]]; then
        echo "⚠ High queue depth indicates RabbitMQ under stress"
        echo "  Recommendation: Check RabbitMQ cluster resources (CPU, memory, disk)"
    else
        echo "✓ Queue depth manageable"
    fi

    echo ""
    echo "================================================================================"
    echo "CONCLUSION"
    echo "================================================================================"

    if [[ $producer_pct -ge 95 ]] && [[ $consumer_producer_ratio -ge 95 ]] && [[ $queue_growth -le 10000 ]]; then
        echo "✓ System handled this load successfully!"
        echo ""
        echo "Next steps:"
        echo "  1. Try increasing MESSAGES_PER_SECOND in simple_load_test.conf"
        echo "  2. Re-run the test to find the maximum capacity"
    else
        echo "⚠ System struggled with this load"
        echo ""
        echo "Recommendations:"
        if [[ $producer_pct -lt 95 ]]; then
            echo "  - Increase PRODUCER_WORKERS (use more CPU cores)"
        fi
        if [[ $consumer_producer_ratio -lt 95 ]]; then
            echo "  - Increase CONSUMER_WORKERS (use more CPU cores)"
        fi
        if [[ $queue_growth -gt 10000 ]]; then
            echo "  - Check RabbitMQ cluster health and resources"
        fi
    fi

    echo ""
    echo "================================================================================"
    echo "Full logs available at:"
    echo "  Producer: /tmp/producer_full.log"
    echo "  Consumer: /tmp/consumer_full.log"
    echo "================================================================================"
    echo ""
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    print_header "SIMPLE RABBITMQ LOAD TEST - STARTING"

    # Trap cleanup on exit
    trap cleanup EXIT

    # Run all steps
    check_prerequisites
    load_configuration
    validate_rabbitmq
    build_container
    prepare_environment
    run_load_test
    cleanup
    generate_report

    print_success "LOAD TEST COMPLETE!"
}

# Run main function
main
