#!/usr/bin/env bash
################################################################################
# LLM configuration helpers for the Quarkus RCA demo.
#
# Mirrors the two-phase pattern from runtimes-intelligence-demo/lib/llm.sh:
#
#   validate_llm_config  LLM_ENV_FILE
#     Validates required fields before any deployment starts.
#     Exits early with clear errors on misconfiguration.
#
#   create_llm_secrets  LLM_ENV_FILE  NAMESPACE
#     Phase 1 — called BEFORE the installer.
#     Creates the causa-gcp-credentials K8s Secret from the credentials file
#     so the secret exists when the installer deploys causa-backend.
#
#   configure_llm_runtime  LLM_ENV_FILE  NAMESPACE
#     Phase 2 — called AFTER the installer.
#     POSTs only the non-sensitive config keys (LLM_PROVIDER, LLM_MODEL_NAME,
#     VERTEX_PROJECT_ID, VERTEX_LOCATION) to POST /api/v1/configs.
#     The GCP credential reaches the backend via the K8s Secret created in
#     Phase 1 and the GOOGLE_APPLICATION_CREDENTIALS env var set in the
#     causa-backend deployment — it is never POSTed through the API.
################################################################################

# Source guard
if [[ -n "${LLM_LIB_LOADED:-}" ]]; then return 0; fi
readonly LLM_LIB_LOADED=1

# ---------------------------------------------------------------------------
# validate_llm_config  LLM_ENV_FILE
#
# Checks that all required fields for the chosen provider are present and the
# credentials file exists. Sources LLM_ENV_FILE in a subshell so the parent
# environment is not polluted. Exits with clear error messages on failure.
#
# Supported providers:  vertex-ai-anthropic  |  anthropic
# ---------------------------------------------------------------------------
validate_llm_config() {
    local llm_env_file="$1"
    local errors=()

    if [[ -z "$llm_env_file" ]]; then
        log_error "validate_llm_config: llm.env path not provided"
        log_error "  Copy llm.env.example to llm.env and fill in your values"
        return 1
    fi

    if [[ ! -f "$llm_env_file" ]]; then
        log_error "LLM configuration file not found: $llm_env_file"
        log_error "  cp $(dirname "$llm_env_file")/llm.env.example $llm_env_file"
        return 1
    fi

    # Read values in subshells — never pollute the parent environment here.
    local provider model_name location project_id creds_file api_key
    provider=$(    bash -c "set -a; source \"$llm_env_file\"; echo \"\${LLM_PROVIDER:-}\"")
    model_name=$(  bash -c "set -a; source \"$llm_env_file\"; echo \"\${LLM_MODEL_NAME:-}\"")
    location=$(    bash -c "set -a; source \"$llm_env_file\"; echo \"\${VERTEX_LOCATION:-}\"")
    project_id=$(  bash -c "set -a; source \"$llm_env_file\"; echo \"\${VERTEX_PROJECT_ID:-}\"")
    creds_file=$(  bash -c "set -a; source \"$llm_env_file\"; eval echo \"\${GOOGLE_APPLICATION_CREDENTIALS:-}\"")
    api_key=$(     bash -c "set -a; source \"$llm_env_file\"; echo \"\${LLM_API_KEY:-}\"")

    log_file_only "LLM validation: reading from $llm_env_file"

    if [[ -z "$provider" ]]; then
        errors+=("LLM_PROVIDER is not set in $llm_env_file")
    fi

    case "$provider" in
        vertex-ai-anthropic)
            [[ -z "$model_name"  ]] && errors+=("LLM_MODEL_NAME is not set")
            [[ -z "$project_id"  ]] && errors+=("VERTEX_PROJECT_ID is not set")
            if [[ -z "$location" ]]; then
                errors+=("VERTEX_LOCATION is not set (valid: us-east5, us-central1, europe-west1, asia-southeast1)")
            elif [[ "$location" == "global" ]]; then
                errors+=("VERTEX_LOCATION='global' is not valid for Claude on Vertex AI — use us-east5, us-central1, europe-west1, or asia-southeast1")
            fi
            if [[ -z "$creds_file" ]]; then
                errors+=("GOOGLE_APPLICATION_CREDENTIALS is not set in $llm_env_file")
            elif [[ ! -f "$creds_file" ]]; then
                errors+=("GOOGLE_APPLICATION_CREDENTIALS='$creds_file' does not exist")
            fi
            ;;
        anthropic)
            [[ -z "$model_name" ]] && errors+=("LLM_MODEL_NAME is not set")
            [[ -z "$api_key"    ]] && errors+=("LLM_API_KEY is not set")
            ;;
        "")
            : # already captured above
            ;;
        *)
            errors+=("LLM_PROVIDER='$provider' is not supported (supported: vertex-ai-anthropic, anthropic)")
            ;;
    esac

    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "LLM configuration validation failed ($llm_env_file):"
        for err in "${errors[@]}"; do
            log_error "  • $err"
            log_file_only "LLM validation error: $err"
        done
        log_error "Edit $llm_env_file and fix the above before re-running."
        return 1
    fi

    log_file_only "LLM validation passed: provider=$provider"
    return 0
}

