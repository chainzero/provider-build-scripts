# provider-build-scripts


## Example cluster installation

> `172.18.*` is the internal network

1. Initialize the control-plane node

> `provider.h100.sdg.val.akash.pub` is just the example  
> `-e` - `curl -s ident.me` returns a public IP of the node  

```
./k3sAndProviderServices.sh -d traefik -e $(curl -s ident.me) -s provider.h100.sdg.val.akash.pub -g -n 172.18.
```

If the cluster has a dedicated ephemeral storage, specify the location using -o and -k
Example

```
./k3sAndProviderServices.sh -d traefik -e $(curl -s ident.me) -s provider.h100.sdg.val.akash.pub -g -n 172.18. -o /data/containerd -k /data/kubelet
```

IMPORTANT: Note down the line `K3s control-plane and worker node token:` as it'll contain the token you'll need to join further nodes.
If you forget to save this info, you can always get it by running `cat /var/lib/rancher/k3s/server/node-token` command.

2. Join the 2nd and 3rd control-pane nodes

IMPORTANT: Make sure to have at least 3 control-plane nodes. If you only have two, then it means you only have two etcd (embedded into k3s) Kubernetes databases. When less than half are down, etcd won't work.

> `172.18.140.11` is the internal IP of the first control-plane node  

```
echo -n "Enter K3s control-plane and worker node token: "
read -s TOKEN
echo
./k3sAndProviderServices.sh -s provider.h100.sdg.val.akash.pub -e $(curl -s ident.me) -m 172.18.140.11 -c $TOKEN -g -n 172.18.
```

3. Join the worker nodes

```
./workerNode.sh -m 172.18.140.11 -t ${TOKEN} -g
```
