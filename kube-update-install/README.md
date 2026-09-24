# Kubernetes Cluster Setup Scripts

Bash scripts for creating and maintaining a **kubeadm-based Kubernetes cluster**.

The repository contains:

- `kubernetes.sh` — installs and upgrades Kubernetes.
- `cilium.sh` — installs Cilium as the cluster CNI.

The scripts keep **Kubernetes lifecycle**, **CNI lifecycle**, and **node scheduling** separate.

---

# Quick Start

## 1. Create the Primary Control Plane

```bash
sudo ./kubernetes.sh \
    -a create \
    -t 1.37.0 \
    -n control-plane
```

## 2. Install Cilium

```bash
sudo ./cilium.sh
```

## 3. Add Workers

Generate the join command on a control-plane node:

```bash
kubeadm token create --print-join-command
```

Run the generated command on the worker.

## 4. Add Additional Control Planes

Generate the certificate key:

```bash
kubeadm init phase upload-certs --upload-certs
```

Then generate the join command:

```bash
kubeadm token create --print-join-command
```

Append:

```text
--control-plane --certificate-key <CERTIFICATE_KEY>
```

Run the resulting `kubeadm join` command on the additional control-plane node.

## 5. Upgrade Kubernetes

First drain the node from a control-plane node:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then run the update:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n worker
```

After verifying the node:

```bash
kubectl uncordon <node-name>
```

## 6. Remote Upgrade over SSH

The script can also be sent directly to a remote node without copying it first:

```bash
ssh worker-node-3-a \
    'sudo bash -s -a update -t 1.37.1 -n worker' \
    < kubeadm-cluster-create-update.sh
```

---

# 1. Prerequisites

Before using the scripts, make sure the following requirements are met.

## Operating System

- Ubuntu 22.04 or newer
- Supported CPU architecture
- Root or `sudo` access
- Internet access

## Container Runtime

A supported CRI-compatible runtime must already be installed and configured.

Supported runtimes:

- containerd
- CRI-O
- Docker via `cri-dockerd`

The runtime must be running before executing `kubernetes.sh`.

## Helm

Helm must be installed before running `cilium.sh`.

Check:

```bash
helm version
```

The Cilium script uses Helm to install the Cilium Helm chart.

## kubectl

`kubectl` must be available on the primary control-plane node before running `cilium.sh`.

Check:

```bash
kubectl version --client
```

---

# 2. Kubernetes Script

## Usage

The script uses command-line flags:

```text
-a    Action
-t    Target Kubernetes version
-n    Node type
-p    Optional kubeadm patches directory
-h    Help
```

General syntax:

```bash
sudo ./kubernetes.sh \
    -a <create|update> \
    -t <x.y.z> \
    -n <node-type> \
    [-p <patches-directory>]
```

### Actions

Supported actions:

```text
create
update
```

### Node Types

Supported node types:

```text
control-plane
additional-control-plane
worker
```

### Target Version

The target version must use the exact `x.y.z` format.

Example:

```text
1.37.1
```

Do not use:

```text
v1.37.1
1.37
latest
```

### Patches

The optional `-p` flag specifies a kubeadm patches directory.

Example:

```bash
-p /etc/kubernetes/patches
```

When provided, the directory is passed to the relevant `kubeadm upgrade` command.

---

# 3. Create the Primary Control Plane

Run:

```bash
sudo ./kubernetes.sh \
    -a create \
    -t 1.37.0 \
    -n control-plane
```

The script:

1. Validates Ubuntu.
2. Validates the CPU architecture.
3. Checks the container runtime.
4. Configures the Kubernetes APT repository.
5. Checks that the requested Kubernetes package versions exist.
6. Installs:
   - `kubeadm`
   - `kubelet`
   - `kubectl`
7. Holds the installed packages.
8. Runs `kubeadm init`.

The script intentionally does **not** install a CNI.

Cilium is installed separately using `cilium.sh`.

---

# 4. Install Cilium

After creating the primary control plane, make sure Helm is installed:

```bash
helm version
```

Then run:

```bash
sudo ./cilium.sh
```

The Cilium script:

1. Verifies that Kubernetes is initialized.
2. Verifies `kubectl` and Helm.
3. Configures the Cilium Helm repository.
4. Installs Cilium into `kube-system`.
5. Waits for the Cilium DaemonSet.
6. Displays Cilium pods and Kubernetes nodes.

Verify the cluster:

```bash
kubectl get nodes
```

Check Cilium:

```bash
kubectl get pods \
    -n kube-system \
    -l k8s-app=cilium
