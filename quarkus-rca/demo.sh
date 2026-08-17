#!/bin/bash
################################################################################
# Quarkus RCA Demo Script
#
# End-to-end demo that:
#
#   Step 1 — Runs install.sh from the quarkus-rca installer branch
#             Provisions: Kind cluster, Prometheus, k8s-mcp-server, Causa Backend,
#             Causa MCP, PostgreSQL (async-profiler & quarkus-mcp skipped — images TBD)
#
#   Step 2 — Deploys the quarkus-perf workload + load-gen job
#             into the causa-rca namespace on the kind cluster
#
#   Step 3 — Sources llm.env, creates credentials Secret, and pushes
#             LLM config to Causa via POST /api/v1/configs
#
#   Step 4 — Writes the Causa MCP entry to ~/.bob/settings/mcp.json
#             and copies the causa-rca SKILL.md into ~/.bob/skills/
#
#   Step 5 — Prints a ready prompt with container/namespace/pod info
#             for the user to paste into Bob IDE
#
# Usage:  ./demo.sh [OPTIONS]
# Run with -h for full option list.
#
# Prerequisites:  kind  kubectl  docker or podman  git  python3
#
# To change installer repo or branch:
#   INSTALLER_URL  and  INSTALLER_BRANCH  variables below (or use CLI flags).
#   The installer is cloned from INSTALLER_URL @ INSTALLER_BRANCH each run.
################################################################################

set -o pipefail

# ---------------------------------------------------------------------------
# Script directory and library loading
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOGGING_FILE="$SCRIPT_DIR/lib/logging.sh"
UTILS_FILE="$SCRIPT_DIR/lib/utils.sh"
UNINSTALL_FILE="$SCRIPT_DIR/lib/uninstall.sh"

