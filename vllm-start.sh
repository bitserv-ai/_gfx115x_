#!/usr/bin/env bash
# Copyright 2026 Blackcat Informatics Inc. / 2026 bitserv-ai
# SPDX-License-Identifier: MIT
#
# vllm-start.sh - Start all vLLM inference instances as background processes
#
# Launches one vLLM process per role defined in VLLM_ROLES. Each role gets
# its own port, device, PID file, and log file. All instances are managed
# as a single logical server.
#
# Per-role configuration is read from .env using the convention:
#   VLLM_<ROLE>_MODEL              - HuggingFace model ID (required)
#   VLLM_<ROLE>_PORT               - Listen port (required)
#   VLLM_<ROLE>_DEVICE             - Device type: rocm, cpu (required)
#   VLLM_<ROLE>_GPU_MEMORY_MB      - GPU memory limit in MB (optional)
#   VLLM_<ROLE>_ATTENTION_BACKEND  - Override attention backend (optional)
#   VLLM_<ROLE>_RUNNER             - Engine runner: generate, pooling (optional)
#   VLLM_<ROLE>_CONVERT            - Model conversion: embed, rerank (optional)
#   VLLM_<ROLE>_TRUST_REMOTE_CODE  - Enable --trust-remote-code if set (optional)
#   VLLM_<ROLE>_HF_OVERRIDES       - HuggingFace config overrides as JSON string (optional)
#   VLLM_<ROLE>_KV_CACHE_DTYPE     - KV cache data type, e.g. fp8_e5m2 (optional)
#   VLLM_<ROLE>_CPU_OFFLOAD_GB     - CPU weight offload in GB via UVA (optional)
#   VLLM_<ROLE>_LIMIT_MM_PER_PROMPT - MM limits per prompt, e.g. '{"video":0,"image":1}' (optional)
#   VLLM_<ROLE>_SKIP_MM_PROFILING   - Skip multimodal encoder profiling (optional, NOT recommended for VL models)
#   VLLM_<ROLE>_EXTRA_ARGS         - Additional vLLM CLI args (optional)
#
# Prerequisites:
#   - .env in the repo root with VLLM_* configuration
#   - vLLM built and available in PATH (via vllm-env.sh)
#   - ROCm installed for GPU roles
#
# Usage:
#   scripts/vllm-start.sh

set -euo pipefail

# =============================================================================
# Setup
# =============================================================================

_SCRIPT_REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_REAL_PATH")" && pwd)"

# Source shared helpers (logging, section headers, prerequisite checks).
# shellcheck source=common.sh
source "${_SCRIPT_DIR}/common.sh"

# shellcheck source=vllm-env.sh disable=SC1091
source "${_SCRIPT_DIR}/vllm-env.sh"

# shellcheck source=vllm-runtime-helpers.sh
source "${_SCRIPT_DIR}/vllm-runtime-helpers.sh"

PLATFORM_DIR="${_SCRIPT_DIR}"
ENV_FILE="${_SCRIPT_DIR}/.env"

unset _SCRIPT_REAL_PATH _SCRIPT_DIR

# Load .env configuration.
vllm_load_env "${ENV_FILE}"

# Defaults for global settings.
VLLM_HOST="${VLLM_HOST:-0.0.0.0}"
VLLM_STARTUP_TIMEOUT="${VLLM_STARTUP_TIMEOUT:-180}"
VLLM_PREFIX_CACHING_HASH_ALGO="${VLLM_PREFIX_CACHING_HASH_ALGO:-xxhash}"

# Force vLLM V0 engine globally (V1 has issues with CPU offloading on ROCm/UMA)
# export VLLM_USE_V1=0
# export VLLM_V1=0

# =============================================================================
# Instance Management
# =============================================================================

