# =============================================================================
# Claude Code CLI 一键安装脚本 (Windows / PowerShell)
# 仓库: https://github.com/DDDDavi4/claude-code-installer-helper
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$UseBundle,
    [string]$BundlePath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# --- 常量 ----------------------------------------------------------------
$Script:SCRIPT_VERSION = "1.0.0"
$Script:CC_NPM_PACKAGE = "@anthropic-ai/claude-code"
$Script:CCSWITCH_REPO = "farion1231/cc-switch"
$Script:NODE_MIN_MAJOR = 18
$Script:DISK_SPACE_MIN_MB = 2048

$Script:NPM_REGISTRY_OFFICIAL = "https://registry.npmjs.org/"
$Script:NPM_REGISTRY_MIRROR   = "https://registry.npmmirror.com/"
$Script:GITHUB_API            = "https://api.github.com"

$Script:LOG_DIR = Join-Path $env:USERPROFILE ".claude"
$Script:LOG_FILE = Join-Path $Script:LOG_DIR "install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$Script:INSTALL_MARKER = Join-Path $Script:LOG_DIR ".install-done"

# 全局状态
$Script:NPM_REGISTRY = $Script:NPM_REGISTRY_OFFICIAL
$Script:SELECTED_GITHUB_DL_BASE = "https://github.com"
$Script:INSTALLED_NODE = $false
$Script:INSTALLED_GIT = $false
$Script:INSTALLED_CC = $false
$Script:INSTALLED_CCSWITCH = $false

# --- 工具函数 ------------------------------------------------------------

function Write-Color {
    param([string]$Color, [string]$Text)
    Write-Host $Text -ForegroundColor $Color
}

function Write-Info    { Write-Color Cyan    "[INFO] $args" }
function Write-Success { Write-Color Green   "[OK]   $args" }
function Write-WarningMsg { Write-Color Yellow  "[WARN] $args" }
function Write-ErrorMsg   { Write-Color Red     "[ERROR] $args" }

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Die {
    param([string]$Text)
    Write-ErrorMsg $Text
    Write-ErrorMsg "安装失败。详细日志: $Script:LOG_FILE"
    exit 1
}

