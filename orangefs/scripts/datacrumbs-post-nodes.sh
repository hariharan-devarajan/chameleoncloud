#!/bin/bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/post_nodes_functions.sh"
source "$SCRIPT_DIR/lib/nfs_functions.sh"
source "$SCRIPT_DIR/lib/orangefs_functions.sh"

datacrumbs_post_nodes_main