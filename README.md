# provider-build-scripts

## Example cluster installation

> `172.18.*` is the internal network

1. Initialize the control-plane node

> `provider.h100.sdg.val.akash.pub` is just the example  

```
./k3sAndProviderServices.sh -d traefik -s provider.h100.sdg.val.akash.pub -g -n 172.18.
```

If a node has a separate ephemeral storage directory, make sure to specify the -o and -k switches followed by the location. 
Example:
ephemeral storage location: `/data/`

```
./k3sAndProviderServices.sh -d traefik -s provider.h100.sdg.val.akash.pub -g -n 172.18. -o /data/k3s -k /data/kubelet
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
./k3sAndProviderServices.sh -s provider.h100.sdg.val.akash.pub -m 172.18.140.11 -c $TOKEN -g -n 172.18.
```
Again, if the ephemeral storage location is not at the default value, specify it using the -k and -o switches.
Example:

```
./k3sAndProviderServices.sh -s provider.h100.sdg.val.akash.pub -m 172.18.140.11 -c $TOKEN -g -n 172.18. -o /data/k3s -k /data/kubelet
```

3. Join the worker nodes

```
./workerNode.sh -m 172.18.140.11 -t ${TOKEN} -g
```

If the ephemeral storage location is not at the default value, specify it using the -k and -o switches.

```
./workerNode.sh -m 172.18.140.11 -t ${TOKEN} -g -o /data/k3s -k /data/kubelet
```

NODE UPGRADE:
Please do not use the upgradeNode.sh at this point, it is a work in progress.
