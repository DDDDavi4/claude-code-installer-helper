# Claude Code CLI 一键安装脚本

[![GitHub release](https://img.shields.io/github/v/release/DDDDavi4/claude-code-installer-helper)](https://github.com/DDDDavi4/claude-code-installer-helper/releases)

为中文用户设计的 **Claude Code CLI** 一键安装工具。自动处理 Node.js、Git 等前置依赖，自动检测网络环境切换国内镜像，集成 [CCSwitch](https://github.com/farion1231/cc-switch) 接入 DeepSeek V4。

## 快速开始

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/DDDDavi4/claude-code-installer-helper/main/install.sh | bash
```

### Windows (PowerShell)

```powershell
# 首次运行需要设置执行策略（仅需一次）
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 下载并运行安装脚本
iwr -Uri "https://raw.githubusercontent.com/DDDDavi4/claude-code-installer-helper/main/install.ps1" -OutFile install.ps1
.\install.ps1
```

## 功能特性

- **环境检测** — 自动识别 OS、架构、磁盘空间、权限状态
- **Node.js 自动安装** — 通过 nvm (macOS) / nvm-windows (Windows) 管理版本
- **Git 自动安装** — Windows 提示安装，macOS 引导安装 Xcode CLT
- **网络智能选源** — 自动测速 npmmirror / npm 官方源，选择最快的
- **GitHub 加速** — 自动检测 ghproxy 可用性，加速 Release 下载
- **CCSwitch 集成** — 自动下载安装，打印 DeepSeek V4 配置指南
- **常见问题排查** — 代理干扰、npm 权限、路径问题、DNS 故障等
- **彩色中文输出** — 每一步都有清晰的中文提示和进度反馈

## 命令行选项

```bash
# 在线安装（默认）
bash install.sh

# 预览模式 — 仅检测环境，不实际安装
bash install.sh --dry-run

# 离线 Bundle 模式
bash install.sh --use-bundle

# 指定本地 Bundle 文件
bash install.sh --use-bundle ./cc-offline-1.0.0-darwin.tar.gz

# 卸载
bash install.sh --uninstall
```

Windows 使用 `-DryRun` / `-Uninstall` / `-UseBundle` 参数。

## 安装流程

```
阶段0: 环境检测 (OS, 架构, 磁盘空间, 权限, 代理)
  ↓
阶段2: 网络测速 (npm 官方 vs npmmirror, GitHub 直连 vs ghproxy)
  ↓
阶段1a: Node.js 安装 (通过 nvm/nvm-windows 安装 LTS)
  ↓
阶段1b: Git 检测与安装
  ↓
阶段3: Claude Code CLI 安装 (npm install -g)
  ↓
阶段4: CCSwitch 安装 (下载桌面应用 + 打印配置指南)
  ↓
阶段5: 验证安装 → 输出安装报告
```

## 安装 CCSwitch 后的 DeepSeek V4 配置

脚本安装 CCSwitch（桌面应用）后，按以下步骤配置：

1. **获取 DeepSeek API Key** — [阿里云百炼](https://bailian.console.aliyun.com) / [硅基流动](https://siliconflow.cn) / [DeepSeek 官方](https://platform.deepseek.com)
2. **打开 CC Switch** — 从系统托盘图标进入
3. **添加供应商** → 选择 DeepSeek → 填入 API Key
4. **配置模型映射** (本地路由模式):
   - Haiku → `deepseek-v4-pro`
   - Sonnet → `deepseek-v4-pro`
   - Opus → `deepseek-v4-pro`
   - 不要带 `[1m]` 后缀

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| 下载慢 / 连接超时 | 脚本会自动切换 npmmirror + ghproxy |
| npm 权限错误 (EACCES) | 脚本自动配置 `~/.npm-global` 目录 |
| macOS "无法验证开发者" | 系统设置 → 隐私与安全性 → 仍要打开 |
| 代理干扰 | `unset HTTP_PROXY HTTPS_PROXY` 或关闭代理软件 |
| claude 命令找不到 | 重新打开终端，确保 `~/.npm-global/bin` 在 PATH 中 |
| Windows 中文用户名 | 脚本自动使用短路径名 fallback |
| PowerShell 禁止执行脚本 | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |

## 日志

所有安装操作日志保存在：
- macOS/Linux: `~/.claude/install-*.log`
- Windows: `%USERPROFILE%\.claude\install-*.log`

## 卸载

```bash
bash install.sh --uninstall   # macOS/Linux
.\install.ps1 -Uninstall      # Windows
```

## 离线安装 (Bundle)

CI 自动构建全家桶 bundle，包含全部依赖：

```
cc-offline-{version}-{platform}.zip
├── node-runtime/      # Node.js 二进制
├── git/               # Git 安装器 (Windows)
├── npm-packages/      # CC CLI 离线包
├── ccswitch/          # CCSwitch 安装器
├── setup.sh / setup.ps1
└── manifest.json
```

下载地址：[GitHub Releases](https://github.com/DDDDavi4/claude-code-installer-helper/releases)

## 开发

```bash
# 本地测试
bash install.sh --dry-run

# 构建 bundle (CI 自动执行)
.github/workflows/build-bundle.yml
```

## 相关项目

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — Anthropic 官方 CLI
- [CCSwitch](https://github.com/farion1231/cc-switch) — 模型切换桌面工具

## License

MIT
