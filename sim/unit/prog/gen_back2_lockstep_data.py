#!/usr/bin/env python3
#==============================================================================
# sim/unit/prog/gen_back2_lockstep_data.py —— 2B-2 锁步 TB 的内嵌数据生成器
#==============================================================================
# 用法：
#   python3 sim/unit/prog/gen_back2_lockstep_data.py > sim/unit/prog/back2_lockstep_data.svh
#
# 每个程序三步（可复现，TB 头注同步登记）：
#   ① 汇编/链接：riscv32-unknown-linux-gnu-gcc -march=<每程序见 PROGS> -mabi=ilp32
#                ★ 不带 C：2A 基线核**不支持"32 bit 指令起始于奇 parcel"**
#                  （fetch_unit.v §4.1 显式限定 `insn_valid_w = insn_valid &
#                    insn_start_lo`，属 2A 已登记的 M2 遗留）；C 混合流会让 2A 侧
#                  永久停在奇 parcel。故三程序一律 `.option norvc`（与
#                  sim/lockstep/prog/lock_hello.S 同一口径）。
#                riscv32-unknown-linux-gnu-ld -T back2_lockstep.ld
#                （Spike 侧另用 back2_lockstep_spike.ld 再链一遍；两脚本各段相对
#                  .text 的偏移**必须逐字节一致**，本脚本对此做 fail-closed 自检）
#   ② 程序映像 ：riscv32-unknown-linux-gnu-objcopy -O verilog  → 逐**字节**（小端）
#                ★ 本工具链的 `-O verilog` 每行 16 个 2 位十六进制**字节**，
#                  不是 32 bit 字！按字节解析再拼字（旧版按字解析 ⇒ 映像整体错位）。
#   ③ 黄金轨迹 ：spike --pc=0x80000000 --isa=rv32imac_zicsr --log-commits --log=<f>
#                （`--pc` 跳过 Spike 内置 boot ROM —— 与 sim/lockstep 同法）
#                的 `core 0: <priv> 0x<pc> (0x<insn>) …` 行 ⇒ **架构提交 PC 序列**
#                （程序以 `j .` 自跳转结尾：检测到 PC 连续重复即判定程序结束，
#                 该条**计入**；序列 = 程序全部提交指令）
#
# 输出（被 sim/unit/tb_back2_lockstep.sv `include）：
#   localparam P_NUM / P_IMG_MAX / P_GOLD_MAX / P0_GOLD_N .. P5_GOLD_N
#   reg [31:0] IMG[] / GOLD[]（PC 轨迹） / GREG_RD[]+GREG_WD[]（写回寄存器轨迹）
#   reg [31:0] IMG  [0:P_NUM*P_IMG_MAX-1];   按程序槽位排布（未用槽填 nop=0x00000013）
#   reg [31:0] GOLD [0:P_NUM*P_GOLD_MAX-1];  同上
#
# ★ 本脚本是"黄金轨迹来源"的可复现证据：任何一步不一致都会被本脚本的自检或
#   TB 的逐条比对打出来。自检全部 fail-closed（非零退出，绝不输出"看起来成功"的内容）。
#==============================================================================
import os
import re
import subprocess
import sys

