#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/vps-audit.yml"

python3 - "$WORKFLOW" <<'PY'
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import subprocess
import sys

import yaml


path = Path(sys.argv[1])
workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
jobs = workflow["jobs"]


def require_fragment(body: str, fragment: str, label: str) -> None:
    if fragment not in body:
        raise AssertionError(f"{label} omitted {fragment!r}")


def assert_contract(candidate: dict) -> None:
    candidate_jobs = candidate["jobs"]
    push_condition = "github.event_name == 'push' && github.ref == 'refs/heads/main'"
    for name in (
        "debian-full",
        "ubuntu-upgrade",
        "ubuntu-transaction",
        "cross-machine-migration-scale",
    ):
        assert candidate_jobs[name]["if"] == push_condition, name

    ip_job = candidate_jobs["public-ip-acme"]
    assert ip_job["if"] == (
        "github.event_name == 'workflow_dispatch' && "
        "github.ref == 'refs/heads/main'"
    )
    assert ip_job["timeout-minutes"] == 90
    assert "needs" not in ip_job
    steps = ip_job["steps"]
    checkout = next(step for step in steps if step.get("name") == "Check out exact candidate")
    assert checkout["uses"] == (
        "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
    )
    assert checkout["with"] == {
        "ref": "${{ github.sha }}",
        "persist-credentials": False,
        "fetch-depth": 1,
    }
    audit = next(
        step for step in steps
        if step.get("name") == (
            "Issue and externally verify independent IPv4 and IPv6 certificates"
        )
    )
    expected_secret_bindings = {
        "RR_IP_ACME_EMAIL": "${{ secrets.RR_IP_ACME_EMAIL }}",
        "RR_B_HOST": "${{ secrets.RR_B_HOST }}",
        "RR_B_PASS": "${{ secrets.RR_B_PASS }}",
        "RR_B_PUBLIC_IPV4": "${{ secrets.RR_B_PUBLIC_IPV4 }}",
        "RR_B_PUBLIC_IPV6": "${{ secrets.RR_B_PUBLIC_IPV6 }}",
        "RR_C_HOST": "${{ secrets.RR_C_HOST }}",
        "RR_C_PASS": "${{ secrets.RR_C_PASS }}",
    }
    for key, value in expected_secret_bindings.items():
        assert audit["env"].get(key) == value, key
    body = audit["run"]
    required = (
        'set +x',
        'python3 - "$RR_IP_ACME_EMAIL" "$RR_B_PUBLIC_IPV4"',
        'not ipv4.is_global',
        'not ipv6.is_global',
        'ipv4_raw != str(ipv4)',
        'ipv6_raw != str(ipv6)',
        'RR_B_PUBLIC_IPV4 is not a global IPv4 address',
        'RR_B_PUBLIC_IPV6 is not a global IPv6 address',
        'StrictHostKeyChecking=yes',
        'UserKnownHostsFile="$b_known_hosts"',
        'UserKnownHostsFile="$c_known_hosts"',
        'rr_run_with_update_locks direct 180 uninstall_all_locked',
        'bash "$stage/install-core.sh" --upgrade',
        "printf '%s\\n' 1 18081 \"$node_port\" ''",
        'nexus_install',
        'INSERT INTO devices(',
        'grep -q \'^vless://\'',
        'nexus_write_config public "$address" "$panel_port" "$stats_port"',
        'pending-acme-ip',
        '/usr/local/bin/rr --nexus-ip-acme-install "$address" "$email"',
        '/usr/local/bin/rr --nexus-ip-acme-uninstall',
        'acme-ip-shortlived',
        'assert_unit_state rr-nexus-ip-acme.timer loaded:active:enabled',
        'systemctl start rr-nexus-ip-acme.service',
        'test "$before" = "$after"',
        'nc -4 -z -w 10 "$RR_B_PUBLIC_IPV4" 80',
        '-verify_ip "$RR_B_PUBLIC_IPV4" -verify_return_error',
        'curl -fsS --noproxy \'*\' --connect-timeout 10 --max-time 30 "$ipv4_url"',
        '"http://[${address}]/.well-known/acme-challenge/rr-audit-not-found"',
        'test "$http_code" = 404',
        '-connect "[${address}]:${panel_port}"',
        '-verify_ip "$address" -verify_return_error',
        'curl -gfsS --noproxy \'*\' --connect-timeout 10 --max-time 30',
        '/var/lib/rr-nexus/ip-acme /var/www/rr-nexus-ip-acme',
        '/etc/systemd/system/rr-nexus-ip-acme.service',
        '/etc/systemd/system/rr-nexus-ip-acme.timer',
        '/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf',
        '/etc/nginx/sites-available/rr-nexus-ip.conf',
        '/etc/rr-nexus/certs/ip.crt /etc/rr-nexus/certs/ip.key',
        '/usr/local/lib/rr-vps/nexus-ip-cert-gate',
        'assert_unit_state rr-nexus-ip-acme.service not-found:inactive:not-found',
        'assert_unit_state rr-nexus-ip-acme.timer not-found:inactive:not-found',
        'assert_unit_state rr-nexus.service loaded:active:enabled',
        'assert_unit_state sing-box.service loaded:active:enabled',
        'grep -Fq ":${node_port}?"',
        'test ! -e /usr/local/bin/rr',
        'cleanup_required=false',
        'IP ACME audit HTTP challenge port remained reachable after uninstall.',
        'IPv6 panel remained reachable after IP ACME uninstall.',
        'IPv6 challenge port remained reachable after IP ACME uninstall.',
    )
    for fragment in required:
        require_fragment(body, fragment, "public-ip-acme job")
    assert body.count(
        '/usr/local/bin/rr --nexus-ip-acme-install "$address" "$email"'
    ) == 2
    assert body.count('test "$before" = "$after"') == 2
    assert body.count(
        'assert_unit_state rr-nexus-ip-acme.timer loaded:active:enabled'
    ) == 2
    assert 'systemctl is-active' not in body
    assert 'systemctl is-enabled' not in body
    assert body.count('-verify_ip "$address" -verify_return_error') == 1
    assert body.count('grep -q \'^vless://\'') >= 4
    for forbidden in (
        "set -x",
        'echo "$RR_IP_ACME_EMAIL"',
        'echo "$RR_B_PASS"',
        'echo "$RR_C_PASS"',
        'echo "$ipv4_url"',
        'echo "$ipv6_url"',
    ):
        if forbidden in body:
            raise AssertionError(f"audit can disclose a secret or token: {forbidden}")

    gate = candidate_jobs["vps-gate"]
    assert gate["if"] == "always()"
    assert gate["needs"] == [
        "debian-full",
        "ubuntu-upgrade",
        "ubuntu-transaction",
        "cross-machine-migration-scale",
        "public-ip-acme",
    ]
    gate_step = gate["steps"][0]
    assert gate_step["env"] == {
        "A_RESULT": "${{ needs.debian-full.result }}",
        "B_RESULT": "${{ needs.ubuntu-upgrade.result }}",
        "C_RESULT": "${{ needs.ubuntu-transaction.result }}",
        "M_RESULT": "${{ needs.cross-machine-migration-scale.result }}",
        "IP_RESULT": "${{ needs.public-ip-acme.result }}",
    }
    gate_body = gate_step["run"]
    for fragment in (
        'case "$GITHUB_EVENT_NAME" in',
        "push)",
        'test "$A_RESULT" = success',
        'test "$B_RESULT" = success',
        'test "$C_RESULT" = success',
        'test "$M_RESULT" = success',
        'test "$IP_RESULT" = skipped',
        "workflow_dispatch)",
        'test "$A_RESULT" = skipped',
        'test "$B_RESULT" = skipped',
        'test "$C_RESULT" = skipped',
        'test "$M_RESULT" = skipped',
        'test "$IP_RESULT" = success',
        "*) exit 1 ;;",
    ):
        require_fragment(gate_body, fragment, "event-complete gate")


