#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install-core.sh"
RESTORE="$REPO_ROOT/modules/55-resilience.sh"
EXTERNAL="$REPO_ROOT/scripts/update-external-state.py"
IP_ACME_CORE="$REPO_ROOT/modules/86-nexus-ip-acme.sh"
TEST_ROOT=$(mktemp -d /root/rr-ip-acme-restore-update.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$1"
}
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

bash -n "$INSTALLER" "$RESTORE"
python3 -m py_compile "$EXTERNAL"
pass 'edited restore/update programs parse'

python3 - "$EXTERNAL" "$TEST_ROOT" <<'PY'
import importlib.util
import os
import pathlib
import re
import sys

helper, test_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr_external", helper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

root = pathlib.Path(test_root) / "external-root"
parent = root / "usr/local/lib/rr-vps"
parent.mkdir(parents=True)
os.chmod(root, 0o700)
for ancestor in (root / "usr", root / "usr/local", root / "usr/local/lib", parent):
    os.chmod(ancestor, 0o755)
os.environ["RR_EXTERNAL_ROOT"] = str(root)

def attempt(size: int, logical: str, name: str, should_pass: bool) -> None:
    source = root / logical.lstrip("/")
    source.parent.mkdir(parents=True, exist_ok=True)
    with source.open("wb") as stream:
        stream.truncate(size)
    items = pathlib.Path(test_root) / name
    items.mkdir(mode=0o700)
    try:
        entry = module.source_entry(logical, items, 0)
    except module.StateError:
        if should_pass:
            raise
    else:
        if not should_pass or entry["size"] != size:
            raise SystemExit("unexpected managed file limit result")

attempt(17 * 1024 * 1024, "/usr/local/lib/rr-vps/lego", "items-17", True)
attempt(73 * 1024 * 1024, "/usr/local/lib/rr-vps/lego", "items-73", False)
attempt(17 * 1024 * 1024, "/etc/rr-nexus/certs/ip.crt", "items-default", False)
assert module.managed_file_limit("/usr/local/lib/rr-vps/lego") == 72 * 1024 * 1024

logical = "/usr/local/lib/rr-vps/lego"
source = root / logical.lstrip("/")
source.parent.mkdir(parents=True, exist_ok=True)
source.write_bytes(b"")
with source.open("r+b") as stream:
    stream.truncate(17 * 1024 * 1024)
restore_snapshot = pathlib.Path(test_root) / "restore-17"
restore_items = restore_snapshot / "items"
restore_items.mkdir(parents=True, mode=0o700)
entry = module.source_entry(logical, restore_items, 0)
source.unlink()
module.restore_entry(restore_snapshot, entry)
assert source.stat().st_size == 17 * 1024 * 1024

source.unlink()
oversize_snapshot = pathlib.Path(test_root) / "restore-73"
oversize_items = oversize_snapshot / "items"
oversize_items.mkdir(parents=True, mode=0o700)
oversize_item = oversize_items / "0"
with oversize_item.open("wb") as stream:
    stream.truncate(73 * 1024 * 1024)
oversize_entry = dict(entry, size=73 * 1024 * 1024)
try:
    module.restore_entry(oversize_snapshot, oversize_entry)
except module.StateError:
    pass
else:
    raise SystemExit("oversized lego rollback item was accepted")

source.write_bytes(b"owned")
writable_items = pathlib.Path(test_root) / "items-writable-parent"
writable_items.mkdir(mode=0o700)
os.chmod(root / "usr/local", 0o777)
try:
    module.source_entry(logical, writable_items, 0)
except module.StateError:
    pass
else:
    raise SystemExit("group/world-writable intermediate parent was accepted")
finally:
    os.chmod(root / "usr/local", 0o755)
PY
pass 'lego has a bounded 72 MiB lifecycle and every parent stays privileged'

# Execute the production parent helpers against a path-identical private
# fixture.  A one-pass replacement avoids accidentally rewriting the fixture
# prefix when shorter logical paths are substituted.
PARENT_FIXTURE="$TEST_ROOT/parent-fixture"
mkdir -p "$PARENT_FIXTURE/var/lib/rr-nexus" "$PARENT_FIXTURE/var/www"
chmod 755 "$PARENT_FIXTURE" "$PARENT_FIXTURE/var" "$PARENT_FIXTURE/var/lib" \
    "$PARENT_FIXTURE/var/www"
