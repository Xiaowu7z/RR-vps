#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# Any regression that unexpectedly reaches the firewall crash gate must stay
# inside this repository-scoped scratch root.  Refuse to run if production
# paths already exist, and prove again on EXIT that the test never published
# a guard, marker, evidence file or service drop-in into the host.
SIDE_EFFECT_PRODUCTION_FIREWALL_PATHS=(
    /usr/local/sbin/rr-firewall-quarantine-guard
    /etc/systemd/system/rr-firewall-quarantine-guard.service
    /etc/systemd/system/rr-firewall-quarantine-guard.path
    /etc/systemd/system/rr-firewall-quarantine-guard.timer
    /var/lib/rr-vps/firewall-quarantine
    /var/lib/rr-vps/firewall-evidence
    /etc/systemd/system/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf
    /etc/systemd/system/rr-nexus.service.d/zzzzz-rr-firewall-quarantine.conf
    /etc/systemd/system/rr-subscription.service.d/zzzzz-rr-firewall-quarantine.conf
    /etc/systemd/system/argo-rr-health.service.d/zzzzz-rr-firewall-quarantine.conf
)
side_effect_production_firewall_absent() {
    local path=""
    for path in "${SIDE_EFFECT_PRODUCTION_FIREWALL_PATHS[@]}"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    done
}
side_effect_production_firewall_absent || {
    printf '%s\n' 'FAIL: production firewall guard state exists before isolated test' >&2
    exit 1
}
SIDE_EFFECT_FIREWALL_ROOT=$(mktemp -d \
    "$REPO_ROOT/test-side-effect-firewall.XXXXXX")
side_effect_firewall_cleanup() {
    local status=$?
    trap - EXIT
    if ! side_effect_production_firewall_absent; then
        printf '%s\n' 'FAIL: isolated test touched production firewall guard state' >&2
        status=1
    fi
    case "$SIDE_EFFECT_FIREWALL_ROOT" in
        "$REPO_ROOT"/test-side-effect-firewall.*)
            rm -rf -- "$SIDE_EFFECT_FIREWALL_ROOT" || status=1
            ;;
        *) status=1 ;;
    esac
    exit "$status"
}
trap side_effect_firewall_cleanup EXIT
export RR_FIREWALL_QUARANTINE_DIR="$SIDE_EFFECT_FIREWALL_ROOT/quarantine"
export RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/firewall-quarantine"
export RR_FIREWALL_SYSTEMD_DIR="$SIDE_EFFECT_FIREWALL_ROOT/systemd"
export RR_FIREWALL_GUARD_SCRIPT="$SIDE_EFFECT_FIREWALL_ROOT/bin/rr-firewall-quarantine-guard"
mkdir -p "$RR_FIREWALL_QUARANTINE_DIR" "$RR_FIREWALL_SYSTEMD_DIR" \
    "$(dirname "$RR_FIREWALL_GUARD_SCRIPT")"
chmod 700 "$RR_FIREWALL_QUARANTINE_DIR" \
    "$(dirname "$RR_FIREWALL_GUARD_SCRIPT")"
chmod 755 "$RR_FIREWALL_SYSTEMD_DIR"

runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' modules/00-runtime.sh)
eval "$runtime_constants"
# shellcheck disable=SC1091
source modules/10-system.sh
# shellcheck disable=SC1091
source modules/20-config.sh
# shellcheck disable=SC1091
source modules/30-singbox.sh
# shellcheck disable=SC1091
source modules/60-update.sh
# shellcheck disable=SC1091
source modules/70-protocols.sh
# shellcheck disable=SC1091
source modules/85-nexus.sh

pass_count=0
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$*"
}

APT_CALLS=0
CURL_CALLS=0
DPKG_CALLS=0
PIP_CALLS=0
CERTBOT_CALLS=0
SYS_ARCH=amd64
apt-get() { APT_CALLS=$((APT_CALLS + 1)); return 1; }
curl() { CURL_CALLS=$((CURL_CALLS + 1)); return 1; }
dpkg() { DPKG_CALLS=$((DPKG_CALLS + 1)); return 1; }
certbot() { CERTBOT_CALLS=$((CERTBOT_CALLS + 1)); return 1; }
cloudflared() { printf '%s\n' 'cloudflared version 2024.1.0'; }
nexus_dependencies_available() { return 1; }
nexus_install_verified_pypi_wheel() { PIP_CALLS=$((PIP_CALLS + 1)); return 1; }
# Never allow this regression to reach the host's system manager.  Blocks that
# exercise systemd contracts install stricter subshell-local mocks below.
systemctl() { return 97; }

RR_UPDATE_TRANSACTION=1
if install_deps >/dev/null 2>&1; then fail 'transaction install_deps unexpectedly succeeded'; fi
if install_cloudflared >/dev/null 2>&1; then fail 'transaction install_cloudflared unexpectedly succeeded'; fi
if install_singbox >/dev/null 2>&1; then fail 'transaction install_singbox unexpectedly succeeded'; fi
if nexus_install_dependencies >/dev/null 2>&1; then fail 'transaction nexus dependencies unexpectedly succeeded'; fi
if nexus_enable_public_https panel.example.invalid admin@example.invalid 443 >/dev/null 2>&1; then
    fail 'transaction Nexus certificate provisioning unexpectedly succeeded'
fi
missing_le_root=$(mktemp -d)
missing_naive_target=$(mktemp -d)
rm -rf "$missing_naive_target"
RR_LE_LIVE_ROOT="$missing_le_root"
RR_NAIVE_CERT_DIR="$missing_naive_target"
if ensure_naive_certificate naive.example.invalid admin@example.invalid >/dev/null 2>&1; then
    fail 'transaction Naive certificate provisioning unexpectedly succeeded'
fi
[ ! -e "$missing_naive_target" ] || fail 'transaction created Naive certificate state before rejecting it'
rm -rf "$missing_le_root"
[ "$APT_CALLS" -eq 0 ] && [ "$CURL_CALLS" -eq 0 ] && [ "$DPKG_CALLS" -eq 0 ] || \
    fail 'transaction dependency guards invoked apt/curl/dpkg'
[ "$PIP_CALLS" -eq 0 ] && [ "$CERTBOT_CALLS" -eq 0 ] || \
    fail 'transaction dependency guards invoked pip/certbot'
pass 'transaction dependency guards fail closed before install or download'

(
    hook_root=$(mktemp -d)
    trap 'rm -rf "$hook_root"' EXIT
    RR_RUNTIME_DIR="$hook_root/runtime"
    RR_LE_RENEW_HOOK_DIR="$hook_root/renewal-hooks/deploy"
    install -d -m 755 "$RR_RUNTIME_DIR/scripts"
    install -m 755 scripts/naive-cert-hook.sh "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    install -d -m 700 "$RR_LE_RENEW_HOOK_DIR"
    install -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
        "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"

    # This regression also runs as an ordinary CI user.  Preserve real file
    # type/mode/link data while mapping only fixture ownership to root:root,
    # which is the production contract enforced by the read-only validator.
    real_stat=$(type -P stat)
    stat() {
        local target="${!#}" value="" mode="" links=""
        case "$target" in
            "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"|\
            "$RR_LE_RENEW_HOOK_DIR"|\
            "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh")
                value=$("$real_stat" "$@") || return 1
                case "${2:-}" in
                    '%u:%g:%a')
                        IFS=: read -r _ _ mode <<< "$value"
                        printf '0:0:%s\n' "$mode"
                        return
                        ;;
                    '%u:%g:%a:%h')
                        IFS=: read -r _ _ mode links <<< "$value"
                        printf '0:0:%s:%s\n' "$mode" "$links"
                        return
                        ;;
                esac
                ;;
        esac
        "$real_stat" "$@"
    }

    state_before=$(find -P "$hook_root" -printf '%P|%y|%m|%i|%n|%s\n' | LC_ALL=C sort)
    rr_certificate_deploy_hook_is_current || fail 'current certificate deploy hook was rejected'
    state_after=$(find -P "$hook_root" -printf '%P|%y|%m|%i|%n|%s\n' | LC_ALL=C sort)
    [ "$state_before" = "$state_after" ] || fail 'hook validation mutated filesystem state'

    mv "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh" "$hook_root/hook.regular"
    ln -s "$hook_root/hook.regular" "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    if rr_certificate_deploy_hook_is_current; then fail 'symlinked certificate hook was accepted'; fi
    rm -f "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    mv "$hook_root/hook.regular" "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    mv "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" "$hook_root/source.regular"
    ln -s "$hook_root/source.regular" "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    if rr_certificate_deploy_hook_is_current; then fail 'symlinked hook source was accepted'; fi
    rm -f "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    mv "$hook_root/source.regular" "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    printf '%s\n' 'if then' > "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    chmod 755 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    install -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
        "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    if rr_certificate_deploy_hook_is_current; then fail 'invalid shell hook source was accepted'; fi
    install -m 755 scripts/naive-cert-hook.sh "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
    install -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
        "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    chmod 755 "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    if rr_certificate_deploy_hook_is_current; then fail 'executable hook with mode 0755 was accepted'; fi
    chmod 700 "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    ln "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh" "$hook_root/hardlink"
    if rr_certificate_deploy_hook_is_current; then fail 'hard-linked certificate hook was accepted'; fi
    rm -f "$hook_root/hardlink"
    printf '%s\n' '# content mismatch' >> "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    if rr_certificate_deploy_hook_is_current; then fail 'mismatched certificate hook was accepted'; fi
    install -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
        "$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
    ln -s missing "$RR_LE_RENEW_HOOK_DIR/rr-naive-cert.sh"
    if rr_certificate_deploy_hook_is_current; then fail 'dangling legacy certificate hook was accepted'; fi
)
pass 'Naive certificate hook validator is strict and read-only'

