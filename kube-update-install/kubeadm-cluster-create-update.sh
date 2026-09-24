#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Kubernetes kubeadm creation / upgrade script
#
# Usage:
#   sudo ./kubernetes.sh -a <create|update> -t <x.y.z> -n <node-type>
#
# Optional:
#   -p <patches-directory>
#
# Node types:
#   control-plane
#   additional-control-plane
#   worker
#
# Examples:
#
#   sudo ./kubernetes.sh \
#       -a create \
#       -t 1.37.0 \
#       -n control-plane
#
#   sudo ./kubernetes.sh \
#       -a create \
#       -t 1.37.0 \
#       -n worker
#
#   sudo ./kubernetes.sh \
#       -a update \
#       -t 1.37.1 \
#       -n control-plane
#
#   sudo ./kubernetes.sh \
#       -a update \
#       -t 1.37.1 \
#       -n additional-control-plane \
#       -p /etc/kubernetes/patches
#
# Remote execution:
#
#   ssh worker-node-3-a \
#       'sudo bash -s -a update -t 1.37.1 -n worker' \
#       < kubeadm-cluster-create-update.sh
#
# IMPORTANT:
#   - This script does NOT install a CNI plugin.
#   - This script does NOT drain or uncordon nodes.
#   - Container runtime must already be installed.
#   - Kubernetes manifests are backed up before every update.
###############################################################################

SCRIPT_NAME="$(basename "$0")"

KUBERNETES_LIST="/etc/apt/sources.list.d/kubernetes.list"
KUBERNETES_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
KUBERNETES_MANIFESTS="/etc/kubernetes/manifests"

###############################################################################
# Colors / output
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

###############################################################################
# Usage / help
###############################################################################

usage() {
    cat <<EOF

Usage:

    sudo ./${SCRIPT_NAME} -a <create|update> -t <x.y.z> -n <node-type> [-p <patches-directory>]

Options:

    -a <create|update>
        Action to perform.

    -t <x.y.z>
        Target Kubernetes version in exact x.y.z format.
        Example: 1.37.1

    -n <node-type>
        Node type.

        Supported values:
            control-plane
            additional-control-plane
            worker

    -p <patches-directory>
        Optional kubeadm patches directory.

        The directory is passed to:
            kubeadm upgrade apply
            kubeadm upgrade node

    -h
        Show this help message.

Examples:

    Create primary control-plane:

        sudo ./${SCRIPT_NAME} \
            -a create \
            -t 1.37.0 \
            -n control-plane

    Create worker:

        sudo ./${SCRIPT_NAME} \
            -a create \
            -t 1.37.0 \
            -n worker

    Update primary control-plane:

        sudo ./${SCRIPT_NAME} \
            -a update \
            -t 1.37.1 \
            -n control-plane

    Update additional control-plane with patches:

        sudo ./${SCRIPT_NAME} \
            -a update \
            -t 1.37.1 \
            -n additional-control-plane \
            -p /etc/kubernetes/patches

    Update worker remotely over SSH:

        ssh worker-node-3-a \
            'sudo bash -s -a update -t 1.37.1 -n worker' \
            < ${SCRIPT_NAME}

EOF
}

###############################################################################
# Argument parsing
###############################################################################

ACTION=""
K8S_VERSION=""
NODE_TYPE=""
PATCHES_DIR=""

while getopts ":a:n:t:p:h" opt; do
    case "$opt" in

        a)
            ACTION="$OPTARG"
            ;;

        n)
            NODE_TYPE="$OPTARG"
            ;;

        t)
            K8S_VERSION="$OPTARG"
            ;;

        p)
            PATCHES_DIR="$OPTARG"
            ;;

        h)
            usage
            exit 0
            ;;

        :)
            error "Option -$OPTARG requires an argument. Use -h for help."

            ;;

        \?)
            error "Invalid option: -$OPTARG. Use -h for help."

            ;;

    esac
done

###############################################################################
# Required argument validation
###############################################################################

if [[ -z "$ACTION" ]]; then
    error "Action is required. Use -a create or -a update."
fi

if [[ -z "$K8S_VERSION" ]]; then
    error "Target Kubernetes version is required. Use -t <x.y.z>."
fi

if [[ -z "$NODE_TYPE" ]]; then
    error "Node type is required. Use -n <node-type>."
