# shellcheck shell=bash
# RR-vps 热更新兼容保险层。
# 本文件不参与发布 manifest；由最新 install.sh 在每次安装/升级时写入
# /usr/local/lib/rr/modules/61-update-guard.sh，并在 60-update.sh 之后加载。
# 设计原则：这里永远不解析远程 manifest 的文件路径/类型，也不校验 bundle
# 成员结构。它只判断“远程清单字节是否变化”，然后把真正的安全校验、
# 下载、事务安装和回滚交给当次最新 bootstrap install.sh。

RR_UPDATE_GUARD_VERSION="3"

rr_update_guard_pause() {
    local prompt="${1:-按回车键返回...}"
    if [ -t 0 ] && [ -t 1 ]; then
        read -r -p "$prompt" _ || true
    fi
}

rr_update_guard_alert() {
    declare -F rr_emit_alert >/dev/null 2>&1 || return 0
    rr_emit_alert update_failed critical "RR-vps 更新失败" "$1" \
        "update_failed:$(date -u '+%Y%m%d%H')" --interval 300
}

rr_update_guard_download() {
    local source_url="$1"
    local target_file="$2"
    local timeout_seconds="${3:-10}"
    local cache_buster=""
    local relative_path=""
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local branch="${RR_BRANCH:-main}"
    local channel="${RR_UPDATE_CHANNEL:-stable}"
    local raw_base="${RR_RAW_BASE:-https://raw.githubusercontent.com/${repository}/refs/heads/${branch}}"
    local api_base="${RR_API_BASE:-https://api.github.com/repos/${repository}/contents}"
    local cdn_base="${RR_CDN_BASE:-https://cdn.jsdelivr.net/gh/${repository}@${branch}}"

    cache_buster=$(date +%s)
    case "$source_url" in
        "${raw_base}/"*) relative_path="${source_url#"${raw_base}/"}" ;;
    esac

    # manifest/bootstrap 都会影响随后执行的 root 代码。它们只允许从 GitHub
    # 官方 TLS 端点取得，用户镜像不能成为更新信任根。
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout "$timeout_seconds" --max-time 180 \
            -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
            "${source_url}?t=${cache_buster}" -o "$target_file" 2>/dev/null && return 0
        if [ "$channel" = beta ] && [ -n "$relative_path" ]; then
            curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 180 \
                -H "Accept: application/vnd.github.raw+json" \
                "${api_base}/${relative_path}?ref=${branch}&t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
            curl -4 -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 180 \
                "${cdn_base}/${relative_path}?t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout_seconds" --tries=3 \
            -O "$target_file" "${source_url}?t=${cache_buster}" && return 0
        if [ "$channel" = beta ] && [ -n "$relative_path" ]; then
            wget -q --timeout="$timeout_seconds" --tries=2 \
                --header="Accept: application/vnd.github.raw+json" \
                -O "$target_file" \
                "${api_base}/${relative_path}?ref=${branch}&t=${cache_buster}" && return 0
            wget -4 -q --timeout="$timeout_seconds" --tries=2 \
                -O "$target_file" "${cdn_base}/${relative_path}?t=${cache_buster}" && return 0
        fi
    else
        return 1
    fi
    return 1
}

rr_update_guard_official_get() {
    local source_url="$1" target_file="$2" repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    case "$source_url" in
        "https://api.github.com/repos/${repository}/"*|\
        "https://github.com/${repository}/releases/download/"*) ;;
        *) return 1 ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
            -fsSL --retry 3 --retry-all-errors --retry-delay 2 \
            --connect-timeout 10 --max-time 180 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2026-03-10' \
            "$source_url" -o "$target_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only --timeout=15 --tries=3 \
            --header='Accept: application/vnd.github+json' \
            --header='X-GitHub-Api-Version: 2026-03-10' \
            -O "$target_file" "$source_url"
    else
        return 1
    fi
}

