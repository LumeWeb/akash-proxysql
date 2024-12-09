#!/bin/bash
set -eo pipefail

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

        # Validate master key consistency
        if ! validate_master_key; then
            echo "Warning: Failed to validate master key, will retry"
            sleep "$check_interval"
            continue
        fi

        # Check all registered nodes
        check_cluster_health

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
    
    # Verify master node exists and is healthy
    local master_info
    master_info=$(get_node_info "$current_master")
    
    if [ -z "$master_info" ] || [ "$(echo "$master_info" | jq -r '.status')" != "online" ]; then
        echo "Warning: Master key points to non-existent or unhealthy node: $current_master"
        # Clear the stale master key
        if ! etcdctl --insecure-transport --insecure-skip-tls-verify del "$ETCD_MASTER_KEY" >/dev/null; then
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
    
    # Only log the start of health check if debug logging is enabled
    [ "${DEBUG:-0}" = "1" ] && echo "Starting cluster health check for nodes"
    
    for node in $nodes; do
        [ "${DEBUG:-0}" = "1" ] && echo "Checking health of node: $node"
        
        # Get current node info from etcd
        local raw_info
        raw_info=$(etcdctl --insecure-transport --insecure-skip-tls-verify get "$ETCD_NODES_PREFIX/$node" -w json)
        
        if [ -z "$raw_info" ] || [ "$raw_info" = "null" ]; then
            echo "WARNING: No info found for node $node, marking as failed"
            update_node_status "$node" "failed"
            continue
        fi

        # Extract and parse the actual node info
        local node_info
        node_info=$(echo "$raw_info" | jq -r '.kvs[0].value | @base64d')
        
        # Check if node info is valid
        if ! echo "$node_info" | jq -e 'has("host") and has("port")' >/dev/null 2>&1; then
            echo "WARNING: Invalid config for node $node, marking as failed"
            if ! update_node_status "$node" "failed"; then
                echo "ERROR: Failed to update status for node $node, continuing..."
            fi
            continue
        fi

        # Check MySQL connectivity only if we have valid host/port
        local health_status="failed"
        local host port
        host=$(echo "$node_info" | jq -r '.host')
        port=$(echo "$node_info" | jq -r '.port')
        
        if [ -n "$host" ] && [ -n "$port" ] && [ "$host" != "null" ] && [ "$port" != "null" ]; then
            if check_mysql_health "$node" >/dev/null 2>&1; then
                health_status="online"
            else
                echo "Node $node health check failed"
            fi
        else
            echo "Node $node missing valid host/port configuration"
        fi

        # Only update and log if status changed
        if [ "$(echo "$node_info" | jq -r '.status // "unknown"')" != "$health_status" ]; then
            echo "Node $node status changed to: $health_status"
            update_node_status "$node" "$health_status"
        fi
    done
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

    update_topology_for_new_master "$SELECTED_NODE"
    return 0
}


# Start the coordinator
main