function Check-Command {
    param([string]$Cmd)
    Get-Command $Cmd -ErrorAction SilentlyContinue | Out-Null
    return $?
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ShortPath {
    param([string]$Path)
    # 如果路径包含空格或非ASCII字符，尝试获取8.3短路径名
    if ($Path -match '[\s一-鿿]') {
        try {
            $fso = New-Object -ComObject Scripting.FileSystemObject
            $folder = $fso.GetFolder($Path)
            return $folder.ShortPath
        } catch {
            return $Path
        }
    }
    return $Path
}

# --- 日志 ----------------------------------------------------------------

function Initialize-Log {
    if (-not (Test-Path $Script:LOG_DIR)) {
        New-Item -ItemType Directory -Path $Script:LOG_DIR -Force | Out-Null
    }
    Start-Transcript -Path $Script:LOG_FILE -Append | Out-Null
}

# --- 环境检测 ------------------------------------------------------------

function Test-System {
    Write-Step "阶段0: 环境检测"

    $os = [Environment]::OSVersion
    $is64 = [Environment]::Is64BitOperatingSystem

    Write-Color Gray "  操作系统:     Windows $($os.VersionString)"
    Write-Color Gray "  架构:         $(if ($is64) { 'x64' } else { 'x86' })"
    Write-Color Gray "  PowerShell:   $($PSVersionTable.PSVersion)"
    Write-Color Gray "  用户目录:     $env:USERPROFILE"
    Write-Color Gray "  计算机名:     $env:COMPUTERNAME"

    # 32位系统警告
    if (-not $is64) {
        Write-WarningMsg "检测到 32 位系统。nvm-windows 推荐 64 位系统，部分功能可能不可用。"
    }

    # 中文/空格路径检测
    if ($env:USERPROFILE -match '[\s一-鿿]') {
        Write-WarningMsg "用户路径包含空格或中文字符: $env:USERPROFILE"
        Write-WarningMsg "脚本将使用短路径名来避免潜在问题。"
        $shortPath = Get-ShortPath $env:USERPROFILE
        if ($shortPath -ne $env:USERPROFILE) {
            Write-Info "短路径名: $shortPath"
        }
    }

    # 磁盘空间
    $drive = (Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($env:USERPROFILE).TrimEnd('\')) -ErrorAction SilentlyContinue)
    if ($drive) {
        $availMB = [math]::Round($drive.Free / 1MB)
        Write-Color Gray "  可用磁盘空间: ${availMB}MB"
        if ($availMB -lt $Script:DISK_SPACE_MIN_MB) {
            Write-WarningMsg "磁盘空间不足 2GB，安装可能失败。建议至少释放 $Script:DISK_SPACE_MIN_MB MB 空间。"
            $confirm = Read-Host "  是否继续? [y/N]"
            if ($confirm -notmatch '^[Yy]') {
                Die "用户取消安装"
            }
        }
    }

    # 写入权限
    try {
        $testFile = Join-Path $env:USERPROFILE ".claude-test-write.tmp"
        New-Item -ItemType File -Path $testFile -Force | Out-Null
        Remove-Item $testFile -Force
    } catch {
        Die "用户目录 $env:USERPROFILE 无写入权限，请检查权限后重试。"
    }

    # 代理检测
    $proxyVars = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')
    $hasProxy = $false
    foreach ($var in $proxyVars) {
        $val = [Environment]::GetEnvironmentVariable($var, 'User')
        if ($val) {
            if (-not $hasProxy) {
                Write-WarningMsg "检测到代理环境变量:"
                $hasProxy = $true
            }
            Write-Color Gray "    ${var}=${val}"
        }
    }
    if ($hasProxy) {
        Write-Color Gray "  如果网络连接失败，请先尝试关闭代理: `$env:HTTP_PROXY=''; `$env:HTTPS_PROXY=''"
    }
}

# --- 网络测速与镜像选择 ----------------------------------------------------

function Test-SingleSpeed {
    param([string]$Name, [string]$Url, [int]$TimeoutSec = 5)

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = "HEAD"
        $req.Timeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

function Select-Mirrors {
    Write-Step "阶段2: 网络测速与镜像选择"

    Write-Info "测速 npm registry..."

    if (Test-SingleSpeed "npm官方" $Script:NPM_REGISTRY_OFFICIAL) {
        $Script:NPM_REGISTRY = $Script:NPM_REGISTRY_OFFICIAL
        Write-Success "npm 官方源可达"
    } elseif (Test-SingleSpeed "npmmirror" $Script:NPM_REGISTRY_MIRROR) {
        $Script:NPM_REGISTRY = $Script:NPM_REGISTRY_MIRROR
        Write-Success "npmmirror 镜像源可达（已切换到国内镜像）"
    } else {
        Write-WarningMsg "所有 npm 源均不可达。将使用默认源，安装可能失败。"
    }

    Write-Info "测速 GitHub..."

    if (Test-SingleSpeed "GitHub直连" "https://github.com") {
        $Script:SELECTED_GITHUB_DL_BASE = "https://github.com"
        Write-Success "GitHub 直连可达"
    } elseif (Test-SingleSpeed "ghproxy" "https://ghproxy.com/") {
        $Script:SELECTED_GITHUB_DL_BASE = "https://ghproxy.com/https://github.com"
        Write-Success "ghproxy 镜像可达（GitHub 下载将走代理）"
    } else {
        Write-WarningMsg "GitHub 和 ghproxy 均不可达。GitHub Release 下载将尝试直连。"
        Write-WarningMsg "如失败，建议手动下载或检查 DNS/代理设置。"
    }
}

# --- 前置依赖安装 ---------------------------------------------------------

function Install-NvmAndNode {
    Write-Step "阶段1a: 安装 Node.js (通过 nvm-windows)"

    # 检查是否已有符合要求的 Node
    $nodeInstalled = $false
    try {
        $nodeVer = (node --version 2>$null) -replace 'v', ''
        if ($nodeVer) {
            $nodeMajor = [int]($nodeVer.Split('.')[0])
            if ($nodeMajor -ge $Script:NODE_MIN_MAJOR) {
                Write-Success "Node.js v${nodeVer} 已满足最低要求 (>= $Script:NODE_MIN_MAJOR.x)"
                return
            } else {
                Write-WarningMsg "当前 Node.js v${nodeVer} 版本过低，需要 >= $Script:NODE_MIN_MAJOR.x"
            }
        }
    } catch {
        Write-Info "未检测到 Node.js"
    }

    # 检测 nvm-windows
    $nvmPath = Join-Path $env:LOCALAPPDATA "nvm"
    $nvmExe = Join-Path $nvmPath "nvm.exe"
    $NVM_HOME = [Environment]::GetEnvironmentVariable("NVM_HOME", "User")

    if (-not (Check-Command "nvm") -and -not (Test-Path $nvmExe)) {
        Write-Info "正在安装 nvm-windows..."

        $nvmInstallerUrl = "https://github.com/coreybutler/nvm-windows/releases/latest/download/nvm-setup.exe"
        if ($Script:SELECTED_GITHUB_DL_BASE -match 'ghproxy') {
            $nvmInstallerUrl = "https://ghproxy.com/$nvmInstallerUrl"
        }

        $tmpDir = Join-Path $env:TEMP "cc-installer"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $installerPath = Join-Path $tmpDir "nvm-setup.exe"

        try {
            Write-Info "正在下载 nvm-windows..."
            Invoke-WebRequest -Uri $nvmInstallerUrl -OutFile $installerPath -UseBasicParsing

            Write-Info "正在安装 nvm-windows（静默模式）..."
            Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT /NORESTART" -Wait -NoNewWindow

            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Success "nvm-windows 安装完成"
        } catch {
            Write-ErrorMsg "nvm-windows 下载失败: $_"
            Die "请检查网络连接或手动下载: https://github.com/coreybutler/nvm-windows/releases"
        }
    } else {
        Write-Info "nvm-windows 已存在"
    }

    # 刷新 PATH（nvm-windows 安装后可能需要）
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [System.Environment]::GetEnvironmentVariable("Path", "User")

    # 使用 nvm 安装 Node LTS
    Write-Info "正在安装 Node.js LTS..."
    try {
        nvm install lts 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "nvm install 失败" }

        nvm use lts 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "nvm use 失败" }
    } catch {
        Die "Node.js LTS 安装失败。请尝试: nvm install lts 查看详细错误"
    }

    $Script:INSTALLED_NODE = $true

    # 验证
    node --version 2>&1 | Out-Host
    Write-Success "Node.js 安装完成: $(node --version)"
}

function Install-Git {
    Write-Step "阶段1b: 检测 Git"

    if (Check-Command "git") {
        Write-Success "Git 已安装: $(git --version)"
        return
    }

    Write-WarningMsg "未检测到 Git。Git 是 Claude Code 的必要依赖。"
    $confirm = Read-Host "  是否自动下载并安装 Git for Windows? [Y/n]"

    if ($confirm -match '^[Nn]') {
        Write-WarningMsg "已跳过 Git 安装。请手动从 https://git-scm.com/download/win 下载安装。"
        return
    }

    Write-Info "正在下载 Git for Windows..."
    $gitUrl = "https://github.com/git-for-windows/git/releases/latest/download/Git-2.47.1-64-bit.exe"
    if ($Script:SELECTED_GITHUB_DL_BASE -match 'ghproxy') {
        $gitUrl = "https://ghproxy.com/$gitUrl"
    }

    $tmpDir = Join-Path $env:TEMP "cc-installer"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $gitInstaller = Join-Path $tmpDir "Git-installer.exe"

    try {
        Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing
        Write-Info "正在安装 Git（静默模式）..."
        Start-Process -FilePath $gitInstaller -ArgumentList "/VERYSILENT /NORESTART /COMPONENTS=icons,ext,ext\reg,assoc,assoc_sh" -Wait -NoNewWindow
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

        # 刷新 PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                    [System.Environment]::GetEnvironmentVariable("Path", "User")

        if (Check-Command "git") {
            $Script:INSTALLED_GIT = $true
            Write-Success "Git 安装完成: $(git --version)"
        } else {
            Write-WarningMsg "Git 安装完成但命令未找到。请重新打开终端后重试。"
        }
    } catch {
        Write-ErrorMsg "Git 下载失败: $_"
        Write-WarningMsg "请手动从 https://git-scm.com/download/win 下载安装。"
    }
}

# --- Claude Code CLI 安装 -------------------------------------------------

function Install-ClaudeCode {
    Write-Step "阶段3: 安装 Claude Code CLI"

    # 设置 npm registry
    if ($Script:NPM_REGISTRY -ne $Script:NPM_REGISTRY_OFFICIAL) {
        npm config set registry $Script:NPM_REGISTRY 2>&1 | Out-Null
        Write-Info "npm registry 已设置为: $Script:NPM_REGISTRY"
    }

    # 确保 npm 全局 bin 目录在 PATH 中
    $npmPrefix = (npm config get prefix 2>&1)
    $npmBin = Join-Path $npmPrefix ""
    if ($npmPrefix -match ' roaming') {
        $npmBin = Join-Path $env:APPDATA "npm"
    }

    # 检查 %APPDATA%\npm 是否在 PATH
    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $appDataNpm = Join-Path $env:APPDATA "npm"

    if ($currentUserPath -notmatch [regex]::Escape($appDataNpm)) {
        Write-Info "添加 %APPDATA%\npm 到用户 PATH..."
        [Environment]::SetEnvironmentVariable("Path", "$currentUserPath;$appDataNpm", "User")
        $env:Path = "$env:Path;$appDataNpm"
    }

    # 安装
    Write-Info "正在安装 $Script:CC_NPM_PACKAGE..."
    try {
        $output = npm install -g $Script:CC_NPM_PACKAGE 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw $output
        }
        $Script:INSTALLED_CC = $true
        Write-Success "Claude Code CLI 安装完成"
        claude --version 2>&1 | Out-Host
    } catch {
        Die "Claude Code CLI 安装失败。请检查网络连接或尝试 -UseBundle 模式。"
    }
}

# --- CCSwitch 安装 --------------------------------------------------------

function Get-LatestCCSwitchVersion {
    $apiUrl = "https://api.github.com/repos/$Script:CCSWITCH_REPO/releases/latest"
    if ($Script:SELECTED_GITHUB_DL_BASE -match 'ghproxy') {
        $apiUrl = "https://ghproxy.com/$apiUrl"
    }

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 10
        return $release.tag_name -replace '^v', ''
    } catch {
        Write-WarningMsg "无法获取 CCSwitch 最新版本号，将使用 latest。"
        return "latest"
    }
}

