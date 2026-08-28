#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

RR_LIB_DIR="$REPO_ROOT"
RR_REPOSITORY="example/rr-vps"
# shellcheck disable=SC1091
source modules/85-nexus.sh

# Keep stable aliases for the production implementations before the staged
# fixtures below replace their public names.  This makes every fixture
# definition precede its call while still exercising the sourced production
# bodies in sections 4 and 6.
eval "$(declare -f nexus_pip_install_local_wheel | \
    sed '1s/nexus_pip_install_local_wheel/nexus_pip_install_local_wheel_production/')"
eval "$(declare -f nexus_install_grpcio_pip_fallback | \
    sed '1s/nexus_install_grpcio_pip_fallback/nexus_install_grpcio_pip_fallback_production/')"

wheel_payload="$test_root/wheel.payload"
printf '%s' 'verified grpcio wheel fixture' > "$wheel_payload"
wheel_digest=$(sha256sum "$wheel_payload")
wheel_digest="${wheel_digest%% *}"
wheel_size=$(stat -c '%s' "$wheel_payload")
path_hash=$(printf '%060d' 0)
wheel_name="grpcio-${NEXUS_GRPCIO_PIP_VERSION}-cp310-cp310-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"
wheel_url="https://${NEXUS_PYPI_FILES_HOST}/packages/aa/bb/${path_hash}/${wheel_name}"

write_grpc_metadata() {
    local output_file="$1"
    local filename="$2"
    local url="$3"
    local digest="$4"
    local size="$5"
    local python_version="$6"
    jq -n \
        --arg package grpcio \
        --arg version "$NEXUS_GRPCIO_PIP_VERSION" \
        --arg filename "$filename" \
        --arg url "$url" \
        --arg digest "$digest" \
        --arg python_version "$python_version" \
        --argjson size "$size" \
        '{
            info: {name: $package, version: $version},
            urls: [{
                filename: $filename,
                url: $url,
                digests: {sha256: $digest},
                size: $size,
                python_version: $python_version,
                packagetype: "bdist_wheel",
                yanked: false
            }]
        }' > "$output_file"
}

normal_metadata="$test_root/normal.json"
write_grpc_metadata \
    "$normal_metadata" "$wheel_name" "$wheel_url" "$wheel_digest" "$wheel_size" cp310

echo "[1/7] exact release, ABI, architecture and trusted host resolution"
resolved=$(nexus_resolve_pypi_wheel \
    "$normal_metadata" grpcio "$NEXUS_GRPCIO_PIP_VERSION" cp310 x86_64)
mapfile -t resolved_fields <<< "$resolved"
[ "${#resolved_fields[@]}" -eq 4 ]
[ "${resolved_fields[0]}" = "$wheel_name" ]
[ "${resolved_fields[1]}" = "$wheel_url" ]
[ "${resolved_fields[2]}" = "$wheel_digest" ]
[ "${resolved_fields[3]}" = "$wheel_size" ]
fetch_log="$test_root/fetch.log"
(
    curl() { printf '%s\n' "$@" > "$fetch_log"; }
    nexus_pypi_fetch https://pypi.org/pypi/grpcio/test/json \
        "$test_root/fetched-metadata" 5242880
)
grep -Fxq -- '--proto' "$fetch_log"
grep -Fxq -- '=https' "$fetch_log"
grep -Fxq -- '--max-filesize' "$fetch_log"
grep -Fxq -- '5242880' "$fetch_log"

echo "[2/7] forged metadata and duplicate members are rejected"
forged_metadata="$test_root/forged.json"
jq '.urls[0].url = "https://attacker.example/packages/aa/bb/000000000000000000000000000000000000000000000000000000000000/grpcio.whl"' \
    "$normal_metadata" > "$forged_metadata"
if nexus_resolve_pypi_wheel \
    "$forged_metadata" grpcio "$NEXUS_GRPCIO_PIP_VERSION" cp310 x86_64 2>/dev/null; then
    echo "forged PyPI file host was accepted" >&2
    exit 1
fi
jq '.urls += [.urls[0]]' "$normal_metadata" > "$forged_metadata"
if nexus_resolve_pypi_wheel \
    "$forged_metadata" grpcio "$NEXUS_GRPCIO_PIP_VERSION" cp310 x86_64 2>/dev/null; then
    echo "duplicate PyPI release member was accepted" >&2
    exit 1
fi
jq '.info.version = "1.82.0"' "$normal_metadata" > "$forged_metadata"
if nexus_resolve_pypi_wheel \
    "$forged_metadata" grpcio "$NEXUS_GRPCIO_PIP_VERSION" cp310 x86_64 2>/dev/null; then
    echo "forged PyPI release version was accepted" >&2
    exit 1
fi

echo "[3/7] wrong and unsupported wheel architectures are rejected"
if nexus_resolve_pypi_wheel \
    "$normal_metadata" grpcio "$NEXUS_GRPCIO_PIP_VERSION" cp310 aarch64 2>/dev/null; then
    echo "x86_64 wheel was selected for aarch64" >&2
    exit 1
fi
if nexus_resolve_pypi_wheel \
    "$normal_metadata" grpcio "$NEXUS_GRPCIO_PIP_VERSION" cp310 armv7l 2>/dev/null; then
    echo "unsupported architecture was accepted" >&2
    exit 1
