#!/bin/bash

# Function to print usage information
usage() {
  echo "Usage: $(basename "$0") [OPTIONS]"
  echo
  echo "Options:"
  echo "  -v, --vm-id VM_ID             VM ID (required)"
  echo "  -n, --vm-name VM_NAME         VM name (default: docker-zfs-template-vm)"
  echo "  -u, --user USER               User name (default: panzer1119)"
  echo "  -s, --storage-vm STORAGE_VM   Storage VM name (default: storage-vm)"
  echo "  -k, --ssh-keys SSH_KEYS       SSH keys path (default: /home/\$USER/.ssh/authorized_keys)"
  echo "  -t, --storage STORAGE         Storage name (default: tn-core-1)"
  echo "  -i, --image-dir IMAGE_DIR     Image directory path (default: /mnt/pve/\$STORAGE/images)"
  echo "  -N, --snippets-dir SNIPPETS_DIR  Snippets directory path (default: /mnt/pve/\$STORAGE/snippets)"
  echo "  -c, --snippet SNIPPET         Cloud-init snippet file (default: docker+zfs.yaml)"
  echo "  -d, --disk-zpool-docker DISK_ZPOOL_DOCKER  Docker disk zpool (default: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0)"
  echo "  -C, --cloud-image CLOUD_IMAGE Cloud image file (required)"
  echo "  -h, --help                    Display this help and exit"
  echo
  echo "Required Options:"
  echo "  -v, --vm-id VM_ID"
  echo "  -C, --cloud-image CLOUD_IMAGE"
  exit 1
}

# Main function
main() {
  # Default values
  local vm_id=""
  local vm_name="docker-zfs-template-vm"
  local user="panzer1119"
  local storage_vm="storage-vm"
  local ssh_keys="/home/${user}/.ssh/authorized_keys"
  local storage="tn-core-1"
  local image_dir="/mnt/pve/${storage}/images"
  local snippets_dir="/mnt/pve/${storage}/snippets"
  local snippet="docker+zfs.yaml"
  local disk_zpool_docker="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"
  local cloud_image=""

  # Parse command-line options
  while getopts ":v:n:u:s:k:t:i:N:c:d:C:h" opt; do
    case ${opt} in
      v) vm_id="${OPTARG}" ;;
      n) vm_name="${OPTARG}" ;;
      u) user="${OPTARG}" ;;
      s) storage_vm="${OPTARG}" ;;
      k) ssh_keys="${OPTARG}" ;;
      t) storage="${OPTARG}" ;;
      i) image_dir="${OPTARG}" ;;
      N) snippets_dir="${OPTARG}" ;;
      c) snippet="${OPTARG}" ;;
      d) disk_zpool_docker="${OPTARG}" ;;
      C) cloud_image="${OPTARG}" ;;
      h) usage ;;
      \?) echo "Invalid option: -${OPTARG}. Use -h for help." >&2; exit 1 ;;
      :) echo "Option -${OPTARG} requires an argument. Use -h for help." >&2; exit 1 ;;
    esac
  done

  # Check for required options
  if [ -z "${vm_id}" ]; then
    echo "Error: VM ID (-v, --vm-id) is required."
    exit 1
  fi

  if [ -z "${cloud_image}" ]; then
    echo "Error: Cloud image (-C, --cloud-image) is required."
    exit 1
  fi

  # Check if the cloud image exists locally
  local cloud_image_path="${image_dir}/${cloud_image}"
  if [ ! -f "${cloud_image_path}" ]; then
    echo "Error: Cloud image '${cloud_image}' not found at '${cloud_image_path}'. Exiting."
    exit 1
  fi

  # Check if the VM exists with qm and delete if so
  if sudo qm list | grep -q "${vm_id}"; then
    # Destroy the VM if it exists
    echo "Destroying existing VM '${vm_id}'..."
    sudo qm destroy "${vm_id}"
  fi

  # Create the VM
  echo "Creating VM '${vm_id}' with name '${vm_name}'..."
  sudo qm create "${vm_id}" --name "${vm_name}" --ostype "l26" \
    --memory "1024" --balloon "0" \
    --agent "1" \
    --bios "ovmf" --machine "q35" --efidisk0 "${storage_vm}:0,pre-enrolled-keys=0" \
    --cpu "host" --cores "1" --numa "1" \
    --vga "serial0" --serial0 "socket" \
    --net0 "virtio,bridge=vmbr0,mtu=1"

  # Import the cloud image
  echo "Importing the cloud image '${cloud_image}' to VM '${vm_id}' storage '${storage_vm}'..."
  sudo qm importdisk "${vm_id}" "${cloud_image_path}" "${storage_vm}"

  # Attach the cloud image
  echo "Attaching the cloud image '${cloud_image}' to VM '${vm_id}' as disk 1..."
  sudo qm set "${vm_id}" --scsihw "virtio-scsi-pci" --virtio0 "${storage_vm}:vm-${vm_id}-disk-1,discard=on"

  # Set the boot order
  echo "Setting the boot order for VM '${vm_id}'..."
  sudo qm set "${vm_id}" --boot "order=virtio0"

  # Set the cloud-init drive
  echo "Setting the cloud-init drive for VM '${vm_id}'..."
  sudo qm set "${vm_id}" --ide2 "${storage_vm}:cloudinit"

  # Copy the cloud-init configuration to the snippets directory (overwrite if exists)
  local snippet_src_path="./cloud-config/${snippet}"
  echo "Copying the cloud-init configuration '${snippet_src_path}' to '${snippets_dir}/${snippet}'..."
  sudo cp -f "${snippet_src_path}" "${snippets_dir}/${snippet}"

  # Replace variables in the cloud-init configuration
  echo "Replacing variables in the cloud-init configuration '${snippets_dir}/${snippet}'..."
  sudo sed -i "s|{{USER}}|${user}|g" "${snippets_dir}/${snippet}"
  sudo sed -i "s|{{DISK_ZPOOL_DOCKER}}|${disk_zpool_docker}|g" "${snippets_dir}/${snippet}"

  # TODO Setup /etc/docker/daemon.json to use Graylog GELF logging driver
  # TODO Setup portainer agent
  # TODO Setup watchtower (but only for notifications? or simply exclude those that are mission critical?)
  # TODO Setup docker zfs storage driver (and docker zfs plugin for volumes)

  # Set the VM options
  echo "Setting the VM options for VM '${vm_id}'..."
  sudo qm set "${vm_id}" --cicustom "vendor=${storage}:snippets/${snippet}"
  sudo qm set "${vm_id}" --tags "ubuntu-template,noble,cloudinit,docker,zfs"
  sudo qm set "${vm_id}" --ciuser "${user}"
  sudo qm set "${vm_id}" --cipassword "password"
  sudo qm set "${vm_id}" --sshkeys "${ssh_keys}"
  sudo qm set "${vm_id}" --ipconfig0 "ip=dhcp"
  sudo qm template "${vm_id}"
}

# Call the main function with all arguments passed to the script
main "$@"
