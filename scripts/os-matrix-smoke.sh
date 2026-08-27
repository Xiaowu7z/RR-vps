#!/bin/bash
# Runs inside disposable Debian/Ubuntu CI containers.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

python3 scripts/rebuild-bundle.py --check
bash scripts/validate.sh

mock_bin=$(mktemp -d)
trap 'rm -rf "$mock_bin"' EXIT
cat > "$mock_bin/systemctl" <<'EOF'
#!/bin/sh
# Container CI has no PID-1 systemd.  Service semantics are covered by the
# regression suite; the OS matrix exercises filesystem transactions.
case "${1:-}" in
    is-active|is-enabled) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$mock_bin/systemctl"
export PATH="$mock_bin:$PATH"

# True clean runtime install, then a second in-place hot update.  No node
# configuration exists in the container, so post-update correctly avoids
# touching unrelated services while still exercising download-independent
# bundle verification, snapshot, atomic runtime switch and guard deployment.
RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade
/usr/local/bin/rr --version | grep -F "RR-vps 7.1.0"
test -x /usr/local/sbin/rr-update-recover
test -s /usr/local/lib/rr/modules/61-update-guard.sh
test -x /usr/local/lib/rr/scripts/naive-cert-hook.sh
test -s /usr/local/lib/rr/nexus/rr_nexus_lib/security.py
test -s /usr/local/lib/rr/nexus/static/admin.js

# A committed first install must be able to roll back to a genuinely clean
# machine, not merely delete the launcher and leave an orphaned runtime.
/usr/local/sbin/rr-update-recover rollback
test ! -e /usr/local/bin/rr
test ! -e /usr/local/lib/rr
test ! -e /usr/local/sbin/rr-update-recover
test ! -e /var/lib/rr-update
RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade

first_manifest=$(sha256sum /usr/local/lib/rr/manifest.sha256 | awk '{print $1}')
# Simulate an uncatchable power-loss window after the old runtime was moved.
if RR_TEST_FAULTS=1 RR_TEST_CRASH_PHASE=old_runtime_moved \
   RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
   RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
   bash scripts/install-core.sh --upgrade; then
    echo "fault injection unexpectedly succeeded" >&2
    exit 1
fi
/usr/local/sbin/rr-update-recover recover
/usr/local/bin/rr --version | grep -F "RR-vps 7.1.0"

RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade
test "$(sha256sum /usr/local/lib/rr/manifest.sha256 | awk '{print $1}')" = "$first_manifest"

# Simulate power loss after the new runtime is visible but before migration.
if RR_TEST_FAULTS=1 RR_TEST_CRASH_PHASE=runtime_swapped \
   RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
   RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
   bash scripts/install-core.sh --upgrade; then
    echo "runtime-swap fault injection unexpectedly succeeded" >&2
    exit 1
fi
/usr/local/sbin/rr-update-recover recover
/usr/local/bin/rr --version | grep -F "RR-vps 7.1.0"

RR_BUNDLE_FILE="$repo_root/rr-bundle.tar.gz" \
RR_GUARD_FILE="$repo_root/scripts/update-guard.sh" \
    bash scripts/install-core.sh --upgrade

# The previous committed transaction is deliberately retained.  Prove the
# one-command manual rollback works and leaves a loadable runtime.
/usr/local/sbin/rr-update-recover rollback
/usr/local/bin/rr --version | grep -F "RR-vps 7.1.0"

# Exercise the user-facing complete uninstall in the disposable container.
printf 'y\n' | bash -c '
  for module_file in /usr/local/lib/rr/modules/*.sh; do
    # shellcheck disable=SC1090
    source "$module_file"
  done
  uninstall_all
'
test ! -e /usr/local/bin/rr
test ! -e /usr/local/lib/rr
test ! -e /usr/local/sbin/rr-update-recover

echo "OS matrix smoke passed: $(. /etc/os-release; printf '%s %s' "$ID" "$VERSION_ID")"
