#!/bin/bash
set -e

# RabbitMQ Load Test Orchestration Script
# Target: 150K messages/second at 100KB each for 100 seconds
# Total: ~1.43TB data throughput

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f ".env" ]; then
    source .env
else
    echo -e "${RED}❌ .env file not found${NC}"
    echo "Copy .env.example to .env and configure your settings"
    exit 1
fi

# Configuration
LOAD_TEST_DURATION=${LOAD_TEST_DURATION:-100}
TARGET_RATE=${TARGET_RATE:-150000}
MESSAGE_SIZE=${MESSAGE_SIZE:-102400}
NUM_PRODUCER_WORKERS=${NUM_PRODUCER_WORKERS:-8}
NUM_CONSUMER_WORKERS=${NUM_CONSUMER_WORKERS:-4}
PRODUCER_CONNECTIONS=${PRODUCER_CONNECTIONS:-50}
CONSUMER_CONNECTIONS=${CONSUMER_CONNECTIONS:-20}
CHANNELS_PER_CONNECTION=${CHANNELS_PER_CONNECTION:-10}

# Derived calculations
TOTAL_MESSAGES=$((TARGET_RATE * LOAD_TEST_DURATION))
TOTAL_DATA_GB=$(echo "scale=2; $TOTAL_MESSAGES * $MESSAGE_SIZE / 1024 / 1024 / 1024" | bc)

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}              RabbitMQ High-Performance Load Test${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Target Rate:      ${GREEN}${TARGET_RATE:,} messages/second${NC}"
    echo -e "Message Size:     ${GREEN}${MESSAGE_SIZE:,} bytes (${MESSAGE_SIZE}KB)${NC}"
    echo -e "Test Duration:    ${GREEN}${LOAD_TEST_DURATION} seconds${NC}"
    echo -e "Total Messages:   ${GREEN}${TOTAL_MESSAGES:,}${NC}"
    echo -e "Total Data:       ${GREEN}${TOTAL_DATA_GB} GB${NC}"
    echo -e "Producer Workers: ${GREEN}${NUM_PRODUCER_WORKERS}${NC}"
    echo -e "Consumer Workers: ${GREEN}${NUM_CONSUMER_WORKERS}${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

check_prerequisites() {
    echo -e "${YELLOW}🔍 Checking prerequisites...${NC}"
    
    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}❌ Python 3 is required${NC}"
        exit 1
    fi
    
    # Check if bc is available for calculations
    if ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}⚠️  Installing bc for calculations...${NC}"
        sudo dnf install -y bc || sudo apt-get install -y bc
    fi
    
    # Check RabbitMQ cluster status
    echo -e "${YELLOW}🐰 Checking RabbitMQ cluster status...${NC}"
    
    local cluster_ready=true
    for host in "$RMQ1_HOST" "$RMQ2_HOST" "$RMQ3_HOST"; do
        if ! curl -s -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASSWORD" \
             "http://$host:15672/api/nodes" >/dev/null; then
            echo -e "${RED}❌ RabbitMQ not accessible at $host${NC}"
            cluster_ready=false
        else
            echo -e "${GREEN}✅ RabbitMQ accessible at $host${NC}"
        fi
    done
    
    if [ "$cluster_ready" = false ]; then
        echo -e "${RED}❌ RabbitMQ cluster not ready. Please start the cluster first.${NC}"
        echo "Run: ./rmq.sh up rmq1 && ./rmq.sh up rmq2 && ./rmq.sh up rmq3"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Prerequisites check passed${NC}"
}

setup_monitoring() {
    echo -e "${YELLOW}📊 Setting up monitoring stack...${NC}"
    
    cd monitoring
    
    # Check if Docker/Podman is available
    if command -v podman &> /dev/null; then
        CONTAINER_ENGINE=podman
    elif command -v docker &> /dev/null; then
        CONTAINER_ENGINE=docker
    else
        echo -e "${RED}❌ Docker or Podman is required for monitoring${NC}"
        exit 1
    fi
    
    # Start monitoring stack
    echo -e "${YELLOW}🚀 Starting monitoring containers...${NC}"
    $CONTAINER_ENGINE compose up -d
    
    # Wait for services to be ready
    echo -e "${YELLOW}⏳ Waiting for monitoring services to start...${NC}"
    sleep 30
    
    # Check if services are accessible
    if curl -s "http://localhost:9090" >/dev/null; then
        echo -e "${GREEN}✅ Prometheus is ready at http://localhost:9090${NC}"
    else
        echo -e "${YELLOW}⚠️  Prometheus may still be starting...${NC}"
    fi
    
    if curl -s "http://localhost:3000" >/dev/null; then
        echo -e "${GREEN}✅ Grafana is ready at http://localhost:3000 (admin/admin123)${NC}"
    else
        echo -e "${YELLOW}⚠️  Grafana may still be starting...${NC}"
    fi
    
    cd ..
}

