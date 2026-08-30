#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
VPS_WORKFLOW="$REPO_ROOT/.github/workflows/vps-audit.yml"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

python3 - "$WORKFLOW" "$VPS_WORKFLOW" "$CI_WORKFLOW" \
    "$TEST_ROOT/assert-workflow-gate.sh" <<'PY'
from pathlib import Path
import re
import sys

release = Path(sys.argv[1]).read_text(encoding="utf-8")
vps = Path(sys.argv[2]).read_text(encoding="utf-8")
ci = Path(sys.argv[3]).read_text(encoding="utf-8")

verify_start = release.index("  verify:\n")
publish_start = release.index("  publish:\n", verify_start)
verify = release[verify_start:publish_start]
publish = release[publish_start:]

assert "permissions:\n      contents: read\n      actions: read" in verify
assert "permissions:\n      contents: write\n      actions: read" in publish
assert "needs: verify" in publish
assert "head_sha=${REQUESTED_SHA}" in verify
assert "head_sha=${EXPECTED_SHA}" in publish
# Workflow gates use the exact head_sha filter. Release/tag reconciliation
# additionally requires successful paginated inventories and never maps a
# failed API read to absence.
assert release.count("--paginate --slurp") >= 4
assert "assert_workflow_gate ci.yml CI" in publish
assert 'assert_workflow_gate vps-audit.yml "VPS audit"' in publish
assert publish.count("assert_release_gate") >= 4
assert publish.count("assert_verified_sha_gate") >= 2
assert "assert_main_tip()" in publish
assert 'git/ref/heads/main" --jq \'.object.sha\'' in publish
assert re.search(
    r"assert_release_gate\n\s+cleanup_armed=true\n\s+trap release_cleanup_on_exit EXIT\n"
    r"\s+created_ref=\$\(api --method POST",
    publish,
)
ref_create = publish.index("created_ref=$(api --method POST")
tag_wait = publish.index('wait_for_remote_tag_sha "$TAG" "$EXPECTED_SHA"', ref_create)
tag_identity = publish.index("assert_run_owned_target_tag", tag_wait)
post_tag_main = publish.index("assert_main_tip", tag_identity)
draft_create = publish.index('gh release create "$TAG"', post_tag_main)
assert ref_create < tag_wait < tag_identity < post_tag_main < draft_create
assert re.search(
    r"assert_release_gate\n\s+cleanup_armed=false\n\s+trap - EXIT\n"
    r"\s+publish_draft_and_confirm \"\$draft_id\" \"\$RUN_OWNER_MARKER\"",
    publish,
)
assert "rr-vps-release-owner:v2:" in publish
assert "rr-vps-release-owner:v1:" not in publish
assert "reconcile_owned_mutable_target()" in publish
assert "classify_target_release_state()" in publish
assert "is_owned_mutable_draft()" in publish
assert "is_exact_public_release()" in publish
assert "verify_published_release()" in publish
assert '$actual.state == "starter"' in publish
patch_call = publish.index(
    'publish_draft_and_confirm "$draft_id" "$RUN_OWNER_MARKER"'
)
verify_call = publish.index(
    'verify_published_release "$draft_id" "$RUN_OWNER_MARKER"', patch_call
)
assert patch_call < verify_call
verifier_start = publish.index("          verify_published_release() {")
assets_start = publish.index("          expected_assets=", verifier_start)
verifier = publish[verifier_start:assets_start]
exact_id = verifier.index('api "/repos/${GITHUB_REPOSITORY}/releases/${release_id}"')
newer_gate = verifier.index("assert_no_newer_product_version", exact_id)
latest_call = verifier.index('assert_latest_product "$release_id" "$owner_marker"', newer_gate)
final_tag_identity = verifier.index("assert_run_owned_target_tag", latest_call)
download = verifier.index("releases/latest/download", final_tag_identity)
assert exact_id < newer_gate < latest_call < final_tag_identity < download
latest_start = publish.index("          assert_latest_product() {")
latest_end = verifier_start
latest = publish[latest_start:latest_end]
assert "is_exact_public_release" in latest
assert "'.immutable == true'" in latest
assert '--rawfile notes "$RELEASE_NOTES_FILE"' in publish
assert '.body == ($notes + "\\n" + $marker + "\\n")' in publish
assert 'releases=$(api --paginate --slurp' in publish
assert '") || return 1\n            jq -e' in publish
assert "remote_tags=$(git ls-remote --tags --refs origin 'refs/tags/v*') || return 1" in publish

