#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

export PYTHONPATH="$REPO_ROOT/nexus${PYTHONPATH:+:$PYTHONPATH}"
RR_LIB_DIR="$REPO_ROOT"
RR_REPOSITORY="example/rr-vps"

# shellcheck disable=SC1091
source modules/55-resilience.sh
# shellcheck disable=SC1091
source modules/20-config.sh
# shellcheck disable=SC1091
source modules/30-singbox.sh
# shellcheck disable=SC1091
source modules/85-nexus.sh

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

expect_archive_reject() {
    local archive="$1"
    if python3 -m rr_nexus_lib.backup_archive inspect "$archive" >/dev/null 2>&1; then
        fail "Unsafe archive was accepted: $archive"
    fi
}

crypto_expect_reject() {
    local operation="$1" source="$2" target="$3"
    rm -f -- "$target"
    if python3 - "$operation" "$source" "$target" <<'PY'
import pathlib
import sys

from rr_nexus_lib.backup_crypto import decrypt, encrypt

operation, source, target = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
try:
    (encrypt if operation == "encrypt" else decrypt)(
        source, target, b"correct horse battery staple"
    )
except Exception:
    raise SystemExit(1)
raise SystemExit(0)
PY
    then
        fail "Unsafe crypto input was accepted: $operation $source"
    fi
    [ ! -e "$target" ] || fail "Rejected crypto input published an output: $target"
    if compgen -G "$(dirname "$target")/.$(basename "$target").rrtmp-*" >/dev/null; then
        fail "Rejected crypto input left a plaintext/ciphertext temporary file"
    fi
}

fixtures="$test_root/fixtures"
mkdir -p "$fixtures/safe/payload/rootfs/etc/rr-nexus"
printf '%s\n' '{"format":2,"version":"7.1.1"}' > "$fixtures/safe/payload/metadata.json"
printf '%s\n' 'example configuration' > "$fixtures/safe/payload/rootfs/etc/example.conf"
printf '%s\n' '{"enabled":true}' > "$fixtures/safe/payload/rootfs/etc/rr-nexus/nexus.json"
: > "$fixtures/safe/payload/crontab.txt"
printf '%s\n' 'placeholder manifest' > "$fixtures/safe/payload/manifest.sha256"

printf '%s\n' '[1/17] bounded payload validation and safe archive roundtrip'
python3 -m rr_nexus_lib.backup_archive validate-payload "$fixtures/safe/payload"
tar --format=ustar --numeric-owner --owner=0 --group=0 \
    -C "$fixtures/safe" -czf "$fixtures/safe.tar.gz" payload
python3 -m rr_nexus_lib.backup_archive inspect "$fixtures/safe.tar.gz"
mkdir -m 700 "$fixtures/extracted"
python3 -m rr_nexus_lib.backup_archive extract \
    "$fixtures/safe.tar.gz" "$fixtures/extracted"
diff -r "$fixtures/safe/payload" "$fixtures/extracted/payload"
[ "$(stat -c %a "$fixtures/extracted/payload")" = 700 ] || \
    fail 'Extracted payload directory mode is not 0700.'
[ "$(stat -c %a "$fixtures/extracted/payload/metadata.json")" = 600 ] || \
    fail 'Extracted file mode is not 0600.'

python3 - "$fixtures" <<'PY'
import gzip
import io
import pathlib
import tarfile

root = pathlib.Path(__import__("sys").argv[1])


def archive(name, members):
    with tarfile.open(root / name, "w:gz", format=tarfile.PAX_FORMAT) as handle:
        for member, content in members:
            handle.addfile(member, io.BytesIO(content) if content is not None else None)


traversal = tarfile.TarInfo("payload/rootfs/etc/../../../../escape")
traversal.size = 1
archive("traversal.tar.gz", [(traversal, b"x")])

link = tarfile.TarInfo("payload/rootfs/etc/link")
link.type = tarfile.SYMTYPE
link.linkname = "/etc/shadow"
archive("symlink.tar.gz", [(link, None)])

hardlink = tarfile.TarInfo("payload/rootfs/etc/hardlink")
hardlink.type = tarfile.LNKTYPE
hardlink.linkname = "payload/rootfs/etc/passwd"
archive("hardlink.tar.gz", [(hardlink, None)])

duplicate_a = tarfile.TarInfo("payload/rootfs/etc/duplicate")
duplicate_a.size = 0
duplicate_b = tarfile.TarInfo("payload/rootfs/etc/duplicate")
duplicate_b.size = 0
archive("duplicate.tar.gz", [(duplicate_a, None), (duplicate_b, None)])

with tarfile.open(root / "too-many.tar.gz", "w:gz", format=tarfile.USTAR_FORMAT) as handle:
    for number in range(10_001):
        member = tarfile.TarInfo(f"payload/rootfs/f{number}")
        member.size = 0
        handle.addfile(member)


def header_only(name, member, tar_format):
    with gzip.open(root / name, "wb") as output:
        output.write(member.tobuf(format=tar_format))


huge = tarfile.TarInfo("payload/rootfs/huge")
huge.size = 2 * 1024**3 + 1
header_only("huge-first-member.tar.gz", huge, tarfile.USTAR_FORMAT)

pax = tarfile.TarInfo("PaxHeader")
pax.type = tarfile.XHDTYPE
pax.size = 64 * 1024 + 1
header_only("huge-pax.tar.gz", pax, tarfile.PAX_FORMAT)

gnu = tarfile.TarInfo("././@LongLink")
gnu.type = tarfile.GNUTYPE_LONGNAME
gnu.size = 4096 + tarfile.BLOCKSIZE + 1
header_only("huge-gnu-longname.tar.gz", gnu, tarfile.GNU_FORMAT)
PY

printf '%s\n' '[2/17] path traversal is rejected before extraction'
expect_archive_reject "$fixtures/traversal.tar.gz"
mkdir -m 700 "$fixtures/traversal-target"
if python3 -m rr_nexus_lib.backup_archive extract \
    "$fixtures/traversal.tar.gz" "$fixtures/traversal-target" >/dev/null 2>&1; then
    fail 'Path-traversal archive was extracted.'
fi
[ ! -e "$test_root/escape" ] || fail 'Path-traversal archive escaped its target.'
[ -z "$(find "$fixtures/traversal-target" -mindepth 1 -print -quit)" ] || \
    fail 'Rejected path-traversal archive partially populated its target.'

printf '%s\n' '[3/17] symbolic-link members are rejected'
expect_archive_reject "$fixtures/symlink.tar.gz"

printf '%s\n' '[4/17] hard-link members are rejected'
expect_archive_reject "$fixtures/hardlink.tar.gz"

printf '%s\n' '[5/17] duplicate canonical members are rejected'
expect_archive_reject "$fixtures/duplicate.tar.gz"

printf '%s\n' '[6/17] the 10000-member limit rejects member 10001'
expect_archive_reject "$fixtures/too-many.tar.gz"

printf '%s\n' '[7/17] an oversized first member is rejected from its header'
expect_archive_reject "$fixtures/huge-first-member.tar.gz"

printf '%s\n' '[8/17] oversized PAX and GNU extended headers are rejected early'
expect_archive_reject "$fixtures/huge-pax.tar.gz"
expect_archive_reject "$fixtures/huge-gnu-longname.tar.gz"

printf '%s\n' '[9/17] authenticated encryption roundtrip rejects tampering atomically'
crypto_dir="$test_root/crypto"
mkdir "$crypto_dir"
python3 - "$fixtures/safe.tar.gz" "$crypto_dir/backup.rrbak" "$crypto_dir/plain.tar.gz" <<'PY'
import pathlib
import sys

from rr_nexus_lib.backup_crypto import decrypt, encrypt

source, encrypted, plaintext = map(pathlib.Path, sys.argv[1:])
password = b"correct horse battery staple"
encrypt(source, encrypted, password)
decrypt(encrypted, plaintext, password)
PY
cmp "$fixtures/safe.tar.gz" "$crypto_dir/plain.tar.gz"
[ "$(stat -c %a "$crypto_dir/backup.rrbak")" = 600 ] || \
    fail 'Encrypted backup mode is not 0600.'
[ "$(stat -c %a "$crypto_dir/plain.tar.gz")" = 600 ] || \
    fail 'Decrypted archive mode is not 0600.'
cp "$crypto_dir/backup.rrbak" "$crypto_dir/tampered.rrbak"
python3 - "$crypto_dir/tampered.rrbak" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("r+b") as handle:
    handle.seek(48)
    original = handle.read(1)
    if not original:
        raise SystemExit("encrypted fixture is unexpectedly short")
    handle.seek(48)
    handle.write(bytes((original[0] ^ 1,)))
PY
crypto_expect_reject decrypt "$crypto_dir/tampered.rrbak" "$crypto_dir/tampered.out"

printf '%s\n' '[10/17] crypto rejects symlink, FIFO and oversized sparse inputs'
ln -s "$fixtures/safe.tar.gz" "$crypto_dir/source-link"
crypto_expect_reject encrypt "$crypto_dir/source-link" "$crypto_dir/link.rrbak"
mkfifo "$crypto_dir/source-fifo"
set +e
timeout 5 bash -c '
    export PYTHONPATH="$1"
    source_file="$2"
    target_file="$3"
    python3 - "$source_file" "$target_file" <<"PY"
import pathlib
import sys
from rr_nexus_lib.backup_crypto import encrypt
try:
    encrypt(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), b"correct horse battery staple")
except Exception:
    raise SystemExit(1)
raise SystemExit(0)
PY
' _ "$PYTHONPATH" "$crypto_dir/source-fifo" "$crypto_dir/fifo.rrbak"
fifo_status=$?
set -e
[ "$fifo_status" -ne 0 ] || fail 'FIFO crypto input was accepted.'
[ "$fifo_status" -ne 124 ] || fail 'FIFO crypto input blocked until timeout.'
[ ! -e "$crypto_dir/fifo.rrbak" ] || fail 'FIFO input published an encrypted output.'
truncate -s $((2 * 1024 * 1024 * 1024 + 16 * 1024 * 1024 + 1)) \
    "$crypto_dir/oversized-sparse.tar.gz"
crypto_expect_reject encrypt \
    "$crypto_dir/oversized-sparse.tar.gz" "$crypto_dir/oversized.rrbak"

printf '%s\n' '[11/17] publication races cannot redirect the final 0600 permission change'
python3 - "$fixtures/safe.tar.gz" "$crypto_dir" <<'PY'
import os
import pathlib
import stat
import sys

import rr_nexus_lib.backup_crypto as backup_crypto

source = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
victim = root / "permission-victim"
victim.write_bytes(b"do not chmod through a symlink")
victim.chmod(0o755)
target = root / "raced.rrbak"
real_link = backup_crypto.os.link


def replace_after_link(source_path, target_path, *, follow_symlinks=True):
    real_link(source_path, target_path, follow_symlinks=follow_symlinks)
    pathlib.Path(target_path).unlink()
    pathlib.Path(target_path).symlink_to(victim)


backup_crypto.os.link = replace_after_link
try:
    try:
        backup_crypto.encrypt(source, target, b"correct horse battery staple")
    except Exception:
        pass
    else:
        raise SystemExit("target replacement during publication was accepted")
