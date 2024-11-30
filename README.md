# ProxySQL MySQL Coordinator

A ProxySQL-based MySQL coordinator that provides automatic failover, intelligent request routing, and automated backups.

## Features

- ProxySQL integration for MySQL request routing
- Automatic writer/reader hostgroup management
- etcd-based coordination and state management
- Automated backup system with S3 storage
- Backup rotation and retention management
- Comprehensive health monitoring
- Automatic master failover with GTID validation

## Configuration

### Required Environment Variables

- `ETCDCTL_ENDPOINTS`: etcd cluster endpoints
- `ETCDCTL_USER`: etcd authentication (format: username:password)
- `MYSQL_REPL_USERNAME`: MySQL replication user
- `MYSQL_REPL_PASSWORD`: MySQL replication password
- `PROXYSQL_ADMIN_USER`: ProxySQL admin username
- `PROXYSQL_ADMIN_PASSWORD`: ProxySQL admin password

### Backup Configuration (Required for backups)

- `S3_ENDPOINT_URL`: S3-compatible storage endpoint
- `S3_BACKUP_BUCKET`: Backup storage bucket name
- `S3_ACCESS_KEY`: S3 access key
- `S3_SECRET_KEY`: S3 secret key

### Optional Environment Variables

- `CHECK_INTERVAL`: Health check interval in seconds (default: 5)
- `PROXYSQL_WRITER_HOSTGROUP`: Writer hostgroup ID (default: 10)
- `PROXYSQL_READER_HOSTGROUP`: Reader hostgroup ID (default: 20)
- `S3_BACKUP_PREFIX`: Prefix for backup storage path (default: "proxysql/")
- `BACKUP_RETENTION_DAYS`: Number of days to retain backups (default: 30)

## etcd Schema

The coordinator uses the following etcd key structure:

- `/mysql/nodes/<node_id>`: Node information including:
  - status: online/failed
  - role: master/slave
  - host: hostname
  - port: MySQL port
  - last_seen: timestamp
  - gtid_position: MySQL GTID position

- `/mysql/topology/master`: Current master node ID
- `/mysql/topology/slaves/<node_id>`: Slave information including:
  - master_node_id: Current master
  - replication_lag: Replication delay in seconds

## Backup System

- Automated backups run every 6 hours
- Backups include ProxySQL configuration tables:
  - stats_mysql_query_digest
  - mysql_query_rules
  - mysql_servers
  - mysql_users
  - stats_mysql_commands_counters
  - stats_mysql_connection_pool
- Backup validation with SHA256 checksums
- Configurable retention period
- Compressed backup archives
- Atomic backup operations with locking

## Monitoring

Monitor the coordinator logs:

```bash
tail -f /var/log/proxysql/backup.log  # Backup logs
tail -f /var/log/proxysql/backup_cleanup.log  # Cleanup logs
```

## License

MIT License - See LICENSE file for details
