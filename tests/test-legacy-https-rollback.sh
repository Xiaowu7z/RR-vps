#!/bin/bash
# Exercise real file/symlink rollback, with service operations mocked.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
python3 - "$repo/scripts/migrate-v702-nginx-https.sh" "$work" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); w=Path(sys.argv[2])
finish=s.split('finish() {',1)[1].split('\n}\n',1)[0]
w.joinpath('finish').write_text('finish() {'+finish+'\n}\n')
mutation=s.split('\nnginx_changed=true\n',1)[1].split('\n# reconfigure',1)[0]
w.joinpath('mutation').write_text('nginx_changed=true\n'+mutation+'\n')
PY
for committed in false true; do
    trial="$work/$committed"
    mkdir -p "$trial/backup" "$trial/scratch" "$trial/available" "$trial/enabled"
    printf 'old site\n' > "$trial/available/site"
    printf 'old renewal\n' > "$trial/renewal"
    chmod 644 "$trial/available/site"
    chmod 600 "$trial/renewal"
    cp -p "$trial/available/site" "$trial/backup/site"
    cp -p "$trial/renewal" "$trial/backup/renewal"
    ln -s "$trial/available/site" "$trial/enabled/old"
    printf 'new complete site\n' > "$trial/scratch/site.port"
    printf 'new http site\n' > "$trial/scratch/site.http"
    rc=0
    bash -s -- "$trial" "$work" "$committed" <<'SH' >/dev/null 2>&1 || rc=$?
set -eo pipefail
trial="$1"; harness="$2"; prep_committed="$3"
work="$trial/scratch"; backup="$trial/backup"
site="$trial/available/site"; old_link="$trial/enabled/old"
new_site="$trial/available/site.port"; new_link="$trial/enabled/new"
renewal="$trial/renewal"; phase=test
nginx_changed=false; nexus_paused=true; timer_paused=true
nginx() { return 0; }
timeout() { shift; "$@"; }
nexus_nginx_managed_paths_are_owned() { return 0; }
systemctl() { printf '%s\n' "$*" >> "$trial/services"; }
source "$harness/finish"
trap finish EXIT
source "$harness/mutation"
printf 'new renewal\n' > "$renewal"
if [ "$prep_committed" = true ]; then nexus_paused=false; timer_paused=false; fi
exit 23
SH
    test "$rc" = 23
    if [ "$committed" = false ]; then
        cmp "$trial/available/site" "$trial/backup/site"
        cmp "$trial/renewal" "$trial/backup/renewal"
        test "$(stat -c %a "$trial/renewal")" = 600
        test "$(readlink "$trial/enabled/old")" = "$trial/available/site"
        test ! -e "$trial/available/site.port"
        test ! -L "$trial/enabled/new"
        grep -qx 'start rr-nexus.service' "$trial/services"
        grep -qx 'start certbot.timer' "$trial/services"
    else
        test "$(cat "$trial/renewal")" = 'new renewal'
        test "$(readlink "$trial/enabled/new")" = "$trial/available/site.port"
        test ! -e "$trial/services"
    fi
done
echo 'Legacy HTTPS file rollback and installer ownership boundary: PASS'
