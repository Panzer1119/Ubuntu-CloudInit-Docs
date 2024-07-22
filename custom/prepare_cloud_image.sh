#!/bin/bash

# Help function
usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -d, --distro       Distribution (default: ubuntu)"
  echo "                     Available options: ubuntu, debian, fedora"
  echo "  -r, --release      Release (default: noble)"
  echo "                     Used by Ubuntu and Debian only"
  echo "                     Examples:"
  echo "                       - Ubuntu: noble"
  echo "                       - Debian: bookworm"
  echo "  -v, --version      Version (default: 24.04)"
  echo "                     Used by Debian and Fedora only"
  echo "                     Examples:"
  echo "                       - Debian: 12"
  echo "                       - Fedora: 40"
  echo "  -b, --build        Build (default: current)"
  echo "                     Examples:"
  echo "                       - Ubuntu: current"
  echo "                       - Debian: latest"
  echo "                       - Fedora: 1.14"
  echo "  -a, --arch         Architecture (default: amd64)"
  echo "                     Available options: amd64"
  echo "  -u, --user         User (default: panzer1119)"
  echo "  -s, --storage      Proxmox storage ID (default: tn-core-1)"
  echo "  -f, --force        Force re-download of the image"
  echo "  --suffix           Custom image name suffix (default: -custom-docker)"
  echo "  --image-name       Specify an image name to use from storage"
  echo "  --sha256           Specify a SHA256 hash for local image verification"
  echo "  --sha512           Specify a SHA512 hash for local image verification"
  echo "  --influx-url       InfluxDB URL (default: http://monitoring-vm.local.panzer1119.de:8086)"
  echo "  --influx-org       InfluxDB organization (default: Homelab)"
  echo "  --influx-bucket    InfluxDB bucket (default: Telegraf)"
  echo "  --influx-token     InfluxDB token (optional)"
  echo "  --dry-run          Show what would be done without making any changes"
  echo "  -h, --help         Display this help message"
  exit 1
}

# Check for required packages
check_requirements() {
  local commands=("virt-customize" "wget" "curl" "jq" "sha256sum" "pvesh")
  local command
  # Check that they are installed
  for command in "${commands[@]}"; do
    if ! command -v "${command}" &> /dev/null; then
      echo "Error: Command ${command} not found. Please install it first."
      exit 1
    fi
  done
}

# Check Proxmox storage
check_proxmox_storage() {
  local storage=$1
  local storage_info storage_path
  local content_images_enabled=false
  local content_iso_enabled=false
  local storage_has_images_dir=false

  # Get storage info from Proxmox API and store it in a variable
  if ! storage_info=$(sudo pvesh get /storage/${storage} --output-format json); then
    echo "Error: Storage '${storage}' does not exist."
    exit 1
  fi

  # Check if storage is enabled for images and ISOs
#   content_images_enabled=$(echo "${storage_info}" | jq -e '.content | index("images")' &> /dev/null && echo "yes" || echo "no")
  content_images_enabled="no"
  content_iso_enabled=$(echo "${storage_info}" | jq -e '.content | index("iso")' &> /dev/null && echo "yes" || echo "no")

  # Get storage path
  storage_path=$(echo "${storage_info}" | jq -r '.path')
  if [ -z "${storage_path}" ]; then
    echo "Error: Could not determine storage path for ${storage}."
    exit 1
  fi

  # Check if both images and ISOs are disabled
  if [ "${content_images_enabled}" == "no" ] && [ "${content_iso_enabled}" == "no" ]; then
    storage_path="${storage_path}/images"
    # Return the storage path if the directory exists
    if -d "${storage_path}"; then
      echo "${storage_path}"
      return
    fi
    echo "Error: Storage ${storage} is not enabled for images or ISOs and does not have an 'images' directory."
    exit 1
  fi

  # Return the storage path (prefer images over ISOs)
  if [ "${content_images_enabled}" == "yes" ]; then
    echo "${storage_path}/images"
  else
    echo "${storage_path}/template/iso"
  fi
}

