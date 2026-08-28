#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' modules/00-runtime.sh)
eval "$runtime_constants"
# shellcheck disable=SC1091
source modules/10-system.sh
# shellcheck disable=SC1091
source modules/55-resilience.sh

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

setup_netfilter_mock() {
    MOCK_NETFILTER_ROOT=$(mktemp -d)
    : > "$MOCK_NETFILTER_ROOT/iptables.filter"
    : > "$MOCK_NETFILTER_ROOT/iptables.nat"
    : > "$MOCK_NETFILTER_ROOT/ip6tables.filter"
    : > "$MOCK_NETFILTER_ROOT/ip6tables.nat"
    MOCK_FAIL_WRITE_BACKEND=""
    MOCK_SKIP_WRITE_BACKEND=""

    mock_netfilter() {
        local backend="$1" table=filter operation="" chain="" line="" argument="" file="" temporary=""
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
                    fi
                done < "$file"
                ;;
            -C|-A|-I|-D)
                chain="${1:-}"
                [ -n "$chain" ] || return 2
                shift
                line="-A $chain"
                for argument in "$@"; do line+=" $argument"; done
                case "$operation" in
                    -C) grep -Fqx -- "$line" "$file" ;;
                    -A|-I)
                        [ "$MOCK_FAIL_WRITE_BACKEND" != "$backend" ] || return 42
                        [ "$MOCK_SKIP_WRITE_BACKEND" != "$backend" ] || return 0
                        temporary="${file}.tmp.$$"
                        if [ "$operation" = -I ]; then
                            { printf '%s\n' "$line"; cat "$file"; } > "$temporary"
                        else
                            { cat "$file"; printf '%s\n' "$line"; } > "$temporary"
                        fi
                        mv -f "$temporary" "$file"
                        ;;
                    -D)
                        [ "$MOCK_FAIL_WRITE_BACKEND" != "$backend" ] || return 42
                        temporary="${file}.tmp.$$"
                        awk -v wanted="$line" '
                            !removed && $0 == wanted { removed=1; next }
                            { print }
                            END { if (!removed) exit 1 }
                        ' "$file" > "$temporary" || { rm -f "$temporary"; return 1; }
                        mv -f "$temporary" "$file"
                        ;;
                esac
                ;;
            *) return 2 ;;
        esac
    }
    iptables() { mock_netfilter iptables "$@"; }
    ip6tables() { mock_netfilter ip6tables "$@"; }
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
    MOCK_UFW_FAIL_WRITE=false
    MOCK_UFW_SKIP_WRITE=false

    ufw() {
        local operation="" action="" rule="" marker="" line="" temporary=""
        if [ "${1:-}" = status ]; then
            if [ "$MOCK_UFW_ACTIVE" = true ]; then
                printf '%s\n' 'Status: active'
                while IFS='|' read -r action rule marker; do
                    [ -n "$action" ] || continue
                    printf '%s %s Anywhere # %s\n' "$rule" "${action^^}" "$marker"
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
        [ "${1:-}" = --force ] && shift
        operation=add
        if [ "${1:-}" = delete ]; then operation=delete; shift; fi
        action="${1:-}"; rule="${2:-}"
        [ "${3:-}" = comment ] || return 2
        marker="${4:-}"
        line="${action}|${rule}|${marker}"
        [ "$MOCK_UFW_FAIL_WRITE" = false ] || return 42
        [ "$MOCK_UFW_SKIP_WRITE" = false ] || return 0
        if [ "$operation" = add ]; then
            grep -Fqx -- "$line" "$MOCK_UFW_RULES" || printf '%s\n' "$line" >> "$MOCK_UFW_RULES"
            return 0
        fi
        temporary="${MOCK_UFW_RULES}.tmp.$$"
        awk -v wanted="$line" '
            !removed && $0 == wanted { removed=1; next }
            { print }
            END { if (!removed) exit 1 }
        ' "$MOCK_UFW_RULES" > "$temporary" || { rm -f "$temporary"; return 1; }
        mv -f "$temporary" "$MOCK_UFW_RULES"
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

printf '%s\n' '[1/8] netfilter success and persistence'
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

printf '%s\n' '[2/8] backend and post-write verification failures'
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

printf '%s\n' '[3/8] persistence failure and missing persistence backend'
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
    trap 'rm -rf "$MOCK_NETFILTER_ROOT"' EXIT
    open_protocol_firewall 34444 tcp
)

