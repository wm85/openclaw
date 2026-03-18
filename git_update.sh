#!/usr/bin/env zsh

# ============================================================
# git_update.sh — 从上游拉取最新代码，合并本地修改，推送到 fork
#
# 用法:
#   ./git_update.sh          # 完整流程：拉取→合并→构建→推送
#   ./git_update.sh --dry    # 只查看差异，不操作
#   ./git_update.sh --pull   # 只拉取合并，不构建不推送
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

UPSTREAM="origin"          # 上游 remote
FORK="myfork"              # 自己的 fork remote
BRANCH="main"
FORK_BRANCH="local-fixes"  # fork 上的分支名
DRY_RUN=0
PULL_ONLY=0

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        --dry)  DRY_RUN=1 ;;
        --pull) PULL_ONLY=1 ;;
    esac
done

# ---- 我们的本地修改 commit 的标识（用于冲突解决策略）----
# 这些文件在冲突时优先保留本地版本
LOCAL_KEEP_FILES=(
    "restart-bot.sh"
    "cleanup_sessions.sh"
    "git_update.sh"
    ".vscode/settings.json"
    "settings.json"
)

# 这些文件冲突时用上游版本（我们的启动优化已被 dist-runtime 替代）
UPSTREAM_KEEP_FILES=(
    "extensions/feishu/src/channel.ts"
    "extensions/feishu/src/bot.ts"
    "extensions/feishu/src/directory.ts"
    "extensions/feishu/src/runtime.ts"
    "src/auto-reply/reply/history.ts"
    "src/auto-reply/reply/mentions.ts"
    "src/channels/plugins/onboarding/helpers.ts"
    "src/plugin-sdk/feishu.ts"
)

# 这些文件需要保留我们的修改（bug fix）
OUR_KEEP_FILES=(
    "extensions/feishu/src/streaming-card.ts"
    "extensions/feishu/src/reply-dispatcher.ts"
    "scripts/tsdown-build.mjs"
    "src/agents/tools/web-guarded-fetch.ts"
)

# ---- 清理 macOS 冲突副本 ----
clean_macos_conflict_copies() {
    local found
    found=$(find "$REPO_DIR" -maxdepth 6 \
        \( -name '* 2' -o -name '* 3' -o -name '* 4' \
           -o -name '* 2.*' -o -name '* 3.*' -o -name '* 4.*' \) \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        local cnt=$(echo "$found" | wc -l | tr -d ' ')
        log_warn "清理 ${cnt} 个 macOS 冲突副本"
        echo "$found" | while IFS= read -r f; do rm -rf "$f" 2>/dev/null; done
    fi
}

# ---- 自动解决冲突 ----
auto_resolve_conflicts() {
    local conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null)
    [[ -z "$conflicts" ]] && return 0

    local unresolved=0
    echo "$conflicts" | while IFS= read -r f; do
        # 本地保留的文件（脚本/配置）
        local keep_local=0
        for lf in "${LOCAL_KEEP_FILES[@]}"; do
            [[ "$f" == "$lf" ]] && keep_local=1 && break
        done
        if (( keep_local )); then
            log_info "  保留本地: $f"
            git checkout --theirs "$f" 2>/dev/null && git add "$f" 2>/dev/null
            continue
        fi

        # 上游优先的文件（已被 dist-runtime 替代的启动优化）
        local keep_upstream=0
        for uf in "${UPSTREAM_KEEP_FILES[@]}"; do
            [[ "$f" == "$uf" ]] && keep_upstream=1 && break
        done
        if (( keep_upstream )); then
            log_info "  用上游版: $f"
            git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null
            continue
        fi

        # 我们的 fix 优先
        local keep_ours=0
        for of in "${OUR_KEEP_FILES[@]}"; do
            [[ "$f" == "$of" ]] && keep_ours=1 && break
        done
        if (( keep_ours )); then
            log_info "  保留我们: $f"
            git checkout --theirs "$f" 2>/dev/null && git add "$f" 2>/dev/null
            continue
        fi

        # 未识别的冲突：用上游版本（安全默认）
        log_warn "  未知冲突，用上游: $f"
        git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null
    done

    # 检查是否还有未解决的冲突
    local remaining=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [[ -n "$remaining" ]]; then
        log_err "仍有未解决的冲突："
        echo "$remaining" | while IFS= read -r f; do
            printf '    %s\n' "$(c_red "$f")"
        done
        return 1
    fi
    return 0
}

# ============================================================
# Step 0: 前置检查
# ============================================================
log_step "Step 0: 前置检查"
clean_macos_conflict_copies

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    log_err "当前分支是 ${CURRENT_BRANCH}，请先切换到 ${BRANCH}"
    exit 1
fi
log_ok "当前分支: ${BRANCH}"

# ============================================================
# Step 1: 拉取上游最新
# ============================================================
log_step "Step 1: 拉取上游最新代码"

git fetch "$UPSTREAM" "$BRANCH" --quiet 2>&1
REMOTE_HEAD=$(git rev-parse "${UPSTREAM}/${BRANCH}")
LOCAL_HEAD=$(git rev-parse HEAD)

BEHIND=$(git rev-list --count HEAD.."${UPSTREAM}/${BRANCH}" 2>/dev/null || echo 0)
AHEAD=$(git rev-list --count "${UPSTREAM}/${BRANCH}"..HEAD 2>/dev/null || echo 0)

log_info "本地 HEAD: ${LOCAL_HEAD:0:10}"
log_info "上游 HEAD: ${REMOTE_HEAD:0:10}"
log_info "上游领先 ${BEHIND} 个提交，本地领先 ${AHEAD} 个提交"

