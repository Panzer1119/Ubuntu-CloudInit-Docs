#! /bin/bash

# Usage: ./ubuntu-noble-cloudinit.sh [VM_ID] [USER] [STORAGE_VM] [SSH_KEYS] [STORAGE] [IMAGE_DIR] [SNIPPETS_DIR]

# Input variables
export VM_ID="${0:-5000}"
export USER="${1:-panzer1119}"
export STORAGE_VM="${2:-storage-vm}"
export SSH_KEYS="${3:-/home/${USER}/.ssh/authorized_keys}"
export STORAGE="${4:-tn-core-1}"
export IMAGE_DIR="${5:-/mnt/pve/${STORAGE}/images}"
export SNIPPETS_DIR="${6:-/mnt/pve/${STORAGE}/snippets}"

# Constants
export UBUNTU_RELEASE="noble"
export UBUNTU_VERSION="current"
export ARCH="amd64"
export CLOUD_IMAGE="${UBUNTU_RELEASE}-server-cloudimg-${ARCH}.img"
export CLOUD_IMAGE_PATH="${IMAGE_DIR}/${CLOUD_IMAGE}"

# Unofficial strict mode
set -x

# Get the SHA256SUMS for ubuntu noble cloud images
echo "Getting SHA256SUMS for Ubuntu Noble cloud images..."
sha256sums=$(wget -qO- "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_VERSION}/SHA256SUMS")

# Check if the cloud image exists locally
if [ -f "${CLOUD_IMAGE_PATH}" ]; then
    # Calculate the SHA256 checksum of the local cloud image
    sha256sum_local=$(sha256sum "${CLOUD_IMAGE_PATH}" | awk '{print $1}')
    # Get the SHA256 checksum of the remote cloud image
    sha256sum_remote=$(echo "${sha256sums}" | grep "${CLOUD_IMAGE}" | awk '{print $1}')
    # Delete the cloud image if the checksums do not match
    if [ "${sha256sum_local}" != "${sha256sum_remote}" ]; then
        echo "SHA256 checksums do not match. Deleting the local cloud image ${CLOUD_IMAGE}..."
        rm -f "${CLOUD_IMAGE_PATH}"
  fi
fi

# Download the cloud image if not found locally
if [ ! -f "${CLOUD_IMAGE_PATH}" ]; then
    echo "Downloading the Ubuntu Noble cloud image ${CLOUD_IMAGE}..."
    wget -qO "${CLOUD_IMAGE_PATH}" "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_VERSION}/${CLOUD_IMAGE}"
fi

# Resize the cloud image
qemu-img resize "${CLOUD_IMAGE_PATH}" "8G"

# Destroy the VM if it exists
sudo qm destroy "${VM_ID}"

# Create the VM
sudo qm create "${VM_ID}" --name "ubuntu-noble-template" --ostype "l26" \
    --memory "1024" --balloon "0" \
    --agent "1" \
    --bios "ovmf" --machine "q35" --efidisk0 "${STORAGE_VM}:0,pre-enrolled-keys=0" \
    --cpu "host" --cores "1" --numa "1" \
    --vga "serial0" --serial0 "socket" \
    --net0 "virtio,bridge=vmbr0,mtu=1"

# Import the cloud image
sudo qm importdisk "${VM_ID}" "${CLOUD_IMAGE}" "${STORAGE_VM}"

# Attach the cloud image
sudo qm set "${VM_ID}" --scsihw "virtio-scsi-pci" --virtio0 "${STORAGE_VM}:vm-${VM_ID}-disk-1,discard=on"

# Set the boot order
sudo qm set "${VM_ID}" --boot "order=virtio0"

# Set the cloud-init drive
sudo qm set "${VM_ID}" --ide2 "${STORAGE_VM}:cloudinit"

# Set the cloud-init configuration
cat <<EOF  | sudo tee "${SNIPPETS_DIR}/ubuntu.yaml"
#cloud-config
runcmd:
    - apt-get update
    - apt-get install -y qemu-guest-agent magic-wormhole
    - systemctl enable ssh
    - reboot
# Taken from https://forum.proxmox.com/threads/combining-custom-cloud-init-with-auto-generated.59008/page-3#post-428772
EOF

# Set the VM options
sudo qm set "${VM_ID}" --cicustom "vendor=${STORAGE}:snippets/ubuntu.yaml"
sudo qm set "${VM_ID}" --tags "ubuntu-template,noble,cloudinit"
sudo qm set "${VM_ID}" --ciuser "${USER}"
sudo qm set "${VM_ID}" --sshkeys "${SSH_KEYS}"
sudo qm set "${VM_ID}" --ipconfig0 "ip=dhcp"
sudo qm template "${VM_ID}"
