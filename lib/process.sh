#!/bin/bash

# ProxySQL process management functions
start_proxysql() {
    # Cleanup any stale PID file
    rm -f /var/lib/proxysql/proxysql.pid

    # Start ProxySQL based on initialization state
    if [ ! -f /var/lib/proxysql/proxysql.db ]; then
        >&2 echo "Initializing ProxySQL for first time..."
    else
        >&2 echo "Starting ProxySQL with existing configuration..."
    fi

    proxysql --no-monitor --no-version-check --idle-threads >/dev/null 2>&1 &

    # Wait for PID file (up to 10 seconds)
    local timeout=10
    local count=0
    while [ ! -f /var/lib/proxysql/proxysql.pid ] && [ $count -lt $timeout ]; do
        sleep 1
        count=$((count + 1))
    done

    if [ ! -f /var/lib/proxysql/proxysql.pid ]; then
        >&2 echo "Error: ProxySQL failed to create PID file"
        return 1
    fi

    # Read and return ONLY the PID
    cat /var/lib/proxysql/proxysql.pid
}

wait_for_proxysql() {
    local pid=$1
    local max_attempts=${2:-30}
    local attempt=1
    
    echo "Waiting for ProxySQL to start..."
    while [ $attempt -le $max_attempts ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Error: ProxySQL process died"
            return 1
        fi
        
        if mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            echo "ProxySQL started successfully"
            return 0
        fi
        
        echo "Waiting for ProxySQL to initialize (attempt $attempt/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "Error: ProxySQL failed to start after $max_attempts attempts"
    return 1
}

check_proxysql_health() {
    if ! pgrep proxysql >/dev/null; then
        echo "ProxySQL process is not running"
        return 1
    fi

    if ! mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
        echo "Cannot connect to ProxySQL admin interface"
        return 1
    fi

    return 0
}