optimize_system() {
    echo -e "${YELLOW}⚙️  Optimizing system for high throughput...${NC}"
    
    # Increase file descriptor limits
    echo -e "${YELLOW}📁 Increasing file descriptor limits...${NC}"
    ulimit -n 65536 || echo -e "${YELLOW}⚠️  Could not set file descriptor limit${NC}"
    
    # TCP optimizations for high throughput
    echo -e "${YELLOW}🌐 Applying TCP optimizations...${NC}"
    sudo sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
    sudo sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
    sudo sysctl -w net.core.rmem_default=16777216 2>/dev/null || true
    sudo sysctl -w net.core.wmem_default=16777216 2>/dev/null || true
    sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" 2>/dev/null || true
    sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" 2>/dev/null || true
    sudo sysctl -w net.core.netdev_max_backlog=5000 2>/dev/null || true
    
    echo -e "${GREEN}✅ System optimizations applied${NC}"
}

prepare_load_test() {
    echo -e "${YELLOW}🔧 Preparing load test environment...${NC}"
    
    # Build test container if using containerized approach
    cd test
    if [ -f "Dockerfile" ]; then
        echo -e "${YELLOW}🐳 Building load test container...${NC}"
        if command -v podman &> /dev/null; then
            podman build -t rabbitmq-loadtest .
        elif command -v docker &> /dev/null; then
            docker build -t rabbitmq-loadtest .
        fi
    fi
    
    # Install Python dependencies if running natively
    if [ -f "requirements.txt" ]; then
        echo -e "${YELLOW}🐍 Installing Python dependencies...${NC}"
        pip3 install -r requirements.txt --user
    else
        # Install essential packages
        pip3 install pika prometheus_client --user
    fi
    
    cd ..
    
    # Create load test environment file
    cat > test/.env << EOF
# Load Test Configuration
TARGET_RATE=${TARGET_RATE}
MESSAGE_SIZE=${MESSAGE_SIZE}
TEST_DURATION=${LOAD_TEST_DURATION}
NUM_WORKERS=${NUM_PRODUCER_WORKERS}
CONSUMER_WORKERS=${NUM_CONSUMER_WORKERS}
PRODUCER_CONNECTIONS=${PRODUCER_CONNECTIONS}
CONSUMER_CONNECTIONS=${CONSUMER_CONNECTIONS}
CHANNELS_PER_CONNECTION=${CHANNELS_PER_CONNECTION}
PREFETCH_COUNT=1000
BATCH_SIZE=100
PROCESSING_DELAY=0.001

# RabbitMQ Connection
RABBITMQ_HOST=${RMQ1_HOST}
RMQ1_HOST=${RMQ1_HOST}
RMQ2_HOST=${RMQ2_HOST}
RMQ3_HOST=${RMQ3_HOST}
RABBITMQ_PORT=5672
RABBITMQ_USERNAME=${RABBITMQ_ADMIN_USER}
RABBITMQ_PASSWORD=${RABBITMQ_ADMIN_PASSWORD}
RABBITMQ_VHOST=/
EOF
    
    echo -e "${GREEN}✅ Load test environment prepared${NC}"
}

run_load_test() {
    echo -e "${YELLOW}🚀 Starting load test...${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Starting at: $(date)"
    echo -e "Expected completion: $(date -d "+${LOAD_TEST_DURATION} seconds")"
    echo -e "${BLUE}================================================================${NC}"
    
    cd test
    
    # Start consumers first
    echo -e "${YELLOW}🎧 Starting consumers...${NC}"
    python3 load_test_consumer.py > consumer.log 2>&1 &
    CONSUMER_PID=$!
    echo "Consumer PID: $CONSUMER_PID"
    
    # Wait a moment for consumers to initialize
    sleep 5
    
    # Start producers
    echo -e "${YELLOW}📨 Starting producers...${NC}"
    python3 load_test_producer.py > producer.log 2>&1 &
    PRODUCER_PID=$!
    echo "Producer PID: $PRODUCER_PID"
    
    # Monitor progress
    echo -e "${YELLOW}📊 Monitoring load test progress...${NC}"
    echo "View logs with: tail -f test/producer.log test/consumer.log"
    echo "Monitor in Grafana: http://localhost:3000"
    echo "Prometheus metrics: http://localhost:9090"
    
    # Wait for test duration plus buffer
    local total_wait=$((LOAD_TEST_DURATION + 30))
    echo -e "${YELLOW}⏳ Waiting ${total_wait} seconds for test completion...${NC}"
    
    for ((i=1; i<=total_wait; i++)); do
        if ((i % 10 == 0)); then
            echo -e "${BLUE}Progress: ${i}/${total_wait} seconds${NC}"
            
            # Check if processes are still running
            if ! kill -0 $PRODUCER_PID 2>/dev/null; then
                echo -e "${YELLOW}Producer finished early${NC}"
                break
            fi
        fi
        sleep 1
    done
    
    # Stop processes gracefully
    echo -e "${YELLOW}🛑 Stopping load test...${NC}"
    
    if kill -0 $PRODUCER_PID 2>/dev/null; then
        kill -TERM $PRODUCER_PID 2>/dev/null || true
        sleep 5
        kill -KILL $PRODUCER_PID 2>/dev/null || true
    fi
    
    # Give consumers more time to process remaining messages
    echo -e "${YELLOW}⏳ Allowing consumers to finish processing...${NC}"
    sleep 30
    
    if kill -0 $CONSUMER_PID 2>/dev/null; then
        kill -TERM $CONSUMER_PID 2>/dev/null || true
        sleep 10
        kill -KILL $CONSUMER_PID 2>/dev/null || true
    fi
    
    cd ..
    
    echo -e "${GREEN}✅ Load test completed${NC}"
}