start_instance() {
    local role="$1"

    # Read per-role configuration via helper.
    local model port device gpu_memory_mb attention_backend extra_args max_model_len quantization max_num_seqs enforce_eager runner convert trust_remote_code hf_overrides kv_cache_dtype cpu_offload_gb limit_mm_per_prompt skip_mm_profiling
    model="$(vllm_role_config "${role}" MODEL)"
    port="$(vllm_role_config "${role}" PORT)"
    device="$(vllm_role_config "${role}" DEVICE)"
    gpu_memory_mb="$(vllm_role_config "${role}" GPU_MEMORY_MB)"
    attention_backend="$(vllm_role_config "${role}" ATTENTION_BACKEND)"
    max_model_len="$(vllm_role_config "${role}" MAX_MODEL_LEN)"
    quantization="$(vllm_role_config "${role}" QUANTIZATION)"
    max_num_seqs="$(vllm_role_config "${role}" MAX_NUM_SEQS)"
    enforce_eager="$(vllm_role_config "${role}" ENFORCE_EAGER)"
    runner="$(vllm_role_config "${role}" RUNNER)"
    convert="$(vllm_role_config "${role}" CONVERT)"
    trust_remote_code="$(vllm_role_config "${role}" TRUST_REMOTE_CODE)"
    hf_overrides="$(vllm_role_config "${role}" HF_OVERRIDES)"
    kv_cache_dtype="$(vllm_role_config "${role}" KV_CACHE_DTYPE)"
    cpu_offload_gb="$(vllm_role_config "${role}" CPU_OFFLOAD_GB)"
    limit_mm_per_prompt="$(vllm_role_config "${role}" LIMIT_MM_PER_PROMPT)"
    skip_mm_profiling="$(vllm_role_config "${role}" SKIP_MM_PROFILING)"
    extra_args="$(vllm_role_config "${role}" EXTRA_ARGS)"

    local pid_file log_file
    pid_file="$(vllm_pid_file "${role}" "${PLATFORM_DIR}")"
    log_file="$(vllm_log_file "${role}" "${PLATFORM_DIR}")"

    # Validate required fields.
    local role_upper
    role_upper="$(vllm_role_upper "${role}")"
    if [[ -z "${model}" ]]; then
        die "Missing VLLM_${role_upper}_MODEL in .env"
    fi
    if [[ -z "${port}" ]]; then
        die "Missing VLLM_${role_upper}_PORT in .env"
    fi
    if [[ -z "${device}" ]]; then
        die "Missing VLLM_${role_upper}_DEVICE in .env"
    fi

    # Check if already running.
    if vllm_is_running "${role}" "${PLATFORM_DIR}"; then
        local pid
        pid="$(vllm_read_pid "${role}" "${PLATFORM_DIR}")"
        warn "vLLM ${role} already running (PID: ${pid}). Skipping."
        return 0
    fi

    # Clean up stale PID if present but process dead.
    local existing_pid
    existing_pid="$(vllm_read_pid "${role}" "${PLATFORM_DIR}")"
    if [[ -n "${existing_pid}" ]]; then
        vllm_cleanup_stale_pid "${role}" "${PLATFORM_DIR}"
    fi

    # Build command arguments.
    # vLLM has no --device CLI flag. Device selection is controlled via the
    # VLLM_TARGET_DEVICE environment variable (defaults to "cuda"). For
    # non-GPU roles (cpu), we set this per-process at launch time.
    local -a cmd_args=(
        vllm serve "${model}"
        --host "${VLLM_HOST}"
        --port "${port}"
        --enable-prefix-caching
        --prefix-caching-hash-algo "${VLLM_PREFIX_CACHING_HASH_ALGO}"
    )

    if [[ -n "${max_model_len}" ]]; then
        cmd_args+=(--max-model-len "${max_model_len}")
    fi

    if [[ -n "${quantization}" ]]; then
        cmd_args+=(--quantization "${quantization}")
    fi

    if [[ -n "${max_num_seqs}" ]]; then
        cmd_args+=(--max-num-seqs "${max_num_seqs}")
    fi

    # CRITICAL: Enable eager mode to allow CPU weight offloading in V1 engine.
    # This bypasses the AssertionError regarding input batch re-initialization.
    # We default it to true but allow per-role disabling (e.g. for FP8 models).
    if [[ "${enforce_eager:-true}" == "true" ]]; then
        cmd_args+=(--enforce-eager)
    fi

    # Attention backend override: allows per-role selection of attention backend.
    # When set, forces a specific backend instead of vLLM's auto-selection.
    # Valid values: ROCM_AITER_FA, ROCM_AITER_UNIFIED_ATTN, TRITON_ATTN, etc.
    if [[ -n "${attention_backend}" ]]; then
        cmd_args+=(--override-attention-backend "${attention_backend}")
        info "${role}: attention backend override: ${attention_backend}"
    fi

    if [[ -n "${runner}" ]]; then
        cmd_args+=(--runner "${runner}")
        info "${role}: runner: ${runner}"
    fi

    if [[ -n "${convert}" ]]; then
        cmd_args+=(--convert "${convert}")
        info "${role}: convert: ${convert}"
    fi

    if [[ -n "${trust_remote_code}" ]]; then
        cmd_args+=(--trust-remote-code)
    fi

    if [[ -n "${hf_overrides}" ]]; then
        cmd_args+=(--hf-overrides "${hf_overrides}")
        info "${role}: hf_overrides: ${hf_overrides}"
    fi

    if [[ -n "${kv_cache_dtype}" ]]; then
        cmd_args+=(--kv-cache-dtype "${kv_cache_dtype}")
        info "${role}: kv_cache_dtype: ${kv_cache_dtype}"
    fi

    if [[ -n "${cpu_offload_gb}" ]]; then
        cmd_args+=(--cpu-offload-gb "${cpu_offload_gb}")
        info "${role}: cpu_offload_gb: ${cpu_offload_gb}"
    fi

    if [[ -n "${limit_mm_per_prompt}" ]]; then
        cmd_args+=(--limit-mm-per-prompt "${limit_mm_per_prompt}")
        info "${role}: limit_mm_per_prompt: ${limit_mm_per_prompt}"
    fi

    if [[ "${skip_mm_profiling:-false}" == "true" ]]; then
        cmd_args+=(--skip-mm-profiling)
        info "${role}: skip_mm_profiling: true"
    fi

    # GPU memory: convert MB to utilization fraction.
    if [[ -n "${gpu_memory_mb}" ]]; then
        local total_mb utilization
        total_mb="$(vllm_gpu_total_mb)"
        utilization="$(vllm_mb_to_utilization "${gpu_memory_mb}" "${total_mb}")"
        cmd_args+=(--gpu-memory-utilization "${utilization}")
        info "${role}: GPU memory ${gpu_memory_mb}MB / ${total_mb}MB = ${utilization}"
    else
        cmd_args+=(--gpu-memory-utilization 0.98)
        info "${role}: GPU memory utilization capped at 0.98 (default)"
    fi

    # Append extra args (word-split intentionally).
    # shellcheck disable=SC2206
    cmd_args+=(${extra_args})

    info "Starting vLLM ${role}: ${model} on ${device}:${port}"
    info "Log file: ${log_file}"

    # Launch in background with per-process VLLM_TARGET_DEVICE.
    # Use setsid (not nohup) to create a new session/process group.
    # nohup breaks the V1 EngineCore multiprocessing fork on ROCm/gfx1151:
    # the EngineCore subprocess becomes a zombie (<defunct>) when the parent
    # is not a session leader. setsid fixes this by creating a new session.
    VLLM_TARGET_DEVICE="${device}" \
    setsid "${cmd_args[@]}" > "${log_file}" 2>&1 &

    local instance_pid=$!
    echo "${instance_pid}" > "${pid_file}"

    # Health check loop.
    info "Waiting for ${role} health check (timeout: ${VLLM_STARTUP_TIMEOUT}s)..."

    if vllm_poll_health "${VLLM_HOST}" "${port}" "${VLLM_STARTUP_TIMEOUT}" "${instance_pid}"; then
        success "vLLM ${role} ready (PID: ${instance_pid}, port: ${port})"

        # Log which attention backend was actually selected (parse vLLM log).
        local backend_line
        backend_line="$(grep -oP 'Using \K\S+ out of potential backends' "${log_file}" 2>/dev/null | head -1)"
        if [[ -n "${backend_line}" ]]; then
            info "${role}: ${backend_line}"
        fi
        return 0
    fi

    # Failed: check if process died or timed out.
    vllm_print_startup_failure_details "${log_file}" "${instance_pid}"
    rm -f "${pid_file}"
    return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
    section "vLLM Inference Server"

    require_commands vllm curl bc

    vllm_require_roles

    # Log optimization state for debugging.
    vllm_log_optimization_state

    local failed=0

    for role in ${VLLM_ROLES}; do
        if ! start_instance "${role}"; then
            error "Failed to start ${role}"
            failed=$((failed + 1))
        fi
    done

    if [[ "${failed}" -gt 0 ]]; then
        die "${failed} instance(s) failed to start."
    fi

    success "All vLLM instances running."
    info "Stop with: scripts/vllm-stop.sh"
}

main "$@"