rr_update_guard_parse_release() {
    local release_json="$1" repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    [ -s "$release_json" ] && [ ! -L "$release_json" ] || return 1
    [ "$(stat -c %s "$release_json" 2>/dev/null || echo 0)" -le 1048576 ] || return 1
    jq -e --arg repo "$repository" '
        . as $release |
        (.id | type == "number") and
        (.tag_name | test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
        (.target_commitish | test("^[0-9a-f]{40}$")) and
        .draft == false and .prerelease == false and .immutable == true and
        .author.login == "github-actions[bot]" and (.body | type) == "string" and
        (.assets | type == "array") and (.assets | length) == 5 and
        ([.assets[].name] | sort) ==
          (["install.sh", "manifest.sha256", "rr-bundle.tar.gz", "RELEASE_INFO", "SHA256SUMS"] | sort) and
        ([.assets[].name] | length == (unique | length)) and
        ([.assets[].id] | length == (unique | length)) and
        all(.assets[];
          (.id | type == "number") and
          (.size | type == "number") and .size == (.size | floor) and .size > 0 and
          .state == "uploaded" and .uploader.login == "github-actions[bot]" and
          (.digest | type == "string") and (.digest | test("^sha256:[0-9a-f]{64}$")) and
          .browser_download_url ==
            ("https://github.com/" + $repo + "/releases/download/" + $release.tag_name + "/" + .name) and
          .url ==
            ("https://api.github.com/repos/" + $repo + "/releases/assets/" + (.id | tostring)))
    ' "$release_json" >/dev/null || return 1
    RR_GUARD_STABLE_RELEASE_ID=$(jq -r '.id' "$release_json")
    RR_GUARD_STABLE_TAG=$(jq -r '.tag_name' "$release_json")
    RR_GUARD_STABLE_VERSION="${RR_GUARD_STABLE_TAG#v}"
    RR_GUARD_STABLE_COMMIT=$(jq -r '.target_commitish' "$release_json")
    RR_GUARD_STABLE_ASSETS=$(jq -cS \
        '[.assets[] | {id, name, size, digest, url, browser_download_url, state,
          uploader: .uploader.login}] | sort_by(.name)' \
        "$release_json") || return 1
    RR_GUARD_STABLE_OWNER_ASSETS=$(jq -cS \
        '[.assets[] | {name, size, digest}] | sort_by(.name)' "$release_json") || return 1
    RR_GUARD_STABLE_FINGERPRINT=$(jq -cS '
        {id, tag_name, target_commitish, draft, prerelease, immutable,
         author: .author.login, body,
         assets: ([.assets[] | {id, name, size, digest, url, browser_download_url, state,
           uploader: .uploader.login}] |
           sort_by(.name))}
    ' "$release_json") || return 1
    [[ "$RR_GUARD_STABLE_RELEASE_ID" =~ ^[0-9]+$ ]] &&
        [[ "$RR_GUARD_STABLE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
}

rr_update_guard_assert_main_tip() {
    local expected_sha="$1" target="" repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    target=$(mktemp /tmp/rr-stable-main.XXXXXX) || return 1
    if ! rr_update_guard_official_get \
        "https://api.github.com/repos/${repository}/git/ref/heads/main" "$target" ||
       [ "$(jq -r '.object.sha // empty' "$target" 2>/dev/null)" != "$expected_sha" ]; then
        rm -f "$target"
        return 1
    fi
    rm -f "$target"
}

rr_update_guard_assert_workflow_gate() {
    local workflow_file="$1" expected_event="$2" expected_sha="$3"
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local runs_dir="" all_runs="" page_file=""
    local page=1 page_count=0 expected_total="" accumulated=0 result=1
    case "$expected_event" in
        push|workflow_dispatch) ;;
        *) return 1 ;;
    esac
    [[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    runs_dir=$(mktemp -d /tmp/rr-stable-runs.XXXXXX) || return 1
    all_runs="$runs_dir/all.jsonl"
    : >"$all_runs" || {
        rm -rf -- "$runs_dir"
        return 1
    }

    # GitHub may return more than one page for a SHA after reruns. Fetch until
    # the first short page, and independently reconcile every page with the
    # advertised total_count. A partial, repeated, or changing inventory is
    # never accepted as release evidence.
    while :; do
        page_file="$runs_dir/page-${page}.json"
        if ! rr_update_guard_official_get \
            "https://api.github.com/repos/${repository}/actions/workflows/${workflow_file}/runs?branch=main&event=${expected_event}&head_sha=${expected_sha}&per_page=100&page=${page}" \
            "$page_file" ||
           ! jq -e '
                type == "object" and
                (.total_count | type == "number") and
                .total_count == (.total_count | floor) and
                .total_count >= 0 and .total_count <= 10000 and
                (.workflow_runs | type == "array") and
                (.workflow_runs | length) <= 100 and
                all(.workflow_runs[]; type == "object")
            ' "$page_file" >/dev/null; then
            rm -rf -- "$runs_dir"
            return 1
        fi
        page_count=$(jq -r '.workflow_runs | length' "$page_file")
        if [ -z "$expected_total" ]; then
            expected_total=$(jq -r '.total_count' "$page_file")
        elif [ "$(jq -r '.total_count' "$page_file")" != "$expected_total" ]; then
            rm -rf -- "$runs_dir"
            return 1
        fi
        jq -c '.workflow_runs[]' "$page_file" >>"$all_runs" || {
            rm -rf -- "$runs_dir"
            return 1
        }
        accumulated=$((accumulated + page_count))
        [ "$accumulated" -le "$expected_total" ] || {
            rm -rf -- "$runs_dir"
            return 1
        }
        if [ "$page_count" -lt 100 ]; then
            break
        fi
        page=$((page + 1))
        [ "$page" -le 101 ] || {
            rm -rf -- "$runs_dir"
            return 1
        }
    done
    [ "$accumulated" -eq "$expected_total" ] || {
        rm -rf -- "$runs_dir"
        return 1
    }

    jq -se --arg sha "$expected_sha" --arg event "$expected_event" '
        . as $inventory |
        ($inventory | map(select(
          .head_sha == $sha and .head_branch == "main" and .event == $event
        ))) as $exact |
        all($inventory[];
          (.id | type == "number") and .id == (.id | floor) and .id > 0 and
          (.run_number | type == "number") and
            .run_number == (.run_number | floor) and .run_number > 0 and
          (.run_attempt | type == "number") and
            .run_attempt == (.run_attempt | floor) and .run_attempt > 0 and
          (.status | type == "string") and
          (.conclusion == null or (.conclusion | type == "string"))) and
        ([$inventory[].id] | length) ==
          ([$inventory[].id] | unique | length) and
        ($inventory | group_by([.run_number, .run_attempt]) |
          all(.[]; length == 1)) and
        ($exact | length) > 0 and
        ($exact | sort_by([.run_number, .run_attempt]) | last) as $run |
        $run.status == "completed" and $run.conclusion == "success"
    ' "$all_runs" >/dev/null && result=0
    rm -rf -- "$runs_dir"
    return "$result"
}

rr_update_guard_assert_owned_tag() {
    local tag="$1" expected_sha="$2" release_json="$3" ref_json="" tag_json=""
    local object_sha="" marker="" owner_commit="" nonce="" payload_sha=""
    local payload_b64="" payload="" canonical="" body_marker=""
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    [ -s "$release_json" ] && [ ! -L "$release_json" ] || return 1
    ref_json=$(mktemp /tmp/rr-stable-ref.XXXXXX) || return 1
    tag_json=$(mktemp /tmp/rr-stable-tag.XXXXXX) || { rm -f "$ref_json"; return 1; }
    if ! rr_update_guard_official_get \
        "https://api.github.com/repos/${repository}/git/ref/tags/${tag}" "$ref_json"; then
        rm -f "$ref_json" "$tag_json"
        return 1
    fi
    object_sha=$(jq -r --arg ref "refs/tags/${tag}" '
        if .ref == $ref and .object.type == "tag" and
           (.object.sha | test("^[0-9a-f]{40}$"))
        then .object.sha else empty end
    ' "$ref_json")
    if [ -z "$object_sha" ] || ! rr_update_guard_official_get \
        "https://api.github.com/repos/${repository}/git/tags/${object_sha}" "$tag_json"; then
        rm -f "$ref_json" "$tag_json"
        return 1
    fi
    marker=$(jq -r '.message // empty' "$tag_json")
    if [[ "$marker" =~ ^rr-vps-release-owner:v2:([^:]+):([0-9a-f]{40}):([0-9a-f]{64}):([0-9a-f]{64}):([A-Za-z0-9+/]*={0,2})$ ]]; then
        [ "${BASH_REMATCH[1]}" = "$tag" ] || {
            rm -f "$ref_json" "$tag_json"
            return 1
        }
        owner_commit="${BASH_REMATCH[2]}"
        nonce="${BASH_REMATCH[3]}"
        payload_sha="${BASH_REMATCH[4]}"
        payload_b64="${BASH_REMATCH[5]}"
    else
        rm -f "$ref_json" "$tag_json"
        return 1
    fi
    [ "$owner_commit" = "$expected_sha" ] && [ -n "$nonce" ] || {
        rm -f "$ref_json" "$tag_json"
        return 1
    }
    payload=$(printf '%s' "$payload_b64" | base64 --decode) || {
        rm -f "$ref_json" "$tag_json"
        return 1
    }
    [ "$(printf '%s' "$payload" | base64 -w 0)" = "$payload_b64" ] &&
        [ "$(printf '%s' "$payload" | sha256sum | awk '{print $1}')" = "$payload_sha" ] || {
        rm -f "$ref_json" "$tag_json"
        return 1
    }
    canonical=$(jq -ceS '
        if type == "array" then [.[] | {name, size, digest}] | sort_by(.name)
        else error("owner payload") end
    ' <<<"$payload") || {
        rm -f "$ref_json" "$tag_json"
        return 1
    }
    [ "$canonical" = "$payload" ] &&
        [ "$canonical" = "$RR_GUARD_STABLE_OWNER_ASSETS" ] || {
        rm -f "$ref_json" "$tag_json"
        return 1
    }
    jq -e --arg object "$object_sha" --arg tag "$tag" --arg sha "$expected_sha" \
        --arg marker "$marker" '
        .sha == $object and .tag == $tag and
        .message == $marker and
        .object.type == "commit" and .object.sha == $sha and
        .tagger.name == "github-actions[bot]" and
        .tagger.email == "41898282+github-actions[bot]@users.noreply.github.com"
    ' "$tag_json" >/dev/null || {
        rm -f "$ref_json" "$tag_json"
        return 1
    }
    body_marker="<!-- ${marker} -->"
    jq -e --arg marker "$body_marker" '
        .author.login == "github-actions[bot]" and
        all(.assets[]; .uploader.login == "github-actions[bot]") and
        (.body as $body | ($body | index($marker)) as $first |
          $first != null and
          (($body[($first + ($marker | length)):] | contains($marker)) | not))
    ' "$release_json" >/dev/null
    local result=$?
    if [ "$result" -eq 0 ]; then
        RR_GUARD_STABLE_OWNER_MARKER="$marker"
        RR_GUARD_STABLE_OWNER_PAYLOAD="$canonical"
        RR_GUARD_STABLE_TAG_OBJECT_SHA="$object_sha"
    fi
    rm -f "$ref_json" "$tag_json"
    return "$result"
}

rr_update_guard_validate_assets() {
    local release_dir="$1" tag="$2" commit="$3" version=""
    local asset="" expected_digest="" expected_size="" actual_digest="" actual_size=""
    version="${tag#v}"
    for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
        [ -f "$release_dir/$asset" ] && [ ! -L "$release_dir/$asset" ] || return 1
        expected_digest=$(jq -r --arg asset "$asset" \
            '.[] | select(.name == $asset) | .digest' <<<"$RR_GUARD_STABLE_ASSETS")
        expected_size=$(jq -r --arg asset "$asset" \
            '.[] | select(.name == $asset) | .size' <<<"$RR_GUARD_STABLE_ASSETS")
        actual_digest="sha256:$(sha256sum "$release_dir/$asset" | awk '{print $1}')"
        actual_size=$(stat -c %s "$release_dir/$asset")
        [ "$actual_digest" = "$expected_digest" ] && [ "$actual_size" = "$expected_size" ] || return 1
    done
    awk '
        NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        $2 !~ /^(install\.sh|manifest\.sha256|rr-bundle\.tar\.gz|RELEASE_INFO)$/ { exit 1 }
        seen[$2]++ { exit 1 }
        END { if (NR != 4) exit 1 }
    ' "$release_dir/SHA256SUMS" || return 1
    (cd "$release_dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || return 1
    awk -F= '
        NF != 2 { exit 1 }
        $1 !~ /^(VERSION|TAG|COMMIT)$/ { exit 1 }
        seen[$1]++ { exit 1 }
        END { if (NR != 3) exit 1 }
    ' "$release_dir/RELEASE_INFO" || return 1
    grep -Fxq "VERSION=${version}" "$release_dir/RELEASE_INFO" &&
        grep -Fxq "TAG=${tag}" "$release_dir/RELEASE_INFO" &&
        grep -Fxq "COMMIT=${commit}" "$release_dir/RELEASE_INFO" &&
        bash -n "$release_dir/install.sh" 2>/dev/null &&
        grep -Fxq "RR_RELEASE_TAG=\"${tag}\"" "$release_dir/install.sh" &&
        grep -Fxq 'RR_REPOSITORY="Xiaowu7z/RR-vps"' "$release_dir/install.sh"
}

rr_update_guard_prepare_stable_release() {
    local release_dir="$1" repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local metadata="" final_metadata="" asset="" asset_url="" expected_size="" max_size=0
    local initial_id="" initial_tag="" initial_commit="" initial_assets="" initial_fingerprint=""
    local initial_owner_assets="" initial_owner_marker="" initial_owner_payload=""
    local initial_tag_object_sha=""
    [ "${RR_UPDATE_CHANNEL:-stable}" = stable ] &&
        [ "$repository" = Xiaowu7z/RR-vps ] && command -v jq >/dev/null 2>&1 || return 1
    [ -d "$release_dir" ] && [ ! -L "$release_dir" ] &&
        [ -z "$(find "$release_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] || return 1
    chmod 700 "$release_dir" || return 1
    metadata="$release_dir/.release.json"
    final_metadata="$release_dir/.release.final.json"
    rr_update_guard_official_get \
        "https://api.github.com/repos/${repository}/releases/latest" "$metadata" &&
        rr_update_guard_parse_release "$metadata" || return 1
    initial_id="$RR_GUARD_STABLE_RELEASE_ID"
    initial_tag="$RR_GUARD_STABLE_TAG"
    initial_commit="$RR_GUARD_STABLE_COMMIT"
    initial_assets="$RR_GUARD_STABLE_ASSETS"
    initial_owner_assets="$RR_GUARD_STABLE_OWNER_ASSETS"
    initial_fingerprint="$RR_GUARD_STABLE_FINGERPRINT"
    rr_update_guard_assert_owned_tag "$initial_tag" "$initial_commit" "$metadata" || return 1
    initial_owner_marker="$RR_GUARD_STABLE_OWNER_MARKER"
    initial_owner_payload="$RR_GUARD_STABLE_OWNER_PAYLOAD"
    initial_tag_object_sha="$RR_GUARD_STABLE_TAG_OBJECT_SHA"

    rr_update_guard_assert_main_tip "$initial_commit" &&
        rr_update_guard_assert_workflow_gate ci.yml push "$initial_commit" &&
        rr_update_guard_assert_workflow_gate vps-audit.yml push "$initial_commit" &&
        rr_update_guard_assert_workflow_gate vps-audit.yml workflow_dispatch "$initial_commit" &&
        rr_update_guard_assert_main_tip "$initial_commit" || return 1

    for asset in install.sh manifest.sha256 rr-bundle.tar.gz RELEASE_INFO SHA256SUMS; do
        case "$asset" in
            install.sh) max_size=262144 ;;
            manifest.sha256) max_size=1048576 ;;
            rr-bundle.tar.gz) max_size=52428800 ;;
            RELEASE_INFO|SHA256SUMS) max_size=16384 ;;
        esac
        expected_size=$(jq -r --arg asset "$asset" \
            '.[] | select(.name == $asset) | .size' <<<"$initial_assets")
        [[ "$expected_size" =~ ^[0-9]+$ ]] && [ "$expected_size" -le "$max_size" ] || return 1
        asset_url="https://github.com/${repository}/releases/download/${initial_tag}/${asset}"
        rr_update_guard_official_get "$asset_url" "$release_dir/$asset" || return 1
        [ "$(stat -c %s "$release_dir/$asset" 2>/dev/null || echo 0)" -le "$max_size" ] || return 1
    done
    RR_GUARD_STABLE_ASSETS="$initial_assets"
    rr_update_guard_validate_assets "$release_dir" "$initial_tag" "$initial_commit" || return 1

    rr_update_guard_official_get \
        "https://api.github.com/repos/${repository}/releases/latest" "$final_metadata" &&
        rr_update_guard_parse_release "$final_metadata" || return 1
    [ "$RR_GUARD_STABLE_RELEASE_ID" = "$initial_id" ] &&
        [ "$RR_GUARD_STABLE_TAG" = "$initial_tag" ] &&
        [ "$RR_GUARD_STABLE_COMMIT" = "$initial_commit" ] &&
        [ "$RR_GUARD_STABLE_ASSETS" = "$initial_assets" ] &&
        [ "$RR_GUARD_STABLE_OWNER_ASSETS" = "$initial_owner_assets" ] &&
        [ "$RR_GUARD_STABLE_FINGERPRINT" = "$initial_fingerprint" ] || return 1
    rr_update_guard_assert_owned_tag "$initial_tag" "$initial_commit" "$final_metadata" &&
        [ "$RR_GUARD_STABLE_OWNER_MARKER" = "$initial_owner_marker" ] &&
        [ "$RR_GUARD_STABLE_OWNER_PAYLOAD" = "$initial_owner_payload" ] &&
        [ "$RR_GUARD_STABLE_TAG_OBJECT_SHA" = "$initial_tag_object_sha" ] &&
        rr_update_guard_assert_workflow_gate ci.yml push "$initial_commit" &&
        rr_update_guard_assert_workflow_gate vps-audit.yml push "$initial_commit" &&
        rr_update_guard_assert_workflow_gate vps-audit.yml workflow_dispatch "$initial_commit" &&
        rr_update_guard_assert_main_tip "$initial_commit" || return 1
    rm -f "$metadata" "$final_metadata"
}

