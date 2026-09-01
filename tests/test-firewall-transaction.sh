#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# This suite deliberately injects indeterminate firewall outcomes.  Those
# paths publish a durable quarantine and systemd guard, so every related path
# and every systemctl operation must be redirected before the production
# modules are sourced.  A regression must fail the suite, never mutate the
# host that happens to execute it.
RR_FIREWALL_TEST_ROOT=$(mktemp -d /run/rr-firewall-test.XXXXXX)
export TMPDIR="$RR_FIREWALL_TEST_ROOT/tmp"
export RR_FIREWALL_QUARANTINE_DIR="$RR_FIREWALL_TEST_ROOT/quarantine"
export RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/firewall-quarantine"
export RR_FIREWALL_SYSTEMD_DIR="$RR_FIREWALL_TEST_ROOT/systemd"
export RR_FIREWALL_GUARD_SCRIPT="$RR_FIREWALL_TEST_ROOT/bin/rr-firewall-quarantine-guard"
export RR_FIREWALL_LOCK_FILE="$RR_FIREWALL_TEST_ROOT/locks/firewall.lock"
export RR_FIREWALL_TEST_SYSTEMCTL_LOG="$RR_FIREWALL_TEST_ROOT/systemctl.calls"
mkdir -p "$TMPDIR" "$RR_FIREWALL_QUARANTINE_DIR" \
    "$RR_FIREWALL_SYSTEMD_DIR" "$(dirname "$RR_FIREWALL_GUARD_SCRIPT")" \
    "$(dirname "$RR_FIREWALL_LOCK_FILE")" \
    "$RR_FIREWALL_TEST_ROOT/systemctl-state/active" \
    "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled"
chmod 700 "$RR_FIREWALL_QUARANTINE_DIR" \
    "$(dirname "$RR_FIREWALL_GUARD_SCRIPT")" \
    "$(dirname "$RR_FIREWALL_LOCK_FILE")"
chmod 755 "$RR_FIREWALL_SYSTEMD_DIR"
: > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"

RR_FIREWALL_HOST_PATHS=(
    /var/lib/rr-vps/firewall-quarantine
    /var/lib/rr-vps/firewall-evidence
    /usr/local/sbin/rr-firewall-quarantine-guard
    /etc/systemd/system/rr-firewall-quarantine-guard.service
    /etc/systemd/system/rr-firewall-quarantine-guard.path
    /etc/systemd/system/rr-firewall-quarantine-guard.timer
    /etc/systemd/system/argo-rr-health.service.d/zzzzz-rr-firewall-quarantine.conf
    /etc/systemd/system/rr-subscription.service.d/zzzzz-rr-firewall-quarantine.conf
    /etc/systemd/system/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf
    /etc/systemd/system/rr-nexus.service.d/zzzzz-rr-firewall-quarantine.conf
)
RR_FIREWALL_PRODUCTION_LOCK=/run/rr-vps/locks/firewall.lock
RR_FIREWALL_PRODUCTION_LOCK_BEFORE="$RR_FIREWALL_TEST_ROOT/production-lock.before"
RR_FIREWALL_PRODUCTION_LOCK_AFTER="$RR_FIREWALL_TEST_ROOT/production-lock.after"

snapshot_firewall_production_lock() {
    local output="$1" path="$RR_FIREWALL_PRODUCTION_LOCK" metadata="" digest=""
    if [ -L "$path" ]; then
        printf 'symlink|%s|%s\n' \
            "$(stat -c '%d:%i:%u:%g:%a:%h:%s:%Y:%Z' -- "$path")" \
            "$(readlink -- "$path")" > "$output"
    elif [ -e "$path" ]; then
        metadata=$(stat -c '%F:%d:%i:%u:%g:%a:%h:%s:%Y:%Z' -- "$path") || \
            return 1
        digest=-
        [ -f "$path" ] && digest=$(sha256sum -- "$path" | awk '{print $1}')
        printf 'present|%s|%s\n' "$metadata" "$digest" > "$output"
    else
        printf '%s\n' absent > "$output"
    fi
}

assert_firewall_host_paths_absent() {
    local path=""
    for path in "${RR_FIREWALL_HOST_PATHS[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            printf 'FAIL: firewall test host path exists: %s\n' "$path" >&2
            return 1
        fi
    done
}

cleanup_firewall_test() {
    local status=$? path=""
    trap - EXIT HUP INT TERM
    for path in "${RR_FIREWALL_HOST_PATHS[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            printf 'FAIL: firewall test touched host path: %s\n' "$path" >&2
            status=1
        fi
    done
    if ! snapshot_firewall_production_lock "$RR_FIREWALL_PRODUCTION_LOCK_AFTER" || \
       ! cmp -s -- "$RR_FIREWALL_PRODUCTION_LOCK_BEFORE" \
            "$RR_FIREWALL_PRODUCTION_LOCK_AFTER"; then
        printf 'FAIL: firewall test changed the production firewall lock.\n' >&2
        status=1
    fi
    rm -rf -- "$RR_FIREWALL_TEST_ROOT"
    exit "$status"
}
trap cleanup_firewall_test EXIT HUP INT TERM
snapshot_firewall_production_lock "$RR_FIREWALL_PRODUCTION_LOCK_BEFORE"
assert_firewall_host_paths_absent || exit 1

runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' modules/00-runtime.sh)
eval "$runtime_constants"
RR_LIB_DIR="$RR_FIREWALL_TEST_ROOT/lib/rr"
SUB_ROOT="$RR_FIREWALL_TEST_ROOT/subscriptions"
SINGBOX_BIN="$RR_FIREWALL_TEST_ROOT/bin/sing-box"
SUB_PID_FILE="$RR_FIREWALL_TEST_ROOT/run/subscription.pid"
SUB_BIND_STATE_FILE="$RR_FIREWALL_TEST_ROOT/run/subscription.bind"
CONFIG_FILE="$RR_FIREWALL_TEST_ROOT/config"
mkdir -p "$RR_LIB_DIR/nexus" "$SUB_ROOT"
printf '%s\n' '# isolated firewall transaction fixture' > "$CONFIG_FILE"
# shellcheck disable=SC1091
source modules/10-system.sh
# shellcheck disable=SC1091
source modules/30-singbox.sh
# shellcheck disable=SC1091
source modules/55-resilience.sh
# shellcheck disable=SC1091
source modules/70-protocols.sh
RR_REAL_UFW_BACKEND_STATE=$(declare -f rr_ufw_backend_state)
RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE=""
RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY=""
RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE=""

# The production entrypoint sources modules/20-config.sh before the firewall
# writers.  This focused suite does not need that module's UI/config surface,
# but the pre-write crash gate must still be able to prove the mocked runtime
# inactive.
# Never let this fault-injection suite enumerate, signal, or launch host
# runtimes.  Individual service-state cases override these deterministic mocks
# inside their own subshells.
managed_singbox_running() { return 1; }
stop_singbox_instances() { return 0; }
start_singbox_instances() { return 0; }
subscription_server_running() { return 1; }
stop_subscription_servers() { return 0; }
start_subscription_server() { return 0; }
is_valid_domain() {
    local value="${1:-}" label=""
    local -a labels=()
    [ -n "$value" ] && [ "${#value}" -le 253 ] && \
        [[ "$value" != .* && "$value" != *. && "$value" == *.* ]] || return 1
    IFS=. read -r -a labels <<< "$value"
    [ "${#labels[@]}" -ge 2 ] || return 1
    for label in "${labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] && \
            [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || \
            return 1
    done
    label="${labels[${#labels[@]}-1]}"
    [[ "$label" =~ ^[A-Za-z]{2,63}$ || \
       "$label" =~ ^xn--[A-Za-z0-9-]{2,59}$ ]]
}

systemctl() {
    local invocation="$*" operation="${1:-}" property="" unit="" path=""
    local with_now=false
    printf '%s\n' "$invocation" >> "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
    shift || true
    case "$operation" in
        --version)
            printf '%s\n' 'systemd 255 (rr-firewall-test)'
            ;;
        daemon-reload) return 0 ;;
        enable)
            if [ "${1:-}" = --now ]; then
                with_now=true
                shift
            fi
            for unit in "$@"; do
                : > "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled/$unit"
                if [ "$with_now" = true ]; then
                    : > "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit"
                fi
            done
            ;;
        disable)
            if [ "${1:-}" = --now ]; then
                with_now=true
                shift
            fi
            for unit in "$@"; do
                rm -f -- "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled/$unit"
                if [ "$with_now" = true ]; then
                    rm -f -- "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit"
                fi
            done
            ;;
        start|restart)
            [ "${1:-}" != --no-block ] || shift
            for unit in "$@"; do
                case "$unit" in
                    sing-box.service|rr-nexus.service|rr-subscription.service|\
                    argo-rr-health.service)
                        if [ -e "$RR_FIREWALL_QUARANTINE_FILE" ] || \
                           [ -L "$RR_FIREWALL_QUARANTINE_FILE" ]; then
                            rm -f -- \
                                "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit"
                            return 1
                        fi
                        ;;
                esac
                : > "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit"
            done
            ;;
        stop)
            [ "${1:-}" != --no-block ] || shift
            for unit in "$@"; do
                rm -f -- "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit"
            done
            ;;
        is-active)
            [ "${1:-}" != --quiet ] || shift
            [ -f "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/${1:-}" ]
            ;;
        is-enabled)
            [ "${1:-}" != --quiet ] || shift
            [ -f "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled/${1:-}" ]
            ;;
        show)
            case "${1:-}" in
                --property=*) property="${1#--property=}"; shift ;;
                -p) property="${2:-}"; shift 2 ;;
                *) return 2 ;;
            esac
            [ "${1:-}" != --value ] || shift
            unit="${1:-}"
            if [ -n "${RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY:-}" ] && \
               [ "$property" = "$RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY" ]; then
                printf '%s\n' "$RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE"
                return 0
            fi
            case "$property" in
                FragmentPath)
                    path="$RR_FIREWALL_SYSTEMD_DIR/$unit"
                    [ -f "$path" ] || return 0
                    printf '%s\n' "$path"
                    ;;
                DropInPaths)
                    if [ -d "$RR_FIREWALL_SYSTEMD_DIR/${unit}.d" ]; then
                        find "$RR_FIREWALL_SYSTEMD_DIR/${unit}.d" -maxdepth 1 \
                            -type f -name '*.conf' -print 2>/dev/null | sort | \
                            paste -sd ' ' -
                    fi
                    ;;
                ExecCondition)
                    path="$RR_FIREWALL_SYSTEMD_DIR/${unit}.d/zzzzz-rr-firewall-quarantine.conf"
                    [ -f "$path" ] || return 0
                    if [ -n "${RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE:-}" ]; then
                        printf '%s\n' "$RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE"
                        return 0
                    fi
                    if [ -f "$RR_FIREWALL_SYSTEMD_DIR/${unit}.d/zzzz-rr-restore-gate.conf" ]; then
                        printf '%s' '{ path=/bin/sh ; argv[]=/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate ; ignore_errors=no } '
                    fi
                    printf '{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e %s ; ignore_errors=no } { path=/usr/bin/test ; argv[]=/usr/bin/test ! -L %s ; ignore_errors=no }\n' \
                        "$RR_FIREWALL_QUARANTINE_FILE" "$RR_FIREWALL_QUARANTINE_FILE"
                    ;;
                User|Group)
                    printf 'root\n'
                    ;;
                DynamicUser|PrivateUsers|PrivateMounts)
                    printf 'no\n'
                    ;;
                ProtectSystem)
                    printf 'no\n'
                    ;;
                ProtectHome)
                    if [ "$unit" = rr-nexus.service ]; then
                        printf 'yes\n'
                    else
                        printf 'no\n'
                    fi
                    ;;
                RootEphemeral)
                    printf 'no\n'
                    ;;
                RootDirectory|RootImage|MountImages|ExtensionImages|\
                ExtensionDirectories|TemporaryFileSystem|BindPaths|\
                BindReadOnlyPaths|InaccessiblePaths|JoinsNamespaceOf|\
                ReadOnlyPaths|ReadWritePaths|Environment|EnvironmentFiles|\
                PassEnvironment|PAMName|SystemCallFilter|Conditions|Asserts)
                    printf '\n'
                    ;;
                ExecStart)
                    if [ "$unit" = rr-firewall-quarantine-guard.service ]; then
                        printf '{ path=%s ; argv[]=%s ; ignore_errors=no ; }\n' \
                            "$RR_FIREWALL_GUARD_SCRIPT" "$RR_FIREWALL_GUARD_SCRIPT"
                    else
                        return 2
                    fi
                    ;;
                ExecStartPre|ExecStartPost|ExecStop|ExecStopPost|ExecReload)
                    printf '\n'
                    ;;
                Paths)
                    [ "$unit" = rr-firewall-quarantine-guard.path ] || return 2
                    printf 'PathExists=%s\n' "$RR_FIREWALL_QUARANTINE_FILE"
                    ;;
                Triggers)
                    case "$unit" in
                        rr-firewall-quarantine-guard.path|rr-firewall-quarantine-guard.timer)
                            printf 'rr-firewall-quarantine-guard.service\n'
                            ;;
                        *) return 2 ;;
                    esac
                    ;;
                Unit)
                    case "$unit" in
                        rr-firewall-quarantine-guard.path|\
                        rr-firewall-quarantine-guard.timer)
                            printf 'rr-firewall-quarantine-guard.service\n'
                            ;;
                        *) return 2 ;;
                    esac
                    ;;
                TimersMonotonic)
                    [ "$unit" = rr-firewall-quarantine-guard.timer ] || return 2
                    printf '{ OnBootSec=2s ; } { OnUnitActiveSec=2s ; }\n'
                    ;;
                TimersCalendar)
                    [ "$unit" = rr-firewall-quarantine-guard.timer ] || return 2
                    printf '\n'
                    ;;
                AccuracyUSec)
                    [ "$unit" = rr-firewall-quarantine-guard.timer ] || return 2
                    printf '1s\n'
                    ;;
                RandomizedDelayUSec)
                    [ "$unit" = rr-firewall-quarantine-guard.timer ] || return 2
                    printf '0\n'
                    ;;
                NextElapseUSecMonotonic)
                    [ "$unit" = rr-firewall-quarantine-guard.timer ] || return 2
                    [ -f "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit" ] || \
                        return 0
                    printf '2s\n'
                    ;;
                LoadState)
                    if [ -f "$RR_FIREWALL_SYSTEMD_DIR/$unit" ]; then
                        printf 'loaded\n'
                    else
                        printf 'not-found\n'
                    fi
                    ;;
                ActiveState)
                    [ -f "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit" ] && \
                        printf 'active\n' || printf 'inactive\n'
                    ;;
                UnitFileState)
                    if [ -f "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled/$unit" ]; then
                        printf 'enabled\n'
                    elif [ "$unit" = rr-firewall-quarantine-guard.path ] || \
                         [ "$unit" = rr-firewall-quarantine-guard.timer ]; then
                        printf 'disabled\n'
                    elif [ -f "$RR_FIREWALL_SYSTEMD_DIR/$unit" ]; then
                        printf 'static\n'
                    fi
                    ;;
                *) return 2 ;;
            esac
            ;;
        *) return 2 ;;
    esac
}

reset_firewall_quarantine_mock() {
    rm -rf -- "$RR_FIREWALL_QUARANTINE_DIR" "$RR_FIREWALL_SYSTEMD_DIR" \
        "$RR_FIREWALL_GUARD_SCRIPT" "$RR_FIREWALL_TEST_ROOT/systemctl-state"
    mkdir -p "$RR_FIREWALL_QUARANTINE_DIR" "$RR_FIREWALL_SYSTEMD_DIR" \
        "$(dirname "$RR_FIREWALL_GUARD_SCRIPT")" \
        "$RR_FIREWALL_TEST_ROOT/systemctl-state/active" \
        "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled"
    chmod 700 "$RR_FIREWALL_QUARANTINE_DIR" \
        "$(dirname "$RR_FIREWALL_GUARD_SCRIPT")"
    chmod 755 "$RR_FIREWALL_SYSTEMD_DIR"
    RR_FIREWALL_INFLIGHT_ACTIVE=0
    RR_FIREWALL_INFLIGHT_OWNER_PID=""
    RR_FIREWALL_INFLIGHT_MARKER_SHA256=""
    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE=""
    RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY=""
    RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE=""
    : > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
}

prime_firewall_ingress_mock() {
    local unit=""
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service argo-rr-health.timer; do
        : > "$RR_FIREWALL_SYSTEMD_DIR/$unit"
        : > "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/$unit"
        : > "$RR_FIREWALL_TEST_ROOT/systemctl-state/enabled/$unit"
    done
}

assert_inflight_crash_is_durably_blocked() {
    local context="$1" unit="" dropin=""
    [ -f "$RR_FIREWALL_QUARANTINE_FILE" ] && \
        [ ! -L "$RR_FIREWALL_QUARANTINE_FILE" ] && \
        [ "$(head -n 1 -- "$RR_FIREWALL_QUARANTINE_FILE")" = \
            firewall-inflight-v1 ] || \
        fail "$context did not leave a canonical v1 crash journal"
    [ -d "$RR_FIREWALL_QUARANTINE_DIR/firewall-evidence" ] && \
        [ ! -L "$RR_FIREWALL_QUARANTINE_DIR/firewall-evidence" ] || \
        fail "$context lost its pre-write firewall evidence"
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.path && \
        systemctl is-active --quiet rr-firewall-quarantine-guard.path || \
        fail "$context lost the durable quarantine path watcher"
    # Inspect the state left by the killed transaction itself before invoking
    # any mock supervisor or start operation; an assertion helper must not
    # repair the exact regression it is intended to detect.
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service argo-rr-health.timer; do
        rr_firewall_managed_unit_is_disabled_inactive "$unit" || \
            fail "$context was not inactive/disabled before restart probes: $unit"
    done
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service; do
        dropin="$RR_FIREWALL_SYSTEMD_DIR/${unit}.d/zzzzz-rr-firewall-quarantine.conf"
        [ -f "$dropin" ] && [ ! -L "$dropin" ] || \
            fail "$context lost the $unit reboot gate"
        if systemctl start "$unit" >/dev/null 2>&1; then
            fail "$context marker allowed $unit to start"
        fi
    done
    # The start probes must not have weakened the supervisor's durable state.
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service argo-rr-health.timer; do
        rr_firewall_managed_unit_is_disabled_inactive "$unit" || \
            fail "$context left $unit enabled or active"
    done
}

