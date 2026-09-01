#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-release-publication-races.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'release publication race regression: FAIL: %s\n' "$*" >&2
    exit 1
}

python3 - "$REPO_ROOT/.github/workflows/release.yml" "$TEST_ROOT/functions.sh" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = lines.index("          resolve_remote_tag_sha() {")
end = next(
    index for index in range(start, len(lines))
    if lines[index] == "          expected_assets=$("
)
Path(sys.argv[2]).write_text(
    "\n".join(line[10:] for line in lines[start:end]) + "\n",
    encoding="utf-8",
)
PY

# shellcheck source=/dev/null
source "$TEST_ROOT/functions.sh"

# This fixture isolates publication-state races after release evidence has
# already passed. The real three-event gate and its failure cases are covered
# by test-release-evidence-events.sh and test-stable-update-trust.sh.
assert_release_gate() { :; }

EXPECTED_SHA=0123456789abcdef0123456789abcdef01234567
TAG=v7.2.0
VERSION=7.2.0
GITHUB_REPOSITORY=example/rr-vps
GH_TOKEN=test-token
RELEASE_TITLE="RR-vps ${VERSION} 正式版"
ASSET_ROOT="$TEST_ROOT/assets"
STATE_ROOT="$TEST_ROOT/state"
API_LOG="$TEST_ROOT/api.log"
GIT_LOG="$TEST_ROOT/git.log"
UPLOAD_LOG="$TEST_ROOT/upload.log"
mkdir -p "$ASSET_ROOT" "$STATE_ROOT"
RELEASE_NOTES_FILE="$ASSET_ROOT/release-notes.md"
printf 'professional notes\n' > "$RELEASE_NOTES_FILE"
printf 'installer\n' > "$ASSET_ROOT/install.sh"
printf 'manifest\n' > "$ASSET_ROOT/manifest.sha256"
printf 'bundle payload\n' > "$ASSET_ROOT/rr-bundle.tar.gz"
printf 'VERSION=7.2.0\nTAG=v7.2.0\nCOMMIT=%s\n' "$EXPECTED_SHA" \
    > "$ASSET_ROOT/RELEASE_INFO"
(
    cd "$ASSET_ROOT"
    sha256sum install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO > SHA256SUMS
)

expected_assets=$(
    for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
        digest="sha256:$(sha256sum "$ASSET_ROOT/$asset" | awk '{print $1}')"
        size=$(stat -c %s "$ASSET_ROOT/$asset")
        jq -cn --arg name "$asset" --arg digest "$digest" --argjson size "$size" \
            '{name:$name,size:$size,digest:$digest}'
    done | jq -scS 'sort_by(.name)'
)

owner_marker_for() {
    local nonce="$1" payload_sha payload_b64
    payload_sha=$(printf '%s' "$expected_assets" | sha256sum | awk '{print $1}')
    payload_b64=$(printf '%s' "$expected_assets" | base64 -w 0)
    printf 'rr-vps-release-owner:v2:%s:%s:%s:%s:%s\n' \
        "$TAG" "$EXPECTED_SHA" "$nonce" "$payload_sha" "$payload_b64"
}

