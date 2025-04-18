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
    echo "  --database DB        Database name to backup (if not specified, will show selection menu)"
    echo "  --username USER      Database username (default: $USERNAME)"
    echo "  --backup-dir DIR     Backup directory (default: $BACKUP_DIR)"
    echo "  --list              List available databases and exit"
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
        list_postgres_dbs | fzf --height 40% --border --prompt "Select a database: "
    else
        list_mysql_dbs | fzf --height 40% --border --prompt "Select a database: "
    fi
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
        --list)
            LIST_DBS=true
            shift
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

# Handle database selection
if [[ "$LIST_DBS" == "true" ]]; then
    case "$DB_TYPE" in
        postgres)
            list_postgres_dbs
            ;;
        mysql)
            list_mysql_dbs
            ;;
        *)
            echo "Error: Unsupported database type: $DB_TYPE"
            echo "Supported types: postgres, mysql"
            exit 1
            ;;
    esac
    exit 0
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

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Generate timestamp with date and time
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="${BACKUP_DIR}/${DATABASE}_${TIMESTAMP}.backup"

# Function to create PostgreSQL dump
dump_postgres() {
    if ! command -v pg_dump &> /dev/null; then
        echo "Error: pg_dump is not installed"
        exit 1
    fi
    
    #  /opt/homebrew/Cellar/postgresql@16/16.8_1/bin/pg_dump --verbose --host=localhost --port=15432 ****** --format=c --encoding=UTF-8 --clean --create --file /private/tmp/local-monorepo-concntric_db-202504161113.backup -n concntric_1699961672 -n public -n pumpernic_1716455915 concntric_db
   
    echo "Creating PostgreSQL dump..."
    if PGPASSWORD=$DB_PASSWORD pg_dump --verbose -h "$HOST" -p "$PORT" -U "$USERNAME" -F c --encoding=UTF-8 --clean --create --file "$BACKUP_FILE" "$DATABASE"; then
        echo "Successfully created PostgreSQL dump at $BACKUP_FILE"
    else
        echo "Error creating PostgreSQL dump"
        exit 1
    fi
}

# Function to create MySQL dump
dump_mysql() {
    if ! command -v mysqldump &> /dev/null; then
        echo "Error: mysqldump is not installed"
        exit 1
    fi
    
    echo "Creating MySQL dump..."
    if mysqldump -h "$HOST" -P "$PORT" -u "$USERNAME" -p"$DB_PASSWORD" --databases "$DATABASE" > "$BACKUP_FILE"; then
        echo "Successfully created MySQL dump at $BACKUP_FILE"
    else
        echo "Error creating MySQL dump"
        exit 1
    fi
}

# Create the appropriate dump based on database type
case "$DB_TYPE" in
    postgres)
        dump_postgres
        ;;
    mysql)
        dump_mysql
        ;;
    *)
        echo "Error: Unsupported database type: $DB_TYPE"
        echo "Supported types: postgres, mysql"
        exit 1
        ;;
esac 