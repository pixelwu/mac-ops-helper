#!/usr/bin/env bash
# ==============================================================================
# ops — macOS 轻量人机协同运维助手 (v1.2.0)
# 兼容 macOS 原生 /bin/bash (Bash 3.2) 与 openrsync
#
# 在任意项目根目录运行，基于项目内的 .ops.json 实现：
#   ops init               生成 .ops.json 清单模板
#   ops pull               拉取关联隐藏目录的脱敏快照与最新日志到 .sync/in/
#   ops apply              部署更新 + 滚动清理旧备份 + 自动运行 verify
#   ops verify             运行宿主机真实探针体检并输出 .sync/report.txt
#   ops capture [App名称]  将目标 App 切至前台并截屏至 .sync/screen.png (兼容挂载卷)
#   ops agy [选项] [文件]  派发 .sync/agy_prompt.md 给 Antigravity 桌面端 (方案 B/A)
#   ops watch [选项]       前台监听当前项目 .sync/agy_prompt.md 自动分流派发
#   ops daemon <子命令>    后台常驻 launchd 多项目守护 (install/uninstall/status/add/remove/list)
#   ops rollback           执行项目回滚脚本
#   ops clean              一键清空当前项目的 .sync/ 临时目录
#   ops --version          查看版本号
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH"
set -euo pipefail

OPS_VERSION="1.2.0"
PROJECT_DIR="$(pwd)"
OPS_CONF="$PROJECT_DIR/.ops.json"
SYNC_DIR="$PROJECT_DIR/.sync"

DAEMON_LABEL="com.user.ops-watch"
DAEMON_PLIST="$HOME/Library/LaunchAgents/${DAEMON_LABEL}.plist"
DAEMON_TMPL="$HOME/.local/share/ops/${DAEMON_LABEL}.plist.tmpl"
DAEMON_PROJECTS_FILE="$HOME/.ops-watch-projects"
DAEMON_STATE_DIR="$HOME/.local/state/ops"
DAEMON_LOG="$DAEMON_STATE_DIR/watch-daemon.log"

expand_path() {
    local p="$1"
    echo "${p/#\~/$HOME}"
}

to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
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
  "agy_app": "Antigravity",
  "agy_idle_seconds": 15,
  "agy_focus_key": "l",
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

    rm -rf "$SYNC_DIR/in"
    mkdir -p "$SYNC_DIR/in/logs"

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
    echo "✅ 拉取完成！现在可以直接让 AI 读取 .sync/in/ 进行排查或修改。"
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
    mkdir -p "$SYNC_DIR"
    local app_name="${1:-}"
    if [[ -z "$app_name" && -f "$OPS_CONF" ]] && command -v jq >/dev/null 2>&1; then
        app_name=$(jq -r '.capture_app // empty' "$OPS_CONF")
    fi
    local screen_file="$SYNC_DIR/screen.png"

    if [[ -n "$app_name" ]]; then
        echo "📸 [ops capture] 正在将 [$app_name] 切至前台并截屏 (避开远程桌面黑屏)..."
        osascript -e "tell application \"$app_name\" to activate" 2>/dev/null || true
        sleep 1
    else
        echo "📸 [ops capture] 正在截取当前屏幕..."
    fi

    # 兼容 SMB / FUSE 远程挂载卷：先写本地 /tmp 临时文件，再流式覆写到 .sync/screen.png
    local tmp_base tmp_screen
    tmp_base=$(mktemp /tmp/ops-screen.XXXXXX)
    tmp_screen="${tmp_base}.png"
    rm -f "$tmp_base"

    if screencapture -x "$tmp_screen" 2>/dev/null && [[ -s "$tmp_screen" ]]; then
        cat "$tmp_screen" > "$screen_file"
        rm -f "$tmp_screen"
        local real_size
        real_size=$(ls -lh "$screen_file" 2>/dev/null | awk '{print $5}' || echo "unknown")
        echo "✅ 截屏已保存: $screen_file (${real_size})"
    else
        rm -f "$tmp_screen"
        echo "⚠️ 截屏失败（请确认当前执行主体拥有「系统设置 -> 隐私与安全性 -> 录屏与系统录音」权限）。"
        return 1
    fi
}

# ─── Antigravity 桌面端联动工具函数 ───

