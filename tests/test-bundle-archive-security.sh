#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    local source_file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$source_file"
}

# Load the runtime validator and retain it under a stable test-only name.
# shellcheck disable=SC1091
source modules/60-update.sh
# shellcheck disable=SC2294
eval "$(declare -f rr_bundle_archive_is_safe | sed \
    '1s/rr_bundle_archive_is_safe/rr_runtime_bundle_archive_is_safe/')"

# Load only the bootstrap validator function: sourcing install-core.sh would
# execute the installer.  Keeping a second callable copy makes every fixture
# exercise both independently shipped trust boundaries.
# shellcheck disable=SC2294
eval "$(extract_function scripts/install-core.sh rr_bundle_archive_is_safe)"
# shellcheck disable=SC2294
eval "$(declare -f rr_bundle_archive_is_safe | sed \
    '1s/rr_bundle_archive_is_safe/rr_bootstrap_bundle_archive_is_safe/')"

archive_validators=(
    rr_runtime_bundle_archive_is_safe
    rr_bootstrap_bundle_archive_is_safe
)

python3 - "$test_root" <<'PY'
from __future__ import annotations

import gzip
import os
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
chunk = b"\0" * (1024 * 1024)


def octal(value: int, width: int) -> bytes:
    encoded = f"{value:o}".encode("ascii")
    if len(encoded) > width - 1:
        raise ValueError("octal field overflow")
    return encoded.rjust(width - 1, b"0") + b"\0"


def header(
    name: str | bytes,
    size: int = 0,
    typeflag: bytes = b"0",
    *,
    prefix: str | bytes = b"",
    size_field: bytes | None = None,
    name_tail: bytes = b"",
) -> bytes:
    block = bytearray(512)
    raw_name = name.encode("ascii") if isinstance(name, str) else name
    raw_prefix = prefix.encode("ascii") if isinstance(prefix, str) else prefix
    if len(raw_name) > 100 or len(raw_prefix) > 155:
        raise ValueError("fixture path too long")
    block[: len(raw_name)] = raw_name
    if name_tail:
        start = len(raw_name) + 1
        block[start : start + len(name_tail)] = name_tail
    block[100:108] = octal(0o600, 8)
    block[108:116] = octal(0, 8)
    block[116:124] = octal(0, 8)
    block[124:136] = size_field if size_field is not None else octal(size, 12)
    block[136:148] = octal(0, 12)
    block[148:156] = b"        "
    block[156:157] = typeflag
    block[257:263] = b"ustar\0"
    block[263:265] = b"00"
    block[265:269] = b"root"
    block[297:301] = b"root"
    block[345 : 345 + len(raw_prefix)] = raw_prefix
    checksum = sum(block)
    block[148:156] = f"{checksum:06o}\0 ".encode("ascii")
    return bytes(block)


def member(
    name: str | bytes,
    payload: bytes = b"",
    typeflag: bytes = b"0",
    **kwargs: object,
) -> bytes:
    return (
        header(name, len(payload), typeflag, **kwargs)
        + payload
        + (b"\0" * ((-len(payload)) % 512))
    )


def write_gzip(name: str, tar_stream: bytes) -> None:
    with gzip.GzipFile(filename="", mode="wb", fileobj=(root / name).open("wb"), mtime=0) as out:
        out.write(tar_stream)


