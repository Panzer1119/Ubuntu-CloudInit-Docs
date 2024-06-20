#! /bin/bash

# Usage: ./ubuntu-noble-cloudinit.sh [VM_ID] [USER] [STORAGE_VM] [SSH_KEYS] [STORAGE] [IMAGE_DIR] [SNIPPETS_DIR]

# Input variables
#export VM_ID="${1:-5000}"
#export USER="${2:-panzer1119}"
#export STORAGE_VM="${3:-storage-vm}"
#export SSH_KEYS="${4:-/home/${USER}/.ssh/authorized_keys}"
#export STORAGE="${5:-tn-core-1}"
#export IMAGE_DIR="${6:-/mnt/pve/${STORAGE}/images}"

# Constants
export UBUNTU_RELEASE="noble"
export UBUNTU_VERSION="current"
export ARCH="amd64"
export CLOUD_IMAGE_NAME="${UBUNTU_RELEASE}-server-cloudimg-${ARCH}.img"
export CLOUD_IMAGE_NAME_CUSTOMIZED="${UBUNTU_RELEASE}-server-cloudimg-${ARCH}-customized-2.img"
export CLOUD_IMAGE_PATH="./${CLOUD_IMAGE_NAME}"
export CLOUD_IMAGE_PATH_CUSTOMIZED="./${CLOUD_IMAGE_NAME_CUSTOMIZED}"
#export IMAGE_RESIZE="8G"

# Unofficial strict mode
#set -x

# Check that libguestfs-tools is installed, and install it if not
if ! command -v virt-customize &>/dev/null; then
  echo "The 'libguestfs-tools' package is not installed. Installing it..."
  sudo apt-get update
  sudo apt-get install -y libguestfs-tools
fi

# Get the SHA256SUMS for ubuntu noble cloud images
echo "Getting SHA256SUMS for Ubuntu ${UBUNTU_RELEASE} ${UBUNTU_VERSION} cloud images..."
sha256sums=$(wget -qO- "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_VERSION}/SHA256SUMS")

# Check if the cloud image exists locally
if [ -f "${CLOUD_IMAGE_PATH}" ]; then
  # Get the SHA256 checksum of the remote cloud image
  echo "Extracting the SHA256 checksum of the remote cloud image '${CLOUD_IMAGE_NAME}'..."
  sha256sum_remote=$(echo "${sha256sums}" | grep "${CLOUD_IMAGE_NAME}" | awk '{print $1}')
  # Calculate the SHA256 checksum of the local cloud image
  echo "Calculating the SHA256 checksum of the local cloud image '${CLOUD_IMAGE_PATH}'..."
  sha256sum_local=$(sha256sum "${CLOUD_IMAGE_PATH}" | awk '{print $1}')
  # Delete the cloud image if the checksums do not match
  if [ "${sha256sum_local}" != "${sha256sum_remote}" ]; then
      echo "SHA256 checksums do not match. Deleting the local cloud image '${CLOUD_IMAGE_PATH}'..."
      rm -f "${CLOUD_IMAGE_PATH}"
  else
    echo "SHA256 checksums match. The local cloud image '${CLOUD_IMAGE_PATH}' is up-to-date."
  fi
else
  echo "The local cloud image '${CLOUD_IMAGE_PATH}' does not exist."
fi

# Download the cloud image if not found locally
if [ ! -f "${CLOUD_IMAGE_PATH}" ]; then
  echo "Downloading the Ubuntu ${UBUNTU_RELEASE} ${UBUNTU_VERSION} cloud image '${CLOUD_IMAGE_PATH}'..."
  wget -qO "${CLOUD_IMAGE_PATH}" "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_VERSION}/${CLOUD_IMAGE_NAME}"
fi

# Copy the cloud image to a new file
echo "Copying the cloud image '${CLOUD_IMAGE_PATH}' to '${CLOUD_IMAGE_PATH_CUSTOMIZED}'..."
cp -a "${CLOUD_IMAGE_PATH}" "${CLOUD_IMAGE_PATH_CUSTOMIZED}"

# Install qemu-guest-agent and magic-wormhole on the cloud image
echo "Installing qemu-guest-agent and magic-wormhole on the cloud image '${CLOUD_IMAGE_PATH_CUSTOMIZED}'..."
virt-customize -a "${CLOUD_IMAGE_PATH_CUSTOMIZED}" --install qemu-guest-agent,magic-wormhole

# Install Docker dependencies and Docker itself
virt-customize -a "${CLOUD_IMAGE_PATH_CUSTOMIZED}" --run-command '
  apt-get update && \
  apt-get install -y ca-certificates curl && \
  install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
  apt-get update && \
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
'

# Set root password on the cloud image
echo "Setting the root password on the cloud image '${CLOUD_IMAGE_PATH_CUSTOMIZED}'..."
virt-customize -a "${CLOUD_IMAGE_PATH_CUSTOMIZED}" --root-password "password:root"

# Clear the machine-id on the cloud image
echo "Clearing the machine-id on the cloud image '${CLOUD_IMAGE_PATH_CUSTOMIZED}'..."
virt-customize -a "${CLOUD_IMAGE_PATH_CUSTOMIZED}" --run-command "echo -n > /etc/machine-id"
