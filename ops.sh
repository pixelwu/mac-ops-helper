#!/usr/bin/env bash
# ops - 轻量级全局人机协同运维命令行工具 (macOS / Bash 3.2+ 兼容)
# 基于项目根目录的 .ops.json 驱动，所有同步快照与探测报告均原地覆盖在 .sync/ 下。

set -euo pipefail

OPS_VERSION="1.3.0"
DAEMON_LABEL="com.user.ops-watch"
DAEMON_PROJECTS_FILE="$HOME/.ops-watch-projects"
DAEMON_PLIST_NAME="com.user.ops-watch.plist"
DAEMON_TMPL_NAME="com.user.ops-watch.plist.tmpl"
DAEMON_STATE_DIR="$HOME/.local/state/ops"
DAEMON_HEARTBEAT_FILE="${DAEMON_STATE_DIR}/heartbeat"
DAEMON_PAUSED_FILE="${DAEMON_STATE_DIR}/paused"
DAEMON_STOPPED_FILE="${DAEMON_STATE_DIR}/stopped_by_user"
CONFIG_FILE_NAME=".ops.json"
SYNC_DIR_NAME=".sync"

# 仅在交互终端启用 ANSI 颜色，确保 AI/管道读取时输出干净
if [ -t 1 ]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_CYAN='\033[0;36m'
else
  C_RESET=''
  C_BOLD=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_CYAN=''
fi

log_info()  { printf "${C_CYAN}[INFO]${C_RESET} %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; }
log_err()   { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; }

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_err "缺少依赖命令: $cmd"
    if [ -n "$hint" ]; then
      printf "  提示: %s\n" "$hint" >&2
    fi
    exit 1
  fi
}

# 将开头的 ~ 展开为 $HOME
expand_path() {
  local p="$1"
  case "$p" in
    "~")
      printf "%s\n" "$HOME"
      ;;
    "~/"*)
      printf "%s/%s\n" "$HOME" "${p#~/}"
      ;;
    *)
      printf "%s\n" "$p"
      ;;
  esac
}

