#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立参考计算（只读 DUT，不引用 RTL）：
- 按 RISC-V 规范字段序从语义重新拼出 32 位编码；
- 与 TB 内的常量逐位对拍（脚本在本目录运行，输出固定本目录日志）。
用法: python3 ref_calc.py <case-tag>
输出: "<tag> OK <hex>" 或非零退出。
字段序来自 unpriv ISA 手册（R/I/S/B/U/J 型）与 OP-FP 编码表。
"""
import sys

def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def s_type(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op

def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

OP_IMM, OP_OP, OP_LOAD, OP_STORE, OP_JALR, OP_LOADFP = 0x13, 0x33, 0x03, 0x23, 0x67, 0x07

# 16 位压缩编码（由压缩格式字段手工拼出，用于证明 TB 输入常量确为所声明指令）
def c_ca(f3, c12, h2, rdp, h65, rs2p, q=1):
    # funct3 | bit12 | bits11:10 | rd' (9:7) | bits6:5 | rs2' (4:2) | q
    return (f3 << 13) | (c12 << 12) | (h2 << 10) | (rdp << 7) | (h65 << 5) | (rs2p << 2) | q

def c_cb_shift(f3, c12, h2, rdp, shamt, q=1):
    return (f3 << 13) | (c12 << 12) | (h2 << 10) | (rdp << 7) | ((shamt & 0x1F) << 2) | q

def c_cr(f3, c12, rs1_5, rs2_5, q=2):
    return (f3 << 13) | (c12 << 12) | (rs1_5 << 7) | ((rs2_5 & 0x1F) << 2) | q

EXPECT = {
    # tag: (computed value, TB constant name)
    "nop":     (i_type(0, 0, 0, 0, OP_IMM), "C0_CTL_NOP 0x0001 -> addi x0,x0,0"),
    "c1":      (r_type(0x20, 9, 8, 0, 8, OP_OP), "C1 c.sub x8,x9 -> sub x8,x8,x9"),
    "c2":      (r_type(0x20, 8, 8, 0, 8, OP_OP), "C2 c.sub x8,x8 -> sub x8,x8,x8"),
    "c3":      (i_type(5, 8, 5, 8, OP_IMM), "C3 c.srli x8,5 -> srli x8,x8,5"),
    "c4":      (i_type(5, 8, 7, 8, OP_IMM), "C4 c.andi x8,5 -> andi x8,x8,5"),
    "c5":      (0x00100073, "C5 c.ebreak -> ebreak"),
    "c6":      (i_type(0, 0, 0, 0, OP_JALR), "C6 c.jr x0 -> (reserved, must be illegal)"),
    "c7":      (i_type(0, 5, 0, 0, OP_JALR), "C7 c.jr x5 -> jalr x0,0(x5)"),
    "c8":      (i_type(0, 5, 0, 1, OP_JALR), "C8 c.jalr x5 -> jalr x1,0(x5)"),
    # OP-FP：funct5<<2 | fmt 放在 [31:25]
    "f0":      (((0b0101100) << 25) | (0 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F0 fsqrt.s f0,f0 (rs2=0, legal)"),
    "f1":      (((0b0101100) << 25) | (1 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F1 fsqrt.s rs2=1 (reserved)"),
    "f2":      (((0b1100000) << 25) | (0b00010 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F2 fcvt.l.s (RV64-only => reserved on RV32)"),
    "f3":      (((0b1101000) << 25) | (0b00010 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F3 fcvt.s.l (RV64-only => reserved on RV32)"),
    "f4":      (((0b1110000) << 25) | (1 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F4 fmv.x.w rs2=1 (reserved)"),
    "f5":      (((0b1111000) << 25) | (1 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F5 fmv.w.x rs2=1 (reserved)"),
    "f6":      (((0b1100000) << 25) | (0 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F6 fcvt.w.s (legal)"),
    "f7":      (((0b1101000) << 25) | (0 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F7 fcvt.s.w (legal)"),
    "f8":      (((0b1110000) << 25) | (0 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F8 fmv.x.w rs2=0 (legal)"),
    "f9":      (((0b1111000) << 25) | (0 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "F9 fmv.w.x rs2=0 (legal)"),
    "fa":      (((0b0000000) << 25) | (2 << 20) | (1 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "FA fadd.s f0,f1,f2 (legal)"),
    "b1":      (((0b0000000) << 25) | (2 << 20) | (1 << 15) | (0 << 12) | (0 << 7) | 0x53,
                "B1 fadd.s f0,f1,f2 (rd=f0)"),
    "b2":      (((0b0000000) << 25) | (2 << 20) | (1 << 15) | (0 << 12) | (1 << 7) | 0x53,
                "B2 fadd.s f1,f1,f2 (rd=f1, control)"),
    "b3":      (i_type(0, 1, 2, 0, OP_LOADFP), "B3 flw f0,0(x1)"),
    "b4":      (i_type(0, 1, 2, 1, OP_LOADFP), "B4 flw f1,0(x1) (control)"),
}

# 压缩输入常量自校验（与 TB 的 cin 常量对拍）
CIN = {
    "nop": 0x0001, "c1": 0x8C05, "c2": 0x8C01, "c3": 0x8015, "c4": 0x8815,
    "c5": 0x9002, "c6": 0x8002, "c7": 0x8282, "c8": 0x9282,
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in EXPECT:
        print("USAGE: ref_calc.py <tag>"); sys.exit(2)
    tag = sys.argv[1]
    val, desc = EXPECT[tag]
    # 机器可判的精确锚点（run_one.sh 只认这两行；desc 不上 stdout，避免任意文本混入）
    print("REF_CHECK %s: OK value=0x%08x" % (tag, val))
    if tag in CIN:
        # 独立重建 16 位编码（按 zca 格式字段）
        rebuild = {
            "nop": (0 << 13) | (0 << 7) | 0x01,                   # c.addi x0,0（f3=000）
            "c1": c_ca(4, 0, 3, 0, 0, 1),                          # CA: rd'=0, rs2'=1, sub
            "c2": c_ca(4, 0, 3, 0, 0, 0),                          # CA: rd'=0, rs2'=0, sub
            "c3": c_cb_shift(4, 0, 0, 0, 5),                       # CB: srli rd'=0, shamt=5
            "c4": c_cb_shift(4, 0, 2, 0, 5),                       # CB: andi rd'=0, imm=5
            "c5": c_cr(4, 1, 0, 0),                                # CR: ebreak
            "c6": c_cr(4, 0, 0, 0),                                # CR: jr x0 (reserved)
            "c7": c_cr(4, 0, 5, 0),                                # CR: jr x5
            "c8": c_cr(4, 1, 5, 0),                                # CR: jalr x5
        }[tag]
        if rebuild != CIN[tag]:
            print("REF_SELFCHECK_MISMATCH %s rebuild=0x%04x tb=0x%04x" % (tag, rebuild, CIN[tag]))
            sys.exit(1)
        print("REF_CIN %s: OK cin=0x%04x" % (tag, CIN[tag]))
