#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-release-reconcile.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'release reconciliation regression: FAIL: %s\n' "$*" >&2
    exit 1
}

python3 - "$REPO_ROOT/.github/workflows/release.yml" "$TEST_ROOT/functions.sh" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = lines.index("          resolve_remote_tag_sha() {")
end = lines.index("          expected_assets=$(", start)
Path(sys.argv[2]).write_text(
    "\n".join(line[10:] for line in lines[start:end]) + "\n",
    encoding="utf-8",
)
PY

# shellcheck source=/dev/null
source "$TEST_ROOT/functions.sh"

EXPECTED_SHA=0123456789abcdef0123456789abcdef01234567
OLD_SHA=1123456789abcdef0123456789abcdef01234567
TAG=v7.1.1
VERSION=7.1.1
GITHUB_REPOSITORY=example/rr-vps
RELEASE_TITLE='RR-vps 7.1.1 正式版'
ASSET_ROOT="$TEST_ROOT/assets"
mkdir -p "$ASSET_ROOT"
RELEASE_NOTES_FILE="$ASSET_ROOT/release-notes.md"
printf 'notes\n' > "$RELEASE_NOTES_FILE"
printf 'abc' > "$ASSET_ROOT/install.sh"
printf 'data' > "$ASSET_ROOT/manifest.sha256"
printf '12345' > "$ASSET_ROOT/rr-bundle.tar.gz"
printf 'info!!' > "$ASSET_ROOT/RELEASE_INFO"
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
old_expected_assets=$(jq -cnS '[
  {name:"install.sh",size:13,digest:("sha256:" + ("1" * 64))},
  {name:"manifest.sha256",size:14,digest:("sha256:" + ("2" * 64))},
  {name:"rr-bundle.tar.gz",size:15,digest:("sha256:" + ("3" * 64))},
  {name:"RELEASE_INFO",size:16,digest:("sha256:" + ("4" * 64))},
  {name:"SHA256SUMS",size:17,digest:("sha256:" + ("5" * 64))}
] | sort_by(.name)')
TAG_OBJECT_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
owner_marker_for() {
    local commit="$1" assets="$2" nonce="$3" payload_sha="" payload_b64=""
    payload_sha=$(printf '%s' "$assets" | sha256sum | awk '{print $1}')
    payload_b64=$(printf '%s' "$assets" | base64 -w 0)
    printf 'rr-vps-release-owner:v2:%s:%s:%s:%s:%s\n' \
        "$TAG" "$commit" "$nonce" "$payload_sha" "$payload_b64"
}
OWNER_MARKER=$(owner_marker_for "$EXPECTED_SHA" "$expected_assets" "$NONCE")
OLD_OWNER_MARKER=$(owner_marker_for "$OLD_SHA" "$old_expected_assets" "$NONCE")
FOREIGN_TAG_OBJECT_SHA=cccccccccccccccccccccccccccccccccccccccc
FOREIGN_OWNER_MARKER=$(owner_marker_for "$EXPECTED_SHA" "$expected_assets" \
    dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd)
