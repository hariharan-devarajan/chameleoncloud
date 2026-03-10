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

  setup_user_ssh_keys() {
    local ssh_dir="$1"
    local owner="$2"

    mkdir -p "$ssh_dir"
    echo "$public_key" > "$ssh_dir/id_rsa.pub"
    echo "-----BEGIN OPENSSH PRIVATE KEY-----" > "$ssh_dir/id_rsa"
    echo "$private_key" | tr -d " " | fold -w 70 >> "$ssh_dir/id_rsa"
    echo "-----END OPENSSH PRIVATE KEY-----" >> "$ssh_dir/id_rsa"
    cat "$ssh_dir/id_rsa.pub" >> "$ssh_dir/authorized_keys"

    cat <<EOF > "$ssh_dir/config"
Host 10.52.*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

    chown -R "$owner" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/id_rsa" "$ssh_dir/id_rsa.pub" "$ssh_dir/authorized_keys" "$ssh_dir/config"
  }

  setup_user_ssh_keys "/home/cc/.ssh" "cc:cc"
  setup_user_ssh_keys "/root/.ssh" "root:root"
}
