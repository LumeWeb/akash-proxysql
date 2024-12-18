#!/bin/bash
set -eo pipefail

# Ensure cron is installed
if ! command -v cron >/dev/null 2>&1; then
    apt-get update && apt-get install -y cron
fi

# Source configurations
source ./paths.sh
source "${LIB_PATH}/process.sh"

# Validate required environment variables
required_vars=(
    "ETCDCTL_ENDPOINTS"
    "ETCDCTL_USER"
    "MYSQL_USER"
    "MYSQL_PASSWORD"
    "PROXYSQL_ADMIN_USER"
    "PROXYSQL_ADMIN_PASSWORD"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required environment variable $var is not set"
        exit 1
    fi
done

# Start ProxySQL
PROXYSQL_PID=$(start_proxysql)

# Wait for ProxySQL to be ready
if ! wait_for_proxysql "$PROXYSQL_PID"; then
    echo "Fatal: ProxySQL failed to start properly"
    exit 1
fi

# Validate etcd connectivity with retries
source "${LIB_PATH}/etcd.sh"
echo "Waiting for etcd to become available..."
if ! validate_etcd_connection; then
    echo "Fatal: Could not establish connection to etcd"
    exit 1
fi

echo "etcd is available, starting coordinator..."
# Start the coordinator
source "${LIB_PATH}/coordinator.sh"
