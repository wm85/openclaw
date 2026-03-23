#!/usr/bin/env zsh

# ============================================================
# cleanup_sessions.sh — 自动清理 OpenClaw 机器人 session 文件
#
# 功能:
#   1. 扫描所有机器人的 session 文件
#   2. 超过阈值的 session 自动提取摘要写入记忆
#   3. 只保留最近 N 条消息，清理历史
#
# 用法:
#   cleanup_sessions.sh              # 清理所有机器人
#   cleanup_sessions.sh adan         # 只清理阿蛋
#   cleanup_sessions.sh --dry        # 只检查，不执行清理
# ============================================================

# ---- 配置 ----
MAX_SESSION_KB=200          # session 文件超过此大小(KB)触发清理
KEEP_MESSAGES=20            # 清理后保留最近 N 条消息
MAX_TOTAL_SESSIONS=30       # 每个机器人最多保留的 session 文件数
STALE_DAYS=7                # 超过 N 天未修改的 isolated session 直接删除

# 机器人列表
typeset -A BOT_DISPLAY BOT_STATE_DIR
BOT_DISPLAY=(adan 阿蛋 xiaoguang 小广 xiaolin 小麟 xiaoshao 小哨 xiaoxin 小馨 adai 阿呆)
BOT_STATE_DIR=(
    adan      "$HOME/.openclaw-adan"
    xiaoguang "$HOME/.openclaw-xiaoguang"
    xiaolin   "$HOME/.openclaw-moai"
    xiaoshao  "$HOME/.openclaw-xiaoshao"
    xiaoxin   "$HOME/.openclaw-xiaoxin"
    adai      "$HOME/.openclaw-adai"
)
ALL_BOTS=(adan xiaoguang xiaolin xiaoshao xiaoxin adai)

# ---- 颜色输出 ----
c_red()    { printf '\e[31m%s\e[0m' "$*" }
c_green()  { printf '\e[32m%s\e[0m' "$*" }
c_yellow() { printf '\e[33m%s\e[0m' "$*" }
c_cyan()   { printf '\e[36m%s\e[0m' "$*" }
c_bold()   { printf '\e[1m%s\e[0m' "$*" }
c_dim()    { printf '\e[2m%s\e[0m' "$*" }

log_info() { printf '%s  %s\n' "$(c_cyan '[INFO]')" "$*" }
log_ok()   { printf '%s  %s\n' "$(c_green '[ OK ]')" "$*" }
log_warn() { printf '%s  %s\n' "$(c_yellow '[WARN]')" "$*" }

# ---- 参数解析 ----
DRY_RUN=0
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --dry|--dry-run) DRY_RUN=1 ;;
        *)               TARGETS+=("$arg") ;;
    esac
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=("${ALL_BOTS[@]}")

# ---- 提取 session 摘要并写入记忆 ----
extract_and_archive() {
    local bot=$1
    local session_file=$2
    local state_dir=${BOT_STATE_DIR[$bot]}
    local display=${BOT_DISPLAY[$bot]}
    local memory_dir="${state_dir}/workspace/memory"
    local basename=$(basename "$session_file" .jsonl)
    local today=$(date +%Y-%m-%d)

    # 用 python 提取 session 中的关键信息摘要
    python3 -c "
import json, sys, os
from datetime import datetime

path = '$session_file'
with open(path) as f:
    lines = f.readlines()

total = len(lines)
size_kb = os.path.getsize(path) / 1024

# 提取时间范围
first_ts = last_ts = ''
try:
    first_ts = json.loads(lines[0]).get('timestamp', '')[:19]
    last_ts = json.loads(lines[-1]).get('timestamp', '')[:19]
except: pass

# 统计角色分布和工具使用
roles = {}
tools_used = set()
for l in lines:
    try:
        d = json.loads(l)
        msg = d.get('message', {})
        role = msg.get('role', 'unknown')
        roles[role] = roles.get(role, 0) + 1
        # 统计工具调用
        for c in msg.get('content', []):
            if isinstance(c, dict) and c.get('type') == 'toolCall':
                tools_used.add(c.get('name', ''))
    except: pass

# 提取最后几条 assistant 消息的文本摘要
summaries = []
for l in reversed(lines):
    if len(summaries) >= 3:
        break
    try:
        d = json.loads(l)
        msg = d.get('message', {})
        if msg.get('role') == 'assistant':
            for c in msg.get('content', []):
                if isinstance(c, dict) and c.get('type') == 'text':
                    text = c['text'].strip()
                    if len(text) > 20:
                        summaries.append(text[:200])
                        break
    except: pass

# 输出摘要
print(f'## Session 归档: {os.path.basename(path)}')
print(f'- 时间: {first_ts} ~ {last_ts}')
print(f'- 消息数: {total}, 大小: {size_kb:.0f}KB')
print(f'- 角色: {dict(sorted(roles.items()))}')
if tools_used:
    print(f'- 工具: {\", \".join(sorted(tools_used))}')
if summaries:
    print(f'- 最近对话片段:')
    for s in reversed(summaries):
        print(f'  > {s}...' if len(s) == 200 else f'  > {s}')
" 2>/dev/null
}

