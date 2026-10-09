#!/usr/bin/env bash
# ============================================================
# tests/run-tests.sh — amneziawg-install 配置校验器回归测试
#
# 只测 --validate-config 这条纯离线路径(不装包、不起隧道、不需要 root),
# 因此在开发机(含 Windows Git Bash)上就能跑。
#
# Usage: bash tests/run-tests.sh
# ============================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../amneziawg-install.sh"
FIXTURES="$HERE/fixtures"

PASS=0
FAIL=0

# 用例表: 文件名|期望退出码|期望输出里必须出现的关键词(用 | 分隔多个)
CASES=(
    "good-amneziawg.conf|0|混淆参数:"
    "full-tunnel-mtu.conf|0|"
    "plain-wireguard.conf|1|没有任何 AmneziaWG 混淆字段"
    "glinet-incomplete.conf|1|混淆字段残缺"
    "h-overlap.conf|1|H 字段区间重叠"
    "bad-numbers.conf|1|Jmin(80) 必须小于 Jmax(10)"
    "no-jc.conf|0|缺少客户端本地混淆参数"
    "missing-keys.conf|1|缺少"
)

run_case() {
    local spec="$1"
    local file expect musts out rc
    file="${spec%%|*}"
    spec="${spec#*|}"
    expect="${spec%%|*}"
    musts="${spec#*|}"

    out=$(bash "$SCRIPT" --validate-config "$FIXTURES/$file" 2>&1)
    rc=$?

    local problems=""
    if [ "$rc" != "$expect" ]; then
        problems="退出码期望 $expect 实际 $rc"
    fi
    if [ -n "$musts" ]; then
        local m
        while IFS= read -r m; do
            [ -n "$m" ] || continue
            if ! printf '%s' "$out" | grep -qF "$m"; then
                problems="$problems; 输出缺少关键信息: $m"
            fi
        done < <(printf '%s' "$musts" | tr '|' '\n')
    fi

    if [ -z "$problems" ]; then
        printf '  \033[0;32mPASS\033[0m  %-26s (退出码 %s)\n' "$file" "$rc"
        PASS=$((PASS + 1))
    else
        printf '  \033[0;31mFAIL\033[0m  %-26s ->%s\n' "$file" "$problems"
        printf '        ---- 实际输出 ----\n'
        printf '%s\n' "$out" | sed 's/^/        /'
        printf '        ------------------\n'
        FAIL=$((FAIL + 1))
    fi
}

echo "amneziawg-install 配置校验测试"
echo "脚本: $SCRIPT"
echo

for c in "${CASES[@]}"; do
    run_case "$c"
done

# ---------- 特殊用例: CRLF(Windows)行尾必须能被自动归一化 ----------
# 这个用例的输入在运行时生成, 仓库里保持 LF 干净
CRLF_TMP=$(mktemp /tmp/awg-crlf.XXXXXX)
trap 'rm -f "$CRLF_TMP"' EXIT
sed 's/$/\r/' "$FIXTURES/good-amneziawg.conf" > "$CRLF_TMP"
out=$(bash "$SCRIPT" --validate-config "$CRLF_TMP" 2>&1)
rc=$?
problems=""
if [ "$rc" != 0 ]; then
    problems="退出码期望 0 实际 $rc"
fi
if ! printf '%s' "$out" | grep -qF "CR 字符"; then
    problems="$problems; 没有提示检测到 CR(Windows 行尾)"
fi
if [ -z "$problems" ]; then
    printf '  \033[0;32mPASS\033[0m  %-26s (退出码 %s)\n' "good-amneziawg.conf(CRLF)" "$rc"
    PASS=$((PASS + 1))
else
    printf '  \033[0;31mFAIL\033[0m  %-26s ->%s\n' "good-amneziawg.conf(CRLF)" "$problems"
    printf '        ---- 实际输出 ----\n'
    printf '%s\n' "$out" | sed 's/^/        /'
    printf '        ------------------\n'
    FAIL=$((FAIL + 1))
fi

echo
echo "结果: 通过 $PASS, 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
