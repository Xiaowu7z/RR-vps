#!/bin/bash
# RR-vps 发布前检查。可从任意工作目录执行。
set -euo pipefail

BASE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$BASE"

echo "[pre-push] 仓库回归测试"
bash scripts/validate.sh

echo "[pre-push] 可复现发布物检查"
python3 scripts/rebuild-bundle.py --check

if command -v shellcheck >/dev/null 2>&1; then
    echo "[pre-push] ShellCheck（error 级别）"
    shellcheck --severity=error rr install.sh modules/*.sh scripts/*.sh
else
    echo "[pre-push] 提示：本机未安装 shellcheck；GitHub Actions 会执行该检查。"
fi

echo "[pre-push] 全量通过，可以 push。"