driver = publish[assets_start:]
first_classify = driver.index("classify_target_release_state")
first_version_gate = driver.index("assert_new_monotonic_version")
tag_object_post = driver.index('tag_object=$(api --method POST')
assert first_classify < first_version_gate < tag_object_post
resume_start = driver.index("exact_public_current)")
resume_end = driver.index("owned_mutable)", resume_start)
resume = driver[resume_start:resume_end]
assert "assert_release_gate" in resume
assert "verify_published_release" in resume
assert "exit 0" in resume
assert not re.search(r"--method\s+(?:POST|PATCH|DELETE)", resume)
owned_end = driver.index("absent)", resume_end)
owned = driver[resume_end:owned_end]
assert 'reconcile_owned_mutable_target "$LOADED_TAG_OBJECT_SHA"' in owned
last_creation_gate = driver.rfind("assert_release_gate", 0, tag_object_post)
assert last_creation_gate != -1 and last_creation_gate < tag_object_post
assert publish.index(
    'api --method DELETE "/repos/${GITHUB_REPOSITORY}/releases/${release_id}"'
) < publish.index('delete_owned_target_tag "$expected_object_sha" "$expected_marker"')
assert "Main is allowed to" not in publish
assert publish.count("--method PATCH") == 1
assert "bash scripts/" not in publish
assert "python3 scripts/" not in publish
for asset in (
    "CHANGELOG.md", "install.sh", "manifest.sha256",
    "modules/00-runtime.sh", "rr-bundle.tar.gz",
):
    assert f"            {asset}\n" in publish

assert "StrictHostKeyChecking=accept-new" not in vps
assert vps.count("StrictHostKeyChecking=yes") == 4
assert vps.count("HostKeyAlgorithms=ssh-ed25519") == 4
assert vps.count("GlobalKnownHostsFile=/dev/null") == 4
job_ranges = {
    "A": ("  debian-full:\n", "  ubuntu-upgrade:\n"),
    "B": ("  ubuntu-upgrade:\n", "  ubuntu-transaction:\n"),
    "C": ("  ubuntu-transaction:\n", "  cross-machine-migration-scale:\n"),
}
pinned_keys = {
    "A": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmpYE2GN+xGyCxDQW1e/NrwzmApHDMz+zLigsrhXhRm",
    "B": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJWJw40hog64SpnWDcp4mvlSJIZ1qspCoOhNrn0L/B5A",
    "C": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPNn4M3kE0+DoV//4xOYwweoLnTrwS+bJmmD6pK4ios3",
}
assert len(set(pinned_keys.values())) == 3
for slot, (start_marker, end_marker) in job_ranges.items():
    start = vps.index(start_marker)
    end = vps.index(end_marker, start)
    job = vps[start:end]
    assert f"RR_{slot}_HOST_KEY: {pinned_keys[slot]}" in job
    assert 'printf \'%s %s %s\\n\' "$host" "$host_key_type" "$host_key_data" > "$known_hosts"' in job
b_start, b_end = job_ranges["B"]
b_job = vps[vps.index(b_start):vps.index(b_end, vps.index(b_start))]
a_start, a_end = job_ranges["A"]
a_job = vps[vps.index(a_start):vps.index(a_end, vps.index(a_start))]
assert "openssl x509 -checkhost" not in a_job
assert "declare -F certificate_identity_matches >/dev/null" in a_job
for certificate, identity in (
    ('${panel_domain}', '$panel_domain'),
    ('${naive_domain}', '$naive_domain'),
):
    assert (
        f'"/etc/letsencrypt/live/{certificate}/fullchain.pem" "{identity}"'
        in a_job
    )
for certificate, wrong_identity in (
    ('${panel_domain}', '$naive_domain'),
    ('${naive_domain}', '$panel_domain'),
):
    assert (
        f'"/etc/letsencrypt/live/{certificate}/fullchain.pem" "{wrong_identity}"'
        in a_job
    )
for fragment in (
    "[ -e /etc/rr-nexus ]",
    "[ -e /var/lib/rr-nexus ]",
    "systemctl list-unit-files rr-nexus.service --no-legend",
    "test ! -e /etc/rr-nexus",
    "test ! -e /var/lib/rr-nexus",
    'systemctl show -p LoadState --value rr-nexus.service',
):
    assert fragment in b_job
