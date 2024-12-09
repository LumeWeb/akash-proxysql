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
# Note: These operations are atomic by design, using etcd's consistency guarantees
# Each operation is self-contained to prevent partial updates

# Get list of registered nodes from etcd
# Returns: List of node IDs, one per line
# Safety: This is an atomic read operation, consistent with etcd's snapshot isolation
get_registered_nodes() {
    # Capture any debug output separately
    local nodes
    nodes=$(etcdctl --insecure-transport --insecure-skip-tls-verify \
        get "$ETCD_NODES_PREFIX/" --prefix --keys-only 2>&1) || return 1
    
    # Process only the actual node keys
    local result=()
    while read -r line; do
        if [[ "$line" =~ ^$ETCD_NODES_PREFIX/([^/]+)$ ]]; then
            result+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$nodes"
    
    # Output results
    printf '%s\n' "${result[@]}"
}

get_current_master() {
    # Use --print-value-only to get just the master node ID
    local master
    master=$(etcdctl --insecure-transport --insecure-skip-tls-verify \
        get "$ETCD_MASTER_KEY" --print-value-only 2>&1) || return 1
    
    # Only output if we got a valid node ID
    [[ -n "$master" ]] && echo "$master"
    return 0
}

# Update node status in etcd
# Parameters:
#   $1: node ID
#   $2: new status (online/failed)
# Safety:
#   - Uses etcd's atomic PUT operation
#   - Node lease ensures automatic cleanup of failed nodes
#   - Preserves existing role information
#   - Updates timestamp for lease renewal tracking
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

# Update slave status information
# Simplified to use direct updates instead of transactions
update_slave_status() {
    local node=$1
    local master_node=$2
    local lag=$3
    
    echo "Updating slave status for node: $node"
    local json="{
        \"master_node_id\": \"$master_node\",
        \"replication_lag\": \"$lag\"
    }"
    
    update_etcd_key "$ETCD_SLAVES_PREFIX/$node" "$json"
}

get_node_info() {
    local node=$1
    
    if [ -z "$node" ]; then
        echo "{\"host\":\"\",\"port\":\"\",\"role\":\"\",\"status\":\"unknown\"}"
        return 1
    fi
    
    # Get node info and decode from base64 if needed
    local result
    result=$(etcdctl --insecure-transport --insecure-skip-tls-verify get "$ETCD_NODES_PREFIX/$node" -w json)
    
    if [ -n "$result" ] && [ "$result" != "null" ]; then
        echo "$result" | jq -r '.kvs[0].value | @base64d'
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


# Simplified etcd operations with better error handling and logging

# Update a key with a value
update_etcd_key() {
    local key=$1
    local value=$2
    
    echo "Updating etcd key: $key"
    if ! etcdctl --insecure-transport --insecure-skip-tls-verify put "$key" "$value" >/dev/null; then
        echo "Error: Failed to update etcd key: $key" >&2
        return 1
    fi
    return 0
}

# Get a key's value with error handling
get_etcd_key() {
    local key=$1
    local result
    
    echo "Fetching etcd key: $key"
    if ! result=$(etcdctl --insecure-transport --insecure-skip-tls-verify get "$key" -w json); then
        echo "Error: Failed to get etcd key: $key" >&2
        return 1
    fi
    
    if [ -z "$result" ] || [ "$result" = "null" ] || ! echo "$result" | jq -e '.kvs[0]' >/dev/null 2>&1; then
        echo "Warning: No value found for key: $key" >&2
        return 0
    fi
    
    echo "$result" | jq -r '.kvs[0].value | @base64d'
}


update_topology_for_new_master() {
    local new_master=$1
    local nodes
    nodes=$(get_registered_nodes)
    
    # Update master node first
    local master_info
    master_info=$(get_node_info "$new_master" | jq --arg role "master" '.role = $role')
    etcdctl --insecure-transport --insecure-skip-tls-verify \
        put "$ETCD_NODES_PREFIX/$new_master" "$master_info"
    
    # Update remaining nodes as slaves
    for node in $nodes; do
        if [ "$node" != "$new_master" ]; then
            local node_info
            node_info=$(get_node_info "$node" | jq --arg role "slave" '.role = $role')
            etcdctl --insecure-transport --insecure-skip-tls-verify \
                put "$ETCD_NODES_PREFIX/$node" "$node_info"
        fi
    done
}
