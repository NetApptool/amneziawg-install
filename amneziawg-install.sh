#!/usr/bin/env bash
# ============================================================
# amneziawg-install — 跨发行版 AmneziaWG 客户端一键安装脚本
# Project : https://github.com/NetApptool/amneziawg-install
# License : MIT
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NetApptool/amneziawg-install/main/amneziawg-install.sh -o /tmp/awg-install.sh
#   sudo bash /tmp/awg-install.sh                       # 交互: 粘贴配置 + Ctrl+D
#   sudo bash /tmp/awg-install.sh --config /root/awg0.conf
#   bash /tmp/awg-install.sh --validate-config ./awg0.conf   # 免 root 只校验
#
# 目标机拉不到 GitHub(内网/信创): 直接把脚本文件 scp 过去跑, 效果完全一样。
#   脚本不依赖任何私网资源; awg 二进制也拉不到时, 先在联网机器上编译好再拷 /usr/bin/。
#
# Tested on:
#   Ubuntu 22.04+ / Debian 12 / Rocky 9 / RHEL 9 / AlmaLinux 9 /
#   Fedora 39+ / openEuler 22+ / Arch / Manjaro
#
# 为什么需要这个脚本(和原生 WireGuard 的区别):
#   1) 装的东西不一样: amneziawg-tools 提供 awg / awg-quick(不是 wg / wg-quick)
#   2) 配置目录不一样: /etc/amnezia/amneziawg/<ifname>.conf(不是 /etc/wireguard/)
#   3) systemd 单元不一样: awg-quick@<ifname>(不是 wg-quick@<ifname>)
#   4) 配置必须带混淆字段: Jc/Jmin/Jmax/S1-S4/H1-H4, 缺了连不上(本脚本会拦)
#   5) 内核模块上游不内置: 走 dkms 编译, 编译不了自动回退用户态 amneziawg-go
#
# 已知限制:
#   - 内核模块路线需要内核头文件; 信创/老内核(麒麟 V10 4.19 等)编译常失败,
#     脚本会自动建议并回退到用户态 amneziawg-go(需要 Go ≥ 1.25 构建)
#   - 用户态实现吞吐明显低于内核态, 适合"能连上"优先的场景
# ============================================================

VERSION="0.2.0"

set -euo pipefail

# ---------------- 默认参数(可被命令行覆盖) ----------------
IFNAME="awg0"                 # 接口名 = 配置文件名去 .conf = systemd 单元实例名
CONF_SRC=""                   # --config 指定的配置来源(非交互)
IMPL="auto"                   # auto | kernel | userspace
ASSUME_YES=0                  # --yes: 所有交互取默认值
START_NOW="ask"               # ask | yes | no
VALIDATE_ONLY=""              # --validate-config <file>: 只校验配置后退出
ALLOW_INCOMPLETE=0            # --allow-incomplete: 允许缺少混淆字段继续
AWG_DIR="/etc/amnezia/amneziawg"
LOG_FILE="/tmp/amneziawg-install.log"
GO_MIN="1.25"                 # amneziawg-go 的 go.mod 要求 go 1.25.0
AWGGO_REPO="github.com/amnezia-vpn/amneziawg-go/v3"

# ---------------- CLI ----------------
usage() {
    cat <<EOF
amneziawg-install v$VERSION  跨发行版 AmneziaWG 客户端一键安装脚本

Usage:
  curl -fsSL https://raw.githubusercontent.com/NetApptool/amneziawg-install/main/amneziawg-install.sh -o /tmp/awg-install.sh
  sudo bash /tmp/awg-install.sh                       # 交互: 粘贴配置 + Ctrl+D
  sudo bash /tmp/awg-install.sh --config /root/awg0.conf
  bash /tmp/awg-install.sh --validate-config ./awg0.conf   # 免 root 只校验配置

  目标机拉不到 GitHub(内网/信创): scp 把本脚本传过去跑, 效果一样。

Options:
  -h, --help              显示本帮助
  -v, --version           显示版本
      --config FILE       从文件读配置(非交互); 缺省为交互粘贴 + Ctrl+D
      --ifname NAME       接口名, 默认 awg0
      --kernel            强制走内核模块(dkms)路线
      --userspace         强制走用户态 amneziawg-go 路线
      --yes, -y           所有交互取默认值(无人值守)
      --no-start          写入配置但不启动隧道、不开机自启
      --validate-config F 只校验配置文件的合法性并退出(不装任何东西)
      --allow-incomplete  允许混淆字段不全的配置继续(不推荐)

Features:
  - 自动识别发行版并装 amneziawg-tools(提供 awg / awg-quick)
  - 内核模块编译失败自动回退用户态 amneziawg-go(信创/老内核可用)
  - 混淆字段分级校验(拦住 GL.iNet 网页二维码那种"残废配置")
  - Windows(CRLF)行尾自动归一化
  - SSH 自保护(0.0.0.0/0 全流量时防 SSH 断连)
  - 可选 Kill Switch / 可选 MTU 1280(4G/5G 场景)
  - DNS 自管(不依赖 systemd-resolved/openresolv, 跨发行版稳定)
  - 自动开机自启 + 启动后自检(握手 + 出口 IP + DNS)
  - 收尾提示用 awg show(wg show 在 AmneziaWG 上是空的)

Project: https://github.com/NetApptool/amneziawg-install
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)          usage; exit 0 ;;
        -v|--version)       echo "amneziawg-install v$VERSION"; exit 0 ;;
        --config)           CONF_SRC="${2:-}"; [ -n "$CONF_SRC" ] || { echo "缺少 --config 的文件名" >&2; exit 2; }; shift 2 ;;
        --ifname)           IFNAME="${2:-}";   [ -n "$IFNAME" ]   || { echo "缺少 --ifname 的值" >&2; exit 2; }; shift 2 ;;
        --kernel)           IMPL="kernel"; shift ;;
        --userspace)        IMPL="userspace"; shift ;;
        --yes|-y)           ASSUME_YES=1; shift ;;
        --no-start)         START_NOW="no"; shift ;;
        --validate-config)  VALIDATE_ONLY="${2:-}"; [ -n "$VALIDATE_ONLY" ] || { echo "缺少 --validate-config 的文件名" >&2; exit 2; }; shift 2 ;;
        --allow-incomplete) ALLOW_INCOMPLETE=1; shift ;;
        *) echo "未知参数: $1  (用 --help 查看用法)" >&2; exit 2 ;;
    esac
done

# 接口名合法性(与 awg-quick 的校验保持一致: 1-15 位, 字母数字 _ = + . -)
if ! printf '%s' "$IFNAME" | grep -qE '^[a-zA-Z0-9_=+.-]{1,15}$'; then
    echo "接口名不合法: $IFNAME (只允许 1-15 位字母数字 _ = + . -)" >&2
    exit 2
fi

# ---------------- 颜色 ----------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------------- 日志与输出 ----------------
# 安全: 本脚本以 root 运行, 日志路径固定写在 /tmp —— 必须防两件事
#   ① 符号链接攻击: 本机普通用户预先在 /tmp 造同名软链指向 /etc/shadow, root 一跑就把它清空
#   ② 日志本身被全局可读: 里面会记到 Endpoint / 隧道地址 / 出口 IP / 混淆参数(准密钥材料)
if [ -L "$LOG_FILE" ]; then
    echo "警告: $LOG_FILE 是符号链接(疑似符号链接攻击), 本次不写日志" >&2
    LOG_FILE=/dev/null
elif (umask 077; : > "$LOG_FILE") 2>/dev/null; then
    chmod 600 "$LOG_FILE" 2>/dev/null || true
else
    LOG_FILE=/dev/null
fi
log()  { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null || true; }
ok()   { echo -e "      ${GREEN}✓${RESET} $*"; log "OK: $*"; }
warn() { echo -e "      ${YELLOW}⚠${RESET}  $*"; log "WARN: $*"; }
err()  { echo -e "${RED}✗${RESET} $*" >&2; log "ERR: $*"; }
info() { echo -e "      ${CYAN}·${RESET} $*"; log "INFO: $*"; }
step() { echo -e "\n${BOLD}${CYAN}[$1/7]${RESET} $2"; log "STEP $1: $2"; }
die()  { err "$*"; exit 1; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "═══════════════════════════════════════════════════"
    echo "  amneziawg-install v$VERSION  AmneziaWG 客户端一键安装"
    echo "═══════════════════════════════════════════════════"
    echo -e "${RESET}"
}

# ---------------- 交互(兼容 curl|bash) ----------------
if [ -t 0 ]; then
    TTY_IN=/dev/stdin
elif [ -e /dev/tty ]; then
    TTY_IN=/dev/tty
else
    TTY_IN=""
fi

ask() {
    local prompt="$1" default="${2:-Y}" answer
    if [ "$ASSUME_YES" = 1 ] || [ -z "$TTY_IN" ]; then
        case "$default" in [Yy]*) return 0 ;; *) return 1 ;; esac
    fi
    read -r -p "      $prompt" answer < "$TTY_IN" || answer=""
    answer="${answer:-$default}"
    case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

ask_choice() {
    local prompt="$1" default="$2" answer
    if [ "$ASSUME_YES" = 1 ] || [ -z "$TTY_IN" ]; then
        echo "$default"; return 0
    fi
    read -r -p "      $prompt" answer < "$TTY_IN" || answer=""
    echo "${answer:-$default}"
}

