#!/usr/bin/env python3
"""Build a narrowly pinned RR 7.2.1 health patch without editing installed files.

Read the original module on stdin and write the complete candidate on stdout.
The caller owns backup, locks, an atomic installation, and its patch receipt.
This utility never edits a manifest or claims that patched bytes are pristine
release bytes. Import transform_bytes for the same side-effect-free operation.

The existing validator reads NAT rules (-C/-S); its parsers create and remove
private temporary files. Automatic address selection can perform public-IP
lookups. The subshell contains its configuration-variable changes. No firewall
writer, persistence command, or service stop is called by the patched hop loop.
"""

import hashlib
import json
import sys


SOURCE_SHA256 = "7c7da6ec8a5be181de680d7f76092b37f49f70774443e28b7d0b0531460ed69d"
PATCHED_SHA256 = "ecc1eeaf5e7ae73e2e337d94b2abcd4acf59b4bcca9eb70b1edeef92cd6e30c7"

OLD_OPERATION = '''        hop_repair_status=0
        install_hop_rules "$hop_label" "$hop_port" "$hop_specs" \\
            >/dev/null 2>&1 || hop_repair_status=$?
        case "$hop_repair_status" in
            0) ;;
            1)
                rr_health_log \\
                    "${hop_label} 端口跳跃修复失败，但已证明 live 防火墙保持原态；本轮健康检查失败"
                return 1
                ;;
            2)
                rr_health_log \\
                    "${hop_label} 端口跳跃修复后的防火墙状态不确定；Sing-box 已停止并验证 inactive"
                return 1
                ;;
            3|*)
                rr_health_log \\
                    "紧急：${hop_label} 端口跳跃修复状态不确定，且无法验证 Sing-box 已停止"
                return 1
                ;;
        esac
'''.encode("utf-8")

NEW_OPERATION = '''        # An ordinary health pass must not arm an in-flight transaction merely
        # to observe configured hops: that transaction deliberately stops ingress.
        # The validator also checks effective first-match ordering. Contain the
        # auto-address resolver's shell variables in this observation subprocess.
        if ! declare -F rr_validate_hop_rules >/dev/null 2>&1 || \\
           ! ( rr_validate_hop_rules "$hop_label" "$hop_port" "$hop_specs" ) \\
                >/dev/null 2>&1; then
            rr_health_log \\
                "${hop_label} 端口跳跃只读校验未通过；未自动改写防火墙或停止节点，请人工检查规则与后端状态"
            return 1
        fi
'''.encode("utf-8")


def transform_bytes(source: bytes) -> bytes:
    """Return exactly the pinned candidate, or refuse unknown input bytes."""
    if not isinstance(source, bytes):
        raise TypeError("source must be bytes")
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("unsupported original module SHA256")
    declaration = b"    local hop_repair_status=0\n"
    if source.count(declaration) != 1 or source.count(OLD_OPERATION) != 1:
        raise ValueError("health hop operation does not match pinned source")
    candidate = source.replace(declaration, b"", 1).replace(
        OLD_OPERATION, NEW_OPERATION, 1
    )
    if hashlib.sha256(candidate).hexdigest() != PATCHED_SHA256:
        raise ValueError("candidate SHA256 differs from pinned patch")
    return candidate


def main() -> int:
    if sys.argv[1:] == ["--describe"]:
        print(json.dumps({"source_sha256": SOURCE_SHA256,
                          "patched_sha256": PATCHED_SHA256,
                          "scope": "7.2.1 health hop observation"}))
        return 0
    if sys.argv[1:]:
        print("usage: patch-health-hop-observation.py [--describe]", file=sys.stderr)
        return 2
    try:
        candidate = transform_bytes(sys.stdin.buffer.read())
    except (TypeError, ValueError) as exc:
        print("HEALTH_HOP_PATCH_REFUSED: " + str(exc), file=sys.stderr)
        return 1
    sys.stdout.buffer.write(candidate)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
