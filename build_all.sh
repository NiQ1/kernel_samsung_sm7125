#!/usr/bin/env bash
#
# build_all.sh - Build the UN1CA sm7125 kernel with KernelSU-Next and the
# security fixes.
#
# Run it from the top of the kernel tree:
#
#     ./build_all.sh                                   # asks what to build
#     ./build_all.sh --device both --ramdisk download  # no questions
#
# Runs, in order:
#   1. apply_ksu.sh
#   2. apply_security_fixes.sh
#   3. build_kernel.sh
# On exit, whether the build worked or not, it reverts what steps 1 and 2
# applied. Anything that was already applied before is left as it was.
#
# Options:
#   --ksu-ref <ref>   Passed on to apply_ksu.sh
#   -h, --help        Show this help
# Every other option goes to build_kernel.sh (see ./build_kernel.sh --help).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY_KSU="$SCRIPT_DIR/apply_ksu.sh"
APPLY_FIXES="$SCRIPT_DIR/apply_security_fixes.sh"
BUILD_KERNEL="$SCRIPT_DIR/build_kernel.sh"

TO_REVERT=()            # apply scripts whose changes this run owns

die() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    sed -n '3,/^set -euo pipefail$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

cleanup() {
    local status=$? i
    set +e
    for ((i = ${#TO_REVERT[@]} - 1; i >= 0; i--)); do
        if ! "${TO_REVERT[i]}" --revert; then
            echo "WARNING: $(basename "${TO_REVERT[i]}") --revert failed; the tree is still patched" >&2
            [ "$status" -ne 0 ] || status=1
        fi
    done
    exit "$status"
}

# Run <apply script> [args...], and revert it on exit unless it was already
# fully applied.
apply_step() {
    local script="$1"
    if "$script" --status >/dev/null 2>&1; then
        echo "$(basename "$script"): already applied before this run; it stays applied"
    else
        TO_REVERT+=("$script")
    fi
    "$@"
}

ksu_args=()
build_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ksu-ref)
            [ $# -ge 2 ] || die "$1 needs a value"
            ksu_args+=("$1" "$2")
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) build_args+=("$1") ;;
    esac
    shift
done

for script in "$APPLY_KSU" "$APPLY_FIXES" "$BUILD_KERNEL"; do
    [ -x "$script" ] || die "$script not found; keep the scripts together in one directory"
done

trap cleanup EXIT
trap 'exit 130' INT TERM

apply_step "$APPLY_KSU" "${ksu_args[@]}"
apply_step "$APPLY_FIXES"
"$BUILD_KERNEL" "${build_args[@]}"