OTHER_OWNER_MARKER=$(owner_marker_for "$EXPECTED_SHA" "$expected_assets" \
    cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
STATE_ROOT="$TEST_ROOT/state"
API_LOG="$TEST_ROOT/api.log"

sleep() { :; }

api() {
    local method=GET endpoint="" argument="" include=false
    while [ "$#" -gt 0 ]; do
        argument="$1"
        case "$argument" in
            --method)
                method="$2"
                shift 2
                ;;
            --include)
                include=true
                shift
                ;;
            /repos/*)
                endpoint="$argument"
                shift
                ;;
            *) shift ;;
        esac
    done
    printf '%s %s\n' "$method" "$endpoint" >> "$API_LOG"
    case "$method:$endpoint" in
        GET:*/releases\?per_page=100)
            [ ! -e "$STATE_ROOT/fail-release-inventory" ] || return 1
            if [ -e "$STATE_ROOT/invalid-release-inventory" ]; then
                printf '{invalid json\n'
                return 0
            fi
            if [ -f "$STATE_ROOT/release.json" ] && [ -f "$STATE_ROOT/release2.json" ]; then
                jq -cs '[.]' "$STATE_ROOT/release.json" "$STATE_ROOT/release2.json"
            elif [ -f "$STATE_ROOT/release.json" ]; then
                jq -cs '[.]' "$STATE_ROOT/release.json"
            else
                printf '[[]]\n'
            fi
            ;;
        GET:*/git/matching-refs/tags/*)
            [ ! -e "$STATE_ROOT/fail-ref-inventory" ] || return 1
            if [ -f "$STATE_ROOT/ref.json" ]; then
                jq -cs '[.]' "$STATE_ROOT/ref.json"
            else
                printf '[[]]\n'
            fi
            ;;
        GET:*/git/tags/*)
            [ ! -e "$STATE_ROOT/fail-tag-read" ] || return 1
            cat "$STATE_ROOT/tag.json"
            ;;
        GET:*/git/ref/tags/*)
            if [ -f "$STATE_ROOT/ref.json" ]; then
                cat "$STATE_ROOT/ref.json"
            else
                [ "$include" = true ] && printf 'HTTP/2 404 Not Found\n'
                return 1
            fi
            ;;
        GET:*/releases/latest)
            [ -f "$STATE_ROOT/release.json" ] || return 1
            cat "$STATE_ROOT/release.json"
            ;;
        GET:*/releases/[0-9]*)
            [ ! -e "$STATE_ROOT/fail-release-read" ] || return 1
            if [ -f "$STATE_ROOT/release.json" ]; then
                cat "$STATE_ROOT/release.json"
            else
                [ "$include" = true ] && printf 'HTTP/2 404 Not Found\n'
                return 1
            fi
            ;;
        DELETE:*/releases/[0-9]*)
            if [ ! -e "$STATE_ROOT/delete-release-stuck" ]; then
                command rm -f -- "$STATE_ROOT/release.json"
            fi
            [ ! -e "$STATE_ROOT/delete-release-response-loss" ]
            ;;
        DELETE:*/git/refs/tags/*)
            if [ ! -e "$STATE_ROOT/delete-tag-stuck" ]; then
                command rm -f -- "$STATE_ROOT/ref.json"
            fi
            [ ! -e "$STATE_ROOT/delete-tag-response-loss" ]
            ;;
        PATCH:*/releases/[0-9]*)
            if [ -e "$STATE_ROOT/patch-public" ]; then
                jq '.draft = false' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
                command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
            elif [ -e "$STATE_ROOT/patch-public-mismatch" ]; then
                jq '.draft = false | .name = "foreign title"' "$STATE_ROOT/release.json" \
                    > "$STATE_ROOT/release.next"
                command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
            fi
            if [ -e "$STATE_ROOT/patch-swap-tag" ]; then
                jq --arg sha "$FOREIGN_TAG_OBJECT_SHA" '.object.sha=$sha' \
                    "$STATE_ROOT/ref.json" > "$STATE_ROOT/ref.next"
                command mv "$STATE_ROOT/ref.next" "$STATE_ROOT/ref.json"
                jq --arg sha "$FOREIGN_TAG_OBJECT_SHA" --arg marker "$FOREIGN_OWNER_MARKER" \
                    '.sha=$sha | .message=$marker' "$STATE_ROOT/tag.json" \
                    > "$STATE_ROOT/tag.next"
                command mv "$STATE_ROOT/tag.next" "$STATE_ROOT/tag.json"
            fi
            [ ! -e "$STATE_ROOT/patch-response-loss" ]
            ;;
        *)
            printf 'Unexpected mocked API call: %s %s\n' "$method" "$endpoint" >&2
            return 1
            ;;
    esac
}

