# shellcheck shell=bash
# Trusted, short-lived ACME certificates for Nexus public-IP subscriptions.
#
# This module is loaded after 85-nexus.sh so certificate publication reuses
# its durable pair-pending marker and Nginx ExecCondition.  ACME state is the
# authoritative generation: a renewal commits the store before publishing the
# live certificate/key pair, and crash recovery always rolls forward.

NEXUS_IP_ACME_VERSION=1
NEXUS_IP_ACME_OWNER_VALUE="rr-nexus-ip-acme-v1"
NEXUS_IP_ACME_STORE_VALUE="rr-nexus-ip-acme-store-v1"
NEXUS_IP_ACME_WEBROOT_VALUE="rr-nexus-ip-acme-webroot-v1"

NEXUS_IP_ACME_STATE_ROOT="${NEXUS_IP_ACME_STATE_ROOT:-/var/lib/rr-nexus/ip-acme}"
NEXUS_IP_ACME_ACTIVE_STORE="${NEXUS_IP_ACME_ACTIVE_STORE:-${NEXUS_IP_ACME_STATE_ROOT}/active}"
NEXUS_IP_ACME_CANDIDATE_STORE="${NEXUS_IP_ACME_CANDIDATE_STORE:-${NEXUS_IP_ACME_STATE_ROOT}/candidate}"
NEXUS_IP_ACME_CONFIG="${NEXUS_IP_ACME_CONFIG:-${NEXUS_IP_ACME_STATE_ROOT}/config.json}"
NEXUS_IP_ACME_JOURNAL="${NEXUS_IP_ACME_JOURNAL:-${NEXUS_IP_ACME_STATE_ROOT}/publication.json}"
NEXUS_IP_ACME_OWNER_MARKER="${NEXUS_IP_ACME_OWNER_MARKER:-${NEXUS_IP_ACME_STATE_ROOT}/.rr-nexus-ip-acme-owner}"
NEXUS_IP_ACME_WEBROOT="${NEXUS_IP_ACME_WEBROOT:-/var/www/rr-nexus-ip-acme}"
NEXUS_IP_ACME_WEBROOT_MARKER="${NEXUS_IP_ACME_WEBROOT_MARKER:-${NEXUS_IP_ACME_WEBROOT}/.rr-nexus-ip-acme-owner}"
NEXUS_IP_ACME_CERT_NAME="${NEXUS_IP_ACME_CERT_NAME:-rr-nexus-ip}"
NEXUS_IP_ACME_LIVE_CERT="${NEXUS_IP_ACME_LIVE_CERT:-/etc/rr-nexus/certs/ip.crt}"
NEXUS_IP_ACME_LIVE_KEY="${NEXUS_IP_ACME_LIVE_KEY:-/etc/rr-nexus/certs/ip.key}"
NEXUS_IP_ACME_PENDING="${NEXUS_IP_ACME_PENDING:-/etc/rr-nexus/certs/.ip-cert-pending}"
NEXUS_IP_ACME_SERVICE_FILE="${NEXUS_IP_ACME_SERVICE_FILE:-/etc/systemd/system/rr-nexus-ip-acme.service}"
NEXUS_IP_ACME_TIMER_FILE="${NEXUS_IP_ACME_TIMER_FILE:-/etc/systemd/system/rr-nexus-ip-acme.timer}"
NEXUS_IP_ACME_RR_BIN="${NEXUS_IP_ACME_RR_BIN:-/usr/local/bin/rr}"
NEXUS_IP_ACME_NGINX_AVAILABLE="${NEXUS_IP_ACME_NGINX_AVAILABLE:-/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf}"
NEXUS_IP_ACME_NGINX_ENABLED="${NEXUS_IP_ACME_NGINX_ENABLED:-/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf}"
NEXUS_IP_ACME_RECOVERED_PUBLICATION=0

# Immutable lego v5.4.0 release assets.  Runtime trust never depends on the
# release checksum file or a mutable "latest" response.
NEXUS_IP_ACME_LEGO_VERSION="5.4.0"
NEXUS_IP_ACME_LEGO_RELEASE_BASE="https://github.com/go-acme/lego/releases/download/v${NEXUS_IP_ACME_LEGO_VERSION}"
NEXUS_IP_ACME_LEGO_AMD64_SIZE="21026575"
NEXUS_IP_ACME_LEGO_AMD64_SHA256="d3adf89392d606ce84d485c1cc20832edd42ace6ff9ced9dd3670d9d8b8aca38"
NEXUS_IP_ACME_LEGO_AMD64_BINARY_SIZE="68141216"
NEXUS_IP_ACME_LEGO_AMD64_BINARY_SHA256="12e84dfa5e32222032b131cbc402ad2125800eb1f90f3b4e311bf44f69d05f4d"
NEXUS_IP_ACME_LEGO_ARM64_SIZE="18969885"
NEXUS_IP_ACME_LEGO_ARM64_SHA256="a86e946e0415e14e28d6dfe3c95914b088b3f5f6e13209e07e2e8c3a64d7280b"
NEXUS_IP_ACME_LEGO_ARM64_BINARY_SIZE="62062752"
NEXUS_IP_ACME_LEGO_ARM64_BINARY_SHA256="947ca4a59f2018edb98697b1de1dd6e1e10a8c66e522f7e62fe2b0875f35d69b"
NEXUS_IP_ACME_LEGO_BIN="${NEXUS_IP_ACME_LEGO_BIN:-/usr/local/lib/rr-vps/lego}"
NEXUS_IP_ACME_LEGO_MARKER="${NEXUS_IP_ACME_LEGO_MARKER:-/usr/local/lib/rr-vps/lego.install}"

nexus_ip_acme_is_global_address() {
    local address="${1:-}"
    python3 - "$address" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
allowed = (
    address.is_global
    and not address.is_multicast
    and getattr(address, "ipv4_mapped", None) is None
    and getattr(address, "scope_id", None) is None
)
raise SystemExit(0 if allowed and address.version in (4, 6) else 1)
PY
}

