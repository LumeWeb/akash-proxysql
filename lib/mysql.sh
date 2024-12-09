#!/bin/bash

# Check MySQL node health status
# This is a critical safety check that validates node health
# 
# Safety considerations:
# - Timeout-based connection attempts prevent hanging
# - Validates both connectivity and basic functionality
# - Used by lease renewal process to maintain cluster state
# - Part of the automatic failover decision process
#
# Returns:
#   0 if node is healthy (can connect and execute queries)
#   1 if node is unhealthy or unreachable
check_mysql_health() {
   local node=$1
   local host
   local port

   echo "Checking MySQL health for node: $node"
   
   host=$(get_node_hostname "$node")
   port=$(get_node_port "$node")

   # Validate host and port
   if [ -z "$host" ] || [ -z "$port" ]; then
       echo "ERROR: Invalid configuration - host ($host) or port ($port) missing for node $node" >&2
       return 1
   fi

   # Try to connect and run simple query
   echo "Attempting MySQL connection to $host:$port..."
   if ! mysql -h"$host" -P"$port" -u"$MYSQL_REPL_USERNAME" -p"$MYSQL_REPL_PASSWORD" -e "SELECT 1;" &>/dev/null; then
       echo "ERROR: Failed to establish MySQL connection to $host:$port" >&2
       echo "Please check: 1) MySQL service status 2) Network connectivity 3) Authentication credentials" >&2
       return 1
   fi

   echo "MySQL health check successful for $host:$port"
   return 0
}

# Check MySQL slave status and replication health
# Parameters:
#   $1: MySQL host
#   $2: MySQL port
# Returns:
#   0 if slave is healthy and in sync
#   1 if slave has issues or excessive lag
check_slave_status() {
    local host=$1
    local port=$2
    
    echo "Checking slave status for $host:$port"
    
    # Check if slave is running and not too far behind
    local result
    result=$(mysql -h "$host" -P "$port" -u"$MYSQL_REPL_USERNAME" -p"$MYSQL_REPL_PASSWORD" \
             -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind_Master:")
    
    if ! echo "$result" | grep -q "Slave_IO_Running: Yes"; then
        echo "ERROR: Slave IO thread not running on $host:$port" >&2
        return 1
    fi
    
    if ! echo "$result" | grep -q "Slave_SQL_Running: Yes"; then
        echo "ERROR: Slave SQL thread not running on $host:$port" >&2
        return 1
    fi
    
    # Check if slave lag is acceptable (< 300 seconds)
    local lag
    lag=$(echo "$result" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    if [ "$lag" -ge 300 ]; then
        echo "ERROR: Slave lag ($lag seconds) exceeds threshold on $host:$port" >&2
        return 1
    fi
    
    echo "Slave status check successful for $host:$port (lag: ${lag}s)"
    return 0
}

select_new_master() {
    local nodes
    nodes=$(get_registered_nodes)
    
    # Find healthy slave with least lag
    local best_slave=""
    local min_lag=999999
    
    for node in $nodes; do
        if [ "$(get_node_role "$node")" = "slave" ] && check_mysql_health "$node"; then
            local host
            local port
            host=$(get_node_hostname "$node")
            port=$(get_node_port "$node")
            
            local lag
            lag=$(mysql -h "$host" -P "$port" -u"$MYSQL_REPL_USERNAME" -p"$MYSQL_REPL_PASSWORD" \
                 -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
            
            if [ "$lag" -lt "$min_lag" ]; then
                min_lag=$lag
                best_slave=$node
            fi
        fi
    done
    
    echo "$best_slave"
}

promote_new_master() {
    local node=$1
    local host
    local port
    
    host=$(get_node_hostname "$node")
    port=$(get_node_port "$node")
    
    # Stop slave and reset slave status
    mysql -h "$host" -P "$port" -u"$MYSQL_REPL_USERNAME" -p"$MYSQL_REPL_PASSWORD" \
        -e "STOP SLAVE; RESET SLAVE ALL;" >/dev/null 2>&1
    
    # Update node role to master
    local node_info
    node_info=$(get_node_info "$node")
    node_info=$(echo "$node_info" | jq --arg role "master" '.role = $role')
    
    echo "Updating node $node role to master"
    if ! update_etcd_key "$ETCD_NODES_PREFIX/$node" "$node_info"; then
        echo "ERROR: Failed to update role for node $node"
        return 1
    fi
}

compare_gtid_positions() {
    local gtid1=$1
    local gtid2=$2

    # If either GTID is empty, treat empty one as "behind"
    if [ -z "$gtid1" ] && [ -z "$gtid2" ]; then
        echo "equal"
        return 0
    elif [ -z "$gtid1" ]; then
        echo "behind"
        return 0
    elif [ -z "$gtid2" ]; then
        echo "ahead"
        return 0
    fi

    # Extract transaction counts from the GTIDs
    local count1 count2
    count1=$(echo "$gtid1" | sed -E 's/.*:([0-9]+)-([0-9]+)/\2/')
    count2=$(echo "$gtid2" | sed -E 's/.*:([0-9]+)-([0-9]+)/\2/')

    # Compare transaction counts
    if [ "$count1" -gt "$count2" ]; then
        echo "ahead"
    elif [ "$count1" -lt "$count2" ]; then
        echo "behind"
    else
        echo "equal"
    fi
}
