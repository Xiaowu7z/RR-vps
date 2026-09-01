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
    ssh_option_blocks: list[str] = []
    for job in candidate_jobs.values():
        for step in job.get("steps", ()):
            body = step.get("run")
            if not body:
                continue
            lines = body.splitlines()
            for index, line in enumerate(lines):
                if line.strip() not in {"ssh_opts=(", "ssh_common=("}:
                    continue
                end = index + 1
                while end < len(lines) and lines[end].strip() != ")":
                    end += 1
                if end == len(lines):
                    raise AssertionError("unterminated SSH option array")
                ssh_option_blocks.append("\n".join(lines[index:end + 1]))
    assert len(ssh_option_blocks) == 5
    for block in ssh_option_blocks:
        tokens = block.split()
        pairs = list(zip(tokens, tokens[1:]))
        assert pairs.count(("-o", "ServerAliveInterval=30")) == 1
        assert pairs.count(("-o", "ServerAliveCountMax=6")) == 1
        assert pairs.count(("-o", "TCPKeepAlive=yes")) == 1

    push_condition = "github.event_name == 'push' && github.ref == 'refs/heads/main'"
    for name in (
        "debian-full",
        "ubuntu-upgrade",
        "ubuntu-transaction",
        "cross-machine-migration-scale",
    ):
        assert candidate_jobs[name]["if"] == push_condition, name

    debian_audit = next(
        step for step in candidate_jobs["debian-full"]["steps"]
        if step.get("name") == "Install all protocols and domain panel"
    )["run"]
    require_fragment(
        debian_audit,
        "23443 25443 n '' ''",
        "Debian active-UFW audit",
    )
    require_fragment(
        debian_audit,
        'test -z "$HY2_HOP_PORTS"',
        "Debian active-UFW audit",
    )
    require_fragment(
        debian_audit,
        "rr_netfilter_rr_namespace_is_empty",
        "Debian active-UFW audit",
    )
    assert "30000:30010" not in debian_audit

    transaction_audit = next(
        step for step in candidate_jobs["ubuntu-transaction"]["steps"]
        if step.get("name") == "Clean host and install local Nexus"
    )["run"]
    for fragment in (
        "purge -y ufw",
        "rr_audit_remove_rule_all",
        "rr_audit_assert_rule_absent",
        "rr_audit_cleanup_cross_fixture optional",
        "rr_audit_cleanup_cross_fixture required",
        "rr_audit_remove_ufw_for_netfilter",
        "rr_firewall_lock_acquire",
        "rr_firewall_lock_release",
        "--comment argo-rr-managed-block -j DROP",
        "--comment argo-rr-audit-fixture -j REDIRECT --to-ports 65431",
        "--comment rr-audit-user-sentinel -j ACCEPT",
        "--comment rr-audit-user-sentinel -j REDIRECT --to-ports 65433",
        "rr_firewall_persistence_backend_available",
        "netfilter-persistent save",
        "service iptables save",
        'install_hop_rules HY2 "$hop_main_port" "$hop_spec"',
        'rr_validate_hop_rules HY2 "$hop_main_port" "$hop_spec"',
        'remove_hop_ports "$hop_main_port" HY2 "$hop_spec"',
    ):
        require_fragment(transaction_audit, fragment, "Ubuntu netfilter audit")
    cleanup_definition = transaction_audit.index(
        "rr_audit_cleanup_cross_fixture()"
    )
    ufw_definition = transaction_audit.index(
        "rr_audit_remove_ufw_for_netfilter()", cleanup_definition
    )
    fixture_helper = transaction_audit[cleanup_definition:ufw_definition]
    fixture_lock = fixture_helper.index("rr_firewall_lock_acquire")
    fixture_clean = fixture_helper.index(
        "rr_audit_clean_fixture_backend", fixture_lock
    )
    fixture_persist = fixture_helper.index(
        "rr_audit_persist_fixture_cleanup", fixture_clean
    )
    fixture_proof = fixture_helper.index(
        "rr_audit_assert_fixture_backend_clean", fixture_persist
    )
    fixture_release = fixture_helper.index(
        "rr_firewall_lock_release", fixture_proof
    )
    assert fixture_helper.count("rr_firewall_lock_acquire") == 1
    assert fixture_helper.count("rr_firewall_lock_release") == 1
    assert (
        fixture_lock < fixture_clean < fixture_persist
        < fixture_proof < fixture_release
    )
    first_optional = transaction_audit.index(
        "rr_audit_cleanup_cross_fixture optional", ufw_definition
    )
    ufw_helper = transaction_audit[ufw_definition:first_optional]
    ufw_lock = ufw_helper.index("rr_firewall_lock_acquire")
    ufw_disable = ufw_helper.index("ufw --force disable", ufw_lock)
    ufw_status = ufw_helper.index("status=$(LC_ALL=C ufw status", ufw_disable)
    ufw_purge = ufw_helper.index("purge -y ufw", ufw_status)
    ufw_absent = ufw_helper.rindex("if rr_ufw_installed")
    ufw_persist = ufw_helper.index(
        "rr_audit_persist_fixture_cleanup optional", ufw_absent
    )
    ufw_release = ufw_helper.index("rr_firewall_lock_release", ufw_persist)
    assert ufw_helper.count("rr_ufw_installed") == 2
    assert ufw_helper.count("rr_audit_persist_fixture_cleanup optional") == 1
    assert (
        ufw_lock < ufw_disable < ufw_status < ufw_purge
        < ufw_absent < ufw_persist < ufw_release
    )
    assert "return" not in ufw_helper[
        ufw_helper.index("\n", ufw_lock) + 1 : ufw_release
    ]
    assert "exit" not in ufw_helper[
        ufw_helper.index("\n", ufw_lock) + 1 : ufw_release
    ]
    product_uninstall = transaction_audit.index(
        "if [ -x /usr/local/bin/rr ]", first_optional
    )
    second_optional = transaction_audit.index(
        "rr_audit_cleanup_cross_fixture optional", first_optional + 1
    )
    remove_ufw = transaction_audit.index(
        "if ! rr_audit_remove_ufw_for_netfilter", second_optional
    )
    remove_runtime = transaction_audit.index(
        'rm -rf -- "$cleanup_runtime"', remove_ufw
    )
    first_candidate = transaction_audit.index(
        "install_candidate >/root/rr-audit-clean-install.log", remove_runtime
    )
    install_dependencies = transaction_audit.index(
        "install_deps </dev/null", first_candidate
    )
    required_cleanup = transaction_audit.index(
        "rr_audit_cleanup_cross_fixture required", install_dependencies
    )
    hop_install = transaction_audit.index(
        'install_hop_rules HY2 "$hop_main_port" "$hop_spec"', required_cleanup
    )
    hop_validate = transaction_audit.index(
        'rr_validate_hop_rules HY2 "$hop_main_port" "$hop_spec"', hop_install
    )
    hop_remove = transaction_audit.index(
        'remove_hop_ports "$hop_main_port" HY2 "$hop_spec"', hop_validate
    )
    hop_absent = transaction_audit.index(
        "rr_netfilter_rr_namespace_is_empty", hop_remove
    )
    framework_install = transaction_audit.index(
        "install_main", hop_absent
    )
    assert (
        cleanup_definition
        < ufw_definition
        < first_optional
        < product_uninstall
        < second_optional
        < remove_ufw
        < remove_runtime
        < first_candidate
        < install_dependencies
        < required_cleanup
        < hop_install
        < hop_validate
        < hop_remove
        < hop_absent
        < framework_install
    )
    assert transaction_audit.count("rr_audit_cleanup_cross_fixture optional") == 2
    assert transaction_audit.count("rr_audit_cleanup_cross_fixture required") == 1
    flat_transaction = " ".join(transaction_audit.replace("\\\n", " ").split())
    remove_tuples = (
        'rr_audit_remove_rule_all "$backend" filter INPUT -p tcp --dport 65431 '
        '-m comment --comment argo-rr-managed-block -j DROP',
        'rr_audit_remove_rule_all "$backend" nat PREROUTING -p udp --dport 65432 '
        '-m comment --comment argo-rr-audit-fixture -j REDIRECT --to-ports 65431',
        'rr_audit_remove_rule_all "$backend" filter INPUT -p tcp --dport 65433 '
        '-m comment --comment rr-audit-user-sentinel -j ACCEPT',
        'rr_audit_remove_rule_all "$backend" nat PREROUTING -p udp --dport 65434 '
        '-m comment --comment rr-audit-user-sentinel -j REDIRECT --to-ports 65433',
    )
    for item in remove_tuples:
        assert flat_transaction.count(item) == 1, item
        proof = item.replace(
            "rr_audit_remove_rule_all", "rr_audit_assert_rule_absent", 1
        )
        assert flat_transaction.count(proof) == 1, proof

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
    cleanup_start = body.index("cleanup_b() {")
    cleanup_end = body.index("finish_ip_audit() {", cleanup_start)
    cleanup = body[cleanup_start:cleanup_end]
    for fragment in (
        "failed=false",
        'bash -s -- "$panel_port" "$node_port"',
        "rr_audit_unit_absent()",
        "rr_audit_http_routes_absent()",
        "rr_audit_capture_nginx_generation()",
        "rr_audit_old_nginx_workers_retired()",
        "rr_audit_prove_nginx_generation_retired()",
        "rr_route_evidence=false",
        "rr_route_evidence=true",
        '[ "$rr_route_evidence" = true ]',
        "rr_audit_capture_nginx_generation || failed=true",
        "rr_audit_prove_nginx_generation_retired || failed=true",
        '[ "$current_start" != "$expected_start" ] || return 1',
        "systemctl reload nginx.service",
        "elif ! bash -c '",
        "for residue in",
        "/usr/local/bin/rr /usr/local/lib/rr /usr/local/bin/sing-box",
        "/etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus",
        "/var/lib/rr-nexus",
        "/etc/systemd/system/sing-box.service",
        "/etc/systemd/system/rr-nexus.service",
        "/var/lib/rr-nexus/ip-acme /var/www/rr-nexus-ip-acme",
        "/etc/systemd/system/rr-nexus-ip-acme.service",
        "/etc/systemd/system/rr-nexus-ip-acme.timer",
        "/usr/local/lib/rr-vps/nexus-ip-cert-gate",
        "rr_audit_http_routes_absent || failed=true",
        "for unit in sing-box.service rr-nexus.service",
        'for port in "$panel_port" "$node_port"',
        'if ! port_state=$(ss -H -ltn "sport = :${port}" 2>/dev/null); then',
        'elif grep -q . <<<"$port_state"; then',
        'rm -rf -- /root/rr-audit-ip-candidate || failed=true',
        '[ "$failed" = false ]',
    ):
        require_fragment(cleanup, fragment, "public-IP failure cleanup")
    assert ">>/root/rr-audit-ip-acme.log 2>&1 || true" not in cleanup
    generation_gate = cleanup.index(
        "if [ -e /usr/local/bin/rr ] || [ -L /usr/local/bin/rr ]"
    )
    generation_capture_call = cleanup.index(
        "rr_audit_capture_nginx_generation || failed=true", generation_gate
    )
    shape_check = cleanup.index(
        "if [ -e /usr/local/bin/rr ] || [ -L /usr/local/bin/rr ]",
        generation_capture_call,
    )
    uninstall = cleanup.index("elif ! bash -c '", shape_check)
    residue_proof = cleanup.index("for residue in", uninstall)
    residue_end = cleanup.index("; do", residue_proof)
    residue_tokens = cleanup[residue_proof:residue_end].replace("\\\n", " ").split()
    for exact_path in (
        "/usr/local/bin/rr",
        "/usr/local/lib/rr",
        "/usr/local/bin/sing-box",
        "/etc/argo_vmess.conf",
        "/etc/sing-box",
        "/etc/rr-nexus",
        "/var/lib/rr-nexus",
        "/etc/systemd/system/sing-box.service",
        "/etc/systemd/system/rr-nexus.service",
    ):
        assert residue_tokens.count(exact_path) == 1
    route_definition = cleanup.index("rr_audit_http_routes_absent() {")
    route_definition_end = cleanup.index(
        "if [ -e /usr/local/bin/rr ]", route_definition
    )
    route_definition_body = cleanup[route_definition:route_definition_end]
    route_loop = route_definition_body.index("for path in")
    route_loop_end = route_definition_body.index("; do", route_loop)
    route_tokens = route_definition_body[route_loop:route_loop_end].replace(
        "\\\n", " "
    ).split()
    for exact_path in (
        "/etc/nginx/sites-available/rr-nexus.conf",
        "/etc/nginx/sites-available/rr-nexus.conf.port",
        "/etc/nginx/sites-available/rr-nexus-ip.conf",
        "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
        "/etc/nginx/sites-enabled/rr-nexus.conf",
        "/etc/nginx/sites-enabled/rr-nexus-port.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf",
    ):
        assert route_tokens.count(exact_path) == 1
    route_proof = cleanup.index(
        "rr_audit_http_routes_absent || failed=true", residue_end
    )
    generation_retirement = cleanup.index(
        "rr_audit_prove_nginx_generation_retired || failed=true", route_proof
    )
    unit_proof = cleanup.index(
        "for unit in sing-box.service rr-nexus.service",
        generation_retirement,
    )
    unit_end = cleanup.index("; do", unit_proof)
    unit_tokens = cleanup[unit_proof:unit_end].replace("\\\n", " ").split()
    for exact_unit in (
        "sing-box.service",
        "rr-nexus.service",
        "rr-nexus-ip-acme.service",
        "rr-nexus-ip-acme.timer",
    ):
        assert unit_tokens.count(exact_unit) == 1
    port_loop = cleanup.index('for port in "$panel_port" "$node_port"', unit_proof)
    port_end = cleanup.index("; do", port_loop)
    port_tokens = cleanup[port_loop:port_end].split()
    for exact_port in ('"$panel_port"', '"$node_port"'):
        assert port_tokens.count(exact_port) == 1
    assert "80" not in port_tokens
    port_query = cleanup.index(
        'if ! port_state=$(ss -H -ltn "sport = :${port}" 2>/dev/null); then',
        port_loop,
    )
    port_listener = cleanup.index(
        'elif grep -q . <<<"$port_state"; then', port_query
    )
    candidate_remove = cleanup.index(
        "rm -rf -- /root/rr-audit-ip-candidate", port_listener
    )
    final_cleanup_gate = cleanup.rindex('[ "$failed" = false ]')
    assert (
        generation_gate < generation_capture_call < shape_check < uninstall
        < residue_proof < route_proof < generation_retirement < unit_proof
        < port_query < port_listener < candidate_remove < final_cleanup_gate
    )
    finish_start = body.index("finish_ip_audit() {", cleanup_end)
    finish_end = body.index("trap finish_ip_audit EXIT", finish_start)
    finish = body[finish_start:finish_end]
    for fragment in (
        "if cleanup_b; then",
        "cleanup_status=$?",
        "IP ACME audit cleanup failed; inspect the root-only VPS log and residual services.",
        'exit "$cleanup_status"',
    ):
        require_fragment(finish, fragment, "public-IP cleanup status")
    required = (
        'set +x',
        'python3 - "$RR_IP_ACME_EMAIL" "$RR_B_PUBLIC_IPV4"',
        'not ipv4.is_global',
        'not ipv6.is_global',
        'ipv4_raw != str(ipv4)',
        'ipv6_raw != str(ipv6)',
        'RR_B_PUBLIC_IPV4 is not a global IPv4 address',
        'RR_B_PUBLIC_IPV6 is not a global IPv6 address',
        'route_probe_name="rr-audit-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
        'route_probe_value=$(openssl rand -hex 32)',
        '[[ "$route_probe_name" =~ ^rr-audit-[0-9]+-[0-9]+$ ]]',
        '[[ "$route_probe_value" =~ ^[0-9a-f]{64}$ ]]',
        'StrictHostKeyChecking=yes',
        'UserKnownHostsFile="$b_known_hosts"',
        'UserKnownHostsFile="$c_known_hosts"',
        'rr_run_with_update_locks direct 180 uninstall_all_locked',
        'declare -F rr_run_with_update_locks',
        'declare -F uninstall_all_locked',
        'elif declare -F uninstall_all >/dev/null 2>&1; then',
        'printf "%s\\n" y | uninstall_all',
        'B IP-ACME pre-clean found incomplete or linked runtime residue.',
        'B IP-ACME pre-clean failed; root-only log retained on VPS.',
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
        '/var/www/rr-nexus-ip-acme/.well-known/acme-challenge/${route_probe_name}',
        'chmod 644 "$route_probe_path"',
        'test "$(stat -c \'%u:%g:%a:%h\' -- "$route_probe_path")" = 0:0:644:1',
        'test "$probe_body" = "$route_probe_value"',
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
        'test ! -L /usr/local/bin/rr',
        'test ! -L /usr/local/lib/rr',
        'cleanup_required=false',
        'IPv6 panel remained reachable after IP ACME uninstall.',
        'old_nginx_master=$(systemctl show -p MainPID --value nginx.service)',
        'old_nginx_workers+=("${worker_pid}:${worker_start}")',
        'old_nginx_workers_retired() {',
        '[ "$current_start" != "$expected_start" ] || return 1',
        'test "$old_workers_gone" = true',
        'new_nginx_master=$(systemctl show -p MainPID --value nginx.service)',
        'test "$new_worker_count" -ge 1',
    )
    for fragment in required:
        require_fragment(body, fragment, "public-ip-acme job")
    assert body.count(
        '/usr/local/bin/rr --nexus-ip-acme-install "$address" "$email"'
    ) == 2
    assert body.count('/usr/local/bin/rr --nexus-ip-acme-uninstall') == 2
    assert body.count(
        'elif declare -F uninstall_all >/dev/null 2>&1; then'
    ) >= 2
    assert body.count('printf "%s\\n" y | uninstall_all') >= 2
    assert body.count('test "$before" = "$after"') == 2
    assert body.count(
        'assert_unit_state rr-nexus-ip-acme.timer loaded:active:enabled'
    ) == 2
    assert 'systemctl is-active' not in body
    assert 'systemctl is-enabled' not in body
    assert body.count('-verify_ip "$address" -verify_return_error') == 1
    assert body.count('grep -q \'^vless://\'') >= 4
    assert body.count('test "$probe_body" = "$route_probe_value"') == 1
    assert body.count('[[ "$route_probe_value" =~ ^[0-9a-f]{64}$ ]]') == 2
    final_start = body.index("bash -s <<'REMOTE_FINAL'")
    final_end = body.index("\nREMOTE_FINAL", final_start)
    final_cleanup = body[final_start:final_end]
    assert "assert_rr_http_routes_absent()" in final_cleanup
    assert final_cleanup.count("\nassert_rr_http_routes_absent\n") == 2
    route_start = final_cleanup.index("assert_rr_http_routes_absent() {")
    route_end = final_cleanup.index(
        "/usr/local/bin/rr --nexus-ip-acme-uninstall", route_start
    )
    final_route_helper = final_cleanup[route_start:route_end]
    final_route_loop = final_route_helper.index("for path in")
    final_route_loop_end = final_route_helper.index("; do", final_route_loop)
    final_route_tokens = final_route_helper[
        final_route_loop:final_route_loop_end
    ].replace("\\\n", " ").split()
    assert final_route_helper.count(
        '[ ! -e "$path" ] && [ ! -L "$path" ] || return 1'
    ) == 1
    for exact_path in (
        "/etc/nginx/sites-available/rr-nexus.conf",
        "/etc/nginx/sites-available/rr-nexus.conf.port",
        "/etc/nginx/sites-available/rr-nexus-ip.conf",
        "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
        "/etc/nginx/sites-enabled/rr-nexus.conf",
        "/etc/nginx/sites-enabled/rr-nexus-port.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf",
    ):
        assert final_route_tokens.count(exact_path) == 1
    worker_capture = final_cleanup.index(
        "old_nginx_master=$(systemctl show -p MainPID --value nginx.service)"
    )
    ip_uninstall = final_cleanup.index(
        "/usr/local/bin/rr --nexus-ip-acme-uninstall", worker_capture
    )
    full_uninstall = final_cleanup.index(
        "rr_run_with_update_locks direct 180 uninstall_all_locked", ip_uninstall
    )
    worker_retirement = final_cleanup.index("old_workers_gone=false", full_uninstall)
    new_generation = final_cleanup.index(
        "new_nginx_master=$(systemctl show -p MainPID --value nginx.service)",
        worker_retirement,
    )
    assert worker_capture < ip_uninstall < full_uninstall
    assert full_uninstall < worker_retirement < new_generation
    post_uninstall = body[body.index("cleanup_required=false", final_end):]
    assert 'nc -4 -z -w 5 "$RR_B_PUBLIC_IPV4" 80' not in post_uninstall
    assert "rr-audit-closed" not in post_uninstall
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
def replace_nth(text: str, old: str, new: str, occurrence: int) -> str:
    start = -1
    for _ in range(occurrence):
        start = text.index(old, start + 1)
    return text[:start] + new + text[start + len(old):]


