#!/usr/bin/env bash
################################################################################
# RabbitMQ Ultra-Short Management Script - EDUCATIONAL VERSION
################################################################################
#
# This is a simplified version of rmq.sh designed for LEARNING.
# It has minimal error checking but DETAILED EXPLANATIONS of what each line does.
#
# USAGE:
#   ./rmq_ultra_short.sh up rmq1              # Start node 1
#   ./rmq_ultra_short.sh down rmq1            # Stop node 1
#   ./rmq_ultra_short.sh join rmq2 rmq1       # Join node 2 to node 1's cluster
#   ./rmq_ultra_short.sh status               # Check all nodes
#   ./rmq_ultra_short.sh policy               # Apply quorum queue policy
#   ./rmq_ultra_short.sh wipe rmq1            # Delete all node 1 data
#
################################################################################

################################################################################
# HELPER FUNCTION: Load environment variables
################################################################################

load_env() {
    # The .env file contains configuration like:
    # - RMQ1_HOST=172.23.12.11        (IP addresses of servers)
    # - RABBITMQ_ADMIN_USER=admin     (credentials)
    # - ERLANG_COOKIE=secret123       (shared secret for cluster)

    # Check if .env file exists in current directory
    if [[ ! -f .env ]]; then
        echo "ERROR: .env file not found!"
        echo "Copy .env.example to .env first"
        exit 1
    fi

    # Source means "execute this file and import its variables into current shell"
    # This makes RMQ1_HOST, RMQ2_HOST, etc. available in this script
    source .env
}

################################################################################
# COMMAND: up - Start a RabbitMQ node
################################################################################
#
# What this does:
# 1. Creates a directory to store RabbitMQ data (messages, queue info, etc.)
# 2. Fixes permissions so RabbitMQ can write to that directory
# 3. Starts a Podman container running RabbitMQ
# 4. Container uses "host" network so it can talk to other nodes directly
#
################################################################################

