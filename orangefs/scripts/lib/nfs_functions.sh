#!/bin/bash
# nfs_functions.sh - Stateless NFS server and client configuration
# All configuration passed via function arguments

# Source common logging library if not already sourced
if ! declare -f log_info &>/dev/null; then
  SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${SCRIPT_ROOT}/lib/logging.sh"
fi

# Install NFS client packages
install_nfs_client_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
}

# Install NFS server packages
install_nfs_server_packages() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient || true
}

# Setup NFS server
# Args: export_dir, target_user, network_cidr (e.g., "10.0.0.0/8")
setup_nfs_server() {
  local export_dir="$1"
  local target_user="$2"
  local network_cidr="${3:-10.0.0.0/8}"

  mkdir -p "$export_dir"
  chown -R "${target_user}:${target_user}" "$export_dir"
  chmod 755 "$export_dir"

  echo "${export_dir} ${network_cidr}(rw,async,no_subtree_check)" > /etc/exports

  systemctl enable rpcbind && systemctl start rpcbind
  systemctl enable nfs-kernel-server && systemctl start nfs-kernel-server
  exportfs -ra

  [ -f /etc/auto_mount_readme ] || touch /etc/auto_mount_readme

  log_info "NFS server configured with export: ${export_dir}"
}

# Resolve NFS server IP from local node IPs
# Args: (none)
# Output: IPv4 address of first 10.x.x.x interface
resolve_nfs_server_ip() {
  /usr/sbin/ip addr show | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | grep 10\\. | head -n1
}

# Write post-nodes environment file for use by post-processing script
# Args: env_file_path, stack_name, compute_count, storage_count, os_auth_type, os_auth_url, os_identity_api_version, os_region_name, os_interface, os_app_cred_id, os_app_cred_secret
write_post_nodes_env() {
  local env_file="$1"
  local stack_name="$2"
  local compute_count="$3"
  local storage_count="$4"
  local os_auth_type="$5"
  local os_auth_url="$6"
  local os_identity_api_version="$7"
  local os_region_name="$8"
  local os_interface="$9"
  local os_app_cred_id="${10}"
  local os_app_cred_secret="${11}"

  {
    echo "STACK_NAME=\"${stack_name}\""
    echo "COMPUTE_COUNT=\"${compute_count}\""
    echo "STORAGE_COUNT=\"${storage_count}\""
    echo "OS_AUTH_TYPE=\"${os_auth_type}\""
    echo "OS_AUTH_URL=\"${os_auth_url}\""
    echo "OS_IDENTITY_API_VERSION=\"${os_identity_api_version}\""
    echo "OS_REGION_NAME=\"${os_region_name}\""
    echo "OS_INTERFACE=\"${os_interface}\""
    echo "OS_APPLICATION_CREDENTIAL_ID=\"${os_app_cred_id}\""
    echo "OS_APPLICATION_CREDENTIAL_SECRET=\"${os_app_cred_secret}\""
  } > "$env_file"
  chmod 600 "$env_file"

  log_info "Post-nodes environment file written to ${env_file}"
}

# Prepare logging for post-nodes script
prepare_post_nodes_logging() {
  touch /var/log/datacrumbs-post-nodes.log
  chmod 644 /var/log/datacrumbs-post-nodes.log
  log_debug "Preparing login post-nodes background script"

  touch /var/log/datacrumbs-post-nodes-launch.log
  chmod 644 /var/log/datacrumbs-post-nodes-launch.log
}

# Extract clean hostname from SSH output (filters warnings, banners)
extract_hostname_from_output() {
  awk '
    /^[[:space:]]*$/ { next }
    /^Warning:/ { next }
    /^Permanently added / { next }
    {
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
        candidate=line
      }
    }
    END {
      if (candidate != "") {
        print candidate
      }
    }
  '
}

# Resolve hostname for a cluster node via SSH with retry logic
# Args: ip, ssh_user, ssh_opts, local_ips_file, max_attempts (default 10), retry_interval_s (default 60)
resolve_cluster_node_hostname() {
  local ip="$1"
  local ssh_user="$2"
  local ssh_opts="$3"
  local local_ips_file="$4"
  local max_attempts="${5:-10}"
  local retry_interval_seconds="${6:-60}"
  local attempt
  local raw_output
  local parsed_hostname

  if grep -Fxq "${ip}" "${local_ips_file}"; then
    hostname -s 2>/dev/null | extract_hostname_from_output || true
    return 0
  fi

  for attempt in $(seq 1 "${max_attempts}"); do
    raw_output="$(timeout 20 ssh ${ssh_opts} "${ssh_user}@${ip}" "hostname -s" </dev/null 2>&1 || true)"
    parsed_hostname="$(printf '%s\n' "${raw_output}" | extract_hostname_from_output || true)"

    if [ -n "${parsed_hostname}" ]; then
      printf '%s\n' "${parsed_hostname}"
      return 0
    fi

    if [ "${attempt}" -lt "${max_attempts}" ]; then
      log_warning "Hostname lookup failed for ${ip} (attempt ${attempt}/${max_attempts}); retrying in ${retry_interval_seconds}s"
      sleep "${retry_interval_seconds}"
    fi
  done

  return 0
}

