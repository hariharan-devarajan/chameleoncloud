#!/bin/bash
# logging.sh - Common logging library for datacrumbs orchestration
# Supports TRACE, DEBUG, INFO, WARNING, ERROR levels controlled via LOG_LEVEL env variable
# TRACE enables set -x for full command output
# DEBUG and INFO include file name and line number

# ============================================================================
# Configuration
# ============================================================================

# Supported log levels in order of verbosity
declare -A LOG_LEVELS=(
  [TRACE]=5
  [DEBUG]=4
  [INFO]=3
  [WARNING]=2
  [ERROR]=1
  [OFF]=0
)

# Default log level
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ============================================================================
# Helper: Get numeric value for log level
# ============================================================================
get_log_level_value() {
  local level="$1"
  local default="${LOG_LEVELS[INFO]}"
  echo "${LOG_LEVELS[$level]:-$default}"
}

# ============================================================================
# Helper: Check if logging is enabled for a level
# ============================================================================
should_log() {
  local message_level="$1"
  local current_level_value
  local message_level_value

  current_level_value=$(get_log_level_value "$LOG_LEVEL")
  message_level_value=$(get_log_level_value "$message_level")

  [ "$message_level_value" -le "$current_level_value" ]
}

# ============================================================================
# Helper: Get caller information (file and line)
# ============================================================================
get_caller_info() {
  local frame="${1:-2}"
  local filename
  local lineno

  # Get the filename from the call stack
  filename=$(basename "${BASH_SOURCE[$frame]}")
  # Get the line number from the call stack
  lineno="${BASH_LINENO[$((frame - 1))]}"

  echo "${filename}:${lineno}"
}

# ============================================================================
# Helper: Format log message with timestamp and level
# ============================================================================
format_log_message() {
  local level="$1"
  local message="$2"
  local caller_info="${3:-}"
  local timestamp

  timestamp=$(date -Is)

  if [ -n "$caller_info" ]; then
    echo "[${timestamp}] STATUS=${level} [${caller_info}] ${message}"
  else
    echo "[${timestamp}] STATUS=${level} ${message}"
  fi
}

# ============================================================================
# Logging Functions
# ============================================================================

# Log ERROR - always printed (unless LOG_LEVEL=OFF)
log_error() {
  if should_log "ERROR"; then
    format_log_message "ERROR" "$*" >&2
  fi
}

# Log WARNING - printed for WARNING and above
log_warning() {
  if should_log "WARNING"; then
    format_log_message "WARNING" "$*" >&2
  fi
}

# Log INFO - printed for INFO and above, includes caller info
log_info() {
  if should_log "INFO"; then
    local caller_info
    caller_info=$(get_caller_info 2)
    format_log_message "INFO" "$*" "$caller_info"
  fi
}

# Log DEBUG - printed for DEBUG and above, includes caller info
log_debug() {
  if should_log "DEBUG"; then
    local caller_info
    caller_info=$(get_caller_info 2)
    format_log_message "DEBUG" "$*" "$caller_info"
  fi
}

# Log TRACE - prints when TRACE level is set, includes command output
log_trace() {
  if should_log "TRACE"; then
    local caller_info
    caller_info=$(get_caller_info 2)
    format_log_message "TRACE" "$*" "$caller_info"
  fi
}

# ============================================================================
# Helper: Enable Trace Mode
# ============================================================================
enable_trace_mode() {
  if should_log "TRACE"; then
    log_trace "Enabling command tracing (set -x)"
    set -x
  fi
}

# ============================================================================
# Helper: Disable Trace Mode
# ============================================================================
disable_trace_mode() {
  { set +x; } 2>/dev/null || true
}

# ============================================================================
# Helper: Get Current Log Level
# ============================================================================
get_current_log_level() {
  echo "$LOG_LEVEL"
}

# ============================================================================
# Setup: Log level summary on startup
# ============================================================================
log_startup_info() {
  local script_name="${1:-script}"
  
  if should_log "INFO"; then
    echo "[$(date -Is)] STATUS=INFO Logging initialized for ${script_name}"
    echo "[$(date -Is)] STATUS=INFO Log level: ${LOG_LEVEL}"
    
    if should_log "TRACE"; then
      echo "[$(date -Is)] STATUS=TRACE Trace mode enabled - commands will be printed"
    fi
  fi
}

# ============================================================================
# Export log level to subshells
# ============================================================================
export LOG_LEVEL