nexus_ip_acme_normalize_address() {
    local input="${1:-}" output_name="${2:-}" canonical_value=""
    [ -z "$output_name" ] || [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    canonical_value=$(python3 - "$input" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if (
    not address.is_global
    or address.is_multicast
    or getattr(address, "ipv4_mapped", None) is not None
    or getattr(address, "scope_id", None) is not None
):
    raise SystemExit(1)
print(str(address))
PY
    ) || return 1
    if [ -n "$output_name" ]; then
        printf -v "$output_name" '%s' "$canonical_value"
    else
        printf '%s\n' "$canonical_value"
    fi
}

nexus_ip_acme_url_host() {
    local address="${1:-}" normalized=""
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    address="$normalized"
    if [[ "$address" == *:* ]]; then
        printf '[%s]\n' "$address"
    else
        printf '%s\n' "$address"
    fi
}

nexus_ip_acme_public_url() {
    local address="${1:-}" port="${2:-}" path="${3:-/}"
    local host=""
    host=$(nexus_ip_acme_url_host "$address") || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    [[ "$path" == /* ]] && [[ "$path" != *$'\n'* ]] && [[ "$path" != *$'\r'* ]] || return 1
    if [ "$port" = 443 ]; then
        printf 'https://%s%s\n' "$host" "$path"
    else
        printf 'https://%s:%s%s\n' "$host" "$port" "$path"
    fi
}

nexus_ip_acme_email_is_valid() {
    local email="${1:-}"
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && \
        [ "${#email}" -le 254 ] && [[ "$email" != *$'\n'* ]] && [[ "$email" != *$'\r'* ]]
}

nexus_ip_acme_exact_marker() {
    local marker="${1:-}" expected="${2:-}" metadata=""
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null) || return 1
    [ "$metadata" = 0:0:600:1 ] && [ "$(cat -- "$marker" 2>/dev/null)" = "$expected" ]
}

nexus_ip_acme_parent_directory_is_safe() {
    local target="${1:-}" parent="" logical="" resolved="" metadata=""
    local owner="" group="" mode="" current="" next=""
    [ -n "$target" ] && [[ "$target" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    parent=$(dirname -- "$target") || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    logical=$(realpath -ms -- "$parent" 2>/dev/null) || return 1
    resolved=$(readlink -e -- "$parent" 2>/dev/null) || return 1
    [ "$parent" = "$logical" ] && [ "$logical" = "$resolved" ] || return 1
    current="$parent"
    while :; do
        [ -d "$current" ] && [ ! -L "$current" ] || return 1
        metadata=$(stat -c '%u:%g:%a' -- "$current" 2>/dev/null) || return 1
        IFS=: read -r owner group mode <<<"$metadata"
        [ "$owner:$group" = 0:0 ] && [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        # Every ancestor is part of the authority boundary.  A writable higher
        # component could exchange the already-validated immediate parent.
        (( (8#$mode & 8#022) == 0 )) || return 1
        [ "$current" != / ] || break
        next=$(dirname -- "$current") || return 1
        [ "$next" != "$current" ] || return 1
        current="$next"
    done
}

nexus_ip_acme_nearest_parent_chain_is_safe() {
    local target="${1:-}" current=""
    [[ "$target" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    current=$(dirname -- "$target") || return 1
    while [ ! -e "$current" ] && [ ! -L "$current" ]; do
        [ "$current" != / ] || return 1
        current=$(dirname -- "$current") || return 1
    done
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
    nexus_ip_acme_parent_directory_is_safe "$current/.rr-ip-acme-parent-proof"
}

nexus_ip_acme_cleanup_atomic_files() {
    local directory="${1:-}" kind="${2:-atomic}" action="${3:-remove}"
    case "$action" in remove|validate-only) ;; *) return 1 ;; esac
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    nexus_ip_acme_parent_directory_is_safe "$directory/.rr-ip-acme-placeholder" || return 1
    python3 - "$directory" "$kind" "$action" <<'PY' >/dev/null 2>&1
import os
import re
import stat
import sys

directory, kind, action = sys.argv[1:]
patterns = {
    "atomic": r"\.rr-ip-acme\.[A-Za-z0-9]{6}",
    "http": r"\.rr-ip-acme-http\.[A-Za-z0-9]{6}",
    "live": r"(?:\.ip-acme\.(?:crt|key)|\.ip-cert-pending)\.[A-Za-z0-9]{6}",
    "unit": r"\.rr-ip-acme-unit\.[A-Za-z0-9]{6}",
}
pattern = patterns.get(kind)
if pattern is None:
    raise SystemExit(1)
root = os.path.abspath(directory)
if os.path.realpath(root) != root:
    raise SystemExit(1)
root_info = os.lstat(root)
if (
    not stat.S_ISDIR(root_info.st_mode)
    or root_info.st_uid != 0
    or root_info.st_gid != 0
    or stat.S_IMODE(root_info.st_mode) & 0o022
):
    raise SystemExit(1)
candidates = []
with os.scandir(root) as entries:
    for entry in entries:
        if not re.fullmatch(pattern, entry.name):
            continue
        info = entry.stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != 0
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) not in (0o600, 0o644)
            or info.st_dev != root_info.st_dev
        ):
            raise SystemExit(1)
        candidates.append(entry.path)
if action == "validate-only":
    raise SystemExit(0)
changed = False
for path in candidates:
    os.unlink(path)
    changed = True
if changed:
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

nexus_ip_acme_write_atomic_file() {
    local target="${1:-}" mode="${2:-}" directory="" temporary=""
    [ -n "$target" ] && [[ "$mode" =~ ^(600|644)$ ]] || return 1
    directory=$(dirname -- "$target") || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    nexus_ip_acme_cleanup_atomic_files "$directory" atomic || return 1
    temporary=$(mktemp "$directory/.rr-ip-acme.XXXXXX") || return 1
    if ! chmod "$mode" "$temporary" || ! cat > "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$target" || \
       ! sync -f "$directory"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || unlink "$temporary" 2>/dev/null || true
        return 1
    fi
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = "0:0:${mode}:1" ]
}

nexus_ip_acme_directory_is_safe() {
    local directory="${1:-}" mode="${2:-700}" canonical=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
    [ "$canonical" = "$directory" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = "0:0:${mode}" ]
}

nexus_ip_acme_path_is_mountpoint() {
    local path="${1:-}"
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q -- "$path"
        return $?
    fi
    python3 - "$path" <<'PY' >/dev/null 2>&1
import os
import sys
raise SystemExit(0 if os.path.ismount(sys.argv[1]) else 1)
PY
}

nexus_ip_acme_creation_stage_is_safe() {
    local stage="${1:-}" kind="${2:-}"
    case "$kind" in state|webroot) ;; *) return 1 ;; esac
    [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
    nexus_ip_acme_path_is_mountpoint "$stage" && return 1
    python3 - "$stage" "$kind" "$NEXUS_IP_ACME_OWNER_VALUE" \
        "$NEXUS_IP_ACME_WEBROOT_VALUE" <<'PY' >/dev/null 2>&1
import os
import re
import stat
import sys

root, kind, state_value, webroot_value = sys.argv[1:]
root = os.path.abspath(root)
if os.path.realpath(root) != root:
    raise SystemExit(1)
root_info = os.lstat(root)
if (
    not stat.S_ISDIR(root_info.st_mode)
    or root_info.st_uid != 0
    or root_info.st_gid != 0
    or stat.S_IMODE(root_info.st_mode) not in (0o700, 0o755)
):
    raise SystemExit(1)
allowed_dirs = {root}
marker_name = ".rr-nexus-ip-acme-owner"
expected_marker = state_value
if kind == "webroot":
    allowed_dirs.update(
        {
            os.path.join(root, ".well-known"),
            os.path.join(root, ".well-known", "acme-challenge"),
        }
    )
    expected_marker = webroot_value
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    info = os.lstat(current)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or info.st_dev != root_info.st_dev
        or os.path.abspath(current) not in allowed_dirs
    ):
        raise SystemExit(1)
    for name in dirs:
        path = os.path.join(current, name)
        child = os.lstat(path)
        if (
            stat.S_ISLNK(child.st_mode)
            or child.st_dev != root_info.st_dev
            or os.path.abspath(path) not in allowed_dirs
        ):
            raise SystemExit(1)
    for name in files:
        path = os.path.join(current, name)
        child = os.lstat(path)
        if (
            not stat.S_ISREG(child.st_mode)
            or child.st_uid != 0
            or child.st_gid != 0
            or child.st_nlink != 1
            or child.st_dev != root_info.st_dev
        ):
            raise SystemExit(1)
        mode = stat.S_IMODE(child.st_mode)
        if current == root and name == marker_name:
            if mode != 0o600 or open(path, "rb").read() != (expected_marker + "\n").encode():
                raise SystemExit(1)
        elif current == root and re.fullmatch(r"\.rr-ip-acme\.[A-Za-z0-9]{6}", name):
            if mode != 0o600:
                raise SystemExit(1)
        else:
            raise SystemExit(1)
PY
}

nexus_ip_acme_remove_creation_stage() {
    local stage="${1:-}" kind="${2:-}" parent=""
    [ -e "$stage" ] || [ -L "$stage" ] || return 0
    nexus_ip_acme_parent_directory_is_safe "$stage" || return 1
    nexus_ip_acme_creation_stage_is_safe "$stage" "$kind" || return 1
    parent=$(dirname -- "$stage") || return 1
    nexus_ip_acme_parent_directory_is_safe "$stage" || return 1
    nexus_ip_acme_creation_stage_is_safe "$stage" "$kind" || return 1
    rm -rf -- "$stage" || return 1
    sync -f "$parent" || return 1
    [ ! -e "$stage" ] && [ ! -L "$stage" ]
}

nexus_ip_acme_lego_asset_fields() {
    local architecture="${1:-}" output_size="${2:-}" output_sha="${3:-}"
    local size="" digest=""
    [[ "$output_size" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$output_sha" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    case "$architecture" in
        amd64|x86_64)
            size="$NEXUS_IP_ACME_LEGO_AMD64_SIZE"
            digest="$NEXUS_IP_ACME_LEGO_AMD64_SHA256"
            ;;
        arm64|aarch64)
            size="$NEXUS_IP_ACME_LEGO_ARM64_SIZE"
            digest="$NEXUS_IP_ACME_LEGO_ARM64_SHA256"
            ;;
        *) return 1 ;;
    esac
    [[ "$size" =~ ^[1-9][0-9]+$ ]] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf -v "$output_size" '%s' "$size"
    printf -v "$output_sha" '%s' "$digest"
}

nexus_ip_acme_lego_binary_fields() {
    local architecture="${1:-}" output_size="${2:-}" output_sha="${3:-}"
    local size="" digest=""
    [[ "$output_size" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$output_sha" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    case "$architecture" in
        amd64|x86_64)
            size="$NEXUS_IP_ACME_LEGO_AMD64_BINARY_SIZE"
            digest="$NEXUS_IP_ACME_LEGO_AMD64_BINARY_SHA256"
            ;;
        arm64|aarch64)
            size="$NEXUS_IP_ACME_LEGO_ARM64_BINARY_SIZE"
            digest="$NEXUS_IP_ACME_LEGO_ARM64_BINARY_SHA256"
            ;;
        *) return 1 ;;
    esac
    [[ "$size" =~ ^[1-9][0-9]+$ ]] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf -v "$output_size" '%s' "$size"
    printf -v "$output_sha" '%s' "$digest"
}

nexus_ip_acme_lego_current_architecture() {
    local output_name="${1:-}" machine="" architecture_value=""
    [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    machine=$(uname -m) || return 1
    case "$machine" in
        x86_64) architecture_value=amd64 ;;
        aarch64|arm64) architecture_value=arm64 ;;
        *) return 1 ;;
    esac
    printf -v "$output_name" '%s' "$architecture_value"
}

nexus_ip_acme_lego_binary_is_official() {
    local binary="${1:-$NEXUS_IP_ACME_LEGO_BIN}" architecture="${2:-}"
    local expected_size="" expected_sha="" actual_size="" actual_sha=""
    [ -n "$architecture" ] || nexus_ip_acme_lego_current_architecture architecture || return 1
    nexus_ip_acme_lego_binary_fields "$architecture" expected_size expected_sha || return 1
    [ -x "$binary" ] && [ -f "$binary" ] && [ ! -L "$binary" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$binary" 2>/dev/null)" = 0:0:755:1 ] || return 1
    actual_size=$(stat -c %s -- "$binary" 2>/dev/null) || return 1
    actual_sha=$(sha256sum "$binary" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual_size" = "$expected_size" ] && [ "$actual_sha" = "$expected_sha" ] || return 1
    "$binary" --version 2>/dev/null | \
        grep -Eq "(^|[^0-9])${NEXUS_IP_ACME_LEGO_VERSION}([^0-9]|$)"
}

nexus_ip_acme_lego_marker_record_is_current() {
    local marker="${1:-$NEXUS_IP_ACME_LEGO_MARKER}" expected_architecture="${2:-}"
    local architecture="" expected_archive_size="" expected_archive_sha=""
    local expected_binary_size="" expected_binary_sha=""
    local -a lines=()
    [ -n "$expected_architecture" ] || \
        nexus_ip_acme_lego_current_architecture expected_architecture || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] || return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 5 ] || return 1
    [ "${lines[0]}" = rr-nexus-ip-acme-lego-v1 ] && \
        [ "${lines[1]}" = "version=${NEXUS_IP_ACME_LEGO_VERSION}" ] || return 1
    architecture="${lines[2]#architecture=}"
    [ "${lines[2]}" = "architecture=${architecture}" ] && \
        [ "$architecture" = "$expected_architecture" ] || return 1
    nexus_ip_acme_lego_asset_fields "$architecture" \
        expected_archive_size expected_archive_sha || return 1
    nexus_ip_acme_lego_binary_fields "$architecture" \
        expected_binary_size expected_binary_sha || return 1
    [ "${lines[3]}" = "archive_sha256=${expected_archive_sha}" ] && \
        [ "${lines[4]}" = "binary_sha256=${expected_binary_sha}" ]
}

nexus_ip_acme_write_lego_marker() {
    local architecture="${1:-}" archive_size="" archive_sha=""
    local binary_size="" binary_sha=""
    nexus_ip_acme_lego_asset_fields "$architecture" archive_size archive_sha || return 1
    nexus_ip_acme_lego_binary_fields "$architecture" binary_size binary_sha || return 1
    printf 'rr-nexus-ip-acme-lego-v1\nversion=%s\narchitecture=%s\narchive_sha256=%s\nbinary_sha256=%s\n' \
        "$NEXUS_IP_ACME_LEGO_VERSION" "$architecture" "$archive_sha" "$binary_sha" | \
        nexus_ip_acme_write_atomic_file "$NEXUS_IP_ACME_LEGO_MARKER" 600
}

nexus_ip_acme_lego_marker_is_current() {
    local marker="$NEXUS_IP_ACME_LEGO_MARKER" binary="$NEXUS_IP_ACME_LEGO_BIN"
    local architecture=""
    nexus_ip_acme_lego_current_architecture architecture || return 1
    nexus_ip_acme_lego_marker_record_is_current "$marker" "$architecture" && \
        nexus_ip_acme_lego_binary_is_official "$binary" "$architecture"
}

nexus_ip_acme_install_lego() {
    local machine="" architecture="" expected_size="" expected_sha="" archive=""
    local stage="" extracted="" candidate_binary="" actual_size="" actual_sha=""
    local expected_binary_size="" expected_binary_sha="" binary_dir="" marker_dir=""
    if nexus_ip_acme_lego_marker_is_current; then
        return 0
    fi
    nexus_ip_acme_lego_current_architecture architecture || return 1
    binary_dir=$(dirname -- "$NEXUS_IP_ACME_LEGO_BIN") || return 1
    marker_dir=$(dirname -- "$NEXUS_IP_ACME_LEGO_MARKER") || return 1
    [ "$binary_dir" = "$marker_dir" ] || return 1
    if [ ! -e "$binary_dir" ] && [ ! -L "$binary_dir" ]; then
        nexus_ip_acme_parent_directory_is_safe "$binary_dir" || return 1
        mkdir -m 755 -- "$binary_dir" || return 1
    fi
    nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_LEGO_BIN" || return 1
    nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_LEGO_MARKER" || return 1
    nexus_ip_acme_directory_is_safe "$binary_dir" 755 || return 1
    nexus_ip_acme_cleanup_atomic_files "$binary_dir" atomic || return 1
    # Either half of a power-loss-interrupted publication is recoverable only
    # when it independently matches the immutable release pins.
    if [ -e "$NEXUS_IP_ACME_LEGO_BIN" ] || [ -L "$NEXUS_IP_ACME_LEGO_BIN" ]; then
        nexus_ip_acme_lego_binary_is_official \
            "$NEXUS_IP_ACME_LEGO_BIN" "$architecture" || return 1
    fi
    if [ -e "$NEXUS_IP_ACME_LEGO_MARKER" ] || [ -L "$NEXUS_IP_ACME_LEGO_MARKER" ]; then
        nexus_ip_acme_lego_marker_record_is_current \
            "$NEXUS_IP_ACME_LEGO_MARKER" "$architecture" || return 1
    else
        nexus_ip_acme_write_lego_marker "$architecture" || return 1
    fi
    if [ -e "$NEXUS_IP_ACME_LEGO_BIN" ] || [ -L "$NEXUS_IP_ACME_LEGO_BIN" ]; then
        nexus_ip_acme_lego_marker_is_current
        return $?
    fi
    nexus_ip_acme_lego_asset_fields "$architecture" expected_size expected_sha || return 1
    nexus_ip_acme_lego_binary_fields "$architecture" \
        expected_binary_size expected_binary_sha || return 1
    stage=$(mktemp -d "${TMPDIR:-/tmp}/rr-lego.XXXXXX") || return 1
    archive="$stage/lego.tar.gz"
    extracted="$stage/extracted"
    mkdir -m 700 "$extracted" || { rmdir "$stage" 2>/dev/null || true; return 1; }
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 180 \
        -o "$archive" \
        "${NEXUS_IP_ACME_LEGO_RELEASE_BASE}/lego_v${NEXUS_IP_ACME_LEGO_VERSION}_linux_${architecture}.tar.gz"; then
        rm -rf -- "$stage"
        return 1
    fi
    actual_size=$(stat -c %s -- "$archive" 2>/dev/null) || { rm -rf -- "$stage"; return 1; }
    actual_sha=$(sha256sum "$archive" 2>/dev/null | awk '{print $1}') || { rm -rf -- "$stage"; return 1; }
    [ "$actual_size" = "$expected_size" ] && [ "$actual_sha" = "$expected_sha" ] || {
        rm -rf -- "$stage"
        return 1
    }
    python3 - "$archive" <<'PY' >/dev/null 2>&1 || { rm -rf -- "$stage"; return 1; }
import pathlib
import sys
import tarfile
archive = sys.argv[1]
with tarfile.open(archive, "r:gz") as bundle:
    members = bundle.getmembers()
    if not members or len(members) > 32:
        raise SystemExit(1)
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):
            raise SystemExit(1)
        if member.size < 0 or member.size > 100 * 1024 * 1024:
            raise SystemExit(1)
PY
    if ! tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$extracted"; then
        rm -rf -- "$stage"
        return 1
    fi
    candidate_binary=$(find "$extracted" -type f -name lego -print -quit 2>/dev/null) || {
        rm -rf -- "$stage"
        return 1
    }
    [ -n "$candidate_binary" ] && [ -f "$candidate_binary" ] && [ ! -L "$candidate_binary" ] || {
        rm -rf -- "$stage"
        return 1
    }
    chmod 755 "$candidate_binary" || { rm -rf -- "$stage"; return 1; }
    actual_size=$(stat -c %s -- "$candidate_binary" 2>/dev/null) || {
        rm -rf -- "$stage"
        return 1
    }
    actual_sha=$(sha256sum "$candidate_binary" | awk '{print $1}') || {
        rm -rf -- "$stage"
        return 1
    }
    [ "$actual_size" = "$expected_binary_size" ] && \
        [ "$actual_sha" = "$expected_binary_sha" ] && \
        "$candidate_binary" --version 2>/dev/null | \
            grep -Eq "(^|[^0-9])${NEXUS_IP_ACME_LEGO_VERSION}([^0-9]|$)" || {
        rm -rf -- "$stage"
        return 1
    }
    sync -f "$candidate_binary" || { rm -rf -- "$stage"; return 1; }
    if ! mv -- "$candidate_binary" "$NEXUS_IP_ACME_LEGO_BIN" || \
       ! sync -f "$binary_dir"; then
        rm -rf -- "$stage"
        return 1
    fi
    rm -rf -- "$stage"
    nexus_ip_acme_lego_marker_is_current
}

nexus_ip_acme_prepare_state_root() {
    local root="$NEXUS_IP_ACME_STATE_ROOT" marker="$NEXUS_IP_ACME_OWNER_MARKER"
    local parent="" stage="${NEXUS_IP_ACME_STATE_ROOT}.new"
    parent=$(dirname -- "$root") || return 1
    nexus_ip_acme_parent_directory_is_safe "$root" || return 1
    nexus_ip_acme_remove_creation_stage "$stage" state || return 1
    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
        mkdir -m 700 -- "$stage" || return 1
        if ! printf '%s\n' "$NEXUS_IP_ACME_OWNER_VALUE" | \
             nexus_ip_acme_write_atomic_file "$stage/.rr-nexus-ip-acme-owner" 600 || \
           ! nexus_ip_acme_fsync_store_tree "$stage" || \
           ! mv -T -- "$stage" "$root" || ! sync -f "$parent"; then
            nexus_ip_acme_remove_creation_stage "$stage" state >/dev/null 2>&1 || true
            return 1
        fi
    fi
    nexus_ip_acme_directory_is_safe "$root" 700 || return 1
    nexus_ip_acme_path_is_mountpoint "$root" && return 1
    nexus_ip_acme_cleanup_atomic_files "$root" atomic || return 1
    nexus_ip_acme_exact_marker "$marker" "$NEXUS_IP_ACME_OWNER_VALUE" || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ]
}

nexus_ip_acme_webroot_is_safe() {
    local root="$NEXUS_IP_ACME_WEBROOT" marker="$NEXUS_IP_ACME_WEBROOT_MARKER"
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    [ "$(readlink -f -- "$root" 2>/dev/null)" = "$root" ] || return 1
    nexus_ip_acme_path_is_mountpoint "$root" && return 1
    [ "$(stat -c '%u:%g:%a' -- "$root" 2>/dev/null)" = 0:0:755 ] || return 1
    nexus_ip_acme_exact_marker "$marker" "$NEXUS_IP_ACME_WEBROOT_VALUE" || return 1
    python3 - "$root" "$marker" <<'PY' >/dev/null 2>&1
import os
import re
import stat
import sys

root, marker = map(os.path.abspath, sys.argv[1:])
if os.path.realpath(root) != root:
    raise SystemExit(1)
root_info = os.lstat(root)
allowed_dirs = {
    root,
    os.path.join(root, ".well-known"),
    os.path.join(root, ".well-known", "acme-challenge"),
}
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    info = os.lstat(current)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != 0 or info.st_dev != root_info.st_dev:
        raise SystemExit(1)
    if os.path.abspath(current) not in allowed_dirs or stat.S_IMODE(info.st_mode) != 0o755:
        raise SystemExit(1)
    for name in dirs:
        path = os.path.join(current, name)
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or info.st_dev != root_info.st_dev or os.path.abspath(path) not in allowed_dirs:
            raise SystemExit(1)
    for name in files:
        path = os.path.join(current, name)
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0 or info.st_nlink != 1 or info.st_dev != root_info.st_dev:
            raise SystemExit(1)
        mode = stat.S_IMODE(info.st_mode)
        if os.path.abspath(path) == marker:
            if mode != 0o600:
                raise SystemExit(1)
        elif re.fullmatch(r"\.rr-ip-acme\.[A-Za-z0-9]{6}", name):
            if mode != 0o600:
                raise SystemExit(1)
        else:
            # lego challenge tokens are transient, root-owned regular files.
            if current != os.path.join(root, ".well-known", "acme-challenge"):
                raise SystemExit(1)
            if not name or len(name) > 256 or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for ch in name):
                raise SystemExit(1)
            if mode not in (0o600, 0o644):
                raise SystemExit(1)
PY
}

nexus_ip_acme_prepare_webroot() {
    local root="$NEXUS_IP_ACME_WEBROOT" marker="$NEXUS_IP_ACME_WEBROOT_MARKER"
    local parent="" stage="${NEXUS_IP_ACME_WEBROOT}.new"
    parent=$(dirname -- "$root") || return 1
    nexus_ip_acme_parent_directory_is_safe "$root" || return 1
    nexus_ip_acme_remove_creation_stage "$stage" webroot || return 1
    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
        mkdir -m 700 -- "$stage" || return 1
        if ! mkdir -m 755 -- "$stage/.well-known" || \
           ! mkdir -m 755 -- "$stage/.well-known/acme-challenge" || \
           ! chmod 755 "$stage" || \
           ! printf '%s\n' "$NEXUS_IP_ACME_WEBROOT_VALUE" | \
               nexus_ip_acme_write_atomic_file "$stage/.rr-nexus-ip-acme-owner" 600 || \
           ! nexus_ip_acme_fsync_store_tree "$stage" || \
           ! mv -T -- "$stage" "$root" || ! sync -f "$parent"; then
            nexus_ip_acme_remove_creation_stage "$stage" webroot >/dev/null 2>&1 || true
            return 1
        fi
    elif ! nexus_ip_acme_webroot_is_safe; then
        # Existing foreign, linked, mounted or mode-unsafe content is never
        # adopted as RR-owned challenge state.
        return 1
    fi
    nexus_ip_acme_cleanup_atomic_files "$root" atomic || return 1
    nexus_ip_acme_cleanup_atomic_files \
        "$root/.well-known/acme-challenge" atomic || return 1
    chmod 755 "$root" "$root/.well-known" \
        "$root/.well-known/acme-challenge" || return 1
    nexus_ip_acme_webroot_is_safe
}

nexus_ip_acme_emit_nginx_webroot_location() {
    local webroot="$NEXUS_IP_ACME_WEBROOT"
    [[ "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    cat <<EOF
location ^~ /.well-known/acme-challenge/ {
    root ${webroot};
    default_type text/plain;
    try_files \$uri =404;
    access_log off;
    log_not_found off;
}
EOF
}

nexus_ip_acme_emit_nginx_http_site() {
    local address="${1:-}" normalized="" host="" webroot="$NEXUS_IP_ACME_WEBROOT"
    local listen_lines="    listen 80;"
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    host=$(nexus_ip_acme_url_host "$normalized") || return 1
    if [[ "$normalized" == *:* ]]; then
        listen_lines=$'    listen 80;\n    listen [::]:80;'
    fi
    [[ "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    cat <<EOF
# rr-nexus-ip-acme-http-owned-v1 address=${normalized}
server {
${listen_lines}
    server_name ${host};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        default_type text/plain;
        try_files \$uri =404;
        access_log off;
        log_not_found off;
    }

    location / {
        return 444;
    }
}
EOF
}

nexus_ip_acme_nginx_http_site_is_owned() {
    local site="$NEXUS_IP_ACME_NGINX_AVAILABLE"
    [ -f "$site" ] && [ ! -L "$site" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$site" 2>/dev/null)" = 0:0:644:1 ] || return 1
    head -n 1 -- "$site" 2>/dev/null | \
        grep -Eq '^# rr-nexus-ip-acme-http-owned-v1 address=[0-9a-fA-F:.]+$'
}

nexus_ip_acme_nginx_http_site_is_current() {
    local address="${1:-}" expected="" actual="" target=""
    nexus_ip_acme_nginx_http_site_is_owned || return 1
    expected=$(nexus_ip_acme_emit_nginx_http_site "$address" | sha256sum | awk '{print $1}') || return 1
    actual=$(sha256sum "$NEXUS_IP_ACME_NGINX_AVAILABLE" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual" = "$expected" ] || return 1
    [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ] || return 1
    target=$(readlink -- "$NEXUS_IP_ACME_NGINX_ENABLED" 2>/dev/null) || return 1
    [ "$target" = "$NEXUS_IP_ACME_NGINX_AVAILABLE" ]
}

nexus_ip_acme_probe_nginx_http_site() {
    local address="${1:-}" normalized="" host="" token="" challenge="" body=""
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    host=$(nexus_ip_acme_url_host "$normalized") || return 1
    token="rr-ip-acme-probe-$(printf '%s' "${BASHPID:-$$}:$RANDOM" | sha256sum | cut -c1-24)"
    challenge="$NEXUS_IP_ACME_WEBROOT/.well-known/acme-challenge/$token"
    body="rr-ip-acme-proof-$token"
    printf '%s\n' "$body" | nexus_ip_acme_write_atomic_file "$challenge" 644 || return 1
    if [ "${RR_TEST_IP_ACME_SKIP_HTTP_PROBE:-0}" = 1 ]; then
        [ "${RR_TEST_IP_ACME:-0}" = 1 ] || return 1
    else
        local received=""
        received=$(curl --fail --silent --show-error --noproxy '*' --proto '=http' \
            --connect-timeout 2 --max-time 5 -H "Host: ${host}" \
            "http://127.0.0.1/.well-known/acme-challenge/${token}") || {
            unlink "$challenge" 2>/dev/null || true
            return 1
        }
        [ "$received" = "$body" ] || {
            unlink "$challenge" 2>/dev/null || true
            return 1
        }
    fi
    unlink "$challenge" 2>/dev/null || return 1
    sync -f "$(dirname -- "$challenge")" || return 1
    nexus_ip_acme_webroot_is_safe
}

nexus_ip_acme_install_nginx_http_site() {
    local address="${1:-}" normalized="" available_dir="" enabled_dir=""
    local activation_mode="${2:-active}" temporary="" target="" directory=""
    case "$activation_mode" in active|validate-only) ;; *) return 1 ;; esac
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    command -v nginx >/dev/null 2>&1 || return 1
    nexus_ip_acme_prepare_webroot || return 1
    available_dir=$(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE") || return 1
    enabled_dir=$(dirname -- "$NEXUS_IP_ACME_NGINX_ENABLED") || return 1
    for directory in "$available_dir" "$enabled_dir"; do
        if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
            nexus_ip_acme_parent_directory_is_safe "$directory" || return 1
            mkdir -m 755 -- "$directory" || return 1
        fi
    done
    nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_NGINX_AVAILABLE" || return 1
    nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_NGINX_ENABLED" || return 1
    nexus_ip_acme_directory_is_safe "$available_dir" 755 || return 1
    nexus_ip_acme_directory_is_safe "$enabled_dir" 755 || return 1
    nexus_ip_acme_cleanup_atomic_files "$available_dir" http || return 1
    if nexus_ip_acme_nginx_http_site_is_current "$normalized"; then
        nginx -t >/dev/null 2>&1 || return 1
        [ "$activation_mode" = active ] || return 0
        systemctl is-active --quiet nginx >/dev/null 2>&1 || \
            systemctl start nginx >/dev/null 2>&1 || return 1
        nginx -s reload >/dev/null 2>&1 || return 1
        nexus_ip_acme_probe_nginx_http_site "$normalized"
        return $?
    fi
    if [ -e "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || [ -L "$NEXUS_IP_ACME_NGINX_AVAILABLE" ]; then
        nexus_ip_acme_nginx_http_site_is_owned || return 1
    fi
    if [ -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] || [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ]; then
        [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ] || return 1
        target=$(readlink -- "$NEXUS_IP_ACME_NGINX_ENABLED" 2>/dev/null) || return 1
        [ "$target" = "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || return 1
    fi
    temporary=$(mktemp "$available_dir/.rr-ip-acme-http.XXXXXX") || return 1
    if ! nexus_ip_acme_emit_nginx_http_site "$normalized" > "$temporary" || \
       ! chmod 644 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$NEXUS_IP_ACME_NGINX_AVAILABLE" || \
       ! sync -f "$available_dir"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || unlink "$temporary" 2>/dev/null || true
        return 1
    fi
    if [ ! -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] && [ ! -L "$NEXUS_IP_ACME_NGINX_ENABLED" ]; then
        ln -s -- "$NEXUS_IP_ACME_NGINX_AVAILABLE" "$NEXUS_IP_ACME_NGINX_ENABLED" || return 1
        sync -f "$enabled_dir" || return 1
    fi
    nexus_ip_acme_nginx_http_site_is_current "$normalized" || return 1
    nginx -t >/dev/null 2>&1 || return 1
    [ "$activation_mode" = active ] || return 0
    if systemctl is-active --quiet nginx >/dev/null 2>&1; then
        nginx -s reload >/dev/null 2>&1 || return 1
    else
        systemctl start nginx >/dev/null 2>&1 || return 1
    fi
    systemctl is-active --quiet nginx >/dev/null 2>&1 || return 1
    nexus_ip_acme_probe_nginx_http_site "$normalized"
}

nexus_ip_acme_remove_nginx_http_site() {
    local address="${1:-}" target="" changed=false available_dir=""
    available_dir=$(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE") || return 2
    [ -d "$available_dir" ] && [ ! -L "$available_dir" ] || return 2
    nexus_ip_acme_cleanup_atomic_files "$available_dir" http || return 2
    if [ -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] || [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ]; then
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_NGINX_ENABLED" || return 2
        [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ] || return 2
        target=$(readlink -- "$NEXUS_IP_ACME_NGINX_ENABLED" 2>/dev/null) || return 2
        [ "$target" = "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || return 2
        nexus_ip_acme_nginx_http_site_is_current "$address" || return 2
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_NGINX_ENABLED" || return 2
        unlink "$NEXUS_IP_ACME_NGINX_ENABLED" 2>/dev/null || return 2
        sync -f "$(dirname -- "$NEXUS_IP_ACME_NGINX_ENABLED")" || return 2
        changed=true
    fi
    if [ -e "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || [ -L "$NEXUS_IP_ACME_NGINX_AVAILABLE" ]; then
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_NGINX_AVAILABLE" || return 2
        nexus_ip_acme_nginx_http_site_is_owned || return 2
        # If the enabled link was already absent, exact rendered content still
        # proves this file belongs to the requested address before deletion.
        local expected="" actual=""
        expected=$(nexus_ip_acme_emit_nginx_http_site "$address" | sha256sum | awk '{print $1}') || return 2
        actual=$(sha256sum "$NEXUS_IP_ACME_NGINX_AVAILABLE" | awk '{print $1}') || return 2
        [ "$expected" = "$actual" ] || return 2
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_NGINX_AVAILABLE" || return 2
        nexus_ip_acme_nginx_http_site_is_owned || return 2
        unlink "$NEXUS_IP_ACME_NGINX_AVAILABLE" 2>/dev/null || return 2
        sync -f "$(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE")" || return 2
        changed=true
    fi
    if [ "$changed" = true ] && command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 || return 2
        if systemctl is-active --quiet nginx >/dev/null 2>&1; then
            nginx -s reload >/dev/null 2>&1 || return 2
        fi
    fi
}

nexus_ip_acme_nginx_http_site_removal_is_safe() {
    local address="${1:-}" target="" expected="" actual=""
    if [ ! -e "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] && \
       [ ! -L "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] && \
       [ ! -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] && \
       [ ! -L "$NEXUS_IP_ACME_NGINX_ENABLED" ]; then
        return 0
    fi
    if [ -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] || [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ]; then
        [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ] || return 1
        target=$(readlink -- "$NEXUS_IP_ACME_NGINX_ENABLED" 2>/dev/null) || return 1
        [ "$target" = "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || return 1
        nexus_ip_acme_nginx_http_site_is_current "$address"
        return $?
    fi
    nexus_ip_acme_nginx_http_site_is_owned || return 1
    expected=$(nexus_ip_acme_emit_nginx_http_site "$address" | sha256sum | awk '{print $1}') || return 1
    actual=$(sha256sum "$NEXUS_IP_ACME_NGINX_AVAILABLE" 2>/dev/null | awk '{print $1}') || return 1
    [ "$expected" = "$actual" ]
}

nexus_ip_acme_write_config() {
    local address="${1:-}" email="${2:-}" normalized="" payload=""
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    address="$normalized"
    nexus_ip_acme_email_is_valid "$email" || return 1
    payload=$(python3 - "$address" "$email" <<'PY'
import json
import sys
print(json.dumps({"address": sys.argv[1], "email": sys.argv[2], "version": 1}, sort_keys=True, separators=(",", ":")))
PY
    ) || return 1
    printf '%s\n' "$payload" | \
        nexus_ip_acme_write_atomic_file "$NEXUS_IP_ACME_CONFIG" 600
}

nexus_ip_acme_read_config() {
    local output_address="${1:-}" output_email="${2:-}" values=""
    local parsed_address="" parsed_email=""
    local -a parsed_values=()
    [[ "$output_address" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$output_email" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [ -f "$NEXUS_IP_ACME_CONFIG" ] && [ ! -L "$NEXUS_IP_ACME_CONFIG" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_IP_ACME_CONFIG" 2>/dev/null)" = 0:0:600:1 ] || return 1
    values=$(python3 - "$NEXUS_IP_ACME_CONFIG" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
if set(value) != {"address", "email", "version"} or value["version"] != 1:
    raise SystemExit(1)
if not isinstance(value["address"], str) or not isinstance(value["email"], str):
    raise SystemExit(1)
if any(c in value["address"] + value["email"] for c in "\r\n\0"):
    raise SystemExit(1)
print(value["address"])
print(value["email"])
PY
    ) || return 1
    mapfile -t parsed_values <<<"$values"
    [ "${#parsed_values[@]}" -eq 2 ] || return 1
    parsed_address="${parsed_values[0]}"
    parsed_email="${parsed_values[1]}"
    local normalized=""
    nexus_ip_acme_normalize_address "$parsed_address" normalized || return 1
    [ "$parsed_address" = "$normalized" ] || return 1
    nexus_ip_acme_email_is_valid "$parsed_email" || return 1
    printf -v "$output_address" '%s' "$parsed_address"
    printf -v "$output_email" '%s' "$parsed_email"
}

nexus_ip_acme_store_marker_is_valid() {
    local store="${1:-}" address="${2:-}" email="${3:-}"
    local marker="$store/.rr-nexus-ip-acme-store" email_sha="" expected_email_sha=""
    local -a lines=()
    nexus_ip_acme_is_global_address "$address" || return 1
    nexus_ip_acme_email_is_valid "$email" || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] || return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 3 ] || return 1
    [ "${lines[0]}" = "$NEXUS_IP_ACME_STORE_VALUE" ] || return 1
    [ "${lines[1]}" = "address=${address}" ] || return 1
    email_sha="${lines[2]#email_sha256=}"
    [ "${lines[2]}" = "email_sha256=${email_sha}" ] && [[ "$email_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    expected_email_sha=$(printf '%s' "$email" | sha256sum | awk '{print $1}') || return 1
    [ "$email_sha" = "$expected_email_sha" ]
}

nexus_ip_acme_store_tree_is_safe() {
    local store="${1:-}" address="${2:-}" email="${3:-}"
    [ -d "$store" ] && [ ! -L "$store" ] || return 1
    nexus_ip_acme_path_is_mountpoint "$store" && return 1
    nexus_ip_acme_store_marker_is_valid "$store" "$address" "$email" || return 1
    python3 - "$store" <<'PY' >/dev/null 2>&1
import os
import stat
import sys
root = os.path.abspath(sys.argv[1])
if os.path.realpath(root) != root:
    raise SystemExit(1)
root_info = os.lstat(root)
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    info = os.lstat(current)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != 0 or stat.S_IMODE(info.st_mode) != 0o700 or info.st_dev != root_info.st_dev:
        raise SystemExit(1)
    for name in dirs:
        info = os.lstat(os.path.join(current, name))
        if stat.S_ISLNK(info.st_mode) or info.st_dev != root_info.st_dev:
            raise SystemExit(1)
    for name in files:
        info = os.lstat(os.path.join(current, name))
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0 or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_dev != root_info.st_dev:
            raise SystemExit(1)
PY
}

nexus_ip_acme_candidate_stage_is_safe() {
    local stage="${1:-}"
    [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
    nexus_ip_acme_path_is_mountpoint "$stage" && return 1
    python3 - "$stage" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])
if os.path.realpath(root) != root:
    raise SystemExit(1)
root_info = os.lstat(root)
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    info = os.lstat(current)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) != 0o700
        or info.st_dev != root_info.st_dev
    ):
        raise SystemExit(1)
    for name in dirs:
        child = os.lstat(os.path.join(current, name))
        if stat.S_ISLNK(child.st_mode) or child.st_dev != root_info.st_dev:
            raise SystemExit(1)
    for name in files:
        child = os.lstat(os.path.join(current, name))
        if (
            not stat.S_ISREG(child.st_mode)
            or child.st_uid != 0
            or child.st_gid != 0
            or child.st_nlink != 1
            or stat.S_IMODE(child.st_mode) != 0o600
            or child.st_dev != root_info.st_dev
        ):
            raise SystemExit(1)
PY
}

nexus_ip_acme_cleanup_candidate_stages() {
    local action="${1:-remove}" entry="" base="" changed=false
    local -a candidates=()
    case "$action" in remove|validate-only) ;; *) return 1 ;; esac
    [ -d "$NEXUS_IP_ACME_STATE_ROOT" ] && \
        [ ! -L "$NEXUS_IP_ACME_STATE_ROOT" ] || return 1
    while IFS= read -r -d '' entry; do
        base=${entry##*/}
        [[ "$base" =~ ^candidate\.new\.[1-9][0-9]*$ ]] || continue
        nexus_ip_acme_candidate_stage_is_safe "$entry" || return 1
        candidates+=("$entry")
    done < <(find "$NEXUS_IP_ACME_STATE_ROOT" -mindepth 1 -maxdepth 1 \
        -name 'candidate.new.*' -print0)
    [ "$action" = remove ] || return 0
    for entry in "${candidates[@]}"; do
        nexus_ip_acme_parent_directory_is_safe "$entry" || return 1
        nexus_ip_acme_candidate_stage_is_safe "$entry" || return 1
        rm -rf -- "$entry" || return 1
        changed=true
    done
    [ "$changed" = false ] || sync -f "$NEXUS_IP_ACME_STATE_ROOT"
}

nexus_ip_acme_cleanup_live_temps() {
    local action="${1:-remove}" cert_dir=""
    cert_dir=$(dirname -- "$NEXUS_IP_ACME_LIVE_CERT") || return 1
    [ "$(dirname -- "$NEXUS_IP_ACME_LIVE_KEY")" = "$cert_dir" ] && \
        [ "$(dirname -- "$NEXUS_IP_ACME_PENDING")" = "$cert_dir" ] || return 1
    [ -d "$cert_dir" ] && [ ! -L "$cert_dir" ] || return 1
    nexus_ip_acme_cleanup_atomic_files "$cert_dir" live "$action"
}

nexus_ip_acme_write_candidate_status() {
    local store="${1:-}" status="${2:-}"
    case "$status" in pending|issued) ;; *) return 1 ;; esac
    [ "$store" = "$NEXUS_IP_ACME_CANDIDATE_STORE" ] || return 1
    printf 'rr-nexus-ip-acme-candidate-%s-v1\n' "$status" | \
        nexus_ip_acme_write_atomic_file "$store/.rr-nexus-ip-acme-candidate" 600
}

