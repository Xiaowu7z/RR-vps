# shellcheck shell=bash
# 模块化更新、迁移与健康检查。

rr_download_file() {
    local source_url="$1"
    local target_file="$2"
    local timeout_seconds="${3:-10}"
    local cache_buster=""
    local relative_path=""
    local official_only="${4:-false}"

    cache_buster=$(date +%s)
    case "$source_url" in
        "${RR_RAW_BASE}/"*) relative_path="${source_url#"${RR_RAW_BASE}/"}" ;;
    esac

    # 用户显式配置的 GitHub 代理优先；兼容 https://ghproxy/... 这类
    # “代理前缀 + 原始 URL”形式。失败后继续走官方源和内置回退。
    if [ "$official_only" != true ] && [ -n "${RR_GITHUB_MIRROR:-}" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 120 \
                "${RR_GITHUB_MIRROR}${source_url}" -o "$target_file" 2>/dev/null && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout="$timeout_seconds" --tries=2 \
                -O "$target_file" "${RR_GITHUB_MIRROR}${source_url}" 2>/dev/null && return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 120 \
            -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
            "${source_url}?t=${cache_buster}" -o "$target_file" 2>/dev/null && return 0
        if [ "${RR_UPDATE_CHANNEL:-stable}" = beta ] && [ -n "$relative_path" ]; then
            # GitHub 官方 Contents API 可绕过 raw.githubusercontent.com 的
            # DNS/路由故障；raw media type 让响应直接成为文件内容。
            curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 120 \
                -H "Accept: application/vnd.github.raw+json" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_BRANCH}&t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
            curl -4 -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 120 \
                "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout_seconds" --tries=3 \
            -O "$target_file" "${source_url}?t=${cache_buster}" && return 0
        if [ "${RR_UPDATE_CHANNEL:-stable}" = beta ] && [ -n "$relative_path" ]; then
            wget -q --timeout="$timeout_seconds" --tries=2 \
                --header="Accept: application/vnd.github.raw+json" \
                -O "$target_file" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_BRANCH}&t=${cache_buster}" && return 0
            wget -4 -q --timeout="$timeout_seconds" --tries=2 \
                -O "$target_file" "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" && return 0
        fi
    else
        return 1
    fi
    return 1
}

rr_manifest_is_valid() {
    local manifest_file="$1"
    [ -s "$manifest_file" ] || return 1
    awk '
        NF != 2 { exit 1 }
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        seen[$2]++ { exit 1 }
        $2 == "rr" { launcher = 1; next }
        $2 == "scripts/naive-cert-hook.sh" { naive_hook = 1; next }
        $2 == "scripts/update-recover.sh" { recovery = 1; next }
        $2 == "scripts/update-external-state.py" { external_state = 1; next }
        $2 ~ /^modules\/[0-9][0-9A-Za-z_-]*\.sh$/ { modules++; next }
        $2 == "nexus/rr_nexus.py" { nexus_app = 1; next }
        $2 ~ /^nexus\/[A-Za-z0-9._-]+\.py$/ { nexus_python++; next }
        $2 ~ /^nexus\/rr_nexus_lib\/[A-Za-z0-9._-]+\.py$/ { nexus_python++; next }
        $2 ~ /^nexus\/static\/[A-Za-z0-9._-]+\.(html|css|js)$/ { nexus_assets++; next }
        { exit 1 }
        END {
            if (!launcher || !naive_hook || !recovery || !external_state || modules < 2) exit 1
            if (!nexus_app || nexus_assets < 3) exit 1
        }
    ' "$manifest_file"
}

rr_bundle_archive_is_safe() {
    local archive_file="$1"
    [ -s "$archive_file" ] || return 1
    [ "$(stat -c %s "$archive_file" 2>/dev/null || echo 0)" -le 52428800 ] || return 1
    # The mirror is only a transport and may be attacker-controlled.  Inspect
    # the raw tar stream before extraction so links, PAX/GNU extensions,
    # duplicate members and small compressed bombs cannot reach tar(1).
    python3 - "$archive_file" <<'PYEOF'
import gzip
import re
import sys
import tarfile

archive = sys.argv[1]
max_members = 512
max_member_size = 16 * 1024 * 1024
max_total_size = 64 * 1024 * 1024
max_padding = 1024 * 1024
allowed = re.compile(
    r"^rr-bundle/(?:manifest\.sha256|rr|"
    r"scripts/(?:naive-cert-hook|update-recover)\.sh|"
    r"scripts/update-external-state\.py|"
    r"modules/[0-9][0-9A-Za-z_-]*\.sh|"
    r"nexus/[A-Za-z0-9._-]+\.py|"
    r"nexus/rr_nexus_lib/[A-Za-z0-9._-]+\.py|"
    r"nexus/static/[A-Za-z0-9._-]+\.(?:html|css|js))$"
)


def fail(message):
    raise ValueError(message)


def octal(field, label):
    if field and field[0] & 0x80:
        fail(f"base-256 {label}")
    value = field.strip(b" \0")
    if not value:
        return 0
    if any(byte < 48 or byte > 55 for byte in value):
        fail(f"invalid {label}")
    return int(value, 8)


def text_field(field, label):
    value, separator, tail = field.partition(b"\0")
    if separator and any(tail):
        fail(f"ambiguous {label}")
    try:
        return value.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValueError(f"non-ascii {label}") from exc


names = []
declared_total = 0
with gzip.open(archive, "rb") as stream:
    zero_blocks = 0
    while True:
        header = stream.read(512)
        if len(header) != 512:
            fail("truncated tar header")
        if header == b"\0" * 512:
            zero_blocks += 1
            if zero_blocks == 2:
                break
            continue
        if zero_blocks:
            fail("data after a partial end marker")
        stored_checksum = octal(header[148:156], "checksum")
        calculated_checksum = sum(header[:148]) + (32 * 8) + sum(header[156:])
        if stored_checksum != calculated_checksum:
            fail("tar checksum mismatch")
        typeflag = header[156:157]
        if typeflag not in (b"\0", b"0"):
            fail("non-regular member or tar extension")
        name = text_field(header[:100], "name")
        prefix = text_field(header[345:500], "prefix")
        if prefix:
            name = prefix + "/" + name
        if not allowed.fullmatch(name):
            fail("member outside the release allowlist")
        if name in names:
            fail("duplicate member")
        size = octal(header[124:136], "size")
        if size > max_member_size:
            fail("member too large")
        declared_total += size
        if declared_total > max_total_size:
            fail("expanded archive too large")
        names.append(name)
        if len(names) > max_members:
            fail("too many members")
        remaining = size
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                fail("truncated member")
            remaining -= len(chunk)
        padding = (-size) % 512
        if padding and len(stream.read(padding)) != padding:
            fail("truncated member padding")
    trailing = 0
    while True:
        chunk = stream.read(65536)
        if not chunk:
            break
        trailing += len(chunk)
        if trailing > max_padding or any(chunk):
            fail("unexpected data after tar end marker")

if len(names) < 2:
    fail("empty bundle")

# A second independent parse checks that Python's tar interpretation matches
# the raw headers and that every declared regular-file payload is readable.
actual_names = []
actual_total = 0
with tarfile.open(archive, mode="r:gz") as handle:
    for member in handle:
        if not member.isreg() or member.pax_headers:
            fail("unsafe interpreted member")
        if member.name not in names or member.name in actual_names:
            fail("interpreted member mismatch")
        if member.size < 0 or member.size > max_member_size:
            fail("interpreted member too large")
        source = handle.extractfile(member)
        if source is None:
            fail("unreadable regular member")
        read_size = 0
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            read_size += len(chunk)
            actual_total += len(chunk)
            if read_size > member.size or actual_total > max_total_size:
                fail("payload exceeds declared limits")
        if read_size != member.size:
            fail("truncated interpreted member")
        actual_names.append(member.name)
if actual_names != names:
    fail("tar parser disagreement")
PYEOF
}