chmod 700 "$PARENT_FIXTURE/var/lib/rr-nexus"
python3 - "$INSTALLER" "$TEST_ROOT/installer-parent-functions.sh" \
    "$PARENT_FIXTURE" <<'PY'
import pathlib
import re
import sys

source, output, prefix = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
start = text.index("rr_ip_acme_parent_chain_is_safe()")
end = text.index("rr_ip_acme_candidate_runtime_is_exact()", start)
fragment = text[start:end]
mapping = {
    "/var/lib/rr-nexus/ip-acme": prefix + "/var/lib/rr-nexus/ip-acme",
    "/var/www/rr-nexus-ip-acme": prefix + "/var/www/rr-nexus-ip-acme",
    "/var/lib/rr-nexus": prefix + "/var/lib/rr-nexus",
    "/var/www": prefix + "/var/www",
    "/var/lib": prefix + "/var/lib",
    "/var": prefix + "/var",
}
pattern = re.compile("|".join(re.escape(value) for value in sorted(mapping, key=len, reverse=True)))
pathlib.Path(output).write_text(pattern.sub(lambda match: mapping[match.group()], fragment), encoding="utf-8")
PY
# shellcheck disable=SC1090
source "$TEST_ROOT/installer-parent-functions.sh"
RR_IP_ACME_STATE_ROOT="$PARENT_FIXTURE/var/lib/rr-nexus/ip-acme"
RR_IP_ACME_WEBROOT="$PARENT_FIXTURE/var/www/rr-nexus-ip-acme"
rr_ip_acme_parent_chain_is_safe "$RR_IP_ACME_STATE_ROOT" || fail 'safe state parent was rejected'
before_mode=$(stat -c %a "$PARENT_FIXTURE/var/www")
rr_ip_acme_prepare_parent "$RR_IP_ACME_WEBROOT" || fail 'safe webroot parent was rejected'
[ "$(stat -c %a "$PARENT_FIXTURE/var/www")" = "$before_mode" ] || \
    fail 'existing /var/www fixture was chmodded'

mkdir -p "$TEST_ROOT/victim-state"
printf 'survive\n' > "$TEST_ROOT/victim-state/sentinel"
rmdir "$PARENT_FIXTURE/var/lib/rr-nexus"
ln -s "$TEST_ROOT/victim-state" "$PARENT_FIXTURE/var/lib/rr-nexus"
if rr_ip_acme_parent_chain_is_safe "$RR_IP_ACME_STATE_ROOT"; then
    fail 'state parent symlink was accepted'
fi
[ "$(cat "$TEST_ROOT/victim-state/sentinel")" = survive ] || fail 'state symlink victim changed'
unlink "$PARENT_FIXTURE/var/lib/rr-nexus"
mkdir -m 700 "$PARENT_FIXTURE/var/lib/rr-nexus"

mkdir -p "$TEST_ROOT/victim-web"
printf 'survive\n' > "$TEST_ROOT/victim-web/sentinel"
rmdir "$PARENT_FIXTURE/var/www"
ln -s "$TEST_ROOT/victim-web" "$PARENT_FIXTURE/var/www"
if rr_ip_acme_prepare_parent "$RR_IP_ACME_WEBROOT"; then
    fail 'webroot intermediate symlink was accepted'
fi
[ "$(cat "$TEST_ROOT/victim-web/sentinel")" = survive ] || fail 'webroot symlink victim changed'
pass 'fixed IP-ACME parent chains reject symlinks without chmodding /var/www'

python3 - "$RESTORE" "$TEST_ROOT/fixed-parent-function.sh" "$TEST_ROOT/fixed-root" <<'PY'
import pathlib
import re
import sys

