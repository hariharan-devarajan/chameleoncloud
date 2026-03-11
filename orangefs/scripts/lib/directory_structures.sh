#!/bin/bash
# directory_structures.sh - Stateless directory and user setup
# All paths and permissions passed via function arguments

# Source common logging library if not already sourced
if ! declare -f log_info &>/dev/null; then
  SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${SCRIPT_ROOT}/lib/logging.sh"
fi

# Setup base user for deployment
# Args: target_user, target_uid (optional), target_gid (optional)
setup_deployment_user() {
  local target_user="$1"
  local target_uid="${2:-1000}"
  local target_gid="${3:-1000}"

  if [ -z "$target_user" ]; then
    log_error "No target user specified"
    return 1
  fi

  if id "$target_user" >/dev/null 2>&1; then
    log_info "User ${target_user} already exists"
    return 0
  fi

  groupadd -g "$target_gid" "$target_user" 2>/dev/null || true
  useradd -u "$target_uid" -g "$target_gid" -s /bin/bash -m "$target_user" 2>/dev/null || true
  log_info "User ${target_user} configured with UID ${target_uid} GID ${target_gid}"
}

# Setup common directories with proper ownership
# Args: target_user, base_paths_csv (comma-separated paths)
setup_common_directories() {
  local target_user="$1"
  local base_paths="$2"

  if [ -z "$target_user" ] || [ -z "$base_paths" ]; then
    log_error "Missing target_user or base_paths"
    return 1
  fi

  while IFS=',' read -r path; do
    path=$(echo "$path" | xargs)  # trim whitespace
    [ -z "$path" ] && continue

    mkdir -p "$path"
    chown -R "${target_user}:${target_user}" "$path"
    chmod 755 "$path"
    log_debug "Directory setup: ${path} owned by ${target_user}"
  done <<< "$base_paths"

  log_info "Common directories created and configured"
}

# Setup NFS client mount directories
# Args: target_user, nfs_mount_point, opt_client_path
setup_nfs_client_directories() {
  local target_user="$1"
  local nfs_mount_point="${2:-/opt/nfs_client}"
  local opt_client_path="${3:-${nfs_mount_point}}"

  mkdir -p "$nfs_mount_point"
  mkdir -p "$opt_client_path"

  chown -R "${target_user}:${target_user}" "$nfs_mount_point"
  chmod 755 "$nfs_mount_point"

  if [ "$nfs_mount_point" != "$opt_client_path" ]; then
    chown -R "${target_user}:${target_user}" "$opt_client_path"
    chmod 755 "$opt_client_path"
  fi

  log_info "NFS client directories prepared: ${nfs_mount_point}"
}

# Setup OrangeFS data and metadata directories
# Args: target_user, data_dir, metadata_dir, mount_dir
setup_orangefs_directories() {
  local target_user="$1"
  local data_dir="${2:-/mnt/nvme/orangefs_data}"
  local metadata_dir="${3:-/mnt/nvme/orangefs_metadata}"
  local mount_dir="${4:-/mnt/orangefs}"
  local log_dir="${5:-/opt/orangefs/logs}"

  mkdir -p "$data_dir"
  mkdir -p "$metadata_dir"
  mkdir -p "$mount_dir"
  mkdir -p "$log_dir"

  chown -R "${target_user}:${target_user}" "$data_dir"
  chown -R "${target_user}:${target_user}" "$metadata_dir"
  chown -R "${target_user}:${target_user}" "$mount_dir"
  chown -R "${target_user}:${target_user}" "$log_dir"

  chmod 755 "$data_dir" "$metadata_dir" "$mount_dir" "$log_dir"

  log_info "OrangeFS directories created:"
  log_debug " - Data:     ${data_dir}"
  log_debug " - Metadata: ${metadata_dir}"
  log_debug " - Mount:    ${mount_dir}"
  log_debug " - Logs:     ${log_dir}"
}

# Setup NFS server export directory
# Args: target_user, export_dir (e.g., /opt/shared)
setup_nfs_server_directory() {
  local target_user="$1"
  local export_dir="${2:-/opt/shared}"

  mkdir -p "$export_dir"
  chown -R "${target_user}:${target_user}" "$export_dir"
  chmod 755 "$export_dir"

  log_info "NFS server export directory prepared: ${export_dir}"
}

# Setup logging directories
# Args: target_user, log_base_dir
setup_logging_directories() {
  local target_user="$1"
  local log_base_dir="${2:-/var/log/datacrumbs}"

  mkdir -p "$log_base_dir"
  chmod 777 "$log_base_dir"

  # Touch standard log files
  touch "$log_base_dir/bootstrap-login.log"
  touch "$log_base_dir/bootstrap-compute.log"
  touch "$log_base_dir/bootstrap-storage.log"
  touch "$log_base_dir/post-nodes.log"
  touch "$log_base_dir/post-nodes-launch.log"
  chmod 666 "$log_base_dir"/*.log

  log_info "Logging directories configured at ${log_base_dir}"
}

# Setup all deployment directories at once
# Args: target_user, nfs_mount_point, export_dir, orangefs_data_dir, etc.
setup_all_directories() {
  local target_user="$1"
  local nfs_mount_point="${2:-/opt/nfs_client}"
  local export_dir="${3:-/opt/shared}"
  local orangefs_data_dir="${4:-/mnt/nvme/orangefs_data}"
  local orangefs_metadata_dir="${5:-/mnt/nvme/orangefs_metadata}"
  local orangefs_mount_dir="${6:-/mnt/orangefs}"
  local orangefs_log_dir="${7:-/opt/orangefs/logs}"
  local log_base_dir="${8:-/var/log/datacrumbs}"

  log_info "Setting up all deployment directories"

  setup_deployment_user "$target_user"
  setup_nfs_server_directory "$target_user" "$export_dir"
  setup_nfs_client_directories "$target_user" "$nfs_mount_point"
  setup_orangefs_directories "$target_user" "$orangefs_data_dir" "$orangefs_metadata_dir" "$orangefs_mount_dir" "$orangefs_log_dir"
  setup_logging_directories "$target_user" "$log_base_dir"

  log_info "All deployment directories configured for user ${target_user}"
}
