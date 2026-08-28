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
        none) ;;
        *) return 99 ;;
    esac

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
    CF_INSTALLED=false
    CF_INSTALLED_TAG="$installed_tag"
    CF_PACKAGE_VALID="$package_valid"

    curl() {
        local output='' argument='' last=''
        printf '%q ' "$@" >> "$CF_CURL_LOG"
        printf '\n' >> "$CF_CURL_LOG"
        while [ "$#" -gt 0 ]; do
            argument="$1"
            shift
            if [ "$argument" = --output ]; then
                [ "$#" -gt 0 ] || return 2
                output="$1"
                shift
                continue
            fi
            last="$argument"
        done
        [ -n "$output" ] || return 2
        if [ "$last" = "$RR_CLOUDFLARED_RELEASE_API" ]; then
            printf '%s' "$CF_METADATA" > "$output"
        else
            [ "$last" = "$url" ] || return 3
            printf '%s' "$CF_PAYLOAD" > "$output"
        fi
    }
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

    if install_cloudflared >/dev/null 2>&1; then
        [ "$mutation" = none ] || {
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
        [ "$mutation" != none ] || {
            echo 'Valid cloudflared release metadata was rejected.' >&2
            return 1
        }
        [ "$CF_INSTALLED" = false ] || [ "$mutation" = installed_mismatch ]
    fi
    rm -f "$CF_CURL_LOG"
)

printf '[1/5] exact release, asset URL, checksum and installed version\n'
run_install_case none

printf '[2/5] unstable, old, duplicate and unbound releases fail closed\n'
for case_name in draft prerelease old wrong_url duplicate; do
    run_install_case "$case_name"
done

printf '[3/5] checksum, package and post-install gates fail closed\n'
for case_name in missing_checksum ambiguous_checksum api_mismatch download_mismatch invalid_deb installed_mismatch; do
    run_install_case "$case_name"
done

printf '[4/5] token-file version boundary\n'
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

printf '[5/5] fixed tunnel token never enters unit or process arguments\n'
(
    load_modules
    fixed_root=$(mktemp -d)
    trap 'rm -rf "$fixed_root"' EXIT
    RR_CF_TOKEN_FILE="$fixed_root/token"
    RR_CLOUDFLARED_SERVICE_FILE="$fixed_root/cloudflared.service"
    RR_CLOUDFLARED_BIN=/bin/true
    secret='eyJh-secret-token-that-must-not-leak'
    (umask 077; printf '%s\n' "$secret" > "$RR_CF_TOKEN_FILE")
    cloudflared_token_file_supported() { return 0; }
    systemctl() { return 0; }
    rr_write_fixed_argo_service
    [ "$(stat -c '%u:%a' "$RR_CF_TOKEN_FILE")" = '0:600' ]
    grep -Fq "LoadCredential=rr-tunnel-token:${RR_CF_TOKEN_FILE}" "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'tunnel run --token-file %d/rr-tunnel-token' "$RR_CLOUDFLARED_SERVICE_FILE"
    ! grep -Fq -- "$secret" "$RR_CLOUDFLARED_SERVICE_FILE"
    ! grep -Eq 'ExecStart=.*--token([=[:space:]])' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'DynamicUser=yes' "$RR_CLOUDFLARED_SERVICE_FILE"
    grep -Fq 'ProtectSystem=strict' "$RR_CLOUDFLARED_SERVICE_FILE"

    chmod 644 "$RR_CF_TOKEN_FILE"
    if rr_write_fixed_argo_service; then
        echo 'A world-readable tunnel token was accepted.' >&2
        exit 1
    fi
    chmod 600 "$RR_CF_TOKEN_FILE"
    ln -s "$RR_CF_TOKEN_FILE" "$fixed_root/token-link"
    RR_CF_TOKEN_FILE="$fixed_root/token-link"
    if rr_write_fixed_argo_service; then
        echo 'A symlink tunnel token was accepted.' >&2
        exit 1
    fi
)

echo 'Cloudflared supply-chain regressions passed.'
