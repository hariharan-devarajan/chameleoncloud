# OrangeFS Deployment - Environment and Logging Structure

## Directory Structure

### Runtime Environment
```
/var/run/datacrumbs/
├── node_orchestration.env          # Node setup environment variables
├── post_nodes_orchestration.env     # Post-nodes environment variables
└── [other runtime files]
```

**Purpose**: Stores transient runtime data and environment variables that facilitate recovery and debugging if a script fails partway through.

### Logging
```
/var/log/datacrumbs/
├── heat-bootstrap.log              # Main Heat template bootstrap execution
├── bootstrap-login.log             # Login node bootstrap execution
├── bootstrap-compute.log           # Compute nodes bootstrap execution
├── bootstrap-storage.log           # Storage nodes bootstrap execution
├── post-nodes.log                  # Post-nodes orchestration script
└── post-nodes-launch.log           # Post-nodes launch wrapper log
```

**Purpose**: Centralized logging location for all datacrumbs orchestration activities with structured STATUS levels for easy filtering.

## Environment Files

### `/var/run/datacrumbs/node_orchestration.env`

Written by: `node_orchestration.sh`
Read by: Manual inspection for debugging

**Contents**:
```bash
# Node Orchestration Environment Variables
# Generated: 2026-03-10T12:00:00+00:00

NODE_ROLE="login|compute|storage"
TARGET_USER="cc"
IS_LOGIN_NODE="0|1"
IS_COMPUTE_NODE="0|1"
IS_STORAGE_NODE="0|1"

# SSH Configuration
PUBLIC_KEY_SET="yes|no"
PRIVATE_KEY_SET="yes|no"

# NFS Configuration
NFS_SERVER_IP="10.x.x.x"
NFS_MOUNT_POINT="/opt/nfs_client"
NFS_EXPORT_DIR="/opt/shared"

# OrangeFS Configuration
ORANGEFS_DATA_DIR="/mnt/nvme/orangefs_data"
ORANGEFS_METADATA_DIR="/mnt/nvme/orangefs_metadata"
ORANGEFS_MOUNT_DIR="/mnt/orangefs"
ORANGEFS_LOG_DIR="/opt/orangefs/logs"

# Stack Configuration
STACK_NAME="my-orangefs-stack"
COMPUTE_COUNT="2"
STORAGE_COUNT="2"

# OpenStack Credentials
OS_AUTH_TYPE="v3applicationcredential"
OS_AUTH_URL="https://chi.tacc.chameleoncloud.org:5000/v3"
OS_IDENTITY_API_VERSION="3"
OS_REGION_NAME="CHI@TACC"
OS_INTERFACE="public"
OS_APPLICATION_CREDENTIAL_ID_SET="yes|no"
OS_APPLICATION_CREDENTIAL_SECRET_SET="yes|no"

# Script Paths
SCRIPT_ROOT="/opt/shared/chameleoncloud"
```

**Note**: Sensitive keys (PUBLIC_KEY, PRIVATE_KEY, OS_APPLICATION_CREDENTIAL_*) are marked as "set" but not stored in plain text for security.

### `/var/run/datacrumbs/post_nodes_orchestration.env`

Written by: `post_nodes_orchestration.sh`
Read by: Manual inspection for debugging

**Contents**:
```bash
# Post-Nodes Orchestration Environment Variables
# Generated: 2026-03-10T12:00:30+00:00

STACK_NAME="my-orangefs-stack"
COMPUTE_COUNT="2"
STORAGE_COUNT="2"

# Timeouts
OPENSTACK_TIMEOUT_SECONDS="1800"
MOUNT_SSH_TIMEOUT_SECONDS="1800"

# Paths
NFS_MOUNT_POINT="/opt/nfs_client"
TARGET_USER="cc"
LOG_DIR="/var/log/datacrumbs"
RUNTIME_DIR="/var/run/datacrumbs"
```

## Log Files and Contents

### `/var/log/datacrumbs/heat-bootstrap.log`

**Written by**: Heat template's user_data script
**Format**: Timestamped with status level markers
**Example**:
```
[2026-03-10T12:00:00+00:00] Heat bootstrap started
[2026-03-10T12:00:05+00:00] Repository cloned successfully
[2026-03-10T12:00:10+00:00] Environment variables exported
[2026-03-10T12:00:15+00:00] Running node orchestration
[2026-03-10T12:05:00+00:00] Heat bootstrap completed successfully
```

### `/var/log/datacrumbs/bootstrap-{role}.log`