IMAGES_ENV_FILE="$SCRIPT_DIR/images.env"
if [[ -f "$IMAGES_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$IMAGES_ENV_FILE"
    set +a
    echo -e "\033[0;36m[images.env]\033[0m Image overrides loaded from: $IMAGES_ENV_FILE"
fi

for _f in "$LOGGING_FILE" "$UTILS_FILE" "$UNINSTALL_FILE"; do
    if [[ ! -f "$_f" ]]; then
        echo "ERROR: $(basename "$_f") not found at $_f"
        exit 1
    fi
done

source "$LOGGING_FILE"
source "$UTILS_FILE"
source "$UNINSTALL_FILE"

_demo_exit_trap() { trap '' INT TERM; stop_spinner; exit 130; }
trap '_demo_exit_trap' INT TERM

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="causa-rca"
TARGET="${TARGET:-kind}"
FRONTEND_ASSISTANT=""
CLI_FRONTEND_SET=false
TERMINATE=false
SKIP_INSTALLER=false
DEMO_DIR="$SCRIPT_DIR/artifacts"

WORKLOAD_APP_NAME="quarkus-perf"
WORKLOAD_CONTAINER_NAME="quarkus-perf"
SCENARIO_HTTP_LARGE_RESPONSE="large-response"
SCENARIO_HTTP_IDLE_TIMEOUT="idle-timeout"
SCENARIO_MEMORY_CACHE="memory-cache"
export WORKLOAD_APP_NAME

# ---------------------------------------------------------------------------
# Chaos Lab configuration
# ---------------------------------------------------------------------------
CHAOS_LAB_URL="${CHAOS_LAB_URL:-https://github.com/causaai/chaos-lab.git}"
CHAOS_LAB_BRANCH="${CHAOS_LAB_BRANCH:-main}"
CHAOS_LAB_DIR="$DEMO_DIR/chaos-lab"
QUARKUS_PERF_SUBDIR="quarkus-perf"

# ---------------------------------------------------------------------------
# Installer configuration
# ---------------------------------------------------------------------------
# To use a different fork or branch, change these variables or pass CLI flags.
INSTALLER_NAME="installer"
INSTALLER_URL="${INSTALLER_URL:-https://github.com/causaai/installer}"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-mvp_demo}"

# ---------------------------------------------------------------------------
# Frontend Assistant configs (Bob IDE, Claude Desktop, etc.)
# ---------------------------------------------------------------------------
BOB_MCP_CONFIG="${HOME}/.bob/settings/mcp.json"
CLAUDE_MCP_CONFIG_MAC="${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
CLAUDE_MCP_CONFIG_LINUX="${HOME}/.config/Claude/claude_desktop_config.json"
CLAUDE_MCP_CONFIG="${CLAUDE_MCP_CONFIG_MAC}"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    CLAUDE_MCP_CONFIG="${CLAUDE_MCP_CONFIG_LINUX}"
fi

# Causa MCP Server is on NodePort 30005 (see installer manifests/causa_mcp/deployment.yaml)
CAUSA_MCP_URL="http://localhost:30005"
CAUSA_BACKEND_URL="http://localhost:30001"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
show_help() {
    echo "Quarkus RCA Demo Script"
    echo ""
    echo "Usage: $0 [--target TARGET] [-n namespace] [--frontend FRONTEND] [-t] [--skip-installer] [--installer-url URL] [--installer-branch BRANCH] [--chaos-lab-url URL] [--chaos-lab-branch BRANCH] [-h]"
    echo ""
    echo "Options:"
    echo "    --target TARGET          Target platform: kind, openshift, vm, etc. (default: kind)"
    echo "                             Passed directly to installer install.sh --target <TARGET>."
    echo "    -n namespace             Namespace for the RCA stack and workload (default: causa-rca)"
    echo "    --frontend FRONTEND      Frontend assistant to configure for RCA chat (e.g. bob, claude)"
    echo "                             Supported: bob, claude, all, none (default: none / not set)"
    echo "    -t                       Terminate mode: clean up all resources"
    echo "    --skip-installer         Skip running install.sh (use when stack is already deployed)"
    echo "    --installer-url URL      Git URL of the installer repo"
    echo "                             Default: https://github.com/causaai/installer"
    echo "    --installer-branch BRANCH  Branch to check out from the installer repo"
    echo "                               Default: mvp_demo"
    echo "    --chaos-lab-url URL      Git URL of the chaos-lab repo"
    echo "                             Default: https://github.com/causaai/chaos-lab.git"
    echo "    --chaos-lab-branch BRANCH  Branch to check out from the chaos-lab repo"
    echo "                               Default: main"
    echo "    -h                       Show this help message"
    echo ""
    echo "Backend RCA LLM vs Frontend Chat Assistant:"
    echo "    Backend RCA LLM is configured via llm.env / environment:"
    echo "        LLM_PROVIDER=vertex-ai-anthropic | anthropic | bob | openai | bedrock | ..."
    echo "    Frontend Assistant (chatting with RCA tools):"
    echo "        Bob IDE: registers Causa MCP in ~/.bob/settings/mcp.json + copies causa-rca SKILL.md"
    echo "        Claude Desktop: registers Causa MCP in claude_desktop_config.json"
    echo ""
    echo "Installer repo / branch:"
    echo "    The installer is cloned from INSTALLER_URL at INSTALLER_BRANCH."
    echo "    To permanently use a different repo or branch, edit these variables"
    echo "    at the top of this script, or export them before running:"
    echo "        export INSTALLER_URL=https://github.com/my-fork/installer"
    echo "        export INSTALLER_BRANCH=my-feature-branch"
    echo "        export CHAOS_LAB_URL=https://github.com/my-fork/chaos-lab.git"
    echo "        export CHAOS_LAB_BRANCH=my-branch"
    echo "        ./demo.sh"
    echo ""
    echo "Examples:"
    echo "    # Full automated demo on kind (default)"
    echo "    $0"
    echo ""
    echo "    # Deploy to OpenShift or VM target"
    echo "    $0 --target openshift -n my-rca"
    echo "    $0 --target vm"
    echo ""
    echo "    # Custom frontend chat assistant"
    echo "    $0 --frontend claude"
    echo "    $0 --frontend bob"
    echo ""
    echo "    # Custom namespace"
    echo "    $0 -n my-rca"
    echo ""
    echo "    # Skip installer (stack already running)"
    echo "    $0 --skip-installer"
    echo ""
    echo "    # Tear down everything"
    echo "    $0 -t"
    echo ""
    echo "Prerequisites:  kind (if target=kind)  kubectl  docker or podman  git  python3"
    echo ""
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
_CLI_FRONTEND_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --target" >&2; exit 1; }
            TARGET="$2"; shift 2 ;;
        -n)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for -n" >&2; exit 1; }
            NAMESPACE="$2"; shift 2 ;;
        --frontend)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --frontend" >&2; exit 1; }
            _CLI_FRONTEND_ARG="$2"; CLI_FRONTEND_SET=true; shift 2 ;;
        -t)               TERMINATE=true; shift ;;
        --skip-installer) SKIP_INSTALLER=true; shift ;;
        --installer-url)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --installer-url" >&2; exit 1; }
            INSTALLER_URL="$2"; shift 2 ;;
        --installer-branch)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --installer-branch" >&2; exit 1; }
            INSTALLER_BRANCH="$2"; shift 2 ;;
        --chaos-lab-url)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --chaos-lab-url" >&2; exit 1; }
            CHAOS_LAB_URL="$2"; shift 2 ;;
        --chaos-lab-branch)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --chaos-lab-branch" >&2; exit 1; }
            CHAOS_LAB_BRANCH="$2"; shift 2 ;;
        -h) show_help; exit 0 ;;
        *)  echo "ERROR: Invalid option: $1" >&2; echo "Use -h for help"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Load llm.env early (Priority: CLI flag > llm.env > default)