fi

case "$ACTION" in

    create|update)
        ;;

    *)
        error "Invalid action '$ACTION'. Use 'create' or 'update'."
        ;;

esac

if [[ ! "$K8S_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid Kubernetes version '$K8S_VERSION'. Expected format: x.y.z"
fi

case "$NODE_TYPE" in

    control-plane|additional-control-plane|worker)
        ;;

    *)
        error "Invalid node type '$NODE_TYPE'."
        ;;

esac

###############################################################################
# Kubernetes repository variables
###############################################################################

K8S_MINOR_VERSION="$(echo "$K8S_VERSION" | cut -d. -f1,2)"

REPO_URL="https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb"

###############################################################################
# Root check
###############################################################################

if [[ "$EUID" -ne 0 ]]; then
    error "This script must be run as root. Use sudo."
fi

###############################################################################
# Determine invoking user's home directory
###############################################################################

get_user_home() {

    local user_home

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then

        user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

        if [[ -n "$user_home" ]]; then
            echo "$user_home"
            return
        fi

    fi

    echo "${HOME:-/root}"
}

USER_HOME="$(get_user_home)"

BACKUP_ROOT="${USER_HOME}/backup/kubernetes-manifests"

###############################################################################
# OS validation
###############################################################################

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release not found. Unable to determine operating system."
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    error "Unsupported operating system: ${ID:-unknown}. This script requires Ubuntu."
fi

if [[ -z "${VERSION_ID:-}" ]]; then
    error "Unable to determine Ubuntu version."
fi

UBUNTU_VERSION="${VERSION_ID}"

if ! dpkg --compare-versions "$UBUNTU_VERSION" ge "22.04"; then
    error "Unsupported Ubuntu version: ${UBUNTU_VERSION}. Ubuntu 22.04 or newer is required by this script."
fi

success "Ubuntu ${UBUNTU_VERSION} detected."

###############################################################################
# Architecture validation
###############################################################################

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in

    amd64|arm64|armhf|ppc64el|s390x)
        ;;

    *)
        error "Unsupported CPU architecture: ${ARCH}"
        ;;

esac

success "Supported architecture detected: ${ARCH}"

###############################################################################
# Patch validation
###############################################################################

validate_patches_directory() {

    if [[ -z "$PATCHES_DIR" ]]; then
        return
    fi

    if [[ ! -d "$PATCHES_DIR" ]]; then
        error "Patches directory does not exist: ${PATCHES_DIR}"
    fi

    if [[ ! -r "$PATCHES_DIR" ]]; then
        error "Patches directory is not readable: ${PATCHES_DIR}"
    fi

    success "Kubeadm patches directory detected: ${PATCHES_DIR}"
}

validate_patches_directory

###############################################################################
# Kubernetes manifest backup
###############################################################################

backup_kubernetes_manifests() {

    if [[ "$ACTION" != "update" ]]; then
        return
    fi

    if [[ ! -d "$KUBERNETES_MANIFESTS" ]]; then
        warning "Kubernetes manifests directory does not exist:"
        warning "    ${KUBERNETES_MANIFESTS}"
        warning "No manifest backup will be created on this node."
        return
    fi

    local timestamp
    local backup_directory

    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"

    backup_directory="${BACKUP_ROOT}/${timestamp}"

    info "Creating Kubernetes manifest backup..."

    mkdir -p "$backup_directory"

    cp -a \
        "$KUBERNETES_MANIFESTS" \
        "$backup_directory/"

    success "Kubernetes manifests backed up to:"
    echo "    ${backup_directory}/manifests"
}

###############################################################################
# Basic prerequisites
###############################################################################

info "Installing required APT tools..."

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gpg

success "Required APT tools are installed."

###############################################################################
# Container runtime validation
###############################################################################

check_container_runtime() {

    local runtime_found=false

    if [[ -S /run/containerd/containerd.sock ]]; then

        runtime_found=true
        info "Detected containerd CRI socket."

    elif [[ -S /var/run/containerd/containerd.sock ]]; then

        runtime_found=true
        info "Detected containerd CRI socket."

    elif [[ -S /var/run/crio/crio.sock ]]; then

        runtime_found=true
        info "Detected CRI-O socket."

    elif [[ -S /run/cri-dockerd.sock ]]; then

        runtime_found=true
        info "Detected Docker Engine via cri-dockerd."

    fi

    if [[ "$runtime_found" == false ]]; then

        error \
            "No supported CRI runtime socket was detected. Install and configure a container runtime before running this script."

    fi

    success "Container runtime detected."
}

