#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rr-install-recovery-runtime.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'install recovery runtime regression: FAIL: %s\n' "$*" >&2
    exit 1
}

expect_rejected() {
    local description="$1"
    shift
    if "$@"; then
        fail "$description was accepted"
    fi
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

[ "${EUID:-$(id -u)}" -eq 0 ] || fail 'this test requires root ownership'

# Load the production trust gates without executing the installer entry point.
# shellcheck disable=SC1090
source <(awk '/^rr_prepare_recovery_runtime\(\)/ { exit } { print }' \
    "$REPO_ROOT/scripts/install-core.sh")

printf '%s\n' '[1/7] umask-077 archive extraction keeps both helper sources trusted'
archive_source="$TEST_ROOT/archive-source"
archive_extract="$TEST_ROOT/archive-extract"
mkdir -p "$archive_source/scripts" "$archive_extract"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$archive_source/scripts/update-recover.sh"
printf '%s\n' '#!/usr/bin/env python3' 'raise SystemExit(0)' > \
    "$archive_source/scripts/update-external-state.py"
chown 0:0 "$archive_source/scripts/update-recover.sh" \
    "$archive_source/scripts/update-external-state.py"
chmod 0755 "$archive_source/scripts/update-recover.sh"
chmod 0644 "$archive_source/scripts/update-external-state.py"
tar --format=ustar -cf "$TEST_ROOT/helpers.tar" -C "$archive_source" scripts
(
    umask 077
    tar --no-same-owner --no-same-permissions -xf "$TEST_ROOT/helpers.tar" \
        -C "$archive_extract"
)
[ "$(stat -c %a -- "$archive_extract/scripts/update-recover.sh")" = 700 ] || \
    fail 'executable helper did not reproduce mode 0700 under umask 077'
[ "$(stat -c %a -- "$archive_extract/scripts/update-external-state.py")" = 600 ] || \
    fail 'regular helper did not reproduce mode 0600 under umask 077'
rr_recovery_helper_source_is_safe \
    "$archive_extract/scripts/update-recover.sh" || fail 'mode-0700 source was rejected'
rr_recovery_helper_source_is_safe \
    "$archive_extract/scripts/update-external-state.py" || \
    fail 'mode-0600 source was rejected'
chmod 0755 "$archive_extract/scripts/update-recover.sh"
rr_recovery_helper_source_is_safe \
    "$archive_extract/scripts/update-recover.sh" || fail 'mode-0755 source was rejected'
chmod 0644 "$archive_extract/scripts/update-external-state.py"
rr_recovery_helper_source_is_safe \
    "$archive_extract/scripts/update-external-state.py" || \
    fail 'mode-0644 source was rejected'

printf '%s\n' '[2/7] expanded source modes retain the regular-file/link-count boundary'
chmod 0640 "$archive_extract/scripts/update-recover.sh"
expect_rejected 'mode-0640 helper source' rr_recovery_helper_source_is_safe \
    "$archive_extract/scripts/update-recover.sh"
chmod 0700 "$archive_extract/scripts/update-recover.sh"
ln "$archive_extract/scripts/update-recover.sh" "$TEST_ROOT/helper-hardlink"
expect_rejected 'multiply-linked helper source' rr_recovery_helper_source_is_safe \
    "$archive_extract/scripts/update-recover.sh"
rm -f -- "$TEST_ROOT/helper-hardlink"
ln -s "$archive_extract/scripts/update-recover.sh" "$TEST_ROOT/helper-symlink"
expect_rejected 'symlink helper source' rr_recovery_helper_source_is_safe \
    "$TEST_ROOT/helper-symlink"

systemd_dir="$TEST_ROOT/systemd"
install -d -o 0 -g 0 -m 0755 "$systemd_dir"
RR_UPDATE_RECOVERY_UNIT_FILE="$systemd_dir/rr-update-recovery.service"
MOCK_LOAD_STATE=loaded
MOCK_FRAGMENT="$RR_UPDATE_RECOVERY_UNIT_FILE"
MOCK_DROPINS=""
MOCK_EXEC_START='{ path=/usr/local/sbin/rr-update-recover ; argv[]=/usr/local/sbin/rr-update-recover recover ; ignore_errors=no ; }'
MOCK_EXEC_START_PRE=""
MOCK_EXEC_START_POST=""
MOCK_EXEC_STOP=""
MOCK_EXEC_STOP_POST=""
MOCK_EXEC_RELOAD=""
MOCK_EXEC_CONDITION=""
MOCK_ENVIRONMENT=""
MOCK_UMASK=0022
MOCK_TYPE=oneshot
MOCK_REMAIN_AFTER_EXIT=no
MOCK_USER=""
MOCK_PRIVATE_MOUNTS=no
MOCK_SYSTEM_CALL_FILTER='~'

systemctl() {
    local property="" argument=""
    if [ "${1:-}" = --version ]; then
        printf '%s\n' 'systemd 255 (255.1)'
        return 0
    fi
    [ "${1:-}" = show ] || return 1
    shift
    for argument in "$@"; do
        case "$argument" in
            --property=*) property="${argument#--property=}" ;;
        esac
    done
    case "$property" in
        LoadState) printf '%s\n' "$MOCK_LOAD_STATE" ;;
        FragmentPath) printf '%s\n' "$MOCK_FRAGMENT" ;;
        DropInPaths) printf '%s\n' "$MOCK_DROPINS" ;;
        ExecStart) printf '%s\n' "$MOCK_EXEC_START" ;;
        ExecStartPre) printf '%s\n' "$MOCK_EXEC_START_PRE" ;;
        ExecStartPost) printf '%s\n' "$MOCK_EXEC_START_POST" ;;
        ExecStop) printf '%s\n' "$MOCK_EXEC_STOP" ;;
        ExecStopPost) printf '%s\n' "$MOCK_EXEC_STOP_POST" ;;
        ExecReload) printf '%s\n' "$MOCK_EXEC_RELOAD" ;;
        ExecCondition) printf '%s\n' "$MOCK_EXEC_CONDITION" ;;
        Environment) printf '%s\n' "$MOCK_ENVIRONMENT" ;;
        UMask) printf '%s\n' "$MOCK_UMASK" ;;
        Type) printf '%s\n' "$MOCK_TYPE" ;;
        RemainAfterExit) printf '%s\n' "$MOCK_REMAIN_AFTER_EXIT" ;;
        User) printf '%s\n' "$MOCK_USER" ;;
        PrivateMounts) printf '%s\n' "$MOCK_PRIVATE_MOUNTS" ;;
        SystemCallFilter) printf '%s\n' "$MOCK_SYSTEM_CALL_FILTER" ;;
        DynamicUser|PrivateUsers|RootEphemeral|ProtectHome|ProtectSystem)
            printf '%s\n' no
            ;;
        Group|WorkingDirectory|RootDirectory|RootImage|MountImages|\
        ExtensionImages|ExtensionDirectories|TemporaryFileSystem|BindPaths|\
        BindReadOnlyPaths|InaccessiblePaths|JoinsNamespaceOf|ReadOnlyPaths|\
        ReadWritePaths|EnvironmentFiles|PassEnvironment|UnsetEnvironment|\
        PAMName)
            printf '\n'
            ;;
        *) return 1 ;;
    esac
}