_extract_prompt_mode() {
    local pfile="$1"
    local first_line lower_line
    first_line=$(head -n 1 "$pfile" 2>/dev/null || true)
    lower_line=$(to_lower "$first_line")
    if printf '%s' "$lower_line" | grep -qE '^[[:space:]]*<!--[[:space:]]*ops-mode:[[:space:]]*a[[:space:]]*-->[[:space:]]*$'; then
        echo "a"
    elif printf '%s' "$lower_line" | grep -qE '^[[:space:]]*<!--[[:space:]]*ops-mode:[[:space:]]*b[[:space:]]*-->[[:space:]]*$'; then
        echo "b"
    else
        echo ""
    fi
}

_copy_clean_prompt_to_clipboard() {
    local pfile="$1"
    local mode_tag
    mode_tag=$(_extract_prompt_mode "$pfile")
    if [[ -n "$mode_tag" ]]; then
        tail -n +2 "$pfile" | pbcopy
    else
        pbcopy < "$pfile"
    fi
}

_agy_fallback_plan_a() {
    local agy_app="$1"
    local from_watch="$2"
    local reason="$3"

    echo "ℹ️  [ops agy · 方案 A] ${reason}"
    echo "   ✓ 干净提示词已复制到系统剪贴板"

    if [[ "$from_watch" != "true" ]]; then
        open -a "$agy_app" "$PROJECT_DIR" 2>/dev/null || true
    fi

    osascript -e "display notification \"提示词已复制到剪贴板，方便时切到 ${agy_app} 按 Cmd+V 并回车。\" with title \"ops agy (方案 A)\"" 2>/dev/null || true
}

cmd_agy() {
    local mode="auto"
    local idle_override=""
    local no_capture=false
    local from_watch=false
    local prompt_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                mode=$(to_lower "${2:-auto}")
                shift 2
                ;;
            --mode=*)
                mode=$(to_lower "${1#*=}")
                shift
                ;;
            --idle)
                idle_override="${2:-}"
                shift 2
                ;;
            --idle=*)
                idle_override="${1#*=}"
                shift
                ;;
            --no-capture)
                no_capture=true
                shift
                ;;
            --from-watch)
                from_watch=true
                shift
                ;;
            -h|--help)
                echo "用法: ops agy [--mode auto|a|b] [--idle 秒数] [--no-capture] [提示词文件]"
                return 0
                ;;
            *)
                prompt_file="$1"
                shift
                ;;
        esac
    done

    [[ -z "$prompt_file" ]] && prompt_file="$SYNC_DIR/agy_prompt.md"
    if [[ ! -s "$prompt_file" ]]; then
        echo "❌ 提示词文件不存在或为空: $prompt_file"
        return 1
    fi

    local agy_app="Antigravity"
    local agy_focus_key="l"
    if [[ -f "$OPS_CONF" ]] && command -v jq >/dev/null 2>&1; then
        local cfg_app cfg_key
        cfg_app=$(jq -r '.agy_app // empty' "$OPS_CONF")
        cfg_key=$(jq -r '.agy_focus_key // empty' "$OPS_CONF")
        [[ -n "$cfg_app" ]] && agy_app="$cfg_app"
        [[ -n "$cfg_key" ]] && agy_focus_key=$(to_lower "$cfg_key")
    fi

    local file_mode
    file_mode=$(_extract_prompt_mode "$prompt_file")
    if [[ "$mode" == "auto" ]]; then
        if [[ "$file_mode" == "a" ]]; then
            mode="a"
        else
            mode="b"
        fi
    fi

    _copy_clean_prompt_to_clipboard "$prompt_file"

    if [[ "$mode" == "a" ]]; then
        local reason_msg="按指令或防打扰规则走安全模式（不自动按键）"
        [[ -n "$idle_override" ]] && reason_msg="${reason_msg} (idle阈值: ${idle_override}s)"
        _agy_fallback_plan_a "$agy_app" "$from_watch" "$reason_msg"
        return 0
    fi

    # ─── 方案 B：全自动派发（双焦点护栏）───
    echo "🚀 [ops agy · 方案 B] 正在全自动派发提示词给 [${agy_app}]..."
    open -a "$agy_app" "$PROJECT_DIR" 2>/dev/null || true
    sleep 0.8
    osascript -e "tell application \"$agy_app\" to activate" 2>/dev/null || true
    sleep 0.5

    local front_app=""
    front_app=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
    if [[ -z "$front_app" ]]; then
        _agy_fallback_plan_a "$agy_app" "$from_watch" "无法读取前台进程（可能缺少「辅助功能」权限），已禁止盲贴并安全降级"
        return 0
    fi

    local front_lower app_lower
    front_lower=$(to_lower "$front_app")
    app_lower=$(to_lower "$agy_app")
    if [[ "$front_lower" != "$app_lower" ]]; then
        _agy_fallback_plan_a "$agy_app" "$from_watch" "当前前台窗口为 [${front_app}] 而非 [${agy_app}]，已禁止盲贴并安全降级"
        return 0
    fi

    if ! osascript \
        -e "tell application \"System Events\"" \
        -e "keystroke \"${agy_focus_key}\" using {command down}" \
        -e "delay 0.35" \
        -e "keystroke \"v\" using {command down}" \
        -e "delay 0.25" \
        -e "key code 36" \
        -e "end tell" 2>/dev/null; then
        _agy_fallback_plan_a "$agy_app" "$from_watch" "模拟按键失败（请检查「辅助功能」权限），已安全降级"
        return 0
    fi

    echo "✅ 已成功发送提示词至 [${agy_app}]！"

    if [[ "$no_capture" != "true" ]]; then
        sleep 1
        cmd_capture "$agy_app" || true
    fi
}

