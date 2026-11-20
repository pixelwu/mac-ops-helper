#!/usr/bin/env bash
# ==============================================================================
# install_ops.sh — 将 ops 命令安装到 ~/.local/bin/ops (无需 root 权限)
# 支持本地脚本执行与一键远程安装:
#   curl -fsSL https://raw.githubusercontent.com/pixelwu/mac-ops-helper/main/install_ops.sh | bash
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

if [[ -f "$SCRIPT_DIR/ops.sh" ]]; then
    cp "$SCRIPT_DIR/ops.sh" "$BIN_DIR/ops"
else
    echo "📥 正在从远程仓库下载 ops.sh ..."
    curl -fsSL "https://raw.githubusercontent.com/pixelwu/mac-ops-helper/main/ops.sh" -o "$BIN_DIR/ops"
fi

chmod +x "$BIN_DIR/ops"

echo "✅ 已安装 ops 到: $BIN_DIR/ops"

if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
    if ! grep -q '\.local/bin' "$HOME/.zshrc" 2>/dev/null; then
        echo '' >> "$HOME/.zshrc"
        echo '# [ops-helper CLI PATH]' >> "$HOME/.zshrc"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
        echo "✓ 已将 $BIN_DIR 写入 ~/.zshrc"
    fi
    echo "👉 请运行一次: source ~/.zshrc   (或新开终端窗口后即可直接使用 ops 命令)"
else
    echo "✓ PATH 已包含 $BIN_DIR，现在可直接运行 ops help 验证。"
fi
