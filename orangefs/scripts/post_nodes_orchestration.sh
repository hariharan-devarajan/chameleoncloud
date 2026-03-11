#!/bin/bash
# post_nodes_orchestration.sh - Post-node discovery and orchestration script
# Runs on login node to orchestrate NFS mounts and OrangeFS deployment across cluster
# All configuration passed via explicit function arguments or config file
set -eu

# Source common logging library first
source "${SCRIPT_ROOT}/orangefs/scripts/lib/logging.sh"

# Enable trace mode if LOG_LEVEL=TRACE
enable_trace_mode

# ============================================================================
# Configuration
# ============================================================================
DEFAULT_OPENSTACK_TIMEOUT_SECONDS="1800"
DEFAULT_MOUNT_SSH_TIMEOUT_SECONDS="1800"
DEFAULT_MAX_WAIT_ATTEMPTS="60"
DEFAULT_WAIT_SLEEP_SECONDS="10"
DEFAULT_TARGET_USER="cc"
DEFAULT_NFS_MOUNT_POINT="/opt/nfs_client"
DEFAULT_SSH_USER="cc"
DEFAULT_ORANGEFS_DATA_DIR="/mnt/nvme/orangefs_data"
DEFAULT_ORANGEFS_METADATA_DIR="/mnt/nvme/orangefs_metadata"
DEFAULT_ORANGEFS_MOUNT_DIR="/mnt/orangefs"
DEFAULT_ORANGEFS_LOG_DIR="/opt/orangefs/logs"
DEFAULT_SCRIPT_ROOT=$(cd "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")" && pwd)

# ============================================================================
# Function: Initialize Post-Nodes Logging and Environment
# ============================================================================
initialize_post_nodes_environment() {
  # Create runtime and logging directories
  mkdir -p /var/run/datacrumbs
  mkdir -p /var/log/datacrumbs
  chmod 755 /var/run/datacrumbs
  chmod 755 /var/log/datacrumbs

  local log_file="/var/log/datacrumbs/post-nodes.log"

  touch "$log_file"
  chmod 644 "$log_file"
  exec > >(tee -a "$log_file") 2>&1

  log_info "Post-nodes orchestration logging initialized"
  log_debug "Log file: ${log_file}"
  log_debug "Runtime directory: /var/run/datacrumbs"
}

# ============================================================================
# Function: Write Post-Nodes Environment to File
# ============================================================================
write_post_nodes_environment_file() {
  local env_file="/var/run/datacrumbs/post_nodes.env"
  local stack_name="$1"
  local compute_count="$2"
  local storage_count="$3"
  local openstack_timeout="$4"
  local mount_ssh_timeout="$5"
  local nfs_mount_point="$6"
  local target_user="$7"
  local log_level="$8"
  local orangefs_data_dir="$9"
  local orangefs_metadata_dir="${10}"
  local orangefs_mount_dir="${11}"
  local orangefs_log_dir="${12}"
  local script_root="${13}"

  {
    echo "# Post-Nodes Orchestration Environment Variables"
    echo "# Generated: $(date -Is)"
    echo ""
    echo "export STACK_NAME=\"${stack_name}\""
    echo "export COMPUTE_COUNT=\"${compute_count}\""
    echo "export STORAGE_COUNT=\"${storage_count}\""
    echo ""
    echo "# Timeouts"
    echo "export OPENSTACK_TIMEOUT_SECONDS=\"${openstack_timeout}\""
    echo "export MOUNT_SSH_TIMEOUT_SECONDS=\"${mount_ssh_timeout}\""
    echo ""
    echo "# Paths"
    echo "export NFS_MOUNT_POINT=\"${nfs_mount_point}\""
    echo "export TARGET_USER=\"${target_user}\""
    echo "export ORANGEFS_DATA_DIR=\"${orangefs_data_dir}\""
    echo "export ORANGEFS_METADATA_DIR=\"${orangefs_metadata_dir}\""
    echo "export ORANGEFS_MOUNT_DIR=\"${orangefs_mount_dir}\""
    echo "export ORANGEFS_LOG_DIR=\"${orangefs_log_dir}\""
    echo ""
    echo "# Logging"
    echo "export LOG_LEVEL=\"${log_level}\""
    echo "export LOG_DIR=\"/var/log/datacrumbs\""
    echo "export RUNTIME_DIR=\"/var/run/datacrumbs\""
    echo ""
    echo "# Script Root"
    echo "export SCRIPT_ROOT=\"${script_root}\""
  } > "$env_file"

  chmod 600 "$env_file"
  log_info "Post-nodes environment variables written to ${env_file}"
}