rr_bundle_tree_is_valid() {
    local bundle_root="$1"
    local manifest_file="$bundle_root/manifest.sha256"
    local expected_count=0
    local actual_count=0
    local shell_file=""
    local python_file=""

    rr_manifest_is_valid "$manifest_file" || return 1
    if find "$bundle_root" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
        return 1
    fi
    expected_count=$(( $(awk 'END { print NR + 0 }' "$manifest_file") + 1 ))
    actual_count=$(find "$bundle_root" -type f | wc -l)
    [ "$actual_count" -eq "$expected_count" ] || return 1
    (cd "$bundle_root" && sha256sum -c manifest.sha256 >/dev/null 2>&1) || return 1
    bash -n "$bundle_root/rr" || return 1
    for shell_file in "$bundle_root"/modules/*.sh; do
        [ -f "$shell_file" ] || return 1
        bash -n "$shell_file" || return 1
    done
    for shell_file in "$bundle_root"/scripts/*.sh; do
        [ -f "$shell_file" ] || return 1
        bash -n "$shell_file" || return 1
    done
    python3 -m py_compile "$bundle_root/scripts/update-external-state.py" || return 1
    while IFS= read -r python_file; do
        python3 -m py_compile "$python_file" || return 1
    done < <(find "$bundle_root/nexus" -type f -name '*.py' -print | LC_ALL=C sort)
}

rr_bundle_manifest_matches_trusted_source() {
    local bundle_manifest="$1"
    local trusted_manifest=""
    local matched=false

    [ -s "$bundle_manifest" ] || return 1
    trusted_manifest=$(mktemp /tmp/rr-bundle-manifest.XXXXXX) || return 1
    if rr_download_file "$RR_MANIFEST_URL" "$trusted_manifest" 3 true && \
       rr_manifest_is_valid "$trusted_manifest" && \
       cmp -s "$bundle_manifest" "$trusted_manifest"; then
        matched=true
    fi
    rm -f "$trusted_manifest"
    [ "$matched" = true ]
}

rr_prepare_bootstrap() {
    local target_file="$1"
    rr_download_file "$RR_BOOTSTRAP_URL" "$target_file" 10 true && \
        [ -s "$target_file" ] && \
        bash -n "$target_file" 2>/dev/null && \
        grep -q '^RR_BOOTSTRAP_VERSION=' "$target_file" && \
        grep -q 'Xiaowu7z/RR-vps' "$target_file"
}

# H16/T12：健康自愈失败不得静默——写 /var/log/rr-health.log + syslog（logger）。
# 供 ensure_runtime_health 在内核重装失败、孤立进程发现等场景记录，面板同步提示。
RR_HEALTH_LOG="/var/log/rr-health.log"
RR_FIREWALL_TX_ROOT="${RR_FIREWALL_TX_ROOT:-/var/lib/rr-update}"
RR_FIREWALL_ACTIVE_TX="${RR_FIREWALL_ACTIVE_TX:-${RR_FIREWALL_TX_ROOT}/active}"
RR_FIREWALL_FINALIZE_REQUIRED="${RR_FIREWALL_FINALIZE_REQUIRED:-false}"
RR_FIREWALL_FINALIZE_PENDING_NAME="firewall-finalize-pending"
RR_FIREWALL_FINALIZE_FAILED_NAME="firewall-finalize-failed"
RR_FIREWALL_FINALIZE_DEFERRED_NAME="firewall-finalize-deferred-active-ufw"
RR_FIREWALL_FINALIZE_COMPLETE_NAME="firewall-finalize-complete"
RR_FIREWALL_ROLLBACK_RETIRED_NAME="firewall-rollback-retired"
rr_health_log() {
    local message="${1:-}" log_size=0 trim_tmp=""
    [ -n "$message" ] || return 0
    log_size=$(stat -c '%s' "$RR_HEALTH_LOG" 2>/dev/null || echo 0)
    if [[ "$log_size" =~ ^[0-9]+$ ]] && [ "$log_size" -gt 1048576 ]; then
        trim_tmp=$(mktemp /var/log/.rr-health.XXXXXX) || trim_tmp=""
        if [ -n "$trim_tmp" ]; then
            tail -c 524288 "$RR_HEALTH_LOG" > "$trim_tmp" 2>/dev/null && \
                chmod 600 "$trim_tmp" && mv -f "$trim_tmp" "$RR_HEALTH_LOG"
            rm -f "$trim_tmp"
        fi
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$RR_HEALTH_LOG" 2>/dev/null || true
    chmod 600 "$RR_HEALTH_LOG" 2>/dev/null || true
    logger -t rr-health "$message" 2>/dev/null || true
}

rr_update_dir_is_safe() {
    local directory="$1" mode="" canonical=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
    [ "$canonical" = "$directory" ] || return 1
    [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c '%a' -- "$directory" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

rr_update_private_file_is_safe() {
    local path="$1"
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$path" 2>/dev/null)" = 0:0:600:1 ]
}

rr_current_update_transaction() {
    local root="$RR_FIREWALL_TX_ROOT" transactions="" tx="" name="" format_file=""
    local -a active_lines=()

    # Return 1 only for the ordinary "no retained transaction" case.  Unsafe
    # state returns 2 so callers cannot silently treat attacker-controlled
    # evidence as absence.
    [ -e "$RR_FIREWALL_ACTIVE_TX" ] || [ -L "$RR_FIREWALL_ACTIVE_TX" ] || return 1
    rr_update_dir_is_safe "$root" || return 2
    transactions="${root}/transactions"
    rr_update_dir_is_safe "$transactions" || return 2
    rr_update_private_file_is_safe "$RR_FIREWALL_ACTIVE_TX" || return 2
    mapfile -t active_lines < "$RR_FIREWALL_ACTIVE_TX" || return 2
    [ "${#active_lines[@]}" -eq 1 ] || return 2
    tx="${active_lines[0]}"
    case "$tx" in
        "$transactions"/*) name="${tx##*/}" ;;
        *) return 2 ;;
    esac
    [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || return 2
    rr_update_dir_is_safe "$tx" || return 2
    [ "$(stat -c '%a' -- "$tx" 2>/dev/null)" = 700 ] || return 2
    format_file="$tx/transaction-format"
    rr_update_private_file_is_safe "$format_file" || return 2
    [ "$(cat -- "$format_file" 2>/dev/null)" = 2 ] || return 2
    printf '%s\n' "$tx"
}

