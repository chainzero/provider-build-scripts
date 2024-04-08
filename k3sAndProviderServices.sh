#!/usr/bin/env bash

# Kubernetes Installation with Provider Services Script

# Default values for options
disable_components="traefik"
external_ip=""

# Process command-line options
while getopts ":d:e:" opt; do
  case ${opt} in
    d )
      disable_components=$OPTARG
      ;;
    e )
      external_ip=$OPTARG
      ;;
    \? )
      echo "Invalid option: $OPTARG" 1>&2
      exit 1
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

# Install K3s master node
echo "Starting K3s installation on master node..."
install_exec="--disable=${disable_components}"
if [[ -n "$external_ip" ]]; then
    install_exec+=" --tls-san=${external_ip}"
fi
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$install_exec" sh -
echo "K3s installation completed."

# If an external IP is specified, update the kubeconfig file
if [[ -n "$external_ip" ]]; then
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "Updating kubeconfig file to use external IP address..."
    sed -i "s/127.0.0.1/$external_ip/g" $KUBECONFIG
    echo "kubeconfig file updated to use external IP address."
fi

# Validate health of master node with retry mechanism
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Checking the health of the master node..."
max_attempts=3
attempt=1
while [ $attempt -le $max_attempts ]; do
    if kubectl get nodes | grep -q ' Ready'; then
        echo "Master node is ready."
        break
    else
        echo "Master node is not ready yet, retrying in 10 seconds... (Attempt $attempt of $max_attempts)"
        sleep 10
    fi
    if [ $attempt -eq $max_attempts ]; then
        echo "Script exited - master node is not ready after $max_attempts attempts - please check status/logs of master node"
        exit 1
    fi
    ((attempt++))
done

# Retrieve and echo the K3s token
echo "Retrieving K3s token for worker nodes..."
token=$(cat /var/lib/rancher/k3s/server/node-token)
echo "K3s token for worker nodes: $token"

# Install provider-services on master
echo "Installing provider-services..."
cd ~
apt-get update
apt-get install -y jq unzip
curl -sfL https://raw.githubusercontent.com/akash-network/provider/main/install.sh | bash

# Add /root/bin to the path for the current session
NEW_PATH="/root/bin"
export PATH="$PATH:$NEW_PATH"

# Validate provider-services installation
echo "Validating provider-services installation..."
provider_services_version=$(provider-services version 2>&1)
if [[ "$provider_services_version" =~ ^v ]]; then
    echo "Provider-services is successfully installed. Version: $provider_services_version"
else
    echo "Provider-services installation failed or not accessible in the PATH."
    exit 1
fi

# Create Kubernetes namespaces and labels
echo "Creating and labeling Kubernetes namespaces..."

# Check if the namespace exists before creating
for ns in akash-services lease; do
    if kubectl get ns $ns > /dev/null 2>&1; then
        echo "Namespace $ns already exists."
    else
        kubectl create ns $ns
        echo "Namespace $ns created."
    fi
done

# Apply labels to namespaces
kubectl label ns akash-services akash.network/name=akash-services akash.network=true --overwrite
kubectl label ns lease akash.network=true --overwrite

echo "Kubernetes namespaces and labels have been set up."

echo "Please proceed with Akash provider account creation/import and export/storage of private key before running the next script."