# ---- 清理单个机器人的 sessions ----
cleanup_bot() {
    local bot=$1
    local state_dir=${BOT_STATE_DIR[$bot]}
    local display=${BOT_DISPLAY[$bot]}
    local sessions_dir="${state_dir}/agents/main/sessions"
    local memory_dir="${state_dir}/workspace/memory"

    if [[ ! -d "$sessions_dir" ]]; then
        return 0
    fi

    local files=("${sessions_dir}"/*.jsonl(N))
    if [[ ${#files[@]} -eq 0 ]]; then
        return 0
    fi

    # 统计当前状态
    local total_size=0
    local total_files=${#files[@]}
    local cleaned=0
    local deleted=0
    local archived=0

    for f in "${files[@]}"; do
        total_size=$((total_size + $(stat -f%z "$f" 2>/dev/null || echo 0)))
    done

    printf '  %s: %d 个文件, 总计 %d KB\n' "$display" "$total_files" "$((total_size / 1024))"

    # Step 1: 删除过期的 isolated session（cron 产生的一次性 session）
    local stale_cutoff=$(date -v-${STALE_DAYS}d +%s 2>/dev/null || date -d "${STALE_DAYS} days ago" +%s 2>/dev/null)
    local -a deleted_files=()
    for f in "${files[@]}"; do
        local mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
        local size_kb=$(( $(stat -f%z "$f" 2>/dev/null || echo 0) / 1024 ))

        # 跳过最近修改的文件（可能是活跃 session）
        if (( mtime > stale_cutoff )); then
            continue
        fi

        # 过期的小文件直接删除（cron isolated session）
        if (( size_kb < MAX_SESSION_KB )); then
            if (( DRY_RUN )); then
                printf '    %s %s (%d KB, 已过期)\n' "$(c_dim '[DRY]')" "$(basename $f)" "$size_kb"
            else
                rm -f "$f"
            fi
            (( deleted++ ))
            deleted_files+=("$f")
            continue
        fi

        # 过期的大文件：提取摘要后删除
        if (( DRY_RUN )); then
            printf '    %s %s (%d KB, 过期+大文件，将归档删除)\n' "$(c_dim '[DRY]')" "$(basename $f)" "$size_kb"
        else
            local summary=$(extract_and_archive "$bot" "$f")
            if [[ -n "$summary" ]]; then
                local archive_file="${memory_dir}/archive/sessions-$(date +%Y-%m).md"
                mkdir -p "$(dirname "$archive_file")"
                printf '\n%s\n' "$summary" >> "$archive_file"
                (( archived++ ))
            fi
            rm -f "$f"
        fi
        (( deleted++ ))
        deleted_files+=("$f")
    done

    # Step 2: 瘦身大文件（保留最近 N 条消息）
    local remaining_files=("${sessions_dir}"/*.jsonl(N))
    for f in "${remaining_files[@]}"; do
        # 跳过 Step 1 中已标记删除的文件
        local skip=0
        for df in "${deleted_files[@]}"; do
            [[ "$f" == "$df" ]] && skip=1 && break
        done
        (( skip )) && continue

        local size_kb=$(( $(stat -f%z "$f" 2>/dev/null || echo 0) / 1024 ))
        if (( size_kb < MAX_SESSION_KB )); then
            continue
        fi

        local line_count=$(wc -l < "$f" | tr -d ' ')
        if (( line_count <= KEEP_MESSAGES )); then
            continue
        fi

        if (( DRY_RUN )); then
            printf '    %s %s (%d KB, %d 条 → 保留 %d 条)\n' \
                "$(c_dim '[DRY]')" "$(basename $f)" "$size_kb" "$line_count" "$KEEP_MESSAGES"
        else
            # 先提取摘要归档
            local summary=$(extract_and_archive "$bot" "$f")
            if [[ -n "$summary" ]]; then
                local archive_file="${memory_dir}/archive/sessions-$(date +%Y-%m).md"
                mkdir -p "$(dirname "$archive_file")"
                printf '\n%s\n' "$summary" >> "$archive_file"
                (( archived++ ))
            fi

            # 只保留最近 N 条
            local tmp="${f}.tmp"
            tail -n "$KEEP_MESSAGES" "$f" > "$tmp"
            mv "$tmp" "$f"
        fi
        (( cleaned++ ))
    done

    # Step 3: 如果 session 文件数量超限，删除最老的
    remaining_files=("${sessions_dir}"/*.jsonl(N))
    # dry-run 模式下要减去 Step 1 中已标记删除的数量
    local effective_count=${#remaining_files[@]}
    (( DRY_RUN )) && effective_count=$(( effective_count - ${#deleted_files[@]} ))
    if (( effective_count > MAX_TOTAL_SESSIONS )); then
        local excess=$(( effective_count - MAX_TOTAL_SESSIONS ))
        # 按修改时间排序，取最老的文件（跳过已删除的）
        local -a old_candidates=()
        for f in $(ls -t "${sessions_dir}"/*.jsonl 2>/dev/null | tail -r); do
            local skip=0
            for df in "${deleted_files[@]}"; do
                [[ "$f" == "$df" ]] && skip=1 && break
            done
            (( skip )) && continue
            old_candidates+=("$f")
            (( ${#old_candidates[@]} >= excess )) && break
        done
        for f in "${old_candidates[@]}"; do
            if (( DRY_RUN )); then
                printf '    %s %s (超过 %d 个文件上限，将删除)\n' \
                    "$(c_dim '[DRY]')" "$(basename $f)" "$MAX_TOTAL_SESSIONS"
            else
                rm -f "$f"
            fi
            (( deleted++ ))
        done
    fi

    # 汇报结果
    if (( cleaned > 0 || deleted > 0 )); then
        local action_word="已清理"
        (( DRY_RUN )) && action_word="将清理"
        local msg="${action_word}: 瘦身 ${cleaned} 个, 删除 ${deleted} 个"
        (( archived > 0 )) && msg="${msg}, 归档 ${archived} 条摘要"
        printf '    %s\n' "$(c_green "$msg")"
    else
        printf '    %s\n' "$(c_dim '无需清理')"
    fi
}

# ---- 主入口 ----
main() {
    if (( DRY_RUN )); then
        printf '%s\n\n' "$(c_bold '🔍 Session 清理预览 (dry-run)')"
    else
        printf '%s\n\n' "$(c_bold '🧹 Session 自动清理')"
    fi

    for bot in "${TARGETS[@]}"; do
        cleanup_bot "$bot"
    done

    printf '\n'
    if (( DRY_RUN )); then
        log_info "以上为预览，实际清理请去掉 --dry 参数"
    else
        log_ok "Session 清理完成"
    fi
}

main
