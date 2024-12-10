#!/bin/bash
set -eo pipefail

# Track last promotion time for grace period
declare -g LAST_PROMOTION_TIME=0

source "${LIB_PATH}/config.sh"
source "${LIB_PATH}/etcd.sh"
source "${LIB_PATH}/mysql.sh"
source "${LIB_PATH}/proxysql.sh"
source "${LIB_PATH}/backup.sh"
source "${LIB_PATH}/restore.sh"

main() {
    # Validate required environment variables
    local required_vars=(
        "ETCDCTL_ENDPOINTS"
        "ETCDCTL_USER"
        "MYSQL_REPL_USERNAME"
        "MYSQL_REPL_PASSWORD"
        "PROXYSQL_ADMIN_USER"
        "PROXYSQL_ADMIN_PASSWORD"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "Error: Required environment variable $var is not set" >&2
            exit 1
        fi
    done

    local check_interval=${CHECK_INTERVAL:-5}

    echo "Starting MySQL Cluster Coordinator..."
    echo "Using ETCD endpoints: $ETCDCTL_ENDPOINTS"

    # Ensure ProxySQL is ready before proceeding
    if ! setup_proxysql; then
        echo "Fatal: Could not connect to ProxySQL admin interface"
        exit 1
    fi

    # Start backup schedule if enabled
    if [ "$BACKUP_ENABLED" = "true" ]; then
        setup_backup_schedule
    else
        echo "Backups are disabled via BACKUP_ENABLED environment variable"
    fi

    while true; do
        # Get registered nodes
        local nodes
        nodes=$(get_registered_nodes)

        if [ -z "$nodes" ]; then
            echo "No MySQL nodes registered in etcd yet. Waiting..."
            sleep "$check_interval"
            continue
        fi

        # Prune stale nodes first
        if ! prune_stale_nodes; then
            echo "Warning: Node pruning reported errors"
            # Continue execution but log the error
        fi

        # Validate master key consistency
        if ! validate_master_key; then
            echo "Warning: Failed to validate master key, will retry"
            sleep "$check_interval"
            continue
        fi

        # Check all registered nodes
        if ! check_cluster_health; then
            echo "Warning: Cluster health check reported errors"
            # Continue execution but log the error
        fi

        # Handle any failed master or missing master
        if ! handle_master_failover; then
            echo "Warning: Failed to handle master failover, will retry on next iteration"
            sleep "$check_interval"
            continue
        fi

        # Update ProxySQL configuration
        update_proxysql_routing

        sleep "$check_interval"
    done
}

select_new_master() {
    local nodes
    nodes=$(get_registered_nodes)
    
    # Find first healthy slave
    for node in $nodes; do
        local node_info
        node_info=$(get_node_info "$node")
        
        # Skip non-slaves and unhealthy nodes
        if [ "$(echo "$node_info" | jq -r '.role')" = "slave" ] && \
           [ "$(echo "$node_info" | jq -r '.status')" = "online" ] && \
           check_mysql_health "$node"; then
            SELECTED_NODE="$node"
            return 0
        fi
    done
    
    return 1
}

# Validate master key consistency
# This ensures the master key in etcd matches reality by:
# 1. Checking if the current master key points to a valid node
# 2. Verifying the node is actually functioning as master
# 3. Clearing stale master keys to allow proper promotion
validate_master_key() {
    local current_master
    current_master=$(get_current_master)
    
    # If no master key exists, that's valid (fresh cluster)
    if [ -z "$current_master" ]; then
        return 0
    fi
    
    # Skip validation if we're within grace period of promotion
    local current_time
    current_time=$(date +%s)
    local grace_period=${PROMOTION_GRACE_PERIOD:-30}  # 30 second default
    
    if [ $((current_time - LAST_PROMOTION_TIME)) -lt "$grace_period" ]; then
        echo "Within promotion grace period, skipping master validation"
        return 0
    fi
    
    # Verify master node exists and is healthy
    local master_info
    master_info=$(get_node_info "$current_master")
    
    if [ -z "$master_info" ] || [ "$(echo "$master_info" | jq -r '.status')" != "online" ]; then
        echo "Warning: Master key points to non-existent or unhealthy node: $current_master"
        # Clear the stale master key
        if ! delete_etcd_key "$ETCD_MASTER_KEY"; then
            echo "Error: Failed to clear stale master key" >&2
            return 1
        fi
        echo "Cleared stale master key"
        return 0
    fi
    
    # Verify node is actually functioning as master
    if [ "$(echo "$master_info" | jq -r '.role')" != "master" ]; then
        echo "Warning: Master key points to node that is not in master role: $current_master"
        # Clear the inconsistent master key
        if ! etcdctl --insecure-transport --insecure-skip-tls-verify del "$ETCD_MASTER_KEY" >/dev/null; then
            echo "Error: Failed to clear inconsistent master key" >&2
            return 1
        fi
        echo "Cleared inconsistent master key"
        return 0
    fi
    
    return 0
}

# Prune stale node records from etcd
# Parameters:
#   $1: max age in seconds (optional, defaults to 300)
# Returns:
#   0 on success, 1 if errors occurred
prune_stale_nodes() {
    local max_age=${1:-300}  # Default to 5 minutes
    local current_time
    current_time=$(date -u +%s)
    local has_errors=0
    
    local nodes
    nodes=$(get_registered_nodes) || return 1
    
    for node in $nodes; do
        local node_info
        node_info=$(get_node_info "$node")
        
        # Skip if we can't get node info
        if [ -z "$node_info" ] || [ "$node_info" = "null" ]; then
            echo "WARNING: No info found for node $node, marking for removal"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            continue
        fi
        
        # Get last_seen timestamp
        local last_seen
        last_seen=$(echo "$node_info" | jq -r '.last_seen // empty')
        
        if [ -z "$last_seen" ]; then
            echo "WARNING: Node $node has no last_seen timestamp, marking for removal"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            continue
        fi
        
        # Convert ISO 8601 timestamp to epoch seconds
        local last_seen_epoch
        last_seen_epoch=$(date -d "$last_seen" +%s 2>/dev/null)
        
        if [ -z "$last_seen_epoch" ]; then
            echo "WARNING: Node $node has invalid last_seen timestamp, marking for removal"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            continue
        fi
        
        # Calculate age in seconds
        local age=$((current_time - last_seen_epoch))
        
        if [ $age -gt $max_age ]; then
            echo "Node $node is stale (age: ${age}s), marking for removal"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            
            # Also clean up any slave status entries
            delete_etcd_key "$ETCD_SLAVES_PREFIX/$node" || has_errors=1
            
            # If this was the master, clear the master key
            local current_master
            current_master=$(get_current_master)
            if [ "$node" = "$current_master" ]; then
                echo "Removing stale master key for node $node"
                delete_etcd_key "$ETCD_MASTER_KEY" || has_errors=1
            fi
        fi
    done
    
    return $has_errors
}

# Check health status of all cluster nodes
# This is the main cluster safety mechanism that:
# 1. Validates each node's health status
# 2. Updates etcd with current state
# 3. Triggers failover if master is unhealthy
#
# Safety guarantees:
# - Uses lease-based health tracking
# - Atomic updates prevent split-brain
# - Consistent view of cluster state
# - Automatic cleanup of failed nodes
check_cluster_health() {
    local nodes
    nodes=$(get_registered_nodes)
    
    [ "${DEBUG:-0}" = "1" ] && echo "Starting cluster health check for nodes"
    
    local has_errors=0
    
    for node in $nodes; do
        [ "${DEBUG:-0}" = "1" ] && echo "Checking health of node: $node"
        
        # Get current node info
        local node_info
        node_info=$(get_node_info "$node")
        
        if [ -z "$node_info" ] || [ "$node_info" = "null" ]; then
            echo "WARNING: No info found for node $node, removing from etcd"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            continue
        fi
        
        # Check if node info is valid
        if ! echo "$node_info" | jq -e 'has("host") and has("port")' >/dev/null 2>&1; then
            echo "WARNING: Invalid config for node $node, removing from etcd"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            continue
        fi

        # Check if host/port are actually populated with valid values
        local host port
        host=$(echo "$node_info" | jq -r '.host')
        port=$(echo "$node_info" | jq -r '.port')
        
        if [ -z "$host" ] || [ -z "$port" ] || [ "$host" = "null" ] || [ "$port" = "null" ]; then
            echo "WARNING: Node $node has empty/null host/port, removing from etcd"
            delete_etcd_key "$ETCD_NODES_PREFIX/$node" || has_errors=1
            continue
        fi

        # Continue with regular health check for valid nodes
        local health_status="failed"
        if check_mysql_health "$node" >/dev/null 2>&1; then
            health_status="online"
        else
            echo "Node $node health check failed"
        fi

        # Only update if status changed
        if [ "$(echo "$node_info" | jq -r '.status // "unknown"')" != "$health_status" ]; then
            echo "Node $node status changed to: $health_status"
            update_node_status "$node" "$health_status" || has_errors=1
        fi
    done

    # Return overall status but don't exit
    return $has_errors
}

setup_backup_schedule() {
    if ! validate_backup_config; then
        echo "Warning: Backup configuration invalid, backups disabled"
        return 1
    fi

    # Ensure cron is installed and running
    if ! command -v cron >/dev/null 2>&1; then
        echo "Error: cron is not installed" >&2
        return 1
    fi

    # Start cron if not running
    if ! pgrep cron >/dev/null; then
        cron
    fi

    # Create cron entry for every 6 hours
    echo "0 */6 * * * /usr/local/bin/proxysql-backup-runner >> /var/log/proxysql_backup.log 2>&1" | crontab -

    echo "Backup scheduler configured via cron"
    return 0
}

handle_master_failover() {
    local current_master
    current_master=$(get_current_master)

    if [ -n "$current_master" ] && check_mysql_health "$current_master" >/dev/null 2>&1; then
        return 0
    fi

    echo "Master node $current_master has failed or no master exists"
    
    # Reset and select new master
    SELECTED_NODE=""
    select_new_master
    local select_result=$?
    
    if [ $select_result -ne 0 ] || [ -z "$SELECTED_NODE" ]; then
        echo "ERROR: No suitable slave found for promotion!" >&2
        return 1
    fi

    echo "Promoting new master node: $SELECTED_NODE"
    if ! update_etcd_key "$ETCD_MASTER_KEY" "$SELECTED_NODE"; then
        echo "ERROR: Failed to promote new master node: $SELECTED_NODE" >&2
        return 1
    fi

    LAST_PROMOTION_TIME=$(date +%s)
    echo "Starting promotion grace period..."
    update_topology_for_new_master "$SELECTED_NODE"
    return 0
}


# Start the coordinator
main
