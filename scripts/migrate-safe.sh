#!/usr/bin/env bash
# Safe database migration wrapper for WRFCoin platform.
# Takes a backup before migrating, validates schema after, and auto-restores on failure.

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

DRY_RUN=false
ROLLBACK_MODE=false
DATABASE_URL="${DATABASE_URL:-}"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/db-backups}"
MIGRATION_CMD="${MIGRATION_CMD:-npm run db:migrate}"
ROLLBACK_CMD="${ROLLBACK_CMD:-npm run db:rollback}"

# Critical tables that must exist after migration
CRITICAL_TABLES=(
    "users"
    "transactions"
    "blocks"
    "wallets"
    "weather_data"
    "carbon_credits"
)

LOG_FILE="${PROJECT_ROOT}/migration-$(date +%Y%m%d-%H%M%S).log"

###############################################################################
# Helpers
###############################################################################

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log() {
    local msg="[$(timestamp)] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="[$(timestamp)] ERROR: $1"
    echo "$msg" >&2 | tee -a "$LOG_FILE"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Safe database migration wrapper with backup, validation, and auto-restore.

Options:
  --dry-run         Show what migrations would run without executing
  --rollback        Undo the last migration
  --help            Show this help message

Environment variables:
  DATABASE_URL      PostgreSQL connection string (required)
  BACKUP_DIR        Directory for backups (default: \$PROJECT_ROOT/db-backups)
  MIGRATION_CMD     Migration command (default: npm run db:migrate)
  ROLLBACK_CMD      Rollback command (default: npm run db:rollback)

Examples:
  DATABASE_URL=postgres://user:pass@localhost:5432/wrfcoin $(basename "$0") --dry-run
  DATABASE_URL=postgres://user:pass@localhost:5432/wrfcoin $(basename "$0")
  DATABASE_URL=postgres://user:pass@localhost:5432/wrfcoin $(basename "$0") --rollback
EOF
    exit 0
}

###############################################################################
# Argument parsing
###############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --rollback)
            ROLLBACK_MODE=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

###############################################################################
# Validation
###############################################################################

validate_env() {
    log "Validating environment..."

    if [[ -z "$DATABASE_URL" ]]; then
        log_error "DATABASE_URL environment variable is required"
        exit 1
    fi

    # Check for pg_dump and psql
    if ! command -v pg_dump >/dev/null 2>&1; then
        log_error "pg_dump is required but not found. Install postgresql-client."
        exit 1
    fi

    if ! command -v psql >/dev/null 2>&1; then
        log_error "psql is required but not found. Install postgresql-client."
        exit 1
    fi

    # Test database connectivity
    if ! psql "$DATABASE_URL" -c "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to database. Check DATABASE_URL."
        exit 1
    fi

    log "Environment validation passed"
}

###############################################################################
# Parse DATABASE_URL for pg_dump/psql (handles standard postgres:// URLs)
###############################################################################

parse_db_url() {
    # Extract components from postgres://user:pass@host:port/dbname
    local url="$DATABASE_URL"

    # Remove protocol prefix
    url="${url#postgres://}"
    url="${url#postgresql://}"

    # Extract user:pass
    local userpass="${url%%@*}"
    local hostportdb="${url#*@}"

    DB_USER="${userpass%%:*}"
    DB_PASS="${userpass#*:}"

    # Extract host:port/dbname
    local hostport="${hostportdb%%/*}"
    DB_NAME="${hostportdb#*/}"
    # Remove query params from DB_NAME
    DB_NAME="${DB_NAME%%\?*}"

    DB_HOST="${hostport%%:*}"
    DB_PORT="${hostport#*:}"

    # Default port if not specified
    if [[ "$DB_PORT" == "$DB_HOST" ]]; then
        DB_PORT="5432"
    fi
}

###############################################################################
# Backup
###############################################################################

create_backup() {
    local backup_file="$BACKUP_DIR/wrfcoin-pre-migration-$(date +%Y%m%d-%H%M%S).sql.gz"

    log "Creating pre-migration backup..."
    log "Backup destination: $backup_file"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would create backup at: $backup_file"
        echo "$backup_file"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    parse_db_url

    PGPASSWORD="$DB_PASS" pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --no-owner \
        --no-acl \
        --format=custom \
        -f "${backup_file%.gz}" 2>>"$LOG_FILE" || {
        log_error "Backup failed"
        exit 1
    }

    # Compress if gzip is available, otherwise keep uncompressed
    if command -v gzip >/dev/null 2>&1; then
        gzip "${backup_file%.gz}"
        log "Backup created and compressed: $backup_file"
    else
        backup_file="${backup_file%.gz}"
        log "Backup created (uncompressed): $backup_file"
    fi

    echo "$backup_file"
}

###############################################################################
# Restore from backup
###############################################################################