TAG_X=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TAG_Y=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OWNER_X=$(owner_marker_for cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
OWNER_Y=$(owner_marker_for dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd)

write_tag_state() {
    local object_sha="$1" marker="$2"
    jq -n --arg ref "refs/tags/${TAG}" --arg sha "$object_sha" \
        '{ref:$ref,object:{type:"tag",sha:$sha}}' > "$STATE_ROOT/ref.json"
    jq -n --arg sha "$object_sha" --arg tag "$TAG" --arg marker "$marker" \
        --arg commit "$EXPECTED_SHA" '
        {sha:$sha,tag:$tag,message:$marker,object:{type:"commit",sha:$commit},
         tagger:{name:"github-actions[bot]",
                 email:"41898282+github-actions[bot]@users.noreply.github.com"}}
    ' > "$STATE_ROOT/tag-${object_sha}.json"
}

write_release_state() {
    local draft="$1" immutable="$2" marker="$3"
    local assets_file="$TEST_ROOT/full-assets.json"
    : > "$assets_file"
    local id=100 asset size digest
    for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
        id=$((id + 1))
        size=$(stat -c %s "$ASSET_ROOT/$asset")
        digest="sha256:$(sha256sum "$ASSET_ROOT/$asset" | awk '{print $1}')"
        jq -cn --arg repo "$GITHUB_REPOSITORY" --arg tag "$TAG" \
            --arg name "$asset" --arg digest "$digest" --argjson size "$size" \
            --argjson id "$id" '
            {id:$id,
             url:("https://api.github.com/repos/" + $repo + "/releases/assets/" + ($id|tostring)),
             browser_download_url:("https://github.com/" + $repo + "/releases/download/" + $tag + "/" + $name),
             name:$name,size:$size,digest:$digest,state:"uploaded",
             uploader:{login:"github-actions[bot]"}}
        ' >> "$assets_file"
    done
    jq -s --rawfile notes "$RELEASE_NOTES_FILE" --arg tag "$TAG" \
        --arg sha "$EXPECTED_SHA" --arg title "$RELEASE_TITLE" \
        --arg repo "$GITHUB_REPOSITORY" \
        --arg marker "<!-- ${marker} -->" --argjson draft "$draft" \
        --argjson immutable "$immutable" '
        {id:17,tag_name:$tag,target_commitish:$sha,name:$title,draft:$draft,
         prerelease:false,immutable:$immutable,author:{login:"github-actions[bot]"},
         upload_url:("https://uploads.github.com/repos/" + $repo +
           "/releases/17/assets{?name,label}"),
         body:($notes + "\n" + $marker + "\n"),assets:.}
    ' "$assets_file" > "$STATE_ROOT/release.json"
}

keep_release_assets() {
    local names_json="$1"
    jq --argjson names "$names_json" '
        .assets |= map(select(.name as $name | $names | index($name)))
    ' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
}

sleep() { :; }

gh() {
    [ "${1:-}" = auth ] && [ "${2:-}" = setup-git ]
}

curl() {
    local input="" endpoint="" argument="" asset="" draft_id=""
    while [ "$#" -gt 0 ]; do
        argument="$1"
        case "$argument" in
            --data-binary) input="$2"; shift 2 ;;
            https://uploads.github.com/*) endpoint="$argument"; shift ;;
            *) shift ;;
        esac
    done
    [[ "$endpoint" =~ /releases/([1-9][0-9]*)/assets\?name=([A-Za-z0-9._-]+)$ ]] ||
        return 1
    draft_id=${BASH_REMATCH[1]}
    asset=${BASH_REMATCH[2]}
    [ "$draft_id" = 17 ] && [ "$input" = "@${asset}" ] && [ -f "$asset" ] || return 1
    if jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' \
        "$STATE_ROOT/release.json" >/dev/null; then
        return 1
    fi
    jq -s --arg name "$asset" '[.[] | select(.name == $name)] | .[0]' \
        "$TEST_ROOT/full-assets.json" > "$STATE_ROOT/upload-asset.json"
    jq --slurpfile uploaded "$STATE_ROOT/upload-asset.json" \
        '.assets += $uploaded' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
    printf '%s %s\n' "$draft_id" "$asset" >> "$UPLOAD_LOG"
    if [ -e "$STATE_ROOT/lose-upload-response" ]; then
        command rm -f -- "$STATE_ROOT/lose-upload-response"
        return 1
    fi
    return 0
}

git() {
    printf '%q ' "$@" >> "$GIT_LOG"
    printf '\n' >> "$GIT_LOG"
    case "${1:-}" in
        push)
            [[ " $* " == *" --force-with-lease=refs/tags/${TAG}:${TAG_X} "* ]] ||
                fail 'tag cleanup did not use the exact annotated-object lease'
            [[ " $* " == *" :refs/tags/${TAG} "* ]] ||
                fail 'tag cleanup did not request only the exact tag deletion'
            write_tag_state "$TAG_Y" "$OWNER_Y"
            return 1
            ;;
        ls-remote)
            printf '%s\trefs/tags/%s\n' "$TAG_X" "$TAG"
            printf '%s\trefs/tags/%s^{}\n' "$EXPECTED_SHA" "$TAG"
            ;;
        *) return 1 ;;
    esac
}