# Debug cluster hosts resolution (show what would be configured)
# Args: all_nodes_file, ssh_user, login_node_file, compute_nodes_file, storage_nodes_file
debug_cluster_hosts_resolution() {
  local all_nodes_file="${1:-/opt/nfs_client/all_nodes.txt}"
  local ssh_user="${2:-cc}"
  local login_node_file="${3:-/opt/nfs_client/login_node.txt}"
  local compute_nodes_file="${4:-/opt/nfs_client/compute_nodes.txt}"
  local storage_nodes_file="${5:-/opt/nfs_client/storage_nodes.txt}"
  local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes"
  local nodes_file
  local local_ips_file
  local ip
  local hostname

  nodes_file="$(mktemp)"
  local_ips_file="$(mktemp)"
  trap 'rm -f "${nodes_file}" "${local_ips_file}"' RETURN

  [ -f "${all_nodes_file}" ] && grep -Ev '^[[:space:]]*$' "${all_nodes_file}" >> "${nodes_file}" || true
  [ -f "${compute_nodes_file}" ] && grep -Ev '^[[:space:]]*$' "${compute_nodes_file}" >> "${nodes_file}" || true
  [ -f "${storage_nodes_file}" ] && grep -Ev '^[[:space:]]*$' "${storage_nodes_file}" >> "${nodes_file}" || true
  [ -f "${login_node_file}" ] && grep -Ev '^[[:space:]]*$' "${login_node_file}" >> "${nodes_file}" || true
  sort -u "${nodes_file}" -o "${nodes_file}"

  if [ ! -s "${nodes_file}" ]; then
    log_error "No nodes found in provided list files"
    return 1
  fi

  ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | sort -u > "${local_ips_file}" || true

  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue

    hostname="$(resolve_cluster_node_hostname "${ip}" "${ssh_user}" "${ssh_opts}" "${local_ips_file}")"

    if [ -z "${hostname}" ]; then
      echo "${ip} <unresolved>"
    else
      echo "${ip} ${hostname}"
    fi
  done < "${nodes_file}"
}

