#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

printf '%s\n' '[1/6] sing-box 1.14.0 source, native build and metadata are pinned'
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

printf '%s\n' '[2/6] core CI gates inspect the latest attempt for the exact SHA'
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

printf '%s\n' '[3/6] one-time legacy Latest bootstrap is explicit, exact and self-closing'
bootstrap_functions=$(python3 - <<'PY'
from __future__ import annotations

import pathlib
import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/build-nexus-core.yml").read_text())
trigger = workflow.get("on", workflow.get(True))
bootstrap_input = trigger["workflow_dispatch"]["inputs"]["bootstrap_legacy_latest"]
if bootstrap_input.get("type") != "boolean" or bootstrap_input.get("default") is not False:
    raise SystemExit("legacy Latest bootstrap is not a default-off boolean dispatch input")

version_step = next(
    step
    for step in workflow["jobs"]["version"]["steps"]
    if step.get("name") == "Resolve and validate the pinned official sing-box release"
)
publish_step = next(
    step
    for step in workflow["jobs"]["publish"]["steps"]
    if step.get("name") == "Publish without changing an existing release"
)
for step in (version_step, publish_step):
    if step["env"].get("BOOTSTRAP_LEGACY_LATEST") != "${{ inputs.bootstrap_legacy_latest }}":
        raise SystemExit("a core gate did not receive the explicit bootstrap input")

def pinned_helper(script: str) -> str:
    start = script.index("pinned_legacy_latest_bootstrap_allowed() {")
    end = script.index("\n\nassert_product_latest() {", start)
    return script[start:end].rstrip()

version_helper = pinned_helper(version_step["run"])
publish_helper = pinned_helper(publish_step["run"])
if version_helper != publish_helper:
    raise SystemExit("read-only and write-capable bootstrap predicates drifted")
for fragment in (
    "[ \"$GITHUB_REPOSITORY\" = Xiaowu7z/RR-vps ]",
    "[ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ]",
    "[ \"${BOOTSTRAP_LEGACY_LATEST:-false}\" = true ]",
    "rr-nexus-core-v1.14.0-r1",
    ".id == 377802786",
    "ad69c42e6c6f468b6c643da06e7a461de7d773f3",
    "532275339",
    "532275341",
    "532275350",
    "532275351",
    "matching-refs/tags/v",
):
    if fragment not in version_helper:
        raise SystemExit(f"bootstrap predicate is not exact: {fragment}")
if publish_step["run"].count("make_latest=false") != 2:
    raise SystemExit("auxiliary Core creation/publication can change repository Latest")
for forbidden in ("make_latest=true", "make_latest=legacy"):
    if forbidden in publish_step["run"]:
        raise SystemExit(f"auxiliary Core publication contains forbidden {forbidden}")

script = version_step["run"]
start = script.index("pinned_legacy_latest_bootstrap_allowed() {")
end = script.index("\n\nrelease_json=$(api", start)
print(script[start:end])
PY
)
# shellcheck disable=SC2294
eval "$bootstrap_functions"

GITHUB_REPOSITORY=Xiaowu7z/RR-vps
GITHUB_EVENT_NAME=workflow_dispatch
BOOTSTRAP_LEGACY_LATEST=true
RR_NEXUS_CORE_VERSION=1.14.0
RR_NEXUS_CORE_TAG=v1.14.0
release_tag=rr-nexus-core-v1.14.0-r1

