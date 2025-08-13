#!/bin/bash
set -e

# RabbitMQ Cluster Management Script for Rocky Linux 8 with Podman
# Usage: ./rmq.sh <command> [args]
# Commands: prep, up, join, policy, status, down, wipe

# Load environment variables
echo "🔍 DEBUG: Looking for .env file in current directory: $(pwd)"
if [ -f ".env" ]; then
    echo "✅ ENV FILE FOUND: Loading configuration from .env"
    source .env
    echo "🔍 DEBUG: Environment variables loaded successfully"
else
    echo "❌ ENV FILE MISSING: .env file not found in $(pwd)"
    echo "🔧 SOLUTION: Copy .env.example to .env and configure:"
    echo "  cp .env.example .env"
    echo "  nano .env  # Edit the configuration"
    echo "📄 REQUIRED: Update IP addresses, passwords, and Erlang cookie"
    if [ -f ".env.example" ]; then
        echo "✅ Found .env.example file - you can copy and modify it"
    else
        echo "❌ .env.example is also missing - this may indicate a damaged installation"
    fi
    exit 1
fi

# Validate required environment variables
check_env() {
    echo "🔍 DEBUG: Validating environment configuration..."
    local vars=("RABBITMQ_IMAGE" "RABBITMQ_ADMIN_USER" "RABBITMQ_ADMIN_PASSWORD" "ERLANG_COOKIE" "RMQ1_HOST" "RMQ2_HOST" "RMQ3_HOST")
    local missing_vars=()
    
    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "❌ MISSING: $var is not set in .env file"
            missing_vars+=("$var")
        else
            # Show partial values for sensitive variables
            case "$var" in
                *PASSWORD*|*COOKIE*)
                    echo "✅ $var: ${!var:0:3}..."
                    ;;
                *)
                    echo "✅ $var: ${!var}"
                    ;;
            esac
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "❌ ENV CHECK FAILED: Missing required variables"
        echo "🔧 SOLUTION: Add these to your .env file:"
        for var in "${missing_vars[@]}"; do
            echo "  $var=<your_value>"
        done
        echo "📄 HINT: Copy .env.example to .env and customize the values"
        exit 1
    fi
    
    echo "✅ ENV CHECK OK: All required variables are set"
}

# Get node hostname based on current server
get_node_name() {
    local current_host=$(hostname -I | awk '{print $1}' || echo "unknown")
    echo "🔍 DEBUG: Current server IP detected as: $current_host"
    echo "🔍 DEBUG: Configured IPs - RMQ1: $RMQ1_HOST, RMQ2: $RMQ2_HOST, RMQ3: $RMQ3_HOST"
    
    case "$current_host" in
        "$RMQ1_HOST") 
            echo "🔍 DEBUG: Identified as RMQ1 server"
            echo "rabbit@rmq1" ;;
        "$RMQ2_HOST") 
            echo "🔍 DEBUG: Identified as RMQ2 server"
            echo "rabbit@rmq2" ;;
        "$RMQ3_HOST") 
            echo "🔍 DEBUG: Identified as RMQ3 server"
            echo "rabbit@rmq3" ;;
        *) 
            local fallback="rabbit@$(hostname -s)"
            echo "⚠️  WARNING: Current IP $current_host doesn't match any configured RMQ host"
            echo "🔍 DEBUG: Using fallback nodename: $fallback"
            echo "$fallback" ;;
    esac
}

# Check network connectivity between nodes
check_connectivity() {
    local target_host="$1"
    local target_name="$2"
    
    echo "🔍 DEBUG: Starting connectivity check to $target_name at $target_host"
    
    # Check if host is reachable
    echo "🔍 DEBUG: Testing ping to $target_host..."
    if ! ping -c 1 -W 2 "$target_host" >/dev/null 2>&1; then
        echo "❌ PING FAILED: Cannot reach $target_name at $target_host"
        echo "🔍 DEBUG: Ping command: ping -c 1 -W 2 $target_host"
        return 1
    fi
    echo "✅ PING OK: Host $target_host is reachable"
    
    # Check required ports
    local ports=(5672 4369 25672 15672)
    local port_names=("AMQP" "EPMD" "Inter-node" "Management")
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local port_name="${port_names[$i]}"
        echo "🔍 DEBUG: Testing port $port ($port_name) on $target_host..."
        if timeout 3 bash -c "echo >/dev/tcp/$target_host/$port" 2>/dev/null; then
            echo "✅ PORT $port OK: $port_name service accessible"
        else
            echo "❌ PORT $port FAILED: $port_name service not accessible on $target_name"
            echo "🔍 DEBUG: Port test command: timeout 3 bash -c 'echo >/dev/tcp/$target_host/$port'"
            return 1
        fi
    done
    
    echo "✅ CONNECTIVITY OK: All checks passed for $target_name"
    return 0
}