api() {
    local method=GET endpoint="" accept="" argument=""
    while [ "$#" -gt 0 ]; do
        argument="$1"
        case "$argument" in
            --method) method="$2"; shift 2 ;;
            -H) accept="$2"; shift 2 ;;
            /repos/*) endpoint="$argument"; shift ;;
            *) shift ;;
        esac
    done
    printf '%s %s %s\n' "$method" "$accept" "$endpoint" >> "$API_LOG"
    case "$method:$endpoint" in
        GET:*/releases\?per_page=100)
            if [ -e "$STATE_ROOT/lag-release-inventory" ]; then
                printf '[[]]\n'
            elif [ -f "$STATE_ROOT/release.json" ]; then
                jq -cs '[.]' "$STATE_ROOT/release.json"
            else
                printf '[[]]\n'
            fi
            ;;
        GET:*/git/matching-refs/tags/*)
            if [ -f "$STATE_ROOT/ref.json" ]; then
                jq -cs '[.]' "$STATE_ROOT/ref.json"
            else
                printf '[[]]\n'
            fi
            ;;
        GET:*/git/tags/*)
            object_sha=$(jq -r '.object.sha' "$STATE_ROOT/ref.json")
            cat "$STATE_ROOT/tag-${object_sha}.json"
            ;;
        GET:*/releases/17)
            cat "$STATE_ROOT/release.json"
            ;;
        GET:*/releases/assets/*)
            [ "$accept" = 'Accept: application/octet-stream' ] || return 1
            asset_id=${endpoint##*/}
            asset_name=$(jq -r --argjson id "$asset_id" \
                '.assets[] | select(.id == $id) | .name' "$STATE_ROOT/release.json")
            [ -n "$asset_name" ] || return 1
            cat "$ASSET_ROOT/$asset_name"
            printf '%s\n' "$asset_id" >> "$STATE_ROOT/downloaded-ids"
            if [ "$(wc -l < "$STATE_ROOT/downloaded-ids")" -eq 5 ]; then
                : > "$STATE_ROOT/downloads-complete"
            fi
            ;;
        GET:*/releases/latest)
            if [ -e "$STATE_ROOT/downloads-complete" ]; then
                jq '.tag_name="v999.0.0"' "$STATE_ROOT/release.json"
            else
                cat "$STATE_ROOT/release.json"
            fi
            ;;
        PATCH:*/releases/17)
            if [ -e "$STATE_ROOT/patch-succeeds" ]; then
                jq '.draft=false | .immutable=true' "$STATE_ROOT/release.json" \
                    > "$STATE_ROOT/release.next"
                command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
            fi
            ;;
        *)
            printf 'unexpected mocked API call: %s %s\n' "$method" "$endpoint" >&2
            return 1
            ;;
    esac
}

printf '%s\n' '[1/6] static workflow contract forbids unsafe release/tag/download mutations'
python3 - "$REPO_ROOT/.github/workflows/release.yml" <<'PY'
from pathlib import Path
import subprocess
import sys
import yaml

path = Path(sys.argv[1])
workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
publish = next(
    step["run"] for step in workflow["jobs"]["publish"]["steps"]
    if step.get("name") == "Publish a new immutable versioned release"
)
required = (
    '--force-with-lease="refs/tags/${TAG}:${expected_object_sha}"',
    'is_canonical_owned_partial_draft()',
    'complete_owned_draft_assets()',
    'https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${draft_id}/assets?name=${asset}',
    'exact_owned_draft_current',
    '/releases/assets/${asset_id}',
    'assert_latest_product "$release_id" "$owner_marker"',
    'draft_creation_attempted=true',
    'if [ "${draft_creation_attempted:-false}" = true ]',
)
for fragment in required:
    if fragment not in publish:
        raise SystemExit(f"missing publication race contract: {fragment}")