nexus_ip_acme_candidate_status_is() {
    local status="${1:-}" marker="$NEXUS_IP_ACME_CANDIDATE_STORE/.rr-nexus-ip-acme-candidate"
    case "$status" in pending|issued) ;; *) return 1 ;; esac
    nexus_ip_acme_exact_marker "$marker" \
        "rr-nexus-ip-acme-candidate-${status}-v1"
}

nexus_ip_acme_harden_store_tree() {
    local store="${1:-}"
    [ -d "$store" ] && [ ! -L "$store" ] || return 1
    find "$store" -xdev -type l -print -quit 2>/dev/null | grep -q . && return 1
    find "$store" -xdev \! -type d \! -type f -print -quit 2>/dev/null | grep -q . && return 1
    chown -R 0:0 -- "$store" || return 1
    find "$store" -xdev -type d -exec chmod 700 {} + || return 1
    find "$store" -xdev -type f -exec chmod 600 {} + || return 1
}

nexus_ip_acme_fsync_store_tree() {
    local store="${1:-}"
    [ -d "$store" ] && [ ! -L "$store" ] || return 1
    python3 - "$store" <<'PY' >/dev/null 2>&1
import os
import stat
import sys
root = os.path.abspath(sys.argv[1])
directories = []
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    directories.append(current)
    for name in files:
        path = os.path.join(current, name)
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            raise SystemExit(1)
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
for directory in reversed(directories):
    descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

nexus_ip_acme_write_store_marker() {
    local store="${1:-}" address="${2:-}" email="${3:-}" email_sha=""
    email_sha=$(printf '%s' "$email" | sha256sum | awk '{print $1}') || return 1
    printf '%s\naddress=%s\nemail_sha256=%s\n' \
        "$NEXUS_IP_ACME_STORE_VALUE" "$address" "$email_sha" | \
        nexus_ip_acme_write_atomic_file "$store/.rr-nexus-ip-acme-store" 600
}

nexus_ip_acme_pair_paths() {
    local store="${1:-}" output_cert="${2:-}" output_key="${3:-}"
    [[ "$output_cert" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$output_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    local cert_path="$store/certificates/${NEXUS_IP_ACME_CERT_NAME}.crt"
    local key_path="$store/certificates/${NEXUS_IP_ACME_CERT_NAME}.key"
    [ -f "$cert_path" ] && [ ! -L "$cert_path" ] && \
        [ -f "$key_path" ] && [ ! -L "$key_path" ] || return 1
    printf -v "$output_cert" '%s' "$cert_path"
    printf -v "$output_key" '%s' "$key_path"
}

nexus_ip_acme_pair_is_trusted() {
    local cert="${1:-}" key="${2:-}" address="${3:-}"
    local ca_bundle="${RR_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
    nexus_ip_acme_is_global_address "$address" || return 1
    [ -f "$cert" ] && [ ! -L "$cert" ] && [ -f "$key" ] && [ ! -L "$key" ] || return 1
    case "$(stat -c '%u:%g:%a:%h' -- "$cert" 2>/dev/null)" in
        0:0:600:1|0:0:644:1) ;;
        *) return 1 ;;
    esac
    [ "$(stat -c '%u:%g:%a:%h' -- "$key" 2>/dev/null)" = 0:0:600:1 ] || return 1
    if declare -F certificate_identity_matches >/dev/null 2>&1; then
        certificate_identity_matches "$cert" "$address" || return 1
    else
        python3 - "$cert" "$address" <<'PY' >/dev/null 2>&1 || return 1
import ipaddress
import ssl
import sys
expected = ipaddress.ip_address(sys.argv[2])
decoded = ssl._ssl._test_decode_cert(sys.argv[1])
for kind, value in decoded.get("subjectAltName", ()):
    if kind == "IP Address" and ipaddress.ip_address(value) == expected:
        raise SystemExit(0)
raise SystemExit(1)
PY
    fi
    if declare -F certificate_private_key_matches >/dev/null 2>&1; then
        certificate_private_key_matches "$cert" "$key" || return 1
    else
        local cert_public="" key_public=""
        cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
        key_public=$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
        [ "$cert_public" = "$key_public" ] || return 1
    fi
    [ -s "$ca_bundle" ] || return 1
    openssl x509 -in "$cert" -noout -checkend 21600 >/dev/null 2>&1 || return 1
    openssl verify -purpose sslserver -CAfile "$ca_bundle" \
        -untrusted "$cert" "$cert" >/dev/null 2>&1
}

nexus_ip_acme_store_pair_is_trusted() {
    local store="${1:-}" address="${2:-}" email="${3:-}" cert="" key=""
    nexus_ip_acme_store_tree_is_safe "$store" "$address" "$email" || return 1
    nexus_ip_acme_pair_paths "$store" cert key || return 1
    nexus_ip_acme_pair_is_trusted "$cert" "$key" "$address"
}

nexus_ip_acme_pair_fingerprint() {
    local cert="${1:-}" key="${2:-}" address="${3:-}"
    local cert_sha="" key_sha=""
    nexus_ip_acme_pair_is_trusted "$cert" "$key" "$address" || return 1
    cert_sha=$(sha256sum "$cert" 2>/dev/null | awk '{print $1}') || return 1
    key_sha=$(sha256sum "$key" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$cert_sha" =~ ^[0-9a-f]{64}$ ]] && [[ "$key_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s:%s\n' "$cert_sha" "$key_sha"
}

nexus_ip_acme_store_fingerprint() {
    local store="${1:-}" address="${2:-}" email="${3:-}" cert="" key=""
    nexus_ip_acme_store_pair_is_trusted "$store" "$address" "$email" || return 1
    nexus_ip_acme_pair_paths "$store" cert key || return 1
    nexus_ip_acme_pair_fingerprint "$cert" "$key" "$address"
}

nexus_ip_acme_live_fingerprint() {
    local address="${1:-}"
    nexus_ip_acme_pair_fingerprint "$NEXUS_IP_ACME_LIVE_CERT" \
        "$NEXUS_IP_ACME_LIVE_KEY" "$address"
}

nexus_ip_acme_write_journal() {
    local address="${1:-}" old_fingerprint="${2:-}" new_fingerprint="${3:-}"
    local phase="${4:-}" payload=""
    local normalized=""
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    [ "$address" = "$normalized" ] || return 1
    [[ "$old_fingerprint" = none || "$old_fingerprint" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] || return 1
    [[ "$new_fingerprint" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] || return 1
    case "$phase" in prepared|store|live) ;; *) return 1 ;; esac
    payload=$(python3 - "$address" "$old_fingerprint" "$new_fingerprint" "$phase" <<'PY'
import json
import sys
print(json.dumps({
    "address": sys.argv[1],
    "new_fingerprint": sys.argv[3],
    "old_fingerprint": sys.argv[2],
    "phase": sys.argv[4],
    "version": 1,
}, sort_keys=True, separators=(",", ":")))
PY
    ) || return 1
    printf '%s\n' "$payload" | \
        nexus_ip_acme_write_atomic_file "$NEXUS_IP_ACME_JOURNAL" 600
}

nexus_ip_acme_read_journal() {
    local output_address="${1:-}" output_old="${2:-}" output_new="${3:-}" output_phase="${4:-}"
    local values="" parsed_address="" parsed_old="" parsed_new="" parsed_phase=""
    local -a parsed=()
    for _nexus_output in "$output_address" "$output_old" "$output_new" "$output_phase"; do
        [[ "$_nexus_output" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    done
    [ -f "$NEXUS_IP_ACME_JOURNAL" ] && [ ! -L "$NEXUS_IP_ACME_JOURNAL" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_IP_ACME_JOURNAL" 2>/dev/null)" = 0:0:600:1 ] || return 1
    values=$(python3 - "$NEXUS_IP_ACME_JOURNAL" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
if set(value) != {"address", "new_fingerprint", "old_fingerprint", "phase", "version"} or value["version"] != 1:
    raise SystemExit(1)
for key in ("address", "new_fingerprint", "old_fingerprint", "phase"):
    if not isinstance(value[key], str) or any(c in value[key] for c in "\r\n\0"):
        raise SystemExit(1)
print(value["address"])
print(value["old_fingerprint"])
print(value["new_fingerprint"])
print(value["phase"])
PY
    ) || return 1
    mapfile -t parsed <<<"$values"
    [ "${#parsed[@]}" -eq 4 ] || return 1
    parsed_address="${parsed[0]}"
    parsed_old="${parsed[1]}"
    parsed_new="${parsed[2]}"
    parsed_phase="${parsed[3]}"
    local normalized=""
    nexus_ip_acme_normalize_address "$parsed_address" normalized || return 1
    [ "$parsed_address" = "$normalized" ] || return 1
    [[ "$parsed_old" = none || "$parsed_old" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] || return 1
    [[ "$parsed_new" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] || return 1
    case "$parsed_phase" in prepared|store|live) ;; *) return 1 ;; esac
    printf -v "$output_address" '%s' "$parsed_address"
    printf -v "$output_old" '%s' "$parsed_old"
    printf -v "$output_new" '%s' "$parsed_new"
    printf -v "$output_phase" '%s' "$parsed_phase"
}

nexus_ip_acme_clear_journal() {
    local address="" old_fingerprint="" new_fingerprint="" phase=""
    nexus_ip_acme_read_journal address old_fingerprint new_fingerprint phase || return 1
    unlink "$NEXUS_IP_ACME_JOURNAL" 2>/dev/null || return 1
    sync -f "$NEXUS_IP_ACME_STATE_ROOT" || return 1
    [ ! -e "$NEXUS_IP_ACME_JOURNAL" ] && [ ! -L "$NEXUS_IP_ACME_JOURNAL" ]
}

nexus_ip_acme_remove_store() {
    local store="${1:-}" address="${2:-}" email="${3:-}" parent="" canonical=""
    case "$store" in
        "$NEXUS_IP_ACME_ACTIVE_STORE"|"$NEXUS_IP_ACME_CANDIDATE_STORE") ;;
        *) return 1 ;;
    esac
    [ -e "$store" ] || [ -L "$store" ] || return 0
    nexus_ip_acme_store_tree_is_safe "$store" "$address" "$email" || return 1
    nexus_ip_acme_path_is_mountpoint "$store" && return 1
    parent=$(dirname -- "$store") || return 1
    nexus_ip_acme_parent_directory_is_safe "$store" || return 1
    canonical=$(readlink -f -- "$parent" 2>/dev/null) || return 1
    [ "$canonical" = "$NEXUS_IP_ACME_STATE_ROOT" ] || return 1
    nexus_ip_acme_store_tree_is_safe "$store" "$address" "$email" || return 1
    nexus_ip_acme_parent_directory_is_safe "$store" || return 1
    rm -rf -- "$store" || return 1
    sync -f "$parent" || return 1
    [ ! -e "$store" ] && [ ! -L "$store" ]
}

nexus_ip_acme_prepare_candidate() {
    local address="${1:-}" email="${2:-}" candidate="$NEXUS_IP_ACME_CANDIDATE_STORE"
    local active="$NEXUS_IP_ACME_ACTIVE_STORE" stage=""
    nexus_ip_acme_cleanup_candidate_stages || return 1
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        nexus_ip_acme_store_tree_is_safe "$candidate" "$address" "$email"
        return $?
    fi
    stage="${candidate}.new.${BASHPID:-$$}"
    [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 1
    if [ -e "$active" ] || [ -L "$active" ]; then
        if ! nexus_ip_acme_store_tree_is_safe "$active" "$address" "$email" || \
           ! cp -a -- "$active" "$stage"; then
            nexus_ip_acme_cleanup_candidate_stages >/dev/null 2>&1 || true
            return 1
        fi
    elif ! mkdir -m 700 -- "$stage" || \
         ! nexus_ip_acme_write_store_marker "$stage" "$address" "$email"; then
        nexus_ip_acme_cleanup_candidate_stages >/dev/null 2>&1 || true
        return 1
    fi
    if ! nexus_ip_acme_harden_store_tree "$stage"; then
        nexus_ip_acme_cleanup_candidate_stages >/dev/null 2>&1 || true
        return 1
    fi
    # Reset inherited active status before publication of the clone name.  A
    # crash after rename can therefore never mistake an unrenewed clone for a
    # completed lego response.
    local candidate_marker="$stage/.rr-nexus-ip-acme-candidate"
    if ! printf '%s\n' rr-nexus-ip-acme-candidate-pending-v1 | \
           nexus_ip_acme_write_atomic_file "$candidate_marker" 600 || \
       ! nexus_ip_acme_store_tree_is_safe "$stage" "$address" "$email" || \
       ! nexus_ip_acme_fsync_store_tree "$stage" || \
       ! mv -- "$stage" "$candidate" || \
       ! sync -f "$NEXUS_IP_ACME_STATE_ROOT"; then
        nexus_ip_acme_cleanup_candidate_stages >/dev/null 2>&1 || true
        return 1
    fi
    nexus_ip_acme_store_tree_is_safe "$candidate" "$address" "$email"
}

nexus_ip_acme_exchange_stores() {
    local active="$NEXUS_IP_ACME_ACTIVE_STORE" candidate="$NEXUS_IP_ACME_CANDIDATE_STORE"
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
    if [ ! -e "$active" ] && [ ! -L "$active" ]; then
        mv -- "$candidate" "$active" || return 1
    else
        [ -d "$active" ] && [ ! -L "$active" ] || return 1
        python3 - "$active" "$candidate" <<'PY' >/dev/null 2>&1 || return 1
import ctypes
import os
import sys
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    raise SystemExit(1)
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
AT_FDCWD = -100
RENAME_EXCHANGE = 2
if renameat2(AT_FDCWD, os.fsencode(sys.argv[1]), AT_FDCWD, os.fsencode(sys.argv[2]), RENAME_EXCHANGE) != 0:
    raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
PY
    fi
    sync -f "$NEXUS_IP_ACME_STATE_ROOT"
}

nexus_ip_acme_publish_live() {
    local address="${1:-}" email="${2:-}" cert="" key="" cert_dir=""
    local cert_tmp="" key_tmp="" store_fingerprint="" live_fingerprint=""
    nexus_ip_acme_store_pair_is_trusted "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email" || return 1
    nexus_ip_acme_ensure_gate || return 1
    nexus_ip_acme_pair_paths "$NEXUS_IP_ACME_ACTIVE_STORE" cert key || return 1
    store_fingerprint=$(nexus_ip_acme_pair_fingerprint "$cert" "$key" "$address") || return 1
    if live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address" 2>/dev/null) && \
       [ "$live_fingerprint" = "$store_fingerprint" ]; then
        return 0
    fi
    declare -F nexus_publish_ip_certificate_pair >/dev/null 2>&1 || return 1
    declare -F nexus_ip_certificate_pair_is_ready >/dev/null 2>&1 || return 1
    cert_dir=$(dirname -- "$NEXUS_IP_ACME_LIVE_CERT") || return 1
    [ "$(dirname -- "$NEXUS_IP_ACME_LIVE_KEY")" = "$cert_dir" ] && \
        [ "$(dirname -- "$NEXUS_IP_ACME_PENDING")" = "$cert_dir" ] || return 1
    [ -d "$cert_dir" ] && [ ! -L "$cert_dir" ] || return 1
    nexus_ip_acme_cleanup_live_temps || return 1
    cert_tmp=$(mktemp "$cert_dir/.ip-acme.crt.XXXXXX") || return 1
    key_tmp=$(mktemp "$cert_dir/.ip-acme.key.XXXXXX") || {
        unlink "$cert_tmp" 2>/dev/null || true
        return 1
    }
    if ! cp -- "$cert" "$cert_tmp" || ! cp -- "$key" "$key_tmp" || \
       ! chmod 644 "$cert_tmp" || ! chmod 600 "$key_tmp" || \
       ! sync -f "$cert_tmp" || ! sync -f "$key_tmp"; then
        unlink "$cert_tmp" 2>/dev/null || true
        unlink "$key_tmp" 2>/dev/null || true
        return 1
    fi
    if ! nexus_publish_ip_certificate_pair "$cert_tmp" "$key_tmp" \
        "$NEXUS_IP_ACME_LIVE_CERT" "$NEXUS_IP_ACME_LIVE_KEY" "$cert_dir" \
        "$NEXUS_IP_ACME_PENDING" "$address"; then
        [ -e "$cert_tmp" ] || [ -L "$cert_tmp" ] || cert_tmp=""
        [ -e "$key_tmp" ] || [ -L "$key_tmp" ] || key_tmp=""
        [ -z "$cert_tmp" ] || unlink "$cert_tmp" 2>/dev/null || true
        [ -z "$key_tmp" ] || unlink "$key_tmp" 2>/dev/null || true
        return 1
    fi
    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address") || return 1
    [ "$live_fingerprint" = "$store_fingerprint" ]
}

nexus_ip_acme_ensure_gate() {
    local gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    local gate_dropin="${NEXUS_IP_CERT_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf}"
    declare -F nexus_ip_certificate_gate_artifacts_are_current >/dev/null 2>&1 || return 1
    if nexus_ip_certificate_gate_artifacts_are_current "$NEXUS_IP_ACME_LIVE_CERT" \
        "$NEXUS_IP_ACME_LIVE_KEY" "$NEXUS_IP_ACME_PENDING"; then
        # Files may have reached disk immediately before a power loss but not
        # the running manager.  Always compile and prove the exact condition set.
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        declare -F nexus_nginx_exec_condition_set_is_exact >/dev/null 2>&1 || return 1
        nexus_nginx_exec_condition_set_is_exact "$NEXUS_IP_ACME_LIVE_CERT" \
            "$NEXUS_IP_ACME_LIVE_KEY" "$NEXUS_IP_ACME_PENDING" true
        return $?
    fi
    # A partial or foreign same-name collision is never overwritten.
    if [ -e "$gate_script" ] || [ -L "$gate_script" ] || \
       [ -e "$gate_dropin" ] || [ -L "$gate_dropin" ]; then
        return 1
    fi
    declare -F nexus_install_ip_certificate_gate >/dev/null 2>&1 || return 1
    # On a clean host the HTTP-only challenge site was started without this
    # gate.  Install it only after a trusted active candidate exists and before
    # publishing either live TLS file; with no live pair the existing gate
    # explicitly allows Nginx to keep serving HTTP-01.
    nexus_install_ip_certificate_gate "$NEXUS_IP_ACME_LIVE_CERT" \
        "$NEXUS_IP_ACME_LIVE_KEY" "$NEXUS_IP_ACME_PENDING"
}

nexus_ip_acme_gate_runtime_is_ready_readonly() {
    declare -F nexus_ip_certificate_gate_artifacts_are_current >/dev/null 2>&1 || return 1
    declare -F nexus_nginx_exec_condition_set_is_exact >/dev/null 2>&1 || return 1
    nexus_ip_certificate_gate_artifacts_are_current "$NEXUS_IP_ACME_LIVE_CERT" \
        "$NEXUS_IP_ACME_LIVE_KEY" "$NEXUS_IP_ACME_PENDING" && \
        nexus_nginx_exec_condition_set_is_exact "$NEXUS_IP_ACME_LIVE_CERT" \
            "$NEXUS_IP_ACME_LIVE_KEY" "$NEXUS_IP_ACME_PENDING" true
}

nexus_ip_acme_update_lock_context_is_trusted() {
    [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] && \
        [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ] || return 1
    case "${RR_UPDATE_LOCK_OWNER:-}" in
        1)
            [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 0 ] || return 1
            declare -F rr_inherited_update_lock_fds_present >/dev/null 2>&1 || return 1
            rr_inherited_update_lock_fds_present
            ;;
        0)
            [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ] || return 1
            declare -F rr_delegated_update_lock_context_is_trusted \
                >/dev/null 2>&1 || return 1
            rr_delegated_update_lock_context_is_trusted
            ;;
        *) return 1 ;;
    esac
}