write_legacy_unit() {
    rr_render_legacy_v710_update_recovery_unit > \
        "$RR_UPDATE_RECOVERY_UNIT_FILE"
    chown 0:0 "$RR_UPDATE_RECOVERY_UNIT_FILE"
    chmod "${1:-0600}" "$RR_UPDATE_RECOVERY_UNIT_FILE"
}

printf '%s\n' '[3/7] exact 281-byte v7.1.0 units accept historical safe umasks'
write_legacy_unit 0600
[ "$(wc -c < "$RR_UPDATE_RECOVERY_UNIT_FILE")" -eq 281 ] || \
    fail 'legacy renderer no longer matches the 281-byte v7.1.0 unit'
[ "$(sha256sum "$RR_UPDATE_RECOVERY_UNIT_FILE" | awk '{print $1}')" = \
    95c317ad865e0ac9b77454a6948bea25783ccc19aa52a25134386ee396362412 ] || \
    fail 'legacy renderer no longer matches the exact v7.1.0 unit bytes'
rr_update_recovery_unit_is_owned_or_absent || fail 'exact mode-0600 legacy unit was rejected'
chmod 0644 "$RR_UPDATE_RECOVERY_UNIT_FILE"
rr_update_recovery_unit_is_owned_or_absent || fail 'exact mode-0644 legacy unit was rejected'
chmod 0640 "$RR_UPDATE_RECOVERY_UNIT_FILE"
rr_update_recovery_unit_is_owned_or_absent || fail 'exact mode-0640 legacy unit was rejected'