check_container_runtime

###############################################################################
# Kubernetes APT repository
###############################################################################

configure_kubernetes_repository() {

    info "Configuring Kubernetes APT repository for v${K8S_MINOR_VERSION}..."

    mkdir -p -m 755 /etc/apt/keyrings

    local temp_key

    temp_key="$(mktemp)"

    curl -fsSL \
        "${REPO_URL}/Release.key" \
        -o "$temp_key"

    if [[ ! -s "$temp_key" ]]; then
        rm -f "$temp_key"
        error "Failed to download Kubernetes repository signing key."
    fi

    gpg --dearmor \
        --yes \
        --output "$KUBERNETES_KEYRING" \
        "$temp_key"

    rm -f "$temp_key"

    chmod 644 "$KUBERNETES_KEYRING"

    cat > "$KUBERNETES_LIST" <<EOF
deb [signed-by=${KUBERNETES_KEYRING}] ${REPO_URL}/ /
EOF

    if ! apt-get update; then
        error "APT repository verification failed for Kubernetes v${K8S_MINOR_VERSION}."
    fi

    success "Kubernetes APT repository configured and verified."
}

configure_kubernetes_repository

###############################################################################
# Package version discovery
###############################################################################

get_package_version() {

    local package="$1"
    local output
    local version

    output="$(apt-cache madison "$package" 2>/dev/null || true)"

    version="$(
        awk -v prefix="${K8S_VERSION}-" '
            $3 ~ "^" prefix {
                print $3
                exit
            }
        ' <<< "$output"
    )"

    echo "$version"
}

KUBEADM_PACKAGE_VERSION="$(get_package_version kubeadm)"
KUBELET_PACKAGE_VERSION="$(get_package_version kubelet)"
KUBECTL_PACKAGE_VERSION="$(get_package_version kubectl)"

if [[ -z "$KUBEADM_PACKAGE_VERSION" ]]; then
    error "Kubernetes version ${K8S_VERSION} is not available for kubeadm."
fi

if [[ -z "$KUBELET_PACKAGE_VERSION" ]]; then
    error "Kubernetes version ${K8S_VERSION} is not available for kubelet."
fi

if [[ -z "$KUBECTL_PACKAGE_VERSION" ]]; then
    error "Kubernetes version ${K8S_VERSION} is not available for kubectl."
fi

success "Requested Kubernetes package versions are available:"

echo "    kubeadm : ${KUBEADM_PACKAGE_VERSION}"
echo "    kubelet : ${KUBELET_PACKAGE_VERSION}"
echo "    kubectl : ${KUBECTL_PACKAGE_VERSION}"

###############################################################################
# Package helper functions
###############################################################################

unhold_kubernetes_packages() {

    apt-mark unhold kubeadm kubelet kubectl \
        >/dev/null 2>&1 || true
}

hold_kubernetes_packages() {

    apt-mark hold kubeadm kubelet kubectl \
        >/dev/null
}

install_exact_packages() {

    local packages=("$@")

    apt-get install -y "${packages[@]}"
}

###############################################################################
# Current Kubernetes version
###############################################################################

get_installed_kubernetes_version() {

    local version=""

    if command -v kubeadm >/dev/null 2>&1; then

        version="$(
            kubeadm version -o short 2>/dev/null || true
        )"

    fi

    version="${version#v}"

    echo "$version"
}

###############################################################################
# Version comparison
###############################################################################

version_is_greater_or_equal() {

    local first="$1"
    local second="$2"

    [[
        "$(printf '%s\n%s\n' "$first" "$second" |
            sort -V |
            head -n1)" == "$second"
    ]]
}

###############################################################################
# Installation
###############################################################################