printf '%s\n' '[4/8] active and inactive UFW behavior'
(
    setup_ufw_mock
    trap 'rm -rf "$MOCK_UFW_ROOT"' EXIT
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
    setup_ufw_mock
    trap 'rm -rf "$MOCK_UFW_ROOT"' EXIT
    MOCK_UFW_ACTIVE=false
    MOCK_UFW_FAIL_WRITE=true
    open_protocol_firewall 44445 tcp
)

printf '%s\n' '[5/8] desired-set cleanup preserves user rules'
(
    setup_netfilter_mock
    setup_ufw_mock
    trap 'rm -rf "$MOCK_NETFILTER_ROOT" "$MOCK_UFW_ROOT"' EXIT
    printf '%s\n' \
        '-A INPUT -p tcp --dport 22 -m comment --comment user-owned -j ACCEPT' \
        '-A INPUT -p tcp --dport 51111 -m comment --comment argo-rr-managed -j ACCEPT' \
        > "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 51000 -m comment --comment user-hop -j REDIRECT --to-ports 22' \
        '-A PREROUTING -p udp --dport 52000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 51111' \
        > "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' 'allow|22/tcp|user-owned' 'allow|51111/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"

    rr_restore_clear_managed_firewall
    assert_rule "$MOCK_NETFILTER_ROOT/iptables.filter" \
        '-A INPUT -p tcp --dport 22 -m comment --comment user-owned -j ACCEPT'
    assert_rule "$MOCK_NETFILTER_ROOT/iptables.nat" \
        '-A PREROUTING -p udp --dport 51000 -m comment --comment user-hop -j REDIRECT --to-ports 22'
    assert_rule "$MOCK_UFW_RULES" 'allow|22/tcp|user-owned'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" '51111'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.nat" '52000'
    assert_no_match "$MOCK_UFW_RULES" '51111'

    open_protocol_firewall 53333 tcp
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" '51111'
    assert_rule "$MOCK_NETFILTER_ROOT/iptables.filter" \
        '-A INPUT -p tcp --dport 53333 -m comment --comment argo-rr-managed -j ACCEPT'
)

