#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

load_modules() {
    RR_LIB_DIR="$ROOT_DIR"
    local module_file
    for module_file in "$ROOT_DIR"/modules/*.sh; do
        # shellcheck disable=SC1090
        source "$module_file"
    done
}

run_install_case() (
    local mutation="${1:-none}"
    load_modules
    SYS_ARCH=amd64
    RR_CLOUDFLARED_RELEASE_API=https://api.github.com/repos/cloudflare/cloudflared/releases/latest
    local tag=2026.8.2
    local asset=cloudflared-linux-amd64.deb
    local url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/${asset}"
    local payload='verified deb payload'
    local digest
    digest=$(printf '%s' "$payload" | sha256sum | awk '{print $1}')
    local body="${asset}: ${digest}"
    local api_digest="sha256:${digest}"
    local asset_url="$url"
    local draft=false prerelease=false
    local duplicate=false download_payload="$payload" package_valid=true
    local installed_tag="$tag"
    local api_rc=0 api_status=200 expected_success=false expected_fallback=false
    local api_header_chain=false final_retry_after=""
    local fallback_tag=2026.9.1
    local fallback_digest="$digest" fallback_size="${#payload}"
    local fallback_url="https://github.com/cloudflare/cloudflared/releases/download/${fallback_tag}/${asset}"

    case "$mutation" in
        draft) draft=true ;;
        prerelease) prerelease=true ;;
        old) tag=2025.3.9; url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/${asset}"; asset_url="$url" ;;
        wrong_url) asset_url="https://attacker.example/${asset}" ;;
        missing_checksum) body='no checksums here' ;;
        ambiguous_checksum)
            body=$(printf '%s: %s\n%s: %s' "$asset" "$digest" "$asset" \
                "$(printf bad | sha256sum | awk '{print $1}')")
            ;;
        api_mismatch) api_digest="sha256:$(printf mismatch | sha256sum | awk '{print $1}')" ;;
        download_mismatch) download_payload='tampered deb payload' ;;
        invalid_deb) package_valid=false ;;
        installed_mismatch) installed_tag=2026.8.1 ;;
        duplicate) duplicate=true ;;
        api_403) api_rc=22; api_status=403; expected_fallback=true; expected_success=true ;;
        api_429) api_rc=22; api_status=429; expected_fallback=true; expected_success=true ;;
        api_403_redirect)
            api_rc=22; api_status=403; expected_fallback=true; expected_success=true
            api_header_chain=true
            ;;
        api_429_redirect)
            api_rc=22; api_status=429; expected_fallback=true; expected_success=true
            api_header_chain=true; final_retry_after=12
            ;;
        api_500) api_rc=22; api_status=500; expected_fallback=true; expected_success=true ;;
        api_503) api_rc=22; api_status=503; expected_fallback=true; expected_success=true ;;
        api_timeout) api_rc=28; api_status=000; expected_fallback=true; expected_success=true ;;
        api_dns) api_rc=6; api_status=000; expected_fallback=true; expected_success=true ;;
        api_connect) api_rc=7; api_status=000; expected_fallback=true; expected_success=true ;;
        api_401) api_rc=22; api_status=401 ;;
        api_404) api_rc=22; api_status=404 ;;
        api_write_failure) api_rc=23; api_status=000 ;;
        api_size_limit) api_rc=63; api_status=200 ;;
        fallback_bad_pin)
            api_rc=22; api_status=403; expected_fallback=true
            fallback_digest=$(printf wrong-pinned-checksum | sha256sum | awk '{print $1}')
            ;;
        fallback_wrong_size)
            api_rc=22; api_status=403; expected_fallback=true
            fallback_size=$((fallback_size + 1))
            ;;
        fallback_invalid_deb)
            api_rc=22; api_status=403; expected_fallback=true; package_valid=false
            ;;
        fallback_installed_mismatch)
            api_rc=22; api_status=403; expected_fallback=true
            ;;
        unsupported_arch) SYS_ARCH=riscv64 ;;
        none) expected_success=true ;;
        *) return 99 ;;
    esac

    if [ "$expected_success" = true ] && [ "$expected_fallback" = true ]; then
        installed_tag="$fallback_tag"
    fi
    local first_asset extra_asset=''
    first_asset=$(jq -cn --arg name "$asset" --arg url "$asset_url" --arg digest "$api_digest" \
        --argjson size "${#payload}" \
        '{name:$name,browser_download_url:$url,digest:$digest,size:$size}')
    if [ "$duplicate" = true ]; then
        extra_asset=",${first_asset}"
    fi
    CF_METADATA=$(printf '{"tag_name":"%s","draft":%s,"prerelease":%s,"body":%s,"assets":[%s%s]}' \
        "$tag" "$draft" "$prerelease" "$(jq -Rn --arg value "$body" '$value')" \
        "$first_asset" "$extra_asset")
    CF_PAYLOAD="$download_payload"
    CF_CURL_LOG=$(mktemp)
    CF_FALLBACK_LOG=$(mktemp)
    CF_POLICY_LOG=$(mktemp)
    CF_INSTALL_LOG=$(mktemp)
    trap 'rm -f "$CF_CURL_LOG" "$CF_FALLBACK_LOG" "$CF_POLICY_LOG" "$CF_INSTALL_LOG"' EXIT
    CF_INSTALLED=false
    CF_INSTALLED_TAG="$installed_tag"
    CF_PACKAGE_VALID="$package_valid"

    curl() {
        local output='' argument='' last='' headers=''
        printf '%q ' "$@" >> "$CF_CURL_LOG"
        printf '\n' >> "$CF_CURL_LOG"
        while [ "$#" -gt 0 ]; do
            argument="$1"
            shift
            if [ "$argument" = --output ] || [ "$argument" = -o ]; then
                [ "$#" -gt 0 ] || return 2
                output="$1"
                shift
                continue
            fi
            if [ "$argument" = --dump-header ]; then
                [ "$#" -gt 0 ] || return 2
                headers="$1"
                shift
                continue
            fi
            last="$argument"
        done
        [ -n "$output" ] || return 2
        if [ "$last" = "$RR_CLOUDFLARED_RELEASE_API" ]; then
            if [ -n "$headers" ] && [ "$api_status" != 000 ]; then
                : > "$headers"
                if [ "$api_header_chain" = true ]; then
                    printf 'HTTP/1.1 200 Connection established\r\n\r\n' >> "$headers"
                    printf 'HTTP/2 302\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1234567890\r\nretry-after: 60\r\n\r\n' >> "$headers"
                fi
                # HTTP/2 omits the reason phrase; the bare status ends in CRLF.
                printf 'HTTP/2 %s\r\n' "$api_status" >> "$headers"
                if [ "$api_header_chain" = false ]; then
                    printf 'x-ratelimit-remaining: 0\r\n' >> "$headers"
                fi
                [ -z "$final_retry_after" ] || printf 'retry-after: %s\r\n' "$final_retry_after" >> "$headers"
                printf '\r\n' >> "$headers"
            fi
            printf '%s' "$CF_METADATA" > "$output"
            return "$api_rc"
        else
            if [ "$last" != "$url" ] && [ "$last" != "$fallback_url" ]; then
                printf 'Unexpected download origin: %s\n' "$last" >> "$CF_POLICY_LOG"
                return 3
            fi
            printf '%s' "$CF_PAYLOAD" > "$output"
        fi
    }
    rr_cloudflared_fallback_release() {
        printf '%s\n' "$*" >> "$CF_FALLBACK_LOG"
        case "${1:-}" in amd64|arm64) ;; *) return 1 ;; esac
        printf '%s\n' "$fallback_tag" "$fallback_url" "$fallback_digest" "$fallback_size"
    }
    apt-get() { printf 'Unexpected apt invocation\n' >> "$CF_POLICY_LOG"; return 99; }
    dpkg-deb() { [ "$CF_PACKAGE_VALID" = true ]; }
    dpkg() {
        [ "${1:-}" = -i ] || return 1
        CF_INSTALLED=true
    }
    cloudflared() {
        [ "$CF_INSTALLED" = true ] || return 1
        [ "${1:-}" = --version ] || return 1
        printf 'cloudflared version %s (built test)\n' "$CF_INSTALLED_TAG"
    }

    if install_cloudflared > "$CF_INSTALL_LOG" 2>&1; then
        [ "$expected_success" = true ] || {
            echo "Unsafe cloudflared case was accepted: $mutation" >&2
            return 1
        }
        [ "$CF_INSTALLED" = true ]
        [ "$(wc -l < "$CF_CURL_LOG")" -eq 2 ]
        grep -Fq -- '--proto =https' "$CF_CURL_LOG"
        grep -Fq -- '--tlsv1.2' "$CF_CURL_LOG"
        grep -Fq -- '--connect-timeout 10' "$CF_CURL_LOG"
        grep -Fq -- '--max-time 120' "$CF_CURL_LOG"
        grep -Fq -- "--max-filesize ${#payload}" "$CF_CURL_LOG"
    else
        [ "$expected_success" = false ] || {
            printf 'Valid cloudflared acquisition was rejected: %s\n' "$mutation" >&2
            cat "$CF_INSTALL_LOG" >&2
            return 1
        }
        [ "$CF_INSTALLED" = false ] || [ "$mutation" = installed_mismatch ] || \
            [ "$mutation" = fallback_installed_mismatch ]
    fi
    [ ! -s "$CF_POLICY_LOG" ]
    if [ "$api_header_chain" = true ]; then
        ! grep -Fq -- '1234567890' "$CF_INSTALL_LOG"
        ! grep -Fq -- '60 秒' "$CF_INSTALL_LOG"
        if [ -n "$final_retry_after" ]; then
            grep -Fq -- '12 秒' "$CF_INSTALL_LOG"
        fi
    fi
    if [ "$expected_fallback" = true ]; then
        [ "$(wc -l < "$CF_FALLBACK_LOG")" -eq 1 ]
        [ "$(wc -l < "$CF_CURL_LOG")" -eq 2 ]
        grep -Fq -- "$fallback_url" "$CF_CURL_LOG"
    else
        [ ! -s "$CF_FALLBACK_LOG" ]
    fi
    if [ "$mutation" = unsupported_arch ]; then
        [ ! -s "$CF_CURL_LOG" ]
    else
        local api_call
        api_call=$(head -n 1 "$CF_CURL_LOG")
        [[ "$api_call" == *"--dump-header "* ]]
        [[ "$api_call" == *"--proto =https"* ]]
        [[ "$api_call" == *"--tlsv1.2"* ]]
        [[ "$api_call" != *"--retry-all-errors"* ]]
        [[ "$api_call" != *"--retry 3"* ]]
        [ "$(grep -Fc -- "$RR_CLOUDFLARED_RELEASE_API" "$CF_CURL_LOG")" -eq 1 ]
    fi
)

printf '[1/14] exact release, asset URL, checksum and installed version\n'
run_install_case none

printf '[2/14] unstable, old, duplicate and unbound releases fail closed\n'
for case_name in draft prerelease old wrong_url duplicate; do
    run_install_case "$case_name"
done

printf '[3/14] checksum, package and post-install gates fail closed\n'
for case_name in missing_checksum ambiguous_checksum api_mismatch download_mismatch invalid_deb installed_mismatch; do
    run_install_case "$case_name"
done

printf '[4/14] token-file version boundary\n'
(
    load_modules
    CF_VERSION=2025.3.9
    cloudflared() { printf 'cloudflared version %s\n' "$CF_VERSION"; }
    if cloudflared_token_file_supported; then
        echo 'cloudflared older than token-file support was accepted.' >&2
        exit 1
    fi
    CF_VERSION=2025.4.0
    cloudflared_token_file_supported
)

cf_snapshot() {
    local path="$1"
    if [ -L "$path" ]; then
        printf 'link:%s:' "$(readlink -- "$path")"
        stat -c '%d:%i:%u:%g:%a:%h:%s:%Y:%Z' -- "$path"
    elif [ -e "$path" ]; then
        printf 'file:%s:' "$(sha256sum -- "$path" | awk '{print $1}')"
        stat -c '%d:%i:%u:%g:%a:%h:%s:%Y:%Z' -- "$path"
    else
        printf 'absent\n'
    fi
}

cf_render_legacy_unit() {
    local description="$1" timeout="$2" binary="$3" token="$4"
    cat <<EOF
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=${timeout}
Type=notify
ExecStart=${binary} --no-autoupdate tunnel run --token ${token}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

cf_render_legacy_token_file_unit() {
    local binary="$1" token_file="$2"
    cat <<EOF
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=${binary} --no-autoupdate tunnel run --token-file ${token_file}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

cf_systemctl() {
    local action="${1:-}" property=""
    printf '%q ' "$@" >> "$CF_SYSTEMCTL_ALL_LOG"
    printf '\n' >> "$CF_SYSTEMCTL_ALL_LOG"
    shift || true
    case "$action" in
        show)
            property="${1#--property=}"
            case "$property" in
                LoadState)
                    [ "$CF_UNIT_STATE" = absent ] && printf 'not-found\n' || printf 'loaded\n'
                    ;;
                FragmentPath)
                    [ "$CF_UNIT_STATE" = absent ] || printf '%s\n' "$RR_CLOUDFLARED_SERVICE_FILE"
                    ;;
                DropInPaths)
                    case "$CF_UNIT_STATE" in
                        current_tampered) printf '%s\n' "$CF_ROOT/third-party.conf" ;;
                        current_gate) printf '%s\n' "$CF_RESTORE_DROPIN" ;;
                    esac
                    ;;
                ExecStart)
                    case "$CF_UNIT_STATE" in
                        current|current_tampered|current_gate|current_env|current_bind|current_user|current_pam|current_syscall|previous)
                            printf '{ path=%s ; argv[]=%s --no-autoupdate tunnel run --token-file %%d/rr-tunnel-token ; ignore_errors=no }\n' \
                                "$CF_BIN" "$CF_BIN"
                            ;;
                        legacy)
                            if [ "$CF_LEGACY_KIND" = token-file ]; then
                                printf '{ path=%s ; argv[]=%s --no-autoupdate tunnel run --token-file %s ; ignore_errors=no }\n' \
                                    "$CF_BIN" "$CF_BIN" "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE"
                            else
                                printf '{ path=%s ; argv[]=%s --no-autoupdate tunnel run --token %s ; ignore_errors=no }\n' \
                                    "$CF_BIN" "$CF_BIN" "$CF_LEGACY_TOKEN"
                            fi
                            ;;
                        thirdparty)
                            printf '{ path=%s ; argv[]=%s --config /etc/third-party.yml tunnel run --token %s ; ignore_errors=no }\n' \
                                "$CF_BIN" "$CF_BIN" "$CF_LEGACY_TOKEN"
                            ;;
                    esac
                    ;;
                ExecCondition)
                    if [ "$CF_UNIT_STATE" = current_gate ]; then
                        printf '{ path=/bin/sh ; argv[]=/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate ; ignore_errors=no }\n'
                    fi
                    ;;
                ExecStartPre|ExecStartPost|ExecReload|ExecStop|ExecStopPost|RootDirectory|RootImage) ;;
                Type)
                    [ "$CF_UNIT_STATE" = legacy ] && printf 'notify\n' || printf 'simple\n'
                    ;;
                DynamicUser)
                    [ "$CF_UNIT_STATE" = previous ] && printf 'yes\n' || printf 'no\n'
                    ;;
                User|Group)
                    if [ "$CF_UNIT_STATE" = previous ]; then
                        printf 'cloudflared\n'
                    elif [ "$CF_UNIT_STATE" = current_user ]; then
                        printf 'nobody\n'
                    else
                        printf 'root\n'
                    fi
                    ;;
                WorkingDirectory) printf '/\n' ;;
                PrivateNetwork) printf 'no\n' ;;
                PrivateUsers|PrivateMounts|RootEphemeral) printf 'no\n' ;;
                PrivateTmp|ProtectHome)
                    [ "$CF_UNIT_STATE" = legacy ] && printf 'no\n' || printf 'yes\n'
                    ;;
                ProtectSystem)
                    [ "$CF_UNIT_STATE" = legacy ] && printf 'no\n' || printf 'strict\n'
                    ;;
                BindReadOnlyPaths)
                    [ "$CF_UNIT_STATE" = current_bind ] && \
                        printf '/var/lib/rr-vps:/hidden\n'
                    :
                    ;;
                Environment)
                    [ "$CF_UNIT_STATE" = current_env ] && \
                        printf 'LD_PRELOAD=/tmp/third-party.so\n'
                    :
                    ;;
                PAMName)
                    [ "$CF_UNIT_STATE" = current_pam ] && printf 'login\n'
                    :
                    ;;
                SystemCallFilter)
                    if [ "$CF_UNIT_STATE" = current_syscall ]; then
                        printf '~statx\n'
                    else
                        printf '~\n'
                    fi
                    ;;
                SystemCallErrorNumber) printf '2147483646\n' ;;
                RootDirectory|RootImage|MountImages|ExtensionImages|ExtensionDirectories|TemporaryFileSystem|BindPaths|InaccessiblePaths|JoinsNamespaceOf|ReadOnlyPaths|ReadWritePaths|EnvironmentFiles|PassEnvironment) ;;
                *) return 91 ;;
            esac
            ;;
        daemon-reload)
            printf 'daemon-reload\n' >> "$CF_SYSTEMCTL_LOG"
            if [ "${CF_DAEMON_RELOAD_FAILURES:-0}" -gt 0 ]; then
                CF_DAEMON_RELOAD_FAILURES=$((CF_DAEMON_RELOAD_FAILURES - 1))
                return 1
            fi
            CF_UNIT_STATE=current
            ;;
        enable)
            printf 'enable %s\n' "$*" >> "$CF_SYSTEMCTL_LOG"
            if [ "$CF_UNIT_STATE" = current ] || [ "$CF_UNIT_STATE" = current_gate ]; then
                CF_UNIT_ACTIVE=true
            else
                return 1
            fi
            ;;
        stop)
            printf 'stop %s\n' "$*" >> "$CF_SYSTEMCTL_LOG"
            [ "${CF_STOP_FAILURE:-false}" != true ] || return 1
            CF_UNIT_ACTIVE=false
            ;;
        is-active)
            [ "$CF_UNIT_ACTIVE" = true ]
            ;;
        *)
            printf 'unexpected %s %s\n' "$action" "$*" >> "$CF_SYSTEMCTL_LOG"
            return 92
            ;;
    esac
}

cf_setup() {
    load_modules
    CF_ROOT=$(mktemp -d)
    chmod 700 "$CF_ROOT"
    RR_CF_TOKEN_FILE="$CF_ROOT/token"
    RR_CLOUDFLARED_SERVICE_FILE="$CF_ROOT/cloudflared.service"
    RR_CLOUDFLARED_BIN=/bin/true
    CF_BIN=$(readlink -f -- "$RR_CLOUDFLARED_BIN")
    CF_SYSTEMCTL_LOG="$CF_ROOT/systemctl.log"
    CF_SYSTEMCTL_ALL_LOG="$CF_ROOT/systemctl-all.log"
    CF_INSTALL_LOG="$CF_ROOT/install.log"
    : > "$CF_SYSTEMCTL_LOG"
    : > "$CF_SYSTEMCTL_ALL_LOG"
    : > "$CF_INSTALL_LOG"
    chmod 600 "$CF_SYSTEMCTL_LOG"
    chmod 600 "$CF_SYSTEMCTL_ALL_LOG"
    chmod 600 "$CF_INSTALL_LOG"
    CF_UNIT_STATE=absent
    CF_UNIT_ACTIVE=false
    CF_DAEMON_RELOAD_FAILURES=0
    CF_STOP_FAILURE=false
    CF_LEGACY_TOKEN='eyJh-valid-legacy-token_0123456789='
    CF_LEGACY_KIND=inline
    RR_LEGACY_CLOUDFLARED_TOKEN_FILE="$CF_ROOT/legacy-cloudflared/token"
    RR_RESTORE_SYSTEMD_DIR="$CF_ROOT/systemd"
    CF_RESTORE_DROPIN="${RR_RESTORE_SYSTEMD_DIR}/cloudflared.service.d/zzzz-rr-restore-gate.conf"
    cloudflared_token_file_supported() { return 0; }
    install_cloudflared() {
        printf 'install\n' >> "$CF_INSTALL_LOG"
        [ "${CF_INSTALL_SUCCESS:-true}" = true ]
    }
    systemctl() { cf_systemctl "$@"; }
}

cf_write_safe_token() {
    local value="$1"
    (umask 077; printf '%s\n' "$value" > "$RR_CF_TOKEN_FILE")
    chown 0:0 "$RR_CF_TOKEN_FILE"
    chmod 600 "$RR_CF_TOKEN_FILE"
}

cf_write_legacy_token() {
    local value="$1"
    install -d -o 0 -g 0 -m "${CF_LEGACY_DIR_MODE:-700}" -- \
        "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")"
    (umask 077; printf '%s' "$value" > "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")
    chown 0:0 "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE"
    chmod 600 "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE"
}

cf_write_current_unit() {
    rr_render_fixed_argo_service "$CF_BIN" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
}

printf '[5/14] current fixed unit hides the token and proves exact ownership\n'
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    secret='eyJh-secret-token-that-must-not-leak_0123456789='
    cf_write_safe_token "$secret"
    cf_write_current_unit
    CF_UNIT_STATE=current
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    rr_fixed_argo_service_is_owned
    expected_argo_tunnel_running
    [ "$(stat -c '%u:%g:%a:%h' "$RR_CF_TOKEN_FILE")" = '0:0:600:1' ]
    grep -Fq "LoadCredential=rr-tunnel-token:${RR_CF_TOKEN_FILE}" "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'tunnel run --token-file %d/rr-tunnel-token' "$RR_CLOUDFLARED_SERVICE_FILE"
    ! grep -Fq -- "$secret" "$RR_CLOUDFLARED_SERVICE_FILE"
    ! grep -Eq 'ExecStart=.*--token([=[:space:]])' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'DynamicUser=no' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'User=root' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'Group=root' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'PrivateUsers=no' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'PrivateMounts=no' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'ProtectSystem=strict' "$RR_CLOUDFLARED_SERVICE_FILE"
)

printf '[6/14] absent service creation preserves a pre-provisioned safe token\n'
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    secret='eyJh-preprovisioned-token_0123456789='
    cf_write_safe_token "$secret"
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    rr_fixed_argo_service_is_owned
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = $'daemon-reload\nenable --now cloudflared' ]
    ! grep -Fq -- "$secret" "$RR_CLOUDFLARED_SERVICE_FILE"
)

printf '[7/14] exact current service refresh is byte-and-metadata idempotent\n'
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-current-token_0123456789='
    cf_write_current_unit
    CF_UNIT_STATE=current
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = 'enable --now cloudflared' ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-current-stop-token_0123456789='
    cf_write_current_unit
    CF_UNIT_STATE=current
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    CF_QUICK_STOP_CALLS=0
    stop_quick_argo_tunnel() { CF_QUICK_STOP_CALLS=$((CF_QUICK_STOP_CALLS + 1)); }
    quick_argo_running() { return 1; }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    rr_stop_all_argo_tunnels_for_menu
    [ "$CF_QUICK_STOP_CALLS" -eq 1 ]
    [ "$CF_UNIT_ACTIVE" = false ]
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = 'stop cloudflared' ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-toggle-config-failure-token_0123456789='
    cf_write_current_unit
    CF_UNIT_STATE=current
    CF_UNIT_ACTIVE=true
    CF_CONFIG_WRITES=0
    load_config_with_defaults() {
        VM_ENABLED=true
        VM_TLS_ENABLED=false
        TUNNEL_MODE=2
        return 0
    }
    apply_config_transaction() {
        CF_CONFIG_WRITES=$((CF_CONFIG_WRITES + 1))
        return 1
    }
    stop_quick_argo_tunnel() { return 0; }
    quick_argo_running() { return 1; }
    clear() { return 0; }
    sleep() { return 0; }
    read() {
        if [ "${1:-}" = -p ]; then
            local target="${!#}"
            printf -v "$target" '%s' 1
        else
            builtin read "$@"
        fi
    }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if toggle_argo >/dev/null; then
        echo 'Toggle reported success after disabled-config commit failed.' >&2
        exit 1
    fi
    [ "$CF_CONFIG_WRITES" -eq 1 ]
    [ "$CF_UNIT_ACTIVE" = true ]
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = \
        $'stop cloudflared\nenable --now cloudflared' ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-missing-binary-current-token_0123456789='
    install -d -o 0 -g 0 -m 755 -- "$CF_ROOT/bin"
    RR_CLOUDFLARED_BIN="$CF_ROOT/bin/cloudflared"
    CF_BIN="$RR_CLOUDFLARED_BIN"
    cf_write_current_unit
    CF_UNIT_STATE=current
    CF_UNIT_ACTIVE=false
    CF_SUPPORTED=false
    cloudflared_token_file_supported() { [ "$CF_SUPPORTED" = true ]; }
    install_cloudflared() {
        printf 'install\n' >> "$CF_INSTALL_LOG"
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$RR_CLOUDFLARED_BIN"
        chown 0:0 "$RR_CLOUDFLARED_BIN"
        chmod 755 "$RR_CLOUDFLARED_BIN"
        CF_SUPPORTED=true
    }
    VM_ENABLED=true
    VM_TLS_ENABLED=false
    TUNNEL_MODE=2
    load_config_with_defaults() { return 0; }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    [ "$(rr_fixed_argo_start_classification)" = current ]
    start_argo_tunnel
    [ "$(cat "$CF_INSTALL_LOG")" = install ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    # Installation creates the previously missing executable, but the exact
    # unit inode/bytes/metadata remain idempotent.
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    expected_argo_tunnel_running
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-current-gated-token_0123456789='
    cf_write_current_unit
    install -d -o 0 -g 0 -m 755 -- "$(dirname "$CF_RESTORE_DROPIN")"
    cat > "$CF_RESTORE_DROPIN" <<'EOF'
[Service]
ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'
EOF
    chown 0:0 "$CF_RESTORE_DROPIN"
    chmod 644 "$CF_RESTORE_DROPIN"
    CF_UNIT_STATE=current_gate
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = 'enable --now cloudflared' ]
)

printf '[8/14] exact RR 7.1 legacy unit migrates token atomically\n'
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_safe_token "$CF_LEGACY_TOKEN"
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 600 "$RR_CLOUDFLARED_SERVICE_FILE"
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    [ "$(stat -c %a -- "$RR_CLOUDFLARED_SERVICE_FILE")" = 600 ]
    [ "$(stat -c %a -- "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")")" = 700 ]
    [ "$(wc -l < "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" -eq 0 ]
    rr_cloudflared_legacy_token_file_is_safe
    [ "$(rr_cloudflared_service_token)" = "$CF_LEGACY_TOKEN" ]
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    if expected_argo_tunnel_running; then
        echo 'A legacy unit was reported as the current runnable RR service.' >&2
        exit 1
    fi
    CF_QUICK_STOP_CALLS=0
    stop_quick_argo_tunnel() { CF_QUICK_STOP_CALLS=$((CF_QUICK_STOP_CALLS + 1)); }
    quick_argo_running() { return 1; }
    if rr_stop_all_argo_tunnels_for_menu; then
        echo 'The menu stop path acted on an unmigrated legacy service.' >&2
        exit 1
    fi
    [ "$CF_QUICK_STOP_CALLS" -eq 0 ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    VM_ENABLED=true
    VM_TLS_ENABLED=false
    load_config_with_defaults() { return 0; }
    start_argo_tunnel
    [ "$(cat "$CF_INSTALL_LOG")" = install ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cat "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" = "$CF_LEGACY_TOKEN" ]
    rr_cloudflared_token_file_is_safe
    [ "$(cat "$RR_CF_TOKEN_FILE")" = "$CF_LEGACY_TOKEN" ]
    rr_fixed_argo_service_is_owned
    expected_argo_tunnel_running
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = $'daemon-reload\nenable --now cloudflared' ]
    ! grep -Fq -- "$CF_LEGACY_TOKEN" "$RR_CLOUDFLARED_SERVICE_FILE"
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-previous-dynamic-user-token_0123456789='
    rr_render_previous_fixed_argo_service "$CF_BIN" > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=previous
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    rr_previous_fixed_argo_service_is_exact
    [ "$(rr_fixed_argo_start_classification)" = legacy ]
    if expected_argo_tunnel_running; then
        echo 'The previous DynamicUser unit was reported runnable before migration.' >&2
        exit 1
    fi
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" != "$unit_before" ]
    rr_fixed_argo_service_is_owned
    expected_argo_tunnel_running
    grep -Fq 'DynamicUser=no' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'User=root' "$RR_CLOUDFLARED_SERVICE_FILE"
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-previous-staged-reload-token_0123456789='
    rr_render_previous_fixed_argo_service "$CF_BIN" > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=previous
    CF_UNIT_ACTIVE=true
    CF_DAEMON_RELOAD_FAILURES=1
    if ensure_fixed_argo_service; then
        echo 'A failed previous-current daemon-reload was reported successful.' >&2
        exit 1
    fi
    [ "$CF_UNIT_STATE" = previous ]
    rr_fixed_argo_service_file_is_owned
    token_staged=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_staged=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_staged" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_staged" ]
    rr_fixed_argo_service_is_owned
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    CF_LEGACY_DIR_MODE=755
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    [ "$(stat -c %a -- "$RR_CLOUDFLARED_SERVICE_FILE")" = 644 ]
    [ "$(stat -c %a -- "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")")" = 755 ]
    ensure_fixed_argo_service
    rr_cloudflared_token_file_is_safe
    [ "$(cat "$RR_CF_TOKEN_FILE")" = "$CF_LEGACY_TOKEN" ]
    rr_fixed_argo_service_is_owned
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_safe_token "$CF_LEGACY_TOKEN"
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 600 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_DAEMON_RELOAD_FAILURES=1
    if ensure_fixed_argo_service; then
        echo 'A failed daemon-reload was reported as success.' >&2
        exit 1
    fi
    [ "$CF_UNIT_STATE" = legacy ]
    rr_fixed_argo_service_file_is_owned
    token_staged=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_staged=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_staged" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_staged" ]
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = $'daemon-reload\ndaemon-reload\nenable --now cloudflared' ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-staged-absent-token_0123456789='
    CF_DAEMON_RELOAD_FAILURES=1
    if ensure_fixed_argo_service; then
        echo 'An absent-service reload fault was reported as success.' >&2
        exit 1
    fi
    [ "$CF_UNIT_STATE" = absent ]
    rr_fixed_argo_service_file_is_owned
    token_staged=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_staged=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_staged" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_staged" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    cf_write_safe_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_unit cloudflared 15 "$CF_BIN" \
        "$CF_LEGACY_TOKEN" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 600 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_FAIL_SERVICE_DIR_SYNC=true
    sync() {
        if [ "${1:-}" = -f ] && [ "${2:-}" = "$CF_ROOT" ] && \
           [ "$CF_FAIL_SERVICE_DIR_SYNC" = true ]; then
            CF_FAIL_SERVICE_DIR_SYNC=false
            return 1
        fi
        command sync "$@"
    }
    if ensure_fixed_argo_service; then
        echo 'A failed post-rename directory fsync was reported as success.' >&2
        exit 1
    fi
    [ "$CF_UNIT_STATE" = legacy ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    rr_fixed_argo_service_file_is_owned
    token_staged=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_staged=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    ensure_fixed_argo_service
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_staged" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_staged" ]
)

printf '[9/14] third-party units and stale tokens are rejected with zero writes\n'
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_safe_token 'eyJh-different-rr-token_0123456789='
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 600 "$RR_CLOUDFLARED_SERVICE_FILE"
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    legacy_token_before=$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if ensure_fixed_argo_service; then
        echo 'A legacy service with a mismatched RR token was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" = "$legacy_token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-stale-rr-token_0123456789='
    printf '%s\n' '[Unit]' 'Description=Third-party cloudflared' > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=thirdparty
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    VM_ENABLED=true
    VM_TLS_ENABLED=false
    load_config_with_defaults() { return 0; }
    CF_QUICK_STOP_CALLS=0
    stop_quick_argo_tunnel() { CF_QUICK_STOP_CALLS=$((CF_QUICK_STOP_CALLS + 1)); }
    quick_argo_running() { return 1; }
    # Model an installed but unsupported/old binary.  The fixed start path
    # must reject the foreign service before it can call the downloader/dpkg
    # wrapper, even though a stale RR token exists beside it.
    cloudflared_token_file_supported() { return 1; }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if expected_argo_tunnel_running; then
        echo 'An active third-party service was reported as RR healthy.' >&2
        exit 1
    fi
    if start_argo_tunnel; then
        echo 'The fixed start path accepted a third-party service.' >&2
        exit 1
    fi
    if rr_stop_all_argo_tunnels_for_menu; then
        echo 'The menu stop path stopped a third-party service.' >&2
        exit 1
    fi
    [ "$CF_QUICK_STOP_CALLS" -eq 0 ]
    if ensure_fixed_argo_service; then
        echo 'A third-party service paired with a stale RR token was overwritten.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ "$CF_UNIT_ACTIVE" = true ]
    [ ! -s "$CF_INSTALL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-toggle-enable-stale-token_0123456789='
    printf '%s\n' '[Unit]' 'Description=Foreign active Cloudflared' > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=thirdparty
    CF_UNIT_ACTIVE=true
    CF_CONFIG_WRITES=0
    CF_SINGBOX_CORE_CALLS=0
    load_config_with_defaults() {
        VM_ENABLED=false
        VM_TLS_ENABLED=false
        TUNNEL_MODE=2
        PORT=18080
        return 0
    }
    ensure_singbox_core() {
        CF_SINGBOX_CORE_CALLS=$((CF_SINGBOX_CORE_CALLS + 1))
        return 0
    }
    is_valid_port() { return 0; }
    apply_config_transaction() { CF_CONFIG_WRITES=$((CF_CONFIG_WRITES + 1)); }
    clear() { return 0; }
    sleep() { return 0; }
    read() {
        if [ "${1:-}" = -p ]; then
            local target="${!#}"
            printf -v "$target" '%s' 1
        else
            builtin read "$@"
        fi
    }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if toggle_argo >/dev/null; then
        echo 'Fixed-mode toggle enabled across a foreign Cloudflared service.' >&2
        exit 1
    fi
    [ "$CF_CONFIG_WRITES" -eq 0 ]
    [ "$CF_SINGBOX_CORE_CALLS" -eq 0 ]
    [ ! -s "$CF_INSTALL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ] && [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-toggle-disable-stale-token_0123456789='
    printf '%s\n' '[Unit]' 'Description=Foreign active Cloudflared' > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=thirdparty
    CF_UNIT_ACTIVE=true
    CF_CONFIG_WRITES=0
    load_config_with_defaults() {
        VM_ENABLED=true
        VM_TLS_ENABLED=false
        TUNNEL_MODE=2
        return 0
    }
    apply_config_transaction() { CF_CONFIG_WRITES=$((CF_CONFIG_WRITES + 1)); }
    stop_quick_argo_tunnel() { return 0; }
    quick_argo_running() { return 1; }
    clear() { return 0; }
    sleep() { return 0; }
    read() {
        if [ "${1:-}" = -p ]; then
            local target="${!#}"
            printf -v "$target" '%s' 1
        else
            builtin read "$@"
        fi
    }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if toggle_argo >/dev/null; then
        echo 'Fixed-mode toggle disabled a foreign Cloudflared service.' >&2
        exit 1
    fi
    [ "$CF_CONFIG_WRITES" -eq 0 ]
    [ "$CF_UNIT_ACTIVE" = true ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ] && [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-toggle-stop-failure-token_0123456789='
    cf_write_current_unit
    CF_UNIT_STATE=current
    CF_UNIT_ACTIVE=true
    CF_STOP_FAILURE=true
    CF_CONFIG_WRITES=0
    load_config_with_defaults() {
        VM_ENABLED=true
        VM_TLS_ENABLED=false
        TUNNEL_MODE=2
        return 0
    }
    apply_config_transaction() { CF_CONFIG_WRITES=$((CF_CONFIG_WRITES + 1)); }
    stop_quick_argo_tunnel() { return 0; }
    quick_argo_running() { return 1; }
    clear() { return 0; }
    sleep() { return 0; }
    read() {
        if [ "${1:-}" = -p ]; then
            local target="${!#}"
            printf -v "$target" '%s' 1
        else
            builtin read "$@"
        fi
    }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if toggle_argo >/dev/null; then
        echo 'Toggle committed disabled config after cloudflared stop failed.' >&2
        exit 1
    fi
    [ "$CF_CONFIG_WRITES" -eq 0 ]
    [ "$CF_UNIT_ACTIVE" = true ]
    [ "$(cat "$CF_SYSTEMCTL_LOG")" = 'stop cloudflared' ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-post-update-stale-token_0123456789='
    printf '%s\n' '[Unit]' 'Description=Administrator Cloudflared' > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=thirdparty
    CF_UNIT_ACTIVE=true
    CONFIG_FILE="$CF_ROOT/config"
    : > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    NEXUS_SERVICE_FILE="$CF_ROOT/no-nexus.service"
    RR_UPDATE_TRANSACTION=1
    RR_UPDATE_ARGO_WAS_RUNNING=false
    RR_UPDATE_SINGBOX_WAS_RUNNING=false
    RR_UPDATE_NEXUS_WAS_RUNNING=false
    RR_UPDATE_SUBSCRIPTION_WAS_RUNNING=false
    RR_UPDATE_HEALTH_TIMER_WAS_ENABLED=false
    CF_POST_UPDATE_SYSTEMCTL_LOG="$CF_ROOT/post-update-systemctl.log"
    : > "$CF_POST_UPDATE_SYSTEMCTL_LOG"
    check_supported_os() { return 0; }
    stop_subscription_servers() { return 0; }
    migrate_config_schema() { return 0; }
    load_config_with_defaults() {
        NAIVE_ENABLED=false
        INSTALL_COMPLETE=true
        VM_ENABLED=true
        VM_TLS_ENABLED=false
        TUNNEL_MODE=2
        SINGBOX_AUTO_RESTART=false
        return 0
    }
    any_node_protocol_enabled() { return 1; }
    stop_singbox_instances() { return 0; }
    generate_node_and_sub() { return 0; }
    crontab() { return 1; }
    sleep() { return 0; }
    # Deliberately terminate after the Argo branch; this fixture verifies the
    # action-point decision without exercising unrelated health publication.
    write_health_monitor_units() { return 1; }
    systemctl() {
        case "$*" in
            'stop sing-box'|'stop rr-subscription'|'stop rr-nexus')
                printf '%s\n' "$*" >> "$CF_POST_UPDATE_SYSTEMCTL_LOG"
                ;;
            'stop cloudflared')
                printf '%s\n' "$*" >> "$CF_POST_UPDATE_SYSTEMCTL_LOG"
                CF_UNIT_ACTIVE=false
                ;;
            *) cf_systemctl "$@" ;;
        esac
    }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if post_update_migrate >/dev/null 2>&1; then
        echo 'The bounded post-update stop fixture unexpectedly completed.' >&2
        exit 1
    fi
    ! grep -Fxq 'stop cloudflared' "$CF_POST_UPDATE_SYSTEMCTL_LOG"
    [ "$CF_UNIT_ACTIVE" = true ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    install -d -o 0 -g 0 -m 755 -- "$CF_ROOT/bin"
    RR_CLOUDFLARED_BIN="$CF_ROOT/bin/cloudflared"
    CF_BIN="$RR_CLOUDFLARED_BIN"
    cf_write_safe_token 'eyJh-stale-token-missing-binary_0123456789='
    printf '%s\n' '[Unit]' 'Description=Foreign service with missing executable' \
        > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    CF_UNIT_STATE=thirdparty
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    VM_ENABLED=true
    VM_TLS_ENABLED=false
    load_config_with_defaults() { return 0; }
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if start_argo_tunnel; then
        echo 'A missing shared binary authorized installation for a foreign service.' >&2
        exit 1
    fi
    [ ! -e "$RR_CLOUDFLARED_BIN" ] && [ ! -L "$RR_CLOUDFLARED_BIN" ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ "$CF_UNIT_ACTIVE" = true ]
    [ ! -s "$CF_INSTALL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=thirdparty
    cat > "$RR_CLOUDFLARED_SERVICE_FILE" <<EOF
[Unit]
Description=Third-party Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=${CF_BIN} --no-autoupdate tunnel run --token ${CF_LEGACY_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if ensure_fixed_argo_service; then
        echo 'An arbitrary third-party --token service was treated as RR legacy.' >&2
        exit 1
    fi
    [ ! -e "$RR_CF_TOKEN_FILE" ] && [ ! -L "$RR_CF_TOKEN_FILE" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)

printf '[10/14] unsafe token evidence and effective-unit drift fail closed\n'
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 666 "$RR_CLOUDFLARED_SERVICE_FILE"
    legacy_token_before=$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if ensure_fixed_argo_service; then
        echo 'A group/world-writable upstream legacy unit was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" = "$legacy_token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -e "$RR_CF_TOKEN_FILE" ] && [ ! -L "$RR_CF_TOKEN_FILE" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ] && [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    chmod 777 "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    directory_before=$(stat -c '%d:%i:%u:%g:%a:%h:%Y:%Z' -- \
        "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")")
    legacy_token_before=$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if ensure_fixed_argo_service; then
        echo 'A world-writable upstream token directory was accepted.' >&2
        exit 1
    fi
    [ "$directory_before" = "$(stat -c '%d:%i:%u:%g:%a:%h:%Y:%Z' -- \
        "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")")" ]
    [ "$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" = "$legacy_token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -e "$RR_CF_TOKEN_FILE" ] && [ ! -L "$RR_CF_TOKEN_FILE" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ] && [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    if chown 1:1 "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" 2>/dev/null; then
        CF_INJECT_NONROOT_STAT=false
    else
        CF_INJECT_NONROOT_STAT=true
    fi
    legacy_token_before=$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if [ "$CF_INJECT_NONROOT_STAT" = true ]; then
        # Some idmapped sandboxes map only uid 0.  There, inject the exact
        # lstat evidence; normal CI performs the real ownership mutation.
        stat() {
            local format="${2:-}" path="${!#}" size=""
            if [ "${1:-}" = -c ] && [ "$format" = '%u:%g:%h:%a:%s' ] && \
               [ "$path" = "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" ]; then
                size=$(command stat -c %s -- "$path") || return 1
                printf '1:1:1:600:%s\n' "$size"
                return 0
            fi
            command stat "$@"
        }
    fi
    if ensure_fixed_argo_service; then
        echo 'A non-root-owned upstream legacy token was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" = "$legacy_token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -e "$RR_CF_TOKEN_FILE" ] && [ ! -L "$RR_CF_TOKEN_FILE" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ] && [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    actual_dir="$CF_ROOT/actual-cloudflared"
    install -d -o 0 -g 0 -m 700 -- "$actual_dir"
    (umask 077; printf '%s' "$CF_LEGACY_TOKEN" > "$actual_dir/token")
    chown 0:0 "$actual_dir/token"
    chmod 600 "$actual_dir/token"
    ln -s "$actual_dir" "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    target_before=$(cf_snapshot "$actual_dir/token")
    link_before=$(cf_snapshot "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if ensure_fixed_argo_service; then
        echo 'A symlinked upstream token directory was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$actual_dir/token")" = "$target_before" ]
    [ "$(cf_snapshot "$(dirname "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")")" = "$link_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -e "$RR_CF_TOKEN_FILE" ] && [ ! -L "$RR_CF_TOKEN_FILE" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ] && [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    CF_UNIT_STATE=legacy
    CF_LEGACY_KIND=token-file
    cf_write_legacy_token "$CF_LEGACY_TOKEN"
    printf '\n' >> "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE"
    cf_render_legacy_token_file_unit "$CF_BIN" \
        "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE" > "$RR_CLOUDFLARED_SERVICE_FILE"
    chown 0:0 "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    legacy_token_before=$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if ensure_fixed_argo_service; then
        echo 'A newline-modified upstream legacy token was accepted.' >&2
        exit 1
    fi
    [ ! -e "$RR_CF_TOKEN_FILE" ] && [ ! -L "$RR_CF_TOKEN_FILE" ]
    [ "$(cf_snapshot "$RR_LEGACY_CLOUDFLARED_TOKEN_FILE")" = "$legacy_token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-world-readable-token_0123456789='
    chmod 644 "$RR_CF_TOKEN_FILE"
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    if ensure_fixed_argo_service; then
        echo 'A world-readable tunnel token was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ ! -e "$RR_CLOUDFLARED_SERVICE_FILE" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    real_token="$CF_ROOT/real-token"
    RR_CF_TOKEN_FILE="$CF_ROOT/token-link"
    (umask 077; printf '%s\n' 'eyJh-symlink-token_0123456789=' > "$real_token")
    chown 0:0 "$real_token"
    chmod 600 "$real_token"
    ln -s "$real_token" "$RR_CF_TOKEN_FILE"
    target_before=$(cf_snapshot "$real_token")
    link_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    if ensure_fixed_argo_service; then
        echo 'A symlink tunnel token was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$real_token")" = "$target_before" ]
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$link_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-hardlinked-token_0123456789='
    ln "$RR_CF_TOKEN_FILE" "$CF_ROOT/token-hardlink"
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    hardlink_before=$(cf_snapshot "$CF_ROOT/token-hardlink")
    if ensure_fixed_argo_service; then
        echo 'A hard-linked tunnel token was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$CF_ROOT/token-hardlink")" = "$hardlink_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
    [ ! -s "$CF_SYSTEMCTL_ALL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-effective-drift-token_0123456789='
    cf_write_current_unit
    CF_UNIT_STATE=current_tampered
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    if expected_argo_tunnel_running; then
        echo 'An active unit with an effective third-party drop-in was reported healthy.' >&2
        exit 1
    fi
    if ensure_fixed_argo_service; then
        echo 'An effective third-party drop-in was accepted.' >&2
        exit 1
    fi
    [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
    [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
    [ ! -s "$CF_SYSTEMCTL_LOG" ]
)
(
    cf_setup
    trap 'rm -rf "$CF_ROOT"' EXIT
    cf_write_safe_token 'eyJh-effective-namespace-token_0123456789='
    cf_write_current_unit
    CF_UNIT_ACTIVE=true
    TUNNEL_MODE=2
    token_before=$(cf_snapshot "$RR_CF_TOKEN_FILE")
    unit_before=$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")
    for CF_UNIT_STATE in current_env current_bind current_user current_pam \
        current_syscall; do
        : > "$CF_SYSTEMCTL_LOG"
        if rr_fixed_argo_service_is_owned || expected_argo_tunnel_running || \
           ensure_fixed_argo_service; then
            echo "Unsafe effective identity was accepted: $CF_UNIT_STATE" >&2
            exit 1
        fi
        [ "$(cf_snapshot "$RR_CF_TOKEN_FILE")" = "$token_before" ]
        [ "$(cf_snapshot "$RR_CLOUDFLARED_SERVICE_FILE")" = "$unit_before" ]
        [ "$CF_UNIT_ACTIVE" = true ]
        [ ! -s "$CF_SYSTEMCTL_LOG" ]
    done
)

printf '[11/14] API limits and transport failures use the verified official fallback\n'
for case_name in api_403 api_429 api_403_redirect api_429_redirect \
    api_500 api_503 api_timeout api_dns api_connect; do
    run_install_case "$case_name"
done

printf '[12/14] fallback never masks bad metadata, bad artifacts or unsupported hosts\n'
for case_name in api_401 api_404 api_write_failure api_size_limit fallback_bad_pin fallback_wrong_size \
    fallback_invalid_deb fallback_installed_mismatch unsupported_arch; do
    run_install_case "$case_name"
done

printf '[13/14] production fallback pins bind both architectures to one official release\n'
(
    load_modules
    [ "$(rr_cloudflared_fallback_release amd64)" = "$(printf '%s\n' \
        2026.9.1 \
        https://github.com/cloudflare/cloudflared/releases/download/2026.9.1/cloudflared-linux-amd64.deb \
        3be76adc4185d36a0bfb4c2dd8663292f0ed363797f2180333b513b43c81d419 \
        19160216)" ]
    [ "$(rr_cloudflared_fallback_release arm64)" = "$(printf '%s\n' \
        2026.9.1 \
        https://github.com/cloudflare/cloudflared/releases/download/2026.9.1/cloudflared-linux-arm64.deb \
        2a870d5bf6ea74d16c0923b804eabbf4943f1fd7c63a5c20fd41cc66b629c725 \
        17667370)" ]
    for arch in riscv64 i386 '' '../amd64'; do
        rejected_output=''
        if rejected_output=$(rr_cloudflared_fallback_release "$arch"); then
            echo "Unsupported fallback architecture was accepted: $arch" >&2
            exit 1
        fi
        [ -z "$rejected_output" ]
    done
)

printf '[14/14] compatible installed binaries and update transactions never acquire packages\n'
(
    load_modules
    SYS_ARCH=amd64
    CF_ACTIVITY_LOG=$(mktemp)
    trap 'rm -f "$CF_ACTIVITY_LOG"' EXIT
    curl() { printf 'curl\n' >> "$CF_ACTIVITY_LOG"; return 99; }
    dpkg() { printf 'dpkg\n' >> "$CF_ACTIVITY_LOG"; return 99; }
    apt-get() { printf 'apt-get\n' >> "$CF_ACTIVITY_LOG"; return 99; }
    rr_cloudflared_fallback_release() { printf 'fallback\n' >> "$CF_ACTIVITY_LOG"; return 99; }
    cloudflared() {
        [ -n "$CF_VERSION" ] || return 127
        printf 'cloudflared version %s\n' "$CF_VERSION"
    }
    for RR_UPDATE_TRANSACTION in 0 1; do
        for CF_VERSION in 2025.4.0 2026.9.1; do
            install_cloudflared >/dev/null 2>&1
            [ ! -s "$CF_ACTIVITY_LOG" ]
        done
    done
    RR_UPDATE_TRANSACTION=1
    for CF_VERSION in '' 2025.3.9; do
        if install_cloudflared >/dev/null 2>&1; then
            echo "Transaction attempted to accept a missing/old cloudflared: $CF_VERSION" >&2
            exit 1
        fi
        [ ! -s "$CF_ACTIVITY_LOG" ]
    done
)

echo 'Cloudflared supply-chain regressions passed.'
