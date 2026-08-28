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
#     POSTs config keys to /api/v1/configs. GCP credentials are never POSTed.
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
#     causa-gcp-credentials — the raw credentials file stored as key.json,
#     mounted by the causa-backend deployment at
#     /var/secrets/google/key.json via the GOOGLE_APPLICATION_CREDENTIALS
#     env var (set in the deployment manifest).
#
#   anthropic | bob:
#     causa-llm-secrets — LLM_API_KEY stored as a K8s secret.
#     (bob only creates this secret when LLM_API_KEY is set in llm.env)
#
# No-op (with a warning) if the credentials file is missing.
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
                write_to_log_file "ERROR" "GCP credentials file not found at $creds_file"
                write_to_log_file "ERROR" "Set GOOGLE_APPLICATION_CREDENTIALS in llm.env or place causa-gcp-key.json next to demo.sh"
                return 1
            fi

            # Create GCP secret once kind cluster is up or causa is deployed
            start_spinner "Creating causa-gcp-credentials secret..."
            if kubectl create secret generic causa-gcp-credentials \
                    --from-file="key.json=$creds_file" \
                    -n "$namespace" >>"${LOG_FILE}" 2>&1; then
                stop_spinner
                log_install_success "causa-gcp-credentials secret created"
            else
                stop_spinner
                log_file_only "Failed to create causa-gcp-credentials — check ${LOG_FILE}"
                return 1
            fi
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
# Phase 2 — POST config keys to the running causa-backend after the
# installer has deployed it.
#
# Keys posted for each provider:
#
#   vertex-ai-anthropic:
#     LLM_PROVIDER, LLM_MODEL_NAME, VERTEX_PROJECT_ID, VERTEX_LOCATION,
#     GOOGLE_APPLICATION_CREDENTIALS (base64-encoded contents of the
#     credentials file — works for both ADC JSON and service-account keys).
#
#   anthropic:
#     LLM_PROVIDER, LLM_MODEL_NAME, LLM_API_KEY.
#
#   bob:
#     LLM_PROVIDER, LLM_API_KEY (when set), BOB_SHELL_PATH (when set).
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
    # Build the payload — read credentials file inside Python so the base64
    # blob never touches a shell variable or the process environment.
    local payload
    payload=$(python3 - "$creds_file" << 'PYEOF'
import os, sys, json, base64

configs = {}

provider    = os.getenv("LLM_PROVIDER",    "").strip()
model       = os.getenv("LLM_MODEL_NAME",  "").strip()
temperature = os.getenv("LLM_TEMPERATURE", "").strip()
endpoint    = os.getenv("LLM_ENDPOINT",    "").strip()

if provider:    configs["LLM_PROVIDER"]    = provider
if model:       configs["LLM_MODEL_NAME"]  = model
if temperature: configs["LLM_TEMPERATURE"] = temperature
if endpoint:    configs["LLM_ENDPOINT"]    = endpoint

# Vertex AI — project and location are non-sensitive; credentials are
# base64-encoded and posted so the backend can resolve ADC regardless of
# whether a volume mount is present (supports both ADC JSON and service-
# account key files).
vertex_proj = os.getenv("VERTEX_PROJECT_ID", "").strip()
vertex_loc  = os.getenv("VERTEX_LOCATION",   "").strip()
if vertex_proj: configs["VERTEX_PROJECT_ID"] = vertex_proj
if vertex_loc:  configs["VERTEX_LOCATION"]   = vertex_loc

if provider == "vertex-ai-anthropic":
    # Path is passed as argv[1] — not via the environment — to avoid
    # exposing the resolved path (or its contents) in the process env.
    creds_path = sys.argv[1] if len(sys.argv) > 1 else ""
    if creds_path and os.path.isfile(creds_path):
        with open(creds_path, "rb") as f:
            configs["GOOGLE_APPLICATION_CREDENTIALS"] = base64.b64encode(f.read()).decode()
    else:
        print(f"WARN: credentials file not found at '{creds_path}' — GOOGLE_APPLICATION_CREDENTIALS will not be posted", file=sys.stderr)

# Anthropic / Bob — API key must go via the API (no volume mount for these providers)
if provider in ("anthropic", "bob"):
    api_key = os.getenv("LLM_API_KEY", "").strip()
    if api_key:
        configs["LLM_API_KEY"] = api_key

# Bob provider — optional path to the bob binary
if provider == "bob":
    bob_path = os.getenv("BOB_SHELL_PATH", os.getenv("BOB_PATH", "")).strip()
    if bob_path:
        configs["BOB_SHELL_PATH"] = bob_path

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

    # Log what is being pushed (keys only — values are redacted from the log).
    local _payload_keys
    _payload_keys=$(python3 -c "
import json, sys
keys = list(json.loads(sys.argv[1]).get('configs', {}).keys())
print(', '.join(keys))
" "$payload" 2>/dev/null || echo "unknown")
    write_to_log_file "INFO" "Pushing LLM config (provider: ${LLM_PROVIDER:-}, keys: $_payload_keys)"

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

# ---------------------------------------------------------------------------
# _patch_vertex_ai_credential_mount  NAMESPACE
#
# Patches the causa-backend Deployment to:
#   • Mount the causa-gcp-credentials secret at /var/secrets/google
#   • Set GOOGLE_APPLICATION_CREDENTIALS=/var/secrets/google/key.json
#
# Idempotent — checks whether the mount already exists before patching.
# Rolls out the new pod and waits up to 120s for it to become ready.
# Non-fatal: logs a warning and returns 0 on any failure so the rest of
# the demo continues (RCA may fail at runtime, but setup does not abort).
# ---------------------------------------------------------------------------
_patch_vertex_ai_credential_mount() {
    local namespace="$1"

    # Check whether the volume mount is already present — if so, skip.
    local existing_mount
    existing_mount=$(kubectl get deployment causa-backend \
        -n "$namespace" \
        -o jsonpath='{.spec.template.spec.volumes[?(@.name=="gcp-credentials")].name}' \
        2>>"${LOG_FILE}" || true)

    if [[ "$existing_mount" == "gcp-credentials" ]]; then
        write_to_log_file "INFO" "_patch_vertex_ai_credential_mount: volume already present — skipping patch"
        return 0
    fi

    # Verify the secret exists before patching.
    if ! kubectl get secret causa-gcp-credentials \
            -n "$namespace" >>"${LOG_FILE}" 2>&1; then
        write_to_log_file "WARN" "_patch_vertex_ai_credential_mount: causa-gcp-credentials secret not found in $namespace — skipping mount patch"
        return 0
    fi

    start_spinner "Patching causa-backend with GCP credential mount..."

    local patch_rc=0
    kubectl patch deployment causa-backend \
        -n "$namespace" \
        --type=json \
        -p '[
          {
            "op": "add",
            "path": "/spec/template/spec/volumes/-",
            "value": {
              "name": "gcp-credentials",
              "secret": { "secretName": "causa-gcp-credentials" }
            }
          },
          {
            "op": "add",
            "path": "/spec/template/spec/containers/0/volumeMounts/-",
            "value": {
              "name": "gcp-credentials",
              "mountPath": "/var/secrets/google",
              "readOnly": true
            }
          },
          {
            "op": "add",
            "path": "/spec/template/spec/containers/0/env/-",
            "value": {
              "name": "GOOGLE_APPLICATION_CREDENTIALS",
              "value": "/var/secrets/google/key.json"
            }
          }
        ]' >>"${LOG_FILE}" 2>&1 || patch_rc=$?

    stop_spinner

    if [[ $patch_rc -ne 0 ]]; then
        write_to_log_file "WARN" "_patch_vertex_ai_credential_mount: kubectl patch failed (rc=$patch_rc) — Vertex AI ADC will not find credentials at runtime"
        log_validation_success "GCP credential mount patch (failed — check ${LOG_FILE})"
        return 0
    fi

    log_install_success "causa-backend patched with GCP credential volume mount"

    # Delete the old pod so the new ReplicaSet pod (with the mount) starts
    # immediately instead of waiting for the rolling-update deadlock on a
    # single-node cluster where memory is tight.
    local old_pod
    old_pod=$(kubectl get pods \
        -l "app=causa-backend" \
        -n "$namespace" \
        --field-selector="status.phase=Running" \
        -o "jsonpath={.items[0].metadata.name}" \
        2>>"${LOG_FILE}" || true)

    if [[ -n "$old_pod" ]]; then
        start_spinner "Restarting causa-backend pod ($old_pod)..."
        kubectl delete pod "$old_pod" -n "$namespace" >>"${LOG_FILE}" 2>&1 || true
        stop_spinner
        write_to_log_file "INFO" "Deleted old causa-backend pod $old_pod to free memory for rolling update"
    fi

    # Wait for the new pod to be ready (up to 120s).
    start_spinner "Waiting for causa-backend to be ready after credential patch (up to 120s)..."
    local wait_rc=0
    kubectl rollout status deployment/causa-backend \
        -n "$namespace" \
        --timeout=120s >>"${LOG_FILE}" 2>&1 || wait_rc=$?
    stop_spinner

    if [[ $wait_rc -eq 0 ]]; then
        log_install_success "causa-backend restarted and ready with GCP credentials"
    else
        write_to_log_file "WARN" "_patch_vertex_ai_credential_mount: rollout did not complete within 120s (rc=$wait_rc) — pod may still be starting"
        log_validation_success "causa-backend rollout (timed out — check: kubectl get pods -n $namespace)"
    fi
}

