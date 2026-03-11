#!/bin/bash
# orangefs_functions.sh - Stateless OrangeFS installation and deployment
# All configuration passed via function arguments


DEFAULT_SCRIPT_ROOT=$(cd "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")" && pwd)


# Source common logging library if not already sourced
if ! declare -f log_info &>/dev/null; then
  source "${SCRIPT_ROOT}/orangefs/scripts/lib/logging.sh"
fi

# Install OrangeFS dependencies
install_orangefs_dependencies() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential wget tar \
    liblmdb-dev libssl-dev libattr1-dev libfuse-dev pkg-config environment-modules lmod
  log_info "OrangeFS dependencies installed"
}

# Install OrangeFS from source
# Args: version (default 2.10.0), prefix (default /opt/nfs_client/orangefs/{version})
install_orangefs() {
  local version="${1:-2.10.0}"
  local prefix="${2:-/opt/nfs_client/orangefs/${version}}"
  local pkgname="orangefs"
  local ofsurl="https://github.com/waltligon/orangefs/releases/download/v.${version}/orangefs-${version}.tar.gz"
  local temp_dir="/tmp/orangefs-install"

  if [ -d "${prefix}/sbin" ] && [ -f "${prefix}/sbin/pvfs2-server" ]; then
    log_info "OrangeFS ${version} already installed at ${prefix}"
    return 0
  fi

  mkdir -p "${temp_dir}"
  cd "${temp_dir}"

  wget -q "${ofsurl}" -O "${pkgname}-${version}.tar.gz"
  tar zxf "${pkgname}-${version}.tar.gz"
  cd "${pkgname}-${version}"

  ./prepare
  ./configure --prefix="${prefix}" --enable-shared --with-db-backend=lmdb --enable-fast --enable-threaded-kmod-helper
  make
  make install

  mkdir -p "${prefix}/etc"
  chmod -R 755 "${prefix}"

  log_info "OrangeFS ${version} installed to ${prefix}"
  rm -rf "${temp_dir}"
}