cmd_up() {
    local node_name=$1  # e.g., "rmq1", "rmq2", "rmq3"

    echo "Starting RabbitMQ node: $node_name"

    # -------------------------------------------------------------------------
    # STEP 1: Create data directory
    # -------------------------------------------------------------------------
    # RabbitMQ needs to store:
    # - Message data (the actual message content)
    # - Queue metadata (queue names, settings, bindings)
    # - Mnesia database (Erlang's database system for cluster info)
    #
    # We create this directory on the HOST machine, then mount it into the container.
    # This way, data persists even if the container is deleted.

    local data_dir="/var/lib/rabbitmq/$node_name"

    # Create directory if it doesn't exist
    # -p means "create parent directories if needed" (like mkdir -p /a/b/c creates /a, /a/b, and /a/b/c)
    sudo mkdir -p "$data_dir"

    # -------------------------------------------------------------------------
    # STEP 2: Fix permissions
    # -------------------------------------------------------------------------
    # RabbitMQ container runs as user ID 999 and group ID 999 inside the container.
    # We need to make sure that user can read/write to our data directory.
    #
    # $(id -u) = your user ID (e.g., 1000)
    # $(id -g) = your group ID (e.g., 1000)
    #
    # We use your IDs because you're running Podman in "rootless" mode
    # (containers run as your user, not as root)

    sudo chown -R $(id -u):$(id -g) "$data_dir"

    # -------------------------------------------------------------------------
    # STEP 3: Start the container
    # -------------------------------------------------------------------------

    podman run -d \
        --name "$node_name" \
        --hostname "$node_name" \
        --network host \
        -v "$data_dir:/var/lib/rabbitmq:Z" \
        -v "$(pwd)/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro,Z" \
        -e RABBITMQ_ERLANG_COOKIE="$ERLANG_COOKIE" \
        -e RABBITMQ_NODENAME="rabbit@$node_name" \
        docker.io/rabbitmq:3.13-management

    # Let's explain EVERY flag:
    #
    # podman run          = Start a new container
    # -d                  = Detached mode (run in background, don't block terminal)
    # --name "$node_name" = Give container a friendly name (rmq1, rmq2, etc.)
    #                       This lets you do "podman logs rmq1" instead of using a random ID
    #
    # --hostname "$node_name"
    #                     = Set the hostname INSIDE the container to "rmq1"
    #                       RabbitMQ uses this to identify itself in the cluster
    #                       Node will be known as "rabbit@rmq1" in cluster
    #
    # --network host      = Use the HOST's network directly (not a separate container network)
    #                       This means:
    #                       - Container's port 5672 = Host's port 5672 (no port mapping needed)
    #                       - Container can reach other hosts by their IPs directly
    #                       - CRITICAL for RabbitMQ clustering!
    #
    # -v "$data_dir:/var/lib/rabbitmq:Z"
    #                     = Volume mount: Connect host directory to container directory
    #                       Format: HOST_PATH:CONTAINER_PATH:OPTIONS
    #                       - HOST_PATH: /var/lib/rabbitmq/rmq1 (on your server)
    #                       - CONTAINER_PATH: /var/lib/rabbitmq (inside container)
    #                       - Z: SELinux label (needed on Rocky Linux for security)
    #                       RabbitMQ writes to /var/lib/rabbitmq inside the container,
    #                       which actually writes to /var/lib/rabbitmq/rmq1 on your host.
    #
    # -v "$(pwd)/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro,Z"
    #                     = Mount our config file into the container
    #                       - $(pwd) = current directory (/root/c#rabbitMQcluster)
    #                       - ro = read-only (container can't modify our config file)
    #                       - Z = SELinux label again
    #                       This is how we customize RabbitMQ's settings!
    #
    # -e RABBITMQ_ERLANG_COOKIE="$ERLANG_COOKIE"
    #                     = Set environment variable inside container
    #                       Erlang cookie is a SHARED SECRET for cluster authentication.
    #                       Think of it like a password - all nodes MUST have the same cookie
    #                       to join the cluster. If cookies don't match, nodes can't communicate.
    #
    # -e RABBITMQ_NODENAME="rabbit@$node_name"
    #                     = Set RabbitMQ's node name
    #                       Format: rabbit@HOSTNAME
    #                       Examples: rabbit@rmq1, rabbit@rmq2, rabbit@rmq3
    #                       This is the IDENTITY of the node in the cluster.
    #
    # docker.io/rabbitmq:3.13-management
    #                     = The Docker image to run
    #                       - docker.io = Docker Hub registry
    #                       - rabbitmq = official RabbitMQ image
    #                       - 3.13 = RabbitMQ version 3.13
    #                       - management = includes web UI on port 15672

    echo "Waiting for RabbitMQ to start..."
    sleep 5

    # At this point, RabbitMQ is starting up inside the container.
    # It will:
    # 1. Read /etc/rabbitmq/rabbitmq.conf for configuration
    # 2. Initialize /var/lib/rabbitmq with database files (if first run)
    # 3. Start listening on port 5672 (AMQP) and 15672 (Management UI)
    # 4. Look for other nodes listed in cluster_formation.classic_config.nodes
    #    (but it won't JOIN them automatically - we use "join" command for that)

    echo "Node $node_name started!"
    echo "Management UI: http://localhost:15672 (if on this server)"
}

################################################################################
# COMMAND: down - Stop a RabbitMQ node
################################################################################
#
# What this does:
# 1. Gracefully stops the RabbitMQ application inside the container
# 2. Stops the container itself
#
# This is SAFE - data is preserved in /var/lib/rabbitmq/$node_name
# When you run "up" again, it will reload all messages and queues.
#
################################################################################

cmd_down() {
    local node_name=$1

    echo "Stopping RabbitMQ node: $node_name"

    # Stop the container gracefully
    # Podman sends SIGTERM signal to RabbitMQ, giving it time to:
    # - Finish processing current messages
    # - Save queue state to disk
    # - Close connections cleanly
    #
    # If container doesn't stop in 10 seconds, Podman sends SIGKILL (force quit)

    podman stop "$node_name"

    echo "Node $node_name stopped"
}

################################################################################
# COMMAND: join - Join a node to an existing cluster
################################################################################
#
# What this does:
# 1. Stops RabbitMQ app on the joining node (but keeps container running)
# 2. Tells the node to join the target node's cluster
# 3. Restarts RabbitMQ app with the new cluster membership
#
# IMPORTANT: This is how clustering happens!
# - Node must be RUNNING (via "up" command)
# - Target node must be RUNNING
# - Both nodes must have SAME Erlang cookie
# - Both nodes must be able to reach each other on port 25672 (inter-node communication)
#
################################################################################