end = b"\0" * 1024
valid_members = (
    member("rr-bundle/rr", b"#!/bin/bash\n:\n")
    + member("rr-bundle/manifest.sha256", b"fixture\n")
)
write_gzip("valid.tar.gz", valid_members + end)
write_gzip("valid-prefix.tar.gz", (
    member("rr", b"#!/bin/bash\n:\n", prefix="rr-bundle")
    + member("manifest.sha256", b"fixture\n", prefix="rr-bundle")
    + end
))
write_gzip("valid-null-typeflag.tar.gz", (
    member("rr-bundle/rr", b"#!/bin/bash\n:\n", b"\0")
    + member("rr-bundle/manifest.sha256", b"fixture\n", b"\0")
    + end
))
write_gzip("valid-zero-trailer.tar.gz", valid_members + end + (b"\0" * 4096))
write_gzip("zero-members.tar.gz", end)
write_gzip("one-member.tar.gz", member("rr-bundle/rr", b":\n") + end)
write_gzip("traversal.tar.gz", (
    member("rr-bundle/../../etc/passwd", b"x")
    + member("rr-bundle/rr", b":\n")
    + end
))
write_gzip("absolute.tar.gz", (
    member("/rr-bundle/rr", b":\n")
    + member("rr-bundle/manifest.sha256", b"x")
    + end
))
write_gzip("non-ascii-name.tar.gz", (
    member(b"rr-bundle/\xff", b"x")
    + member("rr-bundle/rr", b":\n")
    + end
))
write_gzip("ambiguous-name.tar.gz", (
    member("rr-bundle/rr", b":\n", name_tail=b"hidden")
    + member("rr-bundle/manifest.sha256", b"x")
    + end
))
write_gzip("duplicate.tar.gz", (
    member("rr-bundle/rr", b"one")
    + member("rr-bundle/rr", b"two")
    + end
))
write_gzip("unsupported-nexus-root-module.tar.gz", (
    member("rr-bundle/rr", b"#!/bin/bash\n:\n")
    + member("rr-bundle/manifest.sha256", b"fixture\n")
    + member("rr-bundle/nexus/helper.py", b"pass\n")
    + end
))

for fixture_name, typeflag in {
    "symlink": b"2",
    "hardlink": b"1",
    "directory": b"5",
    "character-device": b"3",
    "block-device": b"4",
    "fifo": b"6",
    "contiguous-file": b"7",
    "pax-extension": b"x",
    "global-pax-extension": b"g",
    "gnu-longname": b"L",
    "gnu-longlink": b"K",
    "gnu-sparse": b"S",
}.items():
    write_gzip(
        f"{fixture_name}.tar.gz",
        member("rr-bundle/rr", b"", typeflag)
        + member("rr-bundle/manifest.sha256", b"x")
        + end,
    )

base256 = bytearray(12)
base256[0] = 0x80
base256[-1] = 1
write_gzip("base256-size.tar.gz", (
    header("rr-bundle/rr", size_field=bytes(base256))
    + member("rr-bundle/manifest.sha256", b"x")
    + end
))
write_gzip("invalid-octal-size.tar.gz", (
    header("rr-bundle/rr", size_field=b"00000000008\0")
    + member("rr-bundle/manifest.sha256", b"x")
    + end
))

bad_checksum = bytearray(valid_members + end)
bad_checksum[0] ^= 1
write_gzip("bad-checksum.tar.gz", bytes(bad_checksum))
write_gzip("truncated-header.tar.gz", b"x" * 100)
write_gzip("truncated-member.tar.gz", header("rr-bundle/rr", 64) + b"short")
write_gzip("truncated-padding.tar.gz", header("rr-bundle/rr", 1) + b"x")
write_gzip("partial-end-marker.tar.gz", (
    valid_members + (b"\0" * 512) + member("rr-bundle/modules/00.sh", b":\n") + end
))
write_gzip("nonzero-trailer.tar.gz", valid_members + end + b"attacker-data")

# These limit fixtures contain every declared byte.  If the corresponding
# size check is removed, they remain otherwise-valid tar/gzip streams instead
# of being rejected later as truncated input.
with gzip.GzipFile(filename="", mode="wb", fileobj=(root / "oversized-member.tar.gz").open("wb"), mtime=0) as out:
    oversized_size = 16 * 1024 * 1024 + 1
    out.write(header("rr-bundle/rr", oversized_size))
    for _ in range(16):
        out.write(chunk)
    out.write(b"x")
    out.write(b"\0" * ((-oversized_size) % 512))
    out.write(member("rr-bundle/manifest.sha256", b"x"))
    out.write(end)

with gzip.GzipFile(filename="", mode="wb", fileobj=(root / "too-many-members.tar.gz").open("wb"), mtime=0) as out:
    for index in range(513):
        out.write(member(f"rr-bundle/modules/{index:03d}.sh", b""))
    out.write(end)

with gzip.GzipFile(filename="", mode="wb", fileobj=(root / "oversized-total.tar.gz").open("wb"), mtime=0) as out:
    for index in range(5):
        size = 16 * 1024 * 1024
        out.write(header(f"rr-bundle/modules/{index:02d}.sh", size))
        for _ in range(16):
            out.write(chunk)
    out.write(end)

