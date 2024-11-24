#!/bin/bash
set -eo pipefail

source "${LIB_PATH}/config.sh"
source "${LIB_PATH}/etcd.sh"
source "${LIB_PATH}/mysql.sh"
source "${LIB_PATH}/proxysql.sh"

main() {
    local check_interval=${CHECK_INTERVAL:-5}

    echo "Starting MySQL Cluster Coordinator..."
    echo "Using ETCD endpoints: $ETCDCTL_ENDPOINTS"

    # Ensure ProxySQL is ready before proceeding
    if ! setup_proxysql; then
        echo "Fatal: Could not connect to ProxySQL admin interface"
        exit 1
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
        handle_master_failover

        # Update ProxySQL configuration
        update_proxysql_routing

        sleep "$check_interval"
    done
}

select_new_master() {
    local nodes
    nodes=$(get_registered_nodes)
    local best_slave=""
    local highest_gtid=""

    # Find slave with most up-to-date GTID
    for node in $nodes; do
        # Get node info and check health atomically
        local node_info
        node_info=$(get_node_info "$node")
        local role
        role=$(echo "$node_info" | jq -r '.role')
        
        # Skip non-slaves
        if [ "$role" != "slave" ]; then
            continue
        fi
        
        # Check health and get GTID atomically
        local health_check=0
        local node_gtid=""
        
        if check_mysql_health "$node"; then
            health_check=1
            node_gtid=$(get_node_gtid "$(echo "$node_info" | jq -r '.host')" "$(echo "$node_info" | jq -r '.port')")
        fi
        
        # Skip unhealthy nodes
        if [ "$health_check" -eq 0 ]; then
            continue
        fi

        # For first valid slave or if this slave has higher GTID
        if [ -z "$best_slave" ] || [ "$(compare_gtid_positions "$node_gtid" "$highest_gtid")" = "ahead" ]; then
            best_slave="$node"
            highest_gtid="$node_gtid"
        fi
    done

    echo "$best_slave"
}

check_cluster_health() {
    local nodes
    nodes=$(get_registered_nodes)

    # Build a single atomic transaction for all node updates
    local txn_cmds=""

    for node in $nodes; do
        local node_info health_status
        node_info=$(get_node_info "$node")
        
        if check_mysql_health "$node"; then
            health_status="online"
        else
            health_status="failed"
        fi

        # Only include in transaction if status changed
        if [ "$(echo "$node_info" | jq -r '.status')" != "$health_status" ]; then
            node_info=$(echo "$node_info" | jq --arg status "$health_status" '.status = $status')
            txn_cmds+="compare mod($ETCD_NODES_PREFIX/$node) > 0\n"
            txn_cmds+="success put $ETCD_NODES_PREFIX/$node '$node_info'\n"
            txn_cmds+="failure put $ETCD_NODES_PREFIX/$node '$node_info'\n"
        fi
    done

    # Execute single atomic transaction if there are any updates
    if [ -n "$txn_cmds" ]; then
        execute_transaction "$txn_cmds"
    fi
}

handle_master_failover() {
    local current_master
    current_master=$(get_current_master)

    # If no master exists or current master failed
    if [ -z "$current_master" ] || ! check_mysql_health "$current_master"; then
        echo "Master node $current_master has failed or no master exists"

        # Find best slave to promote based on GTID position
        local new_master
        new_master=$(select_new_master)

        if [ -n "$new_master" ]; then
            # Create transaction that checks current_master hasn't changed
            local txn_cmds
            if [ -z "$current_master" ]; then
                # If no master exists, verify the key doesn't exist
                txn_cmds="compare version(\"$ETCD_MASTER_KEY\") = '0'\n"
            else
                # If replacing failed master, verify it's still the one we think it is
                txn_cmds="compare value(\"$ETCD_MASTER_KEY\") = '$current_master'\n"
            fi
            txn_cmds+="success put $ETCD_MASTER_KEY '$new_master'\n"
            txn_cmds+="failure get $ETCD_MASTER_KEY\n"

            if ! execute_transaction "$txn_cmds"; then
                echo "Master changed during failover attempt, retrying..."
                return 1
            fi

            # Update roles atomically
            update_topology_for_new_master "$new_master"
            echo "Updated topology with new master: $new_master"
        else
            echo "ERROR: No suitable slave found for promotion!" >&2
        fi
    fi
}


# Start the coordinator
main
