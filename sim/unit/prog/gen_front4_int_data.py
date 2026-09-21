#!/usr/bin/env python3
#==============================================================================
# sim/unit/prog/gen_front4_int_data.py —— 由 ELF + Spike 日志生成 TB 内嵌数据
#==============================================================================
# 用法（真源命令见 sim/unit/prog/front4_int.S 头注）：
#   python3 sim/unit/prog/gen_front4_int_data.py <elf> <spike-log> > sim/unit/prog/front4_int_data.svh
#
# 输入：
#   ① ELF            —— 用 `objcopy -O verilog` 临时转出"地址 + 字节流"（小端、按地址递增）；
#   ② Spike 日志     —— `--log-commits --log=<file>` 的行，形如：
#                       `core   0: 3 0x80000000 (0x80002137) x2  0x80002000`
#                       提取**架构提交 PC 序列** = 黄金轨迹（TB 逐条比对）。
#
# 输出（被 sim/unit/tb_front4_integration.sv `include）：
#   · task automatic load_front4_int_image;  … 逐字写入 TB 的 DDR 存储体（wr32）
#   · task automatic load_front4_int_golden; … 填充黄金 PC 数组 g_pc[0..g_npc-1]
#
# ★ 该脚本是"黄金轨迹来源"的可复现证据：TB 头注里写明 ① 程序源 ② 三条命令
#   ③ 本脚本；任何一条不一致都会被 TB 的逐条比对打出来（0 分歧判据）。
#==============================================================================
import re
import subprocess
import sys

def main() -> int:
    if len(sys.argv) != 3:
        print("usage: gen_front4_int_data.py <elf> <spike-log>", file=sys.stderr)
        return 2
    elf, logp = sys.argv[1], sys.argv[2]

    # ---- 1. ELF → (字节流形式的) 地址-数据 ----
    hexpath = "/tmp/front4_int_gen.hex"
    subprocess.run(["riscv32-unknown-linux-gnu-objcopy", "-O", "verilog", elf, hexpath],
                   check=True)
    words = {}           # byte_addr(4 对齐) -> 32bit
    cur = None
    byte_idx = 0
    with open(hexpath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if line.startswith("@"):
                cur = int(line[1:], 16)
                byte_idx = 0
                continue
            for tok in line.split():
                b = int(tok, 16) & 0xFF
                a = cur + byte_idx
                w = a & ~3
                words[w] = words.get(w, 0) | (b << (8 * (a & 3)))
                byte_idx += 1

    # ---- 2. Spike 日志 → 黄金 PC 序列 ----
    pat = re.compile(r"^core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)")
    pcs = []
    with open(logp, "r", errors="replace") as f:
        for line in f:
            m = pat.match(line)
            if m:
                pcs.append(int(m.group(1), 16))

    # ---- 3. 输出 .svh ----
    out = []
    out.append("// ==== 自动生成（不要手改）：sim/unit/prog/gen_front4_int_data.py ====")
    out.append("// 源：sim/unit/prog/front4_int.S（+ front4_int.ld）+ Spike --log-commits 黄金轨迹")
    out.append("// 程序映像：%d 个字；黄金轨迹：%d 条提交 PC" % (len(words), len(pcs)))
    out.append("")
    out.append("task automatic load_front4_int_image;")
    out.append("    begin")
    for a in sorted(words):
        out.append("        wr32(32'h%08x, 32'h%08x);" % (a, words[a]))
    out.append("    end")
    out.append("endtask")
    out.append("")
    out.append("task automatic load_front4_int_golden;")
    out.append("    integer gi;")
    out.append("    begin")
    out.append("        g_npc = %d;" % len(pcs))
    out.append("        for (gi = 0; gi < g_npc; gi = gi + 1) g_pc[gi] = 32'h0;")
    for i, pc in enumerate(pcs):
        out.append("        g_pc[%d] = 32'h%08x;" % (i, pc))
    out.append("    end")
    out.append("endtask")
    out.append("")
    print("\n".join(out))
    return 0

if __name__ == "__main__":
    sys.exit(main())
