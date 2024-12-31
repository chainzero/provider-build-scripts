#!/bin/bash
# upgrade-k3s-master.sh
# Script to upgrade K3s master node while preserving original installation arguments

function get_k3s_server_args() {
    if [ -f "/etc/systemd/system/k3s.service" ]; then
        # Extract all lines between ExecStart and the next empty line or section
        # Only include lines that start with '--' and handle quotes properly
        INSTALL_ARGS=$(awk '/ExecStart=\/usr\/local\/bin\/k3s/,/^$/ {print}' /etc/systemd/system/k3s.service | \
                      grep "^[[:space:]]*'--\|^[[:space:]]*--" | \
                      sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
                      sed "s/'//g" | \
                      tr -d '\\' | \
                      tr '\n' ' ' | \
                      sed 's/[[:space:]]*$//')
        echo "$INSTALL_ARGS"
    else
        echo "Error: K3s server service file not found"
        exit 1
    fi
}

function get_k3s_server_env_vars() {
    ENV_VARS=""
    if [ -f "/etc/systemd/system/k3s.service.env" ]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ ! "$line" =~ ^#.*$ ]] && [ ! -z "$line" ]; then
                ENV_VARS="$ENV_VARS $line"
            fi
        done < "/etc/systemd/system/k3s.service.env"
    fi
    echo "$ENV_VARS"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# Check if this is actually a master node
if [ ! -f "/etc/systemd/system/k3s.service" ]; then
    echo "Error: This doesn't appear to be a K3s master node"
    exit 1
fi

# Get installation arguments
INSTALL_ARGS=$(get_k3s_server_args)
ENV_VARS=$(get_k3s_server_env_vars)

echo "Detected installation arguments: $INSTALL_ARGS"
echo "Detected environment variables: $ENV_VARS"

# Construct and execute upgrade command, forcing IPv4
UPGRADE_CMD="curl -4 -sfL https://get.k3s.io | $ENV_VARS INSTALL_K3S_EXEC=\"server $INSTALL_ARGS\" sh -"

echo "Executing upgrade command:"
echo "$UPGRADE_CMD"
echo "Continue with upgrade? (y/n)"
read -r confirm

if [ "$confirm" = "y" ]; then
    eval "$UPGRADE_CMD"
    echo "Upgrade completed. Please check system logs for any errors."
else
    echo "Upgrade cancelled."
    exit 0
fi