legacy_latest=$(jq -cn '
  {
    id:377802786,
    url:"https://api.github.com/repos/Xiaowu7z/RR-vps/releases/377802786",
    assets_url:"https://api.github.com/repos/Xiaowu7z/RR-vps/releases/377802786/assets",
    upload_url:"https://uploads.github.com/repos/Xiaowu7z/RR-vps/releases/377802786/assets{?name,label}",
    html_url:"https://github.com/Xiaowu7z/RR-vps/releases/tag/rr-nexus-core-v1.13.19",
    tag_name:"rr-nexus-core-v1.13.19",
    target_commitish:"ad69c42e6c6f468b6c643da06e7a461de7d773f3",
    name:"RR Nexus traffic core · sing-box 1.13.19",
    draft:false,prerelease:false,immutable:false,
    author:{login:"github-actions[bot]"},
    created_at:"2026-08-27T12:25:26Z",
    published_at:"2026-08-27T12:26:19Z",
    body:"Built from the official SagerNet/sing-box v1.13.19 source with the additional with_v2ray_api build tag. SHA256SUMS and BUILD_INFO are included. Latest release, refreshed automatically every day or on demand.",
    assets:[
      {id:532275339,name:"BUILD_INFO",state:"uploaded",size:185,
       digest:"sha256:bd5aaf67c5f45f4ce9a6065ddb5dc12cd08c50b502fdea39a9c67d5ac68bd96c",
       url:"https://api.github.com/repos/Xiaowu7z/RR-vps/releases/assets/532275339",
       browser_download_url:"https://github.com/Xiaowu7z/RR-vps/releases/download/rr-nexus-core-v1.13.19/BUILD_INFO",
       uploader:{login:"github-actions[bot]"}},
      {id:532275341,name:"rr-sing-box-1.13.19-linux-amd64.tar.gz",state:"uploaded",size:20610257,
       digest:"sha256:9397dcd049cc1ff7f4fa26c29cc25791c7026e40897cc2072b85cd257b6338ad",
       url:"https://api.github.com/repos/Xiaowu7z/RR-vps/releases/assets/532275341",
       browser_download_url:"https://github.com/Xiaowu7z/RR-vps/releases/download/rr-nexus-core-v1.13.19/rr-sing-box-1.13.19-linux-amd64.tar.gz",
       uploader:{login:"github-actions[bot]"}},
      {id:532275350,name:"rr-sing-box-1.13.19-linux-arm64.tar.gz",state:"uploaded",size:18978144,
       digest:"sha256:28c8ed10d203fa77286d0a25deb0377aa33598c08c7b3de256c7d779529716f0",
       url:"https://api.github.com/repos/Xiaowu7z/RR-vps/releases/assets/532275350",
       browser_download_url:"https://github.com/Xiaowu7z/RR-vps/releases/download/rr-nexus-core-v1.13.19/rr-sing-box-1.13.19-linux-arm64.tar.gz",
       uploader:{login:"github-actions[bot]"}},
      {id:532275351,name:"SHA256SUMS",state:"uploaded",size:210,
       digest:"sha256:81a4d7114411705ae2af7c7b5e0bbf2c316a630558d2250a757cf6654760151b",
       url:"https://api.github.com/repos/Xiaowu7z/RR-vps/releases/assets/532275351",
       browser_download_url:"https://github.com/Xiaowu7z/RR-vps/releases/download/rr-nexus-core-v1.13.19/SHA256SUMS",
       uploader:{login:"github-actions[bot]"}}
    ]
  }
')
legacy_ref_fixture=$(jq -cn '{
  ref:"refs/tags/rr-nexus-core-v1.13.19",
  url:"https://api.github.com/repos/Xiaowu7z/RR-vps/git/refs/tags/rr-nexus-core-v1.13.19",
  object:{type:"commit",sha:"ad69c42e6c6f468b6c643da06e7a461de7d773f3"}
}')
release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" '[[$legacy]]')
ref_pages_fixture='[[{"ref":"refs/tags/v7.1.0"}]]'
current_latest="$legacy_latest"
api_fail=""
api() {
    local endpoint="${*: -1}"
    [ "$endpoint" != "$api_fail" ] || return 1
    case "$endpoint" in
        */releases/latest) printf '%s\n' "$current_latest" ;;
        */git/ref/tags/rr-nexus-core-v1.13.19) printf '%s\n' "$legacy_ref_fixture" ;;
        */releases\?per_page=100) printf '%s\n' "$release_pages_fixture" ;;
        */git/matching-refs/tags/v) printf '%s\n' "$ref_pages_fixture" ;;
        *) return 1 ;;
    esac
}

assert_product_latest || fail 'exact explicit legacy Latest bootstrap was rejected'

product_latest=$(jq -cn '{
  tag_name:"v7.2.0",target_commitish:("a"*40),draft:false,
  prerelease:false,immutable:true,
  assets:["install.sh","manifest.sha256","rr-bundle.tar.gz","RELEASE_INFO","SHA256SUMS"] |
    map({name:.})
}')
current_latest="$product_latest"
BOOTSTRAP_LEGACY_LATEST=false
GITHUB_EVENT_NAME=schedule
assert_product_latest || fail 'normal immutable product Latest required bootstrap state'
current_latest="$legacy_latest"
GITHUB_EVENT_NAME=workflow_dispatch

for mutation in \
    '.id=1' \
    '.tag_name="foreign"' \
    '.target_commitish=("f"*40)' \
    '.author.login="attacker"' \
    '.immutable=true' \
    '.assets[0].id=1' \
    '.assets[0].name="foreign"' \
    '.assets[0].size=1' \
    '.assets[0].digest=("sha256:"+("9"*64))' \
    '.assets[0].state="pending"' \
    '.assets[0].uploader.login="attacker"' \
    '.assets[0].browser_download_url="https://example.invalid/asset"' \
    '.assets += [.assets[0]]'; do
    candidate=$(jq "$mutation" <<<"$legacy_latest")
    BOOTSTRAP_LEGACY_LATEST=true
    if pinned_legacy_latest_bootstrap_allowed "$candidate"; then
        fail "legacy Latest predicate accepted mutation: $mutation"
    fi
