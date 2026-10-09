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
    "bad-numbers.conf|1|Jmin(80) 不能大于 Jmax(10)"
    "no-jc.conf|0|缺少客户端本地混淆参数"
    "jmin-eq-jmax.conf|0|"
    "s-conflict.conf|0|S1+56 恰好等于 S2"
    "peer-first-indented.conf|0|"
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

# ---------- 静态守卫: 安装路径必须经过唯一的校验闸 ----------
# 为什么要有这条: 早期版本 validate_config() 恒 return 0, 而主流程只看函数返回码,
# 于是"拦住残废配置"这个核心承诺在**安装路径**上完全失效 —— 但 --validate-config
# 路径单独读 VAL_ERRORS, 所以整个测试套件照样全绿。行为测试测不到这条, 只能用源码级断言钉住。
echo
echo "静态守卫(安装路径必须走 config_gate):"
if grep -q 'if ! config_gate "\$CONF_TMP"; then' "$SCRIPT"; then
    printf '  \033[0;32mPASS\033[0m  安装路径调用 config_gate\n'
    PASS=$((PASS + 1))
else
    printf '  \033[0;31mFAIL\033[0m  安装路径没有调用 config_gate —— B1 类 bug 会复活\n'
    FAIL=$((FAIL + 1))
fi
if grep -qE '^[[:space:]]*\[ "\$VAL_ERRORS" -eq 0 \][[:space:]]*$' "$SCRIPT"; then
    printf '  \033[0;32mPASS\033[0m  validate_config 按 VAL_ERRORS 决定返回码\n'
    PASS=$((PASS + 1))
else
    printf '  \033[0;31mFAIL\033[0m  validate_config 没有按 VAL_ERRORS 返回(闸门失效)\n'
    FAIL=$((FAIL + 1))
fi

echo
echo "结果: 通过 $PASS, 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
