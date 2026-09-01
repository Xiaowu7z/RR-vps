#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

printf '%s\n' '[1/5] sing-box 1.14.0 source, native build and metadata are pinned'
python3 - <<'PY'
from __future__ import annotations

import pathlib
import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/build-nexus-core.yml").read_text())
env = workflow["env"]
expected_tags = (
    "with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,"
    "with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,"
    "with_usbip,with_openvpn,with_openconnect,badlinkname,"
    "tfogo_checklinkname0,with_v2ray_api"
)
expected = {
    "RR_NEXUS_CORE_VERSION": "1.14.0",
    "RR_NEXUS_CORE_TAG": "v1.14.0",
    "RR_NEXUS_CORE_SOURCE_SHA": "0b8995879f29a9b98ee027bc17b75e101445b238",
    "RR_NEXUS_CORE_UPSTREAM_RELEASE_ID": "379452161",
    "RR_NEXUS_CORE_GO_VERSION": "go1.25.5",
    "RR_NEXUS_CORE_MIN_GO_VERSION": "1.25.0",
    "RR_NEXUS_CORE_BUILD_TAGS": expected_tags,
}
if env != expected:
    raise SystemExit(f"unexpected pinned core environment: {env!r}")

resolve = next(
    step["run"]
    for step in workflow["jobs"]["version"]["steps"]
    if step.get("name") == "Resolve and validate the pinned official sing-box release"
)
build = next(
    step["run"]
    for step in workflow["jobs"]["build"]["steps"]
    if step.get("name") == "Build and execute API-enabled core"
)
metadata = next(
    step["run"]
    for step in workflow["jobs"]["publish"]["steps"]
    if step.get("name") == "Verify artifacts and create release metadata"
)
for fragment in (
    "/repos/SagerNet/sing-box/releases/tags/${RR_NEXUS_CORE_TAG}",
    'release_id "$RR_NEXUS_CORE_UPSTREAM_RELEASE_ID"',
    '.immutable == true',
    '.object.type == "commit" and .object.sha == $sha',
    '[ "$source_sha" = "$RR_NEXUS_CORE_SOURCE_SHA" ]',
):
    if fragment not in resolve:
        raise SystemExit(f"official 1.14 source identity is not closed: {fragment}")
if 'release_json=$(api "/repos/SagerNet/sing-box/releases/latest")' in resolve:
    raise SystemExit("core source silently returned to mutable latest selection")
for fragment in (
    'amd64:x86_64|arm64:aarch64',
    'export CGO_ENABLED=0 GOOS=linux GOARCH GOTOOLCHAIN=local',
    '[ "$go_version" = "$RR_NEXUS_CORE_GO_VERSION" ]',
    '[ "$tags" = "$RR_NEXUS_CORE_BUILD_TAGS" ]',
    'Revision: ${SOURCE_SHA}',
    'CGO: disabled',
    "vcs.revision=",
):
    if fragment not in build:
        raise SystemExit(f"native 1.14 binary proof is missing: {fragment}")
for fragment in (
    '"GO_VERSION=${RR_NEXUS_CORE_GO_VERSION}"',
    '"CGO_ENABLED=0"',
    '"BUILD_TAGS=${RR_NEXUS_CORE_BUILD_TAGS}"',
    '"SOURCE_COMMIT=${SOURCE_SHA}"',
):
    if fragment not in metadata:
        raise SystemExit(f"release metadata proof is missing: {fragment}")

module = pathlib.Path("modules/85-nexus.sh").read_text()
for fragment in (
    'NEXUS_CORE_TARGET_VERSION="1.14.0"',
    'NEXUS_CORE_SOURCE_COMMIT="0b8995879f29a9b98ee027bc17b75e101445b238"',
    'nexus_validate_upstream_core_release()',
    'nexus_validate_traffic_core_binary()',
    'nexus_download_traffic_core "$tx_dir"',
):
    if fragment not in module:
        raise SystemExit(f"runtime 1.14 contract is missing: {fragment}")
for forbidden in (
    "NEXUS_CORE_PINNED_VERSION",
    "nexus_pinned_core_fallback_allowed",
    "\n        return 44\n",
    '热更新候选缺少既有流量统计内核',
):
    if forbidden in module:
        raise SystemExit(f"legacy downgrade/upgrade blocker remains: {forbidden}")
