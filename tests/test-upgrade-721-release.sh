#!/bin/bash
# Reproduce both deployed 7.2.1 update clients against the current release bytes.
# Only official GitHub transport is mocked. Release, tag, workflow, asset, and
# manifest checks run unchanged; no installer or host service is executed.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Immutable guard fixture deployed to both primary hosts: official 7.2.1 and
# the Debian-compatible 7.2.1 candidate. Keep exercising these old bytes even
# if a future release changes scripts/update-guard.sh.
cat >"$test_root/old-guard.gz.b64" <<'OLD_GUARD'
H4sIAAAAAAACA+U9bVsUR7bf/RVlZ5Qh2jMDEtfFkCwiidwl6AMku7nAztPMNNDJMDPp7kEJzD5oNOIr7kaNGoxJNNGbREyy
rm/48l+y9MzwKX/hnnrp7qrq7mFQzId7ffKEma5Tp06dOu9VXfMKsib0XC4zoWc+pB87RjVrYtMrqL9fnSpaqPrJ7coXdysX
f3KOPXaWHq48u7p6+X+cn4/8Z+4IAFUWf6xcPL6yfG/lwRln4cjKg7POwj+cB5+gSS1vjOmW/dvjL6rnf64szgEGZOQtW8vl
EtYEchZvVe4sVH782lk6Ubt+LOmcOV59dLPy+T3n08vOsW8BdbJkmclcIaPlkjljNGmayclCtpTTreTOFrVUzGq2ro6XNDML
6H57fNp5eA9wop0p1oYHWXl4yjl31jn5Ve3JE0pvbelpbelr5+w1Z/7yb4+v1J5dXj1+uvLTg9qzRZhB7eb1ypfn4HP11ilv
Bqh65SidY+3+Hefp0WT152Xny1Mw5MrDa9Cp8tXXq9+fRqOlfDanY5bMn3P+cam6/Fnly6MwqLP0ibPwvTN/o3Lx9q9zixR5
5cEx58wF5/bntZNHKpfuOOe+cxYuOacv/jp3FfBWj94DsisnT1YXr1VuX4fxgUnOsVt0pP/MHYZRVh6cIpM6vPLolHOScdH5
52nniy8ry1dWHt2oLl92nnwGDGa8Hy0UbMs2tSK3Cpgnm/r70+8e2Ns52J1++93O/r3p97r7B3r293UoO5RNm0wzTdmZJqxO
F7WSpceb0cwmBP/I6qCiWZgs2h1KbKalXa2cPgEk1J58t3p+qfbsPHxOJBJlhYAbY2gIqTZKoRG0dSv93IJGdiN7Qs8TCPzP
1LUsUk2kFpESo7gVlEazs8g2SzoBGzM2lYO0aTndtD3asnomp5k6Ut9CAKhPGjYFQG8ks/pUMl/K5VDrG1tbMGJTt0tmHqVI
RxGajTCmGTk9izKmYRt4zgrTDqYaN36u3f1WAXpbFDTszUQROrfH4vgbUkuoaduW97dMbslu2dfUrCBVNfK2bk4B2h2pVNjM
soWD+VxBy0qMtwolM6OnS2auA4/MtdiaOa7b6TEYF5pahSZjUi+U7LSlZwr5rIWXbUe72pIq80AZDQxCerRkAV0dCt9i6jnN
NqZ0kAR7Qm4qFizDLpjTGCmIVX/3gf0DPYP7+99vV/9qaIWDpT98nKSME0YbNbV8ZoJ12tPf2de1r12d1Iy8SNOEls/rOQbG
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
/wWTfE0W62sAAA==
OLD_GUARD
python3 - "$test_root" <<'PYFIXTURE'
import base64, gzip, hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
value = gzip.decompress(base64.b64decode((root / 'old-guard.gz.b64').read_bytes()))
assert hashlib.sha256(value).hexdigest() == '2bbfdd8d80773cb48c19f11f91bbeb7ebd156f9419c30c5d81b3565aa346e64c'
(root / 'old-guard.sh').write_bytes(value)
PYFIXTURE
# shellcheck disable=SC1091
source "$test_root/old-guard.sh"