# ---------------------------------------------------------------------------
# create_llm_secrets  LLM_ENV_FILE  NAMESPACE
#
# Phase 1 — create K8s secrets BEFORE the installer runs.
#
#   vertex-ai-anthropic:
#     causa-gcp-credentials — the raw credentials file stored as key.json,
#     mounted by the causa-backend deployment at
#     /var/secrets/google/key.json via the GOOGLE_APPLICATION_CREDENTIALS
#     env var (set in the deployment manifest).
#
#   anthropic:
#     causa-llm-secrets — LLM_API_KEY stored as a K8s secret.
#
# No-op (with a warning) if the credentials file is missing.
# ---------------------------------------------------------------------------
create_llm_secrets() {
    local llm_env_file="$1"
    local namespace="$2"

    # Source so variables are available to the rest of this function.
    # set -a ensures they're exported for any child processes too.
    set -a
    # shellcheck disable=SC1090
    source "$llm_env_file"
    set +a

    local creds_file
    creds_file=$(eval echo "${GOOGLE_APPLICATION_CREDENTIALS:-}")
    # Also accept a local causa-gcp-key.json next to the script as a fallback
    if [[ -z "$creds_file" || ! -f "$creds_file" ]]; then
        if [[ -f "$SCRIPT_DIR/causa-gcp-key.json" ]]; then
            creds_file="$SCRIPT_DIR/causa-gcp-key.json"
        fi
    fi

    case "${LLM_PROVIDER:-}" in
        vertex-ai-anthropic)
            if kubectl get secret causa-gcp-credentials \
                    -n "$namespace" >>"${LOG_FILE}" 2>&1; then
                write_to_log_file "INFO" "causa-gcp-credentials already exists in $namespace — skipping creation"
                return 0
            fi

            if [[ ! -f "$creds_file" ]]; then
                write_to_log_file "WARN" "GCP credentials file not found at $creds_file"
                write_to_log_file "WARN" "Set GOOGLE_APPLICATION_CREDENTIALS in llm.env or place causa-gcp-key.json next to demo.sh"
                return 0
            fi

            start_spinner "Creating causa-gcp-credentials secret..."
            if kubectl create secret generic causa-gcp-credentials \
                    --from-file="key.json=$creds_file" \
                    -n "$namespace" >>"${LOG_FILE}" 2>&1; then
                stop_spinner
                log_install_success "causa-gcp-credentials secret created"
            else
                stop_spinner
                log_file_only "Failed to create causa-gcp-credentials — check ${LOG_FILE}"
            fi
            ;;

        anthropic)
            if kubectl get secret causa-llm-secrets \
                    -n "$namespace" >>"${LOG_FILE}" 2>&1; then
                write_to_log_file "INFO" "causa-llm-secrets already exists in $namespace — skipping creation"
                return 0
            fi

            # Write key to a temp file so it never appears in ps output.
            local api_key_tmp
            api_key_tmp=$(mktemp /tmp/.llm_secret.XXXXXX)
            chmod 600 "$api_key_tmp"
            printf '%s' "${LLM_API_KEY:-}" > "$api_key_tmp"
            local secret_rc=0
            start_spinner "Creating causa-llm-secrets..."
            kubectl create secret generic causa-llm-secrets \
                    --from-file=LLM_API_KEY="$api_key_tmp" \
                    -n "$namespace" >>"${LOG_FILE}" 2>&1 || secret_rc=$?
            shred -u "$api_key_tmp" 2>/dev/null || rm -f "$api_key_tmp"
            if [[ $secret_rc -eq 0 ]]; then
                stop_spinner
                log_install_success "causa-llm-secrets created"
            else
                stop_spinner
                log_file_only "Failed to create causa-llm-secrets — check ${LOG_FILE}"
            fi
            ;;

        *)
            write_to_log_file "INFO" "create_llm_secrets: provider '${LLM_PROVIDER:-}' needs no K8s secret — skipping"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# configure_llm_runtime  LLM_ENV_FILE  NAMESPACE
