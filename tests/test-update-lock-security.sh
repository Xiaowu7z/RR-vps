#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf '%s\n' 'update lock security regressions require root' >&2
    exit 1
fi

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# This runner maps only uid/gid 0, so physical chown fixtures cannot represent
# hostile ownership.  Override only the two marked stat calls; every ordinary
# path and every fd identity check still reaches the real stat(1).
stat() {
    local -a arguments=("$@")
    local last_index=$(($# - 1))
    local path="${arguments[$last_index]}"
    local argument=""
    if [[ "$path" == */wrong-owner/update.lock ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u:%h ]; then
                printf '%s\n' 65534:1
                return 0
            fi
        done
    fi
    if [[ "$path" == */wrong-parent ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u:%g ]; then
                printf '%s\n' 65534:65534
                return 0
            fi
        done
    fi
    if [[ "$path" == */legacy-wrong-owner/legacy.lock ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u:%g:%a:%h ]; then
                printf '%s\n' 65534:0:644:1
                return 0
            fi
        done
    fi
    if [[ "$path" == */runtime-unmarked-hostile/* ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u:%g ]; then
                printf '%s\n' 65534:65534
                return 0
            fi
        done
    fi
    if [[ "$path" == */installer-unmarked-hostile/* ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u ]; then
                printf '%s\n' 65534
                return 0
            fi
        done
    fi
    if [[ "$path" == */legacy-inode-swap/legacy.lock ]] && \
       [ -e "$path.replacement" ]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %d:%i:%u:%g:%a:%h ]; then
                mv -- "$path" "$path.opened"
                mv -- "$path.replacement" "$path"
                break
            fi
        done
    fi
    command stat "${arguments[@]}"
}

extract_function() {
    local source_file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$source_file"
}

run_helper_security_matrix() (
    local label="$1" source_file="$2" prepare_function="$3" fd_function="$4"
    local case_root="$test_root/helpers/$label"
    local lock_file="" target="" fd="" contender_fd="" held_fd=""

    mkdir -p "$case_root"
    chmod 700 "$case_root"
    # shellcheck disable=SC2294
    eval "$(extract_function "$source_file" "$prepare_function")"
    # shellcheck disable=SC2294
    eval "$(extract_function "$source_file" "$fd_function")"
    declare -F "$prepare_function" >/dev/null || fail "$label prepare helper was not extracted"
    declare -F "$fd_function" >/dev/null || fail "$label fd helper was not extracted"

    # Missing files are created atomically and existing safe files are repaired
    # to the one-link, root-owned 0600 contract.
    mkdir -m 700 "$case_root/create"
    lock_file="$case_root/create/update.lock"
    "$prepare_function" "$lock_file" || fail "$label rejected a safe absent lock"
    [ "$(stat -c '%u:%g:%a:%h' "$lock_file")" = 0:0:600:1 ] || \
        fail "$label created a lock with unsafe metadata"
    exec {fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$fd" || fail "$label rejected matching lock fd"
    exec {fd}>&-

    mkdir -m 700 "$case_root/repair"
    lock_file="$case_root/repair/update.lock"
    : > "$lock_file"
    chmod 0666 "$lock_file"
    "$prepare_function" "$lock_file" || fail "$label did not repair safe root-owned lock metadata"
    [ "$(stat -c '%u:%g:%a:%h' "$lock_file")" = 0:0:600:1 ] || \
        fail "$label left repaired lock metadata unsafe"

    # The dedicated /run/rr-vps/locks directory is always narrowed to 0700.
    # This prevents a low-privilege process from pre-creating lock names even
    # if an earlier installation accidentally left the directory writable.
    mkdir -m 0777 "$case_root/writable-parent"
    "$prepare_function" "$case_root/writable-parent/update.lock" || \
        fail "$label could not repair a root-owned writable parent"
    [ "$(stat -c '%u:%g:%a' "$case_root/writable-parent")" = 0:0:700 ] || \
        fail "$label did not privatize a writable lock parent"
    mkdir -m 1777 "$case_root/sticky-parent"
    "$prepare_function" "$case_root/sticky-parent/update.lock" || \
        fail "$label could not repair a root-owned sticky parent"
    [ "$(stat -c '%u:%g:%a' "$case_root/sticky-parent")" = 0:0:700 ] || \
        fail "$label preserved legacy shared-directory permissions"

    mkdir -m 700 "$case_root/wrong-parent"
    if "$prepare_function" "$case_root/wrong-parent/update.lock"; then
        fail "$label accepted a non-root lock parent"
    fi

    mkdir -m 700 "$case_root/real-parent"
    ln -s real-parent "$case_root/linked-parent"
    if "$prepare_function" "$case_root/linked-parent/update.lock"; then
        fail "$label accepted a symlink lock parent"
    fi

    mkdir -m 0777 "$case_root/preoccupied-parent"
    printf '%s\n' target > "$case_root/preoccupied-target"
    chmod 0644 "$case_root/preoccupied-target"
    ln -s ../preoccupied-target "$case_root/preoccupied-parent/update.lock"
    if "$prepare_function" "$case_root/preoccupied-parent/update.lock"; then
        fail "$label accepted a preoccupied lock name"
    fi
    [ "$(stat -c '%u:%g:%a' "$case_root/preoccupied-parent")" = 0:0:700 ] || \
        fail "$label did not close a previously writable parent"
    [ "$(stat -c %a "$case_root/preoccupied-target")" = 644 ] || \
        fail "$label mutated a preoccupation target"

    # No link or special-file form may be repaired in place: rejecting before
    # chown/chmod avoids mutating an attacker-selected target.
    mkdir -m 700 "$case_root/symlink"
    target="$case_root/symlink/target"
    printf '%s\n' target > "$target"
    chmod 0644 "$target"
    ln -s target "$case_root/symlink/update.lock"
    if "$prepare_function" "$case_root/symlink/update.lock"; then
        fail "$label accepted a symlink lock"
    fi
    [ "$(stat -c %a "$target")" = 644 ] || fail "$label mutated a symlink target"

    mkdir -m 700 "$case_root/fifo"
    mkfifo "$case_root/fifo/update.lock"
    if "$prepare_function" "$case_root/fifo/update.lock"; then
        fail "$label accepted a FIFO lock"
    fi

    mkdir -m 700 "$case_root/hardlink"
    : > "$case_root/hardlink/update.lock"
    ln "$case_root/hardlink/update.lock" "$case_root/hardlink/alias.lock"
    if "$prepare_function" "$case_root/hardlink/update.lock"; then
        fail "$label accepted a multiply-linked lock"
    fi

    mkdir -m 700 "$case_root/wrong-owner"
    : > "$case_root/wrong-owner/update.lock"
    if "$prepare_function" "$case_root/wrong-owner/update.lock"; then
        fail "$label accepted a non-root lock owner"
    fi

    # The fd verifier must bind the opened descriptor to the same inode and to
    # the complete ownership/mode/link-count tuple.
    mkdir -m 700 "$case_root/fd-identity"
    lock_file="$case_root/fd-identity/update.lock"
    "$prepare_function" "$lock_file" || fail "$label could not prepare fd fixture"
    exec {fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$fd" || fail "$label rejected initial fd identity"
    chmod 0644 "$lock_file"
    if "$fd_function" "$lock_file" "$fd"; then
        fail "$label accepted unsafe fd permissions"
    fi
    chmod 0600 "$lock_file"
    mv "$lock_file" "$case_root/fd-identity/opened.lock"
    : > "$lock_file"
    chmod 0600 "$lock_file"
    chown 0:0 "$lock_file"
    if "$fd_function" "$lock_file" "$fd"; then
        fail "$label accepted a path replaced after open"
    fi
    exec {fd}>&-

    # Each helper pair must cooperate with the same kernel flock and release it
    # cleanly after both descriptors close.
    mkdir -m 700 "$case_root/contention"
    lock_file="$case_root/contention/update.lock"
    "$prepare_function" "$lock_file" || fail "$label could not prepare contention fixture"
    exec {held_fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$held_fd" || fail "$label rejected holder fd"
    flock -n "$held_fd" || fail "$label could not acquire an available lock"
    exec {contender_fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$contender_fd" || fail "$label rejected contender fd"
    if flock -n "$contender_fd"; then
        fail "$label allowed a second lock holder"
    fi
    exec {contender_fd}>&-
    exec {held_fd}>&-
    exec {contender_fd}>>"$lock_file"
    flock -n "$contender_fd" || fail "$label did not release the lock after close"
    exec {contender_fd}>&-
)

printf '%s\n' '[1/7] all independently shipped Bash lock helpers enforce one contract'
run_helper_security_matrix \
    installer scripts/install-core.sh rr_prepare_update_lock_file rr_update_lock_fd_is_safe
run_helper_security_matrix \
    recovery scripts/update-recover.sh rr_prepare_update_lock_file rr_update_lock_fd_is_safe
run_helper_security_matrix \
    resilience modules/55-resilience.sh rr_secure_lock_prepare rr_secure_lock_fd_is_safe
run_helper_security_matrix \
    nexus modules/85-nexus.sh nexus_prepare_sync_lock nexus_sync_lock_fd_is_safe

printf '%s\n' '[2/7] installer safely bridges 7.1.0 locking without mutating existing inodes'
(
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_legacy_update_lock_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_legacy_update_lock_parent_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_legacy_update_lock_path_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_legacy_update_lock_fd_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_trusted_installed_runtime_version)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_prepare_legacy_update_bridge_parent)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_legacy_update_bridge_marker_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_publish_legacy_update_bridge_marker)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_legacy_public_lock_is_nonroot_noise)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_promote_trusted_legacy_preoccupation)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_version_ge)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_acquire_legacy_update_lock)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_close_inherited_installer_lock_fds)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_run_with_delegated_update_lock)"
    rr_error() { :; }

    legacy_root="$test_root/legacy-bridge"
    mkdir -m 700 "$legacy_root"
    RR_SUBSCRIPTION_SAFE_VERSION=7.1.1
    RR_LAUNCHER="$legacy_root/rr"
    RR_LEGACY_UPDATE_BRIDGE_FILE="$legacy_root/private/legacy-update-bridge"

    prepare_trusted_runtime() {
        local runtime_root="$1" runtime_version="$2"
        RR_LIB_DIR="$runtime_root"
        mkdir -p "$RR_LIB_DIR/modules"
        chmod 700 "$RR_LIB_DIR" "$RR_LIB_DIR/modules"
        printf 'SCRIPT_VERSION="%s"\n' "$runtime_version" > \
            "$RR_LIB_DIR/modules/00-runtime.sh"
        chmod 600 "$RR_LIB_DIR/modules/00-runtime.sh"
    }
    use_bridge_case() {
        RR_LEGACY_UPDATE_BRIDGE_FILE="$legacy_root/private-$1/legacy-update-bridge"
    }

    use_bridge_case clean
    RR_LIB_DIR="$legacy_root/clean-runtime"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/clean-absent/legacy.lock"
    LEGACY_UPDATE_LOCK_FD=""
    mkdir -m 700 "$legacy_root/clean-absent"
    rr_acquire_legacy_update_lock || fail 'clean install rejected an absent legacy lock'
    [ ! -e "$RR_LEGACY_UPDATE_LOCK_FILE" ] && [ ! -L "$RR_LEGACY_UPDATE_LOCK_FILE" ] || \
        fail 'clean install created a legacy lock in a shared compatibility directory'
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'clean absent legacy path retained an fd'

    use_bridge_case unknown
    RR_LIB_DIR="$legacy_root/unknown-runtime"
    mkdir -m 700 "$RR_LIB_DIR"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/unknown-absent/legacy.lock"
    mkdir -m 700 "$legacy_root/unknown-absent"
    if rr_acquire_legacy_update_lock; then
        fail 'installer inferred a bridge policy from an unversioned existing runtime'
    fi
    [ ! -e "$RR_LEGACY_UPDATE_LOCK_FILE" ] && [ ! -L "$RR_LEGACY_UPDATE_LOCK_FILE" ] || \
        fail 'unknown installed runtime created an uncoordinated legacy lock'
    [ ! -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] && \
        [ ! -L "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] || \
        fail 'unknown installed runtime published an untrusted bridge marker'
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'unknown installed runtime leaked an fd'

    use_bridge_case new
    prepare_trusted_runtime "$legacy_root/new-runtime" 7.1.1
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/new-absent/legacy.lock"
    mkdir -m 700 "$legacy_root/new-absent"
    rr_acquire_legacy_update_lock || fail '7.1.1 install rejected an absent legacy lock'
    [ ! -e "$RR_LEGACY_UPDATE_LOCK_FILE" ] && [ ! -L "$RR_LEGACY_UPDATE_LOCK_FILE" ] || \
        fail '7.1.1 install recreated an unnecessary legacy lock'
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail '7.1.1 absent legacy path retained an fd'

    installer_noise_root="$legacy_root/installer-unmarked-hostile"
    mkdir -m 1777 "$installer_noise_root"
    for hostile_kind in regular symlink fifo; do
        use_bridge_case "new-noise-$hostile_kind"
        RR_LEGACY_UPDATE_LOCK_FILE="$installer_noise_root/$hostile_kind"
        case "$hostile_kind" in
            regular) printf '%s\n' preserve > "$RR_LEGACY_UPDATE_LOCK_FILE" ;;
            symlink)
                printf '%s\n' target-preserve > "$installer_noise_root/target"
                ln -s target "$RR_LEGACY_UPDATE_LOCK_FILE"
                ;;
            fifo) mkfifo "$RR_LEGACY_UPDATE_LOCK_FILE" ;;
        esac
        hostile_before=$(stat -c '%d:%i:%F:%s' "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null || true)
        rr_acquire_legacy_update_lock || \
            fail "unmarked non-root $hostile_kind preplacement caused a clean/current DoS"
        [ -z "$LEGACY_UPDATE_LOCK_FD" ] || \
            fail "ignored non-root $hostile_kind retained a legacy fd"
        [ ! -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] && \
            [ ! -L "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] || \
            fail "ignored non-root $hostile_kind published an authoritative marker"
        [ "$(stat -c '%d:%i:%F:%s' "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null || true)" = \
          "$hostile_before" ] || fail "installer modified ignored non-root $hostile_kind"
    done

    use_bridge_case new-root-abnormal
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/new-root-abnormal.fifo"
    mkfifo "$RR_LEGACY_UPDATE_LOCK_FILE"
    if rr_acquire_legacy_update_lock; then
        fail 'current installer ignored a root-owned abnormal public lock'
    fi
    [ ! -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] || \
        fail 'root-owned abnormal public lock published a bridge marker'

    use_bridge_case new-safe-existing
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/new-safe-existing.lock"
    printf '%s\n' safe-root-evidence > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
    rr_acquire_legacy_update_lock || fail 'current installer rejected safe root-owned legacy evidence'
    rr_legacy_update_bridge_marker_is_safe "$RR_LEGACY_UPDATE_BRIDGE_FILE" || \
        fail 'safe current legacy evidence did not publish a runtime bridge marker'
    exec {LEGACY_UPDATE_LOCK_FD}>&-
    LEGACY_UPDATE_LOCK_FD=""
    exec {current_safe_holder_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
    flock -n "$current_safe_holder_fd" || fail 'current safe bridge fixture could not take lock'
    if rr_acquire_legacy_update_lock; then
        fail 'published marker did not make later runtime legacy acquisition mandatory'
    fi
    exec {current_safe_holder_fd}>&-

    prepare_trusted_runtime "$legacy_root/old-runtime" 7.1.0
    use_bridge_case old-required-preoccupation
    mkdir -m 1777 "$legacy_root/old-required-preoccupation"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/old-required-preoccupation/legacy.lock"
    printf '%s\n' preserve-preoccupation > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
    physical_nonroot_fixture=false
    if chown 65534:65534 "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null; then
        physical_nonroot_fixture=true
    elif [ "${GITHUB_ACTIONS:-false}" = true ]; then
        fail 'GitHub root runner could not create the required physical non-root lock fixture'
    else
        printf '%s\n' 'SKIP: local uid namespace maps only root; physical legacy preoccupation runs in CI'
    fi
    if [ "$physical_nonroot_fixture" = true ]; then
        preoccupation_inode=$(stat -c '%d:%i' "$RR_LEGACY_UPDATE_LOCK_FILE")
        preoccupation_digest=$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")
        rr_acquire_legacy_update_lock || \
            fail 'trusted 7.1.0 upgrade was permanently denied by an idle non-root preoccupation'
        [ "$(stat -c '%d:%i' "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$preoccupation_inode" ] && \
            [ "$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$preoccupation_digest" ] && \
            [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = 0:0:600:1 ] || \
            fail 'legacy preoccupation promotion replaced content/inode or left unsafe metadata'
        rr_legacy_update_bridge_marker_is_safe "$RR_LEGACY_UPDATE_BRIDGE_FILE" || \
            fail 'promoted legacy preoccupation did not publish a trusted bridge marker'
        [ -n "$LEGACY_UPDATE_LOCK_FD" ] || fail 'promoted legacy preoccupation retained no flock fd'
        if flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" -c true; then
            fail 'a 7.1.0 contender entered through the promoted legacy lock'
        fi
        exec {LEGACY_UPDATE_LOCK_FD}>&-
        LEGACY_UPDATE_LOCK_FD=""

        use_bridge_case old-required-busy-preoccupation
        RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/old-required-preoccupation/busy.lock"
        printf '%s\n' busy-preserve > "$RR_LEGACY_UPDATE_LOCK_FILE"
        chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
        chown 65534:65534 "$RR_LEGACY_UPDATE_LOCK_FILE"
        busy_before=$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")
        busy_digest=$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")
        # An exclusive flock does not require a writable descriptor. Open the
        # attacker-owned 0644 inode read-only so this fixture also works on
        # constrained root runners without CAP_DAC_OVERRIDE.
        exec {busy_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
        flock -n "$busy_fd"
        if rr_acquire_legacy_update_lock; then
            fail 'installer mutated or ignored a busy non-root legacy preoccupation'
        fi
        [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$busy_before" ] && \
            [ "$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$busy_digest" ] || \
            fail 'failed busy promotion changed the attacker-owned inode'
        [ ! -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] || \
            fail 'failed busy promotion published a trusted bridge marker'
        exec {busy_fd}>&-
    fi

    use_bridge_case nonsticky-parent
    mkdir -m 0777 "$legacy_root/nonsticky-world-parent"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/nonsticky-world-parent/legacy.lock"
    if rr_acquire_legacy_update_lock; then
        fail 'installer accepted a non-sticky world-writable legacy parent'
    fi
    [ ! -e "$RR_LEGACY_UPDATE_LOCK_FILE" ] || \
        fail 'installer created a legacy lock in a non-sticky world-writable parent'
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'unsafe legacy parent leaked an fd'

    use_bridge_case sticky-parent
    mkdir -m 1777 "$legacy_root/sticky-world-parent"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/sticky-world-parent/legacy.lock"
    rr_acquire_legacy_update_lock || fail 'installer rejected a root-owned sticky legacy parent'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'sticky legacy parent produced unsafe lock metadata'
    exec {LEGACY_UPDATE_LOCK_FD}>&-
    LEGACY_UPDATE_LOCK_FD=""

    use_bridge_case old-absent
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/absent/legacy.lock"
    mkdir -m 700 "$legacy_root/absent"
    rr_acquire_legacy_update_lock || fail 'installer could not bridge an absent legacy lock'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'installer did not atomically create a safe absent legacy lock'
    [ -n "$LEGACY_UPDATE_LOCK_FD" ] || fail 'new legacy lock did not retain its fd'
    if flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" -c true; then
        fail 'a later 7.1.0 process could enter after the absent-lock bridge'
    fi
    [ "$(cat "$RR_LEGACY_UPDATE_BRIDGE_FILE")" = rr-legacy-update-bridge-v1 ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_BRIDGE_FILE")" = 0:0:600:1 ] && \
        [ "$(stat -c '%u:%g:%a' "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")")" = 0:0:700 ] || \
        fail 'old-runtime bridge marker violated its exact private contract'
    exec {LEGACY_UPDATE_LOCK_FD}>&-
    LEGACY_UPDATE_LOCK_FD=""

    use_bridge_case marked-missing
    rr_publish_legacy_update_bridge_marker "$RR_LEGACY_UPDATE_BRIDGE_FILE" || \
        fail 'could not prepare required-missing marker fixture'
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/marked-missing.lock"
    if rr_acquire_legacy_update_lock; then
        fail 'marker-required missing legacy inode was recreated or ignored'
    fi
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'marker-required missing legacy path leaked an fd'

    use_bridge_case marked-unsafe
    rr_publish_legacy_update_bridge_marker "$RR_LEGACY_UPDATE_BRIDGE_FILE" || \
        fail 'could not prepare required-unsafe marker fixture'
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/marked-unsafe.fifo"
    mkfifo "$RR_LEGACY_UPDATE_LOCK_FILE"
    if rr_acquire_legacy_update_lock; then
        fail 'marker-required unsafe legacy inode was accepted'
    fi
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'marker-required unsafe legacy path leaked an fd'

    use_bridge_case unsafe-marker
    mkdir -p "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")"
    chmod 700 "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")"
    printf '%s\n' marker-target > "$legacy_root/unsafe-marker-target"
    ln -s "$legacy_root/unsafe-marker-target" "$RR_LEGACY_UPDATE_BRIDGE_FILE"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/unsafe-marker-legacy.lock"
    : > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0600 "$RR_LEGACY_UPDATE_LOCK_FILE"
    if rr_acquire_legacy_update_lock; then
        fail 'installer accepted an unsafe private bridge marker'
    fi
    grep -Fxq marker-target "$legacy_root/unsafe-marker-target" || \
        fail 'installer followed or modified an unsafe private marker target'
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'unsafe private marker leaked a legacy fd'

    use_bridge_case old-safe
    mkdir -m 700 "$legacy_root/safe"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/safe/legacy.lock"
    printf '%s\n' '7.1.0-lock-sentinel' > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
    legacy_before=$(stat -c '%d:%i:%u:%g:%a:%h:%s' "$RR_LEGACY_UPDATE_LOCK_FILE")
    legacy_digest=$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")
    rr_acquire_legacy_update_lock || fail 'installer rejected a safe existing 0644 legacy lock'
    [ -n "$LEGACY_UPDATE_LOCK_FD" ] || fail 'installer did not retain the legacy bridge fd'
    [ "$(stat -c '%d:%i:%u:%g:%a:%h:%s' "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_before" ] || \
        fail 'installer changed legacy lock inode or metadata'
    [ "$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_digest" ] || \
        fail 'installer changed legacy lock contents'
    if flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" -c true; then
        fail 'installer did not hold the acquired legacy bridge lock'
    fi
    exec {LEGACY_UPDATE_LOCK_FD}>&-
    LEGACY_UPDATE_LOCK_FD=""
    flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" -c true || \
        fail 'installer did not release the legacy bridge lock after fd close'

    use_bridge_case old-busy
    mkdir -m 700 "$legacy_root/busy"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/busy/legacy.lock"
    : > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
    exec {legacy_holder_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
    flock -n "$legacy_holder_fd" || fail 'legacy contention fixture could not take its lock'
    if rr_acquire_legacy_update_lock; then
        fail 'installer ignored a real 7.1.0 lock holder'
    fi
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'installer leaked its failed legacy contender fd'
    exec {legacy_holder_fd}>&-

    for hostile_type in symlink fifo hardlink unsafe-mode unsafe-exec legacy-wrong-owner; do
        use_bridge_case "old-hostile-$hostile_type"
        hostile_dir="$legacy_root/$hostile_type"
        hostile_lock="$hostile_dir/legacy.lock"
        mkdir -m 700 "$hostile_dir"
        case "$hostile_type" in
            symlink)
                printf '%s\n' target > "$hostile_dir/target"
                chmod 0644 "$hostile_dir/target"
                ln -s target "$hostile_lock"
                ;;
            fifo) mkfifo "$hostile_lock" ;;
            hardlink)
                : > "$hostile_lock"
                chmod 0644 "$hostile_lock"
                ln "$hostile_lock" "$hostile_dir/alias.lock"
                ;;
            unsafe-mode)
                : > "$hostile_lock"
                chmod 0666 "$hostile_lock"
                ;;
            unsafe-exec)
                : > "$hostile_lock"
                chmod 0755 "$hostile_lock"
                ;;
            legacy-wrong-owner)
                : > "$hostile_lock"
                chmod 0644 "$hostile_lock"
                ;;
        esac
        RR_LEGACY_UPDATE_LOCK_FILE="$hostile_lock"
        hostile_before=$(stat -c '%d:%i:%a:%h:%s' "$hostile_lock" 2>/dev/null || true)
        if rr_acquire_legacy_update_lock; then
            fail "installer accepted hostile legacy lock type $hostile_type"
        fi
        [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail "installer leaked fd for $hostile_type legacy lock"
        [ "$(stat -c '%d:%i:%a:%h:%s' "$hostile_lock" 2>/dev/null || true)" = "$hostile_before" ] || \
            fail "installer mutated hostile legacy lock type $hostile_type"
    done

    use_bridge_case old-inode-swap
    mkdir -m 700 "$legacy_root/legacy-inode-swap"
    RR_LEGACY_UPDATE_LOCK_FILE="$legacy_root/legacy-inode-swap/legacy.lock"
    printf '%s\n' original > "$RR_LEGACY_UPDATE_LOCK_FILE"
    printf '%s\n' replacement > "$RR_LEGACY_UPDATE_LOCK_FILE.replacement"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE" "$RR_LEGACY_UPDATE_LOCK_FILE.replacement"
    if rr_acquire_legacy_update_lock; then
        fail 'installer accepted a legacy path replaced after open'
    fi
    [ -z "$LEGACY_UPDATE_LOCK_FD" ] || fail 'installer leaked fd after legacy inode replacement'
    grep -Fxq replacement "$RR_LEGACY_UPDATE_LOCK_FILE" || \
        fail 'legacy inode replacement fixture did not execute'
    promotion_source=$(extract_function scripts/install-core.sh \
        rr_promote_trusted_legacy_preoccupation)
    promotion_mismatch_block=$(sed -n \
        '/if not same_inode(current_state, exact_state):/,/os.fchmod(exact_fd, 0o600)/p' \
        <<<"$promotion_source")
    grep -Fq 'fail()' <<<"$promotion_mismatch_block" || \
        fail 'promotion-time legacy inode replacement is not rejected'
    if grep -Fq 'SystemExit(0)' <<<"$promotion_mismatch_block"; then
        fail 'promotion-time root-safe replacement can split the legacy flock domain'
    fi

    delegation_root="$legacy_root/delegation"
    mkdir -m 700 "$delegation_root"
    delegated_new_lock="$delegation_root/update.lock"
    delegated_legacy_lock="$delegation_root/legacy.lock"
    delegated_launcher="$delegation_root/launcher"
    delegated_pid_file="$delegation_root/daemon.pid"
    : > "$delegated_new_lock"
    : > "$delegated_legacy_lock"
    chmod 0600 "$delegated_new_lock" "$delegated_legacy_lock"
    printf '%s\n' \
        '#!/bin/bash' \
        '[ "${RR_UPDATE_LOCK_HELD:-}" = 1 ] || exit 92' \
        'nohup bash -c '\''sleep 30'\'' >/dev/null 2>&1 &' \
        'printf '\''%s\n'\'' "$!" > "${RR_TEST_DAEMON_PID_FILE:?}"' \
        > "$delegated_launcher"
    chmod 0700 "$delegated_launcher"
    exec {UPDATE_LOCK_FD}>>"$delegated_new_lock"
    flock -n "$UPDATE_LOCK_FD" || fail 'delegation fixture could not take new lock'
    exec {LEGACY_UPDATE_LOCK_FD}<"$delegated_legacy_lock"
    flock -n "$LEGACY_UPDATE_LOCK_FD" || fail 'delegation fixture could not take legacy lock'
    RR_TEST_DAEMON_PID_FILE="$delegated_pid_file" \
        rr_run_with_delegated_update_lock "$delegated_launcher" || \
        fail 'delegated launcher fixture failed'
    [ -s "$delegated_pid_file" ] || fail 'delegated launcher did not start its nohup child'
    delegated_pid=$(cat "$delegated_pid_file")
    kill -0 "$delegated_pid" 2>/dev/null || fail 'delegated nohup child exited before lock probe'
    exec {LEGACY_UPDATE_LOCK_FD}>&-
    LEGACY_UPDATE_LOCK_FD=""
    exec {UPDATE_LOCK_FD}>&-
    UPDATE_LOCK_FD=""
    flock -n "$delegated_new_lock" -c true || \
        fail 'delegated nohup child inherited the new transaction lock fd'
    flock -n "$delegated_legacy_lock" -c true || \
        fail 'delegated nohup child inherited the legacy transaction lock fd'
    kill "$delegated_pid" 2>/dev/null || true
    wait "$delegated_pid" 2>/dev/null || true
)

