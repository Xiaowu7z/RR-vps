#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

RR_LIB_DIR="$test_dir/lib"
RR_REPOSITORY="Xiaowu7z/RR-vps"
SINGBOX_BIN="$test_dir/sing-box"
SYS_ARCH=amd64
MIN_SINGBOX_VERSION=1.12.0

version_ge() {
    local candidate="$1" baseline="$2"
    [ "$(printf '%s\n%s\n' "$baseline" "$candidate" | sort -V | tail -n 1)" = \
        "$candidate" ]
}

# shellcheck disable=SC1091
source modules/85-nexus.sh

write_fake_core() {
    local version="$1" go_version="$2" arch="$3" tags="$4"
    local revision="$5" cgo="$6"
    {
        printf '%s\n' '#!/bin/bash'
        printf '%s\n' 'if [ "${1:-}" != version ]; then exit 2; fi'
        printf "printf '%%s\\n' %q\n" "sing-box version ${version}"
        printf "printf '%%s\\n' %q\n" ""
        printf "printf '%%s\\n' %q\n" "Environment: ${go_version} linux/${arch}"
        printf "printf '%%s\\n' %q\n" "Tags: ${tags}"
        printf "printf '%%s\\n' %q\n" "Revision: ${revision}"
        printf "printf '%%s\\n' %q\n" "CGO: ${cgo}"
    } > "$SINGBOX_BIN"
    chmod 755 "$SINGBOX_BIN"
}

printf '%s\n' '[1/4] runtime accepts only the exact audited 1.14.0 binary identity'
write_fake_core "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_GO_VERSION" amd64 \
    "$NEXUS_CORE_EXPECTED_BUILD_TAGS" "$NEXUS_CORE_SOURCE_COMMIT" disabled
nexus_core_supports_traffic || fail 'exact audited 1.14.0 core was rejected'

write_fake_core 1.13.19 "$NEXUS_CORE_GO_VERSION" amd64 \
    "$NEXUS_CORE_EXPECTED_BUILD_TAGS" "$NEXUS_CORE_SOURCE_COMMIT" disabled
if nexus_core_supports_traffic; then
    fail 'legacy 1.13.19 core was treated as the formal 1.14.0 baseline'
fi
write_fake_core "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_GO_VERSION" amd64 \
    "$NEXUS_CORE_EXPECTED_BUILD_TAGS" "${NEXUS_CORE_SOURCE_COMMIT%?}0" disabled
if nexus_core_supports_traffic; then
    fail 'binary with a foreign source revision was accepted'
fi
write_fake_core "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_GO_VERSION" amd64 \
    "$NEXUS_CORE_EXPECTED_BUILD_TAGS" "$NEXUS_CORE_SOURCE_COMMIT" enabled
if nexus_core_supports_traffic; then
    fail 'CGO-enabled binary was accepted'
fi
write_fake_core "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_GO_VERSION" amd64 \
    "with_v2ray_api" "$NEXUS_CORE_SOURCE_COMMIT" disabled
if nexus_core_supports_traffic; then
    fail 'binary without DEFAULT_BUILD_TAGS_OTHERS was accepted'
fi

printf '%s\n' '[2/4] immutable upstream release and BUILD_INFO identities are exact'
upstream="$test_dir/upstream.json"
jq -n --arg tag "$NEXUS_CORE_TARGET_TAG" \
    --argjson id "$NEXUS_CORE_UPSTREAM_RELEASE_ID" '{
      id:$id,tag_name:$tag,draft:false,prerelease:false,immutable:true,
      author:{login:"github-actions[bot]"},
      url:("https://api.github.com/repos/SagerNet/sing-box/releases/"+($id|tostring)),
      html_url:("https://github.com/SagerNet/sing-box/releases/tag/"+$tag)
    }' > "$upstream"
nexus_validate_upstream_core_release "$upstream" || fail 'exact upstream release rejected'
jq '.immutable=false' "$upstream" > "$upstream.mutable"
if nexus_validate_upstream_core_release "$upstream.mutable"; then
    fail 'mutable upstream release accepted'
fi

builder=0123456789abcdef0123456789abcdef01234567
release="rr-nexus-core-v${NEXUS_CORE_TARGET_VERSION}-r${NEXUS_CORE_RELEASE_REVISION}"
build_info="$test_dir/BUILD_INFO"
printf '%s\n' \
    "SING_BOX_VERSION=${NEXUS_CORE_TARGET_VERSION}" \
    "SING_BOX_TAG=${NEXUS_CORE_TARGET_TAG}" \
    "SOURCE_COMMIT=${NEXUS_CORE_SOURCE_COMMIT}" \
    "RR_BUILDER_COMMIT=${builder}" \
    "RR_CORE_RELEASE=${release}" \
    "GO_VERSION=${NEXUS_CORE_GO_VERSION}" \
    "CGO_ENABLED=0" \
    "BUILD_TAG=with_v2ray_api" \
    "BUILD_TAGS=${NEXUS_CORE_EXPECTED_BUILD_TAGS}" \
    "SOURCE=https://github.com/SagerNet/sing-box/tree/${NEXUS_CORE_TARGET_TAG}" \
    > "$build_info"
nexus_validate_core_build_info "$build_info" "$NEXUS_CORE_TARGET_VERSION" \
    "$release" "$builder" || fail 'exact BUILD_INFO rejected'
sed 's/^CGO_ENABLED=0$/CGO_ENABLED=1/' "$build_info" > "$build_info.bad"
if nexus_validate_core_build_info "$build_info.bad" "$NEXUS_CORE_TARGET_VERSION" \
    "$release" "$builder"; then
    fail 'CGO-enabled BUILD_INFO accepted'
fi

printf '%s\n' '[3/4] Nexus V2Ray API generation remains attached to audited cores'
python3 - <<'PY'
from pathlib import Path

module = Path("modules/30-singbox.sh").read_text()
required = (
    "nexus_core_supports_traffic",
    "{v2ray_api:{listen:$listen,stats:{enabled:true,users:$users}}}",
    "json+=',\"experimental\":'\"$nexus_stats_json\"",
)
for fragment in required:
    if fragment not in module:
        raise SystemExit(f"Nexus V2Ray API regression: {fragment}")
PY

printf '%s\n' '[4/4] Naive H2, H3 and dual transports retain their 1.14 config forms'
naive_case=$(python3 - <<'PY'
from pathlib import Path

module = Path("modules/30-singbox.sh").read_text()
start = module.index('case "${NAIVE_MODE:-h2}" in')
end = module.index("esac", start) + len("esac")
print(module[start:end])
PY
)
render_naive_transport() {
    local naive_transport_json=""
    # shellcheck disable=SC2294
    eval "$naive_case"
    printf '%s\n' "$naive_transport_json"
}
[ "$(NAIVE_MODE=h2 NAIVE_QUIC_CC=bbr render_naive_transport)" = \
    ',"network":"tcp"' ] || fail 'Naive H2 transport changed'
[ "$(NAIVE_MODE=h3 NAIVE_QUIC_CC=bbr render_naive_transport)" = \
    ',"network":"udp","quic_congestion_control":"bbr"' ] || \
    fail 'Naive H3 transport changed'
[ "$(NAIVE_MODE=dual NAIVE_QUIC_CC=bbr render_naive_transport)" = \
    ',"quic_congestion_control":"bbr"' ] || fail 'Naive dual transport changed'

printf '%s\n' 'sing-box 1.14.0 runtime regressions: PASS'