write_gzip("oversized-zero-trailer.tar.gz", valid_members + end + (b"\0" * (1024 * 1024 + 1)))
(root / "invalid-gzip.tar.gz").write_bytes(b"not a gzip stream")
shutil.copyfile(root / "valid.tar.gz", root / "truncated-gzip.tar.gz")
with (root / "truncated-gzip.tar.gz").open("r+b") as stream:
    stream.truncate(max(1, stream.seek(0, os.SEEK_END) - 8))

# A valid 60 MiB expanded archive is stored with gzip level 0, making the
# compressed representation exceed 50 MiB while remaining below every
# expanded/member limit.  Only the transport-size guard should reject it.
with gzip.GzipFile(
    filename="",
    mode="wb",
    fileobj=(root / "oversized-compressed.tar.gz").open("wb"),
    compresslevel=0,
    mtime=0,
) as out:
    for index in range(4):
        size = 15 * 1024 * 1024
        out.write(header(f"rr-bundle/modules/{index:02d}.sh", size))
        for _ in range(15):
            out.write(chunk)
    out.write(end)
if (root / "oversized-compressed.tar.gz").stat().st_size <= 50 * 1024 * 1024:
    raise SystemExit("compressed-size fixture did not cross its intended limit")
PY

expect_archive_accept() {
    local fixture="$1" validator=""
    for validator in "${archive_validators[@]}"; do
        "$validator" "$test_root/$fixture" >/dev/null 2>&1 || \
            fail "$validator rejected safe fixture $fixture"
    done
}

expect_archive_reject() {
    local fixture="$1" validator=""
    for validator in "${archive_validators[@]}"; do
        if "$validator" "$test_root/$fixture" >/dev/null 2>&1; then
            fail "$validator accepted hostile fixture $fixture"
        fi
    done
}

printf '%s\n' '[1/5] both archive validators accept canonical regular-file bundles'
expect_archive_accept valid.tar.gz
expect_archive_accept valid-prefix.tar.gz
expect_archive_accept valid-null-typeflag.tar.gz
expect_archive_accept valid-zero-trailer.tar.gz

printf '%s\n' '[2/5] both archive validators reject path, type and duplicate attacks'
for fixture in \
    zero-members.tar.gz one-member.tar.gz traversal.tar.gz absolute.tar.gz \
    non-ascii-name.tar.gz ambiguous-name.tar.gz duplicate.tar.gz \
    unsupported-nexus-root-module.tar.gz \
    symlink.tar.gz hardlink.tar.gz directory.tar.gz character-device.tar.gz \
    block-device.tar.gz fifo.tar.gz contiguous-file.tar.gz pax-extension.tar.gz \
    global-pax-extension.tar.gz gnu-longname.tar.gz gnu-longlink.tar.gz \
    gnu-sparse.tar.gz; do
    expect_archive_reject "$fixture"
done

printf '%s\n' '[3/5] both archive validators reject malformed headers, truncation and bombs'
for fixture in \
    base256-size.tar.gz invalid-octal-size.tar.gz bad-checksum.tar.gz \
    truncated-header.tar.gz truncated-member.tar.gz truncated-padding.tar.gz \
    partial-end-marker.tar.gz nonzero-trailer.tar.gz oversized-zero-trailer.tar.gz \
    invalid-gzip.tar.gz truncated-gzip.tar.gz oversized-member.tar.gz \
    too-many-members.tar.gz oversized-total.tar.gz oversized-compressed.tar.gz; do
    expect_archive_reject "$fixture"
done

run_runtime_tree_validator() (
    # shellcheck disable=SC1091
    source modules/60-update.sh
    PYTHONPYCACHEPREFIX="$test_root/pycache-runtime" rr_bundle_tree_is_valid "$1"
)

run_bootstrap_tree_validator() (
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_manifest_is_valid)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/install-core.sh rr_bundle_tree_is_valid)"
    PYTHONPYCACHEPREFIX="$test_root/pycache-bootstrap" rr_bundle_tree_is_valid "$1"
)

tree_validators=(run_bootstrap_tree_validator run_runtime_tree_validator)