printf '%s\n' '[3/7] standalone recovery distinguishes available, busy and delegated locks'
(
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_prepare_update_lock_file)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_update_lock_fd_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_lock_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_lock_parent_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_lock_path_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_lock_fd_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_acquire_legacy_update_lock)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_read_trusted_private_line)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_bridge_evidence_present)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_bridge_parent_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_bridge_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_acquire_marked_legacy_update_lock)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_bridge_evidence_present)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_bridge_parent_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_read_trusted_private_line)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_legacy_update_bridge_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_acquire_marked_legacy_update_lock)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_close_inherited_recovery_lock_fds)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_acquire_update_lock)"
    rr_recover_log() { :; }

    recovery_root="$test_root/recovery-acquire"
    mkdir -m 700 "$recovery_root"
    RR_UPDATE_LOCK_FILE="$recovery_root/update.lock"
    RR_LEGACY_UPDATE_LOCK_FILE="$recovery_root/rr-update.lock"
    RR_LEGACY_UPDATE_BRIDGE_FILE="$recovery_root/legacy-update-bridge"
    RR_LEGACY_UPDATE_BRIDGE_FILE="$recovery_root/private/legacy-update-bridge"
    RR_UPDATE_RECOVERY_LOCK_FD=""
    RR_UPDATE_RECOVERY_LEGACY_LOCK_FD=""
    rr_acquire_update_lock || fail 'recovery rejected an available secure lock'
    [ -n "$RR_UPDATE_RECOVERY_LOCK_FD" ] || fail 'recovery did not retain its acquired lock fd'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_UPDATE_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'recovery positive acquisition left unsafe metadata'
    rr_close_inherited_recovery_lock_fds

    exec {holder_fd}>>"$RR_UPDATE_LOCK_FILE"
    flock -n "$holder_fd" || fail 'recovery busy fixture could not take lock'
    if rr_acquire_update_lock; then
        fail 'recovery ignored a busy shared lock'
    fi
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] || fail 'recovery leaked a failed contender fd'
    [ -z "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] || fail 'recovery leaked a failed legacy contender fd'
    exec {holder_fd}>&-

    delegated_target="$recovery_root/delegated-target"
    printf '%s\n' unsafe > "$delegated_target"
    ln -s delegated-target "$recovery_root/delegated.lock"
    RR_UPDATE_LOCK_FILE="$recovery_root/delegated.lock"
    RR_UPDATE_LOCK_HELD=1
    rr_acquire_update_lock || fail 'recovery rejected an explicitly delegated parent lock'
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] || fail 'delegated recovery unexpectedly opened another fd'
)

