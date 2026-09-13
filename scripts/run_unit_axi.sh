#!/usr/bin/env bash
#=============================================================================
# run_unit_axi.sh —— AXI 从设备模型（sim/tb/sim_axi_slave.v）的单元自测
#
# 用法: scripts/run_unit_axi.sh
# 通过: 打印 AXI_SLAVE_UNIT: PASS (N checks) 且退出码 0
# 失败: 退出码非 0（iverilog 编译失败 / 检查不过 / $fatal）
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG_DIR="sim/log"
LOG="$LOG_DIR/unit_axi.log"
VVP="$LOG_DIR/tb_axi_slave.vvp"
mkdir -p "$LOG_DIR"

echo "[run_unit_axi] 编译: sim/tb/sim_axi_slave.v + sim/tests/unit/tb_axi_slave.v"
iverilog -g2005 -Wall -I rtl/pkg -s tb_axi_slave -o "$VVP" \
    sim/tb/sim_axi_slave.v \
    sim/tests/unit/tb_axi_slave.v

set +e
vvp "$VVP" 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e

# 双保险：$fatal 的退出码 + 日志内容
if [ "$rc" -ne 0 ] || grep -qE 'AXI_SLAVE_UNIT: FAIL|FAIL\]|FATAL' "$LOG"; then
    echo "UNIT: FAIL (rc=$rc, log=$LOG)"
    exit 1
fi
if ! grep -q 'AXI_SLAVE_UNIT: PASS' "$LOG"; then
    echo "UNIT: FAIL (no PASS marker, log=$LOG)"
    exit 1
fi

echo "[run_unit_axi] 日志: $LOG"