printf '%s\n' '[4/7] content tampering and unsafe file/parent modes fail closed'
printf '%s\n' '# tampered' >> "$RR_UPDATE_RECOVERY_UNIT_FILE"
expect_rejected 'tampered legacy unit' rr_update_recovery_unit_is_owned_or_absent
write_legacy_unit 0666
expect_rejected 'mode-0666 legacy unit' rr_update_recovery_unit_is_owned_or_absent
write_legacy_unit 0600
chmod 0777 "$systemd_dir"
expect_rejected 'group/other-writable legacy unit parent' \
    rr_update_recovery_unit_is_owned_or_absent
chmod 0755 "$systemd_dir"

printf '%s\n' '[5/7] drop-ins and a mismatched effective fragment fail closed'
MOCK_DROPINS="$systemd_dir/rr-update-recovery.service.d/override.conf"
expect_rejected 'legacy unit with an effective drop-in' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_DROPINS=""
MOCK_FRAGMENT="$systemd_dir/different.service"
expect_rejected 'legacy unit with the wrong effective fragment' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_FRAGMENT="$RR_UPDATE_RECOVERY_UNIT_FILE"

printf '%s\n' '[6/7] stale or altered effective commands and environment fail closed'
MOCK_EXEC_START='{ path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; }'
expect_rejected 'legacy unit with the wrong effective ExecStart' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_EXEC_START='{ path=/usr/local/sbin/rr-update-recover ; argv[]=/usr/local/sbin/rr-update-recover recover ; ignore_errors=no ; }'
MOCK_ENVIRONMENT='UNEXPECTED=1'
expect_rejected 'legacy unit with an effective environment override' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_ENVIRONMENT=""
MOCK_EXEC_START_PRE='{ path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; }'
expect_rejected 'legacy unit with an effective ExecStartPre' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_EXEC_START_PRE=""
MOCK_UMASK=0077
expect_rejected 'legacy unit with the current-profile effective UMask' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_UMASK=0022
MOCK_USER=nobody
expect_rejected 'legacy unit with a non-root effective User' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_USER=""
MOCK_PRIVATE_MOUNTS=yes
expect_rejected 'legacy unit with altered namespace isolation' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_PRIVATE_MOUNTS=no
MOCK_SYSTEM_CALL_FILTER='~@privileged'
expect_rejected 'legacy unit with a non-default system-call filter' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_SYSTEM_CALL_FILTER=''
expect_rejected 'legacy unit with an empty system-call filter rendering' \
    rr_update_recovery_unit_is_owned_or_absent
MOCK_SYSTEM_CALL_FILTER='~'

printf '%s\n' '[7/7] snapshot failures identify the recovery-runtime stage safely'
# shellcheck disable=SC2294
eval "$(extract_function "$REPO_ROOT/scripts/install-core.sh" rr_snapshot_runtime)"
rr_prepare_recovery_runtime() { return 1; }
if snapshot_error=$(rr_snapshot_runtime 2>&1); then
    fail 'snapshot unexpectedly accepted a failed recovery-runtime stage'
fi
grep -Fq 'recovery-runtime 阶段未能建立受信任恢复环境' <<< "$snapshot_error" || \
    fail 'snapshot did not emit the fixed recovery-runtime stage error'

printf '%s\n' 'install recovery runtime regressions: PASS'