candidate_cleanup_if = b_job.index("          if [ -e /usr/local/bin/rr ]")
candidate_cleanup_call = b_job.index("                uninstall_all", candidate_cleanup_if)
candidate_cleanup_stage = b_job.index("          printf 'preclean-complete", candidate_cleanup_call)
quarantine_contract_start = b_job.index("          quarantine_fully_absent() {")
quarantine_contract_end = b_job.index(
    '          test "$(id -u)" -eq 0', quarantine_contract_start
)
quarantine_contract = b_job[quarantine_contract_start:quarantine_contract_end]
for artifact in (
    "/var/lib/rr-update/subscription-quarantine",
    "/run/rr-subscription-quarantine.ready",
    "/etc/systemd/system/rr-subscription-quarantine.service",
    "/var/lib/rr-quarantine/guard-state",
    "/usr/local/libexec/rr-vps/subscription-quarantine-guard",
):
    assert artifact in quarantine_contract
assert '[ ! -e "$artifact" ] && [ ! -L "$artifact" ]' in quarantine_contract
assert "not-found:inactive:not-found || return 1" in quarantine_contract
assert '"$backend" -w 5 -t raw -S PREROUTING' in quarantine_contract
assert "rr-vps unsafe rollback subscription quarantine" in quarantine_contract
for fragment in (
    "[ -e /var/lib/rr-update ]",
    "[ -L /var/lib/rr-update ]",
    "[ -e /run/rr-vps/update-maintenance ]",
    "[ -L /run/rr-vps/update-maintenance ]",
):
    position = b_job.index(fragment, candidate_cleanup_if, candidate_cleanup_call)
    assert candidate_cleanup_if < position < candidate_cleanup_call
for fragment in (
    "test ! -e /var/lib/rr-update",
    "test ! -L /var/lib/rr-update",
    "test ! -e /run/rr-vps/update-maintenance",
    "test ! -L /run/rr-vps/update-maintenance",
):
    position = b_job.index(fragment, candidate_cleanup_call, candidate_cleanup_stage)
    assert candidate_cleanup_call < position < candidate_cleanup_stage
quarantine_wait = b_job.index("          quarantine_absent=false", candidate_cleanup_call)
quarantine_probe = b_job.index(
    "            if quarantine_fully_absent; then", quarantine_wait
)
quarantine_final = b_job.index(
    '          if [ "$quarantine_absent" != true ] || ! quarantine_fully_absent; then',
    quarantine_probe,
)
assert candidate_cleanup_call < quarantine_wait < quarantine_probe
assert quarantine_probe < quarantine_final < candidate_cleanup_stage
lock_wait = b_job.index("          update_locks_released=false", quarantine_final)
lock_probe = b_job.index(
    "            rr_run_with_update_locks direct 0 true", lock_wait
)
lock_busy_retry = b_job.index("              75) sleep 1 ;;", lock_probe)
lock_timeout = b_job.index(
    '          if [ "$update_locks_released" != true ]; then', lock_busy_retry
)
assert quarantine_final < lock_wait < lock_probe < lock_busy_retry
assert lock_busy_retry < lock_timeout < candidate_cleanup_stage
assert "B pre-clean update lock probe failed safely" in b_job[lock_probe:lock_timeout]
for fragment in (
    "run_old_install_deps() {",
    "attempt <= 30",
    "Could not get lock|Unable to acquire.*lock|held by process|is another process using",
    "sleep 10",
    "return 75",
):
    assert fragment in b_job