restore_backup() {
    local backup_file="$1"

    log "Restoring database from backup: $backup_file"

    parse_db_url

    local restore_file="$backup_file"

    # Decompress if needed
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -k "$backup_file" 2>/dev/null || true
        restore_file="${backup_file%.gz}"
    fi

    # Drop and recreate the database schema
    PGPASSWORD="$DB_PASS" psql \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" 2>>"$LOG_FILE" || {
        log_error "Failed to reset schema before restore"
        return 1
    }

    # Restore from backup
    PGPASSWORD="$DB_PASS" pg_restore \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --no-owner \
        --no-acl \
        "$restore_file" 2>>"$LOG_FILE" || {
        log_error "Restore failed"
        return 1
    }

    # Clean up decompressed file if we decompressed
    if [[ "$backup_file" == *.gz && -f "$restore_file" ]]; then
        rm -f "$restore_file"
    fi

    log "Database restored successfully from backup"
}

###############################################################################
# Schema validation
###############################################################################

get_table_count() {
    psql "$DATABASE_URL" -t -A -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0"
}

check_critical_tables() {
    local missing=0

    for table in "${CRITICAL_TABLES[@]}"; do
        local exists
        exists=$(psql "$DATABASE_URL" -t -A -c \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table';" 2>/dev/null || echo "0")

        if [[ "$exists" -eq 0 ]]; then
            log_error "Critical table missing after migration: $table"
            missing=$((missing + 1))
        fi
    done

    return $missing
}

validate_schema() {
    log "Validating schema after migration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would validate schema (table counts, critical tables)"
        return 0
    fi

    local table_count
    table_count=$(get_table_count)
    log "Post-migration table count: $table_count"

    if [[ "$table_count" -eq 0 ]]; then
        log_error "Schema validation failed: no tables found"
        return 1
    fi

    if ! check_critical_tables; then
        log_error "Schema validation failed: critical tables missing"
        return 1
    fi

    log "Schema validation passed ($table_count tables, all critical tables present)"
    return 0
}

###############################################################################
# Show pending migrations (dry run)
###############################################################################

show_pending_migrations() {
    log "Checking for pending migrations..."

    cd "$PROJECT_ROOT"

    # Try to show migration status
    if command -v npx >/dev/null 2>&1; then
        log "Migration status:"
        npx drizzle-kit status 2>/dev/null || \
            npm run db:status 2>/dev/null || \
            log "Could not determine migration status (command not available)"
    fi
}

###############################################################################
# Run migration
###############################################################################

run_migration() {
    log "Running database migration..."

    cd "$PROJECT_ROOT"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would execute: $MIGRATION_CMD"
        show_pending_migrations
        return 0
    fi

    log "Executing: $MIGRATION_CMD"
    eval "$MIGRATION_CMD" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Migration command failed"
        return 1
    }

    log "Migration command completed"
}

###############################################################################
# Rollback last migration
###############################################################################

run_rollback() {
    log "Rolling back last migration..."

    cd "$PROJECT_ROOT"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would execute: $ROLLBACK_CMD"
        return 0
    fi

    log "Executing: $ROLLBACK_CMD"
    eval "$ROLLBACK_CMD" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Rollback command failed"
        return 1
    }

    log "Migration rollback completed"
}

###############################################################################
# Main
###############################################################################

main() {
    log "============================================"
    log "  WRFCoin Safe Database Migration"
    log "  Dry run:  $DRY_RUN"
    log "  Rollback: $ROLLBACK_MODE"
    log "============================================"

    validate_env

    # Capture pre-migration table count
    local pre_table_count
    pre_table_count=$(get_table_count)
    log "Pre-migration table count: $pre_table_count"

    if [[ "$ROLLBACK_MODE" == "true" ]]; then
        # For rollback, still take a backup first
        local backup_file
        backup_file=$(create_backup)

        if ! run_rollback; then
            log_error "Migration rollback failed. Restoring from backup..."
            restore_backup "$backup_file"
            log_error "Restored from backup after failed rollback."
            exit 1
        fi

        validate_schema || log "Warning: schema validation had issues after rollback"

        log "============================================"
        log "  Migration rollback completed successfully"
        log "============================================"
        exit 0
    fi

    # Normal migration flow
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Deployment plan:"
        log "  1. Take database backup (pg_dump)"
        log "  2. Run migration: $MIGRATION_CMD"
        log "  3. Validate schema (table counts, critical tables)"
        log "  4. Auto-restore on failure"
        log ""
        show_pending_migrations
        run_migration
        validate_schema
        log "[DRY RUN] Complete. No changes were made."
        exit 0
    fi

    # Step 1: Backup
    local backup_file
    backup_file=$(create_backup)
    log "Backup saved to: $backup_file"

    # Step 2: Run migration
    if ! run_migration; then
        log_error "Migration failed. Restoring from backup..."
        restore_backup "$backup_file"
        log_error "Database restored to pre-migration state."
        exit 1
    fi

    # Step 3: Validate schema
    if ! validate_schema; then
        log_error "Schema validation failed after migration. Restoring from backup..."
        restore_backup "$backup_file"
        log_error "Database restored to pre-migration state."
        exit 1
    fi

    local post_table_count
    post_table_count=$(get_table_count)

    log "============================================"
    log "  Migration completed successfully"
    log "  Tables before: $pre_table_count"
    log "  Tables after:  $post_table_count"
    log "  Backup:        $backup_file"
    log "============================================"
}

main