# Wait for container to be ready
wait_for_container() {
    local container_name="$1"
    local max_wait="${2:-60}"
    local check_interval=2
    local elapsed=0
    
    echo "🔍 DEBUG: Waiting for container $container_name to be ready (max ${max_wait}s)..."
    
    while [ $elapsed -lt $max_wait ]; do
        # Check if container exists first
        if ! podman container exists "$container_name"; then
            echo "❌ CONTAINER MISSING: Container $container_name does not exist"
            return 1
        fi
        
        # Check container status
        local container_status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        echo "🔍 DEBUG: Container $container_name status: $container_status"
        
        if [ "$container_status" != "running" ]; then
            echo "❌ CONTAINER NOT RUNNING: Container $container_name is $container_status"
            echo "🔍 DEBUG: Container logs (last 10 lines):"
            podman logs "$container_name" | tail -10
            return 1
        fi
        
        # Test RabbitMQ status
        echo "🔍 DEBUG: Testing RabbitMQ status in container..."
        if podman exec "$container_name" rabbitmqctl status >/dev/null 2>&1; then
            echo "✅ CONTAINER READY: RabbitMQ in $container_name is responding"
            return 0
        fi
        
        # Test if RabbitMQ process is at least running
        local rabbit_processes=$(podman exec "$container_name" pgrep -f "rabbit" 2>/dev/null | wc -l)
        echo "🔍 DEBUG: RabbitMQ processes in container: $rabbit_processes"
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        echo "⏳ WAITING: Still initializing... ($elapsed/${max_wait}s)"
    done
    
    echo "❌ TIMEOUT: Container $container_name failed to become ready within ${max_wait}s"
    echo "🔍 DEBUG: Final container status:"
    podman inspect "$container_name" --format 'Status: {{.State.Status}} | Error: {{.State.Error}}' 2>/dev/null || echo "Could not inspect container"
    return 1
}

# Prepare system - install Podman and configure firewall
prep() {
    echo "=== Preparing Rocky Linux 8 for RabbitMQ cluster ==="
    
    # Install Podman and required tools
    echo "🔍 DEBUG: Installing Podman and dependencies..."
    sudo dnf update -y
    sudo dnf install -y podman firewalld curl dos2unix
    echo "✅ INSTALL OK: Podman, firewalld, curl, and dos2unix installed"
    
    # Enable and start firewalld
    sudo systemctl enable --now firewalld
    
    # Open required ports
    echo "Opening firewall ports..."
    sudo firewall-cmd --permanent --add-port=5672/tcp    # AMQP
    sudo firewall-cmd --permanent --add-port=15672/tcp   # Management UI
    sudo firewall-cmd --permanent --add-port=4369/tcp    # EPMD
    sudo firewall-cmd --permanent --add-port=25672/tcp   # Inter-node communication
    sudo firewall-cmd --reload
    
    # Create data directory with proper permissions
    mkdir -p ~/.local/share/rabbitmq
    chmod 755 ~/.local/share/rabbitmq
    
    # Enable lingering for rootless containers
    sudo loginctl enable-linger $(whoami)
    
    echo "System preparation complete!"
    echo "Next: Copy .env.example to .env and configure your settings"
}

