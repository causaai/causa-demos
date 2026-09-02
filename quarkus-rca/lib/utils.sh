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
#               • add causa label: causa.ai/monitoring: "true"
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

CAUSA_LABELS = {"causa.ai/monitoring": "true"}

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

    # Inject causa labels (idempotent).
    for k, v in CAUSA_LABELS.items():
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

# start_port_forwards <namespace> <backend_local_port> <mcp_local_port> <pid_file>
#
# Starts background kubectl port-forward tunnels for causa-backend and
# causa-mcp-server/causa-mcp-svc.  Service names and target ports are
# discovered from the cluster; conventional names are used as fallbacks.
# Any stale tunnels from a previous run (tracked by <pid_file> or already
# occupying the local ports) are killed first.
# PIDs are appended to <pid_file> so stop_port_forwards can clean them up.
# Returns 0 when both tunnels are started, 1 if either kubectl call fails.
start_port_forwards() {
    local _ns="$1"
    local _backend_port="$2"
    local _mcp_port="$3"
    local _pid_file="$4"

    if [[ -z "$_ns" || -z "$_backend_port" || -z "$_mcp_port" || -z "$_pid_file" ]]; then
        log_error "start_port_forwards requires namespace, backend_port, mcp_port, pid_file"
        return 1
    fi

    if [[ "$_backend_port" == "$_mcp_port" ]]; then
        log_error "start_port_forwards: backend_port and mcp_port must be different (both set to ${_backend_port})"
        return 1
    fi

    # ── Kill stale PIDs from a previous run ──────────────────────────────────
    if [[ -f "$_pid_file" ]]; then
        while IFS= read -r _old_pid; do
            [[ -z "$_old_pid" ]] && continue
            # Only kill the PID if it still belongs to a kubectl process.
            # ps -p ... -o comm= returns the command name without signalling the
            # process, so a reused PID that now belongs to something else is left
            # alone rather than being terminated by mistake.
            _old_comm=$(ps -p "$_old_pid" -o comm= 2>/dev/null || true)
            if [[ "$_old_comm" == "kubectl" ]]; then
                kill "$_old_pid" 2>/dev/null || true
                write_to_log_file "INFO" "start_port_forwards: killed stale kubectl port-forward PID $_old_pid"
            elif [[ -n "$_old_comm" ]]; then
                write_to_log_file "WARN" "start_port_forwards: skipped PID $_old_pid — belongs to '$_old_comm', not kubectl (PID reuse suspected)"
            fi
        done < "$_pid_file"
        rm -f "$_pid_file"
        write_to_log_file "INFO" "start_port_forwards: finished stale PID cleanup from $_pid_file"
    fi

    # ── Kill any other process already holding the local ports ───────────────
    # Only terminate processes that are confirmed kubectl port-forwards; for
    # anything else, surface an error so the user can free the port manually
    # rather than silently killing an unrelated local service.
    for _lport in "$_backend_port" "$_mcp_port"; do
        _holders=$(lsof -ti "tcp:${_lport}" 2>/dev/null || true)
        if [[ -n "$_holders" ]]; then
            for _holder_pid in $_holders; do
                _holder_comm=$(ps -p "$_holder_pid" -o comm= 2>/dev/null || true)
                if [[ "$_holder_comm" == "kubectl" ]]; then
                    kill "$_holder_pid" 2>/dev/null || true
                    write_to_log_file "INFO" "start_port_forwards: killed stale kubectl port-forward (PID ${_holder_pid}) on port ${_lport}"
                else
                    log_error "start_port_forwards: port ${_lport} is already in use by '${_holder_comm}' (PID ${_holder_pid}) — free the port and retry"
                    return 1
                fi
            done
        fi
    done

    mkdir -p "$(dirname "$_pid_file")"

    # ── Discover causa-backend service ───────────────────────────────────────
    local _backend_svc _backend_svc_port
    _backend_svc=$(kubectl get svc -n "$_ns" \
        -l "app=causa-backend" \
        -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true)
    [[ -z "$_backend_svc" ]] && _backend_svc="causa-backend"

    _backend_svc_port=$(kubectl get svc "$_backend_svc" -n "$_ns" \
        -o jsonpath='{.spec.ports[0].port}' 2>>"$LOG_FILE" || true)
    [[ -z "$_backend_svc_port" ]] && _backend_svc_port="8080"

    # ── Discover causa-mcp service ───────────────────────────────────────────
    local _mcp_svc _mcp_svc_port
    _mcp_svc=$(kubectl get svc -n "$_ns" \
        -l "app=causa-mcp" \
        -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true)
    if [[ -z "$_mcp_svc" ]]; then
        _mcp_svc=$(kubectl get svc -n "$_ns" \
            -l "app=causa-mcp-server" \
            -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true)
    fi
    [[ -z "$_mcp_svc" ]] && _mcp_svc="causa-mcp-svc"

    _mcp_svc_port=$(kubectl get svc "$_mcp_svc" -n "$_ns" \
        -o jsonpath='{.spec.ports[0].port}' 2>>"$LOG_FILE" || true)
    [[ -z "$_mcp_svc_port" ]] && _mcp_svc_port="8080"

    # Helper: kill both tunnels and remove the pid file, used on failure paths.
    _cleanup_tunnels() {
        local _b_pid="$1" _m_pid="$2"
        kill "$_b_pid" 2>/dev/null || true
        kill "$_m_pid" 2>/dev/null || true
        rm -f "$_pid_file"
    }

    # ── Self-healing tunnel wrapper ───────────────────────────────────────────
    # Runs kubectl port-forward in a tight loop so the tunnel is automatically
    # restarted if it exits due to a pod restart, API connection loss, etc.
    # The wrapper exits cleanly on SIGTERM (sent by stop_port_forwards /
    # _cleanup_tunnels).  A 2-second back-off between restarts avoids a
    # busy-loop when the service is permanently unavailable.
    _run_tunnel() {
        local _svc="$1" _local_port="$2" _svc_port="$3" _namespace="$4"
        local _attempt=0
        trap 'exit 0' TERM INT
        while true; do
            _attempt=$(( _attempt + 1 ))
            if [[ $_attempt -gt 1 ]]; then
                echo "$(date '+%Y-%m-%dT%H:%M:%S') [INFO] port-forward svc/${_svc} restarting (attempt ${_attempt})" >> "$LOG_FILE"
                sleep 2
            fi
            kubectl port-forward \
                "svc/${_svc}" \
                "${_local_port}:${_svc_port}" \
                -n "$_namespace" \
                >>"$LOG_FILE" 2>&1 || true
        done
    }

    # ── Start causa-backend tunnel ────────────────────────────────────────────
    start_spinner "Starting port-forward: causa-backend → localhost:${_backend_port}..."
    _run_tunnel "$_backend_svc" "$_backend_port" "$_backend_svc_port" "$_ns" &
    local _pf_backend_pid=$!
    # Record PID immediately so the EXIT trap can clean it up even if an
    # interrupt arrives during the startup delay below.
    echo "$_pf_backend_pid" >> "$_pid_file"
    stop_spinner

    # Give the wrapper ~2 s to fail fast on the first attempt (service not
    # found, port conflict, etc.).  If the wrapper itself has already exited
    # the underlying service is permanently unavailable.
    sleep 2
    if ! kill -0 "$_pf_backend_pid" 2>/dev/null; then
        log_error "port-forward for causa-backend exited immediately (svc/${_backend_svc} ${_backend_port}:${_backend_svc_port}) — check $LOG_FILE"
        _cleanup_tunnels "$_pf_backend_pid" "$_pf_backend_pid"
        return 1
    fi
    write_to_log_file "INFO" "port-forward causa-backend: svc/${_backend_svc} ${_backend_port}:${_backend_svc_port} PID=${_pf_backend_pid}"
    log_install_success "causa-backend forwarded → http://localhost:${_backend_port} (PID ${_pf_backend_pid})"

    # ── Start causa-mcp tunnel ────────────────────────────────────────────────
    start_spinner "Starting port-forward: causa-mcp → localhost:${_mcp_port}..."
    _run_tunnel "$_mcp_svc" "$_mcp_port" "$_mcp_svc_port" "$_ns" &
    local _pf_mcp_pid=$!
    # Record PID immediately for the same reason as the backend above.
    echo "$_pf_mcp_pid" >> "$_pid_file"
    stop_spinner

    # Same liveness check for the MCP tunnel wrapper.
    sleep 2
    if ! kill -0 "$_pf_mcp_pid" 2>/dev/null; then
        log_error "port-forward for causa-mcp exited immediately (svc/${_mcp_svc} ${_mcp_port}:${_mcp_svc_port}) — check $LOG_FILE"
        _cleanup_tunnels "$_pf_backend_pid" "$_pf_mcp_pid"
        return 1
    fi
    write_to_log_file "INFO" "port-forward causa-mcp: svc/${_mcp_svc} ${_mcp_port}:${_mcp_svc_port} PID=${_pf_mcp_pid}"
    log_install_success "causa-mcp forwarded → http://localhost:${_mcp_port} (PID ${_pf_mcp_pid})"

    # ── Wait for the backend tunnel to be reachable ───────────────────────────
    # kubectl port-forward needs a moment to bind the port and connect to the
    # pod.  Poll /q/health (Quarkus SmallRye Health) until it returns HTTP 200
    # or 60 s elapses, so callers never race the tunnel.
    # NOTE: /api/v1/healthz does not exist on this backend — use /q/health.
    local _deadline=$(( $(date +%s) + 60 ))
    start_spinner "Waiting for causa-backend to be reachable on localhost:${_backend_port} (up to 60s)..."
    local _health_rc=1
    while [[ $(date +%s) -lt $_deadline ]]; do
        # Abort the poll early if the tunnel process has already died.
        if ! kill -0 "$_pf_backend_pid" 2>/dev/null; then
            write_to_log_file "WARN" "causa-backend port-forward process (PID ${_pf_backend_pid}) died during health poll"
            break
        fi
        if curl -sf --max-time 3 \
                "http://localhost:${_backend_port}/q/health" \
                >>"$LOG_FILE" 2>&1; then
            _health_rc=0
            break
        fi
        sleep 3
    done
    stop_spinner
    if [[ $_health_rc -eq 0 ]]; then
        log_install_success "causa-backend is reachable on localhost:${_backend_port}"
    else
        log_error "causa-backend did not become reachable within 60s — cleaning up tunnels"
        _cleanup_tunnels "$_pf_backend_pid" "$_pf_mcp_pid"
        return 1
    fi
    return 0
}