assert b_job.count("run_old_install_deps") == 2
assert "SELECT COUNT(*) FROM devices;" in b_job
assert 'all(.[]; test("^dev_[a-f0-9]{12}$"))' in b_job
nexus_names = b_job.index("            nexus_traffic_user_names")
nexus_assert_start = b_job.rfind("          bash -c '\n", 0, nexus_names)
nexus_assert_end = b_job.index("\n          '\n", nexus_names)
nexus_assert = b_job[nexus_assert_start:nexus_assert_end]
assert "set -eo pipefail" in nexus_assert
assert "nexus_traffic_user_names" in nexus_assert and "| jq -e" in nexus_assert
c_start, c_end = job_ranges["C"]
c_job = vps[vps.index(c_start):vps.index(c_end, vps.index(c_start))]
assert "printf '%s\\n' 0 '' '' '' | bash -c" in c_job
assert "committed-settled" in c_job
assert "rr-update-committed-settled-v1" in c_job
assert "if any_node_protocol_enabled; then" in c_job
assert "C no-protocol recovery fixture unexpectedly has an enabled node." in c_job
assert "for writer_marker in writer_state_complete subscription_was_running; do" in c_job
assert 'test -f "$active_tx/backup/$writer_marker"' in c_job
assert "subscription_server_running" in c_job
assert 'ufw --force allow' not in a_job
ufw_reset = a_job.index('ufw --force reset')
ufw_inactive = a_job.index("grep -qx 'Status: inactive'", ufw_reset)
ufw_marker = a_job.index('ufw_marker=/etc/ufw/applications.d/rr-audit-marker', ufw_inactive)
ufw_allow = a_job.index('ufw allow "$ssh_control_port/tcp"', ufw_marker)
ufw_saved = a_job.index('ufw show added', ufw_allow)
ufw_enable = a_job.index('ufw --force enable', ufw_saved)
ufw_active = a_job.index("grep -qx 'Status: active'", ufw_enable)
ufw_live = a_job.index('rr_ufw_rule_state "$ssh_control_port" tcp ALLOW', ufw_active)
assert ufw_reset < ufw_inactive < ufw_marker < ufw_allow < ufw_saved
assert ufw_saved < ufw_enable < ufw_active < ufw_live
assert "|| true" not in a_job[ufw_reset:ufw_live]
migration_start = vps.index("  cross-machine-migration-scale:\n")
gate_start = vps.index("  vps-gate:\n", migration_start)
migration = vps[migration_start:gate_start]
gate = vps[gate_start:]
assert "needs: [debian-full, ubuntu-transaction]" in migration
for slot in ("A", "C"):
    for secret in ("HOST", "PASS"):
        assert f"RR_{slot}_{secret}: ${{{{ secrets.RR_{slot}_{secret} }}}}" in migration
    assert f"RR_{slot}_HOST_KEY: {pinned_keys[slot]}" in migration
for slot in ("A", "B", "C"):
    assert f"secrets.RR_{slot}_HOST_KEY" not in vps
assert "known-hosts-migration-A" in migration
assert "known-hosts-migration-C" in migration
assert 'prepare_known_hosts "$a_host" "$RR_A_HOST_KEY" "$a_known_hosts"' in migration
assert 'prepare_known_hosts "$c_host" "$RR_C_HOST_KEY" "$c_known_hosts"' in migration
assert migration.count("assert_unit_state() {") == 2
for fragment in (
    'systemctl show -p LoadState --value "$unit"',
    'systemctl show -p ActiveState --value "$unit"',
    'systemctl show -p UnitFileState --value "$unit"',
    'test "$load_state:$active_state:$unit_file_state" = "$expected"',
):
    assert migration.count(fragment) == 2
assert "for scale in 1 10 100 500; do" in migration
assert "timeout --kill-after=5 150 /usr/local/bin/rr --sync-devices" in migration
assert 'timeout --kill-after=10 300 /usr/local/bin/rr backup "$backup_file"' in migration
assert 'timeout --kill-after=10 300 /usr/local/bin/rr restore "$backup_file"' in migration
assert migration.count("RR_BACKUP_PASSPHRASE=") == 2
assert "PRAGMA quick_check" in migration
assert "PRAGMA foreign_key_check" in migration
assert "stable_sha256" in migration
assert "cmp -s \"$fingerprint_file\" \"$restored_fingerprint\"" in migration
assert "127.0.0.1:7900" in migration
assert "public_listen=$(ss -H -ltn 'sport = :17900') || exit 1" in migration
for field in (
    "SUB_PORT", "SUB_ACCESS_MODE", "SUB_DOMAIN",
    "SUB_PUBLIC_PORT_IPV4", "SUB_PUBLIC_PORT_IPV6",
):
    assert field in migration
assert "rr-audit-cross-target-bind" in migration
assert "rr-audit-cross-target-firewall" in migration
assert "capture_rr_firewall_state()" in migration
assert "NAIVE_ENABLED=false" in migration
assert "expected_private" in migration and "expected_public" in migration
assert (
    "needs: [debian-full, ubuntu-upgrade, ubuntu-transaction, "
    "cross-machine-migration-scale]"
) in gate
assert "M_RESULT: ${{ needs.cross-machine-migration-scale.result }}" in gate
assert 'test "$M_RESULT" = success' in gate
assert "pinned SSH host keys" in vps
assert "TOFU" not in vps
assert not re.search(r"\bsystemctl\s+is-(?:active|enabled)\b", vps)
for line in vps.splitlines():
    if line.lstrip().startswith("! "):
        assert "||" in line, f"bare negated assertion can pass under errexit: {line}"
