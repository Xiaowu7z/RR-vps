#!/usr/bin/env python3
"""Read-only inventory on the three SSH-key-pinned disposable audit hosts."""
import json
from pathlib import Path
import platform
import subprocess
import sys

role = sys.argv[1]
expected = {"A": ("debian", "12"), "B": ("ubuntu", "22.04"), "C": ("ubuntu", "24.04")}
assert role in expected
assert platform.node() not in {"DMIT-4AcBKDwTCc", "DMIT-8J8LiVPoNa"}, "primary host refused"
os_release = {}
for line in Path('/etc/os-release').read_text().splitlines():
    if '=' in line:
        k, v = line.split('=', 1)
        os_release[k] = v.strip('"')
assert (os_release['ID'], os_release['VERSION_ID']) == expected[role]
def run(args):
    p = subprocess.run(args, capture_output=True, text=True, timeout=20)
    return p.returncode, p.stdout.strip()
out = {'role': role, 'os': os_release['ID'], 'os_version': os_release['VERSION_ID'],
       'python': platform.python_version()}
out['rr'] = run(['/usr/local/bin/rr', '--version'])[1]
cfg_path = Path('/etc/rr-nexus/nexus.json')
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
out['panel'] = {k: cfg.get(k) for k in ('mode', 'listen', 'port', 'domain', 'public_port', 'certificate_mode')}
out['services'] = {}
for unit in ('sing-box.service', 'rr-nexus.service', 'nginx.service', 'argo-rr-health.timer'):
    out['services'][unit] = run(['systemctl', 'is-active', unit])[1]
out['credential_fixture'] = Path('/root/rr-stability-panel-credentials').is_file()
out['certificates'] = []
for cert in Path('/etc/letsencrypt/live').glob('*/fullchain.pem'):
    status, detail = run(['openssl', 'x509', '-in', str(cert), '-noout', '-subject', '-enddate'])
    out['certificates'].append({'lineage': cert.parent.name, 'parsed': status == 0, 'detail': detail})
out['nginx_test_ok'] = run(['nginx', '-t'])[0] == 0
out['health'] = run(['curl', '-fsS', '--max-time', '5', 'http://127.0.0.1:7900/healthz'])[0] == 0
print('CROSS_INVENTORY ' + json.dumps(out, ensure_ascii=False, sort_keys=True))