printf '%s\n' '[4/7] Nexus sync serializes callbacks, releases errors and reuses delegation'
(
    # shellcheck disable=SC2294
    eval "$(extract_function modules/85-nexus.sh nexus_prepare_sync_lock)"
    # shellcheck disable=SC2294
    eval "$(extract_function modules/85-nexus.sh nexus_sync_lock_fd_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function modules/85-nexus.sh nexus_with_sync_lock)"

    nexus_root="$test_root/nexus-sync"
    callback_log="$nexus_root/callback.log"
    mkdir -m 700 "$nexus_root"
    NEXUS_SYNC_LOCK_FILE="$nexus_root/sync.lock"
    NEXUS_SYNC_LOCK_WAIT_SECONDS=1

    nexus_test_callback() {
        printf '%s\n' "$1" >> "$callback_log"
        return "${2:-0}"
    }
    nexus_nested_callback() {
        nexus_with_sync_lock nexus_test_callback nested 0
    }

    nexus_with_sync_lock nexus_test_callback positive 0 || fail 'Nexus rejected available sync lock'
    grep -Fxq positive "$callback_log" || fail 'Nexus did not run locked callback'
    [ "$(stat -c '%u:%g:%a:%h' "$NEXUS_SYNC_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'Nexus created unsafe sync lock metadata'

    set +e
    nexus_with_sync_lock nexus_test_callback callback-error 23
    callback_status=$?
    set -e
    [ "$callback_status" -eq 23 ] || fail 'Nexus lost callback failure status'
    exec {after_error_fd}>>"$NEXUS_SYNC_LOCK_FILE"
    flock -n "$after_error_fd" || fail 'Nexus retained sync lock after callback failure'
    exec {after_error_fd}>&-

    : > "$callback_log"
    exec {nexus_holder_fd}>>"$NEXUS_SYNC_LOCK_FILE"
    flock -n "$nexus_holder_fd" || fail 'Nexus busy fixture could not take lock'
    set +e
    nexus_with_sync_lock nexus_test_callback should-not-run 0 >/dev/null 2>&1
    busy_status=$?
    set -e
    [ "$busy_status" -eq 75 ] || fail "Nexus busy lock returned $busy_status instead of 75"
    [ ! -s "$callback_log" ] || fail 'Nexus ran callback without acquiring busy lock'
    exec {nexus_holder_fd}>&-

    unsafe_target="$nexus_root/unsafe-target"
    printf '%s\n' unsafe > "$unsafe_target"
    ln -s unsafe-target "$nexus_root/delegated.lock"
    NEXUS_SYNC_LOCK_FILE="$nexus_root/delegated.lock"
    RR_NEXUS_SYNC_LOCK_HELD=true
    nexus_with_sync_lock nexus_nested_callback || fail 'Nexus nested delegated lock deadlocked'
    grep -Fxq nested "$callback_log" || fail 'Nexus delegated callback did not execute'
)

printf '%s\n' '[5/7] backup and restore share the update lock and delegate recovery safely'
(
    # shellcheck disable=SC1091
    source modules/55-resilience.sh
    resilience_root="$test_root/resilience-calls"
    mkdir -m 700 "$resilience_root"
    RR_RESTORE_LOCK_FILE="$resilience_root/update.lock"
    RR_LEGACY_UPDATE_LOCK_FILE="$resilience_root/legacy.lock"
    RR_LEGACY_UPDATE_BRIDGE_FILE="$resilience_root/bridge/legacy-update-bridge"
    RR_BACKUP_WORK_DIR="$resilience_root/work"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    recovery_log="$resilience_root/recovery.log"
    rr_ensure_resilience_dependencies() { return 0; }
    rr_backup_prepare_work_dir() { return 0; }
    rr_backup_prune_stale_stages() { fail 'resilience test passed its stop sentinel'; }
    rr_restore_recover_active() {
        [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ] || fail 'resilience omitted lock delegation marker'
        if flock -n "$RR_RESTORE_LOCK_FILE" -c true; then
            fail 'resilience callback ran without the parent holding the new lock'
        fi
        if [ "${RR_TEST_EXPECT_LEGACY_LOCK:-0}" = 1 ] && \
           flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" -c true; then
            fail 'runtime callback did not bridge an existing 7.1.0 lock'
        fi
        printf '%s\n' delegated >> "$recovery_log"
        return 1
    }

    set +e
    rr_backup_create "$resilience_root/unused.rrbak" >/dev/null 2>&1
    backup_status=$?
    set -e
    [ "$backup_status" -eq 1 ] || fail 'backup positive lock sentinel returned unexpected status'
    grep -Fxq delegated "$recovery_log" || fail 'backup did not acquire and delegate the shared lock'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_RESTORE_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'backup call path left unsafe lock metadata'
    [ ! -e "$RR_LEGACY_UPDATE_LOCK_FILE" ] || \
        fail 'runtime backup republished an absent predictable legacy lock'

    unmarked_hostile_dir="$resilience_root/runtime-unmarked-hostile"
    mkdir -m 700 "$unmarked_hostile_dir"
    for hostile_kind in regular symlink fifo; do
        RR_LEGACY_UPDATE_LOCK_FILE="$unmarked_hostile_dir/$hostile_kind"
        case "$hostile_kind" in
            regular) printf '%s\n' preserve > "$RR_LEGACY_UPDATE_LOCK_FILE" ;;
            symlink)
                printf '%s\n' target-preserve > "$unmarked_hostile_dir/target"
                ln -s target "$RR_LEGACY_UPDATE_LOCK_FILE"
                ;;
            fifo) mkfifo "$RR_LEGACY_UPDATE_LOCK_FILE" ;;
        esac
        hostile_before=$(stat -c '%d:%i:%F:%s' "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null || true)
        : > "$recovery_log"
        set +e
        rr_backup_create "$resilience_root/unmarked-$hostile_kind.rrbak" >/dev/null 2>&1
        hostile_status=$?
        set -e
        [ "$hostile_status" -eq 1 ] || fail "unmarked $hostile_kind sentinel returned unexpected status"
        grep -Fxq delegated "$recovery_log" || \
            fail "unmarked non-root $hostile_kind preplacement caused a runtime DoS"
        [ "$(stat -c '%d:%i:%F:%s' "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null || true)" = "$hostile_before" ] || \
            fail "runtime modified unmarked non-root $hostile_kind evidence"
    done

    RR_LEGACY_UPDATE_LOCK_FILE="$resilience_root/root-owned-fifo"
    mkfifo "$RR_LEGACY_UPDATE_LOCK_FILE"
    : > "$recovery_log"
    set +e
    rr_backup_create "$resilience_root/root-fifo.rrbak" >/dev/null 2>&1
    root_fifo_status=$?
    set -e
    [ "$root_fifo_status" -eq 1 ] || fail 'root-owned abnormal legacy evidence was accepted'
    [ ! -s "$recovery_log" ] || fail 'backup ran through root-owned abnormal legacy evidence'
    [ -p "$RR_LEGACY_UPDATE_LOCK_FILE" ] || fail 'backup modified root-owned abnormal evidence'

    RR_LEGACY_UPDATE_LOCK_FILE="$resilience_root/legacy.lock"
    printf '%s\n' legacy-sentinel > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
    legacy_identity=$(stat -c '%d:%i' "$RR_LEGACY_UPDATE_LOCK_FILE")
    legacy_digest=$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")
    : > "$recovery_log"
    set +e
    rr_backup_create "$resilience_root/unmarked-legacy.rrbak" >/dev/null 2>&1
    existing_legacy_status=$?
    set -e
    [ "$existing_legacy_status" -eq 1 ] || fail 'backup unmarked-legacy sentinel returned unexpected status'
    grep -Fxq delegated "$recovery_log" || fail 'backup did not continue past safe unmarked legacy evidence'
    [ "$(stat -c %a "$RR_LEGACY_UPDATE_LOCK_FILE")" = 644 ] && \
        [ "$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_digest" ] || \
        fail 'backup modified safe unmarked legacy evidence'
    install -d -m 700 "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")"
    printf '%s\n' wrong-marker > "$RR_LEGACY_UPDATE_BRIDGE_FILE"
    chmod 0600 "$RR_LEGACY_UPDATE_BRIDGE_FILE"
    : > "$recovery_log"
    set +e
    rr_backup_create "$resilience_root/bad-marker.rrbak" >/dev/null 2>&1
    bad_marker_status=$?
    set -e
    [ "$bad_marker_status" -eq 1 ] || fail 'malformed same-boot marker was accepted'
    [ ! -s "$recovery_log" ] || fail 'backup ran through a malformed bridge marker'
    printf '%s\n' "$RR_LEGACY_UPDATE_BRIDGE_VALUE" > "$RR_LEGACY_UPDATE_BRIDGE_FILE"
    chmod 0600 "$RR_LEGACY_UPDATE_BRIDGE_FILE"
    RR_TEST_EXPECT_LEGACY_LOCK=1
    : > "$recovery_log"
    set +e
    rr_backup_create "$resilience_root/marked-legacy.rrbak" >/dev/null 2>&1
    marked_legacy_status=$?
    set -e
    [ "$marked_legacy_status" -eq 1 ] || fail 'backup marked-legacy sentinel returned unexpected status'
    grep -Fxq delegated "$recovery_log" || fail 'backup did not bridge a required legacy lock'
    RR_LEGACY_UPDATE_LOCK_FILE="$resilience_root/required-missing.lock"
    : > "$recovery_log"
    set +e
    rr_backup_create "$resilience_root/required-missing.rrbak" >/dev/null 2>&1
    required_missing_status=$?
    set -e
    [ "$required_missing_status" -eq 1 ] || fail 'required missing legacy inode was accepted'
    [ ! -s "$recovery_log" ] || fail 'backup ran without a marker-required legacy inode'
    RR_LEGACY_UPDATE_LOCK_FILE="$resilience_root/legacy.lock"

    : > "$recovery_log"
    exec {resilience_holder_fd}>>"$RR_RESTORE_LOCK_FILE"
    flock -n "$resilience_holder_fd" || fail 'resilience busy fixture could not take lock'
    set +e
    rr_backup_create "$resilience_root/busy.rrbak" >/dev/null 2>&1
    busy_backup_status=$?
    set -e
    [ "$busy_backup_status" -eq 1 ] || fail 'backup ignored busy shared lock'
    [ ! -s "$recovery_log" ] || fail 'backup delegated recovery without owning busy lock'

    input_backup="$resilience_root/input.rrbak"
    printf '%s\n' fixture > "$input_backup"
    set +e
    rr_restore_backup "$input_backup" >/dev/null 2>&1
    busy_restore_status=$?
    set -e
    [ "$busy_restore_status" -eq 1 ] || fail 'restore ignored busy shared lock'
    [ ! -s "$recovery_log" ] || fail 'restore delegated recovery without owning busy lock'
    exec {resilience_holder_fd}>&-

    exec {legacy_resilience_holder_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
    flock -n "$legacy_resilience_holder_fd" || fail 'legacy runtime contention fixture failed'
    set +e
    rr_backup_create "$resilience_root/legacy-busy.rrbak" >/dev/null 2>&1
    legacy_busy_status=$?
    set -e
    [ "$legacy_busy_status" -eq 1 ] || fail 'backup ignored a busy 7.1.0 bridge lock'
    [ ! -s "$recovery_log" ] || fail 'backup ran after failing legacy lock acquisition'
    exec {legacy_resilience_holder_fd}>&-

    printf '%s\n' preserve > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0666 "$RR_LEGACY_UPDATE_LOCK_FILE"
    legacy_unsafe_before=$(stat -c '%d:%i:%a:%h:%s' "$RR_LEGACY_UPDATE_LOCK_FILE")
    set +e
    rr_backup_create "$resilience_root/legacy-unsafe.rrbak" >/dev/null 2>&1
    legacy_unsafe_status=$?
    set -e
    [ "$legacy_unsafe_status" -eq 1 ] || fail 'backup accepted an unsafe legacy bridge inode'
    [ "$(stat -c '%d:%i:%a:%h:%s' "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_unsafe_before" ] || \
        fail 'backup mutated an unsafe existing legacy bridge inode'
    chmod 0600 "$RR_LEGACY_UPDATE_LOCK_FILE"
    : > "$recovery_log"

    set +e
    rr_restore_backup "$input_backup" >/dev/null 2>&1
    restore_status=$?
    set -e
    [ "$restore_status" -eq 1 ] || fail 'restore positive lock sentinel returned unexpected status'
    grep -Fxq delegated "$recovery_log" || fail 'restore did not acquire and delegate the shared lock'
    [ "$(stat -c '%d:%i' "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_identity" ] || \
        fail 'backup/restore unlinked or replaced the legacy bridge inode'
)

make_worker_lock_harness() {
    local output="$1" lock_path="$2"
    python3 - modules/90-auto-update.sh "$output" "$lock_path" <<'PY'
from __future__ import annotations

import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
output = pathlib.Path(sys.argv[2])
lock_path = sys.argv[3]
legacy_lock_path = lock_path + ".legacy"
bridge_path = lock_path + ".bridge"
start_marker = "    cat > \"$worker_tmp\" <<'PYEOF'\n"
start = source.index(start_marker) + len(start_marker)
end = source.index("\n\ndef log(msg):", start)
preamble = source[start:end]
expected = 'UPDATE_LOCK_PATH = "/run/rr-vps/locks/update.lock"'
legacy_expected = 'LEGACY_UPDATE_LOCK_PATH = "/run/lock/rr-update.lock"'
bridge_expected = 'LEGACY_UPDATE_BRIDGE_PATH = "/run/rr-vps/legacy-update-bridge"'
if (
    preamble.count(expected) != 1
    or preamble.count(legacy_expected) != 1
    or preamble.count(bridge_expected) != 1
):
    raise SystemExit("worker lock constant changed; update the security harness")
preamble = preamble.replace(expected, f'UPDATE_LOCK_PATH = {lock_path!r}')
preamble = preamble.replace(legacy_expected, f'LEGACY_UPDATE_LOCK_PATH = {legacy_lock_path!r}')
preamble = preamble.replace(bridge_expected, f'''LEGACY_UPDATE_BRIDGE_PATH = {bridge_path!r}

# User namespaces used by some local runners map only uid/gid 0.  Permit the
# test harness to present alternate lstat ownership without changing worker
# logic; the normal path leaves os.lstat untouched.
_real_lstat = os.lstat
_lock_lstat_count = 0
def _fixture_lstat(path):
    global _lock_lstat_count
    if path == UPDATE_LOCK_PATH:
        _lock_lstat_count += 1
        if (
            os.environ.get("RR_LOCK_TEST_SWAP_ON_SECOND_LSTAT") == "1"
            and _lock_lstat_count == 2
        ):
            os.replace(UPDATE_LOCK_PATH + ".replacement", UPDATE_LOCK_PATH)
    result = _real_lstat(path)
    if path == os.path.dirname(UPDATE_LOCK_PATH) and os.environ.get(
        "RR_LOCK_TEST_FAKE_PARENT_UID"
    ):
        fields = list(result)
        fields[4] = int(os.environ["RR_LOCK_TEST_FAKE_PARENT_UID"])
        return os.stat_result(fields)
    if path == UPDATE_LOCK_PATH and (
        os.environ.get("RR_LOCK_TEST_FAKE_UID")
        or os.environ.get("RR_LOCK_TEST_FAKE_GID")
    ):
        fields = list(result)
        if os.environ.get("RR_LOCK_TEST_FAKE_UID"):
            fields[4] = int(os.environ["RR_LOCK_TEST_FAKE_UID"])
        if os.environ.get("RR_LOCK_TEST_FAKE_GID"):
            fields[5] = int(os.environ["RR_LOCK_TEST_FAKE_GID"])
        return os.stat_result(fields)
    if path == LEGACY_UPDATE_LOCK_PATH and os.environ.get(
        "RR_LOCK_TEST_FAKE_LEGACY_UID"
    ):
        fields = list(result)
        fields[4] = int(os.environ["RR_LOCK_TEST_FAKE_LEGACY_UID"])
        return os.stat_result(fields)
    return result
os.lstat = _fixture_lstat''')
preamble += '''\n\nwith open(os.environ["RR_LOCK_TEST_SENTINEL"], "w", encoding="utf-8") as sentinel:\n    sentinel.write("lock-acquired\\n")\nif os.environ.get("RR_LOCK_TEST_RELEASE"):\n    import time\n    while not os.path.exists(os.environ["RR_LOCK_TEST_RELEASE"]):\n        time.sleep(0.02)\n'''
output.write_text(preamble, encoding="utf-8")
output.chmod(0o700)
PY
}

run_worker_case() {
    local harness="$1" sentinel="$2" expected_status="$3" delegated="${4:-0}"
    local fake_uid="${5:-}" fake_gid="${6:-}" fake_parent_uid="${7:-}"
    local swap_on_second_lstat="${8:-0}"
    local fake_legacy_uid="${9:-}"
    local worker_status=0
    rm -f -- "$sentinel"
    set +e
    RR_LOCK_TEST_SENTINEL="$sentinel" RR_WORKER_LOCK_HELD="$delegated" \
        RR_LOCK_TEST_FAKE_UID="$fake_uid" RR_LOCK_TEST_FAKE_GID="$fake_gid" \
        RR_LOCK_TEST_FAKE_PARENT_UID="$fake_parent_uid" \
        RR_LOCK_TEST_SWAP_ON_SECOND_LSTAT="$swap_on_second_lstat" \
        RR_LOCK_TEST_FAKE_LEGACY_UID="$fake_legacy_uid" \
        python3 "$harness" >/dev/null 2>&1
    worker_status=$?
    set -e
    [ "$worker_status" -eq "$expected_status" ] || \
        fail "worker returned $worker_status instead of $expected_status for $(basename "$harness")"
}

printf '%s\n' '[6/7] generated Python worker rejects hostile locks and handles busy/delegated runs'
worker_root="$test_root/worker"
mkdir -m 700 "$worker_root"

positive_parent="$worker_root/positive"
positive_lock="$positive_parent/update.lock"
positive_harness="$worker_root/positive.py"
positive_sentinel="$worker_root/positive.reached"
mkdir -m 700 "$positive_parent"
make_worker_lock_harness "$positive_harness" "$positive_lock"
run_worker_case "$positive_harness" "$positive_sentinel" 0
[ -s "$positive_sentinel" ] || fail 'worker did not proceed after acquiring available lock'
[ "$(stat -c '%u:%g:%a:%h' "$positive_lock")" = 0:0:600:1 ] || \
    fail 'worker created unsafe lock metadata'
[ ! -e "$positive_lock.legacy" ] || \
    fail 'worker republished an absent predictable legacy bridge lock'
[ "$(stat -c '%u:%g:%a' "$positive_parent")" = 0:0:700 ] || \
    fail 'worker did not create a private lock directory'
chmod 0666 "$positive_lock"
run_worker_case "$positive_harness" "$positive_sentinel" 0
[ "$(stat -c %a "$positive_lock")" = 600 ] || fail 'worker did not normalize lock mode'

sticky_parent="$worker_root/sticky"
sticky_lock="$sticky_parent/update.lock"
sticky_harness="$worker_root/sticky.py"
sticky_sentinel="$worker_root/sticky.reached"
mkdir -m 1777 "$sticky_parent"
make_worker_lock_harness "$sticky_harness" "$sticky_lock"
run_worker_case "$sticky_harness" "$sticky_sentinel" 0
[ -s "$sticky_sentinel" ] || fail 'worker rejected root-owned sticky lock parent'
[ "$(stat -c '%u:%g:%a' "$sticky_parent")" = 0:0:700 ] || \
    fail 'worker did not privatize legacy sticky lock parent'

writable_parent="$worker_root/writable-parent"
writable_harness="$worker_root/writable-parent.py"
writable_sentinel="$worker_root/writable-parent.reached"
mkdir -m 0777 "$writable_parent"
make_worker_lock_harness "$writable_harness" "$writable_parent/update.lock"
run_worker_case "$writable_harness" "$writable_sentinel" 0
[ -s "$writable_sentinel" ] || fail 'worker could not repair root-owned writable parent'
[ "$(stat -c '%u:%g:%a' "$writable_parent")" = 0:0:700 ] || \
    fail 'worker left a writable lock parent'

preoccupied_parent="$worker_root/preoccupied-parent"
preoccupied_lock="$preoccupied_parent/update.lock"
preoccupied_target="$worker_root/preoccupied-target"
preoccupied_harness="$worker_root/preoccupied-parent.py"
preoccupied_sentinel="$worker_root/preoccupied-parent.reached"
mkdir -m 0777 "$preoccupied_parent"
printf '%s\n' target > "$preoccupied_target"
chmod 0644 "$preoccupied_target"
ln -s ../preoccupied-target "$preoccupied_lock"
make_worker_lock_harness "$preoccupied_harness" "$preoccupied_lock"
run_worker_case "$preoccupied_harness" "$preoccupied_sentinel" 1
[ ! -e "$preoccupied_sentinel" ] || fail 'worker accepted a preoccupied lock name'
[ "$(stat -c '%u:%g:%a' "$preoccupied_parent")" = 0:0:700 ] || \
    fail 'worker did not close a previously writable parent'
[ "$(stat -c %a "$preoccupied_target")" = 644 ] || \
    fail 'worker mutated a preoccupation target'

linked_real_parent="$worker_root/linked-real-parent"
linked_parent="$worker_root/linked-parent"
linked_harness="$worker_root/linked-parent.py"
linked_sentinel="$worker_root/linked-parent.reached"
mkdir -m 700 "$linked_real_parent"
ln -s linked-real-parent "$linked_parent"
make_worker_lock_harness "$linked_harness" "$linked_parent/update.lock"
run_worker_case "$linked_harness" "$linked_sentinel" 1
[ ! -e "$linked_sentinel" ] || fail 'worker proceeded through symlink lock parent'

foreign_parent="$worker_root/foreign-parent"
foreign_harness="$worker_root/foreign-parent.py"
foreign_sentinel="$worker_root/foreign-parent.reached"
mkdir -m 700 "$foreign_parent"
make_worker_lock_harness "$foreign_harness" "$foreign_parent/update.lock"
run_worker_case "$foreign_harness" "$foreign_sentinel" 1 0 '' '' 65534
[ ! -e "$foreign_sentinel" ] || fail 'worker proceeded through non-root lock parent'

for hostile_type in symlink fifo hardlink wrong-owner wrong-group; do
    hostile_parent="$worker_root/$hostile_type"
    hostile_lock="$hostile_parent/update.lock"
    hostile_harness="$worker_root/$hostile_type.py"
    hostile_sentinel="$worker_root/$hostile_type.reached"
    mkdir -m 700 "$hostile_parent"
    case "$hostile_type" in
        symlink)
            printf '%s\n' target > "$hostile_parent/target"
            ln -s target "$hostile_lock"
            ;;
        fifo) mkfifo "$hostile_lock" ;;
        hardlink)
            : > "$hostile_lock"
            ln "$hostile_lock" "$hostile_parent/alias.lock"
            ;;
        wrong-owner)
            : > "$hostile_lock"
            ;;
        wrong-group)
            : > "$hostile_lock"
            ;;
    esac
    make_worker_lock_harness "$hostile_harness" "$hostile_lock"
    case "$hostile_type" in
        wrong-owner) run_worker_case "$hostile_harness" "$hostile_sentinel" 1 0 65534 ;;
        wrong-group) run_worker_case "$hostile_harness" "$hostile_sentinel" 1 0 '' 65534 ;;
        *) run_worker_case "$hostile_harness" "$hostile_sentinel" 1 ;;
    esac
    [ ! -e "$hostile_sentinel" ] || fail "worker proceeded through $hostile_type lock"