# ============================================================
# 配置解析 helper
#   conf_get <file> <section> <key>  —— 只取指定段里的键, 规避 [Peer] 段同名干扰
#
#   段头识别必须和 awg-quick 自己的解析器对齐(否则"能起但校验说缺段"):
#   awg-quick 先砍掉 # 之后的内容, 再把 key 前后空白 trim, 然后才比 "[Interface]";
#   所以 "  [Interface]" 和 "[Interface]  # 注释" 都是它认的合法段头。
#   (老版本这里只认第 0 列的裸 [Interface], 对上面两种写法会误报"缺少 [Interface] 段"。)
# ============================================================
conf_get() {
    awk -v want="$2" -v key="$3" '
        {
            line = $0
            sub(/#.*/, "", line)
            t = line
            sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
            if (t ~ /^\[/) {
                sec = t
                gsub(/[[:space:]\[\]]/, "", sec)
                next
            }
            if (sec == want) {
                n = index(line, "=")
                if (n == 0) next
                k = substr(line, 1, n - 1); gsub(/[[:space:]]/, "", k)
                if (k == key) {
                    v = substr(line, n + 1)
                    sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
                    print v
                    exit
                }
            }
        }
    ' "$1" 2>/dev/null || true
}

# 取所有段名, 用于校验段完整性(同样容忍缩进与行尾注释)
conf_sections() {
    awk '
        {
            line = $0
            sub(/#.*/, "", line)
            sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
            if (line ~ /^\[/) {
                sec = line
                gsub(/[[:space:]\[\]]/, "", sec)
                print sec
            }
        }' "$1" 2>/dev/null || true
}

is_uint() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

# H 值可以是单值或 a-b 区间
h_range() {  # h_range <value> -> 输出 "low high", 非法则返回 1
    local v="$1"
    case "$v" in
        *-*)
            local lo="${v%%-*}" hi="${v##*-}"
            is_uint "$lo" && is_uint "$hi" && [ "$lo" -le "$hi" ] || return 1
            printf '%s %s\n' "$lo" "$hi" ;;
        *)
            is_uint "$v" || return 1
            printf '%s %s\n' "$v" "$v" ;;
    esac
}

# ============================================================
# 配置校验 —— 本脚本与 wg-install 最大的差异点
#   返回 0 = 通过; 返回 1 = 有致命问题
#   警告信息直接打印, 通过 ERRORS/WARNINGS 计数汇总
# ============================================================
VAL_ERRORS=0
VAL_WARNINGS=0
val_err()   { err "配置错误: $*";  VAL_ERRORS=$((VAL_ERRORS + 1)); }
val_warn()  { warn "配置提示: $*"; VAL_WARNINGS=$((VAL_WARNINGS + 1)); }
# 阻断级: 语法上没错, 但几乎肯定连不上服务端(混淆字段缺失/残缺)
val_block() { err "阻断: $*"; VAL_ERRORS=$((VAL_ERRORS + 1)); }

# uint16 校验(官方文档: S1-S4/Jc/Jmin/Jmax 都是 uint16, 0-65535)
uint16_check() {  # uint16_check <字段名> <值>  -> 0 合法 / 1 已报错
    local name="$1" v="$2"
    if ! is_uint "$v"; then val_err "$name 不是非负整数: $v"; return 1; fi
    if [ "$v" -gt 65535 ]; then val_err "$name=$v 超出 uint16 上限 65535(官方文档)"; return 1; fi
    return 0
}

validate_config() {
    local f="$1"
    VAL_ERRORS=0; VAL_WARNINGS=0

    # ---------- 段完整性 ----------
    local secs; secs=$(conf_sections "$f")
    printf '%s\n' "$secs" | grep -qx 'Interface' || val_err "缺少 [Interface] 段"
    printf '%s\n' "$secs" | grep -qx 'Peer'      || val_err "缺少 [Peer] 段"
    [ "$VAL_ERRORS" -eq 0 ] || return 1

    # ---------- 必备键 ----------
    local priv addr pub ep allowed
    priv=$(conf_get "$f" Interface PrivateKey)
    addr=$(conf_get "$f" Interface Address)
    pub=$(conf_get "$f" Peer PublicKey)
    ep=$(conf_get "$f" Peer Endpoint)
    allowed=$(conf_get "$f" Peer AllowedIPs)

    [ -n "$priv" ]    || val_err "[Interface] 缺少 PrivateKey"
    [ -n "$addr" ]    || val_err "[Interface] 缺少 Address"
    [ -n "$pub" ]     || val_err "[Peer] 缺少 PublicKey"
    [ -n "$ep" ]      || val_err "[Peer] 缺少 Endpoint"
    [ -n "$allowed" ] || val_err "[Peer] 缺少 AllowedIPs"
    [ "$VAL_ERRORS" -eq 0 ] || return 1

    # 私钥/公钥格式: base64, 44 字符, 结尾 =
    printf '%s' "$priv" | grep -qE '^[A-Za-z0-9+/]{43}=$' || val_warn "PrivateKey 不像标准 base64 密钥(44 字符)"
    printf '%s' "$pub"  | grep -qE '^[A-Za-z0-9+/]{43}=$' || val_warn "PublicKey 不像标准 base64 密钥(44 字符)"

    # Endpoint 形如 host:port
    if ! printf '%s' "$ep" | grep -qE ':[0-9]{1,5}$'; then
        val_err "Endpoint 缺端口: $ep"
    else
        local port="${ep##*:}"
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            val_err "Endpoint 端口超出范围: $port"
        fi
    fi

    # ---------- 混淆字段(本项目核心校验) ----------
    # 权威来源:
    #   · docs.amnezia.org/documentation/amnezia-wg
    #       - S1-S4/Jc/Jmin/Jmax 为 uint16(0-65535); H1-H4 为 range<uint32>
    #       - "Important: H1-H4 ranges must not overlap."  ← 区间不重叠是硬约束
    #       - H1 设为 1 表示禁用 H1(H2/H3/H4 同理对应 2/3/4); 参数 0/off/0-0 即禁用该机制
    #       - len(init)=148+S1, len(resp)=92+S2
    #   · amneziawg-go README: 必须与服务端一致的 = HeaderProtectionKey, S1-S4, H1-H4;
    #     客户端本地参数(不必一致) = Jc/Jmin/Jmax, I1-I5, ContentPaddingAddition, 各类 timing
    #   · 内核模块 README: S1+56 != S2, Jmin < Jmax < 1280, S1<=1132, S2<=1188
    #   · 内核 netlink.c 实际强校验: H1-H4 两两不重叠(否则 -EINVAL), 开 header protection 时 S1-S4 >= 12
    #   现场实测: GL.iNet 网页/二维码默认按标准 WG 生成、不带这些字段 → 客户端连不上
    # 字段分三类:
    #   ① 必须与服务端一致(缺失=基本连不上) → S1 S2 H1 H2 H3 H4
    #   ② 客户端本地(缺失只损失伪装强度, 但仍提示)  → Jc Jmin Jmax
    #   ③ 只识别不评判(可选/新版本字段)           → S3 S4 I1-I5 HeaderProtectionKey 等
    local k jc jmin jmax s1 s2 hpk have=0 missing="" core_missing="" local_missing=""
    for k in S1 S2 H1 H2 H3 H4; do
        if [ -n "$(conf_get "$f" Interface "$k")" ]; then
            have=$((have + 1))
        else
            missing="$missing $k"
            core_missing="$core_missing $k"
        fi
    done
    for k in Jc Jmin Jmax; do
        if [ -n "$(conf_get "$f" Interface "$k")" ]; then
            have=$((have + 1))
        else
            local_missing="$local_missing $k"
        fi
    done
    for k in S3 S4 I1 I2 I3 I4 I5 HeaderProtectionKey ContentPaddingAddition RandomTrailers DisableCookies; do
        if [ -n "$(conf_get "$f" Interface "$k")" ]; then
            have=$((have + 1))
        fi
    done

    if [ "$have" -eq 0 ]; then
        val_block "配置里没有任何 AmneziaWG 混淆字段(S1-S4 / H1-H4 / Jc-Jmax 等)"
        info "这看起来是一份【标准 WireGuard】配置。"
        info "标准 WG 客户端连不上开了混淆的 AmneziaWG 服务端(报文类型码被换成 H 值), 反向也一样。"
        info "请到服务端(如 GL.iNet 路由器)取【带混淆参数】的 AmneziaWG 配置。"
        info "GL.iNet 网页/二维码默认按标准 WG 生成、不带这些字段, 需要手工补齐(见项目 README)。"
    elif [ -n "$core_missing" ]; then
        val_block "混淆字段残缺, 必须与服务端一致的字段缺少:$core_missing"
        info "上游明确: S1-S4 与 H1-H4 必须与服务端完全一致(它们决定报文长度前缀与类型码)。"
        info "缺这些字段时客户端会按默认值(0 / 1-2-3-4)发收包, 服务端根本认不出来。"
        info "常见成因: 从 GL.iNet 网页/二维码拷配置 —— 它默认按标准 WG 生成, 只补了一部分字段。"
    elif [ -n "$local_missing" ]; then
        val_warn "缺少客户端本地混淆参数:$local_missing"
        info "上游口径: Jc/Jmin/Jmax 属客户端本地参数(不必与服务端一致), 缺了不影响连通性,"
        info "但会少一层流量伪装。建议按服务端导出值原样补上。"
    fi

    jc=$(conf_get "$f" Interface Jc)
    jmin=$(conf_get "$f" Interface Jmin)
    jmax=$(conf_get "$f" Interface Jmax)
    s1=$(conf_get "$f" Interface S1)
    s2=$(conf_get "$f" Interface S2)

    # Jc: 要 uint16; =0 表示关闭 junk 包机制; 上游 README 建议 1-128(常用 4-12)
    if [ -n "$jc" ] && uint16_check Jc "$jc"; then
        if [ "$jc" -eq 0 ]; then
            val_warn "Jc=0 —— 表示关闭 junk 包机制(官方文档: 参数为 0 即禁用该机制)"
        elif [ "$jc" -gt 128 ]; then
            val_warn "Jc=$jc 超出上游 README 建议范围 1-128(常用 4-12, 越大开销越高)"
        fi
    fi
    # Jmin/Jmax: uint16, Jmin <= Jmax, 且 Jmax 不应达到/超过 MTU(上游 README: < 1280)
    #   注意口径差异: 内核模块 README 写 `Jmax > Jmin`(严格), 但 amneziawg-go README 写 `Jmin <= Jmax`;
    #   三端代码都不校验这一条。真正会出事的只有 Jmin > Jmax(内核 send.c 的无符号区间会下溢),
    #   所以这里只拦 > —— Jmin == Jmax 是合法配置, 不能误拦。
    if [ -n "$jmin" ] && uint16_check Jmin "$jmin"; then :; fi
    if [ -n "$jmax" ] && uint16_check Jmax "$jmax"; then :; fi
    if [ -n "$jmin" ] && [ -n "$jmax" ] && is_uint "$jmin" && is_uint "$jmax"; then
        [ "$jmin" -le "$jmax" ] || val_err "Jmin($jmin) 不能大于 Jmax($jmax) —— 垃圾包大小区间反了, 内核侧会算出非法长度"
        [ "$jmax" -lt 1280 ] || val_warn "Jmax=$jmax 达到/超过 1280 —— 上游 README 建议 Jmax < 1280, 否则垃圾包会被分片"
    fi
    # S1/S2: uint16, S1+56 != S2, 上限按上游 README(S1<=1132, S2<=1188, 以 MTU 1280 估算)
    hpk=$(conf_get "$f" Interface HeaderProtectionKey)
    if [ -n "$s1" ] && uint16_check S1 "$s1"; then
        [ "$s1" -le 1132 ] || val_warn "S1=$s1 超过上游 README 上限 1132(=1280-148), 会让 Init 包超 MTU"
        if [ -n "$hpk" ] && [ "$s1" -lt 12 ]; then
            val_err "配置用了 HeaderProtectionKey, 但 S1=$s1 < 12 —— 内核侧要求开 header protection 时 S1-S4 至少 12"
        fi
    fi
    if [ -n "$s2" ] && uint16_check S2 "$s2"; then
        [ "$s2" -le 1188 ] || val_warn "S2=$s2 超过上游 README 上限 1188(=1280-92)"
        if [ -n "$hpk" ] && [ "$s2" -lt 12 ]; then
            val_err "配置用了 HeaderProtectionKey, 但 S2=$s2 < 12 —— 内核侧要求开 header protection 时 S1-S4 至少 12"
        fi
    fi
    # S1+56 == S2: 文档建议级约束(内核 README 明列, 但三端代码都不校验, awk setconf 照样接受),
    #   且接收端还有 H1/H2 报文类型码兜底 → 只提示, 不当错误拦(否则比上游工具本身还严, 会误拦可用配置)
    if [ -n "$s1" ] && [ -n "$s2" ] && is_uint "$s1" && is_uint "$s2"; then
        [ $((s1 + 56)) -ne "$s2" ] || val_warn "S1+56 恰好等于 S2(S1=$s1): Init 包(148+S1)与 Response 包(92+S2)等长, 按长度区分包类型的做法会失效(上游 README 建议避开; 接收端通常还能靠 H 类型码兜底)"
    fi

    # H1..H4: range<uint32> + 两两区间不重叠(官方文档硬约束 + 内核 netlink.c 会 -EINVAL)
    local hk hs i low high
    local -a HLO=() HHI=() HNAME=()   # 连字段名一起存, 否则某个 H 值格式非法被跳过时编号会整体前移、报错指错字段
    for hk in H1 H2 H3 H4; do
        hs=$(conf_get "$f" Interface "$hk")
        [ -n "$hs" ] || continue
        if ! read -r low high < <(h_range "$hs"); then
            val_err "$hk 格式非法(应为整数或 a-b 区间): $hs"
            continue
        fi
        if [ "$high" -gt 4294967295 ] 2>/dev/null; then
            val_err "$hk=$hs 超出 uint32 上限 4294967295(官方文档)"
            continue
        fi
        if [ "$low" -ge 1 ] && [ "$low" -le 4 ] && [ "$low" -eq "$high" ]; then
            val_warn "$hk=$hs 是官方特殊值($hk 等于 $low 表示禁用 $hk)"
        fi
        [ "$low" -ge 5 ] || val_warn "$hk 起始值 $low 偏小(上游建议 >= 5)"
        HLO+=("$low"); HHI+=("$high"); HNAME+=("$hk")
    done
    local n=${#HLO[@]}
    if [ "$n" -gt 1 ]; then
        local j
        for ((i = 0; i < n; i++)); do
            for ((j = i + 1; j < n; j++)); do
                if [ "${HLO[$i]}" -le "${HHI[$j]}" ] && [ "${HLO[$j]}" -le "${HHI[$i]}" ]; then
                    val_err "H 字段区间重叠(${HNAME[$i]}=${HLO[$i]}-${HHI[$i]} 与 ${HNAME[$j]}=${HLO[$j]}-${HHI[$j]}): 官方文档要求 H1-H4 区间不得重叠(内核会直接拒绝)"
                fi
            done
        done
    fi

    # ---------- 全量路由时提示 MTU ----------
    local mtufull; mtufull=$(conf_get "$f" Interface MTU)
    if printf '%s' "$allowed" | grep -q '0\.0\.0\.0/0'; then
        if [ -z "$mtufull" ]; then
            val_warn "AllowedIPs 含 0.0.0.0/0(全流量)但未设 MTU"
            info "经 4G/5G 拨入时 MTU 必须 <= 1280, 否则表现为能握手但网页打不开。"
        elif [ "$mtufull" -gt 1280 ] 2>/dev/null; then
            val_warn "MTU=$mtufull 偏大, 经 4G/5G 场景建议 <= 1280"
        fi
    fi

    # 统一的退出点: 只要有错误级问题就返回非 0。
    #   ⚠️ 这个 return 值就是"能否继续安装"的唯一判据 ——
    #   历史教训: 早期版本这里恒 return 0, 而主流程只看返回码, 导致"拦住残废配置"
    #   这个核心承诺在安装路径上完全失效(只在 --validate-config 路径生效)。
    [ "$VAL_ERRORS" -eq 0 ]
}

# 单一出口的校验闸: 主流程与 --validate-config 都调它, 避免两条路径结论不一致
config_gate() {  # 用法: if ! config_gate <file>; then ... fi
    validate_config "$1" || true
    [ "$VAL_ERRORS" -eq 0 ]
}

# CRLF → LF 归一化
#   为什么必须做: awg-quick 用 bash 逐行解析配置, 行尾的 \r 会**留在值里** ——
#   PrivateKey 变成 "xxx=\r"、Address 变成 "10.1.0.3/24\r" → 密钥解析失败 / ip address add 失败,
#   而报错信息不会提 \r, 极难排查。Windows 上编辑/传输过来的配置非常常见。
#   注意: 用 tr 而不是 awk 做检测 —— awk 在 Windows(文本模式) 会把 CRLF 读成 LF,
#   检测永远为 0, 而 tr 始终按二进制处理。
normalize_crlf() {
    local f="$1" n tmpf
    n=$(tr -cd '\r' < "$f" 2>/dev/null | wc -c | tr -d '[:space:]')
    if [ "${n:-0}" -gt 0 ]; then
        warn "配置里有 $n 个 CR 字符(Windows 行尾) —— 已自动转成 LF; 否则 awg-quick 解析时会把行尾回车符带进值里, 连不上还查不出原因"
        tmpf="$f.lf.$$"
        # 这份临时文件里是含 PrivateKey 的配置 —— 必须继承原文件权限, 不能按 umask 放开
        if (umask 077; tr -d '\r' < "$f" > "$tmpf") 2>/dev/null; then
            chmod --reference="$f" "$tmpf" 2>/dev/null || chmod 600 "$tmpf" 2>/dev/null || true
            mv "$tmpf" "$f"
        else
            rm -f "$tmpf"
            warn "CRLF 转换失败, 请手工执行 dos2unix 后重试"
        fi
    fi
}

# ============================================================
# --validate-config: 只校验, 不装东西
# ============================================================
if [ -n "$VALIDATE_ONLY" ]; then
    if [ ! -f "$VALIDATE_ONLY" ]; then
        echo "配置文件不存在: $VALIDATE_ONLY" >&2
        exit 2
    fi
    echo "校验配置: $VALIDATE_ONLY"
    # 校验用副本, 绝不改动用户给的原文件(且副本按 0600 建, 里面含私钥)
    VCHECK=$(mktemp /tmp/awg-check.XXXXXX)
    trap 'rm -f "$VCHECK"' EXIT
    cat "$VALIDATE_ONLY" > "$VCHECK"
    normalize_crlf "$VCHECK"
    if config_gate "$VCHECK"; then
        echo "结果: 通过(提示 $VAL_WARNINGS 条)"
        exit 0
    fi
    echo "结果: 不通过(错误 $VAL_ERRORS, 提示 $VAL_WARNINGS)"
    exit 1
fi

# ============================================================
# 主流程
# ============================================================
banner

[ "$(id -u)" -eq 0 ] || die "需要 root 权限, 请用 sudo 运行"

# ---------- [1/7] 检测系统 ----------
step 1 "检测系统..."

[ -f /etc/os-release ] || die "无法识别系统(缺少 /etc/os-release)"
# shellcheck disable=SC1091
. /etc/os-release
DISTRO=${ID:-unknown}
DISTRO_LIKE=${ID_LIKE:-}
KERNEL=$(uname -r)
KMAJ=$(uname -r | cut -d. -f1)
KMIN=$(uname -r | cut -d. -f2)
ARCH_RAW=$(uname -m)

PKG_MGR=""
case "$DISTRO $DISTRO_LIKE" in
    *ubuntu*|*debian*|*kali*|*raspbian*|*deepin*|*linuxmint*|*pop*|*uos*)
        PKG_MGR=apt ;;
    *centos*|*rhel*|*rocky*|*almalinux*|*fedora*|*kylin*|*openeuler*|*anolis*|*amzn*|*opencloudos*)
        if command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf; else PKG_MGR=yum; fi ;;
    *arch*|*manjaro*|*endeavouros*|*cachyos*)
        PKG_MGR=pacman ;;
    *opensuse*|*sles*|*sled*)
        PKG_MGR=zypper ;;
    *alpine*)
        PKG_MGR=apk ;;
    *)
        die "暂不支持的发行版: $DISTRO  (欢迎 Issue: https://github.com/NetApptool/amneziawg-install/issues)" ;;