BASE = 0x80000000          # 两侧统一链接基址（仿真布局；2A 锁步/arch-test 既定口径）
SPIKE_BASE = 0x80000000    # Spike 侧同址 ⇒ 黄金轨迹无需重定位（保留参数以显式化口径）
IMG_MAX = 2048
GOLD_MAX = 1024
#   ★ 每个程序带自己的 `-march` 与 Spike `--isa`（2B-4 新增 p4_fpu 需要 F/D）：
#     整数程序保持 `rv32ima_zicsr`（**逐字节沿用 2B-3 的黄金轨迹口径，不受新增影响**），
#     FP 程序用 `rv32imafd_zicsr`（**不带 C**：`.option norvc` 已禁用压缩指令，
#     `-mabi=ilp32` 只是"不用 FP 寄存器传参"，不影响手写汇编）。
PROGS = [
    ("back2_p1_int.S",     "P1", "rv32ima_zicsr",   "rv32imac_zicsr"),
    ("back2_p2_branch.S",  "P2", "rv32ima_zicsr",   "rv32imac_zicsr"),
    ("back2_p3_memcsr.S",  "P3", "rv32ima_zicsr",   "rv32imac_zicsr"),
    ("back2_p4_fpu.S",     "P4", "rv32imafd_zicsr", "rv32imafdc_zicsr"),
    ("back2_p5_mdu.S",     "P5", "rv32ima_zicsr",   "rv32imac_zicsr"),
    ("back2_p6_l1d.S",     "P6", "rv32ima_zicsr",   "rv32imac_zicsr"),
    #   ★ 2B-4 第 4a 段：特权/陷阱路径（ecall / 非法指令 / ebreak → mtvec → mret）
    ("back2_p7_trap.S",    "P7", "rv32ima_zicsr",   "rv32imac_zicsr"),
    #   ★ 2B-4 第 4a 段：核内 CLINT + MTI 中断。**仅映像、无黄金轨迹**（第 5 个元素
    #     = True）：mtime 自由计数 ⇒ "取中断的拍数"依赖微架构时序，Spike 与本核不可
    #     逐条比；且本 SoC 的 CLINT 在 0x1F00_0000（Spike 默认在 0x0200_0000）⇒
    #     Spike 跑本程序根本不会收到 MTI。判据改由 TB 的 C8'（自记录+硬编码期望）。
    ("back2_p8_int.S",     "P8", "rv32ima_zicsr",   "rv32imac_zicsr", True),
    #   ★ 2B-4 第 4b 段（第一步）：**mtvec 向量模式（MODE=1）**实测——
    #     三条异常落三个不同槽（cause 11/2/3 ⇒ base+44/+8/+12），槽标记进写回轨迹
    #     ⇒ 向量化目标算错必被黄金比对抓住。有 Spike 黄金（M 模式陷阱语义可比）。
    ("back2_p9_trapvec.S", "P9", "rv32ima_zicsr",   "rv32imac_zicsr"),
    #   ★ 2B-4 第 4b-1 段：**CSR 读写轨迹**（替换 `b2_csr`→`csr_file` 的"先立后用"判据）——
    #     只使用两种实现都有的 CSR（mscratch/mepc/mtvec/mcause/mtval/mie/mip/mstatus），
    #     覆盖 csrw/csrr/csrrw/csrrs/csrrc + **立即数形式**（D2 回归保护），
    #     全部读回值进写回轨迹 ⇒ 与 Spike 黄金逐条比。
    ("back2_p10_csr.S",    "P10", "rv32ima_zicsr",  "rv32imac_zicsr"),
]
HERE = os.path.dirname(os.path.abspath(__file__))
GCC = "riscv32-unknown-linux-gnu-gcc"
LD  = "riscv32-unknown-linux-gnu-ld"
OBJCOPY = "riscv32-unknown-linux-gnu-objcopy"
SPIKE = "/opt/riscv/bin/spike"
SPIKE_INSN_CAP = 200000     # 兜底：程序异常（不写 tohost / 不自跳转）时也必须终止


def die(msg: str) -> None:
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def image_bytes(elf, tag):
    """ELF → {byte_addr: byte}（objcopy -O verilog 的 `@<字节地址>` + 十六进制字节流）"""
    hexf = "/tmp/back2_%s.hex" % tag
    run([OBJCOPY, "-O", "verilog", elf, hexf])
    by = {}
    cur = None
    with open(hexf) as f:
        for line in f:
            toks = line.split()
            if not toks:
                continue
            if toks[0].startswith("@"):
                cur = int(toks[0][1:], 16)
                toks = toks[1:]
                if cur is None:
                    die("%s: `@` 段之前出现数据" % elf)
            for t in toks:
                if len(t) > 2:
                    die("%s: 期望 2 位十六进制字节，实得 %r（objcopy 输出格式变了？）"
                        % (elf, t))
                by[cur] = int(t, 16) & 0xFF
                cur += 1
    if not by:
        die("%s: objcopy 未产出任何字节" % elf)
    return by