rr_update_guard_copy_verified_asset() {
    local asset="$1" target_file="$2" release_dir=""
    case "$asset" in
        install.sh|manifest.sha256|rr-bundle.tar.gz|RELEASE_INFO|SHA256SUMS) ;;
        *) return 1 ;;
    esac
    [ -f "$target_file" ] && [ ! -L "$target_file" ] || return 1
    release_dir=$(mktemp -d /tmp/rr-stable-release.XXXXXX) || return 1
    if ! rr_update_guard_prepare_stable_release "$release_dir" ||
       ! install -m 600 "$release_dir/$asset" "$target_file" ||
       [ ! -f "$target_file" ] || [ -L "$target_file" ]; then
        rm -rf "$release_dir"
        return 1
    fi
    rm -rf "$release_dir"
}

# Stable 先完成 immutable Latest、精确资产、Tag、main，以及同一 SHA 的
# CI push、VPS push、VPS workflow_dispatch 三重证据，再比较 manifest；
# beta 才继续消费显式 branch。
check_update() {
    local remote_manifest=""
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local branch="${RR_BRANCH:-main}"
    local raw_base="${RR_RAW_BASE:-https://raw.githubusercontent.com/${repository}/refs/heads/${branch}}"
    local local_manifest="${RR_LOCAL_MANIFEST:-${RR_LIB_DIR:-/usr/local/lib/rr}/manifest.sha256}"
    local manifest_url="${RR_MANIFEST_URL:-${raw_base}/manifest.sha256}"

    UPDATE_AVAILABLE=false
    UPDATE_CHECK_STATE="failed"
    UPDATE_CHECK_ERROR=""
    SCRIPT_VER_STATUS="${YELLOW:-}检查失败（网络不可用）${RESET:-}"

    remote_manifest=$(mktemp /tmp/rr-update-guard-manifest.XXXXXX) || {
        UPDATE_CHECK_ERROR="无法创建临时文件"
        return 0
    }
    if { [ "${RR_UPDATE_CHANNEL:-stable}" = stable ] &&
         ! rr_update_guard_copy_verified_asset manifest.sha256 "$remote_manifest"; } ||
       { [ "${RR_UPDATE_CHANNEL:-stable}" != stable ] &&
         { ! rr_update_guard_download "$manifest_url" "$remote_manifest" 3 ||
           [ ! -s "$remote_manifest" ]; }; }; then
        UPDATE_CHECK_ERROR="GitHub Raw、API 与 CDN 均不可达"
        SCRIPT_VER_STATUS="${YELLOW:-}检查失败（下载链路不可用）${RESET:-}"
        rm -f "$remote_manifest"
        return 0
    fi

    if [ -s "$local_manifest" ] && cmp -s "$remote_manifest" "$local_manifest"; then
        UPDATE_CHECK_STATE="latest"
        SCRIPT_VER_STATUS="${GREEN:-}已是最新${RESET:-}"
    else
        UPDATE_AVAILABLE=true
        UPDATE_CHECK_STATE="available"
        SCRIPT_VER_STATUS="${RED:-}有新版本${RESET:-}"
    fi
    rm -f "$remote_manifest"
}