# 解析相对路径（相对项目根目录）
resolve_project_path() {
  local base="$1"
  local raw="$2"
  local expanded
  expanded="$(expand_path "$raw")"
  case "$expanded" in
    /*)
      printf "%s\n" "$expanded"
      ;;
    *)
      printf "%s/%s\n" "$base" "$expanded"
      ;;
  esac
}

# 从当前目录向上查找 .ops.json 所在项目根目录
PROJECT_ROOT=""
CONFIG_PATH=""
SYNC_DIR=""

find_project_root() {
  local dir="$PWD"
  while [ -n "$dir" ]; do
    if [ -f "$dir/$CONFIG_FILE_NAME" ]; then
      PROJECT_ROOT="$dir"
      CONFIG_PATH="$dir/$CONFIG_FILE_NAME"
      SYNC_DIR="$dir/$SYNC_DIR_NAME"
      return 0
    fi
    if [ "$dir" = "/" ]; then
      break
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

require_config() {
  require_cmd jq "请先安装 jq（例如执行: brew install jq）"
  if ! find_project_root; then
    log_err "当前目录及上级目录中未找到 $CONFIG_FILE_NAME"
    printf "  请先在项目根目录运行: ops init\n" >&2
    exit 1
  fi
  if ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
    log_err "配置文件 JSON 语法无效: $CONFIG_PATH"
    exit 1
  fi
}

print_usage() {
  cat <<EOF
ops v${OPS_VERSION} - 轻量级全局人机协同运维命令行工具

用法:
  ops <command> [options]

命令:
  init [--force]      在当前目录生成 .ops.json 配置模板
  pull                清空并重建 .sync/in/，用 rsync 同步配置并采样最近日志
  apply               执行 deploy_cmd -> 滚动清理旧备份 -> 自动执行 ops verify
  verify              依次执行 verify_cmds，覆盖写入 .sync/report.txt 并打印摘要
  capture [App名称]   激活目标 App 并等待 1 秒后截屏覆盖保存到 .sync/screen.png
  agy [选项] [文件]   派发 .sync/agy_prompt.md 给 Antigravity 桌面端（方案 B 优先，自动降级方案 A）
  watch [选项]        监听 .sync/agy_prompt.md 变化并按键鼠空闲时间自动分流方案 B / 方案 A
  daemon <子命令>     管理多项目开机自启后台守护 (install/uninstall/start/stop/restart/pause/resume/status/add/remove/list/run)
  rollback            执行 rollback_cmd 回滚 -> 自动执行 ops verify
  clean               一键删除当前项目的 .sync/ 目录
  help, -h, --help    显示本帮助信息
  version, -v         显示版本号

说明:
  除 init 外，所有命令均会自动向上查找项目根目录的 .ops.json，
  所有同步产物统一落盘在项目根目录下的 .sync/（原地覆盖，不堆积）。
EOF
}

# 1. ops init
cmd_init() {
  local force="false"
  if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
    force="true"
  fi

  local target="$PWD/$CONFIG_FILE_NAME"
  if [ -f "$target" ] && [ "$force" != "true" ]; then
    log_warn "当前目录已存在 $CONFIG_FILE_NAME（如需覆盖请运行: ops init --force）"
    exit 1
  fi

  local project_name
  project_name="$(basename "$PWD")"
  # 转义项目名中的双引号和反斜杠，保证生成合法 JSON
  local safe_project_name
  safe_project_name="$(printf '%s' "$project_name" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  cat > "$target" <<EOF
{
  "project": "${safe_project_name}",
  "pull": [
    {
      "src": "~/.config/${safe_project_name}",
      "dest": "config",
      "exclude": [
        ".git",
        "node_modules",
        ".env",
        ".env.*",
        "*.key",
        "*.pem",
        "*.p12",
        "*.dmg",
        "*.zip",
        "*.tar.gz",
        "*.sqlite*",
        ".DS_Store"
      ]
    }
  ],
  "logs": [
    {
      "path": "~/Library/Logs/${safe_project_name}.log",
      "lines": 200
    }
  ],
  "deploy_cmd": "echo '[deploy] 请在 .ops.json 中配置实际 deploy_cmd'",
  "rollback_cmd": "echo '[rollback] 请在 .ops.json 中配置实际 rollback_cmd'",
  "backup_dir": "./backups",
  "keep_backups": 3,
  "capture_app": "",
  "agy_app": "Antigravity",
  "agy_idle_seconds": 15,
  "agy_focus_key": "l",
  "verify_cmds": [
    "uname -a",
    "date"
  ]
}
EOF

  log_ok "已生成配置模板: $target"
  log_info "建议将 .sync/ 加入项目的 .gitignore，避免临时快照进入版本控制。"
}

# 2. ops pull
cmd_pull() {
  require_config
  require_cmd rsync "macOS 默认自带 rsync，请检查 PATH 设置"

  local in_dir="$SYNC_DIR/in"
  local logs_dir="$in_dir/logs"

  # 防堆积：每次先清空再重建 .sync/in/
  if [ -z "$SYNC_DIR" ] || [ "$SYNC_DIR" = "/" ]; then
    log_err "异常的 .sync 目录路径，已中止操作"
    exit 1
  fi
  rm -rf "$in_dir"
  mkdir -p "$in_dir" "$logs_dir"

  local project_name
  project_name="$(jq -r '.project // "unnamed"' "$CONFIG_PATH")"
  log_info "开始同步项目 [${project_name}] -> ${in_dir}"

  # 2.1 rsync 同步 pull 数组
  local pull_count
  pull_count="$(jq -r '(.pull // []) | length' "$CONFIG_PATH")"
  local synced_count=0
  local skipped_count=0
  local i=0

  while [ "$i" -lt "$pull_count" ]; do
    local raw_src raw_dest src_path dest_rel dest_path
    raw_src="$(jq -r ".pull[$i].src // \"\"" "$CONFIG_PATH")"
    raw_dest="$(jq -r ".pull[$i].dest // \"\"" "$CONFIG_PATH")"

    if [ -z "$raw_src" ]; then
      log_warn "pull[$i] 缺少 src 字段，已跳过"
      skipped_count=$((skipped_count + 1))
      i=$((i + 1))
      continue
    fi

    src_path="$(resolve_project_path "$PROJECT_ROOT" "$raw_src")"

    if [ -z "$raw_dest" ]; then
      dest_rel="$(basename "$src_path")"
    else
      # 去掉前导斜杠并阻止路径穿越
      dest_rel="${raw_dest#/}"
      case "$dest_rel" in
        *..*)
          log_err "pull[$i] 的 dest 包含非法路径穿越 (..): $raw_dest"
          exit 1
          ;;
      esac
    fi
    dest_path="$in_dir/$dest_rel"

    if [ ! -e "$src_path" ]; then
      log_warn "源路径不存在，跳过: $src_path"
      skipped_count=$((skipped_count + 1))
      i=$((i + 1))
      continue
    fi

    # 构造 rsync exclude 参数（Bash 3.2 兼容）
    local rsync_args=()
    rsync_args+=(-a)
    local ex_count j ex_pat
    ex_count="$(jq -r "(.pull[$i].exclude // []) | length" "$CONFIG_PATH")"
    j=0
    while [ "$j" -lt "$ex_count" ]; do
      ex_pat="$(jq -r ".pull[$i].exclude[$j]" "$CONFIG_PATH")"
      if [ -n "$ex_pat" ]; then
        rsync_args+=(--exclude="$ex_pat")
      fi
      j=$((j + 1))
    done

    if [ -d "$src_path" ]; then
      mkdir -p "$dest_path"
      rsync "${rsync_args[@]}" --delete "${src_path%/}/" "${dest_path%/}/"
    else
      mkdir -p "$(dirname "$dest_path")"
      rsync "${rsync_args[@]}" "$src_path" "$dest_path"
    fi

    log_ok "已同步: $src_path -> .sync/in/$dest_rel"
    synced_count=$((synced_count + 1))
    i=$((i + 1))
  done

  # 2.2 tail 采样 logs 数组
  local log_count
  log_count="$(jq -r '(.logs // []) | length' "$CONFIG_PATH")"
  local sampled_count=0
  local k=0

  while [ "$k" -lt "$log_count" ]; do
    local raw_log_path log_lines log_path base_name out_file
    raw_log_path="$(jq -r ".logs[$k].path // \"\"" "$CONFIG_PATH")"
    log_lines="$(jq -r ".logs[$k].lines // 100" "$CONFIG_PATH")"

    if [ -z "$raw_log_path" ]; then
      k=$((k + 1))
      continue
    fi

    case "$log_lines" in
      ''|*[!0-9]*)
        log_warn "logs[$k].lines 不是有效正整数 ($log_lines)，回退为 100"
        log_lines=100
        ;;
    esac

    log_path="$(resolve_project_path "$PROJECT_ROOT" "$raw_log_path")"
    if [ ! -f "$log_path" ]; then
      log_warn "日志文件不存在，跳过: $log_path"
      k=$((k + 1))
      continue
    fi

    base_name="$(basename "$log_path")"
    out_file="$logs_dir/$base_name"
    if [ -e "$out_file" ]; then
      out_file="$logs_dir/$((k + 1))_${base_name}"
    fi

    tail -n "$log_lines" "$log_path" > "$out_file"
    log_ok "已采样日志 (最近 ${log_lines} 行): $log_path -> .sync/in/logs/$(basename "$out_file")"
    sampled_count=$((sampled_count + 1))
    k=$((k + 1))
  done

  local total_size
  total_size="$(du -sh "$in_dir" 2>/dev/null | awk '{print $1}')"
  printf "\n"
  log_ok "pull 完成: 同步 ${synced_count} 项 (跳过 ${skipped_count} 项)，采样日志 ${sampled_count} 份，.sync/in/ 总大小 ${total_size:-0B}"
}

# 辅助函数：滚动清理 backup_dir 中的旧备份，仅保留最近 keep_backups 份
rotate_backups() {
  local raw_backup_dir keep_backups backup_path
  raw_backup_dir="$(jq -r '.backup_dir // ""' "$CONFIG_PATH")"
  keep_backups="$(jq -r '.keep_backups // 3' "$CONFIG_PATH")"

  if [ -z "$raw_backup_dir" ]; then
    log_info "未配置 backup_dir，跳过旧备份清理"
    return 0
  fi

  case "$keep_backups" in
    ''|*[!0-9]*|0)
      log_warn "keep_backups 配置无效 ($keep_backups)，自动使用默认值 3"
      keep_backups=3
      ;;
  esac

  backup_path="$(resolve_project_path "$PROJECT_ROOT" "$raw_backup_dir")"
  if [ ! -d "$backup_path" ]; then
    log_info "备份目录尚不存在 ($backup_path)，跳过旧备份清理"
    return 0
  fi

  # 收集备份目录下一级条目并按修改时间降序排列（兼容含空格文件名，macOS BSD stat）
  local tmp_list
  tmp_list="$(mktemp "${TMPDIR:-/tmp}/ops_backups.XXXXXX")"
  local entry mtime
  local total=0

  shopt -s nullglob
  for entry in "$backup_path"/*; do
    mtime="$(stat -f '%m' "$entry" 2>/dev/null || echo 0)"
    printf "%s\t%s\n" "$mtime" "$entry" >> "$tmp_list"
    total=$((total + 1))
  done
  shopt -u nullglob

  if [ "$total" -le "$keep_backups" ]; then
    rm -f "$tmp_list"
    log_info "备份目录当前共 ${total} 份（上限 ${keep_backups} 份），无需清理"
    return 0
  fi

  local idx=0
  local removed=0
  while IFS="$(printf '\t')" read -r _mtime item_path; do
    idx=$((idx + 1))
    if [ "$idx" -gt "$keep_backups" ] && [ -n "$item_path" ]; then
      rm -rf "$item_path"
      log_info "已清理旧备份: $(basename "$item_path")"
      removed=$((removed + 1))
    fi
  done < <(sort -t "$(printf '\t')" -k1,1nr "$tmp_list")

  rm -f "$tmp_list"
  log_ok "备份滚动清理完成: 保留最近 ${keep_backups} 份，删除 ${removed} 份旧备份"
}

# 4. ops verify
cmd_verify() {
  require_config

  mkdir -p "$SYNC_DIR"
  local report_file="$SYNC_DIR/report.txt"
  local project_name host_name now_time os_ver arch_name
  project_name="$(jq -r '.project // "unnamed"' "$CONFIG_PATH")"
  host_name="$(hostname)"
  now_time="$(date '+%Y-%m-%d %H:%M:%S %z')"
  os_ver="$(sw_vers -productVersion 2>/dev/null || uname -sr)"
  arch_name="$(uname -m)"

  local cmd_count
  cmd_count="$(jq -r '(.verify_cmds // []) | length' "$CONFIG_PATH")"

  {
    printf "============================================================\n"
    printf "OPS VERIFY REPORT\n"
    printf "============================================================\n"
    printf "Project   : %s\n" "$project_name"
    printf "Time      : %s\n" "$now_time"
    printf "Host      : %s\n" "$host_name"
    printf "System    : macOS %s (%s)\n" "$os_ver" "$arch_name"
    printf "Root      : %s\n" "$PROJECT_ROOT"
    printf "Commands  : %s\n" "$cmd_count"
    printf "============================================================\n\n"
  } > "$report_file"

  if [ "$cmd_count" -eq 0 ]; then
    printf "(verify_cmds 为空，未执行任何探测命令)\n" >> "$report_file"
    log_warn "verify_cmds 为空，已写入基础报告: $report_file"
    return 0
  fi

  local i=0
  local pass_count=0
  local fail_count=0
  local tmp_out

  log_info "开始执行 ${cmd_count} 条宿主机探测命令..."

  while [ "$i" -lt "$cmd_count" ]; do
    local vcmd rc status_label
    vcmd="$(jq -r ".verify_cmds[$i]" "$CONFIG_PATH")"
    tmp_out="$(mktemp "${TMPDIR:-/tmp}/ops_verify.XXXXXX")"

    set +e
    (cd "$PROJECT_ROOT" && bash -c "$vcmd") >"$tmp_out" 2>&1
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      status_label="PASS"
      pass_count=$((pass_count + 1))
      printf "  ${C_GREEN}[PASS]${C_RESET} (%d/%d) %s\n" "$((i + 1))" "$cmd_count" "$vcmd"
    else
      status_label="FAIL (exit=$rc)"
      fail_count=$((fail_count + 1))
      printf "  ${C_RED}[FAIL]${C_RESET} (%d/%d) %s (exit=%d)\n" "$((i + 1))" "$cmd_count" "$vcmd" "$rc"
    fi

    {
      printf ">>> [%d/%d] %s\n" "$((i + 1))" "$cmd_count" "$vcmd"
      printf "Status: %s\n" "$status_label"
      printf -- "--- Output ---\n"
      cat "$tmp_out"
      printf "\n--- End ---\n\n"
    } >> "$report_file"

    rm -f "$tmp_out"
    i=$((i + 1))
  done

  {
    printf "============================================================\n"
    printf "Summary: %d passed, %d failed (total %d)\n" "$pass_count" "$fail_count" "$cmd_count"
    printf "============================================================\n"
  } >> "$report_file"

  printf "\n"
  if [ "$fail_count" -eq 0 ]; then
    log_ok "verify 全部通过 (${pass_count}/${cmd_count})，详细报告已覆盖写入: ${SYNC_DIR_NAME}/report.txt"
    return 0
  else
    log_warn "verify 存在失败项 (通过 ${pass_count} / 失败 ${fail_count})，详细报告已覆盖写入: ${SYNC_DIR_NAME}/report.txt"
    return 1
  fi
}

# 3. ops apply
cmd_apply() {
  require_config

  local deploy_cmd
  deploy_cmd="$(jq -r '.deploy_cmd // ""' "$CONFIG_PATH")"
  if [ -z "$deploy_cmd" ]; then
    log_err ".ops.json 中未配置 deploy_cmd"
    exit 1
  fi

  log_info "执行 deploy_cmd: $deploy_cmd"
  set +e
  (cd "$PROJECT_ROOT" && bash -c "$deploy_cmd")
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    log_err "deploy_cmd 执行失败 (exit=$rc)，已跳过旧备份清理；如需回滚请运行: ops rollback"
    exit "$rc"
  fi
  log_ok "deploy_cmd 执行成功"

  rotate_backups
  cmd_verify
}

# 5. ops capture [App名称]
cmd_capture() {
  require_cmd screencapture "macOS 默认自带 screencapture，请检查 PATH 设置"

  local cli_app="${1:-}"
  local cfg_app=""
  local target_dir="$PWD/$SYNC_DIR_NAME"

  if find_project_root; then
    target_dir="$SYNC_DIR"
    if command -v jq >/dev/null 2>&1 && jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
      cfg_app="$(jq -r '.capture_app // ""' "$CONFIG_PATH")"
    fi
  fi

  local app_name="$cli_app"
  if [ -z "$app_name" ]; then
    app_name="$cfg_app"
  fi

  mkdir -p "$target_dir"
  local screen_file="$target_dir/screen.png"

  if [ -n "$app_name" ]; then
    require_cmd osascript "macOS 默认自带 osascript"
    log_info "正在将应用 [${app_name}] 切到前台激活渲染..."
    # 转义 AppleScript 双引号与反斜杠
    local escaped_app
    escaped_app="$(printf '%s' "$app_name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    if ! osascript -e "tell application \"${escaped_app}\" to activate" >/dev/null 2>&1; then
      log_warn "无法通过 osascript 激活应用 [${app_name}]，将继续直接截屏（请确认应用名称与自动化权限）"
    else
      sleep 1
    fi
  fi

  # 先截到本地 /tmp，再写入目标目录，避免 SMB/FUSE/远程挂载卷直接落盘失败
  local tmp_base tmp_screen
  tmp_base="$(mktemp "${TMPDIR:-/tmp}/ops_screen.XXXXXX")"
  tmp_screen="${tmp_base}.png"
  rm -f "$tmp_base"

  if screencapture -x "$tmp_screen" && [ -s "$tmp_screen" ]; then
    cat "$tmp_screen" > "$screen_file"
    rm -f "$tmp_screen"
    local img_size
    img_size="$(ls -lh "$screen_file" 2>/dev/null | awk '{print $5}')"
    log_ok "截屏已覆盖保存: $screen_file (${img_size:-unknown})"
  else
    rm -f "$tmp_screen"
    log_err "截屏失败！请在「系统设置 -> 隐私与安全性 -> 录屏与系统录音」中为当前终端开启权限并重启终端后重试。"
    exit 1
  fi
}

# 6. ops rollback
cmd_rollback() {
  require_config

  local rollback_cmd
  rollback_cmd="$(jq -r '.rollback_cmd // ""' "$CONFIG_PATH")"
  if [ -z "$rollback_cmd" ]; then
    log_err ".ops.json 中未配置 rollback_cmd"
    exit 1
  fi

  log_info "执行 rollback_cmd: $rollback_cmd"
  set +e
  (cd "$PROJECT_ROOT" && bash -c "$rollback_cmd")
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    log_err "rollback_cmd 执行失败 (exit=$rc)"
    exit "$rc"
  fi
  log_ok "rollback_cmd 执行成功，开始自动验证..."

  cmd_verify
}

# 7. ops clean
cmd_clean() {
  local target_sync=""
  if find_project_root; then
    target_sync="$SYNC_DIR"
  else
    target_sync="$PWD/$SYNC_DIR_NAME"
  fi

  if [ -z "$target_sync" ] || [ "$target_sync" = "/" ] || [ "$(basename "$target_sync")" != "$SYNC_DIR_NAME" ]; then
    log_err "安全检查未通过，拒绝删除: $target_sync"
    exit 1
  fi

  if [ ! -d "$target_sync" ]; then
    log_info "当前项目不存在 .sync/ 目录，无需清理"
    return 0
  fi

  rm -rf "$target_sync"
  log_ok "已一键删除同步目录: $target_sync"
}

# 辅助函数：读取 macOS 键鼠空闲秒数 (HIDIdleTime)
get_idle_seconds() {
  local sec
  sec="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
  case "$sec" in
    ''|*[!0-9]*) printf "0\n" ;;
    *) printf "%s\n" "$sec" ;;
  esac
}

# 辅助函数：检测 macOS 是否处于锁屏状态
is_screen_locked() {
  if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked" = Yes'; then
    return 0
  fi
  return 1
}

# 辅助函数：发送不抢焦点的 macOS 系统通知
send_mac_notification() {
  local title="$1"
  local subtitle="$2"
  local msg="$3"
  if ! command -v osascript >/dev/null 2>&1; then
    return 0
  fi
  local e_title e_sub e_msg
  e_title="$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  e_sub="$(printf '%s' "$subtitle" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  e_msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  osascript -e "display notification \"${e_msg}\" with title \"${e_title}\" subtitle \"${e_sub}\"" >/dev/null 2>&1 || true
}

# 8. ops agy - 向 Antigravity 桌面端派发提示词（方案 B 优先，忙碌/异常自动降级方案 A）
cmd_agy() {
  require_cmd pbcopy "macOS 默认自带 pbcopy"

  local mode="auto"
  local idle_override=""
  local do_capture="true"
  local from_watch="false"
  local prompt_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        mode="${2:-auto}"
        shift 2
        ;;
      --idle)
        idle_override="${2:-}"
        shift 2
        ;;
      --no-capture)
        do_capture="false"
        shift
        ;;
      --from-watch)
        from_watch="true"
        shift
        ;;
      -h|--help)
        cat <<EOF
用法: ops agy [--mode auto|a|b] [--idle 秒数] [--no-capture] [提示词文件]

说明:
  默认读取 .sync/agy_prompt.md 并复制到剪贴板。
  - 方案 B（默认优先）: 唤起 Antigravity 桌面端 -> 核验前台焦点 -> ⌘+L 聚焦输入框 -> ⌘+V 粘贴 -> 回车 -> 自动截屏
  - 方案 A（安全降级）: 保留提示词在剪贴板并发送系统通知，由你手动 ⌘+V 回车
EOF
        return 0
        ;;
      *)
        prompt_file="$1"
        shift
        ;;
    esac
  done

  local proj_root="$PWD"
  local sync_dir="$PWD/$SYNC_DIR_NAME"
  local proj_name
  proj_name="$(basename "$PWD")"
  local agy_app="Antigravity"
  local idle_threshold=15
  local focus_key="l"

  if find_project_root; then
    proj_root="$PROJECT_ROOT"
    sync_dir="$SYNC_DIR"
    proj_name="$(basename "$PROJECT_ROOT")"
    if command -v jq >/dev/null 2>&1 && jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
      proj_name="$(jq -r '.project // ""' "$CONFIG_PATH")"
      [ -z "$proj_name" ] && proj_name="$(basename "$PROJECT_ROOT")"
      local cfg_app cfg_idle cfg_key
      cfg_app="$(jq -r '.agy_app // ""' "$CONFIG_PATH")"
      cfg_idle="$(jq -r '.agy_idle_seconds // ""' "$CONFIG_PATH")"
      cfg_key="$(jq -r '.agy_focus_key // ""' "$CONFIG_PATH")"
      [ -n "$cfg_app" ] && agy_app="$cfg_app"
      case "$cfg_idle" in
        ''|*[!0-9]*) ;;
        *) idle_threshold="$cfg_idle" ;;
      esac
      [ -n "$cfg_key" ] && focus_key="$cfg_key"
    fi
  fi

  if [ -n "$idle_override" ]; then
    case "$idle_override" in
      *[!0-9]*) log_warn "无效的 --idle 参数 ($idle_override)，继续使用 ${idle_threshold}s" ;;
      *) idle_threshold="$idle_override" ;;
    esac
  fi

  if [ -z "$prompt_file" ]; then
    prompt_file="$sync_dir/agy_prompt.md"
  fi

  if [ ! -s "$prompt_file" ]; then
    log_err "未找到有效的提示词文件: $prompt_file"
    exit 1
  fi

  # 读取可选首行模式标记: <!-- ops-mode: A --> 或 <!-- ops-mode: B -->
  local first_line prompt_hint=""
  first_line="$(head -n 1 "$prompt_file" | tr '[:upper:]' '[:lower:]')"
  case "$first_line" in
    *"ops-mode: a"*|*"ops-mode:a"*)
      prompt_hint="a"
      ;;
    *"ops-mode: b"*|*"ops-mode:b"*)
      prompt_hint="b"
      ;;
  esac

  # 复制干净提示词到剪贴板（若首行含 ops-mode 注释则自动剥离）
  if [ -n "$prompt_hint" ]; then
    tail -n +2 "$prompt_file" | pbcopy
  else
    pbcopy < "$prompt_file"
  fi
  log_ok "提示词已复制到系统剪贴板: $prompt_file"

  # 规范化模式
  local norm_mode
  norm_mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
  local selected_plan="b"
  local fallback_reason=""
  local idle_sec
  idle_sec="$(get_idle_seconds)"

  if [ "$norm_mode" = "a" ]; then
    selected_plan="a"
    fallback_reason="手动指定方案 A"
  elif [ "$norm_mode" = "b" ]; then
    selected_plan="b"
  else
    if [ "$prompt_hint" = "a" ]; then
      selected_plan="a"
      fallback_reason="提示词标记为方案 A（需人工确认）"
    elif is_screen_locked; then
      selected_plan="a"
      fallback_reason="检测到屏幕处于锁定状态"
    elif [ "$from_watch" = "true" ] && [ "$idle_sec" -lt "$idle_threshold" ]; then
      selected_plan="a"
      fallback_reason="检测到你正在操作电脑（空闲 ${idle_sec}s < 阈值 ${idle_threshold}s），避免抢焦点"
    else
      selected_plan="b"
    fi
  fi

  # 方案 A：不强行发送，仅保留剪贴板并通知
  if [ "$selected_plan" = "a" ]; then
    log_warn "启用方案 A（${fallback_reason}）"
    if [ "$from_watch" != "true" ]; then
      open -a "$agy_app" "$proj_root" >/dev/null 2>&1 || true
    fi
    send_mac_notification "ops 协同提醒（方案 A）" "$proj_name" "提示词已复制，方便时切到 ${agy_app} 按 Cmd+V 并回车"
    log_info "请在 ${agy_app} 聊天框中按 Cmd+V 并回车执行。"
    return 0
  fi

  # 方案 B：打开桌面端 -> 核验前台焦点 -> ⌘+L 聚焦输入框 -> ⌘+V 粘贴 -> 回车
  require_cmd osascript "macOS 默认自带 osascript"
  log_info "启用方案 B：正在唤起 ${agy_app} 并自动派发提示词（当前键鼠空闲 ${idle_sec}s）..."

  open -a "$agy_app" "$proj_root" >/dev/null 2>&1 || true
  sleep 0.8

  local escaped_app escaped_key
  escaped_app="$(printf '%s' "$agy_app" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  escaped_key="$(printf '%s' "$focus_key" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  osascript -e "tell application \"${escaped_app}\" to activate" >/dev/null 2>&1 || true
  sleep 0.5

  # 护栏 1：核验最前台进程确实是目标 App（同时校验辅助功能权限）
  local front_app front_lc app_lc
  front_app="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)"
  front_lc="$(printf '%s' "$front_app" | tr '[:upper:]' '[:lower:]')"
  app_lc="$(printf '%s' "$agy_app" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$front_app" ]; then
    log_warn "无法读取前台窗口（请检查「系统设置 -> 隐私与安全性 -> 辅助功能」中是否已授权当前终端），自动降级为方案 A"
    send_mac_notification "ops 自动降级（方案 A）" "$proj_name" "缺少辅助功能权限，提示词已复制，请手动 Cmd+V 发送"
    return 0
  fi

  case "$front_lc" in
    *"$app_lc"*) ;;
    *)
      log_warn "当前前台窗口是 [${front_app}] 而非 [${agy_app}]，为防误粘贴已自动降级为方案 A"
      send_mac_notification "ops 自动降级（方案 A）" "$proj_name" "焦点未停留在 ${agy_app}，提示词已复制，请手动 Cmd+V 发送"
      return 0
      ;;
  esac

  # 护栏 2：先按 ⌘+L 聚焦输入框，再 ⌘+V 粘贴并回车提交
  if osascript <<EOF >/dev/null 2>&1
tell application "System Events"
  keystroke "${escaped_key}" using command down
  delay 0.35
  keystroke "v" using command down
  delay 0.25
  key code 36
end tell
EOF
  then
    log_ok "方案 B 执行成功：已聚焦输入框并发送提示词至 ${agy_app}"
    if [ "$do_capture" = "true" ]; then
      sleep 1
      cmd_capture "$agy_app" || true
    fi
  else
    log_warn "模拟按键发送失败（请检查「辅助功能」权限），已自动降级为方案 A"
    send_mac_notification "ops 自动降级（方案 A）" "$proj_name" "自动发送失败，提示词已复制，请手动 Cmd+V 发送"
  fi
}

# 9. ops watch - 监听 .sync/agy_prompt.md 变化并自动按 B/A 策略分流
cmd_watch() {
  local interval=2
  local idle_override=""
  local extra_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --interval)
        interval="${2:-2}"
        shift 2
        ;;
      --idle)
        idle_override="${2:-}"
        shift 2
        ;;
      --no-capture)
        extra_args+=(--no-capture)
        shift
        ;;
      -h|--help)
        cat <<EOF
用法: ops watch [--idle 秒数] [--interval 轮询秒数] [--no-capture]

说明:
  在前台监听当前项目的 .sync/agy_prompt.md。每当文件内容更新时：
  - 若键鼠空闲 >= 阈值（默认 15s）且未锁屏 -> 自动执行方案 B
  - 若你正在操作电脑 -> 不抢焦点，自动降级为方案 A（复制剪贴板 + 系统通知）
  按 Ctrl+C 随时停止监听。
EOF
        return 0
        ;;
      *)
        log_warn "忽略未知参数: $1"
        shift
        ;;
    esac
  done

  local sync_dir="$PWD/$SYNC_DIR_NAME"
  if find_project_root; then
    sync_dir="$SYNC_DIR"
  fi
  mkdir -p "$sync_dir"

  local prompt_file="$sync_dir/agy_prompt.md"
  local state_file="$sync_dir/.agy_last_hash"
  local last_hash=""
  if [ -f "$state_file" ]; then
    last_hash="$(cat "$state_file" 2>/dev/null || true)"
  fi

  if [ -n "$idle_override" ]; then
    extra_args+=(--idle "$idle_override")
  fi

  trap 'printf "\n"; log_info "已停止 ops watch 监听"; exit 0' INT TERM

  log_info "开始监听 ${prompt_file}（每 ${interval}s 检测一次，按 Ctrl+C 停止）..."
  while true; do
    if [ -s "$prompt_file" ]; then
      local cur_hash
      cur_hash="$(cksum "$prompt_file" 2>/dev/null | awk '{print $1"-"$2}')"
      if [ -n "$cur_hash" ] && [ "$cur_hash" != "$last_hash" ]; then
        printf "\n"
        log_info "检测到新任务提示词更新 (${prompt_file})"
        set +e
        cmd_agy --from-watch "${extra_args[@]+"${extra_args[@]}"}" "$prompt_file"
        set -e
        last_hash="$cur_hash"
        printf "%s\n" "$last_hash" > "$state_file"
      fi
    fi
    sleep "$interval"
  done
}

# 10. ops daemon - 多项目常驻后台守护 (macOS launchd)
daemon_resolve_dir() {
  local raw="${1:-$PWD}"
  local expanded
  expanded="$(expand_path "${raw}")"
  if [ ! -d "${expanded}" ]; then
    log_err "目录不存在: ${expanded}"
    return 1
  fi
  (cd "${expanded}" && pwd)
}

daemon_add_project() {
  local dir_abs
  dir_abs="$(daemon_resolve_dir "${1:-$PWD}")" || exit 1
  touch "${DAEMON_PROJECTS_FILE}"
  if grep -Fxq "${dir_abs}" "${DAEMON_PROJECTS_FILE}" 2>/dev/null; then
    log_info "项目已在监听清单中: ${dir_abs}"
    return 0
  fi
  printf "%s\n" "${dir_abs}" >> "${DAEMON_PROJECTS_FILE}"
  log_ok "已加入后台监听清单: ${dir_abs}"
}

daemon_remove_project() {
  local raw="${1:-$PWD}"
  local dir_abs
  if [ -d "$(expand_path "${raw}")" ]; then
    dir_abs="$(daemon_resolve_dir "${raw}")"
  else
    dir_abs="$(expand_path "${raw}")"
  fi
  if [ ! -f "${DAEMON_PROJECTS_FILE}" ]; then
    log_info "监听清单为空，无需移除"
    return 0
  fi
  if ! grep -Fxq "${dir_abs}" "${DAEMON_PROJECTS_FILE}" 2>/dev/null; then
    log_warn "监听清单中未找到: ${dir_abs}"
    return 0
  fi
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ops_projects.XXXXXX")"
  grep -Fxv "${dir_abs}" "${DAEMON_PROJECTS_FILE}" > "${tmp_file}" || true
  cat "${tmp_file}" > "${DAEMON_PROJECTS_FILE}"
  rm -f "${tmp_file}"
  log_ok "已从后台监听清单移除: ${dir_abs}"
}

daemon_list_projects() {
  if [ ! -s "${DAEMON_PROJECTS_FILE}" ]; then
    log_info "后台监听清单为空（可用 ops daemon add [目录] 添加项目）"
    return 0
  fi
  log_info "后台监听项目清单 (${DAEMON_PROJECTS_FILE}):"
  local line idx=0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      ''|\#*) continue ;;
    esac
    idx=$((idx + 1))
    if [ ! -d "${line}" ]; then
      printf "  %d. %s [目录不存在]\n" "${idx}" "${line}"
    elif [ ! -f "${line}/${CONFIG_FILE_NAME}" ]; then
      printf "  %d. %s [未初始化 .ops.json]\n" "${idx}" "${line}"
    else
      printf "  %d. %s\n" "${idx}" "${line}"
    fi
  done < "${DAEMON_PROJECTS_FILE}"
}

daemon_find_template() {
  local script_dir=""
  script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  local cand
  for cand in \
    "$HOME/.local/share/ops/${DAEMON_TMPL_NAME}" \
    "$PWD/ops-tool/${DAEMON_TMPL_NAME}" \
    "$PWD/${DAEMON_TMPL_NAME}" \
    "${script_dir}/${DAEMON_TMPL_NAME}"; do
    if [ -n "${cand}" ] && [ -f "${cand}" ]; then
      printf "%s\n" "${cand}"
      return 0
    fi
  done
  return 1
}

daemon_install() {
  require_cmd launchctl "macOS 默认自带 launchctl"

  # 若当前项目含 .ops.json，顺手登记进监听清单
  if find_project_root; then
    daemon_add_project "${PROJECT_ROOT}"
  else
    touch "${DAEMON_PROJECTS_FILE}"
  fi

  local tmpl_path
  if ! tmpl_path="$(daemon_find_template)"; then
    log_err "未找到模板文件 ${DAEMON_TMPL_NAME}（已检查 ~/.local/share/ops/、./ops-tool/ 与当前目录）"
    exit 1
  fi

  local agents_dir="$HOME/Library/LaunchAgents"
  local plist_path="${agents_dir}/${DAEMON_PLIST_NAME}"
  local cur_user uid_num domain_target
  cur_user="$(id -un)"
  uid_num="$(id -u)"
  domain_target="gui/${uid_num}/${DAEMON_LABEL}"

  mkdir -p "${agents_dir}" "${DAEMON_STATE_DIR}"
  rm -f "${DAEMON_STOPPED_FILE}" "${DAEMON_PAUSED_FILE}"

  # 渲染模板（将 __HOME__ 与 __USER__ 替换为实际值）
  local esc_home esc_user
  esc_home="$(printf '%s' "$HOME" | sed 's/[|&]/\\&/g')"
  esc_user="$(printf '%s' "${cur_user}" | sed 's/[|&]/\\&/g')"
  sed -e "s|__HOME__|${esc_home}|g" -e "s|__USER__|${esc_user}|g" "${tmpl_path}" > "${plist_path}"

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "${plist_path}" >/dev/null
  fi
  log_ok "已生成 LaunchAgent 配置: ${plist_path}"

  launchctl bootout "${domain_target}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${uid_num}" "${plist_path}"
  launchctl kickstart -k "${domain_target}"
  log_ok "开机自启后台守护已启动 (${domain_target})"
  log_info "提示: 后台方案 B 需要在「系统设置 -> 隐私与安全性」的辅助功能与录屏与系统录音中按 Cmd+Shift+G 添加 /bin/bash 并开启开关（未授权时自动安全降级为方案 A）。"
}

daemon_uninstall() {
  require_cmd launchctl "macOS 默认自带 launchctl"
  local uid_num plist_path domain_target
  uid_num="$(id -u)"
  domain_target="gui/${uid_num}/${DAEMON_LABEL}"
  plist_path="$HOME/Library/LaunchAgents/${DAEMON_PLIST_NAME}"

  mkdir -p "${DAEMON_STATE_DIR}"
  touch "${DAEMON_STOPPED_FILE}"
  rm -f "${DAEMON_PAUSED_FILE}"
  launchctl bootout "${domain_target}" >/dev/null 2>&1 || true
  if [ -f "${plist_path}" ]; then
    rm -f "${plist_path}"
    log_ok "已停止并删除 LaunchAgent: ${plist_path}"
  else
    log_info "LaunchAgent 配置文件不存在，已确保守护停止"
  fi
}

daemon_start() {
  require_cmd launchctl "macOS 默认自带 launchctl"
  local uid_num plist_path domain_target
  uid_num="$(id -u)"
  domain_target="gui/${uid_num}/${DAEMON_LABEL}"
  plist_path="$HOME/Library/LaunchAgents/${DAEMON_PLIST_NAME}"

  mkdir -p "${DAEMON_STATE_DIR}"
  rm -f "${DAEMON_STOPPED_FILE}" "${DAEMON_PAUSED_FILE}"

  if [ ! -f "${plist_path}" ]; then
    daemon_install
    return 0
  fi

  launchctl bootstrap "gui/${uid_num}" "${plist_path}" >/dev/null 2>&1 || true
  launchctl kickstart -k "${domain_target}"
  log_ok "后台守护已启动并恢复监听 (${domain_target})"
}

daemon_stop() {
  require_cmd launchctl "macOS 默认自带 launchctl"
  local uid_num domain_target
  uid_num="$(id -u)"
  domain_target="gui/${uid_num}/${DAEMON_LABEL}"

  mkdir -p "${DAEMON_STATE_DIR}"
  touch "${DAEMON_STOPPED_FILE}"
  launchctl bootout "${domain_target}" >/dev/null 2>&1 || true
  log_ok "已手动停止后台守护（保留 LaunchAgent 配置，可随时通过 ops daemon start 恢复）"
}

daemon_pause() {
  mkdir -p "${DAEMON_STATE_DIR}"
  touch "${DAEMON_PAUSED_FILE}"
  log_ok "已暂停后台自动派发（进程保持轻量待命，运行 ops daemon resume 恢复）"
}

daemon_resume() {
  rm -f "${DAEMON_PAUSED_FILE}"
  log_ok "已恢复后台自动派发"
}

daemon_status() {
  local uid_num domain_target log_file
  uid_num="$(id -u)"
  domain_target="gui/${uid_num}/${DAEMON_LABEL}"
  log_file="${DAEMON_STATE_DIR}/watch-daemon.log"

  local print_out="" is_running="false"
  if print_out="$(launchctl print "${domain_target}" 2>/dev/null)"; then
    if printf "%s\n" "${print_out}" | grep -q 'state = running'; then
      is_running="true"
    fi
  fi

  local hb_info="无记录" hb_age=-1
  if [ -f "${DAEMON_HEARTBEAT_FILE}" ]; then
    local hb_ts now_ts
    hb_ts="$(cat "${DAEMON_HEARTBEAT_FILE}" 2>/dev/null || true)"
    now_ts="$(date +%s)"
    case "${hb_ts}" in
      ''|*[!0-9]*) hb_info="格式异常" ;;
      *)
        hb_age=$((now_ts - hb_ts))
        [ "${hb_age}" -lt 0 ] && hb_age=0
        hb_info="${hb_age}s 前"
        ;;
    esac
  fi

  local summary_state="FAILED"
  if [ "${is_running}" = "true" ]; then
    if [ "${hb_age}" -ge 0 ] && [ "${hb_age}" -le 15 ]; then
      if [ -f "${DAEMON_PAUSED_FILE}" ]; then
        summary_state="PAUSED"
      else
        summary_state="RUNNING"
      fi
    else
      summary_state="FAILED (心跳超时或缺失)"
    fi
  else
    if [ -f "${DAEMON_STOPPED_FILE}" ]; then
      summary_state="STOPPED (已手动停止)"
    else
      summary_state="FAILED (未运行)"
    fi
  fi

  log_info "守护综合状态: ${summary_state} | 最近心跳: ${hb_info}"
  log_info "launchd 详情 (${domain_target}):"
  if [ -n "${print_out}" ]; then
    printf "%s\n" "${print_out}" | grep -E 'state =|pid =|last exit code =|path =' | head -n 6 || true
  else
    log_warn "守护当前未加载（可运行 ops daemon start 启动）"
  fi

  printf "\n"
  daemon_list_projects

  printf "\n"
  if [ -f "${log_file}" ]; then
    log_info "最近 10 行守护日志 (${log_file}):"
    tail -n 10 "${log_file}"
  else
    log_info "暂无守护日志 (${log_file})"
  fi
}

daemon_run() {
  local interval=2
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval)
        interval="${2:-2}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  mkdir -p "${DAEMON_STATE_DIR}"
  touch "${DAEMON_PROJECTS_FILE}"
  rm -f "${DAEMON_STOPPED_FILE}"

  trap 'printf "[%s] ops daemon 收到退出信号，停止运行\n" "$(date "+%Y-%m-%d %H:%M:%S")"; exit 0' INT TERM
  printf "[%s] ops daemon v%s 启动，轮询间隔 %ss，监听清单: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${OPS_VERSION}" "${interval}" "${DAEMON_PROJECTS_FILE}"

  while true; do
    date +%s > "${DAEMON_HEARTBEAT_FILE}"
    if [ -f "${DAEMON_PAUSED_FILE}" ]; then
      sleep "${interval}"
      continue
    fi
    if [ -s "${DAEMON_PROJECTS_FILE}" ]; then
      local proj_dir
      while IFS= read -r proj_dir || [ -n "${proj_dir}" ]; do
        case "${proj_dir}" in
          ''|\#*) continue ;;
        esac
        if [ ! -d "${proj_dir}" ]; then
          continue
        fi
        local prompt_file="${proj_dir}/${SYNC_DIR_NAME}/agy_prompt.md"
        local state_file="${proj_dir}/${SYNC_DIR_NAME}/.agy_last_hash"
        if [ ! -s "${prompt_file}" ]; then
          continue
        fi
        local cur_hash last_hash=""
        cur_hash="$(cksum "${prompt_file}" 2>/dev/null | awk '{print $1"-"$2}')"
        if [ -f "${state_file}" ]; then
          last_hash="$(cat "${state_file}" 2>/dev/null || true)"
        fi
        if [ -n "${cur_hash}" ] && [ "${cur_hash}" != "${last_hash}" ]; then
          printf "[%s] 检测到任务更新: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${prompt_file}"
          set +e
          (cd "${proj_dir}" && cmd_agy --from-watch "${prompt_file}")
          set -e
          printf "%s\n" "${cur_hash}" > "${state_file}"
        fi
      done < "${DAEMON_PROJECTS_FILE}"
    fi
    sleep "${interval}"
  done
}

cmd_daemon() {
  local action="${1:-status}"
  shift || true
  case "${action}" in
    add)       daemon_add_project "$@" ;;
    remove|rm) daemon_remove_project "$@" ;;
    list|ls)   daemon_list_projects "$@" ;;
    install)   daemon_install "$@" ;;
    uninstall) daemon_uninstall "$@" ;;
    start|restart) daemon_start "$@" ;;
    stop)      daemon_stop "$@" ;;
    pause)     daemon_pause "$@" ;;
    resume)    daemon_resume "$@" ;;
    status)    daemon_status "$@" ;;
    run)       daemon_run "$@" ;;
    help|-h|--help)
      cat <<EOF
用法: ops daemon <subcommand> [args]

子命令:
  install          登记当前项目（若含 .ops.json）、渲染 LaunchAgent 并启动开机自启守护
  uninstall        停止并移除 LaunchAgent 守护
  start / restart  启动、重启或一键恢复后台守护（自动清除暂停与停止标记）
  stop             手动停止后台守护（保留配置，顶栏显示低调灰标而不报警）
  pause            软暂停自动派发（进程保持待命，不抢焦点）
  resume           恢复自动派发
  status           查看综合状态（RUNNING/PAUSED/STOPPED/FAILED）、心跳、项目清单与最近日志
  add [目录]       将项目加入 ~/.ops-watch-projects（默认当前目录）
  remove [目录]    从 ~/.ops-watch-projects 移除项目（默认当前目录）
  list             查看已登记的后台监听项目清单
  run              供 launchd 调用的常驻轮询入口
EOF
      ;;
    *)
      log_err "未知 daemon 子命令: ${action}"
      exit 1
      ;;
  esac
}

main() {
  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    init)     cmd_init "$@" ;;
    pull)     cmd_pull "$@" ;;
    apply)    cmd_apply "$@" ;;
    verify)   cmd_verify "$@" ;;
    capture)  cmd_capture "$@" ;;
    agy)      cmd_agy "$@" ;;
    watch)    cmd_watch "$@" ;;
    daemon)   cmd_daemon "$@" ;;
    rollback) cmd_rollback "$@" ;;
    clean)    cmd_clean "$@" ;;
    help|-h|--help)
      print_usage
      ;;
    version|-v|--version)
      printf "ops %s\n" "$OPS_VERSION"
      ;;
    *)
      log_err "未知命令: $subcmd"
      printf "\n"
      print_usage
      exit 1
      ;;
  esac
}

main "$@"
