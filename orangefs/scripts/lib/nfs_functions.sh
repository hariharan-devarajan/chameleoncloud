#!/bin/bash

install_nfs_client_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
}

setup_login_nfs_server() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient || true

  mkdir -p /opt/shared
  chown -R cc:cc /opt/shared
  echo '/opt/shared 10.0.0.0/8(rw,async,no_subtree_check)' > /etc/exports

  systemctl enable rpcbind && systemctl start rpcbind
  systemctl enable nfs-kernel-server && systemctl start nfs-kernel-server
  exportfs -ra

  touch /opt/shared/nodelist.txt
  chown -R cc:cc /opt/shared/nodelist.txt
  [ -f /etc/auto_mount_readme ] || touch /etc/auto_mount_readme
}

write_post_env() {
  local stack_name="$1"
  local compute_count="$2"
  local storage_count="$3"
  local os_auth_type="$4"
  local os_auth_url="$5"
  local os_identity_api_version="$6"
  local os_region_name="$7"
  local os_interface="$8"
  local os_application_credential_id="$9"
  local os_application_credential_secret="${10}"

  {
    echo "STACK_NAME=\"${stack_name}\""
    echo "COMPUTE_COUNT=\"${compute_count}\""
    echo "STORAGE_COUNT=\"${storage_count}\""
    echo "OS_AUTH_TYPE=\"${os_auth_type}\""
    echo "OS_AUTH_URL=\"${os_auth_url}\""
    echo "OS_IDENTITY_API_VERSION=\"${os_identity_api_version}\""
    echo "OS_REGION_NAME=\"${os_region_name}\""
    echo "OS_INTERFACE=\"${os_interface}\""
    echo "OS_APPLICATION_CREDENTIAL_ID=\"${os_application_credential_id}\""
    echo "OS_APPLICATION_CREDENTIAL_SECRET=\"${os_application_credential_secret}\""
  } > /etc/datacrumbs-post.env
  chmod 600 /etc/datacrumbs-post.env
}

prepare_post_logs() {
  touch /var/log/datacrumbs-post-nodes.log
  chmod 644 /var/log/datacrumbs-post-nodes.log
  echo "[$(date -Is)] preparing login post-nodes background script" >> /var/log/datacrumbs-post-nodes.log

  touch /var/log/datacrumbs-post-nodes-launch.log
  chmod 644 /var/log/datacrumbs-post-nodes-launch.log
}

resolve_nfs_server_ip() {
  /usr/sbin/ip addr show | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | grep 10\\. | head -n1
}

setup_common_mount_dirs() {
  mkdir -p /mnt/nvme/orangefs_{data,meta}
  mkdir -p /mnt/orangefs
  mkdir -p /opt/nfs_client
}

configure_nfs_firewall() {
  firewall-cmd --permanent --add-service=rpc-bind || true
  firewall-cmd --permanent --add-service=mountd || true
  firewall-cmd --permanent --add-service=nfs || true
  firewall-cmd --reload || true
}

link_login_shared_mount() {
  rm -rf /opt/nfs_client
  ln -s /opt/shared /opt/nfs_client
}
