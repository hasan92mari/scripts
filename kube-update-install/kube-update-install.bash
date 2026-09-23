#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Kubernetes kubeadm / kubelet / kubectl installer/updater
#
# Usage:
#   sudo ./kubernetes.sh install 1.34.1
#   sudo ./kubernetes.sh update  1.34.1
#
# Arguments:
#   $1 = install | update
#   $2 = Kubernetes version in x.y.z format
# ============================================================


# ============================================================
# Configuration
# ============================================================

K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_REPO_FILE="/etc/apt/sources.list.d/kubernetes.list"

K8S_REPO_BASE="https://pkgs.k8s.io/core:/stable"


# ============================================================
# Functions
# ============================================================

error() {
    echo
    echo "ERROR: $1"
    echo
    exit 1
}


info() {
    echo "[INFO] $1"
}


success() {
    echo "[OK] $1"
}


usage() {
    echo
    echo "Usage:"
    echo "  sudo $0 install <x.y.z>"
    echo "  sudo $0 update  <x.y.z>"
    echo
    echo "Examples:"
    echo "  sudo $0 install 1.34.1"
    echo "  sudo $0 update  1.34.1"
    echo
}


# ============================================================
# 1. Validate command-line arguments
# ============================================================

if [[ $# -ne 2 ]]; then
    echo "ERROR: Exactly two arguments are required."
    usage
    exit 1
fi


OPERATION="$1"
K8S_VERSION="$2"


# ============================================================
# 2. Validate operation
# ============================================================

case "${OPERATION}" in
    install|update)
        ;;
    *)
        error "The first argument must be exactly 'install' or 'update'."
        ;;
esac


# ============================================================
# 3. Validate Kubernetes version format
#
# Required:
#   x.y.z
#
# Examples:
#   1.34.1   -> valid
#   1.34     -> invalid
#   v1.34.1  -> invalid
#   1.34.1-1 -> invalid
# ============================================================

