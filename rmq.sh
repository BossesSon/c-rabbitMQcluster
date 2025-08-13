#!/bin/bash
set -e

# RabbitMQ Cluster Management Script for Rocky Linux 8 with Podman
# Usage: ./rmq.sh <command> [args]
# Commands: prep, up, join, policy, status, down, wipe

# Load environment variables
if [ -f ".env" ]; then
    source .env
else
    echo "Error: .env file not found. Copy .env.example to .env and configure."
    exit 1
fi

# Validate required environment variables
check_env() {
    local vars=("RABBITMQ_IMAGE" "RABBITMQ_ADMIN_USER" "RABBITMQ_ADMIN_PASSWORD" "ERLANG_COOKIE" "RMQ1_HOST" "RMQ2_HOST" "RMQ3_HOST")
    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "Error: $var is not set in .env file"
            exit 1
        fi
    done
}

# Get node hostname based on current server
get_node_name() {
    local current_host=$(hostname -I | awk '{print $1}')
    case "$current_host" in
        "$RMQ1_HOST") echo "rabbit@rmq1" ;;
        "$RMQ2_HOST") echo "rabbit@rmq2" ;;
        "$RMQ3_HOST") echo "rabbit@rmq3" ;;
        *) echo "rabbit@$(hostname -s)" ;;
    esac
}

# Prepare system - install Podman and configure firewall
prep() {
    echo "=== Preparing Rocky Linux 8 for RabbitMQ cluster ==="
    
    # Install Podman
    echo "Installing Podman..."
    sudo dnf update -y
    sudo dnf install -y podman firewalld
    
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
    
    # Create data directory
    mkdir -p "$data_dir"
    
    # Copy rabbitmq.conf to data directory
    if [ -f "rabbitmq.conf" ]; then
        cp rabbitmq.conf "$data_dir/"
    else
        echo "Warning: rabbitmq.conf not found, using default configuration"
    fi
    
    echo "=== Starting RabbitMQ node $node_name ==="
    
    # Force cleanup any existing container/processes
    force_cleanup "$node_name"
    
    # Start RabbitMQ container
    podman run -d \
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
        "$RABBITMQ_IMAGE"
    
    echo "Waiting for RabbitMQ to start..."
    sleep 10
    
    # Wait for RabbitMQ to be ready
    local retries=30
    while [ $retries -gt 0 ]; do
        if podman exec "$container_name" rabbitmqctl status >/dev/null 2>&1; then
            echo "RabbitMQ node $node_name is ready!"
            echo "Management UI: http://$node_host:15672"
            echo "Login: $RABBITMQ_ADMIN_USER / $RABBITMQ_ADMIN_PASSWORD"
            return 0
        fi
        echo "Waiting for RabbitMQ to be ready... ($retries retries left)"
        sleep 2
        ((retries--))
    done
    
    echo "Error: RabbitMQ failed to start properly"
    podman logs "$container_name" | tail -20
    exit 1
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
    
    local container_name="rabbitmq-$node_name"
    local seed_nodename="rabbit@$seed_node"
    
    echo "=== Joining $node_name to cluster via $seed_node ==="
    
    # Stop the app
    podman exec "$container_name" rabbitmqctl stop_app
    
    # Reset the node
    podman exec "$container_name" rabbitmqctl reset
    
    # Join cluster
    podman exec "$container_name" rabbitmqctl join_cluster "$seed_nodename"
    
    # Start the app
    podman exec "$container_name" rabbitmqctl start_app
    
    echo "Node $node_name has joined the cluster!"
    
    # Show cluster status
    sleep 2
    podman exec "$container_name" rabbitmqctl cluster_status
}

# Apply quorum queue policy
policy() {
    local node_name="${1:-rmq1}"
    local container_name="rabbitmq-$node_name"
    
    echo "=== Applying quorum queue policy ==="
    
    podman exec "$container_name" rabbitmqctl set_policy \
        quorum-policy ".*" '{"ha-mode":"all","queue-type":"quorum","ha-sync-mode":"automatic"}' \
        --priority 10 --apply-to queues
    
    echo "Quorum queue policy applied successfully!"
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
    
    echo "=== Force cleanup for RabbitMQ node $node_name ==="
    
    # Kill container if running
    podman kill "$container_name" 2>/dev/null || true
    
    # Stop container if still running
    podman stop "$container_name" 2>/dev/null || true
    
    # Remove container forcefully
    podman rm -f "$container_name" 2>/dev/null || true
    
    # Clean up any leftover processes
    pkill -f "rabbitmq.*$node_name" 2>/dev/null || true
    
    # Remove data directory forcefully
    sudo rm -rf "$data_dir" 2>/dev/null || true
    rm -rf "$data_dir" 2>/dev/null || true
    
    # Remove any volumes associated with the container
    podman volume ls -q | grep -E "(rabbitmq|$node_name)" | xargs -r podman volume rm -f 2>/dev/null || true
    
    echo "Force cleanup completed for node $node_name"
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

Note: Make sure to copy .env.example to .env and configure before use.
EOF
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
    help) show_help ;;
    *) echo "Unknown command: $1"; show_help; exit 1 ;;
esac