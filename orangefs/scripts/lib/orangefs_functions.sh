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

install_orangefs_dependencies() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential wget tar \
    liblmdb-dev libssl-dev libattr1-dev libfuse-dev pkg-config
}

install_orangefs() {
  local version="2.10.0"
  local prefix="/opt/orangefs/${version}"
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
  local prefix="/opt/orangefs/${version}"
  local module_dir="/opt/apps/modulefiles"

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
  echo 'export MODULEPATH="/opt/apps/modulefiles:${MODULEPATH}"' > /etc/profile.d/orangefs-module.sh
  chmod 644 /etc/profile.d/orangefs-module.sh

  echo "[$(date -Is)] STATUS=SUCCESS OrangeFS module configured"
}

setup_orangefs_directories() {
  mkdir -p /mnt/nvme/orangefs_data
  mkdir -p /mnt/nvme/orangefs_metadata
  mkdir -p /mnt/orangefs

  chown -R cc:cc /mnt/nvme/orangefs_data
  chown -R cc:cc /mnt/nvme/orangefs_metadata
  chown -R cc:cc /mnt/orangefs

  echo "[$(date -Is)] STATUS=SUCCESS OrangeFS directories created"
}

configure_orangefs_firewall() {
  local failed=0

  if ! firewall-cmd --permanent --add-port=3334/tcp 2>/dev/null; then
    log_warning "Failed to add port 3334/tcp; firewall may not be active"
    failed=1
  fi

  if ! firewall-cmd --permanent --add-port=3335/tcp 2>/dev/null; then
    log_warning "Failed to add port 3335/tcp; firewall may not be active"
    failed=1
  fi

  if ! firewall-cmd --reload 2>/dev/null; then
    log_warning "Failed to reload firewall configuration"
    failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    log_info "OrangeFS firewall rules configured successfully"
  else
    log_warning "Some firewall rules may not have been applied"
  fi
}
