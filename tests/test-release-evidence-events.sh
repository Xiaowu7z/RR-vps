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

# shellcheck disable=SC1091
source scripts/update-guard.sh

fixture_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fixture_dir="$test_root/pages"
mkdir -p "$fixture_dir"

page_path() {
    local workflow="$1" event="$2" page="$3"
    printf '%s/%s-%s-%s.json\n' "$fixture_dir" "$workflow" "$event" "$page"
}

rr_update_guard_official_get() {
    local source_url="$1" target_file="$2" workflow="" event="" page=""
    if [[ "$source_url" =~ /actions/workflows/([^/]+)/runs\? ]]; then
        workflow=${BASH_REMATCH[1]}
    else
        return 1
    fi
    if [[ "$source_url" =~ \&event=([^\&]+)\& ]]; then
        event=${BASH_REMATCH[1]}
    else
        return 1
    fi
    if [[ "$source_url" =~ \&page=([0-9]+)$ ]]; then
        page=${BASH_REMATCH[1]}
    else
        return 1
    fi
    cp "$(page_path "$workflow" "$event" "$page")" "$target_file"
}

write_single_success() {
    local workflow="$1" event="$2" id="$3" run_number="$4"
    jq -cn --arg sha "$fixture_sha" --arg event "$event" \
        --argjson id "$id" --argjson run_number "$run_number" '
        {total_count:1,workflow_runs:[
          {id:$id,head_sha:$sha,head_branch:"main",event:$event,
           run_number:$run_number,run_attempt:1,
           status:"completed",conclusion:"success"}
        ]}
    ' >"$(page_path "$workflow" "$event" 1)"
}

expect_reject() {
    local label="$1" workflow="$2" event="$3"
    if rr_update_guard_assert_workflow_gate "$workflow" "$event" "$fixture_sha"; then
        fail "$label was accepted"
    fi
}

printf '%s\n' '[1/8] CI push and recovery-evidence push are independently required'
write_single_success ci.yml push 1001 10
write_single_success vps-stability.yml push 2001 20
rr_update_guard_assert_workflow_gate ci.yml push "$fixture_sha" || fail 'CI push rejected'
rr_update_guard_assert_workflow_gate vps-stability.yml push "$fixture_sha" || fail 'recovery-evidence push rejected'

printf '%s\n' '[2/8] complete page/per_page traversal accepts 101 exact runs'
jq -cn --arg sha "$fixture_sha" '
    {total_count:101,workflow_runs:[
      range(1;101) as $n |
      {id:(4000+$n),head_sha:$sha,head_branch:"main",event:"push",
       run_number:$n,run_attempt:1,status:"completed",conclusion:"success"}
    ]}
' >"$(page_path ci.yml push 1)"
jq -cn --arg sha "$fixture_sha" '
    {total_count:101,workflow_runs:[
      {id:4101,head_sha:$sha,head_branch:"main",event:"push",
       run_number:101,run_attempt:1,status:"completed",conclusion:"success"}
    ]}
' >"$(page_path ci.yml push 2)"
rr_update_guard_assert_workflow_gate ci.yml push "$fixture_sha" || \
    fail 'complete two-page inventory rejected'

printf '%s\n' '[3/8] the newest run_number/run_attempt must itself be successful'
jq '(.workflow_runs[0].conclusion) = "failure"' \
    "$(page_path ci.yml push 2)" >"$test_root/newest-failed.json"
cp "$test_root/newest-failed.json" "$(page_path ci.yml push 2)"
expect_reject 'newest failed run' ci.yml push

printf '%s\n' '[4/8] changing or incomplete total_count pagination fails closed'
jq '.total_count = 100' "$(page_path ci.yml push 2)" >"$test_root/changed-total.json"
cp "$test_root/changed-total.json" "$(page_path ci.yml push 2)"
expect_reject 'changed total_count' ci.yml push
jq -cn --arg sha "$fixture_sha" '
    {total_count:2,workflow_runs:[
      {id:5001,head_sha:$sha,head_branch:"main",event:"push",
       run_number:1,run_attempt:1,status:"completed",conclusion:"success"}
    ]}
' >"$(page_path ci.yml push 1)"
expect_reject 'short incomplete inventory' ci.yml push

printf '%s\n' '[5/8] duplicate IDs and duplicate run attempts fail closed'
jq -cn --arg sha "$fixture_sha" '
    {total_count:2,workflow_runs:[
      {id:6001,head_sha:$sha,head_branch:"main",event:"push",
       run_number:6,run_attempt:1,status:"completed",conclusion:"success"},
      {id:6002,head_sha:$sha,head_branch:"main",event:"push",
       run_number:6,run_attempt:1,status:"completed",conclusion:"failure"}
    ]}
' >"$(page_path ci.yml push 1)"
expect_reject 'conflicting duplicate run attempt' ci.yml push
jq '(.workflow_runs[1].id) = .workflow_runs[0].id |
    (.workflow_runs[1].run_attempt) = 2 |
    (.workflow_runs[1].conclusion) = "success"' \
    "$(page_path ci.yml push 1)" >"$test_root/duplicate-id.json"
cp "$test_root/duplicate-id.json" "$(page_path ci.yml push 1)"
expect_reject 'duplicate run ID' ci.yml push

printf '%s\n' '[6/8] missing exact event, branch or SHA evidence fails closed'
jq -cn --arg sha "$fixture_sha" '
    {total_count:1,workflow_runs:[
      {id:7001,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",
       run_number:7,run_attempt:1,status:"completed",conclusion:"success"}
    ]}
