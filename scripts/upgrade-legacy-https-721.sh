#!/bin/bash
# RR 7.0.2 -> 7.2.1, existing public HTTPS, VMess-only inspected layout.
# Usage: bash SCRIPT EXPECTED_HOST EXPECTED_DOMAIN VMESS_PORT SUB_PORT
# No blanket firewall rewrites; released installer owns the update transaction.
set -eo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 SYSTEMD_PAGER=cat
expected_host="${1:?expected hostname required}"
expected_domain="${2:?expected panel domain required}"
expected_vm_port="${3:?expected VMess port required}"
expected_sub_port="${4:?expected subscription port required}"
test "${EUID:-$(id -u)}" = 0
test "$(hostname)" = "$expected_host"
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.0.2'
work=$(mktemp -d)
backup=""
phase=download
writers_paused=false
health_was_active=false
health_was_enabled=false
cert_timer_was_active=false
nginx_changed=false
prep_committed=false
installer_started=false
systemctl is-active --quiet argo-rr-health.timer && health_was_active=true
systemctl is-enabled --quiet argo-rr-health.timer && health_was_enabled=true
systemctl is-active --quiet certbot.timer && cert_timer_was_active=true

resume_writers() {
    local resume_result=0
    [ "$writers_paused" = true ] || return 0
    systemctl start rr-nexus.service || resume_result=1
    if [ "$cert_timer_was_active" = true ]; then systemctl start certbot.timer || resume_result=1; fi
    if [ "$health_was_active" = true ]; then systemctl start argo-rr-health.timer || resume_result=1; fi
    [ "$resume_result" = 0 ] || return 1
    writers_paused=false
}