make_valid_tree() {
    local tree="$1"
    mkdir -p "$tree/scripts" "$tree/modules" "$tree/nexus/rr_nexus_lib" "$tree/nexus/static"
    printf '%s\n' '#!/bin/bash' ':' > "$tree/rr"
    printf '%s\n' '#!/bin/bash' ':' > "$tree/scripts/naive-cert-hook.sh"
    printf '%s\n' '#!/bin/bash' ':' > "$tree/scripts/update-recover.sh"
    printf '%s\n' '#!/usr/bin/env python3' 'pass' > "$tree/scripts/update-external-state.py"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="test"' > "$tree/modules/00-runtime.sh"
    printf '%s\n' '#!/bin/bash' ':' > "$tree/modules/10-system.sh"
    printf '%s\n' 'pass' > "$tree/nexus/rr_nexus.py"
    printf '%s\n' 'pass' > "$tree/nexus/sub_server.py"
    printf '%s\n' 'pass' > "$tree/nexus/rr_nexus_lib/helper.py"
    printf '%s\n' '<!doctype html>' > "$tree/nexus/static/index.html"
    printf '%s\n' '"use strict";' > "$tree/nexus/static/app.js"
    printf '%s\n' ':root {}' > "$tree/nexus/static/app.css"
    (
        cd "$tree"
        find . -type f ! -name manifest.sha256 -printf '%P\0' | \
            LC_ALL=C sort -z | xargs -0 sha256sum > manifest.sha256
    )
}

expect_tree_accept() {
    local tree="$1" validator=""
    for validator in "${tree_validators[@]}"; do
        "$validator" "$tree" >/dev/null 2>&1 || \
            fail "$validator rejected safe bundle tree $(basename "$tree")"
    done
}

expect_tree_reject() {
    local tree="$1" validator=""
    for validator in "${tree_validators[@]}"; do
        if "$validator" "$tree" >/dev/null 2>&1; then
            fail "$validator accepted unsafe bundle tree $(basename "$tree")"
        fi
    done
}

printf '%s\n' '[4/5] both extracted trees reject unmanifested, special and invalid payloads'
valid_tree="$test_root/tree-valid"
make_valid_tree "$valid_tree"
expect_tree_accept "$valid_tree"

extra_tree="$test_root/tree-extra"
cp -a "$valid_tree" "$extra_tree"
printf '%s\n' 'unmanifested' > "$extra_tree/nexus/static/extra.js"
expect_tree_reject "$extra_tree"

unsupported_root_tree="$test_root/tree-unsupported-nexus-root"
cp -a "$valid_tree" "$unsupported_root_tree"
printf '%s\n' 'pass' > "$unsupported_root_tree/nexus/helper.py"
(
    cd "$unsupported_root_tree"
    sha256sum nexus/helper.py >> manifest.sha256
)
expect_tree_reject "$unsupported_root_tree"

missing_tree="$test_root/tree-missing"
cp -a "$valid_tree" "$missing_tree"
rm -f "$missing_tree/modules/10-system.sh"
expect_tree_reject "$missing_tree"

symlink_tree="$test_root/tree-symlink"
cp -a "$valid_tree" "$symlink_tree"
ln -s app.js "$symlink_tree/nexus/static/link.js"
expect_tree_reject "$symlink_tree"

fifo_tree="$test_root/tree-fifo"
cp -a "$valid_tree" "$fifo_tree"
mkfifo "$fifo_tree/nexus/static/injected.js"
expect_tree_reject "$fifo_tree"

duplicate_manifest_tree="$test_root/tree-duplicate-manifest"
cp -a "$valid_tree" "$duplicate_manifest_tree"
head -n 1 "$duplicate_manifest_tree/manifest.sha256" >> \
    "$duplicate_manifest_tree/manifest.sha256"
expect_tree_reject "$duplicate_manifest_tree"

bad_digest_tree="$test_root/tree-bad-digest"
cp -a "$valid_tree" "$bad_digest_tree"
printf '%s\n' 'changed' >> "$bad_digest_tree/rr"
expect_tree_reject "$bad_digest_tree"

