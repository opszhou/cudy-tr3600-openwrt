#!/usr/bin/env bash
# 沙箱测试：apply-qmodem-nat2.sh 的替换 / 幂等 / 格式不符失败 / 缺文件失败。
# 不依赖真实 OpenWrt 源码树，构造临时 feeds 目录即可运行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ROOT/scripts/apply-qmodem-nat2.sh"
OLD_LINE='[ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",1"'
NEW_LINE='[ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",2"'

TMP="$(mktemp -d /tmp/qmnat2.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/feeds/qmodem/application/qmodem/files/usr/share/qmodem/modem_dial.sh"
mkdir -p "$(dirname "$F")"

pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then
        echo "✅ $1"
        pass=$((pass + 1))
    else
        echo "❌ $1: 期望 [$3] 实际 [$2]"
        fail=$((fail + 1))
    fi
}

# 用例 1：正常替换（样本含 quectel 分支上下文）
printf '%s\n' '#!/bin/sh' 'at_dial()' '{' '    case $manufacturer in' '        "quectel")' "            $OLD_LINE" '            ;;' '    esac' '}' > "$F"
bash "$APPLY" "$TMP" > /dev/null
check "替换后命中 nat=2" "$(grep -cF "$NEW_LINE" "$F")" "1"
check "替换后无 nat=1 残留" "$(grep -cF "$OLD_LINE" "$F")" "0"
check "其它行未被破坏" "$(grep -cF 'case $manufacturer in' "$F")" "1"

# 用例 2：幂等，再跑一次仍只有一行
bash "$APPLY" "$TMP" > /dev/null
check "二次运行仍只有 1 行 nat=2" "$(grep -cF "$NEW_LINE" "$F")" "1"

# 用例 3：源码格式不符必须失败，不静默跳过
printf '%s\n' '#!/bin/sh' 'nat_cfg="SOMETHING_ELSE"' > "$F"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
    check "格式不符应失败" "未失败" "失败"
else
    check "格式不符应失败" "失败" "失败"
fi

# 用例 4：找不到 modem_dial.sh 必须失败
rm -f "$F"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
    check "缺少文件应失败" "未失败" "失败"
else
    check "缺少文件应失败" "失败" "失败"
fi

echo "---- 通过 $pass / 失败 $fail ----"
[ "$fail" -eq 0 ]
