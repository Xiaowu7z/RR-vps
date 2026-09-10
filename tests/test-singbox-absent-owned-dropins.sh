#!/usr/bin/env bash
set -euo pipefail

# Focused filesystem fixture: real RR ownership checks and atomic unit writer,
# with the read-only systemd property provider replaced. A restricted user
# namespace may also require one explicitly reported owner-metadata injection.
# No services start.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf '%s\n' 'ERROR: this ownership regression requires root; it was not run.' >&2
    exit 1
fi

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../modules/10-system.sh
source "$REPO_ROOT/modules/10-system.sh"
# shellcheck source=../modules/30-singbox.sh
source "$REPO_ROOT/modules/30-singbox.sh"

fixture_root=$(mktemp -d /root/rr-test-singbox-absent.XXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT
case_number=0
passed=0
fixture_foreign_owner=''
owner_metadata_injected=false

stat() {
    if [ "$#" -eq 4 ] && [ "$1" = -c ] && \
       [ "$2" = '%u:%g:%h:%a' ] && [ "$3" = -- ] && \
       [ "$4" = "$fixture_foreign_owner" ]; then
        printf '%s\n' '1:1:1:644'
        return 0
    fi
    command stat "$@"
}

systemctl() {
    local property="" argument=""
    [ "$#" -eq 4 ] && [ "$1" = show ] && \
        [ "$3" = --value ] && [ "$4" = sing-box.service ] || {
        printf 'Unexpected systemctl fixture call: %s\n' "$*" >&2
        return 99
    }
    for argument in "$@"; do
        case "$argument" in --property=*) property=${argument#--property=} ;; esac
    done
    case "$property" in
        LoadState) printf '%s\n' "$fixture_load" ;;
        FragmentPath) printf '%s\n' "$fixture_fragment" ;;
        DropInPaths) printf '%s\n' "$fixture_dropins" ;;
        *) printf 'Unexpected systemd property: %s\n' "$property" >&2; return 99 ;;
    esac
}

new_case() {
    case_number=$((case_number + 1))
    case_root="$fixture_root/case-$case_number"
    RR_RESTORE_SYSTEMD_DIR="$case_root/systemd"
    RR_SINGBOX_SERVICE_FILE="$RR_RESTORE_SYSTEMD_DIR/sing-box.service"
    dropin_dir="$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d"
    firewall_file="$dropin_dir/zzzzz-rr-firewall-quarantine.conf"
    restore_file="$dropin_dir/zzzz-rr-restore-gate.conf"
    install -d -o 0 -g 0 -m 755 -- "$case_root" "$RR_RESTORE_SYSTEMD_DIR"
    fixture_load=not-found
    fixture_fragment=''
    fixture_dropins=''
    fixture_foreign_owner=''
}

add_firewall_gate() {
    install -d -o 0 -g 0 -m 755 -- "$dropin_dir"
    printf '[Service]\nExecCondition=/usr/bin/test ! -e %s\nExecCondition=/usr/bin/test ! -L %s\n' \
        /var/lib/rr-vps/firewall-quarantine \
        /var/lib/rr-vps/firewall-quarantine > "$firewall_file"
    chmod 644 -- "$firewall_file"
}

add_restore_gate() {
    install -d -o 0 -g 0 -m 755 -- "$dropin_dir"
    printf '%s\n' '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$restore_file"
    chmod 644 -- "$restore_file"
}

accepts() {
    local label="$1"
    if ! rr_singbox_service_is_owned_or_absent; then
        printf 'FAIL: expected an absent owned service: %s\n' "$label" >&2
        exit 1
    fi
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$label"
}

rejects() {
    local label="$1"
    if rr_singbox_service_is_owned_or_absent; then
        printf 'FAIL: unsafe service was accepted: %s\n' "$label" >&2
        exit 1
    fi
    if write_singbox_systemd_unit 2> "$case_root/rejection.log"; then
        printf 'FAIL: unsafe unit writer succeeded: %s\n' "$label" >&2
        exit 1
    fi
    [ ! -e "$RR_SINGBOX_SERVICE_FILE" ] && \
        [ ! -L "$RR_SINGBOX_SERVICE_FILE" ] || {
        printf 'FAIL: rejected writer published a unit: %s\n' "$label" >&2
        exit 1
    }
    if ! grep -Fq '[安全拒绝] Sing-box 服务或附加配置无法确认为 RR 自有；未覆盖服务文件。' \
        "$case_root/rejection.log"; then
        printf 'FAIL: rejection lacked its diagnostic: %s\n' "$label" >&2
        exit 1
    fi
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$label"
}

