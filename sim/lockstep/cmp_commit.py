#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#==============================================================================
# sim/lockstep/cmp_commit.py —— DUT 提交 trace v3 ↔ Spike commit log 逐条比对器
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）；依据 docs/design/08-baseline-5stage.md §8.3
#
# 一、输入
#------------------------------------------------------------------------------
#   DUT  : tb_lockstep.sv 落的 v3 trace（每提交一行 + 末行 # end + DUT 侧 AXI 证据）
#          <idx> pc=... xw= xrd= xval= fw= frd= fval= st= ssz= s0a= s0p= s0d= s0b=
#                s1a= s1p= s1d= s1b= cw= cad= cva= fl= ff= fs= obs=
#   Spike: `spike -l --log-commits --log=<file>`（本机 1.1.1-dev 实测：反汇编行与
#          commit 行交错；commit 行 = `core 0: <priv> 0x<pc> (0x<insn>) ...`）
#
#   ★ 旧 v1 trace（只有 pc/wen/rd/wdata）没有 store/CSR/FP 域，本脚本**明确拒绝**，
#     不静默按旧口径放行；必须用 v3 TB 重生成。
#
# 二、逐条比较的域（全部 fail-closed；任一项不符 ⇒ 非零退出，且不打印 PASS 行）
#------------------------------------------------------------------------------
#   ① PC 严格相等；Spike 特权级恒 M(3)；比对前缀内不得有 exception。
#   ② 整数写回：DUT xw/xrd/xval == Spike xN 写；x0 不写；类型必须一致。
#   ③ 浮点写回：DUT fw/frd/fval(64) == Spike fN 写；**64 位全比**（S 结果按
#      NaN-box 高 32 位全 1，D 结果完整 64 位）；x/f 类型不可互换（f0 不是 x0）。
#   ④ store：DUT 在 M_S_ISS 捕获的真实请求（地址/32 位车道数据/字节使能）对
#      Spike `mem <addr> <data>`；mask 用 ISA 确定性 oracle（sb/sh/sw/fsw/fsd +
#      地址低位）对 DUT 实际 strb 比（Spike 不提供 mask，绝不伪造等价掩码）。
#      fsd 必须两相 4 B 都捕到（st=2），单相 ⇒ 失败。--pa-mode bare（默认）
#      逐相比 s0p/s1p==s0a/s1a；translated 无独立 PA oracle ⇒ 显式 UNSUPPORTED。
#   ⑤ CSR：先从参考 insn 独立解 CSR 地址与真写语义（CSRRW/CSRRWI 总写；
#      CSRRS/RC 仅 rs1/zimm!=0 写），再核 DUT cw/cad；缺 cw、错 cad、只读伪 cw、
#      非 CSR 伪 cw 都精确失败。显式写取 csr_file **post-WARL 落地值**（不是
#      原始 operand），与 Spike `c<num>` post-CSR 比；FCSR 展开 c1+c2；显式
#      mstatus 不归入 implicit，按全值比（SD 读视图位在 TB 规范化）。
#   ⑥ fflags：DUT E 级 flags≠0 的隐式副作用（fl/ff）与 Spike c1_fflags 比；
#      flags=0 不记（与 Spike 行为一致）。显式 fflags/fcsr 写由 ⑤ 比。
#   ⑦ mstatus.FS：Spike 隐式 c768_mstatus 只比 FS[14:13] 与 SD；无 VS/XS 时
#      SD==(FS==3)，FS=1/2 必须 SD=0；不从 Spike 回填 DUT 其余 mstatus 位。
#      FS/flags 值来自 TB 对实际 poststate/更新沿的采样，不重算 CSR 规则。
#   ⑧ 终止/锚点（必须来自 DUT 侧观测）：
#      · DUT 末行 reason=TERM_PC、term_pc 匹配、uart_writes>=1、commits==行数；
#      · DUT AXI 上 magic 写恰一次（AW 地址 + 配对 W 数据/strb）且 UART 结束铃
#        恰一次；Spike 单方停机不能冒充 DUT 完成；
#      · DUT 提交 trace 中恰有一条 magic store、恰有一条 doorbell store 且为最后
#        一条；Spike 被比对的最后一条也是 doorbell，下一条是 lockstep_spin。
#   ⑨ 不可比 CSR 读（逐项，不是泛跳所有 counter）：
#      · 非确定：cycle/time（C00/C01/C80/C81）、mcycle（B00/B80）→ CMP_UNSUPPORTED；
#      · instret/instreth（C02/C82）：2026-10-22 新 Top 已修程序序投影 ⇒ 正式比较；
#      · minstret/minstreth（B02/B82）读本轮未移出，仍逐项 CMP_UNSUPPORTED；
#        不接受 ±1 容差，不删默认 N>=60 入口。
#   ⑩ CSR 锁写 no-op：DUT trace 的 cva=post-WARL 落地值；cvo=写前 waddr 视角值。
#      该 cvo 只对 PMP address（0x3B0..0x3BF）有 csr_file 专用现值路径，其他 CSR
#      的产品读视图回退到 rdata_r（raddr 视角），不能用于 no-op 判定。Spike 对
#      被忽略的 PMP 锁写不记 c<num>（实测）；仅当 PMP addr 且 cva==cvo 时允许缺失，
#      其余 CSR 缺失一律失败（不捏造 0 放宽）。
#
# 三、输出
#------------------------------------------------------------------------------
#   成功：`CMP_CHECK` / `CMP_COVERAGE` 摘要 + 唯一 `LOCKSTEP: K/K PASS`（rc=0）。
#   失败：`CMP_DIVERGENCE`（逐条）/ `CMP_ERROR`（格式/证据）/ `CMP_UNSUPPORTED`
#         （不可观测域），rc=1/2，绝不输出 PASS 兜底。
#   `--no-pass-line` 仅供独立 selftest 使用：成功也只打印 CMP_CHECK，不打印
#   正式锁步 PASS 行。
#==============================================================================

import argparse
import re
import sys

# ---- DUT trace v3 ----------------------------------------------------------
DUT_HEADER_TAG = 'DUT commit trace v3'
DUT_HEADER_LINES = (
    '# DUT commit trace v3 — RV32GC 2A Spike lockstep (sim/lockstep/tb_lockstep.sv)',
    '# format: <idx> pc=... xw= xrd= xval= fw= frd= fval= st= ssz= s0a= s0p= s0d= s0b= s1a= s1p= s1d= s1b= cw= cad= cva= cvo= fl= ff= fs= sd= obs=',
    '# x=真实 GPR 写回; f=真实 FP 64bit 写回; st=M_S_ISS 真实 store 请求; cw=显式 CSR 写; fl/ff=实际 fflags 更新; fs=实际 mstatus.FS; sd=实际 csr_mstatus_view[31]（不由 TB 推算）',
)
DUT_LINE_RE = re.compile(
    r'^(?P<idx>\d+)'
    r'\s+pc=0x(?P<pc>[0-9a-fA-F]{8})'
    r'\s+xw=(?P<xw>[01])\s+xrd=(?P<xrd>-?\d+)\s+xval=0x(?P<xval>[0-9a-fA-F]{8})'
    r'\s+fw=(?P<fw>[01])\s+frd=(?P<frd>-?\d+)\s+fval=0x(?P<fval>[0-9a-fA-F]{16})'
    r'\s+st=(?P<st>[0-2])\s+ssz=(?P<ssz>[0-3])'
    r'\s+s0a=0x(?P<s0a>[0-9a-fA-F]{8})\s+s0p=0x(?P<s0p>[0-9a-fA-F]{8})'
    r'\s+s0d=0x(?P<s0d>[0-9a-fA-F]{8})\s+s0b=0x(?P<s0b>[0-9a-fA-F]{1,2})'
    r'\s+s1a=0x(?P<s1a>[0-9a-fA-F]{8})\s+s1p=0x(?P<s1p>[0-9a-fA-F]{8})'
    r'\s+s1d=0x(?P<s1d>[0-9a-fA-F]{8})\s+s1b=0x(?P<s1b>[0-9a-fA-F]{1,2})'
    r'\s+cw=(?P<cw>[01])\s+cad=0x(?P<cad>[0-9a-fA-F]{1,3})\s+cva=0x(?P<cva>[0-9a-fA-F]{8})'
    r'\s+cvo=0x(?P<cvo>[0-9a-fA-F]{8})'
    r'\s+fl=(?P<fl>[01])\s+ff=0x(?P<ff>[0-9a-fA-F]{1,5})'
    r'\s+fs=(?P<fs>[0-3])\s+sd=(?P<sd>[01])\s+obs=(?P<obs>[01])\s*$')