(
    probe_root=$(mktemp -d)
    trap 'rm -rf "$probe_root"' EXIT
    probe_webroot="$probe_root/webroot"
    probe_bin="$probe_root/bin"
    probe_log="$probe_root/curl.log"
    mkdir -p "$probe_webroot/.well-known/acme-challenge" "$probe_bin"
    chmod 700 "$probe_root"
    chmod 755 "$probe_webroot" "$probe_webroot/.well-known" \
        "$probe_webroot/.well-known/acme-challenge" "$probe_bin"
    cat > "$probe_bin/curl" <<'SH'
#!/bin/sh
set -eu
resolve='' url=''
seen_q=false seen_proxy=false seen_path=false seen_no_redirect=true
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) seen_q=true; shift ;;
        --noproxy) [ "$2" = '*' ]; seen_proxy=true; shift 2 ;;
        --path-as-is) seen_path=true; shift ;;
        --silent|--show-error|--fail-with-body) shift ;;
        --connect-timeout) [ "$2" = 2 ]; shift 2 ;;
        --max-time) [ "$2" = 5 ]; shift 2 ;;
        --max-filesize) [ "$2" = 1024 ]; shift 2 ;;
        --request) [ "$2" = GET ]; shift 2 ;;
        --resolve) resolve="$2"; shift 2 ;;
        --output) [ "$2" = - ]; shift 2 ;;
        --write-out) [ "$2" = '%{http_code}' ]; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        -L|--location) seen_no_redirect=false; shift ;;
        *) exit 91 ;;
    esac
done
[ "$seen_q:$seen_proxy:$seen_path:$seen_no_redirect" = true:true:true:true ]
case "$resolve" in
    probe.example.invalid:80:127.0.0.1|probe.example.invalid:80:'[::1]') ;;
    *) exit 92 ;;
esac
name=${url##*/}
printf '%s\n' "$resolve" >> "$RR_PROBE_TEST_LOG"
if [ "${RR_PROBE_TEST_SHADOW:-false}" = true ]; then
    printf '%s' shadow-route
else
    cat "$RR_PROBE_TEST_WEBROOT/.well-known/acme-challenge/$name"
fi
printf '%s' 200
SH
    chmod 755 "$probe_bin/curl"
    unset -f curl
    PATH="$probe_bin:$PATH"
    export RR_PROBE_TEST_WEBROOT="$probe_webroot" RR_PROBE_TEST_LOG="$probe_log"
    RR_PROBE_TEST_SHADOW=false
    export RR_PROBE_TEST_SHADOW
    rr_certbot_acme_effective_route_probe probe.example.invalid "$probe_webroot" ||
        fail 'exact v4/v6 effective ACME route probe was rejected'
    [ "$(wc -l < "$probe_log")" -eq 2 ] && \
        grep -Fxq 'probe.example.invalid:80:127.0.0.1' "$probe_log" && \
        grep -Fxq 'probe.example.invalid:80:[::1]' "$probe_log" ||
        fail 'effective route probe did not perform exact bounded v4 and v6 requests'
    if find "$probe_webroot/.well-known/acme-challenge" -mindepth 1 -print -quit |
        grep -q .; then
        fail 'successful effective route probe left a challenge file behind'
    fi
    RR_PROBE_TEST_SHADOW=true
    export RR_PROBE_TEST_SHADOW
    if rr_certbot_acme_effective_route_probe probe.example.invalid "$probe_webroot"; then
        fail 'shadowed Host route returned ready from the effective route probe'
    fi
    if find "$probe_webroot/.well-known/acme-challenge" -mindepth 1 -print -quit |
        grep -q .; then
        fail 'failed effective route probe left a challenge file behind'
    fi
    stale="$probe_webroot/.well-known/acme-challenge/rr-route-probe-v1_0123456789abcdefghijklmnopqrstuv"
    printf '%s' 'rr-route-probe-v1:0123456789abcdefghijklmnopqrstuvwxyzABCDEFG' > "$stale"
    chmod 644 "$stale"
    RR_PROBE_TEST_SHADOW=false
    export RR_PROBE_TEST_SHADOW
    rr_certbot_acme_effective_route_probe probe.example.invalid "$probe_webroot" ||
        fail 'safe SIGKILL probe residue did not converge on the next check'
    [ ! -e "$stale" ] || fail 'safe stale route probe was not removed'
    ln -s /etc/passwd "$stale"
    if rr_certbot_acme_effective_route_probe probe.example.invalid "$probe_webroot"; then
        fail 'linked stale route probe was accepted and removed'
    fi
    [ -L "$stale" ] || fail 'unsafe stale route probe was unexpectedly changed'
)
pass 'effective ACME route probe is bounded, dual-stack and cleanup-safe'

