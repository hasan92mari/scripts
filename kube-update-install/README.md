# Kubernetes Cluster Setup Scripts

This repository contains two Bash scripts for setting up and maintaining a kubeadm-based Kubernetes cluster:

- `kubernetes.sh` — installs and upgrades Kubernetes components.
- `cilium.sh` — installs Cilium as the cluster CNI.

The scripts keep Kubernetes lifecycle, CNI installation, and node scheduling operations as separate responsibilities.

---

## Prerequisites

Before running the scripts, make sure the following requirements are met.

### Operating System

- Ubuntu 22.04 or newer
- Supported CPU architecture
- Root or `sudo` access
- Internet access

### Container Runtime

A supported CRI-compatible container runtime must already be installed and configured.

Supported runtimes:

- containerd
- CRI-O
- Docker via `cri-dockerd`

The runtime must be running before executing `kubernetes.sh`.

### Helm

**Helm must be installed before running `cilium.sh`.**

Check whether Helm is installed:

```bash
helm version
```

If Helm is not installed, install it before running the Cilium script.

The Cilium script uses Helm to install the Cilium Helm chart.

### kubectl

`kubectl` must also be available on the primary control-plane node before running `cilium.sh`.

Check:

```bash
kubectl version --client
```

---

# 1. Create the Primary Control Plane

Run:

```bash
sudo ./kubernetes.sh create 1.37.0 control-plane
```

The script will:

1. Validate the operating system and architecture.
2. Check the container runtime.
3. Configure the Kubernetes APT repository.
4. Install the requested versions of:
   - `kubeadm`
   - `kubelet`
   - `kubectl`
5. Hold the installed Kubernetes packages.
6. Initialize the Kubernetes control plane with `kubeadm init`.

The script does **not** install a CNI.

---

# 2. Install Cilium

After the primary control plane has been created, make sure Helm is installed.

Check:

```bash
helm version
```

Then run:

```bash
sudo ./cilium.sh
```

The Cilium script will:

1. Verify that Kubernetes is initialized.
2. Verify that `kubectl` and `helm` are available.
3. Configure the Cilium Helm repository.
4. Install Cilium into the `kube-system` namespace.
5. Wait for the Cilium DaemonSet to become ready.
6. Display the Cilium pods and Kubernetes nodes.

Verify the cluster:

```bash
kubectl get nodes
```

Check Cilium:

```bash
kubectl get pods -n kube-system -l k8s-app=cilium
```

---

# 3. Add a Worker Node

On the primary control plane, generate a worker join command:

```bash
kubeadm token create --print-join-command
```

Copy the complete command.

Then execute it on the worker node.

Example:

```bash
kubeadm join <CONTROL_PLANE_ENDPOINT>:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

After the worker joins, verify it from the control plane:

```bash
kubectl get nodes
```

---

# 4. Add an Additional Control Plane

On an existing control-plane node, generate the certificate key:

```bash
kubeadm init phase upload-certs --upload-certs
```

Save the certificate key printed by the command.

Then generate the normal join command:

```bash
kubeadm token create --print-join-command
```

Append:

```text
--control-plane --certificate-key <CERTIFICATE_KEY>
```

The final command will look similar to:

```bash
kubeadm join <CONTROL_PLANE_ENDPOINT>:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --control-plane \
    --certificate-key <CERTIFICATE_KEY>
```

Run the complete command on the additional control-plane node.

Then verify:

```bash
kubectl get nodes
```

---

# 5. Upgrade Kubernetes

The script supports Kubernetes upgrades using the `update` action.

For example, to upgrade from `1.37.0` to `1.37.1`:

```bash
sudo ./kubernetes.sh update 1.37.1 worker
```

For a primary control plane:

```bash
sudo ./kubernetes.sh update 1.37.1 control-plane
```

For an additional control plane:

```bash
sudo ./kubernetes.sh update 1.37.1 additional-control-plane
```

## IMPORTANT: Drain the Node Before an Upgrade

**The node must be drained before running the update script.**

The update script intentionally does **not** perform `kubectl drain` automatically.

This means the administrator is responsible for preparing the node before the upgrade.

### Worker

From a control-plane node:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then, on the worker node, run:

```bash
sudo ./kubernetes.sh update 1.37.1 worker
```

After the upgrade completes and the node is confirmed healthy, uncordon it from a control-plane node:

```bash
kubectl uncordon <node-name>
```

### Additional Control Plane

Before updating an additional control-plane node, drain it from another control-plane node:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then run the update on the node:

```bash
sudo ./kubernetes.sh update 1.37.1 additional-control-plane
```

After verifying that the node is healthy:

```bash
kubectl uncordon <node-name>
```

### Primary Control Plane

Before updating the primary control-plane node, make sure the cluster can continue operating with the other control-plane nodes.

Drain the node from another control-plane node when appropriate:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then run:

```bash
sudo ./kubernetes.sh update 1.37.1 control-plane
```

After verifying that the node is healthy:

```bash
kubectl uncordon <node-name>
```

Finally:

```bash
kubectl get nodes
```

---

# 6. What the Update Script Does

The update script:

1. Updates `kubeadm`.
2. Runs the appropriate `kubeadm upgrade` command.
3. Updates `kubelet`.
4. Updates `kubectl`.
5. Reloads systemd.
6. Restarts kubelet.
7. Verifies the installed versions.

The script does **not**:

- Drain nodes.
- Uncordon nodes.
- Install or upgrade Cilium.
- Perform cluster scheduling operations.

Node draining and uncordoning must be handled manually.

---

# 7. Kubernetes Version Rules

The Kubernetes version must be provided in exact `x.y.z` format.

Valid:

```text
1.37.0
```

Invalid:

```text
v1.37.0
1.37
latest
```

For upgrades, the script:

- Does not allow downgrades.
- Does not update to the same version.
- Does not skip Kubernetes minor versions.

For example:

```text
1.36.5 → 1.37.0
```

is supported.

But:

```text
1.36.5 → 1.38.0
```

is rejected.

Minor versions must be upgraded sequentially.

---

# 8. Package Holds

After installation or upgrade, the following packages are held:

```text
kubeadm
kubelet
kubectl
```

This prevents them from being upgraded unintentionally by normal APT operations.

The script automatically removes the holds before changing package versions and restores them afterward.

Check the holds:

```bash
apt-mark showhold
```

---

# 9. Useful Commands

Check Kubernetes nodes:

```bash
kubectl get nodes -o wide
```

Check all pods:

```bash
kubectl get pods -A
```

Check Cilium:

```bash
kubectl get pods -n kube-system -l k8s-app=cilium
```

Check kubelet:

```bash
systemctl status kubelet
```

Check Kubernetes versions:

```bash
kubeadm version -o short
kubelet --version
kubectl version --client
```

Generate a worker join command:

```bash
kubeadm token create --print-join-command
```

---

# Script Summary

| Script | Purpose |
|---|---|
| `kubernetes.sh` | Install and upgrade Kubernetes |
| `cilium.sh` | Install Cilium CNI |

General setup order:

```text
1. Install and configure container runtime
                 ↓
2. Install Helm
                 ↓
3. Create primary control plane
                 ↓
4. Install Cilium
                 ↓
5. Add additional control planes / workers
                 ↓
6. Drain node before every upgrade
                 ↓
7. Upgrade Kubernetes
                 ↓
8. Verify node health
                 ↓
9. Uncordon node
```

The scripts intentionally keep these responsibilities separate:

- Kubernetes lifecycle → `kubernetes.sh`
- CNI lifecycle → `cilium.sh`
- Node scheduling (`drain` / `uncordon`) → administrator