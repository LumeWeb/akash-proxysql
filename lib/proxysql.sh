#!/bin/bash

setup_proxysql() {
    local max_attempts=30
    local attempt=1
    local wait_time=2

    while [ $attempt -le $max_attempts ]; do
        if mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            # Initialize ProxySQL configuration upon first successful connection
            init_proxysql
            return 0
        fi
        echo "Waiting for ProxySQL admin interface (attempt $attempt/$max_attempts)..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done

    echo "Error: ProxySQL admin interface not available after $max_attempts attempts"
    return 1
}
# Configure Initial ProxySQL Settings
init_proxysql() {
    mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF
    -- Set monitoring credentials
    UPDATE global_variables SET variable_value='${MYSQL_MONITOR_USER}'
    WHERE variable_name='mysql-monitor_username';
    UPDATE global_variables SET variable_value='${MYSQL_MONITOR_PASSWORD}'
    WHERE variable_name='mysql-monitor_password';

    -- Configure monitoring intervals
    UPDATE global_variables SET variable_value='2000'
    WHERE variable_name IN ('mysql-monitor_connect_interval',
                          'mysql-monitor_ping_interval',
                          'mysql-monitor_read_only_interval');

    -- Configure connection pooling
    UPDATE global_variables SET variable_value='50'
    WHERE variable_name='mysql-max_connections';

    -- Configure query rules for read/write split
    DELETE FROM mysql_query_rules;
    
    INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply)
    VALUES (1, 1, '^SELECT.*FOR UPDATE$', $PROXYSQL_WRITER_HOSTGROUP, 1);

    INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply)
    VALUES (2, 1, '^SELECT', $PROXYSQL_READER_HOSTGROUP, 1);

    LOAD MYSQL VARIABLES TO RUNTIME;
    SAVE MYSQL VARIABLES TO DISK;

    LOAD MYSQL QUERY RULES TO RUNTIME;
    SAVE MYSQL QUERY RULES TO DISK;
EOF
}

update_proxysql_routing() {
    local master
    master=$(get_current_master)

    # Initialize ProxySQL with empty hostgroups if no master exists
    if [ -z "$master" ]; then
        echo "No master node available yet. Initializing empty ProxySQL configuration..."
        mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF
        DELETE FROM mysql_servers WHERE hostgroup_id IN ($PROXYSQL_WRITER_HOSTGROUP, $PROXYSQL_READER_HOSTGROUP);
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
EOF
        return 0
    fi

    # Configure master node
    local host
    local port
    host=$(get_node_hostname "$master")
    port=$(get_node_port "$master")

    # Build atomic transaction for all ProxySQL updates
    local txn_cmds=""

    # Update writer hostgroup
    mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF
    DELETE FROM mysql_servers WHERE hostgroup_id=$PROXYSQL_WRITER_HOSTGROUP;
    INSERT INTO mysql_servers (hostgroup_id, hostname, port)
    SELECT $PROXYSQL_WRITER_HOSTGROUP, '$host', COALESCE(NULLIF('$port', ''), 3306);
EOF

    # Get all nodes for reader hostgroup
    local nodes
    nodes=$(get_registered_nodes)

    # Start transaction for reader updates
    txn_cmds+="compare get $ETCD_MASTER_KEY = '$master'\n"

    # Remove existing reader nodes
    mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF
    DELETE FROM mysql_servers WHERE hostgroup_id=$PROXYSQL_READER_HOSTGROUP;
EOF

    # Add current healthy slaves
    for node in $nodes; do
        if [ "$(get_node_role "$node")" = "slave" ] && check_mysql_health "$node"; then
            local slave_host
            local slave_port
            slave_host=$(get_node_hostname "$node")
            slave_port=$(get_node_port "$node")

            mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" --defaults-extra-file=<(echo $'[client]\npassword='"$PROXYSQL_ADMIN_PASSWORD") <<EOF
            INSERT INTO mysql_servers (hostgroup_id, hostname, port)
            VALUES ($PROXYSQL_READER_HOSTGROUP, '$slave_host', COALESCE(NULLIF('$slave_port', ''), 3306));
EOF
        fi
    done

    mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" --defaults-extra-file=<(echo $'[client]\npassword='"$PROXYSQL_ADMIN_PASSWORD") <<EOF
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
EOF
}

# Monitor ProxySQL status
check_proxysql_status() {
    local status
    status=$(mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e "SELECT hostgroup_id, hostname, port, status FROM mysql_servers" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "ProxySQL is healthy"
        echo "$status"
        return 0
    else
        echo "ProxySQL health check failed"
        return 1
    fi
}

# Get current routing configuration
get_current_routing() {
    mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -N -e "
    SELECT CONCAT(hostgroup_id, ',', hostname, ':', port, ',', status)
    FROM mysql_servers
    ORDER BY hostgroup_id"
}
