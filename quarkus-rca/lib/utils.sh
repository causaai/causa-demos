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
    if ! kubectl cluster-info >>"$LOG_FILE" 2>&1; then
        log_error "Kubernetes API server is not reachable."
        log_error "Ensure your cluster is running and your kubeconfig is correct."
        log_error "  kind target: run 'kind create cluster' first, or check 'kubectl cluster-info'."
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

# tune_kind_node_sysctls
#
# Kind nodes share the host's sysctl namespace. inotify.max_user_instances
# defaults to 128 on most Linux distros; repeated jafra-agent crash-loop
# restarts exhaust it, causing EMFILE (OS error 24, "Too many open files").
#
# This function checks the current values and exits 1 with a clear remediation
# message if they are below the required minimums. The caller is responsible
# for acting on the non-zero exit.
tune_kind_node_sysctls() {
    local -A _required=(
        ["fs.inotify.max_user_instances"]=512
        ["fs.inotify.max_user_watches"]=1048576
    )

    local _needs_action=false
    for _key in "${!_required[@]}"; do
        local _want="${_required[$_key]}"
        local _cur
        _cur=$(cat "/proc/sys/${_key//.//}" 2>/dev/null || echo 0)
        if [[ "$_cur" -lt "$_want" ]]; then
            _needs_action=true
            log_file_only "sysctl $_key is $_cur (minimum required: $_want)"
        else
            log_file_only "sysctl $_key = $_cur (ok)"
        fi
    done

    if [[ "$_needs_action" == "true" ]]; then
        log_error "Host inotify limits are too low for the jafra-agent."
        log_error "The agent will crash with EMFILE (error 24: Too many open files)."
        log_error "Run the following on your host before starting the demo:"
        log_error "  sudo sysctl -w fs.inotify.max_user_instances=512"
        log_error "  sudo sysctl -w fs.inotify.max_user_watches=1048576"
        log_error "To persist across reboots, add to /etc/sysctl.d/99-kind.conf:"
        log_error "  fs.inotify.max_user_instances = 512"
        log_error "  fs.inotify.max_user_watches   = 1048576"
        return 1
    fi

    log_install_success "inotify sysctls OK (max_user_instances and max_user_watches meet minimums)"
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
export -f apply_manifest
export -f wait_for_deployment
export -f get_pod_status
export -f tune_kind_node_sysctls
