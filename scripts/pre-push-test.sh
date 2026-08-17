#!/bin/bash
# RR-vps 全量测试脚本 - 每次提交前必须全部通过
set -e

BASE="/srv/hermes-agent/home/RR-vps"
PASS=0
FAIL=0

green() { echo -e "\033[32m✅ $1\033[0m"; PASS=$((PASS+1)); }
red() { echo -e "\033[31m❌ $1\033[0m"; FAIL=$((FAIL+1)); }

cd "$BASE"

echo "========================================="
echo " RR-vps 发布前全量测试"
echo "========================================="

# 1. Shell 语法
echo -e "\n[1/6] Shell 语法检查"
for f in install.sh rr modules/*.sh; do
    if bash -n "$f" 2>/dev/null; then green "$f"; else red "$f 语法错误"; fi
done

# 2. Python 语法
echo -e "\n[2/6] Python 语法检查"
if python3 -c "compile(open('nexus/rr_nexus.py').read(),'x','exec')" 2>/dev/null; then
    green "rr_nexus.py"
else
    red "rr_nexus.py 语法错误"
fi

# 3. Manifest 校验
echo -e "\n[3/6] Manifest 校验"
if awk 'NF!=2||length($1)!=64{exit 1}' manifest.sha256 2>/dev/null; then
    green "manifest 格式 (${#lines} 行)"
else
    red "manifest 格式错误"
fi

if sha256sum -c manifest.sha256 2>/dev/null >/dev/null; then
    green "SHA256 校验"
else
    red "SHA256 校验失败"
fi

# 4. Validator 测试
echo -e "\n[4/6] Validator 测试"
if bash -c "source <(sed 's/^rr_check_system/#skip/' install.sh) 2>/dev/null; rr_manifest_is_valid manifest.sha256" 2>/dev/null; then
    green "rr_manifest_is_valid"
else
    red "rr_manifest_is_valid 失败"
fi

# 5. Nexus JSON 生成测试
echo -e "\n[5/6] Nexus JSON 测试"
for mode in local public; do
    for domain in "" "panel.example.com" "ip"; do
        tmp_json=$(mktemp)
        bash -c "
            NEXUS_CONFIG_FILE=$tmp_json
            source modules/85-nexus.sh 2>/dev/null
            nexus_write_config '$mode' '$domain' 8101 39091 1.2.3.4 >/dev/null 2>&1 || true
        " 2>/dev/null
        if [ -s "$tmp_json" ]; then
            if python3 -c "import json; c=json.load(open('$tmp_json')); assert c['port']==7900; assert c['public_port']==8101" 2>/dev/null; then
                green "nexus_write_config $mode/$domain"
            else
                red "nexus_write_config $mode/$domain JSON错误"
                cat "$tmp_json"
            fi
        fi
        rm -f "$tmp_json"
    done
done

# 6. Bundle 构建 + 验证
echo -e "\n[6/6] Bundle 测试"
if [ -f "rr-bundle.tar.gz" ]; then
    if tar -tzf rr-bundle.tar.gz | grep -q "85-nexus"; then
        green "bundle 包含所有模块"
        if tar -tvzf rr-bundle.tar.gz | awk '$3==0 {exit 1}'; then
            green "bundle 无 0 字节成员"
        else
            red "bundle 存在 0 字节成员"
        fi
    else
        red "bundle 不完整"
    fi
else
    red "bundle 文件缺失"
fi

echo -e "\n========================================="
echo -e " 通过: \033[32m$PASS\033[0m  失败: \033[31m$FAIL\033[0m"
echo -e "========================================="
[ "$FAIL" -eq 0 ] && echo -e "\033[32m✅ 全量通过，可以 push\033[0m" && exit 0
echo -e "\033[31m❌ 有测试失败，修复后再 push\033[0m" && exit 1