# Resolve OrangeFS hostname from IP (with fallback to IP if unresolvable)
# Args: node_ref (IP or hostname), ssh_timeout (default 20s)
resolve_orangefs_host_from_ip() {
  local node_ref="$1"
  local ssh_timeout="${2:-20}"
  local host_name

  if [[ ! "${node_ref}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${node_ref}"
    return 0
  fi

  host_name="$(getent hosts "${node_ref}" | awk '{print $2; exit}' || true)"
  if [ -n "${host_name}" ]; then
    echo "${host_name}"
    return 0
  fi

  host_name="$(timeout "${ssh_timeout}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "cc@${node_ref}" "hostname -s" </dev/null 2>/dev/null || true)"
  if [ -n "${host_name}" ]; then
    echo "${host_name}"
    return 0
  fi

  log_error "Could not resolve hostname for ${node_ref}"
  return 1
}

# Setup OrangeFS lmod modulefile
# Args: version (default 2.10.0), prefix (default /opt/nfs_client/orangefs/{version}), nfs_mount_point (default /opt/nfs_client)
setup_orangefs_module() {
  local version="${1:-2.10.0}"
  local prefix="${2:-/opt/nfs_client/orangefs/${version}}"
  local nfs_mount_point="${3:-/opt/nfs_client}"
  local module_dir="${nfs_mount_point}/apps/modulefiles"

  mkdir -p "${module_dir}"

  cat > "${module_dir}/orangefs.lua" << LUAEOF
-- OrangeFS module file

whatis("Name: OrangeFS")
whatis("Version: ${version}")
whatis("Category: parallel filesystem, HPC")
whatis("Description: OrangeFS user- and kernel-space tools.")
whatis("URL: http://www.orangefs.org")

help([[
OrangeFS ${version} modulefile:

- Sets environment variables for OrangeFS binaries, libraries, man pages.
- Configures paths for OrangeFS ${version} installation.

Configure options: --prefix=${prefix} --with-db-backend=lmdb --enable-shared
Usage:
  module load orangefs
]])

local prefix = "${prefix}"

local bin_dir = pathJoin(prefix, "bin")
local sbin_dir = pathJoin(prefix, "sbin")
local lib_dir = pathJoin(prefix, "lib")
local include_dir = pathJoin(prefix, "include")
local etc_dir = pathJoin(prefix, "etc")
local man_dir = pathJoin(prefix, "share", "man")

prepend_path("PATH", bin_dir)
prepend_path("PATH", sbin_dir)
prepend_path("LIBRARY_PATH", lib_dir)
prepend_path("LD_LIBRARY_PATH", lib_dir)
prepend_path("CPATH", include_dir)
prepend_path("C_INCLUDE_PATH", include_dir)
prepend_path("ETCPATH", etc_dir)
prepend_path("MANPATH", man_dir)

local orangefs_flags = string.format("-L %s/lib -I %s/include -lpvfs2", prefix, prefix)

setenv("ORANGEFS_PATH", prefix, "Path to OrangeFS installation")
setenv("ORANGEFS_FLAGS", orangefs_flags, "Flags needed to compile with OrangeFS")

local mount_dir = os.getenv("ORANGEFS_MOUNT") or "/mnt/orangefs"
local data_dir = os.getenv("ORANGEFS_DATA_DIR") or "/mnt/nvme/orangefs_data"
local meta_dir = os.getenv("ORANGEFS_META_DIR") or "/mnt/nvme/orangefs_metadata"

setenv("ORANGEFS_MOUNT", mount_dir)
setenv("ORANGEFS_DATA_DIR", data_dir)
setenv("ORANGEFS_META_DIR", meta_dir)

setenv("MPIIO_HINTS", "romio_fs_pvfs2")

if mode() == "load" then
  LmodMessage("OrangeFS ${version} loaded")
  LmodMessage("OrangeFS mount point: " .. mount_dir)
  LmodMessage("OrangeFS data directory: " .. data_dir)
  LmodMessage("OrangeFS metadata directory: " .. meta_dir)
elseif mode() == "unload" then
  LmodMessage("OrangeFS ${version} unloaded.")
end

family("orangefs")

execute({
  cmd = "sudo modprobe orangefs",
  modeA = { "load" },
  mode = "silent",
})
LUAEOF

  mkdir -p /etc/profile.d
  echo "export MODULEPATH=\"${module_dir}:\${MODULEPATH}\"" > /etc/profile.d/orangefs-module.sh
  chmod 644 /etc/profile.d/orangefs-module.sh

  log_info "OrangeFS module configured at ${module_dir}/orangefs.lua"
}

# Setup OrangeFS directories with proper ownership
# Args: target_user, data_dir, metadata_dir, mount_dir, log_dir
setup_orangefs_directories() {
  local target_user="$1"
  local data_dir="${2:-/mnt/nvme/orangefs_data}"
  local metadata_dir="${3:-/mnt/nvme/orangefs_metadata}"
  local mount_dir="${4:-/mnt/orangefs}"
  local log_dir="${5:-/opt/orangefs/logs}"

  mkdir -p "$data_dir" "$metadata_dir" "$mount_dir" "$log_dir"
  chown -R "${target_user}:${target_user}" "$data_dir" "$metadata_dir" "$mount_dir" "$log_dir"
  chmod 755 "$data_dir" "$metadata_dir" "$mount_dir" "$log_dir"

  log_info "OrangeFS directories created and owned by ${target_user}"
  log_debug "  Data directory:     ${data_dir}"
  log_debug "  Metadata directory: ${metadata_dir}"
  log_debug "  Mount directory:    ${mount_dir}"
  log_debug "  Log directory:      ${log_dir}"
}

# Configure OrangeFS firewall rules
# Args: ports_csv (e.g., "3334/tcp,3335/tcp"), optional: firewall_cmd_path
configure_orangefs_firewall() {
  local ports_csv="${1:-3334/tcp,3335/tcp}"
  local firewall_cmd="${2:-firewall-cmd}"
  local failed=0
  local ports=()
  local port

  run_firewall_cmd() {
    if "$firewall_cmd" "$@" >/dev/null 2>&1; then
      return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n "$firewall_cmd" "$@" >/dev/null 2>&1; then
      return 0
    fi

    return 1
  }

  run_systemctl_cmd() {
    if systemctl "$@" >/dev/null 2>&1; then
      return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n systemctl "$@" >/dev/null 2>&1; then
      return 0
    fi

    return 1
  }

  apply_port_rule() {
    local port="$1"

    if run_firewall_cmd --permanent --add-port="${port}"; then
      return 0
    fi

    if run_firewall_cmd --add-port="${port}"; then
      log_warning "Applied runtime-only firewall rule for ${port}"
      return 0
    fi

    return 1
  }

  if ! command -v "$firewall_cmd" >/dev/null 2>&1; then
    log_error "firewall-cmd not available; OrangeFS firewall setup is mandatory"
    return 1
  fi

  if ! run_systemctl_cmd is-active --quiet firewalld; then
    log_warning "firewalld is not active; attempting to start it"
    run_systemctl_cmd enable firewalld || true
    run_systemctl_cmd start firewalld || true
  fi

  IFS=',' read -r -a ports <<< "${ports_csv}"
  for port in "${ports[@]}"; do
    port=$(echo "$port" | xargs)  # trim whitespace
    [ -z "$port" ] && continue
    if ! apply_port_rule "$port"; then
      log_warning "Failed to add port ${port}"
      failed=1
    fi
  done

  if ! run_firewall_cmd --reload; then
    log_warning "Failed to reload firewall configuration; attempting firewalld restart"
    run_systemctl_cmd restart firewalld || true

    if run_firewall_cmd --reload; then
      log_info "Firewall reload succeeded after restart"
    else
      log_warning "Firewall reload still failing after restart"
      failed=1
    fi
  fi

  if [ "$failed" -eq 0 ]; then
    log_info "OrangeFS firewall rules configured for ports: ${ports_csv}"
  else
    log_warning "OrangeFS firewall configuration partially applied after retries"
  fi

  return 0
}

# Generate OrangeFS configuration via expect script
# Args: storage_ips_file, config_file, ofs_path, data_dir, metadata_dir, comm_port, fs_name, log_path
generate_orangefs_config_expect() {
  local storage_ips_file="$1"
  local config_file="$2"
  local ofs_path="${3:-/opt/nfs_client/orangefs/2.10.0}"
  local data_dir="${4:-/mnt/nvme/orangefs_data}"
  local metadata_dir="${5:-/mnt/nvme/orangefs_metadata}"
  local comm_port="${6:-3334}"
  local fs_name="${7:-orangefs}"
  local log_path="${8:-/opt/orangefs/logs/orangefs.log}"

  local io_servers
  local meta_servers
  local node_ref
  local host_name

  if [ ! -f "${storage_ips_file}" ]; then
    log_error "Storage IP list file not found: ${storage_ips_file}"
    return 1
  fi

  if ! command -v expect >/dev/null 2>&1; then
    log_error "expect is required but not installed"
    return 1
  fi

  if [ ! -x "${ofs_path}/bin/pvfs2-genconfig" ]; then
    log_error "pvfs2-genconfig not found at ${ofs_path}/bin/pvfs2-genconfig"
    return 1
  fi

  io_servers=""
  while IFS= read -r node_ref; do
    [ -z "${node_ref}" ] && continue
    host_name="$(resolve_orangefs_host_from_ip "${node_ref}")" || return 1
    if [ -z "${io_servers}" ]; then
      io_servers="${host_name}"
    else
      io_servers="${io_servers},${host_name}"
    fi
  done < "${storage_ips_file}"

  meta_servers="${io_servers}"

  if [ -z "${io_servers}" ]; then
    log_error "No IPs found in ${storage_ips_file}"
    return 1
  fi

  mkdir -p "$(dirname "${config_file}")"
  mkdir -p "${log_path%/*}"

  log_info "Generating OrangeFS configuration with pvfs2-genconfig"
  if ! IO_SERVERS="${io_servers}" META_SERVERS="${meta_servers}" OFS_PATH="${ofs_path}" \
    DATA_DIR="${data_dir}" META_DIR="${metadata_dir}" COMM_PORT="${comm_port}" FS_NAME="${fs_name}" \
    CONFIG_FILE="${config_file}" LOG_PATH="${log_path}" expect <<'EOF'
set timeout 120

spawn $env(OFS_PATH)/bin/pvfs2-genconfig \
  --protocol tcp \
  --tcpport $env(COMM_PORT) \
  --storage $env(DATA_DIR) \
  --metadata $env(META_DIR) \
  --fsname $env(FS_NAME) \
  --ioservers $env(IO_SERVERS) \
  --metaservers $env(META_SERVERS) \
  $env(CONFIG_FILE) \
  --logfile $env(LOG_PATH)

expect {
  -re {\* Would you like to verify server list .*} {
    send "y\r"
    exp_continue
  }
  -re {\* Does this look ok .*} {
    send "y\r"
    exp_continue
  }
  eof
}

set result [wait]
exit [lindex $result 3]
EOF
  then
    log_error "Failed to generate OrangeFS config with expect"
    return 1
  fi

  chmod 644 "${config_file}"
  log_info "OrangeFS configuration generated at ${config_file}"
}

# Create OrangeFS server and client node lists from IP addresses
# Args: storage_ips_file, all_nodes_file, server_list_file, client_list_file, login_node_file, target_user
create_orangefs_node_lists() {
  local storage_ips_file="$1"
  local all_nodes_file="$2"
  local server_list_file="$3"
  local client_list_file="$4"
  local login_node_file="${5:-/opt/nfs_client/login_node.txt}"
  local target_user="${6:-cc}"
  local node_ref
  local host_name
  local login_ref

  log_info "Creating OrangeFS node lists"

  : > "$server_list_file"
  while IFS= read -r node_ref; do
    [ -z "${node_ref}" ] && continue
    host_name="$(resolve_orangefs_host_from_ip "${node_ref}")" || return 1
    echo "${host_name}" >> "$server_list_file"
  done < "$storage_ips_file"

  : > "$client_list_file"
  while IFS= read -r node_ref; do
    [ -z "${node_ref}" ] && continue
    host_name="$(resolve_orangefs_host_from_ip "${node_ref}")" || return 1
    echo "${host_name}" >> "$client_list_file"
  done < "$all_nodes_file"

  login_ref=""
  if [ -f "${login_node_file}" ]; then
    login_ref="$(head -n1 "${login_node_file}" || true)"
  fi
  if [ -n "${login_ref}" ]; then
    host_name="$(resolve_orangefs_host_from_ip "${login_ref}")" || return 1
    echo "${host_name}" >> "$client_list_file"
  fi

  sort -u "$server_list_file" -o "$server_list_file"
  sort -u "$client_list_file" -o "$client_list_file"

  chown "${target_user}:${target_user}" "$server_list_file" "$client_list_file"

  log_info "OrangeFS server list: ${server_list_file}"
  log_info "OrangeFS client list: ${client_list_file}"
}

# Install parallel-ssh package
install_parallel_ssh() {
  log_info "Installing parallel-ssh on login node"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y pssh || DEBIAN_FRONTEND=noninteractive apt-get install -y parallel-ssh
}

# Install expect package
install_expect_package() {
  if command -v expect >/dev/null 2>&1; then
    log_info "expect already installed"
    return 0
  fi

  log_info "Installing expect package"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y expect
}

# Deploy OrangeFS servers
# Args: server_list_file, config_file, ofs_path, script_root
deploy_orangefs_servers() {
  local server_list_file="$1"
  local config_file="$2"
  local ofs_path="${3:-/opt/nfs_client/orangefs/2.10.0}"
  local script_root="${4:-${DEFAULT_SCRIPT_ROOT}}"

  log_info "Configuring OrangeFS servers"
  if ! timeout 300 parallel-ssh -P -h "${server_list_file}" -t 60 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "log_dir='/tmp/orangefs/logs' && \
     mkdir -p \"\${log_dir}\" && \
     log_file=\"\${log_dir}/orangefs-server-block-\$(hostname).log\" && \
     { \
       set -x && \
       export PATH=\"${ofs_path}/sbin:\${PATH}\" && \
       export ORANGEFS_PATH=\"${ofs_path}\" && \
       mkdir -p '/mnt/nvme/orangefs_data' && \
       mkdir -p '/mnt/nvme/orangefs_metadata' && \
       mkdir -p '/mnt/orangefs' && \
       mkdir -p '/opt/orangefs/logs' && \
       chown -R cc:cc /mnt/nvme/orangefs_data /mnt/nvme/orangefs_metadata /mnt/orangefs /opt/orangefs || true && \
       rm -rf /mnt/nvme/orangefs_data/* /mnt/nvme/orangefs_metadata/* && \
       rm -f \"\${log_dir}/orangefs.log\" && \
       ${ofs_path}/sbin/pvfs2-server -f -a \$(hostname) \"${config_file}\" && \
       ${ofs_path}/sbin/pvfs2-server -a \$(hostname) \"${config_file}\";
     } > \"\${log_file}\" 2>&1"; then
    log_error "Failed to configure OrangeFS servers"
    return 1
  fi

  log_info "Verifying OrangeFS server deployment"
  timeout 60 parallel-ssh -P -h "${server_list_file}" -t 30 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "(ps -aef | grep pvfs2-server | grep -v grep) && echo 'OrangeFS servers running' || echo 'Server deployment verification needed'"

  log_info "OrangeFS servers deployed"
}