reset_owned_state() {
    command rm -rf -- "$STATE_ROOT"
    mkdir -p "$STATE_ROOT"
    : > "$API_LOG"
    jq -n --arg ref "refs/tags/${TAG}" --arg sha "$TAG_OBJECT_SHA" \
        '{ref:$ref,object:{type:"tag",sha:$sha}}' > "$STATE_ROOT/ref.json"
    jq -n --arg sha "$TAG_OBJECT_SHA" --arg tag "$TAG" --arg marker "$OWNER_MARKER" \
        --arg commit "$EXPECTED_SHA" '
        {sha:$sha,tag:$tag,message:$marker,object:{type:"commit",sha:$commit},
         tagger:{name:"github-actions[bot]",
                 email:"41898282+github-actions[bot]@users.noreply.github.com"}}
    ' > "$STATE_ROOT/tag.json"
    jq -n --rawfile notes "$RELEASE_NOTES_FILE" \
        --arg tag "$TAG" --arg sha "$EXPECTED_SHA" --arg title "$RELEASE_TITLE" \
        --arg marker "<!-- ${OWNER_MARKER} -->" --argjson assets "$expected_assets" '
        {id:17,tag_name:$tag,target_commitish:$sha,name:$title,draft:true,
         prerelease:false,immutable:false,author:{login:"github-actions[bot]"},
         body:($notes + "\n" + $marker + "\n"),
         assets:($assets | map(. + {state:"uploaded"}))}
    ' > "$STATE_ROOT/release.json"
    LOADED_TAG_STATE=unknown
    LOADED_TAG_OBJECT_SHA=""
    LOADED_TAG_OWNER_MARKER=""
    LOADED_TAG_OWNER_COMMIT=""
    LOADED_TAG_EXPECTED_ASSETS=""
}

reset_old_owned_state() {
    reset_owned_state
    jq --arg marker "$OLD_OWNER_MARKER" --arg commit "$OLD_SHA" \
        '.message=$marker | .object.sha=$commit' "$STATE_ROOT/tag.json" \
        > "$STATE_ROOT/tag.next"
    command mv "$STATE_ROOT/tag.next" "$STATE_ROOT/tag.json"
    jq --rawfile notes "$RELEASE_NOTES_FILE" \
        --arg marker "<!-- ${OLD_OWNER_MARKER} -->" --arg commit "$OLD_SHA" \
        --argjson assets "$old_expected_assets" \
        '.target_commitish=$commit | .body=($notes + "\n" + $marker + "\n") |
         .assets=($assets | map(. + {state:"uploaded"}))' \
        "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
}

assert_no_delete() {
    if grep -Eq '^DELETE ' "$API_LOG"; then
        fail "$1 performed a destructive API request"
    fi
}

set_owned_contract() {
    local commit="$1" marker="$2" assets="$3"
    jq --arg marker "$marker" --arg commit "$commit" \
        '.message=$marker | .object.sha=$commit' "$STATE_ROOT/tag.json" \
        > "$STATE_ROOT/tag.next"
    command mv "$STATE_ROOT/tag.next" "$STATE_ROOT/tag.json"
    jq --rawfile notes "$RELEASE_NOTES_FILE" \
        --arg marker "<!-- ${marker} -->" --arg commit "$commit" \
        --argjson assets "$assets" \
        '.target_commitish=$commit | .body=($notes + "\n" + $marker + "\n") |
         .assets=($assets | map(. + {state:"uploaded"}))' \
        "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
}

printf '%s\n' '[1/14] an exact owned draft is removed before its annotated tag'
reset_owned_state
reconcile_owned_mutable_target
[ ! -e "$STATE_ROOT/release.json" ] && [ ! -e "$STATE_ROOT/ref.json" ] ||
    fail 'owned orphan state was not fully reconciled'
release_delete=$(grep -n '^DELETE .*/releases/17$' "$API_LOG" | cut -d: -f1)
tag_delete=$(grep -n '^DELETE .*/git/refs/tags/v7.1.1$' "$API_LOG" | cut -d: -f1)
[[ "$release_delete" =~ ^[0-9]+$ && "$tag_delete" =~ ^[0-9]+$ ]] && \
    [ "$release_delete" -lt "$tag_delete" ] ||
    fail 'owned orphan deletion did not remove release before tag'
: > "$API_LOG"
reconcile_owned_mutable_target
assert_no_delete 'idempotent absent reconciliation'

printf '%s\n' '[2/14] an older-SHA draft is reconciled from its self-described asset contract'
reset_old_owned_state
reconcile_owned_mutable_target "$TAG_OBJECT_SHA" "$OLD_OWNER_MARKER"
[ ! -e "$STATE_ROOT/release.json" ] && [ ! -e "$STATE_ROOT/ref.json" ] ||
    fail 'older-SHA owned orphan state was not reconciled'

