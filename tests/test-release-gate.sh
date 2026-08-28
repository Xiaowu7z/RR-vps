#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
VPS_WORKFLOW="$REPO_ROOT/.github/workflows/vps-audit.yml"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

python3 - "$WORKFLOW" "$VPS_WORKFLOW" "$CI_WORKFLOW" \
    "$TEST_ROOT/assert-workflow-gate.sh" <<'PY'
from pathlib import Path
import re
import sys

release = Path(sys.argv[1]).read_text(encoding="utf-8")
vps = Path(sys.argv[2]).read_text(encoding="utf-8")
ci = Path(sys.argv[3]).read_text(encoding="utf-8")

verify_start = release.index("  verify:\n")
publish_start = release.index("  publish:\n", verify_start)
verify = release[verify_start:publish_start]
publish = release[publish_start:]

assert "permissions:\n      contents: read\n      actions: read" in verify
assert "permissions:\n      contents: write\n      actions: read" in publish
assert "needs: verify" in publish
assert "head_sha=${REQUESTED_SHA}" in verify
assert "head_sha=${EXPECTED_SHA}" in publish
# Pagination is used only for the pre-tag monotonic inventory and the final
# no-newer-version recheck; workflow gates use the exact head_sha filter.
assert release.count("--paginate --slurp") == 2
assert "assert_workflow_gate ci.yml CI" in publish
assert 'assert_workflow_gate vps-audit.yml "VPS audit"' in publish
assert publish.count("assert_release_gate") == 3
assert publish.count("assert_verified_sha_gate") >= 4
assert 'git/ref/heads/main" --jq \'.object.sha\'' in publish
assert re.search(
    r"assert_release_gate\n\s+created_ref=\$\(api --method POST",
    publish,
)
assert re.search(
    r"assert_verified_sha_gate\n\s+assert_no_newer_product_version\n"
    r"\s+published_json=\$\(api --method PATCH",
    publish,
)
assert "bash scripts/" not in publish
assert "python3 scripts/" not in publish
for asset in (
    "CHANGELOG.md", "install.sh", "manifest.sha256",
    "modules/00-runtime.sh", "rr-bundle.tar.gz",
):
    assert f"            {asset}\n" in publish

assert "StrictHostKeyChecking=accept-new" not in vps
assert vps.count("StrictHostKeyChecking=yes") == 3
assert vps.count("HostKeyAlgorithms=ssh-ed25519") == 3
assert vps.count("GlobalKnownHostsFile=/dev/null") == 3
job_ranges = {
    "A": ("  debian-full:\n", "  ubuntu-upgrade:\n"),
    "B": ("  ubuntu-upgrade:\n", "  ubuntu-transaction:\n"),
    "C": ("  ubuntu-transaction:\n", "  vps-gate:\n"),
}
for slot, (start_marker, end_marker) in job_ranges.items():
    start = vps.index(start_marker)
    end = vps.index(end_marker, start)
    job = vps[start:end]
    assert f"RR_{slot}_HOST_KEY: ${{{{ secrets.RR_{slot}_HOST_KEY }}}}" in job
    assert 'printf \'%s %s %s\\n\' "$host" "$host_key_type" "$host_key_data" > "$known_hosts"' in job
assert "pinned SSH host keys" in vps
assert "TOFU" not in vps
for line in vps.splitlines():
    if line.lstrip().startswith("! "):
        assert "||" in line, f"bare negated assertion can pass under errexit: {line}"
assert not re.search(r"!\s+ss\b", vps)
assert not re.search(r"if\s+ss\b[^\n]*\|", vps)
assert not re.search(r"if\s+journalctl\b[^\n]*\|", vps)
assert 'rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null || true)' not in vps
assert "test-uninstall-quarantine.sh|\\" in ci

lines = release.splitlines()
start = lines.index("          assert_workflow_gate() {")
end = lines.index("          assert_immutable_releases_enabled() {", start)
functions = "\n".join(line[10:] for line in lines[start:end]) + "\n"
Path(sys.argv[4]).write_text(functions, encoding="utf-8")
PY

