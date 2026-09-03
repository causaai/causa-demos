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

# wait_for_rollout <name> <namespace> [timeout]
#
# Blocks until the deployment's CURRENT rollout is fully complete — all old
# ReplicaSet pods terminated and the new pod Ready.  Unlike
# `kubectl wait --for=condition=available` (which can return mid-rollout while
# the outgoing pod is still "available"), this does not return until the roll
# has settled.  Callers use this before `kubectl port-forward` so the tunnel
# attaches to the FINAL pod instead of one about to be deleted — otherwise the
# tunnel dies with "lost connection to pod" as soon as the old pod is removed.
wait_for_rollout() {
    local name="$1"
    local ns="${2:-default}"
    local timeout="${3:-300}"
    log_file_only "Waiting for rollout of $name in $ns to complete (timeout: ${timeout}s)..."
    if ! kubectl rollout status deployment/"$name" -n "$ns" \
            --timeout="${timeout}s" >>"$LOG_FILE" 2>&1; then
        log_error "Rollout of $name did not complete within ${timeout}s"
        kubectl get pods -n "$ns" -l "app=$name" >>"$LOG_FILE" 2>&1 || true
        return 1
    fi
    log_file_only "Rollout of $name complete"
    return 0
}

# ===========================================================================
# Port-forward tunnels (kind target)
# ===========================================================================
# On kind the Causa Backend and MCP services are ClusterIP services (the
# installer no longer publishes their NodePorts to the host), so they are
# reached from the host exclusively via `kubectl port-forward`.  The tunnels
# must OUTLIVE this script so the IDE / RCA session can keep hitting
# http://localhost:<port> after demo.sh exits, so each tunnel is started with
# `nohup ... &` + `disown` — it ignores the terminal hang-up and keeps its own
# PID (nohup execs kubectl in place).
#
# Cleanup happens at the start of the next run (start_port_forwards calls
# stop_port_forwards first) and on `-t` (terminate) — never on normal exit.
#
# There is deliberately NO self-healing restart loop: on a local kind cluster
# the tunnel is stable for the length of a demo, and such a loop is what
# previously spawned runaway orphaned "port-forward restarting" processes.
# Killing the single kubectl process is therefore always sufficient.
# ---------------------------------------------------------------------------

# stop_port_forwards <pid_file> [<local_port> ...]
#
# Kills the tunnels recorded in <pid_file>, then (as a fallback for runs whose
# pid file was lost) any kubectl port-forward still bound to the given local
# ports, and removes the pid file.  Safe to call when nothing is running.
stop_port_forwards() {
    local _pid_file="$1"; shift
    local _ports=("$@")
    local _pid _lport

    if [[ -n "$_pid_file" && -f "$_pid_file" ]]; then
        while IFS= read -r _pid; do
            [[ -z "$_pid" ]] && continue
            if kill "$_pid" 2>/dev/null; then
                write_to_log_file "INFO" "stop_port_forwards: killed tunnel PID $_pid"
            fi
        done < "$_pid_file"
        rm -f "$_pid_file"
    fi

    # Fallback (only reached when the pid file was lost): kill orphaned demo
    # tunnels by matching our own launch form, `kubectl port-forward svc/causa-*
    # <local_port>:`.  The `svc/causa-` prefix scopes the match to THIS demo's
    # services so we never kill an unrelated `kubectl port-forward` a developer
    # happens to be running on the same local port from another terminal.  No
    # wrapper loop means killing kubectl directly is enough — it cannot respawn.
    for _lport in "${_ports[@]}"; do
        [[ -z "$_lport" ]] && continue
        pkill -f "kubectl port-forward svc/causa-[a-z]* ${_lport}:" 2>/dev/null || true
    done
}

# _pf_start_one <svc> <local_port> <svc_port> <namespace> <pid_file> <label>
#
# Starts one detached tunnel, records its PID, and verifies it survived the
# first two seconds.  Returns 1 if the tunnel exited immediately.
_pf_start_one() {
    local _svc="$1" _lport="$2" _svc_port="$3" _ns="$4" _pid_file="$5" _label="$6"
    nohup kubectl port-forward "svc/${_svc}" "${_lport}:${_svc_port}" -n "$_ns" \
        >>"$LOG_FILE" 2>&1 &
    local _pid=$!
    # Detach the job so the shell never signals it on exit.  Use the no-argument
    # form (disowns the most-recent background job) — bash 3.2 on macOS does not
    # accept a raw PID here, only bash >= 4.0 does.  nohup already shields the
    # process from SIGHUP, so this is belt-and-suspenders.
    disown 2>/dev/null || true
    echo "$_pid" >> "$_pid_file"

    sleep 2
    if ! kill -0 "$_pid" 2>/dev/null; then
        log_error "port-forward for ${_label} exited immediately (svc/${_svc} ${_lport}:${_svc_port}) — check $LOG_FILE"
        return 1
    fi
    write_to_log_file "INFO" "port-forward ${_label}: svc/${_svc} ${_lport}:${_svc_port} PID=${_pid}"
    log_install_success "${_label} forwarded → http://localhost:${_lport} (PID ${_pid})"
    return 0
}

