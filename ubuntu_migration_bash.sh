#!/usr/bin/env bash
# Ubuntu 迁移工具 - Bash 入口（中文 + 彩色 + DEBUG 级日志）
#
# 用法：
#   sudo bash ./ubuntu_migration_bash.sh
#
# 功能：
#   1. 检测是否运行在 Ubuntu 安装器/live 环境中；若是，提示先完成安装
#      并重启后再运行本脚本，然后退出。
#   2. 在已安装好的 Ubuntu 系统中：
#        - 用 blkid 查找并挂载包含 D:\backup 的旧 Windows 盘
#          （NTFS/exFAT，按 'backup' 目录名大小写不敏感匹配）
#        - 安装 /backup/app 下的软件包（apt_candidates.txt /
#          snap_candidates.txt / 本地 .deb/.AppImage 文件）
#        - 将 /backup/C 的用户文件还原到家目录
#
# 注意：挂载与安装软件包需要 root 权限（sudo）。

set -uo pipefail   # 故意不用 -e：单个包安装失败也要继续并汇报。

# ---------- 日志级别与彩色 ----------
# LOG_LEVEL 可选值：OFF / ERROR / WARN / INFO / DEBUG（默认 DEBUG = 最详细）
# 先把默认值固定到 LOG_LEVEL 本身，避免 set -u 下对未定义变量裸引用报错。
LOG_LEVEL="${LOG_LEVEL:-DEBUG}"
case "$LOG_LEVEL" in
  DEBUG) _LVL=4 ;;
  INFO)  _LVL=3 ;;
  WARN)  _LVL=2 ;;
  ERROR) _LVL=1 ;;
  *)     _LVL=0 ;;
esac

# 仅当输出到终端且未设置 NO_COLOR 时启用彩色；否则自动降级为纯文本。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'
  C_STEP=$'\033[34m'; C_INFO=$'\033[32m'; C_DBG=$'\033[36m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_BOLD=""; C_STEP=""; C_INFO=""; C_DBG=""; C_WARN=""; C_ERR=""
fi

# 日志文件（纯文本、无 ANSI），便于事后审计。可用 LOG_FILE 覆盖。
LOG_FILE="${LOG_FILE:-/tmp/ubuntu_migration_bash.log}"
: > "$LOG_FILE" 2>/dev/null || true

_append() {
  printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || printf '?')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

lg_step() { echo "${C_BOLD}${C_STEP}[步骤] $*${C_RST}"; _append "[步骤] $*"; }
lg_info() { [ "$_LVL" -ge 3 ] || return 0; echo "${C_INFO}[信息] $*${C_RST}"; _append "[信息] $*"; }
lg_dbg()  { [ "$_LVL" -ge 4 ] || return 0; echo "${C_DBG}[调试] $*${C_RST}";  _append "[调试] $*"; }
lg_warn() { [ "$_LVL" -ge 2 ] || return 0; echo "${C_WARN}[警告] $*${C_RST}" >&2; _append "[警告] $*"; }
lg_err()  { echo "${C_ERR}[错误] $*${C_RST}" >&2; _append "[错误] $*"; }

BACKUP_ROOT="backup"           # Windows 盘上的备份文件夹名
BACKUP_C_DIR="${BACKUP_ROOT}/C"
BACKUP_APP_DIR="${BACKUP_ROOT}/app"
MOUNT_POINT="/mnt/windows"

lg_step "Ubuntu 迁移工具 - Bash 入口"
lg_dbg "日志级别: $LOG_LEVEL（阈值=$_LVL）  彩色: $([ -t 1 ] && [ -z "${NO_COLOR:-}" ] && echo 开 || echo 关)"
lg_dbg "日志文件: $LOG_FILE"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        lg_err "本脚本需要以 sudo 运行：sudo bash $0"
        exit 1
    fi
}

# 真实的（非 root）用户主目录。
# 在 sudo 下 $HOME 是 /root；我们要的是真实用户的主目录。
REAL_USER=""
REAL_HOME=""
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    REAL_USER="${SUDO_USER}"
    REAL_HOME="/home/${SUDO_USER}"
else
    REAL_USER="$(id -un)"
    REAL_HOME="${HOME}"
fi
lg_dbg "运行用户: REAL_USER=$REAL_USER  REAL_HOME=$REAL_HOME"

# ----------------------------------------------------------------
# 1) 检测安装器 / live 环境
# ----------------------------------------------------------------
in_installer=0
lg_dbg "开始检测安装器/live 环境..."
if [ -d "/cdrom" ] && [ -f "/cdrom/.disk/info" ]; then
    lg_info "检测到 /cdrom/.disk/info：可能在 Ubuntu 安装器/live 中运行。"
    in_installer=1
