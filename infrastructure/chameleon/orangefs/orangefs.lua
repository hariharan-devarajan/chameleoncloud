-- OrangeFS module file

whatis("Name: OrangeFS")
whatis("Version: 2.10.0")
whatis("Category: parallel filesystem, HPC")
whatis("Description: OrangeFS user‐ and kernel‐space tools.")
whatis("URL: http://www.orangefs.org")

help([[
OrangeFS 2.10.0 modulefile:

- Loads the required OpenMPI module automatically.
- Sets environment variables for OrangeFS binaries, libraries, man pages.
- Chooses config file based on \$USER:
    * \$HOME/.orangefs.conf if it exists
    * otherwise falls back to /etc/orangefs/orangefs-server.conf

Configure options: --prefix=/opt/nfs_client/orangefs/2.10.0 --with-db-backend=lmdb --enable-shared
Usage:
  module load orangefs/2.10.0
]])

-- Set the installation directory
local prefix = "/opt/nfs_client/orangefs/2.10.0"

-- Define OrangeFS directories
local bin_dir = pathJoin(prefix, "bin")
local sbin_dir = pathJoin(prefix, "sbin")
local lib_dir = pathJoin(prefix, "lib")
local include_dir = pathJoin(prefix, "include")
local etc_dir = pathJoin(prefix, "etc")
local man_dir = pathJoin(prefix, "share", "man")


-- Add OrangeFS directories to PATH, LD_LIBRARY_PATH, CPATH, C_INCLUDE_PATH, ETCPATH, and MANPATH
prepend_path("PATH", bin_dir)
prepend_path("PATH", sbin_dir)
prepend_path("LIBRARY_PATH", lib_dir)
prepend_path("LD_LIBRARY_PATH", lib_dir)
prepend_path("CPATH", include_dir)
prepend_path("C_INCLUDE_PATH", include_dir)
prepend_path("ETCPATH", etc_dir)
prepend_path("MANPATH", man_dir)

-- Set additional flags
local orangefs_flags = string.format("-L %s/lib -I %s/include -lpvfs2", prefix, prefix)

local user = os.getenv("USER") or ""
local home = os.getenv("HOME") or ""
local user_conf = pathJoin(etc_dir, "orangefs.conf")
-- local system_conf = "/etc/orangefs/orangefs-server.conf"
local chosen_conf

--if user ~= "" and home ~= "" and isFile(user_conf) then
chosen_conf = user_conf
-- else
-- chosen_conf = system_conf
-- end

-- Add flags to LD_LIBRARY_PATH and C_INCLUDE_PATH
setenv("ORANGEFS_PATH", prefix, "Path to OrangeFS installation")
setenv("ORANGEFS_FLAGS", orangefs_flags, "Flags needed to compile with OrangeFS")

setenv("ORANGEFS_CONFIG", chosen_conf)

-- Other environment variables

-- Determine cluster-wide defaults (could also source from a central config file)
local cluster_mount = "/mnt/ssd/" .. user .. "/orangefs"
local cluster_data_dir = "/mnt/nvme/" .. user .. "/orangefs/data"
local cluster_meta_dir = "/mnt/nvme/" .. user .. "/orangefs/metadata"

-- Let users or admins override these before module load by exporting env vars
local mount_dir = os.getenv("ORANGEFS_MOUNT") or cluster_mount
local data_dir = os.getenv("ORANGEFS_DATA_DIR") or cluster_data_dir
local meta_dir = os.getenv("ORANGEFS_META_DIR") or cluster_meta_dir

-- Export into the user’s environment
setenv("ORANGEFS_MOUNT", mount_dir)
setenv("ORANGEFS_DATA_DIR", data_dir)
setenv("ORANGEFS_META_DIR", meta_dir)

-- MPI-IO hints
setenv("MPIIO_HINTS", "romio_fs_pvfs2")

-- Inform user
if mode() == "load" then
	LmodMessage("OrangeFS 2.10.0 loaded; using config: " .. chosen_conf)
	LmodMessage("OrangeFS mount point: " .. mount_dir)
	LmodMessage("OrangeFS data directory: " .. data_dir)
	LmodMessage("OrangeFS metadata directory: " .. meta_dir)
elseif mode() == "unload" then
	LmodMessage("OrangeFS 2.10.0 unloaded.")
end

family("orangefs")
-- Modprobe the kernel module for OrangeFS 5.15 with sudo
execute({
	cmd = "sudo modprobe orangefs",
	modeA = { "load" },
	mode = "silent",
})