cmd_join() {
    local node_name=$1      # The node we want to add to cluster (e.g., rmq2)
    local target_node=$2    # The node already in cluster (e.g., rmq1)

    echo "Joining $node_name to $target_node's cluster..."

    # -------------------------------------------------------------------------
    # STEP 1: Stop RabbitMQ app (but keep Erlang VM running)
    # -------------------------------------------------------------------------
    # "rabbitmqctl stop_app" stops ONLY the RabbitMQ application, not Erlang.
    # Think of it like:
    # - Erlang VM = the operating system
    # - RabbitMQ app = the application running on that OS
    #
    # We need Erlang running so it can communicate with the target node
    # to negotiate cluster membership.

    podman exec "$node_name" rabbitmqctl stop_app

    # What happens:
    # - All client connections are closed
    # - Queue state is saved to disk
    # - Node is now in "down" state but Erlang is still listening on port 25672

    # -------------------------------------------------------------------------
    # STEP 2: Reset node to clean state
    # -------------------------------------------------------------------------
    # This removes the node from any previous cluster it might have been in.
    # If this is the first time joining, this does nothing (node is already clean).

    podman exec "$node_name" rabbitmqctl reset

    # -------------------------------------------------------------------------
    # STEP 3: Join the cluster
    # -------------------------------------------------------------------------
    # This is the magic command!
    # It tells rabbit@rmq2 to join the cluster that rabbit@rmq1 is in.

    podman exec "$node_name" rabbitmqctl join_cluster "rabbit@$target_node"

    # What happens internally:
    # 1. Erlang on rmq2 connects to Erlang on rmq1 (port 25672)
    # 2. They verify Erlang cookies match (security check)
    # 3. rmq1 shares the cluster membership list (e.g., "rmq1 and rmq3 are in this cluster")
    # 4. rmq2 updates its own membership to include all nodes
    # 5. Cluster metadata is synchronized (users, vhosts, policies, etc.)
    #
    # NOTE: Queue data is NOT copied! Quorum queues will replicate automatically,
    # but classic queues stay on their original node.

    # -------------------------------------------------------------------------
    # STEP 4: Start RabbitMQ app again
    # -------------------------------------------------------------------------
    # Now that we're in the cluster, start accepting client connections again.

    podman exec "$node_name" rabbitmqctl start_app

    # What happens:
    # - RabbitMQ starts listening on port 5672 (AMQP) and 15672 (Management UI)
    # - Joins cluster gossip protocol (shares health status with other nodes)
    # - Becomes available for client connections
    # - If there are quorum queues, it will become a replica for them

    echo "Node $node_name joined the cluster!"

    # -------------------------------------------------------------------------
    # Understanding cluster topology:
    # -------------------------------------------------------------------------
    # After running:
    #   ./rmq_ultra_short.sh up rmq1
    #   ./rmq_ultra_short.sh up rmq2
    #   ./rmq_ultra_short.sh join rmq2 rmq1
    #
    # You have:
    #   rmq1 (standalone) → rmq1 + rmq2 (cluster of 2)
    #
    # To add rmq3:
    #   ./rmq_ultra_short.sh up rmq3
    #   ./rmq_ultra_short.sh join rmq3 rmq1   (or rmq2, doesn't matter!)
    #
    # Result:
    #   rmq1 + rmq2 + rmq3 (cluster of 3)
    #
    # All nodes know about each other. If rmq1 goes down, rmq2 and rmq3
    # continue operating (assuming quorum queues are being used).
}

################################################################################
# COMMAND: status - Check cluster status
################################################################################
#
# What this does:
# 1. Shows which containers are running
# 2. For each running node, shows cluster membership
#
# This is useful to verify:
# - Are all nodes running?
# - Are they all in the same cluster?
# - Which node is the "disc" node (stores metadata)?
#
################################################################################

cmd_status() {
    echo "Checking RabbitMQ cluster status..."
    echo ""

    # Loop through the 3 nodes we expect
    for node in rmq1 rmq2 rmq3; do
        echo "--- Node: $node ---"

        # Check if container is running
        # "podman ps" lists running containers
        # We use "grep -q" to quietly search for our node name
        # -q means "quiet" - don't output anything, just return success/failure

        if podman ps | grep -q "$node"; then
            echo "Status: RUNNING"

            # Get cluster status from this node
            # "rabbitmqctl cluster_status" outputs:
            # - Which nodes are in the cluster
            # - Which nodes are currently online
            # - Which node this is (the one we're querying)

            podman exec "$node" rabbitmqctl cluster_status
        else
            echo "Status: STOPPED"
        fi

        echo ""
    done

    # -------------------------------------------------------------------------
    # Understanding the output:
    # -------------------------------------------------------------------------
    # You'll see something like:
    #
    # Cluster status of node rabbit@rmq1 ...
    # Basics
    #
    # Cluster name: rabbit@rmq1
    #
    # Disk Nodes      ← Nodes that store cluster metadata
    #
    # rabbit@rmq1
    # rabbit@rmq2
    # rabbit@rmq3
    #
    # Running Nodes   ← Nodes currently online
    #
    # rabbit@rmq1
    # rabbit@rmq2
    # rabbit@rmq3
    #
    # If "Running Nodes" is missing a node, it means that node is down or
    # can't communicate with the cluster (network issue, wrong Erlang cookie, etc.)
}