done

swap_parent="$worker_root/inode-swap"
swap_lock="$swap_parent/update.lock"
swap_harness="$worker_root/inode-swap.py"
swap_sentinel="$worker_root/inode-swap.reached"
mkdir -m 700 "$swap_parent"
printf '%s\n' original > "$swap_lock"
printf '%s\n' replacement > "$swap_lock.replacement"
chmod 0600 "$swap_lock" "$swap_lock.replacement"
make_worker_lock_harness "$swap_harness" "$swap_lock"
run_worker_case "$swap_harness" "$swap_sentinel" 1 0 '' '' '' 1
[ ! -e "$swap_sentinel" ] || fail 'worker accepted an inode replaced after open'
grep -Fxq replacement "$swap_lock" || fail 'worker inode-swap fixture did not execute'

busy_parent="$worker_root/busy"
busy_lock="$busy_parent/update.lock"
busy_harness="$worker_root/busy.py"
busy_sentinel="$worker_root/busy.reached"
mkdir -m 700 "$busy_parent"
: > "$busy_lock"
chmod 0600 "$busy_lock"
make_worker_lock_harness "$busy_harness" "$busy_lock"
exec {worker_holder_fd}>>"$busy_lock"
flock -n "$worker_holder_fd" || fail 'worker busy fixture could not take lock'
run_worker_case "$busy_harness" "$busy_sentinel" 0
[ ! -e "$busy_sentinel" ] || fail 'busy standalone worker performed post-lock work'

