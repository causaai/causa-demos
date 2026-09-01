#!/bin/bash
################################################################################
# Common Utilities — Quarkus RCA Demo
# Kind cluster / kubectl (no oc dependency).
################################################################################

# Prevent multiple sourcing
if [[ -n "${DEMO_UTILS_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly DEMO_UTILS_LIB_LOADED=1

# Require logging.sh to be sourced first — it provides log_error, log_file_only,
# log_install_success, and the spinner functions used throughout this library.
if [[ -z "${DEMO_LOGGING_LIB_LOADED:-}" ]]; then
    echo "ERROR: utils.sh requires logging.sh to be sourced first" >&2
    return 1
fi

LOG_FILE="${LOG_FILE:-demo.log}"

start_timer()       { date +%s; }

get_elapsed_time() {
    local start="$1"
    local end; end=$(date +%s)
    local e=$(( end - start ))
    local h=$(( e / 3600 ))
    local m=$(( (e % 3600) / 60 ))
    local s=$(( e % 60 ))
    [[ $h -gt 0 ]] && echo "${h}h ${m}m ${s}s" && return
    [[ $m -gt 0 ]] && echo "${m}m ${s}s"        && return
    echo "${s}s"
}

command_exists()       { command -v "$1" >/dev/null 2>&1; }

check_required_commands() {
    local missing=()
    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_file_only "Please install the missing commands and try again."
        return 1
    fi
    log_file_only "All required commands are available"
    return 0
}

# check_prerequisites <target>
# Builds the required-command list for the given target, validates each command
# is present, and validates cluster reachability when target is "kind" or
# whenever the Kubernetes API must be reachable.
check_prerequisites() {
    local target="${1:-kind}"

    local _cmds=("git" "kubectl" "python3")
    if [[ "$target" == "kind" ]]; then
        _cmds+=("kind")
    fi

    if ! check_required_commands "${_cmds[@]}"; then
        log_error "Missing required commands. Please install them and try again."
        return 1
    fi
    return 0
}

# check_cluster_reachability
# Verifies the Kubernetes API server is reachable before deployment starts.
# Prints a clear error and returns non-zero when the cluster is not available.
check_cluster_reachability() {
    local _target="${1:-kind}"
    if ! kubectl cluster-info >>"$LOG_FILE" 2>&1; then
        log_error "Kubernetes API server is not reachable."
        log_error "Ensure your cluster is running and your kubeconfig is correct."
        if [[ "$_target" == "openshift" ]]; then
            log_error "  openshift target: run 'oc login <cluster-url>' first, or check 'kubectl cluster-info'."
        else
            log_error "  kind target: run 'kind create cluster' first, or check 'kubectl cluster-info'."
        fi
        return 1
    fi
    log_file_only "Kubernetes cluster is reachable"
    return 0
}

clone_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="${3:-}"
    if [[ -z "$repo_url" || -z "$target_dir" ]]; then
        log_error "clone_repo requires repo_url and target_dir"
        return 1
    fi
    if [[ -d "$target_dir" ]]; then
        # If the remote URL has changed, discard the stale clone and re-clone.
        local existing_remote
        existing_remote=$(git -C "$target_dir" remote get-url origin 2>/dev/null || true)
        if [[ "$existing_remote" != "$repo_url" ]]; then
            log_file_only "Remote mismatch (have: $existing_remote, want: $repo_url) — re-cloning"
            rm -rf "$target_dir"
        fi
    fi

    if [[ -d "$target_dir" ]]; then
        cd "$target_dir" || return 1
        local _update_ok=true
        if [[ -n "$branch" ]]; then
            git fetch origin >>"$LOG_FILE" 2>&1 || _update_ok=false
            if [[ "$_update_ok" == "true" ]]; then
                git checkout "$branch" >>"$LOG_FILE" 2>&1 || _update_ok=false
            fi
            if [[ "$_update_ok" == "true" ]]; then
                # PR refs (pr/N) and some SHA-pinned refs cannot be pulled;
                # a non-zero exit here is non-fatal — checkout already has the ref.
                git pull origin "$branch" >>"$LOG_FILE" 2>&1 || true
            fi
        else
            git pull >>"$LOG_FILE" 2>&1 || _update_ok=false
        fi
        cd - >/dev/null

        if [[ "$_update_ok" == "false" ]]; then
            # Update failed — discard stale clone and fall through to a fresh clone
            log_file_only "Update failed for $target_dir — re-cloning from $repo_url"
            rm -rf "$target_dir"
        fi
    fi

    if [[ ! -d "$target_dir" ]]; then
        if ! git clone "$repo_url" "$target_dir" >>"$LOG_FILE" 2>&1; then
            log_error "Failed to clone $(basename "$target_dir") from $repo_url"
            return 1
        fi
        if [[ -n "$branch" ]]; then
            git -C "$target_dir" checkout "$branch" >>"$LOG_FILE" 2>&1 || {
                log_error "Failed to checkout branch: $branch"
                return 1
            }
        fi
    fi
    log_file_only "Repository ready: $target_dir"
    return 0
}

ensure_directory() {
    local dir="$1"
    [[ -z "$dir" ]] && { log_error "ensure_directory requires a path"; return 1; }
    mkdir -p "$dir" || { log_error "Failed to create directory: $dir"; return 1; }
    return 0
}

check_namespace()  { kubectl get namespace "$1" &>/dev/null; }

ensure_namespace() {
    local ns="$1"
    [[ -z "$ns" ]] && { log_error "ensure_namespace requires a namespace"; return 1; }
    if check_namespace "$ns"; then
        log_file_only "Namespace already exists: $ns"
        return 0
    fi
    local out; out=$(kubectl create namespace "$ns" 2>&1)
    local rc=$?
    echo "$out" >>"$LOG_FILE"
    if [[ $rc -eq 0 ]] || echo "$out" | grep -q "AlreadyExists"; then
        log_file_only "Namespace ready: $ns"
        return 0
    fi
    log_error "Failed to create namespace: $ns"
    return 1
}

# patch_workload_manifest <input_file> <output_file> <namespace>
#
# Renders a workload manifest into <output_file> with three normalisation passes:
#   1. sed  — substitutes "namespace: chaos-test" → <namespace> and enables the
#             three chaos flags (IDLE_TIMEOUT, LARGE_RESPONSE, MEMORY_CACHE).
#   2. python3 (pyyaml) — for every Deployment document, surgically patches
#             spec.template.metadata to:
#               • remove pod-level securityContext from spec (not container-level)
#               • add labels:  jafra.io/enabled: "true"
#                              jafra.io/mode: "continuous"
#               • add annotation: jafra.io/containers: "quarkus-perf"
#             All transforms are idempotent.
#   3. Writes the result preserving YAML document separators (---).
#
# Uses pyyaml (stdlib-safe fallback: returns sed-only output if import fails).
patch_workload_manifest() {
    local _input="$1"
    local _output="$2"
    local _namespace="$3"

    [[ -z "$_input" || -z "$_output" || -z "$_namespace" ]] && {
        log_error "patch_workload_manifest requires input, output, and namespace arguments"
        return 1
    }
    [[ ! -f "$_input" ]] && {
        log_error "patch_workload_manifest: input file not found: $_input"
        return 1
    }

    # ── Pass 1: sed substitutions ──────────────────────────────────────────
    local _sed_out
    _sed_out="$(mktemp /tmp/manifest_sed_XXXXXX.yaml)"
    sed \
        -e "s/namespace: chaos-test/namespace: ${_namespace}/g" \
        -e 's/CHAOS_HTTP_IDLE_TIMEOUT_ENABLED: "false"/CHAOS_HTTP_IDLE_TIMEOUT_ENABLED: "true"/g' \
        -e 's/CHAOS_HTTP_LARGE_RESPONSE_ENABLED: "false"/CHAOS_HTTP_LARGE_RESPONSE_ENABLED: "true"/g' \
        -e 's/CHAOS_MEMORY_CACHE_ENABLED: "false"/CHAOS_MEMORY_CACHE_ENABLED: "true"/g' \
        "$_input" > "$_sed_out"

    # ── Pass 2: pyyaml structural patch ───────────────────────────────────
    python3 - "$_sed_out" "$_output" << 'PYEOF'
import shutil
import sys

input_path, output_path = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    shutil.copyfile(input_path, output_path)
    sys.exit(0)

JAFRA_LABELS = {
    "jafra.io/enabled": "true",
    "jafra.io/mode":    "continuous",
}
JAFRA_ANNOTATION = {"jafra.io/containers": "quarkus-perf"}

def patch_deployment(doc):
    """Patch a single Deployment document in-place."""
    spec = doc.get("spec")
    if not isinstance(spec, dict):
        return
    template = spec.get("template")
    if not isinstance(template, dict):
        return

    # Remove pod-level securityContext (NOT the container-level one).
    pod_spec = template.get("spec")
    if isinstance(pod_spec, dict) and "securityContext" in pod_spec:
        del pod_spec["securityContext"]

    # Ensure template.metadata exists.
    meta = template.get("metadata")
    if not isinstance(meta, dict):
        meta = {}
        template["metadata"] = meta

    # Inject jafra labels (idempotent).
    labels = meta.get("labels")
    if not isinstance(labels, dict):
        labels = {}
        meta["labels"] = labels
    for k, v in JAFRA_LABELS.items():
        labels[k] = v

    # Inject jafra annotation (idempotent).
    annotations = meta.get("annotations")
    if not isinstance(annotations, dict):
        annotations = {}
        meta["annotations"] = annotations
    for k, v in JAFRA_ANNOTATION.items():
        annotations[k] = v

with open(input_path) as f:
    raw = f.read()

# Parse all YAML documents (multi-doc manifest separated by ---)
docs = list(yaml.safe_load_all(raw))

patched = []
for doc in docs:
    if isinstance(doc, dict) and doc.get("kind") == "Deployment":
        patch_deployment(doc)
    patched.append(doc)

with open(output_path, "w") as f:
    yaml.dump_all(patched, f,
                  default_flow_style=False,
                  allow_unicode=True,
                  sort_keys=False)
PYEOF
    local _py_rc=$?
    rm -f "$_sed_out"

    if [[ $_py_rc -ne 0 ]]; then
        log_error "patch_workload_manifest: python3 patcher failed (exit $_py_rc)"
        return 1
    fi
    log_file_only "Workload manifest patched: $_input → $_output"
    return 0
}

apply_manifest() {
    local manifest="$1"
    local ns="${2:-default}"
    [[ -z "$manifest" ]] && { log_error "apply_manifest requires a manifest file"; return 1; }
    [[ ! -f "$manifest" ]] && { log_error "Manifest not found: $manifest"; return 1; }
    kubectl apply -f "$manifest" -n "$ns" >>"$LOG_FILE" 2>&1 || {
        log_error "Failed to apply manifest: $manifest"
        return 1
    }
    log_file_only "Manifest applied: $manifest"
    return 0
}

wait_for_deployment() {
    local name="$1"
    local ns="${2:-default}"
    local timeout="${3:-300}"
    log_file_only "Waiting for deployment $name in $ns (timeout: ${timeout}s)..."
    kubectl wait --for=condition=available --timeout="${timeout}s" \
        deployment/"$name" -n "$ns" >>"$LOG_FILE" 2>&1 || {
        log_error "Deployment $name failed to become ready"
        kubectl get pods -n "$ns" -l "app=$name" >>"$LOG_FILE" 2>&1 || true
        return 1
    }
    log_file_only "Deployment $name is ready"
    return 0
}

get_pod_status() {
    local ns="${1:-default}"
    local selector="${2:-}"
    if [[ -n "$selector" ]]; then
        kubectl get pods -n "$ns" -l "$selector"
    else
        kubectl get pods -n "$ns"
    fi
}

export -f start_timer
export -f get_elapsed_time
export -f command_exists
export -f check_required_commands
export -f check_prerequisites
export -f check_cluster_reachability
export -f clone_repo
export -f ensure_directory
export -f check_namespace
export -f ensure_namespace
export -f patch_workload_manifest
export -f apply_manifest
export -f wait_for_deployment
export -f get_pod_status
