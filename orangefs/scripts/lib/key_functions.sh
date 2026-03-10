#!/bin/bash

setup_node_role() {
  IS_LOGIN_NODE="$1"
  IS_COMPUTE_NODE="$2"
  IS_STORAGE_NODE="$3"

  if [ "$IS_LOGIN_NODE" = "1" ]; then
    NODE_ROLE="login"
  elif [ "$IS_COMPUTE_NODE" = "1" ]; then
    NODE_ROLE="compute"
  else
    NODE_ROLE="storage"
  fi

  export IS_LOGIN_NODE IS_COMPUTE_NODE IS_STORAGE_NODE NODE_ROLE
}

setup_bootstrap_logging() {
  local log_file="/var/log/datacrumbs-bootstrap-${NODE_ROLE}.log"
  touch "$log_file"
  chmod 644 "$log_file"
  exec > >(tee -a "$log_file") 2>&1
}

setup_ssh_keys() {
  local public_key="$1"
  local private_key="$2"

  mkdir -p /home/cc/.ssh
  echo "$public_key" > /home/cc/.ssh/id_rsa.pub
  echo "-----BEGIN OPENSSH PRIVATE KEY-----" > /home/cc/.ssh/id_rsa
  echo "$private_key" | tr -d " " | fold -w 70 >> /home/cc/.ssh/id_rsa
  echo "-----END OPENSSH PRIVATE KEY-----" >> /home/cc/.ssh/id_rsa
  cat /home/cc/.ssh/id_rsa.pub >> /home/cc/.ssh/authorized_keys

  cat <<EOF >> /home/cc/.ssh/config
Host 10.52.*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

  chown -R cc:cc /home/cc/.ssh
  chmod 700 /home/cc/.ssh
  chmod 600 /home/cc/.ssh/id_rsa /home/cc/.ssh/id_rsa.pub /home/cc/.ssh/authorized_keys /home/cc/.ssh/config
}