esac

# Go 架构名(用户态回退要用)
case "$ARCH_RAW" in
    x86_64|amd64)        GOARCH=amd64 ;;
    aarch64|arm64)       GOARCH=arm64 ;;
    loongarch64)         GOARCH=loong64 ;;
    riscv64)             GOARCH=riscv64 ;;
    armv7l|armv6l)       GOARCH=armv6l ;;
    i386|i686)           GOARCH=386 ;;
    *)                   GOARCH="" ;;
esac

ok "${PRETTY_NAME:-$DISTRO}  内核 $KERNEL  架构 $ARCH_RAW"
ok "包管理器: $PKG_MGR"
log "uname -a: $(uname -a)"

# 老内核提示(AmneziaWG 模块在这类内核上基本编不出来)
OLD_KERNEL=0
if [ "$KMAJ" -lt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -lt 6 ]; }; then
    OLD_KERNEL=1
    warn "内核 $KERNEL < 5.6, 属于老内核 —— AmneziaWG 内核模块编译成功率低"
fi

# ---------- [2/7] 决定实现路线 ----------
step 2 "决定实现路线(内核模块 / 用户态)..."

info "AmneziaWG 有两种落地方式:"
info "  ① 内核模块 amneziawg(dkms 编译) — 性能好, 需要内核头文件"
info "  ② 用户态 amneziawg-go             — 免编译内核, 吞吐低, 兼容性最好"
info "  awg-quick 在内核模块不可用时会自动回退到 ②(前提: amneziawg-go 在 PATH 里)"