function Install-CCSwitch {
    Write-Step "阶段4: 安装 CCSwitch"

    Write-Info "获取 CCSwitch 最新版本..."
    $version = Get-LatestCCSwitchVersion

    $dlBase = $Script:SELECTED_GITHUB_DL_BASE
    $msiFile = "CC-Switch-v${version}-Windows.msi"
    $dlUrl = if ($dlBase -match 'ghproxy') {
        "https://ghproxy.com/https://github.com/farion1231/cc-switch/releases/download/v${version}/${msiFile}"
    } else {
        "https://github.com/farion1231/cc-switch/releases/download/v${version}/${msiFile}"
    }

    Write-Info "正在下载 CCSwitch (MSI 安装包)..."
    $tmpDir = Join-Path $env:TEMP "cc-installer"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $msiPath = Join-Path $tmpDir $msiFile

    try {
        Invoke-WebRequest -Uri $dlUrl -OutFile $msiPath -UseBasicParsing

        Write-Info "正在安装 CCSwitch..."

        # 检查是否需要管理员权限
        if (Test-Admin) {
            Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait -NoNewWindow
        } else {
            Write-WarningMsg "CCSwitch 安装需要管理员权限，将弹出 UAC 提示。"
            Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Verb RunAs -Wait
        }

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        $Script:INSTALLED_CCSWITCH = $true
        Write-Success "CCSwitch 安装完成"
    } catch {
        Write-ErrorMsg "CCSwitch 下载/安装失败: $_"
        # 尝试便携版
        try {
            $portableFile = "CC-Switch-v${version}-Windows-Portable.zip"
            $portableUrl = if ($dlBase -match 'ghproxy') {
                "https://ghproxy.com/https://github.com/farion1231/cc-switch/releases/download/v${version}/${portableFile}"
            } else {
                "https://github.com/farion1231/cc-switch/releases/download/v${version}/${portableFile}"
            }

            Write-Info "尝试下载便携版..."
            $portablePath = Join-Path $tmpDir $portableFile
            Invoke-WebRequest -Uri $portableUrl -OutFile $portablePath -UseBasicParsing

            $extractDir = Join-Path $env:LOCALAPPDATA "CC-Switch"
            Expand-Archive -Path $portablePath -DestinationPath $extractDir -Force
            $Script:INSTALLED_CCSWITCH = $true
            $Script:CCSWITCH_PORTABLE = $true

            Write-Success "CCSwitch 便携版已解压到: $extractDir"
            Write-Info "请手动运行 ${extractDir}\CC-Switch.exe"
        } catch {
            Write-WarningMsg "CCSwitch 下载失败。请手动从以下地址下载安装："
            Write-Color Gray "  https://github.com/farion1231/cc-switch/releases"
        }
    }

    Show-CCSwitchGuide
}