finally:
    backup_crypto.os.link = real_link

if stat.S_IMODE(victim.stat().st_mode) != 0o755:
    raise SystemExit("publication race changed the symlink target permissions")
if not target.is_symlink():
    raise SystemExit("race fixture did not replace the publication target")
target.unlink()

target.symlink_to(victim)
try:
    backup_crypto.encrypt(source, target, b"correct horse battery staple")
except FileExistsError:
    pass
except Exception:
    pass
else:
    raise SystemExit("pre-existing symlink target was overwritten")
if stat.S_IMODE(victim.stat().st_mode) != 0o755:
    raise SystemExit("pre-existing symlink target permissions changed")
PY
if grep -Fq 'chmod 600 "$output"' modules/55-resilience.sh; then
    fail 'Shell still chmods the published backup path.'
fi

printf '%s\n' '[12/17] backup work directory enforces canonical root-owned 0700 state'
RR_BACKUP_WORK_DIR="$test_root/work"
rr_backup_prepare_work_dir || fail 'A safe backup work directory was rejected.'
[ "$(stat -c '%u:%g:%a' "$RR_BACKUP_WORK_DIR")" = 0:0:700 ] || \
    fail 'Backup work directory does not have root:root 0700 state.'
chmod 777 "$RR_BACKUP_WORK_DIR"
rr_backup_prepare_work_dir || fail 'Correctable work-directory mode was rejected.'
[ "$(stat -c %a "$RR_BACKUP_WORK_DIR")" = 700 ] || \
    fail 'Backup work directory mode was not repaired to 0700.'
mkdir "$test_root/work-target"
ln -s "$test_root/work-target" "$test_root/work-link"
RR_BACKUP_WORK_DIR="$test_root/work-link"
if rr_backup_prepare_work_dir; then
    fail 'A symlink backup work directory was accepted.'
fi
mkdir "$test_root/work-unowned"
if (
    RR_BACKUP_WORK_DIR="$test_root/work-unowned"
    stat() {
        if [ "${1:-}" = -c ] && [ "${2:-}" = '%u:%g' ] && \
            [ "${3:-}" = "$RR_BACKUP_WORK_DIR" ]; then
            printf '%s\n' '65534:65534'
        else
            command stat "$@"
        fi
    }
    rr_backup_prepare_work_dir
); then
    fail 'A non-root-owned backup work directory was accepted.'
fi

printf '%s\n' '[13/17] staging directories reject bad names, links, modes and owners'
RR_BACKUP_WORK_DIR="$test_root/stages"
rr_backup_prepare_work_dir
mkdir -m 700 "$RR_BACKUP_WORK_DIR/create.good" "$RR_BACKUP_WORK_DIR/restore.good"
rr_backup_stage_is_safe "$RR_BACKUP_WORK_DIR/create.good" create || \
    fail 'A safe create stage was rejected.'
rr_backup_stage_is_safe "$RR_BACKUP_WORK_DIR/restore.good" restore || \
    fail 'A safe restore stage was rejected.'
chmod 755 "$RR_BACKUP_WORK_DIR/create.good"
if rr_backup_stage_is_safe "$RR_BACKUP_WORK_DIR/create.good" create; then
    fail 'A group/world-accessible stage was accepted.'
fi
mkdir -m 700 "$RR_BACKUP_WORK_DIR/restore.bad-name"
if rr_backup_stage_is_safe "$RR_BACKUP_WORK_DIR/restore.bad-name" restore; then
    fail 'A stage with an invalid name was accepted.'
fi
ln -s "$RR_BACKUP_WORK_DIR/restore.good" "$RR_BACKUP_WORK_DIR/restore.link"
if rr_backup_stage_is_safe "$RR_BACKUP_WORK_DIR/restore.link" restore; then
    fail 'A symlink restore stage was accepted.'
fi
mkdir -m 700 "$RR_BACKUP_WORK_DIR/restore.unowned"
if (
    stat() {
        if [ "${1:-}" = -c ] && [ "${2:-}" = '%u:%g:%a' ]; then
            printf '%s\n' '65534:65534:700'
        else
            command stat "$@"
        fi
    }
    rr_backup_stage_is_safe "$RR_BACKUP_WORK_DIR/restore.unowned" restore
); then
    fail 'A non-root-owned restore stage was accepted.'
fi
if rr_backup_stage_is_safe "$test_root/outside"; then
    fail 'A stage outside the work directory was accepted.'
fi

printf '%s\n' '[14/17] configured Nexus rejects missing, empty and wrong-schema databases'
nexus_dir="$test_root/nexus"
mkdir -p "$nexus_dir"
printf '%s\n' '{}' > "$nexus_dir/nexus.json"
for invalid in missing empty wrong; do
    stage="$nexus_dir/stage-$invalid"
    mkdir -p "$stage"
    database="$nexus_dir/$invalid.db"
    case "$invalid" in
        missing) rm -f "$database" ;;
        empty) : > "$database" ;;
        wrong)
            python3 - "$database" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("CREATE TABLE unrelated (id INTEGER PRIMARY KEY)")
connection.commit()
connection.close()
PY
            ;;
    esac
    if (
        NEXUS_CONFIG_FILE="$nexus_dir/nexus.json"
        NEXUS_DB_FILE="$database"
        rr_backup_capture_nexus_consistent "$stage"
    ) >/dev/null 2>&1; then
        fail "Configured Nexus accepted its $invalid database."
    fi
done

printf '%s\n' '[15/17] a minimal valid Nexus database is snapshotted consistently'
valid_db="$nexus_dir/valid.db"
python3 - "$valid_db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
for table in ("admins", "devices", "schema_migrations"):
    connection.execute(f"CREATE TABLE {table} (id INTEGER PRIMARY KEY)")
connection.commit()
connection.close()
PY
valid_stage="$nexus_dir/stage-valid"
mkdir "$valid_stage"
(
    NEXUS_CONFIG_FILE="$nexus_dir/nexus.json"
    NEXUS_DB_FILE="$valid_db"
    rr_backup_capture_nexus_consistent "$valid_stage"
)
snapshot="$valid_stage/rootfs/var/lib/rr-nexus/nexus.db"
[ -s "$snapshot" ] || fail 'Valid Nexus snapshot was not created.'
[ "$(stat -c %a "$snapshot")" = 600 ] || fail 'Nexus snapshot mode is not 0600.'
python3 - "$snapshot" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
tables = {row[0] for row in connection.execute(
    "SELECT name FROM sqlite_master WHERE type='table'"
)}
connection.close()
if not {"admins", "devices", "schema_migrations"}.issubset(tables):
    raise SystemExit("Nexus snapshot lost required tables")
PY