generate_report() {
    echo -e "${YELLOW}📋 Generating load test report...${NC}"
    
    local report_file="load_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$report_file" << EOF
================================================================
              RabbitMQ Load Test Report
================================================================
Test Configuration:
- Target Rate: ${TARGET_RATE:,} messages/second
- Message Size: ${MESSAGE_SIZE:,} bytes
- Test Duration: ${LOAD_TEST_DURATION} seconds
- Expected Total: ${TOTAL_MESSAGES:,} messages
- Expected Data: ${TOTAL_DATA_GB} GB

Test Infrastructure:
- Producer Workers: ${NUM_PRODUCER_WORKERS}
- Consumer Workers: ${NUM_CONSUMER_WORKERS}
- Connections per Producer: ${PRODUCER_CONNECTIONS}
- Connections per Consumer: ${CONSUMER_CONNECTIONS}
- Channels per Connection: ${CHANNELS_PER_CONNECTION}

Test Execution:
- Start Time: $(date)
- End Time: $(date)

Results Summary:
$(tail -20 test/producer.log 2>/dev/null || echo "Producer logs not available")

$(tail -20 test/consumer.log 2>/dev/null || echo "Consumer logs not available")

Monitoring:
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000
- Dashboard: RabbitMQ Load Test Dashboard

Log Files:
- Producer: test/producer.log  
- Consumer: test/consumer.log

================================================================
EOF
    
    echo -e "${GREEN}✅ Report generated: $report_file${NC}"
    
    # Display summary
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                    Test Summary${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo "Check the following for detailed results:"
    echo "📊 Grafana Dashboard: http://localhost:3000"
    echo "📈 Prometheus Metrics: http://localhost:9090"
    echo "📋 Full Report: $report_file"
    echo "📝 Producer Logs: test/producer.log"
    echo "📝 Consumer Logs: test/consumer.log"
    echo -e "${BLUE}================================================================${NC}"
}

cleanup_monitoring() {
    echo -e "${YELLOW}🧹 Cleaning up monitoring stack...${NC}"
    
    cd monitoring
    
    if command -v podman &> /dev/null; then
        podman compose down
    elif command -v docker &> /dev/null; then
        docker compose down
    fi
    
    cd ..
    
    echo -e "${GREEN}✅ Monitoring cleanup completed${NC}"
}

show_help() {
    echo "RabbitMQ Load Test Orchestration Script"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  full        - Run complete load test with monitoring (default)"
    echo "  test-only   - Run only the load test without monitoring setup"
    echo "  monitor     - Setup monitoring only"
    echo "  cleanup     - Stop and remove monitoring containers"
    echo "  report      - Generate test report from existing logs"
    echo "  help        - Show this help message"
    echo ""
    echo "Environment Variables (set in .env file):"
    echo "  TARGET_RATE           - Target messages per second (default: 150000)"
    echo "  MESSAGE_SIZE          - Message size in bytes (default: 102400)"
    echo "  LOAD_TEST_DURATION    - Test duration in seconds (default: 100)"
    echo "  NUM_PRODUCER_WORKERS  - Number of producer processes (default: 8)"
    echo "  NUM_CONSUMER_WORKERS  - Number of consumer processes (default: 4)"
    echo ""
    echo "Prerequisites:"
    echo "  - RabbitMQ cluster must be running (./rmq.sh up rmq1/rmq2/rmq3)"
    echo "  - Python 3 with pika library"
    echo "  - Docker or Podman for monitoring"
    echo ""
}

# Signal handlers
cleanup_on_exit() {
    echo -e "\n${YELLOW}🛑 Caught signal, cleaning up...${NC}"
    
    # Kill background processes
    if [ -n "$PRODUCER_PID" ] && kill -0 $PRODUCER_PID 2>/dev/null; then
        kill -TERM $PRODUCER_PID 2>/dev/null || true
    fi
    
    if [ -n "$CONSUMER_PID" ] && kill -0 $CONSUMER_PID 2>/dev/null; then
        kill -TERM $CONSUMER_PID 2>/dev/null || true
    fi
    
    exit 0
}

trap cleanup_on_exit SIGINT SIGTERM

# Main execution
case "${1:-full}" in
    "full")
        print_header
        check_prerequisites
        optimize_system
        setup_monitoring
        prepare_load_test
        run_load_test
        generate_report
        ;;
    "test-only")
        print_header
        check_prerequisites
        optimize_system
        prepare_load_test
        run_load_test
        generate_report
        ;;
    "monitor")
        setup_monitoring
        ;;
    "cleanup")
        cleanup_monitoring
        ;;
    "report")
        generate_report
        ;;
    "help")
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        exit 1
        ;;
esac