assert not re.search(r"!\s+ss\b", vps)
assert not re.search(r"if\s+ss\b[^\n]*\|", vps)
assert not re.search(r"if\s+journalctl\b[^\n]*\|", vps)
assert not re.search(r'test\s+-z\s+"\$\(', vps)
assert 'rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null || true)' not in vps
assert "test-uninstall-quarantine.sh|\\" in ci

lines = release.splitlines()
start = lines.index("          assert_workflow_gate() {")
end = lines.index("          assert_immutable_releases_enabled() {", start)
functions = "\n".join(line[10:] for line in lines[start:end]) + "\n"
Path(sys.argv[4]).write_text(functions, encoding="utf-8")
PY

# shellcheck source=/dev/null
source "$TEST_ROOT/assert-workflow-gate.sh"
EXPECTED_SHA=0123456789abcdef0123456789abcdef01234567
GITHUB_REPOSITORY=example/rr-vps
fixture="$TEST_ROOT/runs.json"
api_log="$TEST_ROOT/api.log"
MAIN_SHA="$EXPECTED_SHA"
api() {
    printf '%s\n' "$*" > "$api_log"
    case "$1" in
        */git/ref/heads/main) printf '%s\n' "$MAIN_SHA" ;;
        *) cat "$fixture" ;;
    esac
}

write_run() {
    local sha="$1" branch="$2" event="$3" status="$4" conclusion="$5" attempt="$6"
    jq -n --arg sha "$sha" --arg branch "$branch" --arg event "$event" \
        --arg status "$status" --arg conclusion "$conclusion" --argjson attempt "$attempt" \
        '{workflow_runs:[{run_number:41,run_attempt:$attempt,head_sha:$sha,
          head_branch:$branch,event:$event,status:$status,conclusion:$conclusion}]}' > "$fixture"
}

printf '%s\n' '[1/6] exact successful main push is accepted through a SHA-filtered query'
write_run "$EXPECTED_SHA" main push completed success 1
assert_workflow_gate ci.yml CI
[[ "$(cat "$api_log")" == *"head_sha=${EXPECTED_SHA}"* ]]

printf '%s\n' '[2/6] wrong SHA, branch, event, status, and conclusion fail closed'
for mutation in sha branch event status conclusion; do
    write_run "$EXPECTED_SHA" main push completed success 1
    case "$mutation" in
        sha) write_run 1123456789abcdef0123456789abcdef01234567 main push completed success 1 ;;
        branch) write_run "$EXPECTED_SHA" beta push completed success 1 ;;
        event) write_run "$EXPECTED_SHA" main workflow_dispatch completed success 1 ;;
        status) write_run "$EXPECTED_SHA" main push in_progress success 1 ;;
        conclusion) write_run "$EXPECTED_SHA" main push completed failure 1 ;;
    esac
    if assert_workflow_gate ci.yml CI >/dev/null 2>&1; then
        echo "Release gate accepted invalid ${mutation}." >&2
        exit 1
    fi
done

printf '%s\n' '[3/6] a newer failed rerun supersedes an older success'
jq -n --arg sha "$EXPECTED_SHA" '{workflow_runs:[
  {run_number:41,run_attempt:1,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"success"},
  {run_number:41,run_attempt:2,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"failure"}
]}' > "$fixture"
if assert_workflow_gate vps-audit.yml 'VPS audit' >/dev/null 2>&1; then
    echo 'Release gate accepted a SHA whose latest attempt failed.' >&2
    exit 1
fi

printf '%s\n' '[4/6] a newer successful rerun is accepted'
jq '.workflow_runs[1].conclusion = "success"' "$fixture" > "$fixture.next"
mv "$fixture.next" "$fixture"
assert_workflow_gate vps-audit.yml 'VPS audit'

printf '%s\n' '[5/6] empty workflow evidence is rejected'
printf '%s\n' '{"workflow_runs":[]}' > "$fixture"
if assert_workflow_gate ci.yml CI >/dev/null 2>&1; then
    echo 'Release gate accepted missing CI evidence.' >&2
    exit 1
fi

printf '%s\n' '[6/6] release mutation gate rejects an advanced main tip'
write_run "$EXPECTED_SHA" main push completed success 2
MAIN_SHA="$EXPECTED_SHA"
assert_release_gate
MAIN_SHA=1123456789abcdef0123456789abcdef01234567
if assert_release_gate >/dev/null 2>&1; then
    echo 'Release gate accepted an obsolete main tip.' >&2
    exit 1
fi

printf '%s\n' 'release gate regression: PASS'
