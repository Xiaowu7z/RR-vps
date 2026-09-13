#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Unprivileged content-validation fixtures only. No server, installation,
# firewall, systemd, or network operations. The approved-policy fixture below
# simulates a future reviewed approval; it is not actual owner authorization.
python3 - "$repo" <<'PY'
import copy
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

repo = Path(sys.argv[1])
validator = repo / 'scripts/verify-owner-recovery-evidence.py'
spec = importlib.util.spec_from_file_location('owner_recovery_validator', validator)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
receipt_path = 'docs/audit/owner-recovery-v724.json'
source_receipt = (repo / receipt_path).read_bytes()
evidence = json.loads(source_receipt)
# Exercise both policy states even after a later reviewed approval. Mutate only
# the fixture template; preserve the repository's actual receipt byte for byte.
evidence['policy_status'] = 'proposal-awaiting-owner-confirmation'
count = 0

with tempfile.TemporaryDirectory(prefix='rr-owner-evidence-tests.') as temporary:
    baseline = Path(temporary) / 'baseline'
    baseline.mkdir()
    # Preserve all original 32 receipt cases against the actual immutable
    # historical payload, even while the current release advances to 7.2.5.
    checker.materialize_historical_root(repo, baseline)

    def run(name, *, mutate_data=None, mutate_files=None, approved_mode=False,
            expected_reason=None):
        global count
        current = Path(temporary) / name
        shutil.copytree(baseline, current)
        data = copy.deepcopy(evidence)
        if mutate_data is not None:
            mutate_data(data)
        (current / receipt_path).write_text(json.dumps(data))
        if mutate_files is not None:
            mutate_files(current)
        command = [sys.executable, str(validator), '--root', str(current)]
        if approved_mode:
            command.append('--require-approved-policy')
        result = subprocess.run(command, capture_output=True, text=True)
        if expected_reason is None:
            assert result.returncode == 0, (name, result.stderr)
            assert not result.stderr, (name, result.stderr)
            output = json.loads(result.stdout)
            assert output['event'] == 'OWNER_RECOVERY_CONTENT_VERIFIED', name
            assert output['source'] == 'owner-provided-terminal-output', name
            assert output['scope']['host_count'] == 1, name
            assert output['scope']['installed_version_after'] == '7.2.3', name
            assert output['scope']['public_protocol_connectivity'] == 'not_reported', name
            assert output['scope']['ci_executed_live_test'] is False, name
            assert output['required_approved_policy'] is approved_mode, name
            assert output['policy_status'] == data['policy_status'], name
        else:
            assert result.returncode == 1, (name, result.returncode, result.stdout, result.stderr)
            assert not result.stdout, (name, result.stdout)
            output = json.loads(result.stderr)
            assert output['event'] == 'OWNER_RECOVERY_CONTENT_REFUSED', name
            assert output['reason'] == expected_reason, (name, output)
        count += 1
        print('PASS ' + name)

    def append(path):
        def change(root):
            target = root / path
            target.write_bytes(target.read_bytes() + b'\n')
        return change

    def approved(data):
        # Simulation confined to a disposable fixture. Never writes source receipt.
        data['policy_status'] = 'owner-approved'

    run('proposal_content_review')
    run('proposal_cannot_open_release_gate', approved_mode=True,
        expected_reason='replacement_policy_not_owner_approved')
    run('simulated_future_approved_policy', mutate_data=approved, approved_mode=True)
    run('missing_receipt', mutate_files=lambda root: (root / receipt_path).unlink(),
        expected_reason='FileNotFoundError')
    run('malformed_receipt', mutate_files=lambda root: (root / receipt_path).write_text('{'),
        expected_reason='JSONDecodeError')
    run('duplicate_json_key', mutate_files=lambda root: (root / receipt_path).write_text(
        (root / receipt_path).read_text().replace('{', '{"policy_status":"owner-approved",', 1)),
        expected_reason='duplicate_json_key')
    run('repository_version_changed', mutate_files=lambda root: (root / 'version').write_text('RR-vps 7.2.6\n'),
        expected_reason='repository_version')
    run('runtime_version_changed', mutate_files=lambda root: (root / 'modules/00-runtime.sh').write_text(
        (root / 'modules/00-runtime.sh').read_text().replace('SCRIPT_VERSION="7.2.4"', 'SCRIPT_VERSION="7.2.5"')),
        expected_reason='runtime_version')
    run('receipt_target_version_changed', mutate_data=lambda data: data['candidate'].update(target_version='7.2.5'),
        expected_reason='candidate_binding')
    run('receipt_bundle_hash_changed', mutate_data=lambda data: data['candidate'].update(bundle_sha256='0' * 64),
        expected_reason='candidate_binding')
    run('bundle_bytes_changed', mutate_files=append('rr-bundle.tar.gz'),
        expected_reason='candidate_bundle_sha256')
    for name in ('10-system', '30-singbox'):
        run(name + '_module_bytes_changed', mutate_files=append('modules/' + name + '.sh'),
            expected_reason='candidate_module_sha256')
    run('helper_pin_changed', mutate_files=lambda root: (root / 'scripts/repair-v723-naive-first-install.sh').write_text(
        (root / 'scripts/repair-v723-naive-first-install.sh').read_text().replace(
            "repair_firewall_candidate_commit='32404ee182bb19a8084ab2423d336e8ec90994e0'",
            "repair_firewall_candidate_commit='" + '0' * 40 + "'")),
        expected_reason='helper_file_sha256')
    run('receipt_helper_commit_changed', mutate_data=lambda data: data['recovery_helper'].update(source_commit='0' * 40),
        expected_reason='helper_binding')
    run('receipt_installed_manifest_changed', mutate_data=lambda data: data['recovery_helper'].update(
        required_installed_manifest_sha256='0' * 64), expected_reason='helper_binding')
    run('manifest_bytes_changed', mutate_files=append('manifest.sha256'),
        expected_reason='bundle_manifest_mismatch')
    run('other_runtime_file_changed', mutate_files=append('modules/20-config.sh'),
        expected_reason='payload_file_sha256')
    run('claims_three_hosts', mutate_data=lambda data: data['scope'].update(host_count=3),
        expected_reason='unsupported_scope')
    run('boolean_cannot_replace_host_count', mutate_data=lambda data: data['scope'].update(host_count=True),
        expected_reason='unsupported_scope')
    run('claims_complete_hot_update', mutate_data=lambda data: data['scope'].update(installed_version_after='7.2.4'),
        expected_reason='unsupported_scope')
    run('claims_public_protocol_test', mutate_data=lambda data: data['scope'].update(public_protocol_connectivity='passed'),
        expected_reason='unsupported_scope')
    run('claims_ci_executed_live_test', mutate_data=lambda data: data['scope'].update(ci_executed_live_test=True),
        expected_reason='unsupported_scope')
    run('claims_ci_source', mutate_data=lambda data: data.update(source='ci-vps-test'),
        expected_reason='receipt_source')
    run('missing_completion_line', mutate_data=lambda data: data['receipt']['lines'].pop(),
        expected_reason='receipt_success_lines')
    run('prefix_spoofs_success', mutate_data=lambda data: data['receipt']['lines'].__setitem__(
        3, 'NOT_SUCCESS ' + data['receipt']['lines'][3]), expected_reason='receipt_success_lines')
    run('failure_mixed_into_receipt', mutate_data=lambda data: data['receipt']['lines'].append(
        'REPAIR_STOP phase=complete rc=1'), expected_reason='receipt_success_lines')
    run('out_of_order_completion', mutate_data=lambda data: data['receipt']['lines'].reverse(),
        expected_reason='receipt_success_lines')
    run('extra_unverified_claim', mutate_data=lambda data: data.update(three_host_test='passed'),
        expected_reason='receipt_schema_keys')
    run('approved_does_not_allow_broader_scope', approved_mode=True,
        mutate_data=lambda data: (approved(data), data['scope'].update(host_count=3)),
        expected_reason='unsupported_scope')
    run('approved_does_not_allow_missing_completion', approved_mode=True,
        mutate_data=lambda data: (approved(data), data['receipt']['lines'].pop()),
        expected_reason='receipt_success_lines')
    run('approved_does_not_allow_changed_payload', approved_mode=True, mutate_data=approved,
        mutate_files=append('rr-bundle.tar.gz'), expected_reason='candidate_bundle_sha256')

    current_baseline = Path(temporary) / 'current-baseline'
    current_paths = [line.split('  ', 1)[1] for line in (repo / 'manifest.sha256').read_text().splitlines()]
    current_paths += ['manifest.sha256', 'rr-bundle.tar.gz', 'version', checker.HELPER_PATH,
                     checker.HISTORICAL_BUNDLE_PATH, receipt_path]
    for path in current_paths:
        target = current_baseline / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / path, target)

    def run_current(name, *, mutate_data=None, mutate_files=None, approved_mode=True,
                    expected_reason=None):
        global count
        current = Path(temporary) / name
        shutil.copytree(current_baseline, current)
        if mutate_data is not None:
            data = json.loads((current / receipt_path).read_bytes())
            mutate_data(data)
            (current / receipt_path).write_text(json.dumps(data))
        if mutate_files is not None:
            mutate_files(current)
        command = [sys.executable, str(validator), '--root', str(current)]
        if approved_mode:
            command.append('--require-approved-policy')
        result = subprocess.run(command, capture_output=True, text=True)
        if expected_reason is None:
            assert result.returncode == 0 and not result.stderr, (name, result.stderr)
            output = json.loads(result.stdout)
            assert output['event'] == 'RELEASE_CHANGE_CONTENT_VERIFIED', name
            assert output['target_version'] == '7.2.5', name
            assert output['bundle_sha256'] == checker.CURRENT_BUNDLE_SHA, name
            assert output['current_live_acceptance'] == 'not_reported', name
            assert output['ci_executed_live_test'] is False, name
            assert output['required_approved_policy'] is approved_mode, name
            historical = output['historical_evidence']
            assert historical['event'] == 'OWNER_RECOVERY_CONTENT_VERIFIED', name
            assert historical['target_version'] == '7.2.4', name
            assert historical['bundle_sha256'] == checker.BUNDLE_SHA, name
            assert historical['scope'] == checker.SCOPE, name
            assert historical['scope']['installed_version_after'] == '7.2.3', name
        else:
            assert result.returncode == 1 and not result.stdout, (name, result.stdout, result.stderr)
            output = json.loads(result.stderr)
            assert output['event'] == 'OWNER_RECOVERY_CONTENT_REFUSED', name
            assert output['reason'] == expected_reason, (name, output)
        count += 1
        print('PASS ' + name)

    def symlink(path):
        def change(root):
            target = root / path
            moved = target.with_name(target.name + '.original')
            target.rename(moved)
            target.symlink_to(moved.name)
        return change

    run_current('725_current_hashes_and_historical_receipt')
    run_current('725_proposal_content_review', approved_mode=False,
                mutate_data=lambda data: data.update(policy_status='proposal-awaiting-owner-confirmation'))
    run_current('725_proposal_cannot_open_release_gate',
                mutate_data=lambda data: data.update(policy_status='proposal-awaiting-owner-confirmation'),
                expected_reason='replacement_policy_not_owner_approved')
    run_current('725_missing_historical_archive',
                mutate_files=lambda root: (root / checker.HISTORICAL_BUNDLE_PATH).unlink(),
                expected_reason='FileNotFoundError')
    run_current('725_historical_archive_tamper', mutate_files=append(checker.HISTORICAL_BUNDLE_PATH),
                expected_reason='historical_bundle_sha256')
    run_current('725_historical_archive_symlink', mutate_files=symlink(checker.HISTORICAL_BUNDLE_PATH),
                expected_reason='symlink_path')
    run_current('725_historical_directory_symlink', mutate_files=symlink('docs/audit/baselines'),
                expected_reason='symlink_path')
    run_current('725_old_receipt_relabelled_as_current',
                mutate_data=lambda data: data['candidate'].update(target_version='7.2.5'),
                expected_reason='candidate_binding')
    run_current('725_old_receipt_cannot_claim_new_live_success',
                mutate_data=lambda data: data['scope'].update(installed_version_after='7.2.5'),
                expected_reason='unsupported_scope')
    run_current('725_old_helper_tamper', mutate_files=append(checker.HELPER_PATH),
                expected_reason='helper_file_sha256')
    run_current('725_runtime_change_beyond_version', mutate_files=append('modules/00-runtime.sh'),
                expected_reason='current_runtime_change_scope')
    run_current('725_system_change_before_download', mutate_files=lambda root:
                (root / 'modules/10-system.sh').write_bytes(b'# unreviewed\n' +
                    (root / 'modules/10-system.sh').read_bytes()),
                expected_reason='system_changes_before_cloudflared')
    run_current('725_system_change_after_download', mutate_files=append('modules/10-system.sh'),
                expected_reason='system_changes_after_cloudflared')
    run_current('725_unreviewed_download_change', mutate_files=lambda root:
                (root / 'modules/10-system.sh').write_text((root / 'modules/10-system.sh').read_text().replace(
                    'rr_cloudflared_fallback_release() {\n', 'rr_cloudflared_fallback_release() {\n    # unreviewed\n')),
                expected_reason='current_system_sha256')
    run_current('725_current_archive_tamper', mutate_files=append('rr-bundle.tar.gz'),
                expected_reason='current_bundle_sha256')
    run_current('725_current_manifest_tamper', mutate_files=append('manifest.sha256'),
                expected_reason='current_manifest_mismatch')
    run_current('725_other_payload_tamper', mutate_files=append('modules/20-config.sh'),
                expected_reason='current_payload_file_mismatch')
    run_current('725_current_payload_symlink', mutate_files=symlink('modules/30-singbox.sh'),
                expected_reason='symlink_path')

    def pack(files, *, extra=None):
        target = io.BytesIO()
        with tarfile.open(fileobj=target, mode='w:gz') as archive:
            for path, data in files.items():
                member = tarfile.TarInfo('rr-bundle/' + path)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            if extra is not None:
                archive.addfile(extra)
        return target.getvalue()

    def refuses(name, operation, expected_reason):
        global count
        try:
            operation()
        except checker.Refusal as error:
            assert str(error) == expected_reason, (name, str(error))
        else:
            raise AssertionError(name + ' accepted')
        count += 1
        print('PASS ' + name)

    original_payload = checker.archive_payload((repo / checker.HISTORICAL_BUNDLE_PATH).read_bytes())
    duplicate = tarfile.TarInfo('rr-bundle/rr')
    refuses('archive_duplicate_member_refused',
            lambda: checker.archive_payload(pack(original_payload, extra=duplicate)), 'archive_duplicate_member')
    link = tarfile.TarInfo('rr-bundle/extra')
    link.type = tarfile.SYMTYPE
    link.linkname = '/etc/passwd'
    refuses('archive_symlink_refused',
            lambda: checker.archive_payload(pack(original_payload, extra=link)), 'archive_member_type')
    traversal = tarfile.TarInfo('rr-bundle/../../escape')
    refuses('archive_traversal_refused',
            lambda: checker.archive_payload(pack(original_payload, extra=traversal)), 'archive_member_path')
    absolute = tarfile.TarInfo('rr-bundle//etc/rr-absolute-fixture')
    refuses('archive_absolute_member_refused',
            lambda: checker.archive_payload(pack(original_payload, extra=absolute)), 'archive_member_path')
    extra = tarfile.TarInfo('rr-bundle/extra')
    refuses('archive_unmanifested_member_refused',
            lambda: checker.archive_payload(pack(original_payload, extra=extra)), 'archive_payload_inventory')

    forged = Path(temporary) / 'forged-current'
    shutil.copytree(current_baseline, forged)
    payload = checker.archive_payload((forged / 'rr-bundle.tar.gz').read_bytes())
    payload['modules/20-config.sh'] += b'\n# outside Cloudflared scope\n'
    old_manifest = payload['manifest.sha256'].decode()
    payload['manifest.sha256'] = ''.join(
        checker.digest(payload[path]) + '  ' + path + '\n'
        for path in (line.split('  ', 1)[1] for line in old_manifest.splitlines())
    ).encode()
    for path in ('modules/20-config.sh', 'manifest.sha256'):
        (forged / path).write_bytes(payload[path])
    forged_bundle = pack(payload)
    (forged / 'rr-bundle.tar.gz').write_bytes(forged_bundle)
    original_current_sha = checker.CURRENT_BUNDLE_SHA
    try:
        # Only this disposable imported module accepts the forged candidate hash.
        # Independently prove that even a rebound archive cannot widen the scope.
        checker.CURRENT_BUNDLE_SHA = checker.digest(forged_bundle)
        refuses('725_rebound_unrelated_payload_still_refused',
                lambda: checker.check_current_release(forged, True), 'current_change_outside_scope')
    finally:
        checker.CURRENT_BUNDLE_SHA = original_current_sha

assert (repo / receipt_path).read_bytes() == source_receipt, 'source receipt changed'
print('OWNER_RECOVERY_EVIDENCE_FIXTURES_OK cases=' + str(count)
      + ' scope=local-content-validation simulated_approval=true live_tests=false')
PY