run_worker_case "$busy_harness" "$busy_sentinel" 0 1
[ -s "$busy_sentinel" ] || fail 'delegated worker did not reuse its parent lock'
exec {worker_holder_fd}>&-

legacy_existing_parent="$worker_root/legacy-existing"
legacy_existing_lock="$legacy_existing_parent/update.lock"
legacy_existing_harness="$worker_root/legacy-existing.py"
legacy_existing_sentinel="$worker_root/legacy-existing.reached"
mkdir -m 700 "$legacy_existing_parent"
: > "$legacy_existing_lock"
printf '%s\n' legacy-sentinel > "$legacy_existing_lock.legacy"
chmod 0600 "$legacy_existing_lock"
chmod 0644 "$legacy_existing_lock.legacy"
legacy_existing_before=$(stat -c '%d:%i:%u:%g:%a:%h:%s' "$legacy_existing_lock.legacy")
legacy_existing_digest=$(sha256sum "$legacy_existing_lock.legacy")
make_worker_lock_harness "$legacy_existing_harness" "$legacy_existing_lock"
run_worker_case "$legacy_existing_harness" "$legacy_existing_sentinel" 0
[ -s "$legacy_existing_sentinel" ] || fail 'worker rejected a trusted existing legacy bridge'
[ "$(stat -c '%d:%i:%u:%g:%a:%h:%s' "$legacy_existing_lock.legacy")" = "$legacy_existing_before" ] && \
    [ "$(sha256sum "$legacy_existing_lock.legacy")" = "$legacy_existing_digest" ] || \
    fail 'worker modified a trusted existing legacy bridge inode'