# Start a RabbitMQ node
up() {
    local node_name="$1"
    if [ -z "$node_name" ]; then
        echo "Usage: $0 up <node_name>"
        echo "Available nodes: rmq1, rmq2, rmq3"
        exit 1
    fi
    
    check_env
    
    local container_name="rabbitmq-$node_name"
    local node_host
    local data_dir="$HOME/.local/share/rabbitmq/$node_name"
    
    # Determine node host
    case "$node_name" in
        "rmq1") node_host="$RMQ1_HOST" ;;
        "rmq2") node_host="$RMQ2_HOST" ;;
        "rmq3") node_host="$RMQ3_HOST" ;;
        *) echo "Error: Invalid node name. Use rmq1, rmq2, or rmq3"; exit 1 ;;
    esac
    
    echo "=== Starting RabbitMQ node $node_name ==="
    
    # Force cleanup any existing container/processes
    echo "🔍 DEBUG: Performing force cleanup for $node_name before starting..."
    force_cleanup "$node_name"
    
    # Create data directory after cleanup
    mkdir -p "$data_dir"
    
    # Copy rabbitmq.conf to data directory
    if [ -f "rabbitmq.conf" ]; then
        cp rabbitmq.conf "$data_dir/"
    else
        echo "Warning: rabbitmq.conf not found, using default configuration"
    fi
    
    # Start RabbitMQ container
    echo "🔍 DEBUG: Starting RabbitMQ container with the following settings:"
    echo "  - Container name: $container_name"
    echo "  - Hostname: $node_name"
    echo "  - Node host IP: $node_host"
    echo "  - Data directory: $data_dir"
    echo "  - Image: $RABBITMQ_IMAGE"
    echo "  - Admin user: $RABBITMQ_ADMIN_USER"
    echo "  - Erlang cookie: ${ERLANG_COOKIE:0:8}..."
    echo "  - Host mappings: rmq1->$RMQ1_HOST, rmq2->$RMQ2_HOST, rmq3->$RMQ3_HOST"
    
    if podman run -d \
        --name "$container_name" \
        --hostname "$node_name" \
        --network host \
        --add-host rmq1:"$RMQ1_HOST" \
        --add-host rmq2:"$RMQ2_HOST" \
        --add-host rmq3:"$RMQ3_HOST" \
        -v "$data_dir:/var/lib/rabbitmq" \
        -v "$data_dir/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro" \
        -e RABBITMQ_DEFAULT_USER="$RABBITMQ_ADMIN_USER" \
        -e RABBITMQ_DEFAULT_PASS="$RABBITMQ_ADMIN_PASSWORD" \
        -e RABBITMQ_ERLANG_COOKIE="$ERLANG_COOKIE" \
        -e RABBITMQ_NODENAME="rabbit@$node_name" \
        "$RABBITMQ_IMAGE"; then
        echo "✅ CONTAINER STARTED: RabbitMQ container launched successfully"
    else
        echo "❌ CONTAINER START FAILED: Could not start RabbitMQ container"
        exit 1
    fi
    
    echo "Waiting for RabbitMQ to start..."
    sleep 5
    
    # Use the new wait function with better error handling
    if wait_for_container "$container_name" 120; then
        echo "✅ RabbitMQ node $node_name is ready!"
        echo "🌐 Management UI: http://$node_host:15672"
        echo "🔑 Login: $RABBITMQ_ADMIN_USER / $RABBITMQ_ADMIN_PASSWORD"
        echo ""
        
        # Test basic functionality
        echo "Testing basic RabbitMQ functionality..."
        if podman exec "$container_name" rabbitmqctl node_health_check >/dev/null 2>&1; then
            echo "✅ Health check passed"
        else
            echo "⚠️  Health check failed, but container is running"
        fi
        
        return 0
    else
        echo "❌ RabbitMQ failed to start properly"
        echo -e "\n=== Container Logs (last 30 lines) ==="
        podman logs "$container_name" | tail -30
        echo -e "\n=== Container Status ==="
        podman inspect "$container_name" --format '{{.State.Status}}: {{.State.Error}}'
        exit 1
    fi
}