if [ "$IMPL" = "auto" ]; then
    if [ "$OLD_KERNEL" = 1 ]; then
        IMPL="userspace"
        ok "内核偏老 → 默认选择【用户态 amneziawg-go】(可用 --kernel 强制覆盖)"
    elif [ -z "$GOARCH" ] && [ "$ARCH_RAW" != "x86_64" ]; then
        IMPL="kernel"
        ok "架构 $ARCH_RAW 无现成 Go 工具链 → 默认选择【内核模块】(可用 --userspace 强制覆盖)"
    else
        IMPL="kernel"
        ok "默认选择【内核模块 dkms】(装不上会自动回退用户态; 可用 --userspace 强制)"
    fi
else
    ok "按命令行指定: $IMPL"
fi

if [ "$IMPL" = "kernel" ]; then
    if ask "仍要尝试内核模块路线? 失败时自动回退用户态 [Y/n]: " "Y"; then
        : # 保持 kernel
    else
        IMPL="userspace"; ok "改为【用户态 amneziawg-go】"
    fi
fi

# ---------- [3/7] 安装 amneziawg-tools ----------
step 3 "安装 amneziawg-tools(提供 awg / awg-quick)..."

# 各发行版的上游包渠道差异很大(2026-10-10 核实):
#   · Ubuntu      → PPA ppa:amnezia/ppa, 装 amneziawg(metapackage: dkms+tools) 或 amneziawg-tools(仅工具)
#   · Debian      → 无 Debian 代号的上游包, 官方文档让手写 sources.list 指向 ubuntu focal(有风险, 失败即源码编译)
#   · RHEL/Rocky  → COPR amneziavpn/amneziawg, 包名 amneziawg-dkms / amneziawg-tools
#   · Fedora      → ⚠️ 官方 COPR 没有 fedora chroot(会用 tigro/amneziawg 这个第三方 COPR, 已明确标注)
#   · Arch        → AUR: amneziawg-tools / amneziawg-dkms / amneziawg-go / amneziawg-linux
#   · Alpine      → 上游没有 aports 包 → 只能源码编译
#   · openSUSE    → 只有 home:* 个人仓库 → 只能源码编译
#   · 麒麟/openEuler → 未查到任何官方包 → 只能源码编译
TOOLS_SRC="https://github.com/amnezia-vpn/amneziawg-tools"
NEED_SOURCE_BUILD=0
case "$DISTRO $DISTRO_LIKE" in
    *alpine*|*opensuse*|*sles*|*sled*|*kylin*|*openeuler*|*opencloudos*|*anolis*)
        NEED_SOURCE_BUILD=1 ;;
esac

apt_has_candidate() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9]'; }

# apt 路线需要的最小工具(两条分支都要用, 所以提前装)
apt_ensure_tools() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg2 ca-certificates >> "$LOG_FILE" 2>&1 || true
}

# 宿主代号(用于给 PPA 选对口袋); 取不到就回退到 VERSION_CODENAME/UBUNTU_CODENAME
apt_codename() {
    local c="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [ -n "$c" ] || c=$(lsb_release -sc 2>/dev/null || true)
    printf '%s' "$c"
}

# PPA 的签名公钥: 只用实测可用的一条路。
#   ⚠️ 曾写过 https://api.launchpad.net/1.0/~amnezia/+archive/ubuntu/ppa?ws.op=getSigningKeyData,
#   实测该 ws.op 不存在(HTTP 400 No such operation), 那条分支永远不会成功 —— 已删掉, 别再加回来。
apt_fetch_ppa_key() {
    local keyring=/usr/share/keyrings/amneziawg.gpg
    mkdir -p /usr/share/keyrings
    if curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828" 2>>"$LOG_FILE" \
         | gpg --dearmor > "$keyring" 2>>"$LOG_FILE"; then
        chmod 644 "$keyring" 2>/dev/null || true
        printf '%s' "$keyring"
        return 0
    fi
    rm -f "$keyring"
    warn "无法从 keyserver 取 PPA 签名公钥"
    return 1
}

# Debian 专用: 上游 PPA 没有 Debian 代号, 按官方文档写死 ubuntu focal(有风险, 失败即源码编译)
apt_add_ppa_manual() {
    local keyring
    keyring=$(apt_fetch_ppa_key) || return 1
    echo "deb [signed-by=$keyring] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" \
        > /etc/apt/sources.list.d/amneziawg.list
    info "已写入 /etc/apt/sources.list.d/amneziawg.list (ubuntu focal 源)"
    return 0
}

install_build_deps() {
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential git >> "$LOG_FILE" 2>&1 ;;
        dnf|yum) $PKG_MGR install -y -q gcc make git >> "$LOG_FILE" 2>&1 ;;
        pacman) pacman -Sy --noconfirm --needed base-devel git >> "$LOG_FILE" 2>&1 ;;
        zypper) zypper -n install gcc make git >> "$LOG_FILE" 2>&1 ;;
        apk)    apk add --no-progress build-base git >> "$LOG_FILE" 2>&1 ;;
    esac
}

# 源码编译: git clone → make → make install
# 装出 /usr/bin/awg、/usr/bin/awg-quick、/etc/amnezia/amneziawg/(0700)、awg-quick@.service
build_tools_from_source() {
    local d
    d=$(mktemp -d)
    info "源码编译 amneziawg-tools(需要 gcc + make + git)"
    install_build_deps || true
    if ! command -v make >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        rm -rf "$d"; return 1
    fi
    if ! git clone --depth=1 "$TOOLS_SRC" "$d/tools" >> "$LOG_FILE" 2>&1; then
        rm -rf "$d"; return 1
    fi
    local mkopts="WITH_WGQUICK=yes"
    command -v systemctl >/dev/null 2>&1 && mkopts="$mkopts WITH_SYSTEMDUNITS=yes"
    command -v bash >/dev/null 2>&1 && mkopts="$mkopts WITH_BASHCOMPLETION=yes"
    # shellcheck disable=SC2086
    if ( cd "$d/tools/src" && make >> "$LOG_FILE" 2>&1 && make install $mkopts >> "$LOG_FILE" 2>&1 ); then
        rm -rf "$d"
        return 0
    fi
    rm -rf "$d"
    return 1
}

install_tools_pkg() {
    case "$PKG_MGR" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1 || true
            # 官方主仓已收录的发行版(部分新版 Ubuntu/Debian)
            if apt_has_candidate amneziawg-tools; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg-tools >> "$LOG_FILE" 2>&1 && return 0
            fi
            # 两条分支都要 curl/gpg, 先补齐(最小化云镜像/容器里常常没有)
            apt_ensure_tools
            # 注意判定顺序: Ubuntu 的 os-release 是 ID=ubuntu + ID_LIKE=debian,
            # 所以"是否真 Debian"绝不能只看 ID_LIKE(否则 Ubuntu 会被当成 Debian,
            # 永远走写死 focal 的口袋, 那条 add-apt-repository 按宿主代号选口袋的路就成了死代码)。
            if [ "$DISTRO" = "debian" ] && [ "${DISTRO_LIKE%% *}" != "ubuntu" ]; then
                # 真 Debian: 上游 PPA 没有 Debian 代号 → 按官方文档写死 focal 源(有风险, 失败即源码编译)
                info "Debian 无对应 PPA 代号 → 按官方文档用 ubuntu focal 源(可能因 libc/依赖不匹配失败, 失败会自动改源码编译)"
                apt_add_ppa_manual || return 1
            else
                info "添加上游 PPA: ppa:amnezia/ppa"
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common >> "$LOG_FILE" 2>&1 || true
                if command -v add-apt-repository >/dev/null 2>&1; then
                    # add-apt-repository 会按宿主代号(如 26.04 的 resolute/stonking)自动选口袋
                    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1 || return 1
                    info "已按宿主代号添加 PPA: $(apt_codename)"
                else
                    apt_add_ppa_manual || return 1
                fi
            fi
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1 || true
            # 客户端只需 amneziawg-tools; 内核模块由本脚本按路线单独处理
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg-tools >> "$LOG_FILE" 2>&1 && return 0
            return 1
            ;;
        dnf|yum)
            if ! rpm -q amneziawg-tools >/dev/null 2>&1; then
                command -v dnf >/dev/null 2>&1 || return 1
                rpm -q epel-release >/dev/null 2>&1 || $PKG_MGR install -y -q epel-release >> "$LOG_FILE" 2>&1 || true
                $PKG_MGR install -y -q 'dnf-command(copr)' >> "$LOG_FILE" 2>&1 || true
                if [ "$DISTRO" = "fedora" ]; then
                    # 上游 COPR 没有 fedora chroot(核实过 36 个 chroot 全是 epel/centos/rhel)
                    warn "上游 COPR amneziavpn/amneziawg 不支持 Fedora, 改用第三方 COPR tigro/amneziawg"
                    $PKG_MGR copr enable -y tigro/amneziawg >> "$LOG_FILE" 2>&1 || return 1
                else
                    info "启用上游 COPR: amneziavpn/amneziawg"
                    $PKG_MGR copr enable -y amneziavpn/amneziawg >> "$LOG_FILE" 2>&1 || return 1
                fi
            fi
            $PKG_MGR install -y -q amneziawg-tools >> "$LOG_FILE" 2>&1 && return 0
            return 1
            ;;
        pacman)
            # ⚠️ Arch 的 AUR 包必走 makepkg, 而 makepkg 硬拒 root
            #   ("Running makepkg as root is not allowed ...", pacman 源码里的硬检查);
            #   本脚本强制 root 运行 → yay/paru 这条路必然失败。
            #   所以直接走源码编译(上游 README 的官方路线), 不再假装能用 AUR。
            if [ "$(id -u)" -eq 0 ]; then
                info "Arch: AUR/makepkg 不允许以 root 运行 → 直接走源码编译(上游 README 官方路线)"
                return 1
            fi
            if command -v yay >/dev/null 2>&1; then
                yay -S --noconfirm --needed amneziawg-tools >> "$LOG_FILE" 2>&1 && return 0
            elif command -v paru >/dev/null 2>&1; then
                paru -S --noconfirm --needed amneziawg-tools >> "$LOG_FILE" 2>&1 && return 0
            elif pacman -Si amneziawg-tools >/dev/null 2>&1; then
                pacman -Sy --noconfirm --needed amneziawg-tools >> "$LOG_FILE" 2>&1 && return 0
            fi
            return 1
            ;;
        zypper|apk)
            # 上游没有官方包(openSUSE 只有 home:* 个人仓库; Alpine 无 aports) → 直接源码编译
            return 1
            ;;
    esac
    return 1
}