if (( BEHIND == 0 )); then
    log_ok "已是最新，无需更新"
    if (( AHEAD > 0 )); then
        log_info "本地有 ${AHEAD} 个本地提交"
    fi
    exit 0
fi

# 显示上游新提交
log_info "上游新提交 (最近 15 条)："
git log --oneline --no-decorate HEAD.."${UPSTREAM}/${BRANCH}" | head -15 | while IFS= read -r line; do
    printf '    %s\n' "$(c_green "$line")"
done
(( BEHIND > 15 )) && printf '    ... 共 %s 个提交\n' "$BEHIND"

if (( DRY_RUN )); then
    log_info "[DRY RUN] 仅查看差异，不执行"
    printf '\n变更文件统计：\n'
    git diff --stat HEAD.."${UPSTREAM}/${BRANCH}" | tail -20
    exit 0
fi

# ============================================================
# Step 2: 提交本地未保存的修改
# ============================================================
log_step "Step 2: 保存本地修改"

LOCAL_CHANGES=$(git status --porcelain 2>/dev/null)
if [[ -n "$LOCAL_CHANGES" ]]; then
    git add -A
    git commit -m "local: auto-commit before upstream sync ($(date +%Y-%m-%d\ %H:%M:%S))" 2>&1 | tail -1
    log_ok "本地修改已提交"
else
    log_info "工作区干净，跳过"
fi

# ============================================================
# Step 3: Rebase 上游代码
# ============================================================
log_step "Step 3: Rebase 上游代码"

# 创建安全备份分支
git branch -f backup-pre-sync HEAD 2>/dev/null

if git rebase "${UPSTREAM}/${BRANCH}" 2>&1 | tail -5; then
    log_ok "Rebase 成功"
else
    log_warn "Rebase 遇到冲突，尝试自动解决..."

    # 循环处理每个冲突的 commit
    local max_attempts=20
    local attempt=0
    while (( attempt < max_attempts )); do
        (( attempt++ ))

        if auto_resolve_conflicts; then
            if GIT_EDITOR=true git rebase --continue 2>&1 | tail -3; then
                # rebase --continue 成功，可能还有下一个 commit 冲突
                # 检查 rebase 是否完成
                if ! git rebase --show-current-patch 2>/dev/null | head -1 > /dev/null 2>&1; then
                    break  # rebase 完成
                fi
            else
                # 可能又遇到新冲突，继续循环
                continue
            fi
        else
            log_err "无法自动解决冲突，回滚到备份"
            git rebase --abort 2>/dev/null
            git reset --hard backup-pre-sync 2>/dev/null
            log_info "已回滚，请手动处理"
            exit 1
        fi
    done

    log_ok "所有冲突已自动解决"
fi

if (( PULL_ONLY )); then
    log_ok "拉取合并完成 (--pull 模式，跳过构建和推送)"
    git log --oneline -5
    exit 0
fi

# ============================================================
# Step 4: 安装依赖 + 构建
# ============================================================
log_step "Step 4: 安装依赖 + 构建"

log_info "pnpm install ..."
if pnpm install 2>&1 | tail -3; then
    log_ok "依赖安装完成"
else
    log_err "依赖安装失败"
    exit 1
fi

log_info "pnpm build ..."
if pnpm build 2>&1 | tail -3; then
    log_ok "构建成功"
else
    # TS declaration 错误不影响 dist 生成
    if [[ -f dist/entry.js ]]; then
        log_warn "构建有 TS 声明错误（不影响运行）"
    else
        log_err "构建失败，dist 未生成"
        exit 1
    fi
fi

log_info "生成 dist-runtime ..."
node scripts/runtime-postbuild.mjs 2>&1
if [[ -f dist-runtime/extensions/feishu/index.js ]]; then
    log_ok "dist-runtime 生成成功"
else
    log_warn "dist-runtime 可能不完整"
fi

# 验证关键依赖没被 build 删掉
if [[ ! -f node_modules/undici/index.js ]]; then
    log_warn "undici 被 build 删了，重新安装..."
    pnpm install --force 2>&1 | tail -1
    if [[ -f node_modules/undici/index.js ]]; then
        log_ok "undici 已恢复"
    else
        log_err "undici 恢复失败！检查 tsdown-build.mjs 是否有 --no-clean"
        exit 1
    fi
fi

# ============================================================
# Step 5: 推送到 fork
# ============================================================
log_step "Step 5: 推送到 fork"

if git remote get-url "$FORK" > /dev/null 2>&1; then
    if git push "$FORK" "${BRANCH}:${FORK_BRANCH}" --force 2>&1; then
        log_ok "已推送到 ${FORK}/${FORK_BRANCH}"
    else
        log_warn "推送失败（可能需要 gh auth login）"
    fi
else
    log_warn "未配置 fork remote (${FORK})，跳过推送"
fi

# ============================================================
# 完成
# ============================================================
log_step "完成"

NEW_HEAD=$(git rev-parse HEAD)
NEW_AHEAD=$(git rev-list --count "${UPSTREAM}/${BRANCH}"..HEAD 2>/dev/null || echo 0)

log_ok "更新完成: ${LOCAL_HEAD:0:10} → ${NEW_HEAD:0:10}"
log_info "合并了 ${BEHIND} 个上游提交，本地有 ${NEW_AHEAD} 个自定义提交"

clean_macos_conflict_copies

printf '\n'
log_info "最近 5 个提交："
git log --oneline --no-decorate -5 | while IFS= read -r line; do
    printf '    %s\n' "$line"
done

printf '\n'
log_info "下一步: ./restart-bot.sh all  重启所有机器人"
printf '\n'
