ARG PROXYSQL_VERSION=2.7.1-debian

# Build stage for coordinator
FROM debian:12-slim AS coordinator-build

# Install build dependencies
RUN apt-get update && apt-get install -y \
    bash \
    curl \
    etcd-client \
    default-mysql-client \
    jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && which etcdctl || (echo "etcdctl not found after installation" && exit 1)

# Create directory structure
RUN mkdir -p /usr/local/lib

# Copy files directly to their destinations
COPY lib/* /usr/local/lib/
COPY paths.sh /
COPY entrypoint.sh /

# Make scripts executable
RUN chmod +x /entrypoint.sh /usr/local/lib/*.sh

# Final stage
FROM proxysql/proxysql:${PROXYSQL_VERSION}

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    bash \
    curl \
    etcd-client \
    jq

 # Install Percona repository and tools
RUN apt-get install -y wget lsb-release gnupg2 \
     && wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb \
     && dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb \
     && apt-get update \
     && apt-get install -y percona-toolkit \
     && rm -rf /var/lib/apt/lists/* \
     && rm percona-release_latest.$(lsb_release -sc)_all.deb

RUN  apt-get clean \
        && rm -rf /var/lib/apt/lists/*

# Copy coordinator files from build stage
COPY --from=coordinator-build /usr/local/lib /usr/local/lib
COPY --from=coordinator-build /entrypoint.sh /entrypoint.sh
COPY --from=coordinator-build /paths.sh /paths.sh

# Set environment variables
ENV ETCDCTL_USER=root:root
ENV MYSQL_USER=root
ENV MYSQL_PASSWORD=root
ENV PROXYSQL_ADMIN_USER=admin
ENV PROXYSQL_ADMIN_PASSWORD=admin
ENV CHECK_INTERVAL=5

# ProxySQL hostgroup configuration (optional)
# ENV PROXYSQL_WRITER_HOSTGROUP=10  # Default: 10
# ENV PROXYSQL_READER_HOSTGROUP=20  # Default: 20

ENTRYPOINT ["/entrypoint.sh"]