(
    runtime_root=$(mktemp -d)
    trap 'rm -rf "$runtime_root"' EXIT
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$runtime_root/certbot"
    chmod 755 "$runtime_root/certbot"
    PATH="$runtime_root:$PATH"
    unset -f certbot
    SERVICE_LOADED=true
    TIMER_LOADED=true
    TIMER_ENABLED=true
    TIMER_ACTIVE=true
    TIMER_TRIGGERS=certbot.service
    TIMER_NEXT_REALTIME=$(date -u -d '+1 day' '+%a %Y-%m-%d %H:%M:%S UTC')
    TIMER_NEXT_MONOTONIC='1h 5min'
    TIMER_FRAGMENT=/lib/systemd/system/certbot.timer
    TIMER_DROPINS=''
    TIMER_CONDITIONS=''
    TIMER_ASSERTS=''
    TIMER_CALENDAR='{ OnCalendar=*-*-* 00,12:00:00 ; next_elapse=mocked }'
    TIMER_RANDOMIZED_DELAY=12h
    TIMER_ACCURACY=1min
    TIMER_RANDOMIZED_OFFSET=0
    SYSTEMD_VERSION=255
    SERVICE_FRAGMENT=/lib/systemd/system/certbot.service
    SERVICE_DROPINS=''
    SERVICE_USER=''
    SERVICE_DYNAMIC_USER=no
    SERVICE_REMAIN_AFTER_EXIT=no
    SERVICE_PRIVATE_NETWORK=no
    SERVICE_ROOT_DIRECTORY=''
    SERVICE_ROOT_IMAGE=''
    SERVICE_PROTECT_SYSTEM=no
    SERVICE_READ_ONLY_PATHS=''
    SERVICE_INACCESSIBLE_PATHS=''
    SERVICE_BIND_PATHS=''
    SERVICE_BIND_READ_ONLY_PATHS=''
    SERVICE_TEMPORARY_FILESYSTEM=''
    SERVICE_NO_EXEC_PATHS=''
    SERVICE_NETWORK_NAMESPACE_PATH=''
    SERVICE_PRIVATE_USERS=no
    SERVICE_RESTRICT_ADDRESS_FAMILIES=''
    SERVICE_RESTRICT_NETWORK_INTERFACES=''
    SERVICE_RESTRICT_FILESYSTEMS=''
    SERVICE_SYSTEM_CALL_FILTER=''
    SERVICE_MOUNT_IMAGES=''
    SERVICE_EXTENSION_IMAGES=''
    SERVICE_EXTENSION_DIRECTORIES=''
    SERVICE_JOINS_NAMESPACE_OF=''
    SERVICE_IP_ADDRESS_DENY=''
    SERVICE_EXEC_START_MODE=single
    SERVICE_IGNORE_ERRORS=no
    SERVICE_EXEC_START_PRE=''
    SERVICE_EXEC_CONDITION=''
    SERVICE_CONDITIONS=''
    SERVICE_ASSERTS=''
    SERVICE_FRAGMENT_STATE='0:0:644:1:regular file'
    TIMER_FRAGMENT_STATE='0:0:644:1:regular file'
    ROUTE_READY=true
    ROUTE_DOMAIN=""
    runtime_real_stat=$(type -P stat)
    stat() {
        local target="${!#}"
        case "$target" in
            /lib/systemd/system/certbot.service|\
            /usr/lib/systemd/system/certbot.service)
                printf '%s\n' "$SERVICE_FRAGMENT_STATE"
                ;;
            /lib/systemd/system/certbot.timer|\
            /usr/lib/systemd/system/certbot.timer)
                printf '%s\n' "$TIMER_FRAGMENT_STATE"
                ;;
            *) "$runtime_real_stat" "$@" ;;
        esac
    }
    rr_certbot_acme_http_route_is_ready() {
        ROUTE_DOMAIN="${1:-}"
        [ "$ROUTE_READY" = true ]
    }
    systemctl() {
        case "$*" in
            '--version')
                printf 'systemd %s (mock)\n' "$SYSTEMD_VERSION"
                ;;
            'show certbot.service --property=LoadState --value')
                [ "$SERVICE_LOADED" = true ] && printf '%s\n' loaded || printf '%s\n' masked
                ;;
            'show certbot.service --property=FragmentPath --value')
                printf '%s\n' "$SERVICE_FRAGMENT"
                ;;
            'show certbot.service --property=DropInPaths --value')
                printf '%s\n' "$SERVICE_DROPINS"
                ;;
            'show certbot.service --property=ExecStart --value')
                certbot_mock=$(command -v certbot)
                printf '{ path=%s ; argv[]=%s -q renew ; ignore_errors=%s ; }' \
                    "$certbot_mock" "$certbot_mock" "$SERVICE_IGNORE_ERRORS"
                if [ "$SERVICE_EXEC_START_MODE" = multiple ]; then
                    printf ' { path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; }'
                fi
                printf '\n'
                ;;
            'show certbot.service --property=ExecStartPre --value')
                printf '%s\n' "$SERVICE_EXEC_START_PRE"
                ;;
            'show certbot.service --property=ExecCondition --value')
                printf '%s\n' "$SERVICE_EXEC_CONDITION"
                ;;
            'show certbot.service --property=Conditions --value')
                printf '%s\n' "$SERVICE_CONDITIONS"
                ;;
            'show certbot.service --property=Asserts --value')
                printf '%s\n' "$SERVICE_ASSERTS"
                ;;
            'show certbot.service --property=User --value')
                printf '%s\n' "$SERVICE_USER"
                ;;
            'show certbot.service --property=DynamicUser --value')
                printf '%s\n' "$SERVICE_DYNAMIC_USER"
                ;;
            'show certbot.service --property=RemainAfterExit --value')
                printf '%s\n' "$SERVICE_REMAIN_AFTER_EXIT"
                ;;
            'show certbot.service --property=PrivateNetwork --value')
                printf '%s\n' "$SERVICE_PRIVATE_NETWORK"
                ;;
            'show certbot.service --property=RootDirectory --value')
                printf '%s\n' "$SERVICE_ROOT_DIRECTORY"
                ;;
            'show certbot.service --property=RootImage --value')
                printf '%s\n' "$SERVICE_ROOT_IMAGE"
                ;;
            'show certbot.service --property=ProtectSystem --value')
                printf '%s\n' "$SERVICE_PROTECT_SYSTEM"
                ;;
            'show certbot.service --property=ReadOnlyPaths --value')
                printf '%s\n' "$SERVICE_READ_ONLY_PATHS"
                ;;
            'show certbot.service --property=InaccessiblePaths --value')
                printf '%s\n' "$SERVICE_INACCESSIBLE_PATHS"
                ;;
            'show certbot.service --property=BindPaths --value')
                printf '%s\n' "$SERVICE_BIND_PATHS"
                ;;
            'show certbot.service --property=BindReadOnlyPaths --value')
                printf '%s\n' "$SERVICE_BIND_READ_ONLY_PATHS"
                ;;
            'show certbot.service --property=TemporaryFileSystem --value')
                printf '%s\n' "$SERVICE_TEMPORARY_FILESYSTEM"
                ;;
            'show certbot.service --property=NoExecPaths --value')
                printf '%s\n' "$SERVICE_NO_EXEC_PATHS"
                ;;
            'show certbot.service --property=NetworkNamespacePath --value')
                printf '%s\n' "$SERVICE_NETWORK_NAMESPACE_PATH"
                ;;
            'show certbot.service --property=PrivateUsers --value')
                printf '%s\n' "$SERVICE_PRIVATE_USERS"
                ;;
            'show certbot.service --property=RestrictAddressFamilies --value')
                printf '%s\n' "$SERVICE_RESTRICT_ADDRESS_FAMILIES"
                ;;
            'show certbot.service --property=RestrictNetworkInterfaces --value')
                (( SYSTEMD_VERSION >= 250 )) || return 98
                printf '%s\n' "$SERVICE_RESTRICT_NETWORK_INTERFACES"
                ;;
            'show certbot.service --property=RestrictFileSystems --value')
                (( SYSTEMD_VERSION >= 250 )) || return 98
                printf '%s\n' "$SERVICE_RESTRICT_FILESYSTEMS"
                ;;
            'show certbot.service --property=SystemCallFilter --value')
                printf '%s\n' "$SERVICE_SYSTEM_CALL_FILTER"
                ;;
            'show certbot.service --property=MountImages --value')
                printf '%s\n' "$SERVICE_MOUNT_IMAGES"
                ;;
            'show certbot.service --property=ExtensionImages --value')
                printf '%s\n' "$SERVICE_EXTENSION_IMAGES"
                ;;
            'show certbot.service --property=ExtensionDirectories --value')
                (( SYSTEMD_VERSION >= 251 )) || return 98
                printf '%s\n' "$SERVICE_EXTENSION_DIRECTORIES"
                ;;
            'show certbot.service --property=JoinsNamespaceOf --value')
                printf '%s\n' "$SERVICE_JOINS_NAMESPACE_OF"
                ;;
            'show certbot.service --property=IPAddressDeny --value')
                printf '%s\n' "$SERVICE_IP_ADDRESS_DENY"
                ;;
            'show certbot.timer --property=LoadState --value')
                [ "$TIMER_LOADED" = true ] && printf '%s\n' loaded || printf '%s\n' not-found
                ;;
            'show certbot.timer --property=FragmentPath --value')
                printf '%s\n' "$TIMER_FRAGMENT"
                ;;
            'show certbot.timer --property=DropInPaths --value')
                printf '%s\n' "$TIMER_DROPINS"
                ;;
            'show certbot.timer --property=Conditions --value')
                printf '%s\n' "$TIMER_CONDITIONS"
                ;;
            'show certbot.timer --property=Asserts --value')
                printf '%s\n' "$TIMER_ASSERTS"
                ;;
            'show certbot.timer --property=Triggers --value')
                printf '%s\n' "$TIMER_TRIGGERS"
                ;;
            'show certbot.timer --property=NextElapseUSecRealtime --value')
                printf '%s\n' "$TIMER_NEXT_REALTIME"
                ;;
            'show certbot.timer --property=NextElapseUSecMonotonic --value')
                printf '%s\n' "$TIMER_NEXT_MONOTONIC"
                ;;
            'show certbot.timer --property=TimersCalendar --value')
                printf '%s\n' "$TIMER_CALENDAR"
                ;;
            'show certbot.timer --property=RandomizedDelayUSec --value')
                printf '%s\n' "$TIMER_RANDOMIZED_DELAY"
                ;;
            'show certbot.timer --property=AccuracyUSec --value')
                printf '%s\n' "$TIMER_ACCURACY"
                ;;
            'show certbot.timer --property=RandomizedOffsetUSec --value')
                printf '%s\n' "$TIMER_RANDOMIZED_OFFSET"
                ;;
            'is-enabled certbot.timer')
                [ "$TIMER_ENABLED" = true ] && printf '%s\n' enabled || return 1
                ;;
            'is-active --quiet certbot.timer') [ "$TIMER_ACTIVE" = true ] ;;
            *) return 1 ;;
        esac
    }
    rr_certbot_renewal_runtime_is_ready naive.example.invalid ||
        fail 'loaded, enabled and active Certbot runtime with a local route was rejected'
    [ "$ROUTE_DOMAIN" = naive.example.invalid ] ||
        fail 'Certbot renewal runtime did not bind the route proof to its lineage domain'
    SERVICE_FRAGMENT=/usr/lib/systemd/system/certbot.service
    TIMER_FRAGMENT=/usr/lib/systemd/system/certbot.timer
    SERVICE_USER=root
    SERVICE_ROOT_IMAGE=n/a
    TIMER_CALENDAR='*-*-* 00,12:00:00'
    for SYSTEMD_VERSION in 249 252 255; do
        rr_certbot_renewal_runtime_is_ready naive.example.invalid ||
            fail "systemd $SYSTEMD_VERSION merged-/usr Certbot runtime was rejected"
    done
    SYSTEMD_VERSION=258
    rr_certbot_renewal_runtime_is_ready naive.example.invalid ||
        fail 'systemd 258 zero randomized offset was rejected'
    SYSTEMD_VERSION=255
    SERVICE_FRAGMENT=/lib/systemd/system/certbot.service
    TIMER_FRAGMENT=/lib/systemd/system/certbot.timer
    SERVICE_USER=''
    SERVICE_ROOT_IMAGE=''
    TIMER_CALENDAR='{ OnCalendar=*-*-* 00,12:00:00 ; next_elapse=mocked }'
    SERVICE_LOADED=false
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'masked Certbot service passed renewal runtime validation'
    fi
    SERVICE_LOADED=true
    SERVICE_EXEC_START_MODE=multiple
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with multiple ExecStart commands passed validation'
    fi
    SERVICE_EXEC_START_MODE=single
    SERVICE_IGNORE_ERRORS=yes
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot ExecStart with ignore_errors=yes passed validation'
    fi
    SERVICE_IGNORE_ERRORS=no
    SERVICE_EXEC_CONDITION='{ path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; }'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a blocking ExecCondition passed validation'
    fi
    SERVICE_EXEC_CONDITION=''
    SERVICE_EXEC_START_PRE='{ path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; }'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a blocking ExecStartPre passed validation'
    fi
    SERVICE_EXEC_START_PRE=''
    SERVICE_CONDITIONS='ConditionPathExists=!/etc/never result=false'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with an effective unit Condition passed validation'
    fi
    SERVICE_CONDITIONS=''
    SERVICE_ASSERTS='AssertPathExists=/etc/never result=false'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with an effective unit Assert passed validation'
    fi
    SERVICE_ASSERTS=''
    SERVICE_USER=nobody
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service running as an unprivileged user passed validation'
    fi
    SERVICE_USER=''
    SERVICE_DYNAMIC_USER=yes
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'dynamically allocated Certbot service identity passed validation'
    fi
    SERVICE_DYNAMIC_USER=no
    SERVICE_REMAIN_AFTER_EXIT=yes
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with RemainAfterExit=yes passed validation'
    fi
    SERVICE_REMAIN_AFTER_EXIT=no
    SERVICE_PRIVATE_NETWORK=yes
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'network-isolated Certbot service passed renewal runtime validation'
    fi
    SERVICE_PRIVATE_NETWORK=no
    SERVICE_ROOT_DIRECTORY=/srv/chroot
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'chrooted Certbot service passed renewal runtime validation'
    fi
    SERVICE_ROOT_DIRECTORY=''
    SERVICE_PROTECT_SYSTEM=full
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'write-blocked Certbot service passed renewal runtime validation'
    fi
    SERVICE_PROTECT_SYSTEM=no
    SERVICE_READ_ONLY_PATHS=/etc/letsencrypt
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a read-only lineage path passed validation'
    fi
    SERVICE_READ_ONLY_PATHS=''
    SERVICE_BIND_PATHS='/etc/letsencrypt:/tmp/shadow-letsencrypt'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a bind-mounted lineage passed validation'
    fi
    SERVICE_BIND_PATHS=''
    SERVICE_PRIVATE_USERS=yes
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a private user namespace passed validation'
    fi
    SERVICE_PRIVATE_USERS=no
    SERVICE_RESTRICT_NETWORK_INTERFACES=lo
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with restricted network interfaces passed validation'
    fi
    SERVICE_RESTRICT_NETWORK_INTERFACES=''
    SERVICE_SYSTEM_CALL_FILTER='~@network-io'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a network-blocking syscall filter passed validation'
    fi
    SERVICE_SYSTEM_CALL_FILTER=''
    SERVICE_MOUNT_IMAGES='/tmp/lineage.raw:/etc/letsencrypt'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a mounted lineage image passed validation'
    fi
    SERVICE_MOUNT_IMAGES=''
    SERVICE_EXTENSION_IMAGES=/tmp/fake-certbot.raw
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a /usr extension image passed validation'
    fi
    SERVICE_EXTENSION_IMAGES=''
    SYSTEMD_VERSION=251
    SERVICE_EXTENSION_DIRECTORIES=/tmp/fake-certbot-extension
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with a /usr extension directory passed validation'
    fi
    SERVICE_EXTENSION_DIRECTORIES=''
    SYSTEMD_VERSION=255
    SERVICE_JOINS_NAMESPACE_OF=blocked-network.service
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service joining another unit namespace passed validation'
    fi
    SERVICE_JOINS_NAMESPACE_OF=''
    SYSTEMD_VERSION=250
    SERVICE_RESTRICT_FILESYSTEMS=ext4
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with restricted filesystems passed validation'
    fi
    SERVICE_RESTRICT_FILESYSTEMS=''
    SYSTEMD_VERSION=255
    SERVICE_DROPINS=/etc/systemd/system/certbot.service.d/unknown.conf
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with an unknown drop-in passed validation'
    fi
    SERVICE_DROPINS=''
    SERVICE_FRAGMENT=/etc/systemd/system/certbot.service
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot service with an untrusted fragment passed validation'
    fi
    SERVICE_FRAGMENT=/lib/systemd/system/certbot.service
    SERVICE_FRAGMENT_STATE='0:0:777:1:symbolic link'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'symlinked Certbot service fragment passed validation'
    fi
    SERVICE_FRAGMENT_STATE='1000:0:644:1:regular file'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'non-root Certbot service fragment passed validation'
    fi
    SERVICE_FRAGMENT_STATE='0:0:644:1:regular file'
    TIMER_TRIGGERS='other.service'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer without the exact certbot.service trigger passed validation'
    fi
    TIMER_TRIGGERS=certbot.service
    TIMER_NEXT_REALTIME=''
    TIMER_NEXT_MONOTONIC='n/a'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer without a scheduled next elapse passed validation'
    fi
    TIMER_NEXT_REALTIME=$(date -u -d '+1 day' '+%a %Y-%m-%d %H:%M:%S UTC')
    TIMER_NEXT_MONOTONIC='1h 5min'
    TIMER_NEXT_REALTIME=$(date -u -d '+100 years' '+%a %Y-%m-%d %H:%M:%S UTC')
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer scheduled one hundred years ahead passed validation'
    fi
    TIMER_NEXT_REALTIME=$(date -u -d '+1 day' '+%a %Y-%m-%d %H:%M:%S UTC')
    TIMER_CALENDAR="{ OnCalendar=$TIMER_NEXT_REALTIME ; next_elapse=mocked }"
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'one-shot Certbot calendar passed recurring runtime validation'
    fi
    TIMER_CALENDAR='{ OnCalendar=*-*-* 00,12:00:00 ; next_elapse=mocked }'
    TIMER_CALENDAR='{ OnCalendar=Tue,Wed *-*-* 00:00:00 ; next_elapse=mocked }'
    TIMER_RANDOMIZED_DELAY=2d
    TIMER_ACCURACY=0
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'clustered weekday calendar with an eight-day worst gap passed validation'
    fi
    TIMER_CALENDAR='{ OnCalendar=*-*-* 00,12:00:00 ; next_elapse=mocked }'
    TIMER_RANDOMIZED_DELAY=12h
    TIMER_ACCURACY=1min
    TIMER_RANDOMIZED_DELAY=7d
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an unbounded randomized delay passed validation'
    fi
    TIMER_RANDOMIZED_DELAY=12h
    TIMER_ACCURACY=7d
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an unbounded accuracy window passed validation'
    fi
    TIMER_ACCURACY=1min
    SYSTEMD_VERSION=258
    TIMER_RANDOMIZED_OFFSET=7d
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an unbounded randomized offset passed validation'
    fi
    TIMER_RANDOMIZED_OFFSET=0
    SYSTEMD_VERSION=255
    TIMER_CONDITIONS='ConditionPathExists=/etc/letsencrypt result=true'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an effective Condition passed validation'
    fi
    TIMER_CONDITIONS=''
    TIMER_ASSERTS='AssertPathExists=/etc/letsencrypt result=true'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an effective Assert passed validation'
    fi
    TIMER_ASSERTS=''
    TIMER_DROPINS=/etc/systemd/system/certbot.timer.d/unknown.conf
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an unknown drop-in passed validation'
    fi
    TIMER_DROPINS=''
    TIMER_FRAGMENT=/etc/systemd/system/certbot.timer
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer with an untrusted fragment passed validation'
    fi
    TIMER_FRAGMENT=/lib/systemd/system/certbot.timer
    TIMER_FRAGMENT_STATE='0:0:644:2:regular file'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'hard-linked Certbot timer fragment passed validation'
    fi
    TIMER_FRAGMENT_STATE='0:0:666:1:regular file'
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'group/world-writable Certbot timer fragment passed validation'
    fi
    TIMER_FRAGMENT_STATE='0:0:644:1:regular file'
    TIMER_ENABLED=false
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'disabled Certbot timer passed renewal runtime validation'
    fi
    TIMER_ENABLED=true
    TIMER_ACTIVE=false
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'inactive Certbot timer passed renewal runtime validation'
    fi
    TIMER_ACTIVE=true
    ROUTE_READY=false
    if rr_certbot_renewal_runtime_is_ready naive.example.invalid; then
        fail 'Certbot timer passed renewal runtime validation without its domain route'
    fi
    if rr_certbot_renewal_runtime_is_ready ''; then
        fail 'Certbot renewal runtime accepted a blank lineage domain'
    fi
)
pass 'Certbot renewal runtime binds timer health to the exact lineage route'