printf '%s\n' '[6/8] restore rollback replaces candidate RR rules exactly'
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
        '-A INPUT -p tcp --dport 22 -m comment --comment user-owned -j ACCEPT' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        '-A INPUT -p udp --dport 61112 -m comment --comment argo-rr-managed-block -j DROP' \
        > "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 62000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 61111' \
        > "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' \
        '-A INPUT -p tcp --dport 61111 -m comment --comment argo-rr-managed -j ACCEPT' \
        > "$MOCK_NETFILTER_ROOT/ip6tables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 62001 -m comment --comment argo-rr-TU5 -j REDIRECT --to-ports 61112' \
        > "$MOCK_NETFILTER_ROOT/ip6tables.nat"
    printf '%s\n' 'allow|22/tcp|user-owned' 'allow|61111/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"

    rr_restore_capture_firewall_snapshot "$rollback"
    cp "$MOCK_NETFILTER_ROOT/iptables.filter" "$transaction_root/original-v4-filter"
    cp "$MOCK_NETFILTER_ROOT/iptables.nat" "$transaction_root/original-v4-nat"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.filter" "$transaction_root/original-v6-filter"
    cp "$MOCK_NETFILTER_ROOT/ip6tables.nat" "$transaction_root/original-v6-nat"
    cp "$MOCK_UFW_RULES" "$transaction_root/original-ufw"

    rr_restore_clear_managed_firewall
    printf '%s\n' \
        '-A INPUT -p tcp --dport 63333 -m comment --comment argo-rr-managed -j ACCEPT' \
        >> "$MOCK_NETFILTER_ROOT/iptables.filter"
    printf '%s\n' \
        '-A PREROUTING -p udp --dport 63000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 63333' \
        >> "$MOCK_NETFILTER_ROOT/iptables.nat"
    printf '%s\n' 'allow|63333/tcp|argo-rr-managed' >> "$MOCK_UFW_RULES"
    : > "$rollback/complete"
    printf '%s\n' "$stage" > "$RR_RESTORE_ACTIVE"

    rr_restore_write_phase() { printf '%s\n' "$2" > "$stage/phase"; }
    rr_restore_stop_managed_runtime() { return 0; }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_migrate_with_original_state() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }

    rr_restore_rollback_stage "$stage"
    cmp -s "$transaction_root/original-v4-filter" "$MOCK_NETFILTER_ROOT/iptables.filter" || \
        fail 'IPv4 filter rollback was not exact'
    cmp -s "$transaction_root/original-v4-nat" "$MOCK_NETFILTER_ROOT/iptables.nat" || \
        fail 'IPv4 NAT rollback was not exact'
    cmp -s "$transaction_root/original-v6-filter" "$MOCK_NETFILTER_ROOT/ip6tables.filter" || \
        fail 'IPv6 filter rollback was not exact'
    cmp -s "$transaction_root/original-v6-nat" "$MOCK_NETFILTER_ROOT/ip6tables.nat" || \
        fail 'IPv6 NAT rollback was not exact'
    cmp -s "$transaction_root/original-ufw" "$MOCK_UFW_RULES" || \
        fail 'UFW rollback was not exact'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.filter" '63333'
    assert_no_match "$MOCK_NETFILTER_ROOT/iptables.nat" '63000'
    [ ! -e "$RR_RESTORE_ACTIVE" ] || fail 'rollback left the active marker behind'
)

printf '%s\n' '[7/8] transaction accepts only the exact legacy local-subscription rule without mutation'
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
            > "$MOCK_NETFILTER_ROOT/${backend}.filter"
        cp "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            "$MOCK_NETFILTER_ROOT/${backend}.before"
    done
    printf '%s\n' 'allow|15554/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    cp "$MOCK_UFW_RULES" "$MOCK_UFW_ROOT/before"

    open_firewall || fail 'exact v7.1.0 subscription ACCEPT was not admitted temporarily'
    [ "$RR_FIREWALL_FINALIZE_REQUIRED" = true ] || \
        fail 'legacy rule did not request a post-commit finalizer'
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
            > "$MOCK_NETFILTER_ROOT/${backend}.filter"
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
            > "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    printf '%s\n' 'allow|15554/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"
    if open_firewall >/dev/null 2>&1; then
        fail 'legacy ACCEPT passed without a proven loopback-only replacement service'
    fi
)

printf '%s\n' '[8/8] local subscription mode removes stale public allow rules'
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
            > "$MOCK_NETFILTER_ROOT/${backend}.filter"
    done
    printf '%s\n' 'allow|15555/tcp|argo-rr-managed' > "$MOCK_UFW_RULES"

    open_firewall
    for backend in iptables ip6tables; do
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            'argo-rr-managed -j ACCEPT'
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 15555 -m comment --comment argo-rr-managed-block -j DROP'
    done
    assert_no_match "$MOCK_UFW_RULES" 'allow|15555/tcp|argo-rr-managed'
    assert_rule "$MOCK_UFW_RULES" 'deny|15555/tcp|argo-rr-managed-block'

    SUB_ACCESS_MODE=https
    open_firewall
    for backend in iptables ip6tables; do
        assert_rule "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            '-A INPUT -p tcp --dport 15555 -m comment --comment argo-rr-managed -j ACCEPT'
        assert_no_match "$MOCK_NETFILTER_ROOT/${backend}.filter" \
            'argo-rr-managed-block -j DROP'
    done
)

printf '%s\n' 'Firewall transaction regressions passed.'
