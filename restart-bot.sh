#!/usr/bin/env zsh

# ============================================================
# restart-bot.sh — 快速重启 OpenClaw 机器人
#
# 用法:
#   restart-bot.sh              # 重启全部机器人
#   restart-bot.sh adan         # 只重启阿蛋
#   restart-bot.sh xiaoguang    # 只重启小广
#   restart-bot.sh xiaolin      # 只重启小麟
#   restart-bot.sh status       # 查看所有机器人状态
#   restart-bot.sh adan xiaolin # 重启指定的多个
# ============================================================

DOMAIN="gui/$(id -u)"

# ---- 机器人注册表 ----
typeset -A BOT_LABEL BOT_PORT BOT_LOG BOT_DISPLAY
BOT_DISPLAY=(adan 阿蛋 xiaoguang 小广 xiaolin 小麟 xiaoshao 小哨 xiaoxin 小馨 adai 阿呆)
BOT_LABEL=(adan com.openclaw.gateway-adan xiaoguang com.openclaw.xiaoguang xiaolin com.openclaw.gateway-moai xiaoshao com.openclaw.gateway-xiaoshao xiaoxin com.openclaw.gateway-xiaoxin adai com.openclaw.gateway-adai)
BOT_PORT=(adan 18700 xiaoguang 18710 xiaolin 18720 xiaoshao 18730 xiaoxin 18740 adai 18750)
BOT_LOG=(
    adan    /tmp/openclaw-adan.log
    xiaoguang /tmp/openclaw-xiaoguang.log
    xiaolin   /tmp/openclaw-gateway-moai.log
    xiaoshao  /tmp/openclaw-xiaoshao.log
    xiaoxin   /tmp/openclaw-xiaoxin.log
    adai      /tmp/openclaw-adai.log
)
ALL_BOTS=(adan xiaoguang xiaolin xiaoshao xiaoxin adai)

# ---- 清理 macOS 冲突副本文件 ----
clean_macos_conflict_copies() {
    local repo_dir="$(cd "$(dirname "$0")" && pwd)"
    local found
    found=$(find "$repo_dir" -maxdepth 6 \
        \( -name '* 2' -o -name '* 3' -o -name '* 4' \
           -o -name '* 2.*' -o -name '* 3.*' -o -name '* 4.*' \) \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        local cnt=$(echo "$found" | wc -l | tr -d ' ')
        log_warn "发现 ${cnt} 个 macOS 冲突副本，正在清理..."
        echo "$found" | while IFS= read -r f; do rm -rf "$f" 2>/dev/null; done
        log_ok "已清理 ${cnt} 个冲突副本"
    fi
}

# ---- 颜色输出函数 ----
c_red()    { printf '\e[31m%s\e[0m' "$*" }
c_green()  { printf '\e[32m%s\e[0m' "$*" }
c_yellow() { printf '\e[33m%s\e[0m' "$*" }
c_cyan()   { printf '\e[36m%s\e[0m' "$*" }
c_bold()   { printf '\e[1m%s\e[0m' "$*" }

log_info() { printf '%s  %s\n' "$(c_cyan '[INFO]')" "$*" }
log_ok()   { printf '%s  %s\n' "$(c_green '[ OK ]')" "$*" }
log_warn() { printf '%s  %s\n' "$(c_yellow '[WARN]')" "$*" }
log_err()  { printf '%s   %s\n' "$(c_red '[ERR]')" "$*" }

# ---- 检查端口是否在监听 ----
check_port() { lsof -i ":${1}" -sTCP:LISTEN &>/dev/null }

# ---- 获取监听指定端口的 PID ----
get_pid_by_port() { lsof -ti ":${1}" -sTCP:LISTEN 2>/dev/null | head -1 }

# ---- 查看状态 ----
show_status() {
    printf '\n%s\n\n' "$(c_bold '🤖 OpenClaw 机器人状态')"
    printf '  %-12s %-8s %-8s %-10s %s\n' "别名" "名称" "端口" "PID" "状态"
    printf '  %-12s %-8s %-8s %-10s %s\n' "----------" "------" "------" "--------" "--------"
    for bot in "${ALL_BOTS[@]}"; do
        local port=${BOT_PORT[$bot]}
        local pid=$(get_pid_by_port "$port" 2>/dev/null)
        if [[ -n "$pid" ]]; then
            printf '  %-12s %-8s %-8s %-10s %s\n' "$bot" "${BOT_DISPLAY[$bot]}" "$port" "$pid" "$(c_green 运行中)"
        else
            printf '  %-12s %-8s %-8s %-10s %s\n' "$bot" "${BOT_DISPLAY[$bot]}" "$port" "—" "$(c_red 已停止)"
        fi
    done
    printf '\n'
}

# ---- 重启单个机器人 ----
restart_one() {
    local bot=$1
    local label=${BOT_LABEL[$bot]}
    local port=${BOT_PORT[$bot]}
    local display=${BOT_DISPLAY[$bot]}
    local logfile=${BOT_LOG[$bot]}
    local plist="$HOME/Library/LaunchAgents/${label}.plist"

    printf '\n%s\n' "$(c_bold "━━━ 重启 ${display} (${bot}) ━━━")"

    # Step 1: bootout 停止进程并暂停 KeepAlive 监控
    local pid=$(get_pid_by_port "$port" 2>/dev/null)
    if [[ -n "$pid" ]]; then
        log_info "停止进程 PID=${pid} (bootout) ..."
        launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
        local w=0
        while kill -0 "$pid" 2>/dev/null && (( w < 10 )); do
            sleep 0.5
            (( w++ ))
        done
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "进程未退出，强制终止 ..."
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi
        log_ok "旧进程已停止"
    else
        log_warn "端口 ${port} 无进程，跳过停止"
        launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
    fi

    sleep 1

    # Step 2: bootstrap 启动新进程（同时恢复 KeepAlive 监控）
    log_info "启动新进程 (bootstrap) ..."
    if ! launchctl bootstrap "${DOMAIN}" "${plist}" 2>/dev/null; then
        launchctl kickstart -k "${DOMAIN}/${label}" 2>/dev/null || true
    fi

    # Step 3: 等待端口就绪
    log_info "等待端口 ${port} 就绪 ..."
    local w=0
    while ! check_port "$port" && (( w < 60 )); do
        sleep 1
        (( w++ ))
    done

    if check_port "$port"; then
        local new_pid=$(get_pid_by_port "$port" 2>/dev/null)
        log_ok "${display} 启动成功 (PID=${new_pid}, 端口=${port})"
    else
        log_err "${display} 启动超时! 请检查日志: tail -50 ${logfile}"
        return 1
    fi

    # Step 4: 显示关键日志
    if [[ -f "$logfile" ]]; then
        local key_lines=$(tail -20 "$logfile" | grep -E "listening|WebSocket|feishu|model|error" | tail -3)
        if [[ -n "$key_lines" ]]; then
            printf '  %s\n' "$(c_cyan '日志:')"
            echo "$key_lines" | while IFS= read -r line; do
                printf '    %s\n' "$line"
            done
        fi
    fi
}

# ---- 解析别名 ----
resolve_bot() {
    case "${(L)1}" in
        adan|aden|阿蛋|default|蛋)   echo adan ;;
        xiaoguang|xg|小广|广)         echo xiaoguang ;;
        xiaolin|xl|小麟|moai|麟)      echo xiaolin ;;
        xiaoshao|xs|小哨|哨)          echo xiaoshao ;;
        xiaoxin|xx|小馨|馨)           echo xiaoxin ;;
        adai|ad|阿呆|呆)              echo adai ;;
        *)                             echo "" ;;
    esac
}

