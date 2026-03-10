#!/bin/bash
set -eux

mkdir -p /usr/local/lib/datacrumbs

cat > /usr/local/lib/datacrumbs/key_functions.sh <<'KEY_FUNCS'
__KEY_FUNCTIONS__
KEY_FUNCS

cat > /usr/local/lib/datacrumbs/nfs_functions.sh <<'NFS_FUNCS'
__NFS_FUNCTIONS__
NFS_FUNCS

cat > /usr/local/lib/datacrumbs/post_nodes_functions.sh <<'POST_NODE_FUNCS'
__POST_NODES_FUNCTIONS__
POST_NODE_FUNCS

chmod 755 /usr/local/lib/datacrumbs/key_functions.sh /usr/local/lib/datacrumbs/nfs_functions.sh /usr/local/lib/datacrumbs/post_nodes_functions.sh

source /usr/local/lib/datacrumbs/key_functions.sh
source /usr/local/lib/datacrumbs/nfs_functions.sh

setup_node_role "__IS_LOGIN_NODE__" "__IS_COMPUTE_NODE__" "__IS_STORAGE_NODE__"
setup_bootstrap_logging
setup_ssh_keys "__PUBLIC_KEY__" "__PRIVATE_KEY__"
install_nfs_client_packages

if [ "$IS_LOGIN_NODE" = "1" ]; then
  setup_login_nfs_server
  prepare_post_logs
  write_post_env "__STACK_NAME__" "__COMPUTE_COUNT__" "__STORAGE_COUNT__" "__OS_AUTH_TYPE__" "__OS_AUTH_URL__" "__OS_IDENTITY_API_VERSION__" "__OS_REGION_NAME__" "__OS_INTERFACE__" "__OS_APPLICATION_CREDENTIAL_ID__" "__OS_APPLICATION_CREDENTIAL_SECRET__"

  cat > /usr/local/bin/datacrumbs-post-nodes.sh <<'POST'
__POST_NODES_SCRIPT__
POST
  chmod +x /usr/local/bin/datacrumbs-post-nodes.sh
  nohup bash /usr/local/bin/datacrumbs-post-nodes.sh >> /var/log/datacrumbs-post-nodes-launch.log 2>&1 &

  NFS_SERVER_IP="$(resolve_nfs_server_ip)"
else
  NFS_SERVER_IP="__NFS_SERVER_IP__"
fi

setup_common_mount_dirs
configure_nfs_firewall

if [ "$IS_LOGIN_NODE" = "1" ]; then
  link_login_shared_mount
fi
