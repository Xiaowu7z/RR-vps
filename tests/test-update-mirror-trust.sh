#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
RR_UPDATE_CHANNEL=stable

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$test_root/mirror"
tar -xzf rr-bundle.tar.gz -C "$test_root/mirror"
mirror_root="$test_root/mirror/rr-bundle"

# Model an attacker-controlled/user-configured mirror that serves a completely
# self-consistent bundle while claiming an older version.  Structural checks
# and the bundle's own manifest must both pass; only the trusted-source
# comparison is allowed to reject it.
sed -i 's/^SCRIPT_VERSION="[^"]*"/SCRIPT_VERSION="0.0.0"/' \
    "$mirror_root/modules/00-runtime.sh"
while read -r _ relative_path; do
    (cd "$mirror_root" && sha256sum "$relative_path")
done < "$mirror_root/manifest.sha256" > "$test_root/mirror-manifest.sha256"
mv "$test_root/mirror-manifest.sha256" "$mirror_root/manifest.sha256"

python3 - "$mirror_root" "$test_root/mirror-bundle.tar.gz" <<'PY'
import gzip
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
paths = [line.split(None, 1)[1] for line in
         (root / "manifest.sha256").read_text().splitlines()]
paths.append("manifest.sha256")

raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as archive:
    for relative in paths:
        payload = (root / relative).read_bytes()
        member = tarfile.TarInfo(f"rr-bundle/{relative}")
        member.size = len(payload)
        member.mode = 0o755 if relative == "rr" or relative.endswith(".sh") else 0o644
        member.uid = member.gid = 0
        member.uname = member.gname = "root"
        member.mtime = 0
        archive.addfile(member, io.BytesIO(payload))
with target.open("wb") as output:
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as zipped:
        zipped.write(raw.getvalue())
PY

# shellcheck disable=SC1091
source modules/60-update.sh

YELLOW=""
RED=""
GREEN=""
CYAN=""
RESET=""

version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

RR_RAW_BASE="https://trusted.invalid/release"
RR_MANIFEST_URL="${RR_RAW_BASE}/manifest.sha256"
RR_BOOTSTRAP_URL="${RR_RAW_BASE}/install.sh"
RR_REPOSITORY="Xiaowu7z/RR-vps"
RR_LOCAL_MANIFEST="$test_root/local-manifest.sha256"
SCRIPT_VERSION=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"/\1/p' \
    modules/00-runtime.sh)
[[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "current runtime version fixture is invalid"
RR_TEST_DOWNLOAD_TRACE="$test_root/download-trace"
RR_TEST_GUARD_TRACE="$test_root/guard-trace"
RR_TEST_EXEC_MARKER="$test_root/bootstrap-executed"
export RR_TEST_EXEC_MARKER
cp "$mirror_root/manifest.sha256" "$RR_LOCAL_MANIFEST"
: > "$RR_TEST_DOWNLOAD_TRACE"
: > "$RR_TEST_GUARD_TRACE"

rr_update_guard_copy_verified_asset() {
    local asset="$1" target_file="$2"
    [ "$RR_REPOSITORY" = "Xiaowu7z/RR-vps" ] || return 1
    printf '%s %s\n' "$RR_REPOSITORY" "$asset" >> "$RR_TEST_GUARD_TRACE"
    case "$asset" in
        manifest.sha256)
            cp "$REPO_ROOT/manifest.sha256" "$target_file"
            ;;
        install.sh)
            printf '%s\n' \
                '#!/bin/bash' \
                'RR_BOOTSTRAP_VERSION=999' \
                'RR_REPOSITORY="Xiaowu7z/RR-vps"' \
                'printf "bundle=%s\n" "${RR_BUNDLE_FILE-unset}" > "${RR_TEST_EXEC_MARKER:?}"' \
                'exit 0' > "$target_file"
            ;;
        *)
            return 1
            ;;
    esac
}

rr_download_file() {
    local source_url="$1" target_file="$2" official_only="${4:-false}"
    printf '%s %s\n' "$official_only" "$source_url" >> "$RR_TEST_DOWNLOAD_TRACE"
    case "$source_url" in
        "${RR_RAW_BASE}/rr-bundle.tar.gz")
            [ "$official_only" != true ] || return 1
            cp "$test_root/mirror-bundle.tar.gz" "$target_file"
            ;;
        *)
            return 1
            ;;
    esac
}

rr_bundle_archive_is_safe "$test_root/mirror-bundle.tar.gz" || \
    fail "self-consistent mirror archive did not pass structural validation"
rr_bundle_tree_is_valid "$mirror_root" || \
    fail "self-consistent mirror tree did not pass its own manifest validation"
grep -q '^SCRIPT_VERSION="0.0.0"$' "$mirror_root/modules/00-runtime.sh" || \
    fail "mirror downgrade fixture is not version 0.0.0"

# do_update exits after a successful bootstrap.  Isolate that supported path
# so the assertions below can prove that the trusted fallback actually ran.
(
    set +e
    unset RR_BUNDLE_FILE
    do_update </dev/null
)

[ -s "$RR_TEST_EXEC_MARKER" ] || \
    fail "untrusted mirror version prevented trusted bootstrap fallback"
grep -qx 'bundle=unset' "$RR_TEST_EXEC_MARKER" || \
    fail "untrusted mirror bundle reached the trusted bootstrap"
grep -q "^${RR_REPOSITORY} manifest.sha256$" "$RR_TEST_GUARD_TRACE" || \
    fail "mirror bundle was not authenticated against the stable release manifest"
grep -q "^${RR_REPOSITORY} install.sh$" "$RR_TEST_GUARD_TRACE" || \
    fail "verified stable bootstrap fallback was not copied"

printf 'PASS: mirror 0.0.0 bundle cannot block or enter trusted fallback\n'