(
    sync_root=$(mktemp -d)
    trap 'rm -rf "$sync_root"' EXIT
    mkdir -p "$sync_root/source" "$sync_root/target"
    printf '%s\n' certificate > "$sync_root/source/fullchain.pem"
    printf '%s\n' private-key > "$sync_root/source/privkey.pem"
    PAIR_VALIDATIONS=0
    naive_certificate_pair_valid() {
        PAIR_VALIDATIONS=$((PAIR_VALIDATIONS + 1))
        [ "$3" = naive.example.invalid ]
    }
    sync_naive_certificate_pair "$sync_root/source" "$sync_root/target" \
        naive.example.invalid || fail 'valid captured Naive pair was not committed'
    [ "$PAIR_VALIDATIONS" -eq 4 ] ||
        fail 'Naive sync did not validate captured and committed pair generations'
    [ "$(stat -c %a "$sync_root/target/fullchain.pem")" = 600 ] && \
        [ "$(stat -c %a "$sync_root/target/privkey.pem")" = 600 ] ||
        fail 'Naive sync did not commit private 0600 pair files'

    printf '%s\n' old-certificate > "$sync_root/target/fullchain.pem"
    printf '%s\n' old-private-key > "$sync_root/target/privkey.pem"
    PAIR_VALIDATIONS=0
    naive_certificate_pair_valid() {
        PAIR_VALIDATIONS=$((PAIR_VALIDATIONS + 1))
        [ "$PAIR_VALIDATIONS" -eq 1 ]
    }
    if sync_naive_certificate_pair "$sync_root/source" "$sync_root/target" \
         naive.example.invalid; then
        fail 'captured Naive pair failing the second validation was committed'
    fi
    grep -Fxq old-certificate "$sync_root/target/fullchain.pem"
    grep -Fxq old-private-key "$sync_root/target/privkey.pem"
)
pass 'Naive certificate sync validates captured temporaries before atomic file commits'