def expect_contract_rejected(candidate: dict, label: str) -> None:
    try:
        assert_contract(candidate)
    except (AssertionError, ValueError):
        return
    raise AssertionError(f"{label} mutation was accepted")


def mutated_transaction(old: str, new: str, occurrence: int = 1) -> dict:
    candidate = deepcopy(workflow)
    step = next(
        item for item in candidate["jobs"]["ubuntu-transaction"]["steps"]
        if item.get("name") == "Clean host and install local Nexus"
    )
    step["run"] = replace_nth(step["run"], old, new, occurrence)
    return candidate


def mutated_ip_cleanup(old: str, new: str) -> dict:
    candidate = deepcopy(workflow)
    step = next(
        item for item in candidate["jobs"]["public-ip-acme"]["steps"]
        if item.get("name") == (
            "Issue and externally verify independent IPv4 and IPv6 certificates"
        )
    )
    body = step["run"]
    start = body.index("cleanup_b() {")
    end = body.index("finish_ip_audit() {", start)
    cleanup = body[start:end]
    cleanup = cleanup.replace(old, new, 1)
    step["run"] = body[:start] + cleanup + body[end:]
    return candidate


def mutated_ip_body(old: str, new: str, occurrence: int = 1) -> dict:
    candidate = deepcopy(workflow)
    step = next(
        item for item in candidate["jobs"]["public-ip-acme"]["steps"]
        if item.get("name") == (
            "Issue and externally verify independent IPv4 and IPv6 certificates"
        )
    )
    step["run"] = replace_nth(step["run"], old, new, occurrence)
    return candidate


