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
#   Step 4 — Writes .mcp.json to the repo root (cross-IDE MCP standard;
#             auto-loaded by Claude shell, Cursor, Windsurf, VS Code Copilot,
#             Gemini CLI and others — no per-user setup required).
#             Optionally installs the causa-rca SKILL.md to a user-supplied
#             path via --skill-path <dir>.
#
#   Step 5 — Prints ready prompts and skill setup instructions
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
SKILL_PATH=""
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

# Causa MCP Server is on NodePort 30005 (see installer manifests/causa_mcp/deployment.yaml)
CAUSA_MCP_URL="http://localhost:30005"
CAUSA_BACKEND_URL="http://localhost:30001"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
show_help() {
    echo "Quarkus RCA Demo Script"
    echo ""
    echo "Usage: $0 [--target TARGET] [-n namespace] [--skill-path DIR] [-t] [--skip-installer] [--installer-url URL] [--installer-branch BRANCH] [--chaos-lab-url URL] [--chaos-lab-branch BRANCH] [-h]"
    echo ""
    echo "Options:"
    echo "    --target TARGET          Target platform: kind, openshift, vm, etc. (default: kind)"
    echo "                             Passed directly to installer install.sh --target <TARGET>."
    echo "    -n namespace             Namespace for the RCA stack and workload (default: causa-rca)"
    echo "    --skill-path DIR         Directory to install the causa-rca skill into."
    echo "                             The script appends /causa-rca and writes SKILL.md"
    echo "                             at the correct location for the detected tool."
    echo "                             If the copy fails, manual instructions are printed."
    echo "                             Examples:"
    echo "                               --skill-path ~/.bob/skills        (Bob)"
    echo "                               --skill-path ~/.claude/skills     (Claude Code)"
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
    echo "MCP server registration:"
    echo "    .mcp.json is always written to the repo root. Any IDE that supports the"
    echo "    cross-IDE MCP standard (Claude shell, Cursor, Windsurf, VS Code Copilot,"
    echo "    Gemini CLI) auto-loads it — no per-user or per-IDE setup required."
    echo ""
    echo "Skill installation:"
    echo "    Pass --skill-path <dir> to have the script copy SKILL.md to that location."
    echo "    If omitted, the script prints manual instructions at the end instead."
    echo ""
    echo "Backend RCA LLM:"
    echo "    Configured via llm.env / environment:"
    echo "        LLM_PROVIDER=vertex-ai-anthropic | anthropic | bob | openai | bedrock | ..."
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
    echo "    # Full automated demo (MCP registered, manual skill setup printed at end)"
    echo "    $0"
    echo ""
    echo "    # Also install skill to Bob"
    echo "    $0 --skill-path ~/.bob/skills"
    echo ""
    echo "    # Also install skill to Claude Code"
    echo "    $0 --skill-path ~/.claude/skills"
    echo ""
    echo "    # Deploy to OpenShift or VM target"
    echo "    $0 --target openshift -n my-rca"
    echo "    $0 --target vm"
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
while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --target" >&2; exit 1; }
            TARGET="$2"; shift 2 ;;
        -n)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for -n" >&2; exit 1; }
            NAMESPACE="$2"; shift 2 ;;
        --skill-path)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --skill-path" >&2; exit 1; }
            SKILL_PATH="$2"; shift 2 ;;
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
# Load llm.env early
# ---------------------------------------------------------------------------
_LLM_ENV_FILE="$SCRIPT_DIR/llm.env"
if [[ -f "$_LLM_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$_LLM_ENV_FILE"
    set +a
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
    print_banner "Quarkus RCA Demo — Cleanup"
    write_to_log_file "INFO" "Demo Cleanup — namespace: $NAMESPACE"
else
    print_banner "Running Quarkus RCA Demo"
    write_to_log_file "INFO" "Demo Setup — namespace: $NAMESPACE, target: $TARGET, skill-path: ${SKILL_PATH:-not set}"
    print_kv_row "Target"           "$TARGET"
    print_kv_row "Namespace"        "$NAMESPACE"
    print_kv_row "Skill Path"       "${SKILL_PATH:-not set (printed at end)}"
    print_kv_row "Installer URL"    "$INSTALLER_URL"
    print_kv_row "Installer Branch" "$INSTALLER_BRANCH"
    print_kv_row "Chaos Lab URL"    "$CHAOS_LAB_URL"
    print_kv_row "Chaos Lab Branch" "$CHAOS_LAB_BRANCH"
    echo "" >/dev/tty 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Terminate mode
# ---------------------------------------------------------------------------
if [[ "$TERMINATE" == "true" ]]; then
    terminate_demo "$NAMESPACE" "$DEMO_DIR" "$SKIP_INSTALLER"

    # Remove causa-rca from project-level .mcp.json
    _MCP_JSON_PATH="${SCRIPT_DIR}/../.mcp.json"
    if [[ -f "$_MCP_JSON_PATH" ]]; then
        start_spinner "Removing Causa MCP from project .mcp.json..."
        _remove_mcp_json_rc=1
        if command_exists python3; then
            python3 - "$_MCP_JSON_PATH" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    cfg.get("mcpServers", {}).pop("causa-rca", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("removed")
except Exception as e:
    print(f"warn: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
            _remove_mcp_json_rc=$?
        fi
        stop_spinner
        if [[ $_remove_mcp_json_rc -eq 0 ]]; then
            log_install_success "Causa MCP removed from project .mcp.json"
        fi
    fi

    ELAPSED=$(get_elapsed_time "$SCRIPT_START_TIME")
    write_to_log_file "SUCCESS" "Total cleanup time: $ELAPSED"
    print_elapsed "$ELAPSED"
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
# Validate required binaries (git, kubectl, python3; kind when target=kind)
if ! check_prerequisites "$TARGET"; then
    exit 1
fi

# Verify the Kubernetes API is reachable before starting any deployment.
# Skip this check when target=kind and the installer is going to run — the
# installer creates the Kind cluster as part of Step 1, so the API does not
# need to exist yet. Only check when the cluster must already be present:
#   - --skip-installer is set (stack already deployed, cluster must be up)
#   - target is not kind (openshift etc. require a pre-existing cluster)
if [[ "$SKIP_INSTALLER" == "true" || "$TARGET" != "kind" ]]; then
    if ! check_cluster_reachability; then
        exit 1
    fi
fi

# For kind targets, verify host inotify limits are sufficient for the
# jafra-agent. kind nodes share the host sysctl namespace; low defaults
# (max_user_instances=128) cause EMFILE crashes after repeated restarts.
if [[ "$TARGET" == "kind" ]]; then
    if ! tune_kind_node_sysctls; then
        exit 1
    fi
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
    # Images are loaded from images.env at script startup (set -a) and passed
    # as explicit flags to install.sh. To change any image, edit images.env.
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
    [[ -n "${JAFRA_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--jafra-mcp-image "$JAFRA_MCP_IMAGE")
    [[ -n "${ASYNC_PROFILER_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--async-profiler-image "$ASYNC_PROFILER_IMAGE")
    [[ -n "${ASYNC_PROFILER_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--async-profiler-mcp-image "$ASYNC_PROFILER_MCP_IMAGE")
    [[ -n "${QUARKUS_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--quarkus-mcp-image "$QUARKUS_MCP_IMAGE")

    write_to_log_file "INFO" "Running: bash $INSTALL_SCRIPT ${_INSTALL_ARGS[*]}"

    # Run install.sh — use /usr/bin/env bash so it picks up the best bash on
    # PATH (e.g. Homebrew bash 5) rather than hardcoding /bin/bash (macOS 3.2).
    /usr/bin/env bash "$INSTALL_SCRIPT" "${_INSTALL_ARGS[@]}" \
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
# Step 4: Register Causa MCP + install skill (optional)
# ===========================================================================

# ── 4a: Always write .mcp.json to the repo root ──────────────────────────
# .mcp.json is the cross-IDE project-level MCP standard. Any IDE that
# supports MCP (Claude shell, Cursor, Windsurf, VS Code Copilot, Gemini CLI)
# auto-loads this file when the developer opens or cd's into the project —
# no per-user setup required.
_MCP_JSON_PATH="${SCRIPT_DIR}/../.mcp.json"
log_section "Step 4: Writing project-level .mcp.json"
start_spinner "Writing .mcp.json to repo root..."
_mcp_json_rc=1
if command_exists python3; then
    python3 - "$_MCP_JSON_PATH" "$CAUSA_MCP_URL" << 'PYEOF'
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
    "url": url + "/mcp"
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("ok")
PYEOF
    _mcp_json_rc=$?
fi
stop_spinner
if [[ $_mcp_json_rc -eq 0 ]]; then
    log_install_success ".mcp.json written (${_MCP_JSON_PATH})"
    write_to_log_file "INFO" ".mcp.json path: $_MCP_JSON_PATH"
else
    log_file_only "Failed to write .mcp.json — add manually"
    log_validation_success ".mcp.json (failed — add manually)"
fi

# ── 4b: Install SKILL.md to user-supplied path (optional) ────────────────
# Invoked only when --skill-path DIR is passed. The script resolves the
# target file name and any tool-specific handling automatically:
#
#   ~/.bob/skills               → appends /causa-rca and copies as SKILL.md
#   ~/.bob/skills/causa-rca     → copied as SKILL.md (same result, explicit)
#   ~/.claude/skills            → appends /causa-rca and copies as SKILL.md
#                                 (Claude Code skills dir — invokable as /causa-rca)
#   ~/.claude/skills/causa-rca  → copied as SKILL.md (same result, explicit)
#   ~/.claude (bare)            → prints a warning and copies as CLAUDE.md
#                                 (global prompt only — /causa-rca command will NOT work;
#                                  use ~/.claude/skills instead for the full skill experience)
#   any other dir               → copied as SKILL.md; a note is printed that
#                                 the tool may need manual wiring
#
# If the copy fails for any reason the step is non-fatal — manual
# instructions are always printed at the end of the script.
_SKILL_INSTALLED=false
_SKILL_INSTALL_NOTE=""
_REPO_SKILL_FILE="${SCRIPT_DIR}/../skills/causa-rca/SKILL.md"

if [[ -n "$SKILL_PATH" ]]; then
    log_section "Step 4: Installing causa-rca skill to $SKILL_PATH"

    # Resolve the skill source
    if [[ ! -f "$_REPO_SKILL_FILE" ]]; then
        write_to_log_file "WARN" "SKILL.md not found at $_REPO_SKILL_FILE — skill install skipped"
        log_validation_success "Skill install (skipped — SKILL.md not found in repo)"
        _SKILL_INSTALL_NOTE="SKILL.md was not found in the repo at $_REPO_SKILL_FILE. Install it manually."
    else
        # Expand tilde in SKILL_PATH
        SKILL_PATH="${SKILL_PATH/#\~/$HOME}"

        # Detect IDE from path and adjust target accordingly
        _install_mode="copy"  # default: plain copy as SKILL.md

        if [[ "$SKILL_PATH" == "$HOME/.bob/skills" || "$SKILL_PATH" == *"/.bob/skills" ]]; then
            # Bob IDE: skills live in named subdirectories — append causa-rca automatically
            SKILL_PATH="${SKILL_PATH}/causa-rca"
        elif [[ "$SKILL_PATH" == "$HOME/.claude/skills" || "$SKILL_PATH" == *"/.claude/skills" ]]; then
            # Claude Code skills directory: skills live in named subdirectories
            SKILL_PATH="${SKILL_PATH}/causa-rca"
        elif [[ "$SKILL_PATH" == "$HOME/.claude" || "$SKILL_PATH" == *"/.claude" ]]; then
            # ~/.claude (bare): writes CLAUDE.md as a global prompt — the /causa-rca
            # command and auto-invocation will NOT work. Warn the user and continue.
            log_validation_success "Warning: ~/.claude installs as a global prompt only — use --skill-path ~/.claude/skills for the full /causa-rca skill experience"
            _install_mode="claude"
        fi

        mkdir -p "$SKILL_PATH"

        # Resolve final file path
        _resolved_skill_path="$SKILL_PATH/SKILL.md"
        if [[ "$_install_mode" == "claude" ]]; then
            _resolved_skill_path="$SKILL_PATH/CLAUDE.md"
        fi

        start_spinner "Installing SKILL.md to ${_resolved_skill_path}..."

        _skill_install_rc=1
        if [[ "$_install_mode" == "claude" ]]; then
            # Strip YAML front-matter before writing
            python3 - "$_REPO_SKILL_FILE" "$_resolved_skill_path" << 'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()
content = re.sub(r'^---\n.*?\n---\n', '', content, count=1, flags=re.DOTALL)
with open(dst, 'w') as f:
    f.write(content.strip() + "\n")
print("ok")
PYEOF
            _skill_install_rc=$?
        else
            cp "$_REPO_SKILL_FILE" "$_resolved_skill_path"
            _skill_install_rc=$?
        fi

        stop_spinner
        if [[ $_skill_install_rc -eq 0 ]]; then
            log_install_success "causa-rca skill installed to ${_resolved_skill_path}"
            write_to_log_file "INFO" "Skill installed: $_resolved_skill_path"
            _SKILL_INSTALLED=true
            _SKILL_INSTALL_PATH="$_resolved_skill_path"
        else
            log_file_only "Failed to install skill to $_resolved_skill_path (non-fatal)"
            log_validation_success "Skill install (failed — see manual instructions at end)"
            _SKILL_INSTALL_NOTE="Automatic install to $_resolved_skill_path failed. Install it manually (see below)."
        fi
    fi
else
    log_section "Step 4: Skill installation (Skipped — no --skill-path given)"
    write_to_log_file "INFO" "No --skill-path provided — skill not installed automatically"
    log_validation_success "Skill install (skipped — manual instructions printed at end)"
fi

# ===========================================================================
# Step 5: Print ready prompts + skill setup instructions
# ===========================================================================

# Discover current quarkus-perf pod name (may be empty right after deploy)
_QP_POD=$(kubectl get pod \
    -n "$NAMESPACE" \
    -l "app=quarkus-perf" \
    --field-selector="status.phase=Running" \
    -o "jsonpath={.items[0].metadata.name}" \
    2>>"$LOG_FILE" || true)
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
    echo -e "${COLOR_BOLD_GREEN}  Demo is ready. Open your AI assistant.${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}What's happening:${COLOR_RESET}"
    echo -e "  • quarkus-perf is running with 3 enabled chaos scenarios from chaos-lab"
    echo -e "  • ${SCENARIO_HTTP_LARGE_RESPONSE}: CHAOS_HTTP_LARGE_RESPONSE_ENABLED=true"
    echo -e "  • ${SCENARIO_HTTP_IDLE_TIMEOUT}: CHAOS_HTTP_IDLE_TIMEOUT_ENABLED=true"
    echo -e "  • ${SCENARIO_MEMORY_CACHE}: CHAOS_MEMORY_CACHE_ENABLED=true"
    echo -e "  • load-gen is hitting /api/bookings + /api/accounts/*/transactions"
    echo -e "  • Combined pressure surfaces RCA for HTTP heap pressure and OOM-like failures"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}Workload details:${COLOR_RESET}"
    echo -e "  Container:  ${COLOR_BOLD}${WORKLOAD_CONTAINER_NAME}${COLOR_RESET}"
    echo -e "  Namespace:  ${COLOR_BOLD}${NAMESPACE}${COLOR_RESET}"
    echo -e "  Pod:        ${COLOR_BOLD}${_POD_DISPLAY}${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}Paste one of these prompts into your AI assistant:${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 1 — investigate any active failure:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate why my quarkus-perf app is unhealthy."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check existing diagnostics first, then run RCA if needed, and show the root cause and fix.${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 2 — HTTP large-response pressure:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate whether quarkus-perf has HTTP or memory pressure from the large-response scenario."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check if large responses and idle connections are causing heap growth, then summarize the RCA.${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 3 — idle-timeout pressure:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate whether quarkus-perf is unhealthy because connections are being held open too long."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check existing diagnostics first and explain whether the idle-timeout scenario is contributing to the failure.${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Prompt 4 — memory-cache / OOM:${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Use the causa-rca skill to investigate whether quarkus-perf is hitting a memory leak or OOM condition."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE}, container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Check for memory issues, use existing diagnostics if present, otherwise run a fresh RCA, and show the fix.${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Your AI assistant will:${COLOR_RESET}"
    echo -e "  1. Use the Causa MCP tools registered via .mcp.json"
    echo -e "  2. Check existing diagnostics before starting a duplicate RCA"
    echo -e "  3. Initiate RCA for ${WORKLOAD_APP_NAME} in namespace ${NAMESPACE} when needed"
    echo -e "  4. Poll until COMPLETED, then present root cause + fix"
    echo ""
    echo -e "${COLOR_CYAN}Note:${COLOR_RESET} You can prompt immediately — no need to wait for an OOMKill."
    echo -e "  Watch pod restarts: ${COLOR_BOLD}kubectl get pods -n ${NAMESPACE} -w${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Causa Backend:${COLOR_RESET} ${CAUSA_BACKEND_URL}/api/v1/diagnostics"
    echo -e "${COLOR_CYAN}Causa MCP:${COLOR_RESET}     ${CAUSA_MCP_URL}/mcp"
    echo -e "${COLOR_CYAN}Project MCP config:${COLOR_RESET} ${SCRIPT_DIR}/../.mcp.json"
    echo ""

    # ── Skill setup summary ─────────────────────────────────────────────────
    echo -e "${COLOR_CYAN}${COLOR_BOLD}----------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_BOLD_YELLOW}Skill setup:${COLOR_RESET}"
    if [[ "$_SKILL_INSTALLED" == "true" ]]; then
        echo -e "  ${COLOR_BOLD_GREEN}✓ Installed to: ${_SKILL_INSTALL_PATH}${COLOR_RESET}"
        echo -e "  Your AI assistant will load it automatically from that location."
    else
        if [[ -n "$_SKILL_INSTALL_NOTE" ]]; then
            echo -e "  ${COLOR_YELLOW}⚠ ${_SKILL_INSTALL_NOTE}${COLOR_RESET}"
            echo ""
        else
            echo -e "  ${COLOR_YELLOW}Skill was not installed automatically (no --skill-path given).${COLOR_RESET}"
            echo ""
        fi
        echo -e "  ${COLOR_BOLD}To configure it manually, copy the SKILL.md to your IDE's skill directory:${COLOR_RESET}"
        echo ""
        echo -e "  ${COLOR_BOLD}Skill file location in this repo:${COLOR_RESET}"
        echo -e "    ${SCRIPT_DIR}/../skills/causa-rca/SKILL.md"
        echo ""
        echo -e "  ${COLOR_BOLD}Bob IDE${COLOR_RESET}"
        echo -e "    mkdir -p ~/.bob/skills/causa-rca"
        echo -e "    cp ${SCRIPT_DIR}/../skills/causa-rca/SKILL.md ~/.bob/skills/causa-rca/SKILL.md"
        echo -e "  ${COLOR_BOLD}  Or re-run:${COLOR_RESET} $0 --skill-path ~/.bob/skills"
        echo ""
        echo -e "  ${COLOR_BOLD}Claude Code${COLOR_RESET}"
        echo -e "    mkdir -p ~/.claude/skills/causa-rca"
        echo -e "    cp ${SCRIPT_DIR}/../skills/causa-rca/SKILL.md ~/.claude/skills/causa-rca/SKILL.md"
        echo -e "  ${COLOR_BOLD}  Or re-run:${COLOR_RESET} $0 --skill-path ~/.claude/skills"
        echo ""
        echo -e "  ${COLOR_BOLD}Cursor / Windsurf / other IDEs${COLOR_RESET}"
        echo -e "    Copy SKILL.md content into your IDE's rules/instructions file."
    fi
    echo -e "${COLOR_CYAN}${COLOR_BOLD}----------------------------------------${COLOR_RESET}"
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

print_elapsed "$ELAPSED"
echo -e "${COLOR_CYAN}Log file: ${LOG_FILE}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
echo "" >/dev/tty 2>/dev/null || true
