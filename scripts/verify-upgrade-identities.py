#!/usr/bin/env python3
"""Compare account, device and node identities without printing credentials."""
import json
import shlex
import sqlite3
import sys
from pathlib import Path


def identities():
    with sqlite3.connect('file:/var/lib/rr-nexus/nexus.db?mode=ro', uri=True) as db:
        assert db.execute('PRAGMA quick_check').fetchone() == ('ok',)
        users = db.execute('SELECT username,password_hash FROM users ORDER BY username').fetchall()
        devices = db.execute('SELECT id,name,credential,subscription_token,enabled,quota_bytes FROM devices ORDER BY id').fetchall()
    keys = {'UUID', 'PRIVATE_KEY', 'PUBLIC_KEY', 'SHORT_ID', 'NAIVE_USER', 'NAIVE_PASS'}
    config = {}
    for line in Path('/etc/argo_vmess.conf').read_text().splitlines():
        key, separator, value = line.partition('=')
        if separator and key in keys:
            parsed = shlex.split(value)
            config[key] = parsed[0] if parsed else ''
    return {'users': users, 'devices': devices, 'node_identity': config}


path = Path(sys.argv[1])
current = identities()
if sys.argv[2:] == ['--capture']:
    path.write_text(json.dumps(current))
    path.chmod(0o600)
    print('UPGRADE_IDENTITIES_CAPTURED')
else:
    assert json.loads(path.read_text()) == json.loads(json.dumps(current)), 'User/device/node identities changed'
    print('UPGRADE_IDENTITIES_PRESERVED')
