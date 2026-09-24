#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Cilium installation script
#
# Usage:
#   sudo ./cilium-install.sh
#
# IMPORTANT:
#   - Run this script on the primary Kubernetes control-plane.
#   - Kubernetes must already be initialized with kubeadm.
#   - This script installs Cilium only.
###############################################################################

SCRIPT_NAME="$(basename "$0")"

CILIUM_NAMESPACE="kube-system"
CILIUM_RELEASE="cilium"
CILIUM_CHART_REPO="https://helm.cilium.io/"
CILIUM_CHART_NAME="cilium"
CILIUM_VERSION=""

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
# Root check
###############################################################################

if [[ "$EUID" -ne 0 ]]; then
    error "This script must be run as root. Use: sudo ./${SCRIPT_NAME}"
fi

###############################################################################
# Required commands
###############################################################################

check_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Required command '$command_name' was not found."
    fi
}

info "Checking required commands..."

check_command kubectl
check_command helm

success "Required commands are available."

###############################################################################
# Kubernetes configuration
###############################################################################

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    error "/etc/kubernetes/admin.conf was not found. This node does not appear to be the primary control-plane."
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Unable to connect to the Kubernetes cluster using /etc/kubernetes/admin.conf."
fi

success "Kubernetes cluster is reachable."

###############################################################################
# Verify this is a control-plane node
###############################################################################

if ! kubectl get nodes >/dev/null 2>&1; then
    error "Unable to retrieve Kubernetes nodes."
fi

success "Kubernetes API is responding."

###############################################################################
# Helm repository
###############################################################################

info "Adding Cilium Helm repository..."

if helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "cilium"; then
    info "Cilium Helm repository already exists."
else
    helm repo add cilium "$CILIUM_CHART_REPO"
fi

helm repo update

success "Cilium Helm repository is ready."

###############################################################################
# Check whether Cilium is already installed
###############################################################################

if helm status "$CILIUM_RELEASE" \
    --namespace "$CILIUM_NAMESPACE" >/dev/null 2>&1; then

    warning "Cilium is already installed."

    echo
    info "Current Cilium Helm release:"
    helm status "$CILIUM_RELEASE" \
        --namespace "$CILIUM_NAMESPACE"

    echo
    info "Cilium pods:"
    kubectl get pods \
        -n "$CILIUM_NAMESPACE" \
        -l k8s-app=cilium

    echo
    success "Nothing to install."
    exit 0
fi

###############################################################################
# Install Cilium
###############################################################################

info "Installing Cilium..."

helm install "$CILIUM_RELEASE" \
    cilium/cilium \
    --namespace "$CILIUM_NAMESPACE"

success "Cilium Helm installation completed."

###############################################################################
# Wait for Cilium
###############################################################################

info "Waiting for Cilium DaemonSet to become ready..."

if ! kubectl rollout status \
    daemonset/cilium \
    -n "$CILIUM_NAMESPACE" \
    --timeout=10m; then

    error "Cilium DaemonSet did not become ready within the expected time."
fi

success "Cilium DaemonSet is ready."

###############################################################################
# Verify Cilium
###############################################################################

info "Checking Cilium pods..."

kubectl get pods \
    -n "$CILIUM_NAMESPACE" \
    -l k8s-app=cilium \
    -o wide

echo

info "Checking Cilium operator..."

kubectl get pods \
    -n "$CILIUM_NAMESPACE" \
    -l name=cilium-operator

echo

info "Checking Kubernetes nodes..."

kubectl get nodes -o wide

echo

###############################################################################
# Final status
###############################################################################

cat <<EOF

===============================================================================
Cilium installation completed
===============================================================================

Cilium is installed in namespace:

    ${CILIUM_NAMESPACE}

Verify the cluster with:

    kubectl get nodes

Check Cilium pods with:

    kubectl get pods -n kube-system -l k8s-app=cilium

Check all Cilium resources with:

    kubectl get all -n kube-system -l k8s-app=cilium

===============================================================================

EOF

success "Cilium setup completed successfully."