nexus_ip_acme_trusted_restore_context() {
    local active="${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}" stage="" phase=""
    [ -e "$active" ] || [ -L "$active" ] || return 1
    nexus_ip_acme_update_lock_context_is_trusted || return 1
    declare -F rr_restore_active_stage >/dev/null 2>&1 || return 1
    declare -F rr_restore_read_exact_marker >/dev/null 2>&1 || return 1
    stage=$(rr_restore_active_stage) || return 1
    [ -n "$stage" ] || return 1
    phase=$(rr_restore_read_exact_marker "$stage/phase") || return 1
    case "$phase" in
        freezing|frozen|prepared|pre_recovery_failed|mutating|cleared|applied|migrating|rolling_back|recovery_failed)
            ;;
        *) return 1 ;;
    esac
}

nexus_ip_acme_tls_site_context_readonly() {
    local address="${1:-}" output_state="${2:-}" output_port="${3:-}"
    local normalized="" config_file="${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}"
    local available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local cert_dir="${NEXUS_CERT_DIR:-/etc/rr-nexus/certs}"
    local site="" enabled="" values="" state="" port="" certificate_mode=""
    local -a parsed=()
    [[ "$output_state" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$output_port" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    [ "$NEXUS_IP_ACME_LIVE_CERT" = "$cert_dir/ip.crt" ] && \
        [ "$NEXUS_IP_ACME_LIVE_KEY" = "$cert_dir/ip.key" ] && \
        [ "$NEXUS_IP_ACME_PENDING" = "$cert_dir/.ip-cert-pending" ] || return 1
    [ -f "$config_file" ] && [ ! -L "$config_file" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$config_file" 2>/dev/null)" = 0:0:600:1 ] || return 1
    values=$(python3 - "$config_file" "$normalized" <<'PY'
import ipaddress
import json
import sys

path, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    value = json.load(stream)
if not isinstance(value, dict) or value.get("mode") != "public":
    raise SystemExit(1)
if value.get("certificate_mode") not in {"pending-acme-ip", "acme-ip-shortlived"}:
    raise SystemExit(1)
try:
    configured = str(ipaddress.ip_address(value.get("domain", "")))
except ValueError:
    raise SystemExit(1)
if configured != expected:
    raise SystemExit(1)
port = value.get("public_port")
if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535 or port in (80, 7900):
    raise SystemExit(1)
print(port)
print(value["certificate_mode"])
PY
    ) || return 1
    mapfile -t parsed <<<"$values"
    [ "${#parsed[@]}" -eq 2 ] && [[ "${parsed[0]}" =~ ^[0-9]+$ ]] || return 1
    port="${parsed[0]}"
    certificate_mode="${parsed[1]}"
    site="$available_dir/rr-nexus-ip.conf"
    enabled="$enabled_dir/rr-nexus-ip.conf"
    declare -F nexus_ip_nginx_site_is_exact >/dev/null 2>&1 || return 1
    if [ ! -e "$site" ] && [ ! -L "$site" ] && \
       [ ! -e "$enabled" ] && [ ! -L "$enabled" ]; then
        state=absent
    else
        [ -f "$site" ] && [ ! -L "$site" ] && [ -L "$enabled" ] || return 1
        nexus_ip_nginx_site_is_exact "$normalized" "$port" \
            "$certificate_mode" "$site" "$enabled" || return 1
        state=present
    fi
    printf -v "$output_state" '%s' "$state"
    printf -v "$output_port" '%s' "$port"
}

nexus_ip_acme_served_leaf_matches_live() {
    local address="${1:-}" port="${2:-}"
    local ca_bundle="${RR_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
    nexus_ip_acme_is_global_address "$address" || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    [ -s "$ca_bundle" ] && [ -f "$NEXUS_IP_ACME_LIVE_CERT" ] && \
        [ ! -L "$NEXUS_IP_ACME_LIVE_CERT" ] || return 1
    python3 - "$address" "$port" "$ca_bundle" \
        "$NEXUS_IP_ACME_LIVE_CERT" <<'PY' >/dev/null 2>&1
import hashlib
import re
import socket
import ssl
import sys

address, raw_port, ca_bundle, certificate = sys.argv[1:]
context = ssl.create_default_context(cafile=ca_bundle)
context.check_hostname = True
with socket.create_connection(("127.0.0.1", int(raw_port)), timeout=5) as connection:
    with context.wrap_socket(connection, server_hostname=address) as tls:
        served = tls.getpeercert(binary_form=True)
data = open(certificate, "r", encoding="ascii").read()
match = re.search(
    r"-----BEGIN CERTIFICATE-----\s+.*?-----END CERTIFICATE-----",
    data,
    re.DOTALL,
)
if match is None:
    raise SystemExit(1)
expected = ssl.PEM_cert_to_DER_cert(match.group(0))
expected_bytes = expected if isinstance(expected, bytes) else bytes(expected, "latin1")
if not served or not hashlib.sha256(served).digest() == hashlib.sha256(expected_bytes).digest():
    raise SystemExit(1)
PY
}

nexus_ip_acme_reload_nginx() {
    local address="${1:-}" tls_state="" panel_port=""
    nexus_ip_acme_tls_site_context_readonly "$address" tls_state panel_port || return 1
    nginx -t >/dev/null 2>&1 || return 1
    declare -F nexus_ip_certificate_gate_allows >/dev/null 2>&1 || return 1
    nexus_ip_certificate_gate_allows "$NEXUS_IP_ACME_LIVE_CERT" \
        "$NEXUS_IP_ACME_LIVE_KEY" "$NEXUS_IP_ACME_PENDING" || return 1
    if [ "${NEXUS_IP_ACME_DEFER_NGINX_ACTIVATION:-0}" = 1 ]; then
        nexus_ip_acme_trusted_restore_context || return 1
        return 0
    fi
    if [ "${RR_TEST_IP_ACME_SKIP_NGINX_RELOAD:-0}" = 1 ]; then
        [ "${RR_TEST_IP_ACME:-0}" = 1 ] || return 1
        [ "$tls_state" = absent ] || \
            [ "${RR_TEST_IP_ACME_SERVED_LEAF_PROVED:-0}" = 1 ] || return 1
        return 0
    fi
    if systemctl is-active --quiet nginx >/dev/null 2>&1; then
        # Bypass a mutable systemd ExecReload and require the native process to
        # acknowledge the configuration before observing the served leaf.
        nginx -s reload >/dev/null 2>&1 || return 1
    else
        systemctl start nginx >/dev/null 2>&1 || return 1
    fi
    systemctl is-active --quiet nginx >/dev/null 2>&1 || return 1
    if [ "$tls_state" = present ]; then
        nexus_ip_acme_served_leaf_matches_live "$address" "$panel_port"
    else
        nexus_ip_acme_probe_nginx_http_site "$address"
    fi
}

nexus_ip_acme_fault() {
    local point="${1:-}"
    [ "${RR_TEST_IP_ACME:-0}" = 1 ] && [ "${RR_TEST_IP_ACME_FAULT:-}" = "$point" ]
}

nexus_ip_acme_finish_publication() {
    local address="${1:-}" email="${2:-}" old_fingerprint="${3:-}"
    local new_fingerprint="${4:-}" phase="${5:-}" active_fingerprint=""
    local candidate_fingerprint="" live_fingerprint=""
    case "$phase" in prepared|store|live) ;; *) return 1 ;; esac

    active_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email" 2>/dev/null) || active_fingerprint=none
    candidate_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_CANDIDATE_STORE" "$address" "$email" 2>/dev/null) || candidate_fingerprint=none

    if [ "$active_fingerprint" != "$new_fingerprint" ]; then
        [ "$candidate_fingerprint" = "$new_fingerprint" ] || return 1
        if [ "$old_fingerprint" = none ]; then
            [ "$active_fingerprint" = none ] || return 1
        else
            [ "$active_fingerprint" = "$old_fingerprint" ] || return 1
        fi
        nexus_ip_acme_exchange_stores || return 1
        active_fingerprint=$(nexus_ip_acme_store_fingerprint \
            "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email") || return 1
        [ "$active_fingerprint" = "$new_fingerprint" ] || return 1
    fi
    nexus_ip_acme_write_journal "$address" "$old_fingerprint" "$new_fingerprint" store || return 1
    nexus_ip_acme_fault after_store && return 97

    nexus_ip_acme_ensure_gate || return 1

    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address" 2>/dev/null) || live_fingerprint=none
    if [ "$live_fingerprint" != "$new_fingerprint" ]; then
        nexus_ip_acme_publish_live "$address" "$email" || return 1
    fi
    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address") || return 1
    [ "$live_fingerprint" = "$new_fingerprint" ] || return 1
    nexus_ip_acme_fault after_live_pair && return 98
    nexus_ip_acme_write_journal "$address" "$old_fingerprint" "$new_fingerprint" live || return 1
    nexus_ip_acme_reload_nginx "$address" || return 1
    nexus_ip_acme_fault after_reload && return 99

    # Journal remains until the exchanged-out old store is safely removed.
    if [ -e "$NEXUS_IP_ACME_CANDIDATE_STORE" ] || [ -L "$NEXUS_IP_ACME_CANDIDATE_STORE" ]; then
        nexus_ip_acme_remove_store "$NEXUS_IP_ACME_CANDIDATE_STORE" "$address" "$email" || return 1
    fi
    nexus_ip_acme_clear_journal
}

