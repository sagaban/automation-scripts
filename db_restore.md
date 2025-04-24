# Database Restore Script

A flexible and interactive database restore utility that supports PostgreSQL and MySQL databases. The script provides an intuitive interface using `fzf` for backup file and database selection, with support for handling cases where the database can't be dropped.

## Features

- Supports PostgreSQL and MySQL databases
- Interactive backup file selection with dates
- Sorts backups by date (newest first)
- Handles cases where database can't be dropped
- Drops all schemas if database can't be dropped
- Configurable through `.env` file or command-line options

## Prerequisites

- `fzf` for interactive selection
- For PostgreSQL:
  - `psql`
  - `pg_restore`
- For MySQL:
  - `mysql`
- Listing files (because MacOS use BSD's `ls`)
  - `lsd`

### Installing Prerequisites

#### macOS

```bash
# Install fzf
brew install fzf

# Install PostgreSQL tools
brew install postgresql

# Install MySQL tools
brew install mysql
```

#### Ubuntu/Debian

```bash
# Install fzf
sudo apt install fzf

# Install PostgreSQL tools
sudo apt install postgresql-client

# Install MySQL tools
sudo apt install mysql-client
```

## Configuration

### Environment Variables

Create a `.env` file in the same directory as the script with the following variables:

```env
# Database Configuration
DB_TYPE=postgres
DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=postgres
DB_PASSWORD=postgres
DB_BACKUP_DIR=backups

# MySQL specific (used when DB_TYPE=mysql)
MYSQL_PORT=3306
```

## Usage

### Basic Usage

```bash
# Make the script executable
chmod +x db_restore.sh

# Run with interactive backup file and database selection
./db_restore.sh
```

### Command-line Options

```bash
# Show help
./db_restore.sh --help

# Restore specific backup file to specific database
./db_restore.sh --database mydb --backup-file backups/local-mydb_2024-04-24_18-18-00.backup

# Specify database type
./db_restore.sh --db-type mysql

# Custom host and port
./db_restore.sh --host localhost --port 5432

# Custom backup directory
./db_restore.sh --backup-dir /path/to/backups
```

### Examples

1. Restore a PostgreSQL database:

```bash
./db_restore.sh --db-type postgres --database mydb --backup-file backups/local-mydb_2024-04-24_18-18-00.backup
```

2. Restore a MySQL database with custom host:

```bash
./db_restore.sh --db-type mysql --host db.example.com --database mydb --backup-file backups/local-mydb_2024-04-24_18-18-00.backup
```

3. Interactive selection with custom backup directory:

```bash
./db_restore.sh --backup-dir /var/backups/db
```

## Backup File Format

Backup files are expected to be in the following format:

```
local-{database_name}_{YYYY-MM-DD_HH-MM-SS}.backup
```

Example:

```
backups/local-mydb_2024-03-16_14-30-22.backup
```

## Notes

- The script will create the database if it doesn't exist
- For PostgreSQL, if the database can't be dropped, the script will drop all schemas instead
- The script supports both interactive and non-interactive modes
- All commands require appropriate database permissions

## Troubleshooting

1. If you get a "command not found" error:

   - Ensure all required tools are installed
   - Check if the tools are in your PATH

2. If you get a connection error:

   - Verify database credentials in `.env`
   - Check if the database server is running
   - Verify host and port settings

3. If `fzf` selection doesn't work:

   - Ensure `fzf` is installed
   - Check if you're running in a terminal that supports `fzf`

4. If database drop fails:
   - Check for active connections to the database
   - Verify you have sufficient permissions
   - The script will attempt to drop all schemas as a fallback

## License

This script is open-source and available under the MIT License.
