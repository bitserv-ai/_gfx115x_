#!/usr/bin/env bash
# Copyright 2026 Blackcat Informatics Inc.
# SPDX-License-Identifier: MIT
#
# vllm-status.sh - Check status of all vLLM inference instances
#
# Reports PID status, health endpoint, and loaded model for each role
# defined in VLLM_ROLES.
#
# Usage:
#   scripts/vllm-status.sh

set -euo pipefail

# =============================================================================
# Setup
# =============================================================================

_SCRIPT_REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_REAL_PATH")" && pwd)"

# Source shared helpers (logging, section headers, prerequisite checks).
# shellcheck source=common.sh
source "${_SCRIPT_DIR}/common.sh"

# shellcheck source=vllm-runtime-helpers.sh
source "${_SCRIPT_DIR}/vllm-runtime-helpers.sh"

PLATFORM_DIR="${_SCRIPT_DIR}"
ENV_FILE="${_SCRIPT_DIR}/.env"

unset _SCRIPT_REAL_PATH _SCRIPT_DIR

# Load .env for VLLM_ROLES and per-role config.
vllm_load_env "${ENV_FILE}"

VLLM_HOST="${VLLM_HOST:-0.0.0.0}"

# =============================================================================
# Instance Status
# =============================================================================

check_instance() {
    local role="$1"

    local model port device
    model="$(vllm_role_config "${role}" MODEL)"
    port="$(vllm_role_config "${role}" PORT)"
    device="$(vllm_role_config "${role}" DEVICE)"

    echo ""
    info "${role} (${model:-unknown} on ${device:-unknown}, port ${port:-?})"

    # 1. PID file check.
    local pid
    pid="$(vllm_read_pid "${role}" "${PLATFORM_DIR}")"

    if [[ -z "${pid}" ]]; then
        warn "  Process: NOT running (no PID file)"
        return 0
    fi

    if ! kill -0 "${pid}" 2>/dev/null; then
        warn "  Process: NOT running (stale PID: ${pid})"
        return 0
    fi

    info "  Process: running (PID: ${pid})"

    # 2. Health endpoint check.
    if [[ -z "${port}" ]]; then
        warn "  Health:  unknown (no port configured)"
        return 0
    fi

    local health_url="http://${VLLM_HOST}:${port}/health"
    if curl -sf "${health_url}" > /dev/null 2>&1; then
        success "  Health:  healthy"
    else
        error "  Health:  unhealthy (${health_url} not responding)"
        return 0
    fi

    # 3. Model info from /v1/models.
    local model_ids
    model_ids="$(vllm_query_models "${VLLM_HOST}" "${port}")"
    if [[ -n "${model_ids}" ]]; then
        info "  Models:  ${model_ids}"
    else
        info "  Models:  (none reported)"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    section "vLLM Server Status"

    vllm_require_roles

    for role in ${VLLM_ROLES}; do
        check_instance "${role}"
    done

    echo ""
}

main "$@"
