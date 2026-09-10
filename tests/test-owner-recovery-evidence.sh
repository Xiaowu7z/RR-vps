#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Unprivileged content-validation fixtures only. No server, installation,
# firewall, systemd, or network operations. The approved-policy fixture below
# simulates a future reviewed approval; it is not actual owner authorization.
python3 - "$repo" <<'PY'
import copy
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

repo = Path(sys.argv[1])
validator = repo / 'scripts/verify-owner-recovery-evidence.py'
receipt_path = 'docs/audit/owner-recovery-v724.json'
source_receipt = (repo / receipt_path).read_bytes()
evidence = json.loads(source_receipt)
# Exercise both policy states even after a later reviewed approval. Mutate only
# the fixture template; preserve the repository's actual receipt byte for byte.
evidence['policy_status'] = 'proposal-awaiting-owner-confirmation'
paths = [line.split('  ', 1)[1] for line in (repo / 'manifest.sha256').read_text().splitlines()]
paths += ['manifest.sha256', 'rr-bundle.tar.gz', 'version',
          'scripts/repair-v723-naive-first-install.sh', receipt_path]
count = 0

with tempfile.TemporaryDirectory(prefix='rr-owner-evidence-tests.') as temporary:
    baseline = Path(temporary) / 'baseline'
    for path in paths:
        target = baseline / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / path, target)

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
    run('repository_version_changed', mutate_files=lambda root: (root / 'version').write_text('RR-vps 7.2.5\n'),
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

assert (repo / receipt_path).read_bytes() == source_receipt, 'source receipt changed'
print('OWNER_RECOVERY_EVIDENCE_FIXTURES_OK cases=' + str(count)
      + ' scope=local-content-validation simulated_approval=true live_tests=false')
PY