setup_netfilter_mock() {
    reset_firewall_quarantine_mock
    MOCK_NETFILTER_ROOT=$(mktemp -d)
    printf '%s\n' '-P INPUT DROP' > "$MOCK_NETFILTER_ROOT/iptables.filter"
    : > "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' '-P INPUT DROP' > "$MOCK_NETFILTER_ROOT/ip6tables.filter"
    : > "$MOCK_NETFILTER_ROOT/ip6tables.nat"
    MOCK_FAIL_WRITE_BACKEND=""
    MOCK_SKIP_WRITE_BACKEND=""
    MOCK_KILL_AFTER_NETFILTER_WRITE_ATTEMPT=0
    MOCK_NETFILTER_WRITE_ATTEMPTS=0
    MOCK_FAIL_WRITE_SPECS=""
    MOCK_SKIP_WRITE_SPECS=""
    MOCK_NAT_WRITE_ATTEMPTS=0
    MOCK_FAIL_NAT_WRITE_SPECS=""
    MOCK_SKIP_NAT_WRITE_SPECS=""
    MOCK_NETFILTER_WRITE_LOG="$MOCK_NETFILTER_ROOT/write-calls"
    : > "$MOCK_NETFILTER_WRITE_LOG"

    mock_netfilter() {
        local backend="$1" table=filter operation="" chain="" line="" argument="" file="" temporary=""
        local position=""
        local chain_found=false
        shift
        if [ "${1:-}" = -w ]; then shift 2; fi
        if [ "${1:-}" = -t ]; then table="$2"; shift 2; fi
        operation="${1:-}"
        [ "$#" -gt 0 ] && shift
        file="$MOCK_NETFILTER_ROOT/${backend}.${table}"
        [ -f "$file" ] || return 3
        case "$operation" in
            -S)
                chain="${1:-}"
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    if [ -z "$chain" ] || [ "$(printf '%s\n' "$line" | awk '{print $2}')" = "$chain" ]; then
                        printf '%s\n' "$line"
                        chain_found=true
                    fi
                done < "$file"
                [ -z "$chain" ] || [ "$chain_found" = true ]
                ;;
            -C|-A|-I|-D)
                chain="${1:-}"
                [ -n "$chain" ] || return 2
                shift
                if [ "$operation" = -I ] && [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; then
                    position="$1"
                    shift
                fi
                line="-A $chain"
                for argument in "$@"; do line+=" $argument"; done
                case "$operation" in
                    -C) grep -Fqx -- "$line" "$file" ;;
                    -A|-I)
                        printf '%s\n' "$backend $table $operation" >> "$MOCK_NETFILTER_WRITE_LOG"
                        MOCK_NETFILTER_WRITE_ATTEMPTS=$((MOCK_NETFILTER_WRITE_ATTEMPTS + 1))
                        case " $MOCK_FAIL_WRITE_SPECS " in
                            *" $backend:$operation:$MOCK_NETFILTER_WRITE_ATTEMPTS "*) return 42 ;;
                        esac
                        if [ "$table" = nat ]; then
                            MOCK_NAT_WRITE_ATTEMPTS=$((MOCK_NAT_WRITE_ATTEMPTS + 1))
                            case " $MOCK_FAIL_NAT_WRITE_SPECS " in
                                *" $backend:$operation:$MOCK_NAT_WRITE_ATTEMPTS "*) return 42 ;;
                            esac
                        fi
                        [ "$MOCK_FAIL_WRITE_BACKEND" != "$backend" ] || return 42
                        case " $MOCK_SKIP_WRITE_SPECS " in
                            *" $backend:$operation:$MOCK_NETFILTER_WRITE_ATTEMPTS "*) return 0 ;;
                        esac
                        if [ "$table" = nat ]; then
                            case " $MOCK_SKIP_NAT_WRITE_SPECS " in
                                *" $backend:$operation:$MOCK_NAT_WRITE_ATTEMPTS "*) return 0 ;;
                            esac
                        fi
                        [ "$MOCK_SKIP_WRITE_BACKEND" != "$backend" ] || return 0
                        temporary="${file}.tmp.$$"
                        if [ "$operation" = -I ] && [ -n "$position" ]; then
                            if ! awk -v wanted="$line" -v wanted_position="$position" \
                                -v wanted_chain="$chain" '
                                BEGIN { current=0; inserted=0 }
                                {
                                    is_chain_rule=($1 == "-A" && $2 == wanted_chain)
                                    if (!inserted && is_chain_rule) {
                                        current++
                                        if (current == wanted_position) {
                                            print wanted
                                            inserted=1
                                        }
                                    } else if (!inserted && (current > 0 || wanted_position == 1) &&
                                               current + 1 == wanted_position &&
                                               $1 == "-A" && $2 != wanted_chain) {
                                        print wanted
                                        inserted=1
                                    }
                                    print
                                }
                                END {
                                    if (!inserted && current + 1 == wanted_position) {
                                        print wanted
                                        inserted=1
                                    }
                                    if (!inserted) exit 1
                                }
                            ' "$file" > "$temporary"; then
                                rm -f "$temporary"
                                return 1
                            fi
                        elif [ "$operation" = -I ]; then
                            { printf '%s\n' "$line"; cat "$file"; } > "$temporary"
                        else
                            { cat "$file"; printf '%s\n' "$line"; } > "$temporary"
                        fi
                        mv -f "$temporary" "$file"
                        if [ "${MOCK_KILL_AFTER_NETFILTER_WRITE_ATTEMPT:-0}" = \
                             "$MOCK_NETFILTER_WRITE_ATTEMPTS" ]; then
                            sync -f "$file"
                            kill -KILL "$BASHPID"
                        fi
                        ;;
                    -D)
                        printf '%s\n' "$backend $table $operation" >> "$MOCK_NETFILTER_WRITE_LOG"
                        MOCK_NETFILTER_WRITE_ATTEMPTS=$((MOCK_NETFILTER_WRITE_ATTEMPTS + 1))
                        case " $MOCK_FAIL_WRITE_SPECS " in
                            *" $backend:$operation:$MOCK_NETFILTER_WRITE_ATTEMPTS "*) return 42 ;;
                        esac
                        if [ "$table" = nat ]; then
                            MOCK_NAT_WRITE_ATTEMPTS=$((MOCK_NAT_WRITE_ATTEMPTS + 1))
                            case " $MOCK_FAIL_NAT_WRITE_SPECS " in
                                *" $backend:$operation:$MOCK_NAT_WRITE_ATTEMPTS "*) return 42 ;;
                            esac
                            case " $MOCK_SKIP_NAT_WRITE_SPECS " in
                                *" $backend:$operation:$MOCK_NAT_WRITE_ATTEMPTS "*) return 0 ;;
                            esac
                        fi
                        [ "$MOCK_FAIL_WRITE_BACKEND" != "$backend" ] || return 42
                        temporary="${file}.tmp.$$"
                        awk -v wanted="$line" '
                            !removed && $0 == wanted { removed=1; next }
                            { print }
                            END { if (!removed) exit 1 }
                        ' "$file" > "$temporary" || { rm -f "$temporary"; return 1; }
                        mv -f "$temporary" "$file"
                        if [ "${MOCK_KILL_AFTER_NETFILTER_WRITE_ATTEMPT:-0}" = \
                             "$MOCK_NETFILTER_WRITE_ATTEMPTS" ]; then
                            sync -f "$file"
                            kill -KILL "$BASHPID"
                        fi
                        ;;
                esac
                ;;
            *) return 2 ;;
        esac
    }
    iptables() { mock_netfilter iptables "$@"; }
    ip6tables() { mock_netfilter ip6tables "$@"; }
    netfilter-persistent() { return 0; }
    # Netfilter-only cases must not consume the runner's saved inactive UFW
    # program. Keep the fixture empty and reject any unexpected UFW writer.
    ufw() {
        if [ "$#" -eq 1 ] && [ "$1" = status ]; then
            printf '%s\n' 'Status: inactive'
            return 0
        fi
        if [ "$#" -eq 2 ] && [ "$1" = show ] && [ "$2" = added ]; then
            printf '%s\n' \
                "Added user rules (see 'ufw status' for running firewall):"
            return 0
        fi
        return 2
    }
    rr_ufw_backend_state() { return 1; }
    rr_netfilter_backend_state() {
        case "$1" in
            iptables|ip6tables) return 0 ;;
            *) return 1 ;;
        esac
    }
}

setup_ufw_mock() {
    MOCK_UFW_ROOT=$(mktemp -d)
    MOCK_UFW_RULES="$MOCK_UFW_ROOT/rules"
    : > "$MOCK_UFW_RULES"
    MOCK_UFW_ACTIVE=true
    MOCK_UFW_IPV6=true
    MOCK_UFW_FAIL_WRITE=false
    MOCK_UFW_SKIP_WRITE=false
    MOCK_UFW_WRITE_ATTEMPTS=0
    MOCK_UFW_FAIL_WRITE_SPECS=""
    MOCK_UFW_SKIP_WRITE_SPECS=""
    MOCK_UFW_WRITE_LOG="$MOCK_UFW_ROOT/write-calls"
    : > "$MOCK_UFW_WRITE_LOG"
    : > "$MOCK_UFW_ROOT/iptables.compiled"
    : > "$MOCK_UFW_ROOT/ip6tables.compiled"

    ufw() {
        local operation="" action="" rule="" marker="" line="" temporary="" position=""
        if [ "${1:-}" = status ]; then
            if [ "$MOCK_UFW_ACTIVE" = true ]; then
                printf '%s\n' 'Status: active'
                while IFS='|' read -r action rule marker; do
                    [ -n "$action" ] || continue
                    printf '%s %s Anywhere # %s\n' "$rule" "${action^^}" "$marker"
                    if [ "$MOCK_UFW_IPV6" = true ]; then
                        printf '%s (v6) %s Anywhere (v6) # %s\n' \
                            "$rule" "${action^^}" "$marker"
                    fi
                done < "$MOCK_UFW_RULES"
            else
                printf '%s\n' 'Status: inactive'
            fi
            return 0
        fi
        if [ "${1:-}" = show ] && [ "${2:-}" = added ]; then
            printf '%s\n' "Added user rules (see 'ufw status' for running firewall):"
            while IFS='|' read -r action rule marker; do
                [ -n "$action" ] || continue
                printf "ufw %s %s comment '%s'\n" "$action" "$rule" "$marker"
            done < "$MOCK_UFW_RULES"
            return 0
        fi
        # Real UFW rejects --force for allow/deny/delete rule operations.
        # Keep the mock strict so regressions cannot pass only in CI.
        [ "${1:-}" != --force ] || return 2
        operation=add
        if [ "${1:-}" = delete ]; then
            operation=delete
            shift
        elif [ "${1:-}" = insert ]; then
            operation=insert
            position="${2:-}"
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 2
            shift 2
        fi
        action="${1:-}"; rule="${2:-}"
        [ "${3:-}" = comment ] || return 2
        marker="${4:-}"
        line="${action}|${rule}|${marker}"
        printf '%s\n' "$operation $line" >> "$MOCK_UFW_WRITE_LOG"
        MOCK_UFW_WRITE_ATTEMPTS=$((MOCK_UFW_WRITE_ATTEMPTS + 1))
        case " $MOCK_UFW_FAIL_WRITE_SPECS " in
            *" $operation:$MOCK_UFW_WRITE_ATTEMPTS "*) return 42 ;;
        esac
        [ "$MOCK_UFW_FAIL_WRITE" = false ] || return 42
        case " $MOCK_UFW_SKIP_WRITE_SPECS " in
            *" $operation:$MOCK_UFW_WRITE_ATTEMPTS "*) return 0 ;;
        esac
        [ "$MOCK_UFW_SKIP_WRITE" = false ] || return 0
        if [ "$operation" = add ]; then
            grep -Fqx -- "$line" "$MOCK_UFW_RULES" || printf '%s\n' "$line" >> "$MOCK_UFW_RULES"
            sync_mock_ufw_filter_program
            return 0
        fi
        temporary="${MOCK_UFW_RULES}.tmp.$$"
        if [ "$operation" = insert ]; then
            if ! awk -v wanted="$line" -v wanted_position="$position" '
                BEGIN { current=0; inserted=0 }
                {
                    current++
                    if (!inserted && current == wanted_position) {
                        print wanted
                        inserted=1
                    }
                    print
                }
                END {
                    if (!inserted && current + 1 == wanted_position) {
                        print wanted
                        inserted=1
                    }
                    if (!inserted) exit 1
                }
            ' "$MOCK_UFW_RULES" > "$temporary"; then
                rm -f "$temporary"
                return 1
            fi
            mv -f "$temporary" "$MOCK_UFW_RULES"
            sync_mock_ufw_filter_program
            return 0
        fi
        awk -v wanted="$line" '
            !removed && $0 == wanted { removed=1; next }
            { print }
            END { if (!removed) exit 1 }
        ' "$MOCK_UFW_RULES" > "$temporary" || { rm -f "$temporary"; return 1; }
        mv -f "$temporary" "$MOCK_UFW_RULES"
        sync_mock_ufw_filter_program
    }
    rr_ufw_backend_state() {
        [ "$MOCK_UFW_ACTIVE" = true ]
    }
    rr_netfilter_backend_state() {
        case "$1" in
            iptables|ip6tables)
                [ -n "${MOCK_NETFILTER_ROOT:-}" ] && \
                    [ -d "$MOCK_NETFILTER_ROOT" ]
                ;;
            *) return 1 ;;
        esac
    }
    if [ -n "${MOCK_NETFILTER_ROOT:-}" ] && [ -d "$MOCK_NETFILTER_ROOT" ]; then
        write_mock_ufw_filter_program iptables
        write_mock_ufw_filter_program ip6tables
    fi
}

setup_ipv6_proc_mock() {
    local all_value="$1" default_value="$2" lo_value="$3" eth0_value="$4"
    MOCK_PROC_ROOT=$(mktemp -d)
    RR_PROC_ROOT="$MOCK_PROC_ROOT"
    mkdir -p \
        "$MOCK_PROC_ROOT/sys/net/ipv6/conf/all" \
        "$MOCK_PROC_ROOT/sys/net/ipv6/conf/default" \
        "$MOCK_PROC_ROOT/sys/net/ipv6/conf/lo" \
        "$MOCK_PROC_ROOT/sys/net/ipv6/conf/eth0"
    printf '%s\n' "$all_value" \
        > "$MOCK_PROC_ROOT/sys/net/ipv6/conf/all/disable_ipv6"
    printf '%s\n' "$default_value" \
        > "$MOCK_PROC_ROOT/sys/net/ipv6/conf/default/disable_ipv6"
    printf '%s\n' "$lo_value" \
        > "$MOCK_PROC_ROOT/sys/net/ipv6/conf/lo/disable_ipv6"
    printf '%s\n' "$eth0_value" \
        > "$MOCK_PROC_ROOT/sys/net/ipv6/conf/eth0/disable_ipv6"
}

force_missing_persistence_backend() {
    unset -f netfilter-persistent 2>/dev/null || true
    rr_firewall_persistence_backend_available() { return 1; }
}

assert_rule() {
    local file="$1" expected="$2"
    grep -Fqx -- "$expected" "$file" || fail "missing rule in $file: $expected"
}

assert_no_match() {
    local file="$1" pattern="$2"
    if grep -Fq -- "$pattern" "$file"; then
        fail "unexpected rule in $file: $pattern"
    fi
}

use_candidate_config() {
    VM_TLS_ENABLED=false
    SUB_ACCESS_MODE="${TEST_SUB_ACCESS_MODE:-local}"
    SUB_PORT="${TEST_SUB_PORT:-15556}"
    SUB_DOMAIN="${TEST_SUB_DOMAIN:-subscriptions.example.com}"
    VL_ENABLED="${TEST_VL_ENABLED:-false}"
    VL_PORT="${TEST_VL_PORT:-24443}"
    HY2_ENABLED="${TEST_HY2_ENABLED:-false}"
    HY2_PORT="${TEST_HY2_PORT:-24444}"
    HY2_HOP_PORTS="${TEST_HY2_HOP_PORTS:-}"
    TU5_ENABLED="${TEST_TU5_ENABLED:-false}"
    TU5_PORT="${TEST_TU5_PORT:-24445}"
    TU5_HOP_PORTS="${TEST_TU5_HOP_PORTS:-}"
    AN_ENABLED=false
    NAIVE_ENABLED=false
    NEXUS_CONFIG_FILE="${TEST_NEXUS_CONFIG_FILE:-/nonexistent/rr-nexus.json}"
}

# Durable in-flight evidence binds the pre-write firewall snapshot to the
# current configuration.  The behavioral suite uses one canonical isolated
# configuration unless a case deliberately overrides this loader.
use_candidate_config
load_config_with_defaults() {
    return 0
}

test_install_hop_rules() {
    local label="$1" main_port="$2" spec_list="$3" spec=""
    local required_ok=true backend=""
    local -a specs=()
    IFS=',' read -r -a specs <<< "$spec_list"
    for spec in "${specs[@]}"; do
        for backend in iptables ip6tables; do
            if ! "$backend" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j REDIRECT \
                --to-ports "$main_port" >/dev/null 2>&1; then
                if ! "$backend" -w 5 -t nat -A PREROUTING -p udp \
                    --dport "$spec" -m comment --comment "argo-rr-${label}" \
                    -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1; then
                    [ "$backend" != iptables ] || required_ok=false
                fi
            fi
        done
    done
    [ "$required_ok" = true ]
}

test_validate_hop_rules() {
    local label="$1" main_port="$2" spec_list="$3" spec=""
    local -a specs=()
    IFS=',' read -r -a specs <<< "$spec_list"
    for spec in "${specs[@]}"; do
        iptables -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
            -m comment --comment "argo-rr-${label}" -j REDIRECT \
            --to-ports "$main_port" >/dev/null 2>&1 || return 1
    done
}

write_mock_ufw_filter_program() {
    local backend="$1" extra="${2:-}" prefix=ufw
    if [ "$backend" = ip6tables ]; then
        prefix=ufw6
        extra="${extra//ufw-/ufw6-}"
    fi
    {
        printf '%s\n' \
            '-P INPUT DROP' \
            "-N ${prefix}-before-input" \
            "-N ${prefix}-user-input" \
            "-N ${prefix}-user-output" \
            "-N ${prefix}-user-forward" \
            "-A INPUT -j ${prefix}-before-input" \
            "-A INPUT -j ${prefix}-user-input" \
            "-A ${prefix}-before-input -i lo -j ACCEPT" \
            "-A ${prefix}-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        [ -z "$extra" ] || printf '%s\n' "$extra"
    } > "$MOCK_NETFILTER_ROOT/${backend}.filter"
    if [ -n "${MOCK_UFW_ROOT:-}" ] && [ -d "$MOCK_UFW_ROOT" ]; then
        : > "$MOCK_UFW_ROOT/${backend}.compiled"
    fi
}

sync_mock_ufw_filter_program() {
    local backend="" prefix="" action="" rule="" marker="" target=""
    local compiled="" temporary=""
    [ -n "${MOCK_NETFILTER_ROOT:-}" ] && [ -d "$MOCK_NETFILTER_ROOT" ] || return 0
    for backend in iptables ip6tables; do
        compiled="$MOCK_UFW_ROOT/${backend}.compiled"
        [ -f "$compiled" ] || : > "$compiled"
        prefix=ufw
        [ "$backend" != ip6tables ] || prefix=ufw6
        # UFW 0.36 reloads the complete user program after any add/delete.
        # Faithfully flush all three user chains, including untracked custom
        # live rules, before rebuilding only persistent `ufw show added` state.
        temporary="$MOCK_NETFILTER_ROOT/${backend}.filter.tmp.$$"
        awk -v prefix="$prefix" '
            $1 == "-A" && ($2 == prefix "-user-input" ||
                            $2 == prefix "-user-output" ||
                            $2 == prefix "-user-forward") { next }
            { print }
        ' "$MOCK_NETFILTER_ROOT/${backend}.filter" > "$temporary"
        mv -f "$temporary" "$MOCK_NETFILTER_ROOT/${backend}.filter"
        : > "$compiled"
        [ "$backend" != ip6tables ] || [ "${MOCK_UFW_IPV6:-true}" = true ] || continue
        while IFS='|' read -r action rule marker; do
            [[ "$rule" =~ ^[1-9][0-9]{0,4}/(tcp|udp)$ ]] || continue
            case "$action" in
                allow) target=ACCEPT ;;
                deny) target=DROP ;;
                reject) target=REJECT ;;
                *) continue ;;
            esac
            printf '%s\n' \
                "-A ${prefix}-user-input -p ${BASH_REMATCH[1]} -m ${BASH_REMATCH[1]} --dport ${rule%/*} -j ${target}" \
                | tee -a "$MOCK_NETFILTER_ROOT/${backend}.filter" >> "$compiled"
        done < "$MOCK_UFW_RULES"
    done
}