# Join a node to the cluster
join() {
    local node_name="$1"
    local seed_node="$2"
    
    if [ -z "$node_name" ] || [ -z "$seed_node" ]; then
        echo "Usage: $0 join <node_name> <seed_node>"
        echo "Example: $0 join rmq2 rmq1"
        exit 1
    fi
    
    check_env
    
    local container_name="rabbitmq-$node_name"
    local seed_container="rabbitmq-$seed_node"
    local seed_nodename="rabbit@$seed_node"
    
    # Get seed node host for connectivity check
    local seed_host
    case "$seed_node" in
        "rmq1") seed_host="$RMQ1_HOST" ;;
        "rmq2") seed_host="$RMQ2_HOST" ;;
        "rmq3") seed_host="$RMQ3_HOST" ;;
        *) echo "Error: Invalid seed node. Use rmq1, rmq2, or rmq3"; exit 1 ;;
    esac
    
    echo "=== Joining $node_name to cluster via $seed_node ==="
    
    # Verify local container exists and is running
    echo "🔍 DEBUG: Checking local container $container_name..."
    if ! podman container exists "$container_name"; then
        echo "❌ LOCAL CONTAINER MISSING: Container $container_name does not exist"
        echo "🔧 SOLUTION: Run '$0 up $node_name' to create the container"
        exit 1
    fi
    
    local container_status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    echo "🔍 DEBUG: Local container status: $container_status"
    if [ "$container_status" != "running" ]; then
        echo "❌ LOCAL CONTAINER NOT RUNNING: Container $container_name is $container_status"
        echo "🔧 SOLUTION: Start the container with '$0 up $node_name'"
        exit 1
    fi
    echo "✅ LOCAL CONTAINER OK: $container_name is running"
    
    # For cross-server clustering, verify connectivity to the remote seed node
    echo "🔍 DEBUG: This is a cross-server join operation"
    echo "🔍 DEBUG: Local node: $node_name (container: $container_name)"
    echo "🔍 DEBUG: Remote seed node: $seed_node at $seed_host"
    echo "🔍 DEBUG: Seed nodename for clustering: $seed_nodename"
    
    # Check connectivity to seed node
    if ! check_connectivity "$seed_host" "$seed_node"; then
        echo "❌ Cannot connect to seed node $seed_node at $seed_host"
        echo "Ensure the seed node is running and accessible"
        exit 1
    fi
    
    # Wait for local container to be ready
    if ! wait_for_container "$container_name" 30; then
        echo "❌ Container $container_name is not ready"
        exit 1
    fi
    
    # For seed container on remote server, verify it's accessible
    echo "🔍 DEBUG: Verifying remote seed node is ready..."
    local max_wait=30
    local wait_time=0
    local seed_ready=false
    
    while [ $wait_time -lt $max_wait ]; do
        echo "🔍 DEBUG: Testing management interface at $seed_host:15672 (attempt $((wait_time/2 + 1)))..."
        if timeout 3 bash -c "echo >/dev/tcp/$seed_host/15672" 2>/dev/null; then
            echo "✅ SEED ACCESSIBLE: Management interface at $seed_host:15672 is responding"
            seed_ready=true
            break
        fi
        echo "⏳ WAITING: Seed node management interface not ready... ($wait_time/${max_wait}s)"
        sleep 2
        wait_time=$((wait_time + 2))
    done
    
    if [ "$seed_ready" = "false" ]; then
        echo "⚠️  SEED NOT READY: Management interface not responding after ${max_wait}s"
        echo "🔧 SOLUTION: Ensure seed node $seed_node is running on $seed_host"
        echo "🔧 SOLUTION: Check if port 15672 is open in firewall"
        echo "🔍 DEBUG: Proceeding with join attempt anyway..."
    fi
    
    # Test Erlang connectivity from local container to seed node
    echo "🔍 DEBUG: Testing Erlang connectivity to seed node..."
    echo "🔍 DEBUG: Command: podman exec $container_name rabbitmqctl eval \"net_adm:ping('$seed_nodename').\""
    
    local erlang_result
    erlang_result=$(podman exec "$container_name" rabbitmqctl eval "net_adm:ping('$seed_nodename')." 2>&1)
    echo "🔍 DEBUG: Erlang ping result: $erlang_result"
    
    if echo "$erlang_result" | grep -q "pong"; then
        echo "✅ ERLANG OK: Nodes can communicate via Erlang distribution"
    else
        echo "⚠️  ERLANG FAILED: Cannot ping seed node via Erlang distribution"
        echo "🔍 DEBUG: This may be normal if nodes haven't established trust yet"
        echo "🔍 DEBUG: Possible causes:"
        echo "  - Different Erlang cookies (check ERLANG_COOKIE in .env)"
        echo "  - Network connectivity issues (ports 4369, 25672)"
        echo "  - Hostname resolution issues"
        echo "🔍 DEBUG: Proceeding with join attempt..."
    fi
    
    # Stop the app with retry
    echo "🔍 DEBUG: Stopping RabbitMQ application on $node_name for clustering..."
    local retries=3
    while [ $retries -gt 0 ]; do
        echo "🔍 DEBUG: Attempt to stop_app (retries left: $retries)"
        if podman exec "$container_name" rabbitmqctl stop_app 2>&1; then
            echo "✅ STOP_APP OK: RabbitMQ application stopped successfully"
            break
        fi
        echo "⚠️  STOP_APP FAILED: Retrying... ($retries attempts left)"
        sleep 2
        ((retries--))
    done
    
    if [ $retries -eq 0 ]; then
        echo "❌ STOP_APP TIMEOUT: Could not stop RabbitMQ application after multiple attempts"
        echo "🔧 SOLUTION: Check container logs: podman logs $container_name"
    fi
    
    # Reset the node
    echo "🔍 DEBUG: Resetting node $node_name to clear any previous cluster membership..."
    local reset_output
    reset_output=$(podman exec "$container_name" rabbitmqctl reset 2>&1)
    if [ $? -eq 0 ]; then
        echo "✅ RESET OK: Node $node_name has been reset"
        echo "🔍 DEBUG: Reset output: $reset_output"
    else
        echo "❌ RESET FAILED: Could not reset node $node_name"
        echo "🔍 DEBUG: Reset error: $reset_output"
        exit 1
    fi
    
    # Join cluster with retry and detailed logging
    echo "🔍 DEBUG: Attempting to join $node_name to cluster via $seed_nodename..."
    retries=3
    while [ $retries -gt 0 ]; do
        echo "🔍 DEBUG: Join attempt (retries left: $retries)"
        echo "🔍 DEBUG: Command: podman exec $container_name rabbitmqctl join_cluster $seed_nodename"
        
        local join_output
        join_output=$(podman exec "$container_name" rabbitmqctl join_cluster "$seed_nodename" 2>&1)
        local join_result=$?
        
        echo "🔍 DEBUG: Join output: $join_output"
        
        if [ $join_result -eq 0 ]; then
            echo "✅ JOIN SUCCESS: Node $node_name has joined the cluster!"
            break
        fi
        
        echo "❌ JOIN FAILED: Attempt failed with exit code $join_result"
        echo "🔍 DEBUG: Error details: $join_output"
        
        if [ $retries -eq 1 ]; then
            echo "❌ JOIN TIMEOUT: Failed to join cluster after multiple attempts"
            echo "🔧 TROUBLESHOOTING CHECKLIST:"
            echo "  1. Verify ERLANG_COOKIE is identical on both nodes:"
            echo "     - Current: ${ERLANG_COOKIE:0:8}..."
            echo "  2. Check network connectivity between servers:"
            echo "     - AMQP port 5672: timeout 3 bash -c 'echo >/dev/tcp/$seed_host/5672'"
            echo "     - EPMD port 4369: timeout 3 bash -c 'echo >/dev/tcp/$seed_host/4369'"
            echo "     - Inter-node port 25672: timeout 3 bash -c 'echo >/dev/tcp/$seed_host/25672'"
            echo "  3. Verify seed node is running:"
            echo "     - SSH to $seed_host and run: podman ps | grep rabbitmq-$seed_node"
            echo "  4. Check firewall rules on both servers"
            echo "  5. Verify hostname resolution in containers:"
            echo "     - podman exec $container_name nslookup $seed_node"
            echo "  6. Check RabbitMQ logs for more details:"
            echo "     - podman logs $container_name"
            exit 1
        fi
        
        echo "⏳ RETRYING: Waiting 5 seconds before retry... ($retries attempts left)"
        sleep 5
        ((retries--))
    done
    
    # Start the app
    echo "🔍 DEBUG: Starting RabbitMQ application on $node_name after joining cluster..."
    local start_output
    start_output=$(podman exec "$container_name" rabbitmqctl start_app 2>&1)
    if [ $? -eq 0 ]; then
        echo "✅ START_APP OK: RabbitMQ application started successfully"
        echo "🔍 DEBUG: Start output: $start_output"
    else
        echo "❌ START_APP FAILED: Could not start RabbitMQ application"
        echo "🔍 DEBUG: Start error: $start_output"
        echo "🔧 SOLUTION: Check logs with: podman logs $container_name"
        exit 1
    fi
    
    echo "✅ Node $node_name has joined the cluster!"
    
    # Wait a moment for cluster to stabilize
    sleep 3
    
    # Show cluster status
    echo -e "\n🔍 DEBUG: Retrieving cluster status after join..."
    echo "=== CLUSTER STATUS ==="
    local status_output
    status_output=$(podman exec "$container_name" rabbitmqctl cluster_status 2>&1)
    if [ $? -eq 0 ]; then
        echo "$status_output"
        echo "✅ CLUSTER STATUS: Successfully retrieved cluster information"
    else
        echo "⚠️  CLUSTER STATUS WARNING: Could not retrieve cluster status"
        echo "🔍 DEBUG: Status error: $status_output"
    fi
    
    # Additional verification
    echo -e "\n🔍 DEBUG: Additional cluster verification..."
    echo "--- Node Status ---"
    podman exec "$container_name" rabbitmqctl status | grep -A 5 -B 5 "cluster_name\|partitions" || echo "Could not get detailed node status"
    
    echo -e "\n--- List Nodes ---"
    podman exec "$container_name" rabbitmqctl eval "rabbit_nodes:all_running()." 2>/dev/null || echo "Could not list running nodes"
}