new_case
accepts 'fresh service with no drop-in directory'

new_case
install -d -m 755 -- "$dropin_dir"
accepts 'fresh service with an empty safe drop-in directory'

new_case
add_firewall_gate
accepts 'first Naive certificate firewall gate before unit creation'
cp -- "$firewall_file" "$case_root/firewall.before"
write_singbox_systemd_unit
cmp -s -- "$firewall_file" "$case_root/firewall.before"
cmp -s -- "$RR_SINGBOX_SERVICE_FILE" <(rr_render_singbox_systemd_unit)
[ "$(stat -c '%u:%g:%a:%h' -- "$RR_SINGBOX_SERVICE_FILE")" = 0:0:644:1 ]
passed=$((passed + 1))
printf '%s\n' 'PASS: real atomic writer creates the unit and preserves its firewall gate'

new_case
add_restore_gate
accepts 'canonical restore gate before unit creation'

new_case
add_firewall_gate
add_restore_gate
accepts 'both exact RR gates before unit creation'

new_case
add_firewall_gate
printf '%s\n' '[Service]' 'User=nobody' > "$dropin_dir/foreign.conf"
rejects 'foreign drop-in'

new_case
add_firewall_gate
printf '%s\n' '[Service]' 'ExecCondition=' >> "$firewall_file"
rejects 'modified firewall gate'

new_case
add_restore_gate
printf '%s\n' '# unexpected content' >> "$restore_file"
rejects 'modified restore gate'

new_case
add_firewall_gate
mv -- "$firewall_file" "$case_root/firewall.target"
ln -s -- "$case_root/firewall.target" "$firewall_file"
rejects 'symlinked gate'

new_case
add_firewall_gate
ln -- "$firewall_file" "$case_root/firewall.link"
rejects 'hard-linked gate'

new_case
add_firewall_gate
mv -- "$dropin_dir" "$case_root/dropins.target"
ln -s -- "$case_root/dropins.target" "$dropin_dir"
rejects 'symlinked drop-in directory'

new_case
add_firewall_gate
chmod 777 -- "$case_root"
rejects 'writable ancestor of the drop-in directory'

new_case
add_firewall_gate
chmod 600 -- "$firewall_file"
rejects 'unexpected gate permissions'

new_case
add_firewall_gate
if chown 1:1 -- "$firewall_file" 2>/dev/null; then
    rejects 'gate not owned by root'
else
    fixture_foreign_owner="$firewall_file"
    owner_metadata_injected=true
    rejects 'foreign gate owner metadata (injected because chown is unavailable)'
fi

new_case
add_firewall_gate
printf '%s\n' hidden > "$dropin_dir/.hidden"
rejects 'hidden unknown entry'

new_case
add_firewall_gate
mkdir -- "$dropin_dir/unknown-directory"
rejects 'unknown subdirectory'

new_case
add_firewall_gate
fixture_load=masked
rejects 'masked effective service'

new_case
add_firewall_gate
fixture_load=loaded
fixture_fragment=/usr/lib/systemd/system/sing-box.service
rejects 'loaded vendor service'

new_case
add_firewall_gate
fixture_fragment=/usr/lib/systemd/system/sing-box.service
rejects 'nonempty manager fragment even with not-found state'

new_case
add_firewall_gate
fixture_dropins="$firewall_file"
rejects 'nonempty effective DropInPaths keeps the original absent-unit boundary'

new_case
add_firewall_gate
fixture_dropins=/run/systemd/system/sing-box.service.d/foreign.conf
rejects 'foreign effective manager drop-in'

printf 'SINGBOX_ABSENT_OWNED_DROPINS_PASS cases=%s systemd=fixture owner_metadata_injected=%s services_started=false\n' \
    "$passed" "$owner_metadata_injected"