printf '%s\n' '[0/9] global firewall lock safety, reentrancy, and concurrency barrier'
(
    lock_test_root=$(mktemp -d)
    trap 'rm -rf "$lock_test_root"' EXIT
    : > "$lock_test_root/file"
    chmod 600 "$lock_test_root/file"
    rr_firewall_lock_file_is_safe "$lock_test_root/file" || \
        fail 'safe root-owned lock fixture was rejected'
    ln "$lock_test_root/file" "$lock_test_root/hardlink"
    if rr_firewall_lock_file_is_safe "$lock_test_root/file"; then
        fail 'multiply linked firewall lock was accepted'
    fi
    rm -f "$lock_test_root/hardlink"
    chmod 666 "$lock_test_root/file"
    if rr_firewall_lock_file_is_safe "$lock_test_root/file"; then
        fail 'group/other-writable firewall lock was accepted'
    fi
    chmod 600 "$lock_test_root/file"
    ln -s file "$lock_test_root/symlink"
    if rr_firewall_lock_file_is_safe "$lock_test_root/symlink"; then
        fail 'symlink firewall lock was accepted'
    fi
    chmod 777 "$lock_test_root"
    if rr_firewall_lock_directory_is_safe "$lock_test_root"; then
        fail 'writable firewall lock directory was accepted'
    fi
    chmod 700 "$lock_test_root"
    canonical_test_lock="$RR_FIREWALL_LOCK_FILE"
    mkdir -m 777 -- "$lock_test_root/world-writable"
    RR_FIREWALL_LOCK_FILE="$lock_test_root/world-writable/firewall.lock"
    if rr_firewall_lock_prepare; then
        fail 'override accepted a world-writable firewall lock parent'
    fi
    RR_FIREWALL_LOCK_FILE="$RR_FIREWALL_TEST_ROOT/locks/not-the-fixed-name"
    if rr_firewall_lock_prepare; then
        fail 'override accepted a non-canonical firewall lock basename'
    fi
    RR_FIREWALL_LOCK_FILE="$canonical_test_lock"

    rr_firewall_lock_acquire || fail 'could not acquire global firewall lock'
    rr_firewall_lock_is_held || fail 'lock owner was not recognized'
    rr_firewall_lock_acquire || fail 'same-owner reentrant acquire failed'
    [ "$RR_FIREWALL_LOCK_DEPTH" -eq 2 ] || fail 'reentrant lock depth was not recorded'
    (
        : > "$lock_test_root/contender-started"
        rr_firewall_lock_acquire || exit 1
        : > "$lock_test_root/contender-acquired"
        rr_firewall_lock_release
    ) &
    contender_pid=$!
    for _ in {1..100}; do
        [ -f "$lock_test_root/contender-started" ] && break
        sleep 0.01
    done
    [ -f "$lock_test_root/contender-started" ] || fail 'lock contender did not start'
    sleep 0.1
    [ ! -e "$lock_test_root/contender-acquired" ] || \
        fail 'child reused an inherited firewall lock description'
    rr_firewall_lock_release || fail 'first reentrant release failed'
    sleep 0.1
    [ ! -e "$lock_test_root/contender-acquired" ] || \
        fail 'partial reentrant release unlocked the transaction domain'
    rr_firewall_lock_release || fail 'final firewall lock release failed'
    wait "$contender_pid" || fail 'serialized lock contender failed'
    [ -f "$lock_test_root/contender-acquired" ] || \
        fail 'lock contender did not enter after final release'
)
(
    lock_test_root=$(mktemp -d)
    trap 'rm -rf "$lock_test_root"' EXIT
    contender_pids=()
    rr_restore_recover_active_locked() {
        local barrier="" pid=""
        rr_firewall_lock_is_held || fail 'recovery callback entered without firewall lock'
        for barrier in after-replay during-migration late-verify before-terminal; do
            (
                : > "$lock_test_root/${barrier}.started"
                rr_firewall_lock_acquire || exit 1
                : > "$lock_test_root/${barrier}.acquired"
                rr_firewall_lock_release
            ) &
            pid=$!
            contender_pids+=("$pid")
            for _ in {1..100}; do
                [ -f "$lock_test_root/${barrier}.started" ] && break
                sleep 0.01
            done
            [ -f "$lock_test_root/${barrier}.started" ] ||
                fail "recovery contender did not reach $barrier"
            sleep 0.05
            [ ! -e "$lock_test_root/${barrier}.acquired" ] ||
                fail "firewall lock was released at recovery barrier $barrier"
        done
    }
    rr_restore_recover_active_with_firewall_lock ||
        fail 'recovery firewall lock wrapper failed'
    for contender_pid in "${contender_pids[@]}"; do
        wait "$contender_pid" || fail 'recovery lock contender failed after release'
    done
    for barrier in after-replay during-migration late-verify before-terminal; do
        [ -f "$lock_test_root/${barrier}.acquired" ] ||
            fail "recovery contender never entered after terminal release: $barrier"
    done
)

printf '%s\n' '[0b/9] durable quarantine guard is exact, idle when clear, and symlink-safe'
(
    reset_firewall_quarantine_mock
    printf '%s\n' firewall-quarantine-v2 > "$RR_FIREWALL_QUARANTINE_FILE"
    chmod 600 "$RR_FIREWALL_QUARANTINE_FILE"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$RR_FIREWALL_GUARD_SCRIPT"
    chmod 700 "$RR_FIREWALL_GUARD_SCRIPT"
    foreign_digest=$(sha256sum -- "$RR_FIREWALL_GUARD_SCRIPT")
    : > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
    if rr_firewall_install_fail_closed_supervisor >/dev/null 2>&1; then
        fail 'foreign quarantine helper was overwritten and trusted'
    fi
    [ "$foreign_digest" = "$(sha256sum -- "$RR_FIREWALL_GUARD_SCRIPT")" ] && \
        [ -z "$(find "$RR_FIREWALL_SYSTEMD_DIR" -type f -print -quit)" ] || \
        fail 'foreign helper preflight changed the supervisor target set'
    [ ! -s "$RR_FIREWALL_TEST_SYSTEMCTL_LOG" ] || \
        fail 'foreign helper preflight reached systemctl'

    reset_firewall_quarantine_mock
    printf '%s\n' firewall-quarantine-v2 > "$RR_FIREWALL_QUARANTINE_FILE"
    chmod 600 "$RR_FIREWALL_QUARANTINE_FILE"
    foreign_service="$RR_FIREWALL_SYSTEMD_DIR/rr-firewall-quarantine-guard.service"
    printf '%s\n' '[Service]' 'ExecStart=/bin/true' > "$foreign_service"
    chmod 644 "$foreign_service"
    foreign_digest=$(sha256sum -- "$foreign_service")
    : > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
    if rr_firewall_install_fail_closed_supervisor >/dev/null 2>&1; then
        fail 'foreign quarantine service base was overwritten and trusted'
    fi
    [ "$foreign_digest" = "$(sha256sum -- "$foreign_service")" ] && \
        [ ! -e "$RR_FIREWALL_GUARD_SCRIPT" ] || \
        fail 'foreign service preflight changed a supervisor target'
    [ ! -s "$RR_FIREWALL_TEST_SYSTEMCTL_LOG" ] || \
        fail 'foreign service preflight reached systemctl'

    reset_firewall_quarantine_mock
    printf '%s\n' firewall-quarantine-v2 > "$RR_FIREWALL_QUARANTINE_FILE"
    chmod 600 "$RR_FIREWALL_QUARANTINE_FILE"
    foreign_dropin="$RR_FIREWALL_SYSTEMD_DIR/rr-firewall-quarantine-guard.service.d/99-hostile.conf"
    mkdir -p "$(dirname -- "$foreign_dropin")"
    printf '%s\n' '[Service]' 'ExecStartPre=/bin/rm -f -- /var/lib/rr-vps/firewall-quarantine' \
        > "$foreign_dropin"
    chmod 644 "$foreign_dropin"
    foreign_digest=$(sha256sum -- "$foreign_dropin")
    : > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
    if rr_firewall_install_fail_closed_supervisor >/dev/null 2>&1; then
        fail 'foreign quarantine service drop-in was executed or trusted'
    fi
    [ "$foreign_digest" = "$(sha256sum -- "$foreign_dropin")" ] && \
        [ ! -e "$RR_FIREWALL_GUARD_SCRIPT" ] || \
        fail 'foreign drop-in preflight changed a supervisor target'
    [ ! -s "$RR_FIREWALL_TEST_SYSTEMCTL_LOG" ] || \
        fail 'foreign drop-in preflight reached systemctl'

    reset_firewall_quarantine_mock
    rr_firewall_install_fail_closed_supervisor || \
        fail 'canonical quarantine supervisor failed installation proof'
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.path && \
        systemctl is-active --quiet rr-firewall-quarantine-guard.path || \
        fail 'quarantine path watcher is not durably enabled and active'
    if systemctl is-enabled --quiet rr-firewall-quarantine-guard.timer || \
       systemctl is-active --quiet rr-firewall-quarantine-guard.timer; then
        fail 'clear host retained the rapid quarantine retry timer'
    fi
    assert_supervisor_effective_mutation_rejected() {
        local property="$1" value="$2" context="$3" before="" after=""
        before=$(sha256sum -- "$RR_FIREWALL_GUARD_SCRIPT" \
            "$RR_FIREWALL_SYSTEMD_DIR"/rr-firewall-quarantine-guard.{service,path,timer}) || \
            fail "$context could not snapshot canonical supervisor files"
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY="$property"
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE="$value"
        : > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
        if rr_firewall_install_fail_closed_supervisor >/dev/null 2>&1; then
            fail "$context passed the pre-activation effective proof"
        fi
        after=$(sha256sum -- "$RR_FIREWALL_GUARD_SCRIPT" \
            "$RR_FIREWALL_SYSTEMD_DIR"/rr-firewall-quarantine-guard.{service,path,timer}) || \
            fail "$context lost a canonical supervisor file"
        [ "$before" = "$after" ] || \
            fail "$context rewrote a supervisor file before rejection"
        if grep -Eq '^(daemon-reload|enable|disable|start|restart|stop)( |$)' \
            "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"; then
            fail "$context reached a mutating systemctl operation"
        fi
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY=""
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE=""
    }
    assert_supervisor_effective_mutation_rejected ExecStartPre \
        '{ path=/bin/rm ; argv[]=/bin/rm -f /var/lib/rr-vps/firewall-quarantine ; ignore_errors=no }' \
        'foreign supervisor ExecStartPre'
    assert_supervisor_effective_mutation_rejected ExecStop \
        '{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }' \
        'foreign supervisor ExecStop'
    assert_supervisor_effective_mutation_rejected User nobody \
        'unprivileged supervisor identity'
    assert_supervisor_effective_mutation_rejected RootDirectory /srv/hostile-root \
        'supervisor alternate root'
    assert_supervisor_effective_mutation_rejected Environment \
        'LD_PRELOAD=/tmp/rr-supervisor.so' 'supervisor injected environment'
    assert_supervisor_effective_mutation_rejected Conditions \
        '{ type=ConditionPathExists ; parameter=/tmp/skip ; trigger=no ; negate=no }' \
        'conditional supervisor unit'
    assert_supervisor_effective_mutation_rejected Unit hostile.service \
        'path/timer target override'
    assert_supervisor_effective_mutation_rejected TimersMonotonic \
        '{ OnBootSec=2s ; } { OnUnitActiveSec=2s ; } { OnUnitInactiveSec=1s ; }' \
        'extra monotonic supervisor schedule'
    assert_supervisor_effective_mutation_rejected TimersCalendar '*-*-* *:*:00' \
        'extra calendar supervisor schedule'

    mkdir -p "$RR_FIREWALL_SYSTEMD_DIR/rr-firewall-quarantine-guard.service.d"
    printf '%s\n' '[Service]' 'ExecStart=' 'ExecStart=/bin/true' > \
        "$RR_FIREWALL_SYSTEMD_DIR/rr-firewall-quarantine-guard.service.d/99-hostile.conf"
    if rr_firewall_install_fail_closed_supervisor >/dev/null 2>&1; then
        fail 'hostile supervisor ExecStart drop-in passed effective proof'
    fi
    rm -rf -- "$RR_FIREWALL_SYSTEMD_DIR/rr-firewall-quarantine-guard.service.d"

    ln -s "$RR_FIREWALL_QUARANTINE_DIR/missing-target" \
        "$RR_FIREWALL_QUARANTINE_FILE"
    rr_firewall_fail_closed_quarantine_active || \
        fail 'dangling quarantine marker was not treated as active'
    /usr/bin/test ! -e "$RR_FIREWALL_QUARANTINE_FILE" || \
        fail 'dangling marker fixture unexpectedly has a target'
    if /usr/bin/test ! -L "$RR_FIREWALL_QUARANTINE_FILE"; then
        fail 'second quarantine ExecCondition would permit a dangling marker'
    fi
    rr_firewall_install_fail_closed_dropins || \
        fail 'symlink-safe quarantine drop-ins failed exact publication'
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service; do
        dropin="$RR_FIREWALL_SYSTEMD_DIR/${unit}.d/zzzzz-rr-firewall-quarantine.conf"
        grep -Fxq "ExecCondition=/usr/bin/test ! -e $RR_FIREWALL_QUARANTINE_FILE" \
            "$dropin" && \
        grep -Fxq "ExecCondition=/usr/bin/test ! -L $RR_FIREWALL_QUARANTINE_FILE" \
            "$dropin" || fail "dangling-marker gate is incomplete for $unit"
    done
)

printf '%s\n' '[0bb/9] effective quarantine conditions are managed-only and fail closed'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    printf '%s\n' firewall-inflight-v1 > "$RR_FIREWALL_QUARANTINE_FILE"
    chmod 600 "$RR_FIREWALL_QUARANTINE_FILE"
    restore_dropin="$RR_FIREWALL_SYSTEMD_DIR/sing-box.service.d/zzzz-rr-restore-gate.conf"
    install -d -m 755 "$(dirname -- "$restore_dropin")"
    printf '%s\n' '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$restore_dropin"
    chmod 644 "$restore_dropin"
    rr_firewall_install_fail_closed_dropins || \
        fail 'canonical optional restore plus firewall condition set was rejected'
    marker_digest=$(sha256sum -- "$RR_FIREWALL_QUARANTINE_FILE")
    firewall_exists="{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e $RR_FIREWALL_QUARANTINE_FILE ; ignore_errors=no }"
    firewall_link="{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -L $RR_FIREWALL_QUARANTINE_FILE ; ignore_errors=no }"
    restore_condition='{ path=/bin/sh ; argv[]=/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate ; ignore_errors=no }'

    assert_condition_mutation_rejected() {
        local context="$1"
        : > "$MOCK_NETFILTER_WRITE_LOG"
        if rr_firewall_install_fail_closed_dropins >/dev/null 2>&1; then
            fail "$context passed the effective quarantine condition proof"
        fi
        [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
            fail "$context reached a firewall backend writer"
        [ "$marker_digest" = "$(sha256sum -- "$RR_FIREWALL_QUARANTINE_FILE")" ] || \
            fail "$context removed or changed the durable quarantine marker"
        if systemctl start sing-box.service >/dev/null 2>&1; then
            fail "$context allowed a quarantined ingress runtime to start"
        fi
    }

    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE="{ path=/usr/bin/rm ; argv[]=/usr/bin/rm -f $RR_FIREWALL_QUARANTINE_FILE ; ignore_errors=no } $restore_condition $firewall_exists $firewall_link"
    assert_condition_mutation_rejected 'malicious marker unlink condition'
    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE="$restore_condition { path=/usr/bin/test ; argv[]=/usr/bin/test ! -e $RR_FIREWALL_QUARANTINE_FILE ; ignore_errors=yes } $firewall_link"
    assert_condition_mutation_rejected 'ignore_errors firewall condition'
    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE="$restore_condition $firewall_link $firewall_exists"
    assert_condition_mutation_rejected 'reversed firewall conditions'
    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE="$restore_condition $firewall_exists $firewall_link $firewall_link"
    assert_condition_mutation_rejected 'duplicate firewall condition'
    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE="$restore_condition { path=/usr/bin/test ; argv[]=/usr/bin/test ! -e $RR_FIREWALL_QUARANTINE_FILE } $firewall_link"
    assert_condition_mutation_rejected 'malformed firewall condition record'

    RR_FIREWALL_TEST_EXEC_CONDITIONS_OVERRIDE=""
    assert_marker_view_mutation_rejected() {
        local property="$1" value="$2" context="$3"
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY="$property"
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE="$value"
        assert_condition_mutation_rejected "$context"
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_PROPERTY=""
        RR_FIREWALL_TEST_EFFECTIVE_OVERRIDE_VALUE=""
    }
    assert_marker_view_mutation_rejected User nobody \
        'unprivileged service identity'
    assert_marker_view_mutation_rejected Group nogroup \
        'untrusted service group'
    assert_marker_view_mutation_rejected DynamicUser yes \
        'dynamic service identity'
    assert_marker_view_mutation_rejected PrivateUsers yes \
        'private user namespace'
    assert_marker_view_mutation_rejected PrivateMounts yes \
        'private mount namespace'
    assert_marker_view_mutation_rejected RootDirectory /srv/hostile-root \
        'alternate service root directory'
    assert_marker_view_mutation_rejected RootImage /srv/hostile.raw \
        'alternate service root image'
    assert_marker_view_mutation_rejected MountImages /srv/hostile.raw:/var/lib \
        'mounted service image'
    assert_marker_view_mutation_rejected ExtensionImages /srv/extension.raw \
        'service extension image'
    assert_marker_view_mutation_rejected ExtensionDirectories /srv/extension \
        'service extension directory'
    assert_marker_view_mutation_rejected TemporaryFileSystem /var/lib/rr-vps \
        'temporary filesystem hiding the marker'
    assert_marker_view_mutation_rejected BindPaths /tmp/empty:/var/lib/rr-vps \
        'bind mount hiding the marker'
    assert_marker_view_mutation_rejected BindReadOnlyPaths \
        /tmp/empty:/var/lib/rr-vps 'read-only bind hiding the marker'
    assert_marker_view_mutation_rejected InaccessiblePaths /var/lib/rr-vps \
        'inaccessible marker path'
    assert_marker_view_mutation_rejected JoinsNamespaceOf hostile.service \
        'joined hostile mount namespace'
    assert_marker_view_mutation_rejected ReadOnlyPaths /var/lib/rr-vps \
        'unproven read-only path override'
    assert_marker_view_mutation_rejected ReadWritePaths /var/lib/rr-vps \
        'unproven read-write path override'
    assert_marker_view_mutation_rejected ProtectSystem hidden \
        'unknown ProtectSystem view'
    assert_marker_view_mutation_rejected SystemCallFilter '~@file-system' \
        'seccomp filter able to turn marker stat into ENOENT'
    assert_marker_view_mutation_rejected Environment \
        'LD_PRELOAD=/tmp/rr-hide-marker.so' \
        'LD_PRELOAD service environment'
    assert_marker_view_mutation_rejected EnvironmentFiles \
        '/tmp/rr-hostile.env (ignore_errors=no)' \
        'service environment file'
    assert_marker_view_mutation_rejected PassEnvironment LD_PRELOAD \
        'manager environment passthrough'
    assert_marker_view_mutation_rejected PAMName rr-hostile \
        'PAM session namespace hook'
    assert_marker_view_mutation_rejected RootEphemeral yes \
        'ephemeral service root'
    assert_marker_view_mutation_rejected ProtectHome tmpfs \
        'unexpected renderer ProtectHome identity'

    hostile_reset="$RR_FIREWALL_SYSTEMD_DIR/sing-box.service.d/100-hostile-reset.conf"
    printf '%s\n' '[Service]' 'ExecCondition=' > "$hostile_reset"
    chmod 644 "$hostile_reset"
    assert_condition_mutation_rejected 'earlier ExecCondition reset drop-in'
    rm -f -- "$hostile_reset"

    printf '%s\n' '# changed restore gate' >> "$restore_dropin"
    assert_condition_mutation_rejected 'non-exact restore drop-in'
)

