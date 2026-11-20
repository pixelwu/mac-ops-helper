#!/usr/bin/env bash
# install_menubar.sh - 编译并安装零依赖原生 macOS 顶栏状态小助手 (OpsMenuBar.app)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SWIFT="$SCRIPT_DIR/OpsMenuBar.swift"
APP_NAME="OpsMenuBar"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
PLIST_LABEL="com.user.ops-menubar"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"
UID_NUM="$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
  printf "[INFO] 正在卸载 %s...\n" "${APP_NAME}.app"
  launchctl bootout "gui/${UID_NUM}/${PLIST_LABEL}" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  rm -f "$LAUNCH_PLIST"
  rm -rf "$APP_DIR"
  printf "[OK] 已卸载 %s 及登录自启项（后台 ops daemon 不受影响）\n" "${APP_NAME}.app"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  printf "[ERROR] 未检测到 swiftc。请先运行 xcode-select --install 安装 macOS 命令行工具后重试。\n" >&2
  exit 1
fi

if [ ! -f "$SRC_SWIFT" ]; then
  printf "[ERROR] 未找到源文件: %s\n" "$SRC_SWIFT" >&2
  exit 1
fi

printf "[INFO] 正在编译原生顶栏小助手 (%s)...\n" "$SRC_SWIFT"
mkdir -p "$MACOS_DIR" "$LAUNCH_AGENTS_DIR"

# 停掉旧实例以便安全覆盖二进制
launchctl bootout "gui/${UID_NUM}/${PLIST_LABEL}" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swiftc -O -framework Cocoa "$SRC_SWIFT" -o "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${PLIST_LABEL}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleVersion</key>
  <string>1.3.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

cat > "$LAUNCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${MACOS_DIR}/${APP_NAME}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF

launchctl bootstrap "gui/${UID_NUM}" "$LAUNCH_PLIST"
launchctl kickstart -k "gui/${UID_NUM}/${PLIST_LABEL}"

printf "[OK] 顶栏小助手已安装并启动: %s\n" "$APP_DIR"
printf "[INFO] 登录自启配置: %s（点击退出仅关闭图标，不影响后台 ops daemon）\n" "$LAUNCH_PLIST"
