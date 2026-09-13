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
# These are current-candidate identities, not replacements for the historical
# owner receipt above. A new candidate must be reviewed and pinned explicitly.
CURRENT_VERSION = "7.2.5"
CURRENT_BUNDLE_SHA = "a2bebc2da7d67dd1db90c5e9dd6df21b195c9a8b356c9ceee892a042cfb8170f"
CURRENT_SYSTEM_SHA = "c901bae30a4249dfabce18b315ece76ca41dba0b3e348c3b74d3404ac7008c1f"
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


def check_release(root: Path, require_approved_policy: bool) -> dict[str, object]:
    version = read_regular(root, "version").decode("utf-8").splitlines()
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