# ============================================================================
# Function: Load Post-Nodes Environment Configuration
# ============================================================================
load_post_nodes_env() {
  local env_file="${1:-/var/run/datacrumbs/post_nodes.env}"
  local openstack_timeout="${2:-${DEFAULT_OPENSTACK_TIMEOUT_SECONDS}}"
  local mount_ssh_timeout="${3:-${DEFAULT_MOUNT_SSH_TIMEOUT_SECONDS}}"

  if [ ! -f "$env_file" ]; then
    log_error "Post-nodes environment file not found: ${env_file}"
    return 1
  fi

  source "$env_file"

  # Set OpenStack credentials
  export OS_AUTH_TYPE="${OS_AUTH_TYPE:-}"
  export OS_AUTH_URL="${OS_AUTH_URL:-}"
  export OS_IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-}"
  export OS_REGION_NAME="${OS_REGION_NAME:-}"
  export OS_INTERFACE="${OS_INTERFACE:-}"
  export OS_APPLICATION_CREDENTIAL_ID="${OS_APPLICATION_CREDENTIAL_ID:-}"
  export OS_APPLICATION_CREDENTIAL_SECRET="${OS_APPLICATION_CREDENTIAL_SECRET:-}"

  log_info "Post-nodes environment loaded from ${env_file}"
  log_debug "Stack: ${STACK_NAME}, Compute: ${COMPUTE_COUNT}, Storage: ${STORAGE_COUNT}"
}

# ============================================================================
# Function: Install OpenStack CLI if Needed
# ============================================================================
ensure_openstack_cli() {
  if command -v openstack >/dev/null 2>&1; then
    log_debug "OpenStack CLI already installed"
    return 0
  fi

  log_info "Installing OpenStack CLI (python3-openstackclient)"
  timeout 600 bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update'
  timeout 600 bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient'
  log_info "OpenStack CLI installed"
}

