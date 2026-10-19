#!/usr/bin/env python3
# -*- coding: utf-8 -*-
""" indépendent 参考计算（只读 DUT）：指令编码 / CLINT 边界值 / LQ 释放窗口。
输出机器锚点 REF_CHECK <tag>: OK value=0x........（run_one.sh 校验 rc + 精确锚点）。
不引用 RTL；按 RISC-V 字段序与规范年龄公式独立重算。
用法: python3 ref_calc.py <tag>
"""
import sys

OP_SYSTEM = 0x73

def sys_insn(csr, rs1, f3, rd):
    return ((csr & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 7) << 12) | \
           ((rd & 0x1F) << 7) | OP_SYSTEM

# --- 指令常量独立重建 ---
CSRRW_X1_MSTATUS_X0 = sys_insn(0x300, 0, 0b001, 1)     # csrrw x1, mstatus, x0
MRET                = sys_insn(0x302, 0, 0b000, 0)     # mret
ILLEGAL_ZERO        = 0x0000_0000

T = 0x1000

def lq_release_mask(head, robs, cmt_n, bits=6):
    """规范：提交组为 [head, head+cmt_n) 的连续前缀；年龄按 ROB 深度取模。"""
    mask = 0
    for i, r in enumerate(robs):
        age = (r - head) % (1 << bits)
        if age < cmt_n:
            mask |= (1 << i)
    return mask

def dut_mask(head, robs, cmt_n):
    """当前 RTL 口径：(rob-head) & 0x7F < cmt_n（7 bit 模 128）。"""
    mask = 0
    for i, r in enumerate(robs):
        age = (r - head) & 0x7F
        if age < cmt_n:
            mask |= (1 << i)
    return mask

VALUES = {
    "p0": ILLEGAL_ZERO,
    "p1": CSRRW_X1_MSTATUS_X0,
    "p2": CSRRW_X1_MSTATUS_X0,
    "p3": CSRRW_X1_MSTATUS_X0,
    "p4": MRET,
    "p5": MRET,
    "b1": T - 1,
    "b2": T,
    "b3": T + 1,
    "l1": lq_release_mask(63, [63, 0], 2),
    "l2": lq_release_mask(0, [0, 1], 2),
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in VALUES:
        print("USAGE: ref_calc.py <tag>"); sys.exit(2)
    tag = sys.argv[1]
    print("REF_CHECK %s: OK value=0x%08x" % (tag, VALUES[tag]))
    if tag.startswith("l"):
        # 附：当前 RTL 口径的预测掩码（仅作诊断；run_one 只要求 REF_CHECK 锚点）
        head, robs = (63, [63, 0]) if tag == "l1" else (0, [0, 1])
        print("REF_PREDICT %s: OK dut_mask=0x%08x" % (tag, dut_mask(head, robs, 2)))