source, output, prefix = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
start = text.index("rr_restore_ip_acme_fixed_parent_is_safe()")
end = text.index("rr_restore_ip_acme_removal_marker_is_safe()", start)
fragment = text[start:end]
mapping = {
    "/etc/systemd/system/rr-nexus-ip-acme.service": prefix + "/etc/systemd/system/rr-nexus-ip-acme.service",
    "/etc/systemd/system/rr-nexus-ip-acme.timer": prefix + "/etc/systemd/system/rr-nexus-ip-acme.timer",
    "/usr/local/lib/rr-vps/lego.install": prefix + "/usr/local/lib/rr-vps/lego.install",
    "/usr/local/lib/rr-vps/lego": prefix + "/usr/local/lib/rr-vps/lego",
    "/etc/systemd/system": prefix + "/etc/systemd/system",
    "/usr/local/lib/rr-vps": prefix + "/usr/local/lib/rr-vps",
}
pattern = re.compile("|".join(re.escape(value) for value in sorted(mapping, key=len, reverse=True)))
pathlib.Path(output).write_text(pattern.sub(lambda match: mapping[match.group()], fragment), encoding="utf-8")
PY
mkdir -p "$TEST_ROOT/fixed-root/etc/systemd/system" \
    "$TEST_ROOT/fixed-root/usr/local/lib/rr-vps"
chmod -R go-w "$TEST_ROOT/fixed-root"
# shellcheck disable=SC1090
source "$TEST_ROOT/fixed-parent-function.sh"
rr_restore_ip_acme_fixed_parent_is_safe \
    "$TEST_ROOT/fixed-root/etc/systemd/system/rr-nexus-ip-acme.service" || \
    fail 'safe fixed unit parent was rejected'
mkdir -p "$TEST_ROOT/fixed-victim"
printf 'survive\n' > "$TEST_ROOT/fixed-victim/sentinel"
rmdir "$TEST_ROOT/fixed-root/usr/local/lib/rr-vps"
ln -s "$TEST_ROOT/fixed-victim" "$TEST_ROOT/fixed-root/usr/local/lib/rr-vps"
if rr_restore_ip_acme_fixed_parent_is_safe "$TEST_ROOT/fixed-root/usr/local/lib/rr-vps/lego"; then
    fail 'fixed lego parent symlink was accepted'
fi
[ "$(cat "$TEST_ROOT/fixed-victim/sentinel")" = survive ] || fail 'fixed-parent victim changed'
pass 'unit and lego deletion parents are canonical and non-writable'

ABSENT_FIXTURE="$TEST_ROOT/absent-root"
python3 - "$INSTALLER" "$TEST_ROOT/absent-function.sh" "$ABSENT_FIXTURE" <<'PY'
import pathlib
import re
import sys

source, output, prefix = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
start = text.index("rr_ip_acme_exclusive_artifacts_are_absent()")
end = text.index("rr_capture_ip_acme_update_state()", start)
fragment = text[start:end]
paths = [
    "/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf",
    "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
    "/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf",
    "/etc/systemd/system/rr-nexus-ip-acme.service",
    "/etc/systemd/system/rr-nexus-ip-acme.timer",
    "/etc/rr-nexus/certs/.ip-cert-pending",
    "/usr/local/lib/rr-vps/nexus-ip-cert-gate",
    "/usr/local/lib/rr-vps/lego.install",
    "/usr/local/lib/rr-vps/lego",
]
mapping = {path: prefix + path for path in paths}
pattern = re.compile("|".join(re.escape(value) for value in sorted(mapping, key=len, reverse=True)))
pathlib.Path(output).write_text(pattern.sub(lambda match: mapping[match.group()], fragment), encoding="utf-8")
PY
mkdir -p "$ABSENT_FIXTURE"
# shellcheck disable=SC1090
source "$TEST_ROOT/absent-function.sh"
RR_IP_ACME_STATE_ROOT="$ABSENT_FIXTURE/var/lib/rr-nexus/ip-acme"
RR_IP_ACME_WEBROOT="$ABSENT_FIXTURE/var/www/rr-nexus-ip-acme"
rr_ip_acme_exclusive_artifacts_are_absent || fail 'clean absent state was rejected'
for residual in \
    "$RR_IP_ACME_STATE_ROOT" "$RR_IP_ACME_WEBROOT" \
    "$ABSENT_FIXTURE/etc/systemd/system/rr-nexus-ip-acme.service" \
    "$ABSENT_FIXTURE/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf" \
    "$ABSENT_FIXTURE/etc/rr-nexus/certs/.ip-cert-pending" \
    "$ABSENT_FIXTURE/usr/local/lib/rr-vps/lego"; do
    mkdir -p "$(dirname -- "$residual")"
    : > "$residual"
    if rr_ip_acme_exclusive_artifacts_are_absent; then
        fail "absent state accepted residual $residual"
    fi
    rm -f -- "$residual"
