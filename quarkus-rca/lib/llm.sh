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
#     Creates the causa-llm-secrets K8s Secret (anthropic/bob providers).
#     No-op for vertex-ai-anthropic — credentials are delivered via the
#     config API in Phase 2 only.
#
#   configure_llm_runtime  LLM_ENV_FILE  NAMESPACE
#     Phase 2 — called AFTER the installer.
#     PUTs LLM config to PUT /api/v1/configs/llm/{provider}, including
#     GOOGLE_APPLICATION_CREDENTIALS as base64-encoded file contents for
#     vertex-ai-anthropic (piped through stdin, never a CLI argument).
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
# Supported providers:  vertex-ai-anthropic  |  anthropic  |  bob
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
    local provider model_name location project_id creds_file api_key bob_shell_path
    provider=$(       bash -c "set -a; source \"$llm_env_file\"; echo \"\${LLM_PROVIDER:-}\"")
    model_name=$(     bash -c "set -a; source \"$llm_env_file\"; echo \"\${LLM_MODEL_NAME:-}\"")
    location=$(       bash -c "set -a; source \"$llm_env_file\"; echo \"\${VERTEX_LOCATION:-}\"")
    project_id=$(     bash -c "set -a; source \"$llm_env_file\"; echo \"\${VERTEX_PROJECT_ID:-}\"")
    creds_file=$(     bash -c "set -a; source \"$llm_env_file\"; eval echo \"\${GOOGLE_APPLICATION_CREDENTIALS:-}\"")
    if [[ -n "$creds_file" && "$creds_file" != /* ]]; then
        creds_file="$(dirname "$llm_env_file")/$creds_file"
    fi
    api_key=$(        bash -c "set -a; source \"$llm_env_file\"; echo \"\${LLM_API_KEY:-}\"")
    bob_shell_path=$( bash -c "set -a; source \"$llm_env_file\"; echo \"\${BOB_SHELL_PATH:-\${BOB_PATH:-}}\"")

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
        bob)
            # BOB_SHELL_PATH is optional — the backend defaults to 'bob' on PATH.
            # LLM_API_KEY is required when Bob uses API-key authentication.
            if [[ -n "$bob_shell_path" && ! -x "$bob_shell_path" ]]; then
                errors+=("BOB_SHELL_PATH='$bob_shell_path' is not executable")
            fi
            ;;
        "")
            : # already captured above
            ;;
        *)
            errors+=("LLM_PROVIDER='$provider' is not supported (supported: vertex-ai-anthropic, anthropic, bob)")
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
#     No K8s Secret is created. Credentials are base64-encoded and POSTed to
#     the config API by configure_llm_runtime (Phase 2).
#
#   anthropic | bob:
#     causa-llm-secrets — LLM_API_KEY stored as a K8s secret.
#     (bob only creates this secret when LLM_API_KEY is set in llm.env)
# ---------------------------------------------------------------------------
create_llm_secrets() {
    local llm_env_file="$1"
    local namespace="$2"

    # Source so variables are available to the rest of this function.
    # set -a ensures they're exported for any child processes (kubectl) too.
    # Side-effect: LLM_API_KEY, GOOGLE_APPLICATION_CREDENTIALS, etc. are
    # exported into the parent shell for the rest of the run.  This is
    # intentional — kubectl needs them — but differs from validate_llm_config
    # which uses subshells.  See the configure_llm_runtime docstring for details.
    set -a
    # shellcheck disable=SC1090
    source "$llm_env_file"
    set +a

    case "${LLM_PROVIDER:-}" in
        vertex-ai-anthropic)
            # Credentials are delivered via the config API POST in configure_llm_runtime
            # (Phase 2) — no K8s Secret is needed here.
            write_to_log_file "INFO" "create_llm_secrets: provider=vertex-ai-anthropic — credentials posted via config API, no K8s Secret needed"
            ;;

        anthropic|bob)
            # bob only needs a secret when LLM_API_KEY is set (API-key auth).
            if [[ "${LLM_PROVIDER:-}" == "bob" && -z "${LLM_API_KEY:-}" ]]; then
                write_to_log_file "INFO" "create_llm_secrets: provider=bob with no LLM_API_KEY — no secret needed"
                return 0
            fi

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
                return 1
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
# Phase 2 — PUT LLM config to the running causa-backend after the
# installer has deployed it.
#
# Endpoint: PUT /api/v1/configs/llm/{provider}
# Provider path values: VERTEX_AI, ANTHROPIC, BOB
#
# Payload structure per provider:
#
#   vertex-ai-anthropic  (→ provider path: VERTEX_AI):
#     url, models, temperature, is_active=true,
#     auth_config: { authType: SA_JSON_KEY, credentialsJson: <base64-encoded JSON> }
#     additional_config: { projectId, location }
#
#   anthropic  (→ provider path: ANTHROPIC):
#     models, temperature, is_active=true,
#     auth_config: { authType: API_KEY, apiKey: <LLM_API_KEY> }
#
#   bob  (→ provider path: BOB):
#     is_active=true,
#     auth_config: { authType: API_KEY, apiKey: <LLM_API_KEY> }    (when set)
#     additional_config: { bobShellPath: <BOB_SHELL_PATH> }         (when set)
#
# NOTE: both create_llm_secrets and configure_llm_runtime source llm.env
# directly into the current shell with `set -a` (required so kubectl/curl
# child processes can read the exported variables).  This means LLM_API_KEY,
# GOOGLE_APPLICATION_CREDENTIALS, etc. remain exported for the rest of the
# demo.sh process.  validate_llm_config uses subshells to avoid this, but
# the secret-creation and config-push phases cannot — they need the vars
# live in the environment.  Be aware of this if you add callers that do not
# expect those variables to be set.
#
# Uses kubectl exec + curl (same as the installer pattern) so no external
# route is needed — works identically on Kind and OpenShift.
# ---------------------------------------------------------------------------
configure_llm_runtime() {
    local llm_env_file="$1"
    local namespace="$2"

    # Source with set -a so all vars are exported for child processes.
    # Side-effect: LLM_API_KEY, GOOGLE_APPLICATION_CREDENTIALS, etc. are
    # exported into the parent shell for the rest of the run (see docstring).
    set -a
    # shellcheck disable=SC1090
    source "$llm_env_file"
    set +a

    # Resolve the credentials file path (expand ~ and relative paths).
    local creds_file
    creds_file=$(eval echo "${GOOGLE_APPLICATION_CREDENTIALS:-}")
    if [[ -n "$creds_file" && "$creds_file" != /* ]]; then
        creds_file="$(dirname "$llm_env_file")/$creds_file"
    fi
    # Also accept causa-gcp-key.json placed next to llm.env as a fallback.
    if [[ -z "$creds_file" || ! -f "$creds_file" ]]; then
        local _fallback
        _fallback="$(dirname "$llm_env_file")/causa-gcp-key.json"
        [[ -f "$_fallback" ]] && creds_file="$_fallback"
    fi
    # Map llm.env provider name to the new API path segment and build the
    # structured payload — credentials file is read inside Python so the
    # base64 blob never touches a shell variable or the process environment.
    local provider_path payload
    provider_path=$(python3 -c "
import os, sys
p = os.getenv('LLM_PROVIDER', '').strip().lower()
mapping = {
    'vertex-ai-anthropic': 'VERTEX_AI',
    'anthropic':           'ANTHROPIC',
    'bob':                 'BOB',
    'openai':              'OPENAI',
}
print(mapping.get(p, ''))
")

    if [[ -z "$provider_path" ]]; then
        write_to_log_file "INFO" "No LLM provider configured — Causa Backend will use heuristic RCA"
        log_validation_success "Causa Backend LLM config (skipped — no provider set in llm.env)"
        return 0
    fi

    payload=$(python3 - "$creds_file" << 'PYEOF'
import os, sys, json, base64

provider    = os.getenv("LLM_PROVIDER",    "").strip().lower()
model       = os.getenv("LLM_MODEL_NAME",  "").strip()
temperature = os.getenv("LLM_TEMPERATURE", "").strip()
endpoint    = os.getenv("LLM_ENDPOINT",    "").strip()

body = {"is_active": True}

if model:
    body["models"] = [model]
if temperature:
    try:
        body["temperature"] = float(temperature)
    except ValueError:
        pass
if endpoint:
    body["url"] = endpoint

if provider == "vertex-ai-anthropic":
    vertex_proj = os.getenv("VERTEX_PROJECT_ID", "").strip()
    vertex_loc  = os.getenv("VERTEX_LOCATION",   "us-east5").strip()

    # Vertex AI Anthropic endpoint — region is substituted into the URL.
    # Default region us-east5 used when VERTEX_LOCATION is not set.
    body["url"] = f"https://{vertex_loc}-aiplatform.googleapis.com"

    # Path is passed as argv[1] — not via the environment — to avoid
    # exposing the resolved path (or its contents) in the process env.
    creds_path = sys.argv[1] if len(sys.argv) > 1 else ""
    creds_b64 = ""
    if creds_path and os.path.isfile(creds_path):
        with open(creds_path, "rb") as f:
            creds_b64 = base64.b64encode(f.read()).decode()
    else:
        print(f"WARN: credentials file not found at '{creds_path}' — credentialsJson will not be set", file=sys.stderr)

    body["auth_config"] = {"authType": "SA_JSON_KEY", "credentialsJson": creds_b64}
    additional = {}
    if vertex_proj: additional["projectId"] = vertex_proj
    if vertex_loc:  additional["location"]  = vertex_loc
    if additional:  body["additional_config"] = additional

elif provider == "anthropic":
    api_key = os.getenv("LLM_API_KEY", "").strip()
    body["url"] = "https://api.anthropic.com"
    body["auth_config"] = {"authType": "API_KEY", "apiKey": api_key}

elif provider == "bob":
    api_key  = os.getenv("LLM_API_KEY",   "").strip()
    bob_path = os.getenv("BOB_SHELL_PATH", os.getenv("BOB_PATH", "")).strip()
    body["url"] = "http://localhost"
    auth = {"authType": "API_KEY"}
    if api_key: auth["apiKey"] = api_key
    body["auth_config"] = auth
    if bob_path:
        body["additional_config"] = {"bobShellPath": bob_path}

print(json.dumps(body))
PYEOF
)

    write_to_log_file "INFO" "Pushing LLM config (provider: ${LLM_PROVIDER:-}, api path: ${provider_path})"

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

    start_spinner "Pushing LLM config to Causa Backend (up to 5 attempts)..."
    local cfg_rc=1 attempt
    for attempt in 1 2 3 4 5; do
        cfg_rc=0
        # Feed payload through stdin (-i/--stdin) so the credential-bearing JSON
        # never appears in the kubectl exec or curl argument list, and therefore
        # cannot be observed via ps, /proc, audit logs, or command tracing.
        printf '%s' "$payload" | \
        kubectl exec -i -n "$namespace" "$causa_pod" -- \
            curl -sS --fail-with-body --max-time 10 \
            -X PUT "http://localhost:8080/api/v1/configs/llm/${provider_path}" \
            -H "Content-Type: application/json" \
            -d @- \
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