install_kubernetes_packages() {

    info "Installing Kubernetes packages..."

    unhold_kubernetes_packages

    # Required installation order:
    # kubeadm -> kubelet -> kubectl

    info "Installing kubeadm ${KUBEADM_PACKAGE_VERSION}..."

    install_exact_packages \
        "kubeadm=${KUBEADM_PACKAGE_VERSION}"

    info "Installing kubelet ${KUBELET_PACKAGE_VERSION}..."

    install_exact_packages \
        "kubelet=${KUBELET_PACKAGE_VERSION}"

    info "Installing kubectl ${KUBECTL_PACKAGE_VERSION}..."

    install_exact_packages \
        "kubectl=${KUBECTL_PACKAGE_VERSION}"

    hold_kubernetes_packages

    systemctl enable kubelet

    success "Kubernetes packages installed and held."
}

###############################################################################
# Kubernetes package verification
###############################################################################

verify_installed_versions() {

    info "Verifying installed Kubernetes versions..."

    local kubeadm_version
    local kubelet_version
    local kubectl_version

    kubeadm_version="$(
        kubeadm version -o short 2>/dev/null || true
    )"

    kubelet_version="$(
        kubelet --version 2>/dev/null |
            awk '{print $2}' || true
    )"

    kubectl_version="$(
        kubectl version --client -o json 2>/dev/null |
            awk -F'"' '/"gitVersion":/ {print $4; exit}' || true
    )"

    echo

    echo "Installed versions:"
    echo "    kubeadm : ${kubeadm_version:-unknown}"
    echo "    kubelet : ${kubelet_version:-unknown}"
    echo "    kubectl : ${kubectl_version:-unknown}"

    echo

    echo "Package hold status:"

    apt-mark showhold |
        grep -E '^(kubeadm|kubelet|kubectl)$' ||
        true

    echo
}

###############################################################################
# Control-plane initialization
###############################################################################

initialize_control_plane() {

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        error "This node already appears to be an initialized control-plane."
    fi

    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        error "This node already appears to have kubeadm configuration."
    fi

    info "Initializing the primary control-plane..."

    kubeadm init \
        --kubernetes-version "v${K8S_VERSION}"

    success "Primary control-plane initialized."

    info "Configuring kubectl for root..."

    export KUBECONFIG=/etc/kubernetes/admin.conf

    success "kubectl configured using /etc/kubernetes/admin.conf."

    cat <<EOF

===============================================================================
Kubernetes control-plane creation completed
===============================================================================

IMPORTANT:
This script does NOT install a CNI plugin.

The cluster requires a CNI plugin before it can be used normally.

Please install Cilium using the separate Cilium installation script.

After Cilium has been installed, use the following command on this
control-plane to generate the worker join command:

    kubeadm token create --print-join-command

Copy the complete output and execute it on the worker node.

For adding an additional control-plane node, see the instructions
printed by the additional-control-plane creation.

===============================================================================

EOF
}

###############################################################################
# Additional control-plane instructions
###############################################################################

print_additional_control_plane_instructions() {

    cat <<EOF

===============================================================================
Additional control-plane creation
===============================================================================

Kubernetes packages have been installed on this node.

The node must now be joined to the existing cluster.

On an existing control-plane node, first generate the certificate key:

    kubeadm init phase upload-certs --upload-certs

Save the certificate key printed by this command.

Then generate the normal join command:

    kubeadm token create --print-join-command

Take the complete join command and append:

    --control-plane --certificate-key <CERTIFICATE_KEY>

The final command should look similar to:

    kubeadm join <CONTROL_PLANE_ENDPOINT>:6443 \\
        --token <TOKEN> \\
        --discovery-token-ca-cert-hash sha256:<HASH> \\
        --control-plane \\
        --certificate-key <CERTIFICATE_KEY>

Execute the complete command on this node.

===============================================================================

EOF
}

###############################################################################
# Worker instructions
###############################################################################

print_worker_instructions() {

    cat <<EOF

===============================================================================
Worker node creation
===============================================================================

Kubernetes packages have been installed on this node.

On an existing control-plane node, generate the worker join command:

    kubeadm token create --print-join-command

Copy the complete output and execute it on this worker node.

The command will look similar to:

    kubeadm join <CONTROL_PLANE_ENDPOINT>:6443 \\
        --token <TOKEN> \\
        --discovery-token-ca-cert-hash sha256:<HASH>

===============================================================================

EOF
}

###############################################################################
# Create workflow
###############################################################################

