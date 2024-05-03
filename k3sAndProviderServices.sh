#!/usr/bin/env bash

# Kubernetes Installation with Provider Services Script

# Default values for options
disable_components="traefik"
external_ip=""
testing_mode=false
all_in_one_mode=false
install_gpu_drivers=false

# Process command-line options
while getopts ":d:e:tag" opt; do
  case ${opt} in
    d )
      disable_components=$OPTARG
      ;;
    e )
      external_ip=$OPTARG
      ;;
    t )
      testing_mode=true
      ;;
    a )
      all_in_one_mode=true
      ;;
    g )
      install_gpu_drivers=true
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
install_exec="--disable=${disable_components} --flannel-backend=none"
if [[ -n "$external_ip" ]]; then
    install_exec+=" --tls-san=${external_ip}"
fi
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$install_exec" sh -
echo "K3s installation completed."

# Install Calico
echo "Installing Calico CNI..."
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
echo "Calico CNI installation completed."

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

# GPU host prep, driver, and toolkit install
if [ "$install_gpu_drivers" = true ]; then
    echo "Starting GPU host preparation, driver, and toolkit installation..."

    apt update
    DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
    apt-get autoremove -y

    echo "Installing NVIDIA drivers..."
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers devices
    ubuntu-drivers autoinstall

    echo "NVIDIA GPU drivers installation completed."

    echo "Installing NVIDIA CUDA toolkit and container runtime..."
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | tee /etc/apt/sources.list.d/libnvidia-container.list

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-cuda-toolkit nvidia-container-toolkit nvidia-container-runtime

    echo "NVIDIA CUDA toolkit and container runtime installation completed."

    # Update nvidia runtime config
    CONFIG_FILE="/etc/nvidia-container-runtime/config.toml"

    if [ -f "$CONFIG_FILE" ]; then
        echo "Updating NVIDIA runtime configuration..."
        sed -i 's/#accept-nvidia-visible-devices-as-volume-mounts = false/accept-nvidia-visible-devices-as-volume-mounts = true/' "$CONFIG_FILE"
        sed -i 's/#accept-nvidia-visible-devices-envvar-when-unprivileged = true/accept-nvidia-visible-devices-envvar-when-unprivileged = false/' "$CONFIG_FILE"
    else
        echo "NVIDIA runtime configuration file not found."
    fi
fi

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

# Retrieve and echo the K3s token, unless in all-in-one mode
if [ "$all_in_one_mode" = false ]; then
    echo "Retrieving K3s token for worker nodes..."
    token=$(cat /var/lib/rancher/k3s/server/node-token)
    echo "K3s token for worker nodes: $token"
fi

echo "Please proceed with Akash provider account creation/import and export/storage of private key before running the next script."
