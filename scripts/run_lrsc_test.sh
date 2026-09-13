#!/usr/bin/env bash
#=============================================================================
# run_lrsc_test.sh —— 构建并运行 A 扩展定向自测（sim/tests/lrsc.S）
#
# 流程：
#   1) 汇编 sim/tests/lrsc.S（-march=rv32imac_zicsr，自带的 _start/trap_handler）
#   2) 生成两种镜像：
#        lrsc.hex        —— 原样
#        lrsc_spread.hex —— 用 scripts/tests/spread_stores.py 把每条 store 之后的 4 条
#                           指令替换成 nop（规避 sim_axi_slave 行为模型"写后立刻读同一地址
#                           会读到上一版数据"的时序假象，见该脚本头部说明）
#   3) 两种镜像都跑 tb_trace_mem，要求 EXIT code=0
#
# 用法: scripts/run_lrsc_test.sh
# 环境: RV32GC_TIMEOUT 覆盖 maxcyc（默认 60000）
#=============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT=sim/tests/out
LOG=sim/log
mkdir -p "$OUT" "$LOG"
MAXCYC="${RV32GC_TIMEOUT:-60000}"

CC=riscv32-unknown-linux-gnu-gcc
OBJCOPY=riscv32-unknown-linux-gnu-objcopy

echo "[lrsc] 汇编 $OUT/lrsc.elf"
"$CC" -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles -O1 \
      -T sim/tests/link.ld -Wl,--no-warn-rwx-segments -o "$OUT/lrsc.elf" sim/tests/lrsc.S
"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/lrsc.elf" "$OUT/lrsc.hex"

# 说明：曾尝试用 scripts/tests/spread_stores.py 在镜像层面把 store 之后的指令改 nop 来规避
# 测试模型"写后立刻读同一地址读到旧值"的现象，但它会破坏控制流（分支目标落在被改区间），
# 已弃用。当前只跑原样镜像；该现象的定位见 AGENT.md 第 7 轮。

echo "[lrsc] 编译 tb_trace_mem"
iverilog -g2005 -I rtl/pkg -s tb_trace_mem -o "$LOG/trace.vvp" -DCORE_PRESENT \
         $(find rtl -name '*.v' | sort) sim/tb/tb_trace_mem.v sim/tb/sim_axi_slave.v

rc=0
for img in lrsc; do
    echo "[lrsc] 运行 $img（maxcyc=$MAXCYC）"
    set +e
    vvp "$LOG/trace.vvp" "+MEM_LO_INIT=$OUT/$img.hex" "+maxcyc=$MAXCYC" > "$LOG/${img}_run.log" 2>&1
    set -e
    if grep -qa 'EXIT code=0' "$LOG/${img}_run.log"; then
        echo "  PASS $img"
    else
        echo "  FAIL $img（日志 $LOG/${img}_run.log）"
        grep -a 'EXIT code=' "$LOG/${img}_run.log" | tail -1 || true
        rc=1
    fi
done

if [ "$rc" -eq 0 ]; then
    echo "LRSC_DIRECTED: PASS"
else
    echo "LRSC_DIRECTED: FAIL"
fi
exit "$rc"
