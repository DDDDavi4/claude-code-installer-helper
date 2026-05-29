#!/usr/bin/env bash
# =============================================================================
# Claude Code CLI 一键安装脚本 (macOS / Linux)
# 仓库: https://github.com/DDDDavi4/claude-code-installer-helper
# =============================================================================
set -euo pipefail

# --- 常量 ----------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly CC_NPM_PACKAGE="@anthropic-ai/claude-code"
readonly CC_VERSION="2.1.153"
readonly CCSWITCH_REPO="farion1231/cc-switch"
readonly NVM_VERSION="0.40.1"
readonly NODE_MIN_MAJOR=18
readonly DISK_SPACE_MIN_MB=2048

# URL 模板
readonly NPM_REGISTRY_OFFICIAL="https://registry.npmjs.org/"
readonly NPM_REGISTRY_MIRROR="https://registry.npmmirror.com/"
readonly GITHUB_API="https://api.github.com"
readonly GITHUB_PROXY="https://ghproxy.com/"
readonly GITHUB_RAW="https://raw.githubusercontent.com"

# 日志文件
readonly LOG_DIR="${HOME}/.claude"
readonly LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly INSTALL_MARKER="${LOG_DIR}/.install-done"

# 颜色
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# --- 全局状态 ------------------------------------------------------------
NPM_REGISTRY="$NPM_REGISTRY_OFFICIAL"
USE_BUNDLE=false
BUNDLE_PATH=""
DRY_RUN=false
UNINSTALL_MODE=false
INSTALLED_NODE=false
INSTALLED_GIT=false
INSTALLED_CC=false
INSTALLED_CCSWITCH=false
SELECTED_GITHUB_DL_BASE="https://github.com"

# --- 工具函数 ------------------------------------------------------------

log_init() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

color() {
    local c="$1"; shift
    printf "%b%s%b" "$c" "$*" "$COLOR_RESET"
}

info()    { echo -e "$(color "$COLOR_BLUE" '[INFO]')" "$@"; }
success() { echo -e "$(color "$COLOR_GREEN" '[OK]')" "$@"; }
warn()    { echo -e "$(color "$COLOR_YELLOW" '[WARN]')" "$@"; }
error()   { echo -e "$(color "$COLOR_RED" '[ERROR]')" "$@"; }
step()    { echo -e "\n$(color "$COLOR_CYAN" '==>') $(color "$COLOR_BOLD" "$@")"; }

die() {
    error "$@"
    error "安装失败。详细日志: ${LOG_FILE}"
    exit 1
}

check_cmd() { command -v "$1" &>/dev/null; }

os_name() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

os_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x64" ;;
        aarch64) echo "arm64" ;;
        arm64)   echo "arm64" ;;
        *)       echo "$arch" ;;
    esac
}

http_get_headers() {
    # 发 HTTP HEAD 请求，返回 HTTP 状态码
    local url="$1"
    local timeout="${2:-5}"
    if check_cmd curl; then
        curl -sI -m "$timeout" --max-time "$timeout" "$url" 2>/dev/null | head -1 | grep -oP '\d{3}' || echo "000"
    elif check_cmd wget; then
        wget --spider --timeout="$timeout" -S "$url" 2>&1 | grep -oP 'HTTP/\S+ \K\d{3}' | head -1 || echo "000"
    else
        echo "000"
    fi
}

# --- 环境检测 ------------------------------------------------------------

