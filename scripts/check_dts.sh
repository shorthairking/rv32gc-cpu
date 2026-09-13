#!/usr/bin/env bash
#==============================================================================
# check_dts.sh —— 2A-7c「DTS/OpenSBI 内存映射声明」的可验证检查
#
# 三部分（全部离线/仿真可跑，不需要板子）：
#   ① dtc 编译设备树（语法/引用/分区合法性）→ .dtb → 反编译回 .dts；
#   ② **DTS ↔ RTL 常量交叉校验**：DDR_BASE/DDR_SIZE、SPI_XIP_BASE/ALIAS、CLINT_BASE、PLIC_BASE
#      与 `rtl/pkg/rv32gc_defs.vh` 逐项比对（两套地址漂移必须 FAIL）；
#   ③ 平台事实与硬判据：UART 寄存器块 0x1FE0_01E0、NAND 数据口 +0x40、NAND 分区总长 = 128 MiB、
#      SPI boot 分区 ≤1 MiB（2A-7b 判据）、`riscv,ndev`=核内 PLIC 源数、mmu-type=sv32、
#      CLINT/PLIC 的 interrupts-extended 声明、CPU 中断控制器存在。
#
# 用法：bash scripts/check_dts.sh     产物：sim/log/rv32gc-chiplab.{dtb,decompiled.dts}
#==============================================================================
set -u
cd "$(dirname "$0")/.."

DTS=sw/board/rv32gc-chiplab.dts
LOG_DIR=sim/log
DTB=$LOG_DIR/rv32gc-chiplab.dtb
BACK=$LOG_DIR/rv32gc-chiplab.decompiled.dts
LOG=$LOG_DIR/check_dts.log
DEFS=rtl/pkg/rv32gc_defs.vh
mkdir -p "$LOG_DIR"; : > "$LOG"

DTC=${DTC:-$(command -v dtc || true)}
if [ -z "${DTC}" ] || [ ! -x "${DTC}" ]; then
  for c in /home/shorthair/fpga/*/Vivado/bin/dtc /opt/*/bin/dtc; do [ -x "$c" ] && DTC=$c && break; done
fi
if [ -z "${DTC}" ] || [ ! -x "${DTC}" ]; then echo "check_dts: 找不到 dtc（可用 DTC=/path/to/dtc 指定）" >&2; exit 2; fi
echo "dtc = $DTC ($($DTC --version 2>&1 | head -1))" | tee -a "$LOG"

$DTC -I dts -O dtb -o "$DTB"  "$DTS"  >>"$LOG" 2>&1 && echo "[ok] dtc 编译" | tee -a "$LOG" \
  || { echo "[FAIL] dtc 编译失败，见 $LOG" | tee -a "$LOG"; exit 1; }
$DTC -I dtb -O dts -o "$BACK" "$DTB"  >>"$LOG" 2>&1 && echo "[ok] dtc 反编译" | tee -a "$LOG" \
  || { echo "[FAIL] dtc 反编译失败" | tee -a "$LOG"; exit 1; }

python3 - "$BACK" "$DTS" "$DEFS" <<'PY' 2>&1 | tee -a "$LOG"
import re, sys
back, orig, defs = sys.argv[1], sys.argv[2], sys.argv[3]
db = open(back, errors='ignore').read()
do = open(orig, errors='ignore').read()
dd = open(defs, errors='ignore').read()

npass = nfail = 0
def ck(name, cond, detail=""):
    global npass, nfail
    if cond: npass += 1; print(f"  [ok]   {name} {detail}")
    else:    nfail += 1; print(f"  [FAIL] {name} {detail}")

def defnum(nm, default=None):
    m = re.search(r"`define\s+%s\s+32'h([0-9A-Fa-f_]+)" % nm, dd)
    return int(m.group(1).replace('_',''), 16) if m else default

def node_addr(nm):
    m = re.search(r"%s@([0-9a-f]+)" % nm, db)
    return int(m.group(1), 16) if m else None

def regs(nm):
    """返回节点名下所有 reg = <...> 里的 (addr,size) 列表"""
    m = re.search(r"%s@[0-9a-f]+\s*\{(.*?)\n\t\t\};" % nm, db, re.S)
    if not m: return []
    out = []
    for r in re.findall(r"reg = <([^>]*)>", m.group(1)):
        vals = [int(x, 16) for x in re.findall(r"0x[0-9a-f]+", r)]
        for i in range(0, len(vals)-1, 2):
            out.append((vals[i], vals[i+1]))
    return out

