#!/usr/bin/env bash
# Ubuntu 迁移 CMD 脚本的最小健全性测试（中文版）。
# 由于 Windows CMD 无法在 Linux 上可移植地解析，
# 这里只执行基本的文本/编码检查。从项目根目录运行：
#   bash tests/test_cmd_syntax.sh
#
# 说明：ubuntu_migration.cmd 以 GBK(CP936) 编码、CRLF 换行保存，
# 以便在简体中文 Windows 上正确显示中文。本测试用 iconv 验证其
# 确为合法 GBK，并检查关键中文日志标记。

set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="ubuntu_migration.cmd"
test -f "$SCRIPT" || { echo "错误：未找到 $SCRIPT"; exit 1; }

# ---------- 基本行数 / 非空检查 ----------
LINES=$(wc -l < "$SCRIPT")
[ "$LINES" -gt 50 ] || { echo "错误：脚本行数过少（$LINES）"; exit 1; }
echo "OK: $SCRIPT 共 $LINES 行"

# ---------- 确认为合法 GBK(CP936) 编码 ----------
# 将文件从 GBK 转成 UTF-8；若字节不是合法 GBK 序列，iconv 会失败。
TMP_UTF8="$(mktemp)"
trap 'rm -f "$TMP_UTF8"' EXIT
if ! iconv -f GBK -t UTF-8 "$SCRIPT" > "$TMP_UTF8" 2>/dev/null; then
    echo "错误：$SCRIPT 不是合法的 GBK(CP936) 编码"
    exit 1
fi
echo "OK: 文件为合法 GBK(CP936) 编码（已转 UTF-8 校验）"

# ---------- 必备章节标记（在转出的 UTF-8 内容里检查）----------
for token in "[1/10]" "[10/10]" ":search_app" ":scan_file" 'D:\backup' \
             ":reg_subkey" ":add_extra_drive" ":try_known_app_mapping" \
             ":show_and_edit" ":lg_dbg" ":lg_step" ":lg_info" ":lg_warn" \
             "chcp 936" "LOG_LEVEL" "THRESH"; do
    grep -qF "$token" "$TMP_UTF8" || { echo "错误：缺少标记：$token"; exit 1; }
done
echo "OK: 必备标记齐全"

# ---------- 中文日志标记（验证中文化确实生效）----------
for zh in "[步骤]" "[信息]" "[调试]" "[警告]" "正在确保备份根目录" "总结与后续步骤" ; do
    grep -qF "$zh" "$TMP_UTF8" || { echo "错误：缺少中文标记：$zh"; exit 1; }
done
echo "OK: 中文日志标记存在"

# ---------- GitHub URL 必须已移除（项目约定）----------
if grep -qF "github.com" "$SCRIPT"; then
    echo "错误：CMD 脚本中仍存在 GitHub URL；应当移除"
    exit 1
fi
echo "OK: 无 GitHub URL"

# ---------- :try_github_release_asset 标签必须已移除 ----------
if grep -qF ":try_github_release_asset" "$SCRIPT"; then
    echo "错误：:try_github_release_asset 标签仍存在；应当移除"
    exit 1
fi
echo "OK: 无 :try_github_release_asset 标签"

# ---------- 必须使用 CRLF 换行（Windows 批处理要求）----------
# 统计回车符；正规 CRLF 文件的 CR 数量应 >= LF 数量。
CR_COUNT=$(tr -cd '\r' < "$SCRIPT" | wc -c)
if [ "$CR_COUNT" -gt 0 ]; then
    echo "OK: 检测到 CRLF 换行（$CR_COUNT 个 CR）"
else
    echo "错误：CMD 脚本没有 CR 字符；使用了纯 LF，Windows 批处理可能异常"
    exit 1
fi

# ---------- 映射 findstr 必须带 /C: 防止多词短语被拆成子串误命中 ----------
# 回归检查：Google Chrome / Visual Studio Code 含空格，若 findstr 不带 /C:，
# 会把 "AgnesCode"(含 Code)、"obs-studio"(含 Studio) 等目录误判为命中映射。
if ! grep -qF 'findstr /i /C:"Google Chrome"' "$SCRIPT"; then
    echo "错误：缺少 /C:\"Google Chrome\"，映射会误命中"
    exit 1
fi
if ! grep -qF 'findstr /i /C:"Visual Studio Code"' "$SCRIPT"; then
    echo "错误：缺少 /C:\"Visual Studio Code\"，映射会误命中"
    exit 1
fi
echo "OK: 映射 findstr 已带 /C: 短语保护"

# ---------- wmic 解析必须用 tokens=1（而非 tokens=2 delims=:）----------
if grep -qF 'tokens=2 delims=:' "$SCRIPT"; then
    echo "错误：发现 'tokens=2 delims=:'，对 wmic 输出解析不正确"
    exit 1
fi
echo "OK: wmic 解析使用正确的 token 规格"

# ---------- 不应隐藏 PowerShell 依赖（可选告警）----------
if grep -qi "powershell" "$SCRIPT"; then
    echo "警告：CMD 脚本中提及 powershell；请确认其为可选项"
fi

echo "PASS: CMD 基本检查全部通过"
