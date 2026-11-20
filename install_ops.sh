#!/usr/bin/env bash
# install_ops.sh - 免 root 安装 ops 到 ~/.local/bin/ops，并按需配置 ~/.zshrc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="$SCRIPT_DIR/ops.sh"
SRC_TMPL="$SCRIPT_DIR/com.user.ops-watch.plist.tmpl"
INSTALL_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/ops"
TARGET_BIN="$INSTALL_DIR/ops"
ZSHRC_FILE="$HOME/.zshrc"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

if [ ! -f "$SRC_SCRIPT" ]; then
  printf "[ERROR] 未找到源文件: %s\n" "$SRC_SCRIPT" >&2
  exit 1
fi

printf "[INFO] 校验脚本语法...\n"
/bin/bash -n "$SRC_SCRIPT"

printf "[INFO] 创建目标目录: %s\n" "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

printf "[INFO] 安装 ops 到: %s\n" "$TARGET_BIN"
cp "$SRC_SCRIPT" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

if [ -f "$SRC_TMPL" ]; then
  printf "[INFO] 安装 LaunchAgent 模板到: %s\n" "$SHARE_DIR"
  mkdir -p "$SHARE_DIR"
  cp "$SRC_TMPL" "$SHARE_DIR/com.user.ops-watch.plist.tmpl"
fi

# 按需将 ~/.local/bin 写入 ~/.zshrc（幂等检测，避免重复写入）
NEED_SOURCE="false"
if [ -f "$ZSHRC_FILE" ] && grep -Eq '(^|[[:space:]:])(\$HOME|~)/\.local/bin([[:space:]:"]|$)' "$ZSHRC_FILE"; then
  printf "[INFO] ~/.zshrc 中已包含 ~/.local/bin PATH 配置，跳过写入\n"
else
  printf "[INFO] 将 ~/.local/bin 添加到 %s\n" "$ZSHRC_FILE"
  {
    printf "\n# ops CLI tool\n"
    printf "%s\n" "$PATH_LINE"
  } >> "$ZSHRC_FILE"
  NEED_SOURCE="true"
fi

# 检查运行依赖
printf "\n[INFO] 检查运行依赖:\n"
if command -v jq >/dev/null 2>&1; then
  printf "  [OK] jq: %s (%s)\n" "$(command -v jq)" "$(jq --version 2>&1 | head -n 1)"
else
  printf "  [WARN] 未检测到 jq，请运行: brew install jq\n"
fi

if command -v rsync >/dev/null 2>&1; then
  printf "  [OK] rsync: %s\n" "$(command -v rsync)"
else
  printf "  [WARN] 未检测到 rsync\n"
fi

# 可选参数：--with-menubar 一并编译安装顶栏状态小助手
WITH_MENUBAR="false"
if [ "${1:-}" = "--with-menubar" ]; then
  WITH_MENUBAR="true"
fi

if [ "$WITH_MENUBAR" = "true" ]; then
  if [ -f "$SCRIPT_DIR/menubar/install_menubar.sh" ]; then
    printf "\n[INFO] 开始安装顶栏状态小助手 OpsMenuBar.app...\n"
    /bin/bash "$SCRIPT_DIR/menubar/install_menubar.sh"
  else
    printf "\n[WARN] 未找到 menubar/install_menubar.sh，跳过顶栏小助手安装\n"
  fi
elif [ -f "$SCRIPT_DIR/menubar/install_menubar.sh" ]; then
  printf "\n[INFO] 提示: 如需安装 macOS 顶栏状态小助手，可运行:\n"
  printf "  ./menubar/install_menubar.sh  （或重新执行 ./install_ops.sh --with-menubar）\n"
fi

printf "\n[OK] ops 安装完成！\n"
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    printf "当前终端已包含 %s，可直接运行: ops --help\n" "$INSTALL_DIR"
    ;;
  *)
    if [ "$NEED_SOURCE" = "true" ]; then
      printf "请执行以下命令使配置在当前终端立即生效:\n"
    else
      printf "当前终端 PATH 尚未加载 %s，请执行:\n" "$INSTALL_DIR"
    fi
    printf "  source ~/.zshrc && ops --help\n"
    ;;
esac
