#!/bin/bash
################################################################################
# Uninstall / Cleanup — Quarkus RCA Demo
################################################################################

if [[ -n "${DEMO_UNINSTALL_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly DEMO_UNINSTALL_LIB_LOADED=1

# Require logging.sh to be sourced first — it provides log_error, log_file_only,
# start_spinner, stop_spinner, log_install_success, log_validation_success, etc.
if [[ -z "${DEMO_LOGGING_LIB_LOADED:-}" ]]; then
    echo "ERROR: uninstall.sh requires logging.sh to be sourced first" >&2
    return 1
fi

WORKLOAD_APP_NAME="${WORKLOAD_APP_NAME:-quarkus-perf}"

delete_manifest() {
    local manifest="$1"
    local ns="${2:-default}"
    [[ -z "$manifest" ]] && { log_error "delete_manifest requires a manifest file"; return 1; }
    if [[ ! -f "$manifest" ]]; then
        log_file_only "Manifest not found (skipping): $manifest"
        return 0
    fi
    log_file_only "Deleting resources from: $manifest (namespace: $ns)"
    kubectl delete -f "$manifest" -n "$ns" --ignore-not-found=true >>"$LOG_FILE" 2>&1
    local delete_rc=$?
    if [[ $delete_rc -eq 0 ]]; then
        log_install_success "${WORKLOAD_APP_NAME} workload deleted"
    else
        log_error "Failed to delete resources from: $manifest (namespace: $ns) — check $LOG_FILE"
    fi
    return $delete_rc
}

terminate_demo() {
    local namespace="$1"
    local demo_dir="$2"
    local skip_installer="${3:-false}"
    local delete_cluster="${4:-false}"
    local target="${5:-kind}"

    if [[ -z "$namespace" || -z "$demo_dir" ]]; then
        log_error "terminate_demo requires namespace and demo_dir"
        return 1
    fi

    log_file_only "TERMINATE MODE — namespace: $namespace"

    # ── Step 1: Delete quarkus-perf workload + load-gen ──────────────────────
    # Done FIRST, before the installer teardown, while the cluster is still
    # fully operational and the namespace is guaranteed to exist.
    log_section "Deleting quarkus-perf workload"

    if check_namespace "$namespace"; then
        # Delete load-gen job by name (Jobs are immutable).
        start_spinner "Deleting load-gen job..."
        kubectl delete job quarkus-perf-load-gen -n "$namespace" \
            --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
        stop_spinner
        log_install_success "load-gen job deleted"

        # Prefer the rendered manifest produced at install time; fall back to
        # a direct label-selector delete so cleanup works even when the
        # artifacts directory is missing (e.g. first -t run on a fresh clone).
        local workload_manifest="$demo_dir/quarkus-perf-deploy.rendered.yaml"
        start_spinner "Deleting quarkus-perf deployment..."
        if [[ -f "$workload_manifest" ]]; then
            log_file_only "Deleting quarkus-perf via manifest: $workload_manifest"
            kubectl delete -f "$workload_manifest" -n "$namespace" \
                --ignore-not-found=true >>"$LOG_FILE" 2>&1
            local _delete_rc=$?
        else
            log_file_only "Rendered manifest not found — deleting quarkus-perf by label selector"
            kubectl delete all -n "$namespace" \
                -l "app=${WORKLOAD_APP_NAME}" \
                --ignore-not-found=true >>"$LOG_FILE" 2>&1
            local _delete_rc=$?
        fi
        stop_spinner
        if [[ $_delete_rc -eq 0 ]]; then
            log_install_success "quarkus-perf workload deleted"
        else
            log_file_only "quarkus-perf deletion encountered issues (rc=$_delete_rc) — continuing cleanup"
        fi
    else
        log_file_only "Namespace $namespace not found — skipping workload deletion"
        log_validation_success "quarkus-perf cleanup (skipped — namespace not found)"
    fi

    # ── Step 2: Run installer teardown via install.sh --terminate ────────────
    # Runs AFTER the workload is deleted so the cluster is still up during
    # Step 1. install.sh --terminate removes the Causa stack components.
    # Pass --delete-cluster to also tear down the Kind cluster.
    if [[ "$skip_installer" == "false" ]]; then
        log_section "Running installer cleanup (install.sh --terminate)"
        local installer_script="$demo_dir/installer/install.sh"
        if [[ -f "$installer_script" ]]; then
            local _installer_log
            _installer_log="$(dirname "$installer_script")/install.log"

            local _terminate_args=(--terminate -n "$namespace" --target "$target")
            [[ "$delete_cluster" == "true" ]] && _terminate_args+=(--delete-cluster)

            log_file_only "Running: /usr/bin/env bash $installer_script ${_terminate_args[*]}"

            {
                echo ""
                echo -e "\033[0;36m\033[1mFull installer log: $_installer_log\033[0m"
                echo ""
            } >/dev/tty 2>/dev/null || true

            # Same fifo split as the install path: log gets everything unfiltered,
            # terminal sees only the clean lines (structured log lines stripped).
            local _t_fifo
            _t_fifo=$(mktemp -t demo_uninstall_fifo.XXXXXX)
            rm -f "$_t_fifo"
            mkfifo "$_t_fifo"
            grep -v -E '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T|^\[(INFO|SUCCESS|SECTION|WARN|ERROR|DEBUG)\]' \
                < "$_t_fifo" >/dev/tty 2>/dev/null &
            local _t_fifo_pid=$!

            /usr/bin/env bash "$installer_script" "${_terminate_args[@]}" \
                2>&1 | tee -a "$LOG_FILE" > "$_t_fifo"
            local rc=${PIPESTATUS[0]}

            wait "$_t_fifo_pid" 2>/dev/null || true
            rm -f "$_t_fifo"

            if [[ $rc -eq 0 ]]; then
                log_install_success "Installer cleanup"
            else
                log_file_only "Installer cleanup encountered issues (rc=$rc) — check log: $LOG_FILE"
                log_validation_success "Installer cleanup (check log for details)"
            fi
        else
            log_error "Installer script not found at: $installer_script"
            log_error "  Re-run without -t first to clone the installer, or run install.sh --terminate manually:"
            log_error "  bash artifacts/installer/install.sh --terminate -n $namespace"
            log_validation_success "Installer cleanup (skipped — script not found; see above)"
        fi
    else
        log_file_only "Installer cleanup skipped (--skip-installer)"
        log_validation_success "Installer cleanup (skipped — --skip-installer)"
    fi

    # ── Step 3: Stop port-forward tunnels ────────────────────────────────────
    local _pf_pid_file
    _pf_pid_file="$(dirname "$demo_dir")/.portforward.pids"
    # Also check inside the artifacts dir in case demo_dir IS the artifacts dir.
    local _pf_pid_file_alt="${demo_dir}/.portforward.pids"
    log_section "Stopping port-forward tunnels"
    if [[ -f "$_pf_pid_file" ]]; then
        stop_port_forwards "$_pf_pid_file"
    elif [[ -f "$_pf_pid_file_alt" ]]; then
        stop_port_forwards "$_pf_pid_file_alt"
    else
        log_file_only "No port-forward PID file found — tunnels may already be stopped"
        log_validation_success "Port-forward cleanup (skipped — PID file not found)"
    fi

    log_install_success "Cleanup completed"
    return 0
}

export -f delete_manifest
export -f terminate_demo
