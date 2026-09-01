#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'installer restore gate regression: FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    local source_file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ ("^" function_name "\\(\\) \\{") { copying=1 }
        copying {
            print
            line=$0
            opens=gsub(/\{/, "", line)
            line=$0
            closes=gsub(/\}/, "", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$source_file"
}

tree_digest() {
    local root="$1"
    (
        cd "$root"
        find -P . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
    ) | sha256sum | awk '{print $1}'
}

# Exercise the production gate itself while replacing only the operations that
# follow it.  This makes every call observable without downloading a release or
# writing under /usr/local.
# shellcheck disable=SC2294
eval "$(extract_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release_after_locks)"

CALL_LOG="$TEST_ROOT/calls"
rr_error() { :; }
rr_fetch_release() {
    printf '%s\n' fetch >> "$CALL_LOG"
}
rr_prepare_recovery_runtime() {
    printf '%s\n' prepare-runtime >> "$CALL_LOG"
}
rr_install_release() {
    printf '%s\n' install >> "$CALL_LOG"
    rr_prepare_recovery_runtime
}

stage="$TEST_ROOT/restore/transactions/tx"
mkdir -p "$stage/rollback/firewall"
printf '%s\n' recovery_failed > "$stage/phase"
printf '%s\n' firewall-snapshot-v1 > "$stage/rollback/firewall/complete"
RR_RESTORE_ACTIVE="$TEST_ROOT/restore/active"
printf '%s\n' "$stage" > "$RR_RESTORE_ACTIVE"

before_tree=$(tree_digest "$stage")
before_phase=$(sha256sum "$stage/phase" | awk '{print $1}')
before_active=$(sha256sum "$RR_RESTORE_ACTIVE" | awk '{print $1}')
: > "$CALL_LOG"
if rr_install_release_after_locks; then
    fail 'recovery_failed v1 restore marker was accepted'
fi
[ ! -s "$CALL_LOG" ] || \
    fail 'recovery_failed v1 marker reached fetch/install/prepare-runtime'
[ "$(tree_digest "$stage")" = "$before_tree" ] && \
    [ "$(sha256sum "$stage/phase" | awk '{print $1}')" = "$before_phase" ] && \
    [ "$(sha256sum "$RR_RESTORE_ACTIVE" | awk '{print $1}')" = "$before_active" ] || \
    fail 'recovery_failed v1 evidence changed while the installer rejected it'
[ "$(cat "$stage/phase")" = recovery_failed ] && \
    [ "$(cat "$stage/rollback/firewall/complete")" = firewall-snapshot-v1 ] || \
    fail 'recovery_failed v1 phase/snapshot evidence was not preserved'

rm -f -- "$RR_RESTORE_ACTIVE"
dangling_target="$TEST_ROOT/restore/missing-active-target"
ln -s "$dangling_target" "$RR_RESTORE_ACTIVE"
before_tree=$(tree_digest "$stage")
before_link=$(readlink -- "$RR_RESTORE_ACTIVE")
: > "$CALL_LOG"
if rr_install_release_after_locks; then
    fail 'dangling restore active marker was accepted'
fi
[ ! -s "$CALL_LOG" ] || \
    fail 'dangling restore marker reached fetch/install/prepare-runtime'
[ -L "$RR_RESTORE_ACTIVE" ] && \
    [ "$(readlink -- "$RR_RESTORE_ACTIVE")" = "$before_link" ] && \
    [ "$(tree_digest "$stage")" = "$before_tree" ] && \
    [ "$(cat "$stage/phase")" = recovery_failed ] || \
    fail 'dangling marker rejection modified restore evidence'

rm -f -- "$RR_RESTORE_ACTIVE"
: > "$CALL_LOG"
rr_install_release_after_locks || fail 'absent restore marker did not release the installer'
[ "$(cat "$CALL_LOG")" = $'fetch\ninstall\nprepare-runtime' ] || \
    fail 'absent marker did not reach fetch/install/prepare-runtime in order'
[ "$(tree_digest "$stage")" = "$before_tree" ] && \
    [ "$(cat "$stage/phase")" = recovery_failed ] || \
    fail 'allowed mock path unexpectedly changed the restore fixture'

printf '%s\n' 'installer restore gate regressions: PASS'
