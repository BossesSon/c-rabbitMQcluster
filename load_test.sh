#!/bin/bash
# RabbitMQ Cluster Load Test Script
# Simplified single-script solution for load testing RabbitMQ clusters

set -e

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default files
ENV_FILE=".env"
PARAMS_FILE="load_test_params.env"
PROMETHEUS_TEMPLATE="monitoring/prometheus.yml.template"
PROMETHEUS_CONFIG="monitoring/prometheus.yml"
DOCKER_COMPOSE_FILE="monitoring/docker-compose.yml"
TEST_DOCKERFILE="test/Dockerfile"
RESULTS_DIR="load_test_results"

# Container/image names
TEST_IMAGE="rabbitmq-load-test"
PRODUCER_CONTAINER_PREFIX="load-test-producer"
CONSUMER_CONTAINER_PREFIX="load-test-consumer"

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_file_exists() {
    if [ ! -f "$1" ]; then
        log_error "Required file not found: $1"
        return 1
    fi
    return 0
}

load_env_files() {
    log_info "Loading configuration files..."

    if ! check_file_exists "$ENV_FILE"; then
        log_error "Please copy .env.example to .env and configure it"
        exit 1
    fi

    # Source .env file
    set -a
    source "$ENV_FILE"
    set +a

    # Source params file if it exists
    if [ -f "$PARAMS_FILE" ]; then
        set -a
        source "$PARAMS_FILE"
        set +a
        log_success "Loaded $ENV_FILE and $PARAMS_FILE"
    else
        log_warning "$PARAMS_FILE not found - using defaults"
        log_success "Loaded $ENV_FILE"
    fi
}

# ============================================================================
# Configuration Generation
# ============================================================================