DUT_END_RE = re.compile(
    r'^#\s*end\s+commits=(?P<commits>\d+)\s+cycles=(?P<cycles>\d+)'
    r'\s+reason=(?P<reason>\S+)\s+term_pc=0x(?P<term_pc>[0-9a-fA-F]+)'
    r'\s+uart_writes=(?P<uart>\d+)'
    r'\s+magic_aw=(?P<magic_aw>\d+)\s+magic_w=(?P<magic_w>\d+)'
    r'\s+magic_addr=0x(?P<magic_addr>[0-9a-fA-F]+)'
    r'\s+magic_data=0x(?P<magic_data>[0-9a-fA-F]+)'
    r'\s+magic_strb=0x(?P<magic_strb>[0-9a-fA-F]+)'
    r'\s+doorbell_aw=(?P<doorbell_aw>\d+)\s+doorbell_w=(?P<doorbell_w>\d+)'
    r'\s+doorbell_addr=0x(?P<doorbell_addr>[0-9a-fA-F]+)'
    r'\s+doorbell_data=0x(?P<doorbell_data>[0-9a-fA-F]+)'
    r'\s+doorbell_strb=0x(?P<doorbell_strb>[0-9a-fA-F]+)'
    r'\s+obs_err=(?P<obs_err>\d+)\s+bus_err=(?P<bus_err>\d+)\s*$')

# ---- Spike commit log ------------------------------------------------------
SPIKE_COMMIT_RE = re.compile(
    r'^core\s+(?P<hart>\d+):\s+(?P<priv>[0-3])\s+0x(?P<pc>[0-9a-fA-F]+)'
    r'\s+\((?P<insn>0x[0-9a-fA-F]+)\)(?P<rest>.*)$')
RE_XREG = re.compile(r'^x(?P<n>\d+)$')
RE_FREG = re.compile(r'^f(?P<n>\d+)$')
RE_CSR = re.compile(r'^c(?P<n>\d+)_(?P<name>\w+)$')
RE_VAL = re.compile(r'^0x[0-9a-fA-F]+$')
# Spike --log 的两种非 commit 行：完整反汇编语法及独立符号标签。
# 反汇编必须有完整行尾、mnemonic 和合法逗号分隔 operand；只匹配前缀会吞垃圾。
SPIKE_DISASM_RE = re.compile(
    r'^core\s+(?P<hart>\d+):\s+0x(?P<pc>[0-9a-fA-F]+)\s+'
    r'\(0x(?P<insn>[0-9a-fA-F]+)\)\s+'
    r'(?P<mnemonic>[A-Za-z_.][A-Za-z0-9_.$]*)(?:\s+(?P<ops>[^\r\n]+))?$')
SPIKE_LABEL_RE = re.compile(
    r'^core\s+\d+:\s+>>>>\s+[A-Za-z_.$][A-Za-z0-9_.$]*$')
SPIKE_NUM_RE = re.compile(r'^[-+]?(?:0x[0-9a-fA-F]+|\d+)$')
SPIKE_GPR_RE = re.compile(
    r'^(?:x(?:[0-9]|[12][0-9]|3[01])|zero|ra|sp|gp|tp|'
    r't[0-6]|s(?:[0-9]|1[01])|a[0-7])$')
SPIKE_FPR_RE = re.compile(
    r'^(?:f(?:[0-9]|[12][0-9]|3[01])|ft(?:[0-9]|1[01])|'
    r'fs(?:[0-9]|1[01])|fa[0-7])$')
SPIKE_PCREL_RE = re.compile(r'^pc\s+[+-]\s+[-+]?(?:0x[0-9a-fA-F]+|\d+)$')
SPIKE_MEM_RE = re.compile(
    r'^(?:[-+]?(?:0x[0-9a-fA-F]+|\d+))?\('
    r'(?:x(?:[0-9]|[12][0-9]|3[01])|zero|ra|sp|gp|tp|t[0-6]|'
    r's(?:[0-9]|1[01])|a[0-7])\)$')
SPIKE_TARGET_RE = re.compile(
    r'^(?:pc\s+[+-]\s+[-+]?(?:0x[0-9a-fA-F]+|\d+)|'
    r'[-+]?(?:0x[0-9a-fA-F]+|\d+)(?:\s+<[^<>\s]+>)?|'
    r'[A-Za-z_.$][A-Za-z0-9_.$]*)$')
SPIKE_CSR_RE = re.compile(r'^(?:0x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*)$')
SPIKE_MASK_RE = re.compile(r'^[iorw]+$')
SPIKE_RM_RE = re.compile(r'^(?:rne|rtz|rdn|rup|rmm|dyn)$')

# Only accept instruction/alias forms emitted by the supported RV32GC 2A
# trace programs. Each mnemonic has typed operand signatures; an unknown name,
# wrong register class, or extra/missing operand is not a disassembly line.
SPIKE_DISASM_SCHEMA = {}
def _add_disasm_schema(names, *signatures):
    for name in names.split():
        SPIKE_DISASM_SCHEMA[name] = signatures

_add_disasm_schema('lui auipc', ('gpr', 'imm'))
_add_disasm_schema('addi slti sltiu xori ori andi slli srli srai',
                    ('gpr', 'gpr', 'imm'))
_add_disasm_schema('add sub sll slt sltu xor srl sra or and mul mulh mulhsu '
                    'mulhu div divu rem remu', ('gpr', 'gpr', 'gpr'))
_add_disasm_schema('lb lh lw lbu lhu', ('gpr', 'mem'))
_add_disasm_schema('sb sh sw', ('gpr', 'mem'))
_add_disasm_schema('beq bne blt bge bltu bgeu', ('gpr', 'gpr', 'target'))
_add_disasm_schema('beqz bnez blez bgez bltz bgtz', ('gpr', 'target'))
_add_disasm_schema('jal', ('gpr', 'target'), ('target',))
_add_disasm_schema('j', ('target',))
_add_disasm_schema('jalr', ('gpr', 'mem'), ('gpr', 'gpr', 'imm'))
_add_disasm_schema('jr', ('gpr',))
_add_disasm_schema('ret nop ecall ebreak mret sret wfi fence.i', ())
_add_disasm_schema('mv not neg seqz snez sltz sgtz', ('gpr', 'gpr'))
_add_disasm_schema('li', ('gpr', 'imm'))
_add_disasm_schema('call tail', ('target',))
_add_disasm_schema('fence', ('mask', 'mask'))
_add_disasm_schema('sfence.vma', ('gpr', 'gpr'), ('gpr',))
_add_disasm_schema('csrr', ('gpr', 'csr'))
_add_disasm_schema('csrrw csrrs csrrc', ('gpr', 'csr', 'gpr'))
_add_disasm_schema('csrrwi csrrsi csrrci', ('gpr', 'csr', 'imm'))
_add_disasm_schema('csrw csrs csrc', ('csr', 'gpr'))
_add_disasm_schema('csrwi csrsi csrci', ('csr', 'imm'))
_add_disasm_schema('rdcycle rdtime rdinstret rdcycleh rdtimeh rdinstreth',
                    ('gpr',))
