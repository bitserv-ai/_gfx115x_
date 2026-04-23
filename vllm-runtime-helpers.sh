#!/usr/bin/env bash
# Copyright 2026 Blackcat Informatics Inc. / 2026 bitserv-ai
# SPDX-License-Identifier: MIT
#
# vllm-runtime-helpers.sh - Runtime management helpers for vLLM instances
#
# Extracts shared patterns from vllm-start.sh, vllm-status.sh, and
# vllm-stop.sh into reusable functions:
#   - Role-based configuration reader (variable indirection)
#   - PID file management
#   - Health check polling
#   - GPU memory helpers
#
# Prerequisites:
#   - common.sh must be sourced first (provides info, success, warn, error, die)
#   - .env must be loaded (provides VLLM_ROLES and per-role config)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/vllm-runtime-helpers.sh"

# Guard: common.sh must be sourced first
if ! declare -f info &>/dev/null; then
    echo "ERROR: vllm-runtime-helpers.sh requires common.sh to be sourced first." >&2
    exit 1
fi

# =============================================================================
# Role Configuration
# =============================================================================

# Read a per-role configuration value via variable indirection.
#
# vLLM roles are configured in .env using the convention:
#   VLLM_<ROLE_UPPER>_<KEY> = value
#
# This function handles the uppercasing and indirection, replacing the
# duplicated pattern across vllm-start.sh, vllm-status.sh, and vllm-stop.sh.
#
# Args:
#   role - Role name (e.g., "director", "voice")
#   key  - Config key (e.g., "MODEL", "PORT", "DEVICE", "GPU_MEMORY_MB")
#
# Outputs:
#   The variable value, or empty string if not set
vllm_role_config() {
    local role="$1"
    local key="$2"
    local role_upper
    role_upper="$(echo "${role}" | tr '[:lower:]' '[:upper:]')"
    local var_name="VLLM_${role_upper}_${key}"
    echo "${!var_name:-}"
}

# Uppercase a role name.
#
# Args:
#   role - Role name (lowercase)
#
# Outputs:
#   Uppercased role name
vllm_role_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# =============================================================================
# PID File Management
# =============================================================================

# Get the PID file path for a role.
#
# PID files are stored in the platform directory as .vllm-<role>.pid.
#
# Args:
#   role         - Role name
#   platform_dir - Platform directory path
#
# Outputs:
#   Absolute path to the PID file
vllm_pid_file() {
    local role="$1"
    local platform_dir="$2"
    echo "${platform_dir}/.vllm-${role}.pid"
}

# Get the log file path for a role.
#
# Args:
#   role         - Role name
#   platform_dir - Platform directory path
#
# Outputs:
#   Absolute path to the log file
vllm_log_file() {
    local role="$1"
    local platform_dir="$2"
    echo "${platform_dir}/.vllm-${role}.log"
}

# Read the PID from a role's PID file.
#
# Args:
#   role         - Role name
#   platform_dir - Platform directory path
#
# Outputs:
#   The PID number, or empty string if no PID file exists
vllm_read_pid() {
    local role="$1"
    local platform_dir="$2"
    local pid_file
    pid_file="$(vllm_pid_file "${role}" "${platform_dir}")"

    if [[ -f "${pid_file}" ]]; then
        cat "${pid_file}"
    else
        echo ""
    fi
}