generate_prometheus_config() {
    log_info "Generating Prometheus configuration from template..."

    if ! check_file_exists "$PROMETHEUS_TEMPLATE"; then
        log_error "Prometheus template not found: $PROMETHEUS_TEMPLATE"
        return 1
    fi

    # Replace template variables with actual values from .env
    sed -e "s/{{RMQ1_HOST}}/${RMQ1_HOST}/g" \
        -e "s/{{RMQ2_HOST}}/${RMQ2_HOST}/g" \
        -e "s/{{RMQ3_HOST}}/${RMQ3_HOST}/g" \
        -e "s/{{TEST_HOST}}/${TEST_HOST}/g" \
        -e "s/{{RABBITMQ_ADMIN_USER}}/${RABBITMQ_ADMIN_USER}/g" \
        -e "s/{{RABBITMQ_ADMIN_PASSWORD}}/${RABBITMQ_ADMIN_PASSWORD}/g" \
        "$PROMETHEUS_TEMPLATE" > "$PROMETHEUS_CONFIG"

    log_success "Generated $PROMETHEUS_CONFIG"
    return 0
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_env_file() {
    log_info "Validating .env configuration..."

    local required_vars=(
        "RMQ1_HOST" "RMQ2_HOST" "RMQ3_HOST" "TEST_HOST"
        "RABBITMQ_ADMIN_USER" "RABBITMQ_ADMIN_PASSWORD"
        "RABBITMQ_ERLANG_COOKIE"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        return 1
    fi

    log_success "Environment configuration is valid"
    return 0
}

validate_params_file() {
    log_info "Validating load test parameters..."

    if [ ! -f "$PARAMS_FILE" ]; then
        log_warning "$PARAMS_FILE not found - will use defaults"
        return 0
    fi

    # Check for critical parameters
    local params_ok=true

    if [ -z "$MESSAGE_SIZE_BYTES" ] || [ "$MESSAGE_SIZE_BYTES" -le 0 ]; then
        log_warning "MESSAGE_SIZE_BYTES not set or invalid, using default: 102400"
        export MESSAGE_SIZE_BYTES=102400
    fi

    if [ -z "$MESSAGES_PER_SECOND" ] || [ "$MESSAGES_PER_SECOND" -le 0 ]; then
        log_warning "MESSAGES_PER_SECOND not set or invalid, using default: 10000"
        export MESSAGES_PER_SECOND=10000
    fi

    if [ -z "$TEST_DURATION_SECONDS" ] || [ "$TEST_DURATION_SECONDS" -le 0 ]; then
        log_warning "TEST_DURATION_SECONDS not set or invalid, using default: 60"
        export TEST_DURATION_SECONDS=60
    fi

    # Calculate expected data volume
    local total_messages=$((MESSAGES_PER_SECOND * TEST_DURATION_SECONDS))
    local total_bytes=$((total_messages * MESSAGE_SIZE_BYTES))
    local total_gb=$((total_bytes / 1073741824))

    log_success "Load test parameters validated:"
    echo "  - Message size: $MESSAGE_SIZE_BYTES bytes"
    echo "  - Rate: $MESSAGES_PER_SECOND msg/s"
    echo "  - Duration: $TEST_DURATION_SECONDS seconds"
    echo "  - Total messages: $total_messages"
    echo "  - Total data: ~${total_gb} GB"

    return 0
}

check_rabbitmq_node() {
    local host=$1
    local user=$2
    local pass=$3

    if curl -s -u "$user:$pass" "http://$host:15672/api/overview" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

validate_rabbitmq_cluster() {
    log_info "Validating RabbitMQ cluster..."

    local nodes=("$RMQ1_HOST" "$RMQ2_HOST" "$RMQ3_HOST")
    local failed_nodes=()

    for node in "${nodes[@]}"; do
        if ! check_rabbitmq_node "$node" "$RABBITMQ_ADMIN_USER" "$RABBITMQ_ADMIN_PASSWORD"; then
            failed_nodes+=("$node")
        fi
    done

    if [ ${#failed_nodes[@]} -gt 0 ]; then
        log_error "Cannot reach RabbitMQ nodes:"
        for node in "${failed_nodes[@]}"; do
            echo "  - $node:15672"
        done
        log_error "Make sure RabbitMQ cluster is running (./rmq.sh status)"
        return 1
    fi

    # Check cluster status
    local cluster_info=$(curl -s -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASSWORD" \
        "http://${RMQ1_HOST}:15672/api/nodes")
    local node_count=$(echo "$cluster_info" | grep -o '"name"' | wc -l)

    if [ "$node_count" -lt 3 ]; then
        log_warning "Expected 3 nodes in cluster, found $node_count"
        log_warning "Cluster may not be fully formed"
    else
        log_success "RabbitMQ cluster is healthy (3 nodes running)"
    fi

    return 0
}

check_exporter() {
    local host=$1
    local port=$2
    local name=$3

    if curl -s "http://$host:$port/metrics" > /dev/null 2>&1; then
        log_success "  $name is accessible at $host:$port"
        return 0
    else
        log_warning "  $name is NOT accessible at $host:$port"
        return 1
    fi
}

validate_exporters() {
    log_info "Validating monitoring exporters (manual prerequisites)..."

    local exporters_ok=true

    # Check node exporters on RabbitMQ nodes
    if ! check_exporter "$RMQ1_HOST" "9100" "Node Exporter (rmq1)"; then
        exporters_ok=false
    fi
    if ! check_exporter "$RMQ2_HOST" "9100" "Node Exporter (rmq2)"; then
        exporters_ok=false
    fi
    if ! check_exporter "$RMQ3_HOST" "9100" "Node Exporter (rmq3)"; then
        exporters_ok=false
    fi

    # Check node exporter on test host (optional)
    check_exporter "$TEST_HOST" "9100" "Node Exporter (test host)" || true

    if [ "$exporters_ok" = false ]; then
        log_warning "Some exporters are not accessible"
        log_warning "Monitoring data will be incomplete"
        log_warning "See LOAD_TEST.md for exporter installation instructions"
    else
        log_success "All required exporters are accessible"
    fi

    return 0
}

validate_dependencies() {
    log_info "Validating system dependencies..."

    local deps_ok=true

    # Check for required commands
    if ! command -v podman &> /dev/null && ! command -v docker &> /dev/null; then
        log_error "Neither podman nor docker found - please install one"
        deps_ok=false
    else
        if command -v podman &> /dev/null; then
            log_success "  podman found"
            export CONTAINER_CMD="podman"
        else
            log_success "  docker found"
            export CONTAINER_CMD="docker"
        fi
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl not found - please install curl"
        deps_ok=false
    else
        log_success "  curl found"
    fi

    if [ "$deps_ok" = false ]; then
        return 1
    fi

    log_success "All dependencies satisfied"
    return 0
}

# ============================================================================
# Preparation Functions
# ============================================================================

build_test_container() {
    log_info "Building test container image..."

    if ! check_file_exists "$TEST_DOCKERFILE"; then
        log_error "Dockerfile not found: $TEST_DOCKERFILE"
        return 1
    fi

    cd test/
    if $CONTAINER_CMD build -t "$TEST_IMAGE" .; then
        log_success "Built container image: $TEST_IMAGE"
        cd ..
        return 0
    else
        log_error "Failed to build container image"
        cd ..
        return 1
    fi
}

prepare_results_directory() {
    log_info "Preparing results directory..."

    local timestamp=$(date +%Y%m%d_%H%M%S)
    export CURRENT_RESULTS_DIR="${RESULTS_DIR}/${timestamp}"

    mkdir -p "$CURRENT_RESULTS_DIR"
    log_success "Results will be saved to: $CURRENT_RESULTS_DIR"

    return 0
}

# ============================================================================
# Monitoring Functions
# ============================================================================

start_monitoring() {
    log_info "Starting monitoring stack..."

    cd monitoring/

    # Use docker-compose or podman-compose
    if command -v podman-compose &> /dev/null; then
        COMPOSE_CMD="podman-compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    elif $CONTAINER_CMD compose version &> /dev/null; then
        COMPOSE_CMD="$CONTAINER_CMD compose"
    else
        log_error "No compose command found (docker-compose, podman-compose, or docker/podman compose)"
        cd ..
        return 1
    fi

    if $COMPOSE_CMD up -d; then
        log_success "Monitoring stack started"
        log_info "Grafana: http://localhost:3000 (admin / \${GRAFANA_ADMIN_PASSWORD:-admin123})"
        log_info "Prometheus: http://localhost:9090"
        cd ..

        # Wait for services to be ready
        log_info "Waiting for monitoring services to initialize..."
        sleep 5

        return 0
    else
        log_error "Failed to start monitoring stack"
        cd ..
        return 1
    fi
}

stop_monitoring() {
    log_info "Stopping monitoring stack..."

    cd monitoring/

    # Determine compose command
    if command -v podman-compose &> /dev/null; then
        COMPOSE_CMD="podman-compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    elif $CONTAINER_CMD compose version &> /dev/null; then
        COMPOSE_CMD="$CONTAINER_CMD compose"
    fi

    if $COMPOSE_CMD down; then
        log_success "Monitoring stack stopped"
        cd ..
        return 0
    else
        log_warning "Failed to stop monitoring stack cleanly"
        cd ..
        return 1
    fi
}

# ============================================================================
# Test Execution Functions
# ============================================================================

create_test_env_file() {
    log_info "Creating test environment file..."

    local test_env_file="test/.env"

    cat > "$test_env_file" <<EOF
# Auto-generated test environment file
# Generated at: $(date)

# RabbitMQ Connection
RABBITMQ_HOST=${RMQ1_HOST}
RABBITMQ_PORT=5672
RABBITMQ_USER=${RABBITMQ_ADMIN_USER}
RABBITMQ_PASSWORD=${RABBITMQ_ADMIN_PASSWORD}

# Test Parameters
MESSAGE_SIZE=${MESSAGE_SIZE_BYTES:-102400}
TARGET_RATE=${MESSAGES_PER_SECOND:-10000}
DURATION=${TEST_DURATION_SECONDS:-60}

# Producer Settings
PRODUCER_WORKERS=${PRODUCER_WORKERS:-4}
CONNECTIONS_PER_WORKER=${PRODUCER_CONNECTIONS_PER_WORKER:-10}
CHANNELS_PER_CONNECTION=${PRODUCER_CHANNELS_PER_CONNECTION:-5}
PUBLISHER_CONFIRMS=${PUBLISHER_CONFIRMS:-true}
BATCH_SIZE=${PRODUCER_BATCH_SIZE:-100}

# Consumer Settings
CONSUMER_WORKERS=${CONSUMER_WORKERS:-2}
CONSUMER_CONNECTIONS=${CONSUMER_CONNECTIONS_PER_WORKER:-10}
PREFETCH_COUNT=${CONSUMER_PREFETCH_COUNT:-200}
BATCH_ACK_SIZE=${CONSUMER_BATCH_ACK_SIZE:-50}
PROCESSING_DELAY=${CONSUMER_PROCESSING_DELAY_MS:-0}

# Queue Settings
QUEUE_NAME=${QUEUE_NAME:-load_test_queue}
QUEUE_TYPE=${QUEUE_TYPE:-quorum}
DURABLE=${QUEUE_DURABLE:-true}
DELIVERY_MODE=${MESSAGE_DELIVERY_MODE:-2}

# Monitoring
ENABLE_STATS=${ENABLE_STATS_OUTPUT:-true}
STATS_INTERVAL=${STATS_INTERVAL:-5}
PROMETHEUS_PORT=${PROMETHEUS_METRICS_PORT:-8000}
EOF

    log_success "Created $test_env_file"
    return 0
}

start_consumers() {
    log_info "Starting consumer processes..."

    local consumer_workers=${CONSUMER_WORKERS:-2}
    local consumer_pids=()

    for i in $(seq 1 $consumer_workers); do
        local container_name="${CONSUMER_CONTAINER_PREFIX}-${i}"

        log_info "  Starting consumer worker $i..."
        $CONTAINER_CMD run -d \
            --name "$container_name" \
            --env-file test/.env \
            --network host \
            "$TEST_IMAGE" \
            python load_test_consumer.py > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            log_success "    Consumer worker $i started: $container_name"
        else
            log_error "    Failed to start consumer worker $i"
        fi
    done

    # Give consumers time to connect
    sleep 3

    return 0
}

start_producers() {
    log_info "Starting producer processes..."

    local producer_workers=${PRODUCER_WORKERS:-4}

    for i in $(seq 1 $producer_workers); do
        local container_name="${PRODUCER_CONTAINER_PREFIX}-${i}"

        log_info "  Starting producer worker $i..."
        $CONTAINER_CMD run -d \
            --name "$container_name" \
            --env-file test/.env \
            --network host \
            "$TEST_IMAGE" \
            python load_test_producer.py > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            log_success "    Producer worker $i started: $container_name"
        else
            log_error "    Failed to start producer worker $i"
        fi
    done

    return 0
}

monitor_test_progress() {
    local duration=${TEST_DURATION_SECONDS:-60}

    log_info "Test running for $duration seconds..."
    log_info "Monitor progress at:"
    echo "  - Grafana: http://localhost:3000"
    echo "  - Prometheus: http://localhost:9090"
    echo "  - RabbitMQ Management: http://${RMQ1_HOST}:15672"

    # Progress bar
    for i in $(seq 1 $duration); do
        local percent=$((i * 100 / duration))
        printf "\r  Progress: [%-50s] %d%% (%d/%d seconds)" \
            $(printf '#%.0s' $(seq 1 $((percent / 2)))) \
            $percent $i $duration
        sleep 1
    done

    echo ""
    log_success "Test duration completed"

    # Give a few seconds for final message processing
    log_info "Waiting for final message processing..."
    sleep 10

    return 0
}

collect_container_logs() {
    log_info "Collecting container logs..."

    local producer_workers=${PRODUCER_WORKERS:-4}
    local consumer_workers=${CONSUMER_WORKERS:-2}

    # Collect producer logs
    for i in $(seq 1 $producer_workers); do
        local container_name="${PRODUCER_CONTAINER_PREFIX}-${i}"
        $CONTAINER_CMD logs "$container_name" > "${CURRENT_RESULTS_DIR}/producer_${i}.log" 2>&1 || true
    done

    # Collect consumer logs
    for i in $(seq 1 $consumer_workers); do
        local container_name="${CONSUMER_CONTAINER_PREFIX}-${i}"
        $CONTAINER_CMD logs "$container_name" > "${CURRENT_RESULTS_DIR}/consumer_${i}.log" 2>&1 || true
    done

    log_success "Logs saved to $CURRENT_RESULTS_DIR"
    return 0
}

stop_test_containers() {
    log_info "Stopping and removing test containers..."

    # Stop and remove all producer containers
    $CONTAINER_CMD ps -a --format "{{.Names}}" | grep "^${PRODUCER_CONTAINER_PREFIX}" | while read container; do
        $CONTAINER_CMD stop "$container" > /dev/null 2>&1 || true
        $CONTAINER_CMD rm "$container" > /dev/null 2>&1 || true
    done

    # Stop and remove all consumer containers
    $CONTAINER_CMD ps -a --format "{{.Names}}" | grep "^${CONSUMER_CONTAINER_PREFIX}" | while read container; do
        $CONTAINER_CMD stop "$container" > /dev/null 2>&1 || true
        $CONTAINER_CMD rm "$container" > /dev/null 2>&1 || true
    done

    log_success "Test containers stopped and removed"
    return 0
}

# ============================================================================
# Cleanup Functions
# ============================================================================

cleanup_test_queue() {
    log_info "Cleaning up test queue..."

    local queue_name=${QUEUE_NAME:-load_test_queue}

    # Delete queue via management API
    curl -s -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASSWORD" \
        -X DELETE \
        "http://${RMQ1_HOST}:15672/api/queues/%2F/${queue_name}" > /dev/null 2>&1 || true

    log_success "Test queue removed (if it existed)"
    return 0
}

# ============================================================================
# Report Generation
# ============================================================================

generate_report() {
    log_info "Generating test report..."

    if [ -z "$CURRENT_RESULTS_DIR" ]; then
        # Find most recent results directory
        CURRENT_RESULTS_DIR=$(ls -td ${RESULTS_DIR}/*/ 2>/dev/null | head -1)
        if [ -z "$CURRENT_RESULTS_DIR" ]; then
            log_error "No test results found"
            return 1
        fi
        CURRENT_RESULTS_DIR=${CURRENT_RESULTS_DIR%/}  # Remove trailing slash
    fi

    local report_file="${CURRENT_RESULTS_DIR}/report.txt"

    cat > "$report_file" <<EOF
================================================================================
RabbitMQ Load Test Report
================================================================================
Generated: $(date)

Test Configuration:
------------------
Message Size: ${MESSAGE_SIZE_BYTES:-N/A} bytes
Target Rate: ${MESSAGES_PER_SECOND:-N/A} msg/s
Duration: ${TEST_DURATION_SECONDS:-N/A} seconds
Producer Workers: ${PRODUCER_WORKERS:-N/A}
Consumer Workers: ${CONSUMER_WORKERS:-N/A}

Expected Results:
----------------
Total Messages: $((${MESSAGES_PER_SECOND:-0} * ${TEST_DURATION_SECONDS:-0}))
Total Data: ~$(( ${MESSAGES_PER_SECOND:-0} * ${TEST_DURATION_SECONDS:-0} * ${MESSAGE_SIZE_BYTES:-0} / 1073741824 )) GB

RabbitMQ Cluster:
----------------
Node 1: ${RMQ1_HOST}
Node 2: ${RMQ2_HOST}
Node 3: ${RMQ3_HOST}

Results Location:
----------------
${CURRENT_RESULTS_DIR}

Monitoring:
----------
Grafana: http://localhost:3000
Prometheus: http://localhost:9090

For detailed metrics, query Prometheus or view Grafana dashboards.

Logs:
-----
EOF

    # List log files
    ls -lh "${CURRENT_RESULTS_DIR}"/*.log 2>/dev/null >> "$report_file" || echo "No log files found" >> "$report_file"

    cat >> "$report_file" <<EOF

================================================================================
To analyze results:
1. Open Grafana: http://localhost:3000
2. View RabbitMQ Load Test dashboard
3. Check producer/consumer logs in ${CURRENT_RESULTS_DIR}
================================================================================
EOF

    log_success "Report generated: $report_file"
    cat "$report_file"

    return 0
}

# ============================================================================
# Main Commands
# ============================================================================

cmd_prep() {
    log_info "=== Preparing Load Test Environment ==="

    load_env_files
    validate_dependencies || exit 1
    validate_env_file || exit 1
    validate_params_file || exit 1
    generate_prometheus_config || exit 1
    build_test_container || exit 1
    prepare_results_directory || exit 1

    log_success "=== Preparation Complete ==="
    log_info "Next steps:"
    echo "  1. Ensure RabbitMQ cluster is running: ./rmq.sh status"
    echo "  2. Ensure monitoring exporters are installed on RabbitMQ nodes (see LOAD_TEST.md)"
    echo "  3. Run validation: ./load_test.sh validate"
    echo "  4. Run test: ./load_test.sh test"
}

cmd_validate() {
    log_info "=== Validating Prerequisites ==="

    load_env_files

    local validation_passed=true

    validate_dependencies || validation_passed=false
    validate_env_file || validation_passed=false
    validate_params_file || validation_passed=false
    validate_rabbitmq_cluster || validation_passed=false
    validate_exporters || true  # Exporters are optional, just warn

    if [ "$validation_passed" = true ]; then
        log_success "=== All Prerequisites Satisfied ==="
        log_info "Ready to run: ./load_test.sh test"
        return 0
    else
        log_error "=== Validation Failed ==="
        log_error "Please fix the issues above before running the test"
        return 1
    fi
}

cmd_test() {
    log_info "=== Starting Load Test ==="

    load_env_files

    # Quick validation
    validate_dependencies || exit 1
    validate_env_file || exit 1
    validate_rabbitmq_cluster || exit 1

    # Prepare for this test run
    prepare_results_directory || exit 1
    create_test_env_file || exit 1

    # Start monitoring
    start_monitoring || {
        log_warning "Failed to start monitoring, but continuing with test"
    }

    # Start test workload
    start_consumers || {
        log_error "Failed to start consumers"
        stop_test_containers
        exit 1
    }

    start_producers || {
        log_error "Failed to start producers"
        stop_test_containers
        exit 1
    }

    # Monitor progress
    monitor_test_progress

    # Collect results
    collect_container_logs

    # Stop test containers
    stop_test_containers

    # Generate report
    generate_report

    log_success "=== Load Test Complete ==="
    log_info "Results saved to: $CURRENT_RESULTS_DIR"
    log_info "View report: cat ${CURRENT_RESULTS_DIR}/report.txt"
}

cmd_monitor_start() {
    log_info "=== Starting Monitoring Stack ==="

    load_env_files
    generate_prometheus_config || exit 1
    start_monitoring || exit 1

    log_success "=== Monitoring Stack Running ==="
}

cmd_monitor_stop() {
    log_info "=== Stopping Monitoring Stack ==="

    stop_monitoring || exit 1

    log_success "=== Monitoring Stack Stopped ==="
}

cmd_cleanup() {
    log_info "=== Cleaning Up Test Artifacts ==="

    load_env_files

    stop_test_containers
    cleanup_test_queue

    # Remove test env file
    rm -f test/.env

    log_success "=== Cleanup Complete ==="
    log_info "Monitoring stack is still running. To stop it: ./load_test.sh monitor-stop"
}

cmd_report() {
    log_info "=== Generating Test Report ==="

    load_env_files
    generate_report
}

cmd_help() {
    cat <<EOF
RabbitMQ Load Test Script

USAGE:
    ./load_test.sh COMMAND

COMMANDS:
    prep              Prepare environment (one-time setup)
                      - Validate configuration files
                      - Build test containers
                      - Generate monitoring configs
                      - Create results directory

    validate          Run pre-flight checks
                      - Check RabbitMQ cluster health
                      - Verify exporters accessible
                      - Validate configuration

    test              Run load test
                      - Start monitoring stack
                      - Execute load test with configured parameters
                      - Collect logs and generate report

    monitor-start     Start monitoring stack only
    monitor-stop      Stop monitoring stack

    cleanup           Clean up test artifacts
                      - Stop and remove test containers
                      - Delete test queue
                      - Remove temporary files

    report            Generate report from most recent test

    help              Show this help message

CONFIGURATION:
    Edit these files to configure your test:
    - .env                   RabbitMQ cluster configuration
    - load_test_params.env   Load test parameters

WORKFLOW:
    1. ./load_test.sh prep
    2. Edit load_test_params.env (set message size, rate, duration)
    3. ./load_test.sh validate
    4. ./load_test.sh test
    5. View results in Grafana: http://localhost:3000

PREREQUISITES:
    - RabbitMQ cluster must be running (3 nodes)
    - Node exporters installed on RabbitMQ nodes (port 9100)
    - Podman or Docker installed
    - curl installed

For detailed documentation, see LOAD_TEST.md
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    local command=${1:-help}

    case "$command" in
        prep)
            cmd_prep
            ;;
        validate)
            cmd_validate
            ;;
        test)
            cmd_test
            ;;
        monitor-start)
            cmd_monitor_start
            ;;
        monitor-stop)
            cmd_monitor_stop
            ;;
        cleanup)
            cmd_cleanup
            ;;
        report)
            cmd_report
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