_add_disasm_schema('frflags frrm frcsr', ('gpr',))
_add_disasm_schema('fsflags fsrm fscsr', ('gpr', 'gpr'))
_add_disasm_schema('fadd.s fsub.s fmul.s fdiv.s fmin.s fmax.s',
                    ('fpr', 'fpr', 'fpr'), ('fpr', 'fpr', 'fpr', 'rm'))
_add_disasm_schema('fadd.d fsub.d fmul.d fdiv.d fmin.d fmax.d',
                    ('fpr', 'fpr', 'fpr'), ('fpr', 'fpr', 'fpr', 'rm'))
_add_disasm_schema('fsqrt.s fsqrt.d', ('fpr', 'fpr'), ('fpr', 'fpr', 'rm'))
_add_disasm_schema('fsgnj.s fsgnjn.s fsgnjx.s fsgnj.d fsgnjn.d fsgnjx.d',
                    ('fpr', 'fpr', 'fpr'))
_add_disasm_schema('feq.s flt.s fle.s feq.d flt.d fle.d',
                    ('gpr', 'fpr', 'fpr'))
_add_disasm_schema('fclass.s fclass.d', ('gpr', 'fpr'))
_add_disasm_schema('fmv.x.w fmv.x.d', ('gpr', 'fpr'))
_add_disasm_schema('fmv.w.x fmv.d.x', ('fpr', 'gpr'))
_add_disasm_schema('fmv.s fmv.d', ('fpr', 'fpr'))
_add_disasm_schema('fcvt.s.w fcvt.s.wu fcvt.d.w fcvt.d.wu',
                    ('fpr', 'gpr'), ('fpr', 'gpr', 'rm'))
_add_disasm_schema('fcvt.s.d fcvt.d.s',
                    ('fpr', 'fpr'), ('fpr', 'fpr', 'rm'))
_add_disasm_schema('fcvt.w.s fcvt.wu.s fcvt.w.d fcvt.wu.d',
                    ('gpr', 'fpr'), ('gpr', 'fpr', 'rm'))
_add_disasm_schema('flw fld', ('fpr', 'mem'))
_add_disasm_schema('fsw fsd', ('fpr', 'mem'))
_add_disasm_schema('fmadd.s fmsub.s fnmsub.s fnmadd.s fmadd.d fmsub.d '
                    'fnmsub.d fnmadd.d',
                    ('fpr', 'fpr', 'fpr', 'fpr'),
                    ('fpr', 'fpr', 'fpr', 'fpr', 'rm'))
# Common compressed aliases accepted by Spike when a source enables C.
_add_disasm_schema('c.nop', ())
_add_disasm_schema('c.addi c.li c.lui c.slli c.srli c.srai c.andi',
                    ('gpr', 'imm'))
_add_disasm_schema('c.mv c.add c.sub c.xor c.or c.and', ('gpr', 'gpr'))
_add_disasm_schema('c.j c.jal', ('target',))
_add_disasm_schema('c.beqz c.bnez', ('gpr', 'target'))
_add_disasm_schema('c.jr c.jalr', ('gpr',))
_add_disasm_schema('c.ebreak', ())
_add_disasm_schema('c.lw c.ld c.lwsp c.ldsp', ('gpr', 'mem'))
_add_disasm_schema('c.flw c.fld c.flwsp c.fldsp', ('fpr', 'mem'))
_add_disasm_schema('c.sw c.sd c.swsp c.sdsp', ('gpr', 'mem'))
_add_disasm_schema('c.fsw c.fsd c.fswsp c.fsdsp', ('fpr', 'mem'))
_add_disasm_schema('c.addi4spn c.addi16sp', ('gpr', 'imm'))

# ---- 不可比 CSR 读：逐项、按原因分类（不是"泛跳所有 counter"）-------------
# ① 非确定：与 DUT 微架构/宿主时间相关，原理上不可逐条对齐。
NONDET_CSR_READ = {
    0xC00: 'cycle',   0xC01: 'time',   0xC80: 'cycleh', 0xC81: 'timeh',
    0xB00: 'mcycle',  0xB80: 'mcycleh',
}
# ② instret/instreth：2026-10-22 新 Top（core_top f44a…、fetch_unit 64f8…、
#    SD 叶 0390…）已修复程序序投影；正式移出 Unsupported，按普通整数写回比较。
#    minstret/minstreth（0xB02/0xB82）读不在本轮移出范围（本轮只验证 instret/
#    instreth 读与 minstret 半写副作用），仍显式 UNSUPPORTED。
UNSUPPORTED_CSR_READ = {
    0xB02: 'minstret',  0xB82: 'minstreth',
}


class CmpError(Exception):
    """格式/证据类错误（rc=2）。"""


def _h(s):
    return int(s, 16)


