#!/usr/bin/env bash

# Provider Setup Script

# Usage instructions
# "Usage: $0 -a ACCOUNT_ADDRESS -k KEY_PASSWORD -d DOMAIN -n NODE [-g -w 'worker1,worker2'] [-p]"
# "Example: $0 -a akash1mtnuc449l0mckz4cevs835qg72nvqwlul5wzyf -k akash -d akashtesting.xyz -n http://akash-node-1:26657 -g -w worker1,worker2 -p"

# Initialize variables with default values or empty
ACCOUNT_ADDRESS=""
KEY_PASSWORD=""
DOMAIN=""
NODE=""
install_gpu_support=false
gpu_nodes=()
use_pricing_script=false

# Process command-line options
while getopts ":a:k:d:n:gw:p" opt; do
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
    p )
      use_pricing_script=true
      ;;
    w )
      IFS=',' read -r -a gpu_nodes <<< "$OPTARG"
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
helm repo remove akash 2>/dev/null || true # Ignore errors if the repo is not found
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
EOF

echo "Provider configuration prepared."

# Download and prepare the pricing script if the -p option is used
if [ "$use_pricing_script" = true ]; then
    echo "Downloading custom pricing script..."
    wget https://raw.githubusercontent.com/akash-network/helm-charts/main/charts/akash-provider/scripts/price_script_generic.sh
    PRICING_SCRIPT_B64="$(cat price_script_generic.sh | openssl base64 -A)"
fi

# Install CRDs for Akash provider
echo "Installing CRDs for Akash provider..."
kubectl apply -f https://raw.githubusercontent.com/akash-network/provider/v0.5.4/pkg/apis/akash.network/crd.yaml

# Install Akash provider with or without the pricing script
echo "Installing Akash provider..."
if [ "$use_pricing_script" = true ]; then
    helm install akash-provider akash/provider -n akash-services -f provider.yaml --set bidpricescript="$PRICING_SCRIPT_B64"
else
    helm install akash-provider akash/provider -n akash-services -f provider.yaml
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

# Configure NVIDIA Runtime Engine if GPUs are part of the cluster
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
        kubectl label nodes "$node" allow-nvdp=true --overwrite
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

echo "Provider setup completed."