for legacy_unmarked_kind in regular symlink fifo; do
    legacy_unmarked_parent="$worker_root/legacy-unmarked-$legacy_unmarked_kind"
    legacy_unmarked_lock="$legacy_unmarked_parent/update.lock"
    legacy_unmarked_harness="$worker_root/legacy-unmarked-$legacy_unmarked_kind.py"
    legacy_unmarked_sentinel="$worker_root/legacy-unmarked-$legacy_unmarked_kind.reached"
    mkdir -m 700 "$legacy_unmarked_parent"
    : > "$legacy_unmarked_lock"
    chmod 0600 "$legacy_unmarked_lock"
    case "$legacy_unmarked_kind" in
        regular) printf '%s\n' preserve > "$legacy_unmarked_lock.legacy" ;;
        symlink)
            printf '%s\n' preserve > "$legacy_unmarked_parent/target"
            ln -s target "$legacy_unmarked_lock.legacy"
            ;;
        fifo) mkfifo "$legacy_unmarked_lock.legacy" ;;
    esac
    legacy_unmarked_before=$(stat -c '%d:%i:%F:%s' "$legacy_unmarked_lock.legacy" 2>/dev/null || true)
    make_worker_lock_harness "$legacy_unmarked_harness" "$legacy_unmarked_lock"
    run_worker_case "$legacy_unmarked_harness" "$legacy_unmarked_sentinel" 0 \
        0 '' '' '' 0 65534
    [ -s "$legacy_unmarked_sentinel" ] || \
        fail "worker let unmarked non-root $legacy_unmarked_kind evidence cause a DoS"
    [ "$(stat -c '%d:%i:%F:%s' "$legacy_unmarked_lock.legacy" 2>/dev/null || true)" = \
        "$legacy_unmarked_before" ] || \
        fail "worker modified unmarked non-root $legacy_unmarked_kind evidence"
