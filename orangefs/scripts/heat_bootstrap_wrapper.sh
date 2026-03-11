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

disable_ddebs_repositories() {
	local repo_file

	for repo_file in /etc/apt/sources.list.d/*; do
		[ -f "$repo_file" ] || continue
		if grep -q 'ddebs\.ubuntu\.com' "$repo_file" 2>/dev/null; then
			mv "$repo_file" "$repo_file.disabled-by-orangefs"
			echo "[$(date -Is)] Disabled debug-symbol APT repo file $repo_file"
		fi
	done

	if [ -f /etc/apt/sources.list ] && grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*ddebs\.ubuntu\.com' /etc/apt/sources.list; then
		sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]].*ddebs\.ubuntu\.com/s/^/# disabled by orangefs: /' /etc/apt/sources.list
		echo "[$(date -Is)] Disabled debug-symbol APT entries in /etc/apt/sources.list"
	fi
}

retry_apt_update() {
	local attempt
	local max_attempts=5
	local retry_delay_seconds=15

	disable_ddebs_repositories

	for attempt in $(seq 1 "$max_attempts"); do
		if DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3; then
			return 0
		fi

		if [ "$attempt" -lt "$max_attempts" ]; then
			echo "[$(date -Is)] apt-get update failed (attempt ${attempt}/${max_attempts}); retrying in ${retry_delay_seconds}s"
			apt-get clean >/dev/null 2>&1 || true
			rm -rf /var/lib/apt/lists/partial/* >/dev/null 2>&1 || true
			sleep "$retry_delay_seconds"
		fi
	done

	echo "[$(date -Is)] ERROR: apt-get update failed after ${max_attempts} attempts"
	return 1
}

# Clone the repository to a well-known location
REPO_URL="${REPO_URL:-https://github.com/hariharan-devarajan/chameleoncloud.git}"
REPO_REF="${REPO_REF:-dev}"
CLONE_DIR="/opt/shared/chameleoncloud"

# Ensure parent directory exists
mkdir -p /opt/shared

echo "[$(date -Is)] Cloning repository from ${REPO_URL} (ref: ${REPO_REF})"
retry_apt_update
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