printf '%s\n' '[0bc/9] every quarantine marker capture failure aborts publication'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    rr_firewall_lock_acquire || fail 'marker capture test could not acquire firewall lock'
    for capture_failure in 1 2 3 4 5; do
        rm -f -- "$RR_FIREWALL_QUARANTINE_FILE" \
            "$RR_FIREWALL_QUARANTINE_DIR"/.firewall-marker.*
        capture_index=0
        rr_firewall_capture_quarantine_unit_line() {
            capture_index=$((capture_index + 1))
            [ "$capture_index" -ne "$capture_failure" ] || return 1
            printf 'unit\t%s\tloaded\tinactive\tdisabled\n' "$1"
        }
        if rr_firewall_write_marker_locked firewall-inflight-v1 unavailable; then
            fail "capture failure $capture_failure published a partial marker"
        fi
        [ ! -e "$RR_FIREWALL_QUARANTINE_FILE" ] && \
            [ ! -L "$RR_FIREWALL_QUARANTINE_FILE" ] || \
            fail "capture failure $capture_failure left a published marker"
        if compgen -G "$RR_FIREWALL_QUARANTINE_DIR/.firewall-marker.*" \
            >/dev/null; then
            fail "capture failure $capture_failure left a marker temporary"
        fi
    done
    rr_firewall_lock_release || fail 'marker capture test could not release firewall lock'
)

printf '%s\n' '[0bd/9] finish closes path-trigger races and preserves strict marker ancestry'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    runtime_restore_called=false
    rr_firewall_restore_quarantine_runtime_state() {
        [ ! -e "$RR_FIREWALL_QUARANTINE_FILE" ] && \
            [ ! -L "$RR_FIREWALL_QUARANTINE_FILE" ] || \
            fail 'runtime restore began while the firewall marker still existed'
        systemctl is-enabled --quiet rr-firewall-quarantine-guard.path && \
            systemctl is-active --quiet rr-firewall-quarantine-guard.path || \
            fail 'runtime restore began before the idle path watcher was rearmed'
        if systemctl is-active --quiet rr-firewall-quarantine-guard.timer || \
           systemctl is-active --quiet rr-firewall-quarantine-guard.service; then
            fail 'runtime restore raced a queued quarantine retry'
        fi
        runtime_restore_called=true
    }
    rr_firewall_lock_acquire || fail 'finish race test could not acquire firewall lock'
    rr_firewall_inflight_begin_locked || fail 'finish race test could not arm journal'
    chmod 750 "$RR_FIREWALL_QUARANTINE_DIR"
    if rr_firewall_load_inflight_marker; then
        fail 'marker loader accepted a non-0700 quarantine directory'
    fi
    chmod 700 "$RR_FIREWALL_QUARANTINE_DIR"
    rr_firewall_load_inflight_marker || fail 'strict marker ancestry did not recover'
    rr_firewall_inflight_finish_locked || fail 'race-free journal finish failed'
    [ "$runtime_restore_called" = true ] || fail 'finish skipped runtime restore'
    rr_firewall_lock_release || fail 'finish race test could not release firewall lock'
)

printf '%s\n' '[0c/9] pre-write journal survives five SIGKILL boundaries and blocks ingress'
# A synchronous stop/proof failure must promote v1 before any backend writer.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    rr_firewall_quiesce_durable_ingress() { return 1; }
    set +e
    open_protocol_firewall 46600 tcp >/dev/null 2>&1
    boundary_status=$?
    set -e
    [ "$boundary_status" -ge 2 ] || \
        fail 'pre-write stop failure was not propagated as indeterminate'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'pre-write stop failure reached a firewall writer'
    [ "$(head -n 1 -- "$RR_FIREWALL_QUARANTINE_FILE" 2>/dev/null)" = \
        firewall-quarantine-v2 ] || \
        fail 'pre-write stop failure did not atomically promote v1 to v2'
)

# SIGKILL immediately after the durable marker rename, before synchronous
# guard activation/proof, leaves the already-enabled path watcher and exact
# service ExecConditions able to block boot/start and converge independently.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    rr_firewall_load_inflight_marker() { kill -KILL "$BASHPID"; }
    ( open_protocol_firewall 46601 tcp >/dev/null 2>&1; exit 99 ) &
    boundary_pid=$!
    set +e; wait "$boundary_pid"; boundary_status=$?; set -e
    [ "$boundary_status" -eq 137 ] || \
        fail "marker-boundary child exited $boundary_status instead of SIGKILL"
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'marker-boundary crash occurred after a firewall writer'
    # Execute the exact independently installed path-service payload rather
    # than having the assertion helper silently repair unit state.
    # shellcheck disable=SC1090
    source "$RR_FIREWALL_GUARD_SCRIPT" || \
        fail 'marker-boundary path supervisor did not converge ingress'
    assert_inflight_crash_is_durably_blocked 'marker-boundary crash'
)

# Kill after the guard has begun stopping services but before its synchronous
# proof completes.  The durable supervisor must finish the remaining units.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    rr_firewall_quiesce_durable_ingress() {
        systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
        kill -KILL "$BASHPID"
    }
    ( open_protocol_firewall 46602 tcp >/dev/null 2>&1; exit 99 ) &
    boundary_pid=$!
    set +e; wait "$boundary_pid"; boundary_status=$?; set -e
    [ "$boundary_status" -eq 137 ] || \
        fail "guard-boundary child exited $boundary_status instead of SIGKILL"
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'guard-boundary crash reached a firewall writer'
    # shellcheck disable=SC1090
    source "$RR_FIREWALL_GUARD_SCRIPT" || \
        fail 'guard-boundary path supervisor did not finish convergence'
    assert_inflight_crash_is_durably_blocked 'guard-boundary crash'
)

# The first backend mutation is permitted only after all ingress was stopped
# and proved.  Killing immediately after that write must retain v1.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    MOCK_KILL_AFTER_NETFILTER_WRITE_ATTEMPT=1
    ( open_protocol_firewall 46603 tcp >/dev/null 2>&1; exit 99 ) &
    boundary_pid=$!
    set +e; wait "$boundary_pid"; boundary_status=$?; set -e
    [ "$boundary_status" -eq 137 ] || \
        fail "first-writer child exited $boundary_status instead of SIGKILL"
    [ -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'first-writer SIGKILL hook ran before the backend mutation'
    assert_inflight_crash_is_durably_blocked 'first-writer crash'
)

# A killed persistence backend cannot erase the crash journal even though the
# complete live candidate has already been written.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    save_boundary="$MOCK_NETFILTER_ROOT/save-boundary"
    netfilter-persistent() {
        : > "$save_boundary"
        sync -f "$save_boundary"
        kill -KILL "$BASHPID"
    }
    ( open_protocol_firewall 46604 tcp >/dev/null 2>&1; exit 99 ) &
    boundary_pid=$!
    set +e; wait "$boundary_pid"; boundary_status=$?; set -e
    [ "$boundary_status" -eq 137 ] && [ -f "$save_boundary" ] || \
        fail 'save-boundary SIGKILL hook did not run after the live candidate'
    assert_inflight_crash_is_durably_blocked 'save-boundary crash'
)

# If the candidate save fails, compensation restores live state before the
# second save.  Killing at that boundary is still indeterminate and must keep
# v1 rather than briefly exposing the restored-but-unproved program.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    prime_firewall_ingress_mock
    compensation_boundary="$MOCK_NETFILTER_ROOT/compensation-boundary"
    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        if [ "$PERSIST_CALLS" -eq 1 ]; then
            return 41
        fi
        : > "$compensation_boundary"
        sync -f "$compensation_boundary"
        kill -KILL "$BASHPID"
    }
    ( open_protocol_firewall 46605 tcp >/dev/null 2>&1; exit 99 ) &
    boundary_pid=$!
    set +e; wait "$boundary_pid"; boundary_status=$?; set -e
    [ "$boundary_status" -eq 137 ] && [ -f "$compensation_boundary" ] || \
        fail 'compensation-boundary SIGKILL hook did not reach the second save'
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            'argo-rr-managed'
    done
    assert_inflight_crash_is_durably_blocked 'compensation-boundary crash'
)

printf '%s\n' '[1/9] netfilter success and persistence'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }

    open_protocol_firewall 14443 tcp
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 14443 -m comment --comment argo-rr-managed -j ACCEPT'
    done
    [ "$PERSIST_CALLS" -eq 1 ] || fail 'open did not persist once'

    close_protocol_firewall 14443 tcp
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" 'argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 14443 -m comment --comment argo-rr-managed-block -j DROP'
    done
    [ "$PERSIST_CALLS" -eq 2 ] || fail 'close did not persist once'
)

printf '%s\n' '[2/9] backend, IPv6-disable proof, and post-write verification failures'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    MOCK_FAIL_WRITE_BACKEND=ip6tables
    if open_protocol_firewall 24443 tcp 2>/dev/null; then
        fail 'ip6tables write failure was hidden'
    fi
)
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    MOCK_SKIP_WRITE_BACKEND=iptables
    if open_protocol_firewall 24444 udp 2>/dev/null; then
        fail 'successful write without an ACCEPT rule passed verification'
    fi
)
(
    setup_ipv6_proc_mock 1 1 1 0
    trap 'rm -rf "$MOCK_PROC_ROOT"' EXIT
    if rr_ipv6_stack_is_disabled; then
        fail 'all/default disable flags hid an enabled concrete IPv6 interface'
    fi
)
(
    setup_ipv6_proc_mock 1 0 1 1
    trap 'rm -rf "$MOCK_PROC_ROOT"' EXIT
    if rr_ipv6_stack_is_disabled; then
        fail 'an enabled IPv6 default policy passed the disabled-stack proof'
    fi
)
(
    setup_ipv6_proc_mock 1 1 1 1
    trap 'rm -rf "$MOCK_PROC_ROOT"' EXIT
    rr_ipv6_stack_is_disabled || \
        fail 'all disabled IPv6 sysctl scopes did not prove the stack disabled'
)

printf '%s\n' '[3/9] persistence failure and missing persistence backend'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    netfilter-persistent() { return 41; }
    if open_protocol_firewall 34443 tcp 2>/dev/null; then
        fail 'persistence failure was hidden'
    fi
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    force_missing_persistence_backend
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4.before"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6.before"
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if open_protocol_firewall 34444 tcp >/dev/null 2>&1; then
        fail 'missing persistence backend allowed a raw filter write'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'missing persistence backend failed only after a raw filter write'
    cmp -s "$transaction_root/v4.before" "$MOCK_NETFILTER_ROOT/iptables.filter" && \
        cmp -s "$transaction_root/v6.before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'missing persistence backend changed live filter state'
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 34445 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    force_missing_persistence_backend
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if rr_restore_clear_managed_firewall >/dev/null 2>&1; then
        fail 'restore firewall clearer ran without a persistence backend'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'restore firewall clearer checked persistence after a write'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "missing restore persistence backend changed $backend state"
    done
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 34446 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    rr_restore_capture_firewall_snapshot "$rollback" || \
        fail 'could not capture raw restore backend fixture'
    force_missing_persistence_backend
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'raw firewall rollback ran without a persistence backend'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'raw rollback checked persistence after a firewall write'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "missing rollback persistence backend changed $backend state"
    done
)

printf '%s\n' '[4/9] active and inactive UFW behavior'
# Nexus must surface a failed underlying firewall transaction instead of
# returning an API-level success object.
reset_firewall_quarantine_mock
(
    SSH_PORT=22
    nexus_fw_known_ports() { printf '%s\n' '45670:tcp:test-port'; }
    nexus_fw_port_open() { return 1; }
    open_protocol_firewall() { return 1; }
    set +e
    nexus_result=$(nexus_fw_toggle 45670 tcp)
    nexus_status=$?
    set -e
    [ "$nexus_status" -eq 1 ] && \
        [ "$nexus_result" = '{"ok":false,"error":"firewall_transaction_failed"}' ] ||
        fail 'Nexus reported success after firewall open failure'
    nexus_fw_port_open() { return 0; }
    close_protocol_firewall() { return 1; }
    set +e
    nexus_result=$(nexus_fw_toggle 45670 tcp)
    nexus_status=$?
    set -e
    [ "$nexus_status" -eq 1 ] && \
        [ "$nexus_result" = '{"ok":false,"error":"firewall_transaction_failed"}' ] ||
        fail 'Nexus reported success after firewall close failure'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    force_missing_persistence_backend
    open_protocol_firewall 44442 tcp || \
        fail 'UFW-only filter transaction incorrectly required a raw persistence backend'
    assert_rule "$MOCK_UFW_RULES" 'allow|44442/tcp|argo-rr-managed'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'UFW-only transaction wrote the raw RR namespace'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' 'allow|44446/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback" || \
        fail 'could not capture UFW-only restore fixture'
    force_missing_persistence_backend
    rr_restore_clear_managed_firewall "$rollback/firewall" || \
        fail 'UFW-only restore clear incorrectly required a raw persistence backend'
    assert_no_match "$MOCK_UFW_RULES" '44446/tcp'
    rr_restore_restore_firewall_snapshot "$rollback" || \
        fail 'UFW-only rollback incorrectly required a raw persistence backend'
    assert_rule "$MOCK_UFW_RULES" 'allow|44446/tcp|argo-rr-managed'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'UFW-only restore wrote the raw RR namespace'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    open_protocol_firewall 44443 tcp
    assert_rule "$MOCK_UFW_RULES" 'allow|44443/tcp|argo-rr-managed'
    close_protocol_firewall 44443 tcp
    assert_no_match "$MOCK_UFW_RULES" 'allow|44443/tcp|argo-rr-managed'
    assert_rule "$MOCK_UFW_RULES" 'deny|44443/tcp|argo-rr-managed-block'

    MOCK_UFW_FAIL_WRITE=true
    if open_protocol_firewall 44444 udp 2>/dev/null; then
        fail 'active UFW write failure was hidden'
    fi
)
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    MOCK_UFW_ACTIVE=false
    MOCK_UFW_FAIL_WRITE=true
    for backend in iptables ip6tables; do
        printf '%s\n' '-P INPUT DROP' > "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    open_protocol_firewall 44445 tcp
)

printf '%s\n' '[4b/9] ordinary single-tuple compensation and persistence matrix'
# Normal netfilter open/closed calls each persist exactly once.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    open_protocol_firewall 45440 tcp || fail 'netfilter open transaction failed'
    [ "$PERSIST_CALLS" -eq 1 ] || fail 'netfilter open did not persist exactly once'
    close_protocol_firewall 45440 tcp || fail 'netfilter closed transaction failed'
    [ "$PERSIST_CALLS" -eq 2 ] || fail 'netfilter closed did not persist exactly once'
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '45440 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 45440 -m comment --comment argo-rr-managed-block -j DROP'
    done
)

# A first-family writer error must be zero-persist and byte-exact live rollback.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4.before"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6.before"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_FAIL_WRITE_SPECS='iptables:-I:1'
    if open_protocol_firewall 45441 tcp >/dev/null 2>&1; then
        fail 'IPv4 writer failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'IPv4 writer failure persisted partial state'
    cmp -s "$transaction_root/v4.before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'IPv4 writer failure changed IPv4 live state'
    cmp -s "$transaction_root/v6.before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'IPv4 writer failure changed IPv6 live state'
)

# A second-family writer error rolls IPv4 back and still performs no save.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4.before"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6.before"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_FAIL_WRITE_SPECS='ip6tables:-I:2'
    if open_protocol_firewall 45442 udp >/dev/null 2>&1; then
        fail 'IPv6 writer failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'IPv6 writer failure persisted partial state'
    cmp -s "$transaction_root/v4.before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'IPv6 writer failure left the IPv4 candidate live'
    cmp -s "$transaction_root/v6.before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'IPv6 writer failure changed the IPv6 pre-state'
)

# A command that reports success without writing is caught by post-verification.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4.before"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6.before"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_SKIP_WRITE_SPECS='ip6tables:-I:2'
    if open_protocol_firewall 45443 udp >/dev/null 2>&1; then
        fail 'IPv6 post-write verification failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'verification failure persisted partial state'
    cmp -s "$transaction_root/v4.before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'verification failure did not compensate IPv4'
    cmp -s "$transaction_root/v6.before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'verification failure changed IPv6'
)

# Fail the desired add after deleting the opposite tuple.  Both families and
# the original INPUT positions must be reconstructed exactly.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 45444 -m comment --comment argo-rr-managed -j ACCEPT' \
            '-A INPUT -p tcp --dport 65010 -m comment --comment user-position-sentinel -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_FAIL_WRITE_SPECS='iptables:-A:2'
    if close_protocol_firewall 45444 tcp >/dev/null 2>&1; then
        fail 'add-after-delete failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'add-after-delete failure was persisted'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "add-after-delete rollback lost $backend INPUT order"
    done
)

# Legacy dual authority changes UFW then IPv4 then IPv6, and persists only
# after all effective-policy/non-target seals pass.  Exercise both directions.
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    printf '%s\n' \
        'allow|22/tcp|user-before' \
        'deny|45445/tcp|argo-rr-managed-block' \
        'allow|23/tcp|user-after' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 65011 -m comment --comment user-before -j ACCEPT' \
            '-A INPUT -p tcp --dport 45445 -m comment --comment argo-rr-managed-block -j DROP' \
            '-A INPUT -p tcp --dport 65012 -m comment --comment user-after -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    open_protocol_firewall 45445 tcp || fail 'dual open transaction failed'
    [ "$PERSIST_CALLS" -eq 1 ] || fail 'dual open did not persist exactly once'
    assert_rule "$MOCK_UFW_RULES" 'allow|45445/tcp|argo-rr-managed'
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 45445 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 65011 -m comment --comment user-before -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 65012 -m comment --comment user-after -j ACCEPT'
    done
    close_protocol_firewall 45445 tcp || fail 'dual closed transaction failed'
    [ "$PERSIST_CALLS" -eq 2 ] || fail 'dual closed did not persist exactly once'
    assert_rule "$MOCK_UFW_RULES" 'deny|45445/tcp|argo-rr-managed-block'
)

# UFW add-after-delete failure restores the exact high-level rule position;
# raw legacy rules are never entered because the UFW phase did not commit.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    printf '%s\n' \
        'allow|22/tcp|user-before' \
        'deny|45446/tcp|argo-rr-managed-block' \
        'allow|23/tcp|user-after' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 45446 -m comment --comment argo-rr-managed-block -j DROP' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    cp "$MOCK_UFW_RULES" "$transaction_root/ufw.before"
    mkdir "$transaction_root/before-state" "$transaction_root/after-state"
    rr_firewall_capture_protocol_transaction "$transaction_root/before-state" \
        45446 tcp dual || fail 'could not capture the dual failure pre-state'
    : > "$MOCK_NETFILTER_WRITE_LOG"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_UFW_FAIL_WRITE_SPECS='add:2'
    if open_protocol_firewall 45446 tcp >/dev/null 2>&1; then
        fail 'UFW add-after-delete failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'UFW failure persisted raw state'
    cmp -s "$transaction_root/ufw.before" "$MOCK_UFW_RULES" || \
        fail 'UFW compensation lost the original rule position'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'UFW phase failure issued a raw tuple writer'
    rr_firewall_capture_protocol_transaction "$transaction_root/after-state" \
        45446 tcp dual || fail 'could not capture the compensated dual state'
    rr_firewall_protocol_transaction_exact_match \
        "$transaction_root/before-state" "$transaction_root/after-state" || \
        fail 'UFW phase failure changed a chain-local or unmanaged projection'
)