install_tools() {
    if [ "$NEED_SOURCE_BUILD" = 1 ]; then
        info "该发行版上游没有官方包 → 直接走源码编译"
        build_tools_from_source && return 0
        return 1
    fi
    install_tools_pkg && return 0
    warn "包管理器路线没装成, 回退源码编译"
    build_tools_from_source && return 0
    return 1
}

echo -n "      正在安装 amneziawg-tools ..."
T0=$(date +%s)
if install_tools && command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
    echo -e " ${GREEN}✓${RESET} 完成(耗时 $(( $(date +%s) - T0 )) 秒)"
    ok "awg      = $(command -v awg)"
    ok "awg-quick= $(command -v awg-quick)"
else
    echo
    err "amneziawg-tools 安装失败, 日志末尾:"
    tail -n 10 "$LOG_FILE" >&2
    cat <<EOF >&2

  可能原因:
    1) 软件源不通(PPA/COPR/AUR 都是第三方源, 内网/信创环境常被墙)
    2) 发行版太老或太冷门, 上游没出包(Alpine/openSUSE/麒麟/openEuler 都没有官方包)
    3) RHEL 系没启用 EPEL

  三条手动替代路线:
    A) 源码编译(任何发行版通用, 需要 gcc + make + git):
         git clone https://github.com/amnezia-vpn/amneziawg-tools
         cd amneziawg-tools/src && make && sudo make install WITH_WGQUICK=yes WITH_SYSTEMDUNITS=yes
    B) 在别的机器上按 A 编译好, 把 awg / awg-quick 两个二进制拷进目标机 /usr/bin/
    C) 离线场景同上 —— 本脚本不依赖 awg 之外的任何东西

  完整日志: $LOG_FILE
EOF
    die "请先把 awg/awg-quick 装上再重跑本脚本"
fi

# 尝试加载内核模块(内核路线)
KERNEL_OK=0
if [ "$IMPL" = "kernel" ]; then
    echo -n "      检查 amneziawg 内核模块 ... "
    if lsmod 2>/dev/null | grep -q '^amneziawg'; then
        echo -e " ${GREEN}✓${RESET} 已加载"
        KERNEL_OK=1
    elif modprobe amneziawg >> "$LOG_FILE" 2>&1; then
        echo -e " ${GREEN}✓${RESET} 加载成功"
        KERNEL_OK=1
    else
        echo -e " ${YELLOW}✗${RESET} 加载失败"
        warn "本机还没有 amneziawg 内核模块, 要先装它"
        echo "      现在安装内核模块包(dkms 编译, 需要内核头文件)..."
        info "提示: 内核模块编译要搬整个内核源码树, /tmp 小的话先设"
        info "      export AWG_TEMP_DIR=/home/<你的目录>/tmp  (上游 README 明列此坑)"
        case "$PKG_MGR" in
            apt)
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-headers-"$(uname -r)" >> "$LOG_FILE" 2>&1 || true
                # PPA 里内核模块的包名是 amneziawg-dkms; amneziawg 是 metapackage(dkms+tools)
                if apt_has_candidate amneziawg-dkms; then
                    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg-dkms >> "$LOG_FILE" 2>&1 || true
                else
                    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg >> "$LOG_FILE" 2>&1 || true
                fi
                ;;
            dnf|yum)
                # COPR 里的实际依赖: dkms kernel-devel make bc yum-utils rpm-build python3-devel git
                $PKG_MGR install -y -q kernel-devel-"$(uname -r)" kernel-headers dkms >> "$LOG_FILE" 2>&1 || true
                $PKG_MGR install -y -q amneziawg-dkms >> "$LOG_FILE" 2>&1 || true
                ;;
            pacman)
                (command -v yay >/dev/null 2>&1 && yay -S --noconfirm --needed amneziawg-dkms >> "$LOG_FILE" 2>&1) \
                  || (command -v paru >/dev/null 2>&1 && paru -S --noconfirm --needed amneziawg-dkms >> "$LOG_FILE" 2>&1) || true
                ;;
            *) : ;;
        esac
        if modprobe amneziawg >> "$LOG_FILE" 2>&1; then
            ok "内核模块加载成功"
            MODVER=$(modinfo -F version amneziawg 2>/dev/null || true)
            if [ -n "$MODVER" ]; then ok "模块版本: $MODVER"; fi
            KERNEL_OK=1
        else
            warn "内核模块仍然不可用(常见于信创/老内核/缺 kernel-headers/源码树缺失)"
            info "上游已知: 内核 <6.7 曾编译失败(issue #204)、低版本内核兼容性反复被破坏"
            IMPL="userspace"
        fi
    fi
fi