# _pf_wait_reachable <local_port> <label> [timeout_secs]
#
# Polls the Quarkus health endpoint through the tunnel until it answers or the
# timeout elapses.  A live kubectl PID is NOT proof the tunnel works: kubectl
# port-forward binds the local socket and keeps running even when the stream to
# the pod fails, so this exercises the tunnel end to end.  Both causa-backend
# and causa-mcp are Quarkus apps exposing /q/health.
_pf_wait_reachable() {
    local _lport="$1" _label="$2" _timeout="${3:-60}"
    local _deadline=$(( $(date +%s) + _timeout ))
    while [[ $(date +%s) -lt $_deadline ]]; do
        if curl -sf --max-time 3 "http://localhost:${_lport}/q/health" \
                >>"$LOG_FILE" 2>&1; then
            log_install_success "${_label} reachable on localhost:${_lport}"
            return 0
        fi
        sleep 3
    done
    log_error "${_label} did not become reachable on localhost:${_lport} within ${_timeout}s"
    return 1
}

# start_port_forwards <namespace> <pid_file> <backend_local_port> <mcp_local_port>
#
# Clears any stale tunnels, then starts detached port-forwards for the Causa
# Backend and MCP services.  Service names/ports are discovered from the
# cluster with conventional fallbacks.  Returns 0 once the backend tunnel is
# reachable on localhost, 1 on any failure.
start_port_forwards() {
    local _ns="$1" _pid_file="$2" _backend_port="$3" _mcp_port="$4"

    if [[ -z "$_ns" || -z "$_pid_file" || -z "$_backend_port" || -z "$_mcp_port" ]]; then
        log_error "start_port_forwards requires namespace, pid_file, backend_port, mcp_port"
        return 1
    fi
    if [[ "$_backend_port" == "$_mcp_port" ]]; then
        log_error "start_port_forwards: backend_port and mcp_port must differ (both ${_backend_port})"
        return 1
    fi

    # Clear tunnels from a previous run before rebinding the ports.
    stop_port_forwards "$_pid_file" "$_backend_port" "$_mcp_port"
    mkdir -p "$(dirname "$_pid_file")"
    : > "$_pid_file"

    # ── Discover services (fall back to conventional names/ports) ────────────
    local _backend_svc _backend_svc_port _mcp_svc _mcp_svc_port
    _backend_svc=$(kubectl get svc -n "$_ns" -l "app=causa-backend" \
        -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true)
    [[ -z "$_backend_svc" ]] && _backend_svc="causa-backend"
    _backend_svc_port=$(kubectl get svc "$_backend_svc" -n "$_ns" \
        -o jsonpath='{.spec.ports[0].port}' 2>>"$LOG_FILE" || true)
    [[ -z "$_backend_svc_port" ]] && _backend_svc_port="8080"

    _mcp_svc=$(kubectl get svc -n "$_ns" -l "app=causa-mcp" \
        -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true)
    [[ -z "$_mcp_svc" ]] && _mcp_svc="causa-mcp"
    _mcp_svc_port=$(kubectl get svc "$_mcp_svc" -n "$_ns" \
        -o jsonpath='{.spec.ports[0].port}' 2>>"$LOG_FILE" || true)
    [[ -z "$_mcp_svc_port" ]] && _mcp_svc_port="8081"

    # ── Start both tunnels ───────────────────────────────────────────────────
    if ! _pf_start_one "$_backend_svc" "$_backend_port" "$_backend_svc_port" \
            "$_ns" "$_pid_file" "causa-backend"; then
        stop_port_forwards "$_pid_file" "$_backend_port" "$_mcp_port"
        return 1
    fi
    if ! _pf_start_one "$_mcp_svc" "$_mcp_port" "$_mcp_svc_port" \
            "$_ns" "$_pid_file" "causa-mcp"; then
        stop_port_forwards "$_pid_file" "$_backend_port" "$_mcp_port"
        return 1
    fi

    # ── Verify BOTH tunnels are usable end to end ────────────────────────────
    # Probe each service's Quarkus health endpoint so callers never race the
    # tunnels coming up, and so a tunnel whose kubectl process is alive but whose
    # pod stream is failing is treated as a failure rather than a success.
    if ! _pf_wait_reachable "$_backend_port" "causa-backend" 60; then
        stop_port_forwards "$_pid_file" "$_backend_port" "$_mcp_port"
        return 1
    fi
    if ! _pf_wait_reachable "$_mcp_port" "causa-mcp" 60; then
        stop_port_forwards "$_pid_file" "$_backend_port" "$_mcp_port"
        return 1
    fi
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
export -f wait_for_rollout
export -f get_pod_status
export -f stop_port_forwards
export -f _pf_start_one
export -f _pf_wait_reachable
export -f start_port_forwards