rr_update_transaction_phase() {
    local tx="$1" phase_file=""
    local -a phase_lines=()
    phase_file="${tx}/phase"
    rr_update_private_file_is_safe "$phase_file" || return 1
    mapfile -t phase_lines < "$phase_file" || return 1
    [ "${#phase_lines[@]}" -eq 1 ] || return 1
    printf '%s\n' "${phase_lines[0]}"
}

rr_write_firewall_finalize_evidence() {
    local tx="$1" name="$2" value="$3" target="" temporary=""
    case "$name" in
        "$RR_FIREWALL_FINALIZE_PENDING_NAME"|"$RR_FIREWALL_FINALIZE_FAILED_NAME"|\
        "$RR_FIREWALL_FINALIZE_DEFERRED_NAME"|"$RR_FIREWALL_FINALIZE_COMPLETE_NAME"|\
        "$RR_FIREWALL_ROLLBACK_RETIRED_NAME") ;;
        *) return 1 ;;
    esac
    [[ "$value" =~ ^local-subscription-firewall-v1\ [0-9]+$ ]] || return 1
    target="${tx}/${name}"
    if [ -e "$target" ] || [ -L "$target" ]; then
        rr_update_private_file_is_safe "$target" || return 1
        [ "$(cat -- "$target" 2>/dev/null)" = "$value" ] || return 1
        return 0
    fi
    temporary=$(mktemp "${tx}/.${name}.XXXXXX") || return 1
    if ! chmod 600 -- "$temporary" || \
       ! printf '%s\n' "$value" > "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$target" || \
       ! sync -f "$tx"; then
        rm -f -- "$temporary"
        return 1
    fi
    rr_update_private_file_is_safe "$target" && \
        [ "$(cat -- "$target" 2>/dev/null)" = "$value" ]
}

rr_read_firewall_finalize_evidence() {
    local tx="$1" name="$2" target="" value="" port=""
    local -a lines=()
    target="${tx}/${name}"
    rr_update_private_file_is_safe "$target" || return 1
    mapfile -t lines < "$target" || return 1
    [ "${#lines[@]}" -eq 1 ] || return 1
    value="${lines[0]}"
    [[ "$value" =~ ^local-subscription-firewall-v1\ ([0-9]+)$ ]] || return 1
    port="${BASH_REMATCH[1]}"
    is_valid_port "$port" || return 1
    printf '%s\n' "$port"
}

rr_record_firewall_finalize_pending() {
    local tx="" phase=""
    [ "$RR_FIREWALL_FINALIZE_REQUIRED" = true ] || return 0
    tx=$(rr_current_update_transaction) || return 1
    phase=$(rr_update_transaction_phase "$tx") || return 1
    [ "$phase" = migrating ] || return 1
    is_valid_port "${SUB_PORT:-}" || return 1
    rr_write_firewall_finalize_evidence "$tx" \
        "$RR_FIREWALL_FINALIZE_PENDING_NAME" \
        "local-subscription-firewall-v1 ${SUB_PORT}"
}