# A first save failure may represent a partial durable write.  Restore live,
# save the original state once, report failure, and never leave the candidate.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4.before"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6.before"
    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        [ "$PERSIST_CALLS" -ne 1 ]
    }
    if open_protocol_firewall 45447 tcp >/dev/null 2>&1; then
        fail 'first persistence failure was hidden after durable rollback'
    fi
    [ "$PERSIST_CALLS" -eq 2 ] || \
        fail 'first persistence failure did not save the original state exactly once'
    cmp -s "$transaction_root/v4.before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'first persistence failure left the IPv4 candidate live'
    cmp -s "$transaction_root/v6.before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'first persistence failure left the IPv6 candidate live'
)

# Failure of both the candidate save and the original-state save is a hard,
# explicit manual-check condition, while live state still returns to original.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4.before"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6.before"
    error_log="$transaction_root/error.log"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 41; }
    if open_protocol_firewall 45448 tcp >/dev/null 2>"$error_log"; then
        fail 'double persistence failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 2 ] || fail 'double persistence failure did not make two saves'
    grep -Fq '原态二次持久化失败' "$error_log" || \
        fail 'double persistence failure omitted the manual-check diagnostic'
    cmp -s "$transaction_root/v4.before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'double persistence failure left IPv4 candidate live'
    cmp -s "$transaction_root/v6.before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'double persistence failure left IPv6 candidate live'
)

# A compensation writer failure is never reported as a successful rollback.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p udp --dport 45449 -m comment --comment argo-rr-managed-block -j DROP' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    error_log="$transaction_root/error.log"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_FAIL_WRITE_SPECS='ip6tables:-I:4 ip6tables:-I:5'
    if open_protocol_firewall 45449 udp >/dev/null 2>"$error_log"; then
        fail 'compensation failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'compensation failure persisted a mixed state'
    grep -Fq '事务补偿失败' "$error_log" || \
        fail 'compensation failure omitted the manual-check diagnostic'
    cmp -s "$transaction_root/iptables.before" \
        "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'best-effort compensation did not restore IPv4 after IPv6 failed'
    if cmp -s "$transaction_root/ip6tables.before" \
        "$MOCK_NETFILTER_ROOT/ip6tables.filter"; then
        fail 'compensation failure injection unexpectedly restored IPv6'
    fi
)

# Candidate/update validation remains a strict zero-writer, zero-persist path
# even for legacy dual authority.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    printf '%s\n' 'allow|45450/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 45450 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    cp "$MOCK_UFW_RULES" "$transaction_root/ufw.before"
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    RR_UPDATE_TRANSACTION=1 open_protocol_firewall 45450 tcp || \
        fail 'read-only dual validation rejected the exact desired state'
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'read-only validation persisted state'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || fail 'read-only validation wrote raw rules'
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || fail 'read-only validation wrote UFW rules'
    cmp -s "$transaction_root/ufw.before" "$MOCK_UFW_RULES" || \
        fail 'read-only validation changed UFW state'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "read-only validation changed $backend"
    done
)

printf '%s\n' '[4c/9] configured-firewall batch compensation and hop transactions'
# The production module-70 hop entrypoints join the same transaction domain:
# direct install/remove calls snapshot, verify, persist and compensate rather
# than issuing uncoordinated raw-table writes.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    ENTRY_IP_MODE=ipv4
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    install_hop_rules HY2 45630 25630 || \
        fail 'production direct hop installer transaction failed'
    [ "$PERSIST_CALLS" -eq 1 ] || \
        fail 'production direct hop installer did not persist exactly once'
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            '-A PREROUTING -p udp --dport 25630 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45630'
    done
    remove_hop_ports 45630 HY2 25630 || \
        fail 'production direct hop remover transaction failed'
    [ "$PERSIST_CALLS" -eq 2 ] || \
        fail 'production direct hop remover did not persist exactly once'
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.nat" '--dport 25630'
    done
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    force_missing_persistence_backend
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25631 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45631' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.before"
    done
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if remove_hop_ports 45631 HY2 25631 >/dev/null 2>&1; then
        fail 'production hop remover ran without a persistence backend'
    fi
    if install_hop_rules TU5 45632 25632 >/dev/null 2>&1; then
        fail 'production hop installer ran without a persistence backend'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'production hop entrypoint checked persistence after a NAT write'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "missing persistence backend changed production $backend hop state"
    done
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25633 -m comment --comment argo-rr-TU5 -j REDIRECT --to-ports 45633' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.before"
    done
    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        [ "$PERSIST_CALLS" -ne 1 ]
    }
    if remove_hop_ports 45633 TU5 25633 >/dev/null 2>&1; then
        fail 'direct hop removal hid its first persistence failure'
    fi
    [ "$PERSIST_CALLS" -eq 2 ] || \
        fail 'direct hop removal did not persist the restored original exactly once'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "direct hop save compensation changed original $backend NAT state"
    done
)

# Hop replacement is one config+firewall batch.  A first persistence failure
# restores the byte-exact old NAT program, persists that original once, and
# rolls the already-applied config back instead of claiming success.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    CONFIG_SPEC=25640
    CONFIG_INTERVAL=30s
    CONFIG_CALLS=0
    load_config_with_defaults() {
        use_candidate_config
        HY2_PORT=45640
        HY2_HOP_PORTS="$CONFIG_SPEC"
        HY2_HOP_INTERVAL="$CONFIG_INTERVAL"
        TU5_ENABLED=false
    }
    get_hop_ports() { printf '%s\n' "$CONFIG_SPEC"; }
    validate_hop_spec_availability() { return 0; }
    apply_config_transaction() {
        CONFIG_CALLS=$((CONFIG_CALLS + 1))
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                HY2_HOP_PORTS) CONFIG_SPEC="$2" ;;
                HY2_HOP_INTERVAL) CONFIG_INTERVAL="$2" ;;
            esac
            shift 2
        done
    }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25640 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45640' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.before"
    done
    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        [ "$PERSIST_CALLS" -ne 1 ]
    }
    if apply_hop_configuration HY2 45640 25641 45s >/dev/null 2>&1; then
        fail 'hop replacement hid its first persistence failure'
    fi
    [ "$PERSIST_CALLS" -eq 2 ] && [ "$CONFIG_CALLS" -eq 2 ] && \
        [ "$CONFIG_SPEC" = 25640 ] && [ "$CONFIG_INTERVAL" = 30s ] ||
        fail "hop replacement compensation mismatch: persist=$PERSIST_CALLS config=$CONFIG_CALLS spec=$CONFIG_SPEC interval=$CONFIG_INTERVAL"
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" ||
            fail "hop replacement save rollback changed original $backend NAT order"
    done
)

# Once the new firewall program has been saved, a temp-root/lock cleanup
# failure cannot safely prove the transaction domain stayed exclusive.  The
# matching config remains on the committed side, but the result is distinctly
# indeterminate and all managed ingress is durably quarantined.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    BATCH_ROOT_SEEN=""
    trap '[ -z "$BATCH_ROOT_SEEN" ] || command rm -rf -- "$BATCH_ROOT_SEEN"; command rm -rf -- "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    CONFIG_SPEC=25645
    CONFIG_CALLS=0
    FAIL_BATCH_CLEANUP=false
    load_config_with_defaults() {
        use_candidate_config
        HY2_PORT=45645
        HY2_HOP_PORTS="$CONFIG_SPEC"
        HY2_HOP_INTERVAL=30s
        TU5_ENABLED=false
    }
    get_hop_ports() { printf '%s\n' "$CONFIG_SPEC"; }
    validate_hop_spec_availability() { return 0; }
    apply_config_transaction() {
        CONFIG_CALLS=$((CONFIG_CALLS + 1))
        BATCH_ROOT_SEEN="${RR_FIREWALL_BATCH_ROOT:-$BATCH_ROOT_SEEN}"
        shift
        while [ "$#" -gt 0 ]; do
            [ "$1" != HY2_HOP_PORTS ] || CONFIG_SPEC="$2"
            shift 2
        done
    }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25645 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45645' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
    done
    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        FAIL_BATCH_CLEANUP=true
    }
    rm() {
        local argument=""
        if [ "$FAIL_BATCH_CLEANUP" = true ]; then
            for argument in "$@"; do
                if [ -n "$BATCH_ROOT_SEEN" ] && [ "$argument" = "$BATCH_ROOT_SEEN" ]; then
                    return 1
                fi
            done
        fi
        command rm "$@"
    }
    error_log="$transaction_root/error.log"
    set +e
    apply_hop_configuration HY2 45645 25646 30s \
        > /dev/null 2> "$error_log"
    cleanup_status=$?
    set -e
    [ "$cleanup_status" -ge 2 ] ||
        fail 'cleanup/lock uncertainty was not propagated as indeterminate'
    [ "$PERSIST_CALLS" -eq 1 ] && [ "$CONFIG_CALLS" -eq 1 ] && \
        [ "$CONFIG_SPEC" = 25646 ] ||
        fail 'cleanup-only failure split committed firewall and config state'
    rr_firewall_fail_closed_quarantine_active ||
        fail 'cleanup/lock uncertainty did not publish durable quarantine'
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.nat" '--dport 25645'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            '-A PREROUTING -p udp --dport 25646 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45645'
    done
    FAIL_BATCH_CLEANUP=false
)

# Replacement preflight models the program after every old tuple is removed.
# A retained old tuple cannot hide a later user range and permit a shadowed
# append; rejection occurs before any NAT/config/persistence write.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    CONFIG_SPEC=25560,25561
    CONFIG_CALLS=0
    load_config_with_defaults() {
        use_candidate_config
        HY2_PORT=45641
        HY2_HOP_PORTS="$CONFIG_SPEC"
        HY2_HOP_INTERVAL=30s
        TU5_ENABLED=false
    }
    get_hop_ports() { printf '%s\n' "$CONFIG_SPEC"; }
    validate_hop_spec_availability() { return 0; }
    apply_config_transaction() { CONFIG_CALLS=$((CONFIG_CALLS + 1)); }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25560 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45641' \
            '-A PREROUTING -p udp --dport 25550:25565 -j REDIRECT --to-ports 22' \
            '-A PREROUTING -p udp --dport 25561 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45641' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.before"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if apply_hop_configuration HY2 45641 25560,25562 30s >/dev/null 2>&1; then
        fail 'retained old hop hid a post-replacement NAT shadow'
    fi
    [ "$CONFIG_CALLS" -eq 0 ] && [ "$PERSIST_CALLS" -eq 0 ] && \
        [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] ||
        fail 'replacement NAT conflict was detected after a side effect'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" ||
            fail "replacement preflight changed $backend NAT state"
    done
)

# A post-write effective-match failure compensates the in-memory batch before
# config or persistence is attempted.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    CONFIG_SPEC=25650
    CONFIG_CALLS=0
    FIRST_MATCH_CALLS=0
    load_config_with_defaults() {
        use_candidate_config
        HY2_PORT=45650
        HY2_HOP_PORTS="$CONFIG_SPEC"
        HY2_HOP_INTERVAL=30s
        TU5_ENABLED=false
    }
    get_hop_ports() { printf '%s\n' "$CONFIG_SPEC"; }
    validate_hop_spec_availability() { return 0; }
    apply_config_transaction() { CONFIG_CALLS=$((CONFIG_CALLS + 1)); }
    rr_validate_hop_rules() { return 0; }
    rr_firewall_hop_program_first_match_is_safe() {
        FIRST_MATCH_CALLS=$((FIRST_MATCH_CALLS + 1))
        [ "$FIRST_MATCH_CALLS" -eq 1 ]
    }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25650 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45650' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.before"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
    if apply_hop_configuration HY2 45650 25651 30s >/dev/null 2>&1; then
        fail 'post-write hop first-match failure was accepted'
    fi
    [ "$FIRST_MATCH_CALLS" -eq 2 ] && [ "$CONFIG_CALLS" -eq 0 ] && \
        [ "$PERSIST_CALLS" -eq 0 ] ||
        fail 'post-write hop failure reached config or persistence'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" ||
            fail "post-write hop failure did not restore exact $backend NAT state"
    done
)

# Main-port changes share the same preflight.  Missing raw persistence cannot
# mutate config, close the old INPUT port, or leave old hop rules behind.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    ENTRY_IP_MODE=ipv4
    CONFIG_CALLS=0
    load_config_with_defaults() {
        use_candidate_config
        HY2_PORT=45660
        HY2_HOP_PORTS=25660
        HY2_HOP_INTERVAL=30s
    }
    apply_config_transaction() { CONFIG_CALLS=$((CONFIG_CALLS + 1)); }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p udp --dport 45660 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25660 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45660' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    force_missing_persistence_backend
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if apply_hop_main_port_configuration HY2 45660 45661 25660 \
        >/dev/null 2>&1; then
        fail 'main-port change ran without hop persistence'
    fi
    [ "$CONFIG_CALLS" -eq 0 ] && [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] ||
        fail 'main-port persistence preflight occurred after a side effect'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" && \
        cmp -s "$transaction_root/${backend}.nat.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" ||
            fail "main-port backend rejection changed $backend state"
    done
)

# Every configured hop is proved against the effective PREROUTING order while
# the global lock is held and before even the first filter tuple is written.
for conflict_case in same-port range multiport user-chain unknown negated; do
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    case "$conflict_case" in
        same-port)
            conflict_rule='-A PREROUTING -p udp --dport 25570 -j REDIRECT --to-ports 22'
            hop_label=HY2; hop_main=45601; hop_spec=25570
            ;;
        range)
            conflict_rule='-A PREROUTING -p udp --dport 25560:25580 -j REDIRECT --to-ports 22'
            hop_label=HY2; hop_main=45601; hop_spec=25570
            ;;
        multiport)
            conflict_rule='-A PREROUTING -p udp -m multiport --dports 53,25585 -j REDIRECT --to-ports 22'
            hop_label=TU5; hop_main=45602; hop_spec=25580:25590
            ;;
        user-chain)
            conflict_rule='-A PREROUTING -p udp --dport 25585 -j USER_NAT'
            hop_label=TU5; hop_main=45602; hop_spec=25580:25590
            ;;
        unknown)
            conflict_rule='-A PREROUTING -p udp -m mystery --mystery value -j ACCEPT'
            hop_label=HY2; hop_main=45601; hop_spec=25570
            ;;
        negated)
            conflict_rule='-A PREROUTING ! -p tcp --dport 1 -j RETURN'
            hop_label=TU5; hop_main=45602; hop_spec=25580:25590
            ;;
    esac
    for backend in iptables ip6tables; do
        [ "$conflict_case" != user-chain ] || \
            printf '%s\n' '-N USER_NAT' >> "$MOCK_NETFILTER_ROOT/${backend}.nat"
        printf '%s\n' "$conflict_rule" >> "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45600
        TEST_HY2_ENABLED=false
        TEST_HY2_HOP_PORTS=
        TEST_TU5_ENABLED=false
        TEST_TU5_HOP_PORTS=
        if [ "$hop_label" = HY2 ]; then
            TEST_HY2_ENABLED=true
            TEST_HY2_PORT="$hop_main"
            TEST_HY2_HOP_PORTS="$hop_spec"
        else
            TEST_TU5_ENABLED=true
            TEST_TU5_PORT="$hop_main"
            TEST_TU5_HOP_PORTS="$hop_spec"
        fi
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail "$conflict_case overlapping NAT rule passed configured-hop preflight"
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail "$conflict_case NAT conflict was rejected only after a firewall write"
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" && \
            cmp -s "$transaction_root/${backend}.nat.before" \
                "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "$conflict_case NAT preflight changed live firewall state"
    done
)
done

# Two fresh configured hop sets are also part of the same pre-write proof;
# they cannot claim overlapping UDP ingress ranges for different protocols.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    load_config_with_defaults() {
        TEST_SUB_PORT=45605
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45606
        TEST_HY2_HOP_PORTS=25700:25710
        TEST_TU5_ENABLED=true
        TEST_TU5_PORT=45607
        TEST_TU5_HOP_PORTS=25710:25720
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'overlapping HY2/TU5 desired hop ranges passed whole-batch preflight'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ "$PERSIST_CALLS" -eq 0 ] ||
        fail 'HY2/TU5 desired overlap was detected after a firewall side effect'
)

# Positive first-match control: recognized disjoint UDP ranges and an exact
# TCP selector at the same port stay ahead of the new RR rule without
# preventing either HY2 family from becoming effective.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 29000:29010 -j REDIRECT --to-ports 22' \
            '-A PREROUTING -p tcp --dport 25594 -j REDIRECT --to-ports 23' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.user.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45608
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45609
        TEST_HY2_HOP_PORTS=25594
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    RR_UPDATE_TRANSACTION=0 open_configured_firewall ||
        fail 'disjoint existing NAT rules were rejected by effective-hop proof'
    for backend in iptables ip6tables; do
        head -n 2 "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            > "$transaction_root/${backend}.user.after"
        cmp -s "$transaction_root/${backend}.user.before" \
            "$transaction_root/${backend}.user.after" ||
            fail "disjoint $backend NAT rules were reordered or changed"
        grep -Fq -- \
            '-A PREROUTING -p udp --dport 25594 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45609' \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" ||
            fail "effective HY2 rule missing behind disjoint $backend rules"
    done
)

# A recognized comment-free legacy rule is itself the effective first match;
# it remains valid and must not be duplicated.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 25595 -j DNAT --to-destination :45612' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45610
        TEST_TU5_ENABLED=true
        TEST_TU5_PORT=45612
        TEST_TU5_HOP_PORTS=25595
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { return 0; }
    rr_validate_hop_rules() {
        rr_firewall_hop_program_first_match_is_safe "$1" "$2" "$3" post
    }
    RR_UPDATE_TRANSACTION=0 open_configured_firewall || \
        fail 'recognized legacy effective hop rule was rejected'
    for backend in iptables ip6tables; do
        [ "$(grep -Fc -- '--dport 25595' "$MOCK_NETFILTER_ROOT/${backend}.nat")" -eq 1 ] || \
            fail "legacy $backend hop rule was duplicated"
    done
)

# Active UFW needs no raw backend for filter-only changes, but adding a hop
# makes raw/NAT durability mandatory for the whole batch.  Reject before the
# UFW tuple or either NAT family changes.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    force_missing_persistence_backend
    cp "$MOCK_UFW_RULES" "$transaction_root/ufw.before"
    for backend in iptables ip6tables; do
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45620
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45621
        TEST_HY2_HOP_PORTS=25620
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'UFW plus hop batch succeeded without a raw persistence backend'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'UFW plus hop backend preflight happened after a firewall write'
    cmp -s "$transaction_root/ufw.before" "$MOCK_UFW_RULES" || \
        fail 'missing hop persistence backend changed UFW state'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" && \
            cmp -s "$transaction_root/${backend}.nat.before" \
                "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "missing hop persistence backend changed $backend state"
    done
)

