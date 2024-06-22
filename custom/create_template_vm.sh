#! /bin/bash

# Usage: ./ubuntu-noble-cloudinit.sh [VM_ID] [USER] [STORAGE_VM] [SSH_KEYS] [STORAGE] [IMAGE_DIR] [SNIPPETS_DIR]

# Input variables
export VM_ID="${1:-5002}"
export USER="${2:-panzer1119}"
export STORAGE_VM="${3:-storage-vm}"
export SSH_KEYS="${4:-/home/${USER}/.ssh/authorized_keys}"
export STORAGE="${5:-tn-core-1}"
export IMAGE_DIR="${6:-/mnt/pve/${STORAGE}/images}"
export SNIPPETS_DIR="${7:-/mnt/pve/${STORAGE}/snippets}"

# Constants
export UBUNTU_RELEASE="noble"
export ARCH="amd64"
export DISK_ZPOOL_DOCKER="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"
export SNIPPET="ubuntu+docker+zfs.yaml"
export SNIPPET_SRC_PATH="./cloud-config/${SNIPPET}"

# Unofficial strict mode
#set -x

# Check if the cloud image exists locally
CLOUD_IMAGE="${UBUNTU_RELEASE}-server-cloudimg-${ARCH}.img"
CLOUD_IMAGE_PATH="${IMAGE_DIR}/${CLOUD_IMAGE}"

if [ -f "${CLOUD_IMAGE_PATH}" ]; then
  echo "Using existing cloud image '${CLOUD_IMAGE}' at '${CLOUD_IMAGE_PATH}'."
else
  echo "Error: Cloud image '${CLOUD_IMAGE}' not found at '${CLOUD_IMAGE_PATH}'. Exiting."
  exit 1
fi

# Check if the VM exists with qm and delete if so
if sudo qm list | grep -q "${VM_ID}"; then
  # Destroy the VM if it exists
  echo "Destroying existing VM '${VM_ID}'..."
  sudo qm destroy "${VM_ID}"
#else
#  echo "The VM '${VM_ID}' does not exist."
fi

# Create the VM
echo "Creating VM '${VM_ID}'..."
sudo qm create "${VM_ID}" --name "ubuntu-${UBUNTU_RELEASE}-docker-zfs-template-vm" --ostype "l26" \
  --memory "1024" --balloon "0" \
  --agent "1" \
  --bios "ovmf" --machine "q35" --efidisk0 "${STORAGE_VM}:0,pre-enrolled-keys=0" \
  --cpu "host" --cores "1" --numa "1" \
  --vga "serial0" --serial0 "socket" \
  --net0 "virtio,bridge=vmbr0,mtu=1"

# Import the cloud image
echo "Importing the cloud image '${CLOUD_IMAGE}' to VM '${VM_ID}' storage '${STORAGE_VM}'..."
sudo qm importdisk "${VM_ID}" "${CLOUD_IMAGE_PATH}" "${STORAGE_VM}"

# Attach the cloud image
echo "Attaching the cloud image '${CLOUD_IMAGE}' to VM '${VM_ID}' as disk 1..."
sudo qm set "${VM_ID}" --scsihw "virtio-scsi-pci" --virtio0 "${STORAGE_VM}:vm-${VM_ID}-disk-1,discard=on"

# Set the boot order
echo "Setting the boot order for VM '${VM_ID}'..."
sudo qm set "${VM_ID}" --boot "order=virtio0"

# Set the cloud-init drive
echo "Setting the cloud-init drive for VM '${VM_ID}'..."
sudo qm set "${VM_ID}" --ide2 "${STORAGE_VM}:cloudinit"

# Copy the cloud-init configuration to the snippets directory (overwrite if exists)
echo "Copying the cloud-init configuration '${SNIPPET_SRC_PATH}' to '${SNIPPETS_DIR}/${SNIPPET}'..."
sudo cp -f "${SNIPPET_SRC_PATH}" "${SNIPPETS_DIR}/${SNIPPET}"

# Replace variables in the cloud-init configuration
echo "Replacing variables in the cloud-init configuration '${SNIPPETS_DIR}/${SNIPPET}'..."
sudo sed -i "s|{{USER}}|${USER}|g" "${SNIPPETS_DIR}/${SNIPPET}"
sudo sed -i "s|{{ARCH}}|${ARCH}|g" "${SNIPPETS_DIR}/${SNIPPET}"
sudo sed -i "s|{{UBUNTU_RELEASE}}|${UBUNTU_RELEASE}|g" "${SNIPPETS_DIR}/${SNIPPET}"
sudo sed -i "s|{{DISK_ZPOOL_DOCKER}}|${DISK_ZPOOL_DOCKER}|g" "${SNIPPETS_DIR}/${SNIPPET}"

# Set the VM options
echo "Setting the VM options for VM '${VM_ID}'..."
sudo qm set "${VM_ID}" --cicustom "vendor=${STORAGE}:snippets/${SNIPPET}"
sudo qm set "${VM_ID}" --tags "ubuntu-template,noble,cloudinit,docker,zfs"
sudo qm set "${VM_ID}" --ciuser "${USER}"
sudo qm set "${VM_ID}" --cipassword "password"
sudo qm set "${VM_ID}" --sshkeys "${SSH_KEYS}"
sudo qm set "${VM_ID}" --ipconfig0 "ip=dhcp"
sudo qm template "${VM_ID}"