def words_from_bytes(by, lo, hi):
    """字节映射 → 连续 32 bit 字列表（小端）
    缺字节按 0x00 补（= 二进制文件语义；本工具链 .text 末尾可能停在 2 字节压缩指令
    的中间 ⇒ 末字只有 2 字节有效，高半必须补 0 而不是报错）。"""
    out = []
    for a in range(lo, ((hi - lo + 3) // 4) * 4 + lo, 4):
        w = 0
        for k in range(4):
            w |= by.get(a + k, 0) << (8 * k)
        out.append(w)
    return out


def golden_regs(elf, tag):
    """Spike --log-commits → 逐条提交的 (写回寄存器号, 写回值)（供数据正确性比对）
    · 行格式：`core 0: 3 0x<pc> (0x<insn>) [xN|fN] 0x<val> ...`；无写回则该条记 (0,0)
    · 与 golden_pcs 的**同一批行**（同一次 Spike 运行），故下标一一对应"""
    logf = "/tmp/back2_%s.spike.log" % tag
    pat  = re.compile(r"^core\s+\d+:\s+\S+\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)"
                      r"(?:\s+([xf])(\d+)\s+0x([0-9a-fA-F]+))?")
    pcs, rds, wds = [], [], []
    prev = None
    with open(logf) as f:
        for line in f:
            m = pat.match(line)
            if not m:
                continue
            pc = int(m.group(1), 16)
            if prev is not None and pc == prev:      # `j .` 自旋：与 golden_pcs 同口径
                break
            prev = pc
            pcs.append(pc)
            if m.group(3) is None:
                rds.append(0); wds.append(0)
            else:
                rds.append(int(m.group(4)) & 0x1F)
                wds.append(int(m.group(5), 16) & 0xFFFFFFFF)
    return pcs, rds, wds


def golden_pcs(elf, tag, isa):
    """Spike --log-commits → 架构提交 PC 序列（到"PC 连续重复"为止，重复那条计入一次）"""
    logf = "/tmp/back2_%s.spike.log" % tag
    run([SPIKE, "--pc=0x%08x" % SPIKE_BASE, "--isa=" + isa,
         "--instructions=%d" % SPIKE_INSN_CAP,
         "--log-commits", "--log=" + logf, elf])
    pat = re.compile(r"^core\s+\d+:\s+\S+\s+0x([0-9a-fA-F]+)\s+\(")
    pcs = []
    with open(logf) as f:
        for line in f:
            m = pat.match(line)
            if not m:
                continue
            pc = int(m.group(1), 16)
            if pcs and pcs[-1] == pc:       # `j .` 自跳转 ⇒ 程序结束（该条已计入）
                break
            pcs.append(pc)
    if not pcs:
        die("%s: Spike 未产出任何提交行（--pc/--isa 口径？）" % elf)
    if pcs[0] != SPIKE_BASE:
        die("%s: 黄金首条 PC=0x%08x ≠ 入口 0x%08x" % (elf, pcs[0], SPIKE_BASE))
    if len(pcs) >= SPIKE_INSN_CAP:
        die("%s: 黄金序列达到 --instructions 上限 %d（程序没停？）" % (elf, SPIKE_INSN_CAP))
    return pcs


def main() -> int:
    out = []
    img_all = []
    gold_all = []
    reg_rd_all = []
    reg_wd_all = []
    gold_n = []
    for fname, tag, march, isa, *prog_opt in PROGS:
        #   `prog_opt[0] = True` ⇒ 只出映像、不出黄金（见 PROGS 处 p8 的说明）
        no_gold = bool(prog_opt and prog_opt[0])
        src = os.path.join(HERE, fname)
        obj = "/tmp/back2_%s.o" % tag
        elf = "/tmp/back2_%s.elf" % tag
        run([GCC, "-march=" + march, "-mabi=ilp32", "-nostdlib",
             "-fno-pic", "-mno-relax", "-c", src, "-o", obj])
        run([LD, "--no-relax", "-T", os.path.join(HERE, "back2_lockstep.ld"), "-o", elf, obj])
        by = image_bytes(elf, tag)
        if not no_gold:
            elf_sp = "/tmp/back2_%s_spike.elf" % tag
            run([LD, "--no-relax", "-T", os.path.join(HERE, "back2_lockstep_spike.ld"),
                 "-o", elf_sp, obj])
            by_sp = image_bytes(elf_sp, tag)
            # ---- 自检①：两次链接的 .text 逐字节相同（否则黄金轨迹与 DUT 映像不同源）----
            for a, b in by.items():
                if (a - BASE) < 0x1000 and by_sp.get(a - BASE + SPIKE_BASE) != b:
                    die("%s .text 在两次链接间不一致 @0x%x（两 .ld 的相对段偏移不同？）"
                        % (fname, a))
        # ---- 自检②：.text 必须从 BASE 起连续、且映像不越界 ----
        if BASE not in by:
            die("%s: 映像不含 BASE=0x%x（入口不在 .text 首？）" % (fname, BASE))
        text_end = BASE
        while text_end in by:
            text_end += 1
        hi = max(by) + 1
        n_w = (hi - BASE + 3) // 4
        words = words_from_bytes(by, BASE, hi)
        if no_gold:
            #   ★ "仅映像"程序（p8_int）：跳过 Spike（时序相关 + CLINT 地址不同源）
            pcs, rds, wds = [], [], []
            sys.stderr.write("%s: **仅映像**（无黄金轨迹；判据见 TB 的 C8'）\n" % fname)
        else:
            pcs = golden_pcs(elf_sp, tag, isa)
            _pcs2, rds, wds = golden_regs(elf_sp, tag)
            #   ★ 自检④：两次解析必须逐条对齐（同一次 Spike 运行的两遍解析）
            if (len(_pcs2) != len(pcs)) or any(a != b for a, b in zip(_pcs2, pcs)):
                die("%s: 黄金 PC 轨迹两次解析不一致（%d vs %d）—— 解析器有问题"
                    % (fname, len(_pcs2), len(pcs)))
            # ---- 自检③：黄金轨迹重定位（本口径下恒等）后就落在 .text 范围内 ----
            pcs = [p - SPIKE_BASE + BASE for p in pcs]
            if max(pcs) >= text_end:
                die("%s: 黄金轨迹 PC 0x%x 越出 .text 末 0x%x（映像/轨迹不同源？）"
                    % (fname, max(pcs), text_end))
        if n_w > IMG_MAX:
            die("%s: 映像 %d 字 > IMG_MAX %d" % (fname, n_w, IMG_MAX))
        if len(pcs) > GOLD_MAX:
            die("%s: 黄金 %d 条 > GOLD_MAX %d" % (fname, len(pcs), GOLD_MAX))
        img = words + [0x00000013] * (IMG_MAX - n_w)
        gold_all += pcs + [0] * (GOLD_MAX - len(pcs))
        img_all += img
        gold_all += []          # （占位：GOLD 已在上面拼接，寄存器轨迹单独输出）
        reg_rd_all += rds + [0] * (GOLD_MAX - len(rds))
        reg_wd_all += wds + [0] * (GOLD_MAX - len(wds))
        gold_n.append(len(pcs))
        if not no_gold:
            sys.stderr.write("%s: img=%d words (0x%x..0x%x), golden=%d insns, last_pc=0x%x\n"
                             % (fname, n_w, BASE, hi, gold_n[-1], pcs[-1]))
        else:
            sys.stderr.write("%s: img=%d words (0x%x..0x%x)\n" % (fname, n_w, BASE, hi))

    out.append("// 本文件由 sim/unit/prog/gen_back2_lockstep_data.py 生成，请勿手改")
    out.append("// 真源：sim/unit/prog/back2_p{1..5}_*.S ＋ back2_lockstep{,_spike}.ld ＋ Spike --log-commits")
    out.append("localparam integer P_NUM      = %d;" % len(PROGS))
    out.append("localparam integer P_IMG_MAX  = %d;" % IMG_MAX)
    out.append("localparam integer P_GOLD_MAX = %d;" % GOLD_MAX)
    for i, n in enumerate(gold_n):
        out.append("localparam integer P%d_GOLD_N = %d;" % (i, n))
    out.append("reg [31:0] IMG  [0:P_NUM*P_IMG_MAX-1];")
    out.append("reg [31:0] GOLD [0:P_NUM*P_GOLD_MAX-1];")
    out.append("// 逐条提交的写回寄存器号/写回值（数据正确性比对；与 GOLD 同下标）")
    out.append("reg [4:0]  GREG_RD [0:P_NUM*P_GOLD_MAX-1];")
    out.append("reg [31:0] GREG_WD [0:P_NUM*P_GOLD_MAX-1];")
    out.append("task automatic load_back2_data;")
    out.append("    begin")
    for i, w in enumerate(img_all):
        out.append("        IMG[%d] = 32'h%08x;" % (i, w))
    for i, p in enumerate(gold_all):
        out.append("        GOLD[%d] = 32'h%08x;" % (i, p))
    for i, r in enumerate(reg_rd_all):
        out.append("        GREG_RD[%d] = 5'd%d;" % (i, r))
    for i, w in enumerate(reg_wd_all):
        out.append("        GREG_WD[%d] = 32'h%08x;" % (i, w))
    out.append("    end")
    out.append("endtask")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
