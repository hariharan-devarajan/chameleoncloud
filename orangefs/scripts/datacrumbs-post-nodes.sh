#!/bin/bash
set -euxo pipefail

export SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_ROOT/lib/nfs_functions.sh"
source "$SCRIPT_ROOT/lib/orangefs_functions.sh"
source "$SCRIPT_ROOT/lib/post_nodes_functions.sh"

datacrumbs_post_nodes_main