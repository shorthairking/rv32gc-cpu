#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_decoder_vectors.py —— rv32_decoder / rv32_imm_gen 单元测试向量生成器（独立小工具）

设计要点（**绝不使用被测 decoder 的输出作期望值**）：
  1. 期望值来自本文件中**按 docs/design/spec/02-uop-and-decode.md 手写**的参考模型
     （decode32 / rvc_expand）以及 HAND 手写期望表；RTL 只是被测对象。
  2. ctrl 的位域位置与字段取值**从 rtl/pkg/rv32gc_defs.vh 解析宏**得到（唯一真源），
     并与 spec/02 §2 的表格逐字段核对（不一致直接报错）；缺宏会列出。
  3. 32 位机器码由 riscv32-unknown-linux-gnu-as 汇编 .S 得到，再用 objdump 反汇编，
     核对「汇编文本 ↔ 机器码」一致（HAND 表与模型也互相核对）。
  4. RVC 的 16 位编码由本脚本按手册位域**手工拼出**，并与汇编器对同一 c.* 助记符的
     压缩编码逐位比对；RVC 展开结果再与汇编器给出的 32 位等价指令机器码逐位比对
     （即 spec/02 §7.2「RVC 与等价 32 位指令必须产生完全相同的 uop」的机器码级验证）。

产物：sim/tests/unit/decoder_vectors.vh（宏表 + 可读注释表）

用法：python3 sim/tests/unit/gen_decoder_vectors.py [--out-dir DIR] [--keep]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

TOOL_PREFIX = "/opt/riscv/bin/riscv32-unknown-linux-gnu-"
AS = TOOL_PREFIX + "as"
OBJDUMP = TOOL_PREFIX + "objdump"
MARCH = "rv32gc_zicsr_zifencei_zicbom_zicboz"
MABI = "ilp32d"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DEFS = os.path.join(ROOT, "rtl", "pkg", "rv32gc_defs.vh")

# =============================================================================
# 1. 解析 rv32gc_defs.vh 宏
# =============================================================================


def parse_defs(path):
    macros = {}
    rx = re.compile(r"^\s*`define\s+([A-Za-z_]\w*)\s+(.+?)\s*(?://.*)?$")
    for line in open(path, encoding="utf-8"):
        m = rx.match(line)
        if not m:
            continue
        name, val = m.group(1), m.group(2).strip()
        vm = re.match(r"^(\d+)'([bdho])([0-9a-fA-F_xzXZ]+)$", val)
        if vm:
            base = {"b": 2, "d": 10, "h": 16, "o": 8}[vm.group(2)]
            try:
                macros[name] = int(vm.group(3).replace("_", ""), base)
            except ValueError:
                pass
        elif re.match(r"^\d+$", val):
            macros[name] = int(val)
    return macros


MACROS = parse_defs(DEFS)


def M(name):
    if name not in MACROS:
        raise KeyError("rv32gc_defs.vh 缺少宏 `%s" % name)
    return MACROS[name]


# =============================================================================
# 2. spec/02 §2 位域表（LSB→MSB）+ 宏一致性核对
# =============================================================================

FIELDS = [
    ("op_class", 3, {"OP_ALU": 0, "OP_BRU": 1, "OP_MDU": 2, "OP_LSU": 3,
                     "OP_FPU": 4, "OP_CSR": 5, "OP_SYS": 6, "OP_NOP": 7}),
    ("alu_op", 5, {"ALU_ADD": 0, "ALU_SUB": 1, "ALU_SLL": 2, "ALU_SLT": 3, "ALU_SLTU": 4,
                   "ALU_XOR": 5, "ALU_SRL": 6, "ALU_SRA": 7, "ALU_OR": 8, "ALU_AND": 9}),
    ("alu_a_sel", 2, {"ALU_A_RS1": 0, "ALU_A_PC": 1, "ALU_A_ZERO": 2}),
    ("alu_b_sel", 3, {"ALU_B_RS2": 0, "ALU_B_IMM": 1, "ALU_B_CONST4": 2,
                      "ALU_B_ZERO": 3, "ALU_B_SHAMT": 4}),
    ("br_type", 3, {"BR_NONE": 0, "BR_EQ": 1, "BR_NE": 2, "BR_LT": 3,
                    "BR_GE": 4, "BR_LTU": 5, "BR_GEU": 6}),
    ("br_flags", 4, {"BRF_RET": 3, "BRF_CALL": 2, "BRF_JALR": 1, "BRF_JAL": 0}),
    ("mdu_op", 3, {"MDU_MUL": 0, "MDU_MULH": 1, "MDU_MULHSU": 2, "MDU_MULHU": 3,
                   "MDU_DIV": 4, "MDU_DIVU": 5, "MDU_REM": 6, "MDU_REMU": 7}),
    ("mem_op", 3, {"MEM_NONE": 0, "MEM_LOAD": 1, "MEM_STORE": 2,
                   "MEM_LR": 3, "MEM_SC": 4, "MEM_AMO": 5}),
    ("mem_size", 2, {"MSZ_BYTE": 0, "MSZ_HALF": 1, "MSZ_WORD": 2}),
    ("mem_flags", 2, {"MF_FP": 1, "MF_UNSIGNED": 0}),
    ("amo_flags", 2, {"AMOF_RL": 1, "AMOF_AQ": 0}),
    ("amo_op", 5, {"AMO_ADD": 0x00, "AMO_SWAP": 0x01, "AMO_XOR": 0x04, "AMO_OR": 0x08,
                   "AMO_AND": 0x0C, "AMO_MIN": 0x10, "AMO_MAX": 0x14,
                   "AMO_MINU": 0x18, "AMO_MAXU": 0x1C}),
    ("fp_op", 6, {}),
    ("fp_fmt", 2, {}),
    ("fp_rm", 3, {}),
    ("csr_op", 2, {"CSR_NONE": 0, "CSR_RW": 1, "CSR_RS": 2, "CSR_RC": 3}),
    ("sys_op", 3, {"SYS_ECALL": 0, "SYS_EBREAK": 1, "SYS_MRET": 2, "SYS_SRET": 3,
                   "SYS_WFI": 4, "SYS_FENCE": 5, "SYS_FENCE_I": 6, "SYS_SFENCE_VMA": 7}),
    ("csr_imm", 1, {}),
    ("cbo_op", 2, {"CBO_INVAL": 0, "CBO_CLEAN": 1, "CBO_FLUSH": 2, "CBO_ZERO": 3}),
    ("wb_sel", 3, {"WB_ALU": 0, "WB_MEM": 1, "WB_PC4": 2, "WB_CSR": 3,
                   "WB_FP": 4, "WB_ZERO": 5}),
    ("rd_wen", 1, {}),
    ("rd_is_fp", 1, {}),
    ("use_rs1", 1, {}),
    ("use_rs2", 1, {}),
    ("excp_valid", 1, {}),
    ("excp_cause", 4, {"DEXC_NONE": 0, "DEXC_ILLEGAL": 2, "DEXC_BREAK": 3,
                       "DEXC_ECALL_U": 8, "DEXC_ECALL_S": 9, "DEXC_ECALL_M": 11}),
    ("is_fence", 1, {}),
    ("is_fencei", 1, {}),
    ("is_sfence", 1, {}),
    ("is_serial", 1, {}),
    ("use_rs3", 1, {}),
]

FIELD_POS = {}
FIELD_ISSUES = []
_lo = 0
for _name, _w, _vals in FIELDS:
    FIELD_POS[_name] = (_lo, _w)
    _hi = _lo + _w - 1
    for _mn, _expect, _kind in ((("CTRL_%s_H" % _name.upper()), _hi, "H"),
                                (("CTRL_%s_W" % _name.upper()), _w, "W")):
        if _mn not in MACROS:
            FIELD_ISSUES.append("缺宏 `%s" % _mn)
        elif MACROS[_mn] != _expect:
            FIELD_ISSUES.append("宏 `%s=%d 与 spec/02 的 %s=%d 不符"
                                % (_mn, MACROS[_mn], _kind, _expect))
    for _mn, _v in _vals.items():
        if _mn not in MACROS:
            FIELD_ISSUES.append("缺宏 `%s（spec/02 §2 需要）" % _mn)
        elif MACROS[_mn] != _v:
            FIELD_ISSUES.append("宏 `%s=%d 与 spec/02 的 %d 不符" % (_mn, MACROS[_mn], _v))
    _lo += _w

CTRL_W = _lo
assert CTRL_W == 73, "ctrl 位宽 %d != 73" % CTRL_W
FIELD_NAMES = [f[0] for f in FIELDS]


def fv(name, val):
    return M(val) if isinstance(val, str) else int(val)


def pack_ctrl(f):
    v = 0
    for name, _w, _vals in FIELDS:
        v |= (fv(name, f.get(name, 0)) & ((1 << FIELD_POS[name][1]) - 1)) << FIELD_POS[name][0]
    return v


def ILLEGAL_MASK():
    """非法指令只比对 ctrl 中 RTL 明确强制的字段（其余输出规格定义为不关心）"""
    m = 0
    for nm in ("excp_valid", "excp_cause", "op_class", "rd_wen",
               "use_rs1", "use_rs2", "use_rs3"):
        lo, wd = FIELD_POS[nm]
        m |= ((1 << wd) - 1) << lo
    return m


# =============================================================================
# 3. 参考模型（按 spec/02 手写，与被测 RTL 无关）
# =============================================================================


def sext(val, bits):
    m = 1 << (bits - 1)
    return (val ^ m) - m


