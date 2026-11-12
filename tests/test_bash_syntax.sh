#!/usr/bin/env bash
# Ubuntu 迁移 Bash 脚本的最小健全性测试（中文版）。
# 从项目根目录运行：bash tests/test_bash_syntax.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="ubuntu_migration_bash.sh"
test -f "$SCRIPT" || { echo "错误：未找到 $SCRIPT"; exit 1; }

# 1) Bash 语法检查
bash -n "$SCRIPT"
echo "OK: bash -n $SCRIPT 通过"

# 2) 彩色与日志级别（验证中文化 + 彩色 + DEBUG 日志确实生效）
for token in \
    "lg_step" \
    "lg_info" \
    "lg_dbg" \
    "lg_warn" \
    "LOG_LEVEL" \
    "\033[36m" \
    "[步骤]" \
    "[调试]"; do
    grep -qF "$token" "$SCRIPT" || { echo "错误：缺少标记：$token"; exit 1; }
done
echo "OK: 彩色与日志级别标记齐全"

# 3) 验证必备辅助函数 / 变量存在
for token in \
    "find_windows_drives" \
    "MOUNT_POINT" \
    "BACKUP_APP_ABS" \
    "in_installer" \
    "require_root" \
    "ensure_fs_tools" \
    "local_packages" \
    "REAL_HOME" \
    "SUDO_USER"; do
    grep -q "$token" "$SCRIPT" || { echo "错误：缺少标记：$token"; exit 1; }
done
echo "OK: 必备函数/变量齐全"

# 4) 脚本不应使用 'set -e'（我们依赖显式错误处理）
if grep -q "set -e" "$SCRIPT"; then
    echo "警告：发现 'set -e'；本脚本设计为失败后继续执行"
fi

# 5) 脚本必须用 SUDO_USER 解析主目录
#    （避免以 sudo 运行时把文件还原到 /root）
if ! grep -q "SUDO_USER" "$SCRIPT"; then
    echo "错误：脚本未用 SUDO_USER 解析主目录"
    exit 1
fi
echo "OK: 存在 SUDO_USER 处理"

# 6) 确认为 UTF-8 编码（中文内容）
#    将文件当 UTF-8 读一遍；若有非法字节，iconv 失败。
if ! iconv -f UTF-8 -t UTF-8 "$SCRIPT" >/dev/null 2>&1; then
    echo "错误：$SCRIPT 不是合法的 UTF-8 编码"
    exit 1
fi
echo "OK: 文件为合法 UTF-8 编码"

echo "PASS: Bash 最小测试全部通过"
