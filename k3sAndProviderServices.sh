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
internal_network=""
tls_san="" # Example: provider.h100.sdg.val.akash.pub
k3s_common_args="--disable=${disable_components} --flannel-backend=none"

# Process command-line options
while getopts ":d:e:tagm:c:r:w:n:s:" opt; do
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
    r )
      remove_node_ip=$OPTARG
      ;;
    w )
      remove_worker_ip=$OPTARG
      ;;
    n )
      internal_network=$OPTARG
      ;;
    s )
      tls_san=$OPTARG
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

if [[ -z "$internal_network" ]]; then
    echo "Please provide the internal network using the -n option."
    exit 1
fi

# Ensure only the first two octets (e.g., 172.18.) are used from the provided network
internal_network=$(echo "$internal_network" | cut -d'.' -f1,2)

# Detect the internal IP based on the first two octets of the provided network
internal_ip=$(hostname -I | tr ' ' '\n' | grep "^${internal_network}\." | head -n 1)

if [[ -z "$internal_ip" ]]; then
    echo "No IP found in the network ${internal_network}. Please verify."
    exit 1
fi

echo "Selected internal IP: $internal_ip"

# Remove control plane node logic
if [[ -n "$remove_node_ip" ]]; then
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl command could not be found, please install it to proceed."
        exit 1
    fi

    # Check if etcdctl is available
    if ! command -v etcdctl &> /dev/null; then
        echo "etcdctl command could not be found, attempting to install it..."
        apt update
        apt install -y etcd-client
        if ! command -v etcdctl &> /dev/null; then
            echo "Failed to install etcdctl, please install it manually."
            exit 1
        fi
    fi

    # Validate node exists
    if ! kubectl get node "$remove_node_ip" &> /dev/null; then
        echo "Specified node does not exist in the cluster."
        exit 1
    fi

    echo "Draining the node..."
    kubectl drain --ignore-daemonsets --delete-local-data $remove_node_ip || { echo "Failed to drain node"; exit 1; }

    echo "Removing the node from the cluster..."
    kubectl delete node $remove_node_ip || { echo "Failed to delete node"; exit 1; }

    # If etcd member needs to be removed:
    echo "Removing the etcd member..."
    etcd_member_id=$(etcdctl member list | grep $remove_node_ip | awk '{print $1}')
    if [ -n "$etcd_member_id" ]; then
        etcdctl member remove $etcd_member_id || { echo "Failed to remove etcd member"; exit 1; }
    else
        echo "No etcd member found for the specified IP."
    fi

    echo "Control plane node removed successfully."
    exit 0
fi

# Remove worker node logic
if [[ -n "$remove_worker_ip" ]]; then
    if ! kubectl get node "$remove_worker_ip" &> /dev/null; then
        echo "Specified worker node does not exist in the cluster."
        exit 1
    fi

    echo "Draining the worker node..."
    kubectl drain "$remove_worker_ip" --ignore-daemonsets --delete-local-data --force || { echo "Failed to drain worker node"; exit 1; }

    echo "Deleting the worker node from the cluster..."
    kubectl delete node "$remove_worker_ip" || { echo "Failed to delete worker node"; exit 1; }

    echo "Worker node removed successfully."
    exit 0
fi

# Function to update CoreDNS with 8.8.8.8 1.1.1.1 servers
update_coredns_config() {
    while ! kubectl -n kube-system get cm coredns >/dev/null 2>&1; do echo waiting for the coredns configmap resource ...; sleep 2; done
    echo "Patching CoreDNS configuration to use 8.8.8.8 1.1.1.1 servers instead of the systemd-resolved default..."
    kubectl patch configmap coredns -n kube-system --type merge -p '{"data":{"Corefile":".:53 {\n        errors\n        health\n        ready\n        kubernetes cluster.local in-addr.arpa ip6.arpa {\n          pods insecure\n          fallthrough in-addr.arpa ip6.arpa\n        }\n        hosts /etc/coredns/NodeHosts {\n          ttl 60\n          reload 15s\n          fallthrough\n        }\n        prometheus :9153\n        forward . 8.8.8.8 1.1.1.1\n        cache 30\n        loop\n        reload\n        loadbalance\n        import /etc/coredns/custom/*.override\n    }\n    import /etc/coredns/custom/*.server"}}'
    echo "CoreDNS configuration patched."
}

