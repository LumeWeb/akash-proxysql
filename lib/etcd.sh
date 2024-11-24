#!/bin/bash
# Source configuration
source "${LIB_PATH}/config.sh"

validate_etcd_connection() {
    local max_attempts=30
    local attempt=1
    local wait_time=2

    while [ $attempt -le $max_attempts ]; do
        echo "Attempting to connect to etcd at '$ETCDCTL_ENDPOINTS'..."
        if output=$(etcdctl --insecure-transport --insecure-skip-tls-verify endpoint health 2>&1); then
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: Cannot connect to etcd at '$ETCDCTL_ENDPOINTS'"
        echo "Error output: $output"
        echo "Retrying in ${wait_time}s..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done

    echo "Error: Failed to connect to etcd at $ETCDCTL_ENDPOINTS after $max_attempts attempts"
    return 1
}

# ETCD interaction functions with explicit TLS disabled
get_registered_nodes() {
    etcdctl --insecure-transport --insecure-skip-tls-verify \
        get "$ETCD_NODES_PREFIX/" --prefix --keys-only | sed "s|$ETCD_NODES_PREFIX/||"
}

get_current_master() {
    local result
    result=$(etcdctl --insecure-transport --insecure-skip-tls-verify \
        get "$ETCD_MASTER_KEY" -w json)
    if [ -z "$result" ] || [ "$result" = "null" ] || ! echo "$result" | jq -e '.kvs[0]' >/dev/null 2>&1; then
        return 0
    fi
    echo "$result" | jq -r '.kvs[0].value // empty' | base64 -d
}

update_node_status() {
     local node=$1
     local status=$2

     # Get current node info to preserve existing role if not specified
     local current_info
     current_info=$(get_node_info "$node")
     local role
     role=$(echo "$current_info" | jq -r '.role // empty')

     # Get host and port using existing getter functions
     local host
     host=$(get_node_hostname "$node")
     local port
     port=$(get_node_port "$node")

     local timestamp
     timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
     local gtid
     gtid=$(get_node_gtid "$host" "$port")

     jq -n \
         --arg status "$status" \
         --arg role "$role" \
         --arg host "$host" \
         --arg port "$port" \
         --arg last_seen "$timestamp" \
         --arg gtid "$gtid" \
         '{
             status: $status,
             role: $role,
             host: $host,
             port: $port,
             last_seen: $last_seen,
             gtid_position: $gtid
         }' | etcdctl --insecure-transport --insecure-skip-tls-verify \
             put "$ETCD_NODES_PREFIX/$node" >/dev/null
 }

update_slave_status() {
    local node=$1
    local master_node=$2
    local lag=$3
    
    local json="{
        \"master_node_id\": \"$master_node\",
        \"replication_lag\": \"$lag\"
    }"
    
    # Base64 encode the JSON
    local encoded_json
    encoded_json=$(echo "$json" | base64)
    
    # Create atomic transaction
    local txn_cmds="compare create $ETCD_SLAVES_PREFIX/$node = ''\n"
    txn_cmds+="success put $ETCD_SLAVES_PREFIX/$node '$encoded_json'\n"
    txn_cmds+="failure put $ETCD_SLAVES_PREFIX/$node '$encoded_json'\n"
    
    execute_transaction "$txn_cmds"
}

get_node_info() {
    local node=$1
    
    if [ -z "$node" ]; then
        echo "{\"host\":\"\",\"port\":\"\",\"role\":\"\",\"status\":\"unknown\"}"
        return 1
    fi
    
    # Get node info directly
    local result
    result=$(etcdctl --insecure-transport --insecure-skip-tls-verify get "$ETCD_NODES_PREFIX/$node" --print-value-only)
    
    if [ -n "$result" ]; then
        # Try to decode if base64 encoded, otherwise return as-is
        if echo "$result" | base64 -d >/dev/null 2>&1; then
            echo "$result" | base64 -d
        else
            echo "$result"
        fi
    else
        echo "{\"host\":\"\",\"port\":\"\",\"role\":\"\",\"status\":\"unknown\"}"
        return 1
    fi
}

get_node_hostname() {
   local node=$1
   # If node contains hostname:port format, extract hostname
   if [[ "$node" =~ ^([^:]+):([0-9]+)$ ]]; then
       echo "${BASH_REMATCH[1]}"
   else
       get_node_info "$node" | jq -r '.host // empty'
   fi
}

get_node_port() {
   local node=$1
   # If node contains hostname:port format, extract port
   if [[ "$node" =~ ^([^:]+):([0-9]+)$ ]]; then
       echo "${BASH_REMATCH[2]}"
   else
       get_node_info "$node" | jq -r '.port // empty'
   fi
}

get_node_role() {
    local node=$1
    get_node_info "$node" | jq -r '.role'
}

get_node_gtid() {
   local host=$1
   local port=$2
   local gtid

   # Try to get GTID, return empty string if it fails
   gtid=$(mysql -h"$host" -P"$port" -u"$MYSQL_REPL_USERNAME" --defaults-extra-file=<(echo $'[client]\npassword='"$MYSQL_REPL_PASSWORD") -e "SHOW MASTER STATUS\G" 2>/dev/null | grep "Executed_Gtid_Set" | awk '{print $2}' || echo "")

   echo "$gtid"
}


# Execute atomic transaction
execute_transaction() {
    local txn_cmds=$1
    if ! printf "%b" "$txn_cmds" | etcdctl --insecure-transport --insecure-skip-tls-verify txn; then
        return 1
    fi
    return 0
}


update_topology_for_new_master() {
    local new_master=$1
    local nodes
    nodes=$(get_registered_nodes)
    
    # Build transaction commands for atomic update
    local txn_cmds=""
    txn_cmds+="put $ETCD_MASTER_KEY $new_master\n"
    
    for node in $nodes; do
        local node_info
        node_info=$(get_node_info "$node")
        
        if [ "$node" = "$new_master" ]; then
            # Update master node info
            node_info=$(echo "$node_info" | jq --arg role "master" '.role = $role')
        else
            # Update slave node info
            node_info=$(echo "$node_info" | jq --arg role "slave" '.role = $role')
        fi
        
        # Base64 encode the JSON
        local encoded_info
        encoded_info=$(echo "$node_info" | base64)
        txn_cmds+="put $ETCD_NODES_PREFIX/$node '$encoded_info'\n"
    done
    
    # Execute all updates in a single atomic transaction
    printf "%b" "$txn_cmds" | etcdctl --insecure-transport --insecure-skip-tls-verify txn >/dev/null 2>&1
}
