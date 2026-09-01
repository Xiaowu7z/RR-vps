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

fixture_assets="$test_root/assets"
mkdir -p "$fixture_assets"
fixture_tag=v7.2.0
fixture_version=7.2.0
fixture_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fixture_tag_object=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat >"$fixture_assets/install.sh" <<'EOF'
#!/bin/bash
RR_BOOTSTRAP_VERSION="2"
RR_REPOSITORY="Xiaowu7z/RR-vps"
RR_RELEASE_TAG="v7.2.0"
:
EOF
printf '%s\n' 'fixture manifest' >"$fixture_assets/manifest.sha256"
printf '%s\n' 'fixture deterministic bundle' >"$fixture_assets/rr-bundle.tar.gz"
printf '%s\n' \
    "VERSION=$fixture_version" \
    "TAG=$fixture_tag" \
    "COMMIT=$fixture_commit" >"$fixture_assets/RELEASE_INFO"
(
    cd "$fixture_assets"
    sha256sum install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO >SHA256SUMS
)

release_json="$test_root/release.json"
asset_id=100
asset_objects=()
for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
    digest="sha256:$(sha256sum "$fixture_assets/$asset" | awk '{print $1}')"
    size=$(stat -c %s "$fixture_assets/$asset")
    asset_objects+=("$(jq -cn \
        --arg repo Xiaowu7z/RR-vps --arg tag "$fixture_tag" --arg name "$asset" \
        --arg digest "$digest" --argjson id "$asset_id" --argjson size "$size" '
        {id:$id,name:$name,size:$size,digest:$digest,state:"uploaded",
         uploader:{login:"github-actions[bot]"},
         url:("https://api.github.com/repos/"+$repo+"/releases/assets/"+($id|tostring)),
         browser_download_url:("https://github.com/"+$repo+"/releases/download/"+$tag+"/"+$name)}
    ')")
    asset_id=$((asset_id + 1))
done
owner_assets=$(printf '%s\n' "${asset_objects[@]}" | \
    jq -scS '[.[] | {name,size,digest}] | sort_by(.name)')
owner_payload_sha=$(printf '%s' "$owner_assets" | sha256sum | awk '{print $1}')
owner_payload_b64=$(printf '%s' "$owner_assets" | base64 -w 0)
owner_marker="rr-vps-release-owner:v2:${fixture_tag}:${fixture_commit}:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc:${owner_payload_sha}:${owner_payload_b64}"
printf '%s\n' "${asset_objects[@]}" | jq -sc \
    --arg tag "$fixture_tag" --arg commit "$fixture_commit" \
    --arg marker "<!-- ${owner_marker} -->" '
    {id:77,tag_name:$tag,target_commitish:$commit,draft:false,prerelease:false,
     immutable:true,author:{login:"github-actions[bot]"},
     body:("fixture release notes\n\n"+$marker+"\n"),assets:.}
' >"$release_json"

main_json="$test_root/main.json"
jq -cn --arg sha "$fixture_commit" '{object:{sha:$sha}}' >"$main_json"
runs_json="$test_root/runs.json"
jq -cn --arg sha "$fixture_commit" '{total_count:2,workflow_runs:[
    {id:4401,head_sha:$sha,head_branch:"main",event:"push",run_number:44,run_attempt:1,
     status:"completed",conclusion:"success"},
    {id:4402,head_sha:$sha,head_branch:"main",event:"push",run_number:44,run_attempt:2,
     status:"completed",conclusion:"success"}
]}' >"$runs_json"
dispatch_runs_json="$test_root/runs-dispatch.json"
jq -cn --arg sha "$fixture_commit" '{total_count:1,workflow_runs:[
    {id:4501,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",
     run_number:45,run_attempt:1,status:"completed",conclusion:"success"}
]}' >"$dispatch_runs_json"
ref_json="$test_root/ref.json"
jq -cn --arg tag "$fixture_tag" --arg sha "$fixture_tag_object" \
    '{ref:("refs/tags/"+$tag),object:{type:"tag",sha:$sha}}' >"$ref_json"
tag_json="$test_root/tag.json"
jq -cn --arg object "$fixture_tag_object" --arg tag "$fixture_tag" \
    --arg sha "$fixture_commit" --arg marker "$owner_marker" '
    {sha:$object,tag:$tag,message:$marker,object:{type:"commit",sha:$sha},
     tagger:{name:"github-actions[bot]",
       email:"41898282+github-actions[bot]@users.noreply.github.com"}}
' >"$tag_json"