**Written by**: `node_orchestration.sh` for each node role
**Format**: Structured with `STATUS=LEVEL` markers for grep filtering
**Example**:
```
[2026-03-10T12:00:15.123456+00:00] STATUS=INFO Bootstrap logging initialized for role login
[2026-03-10T12:00:16.234567+00:00] STATUS=DEBUG Log file: /var/log/datacrumbs/bootstrap-login.log
[2026-03-10T12:00:16.345678+00:00] STATUS=DEBUG Runtime directory: /var/run/datacrumbs
[2026-03-10T12:00:17.456789+00:00] STATUS=INFO Node environment variables written to /var/run/datacrumbs/node_orchestration.env
[2026-03-10T12:01:00.567890+00:00] STATUS=INFO Stage 1: System Updates
[2026-03-10T12:02:00.678901+00:00] STATUS=INFO Stage 2: SSH Keys and Directory Setup
[2026-03-10T12:03:00.789012+00:00] STATUS=INFO Stage 3: Install Base NFS Packages
[2026-03-10T12:04:00.890123+00:00] STATUS=INFO Stage 4: NFS Server Setup (Login Node)
[2026-03-10T12:05:00.901234+00:00] STATUS=INFO Post-nodes environment file written to /etc/datacrumbs-post.env
[2026-03-10T12:05:05.012345+00:00] STATUS=INFO Post-nodes processing script started in background
[2026-03-10T12:06:00.123456+00:00] STATUS=INFO Stage 5: Configure NFS Client Mount
[2026-03-10T12:07:00.234567+00:00] STATUS=SUCCESS NFS client mount configured and verified at /opt/nfs_client
[2026-03-10T12:08:00.345678+00:00] STATUS=INFO Stage 6: OrangeFS Preparation
[2026-03-10T12:09:00.456789+00:00] STATUS=SUCCESS Node Orchestration Completed Successfully
```

**Log Levels**:
- `STATUS=ERROR` - Critical failures requiring intervention
- `STATUS=WARNING` - Recoverable issues or degraded functionality
- `STATUS=INFO` - Normal operation milestones
- `STATUS=DEBUG` - Detailed diagnostic information

### `/var/log/datacrumbs/post-nodes.log`

**Written by**: `post_nodes_orchestration.sh` on login node
**Format**: Same structured format as bootstrap logs
**Example**:
```
[2026-03-10T12:10:00.567890+00:00] STATUS=INFO Post-nodes orchestration logging initialized
[2026-03-10T12:10:01.678901+00:00] STATUS=DEBUG Log file: /var/log/datacrumbs/post-nodes.log
[2026-03-10T12:10:02.789012+00:00] STATUS=DEBUG Runtime directory: /var/run/datacrumbs
[2026-03-10T12:10:03.890123+00:00] STATUS=INFO Post-nodes environment variables written to /var/run/datacrumbs/post_nodes_orchestration.env
[2026-03-10T12:10:05.901234+00:00] STATUS=INFO Waiting for all nodes to be ACTIVE...
[2026-03-10T12:10:10.012345+00:00] STATUS=INFO Checking node readiness from OpenStack (attempt 1/60)
[2026-03-10T12:10:20.123456+00:00] STATUS=INFO Found compute nodes: 2/2
[2026-03-10T12:10:21.234567+00:00] STATUS=INFO Found storage nodes: 2/2
[2026-03-10T12:10:22.345678+00:00] STATUS=INFO All required nodes discovered and listed in /opt/nfs_client/all_nodes.txt
[2026-03-10T12:10:25.456789+00:00] STATUS=INFO Configuring NFS client mounts on all nodes
...
[2026-03-10T12:15:00.567890+00:00] STATUS=SUCCESS Cluster hosts resolution configured
[2026-03-10T12:15:30.678901+00:00] STATUS=SUCCESS Post-Nodes Orchestration Completed Successfully
```

## Debugging and Recovery

### View All Logs
```bash
# View all datacrumbs logs
tail -f /var/log/datacrumbs/*.log

# View only errors across all logs
grep "STATUS=ERROR" /var/log/datacrumbs/*.log

# View warnings and errors
grep -E "STATUS=(ERROR|WARNING)" /var/log/datacrumbs/*.log

# View INFO level events
grep "STATUS=INFO" /var/log/datacrumbs/*.log
```

### Recover from Node Orchestration Failure
```bash
# Check node environment
cat /var/run/datacrumbs/node_orchestration.env

# Rerun key setup
source /var/run/datacrumbs/node_orchestration.env
source /opt/shared/chameleoncloud/orangefs/scripts/lib/key_setup.sh
setup_ssh_keys_multi "$PUBLIC_KEY" "$PRIVATE_KEY" "$TARGET_USER,root"

# Rerun directory setup
source /opt/shared/chameleoncloud/orangefs/scripts/lib/directory_structures.sh
setup_all_directories "$TARGET_USER" "$NFS_MOUNT_POINT" "$NFS_EXPORT_DIR" \
  "$ORANGEFS_DATA_DIR" "$ORANGEFS_METADATA_DIR" "$ORANGEFS_MOUNT_DIR" "/var/log/datacrumbs"
```

### Recover from Post-Nodes Failure
```bash
# Check post-nodes environment
cat /var/run/datacrumbs/post_nodes_orchestration.env

# Rerun post-nodes orchestration
source /var/run/datacrumbs/post_nodes_orchestration.env
bash /opt/shared/chameleoncloud/orangefs/scripts/post_nodes_orchestration.sh
```

## Log Rotation (Recommended)

To prevent logs from growing unbounded, configure logrotate:

```bash
cat > /etc/logrotate.d/datacrumbs << 'EOF'
/var/log/datacrumbs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 root root
    sharedscripts
}
EOF
```

## Permissions

All directories and files are created with:
- **Directories**: `755` (rwxr-xr-x)
- **Log Files**: `644` (rw-r--r--)
- **Environment Files**: `600` (rw-------)  [Protected for security]

This ensures:
- The deployment user (`cc` by default) can read and write logs
- All users can read logs for monitoring
- Environment files with sensitive info are readable only by root