# ============================================================================
# Function: Wait for All Nodes to be Ready
# ============================================================================
# Args: stack_name, compute_count, storage_count, openstack_timeout_seconds,
#       max_attempts, sleep_seconds, nfs_mount_point
wait_for_nodes_ready() {
  local stack_name="$1"
  local compute_count="$2"
  local storage_count="$3"
  local openstack_timeout="${4:-${DEFAULT_OPENSTACK_TIMEOUT_SECONDS}}"
  local max_attempts="${5:-${DEFAULT_MAX_WAIT_ATTEMPTS}}"
  local sleep_seconds="${6:-${DEFAULT_WAIT_SLEEP_SECONDS}}"
  local nfs_mount_point="${7:-${DEFAULT_NFS_MOUNT_POINT}}"

  local attempt
  local server_list_file="/tmp/server_list.json"

  log_info "Waiting for all nodes to be ACTIVE..."

  for attempt in $(seq 1 "$max_attempts"); do
    log_info "Checking node readiness from OpenStack (attempt ${attempt}/${max_attempts})"

    if timeout "$openstack_timeout" openstack server list -f json -c Name -c Status -c Networks >"$server_list_file"; then
      python3 - "$server_list_file" "$stack_name" "$compute_count" "$storage_count" "$nfs_mount_point" <<'PY'
import json
import re
import sys
import os

server_list_file = sys.argv[1]
stack_name = sys.argv[2]
compute_count = int(sys.argv[3])
storage_count = int(sys.argv[4])
nfs_mount_point = sys.argv[5]

def extract_ipv4(value):
    text = value if isinstance(value, str) else str(value)
    matches = re.findall(r'(?:\d{1,3}\.){3}\d{1,3}', text)
    for ip in matches:
        if ip.startswith('10.'):
            return ip
    return ''

with open(server_list_file, 'r', encoding='utf-8') as file_obj:
    rows = json.load(file_obj)

compute_ips = []
storage_ips = []
login_ip = ''

for row in rows:
    name = str(row.get('Name', ''))
    status = str(row.get('Status', ''))
    if status != 'ACTIVE':
        continue

    ip = extract_ipv4(row.get('Networks', ''))
    if not ip:
        continue

    if name.startswith(f"{stack_name}-compute_nodes-"):
        compute_ips.append(ip)
    elif name.startswith(f"{stack_name}-storage_nodes-"):
        storage_ips.append(ip)
    elif name.startswith(f"{stack_name}-login_node-") and not login_ip:
        login_ip = ip

compute_ips = sorted(set(compute_ips))[:compute_count]
storage_ips = sorted(set(storage_ips))[:storage_count]

with open(f'{nfs_mount_point}/compute_nodes.txt', 'w', encoding='utf-8') as file_obj:
    file_obj.write('\n'.join(compute_ips) + ('\n' if compute_ips else ''))

with open(f'{nfs_mount_point}/storage_nodes.txt', 'w', encoding='utf-8') as file_obj:
    file_obj.write('\n'.join(storage_ips) + ('\n' if storage_ips else ''))

with open(f'{nfs_mount_point}/login_node.txt', 'w', encoding='utf-8') as file_obj:
    file_obj.write((login_ip + '\n') if login_ip else '')
PY

      FOUND_COMPUTE="$(wc -l <${nfs_mount_point}/compute_nodes.txt | tr -d ' ')"
      FOUND_STORAGE="$(wc -l <${nfs_mount_point}/storage_nodes.txt | tr -d ' ')"
      LOGIN_IP="$(head -n1 ${nfs_mount_point}/login_node.txt || true)"

      log_info "Found compute nodes: ${FOUND_COMPUTE}/${compute_count}"
      log_info "Found storage nodes: ${FOUND_STORAGE}/${storage_count}"
      log_debug "Resolved login IP: ${LOGIN_IP:-<missing>}"

      if [ "$FOUND_COMPUTE" -ge "$compute_count" ] && [ "$FOUND_STORAGE" -ge "$storage_count" ] && [ -n "$LOGIN_IP" ]; then
        cat ${nfs_mount_point}/compute_nodes.txt ${nfs_mount_point}/storage_nodes.txt | sed '/^$/d' | sort -u >${nfs_mount_point}/all_nodes.txt
        log_info "All required nodes discovered and listed in ${nfs_mount_point}/all_nodes.txt"
        chown cc:cc ${nfs_mount_point}/*.txt
        chmod 666 ${nfs_mount_point}/*.txt
        return 0
      fi
    else
      log_warning "OpenStack server list call failed on attempt ${attempt}"
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$sleep_seconds"
    fi
  done

  log_error "Timed out waiting for all nodes to become ACTIVE"
  return 1
}

# ============================================================================
# Function: Setup Client Mount on Remote Node
# ============================================================================
# Args: ip, login_ip, mount_ssh_timeout_seconds, nfs_mount_point, target_user
setup_client_mount() {
  local ip="$1"
  local login_ip="$2"
  local mount_ssh_timeout="${3:-${DEFAULT_MOUNT_SSH_TIMEOUT_SECONDS}}"
  local nfs_mount_point="${4:-${DEFAULT_NFS_MOUNT_POINT}}"
  local target_user="${5:-${DEFAULT_TARGET_USER}}"
  local max_attempts="10"
  local retry_interval_seconds="60"
  local attempt
  local ok="0"

  log_debug "Setting up NFS client mount on ${ip}"

  for attempt in $(seq 1 "$max_attempts"); do
    log_info "Configuring mount on client ${ip} (attempt ${attempt}/${max_attempts})"

    if timeout "$mount_ssh_timeout" ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
      -o ConnectionAttempts=1 -o BatchMode=yes \
      "${target_user}@${ip}" "sudo bash -lc '
        mkdir -p ${nfs_mount_point} /mnt/orangefs /mnt/nvme/orangefs_{data,metadata}
        grep -q \"${login_ip}:${nfs_mount_point}\" /etc/fstab || \
          echo \"${login_ip}:/opt/shared    ${nfs_mount_point}    nfs defaults,_netdev 0 0\" >> /etc/fstab
        mount -a || true
        mountpoint -q ${nfs_mount_point}
      '"; then
      ok="1"
      break
    fi

    log_warning "Mount configuration attempt ${attempt}/${max_attempts} failed for ${ip}; retrying in ${retry_interval_seconds}s"
    sleep "$retry_interval_seconds"
  done

  if [ "$ok" = "0" ]; then
    log_error "Failed to configure mount on client ${ip}"
    return 1
  fi

  log_info "NFS client mount configured on ${ip}"
  return 0
}

# ============================================================================
# Function: Configure All Client Mounts
# ============================================================================
# Args: all_nodes_file, login_ip, mount_ssh_timeout, nfs_mount_point, target_user
configure_all_client_mounts() {
  local all_nodes_file="$1"
  local login_ip="$2"
  local mount_ssh_timeout="${3:-${DEFAULT_MOUNT_SSH_TIMEOUT_SECONDS}}"
  local nfs_mount_point="${4:-${DEFAULT_NFS_MOUNT_POINT}}"
  local target_user="${5:-${DEFAULT_TARGET_USER}}"
  local ip

  log_info "Configuring NFS client mounts on all nodes"

  while IFS= read -r ip; do
    [ -n "$ip" ] && setup_client_mount "$ip" "$login_ip" "$mount_ssh_timeout" "$nfs_mount_point" "$target_user"
  done < "$all_nodes_file"

  log_info "All client mounts configured"
}

# ============================================================================
# Function: Main Post-Nodes Orchestration
# ============================================================================
# Args: stack_name, compute_count, storage_count, openstack_timeout, mount_ssh_timeout,
#       nfs_mount_point, target_user, log_level, orangefs_data_dir, orangefs_metadata_dir,
#       orangefs_mount_dir, orangefs_log_dir
main_post_nodes_orchestration() {
  local stack_name="$1"
  local compute_count="$2"
  local storage_count="$3"
  local openstack_timeout="${4:-${DEFAULT_OPENSTACK_TIMEOUT_SECONDS}}"
  local mount_ssh_timeout="${5:-${DEFAULT_MOUNT_SSH_TIMEOUT_SECONDS}}"
  local nfs_mount_point="${6:-${DEFAULT_NFS_MOUNT_POINT}}"
  local target_user="${7:-${DEFAULT_TARGET_USER}}"
  local log_level="${8:-INFO}"
  local orangefs_data_dir="${9:-${DEFAULT_ORANGEFS_DATA_DIR}}"
  local orangefs_metadata_dir="${10:-${DEFAULT_ORANGEFS_METADATA_DIR}}"
  local orangefs_mount_dir="${11:-${DEFAULT_ORANGEFS_MOUNT_DIR}}"
  local orangefs_log_dir="${12:-${DEFAULT_ORANGEFS_LOG_DIR}}"
  local orangefs_version="2.10.0"
  local orangefs_prefix="${nfs_mount_point}/orangefs/${orangefs_version}"
  local orangefs_config_file="${nfs_mount_point}/orangefs.conf"
  local orangefs_server_list="${nfs_mount_point}/orangefs_server_list.txt"
  local orangefs_client_list="${nfs_mount_point}/orangefs_client_list.txt"
  local script_root="${SCRIPT_ROOT:-${DEFAULT_SCRIPT_ROOT}}"


  # Set LOG_LEVEL for this and all child scripts
  export LOG_LEVEL="$log_level"

  log_info "==============================================="
  log_info "Post-Nodes Orchestration Started"
  log_info "Stack: ${stack_name}"
  log_info "Expected Compute: ${compute_count}, Storage: ${storage_count}"
  log_info "==============================================="

  # Source function libraries
  source "${script_root}/orangefs/scripts/lib/nfs_functions.sh"
  source "${script_root}/orangefs/scripts/lib/directory_structures.sh"
  source "${script_root}/orangefs/scripts/lib/orangefs_functions.sh"

  # Ensure directories exist
  mkdir -p "$nfs_mount_point"
  : > "${nfs_mount_point}/all_nodes.txt"
  : > "${nfs_mount_point}/compute_nodes.txt"
  : > "${nfs_mount_point}/storage_nodes.txt"
  : > "${nfs_mount_point}/login_node.txt"
  chown "$target_user:$target_user" "${nfs_mount_point}"/*.txt 2>/dev/null || true
  chmod 777 "${nfs_mount_point}"/*.txt 2>/dev/null || true
  log_debug "Node list files prepared"

  # Install OpenStack CLI
  ensure_openstack_cli

  # Wait for all nodes to  be ready
  if ! wait_for_nodes_ready "$stack_name" "$compute_count" "$storage_count" \
    "$openstack_timeout" "${DEFAULT_MAX_WAIT_ATTEMPTS}" "${DEFAULT_WAIT_SLEEP_SECONDS}" \
    "$nfs_mount_point"; then
    log_error "Failed to discover all nodes from OpenStack"
    return 1
  fi

  # Get login IP from file
  local login_ip
  login_ip="$(head -n1 ${nfs_mount_point}/login_node.txt || true)"
  if [ -z "$login_ip" ]; then
    log_error "Could not determine login node IP"
    return 1
  fi

  # Configure all client mounts
  if ! configure_all_client_mounts "${nfs_mount_point}/all_nodes.txt" \
    "$login_ip" "$mount_ssh_timeout" "$nfs_mount_point" "$target_user"; then
    log_error "Failed to configure all client mounts"
    return 1
  fi

  # Configure cluster hosts resolution
  log_info "Configuring cluster hosts resolution"
  configure_cluster_hosts_resolution \
    "${nfs_mount_point}/all_nodes.txt" \
    "$target_user" \
    "${nfs_mount_point}/login_node.txt" \
    "${nfs_mount_point}/compute_nodes.txt" \
    "${nfs_mount_point}/storage_nodes.txt"

  # Prepare OrangeFS runtime on login node
  log_info "Preparing OrangeFS installation and deployment assets"
  #   install_orangefs_dependencies
  #   install_orangefs "${orangefs_version}" "${orangefs_prefix}"
  setup_orangefs_module "${orangefs_version}" "${orangefs_prefix}" "${nfs_mount_point}"
  install_parallel_ssh
  install_expect_package
  configure_orangefs_firewall
  setup_orangefs_directories \
    "$target_user" \
    "$orangefs_data_dir" \
    "$orangefs_metadata_dir" \
    "$orangefs_mount_dir" \
    "$orangefs_log_dir"

  log_info "Generating OrangeFS node lists and configuration"
  if ! sudo -u "$target_user" env \
    SCRIPT_ROOT="$script_root" \
    LOG_LEVEL="$log_level" \
    NFS_MOUNT_POINT="$nfs_mount_point" \
    TARGET_USER="$target_user" \
    ORANGEFS_PREFIX="$orangefs_prefix" \
    ORANGEFS_CONFIG_FILE="$orangefs_config_file" \
    ORANGEFS_SERVER_LIST="$orangefs_server_list" \
    ORANGEFS_CLIENT_LIST="$orangefs_client_list" \
    ORANGEFS_DATA_DIR="$orangefs_data_dir" \
    ORANGEFS_METADATA_DIR="$orangefs_metadata_dir" \
    ORANGEFS_MOUNT_DIR="$orangefs_mount_dir" \
    ORANGEFS_LOG_DIR="$orangefs_log_dir" \
    bash -lc '
      source "${SCRIPT_ROOT}/orangefs/scripts/lib/logging.sh"
      source "${SCRIPT_ROOT}/orangefs/scripts/lib/orangefs_functions.sh"
      create_orangefs_node_lists \
        "${NFS_MOUNT_POINT}/storage_nodes.txt" \
        "${NFS_MOUNT_POINT}/all_nodes.txt" \
        "${ORANGEFS_SERVER_LIST}" \
        "${ORANGEFS_CLIENT_LIST}" \
        "${NFS_MOUNT_POINT}/login_node.txt" \
        "${TARGET_USER}"
      generate_orangefs_config_expect \
        "${NFS_MOUNT_POINT}/storage_nodes.txt" \
        "${ORANGEFS_CONFIG_FILE}" \
        "${ORANGEFS_PREFIX}" \
        "${ORANGEFS_DATA_DIR}" \
        "${ORANGEFS_METADATA_DIR}" \
        "3334" \
        "orangefs" \
        "${ORANGEFS_LOG_DIR}/orangefs.log"
      deploy_orangefs_cluster \
        "${ORANGEFS_SERVER_LIST}" \
        "${ORANGEFS_CLIENT_LIST}" \
        "${ORANGEFS_CONFIG_FILE}" \
        "${ORANGEFS_MOUNT_DIR}" \
        "3334" \
        "${ORANGEFS_PREFIX}" \
        "${SCRIPT_ROOT}"
    '; then
    log_error "OrangeFS deployment failed"
    return 1
  fi

  log_info "==============================================="
  log_info "Post-Nodes Orchestration Completed Successfully"
  log_info "==============================================="
  log_info "All nodes are up with IPs and NFS mounts configured"
  log_info "OrangeFS deployment completed"
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
  # Load configuration from environment file
  local env_file="${1:-/var/run/datacrumbs/post_nodes.env}"
  local stack_name="${STACK_NAME:-}"
  local compute_count="${COMPUTE_COUNT:-0}"
  local storage_count="${STORAGE_COUNT:-0}"
  local openstack_timeout="${OPENSTACK_TIMEOUT_SECONDS:-${DEFAULT_OPENSTACK_TIMEOUT_SECONDS}}"
  local mount_ssh_timeout="${MOUNT_SSH_TIMEOUT_SECONDS:-${DEFAULT_MOUNT_SSH_TIMEOUT_SECONDS}}"
  local nfs_mount_point="${NFS_MOUNT_POINT:-${DEFAULT_NFS_MOUNT_POINT}}"
  local target_user="${TARGET_USER:-${DEFAULT_TARGET_USER}}"
  local log_level="${LOG_LEVEL:-INFO}"
  local orangefs_data_dir="${ORANGEFS_DATA_DIR:-${DEFAULT_ORANGEFS_DATA_DIR}}"
  local orangefs_metadata_dir="${ORANGEFS_METADATA_DIR:-${DEFAULT_ORANGEFS_METADATA_DIR}}"
  local orangefs_mount_dir="${ORANGEFS_MOUNT_DIR:-${DEFAULT_ORANGEFS_MOUNT_DIR}}"
  local orangefs_log_dir="${ORANGEFS_LOG_DIR:-${DEFAULT_ORANGEFS_LOG_DIR}}"
  local script_root="${SCRIPT_ROOT:-${DEFAULT_SCRIPT_ROOT}}"

  # Initialize logging and environment
  initialize_post_nodes_environment

  # Write environment to file for recovery/debugging
  write_post_nodes_environment_file \
    "$stack_name" \
    "$compute_count" \
    "$storage_count" \
    "$openstack_timeout" \
    "$mount_ssh_timeout" \
    "$nfs_mount_point" \
    "$target_user" \
    "$log_level" \
    "$orangefs_data_dir" \
    "$orangefs_metadata_dir" \
    "$orangefs_mount_dir" \
    "$orangefs_log_dir" \
    "$script_root"

  # Load environment if not already sourced
  if [ -z "$stack_name" ] || [ ! -f "$env_file" ]; then
    load_post_nodes_env "$env_file"
    stack_name="${STACK_NAME:-}"
    compute_count="${COMPUTE_COUNT:-0}"
    storage_count="${STORAGE_COUNT:-0}"
  fi

  # Validate configuration
  if [ -z "$stack_name" ]; then
    log_error "STACK_NAME not configured"
    return 1
  fi

  # Execute post-nodes orchestration
  main_post_nodes_orchestration \
    "$stack_name" \
    "$compute_count" \
    "$storage_count" \
    "$openstack_timeout" \
    "$mount_ssh_timeout" \
    "$nfs_mount_point" \
    "$target_user" \
    "$log_level" \
    "$orangefs_data_dir" \
    "$orangefs_metadata_dir" \
    "$orangefs_mount_dir" \
    "$orangefs_log_dir"
}

# Run the main function
main "$@"