# A successful multi-tuple + NAT batch has one durable commit, not one save
# per tuple, and leaves unmanaged filter/NAT projections untouched.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 22 -m comment --comment user-batch-filter -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 26000 -m comment --comment user-batch-nat -j REDIRECT --to-ports 22' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45501
        TEST_VL_ENABLED=true
        TEST_VL_PORT=45502
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45503
        TEST_HY2_HOP_PORTS=25510,25511
        TEST_TU5_ENABLED=true
        TEST_TU5_PORT=45504
        TEST_TU5_HOP_PORTS=25512
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }

    RR_UPDATE_TRANSACTION=0 open_configured_firewall || \
        fail 'successful configured-firewall batch failed'
    [ "$PERSIST_CALLS" -eq 1 ] || \
        fail 'successful configured-firewall batch did not persist exactly once'
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 45501 -m comment --comment argo-rr-managed-block -j DROP'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 45502 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p udp --dport 45503 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p udp --dport 45504 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 22 -m comment --comment user-batch-filter -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            '-A PREROUTING -p udp --dport 26000 -m comment --comment user-batch-nat -j REDIRECT --to-ports 22'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            '-A PREROUTING -p udp --dport 25510 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45503'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            '-A PREROUTING -p udp --dport 25511 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 45503'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            '-A PREROUTING -p udp --dport 25512 -m comment --comment argo-rr-TU5 -j REDIRECT --to-ports 45504'
    done
)

# A later ordinary port failure compensates every earlier successful tuple and
# performs no durable write.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 22 -m comment --comment user-late-failure -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45511
        TEST_VL_ENABLED=true
        TEST_VL_PORT=45512
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45513
        use_candidate_config
    }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    # SUB(v4/v6), VL(v4/v6), then HY2(v4/v6): fail the sixth write.
    MOCK_FAIL_WRITE_SPECS='ip6tables:-I:6'
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'later configured port writer failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'later port failure persisted a prefix'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "later port failure left an earlier $backend tuple"
    done
)

# A dual-authority late UFW failure also unwinds the preceding UFW and raw
# tuple as one operation, preserving the unmanaged projection.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 65020 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    mkdir "$transaction_root/before" "$transaction_root/after"
    rr_firewall_capture_protocol_transaction "$transaction_root/before" \
        45521 tcp dual || fail 'could not capture dual batch pre-state'
    load_config_with_defaults() {
        TEST_SUB_PORT=45521
        TEST_VL_ENABLED=true
        TEST_VL_PORT=45522
        use_candidate_config
    }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_UFW_FAIL_WRITE_SPECS='add:2'
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'late dual UFW failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'late dual UFW failure persisted a prefix'
    rr_firewall_capture_protocol_transaction "$transaction_root/after" \
        45521 tcp dual || fail 'could not capture dual batch compensated state'
    rr_firewall_protocol_transaction_exact_match "$transaction_root/before" \
        "$transaction_root/after" || \
        fail 'late dual UFW failure changed UFW/raw/unmanaged projections'
)

# A required-family hop failure after partial writes restores both NAT
# families and then every earlier INPUT tuple without saving.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 22 -m comment --comment user-hop-filter -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 26100 -m comment --comment user-hop-nat -j REDIRECT --to-ports 22' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45531
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45532
        TEST_HY2_HOP_PORTS=25520,25521
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    # spec1 v4/v6 succeed; required-v4 spec2 fails while optional-v6 may write.
    MOCK_FAIL_NAT_WRITE_SPECS='iptables:-A:3'
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'partial hop writer failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'partial hop failure persisted state'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "partial hop failure left $backend INPUT tuples"
        cmp -s "$transaction_root/${backend}.nat.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "partial hop failure left or reordered $backend NAT rules"
    done
)

# A NAT writer that reports success without writing is rejected by the
# required-family validator and compensated before persistence.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45541
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45542
        TEST_HY2_HOP_PORTS=25530
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    MOCK_SKIP_NAT_WRITE_SPECS='iptables:-A:1'
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'hop success-without-write verification failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'hop verification failure persisted state'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "hop verification failure left $backend INPUT tuples"
        cmp -s "$transaction_root/${backend}.nat.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "hop verification failure changed $backend NAT"
    done
)

# A configured hop can never be silently skipped if the writer/validator was
# not loaded; fail closed and unwind the already reconciled INPUT tuples.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45546
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45547
        TEST_HY2_HOP_PORTS=25535
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    unset -f install_hop_rules rr_validate_hop_rules 2>/dev/null || true
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'missing hop transaction helpers were silently skipped'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'missing hop helpers persisted state'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "missing hop helpers left $backend INPUT tuples"
    done
)

# If a post-hop panel tuple fails, the generic operation journal restores the
# hop first and then the earlier protocol tuples in strict LIFO order.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 26200 -m comment --comment user-post-hop -j REDIRECT --to-ports 22' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    printf '%s\n' '{"mode":"public","public_port":45553}' \
        > "$transaction_root/nexus.json"
    load_config_with_defaults() {
        TEST_SUB_PORT=45551
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45552
        TEST_HY2_HOP_PORTS=25540
        TEST_TU5_ENABLED=true
        TEST_TU5_PORT=45554
        TEST_TU5_HOP_PORTS=25541
        TEST_NEXUS_CONFIG_FILE="$transaction_root/nexus.json"
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 0; }
    # Six filter writes, four NAT writes, then fail the panel's IPv4 writer.
    MOCK_FAIL_WRITE_SPECS='iptables:-I:11'
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'post-hop panel tuple failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'post-hop panel failure persisted state'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "post-hop failure left $backend INPUT tuples"
        cmp -s "$transaction_root/${backend}.nat.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "post-hop failure left $backend NAT tuples"
    done
)

# Batch save failure restores all live INPUT/NAT state and saves that exact
# original once.  The candidate save plus original save total exactly two.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 22 -m comment --comment user-save-filter -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 26300 -m comment --comment user-save-nat -j REDIRECT --to-ports 22' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.filter.before"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.nat.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45561
        TEST_VL_ENABLED=true
        TEST_VL_PORT=45562
        TEST_HY2_ENABLED=true
        TEST_HY2_PORT=45563
        TEST_HY2_HOP_PORTS=25550
        use_candidate_config
        ENTRY_IP_MODE=ipv4
    }
    install_hop_rules() { test_install_hop_rules "$@"; }
    rr_validate_hop_rules() { test_validate_hop_rules "$@"; }
    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        [ "$PERSIST_CALLS" -ne 1 ]
    }
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'configured batch persistence failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 2 ] || \
        fail 'configured batch save failure did not persist original exactly once'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.filter.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "batch save failure left $backend INPUT candidate"
        cmp -s "$transaction_root/${backend}.nat.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "batch save failure left $backend NAT candidate"
    done
)

# If saving both the candidate and recovered original fails, the batch still
# restores live state and emits an explicit manual-inspection warning.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    load_config_with_defaults() {
        TEST_SUB_PORT=45566
        TEST_VL_ENABLED=true
        TEST_VL_PORT=45567
        use_candidate_config
    }
    error_log="$transaction_root/error.log"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 41; }
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall \
        >/dev/null 2>"$error_log"; then
        fail 'configured batch double persistence failure was hidden'
    fi
    [ "$PERSIST_CALLS" -eq 2 ] || \
        fail 'configured batch double persistence failure did not make two saves'
    grep -Fq '批事务原态二次持久化失败' "$error_log" || \
        fail 'configured batch double persistence failure omitted manual warning'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "configured batch double save failure left $backend candidate"
    done
)

# Multiple legacy/tagged hop tuples are restored to their exact original
# PREROUTING positions with targeted deletes/inserts only.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 26400 -m comment --comment user-before -j REDIRECT --to-ports 22' \
            '-A PREROUTING -p udp --dport 25560 -m comment --comment argo-rr-HY2 -j DNAT --to-destination :45571' \
            '-A PREROUTING -p udp --dport 26401 -m comment --comment user-middle -j REDIRECT --to-ports 22' \
            '-A PREROUTING -p udp --dport 25561 -j REDIRECT --to-ports 45571' \
            '-A PREROUTING -p udp --dport 26402 -m comment --comment user-after -j REDIRECT --to-ports 22' \
            '-A OUTPUT -p udp --dport 26403 -j ACCEPT' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
        cp "$MOCK_NETFILTER_ROOT/${backend}.nat" \
            "$transaction_root/${backend}.before"
    done
    snapshot="$transaction_root/snapshot"
    mkdir "$snapshot"
    rr_firewall_capture_hop_transaction "$snapshot" HY2 45571 25560,25561 || \
        fail 'could not capture multi-position hop snapshot'
    rr_firewall_lock_acquire || fail 'could not lock multi-position hop fixture'
    rr_firewall_inflight_begin_locked || \
        fail 'could not arm multi-position hop fixture before its first writer'
    for backend in iptables ip6tables; do
        "$backend" -w 5 -t nat -D PREROUTING -p udp --dport 25560 \
            -m comment --comment argo-rr-HY2 -j DNAT \
            --to-destination :45571 >/dev/null 2>&1 || \
            fail "could not mutate tagged $backend hop"
        "$backend" -w 5 -t nat -D PREROUTING -p udp --dport 25561 \
            -j REDIRECT --to-ports 45571 >/dev/null 2>&1 || \
            fail "could not mutate legacy $backend hop"
        "$backend" -w 5 -t nat -A PREROUTING -p udp --dport 25560 \
            -m comment --comment argo-rr-HY2 -j REDIRECT \
            --to-ports 45571 >/dev/null 2>&1 || \
            fail "could not install mutated $backend hop"
    done
    rr_firewall_restore_hop_transaction "$snapshot" HY2 45571 25560,25561 || \
        fail 'multi-position hop compensation failed'
    rr_firewall_inflight_finish_locked || \
        fail 'multi-position hop fixture could not clear its in-flight journal'
    rr_firewall_lock_release || \
        fail 'multi-position hop fixture could not release its firewall lock'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "hop compensation lost $backend PREROUTING position"
    done
)

printf '%s\n' '[4d/9] menu config/firewall transaction outcomes stay coherent'
# A successful menu port switch has one durable firewall commit.  If the next
# commit's first save fails, status 10 restores the exact old tuples/config and
# the service's original running state.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    CONFIG_VL_PORT=45700
    CONFIG_CALLS=0
    SERVICE_RUNNING=true
    STOP_CALLS=0
    load_config_with_defaults() {
        VM_ENABLED=false; VM_TLS_ENABLED=false; PORT=41000
        VL_ENABLED=true; VL_PORT="$CONFIG_VL_PORT"
        HY2_ENABLED=false; HY2_PORT=41001; HY2_HOP_PORTS=
        TU5_ENABLED=false; TU5_PORT=41002; TU5_HOP_PORTS=
        AN_ENABLED=false; AN_PORT=41003
        NAIVE_ENABLED=false; NAIVE_PORT=41004; NAIVE_MODE=h2
        SUB_ACCESS_MODE=local; SUB_PORT=41005; SSH_PORT=22
        NEXUS_CONFIG_FILE="$MOCK_NETFILTER_ROOT/no-nexus.json"
    }
    apply_config_transaction() {
        CONFIG_CALLS=$((CONFIG_CALLS + 1))
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in VL_PORT) CONFIG_VL_PORT="$2"; VL_PORT="$2" ;; esac
            shift 2
        done
    }
    managed_singbox_running() { [ "$SERVICE_RUNNING" = true ]; }
    stop_singbox_instances() { SERVICE_RUNNING=false; }
    ensure_node_service_running() { SERVICE_RUNNING=true; }
    subscription_server_running() { return 1; }
    stop_subscription_servers() { return 0; }
    rr_firewall_stop_nodes_on_indeterminate_commit() {
        STOP_CALLS=$((STOP_CALLS + 1)); SERVICE_RUNNING=false
    }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 45700 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
    first_operations=(
        'protocol|closed|45700|tcp'
        'protocol|open|45701|tcp')
    first_updates=(VL_PORT 45701)
    apply_config_firewall_batch 'menu port success' preserve \
        first_operations first_updates || fail 'menu port success transaction failed'
    [ "$CONFIG_VL_PORT" = 45701 ] && [ "$CONFIG_CALLS" -eq 1 ] && \
        [ "$PERSIST_CALLS" -eq 1 ] && [ "$SERVICE_RUNNING" = true ] || \
        fail 'menu success did not commit config/firewall/service exactly once'
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 45701 -m comment --comment argo-rr-managed -j ACCEPT'
    done

    PERSIST_CALLS=0
    netfilter-persistent() {
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
        [ "$PERSIST_CALLS" -ne 1 ]
    }
    second_operations=(
        'protocol|closed|45701|tcp'
        'protocol|open|45702|tcp')
    second_updates=(VL_PORT 45702)
    if apply_config_firewall_batch 'menu port rollback' preserve \
        second_operations second_updates >/dev/null 2>&1; then
        fail 'menu port transaction hid its first persistence failure'
    fi
    [ "$CONFIG_VL_PORT" = 45701 ] && [ "$CONFIG_CALLS" -eq 3 ] && \
        [ "$PERSIST_CALLS" -eq 2 ] && [ "$SERVICE_RUNNING" = true ] || \
        fail 'menu status-10 path did not restore config/persistence/service'
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 45701 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" '--dport 45702'
    done
)

# Status 12 is not an exact durable rollback: retain the new config, stop the
# node, return failure, and never issue a misleading inverse config commit.
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    CONFIG_VL_PORT=45710
    CONFIG_CALLS=0
    SERVICE_RUNNING=true
    load_config_with_defaults() {
        VM_ENABLED=false; VM_TLS_ENABLED=false; PORT=41100
        VL_ENABLED=true; VL_PORT="$CONFIG_VL_PORT"
        HY2_ENABLED=false; HY2_PORT=41101; HY2_HOP_PORTS=
        TU5_ENABLED=false; TU5_PORT=41102; TU5_HOP_PORTS=
        AN_ENABLED=false; AN_PORT=41103
        NAIVE_ENABLED=false; NAIVE_PORT=41104; NAIVE_MODE=h2
        SUB_ACCESS_MODE=local; SUB_PORT=41105; SSH_PORT=22
        NEXUS_CONFIG_FILE="$MOCK_NETFILTER_ROOT/no-nexus.json"
    }
    apply_config_transaction() {
        CONFIG_CALLS=$((CONFIG_CALLS + 1)); shift
        while [ "$#" -gt 0 ]; do
            [ "$1" != VL_PORT ] || { CONFIG_VL_PORT="$2"; VL_PORT="$2"; }
            shift 2
        done
    }
    managed_singbox_running() { [ "$SERVICE_RUNNING" = true ]; }
    stop_singbox_instances() { SERVICE_RUNNING=false; }
    ensure_node_service_running() { SERVICE_RUNNING=true; }
    subscription_server_running() { return 1; }
    stop_subscription_servers() { return 0; }
    rr_firewall_stop_nodes_on_indeterminate_commit() { SERVICE_RUNNING=false; }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 45710 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); return 41; }
    operations=(
        'protocol|closed|45710|tcp'
        'protocol|open|45711|tcp')
    updates=(VL_PORT 45711)
    if apply_config_firewall_batch 'menu indeterminate save' preserve \
        operations updates >/dev/null 2>&1; then
        fail 'menu status-12 path claimed success'
    fi
    [ "$CONFIG_VL_PORT" = 45711 ] && [ "$CONFIG_CALLS" -eq 1 ] && \
        [ "$PERSIST_CALLS" -eq 2 ] && [ "$SERVICE_RUNNING" = false ] || \
        fail 'menu status-12 path reversed config or left the node running'
)

# Config-transaction failure is independently proved old after exact firewall
# abort, then restores (and only then restores) the original service state.
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    SERVICE_RUNNING=true
    CONFIG_CALLS=0
    load_config_with_defaults() {
        VM_ENABLED=false; VM_TLS_ENABLED=false; PORT=41200
        VL_ENABLED=true; VL_PORT=45720
        HY2_ENABLED=false; HY2_PORT=41201; HY2_HOP_PORTS=
        TU5_ENABLED=false; TU5_PORT=41202; TU5_HOP_PORTS=
        AN_ENABLED=false; AN_PORT=41203
        NAIVE_ENABLED=false; NAIVE_PORT=41204; NAIVE_MODE=h2
        SUB_ACCESS_MODE=local; SUB_PORT=41205; SSH_PORT=22
        NEXUS_CONFIG_FILE="$MOCK_NETFILTER_ROOT/no-nexus.json"
    }
    apply_config_transaction() { CONFIG_CALLS=$((CONFIG_CALLS + 1)); return 1; }
    managed_singbox_running() { [ "$SERVICE_RUNNING" = true ]; }
    stop_singbox_instances() { SERVICE_RUNNING=false; }
    ensure_node_service_running() { SERVICE_RUNNING=true; }
    subscription_server_running() { return 1; }
    stop_subscription_servers() { return 0; }
    rr_firewall_stop_nodes_on_indeterminate_commit() { SERVICE_RUNNING=false; }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 45720 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$transaction_root/${backend}.before"
    done
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
    operations=(
        'protocol|closed|45720|tcp'
        'protocol|open|45721|tcp')
    updates=(VL_PORT 45721)
    if apply_config_firewall_batch 'menu config failure' preserve \
        operations updates >/dev/null 2>&1; then
        fail 'menu config failure claimed success'
    fi
    [ "$CONFIG_CALLS" -eq 1 ] && [ "$PERSIST_CALLS" -eq 0 ] && \
        [ "$SERVICE_RUNNING" = true ] || \
        fail 'menu config failure did not restore the old service without saving'
    for backend in iptables ip6tables; do
        cmp -s "$transaction_root/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "menu config failure changed $backend live state"
    done
)

# Stage normalization protects shared consumers and rejects an allow record
# that the post-update RR config does not authorize.
(
    load_config_with_defaults() {
        VM_ENABLED=false; VM_TLS_ENABLED=false; PORT=41300
        VL_ENABLED=true; VL_PORT=45730
        HY2_ENABLED=false; HY2_PORT=41301
        TU5_ENABLED=false; TU5_PORT=41302
        AN_ENABLED=true; AN_PORT=45730
        NAIVE_ENABLED=false; NAIVE_PORT=41303; NAIVE_MODE=h2
        SUB_ACCESS_MODE=local; SUB_PORT=41304; SSH_PORT=22
        NEXUS_CONFIG_FILE=/nonexistent/rr-nexus.json
    }
    load_config_with_defaults
    operations=('protocol|closed|45730|tcp')
    updates=(VL_ENABLED false)
    normalized=()
    rr_firewall_normalize_stage_operations operations updates normalized || \
        fail 'shared consumer normalization failed'
    [ "${normalized[*]}" = 'protocol|open|45730|tcp' ] || \
        fail 'shared enabled protocol was converted to a managed DROP'
    operations=('protocol|open|45731|tcp')
    if rr_firewall_normalize_stage_operations operations updates normalized; then
        fail 'unconfigured durable allow survived stage normalization'
    fi
)

printf '%s\n' '[5/9] desired-set cleanup preserves user rules'
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    printf '%s\n' \
        '-A INPUT -p tcp --dport 22 -m comment --comment user-owned -j ACCEPT' \
        '-A INPUT -p tcp --dport 51111 -m comment --comment argo-rr-managed -j ACCEPT' \
        >> "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 51000 -m comment --comment user-hop -j REDIRECT --to-ports 22' \
        '-A PREROUTING -p udp --dport 52000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 51111' \
        > "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' 'allow|22/tcp|user-owned' 'allow|51111/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program

    rr_restore_clear_managed_firewall
    assert_rule "$MOCK_NETFILTER_ROOT/iptables.filter" \
        '-A INPUT -p tcp --dport 22 -m comment --comment user-owned -j ACCEPT'
    assert_rule "$MOCK_NETFILTER_ROOT/iptables.nat" \
        '-A PREROUTING -p udp --dport 51000 -m comment --comment user-hop -j REDIRECT --to-ports 22'
    assert_rule "$MOCK_UFW_RULES" 'allow|22/tcp|user-owned'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" '51111'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.nat" '52000'
    assert_no_match "$MOCK_UFW_RULES" '51111'

    : > "$MOCK_NETFILTER_WRITE_LOG"
    open_protocol_firewall 53333 tcp
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" '51111'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" \
        '-A INPUT -p tcp --dport 53333'
    assert_rule "$MOCK_UFW_RULES" 'allow|53333/tcp|argo-rr-managed'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'UFW-authoritative reconciliation wrote a raw filter rule'
)