# Configure /etc/hosts across entire cluster with hostname resolution
# Args: all_nodes_file, ssh_user, login_node_file, compute_nodes_file, storage_nodes_file
configure_cluster_hosts_resolution() {
  local all_nodes_file="${1:-/opt/nfs_client/all_nodes.txt}"
  local ssh_user="${2:-cc}"
  local login_node_file="${3:-/opt/nfs_client/login_node.txt}"
  local compute_nodes_file="${4:-/opt/nfs_client/compute_nodes.txt}"
  local storage_nodes_file="${5:-/opt/nfs_client/storage_nodes.txt}"
  local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes"
  local nodes_for_hosts_file
  local local_ips_file
  local ip
  local hostname
  local failed=0

  if [ ! -f "${all_nodes_file}" ]; then
    log_error "Node list not found: ${all_nodes_file}"
    return 1
  fi

  nodes_for_hosts_file="$(mktemp)"
  local_ips_file="$(mktemp)"
  trap 'rm -f "${nodes_for_hosts_file}" "${local_ips_file}" /tmp/hosts' RETURN

  grep -Ev '^[[:space:]]*$' "${all_nodes_file}" > "${nodes_for_hosts_file}" || true
  if [ -f "${compute_nodes_file}" ]; then
    grep -Ev '^[[:space:]]*$' "${compute_nodes_file}" >> "${nodes_for_hosts_file}" || true
  fi
  if [ -f "${storage_nodes_file}" ]; then
    grep -Ev '^[[:space:]]*$' "${storage_nodes_file}" >> "${nodes_for_hosts_file}" || true
  fi
  if [ -f "${login_node_file}" ]; then
    grep -Ev '^[[:space:]]*$' "${login_node_file}" >> "${nodes_for_hosts_file}" || true
  fi
  sort -u "${nodes_for_hosts_file}" -o "${nodes_for_hosts_file}"

  ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | sort -u > "${local_ips_file}" || true

  if [ ! -s "${nodes_for_hosts_file}" ]; then
    log_error "No nodes found in ${all_nodes_file} and ${login_node_file}"
    return 1
  fi

  : > /tmp/hosts

  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue

    hostname="$(resolve_cluster_node_hostname "${ip}" "${ssh_user}" "${ssh_opts}" "${local_ips_file}")"

    if [ -z "${hostname}" ]; then
      log_error "Could not resolve hostname for ${ip}"
      failed=1
      continue
    fi

    echo "${ip} ${hostname}"
    echo "${ip} ${hostname}" >> /tmp/hosts
  done < "${nodes_for_hosts_file}"

  if [ "${failed}" -ne 0 ]; then
    log_error "Failed to resolve all hostnames; aborting hosts update"
    return 1
  fi

  sort -u /tmp/hosts -o /tmp/hosts

  if [ ! -s /tmp/hosts ]; then
    log_error "No hostname entries were resolved"
    return 1
  fi

  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue

    if grep -Fxq "${ip}" "${local_ips_file}"; then
      if ! sudo bash -c 'tmp=$(mktemp); awk '\''/^# BEGIN CHAMELEON HOSTS$/{skip=1;next}/^# END CHAMELEON HOSTS$/{skip=0;next}!skip{print}'\'' /etc/hosts > "$tmp"; { echo "# BEGIN CHAMELEON HOSTS"; cat /tmp/hosts; echo "# END CHAMELEON HOSTS"; } >> "$tmp"; cat "$tmp" > /etc/hosts; rm -f "$tmp"'; then
        log_error "Failed to update /etc/hosts on ${ip}"
        failed=1
        continue
      fi

      log_info "Updated /etc/hosts on ${ip}"
      continue
    fi

    if ! timeout 30 scp ${ssh_opts} /tmp/hosts "${ssh_user}@${ip}:/tmp/hosts" </dev/null >/dev/null 2>&1; then
      log_error "Failed to copy /tmp/hosts to nodes"
      failed=1
      continue
    fi

    if ! timeout 30 ssh ${ssh_opts} "${ssh_user}@${ip}" "sudo bash -c 'tmp=\$(mktemp); awk '\''/^# BEGIN CHAMELEON HOSTS\$/{skip=1;next}/^# END CHAMELEON HOSTS\$/{skip=0;next}!skip{print}'\'' /etc/hosts > \"\$tmp\"; { echo \"# BEGIN CHAMELEON HOSTS\"; cat /tmp/hosts; echo \"# END CHAMELEON HOSTS\"; } >> \"\$tmp\"; cat \"\$tmp\" > /etc/hosts; rm -f \"\$tmp\" /tmp/hosts'" </dev/null; then
      log_error "Failed to update /etc/hosts on ${ip}"
      failed=1
      continue
    fi

    log_info "Updated /etc/hosts on ${ip}"
  done < "${nodes_for_hosts_file}"

  if [ "${failed}" -ne 0 ]; then
    log_error "Hosts synchronization incomplete"
    return 1
  fi

  log_info "Cluster hosts resolution configured"
  return 0
}

# Setup NFS client mount on local node
# Args: nfs_server_ip, nfs_mount_point, target_user (optional)
setup_nfs_client_mount() {
  local nfs_server_ip="$1"
  local nfs_mount_point="${2:-/opt/nfs_client}"
  local target_user="${3:-cc}"

  if [ -z "$nfs_server_ip" ]; then
    log_error "NFS server IP is empty; cannot configure NFS client mount"
    return 1
  fi

  mkdir -p "$nfs_mount_point"
  chown -R "${target_user}:${target_user}" "$nfs_mount_point"

  grep -q "^${nfs_server_ip}:/opt/shared[[:space:]]\+${nfs_mount_point}[[:space:]]\+nfs" /etc/fstab || \
  echo "${nfs_server_ip}:/opt/shared    ${nfs_mount_point}    nfs" >> /etc/fstab

  mount -a

  if ! mountpoint -q "$nfs_mount_point"; then
    log_error "Failed to mount ${nfs_mount_point}"
    return 1
  fi

  if [ -z "$(ls -A "$nfs_mount_point")" ]; then
    log_error "${nfs_mount_point} is empty after mounting"
    return 1
  fi

  log_info "NFS client mount configured and verified at ${nfs_mount_point}"
  return 0
}

# Setup a symbolic link for NFS client mount on login node
# Args: nfs_mount_point, link_target (optional - usually /opt/shared)
link_login_shared_mount() {
  local nfs_mount_point="${1:-/opt/nfs_client}"
  local link_target="${2:-/opt/shared}"

  if [ -d "$nfs_mount_point" ] && [ ! -L "$nfs_mount_point" ]; then
    rm -rf "$nfs_mount_point"
  fi

  ln -sf "$link_target" "$nfs_mount_point"
  log_info "Linked ${nfs_mount_point} -> ${link_target}"
}

# Configure NFS firewall rules
# Args: (none - uses firewall-cmd)
configure_nfs_firewall() {
  firewall-cmd --permanent --add-service=rpc-bind || true
  firewall-cmd --permanent --add-service=mountd || true
  firewall-cmd --permanent --add-service=nfs || true
  firewall-cmd --reload || true

  log_info "NFS firewall rules configured"
}
