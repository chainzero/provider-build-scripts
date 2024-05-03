#!/usr/bin/env bash

# Kubernetes Installation with Provider Services Script

# Default values for options
disable_components="traefik"
external_ip=""
testing_mode=false
all_in_one_mode=false
install_gpu_drivers=false
mode="init"  # 'init' for initial setup, 'add' for adding control-plane nodes
master_ip=""
token=""

# Process command-line options
while getopts ":d:e:tagm:c:" opt; do
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
    m )
      master_ip=$OPTARG
      ;;
    c )
      token=$OPTARG
      mode="add"
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

if [[ "$mode" == "init" ]]; then
    echo "Starting initial K3s installation on master node..."
    install_exec="--disable=${disable_components} --flannel-backend=none --cluster-init"
    if [[ -n "$external_ip" ]]; then
        install_exec+=" --tls-san=${external_ip}"
    fi
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$install_exec" sh -
    echo "K3s installation completed."
    token=$(cat /var/lib/rancher/k3s/server/token)
    echo "K3s control-plane and worker node token: $token"
    echo "Installing Calico CNI..."
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
    echo "Calico CNI installation completed."
else
    if [[ -z "$master_ip" || -z "$token" ]]; then
        echo "Both master IP (-m) and token (-c) must be provided to add a control-plane node."
        exit 1
    fi
    echo "Adding a new control-plane node to the cluster..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --flannel-backend=none --node-taint CriticalAddonsOnly=true:NoExecute" K3S_URL="https://$master_ip:6443" K3S_TOKEN="$token" sh -
    echo "Control-plane node added to the cluster."
fi

# Update the kubeconfig file if an external IP is specified
if [[ -n "$external_ip" ]]; then
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "Updating kubeconfig file to use external IP address..."
    sed -i "s/127.0.0.1/$external_ip/g" $KUBECONFIG
    echo "kubeconfig file updated to use external IP address."
fi

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

# Create and label Kubernetes namespaces
echo "Creating and labeling Kubernetes namespaces..."
for ns in akash-services lease; do
    if kubectl get ns $ns > /dev/null 2>&1; then
        echo "Namespace $ns already exists."
    else
        kubectl create ns $ns
        echo "Namespace $ns created."
    fi
done
kubectl label ns akash-services akash.network/name=akash-services akash.network=true --overwrite
kubectl label ns lease akash.network=true --overwrite

# Only output the Akash provider message if this is the initial setup
if [[ "$all_in_one_mode" == "false" && "$mode" == "init" ]]; then
    echo "Please proceed with Akash provider account creation/import and export/storage of private key before running the next script."
fi

echo "Setup completed."