#
# Phase 2 — POST non-sensitive config to the running causa-backend after the
# installer has deployed it.
#
# Only non-sensitive keys are sent here:
#   LLM_PROVIDER, LLM_MODEL_NAME, VERTEX_PROJECT_ID, VERTEX_LOCATION
#
# The GCP credential is NOT POSTed — it is already available to the backend
# via the K8s Secret volume mount created in Phase 1.
#
# Uses kubectl exec + curl (same as the installer pattern) so no external
# route is needed — works identically on Kind and OpenShift.
# ---------------------------------------------------------------------------
configure_llm_runtime() {
    local llm_env_file="$1"
    local namespace="$2"

    # Source with set -a so all vars are exported for child processes.
    set -a
    # shellcheck disable=SC1090
    source "$llm_env_file"
    set +a

    # Build the payload — only non-sensitive keys.
    local payload
    payload=$(python3 - << 'PYEOF'
import os, json

configs = {}

provider    = os.getenv("LLM_PROVIDER",    "").strip()
model       = os.getenv("LLM_MODEL_NAME",  "").strip()
temperature = os.getenv("LLM_TEMPERATURE", "").strip()
endpoint    = os.getenv("LLM_ENDPOINT",    "").strip()

if provider:    configs["LLM_PROVIDER"]    = provider
if model:       configs["LLM_MODEL_NAME"]  = model
if temperature: configs["LLM_TEMPERATURE"] = temperature
if endpoint:    configs["LLM_ENDPOINT"]    = endpoint

# Vertex AI — project and location are non-sensitive
vertex_proj = os.getenv("VERTEX_PROJECT_ID", "").strip()
vertex_loc  = os.getenv("VERTEX_LOCATION",   "").strip()
if vertex_proj: configs["VERTEX_PROJECT_ID"] = vertex_proj
if vertex_loc:  configs["VERTEX_LOCATION"]   = vertex_loc

# Anthropic direct — API key is sensitive but must go via the API (no volume mount)
api_key = os.getenv("LLM_API_KEY", "").strip()
if api_key: configs["LLM_API_KEY"] = api_key

# Bob provider
bob_path = os.getenv("BOB_SHELL_PATH", os.getenv("BOB_PATH", "")).strip()
if bob_path: configs["BOB_SHELL_PATH"] = bob_path

print(json.dumps({"configs": configs}))
PYEOF
)

    # Nothing to push
    local has_config
    has_config=$(python3 -c "
import json, sys
print('true' if json.loads(sys.argv[1]).get('configs') else 'false')
" "$payload")

    if [[ "$has_config" != "true" ]]; then
        write_to_log_file "INFO" "No LLM provider configured — Causa Backend will use heuristic RCA"
        log_validation_success "Causa Backend LLM config (skipped — no provider set in llm.env)"
        return 0
    fi

    write_to_log_file "INFO" "Pushing LLM config (provider: ${LLM_PROVIDER:-}, model: ${LLM_MODEL_NAME:-})"

    local causa_pod
    causa_pod=$(kubectl get pods \
        -l "app=causa-backend" \
        -n "$namespace" \
        --field-selector="status.phase=Running" \
        -o "jsonpath={.items[0].metadata.name}" \
        2>>"${LOG_FILE}" || true)

    if [[ -z "$causa_pod" ]]; then
        write_to_log_file "WARN" "Causa Backend pod not running — skipping config push (RCA will run without LLM)"
        return 0
    fi

    start_spinner "Pushing config to Causa Backend (up to 5 attempts)..."
    local cfg_rc=1 attempt
    for attempt in 1 2 3 4 5; do
        cfg_rc=0
        kubectl exec -n "$namespace" "$causa_pod" -- \
            curl -sf --max-time 10 \
            -X POST "http://localhost:8080/api/v1/configs" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            >>"${LOG_FILE}" 2>&1 || cfg_rc=$?
        [[ $cfg_rc -eq 0 ]] && break
        write_to_log_file "INFO" "Config push attempt ${attempt}/5 failed (rc=${cfg_rc}) — retrying in 10s..."
        [[ $attempt -lt 5 ]] && sleep 10
    done
    stop_spinner

    if [[ $cfg_rc -eq 0 ]]; then
        log_install_success "Causa Backend configured (LLM config pushed)"
    else
        log_file_only "Config push failed after 5 attempts (non-fatal — RCA will run without LLM)"
        log_validation_success "Causa config push (failed — check ${LOG_FILE})"
    fi
}

export -f validate_llm_config
export -f create_llm_secrets
export -f configure_llm_runtime
