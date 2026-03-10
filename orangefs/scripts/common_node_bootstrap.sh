#!/bin/bash
set -eux

log_with_level() {
  local level="$1"
  shift
  echo "[$(date -Is)] STATUS=${level} $*"
}

log_error() {
  log_with_level "ERROR" "$@"
}

log_warning() {
  log_with_level "WARNING" "$@"
}

log_info() {
  log_with_level "INFO" "$@"
}

log_debug() {
  log_with_level "DEBUG" "$@"
}

IS_LOGIN_NODE="${IS_LOGIN_NODE:-0}"
IS_COMPUTE_NODE="${IS_COMPUTE_NODE:-0}"
IS_STORAGE_NODE="${IS_STORAGE_NODE:-0}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
NFS_SERVER_IP_INPUT="${NFS_SERVER_IP:-}"
STACK_NAME_VALUE="${STACK_NAME:-}"
COMPUTE_COUNT_VALUE="${COMPUTE_COUNT:-0}"
STORAGE_COUNT_VALUE="${STORAGE_COUNT:-0}"
OS_AUTH_TYPE_VALUE="${OS_AUTH_TYPE:-}"
OS_AUTH_URL_VALUE="${OS_AUTH_URL:-}"
OS_IDENTITY_API_VERSION_VALUE="${OS_IDENTITY_API_VERSION:-}"
OS_REGION_NAME_VALUE="${OS_REGION_NAME:-}"
OS_INTERFACE_VALUE="${OS_INTERFACE:-}"
OS_APPLICATION_CREDENTIAL_ID_VALUE="${OS_APPLICATION_CREDENTIAL_ID:-}"
OS_APPLICATION_CREDENTIAL_SECRET_VALUE="${OS_APPLICATION_CREDENTIAL_SECRET:-}"

if [ "$IS_LOGIN_NODE" = "1" ]; then
  NODE_ROLE="login"
elif [ "$IS_COMPUTE_NODE" = "1" ]; then
  NODE_ROLE="compute"
else
  NODE_ROLE="storage"
fi

LOG_FILE="/var/log/datacrumbs-bootstrap-${NODE_ROLE}.log"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
log_info "Bootstrap started for role ${NODE_ROLE}"

DEBIAN_FRONTEND=noninteractive apt-get update
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_ROOT/lib/key_functions.sh"
source "$SCRIPT_ROOT/lib/nfs_functions.sh"
log_debug "Loaded function libraries from ${SCRIPT_ROOT}/lib"

source "$SCRIPT_ROOT/lib/orangefs_functions.sh"
log_debug "Loaded OrangeFS functions library"

setup_node_role "$IS_LOGIN_NODE" "$IS_COMPUTE_NODE" "$IS_STORAGE_NODE"
setup_ssh_keys "$PUBLIC_KEY" "$PRIVATE_KEY"
install_nfs_client_packages
log_info "Completed key setup and base NFS client package installation"

if [ "$IS_LOGIN_NODE" = "1" ]; then
  log_info "Configuring login node NFS server and post-nodes workflow"
  setup_login_nfs_server
  prepare_post_logs
  write_post_env "$STACK_NAME_VALUE" "$COMPUTE_COUNT_VALUE" "$STORAGE_COUNT_VALUE" "$OS_AUTH_TYPE_VALUE" "$OS_AUTH_URL_VALUE" "$OS_IDENTITY_API_VERSION_VALUE" "$OS_REGION_NAME_VALUE" "$OS_INTERFACE_VALUE" "$OS_APPLICATION_CREDENTIAL_ID_VALUE" "$OS_APPLICATION_CREDENTIAL_SECRET_VALUE"

  chmod +x "$SCRIPT_ROOT/datacrumbs-post-nodes.sh"
  nohup bash "$SCRIPT_ROOT/datacrumbs-post-nodes.sh" >> /var/log/datacrumbs-post-nodes-launch.log 2>&1 &
  log_info "Started datacrumbs post-nodes script in background"

  NFS_SERVER_IP="$(resolve_nfs_server_ip)"
  log_debug "Resolved login-node NFS server IP as ${NFS_SERVER_IP}"
else
  NFS_SERVER_IP="$NFS_SERVER_IP_INPUT"
  log_debug "Using provided login-node NFS server IP ${NFS_SERVER_IP}"
fi

setup_common_mount_dirs
configure_nfs_firewall
log_info "Prepared mount directories and firewall rules"

setup_nfs_client_mount "$NFS_SERVER_IP"
log_info "Configured NFS client mount using server IP ${NFS_SERVER_IP}"

log_info "Bootstrap completed for role ${NODE_ROLE}"

# install_orangefs_dependencies
# install_orangefs
setup_orangefs_module
setup_orangefs_directories
configure_orangefs_firewall

if [ "$IS_LOGIN_NODE" = "1" ]; then
  log_info "Login node OrangeFS client configured"
elif [ "$IS_COMPUTE_NODE" = "1" ]; then
  log_info "Compute node OrangeFS server and client configured"
else
  log_info "Storage node OrangeFS client configured"
fi

log_info "OrangeFS installation and configuration completed"
