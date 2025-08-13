#!/bin/bash
set -e

# RabbitMQ Cluster Management Script for Rocky Linux 8 with Podman
# Usage: ./rmq.sh <command> [args]
# Commands: prep, up, join, policy, status, down, wipe

# Load environment variables
if [ -f ".env" ]; then
    source .env
else
    echo "❌ .env file not found"
    echo "Copy .env.example to .env and configure:"
    echo "  cp .env.example .env"
    echo "  nano .env"
    exit 1
fi

# Validate required environment variables
check_env() {
    local vars=("RABBITMQ_IMAGE" "RABBITMQ_ADMIN_USER" "RABBITMQ_ADMIN_PASSWORD" "ERLANG_COOKIE" "RMQ1_HOST" "RMQ2_HOST" "RMQ3_HOST")
    local missing_vars=()
    
    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "❌ Missing: $var"
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "Add these to .env file:"
        for var in "${missing_vars[@]}"; do
            echo "  $var=<value>"
        done
        exit 1
    fi
}

# Get node hostname based on current server
get_node_name() {
    local current_host=$(hostname -I | awk '{print $1}' || echo "unknown")
    
    case "$current_host" in
        "$RMQ1_HOST") echo "rabbit@rmq1" ;;
        "$RMQ2_HOST") echo "rabbit@rmq2" ;;
        "$RMQ3_HOST") echo "rabbit@rmq3" ;;
        *) echo "rabbit@$(hostname -s)" ;;
    esac
}

# Check network connectivity between nodes
check_connectivity() {
    local target_host="$1"
    local target_name="$2"
    
    # Check if host is reachable
    if ! ping -c 1 -W 2 "$target_host" >/dev/null 2>&1; then
        echo "❌ Cannot reach $target_name at $target_host"
        return 1
    fi
    
    # Check required ports
    local ports=(5672 4369 25672 15672)
    for port in "${ports[@]}"; do
        if ! timeout 3 bash -c "echo >/dev/tcp/$target_host/$port" 2>/dev/null; then
            echo "❌ Port $port not accessible on $target_name"
            return 1
        fi
    done
    
    echo "✅ $target_name connectivity OK"
    return 0
}

# Wait for container to be ready
wait_for_container() {
    local container_name="$1"
    local max_wait="${2:-60}"
    local check_interval=2
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        if ! podman container exists "$container_name"; then
            echo "❌ Container $container_name missing"
            return 1
        fi
        
        local container_status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        if [ "$container_status" != "running" ]; then
            echo "❌ Container $container_name is $container_status"
            return 1
        fi
        
        if podman exec "$container_name" rabbitmqctl status >/dev/null 2>&1; then
            echo "✅ Container $container_name ready"
            return 0
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        echo "⏳ Waiting... ($elapsed/${max_wait}s)"
    done
    
    echo "❌ Container $container_name timeout after ${max_wait}s"
    return 1
}

