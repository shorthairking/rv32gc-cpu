#!/usr/bin/env bash
#==============================================================================
# patch_platform_33mhz.sh —— 把 chiplab 平台顶层改成本项目的 33 MHz 方案（幂等）
#
# 背景（见 fpga/README.md §2.1）：用户拍板上板时钟 33 MHz。100 MHz→33 MHz 无精确 MMCM 解，
# 故直接**复用平台 `clk_pll_33` 的 clk_out2（33 MHz）同时驱动 cpu_clk 与 uncore_clk**
# ——CPU 与 uncore 同域，AXI 全同步、无 CDC。
#
# 本脚本只做两处最小改动（都在 chip/soc_demo/loongson/soc_top.v）：
#   ① `clk_pll_33` 例化：不再用 clk_out1(50 MHz)，把 clk_out2 接到 uncore_clk（保持原样）
#   ② 新增 `assign cpu_clk = uncore_clk;`（cpu_clk 原本由 clk_out1 驱动 ⇒ 必须同时留空 clk_out1）
#   另把 `config.h` 的 FREQ 改成 33（软件侧时钟一致性）。
#
# 幂等：已打过补丁则直接跳过。默认 dry-run，需显式 `--apply` 才写文件；改动前自动备份 .bak。
# 用法：bash fpga/patch_platform_33mhz.sh [--apply]
#==============================================================================
set -u
cd "$(dirname "$0")/.."                     # rv32gc-cpu/
PLAT=${PLATFORM_ROOT:-../chiplab}
TOP="$PLAT/chip/soc_demo/loongson/soc_top.v"
CFG="$PLAT/chip/soc_demo/loongson/config.h"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$TOP" ] || { echo "patch_platform: 找不到 $TOP（用 PLATFORM_ROOT=… 指定 chiplab 根目录）"; exit 1; }

need_top=0; need_cfg=0
grep -q "clk_out1( )," "$TOP" 2>/dev/null || grep -q "clk_out1(  )," "$TOP" 2>/dev/null || need_top=1
grep -q "assign cpu_clk *= *uncore_clk" "$TOP" || need_top=1
grep -qE '^[`#]define +FREQ +32.d33000000' "$CFG" 2>/dev/null || need_cfg=1   # 平台原文即 `` `define FREQ 32'd33000000 ``

echo "patch_platform_33mhz: 平台=$PLAT"
echo "  · soc_top.v  需要改动: $([ $need_top -eq 1 ] && echo 是 || echo 否（已打过）)"
echo "  · config.h   FREQ→33  : $([ $need_cfg -eq 1 ] && echo 是 || echo 否（已是 33）)"

if [ $APPLY -eq 0 ]; then
  echo "  （dry-run；加 --apply 才写入。将要做的两处改动：）"
  echo "    ① .clk_out1(cpu_clk),   →  .clk_out1(),        // 50 MHz 不再使用"
  echo "    ② 在 clk_pll_33 例化之后加：assign cpu_clk = uncore_clk;   // 33 MHz 同域（无 CDC）"
  echo "    ③ config.h: #define FREQ 33"
  exit 0
fi

[ $need_top -eq 1 ] || [ $need_cfg -eq 1 ] || { echo "  无需改动。"; exit 0; }
cp -n "$TOP" "$TOP.bak" 2>/dev/null || true
cp -n "$CFG" "$CFG.bak" 2>/dev/null || true

python3 - "$TOP" "$CFG" <<'PY'
import re, sys
top, cfg = sys.argv[1], sys.argv[2]
s = open(top).read()
# ① clk_out1 不再驱动 cpu_clk
s2 = re.sub(r"\.clk_out1\(cpu_clk\)(\s*),?(\s*//\s*50MHz)?", r".clk_out1()\1,\2  // 50MHz 不再使用（33MHz 方案）", s, count=1)
if s2 == s:
    s2 = s.replace(".clk_out1(cpu_clk),", ".clk_out1(),", 1)
# ② 33 MHz 同域：cpu_clk = uncore_clk（幂等）
if "assign cpu_clk" not in s2 and "assign cpu_clk" not in s:
    anchor = re.search(r"clk_pll_33\s+clk_pll_33\s*\n?\s*\(", s2)
    # 在 clk_pll_33 例化结束的 ");" 之后插入 assign
    m = re.search(r"(clk_pll_33\s+clk_pll_33[\s\S]*?\n\s*\);\s*\n)", s2)
    if m:
        ins = m.group(1) + "\n// 【RV32-GC 33MHz 方案】CPU 与 uncore 同域：直接复用 clk_out2(33MHz)，AXI 无 CDC\nassign cpu_clk = uncore_clk;\n"
        s2 = s2[:m.start(1)] + ins + s2[m.end(1):]
    else:
        print("  ⚠ 未找到 clk_pll_33 例化，未插入 assign（请手工按 README §2.1 处理）")
open(top, "w").write(s2)
s = open(cfg).read()
s = re.sub(r"(#define\s+FREQ\s+)\d+", r"\g<1>33", s, count=1)
open(cfg, "w").write(s)
print("  ✅ 已写入 soc_top.v / config.h（原文件备份为 *.bak）")
PY
echo "  提示：改完请在 Vivado 里综合确认 WNS≥0（33 MHz / 30.303 ns）与 BRAM 推断（见 README §2.3）。"
