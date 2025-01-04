#!/usr/bin/env bash

# Provider Setup Script

# Initialize variables with default values or empty
ACCOUNT_ADDRESS=""
KEY_PASSWORD=""
DOMAIN=""
NODE=""  # Default to empty, will be set later based on chain_id or user input
chain_id="akashnet-2"  # Default chain ID
provider_version=""  # Will be fetched from Helm Chart
node_version=""  # Will be fetched from Helm Chart
install_gpu_support=false
gpu_nodes=()
install_storage_support=true
use_pricing_script=true
storage_class_name="beta3"

### LOGIC THAT DETERMINES EPHEMERAL STORAGE LOCATION

# Default paths
DEFAULT_NODEFS_DIR="/var/lib/kubelet"
DEFAULT_IMAGEFS_DIR="/var/lib/rancher/k3s"

# K3S Service file
SERVICE_FILE="/etc/systemd/system/k3s.service"

# Function to extract path from argument - we will use this later to determine the path
extract_path() {
  local arg=$1
  local default_path=$2

  # If no path is found in service file, return default
  if [ -z "$arg" ]; then
    echo "$default_path"
    return
  fi

  # Extract the path value
  echo "$arg" | sed 's/.*=\(.*\)/\1/'
}

# Extract the ExecStart command using systemctl
EXECSTART=$(systemctl show k3s.service --property=ExecStart --no-pager -l | sed 's/.*ExecStart=//')

# Look for root-dir (nodefs) argument
NODEFS_ARG=$(echo "$EXECSTART" | grep -o "\--kubelet-arg=root-dir=[^ ]*")
NODEFS_DIR=$((extract_path "$NODEFS_ARG" "$DEFAULT_NODEFS_DIR") | tr -d "'")
IMAGEFS_ARG=$(echo "$EXECSTART" | grep -o "\--data-dir=[^ ]*")
IMAGEFS_DIR=$((extract_path "$IMAGEFS_ARG" "$DEFAULT_IMAGEFS_DIR") | tr -d "'")

# Debugging Output results
echo "nodefs directory: $NODEFS_DIR"
echo "imagefs directory: $IMAGEFS_DIR"

# Function to fetch appVersion from Helm Chart
fetch_app_version() {
  local chart_url=$1
  local version_field="appVersion"
  curl -s $chart_url | grep "^$version_field:" | awk '{print $2}'
}

# Fetch the latest provider version and node version
provider_version=$(fetch_app_version "https://raw.githubusercontent.com/akash-network/helm-charts/main/charts/akash-provider/Chart.yaml")
node_version=$(fetch_app_version "https://raw.githubusercontent.com/akash-network/helm-charts/main/charts/akash-node/Chart.yaml")

# Check if versions were fetched successfully
if [ -z "$provider_version" ] || [ -z "$node_version" ]; then
  echo "Failed to fetch the latest versions. Please check the Helm Chart URLs."
  exit 1
fi

# Process command-line options
while getopts ":a:k:d:n:gw:spbc:v:x:y:" opt; do
  case ${opt} in
    a )
      ACCOUNT_ADDRESS=$OPTARG
      ;;
    k )
      KEY_PASSWORD=$OPTARG
      ;;
    d )
      DOMAIN=$OPTARG
      ;;
    n )
      NODE=$OPTARG
      ;;
    g )
      install_gpu_support=true
      ;;
    w )
      IFS=',' read -r -a gpu_nodes <<< "$OPTARG"
      ;;
    s )
      install_storage_support=true
      ;;
    p )
      use_pricing_script=true
      ;;
    b )
      storage_class_name=$OPTARG
      ;;
    c )
      chain_id=$OPTARG  # User specified chain ID
      ;;
    v )
      provider_version=$OPTARG  # User specified provider image version
      ;;
    x )
      node_version=$OPTARG  # User specified node image version
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

# Set NODE based on chain_id if not explicitly set by the user
if [ -z "$NODE" ]; then
  if [ "$chain_id" == "sandbox-01" ]; then
    NODE="https://rpc.sandbox-01.aksh.pw:443"
  else
    NODE="http://akash-node-1:26657"
  fi
