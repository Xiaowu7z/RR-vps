#!/usr/bin/python3
"""RR-vps 7.2.1 observation only; no collector calls or stats resets."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
import urllib.request

MANIFEST = '''c39dfb6e7f40fd159b7ec4b42e01a851075c9d3ba2a35f49f46a5b2ba0588cdc  rr
f908141e58c8f9abce04c6190072ef878dac768bbd8ba8b100f561847ce7c7ff  scripts/naive-cert-hook.sh
fddc027041ca4ce79c649f53b830c46f9d5736712c0cc9ac60fc4ccf2a8a80a9  scripts/update-recover.sh
bf61a9ed170a67309f562937d4057252b81e3afc85c9f2e277f2aa30a9f06e98  scripts/update-external-state.py
e037a6732c3f51dfce6f4d46b0ff4d3e91cd8f939b926f362705cb15949413f0  modules/00-runtime.sh
1117fcc078ec7d4041dda2902ad93dbdc8e369b822ee82eb846192c178390740  modules/09-systemd.sh
2e8b60c97bc2cc872291d0fceaef7a34dd30bbce713ba3465f1fd87a711549f0  modules/10-system.sh
1d1163516971150a0399ce6c8aa381a75f23dfb1be8d0d63387df4bdfa29412c  modules/20-config.sh
a31b2431a41772e930772df69422e2a3d5024f317d42c3b750b502b63ff2444f  modules/30-singbox.sh
924024237dd3948ec9e7f5ecdbcaa18326a2fdb76ebfd1c8433fe0b549f0cdc6  modules/40-subscription.sh
d423362ce867fa5495b10025433b873bf6f31629ed01cd815587fadbf7585e32  modules/50-status-argo.sh
47bcdf775b70e06f9e47cf30620b34adf34aefccc5db3e14d5d0abe6c545074d  modules/55-resilience.sh
7c7da6ec8a5be181de680d7f76092b37f49f70774443e28b7d0b0531460ed69d  modules/60-update.sh
00c2733d7a4a13dcb4fffe718e800474a864d5b3608439905f00c50851a1b2dd  modules/70-protocols.sh
726709e6922a89359e9a9417e74018479d506c6399ead2a0d659f0b4df8c9dca  modules/80-ui.sh
170ad710ac9cc89c40ab24aeb69fcbd68d65caebf00bca7d218516d161546457  modules/85-nexus.sh
a97d3e583008f7492851b408ceac5979f72e4aa9844fb53ff2ee06bf518a6469  modules/86-nexus-ip-acme.sh
a9d9cfa7d34d54984af30f5a5218ed1b2567e6b1a71166dde6d1b883b16a6988  modules/90-auto-update.sh
9b69c533ff5ac6229217fb658cf12b872e322fcd9e3a217bdaf3e2191aa6ee9c  modules/95-install.sh
79c9594f622b09447a43d11c2d1b3823df77bbf2e2edb5b7b6d0558a628d7a25  modules/99-menus.sh
aab4bb8fb6c7e3d7e4244d1a0d7ceabc22dcd298b11d31e75f159d1cc47ae723  nexus/rr_nexus.py
a9830859c6af5db89451252c0172ba7fc2217c14ca116aac774997493c7616e2  nexus/rr_nexus_lib/__init__.py
72cff73636729d6d8445cf4b723eb0627613e60b99eb15dd220e8651a16c5f67  nexus/rr_nexus_lib/backup_archive.py
9224c800ce0d09a602dda4baf559ff17501f5280fa55bed15ce0e11a00ba8535  nexus/rr_nexus_lib/backup_crypto.py
2915b286cc3fb451facbe3fef0d5e566a989c4949066a6954eff44dd6957fd57  nexus/rr_nexus_lib/http_security.py
472db9149120d4c2359d9b3ecc9a87a54310140a86a3a60fc094c91dc1b16d74  nexus/rr_nexus_lib/notifications.py
c5d985b7cd6925d6b2c3eba441b8ae2f227cf9ca4c0ad29301ac9a0e4ea90ef0  nexus/rr_nexus_lib/notify_cli.py
230414a1633dd3aede65ed46035cf2adc3159458401d443d22325de8e72492c1  nexus/rr_nexus_lib/security.py
2ea6d83dbe90cc8bdb77ebad05a7de5a93ebec695701b3d323d583a8e79cafe1  nexus/static/admin.js
48d649f0c871f30e27fd94149478aa7d049a11cf20352f00c13454b358f83cce  nexus/static/app.css
c58993c8cf2e3f2aab30a94b68affc15a9e70c82786b118818c99c73cbde5180  nexus/static/app.js
b563ffb33a45f0bfb32420f702e106f0c3ed22dc4f6dbc26a43f365ec9d2be80  nexus/static/index.html
2db2fb2016ee6e10efc5d94a5d06cb275011362da3469888010b6cf816299318  nexus/static/optimizer.css
f1a37955a3e33c69954e59c26db4baff5d36d2b572ac717dc0189bf5afd7a89c  nexus/static/optimizer.js
af225a804c5c7c0e03df296137d5b7fd120a4298e76e97981bca0d04b4d999be  nexus/sub_server.py
'''
BASE = Path('/usr/local/lib/rr')
CORE = Path('/usr/local/bin/sing-box')
APP = BASE / 'nexus/rr_nexus.py'
GUARD_SHA = '2bbfdd8d80773cb48c19f11f91bbeb7ebd156f9419c30c5d81b3565aa346e64c'
cfg, sing, units = {}, {}, {}
db_ids, eligible_ids, configured_ids = set(), set(), set()
db_ready = False

def emit(label, **data):
    print(label, json.dumps(data, ensure_ascii=False, sort_keys=True), flush=True)

def section(name):
    def wrap(fn):
        print('\nCHECK ' + name, flush=True)
        try:
            fn()
        except Exception as exc:
            emit('CHECK_ERROR', section=name, error_type=type(exc).__name__)
        return fn
    return wrap

def run(args, timeout=12):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=timeout, check=False)

def sha(path):
    with open(path, 'rb') as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()

def exists(path):
    return os.path.lexists(str(path))

def compare(label, path, expected):
    try:
        actual = sha(path)
        emit('FILE', path=label, result='OK' if actual == expected else 'MISMATCH',
             symlink=path.is_symlink())
        return actual == expected
    except OSError as exc:
        emit('FILE', path=label, result=type(exc).__name__)
        return False

print('RR_TRAFFIC_DIAGNOSTIC_V3_DEBIAN: read-only; QueryStats reset=false; no credentials printed', flush=True)
emit('TIME', utc=dt.datetime.now(dt.timezone.utc).isoformat())
if os.geteuid() != 0:
    raise SystemExit('Run from the root terminal.')

@section('released_files')
def files():
    expected = dict((p, h) for h, p in (line.split() for line in MANIFEST.splitlines() if line.strip()))
    # The manifest describes bundle paths. The installer places its rr entry
    # in /usr/local/bin, while modules, scripts and nexus stay under BASE.
    good = sum(compare('/usr/local/bin/rr' if p == 'rr' else p,
                       Path('/usr/local/bin/rr') if p == 'rr' else BASE / p, h)
               for p, h in expected.items())
    emit('MANIFEST_SUMMARY', expected=len(expected), matching=good,
         baseline='RR-vps 7.2.1 Debian candidate 91cba8eca3c06eb571ff2c60fe2cb3eb88b20c51')
    compare('/usr/local/sbin/rr-update-recover', Path('/usr/local/sbin/rr-update-recover'), expected['scripts/update-recover.sh'])
    compare('/usr/local/sbin/rr-update-external-state', Path('/usr/local/sbin/rr-update-external-state'), expected['scripts/update-external-state.py'])
    compare('modules/61-update-guard.sh', BASE / 'modules/61-update-guard.sh', GUARD_SHA)
    extra = []
    for folder in ('modules', 'nexus', 'scripts'):
        for p in (BASE / folder).rglob('*'):
            if p.is_file() and p.suffix in {'.py', '.sh', '.js', '.css', '.html'}:
                relative = p.relative_to(BASE).as_posix()
                if relative not in expected and relative != 'modules/61-update-guard.sh':
                    extra.append(relative)
    emit('ADDITIONAL_CODE_FILES', count=len(extra), paths=sorted(extra)[:30],
         note='Additional files need review; presence alone is not a fault.')

@section('services_and_running_core')
def services():
    fields = ['Id', 'LoadState', 'ActiveState', 'SubState', 'UnitFileState', 'MainPID',
              'ExecMainStartTimestamp', 'NRestarts', 'PrivateNetwork']
    for name in ('sing-box.service', 'rr-nexus.service', 'nginx.service', 'argo-rr-health.timer'):
        result = run(['systemctl', 'show', name, '--no-pager', '--property=' + ','.join(fields)])
        state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        units[name] = state
        emit('UNIT', unit=name, returncode=result.returncode, **state)
    version = run([str(CORE), 'version'])
    text = version.stdout
    first = next((x for x in text.splitlines() if x.startswith('sing-box version ')), '')
    emit('CORE', version=first[:100], with_v2ray_api='with_v2ray_api' in text,
         returncode=version.returncode, disk_sha256=sha(CORE),
         target_version_matches=first == 'sing-box version 1.14.0',
         source_revision_matches='Revision: 0b8995879f29a9b98ee027bc17b75e101445b238' in text,
         go_version_matches='Environment: go1.25.5 linux/' in text)
    pid = int(units['sing-box.service'].get('MainPID', '0'))
    if pid:
        running = Path('/proc') / str(pid) / 'exe'
        target = os.readlink(running)
        emit('RUNNING_CORE', same_as_disk=sha(running) == sha(CORE),
             deleted_executable=target.endswith(' (deleted)'), canonical_path=target == str(CORE))
        cmd = (Path('/proc') / str(pid) / 'cmdline').read_bytes().split(b'\0')
        emit('CORE_PROCESS', canonical_config=b'/etc/sing-box/config.json' in cmd)
    pid = int(units['rr-nexus.service'].get('MainPID', '0'))
    if pid:
        cmd = (Path('/proc') / str(pid) / 'cmdline').read_bytes().split(b'\0')
        emit('PANEL_PROCESS', canonical_app=str(APP).encode() in cmd,
             system_python=b'/usr/bin/python3' in cmd,
             thread_count=len(list((Path('/proc') / str(pid) / 'task').iterdir())))
        stat = (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
        btime = int(next(x.split()[1] for x in Path('/proc/stat').read_text().splitlines() if x.startswith('btime ')))
        started = btime + int(stat[19]) / os.sysconf('SC_CLK_TCK')
        emit('PANEL_SOURCE_AGE', modified_after_process_start=APP.stat().st_mtime > started + 2,
             note='False alone cannot prove which Python source is loaded.')

@section('maintenance_and_transaction')
def markers():
    for label, path in [('update_maintenance', '/run/rr-vps/update-maintenance'),
                        ('firewall_quarantine', '/var/lib/rr-vps/firewall-quarantine'),
                        ('restore_active', '/var/lib/rr-backup/active')]:
        emit('MARKER', name=label, present=exists(path))
    result = run(['/usr/local/sbin/rr-update-recover', 'status'])
    status = json.loads(result.stdout)
    emit('TRANSACTION', active=status.get('active'), phase=status.get('phase'),
         subscription_quarantine_active=(status.get('subscription_quarantine') or {}).get('active'))
    tx = status.get('transaction', '')
    if re.fullmatch(r'/var/lib/rr-update/transactions/[A-Za-z0-9_-]+', tx):
        marker = Path(tx) / 'committed-settled'
        emit('COMMITTED_SETTLED', present=exists(marker),
             value_matches=marker.is_file() and marker.read_text().strip() == 'rr-update-committed-settled-v1')

@section('statistics_configuration')
def configuration():
    global cfg, sing, configured_ids
    cfg = json.loads(Path('/etc/rr-nexus/nexus.json').read_text())
    sing = json.loads(Path('/etc/sing-box/config.json').read_text())
    api = sing.get('experimental', {}).get('v2ray_api', {})
    stats = api.get('stats', {})
    configured_ids = set(stats.get('users') or [])
    port = cfg.get('stats_port', 39091)
    emit('STATS_CONFIG', panel_stats_port=port, api_present=bool(api), enabled=stats.get('enabled'),
         loopback_listen_matches=api.get('listen') == '127.0.0.1:' + str(port),
         stats_user_count=len(configured_ids), traffic_mode=cfg.get('traffic_mode', 'both'),
         canonical_database=cfg.get('database', '/var/lib/rr-nexus/nexus.db') == '/var/lib/rr-nexus/nexus.db')
    inbound_names = set()
    for inbound in sing.get('inbounds', []):
        names = {str(u.get('name', u.get('username', ''))) for u in inbound.get('users', [])}
        inbound_names.update(names)
        emit('INBOUND_USERS', protocol=inbound.get('type'), total=len(names),
             tracked=len(names & configured_ids), legacy_present='legacy' in names)
    emit('STATS_NAME_MATCH', tracked_names_missing_from_all_inbounds=len(configured_ids - inbound_names))

def connect_db():
    connection = sqlite3.connect('file:/var/lib/rr-nexus/nexus.db?mode=ro', uri=True, timeout=3)
    connection.execute('PRAGMA query_only=ON')
    deadline = time.monotonic() + 8
    connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
    return connection

@section('database_and_user_mapping')
def database():
    global db_ids, eligible_ids, db_ready
    with connect_db() as db:
        integrity = db.execute('PRAGMA quick_check(1)').fetchone()
        emit('DB_INTEGRITY', ok=bool(integrity and integrity[0] == 'ok'))
        db_ids = {row[0] for row in db.execute('SELECT id FROM devices')}
        today = dt.datetime.now(dt.timezone.utc).date().isoformat()
        eligible_ids = {row[0] for row in db.execute("SELECT id FROM devices WHERE enabled=1 AND (expires_at IS NULL OR expires_at='' OR expires_at>=?) AND (quota_bytes=0 OR used_bytes<quota_bytes)", (today,))}
        emit('DB_USERS', total=len(db_ids), eligible=len(eligible_ids),
             eligible_missing_from_stats=len(eligible_ids - configured_ids),
             stats_names_not_in_database=len(configured_ids - db_ids),
             stats_names_not_eligible=len(configured_ids - eligible_ids))
    db_ready = True

def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError('truncated')
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError('oversize')

def fields(data):
    offset = 0
    while offset < len(data):
        key, offset = varint(data, offset)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise ValueError('field')
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, offset = varint(data, offset)
            else:
                size = 8 if wire == 1 else 4
            if offset + size > len(data):
                raise ValueError('truncated')
            value = data[offset:offset + size]
            offset += size
        else:
            raise ValueError('wire')
        yield number, wire, value

@section('grpc_nonreset_probe')
def grpc_probe():
    import grpc
    emit('GRPC_PACKAGE', version=grpc.__version__, interpreter_is_system=True)
    port = cfg.get('stats_port', 39091)
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('port')
    request = b'\x10\x00\x1a\x07user>>>'
    try:
        with grpc.insecure_channel('127.0.0.1:' + str(port), options=[('grpc.max_receive_message_length', 2097152)]) as channel:
            call = channel.unary_unary('/v2ray.core.app.stats.command.StatsService/QueryStats',
                                      request_serializer=lambda x: x, response_deserializer=lambda x: x)
            response = call(request, timeout=4)
        total = matched = positive = unknown = 0
        for number, wire, stat in fields(response):
            if number != 1 or wire != 2:
                continue
            name, value = '', 0
            for n, w, v in fields(stat):
                if (n, w) == (1, 2):
                    name = v.decode('utf-8')
                elif (n, w) == (2, 0):
                    value = v
            total += 1
            match = re.fullmatch(r'user>>>(dev_[a-f0-9]{12})>>>traffic>>>(uplink|downlink)', name)
            if match:
                matched += 1
                positive += value > 0
                unknown += db_ready and match.group(1) not in db_ids
        emit('GRPC_RESULT', ok=True, reset=False, counters=total, panel_pattern_matches=matched,
             nonzero_matches=positive, counters_without_db_device=unknown,
             note='Empty or zero counters can be normal between collector polls; not an end-to-end pass.')
    except grpc.RpcError as exc:
        emit('GRPC_RESULT', ok=False, reset=False, code=exc.code().name)

def sample(label):
    with connect_db() as db:
        for key, query in [
            ('devices', 'SELECT COUNT(*),COALESCE(SUM(uploaded_bytes),0),COALESCE(SUM(downloaded_bytes),0),MAX(traffic_updated_at) FROM devices'),
            ('traffic_samples', 'SELECT MAX(bucket) FROM traffic_samples'),
            ('system_samples', 'SELECT MAX(bucket) FROM system_samples'),
            ('server_traffic', 'SELECT received_bytes,transmitted_bytes,updated_at FROM server_traffic_policy WHERE id=1')]:
            try:
                row = db.execute(query).fetchone()
                emit('DB_SAMPLE', sample=label, table=key, values=list(row) if row else [])
            except sqlite3.Error as exc:
                emit('DB_SAMPLE', sample=label, table=key, error_type=type(exc).__name__)
    total_rx = total_tx = interfaces = 0
    for path in Path('/sys/class/net').iterdir():
        if path.name == 'lo':
            continue
        try:
            total_rx += int((path / 'statistics/rx_bytes').read_text())
            total_tx += int((path / 'statistics/tx_bytes').read_text())
            interfaces += 1
        except OSError:
            continue
    emit('HOST_COUNTERS', sample=label, interface_count=interfaces, rx=total_rx, tx=total_tx,
         note='All non-loopback interfaces; observation only, may double-count virtual interfaces.')

@section('collector_progress')
def progress():
    sample('A')
    time.sleep(6)
    sample('B')
    grpc_probe()
    time.sleep(6)
    sample('C')
    grpc_probe()

@section('local_panel_health')
def health():
    port = cfg.get('port', 7900)
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('port')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open('http://127.0.0.1:' + str(port) + '/healthz', timeout=5) as response:
        emit('PANEL_HEALTH', http_status=response.status,
             note='Health endpoint does not verify the gRPC collector.')

@section('served_frontend')
def frontend():
    port = cfg.get('port', 7900)
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('port')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request('http://127.0.0.1:' + str(port) + '/app.js?v=27&rr_probe=' + str(int(time.time())),
                                     headers={'Cache-Control': 'no-cache'})
    with opener.open(request, timeout=5) as response:
        body = response.read(2 * 1024 * 1024 + 1)
        emit('SERVED_APP_JS', http_status=response.status,
             matches_installed=len(body) <= 2 * 1024 * 1024 and hashlib.sha256(body).hexdigest() == sha(BASE / 'nexus/static/app.js'),
             cache_control=response.headers.get_all('Cache-Control', []))

print('\nRR_TRAFFIC_DIAGNOSTIC_COMPLETE', flush=True)
