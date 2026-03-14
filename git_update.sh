#!/usr/bin/env zsh

# ============================================================
# git_update.sh — 从上游拉取最新代码并合并到本地
#
# 用法:
#   ./git_update.sh          # 拉取并合并
#   ./git_update.sh --dry    # 只查看差异，不合并
# ============================================================

set -eo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

# ---- 颜色 ----
c_red()    { printf '\e[31m%s\e[0m' "$*" }
c_green()  { printf '\e[32m%s\e[0m' "$*" }
c_yellow() { printf '\e[33m%s\e[0m' "$*" }
c_cyan()   { printf '\e[36m%s\e[0m' "$*" }
c_bold()   { printf '\e[1m%s\e[0m' "$*" }

log_info() { printf '%s  %s\n' "$(c_cyan '[INFO]')" "$*" }
log_ok()   { printf '%s  %s\n' "$(c_green '[ OK ]')" "$*" }
log_warn() { printf '%s  %s\n' "$(c_yellow '[WARN]')" "$*" }
log_err()  { printf '%s   %s\n' "$(c_red '[ERR]')" "$*" }
log_step() { printf '\n%s\n' "$(c_bold "━━━ $* ━━━")" }

REMOTE="origin"
BRANCH="main"
DRY_RUN=0
[[ "${1:-}" == "--dry" ]] && DRY_RUN=1