if [[ ! "${K8S_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Kubernetes version must have exactly the format x.y.z.
Example:
  1.34.1"
fi


# Extract major/minor/patch
K8S_MAJOR="${K8S_VERSION%%.*}"
K8S_MINOR="${K8S_VERSION#*.}"
K8S_MINOR="${K8S_MINOR%%.*}"
K8S_PATCH="${K8S_VERSION##*.}"

K8S_MINOR_VERSION="${K8S_MAJOR}.${K8S_MINOR}"


# ============================================================
# 4. Root check
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be executed as root.

Example:
  sudo $0 ${OPERATION} ${K8S_VERSION}"
fi


# ============================================================
# 5. Check required commands
# ============================================================

for command in apt-get apt-cache dpkg gpg curl awk grep sed sort; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        error "Required command '${command}' was not found."
    fi
done


# ============================================================
# 6. Check operating system
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release was not found. Cannot identify the operating system."
fi

# shellcheck disable=SC1091
source /etc/os-release


if [[ "${ID:-}" != "ubuntu" ]]; then
    error "This script supports Ubuntu only.

Detected OS:
  ${PRETTY_NAME:-unknown}"
fi


UBUNTU_VERSION="${VERSION_ID:-unknown}"


# ============================================================
# 7. Validate Ubuntu version
#
# We require Ubuntu 22.04 or newer.
#
# Kubernetes documentation specifically references Ubuntu 22.04
# when discussing the apt keyring setup, and current Kubernetes
# documentation recommends Ubuntu 22.04+ for cgroup v2.
# ============================================================

if [[ ! "${UBUNTU_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    error "Could not determine the Ubuntu version."
fi


UBUNTU_VERSION_NUMBER="$(
    printf '%s\n' "${UBUNTU_VERSION}" |
    awk -F. '{ printf "%d%02d\n", $1, $2 }'
)"


if (( UBUNTU_VERSION_NUMBER < 2204 )); then
    error "Unsupported Ubuntu version: ${UBUNTU_VERSION}

This script requires Ubuntu 22.04 or newer."
fi


success "Ubuntu ${UBUNTU_VERSION} detected."


# ============================================================
# 8. Check architecture
# ============================================================

ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in
    amd64|arm64|armhf|ppc64el|s390x)
        ;;
    *)
        error "Unsupported Debian/Ubuntu architecture: ${ARCH}"
        ;;
esac


success "Architecture: ${ARCH}"


# ============================================================
# 9. Display requested configuration
# ============================================================

echo
echo "============================================================"
echo "Kubernetes package operation"
echo "============================================================"
echo "Operation          : ${OPERATION}"
echo "Requested version  : ${K8S_VERSION}"
echo "Kubernetes minor   : ${K8S_MINOR_VERSION}"
echo "Ubuntu             : ${UBUNTU_VERSION}"
echo "Architecture       : ${ARCH}"
echo "============================================================"
echo


# ============================================================
# 10. Install repository prerequisites
# ============================================================

info "Installing APT repository prerequisites..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gpg


# ============================================================
# 11. Prepare APT keyrings directory
# ============================================================

info "Preparing APT keyring directory..."

mkdir -p -m 755 /etc/apt/keyrings


# ============================================================
# 12. Download Kubernetes repository signing key
#
# The Kubernetes documentation states that the same signing key
# is used for the Kubernetes repositories, so the version in
# Release.key is not important.
# ============================================================

K8S_REPO_URL="${K8S_REPO_BASE}/v${K8S_MINOR_VERSION}/deb"

TEMP_KEY="$(mktemp)"

trap 'rm -f "${TEMP_KEY}"' EXIT


info "Downloading Kubernetes repository signing key..."

if ! curl -fsSL \
    "${K8S_REPO_URL}/Release.key" \
    -o "${TEMP_KEY}"; then

    error "Could not download the Kubernetes repository signing key.

Repository:
  ${K8S_REPO_URL}"
fi


# ============================================================
# 13. Validate downloaded repository key
# ============================================================

info "Validating Kubernetes repository signing key..."

if ! gpg --show-keys --with-colons "${TEMP_KEY}" >/dev/null 2>&1; then
    error "The downloaded Kubernetes repository key is not a valid GPG key."
fi


# Convert key to binary keyring
if ! gpg --dearmor \
    --yes \
    --output "${K8S_KEYRING}" \
    "${TEMP_KEY}"; then

    error "Failed to create the Kubernetes APT keyring."
fi


chmod 644 "${K8S_KEYRING}"


success "Kubernetes repository signing key is valid."


# ============================================================
# 14. Configure Kubernetes APT repository
#
# Each Kubernetes minor release has its own repository.
#
# Example:
#   Kubernetes 1.34.x
#   ->
#   https://pkgs.k8s.io/core:/stable:/v1.34/deb/
# ============================================================

info "Configuring Kubernetes APT repository..."

cat > "${K8S_REPO_FILE}" <<EOF
deb [signed-by=${K8S_KEYRING}] ${K8S_REPO_URL}/ /
EOF

chmod 644 "${K8S_REPO_FILE}"


# ============================================================
# 15. Verify repository configuration
# ============================================================

if ! grep -Fq \
    "${K8S_REPO_URL}/" \
    "${K8S_REPO_FILE}"; then

    error "Kubernetes APT repository configuration failed."
fi


success "Kubernetes APT repository configured."


# ============================================================
# 16. Update APT and verify repository signature
#
# If the Release file signature cannot be verified, apt-get
# update fails here.
# ============================================================

info "Updating APT package index and verifying repository signature..."

if ! apt-get update; then
    error "APT repository validation failed.

Possible causes:
  - Invalid repository signing key
  - Invalid repository configuration
  - Network/DNS problem
  - Repository does not exist for Kubernetes ${K8S_MINOR_VERSION}
  - Repository signature verification failed"
fi


success "Kubernetes APT repository is reachable and its signature was accepted."


# ============================================================
# 17. Check that requested Kubernetes version exists
#
# APT package versions look like:
#
#   1.34.1-1.1
#
# The user provides:
#
#   1.34.1
#
# Therefore we search for package versions beginning with
# "1.34.1-".
# ============================================================

info "Checking availability of Kubernetes ${K8S_VERSION}..."


get_package_version() {
    local package="$1"

    apt-cache madison "${package}" 2>/dev/null |
        awk '{print $3}' |
        grep -E "^${K8S_VERSION//./\\.}-" |
        sort -V |
        tail -n 1
}


KUBEADM_PACKAGE_VERSION="$(get_package_version kubeadm)"
KUBELET_PACKAGE_VERSION="$(get_package_version kubelet)"
KUBECTL_PACKAGE_VERSION="$(get_package_version kubectl)"


# ============================================================
# 18. If requested version doesn't exist, show latest available
# ============================================================

if [[ -z "${KUBEADM_PACKAGE_VERSION}" ||
      -z "${KUBELET_PACKAGE_VERSION}" ||
      -z "${KUBECTL_PACKAGE_VERSION}" ]]; then

    echo
    echo "Requested Kubernetes version ${K8S_VERSION} is not available"
    echo "for all required Kubernetes packages."
    echo

    echo "Package availability:"

    if [[ -n "${KUBEADM_PACKAGE_VERSION}" ]]; then
        echo "  kubeadm : ${KUBEADM_PACKAGE_VERSION}"
    else
        echo "  kubeadm : NOT AVAILABLE"
    fi

    if [[ -n "${KUBELET_PACKAGE_VERSION}" ]]; then
        echo "  kubelet : ${KUBELET_PACKAGE_VERSION}"
    else
        echo "  kubelet : NOT AVAILABLE"
    fi

    if [[ -n "${KUBECTL_PACKAGE_VERSION}" ]]; then
        echo "  kubectl : ${KUBECTL_PACKAGE_VERSION}"
    else
        echo "  kubectl : NOT AVAILABLE"
    fi

    echo


    # Find latest common x.y.z version.
    LATEST_VERSION="$(
        apt-cache madison kubeadm 2>/dev/null |
        awk '{print $3}' |
        sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)-.*$/\1/' |
        sort -V |
        tail -n 1
    )"


    if [[ -n "${LATEST_VERSION}" ]]; then
        echo "Latest available kubeadm version: ${LATEST_VERSION}"
    fi

    echo

    exit 1
