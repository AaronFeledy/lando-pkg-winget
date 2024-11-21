#!/usr/bin/env bash
set -euo pipefail

# Function to show usage
show_usage() {
    echo "Usage: $0 [GITHUB_TOKEN] VERSION"
    echo "Example: $0 ghp_xxxx 3.23.0"
    echo "         $0 3.23.0  # Will try to use KOMAC_TOKEN env var or gh cli"
}

# Check if version is provided
if [ $# -eq 0 ]; then
    show_usage
    exit 1
fi

# Get version from last argument
VERSION="${!#}"

# Remove last argument to allow get_github_token to process the rest
set -- "${@:1:$(($#-1))}"

# Try to get token from argument, environment variable, or gh cli
get_github_token() {
    # First try argument
    if [ -n "${1:-}" ]; then
        echo "$1"
        return 0
    fi
    
    # Then try environment variable
    if [ -n "${KOMAC_TOKEN:-}" ]; then
        echo "$KOMAC_TOKEN"
        return 0
    fi
    
    # Finally try gh cli
    if command_exists gh; then
        if gh auth status &>/dev/null; then
            gh auth token
            return 0
        fi
    fi
    
    return 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to log with timestamp
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to ask for confirmation
confirm() {
    read -r -p "$1 [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Get GitHub token
if ! GITHUB_TOKEN=$(get_github_token "${1:-}"); then
    log "Error: GitHub token not found. Please either:"
    log "  1. Provide token as argument: ./update-lando-package.sh <token> <version>"
    log "  2. Set KOMAC_TOKEN environment variable"
    log "  3. Login with GitHub CLI: gh auth login"
    exit 1
fi

# Construct the URLs using the provided version
LANDO_ARM64_URL="https://github.com/lando/core/releases/download/v${VERSION}/lando-win-arm64-v${VERSION}.exe"
LANDO_AMD64_URL="https://github.com/lando/core/releases/download/v${VERSION}/lando-win-x64-v${VERSION}.exe"

# Function to install Komac
install_komac() {
    log "Komac not found. Installing..."
    
    # Determine OS and architecture
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    
    # Convert architecture names
    case "${ARCH}" in
        x86_64) ARCH="x64" ;;
        aarch64) ARCH="arm64" ;;
        *) log "Unsupported architecture: ${ARCH}"; exit 1 ;;
    esac
    
    # Set OS-specific variables
    case "${OS}" in
        Linux)
            OS="linux"
            INSTALL_DIR="${HOME}/.local/bin"
            
            # For Debian-based systems, try to use the .deb package
            if command_exists apt-get; then
                log "Debian-based system detected, attempting to install via .deb package..."
                TEMP_DEB="$(mktemp)"
                curl -L "https://github.com/russellbanks/Komac/releases/download/v2.6.0/komac_2.6.0-1_amd64.deb" -o "$TEMP_DEB"
                sudo dpkg -i "$TEMP_DEB"
                rm -f "$TEMP_DEB"
                if command_exists komac; then
                    log "Successfully installed Komac via .deb package"
                    return 0
                fi
                log "Falling back to binary installation..."
            fi
            ;;
        Darwin)
            OS="macos"
            INSTALL_DIR="/usr/local/bin"
            ;;
        *) log "Unsupported operating system: ${OS}"; exit 1 ;;
    esac
    
    # Create install directory if it doesn't exist
    mkdir -p "${INSTALL_DIR}"
    
    # Download latest Komac release
    log "Downloading Komac binary..."
    DOWNLOAD_URL="https://github.com/russellbanks/Komac/releases/latest/download/komac-${OS}-${ARCH}"
    if ! curl -L "${DOWNLOAD_URL}" -o "${INSTALL_DIR}/komac"; then
        log "Failed to download Komac"
        exit 1
    fi
    chmod +x "${INSTALL_DIR}/komac"
    
    # Verify installation
    if ! command_exists komac; then
        log "Failed to install Komac. Please add ${INSTALL_DIR} to your PATH"
        exit 1
    fi
    
    log "Successfully installed Komac"
    return 0
}

# Check if Komac is installed, if not install it
if ! command_exists komac; then
    install_komac
fi

log "Using Komac to update Lando.Lando package..."

# Create a temporary directory for the package files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# First run Komac update without submitting to get the changes
if ! komac update Lando.Lando \
    --token "${GITHUB_TOKEN}" \
    --version "${VERSION}" \
    --urls "${LANDO_ARM64_URL}","${LANDO_AMD64_URL}" \
    --output "$TEMP_DIR"; then
    log "Failed to generate package update"
    exit 1
fi