fi

# Check if all required options are provided
if [ -z "$ACCOUNT_ADDRESS" ] || [ -z "$KEY_PASSWORD" ] || [ -z "$DOMAIN" ] || [ -z "$NODE" ]; then
    echo "All options -a (account address), -k (key password), -d (domain), and -n (node) are required."
    exit 1
fi

# Export the environment variables
export ACCOUNT_ADDRESS
export KEY_PASSWORD
export DOMAIN
export NODE

# Set KUBECONFIG
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Install Helm
echo "Installing Helm..."
wget https://get.helm.sh/helm-v3.11.0-linux-amd64.tar.gz
tar -zxvf helm-v3.11.0-linux-amd64.tar.gz
install linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64 helm-v3.11.0-linux-amd64.tar.gz

# Setup Helm repositories
echo "Setting up Helm repositories..."
helm repo remove akash 2>/dev/null || true
helm repo add akash https://akash-network.github.io/helm-charts
helm repo update

echo "Helm and Akash repository setup completed."

# Install Akash services using Helm
echo "Installing Akash services..."
helm install akash-hostname-operator akash/akash-hostname-operator -n akash-services --set image.tag=$provider_version
helm install inventory-operator akash/akash-inventory-operator -n akash-services --set image.tag=$provider_version

# Conditionally install akash-node based on chain_id
if [ "$chain_id" != "sandbox-01" ]; then
  helm install akash-node akash/akash-node -n akash-services --set image.tag=$node_version
fi

helm install akash-provider akash/provider -n akash-services -f ~/provider/provider.yaml --set image.tag=$provider_version

echo "Akash services installed."

# Prepare provider configuration
echo "Preparing provider configuration..."
mkdir -p ~/provider
cd ~/provider

cat > provider.yaml << EOF
---
from: "$ACCOUNT_ADDRESS"
key: "$(cat ~/key.pem | openssl base64 -A)"
keysecret: "$(echo $KEY_PASSWORD | openssl base64 -A)"
domain: "$DOMAIN"
node: "$NODE"
withdrawalperiod: 12h
chainid: "$chain_id"
EOF

echo "Provider configuration prepared."

# If pricing script option is used
if [ "$use_pricing_script" = true ]; then
    echo "Downloading and preparing custom pricing script..."
    wget https://raw.githubusercontent.com/akash-network/helm-charts/main/charts/akash-provider/scripts/price_script_generic.sh -O ~/provider/price_script_generic.sh
    PRICING_SCRIPT_B64=$(cat ~/provider/price_script_generic.sh | openssl base64 -A)
fi

# Install CRDs for Akash provider
echo "Installing CRDs for Akash provider..."
kubectl apply -f https://raw.githubusercontent.com/akash-network/provider/v${provider_version}/pkg/apis/akash.network/crd.yaml

# Install Akash provider with or without the pricing script
echo "Installing Akash provider..."
if [ "$use_pricing_script" = true ]; then
    helm install akash-provider akash/provider -n akash-services -f ~/provider/provider.yaml --set bidpricescript="$PRICING_SCRIPT_B64" --set image.tag=$provider_version
else
    helm install akash-provider akash/provider -n akash-services -f ~/provider/provider.yaml --set image.tag=$provider_version
fi

echo "Akash provider installation completed."

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."
cd ~
cat > ingress-nginx-custom.yaml << EOF
controller:
  service:
    type: ClusterIP
  ingressClassResource:
    name: "akash-ingress-class"
  kind: DaemonSet
  hostPort:
    enabled: true
  admissionWebhooks:
    port: 7443
  config:
    allow-snippet-annotations: false
    compute-full-forwarded-for: true
    proxy-buffer-size: "16k"
  metrics:
    enabled: true
  extraArgs:
    enable-ssl-passthrough: true
tcp:
  "8443": "akash-services/akash-provider:8443"
  "8444": "akash-services/akash-provider:8444"
