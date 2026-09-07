#!/usr/bin/env python3
"""Bound the accepted Certbot edits; reject foreign routes and hidden directives."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('legacy', Path(__file__).resolve().parents[1] / 'scripts/legacy-nginx-702.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


class LegacySiteTests(unittest.TestCase):
    def setUp(self):
        self.domain = 'panel.example.com'
        self.site = '''limit_req_zone $binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;
server { BODY
listen [::]:443 ssl ipv6only=on; # managed by Certbot
listen 443 ssl; # managed by Certbot
ssl_certificate /etc/letsencrypt/live/DOMAIN/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;
include /etc/letsencrypt/options-ssl-nginx.conf;
ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
 if ($host = DOMAIN) { return 301 https://$host$request_uri; }
 listen 80; listen [::]:80; server_name DOMAIN; return 404;
}'''.replace('BODY', legacy.legacy_body(self.domain)).replace('DOMAIN', self.domain)

    def test_certbot_layout(self):
        legacy.check(self.site, self.domain)
        legacy.check(self.site.replace(' ipv6only=on',''), self.domain)

    def test_foreign_edits_refused(self):
        for changed in (
            self.site.replace('127.0.0.1:7900', '127.0.0.1:8000'),
            self.site.replace('root /var/www/rr-nexus-certbot;', 'root /root;'),
            self.site.replace('client_max_body_size 32k;', 'client_max_body_size 32k; include /tmp/foreign;'),
            self.site.replace('return 404;', 'return 200;'),
            self.site.replace('/privkey.pem;', '/foreign.pem;'),
            self.site.replace('listen 443 ssl;', 'listen 443 ssl; listen 8443 ssl;'),
            self.site + 'server { listen 8080; }',
            self.site + '}',
        ):
            with self.subTest(change=changed[-80:]):
                with self.assertRaises(ValueError):
                    legacy.check(changed, self.domain)


if __name__ == '__main__':
    unittest.main()