# Apply quorum queue policy
policy() {
    local node_name="${1:-rmq1}"
    local container_name="rabbitmq-$node_name"
    
    echo "=== Applying quorum queue policy ==="
    
    # Verify container is running
    if ! podman container exists "$container_name"; then
        echo "❌ Container $container_name does not exist. Run: $0 up $node_name"
        exit 1
    fi
    
    if ! wait_for_container "$container_name" 30; then
        echo "❌ Container $container_name is not ready"
        exit 1
    fi
    
    # Apply the policy with correct JSON syntax for quorum queues
    echo "Setting quorum queue policy..."
    if podman exec "$container_name" rabbitmqctl set_policy \
        quorum-policy ".*" '{"queue-type":"quorum"}' \
        --priority 10 --apply-to queues; then
        echo "✅ Quorum queue policy applied successfully!"
    else
        echo "❌ Failed to apply quorum queue policy"
        exit 1
    fi
    
    echo -e "\n=== Current Policies ==="
    podman exec "$container_name" rabbitmqctl list_policies
}

# Show cluster status
status() {
    local node_name="${1:-rmq1}"
    local container_name="rabbitmq-$node_name"
    
    echo "=== RabbitMQ Cluster Status ==="
    
    if ! podman container exists "$container_name"; then
        echo "Error: Container $container_name does not exist"
        exit 1
    fi
    
    if ! podman exec "$container_name" rabbitmqctl status >/dev/null 2>&1; then
        echo "Error: RabbitMQ node $node_name is not running properly"
        exit 1
    fi
    
    echo "--- Node Status ---"
    podman exec "$container_name" rabbitmqctl status
    
    echo -e "\n--- Cluster Status ---"
    podman exec "$container_name" rabbitmqctl cluster_status
    
    echo -e "\n--- Queue Status ---"
    podman exec "$container_name" rabbitmqctl list_queues name policy
    
    echo -e "\n--- Node Health ---"
    podman exec "$container_name" rabbitmqctl node_health_check
}