' >"$(page_path ci.yml push 1)"
expect_reject 'missing push event' ci.yml push
jq '(.workflow_runs[0].event) = "push" | (.workflow_runs[0].head_branch) = "beta"' \
    "$(page_path ci.yml push 1)" >"$test_root/wrong-branch.json"
cp "$test_root/wrong-branch.json" "$(page_path ci.yml push 1)"
expect_reject 'wrong branch' ci.yml push
jq --arg sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    '(.workflow_runs[0].head_branch) = "main" | (.workflow_runs[0].head_sha) = $sha' \
    "$(page_path ci.yml push 1)" >"$test_root/wrong-sha.json"
cp "$test_root/wrong-sha.json" "$(page_path ci.yml push 1)"
expect_reject 'wrong SHA' ci.yml push

printf '%s\n' '[7/8] release and updater contain pre/post-download and pre-write rechecks'
python3 - <<'PY'
from pathlib import Path

release = Path('.github/workflows/release.yml').read_text()
guard = Path('scripts/update-guard.sh').read_text()

for fragment in (
    'require_workflow_success_for_sha ci.yml push "CI push"',
    'require_workflow_success_for_sha vps-stability.yml push "Release recovery evidence push"',
    'assert_workflow_gate ci.yml push "CI push"',
    'assert_workflow_gate vps-stability.yml push "Release recovery evidence push"',
    'branch=main&event=${expected_event}&head_sha=${REQUESTED_SHA}&per_page=100&page=${page}',
    'branch=main&event=${expected_event}&head_sha=${EXPECTED_SHA}&per_page=100&page=${page}',
    'assert_release_gate || return 1\n                  upload_template=',
    'assert_release_gate\n          tag_object=$(api --method POST',
    'assert_release_gate\n          create_status=0',
):
    if fragment not in release:
        raise SystemExit(f'missing release evidence contract: {fragment}')

for fragment in (
    'rr_update_guard_assert_workflow_gate ci.yml push "$initial_commit"',
    'rr_update_guard_assert_workflow_gate vps-stability.yml push "$initial_commit"',
):
    if guard.count(fragment) != 2:
        raise SystemExit(f'updater gate is not checked both before and after download: {fragment}')
if guard.count(
    'branch=main&event=${expected_event}&head_sha=${expected_sha}&per_page=100&page=${page}'
) != 1:
    raise SystemExit('updater does not use complete event-specific pagination')
PY

printf '%s\n' '[8/8] recovery evidence requires owner approval; full CI and historical archives remain explicit'
python3 - <<'PY'
from pathlib import Path
import hashlib
import yaml

root = Path('.')
workflow_dir = root / '.github/workflows'
evidence_text = (workflow_dir / 'vps-stability.yml').read_text()
evidence = yaml.safe_load(evidence_text)
events = evidence.get('on', evidence.get(True))
assert evidence['name'] == 'Release recovery evidence'
assert events['push']['branches'] == ['main']
assert 'pull_request' not in events
assert evidence['permissions'] == {'contents': 'read'}
assert list(evidence['jobs']) == ['evidence']
job = evidence['jobs']['evidence']
assert job['if'] == "github.ref == 'refs/heads/main'"
assert not job.get('continue-on-error', False)
steps = job['steps']
scripts = [step['run'] for step in steps if 'run' in step]
assert len(scripts) == 1
script = scripts[0]
assert 'set -euo pipefail' in script
assert 'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"' in script
assert 'python3 scripts/rebuild-bundle.py --check' in script
assert 'python3 scripts/verify-owner-recovery-evidence.py --require-approved-policy \\\n' in script
assert '| tee "$RUNNER_TEMP/rr-owner-recovery-evidence.txt"' in script
assert '"$GITHUB_STEP_SUMMARY"' in script
assert all(not step.get('continue-on-error', False) for step in steps)
assert not any(token in evidence_text for token in ('sshpass', 'secrets[', 'audit-stability-host.sh'))

ci_text = (workflow_dir / 'ci.yml').read_text()
ci = yaml.safe_load(ci_text)
assert set(ci['jobs']) == {'validate', 'os-matrix'}
assert 'unchanged-runtime' not in ci_text
assert 'outputs.reuse' not in ci_text
for job in ci['jobs'].values():
    assert 'if' not in job and 'needs' not in job
images = {item['image'] for item in ci['jobs']['os-matrix']['strategy']['matrix']['include']}
assert images == {'debian:12', 'ubuntu:22.04', 'ubuntu:24.04'}

publisher = yaml.safe_load((workflow_dir / 'publish-stable.yml').read_text())
events = publisher.get('on', publisher.get(True))
assert events['workflow_run']['workflows'] == ['CI', 'Release recovery evidence']

# Preserve the old workflow contracts as historical source, never as active
# entries capable of contacting deleted hosts. These are original Git blobs.
for name, expected_blob in (
    ('vps-audit.yml', '93c64b905b9f19e004f45b5617aa5b8c92807844'),
    ('cross-os-management.yml', '54d35a0b2942298e5b95063d1c0cb33d478482bf'),
):
    assert not (workflow_dir / name).exists()
    data = (root / 'docs/audit/retired-workflows' / name).read_bytes()
    header = f'blob {len(data)}\0'.encode()
    assert hashlib.sha1(header + data).hexdigest() == expected_blob
PY

printf '%s\n' 'release evidence event regressions: PASS'