nexus_ip_acme_recover_locked() {
    local expected_address="${1:-}" address="" email="" normalized_expected=""
    local journal_address="" old_fingerprint="" new_fingerprint="" phase=""
    local active_fingerprint="" candidate_fingerprint="" live_fingerprint=""
    NEXUS_IP_ACME_RECOVERED_PUBLICATION=0
    nexus_ip_acme_prepare_state_root || return 1
    nexus_ip_acme_read_config address email || return 1
    nexus_ip_acme_cleanup_candidate_stages || return 1
    nexus_ip_acme_cleanup_live_temps || return 1
    if [ -n "$expected_address" ]; then
        nexus_ip_acme_normalize_address "$expected_address" normalized_expected || return 1
        [ "$address" = "$normalized_expected" ] || return 1
    fi

    if [ -e "$NEXUS_IP_ACME_JOURNAL" ] || [ -L "$NEXUS_IP_ACME_JOURNAL" ]; then
        nexus_ip_acme_read_journal journal_address old_fingerprint \
            new_fingerprint phase || return 1
        [ "$journal_address" = "$address" ] || return 1
        nexus_ip_acme_finish_publication "$address" "$email" \
            "$old_fingerprint" "$new_fingerprint" "$phase" || return $?
        NEXUS_IP_ACME_RECOVERED_PUBLICATION=1
        return 0
    fi

    active_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email" 2>/dev/null) || active_fingerprint=none
    candidate_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_CANDIDATE_STORE" "$address" "$email" 2>/dev/null) || candidate_fingerprint=none
    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address" 2>/dev/null) || live_fingerprint=none

    if [ "$candidate_fingerprint" != none ] && \
       { nexus_ip_acme_candidate_status_is issued || \
         [ "$candidate_fingerprint" != "$active_fingerprint" ]; }; then
        # A valid orphan candidate is proof that lego already returned a
        # certificate before a crash.  Persist the journal now and never call
        # the CA again for this generation.
        nexus_ip_acme_write_journal "$address" "$active_fingerprint" \
            "$candidate_fingerprint" prepared || return 1
        nexus_ip_acme_finish_publication "$address" "$email" \
            "$active_fingerprint" "$candidate_fingerprint" prepared || return $?
        NEXUS_IP_ACME_RECOVERED_PUBLICATION=1
        return 0
    fi

    if [ "$active_fingerprint" != none ] && [ "$live_fingerprint" != "$active_fingerprint" ]; then
        # Active is authoritative even without a journal.  Recording an
        # old==new publication still makes a crash during live pair repair
        # unambiguous and recoverable.
        nexus_ip_acme_write_journal "$address" "$active_fingerprint" \
            "$active_fingerprint" store || return 1
        nexus_ip_acme_finish_publication "$address" "$email" \
            "$active_fingerprint" "$active_fingerprint" store || return $?
        NEXUS_IP_ACME_RECOVERED_PUBLICATION=1
        return 0
    fi

    if [ "$candidate_fingerprint" != none ] && \
       [ "$candidate_fingerprint" = "$active_fingerprint" ] && \
       [ "$live_fingerprint" = "$active_fingerprint" ]; then
        # lego found the current generation not due.  It is now safe to remove
        # the proven clone; no certificate/store/live mutation is required.
        nexus_ip_acme_remove_store "$NEXUS_IP_ACME_CANDIDATE_STORE" \
            "$address" "$email" || return 1
    fi
    return 0
}

