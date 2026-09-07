#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Execute the actual workflow shell with an isolated, exhaustive gh replacement.
# The stub rejects unknown calls, so these fixtures cannot dispatch a workflow.
python3 - "$REPO_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

root = Path(sys.argv[1])
workflow = yaml.safe_load((root / '.github/workflows/publish-stable.yml').read_text())
steps = [step for step in workflow['jobs']['dispatch']['steps'] if 'run' in step]
assert len(steps) == 1, 'Select the entire publisher dispatch step, not a reimplementation'
script = steps[0]['run']
sha = 'a' * 40
other_sha = 'b' * 40
repository = 'fixture/rr-vps'

def run(number=1, attempt=1, **changes):
    record = dict(head_sha=sha, head_branch='main', event='push',
                  run_number=number, run_attempt=attempt,
                  status='completed', conclusion='success')
    record.update(changes)
    return record

def fixture(**changes):
    record = dict(main=sha, version='RR-vps 7.2.2\n', releases=[],
                  ci=[run()], stability=[run()])
    record.update(changes)
    return record

cases = [
    ('new-version-both-success', fixture(), 0, True),
    ('future-version-needs-no-workflow-edit',
     fixture(version='RR-vps 8.3.0\n'), 0, True),
    ('new-version-with-older-release',
     fixture(releases=[dict(tag_name='v7.2.1', draft=False)]), 0, True),
    ('main-has-advanced', fixture(main=other_sha), 0, False),
    ('missing-ci', fixture(ci=[]), 0, False),
    ('latest-ci-failed',
     fixture(ci=[run(2, conclusion='failure'), run(1)]), 0, False),
    ('latest-rerun-failed',
     fixture(ci=[run(1, 2, conclusion='failure'), run(1, 1)]), 0, False),
    ('latest-rerun-succeeded',
     fixture(ci=[run(1, 1, conclusion='failure'), run(1, 2)]), 0, True),
    ('stability-in-progress',
     fixture(stability=[run(status='in_progress', conclusion=None)]), 0, False),
    ('stability-failed',
     fixture(stability=[run(conclusion='failure')]), 0, False),
    ('other-sha-is-not-evidence', fixture(ci=[run(head_sha=other_sha)]), 0, False),
    ('other-branch-is-not-evidence', fixture(ci=[run(head_branch='beta')]), 0, False),
    ('pull-request-is-not-push-evidence', fixture(ci=[run(event='pull_request')]), 0, False),
    ('ignore-newer-unrelated-run',
     fixture(ci=[run(99, head_sha=other_sha, conclusion='failure'), run(1)]), 0, True),
    ('already-published-version-is-immutable',
     fixture(releases=[dict(tag_name='v7.2.2', draft=False)]), 0, False),
    ('draft-allows-existing-publisher-recovery',
     fixture(releases=[dict(tag_name='v7.2.2', draft=True)]), 0, True),
    ('published-version-takes-precedence-over-draft',
     fixture(releases=[dict(tag_name='v7.2.2', draft=True),
                       dict(tag_name='v7.2.2', draft=False)]), 0, False),
    ('noncanonical-version-fails', fixture(version='RR-vps 07.2.2\n'), 1, False),
    ('version-shell-text-is-not-executed',
     fixture(version='RR-vps 7.2.2; touch SHOULD_NOT_EXIST\n'), 1, False),
    ('release-list-error-fails-closed', fixture(fail='releases'), 17, False),
    ('gate-api-error-fails-closed', fixture(fail='ci'), 17, False),
]

fake_gh = r'''#!/usr/bin/env python3
import base64
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
with open(os.environ['RR_PUBLISH_CALLS'], 'a') as output:
    output.write(json.dumps(args) + '\n')
fixture = json.loads(Path(os.environ['RR_PUBLISH_FIXTURE']).read_text())
repository = os.environ['GITHUB_REPOSITORY']
sha = os.environ['EXPECTED_SHA']
api = '/repos/' + repository
if args == ['workflow', 'run', 'release.yml', '--repo', repository,
            '--ref', 'main', '-f', 'sha=' + sha]:
    raise SystemExit(0)
if args[:1] != ['api']:
    raise SystemExit('unexpected gh call: ' + repr(args))
paths = [arg for arg in args if arg.startswith('/repos/')]
if len(paths) != 1:
    raise SystemExit('expected one exact API path')
path = paths[0]
if path == api + '/git/ref/heads/main':
    key, response = 'main', {'object': {'sha': fixture['main']}}
elif path == api + '/contents/version?ref=' + sha:
    key = 'version'
    response = {'content': base64.b64encode(fixture['version'].encode()).decode()}
elif path == api + '/releases?per_page=100':
    assert '--paginate' in args, 'Published tags must include every release page'
    key, response = 'releases', fixture['releases']
else:
    names = {'ci.yml': 'ci', 'vps-stability.yml': 'stability'}
    matches = [key for name, key in names.items()
               if path == (api + '/actions/workflows/' + name +
                           '/runs?branch=main&event=push&head_sha=' + sha +
                           '&per_page=100')]
    if len(matches) != 1:
        raise SystemExit('unexpected API path: ' + path)
    key = matches[0]
    response = {'total_count': len(fixture[key]), 'workflow_runs': fixture[key]}
if fixture.get('fail') == key:
    raise SystemExit(17)
if '--jq' in args:
    query = args[args.index('--jq') + 1]
    result = subprocess.run(['jq', '-r', query], input=json.dumps(response),
                            text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
print(json.dumps(response))
'''

with tempfile.TemporaryDirectory(prefix='rr-publish-stable-') as temporary:
    directory = Path(temporary)
    bin_dir = directory / 'bin'
    bin_dir.mkdir()
    (bin_dir / 'gh').write_text(fake_gh)
    (bin_dir / 'gh').chmod(0o755)
    shell_script = directory / 'actual-workflow-step.sh'
    shell_script.write_text(script)
    subprocess.run(['bash', '-n', str(shell_script)], check=True)
    for index, (name, data, expected_status, expected_dispatch) in enumerate(cases, 1):
        case_dir = directory / name
        case_dir.mkdir()
        case_fixture = case_dir / 'fixture.json'
        calls_path = case_dir / 'calls.jsonl'
        case_fixture.write_text(json.dumps(data))
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   GITHUB_REPOSITORY=repository, EXPECTED_SHA=sha,
                   GH_TOKEN='fixture-not-a-token',
                   RR_PUBLISH_FIXTURE=str(case_fixture), RR_PUBLISH_CALLS=str(calls_path))
        result = subprocess.run(['bash', str(shell_script)], cwd=case_dir,
                                env=env, text=True, capture_output=True, timeout=15)
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
        dispatches = [call for call in calls if call[:2] == ['workflow', 'run']]
        assert result.returncode == expected_status, (
            name, result.returncode, expected_status, result.stdout, result.stderr)
        assert len(dispatches) == int(expected_dispatch), (name, calls, result.stdout)
        assert not (case_dir / 'SHOULD_NOT_EXIST').exists(), 'Version became executable code'
        if expected_dispatch:
            assert calls[-1] == ['workflow', 'run', 'release.yml', '--repo', repository,
                                 '--ref', 'main', '-f', 'sha=' + sha], (name, calls)
            assert any('/ci.yml/runs?' in str(call) for call in calls), name
            assert any('/vps-stability.yml/runs?' in str(call) for call in calls), name
        print(f'[{index}/{len(cases)}] {name}: OK')

print('publish stable regression: PASS (actual workflow shell, no remote calls)')
PY