check_system() {
    step "阶段0: 环境检测"

    local os
    os=$(os_name)

    if [[ "$os" == "unknown" ]]; then
        die "不支持的操作系统: $(uname -s)。仅支持 macOS 和 Linux。"
    fi

    echo "  操作系统:     $(uname -s) ($(uname -r))"
    echo "  架构:         $(uname -m) ($(os_arch))"
    echo "  Shell:        ${SHELL:-unknown}"
    echo "  用户目录:     ${HOME}"
    echo "  主机名:       $(hostname)"

    # 磁盘空间
    local avail_kb
    avail_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
    local avail_mb=$((avail_kb / 1024))
    echo "  可用磁盘空间: ${avail_mb}MB"
    if [[ "$avail_mb" -lt "$DISK_SPACE_MIN_MB" ]]; then
        warn "磁盘空间不足 2GB，安装可能失败。建议至少释放 ${DISK_SPACE_MIN_MB}MB 空间。"
        read -rp "  是否继续? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || die "用户取消安装"
    fi

    # 写入权限
    if [[ ! -w "$HOME" ]]; then
        die "用户目录 ${HOME} 无写入权限，请检查权限后重试。"
    fi

    # 代理检测
    if [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${http_proxy:-}${https_proxy:-}${all_proxy:-}" ]]; then
        warn "检测到代理环境变量:"
        [[ -n "${HTTP_PROXY:-}" ]]  && echo "    HTTP_PROXY=${HTTP_PROXY}"
        [[ -n "${HTTPS_PROXY:-}" ]] && echo "    HTTPS_PROXY=${HTTPS_PROXY}"
        [[ -n "${ALL_PROXY:-}" ]]   && echo "    ALL_PROXY=${ALL_PROXY}"
        echo "  如果网络连接失败，请先尝试关闭代理: unset HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    fi

    info "环境检测完成 (OS: $os)"
}

# --- 网络测速与镜像选择 ----------------------------------------------------

speed_test_single() {
    local name="$1" url="$2"
    local code
    code=$(http_get_headers "$url" 3)

    if [[ "$code" == "000" ]]; then
        echo "-1"
    else
        # 任何 2xx/3xx/4xx 都表示可达，返回一个可排序的值
        echo "1000"
    fi
}

select_mirrors() {
    step "阶段2: 网络测速与镜像选择"

    # --- npm registry ---
    info "测速 npm registry..."
    local npm_official_reachable
    local npm_mirror_reachable

    npm_official_reachable=$(speed_test_single "npm官方" "$NPM_REGISTRY_OFFICIAL")
    npm_mirror_reachable=$(speed_test_single "npmmirror" "$NPM_REGISTRY_MIRROR")

    if [[ "$npm_official_reachable" == "1000" ]]; then
        NPM_REGISTRY="$NPM_REGISTRY_OFFICIAL"
        success "npm 官方源可达"
    elif [[ "$npm_mirror_reachable" == "1000" ]]; then
        NPM_REGISTRY="$NPM_REGISTRY_MIRROR"
        success "npmmirror 镜像源可达（已切换到国内镜像）"
    else
        warn "所有 npm 源均不可达。将使用默认源，安装可能失败。"
    fi

    # --- GitHub 下载加速 ---
    info "测速 GitHub..."
    local github_direct
    local github_proxy_reachable

    github_direct=$(speed_test_single "GitHub直连" "https://github.com")
    github_proxy_reachable=$(speed_test_single "ghproxy" "https://ghproxy.com/")

    if [[ "$github_direct" == "1000" ]]; then
        SELECTED_GITHUB_DL_BASE="https://github.com"
        success "GitHub 直连可达"
    elif [[ "$github_proxy_reachable" == "1000" ]]; then
        SELECTED_GITHUB_DL_BASE="https://ghproxy.com/https://github.com"
        success "ghproxy 镜像可达（GitHub 下载将走代理）"
    else
        warn "GitHub 和 ghproxy 均不可达。GitHub Release 下载将尝试直连。"
        warn "如失败，建议手动下载或检查 DNS/代理设置。"
    fi
}

# --- 前置依赖安装 ---------------------------------------------------------

install_xcode_clt() {
    if [[ "$(os_name)" != "macos" ]]; then return 0; fi

    # 检测 Xcode CLT 是否已安装
    if xcode-select -p &>/dev/null; then
        return 0
    fi

    warn "未检测到 Xcode Command Line Tools（Git 等工具需要它）"
    info "正在触发安装（系统将弹出确认窗口）..."
    xcode-select --install 2>/dev/null || true

    echo ""
    warn "请在系统弹窗中点击「安装」，安装完成后按回车继续。"
    read -rp "  按回车继续..."

    if ! xcode-select -p &>/dev/null; then
        warn "Xcode CLT 安装似乎未完成，Git 可能不可用。"
    else
        success "Xcode Command Line Tools 已安装"
    fi
}

install_nvm_and_node() {
    step "阶段1a: 安装 Node.js (通过 nvm)"

    # 检查是否已有符合要求的 Node
    if check_cmd node; then
        local node_ver
        node_ver=$(node --version | sed 's/v//')
        local node_major
        node_major=$(echo "$node_ver" | cut -d. -f1)
        if [[ "$node_major" -ge "$NODE_MIN_MAJOR" ]]; then
            success "Node.js ${node_ver} 已满足最低要求 (>= ${NODE_MIN_MAJOR}.x)"
            return 0
        else
            warn "当前 Node.js ${node_ver} 版本过低，需要 >= ${NODE_MIN_MAJOR}.x"
        fi
    else
        info "未检测到 Node.js"
    fi

    # 检测/安装 nvm
    if [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
        info "nvm 已存在，加载中..."
        export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        # shellcheck disable=SC1091
        source "$NVM_DIR/nvm.sh" 2>/dev/null || true
    else
        info "正在安装 nvm..."
        export NVM_DIR="${HOME}/.nvm"
        local nvm_install_url="https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh"

        if [[ "$SELECTED_GITHUB_DL_BASE" == *"ghproxy"* ]]; then
            nvm_install_url="https://ghproxy.com/${nvm_install_url}"
        fi

        if check_cmd curl; then
            curl -fsSL "$nvm_install_url" | bash 2>&1 || die "nvm 安装失败"
        elif check_cmd wget; then
            wget -qO- "$nvm_install_url" | bash 2>&1 || die "nvm 安装失败"
        else
            die "需要 curl 或 wget 来下载 nvm，但两者都未安装。请先安装 curl。"
        fi

        # 加载 nvm
        # shellcheck disable=SC1091
        source "$NVM_DIR/nvm.sh" 2>/dev/null || true
        success "nvm 安装完成"
    fi

    # 安装 Node.js LTS
    info "正在安装 Node.js LTS..."
    nvm install --lts 2>&1 || die "Node.js LTS 安装失败"
    nvm use --lts 2>&1 || die "Node.js 切换失败"
    nvm alias default 'lts/*' 2>/dev/null || true

    INSTALLED_NODE=true

    # 确保 nvm 在新终端可见
    local shell_rc=""
    case "$(basename "${SHELL:-bash}")" in
        zsh)  shell_rc="${HOME}/.zshrc" ;;
        bash) shell_rc="${HOME}/.bashrc" ;;
        *)    shell_rc="${HOME}/.profile" ;;
    esac

    if ! grep -q 'NVM_DIR' "$shell_rc" 2>/dev/null; then
        {
            echo ''
            echo '# NVM (Claude Code installer added)'
            echo 'export NVM_DIR="$HOME/.nvm"'
            echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
        } >> "$shell_rc"
        info "nvm 初始化已写入 ${shell_rc}"
    fi

    node --version && success "Node.js 安装完成: $(node --version)"
}