################################################################################
# COMMAND: policy - Apply quorum queue policy
################################################################################
#
# What this does:
# 1. Creates a policy named "ha-all"
# 2. Policy applies to ALL queues (pattern ".*")
# 3. Sets queue-type to "quorum" (replicated across all nodes)
# 4. Sets replication factor to 3 (3 copies of each message)
#
# WHY?
# - Quorum queues are HIGHLY AVAILABLE
# - If one node dies, messages are still available on other nodes
# - Automatic leader election (if leader dies, a follower becomes leader)
# - Safer than classic queues for production use
#
################################################################################

cmd_policy() {
    echo "Applying quorum queue policy..."

    # We run this command on rmq1, but it applies cluster-wide
    # (policies are replicated to all nodes automatically)

    podman exec rmq1 rabbitmqctl set_policy ha-all ".*" \
        '{"queue-type":"quorum","max-length-bytes":10000000000}' \
        --priority 1 \
        --apply-to queues

    # Let's break down this command:
    #
    # rabbitmqctl set_policy
    #                     = Create or update a policy
    #
    # ha-all              = Policy name (you can choose any name)
    #                       "ha" = high availability
    #
    # ".*"                = Pattern that matches queue names
    #                       ".*" is a regex meaning "match any queue name"
    #                       Examples of patterns:
    #                       - "^load_test.*" = queues starting with "load_test"
    #                       - ".*_important$" = queues ending with "_important"
    #
    # '{"queue-type":"quorum","max-length-bytes":10000000000}'
    #                     = Policy definition (JSON)
    #                       - queue-type: quorum = Use quorum queues (not classic)
    #                       - max-length-bytes: 10GB = Limit queue size to 10GB
    #                         (if queue grows beyond this, oldest messages are dropped)
    #
    # --priority 1        = Policy priority (if multiple policies match, higher number wins)
    #                       Priority 1 is pretty low - useful as a default
    #
    # --apply-to queues   = Apply to queues (not exchanges or other objects)

    echo "Policy applied!"

    # -------------------------------------------------------------------------
    # What happens now:
    # -------------------------------------------------------------------------
    # - New queues automatically become quorum queues
    # - Existing classic queues are NOT converted (you'd need to delete and recreate them)
    # - Quorum queues are replicated across all 3 nodes
    # - Each message is stored 3 times (one per node)
    # - If rmq1 dies, rmq2 or rmq3 takes over as leader for queues hosted on rmq1
    #
    # Trade-offs:
    # - Quorum queues are SLOWER than classic queues (3x writes instead of 1x)
    # - Quorum queues use MORE DISK (3x storage instead of 1x)
    # - Quorum queues are SAFER (survive node failures)
}

################################################################################
# COMMAND: wipe - Delete all data for a node
################################################################################
#
# What this does:
# 1. Stops the container
# 2. Removes the container (but not the data)
# 3. Deletes the data directory on the host
#
# ⚠️  DANGEROUS! This PERMANENTLY deletes:
# - All messages on this node
# - All queues hosted on this node (if classic queues)
# - All cluster metadata (if this was the last node)
#
# USE CASES:
# - Node is corrupted and won't start
# - Testing fresh installation
# - Removing a node from cluster permanently
#
################################################################################

