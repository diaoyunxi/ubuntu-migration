#!/usr/bin/env bash
# 运行 Ubuntu 迁移项目的所有最小测试（中文版）。
#
# 用法（从项目根目录）：
#   bash tests/run_all.sh
#
# CMD 脚本因面向 Windows，只做文本/编码检查；
# Bash 脚本用 bash -n 与基本标记测试检查。
#
# 每个测试在子 shell 中运行，单个测试失败不会中断其他测试；
# 只要有一个测试失败，脚本就以非零状态退出。

cd "$(dirname "$0")/.."

status=0
for t in tests/test_cmd_syntax.sh tests/test_bash_syntax.sh; do
    echo "=== 正在运行 $t ==="
    if bash "$t"; then
        echo "--- $t 通过"
    else
        echo "--- $t 失败"
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "全部测试通过"
else
    echo "部分测试失败" >&2
fi
exit "$status"
