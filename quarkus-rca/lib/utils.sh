#!/bin/bash
################################################################################
# Common Utilities — Quarkus RCA Demo
#
# Adapted from the runtimes-intelligence-demo utilities for a Kind cluster
# with kubectl (no oc dependency).
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

clone_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="${3:-}"
    if [[ -z "$repo_url" || -z "$target_dir" ]]; then
        log_error "clone_repo requires repo_url and target_dir"
        return 1
    fi
    if [[ -d "$target_dir" ]]; then
        cd "$target_dir" || return 1
        if [[ -n "$branch" ]]; then
            git fetch origin >>"$LOG_FILE" 2>&1 || {
                log_error "Failed to fetch from origin in $target_dir"
                cd - >/dev/null; return 1
            }
            git checkout "$branch" >>"$LOG_FILE" 2>&1 || {
                log_error "Failed to checkout branch $branch in $target_dir"
                cd - >/dev/null; return 1
            }
            git pull origin "$branch" >>"$LOG_FILE" 2>&1 || {
                log_error "Failed to pull $branch from origin in $target_dir"
                cd - >/dev/null; return 1
            }
        else
            git pull >>"$LOG_FILE" 2>&1 || {
                log_error "Failed to pull latest changes in $target_dir"
                cd - >/dev/null; return 1
            }
        fi
        cd - >/dev/null
    else
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

export -f start_timer
export -f get_elapsed_time
export -f command_exists
export -f check_required_commands
export -f clone_repo
export -f ensure_directory
export -f check_namespace
export -f ensure_namespace
export -f apply_manifest
export -f wait_for_deployment
export -f get_pod_status