create_workflow() {

    info "Starting Kubernetes creation..."

    echo
    echo "    Kubernetes version : ${K8S_VERSION}"
    echo "    Node type          : ${NODE_TYPE}"

    if [[ -n "$PATCHES_DIR" ]]; then
        echo "    Patches directory  : ${PATCHES_DIR}"
    else
        echo "    Patches directory  : none"
    fi

    echo

    install_kubernetes_packages

    verify_installed_versions

    case "$NODE_TYPE" in

        control-plane)
            initialize_control_plane
            ;;

        additional-control-plane)
            print_additional_control_plane_instructions
            ;;

        worker)
            print_worker_instructions
            ;;

    esac

    success "Creation workflow completed."
}

###############################################################################
# Update validation
###############################################################################

validate_update_version() {

    local current_version="$1"

    if [[ -z "$current_version" ]]; then
        error "Unable to determine the currently installed Kubernetes version."
    fi

    info "Currently installed Kubernetes version: ${current_version}"
    info "Requested Kubernetes version: ${K8S_VERSION}"

    # No downgrade.
    if ! version_is_greater_or_equal \
        "$K8S_VERSION" \
        "$current_version"; then

        error \
            "Downgrade is not supported. Current version is ${current_version}, requested version is ${K8S_VERSION}."

    fi

    # Same version is not an update.
    if [[ "$K8S_VERSION" == "$current_version" ]]; then

        error \
            "Requested version ${K8S_VERSION} is already installed. No update is required."

    fi

    local current_minor

    current_minor="$(
        echo "$current_version" |
            cut -d. -f1,2
    )"

    # Kubernetes minor versions must be upgraded sequentially.
    if [[ "$current_minor" != "$K8S_MINOR_VERSION" ]]; then

        local current_major
        local current_minor_number
        local target_major
        local target_minor_number

        current_major="$(
            echo "$current_version" |
                cut -d. -f1
        )"

        current_minor_number="$(
            echo "$current_version" |
                cut -d. -f2
        )"

        target_major="$(
            echo "$K8S_VERSION" |
                cut -d. -f1
        )"

        target_minor_number="$(
            echo "$K8S_VERSION" |
                cut -d. -f2
        )"

        if [[ "$current_major" != "$target_major" ]]; then

            error \
                "Major-version upgrades are not supported by this script: ${current_version} -> ${K8S_VERSION}"

        fi

        if (( target_minor_number != current_minor_number + 1 )); then

            error \
                "Skipping Kubernetes minor versions is not supported by this script: ${current_version} -> ${K8S_VERSION}"

        fi

    fi
}

###############################################################################
# Update kubeadm
###############################################################################

update_kubeadm() {

    info "Updating kubeadm to ${KUBEADM_PACKAGE_VERSION}..."

    apt-mark unhold kubeadm \
        >/dev/null 2>&1 || true

    apt-get install -y \
        "kubeadm=${KUBEADM_PACKAGE_VERSION}"

    apt-mark hold kubeadm \
        >/dev/null

    success "kubeadm updated."
}

###############################################################################
# Update kubelet + kubectl
###############################################################################

update_kubelet_and_kubectl() {

    info "Updating kubelet to ${KUBELET_PACKAGE_VERSION}..."
    info "Updating kubectl to ${KUBECTL_PACKAGE_VERSION}..."

    apt-mark unhold kubelet kubectl \
        >/dev/null 2>&1 || true

    apt-get install -y \
        "kubelet=${KUBELET_PACKAGE_VERSION}" \
        "kubectl=${KUBECTL_PACKAGE_VERSION}"

    apt-mark hold kubelet kubectl \
        >/dev/null

    success "kubelet and kubectl updated."
}

###############################################################################
# Restart kubelet
###############################################################################

restart_kubelet() {

    info "Reloading systemd configuration..."

    systemctl daemon-reload

    info "Restarting kubelet..."

    systemctl restart kubelet

    if ! systemctl is-active --quiet kubelet; then
        error "kubelet failed to start."
    fi

    success "kubelet restarted successfully."
}

###############################################################################
# kubeadm patch arguments
###############################################################################

get_patch_arguments() {

    if [[ -n "$PATCHES_DIR" ]]; then

        printf '%s\n' \
            "--patches" \
            "$PATCHES_DIR"

    fi
}

###############################################################################
# Primary control-plane update
###############################################################################