done

BOOTSTRAP_LEGACY_LATEST=false
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'default-off bootstrap flag was ignored'
fi
BOOTSTRAP_LEGACY_LATEST=true
for invalid_event in schedule push; do
    GITHUB_EVENT_NAME="$invalid_event"
    if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
        fail "non-dispatch bootstrap event was accepted: $invalid_event"
    fi
done
GITHUB_EVENT_NAME=workflow_dispatch
GITHUB_REPOSITORY=attacker/RR-vps
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'fork repository was allowed to reuse the legacy identity'
fi
GITHUB_REPOSITORY=Xiaowu7z/RR-vps
RR_NEXUS_CORE_VERSION=1.15.0
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'a future Core version inherited the one-time v7.2 bootstrap'
fi
RR_NEXUS_CORE_VERSION=1.14.0
RR_NEXUS_CORE_TAG=v1.15.0
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'a different upstream Core tag inherited the one-time bootstrap'
fi
RR_NEXUS_CORE_TAG=v1.14.0
release_tag=rr-nexus-core-v1.14.0-r2
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'a different Core release revision inherited the one-time bootstrap'
fi
release_tag=rr-nexus-core-v1.14.0-r1

legacy_ref_saved="$legacy_ref_fixture"
legacy_ref_fixture=$(jq '.object.sha=("f"*40)' <<<"$legacy_ref_saved")
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'moved legacy Core tag was accepted'
fi
legacy_ref_fixture=$(jq '.object.type="tag"' <<<"$legacy_ref_saved")
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'annotated legacy Core tag was accepted'
fi
legacy_ref_fixture="$legacy_ref_saved"

release_pages_fixture='[[]]'
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'empty release inventory was accepted'
fi
release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" \
    '[[ $legacy | .id=1 ]]')
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'release inventory missing the exact legacy release was accepted'
fi
release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" \
    '[[ $legacy, $legacy ]]')
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'duplicate exact legacy release inventory was accepted'
fi
for malformed_release in \
    '{}' \
    'null' \
    '7' \
    '{"tag_name":null}' \
    '{"tag_name":7}'; do
    release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" \
        --argjson malformed "$malformed_release" '[[ $legacy, $malformed ]]')
    if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
        fail "malformed release inventory object was accepted: $malformed_release"
    fi
done

release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" \
    '[[ $legacy, ($legacy | .id=720 | .tag_name="v7.2.0" | .draft=true) ]]')
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'v7.2 draft did not permanently close the bootstrap'
fi
release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" \
    '[[ $legacy, ($legacy | .id=730 | .tag_name="v7.3.0" | .draft=false) ]]')
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'a newer canonical product release did not close the bootstrap'
fi
release_pages_fixture=$(jq -cn --argjson legacy "$legacy_latest" '[[$legacy]]')
ref_pages_fixture='[[{"ref":"refs/tags/v7.2.0"}]]'
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'v7.2 tag-only state did not permanently close the bootstrap'
fi
ref_pages_fixture='[[{"ref":"refs/tags/v7.3.0"}]]'
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'a newer canonical product tag-only state did not close the bootstrap'
fi
ref_pages_fixture='[[]]'
if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
    fail 'empty product-tag inventory was accepted'
fi
for malformed_ref in \
    '{}' \
    'null' \
    '7' \
    '{"ref":null}' \
    '{"ref":7}'; do
    ref_pages_fixture=$(jq -cn --argjson malformed "$malformed_ref" \
        '[[ {ref:"refs/tags/v7.1.0"}, $malformed ]]')
    if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
        fail "malformed product-tag inventory object was accepted: $malformed_ref"
    fi
done
ref_pages_fixture='[[{"ref":"refs/tags/v7.1.0"}]]'

for api_fail in \
    "/repos/Xiaowu7z/RR-vps/git/ref/tags/rr-nexus-core-v1.13.19" \
    "/repos/Xiaowu7z/RR-vps/releases?per_page=100" \
    "/repos/Xiaowu7z/RR-vps/git/matching-refs/tags/v"; do
    if pinned_legacy_latest_bootstrap_allowed "$legacy_latest"; then
        fail "bootstrap admitted an API failure: $api_fail"
    fi
done
api_fail=""

printf '%s\n' '[4/6] core publication is an exact owned, resumable transaction'
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

printf '%s\n' '[5/6] exact draft/public predicates and PATCH ambiguity are executable contracts'
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

printf '%s\n' '[6/6] workflow YAML and embedded shell remain syntactically valid'
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