_get_idle_seconds() {
    ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' || echo "0"
}

_is_screen_locked() {
    ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked" = Yes'
}

_poll_project_once() {
    local proj="$1"
    local idle_override="$2"
    local no_capture="$3"

    local p_sync="${proj}/.sync"
    local p_conf="${proj}/.ops.json"
    local prompt_file="${p_sync}/agy_prompt.md"
    local hash_file="${p_sync}/.agy_last_hash"

    [[ ! -s "$prompt_file" ]] && return 0

    local cur_hash last_hash
    cur_hash=$(cksum "$prompt_file" 2>/dev/null | awk '{print $1 "-" $2}' || true)
    last_hash=""
    [[ -f "$hash_file" ]] && last_hash=$(cat "$hash_file" 2>/dev/null || true)

    if [[ -n "$cur_hash" && "$cur_hash" != "$last_hash" ]]; then
        mkdir -p "$p_sync"
        echo "$cur_hash" > "$hash_file"

        local idle_threshold="$idle_override"
        if [[ -z "$idle_threshold" ]]; then
            idle_threshold=15
            if [[ -f "$p_conf" ]] && command -v jq >/dev/null 2>&1; then
                local cfg_idle
                cfg_idle=$(jq -r '.agy_idle_seconds // empty' "$p_conf")
                [[ -n "$cfg_idle" ]] && idle_threshold="$cfg_idle"
            fi
        fi

        echo ""
        echo "🔔 [$(date '+%H:%M:%S')] 检测到项目 [${proj}] 的 agy_prompt.md 更新 (hash: ${cur_hash})"

        local file_mode idle_sec locked_flag target_mode
        file_mode=$(_extract_prompt_mode "$prompt_file")
        idle_sec=$(_get_idle_seconds)
        [[ -z "$idle_sec" ]] && idle_sec=0

        locked_flag=false
        if _is_screen_locked; then
            locked_flag=true
        fi

        if [[ "$file_mode" == "a" ]]; then
            target_mode="a"
            echo "   ↳ 提示词标记 ops-mode: A -> 走方案 A"
        elif [[ "$locked_flag" == "true" ]]; then
            target_mode="a"
            echo "   ↳ 检测到屏幕已锁定 -> 走方案 A（不抢焦点）"
        elif (( idle_sec < idle_threshold )); then
            target_mode="a"
            echo "   ↳ 键鼠空闲 ${idle_sec}s < ${idle_threshold}s（人正在操作电脑）-> 走方案 A（不抢焦点）"
        else
            target_mode="b"
            echo "   ↳ 未锁屏且空闲 ${idle_sec}s >= ${idle_threshold}s -> 走方案 B（全自动派发）"
        fi

        (
            cd "$proj"
            PROJECT_DIR="$proj"
            OPS_CONF="${proj}/.ops.json"
            SYNC_DIR="${proj}/.sync"
            if [[ "$no_capture" == "true" ]]; then
                cmd_agy --from-watch --mode "$target_mode" --no-capture "$prompt_file" || true
            else
                cmd_agy --from-watch --mode "$target_mode" "$prompt_file" || true
            fi
        )
    fi
}

