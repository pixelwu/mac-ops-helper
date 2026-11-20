# ops — macOS 轻量人机协同运维助手 (v1.2.0)

> 一个极简的 macOS 全局命令行小工具（兼容原生 Bash 3.2 与 `openrsync`），专门解决 **“总控 AI 受限于项目目录沙盒，无法直接读写系统隐藏目录、跑宿主机真实体检、跨挂载卷截屏或联动 Antigravity 桌面端施工队”** 的痛点。

---

## 1. 它怎么工作？（一张图看懂）

项目依然留在你原来的文件夹里，完全不干扰 Git 仓库。只需在项目根目录放一个 `.ops.json` 清单，开启一次 `ops daemon install` 后即可后台自动监听多项目：

```text
  【系统隐藏目录】                   【当前项目目录】                      【总控 AI (Gemini)】
   ~/.your-service/                  ./your-project/
   ~/Library/LaunchAgents/             ├── .ops.json
            │                          ├── .sync/
            │   ① ops pull             │     ├── in/            ──────► ② 读代码、设计架构、写提示词
            ├──────────────────────────┼────►│
            │                          │     ├── agy_prompt.md  ◄──────   输出任务包 + 首行模式标记
            │   ③ ops daemon (常驻)     │     │
            │   ──► Antigravity 桌面端 │     ├── agy_log.md     ◄──────   Antigravity 施工完写回留痕
            │       (Turbo 模式施工)    │     │
            │   ④ ops apply / verify   │     ├── report.txt     ──────► ⑤ 总控 AI 读 log + report + 截图验收
            ├──────────────────────────┼────►└── screen.png
```

---

## 2. 一次性安装与更新（免 root，所有项目通用）

```bash
./install_ops.sh && ops --version
```

安装完成后，`ops` 会放到 `~/.local/bin/ops`，守护模板会放到 `~/.local/share/ops/`，以后在**任意项目文件夹**里都能直接用。

---

## 3. 日常命令速查

| 命令 | 做什么 | 什么时候用 |
| :--- | :--- | :--- |
| **`ops init`** | 在当前项目生成一个 `.ops.json` 模板 | 第一次把新项目接入 `ops` 时 |
| **`ops pull`** | 把隐藏目录的最新源码和日志拉到 `.sync/in/`（自动跳过密码/Token） | 让总控 AI 排查问题或改代码前 |
| **`ops apply`** | 执行部署 → 自动滚动清理旧备份（留最近 3 份）→ **自动跑 `verify` 出报告** | 一键落盘并验收时 |
| **`ops verify`** | 只跑宿主机真实探针，生成 `.sync/report.txt` | 单独查服务/端口/网络状态时 |
| **`ops capture [App名]`** | 把指定 App 切至前台，经本地 `/tmp` 中转流式写入 `.sync/screen.png`（兼容 SMB/FUSE 挂载卷，避开黑屏） | 需要让 AI 看界面渲染效果时 |
| **`ops agy [--mode auto\|a\|b] [--idle 秒] [--no-capture] [文件]`** | 读取 `.sync/agy_prompt.md`，剥离首行模式标记后复制剪贴板，按**方案 B（全自动派发）**或**方案 A（安全降级通知）**交给 Antigravity 桌面端 | 手动一键派发给 Antigravity 时 |
| **`ops watch [--idle 秒] [--interval 秒] [--no-capture]`** | 前台轮询当前项目 `.sync/agy_prompt.md`（`cksum` 去重），结合键鼠空闲与锁屏状态自动分流 | 临时调试单项目监听时 |
| **`ops daemon install`** | 安装并启动 `com.user.ops-watch` 开机自启后台守护，自动登记当前项目 | **推荐**：装一次后彻底告别手动开终端跑 `ops watch` |
| **`ops daemon add / remove / list / status / uninstall`** | 增删或查看后台守护监听的项目清单、查看日志或卸载守护 | 新增其他项目到后台监听或排查守护状态时 |
| **`ops rollback`** | 一键回滚到部署前的最近一次备份 | 改完发现不对劲，秒级还原 |
| **`ops clean`** | 删除当前项目的 `.sync/` 临时目录 | 可选，项目完结想清零时 |
| **`ops --version`** | 打印当前版本号（`ops 1.2.0`） | 确认升级是否生效 |

---

## 4. `.ops.json` 配置字段说明