# 用户态路线: 准备 amneziawg-go
if [ "$IMPL" = "userspace" ] || [ "$KERNEL_OK" -eq 0 ]; then
    IMPL="userspace"
    if command -v amneziawg-go >/dev/null 2>&1; then
        ok "已存在用户态实现: $(command -v amneziawg-go)"
    else
        info "需要准备用户态实现 amneziawg-go(源码编译, 依赖 Go >= $GO_MIN)"
        GO_BIN=""
        if command -v go >/dev/null 2>&1; then GO_BIN=$(command -v go); fi
        GO_VER=""
        if [ -n "$GO_BIN" ]; then
            GO_VER=$("$GO_BIN" version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true)
        fi
        GO_OK=0
        if [ -n "$GO_VER" ]; then
            # 版本比较: 只要 主版本.次版本(go1.25.0 → 1.25)
            GO_MAJOR=${GO_VER%%.*}
            GO_REST=${GO_VER#*.}
            GO_MINOR=${GO_REST%%.*}
            if [ "${GO_MAJOR:-0}" -gt 1 ] 2>/dev/null; then GO_OK=1; fi
            if [ "${GO_MAJOR:-0}" -eq 1 ] 2>/dev/null && [ "${GO_MINOR:-0}" -ge 25 ] 2>/dev/null; then GO_OK=1; fi
        fi

        if [ "$GO_OK" != 1 ]; then
            if [ -n "$GO_VER" ]; then
                warn "本机 Go 版本 $GO_VER 低于 $GO_MIN, 需要升级(或装到独立目录不覆盖系统 Go)"
            else
                warn "本机没有 Go 工具链"
            fi
            if [ -n "$GOARCH" ]; then
                info "可以从 https://go.dev/dl/ 装一份 Go >= $GO_MIN 到 /usr/local/go(不动系统包)"
                info "命令(示例, 架构 $GOARCH):"
                info "  curl -fsSLO https://go.dev/dl/go1.25.0.linux-$GOARCH.tar.gz"
                info "  rm -rf /usr/local/go && tar -C /usr/local -xzf go1.25.0.linux-$GOARCH.tar.gz"
                info "  export PATH=/usr/local/go/bin:\$PATH"
                info "装好后重跑本脚本即可。"
            else
                info "架构 $ARCH_RAW 没有官方 Go 工具链, 请走内核模块路线或手工交叉编译 amneziawg-go。"
            fi
            die "缺 Go 工具链, 无法构建用户态实现"
        fi

        ok "Go 工具链可用($GO_VER)"
        echo
        info "上游官方装法: git clone → make → make install(装到 /usr/bin/amneziawg-go)"
        info "本脚本先试更快的 go install, 失败再走官方 make 路线"
        echo -n "      正在构建 amneziawg-go ..."
        BUILT=0
        # 路线 A: go install(快, 但需要能访问模块代理; 国内自动回退到 goproxy.cn)
        if GOBIN=/usr/local/bin "$GO_BIN" install "$AWGGO_REPO@latest" >> "$LOG_FILE" 2>&1; then
            BUILT=1
        else
            info "默认 GOPROXY 不通, 改走国内镜像 goproxy.cn 重试"
            if GOBIN=/usr/local/bin GOPROXY=https://goproxy.cn,direct \
               "$GO_BIN" install "$AWGGO_REPO@latest" >> "$LOG_FILE" 2>&1; then
                BUILT=1
            fi
        fi
        # 路线 B: 官方 make 路线
        if [ "$BUILT" != 1 ]; then
            info "go install 不通, 改用官方 git clone + make 路线"
            TMPD=$(mktemp -d)
            if git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-go "$TMPD/awg-go" >> "$LOG_FILE" 2>&1 \
               && make -C "$TMPD/awg-go" >> "$LOG_FILE" 2>&1 \
               && install -m 0755 "$TMPD/awg-go/amneziawg-go" /usr/local/bin/amneziawg-go >> "$LOG_FILE" 2>&1; then
                BUILT=1
            fi
            rm -rf "$TMPD"
        fi
        if [ "$BUILT" != 1 ]; then
            echo -e " ${RED}✗${RESET}"
            err "amneziawg-go 构建失败, 日志末尾:"
            tail -n 10 "$LOG_FILE" >&2
            cat <<EOF >&2

  手动路线(任何发行版通用):
    git clone https://github.com/amnezia-vpn/amneziawg-go
    cd amneziawg-go && make && sudo make install     # → /usr/bin/amneziawg-go
  注意: 需要 Go >= $GO_MIN(见 go.mod), 系统包里的 Go 往往太老 → 从 https://go.dev/dl/ 装新的
        make 里会用 git 取版本号, 所以 git 也要装

  完整日志: $LOG_FILE
EOF
            die "用户态路线失败; 装好 Go >= $GO_MIN 与 git 后重跑, 或改走 --kernel"
        fi
        echo -e " ${GREEN}✓${RESET} 完成"
        command -v amneziawg-go >/dev/null 2>&1 || die "amneziawg-go 未出现在 PATH(检查 /usr/local/bin 是否在 PATH 里)"
        ok "amneziawg-go = $(command -v amneziawg-go)"
    fi
fi

if [ "$IMPL" = "kernel" ] && [ "$KERNEL_OK" = 1 ]; then
    ok "实现路线: 内核模块(amneziawg)"
else
    IMPL="userspace"
    ok "实现路线: 用户态(amneziawg-go) —— 吞吐较低, 但兼容性最好"
fi

# ---------- [4/7] 获取配置 ----------
step 4 "获取并校验 AmneziaWG 配置"

mkdir -p "$AWG_DIR"
chmod 700 "$AWG_DIR"

CONF_TMP=$(mktemp /tmp/awg-conf.XXXXXX)
trap 'rm -f "$CONF_TMP"' EXIT

if [ -n "$CONF_SRC" ]; then
    [ -f "$CONF_SRC" ] || die "配置文件不存在: $CONF_SRC"
    cat "$CONF_SRC" > "$CONF_TMP"
    ok "已从文件读入配置: $CONF_SRC"
else
    if [ -z "$TTY_IN" ]; then
        die "无可用终端读配置。请改用: sudo bash $0 --config /path/to/awg0.conf"
    fi
    echo -e "      粘贴你的 AmneziaWG 配置(必须含 Jc/Jmin/Jmax/S1/S2/H1-H4 混淆字段),"
    echo -e "      粘贴完成后按 ${BOLD}Ctrl+D${RESET} 结束:"
    echo "      ────────────────────────────────────────"
    cat > "$CONF_TMP" < "$TTY_IN"
    echo "      ────────────────────────────────────────"
fi

[ -s "$CONF_TMP" ] || die "配置为空"

# 行尾归一化(Windows 编辑过的配置会把 \r 带进值里, 详见 normalize_crlf 注释)
normalize_crlf "$CONF_TMP"

if ! config_gate "$CONF_TMP"; then
    echo
    err "配置校验不通过(错误 $VAL_ERRORS 条)"
    echo
    cat <<'EOF'
  说明: 这不是脚本在刁难你 —— 混淆参数不一致时, AmneziaWG 的典型表现是
        "看着连上了但打不开网页" 或 "发 148B 收 0B", 排查成本远高于现在改对。

  正确的配置从哪来:
    1) 服务端是 GL.iNet 路由器: 不能直接扫网页二维码(默认按标准 WG 生成,
       不含混淆字段), 要用带 Jc/S1/H1-H4 的完整配置(见项目 README)
    2) 服务端是自建 AmneziaWG: 拿服务端 amneziawg.conf 的 [Interface] 段里
       Jc/Jmin/Jmax/S1-S4/H1-H4 原样抄到客户端 [Interface] 段
    3) 确实确认服务端没开混淆: 加 --allow-incomplete 可强行继续
EOF
    if [ "$ALLOW_INCOMPLETE" = 1 ]; then
        warn "--allow-incomplete 已指定, 强行继续"
    else
        die "请修正配置后重跑(或加 --allow-incomplete 强行继续)"
    fi
fi

ENDPOINT=$(conf_get "$CONF_TMP" Peer Endpoint)
UPEER=$(conf_get "$CONF_TMP" Peer PublicKey)
ALLOWED=$(conf_get "$CONF_TMP" Peer AllowedIPs)
DNS_LINE=$(conf_get "$CONF_TMP" Interface DNS)
ADDRESS=$(conf_get "$CONF_TMP" Interface Address)
CONF_MTU=$(conf_get "$CONF_TMP" Interface MTU)

[ -n "$ENDPOINT" ] || die "配置无效: 未找到 Endpoint"
[ -n "$ADDRESS" ]  || die "配置无效: 未找到 Address"

FULL_TUNNEL=0
if printf '%s' "$ALLOWED" | grep -q '0\.0\.0\.0/0'; then
    FULL_TUNNEL=1
    ok "全流量模式(0.0.0.0/0)  对端: $ENDPOINT"
else
    ok "分流模式: $ALLOWED  对端: $ENDPOINT"
fi
ok "本机隧道地址: $ADDRESS  服务端公钥: ${UPEER:0:12}…"
info "对端公钥要与服务端侧登记的一致; 若服务端没登记本机公钥, 会表现为收 0B"

# 混淆字段回显(让用户确认抄对了)
OBF_SHOW=""
for k in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
    v=$(conf_get "$CONF_TMP" Interface "$k")
    if [ -n "$v" ]; then OBF_SHOW="$OBF_SHOW $k=$v"; fi
done
if [ -n "$OBF_SHOW" ]; then ok "混淆参数:$OBF_SHOW"; fi

# ---------- [5/7] 几个小问题 ----------
step 5 "几个小问题"

# 5.1 旧配置处理
CFG_PATH="$AWG_DIR/$IFNAME.conf"
BACKUP=""
if [ -f "$CFG_PATH" ]; then
    echo
    warn "发现 $CFG_PATH 已存在"
    echo "      [1] 备份后覆盖(推荐)"
    echo "      [2] 取消安装"
    CHOICE=$(ask_choice "请选择 [1/2]: " "1")
    case "$CHOICE" in
        2) die "用户取消" ;;
        *)
            BACKUP="$CFG_PATH.bak.$(date +%Y%m%d-%H%M%S)"
            cp -a "$CFG_PATH" "$BACKUP"
            # 两个单元名都停一下: 老的 wg-quick@ 万一有人手改过配置目录
            systemctl stop "awg-quick@$IFNAME" 2>/dev/null || true
            awg-quick down "$IFNAME" 2>/dev/null || true
            wg-quick down "$IFNAME" 2>/dev/null || true
            ok "已备份到 $(basename "$BACKUP")"
            ;;
    esac
fi

# 5.2 DNS 改用 PostUp/PostDown 自管(与原生 wg-install 同一策略)
#     理由: awg-quick 调 resolvconf 在 Rocky/RHEL/麒麟/信创上经常失败,
#     不依赖 systemd-resolved/openresolv 最稳。
if [ -n "$DNS_LINE" ]; then
    sed -i 's/^\(\s*DNS\s*=\)/# \1  # handled by amneziawg-install PostUp/' "$CONF_TMP"
fi

# 5.3 SSH 自保护
SSH_PROTECT=0; SSH_IP=""
if [ -n "${SSH_CLIENT:-${SSH_CONNECTION:-}}" ]; then
    SSH_IP=$(echo "${SSH_CLIENT:-${SSH_CONNECTION:-}}" | awk '{print $1}')
fi
if [ -n "$SSH_IP" ] && [ "$FULL_TUNNEL" = "1" ]; then
    echo
    warn "检测到你正在通过 SSH 连接(来自 $SSH_IP)"
    echo "      启动隧道后这条 SSH 会断开, 要保护吗?"
    if ask "保护当前 SSH 连接? [Y/n]: " "Y"; then
        SSH_PROTECT=1
        ok "已加保护规则, 启动后 SSH 不会断"
    else
        warn "跳过(注意启动后 SSH 可能断)"
    fi
fi

# 5.4 MTU(4G/5G 场景必须 <= 1280)
#   两种都要管: ① 没设 MTU  ② 设了但偏大(如 1420) —— 后者老版本会直接跳过这个提示
MTU_SET=0
MTU_OVER=0
if [ -n "$CONF_MTU" ] && [ "$CONF_MTU" -gt 1280 ] 2>/dev/null; then MTU_OVER=1; fi
if [ "$FULL_TUNNEL" = "1" ] && { [ -z "$CONF_MTU" ] || [ "$MTU_OVER" = 1 ]; }; then
    echo
    info "全流量模式下, MTU 没设时由 awg-quick 自动推算"
    info "经 4G/5G 拨入(车机/CPE/手机热点)时 MTU 必须 <= 1280, 否则能握手但打不开网页"
    if [ "$MTU_OVER" = 1 ]; then
        warn "你的配置里是 MTU = $CONF_MTU, 偏大"
    fi
    if ask "写入 MTU = 1280? [Y/n]: " "Y"; then
        MTU_SET=1280; ok "将写入 MTU = 1280(覆盖原值)"
    fi
fi

# 5.5 Kill Switch
KILL_SWITCH=0
echo
if ask "是否启用 Kill Switch?(隧道断了就断网, 防 IP 泄漏)[y/N]: " "N"; then
    KILL_SWITCH=1
    ok "已启用 Kill Switch"
else
    ok "跳过"
fi