PY

printf '%s\n' '[2/5] core CI gates inspect the latest attempt for the exact SHA'
python3 - <<'PY'
from __future__ import annotations

import pathlib
import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/build-nexus-core.yml").read_text())
scripts = "\n".join(
    step.get("run", "")
    for job in workflow["jobs"].values()
    for step in job.get("steps", [])
    if isinstance(step, dict)
)
if "status=success" in scripts:
    raise SystemExit("core workflow still prefilters CI runs by success")
queries = [line for line in scripts.splitlines() if "actions/workflows/ci.yml/runs?" in line]
if len(queries) != 3:
    raise SystemExit(f"expected three exact-SHA CI queries, found {len(queries)}")
if any("head_sha=${" not in line or "event=push" not in line for line in queries):
    raise SystemExit("a core CI query is not scoped to the exact push SHA")
if scripts.count("sort_by(.run_number, .run_attempt) | last") != 3:
    raise SystemExit("every core CI gate must select the latest run attempt")
PY

sha=0123456789abcdef0123456789abcdef01234567
attempt_fixture=$(jq -cn --arg sha "$sha" '[{workflow_runs: [
    {head_sha: $sha, head_branch: "main", event: "push", run_number: 71,
     run_attempt: 1, status: "completed", conclusion: "success"},
    {head_sha: $sha, head_branch: "main", event: "push", run_number: 71,
     run_attempt: 2, status: "completed", conclusion: "failure"}
]}]')
latest_ci_is_success() {
    jq -e --arg sha "$sha" '
      (map(.workflow_runs[]) |
        map(select(.head_sha == $sha and .head_branch == "main" and .event == "push")) |
        sort_by(.run_number, .run_attempt) | last) as $run |
      $run != null and $run.head_sha == $sha and
      $run.head_branch == "main" and $run.event == "push" and
      $run.status == "completed" and $run.conclusion == "success"
    ' >/dev/null
}
if latest_ci_is_success <<<"$attempt_fixture"; then
    fail 'attempt 1 success incorrectly masked attempt 2 failure'
fi
attempt_fixture=$(jq '.[0].workflow_runs[1].conclusion = "success"' <<<"$attempt_fixture")
latest_ci_is_success <<<"$attempt_fixture" || fail 'latest successful attempt was rejected'

printf '%s\n' '[3/5] core publication is an exact owned, resumable transaction'
python3 - <<'PY'
from __future__ import annotations

import pathlib
import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/build-nexus-core.yml").read_text())
publish = next(
    step["run"]
    for step in workflow["jobs"]["publish"]["steps"]
    if step.get("name") == "Publish without changing an existing release"
)
build = next(
    step["run"]
    for step in workflow["jobs"]["build"]["steps"]
    if step.get("name") == "Build and execute API-enabled core"
)
for fragment in ("--sort=name", "--format=ustar", "--mtime='@0'", "gzip -n -9"):
    if fragment not in build:
        raise SystemExit(f"core rerun artifact is not deterministic: {fragment}")
required = (
    "rr-nexus-core-release-owner:v1:",
    "load_owned_target_tag()",
    "is_owned_mutable_draft()",
    "is_exact_mutable_draft()",
    "classify_target_release_state()",
    "adopt_or_create_draft()",
    "publish_draft_and_confirm()",
    '--force-with-lease="refs/tags/${TAG}:${expected_object_sha}"',
)
for fragment in required:
    if fragment not in publish:
        raise SystemExit(f"missing core transaction contract: {fragment}")
for forbidden in (
    'DELETE "/repos/${GITHUB_REPOSITORY}/releases/',
    'DELETE "/repos/${GITHUB_REPOSITORY}/git/refs/tags/',
    'gh release create "$TAG"',
):
    if forbidden in publish:
        raise SystemExit(f"unsafe non-CAS/non-resumable core mutation remains: {forbidden}")
PY