bad_shell_tree="$test_root/tree-bad-shell"
cp -a "$valid_tree" "$bad_shell_tree"
printf '%s\n' 'if then' > "$bad_shell_tree/modules/10-system.sh"
(
    cd "$bad_shell_tree"
    sha256sum modules/10-system.sh > replacement.digest
    awk 'NR == FNR { replacement = $1; next } \
        $2 == "modules/10-system.sh" { $1 = replacement } { print }' \
        replacement.digest manifest.sha256 > manifest.next
    mv manifest.next manifest.sha256
    rm -f replacement.digest
)
expect_tree_reject "$bad_shell_tree"

bad_python_tree="$test_root/tree-bad-python"
cp -a "$valid_tree" "$bad_python_tree"
printf '%s\n' 'def broken(:' > "$bad_python_tree/nexus/rr_nexus.py"
(
    cd "$bad_python_tree"
    sha256sum nexus/rr_nexus.py > replacement.digest
    awk 'NR == FNR { replacement = $1; next } \
        $2 == "nexus/rr_nexus.py" { $1 = replacement } { print }' \
        replacement.digest manifest.sha256 > manifest.next
    mv manifest.next manifest.sha256
    rm -f replacement.digest
)
expect_tree_reject "$bad_python_tree"

bad_external_python_tree="$test_root/tree-bad-external-python"
cp -a "$valid_tree" "$bad_external_python_tree"
printf '%s\n' 'def broken(:' > "$bad_external_python_tree/scripts/update-external-state.py"
(
    cd "$bad_external_python_tree"
    sha256sum scripts/update-external-state.py > replacement.digest
    awk 'NR == FNR { replacement = $1; next } \
        $2 == "scripts/update-external-state.py" { $1 = replacement } { print }' \
        replacement.digest manifest.sha256 > manifest.next
    mv manifest.next manifest.sha256
    rm -f replacement.digest
)
expect_tree_reject "$bad_external_python_tree"

printf '%s\n' '[5/5] release builder rejects schema drift and emits extension-free USTAR'
python3 - "$REPO_ROOT" "$test_root" <<'PY'
from __future__ import annotations

import importlib.util
import io
import pathlib
import sys
import tarfile

repo = pathlib.Path(sys.argv[1])
test_root = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "rr_rebuild_bundle", repo / "scripts/rebuild-bundle.py"
)
if spec is None or spec.loader is None:
    raise SystemExit("could not load release builder")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def fixture_root(name: str) -> pathlib.Path:
    root = test_root / name
    (root / "scripts").mkdir(parents=True)
    (root / "modules").mkdir()
    (root / "nexus").mkdir()
    for relative in (
        "rr",
        "scripts/naive-cert-hook.sh",
        "scripts/update-recover.sh",
        "scripts/update-external-state.py",
    ):
        path = root / relative
        path.write_text("fixture\n", encoding="ascii")
    return root


def expect_release_files_reject(root: pathlib.Path, label: str) -> None:
    builder.BASE = root
    try:
        builder.release_files()
    except ValueError:
        return
    raise SystemExit(f"release builder accepted {label}")


nested = fixture_root("builder-nested")
(nested / "nexus/deeper").mkdir()
(nested / "nexus/deeper/injected.py").write_text("pass\n", encoding="ascii")
expect_release_files_reject(nested, "nested Nexus runtime path")

unsupported_root = fixture_root("builder-unsupported-root")
(unsupported_root / "nexus/helper.py").write_text("pass\n", encoding="ascii")
expect_release_files_reject(
    unsupported_root, "Nexus root module the installer would not copy"
)

long_name = fixture_root("builder-long-name")
(long_name / "nexus" / (("a" * 86) + ".py")).write_text("pass\n", encoding="ascii")
expect_release_files_reject(long_name, "archive member name over 100 bytes")

builder.BASE = repo
manifest = builder.expected_manifest()
bundle = builder.expected_bundle(manifest)
with tarfile.open(fileobj=io.BytesIO(bundle), mode="r:gz") as archive:
    members = archive.getmembers()
    if any(member.pax_headers or member.type != tarfile.REGTYPE for member in members):
        raise SystemExit("release builder emitted a tar extension or non-regular member")
    if any(len(member.name.encode("ascii")) > 100 for member in members):
        raise SystemExit("release builder emitted a member outside its fixed USTAR name field")
PY

printf '%s\n' 'bundle archive and tree security regressions: PASS'