# Deploy OrangeFS clients
# Args: client_list_file, server_list_file, client_dir, fs_name, comm_port, script_root
deploy_orangefs_clients() {
  local client_list_file="$1"
  local server_list_file="$2"
  local client_dir="${3:-/mnt/orangefs}"
  local fs_name="${4:-orangefs}"
  local comm_port="${5:-3334}"
  local script_root="${6:-${DEFAULT_SCRIPT_ROOT}}"

  log_info "Configuring OrangeFS clients"
  if ! timeout 300 parallel-ssh -P -h "${client_list_file}" -t 60 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "log_dir='/tmp/orangefs/logs' && \
     mkdir -p \"\${log_dir}\" && \
     log_file=\"\${log_dir}/orangefs-client-block-\$(hostname).log\" && \
     { \
       set -x && \
       mkdir -p \"${client_dir}\" && \
       sudo ${script_root}/orangefs/scripts/orangefs_client_mount.sh && \
       sudo mount -t pvfs2 tcp://\$(head -n1 \"${server_list_file}\"):${comm_port}/${fs_name} \"${client_dir}\" && \
       echo  \$(hostname) >  \"${client_dir}/\$(hostname).txt\"; \
     } > \"\${log_file}\" 2>&1"; then
    log_error "Failed to configure OrangeFS clients"
    return 1
  fi

  log_info "Verifying OrangeFS client deployment"
  timeout 60 parallel-ssh -P -h "${client_list_file}" -t 30 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "(mount | grep pvfs2) && echo 'OrangeFS mounted' || echo 'Mount verification needed'"

  log_info "OrangeFS clients deployed"
}