expect_contract_rejected(
    mutated_transaction("rr_firewall_lock_acquire || return 1", ":", 1),
    "fixture firewall-lock acquire",
)
expect_contract_rejected(
    mutated_transaction("rr_firewall_lock_release || failed=true", ":", 1),
    "fixture firewall-lock release",
)
expect_contract_rejected(
    mutated_transaction("rr_firewall_lock_acquire || return 1", ":", 2),
    "UFW firewall-lock acquire",
)
expect_contract_rejected(
    mutated_transaction("rr_firewall_lock_release || failed=true", ":", 2),
    "UFW firewall-lock release",
)
expect_contract_rejected(
    mutated_transaction(
        "if rr_ufw_installed; then\n    failed=true\n  fi",
        "if false; then\n    failed=true\n  fi",
    ),
    "UFW final absence proof",
)
expect_contract_rejected(
    mutated_transaction("rr_audit_persist_fixture_cleanup optional", ":", 1),
    "post-UFW persistence",
)
expect_contract_rejected(
    mutated_transaction("rr_audit_cleanup_cross_fixture optional", ":", 1),
    "first optional fixture cleanup",
)
expect_contract_rejected(
    mutated_transaction("rr_audit_cleanup_cross_fixture optional", ":", 2),
    "second optional fixture cleanup",
)
expect_contract_rejected(
    mutated_transaction("--dport 65431", "--dport 65430", 1),
    "exact firewall fixture port",
)
expect_contract_rejected(
    mutated_transaction(
        'install_hop_rules HY2 "$hop_main_port" "$hop_spec"', ":", 1
    ),
    "real-host product hop install",
)
expect_contract_rejected(
    mutated_ip_cleanup('[ "$failed" = false ]', ":"),
    "public-IP cleanup final gate",
)
expect_contract_rejected(
    mutated_ip_cleanup("rr_route_evidence=true", "rr_route_evidence=false"),
    "public-IP cleanup Nginx route evidence",
)
expect_contract_rejected(
    mutated_ip_cleanup(
        "rr_audit_capture_nginx_generation || failed=true",
        ":",
    ),
    "public-IP cleanup Nginx generation capture",
)
expect_contract_rejected(
    mutated_ip_cleanup(
        "rr_audit_prove_nginx_generation_retired || failed=true",
        ":",
    ),
    "public-IP cleanup Nginx generation retirement",
)
expect_contract_rejected(
    mutated_ip_cleanup("elif ! bash -c '", "elif bash -c '"),
    "public-IP cleanup uninstall status",
)
expect_contract_rejected(
    mutated_ip_cleanup(
        'if ! port_state=$(ss -H -ltn "sport = :${port}" 2>/dev/null); then',
        'if port_state=$(ss -H -ltn "sport = :${port}" 2>/dev/null); then',
    ),
    "public-IP cleanup port query failure",
)
expect_contract_rejected(
    mutated_ip_cleanup("/usr/local/bin/sing-box", "/usr/local/bin/ignored"),
    "public-IP cleanup core residue",
)
expect_contract_rejected(
    mutated_ip_cleanup(
        "/etc/nginx/sites-available/rr-nexus.conf",
        "/etc/nginx/sites-available/ignored.conf",
    ),
    "public-IP cleanup owned HTTP routes",
)
expect_contract_rejected(
    mutated_ip_body(
        '[ ! -e "$path" ] && [ ! -L "$path" ] || return 1',
        '[ ! -e "$path" ] && [ ! -L "$path" ]',
        2,
    ),
    "public-IP final owned-route fail-hard proof",
)
expect_contract_rejected(
    mutated_ip_body(
        'test "$old_workers_gone" = true',
        ":",
    ),
    "public-IP final old Nginx generation retirement",
)
expect_contract_rejected(
    mutated_ip_body(
        'test "$new_worker_count" -ge 1',
        ":",
    ),
    "public-IP final new Nginx generation proof",
)
expect_contract_rejected(
    mutated_ip_cleanup("sing-box.service rr-nexus.service", "rr-nexus.service"),
    "public-IP cleanup core units",
)
expect_contract_rejected(
    mutated_ip_cleanup(
        'for port in "$panel_port" "$node_port"; do',
        'for port in "$panel_port"; do',
    ),
    "public-IP cleanup node listener",
)

mutation = deepcopy(workflow)
ssh_step = next(
    step for step in mutation["jobs"]["debian-full"]["steps"]
    if "-o ServerAliveCountMax=6" in step.get("run", "")
)
ssh_step["run"] = ssh_step["run"].replace(
    "-o ServerAliveCountMax=6", "-o ServerAliveCountMax=60", 1
)
expect_contract_rejected(mutation, "SSH keepalive retry budget")

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

mutation = deepcopy(workflow)
transaction_step = next(
    step for step in mutation["jobs"]["ubuntu-transaction"]["steps"]
    if step.get("name") == "Clean host and install local Nexus"
)
transaction_step["run"] = transaction_step["run"].replace(
    "rr_audit_cleanup_cross_fixture required", ":", 1
)
try:
    assert_contract(mutation)
except AssertionError:
    pass
else:
    raise AssertionError("required persisted fixture-cleanup mutation was accepted")

print("VPS public-IP ACME workflow contract: PASS")
PY