rr_snapshot_ufw_state() {
    local tx="$1" state_file="" complete_file="" required_file=""
    state_file="${tx}/backup/external-state/state.json"
    complete_file="${tx}/backup/external-state/complete"
    required_file="${tx}/backup/external_state_required"
    python3 - "$state_file" "$complete_file" "$tx" "$required_file" <<'PY'
import hashlib
import json
import os
import stat
import sys


def secure_read(path):
    before = os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != 0 or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600):
        raise SystemExit(1)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise SystemExit(1)
        chunks = []
        total = 0
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            total += len(block)
            if total > 16 * 1024 * 1024:
                raise SystemExit(1)
            chunks.append(block)
        return b"".join(chunks)
    finally:
        os.close(fd)


transaction = os.path.realpath(sys.argv[3])
if transaction != sys.argv[3]:
    raise SystemExit(1)
for directory in (transaction, os.path.join(transaction, "backup"),
                  os.path.join(transaction, "backup", "external-state")):
    info = os.lstat(directory)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022
            or os.path.realpath(directory) != directory):
        raise SystemExit(1)
if secure_read(sys.argv[4]):
    raise SystemExit(1)
raw = secure_read(sys.argv[1])
marker = secure_read(sys.argv[2]).decode("ascii").strip().split()
if len(marker) != 2 or marker[0] != "rr-update-external-state-v2":
    raise SystemExit(1)
if hashlib.sha256(raw).hexdigest() != marker[1]:
    raise SystemExit(1)
value = json.loads(raw)
if value.get("version") != marker[0]:
    raise SystemExit(1)
state = value.get("firewall", {}).get("ufw", {}).get("state")
if state not in {"active", "inactive", "absent"}:
    raise SystemExit(1)
print(state)
PY
}

rr_current_ufw_state() {
    local state=0
    command -v ufw >/dev/null 2>&1 || { printf '%s\n' absent; return 0; }
    if rr_ufw_backend_state; then
        printf '%s\n' active
        return 0
    else
        state=$?
    fi
    [ "$state" -eq 1 ] || return 1
    printf '%s\n' inactive
}

rr_finalize_committed_firewall() {
    local mode="${1:-normal}" tx="" phase="" port="" evidence=""
    local snapshot_ufw="" current_ufw="" result=0
    case "$mode" in normal|health|retire-rollback) ;; *) return 2 ;; esac

    if tx=$(rr_current_update_transaction); then
        :
    else
        result=$?
        [ "$result" -eq 1 ] && [ "$mode" = health ] && return 0
        return 1
    fi
    phase=$(rr_update_transaction_phase "$tx") || return 1
    if [ "$phase" != committed ]; then
        [ "$mode" = health ] && return 0
        return 1
    fi
    if [ ! -e "$tx/$RR_FIREWALL_FINALIZE_PENDING_NAME" ] && \
       [ ! -L "$tx/$RR_FIREWALL_FINALIZE_PENDING_NAME" ]; then
        return 0
    fi
    port=$(rr_read_firewall_finalize_evidence "$tx" \
        "$RR_FIREWALL_FINALIZE_PENDING_NAME") || return 1
    evidence="local-subscription-firewall-v1 ${port}"
    snapshot_ufw=$(rr_snapshot_ufw_state "$tx") || {
        rr_write_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_FINALIZE_FAILED_NAME" "$evidence" >/dev/null 2>&1 || true
        return 1
    }
    current_ufw=$(rr_current_ufw_state) || {
        rr_write_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_FINALIZE_FAILED_NAME" "$evidence" >/dev/null 2>&1 || true
        return 1
    }
    if [ "$snapshot_ufw" != "$current_ufw" ]; then
        rr_write_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_FINALIZE_FAILED_NAME" "$evidence" >/dev/null 2>&1 || true
        return 1
    fi

    # Active UFW snapshots use a full read-only equality invariant.  Changing
    # even an RR-owned rule while the committed transaction remains available
    # for manual rollback would make that rollback fail.  Preserve the exact
    # rules and a root-only pending/deferred marker until a future update first
    # retires the old rollback window, or an operator explicitly chooses the
    # retire-rollback mode.
    if [ "$snapshot_ufw" = active ] && [ "$mode" != retire-rollback ]; then
        rr_write_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_FINALIZE_DEFERRED_NAME" "$evidence"
        return $?
    fi

    if [ "$snapshot_ufw" = active ]; then
        # This marker is the durable record that the caller explicitly retired
        # the active-UFW rollback window.  Publish it before the first rule
        # mutation so a crash can never leave rollback looking safe.
        rr_write_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_ROLLBACK_RETIRED_NAME" "$evidence" || return 1
    fi

    load_config_with_defaults || result=1
    if [ "$result" -eq 0 ] && \
       { [ "${SUB_ACCESS_MODE:-local}" != local ] || [ "${SUB_PORT:-}" != "$port" ]; }; then
        result=1
    fi
    if [ "$result" -eq 0 ]; then
        RR_UPDATE_TRANSACTION=0 open_configured_firewall || result=1
    fi
    if [ "$result" -ne 0 ]; then
        rr_write_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_FINALIZE_FAILED_NAME" "$evidence" >/dev/null 2>&1 || true
        return 1
    fi

    # Publish completion before removing pending/failure markers.  If the
    # subsequent directory fsync fails, there is still durable evidence rather
    # than a failed return with every trace erased.
    rr_write_firewall_finalize_evidence "$tx" \
        "$RR_FIREWALL_FINALIZE_COMPLETE_NAME" "$evidence" || return 1
    rm -f -- "$tx/$RR_FIREWALL_FINALIZE_PENDING_NAME" \
        "$tx/$RR_FIREWALL_FINALIZE_FAILED_NAME" \
        "$tx/$RR_FIREWALL_FINALIZE_DEFERRED_NAME" || return 1
    sync -f "$tx"
}