install_git() {
    step "阶段1b: 检测 Git"

    if check_cmd git; then
        success "Git 已安装: $(git --version)"
        return 0
    fi

    local os
    os=$(os_name)

    if [[ "$os" == "macos" ]]; then
        info "macOS 上尝试安装 Xcode Command Line Tools（包含 git）..."
        install_xcode_clt
        if check_cmd git; then
            INSTALLED_GIT=true
            return 0
        fi
    elif [[ "$os" == "linux" ]]; then
        warn "未检测到 Git。请使用系统包管理器安装："
        echo "    Debian/Ubuntu: sudo apt-get install -y git"
        echo "    RHEL/CentOS:   sudo yum install -y git"
        echo "    Arch:          sudo pacman -S git"
    fi
}

# --- Claude Code CLI 安装 -------------------------------------------------

install_claude_code() {
    step "阶段3: 安装 Claude Code CLI"

    # 设置 npm registry
    if [[ "$NPM_REGISTRY" != "$NPM_REGISTRY_OFFICIAL" ]]; then
        npm config set registry "$NPM_REGISTRY" 2>/dev/null || true
        info "npm registry 已设置为: ${NPM_REGISTRY}"
    fi

    # npm 全局目录权限修复
    local npm_global_dir
    npm_global_dir="$(npm config get prefix 2>/dev/null || echo '')"

    # 检测 npm 全局目录是否需要权限修复
    if [[ -n "$npm_global_dir" ]] && [[ ! -w "$npm_global_dir" ]]; then
        warn "npm 全局目录无写入权限: ${npm_global_dir}"
        info "正在配置用户级 npm 目录..."

        local npm_user_dir="${HOME}/.npm-global"
        mkdir -p "$npm_user_dir"
        npm config set prefix "$npm_user_dir" 2>/dev/null

        # 添加到 PATH
        local shell_rc=""
        case "$(basename "${SHELL:-bash}")" in
            zsh)  shell_rc="${HOME}/.zshrc" ;;
            bash) shell_rc="${HOME}/.bashrc" ;;
            *)    shell_rc="${HOME}/.profile" ;;
        esac

        if ! grep -q '.npm-global' "$shell_rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$shell_rc"
            info "PATH 已写入 ${shell_rc}"
        fi
        export PATH="$HOME/.npm-global/bin:$PATH"
        success "npm 权限已修复 (prefix: ${npm_user_dir})"
    fi

    # 安装
    info "正在安装 ${CC_NPM_PACKAGE}@${CC_VERSION}..."
    if npm install -g "${CC_NPM_PACKAGE}@${CC_VERSION}" 2>&1; then
        INSTALLED_CC=true
        success "Claude Code CLI 安装完成: $(claude --version 2>/dev/null || echo 'version ok')"
    else
        die "Claude Code CLI 安装失败。请检查网络连接或尝试 --use-bundle 模式。"
    fi
}