printf '%s\n' '[16/17] target shape is mount/mode safe and full replay preserves empty directories'
(
    shape_parent="$test_root/target-shape"
    shape_counter=0
    mutation_log="$shape_parent/mutation.log"
    mkdir -p "$shape_parent"

    new_safe_shape() {
        shape_counter=$((shape_counter + 1))
        SHAPE_ROOT="$shape_parent/case-${shape_counter}"
        CONFIG_FILE="$SHAPE_ROOT/etc/argo_vmess.conf"
        SHAPE_MOUNTINFO="$SHAPE_ROOT/mountinfo"
        mkdir -p \
            "$SHAPE_ROOT/etc/systemd/system" \
            "$SHAPE_ROOT/usr/local/bin" \
            "$SHAPE_ROOT/var/lib/rr-nexus/subscriptions" \
            "$SHAPE_ROOT/tmp/sub_server/client-route" \
            "$SHAPE_ROOT/etc/nginx/sites-available" \
            "$SHAPE_ROOT/etc/nginx/sites-enabled" \
            "$SHAPE_ROOT/etc/sing-box" \
            "$SHAPE_ROOT/etc/rr-nexus/certs" \
            "$SHAPE_ROOT/etc/rr-naive" \
            "$SHAPE_ROOT/etc/rr-update" \
            "$SHAPE_ROOT/etc/rr-cloudflared"
        chmod 1777 "$SHAPE_ROOT/tmp"
        # The ancestor /etc record deliberately shares the root device, as a
        # bind mount can.  Ancestors are safe; an exact/nested managed target is
        # not.  The escaped unrelated path proves kernel mountinfo decoding.
        printf '%s\n' \
            '1 0 8:1 / / rw,relatime - ext4 /dev/root rw' \
            '2 1 8:1 /etc /etc rw,relatime - ext4 /dev/root rw' \
            '3 1 8:1 /mnt/safe\040name /mnt/safe\040name rw,relatime - ext4 /dev/root rw' \
            > "$SHAPE_MOUNTINFO"
        printf '%s\n' 'CONFIG_VERSION=9' > "$CONFIG_FILE"
        printf '%s\n' '{}' > "$SHAPE_ROOT/etc/sing-box/config.json"
        printf '%s\n' '{}' > "$SHAPE_ROOT/etc/rr-nexus/nexus.json"
        printf '%s\n' cert > "$SHAPE_ROOT/etc/rr-nexus/certs/ip.crt"
        printf '%s\n' key > "$SHAPE_ROOT/etc/rr-naive/privkey.pem"
        printf '%s\n' stable > "$SHAPE_ROOT/etc/rr-update/channel"
        printf '%s\n' token > "$SHAPE_ROOT/etc/rr-cloudflared/token"
        printf '%s\n' remote > "$SHAPE_ROOT/var/lib/rr-nexus/remote.key"
        printf '%s\n' database > "$SHAPE_ROOT/var/lib/rr-nexus/nexus.db"
        printf '%s\n' derived > "$SHAPE_ROOT/var/lib/rr-nexus/subscriptions/device.txt"
        # Derived public routes legitimately contain RR-created links.  Only
        # their top-level deletion boundary is part of the shape contract.
        ln -s ../target "$SHAPE_ROOT/tmp/sub_server/client-route/token"
        printf '%s\n' worker > "$SHAPE_ROOT/usr/local/bin/auto_update_sub.py"
        for unit in sing-box.service rr-nexus.service argo-rr-health.service \
            argo-rr-health.timer cloudflared.service \
            rr-restore-recovery.service rr-restore-watchdog.service; do
            printf '%s\n' '[Unit]' > "$SHAPE_ROOT/etc/systemd/system/$unit"
        done
        for unit in sing-box.service rr-nexus.service rr-subscription.service \
            cloudflared.service nginx.service argo-rr-health.service \
            argo-rr-health.timer rr-restore-recovery.service \
            rr-restore-watchdog.service; do
            mkdir -p "$SHAPE_ROOT/etc/systemd/system/${unit}.d"
            printf '%s\n' '[Service]' > \
                "$SHAPE_ROOT/etc/systemd/system/${unit}.d/40-rr-restore-gate.conf"
        done
        printf '%s\n' site > "$SHAPE_ROOT/etc/nginx/sites-available/rr-nexus.conf"
        printf '%s\n' port > "$SHAPE_ROOT/etc/nginx/sites-available/rr-nexus.conf.port"
        printf '%s\n' ip > "$SHAPE_ROOT/etc/nginx/sites-available/rr-nexus-ip.conf"
        ln -s "$SHAPE_ROOT/etc/nginx/sites-available/rr-nexus.conf" \
            "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus.conf"
        ln -s "$SHAPE_ROOT/etc/nginx/sites-available/rr-nexus.conf.port" \
            "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus-port.conf"
        ln -s "$SHAPE_ROOT/etc/nginx/sites-available/rr-nexus-ip.conf" \
            "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus-ip.conf"
    }

    shape_fingerprint() {
        find "$SHAPE_ROOT" -xdev -printf '%P|%y|%m|%U|%G|%s|%l\n' \
            | LC_ALL=C sort | sha256sum | awk '{print $1}'
    }

    expect_shape_reject() {
        local label="$1" before="" after=""
        before=$(shape_fingerprint)
        : > "$mutation_log"
        if rr_restore_validate_target_snapshot_shape \
             "$SHAPE_ROOT" "$SHAPE_MOUNTINFO" \
             >/dev/null 2>&1; then
            fail "Unsafe target snapshot shape was accepted: $label"
        fi
        after=$(shape_fingerprint)
        [ "$after" = "$before" ] ||
            fail "Target shape validation mutated the filesystem: $label"
        [ ! -s "$mutation_log" ] ||
            fail "Target shape validation invoked a mutating helper: $label"
    }

    systemctl() { printf '%s\n' systemctl >> "$mutation_log"; return 1; }
    certbot() { printf '%s\n' certbot >> "$mutation_log"; return 1; }
    open_configured_firewall() {
        printf '%s\n' firewall >> "$mutation_log"
        return 1
    }
    rr_restore_migrate_legacy_fixed_token() {
        printf '%s\n' legacy-token >> "$mutation_log"
        return 1
    }

    new_safe_shape
    rr_restore_validate_target_snapshot_shape \
        "$SHAPE_ROOT" "$SHAPE_MOUNTINFO" ||
        fail 'A regular root-owned target and exact RR Nginx links were rejected.'

    new_safe_shape
    printf '%s\n' \
        "4 1 8:1 /etc/sing-box $SHAPE_ROOT/etc/sing-box rw,relatime - ext4 /dev/root rw" \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject managed-root-bind-mount

    new_safe_shape
    printf '%s\n' \
        '4 1 8:1 /etc/rr-nexus/certs /etc/rr-nexus/certs rw,relatime - ext4 /dev/root rw' \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject nested-managed-bind-mount

    new_safe_shape
    printf '%s\n' \
        '4 1 8:1 /etc/argo_vmess.conf /etc/argo_vmess.conf rw,relatime - ext4 /dev/root rw' \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject exact-config-mount

    new_safe_shape
    printf '%s\n' \
        '4 1 8:1 /etc/nginx/sites-enabled /etc/nginx/sites-enabled rw,relatime - ext4 /dev/root rw' \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject nginx-writer-parent-mount

    new_safe_shape
    printf '%s\n' \
        '4 1 8:1 /etc/systemd/system/nginx.service.d /etc/systemd/system/nginx.service.d rw,relatime - ext4 /dev/root rw' \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject restore-dropin-mount

    new_safe_shape
    printf '%s\n' \
        '4 1 8:1 /bad\999escape /bad\999escape rw,relatime - ext4 /dev/root rw' \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject invalid-mountinfo-escape

    new_safe_shape
    rm -f "$CONFIG_FILE"
    ln -s "$SHAPE_ROOT/missing-config" "$CONFIG_FILE"
    expect_shape_reject dangling-config

    new_safe_shape
    mv "$SHAPE_ROOT/etc/systemd/system/sing-box.service" "$SHAPE_ROOT/live-unit"
    ln -s "$SHAPE_ROOT/live-unit" "$SHAPE_ROOT/etc/systemd/system/sing-box.service"
    expect_shape_reject live-unit-link

    new_safe_shape
    rm -f "$SHAPE_ROOT/etc/systemd/system/rr-nexus.service"
    ln -s "$SHAPE_ROOT/missing-unit" "$SHAPE_ROOT/etc/systemd/system/rr-nexus.service"
    expect_shape_reject dangling-unit-link

    new_safe_shape
    ln -s /etc/passwd "$SHAPE_ROOT/etc/rr-nexus/foreign-link"
    expect_shape_reject nested-managed-link

    new_safe_shape
    mv "$SHAPE_ROOT/etc/rr-naive" "$SHAPE_ROOT/rr-naive-real"
    ln -s "$SHAPE_ROOT/rr-naive-real" "$SHAPE_ROOT/etc/rr-naive"
    expect_shape_reject managed-directory-link

    new_safe_shape
    mkfifo "$SHAPE_ROOT/etc/rr-update/unsupported-fifo"
    expect_shape_reject nested-special-file

    new_safe_shape
    ln "$SHAPE_ROOT/etc/sing-box/config.json" "$SHAPE_ROOT/hardlink-alias"
    expect_shape_reject nested-hardlink

    new_safe_shape
    ln "$SHAPE_ROOT/var/lib/rr-nexus/remote.key" \
        "$SHAPE_ROOT/remote-key-hardlink"
    expect_shape_reject key-hardlink

    new_safe_shape
    mv "$SHAPE_ROOT/tmp/sub_server" "$SHAPE_ROOT/sub-server-real"
    ln -s "$SHAPE_ROOT/sub-server-real" "$SHAPE_ROOT/tmp/sub_server"
    expect_shape_reject derived-root-link

    new_safe_shape
    mv "$SHAPE_ROOT/etc/nginx/sites-enabled" "$SHAPE_ROOT/nginx-enabled-real"
    ln -s "$SHAPE_ROOT/nginx-enabled-real" "$SHAPE_ROOT/etc/nginx/sites-enabled"
    expect_shape_reject nginx-parent-link

    new_safe_shape
    rm -f "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus.conf"
    ln -s /etc/passwd "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus.conf"
    expect_shape_reject foreign-nginx-link

    new_safe_shape
    rm -f "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus-port.conf"
    printf '%s\n' enabled > \
        "$SHAPE_ROOT/etc/nginx/sites-enabled/rr-nexus-port.conf"
    expect_shape_reject nginx-enablement-regular-file

    new_safe_shape
    rm -f "$SHAPE_ROOT/etc/systemd/system/cloudflared.service"
    ln -s "$SHAPE_ROOT/live-unit" "$SHAPE_ROOT/etc/systemd/system/cloudflared.service"
    expect_shape_reject cloudflared-unit-link

    new_safe_shape
    rm -f "$SHAPE_ROOT/etc/systemd/system/rr-restore-watchdog.service"
    ln -s "$SHAPE_ROOT/missing-watchdog" \
        "$SHAPE_ROOT/etc/systemd/system/rr-restore-watchdog.service"
    expect_shape_reject recovery-unit-link

    new_safe_shape
    mv "$SHAPE_ROOT/etc/systemd/system/nginx.service.d" \
        "$SHAPE_ROOT/nginx-dropin-real"
    ln -s "$SHAPE_ROOT/nginx-dropin-real" \
        "$SHAPE_ROOT/etc/systemd/system/nginx.service.d"
    expect_shape_reject restore-gate-parent-link

    new_safe_shape
    printf '%s\n' '[Service]' > \
        "$SHAPE_ROOT/etc/systemd/system/nginx.service.d/unmanaged.conf"
    chmod 666 "$SHAPE_ROOT/etc/systemd/system/nginx.service.d/unmanaged.conf"
    expect_shape_reject writable-unmanaged-dropin

    new_safe_shape
    printf '%s\n' '[Service]' 'ExecCondition=' > \
        "$SHAPE_ROOT/etc/systemd/system/nginx.service.d/zzzzz-hostile-reset.conf"
    expect_shape_reject later-restore-gate-reset

    new_safe_shape
    chmod 777 \
        "$SHAPE_ROOT/etc/systemd/system/rr-restore-watchdog.service.d"
    printf '%s\n' '[Service]' 'ExecStart=/tmp/adversary' > \
        "$SHAPE_ROOT/etc/systemd/system/rr-restore-watchdog.service.d/override.conf"
    chmod 666 \
        "$SHAPE_ROOT/etc/systemd/system/rr-restore-watchdog.service.d/override.conf"
    expect_shape_reject writable-watchdog-dropin

    new_safe_shape
    printf '%s\n' \
        '4 1 8:1 /etc/systemd/system/rr-restore-recovery.service.d /etc/systemd/system/rr-restore-recovery.service.d rw,relatime - ext4 /dev/root rw' \
        >> "$SHAPE_MOUNTINFO"
    expect_shape_reject recovery-dropin-mount

    new_safe_shape
    ln -s /etc/passwd \
        "$SHAPE_ROOT/etc/systemd/system/nginx.service.d/unmanaged.conf"
    expect_shape_reject linked-unmanaged-dropin

    new_safe_shape
    chmod 775 "$SHAPE_ROOT/etc/rr-update"
    expect_shape_reject writable-managed-directory

    new_safe_shape
    chmod 666 "$SHAPE_ROOT/etc/systemd/system/rr-nexus.service"
    expect_shape_reject writable-privileged-unit

    new_safe_shape
    # Some container-backed scratch filesystems deliberately reject ownership
    # changes even for uid 0.  Exercise the owner gate wherever the filesystem
    # can represent the adversarial state; the release-gate mutation below
    # still enforces the check on every platform.
    if chown 65534:65534 \
         "$SHAPE_ROOT/etc/systemd/system/argo-rr-health.timer" 2>/dev/null; then
        expect_shape_reject non-root-unit
    fi

    replay="$shape_parent/full-replay"
    replay_destination="$shape_parent/full-destination"
    mkdir -p \
        "$replay/rootfs/etc/sing-box/empty/deep" \
        "$replay/rootfs/etc/rr-naive/private-empty" \
        "$replay_destination"
    printf '%s\n' '{}' > "$replay/rootfs/etc/sing-box/config.json"
    chmod 750 "$replay/rootfs/etc/sing-box"
    chmod 710 "$replay/rootfs/etc/sing-box/empty"
    chmod 700 "$replay/rootfs/etc/sing-box/empty/deep"
    chmod 750 "$replay/rootfs/etc/rr-naive"
    chmod 700 "$replay/rootfs/etc/rr-naive/private-empty"
    rr_restore_apply_tree "$replay" full "$replay_destination" ||
        fail 'Full rollback tree replay failed for safe empty directories.'
    [ -d "$replay_destination/etc/sing-box/empty/deep" ] &&
        [ -d "$replay_destination/etc/rr-naive/private-empty" ] ||
        fail 'Full rollback replay discarded an empty managed directory.'
    [ "$(stat -c %a "$replay_destination/etc/sing-box")" = 750 ] &&
        [ "$(stat -c %a "$replay_destination/etc/sing-box/empty")" = 710 ] &&
        [ "$(stat -c %a "$replay_destination/etc/sing-box/empty/deep")" = 700 ] &&
        [ "$(stat -c %a "$replay_destination/etc/rr-naive")" = 750 ] ||
        fail 'Full rollback replay did not restore safe directory modes.'
)

