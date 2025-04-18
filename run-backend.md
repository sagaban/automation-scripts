# Run Backend Script

A Zsh script that provides an interactive interface for running backend services with different database configurations using `fzf` and `zellij`.

## Features

- Interactive database environment selection using `fzf`
- Automatic pane renaming in `zellij`
- Docker Compose integration
- Git hash inclusion in environment variables
- Multiple database environment support

## Prerequisites

- `zsh` shell
- `fzf` for interactive selection
- `zellij` terminal multiplexer
- Docker and Docker Compose
- Git

### Installing Prerequisites

#### macOS

```bash
# Install fzf
brew install fzf

# Install zellij
brew install zellij

# Install Docker
brew install --cask docker
```

#### Ubuntu/Debian

```bash
# Install fzf
sudo apt install fzf

# Install zellij
curl -L https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz | tar xz
sudo mv zellij /usr/local/bin/

# Install Docker
sudo apt install docker.io docker-compose
```

## Usage

1. Make the script executable:

```bash
chmod +x run-backend
```

2. Run the script:

```bash
./run-backend
```

## Available Database Environments

The script provides the following database environments:

- Main Database
- Development Database (\_dev)
- PRS Database (\_prs)
- Hotfix Database (\_hotfix)
- Fede's Database (\_fede)
- Production Database (\_prod)

## Environment Variables

The script sets the following environment variables for Docker Compose:

- `CUSTOM_ENV`: Selected database suffix
- `WORKING_DIR`: Current working directory
- `COMPOSE_PROFILES`: Set to "backend"
- `GIT_HASH`: Short Git commit hash
- `GIT_LONG_HASH`: Full Git commit hash

## Integration with Zellij

The script automatically renames the current Zellij pane to include the selected database name:

```
"{Database Label} (concntric_db{suffix})"
```

Example:

```
"Main Database (concntric_db)"
"Development Database (concntric_db_dev)"
```

## Notes

- The script must be run within a Zellij session
- Docker Compose must be configured to use the environment variables
- The script assumes a Git repository is present for hash generation

## Troubleshooting

1. If `fzf` selection doesn't work:

   - Ensure `fzf` is installed
   - Check if you're running in a terminal that supports `fzf`

2. If Zellij pane renaming fails:

   - Verify you're running within a Zellij session
   - Check Zellij permissions

3. If Docker Compose fails:
   - Ensure Docker is running
   - Verify Docker Compose configuration
   - Check environment variables in docker-compose.yml

## License

This script is open-source and available under the MIT License.
