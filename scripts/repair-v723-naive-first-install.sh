#!/bin/bash
# Targeted recovery for VM8334-82's verified RR-vps 7.2.3 first-install state.
# Keeps the installed release bytes and all existing protection drop-ins.
set -o pipefail
if [ "${1:-}" != --internal ]; then
    if [ "$#" -ne 0 ] && { [ "$#" -ne 1 ] || [ "$1" != --check ]; }; then
        echo 'Usage: bash repair-v723-naive-first-install.sh [--check]'; exit 2
    fi
    exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=dumb SSH_CONNECTION="${SSH_CONNECTION:-}" \
        /bin/bash --noprofile --norc "$0" --internal "$@"
fi
repair_check_only=false
case "$#:${2:-}" in
    1:) ;;
    2:--check) repair_check_only=true ;;
    *) exit 2 ;;
esac
umask 077
[ "$(id -u)" = 0 ] && [ "$(hostname)" = VM8334-82 ] || {
    echo 'REPAIR_STOP phase=host_identity'; exit 1;
}
repair_stage=$(mktemp -d /root/rr-repair-naive723.XXXXXX) || exit 1
chmod 700 "$repair_stage" || exit 1
repair_phase=preflight
exec 3>&1
exec >"$repair_stage/repair.log" 2>&1
printf '日志目录（配置备份须取得写锁后才开始）：%s\n' "$repair_stage" >&3

repair_verify_runtime() {
    python3 - "$repair_stage" "$1" <<'PY'
import hashlib, os, re, stat, sys
from pathlib import Path
stage, copy = Path(sys.argv[1]), sys.argv[2] == 'copy'
root = Path('/usr/local/lib/rr')
def safe(path):
    for parent in reversed(path.parents):
        s = parent.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError('unsafe_parent')
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_gid != 0 or s.st_nlink != 1 or s.st_mode & 0o022:
        raise ValueError('unsafe_file')
    return path.read_bytes()
try:
    osinfo = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    assert osinfo['ID'].strip('"') == 'debian' and osinfo['VERSION_ID'].strip('"') == '12'
    manifest = safe(root / 'manifest.sha256')
    assert hashlib.sha256(manifest).hexdigest() == '87d5f85a0a4232882c97b54adbd49dfdc93b79beeca77fb59ee873aee366ce64'
    modules = {}
    for line in manifest.decode().splitlines():
        digest, name = line.split(None, 1)
        assert re.fullmatch('[0-9a-f]{64}', digest)
        assert not name.startswith('/') and '..' not in Path(name).parts
        path = Path('/usr/local/bin/rr') if name == 'rr' else root / name
        data = safe(path)
        assert hashlib.sha256(data).hexdigest() == digest, name
        if name.startswith('modules/'):
            modules[Path(name).name] = data
        if name in ('scripts/update-recover.sh', 'scripts/update-external-state.py'):
            installed = Path('/usr/local/sbin') / ('rr-update-recover' if name.endswith('.sh') else 'rr-update-external-state')
            assert safe(installed) == data
    guard = safe(root / 'modules/61-update-guard.sh')
    assert hashlib.sha256(guard).hexdigest() == '2bbfdd8d80773cb48c19f11f91bbeb7ebd156f9419c30c5d81b3565aa346e64c'
    modules['61-update-guard.sh'] = guard
    assert {p.name for p in (root / 'modules').glob('*.sh')} == set(modules)
    if copy:
        target = stage / 'modules'
        target.mkdir(mode=0o700)
        for name, data in modules.items():
            (target / name).write_bytes(data)
except (AssertionError, OSError, ValueError) as error:
    print('Runtime or host preflight refused:', type(error).__name__)
    raise SystemExit(1)
PY
}

