#!/usr/bin/env bash
# install_menubar.sh - 编译并安装原生 macOS 顶栏状态小助手 OpsMenuBar.app（免 root）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SWIFT="${SCRIPT_DIR}/OpsMenuBar.swift"
SRC_INFO="${SCRIPT_DIR}/Info.plist"
SRC_TMPL="${SCRIPT_DIR}/com.user.ops-menubar.plist.tmpl"

APP_DIR="$HOME/Applications/OpsMenuBar.app"
APP_BIN="${APP_DIR}/Contents/MacOS/OpsMenuBar"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.user.ops-menubar"
PLIST_PATH="${AGENTS_DIR}/${PLIST_LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN_TARGET="gui/${UID_NUM}/${PLIST_LABEL}"

if [ "${1:-}" = "--uninstall" ]; then
  printf "[INFO] 正在停止并卸载 OpsMenuBar...\n"
  launchctl bootout "${DOMAIN_TARGET}" >/dev/null 2>&1 || true
  pkill -x OpsMenuBar >/dev/null 2>&1 || true
  rm -f "${PLIST_PATH}"
  rm -rf "${APP_DIR}"
  printf "[OK] 已卸载 OpsMenuBar（不影响后台 ops daemon 继续运行）。\n"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  printf "[ERROR] 未检测到 swiftc，请先安装 Xcode Command Line Tools:\n" >&2
  printf "  xcode-select --install\n" >&2
  exit 1
fi

if [ ! -f "${SRC_SWIFT}" ] || [ ! -f "${SRC_INFO}" ] || [ ! -f "${SRC_TMPL}" ]; then
  printf "[ERROR] 缺少 menubar 源文件，请确认在完整的仓库目录中执行。\n" >&2
  exit 1
fi

printf "[INFO] 停止旧版 OpsMenuBar（如有）...\n"
launchctl bootout "${DOMAIN_TARGET}" >/dev/null 2>&1 || true
pkill -x OpsMenuBar >/dev/null 2>&1 || true

printf "[INFO] 编译原生 OpsMenuBar.app...\n"
mkdir -p "${APP_DIR}/Contents/MacOS"
swiftc -O -framework Cocoa "${SRC_SWIFT}" -o "${APP_BIN}"
cp "${SRC_INFO}" "${APP_DIR}/Contents/Info.plist"
chmod +x "${APP_BIN}"

printf "[INFO] 配置登录自启 LaunchAgent: %s\n" "${PLIST_PATH}"
mkdir -p "${AGENTS_DIR}"
ESC_HOME="$(printf '%s' "$HOME" | sed 's/[|&]/\\&/g')"
sed -e "s|__HOME__|${ESC_HOME}|g" "${SRC_TMPL}" > "${PLIST_PATH}"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "${PLIST_PATH}" >/dev/null
fi

printf "[INFO] 启动 OpsMenuBar...\n"
launchctl bootstrap "gui/${UID_NUM}" "${PLIST_PATH}"
launchctl kickstart -k "${DOMAIN_TARGET}"

printf "[OK] OpsMenuBar 已安装并启动！请查看 macOS 顶部菜单栏。\n"
printf "     如需卸载，请运行: %s --uninstall\n" "$0"
