#!/bin/bash
set -eux

IS_LOGIN_NODE="__IS_LOGIN_NODE__"
IS_COMPUTE_NODE="__IS_COMPUTE_NODE__"
IS_STORAGE_NODE="__IS_STORAGE_NODE__"

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

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y git

REPO_URL="__REPO_URL__"
REPO_REF="__REPO_REF__"
REPO_DIR="/opt/chameleoncloud"

if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch --all
  git -C "$REPO_DIR" checkout "$REPO_REF"
  git -C "$REPO_DIR" pull --ff-only origin "$REPO_REF" || true
else
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR"
fi

SCRIPT_ROOT="$REPO_DIR/orangefs/scripts"
source "$SCRIPT_ROOT/lib/key_functions.sh"
source "$SCRIPT_ROOT/lib/nfs_functions.sh"

setup_node_role "$IS_LOGIN_NODE" "$IS_COMPUTE_NODE" "$IS_STORAGE_NODE"
setup_ssh_keys "__PUBLIC_KEY__" "__PRIVATE_KEY__"
install_nfs_client_packages

if [ "$IS_LOGIN_NODE" = "1" ]; then
  setup_login_nfs_server
  prepare_post_logs
  write_post_env "__STACK_NAME__" "__COMPUTE_COUNT__" "__STORAGE_COUNT__" "__OS_AUTH_TYPE__" "__OS_AUTH_URL__" "__OS_IDENTITY_API_VERSION__" "__OS_REGION_NAME__" "__OS_INTERFACE__" "__OS_APPLICATION_CREDENTIAL_ID__" "__OS_APPLICATION_CREDENTIAL_SECRET__"

  chmod +x "$SCRIPT_ROOT/datacrumbs-post-nodes.sh"
  nohup bash "$SCRIPT_ROOT/datacrumbs-post-nodes.sh" >> /var/log/datacrumbs-post-nodes-launch.log 2>&1 &

  NFS_SERVER_IP="$(resolve_nfs_server_ip)"
else
  NFS_SERVER_IP="__NFS_SERVER_IP__"
fi

setup_common_mount_dirs
configure_nfs_firewall

if [ "$IS_LOGIN_NODE" = "1" ]; then
  link_login_shared_mount
fi