rr_manual_update_rollback_is_safe() {
    local tx="" phase="" marker="" state=0
    if tx=$(rr_current_update_transaction); then
        :
    else
        state=$?
        [ "$state" -eq 1 ]
        return $?
    fi
    phase=$(rr_update_transaction_phase "$tx") || return 1
    [ "$phase" = committed ] || return 0
    marker="$tx/$RR_FIREWALL_ROLLBACK_RETIRED_NAME"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        rr_read_firewall_finalize_evidence "$tx" \
            "$RR_FIREWALL_ROLLBACK_RETIRED_NAME" >/dev/null || return 1
        return 1
    fi
    return 0
}

rr_run_post_update_finalize() {
    local mode="${1:-normal}" result=0
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ]; then
        if [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ]; then
            rr_finalize_committed_firewall "$mode"
        else
            rr_run_without_inherited_update_lock_fds \
                rr_finalize_committed_firewall "$mode"
        fi
        return $?
    fi
    rr_run_with_update_locks isolated 0 rr_finalize_committed_firewall "$mode" || result=$?
    if [ "$result" -eq 75 ] || [ "$result" -eq 76 ]; then result=1; fi
    return "$result"
}

    check_update() {
    local remote_manifest=""
    # H15：三态检查——available 有新 / latest 已最新 / failed 检查失败（网络不可用）。
    # 默认置 failed 并显示"检查失败"，下载/校验任一失败时保持该态，绝不误报"已是最新"。
    UPDATE_AVAILABLE=false
    UPDATE_CHECK_STATE="failed"
    UPDATE_CHECK_ERROR=""
    SCRIPT_VER_STATUS="${YELLOW}检查失败（网络不可用）${RESET}"
    remote_manifest=$(mktemp /tmp/rr-manifest-check.XXXXXX) || return 0
    if ! rr_download_file "$RR_MANIFEST_URL" "$remote_manifest" 3 true; then
        UPDATE_CHECK_ERROR="GitHub Raw、API 与 CDN 均不可达"
        SCRIPT_VER_STATUS="${YELLOW}检查失败（下载链路不可用）${RESET}"
        rm -f "$remote_manifest"
        return 0
    fi
    if ! rr_manifest_is_valid "$remote_manifest"; then
        UPDATE_CHECK_ERROR="远程 manifest.sha256 格式无效"
        SCRIPT_VER_STATUS="${YELLOW}检查失败（远程清单无效）${RESET}"
        rm -f "$remote_manifest"
        return 0
    fi

    if [ ! -s "$RR_LOCAL_MANIFEST" ] || \
       [ "$(sha256sum "$remote_manifest" | awk '{print $1}')" != \
         "$(sha256sum "$RR_LOCAL_MANIFEST" 2>/dev/null | awk '{print $1}')" ]; then
        UPDATE_AVAILABLE=true
        UPDATE_CHECK_STATE="available"
        SCRIPT_VER_STATUS="${RED}有新版本${RESET}"
    else
        UPDATE_AVAILABLE=false
        UPDATE_CHECK_STATE="latest"
        SCRIPT_VER_STATUS="${GREEN}已是最新${RESET}"
    fi
    rm -f "$remote_manifest"
}

