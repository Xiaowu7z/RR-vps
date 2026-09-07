#!/bin/bash
# One-time compatibility adapter. Preserve production certificates/identities;
# reconfigure renewal through Certbot's staging-tested command before upgrading.
set -eo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 SYSTEMD_PAGER=cat
test "${EUID:-$(id -u)}" = 0
identity_backup="${1:?Supply the existing pre-upgrade backup directory}"
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.0.2'
printf '%s  %s\n' d33dca31a1cfb295491561bd8e77c106a103e8211b8cdf7e6c9f1f21e91924f3 \
    "$identity_backup/verify-identities.py" | sha256sum -c -
python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
/usr/local/sbin/rr-update-recover status | python3 -c \
    'import json,sys; s=json.load(sys.stdin); assert s.get("active") is False'
work=$(mktemp -d)
backup=""
phase=preflight
nginx_changed=false
prep_committed=false
nexus_paused=false
timer_paused=false
finish() {
    local result=$? rollback_result=0
    trap - EXIT INT TERM HUP
    if [ "$nginx_changed" = true ] && [ "$prep_committed" != true ]; then
        cp -p -- "$backup/site" "$site.restore" && mv -fT -- "$site.restore" "$site" || rollback_result=1
        cp -p -- "$backup/renewal" "$renewal.restore" && mv -fT -- "$renewal.restore" "$renewal" || rollback_result=1
        rm -f -- "$old_link.restore"
        ln -s -- "$site" "$old_link.restore" && mv -fT -- "$old_link.restore" "$old_link" || rollback_result=1
        rm -f -- "$new_link" "$new_site" || rollback_result=1
        nginx -t >"$work/rollback-nginx.log" 2>&1 && nginx -s reload >>"$work/rollback-nginx.log" 2>&1 || rollback_result=1
        printf 'HTTPS_PREPARATION_ROLLBACK rc=%s\n' "$rollback_result"
    fi
    if [ "$nexus_paused" = true ]; then systemctl start rr-nexus.service || result=1; fi
    if [ "$timer_paused" = true ]; then systemctl start certbot.timer || result=1; fi
    if [ "$result" != 0 ] || [ "$rollback_result" != 0 ]; then
        printf 'STOP phase=%s rc=%s backup=%s\n' "$phase" "$result" "${backup:-not-created}"
        if [ -f "$work/certbot.log" ]; then
            python3 - "$work/certbot.log" <<'PY'
from pathlib import Path
import re,sys
for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
    if re.search(r'error|failed|detail:|invalid',line,re.I):
        print(re.sub(r'[A-Za-z0-9_-]{32,}','<identifier>',line)[:240])
PY
        fi
        /usr/local/sbin/rr-update-recover status || true
    fi
    rm -rf -- "$work"
    [ "$rollback_result" = 0 ] || result=1
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
    https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/rr-bundle.tar.gz -o "$work/bundle.tar.gz"
printf '%s  %s\n' f00fc713dc63e43ca60da1c5f936d17263d58776445567b0dc8f3a2af7f8f9d3 \
    "$work/bundle.tar.gz" | sha256sum -c -
tar -xzf "$work/bundle.tar.gz" -C "$work"
candidate="$work/rr-bundle"
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://raw.githubusercontent.com/Xiaowu7z/RR-vps/0f415d2a446b33287a004836cbf918d74497810d/scripts/legacy-nginx-702.py -o "$work/check-site.py"
printf '%s  %s\n' 7efdac51d258afb79a75bd76f8605a3a9e7a0c5816b4624c1bba1a594a3eea82 "$work/check-site.py" | sha256sum -c -
curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
    https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/install.sh -o "$work/install.sh"
printf '%s  %s\n' 171b6f1fd2df445b5837c87b6744f9d38ff7ac2a0ca82b6fe41dd6d905995bb0 \
    "$work/install.sh" | sha256sum -c -
# Acquire the normal recovery lock before inspecting or editing managed paths.
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$candidate/scripts/update-recover.sh"
rr_acquire_update_lock
for module in 00-runtime.sh 09-systemd.sh 10-system.sh 20-config.sh 30-singbox.sh 85-nexus.sh; do
    source "$candidate/modules/$module"
done
RR_LIB_DIR="$candidate"
load_config_with_defaults
test "$(jq -r '.mode' "$NEXUS_CONFIG_FILE")" = public
test "$(jq -r '.public_port' "$NEXUS_CONFIG_FILE")" = 443
test "$(jq -r '.port' "$NEXUS_CONFIG_FILE")" = 7900
domain=$(jq -r '.domain' "$NEXUS_CONFIG_FILE")
is_valid_domain "$domain"
site=/etc/nginx/sites-available/rr-nexus.conf
old_link=/etc/nginx/sites-enabled/rr-nexus.conf
new_site=/etc/nginx/sites-available/rr-nexus.conf.port
new_link=/etc/nginx/sites-enabled/rr-nexus-port.conf
renewal="/etc/letsencrypt/renewal/$domain.conf"
webroot=/var/www/rr-nexus-certbot
nexus_nginx_regular_site_metadata_is_exact "$site"
nexus_nginx_enabled_link_is_exact "$old_link" "$site"
for path in "$new_site" "$new_link" "$old_link.restore" "$site.restore" "$renewal.restore"; do
    test ! -e "$path" && test ! -L "$path"
done
python3 "$work/check-site.py" "$site" "$domain"
python3 - "$renewal" "$domain" <<'PY'
from pathlib import Path
import configparser,stat,sys
p=Path(sys.argv[1]); m=p.lstat()
assert stat.S_ISREG(m.st_mode) and (m.st_uid,m.st_gid,m.st_nlink)==(0,0,1)
assert not stat.S_IMODE(m.st_mode)&0o022
c=configparser.ConfigParser(interpolation=None,strict=True)
c.read_string('[paths]\n'+p.read_text())
assert c['renewalparams']['authenticator']=='nginx'
assert c['renewalparams']['installer']=='nginx'
for k in ('pre_hook','post_hook','deploy_hook','renew_hook'):
    assert not c['renewalparams'].get(k,''), 'Custom certificate hook requires review'
assert c['paths']['fullchain']==f'/etc/letsencrypt/live/{sys.argv[2]}/fullchain.pem'
assert c['paths']['privkey']==f'/etc/letsencrypt/live/{sys.argv[2]}/privkey.pem'
PY
subscription_certificate_pair_valid "/etc/letsencrypt/live/$domain/fullchain.pem" \
    "/etc/letsencrypt/live/$domain/privkey.pem" "$domain"
certbot --help all > "$work/certbot-help" 2>/dev/null
grep -q reconfigure "$work/certbot-help"
for unit in sing-box.service rr-nexus.service nginx.service certbot.timer; do systemctl is-active --quiet "$unit"; done
test "$(systemctl show certbot.service -p ActiveState --value)" = inactive
for path in /var/www "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge"; do
    if [ -e "$path" ] || [ -L "$path" ]; then nexus_nginx_managed_directory_is_safe "$path"; fi
done
timeout 15 nginx -t
test "$(command -v nginx)" = /usr/sbin/nginx
backup=$(mktemp -d /root/rr-legacy-https.XXXXXX)
cp -p -- "$site" "$backup/site"
cp -p -- "$renewal" "$backup/renewal"
sha256sum /etc/argo_vmess.conf /etc/sing-box/config.json /etc/rr-nexus/nexus.json \
    "/etc/letsencrypt/live/$domain/"{cert,chain,fullchain,privkey}.pem > "$backup/unchanged.sha256"
nexus_emit_nginx_domain_custom_site "$domain" 443 "$webroot" false > "$work/site.port"
nexus_emit_nginx_domain_http_site "$domain" "$webroot" > "$work/site.http"
printf '准备旧版 HTTPS 迁移；节点保持运行，面板会短暂暂停。备份：%s\n' "$backup"
phase=pause-certificate-writers
timer_paused=true
systemctl stop certbot.timer
test "$(systemctl show certbot.service -p ActiveState --value)" = inactive
nexus_paused=true
systemctl stop rr-nexus.service
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
# reconfigure validates against staging and saves renewal options only after
# success. An explicitly empty installer removes the old Nginx configurator.
phase=certbot-reconfigure
# Nginx workers must be able to read the temporary challenge. Certbot itself
# sets private account/key modes; the challenge must not inherit root's 077.
# Keep certificate reload working even if the subsequent RR upgrade rolls back.
(umask 022; timeout --kill-after=15 180 certbot reconfigure --cert-name "$domain" \
    --authenticator webroot --webroot-path "$webroot" --installer '' \
    --deploy-hook '/usr/sbin/nginx -t && /usr/sbin/nginx -s reload' \
    --run-deploy-hooks --no-directory-hooks --non-interactive) > "$work/certbot.log" 2>&1
phase=verify-prepared-https
rr_certbot_webroot_lineage_is_renewable "$domain"
sha256sum -c "$backup/unchanged.sha256"
python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
rr_certbot_acme_http_route_is_ready "$domain"
# From this point the new renewal settings and route are proven together.
# Retain that working preparation even if resuming a service fails.
prep_committed=true
systemctl start rr-nexus.service
nexus_paused=false
systemctl start certbot.timer
timer_paused=false
rr_certbot_renewal_runtime_is_ready "$domain"
printf 'LEGACY_HTTPS_PREPARED: 证书及用户身份未变，续签已通过验证。\n'
# The released installer now owns rollback and quarantine. Never restore the
# older Nginx configuration or start services over its decisions on failure.
rr_close_inherited_recovery_lock_fds
unset RR_UPDATE_LOCK_HELD RR_RESTORE_LOCK_HELD RR_UPDATE_LOCK_OWNER RR_UPDATE_LOCK_FDS_CLOSED
phase=upgrade
bash "$work/install.sh" --upgrade
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.2.1'
python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
for unit in sing-box.service rr-nexus.service nginx.service; do systemctl is-active --quiet "$unit"; done
/usr/local/sbin/rr-update-recover status | python3 -c \
    'import json,sys; s=json.load(sys.stdin); assert not s.get("subscription_quarantine",{}).get("active")'
rr_health_monitor_unit_definitions_are_current
systemctl enable --now argo-rr-health.timer
rr_health_monitor_units_are_current
phase=complete
printf 'UPGRADE_COMPLETE: RR-vps 7.2.1；原有用户和订阅身份核对一致。\n'
