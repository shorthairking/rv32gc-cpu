#!/usr/bin/env bash
#=============================================================================
# run_dcache_test.sh —— L1 数据 Cache 定向功能测试（sim/tests/dcache_directed.S）
#
#   用法: bash scripts/run_dcache_test.sh
#   通过: 打印 "DCACHE_DIRECTED: PASS (<N> checks)"，退出码 0
#   失败: 打印 "DCACHE_DIRECTED: FAIL ..." + 首个失败现场（ck id/got/exp），退出码非 0
#
# 验证什么（详见 sim/tests/dcache_directed.S 头部）：
#   写后立刻读同址（写直达一致性）、同址 store→load→store→load 交替、跨行/非对齐读写、
#   LR/SC/AMO 在**已缓存行**上结果正确且随后 load 看到新值（AMO/SC 写完成必须**失效被写行**）、
#   自改码 + fence.i（D 侧写直达 + I 侧整表失效的组合）、
#   CBO.INVAL/CLEAN/FLUSH/ZERO 作用在**已缓存**行上（zero 必须穿过/更新 Cache）。
#
# 机制：与 scripts/run_fencei_smc_test.sh 同款（-T sim/tests/link.ld 复位 PC=0x0 布局），
#       仿真走 scripts/run_sim.sh（tb_smoke + core_top）。
# 环境变量：RV32GC_TIMEOUT / CROSS / 以及 DCACHE_ENABLE 传给 RTL（1=开 Cache，0=直通对照）
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT=sim/tests/out
LOG=sim/log/dcache_directed.log
TMO="${RV32GC_TIMEOUT:-400000}"
mkdir -p "$OUT" sim/log

CROSS="${CROSS:-riscv32-unknown-linux-gnu-}"
CC="${CC:-${CROSS}gcc}"
OBJCOPY="${OBJCOPY:-${CROSS}objcopy}"

echo "[dcache] 汇编 sim/tests/dcache_directed.S"
"$CC" -march=rv32imac_zicsr_zifencei_zicbom_zicboz -mabi=ilp32 -nostdlib -nostartfiles -O1 \
      -T sim/tests/link.ld -Wl,--no-warn-rwx-segments \
      -o "$OUT/dcache_directed.elf" sim/tests/dcache_directed.S
"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/dcache_directed.elf" "$OUT/dcache_directed.hex"

echo "[dcache] 运行（rv32gc_core + L1D ENABLE=${DCACHE_ENABLE:-1}）"
set +e
RV32GC_TIMEOUT="$TMO" bash scripts/run_sim.sh dcache_directed >/dev/null 2>&1
set -e

if grep -qa "DCACHE_DIRECTED: PASS" sim/log/dcache_directed.log; then
    grep -a "DCACHE_DIRECTED: PASS" sim/log/dcache_directed.log | tail -1
    exit 0
fi

echo "DCACHE_DIRECTED: FAIL"
grep -aE "DCACHE_DIRECTED|\[ck |TB: EXIT|TB: TIMEOUT|TB: TEST FAIL" sim/log/dcache_directed.log | head -10
exit 1
