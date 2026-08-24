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

cleanup_directory() {
    local dir="$1"
    [[ -z "$dir" ]] && { log_error "cleanup_directory requires a path"; return 1; }
    if [[ -d "$dir" ]]; then
        log_file_only "Removing directory: $dir"
        rm -rf "$dir"
        log_install_success "Directory removed: $(basename "$dir")"
    else
        log_file_only "Directory not found (already clean): $dir"
    fi
    return 0
}

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

    if [[ -z "$namespace" || -z "$demo_dir" ]]; then
        log_error "terminate_demo requires namespace and demo_dir"
        return 1
    fi

    log_file_only "TERMINATE MODE — namespace: $namespace"

    # ── Step 1: Run installer teardown via install.sh --terminate ────────────
    # The installer script is named install.sh on the quarkus-rca branch.
    if [[ "$skip_installer" == "false" ]]; then
        log_section "Running installer cleanup (install.sh --terminate)"
        local installer_script="$demo_dir/installer/install.sh"
        if [[ -f "$installer_script" ]]; then
            log_file_only "Running: bash $installer_script --terminate -n $namespace"
            start_spinner "Running install.sh --terminate..."
            bash "$installer_script" --terminate -n "$namespace" 2>&1 \
                | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"
            local rc=${PIPESTATUS[0]}
            stop_spinner
            if [[ $rc -eq 0 ]]; then
                log_install_success "Installer cleanup"
            else
                log_file_only "Installer cleanup encountered issues — check log: $LOG_FILE"
            fi
        else
            log_file_only "Installer script not found: $installer_script — skipping"
            log_validation_success "Installer cleanup (skipped — script not found)"
        fi
    else
        log_file_only "Installer cleanup skipped (--skip-installer)"
    fi

    # ── Step 2: Delete quarkus-perf workload + load-gen ──────────────────────
    log_section "Deleting quarkus-perf workload"

    # Use the rendered manifest written by demo.sh during install; the raw
    # chaos-lab clone is deleted in Step 3 and is not available here.
    if check_namespace "$namespace"; then
        # Delete load-gen job first (Jobs are immutable; delete by name)
        start_spinner "Deleting load-gen job..."
        kubectl delete job quarkus-perf-load-gen -n "$namespace" \
            --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
        stop_spinner
        log_install_success "load-gen job deleted"

        # Delete workload — spinner wraps the actual kubectl delete work
        local workload_manifest="$demo_dir/quarkus-perf-deploy.rendered.yaml"
        start_spinner "Deleting quarkus-perf deployment..."
        delete_manifest "$workload_manifest" "$namespace"
        local _delete_rc=$?
        stop_spinner
        # log_install_success / log_error already emitted by delete_manifest;
        # stop_spinner is unconditional so it always clears the terminal line.
        [[ $_delete_rc -ne 0 ]] && log_file_only "Workload deletion failed — continuing cleanup"
    else
        log_file_only "Namespace $namespace not found — skipping workload deletion"
        log_validation_success "quarkus-perf cleanup (skipped — namespace not found)"
    fi

    # ── Step 3: Remove cloned repos / artifacts ───────────────────────────────
    log_section "Removing cloned repositories"
    start_spinner "Removing artifacts..."
    cleanup_directory "$demo_dir"
    stop_spinner

    log_install_success "Cleanup completed"
    return 0
}

export -f cleanup_directory
export -f delete_manifest
export -f terminate_demo