nexus_ip_acme_run_lego_candidate() {
    local address="${1:-}" email="${2:-}" result=0
    nexus_ip_acme_store_tree_is_safe "$NEXUS_IP_ACME_CANDIDATE_STORE" \
        "$address" "$email" || return 1
    nexus_ip_acme_prepare_webroot || return 1
    nexus_ip_acme_nginx_http_site_is_current "$address" || return 1
    nexus_ip_acme_probe_nginx_http_site "$address" || return 1
    nexus_ip_acme_lego_marker_is_current || return 1
    # lego v5 command syntax is `lego run [options]`.  `--profile shortlived`
    # is required for Let's Encrypt IP certificates; leaving --renew-days at
    # its zero default preserves lego's ARI/dynamic short-lived threshold.
    "$NEXUS_IP_ACME_LEGO_BIN" run \
        --accept-tos \
        --email "$email" \
        --domains "$address" \
        --cert.name "$NEXUS_IP_ACME_CERT_NAME" \
        --path "$NEXUS_IP_ACME_CANDIDATE_STORE" \
        --profile shortlived \
        --http \
        --http.webroot "$NEXUS_IP_ACME_WEBROOT" || result=$?
    # Preserve even a failed candidate: account creation may have succeeded,
    # and a later retry must reuse that account instead of starting over.
    nexus_ip_acme_harden_store_tree "$NEXUS_IP_ACME_CANDIDATE_STORE" || return 1
    nexus_ip_acme_store_tree_is_safe "$NEXUS_IP_ACME_CANDIDATE_STORE" \
        "$address" "$email" || return 1
    nexus_ip_acme_webroot_is_safe || return 1
    [ "$result" -eq 0 ] || return "$result"
    nexus_ip_acme_store_pair_is_trusted "$NEXUS_IP_ACME_CANDIDATE_STORE" \
        "$address" "$email" || return 1
    nexus_ip_acme_fsync_store_tree "$NEXUS_IP_ACME_CANDIDATE_STORE" || return 1
    nexus_ip_acme_write_candidate_status "$NEXUS_IP_ACME_CANDIDATE_STORE" issued || return 1
    nexus_ip_acme_fsync_store_tree "$NEXUS_IP_ACME_CANDIDATE_STORE"
}

nexus_ip_acme_renew_locked() {
    local address="" email="" active_fingerprint="" candidate_fingerprint=""
    local live_fingerprint=""
    [ ! -e "${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}" ] && \
        [ ! -L "${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}" ] || return 75
    nexus_ip_acme_prepare_state_root || return 1
    nexus_ip_acme_read_config address email || return 1
    nexus_ip_acme_prepare_webroot || return 1
    nexus_ip_acme_install_nginx_http_site "$address" || return 1
    nexus_ip_acme_recover_locked "$address" || return $?
    [ "$NEXUS_IP_ACME_RECOVERED_PUBLICATION" = 0 ] || return 0

    nexus_ip_acme_prepare_candidate "$address" "$email" || return 1
    active_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email" 2>/dev/null) || active_fingerprint=none
    candidate_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_CANDIDATE_STORE" "$address" "$email" 2>/dev/null) || candidate_fingerprint=none
    if ! nexus_ip_acme_candidate_status_is issued && \
       { [ "$candidate_fingerprint" = none ] || \
         [ "$candidate_fingerprint" = "$active_fingerprint" ]; }; then
        nexus_ip_acme_run_lego_candidate "$address" "$email" || return $?
    fi
    nexus_ip_acme_fault after_lego && return 96

    active_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email" 2>/dev/null) || active_fingerprint=none
    candidate_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_CANDIDATE_STORE" "$address" "$email") || return 1
    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address" 2>/dev/null) || live_fingerprint=none

    if [ "$candidate_fingerprint" = "$active_fingerprint" ] && \
       [ "$live_fingerprint" = "$active_fingerprint" ]; then
        nexus_ip_acme_remove_store "$NEXUS_IP_ACME_CANDIDATE_STORE" \
            "$address" "$email"
        return $?
    fi
    nexus_ip_acme_write_journal "$address" "$active_fingerprint" \
        "$candidate_fingerprint" prepared || return 1
    nexus_ip_acme_fault after_journal && return 95
    nexus_ip_acme_finish_publication "$address" "$email" \
        "$active_fingerprint" "$candidate_fingerprint" prepared
}

nexus_ip_acme_has_recoverable_state() {
    local expected_address="${1:-}" address="" email="" normalized_expected=""
    local journal_address="" old_fingerprint="" new_fingerprint="" phase=""
    local fingerprint=""
    nexus_ip_acme_directory_is_safe "$NEXUS_IP_ACME_STATE_ROOT" 700 || return 1
    nexus_ip_acme_exact_marker "$NEXUS_IP_ACME_OWNER_MARKER" \
        "$NEXUS_IP_ACME_OWNER_VALUE" || return 1
    nexus_ip_acme_read_config address email || return 1
    if [ -n "$expected_address" ]; then
        nexus_ip_acme_normalize_address "$expected_address" normalized_expected || return 1
        [ "$normalized_expected" = "$address" ] || return 1
    fi
    if [ -e "$NEXUS_IP_ACME_JOURNAL" ] || [ -L "$NEXUS_IP_ACME_JOURNAL" ]; then
        nexus_ip_acme_read_journal journal_address old_fingerprint \
            new_fingerprint phase || return 1
        [ "$journal_address" = "$address" ] || return 1
        fingerprint=$(nexus_ip_acme_store_fingerprint \
            "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email" 2>/dev/null) || fingerprint=none
        [ "$fingerprint" = "$new_fingerprint" ] && return 0
        fingerprint=$(nexus_ip_acme_store_fingerprint \
            "$NEXUS_IP_ACME_CANDIDATE_STORE" "$address" "$email" 2>/dev/null) || fingerprint=none
        [ "$fingerprint" = "$new_fingerprint" ]
        return $?
    fi
    if nexus_ip_acme_store_tree_is_safe "$NEXUS_IP_ACME_ACTIVE_STORE" \
        "$address" "$email"; then
        return 0
    fi
    # A safe but not-yet-issued candidate can contain a registered ACME
    # account and is intentionally recoverable on the next attempt.
    nexus_ip_acme_store_tree_is_safe "$NEXUS_IP_ACME_CANDIDATE_STORE" \
        "$address" "$email"
}

# Non-mutating ownership proof for update/restore snapshot layers.
nexus_ip_acme_owned_state_is_safe() {
    local expected_address="${1:-}" configured_address="" configured_email=""
    local normalized=""
    nexus_ip_acme_state_tree_is_owned || return 1
    nexus_ip_acme_read_config configured_address configured_email || return 1
    if [ -n "$expected_address" ]; then
        nexus_ip_acme_normalize_address "$expected_address" normalized || return 1
        [ "$normalized" = "$configured_address" ] || return 1
    fi
}

nexus_ip_acme_emit_service_unit() {
    local rr_bin="$NEXUS_IP_ACME_RR_BIN"
    [[ "$rr_bin" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    cat <<EOF
# rr-nexus-ip-acme-owned-v1
[Unit]
Description=RR Nexus short-lived IP certificate renewal
After=network-online.target nginx.service
Wants=network-online.target
ConditionPathExists=${NEXUS_IP_ACME_CONFIG}

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
ExecCondition=/bin/sh -c '[ ! -e /run/rr-vps/update-maintenance ] && [ ! -L /run/rr-vps/update-maintenance ] && [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ]'
ExecStart=${rr_bin} --nexus-ip-acme-renew
TimeoutStartSec=15min
SuccessExitStatus=75
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${NEXUS_IP_ACME_STATE_ROOT} ${NEXUS_IP_ACME_WEBROOT} $(dirname -- "$NEXUS_IP_ACME_LIVE_CERT") $(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE") $(dirname -- "$NEXUS_IP_ACME_NGINX_ENABLED") /usr/local/lib/rr-vps /etc/systemd/system/nginx.service.d
EOF
}

nexus_ip_acme_emit_timer_unit() {
    cat <<'EOF'
# rr-nexus-ip-acme-owned-v1
[Unit]
Description=Run RR Nexus IP certificate renewal every 12 hours

[Timer]
OnActiveSec=15min
OnUnitActiveSec=12h
RandomizedDelaySec=30min
Unit=rr-nexus-ip-acme.service

[Install]
WantedBy=timers.target
EOF
}

nexus_ip_acme_unit_is_owned() {
    local unit="${1:-}"
    [ -f "$unit" ] && [ ! -L "$unit" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$unit" 2>/dev/null)" = 0:0:644:1 ] || return 1
    [ "$(head -n 1 -- "$unit" 2>/dev/null)" = '# rr-nexus-ip-acme-owned-v1' ]
}

nexus_ip_acme_unit_is_current() {
    local unit="${1:-}" kind="${2:-}" expected="" actual=""
    nexus_ip_acme_unit_is_owned "$unit" || return 1
    case "$kind" in
        service) expected=$(nexus_ip_acme_emit_service_unit | sha256sum | awk '{print $1}') || return 1 ;;
        timer) expected=$(nexus_ip_acme_emit_timer_unit | sha256sum | awk '{print $1}') || return 1 ;;
        *) return 1 ;;
    esac
    actual=$(sha256sum "$unit" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual" = "$expected" ]
}

nexus_ip_acme_write_unit() {
    local unit="${1:-}" kind="${2:-}" directory="" temporary=""
    if [ -e "$unit" ] || [ -L "$unit" ]; then
        nexus_ip_acme_unit_is_owned "$unit" || return 1
    fi
    directory=$(dirname -- "$unit") || return 1
    if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
        nexus_ip_acme_parent_directory_is_safe "$directory" || return 1
        mkdir -m 755 -- "$directory" || return 1
    fi
    nexus_ip_acme_parent_directory_is_safe "$unit" || return 1
    nexus_ip_acme_directory_is_safe "$directory" 755 || return 1
    nexus_ip_acme_cleanup_atomic_files "$directory" unit || return 1
    temporary=$(mktemp "$directory/.rr-ip-acme-unit.XXXXXX") || return 1
    case "$kind" in
        service) nexus_ip_acme_emit_service_unit > "$temporary" || return 1 ;;
        timer) nexus_ip_acme_emit_timer_unit > "$temporary" || return 1 ;;
        *) unlink "$temporary" 2>/dev/null || true; return 1 ;;
    esac
    if ! chmod 644 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$unit" || ! sync -f "$directory"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || unlink "$temporary" 2>/dev/null || true
        return 1
    fi
    nexus_ip_acme_unit_is_current "$unit" "$kind"
}

nexus_ip_acme_systemctl_value() {
    local unit_name="${1:-}" property_name="${2:-}" output_name="${3:-}" result_value=""
    case "$unit_name" in rr-nexus-ip-acme.service|rr-nexus-ip-acme.timer) ;; *) return 1 ;; esac
    [[ "$property_name" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
    [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    result_value=$(systemctl show "$unit_name" -p "$property_name" --value \
        2>/dev/null) || return 1
    [[ "$result_value" != *$'\n'* ]] && [[ "$result_value" != *$'\r'* ]] || return 1
    printf -v "$output_name" '%s' "$result_value"
}

nexus_ip_acme_effective_service_is_exact() {
    local load_state="" fragment="" dropins="" type="" user="" group="" umask=""
    local success="" unit_state="" exec_start="" exec_condition="" value=""
    local condition_script="[ ! -e /run/rr-vps/update-maintenance ] && [ ! -L /run/rr-vps/update-maintenance ] && [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ]"
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service LoadState load_state || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service FragmentPath fragment || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service DropInPaths dropins || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service Type type || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service User user || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service Group group || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service UMask umask || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service SuccessExitStatus success || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service UnitFileState unit_state || return 1
    [ "$load_state" = loaded ] && [ "$fragment" = "$NEXUS_IP_ACME_SERVICE_FILE" ] && \
        [ -z "$dropins" ] && [ "$type" = oneshot ] && [ "$user:$group" = root:root ] && \
        [ "$umask" = 0077 ] && [ "$success" = 75 ] && [ "$unit_state" = static ] || return 1
    for value in ExecStartPre ExecStartPost ExecReload ExecStop ExecStopPost; do
        local hook=""
        nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service "$value" hook || return 1
        [ -z "$hook" ] || return 1
    done
    for value in Environment EnvironmentFiles PassEnvironment UnsetEnvironment; do
        local environment_value=""
        nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service "$value" \
            environment_value || return 1
        [ -z "$environment_value" ] || return 1
    done
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service ExecStart exec_start || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service ExecCondition exec_condition || return 1
    python3 - "$exec_start" "$exec_condition" "$NEXUS_IP_ACME_RR_BIN" \
        "$condition_script" <<'PY' >/dev/null 2>&1
import sys
start, condition, rr_bin, script = sys.argv[1:]
if start.count("path=") != 1 or start.count("argv[]=") != 1:
    raise SystemExit(1)
if f"path={rr_bin}" not in start or f"argv[]={rr_bin} --nexus-ip-acme-renew" not in start:
    raise SystemExit(1)
if condition.count("path=") != 1 or condition.count("argv[]=") != 1:
    raise SystemExit(1)
if "path=/bin/sh" not in condition or f"argv[]=/bin/sh -c {script}" not in condition:
    raise SystemExit(1)
PY
}

nexus_ip_acme_effective_timer_is_exact() {
    local load_state="" fragment="" dropins="" unit="" active_delay=""
    local interval="" randomized="" persistent=""
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer LoadState load_state || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer FragmentPath fragment || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer DropInPaths dropins || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer Unit unit || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer OnActiveUSec active_delay || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer OnUnitActiveUSec interval || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer RandomizedDelayUSec randomized || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer Persistent persistent || return 1
    [ "$load_state" = loaded ] && [ "$fragment" = "$NEXUS_IP_ACME_TIMER_FILE" ] && \
        [ -z "$dropins" ] && [ "$unit" = rr-nexus-ip-acme.service ] && \
        [ "$active_delay" = 15min ] && [ "$interval" = 12h ] && \
        [ "$randomized" = 30min ] && [ "$persistent" = no ]
}

nexus_ip_acme_service_is_quiescent_exact() {
    local active="" sub="" pid=""
    nexus_ip_acme_effective_service_is_exact || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service ActiveState active || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service SubState sub || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service MainPID pid || return 1
    [ "$active:$sub:$pid" = inactive:dead:0 ]
}

nexus_ip_acme_timer_is_armed_exact() {
    local unit_state="" active="" sub=""
    nexus_ip_acme_effective_timer_is_exact || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer UnitFileState unit_state || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer ActiveState active || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer SubState sub || return 1
    [ "$unit_state:$active:$sub" = enabled:active:waiting ]
}

nexus_ip_acme_units_are_disarmed_exact() {
    nexus_ip_acme_service_is_quiescent_exact || return 1
    nexus_ip_acme_timer_is_disarmed_exact
}

nexus_ip_acme_timer_is_disarmed_exact() {
    local unit_state="" active="" sub=""
    nexus_ip_acme_effective_timer_is_exact || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer UnitFileState unit_state || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer ActiveState active || return 1
    nexus_ip_acme_systemctl_value rr-nexus-ip-acme.timer SubState sub || return 1
    [ "$unit_state:$active:$sub" = disabled:inactive:dead ]
}

nexus_ip_acme_unit_is_absent_exact() {
    local name="${1:-}" unit_file_state="" unit_path="" status=0
    local load_state="" fragment="" dropins="" active="" sub=""
    case "$name" in
        rr-nexus-ip-acme.service) unit_path="$NEXUS_IP_ACME_SERVICE_FILE" ;;
        rr-nexus-ip-acme.timer) unit_path="$NEXUS_IP_ACME_TIMER_FILE" ;;
        *) return 1 ;;
    esac
    nexus_ip_acme_nearest_parent_chain_is_safe "$unit_path" || return 1
    nexus_ip_acme_systemctl_value "$name" LoadState load_state || return 1
    nexus_ip_acme_systemctl_value "$name" FragmentPath fragment || return 1
    nexus_ip_acme_systemctl_value "$name" DropInPaths dropins || return 1
    nexus_ip_acme_systemctl_value "$name" ActiveState active || return 1
    nexus_ip_acme_systemctl_value "$name" SubState sub || return 1
    [ "$load_state" = not-found ] && [ -z "$fragment" ] && [ -z "$dropins" ] && \
        [ "$active:$sub" = inactive:dead ] || return 1
    if unit_file_state=$(LC_ALL=C systemctl is-enabled "$name" 2>/dev/null); then
        return 1
    else
        status=$?
    fi
    [ "$status" -ne 0 ] && [ "$unit_file_state" = not-found ]
}