(
    RR_UPDATE_TRANSACTION=1
    RR_PORTABLE_RESTORE=1
    RR_NAIVE_CERT_DIR=$(mktemp -d)
    trap 'rm -rf "$RR_NAIVE_CERT_DIR"' EXIT
    PAIR_CHECKS=0
    LINEAGE_CHECKS=0
    RUNTIME_CHECKS=0
    CERT_SYNCS=0
    HOOK_CHECKS=0
    HOOK_DEPLOYS=0
    is_valid_domain() { return 0; }
    naive_certificate_pair_valid() { PAIR_CHECKS=$((PAIR_CHECKS + 1)); return 0; }
    rr_certbot_webroot_lineage_is_renewable() {
        LINEAGE_CHECKS=$((LINEAGE_CHECKS + 1))
        return 0
    }
    rr_certbot_renewal_runtime_is_ready() {
        [ "${1:-}" = naive.example.invalid ] || return 1
        RUNTIME_CHECKS=$((RUNTIME_CHECKS + 1))
        return 0
    }
    sync_naive_certificate_pair() { CERT_SYNCS=$((CERT_SYNCS + 1)); return 0; }
    rr_certificate_deploy_hook_is_current() { HOOK_CHECKS=$((HOOK_CHECKS + 1)); return 0; }
    deploy_naive_cert_hook() { HOOK_DEPLOYS=$((HOOK_DEPLOYS + 1)); return 0; }

    ensure_naive_certificate naive.example.invalid admin@example.invalid ||
        fail 'portable transaction rejected a pre-provisioned current hook'
    [ "$PAIR_CHECKS" -eq 1 ] && [ "$LINEAGE_CHECKS" -eq 1 ] && \
        [ "$RUNTIME_CHECKS" -eq 1 ] && \
        [ "$CERT_SYNCS" -eq 1 ] && \
        [ "$HOOK_CHECKS" -eq 1 ] && [ "$HOOK_DEPLOYS" -eq 0 ] ||
        fail 'portable transaction skipped the renewable lineage or wrote its deploy hook'

    rr_certbot_webroot_lineage_is_renewable() {
        LINEAGE_CHECKS=$((LINEAGE_CHECKS + 1))
        return 1
    }
    if ensure_naive_certificate naive.example.invalid admin@example.invalid >/dev/null 2>&1; then
        fail 'portable transaction accepted a valid copied pair without a renewable lineage'
    fi
    [ "$RUNTIME_CHECKS" -eq 1 ] && [ "$CERT_SYNCS" -eq 1 ] && \
        [ "$HOOK_CHECKS" -eq 1 ] ||
        fail 'portable lineage failure was not rejected before runtime, sync or hook operations'
    rr_certbot_webroot_lineage_is_renewable() {
        LINEAGE_CHECKS=$((LINEAGE_CHECKS + 1))
        return 0
    }

    rr_certificate_deploy_hook_is_current() { HOOK_CHECKS=$((HOOK_CHECKS + 1)); return 1; }
    if ensure_naive_certificate naive.example.invalid admin@example.invalid >/dev/null 2>&1; then
        fail 'portable transaction accepted a stale certificate hook'
    fi
    [ "$HOOK_DEPLOYS" -eq 0 ] || fail 'portable hook failure invoked the writer'

    RR_PORTABLE_RESTORE=0
    ensure_naive_certificate naive.example.invalid admin@example.invalid ||
        fail 'ordinary transaction no longer deploys the certificate hook'
    [ "$PAIR_CHECKS" -eq 4 ] && [ "$LINEAGE_CHECKS" -eq 4 ] && \
        [ "$RUNTIME_CHECKS" -eq 3 ] && [ "$CERT_SYNCS" -eq 3 ] && \
        [ "$HOOK_DEPLOYS" -eq 1 ] ||
        fail 'ordinary transaction skipped pair, lineage, runtime, sync or hook deployment'
)
pass 'portable Naive transaction validates but never deploys the global hook'