# 5.6 连通性自检
echo
TEST_CONN=1
if ask "启动后自动测试连通性? [Y/n]: " "Y"; then ok "好的"; else TEST_CONN=0; fi

# 5.7 立即启动
START=0
case "$START_NOW" in
    yes) START=1 ;;
    no)  START=0 ;;
    ask) if ask "立即启动并设置开机自启? [Y/n]: " "Y"; then START=1; fi ;;
esac

# ---------- 组装最终配置 ----------
# DNS helper 脚本(仅当原配置带 DNS)
#   注意: awg-quick 会把 DNS 值按"是不是 IP"分成 DNS 服务器与 DNS 搜索域两类,
#   所以这里也要分开处理 —— 非 IP 的项写成 search 行, 不能硬塞成 nameserver(会写出无效 resolv.conf)
if [ -n "$DNS_LINE" ]; then
    DNS_IPS=""; DNS_SEARCH_DOMS=""
    for d in $(printf '%s' "$DNS_LINE" | tr ',' ' '); do
        case "$d" in
            *:*)                            DNS_IPS="$DNS_IPS $d" ;;   # IPv6
            [0-9]*.[0-9]*.[0-9]*.[0-9]*)    DNS_IPS="$DNS_IPS $d" ;;   # IPv4
            *)                              DNS_SEARCH_DOMS="$DNS_SEARCH_DOMS $d" ;;
        esac
    done
    if [ -n "$DNS_SEARCH_DOMS" ]; then
        info "配置里的 $DNS_SEARCH_DOMS 不是 IP —— 按 DNS 搜索域处理(写进 search 行)"
    fi
    {
        echo '#!/bin/sh'
        echo '# auto-generated by amneziawg-install — PostUp DNS handler'
        echo '[ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf /etc/resolv.conf.awg-install.bak 2>/dev/null'
        echo '{'
        for d in $DNS_IPS; do
            echo "    echo 'nameserver $d'"
        done
        if [ -n "$DNS_SEARCH_DOMS" ]; then
            echo "    echo 'search$DNS_SEARCH_DOMS'"
        fi
        echo '} > /etc/resolv.conf'
        echo 'exit 0'
    } > "$AWG_DIR/$IFNAME-dns-up.sh"
    chmod 755 "$AWG_DIR/$IFNAME-dns-up.sh"

    cat > "$AWG_DIR/$IFNAME-dns-down.sh" <<'DNS_DOWN_EOF'
#!/bin/sh
# auto-generated by amneziawg-install — PostDown DNS handler
if [ -f /etc/resolv.conf.awg-install.bak ]; then
    mv /etc/resolv.conf.awg-install.bak /etc/resolv.conf
fi
exit 0
DNS_DOWN_EOF
    chmod 755 "$AWG_DIR/$IFNAME-dns-down.sh"
fi

