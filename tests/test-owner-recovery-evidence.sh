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
    # historical payload, even while the current release advances to 7.2.6.
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
    run('repository_version_changed', mutate_files=lambda root: (root / 'version').write_text('RR-vps 7.2.7\n'),
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
    current_baseline.mkdir()
    # All 7.2.5 cases still run against its actual immutable bundle, never the
    # new 7.2.6 payload relabelled as a historical release.
    checker.materialize_previous_root(repo, current_baseline)

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

    release_baseline = Path(temporary) / 'release-726-baseline'
    release_paths = {line.split('  ', 1)[1]
                     for line in (repo / 'manifest.sha256').read_text().splitlines()}
    release_paths.update({
        'manifest.sha256', 'rr-bundle.tar.gz', 'version', checker.HELPER_PATH,
        checker.HISTORICAL_BUNDLE_PATH, checker.PREVIOUS_BUNDLE_PATH,
        checker.PREVIOUS_GUARD_PATH, checker.PREVIOUS_CORE_PATH,
        receipt_path, checker.LA_RECEIPT_PATH,
        checker.LA_HELPER_PATH,
    })
    release_paths.update(checker.RELEASE_726_FILE_SHAS)
    for path in release_paths:
        target = release_baseline / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / path, target)
    source_la_receipt = (repo / checker.LA_RECEIPT_PATH).read_bytes()

    def run_726(name, *, mutate_la=None, mutate_historical=None, mutate_files=None,
                approved_mode=True, expected_reason=None):
        global count
        current = Path(temporary) / name
        shutil.copytree(release_baseline, current)
        for path, mutate in ((checker.LA_RECEIPT_PATH, mutate_la),
                             (receipt_path, mutate_historical)):
            if mutate is not None:
                data = json.loads((current / path).read_bytes())
                mutate(data)
                (current / path).write_text(json.dumps(data))
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
            assert output['target_version'] == '7.2.6', name
            assert output['bundle_sha256'] == checker.RELEASE_726_BUNDLE_SHA, name
            assert output['file_sha256'] == checker.RELEASE_726_FILE_SHAS, name
            assert output['current_live_acceptance'] == 'not_reported', name
            assert output['ci_executed_live_test'] is False, name
            assert output['required_approved_policy'] is approved_mode, name
            historical = output['historical_evidence']
            assert historical['target_version'] == '7.2.4', name
            assert historical['bundle_sha256'] == checker.BUNDLE_SHA, name
            assert historical['scope'] == checker.SCOPE, name
            assert historical['scope']['installed_version_after'] == '7.2.3', name
            previous = output['previous_release_evidence']
            assert previous['target_version'] == '7.2.5', name
            assert previous['bundle_sha256'] == checker.CURRENT_BUNDLE_SHA, name
            assert previous['current_live_acceptance'] == 'not_reported', name
            la = output['la721_recovery_evidence']
            assert la['helper_sha256'] == checker.LA_HELPER_SHA, name
            assert la['scope'] == checker.LA_SCOPE, name
            assert la['scope']['installed_version_after'] == '7.2.1-with-local-health-hotfix', name
            assert la['scope']['public_protocol_connectivity'] == 'not_reported', name
            assert la['completion'] == checker.LA_COMPLETION, name
            assert la['release_authorization']['quote'] == '整合修复发布7.2.6正式版。', name
        else:
            assert result.returncode == 1 and not result.stdout, (name, result.stdout, result.stderr)
            output = json.loads(result.stderr)
            assert output['event'] == 'OWNER_RECOVERY_CONTENT_REFUSED', name
            assert output['reason'] == expected_reason, (name, output)
        count += 1
        print('PASS ' + name)

    run_726('726_candidate_and_both_original_receipts')
    run_726('726_proposal_content_review', approved_mode=False,
            mutate_la=lambda data: data.update(release_policy_status='proposal-awaiting-owner-confirmation'))
    run_726('726_proposal_cannot_open_release_gate',
            mutate_la=lambda data: data.update(release_policy_status='proposal-awaiting-owner-confirmation'),
            expected_reason='release_726_policy_not_owner_approved')
    run_726('726_historical_approval_still_required',
            mutate_historical=lambda data: data.update(policy_status='proposal-awaiting-owner-confirmation'),
            expected_reason='replacement_policy_not_owner_approved')
    run_726('726_fabricated_owner_authorization_refused',
            mutate_la=lambda data: data['release_authorization'].update(quote='三台机器已通过7.2.6升级'),
            expected_reason='release_726_authorization')
    run_726('726_wrong_release_authorization_refused',
            mutate_la=lambda data: data['release_authorization'].update(target_version='7.2.7'),
            expected_reason='release_726_authorization')
    run_726('726_la_receipt_missing',
            mutate_files=lambda root: (root / checker.LA_RECEIPT_PATH).unlink(),
            expected_reason='FileNotFoundError')
    run_726('726_la_duplicate_key', mutate_files=lambda root: (root / checker.LA_RECEIPT_PATH).write_text(
            (root / checker.LA_RECEIPT_PATH).read_text().replace('{', '{"scope":{},', 1)),
            expected_reason='duplicate_json_key')
    run_726('726_la_unknown_claim', mutate_la=lambda data: data.update(three_host_upgrade='passed'),
            expected_reason='la_receipt_schema_keys')
    run_726('726_la_claims_ci_source', mutate_la=lambda data: data.update(source='ci-vps-test'),
            expected_reason='la_receipt_source')
    for name, field, value in (
        ('claims_three_hosts', 'host_count', 3),
        ('boolean_host_count', 'host_count', True),
        ('claims_new_release_upgrade', 'installed_version_after', '7.2.6'),
        ('claims_public_connectivity', 'public_protocol_connectivity', 'passed'),
        ('claims_client_subscription', 'client_subscription_use', 'passed'),
        ('claims_ci_live_test', 'ci_executed_live_test', True),
    ):
        run_726('726_la_' + name,
                mutate_la=lambda data, field=field, value=value: data['scope'].update({field: value}),
                expected_reason='la_unsupported_scope')
    run_726('726_la_wrong_executed_helper',
            mutate_la=lambda data: data['recovery_helper'].update(source_commit='0' * 40),
            expected_reason='la_helper_binding')
    run_726('726_la_wrong_helper_arguments',
            mutate_la=lambda data: data['recovery_helper'].update(arguments=[]),
            expected_reason='la_helper_binding')
    run_726('726_la_helper_bytes_tamper', mutate_files=append(checker.LA_HELPER_PATH),
            expected_reason='la_helper_file_sha256')
    run_726('726_la_missing_final_pass',
            mutate_la=lambda data: data['receipt']['phase_checks'].pop(),
            expected_reason='la_receipt_success_events')
    run_726('726_la_failed_service_restore',
            mutate_la=lambda data: data['receipt']['phase_checks'][-2].update(result='FAIL'),
            expected_reason='la_receipt_success_events')
    run_726('726_la_unordered_phase_checks',
            mutate_la=lambda data: data['receipt']['phase_checks'].reverse(),
            expected_reason='la_receipt_success_events')
    run_726('726_la_missing_completion',
            mutate_la=lambda data: data['receipt'].pop('completion'),
            expected_reason='la_receipt_success_events')
    run_726('726_la_wrong_completion_event',
            mutate_la=lambda data: data['receipt']['completion'].update(event='LA726_UPGRADE_COMPLETE'),
            expected_reason='la_receipt_success_events')
    run_726('726_la_claims_firewall_unchanged',
            mutate_la=lambda data: data['receipt']['completion'].update(firewall='unchanged'),
            expected_reason='la_receipt_success_events')
    run_726('726_la_claims_health_timer_active',
            mutate_la=lambda data: data['receipt']['completion'].update(health_timer='active'),
            expected_reason='la_receipt_success_events')
    run_726('726_la_receipt_symlink', mutate_files=symlink(checker.LA_RECEIPT_PATH),
            expected_reason='symlink_path')
    run_726('726_previous_bundle_tamper', mutate_files=append(checker.PREVIOUS_BUNDLE_PATH),
            expected_reason='previous_bundle_sha256')
    run_726('726_original_debian_bundle_tamper', mutate_files=append(checker.HISTORICAL_BUNDLE_PATH),
            expected_reason='historical_bundle_sha256')
    run_726('726_debian_receipt_not_relabelled',
            mutate_historical=lambda data: data['candidate'].update(target_version='7.2.6'),
            expected_reason='candidate_binding')
    run_726('726_previous_guard_tamper', mutate_files=append(checker.PREVIOUS_GUARD_PATH),
            expected_reason='previous_guard_sha256')
    run_726('726_previous_core_tamper', mutate_files=append(checker.PREVIOUS_CORE_PATH),
            expected_reason='previous_core_sha256')
    run_726('726_runtime_change_beyond_version', mutate_files=append('modules/00-runtime.sh'),
            expected_reason='release_726_runtime_change_scope')
    run_726('726_system_change_outside_scope', mutate_files=append('modules/10-system.sh'),
            expected_reason='release_726_change_outside_function_scope')
    run_726('726_cloudflared_baseline_must_stay_unchanged', mutate_files=lambda root:
            (root / 'modules/10-system.sh').write_text((root / 'modules/10-system.sh').read_text().replace(
                'rr_cloudflared_fallback_release() {\n',
                'rr_cloudflared_fallback_release() {\n    # outside 7.2.6 scope\n')),
            expected_reason='release_726_change_outside_function_scope')
    run_726('726_unreviewed_health_change_inside_scope', mutate_files=lambda root:
            (root / 'modules/60-update.sh').write_text((root / 'modules/60-update.sh').read_text().replace(
                'ensure_runtime_health() {\n', 'ensure_runtime_health() {\n    # unreviewed change\n')),
            expected_reason='release_726_candidate_file_sha256')
    run_726('726_subscription_check_cannot_be_removed', mutate_files=lambda root:
            (root / 'modules/20-config.sh').write_bytes((root / 'modules/20-config.sh').read_bytes().replace(
                checker.RELEASE_726_EXACT_INSERTIONS['modules/20-config.sh'][0], b'')),
            expected_reason='release_726_exact_insertion')
    run_726('726_install_core_change_outside_scope', mutate_files=append('scripts/install-core.sh'),
            expected_reason='release_726_core_change_scope')
    run_726('726_unreviewed_rollback_change_inside_scope', mutate_files=lambda root:
            (root / 'scripts/install-core.sh').write_text((root / 'scripts/install-core.sh').read_text().replace(
                'rr_rollback() {\n', 'rr_rollback() {\n    # unreviewed change\n')),
            expected_reason='release_726_candidate_file_sha256')
    run_726('726_generated_bootstrap_tamper', mutate_files=append('install.sh'),
            expected_reason='release_726_candidate_file_sha256')
    run_726('726_bundle_tamper', mutate_files=append('rr-bundle.tar.gz'),
            expected_reason='release_726_bundle_sha256')
    run_726('726_manifest_tamper', mutate_files=append('manifest.sha256'),
            expected_reason='release_726_manifest_mismatch')
    run_726('726_unrelated_payload_tamper', mutate_files=append('modules/30-singbox.sh'),
            expected_reason='release_726_payload_file_mismatch')

    refuses('726_ambiguous_function_anchor_refused', lambda: checker.unchanged_outside_blocks(
        b'A\nB\nA\nC\n', b'A\nB\nC\n', [(b'A\n', b'A\n', b'C\n')]),
        'release_726_change_boundaries')
    refuses('726_missing_function_anchor_refused', lambda: checker.unchanged_outside_blocks(
        b'A\nB\nC\n', b'A\nB\n', [(b'A\n', b'A\n', b'C\n')]),
        'release_726_change_boundaries')
    refuses('726_overlapping_function_ranges_refused', lambda: checker.unchanged_outside_blocks(
        b'A\nB\nC\nD\n', b'A\nB\nC\nD\n',
        [(b'A\n', b'A\n', b'C\n'), (b'B\n', b'B\n', b'D\n')]),
        'release_726_overlapping_boundaries')

    def rebind_726_payload(name, path, addition, expected_reason):
        forged = Path(temporary) / name
        shutil.copytree(release_baseline, forged)
        payload = checker.archive_payload((forged / 'rr-bundle.tar.gz').read_bytes())
        payload[path] += addition
        manifest_paths = [line.split('  ', 1)[1]
                          for line in payload['manifest.sha256'].decode().splitlines()]
        payload['manifest.sha256'] = ''.join(checker.digest(payload[item]) + '  ' + item + '\n'
                                              for item in manifest_paths).encode()
        for item in (path, 'manifest.sha256'):
            (forged / item).write_bytes(payload[item])
        bundle = pack(payload)
        (forged / 'rr-bundle.tar.gz').write_bytes(bundle)
        saved_bundle_pin = checker.RELEASE_726_BUNDLE_SHA
        saved_file_pins = checker.RELEASE_726_FILE_SHAS.copy()
        try:
            # A simulated reviewed re-pin alone cannot expand the function or
            # payload scope. Only this disposable imported module is modified.
            checker.RELEASE_726_BUNDLE_SHA = checker.digest(bundle)
            # Model the deterministic rebuild's two generated bootstrap pins,
            # so the negative case reaches the independent payload scope gate.
            core_path = forged / 'scripts/install-core.sh'
            core_path.write_bytes(core_path.read_bytes().replace(
                saved_bundle_pin.encode(), checker.RELEASE_726_BUNDLE_SHA.encode()))
            core_sha = checker.digest(core_path.read_bytes())
            bootstrap_path = forged / 'install.sh'
            bootstrap_path.write_bytes(bootstrap_path.read_bytes().replace(
                saved_file_pins['scripts/install-core.sh'].encode(), core_sha.encode()))
            checker.RELEASE_726_FILE_SHAS['scripts/install-core.sh'] = core_sha
            checker.RELEASE_726_FILE_SHAS['install.sh'] = checker.digest(bootstrap_path.read_bytes())
            if path in checker.RELEASE_726_FILE_SHAS:
                checker.RELEASE_726_FILE_SHAS[path] = checker.digest(payload[path])
            refuses(name, lambda: checker.check_726_release(forged, True), expected_reason)
        finally:
            checker.RELEASE_726_BUNDLE_SHA = saved_bundle_pin
            checker.RELEASE_726_FILE_SHAS = saved_file_pins

    rebind_726_payload('726_rebound_unrelated_payload_refused', 'modules/30-singbox.sh',
                      b'\n# unrelated candidate change\n', 'release_726_change_outside_scope')
    rebind_726_payload('726_rebound_system_outside_function_scope_refused', 'modules/10-system.sh',
                      b'\n# outside approved functions\n', 'release_726_change_outside_function_scope')
    saved_726_bundle_pin = checker.RELEASE_726_BUNDLE_SHA
    try:
        checker.RELEASE_726_BUNDLE_SHA = 'PENDING_FINAL_CANDIDATE_BUNDLE'
        refuses('726_unpinned_candidate_refused',
                lambda: checker.check_726_release(release_baseline, True), 'release_726_candidate_not_pinned')
    finally:
        checker.RELEASE_726_BUNDLE_SHA = saved_726_bundle_pin
    assert (repo / checker.LA_RECEIPT_PATH).read_bytes() == source_la_receipt, 'LA source receipt changed'

assert (repo / receipt_path).read_bytes() == source_receipt, 'source receipt changed'
print('OWNER_RECOVERY_EVIDENCE_FIXTURES_OK cases=' + str(count)
      + ' scope=local-content-validation simulated_approval=true live_tests=false')
PY
