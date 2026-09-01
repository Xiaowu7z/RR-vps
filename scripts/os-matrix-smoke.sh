#!/bin/bash
# Runs inside disposable Debian/Ubuntu CI containers.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
expected_version=$(sed -n '1s/^RR-vps //p' version | tr -d '[:space:]')
case "$expected_version" in
    ''|*[!0-9A-Za-z.-]*) echo "Invalid repository version: $expected_version" >&2; exit 1 ;;
esac

python3 scripts/rebuild-bundle.py --check
bash scripts/validate.sh

mock_bin=$(mktemp -d)
trap 'rm -rf "$mock_bin"' EXIT
cat > "$mock_bin/systemctl" <<'EOF'
#!/bin/sh
# Container CI has no PID-1 systemd.  Service semantics are covered by the
# regression suite; the OS matrix exercises filesystem transactions.  Keep a
# small state model because production transaction code deliberately treats an
# empty or inconsistent `systemctl show` response as unsafe.
set -eu

state_dir=${0%/*}/systemctl-state
mkdir -p "$state_dir/active" "$state_dir/enabled"

normalize_unit() {
    case "$1" in
        *.*) printf '%s\n' "$1" ;;
        *) printf '%s.service\n' "$1" ;;
    esac
}

unit_is_safe() {
    case "$1" in
        ''|*[!A-Za-z0-9_.@-]*) return 1 ;;
        *) return 0 ;;
    esac
}

unit_file() {
    unit=$1
    if [ -n "${RR_MOCK_SYSTEMD_UNIT_DIR:-}" ]; then
        candidate="$RR_MOCK_SYSTEMD_UNIT_DIR/$unit"
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    for candidate in \
        "/etc/systemd/system/$unit" \
        "/lib/systemd/system/$unit" \
        "/usr/lib/systemd/system/$unit"; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

unit_is_masked() {
    path=$(unit_file "$1" 2>/dev/null) || return 1
    [ -L "$path" ] && [ "$(readlink "$path" 2>/dev/null || true)" = /dev/null ]
}

command=${1:-}
[ -n "$command" ] || exit 1
shift

case "$command" in
    --version)
        # Exercise the modern-property branch of the production effective-unit
        # validator on every matrix image.  The container has no systemd bus,
        # so this value belongs to the shim rather than the host binary.
        printf '%s\n' 'systemd 255 (255.0)'
        ;;
    daemon-reload|reset-failed)
        exit 0
        ;;
    show)
        property=
        requested_unit=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -p|--property)
                    [ "$#" -ge 2 ] || exit 1
                    property=$2
                    shift 2
                    ;;
                --property=*) property=${1#*=}; shift ;;
                --value) shift ;;
                --*) shift ;;
                *) requested_unit=$1; shift ;;
            esac
        done
        [ -n "$requested_unit" ] && [ -n "$property" ] || exit 1
        unit=$(normalize_unit "$requested_unit")
        unit_is_safe "$unit" || exit 1
        fragment=$(unit_file "$unit" 2>/dev/null || true)
        case "$property" in
            LoadState)
                if unit_is_masked "$unit"; then
                    printf '%s\n' masked
                elif [ -n "$fragment" ]; then
                    printf '%s\n' loaded
                else
                    printf '%s\n' not-found
                fi
                ;;
            ActiveState)
                if [ -e "$state_dir/active/$unit" ]; then
                    printf '%s\n' active
                else
                    printf '%s\n' inactive
                fi
                ;;
            UnitFileState)
                if unit_is_masked "$unit"; then
                    printf '%s\n' masked
                elif [ -e "$state_dir/enabled/$unit" ]; then
                    printf '%s\n' enabled
                elif [ -n "$fragment" ]; then
                    printf '%s\n' disabled
                else
                    printf '%s\n' not-found
                fi
                ;;
            FragmentPath) printf '%s\n' "$fragment" ;;
            DropInPaths) printf '\n' ;;
            MainPID) printf '0\n' ;;
            ExecStart)
                if [ "$unit" = rr-update-recovery.service ] && [ -n "$fragment" ]; then
                    printf '%s\n' '{ path=/usr/local/sbin/rr-update-recover ; argv[]=/usr/local/sbin/rr-update-recover recover ; ignore_errors=no ; }'
                else
                    printf '\n'
                fi
                ;;
            Environment)
                if [ "$unit" = rr-update-recovery.service ] && [ -n "$fragment" ]; then
                    printf '%s\n' 'RR_UPDATE_RECOVERY_SERVICE=1'
                else
                    printf '\n'
                fi
                ;;
            Type)
                if [ "$unit" = rr-update-recovery.service ] && [ -n "$fragment" ]; then
                    printf '%s\n' oneshot
                else
                    printf '%s\n' simple
                fi
                ;;
            DynamicUser|PrivateUsers|PrivateMounts|RootEphemeral|ProtectHome|ProtectSystem)
                printf '%s\n' no
                ;;
            RemainAfterExit) printf '%s\n' no ;;
            User|Group|WorkingDirectory|ExecStartPre|ExecReload|ExecCondition|\
            RootDirectory|RootImage|MountImages|ExtensionImages|\
            ExtensionDirectories|TemporaryFileSystem|BindPaths|BindReadOnlyPaths|\
            InaccessiblePaths|JoinsNamespaceOf|ReadOnlyPaths|ReadWritePaths|\
            EnvironmentFiles|PassEnvironment|UnsetEnvironment|PAMName|\
            SystemCallFilter)
                printf '\n'
                ;;
            *) exit 1 ;;
        esac
        ;;
    is-active|is-enabled)
        units=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --*) shift ;;
                *) units="$units $(normalize_unit "$1")"; shift ;;
            esac
        done
        [ -n "$units" ] || exit 1
        for unit in $units; do
            unit_is_safe "$unit" || exit 1
            case "$command" in
                is-active) [ -e "$state_dir/active/$unit" ] || exit 1 ;;
                is-enabled) [ -e "$state_dir/enabled/$unit" ] || exit 1 ;;
            esac
        done
        ;;
    enable|disable|start|stop|restart)
        now=false
        units=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --now) now=true; shift ;;
                --*) shift ;;
                *) units="$units $(normalize_unit "$1")"; shift ;;
            esac
        done
        [ -n "$units" ] || exit 1
        for unit in $units; do
            unit_is_safe "$unit" || exit 1
            case "$command" in
                enable)
                    : > "$state_dir/enabled/$unit"
                    [ "$now" = false ] || : > "$state_dir/active/$unit"
                    ;;
                disable)
                    rm -f -- "$state_dir/enabled/$unit"
                    [ "$now" = false ] || rm -f -- "$state_dir/active/$unit"
                    ;;
                start|restart) : > "$state_dir/active/$unit" ;;
                stop) rm -f -- "$state_dir/active/$unit" ;;
            esac
        done
        ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$mock_bin/systemctl"
install -d -m 755 "$mock_bin/units"
export RR_MOCK_SYSTEMD_UNIT_DIR="$mock_bin/units"
export PATH="$mock_bin:$PATH"

# Fail immediately if the container shim cannot provide the strict, coherent
# state tuples consumed by install, recovery and uninstall transactions.
mock_unit=rr-os-matrix-mock.service
install -m 644 /dev/null "$RR_MOCK_SYSTEMD_UNIT_DIR/$mock_unit"
test "$(systemctl show --property=LoadState --value "$mock_unit")" = loaded
test "$(systemctl show -p ActiveState --value "$mock_unit")" = inactive
test "$(systemctl show --property=UnitFileState --value "$mock_unit")" = disabled
systemctl enable --now "$mock_unit"
systemctl is-active --quiet "$mock_unit"
systemctl is-enabled --quiet "$mock_unit"
test "$(systemctl show -p ActiveState --value "$mock_unit")" = active
test "$(systemctl show -p UnitFileState --value "$mock_unit")" = enabled
systemctl disable --now "$mock_unit"
test "$(systemctl show -p ActiveState --value "$mock_unit")" = inactive
test "$(systemctl show -p UnitFileState --value "$mock_unit")" = disabled
rm -f -- "$RR_MOCK_SYSTEMD_UNIT_DIR/$mock_unit"
test "$(systemctl show -p LoadState --value "$mock_unit")" = not-found
test "$(systemctl show -p UnitFileState --value "$mock_unit")" = not-found

# Load only the installer's declarations and prove that the matrix shim
# satisfies the same fail-closed effective-unit identity gate used during the
# first snapshot.  This catches drift whenever that production gate adds a
# systemd property, before the smoke test reports the less specific backup
# cancellation error.
(
    # shellcheck disable=SC1090
    source <(awk '/^rr_prepare_recovery_runtime\(\)/ { exit } { print }' \
        scripts/install-core.sh)
    RR_UPDATE_SYSTEMD_DIR="$RR_MOCK_SYSTEMD_UNIT_DIR"
    RR_UPDATE_RECOVERY_UNIT_FILE="${RR_UPDATE_SYSTEMD_DIR}/rr-update-recovery.service"
    rr_render_update_recovery_unit > "$RR_UPDATE_RECOVERY_UNIT_FILE"
    chmod 644 "$RR_UPDATE_RECOVERY_UNIT_FILE"
    rr_update_recovery_effective_identity_is_exact
    rm -f -- "$RR_UPDATE_RECOVERY_UNIT_FILE"
)
if [ "${RR_OS_MATRIX_SYSTEMCTL_SELF_TEST_ONLY:-0}" = 1 ]; then
    echo "OS matrix systemctl shim self-test passed"
    exit 0
fi

# True clean runtime install, then a second in-place hot update.  No node
# configuration exists in the container, so post-update correctly avoids
# touching unrelated services while still exercising download-independent
# bundle verification, snapshot, atomic runtime switch and guard deployment.
RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"
test -x /usr/local/sbin/rr-update-recover
test -x /usr/local/sbin/rr-update-external-state
test -s /usr/local/lib/rr/modules/61-update-guard.sh
test -x /usr/local/lib/rr/scripts/naive-cert-hook.sh
test -x /usr/local/lib/rr/scripts/update-external-state.py
test -s /usr/local/lib/rr/nexus/rr_nexus_lib/security.py
test -s /usr/local/lib/rr/nexus/static/admin.js

# A committed first install must be able to roll back to a genuinely clean
# machine, not merely delete the launcher and leave an orphaned runtime.
/usr/local/sbin/rr-update-recover rollback
test ! -e /usr/local/bin/rr
test ! -e /usr/local/lib/rr
test ! -e /usr/local/sbin/rr-update-recover
test ! -e /usr/local/sbin/rr-update-external-state
test ! -e /var/lib/rr-update
RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade

first_manifest=$(sha256sum /usr/local/lib/rr/manifest.sha256 | awk '{print $1}')
# Exercise the catchable failure window after the old runtime was moved but
# before the candidate became live.  This is distinct from SIGKILL recovery:
# the installer's EXIT rollback itself must restore the only old copy.
if RR_TEST_FAULTS=1 RR_TEST_FAIL_PHASE=old_runtime_moved \
   RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
   RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
   bash scripts/install-core.sh --upgrade; then
    echo "catchable old-runtime-moved fault unexpectedly succeeded" >&2
    exit 1
fi
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"
test "$(sha256sum /usr/local/lib/rr/manifest.sha256 | awk '{print $1}')" = "$first_manifest"
test ! -e /var/lib/rr-update/active

# Simulate an uncatchable power-loss window after the old runtime was moved.
if RR_TEST_FAULTS=1 RR_TEST_CRASH_PHASE=old_runtime_moved \
   RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
   RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
   bash scripts/install-core.sh --upgrade; then
    echo "fault injection unexpectedly succeeded" >&2
    exit 1
fi
/usr/local/sbin/rr-update-recover recover
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"

RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade
test "$(sha256sum /usr/local/lib/rr/manifest.sha256 | awk '{print $1}')" = "$first_manifest"

# Simulate power loss after the new runtime is visible but before migration.
if RR_TEST_FAULTS=1 RR_TEST_CRASH_PHASE=runtime_swapped \
   RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
   RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
   bash scripts/install-core.sh --upgrade; then
    echo "runtime-swap fault injection unexpectedly succeeded" >&2
    exit 1
fi
/usr/local/sbin/rr-update-recover recover
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"

RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade

# The previous committed transaction is deliberately retained.  Prove the
# one-command manual rollback works and leaves a loadable runtime.
/usr/local/sbin/rr-update-recover rollback
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"

# Exercise the user-facing complete uninstall in the disposable container.
printf 'y\n' | bash -c '
  for module_file in /usr/local/lib/rr/modules/*.sh; do
    # shellcheck disable=SC1090
    source "$module_file"
  done
  uninstall_all
'
test ! -e /usr/local/bin/rr
test ! -e /usr/local/lib/rr
test ! -e /usr/local/sbin/rr-update-recover
test ! -e /usr/local/sbin/rr-update-external-state

echo "OS matrix smoke passed: $(. /etc/os-release; printf '%s %s' "$ID" "$VERSION_ID")"