def imm_of(kind, w):
    """spec/02 §5 立即数生成"""
    if kind == "I":
        return sext((w >> 20) & 0xFFF, 12) & 0xFFFFFFFF
    if kind == "S":
        return sext(((w >> 25) << 5) | ((w >> 7) & 0x1F), 12) & 0xFFFFFFFF
    if kind == "B":
        v = (((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | \
            (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1)
        return sext(v, 13) & 0xFFFFFFFF
    if kind == "U":
        return ((w >> 12) << 12) & 0xFFFFFFFF
    if kind == "J":
        v = (((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12) | \
            (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1)
        return sext(v, 21) & 0xFFFFFFFF
    if kind == "SHAMT":
        return (w >> 20) & 0x1F
    if kind == "CSR":
        return (w >> 15) & 0x1F
    if kind == "NONE":                                 # 无立即数字段 → 0
        return 0
    raise ValueError(kind)


def new_dec():
    return dict(legal=0, rs1=0, rs2=0, rs3=0, rd=0, csr=0, imm=0, imm_type="I",
                f=dict((k, 0) for k in FIELD_NAMES))


def setf(d, **kw):
    for k, v in kw.items():
        d["f"][k] = v
    return d


def illegal(d):
    d["legal"] = 0
    setf(d, op_class="OP_NOP", rd_wen=0, rd_is_fp=0, use_rs1=0, use_rs2=0, use_rs3=0,
         excp_valid=1, excp_cause="DEXC_ILLEGAL")
    return d


def decode32(w):
    d = new_dec()
    op = w & 0x7F
    rd, f3 = (w >> 7) & 0x1F, (w >> 12) & 7
    rs1, rs2 = (w >> 15) & 0x1F, (w >> 20) & 0x1F
    f7, f12, f5 = (w >> 25) & 0x7F, (w >> 20) & 0xFFF, (w >> 27) & 0x1F

    if op == 0x37:                                     # LUI
        d["legal"] = 1
        setf(d, op_class="OP_ALU", alu_op="ALU_ADD", alu_a_sel="ALU_A_ZERO",
             alu_b_sel="ALU_B_IMM", wb_sel="WB_ALU", rd_wen=1 if rd else 0)
        d.update(rd=rd, imm_type="U")
    elif op == 0x17:                                   # AUIPC
        d["legal"] = 1
        setf(d, op_class="OP_ALU", alu_op="ALU_ADD", alu_a_sel="ALU_A_PC",
             alu_b_sel="ALU_B_IMM", wb_sel="WB_ALU", rd_wen=1 if rd else 0)
        d.update(rd=rd, imm_type="U")
    elif op == 0x6F:                                   # JAL
        d["legal"] = 1
        setf(d, op_class="OP_BRU",
             br_flags=((1 << M("BRF_CALL")) if rd == 1 else 0) | (1 << M("BRF_JAL")),
             wb_sel="WB_PC4", rd_wen=1 if rd else 0)
        d.update(rd=rd, imm_type="J")
    elif op == 0x67 and f3 == 0:                       # JALR
        d["legal"] = 1
        flags = ((1 << M("BRF_RET")) if (rs1 == 1 and rd == 0) else 0) | \
                ((1 << M("BRF_CALL")) if rd == 1 else 0) | (1 << M("BRF_JALR"))
        setf(d, op_class="OP_BRU", br_flags=flags, wb_sel="WB_PC4",
             rd_wen=1 if rd else 0, use_rs1=1)
        d.update(rs1=rs1, rd=rd, imm_type="I")
    elif op == 0x63:                                   # BRANCH
        bt = {0: "BR_EQ", 1: "BR_NE", 4: "BR_LT", 5: "BR_GE", 6: "BR_LTU", 7: "BR_GEU"}
        if f3 in bt:
            d["legal"] = 1
            setf(d, op_class="OP_BRU", br_type=bt[f3], use_rs1=1, use_rs2=1)
            d.update(rs1=rs1, rs2=rs2, imm_type="B")
    elif op == 0x03:                                   # LOAD
        ms = {0: ("MSZ_BYTE", 0), 1: ("MSZ_HALF", 0), 2: ("MSZ_WORD", 0),
              4: ("MSZ_BYTE", 1), 5: ("MSZ_HALF", 1)}
        if f3 in ms:
            d["legal"] = 1
            sz, uns = ms[f3]
            mf = (1 << M("MF_UNSIGNED")) if uns else 0
            setf(d, op_class="OP_LSU", mem_op="MEM_LOAD", mem_size=sz, mem_flags=mf,
                 wb_sel="WB_MEM", rd_wen=1 if rd else 0, use_rs1=1)
            d.update(rs1=rs1, rd=rd, imm_type="I")
    elif op == 0x23:                                   # STORE
        ms = {0: "MSZ_BYTE", 1: "MSZ_HALF", 2: "MSZ_WORD"}
        if f3 in ms:
            d["legal"] = 1
            setf(d, op_class="OP_LSU", mem_op="MEM_STORE", mem_size=ms[f3],
                 use_rs1=1, use_rs2=1)
            d.update(rs1=rs1, rs2=rs2, imm_type="S")
    elif op == 0x13:                                   # OP-IMM
        ai = {0: "ALU_ADD", 2: "ALU_SLT", 3: "ALU_SLTU", 4: "ALU_XOR",
              6: "ALU_OR", 7: "ALU_AND"}
        if f3 in ai:
            d["legal"] = 1
            setf(d, op_class="OP_ALU", alu_op=ai[f3], alu_a_sel="ALU_A_RS1",
                 alu_b_sel="ALU_B_IMM", wb_sel="WB_ALU", rd_wen=1 if rd else 0, use_rs1=1)
            d.update(rs1=rs1, rd=rd, imm_type="I")
        elif f3 == 1 and f7 == 0x00:                   # SLLI
            d["legal"] = 1
            setf(d, op_class="OP_ALU", alu_op="ALU_SLL", alu_a_sel="ALU_A_RS1",
                 alu_b_sel="ALU_B_SHAMT", wb_sel="WB_ALU", rd_wen=1 if rd else 0, use_rs1=1)
            d.update(rs1=rs1, rd=rd, imm_type="SHAMT")
        elif f3 == 5 and f7 in (0x00, 0x20):           # SRLI / SRAI
            d["legal"] = 1
            setf(d, op_class="OP_ALU", alu_op=("ALU_SRL" if f7 == 0 else "ALU_SRA"),
                 alu_a_sel="ALU_A_RS1", alu_b_sel="ALU_B_SHAMT", wb_sel="WB_ALU",
                 rd_wen=1 if rd else 0, use_rs1=1)
            d.update(rs1=rs1, rd=rd, imm_type="SHAMT")
    elif op == 0x33:                                   # OP / M
        if f7 == 0x01:
            mo = {0: "MDU_MUL", 1: "MDU_MULH", 2: "MDU_MULHSU", 3: "MDU_MULHU",
                  4: "MDU_DIV", 5: "MDU_DIVU", 6: "MDU_REM", 7: "MDU_REMU"}
            d["legal"] = 1
            setf(d, op_class="OP_MDU", mdu_op=mo[f3], wb_sel="WB_ALU",
                 rd_wen=1 if rd else 0, use_rs1=1, use_rs2=1)
            d.update(rs1=rs1, rs2=rs2, rd=rd)
        else:
            ao = {0: ("ALU_ADD", 0x00, "ALU_SUB", 0x20), 1: ("ALU_SLL", 0x00, None, None),
                  2: ("ALU_SLT", 0x00, None, None), 3: ("ALU_SLTU", 0x00, None, None),
                  4: ("ALU_XOR", 0x00, None, None), 5: ("ALU_SRL", 0x00, "ALU_SRA", 0x20),
                  6: ("ALU_OR", 0x00, None, None), 7: ("ALU_AND", 0x00, None, None)}
            ent = ao[f3]
            pick = None
            if f7 == ent[1]:
                pick = ent[0]
            elif ent[2] and f7 == ent[3]:
                pick = ent[2]
            if pick:
                d["legal"] = 1
                setf(d, op_class="OP_ALU", alu_op=pick, alu_a_sel="ALU_A_RS1",
                     alu_b_sel="ALU_B_RS2", wb_sel="WB_ALU",
                     rd_wen=1 if rd else 0, use_rs1=1, use_rs2=1)
                d.update(rs1=rs1, rs2=rs2, rd=rd)
    elif op == 0x0F:                                   # MISC-MEM
        if f3 == 0:                                    # FENCE
            d["legal"] = 1
            setf(d, op_class="OP_SYS", sys_op="SYS_FENCE", is_fence=1, is_serial=1)
            d["imm_type"] = "NONE"
        elif f3 == 1:                                  # FENCE.I（rs1/rd/funct12 为保留字段，忽略）
            d["legal"] = 1
            setf(d, op_class="OP_SYS", sys_op="SYS_FENCE_I", is_fencei=1, is_serial=1)
            d["imm_type"] = "NONE"
        elif f3 == 2:                                  # Zicbom（编码固定 rd=0）
            cb = {0x000: "CBO_INVAL", 0x001: "CBO_CLEAN",
                  0x002: "CBO_FLUSH", 0x004: "CBO_ZERO"}
            if rd == 0 and f12 in cb:
                d["legal"] = 1
                setf(d, op_class="OP_SYS", cbo_op=cb[f12], is_serial=1, use_rs1=1)
                d.update(rs1=rs1, imm_type="NONE")
    elif op == 0x73:                                   # SYSTEM / Zicsr / Zicbom
        if f3 == 0:
            if f7 == 0x00 and f12 in (0x000, 0x001) and rd == 0 and rs1 == 0:
                if f12 == 0x000:                       # ECALL
                    d["legal"] = 1
                    setf(d, op_class="OP_SYS", sys_op="SYS_ECALL", is_serial=1,
                         excp_valid=1, excp_cause="DEXC_ECALL_M")
                    d["imm_type"] = "NONE"
                else:                                  # EBREAK
                    d["legal"] = 1
                    setf(d, op_class="OP_SYS", sys_op="SYS_EBREAK", is_serial=1,
                         excp_valid=1, excp_cause="DEXC_BREAK")
                    d["imm_type"] = "NONE"
            elif f7 == 0x18 and f12 == 0x302 and rd == 0 and rs1 == 0:   # MRET
                d["legal"] = 1
                setf(d, op_class="OP_SYS", sys_op="SYS_MRET", is_serial=1)
                d["imm_type"] = "NONE"
            elif f7 == 0x08 and f12 == 0x102 and rd == 0 and rs1 == 0:   # SRET
                d["legal"] = 1
                setf(d, op_class="OP_SYS", sys_op="SYS_SRET", is_serial=1)
                d["imm_type"] = "NONE"
            elif f7 == 0x08 and f12 == 0x105 and rd == 0 and rs1 == 0:   # WFI
                d["legal"] = 1
                setf(d, op_class="OP_SYS", sys_op="SYS_WFI", is_serial=1)
                d["imm_type"] = "NONE"
            elif f7 == 0x09 and rd == 0:                                 # SFENCE.VMA(rs2=ASID)
                d["legal"] = 1
                setf(d, op_class="OP_SYS", sys_op="SYS_SFENCE_VMA", is_sfence=1,
                     is_serial=1, use_rs1=1, use_rs2=1)
                d.update(rs1=rs1, rs2=rs2, imm_type="NONE")
        elif f3 in (1, 2, 3, 5, 6, 7):                 # Zicsr
            d["legal"] = 1
            cop = {1: "CSR_RW", 2: "CSR_RS", 3: "CSR_RC",
                   5: "CSR_RW", 6: "CSR_RS", 7: "CSR_RC"}[f3]
            cimm = 1 if f3 & 4 else 0
            setf(d, op_class="OP_CSR", csr_op=cop, csr_imm=cimm, wb_sel="WB_CSR",
                 rd_wen=1 if rd else 0, is_serial=1, use_rs1=0 if cimm else 1)
            d.update(rs1=rs1, rd=rd, csr=f12, imm_type="CSR" if cimm else "I")
    elif op == 0x2F and f3 == 2:                       # AMO
        aq, rl = (w >> 26) & 1, (w >> 25) & 1
        aflags = (rl << M("AMOF_RL")) | (aq << M("AMOF_AQ"))
        amos = {0x01: "AMO_SWAP", 0x00: "AMO_ADD", 0x04: "AMO_XOR", 0x08: "AMO_OR",
                0x0C: "AMO_AND", 0x10: "AMO_MIN", 0x14: "AMO_MAX",
                0x18: "AMO_MINU", 0x1C: "AMO_MAXU"}
        if f5 == 0x02 and rs2 == 0:                    # LR.W
            d["legal"] = 1
            setf(d, op_class="OP_LSU", mem_op="MEM_LR", mem_size="MSZ_WORD",
                 amo_flags=aflags, wb_sel="WB_MEM", rd_wen=1 if rd else 0, use_rs1=1)
            d.update(rs1=rs1, rd=rd)
        elif f5 == 0x03 and rs2 != 0:                  # SC.W
            d["legal"] = 1
            setf(d, op_class="OP_LSU", mem_op="MEM_SC", mem_size="MSZ_WORD",
                 amo_flags=aflags, wb_sel="WB_MEM", rd_wen=1 if rd else 0,
                 use_rs1=1, use_rs2=1)
            d.update(rs1=rs1, rs2=rs2, rd=rd)
        elif f5 in amos:                               # AMO*.W
            d["legal"] = 1
            setf(d, op_class="OP_LSU", mem_op="MEM_AMO", mem_size="MSZ_WORD",
                 amo_op=amos[f5], amo_flags=aflags, wb_sel="WB_MEM",
                 rd_wen=1 if rd else 0, use_rs1=1, use_rs2=1)
            d.update(rs1=rs1, rs2=rs2, rd=rd)
    # 其余（OP-FP / LOAD-FP / STORE-FP / FMA / OP-32 / 未定义）保持 legal=0

    if not d["legal"]:
        illegal(d)
    else:
        d["imm"] = imm_of(d["imm_type"], w)
    return d


def rvc_expand(c):
    """16 位压缩指令 → 等价 32 位（spec/02 §4.6 / unpriv zca.adoc）。返回 (word32, ill)"""
    op, f3 = c & 3, (c >> 13) & 7
    rd, rs2 = (c >> 7) & 0x1F, (c >> 2) & 0x1F
    rdp = 8 | ((c >> 2) & 7)          # rd'  = x8..x15
    rs1p = 8 | ((c >> 7) & 7)         # rs1' = x8..x15
    rs2p = 8 | ((c >> 2) & 7)         # rs2' = x8..x15
    b12 = (c >> 12) & 1
    imm6 = (b12 << 5) | ((c >> 2) & 0x1F)
    b = lambda n: (c >> n) & 1
    ill = False
    w = c

    def R(f7, f3_, rdv, rs1v, rs2v, opc=0x33):
        return (f7 << 25) | (rs2v << 20) | (rs1v << 15) | (f3_ << 12) | (rdv << 7) | opc

    def I12(imm, rs1v, f3_, rdv, opc):
        return ((imm & 0xFFF) << 20) | (rs1v << 15) | (f3_ << 12) | (rdv << 7) | opc

    def S12(imm, rs2v, rs1v, f3_, opc):
        return (((imm >> 5) & 0x7F) << 25) | (rs2v << 20) | (rs1v << 15) | \
               (f3_ << 12) | ((imm & 0x1F) << 7) | opc

    def B12(imm, rs2v, rs1v, f3_):
        return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2v << 20) | \
               (rs1v << 15) | (f3_ << 12) | (((imm >> 1) & 0xF) << 8) | \
               (((imm >> 11) & 1) << 7) | 0x63

    def J21(imm, rdv):
        return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
               (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (rdv << 7) | 0x6F

    if op == 0:
        # nzuimm[9:2]（8 位）：[9:6]=inst[10:7]、[5:4]=inst[12:11]、[3]=inst[5]、[2]=inst[6]
        nz4 = (b(10) << 7) | (b(9) << 6) | (b(8) << 5) | (b(7) << 4) | \
              (b(12) << 3) | (b(11) << 2) | (b(5) << 1) | b(6)
        u_lw = (b(5) << 4) | (b(12) << 3) | (b(11) << 2) | (b(10) << 1) | b(6)
        u_ld = (b(6) << 4) | (b(5) << 3) | (b(12) << 2) | (b(11) << 1) | b(10)
        if f3 == 0:                                    # C.ADDI4SPN
            w = I12(nz4 << 2, 2, 0, rdp, 0x13)
            ill = (nz4 == 0)
        elif f3 == 1:                                  # C.FLD
            w = I12(u_ld << 3, rs1p, 3, rdp, 0x07)
        elif f3 == 2:                                  # C.LW
            w = I12(u_lw << 2, rs1p, 2, rdp, 0x03)
        elif f3 == 3:                                  # C.FLW（RV32）
            w = I12(u_lw << 2, rs1p, 2, rdp, 0x07)
        elif f3 == 5:                                  # C.FSD
            w = S12(u_ld << 3, rs2p, rs1p, 3, 0x27)
        elif f3 == 6:                                  # C.SW
            w = S12(u_lw << 2, rs2p, rs1p, 2, 0x23)
        elif f3 == 7:                                  # C.FSW（RV32）
            w = S12(u_lw << 2, rs2p, rs1p, 2, 0x27)
        else:
            ill = True
    elif op == 1:
        if f3 == 0:                                    # C.NOP / C.ADDI
            w = I12(sext(imm6, 6), rd, 0, rd, 0x13)
        elif f3 == 1:                                  # C.JAL
            o = (b(12) << 11) | (b(8) << 10) | (b(10) << 9) | (b(9) << 8) | \
                (b(6) << 7) | (b(7) << 6) | (b(2) << 5) | (b(11) << 4) | \
                (b(5) << 3) | (b(4) << 2) | (b(3) << 1)
            w = J21(sext(o, 12), 1)
        elif f3 == 2:                                  # C.LI
            w = I12(sext(imm6, 6), 0, 0, rd, 0x13)
        elif f3 == 3:
            if rd == 2:                                # C.ADDI16SP
                o = (b(12) << 9) | (b(4) << 8) | (b(3) << 7) | (b(5) << 6) | \
                    (b(2) << 5) | (b(6) << 4)
                w = I12(sext(o, 10), 2, 0, 2, 0x13)
                ill = (o == 0)
            else:                                      # C.LUI
                nzimm20 = (b(12) << 5) | ((c >> 2) & 0x1F)      # nzimm[17:12]
                val32 = sext(nzimm20 << 12, 18) & 0xFFFFFFFF     # 32 位立即数值
                w = (((val32 >> 12) & 0xFFFFF) << 12) | (rd << 7) | 0x37
                ill = (imm6 == 0)                      # imm=0 保留；rd=x0 且 imm!=0 是 HINT
        elif f3 == 4:
            if ((c >> 10) & 3) == 3:                   # CA：c.sub/c.xor/c.or/c.and
                f2 = (c >> 5) & 3
                w = {0: R(0x20, 0, rs1p, rs1p, rs2p), 1: R(0x00, 4, rs1p, rs1p, rs2p),
                     2: R(0x00, 6, rs1p, rs1p, rs2p),
                     3: R(0x00, 7, rs1p, rs1p, rs2p)}[f2]
                ill = (b12 == 1)                       # RV64 C.SUBW/C.ADDW → RV32 非法
            else:                                      # CB：c.srli/c.srai/c.andi
                f2 = (c >> 10) & 3
                if f2 == 0:
                    w = I12((b12 << 5) | ((c >> 2) & 0x1F), rs1p, 5, rs1p, 0x13)
                    ill = (b12 == 1)
                elif f2 == 1:
                    w = I12((0x20 << 5) | (b12 << 5) | ((c >> 2) & 0x1F), rs1p, 5, rs1p, 0x13)
                    ill = (b12 == 1)
                else:                                  # f2 == 2：C.ANDI
                    w = I12(sext(imm6, 6), rs1p, 7, rs1p, 0x13)
        elif f3 == 5:                                  # C.J
            o = (b(12) << 11) | (b(8) << 10) | (b(10) << 9) | (b(9) << 8) | \
                (b(6) << 7) | (b(7) << 6) | (b(2) << 5) | (b(11) << 4) | \
                (b(5) << 3) | (b(4) << 2) | (b(3) << 1)
            w = J21(sext(o, 12), 0)
        elif f3 in (6, 7):                             # C.BEQZ / C.BNEZ
            o = (b(12) << 8) | (b(11) << 4) | (b(10) << 3) | (b(6) << 7) | \
                (b(5) << 6) | (b(4) << 2) | (b(3) << 1) | b(2)
            w = B12(sext(o, 9) & 0x1FFF, 0, rs1p, 0 if f3 == 6 else 1)
        else:
            ill = True
    elif op == 2:
        u_lwsp = (b(3) << 5) | (b(2) << 4) | (b(12) << 3) | (b(6) << 2) | \
                 (b(5) << 1) | b(4)
        u_ldsp = (b(4) << 5) | (b(3) << 4) | (b(2) << 3) | (b(12) << 2) | \
                 (b(6) << 1) | b(5)
        u_swsp = (b(8) << 5) | (b(7) << 4) | (b(12) << 3) | (b(11) << 2) | \
                 (b(10) << 1) | b(9)
        u_sdsp = (b(9) << 5) | (b(8) << 4) | (b(7) << 3) | (b(12) << 2) | \
                 (b(11) << 1) | b(10)
        if f3 == 0:                                    # C.SLLI
            w = I12((b12 << 5) | ((c >> 2) & 0x1F), rd, 1, rd, 0x13)
            ill = (b12 == 1)
        elif f3 == 1:                                  # C.FLDSP
            w = I12(u_ldsp << 3, 2, 3, rd, 0x07)
        elif f3 == 2:                                  # C.LWSP
            w = I12(u_lwsp << 2, 2, 2, rd, 0x03)
            ill = (rd == 0)
        elif f3 == 3:                                  # C.FLWSP（RV32）
            w = I12(u_lwsp << 2, 2, 2, rd, 0x07)
        elif f3 == 4:                                  # CR
            if b12 == 0 and rs2 == 0:                  # C.JR
                w = I12(0, rd, 0, 0, 0x67)
                ill = (rd == 0)
            elif b12 == 0:                             # C.MV
                w = R(0, 0, rd, 0, rs2)
            elif rd == 0 and rs2 == 0:                 # C.EBREAK
                w = 0x00100073
            elif rs2 == 0:                             # C.JALR
                w = I12(0, rd, 0, 1, 0x67)
            else:                                      # C.ADD
                w = R(0, 0, rd, rd, rs2)
        elif f3 == 5:                                  # C.FSDSP
            w = S12(u_sdsp << 3, rs2, 2, 3, 0x27)
        elif f3 == 6:                                  # C.SWSP
            w = S12(u_swsp << 2, rs2, 2, 2, 0x23)
        elif f3 == 7:                                  # C.FSWSP（RV32）
            w = S12(u_swsp << 2, rs2, 2, 2, 0x27)
        else:
            ill = True
    return w & 0xFFFFFFFF, ill


def model_decode(raw):
    if (raw & 3) != 3:
        w, rvc_ill = rvc_expand(raw & 0xFFFF)
        d = decode32(w)
        if rvc_ill:
            illegal(d)
        ilen = 1                                       # ilen = log2(字节数)
    else:
        w = raw
        d = decode32(w)
        ilen = 2
    d["instr"] = w
    d["ilen"] = ilen
    d["ctrl"] = pack_ctrl(d["f"])
    return d


# =============================================================================
# 4. 手写期望表（HAND）：对代表性子集逐字段手写期望，与参考模型互查
# =============================================================================

HAND = {
    "lui a0, 0x12345": dict(op_class="OP_ALU", alu_op="ALU_ADD", alu_a_sel="ALU_A_ZERO",
                            alu_b_sel="ALU_B_IMM", wb_sel="WB_ALU", rd_wen=1,
                            use_rs1=0, use_rs2=0, imm=0x12345000),
    "auipc a2, 0x1": dict(op_class="OP_ALU", alu_op="ALU_ADD", alu_a_sel="ALU_A_PC",
                          alu_b_sel="ALU_B_IMM", wb_sel="WB_ALU", rd_wen=1, imm=0x1000),
    "jal x1, .+12": dict(op_class="OP_BRU", br_flags=0b0101, wb_sel="WB_PC4",
                         rd_wen=1, use_rs1=0, imm=12),
    "jal x5, .-4": dict(op_class="OP_BRU", br_flags=0b0001, wb_sel="WB_PC4",
                        rd_wen=1, imm=0xFFFFFFFC),
    "jalr x0, 0(x1)": dict(op_class="OP_BRU", br_flags=0b1010, wb_sel="WB_PC4",
                           rd_wen=0, use_rs1=1, rs1=1, rd=0, imm=0),
    "jalr x1, 0(x1)": dict(op_class="OP_BRU", br_flags=0b0110, wb_sel="WB_PC4",
                           rd_wen=1, use_rs1=1, imm=0),
    "jalr x5, 16(x6)": dict(op_class="OP_BRU", br_flags=0b0010, wb_sel="WB_PC4",
                            rd_wen=1, rs1=6, rd=5, imm=16),
    "beq a0, a1, .+8": dict(op_class="OP_BRU", br_type="BR_EQ", use_rs1=1, use_rs2=1,
                            rd_wen=0, imm=8),
    "bgeu a2, a3, .-16": dict(op_class="OP_BRU", br_type="BR_GEU", use_rs1=1,
                              use_rs2=1, imm=0xFFFFFFF0),
    "lb a0, 0(a1)": dict(op_class="OP_LSU", mem_op="MEM_LOAD", mem_size="MSZ_BYTE",
                         mem_flags=0, wb_sel="WB_MEM", rd_wen=1, use_rs1=1, use_rs2=0),
    "lhu a0, -2(a1)": dict(op_class="OP_LSU", mem_op="MEM_LOAD", mem_size="MSZ_HALF",
                           mem_flags=1, wb_sel="WB_MEM", rd_wen=1, imm=0xFFFFFFFE),
    "lw a0, 8(sp)": dict(op_class="OP_LSU", mem_op="MEM_LOAD", mem_size="MSZ_WORD",
                         mem_flags=0, wb_sel="WB_MEM", rd_wen=1, rs1=2, rd=10, imm=8),
    "sb a0, 0(a1)": dict(op_class="OP_LSU", mem_op="MEM_STORE", mem_size="MSZ_BYTE",
                         use_rs1=1, use_rs2=1, rd_wen=0),
    "sw a0, 8(sp)": dict(op_class="OP_LSU", mem_op="MEM_STORE", mem_size="MSZ_WORD",
                         use_rs1=1, use_rs2=1, rd_wen=0, imm=8),
    "addi a0, a1, 5": dict(op_class="OP_ALU", alu_op="ALU_ADD", alu_a_sel="ALU_A_RS1",
                           alu_b_sel="ALU_B_IMM", wb_sel="WB_ALU", rd_wen=1,
                           use_rs1=1, use_rs2=0, imm=5),
    "addi a0, a1, -2048": dict(op_class="OP_ALU", alu_op="ALU_ADD", alu_b_sel="ALU_B_IMM",
                               wb_sel="WB_ALU", rd_wen=1, imm=0xFFFFF800),
    "srai a0, a1, 31": dict(op_class="OP_ALU", alu_op="ALU_SRA", alu_b_sel="ALU_B_SHAMT",
                            wb_sel="WB_ALU", rd_wen=1, imm=31),
    "slli a0, a1, 0": dict(op_class="OP_ALU", alu_op="ALU_SLL", alu_b_sel="ALU_B_SHAMT",
                           wb_sel="WB_ALU", rd_wen=1, imm=0),
    "add a0, a1, a2": dict(op_class="OP_ALU", alu_op="ALU_ADD", alu_a_sel="ALU_A_RS1",
                           alu_b_sel="ALU_B_RS2", wb_sel="WB_ALU", rd_wen=1,
                           use_rs1=1, use_rs2=1),
    "sub a0, a1, a2": dict(op_class="OP_ALU", alu_op="ALU_SUB", alu_b_sel="ALU_B_RS2",
                           wb_sel="WB_ALU", rd_wen=1),
    "and a0, a1, a2": dict(op_class="OP_ALU", alu_op="ALU_AND", alu_b_sel="ALU_B_RS2",
                           wb_sel="WB_ALU", rd_wen=1),
    "sltu a0, a1, a2": dict(op_class="OP_ALU", alu_op="ALU_SLTU", wb_sel="WB_ALU"),
    "fence": dict(op_class="OP_SYS", sys_op="SYS_FENCE", is_fence=1, is_serial=1,
                  rd_wen=0, use_rs1=0, use_rs2=0),
    "fence.i": dict(op_class="OP_SYS", sys_op="SYS_FENCE_I", is_fencei=1, is_serial=1,
                    rd_wen=0),
    "ecall": dict(op_class="OP_SYS", sys_op="SYS_ECALL", is_serial=1, excp_valid=1,
                  excp_cause="DEXC_ECALL_M", rd_wen=0),
    "ebreak": dict(op_class="OP_SYS", sys_op="SYS_EBREAK", is_serial=1, excp_valid=1,
                   excp_cause="DEXC_BREAK", rd_wen=0),
    "mret": dict(op_class="OP_SYS", sys_op="SYS_MRET", is_serial=1, rd_wen=0),
    "sret": dict(op_class="OP_SYS", sys_op="SYS_SRET", is_serial=1, rd_wen=0),
    "wfi": dict(op_class="OP_SYS", sys_op="SYS_WFI", is_serial=1, rd_wen=0),
    "sfence.vma x0, x0": dict(op_class="OP_SYS", sys_op="SYS_SFENCE_VMA", is_sfence=1,
                              is_serial=1, use_rs1=1, use_rs2=1, rd_wen=0, imm=0),
    "csrrw a0, mstatus, a1": dict(op_class="OP_CSR", csr_op="CSR_RW", csr_imm=0,
                                  wb_sel="WB_CSR", rd_wen=1, use_rs1=1, use_rs2=0,
                                  is_serial=1, csr=0x300),
    "csrrwi a0, mstatus, 5": dict(op_class="OP_CSR", csr_op="CSR_RW", csr_imm=1,
                                  wb_sel="WB_CSR", rd_wen=1, use_rs1=0, is_serial=1,
                                  imm=5, rs1=5),
    "csrrsi a0, mstatus, 5": dict(op_class="OP_CSR", csr_op="CSR_RS", csr_imm=1,
                                  wb_sel="WB_CSR", rd_wen=1, use_rs1=0, imm=5),
    "csrrci a0, mstatus, 5": dict(op_class="OP_CSR", csr_op="CSR_RC", csr_imm=1,
                                  wb_sel="WB_CSR", rd_wen=1, use_rs1=0, imm=5),
    "csrrs x0, mstatus, a1": dict(op_class="OP_CSR", csr_op="CSR_RS", csr_imm=0,
                                  wb_sel="WB_CSR", rd_wen=0, use_rs1=1),
    "mul a0, a1, a2": dict(op_class="OP_MDU", mdu_op="MDU_MUL", wb_sel="WB_ALU",
                           rd_wen=1, use_rs1=1, use_rs2=1),
    "mulhsu a0, a1, a2": dict(op_class="OP_MDU", mdu_op="MDU_MULHSU", wb_sel="WB_ALU"),
    "divu a0, a1, a2": dict(op_class="OP_MDU", mdu_op="MDU_DIVU", wb_sel="WB_ALU"),
    "remu a0, a1, a2": dict(op_class="OP_MDU", mdu_op="MDU_REMU", wb_sel="WB_ALU"),
    "lr.w a0, (a1)": dict(op_class="OP_LSU", mem_op="MEM_LR", mem_size="MSZ_WORD",
                          amo_flags=0, amo_op=0, wb_sel="WB_MEM", rd_wen=1,
                          use_rs1=1, use_rs2=0),
    "lr.w.aqrl a0, (a1)": dict(op_class="OP_LSU", mem_op="MEM_LR", amo_flags=0b11),
    "sc.w a0, a1, (a2)": dict(op_class="OP_LSU", mem_op="MEM_SC", mem_size="MSZ_WORD",
                              wb_sel="WB_MEM", rd_wen=1, use_rs1=1, use_rs2=1),
    "amoadd.w a0, a1, (a2)": dict(op_class="OP_LSU", mem_op="MEM_AMO",
                                  amo_op="AMO_ADD", amo_flags=0, wb_sel="WB_MEM",
                                  rd_wen=1, use_rs1=1, use_rs2=1),
    "amomaxu.w.aqrl a0, a1, (a2)": dict(op_class="OP_LSU", mem_op="MEM_AMO",
                                        amo_op="AMO_MAXU", amo_flags=0b11),
    "cbo.inval (a0)": dict(op_class="OP_SYS", cbo_op="CBO_INVAL", is_serial=1,
                           use_rs1=1, rd_wen=0, rs1=10),
    "cbo.clean (a0)": dict(op_class="OP_SYS", cbo_op="CBO_CLEAN", is_serial=1, use_rs1=1),
    "cbo.flush (a0)": dict(op_class="OP_SYS", cbo_op="CBO_FLUSH", is_serial=1, use_rs1=1),
    "cbo.zero (a0)": dict(op_class="OP_SYS", cbo_op="CBO_ZERO", is_serial=1, use_rs1=1),
    "fadd.s fa0, fa1, fa2": dict(legal=0, excp_cause="DEXC_ILLEGAL", excp_valid=1,
                                 op_class="OP_NOP", rd_wen=0, use_rs1=0, use_rs2=0),
    "flw fa0, 0(a1)": dict(legal=0, excp_cause="DEXC_ILLEGAL", excp_valid=1),
    "fsw fa0, 0(a1)": dict(legal=0, excp_cause="DEXC_ILLEGAL", excp_valid=1),
    "fmadd.s fa0, fa1, fa2, fa3": dict(legal=0, excp_cause="DEXC_ILLEGAL"),
    "0x00000000": dict(legal=0, excp_cause="DEXC_ILLEGAL", excp_valid=1,
                       op_class="OP_NOP"),
}


def norm(s):
    return re.sub(r"\s+", " ", s.strip().lower())


# =============================================================================
# 5. 指令源码（32 位）与 RVC 用例表
# =============================================================================

ASM32 = [
    # RV32I: LUI / AUIPC
    "lui a0, 0x12345", "lui a1, 0xfffff", "lui a1, 0x1", "lui x0, 0x1",
    "auipc a2, 0x1", "auipc a3, 0x80000",
    # JAL / JALR
    "jal x0, .+8", "jal x1, .+8", "jal x1, .+12", "jal x5, .-4",
    "jalr x0, 0(x1)", "jalr x1, 0(x1)", "jalr x5, 16(x6)", "jalr x0, 0(x5)",
    "jalr x0, 0(a0)", "jalr x1, 0(a0)",
    # BRANCH
    "beq a0, a1, .+8", "beq a0, x0, .+8", "bne a0, x0, .+8", "bne a0, a1, .-8",
    "blt a0, a1, .+4", "bge a0, a1, .+12", "bltu a2, a3, .+16", "bgeu a2, a3, .-16",
    # LOAD
    "lb a0, 0(a1)", "lh a0, 2(a1)", "lw a0, -4(a1)", "lbu a0, 1(a1)", "lhu a0, -2(a1)",
    "lw a0, 8(a1)", "lw a0, 8(sp)", "lw a0, 0(sp)", "lw a0, 4(sp)",
    # STORE
    "sb a0, 0(a1)", "sh a0, 2(a1)", "sw a0, -4(a1)", "sw a0, 8(a1)", "sw a0, 8(sp)",
    "sw a0, 0(sp)",
    # OP-IMM
    "addi a0, a1, 5", "addi a0, a1, -2048", "addi a0, a1, 2047", "addi a0, a0, 5",
    "addi a0, a0, 0", "addi x0, x0, 0", "addi x0, x0, 1", "addi x0, x0, 5",
    "addi a0, x0, 7", "addi a0, sp, 16", "addi sp, sp, 16",
    "slti a0, a1, -1", "sltiu a0, a1, 2047", "xori a0, a1, 0x7ff", "ori a0, a1, -1",
    "andi a0, a1, 1", "andi a0, a0, 3",
    "slli a0, a1, 31", "slli a0, a1, 0", "slli a0, a0, 3", "slli a0, a0, 0",
    "srli a0, a1, 1", "srli a0, a0, 3", "srai a0, a1, 31", "srai a0, a0, 3",
    # OP
    "add a0, a1, a2", "sub a0, a1, a2", "sll a0, a1, a2", "slt a0, a1, a2",
    "sltu a0, a1, a2", "xor a0, a1, a2", "srl a0, a1, a2", "sra a0, a1, a2",
    "or a0, a1, a2", "and a0, a1, a2", "add a0, x0, a1", "add x0, x0, a1",
    "add a0, a0, a1", "sub a0, a0, a1", "xor a0, a0, a1", "or a0, a0, a1",
    "and a0, a0, a1",
    # SYS
    "fence", "fence rw, rw", "fence.i", "ecall", "ebreak", "mret", "sret", "wfi",
    "sfence.vma x0, x0", "sfence.vma a0, a1",
    # Zicsr
    "csrrw a0, mstatus, a1", "csrrs a0, mstatus, a1", "csrrc a0, mstatus, a1",
    "csrrwi a0, mstatus, 5", "csrrsi a0, mstatus, 5", "csrrci a0, mstatus, 5",
    "csrrs x0, mstatus, a1", "csrrw x0, mscratch, a1", "csrrw a0, mtvec, x0",
    "csrrw a0, satp, a1", "csrrs a0, mcause, x0",
    # M
    "mul a0, a1, a2", "mulh a0, a1, a2", "mulhsu a0, a1, a2", "mulhu a0, a1, a2",
    "div a0, a1, a2", "divu a0, a1, a2", "rem a0, a1, a2", "remu a0, a1, a2",
    # A
    "lr.w a0, (a1)", "lr.w.aq a0, (a1)", "lr.w.rl a0, (a1)", "lr.w.aqrl a0, (a1)",
    "sc.w a0, a1, (a2)", "sc.w.rl a0, a1, (a2)",
    "amoswap.w a0, a1, (a2)", "amoadd.w a0, a1, (a2)", "amoxor.w a0, a1, (a2)",
    "amoand.w a0, a1, (a2)", "amoor.w a0, a1, (a2)", "amomin.w a0, a1, (a2)",
    "amomax.w a0, a1, (a2)", "amominu.w a0, a1, (a2)", "amomaxu.w a0, a1, (a2)",
    "amoadd.w.aqrl a0, a1, (a2)", "amomaxu.w.aqrl a0, a1, (a2)",
    # Zicbom
    "cbo.inval (a0)", "cbo.clean (a0)", "cbo.flush (a0)", "cbo.zero (a0)",
    # F/D（未实现 → 期望 legal=0）
    "fadd.s fa0, fa1, fa2", "fsub.d fa0, fa1, fa2", "fmul.s fa0, fa1, fa2",
    "fdiv.d fa0, fa1, fa2", "fsqrt.s fa0, fa1", "fsgnj.s fa0, fa1, fa2",
    "fsgnjn.d fa0, fa1, fa2", "fsgnjx.s fa0, fa1, fa2", "fmin.s fa0, fa1, fa2",
    "fmax.d fa0, fa1, fa2", "fcvt.s.d fa0, fa1", "fcvt.d.s fa0, fa1",
    "fcvt.w.s a0, fa1", "fcvt.wu.d a0, fa1", "fcvt.s.w fa0, a1",
    "fcvt.d.wu fa0, a1", "fmv.x.w a0, fa1", "fmv.w.x fa0, a1",
    "feq.s a0, fa1, fa2", "flt.d a0, fa1, fa2", "fle.s a0, fa1, fa2",
    "fclass.s a0, fa1", "fclass.d a0, fa1",
    "fmadd.s fa0, fa1, fa2, fa3", "fmsub.d fa0, fa1, fa2, fa3",
    "fnmsub.s fa0, fa1, fa2, fa3", "fnmadd.d fa0, fa1, fa2, fa3",
    "flw fa0, 0(a1)", "fld fa0, 8(a1)", "fsw fa0, 0(a1)", "fsd fa0, 8(a1)",
    "fld fa0, 8(sp)", "fsd fa0, 8(sp)", "flw fa0, 8(sp)", "fsw fa0, 8(sp)",
]

# RVC： (助记符, 手工 16 位编码, 等价 32 位汇编文本)
# 期望值 = 等价 32 位指令的期望值（由展开机器码在同一张表里查到）
# 16 位非法/保留编码： (说明, raw16)
RVC = [
    ("c.addi4spn a0, sp, 16",     0x0808, "addi a0, sp, 16"),
    ("c.lw a0, 8(a1)",            0x4588, "lw a0, 8(a1)"),
    ("c.sw a0, 8(a1)",            0xC588, "sw a0, 8(a1)"),
    ("c.nop",                     0x0001, "addi x0, x0, 0"),
    ("c.addi a0, 5",              0x0515, "addi a0, a0, 5"),
    ("c.jal .+8",                 0x2021, "jal x1, .+8"),
    ("c.li a0, 7",                0x451D, "addi a0, x0, 7"),
    ("c.lui a1, 1",               0x6585, "lui a1, 0x1"),
    ("c.srli a0, 3",              0x810D, "srli a0, a0, 3"),
    ("c.srai a0, 3",              0x850D, "srai a0, a0, 3"),
    ("c.andi a0, 3",              0x890D, "andi a0, a0, 3"),
    ("c.sub a0, a1",              0x8D0D, "sub a0, a0, a1"),
    ("c.xor a0, a1",              0x8D2D, "xor a0, a0, a1"),
    ("c.or a0, a1",               0x8D4D, "or a0, a0, a1"),
    ("c.and a0, a1",              0x8D6D, "and a0, a0, a1"),
    ("c.j .+8",                   0xA021, "jal x0, .+8"),
    ("c.beqz a0, .+8",            0xC501, "beq a0, x0, .+8"),
    ("c.bnez a0, .+8",            0xE501, "bne a0, x0, .+8"),
    ("c.slli a0, 3",              0x050E, "slli a0, a0, 3"),
    ("c.lwsp a0, 8(sp)",          0x4522, "lw a0, 8(sp)"),
    ("c.lwsp a0, 0(sp)",          0x4502, "lw a0, 0(sp)"),
    ("c.jr a0",                   0x8502, "jalr x0, 0(a0)"),
    ("c.mv a0, a1",               0x852E, "add a0, x0, a1"),
    ("c.ebreak",                  0x9002, "ebreak"),
    ("c.jalr a0",                 0x9502, "jalr x1, 0(a0)"),
    ("c.add a0, a1",              0x952E, "add a0, a0, a1"),
    ("c.swsp a0, 8(sp)",          0xC42A, "sw a0, 8(sp)"),
    ("c.swsp a0, 0(sp)",          0xC02A, "sw a0, 0(sp)"),
    ("c.addi16sp sp, 16",         0x6141, "addi sp, sp, 16"),
    # 压缩浮点访存（RV32C 定义；F/D 未实现 → legal=0，展开仍须正确）
    ("c.fld fa0, 8(a1)",          0x2588, "fld fa0, 8(a1)"),
    ("c.fsd fa0, 8(a1)",          0xA588, "fsd fa0, 8(a1)"),
    ("c.flw fa0, 8(a1)",          0x6588, "flw fa0, 8(a1)"),
    ("c.fsw fa0, 8(a1)",          0xE588, "fsw fa0, 8(a1)"),
    ("c.fldsp fa0, 8(sp)",        0x2522, "fld fa0, 8(sp)"),
    ("c.fsdsp fa0, 8(sp)",        0xA42A, "fsd fa0, 8(sp)"),
    ("c.flwsp fa0, 8(sp)",        0x6522, "flw fa0, 8(sp)"),
    ("c.fswsp fa0, 8(sp)",        0xE42A, "fsw fa0, 8(sp)"),
    # HINT / 合法边界形式（按 ISA 手册保持合法）
    ("c.addi x0, 1",              0x0005, "addi x0, x0, 1"),
    ("c.li x0, 5",                0x4015, "addi x0, x0, 5"),
    ("c.slli a0, 0",              0x0502, "slli a0, a0, 0"),
    ("c.lui x0, 1",               0x6005, "lui x0, 0x1"),
    ("c.mv x0, a1",               0x802E, "add x0, x0, a1"),
    ("c.addi a0, 0",              0x0501, "addi a0, a0, 0"),
]

RVC_ILLEGAL = [
    ("c.addi4spn nzuimm=0（保留）",        0x0000),
    ("c.lwsp rd=x0（保留）",               0x4042),
    ("c.jr rs1=x0（保留）",                0x8002),
    ("c.lui imm=0（保留）",                0x6581),
    ("c.addi16sp nzimm=0（保留）",         0x6101),
    ("c.srli shamt[5]=1（XLEN=32 保留）",  0x9101),
    ("c.srai shamt[5]=1（XLEN=32 保留）",  0x9501),
    ("c.slli shamt[5]=1（XLEN=32 保留）",  0x1502),
    ("CA inst[15:10]=100111（RV64 C.SUBW）", 0x950D),
    ("op=00 funct3=100（保留槽位）",       0x8000),
    ("c.fld 全 0 字段（F/D 未实现 → 非法）", 0x2000),
    ("op=00 funct3=100 另一保留编码点",    0x9C00),
]


# objdump 伪指令别名归一（压缩/非压缩形式的别名文本可能不同，如 mv vs add）
CANON_MN = {"mv": {"add", "addi"}, "li": {"addi"}, "nop": {"addi"},
            "jr": {"jalr"}, "j": {"jal"}, "ret": {"jalr"}, "beqz": {"beq"},
            "bnez": {"bne"}, "neg": {"sub"}, "not": {"xor"}}


def canon(mn):
    """助记符归一为可接受集合（objdump 伪指令别名在不同形式下可能不同）"""
    if mn.startswith("c."):
        mn = mn[2:]
    return CANON_MN.get(mn, {mn})


# =============================================================================
# 5.5 覆盖清单（规格要求：RV32I/M/A/Zicsr/SYS/Zicbom 每条 ≥1 例、Zca 每条 ≥1 例）
# =============================================================================

REQUIRED_LEGAL = [
    # RV32I
    "lui", "auipc", "jal", "jalr", "beq", "bne", "blt", "bge", "bltu", "bgeu",
    "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw",
    "addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai",
    "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
    "fence", "fence.i", "ecall", "ebreak", "mret", "sret", "wfi",
    # M
    "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu",
    # A
    "lr.w", "sc.w", "amoswap.w", "amoadd.w", "amoxor.w", "amoand.w", "amoor.w",
    "amomin.w", "amomax.w", "amominu.w", "amomaxu.w",
    # Zicsr
    "csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci",
    # SYS
    "sfence.vma",
    # Zicbom
    "cbo.inval", "cbo.clean", "cbo.flush", "cbo.zero",
    # Zca（RV32 全部整数压缩指令 + c.addi16sp）
    "c.addi4spn", "c.lw", "c.sw", "c.nop", "c.addi", "c.jal", "c.li", "c.lui",
    "c.srli", "c.srai", "c.andi", "c.sub", "c.xor", "c.or", "c.and", "c.j",
    "c.beqz", "c.bnez", "c.slli", "c.lwsp", "c.jr", "c.mv", "c.ebreak", "c.jalr",
    "c.add", "c.swsp", "c.addi16sp",
]

REQUIRED_ILLEGAL = [   # F/D 未实现：必须出现且必须判非法
    "fadd.s", "fsub.d", "fmul.s", "fdiv.d", "fsqrt.s", "fsgnj.s", "fsgnjn.d",
    "fsgnjx.s", "fmin.s", "fmax.d", "fcvt.s.d", "fcvt.d.s", "fcvt.w.s",
    "fcvt.wu.d", "fcvt.s.w", "fcvt.d.wu", "fmv.x.w", "fmv.w.x", "feq.s",
    "flt.d", "fle.s", "fclass.s", "fclass.d", "fmadd.s", "fmsub.d", "fnmsub.s",
    "fnmadd.d", "flw", "fld", "fsw", "fsd",
    "c.fld", "c.fsd", "c.flw", "c.fsw", "c.fldsp", "c.fsdsp", "c.flwsp", "c.fswsp",
]


def coverage_check(vectors):
    ok_mn, ill_mn = set(), set()
    for v in vectors:
        mn = v["note"].split()[0].lower()
        (ok_mn if v["exp"]["legal"] else ill_mn).add(mn)
    miss = [m for m in REQUIRED_LEGAL if m not in ok_mn]
    if miss:
        raise SystemExit("覆盖不足（缺少合法用例）: %s" % ", ".join(miss))
    miss = [m for m in REQUIRED_ILLEGAL if m not in ill_mn]
    if miss:
        raise SystemExit("覆盖不足（缺少非法用例/被误判合法）: %s" % ", ".join(miss))
    return len(REQUIRED_LEGAL), len(REQUIRED_ILLEGAL)


def ENC_R(f7, f3, rd, rs1, rs2, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def ENC_I(f12, rd, rs1, f3, op):
    return (f12 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def ENC_S(f7, rs2, rs1, f3, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | op


ILLEGAL32 = [
    (0x00000000, "全 0（规范定义非法）"),
    (0xFFFFFFFF, "全 1"),
    (ENC_I(0x003, 0, 0, 0, 0x73), "SYSTEM funct12=0x003 保留"),
    (ENC_I(0x300, 0, 0, 0, 0x73), "SYSTEM f7=0011000 funct12=0x300 保留"),
    (ENC_I(0x000, 10, 11, 4, 0x73), "SYSTEM funct3=100 保留"),
    (ENC_I(0x101, 0, 0, 0, 0x73), "SYSTEM f7=0001000 funct12=0x101 保留"),
    (ENC_I(0x000, 10, 0, 0, 0x73), "ECALL rd!=0（保留）"),
    (ENC_I(0x302, 10, 0, 0, 0x73), "MRET rd!=0（保留）"),
    (ENC_I(0x302, 0, 11, 0, 0x73), "MRET rs1!=0（保留）"),
    (ENC_I(0x102, 10, 0, 0, 0x73), "SRET rd!=0（保留）"),
    (ENC_I(0x105, 10, 0, 0, 0x73), "WFI rd!=0（保留）"),
    ((0x09 << 25) | (11 << 20) | (10 << 15) | (1 << 7) | 0x73, "SFENCE.VMA rd!=0"),
    # 注：FENCE.I 的 rs1/rd/funct12 是"实现必须忽略"的保留字段（zifencei.adoc），
    #     不是非法编码，故不作为 ILLEGAL32 条目（对应 arch-test 用例 0x0001100f）。
    (ENC_I(0x000, 10, 10, 2, 0x0F), "CBO rd!=0（保留）"),
    (ENC_I(0x002, 0, 10, 3, 0x0F), "MISC-MEM funct3=011 保留"),
    (ENC_I(0, 10, 11, 3, 0x03), "LOAD funct3=011（RV64 LD）"),
    (ENC_I(0, 10, 11, 7, 0x03), "LOAD funct3=111（RV64 LWU/LD）"),
    (ENC_S(0, 10, 11, 3, 0x23), "STORE funct3=011（RV64 SD）"),
    (ENC_I(0x020, 10, 11, 5, 0x13), "OP-IMM funct3=101 funct7=0000001 保留"),
    ((0x20 << 25) | (31 << 20) | (11 << 15) | (1 << 12) | (10 << 7) | 0x13,
     "OP-IMM SLLI 带 funct7=0100000（保留）"),
    (ENC_R(0x02, 0, 10, 11, 12, 0x33), "OP funct7=0000010 保留"),
    (ENC_R(0x20, 1, 10, 11, 12, 0x33), "OP funct7=0100000 配 SLL（保留）"),
    (ENC_R(0, 0, 10, 11, 12, 0x3B), "OP-32（addw，RV64 专有）"),
    (ENC_I(0, 0, 0, 1, 0x67), "JALR funct3=001 保留"),
    (ENC_S(0, 10, 11, 2, 0x63), "BRANCH funct3=010 保留"),
    (ENC_S(0, 10, 11, 3, 0x63), "BRANCH funct3=011 保留"),
    (ENC_I(0x003, 0, 10, 2, 0x0F), "CBO funct12=0x003（保留）"),
    (ENC_I(0, 0, 0, 4, 0x0F), "MISC-MEM funct3=100 保留"),
    ((0x02 << 27) | (10 << 20) | (11 << 15) | (2 << 12) | (10 << 7) | 0x2F,
     "AMO funct3=011 保留"),
    ((0x06 << 27) | (10 << 20) | (11 << 15) | (2 << 12) | (10 << 7) | 0x2F,
     "AMO funct5=00110 未定义"),
    ((0x02 << 27) | (12 << 20) | (11 << 15) | (2 << 12) | (10 << 7) | 0x2F,
     "LR.W rs2!=0（保留）"),
    ((0x03 << 27) | (0 << 20) | (11 << 15) | (2 << 12) | (10 << 7) | 0x2F,
     "SC.W rs2=0（保留）"),
    ((0x20 << 25) | (12 << 20) | (11 << 15) | (0 << 12) | (10 << 7) | 0x53,
     "OP-FP fsub.s（F 未实现）"),
    (ENC_I(0, 0, 11, 2, 0x07), "LOAD-FP（F 未实现）"),
    (ENC_S(0, 1, 11, 2, 0x27), "STORE-FP（F 未实现）"),
]


def build_asm():
    lines = [".option norvc", ".text", ".globl _start", "_start:"]
    lines += ["  " + a for a in ASM32]
    return "\n".join(lines) + "\n"


def build_asm_rvc():
    lines = [".option arch, +c", ".text", ".globl _start", "_start:"]
    lines += ["  " + name for name, _raw, _eq in RVC]
    return "\n".join(lines) + "\n"


def build_asm_eq():
    """RVC 的 32 位等价指令（禁止压缩，保证按索引 1:1 对应）"""
    lines = [".option norvc", ".text", ".globl _start", "_start:"]
    lines += ["  " + eq for _n, _r, eq in RVC]
    return "\n".join(lines) + "\n"


def run_tool(args):
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit("工具失败: %s" % " ".join(args))
    return p.stdout


DIS_RX = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8}|[0-9a-f]{4})\s+(.*?)\s*$")


def disassemble(src_text, workdir, tag):
    s_path = os.path.join(workdir, "v_%s.S" % tag)
    o_path = os.path.join(workdir, "v_%s.o" % tag)
    open(s_path, "w", encoding="utf-8").write(src_text)
    run_tool([AS, "-march=" + MARCH, "-mabi=" + MABI, "-o", o_path, s_path])
    out = run_tool([OBJDUMP, "-d", o_path])
    res = []
    for line in out.splitlines():
        m = DIS_RX.match(line)
        if m:
            res.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3).strip()))
    return res


# =============================================================================
# 6. 组装向量
# =============================================================================


def check_hand(key, exp):
    if key not in HAND:
        return
    for k, v in HAND[key].items():
        if k == "legal":
            got, want = exp["legal"], v
        elif k == "imm":
            got, want = exp["imm"], v & 0xFFFFFFFF
        elif k in ("rs1", "rs2", "rs3", "rd", "csr"):
            got, want = exp[k], v
        else:
            got, want = fv(k, exp["f"][k]), fv(k, v)
        if got != want:
            raise SystemExit("HAND 与参考模型不一致 [%s].%s: model=%s hand=%s"
                             % (key, k, got, want))


VEC_LAYOUT = [("instr_raw", 32), ("exp_instr", 32), ("exp_imm", 32),
              ("exp_ctrl", 73), ("exp_mask", 73), ("exp_rs1", 5), ("exp_rs2", 5),
              ("exp_rs3", 5), ("exp_rd", 5), ("exp_ilen", 2), ("exp_legal", 1)]
VEC_W = sum(w for _n, w in VEC_LAYOUT)
VEC_OFF = {}
_o = 0
for _n, _w in VEC_LAYOUT:
    VEC_OFF[_n] = _o
    _o += _w


def pack_vector(v):
    e = v["exp"]
    mask = ((1 << CTRL_W) - 1) if e["legal"] else ILLEGAL_MASK()
    val = 0
    val |= (v["raw"] & 0xFFFFFFFF) << VEC_OFF["instr_raw"]
    val |= (e["instr"] & 0xFFFFFFFF) << VEC_OFF["exp_instr"]
    val |= (e["imm"] & 0xFFFFFFFF) << VEC_OFF["exp_imm"]
    val |= (e["ctrl"] & ((1 << CTRL_W) - 1)) << VEC_OFF["exp_ctrl"]
    val |= (mask & ((1 << CTRL_W) - 1)) << VEC_OFF["exp_mask"]
    val |= (e["rs1"] & 0x1F) << VEC_OFF["exp_rs1"]
    val |= (e["rs2"] & 0x1F) << VEC_OFF["exp_rs2"]
    val |= (e["rs3"] & 0x1F) << VEC_OFF["exp_rs3"]
    val |= (e["rd"] & 0x1F) << VEC_OFF["exp_rd"]
    val |= (e["ilen"] & 3) << VEC_OFF["exp_ilen"]
    val |= (1 if e["legal"] else 0) << VEC_OFF["exp_legal"]
    return val


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=HERE)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if FIELD_ISSUES:
        print("!! rv32gc_defs.vh 与 spec/02 §2 一致性检查失败:")
        for i in FIELD_ISSUES:
            print("   -", i)
        return 2
    print("[宏] rv32gc_defs.vh 共 %d 个宏；ctrl 位宽 %d；spec/02 §2 全部字段与 "
          "CTRL_*_H/_W 逐位一致" % (len(MACROS), CTRL_W))

    workdir = tempfile.mkdtemp(prefix="decvec_")
    dis32 = disassemble(build_asm(), workdir, "32")
    dis_rvc = disassemble(build_asm_rvc(), workdir, "rvc")
    dis_eq = disassemble(build_asm_eq(), workdir, "eq")

    if len(dis32) != len(ASM32):
        raise SystemExit("32 位反汇编条数 %d != 汇编条数 %d" % (len(dis32), len(ASM32)))
    if len(dis_rvc) != len(RVC) or len(dis_eq) != len(RVC):
        raise SystemExit("RVC 反汇编条数 %d/%d != 用例数 %d"
                         % (len(dis_rvc), len(dis_eq), len(RVC)))

    vectors = []

    # ---- 32 位合法/FP 向量（.option norvc 保证按索引 1:1 对齐） ----
    for i, a in enumerate(ASM32):
        raw = dis32[i][1]
        exp = model_decode(raw)
        check_hand(a, exp)
        vectors.append(dict(raw=raw, exp=exp, note=a, kind="I32"))

    # ---- 32 位非法向量 ----
    for raw, note in ILLEGAL32:
        exp = model_decode(raw)
        if exp["legal"]:
            raise SystemExit("ILLEGAL32 中 %08x（%s）被参考模型判为合法" % (raw, note))
        vectors.append(dict(raw=raw, exp=exp, note="非法: " + note, kind="ILL32"))

    # ---- RVC 向量 ----
    for i, (name, raw, eq) in enumerate(RVC):
        _a16, w16, t16 = dis_rvc[i]
        _a32, w32eq, t32 = dis_eq[i]
        if w16 != raw:                       # (b) 汇编器压缩编码 == 手工编码
            raise SystemExit("RVC 编码与汇编器不一致 [%s]: 手工=%04x 汇编器=%04x (%s)"
                             % (name, raw, w16, t16))
        w32, ill = rvc_expand(raw)
        if w32 != w32eq:                     # (a) 展开 == 汇编器 32 位等价机器码
            raise SystemExit("RVC 展开不符 [%s]: 展开=%08x 汇编等价(%s)=%08x"
                             % (name, w32, eq, w32eq))
        # (c) 反汇编助记符一致性（别名归一后比较；机器码级一致性已由 (a)(b) 保证）
        if not (canon(t16.split()[0]) & canon(t32.split()[0])):
            raise SystemExit("RVC 与等价 32 位助记符不一致 [%s]: '%s' vs '%s'"
                             % (name, t16, t32))
        exp = model_decode(raw)
        eqx = model_decode(w32eq)            # spec/02 §7.2：与 32 位等价指令 uop 逐字段比对
        for k in ("legal", "instr", "rs1", "rs2", "rs3", "rd", "imm", "ctrl"):
            if exp[k] != eqx[k]:
                raise SystemExit("RVC 与等价 32 位 uop 不一致 [%s].%s: %s vs %s"
                                 % (name, k, exp[k], eqx[k]))
        check_hand(name, exp)
        if ill and exp["legal"]:
            raise SystemExit("RVC 保留编码被判合法: %s" % name)
        vectors.append(dict(raw=raw, exp=exp, note=name, kind="I16"))

    # ---- 16 位非法向量 ----
    for note, raw in RVC_ILLEGAL:
        exp = model_decode(raw)
        if exp["legal"]:
            raise SystemExit("RVC_ILLEGAL 中 %04x（%s）被参考模型判为合法" % (raw, note))
        vectors.append(dict(raw=raw, exp=exp, note="非法: " + note, kind="ILL16"))

    n_cov_l, n_cov_i = coverage_check(vectors)
    n_legal = sum(1 for v in vectors if v["exp"]["legal"])
    n_ill = len(vectors) - n_legal
    if len(vectors) < 120:
        raise SystemExit("向量数 %d < 120" % len(vectors))
    if n_ill < 15:
        raise SystemExit("非法向量数 %d < 15" % n_ill)

    # ---- 生成 decoder_vectors.vh ----
    L = []
    L.append("//=============================================================================")
    L.append("// decoder_vectors.vh —— rv32_decoder/rv32_imm_gen 单元测试向量（自动生成，勿手改）")
    L.append("// 生成器: sim/tests/unit/gen_decoder_vectors.py")
    L.append("// 期望来源: 生成器内按 docs/design/spec/02-uop-and-decode.md 手写的参考模型")
    L.append("//           + HAND 手写期望表 + as/objdump 双向交叉验证（不使用被测 RTL 输出）")
    L.append("// 字段布局（LSB→MSB，共 %d 位）:" % VEC_W)
    for nm, wd in VEC_LAYOUT:
        L.append("//   [%3d:%3d] %s" % (VEC_OFF[nm] + wd - 1, VEC_OFF[nm], nm))
    L.append("// 非法向量（exp_legal=0）的 exp_mask 只覆盖 RTL 明确强制的 ctrl 字段")
    L.append("//（excp_valid/excp_cause/op_class/rd_wen/use_rs1/use_rs2/use_rs3），")
    L.append("// 其余输出按接口定义在 legal=0 时为不关心。")
    L.append("//=============================================================================")
    L.append("`ifndef DECODER_VECTORS_VH")
    L.append("`define DECODER_VECTORS_VH")
    L.append("")
    L.append("`define DECODER_VEC_NUM %d" % len(vectors))
    L.append("`define DECODER_VEC_W   %d" % VEC_W)
    L.append("//")
    L.append("// 用法（tb_decoder.v）：")
    L.append("//   `include \"decoder_vectors.vh\"            // 取 DECODER_VEC_NUM/W")
    L.append("//   initial begin")
    L.append("//     `define DECODER_VEC_EMIT_DATA")
    L.append("//     `include \"decoder_vectors.vh\"          // 展开向量赋值")
    L.append("//     `undef DECODER_VEC_EMIT_DATA")
    L.append("//   end")
    L.append("")
    L.append("// idx | instr_raw | lg il | instr    | rs1 rs2 rs3 rd | imm      | ctrl(hex)  | 说明")
    for i, v in enumerate(vectors):
        e = v["exp"]
        L.append("// %3d | %08x  |  %d  %d | %08x |  %2d  %2d  %2d %2d | %08x | %019x | %s"
                 % (i, v["raw"], e["legal"], e["ilen"], e["instr"], e["rs1"], e["rs2"],
                    e["rs3"], e["rd"], e["imm"], e["ctrl"], v["note"]))
    L.append("")
    L.append("`endif // DECODER_VECTORS_VH")
    L.append("")
    L.append("//-----------------------------------------------------------------------------")
    L.append("// 数据段（不受 include 保护宏约束）：在 testbench 的 initial 块内")
    L.append("// `define DECODER_VEC_EMIT_DATA 后再次 `include 本文件，即展开为")
    L.append("//   vec[i] = 向量; 赋值（避免超长宏超出仿真器预处理限制）。")
    L.append("//-----------------------------------------------------------------------------")
    L.append("`ifdef DECODER_VEC_EMIT_DATA")
    for i, v in enumerate(vectors):
        L.append("  vec[%3d] = %d'h%0*x;" % (i, VEC_W, (VEC_W + 3) // 4, pack_vector(v)))
    L.append("`endif // DECODER_VEC_EMIT_DATA")
    out_path = os.path.join(args.out_dir, "decoder_vectors.vh")
    open(out_path, "w", encoding="utf-8").write("\n".join(L) + "\n")

    cov = {}
    for v in vectors:
        cov[v["kind"]] = cov.get(v["kind"], 0) + 1
    print("[向量] 共 %d 条（合法 %d / 非法 %d）" % (len(vectors), n_legal, n_ill))
    print("[分类] " + " ".join("%s=%d" % kv for kv in sorted(cov.items())))
    print("[覆盖] 规格清单 %d 条合法指令 + %d 条 F/D 未实现指令全部命中（每条 ≥1 例）"
          % (n_cov_l, n_cov_i))
    print("[输出] %s" % out_path)
    if args.keep:
        print("[临时目录] %s" % workdir)
    else:
        for f in os.listdir(workdir):
            os.remove(os.path.join(workdir, f))
        os.rmdir(workdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
