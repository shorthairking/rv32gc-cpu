#!/usr/bin/env bash
#=============================================================================
# run_fencei_smc_test.sh —— `fence.i` + 自修改代码定向自测（sim/tests/fencei_smc.S）
#
#   用法: scripts/run_fencei_smc_test.sh
#   通过: 打印 "FENCEI_SMC: PASS (<N> checks)"，退出码 0（N 由被测试程序自己打印）
#   失败: 打印 "FENCEI_SMC: FAIL ..." + 现场证据，退出码非 0
#
# 验证什么：`fence.i` 提交拍必须让 L1 指令 Cache（rtl/frontend/rv32_icache.v）**整表失效**，
#   否则被 store 改写过的行会从 Cache 命中旧指令（阶段 2 必失败，见 sim/tests/fencei_smc.S 头部）。
#
# 机制复用：
#   · 汇编/链接与 sim/tests/fetch_err.S 同款（-T sim/tests/link.ld → 复位 PC=0x0 布局）
#   · 仿真走 scripts/run_sim.sh（tb_smoke + core_top），本脚本只负责判定与打印
#   · 退出码 0x1FAF_FF00 / 虚拟串口 0x1FAF_FF10 与全项目约定一致
#
# 环境变量：
#   RV32GC_TIMEOUT=<n> 覆盖 tb_smoke 超时时钟数（默认 400000，够本测试 ~2 千拍）
#   CROSS=<前缀>       覆盖工具链前缀（默认 riscv32-unknown-linux-gnu-）
#   ICACHE_ENABLE=<0|1> 传给 RTL 的 rv32_icache.ENABLE（默认 1；0 = 直通基线，
#                      用于对照实验：Cache 关掉时本测试也应当通过）
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT=sim/tests/out
LOG=sim/log/fencei_smc.log
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
# 1. 构建（纯 RV32I + Zicsr + Zifencei；-mno-relax 保证 li/la 形态可控）
#------------------------------------------------------------------------------
echo "[fencei_smc] 汇编 sim/tests/fencei_smc.S → $OUT/fencei_smc.elf"
set +e
"$CC" -march=rv32i_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
      -Wl,--no-relax -Wl,--no-warn-rwx-segments -T sim/tests/link.ld \
      -o "$OUT/fencei_smc.elf" sim/tests/fencei_smc.S
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "FENCEI_SMC: FAIL (汇编失败 rc=$rc)"
    exit 1
fi

"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/fencei_smc.elf" "$OUT/fencei_smc.hex"
[ -n "$OBJDUMP" ] && command -v "$OBJDUMP" >/dev/null 2>&1 && \
    "$OBJDUMP" -d "$OUT/fencei_smc.elf" > "$OUT/fencei_smc.dump" || true

#------------------------------------------------------------------------------
# 2. 仿真（复用 scripts/run_sim.sh：发现 $OUT/fencei_smc.hex 已存在即直接载入）
#------------------------------------------------------------------------------
echo "[fencei_smc] 仿真（scripts/run_sim.sh fencei_smc，timeout=$TMO 时钟）"
set +e
RV32GC_TIMEOUT="$TMO" bash scripts/run_sim.sh fencei_smc > /dev/null 2>&1
sim_rc=$?
set -e

#------------------------------------------------------------------------------
# 3. 判定
#------------------------------------------------------------------------------
if [ ! -f "$LOG" ]; then
    echo "FENCEI_SMC: FAIL (没有产生日志 $LOG，仿真未跑起来)"
    exit 1
fi
if [ "$sim_rc" -ne 0 ]; then
    echo "FENCEI_SMC: FAIL (仿真 rc=$sim_rc；日志 $LOG 尾部)"
    tail -20 "$LOG"
    exit 1
fi
if ! grep -qa 'FENCEI_SMC: PASS' "$LOG"; then
    echo "FENCEI_SMC: FAIL (日志中没有 'FENCEI_SMC: PASS')"
    echo "---- 现场（退出码 / 失败项 / 输出）----"
    grep -a 'EXIT code=' "$LOG" | tail -5 || true
    grep -a 'FENCEI_SMC' "$LOG" | tail -5 || true
    grep -a 'FAIL\|TRAP' "$LOG" | tail -10 || true
    exit 1
fi

echo "FENCEI_SMC: PASS"
grep -a 'FENCEI_SMC: PASS' "$LOG" | tail -1
echo "  日志: $LOG  反汇编: $OUT/fencei_smc.dump"
exit 0
