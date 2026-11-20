#!/usr/bin/env bash
# ==============================================================================
# ops — macOS 轻量人机协同运维助手 (v1.0)
# 在任意项目根目录运行，基于项目内的 .ops.json 实现：
#   ops pull               拉取关联隐藏目录的脱敏快照与最新日志到 .sync/in/
#   ops apply              部署更新 + 滚动清理旧备份(仅留最近3份) + 自动运行 verify
#   ops verify             运行宿主机真实探针体检并输出 .sync/report.txt
#   ops capture [App名称]  将目标 App 切至前台并截屏至 .sync/screen.png (防远程黑屏)
#   ops rollback           执行项目回滚脚本
#   ops clean              一键清空当前项目的 .sync/ 临时目录
#   ops help               显示帮助
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

PROJECT_DIR="$(pwd)"
OPS_CONF="$PROJECT_DIR/.ops.json"
SYNC_DIR="$PROJECT_DIR/.sync"

expand_path() {
    local p="$1"
    echo "${p/#\~/$HOME}"
}

require_conf() {
    if [[ ! -f "$OPS_CONF" ]]; then
        echo "❌ 当前目录未找到 .ops.json ($PROJECT_DIR)"
        echo "   请先切换到包含 .ops.json 的项目目录，或运行: ops init"
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "❌ 缺少依赖 jq，请先安装: brew install jq"
        exit 1
    fi
}

prune_backups() {
    local bdir keep
    bdir=$(jq -r '.backup_dir // empty' "$OPS_CONF")
    keep=$(jq -r '.keep_backups // 3' "$OPS_CONF")
    [[ -z "$bdir" ]] && return 0
    bdir="$(expand_path "$bdir")"
    [[ ! -d "$bdir" ]] && return 0

    local count=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        count=$((count + 1))
        if (( count > keep )); then
            rm -rf "${bdir:?}/${entry:?}"
            echo "   🧹 已自动清理旧备份: $entry"
        fi
    done < <(ls -1t "$bdir" 2>/dev/null || true)
}

cmd_init() {
    if [[ -f "$OPS_CONF" ]]; then
        echo "⚠️  .ops.json 已存在: $OPS_CONF"
        exit 0
    fi
    cat > "$OPS_CONF" <<'EOF'
{
  "project": "my-project",
  "pull": [
    {
      "src": "~/.my-service",
      "dest": "my-service",
      "exclude": ["bin", "logs", "backups", "*.db", "*.log", "config.json"]
    }
  ],
  "logs": [
    { "path": "~/.my-service/logs/app.log", "lines": 100 }
  ],
  "deploy_cmd": "bash ./deploy.sh",
  "rollback_cmd": "bash ./rollback.sh",
  "backup_dir": "~/.my-service/backups",
  "keep_backups": 3,
  "capture_app": "",
  "verify_cmds": [
    "echo 'OK'"
  ]
}
EOF
    echo "✅ 已生成模板配置文件: $OPS_CONF"
}

cmd_pull() {
    require_conf
    local project_name
    project_name=$(jq -r '.project // "project"' "$OPS_CONF")
    echo "📥 [ops pull] 正在拉取 [$project_name] 现场快照至 .sync/in/ ..."

    # 每次覆盖重建，绝不堆积历史垃圾
    rm -rf "$SYNC_DIR/in"
    mkdir -p "$SYNC_DIR/in/logs"

    # 1. 拉取配置的源码/配置目录（自动按 exclude 跳过敏感文件与大二进制）
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local src dest
        src=$(expand_path "$(echo "$item" | jq -r '.src')")
        dest=$(echo "$item" | jq -r '.dest')

        if [[ ! -e "$src" ]]; then
            echo "   ⚠️ 跳过不存在的路径: $src"
            continue
        fi

        local target="$SYNC_DIR/in/$dest"
        if [[ -d "$src" ]]; then
            mkdir -p "$target"
            local rsync_args=(-a --delete)
            while IFS= read -r ex; do
                [[ -n "$ex" ]] && rsync_args+=(--exclude="$ex")
            done < <(echo "$item" | jq -r '.exclude[]? // empty')
            rsync "${rsync_args[@]}" "$src/" "$target/" 2>/dev/null || true
            ls -la "$src" > "$SYNC_DIR/in/${dest}_tree.txt" 2>/dev/null || true
            echo "   ✓ 已同步目录: $src -> .sync/in/$dest"
        else
            mkdir -p "$(dirname "$target")"
            cp "$src" "$target"
            echo "   ✓ 已同步文件: $src -> .sync/in/$dest"
        fi
    done < <(jq -c '.pull[]? // empty' "$OPS_CONF")

    # 2. 抓取最近 N 行日志
    while IFS= read -r litem; do
        [[ -z "$litem" ]] && continue
        local lpath lines lname
        lpath=$(expand_path "$(echo "$litem" | jq -r '.path')")
        lines=$(echo "$litem" | jq -r '.lines // 100')
        lname=$(basename "$lpath")
        if [[ -f "$lpath" ]]; then
            tail -n "$lines" "$lpath" > "$SYNC_DIR/in/logs/$lname" 2>/dev/null || true
            echo "   ✓ 已采样日志 (最后 ${lines} 行): $lname"
        fi
    done < <(jq -c '.logs[]? // empty' "$OPS_CONF")

    date "+pulled_at=%Y-%m-%d %H:%M:%S" > "$SYNC_DIR/in/.meta"
    echo "✅ 拉取完成！现在可以直接让 Gemini 读取 .sync/in/ 进行排查或修改。"
}