RR_REPOSITORY=Xiaowu7z/RR-vps
RR_UPDATE_CHANNEL=stable
RR_TEST_RELEASE_JSON="$release_json"
RR_TEST_RUNS_JSON="$runs_json"
RR_TEST_DISPATCH_RUNS_JSON="$dispatch_runs_json"
RR_TEST_MAIN_JSON="$main_json"
RR_TEST_REF_JSON="$ref_json"
RR_TEST_TAG_JSON="$tag_json"
RR_TEST_ASSETS="$fixture_assets"

rr_update_guard_official_get() {
    local source_url="$1" target_file="$2" basename=""
    case "$source_url" in
        */releases/latest) cp "$RR_TEST_RELEASE_JSON" "$target_file" ;;
        */git/ref/heads/main) cp "$RR_TEST_MAIN_JSON" "$target_file" ;;
        */actions/workflows/*/runs\?*event=workflow_dispatch*)
            cp "$RR_TEST_DISPATCH_RUNS_JSON" "$target_file"
            ;;
        */actions/workflows/*/runs\?*event=push*) cp "$RR_TEST_RUNS_JSON" "$target_file" ;;
        */git/ref/tags/*) cp "$RR_TEST_REF_JSON" "$target_file" ;;
        */git/tags/*) cp "$RR_TEST_TAG_JSON" "$target_file" ;;
        */releases/download/*)
            basename=${source_url##*/}
            cp "$RR_TEST_ASSETS/$basename" "$target_file"
            ;;
        *) return 1 ;;
    esac
}

printf '%s\n' '[1/4] exact immutable release, bytes, tag, main and latest attempts pass'
verified="$test_root/verified"
mkdir "$verified"
rr_update_guard_prepare_stable_release "$verified" || fail 'valid stable release was rejected'
for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
    cmp -s "$fixture_assets/$asset" "$verified/$asset" || fail "verified asset differs: $asset"
done

printf '%s\n' '[2/4] a newer failed rerun overrides an earlier successful attempt'
jq '(.workflow_runs[1].conclusion) = "failure"' "$runs_json" >"$test_root/runs-failed.json"
RR_TEST_RUNS_JSON="$test_root/runs-failed.json"
rejected="$test_root/rejected-attempt"
mkdir "$rejected"
if rr_update_guard_prepare_stable_release "$rejected"; then
    fail 'latest failed workflow attempt was accepted'
fi
RR_TEST_RUNS_JSON="$runs_json"

printf '%s\n' '[3/4] metadata, provenance and asset mutations fail closed'
expect_metadata_reject() {
    local filter="$1" label="$2" candidate="$test_root/candidate.json"
    jq "$filter" "$release_json" >"$candidate"
    if rr_update_guard_parse_release "$candidate"; then
        fail "release metadata mutation accepted: $label"
    fi
}
expect_metadata_reject '.draft = true' draft
expect_metadata_reject '.immutable = false' mutable
expect_metadata_reject '.tag_name = "v07.2.0"' noncanonical-semver
expect_metadata_reject '.assets[0].browser_download_url = "https://example.invalid/install.sh"' foreign-url
expect_metadata_reject '.assets += [.assets[0]]' duplicate-asset
expect_metadata_reject '.author.login = "attacker"' foreign-author
expect_metadata_reject '.assets[0].uploader.login = "attacker"' foreign-uploader

expect_prepare_reject() {
    local release_fixture="$1" tag_fixture="$2" label="$3"
    local output="$test_root/rejected-${label}"
    RR_TEST_RELEASE_JSON="$release_fixture"
    RR_TEST_TAG_JSON="$tag_fixture"
    mkdir "$output"
    if rr_update_guard_prepare_stable_release "$output"; then
        fail "stable ownership mutation accepted: $label"
    fi
    RR_TEST_RELEASE_JSON="$release_json"
    RR_TEST_TAG_JSON="$tag_json"
}

jq '.body = "foreign body without owner marker"' \
    "$release_json" >"$test_root/release-foreign-body.json"
expect_prepare_reject "$test_root/release-foreign-body.json" "$tag_json" foreign-body
jq --arg marker "<!-- ${owner_marker} -->" '.body += $marker' \
    "$release_json" >"$test_root/release-duplicate-marker.json"
expect_prepare_reject "$test_root/release-duplicate-marker.json" "$tag_json" duplicate-marker
jq '.message = "owned"' "$tag_json" >"$test_root/tag-arbitrary-message.json"
expect_prepare_reject "$release_json" "$test_root/tag-arbitrary-message.json" arbitrary-tag-message