(
    CONFIG_FILE=$(mktemp)
    trap 'rm -f "$CONFIG_FILE"' EXIT
    printf '%s\n' 'CONFIG_VERSION=9' > "$CONFIG_FILE"
    RR_UPDATE_LOCK_HELD=0
    RR_UPDATE_TRANSACTION=1
    RR_PORTABLE_RESTORE=0
    PAIR_CHECKS=0
    LINEAGE_CHECKS=0
    RUNTIME_CHECKS=0
    CERT_WRITES=0
    HOOK_WRITES=0
    AFTER_CERT_GATE=0
    SERVICE_GATE_INSTALLS=0
    SERVICE_GATE_PROOFS=0
    SERVICE_STOPS=0
    RR_SINGBOX_SERVICE_FILE=$(mktemp)
    printf '%s\n' '[Service]' > "$RR_SINGBOX_SERVICE_FILE"
    chmod 644 "$RR_SINGBOX_SERVICE_FILE"
    check_supported_os() { return 0; }
    systemctl() { SERVICE_STOPS=$((SERVICE_STOPS + 1)); return 0; }
    stop_subscription_servers() { return 0; }
    sleep() { :; }
    migrate_config_schema() { return 0; }
    load_config_with_defaults() {
        NAIVE_ENABLED=true
        NAIVE_DOMAIN=naive.example.invalid
        LE_EMAIL=admin@example.invalid
        INSTALL_COMPLETE=true
        return 0
    }
    is_valid_domain() { return 0; }
    naive_certificate_pair_valid() { PAIR_CHECKS=$((PAIR_CHECKS + 1)); return 0; }
    rr_certbot_webroot_lineage_is_renewable() {
        LINEAGE_CHECKS=$((LINEAGE_CHECKS + 1))
        return 1
    }
    rr_certbot_renewal_runtime_is_ready() {
        [ "${1:-}" = naive.example.invalid ] || return 1
        RUNTIME_CHECKS=$((RUNTIME_CHECKS + 1))
        return 0
    }
    sync_naive_certificate_pair() { CERT_WRITES=$((CERT_WRITES + 1)); return 0; }
    deploy_naive_cert_hook() { HOOK_WRITES=$((HOOK_WRITES + 1)); return 0; }
    install() { CERT_WRITES=$((CERT_WRITES + 1)); return 0; }
    ensure_singbox_service_guards() {
        SERVICE_GATE_INSTALLS=$((SERVICE_GATE_INSTALLS + 1))
        return 0
    }
    rr_singbox_service_guards_are_effective() {
        SERVICE_GATE_PROOFS=$((SERVICE_GATE_PROOFS + 1))
        return 0
    }
    any_node_protocol_enabled() { AFTER_CERT_GATE=$((AFTER_CERT_GATE + 1)); return 0; }

    if post_update_migrate >/dev/null 2>&1; then
        fail 'ordinary update accepted Naive state without a renewable lineage'
    fi
    [ "$PAIR_CHECKS" -eq 1 ] && [ "$LINEAGE_CHECKS" -eq 1 ] && \
        [ "$RUNTIME_CHECKS" -eq 0 ] && [ "$CERT_WRITES" -eq 0 ] && \
        [ "$HOOK_WRITES" -eq 0 ] && [ "$AFTER_CERT_GATE" -eq 0 ] && \
        [ "$SERVICE_GATE_INSTALLS" -eq 1 ] && [ "$SERVICE_GATE_PROOFS" -eq 1 ] && \
        [ "$SERVICE_STOPS" -eq 3 ] ||
        fail 'ordinary post-update path performed runtime, write or later service work after lineage failure'
)
pass 'ordinary post-update Naive path gates writes and later services on lineage proof'

(
    gate_root=$(mktemp -d)
    trap 'rm -rf "$gate_root"' EXIT
    CONFIG_FILE="$gate_root/config"
    RR_SINGBOX_SERVICE_FILE="$gate_root/systemd/sing-box.service"
    marker="$gate_root/naive/.pair-pending"
    naive_cert="$gate_root/naive/fullchain.pem"
    naive_key="$gate_root/naive/privkey.pem"
    self_dir="$gate_root/self"
    mkdir -p "$(dirname "$RR_SINGBOX_SERVICE_FILE")" "$self_dir"
    printf '%s\n' 'INSTALL_COMPLETE=true' > "$CONFIG_FILE"
    rr_render_singbox_systemd_unit_legacy_710 > "$RR_SINGBOX_SERVICE_FILE"
    chmod 644 "$RR_SINGBOX_SERVICE_FILE"
    GATE_PROOF_LOG="$gate_root/effective-proofs.log"
    : > "$GATE_PROOF_LOG"
    CERT_FIRST_RENAME_REACHED=0
    manager_reloaded=false
    check_supported_os() { return 0; }
    stop_subscription_servers() { return 0; }
    sleep() { :; }
    migrate_config_schema() { return 0; }
    load_config_with_defaults() {
        NAIVE_ENABLED=true
        NAIVE_DOMAIN=naive.example.invalid
        LE_EMAIL=admin@example.invalid
        INSTALL_COMPLETE=true
        return 0
    }
    systemctl() {
        case "$*" in
            'stop sing-box'|'stop rr-subscription'|'stop rr-nexus') return 0 ;;
            'daemon-reload')
                grep -Fxq 'ExecStartPre=/usr/local/bin/rr --singbox-certificate-gate' \
                    "$RR_SINGBOX_SERVICE_FILE" && manager_reloaded=true ;;
            '--version') printf '%s\n' 'systemd 253' ;;
            'show --property=LoadState --value sing-box.service') printf '%s\n' loaded ;;
            'show --property=FragmentPath --value sing-box.service')
                printf '%s\n' "$RR_SINGBOX_SERVICE_FILE" ;;
            'show --property=ExecStartPre --value sing-box.service')
                if [ "$manager_reloaded" = true ]; then
                    printf '%s' \
                        '{ path=/usr/local/bin/rr ; argv[]=/usr/local/bin/rr --singbox-certificate-gate ; ignore_errors=no ; } '
                fi
                printf '%s\n' \
                    '{ path=/usr/local/bin/sing-box ; argv[]=/usr/local/bin/sing-box check -c /etc/sing-box/config.json ; ignore_errors=no ; }' ;;
            'show --property=ExecStart --value sing-box.service')
                printf '%s\n' \
                    '{ path=/usr/local/bin/sing-box ; argv[]=/usr/local/bin/sing-box run -c /etc/sing-box/config.json ; ignore_errors=no ; }' ;;
            'show --property=ExecReload --value sing-box.service')
                printf '%s\n' \
                    '{ path=/bin/kill ; argv[]=/bin/kill -HUP $MAINPID ; ignore_errors=no ; }' ;;
            'show --property=User --value sing-box.service') printf '%s\n' root ;;
            'show --property=Group --value sing-box.service') printf '%s\n' root ;;
            'show --property=WorkingDirectory --value sing-box.service')
                printf '%s\n' /etc/sing-box ;;
            'show --property=DynamicUser --value sing-box.service'|\
            'show --property=PrivateUsers --value sing-box.service'|\
            'show --property=PrivateMounts --value sing-box.service'|\
            'show --property=PrivateNetwork --value sing-box.service')
                printf '%s\n' no ;;
            'show --property=RootDirectory --value sing-box.service'|\
            'show --property=RootImage --value sing-box.service'|\
            'show --property=MountImages --value sing-box.service'|\
            'show --property=ExtensionImages --value sing-box.service'|\
            'show --property=ExtensionDirectories --value sing-box.service'|\
            'show --property=TemporaryFileSystem --value sing-box.service'|\
            'show --property=BindPaths --value sing-box.service'|\
            'show --property=BindReadOnlyPaths --value sing-box.service'|\
            'show --property=InaccessiblePaths --value sing-box.service'|\
            'show --property=JoinsNamespaceOf --value sing-box.service'|\
            'show --property=ReadOnlyPaths --value sing-box.service'|\
            'show --property=ReadWritePaths --value sing-box.service'|\
            'show --property=Environment --value sing-box.service'|\
            'show --property=EnvironmentFiles --value sing-box.service'|\
            'show --property=PassEnvironment --value sing-box.service'|\
            'show --property=PAMName --value sing-box.service'|\
            'show --property=SystemCallFilter --value sing-box.service'|\
            'show --property=Conditions --value sing-box.service'|\
            'show --property=Asserts --value sing-box.service'|\
            'show --property=DropInPaths --value sing-box.service'|\
            'show --property=ExecCondition --value sing-box.service'|\
            'show --property=ExecStartPost --value sing-box.service'|\
            'show --property=ExecStop --value sing-box.service'|\
            'show --property=ExecStopPost --value sing-box.service')
                printf '\n' ;;
            'show --property=ProtectSystem --value sing-box.service')
                printf '%s\n' no ;;
            'show --property=ProtectHome --value sing-box.service')
                printf '%s\n' no ;;
            'show --property=StartLimitIntervalUSec --value sing-box.service')
                printf '%s\n' 1min ;;
            'show --property=StartLimitBurst --value sing-box.service') printf '%s\n' 5 ;;
            'show --property=Restart --value sing-box.service') printf '%s\n' on-failure ;;
            'show --property=RestartPreventExitStatus --value sing-box.service')
                if [ "$manager_reloaded" = true ]; then
                    printf '%s\n' proof >> "$GATE_PROOF_LOG"
                    printf '%s\n' 78
                else
                    printf '\n'
                fi
                ;;
            *) return 1 ;;
        esac
    }
    ensure_naive_certificate() {
        [ "$(wc -l < "$GATE_PROOF_LOG")" -ge 2 ] ||
            fail 'certificate writer ran before repeated exact effective gate proof'
        grep -Fxq 'ExecStartPre=/usr/local/bin/rr --singbox-certificate-gate' \
            "$RR_SINGBOX_SERVICE_FILE" ||
            fail 'certificate writer ran before the atomic unit publication'
        rr_certificate_pair_pending_publish "$marker" ||
            fail 'could not publish first-rename crash marker fixture'
        printf '%s\n' first-renamed-private-key > "$naive_key"
        chmod 600 "$naive_key"
        CERT_FIRST_RENAME_REACHED=1
        set +e
        rr_singbox_certificate_start_gate_for_paths \
            "$self_dir/cert.pem" "$self_dir/private.key" "$self_dir/.pair-pending" \
            "$naive_cert" "$naive_key" "$marker"
        gate_status=$?
        set -e
        [ "$gate_status" -eq 78 ] ||
            fail 'effective certificate gate admitted a pending first-rename generation'
        return 1
    }
    if post_update_migrate >/dev/null 2>&1; then
        fail 'first-rename fault fixture unexpectedly completed migration'
    fi
    [ "$CERT_FIRST_RENAME_REACHED" -eq 1 ] && \
        [ "$(wc -l < "$GATE_PROOF_LOG")" -ge 2 ] ||
        fail 'post-update did not install/prove the gate before certificate publication'
)
pass 'post-update upgrades the Sing-box certificate gate before first pair rename'