fi

if grep -q "casper" /proc/cmdline 2>/dev/null; then
    lg_info "检测到 /proc/cmdline 中的 'casper'：正在 live 安装器中运行。"
    in_installer=1
fi

if [ -f "/etc/live/RELEASE" ]; then
    lg_info "检测到 /etc/live/RELEASE：正在 live 会话中运行。"
    in_installer=1
fi

# 其他“live/安装器树（而非已安装系统）”的信号
if [ -d "/run/casper" ] || [ -d "/cdrom/casper" ]; then
    lg_info "检测到 casper 运行时目录：正在 live 安装器中运行。"
    in_installer=1
fi

if [ "$in_installer" -eq 1 ]; then
    lg_step "=========================================================="
    lg_step "本脚本正在 Ubuntu 安装器/live ISO 中运行。"
    lg_step ""
    lg_step "请先完成 Ubuntu 安装。安装并首次进入系统后，"
    lg_step "再次运行本脚本："
    lg_step ""
    lg_step "    sudo bash ./ubuntu_migration_bash.sh"
    lg_step ""
    lg_step "届时它会挂载旧 Windows 盘，并安装"
    lg_step "${BACKUP_APP_DIR} 下列出的软件。"
    lg_step ""
    lg_step "你在 Windows 上使用的备份盘（D:）应仍连接着；"
    lg_step "脚本会自动识别。"
    lg_step "详细日志: $LOG_FILE"
    lg_step "=========================================================="
    exit 0
fi

# ----------------------------------------------------------------
# 2) 定位包含备份根的旧 Windows 盘。
# ----------------------------------------------------------------
require_root
lg_step "[1/4] 定位并挂载旧 Windows 盘..."

find_windows_drives() {
    # 列出 NTFS 或 exFAT 块设备，每行一个。
    # 直接按文件系统类型查询 blkid，比解析 export 格式更稳健
    # （后者可能出现共享记录 id 的多行记录）。
    {
        blkid -t ntfs -o device 2>/dev/null
        blkid -t exfat -o device 2>/dev/null
    } | sort -u
}

lg_info "正在搜索 Windows 盘（NTFS/exFAT）..."
WINDOWS_DRIVES=()
while IFS= read -r line; do
    [ -n "$line" ] && WINDOWS_DRIVES+=("$line")
done < <(find_windows_drives)

if [ "${#WINDOWS_DRIVES[@]}" -eq 0 ]; then
    lg_err "未找到 NTFS/exFAT 盘。"
    lg_info "请确认旧 Windows 磁盘仍连接着。"
    lg_info "若知道设备（如 /dev/sda2），可手动挂载："
    lg_info "    sudo mount /dev/sda2 ${MOUNT_POINT}"
    lg_info "然后重跑本脚本。"
    lg_step "详细日志: $LOG_FILE"
    exit 1
fi

lg_info "找到 ${#WINDOWS_DRIVES[@]} 个候选 Windows 盘："
for d in "${WINDOWS_DRIVES[@]}"; do
    lg_dbg "  候选盘: $d"
done

# 在尝试挂载前，确保 ntfs-3g / exfat 工具可用。
ensure_fs_tools() {
    local dev="$1" fstype
    fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null | tr -d '"' || true)
    lg_dbg "确保文件系统工具: $dev（类型=$fstype）"
    case "$fstype" in
        ntfs)
            if ! command -v ntfs-3g >/dev/null 2>&1; then
                lg_info "正在安装 ntfs-3g ..."
                apt-get update -qq || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y ntfs-3g \
                    || { lg_warn "无法安装 ntfs-3g；挂载可能失败。"; return 1; }
            fi
            ;;
        exfat)
            if ! command -v mount.exfat >/dev/null 2>&1 && \
               ! lsmod 2>/dev/null | grep -q '^exfat'; then
                lg_info "正在安装 exfat 工具 ..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y exfat-fuse exfat-utils \
                    || { lg_warn "无法安装 exfat 工具；挂载可能失败。"; return 1; }
            fi
            ;;
    esac
    return 0
}