# Check if a role's vLLM process is currently running.
#
# Checks both PID file existence and whether the process is alive.
#
# Args:
#   role         - Role name
#   platform_dir - Platform directory path
#
# Returns:
#   0 if running, 1 if not running or stale
vllm_is_running() {
    local role="$1"
    local platform_dir="$2"
    local pid
    pid="$(vllm_read_pid "${role}" "${platform_dir}")"

    if [[ -z "${pid}" ]]; then
        return 1
    fi

    if kill -0 "${pid}" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Clean up a stale PID file for a role.
#
# Removes the PID file and warns about the stale state. Call this when
# vllm_read_pid returns a PID but kill -0 fails.
#
# Args:
#   role         - Role name
#   platform_dir - Platform directory path
vllm_cleanup_stale_pid() {
    local role="$1"
    local platform_dir="$2"
    local pid_file
    pid_file="$(vllm_pid_file "${role}" "${platform_dir}")"
    local pid
    pid="$(vllm_read_pid "${role}" "${platform_dir}")"

    if [[ -n "${pid}" ]]; then
        warn "Stale PID file for ${role} (PID ${pid} not running). Removing."
    fi
    rm -f "${pid_file}"
}

# =============================================================================
# Health Check
# =============================================================================

# Poll a vLLM instance's health endpoint until it responds or timeout.
#
# Used during startup to wait for the server to become ready. Checks
# both process liveness and HTTP health endpoint.
#
# Args:
#   host        - Hostname/IP to check
#   port        - Port number
#   timeout_sec - Maximum seconds to wait
#   pid         - Process ID to monitor (optional; if set, returns 1 if dies)
#
# Returns:
#   0 if healthy, 1 if timeout or process died
vllm_poll_health() {
    local host="$1"
    local port="$2"
    local timeout_sec="$3"
    local pid="${4:-}"
    local health_url="http://${host}:${port}/health"
    local waited=0

    while [[ "${waited}" -lt "${timeout_sec}" ]]; do
        # Check process liveness if PID provided
        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            return 1
        fi

        # Check health endpoint
        if curl -sf "${health_url}" > /dev/null 2>&1; then
            return 0
        fi

        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

# Query the loaded models from a vLLM instance.
#
# Args:
#   host - Hostname/IP
#   port - Port number
#
# Outputs:
#   Comma-separated list of model IDs, or empty string
vllm_query_models() {
    local host="$1"
    local port="$2"
    local models_url="http://${host}:${port}/v1/models"
    local response

    if response="$(curl -sf "${models_url}" 2>/dev/null)"; then
        echo "${response}" | grep -oP '"id"\s*:\s*"\K[^"]+' | paste -sd ', '
    else
        echo ""
    fi
}

# =============================================================================
# GPU Memory
# =============================================================================

# Get total allocatable GPU memory in megabytes from rocm-smi.
#
# Reports VRAM (BIOS carve-out) only. On UMA architectures (Strix Halo),
# hipMalloc can only allocate from the 48 GB VRAM carve-out — the GTT pool
# (~25 GB) is kernel-managed and not accessible via hipMalloc. Including GTT
# in the divisor would produce an artificially low utilization fraction,
# causing vLLM to under-allocate and run out of KV-cache memory.
#
# For llama.cpp Vulkan (RADV), which CAN use GTT, use the vanilla/llamacpp
# backend configuration with explicit GPU_MEMORY_MB targeting VRAM+GTT instead.
#
# Handles multi-GPU systems by summing VRAM across all devices.
#
# Outputs:
#   Total allocatable GPU memory (VRAM only) in MB
#
# Returns:
#   0 on success, dies if rocm-smi query fails
vllm_gpu_total_mb() {
    local vram_sum
    vram_sum="$(rocm-smi --showmeminfo vram 2>/dev/null | grep "VRAM Total Memory" | grep -oP '\d+$' | paste -sd+ | bc 2>/dev/null || echo 0)"

    if [[ "${vram_sum}" -eq 0 ]]; then
        die "Cannot query VRAM from rocm-smi. Is ROCm installed?"
    fi
    echo $(( vram_sum / 1048576 ))
}

# Convert megabytes to a gpu-memory-utilization fraction (0.0-1.0).
#
# Args:
#   requested_mb - Requested memory in MB
#   total_mb     - Total available memory in MB
#
# Outputs:
#   Floating-point fraction (e.g., "0.6250")
vllm_mb_to_utilization() {
    local requested_mb="$1"
    local total_mb="$2"
    echo "scale=4; ${requested_mb} / ${total_mb}" | bc
}

# =============================================================================
# Environment Loading
# =============================================================================

# Load .env file for vLLM configuration.
#
# Sources the .env file with set -a to export all variables. Dies if
# the file is not found.
#
# Args:
#   env_file - Path to .env file
vllm_load_env() {
    local env_file="$1"

    if [[ ! -f "${env_file}" ]]; then
        die "Environment file not found: ${env_file}"
    fi

    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a
}

# Validate that VLLM_ROLES is set and non-empty.
#
# Args:
#   (none - reads VLLM_ROLES from environment)
#
# Returns:
#   0 if set, dies if not
vllm_require_roles() {
    if [[ -z "${VLLM_ROLES:-}" ]]; then
        die "VLLM_ROLES not set in .env. Define roles to launch (e.g., \"director voice router\")."
    fi
}

# =============================================================================
# Optimization State Display
# =============================================================================

# Log the current optimization state for a vLLM launch.
#
# Prints which optimizations are active based on environment variables.
# Useful for debugging performance issues and verifying configuration.
vllm_log_optimization_state() {
    info "Optimization state:"
    info "  V1 multiprocessing:  ${VLLM_ENABLE_V1_MULTIPROCESSING:-1 (default)}"
    info "  AITER master:       ${VLLM_ROCM_USE_AITER:-disabled}"
    info "  AITER linear:       ${VLLM_ROCM_USE_AITER_LINEAR:-default}"
    info "  AITER MOE:          ${VLLM_ROCM_USE_AITER_MOE:-default}"
    info "  AITER RMSNorm:      ${VLLM_ROCM_USE_AITER_RMSNORM:-default}"
    info "  AITER MHA:          ${VLLM_ROCM_USE_AITER_MHA:-default}"
    info "  AITER Triton GEMM:  ${VLLM_ROCM_USE_AITER_TRITON_GEMM:-default}"
    info "  AITER Triton ROPE:  ${VLLM_ROCM_USE_AITER_TRITON_ROPE:-disabled}"
    info "  AITER unified attn: ${VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION:-disabled}"
    info "  AITER shared MoE:   ${VLLM_ROCM_USE_AITER_FUSION_SHARED_EXPERTS:-disabled}"
    info "  Shuffle KV cache:   ${VLLM_ROCM_SHUFFLE_KV_CACHE_LAYOUT:-disabled}"
    info "  Flash Attn Triton:  ${FLASH_ATTENTION_TRITON_AMD_ENABLE:-FALSE}"
    info "  hipBLASLt:          ${TORCH_BLAS_PREFER_HIPBLASLT:-disabled}"
    info "  TunableOp:          ${PYTORCH_TUNABLEOP_ENABLED:-disabled}"
    info "  Buffer ops:         ${AMDGCN_USE_BUFFER_OPS:-disabled}"
    info "  HSA GFX override:   ${HSA_OVERRIDE_GFX_VERSION:-not set}"
    info "  ROCm arch:          ${PYTORCH_ROCM_ARCH:-not set}"
}

# =============================================================================
# Startup Failure Diagnostics
# =============================================================================

# Print detailed diagnostics when a vLLM instance fails to start.
#
# Shows whether the process died or timed out, the last 50 lines of the
# log file, and attempts to diagnose common failure patterns (OOM, HIP
# errors, import errors, port conflicts).
#
# Args:
#   log_file     - Path to the vLLM instance log file
#   instance_pid - PID of the vLLM process
vllm_print_startup_failure_details() {
    local log_file="$1"
    local instance_pid="$2"

    if ! kill -0 "${instance_pid}" 2>/dev/null; then
        error "Process died during startup (PID ${instance_pid})"
    else
        error "Health check timed out — process alive but not responding"
    fi

    error "Log file: ${log_file}"
    error "--- Last 50 lines ---"
    tail -50 "${log_file}" >&2

    local log_tail
    log_tail="$(tail -200 "${log_file}" 2>/dev/null)" || true

    if echo "${log_tail}" | grep -qi "out of memory\|OOM\|CUDA out of memory\|Memory allocation failed"; then
        error "DIAGNOSIS: Out of memory. Reduce model size or gpu-memory-utilization."
    fi
    if echo "${log_tail}" | grep -qi "hipError\|ROCBLAS\|HSA error\|amdgpu"; then
        error "DIAGNOSIS: ROCm/HIP error. Check ROCm installation and HSA_OVERRIDE_GFX_VERSION."
    fi
    if echo "${log_tail}" | grep -qi "ModuleNotFoundError\|ImportError"; then
        error "DIAGNOSIS: Python import error. Check venv activation and dependencies."
    fi
    if echo "${log_tail}" | grep -qi "port.*already in use\|Address already in use"; then
        error "DIAGNOSIS: Port conflict. Another process is using this port."
    fi
    if echo "${log_tail}" | grep -qi "Permission denied\|permission denied"; then
        error "DIAGNOSIS: Permission denied. Check file ownership and directory permissions."
    fi
}