post_update_migrate() {
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] && \
       [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" != 1 ]; then
        rr_run_without_inherited_update_lock_fds post_update_migrate
        return $?
    fi
    local update_tx="${RR_UPDATE_TRANSACTION:-0}"
    local singbox_was_running="${RR_UPDATE_SINGBOX_WAS_RUNNING:-true}"
    local nexus_was_running="${RR_UPDATE_NEXUS_WAS_RUNNING:-true}"
    local subscription_was_running="${RR_UPDATE_SUBSCRIPTION_WAS_RUNNING:-true}"
    local argo_was_running="${RR_UPDATE_ARGO_WAS_RUNNING:-true}"
    local health_timer_was_enabled="${RR_UPDATE_HEALTH_TIMER_WAS_ENABLED:-true}"
    RR_FIREWALL_FINALIZE_REQUIRED=false
    check_supported_os >/dev/null 2>&1 || return 1
    # A machine without RR-vps configuration has no managed runtime to stop or
    # migrate. Returning before service operations avoids touching an unrelated
    # system sing-box installation during a fresh bootstrap.
    [ -f "$CONFIG_FILE" ] || return 0
    # 热更新前置：停止旧服务避免端口冲突
    systemctl stop sing-box 2>/dev/null || true
    systemctl stop rr-subscription 2>/dev/null || true
    systemctl stop rr-nexus 2>/dev/null || true
    stop_subscription_servers || return 1
    sleep 1
    migrate_config_schema || return 1
    load_config_with_defaults || return 1
    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        # Replace the legacy inline certbot hook during hot update.  The 7.1
        # hook only accepts the configured Naive lineage and cannot copy an
        # unrelated certificate renewed in the same certbot run.
        if [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then
            ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL" || return 1
        else
            deploy_naive_cert_hook || return 1
        fi
    fi

    # A failed first-install candidate intentionally contains empty keys and
    # no runnable service.  Updating the script must still succeed so the user
    # can re-enter option 1 with the fixed installer; do not treat that
    # candidate as a live node to migrate or restart.
    # (6.6.8: 收紧判定——迁移后的活节点机器 INSTALL_COMPLETE=false 但节点启用，
    # 必须照常重启，否则高速热更后节点无人拉起)
    if [ "$INSTALL_COMPLETE" != "true" ] && ! any_node_protocol_enabled; then
        return 0
    fi

    local current_version=""
    if any_node_protocol_enabled; then
        current_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
        if [ -z "$current_version" ]; then
            if [ "$update_tx" = 1 ]; then
                printf '%s\n' '[安全拒绝] 热更新候选缺少 Sing-box 内核；未下载，准备回滚。' >&2
                return 1
            fi
            install_singbox || return 1
        elif ! version_ge "$current_version" "$MIN_SINGBOX_VERSION"; then
            if [ "$update_tx" = 1 ]; then
                printf '[安全拒绝] 热更新候选所需 Sing-box 版本高于现有 %s；未升级，准备回滚。\n' \
                    "$current_version" >&2
                return 1
            fi
            # 下载失败时仍保留旧核心；只要现有协议配置能通过校验，脚本更新可以继续。
            install_singbox >/dev/null 2>&1 || true
        fi

        if [ ! -f /etc/systemd/system/sing-box.service ]; then
            if [ "$update_tx" = 1 ]; then
                printf '%s\n' '[安全拒绝] 热更新候选缺少既有 Sing-box systemd 单元；未创建外部服务。' >&2
                return 1
            fi
            build_singbox_config || return 1
            setup_systemd || return 1
            generate_node_and_sub || return 1
        else
            ensure_singbox_service_guards
            sync_runtime_state || return 1
        fi
    else
        stop_singbox_instances >/dev/null 2>&1 || true
        generate_node_and_sub || return 1
    fi

    if crontab -l 2>/dev/null | grep -q 'auto_update_sub.py'; then
        write_auto_update_worker || return 1
        RR_WORKER_LOCK_HELD=1 python3 /usr/local/bin/auto_update_sub.py >/dev/null 2>&1 || return 1
    fi

    load_config_with_defaults || return 1
    if any_node_protocol_enabled && [ "$SINGBOX_AUTO_RESTART" = "true" ] && \
       { [ "$update_tx" != 1 ] || [ "$singbox_was_running" = true ]; } && ! managed_singbox_running; then
        restart_singbox || return 1
    fi
    if [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ] && \
       { [ "$update_tx" != 1 ] || [ "$argo_was_running" = true ]; } && \
       ! expected_argo_tunnel_running; then
        start_argo_tunnel >/dev/null 2>&1 || return 1
    elif [ "$update_tx" = 1 ] && [ "$argo_was_running" != true ]; then
        if [ "${TUNNEL_MODE:-1}" = 2 ]; then
            systemctl stop cloudflared >/dev/null 2>&1 || true
        else
            stop_quick_argo_tunnel
        fi
    fi
    if any_node_protocol_enabled && { [ "$update_tx" != 1 ] || [ "$health_timer_was_enabled" = true ]; }; then
        setup_health_monitor >/dev/null 2>&1 || true
    elif [ "$update_tx" = 1 ]; then
        systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
    elif ! any_node_protocol_enabled; then
        systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
    fi
    if [ -f "$NEXUS_SERVICE_FILE" ]; then
        nexus_install_dependencies || return 1
        nexus_migrate_runtime_config || return 1
        nexus_reconcile_public_proxy || return 1
        nexus_enable_traffic_engine || return 1
        ensure_nexus_service_guards
        RR_NEXUS_CONFIG="$NEXUS_CONFIG_FILE" python3 "$NEXUS_APP" --check || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        if [ "$update_tx" != 1 ] || [ "$nexus_was_running" = true ]; then
            systemctl restart rr-nexus >/dev/null 2>&1 || return 1
        else
            systemctl stop rr-nexus >/dev/null 2>&1 || true
        fi
    fi
    open_configured_firewall || return 1
    if [ "$update_tx" = 1 ] && [ "$RR_FIREWALL_FINALIZE_REQUIRED" = true ]; then
        rr_record_firewall_finalize_pending || return 1
    fi

    # 事务健康门：任一关失败都让核心安装器自动回滚。
    if any_node_protocol_enabled; then
        "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1 || return 1
        if [ "$update_tx" != 1 ] || [ "$singbox_was_running" = true ]; then
            systemctl is-active --quiet sing-box || return 1
        else
            systemctl stop sing-box >/dev/null 2>&1 || true
        fi
    fi
    if [ -r /var/lib/rr-nexus/nexus.db ]; then
        python3 - /var/lib/rr-nexus/nexus.db <<'PY' || return 1
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
try:
    row = db.execute("PRAGMA quick_check").fetchone()
    raise SystemExit(0 if row and row[0] == "ok" else 1)
finally:
    db.close()
PY
    fi
    if [ -f "$NEXUS_SERVICE_FILE" ] && { [ "$update_tx" != 1 ] || [ "$nexus_was_running" = true ]; }; then
        systemctl is-active --quiet rr-nexus || return 1
        local nexus_health_port=""
        nexus_health_port=$(jq -r '.port // 7900' "$NEXUS_CONFIG_FILE" 2>/dev/null || printf 7900)
        curl -fsS --connect-timeout 3 --max-time 8 "http://127.0.0.1:${nexus_health_port}/healthz" >/dev/null || return 1
        nexus_public_proxy_health_check || return 1
    fi
    if [ "$update_tx" = 1 ] && [ "$subscription_was_running" != true ]; then
        local migrated_sub_pid=""
        [ -f "$SUB_PID_FILE" ] && migrated_sub_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
        is_subscription_pid "$migrated_sub_pid" && kill "$migrated_sub_pid" >/dev/null 2>&1 || true
        rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE"
    elif [ "$subscription_was_running" = true ]; then
        local migrated_sub_pid=""
        [ -f "$SUB_PID_FILE" ] && migrated_sub_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
        is_subscription_pid "$migrated_sub_pid" || return 1
    fi
    return 0
}

ensure_runtime_health() {
    [ "$HEALTH_CHECK_DONE" = false ] || return 0
    HEALTH_CHECK_DONE=true
    if ! rr_finalize_committed_firewall health; then
        rr_health_log "已提交更新的订阅防火墙待收敛失败；保留事务证据且未回滚，请运行 rr doctor"
        return 1
    fi
    [ -f "$CONFIG_FILE" ] || return 0
    migrate_config_schema >/dev/null 2>&1 || return 0
    load_config_with_defaults || return 0
    # 首次安装尚未完成时不介入，避免定时器与安装向导争抢端口或隧道。
    # (T10 C 系发现：迁移后的活节点机器 INSTALL_COMPLETE=false 但节点启用，
    #  健康定时器必须介入，否则该机器无自动恢复；仅"无节点协议"时保持旁路)
    [ "$INSTALL_COMPLETE" = "true" ] || ! any_node_protocol_enabled || return 0
    if ! any_node_protocol_enabled; then
        managed_singbox_running && stop_singbox_instances >/dev/null 2>&1 || true
        return 0
    fi
    ensure_singbox_service_guards
    # T4：为已部署机器幂等补齐 rr-nexus 单元的 StartLimit + 损坏数据库防重启。
    [ -f "$NEXUS_SERVICE_FILE" ] && ensure_nexus_service_guards

    # H6：sing-box 单元 active 时若存在脱离 unit cgroup 的受管进程，只记录与提示
    # 绝不自动清理（可能是用户手动运行的进程，清理有风险）。
    SB_ORPHAN_DETECTED=false
    if [ -f /etc/systemd/system/sing-box.service ] && systemctl is-active --quiet sing-box; then
        local orphan_pids=""
        orphan_pids=$(singbox_orphan_pids | tr '\n' ' ')
        if [ -n "$orphan_pids" ]; then
            SB_ORPHAN_DETECTED=true
            rr_health_log "发现脱离 systemd 的孤立 sing-box 进程（PID:${orphan_pids}），仅提示未清理；如非人为启动可到菜单 11→2 处理"
        fi
    fi

    # 只在受管内核缺失/损坏时修复；正常内核不做周期升级，避免无意义重启在线节点。
    local health_core_version=""
    SB_CORE_MISSING=false
    health_core_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
    if [ "$SINGBOX_AUTO_RESTART" = "true" ] && [ -z "$health_core_version" ]; then
        # H16：内核缺失自愈失败不得静默——写健康日志并在面板显示提示字段。
        if ! install_singbox >/dev/null 2>&1; then
            SB_CORE_MISSING=true
            rr_health_log "Sing-box 内核缺失且自动重装失败（可能网络不可用），节点未拉起；网络恢复后执行 rr 或菜单 11→7 重试"
        fi
        health_core_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
    fi

    if [ "$SINGBOX_AUTO_RESTART" = "true" ] && [ -n "$health_core_version" ] && \
       ! systemctl is-active --quiet sing-box; then
        if "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            restart_singbox >/dev/null 2>&1 || true
        fi
    fi

    if managed_singbox_running && [ "$VM_ENABLED" != "false" ] && \
       [ "$VM_TLS_ENABLED" != "true" ] && ! expected_argo_tunnel_running; then
        start_argo_tunnel >/dev/null 2>&1 || true
    fi

    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_HOP_PORTS" ]; then
        install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1 || true
    fi

    # 设备到期和额度状态可能在无人操作时变化；定时同步只会在用户列表
    # 实际变化时重启 Sing-box，平时不会打断在线节点。
    if command -v timeout >/dev/null 2>&1 && \
       [ -x "$RR_LAUNCHER" ] && \
       [ -f "${NEXUS_DB_FILE:-/nonexistent}" ]; then
        # timeout can only exec a program; a non-exported Bash function exits
        # 127 without doing any work.  Re-enter through the supported CLI.
        timeout --kill-after=5 150 "$RR_LAUNCHER" --sync-devices >/dev/null 2>&1 || true
    fi

    local sub_pid=""
    [ -f "$SUB_PID_FILE" ] && sub_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    if ! is_subscription_pid "$sub_pid" || \
       [ ! -s "${SUB_ROOT}/${UUID}/jhsub.txt" ] || \
       [ ! -s "${SUB_ROOT}/${UUID}/client.json" ]; then
        # 订阅自愈加超时保护：重建含公网入口探测，网络异常时不能拖垮
        # 整个健康检查链（此前实测一次网络抖动把链条卡住导致订阅迟迟未拉起）。
        timeout --kill-after=5 150 "$RR_LAUNCHER" --sync-subscriptions >/dev/null 2>&1 || true
    fi
    return 0
}

rr_run_health_check() {
    local health_result=0

    # The installer/recovery path already owns the shared transaction lock and
    # must explicitly delegate that ownership before re-entering the launcher.
    # Normal timer/manual invocations take the same lock as update, backup and
    # restore so they can never repair services or rewrite subscriptions while
    # a transaction snapshot is in progress.
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ]; then
        if [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ]; then
            ensure_runtime_health
        else
            rr_run_without_inherited_update_lock_fds ensure_runtime_health
        fi
        return $?
    fi
    rr_run_with_update_locks isolated 0 ensure_runtime_health || health_result=$?
    if [ "$health_result" -eq 75 ]; then
        # A timer firing during either a current or 7.1.0 transaction is an
        # expected skip. The next timer pass will run after both locks release.
        return 0
    fi
    if [ "$health_result" -eq 76 ]; then
        rr_health_log "共享事务锁或 7.1.0 兼容锁不安全，健康检查已拒绝运行"
        health_result=1
    fi
    return "$health_result"
}


