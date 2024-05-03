#!/usr/bin/env bash

# K3s Upgrade Script

# Default values for options
discover_only=false

# Process command-line options
while getopts ":d" opt; do
  case ${opt} in
    d )
      discover_only=true
      ;;
    \? )
      echo "Usage: cmd [-d]"
      exit 1
      ;;
  esac
done

# Query urrently installed version of K3s
get_current_version() {
  k3s --version 2>&1 | awk '{print $3}' | tr -d 'v'
}

# Determine the latest stable version from GitHub
get_latest_version() {
  curl -s https://api.github.com/repos/k3s-io/k3s/releases/latest | grep 'tag_name' | cut -d '"' -f 4 | tr -d 'v'
}

# Check versions
current_version=$(get_current_version)
latest_version=$(get_latest_version)

echo "Current installed version: $current_version"
echo "Latest stable version: $latest_version"

# Compare versions and decide on upgrade
if [ "$current_version" != "$latest_version" ]; then
  if [ "$discover_only" = true ]; then
    echo "An upgrade is available. Current version: $current_version, Latest version: $latest_version"
  else
    echo "Upgrading K3s from version $current_version to $latest_version..."
    # Command to upgrade K3s
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v$latest_version" sh -
    echo "Upgrade completed."
  fi
else
  echo "No upgrade needed. You are already running the latest version."
fi
