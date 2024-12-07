#!/bin/bash

# Validate ETCD authentication format
if [[ ! "${ETCDCTL_USER}" =~ ^[^:]+:[^:]+$ ]]; then
    echo "Error: ETCDCTL_USER must be in format username:password" >&2
    exit 1
fi

# ETCD paths configuration
ETCD_BASE="/mysql"
ETCD_NODES_PREFIX="${ETCD_BASE}/nodes"
ETCD_TOPOLOGY_PREFIX="${ETCD_BASE}/topology"
ETCD_MASTER_KEY="${ETCD_TOPOLOGY_PREFIX}/master"
ETCD_SLAVES_PREFIX="${ETCD_TOPOLOGY_PREFIX}/slaves"

# ProxySQL hostgroup configuration
# Hostgroups are used to route traffic to different MySQL servers:
# - Writer hostgroup: Contains the master node for write operations
# - Reader hostgroup: Contains slave nodes for read operations
#
# Default values follow ProxySQL convention:
# - Lower numbers (10) for writer/master groups
# - Higher numbers (20) for reader/slave groups
PROXYSQL_WRITER_HOSTGROUP=${PROXYSQL_WRITER_HOSTGROUP:-10}
PROXYSQL_READER_HOSTGROUP=${PROXYSQL_READER_HOSTGROUP:-20}

# Validate hostgroup configuration
if ! [[ "$PROXYSQL_WRITER_HOSTGROUP" =~ ^[0-9]+$ ]] || \
   ! [[ "$PROXYSQL_READER_HOSTGROUP" =~ ^[0-9]+$ ]]; then
    echo "Error: ProxySQL hostgroup IDs must be positive integers" >&2
    exit 1
fi

if [ "$PROXYSQL_WRITER_HOSTGROUP" -eq "$PROXYSQL_READER_HOSTGROUP" ]; then
    echo "Error: Writer and reader hostgroups must be different" >&2
    exit 1
fi

# Validate MySQL replication user credentials
if [ -z "$MYSQL_REPL_PASSWORD" ]; then
    echo "Error: MYSQL_REPL_PASSWORD must be set" >&2
    exit 1
fi

# Basic format validation for replication user
if [[ ! "$MYSQL_REPL_USERNAME" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
    echo "Error: MYSQL_REPL_USERNAME contains invalid characters" >&2
    exit 1
fi

if [ ${#MYSQL_REPL_PASSWORD} -lt 8 ]; then
    echo "Error: MYSQL_REPL_PASSWORD must be at least 8 characters long" >&2
    exit 1
fi