done
pass 'absent state rejects every exclusively ACME-owned residual artifact'

(
    # shellcheck disable=SC1090
    RR_LIB_DIR="$REPO_ROOT"
    RR_REPOSITORY=Xiaowu7z/RR-vps
    source "$REPO_ROOT/modules/85-nexus.sh"
    NEXUS_NGINX_AVAILABLE_DIR="$TEST_ROOT/nginx/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$TEST_ROOT/nginx/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR"
    chmod 755 "$TEST_ROOT/nginx" "$NEXUS_NGINX_AVAILABLE_DIR" \
        "$NEXUS_NGINX_ENABLED_DIR"
    printf 'foreign same-name site\n' > "$NEXUS_NGINX_SITE"
    chmod 644 "$NEXUS_NGINX_SITE"
    if nexus_nginx_managed_paths_are_owned; then
        fail 'foreign same-name Nexus Nginx file was accepted'
    fi
)
(
    # shellcheck disable=SC1090
    source "$RESTORE"
    touched="$TEST_ROOT/foreign-unlink-called"
    rr_restore_nginx_snapshot_paths_are_owned() { return 0; }
    nexus_nginx_managed_paths_are_owned() { return 1; }
    nexus_nginx_unlink_owned_path() { : > "$touched"; return 0; }
    nexus_nginx_restore_snapshot_path() { : > "$touched"; return 0; }
    nexus_ip_acme_parent_directory_is_safe() { return 0; }
    if rr_restore_restore_nginx_files "$TEST_ROOT/nonexistent-rollback"; then
        fail 'rollback accepted a foreign Nginx collision'
    fi
    [ ! -e "$touched" ]
)
pass 'foreign same-name Nexus Nginx paths fail before the first unlink'

(
    # shellcheck disable=SC1090
    source "$RESTORE"
    probe="$TEST_ROOT/readonly-probe"
    mkdir -p "$probe"
    nexus_ip_acme_runtime_is_ready() {
        [ "${1:-}" = 203.0.113.9 ] || return 1
        : > "$probe/called"
    }
    rr_restore_ip_acme_runtime_readonly_is_ready 203.0.113.9
    [ -f "$probe/called" ]
)
pass 'target capture delegates to the canonical read-only runtime proof'

