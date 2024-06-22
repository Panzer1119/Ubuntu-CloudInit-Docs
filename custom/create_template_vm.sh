#! /bin/bash

# Default values
DEFAULT_VM_ID="5002"
DEFAULT_USER="panzer1119"
DEFAULT_STORAGE_VM="storage-vm"
DEFAULT_SSH_KEYS="/home/${DEFAULT_USER}/.ssh/authorized_keys"
DEFAULT_STORAGE="tn-core-1"
DEFAULT_IMAGE_DIR="/mnt/pve/${DEFAULT_STORAGE}/images"
DEFAULT_SNIPPETS_DIR="/mnt/pve/${DEFAULT_STORAGE}/snippets"
DEFAULT_SNIPPET="docker+zfs.yaml"
DEFAULT_DISK_ZPOOL_DOCKER="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"

# Function to print usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -v, --vm-id VM_ID             VM ID (default: ${DEFAULT_VM_ID})
  -u, --user USER               User name (default: ${DEFAULT_USER})
  -s, --storage-vm STORAGE_VM   Storage VM name (default: ${DEFAULT_STORAGE_VM})
  -k, --ssh-keys SSH_KEYS       SSH keys path (default: ${DEFAULT_SSH_KEYS})
  -t, --storage STORAGE         Storage name (default: ${DEFAULT_STORAGE})
  -i, --image-dir IMAGE_DIR     Image directory path (default: ${DEFAULT_IMAGE_DIR})
  -n, --snippets-dir SNIPPETS_DIR  Snippets directory path (default: ${DEFAULT_SNIPPETS_DIR})
  -c, --snippet SNIPPET         Cloud-init snippet file (default: ${DEFAULT_SNIPPET})
  -d, --disk-zpool-docker DISK_ZPOOL_DOCKER  Docker disk zpool (default: ${DEFAULT_DISK_ZPOOL_DOCKER})
  -h, --help                    Display this help and exit
EOF
}

# Parse command-line options
while getopts ":v:u:s:k:t:i:n:c:d:h" opt; do
  case ${opt} in
    v) VM_ID="${OPTARG}" ;;
    u) USER="${OPTARG}" ;;
    s) STORAGE_VM="${OPTARG}" ;;
    k) SSH_KEYS="${OPTARG}" ;;
    t) STORAGE="${OPTARG}" ;;
    i) IMAGE_DIR="${OPTARG}" ;;
    n) SNIPPETS_DIR="${OPTARG}" ;;
    c) SNIPPET="${OPTARG}" ;;
    d) DISK_ZPOOL_DOCKER="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -${OPTARG}. Use -h for help." >&2; exit 1 ;;
    :) echo "Option -${OPTARG} requires an argument. Use -h for help." >&2; exit 1 ;;
  esac
done

shift $((OPTIND -1))

# Check if the cloud image exists locally
CLOUD_IMAGE="noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_PATH="${IMAGE_DIR}/${CLOUD_IMAGE}"

if [ ! -f "${CLOUD_IMAGE_PATH}" ]; then
  echo "Error: Cloud image '${CLOUD_IMAGE}' not found at '${CLOUD_IMAGE_PATH}'. Exiting."
  exit 1
fi

# Check if the VM exists with qm and delete if so
if sudo qm list | grep -q "${VM_ID}"; then
  # Destroy the VM if it exists
  echo "Destroying existing VM '${VM_ID}'..."
  sudo qm destroy "${VM_ID}"
fi

# Create the VM
echo "Creating VM '${VM_ID}'..."
sudo qm create "${VM_ID}" --name "ubuntu-docker-zfs-template-vm" --ostype "l26" \
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
sudo sed -i "s|{{DISK_ZPOOL_DOCKER}}|${DISK_ZPOOL_DOCKER}|g" "${SNIPPETS_DIR}/${SNIPPET}"

# TODO Setup /etc/docker/daemon.json to use Graylog GELF logging driver
# TODO Setup portainer agent
# TODO Setup watchtower (but only for notifications? or simply exclude those that are mission critical?)
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