# --- CCSwitch 安装 --------------------------------------------------------

get_latest_ccswitch_version() {
    local api_url="https://api.github.com/repos/${CCSWITCH_REPO}/releases/latest"
    local version

    # 如果 GitHub 不通，用 ghproxy
    if [[ "$SELECTED_GITHUB_DL_BASE" == *"ghproxy"* ]]; then
        api_url="https://ghproxy.com/${api_url}"
    fi

    version=$(curl -fsSL "$api_url" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*: "\(.*\)".*/\1/' | sed 's/^v//')
    echo "${version:-latest}"
}

install_ccswitch() {
    step "阶段4: 安装 CCSwitch"

    local os
    os=$(os_name)
    local arch
    arch=$(os_arch)

    info "获取 CCSwitch 最新版本..."
    local version
    version=$(get_latest_ccswitch_version)

    if [[ "$version" == "latest" ]]; then
        warn "无法获取 CCSwitch 最新版本号，将尝试下载最新 Release。"
    fi

    if [[ "$os" == "macos" ]]; then
        install_ccswitch_macos "$version"
    elif [[ "$os" == "linux" ]]; then
        install_ccswitch_linux "$version" "$arch"
    fi

    INSTALLED_CCSWITCH=true
    print_ccswitch_guide
}

install_ccswitch_macos() {
    local version="$1"

    # 方式1: 尝试 Homebrew
    if check_cmd brew; then
        info "检测到 Homebrew，尝试通过 brew 安装 CCSwitch..."
        if brew tap farion1231/ccswitch 2>/dev/null && brew install --cask cc-switch 2>&1; then
            success "CCSwitch 安装完成 (Homebrew)"
            return 0
        fi
        warn "Homebrew 安装失败，尝试手动下载..."
    fi

    # 方式2: 手动下载
    local dl_base="${SELECTED_GITHUB_DL_BASE}"
    local zip_file="CC-Switch-v${version}-macOS.zip"
    local dl_url

    if [[ "$dl_base" == *"ghproxy"* ]]; then
        dl_url="${dl_base}/farion1231/cc-switch/releases/download/v${version}/${zip_file}"
    else
        dl_url="${dl_base}/farion1231/cc-switch/releases/download/v${version}/${zip_file}"
    fi

    info "正在下载 CCSwitch..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf $tmp_dir' RETURN

    if curl -fSL -o "${tmp_dir}/${zip_file}" "$dl_url" 2>&1; then
        info "正在解压..."
        unzip -o "${tmp_dir}/${zip_file}" -d /Applications/ 2>&1 || warn "解压到 /Applications 失败，请手动安装"
        success "CCSwitch 已下载到 /Applications"
        info "macOS 安全提示: 如遇「无法验证开发者」警告，请前往："
        info "  系统设置 → 隐私与安全性 → 仍要打开"
    else
        warn "CCSwitch 下载失败。请手动从以下地址下载安装："
        echo "  https://github.com/farion1231/cc-switch/releases"
    fi
}

install_ccswitch_linux() {
    local version="$1"
    local arch="$2"

    local dl_base="${SELECTED_GITHUB_DL_BASE}"
    local deb_file="CC.Switch_${version}_amd64.deb"
    local dl_url

    if [[ "$dl_base" == *"ghproxy"* ]]; then
        dl_url="${dl_base}/farion1231/cc-switch/releases/download/v${version}/${deb_file}"
    else
        dl_url="${dl_base}/farion1231/cc-switch/releases/download/v${version}/${deb_file}"
    fi

    info "正在下载 CCSwitch (.deb)..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf $tmp_dir' RETURN

    if curl -fSL -o "${tmp_dir}/${deb_file}" "$dl_url" 2>&1; then
        if check_cmd sudo; then
            info "安装需要管理员权限，请输入密码："
            sudo dpkg -i "${tmp_dir}/${deb_file}" 2>&1 || die "dpkg 安装失败"
            success "CCSwitch 安装完成"
        else
            warn "未找到 sudo，请手动安装："
            echo "  dpkg -i ${tmp_dir}/${deb_file}"
        fi
    else
        # 尝试 AppImage
        local appimage_file="CC.Switch-${version}.AppImage"
        warn ".deb 下载失败，尝试 AppImage..."
        if [[ "$dl_base" == *"ghproxy"* ]]; then
            dl_url="${dl_base}/farion1231/cc-switch/releases/download/v${version}/${appimage_file}"
        else
            dl_url="${dl_base}/farion1231/cc-switch/releases/download/v${version}/${appimage_file}"
        fi

        if curl -fSL -o "${HOME}/CC-Switch.AppImage" "$dl_url" 2>&1; then
            chmod +x "${HOME}/CC-Switch.AppImage"
            success "CCSwitch (AppImage) 已下载到 ~/CC-Switch.AppImage"
        else
            warn "CCSwitch 下载失败。请手动从以下地址下载："
            echo "  https://github.com/farion1231/cc-switch/releases"
        fi
    fi
}

print_ccswitch_guide() {
    echo ""
    echo -e "$(color "$COLOR_BOLD" '╔══════════════════════════════════════════════════════════╗')"
    echo -e "$(color "$COLOR_BOLD" '║')"       "$(color "$COLOR_GREEN" 'CC Switch — 配置 DeepSeek V4 接入 Claude Code')       $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '╠══════════════════════════════════════════════════════════╣')"
    echo -e "$(color "$COLOR_BOLD" '║')                                                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" '1.') 获取 DeepSeek API Key                                $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     - 阿里云百炼: https://bailian.console.aliyun.com     $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     - 硅基流动:   https://siliconflow.cn                  $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     - DeepSeek 官方: https://platform.deepseek.com       $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')                                                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" '2.') 打开 CC Switch（系统托盘图标）                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     → 点击「供应商」→「添加供应商」                        $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     → 选择 DeepSeek → 填入 API Key                       $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')                                                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" '3.') 配置模型映射（本地路由模式）                            $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     → Haiku  → deepseek-v4-pro                           $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     → Sonnet → deepseek-v4-pro                           $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     → Opus   → deepseek-v4-pro                           $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     $(color "$COLOR_YELLOW" '⚠ 本地路由模式下不要带 [1m] 后缀')                      $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')                                                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" '4.') 切换到 DeepSeek                                        $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "     → CC Switch → 选择 DeepSeek 供应商 → 点击「应用」      $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')                                                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" '5.') 验证: 运行 $(color "$COLOR_YELLOW" 'claude') 观察模型名                        $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')                                                          $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '║')" "  详细文档: https://github.com/farion1231/cc-switch        $(color "$COLOR_BOLD" '║')"
    echo -e "$(color "$COLOR_BOLD" '╚══════════════════════════════════════════════════════════╝')"
    echo ""
}