(
    # shellcheck disable=SC1090
    source "$RESTORE"
    capture_root="$TEST_ROOT/capture-absent"
    rollback="$capture_root/rollback"
    mkdir -p "$rollback"
    printf '%s\n' \
        '{"mode":"local","domain":"","public_port":7900,"certificate_mode":"none"}' \
        > "$rollback/target-nexus-access.json"
    NEXUS_IP_ACME_STATE_ROOT="$capture_root/state"
    NEXUS_IP_ACME_WEBROOT="$capture_root/webroot"
    NEXUS_IP_ACME_SERVICE_FILE="$capture_root/service"
    NEXUS_IP_ACME_TIMER_FILE="$capture_root/timer"
    NEXUS_IP_ACME_NGINX_AVAILABLE="$capture_root/http-site"
    NEXUS_IP_ACME_NGINX_ENABLED="$capture_root/http-link"
    NEXUS_IP_ACME_LEGO_BIN="$capture_root/lego"
    NEXUS_IP_ACME_LEGO_MARKER="$capture_root/lego.install"
    NEXUS_IP_ACME_LIVE_CERT="$capture_root/certs/ip.crt"
    NEXUS_IP_ACME_LIVE_KEY="$capture_root/certs/ip.key"
    NEXUS_IP_ACME_PENDING="$capture_root/pending"
    RR_RESTORE_NEXUS_GATE_EXEC_PATH="$capture_root/gate"
    RR_RESTORE_SYSTEMD_DIR="$capture_root/systemd"
    gate_exact=true
    nexus_ip_certificate_pair_is_ready() { return 0; }
    nexus_ip_certificate_gate_artifacts_are_current() {
        [ "$gate_exact" = true ]
    }
    nexus_nginx_exec_condition_set_is_exact() { [ "$gate_exact" = true ]; }
    is_ip_version() { [ "$1" = 203.0.113.9 ] && [ "$2" = 4 ]; }
    rr_restore_capture_target_ip_acme_state "$rollback" || \
        fail 'clean non-ACME target was rejected'
    rm -f "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME"
    for residual in "$NEXUS_IP_ACME_PENDING" \
        "$RR_RESTORE_NEXUS_GATE_EXEC_PATH" \
        "$RR_RESTORE_SYSTEMD_DIR/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"; do
        mkdir -p "$(dirname -- "$residual")"
        : > "$residual"
        if rr_restore_capture_target_ip_acme_state "$rollback"; then
            fail "portable target capture accepted ACME residual $residual"
        fi
        rm -f -- "$residual"
    done
    mkdir -p "$(dirname -- "$RR_RESTORE_NEXUS_GATE_EXEC_PATH")" \
        "$(dirname -- "$RR_RESTORE_SYSTEMD_DIR/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME")"
    : > "$RR_RESTORE_NEXUS_GATE_EXEC_PATH"
    : > "$RR_RESTORE_SYSTEMD_DIR/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
    if rr_restore_capture_target_ip_acme_state "$rollback"; then
        fail 'gate pair without a legacy certificate pair was accepted'
    fi
    rm -f "$RR_RESTORE_NEXUS_GATE_EXEC_PATH" \
        "$RR_RESTORE_SYSTEMD_DIR/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"

    printf '%s\n' \
        '{"mode":"public","domain":"203.0.113.9","public_port":8443,"certificate_mode":"legacy-self-signed"}' \
        > "$rollback/target-nexus-access.json"
    mkdir -p "$(dirname -- "$NEXUS_IP_ACME_LIVE_CERT")"
    : > "$NEXUS_IP_ACME_LIVE_CERT"
    : > "$NEXUS_IP_ACME_LIVE_KEY"
    rr_restore_capture_target_ip_acme_state "$rollback" || \
        fail 'exact legacy pair with absent gate was rejected'
    : > "$RR_RESTORE_NEXUS_GATE_EXEC_PATH"
    : > "$RR_RESTORE_SYSTEMD_DIR/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
    rr_restore_capture_target_ip_acme_state "$rollback" || \
        fail 'exact legacy pair with exact effective gate was rejected'
    gate_exact=false
    if rr_restore_capture_target_ip_acme_state "$rollback"; then
        fail 'foreign legacy gate pair was accepted'
    fi
)
pass 'portable target capture enforces the exact legacy cert/gate matrix'

(
    # shellcheck disable=SC1090
    RR_LIB_DIR="$REPO_ROOT"
    RR_REPOSITORY=Xiaowu7z/RR-vps
    source "$REPO_ROOT/modules/85-nexus.sh"
    source "$RESTORE"
    mode_root="$TEST_ROOT/nginx-mode"
    available="$mode_root/etc/nginx/sites-available"
    enabled="$mode_root/etc/nginx/sites-enabled"
    mkdir -p "$available" "$enabled"
    chmod 750 "$mode_root/etc/nginx"
    chmod 700 "$available"
    chmod 750 "$enabled"
    NEXUS_NGINX_TRUST_ROOT="$mode_root"
    rr_restore_prepare_nginx_snapshot_destinations "$available" "$enabled"
    [ "$(stat -c %a -- "$available")" = 700 ] && \
        [ "$(stat -c %a -- "$enabled")" = 750 ] || \
        fail 'existing Nginx directory mode was changed'
    rmdir "$enabled"
    rr_restore_prepare_nginx_snapshot_destinations "$available" "$enabled"
    [ "$(stat -c %a -- "$available")" = 700 ] && \
        [ "$(stat -c %a -- "$enabled")" = 755 ]
)
pass 'Nginx restore preserves existing directory modes and safely creates only missing dirs'