def parse_dut(path):
    """解析 DUT v3 trace：仅接受固定三行元数据、连续数据与唯一末行。"""
    commits = []
    trailer = None
    metadata_count = 0
    try:
        fh = open(path, 'r', encoding='utf-8', errors='strict')
    except OSError as e:
        raise CmpError('打不开 DUT trace %s：%s' % (path, e))
    with fh:
        for lno, raw in enumerate(fh, 1):
            line = raw[:-1] if raw.endswith('\n') else raw
            if trailer is not None:
                raise CmpError('DUT trace 第 %d 行出现在 # end 之后（空行、重复 end、'
                               'end 后数据均拒绝）：%r' % (lno, line))
            if not line.strip():
                raise CmpError('DUT trace 第 %d 行为空白行（格式不允许空行）' % lno)
            if metadata_count < len(DUT_HEADER_LINES):
                expected = DUT_HEADER_LINES[metadata_count]
                if line != expected:
                    if metadata_count == 0 and line.startswith('# DUT commit trace'):
                        if 'old v1' in line or 'v1' in line:
                            raise CmpError('旧 v1 DUT trace 被严格 v3 入口拒绝；必须重生成')
                        raise CmpError('DUT trace 头/版本不匹配（仅接受严格 v3 三行元数据）：%r'
                                       % line[:160])
                    raise CmpError('DUT trace 第 %d 行元数据不匹配或缺字段；'
                                   '期望固定元数据第 %d 行' % (lno, metadata_count + 1))
                metadata_count += 1
                continue
            if line.startswith('#'):
                if re.match(r'^#\s*end\b', line):
                    m = DUT_END_RE.fullmatch(line)
                    if not m:
                        raise CmpError('DUT trace 第 %d 行 # end 格式损坏（末行证据不完整）：%r'
                                       % (lno, line))
                    trailer = {
                        'commits': int(m.group('commits')),
                        'cycles': int(m.group('cycles')),
                        'reason': m.group('reason'),
                        'term_pc': _h(m.group('term_pc')),
                        'uart_writes': int(m.group('uart')),
                        'magic_aw': int(m.group('magic_aw')),
                        'magic_w': int(m.group('magic_w')),
                        'magic_addr': _h(m.group('magic_addr')),
                        'magic_data': _h(m.group('magic_data')),
                        'magic_strb': _h(m.group('magic_strb')),
                        'doorbell_aw': int(m.group('doorbell_aw')),
                        'doorbell_w': int(m.group('doorbell_w')),
                        'doorbell_addr': _h(m.group('doorbell_addr')),
                        'doorbell_data': _h(m.group('doorbell_data')),
                        'doorbell_strb': _h(m.group('doorbell_strb')),
                        'obs_err': int(m.group('obs_err')),
                        'bus_err': int(m.group('bus_err')),
                    }
                    continue
                raise CmpError('DUT trace 第 %d 行出现未知/重复/错位元数据：%r' % (lno, line))
            m = DUT_LINE_RE.fullmatch(line)
            if not m:
                raise CmpError('DUT trace 第 %d 行不符合 v3 固定字段格式（缺字段/多字段/'
                               '含 X 或 Z 都失败）：%r' % (lno, line))
            idx = int(m.group('idx'))
            if idx != len(commits):
                raise CmpError('DUT trace 序号不连续：第 %d 行 idx=%d，期望 %d'
                               % (lno, idx, len(commits)))
            d = {
                'pc': _h(m.group('pc')),
                'xw': int(m.group('xw')), 'xrd': int(m.group('xrd')),
                'xval': _h(m.group('xval')),
                'fw': int(m.group('fw')), 'frd': int(m.group('frd')),
                'fval': _h(m.group('fval')),
                'st': int(m.group('st')), 'ssz': int(m.group('ssz')),
                's0a': _h(m.group('s0a')), 's0p': _h(m.group('s0p')),
                's0d': _h(m.group('s0d')), 's0b': _h(m.group('s0b')),
                's1a': _h(m.group('s1a')), 's1p': _h(m.group('s1p')),
                's1d': _h(m.group('s1d')), 's1b': _h(m.group('s1b')),
                'cw': int(m.group('cw')), 'cad': _h(m.group('cad')),
                'cva': _h(m.group('cva')), 'cvo': _h(m.group('cvo')),
                'fl': int(m.group('fl')), 'ff': _h(m.group('ff')),
                'fs': int(m.group('fs')), 'sd': int(m.group('sd')),
                'obs': int(m.group('obs')), 'raw': line,
            }
            if d['obs'] != 1:
                raise CmpError('DUT trace 第 %d 行 obs=0（已声明观测域含 X/Z）' % lno)
            if d['xw']:
                if not (1 <= d['xrd'] <= 31):
                    raise CmpError('DUT trace 第 %d 行 xw=1 但 xrd=%d（x0/越界写）'
                                   % (lno, d['xrd']))
            elif d['xrd'] != -1:
                raise CmpError('DUT trace 第 %d 行 xw=0 但 xrd=%d（字段冲突）'
                               % (lno, d['xrd']))
            if d['fw']:
                if not (0 <= d['frd'] <= 31):
                    raise CmpError('DUT trace 第 %d 行 fw=1 但 frd=%d' % (lno, d['frd']))
                if d['xw']:
                    raise CmpError('DUT trace 第 %d 行同时 xw=1 与 fw=1（类型冲突）' % lno)
            elif d['frd'] != -1:
                raise CmpError('DUT trace 第 %d 行 fw=0 但 frd=%d（字段冲突）'
                               % (lno, d['frd']))
            if d['st'] == 0:
                if (d['ssz'] != 0 or d['s0a'] or d['s0p'] or d['s0d'] or d['s0b']
                        or d['s1a'] or d['s1p'] or d['s1d'] or d['s1b']):
                    raise CmpError('DUT trace 第 %d 行 st=0 但 store 字段非零（字段冲突）'
                                   % lno)
            elif d['st'] == 1:
                if d['s1a'] or d['s1p'] or d['s1d'] or d['s1b']:
                    raise CmpError('DUT trace 第 %d 行 st=1 但 s1* 非零（字段冲突）' % lno)
                if d['ssz'] == 3:
                    raise CmpError('DUT trace 第 %d 行 fsd 只有单相（st=1, ssz=3）；'
                                   '拒绝用单相冒充 64 位落盘' % lno)
            elif d['ssz'] != 3:
                raise CmpError('DUT trace 第 %d 行 st=2 但 ssz=%d（仅 fsd 允许）'
                               % (lno, d['ssz']))
            if d['cw']:
                if d['cad'] == 0:
                    raise CmpError('DUT trace 第 %d 行 cw=1 但 cad=0' % lno)
            elif d['cad'] != 0 or d['cva'] != 0 or d['cvo'] != 0:
                raise CmpError('DUT trace 第 %d 行 cw=0 但 cad/cva/cvo 非零（字段冲突）'
                               % lno)
            if d['fl'] and d['ff'] > 0x1F:
                raise CmpError('DUT trace 第 %d 行 fl=1 但 ff=0x%x 超过 5 bit'
                               % (lno, d['ff']))
            if not d['fl'] and d['ff'] != 0:
                raise CmpError('DUT trace 第 %d 行 fl=0 但 ff=0x%x（字段冲突）'
                               % (lno, d['ff']))
            commits.append(d)
    if metadata_count != len(DUT_HEADER_LINES):
        raise CmpError('DUT trace 缺少固定 v3 元数据行（读到 %d/%d）'
                       % (metadata_count, len(DUT_HEADER_LINES)))
    if trailer is None:
        raise CmpError('DUT trace 缺少唯一末行证据（# end ...）')
    return commits, trailer


def parse_spike_rest(rest, where):
    """把 commit 行剩余字段拆成 xN 写 / fN 写 / mem / CSR。"""
    toks = rest.split()
    out = {'xw': {}, 'fw': {}, 'mem': [], 'csr': []}
    i = 0
    while i < len(toks):
        t = toks[i]
        m = RE_XREG.match(t)
        if m:
            if i + 1 >= len(toks) or not RE_VAL.match(toks[i + 1]):
                raise CmpError('%s：x 寄存器字段后不是 0x 值：%r %r'
                               % (where, t, toks[i + 1:i + 2]))
            n = int(m.group('n'))
            if n in out['xw']:
                raise CmpError('%s：同一提交重复写 x%d（dict lastwins 被禁）'
                               % (where, n))
            out['xw'][n] = int(toks[i + 1], 16)
            i += 2
            continue
        m = RE_FREG.match(t)
        if m:
            if i + 1 >= len(toks) or not RE_VAL.match(toks[i + 1]):
                raise CmpError('%s：f 寄存器字段后不是 0x 值：%r %r'
                               % (where, t, toks[i + 1:i + 2]))
            n = int(m.group('n'))
            if n in out['fw']:
                raise CmpError('%s：同一提交重复写 f%d（dict lastwins 被禁）'
                               % (where, n))
            out['fw'][n] = int(toks[i + 1], 16)
            i += 2
            continue
        if t == 'mem':
            if i + 1 >= len(toks) or not RE_VAL.match(toks[i + 1]):
                raise CmpError('%s：mem 字段格式异常：%r' % (where, toks[i:i + 3]))
            addr = int(toks[i + 1], 16)
            i += 2
            data = None
            if i < len(toks) and RE_VAL.match(toks[i]):
                data = int(toks[i], 16)
                i += 1
            out['mem'].append((addr, data))
            continue
        m = RE_CSR.match(t)
        if m:
            if i + 1 >= len(toks) or not RE_VAL.match(toks[i + 1]):
                raise CmpError('%s：CSR 字段后不是 0x 值：%r' % (where, t))
            n = int(m.group('n'))
            v = int(toks[i + 1], 16)
            if any(a == n for (a, _) in out['csr']):
                raise CmpError('%s：同一提交重复 CSR c%d（同值重复也拒绝）'
                               % (where, n))
            out['csr'].append((n, v))
            i += 2
            continue
        raise CmpError('%s：无法识别的 commit 字段 %r（本机 spike 格式可能已变化）'
                       % (where, t))
    return out


def _valid_spike_operand(kind, operand):
    if kind == 'reg':
        return bool(SPIKE_GPR_RE.fullmatch(operand) or SPIKE_FPR_RE.fullmatch(operand))
    if kind == 'gpr':
        return bool(SPIKE_GPR_RE.fullmatch(operand))
    if kind == 'fpr':
        return bool(SPIKE_FPR_RE.fullmatch(operand))
    if kind == 'imm':
        return bool(SPIKE_NUM_RE.fullmatch(operand))
    if kind == 'mem':
        return bool(SPIKE_MEM_RE.fullmatch(operand))
    if kind == 'target':
        return bool(SPIKE_TARGET_RE.fullmatch(operand))
    if kind == 'csr':
        return bool(SPIKE_CSR_RE.fullmatch(operand))
    if kind == 'rm':
        return bool(SPIKE_RM_RE.fullmatch(operand))
    if kind == 'mask':
        return bool(SPIKE_MASK_RE.fullmatch(operand))
    return False