nexus_ip_acme_units_are_absent_exact() {
    nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.timer && \
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.service
}

nexus_ip_acme_unit_stale_removed_is_safe() {
    local name="${1:-}" path=""
    case "$name" in
        rr-nexus-ip-acme.service) path="$NEXUS_IP_ACME_SERVICE_FILE" ;;
        rr-nexus-ip-acme.timer) path="$NEXUS_IP_ACME_TIMER_FILE" ;;
        *) return 1 ;;
    esac
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    nexus_ip_acme_nearest_parent_chain_is_safe "$path" || return 1
    # Recover only the precise crash window after an exact, disarmed fragment
    # was unlinked but before daemon-reload forgot its compiled identity.
    if [ "$name" = rr-nexus-ip-acme.service ]; then
        nexus_ip_acme_service_is_quiescent_exact
    else
        nexus_ip_acme_timer_is_disarmed_exact
    fi
}

nexus_ip_acme_wait_service_quiescent() {
    local attempt=0 state=""
    while [ "$attempt" -lt 100 ]; do
        nexus_ip_acme_systemctl_value rr-nexus-ip-acme.service ActiveState state || return 1
        case "$state" in
            inactive) break ;;
            failed)
                systemctl reset-failed rr-nexus-ip-acme.service \
                    >/dev/null 2>&1 || return 1
                ;;
            activating|active|deactivating) sleep 0.1 ;;
            *) return 1 ;;
        esac
        attempt=$((attempt + 1))
    done
    [ "$attempt" -lt 100 ] && nexus_ip_acme_service_is_quiescent_exact
}

nexus_ip_acme_install_units() {
    nexus_ip_acme_write_unit "$NEXUS_IP_ACME_SERVICE_FILE" service || return 1
    nexus_ip_acme_write_unit "$NEXUS_IP_ACME_TIMER_FILE" timer || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    # Prove the compiled static service identity and absence of drop-ins before
    # enabling the timer.  The service itself deliberately has no [Install].
    nexus_ip_acme_effective_service_is_exact || return 1
    nexus_ip_acme_effective_timer_is_exact || return 1
    systemctl enable --now rr-nexus-ip-acme.timer >/dev/null 2>&1 || return 1
    nexus_ip_acme_wait_service_quiescent || return 1
    nexus_ip_acme_timer_is_armed_exact
}

nexus_ip_acme_with_writer_lock() {
    local callback="${1:-}"
    shift
    declare -F "$callback" >/dev/null 2>&1 || return 76
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] || \
       [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ]; then
        nexus_ip_acme_update_lock_context_is_trusted || return 76
        "$callback" "$@"
        return $?
    fi
    declare -F rr_run_with_update_locks >/dev/null 2>&1 || return 76
    rr_run_with_update_locks isolated 300 "$callback" "$@"
}

nexus_ip_acme_install_locked() {
    local address="${1:-}" email="${2:-}" configured_address="" configured_email="" normalized=""
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    address="$normalized"
    nexus_ip_acme_email_is_valid "$email" || return 1
    [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ] || return 75
    nexus_ip_acme_prepare_state_root || return 1
    if [ -e "$NEXUS_IP_ACME_CONFIG" ] || [ -L "$NEXUS_IP_ACME_CONFIG" ]; then
        nexus_ip_acme_read_config configured_address configured_email || return 1
        [ "$configured_address" = "$address" ] && [ "$configured_email" = "$email" ] || return 1
    else
        nexus_ip_acme_write_config "$address" "$email" || return 1
    fi
    nexus_ip_acme_prepare_webroot || return 1
    nexus_ip_acme_install_lego || return 1
    # Make the recovered publication's reload path valid before consuming a
    # durable journal.  This validates configuration without starting Nginx;
    # the publication itself proves activation (or the fresh renewal below
    # starts and probes HTTP-01 before contacting the CA).
    nexus_ip_acme_install_nginx_http_site "$address" validate-only || return 1
    # Recovery is always first; a prior successful CA response in candidate or
    # journal is committed without another lego invocation.
    nexus_ip_acme_recover_locked "$address" || return $?
    if [ "$NEXUS_IP_ACME_RECOVERED_PUBLICATION" = 0 ]; then
        nexus_ip_acme_renew_locked || return $?
    fi
    nexus_ip_acme_install_units
}

nexus_ip_acme_install() {
    nexus_ip_acme_with_writer_lock nexus_ip_acme_install_locked "$@"
}

nexus_ip_acme_rearm_locked() {
    local expected_address="${1:-}" address="" email="" normalized=""
    local store_fingerprint="" live_fingerprint="" activation_mode=active
    local restore_active="${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}"
    if [ -e "$restore_active" ] || [ -L "$restore_active" ]; then
        nexus_ip_acme_trusted_restore_context || return 75
        activation_mode=validate-only
    fi
    nexus_ip_acme_prepare_state_root || return 1
    nexus_ip_acme_read_config address email || return 1
    if [ -n "$expected_address" ]; then
        nexus_ip_acme_normalize_address "$expected_address" normalized || return 1
        [ "$normalized" = "$address" ] || return 1
    fi
    nexus_ip_acme_prepare_webroot || return 1
    nexus_ip_acme_lego_marker_is_current || return 1
    nexus_ip_acme_install_nginx_http_site "$address" "$activation_mode" || return 1
    # recover_locked only consumes durable local evidence; it never invokes
    # lego or creates a new ACME order.
    if [ "$activation_mode" = validate-only ]; then
        NEXUS_IP_ACME_DEFER_NGINX_ACTIVATION=1 \
            nexus_ip_acme_recover_locked "$address" || return $?
    else
        nexus_ip_acme_recover_locked "$address" || return $?
    fi
    store_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email") || return 1
    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address") || return 1
    [ "$store_fingerprint" = "$live_fingerprint" ] || return 1
    nexus_ip_acme_ensure_gate || return 1
    nexus_ip_acme_install_units
}

nexus_ip_acme_rearm() {
    local restore_active="${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}"
    # Check before acquiring a lock: otherwise ambient restore markers could
    # be combined with the wrapper's newly-created delegation flags.
    if [ -e "$restore_active" ] || [ -L "$restore_active" ]; then
        nexus_ip_acme_trusted_restore_context || return 75
    fi
    nexus_ip_acme_with_writer_lock nexus_ip_acme_rearm_locked "$@"
}

nexus_ip_acme_renew() {
    nexus_ip_acme_with_writer_lock nexus_ip_acme_renew_locked
}

nexus_ip_acme_recover() {
    nexus_ip_acme_with_writer_lock nexus_ip_acme_recover_locked "$@"
}

nexus_ip_acme_service_entry() {
    local maintenance="${RR_UPDATE_MAINTENANCE_FILE:-/run/rr-vps/update-maintenance}"
    [ "$(id -u)" -eq 0 ] || return 1
    # A timer activation may race while install/update recovery still owns the
    # update lock.  Exit before lock acquisition so systemd can quiesce the
    # oneshot and the transaction can safely re-arm the timer.
    [ ! -e "$maintenance" ] && [ ! -L "$maintenance" ] || return 75
    nexus_ip_acme_renew
}

nexus_ip_acme_no_recovery_temps_readonly() {
    local cert_dir="" lego_dir="" http_dir="" service_dir="" timer_dir=""
    cert_dir=$(dirname -- "$NEXUS_IP_ACME_LIVE_CERT") || return 1
    [ "$(dirname -- "$NEXUS_IP_ACME_LIVE_KEY")" = "$cert_dir" ] && \
        [ "$(dirname -- "$NEXUS_IP_ACME_PENDING")" = "$cert_dir" ] || return 1
    lego_dir=$(dirname -- "$NEXUS_IP_ACME_LEGO_BIN") || return 1
    [ "$(dirname -- "$NEXUS_IP_ACME_LEGO_MARKER")" = "$lego_dir" ] || return 1
    http_dir=$(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE") || return 1
    service_dir=$(dirname -- "$NEXUS_IP_ACME_SERVICE_FILE") || return 1
    timer_dir=$(dirname -- "$NEXUS_IP_ACME_TIMER_FILE") || return 1
    python3 - "$NEXUS_IP_ACME_STATE_ROOT" "$NEXUS_IP_ACME_WEBROOT" \
        "$cert_dir" "$lego_dir" "$http_dir" "$service_dir" "$timer_dir" <<'PY' >/dev/null 2>&1
import os
import re
import stat
import sys

state, webroot, certdir, legodir, httpdir, servicedir, timerdir = sys.argv[1:]
for path in (state + ".new", webroot + ".new"):
    if os.path.lexists(path):
        raise SystemExit(1)
checks = (
    (state, (r"\.rr-ip-acme\.[A-Za-z0-9]{6}", r"candidate\.new\.[1-9][0-9]*")),
    (webroot, (r"\.rr-ip-acme\.[A-Za-z0-9]{6}",)),
    (os.path.join(webroot, ".well-known", "acme-challenge"),
        (r"\.rr-ip-acme\.[A-Za-z0-9]{6}",)),
    (certdir, (r"(?:\.ip-acme\.(?:crt|key)|\.ip-cert-pending)\.[A-Za-z0-9]{6}",)),
    (legodir, (r"\.rr-ip-acme\.[A-Za-z0-9]{6}",)),
    (httpdir, (r"\.rr-ip-acme-http\.[A-Za-z0-9]{6}",)),
    (servicedir, (r"\.rr-ip-acme-unit\.[A-Za-z0-9]{6}",)),
    (timerdir, (r"\.rr-ip-acme-unit\.[A-Za-z0-9]{6}",)),
)
for directory, patterns in checks:
    if not os.path.isdir(directory) or os.path.islink(directory) or os.path.realpath(directory) != os.path.abspath(directory):
        raise SystemExit(1)
    for name in os.listdir(directory):
        if any(re.fullmatch(pattern, name) for pattern in patterns):
            raise SystemExit(1)
PY
}

nexus_ip_acme_runtime_is_ready() {
    local expected_address="${1:-}" address="" email="" store_fingerprint="" live_fingerprint="" normalized=""
    local path=""
    nexus_ip_acme_normalize_address "$expected_address" normalized || return 1
    expected_address="$normalized"
    for path in "$NEXUS_IP_ACME_STATE_ROOT" "$NEXUS_IP_ACME_WEBROOT" \
        "$NEXUS_IP_ACME_LEGO_BIN" "$NEXUS_IP_ACME_LEGO_MARKER" \
        "$NEXUS_IP_ACME_LIVE_CERT" "$NEXUS_IP_ACME_LIVE_KEY" \
        "$NEXUS_IP_ACME_NGINX_AVAILABLE" "$NEXUS_IP_ACME_NGINX_ENABLED" \
        "$NEXUS_IP_ACME_SERVICE_FILE" "$NEXUS_IP_ACME_TIMER_FILE" \
        "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}"; do
        nexus_ip_acme_nearest_parent_chain_is_safe "$path" || return 1
    done
    nexus_ip_acme_directory_is_safe "$NEXUS_IP_ACME_STATE_ROOT" 700 || return 1
    nexus_ip_acme_path_is_mountpoint "$NEXUS_IP_ACME_STATE_ROOT" && return 1
    nexus_ip_acme_exact_marker "$NEXUS_IP_ACME_OWNER_MARKER" \
        "$NEXUS_IP_ACME_OWNER_VALUE" || return 1
    nexus_ip_acme_read_config address email || return 1
    [ "$address" = "$expected_address" ] || return 1
    nexus_ip_acme_webroot_is_safe || return 1
    nexus_ip_acme_nginx_http_site_is_current "$address" || return 1
    nexus_ip_acme_lego_marker_is_current || return 1
    [ ! -e "$NEXUS_IP_ACME_JOURNAL" ] && [ ! -L "$NEXUS_IP_ACME_JOURNAL" ] || return 1
    [ ! -e "$NEXUS_IP_ACME_CANDIDATE_STORE" ] && [ ! -L "$NEXUS_IP_ACME_CANDIDATE_STORE" ] || return 1
    store_fingerprint=$(nexus_ip_acme_store_fingerprint \
        "$NEXUS_IP_ACME_ACTIVE_STORE" "$address" "$email") || return 1
    live_fingerprint=$(nexus_ip_acme_live_fingerprint "$address") || return 1
    [ "$store_fingerprint" = "$live_fingerprint" ] || return 1
    nexus_ip_acme_state_tree_is_owned || return 1
    nexus_ip_acme_no_recovery_temps_readonly || return 1
    nexus_ip_acme_gate_runtime_is_ready_readonly || return 1
    nexus_ip_acme_unit_is_current "$NEXUS_IP_ACME_SERVICE_FILE" service || return 1
    nexus_ip_acme_unit_is_current "$NEXUS_IP_ACME_TIMER_FILE" timer || return 1
    nexus_ip_acme_service_is_quiescent_exact || return 1
    nexus_ip_acme_timer_is_armed_exact
}

nexus_ip_acme_disarm_locked() {
    local service_present=false timer_present=false
    nexus_ip_acme_nearest_parent_chain_is_safe "$NEXUS_IP_ACME_SERVICE_FILE" || return 2
    nexus_ip_acme_nearest_parent_chain_is_safe "$NEXUS_IP_ACME_TIMER_FILE" || return 2
    if [ -e "$NEXUS_IP_ACME_SERVICE_FILE" ] || [ -L "$NEXUS_IP_ACME_SERVICE_FILE" ]; then
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_SERVICE_FILE" || return 2
        nexus_ip_acme_unit_is_current "$NEXUS_IP_ACME_SERVICE_FILE" service || return 2
        service_present=true
    fi
    if [ -e "$NEXUS_IP_ACME_TIMER_FILE" ] || [ -L "$NEXUS_IP_ACME_TIMER_FILE" ]; then
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_TIMER_FILE" || return 2
        nexus_ip_acme_unit_is_current "$NEXUS_IP_ACME_TIMER_FILE" timer || return 2
        timer_present=true
    fi
    if [ "$service_present" = true ]; then
        nexus_ip_acme_effective_service_is_exact || return 2
    else
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.service || \
            nexus_ip_acme_unit_stale_removed_is_safe rr-nexus-ip-acme.service || return 2
    fi
    if [ "$timer_present" = true ]; then
        nexus_ip_acme_effective_timer_is_exact || return 2
    else
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.timer || \
            nexus_ip_acme_unit_stale_removed_is_safe rr-nexus-ip-acme.timer || return 2
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 2
    nexus_ip_acme_nearest_parent_chain_is_safe "$NEXUS_IP_ACME_SERVICE_FILE" || return 2
    nexus_ip_acme_nearest_parent_chain_is_safe "$NEXUS_IP_ACME_TIMER_FILE" || return 2
    if [ "$service_present" = true ]; then
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_SERVICE_FILE" || return 2
        nexus_ip_acme_unit_is_current "$NEXUS_IP_ACME_SERVICE_FILE" service || return 2
        nexus_ip_acme_effective_service_is_exact || return 2
    else
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.service || return 2
    fi
    if [ "$timer_present" = true ]; then
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_TIMER_FILE" || return 2
        nexus_ip_acme_unit_is_current "$NEXUS_IP_ACME_TIMER_FILE" timer || return 2
        nexus_ip_acme_effective_timer_is_exact || return 2
    else
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.timer || return 2
    fi
    # Stop the trigger first, then wait for any in-flight oneshot to terminate.
    if [ "$timer_present" = true ]; then
        systemctl disable --now rr-nexus-ip-acme.timer >/dev/null 2>&1 || true
    fi
    if [ "$service_present" = true ]; then
        systemctl stop rr-nexus-ip-acme.service >/dev/null 2>&1 || true
        systemctl disable rr-nexus-ip-acme.service >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 2
    if [ "$timer_present" = true ]; then
        nexus_ip_acme_timer_is_disarmed_exact || return 2
    else
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.timer || return 2
    fi
    if [ "$service_present" = true ]; then
        nexus_ip_acme_service_is_quiescent_exact || return 2
    else
        nexus_ip_acme_unit_is_absent_exact rr-nexus-ip-acme.service || return 2
    fi
    # State, journal, candidate, account and webroot deliberately remain.  A
    # failed surrounding Nexus install can later prove and resume them without
    # another CA order, while no background signer is left armed.
    return 0
}

nexus_ip_acme_disarm() {
    nexus_ip_acme_with_writer_lock nexus_ip_acme_disarm_locked
}

nexus_ip_acme_state_tree_is_owned() {
    local address="" email="" entry="" base=""
    nexus_ip_acme_directory_is_safe "$NEXUS_IP_ACME_STATE_ROOT" 700 || return 1
    nexus_ip_acme_exact_marker "$NEXUS_IP_ACME_OWNER_MARKER" \
        "$NEXUS_IP_ACME_OWNER_VALUE" || return 1
    nexus_ip_acme_read_config address email || return 1
    while IFS= read -r -d '' entry; do
        base=${entry##*/}
        case "$base" in
            .rr-nexus-ip-acme-owner|config.json) ;;
            publication.json)
                local journal_address="" old_fingerprint="" new_fingerprint="" phase=""
                nexus_ip_acme_read_journal journal_address old_fingerprint \
                    new_fingerprint phase || return 1
                [ "$journal_address" = "$address" ] || return 1
                ;;
            active|candidate)
                nexus_ip_acme_store_tree_is_safe "$entry" "$address" "$email" || return 1
                ;;
            candidate.new.*)
                [[ "$base" =~ ^candidate\.new\.[1-9][0-9]*$ ]] || return 1
                nexus_ip_acme_candidate_stage_is_safe "$entry" || return 1
                ;;
            .rr-ip-acme.*)
                [[ "$base" =~ ^\.rr-ip-acme\.[A-Za-z0-9]{6}$ ]] || return 1
                [ -f "$entry" ] && [ ! -L "$entry" ] && \
                    [ "$(stat -c '%u:%g:%a:%h' -- "$entry" 2>/dev/null)" = 0:0:600:1 ] || \
                    return 1
                ;;
            *) return 1 ;;
        esac
    done < <(find "$NEXUS_IP_ACME_STATE_ROOT" -mindepth 1 -maxdepth 1 -print0)
}