printf '%s\n' '[17/17] portable certificate restore requires trusted pre-mutation state'
(
    renewable_root="$test_root/renewable-lineage"
    RR_LE_CONFIG_ROOT="$renewable_root/etc/letsencrypt"
    RR_LE_LIVE_ROOT="$RR_LE_CONFIG_ROOT/live"
    RR_LE_ARCHIVE_ROOT="$RR_LE_CONFIG_ROOT/archive"
    RR_LE_RENEWAL_ROOT="$RR_LE_CONFIG_ROOT/renewal"
    RR_LE_ACCOUNTS_ROOT="$RR_LE_CONFIG_ROOT/accounts"
    RR_NAIVE_ACME_WEBROOT="$renewable_root/var/www/rr-nexus-certbot"
    renewable_domain=renewable.example.net
    renewable_account=0123456789abcdef0123456789abcdef
    renewable_live="$RR_LE_LIVE_ROOT/$renewable_domain"
    renewable_archive="$RR_LE_ARCHIVE_ROOT/$renewable_domain"
    renewable_account_dir="$RR_LE_ACCOUNTS_ROOT/acme-v02.api.letsencrypt.org/directory/$renewable_account"
    renewable_conf="$RR_LE_RENEWAL_ROOT/$renewable_domain.conf"
    mkdir -p "$renewable_live" "$renewable_archive" "$RR_LE_RENEWAL_ROOT" \
        "$renewable_account_dir" \
        "$RR_NAIVE_ACME_WEBROOT/.well-known/acme-challenge"
    chmod -R go-w "$RR_LE_CONFIG_ROOT" "$RR_NAIVE_ACME_WEBROOT"
    chmod 700 "$renewable_account_dir"

    renewable_ca_key="$test_root/renewable-ca.key"
    renewable_ca_cert="$test_root/renewable-ca.crt"
    renewable_csr="$test_root/renewable.csr"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj '/CN=RR renewable lineage test CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$renewable_ca_key" -out "$renewable_ca_cert" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes \
        -subj "/CN=$renewable_domain" \
        -addext "subjectAltName=DNS:$renewable_domain" \
        -keyout "$renewable_archive/privkey1.pem" \
        -out "$renewable_csr" >/dev/null 2>&1
    openssl x509 -req -days 30 -in "$renewable_csr" \
        -CA "$renewable_ca_cert" -CAkey "$renewable_ca_key" \
        -CAcreateserial -copy_extensions copy \
        -out "$renewable_archive/cert1.pem" >/dev/null 2>&1
    cp "$renewable_ca_cert" "$renewable_archive/chain1.pem"
    {
        cat "$renewable_archive/cert1.pem"
        cat "$renewable_archive/chain1.pem"
    } > "$renewable_archive/fullchain1.pem"
    chmod 600 "$renewable_archive/privkey1.pem"
    chmod 644 "$renewable_archive/cert1.pem" "$renewable_archive/chain1.pem" \
        "$renewable_archive/fullchain1.pem"
    for stem in cert privkey chain fullchain; do
        ln -s "../../archive/$renewable_domain/${stem}1.pem" \
            "$renewable_live/${stem}.pem"
    done
    cat > "$renewable_conf" <<EOF
version = 2.11.0
archive_dir = $renewable_archive
cert = $renewable_live/cert.pem
privkey = $renewable_live/privkey.pem
chain = $renewable_live/chain.pem
fullchain = $renewable_live/fullchain.pem

[renewalparams]
account = $renewable_account
authenticator = webroot
server = https://acme-v02.api.letsencrypt.org/directory
autorenew = True
config_dir = $RR_LE_CONFIG_ROOT

[[webroot_map]]
$renewable_domain = $RR_NAIVE_ACME_WEBROOT
EOF
    account_key="$test_root/renewable-account.pem"
    account_der="$test_root/renewable-account.der"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$account_key" >/dev/null 2>&1
    openssl pkey -in "$account_key" -outform DER -out "$account_der" \
        >/dev/null 2>&1
    python3 - "$account_der" "$renewable_account_dir/private_key.json" <<'PY'
import base64
import json
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()


def read_length(offset):
    first = data[offset]
    offset += 1
    if first < 128:
        return first, offset
    count = first & 0x7f
    if not count or count > 4:
        raise SystemExit("invalid RSA DER length")
    return int.from_bytes(data[offset:offset + count], "big"), offset + count


def read_value(offset, tag):
    if offset >= len(data) or data[offset] != tag:
        raise SystemExit("invalid RSA DER tag")
    length, start = read_length(offset + 1)
    end = start + length
    if end > len(data):
        raise SystemExit("truncated RSA DER")
    return data[start:end], end


sequence, outer_end = read_value(0, 0x30)
if outer_end != len(data):
    raise SystemExit("trailing RSA DER")
data = sequence
values = []
offset = 0
while offset < len(data):
    encoded, offset = read_value(offset, 0x02)
    if encoded and encoded[0] == 0:
        encoded = encoded[1:]
    values.append(int.from_bytes(encoded, "big"))
if len(values) != 9 or values[0] != 0:
    raise SystemExit("unexpected RSA private key")


def b64uint(value):
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


names = ("n", "e", "d", "p", "q", "dp", "dq", "qi")
jwk = {"kty": "RSA"}
jwk.update({name: b64uint(value) for name, value in zip(names, values[1:])})
pathlib.Path(sys.argv[2]).write_text(json.dumps(jwk, sort_keys=True) + "\n", encoding="utf-8")
PY
    canonical_account=$(
        openssl pkey -in "$account_key" -pubout 2>/dev/null |
            md5sum | awk '{print $1}'
    )
    [[ "$canonical_account" =~ ^[0-9a-f]{32}$ ]] ||
        fail 'Could not derive the canonical Certbot account identifier.'
    canonical_account_dir="$RR_LE_ACCOUNTS_ROOT/acme-v02.api.letsencrypt.org/directory/$canonical_account"
    mv "$renewable_account_dir" "$canonical_account_dir"
    renewable_account="$canonical_account"
    renewable_account_dir="$canonical_account_dir"
    sed -i "s/^account = .*/account = $renewable_account/" "$renewable_conf"
    printf '%s\n' \
        '{"body":{},"uri":"https://acme-v02.api.letsencrypt.org/acme/acct/123456"}' \
        > "$renewable_account_dir/regr.json"
    printf '%s\n' \
        '{"creation_dt":"2026-08-31T00:00:00Z","creation_host":"rr-test"}' \
        > "$renewable_account_dir/meta.json"
    chmod 400 "$renewable_account_dir/private_key.json"
    chmod 644 "$renewable_account_dir/regr.json" "$renewable_account_dir/meta.json"
    is_valid_domain() {
        [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
    }

    lineage_fingerprint() {
        {
            find -P "$renewable_root" -printf '%P|%y|%m|%U|%G|%s|%l\n' |
                LC_ALL=C sort
            find -P "$renewable_root" -type f -print0 |
                LC_ALL=C sort -z | xargs -0 sha256sum
        } | sha256sum | awk '{print $1}'
    }
    renewable_before=$(lineage_fingerprint)
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'A complete production Webroot lineage was rejected.'
    renewable_after=$(lineage_fingerprint)
    [ "$renewable_before" = "$renewable_after" ] ||
        fail 'Renewable lineage validation mutated its fixture.'

    v2_account_directory="$RR_LE_ACCOUNTS_ROOT/acme-v02.api.letsencrypt.org/directory"
    v1_account_directory="$RR_LE_ACCOUNTS_ROOT/acme-v01.api.letsencrypt.org/directory"
    install -d -m 700 "$(dirname "$v1_account_directory")"
    mv "$v2_account_directory" "$v1_account_directory"
    ln -s ../acme-v01.api.letsencrypt.org/directory "$v2_account_directory"
    renewable_account_dir="$v1_account_directory/$renewable_account"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'Certbot official v2-to-v1 production account reuse alias was rejected.'
    rm -f "$v2_account_directory"
    ln -s /tmp/attacker-account-directory "$v2_account_directory"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'An absolute or non-official production account directory alias passed validation.'
    fi
    rm -f "$v2_account_directory"
    mv "$v1_account_directory" "$v2_account_directory"
    renewable_account_dir="$v2_account_directory/$renewable_account"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'The lineage was not accepted after restoring the direct v2 account directory.'

    webroot_parent=$(dirname "$RR_NAIVE_ACME_WEBROOT")
    chmod 777 "$webroot_parent"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A lineage below a group/other-writable Webroot ancestor passed validation.'
    fi
    chmod 755 "$webroot_parent"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'The lineage was not accepted after restoring its Webroot ancestor mode.'

    cert_backup="$test_root/renewable-cert.backup"
    key_backup="$test_root/renewable-key.backup"
    chain_backup="$test_root/renewable-chain.backup"
    fullchain_backup="$test_root/renewable-fullchain.backup"
    jwk_backup="$test_root/renewable-jwk.backup"
    cp "$renewable_archive/cert1.pem" "$cert_backup"
    cp "$renewable_archive/privkey1.pem" "$key_backup"
    cp "$renewable_archive/chain1.pem" "$chain_backup"
    cp "$renewable_archive/fullchain1.pem" "$fullchain_backup"
    cp "$renewable_account_dir/private_key.json" "$jwk_backup"

    wrong_account=00000000000000000000000000000000
    [ "$wrong_account" != "$renewable_account" ] ||
        wrong_account=11111111111111111111111111111111
    wrong_account_dir="${renewable_account_dir%/*}/$wrong_account"
    mv "$renewable_account_dir" "$wrong_account_dir"
    sed -i "s/^account = .*/account = $wrong_account/" "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A Certbot account directory not bound to its JWK public key passed validation.'
    fi
    sed -i "s/^account = .*/account = $renewable_account/" "$renewable_conf"
    mv "$wrong_account_dir" "$renewable_account_dir"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'The lineage was not accepted after restoring its canonical account identifier.'

    renewable_ec_key="$test_root/renewable-ec.key"
    renewable_ec_csr="$test_root/renewable-ec.csr"
    renewable_ec_cert="$test_root/renewable-ec.crt"
    openssl ecparam -name prime256v1 -genkey -noout \
        -out "$renewable_ec_key" >/dev/null 2>&1
    openssl req -new -key "$renewable_ec_key" \
        -subj "/CN=$renewable_domain" \
        -addext "subjectAltName=DNS:$renewable_domain" \
        -out "$renewable_ec_csr" >/dev/null 2>&1
    openssl x509 -req -days 30 -in "$renewable_ec_csr" \
        -CA "$renewable_ca_cert" -CAkey "$renewable_ca_key" \
        -CAserial "$test_root/renewable-ca.srl" -copy_extensions copy \
        -out "$renewable_ec_cert" >/dev/null 2>&1
    cp "$renewable_ec_key" "$renewable_archive/privkey1.pem"
    cp "$renewable_ec_cert" "$renewable_archive/cert1.pem"
    {
        cat "$renewable_archive/cert1.pem"
        cat "$renewable_archive/chain1.pem"
    } > "$renewable_archive/fullchain1.pem"
    chmod 600 "$renewable_archive/privkey1.pem"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'A genuine matching ECDSA Certbot leaf/key pair was rejected.'
    cp "$key_backup" "$renewable_archive/privkey1.pem"
    cp "$cert_backup" "$renewable_archive/cert1.pem"
    cp "$fullchain_backup" "$renewable_archive/fullchain1.pem"

    broken_key_der="$test_root/renewable-broken-key.der"
    broken_key_pem="$test_root/renewable-broken-key.pem"
    openssl rsa -in "$key_backup" -traditional -outform DER \
        -out "$broken_key_der" >/dev/null 2>&1
    python3 - "$broken_key_der" "$broken_key_pem" <<'PY'
import base64
import pathlib
import sys

encoded = bytearray(pathlib.Path(sys.argv[1]).read_bytes())


def read_length(offset):
    first = encoded[offset]
    offset += 1
    if first < 128:
        return first, offset
    count = first & 0x7f
    if not count or count > 4:
        raise SystemExit("invalid PKCS#1 length")
    return int.from_bytes(encoded[offset:offset + count], "big"), offset + count


if not encoded or encoded[0] != 0x30:
    raise SystemExit("invalid PKCS#1 sequence")
sequence_length, offset = read_length(1)
if offset + sequence_length != len(encoded):
    raise SystemExit("invalid PKCS#1 sequence size")
for index in range(9):
    if offset >= len(encoded) or encoded[offset] != 0x02:
        raise SystemExit("invalid PKCS#1 integer")
    integer_length, start = read_length(offset + 1)
    end = start + integer_length
    if end > len(encoded):
        raise SystemExit("truncated PKCS#1 integer")
    if index == 6:
        # Change only dp.  n/e and therefore the derived public key remain
        # byte-identical while the private key becomes unusable.
        encoded[end - 1] ^= 1
    offset = end
if offset != len(encoded):
    raise SystemExit("trailing PKCS#1 data")

payload = base64.b64encode(encoded)
pem = (
    b"-----BEGIN RSA PRIVATE KEY-----\n"
    + b"\n".join(payload[pos:pos + 64] for pos in range(0, len(payload), 64))
    + b"\n-----END RSA PRIVATE KEY-----\n"
)
pathlib.Path(sys.argv[2]).write_bytes(pem)
PY
    openssl pkey -in "$key_backup" -pubout > "$test_root/renewable-good-key.pub" 2>/dev/null
    openssl pkey -in "$broken_key_pem" -pubout > "$test_root/renewable-broken-key.pub" 2>/dev/null
    cmp -s "$test_root/renewable-good-key.pub" "$test_root/renewable-broken-key.pub" ||
        fail 'Broken-private-key fixture unexpectedly changed the public key.'
    if openssl pkey -in "$broken_key_pem" -check -noout >/dev/null 2>&1; then
        fail 'Broken-private-key fixture unexpectedly passed the OpenSSL backend check.'
    fi
    cp "$broken_key_pem" "$renewable_archive/privkey1.pem"
    chmod 600 "$renewable_archive/privkey1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A public-matching but internally inconsistent private key passed validation.'
    fi
    cp "$key_backup" "$renewable_archive/privkey1.pem"
    chmod 600 "$renewable_archive/privkey1.pem"

    printf '%s\n' '-----BEGIN CERTIFICATE-----' fake \
        '-----END CERTIFICATE-----' > "$renewable_archive/cert1.pem"
    {
        cat "$renewable_archive/cert1.pem"
        cat "$renewable_archive/chain1.pem"
    } > "$renewable_archive/fullchain1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A lineage containing fake PEM passed validation.'
    fi
    cp "$cert_backup" "$renewable_archive/cert1.pem"
    cp "$fullchain_backup" "$renewable_archive/fullchain1.pem"

    printf '\n' >> "$renewable_archive/fullchain1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A fullchain that was not exact cert plus chain passed validation.'
    fi
    cp "$fullchain_backup" "$renewable_archive/fullchain1.pem"

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$renewable_archive/privkey1.pem" >/dev/null 2>&1
    chmod 600 "$renewable_archive/privkey1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A lineage whose private key did not match cert.pem passed validation.'
    fi
    cp "$key_backup" "$renewable_archive/privkey1.pem"
    chmod 600 "$renewable_archive/privkey1.pem"

    extra_san_csr="$test_root/renewable-extra-san.csr"
    extra_san_cert="$test_root/renewable-extra-san.crt"
    openssl req -new -key "$renewable_archive/privkey1.pem" \
        -subj "/CN=$renewable_domain" \
        -addext "subjectAltName=DNS:$renewable_domain,DNS:extra.example.net" \
        -out "$extra_san_csr" >/dev/null 2>&1
    openssl x509 -req -days 30 -in "$extra_san_csr" \
        -CA "$renewable_ca_cert" -CAkey "$renewable_ca_key" \
        -CAserial "$test_root/renewable-ca.srl" -copy_extensions copy \
        -out "$extra_san_cert" >/dev/null 2>&1
    cp "$extra_san_cert" "$renewable_archive/cert1.pem"
    {
        cat "$renewable_archive/cert1.pem"
        cat "$renewable_archive/chain1.pem"
    } > "$renewable_archive/fullchain1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A lineage with an additional SAN outside the exact RR domain policy passed validation.'
    fi
    cp "$cert_backup" "$renewable_archive/cert1.pem"
    cp "$fullchain_backup" "$renewable_archive/fullchain1.pem"

    unrelated_ca_key="$test_root/unrelated-ca.key"
    unrelated_ca_cert="$test_root/unrelated-ca.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj '/CN=Unrelated lineage CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$unrelated_ca_key" -out "$unrelated_ca_cert" >/dev/null 2>&1
    cp "$unrelated_ca_cert" "$renewable_archive/chain1.pem"
    {
        cat "$renewable_archive/cert1.pem"
        cat "$renewable_archive/chain1.pem"
    } > "$renewable_archive/fullchain1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A cryptographically unrelated cert.pem and chain.pem passed validation.'
    fi
    cp "$chain_backup" "$renewable_archive/chain1.pem"
    cp "$fullchain_backup" "$renewable_archive/fullchain1.pem"

    cat "$unrelated_ca_cert" >> "$renewable_archive/chain1.pem"
    {
        cat "$renewable_archive/cert1.pem"
        cat "$renewable_archive/chain1.pem"
    } > "$renewable_archive/fullchain1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A valid chain with an appended unrelated certificate passed validation.'
    fi
    cp "$chain_backup" "$renewable_archive/chain1.pem"
    cp "$fullchain_backup" "$renewable_archive/fullchain1.pem"

    chmod 600 "$renewable_account_dir/private_key.json"
    printf '%s\n' \
        '{"kty":"RSA","n":"AQ","e":"Aw","d":"AQ","p":"Aw","q":"BQ","dp":"AQ","dq":"AQ","qi":"AQ"}' \
        > "$renewable_account_dir/private_key.json"
    chmod 400 "$renewable_account_dir/private_key.json"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A syntactically shaped but mathematically fake account JWK passed validation.'
    fi
    install -m 400 "$jwk_backup" "$renewable_account_dir/private_key.json"

    chmod 600 "$renewable_account_dir/private_key.json"
    python3 - "$renewable_account_dir/private_key.json" <<'PY'
import base64
import json
import math
import pathlib
import sys

# p and q deliberately multiply known Mersenne primes.  The old congruence
# checks all pass, but a real RSA backend must reject the composite factors.
a = (1 << 521) - 1
b = (1 << 607) - 1
c = (1 << 127) - 1
d0 = (1 << 1279) - 1
p = a * b
q = c * d0
n = p * q
e = 65537
lcm = math.lcm(p - 1, q - 1)
d = pow(e, -1, lcm)
values = {
    "n": n,
    "e": e,
    "d": d,
    "p": p,
    "q": q,
    "dp": d % (p - 1),
    "dq": d % (q - 1),
    "qi": pow(q, -1, p),
}


def b64uint(value):
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


jwk = {"kty": "RSA", **{name: b64uint(value) for name, value in values.items()}}
pathlib.Path(sys.argv[1]).write_text(json.dumps(jwk) + "\n", encoding="utf-8")
PY
    chmod 400 "$renewable_account_dir/private_key.json"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A composite-factor account JWK passed the backend RSA key check.'
    fi
    install -m 400 "$jwk_backup" "$renewable_account_dir/private_key.json"

    registration_backup="$test_root/renewable-registration.backup"
    metadata_backup="$test_root/renewable-metadata.backup"
    cp "$renewable_account_dir/regr.json" "$registration_backup"
    cp "$renewable_account_dir/meta.json" "$metadata_backup"
    printf '%s\n' \
        '{"body":[],"uri":"https://acme-v02.api.letsencrypt.org/acme/acct/123456"}' \
        > "$renewable_account_dir/regr.json"
    chmod 644 "$renewable_account_dir/regr.json"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A Certbot registration with a non-object ACME account body passed validation.'
    fi
    install -m 644 "$registration_backup" "$renewable_account_dir/regr.json"
    printf '%s\n' \
        '{"creation_dt":"2026-08-31T00:00:00Z","creation_host":"rr-test","register_to_eff":"admin@renewable.example.net"}' \
        > "$renewable_account_dir/meta.json"
    chmod 644 "$renewable_account_dir/meta.json"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'Certbot metadata with a legacy EFF registration email was rejected.'
    printf '%s\n' \
        '{"creation_dt":"2026-08-31T00:00:00Z","creation_host":"rr-test","register_to_eff":null}' \
        > "$renewable_account_dir/meta.json"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'Loader-compatible Certbot metadata with a null EFF field was rejected.'
    printf '%s\n' \
        '{"creation_dt":"2026-08-31T00:00:00Z","creation_host":"rr-test","register_to_eff":true}' \
        > "$renewable_account_dir/meta.json"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'Certbot metadata with a boolean EFF registration field passed validation.'
    fi
    printf '%s\n' '{"creation_host":"rr-test"}' \
        > "$renewable_account_dir/meta.json"
    chmod 644 "$renewable_account_dir/meta.json"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'Certbot metadata without a parseable creation timestamp passed validation.'
    fi
    install -m 644 "$metadata_backup" "$renewable_account_dir/meta.json"

    chmod 644 "$renewable_archive/privkey1.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A group/other-readable lineage private key passed validation.'
    fi
    chmod 600 "$renewable_archive/privkey1.pem"
    chmod 644 "$renewable_account_dir/private_key.json"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A group/other-readable Certbot account private key passed validation.'
    fi
    chmod 400 "$renewable_account_dir/private_key.json"
    chmod 755 "$renewable_account_dir"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A group/other-accessible Certbot account secret directory passed validation.'
    fi
    chmod 700 "$renewable_account_dir"

    cat >> "$renewable_conf" <<'EOF'

[acme_renewal_info]
ari_retry_after = 2026-09-01T12:00:00
EOF
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'One valid Certbot ARI retry timestamp was rejected.'
    sed -i 's/ari_retry_after = .*/ari_retry_after = not-a-datetime/' "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'An invalid Certbot ARI retry timestamp passed validation.'
    fi
    sed -i 's/ari_retry_after = .*/ari_retry_after = 2026-09-01T12:00:00+00:00/' "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A timezone-aware ARI timestamp incompatible with Certbot passed validation.'
    fi
    sed -i 's/ari_retry_after = .*/ari_retry_after = 2026-09-01T12:00:00/' "$renewable_conf"
    printf '%s\n' 'unexpected = value' >> "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'An ACME renewal information section with extra keys passed validation.'
    fi
    sed -i '$d' "$renewable_conf"
    printf '%s\n' '[acme_renewal_info]' 'ari_retry_after = 2026-09-02T12:00:00' \
        >> "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'Duplicate ACME renewal information sections passed validation.'
    fi
    sed -i '/^\[acme_renewal_info\]$/,$d' "$renewable_conf"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'The lineage was not accepted after removing ARI mutation fixtures.'

    renewal_config_backup="$test_root/renewable-config.backup"
    cp "$renewable_conf" "$renewal_config_backup"
    python3 - "$renewable_conf" "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
block = f"[[webroot_map]]\n{sys.argv[2]} = {sys.argv[3]}\n"
text = path.read_text(encoding="utf-8")
if text.count(block) != 1:
    raise SystemExit("unexpected renewal fixture")
path.write_text(text.replace(block, "").replace("[renewalparams]\n", block + "\n[renewalparams]\n"), encoding="utf-8")
PY
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A webroot_map placed before its ConfigObj parent passed validation.'
    fi
    cp "$renewal_config_backup" "$renewable_conf"
    sed -i '/^\[\[webroot_map\]\]$/i [acme_renewal_info]\nari_retry_after = 2026-09-01T12:00:00\n' \
        "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A webroot_map separated from renewalparams by an ARI section passed validation.'
    fi
    cp "$renewal_config_backup" "$renewable_conf"

    for stem in cert chain fullchain; do
        cp "$renewable_archive/${stem}1.pem" "$renewable_archive/${stem}2.pem"
        ln -sfn "../../archive/$renewable_domain/${stem}2.pem" \
            "$renewable_live/${stem}.pem"
    done
    ln -s privkey1.pem "$renewable_archive/privkey2.pem"
    ln -sfn "../../archive/$renewable_domain/privkey2.pem" \
        "$renewable_live/privkey.pem"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'A genuine Certbot reuse-key successor shape was rejected.'
    cp "$renewable_archive/privkey1.pem" "$renewable_archive/privkey3.pem"
    rm -f "$renewable_archive/privkey2.pem"
    ln -s privkey3.pem "$renewable_archive/privkey2.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A reuse-key archive member pointing to a future generation passed validation.'
    fi
    rm -f "$renewable_archive/privkey2.pem" "$renewable_archive/privkey3.pem"
    ln -s privkey1.pem "$renewable_archive/privkey2.pem"
    for stem in cert privkey chain fullchain; do
        ln -sfn "../../archive/$renewable_domain/${stem}1.pem" \
            "$renewable_live/${stem}.pem"
        rm -f "$renewable_archive/${stem}2.pem"
    done

    ln -sfn "../../archive/$renewable_domain/./cert1.pem" \
        "$renewable_live/cert.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A non-canonical live archive link passed Certbot lineage validation.'
    fi
    ln -sfn "../../archive/$renewable_domain/cert1.pem" \
        "$renewable_live/cert.pem"

    rm -f "$renewable_live/fullchain.pem"
    cp "$renewable_archive/fullchain1.pem" "$renewable_live/fullchain.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A hand-copied live fullchain passed renewable lineage validation.'
    fi
    rm -f "$renewable_live/fullchain.pem"
    ln -s "../../archive/$renewable_domain/fullchain1.pem" \
        "$renewable_live/fullchain.pem"

    printf '%s\n' fullchain-generation-2 > "$renewable_archive/fullchain2.pem"
    ln -sfn "../../archive/$renewable_domain/fullchain2.pem" \
        "$renewable_live/fullchain.pem"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'Mixed Certbot archive generations passed renewable lineage validation.'
    fi
    ln -sfn "../../archive/$renewable_domain/fullchain1.pem" \
        "$renewable_live/fullchain.pem"
    rm -f "$renewable_archive/fullchain2.pem"

    mv "$renewable_account_dir" "${renewable_account_dir}.missing"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A lineage without its production ACME account passed validation.'
    fi
    mv "${renewable_account_dir}.missing" "$renewable_account_dir"

    sed -i "s#^$renewable_domain = .*#$renewable_domain = /wrong/webroot#" \
        "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A lineage with the wrong challenge Webroot passed validation.'
    fi
    sed -i "s#^$renewable_domain = .*#$renewable_domain = $RR_NAIVE_ACME_WEBROOT#" \
        "$renewable_conf"

    sed -i '/^server = /a server = https://acme-v02.api.letsencrypt.org/directory' \
        "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A renewal config with a duplicated required key passed validation.'
    fi
    sed -i '0,/^server = /!{/^server = /d;}' "$renewable_conf"

    chmod 666 "$renewable_conf"
    if rr_certbot_webroot_lineage_is_renewable "$renewable_domain"; then
        fail 'A group/other-writable renewal file passed lineage validation.'
    fi
    chmod 644 "$renewable_conf"
    rr_certbot_webroot_lineage_is_renewable "$renewable_domain" ||
        fail 'The restored renewable lineage fixture was not accepted.'

    # A healthy timer alone cannot renew through a missing/broken HTTP-01
    # route.  Exercise the exact local proof as root so ownership, link and
    # ancestor checks are real rather than mocked.  Every negative is also
    # driven through the portable update path and the timer-enabler to prove
    # it is rejected before certificate, hook or service mutation.
    (
        runtime_route_root="$test_root/renewal-runtime-route"
        RR_NAIVE_ACME_NGINX_SITE="$runtime_route_root/etc/nginx/sites-available/rr-naive-acme.conf"
        RR_NAIVE_ACME_NGINX_ENABLED="$runtime_route_root/etc/nginx/sites-enabled/rr-naive-acme.conf"
        NEXUS_NGINX_AVAILABLE_DIR="$runtime_route_root/etc/nginx/sites-available"
        NEXUS_NGINX_ENABLED_DIR="$runtime_route_root/etc/nginx/sites-enabled"
        NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
        NEXUS_NGINX_TRUST_ROOT="$runtime_route_root"
        RR_NAIVE_CERT_DIR="$runtime_route_root/candidate-cert"
        RR_UPDATE_TRANSACTION=1
        RR_PORTABLE_RESTORE=1
        RED=""
        RESET=""
        is_valid_port() {
            [[ "${1:-}" =~ ^[0-9]+$ ]] && \
                (( 10#$1 >= 1 && 10#$1 <= 65535 ))
        }
        route_certbot_dir="$runtime_route_root/bin"
        mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
            "$route_certbot_dir"
        chmod 755 "$runtime_route_root" "$runtime_route_root/etc" \
            "$runtime_route_root/etc/nginx" "$NEXUS_NGINX_AVAILABLE_DIR" \
            "$NEXUS_NGINX_ENABLED_DIR" "$route_certbot_dir"
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$route_certbot_dir/certbot"
        chmod 755 "$route_certbot_dir/certbot"
        PATH="$route_certbot_dir:$PATH"
        unset -f certbot 2>/dev/null || true

        write_runtime_route_site() {
            local route_domain="$1" route_webroot="$2" route_port="$3"
            cat > "$RR_NAIVE_ACME_NGINX_SITE" <<EOF
server {
    listen ${route_port};
    listen [::]:${route_port};
    server_name ${route_domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${route_webroot};
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF
            chmod 644 "$RR_NAIVE_ACME_NGINX_SITE"
        }

        SERVICE_LOADED=true
        TIMER_LOADED=true
        TIMER_ENABLED=true
        TIMER_ACTIVE=true
        TIMER_TRIGGERS=certbot.service
        TIMER_NEXT_REALTIME=$(date -u -d '+1 day' '+%a %Y-%m-%d %H:%M:%S UTC')
        TIMER_NEXT_MONOTONIC='1h 5min'
        TIMER_CALENDAR='{ OnCalendar=*-*-* 00,12:00:00 ; next_elapse=mocked }'
        TIMER_RANDOMIZED_DELAY=12h
        TIMER_ACCURACY=1min
        NGINX_ACTIVE=true
        PORT_80_LISTENING=true
        FIREWALL_80_OPEN=true
        SERVICE_WRITES=0
        CERT_WRITES=0
        HOOK_WRITES=0
        runtime_real_stat=$(type -P stat)
        stat() {
            case "${!#}" in
                /lib/systemd/system/certbot.service|\
                /lib/systemd/system/certbot.timer)
                    printf '%s\n' '0:0:644:1:regular file'
                    ;;
                *) "$runtime_real_stat" "$@" ;;
            esac
        }
        nginx() { [ "${1:-}" = -t ]; }
        ss() {
            [ "$PORT_80_LISTENING" = true ] &&
                printf '%s\n' 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:*'
        }
        systemctl() {
            case "$*" in
                '--version') printf '%s\n' 'systemd 255 (mock)' ;;
                'show certbot.service --property=LoadState --value')
                    [ "$SERVICE_LOADED" = true ] && printf '%s\n' loaded || \
                        printf '%s\n' masked
                    ;;
                'show certbot.service --property=FragmentPath --value')
                    printf '%s\n' /lib/systemd/system/certbot.service
                    ;;
                'show certbot.service --property=DropInPaths --value'|\
                'show certbot.service --property=User --value'|\
                'show certbot.service --property=RootDirectory --value'|\
                'show certbot.service --property=RootImage --value'|\
                'show certbot.service --property=ReadOnlyPaths --value'|\
                'show certbot.service --property=InaccessiblePaths --value'|\
                'show certbot.service --property=BindPaths --value'|\
                'show certbot.service --property=BindReadOnlyPaths --value'|\
                'show certbot.service --property=TemporaryFileSystem --value'|\
                'show certbot.service --property=NoExecPaths --value'|\
                'show certbot.service --property=NetworkNamespacePath --value'|\
                'show certbot.service --property=RestrictAddressFamilies --value'|\
                'show certbot.service --property=RestrictNetworkInterfaces --value'|\
                'show certbot.service --property=RestrictFileSystems --value'|\
                'show certbot.service --property=SystemCallFilter --value'|\
                'show certbot.service --property=MountImages --value'|\
                'show certbot.service --property=ExtensionImages --value'|\
                'show certbot.service --property=ExtensionDirectories --value'|\
                'show certbot.service --property=JoinsNamespaceOf --value'|\
                'show certbot.service --property=IPAddressDeny --value')
                    printf '\n'
                    ;;
                'show certbot.service --property=PrivateNetwork --value'|\
                'show certbot.service --property=DynamicUser --value'|\
                'show certbot.service --property=RemainAfterExit --value'|\
                'show certbot.service --property=PrivateUsers --value'|\
                'show certbot.service --property=ProtectSystem --value')
                    printf '%s\n' no
                    ;;
                'show certbot.service --property=ExecStart --value')
                    certbot_mock=$(command -v certbot)
                    printf '{ path=%s ; argv[]=%s -q renew ; ignore_errors=no ; }\n' \
                        "$certbot_mock" "$certbot_mock"
                    ;;
                'show certbot.service --property=ExecStartPre --value'|\
                'show certbot.service --property=ExecCondition --value'|\
                'show certbot.service --property=Conditions --value'|\
                'show certbot.service --property=Asserts --value')
                    printf '\n'
                    ;;
                'show certbot.timer --property=LoadState --value')
                    [ "$TIMER_LOADED" = true ] && printf '%s\n' loaded || \
                        printf '%s\n' not-found
                    ;;
                'show certbot.timer --property=FragmentPath --value')
                    printf '%s\n' /lib/systemd/system/certbot.timer
                    ;;
                'show certbot.timer --property=DropInPaths --value'|\
                'show certbot.timer --property=Conditions --value'|\
                'show certbot.timer --property=Asserts --value')
                    printf '\n'
                    ;;
                'show certbot.timer --property=Triggers --value')
                    printf '%s\n' "$TIMER_TRIGGERS"
                    ;;
                'show certbot.timer --property=NextElapseUSecRealtime --value')
                    printf '%s\n' "$TIMER_NEXT_REALTIME"
                    ;;
                'show certbot.timer --property=NextElapseUSecMonotonic --value')
                    printf '%s\n' "$TIMER_NEXT_MONOTONIC"
                    ;;
                'show certbot.timer --property=TimersCalendar --value')
                    printf '%s\n' "$TIMER_CALENDAR"
                    ;;
                'show certbot.timer --property=RandomizedDelayUSec --value')
                    printf '%s\n' "$TIMER_RANDOMIZED_DELAY"
                    ;;
                'show certbot.timer --property=AccuracyUSec --value')
                    printf '%s\n' "$TIMER_ACCURACY"
                    ;;
                'is-enabled certbot.timer')
                    [ "$TIMER_ENABLED" = true ] && printf '%s\n' enabled || return 1
                    ;;
                'is-active --quiet certbot.timer') [ "$TIMER_ACTIVE" = true ] ;;
                'is-active --quiet nginx') [ "$NGINX_ACTIVE" = true ] ;;
                enable*|start*|restart*|reload*)
                    SERVICE_WRITES=$((SERVICE_WRITES + 1))
                    return 1
                    ;;
                *) return 1 ;;
            esac
        }
        rr_validate_protocol_firewall() {
            [ "$*" = '80 tcp open' ] && [ "$FIREWALL_80_OPEN" = true ]
        }
        EFFECTIVE_ROUTE_READY=true
        rr_certbot_acme_effective_route_probe() {
            [ "${1:-}" = "$renewable_domain" ] && \
                [ "${2:-}" = "$RR_NAIVE_ACME_WEBROOT" ] && \
                [ "$EFFECTIVE_ROUTE_READY" = true ]
        }
        naive_certificate_pair_valid() { [ "${3:-}" = "$renewable_domain" ]; }
        rr_certbot_webroot_lineage_is_renewable() {
            [ "${1:-}" = "$renewable_domain" ]
        }
        sync_naive_certificate_pair() {
            CERT_WRITES=$((CERT_WRITES + 1))
            return 0
        }
        rr_certificate_deploy_hook_is_current() {
            HOOK_WRITES=$((HOOK_WRITES + 1))
            return 0
        }
        deploy_naive_cert_hook() {
            HOOK_WRITES=$((HOOK_WRITES + 1))
            return 0
        }

        runtime_route_fingerprint() {
            {
                find -P "$runtime_route_root" -printf '%P|%y|%m|%U|%G|%s|%l\n' |
                    LC_ALL=C sort
                find -P "$runtime_route_root" -type f -print0 |
                    LC_ALL=C sort -z | xargs -0 sha256sum
            } | sha256sum | awk '{print $1}'
        }
        expect_runtime_route_reject() {
            local label="$1"
            CERT_WRITES=0
            HOOK_WRITES=0
            SERVICE_WRITES=0
            if rr_certbot_renewal_runtime_is_ready "$renewable_domain" \
                 >/dev/null 2>&1; then
                fail "$label passed the domain-aware Certbot runtime proof."
            fi
            if rr_enable_certbot_renewal_runtime "$renewable_domain" \
                 >/dev/null 2>&1; then
                fail "$label was allowed to enable the Certbot timer."
            fi
            [ "$SERVICE_WRITES" -eq 0 ] ||
                fail "$label reached a systemd writer before route rejection."
            if ensure_naive_certificate "$renewable_domain" admin@example.net \
                 >/dev/null 2>&1; then
                fail "$label passed portable Naive preflight."
            fi
            [ "$CERT_WRITES" -eq 0 ] && [ "$HOOK_WRITES" -eq 0 ] && \
                [ "$SERVICE_WRITES" -eq 0 ] && [ ! -e "$RR_NAIVE_CERT_DIR" ] ||
                fail "$label reached certificate, hook or service mutation."
        }

        write_runtime_route_site "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" 80
        ln -s "$RR_NAIVE_ACME_NGINX_SITE" "$RR_NAIVE_ACME_NGINX_ENABLED"
        cat > "$NEXUS_NGINX_AVAILABLE_DIR/default" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 404;
}
EOF
        chmod 644 "$NEXUS_NGINX_AVAILABLE_DIR/default"
        ln -s "$NEXUS_NGINX_AVAILABLE_DIR/default" \
            "$NEXUS_NGINX_ENABLED_DIR/default"
        runtime_before=$(runtime_route_fingerprint)
        rr_certbot_renewal_runtime_is_ready "$renewable_domain" ||
            fail 'A complete route alongside the clean-package default site was rejected.'
        runtime_after=$(runtime_route_fingerprint)
        [ "$runtime_before" = "$runtime_after" ] ||
            fail 'The domain-aware Certbot runtime proof mutated local state.'

        mv "$RR_NAIVE_ACME_NGINX_ENABLED" "${RR_NAIVE_ACME_NGINX_ENABLED}.saved"
        expect_runtime_route_reject 'A missing enabled ACME site'
        mv "${RR_NAIVE_ACME_NGINX_ENABLED}.saved" "$RR_NAIVE_ACME_NGINX_ENABLED"

        mv "$RR_NAIVE_ACME_NGINX_ENABLED" "${RR_NAIVE_ACME_NGINX_ENABLED}.saved"
        ln -s "${RR_NAIVE_ACME_NGINX_SITE}.wrong" "$RR_NAIVE_ACME_NGINX_ENABLED"
        expect_runtime_route_reject 'An enabled ACME link with the wrong exact target'
        rm -f "$RR_NAIVE_ACME_NGINX_ENABLED"
        mv "${RR_NAIVE_ACME_NGINX_ENABLED}.saved" "$RR_NAIVE_ACME_NGINX_ENABLED"

        mv "$RR_NAIVE_ACME_NGINX_SITE" "${RR_NAIVE_ACME_NGINX_SITE}.saved"
        expect_runtime_route_reject 'A missing enabled ACME site target'
        mv "${RR_NAIVE_ACME_NGINX_SITE}.saved" "$RR_NAIVE_ACME_NGINX_SITE"

        chmod 664 "$RR_NAIVE_ACME_NGINX_SITE"
        expect_runtime_route_reject 'A group-writable ACME site'
        chmod 644 "$RR_NAIVE_ACME_NGINX_SITE"

        write_runtime_route_site wrong.example.net "$RR_NAIVE_ACME_WEBROOT" 80
        expect_runtime_route_reject 'An ACME site for the wrong Host domain'
        write_runtime_route_site "$renewable_domain" /wrong/webroot 80
        expect_runtime_route_reject 'An ACME site for the wrong Webroot'
        write_runtime_route_site "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" 81
        expect_runtime_route_reject 'An ACME site without an exact port-80 listener'

        write_runtime_route_site "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" 80
        cat >> "$RR_NAIVE_ACME_NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${renewable_domain};
    return 403;
}
EOF
        expect_runtime_route_reject 'A duplicate same-domain port-80 server'

        write_runtime_route_site "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" 80
        cat >> "$RR_NAIVE_ACME_NGINX_SITE" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name *.example.net;
    return 403;
}
EOF
        expect_runtime_route_reject 'An extra wildcard port-80 server in an RR site'

        write_runtime_route_site "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" 80
        cat >> "$RR_NAIVE_ACME_NGINX_SITE" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 403;
}
EOF
        expect_runtime_route_reject 'An extra default catch-all port-80 server in an RR site'
        write_runtime_route_site "$renewable_domain" "$RR_NAIVE_ACME_WEBROOT" 80

        NGINX_ACTIVE=false
        expect_runtime_route_reject 'An inactive Nginx service'
        NGINX_ACTIVE=true
        PORT_80_LISTENING=false
        expect_runtime_route_reject 'A host without a TCP/80 listener'
        PORT_80_LISTENING=true
        FIREWALL_80_OPEN=false
        expect_runtime_route_reject 'A closed effective RR tcp/80 firewall policy'

        # nginx -T may accept a competing conf.d/default/wildcard server with
        # only a warning.  The production proof performs real Host-routed v4
        # and v6 requests; model the resulting non-probe response here and
        # ensure every caller remains fail-closed regardless of source syntax.
        FIREWALL_80_OPEN=true
        EFFECTIVE_ROUTE_READY=false
        mkdir -p "$runtime_route_root/etc/nginx/conf.d"
        chmod 755 "$runtime_route_root/etc/nginx/conf.d"
        printf '%s\n' \
            "server { listen 80; server_name ${renewable_domain}; return 403; }" > \
            "$runtime_route_root/etc/nginx/conf.d/00-shadow.conf"
        chmod 644 "$runtime_route_root/etc/nginx/conf.d/00-shadow.conf"
        expect_runtime_route_reject 'A conf.d exact-domain shadow server'
        expect_runtime_route_reject 'A one-line or split-brace shadow server'
        expect_runtime_route_reject 'A default or wildcard shadow server'
        rm -f "$runtime_route_root/etc/nginx/conf.d/00-shadow.conf"
        EFFECTIVE_ROUTE_READY=true

        # Nexus uses the same canonical Webroot.  Prove that both its issuance
        # bootstrap site and its committed custom-port site satisfy the exact
        # domain route contract, with the Naive site disabled so it cannot
        # mask a Nexus template regression.
        FIREWALL_80_OPEN=true
        naive_nexus_disabled="$runtime_route_root/rr-naive-acme.disabled"
        mv "$RR_NAIVE_ACME_NGINX_ENABLED" "$naive_nexus_disabled"
        NGINX_ACTIVE=false
        nexus_write_nginx_site "$renewable_domain" 18443 ||
            fail 'Nexus ACME bootstrap site could not be staged for route validation.'
        NGINX_ACTIVE=true
        rr_certbot_renewal_runtime_is_ready "$renewable_domain" ||
            fail 'Nexus ACME bootstrap site failed the domain-aware runtime proof.'
        NGINX_ACTIVE=false
        nexus_write_nginx_custom_port "$renewable_domain" 18443 ||
            fail 'Nexus custom-port site could not be staged for route validation.'
        NGINX_ACTIVE=true
        rr_certbot_renewal_runtime_is_ready "$renewable_domain" ||
            fail 'Nexus custom-port ACME route failed the domain-aware runtime proof.'
    )

    naive_root="$test_root/portable-naive"
    imported_config="$naive_root/imported.conf"
    target_config="$naive_root/target.conf"
    payload_root="$naive_root/payload"
    imported_cert_dir="$payload_root/rootfs/etc/rr-naive"
    lineage_root="$naive_root/letsencrypt/live"
    call_log="$naive_root/calls"
    mkdir -p "$imported_cert_dir" "$lineage_root"

    # `test -e` is false for a dangling link.  Target ownership must use
    # lstat-style presence semantics so such a path cannot be mistaken for a
    # blank destination and deleted by the restore transaction.
    ln -s "$naive_root/missing-target" "$naive_root/dangling-target.conf"
    CONFIG_FILE="$naive_root/dangling-target.conf"
    ownership_body=$(declare -f rr_restore_validate_target_ownership)
    [[ "$ownership_body" == *'if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then'* ]] ||
        fail 'Target ownership does not classify a dangling config symlink as occupied.'
    if rr_restore_validate_target_ownership >/dev/null 2>&1; then
        fail 'A dangling target config symlink was accepted as a blank destination.'
    fi
    rm -f "$CONFIG_FILE"

    : > "$imported_cert_dir/fullchain.pem"
    : > "$imported_cert_dir/privkey.pem"
    cat > "$imported_config" <<'EOF'
