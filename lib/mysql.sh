#!/bin/bash

check_mysql_health() {
   local node=$1
   local host
   local port

   host=$(get_node_hostname "$node")
   port=$(get_node_port "$node")

   # Validate host and port
   if [ -z "$host" ] || [ -z "$port" ]; then
       echo "Invalid host ($host) or port ($port) for node $node" >&2
       return 1
   fi

   # Try to connect and run simple query
   if ! mysql -h"$host" -P"$port" -u"$MYSQL_REPL_USERNAME" -p"$MYSQL_REPL_PASSWORD" -e "SELECT 1;" &>/dev/null; then
       echo "Failed to connect to MySQL at $host:$port" >&2
       return 1
   fi

   return 0
}

check_slave_status() {
    local host=$1
    local port=$2
    
    # Check if slave is running and not too far behind
    local result
    result=$(mysql -h "$host" -P "$port" -u"$MYSQL_REPL_USERNAME" -p"$MYSQL_REPL_PASSWORD" \
             -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind_Master:")
    
    echo "$result" | grep -q "Slave_IO_Running: Yes" || return 1
    echo "$result" | grep -q "Slave_SQL_Running: Yes" || return 1
    
    # Check if slave lag is acceptable (< 300 seconds)
    local lag
    lag=$(echo "$result" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    [ "$lag" -lt 300 ] || return 1
    
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
    
    # Build atomic transaction for role update
    local node_info
    node_info=$(get_node_info "$node")
    node_info=$(echo "$node_info" | jq --arg role "master" '.role = $role')
    
    local txn_cmds="compare mod($ETCD_NODES_PREFIX/$node) > 0\n"
    txn_cmds+="success put $ETCD_NODES_PREFIX/$node '$node_info'\n"
    txn_cmds+="failure put $ETCD_NODES_PREFIX/$node '$node_info'\n"
    
    execute_transaction "$txn_cmds"
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