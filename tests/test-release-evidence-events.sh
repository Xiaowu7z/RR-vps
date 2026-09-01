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

printf '%s\n' '[1/7] CI push and both VPS audit event classes are independently required'
write_single_success ci.yml push 1001 10
write_single_success vps-audit.yml push 2001 20
write_single_success vps-audit.yml workflow_dispatch 3001 30
rr_update_guard_assert_workflow_gate ci.yml push "$fixture_sha" || fail 'CI push rejected'
rr_update_guard_assert_workflow_gate vps-audit.yml push "$fixture_sha" || fail 'VPS push rejected'
rr_update_guard_assert_workflow_gate vps-audit.yml workflow_dispatch "$fixture_sha" || \
    fail 'VPS workflow_dispatch rejected'

printf '%s\n' '[2/7] complete page/per_page traversal accepts 101 exact runs'
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

printf '%s\n' '[3/7] the newest run_number/run_attempt must itself be successful'
jq '(.workflow_runs[0].conclusion) = "failure"' \
    "$(page_path ci.yml push 2)" >"$test_root/newest-failed.json"
cp "$test_root/newest-failed.json" "$(page_path ci.yml push 2)"
expect_reject 'newest failed run' ci.yml push

printf '%s\n' '[4/7] changing or incomplete total_count pagination fails closed'
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

printf '%s\n' '[5/7] duplicate IDs and duplicate run attempts fail closed'
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

printf '%s\n' '[6/7] missing exact event, branch or SHA evidence fails closed'
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

printf '%s\n' '[7/7] release and updater contain pre/post-download and pre-write rechecks'
python3 - <<'PY'
from pathlib import Path

release = Path('.github/workflows/release.yml').read_text()
guard = Path('scripts/update-guard.sh').read_text()

for fragment in (
    'require_workflow_success_for_sha ci.yml push "CI push"',
    'require_workflow_success_for_sha vps-audit.yml push "VPS audit push"',
    'require_workflow_success_for_sha vps-audit.yml workflow_dispatch',
    'assert_workflow_gate ci.yml push "CI push"',
    'assert_workflow_gate vps-audit.yml push "VPS audit push"',
    'assert_workflow_gate vps-audit.yml workflow_dispatch',
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
    'rr_update_guard_assert_workflow_gate vps-audit.yml push "$initial_commit"',
    'rr_update_guard_assert_workflow_gate vps-audit.yml workflow_dispatch "$initial_commit"',
):
    if guard.count(fragment) != 2:
        raise SystemExit(f'updater gate is not checked both before and after download: {fragment}')
if guard.count(
    'branch=main&event=${expected_event}&head_sha=${expected_sha}&per_page=100&page=${page}'
) != 1:
    raise SystemExit('updater does not use complete event-specific pagination')
PY

printf '%s\n' 'release evidence event regressions: PASS'