update_primary_control_plane() {

    info "Updating primary control-plane..."

    update_kubeadm

    info "Running kubeadm upgrade plan..."

    kubeadm upgrade plan

    info "Applying Kubernetes upgrade to v${K8S_VERSION}..."

    if [[ -n "$PATCHES_DIR" ]]; then

        info "Using kubeadm patches from:"
        info "    ${PATCHES_DIR}"

        kubeadm upgrade apply \
            "v${K8S_VERSION}" \
            --yes \
            --patches "$PATCHES_DIR"

    else

        kubeadm upgrade apply \
            "v${K8S_VERSION}" \
            --yes

    fi

    success "Control-plane components upgraded."

    update_kubelet_and_kubectl

    restart_kubelet

    verify_installed_versions

    cat <<EOF

===============================================================================
Primary control-plane update completed
===============================================================================

IMPORTANT:
This script does NOT drain or uncordon nodes.

If you drained this node before the update, uncordon it manually after
confirming that the node is healthy:

    kubectl uncordon <node-name>

Then verify the cluster:

    kubectl get nodes

===============================================================================

EOF
}

###############################################################################
# Additional control-plane update
###############################################################################

update_additional_control_plane() {

    info "Updating additional control-plane node..."

    update_kubeadm

    info "Running kubeadm upgrade node..."

    if [[ -n "$PATCHES_DIR" ]]; then

        info "Using kubeadm patches from:"
        info "    ${PATCHES_DIR}"

        kubeadm upgrade node \
            --patches "$PATCHES_DIR"

    else

        kubeadm upgrade node

    fi

    success "Local control-plane configuration upgraded."

    update_kubelet_and_kubectl

    restart_kubelet

    verify_installed_versions

    cat <<EOF

===============================================================================
Additional control-plane update completed
===============================================================================

IMPORTANT:
This script does NOT drain or uncordon nodes.

If you drained this node before the update, uncordon it manually after
confirming that the node is healthy:

    kubectl uncordon <node-name>

Then verify:

    kubectl get nodes

===============================================================================

EOF
}

###############################################################################
# Worker update
###############################################################################

update_worker() {

    info "Updating worker node..."

    update_kubeadm

    info "Running kubeadm upgrade node..."

    if [[ -n "$PATCHES_DIR" ]]; then

        warning "Patches were provided, but this is a worker node."
        warning "kubeadm upgrade node will receive the patch directory."

        kubeadm upgrade node \
            --patches "$PATCHES_DIR"

    else

        kubeadm upgrade node

    fi

    success "Worker kubelet configuration upgraded."

    update_kubelet_and_kubectl

    restart_kubelet

    verify_installed_versions

    cat <<EOF

===============================================================================
Worker node update completed
===============================================================================

IMPORTANT:
This script does NOT drain or uncordon nodes.

Before running this update, the node should have been drained manually
from a control-plane node with appropriate permissions.

After confirming that the node is healthy, uncordon it manually:

    kubectl uncordon <node-name>

Then verify:

    kubectl get nodes

===============================================================================

EOF
}

###############################################################################
# Update workflow
###############################################################################

update_workflow() {

    local current_version

    current_version="$(get_installed_kubernetes_version)"

    validate_update_version "$current_version"

    echo

    info "Starting Kubernetes update..."

    echo
    echo "    Current version   : ${current_version}"
    echo "    Target version    : ${K8S_VERSION}"
    echo "    Node type         : ${NODE_TYPE}"

    if [[ -n "$PATCHES_DIR" ]]; then
        echo "    Patches directory : ${PATCHES_DIR}"
    else
        echo "    Patches directory : none"
    fi

    echo

    warning "This script does NOT drain or uncordon the node."
    warning "Make sure the required node has been drained before continuing."

    echo

    ###########################################################################
    # Backup manifests BEFORE kubeadm upgrade
    ###########################################################################

    backup_kubernetes_manifests

    case "$NODE_TYPE" in

        control-plane)
            update_primary_control_plane
            ;;

        additional-control-plane)
            update_additional_control_plane
            ;;

        worker)
            update_worker
            ;;

    esac

    success "Update workflow completed successfully."
}

###############################################################################
# Main
###############################################################################

info "Kubernetes script started."

echo

case "$ACTION" in

    create)
        create_workflow
        ;;

    update)
        update_workflow
        ;;

esac

echo

success "Done."