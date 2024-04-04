#!/usr/bin/env bash

# Example use:
# ./worker_script.sh -m 10.128.0.2 -t K1085a240214a2c903fabe6eaaf7785a439b227597e516294d208b38a122e62fa3e -g

# Worker Script

# Initialize variables
master_ip=""
token=""
install_gpu_drivers=false

# Process command-line options
while getopts ":m:t:g" opt; do
  case ${opt} in
    m )
      master_ip=$OPTARG
      ;;
    t )
      token=$OPTARG
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

# Check if the master IP and token have been provided
if [ -z "$master_ip" ] || [ -z "$token" ]; then
    echo "Both master IP (-m) and token (-t) must be provided."
    exit 1
fi

# Install K3s worker node
echo "Starting K3s installation on worker node..."
curl -sfL https://get.k3s.io | K3S_URL=https://$master_ip:6443 K3S_TOKEN=$token sh -

# Check if K3s agent is running
echo "Verifying K3s installation on worker node..."
if systemctl is-active --quiet k3s-agent; then
    echo "K3s installation completed on worker node."
else
    echo "K3s installation failed on worker node. Please check the logs for more information."
    exit 1
fi

# GPU host prep, driver, and toolkit install
if [ "$install_gpu_drivers" = true ]; then
    echo "Starting GPU host preparation, driver, and toolkit installation..."

    apt update
    DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
    apt-get autoremove -y

    echo "Installing NVIDIA drivers..."
    apt-get install -y ubuntu-drivers-common

    echo "Please follow the prompts to identify and install the recommended NVIDIA driver..."
    ubuntu-drivers devices

    echo "Running ubuntu-drivers autoinstall, please follow any interactive prompts..."
    ubuntu-drivers autoinstall

    echo "NVIDIA GPU drivers installation should be completed."

    echo "NVIDIA GPU drivers installation completed."

    echo "Installing NVIDIA CUDA toolkit and container runtime..."

    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | tee /etc/apt/sources.list.d/libnvidia-container.list

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-cuda-toolkit nvidia-container-toolkit nvidia-container-runtime

    echo "NVIDIA CUDA toolkit and container runtime installation completed."

    ### update nvidia runtime config - execute on worker nodes hosting gpu
 
    # Path to the NVIDIA container runtime configuration file
    CONFIG_FILE="/etc/nvidia-container-runtime/config.toml"

    # Check if the file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Use sed to uncomment and set the desired values
    sed -i 's/#accept-nvidia-visible-devices-as-volume-mounts = false/accept-nvidia-visible-devices-as-volume-mounts = true/' "$CONFIG_FILE"
    sed -i 's/#accept-nvidia-visible-devices-envvar-when-unprivileged = true/accept-nvidia-visible-devices-envvar-when-unprivileged = false/' "$CONFIG_FILE"
fi
