#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OPTIMIZER="$REPO_ROOT/nexus/static/optimizer.js"

node --check "$OPTIMIZER"

python3 - "$OPTIMIZER" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

# Every network call in the optimizer is third-party and must suppress cookies
# and the panel referrer. Keep this exact count deliberate so a new fetch cannot
# silently bypass the privacy contract.
fetch_calls = re.findall(r"\bfetch\((?:(?!\);).)*\);", source, flags=re.S)
assert len(fetch_calls) == 4, f"unexpected fetch count: {len(fetch_calls)}"
for call in fetch_calls:
    assert 'credentials: "omit"' in call, call[:160]
    assert 'referrerPolicy: "no-referrer"' in call, call[:160]

assert 'const HISTORY_KEY = "rr_edge_optimizer_history_v3"' in source
assert "rr_edge_optimizer_history_v2" not in source
scope_start = source.index("function historyScopeKey()")
scope_end = source.index("// 历史表现", scope_start)
scope = source[scope_start:scope_end]
for field in ("benchmarkProfile", "operator", "protocol", "use", "mode"):
    assert f"OptimizerState.{field}" in scope, field

main_start = source.index("async function optimizerStart()")
main_end = source.index("function optimizerStop()", main_start)
main = source[main_start:main_end]
assert main.count("await verifyEgressStable(") == 4
assert 'OptimizerState.egressIp = "";' in main
assert "OptimizerState.egressVerified = !!(baseline.ok && baseline.ip);" in main
assert "OptimizerState.controller.signal, false" in main
assert "if (trackEgress && resp.ok && ip && OptimizerState.egressIp) observeEgressIp(ip);" in source

reliable_start = main.index("const reliable =")
reliable_end = main.index('setProgress(100, "完成")', reliable_start)
reliable = main[reliable_start:reliable_end]
assert "OptimizerState.egressVerified" in reliable
assert "!OptimizerState.egressChanged" in reliable
assert 'mode !== "proxy" || gateAllowed' in reliable
for call in ("saveBlacklist(blist);", "saveLocal(results[0], dl);", "saveHistoryScores(results);"):
    assert main.count(call) == 1, call
    assert call in reliable, call

assert "/api/" not in source
assert "apply_config_transaction" not in source
PY

printf '%s\n' "optimizer privacy and persistence regression: ok"