cmd_wipe() {
    local node_name=$1

    echo "⚠️  WARNING: This will DELETE ALL DATA for $node_name!"
    echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
    sleep 5

    echo "Wiping $node_name..."

    # -------------------------------------------------------------------------
    # STEP 1: Stop and remove container
    # -------------------------------------------------------------------------

    # Stop container (if running)
    podman stop "$node_name" 2>/dev/null || true
    # "2>/dev/null" = hide error messages if container doesn't exist
    # "|| true" = don't exit script if command fails (keep going)

    # Remove container
    podman rm "$node_name" 2>/dev/null || true

    # -------------------------------------------------------------------------
    # STEP 2: Delete data directory
    # -------------------------------------------------------------------------

    local data_dir="/var/lib/rabbitmq/$node_name"

    # Remove entire directory and everything in it
    # -rf means:
    # - r = recursive (delete subdirectories too)
    # - f = force (don't ask for confirmation)

    sudo rm -rf "$data_dir"

    echo "Node $node_name wiped!"
    echo "Run './rmq_ultra_short.sh up $node_name' to create fresh node"

    # -------------------------------------------------------------------------
    # What happens if you wipe a cluster node:
    # -------------------------------------------------------------------------
    # Scenario 1: Wipe rmq1 while rmq2 and rmq3 are running
    # - rmq2 and rmq3 continue operating
    # - Quorum queues remain available (they have copies on rmq2 and rmq3)
    # - When you start rmq1 again and join it, it becomes a fresh node
    #   and gets new copies of quorum queues automatically
    #
    # Scenario 2: Wipe rmq1 when it's the ONLY node
    # - You just deleted everything (all messages, all queues, all users except admin)
    # - You'll need to reconfigure from scratch
    #
    # Scenario 3: Wipe all 3 nodes
    # - Complete cluster destruction
    # - Like starting from scratch
    # - Useful for testing
}

################################################################################
# MAIN: Command dispatcher
################################################################################
#
# This is the entry point when you run the script.
# It loads the .env file, then calls the appropriate command function
# based on what you typed.
#
################################################################################

# Load environment variables first (needed by all commands)
load_env

# Get the command (first argument)
COMMAND=$1

# Use "case" statement to match command and call appropriate function
# This is like "switch" in other languages
case "$COMMAND" in
    up)
        # Example: ./rmq_ultra_short.sh up rmq1
        # $1 = "up", $2 = "rmq1"
        # We pass $2 (the node name) to cmd_up function
        cmd_up "$2"
        ;;

    down)
        # Example: ./rmq_ultra_short.sh down rmq1
        cmd_down "$2"
        ;;

    join)
        # Example: ./rmq_ultra_short.sh join rmq2 rmq1
        # $2 = rmq2 (node to join), $3 = rmq1 (target)
        cmd_join "$2" "$3"
        ;;

    status)
        # Example: ./rmq_ultra_short.sh status
        cmd_status
        ;;

    policy)
        # Example: ./rmq_ultra_short.sh policy
        cmd_policy
        ;;

    wipe)
        # Example: ./rmq_ultra_short.sh wipe rmq1
        cmd_wipe "$2"
        ;;

    *)
        # If command doesn't match any of the above, show usage
        echo "RabbitMQ Ultra-Short Management Script"
        echo ""
        echo "Usage:"
        echo "  $0 up <node>              Start a node (rmq1, rmq2, or rmq3)"
        echo "  $0 down <node>            Stop a node"
        echo "  $0 join <node> <target>   Join node to target's cluster"
        echo "  $0 status                 Show cluster status"
        echo "  $0 policy                 Apply quorum queue policy"
        echo "  $0 wipe <node>            Delete all data (DANGEROUS!)"
        echo ""
        echo "Example workflow:"
        echo "  $0 up rmq1                # Start first node"
        echo "  $0 up rmq2                # Start second node"
        echo "  $0 join rmq2 rmq1         # Join rmq2 to rmq1's cluster"
        echo "  $0 up rmq3                # Start third node"
        echo "  $0 join rmq3 rmq1         # Join rmq3 to cluster"
        echo "  $0 policy                 # Enable quorum queues"
        echo "  $0 status                 # Check everything is working"
        exit 1
        ;;
esac

################################################################################
# END OF SCRIPT
################################################################################
#
# Congratulations! You now understand:
# - How Podman containers are started with specific configurations
# - How RabbitMQ nodes discover each other (Erlang cookie + explicit join)
# - How clustering works (stop app, join cluster, start app)
# - How policies control queue behavior (quorum vs classic)
# - How data persists (volume mounts from host to container)
#
# Next steps to deepen your learning:
# 1. Run "./rmq_ultra_short.sh status" after each operation to see changes
# 2. Look inside /var/lib/rabbitmq/rmq1 to see the actual data files
# 3. Check "podman logs rmq1" to see RabbitMQ startup messages
# 4. Open Management UI (http://IP:15672) and compare with CLI output
# 5. Try creating a test queue and watch how it gets replicated (if quorum)
#
# Good luck with your RabbitMQ journey! 🐰
#
################################################################################
