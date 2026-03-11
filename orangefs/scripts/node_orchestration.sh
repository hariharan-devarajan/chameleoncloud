#!/bin/bash
# node_orchestration.sh - Top-level orchestration script for all node types
# All configuration passed via explicit function arguments, no env var dependencies
set -eu

# Source common logging library first
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_ROOT}/lib/logging.sh"

# Enable trace mode if LOG_LEVEL=TRACE
enable_trace_mode

# ============================================================================
# Configuration and Variables
# ============================================================================

# Default values
DEFAULT_TARGET_USER="cc"
DEFAULT_NFS_MOUNT_POINT="/opt/nfs_client"
DEFAULT_NFS_EXPORT_DIR="/opt/shared"
DEFAULT_ORANGEFS_DATA_DIR="/mnt/nvme/orangefs_data"
DEFAULT_ORANGEFS_METADATA_DIR="/mnt/nvme/orangefs_metadata"
DEFAULT_ORANGEFS_MOUNT_DIR="/mnt/orangefs"
DEFAULT_ORANGEFS_LOG_DIR="/opt/orangefs/logs"

# ============================================================================
# Function: Setup Bootstrap Environment and Logging
# ============================================================================
setup_bootstrap_environment() {
  local role="$1"
  
  # Create runtime and logging directories
  mkdir -p /var/run/datacrumbs
  mkdir -p /var/log/datacrumbs
  chmod 755 /var/run/datacrumbs
  chmod 755 /var/log/datacrumbs

  local log_file="/var/log/datacrumbs/bootstrap-${role}.log"

  touch "$log_file"
  chmod 644 "$log_file"
  exec > >(tee -a "$log_file") 2>&1

  log_info "Bootstrap logging initialized for role ${role}"
  log_debug "Log file: ${log_file}"
  log_debug "Runtime directory: /var/run/datacrumbs"
}

# ============================================================================
# Function: Write Node Environment to File
# ============================================================================
write_node_environment_file() {
  local env_file="/var/run/datacrumbs/node_orchestration.env"
  local node_role="$1"
  local target_user="$2"
  local public_key="$3"
  local private_key="$4"
  local is_login_node="$5"
  local is_compute_node="$6"
  local is_storage_node="$7"
  local nfs_server_ip="$8"
  local nfs_mount_point="$9"
  local nfs_export_dir="${10}"
  local orangefs_data_dir="${11}"
  local orangefs_metadata_dir="${12}"
  local orangefs_mount_dir="${13}"
  local orangefs_log_dir="${14}"
  local stack_name="${15}"
  local compute_count="${16}"
  local storage_count="${17}"
  local os_auth_type="${18}"
  local os_auth_url="${19}"
  local os_identity_api_version="${20}"
  local os_region_name="${21}"
  local os_interface="${22}"
  local os_app_cred_id="${23}"
  local os_app_cred_secret="${24}"
  local script_root="${25}"
  local log_level="${26}"

  {
    echo "# Node Orchestration Environment Variables"
    echo "# Generated: $(date -Is)"
    echo ""
    echo "NODE_ROLE=\"${node_role}\""
    echo "TARGET_USER=\"${target_user}\""
    echo "IS_LOGIN_NODE=\"${is_login_node}\""
    echo "IS_COMPUTE_NODE=\"${is_compute_node}\""
    echo "IS_STORAGE_NODE=\"${is_storage_node}\""
    echo ""
    echo "# Logging"
    echo "LOG_LEVEL=\"${log_level}\""
    echo ""
    echo "# SSH Configuration"
    echo "PUBLIC_KEY_SET=\"$([ -n \"${public_key}\" ] && echo 'yes' || echo 'no')\""
    echo "PRIVATE_KEY_SET=\"$([ -n \"${private_key}\" ] && echo 'yes' || echo 'no')\""
    echo ""
    echo "# NFS Configuration"
    echo "NFS_SERVER_IP=\"${nfs_server_ip}\""
    echo "NFS_MOUNT_POINT=\"${nfs_mount_point}\""
    echo "NFS_EXPORT_DIR=\"${nfs_export_dir}\""
    echo ""
    echo "# OrangeFS Configuration"
    echo "ORANGEFS_DATA_DIR=\"${orangefs_data_dir}\""
    echo "ORANGEFS_METADATA_DIR=\"${orangefs_metadata_dir}\""
    echo "ORANGEFS_MOUNT_DIR=\"${orangefs_mount_dir}\""
    echo "ORANGEFS_LOG_DIR=\"${orangefs_log_dir}\""
    echo ""
    echo "# Stack Configuration"
    echo "STACK_NAME=\"${stack_name}\""
    echo "COMPUTE_COUNT=\"${compute_count}\""
    echo "STORAGE_COUNT=\"${storage_count}\""
    echo ""
    echo "# OpenStack Credentials"
    echo "OS_AUTH_TYPE=\"${os_auth_type}\""
    echo "OS_AUTH_URL=\"${os_auth_url}\""
    echo "OS_IDENTITY_API_VERSION=\"${os_identity_api_version}\""
    echo "OS_REGION_NAME=\"${os_region_name}\""
    echo "OS_INTERFACE=\"${os_interface}\""
    echo "OS_APPLICATION_CREDENTIAL_ID_SET=\"$([ -n \"${os_app_cred_id}\" ] && echo 'yes' || echo 'no')\""
    echo "OS_APPLICATION_CREDENTIAL_SECRET_SET=\"$([ -n \"${os_app_cred_secret}\" ] && echo 'yes' || echo 'no')\""
    echo ""
    echo "# Script Paths"
    echo "SCRIPT_ROOT=\"${script_root}\""
  } > "$env_file"
  
  chmod 600 "$env_file"
  log_info "Node environment variables written to ${env_file}"
}