fi

echo "[4/7] pip is isolated from indexes, caches, configs and dependency solving"
pip_log="$test_root/pip.log"
nexus_python_pip() {
    if [ "${1:-}" = --isolated ] && [ "${2:-}" = install ] && [ "${3:-}" = --help ]; then
        printf '%s\n' '  --break-system-packages'
        return 0
    fi
    {
        printf 'PIP_CONFIG_FILE=%s\n' "${PIP_CONFIG_FILE:-}"
        printf 'PIP_INDEX_URL=%s\n' "${PIP_INDEX_URL-unset}"
        printf 'ARG=%s\n' "$@"
    } > "$pip_log"
}
PIP_INDEX_URL="https://attacker.example/simple" \
    nexus_pip_install_local_wheel_production "$wheel_payload"
grep -Fxq 'PIP_CONFIG_FILE=/dev/null' "$pip_log"
grep -Fxq 'PIP_INDEX_URL=unset' "$pip_log"
grep -Fxq 'ARG=--isolated' "$pip_log"
grep -Fxq 'ARG=--no-index' "$pip_log"
grep -Fxq 'ARG=--no-deps' "$pip_log"
grep -Fxq 'ARG=--no-cache-dir' "$pip_log"
grep -Fxq 'ARG=--only-binary=:all:' "$pip_log"
grep -Fxq 'ARG=--break-system-packages' "$pip_log"

echo "[5/7] a forged download digest fails before pip"
bad_digest=$(printf '%064d' 0)
bad_digest_metadata="$test_root/bad-digest.json"
write_grpc_metadata \
    "$bad_digest_metadata" "$wheel_name" "$wheel_url" "$bad_digest" "$wheel_size" cp310
active_metadata="$bad_digest_metadata"
nexus_current_python_abi() { printf '%s\n' cp310; }
nexus_current_wheel_arch() { printf '%s\n' x86_64; }
nexus_pypi_fetch() {
    local url="$1"
    local output_file="$2"
    case "$url" in
        "${NEXUS_PYPI_API_ROOT}/grpcio/${NEXUS_GRPCIO_PIP_VERSION}/json")
            cp "$active_metadata" "$output_file"
            ;;
        "$wheel_url") cp "$wheel_payload" "$output_file" ;;
        *)
            echo "unexpected fixture URL: $url" >&2
            return 1
            ;;
    esac
}
pip_install_log="$test_root/pip-installs.log"
nexus_pip_install_local_wheel() {
    printf '%s\n' "$1" >> "$pip_install_log"
}
if nexus_install_verified_pypi_wheel grpcio "$NEXUS_GRPCIO_PIP_VERSION" 2>/dev/null; then
    echo "wheel with a forged digest was installed" >&2
    exit 1
fi
[ ! -e "$pip_install_log" ]

echo "[6/7] verified fallback is exact, post-checked and never downgraded"
active_metadata="$normal_metadata"
grpc_state="$test_root/grpc-version"
pip_mode=exact
nexus_grpc_installed_version() {
    [ -s "$grpc_state" ] || return 1
    command cat "$grpc_state"
}
nexus_typing_extensions_installed_version() {
    printf '%s\n' "$NEXUS_TYPING_EXTENSIONS_PIP_VERSION"
}
nexus_pip_install_local_wheel() {
    printf '%s\n' "$1" >> "$pip_install_log"
    case "$pip_mode" in
        exact) printf '%s\n' "$NEXUS_GRPCIO_PIP_VERSION" > "$grpc_state" ;;
        wrong) printf '%s\n' 1.82.0 > "$grpc_state" ;;
        *) return 1 ;;
    esac
}
nexus_install_grpcio_pip_fallback_production
[ "$(<"$grpc_state")" = "$NEXUS_GRPCIO_PIP_VERSION" ]

pip_mode=wrong
: > "$grpc_state"
if nexus_install_grpcio_pip_fallback_production 2>/dev/null; then
    echo "wrong post-install grpcio version was accepted" >&2
    exit 1
fi
[ "$(<"$grpc_state")" = 1.82.0 ]

install_count=$(wc -l < "$pip_install_log")
printf '%s\n' 1.84.0 > "$grpc_state"
nexus_install_grpcio_pip_fallback_production >/dev/null 2>&1
[ "$(<"$grpc_state")" = 1.84.0 ]
[ "$(wc -l < "$pip_install_log")" -eq "$install_count" ]

echo "[7/7] apt remains preferred and Ubuntu 22-style old apt falls back"
apt_log="$test_root/apt.log"
fallback_log="$test_root/fallback.log"
apt-get() {
    printf '%s\n' "$*" >> "$apt_log"
}
nexus_install_grpcio_pip_fallback() {
    printf '%s\n' fallback >> "$fallback_log"
}
printf '%s\n' 1.60.0 > "$grpc_state"
nexus_install_dependencies
grep -Fq 'python3-typing-extensions' "$apt_log"
grep -Fq 'install -y python3-grpcio' "$apt_log"
[ ! -e "$fallback_log" ]

printf '%s\n' 1.41.3 > "$grpc_state"
nexus_install_dependencies
[ "$(wc -l < "$fallback_log")" -eq 1 ]

echo "grpcio supply-chain regression tests passed."