do_update() {
    echo -e "\n${YELLOW}检查 RR-vps 远程版本...${RESET}"
    # check_update 失败时不会重置该变量，先归零避免残留 true 误判"有更新"。
    UPDATE_AVAILABLE=false

    # ============================================================
    # 第一步：bundle 高速直更（绕过 CDN manifest 缓存）
    # 先解压到临时目录做完整校验，再交给安装器的统一事务执行升级。
    # ============================================================
    local bundle_url="${RR_RAW_BASE}/rr-bundle.tar.gz"
    local bundle_tmp=""
    bundle_tmp=$(mktemp /tmp/rr-bundle-update.XXXXXX) || true
    local bundle_stage=""
    bundle_stage=$(mktemp -d /tmp/rr-bundle-stage.XXXXXX) || true
    local remote_ver=""
    local local_ver="${SCRIPT_VERSION:-0}"
    local bootstrap_tmp=""
    local bundle_changed=false

    if [ -n "$bundle_tmp" ] && [ -n "$bundle_stage" ] && \
       rr_download_file "$bundle_url" "$bundle_tmp" 10 && \
       [ -s "$bundle_tmp" ] && \
       rr_bundle_archive_is_safe "$bundle_tmp" && \
       tar --no-same-owner --no-same-permissions -xzf \
           "$bundle_tmp" -C "$bundle_stage" 2>/dev/null && \
       rr_bundle_tree_is_valid "$bundle_stage/rr-bundle" && \
       rr_bundle_manifest_matches_trusted_source \
           "$bundle_stage/rr-bundle/manifest.sha256"; then
        # A user mirror is only an untrusted transport.  Do not use the
        # bundle's self-reported version or manifest for update/downgrade
        # decisions until its complete manifest matches a trusted source.
        remote_ver=$(grep -o '^SCRIPT_VERSION="[0-9][0-9.]*"' \
            "$bundle_stage/rr-bundle/modules/00-runtime.sh" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [ -s "$RR_LOCAL_MANIFEST" ] && \
           cmp -s "$bundle_stage/rr-bundle/manifest.sha256" "$RR_LOCAL_MANIFEST"; then
            bundle_changed=false
        else
            bundle_changed=true
        fi
        if [ -n "$remote_ver" ] && [ "$bundle_changed" = true ] && \
           { [ "$local_ver" = "0" ] || version_ge "$remote_ver" "$local_ver"; }; then
            bootstrap_tmp=$(mktemp /tmp/rr-bootstrap-update.XXXXXX) || return 1
            if ! rr_prepare_bootstrap "$bootstrap_tmp"; then
                rm -f "$bootstrap_tmp" "$bundle_tmp"
                rm -rf "$bundle_stage"
                echo -e "${RED}[失败] 更新程序下载或完整性检查失败，当前节点未改动。${RESET}"
                read -rp "按回车键返回..." || true
                return 1
            fi
            chmod 700 "$bootstrap_tmp"
            echo -e "${YELLOW}发现发布内容更新，正在执行带完整回滚保护的高速热更新...${RESET}"
            if RR_BUNDLE_FILE="$bundle_tmp" bash "$bootstrap_tmp" --upgrade; then
                rm -f "$bootstrap_tmp" "$bundle_tmp"
                rm -rf "$bundle_stage"
                echo -e "${GREEN}[成功] RR-vps 已完成高速热更新，服务迁移校验通过。${RESET}"
                read -rp "按回车键退出..." || true
                exit 0
            fi
            rm -f "$bootstrap_tmp" "$bundle_tmp"
            rm -rf "$bundle_stage"
            echo -e "${RED}[失败] 高速热更新未完成，安装程序已回滚运行文件与数据。${RESET}"
            read -rp "按回车键返回..." || true
            return 1
        fi
    fi
    rm -f "$bundle_tmp" 2>/dev/null
    rm -rf "$bundle_stage" 2>/dev/null

    # H3：远程 bundle 版本低于本地时显式提示降级已被拦截（此前静默跳过）。
    if [ -n "$remote_ver" ] && [ "$local_ver" != "0" ] && [ "$remote_ver" != "$local_ver" ] && \
       ! version_ge "$remote_ver" "$local_ver"; then
        echo -e "${YELLOW}[提示] 已阻止降级：远程版本 ${remote_ver} 低于本地版本 ${local_ver}。${RESET}"
        read -rp "按回车键返回..." || true
        return 1
    fi

    # ============================================================
    # 第二步：manifest 比对 + bootstrap 全量升级（原兜底路径）
    # ============================================================
    check_update
    if [ "${UPDATE_CHECK_STATE:-latest}" = "failed" ]; then
        echo -e "${YELLOW}[提示] 版本检查失败：${UPDATE_CHECK_ERROR:-未知原因}；本次未执行更新，当前节点未改动。${RESET}"
        read -p "按回车键返回..." || true
        return 1
    fi
    if [ "$UPDATE_AVAILABLE" != true ]; then
        echo -e "${GREEN}当前已是最新版本，无需更新。${RESET}"
        read -p "按回车键返回..."
        return 0
    fi

    # 直接下载最新安装器（带时间戳绕过 CDN 缓存）。
    bootstrap_tmp=$(mktemp /tmp/rr-bootstrap-update.XXXXXX) || return 1
    if ! rr_prepare_bootstrap "$bootstrap_tmp"; then
        rm -f "$bootstrap_tmp"
        echo -e "${RED}[失败] 更新程序下载或完整性检查失败，当前节点未改动。${RESET}"
        read -p "按回车键返回..." || true
        return 1
    fi
    [ -s "$bootstrap_tmp" ] || { rm -f "$bootstrap_tmp"; echo -e "${RED}[失败] 更新程序不可用。${RESET}"; read -p "按回车键返回..."; return 1; }
    chmod 700 "$bootstrap_tmp"

    echo -e "${YELLOW}发现新版本，正在执行带回滚保护的模块化热更新...${RESET}"
    if bash "$bootstrap_tmp" --upgrade; then
        rm -f "$bootstrap_tmp"
        echo -e "${GREEN}[成功] RR-vps 已更新到最新版本。${RESET}"
        echo -e "${CYAN}原 UUID、密钥、域名、节点端口、订阅端口及 IPv4/IPv6 设置均已保留。${RESET}"
        echo -e "${YELLOW}请重新执行 rr 进入新版本面板。${RESET}"
        read -p "按回车键退出..."
        exit 0
    fi

    rm -f "$bootstrap_tmp"
    echo -e "${RED}[失败] 热更新没有完成，安装程序已回滚原模块和运行数据。${RESET}"
    read -p "按回车键返回..."
    return 1
}