# --- 验证 ----------------------------------------------------------------

verify_installation() {
    step "阶段5: 验证安装"

    local all_ok=true

    echo ""
    echo -e "  $(color "$COLOR_CYAN" 'Node.js:') "
    if check_cmd node; then
        echo "    $(node --version)"
    else
        echo "    $(color "$COLOR_RED" '未安装')"
        all_ok=false
    fi

    echo -e "  $(color "$COLOR_CYAN" 'npm:')"
    if check_cmd npm; then
        echo "    $(npm --version)  (registry: $(npm config get registry 2>/dev/null))"
    else
        echo "    $(color "$COLOR_RED" '未安装')"
        all_ok=false
    fi

    echo -e "  $(color "$COLOR_CYAN" 'Git:')"
    if check_cmd git; then
        echo "    $(git --version)"
    else
        echo "    $(color "$COLOR_YELLOW" '未安装')"
    fi

    echo -e "  $(color "$COLOR_CYAN" 'Claude Code CLI:')"
    if check_cmd claude; then
        echo "    $(claude --version 2>/dev/null || echo '已安装')"
    else
        # 检查 npm-global 路径
        if [[ -x "${HOME}/.npm-global/bin/claude" ]]; then
            echo "    $(color "$COLOR_YELLOW" '请重新打开终端或运行: export PATH=\"\$HOME/.npm-global/bin:\$PATH\"')"
        else
            echo "    $(color "$COLOR_RED" '未安装')"
            all_ok=false
        fi
    fi

    echo ""

    if $all_ok; then
        # 写入安装标记
        mkdir -p "$LOG_DIR"
        touch "$INSTALL_MARKER"

        echo -e "$(color "$COLOR_BOLD" '╔════════════════════════════════════════════════╗')"
        echo -e "$(color "$COLOR_BOLD" '║')     $(color "$COLOR_GREEN" 'Claude Code CLI 安装成功!')                  $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '╠════════════════════════════════════════════════╣')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" 'Node.js:')  $(node --version | sed 's/v//')                              $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" 'Git:')      $(git --version | sed 's/git version //')                    $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" 'CC CLI:')   $(claude --version 2>/dev/null || echo '已安装')                              $(color "$COLOR_BOLD" '║')"
        if $INSTALLED_CCSWITCH; then
            echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" 'Backend:')  DeepSeek V4 (via CCSwitch)          $(color "$COLOR_BOLD" '║')"
        fi
        echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_CYAN" 'npm 源:')  $(npm config get registry 2>/dev/null)   $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '╠════════════════════════════════════════════════╣')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  运行 $(color "$COLOR_YELLOW" 'claude') 开始使用                           $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  运行 $(color "$COLOR_YELLOW" 'claude mcp add') 配置 MCP 工具              $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '╠════════════════════════════════════════════════╣')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_RED" '请勿升级! npm update -g 会导致无法使用')           $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '║')" "  $(color "$COLOR_YELLOW" '版本锁定: claude-code@2.1.153')                  $(color "$COLOR_BOLD" '║')"
        echo -e "$(color "$COLOR_BOLD" '╚════════════════════════════════════════════════╝')"
    else
        warn "部分组件未正确安装。请查看日志: ${LOG_FILE}"
    fi
}