nexus_ip_acme_remove_owned_units() {
    local unit="" kind="" service_dir="" timer_dir=""
    for unit in "$NEXUS_IP_ACME_TIMER_FILE" "$NEXUS_IP_ACME_SERVICE_FILE"; do
        if [ -e "$unit" ] || [ -L "$unit" ]; then
            nexus_ip_acme_parent_directory_is_safe "$unit" || return 2
            if [ "$unit" = "$NEXUS_IP_ACME_TIMER_FILE" ]; then kind=timer; else kind=service; fi
            nexus_ip_acme_unit_is_current "$unit" "$kind" || return 2
        fi
    done
    service_dir=$(dirname -- "$NEXUS_IP_ACME_SERVICE_FILE") || return 2
    timer_dir=$(dirname -- "$NEXUS_IP_ACME_TIMER_FILE") || return 2
    [ -d "$service_dir" ] && [ ! -L "$service_dir" ] || return 2
    [ -d "$timer_dir" ] && [ ! -L "$timer_dir" ] || return 2
    nexus_ip_acme_cleanup_atomic_files "$service_dir" unit || return 2
    if [ "$timer_dir" != "$service_dir" ]; then
        nexus_ip_acme_cleanup_atomic_files "$timer_dir" unit || return 2
    fi
    for unit in "$NEXUS_IP_ACME_TIMER_FILE" "$NEXUS_IP_ACME_SERVICE_FILE"; do
        if [ -e "$unit" ] || [ -L "$unit" ]; then
            nexus_ip_acme_parent_directory_is_safe "$unit" || return 2
            if [ "$unit" = "$NEXUS_IP_ACME_TIMER_FILE" ]; then kind=timer; else kind=service; fi
            nexus_ip_acme_unit_is_current "$unit" "$kind" || return 2
            unlink "$unit" 2>/dev/null || return 2
            sync -f "$(dirname -- "$unit")" || return 2
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || return 2
    nexus_ip_acme_units_are_absent_exact || return 2
}

nexus_ip_acme_remove_owned_webroot() {
    local root="$NEXUS_IP_ACME_WEBROOT"
    [ -e "$root" ] || [ -L "$root" ] || return 0
    nexus_ip_acme_parent_directory_is_safe "$root" || return 2
    nexus_ip_acme_webroot_is_safe || return 2
    nexus_ip_acme_path_is_mountpoint "$root" && return 2
    nexus_ip_acme_parent_directory_is_safe "$root" || return 2
    nexus_ip_acme_webroot_is_safe || return 2
    rm -rf -- "$root" || return 2
    sync -f "$(dirname -- "$root")" || return 2
    [ ! -e "$root" ] && [ ! -L "$root" ]
}

nexus_ip_acme_remove_owned_lego() {
    local directory="" architecture=""
    if [ ! -e "$NEXUS_IP_ACME_LEGO_BIN" ] && [ ! -L "$NEXUS_IP_ACME_LEGO_BIN" ] && \
       [ ! -e "$NEXUS_IP_ACME_LEGO_MARKER" ] && [ ! -L "$NEXUS_IP_ACME_LEGO_MARKER" ]; then
        return 0
    fi
    nexus_ip_acme_lego_current_architecture architecture || return 2
    if [ -e "$NEXUS_IP_ACME_LEGO_BIN" ] || [ -L "$NEXUS_IP_ACME_LEGO_BIN" ]; then
        nexus_ip_acme_lego_binary_is_official \
            "$NEXUS_IP_ACME_LEGO_BIN" "$architecture" || return 2
    fi
    if [ -e "$NEXUS_IP_ACME_LEGO_MARKER" ] || [ -L "$NEXUS_IP_ACME_LEGO_MARKER" ]; then
        nexus_ip_acme_lego_marker_record_is_current \
            "$NEXUS_IP_ACME_LEGO_MARKER" "$architecture" || return 2
    fi
    directory=$(dirname -- "$NEXUS_IP_ACME_LEGO_BIN") || return 2
    [ "$(dirname -- "$NEXUS_IP_ACME_LEGO_MARKER")" = "$directory" ] || return 2
    nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_LEGO_BIN" || return 2
    nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_LEGO_MARKER" || return 2
    nexus_ip_acme_cleanup_atomic_files "$directory" atomic || return 2
    if [ -e "$NEXUS_IP_ACME_LEGO_BIN" ] || [ -L "$NEXUS_IP_ACME_LEGO_BIN" ]; then
        nexus_ip_acme_lego_binary_is_official \
            "$NEXUS_IP_ACME_LEGO_BIN" "$architecture" || return 2
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_LEGO_BIN" || return 2
        unlink "$NEXUS_IP_ACME_LEGO_BIN" 2>/dev/null || return 2
    fi
    if [ -e "$NEXUS_IP_ACME_LEGO_MARKER" ] || [ -L "$NEXUS_IP_ACME_LEGO_MARKER" ]; then
        nexus_ip_acme_lego_marker_record_is_current \
            "$NEXUS_IP_ACME_LEGO_MARKER" "$architecture" || return 2
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_LEGO_MARKER" || return 2
        unlink "$NEXUS_IP_ACME_LEGO_MARKER" 2>/dev/null || return 2
    fi
    sync -f "$directory" || return 2
    [ ! -e "$NEXUS_IP_ACME_LEGO_BIN" ] && [ ! -L "$NEXUS_IP_ACME_LEGO_BIN" ] && \
        [ ! -e "$NEXUS_IP_ACME_LEGO_MARKER" ] && [ ! -L "$NEXUS_IP_ACME_LEGO_MARKER" ]
}

nexus_ip_acme_uninstall_locked() {
    local status=0 address="" email="" state_stage="${NEXUS_IP_ACME_STATE_ROOT}.new"
    local webroot_stage="${NEXUS_IP_ACME_WEBROOT}.new" cert_dir="" lego_dir=""
    local http_dir="" service_dir="" timer_dir=""
    if [ -e "$NEXUS_IP_ACME_CONFIG" ] || [ -L "$NEXUS_IP_ACME_CONFIG" ]; then
        nexus_ip_acme_read_config address email || return 2
    fi
    # Complete the ownership preflight before deleting the first artifact, so
    # a foreign collision cannot turn uninstall into a partial cleanup.
    if [ -e "$NEXUS_IP_ACME_STATE_ROOT" ] || [ -L "$NEXUS_IP_ACME_STATE_ROOT" ]; then
        nexus_ip_acme_state_tree_is_owned || return 2
    fi
    if [ -e "$state_stage" ] || [ -L "$state_stage" ]; then
        nexus_ip_acme_parent_directory_is_safe "$state_stage" || return 2
        nexus_ip_acme_creation_stage_is_safe "$state_stage" state || return 2
    fi
    if [ -e "$NEXUS_IP_ACME_WEBROOT" ] || [ -L "$NEXUS_IP_ACME_WEBROOT" ]; then
        nexus_ip_acme_webroot_is_safe || return 2
    fi
    if [ -e "$webroot_stage" ] || [ -L "$webroot_stage" ]; then
        nexus_ip_acme_parent_directory_is_safe "$webroot_stage" || return 2
        nexus_ip_acme_creation_stage_is_safe "$webroot_stage" webroot || return 2
    fi
    if [ -e "$NEXUS_IP_ACME_LEGO_BIN" ] || [ -L "$NEXUS_IP_ACME_LEGO_BIN" ] || \
       [ -e "$NEXUS_IP_ACME_LEGO_MARKER" ] || [ -L "$NEXUS_IP_ACME_LEGO_MARKER" ]; then
        local _nexus_lego_architecture=""
        nexus_ip_acme_lego_current_architecture _nexus_lego_architecture || return 2
        if [ -e "$NEXUS_IP_ACME_LEGO_BIN" ] || [ -L "$NEXUS_IP_ACME_LEGO_BIN" ]; then
            nexus_ip_acme_lego_binary_is_official "$NEXUS_IP_ACME_LEGO_BIN" \
                "$_nexus_lego_architecture" || return 2
        fi
        if [ -e "$NEXUS_IP_ACME_LEGO_MARKER" ] || [ -L "$NEXUS_IP_ACME_LEGO_MARKER" ]; then
            nexus_ip_acme_lego_marker_record_is_current "$NEXUS_IP_ACME_LEGO_MARKER" \
                "$_nexus_lego_architecture" || return 2
        fi
    fi
    if [ -n "$address" ]; then
        nexus_ip_acme_nginx_http_site_removal_is_safe "$address" || return 2
    fi
    cert_dir=$(dirname -- "$NEXUS_IP_ACME_LIVE_CERT") || return 2
    [ "$(dirname -- "$NEXUS_IP_ACME_LIVE_KEY")" = "$cert_dir" ] && \
        [ "$(dirname -- "$NEXUS_IP_ACME_PENDING")" = "$cert_dir" ] || return 2
    if [ -d "$cert_dir" ] && [ ! -L "$cert_dir" ]; then
        nexus_ip_acme_cleanup_live_temps validate-only || return 2
    elif [ -e "$cert_dir" ] || [ -L "$cert_dir" ]; then
        return 2
    fi
    lego_dir=$(dirname -- "$NEXUS_IP_ACME_LEGO_BIN") || return 2
    http_dir=$(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE") || return 2
    service_dir=$(dirname -- "$NEXUS_IP_ACME_SERVICE_FILE") || return 2
    timer_dir=$(dirname -- "$NEXUS_IP_ACME_TIMER_FILE") || return 2
    if [ -d "$lego_dir" ] && [ ! -L "$lego_dir" ]; then
        nexus_ip_acme_cleanup_atomic_files "$lego_dir" atomic validate-only || return 2
    elif [ -e "$lego_dir" ] || [ -L "$lego_dir" ]; then return 2; fi
    if [ -d "$http_dir" ] && [ ! -L "$http_dir" ]; then
        nexus_ip_acme_cleanup_atomic_files "$http_dir" http validate-only || return 2
    elif [ -e "$http_dir" ] || [ -L "$http_dir" ]; then return 2; fi
    if [ -d "$service_dir" ] && [ ! -L "$service_dir" ]; then
        nexus_ip_acme_cleanup_atomic_files "$service_dir" unit validate-only || return 2
    elif [ -e "$service_dir" ] || [ -L "$service_dir" ]; then return 2; fi
    if [ "$timer_dir" != "$service_dir" ]; then
        if [ -d "$timer_dir" ] && [ ! -L "$timer_dir" ]; then
            nexus_ip_acme_cleanup_atomic_files "$timer_dir" unit validate-only || return 2
        elif [ -e "$timer_dir" ] || [ -L "$timer_dir" ]; then return 2; fi
    fi
    nexus_ip_acme_disarm_locked || status=$?
    [ "$status" -lt 2 ] || return "$status"
    nexus_ip_acme_remove_owned_units || return $?
    if [ -d "$cert_dir" ] && [ ! -L "$cert_dir" ]; then
        nexus_ip_acme_cleanup_live_temps || return 2
    fi
    if [ -d "$http_dir" ] && [ ! -L "$http_dir" ]; then
        nexus_ip_acme_cleanup_atomic_files "$http_dir" http || return 2
    fi
    if [ -n "$address" ]; then
        nexus_ip_acme_remove_nginx_http_site "$address" || return $?
    elif [ -e "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || \
         [ -L "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] || \
         [ -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] || \
         [ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ]; then
        return 2
    fi
    nexus_ip_acme_remove_creation_stage "$webroot_stage" webroot || return 2
    nexus_ip_acme_remove_owned_webroot || return $?
    if [ -d "$lego_dir" ] && [ ! -L "$lego_dir" ]; then
        nexus_ip_acme_cleanup_atomic_files "$lego_dir" atomic || return 2
    fi
    nexus_ip_acme_remove_owned_lego || return $?
    if [ -e "$NEXUS_IP_ACME_STATE_ROOT" ] || [ -L "$NEXUS_IP_ACME_STATE_ROOT" ]; then
        nexus_ip_acme_cleanup_atomic_files "$NEXUS_IP_ACME_STATE_ROOT" atomic || return 2
        nexus_ip_acme_cleanup_candidate_stages || return 2
        nexus_ip_acme_state_tree_is_owned || return 2
        nexus_ip_acme_path_is_mountpoint "$NEXUS_IP_ACME_STATE_ROOT" && return 2
        nexus_ip_acme_parent_directory_is_safe "$NEXUS_IP_ACME_STATE_ROOT" || return 2
        rm -rf -- "$NEXUS_IP_ACME_STATE_ROOT" || return 2
        sync -f "$(dirname -- "$NEXUS_IP_ACME_STATE_ROOT")" || return 2
    fi
    nexus_ip_acme_remove_creation_stage "$state_stage" state || return 2
    [ ! -e "$NEXUS_IP_ACME_STATE_ROOT" ] && [ ! -L "$NEXUS_IP_ACME_STATE_ROOT" ] && \
        [ ! -e "$state_stage" ] && [ ! -L "$state_stage" ] && \
        [ ! -e "$NEXUS_IP_ACME_WEBROOT" ] && [ ! -L "$NEXUS_IP_ACME_WEBROOT" ] && \
        [ ! -e "$webroot_stage" ] && [ ! -L "$webroot_stage" ] && \
        [ ! -e "$NEXUS_IP_ACME_LEGO_BIN" ] && [ ! -L "$NEXUS_IP_ACME_LEGO_BIN" ] && \
        [ ! -e "$NEXUS_IP_ACME_LEGO_MARKER" ] && [ ! -L "$NEXUS_IP_ACME_LEGO_MARKER" ] && \
        [ ! -e "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] && [ ! -L "$NEXUS_IP_ACME_NGINX_AVAILABLE" ] && \
        [ ! -e "$NEXUS_IP_ACME_NGINX_ENABLED" ] && [ ! -L "$NEXUS_IP_ACME_NGINX_ENABLED" ] && \
        nexus_ip_acme_units_are_absent_exact || return 2
    return "$status"
}

nexus_ip_acme_uninstall() {
    nexus_ip_acme_with_writer_lock nexus_ip_acme_uninstall_locked
}