# Stop and remove a node
down() {
    local node_name="$1"
    if [ -z "$node_name" ]; then
        echo "Usage: $0 down <node_name>"
        exit 1
    fi
    
    local container_name="rabbitmq-$node_name"
    
    echo "=== Stopping RabbitMQ node $node_name ==="
    
    podman stop "$container_name" 2>/dev/null || true
    podman rm "$container_name" 2>/dev/null || true
    
    echo "Node $node_name stopped and removed"
}

# Forcefully clean up everything for a node
force_cleanup() {
    local node_name="$1"
    local container_name="rabbitmq-$node_name"
    local data_dir="$HOME/.local/share/rabbitmq/$node_name"
    
    echo "🧹 === FORCE CLEANUP for RabbitMQ node $node_name ==="
    echo "🔍 DEBUG: Container name: $container_name"
    echo "🔍 DEBUG: Data directory: $data_dir"
    
    # Check if container exists
    if podman container exists "$container_name" 2>/dev/null; then
        local container_status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        echo "🔍 DEBUG: Container $container_name exists with status: $container_status"
        
        # Kill container if running
        if [ "$container_status" = "running" ]; then
            echo "🔍 DEBUG: Killing running container..."
            podman kill "$container_name" 2>/dev/null && echo "✅ Container killed" || echo "⚠️  Kill failed or container already stopped"
        fi
        
        # Stop container if still running
        echo "🔍 DEBUG: Ensuring container is stopped..."
        podman stop "$container_name" 2>/dev/null && echo "✅ Container stopped" || echo "⚠️  Stop failed or container already stopped"
        
        # Remove container forcefully
        echo "🔍 DEBUG: Removing container..."
        podman rm -f "$container_name" 2>/dev/null && echo "✅ Container removed" || echo "⚠️  Remove failed"
    else
        echo "🔍 DEBUG: Container $container_name does not exist (OK)"
    fi
    
    # Clean up any leftover processes
    echo "🔍 DEBUG: Checking for leftover RabbitMQ processes..."
    local rabbit_pids=$(pgrep -f "rabbitmq.*$node_name" 2>/dev/null || echo "")
    if [ -n "$rabbit_pids" ]; then
        echo "🔍 DEBUG: Found leftover processes: $rabbit_pids"
        pkill -f "rabbitmq.*$node_name" 2>/dev/null && echo "✅ Processes killed" || echo "⚠️  Process kill failed"
    else
        echo "🔍 DEBUG: No leftover processes found (OK)"
    fi
    
    # Remove data directory forcefully
    if [ -d "$data_dir" ]; then
        echo "🔍 DEBUG: Removing data directory: $data_dir"
        local dir_size=$(du -sh "$data_dir" 2>/dev/null | cut -f1 || echo "unknown")
        echo "🔍 DEBUG: Data directory size: $dir_size"
        
        # Try without sudo first
        if rm -rf "$data_dir" 2>/dev/null; then
            echo "✅ Data directory removed (no sudo needed)"
        else
            echo "🔍 DEBUG: Regular rm failed, trying with sudo..."
            sudo rm -rf "$data_dir" 2>/dev/null && echo "✅ Data directory removed (with sudo)" || echo "⚠️  Data directory removal failed"
        fi
    else
        echo "🔍 DEBUG: Data directory does not exist (OK)"
    fi
    
    # Remove any volumes associated with the container
    echo "🔍 DEBUG: Checking for associated volumes..."
    local volumes=$(podman volume ls -q 2>/dev/null | grep -E "(rabbitmq|$node_name)" || echo "")
    if [ -n "$volumes" ]; then
        echo "🔍 DEBUG: Found volumes: $volumes"
        echo "$volumes" | xargs -r podman volume rm -f 2>/dev/null && echo "✅ Volumes removed" || echo "⚠️  Volume removal failed"
    else
        echo "🔍 DEBUG: No associated volumes found (OK)"
    fi
    
    echo "✅ CLEANUP COMPLETE: Force cleanup finished for node $node_name"
    echo "🔍 DEBUG: You can now safely run: $0 up $node_name"
}