# shellcheck source=/dev/null
source "$TEST_ROOT/assert-workflow-gate.sh"
EXPECTED_SHA=0123456789abcdef0123456789abcdef01234567
GITHUB_REPOSITORY=example/rr-vps
fixture="$TEST_ROOT/runs.json"
api_log="$TEST_ROOT/api.log"
MAIN_SHA="$EXPECTED_SHA"
api() {
    printf '%s\n' "$*" > "$api_log"
    case "$1" in
        */git/ref/heads/main) printf '%s\n' "$MAIN_SHA" ;;
        *) cat "$fixture" ;;
    esac
}

write_run() {
    local sha="$1" branch="$2" event="$3" status="$4" conclusion="$5" attempt="$6"
    jq -n --arg sha "$sha" --arg branch "$branch" --arg event "$event" \
        --arg status "$status" --arg conclusion "$conclusion" --argjson attempt "$attempt" \
        '{workflow_runs:[{run_number:41,run_attempt:$attempt,head_sha:$sha,
          head_branch:$branch,event:$event,status:$status,conclusion:$conclusion}]}' > "$fixture"
}

printf '%s\n' '[1/6] exact successful main push is accepted through a SHA-filtered query'
write_run "$EXPECTED_SHA" main push completed success 1
assert_workflow_gate ci.yml CI
[[ "$(cat "$api_log")" == *"head_sha=${EXPECTED_SHA}"* ]]

printf '%s\n' '[2/6] wrong SHA, branch, event, status, and conclusion fail closed'
for mutation in sha branch event status conclusion; do
    write_run "$EXPECTED_SHA" main push completed success 1
    case "$mutation" in
        sha) write_run 1123456789abcdef0123456789abcdef01234567 main push completed success 1 ;;
        branch) write_run "$EXPECTED_SHA" beta push completed success 1 ;;
        event) write_run "$EXPECTED_SHA" main workflow_dispatch completed success 1 ;;
        status) write_run "$EXPECTED_SHA" main push in_progress success 1 ;;
        conclusion) write_run "$EXPECTED_SHA" main push completed failure 1 ;;
    esac
    if assert_workflow_gate ci.yml CI >/dev/null 2>&1; then
        echo "Release gate accepted invalid ${mutation}." >&2
        exit 1
    fi
done

printf '%s\n' '[3/6] a newer failed rerun supersedes an older success'
jq -n --arg sha "$EXPECTED_SHA" '{workflow_runs:[
  {run_number:41,run_attempt:1,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"success"},
  {run_number:41,run_attempt:2,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"failure"}
]}' > "$fixture"
if assert_workflow_gate vps-audit.yml 'VPS audit' >/dev/null 2>&1; then
    echo 'Release gate accepted a SHA whose latest attempt failed.' >&2
    exit 1
fi

printf '%s\n' '[4/6] a newer successful rerun is accepted'
jq '.workflow_runs[1].conclusion = "success"' "$fixture" > "$fixture.next"
mv "$fixture.next" "$fixture"
assert_workflow_gate vps-audit.yml 'VPS audit'

printf '%s\n' '[5/6] empty workflow evidence is rejected'
printf '%s\n' '{"workflow_runs":[]}' > "$fixture"
if assert_workflow_gate ci.yml CI >/dev/null 2>&1; then
    echo 'Release gate accepted missing CI evidence.' >&2
    exit 1
fi

printf '%s\n' '[6/6] release mutation gate rejects an advanced main tip'
write_run "$EXPECTED_SHA" main push completed success 2
MAIN_SHA="$EXPECTED_SHA"
assert_release_gate
MAIN_SHA=1123456789abcdef0123456789abcdef01234567
if assert_release_gate >/dev/null 2>&1; then
    echo 'Release gate accepted an obsolete main tip.' >&2
    exit 1
fi

printf '%s\n' 'release gate regression: PASS'
