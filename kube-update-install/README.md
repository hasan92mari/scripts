# Kubernetes Cluster Setup Scripts

This repository contains two Bash scripts for setting up and maintaining a kubeadm-based Kubernetes cluster:

- `kubernetes.sh` — installs and upgrades Kubernetes components.
- `cilium.sh` — installs Cilium as the cluster CNI.

The scripts are designed to keep Kubernetes installation/upgrade and CNI installation as separate steps.

---

## Requirements

Before using the scripts, make sure you have:

- Ubuntu 22.04 or newer
- A supported CPU architecture
- A configured container runtime such as:
  - containerd
  - CRI-O
  - Docker via `cri-dockerd`
- Root or `sudo` access
- Network access to the Kubernetes APT repository and Helm repository

The container runtime must already be installed and configured before running `kubernetes.sh`.

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

After the primary control plane has been created, run:

```bash
sudo ./cilium.sh
```

The Cilium script will:

1. Verify that Kubernetes is initialized.
2. Configure the Cilium Helm repository.
3. Install Cilium into the `kube-system` namespace.
4. Wait for the Cilium DaemonSet to become ready.
5. Display the Cilium pods and Kubernetes nodes.

Verify the cluster:

```bash
kubectl get nodes
```

And check Cilium:

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

Then run it on the worker node.

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

Append these options to the join command:

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

The script:

1. Updates `kubeadm`.
2. Runs the appropriate `kubeadm upgrade` command.
3. Updates `kubelet`.
4. Updates `kubectl`.
5. Reloads systemd.
6. Restarts kubelet.
7. Verifies the installed versions.

---

## Node Drain During Upgrades

The script intentionally does **not** automatically drain or uncordon nodes.

Before upgrading a node, drain it manually from a control-plane node when required.

For example:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

After the upgrade has completed and the node is healthy:

```bash
kubectl uncordon <node-name>
```

Then verify:

```bash
kubectl get nodes
```

This approach keeps cluster scheduling operations separate from the package and Kubernetes upgrade script.

---

# 6. Kubernetes Version Rules

The Kubernetes version must be provided in exact `x.y.z` format.

Valid example:

```text
1.37.0
```

Invalid examples:

```text
v1.37.0
1.37
latest
```

For upgrades, the script:

- Does not allow downgrades.
- Does not run an update if the requested version is already installed.
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

Minor versions must be upgraded sequentially according to the Kubernetes upgrade process.

---

# 7. Package Holds

After installation or upgrade, the following packages are held:

```text
kubeadm
kubelet
kubectl
```

This prevents them from being upgraded unintentionally by normal APT operations.

The script automatically removes the holds before changing package versions and restores them afterward.

Check the holds with:

```bash
apt-mark showhold
```

---

# 8. Useful Commands

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

The general setup order is:

```text
1. Install/configure container runtime
           ↓
2. Create primary control plane
           ↓
3. Install Cilium
           ↓
4. Add additional control planes / workers
           ↓
5. Manage upgrades with kubernetes.sh
```

The scripts intentionally keep these responsibilities separate:

- Kubernetes lifecycle → `kubernetes.sh`
- CNI lifecycle → `cilium.sh`
- Node scheduling operations (`drain` / `uncordon`) → administrator