```

---

# 5. Add a Worker Node

On an existing control-plane node:

```bash
kubeadm token create --print-join-command
```

The command will look similar to:

```bash
kubeadm join <CONTROL_PLANE_ENDPOINT>:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

Run the complete command on the worker.

Then verify:

```bash
kubectl get nodes
```

---

# 6. Add an Additional Control Plane

On an existing control-plane node, generate the certificate key:

```bash
kubeadm init phase upload-certs --upload-certs
```

Save the certificate key.

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

Verify:

```bash
kubectl get nodes
```

---

# 7. Upgrade Kubernetes

The `update` action upgrades an existing Kubernetes installation.

For example:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n worker
```

Primary control plane:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n control-plane
```

Additional control plane:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n additional-control-plane
```

---

# 8. Kubernetes Manifest Backup

Before every `update`, the script automatically creates a backup of:

```text
/etc/kubernetes/manifests
```

The backup is stored under the home directory of the user who invoked `sudo`:

```text
~/backup/kubernetes-manifests/
```

Each update receives its own timestamped directory.

Example:

```text
~/backup/kubernetes-manifests/
└── 2026-09-25_00-15-30/
    └── manifests/
        ├── etcd.yaml
        ├── kube-apiserver.yaml
        ├── kube-controller-manager.yaml
        └── kube-scheduler.yaml
```

This provides a snapshot of the static pod manifests **before the Kubernetes upgrade**.

The backup does not automatically restore the manifests after the upgrade.

---

# 9. kubeadm Patches

If the cluster contains custom control-plane configuration, kubeadm patches can be provided with `-p`.

Example:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n control-plane \
    -p /etc/kubernetes/patches
```

The directory is passed to:

```bash
kubeadm upgrade apply
```

or:

```bash
kubeadm upgrade node
```

depending on the node type.

This allows kubeadm to apply the defined customizations while generating the updated static pod manifests.

The script does **not** automatically generate patches from the existing manifests.

For a cluster using custom settings such as:

- API server audit configuration
- Encryption configuration
- Custom API server arguments
- Custom volume mounts
- Other kubeadm-supported control-plane customizations

the appropriate patches should be maintained in a patch directory and supplied using `-p`.

---

# 10. Drain Before Every Upgrade

The script intentionally does **not** run `kubectl drain` or `kubectl uncordon`.

The administrator must handle node scheduling manually.

## Worker

From a control-plane node:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then update the worker:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n worker
```

Or remotely:

```bash
ssh worker-node-3-a \
    'sudo bash -s -a update -t 1.37.1 -n worker' \
    < kubeadm-cluster-create-update.sh
```

After verifying the node:

```bash
kubectl uncordon <node-name>
```

---

## Additional Control Plane

Drain the node from another control-plane node:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then update:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n additional-control-plane
```

After verifying the node:

```bash
kubectl uncordon <node-name>
```

---

## Primary Control Plane

Before updating the primary control plane, make sure the cluster can continue operating with the remaining control-plane nodes.

Drain the node from another control-plane node when appropriate:

```bash
kubectl drain <node-name> \
    --ignore-daemonsets \
    --delete-emptydir-data
```

Then update:

```bash
sudo ./kubernetes.sh \
    -a update \
    -t 1.37.1 \
    -n control-plane
```

After verifying the node:

```bash
kubectl uncordon <node-name>
```

Finally:

```bash
kubectl get nodes
```

---

# 11. Remote Execution

The Kubernetes script can be executed over SSH without copying it to the target node.

Example:

```bash
ssh worker-node-3-a \
    'sudo bash -s -a update -t 1.37.1 -n worker' \
    < kubeadm-cluster-create-update.sh
```

The local shell:

1. Opens an SSH connection.
2. Sends the script through standard input.
3. Starts Bash on the remote machine.
4. Runs the script as root through `sudo`.
5. Passes the command-line flags to the script.

The remote node therefore does not need a local copy of the script.

The executable permission on the remote script is also not required.

### Remote Control-Plane Example

```bash
ssh control-plane-2 \
    'sudo bash -s -a update -t 1.37.1 -n additional-control-plane' \
    < kubeadm-cluster-create-update.sh
```

### Remote Upgrade with Patches

If the patch directory already exists on the remote node:

```bash
ssh control-plane-2 \
    'sudo bash -s -a update -t 1.37.1 -n additional-control-plane -p /etc/kubernetes/patches' \
    < kubeadm-cluster-create-update.sh
```

The `-p` path refers to a directory **on the target node**, not on the machine running SSH.

---

# 12. What Happens During an Update

The update workflow is:

```text
1. Determine installed Kubernetes version
                 ↓
2. Validate target version
                 ↓
3. Validate package availability
                 ↓
4. Backup /etc/kubernetes/manifests
                 ↓
5. Update kubeadm
                 ↓
6. Run kubeadm upgrade
                 ↓
7. Update kubelet
                 ↓
8. Update kubectl
                 ↓
9. Reload systemd
                 ↓
10. Restart kubelet
                 ↓
11. Verify installed versions
                 ↓
12. Administrator verifies node
                 ↓
13. Administrator uncordons node
```

For a primary control plane:

```text
kubeadm upgrade plan
        ↓
kubeadm upgrade apply
```

For an additional control plane:

```text
kubeadm upgrade node
```

For a worker:

```text
kubeadm upgrade node
```

---

# 13. Kubernetes Version Rules

The target version must use exact `x.y.z` format.

Valid:

```text
1.37.0
1.37.1
1.38.0
```

Invalid:

```text
v1.37.0
1.37
latest
```

The update logic:

- Rejects downgrades.
- Rejects updating to the currently installed version.
- Does not skip minor versions.
- Allows patch-level updates.

Examples:

```text
1.37.0 → 1.37.1
```

Allowed.

```text
1.36.5 → 1.37.0
```

Allowed.

```text
1.36.5 → 1.38.0
```

Rejected because the `1.37` minor version was skipped.

---

# 14. Package Holds

After installation or upgrade, these packages are held:

```text
kubeadm
kubelet
kubectl
```

This prevents normal APT operations from unintentionally upgrading them.

Before changing versions, the script removes the holds.

After the installation or upgrade, the script restores them.

Check the current holds:

```bash
apt-mark showhold
```

---

# 15. Useful Commands

## Kubernetes Nodes

```bash
kubectl get nodes -o wide
```

## All Pods

```bash
kubectl get pods -A
```

## Cilium

```bash
kubectl get pods \
    -n kube-system \
    -l k8s-app=cilium
```

## Kubelet

```bash
systemctl status kubelet
```

## Kubernetes Versions

```bash
kubeadm version -o short
```

```bash
kubelet --version
```

```bash
kubectl version --client
```

## Worker Join Command

```bash
kubeadm token create --print-join-command
```

## Package Holds

```bash
apt-mark showhold
```

---

# 16. Script Responsibilities

| Script / Operation | Responsibility |
|---|---|
| `kubernetes.sh` | Install and upgrade Kubernetes |
| `cilium.sh` | Install Cilium CNI |
| `kubectl drain` | Administrator |
| `kubectl uncordon` | Administrator |
| kubeadm patches | Administrator |
| Kubernetes manifest backup | `kubernetes.sh` |

The scripts intentionally keep these responsibilities separate:

```text
Kubernetes lifecycle
        ↓
kubernetes.sh

CNI lifecycle
        ↓
cilium.sh

Node scheduling
        ↓
Administrator
```

The Kubernetes script does not install or upgrade Cilium and does not automatically drain or uncordon nodes.