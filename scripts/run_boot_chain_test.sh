#!/usr/bin/env bash
#==============================================================================
# run_boot_chain_test.sh —— 2A-7b「启动镜像三件套」的**仿真端到端验收**
#
# 与 run_spi_boot_test.sh 的区别：那个跑的是"单元级链路自测"（sim/tests/spi_boot.S），
# 本脚本跑的是**真正要烧写的产物**：`sw/board/spi_stub.S` + `sw/board/ddr_main.S`
# 经 `scripts/pack_boot_image.sh` 打包出的镜像，验证判据：
#   ① SPI 桩从 0x1C00_0000 复位起跑（复位向量 = SPI-XIP 窗口，D16）；
#   ② 桩打印横幅、经 `jr` 跳到 DDR 0x0；
#   ③ DDR 主镜像在 0x0 起跑并打印自己的横幅；
#   ④ 主镜像以退出码 0 结束（IO_SIMU 写 0）；
#   ⑤ TB 观测到"SPI 窗口提交过指令"且"DDR 窗口提交过指令"（顺序由 banner 保证）。
#
# 成功: "BOOT_CHAIN: PASS (...)" 且 exit 0；否则非零退出并打印日志路径。
# 用法: bash scripts/run_boot_chain_test.sh [--skip-pack]
#==============================================================================
set -u
cd "$(dirname "$0")/.."

OUT=sw/board/out
LOG=sim/log/boot_chain.log
VVP=sim/log/boot_chain.vvp
TIMEOUT=${BOOT_CHAIN_TIMEOUT:-200000}

: >"$LOG"
fail() { echo "BOOT_CHAIN: FAIL ($*)"; echo "  日志: $LOG"; exit 1; }

# 1. 打包（含 ≤1 MiB / 无重定位 / DDR 入口 0x0 三项硬判据）
[ "${1:-}" = "--skip-pack" ] || { bash scripts/pack_boot_image.sh >>"$LOG" 2>&1 || fail "打包失败（见 $LOG）"; }
for f in "$OUT/spi_stub.sim.hex" "$OUT/ddr_main.sim.hex"; do
  [ -f "$f" ] || fail "缺少 $f（先跑 scripts/pack_boot_image.sh）"
done

# 2. 编译 RTL + TB（复位向量 = SPI-XIP 窗口）
#    ⚠ -DRESET_PC 必须写成 Verilog 字面量 `32'h1C000000`：写成 `0x1C000000` 会让
#      iverilog 在解析 rv32gc_core.v 时报 "syntax error"（本轮踩过，排查成本很高）
echo "[boot-chain] 编译 RTL + tb_spi_boot（-DRESET_PC=32'h1C000000）"
if ! iverilog -g2005 -Wall -I rtl/pkg -s tb_spi_boot -o "$VVP" \
        -DCORE_PRESENT "-DRESET_PC=32'h1C000000" \
        $(find rtl -name '*.v' | sort) sim/tb/tb_spi_boot.v sim/tb/sim_axi_slave.v >>"$LOG" 2>&1; then
  fail "iverilog 编译失败（见 $LOG）"
fi

# 3. 运行：SPI 窗口镜像 + DDR 镜像
echo "[boot-chain] 运行（SPI=spi_stub.sim.hex, DDR=ddr_main.sim.hex, timeout=$TIMEOUT）"
set +e
vvp "$VVP" "+SPI_INIT=$OUT/spi_stub.sim.hex" "+MEM_LO_INIT=$OUT/ddr_main.sim.hex" \
          "+timeout=$TIMEOUT" 2>&1 | tee -a "$LOG"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "vvp rc=$rc（见 $LOG）"
grep -q "TIMEOUT" "$LOG" && fail "仿真超时（见 $LOG）"
grep -qE "%Error|Error: |\$fatal" "$LOG" && fail "仿真报错（见 $LOG）"

# 4. 断言：两条横幅都出现，且 SPI 横幅在 DDR 横幅之前（证明链路顺序）
#    日志里字符会有"重影"（同一字符打两遍）：桩同时写平台 UART(0x1FE0_01E0) 与仿真虚拟串口，
#    而仿真对这两个地址都会打印。断言前先把连续重复的字符折叠成一个（只影响可读性判断）。
NORM="$LOG.norm"
python3 - "$LOG" >"$NORM" <<'PYEOF'
import re, sys
s = open(sys.argv[1], errors='ignore').read()
sys.stdout.write(re.sub(r'(.)\1', r'\1', s))
PYEOF
grep -a -q "SPI stub at 0x1C000000" "$NORM" || fail "没看到 SPI 桩横幅（桩没跑起来）"
grep -a -q "DDR main image @0x0 running" "$NORM" || fail "没看到 DDR 主镜像横幅（跳转/主镜像没跑起来）"
SPI_LN=$(grep -a -n "SPI stub at 0x1C000000" "$NORM" | head -1 | cut -d: -f1)
DDR_LN=$(grep -a -n "DDR main image @0x0 running" "$NORM" | head -1 | cut -d: -f1)
[ "$SPI_LN" -lt "$DDR_LN" ] || fail "横幅顺序不符：SPI@$SPI_LN 应在 DDR@$DDR_LN 之前"
# TB 自身的 CHECK/ 退出码断言用**原始日志**（TB 打印不重影，只有程序串口输出会重影）
grep -a -q "CHECK-1 OK"      "$LOG" || fail "TB CHECK-1 失败：首笔取指不在 SPI-XIP 窗口"
grep -a -q "CHECK-2 OK"      "$LOG" || fail "TB CHECK-2 失败：没有指令在 SPI-XIP 窗口提交"
grep -a -q "CHECK-3 OK"      "$LOG" || fail "TB CHECK-3 失败：没有指令在 DDR 窗口提交"
grep -a -q "CHECK-4 OK"      "$LOG" || fail "TB CHECK-4 失败：跨窗口取指通路没打通"
grep -a -q "EXIT code=0"     "$LOG" || fail "没有观测到退出码 0（IO_SIMU）"

echo "BOOT_CHAIN: PASS (SPI 桩 0x1C00_0000 → DDR 0x0 → exit 0；横幅与窗口提交均观测到)"
echo "  日志: $LOG"
