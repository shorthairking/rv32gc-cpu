#!/usr/bin/env bash
# lockstep.sh —— 在 0x8000_0000 布局下做 Spike 与本核的提交级锁步比对
# 用法: scripts/lockstep.sh <elf> [max_commits]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$1"; MAXC="${2:-2000}"
OUT="$ROOT/sim/log"; mkdir -p "$OUT"
OBJCOPY=riscv32-unknown-linux-gnu-objcopy
SPIKE="$ROOT/tools/spike-install/bin/spike"
NAME=$(basename "$ELF" .elf)

# 1) Spike 提交轨迹（内存映射 0x8000_0000）
timeout 120 "$SPIKE" -m0x80000000:0x10000000 --isa=rv32i --log-commits "$ELF" 2>/dev/null \
  | head -"$MAXC" > "$OUT/$NAME.spike.log"

# 2) 生成 mem_hi 镜像（重定位到 0x80000000）
"$OBJCOPY" -O verilog --verilog-data-width=1 --change-addresses=-0x80000000 "$ELF" "$OUT/$NAME.hi.hex"

# 3) 用 RESET_PC=0x80000000 重新编译 RTL + 调试 TB，跑出提交轨迹
iverilog -g2005 -I "$ROOT/rtl/pkg" -DRESET_PC=32'h8000_0000 -s tb_debug_min \
  -o "$OUT/$NAME.lockstep.vvp" $(find "$ROOT/rtl" -name '*.v' | sort) \
  "$ROOT/sim/tb/sim_axi_slave.v" "$ROOT/sim/tb/tb_debug_min.v"
timeout 300 vvp "$OUT/$NAME.lockstep.vvp" "+MEM_HI_INIT=$OUT/$NAME.hi.hex" 2>/dev/null \
  | grep -E '^C' > "$OUT/$NAME.rtl.log"

# 4) 比对
python3 "$ROOT/scripts/lockstep_diff.py" "$OUT/$NAME.spike.log" "$OUT/$NAME.rtl.log"
