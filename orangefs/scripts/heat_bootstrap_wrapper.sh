#!/bin/bash
# Heat template bootstrap wrapper - clones repo and runs node orchestration
# This script is injected into Heat user_data and handled all repo cloning
# and parameter passing to the stateless node_orchestration script

set -eux

# Setup directories
mkdir -p /var/run/datacrumbs
mkdir -p /var/log/datacrumbs
chmod 755 /var/run/datacrumbs
chmod 755 /var/log/datacrumbs

# Create main Heat bootstrap log
HEAT_LOG="/var/log/datacrumbs/heat-bootstrap.log"
touch "$HEAT_LOG"
chmod 644 "$HEAT_LOG"
exec > >(tee -a "$HEAT_LOG") 2>&1

echo "[$(date -Is)] Heat bootstrap wrapper starting"

# Clone the repository to a well-known location
REPO_URL="${REPO_URL:-https://github.com/hariharan-devarajan/chameleoncloud.git}"
REPO_REF="${REPO_REF:-dev}"
CLONE_DIR="/opt/shared/chameleoncloud"

# Ensure parent directory exists
mkdir -p /opt/shared

echo "[$(date -Is)] Cloning repository from ${REPO_URL} (ref: ${REPO_REF})"
git clone -b "$REPO_REF" "$REPO_URL" "$CLONE_DIR" 2>&1 || git clone "$REPO_URL" "$CLONE_DIR" 2>&1
cd "$CLONE_DIR"

# Make orchestration scripts executable
chmod +x orangefs/scripts/node_orchestration.sh
chmod +x orangefs/scripts/post_nodes_orchestration.sh

echo "[$(date -Is)] Running node orchestration script"

# Run the orchestration script with all parameters passed from Heat template
# All ENV variables are passed directly as-is from Heat template substitution
bash orangefs/scripts/node_orchestration.sh

echo "[$(date -Is)] Bootstrap wrapper completed successfully"
