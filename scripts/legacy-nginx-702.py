#!/usr/bin/env python3
"""Recognize the exact RR 7.0.2 site plus bounded Certbot TLS/redirect edits."""
import collections
from pathlib import Path
import re
import sys

DOMAIN = re.compile(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}')


def parse(text):
    if len(text) > 131072 or '\0' in text or '"' in text or "'" in text or '\\' in text:
        raise ValueError('unsupported site syntax')
    tokens = re.findall(r'#[^\n]*|[{};]|[^\s{};#]+', text)
    tokens = [t for t in tokens if not t.startswith('#')]
    index = 0

    def block(nested=False):
        nonlocal index
        nodes, words = [], []
        while index < len(tokens):
            token = tokens[index]
            index += 1
            if token == '}':
                if not nested or words:
                    raise ValueError('unbalanced site')
                return tuple(nodes)
            if token == '{':
                if not words:
                    raise ValueError('unnamed block')
                nodes.append((tuple(words), block(True)))
                words = []
            elif token == ';':
                if not words:
                    raise ValueError('empty directive')
                nodes.append((tuple(words), None))
                words = []
            else:
                words.append(token)
        if nested or words:
            raise ValueError('incomplete site')
        return tuple(nodes)

    return block()


def canonical(nodes):
    return collections.Counter((args, None if children is None else
        tuple(sorted(canonical(children).items(), key=repr))) for args, children in nodes)


def legacy_body(domain):
    return '''server_name DOMAIN;
client_max_body_size 32k;
location /.well-known/acme-challenge/ { root /var/www/rr-nexus-certbot; }
location = /api/login {
 limit_req zone=rr_nexus_login burst=5 nodelay;
 proxy_pass http://127.0.0.1:7900;
 proxy_set_header Host $host;
 proxy_set_header X-Real-IP $remote_addr;
 proxy_set_header X-Forwarded-For $remote_addr;
 proxy_set_header X-Forwarded-Proto $scheme;
}
location / {
 proxy_pass http://127.0.0.1:7900;
 proxy_http_version 1.1;
 proxy_set_header Host $host;
 proxy_set_header X-Real-IP $remote_addr;
 proxy_set_header X-Forwarded-For $remote_addr;
 proxy_set_header X-Forwarded-Proto $scheme;
 proxy_connect_timeout 5s;
 proxy_read_timeout 65s;
}'''.replace('DOMAIN', domain)


def check(text, domain):
    if not DOMAIN.fullmatch(domain):
        raise ValueError('invalid domain')
    nodes = parse(text)
    zone = parse('limit_req_zone $binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;')[0]
    if len(nodes) != 3 or nodes.count(zone) != 1:
        raise ValueError('site is not the RR 7.0.2 layout')
    servers = [children for args, children in nodes if args == ('server',) and children is not None]
    if len(servers) != 2:
        raise ValueError('unexpected server blocks')
    tls = [s for s in servers if any(a[0] == 'ssl_certificate' for a, _ in s)]
    if len(tls) != 1:
        raise ValueError('unexpected TLS server')
    special = {'listen', 'ssl_certificate', 'ssl_certificate_key', 'include', 'ssl_dhparam'}
    body = tuple((a, c) for a, c in tls[0] if a[0] not in special)
    if canonical(body) != canonical(parse(legacy_body(domain))):
        raise ValueError('customized legacy proxy; automatic replacement refused')
    ssl = tuple((a, c) for a, c in tls[0] if a[0] in special)
    expected = f'''listen 443 ssl; listen [::]:443 ssl;
ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
include /etc/letsencrypt/options-ssl-nginx.conf;
ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;'''
    if not any(canonical(ssl) == canonical(parse(expected.replace('[::]:443 ssl;', variant)))
               for variant in ('[::]:443 ssl;', '[::]:443 ssl ipv6only=on;')):
        raise ValueError('unrecognized Certbot TLS directives')
    http = servers[1] if servers[0] == tls[0] else servers[0]
    redirect = f'''if ($host = {domain}) {{ return 301 https://$host$request_uri; }}
listen 80; listen [::]:80; server_name {domain}; return 404;'''
    if canonical(http) != canonical(parse(redirect)):
        raise ValueError('unrecognized Certbot redirect server')


def main():
    path, domain = sys.argv[1:]
    check(Path(path).read_text(), domain)
    print('LEGACY_NGINX_LAYOUT_VERIFIED')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print('LEGACY_NGINX_REFUSED: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
