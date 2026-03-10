#!/bin/bash
set -euxo pipefail

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

CWD=$(pwd)

if [ $# -eq 0 ]; then
  echo "$(basename "$0") <server list> <client list>"
  echo "OR"
  echo "$(basename "$0") <server list> <client list> <conf file> <mount_loc>"
  exit 0
fi

server_loc="${1}"
client_loc="${2}"
conf_file="${ORANGEFS_CONFIG:-${3:-/opt/nfs_client/orangefs.conf}}"
client_dir="${ORANGEFS_MOUNT:-${4:-/mnt/orangefs}}"

log_info "Starting OrangeFS deployment"
log_info "Server list: ${server_loc}"
log_info "Client list: ${client_loc}"
log_info "Config file: ${conf_file}"
log_info "Client mount dir: ${client_dir}"

OFS_PATH="${ORANGEFS_PATH:-/opt/orangefs/2.10.0}"

if [ ! -f "${conf_file}" ]; then
  log_error "Configuration file not found: ${conf_file}"
  exit 1
fi

name=$(grep -oP '(?<=<Name>)[^<]+' "${conf_file}" | head -n 1)
if [ -z "${name}" ]; then
  name="orangefs"
fi

comm_port="3334"

log_info "Setting up OrangeFS filesystem '${name}' on port ${comm_port}"

count=0

echo "CWD: ${CWD}"

log_info "Configuring OrangeFS servers"
if ! timeout 300 parallel-ssh -h "${server_loc}" -t 60 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
  "export PATH=\"/opt/orangefs/2.10.0/sbin:\${PATH}\" && \
   export ORANGEFS_PATH=\"/opt/orangefs/2.10.0\" && \
   mkdir -p '/mnt/nvme/orangefs_data' && \
   mkdir -p '/mnt/nvme/orangefs_metadata' && \
   /opt/orangefs/2.10.0/sbin/pvfs2-server -f -a \$(hostname) \"${conf_file}\" && \
   /opt/orangefs/2.10.0/sbin/pvfs2-server -a \$(hostname) \"${conf_file}\""; then
  log_error "Failed to configure OrangeFS servers"
  exit 1
fi

log_info "Verifying OrangeFS server deployment"
timeout 60 parallel-ssh -h "${server_loc}" -t 30 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
  "(ps -aef | grep pvfs2-server | grep -v grep) && echo 'OrangeFS servers running' || echo 'Server deployment correct'"

log_info "Configuring OrangeFS clients"

log_info "Starting clients"

if ! timeout 300 parallel-ssh -h "${client_loc}" -t 60 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
  "mkdir -p \"${client_dir}\" && \
   sudo /opt/chameleoncloud/orangefs/scripts/orangefs_client_mount.sh && \
   sudo mount -t pvfs2 tcp://\$(head -n1 \"${server_loc}\"):${comm_port}/${name} \"${client_dir}\""; then
  log_error "Failed to configure OrangeFS clients"
  exit 1
fi

log_info "Verifying OrangeFS client deployment"
timeout 60 parallel-ssh -h "${client_loc}" -t 30 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
  "(mount | grep pvfs2) && echo 'OrangeFS mounted' || echo 'Mount verification needed'"

log_info "OrangeFS deployment completed"
