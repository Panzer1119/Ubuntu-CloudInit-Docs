#!/bin/bash

# Help function
usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -d, --distro    Distribution (default: ubuntu)"
  echo "                  Available options: ubuntu, debian, fedora"
  echo "  -r, --release   Release (default: noble)"
  echo "                  Examples: noble, jammy"
  echo "  -v, --version   Version (default: current)"
  echo "                  Example: current"
  echo "  -a, --arch      Architecture (default: amd64)"
  echo "                  Available options: amd64"
  echo "  -u, --user      User (default: panzer1119)"
  echo "  -s, --storage   Proxmox storage ID (default: tn-core-1)"
  echo "  -f, --force     Force re-download of the image"
  echo "  --suffix        Custom image name suffix (default: -custom-docker)"
  echo "  -h, --help      Display this help message"
  exit 1
}

# Check for required packages
check_requirements() {
  local pkg
  for pkg in libguestfs-tools qemu-utils wget curl jq sha256sum pvesh; do
    if ! dpkg -s "${pkg}" &> /dev/null; then
      echo "Error: ${pkg} is not installed. Please install it first."
      exit 1
    fi
  done
}

# Check Proxmox storage
check_proxmox_storage() {
  local storage=$1
  local storage_info storage_path

  storage_info=$(pvesh get /storage/${storage}) || { echo "Error: Storage ID ${storage} does not exist."; exit 1; }

  if ! echo "${storage_info}" | grep -q 'content.*images'; then
    echo "Error: Storage ID ${storage} is not enabled to store images."
    exit 1
  fi

  storage_path=$(echo "${storage_info}" | jq -r '.path')
  if [ -z "${storage_path}" ]; then
    echo "Error: Could not determine storage path for ${storage}."
    exit 1
  fi

  echo "${storage_path}"
}

# Main function
main() {
  # Default values
  local distro="ubuntu"
  local release="noble"
  local version="current"
  local arch="amd64"
  local user="panzer1119"
  local storage="tn-core-1"
  local force_download=false
  local custom_suffix="-custom-docker"

  # Parse options
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--distro)
        distro="$2"
        shift 2
        ;;
      -r|--release)
        release="$2"
        shift 2
        ;;
      -v|--version)
        version="$2"
        shift 2
        ;;
      -a|--arch)
        arch="$2"
        shift 2
        ;;
      -u|--user)
        user="$2"
        shift 2
        ;;
      -s|--storage)
        storage="$2"
        shift 2
        ;;
      -f|--force)
        force_download=true
        shift
        ;;
      --suffix)
        custom_suffix="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Invalid option: $1" >&2
        usage
        ;;
    esac
  done

  # Check for required packages
  check_requirements

  # Check Proxmox storage
  local storage_path
  storage_path=$(check_proxmox_storage "${storage}")

  # Determine the download URL and checksum URL based on options
  local img_url checksum_url checksum_file img_name img_path temp_img custom_img_name custom_img_path expected_checksum existing_checksum

  case ${distro} in
    ubuntu)
      img_url="https://cloud-images.ubuntu.com/${release}/current/${release}-server-cloudimg-${arch}.img"
      checksum_url="https://cloud-images.ubuntu.com/${release}/current/SHA256SUMS"
      checksum_file="SHA256SUMS"
      ;;
    debian)
      img_url="https://cloud.debian.org/images/cloud/OpenStack/current-${release}/debian-${release}-openstack-${arch}.qcow2"
      checksum_url="https://cloud.debian.org/images/cloud/OpenStack/current-${release}/SHA256SUMS"
      checksum_file="SHA256SUMS"
      ;;
    fedora)
      img_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/Fedora-Cloud-Base-${version}.${arch}.qcow2"
      checksum_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/CHECKSUM"
      checksum_file="CHECKSUM"
      ;;
    *)
      echo "Unsupported distribution: ${distro}" >&2
      exit 1
      ;;
  esac

  # Download the checksum file
  wget -O "${checksum_file}" "${checksum_url}"

  # Extract the checksum for the image
  expected_checksum=$(grep $(basename ${img_url}) ${checksum_file} | awk '{ print $1 }')

  # Download the image if not already present or if checksum does not match or force download
  img_name="${distro}-${release}-${version}-${arch}.img"
  img_path="${storage_path}/${img_name}"

  if [ "${force_download}" = true ]; then
    echo "Forcing download of the image."
    wget -O "${img_path}" "${img_url}"
  else
    if [ -f "${img_path}" ]; then
      echo "Image already exists in storage. Checking hash..."
      existing_checksum=$(sha256sum "${img_path}" | awk '{ print $1 }')
      if [ "${existing_checksum}" == "${expected_checksum}" ]; then
        echo "Image checksum matches. Using existing image."
      else
        echo "Image checksum does not match. Downloading new image."
        wget -O "${img_path}" "${img_url}"
      fi
    else
      wget -O "${img_path}" "${img_url}"
    fi
  fi

  # Copy image to temporary folder for customization
  temp_img="/tmp/${img_name}"
  cp "${img_path}" "${temp_img}"

  # Customize the image with virt-customize
  sudo virt-customize -a "${temp_img}" \
    --install qemu-guest-agent,magic-wormhole,zfsutils-linux,ca-certificates,curl,jq,eza,ncdu,rclone,cifs-utils,tree,etckeeper \
    --run-command 'curl -fsSL https://get.docker.com -o get-docker.sh' \
    --run-command 'sh get-docker.sh' \
    --run-command "usermod -aG docker ${user}" \
    --run-command 'rm -f get-docker.sh'

  # Rename and move the customized image back to the storage location
  custom_img_name="${distro}-${release}-${version}-${arch}${custom_suffix}.img"
  custom_img_path="${storage_path}/${custom_img_name}"
  mv "${temp_img}" "${custom_img_path}"

  # Output the final image location
  echo "Customized image saved as ${custom_img_path}"
}

# Call the main function with all the arguments
main "$@"