fi


success "Requested Kubernetes version ${K8S_VERSION} exists."


# ============================================================
# 19. UPDATE-specific validation
# ============================================================

if [[ "${OPERATION}" == "update" ]]; then

    # --------------------------------------------------------
    # kubeadm must already exist
    # --------------------------------------------------------

    if ! command -v kubeadm >/dev/null 2>&1; then
        error "kubeadm is not installed.

Use:
  $0 install ${K8S_VERSION}"
    fi


    # --------------------------------------------------------
    # Get currently installed kubeadm version
    # --------------------------------------------------------

    CURRENT_VERSION="$(
        kubeadm version -o short 2>/dev/null |
        sed 's/^v//'
    )"


    if [[ ! "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Could not determine the currently installed kubeadm version."
    fi


    echo
    echo "Current kubeadm version : ${CURRENT_VERSION}"
    echo "Requested version       : ${K8S_VERSION}"
    echo


    # --------------------------------------------------------
    # Compare versions
    # --------------------------------------------------------

    HIGHEST_VERSION="$(
        printf '%s\n%s\n' \
            "${CURRENT_VERSION}" \
            "${K8S_VERSION}" |
        sort -V |
        tail -n 1
    )


    if [[ "${HIGHEST_VERSION}" == "${CURRENT_VERSION}" &&
          "${CURRENT_VERSION}" != "${K8S_VERSION}" ]]; then

        error "The requested version ${K8S_VERSION} is lower than the
currently installed version ${CURRENT_VERSION}.

Downgrading is not allowed by this script."
    fi


    if [[ "${CURRENT_VERSION}" == "${K8S_VERSION}" ]]; then
        info "Requested version is already installed."
    fi

fi


# ============================================================
# 20. Final installation plan
# ============================================================

echo
echo "============================================================"
echo "Final installation plan"
echo "============================================================"
echo "Operation:"
echo "  ${OPERATION}"
echo
echo "Kubernetes version:"
echo "  ${K8S_VERSION}"
echo
echo "Packages:"
echo "  kubeadm = ${KUBEADM_PACKAGE_VERSION}"
echo "  kubelet = ${KUBELET_PACKAGE_VERSION}"
echo "  kubectl = ${KUBECTL_PACKAGE_VERSION}"
echo "============================================================"
echo


# ============================================================
# 21. Remove package holds
# ============================================================

info "Removing existing Kubernetes package holds..."

apt-mark unhold kubeadm kubelet kubectl >/dev/null 2>&1 || true


# ============================================================
# 22. Install/update kubeadm FIRST
# ============================================================

info "Installing kubeadm ${KUBEADM_PACKAGE_VERSION}..."

apt-get install -y \
    "kubeadm=${KUBEADM_PACKAGE_VERSION}"


success "kubeadm installed."


# ============================================================
# 23. Install/update kubelet SECOND
# ============================================================

info "Installing kubelet ${KUBELET_PACKAGE_VERSION}..."

apt-get install -y \
    "kubelet=${KUBELET_PACKAGE_VERSION}"


success "kubelet installed."


# ============================================================
# 24. Install/update kubectl THIRD
# ============================================================

info "Installing kubectl ${KUBECTL_PACKAGE_VERSION}..."

apt-get install -y \
    "kubectl=${KUBECTL_PACKAGE_VERSION}"


success "kubectl installed."


# ============================================================
# 25. Hold Kubernetes packages
# ============================================================

info "Holding Kubernetes packages..."

apt-mark hold kubeadm kubelet kubectl


# ============================================================
# 26. Final verification
# ============================================================

echo
echo "============================================================"
echo "Installation completed successfully."
echo "============================================================"

echo
echo "Installed versions:"

echo
echo "kubeadm:"
kubeadm version -o short

echo
echo "kubelet:"
kubelet --version

echo
echo "kubectl:"
kubectl version --client --output=yaml 2>/dev/null |
    grep -E 'gitVersion:' |
    head -n 1 || true

echo
echo "APT package status:"
apt-mark showhold |
    grep -E '^(kubeadm|kubelet|kubectl)$' || true

echo
echo "============================================================"