(
    # shellcheck disable=SC1090
    source "$RESTORE"
    NEXUS_CONFIG_FILE="$TEST_ROOT/nexus-firewall.json"
    printf '%s\n' \
        '{"mode":"public","domain":"203.0.113.9","public_port":8443,"certificate_mode":"acme-ip-shortlived"}' \
        > "$NEXUS_CONFIG_FILE"
    load_config_with_defaults() {
        VM_TLS_ENABLED=false SUB_PORT=7900 SUB_ACCESS_MODE=local
        VL_ENABLED=false HY2_ENABLED=false TU5_ENABLED=false AN_ENABLED=false NAIVE_ENABLED=false
    }
    is_valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
    is_global_ip_version() { return 0; }
    rr_restore_candidate_firewall_keys "$TEST_ROOT/firewall-keys"
    grep -Fxq '80/tcp open' "$TEST_ROOT/firewall-keys"
    grep -Fxq '8443/tcp open' "$TEST_ROOT/firewall-keys"
)
pass 'short-lived IP ACME restore retains the TCP/80 firewall consumer'

python3 - "$INSTALLER" "$RESTORE" "$IP_ACME_CORE" <<'PY'
import pathlib
import re
import sys

installer = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
restore = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
core = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")

def function(text: str, name: str, next_name: str) -> str:
    start = text.index(name + "()")
    end = text.index(next_name + "()", start)
    return text[start:end]

directory_restore = function(installer, "rr_restore_ip_acme_update_directories", "rr_restore_ip_acme_update_writer_state")
assert re.search(r"(?m)^\s*rr_restore_dir(?:\s|$)", directory_restore) is None
assert 'ip_acme_directories_complete' in installer
assert 'rr_set_private_marker "$BACKUP_DIR/had_nexus_ip_acme_state"' in installer
assert 'rr_set_private_marker "$BACKUP_DIR/had_nexus_ip_acme_webroot"' in installer
exclusive = function(installer, "rr_ip_acme_exclusive_artifacts_are_absent", "rr_ip_acme_candidate_legacy_access_plane_is_exact")
assert "nexus-ip-cert-gate" not in exclusive
assert "rr_ip_acme_legacy_absent_state_is_exact" in installer

capture = function(restore, "rr_restore_capture_target_ip_acme_state", "rr_restore_snapshot_target_ip_acme_state")
assert "rr_restore_ip_acme_runtime_readonly_is_ready" in capture
readiness = function(core, "nexus_ip_acme_runtime_is_ready", "nexus_ip_acme_disarm_locked")
for mutator in (
    "nexus_ip_acme_prepare_state_root",
    "nexus_ip_acme_ensure_gate",
    "nexus_ip_acme_install_units",
    "systemctl daemon-reload",
    "systemctl start",
    "systemctl stop",
):
    assert mutator not in readiness
replace = function(restore, "rr_restore_replace_target_ip_acme_state", "rr_restore_disarm_target_ip_acme")
assert "unlink /usr/local/lib/rr-vps/lego /usr/local/lib/rr-vps/lego.install" not in replace
assert "rr_restore_ip_acme_fixed_parent_is_safe" in replace
assert "rr_restore_authorize_ip_acme_runtime_removal" in replace
nginx_restore = function(restore, "rr_restore_restore_nginx_files", "rr_restore_activate_nginx_state")
assert "install -d -m 755 /etc/nginx" not in nginx_restore
assert "rr_restore_nginx_snapshot_paths_are_owned" in nginx_restore
assert "nexus_nginx_restore_snapshot_path" in nginx_restore
cleanup = function(installer, "rr_cleanup", "rr_fetch_release")
assert "rr_republish_retryable_update_phase" in cleanup
assert "rr_write_phase recovery_failed" not in cleanup
PY
pass 'rollback avoids generic double-delete and publishes crash-durable directory evidence'

printf 'All %d IP-ACME restore/update tests passed.\n' "$pass_count"