rr_update_guard_prepare_bootstrap() {
    local target_file="$1"
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local branch="${RR_BRANCH:-main}"
    local raw_base="${RR_RAW_BASE:-https://raw.githubusercontent.com/${repository}/refs/heads/${branch}}"
    local bootstrap_url="${RR_BOOTSTRAP_URL:-${raw_base}/install.sh}"

    { [ "${RR_UPDATE_CHANNEL:-stable}" = stable ] &&
      rr_update_guard_copy_verified_asset install.sh "$target_file" ||
      { [ "${RR_UPDATE_CHANNEL:-stable}" != stable ] &&
        rr_update_guard_download "$bootstrap_url" "$target_file" 10; }; } && \
        [ -s "$target_file" ] && \
        [ "$(stat -c %s "$target_file" 2>/dev/null || echo 0)" -le 262144 ] && \
        bash -n "$target_file" 2>/dev/null && \
        grep -q '^RR_BOOTSTRAP_VERSION=' "$target_file" && \
        grep -q 'RR_REPOSITORY="Xiaowu7z/RR-vps"' "$target_file"
}

# 8 号热更新的唯一职责：获取“此刻最新”的 bootstrap，再由 bootstrap 决定
# 当前发布清单/文件类型/Bundle 如何验证和安装。保险层本身不维护发布白名单。
do_update() {
    local bootstrap_tmp=""
    local preflight_tmp=""

    # 上次更新如果被断电/SIGKILL 中断，先由独立恢复器收敛到旧版。
    if [ -x /usr/local/sbin/rr-update-recover ]; then
        /usr/local/sbin/rr-update-recover recover || {
            echo -e "${RED:-}[失败] 上次更新事务未能完整恢复，已停止新更新。${RESET:-}"
            return 1
        }
    fi
    preflight_tmp=$(mktemp /tmp/rr-update-preflight.XXXXXX) || return 1
    if [ -x /usr/local/bin/rr ] && ! /usr/local/bin/rr --update-preflight >"$preflight_tmp" 2>/dev/null; then
        echo -e "${RED:-}[失败] 更新预检未通过，当前节点未改动。${RESET:-}"
        cat "$preflight_tmp" 2>/dev/null || true
        rr_update_guard_alert "更新预检未通过，当前节点未改动。"
        rm -f "$preflight_tmp"
        rr_update_guard_pause
        return 1
    fi
    rm -f "$preflight_tmp"

    echo -e "\n${YELLOW:-}检查 RR-vps 远程更新...${RESET:-}"
    check_update
    if [ "${UPDATE_CHECK_STATE:-failed}" = "latest" ]; then
        echo -e "${GREEN:-}当前已是最新版本，无需更新。${RESET:-}"
        rr_update_guard_pause
        return 0
    fi
    if [ "${UPDATE_CHECK_STATE:-failed}" = "failed" ]; then
        echo -e "${YELLOW:-}[提示] 状态检查失败：${UPDATE_CHECK_ERROR:-未知原因}。将直接尝试获取最新安全更新程序；获取失败则不会改动当前节点。${RESET:-}"
    else
        echo -e "${YELLOW:-}发现发布内容变化，正在获取最新安全更新程序...${RESET:-}"
    fi

    bootstrap_tmp=$(mktemp /tmp/rr-bootstrap-guard.XXXXXX) || {
        echo -e "${RED:-}[失败] 无法创建更新临时文件，当前节点未改动。${RESET:-}"
        rr_update_guard_pause
        return 1
    }
    if ! rr_update_guard_prepare_bootstrap "$bootstrap_tmp"; then
        rm -f "$bootstrap_tmp"
        echo -e "${RED:-}[失败] 最新更新程序下载或完整性检查失败，当前节点未改动。${RESET:-}"
        rr_update_guard_alert "安全引导器下载或完整性检查失败，当前节点未改动。"
        rr_update_guard_pause
        return 1
    fi
    chmod 700 "$bootstrap_tmp"

    echo -e "${YELLOW:-}正在执行带完整备份、校验与自动回滚保护的热更新...${RESET:-}"
    if bash "$bootstrap_tmp" --upgrade; then
        rm -f "$bootstrap_tmp"
        echo -e "${GREEN:-}[成功] RR-vps 热更新完成。${RESET:-}"
        echo -e "${CYAN:-}原 UUID、密钥、域名、节点端口、订阅端口及 IPv4/IPv6 设置均按安装器事务规则保留。${RESET:-}"
        if [ -t 0 ] && [ -t 1 ]; then
            read -r -p "按回车键退出并重新执行 rr..." _ || true
        fi
        exit 0
    fi

    rm -f "$bootstrap_tmp"
    echo -e "${RED:-}[失败] 热更新未完成；最新安装程序已按事务规则回滚，当前节点保持升级前状态。${RESET:-}"
    rr_update_guard_alert "热更新事务失败，已执行自动回滚；请运行 rr doctor。"
    rr_update_guard_pause
    return 1
}