# Add control plane node logic
if [[ "$mode" == "init" ]]; then
    echo "Starting initial K3s installation on master node..."
    install_exec="--cluster-init"
    if [[ -n "$external_ip" ]]; then
        install_exec+=" --node-external-ip=${external_ip}"
    fi
    install_exec+=" --node-ip=${internal_ip}"
    if [[ -n "$tls_san" ]]; then
        install_exec+=" --tls-san=${tls_san}"
    fi
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$k3s_common_args $install_exec" sh -
    echo "K3s installation completed."
    token=$(cat /var/lib/rancher/k3s/server/token)
    echo "K3s control-plane and worker node token: $token"
    echo "Installing Calico CNI..."
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/refs/tags/v3.28.2/manifests/calico.yaml
    echo "Calico CNI installation completed."

    # Ensure jq is installed for JSON processing
    if ! command -v jq &> /dev/null; then
        echo "jq is not installed. Installing jq..."
        apt-get update && apt-get install -y jq
    fi

    update_coredns_config  # Update the CoreDNS ConfigMap

    # Install provider-services on master
    echo "Installing provider-services..."
    cd ~
    apt-get update
    apt-get install -y unzip
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

    if [[ "$all_in_one_mode" == "false" ]]; then
        echo "Please proceed with Akash provider account creation/import and export/storage of private key before running the next script."
    fi
else
    if [[ -z "$master_ip" || -z "$token" ]]; then
        echo "Both master IP (-m) and token (-c) must be provided to add a control-plane node."
        exit 1
    fi
    echo "Adding a new control-plane node to the cluster..."
    install_exec=""
    if [[ -n "$external_ip" ]]; then
        install_exec+=" --node-external-ip=${external_ip}"
    fi
    install_exec+=" --node-ip=${internal_ip}"
    if [[ -n "$tls_san" ]]; then
        install_exec+=" --tls-san=${tls_san}"
    fi
    # when K3S_URL is used, must add "server" when adding a new control-plane nodes to the cluster
    # it also must go first in the order, otherwise k3s.service will fail to start
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server ${k3s_common_args} ${install_exec}" K3S_URL="https://$master_ip:6443" K3S_TOKEN="$token" sh -
    echo "Control-plane node added to the cluster."
fi

# Update the kubeconfig file if an external IP is specified
if [[ -n "$external_ip" ]]; then
    echo "Updating kubeconfig file to use both internal and external IP addresses..."

    # Define paths for the kubeconfig files
    kubeconfig_path=/etc/rancher/k3s/k3s.yaml

    # Extract the current certificate-authority-data
    ca_data=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

    # Create a new kubeconfig content with both internal and external IPs
    cat <<EOF > ${kubeconfig_path}
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${ca_data}
    server: https://${external_ip}:6443
  name: k3s-cluster
contexts:
- context:
    cluster: k3s-cluster
    user: default
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: default
  user:
    client-certificate-data: $(kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')
    client-key-data: $(kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}')
EOF

    echo "kubeconfig file updated to use both internal and external IP addresses with a single context."
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
    echo "Installing NVIDIA container runtime..."
    distribution="stable/deb"
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | tee /etc/apt/sources.list.d/libnvidia-container.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit nvidia-container-runtime
    echo "NVIDIA container runtime installation completed."
    CONFIG_FILE="/etc/nvidia-container-runtime/config.toml"
    if [ -f "$CONFIG_FILE" ]; then
        echo "Updating NVIDIA runtime configuration..."
        sed -i 's/#accept-nvidia-visible-devices-as-volume-mounts = false/accept-nvidia-visible-devices-as-volume-mounts = true/' "$CONFIG_FILE"
        sed -i 's/#accept-nvidia-visible-devices-envvar-when-unprivileged = true/accept-nvidia-visible-devices-envvar-when-unprivileged = false/' "$CONFIG_FILE"
    else
        echo "NVIDIA runtime configuration file not found."
    fi
fi

echo "Setup completed."