def _valid_spike_disasm(line):
    """Accept only supported Spike mnemonics and their typed operand schemas."""
    m = SPIKE_DISASM_RE.fullmatch(line)
    if not m:
        return False
    schemas = SPIKE_DISASM_SCHEMA.get(m.group('mnemonic'))
    if schemas is None:
        return False
    ops = m.group('ops')
    operands = [] if ops is None else [op.strip() for op in ops.split(',')]
    return any(len(operands) == len(schema) and
               all(_valid_spike_operand(kind, operand)
                   for kind, operand in zip(schema, operands))
               for schema in schemas)


def parse_spike(path):
    """解析 Spike commit；只忽略完整合法的 disasm/label 行。"""
    commits = []
    try:
        fh = open(path, 'r', encoding='utf-8', errors='strict')
    except OSError as e:
        raise CmpError('打不开 Spike trace %s：%s' % (path, e))
    with fh:
        for lno, raw in enumerate(fh, 1):
            line = raw[:-1] if raw.endswith('\n') else raw
            if not line.strip():
                raise CmpError('Spike trace 第 %d 行为空白行（拒绝跳过）' % lno)
            if not line.startswith('core'):
                raise CmpError('Spike trace 第 %d 行不是 core 记录（未知/损坏行，'
                               '拒绝泛跳）：%r' % (lno, line))
            if 'exception' in line:
                raise CmpError('Spike trace 第 %d 行出现 exception（程序发生陷阱，'
                               '不能作为锁步轨迹）：%r' % (lno, line))
            m = SPIKE_COMMIT_RE.fullmatch(line)
            if m:
                where = 'Spike trace 第 %d 行' % lno
                commits.append({
                    'pc': int(m.group('pc'), 16),
                    'priv': int(m.group('priv')),
                    'insn': int(m.group('insn'), 16),
                    'rest': parse_spike_rest(m.group('rest'), where),
                    'raw': line,
                })
                continue
            if SPIKE_LABEL_RE.fullmatch(line) or _valid_spike_disasm(line):
                continue
            raise CmpError('Spike trace 第 %d 行是未知 core 形态（既非 commit、'
                           '合法完整反汇编，也非符号标签；拒绝吞掉）：%r'
                           % (lno, line))
    return commits


def fmt_dut(c):
    parts = ['pc=0x%08x xw=%d xrd=%d xval=0x%08x fw=%d frd=%d fval=0x%016x'
             % (c['pc'], c['xw'], c['xrd'], c['xval'], c['fw'], c['frd'], c['fval'])]
    if c['st']:
        parts.append('st=%d ssz=%d s0a=0x%08x s0d=0x%08x s0b=0x%x s1a=0x%08x s1d=0x%08x s1b=0x%x'
                     % (c['st'], c['ssz'], c['s0a'], c['s0d'], c['s0b'],
                        c['s1a'], c['s1d'], c['s1b']))
    if c['cw']:
        parts.append('cw=1 cad=0x%03x cva=0x%08x cvo=0x%08x'
                     % (c['cad'], c['cva'], c['cvo']))
    if c['fl']:
        parts.append('fl=1 ff=0x%05x' % c['ff'])
    parts.append('fs=%d sd=%d' % (c['fs'], c['sd']))
    return ' '.join(parts)


def insn_class(insn):
    """返回 (kind, width_or_funct3)。kind ∈ int_store/fsw/fsd/load/fp_load/fp/system/other。"""
    op = insn & 0x7f
    f3 = (insn >> 12) & 0x7
    if op == 0x23:                          # S-type 整数 store
        if f3 <= 2:
            return ('int_store', (1, 2, 4)[f3])
        return ('int_store_bad', f3)
    if op == 0x27:                          # FP load/store
        if f3 == 2:
            return ('fsw', 4)
        if f3 == 3:
            return ('fsd', 8)
        return ('fp_load', f3)
    if op == 0x07:
        return ('load', f3)
    if op in (0x53, 0x43, 0x47, 0x4b):
        return ('fp', None)
    if op == 0x73:
        return ('system', f3)
    return ('other', None)


def csr_write_semantics(insn):
    """从参考 insn 独立解 CSR 地址与"是否真写"。

    返回 None（非 CSR 指令）或 (want, csr_num)，want ∈ write/none。
      CSRRW/CSRRWI 总是写；CSRRS/CSRRC 仅 rs1!=x0 写；
      CSRRSI/CSRRCI 仅 zimm!=0 写。这里只看参考编码，不依赖 DUT cw。
    """
    if (insn & 0x7F) != 0x73:
        return None
    f3   = (insn >> 12) & 0x7
    csr  = (insn >> 20) & 0xFFF
    rs1  = (insn >> 15) & 0x1F
    if f3 == 1:                           # CSRRW
        return ('write', csr)
    if f3 in (2, 3):                      # CSRRS / CSRRC
        return ('write' if rs1 != 0 else 'none', csr)
    if f3 == 5:                           # CSRRWI
        return ('write', csr)
    if f3 in (6, 7):                      # CSRRSI / CSRRCI
        return ('write' if rs1 != 0 else 'none', csr)
    return None


def expected_store_mask(kind, addr, width):
    off = addr & 3
    if kind == 'int_store' and width == 1:
        return 1 << off
    if kind == 'int_store' and width == 2:
        return 3 << off
    return 0xF


def narrow_from_lane(lane32, addr, width):
    shift = 8 * (addr & 3)
    mask = (1 << (8 * width)) - 1
    return (lane32 >> shift) & mask


def expand_dut_csr(addr, val, old):
    """DUT 落地 CSR 写 → {Spike c<num>: (新值, 写前值)}；写前值仅用于 no-op 判定。"""
    if addr == 0x003:                       # fcsr → fflags + frm
        return {0x001: (val & 0x1F, old & 0x1F),
                0x002: ((val >> 5) & 0x7, (old >> 5) & 0x7)}
    if addr == 0x001:
        return {0x001: (val & 0x1F, old & 0x1F)}
    if addr == 0x002:
        return {0x002: (val & 0x7, old & 0x7)}
    return {addr: (val, old)}