# ---------- 往 [Interface] 段内插行 ----------
# 之所以专门写个函数, 是因为手写的 awk 匹配踩过两个坑:
#   ① 段头只认第 0 列的裸 "[Interface]" —— 而 awg-quick 自己的解析器会把 key 前后空白 trim,
#      所以 "  [Interface]" / "[Interface]  # 注释" 都是它认的合法配置; 老写法对这类配置**静默漏插**
#      (用户被告知写了 MTU / 加了保护规则, 实际一行都没写进去), 结果是"隧道起来了但域名全解析不了"。
#   ② 老写法把 PostUp 插在"第一个 [Peer] 之前"就等于插在 [Interface] 段内 —— 这个假设只在
#      [Interface] 排第一时成立; [Peer] 写在前面的配置会让 PostUp 落到所有段之外,
#      awg setconf 直接报 `Line unrecognized' 起不来。
#   现在: 插到"第一个非 [Interface] 的段头"之前(= [Interface] 段末尾); 没有其它段就追加到文件末尾。
inject_into_interface() {  # inject_into_interface <file> <payload(可含多行, 以 \n 结尾)>
    local f="$1" payload="$2" tmp
    tmp=$(mktemp)
    if ! awk -v inject="$payload" '
        function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
        function is_sec(s)   { return (ltrim(s) ~ /^\[/) }
        function is_iface(s) {
            s = ltrim(s); sub(/[[:space:]]*#.*$/, "", s); sub(/[[:space:]]+$/, "", s)
            return (s == "[Interface]")
        }
        {
            if (!done && seen_iface && is_sec($0) && !is_iface($0)) { printf "%s", inject; done = 1 }
            if (is_iface($0)) seen_iface = 1
            print
        }
        END { if (!done && seen_iface) printf "%s", inject }
    ' "$f" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 1; fi   # 内容没变 = 没插进去
    mv "$tmp" "$f"
    return 0
}

# MTU 写入: 配置里已有 MTU 就**替换**(不能追加第二行 —— 虽然 awg-quick 取最后一个,
# 但留两行 MTU 会让人看不懂生效的是哪个), 没有才注入
set_mtu_in_config() {  # set_mtu_in_config <file> <value>
    local f="$1" val="$2" tmp
    if grep -qE '^[[:space:]]*MTU[[:space:]]*=' "$f"; then
        tmp=$(mktemp)
        if awk -v mtu="$val" '
            /^[[:space:]]*MTU[[:space:]]*=/ { print "MTU = " mtu; next }
            { print }
        ' "$f" > "$tmp"; then
            mv "$tmp" "$f"; return 0
        fi
        rm -f "$tmp"; return 1
    fi
    inject_into_interface "$f" "MTU = $val"$'\n'
}

# MTU 注入
if [ "$MTU_SET" != 0 ]; then
    if set_mtu_in_config "$CONF_TMP" "$MTU_SET"; then
        : # 已在上面打过 "将写入 MTU = 1280"
    else
        warn "MTU 写入失败(没找到 [Interface] 段) —— 配置将不带 MTU, 请手工加一行 MTU = $MTU_SET"
    fi
fi

# PostUp/PostDown / PreDown 注入
INJECT=""
if [ -n "$DNS_LINE" ]; then
    INJECT+="PostUp = $AWG_DIR/$IFNAME-dns-up.sh"$'\n'
    INJECT+="PostDown = $AWG_DIR/$IFNAME-dns-down.sh"$'\n'
fi
if [ "$SSH_PROTECT" = "1" ] && [ -n "$SSH_IP" ]; then
    # 解析默认路由时不能按字段位置硬取: 设备型默认路由(PPP/4G)是
    #   "default dev ppp0 scope link" —— 没有 via, $3/$5 会取到 ppp0/link,
    #   拼出的 "ip route add X/32 via ppp0 dev link" 必然失败,
    #   而 PostUp 失败会让 awg-quick up/down 整体失败(上游是 set -e) → 隧道起不来。
    DEFAULT_GW=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')
    DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    SSH_ROUTE=""
    if [ -n "$DEFAULT_IF" ] && [ -n "$DEFAULT_GW" ]; then
        SSH_ROUTE="ip route add ${SSH_IP}/32 via ${DEFAULT_GW} dev ${DEFAULT_IF}"
    elif [ -n "$DEFAULT_IF" ]; then
        SSH_ROUTE="ip route add ${SSH_IP}/32 dev ${DEFAULT_IF}"
        info "默认路由是设备型(无 via), SSH 保护用 ${SSH_ROUTE}"
    fi
    if [ -n "$SSH_ROUTE" ]; then
        INJECT+="PostUp = $SSH_ROUTE"$'\n'
        INJECT+="PostDown = ip route del ${SSH_IP}/32"$'\n'
    else
        warn "无法解析默认路由, SSH 保护规则跳过(启动后这条 SSH 可能断)"
    fi
fi
if [ "$KILL_SWITCH" = "1" ]; then
    # 注意: AmneziaWG 用 awg show 取 fwmark(wg show 是空的)
    INJECT+="PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark \$(awg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT"$'\n'
    INJECT+="PreDown = iptables -D OUTPUT ! -o %i -m mark ! --mark \$(awg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT"$'\n'
fi

if [ -n "$INJECT" ]; then
    if inject_into_interface "$CONF_TMP" "$INJECT"; then
        ok "已写入 PostUp/PostDown 规则(验证: 段内注入, 不在段外)"
    else
        warn "PostUp/PostDown 注入失败 —— 请手工把上面这些行加到 [Interface] 段里"
        warn "否则可能出现: 隧道起来了但 /etc/resolv.conf 没被改写(DNS 自管失效)"
    fi
fi

# 落盘前自检: 确认注入的规则确实在 [Interface] 段里(而不是被插到段外)
if [ -n "$INJECT" ] && ! awk '
    function ltrim(s){sub(/^[[:space:]]+/,"",s); return s}
    function is_sec(s){return (ltrim(s) ~ /^\[/)}
    function is_iface(s){s=ltrim(s); sub(/[[:space:]]*#.*$/,"",s); sub(/[[:space:]]+$/,"",s); return (s=="[Interface]")}
    { if (is_iface($0)) ins=1; else if (is_sec($0)) ins=0
      if (ins && $0 ~ /^[[:space:]]*PostUp[[:space:]]*=/) f=1 }
    END { exit !f }
' "$CONF_TMP"; then
    warn "自检未发现 [Interface] 段内的 PostUp 行, 请人工确认配置"
fi

install -m 600 "$CONF_TMP" "$CFG_PATH"
chown root:root "$CFG_PATH"
ok "配置已写入 $CFG_PATH (权限 600)"
info "AmneziaWG 的配置目录是 $AWG_DIR —— 不是 /etc/wireguard/"
info "想改配置: sudo vi $CFG_PATH 然后 sudo awg-quick down $IFNAME && sudo awg-quick up $IFNAME"

# ---------- [6/7] 启动 ----------
EXIT_IP=""; HANDSHAKE_OK=0; MODE_ACTUAL=""

# 启动前的 Endpoint 预检: awg setconf 会自己解析 Endpoint 主机名, 解析不了就报
#   "Name or service not known: `host:port'" + "Configuration parsing error"
# —— 这是最容易被误读成"配置写错了"的一类失败(其实配置没问题, 是本机 DNS 解析不了)。
# 提前查一次, 把真正的原因和查法摊给用户; 也提前给出"改用 IP"的绕法。
ENDPOINT_HOST="${ENDPOINT%:*}"
ENDPOINT_PORT="${ENDPOINT##*:}"
preflight_endpoint() {
    # 已经是 IP 就不需要解析
    if printf '%s' "$ENDPOINT_HOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
       || printf '%s' "$ENDPOINT_HOST" | grep -q ':'; then
        ok "Endpoint 是 IP, 不需要 DNS 解析"
        return 0
    fi
    if getent hosts "$ENDPOINT_HOST" >/dev/null 2>&1; then
        local ip; ip=$(getent hosts "$ENDPOINT_HOST" | awk 'NR==1{print $1}')
        ok "Endpoint 域名可解析: $ENDPOINT_HOST -> $ip"
        return 0
    fi
    warn "Endpoint 域名【解析不了】: $ENDPOINT_HOST"
    info "这正是 \`Name or service not known' + \`Configuration parsing error' 的原因 ——"
    info "不是配置写错了, 是这台机器现在解析不了这个名字(awg setconf 会自己解析 Endpoint)。"
    echo
    echo "  按顺序自查:"
    echo "    cat /etc/resolv.conf          # 有没有可用 nameserver(只有 127.0.0.53 时看 systemd-resolved 是否活着)"
    echo "    ping -c2 223.5.5.5            # 纯 IP 通不通(分清'没网'还是'只有 DNS 坏')"
    echo "    getent hosts $ENDPOINT_HOST   # 换个工具复验"
    echo
    echo "  两条绕法:"
    echo "    A) 修好 DNS 再重跑本脚本"
    echo "    B) 找台能解析的机器查出 IP, 把配置改成 IP 直连:"
    echo "         Endpoint = <IP>:$ENDPOINT_PORT"
    echo "       改完: sudo awg-quick down $IFNAME && sudo awg-quick up $IFNAME"
    echo "       (DDNS 换 IP 后要再改一次, 属临时手段; 根治还是修 DNS)"
    return 1
}

if [ "$START" = "1" ]; then
    step 6 "启动隧道..."
    preflight_endpoint || info "仍然继续尝试(万一 awg-quick 内的重试能等到 DNS 恢复)"
    if awg-quick up "$IFNAME" >> "$LOG_FILE" 2>&1; then
        ok "awg-quick up $IFNAME"
    else
        err "启动失败, 日志末尾:"
        tail -n 20 "$LOG_FILE" >&2
        echo
        # 按上游真实报错特征分流 —— 只说命中那条, 不让用户在一堆"常见原因"里猜
        if grep -q 'Name or service not known' "$LOG_FILE"; then
            err "命中原因: Endpoint 域名解析失败(见上一条预检)"
            echo "        → 先修 DNS, 或把 Endpoint 改成 IP 后重试(上面绕法 B)"
            echo "        → 若本机 DNS 依赖隧道自身, 会出现先有鸡还是先有蛋 —— 必须先用 IP 把隧道起起来"
        elif grep -q 'Configuration parsing error' "$LOG_FILE"; then
            err "命中原因: 配置解析失败 —— 配置里有 awg 不认识的键或格式"
            echo "        → 检查: 键名拼写、密钥是否 44 字符 base64 且以 = 结尾、地址是否带掩码"
            echo "        → 上游会指明是哪一行, 上面日志 \`Line unrecognized' 后面就是那行"
        elif grep -qE 'already exists|Address already in use|File exists' "$LOG_FILE"; then
            err "命中原因: 接口/地址已存在"
            echo "        → 先关掉旧的: sudo awg-quick down $IFNAME(或用 --ifname 换个名字)"
        elif grep -qE 'Operation not permitted|Permission denied' "$LOG_FILE"; then
            err "命中原因: 权限不足(建接口/改路由都要 root)"
            echo "        → sudo bash $0 ..."
        else
            err "未命中已知原因, 请把上面日志原样发出来"
        fi
        echo
        cat <<EOF >&2
  其它可能(按可能性排序):
    1) 内核模块没装且 amneziawg-go 不在 PATH(awg-quick 无处回退)
       → 现在 PATH 里 amneziawg-go: $(command -v amneziawg-go 2>/dev/null || echo "无")
    2) Endpoint 那侧 UDP $ENDPOINT_PORT 被挡 —— 这不会让 up 失败, 只会"起来了但收 0B"
    3) SSH 自保护注入的路由命令失败(设备型默认路由, 如 PPP/4G)

  完整日志: $LOG_FILE
EOF
        die "启动失败"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl enable "awg-quick@$IFNAME" >> "$LOG_FILE" 2>&1; then
            ok "systemctl enable awg-quick@$IFNAME  (开机自启已开)"
        else
            warn "开机自启设置失败"
        fi
    else
        warn "未检测到 systemd, 请自行设置开机自启"
    fi

    # 判定实际生效的实现(内核 or 用户态)
    #   内核模块: `ip -d link show` 能看到 amneziawg 这个 link kind
    #   用户态:   接口是 tun 设备(amneziawg-go 建立)
    #   (iproute2 版本不同打印格式有差异, 所以三重判据 + 兜底)
    LINK_DETAIL=$(ip -d link show "$IFNAME" 2>/dev/null || true)
    log "ip -d link show $IFNAME: $LINK_DETAIL"
    if printf '%s' "$LINK_DETAIL" | grep -qw 'amneziawg'; then
        MODE_ACTUAL="内核模块(amneziawg)"
    elif printf '%s' "$LINK_DETAIL" | grep -qw 'tun'; then
        MODE_ACTUAL="用户态(amneziawg-go)"
        warn "当前走的是【用户态实现】, 吞吐低于内核态"
    elif [ -e /sys/module/amneziawg ]; then
        MODE_ACTUAL="内核模块(amneziawg)"
    else
        MODE_ACTUAL="未能判定"
        warn "无法判定实现方式(内核态/用户态), 请用 sudo awg show $IFNAME 确认"
    fi
    ok "本次实际实现: $MODE_ACTUAL"
else
    step 6 "跳过启动"
    ok "稍后手动启动: sudo awg-quick up $IFNAME"
fi

# ---------- [7/7] 连通性自检 ----------
if [ "$TEST_CONN" = "1" ] && [ "$START" = "1" ]; then
    step 7 "连通性测试..."
    sleep 3

    # 握手判定: 先整体取状态(信息量最大), 命令本身失败要区分开报
    SHOW_OUT=""
    if ! SHOW_OUT=$(awg show "$IFNAME" 2>&1); then
        warn "awg show 执行失败(用户态实现的 UAPI socket 可能没建起来):"
        echo "        $SHOW_OUT"
    elif printf '%s' "$SHOW_OUT" | grep -q 'latest handshake'; then
        ok "握手成功(服务端已确认本机)"
        HANDSHAKE_OK=1
    else
        warn "尚未握手 —— 常见原因:"
        echo "        · 服务端没登记本机公钥(表现为收 0B)"
        echo "        · 到 $ENDPOINT 的 UDP 被墙/被 NAT 丢"
        echo "        · 混淆参数与服务端不一致(手抄漏了 S1/S2 或 H 值)"
        echo "        · 服务端与客户端 Endpoint/端口对不上"
    fi

    if [ -n "$DNS_LINE" ]; then
        DNS_FIRST=$(printf '%s' "$DNS_LINE" | tr ',' ' ' | awk '{print $1}')
        if PING_OUT=$(ping -c 3 -W 2 "$DNS_FIRST" 2>/dev/null); then
            RTT=$(echo "$PING_OUT" | tail -1 | awk -F/ '{printf "%.0f", $5}')
            ok "ping $DNS_FIRST  ${RTT}ms"
        else
            warn "ping $DNS_FIRST 失败"
        fi
    fi

    EXIT_IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
           || curl -fsS --max-time 10 https://ipinfo.io/ip  2>/dev/null \
           || curl -fsS --max-time 10 https://ifconfig.me   2>/dev/null \
           || echo "查询失败")
    ok "出口 IP  $EXIT_IP"

    if getent hosts example.com >/dev/null 2>&1; then
        ok "DNS 解析(example.com)  正常"
    else
        warn "DNS 解析失败"
    fi
else
    step 7 "跳过连通性测试"
fi

# ---------- 总结 ----------
echo
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════"
echo -e "  ✅ 全部完成!"
echo -e "═══════════════════════════════════════════════════${RESET}"
echo
if [ "$START" = "1" ]; then
    if [ -n "$EXIT_IP" ]; then echo "  当前出口 IP : $EXIT_IP"; fi
    echo "  隧道接口    : $IFNAME  →  $ADDRESS"
    echo "  实现方式    : ${MODE_ACTUAL:-未知}"
    echo "  开机自启    : 已启用(awg-quick@$IFNAME)"
    if [ "$HANDSHAKE_OK" = 0 ]; then
        echo "  ${YELLOW}⚠  尚未握手 — 先查服务端是否登记了本机公钥${RESET}"
    fi
else
    echo "  状态        : 已安装(未启动)"
fi
echo "  配置文件    : $CFG_PATH  (权限 600)"
if [ -n "$BACKUP" ]; then echo "  旧配置备份  : $BACKUP"; fi
echo
echo -e "  ${BOLD}常用命令(注意是 awg, 不是 wg!):${RESET}"
echo "    查看状态  : sudo awg show            ${YELLOW}# wg show 在 AmneziaWG 上是空的!${RESET}"
echo "    看配置    : sudo awg showconf $IFNAME"
echo "    临时关闭  : sudo awg-quick down $IFNAME"
echo "    临时启动  : sudo awg-quick up $IFNAME"
echo "    重启隧道  : sudo systemctl restart awg-quick@$IFNAME"
echo "    永久禁用  : sudo systemctl disable --now awg-quick@$IFNAME"
echo "    改配置    : sudo vi $CFG_PATH  改完重启"
echo
echo "  日志: $LOG_FILE"
echo "  反馈: https://github.com/NetApptool/amneziawg-install/issues"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
echo
