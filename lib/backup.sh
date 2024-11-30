#!/bin/bash

source "${LIB_PATH}/backup_config.sh"

# Check if enough disk space is available
check_disk_space() {
    local path=$1
    local required_mb=$2
    local available_kb
    available_kb=$(df -P "$path" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo "Error: Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB" >&2
        return 1
    fi
    return 0
}

backup_proxysql() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="proxysql_backup_${timestamp}.sql"
    local backup_path="/tmp/${backup_file}"
    local backup_dir="/tmp/proxysql_backup_${timestamp}"
    local lock_file="/var/run/proxysql_backup.lock"
    local checksum_file="${backup_path}.sha256"
    local config_lock_file="/tmp/proxysql_config.lock"
    
    # Ensure cleanup of temporary files on exit
    trap 'rm -rf "$backup_dir" "${backup_path}.tar.gz" "$checksum_file" "$lock_file" "$config_lock_file"' EXIT
    
    # Check disk space (require at least 1GB)
    if ! check_disk_space "/tmp" 1000; then
        return 1
    fi

    # Ensure only one backup runs at a time
    if ! mkdir "$lock_file" 2>/dev/null; then
        echo "Error: Another backup process is running" >&2
        return 1
    fi
    trap 'rm -rf "$lock_file"' EXIT
    
    if ! mkdir -p "$backup_dir"; then
        echo "Error: Failed to create backup directory" >&2
        rm -rf "$lock_file"
        return 1
    fi
    
    # Lock ProxySQL configuration and create lock file
    if ! (
        flock -n 9 || exit 1
        mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \
            -e "PROXYSQL READONLY 1; SAVE MYSQL VARIABLES TO DISK; SAVE MYSQL SERVERS TO DISK;" 2>/dev/null
    ) 9>"$config_lock_file"; then
        echo "Error: Failed to lock ProxySQL configuration" >&2
        return 1
    fi
    
    # Ensure configuration unlock on exit
    trap 'mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e "PROXYSQL READONLY 0;" 2>/dev/null; rm -rf "$lock_file"' EXIT
    
    # Dump important tables
    local tables=(
        "stats_mysql_query_digest"
        "mysql_query_rules"
        "mysql_servers"
        "mysql_users"
        "stats_mysql_commands_counters"
        "stats_mysql_connection_pool"
    )
    
    local backup_failed=0
    for table in "${tables[@]}"; do
        if ! mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \
            -e "SELECT * FROM ${table}" > "${backup_dir}/${table}.sql" 2>/dev/null; then
            echo "Error: Failed to backup table ${table}" >&2
            backup_failed=1
            break
        fi
    done
    
    if [ "$backup_failed" -eq 1 ]; then
        rm -rf "$backup_dir"
        return 1
    fi
    
    # Compress backup
    if ! tar czf "${backup_path}.tar.gz" -C "/tmp" "proxysql_backup_${timestamp}"; then
        echo "Error: Failed to compress backup" >&2
        rm -rf "$backup_dir"
        return 1
    fi
    
    # Create and verify backup integrity
    if ! sha256sum "${backup_path}.tar.gz" > "$checksum_file"; then
        echo "Error: Failed to create backup checksum" >&2
        return 1
    fi
    
    # Verify backup integrity
    if ! sha256sum -c "$checksum_file" >/dev/null 2>&1; then
        echo "Error: Backup verification failed" >&2
        return 1
    fi
    
    # Test backup contents
    if ! tar tzf "${backup_path}.tar.gz" >/dev/null 2>&1; then
        echo "Error: Backup archive is corrupted" >&2
        return 1
    fi
    
    # Upload to S3 with retry
    local max_retries=3
    local retry=0
    local upload_success=0
    
    while [ $retry -lt $max_retries ]; do
        if s3cmd --host="${S3_ENDPOINT_URL}" \
              --host-bucket="${S3_BACKUP_BUCKET}" \
              --access_key="${S3_ACCESS_KEY}" \
              --secret_key="${S3_SECRET_KEY}" \
              put "${backup_path}.tar.gz" "s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}${backup_file}.tar.gz" && \
           s3cmd --host="${S3_ENDPOINT_URL}" \
              --host-bucket="${S3_BACKUP_BUCKET}" \
              --access_key="${S3_ACCESS_KEY}" \
              --secret_key="${S3_SECRET_KEY}" \
              put "$checksum_file" "s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}${backup_file}.tar.gz.sha256"; then
            upload_success=1
            break
        fi
        retry=$((retry + 1))
        echo "Upload attempt $retry failed, retrying..." >&2
        sleep 5
    done
    
    if [ $upload_success -eq 0 ]; then
        echo "Error: Failed to upload backup to S3 after $max_retries attempts" >&2
        rm -rf "$backup_dir" "${backup_path}.tar.gz" "$checksum_file"
        return 1
    fi
    
    # Cleanup local files
    if ! rm -rf "$backup_dir" "${backup_path}.tar.gz"; then
        echo "Warning: Failed to cleanup local backup files" >&2
        return 1
    fi
    
    echo "Successfully created and uploaded backup: ${backup_file}.tar.gz"
}

cleanup_old_backups() {
    local cutoff_date=$(date -d "-${BACKUP_RETENTION_DAYS} days" +%Y%m%d)
    local temp_list="/tmp/backup_list.$$"
    local error_count=0
    local deletion_log="/var/log/proxysql/backup_cleanup.log"
    
    # Ensure cleanup of temporary files
    trap 'rm -f "$temp_list"' EXIT
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$deletion_log")"
    
    echo "Cleaning up backups older than ${BACKUP_RETENTION_DAYS} days..."
    
    # Get list of backups
    if ! s3cmd --host="${S3_ENDPOINT_URL}" \
          --host-bucket="${S3_BACKUP_BUCKET}" \
          --access_key="${S3_ACCESS_KEY}" \
          --secret_key="${S3_SECRET_KEY}" \
          ls "s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}" > "$temp_list"; then
        echo "Error: Failed to list backups from S3" >&2
        rm -f "$temp_list"
        return 1
    fi
    
    # Process backup list
    while read -r line; do
        if [[ $line =~ s3.*proxysql_backup_([0-9]{8}).*\.tar\.gz$ ]]; then
            local filedate="${BASH_REMATCH[1]}"
            local filename=$(echo "$line" | awk '{print $4}')
            local checksum_file="${filename}.sha256"
            
            if [ "$filedate" -lt "$cutoff_date" ]; then
                echo "Removing old backup: $filename"
                if ! s3cmd --host="${S3_ENDPOINT_URL}" \
                      --host-bucket="${S3_BACKUP_BUCKET}" \
                      --access_key="${S3_ACCESS_KEY}" \
                      --secret_key="${S3_SECRET_KEY}" \
                      rm "$filename" "$checksum_file"; then
                    echo "Warning: Failed to remove backup: $filename" >&2
                    error_count=$((error_count + 1))
                fi
            fi
        fi
    done < "$temp_list"
    
    rm -f "$temp_list"
    
    if [ $error_count -gt 0 ]; then
        echo "Warning: Failed to remove $error_count backup(s)" >&2
        return 1
    fi
    
    return 0
}
