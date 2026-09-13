#!/usr/bin/env python3
"""Check the historical recovery receipt and an explicitly bounded release.

This does not contact any VPS or attest to public protocol connectivity. The
default mode can review an unapproved proposal. A release workflow must pass
--require-approved-policy; that mode refuses the proposal until the owner has
explicitly approved the replacement verification policy and its status has
been updated in a reviewed change. This file alone changes no release policy.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import stat
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


RECEIPT_PATH = "docs/audit/owner-recovery-v724.json"
VERSION = "7.2.4"
BUNDLE_SHA = "288b4977295cf8de08be08c22a0f678e584a25bb0c0c8218190002eeaf28bbba"
HISTORICAL_BUNDLE_PATH = "docs/audit/baselines/rr-vps-v7.2.4.tar.gz"
# Preserve these names and exact identities for the existing 7.2.5 verifier
# and its regression fixtures. They are NOT the latest-release identities,
# and do not replace the historical owner receipt above.
CURRENT_VERSION = "7.2.5"
CURRENT_BUNDLE_SHA = "a2bebc2da7d67dd1db90c5e9dd6df21b195c9a8b356c9ceee892a042cfb8170f"
CURRENT_SYSTEM_SHA = "c901bae30a4249dfabce18b315ece76ca41dba0b3e348c3b74d3404ac7008c1f"
PREVIOUS_BUNDLE_PATH = "docs/audit/baselines/rr-vps-v7.2.5.tar.gz"
PREVIOUS_GUARD_PATH = "docs/audit/baselines/update-guard-v725.sh"
PREVIOUS_GUARD_SHA = "2bbfdd8d80773cb48c19f11f91bbeb7ebd156f9419c30c5d81b3565aa346e64c"
PREVIOUS_CORE_PATH = "docs/audit/baselines/install-core-v725.sh"
PREVIOUS_CORE_SHA = "71969d44551d8899d8dc74b6cfae67f4fe5f3a26afe9a571279f857fa65081af"

# 7.2.6 identities are separate from BOTH historical recovery receipts.
# Pinned after the final 7.2.6 bundle was rebuilt and its bounded source
# changes were reviewed. Any later candidate requires explicit re-verification.
RELEASE_726_VERSION = "7.2.6"
RELEASE_726_BUNDLE_SHA = "aa1e5ca57dbc36e0ee860d75a9d59a42807db4de438740b10caa45b6fa6c9dd1"
RELEASE_726_FILE_SHAS = {
    "modules/10-system.sh": "4f0389eb8ecdbd7787323b43d0267485c740a4a88a3de598c855def2dc8c2492",
    "modules/20-config.sh": "2ff779bbd49f9c1e47be16255eda9e326c795b1ed6b8e8c01191fc18435c769f",
    "modules/55-resilience.sh": "0cb4c5df4d154daab6cf0093ca99fb601353e425211a93228e5728df7682d441",
    "modules/60-update.sh": "7686e11dff99117904e24d2a0ad8dcad0c0c0ac86c42211c67420634fc46c678",
    "scripts/update-recover.sh": "fb55d2c95dfd837ce798774b4abcb3cc0a683dd3c434259d658b882a1286095d",
    "scripts/update-external-state.py": "e39ab98e3027b782147fe51ab4f905b52af87d2210c98907aeeb59023883863e",
    "scripts/update-guard.sh": "2bbfdd8d80773cb48c19f11f91bbeb7ebd156f9419c30c5d81b3565aa346e64c",
    "scripts/install-core.sh": "3f38c66ee993470b7490ca6793f98559d1a67167a20aa0883ed583351f3e44ce",
    "install.sh": "383d08a6c4250450b6d03a9e57be97b9340ca16b5c39abec457ba86417821f98",
}
LA_RECEIPT_PATH = "docs/audit/owner-recovery-la721-20260913.json"
LA_HELPER_PATH = "scripts/recover-la721-firewall-inflight.py"
LA_HELPER_COMMIT = "081a6d684a1da440306bb32fd2413c4b2a4e82fb"
LA_HELPER_SHA = "abafb5c2e652adf998213d9179f5b1c610417aa19c136928cabbedbf2f54b1df"
LA_SCOPE = {
    "kind": "targeted-primary-server-firewall-recovery",
    "host_count": 1,
    "host": "DMIT-4AcBKDwTCc",
    "operating_system": "Ubuntu 24.04",
    "installed_version_before": "7.2.1",
    "installed_version_after": "7.2.1-with-local-health-hotfix",
    "public_protocol_connectivity": "not_reported",
    "client_subscription_use": "not_reported",
    "ci_executed_live_test": False,
    "not_claimed": [
        "three-host-live-tests", "complete-7.2.6-fresh-install",
        "complete-hot-update-to-7.2.6", "public-end-to-end-protocol-tests",
        "reboot-acceptance", "sustained-stability",
    ],
}
LA_PHASES = [
    "host", "writer_locks", "installed_identity", "transaction_state",
    "unchanged_firewall_evidence", "stopped_service_state", "backup",
    "prove_legacy_rule_equivalence", "read_only_policy_and_service_preflight",
    "stop_quarantine_guard", "health_observation_hotfix",
    "repair_subscription_loopback", "abort_unchanged_orphan",
    "restore_recorded_services", "postverify",
]
LA_COMPLETION = {
    "event": "LA721_RECOVERY_COMPLETE", "phase": "postverify",
    "backup": "<redacted>", "identities": "preserved",
    "firewall": "ipv4_loopback_20382_repaired",
    "persistence": "matching_loopback_repair", "health_timer": "disabled",
    "local_hotfix": "readonly-health-hop",
}
RELEASE_726_AUTHORIZATION = {
    "source": "owner-message-in-current-conversation",
    "reported_on": "2026-09-13",
    "quote": "整合修复发布7.2.6正式版。",
    "target_version": "7.2.6",
}


def shell_block(name: str, following: str) -> tuple[bytes, bytes, bytes]:
    begin = ("\n" + name + "() {\n").encode()
    return begin, begin, ("\n" + following + "() {\n").encode()


def python_block(name: str, following: str) -> tuple[bytes, bytes, bytes]:
    begin = ("\ndef " + name + "(").encode()
    return begin, begin, ("\ndef " + following + "(").encode()


# Each (old start, new start, common end) identifies a reviewed function block.
# Everything outside these exact, unique boundaries must remain byte-identical.
# Empty old blocks represent insertions immediately before their common end.
RELEASE_726_BLOCKS: dict[str, list[tuple[bytes, bytes, bytes]]] = {
    "modules/10-system.sh": [
        (b"\nrr_firewall_render_quarantine_guard_service() {\n",
         b"\n# The legacy template is accepted only by the migration preflight.",
         b"\nrr_firewall_render_quarantine_guard_path() {\n"),
        (b"\nrr_firewall_quarantine_supervisor_effective() {\n",
         b"\nrr_firewall_quarantine_supervisor_effective() {\n",
         b"\nrr_firewall_activate_quarantine_supervisor() {\n"),
        (b"\nrr_firewall_activate_quarantine_supervisor() {\n",
         b"\nrr_firewall_activate_quarantine_supervisor() {\n",
         b"\nrr_firewall_deactivate_quarantine_retry() {\n"),
        (b"\nrr_firewall_quarantine_supervisor_preflight_is_safe() {\n",
         b"\nrr_firewall_quarantine_supervisor_preflight_is_safe() {\n",
         b"\nrr_firewall_install_fail_closed_supervisor() {\n"),
        (b"\nrr_firewall_install_fail_closed_supervisor() {\n",
         b"\nrr_firewall_install_fail_closed_supervisor() {\n",
         b"\nrr_firewall_systemd_dropin_metadata_is_safe() {\n"),
        (b"\nrr_reconcile_ufw_protocol_rule() {\n",
         b"\n# Prove the first match for this one local subscription SYN.",
         b"\nrr_reconcile_ufw_protocol_rule() {\n"),
        shell_block("rr_reconcile_netfilter_protocol_rule", "rr_firewall_capture_ufw_protocol_state"),
        shell_block("rr_firewall_capture_netfilter_protocol_state", "rr_firewall_capture_protocol_transaction"),
        shell_block("rr_firewall_run_netfilter_saved_tuple", "rr_firewall_run_ufw_saved_tuple"),
        shell_block("rr_netfilter_rr_namespace_is_empty", "rr_filter_family_backends_are_complete"),
        shell_block("rr_reconcile_protocol_firewall_locked", "rr_validate_protocol_firewall"),
        shell_block("rr_local_subscription_loopback_ready", "rr_validate_local_subscription_firewall_transition"),
        shell_block("rr_validate_local_subscription_firewall_transition", "open_firewall"),
        shell_block("open_firewall", "open_protocol_firewall"),
        shell_block("rr_firewall_verify_desired_namespace", "rr_firewall_restore_quarantine_snapshot_locked"),
    ],
    "modules/55-resilience.sh": [
        shell_block("rr_doctor_repair_locked", "rr_doctor"),
        shell_block("rr_restore_filter_managed_firewall_rules", "rr_restore_capture_netfilter_rules"),
        shell_block("rr_restore_capture_netfilter_rules", "rr_restore_capture_netfilter_snapshot"),
        shell_block("rr_restore_capture_netfilter_snapshot", "rr_restore_filter_ufw_rules"),
        shell_block("rr_restore_run_netfilter_saved_rule", "rr_restore_run_ufw_saved_rule"),
        shell_block("rr_restore_normalize_full_firewall_program", "rr_restore_verify_firewall_snapshot"),
    ],
    "modules/60-update.sh": [
        (b"\nrr_finalize_committed_firewall() {\n",
         b"\nrr_update_firewall_migration_snapshot_is_current() {\n",
         b"\nrr_finalize_committed_firewall() {\n"),
        shell_block("post_update_migrate", "rr_certificate_reload_directory_is_exact"),
        shell_block("ensure_runtime_health", "rr_run_health_check"),
    ],
    "scripts/update-external-state.py": [
        (b"\nMANAGED_PATHS = (\n", b"\nLEGACY_MANAGED_PATHS = (\n", b"\nSERVICES = "),
        python_block("is_strict_rr_rule", "parse_rule"),
        (b"\ndef snapshot(", b"\ndef firewall_guard_state(", b"\ndef secure_snapshot_file("),
        python_block("load_snapshot", "remove_managed_path"),
        python_block("verify", "restore"),
        python_block("restore", "main"),
    ],
    "scripts/update-recover.sh": [
        shell_block("rr_restore_external_state_if_required", "rr_ip_acme_private_marker_is_exact"),
        shell_block("rr_restore_transaction", "main"),
    ],
}
RELEASE_726_EXACT_INSERTIONS = {
    "modules/20-config.sh": [
        '''        if [ "$access_mode" = local ] && ! rr_local_subscription_loopback_ready; then
            printf '%s\\n' '[错误] 订阅进程存在，但本机 TCP 连接失败；请修复本机订阅防火墙路径。' >&2
            return 1
        fi
'''.encode(),
        '''    if [ "$access_mode" = local ] && ! rr_local_subscription_loopback_ready; then
        printf '%s\\n' '[错误] 订阅已监听，但本机 TCP 连接失败；启动未通过验收。' >&2
        return 1
    fi
'''.encode(),
    ],
}
RELEASE_726_CORE_BLOCKS: list[tuple[bytes, bytes, bytes]] = [
    shell_block("rr_rollback", "rr_republish_retryable_update_phase"),
    shell_block("rr_install_restore_external_state_if_required", "rr_capture_update_writer_state"),
]
HELPER_PATH = "scripts/repair-v723-naive-first-install.sh"
HELPER_COMMIT = "87ba6798b229c57b5434f7ac16d6e161d326f64d"
HELPER_SHA = "5d3ee4294126212aac54b532ca5165cb0ee8a1757483f69aa88d4cf0cd24ba0e"
INSTALLED_MANIFEST_SHA = "87d5f85a0a4232882c97b54adbd49dfdc93b79beeca77fb59ee873aee366ce64"
MODULES = {
    "modules/10-system.sh": {
        "source_commit": "32404ee182bb19a8084ab2423d336e8ec90994e0",
        "sha256": "76dd751658ab07ed5c009dcd25899bd2fc96b94cb442a2a0db7543483a4d7055",
    },
    "modules/30-singbox.sh": {
        "source_commit": "cfeda272431beaffd03568c7a80c6934927f826a",
        "sha256": "dfd6929c22576a49eff09a4c931a958c410225b009f9d96a5679371d8c3ee566",
    },
}
SCOPE = {
    "kind": "targeted-first-install-recovery",
    "operating_system": "Debian GNU/Linux 12",
    "host_count": 1,
    "installed_version_before": "7.2.3",
    "installed_version_after": "7.2.3",
    "nexus": "not_installed",
    "public_protocol_connectivity": "not_reported",
    "ci_executed_live_test": False,
    "not_claimed": [
        "three-host-live-tests",
        "complete-7.2.4-fresh-install",
        "complete-hot-update-to-7.2.4",
        "public-end-to-end-protocol-tests",
        "primary-server-hot-update-tests",
    ],
}
SUCCESS_LINES = [
    "FIREWALL_RECOVERY_COMPLETE configuration=unchanged nodes=inactive nexus=not_installed backup=<redacted>",
    "CANDIDATE_OWNERSHIP_CHECK_OK source=" + MODULES["modules/30-singbox.sh"]["source_commit"],
    "REPAIR_PATCH_SOURCE commit=" + MODULES["modules/30-singbox.sh"]["source_commit"]
    + " module_sha256=" + MODULES["modules/30-singbox.sh"]["sha256"] + " installed_version=7.2.3",
    "REPAIR_COMPLETE version=7.2.3 identities=preserved nexus=not_installed",
]


class Refusal(ValueError):
    pass


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise Refusal(reason)


def exact(value: object, expected: object, reason: str) -> None:
    if isinstance(expected, bytes):
        require(type(value) is bytes and value == expected, reason)
        return
    # JSON equality is type-sensitive here: true must not pass as host_count=1.
    require(json.dumps(value, sort_keys=True) == json.dumps(expected, sort_keys=True), reason)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def read_regular(root: Path, relative: str) -> bytes:
    pieces = PurePosixPath(relative).parts
    require(bool(pieces) and not relative.startswith("/") and ".." not in pieces, "unsafe_path")
    current = root
    for index, piece in enumerate(pieces):
        current /= piece
        info = current.lstat()
        require(not stat.S_ISLNK(info.st_mode), "symlink_path")
        require(stat.S_ISREG(info.st_mode) if index == len(pieces) - 1 else stat.S_ISDIR(info.st_mode),
                "unexpected_file_type")
    return current.read_bytes()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_receipt(root: Path, require_approved_policy: bool) -> dict[str, object]:
    evidence = json.loads(read_regular(root, RECEIPT_PATH), object_pairs_hook=unique_object)
    require(type(evidence) is dict, "receipt_not_object")
    exact(sorted(evidence), sorted([
        "schema", "policy_status", "source", "reported_on", "scope", "candidate",
        "recovery_helper", "receipt", "limitation",
    ]), "receipt_schema_keys")
    exact(evidence["schema"], "rr-owner-recovery-evidence-v1", "receipt_schema")
    require(evidence["policy_status"] in ("proposal-awaiting-owner-confirmation", "owner-approved"),
            "unknown_policy_status")
    exact(evidence["source"], "owner-provided-terminal-output", "receipt_source")
    exact(evidence["reported_on"], "2026-09-10", "receipt_date")
    exact(evidence["scope"], SCOPE, "unsupported_scope")
    exact(evidence["candidate"], {
        "target_version": VERSION, "bundle_sha256": BUNDLE_SHA, "modules": MODULES,
    }, "candidate_binding")
    exact(evidence["recovery_helper"], {
        "path": HELPER_PATH, "source_commit": HELPER_COMMIT, "sha256": HELPER_SHA,
        "required_installed_manifest_sha256": INSTALLED_MANIFEST_SHA,
    }, "helper_binding")
    exact(evidence["receipt"], {
        "format": "ordered-final-success-lines",
        "redaction": "Only the private backup path on the firewall completion line is replaced with <redacted>.",
        "lines": SUCCESS_LINES,
    }, "receipt_success_lines")
    exact(evidence["limitation"],
          "This validates an owner-reported receipt and source/artifact consistency, not a CI-executed VPS test.",
          "receipt_limitation")

    version_lines = read_regular(root, "version").decode("utf-8").splitlines()
    require(bool(version_lines) and version_lines[0] == "RR-vps " + VERSION, "repository_version")
    runtime = read_regular(root, "modules/00-runtime.sh").decode("utf-8")
    exact(re.findall(r'^SCRIPT_VERSION="([^"\n]+)"$', runtime, re.MULTILINE), [VERSION],
          "runtime_version")
    helper_bytes = read_regular(root, HELPER_PATH)
    exact(digest(helper_bytes), HELPER_SHA, "helper_file_sha256")
    helper = helper_bytes.decode("utf-8")
    pins = {
        "repair_candidate_commit": MODULES["modules/30-singbox.sh"]["source_commit"],
        "repair_candidate_module_sha256": MODULES["modules/30-singbox.sh"]["sha256"],
        "repair_firewall_candidate_commit": MODULES["modules/10-system.sh"]["source_commit"],
        "repair_firewall_candidate_sha256": MODULES["modules/10-system.sh"]["sha256"],
    }
    for name, expected in pins.items():
        exact(re.findall(r"^" + name + r"='([^'\n]+)'$", helper, re.MULTILINE), [expected], "helper_source_pin")
    exact(re.findall(r"^    assert hashlib.sha256\(manifest\).hexdigest\(\) == '([0-9a-f]{64})'$",
                     helper, re.MULTILINE), [INSTALLED_MANIFEST_SHA], "installed_manifest_pin")
    for path, identity in MODULES.items():
        exact(digest(read_regular(root, path)), identity["sha256"], "candidate_module_sha256")

    bundle = read_regular(root, "rr-bundle.tar.gz")
    exact(digest(bundle), BUNDLE_SHA, "candidate_bundle_sha256")
    # The pinned archive also binds all other payload files: updating unrelated
    # runtime source cannot silently reuse this older evidence/bundle pair.
    manifest = read_regular(root, "manifest.sha256")
    with tarfile.open(fileobj=io.BytesIO(bundle), mode="r:gz") as archive:
        archived_manifest = archive.extractfile("rr-bundle/manifest.sha256")
        require(archived_manifest is not None, "bundle_manifest_missing")
        exact(manifest, archived_manifest.read(), "bundle_manifest_mismatch")
        paths = set()
        for line in manifest.decode("utf-8").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_./-]+)", line)
            require(match is not None, "manifest_entry")
            expected, path = match.groups()
            require(path not in paths, "duplicate_manifest_path")
            paths.add(path)
            exact(digest(read_regular(root, path)), expected, "payload_file_sha256")
            archived_file = archive.extractfile("rr-bundle/" + path)
            require(archived_file is not None, "bundle_payload_missing")
            exact(digest(archived_file.read()), expected, "bundle_payload_sha256")
        require(set(MODULES).issubset(paths), "modules_missing_from_payload")

    if require_approved_policy:
        exact(evidence["policy_status"], "owner-approved", "replacement_policy_not_owner_approved")
    return {
        "event": "OWNER_RECOVERY_CONTENT_VERIFIED",
        "source": evidence["source"],
        "policy_status": evidence["policy_status"],
        "required_approved_policy": require_approved_policy,
        "target_version": VERSION,
        "bundle_sha256": BUNDLE_SHA,
        "scope": SCOPE,
        "notice": "Receipt/source consistency only; no VPS or public protocol test was executed by this command.",
    }


def archive_payload(bundle: bytes) -> dict[str, bytes]:
    """Read only regular, unique manifest-bound files; never extract paths."""
    files = {}
    with tarfile.open(fileobj=io.BytesIO(bundle), mode="r:gz") as archive:
        for member in archive.getmembers():
            require(member.isreg() and not member.pax_headers, "archive_member_type")
            require(re.fullmatch(r"rr-bundle/[A-Za-z0-9_./-]+", member.name) is not None,
                    "archive_member_path")
            path = member.name.removeprefix("rr-bundle/")
            parts = PurePosixPath(path).parts
            require(bool(parts) and not PurePosixPath(path).is_absolute()
                    and path == PurePosixPath(path).as_posix() and ".." not in parts,
                    "archive_member_path")
            require(path not in files, "archive_duplicate_member")
            source = archive.extractfile(member)
            require(source is not None, "archive_member_missing")
            files[path] = source.read()
    require("manifest.sha256" in files, "archive_manifest_missing")
    paths = set()
    for line in files["manifest.sha256"].decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_./-]+)", line)
        require(match is not None, "archive_manifest_entry")
        expected, path = match.groups()
        require(path not in paths and path != "manifest.sha256", "archive_manifest_duplicate")
        paths.add(path)
        require(path in files, "archive_payload_missing")
        exact(digest(files[path]), expected, "archive_payload_sha256")
    exact(sorted(files), sorted(paths | {"manifest.sha256"}), "archive_payload_inventory")
    return files


def materialize_historical_root(root: Path, destination: Path) -> dict[str, bytes]:
    """Rebuild the fixed 7.2.4 fixture without trusting the current payload."""
    bundle = read_regular(root, HISTORICAL_BUNDLE_PATH)
    exact(digest(bundle), BUNDLE_SHA, "historical_bundle_sha256")
    files = archive_payload(bundle)
    # The caller creates an isolated empty TemporaryDirectory. Writing explicit
    # validated regular members avoids extractall, links, devices and traversal.
    require(destination.is_dir() and not any(destination.iterdir()), "historical_destination")
    material = dict(files)
    material.update({
        "rr-bundle.tar.gz": bundle,
        "version": ("RR-vps " + VERSION + "\n").encode(),
        HELPER_PATH: read_regular(root, HELPER_PATH),
        RECEIPT_PATH: read_regular(root, RECEIPT_PATH),
    })
    for path, data in material.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
    return files


def unchanged_outside_cloudflared(before: bytes, after: bytes) -> None:
    before_start = b"\ninstall_cloudflared() {\n"
    after_start = b"\nrr_cloudflared_fallback_release() {\n"
    end = b"\nrr_ufw_backend_state() {\n"
    require(before.count(before_start) == after.count(after_start) == 1
            and before.count(end) == after.count(end) == 1, "cloudflared_change_boundaries")
    before_prefix, before_body = before.split(before_start)
    after_prefix, after_body = after.split(after_start)
    exact(before_prefix, after_prefix, "system_changes_before_cloudflared")
    require(end in before_body and end in after_body, "cloudflared_change_boundaries")
    exact(before_body.split(end)[1], after_body.split(end)[1],
          "system_changes_after_cloudflared")


def check_current_release(root: Path, require_approved_policy: bool) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="rr-recovery-baseline.") as temporary:
        historical_root = Path(temporary)
        historical = materialize_historical_root(root, historical_root)
        # Keep every original receipt/helper/module/bundle check and approval
        # requirement. The returned evidence remains explicitly about 7.2.4.
        receipt = check_receipt(historical_root, require_approved_policy)

    version_lines = read_regular(root, "version").decode("utf-8").splitlines()
    require(bool(version_lines) and version_lines[0] == "RR-vps " + CURRENT_VERSION,
            "current_repository_version")
    runtime = read_regular(root, "modules/00-runtime.sh")
    before_version = ('SCRIPT_VERSION="' + VERSION + '"').encode()
    after_version = ('SCRIPT_VERSION="' + CURRENT_VERSION + '"').encode()
    require(historical["modules/00-runtime.sh"].count(before_version) == 1,
            "historical_runtime_version")
    exact(runtime, historical["modules/00-runtime.sh"].replace(before_version, after_version),
          "current_runtime_change_scope")

    system = read_regular(root, "modules/10-system.sh")
    unchanged_outside_cloudflared(historical["modules/10-system.sh"], system)
    exact(digest(system), CURRENT_SYSTEM_SHA, "current_system_sha256")
    bundle = read_regular(root, "rr-bundle.tar.gz")
    exact(digest(bundle), CURRENT_BUNDLE_SHA, "current_bundle_sha256")
    current = archive_payload(bundle)
    exact(sorted(current), sorted(historical), "current_payload_inventory")
    exact(read_regular(root, "manifest.sha256"), current["manifest.sha256"],
          "current_manifest_mismatch")
    allowed = {"manifest.sha256", "modules/00-runtime.sh", "modules/10-system.sh"}
    for path, archived in current.items():
        local = read_regular(root, path)
        exact(local, archived, "current_payload_file_mismatch")
        if path not in allowed:
            exact(local, historical[path], "current_change_outside_scope")

    return {
        "event": "RELEASE_CHANGE_CONTENT_VERIFIED",
        "target_version": CURRENT_VERSION,
        "bundle_sha256": CURRENT_BUNDLE_SHA,
        "system_sha256": CURRENT_SYSTEM_SHA,
        "required_approved_policy": require_approved_policy,
        "historical_evidence": receipt,
        "change_scope": ["runtime-version-line", "cloudflared-download-functions"],
        "current_live_acceptance": "not_reported",
        "ci_executed_live_test": False,
        "notice": "Historical 7.2.3 recovery receipt preserved; current release hashes and restricted source changes verified. No 7.2.5 AWS installation, VPS test or public protocol test is attested. Full exact-commit CI is an independent mandatory release gate.",
    }


def materialize_previous_root(root: Path, destination: Path) -> dict[str, bytes]:
    """Keep the complete original 7.2.5 checks against its fixed release bytes."""
    bundle = read_regular(root, PREVIOUS_BUNDLE_PATH)
    exact(digest(bundle), CURRENT_BUNDLE_SHA, "previous_bundle_sha256")
    files = archive_payload(bundle)
    require(destination.is_dir() and not any(destination.iterdir()), "previous_destination")
    material = dict(files)
    material.update({
        "rr-bundle.tar.gz": bundle,
        "version": ("RR-vps " + CURRENT_VERSION + "\n").encode(),
        HELPER_PATH: read_regular(root, HELPER_PATH),
        RECEIPT_PATH: read_regular(root, RECEIPT_PATH),
        HISTORICAL_BUNDLE_PATH: read_regular(root, HISTORICAL_BUNDLE_PATH),
    })
    for path, data in material.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
    return files


def check_la_receipt(root: Path, require_approved_policy: bool) -> dict[str, object]:
    evidence = json.loads(read_regular(root, LA_RECEIPT_PATH), object_pairs_hook=unique_object)
    require(type(evidence) is dict, "la_receipt_not_object")
    exact(sorted(evidence), sorted([
        "schema", "source", "reported_on", "scope", "recovery_helper", "receipt",
        "limitation", "release_policy_status", "release_authorization",
    ]), "la_receipt_schema_keys")
    exact(evidence["schema"], "rr-owner-la721-recovery-evidence-v1", "la_receipt_schema")
    exact(evidence["source"], "owner-provided-terminal-output", "la_receipt_source")
    exact(evidence["reported_on"], "2026-09-13", "la_receipt_date")
    exact(evidence["scope"], LA_SCOPE, "la_unsupported_scope")
    exact(evidence["recovery_helper"], {
        "path": LA_HELPER_PATH, "source_commit": LA_HELPER_COMMIT,
        "sha256": LA_HELPER_SHA, "arguments": ["--repair-loopback"],
    }, "la_helper_binding")
    exact(digest(read_regular(root, LA_HELPER_PATH)), LA_HELPER_SHA, "la_helper_file_sha256")
    exact(evidence["receipt"], {
        "format": "ordered-phase-checks-and-final-completion",
        "redaction": "The private backup path in the final completion event is replaced with <redacted>. Repeated informational events are omitted; all phase checks are retained in order.",
        "phase_checks": [{"event": "RECOVERY_CHECK", "phase": phase, "result": "PASS"}
                         for phase in LA_PHASES],
        "completion": LA_COMPLETION,
        "completion_order": "after_restore_recorded_services_check_before_postverify_check",
    }, "la_receipt_success_events")
    exact(evidence["limitation"],
          "Owner-reported recovery of 7.2.1 with a local hotfix, not a CI-executed VPS test or a 7.2.6 installation/upgrade receipt.",
          "la_receipt_limitation")
    require(evidence["release_policy_status"] in
            ("proposal-awaiting-owner-confirmation", "owner-approved"), "la_unknown_policy_status")
    exact(evidence["release_authorization"], RELEASE_726_AUTHORIZATION, "release_726_authorization")
    if require_approved_policy:
        exact(evidence["release_policy_status"], "owner-approved", "release_726_policy_not_owner_approved")
    return {
        "event": "LA721_OWNER_RECOVERY_CONTENT_VERIFIED", "source": evidence["source"],
        "scope": LA_SCOPE, "helper_sha256": LA_HELPER_SHA,
        "completion": LA_COMPLETION,
        "release_authorization": evidence["release_authorization"],
        "release_policy_status": evidence["release_policy_status"],
        "notice": "The owner recovered 7.2.1 with a local hotfix; this receipt does not attest to installation or upgrade of 7.2.6.",
    }


def unchanged_outside_blocks(before: bytes, after: bytes,
                             blocks: list[tuple[bytes, bytes, bytes]]) -> None:
    """Compare all bytes outside explicit unique reviewed boundary pairs.

    Source is never executed or parsed as trusted shell. Unique anchors and
    nonoverlap are checked independently on both sides before masking. Exact
    candidate hashes additionally seal the code *inside* each allowed block.
    """
    def masked(source: bytes, side: int) -> bytes:
        spans = []
        for index, block in enumerate(blocks):
            begin, end = block[side], block[2]
            require(source.count(begin) == source.count(end) == 1, "release_726_change_boundaries")
            start, stop = source.index(begin), source.index(end)
            require(start < stop or (side == 0 and begin == end), "release_726_change_boundaries")
            spans.append((start, stop, index))
        spans.sort()
        cursor = 0
        result = bytearray()
        for start, stop, index in spans:
            require(start >= cursor, "release_726_overlapping_boundaries")
            result.extend(source[cursor:start])
            result.extend(("<reviewed-block-" + str(index) + ">").encode())
            cursor = stop
        result.extend(source[cursor:])
        return bytes(result)
    exact(masked(before, 0), masked(after, 1), "release_726_change_outside_function_scope")


def check_726_release(root: Path, require_approved_policy: bool) -> dict[str, object]:
    # Neither old evidence nor old approval is overwritten by the new release.
    with tempfile.TemporaryDirectory(prefix="rr-recovery-725-baseline.") as temporary:
        previous_root = Path(temporary)
        previous = materialize_previous_root(root, previous_root)
        previous_result = check_current_release(previous_root, require_approved_policy)
    la_result = check_la_receipt(root, require_approved_policy)
    version_lines = read_regular(root, "version").decode("utf-8").splitlines()
    require(bool(version_lines) and version_lines[0] == "RR-vps " + RELEASE_726_VERSION,
            "release_726_repository_version")
    before_version = ('SCRIPT_VERSION="' + CURRENT_VERSION + '"').encode()
    after_version = ('SCRIPT_VERSION="' + RELEASE_726_VERSION + '"').encode()
    require(previous["modules/00-runtime.sh"].count(before_version) == 1, "previous_runtime_version")
    exact(read_regular(root, "modules/00-runtime.sh"),
          previous["modules/00-runtime.sh"].replace(before_version, after_version),
          "release_726_runtime_change_scope")
    guard = read_regular(root, PREVIOUS_GUARD_PATH)
    exact(digest(guard), PREVIOUS_GUARD_SHA, "previous_guard_sha256")
    before_files = {**previous, "scripts/update-guard.sh": guard}
    for path, blocks in RELEASE_726_BLOCKS.items():
        require(path in before_files, "release_726_scope_unknown_path")
        unchanged_outside_blocks(before_files[path], read_regular(root, path), blocks)
    for path, insertions in RELEASE_726_EXACT_INSERTIONS.items():
        source = read_regular(root, path)
        for insertion in insertions:
            require(source.count(insertion) == 1, "release_726_exact_insertion")
            source = source.replace(insertion, b"")
        exact(source, before_files[path], "release_726_change_outside_function_scope")
    if "scripts/update-guard.sh" not in RELEASE_726_BLOCKS:
        exact(read_regular(root, "scripts/update-guard.sh"), guard,
              "release_726_guard_change_scope")
    require(re.fullmatch(r"[0-9a-f]{64}", RELEASE_726_BUNDLE_SHA) is not None
            and all(re.fullmatch(r"[0-9a-f]{64}", value) is not None
                    for value in RELEASE_726_FILE_SHAS.values()), "release_726_candidate_not_pinned")
    # Normalize generated tag/digest lines before checking the explicitly
    # bounded inline rollback correction. Rebuild check remains mandatory.
    previous_core = read_regular(root, PREVIOUS_CORE_PATH)
    exact(digest(previous_core), PREVIOUS_CORE_SHA, "previous_core_sha256")
    core = read_regular(root, "scripts/install-core.sh")
    core_tag = b'RR_RELEASE_TAG="v7.2.6"'
    core_bundle = RELEASE_726_BUNDLE_SHA.encode()
    require(core.count(core_tag) == 1, "release_726_core_version")
    require(core.count(core_bundle) == 1, "release_726_core_bundle_binding")
    normalized_core = core.replace(core_tag, b'RR_RELEASE_TAG="v7.2.5"').replace(
        core_bundle, CURRENT_BUNDLE_SHA.encode())
    try:
        unchanged_outside_blocks(previous_core, normalized_core, RELEASE_726_CORE_BLOCKS)
    except Refusal as error:
        raise Refusal("release_726_core_change_scope") from error
    for path, expected in RELEASE_726_FILE_SHAS.items():
        exact(digest(read_regular(root, path)), expected, "release_726_candidate_file_sha256")
    bundle = read_regular(root, "rr-bundle.tar.gz")
    exact(digest(bundle), RELEASE_726_BUNDLE_SHA, "release_726_bundle_sha256")
    current = archive_payload(bundle)
    exact(sorted(current), sorted(previous), "release_726_payload_inventory")
    exact(read_regular(root, "manifest.sha256"), current["manifest.sha256"],
          "release_726_manifest_mismatch")
    allowed = ({"manifest.sha256", "modules/00-runtime.sh"}
               | set(RELEASE_726_BLOCKS) | set(RELEASE_726_EXACT_INSERTIONS))
    for path, archived in current.items():
        local = read_regular(root, path)
        exact(local, archived, "release_726_payload_file_mismatch")
        if path not in allowed:
            exact(local, previous[path], "release_726_change_outside_scope")
    return {
        "event": "RELEASE_CHANGE_CONTENT_VERIFIED", "target_version": RELEASE_726_VERSION,
        "bundle_sha256": RELEASE_726_BUNDLE_SHA, "file_sha256": RELEASE_726_FILE_SHAS,
        "required_approved_policy": require_approved_policy,
        "historical_evidence": previous_result["historical_evidence"],
        "previous_release_evidence": previous_result, "la721_recovery_evidence": la_result,
        "change_scope": ["version-and-generated-bootstrap", "readonly-health-hop",
                         "local-subscription-loopback-and-upgrade-migration",
                         "quarantine-guard-lifecycle-and-strict-legacy-migration",
                         "related-upgrade-snapshot-and-rollback",
                         "backup-and-doctor-local-rule-ownership"],
        "current_live_acceptance": "not_reported", "ci_executed_live_test": False,
        "notice": "Historical Debian 7.2.3 and LA 7.2.1 recovery receipts are preserved separately. Current candidate hashes and bounded changes are verified; no 7.2.6 VPS installation, upgrade or client connectivity is attested. Full exact-commit CI is an independent mandatory release gate.",
    }


def check_release(root: Path, require_approved_policy: bool) -> dict[str, object]:
    version = read_regular(root, "version").decode("utf-8").splitlines()
    if version and version[0] == "RR-vps " + RELEASE_726_VERSION:
        return check_726_release(root, require_approved_policy)
    if version and version[0] == "RR-vps " + CURRENT_VERSION:
        return check_current_release(root, require_approved_policy)
    # Existing 7.2.4 --root fixtures retain the original checks and reasons;
    # unsupported future versions continue to fail its repository-version check.
    return check_receipt(root, require_approved_policy)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--require-approved-policy", action="store_true")
    args = parser.parse_args()
    try:
        result = check_release(args.root.resolve(), args.require_approved_policy)
    except (Refusal, OSError, UnicodeError, json.JSONDecodeError, tarfile.TarError, KeyError, TypeError) as error:
        # Do not echo arbitrary receipt text, local paths, or file contents.
        reason = str(error) if isinstance(error, Refusal) else type(error).__name__
        print(json.dumps({"event": "OWNER_RECOVERY_CONTENT_REFUSED", "reason": reason}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
