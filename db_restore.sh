#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load environment variables from .env file if it exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Default values (can be overridden by .env or command line arguments)
DB_TYPE=${DB_TYPE:-"postgres"}
HOST=${DB_HOST:-"localhost"}
PORT=${DB_PORT:-"5432"}
DATABASE=""
USERNAME=${DB_USERNAME:-"postgres"}
BACKUP_DIR=${DB_BACKUP_DIR:-"backups"}

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --db-type TYPE       Database type (postgres or mysql. Default: $DB_TYPE)"
    echo "  --host HOST          Database host (default: $HOST)"
    echo "  --port PORT          Database port (default: $PORT)"
    echo "  --database DB        Target database name to restore to (if not specified, will show selection menu)"
    echo "  --username USER      Database username (default: $USERNAME)"
    echo "  --backup-dir DIR     Backup directory (default: $BACKUP_DIR)"
    echo "  --backup-file FILE   Specific backup file to restore (if not specified, will show selection menu)"
    echo "  --help              Show this help message"
    echo ""
    echo "Note: Default values can be set in .env file in the script directory ($SCRIPT_DIR)"
    exit 1
}

# Function to list PostgreSQL databases
list_postgres_dbs() {
    if ! command -v psql &> /dev/null; then
        echo "Error: psql is not installed"
        exit 1
    fi

    PGPASSWORD=$DB_PASSWORD psql -h "$HOST" -p "$PORT" -U "$USERNAME" -l -t | cut -d'|' -f1 | sed -e 's/ //g' -e '/^$/d'
}

# Function to list MySQL databases
list_mysql_dbs() {
    if ! command -v mysql &> /dev/null; then
        echo "Error: mysql is not installed"
        exit 1
    fi

    mysql -h "$HOST" -P "$PORT" -u "$USERNAME" -p"$DB_PASSWORD" -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$"
}

# Function to select database using fzf
select_database() {
    local db_type=$1
    
    # Check if fzf is installed
    if ! command -v fzf &> /dev/null; then
        echo "Error: fzf is not installed. Please install it first:"
        echo "  brew install fzf  # for macOS"
        echo "  apt install fzf   # for Ubuntu/Debian"
        exit 1
    fi

    # Get databases based on type and pipe to fzf
    if [[ "$db_type" == "postgres" ]]; then
        list_postgres_dbs | fzf --height 40% --border --prompt "Select a database to restore to: "
    else
        list_mysql_dbs | fzf --height 40% --border --prompt "Select a database to restore to: "
    fi
}

# Function to select backup file using fzf
select_backup_file() {
    # Check if fzf is installed
    if ! command -v fzf &> /dev/null; then
        echo "Error: fzf is not installed. Please install it first:"
        echo "  brew install fzf  # for macOS"
        echo "  apt install fzf   # for Ubuntu/Debian"
        exit 1
    fi

    # List backup files with creation dates and sort by date
    find "$BACKUP_DIR" -type f -name "*.backup" -exec lsd -l --date +"%Y-%m-%d %H:%M:%S" {} \; | \
        sort -k6,7r | \
        awk '{printf "%s %s\t%s\n", $6, $7, $NF}' | \
        fzf --height 40% --border --prompt "Select a backup file to restore: " | \
        awk '{print $3}'
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --db-type)
            DB_TYPE="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --database)
            DATABASE="$2"
            shift 2
            ;;
        --username)
            USERNAME="$2"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --backup-file)
            BACKUP_FILE="$2"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Adjust default port for MySQL
if [[ "$DB_TYPE" == "mysql" && "$PORT" == "5432" ]]; then
    PORT=${MYSQL_PORT:-"3306"}
fi

# If no backup file specified, show selection menu
if [[ -z "$BACKUP_FILE" ]]; then
    BACKUP_FILE=$(select_backup_file)
    
    # Check if a backup file was selected
    if [ -z "$BACKUP_FILE" ]; then
        echo "No backup file selected"
        exit 1
    fi
fi

# If no database specified, show selection menu
if [[ -z "$DATABASE" ]]; then
    DATABASE=$(select_database "$DB_TYPE")
    
    # Check if a database was selected
    if [ -z "$DATABASE" ]; then
        echo "No database selected"
        exit 1
    fi
fi

# Function to restore PostgreSQL dump
restore_postgres() {
    if ! command -v pg_restore &> /dev/null; then
        echo "Error: pg_restore is not installed"
        exit 1
    fi
    
    echo "Restoring PostgreSQL dump from $BACKUP_FILE to database $DATABASE..."
    
    # Try to drop the database if it exists
    if ! PGPASSWORD=$DB_PASSWORD psql -h "$HOST" -p "$PORT" -U "$USERNAME" -c "DROP DATABASE IF EXISTS $DATABASE;"; then
        echo "Could not drop database $DATABASE (likely due to active connections)."
        echo "Attempting to drop all schemas instead..."
        
        # Get all schemas except system schemas
        SCHEMAS=$(PGPASSWORD=$DB_PASSWORD psql -h "$HOST" -p "$PORT" -U "$USERNAME" -d "$DATABASE" -t -c "
            SELECT schema_name 
            FROM information_schema.schemata 
            WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
            AND schema_name NOT LIKE 'pg_temp%'
            AND schema_name NOT LIKE 'pg_toast_temp%';
        ")
        
        # Drop each schema
        for schema in $SCHEMAS; do
            echo "Dropping schema $schema..."
            PGPASSWORD=$DB_PASSWORD psql -h "$HOST" -p "$PORT" -U "$USERNAME" -d "$DATABASE" -c "DROP SCHEMA IF EXISTS $schema CASCADE;"
        done
    else
        # Create the database if we successfully dropped it
        PGPASSWORD=$DB_PASSWORD psql -h "$HOST" -p "$PORT" -U "$USERNAME" -c "CREATE DATABASE $DATABASE;"
    fi
    
    # Restore the backup
    if PGPASSWORD=$DB_PASSWORD pg_restore --verbose --host="$HOST" --port="$PORT" -U "$USERNAME" --dbname="$DATABASE" "$BACKUP_FILE"; then
        echo "Successfully restored PostgreSQL dump to $DATABASE"
    else
        echo "Error restoring PostgreSQL dump"
        exit 1
    fi
}

# Function to restore MySQL dump
restore_mysql() {
    if ! command -v mysql &> /dev/null; then
        echo "Error: mysql is not installed"
        exit 1
    fi
    
    echo "Restoring MySQL dump from $BACKUP_FILE to database $DATABASE..."
    
    # Drop the database if it exists
    mysql -h "$HOST" -P "$PORT" -u "$USERNAME" -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS $DATABASE;"
    
    # Create the database
    mysql -h "$HOST" -P "$PORT" -u "$USERNAME" -p"$DB_PASSWORD" -e "CREATE DATABASE $DATABASE;"
    
    # Restore the backup
    if mysql -h "$HOST" -P "$PORT" -u "$USERNAME" -p"$DB_PASSWORD" "$DATABASE" < "$BACKUP_FILE"; then
        echo "Successfully restored MySQL dump to $DATABASE"
    else
        echo "Error restoring MySQL dump"
        exit 1
    fi
}

# Restore the appropriate dump based on database type
case "$DB_TYPE" in
    postgres)
        restore_postgres
        ;;
    mysql)
        restore_mysql
        ;;
    *)
        echo "Error: Unsupported database type: $DB_TYPE"
        echo "Supported types: postgres, mysql"
        exit 1
        ;;
esac 