# ---- Session 自动清理 ----
cleanup_sessions() {
    local script="${REPO_DIR}/cleanup_sessions.sh"
    if [[ -x "$script" ]]; then
        zsh "$script"
    else
        log_warn "cleanup_sessions.sh 不存在或不可执行，跳过 session 清理"
    fi
}

# ---- 代码编译（如有变更） ----
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

maybe_build() {
    # 检查 dist/ 是否存在，以及源码是否比 dist 更新
    local dist_marker="${REPO_DIR}/dist/index.js"
    local needs_build=0

    if [[ ! -f "$dist_marker" ]]; then
        needs_build=1
    else
        # 检查 src/ 和 extensions/ 下是否有比 dist 更新的文件
        local newer=$(find "${REPO_DIR}/src" "${REPO_DIR}/extensions" \
            -name '*.ts' -newer "$dist_marker" 2>/dev/null | head -1)
        if [[ -n "$newer" ]]; then
            needs_build=1
        fi
    fi

    if (( needs_build )); then
        log_info "检测到代码变更，执行编译 ..."
        if (cd "$REPO_DIR" && pnpm build 2>&1 | tail -3); then
            log_ok "编译完成"
        else
            log_err "编译失败! 请手动检查: cd ${REPO_DIR} && pnpm build"
            exit 1
        fi
    else
        log_info "代码无变更，跳过编译"
    fi
}

# ---- 主入口 ----
main() {
    # 每次启动前清理 macOS 冲突副本
    clean_macos_conflict_copies

    if [[ $# -eq 0 ]] || [[ "$1" == "all" ]]; then
        printf '%s\n' "$(c_bold '🔄 重启全部机器人 ...')"
        cleanup_sessions
        maybe_build
        local failed=0
        for bot in "${ALL_BOTS[@]}"; do
            restart_one "$bot" || (( failed++ )) || true
        done
        printf '\n'
        show_status
        if (( failed > 0 )); then
            log_err "${failed} 个机器人启动失败"
            exit 1
        fi
        log_ok "全部机器人重启完成!"
        return 0
    fi

    if [[ "$1" == "status" ]] || [[ "$1" == "s" ]]; then
        show_status
        return 0
    fi

    if [[ "$1" == "help" ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        echo "用法: ${0:t} [adan|xiaoguang|xiaolin|all|status|help]"
        echo ""
        echo "  无参数 / all     重启全部机器人"
        echo "  adan             重启阿蛋 (端口 18700)"
        echo "  xiaoguang / xg   重启小广 (端口 18710)"
        echo "  xiaolin / xl     重启小麟 (端口 18720)"
        echo "  xiaoshao / xs    重启小哨 (端口 18730)"
        echo "  xiaoxin / xx     重启小馨 (端口 18740)"
        echo "  adai / ad        重启阿呆 (端口 18750)"
        echo "  status / s       查看所有机器人状态"
        echo ""
        echo "支持同时指定多个: ${0:t} adan xiaolin"
        return 0
    fi

    local targets=()
    for arg in "$@"; do
        local bot=$(resolve_bot "$arg")
        if [[ -z "$bot" ]]; then
            log_err "未知机器人: ${arg}"
            echo "  可用: adan(阿蛋), xiaoguang/xg(小广), xiaolin/xl(小麟), xiaoshao/xs(小哨), adai/ad(阿呆)"
            exit 1
        fi
        targets+=("$bot")
    done

    cleanup_sessions
    maybe_build

    local failed=0
    for bot in "${targets[@]}"; do
        restart_one "$bot" || (( failed++ )) || true
    done

    printf '\n'
    if (( ${#targets[@]} > 1 )); then
        show_status
    fi

    if (( failed > 0 )); then
        log_err "${failed} 个机器人启动失败"
        exit 1
    fi
    log_ok "重启完成!"
}

main "$@"
