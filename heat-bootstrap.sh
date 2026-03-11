#!/bin/bash
set -eux

# Setup runtime and logging directories first
mkdir -p /var/run/datacrumbs
mkdir -p /var/log/datacrumbs
chmod 755 /var/run/datacrumbs
chmod 755 /var/log/datacrumbs

# Create main Heat bootstrap log
HEAT_LOG="/var/log/datacrumbs/heat-bootstrap.log"
touch "$HEAT_LOG"
chmod 644 "$HEAT_LOG"
exec > >(tee -a "$HEAT_LOG") 2>&1

echo "[$(date -Is)] Heat bootstrap started"

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y git

REPO_URL="https://github.com/hariharan-devarajan/chameleoncloud.git"
REPO_REF="feature/organization"
export LOG_LEVEL="INFO"
TARGET_USER="cc"
SCRIPT_ROOT="/opt/shared/chameleoncloud"

if [ -d "$SCRIPT_ROOT/.git" ]; then
  git -C "$SCRIPT_ROOT" pull || true
else
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SCRIPT_ROOT"
fi
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$SCRIPT_ROOT" || true
echo "[$(date -Is)] Repository cloned successfully"


# Source common logging library
source "$SCRIPT_ROOT/orangefs/scripts/lib/logging.sh"
log_startup_info
enable_trace_mode

export LOG_LEVEL="INFO"
export TARGET_USER="cc"
export IS_LOGIN_NODE="1"
export IS_COMPUTE_NODE="0"
export IS_STORAGE_NODE="0"
export PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPcSrY7fM9Xb8hFtxgkTn1qUwiLPTV/akKK3FBONFCVr cc@test"
export PRIVATE_KEY="b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUxOQAAACD3Eq2O3zPV2/IRbcYJE59alMIiz01f2pCitxQTjRQlawAAAKDtPNHw7TzR8AAAAAtzc2gtZWQyNTUxOQAAACD3Eq2O3zPV2/IRbcYJE59alMIiz01f2pCitxQTjRQlawAAAEB4ka1n3/IfpL/E8xYMm779zR0WN2W53ss2Vl74psvKTvcSrY7fM9Xb8hFtxgkTn1qUwiLPTV/akKK3FBONFCVrAAAAGWhhcmloYXJhbmRldjFAcm9ja2NydXNoZXIBAgME"
export NFS_SERVER_IP=""
export NFS_MOUNT_POINT="/opt/nfs_client"
export NFS_EXPORT_DIR="/opt/shared"
export ORANGEFS_DATA_DIR="/mnt/nvme/orangefs_data"
export ORANGEFS_METADATA_DIR="/mnt/nvme/orangefs_metadata"
export ORANGEFS_MOUNT_DIR="/mnt/orangefs"
export ORANGEFS_LOG_DIR="/opt/orangefs/logs"
export STACK_NAME="t2"
export COMPUTE_COUNT="1"
export STORAGE_COUNT="1"
export OS_AUTH_TYPE="v3applicationcredential"
export OS_AUTH_URL="https://chi.tacc.chameleoncloud.org:5000/v3"
export OS_IDENTITY_API_VERSION="3"
export OS_REGION_NAME="CHI@TACC"
export OS_INTERFACE="public"
export OS_APPLICATION_CREDENTIAL_ID="7a600c7eb32a46ba995b79c01381eeff"
export OS_APPLICATION_CREDENTIAL_SECRET="JYVEgPbbh5CPVsvCyISDz7fSxVrLh1lFrHmYCfhmJflFI2geAbze5oMY1vKPGr1gWs3HcoAGc6LQNK8lQrBDWw"
export OPENSTACK_TIMEOUT_SECONDS="1800"
export MOUNT_SSH_TIMEOUT_SECONDS="1800"
export SCRIPT_ROOT="$SCRIPT_ROOT"

log_info "Environment variables exported"

chmod +x "$SCRIPT_ROOT/orangefs/scripts/node_orchestration.sh"
chmod +x "$SCRIPT_ROOT/orangefs/scripts/post_nodes_orchestration.sh"

log_info "Running node orchestration"
bash "$SCRIPT_ROOT/orangefs/scripts/node_orchestration.sh"

echo "[$(date -Is)] Heat bootstrap completed successfully"