printf '%s\n' '[4/5] exact draft/public predicates and PATCH ambiguity are executable contracts'
transaction_functions=$(python3 - <<'PY'
from __future__ import annotations

import pathlib
import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/build-nexus-core.yml").read_text())
publish = next(
    step["run"]
    for step in workflow["jobs"]["publish"]["steps"]
    if step.get("name") == "Publish without changing an existing release"
)
start = publish.index("is_owned_mutable_draft() {")
end = publish.index("delete_owned_target_tag_cas() {", start)
patch_start = publish.index("publish_draft_and_confirm() {", end)
patch_end = publish.index("verify_published_release() {", patch_start)
print(publish[start:end])
print(publish[patch_start:patch_end])
PY
)
# shellcheck disable=SC2294
eval "$transaction_functions"

TAG=rr-nexus-core-v1.2.3-r1
GITHUB_REPOSITORY=Xiaowu7z/RR-vps
RELEASE_TITLE='RR Nexus traffic core · sing-box 1.2.3'
RELEASE_NOTES='fixture notes'
RUN_OWNER_MARKER='rr-nexus-core-release-owner:v1:fixture'
BUILDER_SHA=0123456789abcdef0123456789abcdef01234567
expected_assets=$(jq -cn '[
    {digest:("sha256:"+("1"*64)),name:"BUILD_INFO",size:11},
    {digest:("sha256:"+("2"*64)),name:"SHA256SUMS",size:12},
    {digest:("sha256:"+("3"*64)),name:"rr-sing-box-1.2.3-linux-amd64.tar.gz",size:13},
    {digest:("sha256:"+("4"*64)),name:"rr-sing-box-1.2.3-linux-arm64.tar.gz",size:14}
] | sort_by(.name)')
draft_fixture=$(jq -cn --arg tag "$TAG" --arg sha "$BUILDER_SHA" \
    --arg title "$RELEASE_TITLE" --arg notes "$RELEASE_NOTES" \
    --arg marker "<!-- ${RUN_OWNER_MARKER} -->" --argjson assets "$expected_assets" '
    {id:77,tag_name:$tag,target_commitish:$sha,name:$title,
     draft:true,prerelease:false,immutable:false,author:{login:"github-actions[bot]"},
     body:($notes+"\n\n"+$marker+"\n"),
     assets:[$assets[] | . + {id:(100+.size),state:"uploaded",
       uploader:{login:"github-actions[bot]"}}]}
')
is_exact_mutable_draft "$draft_fixture" "$RUN_OWNER_MARKER" \
    "$BUILDER_SHA" "$expected_assets" || fail 'exact owned draft predicate rejected fixture'

public_fixture=$(jq '.draft=false | .immutable=true' <<<"$draft_fixture")
is_exact_public_release "$public_fixture" 77 "$RUN_OWNER_MARKER" \
    "$BUILDER_SHA" "$expected_assets" || fail 'exact public predicate rejected fixture'
for mutation in \
    '.author.login="attacker"' \
    '.body="foreign"' \
    '.assets[0].uploader.login="attacker"' \
    '.assets[0].digest=("sha256:"+("9"*64))'; do
    candidate=$(jq "$mutation" <<<"$draft_fixture")
    if is_exact_mutable_draft "$candidate" "$RUN_OWNER_MARKER" \
        "$BUILDER_SHA" "$expected_assets"; then
        fail "owned draft predicate accepted mutation: $mutation"
    fi
done

api() {
    if [ "${1:-}" = --method ]; then
        return 1
    fi
    printf '%s\n' "$public_fixture"
}
publish_draft_and_confirm 77 || fail 'lost PATCH response was not resolved by exact-ID GET'

printf '%s\n' '[5/5] workflow YAML and embedded shell remain syntactically valid'
python3 - <<'PY'
from __future__ import annotations

import pathlib
import subprocess
import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/build-nexus-core.yml").read_text())
for job_name, job in workflow["jobs"].items():
    for index, step in enumerate(job.get("steps", [])):
        script = step.get("run") if isinstance(step, dict) else None
        if not script:
            continue
        result = subprocess.run(
            ["bash", "-n"], input=script, text=True, capture_output=True, check=False
        )
        if result.returncode:
            raise SystemExit(
                f"embedded shell syntax failed in {job_name} step {index}: {result.stderr}"
            )
PY

printf '%s\n' 'nexus core supply-chain regressions: PASS'