# Prepare system - install Podman and configure firewall
prep() {
    echo "=== Preparing Rocky Linux 8 for RabbitMQ cluster ==="
    
    # Install Podman and required tools
    echo "Installing Podman and dependencies..."
    sudo dnf update -y
    sudo dnf install -y podman firewalld curl dos2unix
    echo "✅ Installation complete"
    
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
    echo "Starting $container_name ($node_host)"
    
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
        echo "✅ Container started"
    else
        echo "❌ Container start failed"
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
    if ! podman container exists "$container_name"; then
        echo "❌ Container $container_name missing. Run: $0 up $node_name"
        exit 1
    fi
    
    local container_status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [ "$container_status" != "running" ]; then
        echo "❌ Container $container_name is $container_status"
        exit 1
    fi
    echo "✅ Local container ready"
    
    echo "Joining $node_name → $seed_node ($seed_host)"
    
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
    
    # Test seed node accessibility
    local max_wait=30
    local wait_time=0
    
    while [ $wait_time -lt $max_wait ]; do
        if timeout 3 bash -c "echo >/dev/tcp/$seed_host/15672" 2>/dev/null; then
            echo "✅ Seed node accessible"
            break
        fi
        echo "⏳ Waiting for seed... ($wait_time/${max_wait}s)"
        sleep 2
        wait_time=$((wait_time + 2))
    done
    
    if [ $wait_time -ge $max_wait ]; then
        echo "⚠️  Seed not responding, proceeding anyway"
    fi
    
    # Test Erlang connectivity
    local erlang_result
    erlang_result=$(podman exec "$container_name" rabbitmqctl eval "net_adm:ping('$seed_nodename')." 2>&1)
    
    if echo "$erlang_result" | grep -q "pong"; then
        echo "✅ Erlang ping OK"
    else
        echo "⚠️  Erlang ping failed (may be normal)"
    fi
    
    # Stop the app
    echo "Stopping RabbitMQ app..."
    local retries=3
    while [ $retries -gt 0 ]; do
        if podman exec "$container_name" rabbitmqctl stop_app 2>/dev/null; then
            echo "✅ App stopped"
            break
        fi
        echo "Retrying stop_app... ($retries left)"
        sleep 2
        ((retries--))
    done
    
    # Reset the node
    echo "Resetting node..."
    if podman exec "$container_name" rabbitmqctl reset >/dev/null 2>&1; then
        echo "✅ Node reset"
    else
        echo "❌ Reset failed"
        exit 1
    fi
    
    # Join cluster
    echo "Joining cluster..."
    retries=3
    while [ $retries -gt 0 ]; do
        local join_output
        join_output=$(podman exec "$container_name" rabbitmqctl join_cluster "$seed_nodename" 2>&1)
        
        if [ $? -eq 0 ]; then
            echo "✅ Joined cluster successfully"
            break
        fi
        
        if [ $retries -eq 1 ]; then
            echo "❌ Join failed after retries"
            echo "Error: $join_output"
            echo "Check: ERLANG_COOKIE, network ports 4369/25672/5672, seed node running"
            exit 1
        fi
        
        echo "Retrying join... ($retries left)"
        sleep 5
        ((retries--))
    done
    
    # Start the app
    echo "Starting RabbitMQ app..."
    if podman exec "$container_name" rabbitmqctl start_app >/dev/null 2>&1; then
        echo "✅ App started"
    else
        echo "❌ App start failed"
        exit 1
    fi
    
    echo "✅ Node $node_name has joined the cluster!"
    
    # Wait a moment for cluster to stabilize
    sleep 3
    
    # Show cluster status
    echo -e "\n=== Cluster Status ==="
    if podman exec "$container_name" rabbitmqctl cluster_status; then
        echo "✅ Join complete"
    else
        echo "⚠️  Could not get cluster status"
    fi
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
    
    # Apply quorum queue policy
    echo "Setting quorum queue policy..."
    
    # First check RabbitMQ version and cluster status
    echo "Checking RabbitMQ version..."
    local version_output
    version_output=$(podman exec "$container_name" rabbitmqctl version 2>/dev/null)
    echo "Version: $version_output"
    
    echo "Checking cluster status..."
    local cluster_output
    cluster_output=$(timeout 10 podman exec "$container_name" rabbitmqctl cluster_status 2>&1)
    local cluster_exit_code=$?
    
    if [ $cluster_exit_code -eq 124 ]; then
        echo "⚠️  Cluster status check timed out - RabbitMQ may be starting"
    elif [ $cluster_exit_code -ne 0 ] || echo "$cluster_output" | grep -q "Error\|failed"; then
        echo "❌ Cluster issue:"
        echo "$cluster_output"
        echo "Trying policy anyway..."
    else
        echo "✅ Cluster status OK"
    fi
    
    # First try a simple policy test
    echo "Testing rabbitmqctl responsiveness..."
    if ! timeout 5 podman exec "$container_name" rabbitmqctl list_policies >/dev/null 2>&1; then
        echo "❌ RabbitMQ not responding to commands"
        exit 1
    fi
    echo "✅ RabbitMQ responding"
    
    # Try the policy command with shorter timeout first
    echo "Applying quorum policy (timeout 10s)..."
    local policy_output
    if policy_output=$(timeout 10 podman exec "$container_name" rabbitmqctl set_policy quorum-policy ".*" '{"x-queue-type":"quorum"}' --priority 10 --apply-to queues 2>&1); then
        echo "✅ Quorum policy applied successfully!"
        echo "$policy_output"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "❌ Policy command timed out"
        else
            echo "❌ Policy failed:"
            echo "$policy_output"
            
            # Try fallback to classic HA policy
            echo ""
            echo "Trying classic HA policy as fallback..."
            if podman exec "$container_name" rabbitmqctl set_policy ha-all ".*" '{"ha-mode":"all"}' --priority 5 --apply-to queues 2>&1; then
                echo "✅ Classic HA policy applied as fallback"
            else
                echo "❌ Both policies failed"
            fi
        fi
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
    
    echo "=== Force cleanup: $node_name ==="
    
    # Check if container exists
    if podman container exists "$container_name" 2>/dev/null; then
        local container_status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        echo "Container status: $container_status"
        
        # Kill container if running
        if [ "$container_status" = "running" ]; then
            podman kill "$container_name" 2>/dev/null && echo "✅ Killed" || echo "⚠️  Kill failed"
        fi
        
        # Stop container if still running
        podman stop "$container_name" 2>/dev/null && echo "✅ Stopped" || echo "⚠️  Stop failed"
        
        # Remove container forcefully
        podman rm -f "$container_name" 2>/dev/null && echo "✅ Removed" || echo "⚠️  Remove failed"
    else
        echo "Container doesn't exist (OK)"
    fi
    
    # Clean up any leftover processes
    local rabbit_pids=$(pgrep -f "rabbitmq.*$node_name" 2>/dev/null || echo "")
    if [ -n "$rabbit_pids" ]; then
        pkill -f "rabbitmq.*$node_name" 2>/dev/null && echo "✅ Processes killed" || echo "⚠️  Process kill failed"
    fi
    
    # Remove data directory forcefully
    if [ -d "$data_dir" ]; then
        if rm -rf "$data_dir" 2>/dev/null; then
            echo "✅ Data removed"
        else
            sudo rm -rf "$data_dir" 2>/dev/null && echo "✅ Data removed (sudo)" || echo "⚠️  Data removal failed"
        fi
    fi
    
    # Remove any volumes associated with the container
    local volumes=$(podman volume ls -q 2>/dev/null | grep -E "(rabbitmq|$node_name)" || echo "")
    if [ -n "$volumes" ]; then
        echo "$volumes" | xargs -r podman volume rm -f 2>/dev/null && echo "✅ Volumes removed" || echo "⚠️  Volume removal failed"
    fi
    
    echo "✅ Cleanup complete for $node_name"
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