CONFIG_VERSION=9
UUID=00000000-0000-4000-8000-000000000001
INSTALL_COMPLETE=true
NAIVE_ENABLED=true
NAIVE_DOMAIN=naive.example.net
EOF
    printf '%s\n' 'CONFIG_VERSION=9' > "$target_config"
    CONFIG_FILE="$target_config"
    RR_LE_LIVE_ROOT="$lineage_root"
    is_valid_domain() {
        [ "$1" = naive.example.net ] || [ "$1" = sub.example.net ]
    }
    MOCK_IMPORTED_VALID=false
    MOCK_LINEAGE_VALID=false
    MOCK_SUBSCRIPTION_VALID=false
    MOCK_RENEWABLE=false
    MOCK_RENEWAL_RUNTIME=false
    MOCK_HOOK_CURRENT=false
    naive_certificate_pair_valid() {
        printf 'pair:%s:%s\n' "$1" "$3" >> "$call_log"
        if [ "$1" = "$imported_cert_dir/fullchain.pem" ] &&
           [ "$2" = "$imported_cert_dir/privkey.pem" ] &&
           [ "$3" = naive.example.net ]; then
            [ "$MOCK_IMPORTED_VALID" = true ]
            return
        fi
        [ "$1" = "$lineage_root/naive.example.net/fullchain.pem" ] &&
            [ "$2" = "$lineage_root/naive.example.net/privkey.pem" ] &&
            [ "$3" = naive.example.net ] && [ "$MOCK_LINEAGE_VALID" = true ]
    }
    rr_certificate_deploy_hook_is_current() {
        printf '%s\n' hook >> "$call_log"
        [ "$MOCK_HOOK_CURRENT" = true ]
    }
    naive_cert_hook_is_current() {
        rr_certificate_deploy_hook_is_current
    }
    subscription_certificate_pair_valid() {
        printf 'subscription:%s:%s\n' "$1" "$3" >> "$call_log"
        [ "$1" = "$lineage_root/sub.example.net/fullchain.pem" ] &&
            [ "$2" = "$lineage_root/sub.example.net/privkey.pem" ] &&
            [ "$3" = sub.example.net ] && [ "$MOCK_SUBSCRIPTION_VALID" = true ]
    }
    rr_certbot_webroot_lineage_is_renewable() {
        printf 'lineage:%s\n' "$1" >> "$call_log"
        [ "$MOCK_RENEWABLE" = true ]
    }
    rr_certbot_renewal_runtime_is_ready() {
        printf 'renewal-runtime:%s\n' "${1:-}" >> "$call_log"
        case "${1:-}" in naive.example.net|sub.example.net) ;; *) return 1 ;; esac
        [ "$MOCK_RENEWAL_RUNTIME" = true ]
    }
    systemctl() { fail 'Naive preflight invoked systemctl.'; }
    certbot() { fail 'Naive preflight invoked certbot.'; }
    open_protocol_firewall() { fail 'Naive preflight mutated the firewall.'; }

    before_sha=$(sha256sum "$target_config" | awk '{print $1}')
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'An invalid imported Naive certificate pair passed preflight.'
    fi
    [ "$(wc -l < "$call_log")" -eq 1 ] ||
        fail 'Invalid imported Naive material was not rejected before target checks.'
    [ "$(sha256sum "$target_config" | awk '{print $1}')" = "$before_sha" ] ||
        fail 'Naive preflight mutated the existing target config.'

    MOCK_IMPORTED_VALID=true
    CONFIG_FILE="$naive_root/blank-target.conf"
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'A blank target was allowed to create unstaged global ACME state.'
    fi

    CONFIG_FILE="$target_config"
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'A target without a trusted matching lineage passed preflight.'
    fi
    MOCK_LINEAGE_VALID=true
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'A target with a valid copied pair but no renewable lineage passed preflight.'
    fi
    MOCK_RENEWABLE=true
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'A target without an active Certbot renewal runtime passed preflight.'
    fi
    MOCK_RENEWAL_RUNTIME=true
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'A target with an outdated or missing deploy hook passed preflight.'
    fi
    MOCK_HOOK_CURRENT=true
    rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" ||
        fail 'Trusted imported material and a fully prepared target were rejected.'

    sed -i 's/^NAIVE_DOMAIN=.*$/NAIVE_DOMAIN=disabled/' "$imported_config"
    if rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" \
         >/dev/null 2>&1; then
        fail 'Enabled Naive domain literal "disabled" bypassed preflight state parsing.'
    fi

    sed -i 's/^NAIVE_DOMAIN=.*$/NAIVE_DOMAIN=naive.example.net/' "$imported_config"
    sed -i 's/^NAIVE_ENABLED=true$/NAIVE_ENABLED=false/' "$imported_config"
    CONFIG_FILE="$naive_root/blank-disabled-target.conf"
    MOCK_IMPORTED_VALID=false
    MOCK_LINEAGE_VALID=false
    MOCK_RENEWABLE=false
    MOCK_RENEWAL_RUNTIME=false
    MOCK_HOOK_CURRENT=false
    : > "$call_log"
    rr_restore_preflight_portable_naive_target "$imported_config" "$payload_root" ||
        fail 'A backup with Naive disabled was incorrectly gated on certificate state.'
    [ ! -s "$call_log" ] ||
        fail 'A backup with Naive disabled still inspected certificate state.'

    CONFIG_FILE="$target_config"
    cat > "$target_config" <<'EOF'
