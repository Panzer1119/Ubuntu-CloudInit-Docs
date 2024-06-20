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
export UBUNTU_VERSION="current"
export ARCH="amd64"
export CLOUD_IMAGE="${UBUNTU_RELEASE}-server-cloudimg-${ARCH}.img"
export CLOUD_IMAGE_PATH="${IMAGE_DIR}/${CLOUD_IMAGE}"
export IMAGE_RESIZE="8G"
export SNIPPET="ubuntu+docker+zfs.yaml"

# Unofficial strict mode
#set -x

# Get the SHA256SUMS for ubuntu noble cloud images
echo "Getting SHA256SUMS for Ubuntu ${UBUNTU_RELEASE} ${UBUNTU_VERSION} cloud images..."
sha256sums=$(wget -qO- "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_VERSION}/SHA256SUMS")

# Check if the cloud image exists locally
if [ -f "${CLOUD_IMAGE_PATH}" ]; then
  # Get the SHA256 checksum of the remote cloud image
  echo "Extracting the SHA256 checksum of the remote cloud image '${CLOUD_IMAGE}'..."
  sha256sum_remote=$(echo "${sha256sums}" | grep "${CLOUD_IMAGE}" | awk '{print $1}')
  # Calculate the SHA256 checksum of the local cloud image
  echo "Calculating the SHA256 checksum of the local cloud image '${CLOUD_IMAGE}'..."
  sha256sum_local=$(sha256sum "${CLOUD_IMAGE_PATH}" | awk '{print $1}')
  # Delete the cloud image if the checksums do not match
  if [ "${sha256sum_local}" != "${sha256sum_remote}" ]; then
    # Check if image size is IMAGE_RESIZE, so we can skip the download (convert IMAGE_RESIZE to bytes)
    image_resize_bytes=$(echo "${IMAGE_RESIZE}" | numfmt --from=iec)
    echo "SHA256 checksums do not match."
    if [ "$(qemu-img info --output json "${CLOUD_IMAGE_PATH}" | jq -r '.["virtual-size"]')" == "${image_resize_bytes}" ]; then
      echo "The local cloud image '${CLOUD_IMAGE}' is already resized to ${IMAGE_RESIZE}."
    else
      echo "Deleting the local cloud image '${CLOUD_IMAGE}'..."
      rm -f "${CLOUD_IMAGE_PATH}"
    fi
  else
    echo "SHA256 checksums match. The local cloud image '${CLOUD_IMAGE}' is up-to-date."
  fi
else
  echo "The local cloud image '${CLOUD_IMAGE}' does not exist."
fi

# Download the cloud image if not found locally
if [ ! -f "${CLOUD_IMAGE_PATH}" ]; then
  echo "Downloading the Ubuntu ${UBUNTU_RELEASE} ${UBUNTU_VERSION} cloud image '${CLOUD_IMAGE}'..."
  wget -qO "${CLOUD_IMAGE_PATH}" "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_VERSION}/${CLOUD_IMAGE}"
fi

# Resize the cloud image
echo "Resizing the cloud image '${CLOUD_IMAGE}' to ${IMAGE_RESIZE}..."
qemu-img resize "${CLOUD_IMAGE_PATH}" "${IMAGE_RESIZE}"

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

# Set the cloud-init configuration
echo "Generating the cloud-init configuration '${SNIPPETS_DIR}/${SNIPPET}'..."
cat <<EOF  | sudo tee "${SNIPPETS_DIR}/${SNIPPET}"
#cloud-config
groups:
  - docker

users:
  - name: ${USER}
  - groups: docker

package_update: true
package_upgrade: true
package_reboot_if_required: true

apt:
  sources:
    docker.list:
      source: "deb [arch=${ARCH} signed-by=/etc/apt/trusted.gpg.d/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_RELEASE} stable"
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
      filename: docker.list

packages:
  - qemu-guest-agent
  - magic-wormhole
  - zfsutils-linux
  - ca-certificates
  - curl
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - docker-buildx-plugin
  - docker-compose-plugin

runcmd:
  # Enable the ssh service
  - systemctl enable ssh
  # Reboot the VM
  - reboot

# Taken from https://forum.proxmox.com/threads/combining-custom-cloud-init-with-auto-generated.59008/page-3#post-428772
EOF

# TODO Setup /etc/docker/daemon.json to use Graylog GELF logging driver
# TODO Setup docker zfs storage driver (and docker zfs plugin for volumes)

# Set the VM options
echo "Setting the VM options for VM '${VM_ID}'..."
sudo qm set "${VM_ID}" --cicustom "vendor=${STORAGE}:snippets/${SNIPPET}"
sudo qm set "${VM_ID}" --tags "ubuntu-template,noble,cloudinit,docker,zfs"
sudo qm set "${VM_ID}" --ciuser "${USER}"
sudo qm set "${VM_ID}" --cipassword "password"
sudo qm set "${VM_ID}" --sshkeys "${SSH_KEYS}"
sudo qm set "${VM_ID}" --ipconfig0 "ip=dhcp"
sudo qm template "${VM_ID}"