# stop_port_forwards <pid_file>
#
# Kills all background port-forward processes whose PIDs are recorded in
# <pid_file>, then removes the file.  Silently ignores already-dead PIDs.
stop_port_forwards() {
    local _pid_file="$1"
    if [[ -z "$_pid_file" ]]; then
        log_error "stop_port_forwards requires a pid_file argument"
        return 1
    fi
    if [[ ! -f "$_pid_file" ]]; then
        log_file_only "stop_port_forwards: no PID file found at $_pid_file — nothing to stop"
        return 0
    fi
    local _stopped=0
    while IFS= read -r _pid; do
        [[ -z "$_pid" ]] && continue
        # Guard against PID reuse: only kill the process if it is still kubectl.
        _comm=$(ps -p "$_pid" -o comm= 2>/dev/null || true)
        if [[ "$_comm" == "kubectl" ]]; then
            if kill "$_pid" 2>/dev/null; then
                write_to_log_file "INFO" "stop_port_forwards: killed port-forward PID $_pid"
                _stopped=$(( _stopped + 1 ))
            else
                write_to_log_file "INFO" "stop_port_forwards: PID $_pid already gone"
            fi
        elif [[ -z "$_comm" ]]; then
            write_to_log_file "INFO" "stop_port_forwards: PID $_pid already gone"
        else
            write_to_log_file "WARN" "stop_port_forwards: skipped PID $_pid — belongs to '$_comm', not kubectl (PID reuse suspected)"
        fi
    done < "$_pid_file"
    rm -f "$_pid_file"
    log_install_success "Port-forward tunnels stopped (${_stopped} process(es))"
    return 0
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
export -f start_port_forwards
export -f stop_port_forwards