# --- 卸载 ----------------------------------------------------------------

run_uninstall() {
    echo ""
    echo -e "$(color "$COLOR_YELLOW" '========================================')"
    echo -e "$(color "$COLOR_YELLOW" '  Claude Code CLI 卸载工具')"
    echo -e "$(color "$COLOR_YELLOW" '========================================')"
    echo ""

    # 1. 卸载 Claude Code CLI
    if check_cmd claude; then
        info "卸载 Claude Code CLI..."
        npm uninstall -g "$CC_NPM_PACKAGE" 2>/dev/null || warn "npm 卸载失败，可尝试手动删除"
        success "Claude Code CLI 已卸载"
    else
        info "Claude Code CLI 未安装，跳过。"
    fi

    # 2. CCSwitch
    if [[ "$(os_name)" == "macos" ]]; then
        if check_cmd brew && brew list --cask cc-switch &>/dev/null 2>&1; then
            read -rp "  是否卸载 CCSwitch? [y/N] " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                brew uninstall --cask cc-switch 2>/dev/null || true
                info "CCSwitch 已卸载（Homebrew）"
            fi
        elif [[ -d "/Applications/CC Switch.app" ]]; then
            echo "  CCSwitch 位于 /Applications/CC Switch.app"
            echo "  $(color "$COLOR_YELLOW" '请手动将 CC Switch.app 移到废纸篓以卸载')"
        fi
    fi

    # 3. nvm & Node.js
    echo ""
    warn "nvm 和 Node.js 可能被其他项目使用，默认不卸载。"
    read -rp "  是否同时卸载 nvm 和 Node.js? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [[ -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
            rm -rf "${NVM_DIR:-$HOME/.nvm}"
            info "nvm 目录已删除: ${NVM_DIR:-$HOME/.nvm}"
        fi
        echo "  $(color "$COLOR_YELLOW" '请手动从 .bashrc / .zshrc 中删除 nvm 相关的行')"
    fi

    # 4. 恢复 npm registry
    if check_cmd npm; then
        info "恢复 npm registry 到默认值..."
        npm config delete registry 2>/dev/null || true
    fi

    # 5. ~/.claude 目录
    if [[ -d "${HOME}/.claude" ]]; then
        read -rp "  是否删除 ~/.claude 配置目录（含登录态）? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "${HOME}/.claude"
            info "~/.claude 目录已删除"
        fi
    fi

    # 6. 安装标记
    rm -f "$INSTALL_MARKER"

    echo ""
    success "卸载完成。如有残留文件，请手动检查："
    echo "  - ~/.npm-global/"
    echo "  - ~/.claude/"
    echo "  - ~/.nvm/"
    echo "  - .bashrc / .zshrc 中的 NVM/PATH 相关行"
}

# --- dry-run 模式 ---------------------------------------------------------