(
    subscription_root=$(mktemp -d)
    trap 'rm -rf "$subscription_root"' EXIT
    RR_UPDATE_TRANSACTION=1
    RR_PORTABLE_RESTORE=1
    RR_LIB_DIR="$subscription_root/runtime"
    RR_LE_LIVE_ROOT="$subscription_root/letsencrypt/live"
    SUB_ROOT="$subscription_root/subscriptions"
    SUB_PID_FILE="$subscription_root/subscription.pid"
    SUB_BIND_STATE_FILE="$subscription_root/subscription.bind"
    SUB_PORT=39291
    SUB_ACCESS_MODE=https
    SUB_DOMAIN=sub.example.invalid
    SUB_BIND_ADDRESS=0.0.0.0
    mkdir -p "$RR_LIB_DIR/nexus" "$RR_LE_LIVE_ROOT/$SUB_DOMAIN" "$SUB_ROOT"
    printf '%s\n' 'print("fixture")' > "$RR_LIB_DIR/nexus/sub_server.py"
    printf '%s\n' certificate > "$RR_LE_LIVE_ROOT/$SUB_DOMAIN/fullchain.pem"
    printf '%s\n' private-key > "$RR_LE_LIVE_ROOT/$SUB_DOMAIN/privkey.pem"

    SUB_PAIR_CHECKS=0
    SUB_LINEAGE_CHECKS=0
    SUB_RUNTIME_CHECKS=0
    SUB_HOOK_CHECKS=0
    SUB_HOOK_DEPLOYS=0
    is_valid_port() { return 0; }
    is_valid_domain() { return 0; }
    subscription_certificate_pair_valid() {
        SUB_PAIR_CHECKS=$((SUB_PAIR_CHECKS + 1))
        return 0
    }
    rr_certbot_webroot_lineage_is_renewable() {
        SUB_LINEAGE_CHECKS=$((SUB_LINEAGE_CHECKS + 1))
        return 0
    }
    rr_certbot_renewal_runtime_is_ready() {
        [ "${1:-}" = sub.example.invalid ] || return 1
        SUB_RUNTIME_CHECKS=$((SUB_RUNTIME_CHECKS + 1))
        return 0
    }
    rr_certificate_deploy_hook_is_current() {
        SUB_HOOK_CHECKS=$((SUB_HOOK_CHECKS + 1))
        return 0
    }
    deploy_subscription_cert_hook() {
        SUB_HOOK_DEPLOYS=$((SUB_HOOK_DEPLOYS + 1))
        return 0
    }
    ensure_subscription_root() { return 0; }
    is_subscription_pid() { [ "${1:-}" = 4242 ]; }

    server_signature=$(sha256sum "$RR_LIB_DIR/nexus/sub_server.py" | awk '{print $1}')
    cert_signature=$(sha256sum "$RR_LE_LIVE_ROOT/$SUB_DOMAIN/fullchain.pem" | awk '{print $1}')
    printf '%s\n' 4242 > "$SUB_PID_FILE"
    printf '%s\n' \
        "${SUB_PORT}|${SUB_BIND_ADDRESS}|https|${SUB_DOMAIN}|${server_signature}|${cert_signature}" \
        > "$SUB_BIND_STATE_FILE"

    start_subscription_server ||
        fail 'portable transaction rejected a prepared HTTPS subscription target'
    [ "$SUB_PAIR_CHECKS" -eq 1 ] && [ "$SUB_LINEAGE_CHECKS" -eq 1 ] && \
        [ "$SUB_RUNTIME_CHECKS" -eq 1 ] && \
        [ "$SUB_HOOK_CHECKS" -eq 1 ] && \
        [ "$SUB_HOOK_DEPLOYS" -eq 0 ] ||
        fail 'portable HTTPS subscription path skipped lineage or wrote the global hook'

    rr_certbot_webroot_lineage_is_renewable() {
        SUB_LINEAGE_CHECKS=$((SUB_LINEAGE_CHECKS + 1))
        return 1
    }
    if start_subscription_server >/dev/null 2>&1; then
        fail 'portable HTTPS subscription accepted a valid copied pair without renewable lineage'
    fi
    [ "$SUB_RUNTIME_CHECKS" -eq 1 ] && [ "$SUB_HOOK_CHECKS" -eq 1 ] ||
        fail 'subscription lineage failure was not rejected before runtime or hook validation'
    rr_certbot_webroot_lineage_is_renewable() {
        SUB_LINEAGE_CHECKS=$((SUB_LINEAGE_CHECKS + 1))
        return 0
    }

    rr_certificate_deploy_hook_is_current() {
        SUB_HOOK_CHECKS=$((SUB_HOOK_CHECKS + 1))
        return 1
    }
    if start_subscription_server >/dev/null 2>&1; then
        fail 'portable HTTPS subscription path accepted a stale deploy hook'
    fi
    [ "$SUB_HOOK_DEPLOYS" -eq 0 ] ||
        fail 'portable HTTPS subscription hook failure invoked the writer'

    RR_PORTABLE_RESTORE=0
    start_subscription_server ||
        fail 'ordinary transaction no longer deploys the HTTPS subscription hook'
    [ "$SUB_PAIR_CHECKS" -eq 4 ] && [ "$SUB_LINEAGE_CHECKS" -eq 4 ] && \
        [ "$SUB_RUNTIME_CHECKS" -eq 3 ] && [ "$SUB_HOOK_DEPLOYS" -eq 1 ] ||
        fail 'ordinary HTTPS subscription path skipped pair, lineage, runtime or hook deployment'
)
pass 'portable HTTPS subscription validates but never deploys the global hook'

RR_UPDATE_TRANSACTION=0
if install_deps >/dev/null 2>&1; then fail 'mocked normal install_deps unexpectedly succeeded'; fi
[ "$APT_CALLS" -gt 0 ] || fail 'normal install_deps no longer invokes apt'
APT_CALLS=0
if install_cloudflared >/dev/null 2>&1; then fail 'mocked normal cloudflared install unexpectedly succeeded'; fi
[ "$CURL_CALLS" -gt 0 ] || fail 'normal cloudflared install no longer invokes download path'
CURL_CALLS=0
if install_singbox >/dev/null 2>&1; then fail 'mocked normal sing-box install unexpectedly succeeded'; fi
[ "$CURL_CALLS" -gt 0 ] || fail 'normal sing-box install no longer invokes download path'
APT_CALLS=0
if nexus_install_dependencies >/dev/null 2>&1; then fail 'mocked normal Nexus dependency install unexpectedly succeeded'; fi
[ "$APT_CALLS" -gt 0 ] || fail 'normal Nexus dependency install no longer invokes apt'
pass 'ordinary installation paths retain package and download behavior'

