#!/bin/bash

# Function to print usage information
usage() {
  echo "Usage: $(basename "${0}") [OPTIONS]"
  echo
  echo "Options:"
  echo "  -v, --vm-id VM_ID               VM ID (required)"
  echo "  -N, --vm-name VM_NAME           VM name (default: docker-zfs-template-vm)"
  echo "  -u, --user USER                 User name (default: panzer1119)"
  echo "  -s, --vm-storage VM_STORAGE_ID  Storage ID for VM (default: storage-vm)"
  echo "  -k, --ssh-keys SSH_KEYS         SSH keys path or string (default: /home/\$USER/.ssh/authorized_keys)"
  echo "  -t, --storage STORAGE_ID        Storage ID for ISOs and Snippets (default: tn-core-1)"
  echo "  -i, --iso-dir ISO_DIR           ISO directory path (default: derived from STORAGE)"
  echo "  -e, --snippets-dir SNIPPETS_DIR Snippets directory path (default: derived from STORAGE)"
  echo "  -c, --snippet SNIPPET           Cloud-init snippet file (default: docker+zfs.yaml)"
  echo "  -d, --zfs-pool-docker-name ZFS_POOL_DOCKER_NAME Name for the docker ZFS pool (default: docker)"
  echo "  -D, --zfs-pool-docker-disk ZFS_POOL_DOCKER_DISK Disk for the docker ZFS pool (default: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0)"
  echo "  -L, --docker-var-lib-zfs-dataset-name        DOCKER_VAR_LIB_ZFS_DATASET_NAME        Name for the docker var lib ZFS dataset (default: state)"
  echo "  -S, --docker-storage-driver-zfs-dataset-name DOCKER_STORAGE_DRIVER_ZFS_DATASET_NAME Name for the docker storage driver ZFS dataset (default: layers)"
  echo "  -V, --docker-volume-plugin-zfs-dataset-name  DOCKER_VOLUME_PLUGIN_ZFS_DATASET_NAME  Name for the docker volume plugin ZFS dataset  (default: volumes)"
  echo "  -C, --cloud-image CLOUD_IMAGE   Cloud image file (required)"
  echo "  -p, --cipassword CIPASSWORD     Cloud-init password (default: password)"
  echo "  -I, --ipconfig0 IPCONFIG0       IP configuration (default: ip=dhcp)"
  echo "                                  Example for static IPv4 with gateway: ip=192.168.1.100/24,gw=192.168.1.1"
  echo "  -T, --tags TAGS                 Tags for the VM (default: cloudinit,docker,zfs)"
  echo "  -g, --gelf-driver ADDRESS       Address for Docker GELF logging driver (default: udp://monitoring-vm.local.panzer1119.de:12201)"
  echo "  -h, --help                      Display this help and exit"
  echo "  -n, --dry-run                   Print the commands without executing them"
  echo
  echo "Required Options:"
  echo "  -v, --vm-id VM_ID"
  echo "  -C, --cloud-image CLOUD_IMAGE"
  exit 1
}

# Check for required packages
check_requirements() {
  local commands=("pvesh" "jq" "qm" "sed" "sudo")
  local command
  # Check that they are installed
  for command in "${commands[@]}"; do
    if ! command -v "${command}" &> /dev/null; then
      echo "Error: Command ${command} not found. Please install it first."
      exit 1
    fi
  done
}

dry_run=false

