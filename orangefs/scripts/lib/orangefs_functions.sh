#!/bin/bash
set -euxo pipefail

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

resolve_orangefs_host_from_ip() {
  local node_ref="$1"
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

  host_name="$(timeout 20 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "cc@${node_ref}" "hostname -s" </dev/null 2>/dev/null || true)"
  if [ -n "${host_name}" ]; then
    echo "${host_name}"
    return 0
  fi

  log_error "Could not resolve hostname for ${node_ref}"
  return 1
}

install_orangefs_dependencies() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential wget tar \
    liblmdb-dev libssl-dev libattr1-dev libfuse-dev pkg-config  environment-modules lmod
}

install_orangefs() {
  local version="2.10.0"
  local prefix="/opt/shared/orangefs/${version}"
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

setup_orangefs_module() {
  local version="2.10.0"
  local prefix="/opt/nfs_client/orangefs/${version}"
  local module_dir="/opt/nfs_client/apps/modulefiles"

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
  echo 'export MODULEPATH="/opt/nfs_client/apps/modulefiles:${MODULEPATH}"' > /etc/profile.d/orangefs-module.sh
  chmod 644 /etc/profile.d/orangefs-module.sh

  echo "[$(date -Is)] STATUS=SUCCESS OrangeFS module configured"
}

setup_orangefs_directories() {
  mkdir -p /mnt/nvme/orangefs_data
  mkdir -p /mnt/nvme/orangefs_metadata
  mkdir -p /mnt/orangefs
  mkdir -p /opt/orangefs/logs

  chown -R cc:cc /mnt/nvme
  chown -R cc:cc /mnt/nvme
  chown -R cc:cc /mnt/orangefs
  chown -R cc:cc /opt/orangefs/logs

  STORAGE_SERVER_IP="$(head -n1 /opt/nfs_client/orangefs_server_list.txt || true)"
  echo "tcp://${STORAGE_SERVER_IP}:3334/orangefs /mnt/orangefs pvfs2 defaults,noauto 0 0" > /etc/pvfs2tab

  chmod a+r /etc/pvfs2tab
  echo "[$(date -Is)] STATUS=SUCCESS OrangeFS directories created"
}

configure_orangefs_firewall() {
  local failed=0

  run_firewall_cmd() {
    if firewall-cmd "$@" >/dev/null 2>&1; then
      return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n firewall-cmd "$@" >/dev/null 2>&1; then
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

  apply_orangefs_port_rule() {
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

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    log_error "firewall-cmd not available; OrangeFS firewall setup is mandatory"
    return 1
  fi

  if ! run_systemctl_cmd is-active --quiet firewalld; then
    log_warning "firewalld is not active; attempting to start it"
    run_systemctl_cmd enable firewalld || true
    run_systemctl_cmd start firewalld || true
  fi

  if ! apply_orangefs_port_rule "3334/tcp"; then
    log_warning "Failed to add port 3334/tcp"
    failed=1
  fi

  if ! apply_orangefs_port_rule "3335/tcp"; then
    log_warning "Failed to add port 3335/tcp"
    failed=1
  fi

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
    log_info "OrangeFS firewall rules configured successfully"
  else
    log_warning "OrangeFS firewall rules were partially applied after retries"
  fi

  return 0
}


# TODO: replace with except script.
generate_orangefs_config() {
  local compute_ips_file="$1"
  local config_file="$2"
  local node_ref
  local host_name

  log_info "Generating OrangeFS configuration at ${config_file}"

  local data_dir="/mnt/nvme/orangefs_data"
  local meta_dir="/mnt/nvme/orangefs_metadata"
  local mount_dir="/mnt/orangefs"
  local comm_port="3334"
  local io_port="3335"
  local fs_name="orangefs"

  {
    echo "<OrangeFSConfig>"
    echo "  <Filesystem>"
    echo "    <Name>${fs_name}</Name>"
    echo "    <ID>1</ID>"
    echo "  </Filesystem>"
    echo "  <ServerOptions>"
    echo "    <Communication>TCP</Communication>"
    echo "    <Port>${comm_port}</Port>"
    echo "  </ServerOptions>"
    echo "  <DataHandleOptions>"
    echo "    <DataStorageSpace>${data_dir}</DataStorageSpace>"
    echo "    <MetadataStorageSpace>${meta_dir}</MetadataStorageSpace>"
    echo "  </DataHandleOptions>"
    echo "  <ClientOptions>"
    echo "    <Communication>TCP</Communication>"
    echo "    <Port>${io_port}</Port>"
    echo "    <MountPoint>${mount_dir}</MountPoint>"
    echo "  </ClientOptions>"
    echo "  <StorageServers>"

    while IFS= read -r node_ref; do
      if [ -n "$node_ref" ]; then
        host_name="$(resolve_orangefs_host_from_ip "${node_ref}")" || return 1
        echo "    <Server>"
        echo "      <HostName>${host_name}</HostName>"
        echo "      <DataStorageSpace>${data_dir}</DataStorageSpace>"
        echo "      <MetadataStorageSpace>${meta_dir}</MetadataStorageSpace>"
        echo "    </Server>"
      fi
    done <"$compute_ips_file"

    echo "  </StorageServers>"
    echo "</OrangeFSConfig>"
  } >"$config_file"
  chown cc:cc "${config_file}"
  log_info "OrangeFS configuration generated at ${config_file}"
}

generate_orangefs_config_expect() {
  local compute_ips_file="$1"
  local config_file="$2"
  local ofs_path="${3:-/opt/nfs_client/orangefs/2.10.0}"

  local data_dir="/mnt/nvme/orangefs_data"
  local meta_dir="/mnt/nvme/orangefs_metadata"
  local comm_port="3334"
  local fs_name="orangefs"
  local log_path="/opt/orangefs/logs/orangefs.log"
  local io_servers
  local meta_servers
  local node_ref
  local host_name

  if [ ! -f "${compute_ips_file}" ]; then
    log_error "Compute IP list file not found: ${compute_ips_file}"
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
  done < "${compute_ips_file}"

  meta_servers="${io_servers}"

  if [ -z "${io_servers}" ]; then
    log_error "No IPs found in ${compute_ips_file}"
    return 1
  fi

  mkdir -p "$(dirname "${config_file}")"
  mkdir -p "${log_path}"

  log_info "Generating OrangeFS configuration with pvfs2-genconfig and expect"
  if ! IO_SERVERS="${io_servers}" META_SERVERS="${meta_servers}" OFS_PATH="${ofs_path}" \
    DATA_DIR="${data_dir}" META_DIR="${meta_dir}" COMM_PORT="${comm_port}" FS_NAME="${fs_name}" \
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

  chown cc:cc "${config_file}"
  log_info "OrangeFS configuration generated at ${config_file}"
}

create_orangefs_node_lists() {
  local storage_ips_file="$1"
  local all_nodes_file="$2"
  local server_list_file="$3"
  local client_list_file="$4"
  local login_node_file="${5:-/opt/nfs_client/login_node.txt}"
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

  login_ref="${LOGIN_IP:-}"
  if [ -z "${login_ref}" ] && [ -f "${login_node_file}" ]; then
    login_ref="$(head -n1 "${login_node_file}" || true)"
  fi
  if [ -n "${login_ref}" ]; then
    host_name="$(resolve_orangefs_host_from_ip "${login_ref}")" || return 1
    echo "${host_name}" >> "$client_list_file"
  fi

  sort -u "$server_list_file" -o "$server_list_file"
  sort -u "$client_list_file" -o "$client_list_file"

  chown cc:cc "$server_list_file" "$client_list_file"

  log_info "OrangeFS server list: ${server_list_file}"
  log_info "OrangeFS client list: ${client_list_file}"
}

install_parallel_ssh() {
  log_info "Installing parallel-ssh on login node"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y pssh || DEBIAN_FRONTEND=noninteractive apt-get install -y parallel-ssh
}

install_expect_package() {
  if command -v expect >/dev/null 2>&1; then
    log_info "expect already installed"
    return 0
  fi

  log_info "Installing expect package"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y expect
}

deploy_orangefs_servers() {
  local server_loc="$1"
  local conf_file="$2"
  local ofs_path="${3:-/opt/nfs_client/orangefs/2.10.0}"

  log_info "Configuring OrangeFS servers"
  if ! timeout 300 parallel-ssh -P -h "${server_loc}" -t 60 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
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
       ${ofs_path}/sbin/pvfs2-server -f -a \$(hostname) \"${conf_file}\" && \
       ${ofs_path}/sbin/pvfs2-server -a \$(hostname) \"${conf_file}\" && \
       source ${SCRIPT_ROOT}/lib/orangefs_functions.sh && configure_orangefs_firewall; \
     } > \"\${log_file}\" 2>&1"; then
    log_error "Failed to configure OrangeFS servers"
    return 1
  fi

  log_info "Verifying OrangeFS server deployment"
  timeout 60 parallel-ssh -P -h "${server_loc}" -t 30 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "(ps -aef | grep pvfs2-server | grep -v grep) && echo 'OrangeFS servers running' || echo 'Server deployment verification needed'"
}

deploy_orangefs_clients() {
  local client_loc="$1"
  local server_loc="$2"
  local client_dir="$3"
  local fs_name="$4"
  local comm_port="${5:-3334}"

  log_info "Configuring OrangeFS clients"
  if ! timeout 300 parallel-ssh -P -h "${client_loc}" -t 60 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "log_dir='/tmp/orangefs/logs' && \
     mkdir -p \"\${log_dir}\" && \
     log_file=\"\${log_dir}/orangefs-client-block-\$(hostname).log\" && \
     { \
       set -x && \
       mkdir -p \"${client_dir}\" && \
       sudo /opt/nfs_client/chameleoncloud/orangefs/scripts/orangefs_client_mount.sh && \
       sudo mount -t pvfs2 tcp://\$(head -n1 \"${server_loc}\"):${comm_port}/${fs_name} \"${client_dir}\" && \
       echo  \$(hostname) >  \"${client_dir}/\$(hostname).txt\"; \
     } > \"\${log_file}\" 2>&1"; then
    log_error "Failed to configure OrangeFS clients"
    return 1
  fi

  log_info "Verifying OrangeFS client deployment"
  timeout 60 parallel-ssh -P -h "${client_loc}" -t 30 -O "StrictHostKeyChecking=no" -O "BatchMode=yes" \
    "(mount | grep pvfs2) && echo 'OrangeFS mounted' || echo 'Mount verification needed'"
}

deploy_orangefs_cluster() {
  local server_loc="$1"
  local client_loc="$2"
  local conf_file="${3:-/opt/nfs_client/orangefs.conf}"
  local client_dir="${4:-/mnt/orangefs}"
  local comm_port="${5:-3334}"
  local ofs_path="${6:-/opt/nfs_client/orangefs/2.10.0}"
  local fs_name

  if [ ! -f "${conf_file}" ]; then
    log_error "Configuration file not found: ${conf_file}"
    return 1
  fi

  fs_name="$(grep -oP '(?<=<Name>)[^<]+' "${conf_file}" | head -n 1 || true)"
  if [ -z "${fs_name}" ]; then
    fs_name="orangefs"
  fi

  log_info "Starting OrangeFS deployment"
  log_info "Server list: ${server_loc}"
  log_info "Client list: ${client_loc}"
  log_info "Config file: ${conf_file}"
  log_info "Client mount dir: ${client_dir}"
  log_info "Filesystem name: ${fs_name}"

  deploy_orangefs_servers "${server_loc}" "${conf_file}" "${ofs_path}"
  deploy_orangefs_clients "${client_loc}" "${server_loc}" "${client_dir}" "${fs_name}" "${comm_port}"

  log_info "OrangeFS deployment completed"
}