# 自动挑选包含名为 'backup' 目录的盘（大小写不敏感：NTFS 在
# Windows 上大小写不敏感，但挂载可能保留或规范化该名称）。
chosen=""
for d in "${WINDOWS_DRIVES[@]}"; do
    lg_info "正在挂载 $d 到 $MOUNT_POINT（探测）..."
    ensure_fs_tools "$d" || true
    mkdir -p "$MOUNT_POINT"
    if ! mount "$d" "$MOUNT_POINT" 2>/dev/null; then
        lg_warn "挂载 $d 失败；尝试下一个。"
        continue
    fi
    # 在挂载卷的顶层查找名为 'backup' 的目录（大小写不敏感）。
    if find "$MOUNT_POINT" -maxdepth 1 -iname 'backup' -type d 2>/dev/null | grep -q .; then
        chosen="$d"
        lg_info "在 $d 上找到 'backup' 目录。"
        umount "$MOUNT_POINT" 2>/dev/null || true
        break
    else
        lg_warn "$d 上未找到 'backup'；卸载并尝试下一个。"
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
done

if [ -z "$chosen" ]; then
    lg_info "无法自动识别哪个盘包含 'backup'。"
    lg_info "请选择正确的设备："
    i=1
    for d in "${WINDOWS_DRIVES[@]}"; do
        lg_info "  $i) $d"
        i=$((i+1))
    done
    if [ -t 0 ]; then
        read -rp "输入包含 /backup 的设备编号: " idx
    else
        lg_warn "无终端交互；默认选择第一个盘。"
        idx=1
    fi
    if [ -z "${WINDOWS_DRIVES[$((idx-1))]:-}" ]; then
        lg_err "选择无效。"
        exit 1
    fi
    chosen="${WINDOWS_DRIVES[$((idx-1))]}"
    lg_info "已选择 $chosen"
fi

# 挂载所选盘
lg_step "[2/4] 挂载所选 Windows 盘..."
ensure_fs_tools "$chosen" || true
mkdir -p "$MOUNT_POINT"
if ! mount "$chosen" "$MOUNT_POINT"; then
    lg_err "无法将 $chosen 挂载到 $MOUNT_POINT。"
    exit 1
fi
lg_info "已挂载 $chosen 到 $MOUNT_POINT"
lg_dbg "正在 $MOUNT_POINT 查找 backup 根目录"

# 检查备份根目录是否存在（大小写不敏感）
BACKUP_ABS=""
while IFS= read -r cand; do
    [ -n "$cand" ] && BACKUP_ABS="$cand" && break
done < <(find "$MOUNT_POINT" -maxdepth 1 -iname 'backup' -type d 2>/dev/null)

if [ -z "$BACKUP_ABS" ]; then
    lg_err "$MOUNT_POINT/backup 在 $chosen 上不存在。"
    lg_info "Windows CMD 脚本应当已创建 D:\backup。"
    umount "$MOUNT_POINT" 2>/dev/null || true
    lg_step "详细日志: $LOG_FILE"
    exit 1
fi
lg_info "备份根目录: $BACKUP_ABS"
BACKUP_ROOT_ABS="$BACKUP_ABS"
BACKUP_C_ABS="${BACKUP_ABS}/C"
BACKUP_APP_ABS="${BACKUP_ABS}/app"

# ----------------------------------------------------------------
# 3) 从 /backup/C 还原用户文件
# ----------------------------------------------------------------
lg_step "[3/4] 还原用户文件（/backup/C）..."
if [ -d "$BACKUP_C_ABS" ]; then
    lg_info "在 $BACKUP_C_ABS 找到用户文件。"
    lg_info "正在还原到 ${REAL_HOME}/.ubuntu_migration_backup_C ..."
    lg_dbg "源目录顶层条目（前 10 项）："
    ls -1 "$BACKUP_C_ABS" 2>/dev/null | head -10 | while IFS= read -r l; do
        lg_dbg "  $l"
    done
    # 保留属性复制；源是只读 NTFS 挂载，所以复制到用户主目录并修正属主。
    mkdir -p "${REAL_HOME}/.ubuntu_migration_backup_C"
    if cp -a "${BACKUP_C_ABS}/." "${REAL_HOME}/.ubuntu_migration_backup_C/" 2>/dev/null; then
        lg_info "文件已还原到 ${REAL_HOME}/.ubuntu_migration_backup_C"
        lg_dbg "正在将属主修正为 ${REAL_USER} ..."
        chown -R "${REAL_USER}" "${REAL_HOME}/.ubuntu_migration_backup_C" 2>/dev/null || true
    else
        lg_warn "部分文件未能复制；请检查上方权限信息。"
    fi
    lg_info "你可手动将它们移动到指定位置。"
else
    lg_warn "在 $BACKUP_C_ABS 未找到用户文件备份。"
fi