# ============================================================================
# Function: Main Node Orchestration
# ============================================================================
# Args: node_role, target_user, public_key, private_key, is_login_node, is_compute_node, is_storage_node,
#       nfs_server_ip, nfs_mount_point, nfs_export_dir,
#       orangefs_data_dir, orangefs_metadata_dir, orangefs_mount_dir, orangefs_log_dir,
#       stack_name, compute_count, storage_count,
#       os_auth_type, os_auth_url, os_identity_api_version, os_region_name, os_interface,
#       os_app_cred_id, os_app_cred_secret,
#       script_root, log_level
orchestrate_node_setup() {
  local node_role="$1"
  local target_user="$2"
  local public_key="$3"
  local private_key="$4"
  local is_login_node="$5"
  local is_compute_node="$6"
  local is_storage_node="$7"
  local nfs_server_ip="$8"
  local nfs_mount_point="${9:-.}"
  local nfs_export_dir="${10:-.}"
  local orangefs_data_dir="${11:-.}"
  local orangefs_metadata_dir="${12:-.}"
  local orangefs_mount_dir="${13:-.}"
  local orangefs_log_dir="${14:-.}"
  local stack_name="${15:-}"
  local compute_count="${16:-0}"
  local storage_count="${17:-0}"
  local os_auth_type="${18:-}"
  local os_auth_url="${19:-}"
  local os_identity_api_version="${20:-}"
  local os_region_name="${21:-}"
  local os_interface="${22:-}"
  local os_app_cred_id="${23:-}"
  local os_app_cred_secret="${24:-}"
  local script_root="${25:-.}"
  local log_level="${26:-INFO}"

  # Set defaults if not provided
  : "${nfs_mount_point:=${DEFAULT_NFS_MOUNT_POINT}}"
  : "${nfs_export_dir:=${DEFAULT_NFS_EXPORT_DIR}}"
  : "${orangefs_data_dir:=${DEFAULT_ORANGEFS_DATA_DIR}}"
  : "${orangefs_metadata_dir:=${DEFAULT_ORANGEFS_METADATA_DIR}}"
  : "${orangefs_mount_dir:=${DEFAULT_ORANGEFS_MOUNT_DIR}}"
  : "${orangefs_log_dir:=${DEFAULT_ORANGEFS_LOG_DIR}}"

  # Set LOG_LEVEL for this and all child scripts
  export LOG_LEVEL="$log_level"

  log_startup_info "node_orchestration.sh"
  log_info "==============================================="
  log_info "Node Orchestration Started"
  log_info "Role: ${node_role}"
  log_info "Target User: ${target_user}"
  log_info "Is Login: ${is_login_node}, Is Compute: ${is_compute_node}, Is Storage: ${is_storage_node}"
  log_info "NFS Mount: ${nfs_mount_point}"
  log_info "OrangeFS Data: ${orangefs_data_dir}"
  log_info "==============================================="

  # Source function libraries
  source "${script_root}/lib/logging.sh"
  source "${script_root}/lib/key_setup.sh"
  source "${script_root}/lib/directory_structures.sh"
  source "${script_root}/lib/nfs_functions.sh"
  source "${script_root}/lib/orangefs_functions.sh"

  # ========================================================================
  # Stage 1: System Updates
  # ========================================================================
  log_info "Stage 1: System Updates"
  DEBIAN_FRONTEND=noninteractive apt-get update
  log_debug "System packages updated"

  # ========================================================================
  # Stage 2: Setup SSH Keys and Directory Structure
  # ========================================================================
  log_info "Stage 2: SSH Keys and Directory Setup"
  setup_ssh_keys_multi "$public_key" "$private_key" "$target_user,root"
  setup_all_directories "$target_user" "$nfs_mount_point" "$nfs_export_dir" \
    "$orangefs_data_dir" "$orangefs_metadata_dir" "$orangefs_mount_dir" "$orangefs_log_dir" \
    "/var/log/datacrumbs"
  log_info "SSH keys and directories configured"

  # ========================================================================
  # Stage 3: Install Base NFS Client
  # ========================================================================
  log_info "Stage 3: Install Base NFS Packages"
  install_nfs_client_packages
  log_info "NFS client packages installed"

  # ========================================================================
  # Stage 4: NFS Server Setup (Login Node Only)
  # ========================================================================
  if [ "$is_login_node" = "1" ]; then
    log_info "Stage 4: NFS Server Setup (Login Node)"
    install_nfs_server_packages
    setup_nfs_server "$nfs_export_dir" "$target_user" "10.0.0.0/8"
    configure_nfs_firewall
    log_info "NFS server configured and running"

    # Prepare for post-nodes processing
    write_post_nodes_env "/etc/datacrumbs-post.env" \
      "$stack_name" "$compute_count" "$storage_count" \
      "$os_auth_type" "$os_auth_url" "$os_identity_api_version" \
      "$os_region_name" "$os_interface" "$os_app_cred_id" "$os_app_cred_secret"
    prepare_post_nodes_logging

    # Start post-nodes script in background
    chmod +x "${script_root}/datacrumbs-post-nodes.sh"
    nohup bash "${script_root}/datacrumbs-post-nodes.sh" >> /var/log/datacrumbs-post-nodes-launch.log 2>&1 &
    log_info "Post-nodes processing script started in background"

    # Use local shared mount as NFS mount point on login node
    link_login_shared_mount "$nfs_mount_point" "$nfs_export_dir"
    resolved_nfs_server_ip="$(resolve_nfs_server_ip)"
  else
    log_info "Stage 4: Skipped (Not Login Node)"
    resolved_nfs_server_ip="$nfs_server_ip"
  fi

  # ========================================================================
  # Stage 5: Setup NFS Client Mount on This Node
  # ========================================================================
  log_info "Stage 5: Configure NFS Client Mount"
  if [ -z "$resolved_nfs_server_ip" ]; then
    log_error "NFS server IP not available"
    return 1
  fi
  setup_nfs_client_mount "$resolved_nfs_server_ip" "$nfs_mount_point" "$target_user"
  log_info "NFS client mount successfully configured"

  # ========================================================================
  # Stage 6: OrangeFS Preparation (Not yet fully deployed)
  # ========================================================================
  log_info "Stage 6: OrangeFS Preparation (Installation deferred to post-nodes)"
  # Full OrangeFS deployment happens during post-nodes phase when all nodes are ready
  # For now, just prepare directories and log level
  setup_orangefs_directories "$target_user" "$orangefs_data_dir" \
    "$orangefs_metadata_dir" "$orangefs_mount_dir" "$orangefs_log_dir"
  log_info "OrangeFS directories prepared (full deployment in post-nodes phase)"

  log_info "==============================================="
  log_info "Node Orchestration Completed Successfully"
  log_info "Role: ${node_role}"
  log_info "==============================================="
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
  local is_login_node="${IS_LOGIN_NODE:-0}"
  local is_compute_node="${IS_COMPUTE_NODE:-0}"
  local is_storage_node="${IS_STORAGE_NODE:-0}"
  local target_user="${TARGET_USER:-${DEFAULT_TARGET_USER}}"
  local public_key="${PUBLIC_KEY:-}"
  local private_key="${PRIVATE_KEY:-}"
  local nfs_server_ip="${NFS_SERVER_IP:-}"
  local nfs_mount_point="${NFS_MOUNT_POINT:-${DEFAULT_NFS_MOUNT_POINT}}"
  local nfs_export_dir="${NFS_EXPORT_DIR:-${DEFAULT_NFS_EXPORT_DIR}}"
  local orangefs_data_dir="${ORANGEFS_DATA_DIR:-${DEFAULT_ORANGEFS_DATA_DIR}}"
  local orangefs_metadata_dir="${ORANGEFS_METADATA_DIR:-${DEFAULT_ORANGEFS_METADATA_DIR}}"
  local orangefs_mount_dir="${ORANGEFS_MOUNT_DIR:-${DEFAULT_ORANGEFS_MOUNT_DIR}}"
  local orangefs_log_dir="${ORANGEFS_LOG_DIR:-${DEFAULT_ORANGEFS_LOG_DIR}}"
  local stack_name="${STACK_NAME:-}"
  local compute_count="${COMPUTE_COUNT:-0}"
  local storage_count="${STORAGE_COUNT:-0}"
  local os_auth_type="${OS_AUTH_TYPE:-}"
  local os_auth_url="${OS_AUTH_URL:-}"
  local os_identity_api_version="${OS_IDENTITY_API_VERSION:-}"
  local os_region_name="${OS_REGION_NAME:-}"
  local os_interface="${OS_INTERFACE:-}"
  local os_app_cred_id="${OS_APPLICATION_CREDENTIAL_ID:-}"
  local os_app_cred_secret="${OS_APPLICATION_CREDENTIAL_SECRET:-}"
  local script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local log_level="${LOG_LEVEL:-INFO}"

  # Determine node role
  local node_role
  if [ "$is_login_node" = "1" ]; then
    node_role="login"
  elif [ "$is_compute_node" = "1" ]; then
    node_role="compute"
  else
    node_role="storage"
  fi

  # Setup logging and runtime directories
  setup_bootstrap_environment "$node_role"

  # Write environment to file for recovery/debugging
  write_node_environment_file \
    "$node_role" \
    "$target_user" \
    "$public_key" \
    "$private_key" \
    "$is_login_node" \
    "$is_compute_node" \
    "$is_storage_node" \
    "$nfs_server_ip" \
    "$nfs_mount_point" \
    "$nfs_export_dir" \
    "$orangefs_data_dir" \
    "$orangefs_metadata_dir" \
    "$orangefs_mount_dir" \
    "$orangefs_log_dir" \
    "$stack_name" \
    "$compute_count" \
    "$storage_count" \
    "$os_auth_type" \
    "$os_auth_url" \
    "$os_identity_api_version" \
    "$os_region_name" \
    "$os_interface" \
    "$os_app_cred_id" \
    "$os_app_cred_secret" \
    "$script_root" \
    "$log_level"

  # Execute orchestration
  orchestrate_node_setup \
    "$node_role" \
    "$target_user" \
    "$public_key" \
    "$private_key" \
    "$is_login_node" \
    "$is_compute_node" \
    "$is_storage_node" \
    "$nfs_server_ip" \
    "$nfs_mount_point" \
    "$nfs_export_dir" \
    "$orangefs_data_dir" \
    "$orangefs_metadata_dir" \
    "$orangefs_mount_dir" \
    "$orangefs_log_dir" \
    "$stack_name" \
    "$compute_count" \
    "$storage_count" \
    "$os_auth_type" \
    "$os_auth_url" \
    "$os_identity_api_version" \
    "$os_region_name" \
    "$os_interface" \
    "$os_app_cred_id" \
    "$os_app_cred_secret" \
    "$script_root" \
    "$log_level"
}

# Run the main function
main "$@"