# ---- 清理 macOS 冲突副本文件 ----
# macOS 在文件冲突时会生成 "filename 2.ext", "filename 3.ext" 等副本
# 这些文件会污染 git 仓库，必须定期清理
clean_macos_conflict_copies() {
    local count=0
    local found
    found=$(find "$REPO_DIR" -maxdepth 6 \
        \( -name '* 2' -o -name '* 3' -o -name '* 4' \
           -o -name '* 2.*' -o -name '* 3.*' -o -name '* 4.*' \) \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        count=$(echo "$found" | wc -l | tr -d ' ')
        log_warn "发现 ${count} 个 macOS 冲突副本文件，正在清理..."
        echo "$found" | while IFS= read -r f; do
            rm -rf "$f" 2>/dev/null
        done
        log_ok "已清理 ${count} 个冲突副本文件"
    fi
}

# ---- 需要保护的本地配置/脚本 ----
# 这些文件在 rebase 冲突时优先保留本地版本
LOCAL_PROTECTED_FILES=(
    "restart-bot.sh"
    "git_update.sh"
)

# 机器人配置目录（不在 git 仓库内，无需 git 保护，但更新后需检查完整性）
BOT_CONFIG_DIRS=(
    "$HOME/.openclaw-adan"
    "$HOME/.openclaw-xiaoguang"
    "$HOME/.openclaw-moai"
    "$HOME/.openclaw-xiaoshao"
    "$HOME/.openclaw-xiaoxin"
)

# ---- 备份机器人配置 ----
backup_bot_configs() {
    local backup_dir="/tmp/openclaw-config-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$backup_dir"
    for dir in "${BOT_CONFIG_DIRS[@]}"; do
        local name=$(basename "$dir")
        if [[ -f "${dir}/openclaw.json" ]]; then
            cp "${dir}/openclaw.json" "${backup_dir}/${name}.json"
        fi
    done
    echo "$backup_dir"
}

# ---- 验证机器人配置完整性 ----
verify_bot_configs() {
    local backup_dir="$1"
    local issues=0
    for dir in "${BOT_CONFIG_DIRS[@]}"; do
        local name=$(basename "$dir")
        local cfg="${dir}/openclaw.json"
        if [[ ! -f "$cfg" ]]; then
            log_warn "配置文件缺失: ${cfg}"
            if [[ -f "${backup_dir}/${name}.json" ]]; then
                cp "${backup_dir}/${name}.json" "$cfg"
                log_ok "已从备份恢复: ${cfg}"
            else
                (( issues++ ))
            fi
        fi
    done
    return $issues
}

# ============================================================
# Step 0: 清理 macOS 冲突副本文件
# ============================================================
log_step "Step 0: 清理 macOS 冲突副本"
clean_macos_conflict_copies

# ============================================================
# Step 1: 检查当前状态
# ============================================================
log_step "Step 1: 检查本地状态"

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    log_err "当前分支是 ${CURRENT_BRANCH}，请先切换到 ${BRANCH}"
    exit 1
fi
log_ok "当前分支: ${BRANCH}"

# 显示本地未提交的修改
LOCAL_CHANGES=$(git status --porcelain 2>/dev/null)
if [[ -n "$LOCAL_CHANGES" ]]; then
    count=$(echo "$LOCAL_CHANGES" | wc -l | tr -d ' ')
    log_warn "本地有 ${count} 个未提交的修改："
    echo "$LOCAL_CHANGES" | head -20 | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
    if (( count > 20 )); then
        printf '    ... 共 %s 个文件\n' "$count"
    fi
else
    log_ok "工作区干净"
fi

LOCAL_HEAD=$(git rev-parse HEAD)
log_info "本地 HEAD: ${LOCAL_HEAD:0:10}"

# ============================================================
# Step 2: 从上游拉取最新代码
# ============================================================
log_step "Step 2: 从上游拉取最新代码"

log_info "执行 git fetch ${REMOTE} ${BRANCH} ..."
git fetch "$REMOTE" "$BRANCH" 2>&1 | while IFS= read -r line; do
    printf '    %s\n' "$line"
done

REMOTE_HEAD=$(git rev-parse "${REMOTE}/${BRANCH}")
log_info "远程 HEAD: ${REMOTE_HEAD:0:10}"

# 检查是否有新提交
BEHIND=$(git rev-list --count HEAD.."${REMOTE}/${BRANCH}" 2>/dev/null || echo 0)
AHEAD=$(git rev-list --count "${REMOTE}/${BRANCH}"..HEAD 2>/dev/null || echo 0)

if (( BEHIND == 0 )); then
    log_ok "本地已是最新，无需更新"
    if (( AHEAD > 0 )); then
        log_info "本地领先远程 ${AHEAD} 个提交（本地修改）"
    fi
    exit 0
fi

log_info "远程领先 ${BEHIND} 个提交，本地领先 ${AHEAD} 个提交"

# 显示远程新增的提交
log_info "远程新提交："
git log --oneline --no-decorate HEAD.."${REMOTE}/${BRANCH}" | head -20 | while IFS= read -r line; do
    printf '    %s\n' "$(c_green "$line")"
done
if (( BEHIND > 20 )); then
    printf '    ... 共 %s 个提交\n' "$BEHIND"
fi

if (( DRY_RUN )); then
    log_info "[DRY RUN] 仅查看差异，不执行合并"
    printf '\n'
    log_info "变更文件统计："
    git diff --stat HEAD.."${REMOTE}/${BRANCH}" | tail -20
    exit 0
fi

# ============================================================
# Step 3: 提交本地修改
# ============================================================
log_step "Step 3: 提交本地修改"

if [[ -n "$LOCAL_CHANGES" ]]; then
    log_info "检测到未提交的修改，准备提交到本地仓库..."
    
    # 添加所有修改（包括新文件）
    git add -A
    
    # 生成提交信息
    COMMIT_MSG="local: auto-commit changes before sync ($(date +%Y-%m-%d\ %H:%M:%S))"
    
    log_info "提交信息: ${COMMIT_MSG}"
    if git commit -m "$COMMIT_MSG" 2>&1 | while IFS= read -r line; do
        printf '    %s\n' "$line"
    done; then
        log_ok "本地修改已提交"
    else
        log_err "提交失败"
        exit 1
    fi
else
    log_info "无未提交的修改，跳过提交步骤"
fi

# ============================================================
# Step 4: 备份机器人配置
# ============================================================
STASHED=0

log_step "Step 4: 备份机器人配置"

CONFIG_BACKUP=$(backup_bot_configs)
log_ok "配置已备份到: ${CONFIG_BACKUP}"

# ============================================================
# Step 5: 合并远程代码
# ============================================================
log_step "Step 5: 合并远程代码 (rebase)"

log_info "执行 git rebase ${REMOTE}/${BRANCH} ..."

if git rebase "${REMOTE}/${BRANCH}" 2>&1 | while IFS= read -r line; do
    printf '    %s\n' "$line"
done; then
    log_ok "Rebase 成功"
else
    # Rebase 冲突
    printf '\n'
    log_err "Rebase 遇到冲突！"

    # 显示冲突文件
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [[ -n "$CONFLICTS" ]]; then
        log_warn "冲突文件："
        auto_resolved=0
        echo "$CONFLICTS" | while IFS= read -r f; do
            # 检查是否是受保护的本地文件
            protected=0
            for pf in "${LOCAL_PROTECTED_FILES[@]}"; do
                if [[ "$f" == "$pf" ]]; then
                    protected=1
                    break
                fi
            done

            if (( protected )); then
                printf '    %s %s\n' "$(c_yellow "$f")" "(本地保护文件，自动保留本地版本)"
                git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null
                (( auto_resolved++ ))
            else
                printf '    %s\n' "$(c_red "$f")"
            fi
        done

        # 如果所有冲突都已自动解决，继续 rebase
        REMAINING=$(git diff --name-only --diff-filter=U 2>/dev/null)
        if [[ -z "$REMAINING" ]]; then
            log_ok "所有冲突已自动解决（保留本地保护文件）"
            if GIT_EDITOR=true git rebase --continue 2>&1 | while IFS= read -r line; do
                printf '    %s\n' "$line"
            done; then
                log_ok "Rebase 继续成功"
            else
                log_err "Rebase 继续失败"
                git rebase --abort 2>/dev/null
                exit 1
            fi
        else
            printf '\n'
            log_warn "请手动解决以上冲突，然后执行："
            printf '    %s\n' "1. 编辑冲突文件，解决冲突标记 (<<<< ==== >>>>)"
            printf '    %s\n' "2. git add <冲突文件>"
            printf '    %s\n' "3. GIT_EDITOR=true git rebase --continue"
            printf '    %s\n' ""
            printf '    %s\n' "或者放弃本次合并: git rebase --abort"
            printf '\n'
            log_info "配置备份位置: ${CONFIG_BACKUP}"
            exit 1
        fi
    fi
fi

# ============================================================
# Step 6: 验证机器人配置
# ============================================================
log_step "Step 6: 验证机器人配置"

if verify_bot_configs "$CONFIG_BACKUP"; then
    log_ok "所有机器人配置完好"
else
    log_warn "部分配置有问题，请检查"
fi

# ============================================================
# Step 7: 完成
# ============================================================
log_step "完成"

NEW_HEAD=$(git rev-parse HEAD)
log_ok "更新完成: ${LOCAL_HEAD:0:10} → ${NEW_HEAD:0:10}"
log_info "合并了 ${BEHIND} 个远程提交"

if (( AHEAD > 0 )); then
    log_info "本地仍有 ${AHEAD} 个本地提交（未推送到远程）"
fi

# 完成后再次清理（rebase/merge 可能申生新的冲突副本）
clean_macos_conflict_copies

# 最终状态
FINAL_CHANGES=$(git status --porcelain 2>/dev/null)
if [[ -n "$FINAL_CHANGES" ]]; then
    fcount=$(echo "$FINAL_CHANGES" | wc -l | tr -d ' ')
    log_info "工作区有 ${fcount} 个未提交修改"
fi

printf '\n'
log_info "最近5个提交："
git log --oneline --no-decorate -5 | while IFS= read -r line; do
    printf '    %s\n' "$line"
done
printf '\n'