printf '%s\n' '[5b/9] UFW authority is closed across installs, updates and invalid scopes'
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }

    # First use on an active-UFW host with no legacy raw RR namespace chooses
    # UFW authority and keeps that state on later ordinary menu/update calls.
    open_protocol_firewall 54443 tcp
    assert_rule "$MOCK_UFW_RULES" 'allow|54443/tcp|argo-rr-managed'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'fresh active-UFW reconciliation dual-wrote raw INPUT'
    [ "$PERSIST_CALLS" -eq 0 ] || fail 'UFW-only filter state was raw-persisted'
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"
    RR_UPDATE_TRANSACTION=1 open_protocol_firewall 54443 tcp
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'ordinary update validation mutated UFW-authoritative state'
    RR_UPDATE_TRANSACTION=0 open_protocol_firewall 54444 udp
    assert_rule "$MOCK_UFW_RULES" 'allow|54444/udp|argo-rr-managed'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'later menu call fell back from UFW authority to dual-write'
)
for invalid_scope in bad missing_portable missing_lock inactive stale_raw; do
    (
        setup_netfilter_mock
        setup_ufw_mock
        trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
        RR_PORTABLE_UFW_AUTHORITY=1
        RR_PORTABLE_RESTORE=1
        RR_RESTORE_LOCK_HELD=1
        PERSIST_CALLS=0
        netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
        case "$invalid_scope" in
            bad) RR_PORTABLE_UFW_AUTHORITY=bad ;;
            missing_portable) RR_PORTABLE_RESTORE=0 ;;
            missing_lock) RR_RESTORE_LOCK_HELD=0 ;;
            inactive) MOCK_UFW_ACTIVE=false ;;
            stale_raw)
                printf '%s\n' \
                    '-A INPUT -p tcp --dport 54445 -m comment --comment argo-rr-managed -j ACCEPT' \
                    > "$MOCK_NETFILTER_ROOT/iptables.filter"
                ;;
        esac
        : > "$MOCK_NETFILTER_WRITE_LOG"
        : > "$MOCK_UFW_WRITE_LOG"
        if open_protocol_firewall 54445 tcp >/dev/null 2>&1; then
            fail "invalid portable UFW authority scope passed: $invalid_scope"
        fi
        [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
            fail "invalid authority scope wrote firewall state: $invalid_scope"
        [ "$PERSIST_CALLS" -eq 0 ] || \
            fail "invalid authority scope persisted firewall state: $invalid_scope"
    )
done
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    RR_PORTABLE_UFW_AUTHORITY=1
    RR_PORTABLE_RESTORE=1
    RR_RESTORE_LOCK_HELD=1
    open_protocol_firewall 54446 tcp
    assert_rule "$MOCK_UFW_RULES" 'allow|54446/tcp|argo-rr-managed'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'valid portable UFW scope wrote raw filter state'
)

printf '%s\n' '[6/9] restore rollback replaces candidate RR rules exactly'
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    RR_BACKUP_WORK_DIR="$transaction_root"
    RR_RESTORE_ACTIVE="$transaction_root/active"
    RR_RESTORE_RUNTIME_READY="$transaction_root/runtime-ready"
    stage="$transaction_root/restore.exact"
    rollback="$stage/rollback"
    mkdir -p "$rollback/rootfs"
    chmod 700 "$stage"

    printf '%s\n' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        '-A INPUT -m comment --comment user-owned-drop -j DROP' \
        '-A INPUT -p udp --dport 61112 -m comment --comment argo-rr-managed-block -j DROP' \
        >> "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 62000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 61111' \
        > "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        >> "$MOCK_NETFILTER_ROOT/ip6tables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 62001 -m comment --comment argo-rr-TU5 -j REDIRECT --to-ports 61112' \
        > "$MOCK_NETFILTER_ROOT/ip6tables.nat"
    printf '%s\n' \
        'allow|61111/tcp|argo-rr-managed' \
        'deny|61112/udp|argo-rr-managed-block' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program

    rr_restore_capture_firewall_snapshot "$rollback"
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/original-v4-filter"
    cp "$MOCK_NETFILTER_ROOT/iptables.nat" "$transaction_root/original-v4-nat"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/original-v6-filter"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.nat" "$transaction_root/original-v6-nat"
    cp "$MOCK_UFW_RULES" "$transaction_root/original-ufw"
    rr_restore_capture_ufw_rules "$transaction_root/original-ufw-program" || \
        fail 'could not capture original UFW normalization program'

    rr_restore_clear_managed_firewall
    printf '%s\n' \
        '-A INPUT -p tcp --dport 63333 -m comment --comment argo-rr-managed -j ACCEPT' \
        >> "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 63000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 63333' \
        >> "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' 'allow|63333/tcp|argo-rr-managed' >> "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    : > "$rollback/complete"
    (umask 077; printf '%s\n' "$stage" > "$RR_RESTORE_ACTIVE")

    rr_restore_write_phase() {
        (umask 077; printf '%s\n' "$2" > "$stage/phase")
    }
    rr_restore_stop_managed_runtime() { return 0; }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    # IP-ACME replay is covered by its dedicated restore suite.  Keep this
    # transaction focused on exact firewall rollback and late verification.
    rr_restore_replace_target_ip_acme_state() { return 0; }
    rr_restore_rearm_target_ip_acme() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    RR_TEST_MIGRATION_REACHED=false
    rr_restore_migrate_with_original_state() {
        RR_TEST_MIGRATION_REACHED=true
        : > "$MOCK_NETFILTER_WRITE_LOG"
        : > "$MOCK_UFW_WRITE_LOG"
    }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }

    rr_restore_rollback_stage "$stage"
    [ "$RR_TEST_MIGRATION_REACHED" = true ] || \
        fail 'rollback did not reach transaction-mode migration'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'post-migration firewall verification wrote netfilter state'
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'post-migration firewall verification wrote UFW state'
    rr_restore_capture_ufw_rules "$transaction_root/current-ufw-program" || \
        fail 'could not capture restored UFW normalization program'
    rr_restore_normalize_full_firewall_program filter iptables \
        "$transaction_root/original-v4-filter" "$transaction_root/original-ufw-program" \
        "$transaction_root/original-v4-filter.normalized" || \
        fail 'could not normalize original IPv4 filter projection'
    rr_restore_normalize_full_firewall_program filter iptables \
        "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/current-ufw-program" \
        "$transaction_root/current-v4-filter.normalized" || \
        fail 'could not normalize restored IPv4 filter projection'
    cmp -s "$transaction_root/original-v4-filter.normalized" \
        "$transaction_root/current-v4-filter.normalized" || \
        fail 'IPv4 unmanaged filter projection rollback was not exact'
    cmp -s "$transaction_root/original-v4-nat" "$MOCK_NETFILTER_ROOT/iptables.nat" || \
        fail 'IPv4 NAT rollback was not exact'
    rr_restore_normalize_full_firewall_program filter ip6tables \
        "$transaction_root/original-v6-filter" "$transaction_root/original-ufw-program" \
        "$transaction_root/original-v6-filter.normalized" || \
        fail 'could not normalize original IPv6 filter projection'
    rr_restore_normalize_full_firewall_program filter ip6tables \
        "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/current-ufw-program" \
        "$transaction_root/current-v6-filter.normalized" || \
        fail 'could not normalize restored IPv6 filter projection'
    cmp -s "$transaction_root/original-v6-filter.normalized" \
        "$transaction_root/current-v6-filter.normalized" || \
        fail 'IPv6 unmanaged filter projection rollback was not exact'
    cmp -s "$transaction_root/original-v6-nat" "$MOCK_NETFILTER_ROOT/ip6tables.nat" || \
        fail 'IPv6 NAT rollback was not exact'
    cmp -s "$transaction_root/original-ufw" "$MOCK_UFW_RULES" || \
        fail 'UFW rollback was not exact'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" '63333'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.nat" '63000'
    [ ! -e "$RR_RESTORE_ACTIVE" ] || fail 'rollback left the active marker behind'
)

# A direct administrator/UFW reorder during service reconstruction is outside
# RR's flock domain, so the late whole-program verifier must catch it before a
# rollback can publish a terminal success state.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    RR_BACKUP_WORK_DIR="$transaction_root"
    RR_RESTORE_RUNTIME_READY="$transaction_root/runtime-ready"
    stage="$transaction_root/restore.lateufworder"
    rollback="$stage/rollback"
    mkdir -p "$rollback/rootfs"
    chmod 700 "$stage"
    printf '%s\n' \
        'allow|61121/tcp|argo-rr-managed' \
        'allow|22/tcp|user-owned-ssh' \
        'deny|61122/udp|argo-rr-managed-block' \
        'allow|53/udp|user-owned-dns' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    : > "$rollback/complete"
    rr_restore_clear_managed_firewall "$rollback/firewall"
    printf '%s\n' 'allow|63334/tcp|argo-rr-managed' >> "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    STOP_CALLS=0
    rr_restore_stop_managed_runtime() { STOP_CALLS=$((STOP_CALLS + 1)); }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_replace_target_ip_acme_state() { return 0; }
    rr_restore_rearm_target_ip_acme() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_rollback_claims_cloudflared() { return 1; }
    rr_restore_clear_marker() { rm -f -- "$1"; }
    rr_restore_publish_marker() { : > "$1"; }
    rr_restore_migrate_with_original_state() {
        local reordered="${MOCK_UFW_RULES}.reordered"
        awk 'NR==1 { first=$0; next } NR==2 { print; print first; next } { print }' \
            "$MOCK_UFW_RULES" > "$reordered" &&
            mv -f "$reordered" "$MOCK_UFW_RULES" &&
            sync_mock_ufw_filter_program
    }
    if rr_restore_rollback_stage "$stage" >/dev/null 2>&1; then
        fail 'late UFW combined-order change passed rollback terminal verification'
    fi
    late_phase=$(cat "$stage/phase" 2>/dev/null || printf missing)
    [ "$late_phase" = recovery_failed ] ||
        fail "late UFW reorder did not retain recovery_failed evidence (phase=$late_phase, stops=$STOP_CALLS)"
    [ "$STOP_CALLS" -ge 2 ] ||
        fail 'late UFW reorder did not re-stop services after verification failure'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'allow|61111/tcp|argo-rr-managed' \
        'deny|61111/tcp|user-owned-deny' > "$MOCK_UFW_RULES"
    cp "$MOCK_UFW_RULES" "$transaction_root/before"
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_capture_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'mixed RR/user UFW ordering was accepted without a restorable family-specific snapshot'
    fi
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'mixed UFW snapshot rejection wrote firewall state'
    cmp -s "$transaction_root/before" "$MOCK_UFW_RULES" || \
        fail 'mixed UFW snapshot rejection changed user rules'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'allow|61111/tcp|argo-rr-managed' \
        'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program

    rr_restore_capture_firewall_snapshot "$rollback"
    load_config_with_defaults() {
        VM_TLS_ENABLED=false
        SUB_PORT=61111
        VL_ENABLED=false
        HY2_ENABLED=false
        TU5_ENABLED=false
        AN_ENABLED=false
        NAIVE_ENABLED=false
        NEXUS_CONFIG_FILE="$transaction_root/no-nexus.json"
    }
    rr_restore_candidate_ufw_is_disjoint "$transaction_root/rollback" || \
        fail 'disjoint SSH and imported RR UFW ports were rejected'
    rr_restore_clear_managed_firewall
    printf '%s\n' 'allow|63333/tcp|argo-rr-managed' >> "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_restore_firewall_snapshot "$rollback"
    assert_rule "$MOCK_UFW_RULES" 'allow|22/tcp|user-owned-ssh'
    assert_rule "$MOCK_UFW_RULES" 'allow|61111/tcp|argo-rr-managed'
    assert_no_match "$MOCK_UFW_RULES" '63333'
)

# UFW-only rollback preserves the complete, non-lexicographic interleaving of
# RR and disjoint user rules by replaying managed entries at saved ordinals.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'deny|61212/udp|argo-rr-managed-block' \
        'allow|22/tcp|user-owned-ssh' \
        'allow|61111/tcp|argo-rr-managed' \
        'allow|53/udp|user-owned-dns' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    cp "$MOCK_UFW_RULES" "$transaction_root/ufw.before"
    rr_restore_capture_firewall_snapshot "$rollback"
    rr_restore_clear_managed_firewall "$rollback/firewall"
    printf '%s\n' 'allow|63333/tcp|argo-rr-managed' >> "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    force_missing_persistence_backend
    rr_restore_restore_firewall_snapshot "$rollback" ||
        fail 'UFW-only ordered rollback required a raw persistence backend'
    cmp -s "$transaction_root/ufw.before" "$MOCK_UFW_RULES" ||
        fail 'UFW rollback changed combined managed/user rule order'
    grep -q '^insert ' "$MOCK_UFW_WRITE_LOG" ||
        fail 'UFW ordered rollback appended instead of inserting saved ordinals'
)

# An ordered insert failure is visible and can never be accepted by the exact
# whole-program verifier.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'allow|61113/tcp|argo-rr-managed' \
        'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    rr_restore_clear_managed_firewall "$rollback/firewall"
    MOCK_UFW_WRITE_ATTEMPTS=0
    MOCK_UFW_FAIL_WRITE_SPECS='insert:1'
    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'failed UFW ordinal insert passed exact rollback verification'
    fi
)

# A writer that reports success but leaves the compiled live UFW chain
# duplicated/corrupt is rejected even when `ufw show added` is byte-exact.
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'allow|61114/tcp|argo-rr-managed' \
        'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    rr_restore_clear_managed_firewall "$rollback/firewall"
    eval "$(declare -f ufw | sed '1s/^ufw/original_ufw/')"
    ufw() {
        local result=0
        original_ufw "$@" || result=$?
        if [ "$result" -eq 0 ] && [ "${1:-}" = insert ]; then
            printf '%s\n' \
                '-A ufw-user-input -p tcp -m tcp --dport 61114 -j ACCEPT' \
                >> "$MOCK_NETFILTER_ROOT/iptables.filter"
        fi
        return "$result"
    }
    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'corrupt compiled UFW chain passed exact ordered rollback'
    fi
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' 'allow|15556/tcp|user-owned-public-port' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    load_config_with_defaults() {
        VM_TLS_ENABLED=false
        SUB_PORT=15556
        VL_ENABLED=false
        HY2_ENABLED=false
        TU5_ENABLED=false
        AN_ENABLED=false
        NAIVE_ENABLED=false
        NEXUS_CONFIG_FILE="$transaction_root/no-nexus.json"
    }
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_candidate_ufw_is_disjoint "$rollback" >/dev/null 2>&1; then
        fail 'a user UFW allow on the imported local-subscription port passed preflight'
    fi
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'candidate UFW conflict preflight wrote firewall state'
    assert_rule "$MOCK_UFW_RULES" 'allow|15556/tcp|user-owned-public-port'
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        '-A INPUT -p tcp --dport 15556 -m comment --comment user-owned-public-port -j ACCEPT' \
        '-A INPUT -p tcp --dport 24443 -m comment --comment user-owned-deny -j DROP' \
        > "$MOCK_NETFILTER_ROOT/iptables.filter"
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/before"
    rr_restore_capture_firewall_snapshot "$rollback"
    load_config_with_defaults() {
        VM_TLS_ENABLED=false
        SUB_PORT=15556
        VL_ENABLED=true
        VL_PORT=24443
        HY2_ENABLED=false
        TU5_ENABLED=false
        AN_ENABLED=false
        NAIVE_ENABLED=false
        NEXUS_CONFIG_FILE="$transaction_root/no-nexus.json"
    }
    : > "$MOCK_NETFILTER_WRITE_LOG"

    if rr_restore_candidate_netfilter_is_disjoint "$rollback" >/dev/null 2>&1; then
        fail 'same-port user netfilter ACCEPT/DROP rules passed candidate preflight'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'candidate netfilter conflict preflight wrote firewall state'
    cmp -s "$transaction_root/before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'candidate netfilter conflict preflight changed user rules'
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-P INPUT DROP' \
            '-A INPUT -p tcp --dport 22 -m comment --comment user-owned-ssh -j ACCEPT' \
            > "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    rr_restore_capture_firewall_snapshot "$rollback"
    load_config_with_defaults() { use_candidate_config; }
    rr_restore_candidate_netfilter_is_disjoint "$rollback" || \
        fail 'simple disjoint IPv4/IPv6 SSH rules were rejected'
)
for complex_case in multiport range catchall chain_jump input_return; do
    (
        setup_netfilter_mock
        transaction_root=$(mktemp -d)
        trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
        rollback="$transaction_root/rollback"
        case "$complex_case" in
            multiport)
                printf '%s\n' \
                    '-A INPUT -p tcp -m multiport --dports 22,15556 -j ACCEPT' \
                    > "$MOCK_NETFILTER_ROOT/iptables.filter"
                ;;
            range)
                printf '%s\n' '-A INPUT -p tcp --dport 15000:16000 -j DROP' \
                    > "$MOCK_NETFILTER_ROOT/ip6tables.filter"
                ;;
            catchall)
                printf '%s\n' '-A INPUT -j ACCEPT' \
                    > "$MOCK_NETFILTER_ROOT/iptables.filter"
                ;;
            chain_jump)
                printf '%s\n' \
                    '-N USER_GUARD' \
                    '-A INPUT -p tcp --dport 15556 -j USER_GUARD' \
                    '-A USER_GUARD -j DROP' \
                    > "$MOCK_NETFILTER_ROOT/ip6tables.filter"
                ;;
            input_return)
                printf '%s\n' '-A INPUT -p tcp --dport 15556 -j RETURN' \
                    > "$MOCK_NETFILTER_ROOT/iptables.filter"
                ;;
        esac
        cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/v4-before"
        cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/v6-before"
        rr_restore_capture_firewall_snapshot "$rollback"
        load_config_with_defaults() { use_candidate_config; }
        : > "$MOCK_NETFILTER_WRITE_LOG"
        if rr_restore_candidate_netfilter_is_disjoint "$rollback" >/dev/null 2>&1; then
            fail "ambiguous netfilter rule passed candidate preflight: $complex_case"
        fi
        [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
            fail "netfilter conflict preflight wrote rules: $complex_case"
        cmp -s "$transaction_root/v4-before" "$MOCK_NETFILTER_ROOT/iptables.filter" && \
            cmp -s "$transaction_root/v6-before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
            fail "netfilter conflict preflight changed live rules: $complex_case"
    )