for forbidden in (
    'api --method DELETE "/repos/${GITHUB_REPOSITORY}/releases/',
    'api --method DELETE "/repos/${GITHUB_REPOSITORY}/git/refs/tags/',
    'releases/latest/download',
    'gh release create "$TAG"',
    '--clobber',
):
    if forbidden in publish:
        raise SystemExit(f"unsafe publication operation remains: {forbidden}")
if "bash scripts/" in publish or "python3 scripts/" in publish:
    raise SystemExit("contents:write job executes a candidate repository script")
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

printf '%s\n' '[2/6] X-to-foreign-Y ref race cannot delete Y'
: > "$API_LOG"
: > "$GIT_LOG"
command rm -f -- "$STATE_ROOT/release.json"
write_tag_state "$TAG_X" "$OWNER_X"
if delete_owned_target_tag "$TAG_X" "$OWNER_X" >/dev/null 2>&1; then
    fail 'CAS cleanup reported success after a foreign ref replacement'
fi
[ "$(jq -r '.object.sha' "$STATE_ROOT/ref.json")" = "$TAG_Y" ] ||
    fail 'foreign replacement tag Y was deleted or changed'
[ "$(grep -c '^push ' "$GIT_LOG")" -eq 1 ] ||
    fail 'ambiguous CAS cleanup retried the destructive push'
if grep -Eq '^DELETE ' "$API_LOG"; then
    fail 'tag cleanup fell back to an unconditional REST DELETE'
fi

printf '%s\n' '[3/6] a 1/5 draft resumes by exact ID through a lost upload response'
: > "$API_LOG"
: > "$UPLOAD_LOG"
command rm -f -- "$STATE_ROOT/patch-succeeds" "$STATE_ROOT/downloads-complete" \
    "$STATE_ROOT/downloaded-ids"
write_tag_state "$TAG_X" "$OWNER_X"
write_release_state true false "$OWNER_X"
keep_release_assets '["install.sh"]'
classify_target_release_state
[ "$TARGET_RELEASE_STATE" = exact_owned_partial_draft_current ] &&
    [ "$TARGET_RELEASE_ID" = 17 ] || fail 'canonical 1/5 draft was not re-adopted'
RUN_TAG_OBJECT_SHA="$TAG_X"
RUN_OWNER_MARKER="$OWNER_X"
: > "$STATE_ROOT/lose-upload-response"
(
    cd "$ASSET_ROOT"
    complete_owned_draft_assets 17 "$OWNER_X"
) || fail 'partial draft did not converge after a lost upload response'
[ "$(jq -r '.id' "$STATE_ROOT/release.json")" = 17 ] ||
    fail 'partial recovery changed the exact release ID'
is_exact_mutable_draft "$(cat "$STATE_ROOT/release.json")" "$OWNER_X" \
    "$EXPECTED_SHA" "$expected_assets" || fail 'partial recovery did not produce the exact payload'
[ "$(wc -l < "$UPLOAD_LOG")" -eq 4 ] ||
    fail 'partial recovery did not upload exactly the four missing slots'
: > "$STATE_ROOT/patch-succeeds"
publish_draft_and_confirm 17 "$OWNER_X" || fail 'completed partial draft was not published'
[ "$(jq -r '.draft' "$STATE_ROOT/release.json")" = false ] ||
    fail 'completed partial draft did not become public'
if grep -Eq '(^| )(DELETE|--clobber)( |$)' "$API_LOG" "$UPLOAD_LOG"; then
    fail 'partial recovery deleted or overwrote an uncertain slot'
fi

printf '%s\n' '[4/6] failed publication is re-adopted by exact draft ID on the next run'
: > "$API_LOG"
command rm -f -- "$STATE_ROOT/patch-succeeds" "$STATE_ROOT/downloads-complete" \
    "$STATE_ROOT/downloaded-ids"