# Official v7.2.1 at c7de4b412b2bd90d45fea733a0d62ede37918aab.
cat >"$test_root/official-721.manifest" <<'OFFICIAL_MANIFEST'
c39dfb6e7f40fd159b7ec4b42e01a851075c9d3ba2a35f49f46a5b2ba0588cdc  rr
f908141e58c8f9abce04c6190072ef878dac768bbd8ba8b100f561847ce7c7ff  scripts/naive-cert-hook.sh
fddc027041ca4ce79c649f53b830c46f9d5736712c0cc9ac60fc4ccf2a8a80a9  scripts/update-recover.sh
bf61a9ed170a67309f562937d4057252b81e3afc85c9f2e277f2aa30a9f06e98  scripts/update-external-state.py
e037a6732c3f51dfce6f4d46b0ff4d3e91cd8f939b926f362705cb15949413f0  modules/00-runtime.sh
1117fcc078ec7d4041dda2902ad93dbdc8e369b822ee82eb846192c178390740  modules/09-systemd.sh
2e8b60c97bc2cc872291d0fceaef7a34dd30bbce713ba3465f1fd87a711549f0  modules/10-system.sh
46d77107b13342e5a118ba88866ab889a234b5675e6866b1f61201c6e73c377a  modules/20-config.sh
a31b2431a41772e930772df69422e2a3d5024f317d42c3b750b502b63ff2444f  modules/30-singbox.sh
924024237dd3948ec9e7f5ecdbcaa18326a2fdb76ebfd1c8433fe0b549f0cdc6  modules/40-subscription.sh
d423362ce867fa5495b10025433b873bf6f31629ed01cd815587fadbf7585e32  modules/50-status-argo.sh
47bcdf775b70e06f9e47cf30620b34adf34aefccc5db3e14d5d0abe6c545074d  modules/55-resilience.sh
7c7da6ec8a5be181de680d7f76092b37f49f70774443e28b7d0b0531460ed69d  modules/60-update.sh
00c2733d7a4a13dcb4fffe718e800474a864d5b3608439905f00c50851a1b2dd  modules/70-protocols.sh
726709e6922a89359e9a9417e74018479d506c6399ead2a0d659f0b4df8c9dca  modules/80-ui.sh
170ad710ac9cc89c40ab24aeb69fcbd68d65caebf00bca7d218516d161546457  modules/85-nexus.sh
a97d3e583008f7492851b408ceac5979f72e4aa9844fb53ff2ee06bf518a6469  modules/86-nexus-ip-acme.sh
a9d9cfa7d34d54984af30f5a5218ed1b2567e6b1a71166dde6d1b883b16a6988  modules/90-auto-update.sh
9b69c533ff5ac6229217fb658cf12b872e322fcd9e3a217bdaf3e2191aa6ee9c  modules/95-install.sh
79c9594f622b09447a43d11c2d1b3823df77bbf2e2edb5b7b6d0558a628d7a25  modules/99-menus.sh
aab4bb8fb6c7e3d7e4244d1a0d7ceabc22dcd298b11d31e75f159d1cc47ae723  nexus/rr_nexus.py
a9830859c6af5db89451252c0172ba7fc2217c14ca116aac774997493c7616e2  nexus/rr_nexus_lib/__init__.py
72cff73636729d6d8445cf4b723eb0627613e60b99eb15dd220e8651a16c5f67  nexus/rr_nexus_lib/backup_archive.py
9224c800ce0d09a602dda4baf559ff17501f5280fa55bed15ce0e11a00ba8535  nexus/rr_nexus_lib/backup_crypto.py
2915b286cc3fb451facbe3fef0d5e566a989c4949066a6954eff44dd6957fd57  nexus/rr_nexus_lib/http_security.py
472db9149120d4c2359d9b3ecc9a87a54310140a86a3a60fc094c91dc1b16d74  nexus/rr_nexus_lib/notifications.py
c5d985b7cd6925d6b2c3eba441b8ae2f227cf9ca4c0ad29301ac9a0e4ea90ef0  nexus/rr_nexus_lib/notify_cli.py
230414a1633dd3aede65ed46035cf2adc3159458401d443d22325de8e72492c1  nexus/rr_nexus_lib/security.py
2ea6d83dbe90cc8bdb77ebad05a7de5a93ebec695701b3d323d583a8e79cafe1  nexus/static/admin.js
48d649f0c871f30e27fd94149478aa7d049a11cf20352f00c13454b358f83cce  nexus/static/app.css
c58993c8cf2e3f2aab30a94b68affc15a9e70c82786b118818c99c73cbde5180  nexus/static/app.js
b563ffb33a45f0bfb32420f702e106f0c3ed22dc4f6dbc26a43f365ec9d2be80  nexus/static/index.html
2db2fb2016ee6e10efc5d94a5d06cb275011362da3469888010b6cf816299318  nexus/static/optimizer.css
f1a37955a3e33c69954e59c26db4baff5d36d2b572ac717dc0189bf5afd7a89c  nexus/static/optimizer.js
af225a804c5c7c0e03df296137d5b7fd120a4298e76e97981bca0d04b4d999be  nexus/sub_server.py
OFFICIAL_MANIFEST
# The verified Debian candidate changed only the calendar parser in module 20.
# Pin the full resulting manifest hash as well as the changed entry.
python3 - "$test_root" <<'PYMANIFEST'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
original = (root / 'official-721.manifest').read_bytes()
assert hashlib.sha256(original).hexdigest() == 'cf604eddf29d8d2ae069214844b3e9f96c3b2c80eb72359e2428d1368925b894'
before = b'46d77107b13342e5a118ba88866ab889a234b5675e6866b1f61201c6e73c377a  modules/20-config.sh\n'
after = b'1d1163516971150a0399ce6c8aa381a75f23dfb1be8d0d63387df4bdfa29412c  modules/20-config.sh\n'
assert original.count(before) == 1
candidate = original.replace(before, after)
assert hashlib.sha256(candidate).hexdigest() == '98685d1dc37a7255aa3d139d57ea0daaf2e9dd776fd016512014eb0d02906042'
(root / 'debian-721.manifest').write_bytes(candidate)
PYMANIFEST

