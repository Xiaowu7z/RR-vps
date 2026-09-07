#!/usr/bin/env python3
"""Exercise the adapter's persistent-file restoration with isolated files."""
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = (Path(__file__).parents[1] / 'scripts/upgrade-v702-prepared-firewall.sh').read_text()
SOURCE = SOURCE.split('cat > "$backup/persistence.py" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / 'iptables'
        self.backup = Path(temp.name) / 'backup'
        self.root.mkdir()
        self.backup.mkdir()
        self.source = compile(SOURCE.replace("Path('/etc/iptables')", repr(self.root).replace('PosixPath', 'Path')), '<persistence>', 'exec')
        self.live = {}

    def run_action(self, action):
        with patch('sys.argv', ['persistence', action, str(self.backup)]), \
             patch('subprocess.check_output', side_effect=lambda args, **kw: self.live[args[0]]), \
             contextlib.redirect_stdout(io.StringIO()):
            exec(self.source, {})

    def test_restore_original_bytes_mode_and_absence(self):
        path = self.root / 'rules.v4'
        path.write_text('original persisted rules\n')
        path.chmod(0o640)
        self.run_action('snapshot')
        path.write_text('partially saved rules\n')
        path.chmod(0o600)
        (self.root / 'rules.v6').write_text('new file\n')
        self.run_action('restore')
        self.assertEqual(path.read_text(), 'original persisted rules\n')
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.root / 'rules.v6').exists())

    def test_persistence_match_and_non_filter_invariance(self):
        old = '*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n*nat\n:PREROUTING ACCEPT [0:0]\nCOMMIT\n'
        new = old.replace('COMMIT', '-A INPUT -p tcp --dport 443 -j ACCEPT\nCOMMIT', 1)
        for backend, name in [('iptables', 'rules.v4'), ('ip6tables', 'rules.v6')]:
            (self.backup / (backend + '.before.save')).write_text(old)
            (self.root / name).write_text(new)
            self.live[backend + '-save'] = '# varying generated timestamp\n' + new.replace('[0:0]', '[50:100]')
        self.run_action('verify')
        (self.root / 'rules.v6').write_text(old)
        with self.assertRaises(AssertionError):
            self.run_action('verify')
        changed = new.replace(':PREROUTING ACCEPT', ':PREROUTING DROP')
        (self.root / 'rules.v6').write_text(changed)
        self.live['ip6tables-save'] = changed
        with self.assertRaises(AssertionError):
            self.run_action('verify')


if __name__ == '__main__':
    unittest.main()