# Function to execute a command or print it if dry run
run_command() {
    if [ "${dry_run}" = true ]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Function to derive storage mountpoint based on Proxmox storage
derive_storage_mountpoint() {
    local storage_id="${1}"
    local iso_dir="${2}"
    local snippets_dir="${3}"
    local storage_info=""
    local mountpoint=""

    # Get storage info from Proxmox API and store it in a variable
    if ! storage_info=$(run_command sudo pvesh get "/storage/${storage_id}" --output-format json); then
        echo "Error: Storage '${storage_id}' does not exist."
        exit 1
    fi

    # If iso_dir is not specified, check if storage supports content type 'iso'
    if [ -z "${iso_dir}" ]; then
        if ! echo "${storage_info}" | jq -e '.content|index("iso")' &>/dev/null; then
            echo "Error: Storage '${storage_id}' must be enabled for content type 'iso'."
            exit 1
        fi
    fi

    # If snippets_dir is not specified, check if storage supports content type 'snippets'
    if [ -z "${snippets_dir}" ]; then
        if ! echo "${storage_info}" | jq -e '.content|index("snippets")' &>/dev/null; then
            echo "Error: Storage '${storage_id}' must be enabled for content type 'snippets'."
            exit 1
        fi
    fi

    # Get the mountpoint
    mountpoint=$(echo "${storage_info}" | jq -r '.path')

    # Check if mountpoint exists
    if [ ! -d "${mountpoint}" ]; then
        echo "Error: Mount point '${mountpoint}' does not exist."
        exit 1
    fi

    # Return storage mount point
    echo "${mountpoint}"
}

# Function to derive iso directory based on Proxmox storage
derive_iso_dir() {
    local mountpoint="${1}"
    local iso_dir=""

    # Derive ISO directory
    iso_dir="${mountpoint}/template/iso"

    # Check if ISO directory exists
    if [ ! -d "${iso_dir}" ]; then
        echo "Error: ISO directory '${iso_dir}' does not exist."
        exit 1
    fi

    # Return ISO directory
    echo "${iso_dir}"
}

# Function to derive snippets directory based on Proxmox storage
derive_snippets_dir() {
    local mountpoint="${1}"
    local snippets_dir=""

    # Derive snippets directory
    snippets_dir="${mountpoint}/snippets"

    # Check if snippets directory exists
    if [ ! -d "${snippets_dir}" ]; then
        echo "Error: Snippets directory '${snippets_dir}' does not exist."
        exit 1
    fi

    # Return snippets directory
    echo "${snippets_dir}"
}

# Main function
main() {
  # Default values
  local vm_id=""
  local vm_name="docker-zfs-template-vm"
  local user="panzer1119"
  local vm_storage="storage-vm"
  local ssh_keys="/home/${user}/.ssh/authorized_keys"
  local storage_id="tn-core-1"
  local storage_mountpoint=""
  local iso_dir=""
  local snippets_dir=""
  local snippet="docker+zfs.yaml"
  local zfs_pool_docker_name="docker"
  local zfs_pool_docker_disk="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"
  local docker_var_lib_zfs_dataset_name="state"
  local docker_storage_driver_zfs_dataset_name="layers"
  local docker_volume_plugin_zfs_dataset_name="volumes"
  local cloud_image=""
  local cipassword="password"
  local ipconfig0="ip=dhcp"
  local tags="cloudinit,docker,zfs"
  local gelf_driver="udp://monitoring-vm.local.panzer1119.de:12201"

  # Check for sudo/root permissions
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
  fi

  # Check for required packages
  check_requirements

  # Parse command-line options
  while getopts ":v:N:u:s:k:t:i:e:c:d:D:L:S:V:C:p:I:T:g:hn-:" opt; do
    case ${opt} in
      -)
        case "${OPTARG}" in
          vm-id) vm_id="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          vm-name) vm_name="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          user) user="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          vm-storage) vm_storage="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          ssh-keys) ssh_keys="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          storage) storage_id="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          iso-dir) iso_dir="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          snippets-dir) snippets_dir="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          snippet) snippet="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          zfs-pool-docker-name) zfs_pool_docker_name="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          zfs-pool-docker-disk) zfs_pool_docker_disk="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          docker-var-lib-zfs-dataset-name) docker_var_lib_zfs_dataset_name="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          docker-storage-driver-zfs-dataset-name) docker_storage_driver_zfs_dataset_name="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          docker-volume-plugin-zfs-dataset-name) docker_volume_plugin_zfs_dataset_name="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          cloud-image) cloud_image="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          cipassword) cipassword="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          ipconfig0) ipconfig0="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          tags) tags="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          gelf-driver) gelf_driver="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
          help) usage ;;
          dry-run) dry_run=true ;;
          *) echo "Invalid option: --${OPTARG}. Use -h for help." >&2; exit 1 ;;
        esac
        ;;
      v) vm_id="${OPTARG}" ;;
      N) vm_name="${OPTARG}" ;;
      u) user="${OPTARG}" ;;
      s) vm_storage="${OPTARG}" ;;
      k) ssh_keys="${OPTARG}" ;;
      t) storage_id="${OPTARG}" ;;
      i) iso_dir="${OPTARG}" ;;
      e) snippets_dir="${OPTARG}" ;;
      c) snippet="${OPTARG}" ;;
      d) zfs_pool_docker_name="${OPTARG}" ;;
      D) zfs_pool_docker_disk="${OPTARG}" ;;
      L) docker_var_lib_zfs_dataset_name="${OPTARG}" ;;
      S) docker_storage_driver_zfs_dataset_name="${OPTARG}" ;;
      V) docker_volume_plugin_zfs_dataset_name="${OPTARG}" ;;
      C) cloud_image="${OPTARG}" ;;
      p) cipassword="${OPTARG}" ;;
      I) ipconfig0="${OPTARG}" ;;
      T) tags="${OPTARG}" ;;
      g) gelf_driver="${OPTARG}" ;;
      h) usage ;;
      n) dry_run=true ;;
      \?) echo "Invalid option: -${OPTARG}. Use -h for help." >&2; exit 1 ;;
      :) echo "Option -${OPTARG} requires an argument. Use -h for help." >&2; exit 1 ;;
    esac
  done

  # Check for required options
  if [ -z "${vm_id}" ] || [ -z "${cloud_image}" ]; then
    echo "Error: VM ID (-v, --vm-id) and Cloud image (-C, --cloud-image) are required."
    exit 1
  fi

  # Derive storage mountpoint if iso_dir or snippets_dir is not specified
  if [ -z "${iso_dir}" ] || [ -z "${snippets_dir}" ]; then
    storage_mountpoint=$(derive_storage_mountpoint "${storage_id}" "${iso_dir}" "${snippets_dir}")
  fi

  # Derive image directory if not specified
  if [ -z "${iso_dir}" ]; then
    iso_dir=$(derive_iso_dir "${storage_mountpoint}")
  fi

  # Derive snippets directory if not specified
  if [ -z "${snippets_dir}" ]; then
    snippets_dir=$(derive_snippets_dir "${storage_mountpoint}")
  fi

  # Check if the cloud image exists locally
  local cloud_image_path="${iso_dir}/${cloud_image}"
  if [ ! -f "${cloud_image_path}" ]; then
    echo "Error: Cloud image '${cloud_image}' not found at '${cloud_image_path}'. Exiting."
    exit 1
  fi

  # Check if the VM exists with qm and delete if so
  if sudo qm list | grep -q "${vm_id}"; then
    # Destroy the VM if it exists
    echo "Destroying existing VM '${vm_id}'..."
    run_command sudo qm destroy "${vm_id}"
  fi

  # Create the VM
  echo "Creating VM '${vm_id}' with name '${vm_name}'..."
  run_command sudo qm create "${vm_id}" --name "${vm_name}" --ostype l26 --memory 1024 --balloon 0 --agent 1 --bios ovmf --machine q35 --efidisk0 "${vm_storage}:0,pre-enrolled-keys=0" --cpu host --cores 1 --numa 1 --vga serial0 --serial0 socket --net0 virtio,bridge=vmbr0,mtu=1

  # Import the cloud image
  echo "Importing the cloud image '${cloud_image}' to VM '${vm_id}' storage '${vm_storage}'..."
  run_command sudo qm importdisk "${vm_id}" "${cloud_image_path}" "${vm_storage}"

  # Attach the cloud image
  echo "Attaching the cloud image '${cloud_image}' to VM '${vm_id}' as disk 1..."
  run_command sudo qm set "${vm_id}" --scsihw virtio-scsi-pci --virtio0 "${vm_storage}:vm-${vm_id}-disk-1,discard=on"

  # Set the boot order
  echo "Setting the boot order for VM '${vm_id}'..."
  run_command sudo qm set "${vm_id}" --boot order=virtio0

  # Set the cloud-init drive
  echo "Setting the cloud-init drive for VM '${vm_id}'..."
  run_command sudo qm set "${vm_id}" --ide2 "${vm_storage}:cloudinit"

  # Copy the cloud-init configuration to the snippets directory (overwrite if exists)
  local snippet_src_path="./cloud-config/${snippet}"
  echo "Copying the cloud-init configuration '${snippet_src_path}' to '${snippets_dir}/${snippet}'..."
  run_command sudo cp -f "${snippet_src_path}" "${snippets_dir}/${snippet}"

  # Replace variables in the cloud-init configuration
  echo "Replacing variables in the cloud-init configuration '${snippets_dir}/${snippet}'..."
  run_command sudo sed -i "s|{{USER}}|${user}|g" "${snippets_dir}/${snippet}"
  run_command sudo sed -i "s|{{ZFS_POOL_DOCKER_NAME}}|${zfs_pool_docker_name}|g" "${snippets_dir}/${snippet}"
  run_command sudo sed -i "s|{{ZFS_POOL_DOCKER_DISK}}|${zfs_pool_docker_disk}|g" "${snippets_dir}/${snippet}"
  run_command sudo sed -i "s|{{DOCKER_VAR_LIB_ZFS_DATASET_NAME}}|${docker_var_lib_zfs_dataset_name}|g" "${snippets_dir}/${snippet}"
  run_command sudo sed -i "s|{{DOCKER_STORAGE_DRIVER_ZFS_DATASET_NAME}}|${docker_storage_driver_zfs_dataset_name}|g" "${snippets_dir}/${snippet}"
  run_command sudo sed -i "s|{{DOCKER_VOLUME_PLUGIN_ZFS_DATASET_NAME}}|${docker_volume_plugin_zfs_dataset_name}|g" "${snippets_dir}/${snippet}"

  # TODO Setup portainer agent
  # TODO Setup watchtower (but only for notifications? or simply exclude those that are mission critical?)

#FIXME Use jq to edit the file and rename gelf_driver to gelf_driver_address
#   # Configure Docker GELF logging driver
#   echo "Configuring Docker GELF logging driver to use '${gelf_driver}'..."
#   echo '{ "log-driver": "gelf", "log-opts": { "gelf-address": "'"${gelf_driver}"'" } }' | sudo tee /etc/docker/daemon.json >/dev/null

  # Set the VM options
  echo "Setting the VM options for VM '${vm_id}'..."
  run_command sudo qm set "${vm_id}" --cicustom "vendor=${storage_id}:snippets/${snippet}"
  run_command sudo qm set "${vm_id}" --tags "${tags}"
  run_command sudo qm set "${vm_id}" --ciuser "${user}"
  run_command sudo qm set "${vm_id}" --cipassword "${cipassword}"
  run_command sudo qm set "${vm_id}" --sshkeys "${ssh_keys}"
  run_command sudo qm set "${vm_id}" --ipconfig0 "${ipconfig0}"

  echo "VM creation and configuration completed successfully."

  # Convert the VM to a template
  run_command sudo qm template "${vm_id}"
  echo "VM '${vm_id}' converted to a template."
}

# Run main function with command-line arguments
main "$@"