# Complete OrangeFS cluster deployment orchestration
# Args: server_list_file, client_list_file, config_file, client_dir, comm_port, ofs_path, script_root
deploy_orangefs_cluster() {
  local server_list_file="$1"
  local client_list_file="$2"
  local config_file="${3:-/opt/nfs_client/orangefs.conf}"
  local client_dir="${4:-/mnt/orangefs}"
  local comm_port="${5:-3334}"
  local ofs_path="${6:-/opt/nfs_client/orangefs/2.10.0}"
  local script_root="${7:-${DEFAULT_SCRIPT_ROOT}}"

  if [ ! -f "${config_file}" ]; then
    log_error "Configuration file not found: ${config_file}"
    return 1
  fi

  local fs_name
  fs_name="$(grep -oP '(?<=<Name>)[^<]+' "${config_file}" | head -n 1 || true)"
  if [ -z "${fs_name}" ]; then
    fs_name="orangefs"
  fi

  log_info "Starting OrangeFS cluster deployment"
  log_info "Server list: ${server_list_file}"
  log_info "Client list: ${client_list_file}"
  log_info "Config file: ${config_file}"
  log_info "Mount directory: ${client_dir}"
  log_info "Filesystem name: ${fs_name}"

  deploy_orangefs_servers "${server_list_file}" "${config_file}" "${ofs_path}" "${script_root}"
  deploy_orangefs_clients "${client_list_file}" "${server_list_file}" "${client_dir}" "${fs_name}" "${comm_port}" "${script_root}"

  log_info "OrangeFS cluster deployment completed"
}
