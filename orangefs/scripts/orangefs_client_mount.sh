#!/bin/bash
set -eux

log_with_level() {
  local level="$1"
  shift
  echo "[$(date -Is)] STATUS=${level} $*"
}

log_info() {
  log_with_level "INFO" "$@"
}

log_warning() {
  log_with_level "WARNING" "$@"
}

log_error() {
  log_with_level "ERROR" "$@"
}

log_debug() {
  log_with_level "DEBUG" "$@"
}

log_info "Loading OrangeFS kernel module"
sudo modprobe orangefs

log_info "Loading Lmod environment"
source /etc/profile.d/modules.sh

log_info "Loading OrangeFS module"
module load orangefs

OFS_PATH="${ORANGEFS_PATH:-/opt/nfs_client/orangefs/2.10.0}"

log_info "Starting OrangeFS pvfs2-client"
"${OFS_PATH}/sbin/pvfs2-client" -p "${OFS_PATH}/sbin/pvfs2-client-core"

log_info "OrangeFS client started successfully"