done
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'allow|15556/tcp|argo-rr-managed' \
        'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    load_config_with_defaults() { use_candidate_config; }
    rr_restore_candidate_ufw_is_disjoint "$rollback" || \
        fail 'disjoint compiled UFW rule was rejected by show-added guard'
    rr_restore_candidate_netfilter_is_disjoint "$rollback" || \
        fail 'normal compiled RR UFW rule was mistaken for custom raw policy'
)
for ufw_custom_case in before_drop user_return user_catchall_return; do
    (
        setup_netfilter_mock
        setup_ufw_mock
        transaction_root=$(mktemp -d)
        trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
        rollback="$transaction_root/rollback"
        printf '%s\n' 'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
        case "$ufw_custom_case" in
            before_drop)
                custom_rule='-A ufw-before-input -p tcp --dport 15556 -j DROP'
                ;;
            user_return)
                custom_rule='-A ufw-user-input -p tcp --dport 15556 -j RETURN'
                ;;
            user_catchall_return)
                custom_rule='-A ufw-user-input -j RETURN'
                ;;
        esac
        for backend in iptables ip6tables; do
            write_mock_ufw_filter_program "$backend" "$custom_rule"
        done
        : > "$MOCK_NETFILTER_WRITE_LOG"
        : > "$MOCK_UFW_WRITE_LOG"
        if rr_restore_capture_firewall_snapshot "$rollback" >/dev/null 2>&1; then
            fail "custom live UFW policy entered a rollback snapshot: $ufw_custom_case"
        fi
        [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
            fail "custom UFW snapshot rejection wrote firewall state: $ufw_custom_case"
    )
done
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        '-A PREROUTING -p udp -m multiport --dports 22,25005 -j REDIRECT --to-ports 22' \
        > "$MOCK_NETFILTER_ROOT/iptables.nat"
    cp "$MOCK_NETFILTER_ROOT/iptables.nat" "$transaction_root/nat-before"
    rr_restore_capture_firewall_snapshot "$rollback"
    TEST_HY2_ENABLED=true
    TEST_HY2_HOP_PORTS=25000:25010
    load_config_with_defaults() { use_candidate_config; }
    : > "$MOCK_NETFILTER_WRITE_LOG"
    if rr_restore_candidate_netfilter_is_disjoint "$rollback" >/dev/null 2>&1; then
        fail 'overlapping user NAT multiport rule passed hop preflight'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'NAT conflict preflight wrote firewall state'
    cmp -s "$transaction_root/nat-before" "$MOCK_NETFILTER_ROOT/iptables.nat" || \
        fail 'NAT conflict preflight changed user rules'
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 30000:30010 -j REDIRECT --to-ports 22' \
        > "$MOCK_NETFILTER_ROOT/ip6tables.nat"
    rr_restore_capture_firewall_snapshot "$rollback"
    TEST_HY2_ENABLED=true
    TEST_HY2_HOP_PORTS=25000:25010
    load_config_with_defaults() { use_candidate_config; }
    rr_restore_candidate_netfilter_is_disjoint "$rollback" || \
        fail 'disjoint user NAT range was rejected'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' 'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    printf '%s\n' '-A ufw-before-input -p tcp --dport 15556 -j DROP' \
        >> "$MOCK_NETFILTER_ROOT/ip6tables.filter"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/live-before"
    PERSIST_CALLS=0
    netfilter-persistent() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"
    if rr_restore_verify_firewall_pre_mutation_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'post-snapshot UFW custom-chain injection passed live recapture'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] && \
        [ "$PERSIST_CALLS" -eq 0 ] || \
        fail 'live recapture conflict wrote or persisted firewall state'
    cmp -s "$transaction_root/live-before" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'live recapture conflict changed injected administrator rule'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        'allow|61111/tcp|argo-rr-managed' \
        'deny|Anywhere|user-owned-catch-all' > "$MOCK_UFW_RULES"
    cp "$MOCK_UFW_RULES" "$transaction_root/before"
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_capture_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'a catch-all user UFW rule was treated as provably disjoint from RR ports'
    fi
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'ambiguous UFW snapshot rejection wrote firewall state'
    cmp -s "$transaction_root/before" "$MOCK_UFW_RULES" || \
        fail 'ambiguous UFW snapshot rejection changed user rules'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    MOCK_UFW_ACTIVE=false
    for backend in iptables ip6tables; do
        printf '%s\n' '-P INPUT DROP' > "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    printf '%s\n' 'allow|22/tcp|user-owned-ssh' > "$MOCK_UFW_RULES"
    rr_restore_capture_firewall_snapshot "$rollback"
    MOCK_UFW_ACTIVE=true
    cp "$MOCK_UFW_RULES" "$transaction_root/before"
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'rollback accepted an inactive-to-active UFW backend transition'
    fi
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'rollback wrote UFW after detecting a backend-state transition'
    cmp -s "$transaction_root/before" "$MOCK_UFW_RULES" || \
        fail 'rollback changed newly active UFW rules'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    MOCK_UFW_ACTIVE=false
    printf '%s\n' 'deny|61111/tcp|argo-rr-managed-block' > "$MOCK_UFW_RULES"
    cp "$MOCK_UFW_RULES" "$transaction_root/before"
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_capture_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'inactive UFW persisted stale RR rules in a portable snapshot'
    fi
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'inactive stale UFW rejection wrote firewall state'
    cmp -s "$transaction_root/before" "$MOCK_UFW_RULES" || \
        fail 'inactive stale UFW rejection changed persistent rules'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' 'allow|61111/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    rr_restore_capture_firewall_snapshot "$rollback"
    MOCK_UFW_ACTIVE=false
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'rollback accepted an active-to-inactive UFW backend transition'
    fi
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'rollback wrote UFW after an active backend disappeared'
)
(
    transaction_root=$(mktemp -d)
    MOCK_NETFILTER_ROOT="$transaction_root/not-created"
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    if rr_restore_capture_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'portable snapshot accepted a target with no filter authority'
    fi
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        > "$MOCK_NETFILTER_ROOT/iptables.filter"
    rr_restore_capture_firewall_snapshot "$rollback"
    printf '%s\n' firewall-snapshot-v1 > "$rollback/firewall/complete"
    : > "$MOCK_NETFILTER_WRITE_LOG"

    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'legacy v1 firewall evidence was guessed into a v2 rollback'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'legacy v1 firewall evidence caused a firewall write'
    [ -f "$rollback/firewall/complete" ] || \
        fail 'legacy v1 rejection discarded recovery evidence'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    mkdir -p "$rollback"
    printf '%s\n' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        > "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' 'allow|61111/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/filter-before"
    cp "$MOCK_UFW_RULES" "$transaction_root/ufw-before"
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"

    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'missing firewall snapshot evidence was treated as recoverable'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'missing firewall snapshot evidence caused firewall writes'
    cmp -s "$transaction_root/filter-before" "$MOCK_NETFILTER_ROOT/iptables.filter" && \
        cmp -s "$transaction_root/ufw-before" "$MOCK_UFW_RULES" || \
        fail 'missing firewall snapshot rejection changed live state'
    [ -d "$rollback" ] || fail 'missing firewall snapshot rejection discarded transaction evidence'
)
(
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$transaction_root"' EXIT
    RR_BACKUP_WORK_DIR="$transaction_root"
    RR_RESTORE_RUNTIME_READY="$transaction_root/runtime-ready"
    stage="$transaction_root/restore.late-failure"
    rollback="$stage/rollback"
    mkdir -p "$rollback/rootfs"
    : > "$rollback/complete"
    RR_TEST_STOP_CALLS=0

    rr_restore_write_phase() { printf '%s\n' "$2" > "$stage/phase"; }
    rr_restore_stop_managed_runtime() {
        RR_TEST_STOP_CALLS=$((RR_TEST_STOP_CALLS + 1))
        return 0
    }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_replace_target_ip_acme_state() { return 0; }
    rr_restore_rearm_target_ip_acme() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_migrate_with_original_state() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 1; }
    rr_restore_publish_marker() { printf '%s\n' "$2" > "$1"; }
    rr_restore_clear_marker() { rm -f -- "$1"; }

    if rr_restore_rollback_stage "$stage" >/dev/null 2>&1; then
        fail 'late read-only firewall verification failure reported rollback success'
    fi
    [ "$RR_TEST_STOP_CALLS" -eq 2 ] || \
        fail 'late firewall verification failure did not re-stop managed runtime'
    [ ! -e "$RR_RESTORE_RUNTIME_READY" ] || \
        fail 'late firewall verification failure left the runtime gate open'
    [ "$(cat "$stage/phase")" = recovery_failed ] || \
        fail 'late firewall verification failure did not retain recovery evidence'
)
(
    setup_netfilter_mock
    transaction_root=$(mktemp -d)
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$transaction_root"' EXIT
    rollback="$transaction_root/rollback"
    printf '%s\n' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        '-A INPUT -m comment --comment user-owned-drop -j DROP' \
        > "$MOCK_NETFILTER_ROOT/iptables.filter"
    rr_restore_capture_firewall_snapshot "$rollback"
    rr_restore_clear_managed_firewall
    printf '%s\n' \
        '-A INPUT -p tcp --dport 63333 -m comment --comment argo-rr-managed -j ACCEPT' \
        '-A INPUT -p tcp --dport 22 -m comment --comment concurrent-user -j ACCEPT' \
        >> "$MOCK_NETFILTER_ROOT/iptables.filter"
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/before"
    : > "$MOCK_NETFILTER_WRITE_LOG"

    if rr_restore_restore_firewall_snapshot "$rollback" >/dev/null 2>&1; then
        fail 'rollback ignored a concurrent user-chain change'
    fi
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'rollback mutated rules after detecting a concurrent user-chain change'
    cmp -s "$transaction_root/before" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'rollback clobbered a concurrent user-chain change'
)

printf '%s\n' '[7/9] transaction accepts only the exact legacy local-subscription rule without mutation'
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    VM_TLS_ENABLED=false
    SUB_ACCESS_MODE=local
    SUB_PORT=15553
    RR_UPDATE_TRANSACTION=1
    RR_PORTABLE_RESTORE=1
    RR_PORTABLE_UFW_AUTHORITY=1
    RR_RESTORE_LOCK_HELD=1
    RR_FIREWALL_FINALIZE_REQUIRED=false
    printf '%s\n' 'deny|15553/tcp|argo-rr-managed-block' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"

    open_firewall || fail 'UFW-authoritative local-subscription DENY failed tx validation'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] && [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'UFW-authoritative local-subscription validator wrote firewall state'
    [ "$RR_FIREWALL_FINALIZE_REQUIRED" = false ] || \
        fail 'exact UFW DENY incorrectly requested legacy finalization'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    VM_TLS_ENABLED=false
    SUB_ACCESS_MODE=local
    SUB_PORT=15554
    RR_UPDATE_TRANSACTION=1
    RR_FIREWALL_FINALIZE_REQUIRED=false
    rr_local_subscription_loopback_ready() { return 0; }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 15554 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$MOCK_NETFILTER_ROOT/${backend}.before"
    done
    printf '%s\n' 'allow|15554/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    for backend in iptables ip6tables; do
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$MOCK_NETFILTER_ROOT/${backend}.before"
    done
    cp "$MOCK_UFW_RULES" "$MOCK_UFW_ROOT/before"
    : > "$MOCK_NETFILTER_WRITE_LOG"
    : > "$MOCK_UFW_WRITE_LOG"

    open_firewall || fail 'exact v7.1.0 subscription ACCEPT was not admitted temporarily'
    [ "$RR_FIREWALL_FINALIZE_REQUIRED" = true ] || \
        fail 'legacy rule did not request a post-commit finalizer'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'transaction validator issued a netfilter write that happened to cancel out'
    [ ! -s "$MOCK_UFW_WRITE_LOG" ] || \
        fail 'transaction validator issued a UFW write that happened to cancel out'
    for backend in iptables ip6tables; do
        cmp -s "$MOCK_NETFILTER_ROOT/${backend}.before" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail 'transaction changed a legacy netfilter rule'
    done
    cmp -s "$MOCK_UFW_ROOT/before" "$MOCK_UFW_RULES" || \
        fail 'transaction changed a legacy UFW rule'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    VM_TLS_ENABLED=false
    SUB_ACCESS_MODE=local
    SUB_PORT=15554
    RR_UPDATE_TRANSACTION=1
    RR_FIREWALL_FINALIZE_REQUIRED=false
    rr_local_subscription_loopback_ready() { return 0; }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 15554 -m comment --comment attacker-owned -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    # A comment merely containing the RR marker must not be treated as the
    # exact legacy UFW rule either.
    printf '%s\n' 'allow|15554/tcp|attacker-argo-rr-managed' > "$MOCK_UFW_RULES"
    if open_firewall >/dev/null 2>&1; then
        fail 'an arbitrary public allow rule passed the legacy exception'
    fi
    [ "$RR_FIREWALL_FINALIZE_REQUIRED" = false ] || \
        fail 'rejected arbitrary rule requested finalization'
)
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    VM_TLS_ENABLED=false
    SUB_ACCESS_MODE=local
    SUB_PORT=15554
    RR_UPDATE_TRANSACTION=1
    RR_FIREWALL_FINALIZE_REQUIRED=false
    rr_local_subscription_loopback_ready() { return 1; }
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 15554 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    printf '%s\n' 'allow|15554/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program
    if open_firewall >/dev/null 2>&1; then
        fail 'legacy ACCEPT passed without a proven loopback-only replacement service'
    fi
)

printf '%s\n' '[8/9] local subscription mode removes stale public allow rules'
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    VM_TLS_ENABLED=false
    SUB_ACCESS_MODE=local
    SUB_PORT=15555
    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-A INPUT -p tcp --dport 15555 -m comment --comment argo-rr-managed -j ACCEPT' \
            >> "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    printf '%s\n' 'allow|15555/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    sync_mock_ufw_filter_program

    open_firewall || fail 'local subscription close transaction failed'
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            'argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 15555 -m comment --comment argo-rr-managed-block -j DROP'
    done
    assert_no_match "$MOCK_UFW_RULES" 'allow|15555/tcp|argo-rr-managed'
    assert_rule "$MOCK_UFW_RULES" 'deny|15555/tcp|argo-rr-managed-block'

    SUB_ACCESS_MODE=https
    open_firewall || fail 'public subscription open transaction failed'
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 15555 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            'argo-rr-managed-block -j DROP'
    done
)

printf '%s\n' '[9/9] portable restore rebuilds only the imported RR desired set'
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    PERSIST_CALLS=0
    netfilter-persistent() {
        [ "${1:-}" = save ] || return 2
        PERSIST_CALLS=$((PERSIST_CALLS + 1))
    }
    load_config_with_defaults() {
        VM_TLS_ENABLED=false
        SUB_ACCESS_MODE=local
        SUB_PORT=15556
        VL_ENABLED=true
        VL_PORT=24443
        HY2_ENABLED=true
        HY2_PORT=24444
        HY2_HOP_PORTS=25000:25001
        TU5_ENABLED=false
        TU5_HOP_PORTS=
        AN_ENABLED=false
        NAIVE_ENABLED=false
        NEXUS_CONFIG_FILE="$MOCK_NETFILTER_ROOT/no-nexus.json"
    }
    install_hop_rules() {
        local label="$1" main_port="$2" spec="$3" backend=""
        for backend in iptables ip6tables; do
            "$backend" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j REDIRECT \
                --to-ports "$main_port" >/dev/null 2>&1 ||
                "$backend" -w 5 -t nat -A PREROUTING -p udp --dport "$spec" \
                    -m comment --comment "argo-rr-${label}" -j REDIRECT \
                    --to-ports "$main_port" >/dev/null 2>&1
        done
    }
    rr_validate_hop_rules() {
        local label="$1" main_port="$2" spec="$3" backend=""
        for backend in iptables ip6tables; do
            "$backend" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j REDIRECT \
                --to-ports "$main_port" >/dev/null 2>&1 || return 1
        done
    }

    for backend in iptables ip6tables; do
        printf '%s\n' \
            '-P INPUT DROP' \
            '-A INPUT -p tcp --dport 65001 -m comment --comment user-firewall-sentinel -j ACCEPT' \
            '-A INPUT -p tcp --dport 65002 -m comment --comment argo-rr-managed -j ACCEPT' \
            > "$MOCK_NETFILTER_ROOT/${backend}.filter"
        printf '%s\n' \
            '-A PREROUTING -p udp --dport 65003 -m comment --comment user-nat-sentinel -j REDIRECT --to-ports 22' \
            '-A PREROUTING -p udp --dport 65004 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 65002' \
            > "$MOCK_NETFILTER_ROOT/${backend}.nat"
    done

    rr_restore_clear_managed_firewall
    RR_UPDATE_TRANSACTION=0 open_configured_firewall
    for backend in iptables ip6tables; do
        filter_file="$MOCK_NETFILTER_ROOT/${backend}.filter"
        nat_file="$MOCK_NETFILTER_ROOT/${backend}.nat"
        assert_no_match "$filter_file" '65002'
        assert_no_match "$nat_file" '65004'
        assert_rule "$filter_file" \
            '-A INPUT -p tcp --dport 65001 -m comment --comment user-firewall-sentinel -j ACCEPT'
        assert_rule "$nat_file" \
            '-A PREROUTING -p udp --dport 65003 -m comment --comment user-nat-sentinel -j REDIRECT --to-ports 22'
        [ "$(grep -Fxc -- '-A INPUT -p tcp --dport 15556 -m comment --comment argo-rr-managed-block -j DROP' "$filter_file")" -eq 1 ] || \
            fail "local subscription DROP was not exact-once for $backend"
        [ "$(grep -Fxc -- '-A INPUT -p tcp --dport 24443 -m comment --comment argo-rr-managed -j ACCEPT' "$filter_file")" -eq 1 ] || \
            fail "VLESS rule was not exact-once for $backend"
        [ "$(grep -Fxc -- '-A INPUT -p udp --dport 24444 -m comment --comment argo-rr-managed -j ACCEPT' "$filter_file")" -eq 1 ] || \
            fail "HY2 rule was not exact-once for $backend"
        [ "$(grep -Fxc -- '-A PREROUTING -p udp --dport 25000:25001 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 24444' "$nat_file")" -eq 1 ] || \
            fail "HY2 hop rule was not exact-once for $backend"
        cp "$filter_file" "$filter_file.before-read-only"
        cp "$nat_file" "$nat_file.before-read-only"
    done
    persisted_before="$PERSIST_CALLS"
    : > "$MOCK_NETFILTER_WRITE_LOG"

    RR_UPDATE_TRANSACTION=1 open_configured_firewall
    [ "$PERSIST_CALLS" -eq "$persisted_before" ] || \
        fail 'transaction validator persisted the firewall'
    [ ! -s "$MOCK_NETFILTER_WRITE_LOG" ] || \
        fail 'transaction firewall validation issued a netfilter write'
    for backend in iptables ip6tables; do
        cmp -s "$MOCK_NETFILTER_ROOT/${backend}.filter.before-read-only" \
            "$MOCK_NETFILTER_ROOT/${backend}.filter" || \
            fail "transaction validator changed $backend filter rules"
        cmp -s "$MOCK_NETFILTER_ROOT/${backend}.nat.before-read-only" \
            "$MOCK_NETFILTER_ROOT/${backend}.nat" || \
            fail "transaction validator changed $backend NAT rules"
    done
)
(
    setup_netfilter_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    load_config_with_defaults() {
        VM_TLS_ENABLED=false
        SUB_ACCESS_MODE=local
        SUB_PORT=15557
        VL_ENABLED=false
        HY2_ENABLED=false
        HY2_HOP_PORTS=
        TU5_ENABLED=false
        TU5_HOP_PORTS=
        AN_ENABLED=false
        NAIVE_ENABLED=false
        NEXUS_CONFIG_FILE="$MOCK_NETFILTER_ROOT/no-nexus.json"
    }
    netfilter-persistent() { return 41; }
    if RR_UPDATE_TRANSACTION=0 open_configured_firewall >/dev/null 2>&1; then
        fail 'portable restore reconciliation hid a persistence failure'
    fi
)

printf '%s\n' 'Firewall transaction regressions passed.'