fixture_assets="$test_root/assets"
mkdir "$fixture_assets"
cp install.sh manifest.sha256 rr-bundle.tar.gz "$fixture_assets/"
fixture_version=$(sed -n '1s/^RR-vps //p' version)
[[ "$fixture_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid release version'
[ "$(printf '%s\n' 7.2.2 "$fixture_version" | sort -V | head -n 1)" = 7.2.2 ] || fail 'requires 7.2.2 or newer'
fixture_tag="v$fixture_version"
fixture_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fixture_tag_object=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# Verify these are the actual coherent candidate bootstrap/bundle bytes, not
# a dummy bootstrap that would hide tag or pinned-installer hash regressions.
python3 - "$fixture_tag" <<'PYPAYLOAD'
import hashlib, pathlib, re, sys, tarfile
root = pathlib.Path('.')
bootstrap = (root / 'install.sh').read_text()
for key, expected in (
    ('RR_RELEASE_TAG', sys.argv[1]),
    ('RR_CORE_SHA256', hashlib.sha256((root / 'scripts/install-core.sh').read_bytes()).hexdigest()),
    ('RR_GUARD_SHA256', hashlib.sha256((root / 'scripts/update-guard.sh').read_bytes()).hexdigest()),
):
    assert re.findall(r'^' + key + r'="([^"]+)"$', bootstrap, re.M) == [expected], key
with tarfile.open(root / 'rr-bundle.tar.gz', 'r:gz') as bundle:
    assert bundle.extractfile('rr-bundle/manifest.sha256').read() == (root / 'manifest.sha256').read_bytes()
PYPAYLOAD
printf '%s\n' "VERSION=$fixture_version" "TAG=$fixture_tag" "COMMIT=$fixture_commit" >"$fixture_assets/RELEASE_INFO"
(cd "$fixture_assets"; sha256sum install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO >SHA256SUMS)

asset_objects=()
asset_id=100
for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
    digest="sha256:$(sha256sum "$fixture_assets/$asset" | awk '{print $1}')"
    size=$(stat -c %s "$fixture_assets/$asset")
    asset_objects+=("$(jq -cn --arg repo Xiaowu7z/RR-vps --arg tag "$fixture_tag" \
        --arg name "$asset" --arg digest "$digest" --argjson id "$asset_id" --argjson size "$size" '
        {id:$id,name:$name,size:$size,digest:$digest,state:"uploaded",
         uploader:{login:"github-actions[bot]"},
         url:("https://api.github.com/repos/"+$repo+"/releases/assets/"+($id|tostring)),
         browser_download_url:("https://github.com/"+$repo+"/releases/download/"+$tag+"/"+$name)}
    ')")
    asset_id=$((asset_id + 1))
done
owner_assets=$(printf '%s\n' "${asset_objects[@]}" | jq -scS '[.[] | {name,size,digest}] | sort_by(.name)')
owner_payload_sha=$(printf '%s' "$owner_assets" | sha256sum | awk '{print $1}')
owner_payload_b64=$(printf '%s' "$owner_assets" | base64 -w 0)
owner_marker="rr-vps-release-owner:v2:${fixture_tag}:${fixture_commit}:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc:${owner_payload_sha}:${owner_payload_b64}"
printf '%s\n' "${asset_objects[@]}" | jq -sc --arg tag "$fixture_tag" --arg commit "$fixture_commit" \
    --arg marker "<!-- ${owner_marker} -->" '
    {id:77,tag_name:$tag,target_commitish:$commit,draft:false,prerelease:false,
     immutable:true,author:{login:"github-actions[bot]"},
     body:("compatibility test release\n\n"+$marker+"\n"),assets:.}
' >"$test_root/release.json"
jq -cn --arg sha "$fixture_commit" '{object:{sha:$sha}}' >"$test_root/main.json"
jq -cn --arg sha "$fixture_commit" '{total_count:1,workflow_runs:[
    {id:4401,head_sha:$sha,head_branch:"main",event:"push",run_number:44,run_attempt:1,
     status:"completed",conclusion:"success"}
]}' >"$test_root/runs.json"
jq -cn --arg tag "$fixture_tag" --arg sha "$fixture_tag_object" \
    '{ref:("refs/tags/"+$tag),object:{type:"tag",sha:$sha}}' >"$test_root/ref.json"
jq -cn --arg object "$fixture_tag_object" --arg tag "$fixture_tag" --arg sha "$fixture_commit" --arg marker "$owner_marker" '
    {sha:$object,tag:$tag,message:$marker,object:{type:"commit",sha:$sha},
     tagger:{name:"github-actions[bot]",email:"41898282+github-actions[bot]@users.noreply.github.com"}}
' >"$test_root/tag.json"

RR_REPOSITORY=Xiaowu7z/RR-vps
RR_UPDATE_CHANNEL=stable
RR_GITHUB_MIRROR=https://untrusted.invalid/
fixture_fault=none
# Restrict transport to the exact endpoints expected by the old release guard.
# A branch/raw fallback, missing event filter, or unbound tag is a test failure.
rr_update_guard_official_get() {
    local source_url="$1" target_file="$2" asset=""
    printf '%s\n' "$source_url" >>"$test_root/http.log"
    case "$source_url" in
        https://api.github.com/repos/Xiaowu7z/RR-vps/releases/latest)
            cp "$test_root/release.json" "$target_file"
            if [ "$fixture_fault" = mutable-release ]; then
                jq '.immutable = false' "$test_root/release.json" >"$target_file"
            fi
            ;;
        https://api.github.com/repos/Xiaowu7z/RR-vps/git/ref/heads/main)
            if [ "$fixture_fault" = moved-main ]; then
                jq '.object.sha = "dddddddddddddddddddddddddddddddddddddddd"' "$test_root/main.json" >"$target_file"
            else cp "$test_root/main.json" "$target_file"; fi
            ;;
        "https://api.github.com/repos/Xiaowu7z/RR-vps/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha=$fixture_commit&per_page=100&page=1"|\
        "https://api.github.com/repos/Xiaowu7z/RR-vps/actions/workflows/vps-stability.yml/runs?branch=main&event=push&head_sha=$fixture_commit&per_page=100&page=1")
            if [ "$fixture_fault" = dispatch-only ] && [[ "$source_url" = */vps-stability.yml/* ]]; then
                jq '.workflow_runs[0].event = "workflow_dispatch"' "$test_root/runs.json" >"$target_file"
            else cp "$test_root/runs.json" "$target_file"; fi
            ;;
        "https://api.github.com/repos/Xiaowu7z/RR-vps/git/ref/tags/$fixture_tag")
            cp "$test_root/ref.json" "$target_file" ;;
        "https://api.github.com/repos/Xiaowu7z/RR-vps/git/tags/$fixture_tag_object")
            cp "$test_root/tag.json" "$target_file" ;;
        "https://github.com/Xiaowu7z/RR-vps/releases/download/$fixture_tag/"*)
            asset=${source_url##*/}
            case "$asset" in install.sh|manifest.sha256|rr-bundle.tar.gz|RELEASE_INFO|SHA256SUMS) ;; *) return 1 ;; esac
            cp "$fixture_assets/$asset" "$target_file"
            if [ "$fixture_fault:$asset" = tampered-bootstrap:install.sh ]; then
                printf '\n# substituted transport bytes\n' >>"$target_file"
            fi
            ;;
        *) fail "unexpected external endpoint: $source_url" ;;
    esac
}
rr_update_guard_download() { fail 'old stable guard attempted an unverified download'; }
# Guard allows syntax checking; the real candidate installer must never run.
bash() {
    if [ "$#" -eq 2 ] && [ "$1" = -n ]; then command bash "$@"; return; fi
    : >"$test_root/installer-execution-attempt"
    fail 'read-only compatibility test tried to execute an installer'
}

