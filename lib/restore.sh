#!/bin/bash

source "${LIB_PATH}/backup_config.sh"

restore_proxysql() {
    local backup_file=$1
    local temp_dir="/tmp/proxysql_restore"
    
    if [ -z "$backup_file" ]; then
        echo "Error: Backup file name required" >&2
        return 1
    }
    
    if ! mkdir -p "$temp_dir"; then
        echo "Error: Failed to create temporary directory" >&2
        return 1
    }
    
    echo "Downloading backup file ${backup_file}..."
    # Download from S3
    if ! s3cmd --host="${S3_ENDPOINT_URL}" \
          --host-bucket="${S3_BACKUP_BUCKET}" \
          --access_key="${S3_ACCESS_KEY}" \
          --secret_key="${S3_SECRET_KEY}" \
          get "s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}${backup_file}" \
          "${temp_dir}/${backup_file}"; then
        echo "Error: Failed to download backup file from S3" >&2
        rm -rf "$temp_dir"
        return 1
    fi
    
    echo "Extracting backup file..."
    # Extract backup
    if ! tar xzf "${temp_dir}/${backup_file}" -C "$temp_dir"; then
        echo "Error: Failed to extract backup file" >&2
        rm -rf "$temp_dir"
        return 1
    fi
    
    echo "Restoring ProxySQL tables..."
    # Restore each table
    local tables=(
        "stats_mysql_query_digest"
        "mysql_query_rules"
        "mysql_servers"
        "mysql_users"
        "stats_mysql_commands_counters"
        "stats_mysql_connection_pool"
    )
    
    for table in "${tables[@]}"; do
        mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \
            -e "TRUNCATE TABLE ${table}; LOAD DATA LOCAL INFILE '${temp_dir}/proxysql_backup_*/${table}.sql' INTO TABLE ${table};"
    done
    
    # Apply runtime changes
    mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF
    LOAD MYSQL SERVERS TO RUNTIME;
    SAVE MYSQL SERVERS TO DISK;
    
    LOAD MYSQL USERS TO RUNTIME;
    SAVE MYSQL USERS TO DISK;
    
    LOAD MYSQL QUERY RULES TO RUNTIME;
    SAVE MYSQL QUERY RULES TO DISK;
EOF
    
    echo "Cleaning up temporary files..."
    # Cleanup
    if ! rm -rf "$temp_dir"; then
        echo "Warning: Failed to cleanup temporary files" >&2
        return 1
    fi
    
    echo "Successfully restored ProxySQL from backup: ${backup_file}"
}