run_dry_run() {
    echo ""
    echo -e "$(color "$COLOR_CYAN" '========================================')"
    echo -e "$(color "$COLOR_CYAN" '  Dry-Run 模式 — 仅预览，不实际安装')"
    echo -e "$(color "$COLOR_CYAN" '========================================')"
    echo ""

    echo -e "  $(color "$COLOR_BOLD" '系统信息:')"
    echo "    操作系统:       $(uname -s) ($(uname -r))"
    echo "    架构:           $(uname -m) ($(os_arch))"
    echo "    Shell:          ${SHELL:-unknown}"
    echo "    用户目录:       ${HOME}"

    local avail_kb avail_mb
    avail_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
    avail_mb=$((avail_kb / 1024))
    echo "    可用磁盘空间:   ${avail_mb}MB"

    echo ""
    echo -e "  $(color "$COLOR_BOLD" '已安装状态:')"
    check_cmd node   && echo "    Node.js:       $(node --version)"   || echo "    Node.js:       $(color "$COLOR_RED" '未安装')"
    check_cmd npm    && echo "    npm:           $(npm --version)"    || echo "    npm:           $(color "$COLOR_RED" '未安装')"
    check_cmd git    && echo "    Git:           $(git --version)"   || echo "    Git:           $(color "$COLOR_YELLOW" '未安装')"
    check_cmd claude && echo "    Claude Code:   $(claude --version 2>/dev/null || echo '已安装')" || echo "    Claude Code:   $(color "$COLOR_RED" '未安装')"
    check_cmd brew   && echo "    Homebrew:      已安装"             || echo "    Homebrew:      未安装"

    echo ""
    echo -e "  $(color "$COLOR_BOLD" '将要安装:')"
    [[ "$(check_cmd node && node --version | sed 's/v//' | cut -d. -f1)" -ge "$NODE_MIN_MAJOR" ]] 2>/dev/null \
        && echo "    Node.js:       已满足要求，跳过" \
        || echo "    Node.js LTS:   通过 nvm 安装 (约 100MB)"
    check_cmd git \
        && echo "    Git:           已满足要求，跳过" \
        || echo "    Git:           需要安装"
    check_cmd claude \
        && echo "    Claude Code:   已安装，将升级到最新版" \
        || echo "    Claude Code:   通过 npm 安装 (约 200MB)"
    echo "    CCSwitch:      从 GitHub Releases 下载桌面应用"
    echo "    总计预计占用:  约 500MB - 1GB"
    echo ""

    if [[ "$(os_name)" == "macos" ]] && ! xcode-select -p &>/dev/null; then
        echo -e "  $(color "$COLOR_YELLOW" '⚠ 警告: Xcode Command Line Tools 未安装，可能需要额外下载 (~2GB)')"
    fi
}

# --- Bundle 模式 ----------------------------------------------------------

run_bundle_install() {
    local bundle_file="${BUNDLE_PATH:-}"

    if [[ -z "$bundle_file" ]]; then
        # 从网络下载 bundle
        local os_name_str arch_str ext
        os_name_str=$(os_name)
        arch_str=$(os_arch)

        case "$os_name_str" in
            macos) ext="tar.gz" ;;
            linux) ext="tar.gz" ;;
            *)     die "Bundle 模式不支持当前操作系统: ${os_name_str}" ;;
        esac

        local bundle_name="cc-offline-latest-${os_name_str}-${arch_str}.${ext}"
        local dl_url_gh="https://github.com/DDDDavi4/claude-code-installer-helper/releases/latest/download/${bundle_name}"

        # 如果有 ghproxy 可用则走代理
        if [[ "$SELECTED_GITHUB_DL_BASE" == *"ghproxy"* ]]; then
            dl_url_gh="https://ghproxy.com/${dl_url_gh}"
        fi

        info "正在下载 bundle..."

        local tmp_dir
        tmp_dir=$(mktemp -d)
        bundle_file="${tmp_dir}/${bundle_name}"

        if ! curl -fSL -o "$bundle_file" "$dl_url_gh" 2>&1; then
            die "Bundle 下载失败。请检查网络连接或使用在线安装模式。"
        fi
    fi

    info "正在解压 bundle: ${bundle_file}"

    local extract_dir
    extract_dir=$(mktemp -d)
    trap 'rm -rf $extract_dir' EXIT

    tar -xzf "$bundle_file" -C "$extract_dir" 2>&1 || die "Bundle 解压失败"

    # 执行 bundle 内的 setup 脚本
    if [[ -f "${extract_dir}/setup.sh" ]]; then
        bash "${extract_dir}/setup.sh"
    elif [[ -f "${extract_dir}/install.sh" ]]; then
        bash "${extract_dir}/install.sh"
    else
        die "Bundle 中未找到 setup.sh，bundle 可能已损坏。"
    fi
}