zero_hash=$(printf '%064d' 0)
bad_hash_marker=${owner_marker/:${owner_payload_sha}:/:${zero_hash}:}
jq --arg marker "$bad_hash_marker" '.message = $marker' \
    "$tag_json" >"$test_root/tag-bad-payload-hash.json"
jq --arg old "<!-- ${owner_marker} -->" --arg new "<!-- ${bad_hash_marker} -->" \
    '.body |= (split($old) | join($new))' \
    "$release_json" >"$test_root/release-bad-payload-hash.json"
expect_prepare_reject \
    "$test_root/release-bad-payload-hash.json" \
    "$test_root/tag-bad-payload-hash.json" bad-payload-hash

noncanonical_payload=$(jq '.' <<<"$owner_assets")
noncanonical_sha=$(printf '%s' "$noncanonical_payload" | sha256sum | awk '{print $1}')
noncanonical_b64=$(printf '%s' "$noncanonical_payload" | base64 -w 0)
noncanonical_marker="rr-vps-release-owner:v2:${fixture_tag}:${fixture_commit}:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd:${noncanonical_sha}:${noncanonical_b64}"
jq --arg marker "$noncanonical_marker" '.message = $marker' \
    "$tag_json" >"$test_root/tag-noncanonical-payload.json"
jq --arg old "<!-- ${owner_marker} -->" \
    --arg new "<!-- ${noncanonical_marker} -->" \
    '.body |= (split($old) | join($new))' \
    "$release_json" >"$test_root/release-noncanonical-payload.json"
expect_prepare_reject \
    "$test_root/release-noncanonical-payload.json" \
    "$test_root/tag-noncanonical-payload.json" noncanonical-payload

jq '.assets[0].digest = ("sha256:" + ("0" * 64))' \
    "$release_json" >"$test_root/release-false-digest.json"
RR_TEST_RELEASE_JSON="$test_root/release-false-digest.json"
bad_digest_dir="$test_root/rejected-digest"
mkdir "$bad_digest_dir"
if rr_update_guard_prepare_stable_release "$bad_digest_dir"; then
    fail 'API digest differing from downloaded bytes was accepted'
fi
RR_TEST_RELEASE_JSON="$release_json"

bad_info="$test_root/assets-bad-info"
cp -a "$fixture_assets" "$bad_info"
sed 's/^COMMIT=.*/COMMIT=cccccccccccccccccccccccccccccccccccccccc/' \
    "$bad_info/RELEASE_INFO" >"$bad_info/RELEASE_INFO.next"
mv "$bad_info/RELEASE_INFO.next" "$bad_info/RELEASE_INFO"
RR_TEST_ASSETS="$bad_info"
bad_asset_dir="$test_root/rejected-info"
mkdir "$bad_asset_dir"
if rr_update_guard_prepare_stable_release "$bad_asset_dir"; then
    fail 'RELEASE_INFO/asset digest mismatch was accepted'
fi
RR_TEST_ASSETS="$fixture_assets"

printf '%s\n' '[4/4] stable runtime delegates to release trust while beta remains branch-based'
python3 - <<'PY'
from __future__ import annotations

import pathlib

source = pathlib.Path("modules/60-update.sh").read_text()
start = source.index("rr_bundle_manifest_matches_trusted_source() {")
end = source.index("# H16/T12", start)
trust = source[start:end]
if trust.count("rr_update_guard_copy_verified_asset") < 2:
    raise SystemExit("stable module paths do not delegate manifest/bootstrap trust")
if trust.count('[ "${RR_UPDATE_CHANNEL:-stable}" != beta'):
    raise SystemExit("unexpected channel expression")
if trust.count('[ "${RR_UPDATE_CHANNEL:-stable}" != stable ]') < 2:
    raise SystemExit("beta branch fallback was removed")

guard = pathlib.Path("scripts/update-guard.sh").read_text()
for fragment in (
    'rr_update_guard_copy_verified_asset manifest.sha256 "$remote_manifest"',
    'rr_update_guard_copy_verified_asset install.sh "$target_file"',
    'sort_by([.run_number, .run_attempt]) | last',
    'vps-audit.yml push "$initial_commit"',
    'vps-audit.yml workflow_dispatch "$initial_commit"',
    'rr_update_guard_assert_owned_tag "$initial_tag" "$initial_commit"',
):
    if fragment not in guard:
        raise SystemExit(f"missing stable trust contract: {fragment}")
PY

printf '%s\n' 'stable updater release trust regressions: PASS'