printf '%s\n' '[3/14] corrupt marker hash, base64, name, or digest is never deletion authority'
for marker_mutation in hash base64 name digest; do
    reset_owned_state
    mutation_assets="$expected_assets"
    payload_sha=$(printf '%s' "$mutation_assets" | sha256sum | awk '{print $1}')
    payload_b64=$(printf '%s' "$mutation_assets" | base64 -w 0)
    case "$marker_mutation" in
        hash)
            payload_sha=$(printf '0%.0s' {1..64})
            mutation_marker="rr-vps-release-owner:v2:${TAG}:${EXPECTED_SHA}:${NONCE}:${payload_sha}:${payload_b64}"
            ;;
        base64)
            mutation_marker="rr-vps-release-owner:v2:${TAG}:${EXPECTED_SHA}:${NONCE}:${payload_sha}:W10="
            ;;
        name)
            mutation_assets=$(jq -cS '.[0].name="unexpected.bin" | sort_by(.name)' \
                <<<"$expected_assets")
            mutation_marker=$(owner_marker_for "$EXPECTED_SHA" "$mutation_assets" "$NONCE")
            ;;
        digest)
            mutation_assets=$(jq -cS '.[0].digest="sha256:abc" | sort_by(.name)' \
                <<<"$expected_assets")
            mutation_marker=$(owner_marker_for "$EXPECTED_SHA" "$mutation_assets" "$NONCE")
            ;;
    esac
    set_owned_contract "$EXPECTED_SHA" "$mutation_marker" "$mutation_assets"
    if reconcile_owned_mutable_target >/dev/null 2>&1; then
        fail "corrupt marker ${marker_mutation} was reported as owned"
    fi
    assert_no_delete "corrupt marker ${marker_mutation}"
done

printf '%s\n' '[4/14] exact current public state is classified for verification-only resume'
reset_owned_state
jq '.draft=false | .immutable=true' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
classify_target_release_state
[ "$TARGET_RELEASE_STATE" = exact_public_current ] && [ "$TARGET_RELEASE_ID" = 17 ] ||
    fail 'exact current public release was not classified for resume'
RUN_TAG_OBJECT_SHA="$LOADED_TAG_OBJECT_SHA"
RUN_OWNER_MARKER="$LOADED_TAG_OWNER_MARKER"
git() {
    [ "${1:-}" = ls-remote ] || return 1
    [ ! -e "$STATE_ROOT/fail-git-inventory" ] || return 92
    if [[ " $* " == *" --refs "* ]]; then
        printf '%s\trefs/tags/%s\n' "$TAG_OBJECT_SHA" "$TAG"
    else
        printf '%s\trefs/tags/%s\n' "$TAG_OBJECT_SHA" "$TAG"
        printf '%s\trefs/tags/%s^{}\n' "$EXPECTED_SHA" "$TAG"
    fi
}
curl() {
    local output="" url="" argument=""
    while [ "$#" -gt 0 ]; do
        argument="$1"
        case "$argument" in
            -o) output="$2"; shift 2 ;;
            https://*) url="$argument"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$output" ] && [ -n "$url" ] || return 1
    command cp "$ASSET_ROOT/${url##*/}" "$output"
}
(
    cd "$ASSET_ROOT"
    verify_published_release "$TARGET_RELEASE_ID" "$RUN_OWNER_MARKER"
) || fail 'exact current public verification-only resume failed'
for inventory_failure in api invalid-json git; do
    case "$inventory_failure" in
        api) : > "$STATE_ROOT/fail-release-inventory" ;;
        invalid-json) : > "$STATE_ROOT/invalid-release-inventory" ;;
        git) : > "$STATE_ROOT/fail-git-inventory" ;;
    esac
    if assert_no_newer_product_version >/dev/null 2>&1; then
        fail "newer-version gate accepted ${inventory_failure} inventory failure"
    fi
    command rm -f -- "$STATE_ROOT/fail-release-inventory" \
        "$STATE_ROOT/invalid-release-inventory" "$STATE_ROOT/fail-git-inventory"
done
unset -f git curl
assert_no_delete 'exact current public verification-only resume'
if grep -Eq '^(PATCH|POST) ' "$API_LOG"; then
    fail 'exact current public resume attempted publication mutation'
fi
reset_owned_state
jq --arg marker "<!-- ${OWNER_MARKER} -->" \
    '.draft=false | .immutable=true | .body=("tampered notes\n" + $marker + "\n")' \
    "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
if classify_target_release_state >/dev/null 2>&1; then
    fail 'tampered public release notes were accepted as exact current state'
fi
assert_no_delete 'tampered public release notes'

