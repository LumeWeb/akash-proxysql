# ProxySQL MySQL Coordinator for Akash

A ProxySQL-based MySQL coordinator container for Akash Network deployments that provides automatic failover and intelligent request routing.

## Features

- ProxySQL integration for MySQL request routing
- Automatic writer/reader hostgroup management
- etcd-based coordination
- Containerized deployment for Akash Network

## Configuration

### Required Environment Variables

- `ETCD_ENDPOINTS`: etcd cluster endpoints
- `ETCDCTL_USER`: etcd authentication (format: username:password)
- `MYSQL_USER`: MySQL user for health checks
- `MYSQL_PASSWORD`: MySQL user password
- `PROXYSQL_ADMIN_USER`: ProxySQL admin username
- `PROXYSQL_ADMIN_PASSWORD`: ProxySQL admin password

### Optional Environment Variables

- `CHECK_INTERVAL`: Health check interval in seconds (default: 5)
- `PROXYSQL_WRITER_HOSTGROUP`: Writer hostgroup ID (default: 10)
- `PROXYSQL_READER_HOSTGROUP`: Reader hostgroup ID (default: 20)

## Deployment

### Akash SDL Example

```yaml
version: "2.0"

services:
  coordinator:
    image: proxysql/proxysql:2.7.1-debian
    env:
      - ETCD_ENDPOINTS=http://etcd-host:2379
      - MYSQL_USER=root
      - MYSQL_PASSWORD=your_password
      - PROXYSQL_ADMIN_USER=admin
      - PROXYSQL_ADMIN_PASSWORD=admin_password
    expose:
      - port: 6032
        as: 6032
        to:
          - global: true

profiles:
  compute:
    coordinator:
      resources:
        cpu:
          units: 1
        memory:
          size: 512Mi
        storage:
          size: 512Mi

deployment:
  coordinator:
    akash:
      profile: coordinator
      count: 1
```

## Monitoring

Monitor the coordinator logs using:

```bash
akash provider service-logs --service coordinator
```

## License

MIT License - See LICENSE file for details
