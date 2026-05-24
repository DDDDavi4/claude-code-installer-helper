# Claude Code CLI 一键安装脚本 — 技术规范 SPEC

**版本**: v1.1
**日期**: 2026-05-24
**状态**: 已确认（全部待定项已解决）
**仓库**: `DDDDavi4/claude-code-installer-helper`

---

## 1. 概述

### 1.1 目标

提供一套 **跨平台一键安装脚本**，让用户在 macOS / Windows 上以最低门槛完成 Claude Code CLI 的安装，同时集成 CCSwitch 以接入 DeepSeek V4 后端。

### 1.2 核心原则

- **零前置假设**：用户可能没有 Node.js、Git，脚本全自动处理。
- **国内可用**：自动检测网络环境，无缝切换国内镜像源。
- **快速成功路径**：90% 用户应能在 2 分钟内完成安装。
- **失败可恢复**：每一步都有清晰的中文错误提示和修复建议。

---

## 2. 架构总览

```
用户下载脚本
├── [在线模式] install.sh / install.ps1
│   ├── 阶段0: 环境检测 (OS, Shell, 权限)
│   ├── 阶段1: 前置依赖 (Node.js via nvm, Git)
│   ├── 阶段2: 网络测速 & 镜像选择
│   ├── 阶段3: 安装 Claude Code CLI (npm global)
│   ├── 阶段4: 安装 CCSwitch (下载桌面应用 + 打印配置指南)
│   └── 阶段5: 验证 & 完成提示
│
├── [Bundle 模式] install.sh --use-bundle / install.ps1 -UseBundle
│   ├── 解压本地/远程 bundle 压缩包
│   └── 从 bundle 离线安装所有组件
│
└── [卸载模式] install.sh --uninstall / install.ps1 -Uninstall
    └── 清理所有安装痕迹
```

### 2.1 文件清单

| 文件 | 用途 | 目标平台 |
|------|------|----------|
| `install.sh` | bash 在线安装入口 | macOS / Linux |
| `install.ps1` | PowerShell 在线安装入口 | Windows |
| `lib/common.sh` | bash 脚本共用函数库 | macOS / Linux |
| `lib/common.ps1` | PowerShell 共用函数库 | Windows |
| `.github/workflows/build-bundle.yml` | CI 自动构建 bundle | GitHub Actions |
| `cc-offline-{version}-darwin.tar.gz` | macOS 全家桶 bundle | macOS |
| `cc-offline-{version}-win32.zip` | Windows 全家桶 bundle | Windows |
| `checksums.sha256` | bundle 完整性校验文件 | 随 bundle 发布 |
| `README.md` | 用户文档 + 安装指引 | GitHub 首页 |

---

## 3. 分发方式

### 3.1 主路径：在线脚本

用户通过 GitHub 仓库 README 提供的一行命令安装：

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/DDDDavi4/claude-code-installer-helper/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
iwr -Uri "https://raw.githubusercontent.com/DDDDavi4/claude-code-installer-helper/main/install.ps1" -OutFile install.ps1; .\install.ps1
```

### 3.2 保底路径：Bundle 模式

用户手动指定 `--use-bundle`，脚本从双线托管下载全家桶 bundle：

```bash
bash install.sh --use-bundle
# 或
.\install.ps1 -UseBundle
```

### 3.3 Bundle 双线托管

| 线路 | 地址 | 优先级 |
|------|------|--------|
| 腾讯云 COS | `https://<bucket>.cos.ap-<region>.myqcloud.com/` | 自动测速优先生效 |
| GitHub Releases | `https://github.com/DDDDavi4/claude-code-installer-helper/releases/` | 保底线路 |

脚本在下载 bundle 前自动测速两个源，选择延迟最低的。

---

## 4. 阶段详细设计

### 4.0 环境检测

```
输入：无
输出：OS 类型、Shell 类型、权限状态、可用磁盘空间
```

**检测项：**

| 检测项 | macOS | Windows |
|--------|-------|---------|
| 操作系统 | `uname -s` | `$env:OS` |
| 架构 | `uname -m` | `[Environment]::Is64BitOperatingSystem` |
| Shell | `$SHELL` | `$Host.Name` |
| 磁盘空间 | `df -h` | `Get-PSDrive` |
| 写入权限 | 测试 `$HOME` 目录 | 测试 `$env:USERPROFILE` |

