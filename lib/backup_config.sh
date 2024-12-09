#!/bin/bash

# Export backup enabled status with default to true if not set
export BACKUP_ENABLED=${BACKUP_ENABLED:-"true"}

# Validate required backup environment variables
validate_backup_config() {
    # If explicitly disabled, log and return 1
    if [ "$BACKUP_ENABLED" = "false" ]; then
        echo "Backups are disabled via BACKUP_ENABLED environment variable"
        return 1
    fi

    local required_vars=(
        "S3_ENDPOINT_URL"
        "S3_BACKUP_BUCKET"
        "S3_ACCESS_KEY"
        "S3_SECRET_KEY"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "Error: Required environment variable $var is not set"
            return 1
        fi
    done

    # Set defaults for optional variables
    BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
    S3_BACKUP_PREFIX=${S3_BACKUP_PREFIX:-"proxysql/"}

    # Verify S3 bucket exists and is accessible
    if ! s3cmd --host="${S3_ENDPOINT_URL}" \
          --host-bucket="${S3_BACKUP_BUCKET}" \
          --access_key="${S3_ACCESS_KEY}" \
          --secret_key="${S3_SECRET_KEY}" \
          ls "s3://${S3_BACKUP_BUCKET}" >/dev/null 2>&1; then
        echo "Error: Cannot access S3 bucket ${S3_BACKUP_BUCKET}"
        return 1
    fi
}