# Wipe all data for a node (enhanced)
wipe() {
    local node_name="$1"
    if [ -z "$node_name" ]; then
        echo "Usage: $0 wipe <node_name>"
        exit 1
    fi
    
    echo "=== Wiping data for RabbitMQ node $node_name ==="
    echo "This will permanently delete all data for $node_name!"
    read -p "Are you sure? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        force_cleanup "$node_name"
        echo "Data for node $node_name has been wiped"
    else
        echo "Cancelled"
    fi
}

# Clean up everything - all nodes and data
cleanup_all() {
    echo "=== COMPLETE CLEANUP - This will destroy ALL RabbitMQ data and containers ==="
    echo "This will remove:"
    echo "- All RabbitMQ containers (rmq1, rmq2, rmq3)"
    echo "- All RabbitMQ data directories"
    echo "- All RabbitMQ images"
    echo ""
    read -p "Are you ABSOLUTELY sure? Type 'YES' to confirm: " confirm
    
    if [ "$confirm" = "YES" ]; then
        echo "Performing complete cleanup..."
        
        # Force cleanup all nodes
        for node in rmq1 rmq2 rmq3; do
            echo "Cleaning up $node..."
            force_cleanup "$node"
        done
        
        # Remove any remaining RabbitMQ containers
        podman ps -a --filter ancestor=rabbitmq --format "{{.Names}}" | xargs -r podman rm -f 2>/dev/null || true
        
        # Remove RabbitMQ images
        podman images --filter reference=rabbitmq --format "{{.Repository}}:{{.Tag}}" | xargs -r podman rmi -f 2>/dev/null || true
        
        # Clean up base directory
        sudo rm -rf "$HOME/.local/share/rabbitmq" 2>/dev/null || true
        rm -rf "$HOME/.local/share/rabbitmq" 2>/dev/null || true
        
        # Prune containers and volumes
        podman container prune -f 2>/dev/null || true
        podman volume prune -f 2>/dev/null || true
        
        echo "Complete cleanup finished. You can now start fresh."
    else
        echo "Cleanup cancelled"
    fi
}

# Test network connectivity between all nodes
test_network() {
    echo "=== Testing network connectivity between all nodes ==="
    
    check_env
    
    local nodes=("rmq1:$RMQ1_HOST" "rmq2:$RMQ2_HOST" "rmq3:$RMQ3_HOST")
    local all_good=true
    
    for node_info in "${nodes[@]}"; do
        IFS=':' read -r node_name node_host <<< "$node_info"
        echo -e "\n--- Testing $node_name ($node_host) ---"
        
        if check_connectivity "$node_host" "$node_name"; then
            echo "✅ $node_name connectivity OK"
        else
            echo "❌ $node_name connectivity FAILED"
            all_good=false
        fi
    done
    
    echo -e "\n=== Network Test Summary ==="
    if $all_good; then
        echo "✅ All nodes are reachable and have open ports"
        echo "Ready for clustering!"
    else
        echo "❌ Some connectivity issues detected"
        echo "Fix network/firewall issues before clustering"
        exit 1
    fi
}

