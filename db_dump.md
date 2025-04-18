# Database Backup Script

A flexible and interactive database backup utility that supports PostgreSQL and MySQL databases. The script provides an intuitive interface using `fzf` for database selection and allows customization through command-line options or environment variables.

## Features

- Supports PostgreSQL and MySQL databases
- Interactive database selection using `fzf`
- Configurable through `.env` file or command-line options
- Timestamped backup files
- Custom backup directory support
- Password handling through environment variables

## Prerequisites

- `bash` shell
- `fzf` for interactive selection
- Database client tools:
  - For PostgreSQL: `pg_dump` and `psql`
  - For MySQL: `mysqldump` and `mysql`

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
chmod +x db_dump.sh

# Run with interactive database selection
./db_dump.sh
```

### Command-line Options

```bash
# Show help
./db_dump.sh --help

# List available databases
./db_dump.sh --list

# Backup specific database
./db_dump.sh --database mydb

# Specify database type
./db_dump.sh --db-type mysql

# Custom host and port
./db_dump.sh --host localhost --port 5432

# Custom backup directory
./db_dump.sh --backup-dir /path/to/backups
```

### Examples

1. Backup a PostgreSQL database:

```bash
./db_dump.sh --db-type postgres --database mydb
```

2. Backup a MySQL database with custom host:

```bash
./db_dump.sh --db-type mysql --host db.example.com --database mydb
```

3. Interactive selection with custom backup directory:

```bash
./db_dump.sh --backup-dir /var/backups/db
```

## Backup File Format

Backup files are created with the following naming convention:

```
{backup_dir}/{database_name}_{YYYY-MM-DD_HH-MM-SS}.backup
```

Example:

```
backups/mydb_2024-03-16_14-30-22.backup
```

## Notes

- The script will automatically create the backup directory if it doesn't exist
- For PostgreSQL, backups are created in custom format (`-F c`)
- For MySQL, backups are created in SQL format
- Passwords are handled through environment variables for security
- The script supports both interactive and non-interactive modes

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

## License

This script is open-source and available under the MIT License.