printf '%s\n' '[5/14] old or mismatched public state fails closed without mutation'
for public_mutation in old-sha mismatch; do
    if [ "$public_mutation" = old-sha ]; then
        reset_old_owned_state
    else
        reset_owned_state
        jq '.name="foreign title"' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
        command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
    fi
    jq '.draft=false | .immutable=true' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next"
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
    if classify_target_release_state >/dev/null 2>&1; then
        fail "${public_mutation} public release was accepted as current"
    fi
    assert_no_delete "${public_mutation} public release"
    if grep -Eq '^(PATCH|POST) ' "$API_LOG"; then
        fail "${public_mutation} public release triggered publication mutation"
    fi
done

printf '%s\n' '[6/14] expected empty starter assets are recoverable, foreign starter state is not'
reset_owned_state
jq '.assets=[{name:"install.sh",size:0,digest:null,state:"starter",
    uploader:{login:"github-actions[bot]"}}]' "$STATE_ROOT/release.json" \
    > "$STATE_ROOT/release.next"
command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
reconcile_owned_mutable_target
[ ! -e "$STATE_ROOT/release.json" ] && [ ! -e "$STATE_ROOT/ref.json" ] ||
    fail 'owned empty starter asset was not safely reconciled'
for starter_mutation in name uploader size digest state; do
    reset_owned_state
    jq '.assets=[{name:"install.sh",size:0,digest:null,state:"starter",
        uploader:{login:"github-actions[bot]"}}]' "$STATE_ROOT/release.json" \
        > "$STATE_ROOT/release.next"
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
    case "$starter_mutation" in
        name) jq '.assets[0].name="unexpected.bin"' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        uploader) jq '.assets[0].uploader.login="foreign-user"' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        size) jq '.assets[0].size=1' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        digest) jq '.assets[0].digest="sha256:foreign"' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        state) jq '.assets[0].state="open"' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
    esac
    command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
    if reconcile_owned_mutable_target >/dev/null 2>&1; then
        fail "unsafe starter ${starter_mutation} was reported as owned"
    fi
    assert_no_delete "unsafe starter ${starter_mutation}"
done

printf '%s\n' '[7/14] lost DELETE responses require authoritative absence before success'
reset_owned_state
: > "$STATE_ROOT/delete-release-response-loss"
: > "$STATE_ROOT/delete-tag-response-loss"
reconcile_owned_mutable_target
[ ! -e "$STATE_ROOT/release.json" ] && [ ! -e "$STATE_ROOT/ref.json" ] ||
    fail 'confirmed response-loss deletion did not converge to absence'

printf '%s\n' '[8/14] an unconfirmed release deletion never reaches tag deletion'
reset_owned_state
: > "$STATE_ROOT/delete-release-stuck"
if reconcile_owned_mutable_target >/dev/null 2>&1; then
    fail 'stuck release deletion was reported as reconciled'
fi
[ -e "$STATE_ROOT/release.json" ] && [ -e "$STATE_ROOT/ref.json" ] ||
    fail 'unconfirmed release deletion removed protected state'
if grep -q '^DELETE .*/git/refs/tags/' "$API_LOG"; then
    fail 'tag deletion followed an unconfirmed release deletion'
fi

printf '%s\n' '[9/14] public, immutable, foreign, duplicate and unreadable state is never deleted'
for mutation in public immutable marker tag duplicate inventory run-marker; do
    reset_owned_state
    case "$mutation" in
        public) jq '.draft=false' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        immutable) jq '.immutable=true' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        marker) jq '.body="foreign"' "$STATE_ROOT/release.json" > "$STATE_ROOT/release.next" ;;
        tag) jq '.object.sha="1123456789abcdef0123456789abcdef01234567"' \
            "$STATE_ROOT/tag.json" > "$STATE_ROOT/tag.next" ;;
        duplicate) command cp "$STATE_ROOT/release.json" "$STATE_ROOT/release2.json" ;;
        inventory) : > "$STATE_ROOT/fail-release-inventory" ;;
        run-marker) : ;;
    esac
    if [ -f "$STATE_ROOT/release.next" ]; then
        command mv "$STATE_ROOT/release.next" "$STATE_ROOT/release.json"
    fi
    if [ -f "$STATE_ROOT/tag.next" ]; then
        command mv "$STATE_ROOT/tag.next" "$STATE_ROOT/tag.json"
    fi
    if [ "$mutation" = run-marker ]; then
        reconcile_owned_mutable_target "$TAG_OBJECT_SHA" \
            "$OTHER_OWNER_MARKER" \
            >/dev/null 2>&1 && reconciled=true || reconciled=false
    else
        reconcile_owned_mutable_target >/dev/null 2>&1 && reconciled=true || reconciled=false
    fi
    if [ "$reconciled" = true ]; then
        fail "$mutation state was reported as safely reconciled"
    fi
    assert_no_delete "$mutation state"
