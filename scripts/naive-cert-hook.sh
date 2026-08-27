#!/bin/bash
# Certbot deploy hook for the RR-vps NaiveProxy certificate.
set -u

CONFIG_FILE="/etc/argo_vmess.conf"
TARGET_DIR="/etc/rr-naive"
NAIVE_DOMAIN=""

[ -r "$CONFIG_FILE" ] || exit 0
# The RR config is root-owned and written using shell-safe quoting.
# shellcheck disable=SC1090
. "$CONFIG_FILE"
[ -n "${NAIVE_DOMAIN:-}" ] || exit 0

lineage="${RENEWED_LINEAGE:-/etc/letsencrypt/live/${NAIVE_DOMAIN}}"
[ "$(basename "$lineage")" = "$NAIVE_DOMAIN" ] || exit 0
[ -f "$lineage/fullchain.pem" ] && [ -f "$lineage/privkey.pem" ] || exit 0

install -d -m 700 "$TARGET_DIR"
install -m 600 "$lineage/fullchain.pem" "$TARGET_DIR/fullchain.pem"
install -m 600 "$lineage/privkey.pem" "$TARGET_DIR/privkey.pem"
systemctl try-restart sing-box >/dev/null 2>&1 || true