EOF
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.10.0 \
  --namespace ingress-nginx --create-namespace \
  -f ingress-nginx-custom.yaml
kubectl label ns ingress-nginx app.kubernetes.io/name=ingress-nginx app.kubernetes.io/instance=ingress-nginx
kubectl label ingressclass akash-ingress-class akash.network=true
echo "NGINX Ingress Controller installation completed."

# Apply NVIDIA Runtime Engine and label GPU nodes if GPUs are part of the cluster
if [ "$install_gpu_support" = true ]; then
    echo "Configuring NVIDIA Runtime Engine..."

    cat > nvidia-runtime-class.yaml << EOF
kind: RuntimeClass
apiVersion: node.k8s.io/v1
metadata:
  name: nvidia
handler: nvidia
EOF

    kubectl apply -f nvidia-runtime-class.yaml

    for node in "${gpu_nodes[@]}"; do
        echo "Labeling $node for NVIDIA support..."
        kubectl label nodes "$node" allow-nvdp=true
    done

    echo "Adding NVIDIA Device Plugin Helm repository..."
    helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
    helm repo update

    echo "Installing NVIDIA Device Plugin..."
    helm upgrade -i nvdp nvdp/nvidia-device-plugin \
      --namespace nvidia-device-plugin \
      --create-namespace \
      --version 0.16.2 \
      --set runtimeClassName="nvidia" \
      --set deviceListStrategy=volume-mounts \
      --set-string nodeSelector.allow-nvdp="true"

    echo "NVIDIA Runtime Engine configuration completed."
fi

# If storage support is enabled, configure Rook-Ceph and update the custom controller if needed
if [ "$install_storage_support" = true ]; then
    echo "Adding Rook-Ceph Helm repository for persistent storage support..."
    helm repo add rook-release https://charts.rook.io/release
    helm repo update
    echo "Rook-Ceph repository added."

    # Create the rook-ceph-operator.values.yml file and append the kubelet directory location

    # Check if NODEFS_DIR is different from default and create values file if needed
    if [ "$NODEFS_DIR" != "$DEFAULT_NODEFS_DIR" ]; then
    #Create or overwrite the values file
    #Debugging print the value of $NODEFS_DIR
    echo "$NODEFS_DIR"
    cat > /root/provider/rook-ceph-operator.values.yml << EOF
csi:
  kubeletDirPath: "$NODEFS_DIR"
EOF
    echo "Created /root/provider/rook-ceph-operator.values.yml with custom kubeletDirPath"
fi

    # Install the Rook-Ceph Helm chart for the operator
    echo "Installing Rook-Ceph operator..."
    helm install --create-namespace -n rook-ceph rook-ceph rook-release/rook-ceph --version 1.16.1 -f ~/provider/rook-ceph-operator.values.yml
    echo "Rook-Ceph operator installation completed."

    # Install the Rook-Ceph cluster
    echo "Installing Rook-Ceph cluster..."
    helm install --create-namespace -n rook-ceph rook-ceph-cluster \
       --set operatorNamespace=rook-ceph rook-release/rook-ceph-cluster --version 1.16.1 \
       -f ~/provider/rook-ceph-cluster.values.yml
    echo "Rook-Ceph cluster installation completed."

    # Label the StorageClass
    if [ -n "$storage_class_name" ]; then
        echo "Labeling StorageClass $storage_class_name for Akash integration..."
        kubectl label sc "$storage_class_name" akash.network=true
        echo "StorageClass $storage_class_name labeled for Akash integration."

        # Update the inventory operator if the storage class is not 'beta3' which is the default in the operator helm chart
        if [ "$storage_class_name" != "beta3" ]; then
            echo "Updating the inventory operator to use storage class $storage_class_name..."
            helm upgrade inventory-operator akash/akash-inventory-operator -n akash-services \
                --set inventoryConfig.cluster_storage[0]=default,inventoryConfig.cluster_storage[1]=$storage_class_name,inventoryConfig.cluster_storage[2]=ram
            echo "Inventory operator updated to use storage class $storage_class_name."
        fi
    fi
fi

echo "Provider setup completed."