def main(argv=None):
    ap = argparse.ArgumentParser(description='DUT v3 提交 trace ↔ Spike commit log 逐条比对')
    ap.add_argument('--dut', required=True)
    ap.add_argument('--spike', required=True)
    ap.add_argument('--min-commits', type=int, default=60)
    ap.add_argument('--context', type=int, default=8)
    ap.add_argument('--term-pc', type=lambda s: int(s, 0), default=0x80000120)
    ap.add_argument('--magic-addr', type=lambda s: int(s, 0), default=0x80002000)
    ap.add_argument('--magic-val', type=lambda s: int(s, 0), default=0x600D5EED)
    ap.add_argument('--magic-strb', type=lambda s: int(s, 0), default=0xF)
    ap.add_argument('--doorbell-addr', type=lambda s: int(s, 0), default=0x1FE001E0)
    ap.add_argument('--doorbell-val', type=lambda s: int(s, 0), default=0x5A)
    ap.add_argument('--doorbell-strb', type=lambda s: int(s, 0), default=0xF)
    ap.add_argument('--pa-mode', choices=('bare', 'translated'), default='bare',
                    help='bare: 逐相比对 s0p/s1p==s0a/s1a；translated: 无独立 oracle ⇒ UNSUPPORTED')
    ap.add_argument('--no-pass-line', action='store_true',
                    help='仅供独立 selftest：成功也不打印正式 LOCKSTEP PASS 行')
    args = ap.parse_args(argv)

    try:
        dut, trailer = parse_dut(args.dut)
        spk = parse_spike(args.spike)
    except CmpError as e:
        print('CMP_ERROR: %s' % e)
        return 2

    print('CMP_SUMMARY: trace_v=3 dut_commits=%d spike_commits=%d min_commits=%d'
          % (len(dut), len(spk), args.min_commits))
    print('CMP_SUMMARY: DUT 末行 reason=%s term_pc=0x%08x cycles=%d uart_writes=%d '
          'obs_err=%d bus_err=%d'
          % (trailer['reason'], trailer['term_pc'], trailer['cycles'],
             trailer['uart_writes'], trailer['obs_err'], trailer['bus_err']))

    # ---- 证据/长度检查（fail-closed）----
    if trailer['reason'] != 'TERM_PC':
        print('CMP_ERROR: DUT 末行 reason=%s（非 TERM_PC ⇒ 未跑到 lockstep_spin）'
              % trailer['reason'])
        return 2
    if trailer['term_pc'] != args.term_pc:
        print('CMP_ERROR: DUT 末行 term_pc=0x%08x 与 --term-pc=0x%08x 不一致'
              % (trailer['term_pc'], args.term_pc))
        return 2
    if trailer['uart_writes'] < 1:
        print('CMP_ERROR: DUT 侧未观测到 UART 结束铃（uart_writes=%d）'
              % trailer['uart_writes'])
        return 2
    if trailer['commits'] != len(dut):
        print('CMP_ERROR: 末行 commits=%d 与 trace 实际条数 %d 不一致'
              % (trailer['commits'], len(dut)))
        return 2
    if trailer['obs_err'] != 0:
        print('CMP_ERROR: DUT 末行 obs_err=%d（已声明观测域含 X/Z 或 fflags 事件'
              '无法对齐）' % trailer['obs_err'])
        return 2
    if trailer['bus_err'] != 0:
        print('CMP_ERROR: DUT 末行 bus_err=%d（AXI 写数据无配对 AW）'
              % trailer['bus_err'])
        return 2
    if len(dut) < args.min_commits:
        print('CMP_ERROR: DUT 提交条数 %d < 下限 %d' % (len(dut), args.min_commits))
        return 2
    if len(spk) <= len(dut):
        print('CMP_ERROR: Spike 轨迹仅 %d 条 commit，不足以覆盖 DUT 的 %d 条（≤ ⇒ 无法比对）'
              % (len(spk), len(dut)))
        return 2

    # ---- DUT 侧 AXI 锚点（magic/doorbell 各恰一次）----
    def check_bus_anchor(name, aw, w, addr, data, strb, eaddr, edata, estrb):
        if aw != 1 or w != 1:
            return ('%s AXI 写次数 aw=%d w=%d（必须恰一次；DUT 侧证据，'
                    'Spike 单方停机不能替代）' % (name, aw, w))
        if addr != eaddr:
            return ('%s AXI 地址=0x%08x，期望 0x%08x' % (name, addr, eaddr))
        if data != edata:
            return ('%s AXI 数据=0x%08x，期望 0x%08x' % (name, data, edata))
        if strb != estrb:
            return ('%s AXI strb=0x%x，期望 0x%x（DUT 实际字节使能）'
                    % (name, strb, estrb))
        return None

    err = check_bus_anchor('magic', trailer['magic_aw'], trailer['magic_w'],
                           trailer['magic_addr'], trailer['magic_data'],
                           trailer['magic_strb'], args.magic_addr,
                           args.magic_val, args.magic_strb)
    if err:
        print('CMP_ERROR: %s' % err)
        return 2
    err = check_bus_anchor('doorbell', trailer['doorbell_aw'], trailer['doorbell_w'],
                           trailer['doorbell_addr'], trailer['doorbell_data'],
                           trailer['doorbell_strb'], args.doorbell_addr,
                           args.doorbell_val, args.doorbell_strb)
    if err:
        print('CMP_ERROR: %s' % err)
        return 2

    # ---- 逐条比对 ----
    n_store = n_csr = n_csr_noop = n_fp64 = n_fflags = n_fs = 0

    def dump_divergence(n, msg):
        print('CMP_DIVERGENCE: 第 %d 条：%s' % (n, msg))
        lo = max(0, n - args.context)
        hi = min(len(dut), n + 1 + args.context)
        print('---- DUT/SPIKE 上下文（第 %d..%d 条）----' % (lo, hi - 1))
        for i in range(lo, hi):
            mark = '>>' if i == n else '  '
            if i < len(dut):
                print('%s [%4d] DUT   %s' % (mark, i, fmt_dut(dut[i])))
            if i < len(spk):
                print('%s [%4d] SPIKE %s' % (mark, i, spk[i]['raw'].strip()))

    # Spike status state is tracked independently in program order.  A status
    # record updates both fields; frames without a record inherit the previous
    # reference state.  DUT FS/SD never seed or repair this reference.
    ref_fs, ref_sd = 0, 0
    for i in range(len(dut)):
        d, s = dut[i], spk[i]
        if s['priv'] != 3:
            dump_divergence(i, 'Spike 侧特权级=%d（本程序应恒为 M=3；'
                               '可能发生陷阱/权限变化）' % s['priv'])
            return 1
        if d['pc'] != s['pc']:
            dump_divergence(i, 'DUT pc=0x%08x  spike pc=0x%08x（PC 不等/前后错位）'
                               % (d['pc'], s['pc']))
            return 1

        kind, kw = insn_class(s['insn'])
        rest = s['rest']
        sp_status = next(((num, val) for num, val in rest['csr']
                          if num in (0x300, 0x100)), None)
        if sp_status is not None:
            status_num, status_val = sp_status
            ref_fs = (status_val >> 13) & 0x3
            ref_sd = (status_val >> 31) & 1
        if d['fs'] != ref_fs:
            dump_divergence(i, 'pc=0x%08x field=mstatus.FS got=%d ref=%d '
                               '(Spike program-order state)' % (d['pc'], d['fs'], ref_fs))
            return 1
        if d['sd'] != ref_sd:
            dump_divergence(i, 'pc=0x%08x field=mstatus.SD got=%d ref=%d '
                               '(actual DUT csr_mstatus_view[31], Spike program-order state)'
                               % (d['pc'], d['sd'], ref_sd))
            return 1
        n_fs += 1

        # ---- 非确定 CSR 读：显式拒绝（逐项）----
        if kind == 'system':
            f3 = kw
            if f3 in (1, 2, 3, 5, 6, 7):
                csr_num = (s['insn'] >> 20) & 0xFFF
                rd = (s['insn'] >> 7) & 0x1F
                if csr_num in NONDET_CSR_READ and rd != 0:
                    print('CMP_UNSUPPORTED: 第 %d 条 pc=0x%08x 读 %s(0x%03x) 到 x%d；'
                          '该 counter 与 DUT 微架构/宿主时间相关，本锁步无法比较'
                          '（逐项拒绝，不泛跳其它 CSR）'
                          % (i, d['pc'], NONDET_CSR_READ[csr_num], csr_num, rd))
                    return 2
                if csr_num in UNSUPPORTED_CSR_READ and rd != 0:
                    print('CMP_UNSUPPORTED: 第 %d 条 pc=0x%08x 读 %s(0x%03x) 到 x%d；'
                          'instret/instreth 已移出并逐条比较；minstret/minstreth 读'
                          '本轮未移出（只验证半写副作用），显式判不可比'
                          % (i, d['pc'], UNSUPPORTED_CSR_READ[csr_num], csr_num, rd))
                    return 2

        # ---- CSR 身份：先从参考 insn 独立解 csr 地址/真写语义，再核 DUT cw ----
        ref_csr = csr_write_semantics(s['insn'])
        if ref_csr is not None:
            want_csr, csr_num = ref_csr
            if want_csr == 'write':
                if not d['cw']:
                    dump_divergence(i, '参考 insn 是 CSR 写（csr=0x%03x），但 DUT 提交 '
                                       'trace 无 cw（不得被当隐式 FS/吞掉）' % csr_num)
                    return 1
                if d['cad'] != csr_num:
                    dump_divergence(i, '参考 insn 写 csr=0x%03x，DUT cw cad=0x%03x'
                                       '（CSR 身份错）' % (csr_num, d['cad']))
                    return 1
            else:
                if d['cw']:
                    dump_divergence(i, '参考 insn 是只读 CSRRS/RC（rs1/zimm=0，'
                                       'csr=0x%03x），DUT 却报 cw=1 cad=0x%03x'
                                       % (csr_num, d['cad']))
                    return 1
        elif d['cw']:
            dump_divergence(i, '参考 insn 不是 CSR 写，DUT 却报 cw=1 cad=0x%03x'
                               '（伪 CSR 记录）' % d['cad'])
            return 1

        # ---- 整数写回 ----
        if len(rest['xw']) > 1:
            dump_divergence(i, 'Spike 同一提交有多个整数写（不支持）：%r'
                               % (rest['xw'],))
            return 2
        if d['xw']:
            if not rest['xw']:
                dump_divergence(i, 'DUT 写 x%d=0x%08x，Spike 同 PC 无整数写%s'
                                   % (d['xrd'], d['xval'],
                                      '（Spike 是浮点写 f%d）'
                                      % list(rest['fw'])[0] if rest['fw'] else ''))
                return 1
            if d['xrd'] not in rest['xw']:
                dump_divergence(i, 'DUT 写 x%d=0x%08x，Spike 写的是 x%d（类型/寄存器号错）'
                                   % (d['xrd'], d['xval'], list(rest['xw'])[0]))
                return 1
            if rest['xw'][d['xrd']] != d['xval']:
                dump_divergence(i, 'DUT x%d 写值=0x%08x  spike 写值=0x%08x'
                                   % (d['xrd'], d['xval'], rest['xw'][d['xrd']]))
                return 1
            if rest['fw']:
                dump_divergence(i, 'DUT 整数写与 Spike 浮点写同时出现（x/f 类型冲突）')
                return 1
        else:
            if rest['xw']:
                n, v = next(iter(rest['xw'].items()))
                dump_divergence(i, 'DUT 未写整数寄存器，但 Spike 写了 x%d=0x%08x'
                                   % (n, v))
                return 1

        # ---- 浮点写回（64 位全比）----
        if len(rest['fw']) > 1:
            dump_divergence(i, 'Spike 同一提交有多个浮点写（不支持）：%r'
                               % (rest['fw'],))
            return 2
        if d['fw']:
            if not rest['fw']:
                dump_divergence(i, 'DUT 写 f%d=0x%016x，Spike 同 PC 无浮点写%s'
                                   % (d['frd'], d['fval'],
                                      '（Spike 是整数写 x%d）'
                                      % list(rest['xw'])[0] if rest['xw'] else ''))
                return 1
            if d['frd'] not in rest['fw']:
                dump_divergence(i, 'DUT 写 f%d，Spike 写的是 f%d（浮点寄存器号错）'
                                   % (d['frd'], list(rest['fw'])[0]))
                return 1
            sv = rest['fw'][d['frd']]
            if sv != d['fval']:
                dump_divergence(i, 'DUT f%d 写值=0x%016x  spike 写值=0x%016x'
                                   '（64 位比较；S 结果高 32 位应为 NaN-box）'
                                   % (d['frd'], d['fval'], sv))
                return 1
            n_fp64 += 1
        else:
            if rest['fw']:
                n, v = next(iter(rest['fw'].items()))
                dump_divergence(i, 'DUT 未写浮点寄存器，但 Spike 写了 f%d=0x%016x'
                                   % (n, v))
                return 1

        # ---- store ----
        is_store = kind in ('int_store', 'fsw', 'fsd')
        if kind == 'int_store_bad':
            dump_divergence(i, 'Spike 整数 store funct3=%d 非法' % kw)
            return 2
        # Spike 的 mem 记录：store 必须恰一条且带数据；load 的 mem 只有地址
        mem_store = [(a, v) for (a, v) in rest['mem'] if v is not None]
        if is_store:
            if len(mem_store) != 1:
                dump_divergence(i, 'Spike store 提交的 mem 记录数=%d（期望 1 条带数据）'
                                   % len(mem_store))
                return 2
            sp_addr, sp_data = mem_store[0]
            width = kw
            if d['st'] == 0:
                dump_divergence(i, 'Spike 是 store（addr=0x%08x data=0x%x），'
                                   '但 DUT 提交 trace 没有 store 记录（缺失/未采样）'
                                   % (sp_addr, sp_data))
                return 1
            if kind == 'fsd':
                if d['st'] != 2:
                    dump_divergence(i, 'fsd 需要两相 4B store 记录（st=2），DUT st=%d'
                                       % d['st'])
                    return 1
                exp_b = 0xF
                if d['ssz'] != 3:
                    dump_divergence(i, 'fsd ssz=%d（期望 3）' % d['ssz'])
                    return 1
                if d['s0a'] != sp_addr:
                    dump_divergence(i, 'fsd DUT 低相地址=0x%08x  spike 地址=0x%08x'
                                       % (d['s0a'], sp_addr))
                    return 1
                if d['s1a'] != ((sp_addr + 4) & 0xFFFFFFFF):
                    dump_divergence(i, 'fsd DUT 高相地址=0x%08x 期望 0x%08x'
                                       % (d['s1a'], (sp_addr + 4) & 0xFFFFFFFF))
                    return 1
                if d['s0b'] != exp_b or d['s1b'] != exp_b:
                    dump_divergence(i, 'fsd DUT strb=0x%x/0x%x 期望 0x%x/0x%x'
                                       % (d['s0b'], d['s1b'], exp_b, exp_b))
                    return 1
                dut64 = ((d['s1d'] & 0xFFFFFFFF) << 32) | (d['s0d'] & 0xFFFFFFFF)
                if dut64 != sp_data:
                    dump_divergence(i, 'fsd DUT 64 位数据=0x%016x  spike=0x%016x'
                                       % (dut64, sp_data))
                    return 1
            else:
                if d['st'] != 1:
                    dump_divergence(i, 'DUT store 记录 st=%d（期望 1）' % d['st'])
                    return 1
                if d['ssz'] != (2 if width == 4 else {1: 0, 2: 1}[width]):
                    dump_divergence(i, 'DUT store ssz=%d 与 width=%d 不符'
                                       % (d['ssz'], width))
                    return 1
                if d['s0a'] != sp_addr:
                    dump_divergence(i, 'DUT store 地址=0x%08x  spike 地址=0x%08x'
                                       % (d['s0a'], sp_addr))
                    return 1
                exp_b = expected_store_mask(kind, sp_addr, width)
                if d['s0b'] != exp_b:
                    dump_divergence(i, 'DUT store strb=0x%x  ISA 期望 0x%x'
                                       '（addr=0x%08x width=%d）'
                                       % (d['s0b'], exp_b, sp_addr, width))
                    return 1
                dv = narrow_from_lane(d['s0d'], sp_addr, width)
                mask = (1 << (8 * width)) - 1
                if dv != (sp_data & mask):
                    dump_divergence(i, 'DUT store 数据（车道 0x%08x 抽取）=0x%x  '
                                       'spike=0x%x（addr=0x%08x width=%d）'
                                       % (d['s0d'], dv, sp_data & mask, sp_addr, width))
                    return 1
            if args.pa_mode == 'bare':
                if d['s0p'] != d['s0a']:
                    dump_divergence(i, 'Bare 模式 DUT store 物理地址=0x%08x 与虚拟'
                                       '地址=0x%08x 不等（PA 采样错误）'
                                       % (d['s0p'], d['s0a']))
                    return 1
                if d['st'] == 2 and d['s1p'] != d['s1a']:
                    dump_divergence(i, 'Bare 模式 fsd 高相 PA=0x%08x 与 VA=0x%08x 不等'
                                       % (d['s1p'], d['s1a']))
                    return 1
            elif args.pa_mode == 'translated':
                print('CMP_UNSUPPORTED: 第 %d 条 store 在翻译模式（--pa-mode translated）'
                      '下没有独立 PA oracle；不默认把 s0p/s1p 当诊断' % i)
                return 2
            n_store += 1
        else:
            if d['st'] != 0:
                dump_divergence(i, 'DUT 提交 trace 声称 store（st=%d, addr=0x%08x），'
                                   '但 Spike 同 PC 不是 store（额外记录）'
                                   % (d['st'], d['s0a']))
                return 1

        # ---- 显式 CSR 写 + 隐式 fflags + mstatus.FS ----
        expected_csr = {}          # addr -> (新值, 写前值 or None=必须出现)
        if d['cw']:
            exp = expand_dut_csr(d['cad'], d['cva'], d['cvo'])
            for a, vv in exp.items():
                expected_csr[a] = vv
            n_csr += 1
        if d['fl']:
            if 0x001 in expected_csr and expected_csr[0x001][0] != d['ff']:
                dump_divergence(i, '同一提交显式 CSR 写(fcsr/fflags)与隐式 fflags '
                                   '冲突：0x%x vs 0x%x'
                                   % (expected_csr[0x001][0], d['ff']))
                return 1
            expected_csr[0x001] = (d['ff'], None)
            n_fflags += 1

        sp_csr = {}
        for (num, val) in rest['csr']:
            if num in sp_csr and sp_csr[num] != val:
                dump_divergence(i, 'Spike 同一提交对 c%d 有冲突记录 0x%x/0x%x'
                                   % (num, sp_csr[num], val))
                return 2
            sp_csr[num] = val

        for a, (v, old) in expected_csr.items():
            if a not in sp_csr:
                # 锁写 no-op：仅对 PMP address 寄存器开放（0x3B0..0x3BF）。
                # 理由：csr_file 的 rd_waddr_cur 只对 pmpaddr 有专用 one-hot 现值
                # （pmpaddr_wr），其余 CSR 回退 rdata_r（是 raddr 视角，不是 waddr
                # 现值），不能拿它判定"无变化"；伪造 cvo=0 会误放行缺失记录。
                # 其他 CSR 的 no-op 豁免需要产品新增"写前值/写有效"输出后再开，
                # 当前一律按缺失记录失败（fail-closed）。
                if 0x3B0 <= a <= 0x3BF and old is not None and v == old:
                    n_csr_noop += 1
                    continue
                dump_divergence(i, 'DUT 声明 CSR c%d 落地值=0x%08x（写前=0x%08x），'
                                   'Spike 同 PC 无该 CSR 记录'
                                   % (a, v, old if old is not None else 0))
                return 1
            if sp_csr[a] != v:
                if a == 0x001:
                    dump_divergence(i, 'pc=0x%08x field=fflags got=0x%08x ref=0x%08x; '
                                       'DUT CSR c1 落地值与 Spike 不同'
                                       % (d['pc'], v, sp_csr[a]))
                else:
                    dump_divergence(i, 'DUT CSR c%d 落地值=0x%08x  spike=0x%08x'
                                       % (a, v, sp_csr[a]))
                return 1
        for num, val in sp_csr.items():
            if num in expected_csr:
                continue
            if num == 0x300:
                # c768 是 Spike 的程序序状态更新/记录；FS 与 SD 已在每个
                # commit 的独立 ref_fs/ref_sd 状态比较，不在此处按有记录才比。
                continue
            if num == 0x001:
                dump_divergence(i, 'pc=0x%08x field=fflags got=absent ref=0x%08x; '
                                   'Spike 有 CSR c1 记录但 DUT 未声明更新'
                                   % (d['pc'], val))
            else:
                dump_divergence(i, 'Spike 有 CSR c%d=0x%08x 记录，但 DUT 提交 trace 未声明'
                                   '（额外记录/域不可观测）' % (num, val))
            return 1

    # ---- 结束锚点：DUT 提交 trace 与 Spike 必须都证明跑到同一结尾 ----
    magic_hits = []
    doorbell_hits = []
    for i in range(len(dut)):
        d = dut[i]
        w = {0: 1, 1: 2, 2: 4}.get(d['ssz'])
        if d['st'] and d['s0a'] == args.magic_addr and w:
            val = narrow_from_lane(d['s0d'], args.magic_addr, w)
            if val == args.magic_val and d['s0b'] == args.magic_strb:
                magic_hits.append(i)
        if d['st'] and d['s0a'] == args.doorbell_addr and w:
            val = narrow_from_lane(d['s0d'], args.doorbell_addr, w)
            if val == args.doorbell_val and d['s0b'] == args.doorbell_strb:
                doorbell_hits.append(i)
    if len(magic_hits) != 1:
        print('CMP_ERROR: DUT 提交 trace 中 magic store（addr=0x%08x data=0x%08x）'
              '命中 %d 次（期望恰 1；Spike 单方 mem 记录不算 DUT 完成）'
              % (args.magic_addr, args.magic_val, len(magic_hits)))
        return 2
    if len(doorbell_hits) != 1:
        print('CMP_ERROR: DUT 提交 trace 中 doorbell store（addr=0x%08x data=0x%08x）'
              '命中 %d 次（期望恰 1）'
              % (args.doorbell_addr, args.doorbell_val, len(doorbell_hits)))
        return 2
    if doorbell_hits[0] != len(dut) - 1:
        print('CMP_ERROR: DUT doorbell store 在第 %d 条，不是最后一条（末条=%d）'
              % (doorbell_hits[0], len(dut) - 1))
        return 2

    last = spk[len(dut) - 1]
    door_hit = any(addr == args.doorbell_addr and data == args.doorbell_val
                   for (addr, data) in last['rest']['mem'])
    if not door_hit:
        print('CMP_ERROR: Spike 被比对的最后一条（第 %d 条，pc=0x%08x）不是 UART '
              '结束铃写（mem 0x%08x = 0x%08x）：%s'
              % (len(dut) - 1, last['pc'], args.doorbell_addr, args.doorbell_val,
                 last['raw'].strip()))
        return 2
    if spk[len(dut)]['pc'] != args.term_pc:
        print('CMP_ERROR: Spike 第 %d 条 pc=0x%08x 不是终止点 lockstep_spin=0x%08x '
              '⇒ DUT 停止位置与程序结尾不对齐'
              % (len(dut), spk[len(dut)]['pc'], args.term_pc))
        return 2

    print('CMP_CHECK: 首条 pc=0x%08x；末条 pc=0x%08x；magic 提交=%d；doorbell 提交=%d（末条）'
          % (dut[0]['pc'], dut[-1]['pc'], magic_hits[0], doorbell_hits[0]))
    print('CMP_CHECK: DUT 总线锚点 magic(aw/w=1,addr=0x%08x,data=0x%08x,strb=0x%x) '
          'doorbell(aw/w=1,addr=0x%08x,data=0x%08x,strb=0x%x)'
          % (trailer['magic_addr'], trailer['magic_data'], trailer['magic_strb'],
             trailer['doorbell_addr'], trailer['doorbell_data'], trailer['doorbell_strb']))
    print('CMP_COVERAGE: store=%d csr=%d csr_noop=%d fp64=%d fflags=%d implicit_fs=%d'
          % (n_store, n_csr, n_csr_noop, n_fp64, n_fflags, n_fs))
    print('CMP_CHECK: 比较域 = PC + 整数写回 + FP64 写回 + store(addr/data/mask/PA) + '
          'CSR 身份/显式 post-WARL/no-op + 隐式 fflags + mstatus.FS/SD + '
          'instret/instreth 程序序；cycle/time/mcycle 与 minstret/minstreth 读显式拒绝')
    if not args.no_pass_line:
        print('LOCKSTEP: %d/%d PASS' % (len(dut), len(dut)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
