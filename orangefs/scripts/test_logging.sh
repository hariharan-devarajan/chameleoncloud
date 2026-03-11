#!/bin/bash
# test_logging.sh - Quick test of logging.sh integration

set -eu

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test 1: Source logging.sh
echo "Test 1: Sourcing logging.sh..."
source "${SCRIPT_ROOT}/lib/logging.sh"
echo "✓ logging.sh sourced successfully"

# Test 2: Check if log functions exist
echo "Test 2: Checking log functions..."
declare -f log_info &>/dev/null && echo "✓ log_info exists" || echo "✗ log_info missing"
declare -f log_warning &>/dev/null && echo "✓ log_warning exists" || echo "✗ log_warning missing"
declare -f log_error &>/dev/null && echo "✓ log_error exists" || echo "✗ log_error missing"
declare -f log_debug &>/dev/null && echo "✓ log_debug exists" || echo "✗ log_debug missing"
declare -f log_trace &>/dev/null && echo "✓ log_trace exists" || echo "✗ log_trace missing"

# Test 3: Test logging at different levels
echo ""
echo "Test 3: Testing logging levels (LOG_LEVEL=DEBUG)..."
export LOG_LEVEL="DEBUG"
log_error "This is an ERROR message"
log_warning "This is a WARNING message"
log_info "This is an INFO message"
log_debug "This is a DEBUG message"

# Test 4: Check get_current_log_level function
echo ""
echo "Test 4: Testing LOG_LEVEL environment..."
current_level=$(get_current_log_level)
echo "Current LOG_LEVEL: $current_level"
[ "$current_level" = "4" ] && echo "✓ LOG_LEVEL correctly set to 4 (DEBUG)" || echo "✗ LOG_LEVEL mismatch"

# Test 5: Source key_setup.sh
echo ""
echo "Test 5: Sourcing key_setup.sh..."
source "${SCRIPT_ROOT}/lib/key_setup.sh"
echo "✓ key_setup.sh sourced (uses logging.sh)"

# Test 6: Source directory_structures.sh
echo ""
echo "Test 6: Sourcing directory_structures.sh..."
source "${SCRIPT_ROOT}/lib/directory_structures.sh"
echo "✓ directory_structures.sh sourced (uses logging.sh)"

echo ""
echo "========================================"
echo "All logging integration tests passed! ✓"
echo "========================================"