for profile in official-721 debian-721; do
    printf 'Testing deployed %s guard with actual %s assets\n' "$profile" "$fixture_tag"
    RR_LOCAL_MANIFEST="$test_root/$profile.manifest"
    old_manifest_digest=$(sha256sum "$RR_LOCAL_MANIFEST" | awk '{print $1}')
    : >"$test_root/http.log"
    check_update
    [ "$UPDATE_CHECK_STATE:$UPDATE_AVAILABLE" = available:true ] || fail "$profile did not detect the new release"
    target=$(mktemp "$test_root/bootstrap.XXXXXX")
    rr_update_guard_prepare_bootstrap "$target" || fail "$profile rejected the actual new bootstrap"
    cmp -s install.sh "$target" || fail "$profile downloaded different bootstrap bytes"
    [ "$old_manifest_digest" = "$(sha256sum "$RR_LOCAL_MANIFEST" | awk '{print $1}')" ] || fail 'local manifest changed'
    # Each of check_update and prepare_bootstrap runs pre/post-download proof.
    for workflow in ci.yml vps-stability.yml; do
        count=$(grep -Fc "/actions/workflows/$workflow/runs?branch=main&event=push&head_sha=$fixture_commit&per_page=100&page=1" "$test_root/http.log")
        [ "$count" -eq 4 ] || fail "$profile omitted repeated $workflow evidence"
    done
    [ "$(grep -Fc '/releases/latest' "$test_root/http.log")" -eq 4 ] || fail 'Latest was not rechecked'
    rm -f "$target"
done

# A byte-identical installed candidate correctly stops without requesting
# installation, regardless of its semantic version display.
RR_LOCAL_MANIFEST="$fixture_assets/manifest.sha256"
check_update
[ "$UPDATE_CHECK_STATE:$UPDATE_AVAILABLE" = latest:false ] || fail 'identical manifest was not latest'

RR_LOCAL_MANIFEST="$test_root/debian-721.manifest"
for fixture_fault in moved-main dispatch-only mutable-release tampered-bootstrap; do
    printf 'Rejecting %s without offering executable bootstrap bytes\n' "$fixture_fault"
    check_update
    [ "$UPDATE_CHECK_STATE:$UPDATE_AVAILABLE" = failed:false ] || fail "$fixture_fault remained available"
    target=$(mktemp "$test_root/rejected-bootstrap.XXXXXX")
    if rr_update_guard_prepare_bootstrap "$target"; then fail "$fixture_fault was accepted"; fi
    [ ! -s "$target" ] || fail "$fixture_fault exposed unverified bootstrap bytes"
    rm -f "$target"
done
[ ! -e "$test_root/installer-execution-attempt" ] || fail 'installer was executed'
printf '%s\n' 'official and Debian 7.2.1 old-client release compatibility: PASS'