| 字段 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `project` | string | — | 项目名称（写入体检报告头部） |
| `pull` | array | `[]` | 需拉取的隐藏目录/文件清单（支持 `src`、`dest`、`exclude`） |
| `logs` | array | `[]` | 需采样的日志路径及尾部行数（`path`、`lines`） |
| `deploy_cmd` | string | — | `ops apply` 调用的部署命令 |
| `rollback_cmd` | string | — | `ops rollback` 调用的回滚命令 |
| `backup_dir` | string | — | 自动滚动清理旧备份的目录 |
| `keep_backups` | number | `3` | 滚动保留的最近备份份数 |
| `capture_app` | string | `""` | `ops capture` 默认切到前台的 App 名 |
| `agy_app` | string | `"Antigravity"` | `ops agy` / `ops watch` / `ops daemon` 唤起和核验焦点的桌面端应用名 |
| `agy_idle_seconds` | number | `15` | 判定“人已松手”的键鼠空闲秒数阈值 |
| `agy_focus_key` | string | `"l"` | Antigravity 聚焦聊天输入框的 `Cmd + <key>` 快捷键（默认 `Cmd + L`） |
| `verify_cmds` | array | `[]` | `ops verify` 依次执行的宿主机探针命令 |

---

## 5. macOS 权限指引（一次性授权）

macOS 隐私权限按**执行主体**绑定，授权一次后该主体下运行的任意脚本自动继承，无需重复授权：

1. **手动在终端运行 `ops capture` / `ops agy` / `ops watch`**：
   - 在「系统设置 → 隐私与安全性」的 **录屏与系统录音** 和 **辅助功能（Accessibility）** 中，点 `+` 添加你用来敲命令的终端 App（如 `Terminal.app`、iTerm、Warp）并打开开关。
2. **启用 `ops daemon install` 后台开机自启守护（方案 B 必需）**：
   - 由于 `launchd` 后台以 `/bin/bash` 运行，请在上述 **录屏与系统录音** 和 **辅助功能** 两个列表里点 `+`，按 **`Cmd + Shift + G`** 输入 `/bin/bash` 添加并打开开关。
   - 若未授权，后台守护仍可安全工作，只是触发时会自动降级为方案 A（剪贴板 + 系统通知，绝不盲贴）。

---

## 6. 给 AI 助手的协作约定（总控 vs Antigravity 施工队）

1. **最少打扰分工（总控 vs 施工队）**：
   - **总控 AI（Gemini）**：负责需求拆解、架构设计、关键核心逻辑，以及通过 `.sync/` 产物做最终验收；尽量减少碎步执行终端命令，避免频繁弹窗打断人类。
   - **Antigravity 桌面端（Turbo 模式）**：作为一线全自动施工队，批量建文件、装依赖、改多文件、跑编译/单测、处理需要宿主机权限的操作及 UI 点击，全部打包写入 `.sync/agy_prompt.md` 交由其一口气执行。
2. **模式提前告知与高风险刹车**：
   - 总控 AI 每次生成 `.sync/agy_prompt.md` 时，必须在回复最开头明确告知本轮建议走 **方案 B** 还是 **方案 A**。
   - 凡涉及删除重要数据、修改系统核心配置、线上发布或账号敏感操作，必须在 `.sync/agy_prompt.md` 第一行写入 `<!-- ops-mode: A -->` 并在回复开头提醒人类确认。
3. **强制真实环境留痕（`.sync/agy_log.md`）**：
   - 每份 `.sync/agy_prompt.md` 末尾都必须附带收尾要求：无论执行结果是成功、部分完成还是阻塞，Antigravity 都必须将本次完整执行记录**覆盖写入 `.sync/agy_log.md`**，固定包含四部分：
     1. **执行状态与时间**：`SUCCESS` / `PARTIAL` / `BLOCKED`
     2. **改动与命令清单**：新增/修改/删除的文件及执行过的关键命令
     3. **真实环境遇到的问题与处理过程**：每条问题写清「现象与原始报错片段 → 根因判断 → 已尝试的修复与结果（已解决 / 临时绕过 / 仍阻塞） → 需要总控或人类决策的遗留项」
     4. **验收产物状态**：是否已完成 `ops verify`（`.sync/report.txt`）及按需 `ops capture`（`.sync/screen.png`）
   - 验收时优先读取 `.sync/agy_log.md`、`.sync/report.txt` 和 `.sync/screen.png`。

---

## 7. 会不会越用越占空间？

**不会，无需每次手动清理**：`.sync/` 下的 `in/`、`report.txt`、`screen.png`、`agy_prompt.md`、`agy_log.md` 均为单文件/原地覆盖；`backups/` 默认自动滚动只保留最近 3 份；把 `.sync/` 加入 `.gitignore` 即可保持 Git 零污染。