write_tag_state "$TAG_X" "$OWNER_X"
write_release_state true false "$OWNER_X"
classify_target_release_state
[ "$TARGET_RELEASE_STATE" = exact_owned_draft_current ] &&
    [ "$TARGET_RELEASE_ID" = 17 ] || fail 'exact owned draft was not re-adopted'
if publish_draft_and_confirm 17 "$OWNER_X" >/dev/null 2>&1; then
    fail 'unchanged draft was reported as successfully published'
fi
[ "$(jq -r '.draft' "$STATE_ROOT/release.json")" = true ] ||
    fail 'failed publication did not preserve the draft'
classify_target_release_state
[ "$TARGET_RELEASE_STATE" = exact_owned_draft_current ] &&
    [ "$TARGET_RELEASE_ID" = 17 ] || fail 'next run did not re-adopt the same exact draft ID'
: > "$STATE_ROOT/patch-succeeds"
publish_draft_and_confirm 17 "$OWNER_X" || fail 're-adopted exact draft did not resume publication'
[ "$(jq -r '.draft' "$STATE_ROOT/release.json")" = false ] ||
    fail 'resumed publication did not make the exact draft public'
if grep -Eq '^DELETE ' "$API_LOG"; then
    fail 'draft retry performed an unconditional deletion'
fi

printf '%s\n' '[5/6] lost draft response plus lagging inventory preserves the adoptable tag'
: > "$API_LOG"
: > "$GIT_LOG"
write_tag_state "$TAG_X" "$OWNER_X"
write_release_state true false "$OWNER_X"
keep_release_assets '[]'
: > "$STATE_ROOT/lag-release-inventory"
cleanup_armed=true
draft_creation_attempted=true
RUN_TAG_OBJECT_SHA="$TAG_X"
RUN_OWNER_MARKER="$OWNER_X"
if (set +e; false; release_cleanup_on_exit) >/dev/null 2>&1; then
    fail 'cleanup changed a failing publication into success'
fi
[ "$(jq -r '.object.sha' "$STATE_ROOT/ref.json")" = "$TAG_X" ] ||
    fail 'cleanup deleted the exact owned tag after an ambiguous draft POST'
[ -f "$STATE_ROOT/release.json" ] ||
    fail 'cleanup deleted the delayed draft after an ambiguous POST'
if grep -Eq '^push ' "$GIT_LOG"; then
    fail 'cleanup attempted CAS tag deletion after draft creation was attempted'
fi
command rm -f -- "$STATE_ROOT/lag-release-inventory"
classify_target_release_state
[ "$TARGET_RELEASE_STATE" = exact_owned_partial_draft_current ] ||
    fail 'delayed draft was not adoptable by exact tag and owner marker'

printf '%s\n' '[6/6] post-download Latest switch fails final publication verification'
: > "$API_LOG"
command rm -f -- "$STATE_ROOT/downloads-complete" "$STATE_ROOT/downloaded-ids"
write_release_state false true "$OWNER_X"
RUN_TAG_OBJECT_SHA="$TAG_X"
RUN_OWNER_MARKER="$OWNER_X"
(
    cd "$ASSET_ROOT"
    if verify_published_release 17 "$OWNER_X" >/dev/null 2>&1; then
        fail 'final verification accepted a concurrent Latest switch'
    fi
)
[ -e "$STATE_ROOT/downloads-complete" ] ||
    fail 'fixture did not download all five assets by exact asset ID'
[ "$(sort -u "$STATE_ROOT/downloaded-ids" | wc -l)" -eq 5 ] ||
    fail 'not every release asset ID was downloaded exactly'
if grep -Fq 'releases/latest/download' "$API_LOG"; then
    fail 'verification used the mutable latest/download route'
fi
grep -Fq "GET  /repos/${GITHUB_REPOSITORY}/releases/latest" "$API_LOG" ||
    fail 'Latest was not revalidated after the asset downloads'

printf '%s\n' 'release publication race regression: PASS'