done

legacy_busy_parent="$worker_root/legacy-busy"
legacy_busy_lock="$legacy_busy_parent/update.lock"
legacy_busy_harness="$worker_root/legacy-busy.py"
legacy_busy_sentinel="$worker_root/legacy-busy.reached"
mkdir -m 700 "$legacy_busy_parent"
: > "$legacy_busy_lock"
: > "$legacy_busy_lock.legacy"
chmod 0600 "$legacy_busy_lock" "$legacy_busy_lock.legacy"
printf '%s\n' 'rr-legacy-update-bridge-v1' > "$legacy_busy_lock.bridge"
chmod 0600 "$legacy_busy_lock.bridge"
make_worker_lock_harness "$legacy_busy_harness" "$legacy_busy_lock"
exec {legacy_worker_holder_fd}<"$legacy_busy_lock.legacy"
flock -n "$legacy_worker_holder_fd" || fail 'worker legacy-busy fixture could not take its lock'
run_worker_case "$legacy_busy_harness" "$legacy_busy_sentinel" 0
[ ! -e "$legacy_busy_sentinel" ] || fail 'worker ignored a busy 7.1.0 bridge lock'
exec {legacy_worker_holder_fd}>&-

legacy_required_missing_parent="$worker_root/legacy-required-missing"
legacy_required_missing_lock="$legacy_required_missing_parent/update.lock"
legacy_required_missing_harness="$worker_root/legacy-required-missing.py"
legacy_required_missing_sentinel="$worker_root/legacy-required-missing.reached"
mkdir -m 700 "$legacy_required_missing_parent"
: > "$legacy_required_missing_lock"
chmod 0600 "$legacy_required_missing_lock"
printf '%s\n' 'rr-legacy-update-bridge-v1' > "$legacy_required_missing_lock.bridge"
chmod 0600 "$legacy_required_missing_lock.bridge"
make_worker_lock_harness "$legacy_required_missing_harness" "$legacy_required_missing_lock"
run_worker_case "$legacy_required_missing_harness" "$legacy_required_missing_sentinel" 1
[ ! -e "$legacy_required_missing_sentinel" ] || \
    fail 'worker accepted a marker-required missing legacy inode'

legacy_bad_marker_parent="$worker_root/legacy-bad-marker"
legacy_bad_marker_lock="$legacy_bad_marker_parent/update.lock"
legacy_bad_marker_harness="$worker_root/legacy-bad-marker.py"
legacy_bad_marker_sentinel="$worker_root/legacy-bad-marker.reached"
mkdir -m 700 "$legacy_bad_marker_parent"
: > "$legacy_bad_marker_lock"
: > "$legacy_bad_marker_lock.legacy"
printf '%s\n' wrong > "$legacy_bad_marker_lock.bridge"
chmod 0600 "$legacy_bad_marker_lock" "$legacy_bad_marker_lock.legacy" \
    "$legacy_bad_marker_lock.bridge"
make_worker_lock_harness "$legacy_bad_marker_harness" "$legacy_bad_marker_lock"
run_worker_case "$legacy_bad_marker_harness" "$legacy_bad_marker_sentinel" 1
[ ! -e "$legacy_bad_marker_sentinel" ] || fail 'worker accepted a malformed bridge marker'

legacy_hostile_parent="$worker_root/legacy-hostile"
legacy_hostile_lock="$legacy_hostile_parent/update.lock"
legacy_hostile_harness="$worker_root/legacy-hostile.py"
legacy_hostile_sentinel="$worker_root/legacy-hostile.reached"
mkdir -m 700 "$legacy_hostile_parent"
: > "$legacy_hostile_lock"
printf '%s\n' preserve > "$legacy_hostile_lock.legacy"
chmod 0600 "$legacy_hostile_lock"
chmod 0666 "$legacy_hostile_lock.legacy"
legacy_hostile_before=$(stat -c '%d:%i:%a:%h:%s' "$legacy_hostile_lock.legacy")
make_worker_lock_harness "$legacy_hostile_harness" "$legacy_hostile_lock"
run_worker_case "$legacy_hostile_harness" "$legacy_hostile_sentinel" 1
[ ! -e "$legacy_hostile_sentinel" ] || fail 'worker accepted an unsafe legacy bridge inode'
[ "$(stat -c '%d:%i:%a:%h:%s' "$legacy_hostile_lock.legacy")" = "$legacy_hostile_before" ] || \
    fail 'worker mutated an unsafe legacy bridge inode'