assert_contract(workflow)

# Every embedded shell block must parse independently. This catches malformed
# nested heredocs as well as ordinary Bash syntax regressions.
for job_name, job in jobs.items():
    for index, step in enumerate(job.get("steps", ())):
        body = step.get("run")
        if not body:
            continue
        result = subprocess.run(
            ["bash", "-n"],
            input=body,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode:
            raise AssertionError(
                f"invalid embedded Bash in {job_name} step {index}: {result.stderr}"
            )

# Mutation checks prove the test is fail-closed for its three release-critical
# relationships instead of merely searching the unmodified document.
mutation = deepcopy(workflow)
mutation["jobs"]["public-ip-acme"]["if"] = (
    "github.event_name == 'push' && github.ref == 'refs/heads/main'"
)
try:
    assert_contract(mutation)
except AssertionError:
    pass
else:
    raise AssertionError("dispatch-to-push mutation was accepted")

mutation = deepcopy(workflow)
gate_run = mutation["jobs"]["vps-gate"]["steps"][0]["run"]
mutation["jobs"]["vps-gate"]["steps"][0]["run"] = gate_run.replace(
    'test "$IP_RESULT" = skipped', ":", 1
)
try:
    assert_contract(mutation)
except AssertionError:
    pass
else:
    raise AssertionError("push IP-skipped gate mutation was accepted")

mutation = deepcopy(workflow)
audit_step = mutation["jobs"]["public-ip-acme"]["steps"][2]
audit_step["run"] = audit_step["run"].replace(
    '-verify_ip "$RR_B_PUBLIC_IPV4" -verify_return_error',
    "-verify_return_error",
    1,
)
try:
    assert_contract(mutation)
except AssertionError:
    pass
else:
    raise AssertionError("IPv4 IP-SAN verification mutation was accepted")

print("VPS public-IP ACME workflow contract: PASS")
PY
