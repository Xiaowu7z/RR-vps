#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

export PYTHONPATH="$REPO_ROOT/nexus${PYTHONPATH:+:$PYTHONPATH}"

# shellcheck disable=SC1091
source modules/55-resilience.sh

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

printf '%s\n' '[1/15] bounded payload validation and safe archive roundtrip'
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

printf '%s\n' '[2/15] path traversal is rejected before extraction'
expect_archive_reject "$fixtures/traversal.tar.gz"
mkdir -m 700 "$fixtures/traversal-target"
if python3 -m rr_nexus_lib.backup_archive extract \
    "$fixtures/traversal.tar.gz" "$fixtures/traversal-target" >/dev/null 2>&1; then
    fail 'Path-traversal archive was extracted.'
fi
[ ! -e "$test_root/escape" ] || fail 'Path-traversal archive escaped its target.'
[ -z "$(find "$fixtures/traversal-target" -mindepth 1 -print -quit)" ] || \
    fail 'Rejected path-traversal archive partially populated its target.'

printf '%s\n' '[3/15] symbolic-link members are rejected'
expect_archive_reject "$fixtures/symlink.tar.gz"

printf '%s\n' '[4/15] hard-link members are rejected'
expect_archive_reject "$fixtures/hardlink.tar.gz"

printf '%s\n' '[5/15] duplicate canonical members are rejected'
expect_archive_reject "$fixtures/duplicate.tar.gz"

printf '%s\n' '[6/15] the 10000-member limit rejects member 10001'
expect_archive_reject "$fixtures/too-many.tar.gz"

printf '%s\n' '[7/15] an oversized first member is rejected from its header'
expect_archive_reject "$fixtures/huge-first-member.tar.gz"

printf '%s\n' '[8/15] oversized PAX and GNU extended headers are rejected early'
expect_archive_reject "$fixtures/huge-pax.tar.gz"
expect_archive_reject "$fixtures/huge-gnu-longname.tar.gz"

printf '%s\n' '[9/15] authenticated encryption roundtrip rejects tampering atomically'
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

printf '%s\n' '[10/15] crypto rejects symlink, FIFO and oversized sparse inputs'
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

printf '%s\n' '[11/15] publication races cannot redirect the final 0600 permission change'
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

printf '%s\n' '[12/15] backup work directory enforces canonical root-owned 0700 state'
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

printf '%s\n' '[13/15] staging directories reject bad names, links, modes and owners'
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

printf '%s\n' '[14/15] configured Nexus rejects missing, empty and wrong-schema databases'
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

printf '%s\n' '[15/15] a minimal valid Nexus database is snapshotted consistently'
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

printf '%s\n' 'Backup archive regression tests passed (15/15).'