# Main function
main() {
  # Default values
  local distro="ubuntu"
  local release=""
  local version=""
  local build=""
  local arch=""
  local user="panzer1119"
  local storage="tn-core-1"
  local force_download=false
  local dry_run=false
  local custom_suffix="-custom-docker"
  local image_name=""
  local sha256_hash=""
  local sha512_hash=""
  local influx_url="http://monitoring-vm.local.panzer1119.de:8086"
  local influx_org="Homelab"
  local influx_bucket="Telegraf"
  local influx_token=""

  # Check for sudo/root permissions
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
  fi

  # Check for required packages
  check_requirements

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
      -b|--build)
        build="$2"
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
      --image-name)
        image_name="$2"
        shift 2
        ;;
      --sha256)
        sha256_hash="$2"
        shift 2
        ;;
      --sha512)
        sha512_hash="$2"
        shift 2
        ;;
      --influx-url)
        influx_url="$2"
        shift 2
        ;;
      --influx-org)
        influx_org="$2"
        shift 2
        ;;
      --influx-bucket)
        influx_bucket="$2"
        shift 2
        ;;
      --influx-token)
        influx_token="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
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

  # Function to execute a command or print it if dry run
  run_command() {
    if [ "${dry_run}" = true ]; then
      echo "[DRY-RUN] $*"
    else
      eval "$@"
    fi
  }

  # Check Proxmox storage
  local storage_path
  storage_path=$(check_proxmox_storage "${storage}")

  # Determine the download URL and checksum URL based on options if image name is not specified
  local img_url checksum_url checksum_file img_path temp_img custom_img_name custom_img_path expected_checksum existing_checksum

  if [ -n "${image_name}" ]; then
    img_path="${storage_path}/${image_name}"
    if [ ! -f "${img_path}" ]; then
      echo "Error: Specified image ${img_path} does not exist in storage."
      exit 1
    fi
  else
    case ${distro} in
      ubuntu)
        # Set default values if not provided
        [ -z "${release}" ] && release="noble"
        [ -z "${version}" ] && version="24.04" # Is not used
        [ -z "${build}" ] && build="current"
        [ -z "${arch}" ] && arch="amd64"
        # Set image URL and checksum URL
        img_url="https://cloud-images.ubuntu.com/${release}/${build}/${release}-server-cloudimg-${arch}.img"
        checksum_url="https://cloud-images.ubuntu.com/${release}/${build}/SHA256SUMS"
        checksum_file="/tmp/SHA256SUMS-Ubuntu-${release}-${build}"
        # If SHA512 hash is provided throw an error as it is not supported
        if [ -n "${sha512_hash}" ]; then
          echo "Error: SHA512 hash is not supported for Ubuntu images."
          exit 1
        fi
        ;;
      debian)
        # Set default values if not provided
        [ -z "${release}" ] && release="bookworm"
        [ -z "${version}" ] && version="12"
        [ -z "${build}" ] && build="latest"
        [ -z "${arch}" ] && arch="amd64"
        # Set image URL and checksum URL
        img_url="https://cloud.debian.org/images/cloud/${release}/${build}/debian-${version}-genericcloud-${arch}.qcow2"
        checksum_url="https://cloud.debian.org/images/cloud/${release}/${build}/SHA512SUMS"
        checksum_file="/tmp/SHA512SUMS-Debian-${release}-${build}"
        # If SHA256 hash is provided throw an error as it is not supported
        if [ -n "${sha256_hash}" ]; then
          echo "Error: SHA256 hash is not supported for Debian images."
          exit 1
        fi
        ;;
      fedora)
        # Set default values if not provided
        release="Cloud" # There are no specific releases for Fedora Cloud
        [ -z "${version}" ] && version="40"
        [ -z "${build}" ] && build="1.14"
        [ -z "${arch}" ] && arch="x86_64"
        # Set image URL and checksum URL
        img_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/Fedora-${release}-Base-Generic.${arch}-${version}-${build}.qcow2"
        checksum_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/Fedora-${release}-${version}-${build}-${arch}-CHECKSUM"
        checksum_file="/tmp/CHECKSUM-Fedora-${release}-${version}-${build}-${arch}"
        # If SHA512 hash is provided throw an error as it is not supported
        if [ -n "${sha512_hash}" ]; then
          echo "Error: SHA512 hash is not supported for Ubuntu images."
          exit 1
        fi
        ;;
      *)
        echo "Unsupported distribution: ${distro}" >&2
        exit 1
        ;;
    esac

    # Download the checksum file if SHA256 and SHA512 hash is not provided
    if [ -z "${sha256_hash}" ] && [ -z "${sha512_hash}" ]; then
      run_command wget -O "${checksum_file}" "${checksum_url}"
      # Get the expected checksum for distros Debian and Ubuntu
      if [ "${distro}" == "debian" ] || [ "${distro}" == "ubuntu" ]; then
        expected_checksum=$(grep $(basename ${img_url}) ${checksum_file} | awk '{ print $1 }')
      elif [ "${distro}" == "fedora" ]; then
        expected_checksum=$(grep $(basename ${img_url}) ${checksum_file} | awk -F' = ' '{print $2}')
      else
        echo "Unsupported distribution: ${distro}" >&2
        exit 1
      fi
      # Delete the checksum file if it was downloaded
      if [ -f "${checksum_file}" ]; then
        run_command rm -f "${checksum_file}"
      fi
    else
      # Select the expected checksum based on the distro
      if [ "${distro}" == "fedora" ] || [ "${distro}" == "ubuntu" ]; then
        expected_checksum="${sha256_hash}"
      elif [ "${distro}" == "debian" ]; then
        expected_checksum="${sha512_hash}"
      else
        echo "Unsupported distribution: ${distro}" >&2
        exit 1
      fi
    fi

    # Download the image if not already present or if checksum does not match or force download
    local img_name="$(basename ${img_url})"
    img_path="${storage_path}/${img_name}"

    if [ "${force_download}" = true ]; then
      echo "Forcing download of the image."
      run_command wget -O "${img_path}" "${img_url}"
    else
      if [ -f "${img_path}" ]; then
        echo "Image already exists in storage. Checking hash..."
        existing_checksum=$(sha256sum "${img_path}" | awk '{ print $1 }')
        if [ "${existing_checksum}" == "${expected_checksum}" ]; then
          echo "Image checksum matches. Using existing image."
        else
          echo "Image checksum does not match. Downloading new image."
          run_command wget -O "${img_path}" "${img_url}"
        fi
      else
        run_command wget -O "${img_path}" "${img_url}"
      fi
    fi
  fi

  # Copy image to temporary folder for customization
  temp_img="/tmp/${img_name}"
  run_command cp "${img_path}" "${temp_img}"

  # Verify telegraf configuration file exists
  if [ ! -f "telegraf.conf" ]; then
    echo "Error: telegraf.conf file not found."
    exit 1
  fi

  # Customize the image
  custom_img_name="$(basename "${img_path%.*}${custom_suffix}.${img_path##*.}")"
  custom_img_path="${storage_path}/${custom_img_name}"
  # If the command fails, delete the temporary image and exit
  #FIXME this command has problems with run_command
  if ! run_command virt-customize -a "${temp_img}" \
    --install qemu-guest-agent,magic-wormhole,zfsutils-linux,ca-certificates,curl,jq,eza,ncdu,rclone,cifs-utils,tree,etckeeper \
    --run-command "curl -fsSL https://get.docker.com -o get-docker.sh" \
    --run-command "sh get-docker.sh" \
    --run-command 'curl -s https://repos.influxdata.com/influxdata-archive.key > /tmp/influxdata-archive.key' \
    --run-command 'echo "943666881a1b8d9b849b74caebf02d3465d6beb716510d86a39f6c8e8dac7515 /tmp/influxdata-archive.key" | sha256sum -c' \
    --run-command 'cat /tmp/influxdata-archive.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/influxdata-archive.gpg > /dev/null' \
    --run-command 'echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" | tee /etc/apt/sources.list.d/influxdata.list' \
    --run-command 'apt-get update && apt-get install -y telegraf' \
    --copy-in "telegraf.conf:/etc/telegraf/telegraf.conf" \
    --run-command "echo 'INFLUX_URL=${influx_url}' >> /etc/environment" \
    --run-command "echo 'INFLUX_ORG=${influx_org}' >> /etc/environment" \
    --run-command "echo 'INFLUX_BUCKET=${influx_bucket}' >> /etc/environment" \
    --run-command "echo 'INFLUX_TOKEN=${influx_token}' >> /etc/environment" \
    --run-command "echo -n > /etc/machine-id"; then
    echo "Error: Failed to customize the image."
    run_command rm -f "${temp_img}"
    exit 1
  fi

  # Move customized image to storage
  run_command mv "${temp_img}" "${custom_img_path}"
  echo "Customized image saved to ${custom_img_path}"
}

main "$@"