function Show-CCSwitchGuide {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "       CC Switch — 配置 DeepSeek V4 接入 Claude Code       " -ForegroundColor Green -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║                                                          ║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "  1. 获取 DeepSeek API Key                                " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     - 阿里云百炼: https://bailian.console.aliyun.com     " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     - 硅基流动:   https://siliconflow.cn                  " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     - DeepSeek 官方: https://platform.deepseek.com       " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║                                                          ║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "  2. 从开始菜单启动 CC Switch（系统托盘图标）               " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     → 点击「供应商」→「添加供应商」                        " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     → 选择 DeepSeek → 填入 API Key                       " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║                                                          ║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "  3. 配置模型映射（本地路由模式）                            " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     → Haiku  → deepseek-v4-pro                           " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     → Sonnet → deepseek-v4-pro                           " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     → Opus   → deepseek-v4-pro                           " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     ⚠ 本地路由模式下不要带 [1m] 后缀                      " -ForegroundColor Yellow -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║                                                          ║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "  4. 切换到 DeepSeek                                      " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "     → CC Switch → 选择 DeepSeek → 点击「应用」             " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║                                                          ║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "  5. 验证: 运行 claude 观察模型名                           " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║                                                          ║" -ForegroundColor Cyan
    Write-Host "║" -ForegroundColor Cyan -NoNewline
    Write-Host "  详细文档: https://github.com/farion1231/cc-switch        " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# --- 验证 ----------------------------------------------------------------

function Test-Installation {
    Write-Step "阶段5: 验证安装"

    $allOk = $true

    Write-Host ""
    Write-Color Cyan "  Node.js:"
    try {
        $nv = node --version 2>$null
        Write-Color Gray "    $nv"
    } catch {
        Write-Color Red "    未安装"
        $allOk = $false
    }

    Write-Color Cyan "  npm:"
    try {
        $npmv = npm --version 2>$null
        $reg = npm config get registry 2>$null
        Write-Color Gray "    v${npmv}  (registry: ${reg})"
    } catch {
        Write-Color Red "    未安装"
        $allOk = $false
    }

    Write-Color Cyan "  Git:"
    try {
        $gv = git --version 2>$null
        Write-Color Gray "    $gv"
    } catch {
        Write-Color Yellow "    未安装"
    }

    Write-Color Cyan "  Claude Code CLI:"
    try {
        $cv = claude --version 2>$null
        Write-Color Gray "    $cv"
    } catch {
        $npmBin = Join-Path $env:APPDATA "npm"
        $claudeExe = Join-Path $npmBin "claude.cmd"
        if (Test-Path $claudeExe) {
            Write-Color Yellow "    请重新打开终端后运行 claude"
        } else {
            Write-Color Red "    未安装"
            $allOk = $false
        }
    }

    Write-Host ""

    if ($allOk) {
        New-Item -ItemType File -Path $Script:INSTALL_MARKER -Force | Out-Null

        Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║     " -ForegroundColor Cyan -NoNewline
        Write-Host "Claude Code CLI 安装成功!" -ForegroundColor Green -NoNewline
        Write-Host "                  ║" -ForegroundColor Cyan
        Write-Host "╠════════════════════════════════════════════════╣" -ForegroundColor Cyan
        try { Write-Host "║  Node.js:  $(node --version)                              ║" -ForegroundColor Cyan } catch {}
        try { Write-Host "║  Git:      $(git --version)                                ║" -ForegroundColor Cyan } catch {}

        if ($Script:INSTALLED_CCSWITCH) {
            Write-Host "║  Backend:  DeepSeek V4 (via CCSwitch)          ║" -ForegroundColor Cyan
        }
        Write-Host "╠════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "║  运行 " -ForegroundColor Cyan -NoNewline
        Write-Host "claude" -ForegroundColor Yellow -NoNewline
        Write-Host " 开始使用                           ║" -ForegroundColor Cyan
        Write-Host "║  运行 " -ForegroundColor Cyan -NoNewline
        Write-Host "cclogin" -ForegroundColor Yellow -NoNewline
        Write-Host " 进行认证                          ║" -ForegroundColor Cyan
        Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Cyan
    } else {
        Write-WarningMsg "部分组件未正确安装。请查看日志: $Script:LOG_FILE"
    }
}

# --- 卸载 ----------------------------------------------------------------

function Invoke-Uninstall {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Claude Code CLI 卸载工具" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""

    # 1. Claude Code CLI
    if (Check-Command "claude") {
        Write-Info "卸载 Claude Code CLI..."
        npm uninstall -g $Script:CC_NPM_PACKAGE 2>&1 | Out-Null
        Write-Success "Claude Code CLI 已卸载"
    }

    # 2. CCSwitch
    $ccswitchPath = Join-Path $env:LOCALAPPDATA "Programs" "CC-Switch"
    $ccswitchPortable = Join-Path $env:LOCALAPPDATA "CC-Switch"
    if (Test-Path $ccswitchPath) {
        Write-Color Gray "  CCSwitch 位于: $ccswitchPath"
    }
    if (Test-Path $ccswitchPortable) {
        Write-Color Gray "  CCSwitch 便携版位于: $ccswitchPortable"
    }
    Write-WarningMsg "CCSwitch 是桌面应用，请通过 Windows「添加/删除程序」手动卸载。"

    # 3. nvm & Node.js
    Write-Host ""
    Write-WarningMsg "nvm-windows 和 Node.js 可能被其他项目使用，默认不卸载。"
    $confirm = Read-Host "  是否同时卸载 nvm-windows 和 Node.js? [y/N]"
    if ($confirm -match '^[Yy]') {
        $nvmPath = [Environment]::GetEnvironmentVariable("NVM_HOME", "User")
        if ($nvmPath -and (Test-Path $nvmPath)) {
            nvm unload 2>$null
            Remove-Item $nvmPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "nvm-windows 目录已删除: $nvmPath"
        }
        Write-Color Yellow "  请通过 Windows「添加/删除程序」手动卸载 Node.js。"
    }

    # 4. 恢复 npm registry
    try {
        npm config delete registry 2>&1 | Out-Null
    } catch {}

    # 5. ~/.claude 目录
    if (Test-Path $Script:LOG_DIR) {
        $confirm = Read-Host "  是否删除 .claude 配置目录（含登录态）? [y/N]"
        if ($confirm -match '^[Yy]') {
            Remove-Item $Script:LOG_DIR -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "~/.claude 目录已删除"
        }
    }

    Remove-Item $Script:INSTALL_MARKER -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Success "卸载完成。"
}

# --- dry-run 模式 ---------------------------------------------------------

function Invoke-DryRun {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Dry-Run 模式 — 仅预览，不实际安装" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  系统信息:" -ForegroundColor White
    Write-Color Gray "    操作系统:       Windows $([Environment]::OSVersion.VersionString)"
    Write-Color Gray "    架构:           $(if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })"
    Write-Color Gray "    PowerShell:     $($PSVersionTable.PSVersion)"
    Write-Color Gray "    用户目录:       $env:USERPROFILE"
    Write-Color Gray "    管理员权限:     $(if (Test-Admin) { '是' } else { '否' })"

    $drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($env:USERPROFILE).TrimEnd('\')) -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Color Gray "    可用磁盘空间:   $([math]::Round($drive.Free / 1MB))MB"
    }

    Write-Host ""
    Write-Host "  已安装状态:" -ForegroundColor White
    try { Write-Color Gray "    Node.js:       $(node --version)" } catch { Write-Color Red "    Node.js:       未安装" }
    try { Write-Color Gray "    npm:           $(npm --version)" } catch { Write-Color Red "    npm:           未安装" }
    try { Write-Color Gray "    Git:           $(git --version)" } catch { Write-Color Yellow "    Git:           未安装" }
    try { Write-Color Gray "    Claude Code:   $(claude --version 2>$null)" } catch { Write-Color Red "    Claude Code:   未安装" }

    Write-Host ""
    Write-Host "  将要安装:" -ForegroundColor White
    $nodeInstalled = try { $v = node --version 2>$null; [int]($v -replace 'v','').Split('.')[0] -ge $Script:NODE_MIN_MAJOR } catch { $false }
    if ($nodeInstalled) { Write-Color Gray "    Node.js:       已满足要求，跳过" } else { Write-Color Gray "    Node.js LTS:   通过 nvm-windows 安装 (约 100MB)" }
    if (Check-Command "git") { Write-Color Gray "    Git:           已满足要求，跳过" } else { Write-Color Gray "    Git:           需要安装 Git for Windows (约 50MB)" }
    if (Check-Command "claude") { Write-Color Gray "    Claude Code:   已安装，将升级到最新版" } else { Write-Color Gray "    Claude Code:   通过 npm 安装 (约 200MB)" }
    Write-Color Gray "    CCSwitch:      从 GitHub Releases 下载 MSI 安装包"
    Write-Color Gray "    总计预计占用:  约 500MB - 1GB"
    Write-Host ""

    if (-not (Test-Admin)) {
        Write-Color Yellow "  ⚠ 提示: 部分安装步骤可能需要管理员权限（如安装 MSI 包），将弹出 UAC 窗口。"
    }
    if ($env:USERPROFILE -match '[\s一-鿿]') {
        Write-Color Yellow "  ⚠ 警告: 用户名包含空格或中文，可能导致部分工具路径异常。"
    }
}

# --- Bundle 模式 ----------------------------------------------------------

function Invoke-BundleInstall {
    $bundleFile = if ($BundlePath) { $BundlePath } else { $null }

    if (-not $bundleFile) {
        $bundleName = "cc-offline-latest-windows-x64.zip"
        $ghUrl = "https://github.com/DDDDavi4/claude-code-installer-helper/releases/latest/download/${bundleName}"

        if ($Script:SELECTED_GITHUB_DL_BASE -match 'ghproxy') {
            $ghUrl = "https://ghproxy.com/$ghUrl"
        }

        $tmpDir = Join-Path $env:TEMP "cc-installer"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $bundleFile = Join-Path $tmpDir $bundleName

        Write-Info "正在下载 bundle..."

        try {
            Invoke-WebRequest -Uri $ghUrl -OutFile $bundleFile -UseBasicParsing -TimeoutSec 120
            Write-Success "Bundle 下载成功"
        } catch {
            Die "Bundle 下载失败。请检查网络连接或使用在线安装模式。"
        }
    }

    # 解压
    $extractDir = Join-Path $env:TEMP "cc-bundle-extract"
    Write-Info "正在解压 bundle..."
    Expand-Archive -Path $bundleFile -DestinationPath $extractDir -Force

    # 执行离线 setup
    $setupScript = Join-Path $extractDir "setup.ps1"
    $setupScript2 = Join-Path $extractDir "install.ps1"

    if (Test-Path $setupScript) {
        & $setupScript
    } elseif (Test-Path $setupScript2) {
        & $setupScript2
    } else {
        Die "Bundle 中未找到 setup.ps1，bundle 可能已损坏。"
    }
}

# --- 帮助信息 ------------------------------------------------------------

function Show-Help {
    Write-Host "Claude Code CLI 一键安装脚本 v$Script:SCRIPT_VERSION"
    Write-Host ""
    Write-Host "用法: .\install.ps1 [选项]"
    Write-Host ""
    Write-Host "选项:"
    Write-Host "  -DryRun         模拟运行，只显示检测结果和安装计划"
    Write-Host "  -Uninstall      卸载所有已安装的组件"
    Write-Host "  -UseBundle [路径] 使用离线 bundle 安装 (可选指定本地文件)"
    Write-Host "  -Help           显示此帮助信息"
    Write-Host ""
    Write-Host "示例:"
    Write-Host "  .\install.ps1                    # 在线安装"
    Write-Host "  .\install.ps1 -DryRun            # 预览安装计划"
    Write-Host "  .\install.ps1 -UseBundle         # 使用 bundle 模式"
    Write-Host "  .\install.ps1 -Uninstall         # 卸载"
    Write-Host ""
    Write-Host "首次运行 PowerShell 脚本需要设置执行策略:"
    Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

# --- 故障排查提示 ---------------------------------------------------------

function Show-Troubleshooting {
    Write-Host ""
    Write-Host "════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  常见问题排查" -ForegroundColor Yellow
    Write-Host "════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  无法运行 .ps1 脚本 (ExecutionPolicy):" -ForegroundColor Cyan
    Write-Color Gray "    以管理员身份运行 PowerShell:"
    Write-Color Gray "    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    Write-Host ""
    Write-Host "  npm 权限/路径错误:" -ForegroundColor Cyan
    Write-Color Gray "    npm 全局模块路径应自动添加到 %APPDATA%\npm"
    Write-Color Gray "    如找不到 claude 命令，请重新打开终端。"
    Write-Host ""
    Write-Host "  代理/网络问题:" -ForegroundColor Cyan
    Write-Color Gray "    关闭代理: `$env:HTTP_PROXY=''; `$env:HTTPS_PROXY=''"
    Write-Color Gray "    或通过 Windows 设置 → 网络和 Internet → 代理 → 关闭"
    Write-Host ""
    Write-Host "  中文用户名路径问题:" -ForegroundColor Cyan
    Write-Color Gray "    如出现路径乱码或找不到命令，尝试使用不含中文的用户名。"
    Write-Color Gray "    或设置环境变量 NPM_CONFIG_CACHE 到纯英文路径。"
    Write-Host ""
    Write-Host "  CCSwitch 无法安装:" -ForegroundColor Cyan
    Write-Color Gray "    尝试从 https://github.com/farion1231/cc-switch/releases"
    Write-Color Gray "    下载便携版 (Portable.zip) 直接解压运行。"
    Write-Host ""
    Write-Host "  更多帮助:" -ForegroundColor Cyan
    Write-Color Gray "    https://github.com/DDDDavi4/claude-code-installer-helper/issues"
    Write-Host ""
}

# --- 主流程 ----------------------------------------------------------------

function Main {
    # 帮助
    if ($args -contains '-Help' -or $args -contains '--help' -or $args -contains '-h') {
        Show-Help
        return
    }

    # dry-run 不需要日志
    if ($DryRun) {
        Invoke-DryRun
        return
    }

    # 卸载不需要初始化日志
    if ($Uninstall) {
        Invoke-Uninstall
        return
    }

    # 检查 PowerShell 执行策略（仅在非 dry-run 时提醒）
    if (-not $DryRun) {
        $execPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
        if ($execPolicy -eq 'Restricted' -or $execPolicy -eq 'Undefined') {
            Write-WarningMsg "当前 PowerShell 执行策略为 $execPolicy，脚本可能无法运行。"
            Write-Color Gray "  请先执行: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
            Write-Color Gray "  然后重新运行此脚本。"
            $confirm = Read-Host "  是否现在设置? [Y/n]"
            if ($confirm -notmatch '^[Nn]') {
                try {
                    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
                    Write-Success "执行策略已设置为 RemoteSigned (仅当前用户)"
                } catch {
                    Write-ErrorMsg "设置执行策略失败，请以管理员身份运行此脚本或手动设置。"
                    exit 1
                }
            }
        }
    }

    # 初始化日志
    Initialize-Log

    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  " -ForegroundColor Cyan -NoNewline
    Write-Host "Claude Code CLI 一键安装脚本" -ForegroundColor White -NoNewline
    Write-Host "        ║" -ForegroundColor Cyan
    Write-Host "║  " -ForegroundColor Cyan -NoNewline
    Write-Host "v$Script:SCRIPT_VERSION" -ForegroundColor Gray -NoNewline
    Write-Host "                              ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "日志文件: $Script:LOG_FILE"
    Write-Host ""

    # Bundle 模式
    if ($UseBundle) {
        Invoke-BundleInstall
        Test-Installation
        Show-Troubleshooting
        return
    }

    # --- 标准在线安装流程 ---
    try {
        Test-System                       # 阶段0
        Select-Mirrors                    # 阶段2
        Install-NvmAndNode                # 阶段1a
        Install-Git                       # 阶段1b
        Install-ClaudeCode                # 阶段3
        Install-CCSwitch                  # 阶段4
        Test-Installation                 # 阶段5
        Show-Troubleshooting
        Write-Info "完整日志已保存至: $Script:LOG_FILE"
    } catch {
        Write-ErrorMsg "安装过程中发生未预期的错误: $_"
        Write-ErrorMsg "请查看日志: $Script:LOG_FILE"
        exit 1
    } finally {
        Stop-Transcript 2>$null | Out-Null
    }
}

Main
