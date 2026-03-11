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
  chown -R cc:cc -R /mnt 
  chown cc:cc /opt/nfs_client
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

resolve_cluster_node_hostname() {
  local ip="$1"
  local ssh_user="$2"
  local ssh_opts="$3"
  local local_ips_file="$4"
  local max_attempts=10
  local retry_interval_seconds=60
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
      echo "[$(date -Is)] STATUS=WARNING Hostname lookup failed for ${ip} (attempt ${attempt}/${max_attempts}); retrying in ${retry_interval_seconds}s" >&2
      sleep "${retry_interval_seconds}"
    fi
  done

  return 0
}

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
    echo "[$(date -Is)] STATUS=ERROR No nodes found in provided list files"
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
    echo "[$(date -Is)] STATUS=ERROR Node list not found: ${all_nodes_file}"
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
    echo "[$(date -Is)] STATUS=ERROR No nodes found in ${all_nodes_file} and ${login_node_file}"
    return 1
  fi

  : > /tmp/hosts

  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue

    hostname="$(resolve_cluster_node_hostname "${ip}" "${ssh_user}" "${ssh_opts}" "${local_ips_file}")"

    if [ -z "${hostname}" ]; then
      echo "[$(date -Is)] STATUS=ERROR Could not resolve hostname for ${ip}"
      failed=1
      continue
    fi

    echo "${ip} ${hostname}"
    echo "${ip} ${hostname}" >> /tmp/hosts
  done < "${nodes_for_hosts_file}"

  if [ "${failed}" -ne 0 ]; then
    echo "[$(date -Is)] STATUS=ERROR Failed to resolve all hostnames; aborting hosts update"
    return 1
  fi

  sort -u /tmp/hosts -o /tmp/hosts

  if [ ! -s /tmp/hosts ]; then
    echo "[$(date -Is)] STATUS=ERROR No hostname entries were resolved"
    return 1
  fi

  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue

    if grep -Fxq "${ip}" "${local_ips_file}"; then
      if ! sudo bash -c 'tmp=$(mktemp); awk '\''/^# BEGIN CHAMELEON HOSTS$/{skip=1;next}/^# END CHAMELEON HOSTS$/{skip=0;next}!skip{print}'\'' /etc/hosts > "$tmp"; { echo "# BEGIN CHAMELEON HOSTS"; cat /tmp/hosts; echo "# END CHAMELEON HOSTS"; } >> "$tmp"; cat "$tmp" > /etc/hosts; rm -f "$tmp"'; then
        echo "[$(date -Is)] STATUS=ERROR Failed to update /etc/hosts on ${ip}"
        failed=1
        continue
      fi

      echo "[$(date -Is)] STATUS=INFO Updated /etc/hosts on ${ip}"
      continue
    fi

    if ! timeout 30 scp ${ssh_opts} /tmp/hosts "${ssh_user}@${ip}:/tmp/hosts" </dev/null >/dev/null 2>&1; then
      echo "[$(date -Is)] STATUS=ERROR Failed to copy /tmp/hosts to ${ip}"
      failed=1
      continue
    fi

    if ! timeout 30 ssh ${ssh_opts} "${ssh_user}@${ip}" "sudo bash -c 'tmp=\$(mktemp); awk '\''/^# BEGIN CHAMELEON HOSTS\$/{skip=1;next}/^# END CHAMELEON HOSTS\$/{skip=0;next}!skip{print}'\'' /etc/hosts > \"\$tmp\"; { echo \"# BEGIN CHAMELEON HOSTS\"; cat /tmp/hosts; echo \"# END CHAMELEON HOSTS\"; } >> \"\$tmp\"; cat \"\$tmp\" > /etc/hosts; rm -f \"\$tmp\" /tmp/hosts'" </dev/null; then
      echo "[$(date -Is)] STATUS=ERROR Failed to update /etc/hosts on ${ip}"
      failed=1
      continue
    fi

    echo "[$(date -Is)] STATUS=INFO Updated /etc/hosts on ${ip}"
  done < "${nodes_for_hosts_file}"

  if [ "${failed}" -ne 0 ]; then
    echo "[$(date -Is)] STATUS=ERROR Hosts synchronization incomplete"
    return 1
  fi

  echo "[$(date -Is)] STATUS=SUCCESS Cluster hosts resolution configured"
  return 0
}

setup_nfs_client_mount() {
    local nfs_server_ip="$1"

    if [ -z "$nfs_server_ip" ]; then
    echo "[$(date -Is)] STATUS=ERROR NFS server IP is empty; cannot configure NFS client mount"
    return 1
    fi

    mkdir -p /opt/nfs_client

    grep -q "^${nfs_server_ip}:/opt/shared[[:space:]]\+/opt/nfs_client[[:space:]]\+nfs" /etc/fstab || \

    echo "${nfs_server_ip}:/opt/shared    /opt/nfs_client    nfs" >> /etc/fstab

    mount -a

    if ! mountpoint -q /opt/nfs_client; then
        echo "[$(date -Is)] STATUS=ERROR Failed to mount /opt/nfs_client"
        return 1
    fi

    if [ -z "$(ls -A /opt/nfs_client)" ]; then
        echo "[$(date -Is)] STATUS=ERROR /opt/nfs_client is empty after mounting"
        return 1
    fi
    echo "[$(date -Is)] STATUS=SUCCESS NFS client mount configured and verified at /opt/nfs_client"
    return 0
}