cmd_watch() {
    local idle_threshold=""
    local interval=2
    local no_capture=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --idle)       idle_threshold="${2:-}"; shift 2 ;;
            --idle=*)     idle_threshold="${1#*=}"; shift ;;
            --interval)   interval="${2:-2}"; shift 2 ;;
            --interval=*) interval="${1#*=}"; shift ;;
            --no-capture) no_capture=true; shift ;;
            -h|--help)
                echo "用法: ops watch [--idle 秒数] [--interval 轮询秒数] [--no-capture]"
                return 0
                ;;
            *) shift ;;
        esac
    done

    mkdir -p "$SYNC_DIR"
    trap 'echo ""; echo "👋 [ops watch] 已停止监听。"; exit 0' INT TERM

    echo "👀 [ops watch] 开始前台监听: ${SYNC_DIR}/agy_prompt.md"
    echo "   轮询间隔: ${interval}s | 按 Ctrl+C 退出"

    while true; do
        _poll_project_once "$PROJECT_DIR" "$idle_threshold" "$no_capture"
        sleep "$interval"
    done
}

# ─── 多项目常驻后台守护 (launchd) ───

_daemon_add_path() {
    local target="${1:-$PROJECT_DIR}"
    target="$(cd "$target" 2>/dev/null && pwd)" || { echo "❌ 目录不存在: $1"; return 1; }
    touch "$DAEMON_PROJECTS_FILE"
    if grep -Fxq "$target" "$DAEMON_PROJECTS_FILE" 2>/dev/null; then
        echo "ℹ️  项目已在守护监听列表中: $target"
    else
        echo "$target" >> "$DAEMON_PROJECTS_FILE"
        echo "✅ 已加入后台守护监听列表: $target"
    fi
}

_daemon_remove_path() {
    local target="${1:-$PROJECT_DIR}"
    target="$(cd "$target" 2>/dev/null && pwd || echo "$target")"
    if [[ ! -f "$DAEMON_PROJECTS_FILE" ]]; then
        echo "ℹ️  当前没有已登记的监听项目。"
        return 0
    fi
    local tmp
    tmp=$(mktemp /tmp/ops-projects.XXXXXX)
    grep -Fxv "$target" "$DAEMON_PROJECTS_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$DAEMON_PROJECTS_FILE"
    echo "✅ 已从后台守护监听列表移除: $target"
}

