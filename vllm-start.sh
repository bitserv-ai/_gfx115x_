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
#   VLLM_<ROLE>_ENFORCE_EAGER      - Disable CUDA graph capture (optional, default: true)
#   VLLM_<ROLE>_MAX_NUM_BATCHED_TOKENS - Max tokens per batch (optional, vLLM default: 8192)
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
VLLM_STARTUP_ERROR_TAIL_LINES="${VLLM_STARTUP_ERROR_TAIL_LINES:-120}"
VLLM_MAX_GPU_MEMORY_UTILIZATION="${VLLM_MAX_GPU_MEMORY_UTILIZATION:-0.98}"

# =============================================================================
# Startup Failure Diagnostics
# =============================================================================

# Print a startup failure summary from a vLLM log file.
#
# Searches for the first traceback and prints focused context around it,
# then prints the last N lines (configurable via VLLM_STARTUP_ERROR_TAIL_LINES).
# This helps locate the root cause quickly — vLLM often reports the true
# engine/core failure immediately before the traceback.
#
# Args:
#   log_file - Path to vLLM instance log file
vllm_print_startup_failure_details() {
    local log_file="$1"
    local traceback_context_lines="${VLLM_STARTUP_TRACEBACK_CONTEXT_LINES:-40}"

    if [[ ! -f "${log_file}" ]]; then
        error "No startup log found at ${log_file}"
        return
    fi

    local first_traceback_line
    first_traceback_line="$(grep -n -m1 "Traceback (most recent call last)" "${log_file}" \
        | cut -d: -f1 || true)"
    if [[ -n "${first_traceback_line}" ]]; then
        error "First traceback starts at line ${first_traceback_line} in ${log_file}"

        local context_start context_end
        context_start=$(( first_traceback_line - traceback_context_lines ))
        if [[ "${context_start}" -lt 1 ]]; then
            context_start=1
        fi
        context_end=$(( first_traceback_line + traceback_context_lines ))
        error "Context around first traceback (lines ${context_start}-${context_end}):"
        sed -n "${context_start},${context_end}p" "${log_file}" >&2
    fi

    error "Last ${VLLM_STARTUP_ERROR_TAIL_LINES} lines from ${log_file}:"
    tail -"${VLLM_STARTUP_ERROR_TAIL_LINES}" "${log_file}" >&2
}

# Detect known torch.compile duplicate-pattern crash in ROCm AITER RMSNorm fusion.
#
# Args:
#   log_file - Path to vLLM instance log file
# Returns:
#   0 if duplicate-pattern signature found, 1 otherwise
vllm_is_aiter_rmsnorm_duplicate_pattern_failure() {
    local log_file="$1"

    [[ -f "${log_file}" ]] || return 1

    # Primary signature: both rocm_aiter_fusion.py and check_and_add_duplicate_pattern
    # must appear in the log (file name + function name).
    if grep -q "rocm_aiter_fusion.py" "${log_file}" \
        && grep -q "check_and_add_duplicate_pattern" "${log_file}"; then
        return 0
    fi

    if grep -q "Duplicate pattern.*already been registered" "${log_file}" \
        && grep -q "rocm_aiter_fusion" "${log_file}"; then
        return 0
    fi
    return 1
}

# Print targeted diagnostics for the duplicate-pattern startup crash.
#
# Reports installed vLLM/torch/triton versions, the rocm_aiter_fusion.py
# path, and whether skip_duplicates=True is present on register_replacement
# calls — the typical root-cause indicator for this crash.
#
# Args:
#   role - Logical instance role for log prefixing
vllm_print_duplicate_pattern_diagnostics() {
    local role="$1"

    info "${role}: collecting duplicate-pattern diagnostics (versions + patch state)"
    python - <<'PY'
import importlib.util
import os
import re
import sys

def _safe_import(name):
    try:
        mod = __import__(name)
        return mod, None
    except Exception as exc:
        return None, exc

vllm, vllm_err = _safe_import("vllm")
torch, torch_err = _safe_import("torch")
triton, triton_err = _safe_import("triton")

print("  diag  Python executable:", sys.executable)
print("  diag  vLLM version:      ", getattr(vllm, "__version__", f"<import failed: {vllm_err}>"))
print("  diag  torch version:     ", getattr(torch, "__version__", f"<import failed: {torch_err}>"))
print("  diag  triton version:    ", getattr(triton, "__version__", f"<import failed: {triton_err}>"))

target = None
if vllm is not None:
    spec = importlib.util.find_spec("vllm.compilation.passes.fusion.rocm_aiter_fusion")
    if spec is not None:
        target = spec.origin

if not target or not os.path.isfile(target):
    print("  diag  rocm_aiter_fusion: <not found in active environment>")
    raise SystemExit(0)

print("  diag  rocm_aiter_fusion: ", target)
try:
    text = open(target, "r", encoding="utf-8").read()
except Exception as exc:
    print(f"  diag  patch check:       <failed to read file: {exc}>")
    raise SystemExit(0)

try:
    register_calls = len(re.findall(r"pm\.register_replacement\(", text))
    skip_dupe = len(
        re.findall(
            r"pm\.register_replacement\([^\n]*skip_duplicates\s*=\s*True",
            text,
        )
    )
except re.error as exc:
    print(f"  diag  regex check:       <failed: {exc}>")
    raise SystemExit(0)

print("  diag  register calls:    ", register_calls)
print("  diag  skip_duplicates=:  ", skip_dupe)

if register_calls and skip_dupe == 0:
    print("  diag  likely root cause: active wheel is missing the skip_duplicates patch")
    print("  diag  action: rebuild/reinstall vLLM so rocm_aiter_fusion.py includes skip_duplicates=True")
elif register_calls and skip_dupe < register_calls:
    print("  diag  likely root cause: partial patch application in rocm_aiter_fusion.py")
else:
    print("  diag  patch state:       skip_duplicates appears present")
PY
}

