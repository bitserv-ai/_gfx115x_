#!/usr/bin/env bash
# Copyright 2026 Blackcat Informatics Inc.
# SPDX-License-Identifier: MIT
#
# common.sh - Shared shell helpers for strix-halo scripts
#
# Provides logging, section headers, and prerequisite checking functions
# used by build-vllm.sh, vllm-start.sh, vllm-stop.sh, and vllm-status.sh.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Guard against double-sourcing.  The "|| true" handles the case where this
# file is executed directly rather than sourced (return exits non-zero outside
# a function/source context).
if declare -f info &>/dev/null; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

info()    { printf '  \033[1;34minfo\033[0m  %s\n' "$*"; }
success() { printf '  \033[1;32m  ok\033[0m  %s\n' "$*"; }
warn()    { printf '  \033[1;33mwarn\033[0m  %s\n' "$*" >&2; }
error()   { printf '  \033[1;31m err\033[0m  %s\n' "$*" >&2; }
die()     { error "$@"; exit 1; }

# -----------------------------------------------------------------------------
# Section headers
# -----------------------------------------------------------------------------

# Print a prominent section header to visually separate build/run phases.
#
# Args:
#   $* - Section title text
section() { printf '\n  \033[1;35m━━ %s\033[0m\n\n' "$*"; }

# -----------------------------------------------------------------------------
# Prerequisite checking
# -----------------------------------------------------------------------------

# Verify that all listed commands are available in PATH.
# Dies immediately on the first missing command with an actionable message.
#
# Args:
#   $@ - Command names to check (e.g., clang cmake ninja uv)
require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 \
            || die "Required command not found: ${cmd}"
    done
}