printf '%s\n' '[7/7] production call sites preserve shared-lock and worker delegation wiring'
assert_fd_helper_contract() {
    local source_file="$1" function_name="$2" body=""
    body=$(extract_function "$source_file" "$function_name")
    grep -Fq 'local shell_pid="${BASHPID:-$$}"' <<< "$body" || \
        fail "$source_file expands BASHPID inside command substitution"
    grep -Fq 'local fd_path="/proc/$shell_pid/fd/$lock_fd"' <<< "$body" || \
        fail "$source_file does not bind fd inspection to the caller shell"
    grep -Fq '[ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"' <<< "$body" || \
        fail "$source_file lacks procfs namespace fallback for fd inspection"
    grep -Fq 'stat -Lc' <<< "$body" && grep -Fq -- '"$fd_path"' <<< "$body" || \
        fail "$source_file does not stat the precomputed fd path"
}

assert_fd_helper_contract scripts/install-core.sh rr_update_lock_fd_is_safe
assert_fd_helper_contract scripts/update-recover.sh rr_update_lock_fd_is_safe
assert_fd_helper_contract modules/55-resilience.sh rr_secure_lock_fd_is_safe
assert_fd_helper_contract modules/85-nexus.sh nexus_sync_lock_fd_is_safe

grep -Fq 'RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"' \
    scripts/install-core.sh || fail 'installer default shared lock path regressed'
grep -Fq 'RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"' \
    scripts/update-recover.sh || fail 'recovery default shared lock path regressed'
grep -Fq 'RR_RESTORE_LOCK_FILE="${RR_RESTORE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"' \
    modules/55-resilience.sh || fail 'backup/restore default shared lock path regressed'
grep -Fq 'NEXUS_SYNC_LOCK_FILE="${RR_NEXUS_SYNC_LOCK_FILE:-/run/rr-vps/locks/nexus-sync.lock}"' \
    modules/85-nexus.sh || fail 'Nexus default sync lock path regressed'
grep -Fq 'UPDATE_LOCK_PATH = "/run/rr-vps/locks/update.lock"' modules/90-auto-update.sh || \
    fail 'worker default shared lock path regressed'
grep -Fq 'LEGACY_UPDATE_LOCK_PATH = "/run/lock/rr-update.lock"' modules/90-auto-update.sh || \
    fail 'worker legacy 7.1.0 bridge path regressed'
grep -Fq 'LEGACY_UPDATE_BRIDGE_PATH = "/run/rr-vps/legacy-update-bridge"' \
    modules/90-auto-update.sh || fail 'worker same-boot bridge marker path regressed'
grep -Fq 'RR_LEGACY_UPDATE_LOCK_FILE="${RR_LEGACY_UPDATE_LOCK_FILE:-/run/lock/rr-update.lock}"' \
    modules/55-resilience.sh || fail 'runtime legacy 7.1.0 bridge path regressed'
grep -Fq 'RR_LEGACY_UPDATE_BRIDGE_FILE="${RR_LEGACY_UPDATE_BRIDGE_FILE:-/run/rr-vps/legacy-update-bridge}"' \
    modules/55-resilience.sh || fail 'runtime same-boot bridge marker path regressed'
grep -Fq 'RR_LEGACY_UPDATE_LOCK_FILE="${RR_LEGACY_UPDATE_LOCK_FILE:-/run/lock/rr-update.lock}"' \
    scripts/install-core.sh || fail 'installer legacy 7.1.0 bridge path regressed'
grep -Fq 'RR_LEGACY_UPDATE_BRIDGE_FILE="${RR_LEGACY_UPDATE_BRIDGE_FILE:-/run/rr-vps/legacy-update-bridge}"' \
    scripts/install-core.sh || fail 'installer private same-boot bridge marker path regressed'
grep -Fq 'rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE"' \
    scripts/install-core.sh || fail 'installer no longer acquires the legacy bridge lock'
grep -Fq 'rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE"' scripts/install-core.sh || \
    fail 'installer no longer prepares the configured shared update lock'
grep -Fq 'rr_update_lock_fd_is_safe "$RR_UPDATE_LOCK_FILE" "$UPDATE_LOCK_FD"' \
    scripts/install-core.sh || fail 'installer no longer validates opened lock identity'
installer_source_flat=$(tr '\n' ' ' < scripts/install-core.sh)
grep -Eq 'rr_run_with_delegated_update_lock[[:space:]]*\\[[:space:]]*"\$RR_RECOVERY_HELPER" recover' \
    <<<"$installer_source_flat" || \
    fail 'installer recovery delegation marker is missing'
grep -Fq 'rr_resume_subscription_bounded || rollback_failed=true' \
    scripts/install-core.sh || \
    fail 'installer bounded subscription fallback marker is missing'
grep -Fq '"$RR_LAUNCHER" --refresh-subscription' scripts/install-core.sh || \
    fail 'installer subscription refresh launcher contract is missing'
grep -Fq 'rr_run_with_delegated_update_lock "$RR_LAUNCHER" --post-update' \
    scripts/install-core.sh || \
    fail 'installer post-update delegation marker is missing'
delegate_body=$(extract_function scripts/install-core.sh rr_run_with_delegated_update_lock)
delegate_close_body=$(extract_function scripts/install-core.sh \
    rr_close_inherited_installer_lock_fds)
grep -Fq 'rr_close_inherited_installer_lock_fds' <<<"$delegate_body" && \
    grep -Fq 'exec {lock_fd}>&-' <<<"$delegate_close_body" && \
    grep -Fq 'LEGACY_UPDATE_LOCK_FD=""' <<<"$delegate_close_body" && \
    grep -Fq 'UPDATE_LOCK_FD=""' <<<"$delegate_close_body" && \
    grep -Fq 'RR_UPDATE_LOCK_HELD=1 "$@"' <<<"$delegate_body" || \
    fail 'installer delegate does not close both inherited fds before invoking children'
resilience_source_flat=$(tr '\n' ' ' < modules/55-resilience.sh)
grep -Eq 'RR_RESTORE_LOCK_HELD=1[[:space:]\\]+rr_restore_recover_active' \
    <<<"$resilience_source_flat" || \
    fail 'backup/watchdog recovery delegation marker is missing'
grep -Fq 'local RR_NEXUS_SYNC_LOCK_HELD=true' modules/85-nexus.sh || \
    fail 'Nexus nested sync delegation marker is missing'
grep -Fq 'RR_WORKER_LOCK_HELD=1 python3 /usr/local/bin/auto_update_sub.py' modules/60-update.sh || \
    fail 'post-update worker delegation marker is missing'

installer_entry=$(sed -n '/^rr_prepare_update_lock_file "\$RR_UPDATE_LOCK_FILE"/,$p' \
    scripts/install-core.sh)
new_lock_line=$(grep -n 'flock -n "$UPDATE_LOCK_FD"' <<<"$installer_entry" | head -n 1 | cut -d: -f1)
legacy_lock_line=$(grep -n 'rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE"' \
    <<<"$installer_entry" | head -n 1 | cut -d: -f1)
fetch_line=$(grep -n '^rr_fetch_release' <<<"$installer_entry" | head -n 1 | cut -d: -f1)
[[ "$new_lock_line" =~ ^[0-9]+$ && "$legacy_lock_line" =~ ^[0-9]+$ && \
   "$fetch_line" =~ ^[0-9]+$ ]] || fail 'installer dual-lock ordering evidence is incomplete'
[ "$new_lock_line" -lt "$legacy_lock_line" ] && [ "$legacy_lock_line" -lt "$fetch_line" ] || \
    fail 'installer does not hold new then legacy locks before transaction work'
legacy_failure_tail=${installer_entry#*if ! rr_acquire_legacy_update_lock}
legacy_failure_block=${legacy_failure_tail%%rr_fetch_release*}
grep -Fq 'exec {UPDATE_LOCK_FD}>&-' <<<"$legacy_failure_block" || \
    fail 'installer does not close its new lock fd when legacy acquisition fails'

installer_tail=$(sed -n '/^rr_cleanup 0$/,$p' scripts/install-core.sh)
close_line=$(grep -n 'exec {UPDATE_LOCK_FD}>&-' <<<"$installer_tail" | head -n 1 | cut -d: -f1)
launcher_line=$(grep -n 'exec "$RR_LAUNCHER"' <<<"$installer_tail" | head -n 1 | cut -d: -f1)
[[ "$close_line" =~ ^[0-9]+$ && "$launcher_line" =~ ^[0-9]+$ ]] || \
    fail 'installer launch lock-release evidence is incomplete'
[ "$close_line" -lt "$launcher_line" ] || \
    fail 'interactive launcher can inherit the installer transaction lock'
grep -Fq 'UPDATE_LOCK_FD=""' <<<"$installer_tail" || \
    fail 'installer does not invalidate its closed lock descriptor'

launcher_lock="$test_root/launcher-inheritance.lock"
bash -c '
    set -e
    exec {lock_fd}>>"$1"
    flock -n "$lock_fd"
    exec {lock_fd}>&-
    exec flock -n "$1" -c true
' bash "$launcher_lock" || fail 'closed installer-style fd remained inherited across exec'

printf '%s\n' 'update lock security regressions: PASS'