**边界处理：**

- 磁盘空间 < 2GB：**警告**并询问是否继续
- 无写入权限：提示手动创建目录或切换用户
- 32 位系统：**警告**（nvm 64-bit 推荐）
- Windows 中文用户名（路径含空格）：自动使用短路径名 (`8.3` 格式) 作为 fallback

### 4.1 前置依赖

#### 4.1.1 Node.js 安装 (通过 nvm)

```
策略：检测 → 无则装 nvm → 通过 nvm 装 Node LTS → 验证
```

**macOS / Linux (`install.sh`):**
1. 检测 `node --version`，若版本 >= CC 最低要求则跳过
2. 否则检测 `nvm --version`，无则安装 [nvm-sh/nvm](https://github.com/nvm-sh/nvm)
3. `nvm install --lts` 安装 Node LTS
4. `nvm use --lts` 激活
5. 写入 `.bashrc` / `.zshrc` 确保 nvm 在新终端可用

**Windows (`install.ps1`):**
1. 检测 `node --version`，若版本 >= CC 最低要求则跳过
2. 否则检测 nvm-windows，无则下载 [coreybutler/nvm-windows](https://github.com/coreybutler/nvm-windows) 安装器
3. 静默安装 nvm-windows (`/VERYSILENT`)
4. `nvm install lts` && `nvm use lts`
5. 刷新 PATH 环境变量

**CC 最低 Node 版本**：从 `npm view @anthropic-ai/claude-code engines.node` 动态读取，写入脚本常量，CI 自动更新。

#### 4.1.2 Git 安装

**全平台检测逻辑：**

| 平台 | 检测方式 | 安装方式 |
|------|----------|----------|
| macOS | `git --version` | 引导安装 Xcode CLT：`xcode-select --install` |
| Windows | `git --version` | 下载 Git for Windows 安装器（静默安装） |
| Linux | `git --version` | `apt-get install git` / `yum install git` |

**交互设计：**
- macOS：检测到缺失 → 自动触发 `xcode-select --install`（系统弹窗确认）
- Windows：检测到缺失 → **提示用户选择** Y/n，确认后下载安装

### 4.2 网络测速 & 镜像选择

```
策略：并行测速 → 选择最优源 → 设置 npm registry → 继续安装
```

**测速节点列表：**

| 源 | URL | 用途 |
|----|-----|------|
| npm 官方 | `https://registry.npmjs.org/` | npm 默认源 |
| npmmirror | `https://registry.npmmirror.com/` | 国内首选镜像 |
| GitHub 官方 | `https://github.com` | git clone / release 下载 |
| GitHub 镜像 | `https://ghproxy.com/` | 国内 GitHub 加速 |

**测速方法：**
- 每个源发 1 个轻量 HTTP HEAD 请求，记录延迟
- 超时阈值：3 秒
- 选择延迟最低的可用源
- 如果所有源超时：输出 DNS / 代理排查建议

**代理检测：**
1. 检测环境变量 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`
2. 如果设置了代理但连接不通 → 警告用户 "检测到代理配置但连接失败，建议检查代理设置"
3. 提示 `unset` 命令关闭代理（不自动执行）

### 4.3 安装 Claude Code CLI

```
npm install -g @anthropic-ai/claude-code
```

**npm 权限修复 (macOS/Linux)：**
- 如果遇到 EACCES / EPERM 错误：
  1. 自动创建 `~/.npm-global` 目录
  2. `npm config set prefix ~/.npm-global`
  3. 将 `~/.npm-global/bin` 加入 PATH
  4. 重新执行安装

**Windows 路径处理：**
- 检测 `%APPDATA%\npm` 是否在 PATH 中
- 若不在，自动添加到用户级 PATH
- 如果用户名含非 ASCII 字符或空格 → 使用 `%USERPROFILE%` 短路径名

**验证安装：**
```bash
claude --version
```

### 4.4 安装 CCSwitch (DeepSeek V4 接入)

**CCSwitch 是什么：** [farion1231/cc-switch](https://github.com/farion1231/cc-switch) 是一个基于 Tauri 2 的**桌面 GUI 应用**，用于管理 Claude Code 等多款 AI CLI 工具的模型供应商切换。通过 GUI 界面添加供应商、填写 API Key、配置模型映射，无需手动改配置文件。

```
策略：下载最新 Release → 安装桌面应用 → 启动应用 → 打印 GUI 配置指南
```

#### 4.4.1 macOS 安装 CCSwitch

```bash
# 方式1 (推荐): Homebrew Cask
brew tap farion1231/ccswitch
brew install --cask cc-switch

# 方式2: 直接下载 .zip 解压到 /Applications
# 从 GitHub Releases 下载 CC-Switch-v{version}-macOS.zip
```

**安装后步骤：**
1. 启动 `CC Switch.app`（如遇"无法验证开发者"，引导用户前往「系统设置 → 隐私与安全性 → 仍要打开」）
2. 应用启动后会在系统托盘显示图标
3. 脚本输出 GUI 配置指南（见 4.4.3）

#### 4.4.2 Windows 安装 CCSwitch

```powershell
# 方式1 (推荐): 下载 .msi 安装器静默安装
# 从 GitHub Releases 下载 CC-Switch-v{version}-Windows.msi
msiexec /i "CC-Switch-v{version}-Windows.msi" /quiet

# 方式2: 下载便携版 .zip 解压运行
```

**安装后步骤：**
1. 从开始菜单或桌面快捷方式启动 CC Switch
2. 系统托盘出现图标即表示运行成功
3. 脚本输出 GUI 配置指南（见 4.4.3）

#### 4.4.3 DeepSeek V4 配置指南（由脚本打印）

CCSwitch 安装完成后，脚本不会自动配置（需 GUI 交互），而是输出以下指南：

```
╔══════════════════════════════════════════════════════════╗
║       CC Switch — 配置 DeepSeek V4 接入 Claude Code       ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  1. 获取 DeepSeek API Key                                ║
║     - 阿里云百炼: https://bailian.console.aliyun.com     ║
║     - 硅基流动:   https://siliconflow.cn                  ║
║     - DeepSeek 官方: https://platform.deepseek.com       ║
║                                                          ║
║  2. 打开 CC Switch 系统托盘图标                           ║
║     → 点击「供应商」→「添加供应商」                        ║
║     → 选择 DeepSeek → 填入 API Key                       ║
║                                                          ║
║  3. 配置模型映射                                          ║
║     → Haiku  → deepseek-v4-pro（或 deepseek-v4-flash）   ║
║     → Sonnet → deepseek-v4-pro                           ║
║     → Opus   → deepseek-v4-pro                           ║
║     ⚠️ 本地路由模式下不要带 [1m] 后缀                      ║
║                                                          ║
║  4. 切换到 DeepSeek                                      ║
║     → CC Switch → 选择 DeepSeek 供应商 → 点击「应用」      ║
║                                                          ║
║  5. 验证: 运行 claude 观察模型是否为 deepseek-v4-pro      ║
║                                                          ║
║  详细文档: https://github.com/farion1231/cc-switch        ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

#### 4.4.4 CCSwitch Release 检测

脚本启动时从 GitHub API 获取 CCSwitch 最新版本号：
```
GET https://api.github.com/repos/farion1231/cc-switch/releases/latest
```
用于构建正确的下载 URL。如果 GitHub API 不可达（国内网络），使用硬编码的 fallback 版本号或通过 ghproxy 代理获取。

### 4.5 验证 & 完成提示

```
检查清单 → 输出安装报告 → 提示后续操作
```

**验证清单：**
- [ ] `node --version` 满足 CC 最低要求
- [ ] `git --version` 可用
- [ ] `claude --version` 输出正常
- [ ] `ccswitch status` 显示已切换到 DeepSeek V4
- [ ] `npm config get registry` 指向可用源

**输出示例：**
```
╔════════════════════════════════════════════════╗
║     Claude Code CLI 安装成功！                  ║
╠════════════════════════════════════════════════╣
║  Node.js:  v20.11.0                           ║
║  Git:      v2.43.0                            ║
║  CC CLI:   v1.2.3                             ║
║  Backend:  DeepSeek V4 (via CCSwitch)          ║
║  npm 源:   https://registry.npmmirror.com/    ║
╠════════════════════════════════════════════════╣
║  运行 claude 开始使用                           ║
║  运行 cclogin 进行认证                          ║
╚════════════════════════════════════════════════╝
```

---

## 5. Bundle 系统

### 5.1 Bundle 内容

全家桶 bundle 是一个自包含压缩包，包含：

```
cc-offline-{version}-{platform}.tar.gz
├── node/                  # Node.js 二进制（对应平台）
├── git/                   # Git 安装器/二进制（对应平台）
├── npm-packages/          # CC CLI 及所有依赖的 .tgz 离线包
├── ccswitch/              # CCSwitch 桌面应用安装器（.dmg / .msi）
├── setup.sh / setup.ps1   # 离线安装入口
└── manifest.json          # 包含版本号和校验信息
```

### 5.2 CI 自动构建 (GitHub Actions)

```
触发条件：CC 新版本发布 (监听 npm registry) 或 手动 workflow_dispatch
```

**工作流步骤：**
1. 检测 `@anthropic-ai/claude-code` 最新版本
2. 下载各平台 Node.js LTS 二进制
3. 下载 Git for Windows 安装器
4. `npm pack @anthropic-ai/claude-code` 生成离线包
5. 打包为 `cc-offline-{version}-{platform}.{ext}`
6. 生成 `checksums.sha256`
7. 发布到 GitHub Releases + 上传至腾讯云 COS
8. 更新 `install.sh` / `install.ps1` 中的版本号常量

### 5.3 版本策略

- Bundle 版本号**严格跟随** CC 版本号
- CC 发布新版本后，CI 自动触发打包（预期延迟 < 30 分钟）
- Node.js 版本：跟随 CC 的 `engines.node` 要求
- Git 版本：每月检查一次 Git for Windows 最新稳定版

---

## 6. 故障排查矩阵

### 6.1 npm 权限错误 (macOS/Linux)

| 症状 | 诊断 | 自动修复 |
|------|------|----------|
| `EACCES` / `EPERM` | npm 全局目录无写入权限 | 配置 `~/.npm-global` + 添加 PATH |
| `EACCES` on `~/.npm` | 缓存目录被 sudo 污染 | `sudo chown -R $(whoami) ~/.npm`（需用户确认） |

### 6.2 代理干扰

| 症状 | 诊断 | 修复提示 |
|------|------|----------|
| `ECONNREFUSED` | 代理设置无效 | 提示 `unset *_PROXY` 或检查代理服务 |
| `Tunnel connection failed` | 代理服务器不可达 | 提示检查代理地址和端口 |
| 连接到 localhost:port 超时 | 本地代理占用了端口 | 提示关闭代理软件 |

### 6.3 路径与用户名问题 (Windows)

| 症状 | 诊断 | 自动修复 |
|------|------|----------|
| npm 安装后找不到命令 | `%APPDATA%\npm` 不在 PATH | 自动添加到用户 PATH |
| 中文/空格路径导致报错 | `%USERPROFILE%` 含特殊字符 | 使用 8.3 短路径名 fallback |

### 6.4 Xcode Command Line Tools (macOS)

| 症状 | 诊断 | 修复 |
|------|------|------|
| `xcrun: error` | CLT 未安装 | `xcode-select --install` |
| Git 命令不存在 | CLT 未安装（包含 git） | 同上 |

### 6.5 认证超时向导

| 症状 | 可能原因 | 排查步骤 |
|------|----------|----------|
| `claude` 启动后登录超时 | 1. 网络不通 2. 代理问题 3. API 服务异常 | 1. 检查网络 2. 检查代理 3. 访问 status.anthropic.com |
| CCSwitch 连接失败 | 1. DeepSeek API Key 未设 2. CCSwitch 配置错误 | 1. 检查环境变量 2. 运行 `ccswitch doctor` |

### 6.6 DNS 故障

| 症状 | 诊断 | 修复建议 |
|------|------|----------|
| `getaddrinfo ENOTFOUND` | DNS 解析失败 | 建议切换 DNS：`8.8.8.8` 或 `114.114.114.114` |
| 特定域名无法解析 | 可能被污染/屏蔽 | 建议检查 hosts 或使用代理 |

---

## 7. 卸载设计

### 7.1 触发方式

```bash
# macOS / Linux
bash install.sh --uninstall

# Windows
.\install.ps1 -Uninstall
```

### 7.2 卸载内容

| 组件 | 操作 | 需要确认 |
|------|------|----------|
| Claude Code CLI | `npm uninstall -g @anthropic-ai/claude-code` | 否 |
| CCSwitch | macOS: `brew uninstall --cask cc-switch` 或删除 .app；Windows: 通过「添加/删除程序」卸载 | **是**（桌面应用需手动卸载） |
| nvm & Node.js | 默认**不卸载**（可能被其他项目使用） | **是**（额外提示） |
| npm 配置修改 | 恢复原始 registry | 否 |
| PATH 修改 | 询问是否还原 | **是** |
| ~/.claude 配置目录 | 删除（含登录态） | **是** |

### 7.3 卸载后状态

卸载脚本执行完后输出残留文件清单，让用户手动确认是否彻底清理。

---

## 8. 辅助功能

### 8.1 `--dry-run` 模式

```
bash install.sh --dry-run
.\install.ps1 -DryRun
```

不实际安装，仅输出：
- 检测到的系统信息
- 将要安装的组件及版本
- 将占用的磁盘空间
- 可能遇到的问题预警

### 8.2 `--uninstall` 卸载模式

（见第 7 章）

### 8.3 `--use-bundle <path>` 指定本地 bundle

```
bash install.sh --use-bundle ./cc-offline-1.0.0-darwin.tar.gz
```

跳过下载，直接使用本地 bundle 文件安装（适用于离线/U盘场景）。

### 8.4 日志记录

所有安装操作写入日志文件：
- macOS/Linux: `~/.claude/install-{timestamp}.log`
- Windows: `$env:USERPROFILE\.claude\install-{timestamp}.log`

失败时脚本末尾自动输出日志路径。

---

## 9. 安全设计

### 9.1 SHA256 校验

- 每次 bundle 发布时生成 `checksums.sha256`
- 脚本下载 bundle 后自动校验 SHA256
- 在校验失败时**拒绝安装**并提示用户重新下载

### 9.2 最小权限原则

- 默认所有安装在用户目录 (`$HOME` / `%USERPROFILE%`)
- 仅在安装 Xcode CLT (macOS) 或 Git for Windows 时需要管理员权限
- 需要提权时明确告知用户原因，不自动执行

### 9.3 HTTPS 强制

所有下载必须通过 HTTPS，不信任 HTTP 源。

---

## 10. 未来扩展预留

### 10.1 Docker 支持

后续可提供 `Dockerfile` 预装所有组件，用户通过：

```bash
docker run -it --rm ghcr.io/ddddavi4/claude-code:latest claude
```

一键使用，无需安装任何系统依赖。

### 10.2 国内 CDN 加速

bundle 托管可接入：
- 腾讯云 CDN
- 阿里云 CDN
- 七牛云 CDN

脚本支持 `--mirror` 参数指定加速源。

### 10.3 离线完整模式

后续支持 `--offline` 模式，允许用户提前下载 bundle，在完全无网环境下安装。

---

## 11. 已确认事项

| # | 事项 | 结论 |
|---|------|------|
| 1 | CCSwitch GitHub 仓库 | `farion1231/cc-switch`（公开仓库） |
| 2 | CCSwitch 安装方式 | Tauri 2 桌面 GUI 应用，通过 GitHub Releases 分发 |
| 3 | 国内对象存储 | 腾讯云 COS |
| 4 | 仓库命名 | `claude-code-installer-helper` |
| 5 | `@anthropic-ai/claude-code` 最低 Node 版本 | 从 `npm view engines.node` 动态获取 |
| 6 | Bundle 版本策略 | 严格跟随 CC 版本号，CI 自动触发 |

---

## 12. 成功标准

- [ ] macOS 用户从零开始，3 步内完成安装（下载脚本 + 执行 + 登录）
- [ ] Windows 用户从零开始，5 步内完成安装（下载脚本 + 设置执行策略 + 执行 + 安装 Git + 登录）
- [ ] 中国大陆用户无需手动配置镜像，自动测速选择最优源
- [ ] bundle 模式在完全离线环境下可完成安装
- [ ] 安装失败时提供中文错误原因和修复建议
- [ ] 卸载后不残留影响系统的配置

---

*SPEC v1.1 — 所有待定项已确认，可进入实现阶段。*