CONFIG_VERSION=9
SUB_ACCESS_MODE=local
SUB_DOMAIN=
EOF
    rr_restore_preflight_portable_subscription_target ||
        fail 'A loopback-only target was incorrectly gated on certificate state.'

    cat > "$target_config" <<'EOF'
CONFIG_VERSION=9
SUB_ACCESS_MODE=https
SUB_DOMAIN=sub.example.net
EOF
    : > "$call_log"
    if rr_restore_preflight_portable_subscription_target >/dev/null 2>&1; then
        fail 'An HTTPS subscription target without a trusted certificate passed preflight.'
    fi
    [ "$(wc -l < "$call_log")" -eq 1 ] ||
        fail 'An invalid subscription certificate was not rejected before hook checks.'
    MOCK_SUBSCRIPTION_VALID=true
    if rr_restore_preflight_portable_subscription_target >/dev/null 2>&1; then
        fail 'An HTTPS subscription pair without a renewable lineage passed preflight.'
    fi
    MOCK_RENEWABLE=true
    if rr_restore_preflight_portable_subscription_target >/dev/null 2>&1; then
        fail 'An HTTPS subscription target without an active Certbot renewal runtime passed preflight.'
    fi
    MOCK_RENEWAL_RUNTIME=true
    if rr_restore_preflight_portable_subscription_target >/dev/null 2>&1; then
        fail 'An HTTPS subscription target with an outdated hook passed preflight.'
    fi
    MOCK_HOOK_CURRENT=true
    rr_restore_preflight_portable_subscription_target ||
        fail 'A prepared HTTPS subscription target was rejected.'

    CONFIG_FILE="$naive_root/blank-subscription-target.conf"
    rr_restore_preflight_portable_subscription_target ||
        fail 'A blank loopback-only target was incorrectly rejected.'
    CONFIG_FILE="$target_config"
    sed -i 's/^SUB_ACCESS_MODE=https$/SUB_ACCESS_MODE=local/' "$target_config"
    if rr_restore_preflight_portable_subscription_target >/dev/null 2>&1; then
        fail 'A local subscription target carrying a public domain passed preflight.'
    fi

    restore_body=$(declare -f rr_restore_backup_locked)
    ownership_gate='rr_restore_validate_target_ownership ||'
    naive_gate='rr_restore_preflight_portable_naive_target'
    naive_config_arg='"$stage/payload/rootfs/etc/argo_vmess.conf"'
    naive_payload_arg='"$stage/payload" ||'
    subscription_gate='rr_restore_preflight_portable_subscription_target ||'
    first_target_mutation='rr_restore_migrate_legacy_fixed_token ||'
    [[ "$restore_body" == *"$ownership_gate"*"$naive_gate"*"$naive_config_arg"*"$naive_payload_arg"*"$subscription_gate"*"$first_target_mutation"* ]] ||
        fail 'Portable certificate preflights no longer precede target migration.'
    [[ "$restore_body" == *'[ -e "$target" ] || [ -L "$target" ] || continue'* ]] ||
        fail 'Rollback capture does not preserve dangling managed-path symlinks.'
    mutated_restore_body=${restore_body/rr_restore_preflight_portable_naive_target/removed_naive_preflight}
    if [[ "$mutated_restore_body" == *rr_restore_preflight_portable_naive_target* ]]; then
        fail 'Naive preflight mutation probe did not remove the gate.'
    fi
    mutated_restore_body=${restore_body/rr_restore_preflight_portable_subscription_target/removed_subscription_preflight}
    if [[ "$mutated_restore_body" == *rr_restore_preflight_portable_subscription_target* ]]; then
        fail 'Subscription preflight mutation probe did not remove the gate.'
    fi

    preflight_body=$(declare -f rr_restore_preflight_portable_naive_target)
    imported_pair='"$imported_cert_dir/fullchain.pem"'
    blank_guard='[ -f "$CONFIG_FILE" ]'
    target_pair='"$le_live_root/$naive_domain/fullchain.pem"'
    lineage_guard='rr_certbot_webroot_lineage_is_renewable "$naive_domain" ||'
    runtime_guard='rr_certbot_renewal_runtime_is_ready "$naive_domain" ||'
    hook_guard='rr_certificate_deploy_hook_is_current ||'
    [[ "$preflight_body" == *"$imported_pair"*"$blank_guard"*"$target_pair"*"$lineage_guard"*"$runtime_guard"*"$hook_guard"* ]] ||
        fail 'Portable Naive preflight order no longer validates imported, target lineage, renewal runtime and hook state.'

    subscription_preflight_body=$(declare -f rr_restore_preflight_portable_subscription_target)
    subscription_pair='subscription_certificate_pair_valid'
    subscription_lineage='rr_certbot_webroot_lineage_is_renewable "$target_domain" ||'
    subscription_runtime='rr_certbot_renewal_runtime_is_ready "$target_domain" ||'
    generic_hook_guard='rr_certificate_deploy_hook_is_current ||'
    [[ "$subscription_preflight_body" == *"$subscription_pair"*"$subscription_lineage"*"$subscription_runtime"*"$generic_hook_guard"* ]] ||
        fail 'Portable subscription preflight no longer validates target certificate, lineage, renewal runtime and hook state.'
)

printf '%s\n' 'Backup archive regression tests passed (17/17).'
