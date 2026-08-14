#!/bin/bash

################################################################################
# Logging Library — Demo Scripts
#
# Mirrors the function contract of demos/installer/lib/logging.sh so that
# runtimes-intelligence-demo.sh produces output in the same format as the
# installer:
#
#   Terminal  — section headers, single-line "Component ✓" success lines,
#               errors, and the "Logging initialized" banner only.
#   Log file  — full timestamped detail via write_to_log_file / log_file_only.
################################################################################

# Prevent multiple sourcing
if [[ -n "${DEMO_LOGGING_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly DEMO_LOGGING_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Color codes (identical to installer/lib/logging.sh)
# ---------------------------------------------------------------------------
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_ORANGE='\033[0;38;5;214m'
readonly COLOR_BOLD_RED='\033[1;31m'
readonly COLOR_BOLD_GREEN='\033[1;32m'
readonly COLOR_BOLD_YELLOW='\033[1;33m'

# ---------------------------------------------------------------------------
# Log file (set by init_logging; falls back to demo.log)
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-demo.log}"

################################################################################
# get_timestamp — ISO 8601 UTC (matches installer)
################################################################################
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

################################################################################
# write_to_log_file — timestamped entry to log file only, no terminal output
# Usage: write_to_log_file "INFO" "message"
################################################################################
write_to_log_file() {
    local level="$1"
    local message="$2"
    if [[ -n "${LOG_FILE}" ]]; then
        echo "[$(get_timestamp)] [${level}] ${message}" >> "${LOG_FILE}"
    fi
}

################################################################################
# log_file_only — convenience wrapper: INFO entry, no terminal output
# Usage: log_file_only "message"
################################################################################
log_file_only() {
    write_to_log_file "INFO" "$1"
}

################################################################################
# init_logging — initialise log file and print banner to terminal
# Usage: init_logging <log_file_path> [append]
#   append = "true"  → append with separator (terminate/cleanup mode)
#   append = "false" → overwrite with fresh header (default / setup mode)
################################################################################
init_logging() {
    local log_file="${1:-${LOG_FILE}}"
    local append="${2:-false}"
    LOG_FILE="${log_file}"

    mkdir -p "$(dirname "${LOG_FILE}")"

    if [[ "${append}" == "true" ]]; then
        {
            echo ""
            echo "========================================"
            echo "Log Entry - $(get_timestamp)"
            echo "========================================"
            echo ""
        } >> "${LOG_FILE}"
    else
        {
            echo "========================================"
            echo "Demo Log"
            echo "Started: $(get_timestamp)"
            echo "========================================"
            echo ""
        } > "${LOG_FILE}"
    fi

    echo -e "${COLOR_GREEN}Logging initialized. Log file: ${LOG_FILE}${COLOR_RESET}"
    write_to_log_file "INFO" "Logging initialized. Log file: ${LOG_FILE}"
}

################################################################################
# log_section — terminal: cyan bold separator + title
#               log file: plain separator + title
# Usage: log_section "Section Title"
################################################################################
log_section() {
    local title="$1"
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}${title}${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo ""
    } > /dev/tty 2>/dev/null || true
    if [[ -n "${LOG_FILE}" ]]; then
        {
            echo ""
            echo "========================================"
            echo "${title}"
            echo "========================================"
            echo ""
            echo "[$(get_timestamp)] [SECTION] ${title}"
        } >> "${LOG_FILE}"
    fi
}

################################################################################
# log_validation_success — terminal: cyan bold "Message ✓"
# Usage: log_validation_success "Validating Prerequisites"
################################################################################
log_validation_success() {
    local message="$1"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}${message} ✓${COLOR_RESET}" > /dev/tty 2>/dev/null || \
        echo -e "${COLOR_CYAN}${COLOR_BOLD}${message} ✓${COLOR_RESET}"
    write_to_log_file "SUCCESS" "${message}"
}

################################################################################
# log_install_success — terminal: orange bold "Component ✓"
# Usage: log_install_success "chaos-lab"
################################################################################
log_install_success() {
    local message="$1"
    echo -e "${COLOR_ORANGE}${COLOR_BOLD}${message} ✓${COLOR_RESET}" > /dev/tty 2>/dev/null || \
        echo -e "${COLOR_ORANGE}${COLOR_BOLD}${message} ✓${COLOR_RESET}"
    write_to_log_file "SUCCESS" "${message}"
}

################################################################################
# log_error — terminal: bold red "[ERROR] message"
# Usage: log_error "Something went wrong"
################################################################################
log_error() {
    local message="$1"
    echo -e "${COLOR_BOLD_RED}[ERROR] ${message}${COLOR_RESET}" > /dev/tty 2>/dev/null || \
        echo -e "${COLOR_BOLD_RED}[ERROR] ${message}${COLOR_RESET}" >&2
    write_to_log_file "ERROR" "${message}"
}

################################################################################
# start_spinner / stop_spinner — mirrors installer spinner behaviour
# Usage: start_spinner "Installing chaos-lab..."
#        stop_spinner
################################################################################
SPINNER_PID=""
_SPINNER_STOP_FILE=""

start_spinner() {
    local message="$1"
    local spinners=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    # Use a temp file as a stop flag — avoids signal/process-group issues
    _SPINNER_STOP_FILE="$(mktemp /tmp/.spinner_stop.XXXXXX)"
    (
        set +e
        local i=0
        while [[ -f "${_SPINNER_STOP_FILE}" ]]; do
            printf "\r${COLOR_CYAN}${COLOR_BOLD}${message} ${spinners[$((i % ${#spinners[@]}))]}${COLOR_RESET}" > /dev/tty 2>/dev/null
            sleep 0.1
            i=$(( i + 1 ))
        done
        printf "\r\033[K" > /dev/tty 2>/dev/null
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "${_SPINNER_STOP_FILE:-}" ]]; then
        rm -f "${_SPINNER_STOP_FILE}" 2>/dev/null || true
        _SPINNER_STOP_FILE=""
    fi
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "${SPINNER_PID}" 2>/dev/null || true
        wait "${SPINNER_PID}" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r\033[K" > /dev/tty 2>/dev/null
    return 0
}

################################################################################
# Export all functions
################################################################################
export -f get_timestamp
export -f write_to_log_file
export -f log_file_only
export -f init_logging
export -f log_section
export -f log_validation_success
export -f log_install_success
export -f log_error
export -f start_spinner
export -f stop_spinner