done

printf '%s\n' '[10/14] an owned tag-only orphan is recoverable but a lightweight tag is not'
reset_owned_state
command rm -f -- "$STATE_ROOT/release.json"
reconcile_owned_mutable_target
[ ! -e "$STATE_ROOT/ref.json" ] || fail 'owned tag-only orphan was not removed'
reset_owned_state
command rm -f -- "$STATE_ROOT/release.json"
jq '.object.type="commit" | .object.sha=$sha' --arg sha "$EXPECTED_SHA" \
    "$STATE_ROOT/ref.json" > "$STATE_ROOT/ref.next"
command mv "$STATE_ROOT/ref.next" "$STATE_ROOT/ref.json"
if reconcile_owned_mutable_target >/dev/null 2>&1; then
    fail 'foreign lightweight tag was reported as owned'
fi
assert_no_delete 'foreign lightweight tag'

printf '%s\n' '[11/14] PATCH response loss is accepted only after exact public state is read'
reset_owned_state
load_owned_target_tag
: > "$STATE_ROOT/patch-public"
: > "$STATE_ROOT/patch-response-loss"
publish_draft_and_confirm 17 "$LOADED_TAG_OWNER_MARKER" ||
    fail 'exact public state did not reconcile a lost PATCH response'
[ "$(jq -r '.draft' "$STATE_ROOT/release.json")" = false ] ||
    fail 'publication fixture did not become public'
assert_no_delete 'post-PATCH exact public reconciliation'

printf '%s\n' '[12/14] an unresolved draft after PATCH is left untouched for a later run'
reset_owned_state
load_owned_target_tag
: > "$STATE_ROOT/patch-response-loss"
if publish_draft_and_confirm 17 "$LOADED_TAG_OWNER_MARKER" >/dev/null 2>&1; then
    fail 'unchanged draft was reported as published'
fi
[ -e "$STATE_ROOT/release.json" ] && [ -e "$STATE_ROOT/ref.json" ] ||
    fail 'ambiguous PATCH path deleted mutable state'
assert_no_delete 'ambiguous PATCH path'

printf '%s\n' '[13/14] mismatched public state after PATCH fails without deletion'
reset_owned_state
load_owned_target_tag
: > "$STATE_ROOT/patch-public-mismatch"
: > "$STATE_ROOT/patch-response-loss"
if publish_draft_and_confirm 17 "$LOADED_TAG_OWNER_MARKER" >/dev/null 2>&1; then
    fail 'mismatched public release was accepted'
fi
[ -e "$STATE_ROOT/release.json" ] && [ -e "$STATE_ROOT/ref.json" ] ||
    fail 'mismatched public state was deleted'
assert_no_delete 'mismatched public PATCH state'

printf '%s\n' '[14/14] a same-commit foreign tag swap is rejected after PATCH'
reset_owned_state
RUN_TAG_OBJECT_SHA="$TAG_OBJECT_SHA"
RUN_OWNER_MARKER="$OWNER_MARKER"
: > "$STATE_ROOT/patch-public"
: > "$STATE_ROOT/patch-response-loss"
: > "$STATE_ROOT/patch-swap-tag"
publish_draft_and_confirm 17 "$RUN_OWNER_MARKER" ||
    fail 'tag-swap fixture did not reach exact public release state'
if assert_run_owned_target_tag >/dev/null 2>&1; then
    fail 'same-commit foreign annotated tag was accepted as this run ownership'
fi
[ "$(jq -r '.object.sha' "$STATE_ROOT/ref.json")" = "$FOREIGN_TAG_OBJECT_SHA" ] ||
    fail 'tag-swap fixture did not replace the annotated object'
assert_no_delete 'post-PATCH same-commit foreign tag'

printf '%s\n' 'release reconciliation regression: PASS'
