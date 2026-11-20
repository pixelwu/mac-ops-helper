# mac-ops-helper (ops CLI) — macOS 轻量人机协同运维助手

> 一个极简的 macOS 全局命令行小工具（单文件 Bash 脚本），专门解决 **“AI 助手受限于项目目录沙盒，无法直接读写系统隐藏目录、跑宿主机真实体检或看远程桌面界面”** 的痛点。

---

## 1. 它怎么工作？（一张图看懂）

项目依然留在你原来的文件夹里，完全不干扰 Git 仓库或其他 AI 工具。只需在项目根目录放一个 `.ops.json` 清单，日常只用敲极短的单词：

```text
  【系统隐藏目录（AI 进不去）】            【当前项目目录（AI 可读写）】           【AI 助手】
   ~/.your-service/                        ./your-project/
   ~/Library/LaunchAgents/                   ├── .ops.json  (声明关联路径)
            │                                ├── .sync/     (临时区，原地覆盖不堆积)
            │   ① 你敲: ops pull             │     ├── in/        ◀── 脱敏源码 + 日志 ──► ② AI 读代码、改好并自测
            ├────────────────────────────────┼────►│
            │   ③ 你敲: ops apply            │     │
            │◄───────────────────────────────┼─────┤ (先备份 → 部署 → 自动滚动清旧备份)
            │   ④ 自动跑: ops verify         │     │
            ├────────────────────────────────┼────►├── report.txt ◀── 真实宿主机体检 ───► ⑤ AI 读报告验收
            │   (可选) ops capture           │     └── screen.png ◀── 自动切前台截屏
```

---

## 2. 一次性安装（免 root，所有项目通用）

### 方式一：克隆仓库安装（推荐）

```bash
# 1. 克隆仓库
git clone git@github.com:pixelwu/mac-ops-helper.git
cd mac-ops-helper

# 2. 执行安装并刷新环境变量
bash ./install_ops.sh && source ~/.zshrc
```

> **提示**：若未配置 GitHub SSH 密钥，可使用 HTTPS 协议克隆：  
> `git clone https://github.com/pixelwu/mac-ops-helper.git`

### 方式二：单行在线安装

```bash
curl -fsSL https://raw.githubusercontent.com/pixelwu/mac-ops-helper/main/install_ops.sh | bash && source ~/.zshrc
```

安装完成后，`ops` 会被放置于 `~/.local/bin/ops`，在**任意终端与项目目录**下均可直接调用。

---

## 3. 日常命令速查（你只需要记住这几个）

| 命令 | 做什么 | 什么时候用 |
| :--- | :--- | :--- |
| **`ops init`** | 在当前项目生成一个 `.ops.json` 模板 | 第一次把某个运维类项目接入 `ops` 时 |
| **`ops pull`** | 把隐藏目录的最新源码和最近日志拉到 `.sync/in/`（自动跳过密码/Token） | 想让 AI 帮你排查或改代码前 |
| **`ops apply`** | 执行部署 → 自动滚动清理旧备份（只留最近 3 份）→ **自动跑 `verify` 出报告** | AI 改完代码，你准备一键落盘并验收时 |
| **`ops verify`** | 只跑宿主机真实探针，生成 `.sync/report.txt` | 想单独查服务/端口/网络状态时 |
| **`ops capture [App名]`** | 自动把指定 App 切到最前台并截屏存到 `.sync/screen.png` | 需要让 AI 看界面渲染效果，绕开 Mac mini 远程桌面黑屏 |
| **`ops rollback`** | 一键回滚到部署前的最近一次备份 | 改完发现不对劲，秒级还原 |
| **`ops clean`** | 删除当前项目的 `.sync/` 临时目录 | 可选，项目彻底完结想清零时顺手敲一下 |

---

## 4. 会不会越用越占空间？（防堆积机制）

**不会，平时不需要每次手动清理：**
1. **`.sync/` 原地覆盖**：`ops pull`、`ops verify`、`ops capture` 每次运行都会直接覆盖上一次的快照、报告和截图，不会按时间生成一堆历史副本，通常只占几 MB。
2. **备份自动淘汰**：`ops apply` 内置滚动清理，默认只保留最近 `3` 次备份（可在 `.ops.json` 里用 `keep_backups` 调整），超出的最老备份会自动删掉。
3. **Git 零污染**：把 `.sync/` 写进项目的 `.gitignore`，临时文件和截图永远不会被误提交到远程仓库。

---

## 5. 给新项目接入 `ops`（30 秒配置）

在任意项目根目录运行 `ops init`（或复制 `.ops.json.example` 为 `.ops.json`），按实际路径修改即可：

```json
{
  "project": "my-service",
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
  "capture_app": "My App",
  "verify_cmds": [
    "echo '在这里填你的端口/服务/连通性自检命令'"
  ]
}
```

---

## 6. macOS 前台截屏权限说明（仅首次使用 `ops capture`）

在 Mac mini 远程桌面 / BetterDisplay 环境下，为了使用 `ops capture` 截屏：
1. 打开 **系统设置 → 隐私与安全性 → 录屏与系统录音**。
2. 点击左下角 **`+`**，添加**你用来敲命令的终端 App**（例如 `应用程序 → 实用工具 → 终端.app`，或 iTerm / Warp / Antigravity），打开开关并重启该终端即可。

---

## 7. 依赖要求

* macOS（自带 `rsync`、`osascript`、`screencapture`）
* `jq`（如未安装：`brew install jq`）
