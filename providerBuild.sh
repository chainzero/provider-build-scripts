### todos
### add values.yaml config for inventory operator to update storage type/class
### update docs for persistent storage

#!/usr/bin/env bash

# Provider Setup Script

# Usage instructions
# ./providerBuild.sh -a akash1mtnuc449l0mckz4cevs835qg72nvqwlul5wzyf -k akashprovider -d akashtesting.xyz -n http://akash-node-1:26657  -g -w worker -s -p

# Initialize variables with default values or empty
ACCOUNT_ADDRESS=""
KEY_PASSWORD=""
DOMAIN=""
NODE=""
install_gpu_support=false
gpu_nodes=()
install_storage_support=false
use_pricing_script=false
storage_class_name=""

# Process command-line options
while getopts ":a:k:d:n:gw:spb:" opt; do
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
helm install akash-hostname-operator akash/akash-hostname-operator -n akash-services
helm install inventory-operator akash/akash-inventory-operator -n akash-services
helm install akash-node akash/akash-node -n akash-services

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
attributes:
  - key: region
    value: "us-east" 
  - key: host
    value: akash
  - key: tier
    value: community
  - key: organization
    value: "akashtesting"
  - key: capabilities/gpu/vendor/nvidia/model/t4
    value: true
  - key: capabilities/storage/1/class
    value: beta3
  - key: capabilities/storage/1/persistent
    value: true
price_target_cpu: 1.60
price_target_memory: 0.80
price_target_hd_ephemeral: 0.02
price_target_hd_pers_hdd: 0.01
price_target_hd_pers_ssd: 0.03
price_target_hd_pers_nvme: 0.04
price_target_endpoint: 0.05
price_target_ip: 5
price_target_gpu_mappings: "t4=80"
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
kubectl apply -f https://raw.githubusercontent.com/akash-network/provider/v0.5.4/pkg/apis/akash.network/crd.yaml

# Install Akash provider with or without the pricing script
echo "Installing Akash provider..."
if [ "$use_pricing_script" = true ]; then
    helm install akash-provider akash/provider -n akash-services -f ~/provider/provider.yaml --set bidpricescript="$PRICING_SCRIPT_B64"
else
    helm install akash-provider akash/provider -n akash-services -f ~/provider/provider.yaml
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
      --version 0.14.5 \
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

    # Install the Rook-Ceph Helm chart for the operator
    echo "Installing Rook-Ceph operator..."
    helm install --create-namespace -n rook-ceph rook-ceph rook-release/rook-ceph --version 1.14.0
    echo "Rook-Ceph operator installation completed."

    # Install the Rook-Ceph cluster
    echo "Installing Rook-Ceph cluster..."
    helm install --create-namespace -n rook-ceph rook-ceph-cluster \
       --set operatorNamespace=rook-ceph rook-release/rook-ceph-cluster --version 1.14.0 \
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