# ---------------------------------------------------------------------------
_LLM_ENV_FILE="$SCRIPT_DIR/llm.env"
if [[ -f "$_LLM_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$_LLM_ENV_FILE"
    set +a
fi

if [[ "$CLI_FRONTEND_SET" == "true" ]]; then
    FRONTEND_ASSISTANT="$_CLI_FRONTEND_ARG"
fi

# ---------------------------------------------------------------------------
# Initialise logging
# ---------------------------------------------------------------------------
SCRIPT_START_TIME=$(start_timer)
LOG_FILE="$SCRIPT_DIR/demo.log"

if [[ "$TERMINATE" == "true" ]]; then
    init_logging "$LOG_FILE" "true"
else
    init_logging "$LOG_FILE" "false"
fi

# ---------------------------------------------------------------------------
# Opening banner
# ---------------------------------------------------------------------------
if [[ "$TERMINATE" == "true" ]]; then
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Quarkus RCA Demo — Cleanup${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    write_to_log_file "INFO" "Demo Cleanup — namespace: $NAMESPACE"
else
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Running Quarkus RCA Demo${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    write_to_log_file "INFO" "Demo Setup — namespace: $NAMESPACE, target: $TARGET, frontend: ${FRONTEND_ASSISTANT:-none}"
    echo -e "${COLOR_CYAN}Target:${COLOR_RESET}           ${COLOR_BOLD}${TARGET}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Namespace:${COLOR_RESET}        ${COLOR_BOLD}${NAMESPACE}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Frontend Chat:${COLOR_RESET}    ${COLOR_BOLD}${FRONTEND_ASSISTANT:-none}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Installer URL:${COLOR_RESET}    ${COLOR_BOLD}${INSTALLER_URL}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Installer Branch:${COLOR_RESET} ${COLOR_BOLD}${INSTALLER_BRANCH}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Chaos Lab URL:${COLOR_RESET}    ${COLOR_BOLD}${CHAOS_LAB_URL}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Chaos Lab Branch:${COLOR_RESET} ${COLOR_BOLD}${CHAOS_LAB_BRANCH}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo "" >/dev/tty 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Terminate mode
# ---------------------------------------------------------------------------
if [[ "$TERMINATE" == "true" ]]; then
    terminate_demo "$NAMESPACE" "$DEMO_DIR" "$SKIP_INSTALLER"

    # Remove Causa MCP entry from Bob mcp.json
    if [[ -f "$BOB_MCP_CONFIG" ]]; then
        start_spinner "Removing Causa MCP from Bob IDE config..."
        _remove_rc=1
        if command_exists python3; then
            python3 - "$BOB_MCP_CONFIG" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    cfg.get("mcpServers", {}).pop("causa-rca", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("removed")
except Exception as e:
    print(f"warn: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
            _remove_rc=$?
        fi
        stop_spinner
        if [[ $_remove_rc -eq 0 ]]; then
            log_install_success "Causa MCP removed from Bob IDE config"
        fi
    fi

    # Remove Causa MCP entry from Claude config
    if [[ -f "$CLAUDE_MCP_CONFIG" ]]; then
        start_spinner "Removing Causa MCP from Claude Desktop config..."
        _remove_claude_rc=1
        if command_exists python3; then
            python3 - "$CLAUDE_MCP_CONFIG" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    cfg.get("mcpServers", {}).pop("causa-rca", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("removed")
except Exception as e:
    print(f"warn: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
            _remove_claude_rc=$?
        fi
        stop_spinner
        if [[ $_remove_claude_rc -eq 0 ]]; then
            log_install_success "Causa MCP removed from Claude Desktop config"
        fi
    fi

    ELAPSED=$(get_elapsed_time "$SCRIPT_START_TIME")
    write_to_log_file "SUCCESS" "Total cleanup time: $ELAPSED"
    {
        echo ""
        echo -e "${COLOR_BOLD_YELLOW}Total cleanup time: $ELAPSED${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
# Check non-runtime prerequisites first (kind is required only when target is kind)
_REQUIRED_CMDS=("git" "kubectl")
if [[ "$TARGET" == "kind" ]]; then
    _REQUIRED_CMDS+=("kind")
fi

if ! check_required_commands "${_REQUIRED_CMDS[@]}"; then
    log_error "Missing required commands (${_REQUIRED_CMDS[*]}). Please install them and try again."
    exit 1
fi

# Resolve container runtime — prefer docker, fall back to podman
if command_exists docker; then
    CONTAINER_RUNTIME="docker"
elif command_exists podman; then
    CONTAINER_RUNTIME="podman"
else
    log_error "No container runtime found. Install docker or podman."
    log_error "  - docker: https://docs.docker.com/get-docker/"
    log_error "  - podman: https://podman.io/getting-started/installation"
    exit 1
fi
export CONTAINER_RUNTIME
write_to_log_file "INFO" "Container runtime: $CONTAINER_RUNTIME"

log_validation_success "Validating Prerequisites"

ensure_directory "$DEMO_DIR"
cd "$DEMO_DIR"

# ===========================================================================
# Step 1: Run install.sh (Causa RCA stack on kind)
# ===========================================================================
log_section "Step 1: Installing Causa RCA stack via install.sh"

# ---------------------------------------------------------------------------
# 1a: Clone / update the installer repo
# ---------------------------------------------------------------------------
INSTALLER_DIR="$DEMO_DIR/$INSTALLER_NAME"

if [[ "$SKIP_INSTALLER" == "false" ]]; then
    start_spinner "Cloning installer (branch: $INSTALLER_BRANCH)..."
    if ! clone_repo "$INSTALLER_URL" "$INSTALLER_DIR" "$INSTALLER_BRANCH" \
            2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
        stop_spinner
        log_error "Failed to clone installer from $INSTALLER_URL"
        exit 1
    fi
    stop_spinner
    log_install_success "installer cloned (branch: $INSTALLER_BRANCH)"

    # install.sh is the entry point on the quarkus-rca branch.
    # If you want to use main or a different branch in future, update
    # INSTALLER_BRANCH above (or --installer-branch CLI flag) — the script
    # name is always install.sh.
    INSTALL_SCRIPT="$INSTALLER_DIR/install.sh"
    if [[ ! -f "$INSTALL_SCRIPT" ]]; then
        log_error "install.sh not found in $INSTALLER_DIR (branch: $INSTALLER_BRANCH)"
        log_error "Expected: $INSTALL_SCRIPT"
        exit 1
    fi

    # ---------------------------------------------------------------------------
    # 1b: Run install.sh with --target kind and image overrides
    # ---------------------------------------------------------------------------
    # Images are provided explicitly so the installer uses exactly what we want:
    #   causa backend:     quay.io/rh-ee-shesaxen/causa-backend:adc-fix
    #   causa mcp:         quay.io/bmenghan/causa-mcp-server:latest
    #   k8s mcp server:    quay.io/containers/kubernetes_mcp_server:v0.0.62
    # async-profiler, async-profiler-mcp, quarkus-mcp images are not yet
    # available — install.sh skips them gracefully (non-fatal warnings).
    #
    # To permanently change the images, edit images.env in this directory.
    # The images below are loaded from images.env at script startup (set -a).
    # ---------------------------------------------------------------------------
    {
        echo ""
        echo -e "${COLOR_CYAN}Running install.sh --target kind ...${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true

    _INSTALL_ARGS=(
        --target kind
        -n "${NAMESPACE}"
    )

    # Pass image overrides if set via images.env or environment
    [[ -n "${K8S_MCP_SERVER_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--k8s-mcp-server-image "$K8S_MCP_SERVER_IMAGE")
    [[ -n "${CAUSA_BACKEND_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--causa-backend-image "$CAUSA_BACKEND_IMAGE")
    [[ -n "${CAUSA_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--causa-mcp-image "$CAUSA_MCP_IMAGE")
    [[ -n "${ASYNC_PROFILER_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--async-profiler-image "$ASYNC_PROFILER_IMAGE")
    [[ -n "${ASYNC_PROFILER_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--async-profiler-mcp-image "$ASYNC_PROFILER_MCP_IMAGE")
    [[ -n "${QUARKUS_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--quarkus-mcp-image "$QUARKUS_MCP_IMAGE")

    write_to_log_file "INFO" "Running: bash $INSTALL_SCRIPT ${_INSTALL_ARGS[*]}"

    # Run install.sh — its output is tee'd to terminal AND log file
    bash "$INSTALL_SCRIPT" "${_INSTALL_ARGS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    _install_rc=${PIPESTATUS[0]}

    if [[ $_install_rc -ne 0 ]]; then
        log_error "install.sh failed (exit code: $_install_rc). Check log: $LOG_FILE"
        exit 1
    fi
    log_install_success "Causa RCA stack deployed"
else
    log_install_success "Skipping installer (--skip-installer flag set)"
    log_file_only "Installer skipped by user"
    INSTALLER_DIR="${INSTALLER_DIR:-}"
fi

# ===========================================================================
# Step 1.5: Clone chaos-lab and locate quarkus-perf manifests
# ===========================================================================
log_section "Step 1.5: Cloning chaos-lab to get quarkus-perf manifests"

start_spinner "Cloning chaos-lab (branch: $CHAOS_LAB_BRANCH)..."
if ! clone_repo "$CHAOS_LAB_URL" "$CHAOS_LAB_DIR" "$CHAOS_LAB_BRANCH" \
        2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
    stop_spinner
    log_error "Failed to clone chaos-lab from $CHAOS_LAB_URL"
    exit 1
fi
stop_spinner
log_install_success "chaos-lab cloned (branch: $CHAOS_LAB_BRANCH)"

# ===========================================================================
# Step 2: Deploy quarkus-perf workload + load-gen
# ===========================================================================
log_section "Step 2: Deploying quarkus-perf workload"

WORKLOAD_MANIFEST="$CHAOS_LAB_DIR/$QUARKUS_PERF_SUBDIR/manifests/deploy-kind.yaml"
LOAD_GEN_MANIFEST="$CHAOS_LAB_DIR/$QUARKUS_PERF_SUBDIR/manifests/load-gen-job.yaml"
WORKLOAD_RENDERED_MANIFEST="$DEMO_DIR/quarkus-perf-deploy.rendered.yaml"
LOAD_GEN_RENDERED_MANIFEST="$DEMO_DIR/quarkus-perf-load-gen.rendered.yaml"

if [[ ! -f "$WORKLOAD_MANIFEST" ]]; then
    WORKLOAD_MANIFEST="$CHAOS_LAB_DIR/$QUARKUS_PERF_SUBDIR/manifests/deploy.yaml"
fi

if [[ ! -f "$WORKLOAD_MANIFEST" ]]; then
    log_error "Workload manifest not found in chaos-lab under $CHAOS_LAB_DIR/$QUARKUS_PERF_SUBDIR/manifests"
    exit 1
fi

sed \
    -e "s/namespace: chaos-test/namespace: $NAMESPACE/g" \
    -e "s/CHAOS_HTTP_IDLE_TIMEOUT_ENABLED: \"false\"/CHAOS_HTTP_IDLE_TIMEOUT_ENABLED: \"true\"/g" \
    -e "s/CHAOS_HTTP_LARGE_RESPONSE_ENABLED: \"false\"/CHAOS_HTTP_LARGE_RESPONSE_ENABLED: \"true\"/g" \
    -e "s/CHAOS_MEMORY_CACHE_ENABLED: \"false\"/CHAOS_MEMORY_CACHE_ENABLED: \"true\"/g" \
    "$WORKLOAD_MANIFEST" > "$WORKLOAD_RENDERED_MANIFEST"
if [[ -f "$LOAD_GEN_MANIFEST" ]]; then
    sed "s/namespace: chaos-test/namespace: $NAMESPACE/g" "$LOAD_GEN_MANIFEST" > "$LOAD_GEN_RENDERED_MANIFEST"
fi

start_spinner "Creating namespace $NAMESPACE..."
ensure_namespace "$NAMESPACE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"
stop_spinner

# ── Deploy quarkus-perf ──────────────────────────────────────────────────
start_spinner "Deploying quarkus-perf workload..."
if ! apply_manifest "$WORKLOAD_RENDERED_MANIFEST" "$NAMESPACE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
    stop_spinner
    log_error "Failed to deploy quarkus-perf workload"
    exit 1
fi
stop_spinner
log_install_success "quarkus-perf deployed to $NAMESPACE"

# ── Wait for quarkus-perf to be ready ─────────────────────────────────────
start_spinner "Waiting for quarkus-perf to be ready (up to 300s)..."
if ! wait_for_deployment "quarkus-perf" "$NAMESPACE" 300 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
    stop_spinner
    log_file_only "quarkus-perf not ready within timeout — continuing"
    log_validation_success "quarkus-perf readiness (timed out — check: kubectl get pods -n $NAMESPACE)"
else
    stop_spinner
    log_install_success "quarkus-perf is ready"
fi

# ── Start load-gen job (generates traffic that drives heap leak) ──────────
start_spinner "Starting load-gen job (drives OOM pressure)..."
if [[ -f "$LOAD_GEN_RENDERED_MANIFEST" ]]; then
    # Delete previous job if it exists (Jobs are immutable)
    kubectl delete job quarkus-perf-load-gen -n "$NAMESPACE" \
        --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
    if ! apply_manifest "$LOAD_GEN_RENDERED_MANIFEST" "$NAMESPACE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
        stop_spinner
        log_file_only "Failed to start load-gen job — continuing (OOM will take longer)"
    else
        stop_spinner
        log_install_success "load-gen job started (20 workers × 100ms delay → OOM in ~3-5 min)"
    fi
else
    stop_spinner
    log_file_only "Load-gen manifest not found: $LOAD_GEN_MANIFEST — skipping"
    log_validation_success "load-gen job (skipped — manifest not found)"
fi


# ===========================================================================
# Step 3: Configure Causa Backend — LLM credentials
# ===========================================================================
# Sources llm.env, creates the causa-gcp-credentials K8s Secret from
# causa-gcp-key.json, and pushes LLM config to Causa via
# POST /api/v1/configs (default Causa cooldown is preserved).
#
# Non-fatal: if no LLM provider is configured, Causa performs RCA using
# heuristics without LLM config.
# ===========================================================================
log_section "Step 3: Configuring Causa Backend (LLM)"

if [[ -f "$_LLM_ENV_FILE" ]]; then
    write_to_log_file "INFO" "Using LLM config loaded from: $_LLM_ENV_FILE"
else
    write_to_log_file "INFO" "llm.env not found — using exported environment variables"
    write_to_log_file "INFO" "Copy llm.env.example to llm.env and fill in values to enable LLM RCA"
fi

# ── Auto-create causa-gcp-credentials K8s Secret from local key file ─────
_GCP_KEY_FILE="$SCRIPT_DIR/causa-gcp-key.json"
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    _GCP_KEY_FILE="${GOOGLE_APPLICATION_CREDENTIALS}"
fi

if [[ "${LLM_PROVIDER:-}" == "vertex-ai-anthropic" || -n "${VERTEX_PROJECT_ID:-}" ]]; then
    if kubectl get secret causa-gcp-credentials \
            -n "$NAMESPACE" >>"$LOG_FILE" 2>&1; then
        write_to_log_file "INFO" "causa-gcp-credentials secret already exists in $NAMESPACE"
    elif [[ -f "$_GCP_KEY_FILE" ]]; then
        start_spinner "Creating causa-gcp-credentials secret from $(basename "$_GCP_KEY_FILE")..."
        if kubectl create secret generic causa-gcp-credentials \
                --from-file="key.json=$_GCP_KEY_FILE" \
                -n "$NAMESPACE" >>"$LOG_FILE" 2>&1; then
            stop_spinner
            log_install_success "causa-gcp-credentials secret created"
        else
            stop_spinner
            log_file_only "Failed to create causa-gcp-credentials secret — check $LOG_FILE"
        fi
    else
        write_to_log_file "WARN" "GCP key file not found at $_GCP_KEY_FILE"
        write_to_log_file "WARN" "Place the GCP service-account key there to enable Vertex AI LLM RCA"
    fi
fi

# ── Read GCP key back as a single-line base64 blob from the K8s Secret ───
_GCP_B64=""
if [[ "${LLM_PROVIDER:-}" == "vertex-ai-anthropic" || -n "${VERTEX_PROJECT_ID:-}" ]]; then
    _GCP_B64=$(kubectl get secret causa-gcp-credentials \
        -n "$NAMESPACE" \
        -o "jsonpath={.data.key\.json}" \
        2>>"$LOG_FILE" | tr -d '[:space:]' || true)
    if [[ -z "$_GCP_B64" && -f "$_GCP_KEY_FILE" ]]; then
        _GCP_B64=$(base64 < "$_GCP_KEY_FILE" | tr -d '[:space:]')
    fi
fi

# ── Build POST /api/v1/configs payload ───────────────────────────────────
# Use python3 to build a valid, properly escaped JSON payload for all providers
_CONFIG_PAYLOAD=$(python3 - << 'PYEOF'
import os, json

configs = {}

# Check provider and general LLM settings
provider = os.getenv("LLM_PROVIDER", "").strip()
model = os.getenv("LLM_MODEL_NAME", "").strip()
api_key = os.getenv("LLM_API_KEY", "").strip()
endpoint = os.getenv("LLM_ENDPOINT", "").strip()
temperature = os.getenv("LLM_TEMPERATURE", "").strip()

if provider:
    configs["LLM_PROVIDER"] = provider
if model:
    configs["LLM_MODEL_NAME"] = model
if api_key:
    configs["LLM_API_KEY"] = api_key
if endpoint:
    configs["LLM_ENDPOINT"] = endpoint
if temperature:
    configs["LLM_TEMPERATURE"] = temperature

# Vertex AI specific
vertex_proj = os.getenv("VERTEX_PROJECT_ID", "").strip()
vertex_loc = os.getenv("VERTEX_LOCATION", "").strip()
gcp_b64 = os.getenv("_GCP_B64", "").strip()

if vertex_proj:
    configs["VERTEX_PROJECT_ID"] = vertex_proj
if vertex_loc:
    configs["VERTEX_LOCATION"] = vertex_loc
if gcp_b64:
    configs["GOOGLE_APPLICATION_CREDENTIALS"] = gcp_b64

# Bob / custom provider specific
bob_shell_path = os.getenv("BOB_SHELL_PATH", os.getenv("BOB_PATH", "")).strip()
if bob_shell_path:
    configs["BOB_SHELL_PATH"] = bob_shell_path

print(json.dumps({"configs": configs}))
PYEOF
)

# ── Push LLM config to Causa Backend if configured ───────────────────────
_HAS_LLM_CONFIG=$(python3 -c "import json, os; p=json.loads('''$_CONFIG_PAYLOAD''').get('configs',{}); print('true' if len(p) > 0 else 'false')")

if [[ "$_HAS_LLM_CONFIG" == "true" ]]; then
    write_to_log_file "INFO" "Pushing LLM config (provider: ${LLM_PROVIDER:-auto}, model: ${LLM_MODEL_NAME:-default}) to Causa"

    # ── Find running Causa Backend pod ───────────────────────────────────────
    _CAUSA_POD=$(kubectl get pods \
        -l "app=causa-backend" \
        -n "$NAMESPACE" \
        --field-selector="status.phase=Running" \
        -o "jsonpath={.items[0].metadata.name}" \
        2>>"$LOG_FILE" || true)

    if [[ -z "$_CAUSA_POD" ]]; then
        write_to_log_file "WARN" "Causa Backend pod not running — skipping config push (RCA will run without LLM)"
    else
        start_spinner "Pushing config to Causa Backend (up to 5 attempts)..."
        _cfg_rc=1
        for _attempt in 1 2 3 4 5; do
            _cfg_rc=0
            kubectl exec -n "$NAMESPACE" "$_CAUSA_POD" -- \
                curl -sf --max-time 10 \
                -X POST "http://localhost:8080/api/v1/configs" \
                -H "Content-Type: application/json" \
                -d "$_CONFIG_PAYLOAD" \
                >>"$LOG_FILE" 2>&1 || _cfg_rc=$?

            if [[ $_cfg_rc -eq 0 ]]; then
                break
            fi
            write_to_log_file "INFO" "Config push attempt ${_attempt}/5 failed (rc=${_cfg_rc}) — retrying in 10s..."
            [[ $_attempt -lt 5 ]] && sleep 10
        done
        stop_spinner
        if [[ $_cfg_rc -eq 0 ]]; then
            log_install_success "Causa Backend configured (LLM config pushed)"
        else
            log_file_only "Config push failed after 5 attempts (non-fatal — RCA will run without LLM)"
            log_validation_success "Causa config push (failed — check $LOG_FILE)"
        fi
    fi
else
    write_to_log_file "INFO" "No LLM provider configured — Causa Backend will use default settings / heuristic RCA"
    log_validation_success "Causa Backend LLM config (skipped — no provider set in llm.env)"
fi

# ===========================================================================
# Step 4: Register Causa MCP in Frontend Assistant(s) (Bob IDE, Claude Desktop, etc.)
# ===========================================================================
if [[ -z "$FRONTEND_ASSISTANT" || "$FRONTEND_ASSISTANT" == "none" ]]; then
    log_section "Step 4: Frontend Assistant Configuration (Skipped)"
    write_to_log_file "INFO" "Frontend assistant is not set — skipping automatic MCP client configuration"
    {
        echo -e "${COLOR_YELLOW}Frontend assistant is not set, so skipping automatic MCP client configuration.${COLOR_RESET}"
        echo -e "To configure automatically, set ${COLOR_BOLD}FRONTEND_ASSISTANT=bob|claude${COLOR_RESET} in llm.env or pass ${COLOR_BOLD}--frontend bob|claude${COLOR_RESET} as a CLI argument."
        echo ""
    } >/dev/tty 2>/dev/null || true
    log_validation_success "Frontend assistant config (skipped — not set)"
else
    log_section "Step 4: Registering Causa MCP in Frontend Assistant ($FRONTEND_ASSISTANT)"

    # ── 4a: Register in Bob IDE (if FRONTEND_ASSISTANT is bob or all) ─────────
    if [[ "$FRONTEND_ASSISTANT" == "bob" || "$FRONTEND_ASSISTANT" == "all" ]]; then
        start_spinner "Writing Causa MCP entry to ~/.bob/settings/mcp.json..."
        _bob_mcp_dir="$(dirname "$BOB_MCP_CONFIG")"
        mkdir -p "$_bob_mcp_dir"

        if command_exists python3; then
            python3 - "$BOB_MCP_CONFIG" "$CAUSA_MCP_URL" << 'PYEOF'
import json, sys, os
path, url = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}
cfg.setdefault("mcpServers", {})["causa-rca"] = {
    "type": "http",
    "url": url + "/mcp",
    "description": "Causa RCA — root cause analysis for Quarkus/Java apps"
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("ok")
PYEOF
            _reg_rc=$?
        elif command_exists jq; then
            _jq_input="{}"
            [[ -f "$BOB_MCP_CONFIG" ]] && _jq_input=$(cat "$BOB_MCP_CONFIG")
            printf '%s' "$_jq_input" \
                | jq --arg url "$CAUSA_MCP_URL/mcp" \
                  '.mcpServers["causa-rca"] = {"type":"http","url":$url,"description":"Causa RCA — root cause analysis for Quarkus/Java apps"}' \
                > "${BOB_MCP_CONFIG}.tmp" \
                && mv "${BOB_MCP_CONFIG}.tmp" "$BOB_MCP_CONFIG"
            _reg_rc=$?
        else
            if [[ ! -f "$BOB_MCP_CONFIG" ]]; then
                printf '{"mcpServers":{"causa-rca":{"type":"http","url":"%s/mcp","description":"Causa RCA"}}}\n' \
                    "$CAUSA_MCP_URL" > "$BOB_MCP_CONFIG"
                _reg_rc=$?
            else
                write_to_log_file "WARN" \
                    "python3 and jq not found — existing $BOB_MCP_CONFIG not updated; add causa-rca entry manually"
                _reg_rc=1
            fi
        fi

        stop_spinner
        if [[ $_reg_rc -eq 0 ]]; then
            log_install_success "Causa MCP registered in Bob IDE ($CAUSA_MCP_URL/mcp)"
            write_to_log_file "INFO" "Bob MCP config: $BOB_MCP_CONFIG"
        else
            log_file_only "Bob MCP config update failed — add manually (see below)"
            log_validation_success "Bob IDE config (failed — add manually)"
        fi

        # Copy causa-rca SKILL.md to ~/.bob/skills/
        BOB_SKILL_DIR="${HOME}/.bob/skills/causa-rca"
        BOB_SKILL_FILE="${BOB_SKILL_DIR}/SKILL.md"
        REPO_SKILL_FILE="${SCRIPT_DIR}/../.bob/skills/causa-rca/SKILL.md"

        start_spinner "Copying causa-rca SKILL.md to Bob IDE..."
        mkdir -p "$BOB_SKILL_DIR"

        if [[ -f "$REPO_SKILL_FILE" ]]; then
            cp "$REPO_SKILL_FILE" "$BOB_SKILL_FILE"
            _skill_rc=$?
        else
            cat > "$BOB_SKILL_FILE" << 'SKILL_EOF'
---
name: causa-rca
description: Activate when a developer asks about application health, diagnostics, root cause analysis, existing RCA results, or why their application is failing.
compatibility: Requires the Causa MCP server to be configured in Bob with tools initiate_rca and get_rca_result.
---

# Causa RCA Skill

Use tools initiate_rca and get_rca_result from the Causa MCP server.
See the full SKILL.md in the causa-demos repo for complete instructions.
SKILL_EOF
            _skill_rc=$?
        fi

        stop_spinner
        if [[ $_skill_rc -eq 0 && -f "$BOB_SKILL_FILE" ]]; then
            log_install_success "causa-rca SKILL.md written to Bob IDE"
            write_to_log_file "INFO" "Skill: $BOB_SKILL_FILE"
        else
            log_file_only "Failed to write causa-rca SKILL.md"
            log_validation_success "causa-rca skill (failed — copy manually to ~/.bob/skills/causa-rca/SKILL.md)"
        fi
    fi

    # ── 4b: Register in Claude Desktop (if FRONTEND_ASSISTANT is claude or all) ─
    if [[ "$FRONTEND_ASSISTANT" == "claude" || "$FRONTEND_ASSISTANT" == "all" ]]; then
        start_spinner "Writing Causa MCP entry to Claude Desktop config..."
        _claude_mcp_dir="$(dirname "$CLAUDE_MCP_CONFIG")"
        mkdir -p "$_claude_mcp_dir"

        _claude_reg_rc=1
        if command_exists python3; then
            python3 - "$CLAUDE_MCP_CONFIG" "$CAUSA_MCP_URL" << 'PYEOF'
import json, sys, os
path, url = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}
# Claude Desktop format uses command/url or sse/http depending on version
# For SSE / HTTP MCP servers:
cfg.setdefault("mcpServers", {})["causa-rca"] = {
    "url": url + "/mcp",
    "type": "http"
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("ok")
PYEOF
            _claude_reg_rc=$?
        fi
        stop_spinner
        if [[ $_claude_reg_rc -eq 0 ]]; then
            log_install_success "Causa MCP registered in Claude Desktop config"
            write_to_log_file "INFO" "Claude MCP config: $CLAUDE_MCP_CONFIG"
        else
            log_file_only "Claude MCP config not written (non-fatal)"
            log_validation_success "Claude Desktop config (skipped or manual configuration required)"
        fi
    fi
fi

# ===========================================================================
# Step 5: Print Assistant Ready Prompts with container / namespace / pod info
# ===========================================================================
# Identify the current quarkus-perf pod name so we can give the user a
# ready-to-paste prompt for Bob IDE / Claude / any LLM chat interface.
# ===========================================================================

# Discover current quarkus-perf pod name (may be empty right after deploy)
_QP_POD=$(kubectl get pod \
    -n "$NAMESPACE" \
    -l "app=quarkus-perf" \
    --field-selector="status.phase=Running" \
    -o "jsonpath={.items[0].metadata.name}" \
    2>>"$LOG_FILE" || true)

# If not running yet, grab any pod in any phase for the prompt
if [[ -z "$_QP_POD" ]]; then
    _QP_POD=$(kubectl get pod \
        -n "$NAMESPACE" \
        -l "app=quarkus-perf" \
        -o "jsonpath={.items[0].metadata.name}" \
        2>>"$LOG_FILE" || true)
fi

_POD_DISPLAY="${_QP_POD:-quarkus-perf-<generated-suffix>}"

{
    echo ""
    echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
    if [[ "$FRONTEND_ASSISTANT" == "claude" ]]; then
        echo -e "${COLOR_BOLD_GREEN}  Demo is ready. Switch to Claude Desktop now.${COLOR_RESET}"
    elif [[ "$FRONTEND_ASSISTANT" == "bob" ]]; then
        echo -e "${COLOR_BOLD_GREEN}  Demo is ready. Switch to Bob IDE now.${COLOR_RESET}"
    else
        echo -e "${COLOR_BOLD_GREEN}  Demo is ready. Connect your AI assistant to Causa MCP.${COLOR_RESET}"
    fi
    echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}What's happening:${COLOR_RESET}"
    echo -e "  • quarkus-perf is running with 3 enabled chaos scenarios from chaos-lab"
    echo -e "  • ${SCENARIO_HTTP_LARGE_RESPONSE}: CHAOS_HTTP_LARGE_RESPONSE_ENABLED=true"
    echo -e "  • ${SCENARIO_HTTP_IDLE_TIMEOUT}: CHAOS_HTTP_IDLE_TIMEOUT_ENABLED=true"
    echo -e "  • ${SCENARIO_MEMORY_CACHE}: CHAOS_MEMORY_CACHE_ENABLED=true"
    echo -e "  • load-gen is hitting /api/bookings + /api/accounts/*/transactions"
    echo -e "  • Combined pressure can surface RCA for HTTP heap pressure and OOM-like failures"

    echo ""
    echo -e "${COLOR_BOLD_YELLOW}Workload details:${COLOR_RESET}"
    echo -e "  Container:  ${COLOR_BOLD}${WORKLOAD_CONTAINER_NAME}${COLOR_RESET}"
    echo -e "  Namespace:  ${COLOR_BOLD}${NAMESPACE}${COLOR_RESET}"
    echo -e "  Pod:        ${COLOR_BOLD}${_POD_DISPLAY}${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}Type this in Bob IDE chat:${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 1 — investigate any active failure:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate why my quarkus-perf app is unhealthy."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check existing diagnostics first, then run RCA if needed, and show the root cause and fix.${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 2 — focus on HTTP large-response pressure:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate whether quarkus-perf has HTTP or memory pressure from the large-response scenario."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check if large responses and idle connections are causing heap growth, then summarize the RCA.${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 3 — focus on idle-timeout pressure:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate whether quarkus-perf is unhealthy because connections are being held open too long."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check existing diagnostics first and explain whether the idle-timeout scenario is contributing to the failure.${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 4 — focus on memory-cache / OOM:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate whether quarkus-perf is hitting a memory leak or OOM condition."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check for memory issues, use existing diagnostics if present, otherwise run a fresh RCA, and show the fix.${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}What Bob will do:${COLOR_RESET}"
    echo -e "  1. Use the causa-rca skill flow from ${BOB_SKILL_FILE}"
    echo -e "  2. Check existing diagnostics before starting a duplicate RCA"
    echo -e "  3. Initiate RCA for ${WORKLOAD_APP_NAME} in namespace ${NAMESPACE} when needed"
    echo -e "  4. Poll until COMPLETED, then present root cause + fix"
    echo ""
    echo -e "${COLOR_CYAN}Note:${COLOR_RESET} You can prompt Bob immediately — no need to wait for an OOMKill."
    echo -e "  Watch pod restarts: ${COLOR_BOLD}kubectl get pods -n ${NAMESPACE} -w${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Causa Backend:${COLOR_RESET} ${CAUSA_BACKEND_URL}/api/v1/diagnostics"
    echo -e "${COLOR_CYAN}Causa MCP:${COLOR_RESET}     ${CAUSA_MCP_URL}/mcp"
    if [[ "$FRONTEND_ASSISTANT" == "bob" || "$FRONTEND_ASSISTANT" == "all" ]]; then
        echo -e "${COLOR_CYAN}Bob Skill file:${COLOR_RESET} ${BOB_SKILL_FILE:-${HOME}/.bob/skills/causa-rca/SKILL.md}"
        echo -e "${COLOR_CYAN}Bob MCP config:${COLOR_RESET} ${BOB_MCP_CONFIG}"
    fi
    if [[ "$FRONTEND_ASSISTANT" == "claude" || "$FRONTEND_ASSISTANT" == "all" ]]; then
        echo -e "${COLOR_CYAN}Claude config:${COLOR_RESET}  ${CLAUDE_MCP_CONFIG}"
    fi
    if [[ -z "$FRONTEND_ASSISTANT" || "$FRONTEND_ASSISTANT" == "none" ]]; then
        echo -e "${COLOR_CYAN}Frontend Assistant:${COLOR_RESET} Not configured (add ${CAUSA_MCP_URL}/mcp to your MCP client)"
    fi
    echo ""
} >/dev/tty 2>/dev/null || true

# ---------------------------------------------------------------------------
# Completion summary
# ---------------------------------------------------------------------------
ELAPSED=$(get_elapsed_time "$SCRIPT_START_TIME")
write_to_log_file "SUCCESS" "Demo setup completed in $ELAPSED"

{
    echo "========================================"
    echo "Quarkus RCA Demo — Completed"
    echo "========================================"
    echo "Namespace:    $NAMESPACE"
    echo "Demo log:     $LOG_FILE"
    [[ "$SKIP_INSTALLER" == "false" && -n "${INSTALLER_DIR:-}" ]] && \
        echo "Installer log: ${INSTALLER_DIR}/install.log"
    echo "========================================"
} >>"$LOG_FILE"

{
    echo -e "${COLOR_BOLD_YELLOW}Total setup time: $ELAPSED${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Log file: ${LOG_FILE}${COLOR_RESET}"
    echo ""
} >/dev/tty 2>/dev/null || true