# =============================================================================
# Instance Management
# =============================================================================

start_instance() {
    local role="$1"

    # Read per-role configuration via helper.
    local model port device gpu_memory_mb attention_backend extra_args max_model_len quantization max_num_seqs max_num_batched_tokens enforce_eager runner convert trust_remote_code hf_overrides kv_cache_dtype cpu_offload_gb limit_mm_per_prompt skip_mm_profiling
    model="$(vllm_role_config "${role}" MODEL)"
    port="$(vllm_role_config "${role}" PORT)"
    device="$(vllm_role_config "${role}" DEVICE)"
    gpu_memory_mb="$(vllm_role_config "${role}" GPU_MEMORY_MB)"
    attention_backend="$(vllm_role_config "${role}" ATTENTION_BACKEND)"
    max_model_len="$(vllm_role_config "${role}" MAX_MODEL_LEN)"
    quantization="$(vllm_role_config "${role}" QUANTIZATION)"
    max_num_seqs="$(vllm_role_config "${role}" MAX_NUM_SEQS)"
    max_num_batched_tokens="$(vllm_role_config "${role}" MAX_NUM_BATCHED_TOKENS)"
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

    if [[ -n "${max_num_batched_tokens}" ]]; then
        cmd_args+=(--max-num-batched-tokens "${max_num_batched_tokens}")
    fi

    # CRITICAL: Enable eager mode to allow CPU weight offloading in V1 engine.
    # This bypasses the AssertionError regarding input batch re-initialization.
    # Default: true (safe). Set to false per-role via VLLM_<ROLE>_ENFORCE_EAGER=false
    # for LLM-only models to enable CUDA graph capture (15-30% decode throughput).
    # VL models and CPU-offload roles should keep true (OOM risk + offload incompat).
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

    if [[ "${trust_remote_code}" == "true" || "${trust_remote_code}" == "1" || "${trust_remote_code}" == "yes" ]]; then
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

    # GPU memory: convert MB to utilization fraction (GPU roles only).
    if [[ "${device}" != "cpu" ]]; then
        if [[ -n "${gpu_memory_mb}" ]]; then
            local total_mb utilization
            total_mb="$(vllm_gpu_total_mb)"
            utilization="$(vllm_mb_to_utilization "${gpu_memory_mb}" "${total_mb}")"
            if [[ "$(echo "${utilization} > ${VLLM_MAX_GPU_MEMORY_UTILIZATION}" | bc)" -eq 1 ]]; then
                warn "${role}: requested ${gpu_memory_mb}MB exceeds detected ${total_mb}MB; capping --gpu-memory-utilization to ${VLLM_MAX_GPU_MEMORY_UTILIZATION}"
                utilization="${VLLM_MAX_GPU_MEMORY_UTILIZATION}"
            fi
            cmd_args+=(--gpu-memory-utilization "${utilization}")
            info "${role}: GPU memory ${gpu_memory_mb}MB / ${total_mb}MB = ${utilization}"
        else
            cmd_args+=(--gpu-memory-utilization "${VLLM_MAX_GPU_MEMORY_UTILIZATION}")
            info "${role}: GPU memory utilization capped at ${VLLM_MAX_GPU_MEMORY_UTILIZATION} (default)"
        fi
    fi

    # Append extra args (word-split intentionally for space-separated CLI flags).
    # Validate via read -r -a to catch unbalanced quotes early.
    if [[ -n "${extra_args}" ]]; then
        local -a _extra_args_array=()
        read -r -a _extra_args_array <<< "${extra_args}"
        if [[ ${#_extra_args_array[@]} -gt 0 ]]; then
            cmd_args+=("${_extra_args_array[@]}")
        fi
    fi

    # AITER RMSNorm duplicate-pattern retry fallback.
    # Enabled via VLLM_ENABLE_AITER_RMSNORM_DUP_PATTERN_RETRY=1.
    # Legacy compat: VLLM_DISABLE_AITER_RMSNORM_ON_DUP_PATTERN=1 also enables.
    local enable_rmsnorm_retry="${VLLM_ENABLE_AITER_RMSNORM_DUP_PATTERN_RETRY:-0}"
    if [[ "${enable_rmsnorm_retry}" != "1" ]] \
        && [[ "${VLLM_DISABLE_AITER_RMSNORM_ON_DUP_PATTERN:-0}" == "1" ]]; then
        enable_rmsnorm_retry="1"
    fi
    local launch_with_rmsnorm_disabled=0
    local attempt

    for attempt in 1 2; do
        info "Starting vLLM ${role}: ${model} on ${device}:${port} (attempt ${attempt}/2)"
        info "Log file: ${log_file}"

        # Launch in background with per-process VLLM_TARGET_DEVICE.
        # Use setsid (not nohup) to create a new session/process group.
        # nohup breaks the V1 EngineCore multiprocessing fork on ROCm/gfx1151:
        # the EngineCore subprocess becomes a zombie (<defunct>) when the parent
        # is not a session leader. setsid fixes this by creating a new session.
        local -a launch_env=(
            VLLM_TARGET_DEVICE="${device}"
        )
        if [[ "${launch_with_rmsnorm_disabled}" -eq 1 ]]; then
            launch_env+=(VLLM_ROCM_USE_AITER_RMSNORM=0)
        fi

        env "${launch_env[@]}" \
        setsid "${cmd_args[@]}" > "${log_file}" 2>&1 &

        local instance_pid=$!
        echo "${instance_pid}" > "${pid_file}"

        # Health check loop.
        info "Waiting for ${role} health check (timeout: ${VLLM_STARTUP_TIMEOUT}s)..."

        if vllm_poll_health "127.0.0.1" "${port}" "${VLLM_STARTUP_TIMEOUT}" "${instance_pid}"; then
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
        if ! kill -0 "${instance_pid}" 2>/dev/null; then
            error "vLLM ${role} (PID ${instance_pid}) died during startup."
        else
            error "vLLM ${role} did not become healthy within ${VLLM_STARTUP_TIMEOUT}s."
        fi

        # Automatic one-time fallback for known duplicate pattern crash in
        # RocmAiterRMSNormQuantFusionPass.
        if [[ "${VLLM_ROCM_USE_AITER_RMSNORM:-0}" == "1" ]] \
            && vllm_is_aiter_rmsnorm_duplicate_pattern_failure "${log_file}"; then
            vllm_print_duplicate_pattern_diagnostics "${role}"

            if [[ "${enable_rmsnorm_retry}" == "1" ]] \
                && [[ "${launch_with_rmsnorm_disabled}" -eq 0 ]]; then
                launch_with_rmsnorm_disabled=1
                warn "${role}: detected AITER RMSNorm duplicate-pattern startup crash; retrying with VLLM_ROCM_USE_AITER_RMSNORM=0"
                if kill -0 "${instance_pid}" 2>/dev/null; then
                    kill -TERM "${instance_pid}" 2>/dev/null || true
                    sleep 2
                    kill -KILL "${instance_pid}" 2>/dev/null || true
                fi
                rm -f "${pid_file}"
                continue
            fi
            warn "${role}: detected AITER RMSNorm duplicate-pattern startup crash"
            warn "${role}: retry fallback is disabled (set VLLM_ENABLE_AITER_RMSNORM_DUP_PATTERN_RETRY=1 to enable one-time retry)"
        fi

        vllm_print_startup_failure_details "${log_file}"

        if kill -0 "${instance_pid}" 2>/dev/null; then
            warn "${role}: terminating leftover vLLM process (PID ${instance_pid})"
            kill -TERM "${instance_pid}" 2>/dev/null || true
            sleep 2
            kill -KILL "${instance_pid}" 2>/dev/null || true
        fi

        rm -f "${pid_file}"
        return 1
    done

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