repair_verify_runtime copy || { echo 'REPAIR_STOP phase=runtime_identity' >&3; exit 1; }
# Exercise the reviewed candidate ownership check from a private copy. The
# installed launcher, modules and manifest remain the immutable 7.2.3 bytes.
repair_candidate_commit='cfeda272431beaffd03568c7a80c6934927f826a'
repair_candidate_module_sha256='dfd6929c22576a49eff09a4c931a958c410225b009f9d96a5679371d8c3ee566'
if [[ ! "$repair_candidate_commit" =~ ^[0-9a-f]{40}$ ]] || \
   [[ ! "$repair_candidate_module_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'REPAIR_STOP phase=candidate_not_pinned' >&3
    exit 1
fi
repair_candidate_file="$repair_stage/candidate-30-singbox.sh"
if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 15 \
    --max-time 90 --output "$repair_candidate_file" \
    "https://raw.githubusercontent.com/Xiaowu7z/RR-vps/$repair_candidate_commit/modules/30-singbox.sh" || \
   ! printf '%s  %s\n' "$repair_candidate_module_sha256" "$repair_candidate_file" | sha256sum -c - || \
   ! /bin/bash -n "$repair_candidate_file" || \
   ! mv -- "$repair_candidate_file" "$repair_stage/modules/30-singbox.sh"; then
    echo 'REPAIR_STOP phase=candidate_identity' >&3
    exit 1
fi
for repair_module in "$repair_stage"/modules/*.sh; do
    # shellcheck disable=SC1090
    source "$repair_module" || { echo 'REPAIR_STOP phase=load_runtime' >&3; exit 1; }
done

repair_note() {
    repair_phase="$1"
    printf '%s\n' "$repair_phase" >"$repair_stage/phase" || return 1
    printf 'REPAIR_STEP phase=%s\n' "$repair_phase" >&3
}

repair_no_markers() {
    local path=""
    for path in /var/lib/rr-vps/firewall-quarantine /var/lib/rr-backup/active \
        /run/rr-vps/restore-live /run/rr-vps/restore-watch-request \
        /etc/sing-box/.pair-pending /etc/rr-naive/.pair-pending; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    done
}

repair_nexus_absent() {
    local path="" state=""
    for path in "$NEXUS_CONFIG_FILE" "$NEXUS_DB_FILE"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    done
    state=$(systemctl show rr-nexus.service -p LoadState --value) || return 1
    [ "$state" = not-found ]
}

# This diagnostic uses exactly the predicates required by recovery. It neither
# reads configuration values nor runs the configuration/certificate builders.
# Every independent check is reported before a failing preflight returns.
repair_preflight_path_metadata() {
    python3 - "$1" >&3 <<'PY'
import json, os, stat, sys
from pathlib import Path
path = Path(sys.argv[1])
for item in list(reversed(path.parents)) + [path]:
    record = {'event': 'REPAIR_PATH', 'path': str(item)}
    try:
        info = item.lstat()
        record.update(uid=info.st_uid, gid=info.st_gid,
                      mode=oct(stat.S_IMODE(info.st_mode)), links=info.st_nlink,
                      exists=item.exists(), symlink=stat.S_ISLNK(info.st_mode),
                      type=('directory' if stat.S_ISDIR(info.st_mode) else
                            'regular' if stat.S_ISREG(info.st_mode) else
                            'symlink' if stat.S_ISLNK(info.st_mode) else 'other'),
                      realpath=os.path.realpath(item))
    except OSError as error:
        record.update(error=type(error).__name__, errno=error.errno)
    print(json.dumps(record, ensure_ascii=True))
PY
}

repair_preflight_check() {
    local name="$1" result=0 outcome=PASS
    shift
    "$@" || result=$?
    if [ "$result" -ne 0 ]; then
        outcome=FAIL
        repair_preflight_failed=$((repair_preflight_failed + 1))
    fi
    repair_preflight_total=$((repair_preflight_total + 1))
    printf 'REPAIR_CHECK name=%s result=%s rc=%s\n' "$name" "$outcome" "$result" >&3
}

repair_preflight_absent() {
    local path="$1"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi
    repair_preflight_path_metadata "$path" || true
    return 1
}

repair_preflight_directory() {
    local path="$1" result=0
    rr_firewall_root_directory_chain_is_safe "$path" || result=$?
    [ "$result" -eq 0 ] || repair_preflight_path_metadata "$path" || true
    return "$result"
}

repair_preflight_config_metadata() {
    local path="$1"
    if [ -f "$path" ] && [ ! -L "$path" ] && \
       [ "$(stat -c '%u:%g:%a:%h' -- "$path")" = 0:0:600:1 ]; then
        return 0
    fi
    repair_preflight_path_metadata "$path" || true
    return 1
}

repair_preflight_systemd() {
    local unit="$1" property="$2" predicate="$3" expected="$4"
    local require_success="$5" value="" command_rc=0
    # Only non-secret unit metadata may enter the terminal report.
    case "$unit" in
        sing-box.service|rr-nexus.service|rr-subscription.service|\
        argo-rr-health.timer|argo-rr-health.service) ;;
        *) return 2 ;;
    esac
    case "$property" in LoadState|ActiveState|FragmentPath|DropInPaths) ;; *) return 2 ;; esac
    value=$(systemctl show "$unit" -p "$property" --value) || command_rc=$?
    printf 'REPAIR_UNIT unit=%s property=%s value=%q command_rc=%s\n' \
        "$unit" "$property" "$value" "$command_rc" >&3
    # The original predicates differ: some compare command output only, while
    # others also require systemctl to succeed. Preserve that distinction.
    if [ "$require_success" = true ] && [ "$command_rc" -ne 0 ]; then
        return 1
    fi
    case "$predicate" in
        equal) [ "$value" = "$expected" ] ;;
        idle) case "$value" in inactive|failed) return 0 ;; *) return 1 ;; esac ;;
        *) return 2 ;;
    esac
}

repair_preflight_dropin_members() {
    local directory=/etc/systemd/system/sing-box.service.d members="" command_rc=0
    members=$(find "$directory" -mindepth 1 -maxdepth 1 -printf '%f\n') || command_rc=$?
    printf 'REPAIR_DROPINS directory=%s members=%q command_rc=%s\n' \
        "$directory" "$members" "$command_rc" >&3
    if [ "$members" = zzzzz-rr-firewall-quarantine.conf ]; then
        return 0
    fi
    repair_preflight_path_metadata "$directory" || true
    return 1
}

repair_preflight_dropin_exact() {
    local path=/etc/systemd/system/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf result=0
    rr_firewall_fail_closed_dropin_is_exact "$path" /var/lib/rr-vps/firewall-quarantine || result=$?
    [ "$result" -eq 0 ] || repair_preflight_path_metadata "$path" || true
    return "$result"
}

repair_preflight_checks() {
    local path="" name=""
    repair_preflight_total=0
    repair_preflight_failed=0
    repair_preflight_check runtime_identity repair_verify_runtime check
    for path in /var/lib/rr-vps/firewall-quarantine /var/lib/rr-backup/active \
        /run/rr-vps/restore-live /run/rr-vps/restore-watch-request \
        /etc/sing-box/.pair-pending /etc/rr-naive/.pair-pending; do
        name=${path//\//_}
        repair_preflight_check "absent${name}" repair_preflight_absent "$path"
    done
    for path in /etc/systemd/system /etc/systemd/system/sing-box.service.d /var/lib/rr-vps \
        /etc/sing-box /etc/rr-naive /etc/letsencrypt /run/rr-vps; do
        name=${path//\//_}
        repair_preflight_check "directory${name}" repair_preflight_directory "$path"
    done
    for path in /etc/argo_vmess.conf /etc/sing-box/config.json; do
        name=${path//\//_}
        repair_preflight_check "metadata${name}" repair_preflight_config_metadata "$path"
    done
    repair_preflight_check singbox_unit_file_absent repair_preflight_absent /etc/systemd/system/sing-box.service
    repair_preflight_check singbox_load_state repair_preflight_systemd sing-box.service LoadState equal not-found false
    repair_preflight_check singbox_fragment_absent repair_preflight_systemd sing-box.service FragmentPath equal '' false
    repair_preflight_check singbox_effective_dropins_absent repair_preflight_systemd sing-box.service DropInPaths equal '' false
    repair_preflight_check singbox_dropin_members repair_preflight_dropin_members
    repair_preflight_check singbox_dropin_exact repair_preflight_dropin_exact
    # Keep all three predicates from repair_nexus_absent, but report them
    # separately so a file, database or manager-state mismatch is distinguishable.
    repair_preflight_check nexus_config_absent repair_preflight_absent "$NEXUS_CONFIG_FILE"
    repair_preflight_check nexus_database_absent repair_preflight_absent "$NEXUS_DB_FILE"
    repair_preflight_check nexus_load_state repair_preflight_systemd rr-nexus.service LoadState equal not-found true
    repair_preflight_check subscription_load_state repair_preflight_systemd rr-subscription.service LoadState equal not-found false
    for path in sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.timer argo-rr-health.service; do
        repair_preflight_check "inactive_${path}" repair_preflight_systemd "$path" ActiveState idle '' true
    done
    printf 'REPAIR_PREFLIGHT total=%s failed=%s recovery_performed=false\n' \
        "$repair_preflight_total" "$repair_preflight_failed" >&3
    [ "$repair_preflight_failed" -eq 0 ]
}

# Reject inputs that the stock builder would silently regenerate. This is a
# recovery of existing identity, not an opportunity to create new credentials.
repair_credentials_ready() {
    local variable="" pin=""
    is_valid_uuid "$UUID" || return 1
    [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{32}$ ]] || return 1
    [ -n "$NAIVE_USER" ] && [ -n "$NAIVE_PASS" ] || return 1
    for variable in UUID SUB_TOKEN NAIVE_USER NAIVE_PASS PRIVATE_KEY \
        PUBLIC_KEY SHORT_ID CERT_SHA256; do
        is_masked_credential "${!variable}" && return 1
    done
    rr_certificate_private_key_pair_matches \
        /etc/sing-box/cert.pem /etc/sing-box/private.key || return 1
    pin=$(openssl x509 -in /etc/sing-box/cert.pem -outform DER | sha256sum) || return 1
    [ "${pin%% *}" = "$CERT_SHA256" ] || return 1
    [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] && \
        [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] && \
        [[ "$SHORT_ID" =~ ^[0-9a-fA-F]{8}$ ]] || return 1
    [ "$(rr_reality_public_from_private "$PRIVATE_KEY")" = "$PUBLIC_KEY" ]
}

# LE live entries are legitimate symlinks; record both their resolved targets
# and bytes, while requiring ordinary root-owned files under trusted parents.
repair_material_digest() {
    python3 - "$NAIVE_DOMAIN" <<'PY'
import hashlib, json, stat, sys
from pathlib import Path
domain = sys.argv[1]
paths = [Path('/etc/sing-box/cert.pem'), Path('/etc/sing-box/private.key'),
         Path('/etc/rr-naive/fullchain.pem'), Path('/etc/rr-naive/privkey.pem')]
paths += [Path('/etc/letsencrypt/live') / domain / name
          for name in ('cert.pem', 'chain.pem', 'fullchain.pem', 'privkey.pem')]
for path in paths:
    resolved = path.resolve(strict=True)
    if not str(path).startswith('/etc/letsencrypt/live/') and resolved != path:
        raise SystemExit('non_LE_material_symlink')
    if str(path).startswith('/etc/letsencrypt/live/'):
        expected = Path('/etc/letsencrypt/archive') / domain
        if resolved.parent != expected:
            raise SystemExit('unexpected_LE_archive')
    for parent in reversed(resolved.parents):
        s = parent.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise SystemExit('unsafe_material_parent')
    s = resolved.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_gid != 0 or s.st_nlink != 1 or s.st_mode & 0o022:
        raise SystemExit('unsafe_material_file')
    print(json.dumps([str(path), str(resolved), hashlib.sha256(resolved.read_bytes()).hexdigest()]))
PY
}

repair_identity() {
    local variable=""
    for variable in UUID PRIVATE_KEY PUBLIC_KEY SHORT_ID CERT_SHA256 \
        PORT ARGO_EDGE_PORT SUB_PORT SUB_PUBLIC_PORT_IPV4 SUB_PUBLIC_PORT_IPV6 \
        SUB_ACCESS_MODE SUB_DOMAIN SUB_TOKEN CDN_IP TUNNEL_MODE \
        VM_ENABLED VM_TLS_ENABLED VL_ENABLED VL_PORT HY2_ENABLED HY2_PORT \
        HY2_HOP_PORTS HY2_HOP_INTERVAL TU5_ENABLED TU5_PORT TU5_HOP_PORTS \
        AN_ENABLED AN_PORT NAIVE_ENABLED NAIVE_PORT NAIVE_MODE NAIVE_QUIC_CC \
        NAIVE_USER NAIVE_PASS NAIVE_DOMAIN ENTRY_IP_MODE OUTBOUND_IP_MODE \
        ENTRY_IPV4_ADDRESS ENTRY_IPV6_ADDRESS VM_PREVIOUS_PORT \
        CLASH_ENABLED SINGBOX_AUTO_RESTART HB_ENABLED HB_INTERVAL LE_EMAIL CONFIG_VERSION; do
        declare -p "$variable" || return 1
    done
}

repair_capture() {
    local path="" backend=""
    local -a paths=()
    for path in etc/argo_vmess.conf etc/sing-box etc/rr-naive \
        etc/systemd/system/sing-box.service.d var/lib/rr-vps \
        etc/iptables etc/nginx/sites-available etc/nginx/sites-enabled \
        etc/letsencrypt etc/systemd/system/rr-subscription.service \
        etc/systemd/system/rr-subscription.service.d \
        etc/systemd/system/argo-rr-health.service \
        etc/systemd/system/argo-rr-health.service.d \
        etc/systemd/system/argo-rr-health.timer \
        etc/systemd/system/rr-firewall-quarantine-guard.service \
        etc/systemd/system/rr-firewall-quarantine-guard.path \
        etc/systemd/system/rr-firewall-quarantine-guard.timer \
        usr/local/sbin/rr-firewall-quarantine-guard; do
        [ ! -e "/$path" ] && [ ! -L "/$path" ] || paths+=("$path")
    done
    tar -C / -czf "$repair_stage/before.tar.gz" -- "${paths[@]}" || return 1
    for backend in iptables ip6tables; do
        "$backend-save" >"$repair_stage/$backend.rules" || return 1
    done
    systemctl show sing-box.service nginx.service rr-nexus.service \
        rr-firewall-quarantine-guard.service rr-firewall-quarantine-guard.path \
        rr-firewall-quarantine-guard.timer argo-rr-health.timer \
        -p Id -p LoadState -p ActiveState -p UnitFileState -p Result \
        -p ExecMainCode -p ExecMainStatus -p FragmentPath -p DropInPaths \
        --no-pager >"$repair_stage/units-before.txt" || return 1
    journalctl -u rr-firewall-quarantine-guard.service -u sing-box.service \
        -n 100 --no-pager -o short-iso >"$repair_stage/journal-before.txt" || return 1
    repair_identity >"$repair_stage/identity-before.txt" || return 1
    repair_material_digest >"$repair_stage/material-before.txt" || return 1
    sha256sum "$repair_stage/before.tar.gz" >"$repair_stage/backup.sha256"
}

repair_add_missing_unit() {
    local candidate=""
    # This is the actual candidate predicate that fixes the reported first
    # installation conflict. Never replace it with a stub or force success.
    rr_singbox_service_is_owned_or_absent || return 1
    printf 'CANDIDATE_OWNERSHIP_CHECK_OK source=%s\n' "$repair_candidate_commit" >&3 || return 1
    candidate=$(mktemp /etc/systemd/system/.rr-repair-sing-box.XXXXXX) || return 1
    if ! rr_render_singbox_systemd_unit >"$candidate" || \
       ! chmod 644 "$candidate" || ! chown 0:0 "$candidate" || ! sync -f "$candidate"; then
        rm -f -- "$candidate"; return 1
    fi
    # Atomic create without replacement; a concurrently created unit is refused.
    if ! ln -- "$candidate" /etc/systemd/system/sing-box.service; then
        rm -f -- "$candidate"; return 1
    fi
    repair_unit_created=true
    rm -f -- "$candidate" || return 1
    sync -f /etc/systemd/system || return 1
    systemctl daemon-reload || return 1
    rr_singbox_service_guards_are_effective
}

repair_locked() {
    # These are deliberately NOT local. The wrapper's isolated shell invokes
    # EXIT after this callback has returned and its locals have gone away.
    repair_unit_created=false
    repair_mutation_started=false
    repair_finished=false
    repair_health_started=false
    # This trap runs in rr_run_with_update_locks' isolated, lock-held callback.
    trap 'repair_exit $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    repair_note locked_preflight || return 1
    repair_preflight_checks || return 1
    if [ "$repair_check_only" = true ]; then
        printf 'PREFLIGHT_ONLY_OK recovery_performed=false\n' >&3 || return 1
        repair_finished=true
        return 0
    fi
    repair_note existing_configuration || return 1
    load_config_with_defaults || return 1
    [ "$SCRIPT_VERSION" = 7.2.3 ] && [ "$INSTALL_COMPLETE" = false ] || return 1
    [ "$NAIVE_ENABLED" = true ] && [ "$NAIVE_DOMAIN" = lam.188199201.xyz ] || return 1
    [ "$VM_ENABLED" = true ] && [ "$VM_TLS_ENABLED" = false ] && [ "$TUNNEL_MODE" = 1 ] || return 1
    [ -z "$ARGO_DOMAIN" ] || return 1
    managed_singbox_running && return 1
    quick_argo_running && return 1
    subscription_server_running && return 1
    repair_note preserve_evidence || return 1
    repair_capture || return 1

    repair_note existing_identity || return 1
    cloudflared_token_file_supported || return 1
    repair_credentials_ready || return 1
    repair_note existing_certificate || return 1
    naive_certificate_pair_valid /etc/rr-naive/fullchain.pem /etc/rr-naive/privkey.pem "$NAIVE_DOMAIN" || return 1
    naive_certificate_pair_valid "/etc/letsencrypt/live/$NAIVE_DOMAIN/fullchain.pem" \
        "/etc/letsencrypt/live/$NAIVE_DOMAIN/privkey.pem" "$NAIVE_DOMAIN" || return 1
    rr_certbot_webroot_lineage_is_renewable "$NAIVE_DOMAIN" || return 1
    rr_certbot_renewal_runtime_is_ready "$NAIVE_DOMAIN" || return 1
    rr_certificate_deploy_hook_is_current || return 1
    "$SINGBOX_BIN" check -c /etc/sing-box/config.json || return 1
    rr_firewall_quarantine_supervisor_effective || return 1

    repair_note create_missing_service || return 1
    repair_add_missing_unit || return 1
    repair_no_markers || return 1
    # Preserve previous failure evidence, then actually run the verified guard
    # in its no-marker idle branch rather than merely clearing its failed flag.
    repair_note settle_idle_guard || return 1
    systemctl start rr-firewall-quarantine-guard.service || return 1
    rr_firewall_deactivate_quarantine_retry || return 1
    rr_firewall_activate_idle_quarantine_supervisor || return 1

    repair_mutation_started=true
    repair_note build_existing_config || return 1
    build_singbox_config || return 1
    load_config_with_defaults || return 1
    repair_identity >"$repair_stage/identity-current.txt" || return 1
    cmp -s "$repair_stage/identity-before.txt" "$repair_stage/identity-current.txt" || return 1
    repair_material_digest >"$repair_stage/material-current.txt" || return 1
    cmp -s "$repair_stage/material-before.txt" "$repair_stage/material-current.txt" || return 1
    repair_note reconcile_firewall || return 1
    open_configured_firewall || return $?
    repair_no_markers || return 1
    repair_note start_singbox || return 1
    setup_systemd || return 1
    managed_singbox_running || return 1
    repair_note start_argo || return 1
    start_argo_tunnel || return 1
    expected_argo_tunnel_running || return 1
    repair_note subscriptions || return 1
    generate_node_and_sub || return 1
    subscription_server_running || return 1
    repair_note health_monitor || return 1
    repair_health_started=true
    setup_health_monitor || return 1
    rr_health_monitor_units_are_current || return 1
    repair_no_markers || return 1
    load_config_with_defaults || return 1
    repair_identity >"$repair_stage/identity-after.txt" || return 1
    cmp -s "$repair_stage/identity-before.txt" "$repair_stage/identity-after.txt" || return 1
    repair_material_digest >"$repair_stage/material-after.txt" || return 1
    cmp -s "$repair_stage/material-before.txt" "$repair_stage/material-after.txt" || return 1
    repair_verify_runtime check || return 1
    managed_singbox_running && expected_argo_tunnel_running || return 1
    repair_nexus_absent || return 1
    safe_sed INSTALL_COMPLETE true || return 1
    load_config_with_defaults || return 1
    [ "$INSTALL_COMPLETE" = true ] || return 1
    repair_note complete || return 1
    repair_finished=true
    printf 'REPAIR_PATCH_SOURCE commit=%s module_sha256=%s installed_version=7.2.3\n' \
        "$repair_candidate_commit" "$repair_candidate_module_sha256" >&3
    printf 'REPAIR_COMPLETE version=7.2.3 identities=preserved nexus=not_installed\n' >&3
}

repair_exit() {
    local result="$1" stop_failed=false unit="" state=""
    trap - EXIT HUP INT TERM
    [ "${repair_finished:-false}" = false ] || return 0
    [ "$result" -ne 0 ] || result=1
    if [ "${repair_mutation_started:-false}" = true ]; then
        # Do not roll old config over a newly created firewall evidence seal.
        if [ "${repair_health_started:-false}" = true ]; then
            systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || stop_failed=true
        fi
        # The newly created node unit must not auto-start an unfinished
        # recovery after reboot. Keep any firewall marker/evidence untouched.
        systemctl disable sing-box.service >/dev/null 2>&1 || stop_failed=true
        systemctl stop argo-rr-health.timer argo-rr-health.service \
            rr-subscription.service sing-box.service >/dev/null 2>&1 || true
        stop_quick_argo_tunnel >/dev/null 2>&1 || stop_failed=true
        stop_subscription_servers >/dev/null 2>&1 || stop_failed=true
        managed_singbox_running && stop_failed=true
        quick_argo_running && stop_failed=true
        subscription_server_running && stop_failed=true
        for unit in sing-box.service rr-subscription.service argo-rr-health.timer; do
            state=$(systemctl show "$unit" -p ActiveState --value) || state=unknown
            case "$state" in inactive|failed) ;; *) stop_failed=true ;; esac
        done
    elif [ "${repair_unit_created:-false}" = true ] && repair_no_markers && \
         [ "$(systemctl show sing-box.service -p ActiveState --value)" = inactive ] && \
         cmp -s /etc/systemd/system/sing-box.service <(rr_render_singbox_systemd_unit); then
        rm -f /etc/systemd/system/sing-box.service || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    printf 'REPAIR_STOP phase=%s rc=%s cleanup_uncertain=%s backup=%s\n' \
        "$repair_phase" "$result" "$stop_failed" "$repair_stage" >&3
    exit "$result"
}

# The environment was cleared before any runtime module was loaded. Enter the
# original lock API once, with its supported bounded wait; never retry a
# callback that may already have changed the host.
printf 'REPAIR_WAIT phase=writer_lock max_wait_seconds=20\n' >&3
rr_run_with_update_locks isolated 20 repair_locked </dev/null
repair_result=$?
if [ "$repair_result" -ne 0 ] && [ ! -f "$repair_stage/phase" ]; then
    if [ "$repair_result" -eq 75 ]; then
        printf '未取得 RR 写入锁（新写锁最多等待 20 秒）；通常是其他任务占用，也可能是 flock 错误。尚未备份配置或执行恢复。\n' >&3
    elif [ "$repair_result" -eq 76 ]; then
        printf 'RR 事务锁的可信性检查未通过；尚未备份配置或执行恢复。\n' >&3
    fi
    printf 'REPAIR_STOP phase=writer_lock rc=%s backup=%s\n' "$repair_result" "$repair_stage" >&3
fi
exit "$repair_result"