# Show help
show_help() {
    cat << EOF
RabbitMQ Cluster Management Script

Usage: $0 <command> [args]

Commands:
  prep                    - Install Podman and configure firewall
  up <node>              - Start a RabbitMQ node (rmq1, rmq2, or rmq3)
  join <node> <seed>     - Join a node to cluster via seed node
  policy                 - Apply quorum queue policy (run on rmq1)
  status [node]          - Show cluster status (default: rmq1)
  down <node>            - Stop and remove a node
  wipe <node>            - Completely wipe a node's data (WARNING: destructive!)
  cleanup-all            - Complete cleanup of everything (VERY destructive!)
  test-network           - Test network connectivity between all nodes
  debug [node]           - Show detailed debug information (useful for troubleshooting)

Examples:
  $0 prep                # Prepare system
  $0 up rmq1            # Start first node
  $0 up rmq2            # Start second node
  $0 join rmq2 rmq1     # Join rmq2 to cluster
  $0 policy             # Apply quorum queue policy
  $0 status             # Show cluster status
  $0 down rmq2          # Stop rmq2 node
  $0 wipe rmq2          # Wipe rmq2 data
  $0 cleanup-all        # Complete cleanup (DANGEROUS!)
  $0 test-network       # Test connectivity before clustering
  $0 debug              # Show system debug info
  $0 debug rmq1         # Show detailed info for rmq1

Note: Make sure to copy .env.example to .env and configure before use.
EOF
}

# Debug system state and configuration
debug() {
    local node_name="${1:-all}"
    
    echo "🔍 === SYSTEM DEBUG INFORMATION ==="
    echo "📅 Timestamp: $(date)"
    echo "💻 Hostname: $(hostname)"
    echo "🌐 IP Address: $(hostname -I | awk '{print $1}' || echo 'unknown')"
    echo "📁 Working Directory: $(pwd)"
    echo ""
    
    # Environment check
    echo "--- ENVIRONMENT ---"
    if [ -f ".env" ]; then
        echo "✅ .env file exists"
        check_env 2>/dev/null && echo "✅ All required variables set" || echo "❌ Environment variables missing or invalid"
    else
        echo "❌ .env file missing"
    fi
    echo ""
    
    # Container status
    echo "--- CONTAINER STATUS ---"
    local all_containers=$(podman ps -a --filter "name=rabbitmq-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
    if [ -n "$all_containers" ]; then
        echo "$all_containers"
    else
        echo "No RabbitMQ containers found"
    fi
    echo ""
    
    # Network connectivity
    if [ -f ".env" ]; then
        source .env 2>/dev/null
        echo "--- NETWORK CONNECTIVITY ---"
        for host_var in RMQ1_HOST RMQ2_HOST RMQ3_HOST; do
            local host_ip="${!host_var}"
            if [ -n "$host_ip" ]; then
                echo -n "Testing $host_var ($host_ip): "
                if ping -c 1 -W 2 "$host_ip" >/dev/null 2>&1; then
                    echo "✅ Reachable"
                else
                    echo "❌ Unreachable"
                fi
            fi
        done
        echo ""
    fi
    
    # Specific node debug
    if [ "$node_name" != "all" ] && [ "$node_name" != "" ]; then
        echo "--- NODE $node_name DETAILS ---"
        local container_name="rabbitmq-$node_name"
        local data_dir="$HOME/.local/share/rabbitmq/$node_name"
        
        echo "Container name: $container_name"
        echo "Data directory: $data_dir"
        
        if podman container exists "$container_name" 2>/dev/null; then
            echo "Container status: $(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null)"
            echo "Container image: $(podman inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null)"
            if [ "$(podman inspect "$container_name" --format '{{.State.Status}}')" = "running" ]; then
                echo "RabbitMQ status:"
                podman exec "$container_name" rabbitmqctl status 2>/dev/null | head -20 || echo "  Cannot get RabbitMQ status"
            fi
        else
            echo "❌ Container does not exist"
        fi
        
        if [ -d "$data_dir" ]; then
            echo "Data directory size: $(du -sh "$data_dir" 2>/dev/null | cut -f1)"
            echo "Data directory contents: $(ls -la "$data_dir" 2>/dev/null | wc -l) files"
        else
            echo "❌ Data directory does not exist"
        fi
    fi
    
    echo "🔍 Debug information complete. Use this info for troubleshooting."
}

# Main command dispatcher
case "${1:-help}" in
    prep) prep ;;
    up) up "$2" ;;
    join) join "$2" "$3" ;;
    policy) policy "$2" ;;
    status) status "$2" ;;
    down) down "$2" ;;
    wipe) wipe "$2" ;;
    cleanup-all) cleanup_all ;;
    test-network) test_network ;;
    debug) debug "$2" ;;
    help) show_help ;;
    *) echo "Unknown command: $1"; show_help; exit 1 ;;
esac