FIREWALL_MUTATIONS=0
RULE_PRESENT=true
rr_ufw_backend_state() { return 1; }
rr_netfilter_backend_state() {
    case "$1" in iptables|ip6tables) return 0 ;; *) return 1 ;; esac
}
rr_netfilter_rr_namespace_is_empty() { return 1; }
rr_inactive_ufw_protocol_is_disjoint() { return 0; }
rr_netfilter_protocol_is_uncontested() { return 0; }
rr_netfilter_rule_state() {
    local _backend="$1" _port="$2" _proto="$3" comment="$4" target="$5"
    [ "$RULE_PRESENT" = true ] && [ "$comment" = "$FIREWALL_COMMENT" ] && [ "$target" = ACCEPT ]
}
rr_reconcile_netfilter_protocol_rule() {
    FIREWALL_MUTATIONS=$((FIREWALL_MUTATIONS + 1))
    RULE_PRESENT=true
    return 0
}
rr_firewall_capture_protocol_transaction() { return 0; }
rr_firewall_protocol_transaction_seals_match() { return 0; }
rr_firewall_inflight_begin_locked() { return 0; }
save_firewall() {
    FIREWALL_MUTATIONS=$((FIREWALL_MUTATIONS + 1))
    return 0
}
netfilter-persistent() { return 0; }

RR_UPDATE_TRANSACTION=1
open_protocol_firewall 443 tcp || fail 'transaction rejected an existing expected firewall rule'
[ "$FIREWALL_MUTATIONS" -eq 0 ] || fail 'transaction mutated/persisted an existing firewall rule'
RULE_PRESENT=false
if open_protocol_firewall 443 tcp >/dev/null 2>&1; then fail 'transaction accepted a missing firewall rule'; fi
[ "$FIREWALL_MUTATIONS" -eq 0 ] || fail 'transaction repaired a missing firewall rule'
RR_UPDATE_TRANSACTION=0
open_protocol_firewall 443 tcp || fail 'ordinary firewall reconciliation failed'
[ "$FIREWALL_MUTATIONS" -gt 0 ] || fail 'ordinary firewall reconciliation was disabled'
pass 'transaction firewall path is read-only while ordinary reconciliation remains enabled'

HOP_WRITES=0
HOP_PRESENT=true
iptables() {
    local argument=""
    if [[ " $* " == *' -S '* ]]; then
        [ "$HOP_PRESENT" = true ] && \
            printf '%s\n' \
                '-A PREROUTING -p udp --dport 20000:20010 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 8443'
        return 0
    fi
    for argument in "$@"; do
        case "$argument" in -A|-I|-D) HOP_WRITES=$((HOP_WRITES + 1)); return 1 ;; esac
    done
    [ "$HOP_PRESENT" = true ]
}
ENTRY_IP_MODE=ipv4
RR_UPDATE_TRANSACTION=1
rr_validate_hop_rules HY2 8443 20000:20010 || fail 'existing hop rule failed read-only validation'
[ "$HOP_WRITES" -eq 0 ] || fail 'hop validation wrote a NAT rule'
HOP_PRESENT=false
if rr_validate_hop_rules HY2 8443 20000:20010 >/dev/null 2>&1; then
    fail 'missing hop rule passed read-only validation'
fi
[ "$HOP_WRITES" -eq 0 ] || fail 'missing hop rule was repaired during transaction'
pass 'transaction hop-port validation never mutates NAT rules'

transaction_config="$SIDE_EFFECT_FIREWALL_ROOT/transaction-config"
printf '%s\n' 'INSTALL_COMPLETE=true' > "$transaction_config"
CONFIG_FILE="$transaction_config"
SINGBOX_BIN=/nonexistent/rr-sing-box
INSTALL_CALLS=0
check_supported_os() { return 0; }
systemctl() { return 0; }
stop_subscription_servers() { return 0; }
migrate_config_schema() { return 0; }
load_config_with_defaults() {
    INSTALL_COMPLETE=true
    NAIVE_ENABLED=false
    return 0
}
any_node_protocol_enabled() { return 0; }
get_singbox_version() { return 1; }
install_singbox() { INSTALL_CALLS=$((INSTALL_CALLS + 1)); return 1; }

RR_UPDATE_TRANSACTION=1
if post_update_migrate >/dev/null 2>&1; then fail 'transaction with a missing core unexpectedly succeeded'; fi
[ "$INSTALL_CALLS" -eq 0 ] || fail 'post-update transaction called the core installer'
RR_UPDATE_TRANSACTION=0
if post_update_migrate >/dev/null 2>&1; then fail 'mocked ordinary migration unexpectedly succeeded'; fi
[ "$INSTALL_CALLS" -eq 1 ] || fail 'ordinary migration no longer reaches core repair'
pass 'post-update migration fails before core installation only in transaction mode'

(
    SECONDS=0
    HEALTH_PROBES=0
    HEALTH_SLEEPS=0
    systemctl() { [ "$*" = 'is-active --quiet rr-nexus' ]; }
    curl() {
        HEALTH_PROBES=$((HEALTH_PROBES + 1))
        [[ "$*" == *'http://127.0.0.1:7900/healthz'* ]]
        [ "$HEALTH_PROBES" -eq 3 ]
    }
    sleep() {
        HEALTH_SLEEPS=$((HEALTH_SLEEPS + 1))
        SECONDS=$((SECONDS + 1))
    }
    rr_wait_nexus_local_health 7900 ||
        fail 'bounded Nexus readiness rejected a delayed healthy listener'
    [ "$HEALTH_PROBES" -eq 3 ] && [ "$HEALTH_SLEEPS" -eq 2 ] ||
        fail 'bounded Nexus readiness did not retry only until success'
)
pass 'post-update Nexus readiness tolerates bounded Type=simple startup delay'

(
    SECONDS=0
    HEALTH_PROBES=0
    HEALTH_SLEEPS=0
    systemctl() { [ "$*" = 'is-active --quiet rr-nexus' ]; }
    curl() { HEALTH_PROBES=$((HEALTH_PROBES + 1)); return 1; }
    sleep() {
        HEALTH_SLEEPS=$((HEALTH_SLEEPS + 1))
        SECONDS=$((SECONDS + 10))
    }
    if rr_wait_nexus_local_health 7900; then
        fail 'bounded Nexus readiness accepted a permanently unavailable listener'
    fi
    [ "$HEALTH_PROBES" -ge 2 ] && [ "$HEALTH_PROBES" -le 4 ] &&
        [ "$HEALTH_SLEEPS" -eq "$HEALTH_PROBES" ] ||
        fail 'Nexus readiness deadline was not finite and deterministic'
)
pass 'post-update Nexus readiness remains fail-closed at its deadline'

(
    SECONDS=0
    SERVICE_CHECKS=0
    HEALTH_PROBES=0
    systemctl() {
        SERVICE_CHECKS=$((SERVICE_CHECKS + 1))
        [ "$SERVICE_CHECKS" -eq 1 ]
    }
    curl() { HEALTH_PROBES=$((HEALTH_PROBES + 1)); return 1; }
    sleep() { SECONDS=$((SECONDS + 1)); }
    if rr_wait_nexus_local_health 7900; then
        fail 'Nexus readiness accepted a service that exited during startup'
    fi
    [ "$SERVICE_CHECKS" -eq 2 ] && [ "$HEALTH_PROBES" -eq 1 ] ||
        fail 'Nexus readiness kept probing after the service exited'
)
pass 'post-update Nexus readiness rejects an exited service immediately'

(
    systemctl() { fail 'invalid Nexus port reached systemd'; }
    curl() { fail 'invalid Nexus port reached curl'; }
    if rr_wait_nexus_local_health invalid; then
        fail 'Nexus readiness accepted an invalid health port'
    fi
)

post_update_body=$(sed -n '/^post_update_migrate() {/,/^}/p' modules/60-update.sh)
wait_line=$(grep -nF 'rr_wait_nexus_local_health "$nexus_health_port"' \
    <<<"$post_update_body" | cut -d: -f1)
proxy_line=$(grep -nF 'nexus_public_proxy_health_check || return 1' \
    <<<"$post_update_body" | cut -d: -f1)
[[ "$wait_line" =~ ^[0-9]+$ && "$proxy_line" =~ ^[0-9]+$ ]] &&
    [ "$wait_line" -lt "$proxy_line" ] ||
    fail 'post-update migration no longer gates the public proxy on local Nexus readiness'
if grep -Fq 'curl -fsS --connect-timeout 3 --max-time 8 "http://127.0.0.1:${nexus_health_port}/healthz"' \
    <<<"$post_update_body"; then
    fail 'post-update migration restored the racy one-shot Nexus health probe'
fi
pass 'post-update migration wires bounded local readiness before public proxy health'

printf 'update side-effect guard tests passed: %s\n' "$pass_count"