cmd_daemon() {
    local sub="${1:-status}"
    shift || true
    local uid_num
    uid_num="$(id -u)"

    case "$sub" in
        add)
            _daemon_add_path "${1:-$PROJECT_DIR}"
            ;;
        remove|rm)
            _daemon_remove_path "${1:-$PROJECT_DIR}"
            ;;
        list|ls)
            echo "📋 后台守护监听项目清单 (${DAEMON_PROJECTS_FILE}):"
            if [[ -s "$DAEMON_PROJECTS_FILE" ]]; then
                nl -ba "$DAEMON_PROJECTS_FILE"
            else
                echo "   (空，运行 ops daemon add 添加当前项目)"
            fi
            ;;
        install)
            mkdir -p "$HOME/Library/LaunchAgents" "$DAEMON_STATE_DIR"
            local tmpl_src="$DAEMON_TMPL"
            if [[ ! -f "$tmpl_src" && -f "${PROJECT_DIR}/ops-tool/${DAEMON_LABEL}.plist.tmpl" ]]; then
                tmpl_src="${PROJECT_DIR}/ops-tool/${DAEMON_LABEL}.plist.tmpl"
            elif [[ ! -f "$tmpl_src" && -f "${PROJECT_DIR}/${DAEMON_LABEL}.plist.tmpl" ]]; then
                tmpl_src="${PROJECT_DIR}/${DAEMON_LABEL}.plist.tmpl"
            fi
            if [[ ! -f "$tmpl_src" ]]; then
                echo "❌ 缺少守护模板 ${DAEMON_TMPL}，请在含 ${DAEMON_LABEL}.plist.tmpl 的目录运行或复制模板至 ~/.local/share/ops/"
                exit 1
            fi
            # 若当前目录含 .ops.json，顺手自动登记
            if [[ -f "$OPS_CONF" ]]; then
                _daemon_add_path "$PROJECT_DIR"
            fi
            sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$USER|g" "$tmpl_src" > "$DAEMON_PLIST"
            launchctl bootout "gui/${uid_num}/${DAEMON_LABEL}" 2>/dev/null || true
            sleep 0.2
            launchctl bootstrap "gui/${uid_num}" "$DAEMON_PLIST"
            launchctl kickstart -k "gui/${uid_num}/${DAEMON_LABEL}" 2>/dev/null || true
            echo "✅ 已安装并启动开机自启后台守护: ${DAEMON_LABEL}"
            echo "   📄 日志路径: ${DAEMON_LOG}"
            echo "   ⚠️  提示：如需后台自动执行方案 B（粘贴发送/截屏），请在「系统设置 → 隐私与安全性」的"
            echo "      「辅助功能」和「录屏与系统录音」中按 Cmd+Shift+G 添加 /bin/bash 并打开开关。"
            ;;
        uninstall)
            launchctl bootout "gui/${uid_num}/${DAEMON_LABEL}" 2>/dev/null || true
            rm -f "$DAEMON_PLIST"
            echo "✅ 已停止并卸载后台守护: ${DAEMON_LABEL}"
            ;;
        status)
            echo "================ ops watch 后台守护状态 (v${OPS_VERSION}) ================"
            if launchctl print "gui/${uid_num}/${DAEMON_LABEL}" >/dev/null 2>&1; then
                echo "• 守护进程 (${DAEMON_LABEL}) : ✅ 运行中 (开机自启)"
            else
                echo "• 守护进程 (${DAEMON_LABEL}) : ⚪ 未运行 (运行 ops daemon install 开启)"
            fi
            echo "• 监听清单 (${DAEMON_PROJECTS_FILE}):"
            if [[ -s "$DAEMON_PROJECTS_FILE" ]]; then
                sed 's/^/    - /' "$DAEMON_PROJECTS_FILE"
            else
                echo "    (空)"
            fi
            if [[ -f "$DAEMON_LOG" ]]; then
                echo "• 最近日志 (${DAEMON_LOG}):"
                tail -n 10 "$DAEMON_LOG" | sed 's/^/    | /'
            fi
            echo "==================================================================="
            ;;
        run)
            mkdir -p "$DAEMON_STATE_DIR"
            touch "$DAEMON_PROJECTS_FILE"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ops daemon] 启动多项目后台监听 (v${OPS_VERSION})"
            while true; do
                if [[ -s "$DAEMON_PROJECTS_FILE" ]]; then
                    while IFS= read -r proj; do
                        [[ -z "$proj" ]] && continue
                        [[ "$proj" == \#* ]] && continue
                        [[ ! -d "$proj" ]] && continue
                        _poll_project_once "$proj" "" "false" || true
                    done < "$DAEMON_PROJECTS_FILE"
                fi
                sleep 2
            done
            ;;
        *)
            echo "用法: ops daemon {install|uninstall|status|add [目录]|remove [目录]|list}"
            exit 1
            ;;
    esac
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
    agy)      shift; cmd_agy "$@" ;;
    watch)    shift; cmd_watch "$@" ;;
    daemon)   shift; cmd_daemon "$@" ;;
    rollback) cmd_rollback ;;
    clean)    cmd_clean ;;
    -v|--version|version)
        echo "ops ${OPS_VERSION}"
        ;;
    help|-h|--help|*)
        echo "ops ${OPS_VERSION} — macOS 轻量人机协同运维助手"
        echo ""
        echo "用法 (在项目根目录执行):"
        echo "  ops init                              生成 .ops.json 清单模板"
        echo "  ops pull                              拉取关联隐藏目录的脱敏快照与日志至 .sync/in/"
        echo "  ops apply                             部署更新 + 滚动清理旧备份 + 自动运行 verify"
        echo "  ops verify                            执行真实宿主机体检并输出 .sync/report.txt"
        echo "  ops capture [App名称]                 将 App 切至前台并截屏至 .sync/screen.png"
        echo "  ops agy [--mode auto|a|b] [文件]      派发 .sync/agy_prompt.md 给 Antigravity 桌面端"
        echo "  ops watch [--idle 秒] [--interval 秒] 前台监听 .sync/agy_prompt.md 自动分流派发"
        echo "  ops daemon {install|status|add|...}   后台常驻 launchd 多项目自动守护"
        echo "  ops rollback                          一键回滚到部署前备份"
        echo "  ops clean                             清空当前项目的 .sync/ 临时目录"
        echo "  ops --version                         查看版本号"
        ;;
esac
