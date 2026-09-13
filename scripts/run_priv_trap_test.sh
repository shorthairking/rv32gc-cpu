#!/usr/bin/env bash
#=============================================================================
# run_priv_trap_test.sh —— 特权/陷阱路径定向自测（sim/tests/priv_trap.S）的
#                         构建 + 仿真 + 判定 一体化脚本
#
#   用法: scripts/run_priv_trap_test.sh
#   通过: 打印 PRIV_TRAP: PASS (<N> checks)，退出码 0（N 由被测试程序自己打印）
#   失败: 打印 PRIV_TRAP: FAIL ...，退出码非 0
#
# 覆盖：mtvec WARL(direct/vectored)、M/S/U 三态 ecall、medeleg 委托、stvec、
#       mret/sret、mstatus.MPP、sstatus.SPP/SPIE/SIE、M 模式软件中断进入、
#       mepc/sepc 低位对齐（详见 sim/tests/priv_trap.S 头部注释）
#
# 机制复用：
#   · 汇编/链接与 sim/tests/lrsc.S 同款（-T sim/tests/link.ld → 复位 PC=0x0 布局）
#   · 仿真走 scripts/run_sim.sh（tb_smoke + core_top），本脚本只负责判定与打印
#   · 退出码 0x1FAF_FF00 / 虚拟串口 0x1FAF_FF10 与全项目约定一致
#
# 环境变量：
#   RV32GC_TIMEOUT=<n> 覆盖 tb_smoke 超时时钟数（默认 400000，够本测试 ~4 万拍）
#   CROSS=<前缀>       覆盖工具链前缀（默认 riscv32-unknown-linux-gnu-）
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT=sim/tests/out
LOG=sim/log/priv_trap.log
TMO="${RV32GC_TIMEOUT:-400000}"
mkdir -p "$OUT" sim/log

CROSS="${CROSS:-riscv32-unknown-linux-gnu-}"
CC="${CC:-${CROSS}gcc}"
OBJCOPY="${OBJCOPY:-${CROSS}objcopy}"
OBJDUMP="${OBJDUMP:-${CROSS}objdump}"

for tool in "$CC" "$OBJCOPY"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: 找不到 $tool（用 CROSS= 指定前缀）" >&2; exit 1; }
done

#------------------------------------------------------------------------------
# 1. 构建（纯 RV32I+Zicsr，不启用 C：全部 4 字节指令，便于按 PC 校验 mepc/sepc；
#    -mno-relax 保证 la = auipc+addi，地址与期望值可控）
#------------------------------------------------------------------------------
echo "[priv_trap] 汇编 sim/tests/priv_trap.S → $OUT/priv_trap.elf"
set +e
"$CC" -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
      -Wl,--no-relax -Wl,--no-warn-rwx-segments -T sim/tests/link.ld \
      -o "$OUT/priv_trap.elf" sim/tests/priv_trap.S
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "PRIV_TRAP: FAIL (汇编失败 rc=$rc)"
    exit 1
fi

"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/priv_trap.elf" "$OUT/priv_trap.hex"
[ -n "$OBJDUMP" ] && command -v "$OBJDUMP" >/dev/null 2>&1 && \
    "$OBJDUMP" -d "$OUT/priv_trap.elf" > "$OUT/priv_trap.dump" || true

#------------------------------------------------------------------------------
# 2. 仿真（复用 scripts/run_sim.sh：查找 $OUT/priv_trap.hex 已存在的镜像，直接载入）
#------------------------------------------------------------------------------
echo "[priv_trap] 仿真（scripts/run_sim.sh priv_trap，timeout=$TMO 时钟）"
set +e
RV32GC_TIMEOUT="$TMO" bash scripts/run_sim.sh priv_trap > /dev/null 2>&1
sim_rc=$?
set -e

#------------------------------------------------------------------------------
# 3. 判定：程序自打印的判定行 + TB 的 EXIT code 双保险
#------------------------------------------------------------------------------
echo "[priv_trap] ---- 被测试程序输出（VUART）----"
grep -a '^\[FAIL\]' "$LOG" || true
grep -a '^\[SKIP\]' "$LOG" || true
# 失败时的现场证据块（中断未进入时的 CSR/寄存器快照）
if grep -qa -- '---- 中断现场证据 ----' "$LOG"; then
    sed -n '/---- 中断现场证据 ----/,/expected_ent/p' "$LOG" || true
fi

# 判定行由被测试程序自己打印（N = 实际执行的检查数），脚本只做透传，不臆造
VERDICT="$(grep -a -m1 -o 'PRIV_TRAP:.*' "$LOG" || true)"

if [ "$sim_rc" -eq 0 ] && grep -qa 'TB: TEST PASS' "$LOG" && \
   [[ "$VERDICT" == PRIV_TRAP:\ PASS* ]]; then
    echo "[priv_trap] TB: $(grep -a -m1 'TB: EXIT code=' "$LOG" || true)"
    echo "$VERDICT"
    echo "[priv_trap] 日志: $LOG"
    exit 0
fi

if [ -n "$VERDICT" ]; then
    echo "$VERDICT"
else
    reason="无判定行"
    grep -qa 'TIMEOUT' "$LOG" && reason="超时（挂死，见日志 pc=）" || true
    echo "PRIV_TRAP: FAIL ($reason)"
fi
echo "[priv_trap] $(grep -a -m1 'TB: EXIT code=' "$LOG" || echo 'TB: 无 EXIT code 行')（sim rc=$sim_rc）"
echo "[priv_trap] 日志: $LOG"
exit 1
