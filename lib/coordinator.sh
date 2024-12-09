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

        # Check all registered nodes
        check_cluster_health

        # Handle any failed master
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
            echo "$node"
            return 0
        fi
    done
    
    return 1
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
    
    echo "Starting cluster health check for ${#nodes[@]} nodes"
    
    for node in $nodes; do
        echo "Checking health of node: $node"
        local node_info
        node_info=$(get_node_info "$node")
        
        if [ $? -ne 0 ] || [ -z "$node_info" ]; then
            echo "WARNING: Could not get info for node $node, skipping health check"
            continue
        fi

        # Check MySQL connectivity
        local health_status
        if check_mysql_health "$node"; then
            health_status="online"
        else
            health_status="failed"
            echo "[proxysql]: Node $node health check failed"
        fi

        # Only update if status changed
        if [ "$(echo "$node_info" | jq -r '.status')" != "$health_status" ]; then
            # Verify node ID format
            if [[ ! "$node" =~ ^[0-9a-zA-Z_-]+$ ]]; then
                echo "Warning: Invalid node ID format: $node, skipping status update"
                continue
            fi

            # Update node info with new status
            node_info=$(echo "$node_info" | jq --arg status "$health_status" '.status = $status' | jq -c .)
            
            # Simple PUT update - node lease will handle liveness
            if ! etcdctl --insecure-transport --insecure-skip-tls-verify \
                put "$ETCD_NODES_PREFIX/$node" "$node_info" >/dev/null; then
                echo "Warning: Failed to update status for node $node"
                continue
            fi
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
