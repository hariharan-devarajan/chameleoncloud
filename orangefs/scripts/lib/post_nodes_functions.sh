#!/bin/bash

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

datacrumbs_post_nodes_setup() {
  source /etc/datacrumbs-post.env

  LOG_FILE="/var/log/datacrumbs-post-nodes.log"
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_info "Initialized post-nodes logging to ${LOG_FILE}"

  if ! command -v openstack >/dev/null 2>&1; then
    log_warning "openstack CLI not found; installing python3-openstackclient"
    timeout 600 bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update'
    timeout 600 bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient'
  fi

  export OS_AUTH_TYPE
  export OS_AUTH_URL
  export OS_IDENTITY_API_VERSION
  export OS_REGION_NAME
  export OS_INTERFACE
  export OS_APPLICATION_CREDENTIAL_ID
  export OS_APPLICATION_CREDENTIAL_SECRET

  mkdir -p /opt/nfs_client
  : > /opt/nfs_client/all_nodes.txt
  : > /opt/nfs_client/compute_nodes.txt
  : > /opt/nfs_client/storage_nodes.txt
  : > /opt/nfs_client/login_node.txt
  log_debug "Reset node list files under /opt/nfs_client"
}

wait_for_nodes_ready() {
  local max_attempts=60
  local sleep_seconds=10
  local attempt
  local server_list_file="/tmp/server_list.json"

  for attempt in $(seq 1 "$max_attempts"); do
    log_info "Checking node readiness from OpenStack (attempt ${attempt}/${max_attempts})"
    if timeout 30 openstack server list -f json -c Name -c Status -c Networks > "$server_list_file"; then
      python3 - "$server_list_file" "$STACK_NAME" "$COMPUTE_COUNT" "$STORAGE_COUNT" <<'PY'
import json
import re
import sys

server_list_file = sys.argv[1]
stack_name = sys.argv[2]
compute_count = int(sys.argv[3])
storage_count = int(sys.argv[4])

def extract_ipv4(value):
    text = value if isinstance(value, str) else str(value)
    matches = re.findall(r'(?:\d{1,3}\.){3}\d{1,3}', text)
  for ip in matches:
    if ip.startswith('10.'):
      return ip
  return ''

with open(server_list_file, 'r', encoding='utf-8') as file_obj:
    rows = json.load(file_obj)

compute_ips = []
storage_ips = []
login_ip = ''

for row in rows:
    name = str(row.get('Name', ''))
    status = str(row.get('Status', ''))
    if status != 'ACTIVE':
        continue

    ip = extract_ipv4(row.get('Networks', ''))
    if not ip:
        continue

    if name.startswith(f"{stack_name}-compute_nodes-"):
        compute_ips.append(ip)
    elif name.startswith(f"{stack_name}-storage_nodes-"):
        storage_ips.append(ip)
    elif name.startswith(f"{stack_name}-login_node-") and not login_ip:
        login_ip = ip

compute_ips = sorted(set(compute_ips))[:compute_count]
storage_ips = sorted(set(storage_ips))[:storage_count]

with open('/opt/nfs_client/compute_nodes.txt', 'w', encoding='utf-8') as file_obj:
    file_obj.write('\n'.join(compute_ips) + ('\n' if compute_ips else ''))

with open('/opt/nfs_client/storage_nodes.txt', 'w', encoding='utf-8') as file_obj:
    file_obj.write('\n'.join(storage_ips) + ('\n' if storage_ips else ''))

with open('/opt/nfs_client/login_node.txt', 'w', encoding='utf-8') as file_obj:
    file_obj.write((login_ip + '\n') if login_ip else '')
PY

      FOUND_COMPUTE="$(wc -l < /opt/nfs_client/compute_nodes.txt | tr -d ' ')"
      FOUND_STORAGE="$(wc -l < /opt/nfs_client/storage_nodes.txt | tr -d ' ')"
      LOGIN_IP="$(head -n1 /opt/nfs_client/login_node.txt || true)"

      log_info "Found compute nodes: ${FOUND_COMPUTE}/${COMPUTE_COUNT}"
      log_info "Found storage nodes: ${FOUND_STORAGE}/${STORAGE_COUNT}"
      log_debug "Resolved login IP: ${LOGIN_IP:-<missing>}"

      if [ "$FOUND_COMPUTE" -ge "$COMPUTE_COUNT" ] && [ "$FOUND_STORAGE" -ge "$STORAGE_COUNT" ] && [ -n "$LOGIN_IP" ]; then
        cat /opt/nfs_client/compute_nodes.txt /opt/nfs_client/storage_nodes.txt | sed '/^$/d' | sort -u > /opt/nfs_client/all_nodes.txt
        log_info "All required nodes discovered and listed in /opt/nfs_client/all_nodes.txt"
        return 0
      fi
    else
      log_warning "OpenStack server list call failed on attempt ${attempt}"
    fi
    sleep "$sleep_seconds"
  done

  log_error "Timed out waiting for all nodes to become ACTIVE with 10.x.x.x IPs"
  return 1
}

setup_client_mount() {
  local ip="$1"
  local ok="0"

  for attempt in $(seq 1 12); do
    log_info "Configuring mount on client ${ip} (attempt ${attempt}/12)"
    if timeout 45 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ConnectionAttempts=1 -o BatchMode=yes "cc@${ip}" "sudo bash -lc '
      mkdir -p /opt/nfs_client /mnt/orangefs /mnt/nvme/orangefs_{data,meta}
      grep -q \"${LOGIN_IP}:/opt/shared[[:space:]]\+/opt/nfs_client\" /etc/fstab || echo \"${LOGIN_IP}:/opt/shared    /opt/nfs_client    nfs defaults,_netdev 0 0\" >> /etc/fstab
      grep -q \"tcp://${LOGIN_IP}:3334/orangefs /mnt/orangefs pvfs2\" /etc/pvfs2tab 2>/dev/null || echo \"tcp://${LOGIN_IP}:3334/orangefs /mnt/orangefs pvfs2 defaults,noauto 0 0\" >> /etc/pvfs2tab
      chmod a+r /etc/pvfs2tab
      mount -a || true
      mountpoint -q /opt/nfs_client
    '"; then
      ok="1"
      break
    fi
    log_debug "Mount configuration retry pending for ${ip}"
    sleep 10
  done

  if [ "$ok" = "0" ]; then
    log_error "Failed to configure mount on client ${ip}"
    return 1
  fi
}

configure_all_client_mounts() {
  while IFS= read -r ip; do
    [ -n "$ip" ] && setup_client_mount "$ip"
  done < /opt/nfs_client/all_nodes.txt
}

finalize_post_nodes() {
  log_info "All nodes are up with IPs and NFS mounts configured"
  chown cc:cc /opt/nfs_client/all_nodes.txt /opt/nfs_client/compute_nodes.txt /opt/nfs_client/storage_nodes.txt /opt/nfs_client/login_node.txt
  log_info "Running final cluster configuration script"
}

datacrumbs_post_nodes_main() {
  datacrumbs_post_nodes_setup
  wait_for_nodes_ready
  configure_all_client_mounts
  finalize_post_nodes
}