# ----------------------------------------------------------------
# 4) 从 /backup/app 安装软件包
# ----------------------------------------------------------------
lg_step "[4/4] 安装软件包（/backup/app）..."
if [ -d "$BACKUP_APP_ABS" ]; then
    lg_info "在 $BACKUP_APP_ABS 找到应用包目录。"

    apt_candidates="${BACKUP_APP_ABS}/apt_candidates.txt"
    snap_candidates="${BACKUP_APP_ABS}/snap_candidates.txt"

    # 收集本地二进制包到数组，供下方处理。
    local_packages=()
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local_packages+=("$f")
    done < <(find "$BACKUP_APP_ABS" -maxdepth 1 -type f \
             \( -name '*.deb' -o -name '*.AppImage' -o -name '*.appimage' \
                -o -name '*.tar.gz' -o -name '*.tar.xz' \) 2>/dev/null)
    lg_dbg "本地二进制包: ${local_packages[*]:-（无）}"

    # 安装循环前运行一次 apt-get update。
    if [ -f "$apt_candidates" ]; then
        lg_info "正在从 apt_candidates.txt 安装 apt 包 ..."
        apt-get update -qq || lg_warn "apt-get update 失败；继续。"
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            # 去掉首尾空白
            pkg="${pkg#"${pkg%%[![:space:]]*}"}"
            pkg="${pkg%"${pkg##*[![:space:]]}"}"
            [ -z "$pkg" ] && continue
            lg_dbg "  apt: $pkg"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" \
                || lg_warn "  apt 包安装失败: $pkg（仓库中可能不存在）"
        done < "$apt_candidates"
    else
        lg_warn "未找到 apt_candidates.txt。"
    fi

    if [ -f "$snap_candidates" ]; then
        lg_info "正在从 snap_candidates.txt 安装 snap 包 ..."
        if command -v snap >/dev/null 2>&1; then
            while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                pkg="${pkg#"${pkg%%[![:space:]]*}"}"
                pkg="${pkg%"${pkg##*[![:space:]]}"}"
                [ -z "$pkg" ] && continue
                lg_dbg "  snap: $pkg"
                snap install "$pkg" || lg_warn "  snap 包安装失败: $pkg"
            done < "$snap_candidates"
        else
            lg_warn "未安装 snapd；跳过 snap 包。"
        fi
    else
        lg_warn "未找到 snap_candidates.txt。"
    fi

    # 放在应用目录里的任何本地 .deb / .appimage / 压缩包
    lg_dbg "正在检查本地二进制包（.deb、.appimage、.tar.gz）..."
    found_local=0
    for f in ${local_packages[@]+"${local_packages[@]}"}; do
        lg_dbg "  本地: $f"
        case "$f" in
            *.deb)
                dpkg -i "$f" 2>/dev/null || {
                    apt-get install -f -y 2>/dev/null || true
                    lg_warn "    $f 未能完整安装；可能缺少依赖。"
                }
                ;;
            *.AppImage|*.appimage)
                bname="$(basename "$f")"
                mkdir -p /opt/local_apps
                cp "$f" "/opt/local_apps/${bname}" 2>/dev/null \
                    || { lg_warn "    无法复制 $f"; continue; }
                chmod +x "/opt/local_apps/${bname}" 2>/dev/null || true
                lg_info "    AppImage 已安装到 /opt/local_apps/${bname}"
                ;;
            *.tar.gz|*.tar.xz)
                mkdir -p /opt/local_apps
                tar -xf "$f" -C /opt/local_apps/ 2>/dev/null \
                    || lg_warn "    无法解压 $f"
                ;;
        esac
        found_local=1
    done
    if [ "$found_local" -eq 1 ]; then
        lg_info "已处理本地包。"
    else
        lg_dbg "未找到本地二进制包。"
    fi
else
    lg_warn "在 $BACKUP_APP_ABS 未找到应用包目录。"
fi

# ----------------------------------------------------------------
# 5) 卸载并收尾
# ----------------------------------------------------------------
lg_step "卸载并收尾..."
# 在卸载前保存路径供摘要使用。
RESTORE_DIR="${REAL_HOME}/.ubuntu_migration_backup_C"
APP_DIR_FOR_SUMMARY="${BACKUP_APP_ABS}"

lg_info "正在卸载 $chosen ..."
umount "$MOUNT_POINT" 2>/dev/null || lg_warn "无法卸载 $MOUNT_POINT（可能有文件仍打开）。"

lg_step "=========================================================="
lg_step "迁移完成。"
lg_step ""
lg_step "  - 用户文件（若有）已还原到:"
lg_step "      ${RESTORE_DIR}"
lg_step "  - 已安装的软件来自:"
lg_step "      ${APP_DIR_FOR_SUMMARY}"
lg_step ""
lg_step "请检查还原的文件与已安装的应用；必要时重启。"
lg_step "详细日志: $LOG_FILE"
lg_step "=========================================================="