# --- 帮助信息 ------------------------------------------------------------

print_help() {
    echo "Claude Code CLI 一键安装脚本 v${SCRIPT_VERSION}"
    echo ""
    echo "用法: bash install.sh [选项]"
    echo ""
    echo "选项:"
    echo "  --dry-run         模拟运行，只显示检测结果和安装计划"
    echo "  --uninstall       卸载所有已安装的组件"
    echo "  --use-bundle [路径] 使用离线 bundle 安装 (可选指定本地文件)"
    echo "  --help            显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  bash install.sh                  # 在线安装"
    echo "  bash install.sh --dry-run        # 预览安装计划"
    echo "  bash install.sh --use-bundle     # 使用 bundle 模式"
    echo "  bash install.sh --uninstall      # 卸载"
}

# --- 故障排查提示 ---------------------------------------------------------

print_troubleshooting() {
    echo ""
    echo -e "$(color "$COLOR_YELLOW" '════════════════════════════════════════════')"
    echo -e "$(color "$COLOR_YELLOW" '  常见问题排查')"
    echo -e "$(color "$COLOR_YELLOW" '════════════════════════════════════════════')"
    echo ""
    echo -e "  $(color "$COLOR_CYAN" 'npm 权限错误 (EACCES/EPERM):')"
    echo "    脚本已自动处理，如仍有问题:"
    echo "    sudo chown -R \$(whoami) ~/.npm"
    echo ""
    echo -e "  $(color "$COLOR_CYAN" '代理/网络问题:')"
    echo "    关闭代理:  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    echo "    切换 DNS:  echo 'nameserver 114.114.114.114' | sudo tee /etc/resolv.conf"
    echo ""
    echo -e "  $(color "$COLOR_CYAN" 'CCSwitch 无法打开 (macOS):')"
    echo "    系统设置 → 隐私与安全性 → 仍要打开"
    echo "    或执行: xattr -cr \"/Applications/CC Switch.app\""
    echo ""
    echo -e "  $(color "$COLOR_CYAN" 'claude 命令找不到:')"
    echo "    重新打开终端，或执行:"
    echo "    export PATH=\"\$HOME/.npm-global/bin:\$PATH\""
    echo ""
    echo -e "  $(color "$COLOR_CYAN" '更多帮助:')"
    echo "    https://github.com/DDDDavi4/claude-code-installer-helper/issues"
    echo ""
}

# --- 主流程 ----------------------------------------------------------------

main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --use-bundle)
                USE_BUNDLE=true
                if [[ -n "${2:-}" ]] && [[ "$2" != --* ]]; then
                    BUNDLE_PATH="$2"
                    shift
                fi
                shift
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                error "未知参数: $1"
                print_help
                exit 1
                ;;
        esac
    done

    # dry-run 不需要日志
    if $DRY_RUN; then
        run_dry_run
        exit 0
    fi

    # 初始化日志（在 dry-run 之后）
    log_init

    echo ""
    echo -e "$(color "$COLOR_CYAN" '╔══════════════════════════════════════╗')"
    echo -e "$(color "$COLOR_CYAN" '║')  $(color "$COLOR_BOLD" 'Claude Code CLI 一键安装脚本')        $(color "$COLOR_CYAN" '║')"
    echo -e "$(color "$COLOR_CYAN" '║')  v'"${SCRIPT_VERSION}"'                              $(color "$COLOR_CYAN" '║')"
    echo -e "$(color "$COLOR_CYAN" '╚══════════════════════════════════════╝')"
    echo ""
    info "日志文件: ${LOG_FILE}"
    echo ""

    # 卸载模式
    if $UNINSTALL_MODE; then
        run_uninstall
        exit 0
    fi

    # Bundle 模式
    if $USE_BUNDLE; then
        run_bundle_install
        verify_installation
        print_troubleshooting
        exit 0
    fi

    # --- 标准在线安装流程 ---
    check_system                          # 阶段0
    install_xcode_clt                     # macOS 前置
    select_mirrors                        # 阶段2
    install_nvm_and_node                  # 阶段1a
    install_git                           # 阶段1b
    install_claude_code                   # 阶段3
    install_ccswitch                      # 阶段4
    verify_installation                   # 阶段5
    print_troubleshooting

    info "完整日志已保存至: ${LOG_FILE}"
}

main "$@"