finish() {
    local result=$? restore_result=0
    trap - EXIT INT TERM HUP
    if [ "$installer_started" != true ]; then
        if [ "$nginx_changed" = true ] && [ "$prep_committed" != true ]; then
            cp -p -- "$backup/site" "$site.restore" && mv -fT -- "$site.restore" "$site" || restore_result=1
            cp -p -- "$backup/renewal" "$renewal.restore" && mv -fT -- "$renewal.restore" "$renewal" || restore_result=1
            rm -f -- "$old_link.restore"
            ln -s -- "$site" "$old_link.restore" && mv -fT -- "$old_link.restore" "$old_link" || restore_result=1
            rm -f -- "$new_link" "$new_site" || restore_result=1
            timeout 15 nginx -t >"$work/rollback-nginx.log" 2>&1 && nginx -s reload >>"$work/rollback-nginx.log" 2>&1 || restore_result=1
            printf 'HTTPS_PREPARATION_ROLLBACK rc=%s\n' "$restore_result"
        fi
        if [ "$restore_result" = 0 ]; then
            resume_writers || restore_result=1
        else
            printf 'HTTPS_RESTORE_INCOMPLETE: writers remain paused; inspect backup before recovery.\n'
        fi
    fi
    if [ -n "$backup" ] && [ -d "$backup" ]; then
        for log in certbot-probe.log certbot-verify.log certbot.log rollback-nginx.log; do
            if [ -f "$work/$log" ]; then install -m 600 "$work/$log" "$backup/$log" || true; fi
        done
    fi
    if [ "$result" != 0 ] || [ "$restore_result" != 0 ]; then
        printf 'STOP phase=%s rc=%s restore_rc=%s backup=%s\n' "$phase" "$result" "$restore_result" "${backup:-not-created}"
        if [ -x /usr/local/sbin/rr-update-recover ]; then /usr/local/sbin/rr-update-recover status || true; fi
    fi
    rm -rf -- "$work"
    [ "$restore_result" = 0 ] || result=1
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

download() {
    local url="$1" destination="$2" digest="$3"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
        --connect-timeout 15 --max-time 180 "$url" -o "$destination" || return 1
    printf '%s  %s\n' "$digest" "$destination" | sha256sum -c -
}
download https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/rr-bundle.tar.gz \
    "$work/bundle.tar.gz" f00fc713dc63e43ca60da1c5f936d17263d58776445567b0dc8f3a2af7f8f9d3
tar --no-same-owner -xzf "$work/bundle.tar.gz" -C "$work"
candidate="$work/rr-bundle"
download https://raw.githubusercontent.com/Xiaowu7z/RR-vps/c7de4b412b2bd90d45fea733a0d62ede37918aab/install.sh \
    "$work/install.sh" 171b6f1fd2df445b5837c87b6744f9d38ff7ac2a0ca82b6fe41dd6d905995bb0
download https://raw.githubusercontent.com/Xiaowu7z/RR-vps/v7.2.1/scripts/verify-upgrade-identities.py \
    "$work/verify.py" d33dca31a1cfb295491561bd8e77c106a103e8211b8cdf7e6c9f1f21e91924f3
download https://raw.githubusercontent.com/Xiaowu7z/RR-vps/0f415d2a446b33287a004836cbf918d74497810d/scripts/legacy-nginx-702.py \
    "$work/check-site.py" 7efdac51d258afb79a75bd76f8605a3a9e7a0c5816b4624c1bba1a594a3eea82
cat > "$work/renewal-compat.py" <<'RR_RENEWAL_HELPER'
#!/usr/bin/env python3
"""Convert a reviewed Certbot 2.1 nginx renewal file to RR's webroot.

Caller owns backups, writer exclusion, staging validation before AND after this
operation, certificate-byte checks and rollback. No certificates are touched.
Uses ConfigObj, the same parser already required by distribution Certbot.
"""
import copy
import io
import os
from pathlib import Path
import re
import secrets
import stat
import sys

MAX_BYTES = 128 * 1024
WEBROOT = '/var/www/rr-nexus-certbot'
PRODUCTION = 'https://acme-v02.api.letsencrypt.org/directory'
HOOK = '/usr/sbin/nginx -t && /usr/sbin/nginx -s reload'


class Refused(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Refused(reason)


def parse(raw):
    try:
        from configobj import ConfigObj
        require(0 < len(raw) <= MAX_BYTES and b'\x00' not in raw,
                'invalid renewal size or encoding')
        return ConfigObj(io.BytesIO(raw), interpolation=False, encoding='utf-8',
                         list_values=True, raise_errors=True)
    except Refused:
        raise
    except ImportError:
        raise Refused('system Python lacks Certbot ConfigObj dependency') from None
    except Exception:
        # Parser errors can contain secret configuration values.
        raise Refused('renewal configuration is not valid ConfigObj') from None


def converted(raw, domain, webroot):
    require(isinstance(domain, str) and len(domain) <= 253 and
            re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+'
                         r'[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?', domain),
            'domain is not canonical')
    require(webroot == WEBROOT, 'webroot is not the RR challenge root')
    cfg = parse(raw)
    require(cfg.sections == ['renewalparams'],
            'unexpected renewal sections require review')
    params = cfg['renewalparams']
    require(not params.sections, 'existing nested renewal sections require review')
    require(params.get('authenticator') == 'nginx' and
            params.get('installer') == 'nginx',
            'renewal is not the reviewed nginx lineage')
    require(params.get('server') == PRODUCTION,
            'renewal is not bound to production ACME')
    require(isinstance(params.get('account'), str) and
            re.fullmatch(r'[0-9a-f]{32}', params['account']),
            'invalid production account identifier')
    for key in ('pre_hook', 'post_hook', 'deploy_hook', 'renew_hook'):
        require(not params.get(key) and not cfg.get(key),
                'existing certificate hooks require review')
    require('webroot_path' not in params and 'webroot_map' not in params,
            'existing webroot options require review')
    expected_paths = {'archive_dir': '/etc/letsencrypt/archive/' + domain}
    expected_paths.update({stem: '/etc/letsencrypt/live/' + domain + '/' + stem + '.pem'
                           for stem in ('cert', 'privkey', 'chain', 'fullchain')})
    require(all(cfg.get(key) == value for key, value in expected_paths.items()),
            'certificate paths do not match the reviewed lineage')
    require('config_dir' not in params or params['config_dir'] == '/etc/letsencrypt',
            'unexpected Certbot configuration root')
    require('autorenew' not in params or
            isinstance(params['autorenew'], str) and params['autorenew'].lower() == 'true',
            'automatic renewal is disabled')

    before = cfg.dict()
    expected = copy.deepcopy(before)
    expected_params = expected['renewalparams']
    expected_params.pop('installer')
    expected_params['authenticator'] = 'webroot'
    expected_params['webroot_path'] = [webroot]
    expected_params['webroot_map'] = {domain: webroot}
    # Certbot 2.1's --deploy-hook CLI sets renew_hook internally and saves that
    # key in renewalparams. A deploy_hook key alone is ignored during renew.
    expected_params['renew_hook'] = HOOK
    del params['installer']
    params['authenticator'] = 'webroot'
    params['webroot_path'] = [webroot]
    params['renew_hook'] = HOOK
    params['webroot_map'] = {domain: webroot}
    buffer = io.BytesIO()
    cfg.write(buffer)
    result = buffer.getvalue()
    require(parse(result).dict() == expected,
            'round-trip changed unrelated renewal configuration')
    return result


def secure_parent(path):
    require(path.is_absolute() and str(path) == os.path.normpath(str(path)),
            'renewal path is not canonical')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parent.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                              dir_fd=fd)
            os.close(fd)
            fd = next_fd
            info = os.fstat(fd)
            require(info.st_uid == 0 and not stat.S_IMODE(info.st_mode) & 0o022,
                    'renewal parent is not a secure root-owned directory')
        return fd
    except Exception:
        os.close(fd)
        raise


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def rewrite(path_raw, domain, webroot):
    require(os.geteuid() == 0, 'root is required')
    path = Path(path_raw)
    require(path.name == domain + '.conf', 'renewal filename differs from domain')
    parent_fd = secure_parent(path)
    source_fd = None
    temp_name = None
    try:
        source_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        original = os.fstat(source_fd)
        require(stat.S_ISREG(original.st_mode) and original.st_nlink == 1 and
                original.st_uid == 0 and original.st_gid == 0 and
                not stat.S_IMODE(original.st_mode) & 0o022,
                'renewal file has unsafe type, ownership or permissions')
        raw = os.read(source_fd, MAX_BYTES + 1)
        require(len(raw) == original.st_size and original.st_size <= MAX_BYTES,
                'renewal read was incomplete or exceeded the size limit')
        result = converted(raw, domain, webroot)
        temp_name = '.rr-renewal-' + secrets.token_hex(16)
        temp_fd = os.open(temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                          os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
        try:
            os.fchown(temp_fd, original.st_uid, original.st_gid)
            os.fchmod(temp_fd, stat.S_IMODE(original.st_mode))
            # Preserve ACL/SELinux labels and other existing extended metadata.
            for name in os.listxattr(source_fd):
                os.setxattr(temp_fd, name, os.getxattr(source_fd, name))
            view = memoryview(result)
            while view:
                written = os.write(temp_fd, view)
                require(written > 0, 'could not write prepared renewal configuration')
                view = view[written:]
            os.fsync(temp_fd)
        finally:
            os.close(temp_fd)
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        require(fingerprint(current) == fingerprint(original) and
                fingerprint(os.fstat(source_fd)) == fingerprint(original),
                'renewal configuration changed concurrently')
        os.lseek(source_fd, 0, os.SEEK_SET)
        require(os.read(source_fd, MAX_BYTES + 1) == raw,
                'renewal contents changed concurrently')
        os.replace(temp_name, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        temp_name = None
        os.fsync(parent_fd)
    finally:
        if temp_name is not None:
            os.unlink(temp_name, dir_fd=parent_fd)
        if source_fd is not None:
            os.close(source_fd)
        os.close(parent_fd)


def main():
    require(len(sys.argv) == 4,
            'usage: renewal_webroot_compat.py RENEWAL_FILE DOMAIN WEBROOT')
    rewrite(*sys.argv[1:])
    print('RENEWAL_WEBROOT_OPTIONS_SAVED')


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print('RENEWAL_COMPAT_REFUSED: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print('RENEWAL_COMPAT_REFUSED: local operation failed (' +
              type(error).__name__ + ')', file=sys.stderr)
        sys.exit(1)
RR_RENEWAL_HELPER
cat > "$work/extra-identities.py" <<'RR_EXTRA_IDENTITIES'
#!/usr/bin/env python3
"""Preserve supplementary RR identities without displaying credential values."""
import hashlib
import json
import os
import re
import shlex
import stat
import sys
from pathlib import Path


# These defaults match 7.2.1 load_config_with_defaults, including its explicitly
# documented legacy behavior. New defaults may appear on disk during upgrade.
DEFAULTS = {
    "CDN_IP": "cloudflare-ech.com", "ARGO_DOMAIN": "",
    "ARGO_EDGE_PORT": "443", "SUB_PORT": "18080", "SUB_DOMAIN": "",
    "SUB_ACCESS_MODE": "local", "TUNNEL_MODE": "1",
    "VM_ENABLED": "true", "VM_TLS_ENABLED": "false", "VL_ENABLED": "false",
    "HY2_ENABLED": "false", "TU5_ENABLED": "false", "AN_ENABLED": "false",
    "NAIVE_ENABLED": "false",
}
WATCHED = set(DEFAULTS) | {"SUB_TOKEN"}
UUID_JSON = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\.json")


class IdentityError(Exception):
    pass


def private_read(path, field):
    """Read existing regular root-owned files without following a final symlink."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                    or info.st_mode & 0o022 or info.st_size > 1024 * 1024):
                raise IdentityError("UNSAFE_FILE:" + field)
            with os.fdopen(fd, "rb", closefd=False) as stream:
                return stream.read(1024 * 1024 + 1)
        finally:
            os.close(fd)
    except IdentityError:
        raise
    except (OSError, ValueError):
        raise IdentityError("UNREADABLE_FILE:" + field) from None


def config_values(root):
    raw = private_read(root / "etc/argo_vmess.conf", "config")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeError:
        raise IdentityError("CONFIG_ENCODING") from None
    values = {}
    for line in lines:
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or key not in WATCHED:
            continue
        if key in values:
            raise IdentityError("CONFIG_DUPLICATE:" + key)
        try:
            words = shlex.split(value)
        except ValueError:
            raise IdentityError("CONFIG_PARSE:" + key) from None
        if len(words) > 1:
            raise IdentityError("CONFIG_PARSE:" + key)
        values[key] = words[0] if words else ""
    return values


def credential_paths(root):
    names = {"token", "config.yml", "config.yaml", "config.json", "cert.pem", "credentials.json"}
    selected = []
    for relative in ("etc/rr-cloudflared", "etc/cloudflared", "root/.cloudflared"):
        directory = root / relative
        if not os.path.lexists(directory):
            continue
        try:
            info = directory.lstat()
            if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                    or info.st_uid != 0 or info.st_mode & 0o022):
                raise IdentityError("UNSAFE_DIRECTORY:" + relative)
            allowed_names = {"token"} if relative == "etc/rr-cloudflared" else names
            selected.extend(p for p in directory.iterdir()
                            if p.name in allowed_names or
                            (relative != "etc/rr-cloudflared" and UUID_JSON.fullmatch(p.name)))
        except OSError:
            raise IdentityError("UNREADABLE_DIRECTORY:" + relative) from None
    return sorted(p for p in set(selected) if os.path.lexists(p))


def capture_state(root=Path("/")):
    values = config_values(root)
    config = {key: values.get(key) or default for key, default in DEFAULTS.items()}
    # A token absent in the old release can legitimately be added by migration.
    # A previously nonempty token must never change, even if it is nonstandard.
    if values.get("SUB_TOKEN"):
        config["SUB_TOKEN.sha256"] = hashlib.sha256(values["SUB_TOKEN"].encode()).hexdigest()
    try:
        nexus = json.loads(private_read(root / "etc/rr-nexus/nexus.json", "nexus"))
        public_port = int(nexus.get("public_port") or 443)
        if not 1 <= public_port <= 65535:
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise IdentityError("NEXUS_PARSE:public_port") from None
    credentials = {}
    for path in credential_paths(root):
        relative = path.relative_to(root).as_posix()
        credentials[relative] = hashlib.sha256(private_read(path, relative)).hexdigest()
    return {"format": 1, "config": config,
            "nexus": {"public_port": public_port}, "credential_files": credentials}


def changed_fields(before, after):
    if (not isinstance(before, dict) or before.get("format") != 1
            or set(before) != {"format", "config", "nexus", "credential_files"}
            or any(not isinstance(before.get(k), dict)
                   for k in ("config", "nexus", "credential_files"))
            or not set(DEFAULTS).issubset(before["config"])
            or set(before["config"]) - (set(DEFAULTS) | {"SUB_TOKEN.sha256"})
            or set(before["nexus"]) != {"public_port"}):
        raise IdentityError("INVALID_SNAPSHOT")
    changed = []
    for section in ("config", "nexus", "credential_files"):
        # Compare every preexisting identity. Newly added credential files and
        # a newly generated previously absent SUB_TOKEN are permitted.
        for key, value in sorted(before[section].items()):
            if after[section].get(key) != value:
                if section == "credential_files":
                    # Only paths captured by us can appear in diagnostics.
                    if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_./-]+", key):
                        raise IdentityError("INVALID_SNAPSHOT")
                changed.append(section + "." + key)
    return changed


def main(argv):
    if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] != "--capture"):
        raise IdentityError("USAGE: SNAPSHOT [--capture]")
    path = Path(argv[1])
    current = capture_state()
    if len(argv) == 3:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(current, stream, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
        except OSError:
            raise IdentityError("SNAPSHOT_WRITE_FAILED") from None
        print("UPGRADE_EXTRA_IDENTITIES_CAPTURED")
        return 0
    try:
        before = json.loads(private_read(path, "snapshot"))
    except (ValueError, TypeError):
        raise IdentityError("INVALID_SNAPSHOT") from None
    changed = changed_fields(before, current)
    if changed:
        print("UPGRADE_EXTRA_IDENTITIES_CHANGED: " + ",".join(changed), file=sys.stderr)
        return 1
    print("UPGRADE_EXTRA_IDENTITIES_PRESERVED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except IdentityError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
RR_EXTRA_IDENTITIES

phase=preflight
# A pristine 7.0.2 host has no installed recovery helper. Use the verified
# candidate's read-only status entry; do not install anything to pass this gate.
bash "$candidate/scripts/update-recover.sh" status | /usr/bin/python3 -c \
    'import json,sys; s=json.load(sys.stdin); assert s.get("active") is False and s.get("subscription_quarantine",{}).get("active") is False, "Existing transaction or quarantine requires inspection"'
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$candidate/scripts/update-recover.sh"
set +u
rr_acquire_update_lock
bash "$candidate/scripts/update-recover.sh" status | /usr/bin/python3 -c \
    'import json,sys; s=json.load(sys.stdin); assert s.get("active") is False and s.get("subscription_quarantine",{}).get("active") is False'
for marker in /run/rr-vps/update-maintenance /var/lib/rr-backup/active /var/lib/rr-vps/firewall-quarantine; do
    test ! -e "$marker" && test ! -L "$marker"
done
for module in 00-runtime.sh 09-systemd.sh 10-system.sh 20-config.sh 30-singbox.sh 85-nexus.sh; do
    source "$candidate/modules/$module"
done
RR_LIB_DIR="$candidate"
load_config_with_defaults
is_valid_domain "$expected_domain"
is_valid_port "$expected_vm_port"
is_valid_port "$expected_sub_port"
test "$PORT:$SUB_PORT" = "$expected_vm_port:$expected_sub_port"
test "$VM_ENABLED:$VM_TLS_ENABLED:$VL_ENABLED:$HY2_ENABLED:$TU5_ENABLED:$AN_ENABLED:$NAIVE_ENABLED" = true:false:false:false:false:false:false
test "$(jq -r '[.mode,.domain,(.port|tostring),(.public_port|tostring)]|join(":")' "$NEXUS_CONFIG_FILE")" = "public:$expected_domain:7900:443"
domain="$expected_domain"
for unit in sing-box.service rr-nexus.service nginx.service; do systemctl is-active --quiet "$unit"; done
for port in 80 443; do
    rr_validate_protocol_firewall "$port" tcp open || {
        printf 'PRECHECK_FAILED firewall_tcp_%s; no firewall rules were changed.\n' "$port"
        exit 1
    }
done
site=/etc/nginx/sites-available/rr-nexus.conf
old_link=/etc/nginx/sites-enabled/rr-nexus.conf
new_site=/etc/nginx/sites-available/rr-nexus.conf.port
new_link=/etc/nginx/sites-enabled/rr-nexus-port.conf
renewal="/etc/letsencrypt/renewal/$domain.conf"
webroot=/var/www/rr-nexus-certbot
renewal_mode=$(/usr/bin/python3 - "$renewal" <<'PY'
from pathlib import Path
import re, sys
values = re.findall(r'(?m)^\s*authenticator\s*=\s*([A-Za-z0-9_-]+)\s*$', Path(sys.argv[1]).read_text())
assert len(values) == 1 and values[0] in ('nginx','webroot')
print(values[0])
PY
)
if [ "$renewal_mode" = nginx ]; then
    nexus_nginx_regular_site_metadata_is_exact "$site"
    nexus_nginx_enabled_link_is_exact "$old_link" "$site"
    for path in "$new_site" "$new_link" "$old_link.restore" "$site.restore" "$renewal.restore"; do
        test ! -e "$path" && test ! -L "$path"
    done
    /usr/bin/python3 "$work/check-site.py" "$site" "$domain"
    /usr/bin/python3 - "$renewal" "$domain" <<'PY'
from pathlib import Path
import configparser, stat, sys
p=Path(sys.argv[1]); m=p.lstat()
assert stat.S_ISREG(m.st_mode) and (m.st_uid,m.st_gid,m.st_nlink)==(0,0,1)
assert not stat.S_IMODE(m.st_mode)&0o022
c=configparser.ConfigParser(interpolation=None,strict=True)
c.read_string('[paths]\n'+p.read_text())
assert c['renewalparams']['authenticator']=='nginx' and c['renewalparams']['installer']=='nginx'
for key in ('pre_hook','post_hook','deploy_hook','renew_hook'):
    assert not c['renewalparams'].get(key,''), 'Custom certificate hook requires inspection'
assert c['paths']['fullchain']==f'/etc/letsencrypt/live/{sys.argv[2]}/fullchain.pem'
assert c['paths']['privkey']==f'/etc/letsencrypt/live/{sys.argv[2]}/privkey.pem'
PY
else
    nexus_nginx_managed_paths_are_owned
    rr_certbot_webroot_lineage_is_renewable "$domain"
    prep_committed=true
fi
subscription_certificate_pair_valid "/etc/letsencrypt/live/$domain/fullchain.pem" \
    "/etc/letsencrypt/live/$domain/privkey.pem" "$domain"
certbot --help all > "$work/certbot-help" 2>/dev/null
certbot_path=$(command -v certbot)
certbot --version
certbot_reconfigure=false
if grep -qw reconfigure "$work/certbot-help"; then certbot_reconfigure=true; fi
if [ "$certbot_reconfigure" = false ] && [ "$renewal_mode" = nginx ]; then
    /usr/bin/python3 -c 'import configobj' || { echo 'PRECHECK_FAILED: Certbot ConfigObj dependency unavailable'; exit 1; }
fi
test "$cert_timer_was_active" = true || { echo 'PRECHECK_FAILED: certbot.timer is not active'; exit 1; }
systemctl is-enabled --quiet certbot.timer || { echo 'PRECHECK_FAILED: certbot.timer is not enabled'; exit 1; }
case "$(systemctl show certbot.service -p ActiveState --value)" in inactive|failed) ;; *) echo 'PRECHECK_FAILED: Certbot task is running'; exit 1 ;; esac
for path in /var/www "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge"; do
    if [ -e "$path" ] || [ -L "$path" ]; then nexus_nginx_managed_directory_is_safe "$path"; fi
done
timeout 15 nginx -t
test "$(command -v nginx)" = /usr/sbin/nginx

phase=backup
paths=()
for path in etc/argo_vmess.conf etc/sing-box etc/rr-nexus etc/nginx etc/letsencrypt \
    etc/systemd/system etc/rr-update etc/rr-cloudflared etc/cloudflared root/.cloudflared \
    etc/rr-naive etc/iptables var/lib/rr-update var/lib/rr-quarantine \
    usr/local/bin/rr usr/local/bin/sing-box usr/local/bin/cloudflared usr/bin/cloudflared \
    usr/local/bin/auto_update_sub.py usr/local/lib/rr usr/local/libexec/rr-vps \
    usr/local/sbin/rr-update-recover usr/local/sbin/rr-update-external-state \
    var/lib/rr-nexus var/lib/rr-vps var/www/rr-nexus-certbot var/spool/cron/crontabs/root tmp/sub_server; do
    if [ -e "/$path" ] || [ -L "/$path" ]; then paths+=("$path"); fi
done
size_kb=$(cd /; du -skc -- "${paths[@]}" | tail -1 | awk '{print $1}')
free_kb=$(df -Pk /root | awk 'NR==2 {print $4}')
test "$free_kb" -ge "$((size_kb * 2 + 524288))" || { echo 'PRECHECK_FAILED: insufficient backup space'; exit 1; }
backup=$(mktemp -d /root/rr-before-7.2.1.XXXXXX)
printf '备份目录：%s；开始备份与 HTTPS 兼容迁移。\n' "$backup"
printf '%s\n' "${paths[@]}" > "$backup/backup-paths.txt"
printf 'health_active=%s\nhealth_enabled=%s\ncertbot_timer_active=%s\n' \
    "$health_was_active" "$health_was_enabled" "$cert_timer_was_active" > "$backup/writer-states.txt"
writers_paused=true
systemctl stop argo-rr-health.timer argo-rr-health.service rr-nexus.service
if [ "$cert_timer_was_active" = true ]; then systemctl stop certbot.timer; fi
case "$(systemctl show certbot.service -p ActiveState --value)" in inactive|failed) ;; *) exit 1 ;; esac
/usr/bin/python3 "$work/verify.py" "$backup/identities.json" --capture
/usr/bin/python3 "$work/extra-identities.py" "$backup/extra-identities.json" --capture
install -m 600 "$work/verify.py" "$backup/verify-identities.py"
install -m 600 "$work/extra-identities.py" "$backup/extra-identities.py"
/usr/bin/python3 - "$backup/nexus.db" <<'PY'
import sqlite3, sys
with sqlite3.connect('file:/var/lib/rr-nexus/nexus.db?mode=ro',uri=True) as source:
    assert source.execute('PRAGMA quick_check').fetchone() == ('ok',)
    with sqlite3.connect(sys.argv[1]) as target:
        source.backup(target)
        assert target.execute('PRAGMA quick_check').fetchone() == ('ok',)
PY
tar --acls --xattrs --numeric-owner -czf "$backup/files.tar.gz.part" -C / "${paths[@]}"
gzip -t "$backup/files.tar.gz.part"
mv "$backup/files.tar.gz.part" "$backup/files.tar.gz"
(cd "$backup"; sha256sum files.tar.gz nexus.db identities.json extra-identities.json > SHA256SUMS; sha256sum -c SHA256SUMS)
sync -f "$backup"
sha256sum /etc/argo_vmess.conf /etc/sing-box/config.json /etc/rr-nexus/nexus.json \
    "/etc/letsencrypt/live/$domain/"{cert,chain,fullchain,privkey}.pem > "$backup/preparation-unchanged.sha256"

if [ "$renewal_mode" = nginx ]; then
    cp -p -- "$site" "$backup/site"
    cp -p -- "$renewal" "$backup/renewal"
    nexus_emit_nginx_domain_custom_site "$domain" 443 "$webroot" false > "$work/site.port"
    nexus_emit_nginx_domain_http_site "$domain" "$webroot" > "$work/site.http"
    phase=prepare-https-route
    install -d -m 755 "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge"
    nginx_changed=true
    install -m 644 "$work/site.port" "$new_site"
    ln -s "$new_site" "$old_link.restore"
    mv -fT "$old_link.restore" "$old_link"
    mv -T "$old_link" "$new_link"
    install -m 644 "$work/site.http" "$site.restore"
    mv -fT "$site.restore" "$site"
    timeout 15 nginx -t
    nginx -s reload
    nexus_nginx_managed_paths_are_owned
    if [ "$certbot_reconfigure" = true ]; then
        phase=certbot-reconfigure
        (umask 022; timeout --kill-after=15 180 "$certbot_path" reconfigure --cert-name "$domain" \
            --authenticator webroot --webroot-path "$webroot" --installer '' \
            --deploy-hook '/usr/sbin/nginx -t && /usr/sbin/nginx -s reload' \
            --run-deploy-hooks --no-directory-hooks --non-interactive) > "$work/certbot.log" 2>&1
    else
        phase=certbot-legacy-staging-probe
        # Certbot <=2.2 has no reconfigure or --run-deploy-hooks. Prove the
        # challenge first, then atomically save options and prove their readback.
        (umask 022; timeout --kill-after=15 180 "$certbot_path" renew --cert-name "$domain" --dry-run \
            --authenticator webroot --webroot-path "$webroot" --installer '' \
            --deploy-hook '/usr/sbin/nginx -t && /usr/sbin/nginx -s reload' \
            --no-directory-hooks --no-random-sleep-on-renew --non-interactive) > "$work/certbot-probe.log" 2>&1
        phase=certbot-legacy-save-options
        /usr/bin/python3 "$work/renewal-compat.py" "$renewal" "$domain" "$webroot"
        phase=certbot-legacy-verify-options
        (umask 022; timeout --kill-after=15 180 "$certbot_path" renew --cert-name "$domain" --dry-run \
            --no-directory-hooks --no-random-sleep-on-renew --non-interactive) > "$work/certbot-verify.log" 2>&1
        timeout 15 nginx -t
        nginx -s reload
    fi
fi
phase=verify-prepared-https
rr_certbot_webroot_lineage_is_renewable "$domain"
sha256sum -c "$backup/preparation-unchanged.sha256"
/usr/bin/python3 "$work/verify.py" "$backup/identities.json"
/usr/bin/python3 "$work/extra-identities.py" "$backup/extra-identities.json"
rr_certbot_acme_http_route_is_ready "$domain"
prep_committed=true
resume_writers
rr_certbot_renewal_runtime_is_ready "$domain"
printf 'LEGACY_HTTPS_PREPARED: 生产证书和用户身份未变，续签配置已验证。\n'

# From this point, only the published installer decides rollback/quarantine.
rr_close_inherited_recovery_lock_fds
unset RR_UPDATE_LOCK_HELD RR_RESTORE_LOCK_HELD RR_UPDATE_LOCK_OWNER RR_UPDATE_LOCK_FDS_CLOSED
phase=upgrade
installer_started=true
bash "$work/install.sh" --upgrade
phase=verify-upgrade
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.2.1'
/usr/bin/python3 "$work/verify.py" "$backup/identities.json"
/usr/bin/python3 "$work/extra-identities.py" "$backup/extra-identities.json"
for unit in sing-box.service rr-nexus.service nginx.service; do systemctl is-active --quiet "$unit"; done
/usr/local/sbin/rr-update-recover status | /usr/bin/python3 -c '
import json,os,sys
from pathlib import Path
s=json.load(sys.stdin)
assert s.get("phase")=="committed" and s.get("subscription_quarantine",{}).get("active") is False
tx=Path(s["transaction"])
assert tx.parent == Path("/var/lib/rr-update/transactions")
assert (tx/"committed-settled").read_text().strip()=="rr-update-committed-settled-v1"
for p in ("/run/rr-vps/update-maintenance","/var/lib/rr-vps/firewall-quarantine","/var/lib/rr-backup/active"):
    assert not os.path.lexists(p)
print("UPDATE_COMMITTED_SETTLED_OK")
'
rr_health_monitor_unit_definitions_are_current
if [ "$health_was_enabled" = true ]; then systemctl is-enabled --quiet argo-rr-health.timer; fi
if [ "$health_was_active" = true ]; then systemctl is-active --quiet argo-rr-health.timer; fi
phase=complete
printf 'UPGRADE_COMPLETE: RR-vps 7.2.1；用户、节点、订阅和隧道身份核对一致。\n备份：%s\n' "$backup"
