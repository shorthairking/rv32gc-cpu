#!/usr/bin/env bash
# lockstep.sh —— 在 0x8000_0000 布局下做 Spike 与本核的提交级锁步比对
# 用法: scripts/lockstep.sh <elf> [max_commits]
#   MAXCYC=<拍>  覆盖 RTL 侧仿真上限（默认 200000；遇到 tohost 会提前结束）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$1"; MAXC="${2:-6000}"
MAXCYC="${MAXCYC:-200000}"
OUT="$ROOT/sim/log"; mkdir -p "$OUT"
OBJCOPY=riscv32-unknown-linux-gnu-objcopy
SPIKE="$ROOT/tools/spike-install/bin/spike"
NAME=$(basename "$ELF" .elf)

# 1) Spike 提交轨迹（内存映射 0x8000_0000；ISA 必须与镜像一致，含 C 扩展）
#    注意：--log-commits 的输出在 stderr，必须 2>&1 1>/dev/null 才能只留提交轨迹
timeout 120 "$SPIKE" -m0x80000000:0x10000000 --isa="${ISA:-rv32imac}" --log-commits "$ELF" \
  2>&1 1>/dev/null | head -"$MAXC" > "$OUT/$NAME.spike.log" || true

# 2) 生成 mem_hi 镜像（重定位到 0x80000000）
"$OBJCOPY" -O verilog --verilog-data-width=1 --change-addresses=-0x80000000 "$ELF" "$OUT/$NAME.hi.hex"

# 3) 用 ELF 入口点作为 RESET_PC 重新编译 RTL + 调试 TB，跑出提交轨迹
#    注意：32'h... 必须加引号，否则 bash 会把单引号当成未闭合引号直接报错
ENTRY_HEX=$(riscv32-unknown-linux-gnu-readelf -h "$ELF" | awk '/Entry point address/{print $4}' | sed 's/^0x//')
[ -n "$ENTRY_HEX" ] || { echo "ERROR: 无法取得 ELF 入口点"; exit 1; }
echo "[lockstep] ELF 入口=0x$ENTRY_HEX（作为 RESET_PC）"
RTL_SRCS=(); while IFS= read -r f; do RTL_SRCS+=("$f"); done < <(find "$ROOT/rtl" -name '*.v' | sort)
iverilog -g2005 -I "$ROOT/rtl/pkg" -DRESET_PC="32'h$ENTRY_HEX" -s tb_debug_min \
  -o "$OUT/$NAME.lockstep.vvp" "${RTL_SRCS[@]}" \
  "$ROOT/sim/tb/sim_axi_slave.v" "$ROOT/sim/tb/tb_debug_min.v"
timeout 600 vvp "$OUT/$NAME.lockstep.vvp" "+MEM_HI_INIT=$OUT/$NAME.hi.hex" "+maxcyc=$MAXCYC" 2>/dev/null \
  | grep -E '^C' > "$OUT/$NAME.rtl.log"

# 4) 比对
python3 "$ROOT/scripts/lockstep_diff.py" "$OUT/$NAME.spike.log" "$OUT/$NAME.rtl.log"
