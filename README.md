# CodexQuota

<p align="center"><b>macOS 菜单栏 AI 编程订阅额度监控</b><br>一个状态栏图标，同时盯住 Codex 与 GLM Coding Plan 的 5 小时 / 每周剩余额度</p>

```
 🔴 Codex:0%|84%      ← 红点 = 5小时窗口已用满
 🟢 GLM:96%|97%       ← 绿点 = 额度充裕
```

白色等宽文字 + 彩色状态点，与 macOS 菜单栏原生风格一致。同一状态项内多行叠显，每个被监控的服务占一行，点击菜单即可勾选显示哪些。

## 功能

- **Codex（ChatGPT 订阅）**：5 小时窗口 + 每周窗口剩余百分比、重置倒计时、限流状态、套餐类型
- **GLM Coding Plan（智谱）**：5 小时 + 每周积分余额（精确到点数）、套餐档位（lite/pro/max）、重置时间
- **菜单勾选监控项**：不想盯哪个就取消勾选，状态栏只显示勾选的；选择自动记忆
- **状态点三色**：🟢 余量 > 40%　🟡 11–40%　🔴 ≤ 10% 或已限流
- 5 分钟自动刷新（可 ⌘R 手动），重置倒计时本地每 30 秒刷新
- 零配置后台运行：无 Dock 图标、CPU 占用 ~0%、内存 ~50MB

## 系统要求

- macOS 13.0+
- Codex 监控：本机已用 ChatGPT 账号登录过 Codex CLI（存在 `~/.codex/auth.json`）
- GLM 监控：拥有智谱 GLM Coding Plan 的 API Key

## 安装

### 方式一：一条命令安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/<your-org>/CodexQuota/main/scripts/install.sh | bash
```

脚本做的事：`git clone` → `swiftc` 编译（需要 Xcode Command Line Tools）→ 打包 `.app` → 放入 `/Applications` → 启动并注册登录项。全程约 30 秒。

### 方式二：手动安装

```bash
git clone https://github.com/<your-org>/CodexQuota.git
cd CodexQuota
# 首次编译需要 Xcode Command Line Tools: xcode-select --install
swiftc -O -o CodexQuota Sources/codex_quota.swift
mkdir -p CodexQuota.app/Contents/MacOS
mv CodexQuota CodexQuota.app/Contents/MacOS/
cp Info.plist CodexQuota.app/Contents/
cp -r CodexQuota.app /Applications/
open /Applications/CodexQuota.app
```

如需开机自启动：系统设置 → 通用 → 登录项 → 添加 CodexQuota。

## 配置

### Codex

只要你在本机登录过 Codex CLI（`~/.codex/auth.json` 存在 OAuth token），无需任何配置。app 只读 token 调用官方 usage 接口，**不会上传任何数据**。

### GLM Coding Plan

app 默认从 `~/.hermes/.env` 读取 `CUSTOM_OPEN_BIGMODEL_CN_API_KEY`。如果你的 key 放在别处，用环境变量覆盖：

```bash
# launchctl 方式（重启后仍有效）
launchctl setenv GLM_API_KEY "你的key"

# 或写入 shell 配置 (~/.zshrc)
export GLM_API_KEY="你的key"
```

优先级：`GLM_API_KEY` 环境变量 > `~/.hermes/.env` 中的 `CUSTOM_OPEN_BIGMODEL_CN_API_KEY`。

> 注意：这只影响 GLM 监控读哪个 key。额度按账号统计——监控哪个 key 就显示哪个账号的额度。

## 使用

点击菜单栏图标：

```
状态栏显示:
  ✓ Codex
  ✓ GLM
────────────────
Codex 额度 (team)
  5h余 0%　7d余 84%
  5h重置 2:47:31　7d重置 6d 23h
────────────────
GLM Coding (max)
  5h余 96% (26893/28000)　7d余 97% (135593/140000)
  5h重置 3:12:44　7d重置 6d 18h
────────────────
立即刷新      ⌘R
更新于 下午1:42
────────────────
CodexQuota v1.1.0
退出          ⌘Q
```

菜单里点 **Codex / GLM** 行首的勾选框即可在状态栏显示/隐藏对应监控。

## 工作原理

| | 端点 | 凭证 |
|---|---|---|
| Codex | `GET chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` 的 OAuth access_token |
| GLM | `GET open.bigmodel.cn/api/monitor/usage/quota/limit` | GLM Coding Plan API Key |

两个都是官方接口、纯 GET、只读。app 不收集、不上传任何数据；所有请求直接从你的机器发往对应服务。

## 目录结构

```
CodexQuota/
├── Sources/codex_quota.swift   # 全部源码（单文件，~450 行）
├── Info.plist                  # bundle 配置
├── scripts/install.sh          # 一键安装脚本
└── README.md
```

## License

MIT