print("[2] DTS ↔ rtl/pkg/rv32gc_defs.vh 交叉校验")
ddr_base, ddr_size = defnum('DDR_BASE'), defnum('DDR_SIZE')
xip, alias = defnum('SPI_XIP_BASE'), defnum('SPI_XIP_ALIAS_BASE')
clint, plic = defnum('CLINT_BASE'), defnum('PLIC_BASE')

mem = regs('memory')
ck("DDR 基址 = DDR_BASE", mem and mem[0][0] == ddr_base, f"(dts={mem[0][0]:#x} rtl={ddr_base:#x})" if mem else "(缺 /memory)")
ck("DDR 容量 = DDR_SIZE", mem and mem[0][1] == ddr_size, f"(dts={mem[0][1]:#x} rtl={ddr_size:#x})" if mem else "")
ck("SPI-XIP 窗口基址 = SPI_XIP_BASE", node_addr('flash') == xip, f"(dts={node_addr('flash'):#x} rtl={xip:#x})")
flash_regs = regs('flash')
ck("SPI 别名窗口在 reg 中声明", any(a == alias for a, _ in flash_regs), f"(rtl alias={alias:#x})")
ck("CLINT 基址 = CLINT_BASE", node_addr('clint') == clint, f"(dts={node_addr('clint'):#x} rtl={clint:#x})")
ck("PLIC 基址 = PLIC_BASE", node_addr('plic') == plic, f"(dts={node_addr('plic'):#x} rtl={plic:#x})")

print("[3] 平台事实与硬判据")
ck("UART0 寄存器块 = 0x1FE0_01E0", node_addr('serial') == 0x1FE001E0, f"(dts={node_addr('serial'):#x})")
nand_regs = regs('nand')
ck("NAND 数据口 = 基址 + 0x40", any(a == node_addr('nand') + 0x40 for a, _ in nand_regs))
ck("MMU 声明为 Sv32（mmu-type）", 'mmu-type = "riscv,sv32"' in db)
ck("riscv,ndev = 8（核内 PLIC 的 NSRC）", re.search(r"riscv,ndev = <0x0?8>", db) is not None)
ck("CLINT 声明 M 软件(3)/定时器(7)中断", ('&cpu0_intc 3' in do) and ('&cpu0_intc 7' in do))
ck("PLIC 声明 M(11)/S(9) 外部中断", ('&cpu0_intc 11' in do) and ('&cpu0_intc 9' in do))
ck("CPU 中断控制器存在（cpu-intc）", '"riscv,cpu-intc"' in db)
tb = re.search(r"timebase-frequency = <0x([0-9a-f]+)>", db)
ck("timebase-frequency = 33 MHz（用户拍板上板时钟）", tb and int(tb.group(1),16) == 33000000,
   f"(dts={int(tb.group(1),16) if tb else '缺'})")

# 分区断言：SPI boot ≤1 MiB；NAND 分区总长 = 128 MiB
parts = []
for m in re.finditer(r'label = "([a-z0-9_-]+)"\s*;.*?reg = <0x([0-9a-f]+) 0x([0-9a-f]+)>', db, re.S):
    parts.append((m.group(1), int(m.group(2),16), int(m.group(3),16)))
spi_parts = [p for p in parts if p[0] in ('boot', 'fdt-spare')]
nand_parts = [p for p in parts if p[0] in ('env', 'kernel', 'dtb', 'rootfs')]
boot = next((p for p in spi_parts if p[0] == 'boot'), None)
ck("SPI boot 分区 ≤ 1 MiB（2A-7b 判据）", boot and boot[2] <= 0x100000,
   f"(size={boot[2]:#x})" if boot else "(缺)")
total = sum(p[2] for p in nand_parts)
ck("NAND 分区总长 = 128 MiB", total == 134217728, f"(sum={total})")
ck("NAND env 分区偏移 0 且 256 KiB（U-Boot ENV_OFFSET/ENV_SIZE）",
   any(p[0]=='env' and p[1]==0 and p[2]==0x40000 for p in nand_parts))

print("------------------------------------------------------------")
print(f"CHECK_DTS: {'PASS' if nfail==0 else 'FAIL'} ({npass} ok / {nfail} fail)")
sys.exit(1 if nfail else 0)
PY