cmd_verify() {
    require_conf
    mkdir -p "$SYNC_DIR"
    local report="$SYNC_DIR/report.txt"
    local project_name
    project_name=$(jq -r '.project // "project"' "$OPS_CONF")

    echo "🧪 [ops verify] 正在宿主机执行真实体检 -> .sync/report.txt ..."
    {
        echo "=================================================================="
        echo "Project : $project_name"
        echo "Time    : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host    : $(scutil --get ComputerName 2>/dev/null || hostname)"
        echo "=================================================================="
        echo ""
    } > "$report"

    local idx=0
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        idx=$((idx + 1))
        {
            echo "--- [Check #$idx] $cmd ---"
            bash -c "$cmd" 2>&1 || echo "(exit code: $?)"
            echo ""
        } >> "$report"
    done < <(jq -r '.verify_cmds[]? // empty' "$OPS_CONF")

    echo "✅ 体检完成！报告已写入: $report"
    echo "   摘要预览："
    head -n 25 "$report" | sed 's/^/   | /'
}

cmd_apply() {
    require_conf
    local deploy_cmd
    deploy_cmd=$(jq -r '.deploy_cmd // empty' "$OPS_CONF")
    if [[ -z "$deploy_cmd" ]]; then
        echo "❌ .ops.json 中未配置 deploy_cmd"
        exit 1
    fi

    echo "🚀 [ops apply] 执行部署命令: $deploy_cmd"
    bash -c "$deploy_cmd"

    echo ""
    echo "🧹 [ops apply] 检查备份滚动策略..."
    prune_backups

    echo ""
    cmd_verify
}

cmd_capture() {
    require_conf
    mkdir -p "$SYNC_DIR"
    local app_name="${1:-}"
    if [[ -z "$app_name" ]]; then
        app_name=$(jq -r '.capture_app // empty' "$OPS_CONF")
    fi
    local out_png="$SYNC_DIR/screen.png"

    if [[ -n "$app_name" ]]; then
        echo "📸 [ops capture] 正在将 [$app_name] 切至前台并截屏 (避开远程桌面黑屏)..."
        osascript -e "tell application \"$app_name\" to activate" 2>/dev/null || true
        sleep 1
    else
        echo "📸 [ops capture] 正在截取当前屏幕..."
    fi

    if screencapture -x "$out_png" 2>/dev/null; then
        echo "✅ 截屏已保存: $out_png (Gemini 可直接读取检核)"
    else
        echo "⚠️ 截屏失败（请确认终端拥有「系统设置 -> 隐私与安全性 -> 录屏」权限）。"
        exit 1
    fi
}

cmd_rollback() {
    require_conf
    local rb_cmd
    rb_cmd=$(jq -r '.rollback_cmd // empty' "$OPS_CONF")
    if [[ -z "$rb_cmd" ]]; then
        echo "❌ .ops.json 中未配置 rollback_cmd"
        exit 1
    fi
    echo "↩️  [ops rollback] 执行回滚: $rb_cmd"
    bash -c "$rb_cmd"
    echo ""
    cmd_verify
}

cmd_clean() {
    if [[ -d "$SYNC_DIR" ]]; then
        rm -rf "$SYNC_DIR"
        echo "🧹 [ops clean] 已彻底清空当前项目的 .sync/ 临时目录。"
    else
        echo "ℹ️  当前项目没有 .sync/ 目录，无需清理。"
    fi
}

case "${1:-help}" in
    init)     cmd_init ;;
    pull)     cmd_pull ;;
    apply)    cmd_apply ;;
    verify)   cmd_verify ;;
    capture)  shift; cmd_capture "${1:-}" ;;
    rollback) cmd_rollback ;;
    clean)    cmd_clean ;;
    help|*)
        echo "ops — macOS 轻量人机协同运维助手 (v1.0)"
        echo ""
        echo "用法 (在项目根目录执行):"
        echo "  ops init               生成 .ops.json 清单模板"
        echo "  ops pull               拉取关联隐藏目录的脱敏快照与日志至 .sync/in/"
        echo "  ops apply              部署更新 + 滚动清理旧备份 + 自动运行 verify"
        echo "  ops verify             执行真实宿主机体检并输出 .sync/report.txt"
        echo "  ops capture [App名称]  将 App 切至前台并截屏至 .sync/screen.png"
        echo "  ops rollback           一键回滚到部署前备份"
        echo "  ops clean              清空当前项目的 .sync/ 临时目录"
        ;;
esac
