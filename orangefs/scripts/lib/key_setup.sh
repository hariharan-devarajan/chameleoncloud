#!/bin/bash
# key_setup.sh - Stateless SSH key and role configuration
# All configuration passed via function arguments

# Source common logging library if not already sourced
if ! declare -f log_info &>/dev/null; then
  SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${SCRIPT_ROOT}/lib/logging.sh"
fi

setup_user_ssh_keys() {
  local ssh_dir="$1"
  local owner="$2"
  local public_key="$3"
  local private_key="$4"

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
Host *compute*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
Host *storage*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
Host *login*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

  chown -R "$owner" "$ssh_dir"
  chmod 700 "$ssh_dir"
  chmod 600 "$ssh_dir/id_rsa" "$ssh_dir/id_rsa.pub" "$ssh_dir/authorized_keys" "$ssh_dir/config"
}

# Setup SSH keys for a specified user
# Args: public_key, private_key, target_user
setup_ssh_keys_for_user() {
  local public_key="$1"
  local private_key="$2"
  local target_user="$3"

  if [ -z "$public_key" ] || [ -z "$private_key" ]; then
    log_warning "SSH keys not provided; skipping SSH setup for ${target_user}"
    return 0
  fi

  local home_dir
  if [ "$target_user" = "root" ]; then
    home_dir="/root"
  else
    home_dir="/home/${target_user}"
  fi

  setup_user_ssh_keys "${home_dir}/.ssh" "${target_user}:${target_user}" "$public_key" "$private_key"
  log_info "SSH keys configured for user ${target_user} at ${home_dir}/.ssh"
}

# Setup SSH keys for multiple users
# Args: public_key, private_key, comma-separated user list (e.g., "cc,root")
setup_ssh_keys_multi() {
  local public_key="$1"
  local private_key="$2"
  local users="$3"
  local user_list=()
  local user

  if [ -z "$users" ]; then
    return 0
  fi

  IFS=',' read -r -a user_list <<< "$users"
  for user in "${user_list[@]}"; do
    user=$(echo "$user" | xargs)  # trim whitespace
    [ -z "$user" ] && continue
    setup_ssh_keys_for_user "$public_key" "$private_key" "$user"
  done
}

# Determine node role from indicator flags
# Args: is_login_node (0/1), is_compute_node (0/1), is_storage_node (0/1)
# Output: role (login, compute, or storage)
determine_node_role() {
  local is_login="$1"
  local is_compute="$2"
  local is_storage="$3"

  if [ "$is_login" = "1" ]; then
    echo "login"
  elif [ "$is_compute" = "1" ]; then
    echo "compute"
  else
    echo "storage"
  fi
}
