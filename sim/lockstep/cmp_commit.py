#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#==============================================================================
# sim/lockstep/cmp_commit.py —— DUT 提交 trace ↔ Spike commit log 逐条比对器
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）；依据 docs/design/08-baseline-5stage.md §8.3
#
# 一、输入（两条轨迹都必须由 run.sh 生成，格式见下）
#------------------------------------------------------------------------------
#   DUT  : sim/lockstep/build/dut.trace（tb_lockstep.sv 落盘）
#          数据行： `<idx> pc=0x%08x wen=%0d rd=%0d wdata=0x%08x`
#          末行：   `# end commits=.. cycles=.. reason=TERM_PC term_pc=0x.. uart_writes=.. ...`
#   Spike: sim/lockstep/build/spike.trace（`spike -l --log-commits --log=<file>`）
#          本机 spike 1.1.1-dev 实测：--log 文件里**反汇编行与 commit 行交错**，
#          commit 行形如（四种样例，均为本机实测原文）：
#             core   0: 3 0x80000000 (0x800002b7) x5  0x80000000
#             core   0: 3 0x80000020 (0x01de2023) mem 0x80001004 0x00000124   # 存数：地址+数据
#             core   0: 3 0x80000024 (0x000e2f03) x30 0x00000124 mem 0x80001004  # 取数：只有地址
#             core   0: 3 0x8000002c (0x340312f3) x5  0x00000000 c832_mscratch 0x12345678
#          判别式 = "core <hart>: <priv 单个数字> 0x<addr> (0x<insn>)"；反汇编行的
#          第二字段直接是地址（0x…），故不会误配。
#
# 二、比对判据（全部 fail-closed；任一项不满足 ⇒ 非零退出，且**不打印 PASS 行**）
#------------------------------------------------------------------------------
#   ① DUT trace 条数 K >= --min-commits（默认 60）；序号连续；末行证据行可解析且
#      reason=TERM_PC（= DUT 提交到 lockstep_spin 而停止，非超时）、uart_writes>=1。
#   ② Spike 侧至少要有 K 条 commit（不够 ⇒ 无法比对 ⇒ FAIL）。
#   ③ 逐条严格相等：**pc 必须相等**；DUT wen=1 ⇒ Spike 必须有同号 xN 且写值相等；
#      DUT wen=0 ⇒ Spike 不得有整数寄存器写（出现 fN/其它 ⇒ FAIL，见 §四）。
#   ④ 程序确实跑到结尾：被比对前缀里必须出现魔数写（mem MAGIC_ADDR = MAGIC_VAL），
#      且**最后一条**必须是 UART 结束铃写（mem DOORBELL_ADDR = DOORBELL_VAL）。
#   ⑤ 终止点对齐：Spike 第 K 条必须是 lockstep_spin（term_pc）——它正是 DUT 停止处
#      的那条指令（DUT 不记录 TERM_PC 本身）。⇒ 证明 DUT 不是在别处提前/滞后停止。
#   ⑥ 比对前缀内 Spike 特权级恒为 M(3)（本程序不陷阱、不换特权）；出现非 3 ⇒ FAIL。
#      比对前缀内 commit 行不得含 "exception" 字样 ⇒ FAIL。
#
# 三、输出
#------------------------------------------------------------------------------
#   成功：唯一一行 `LOCKSTEP: K/K PASS`（K>=min-commits），rc=0；
#   失败：`CMP_DIVERGENCE: 第 N 条：DUT pc=… spike pc=…` + 前后各 context 行，
#         或 `CMP_ERROR: …`（格式/证据缺失），rc=1/2。
#   ★ 本脚本**绝不**在失败路径输出含 "PASS" 字样的兜底文案。
#
# 四、覆盖范围与限制（明写，避免误判测试强度）
#------------------------------------------------------------------------------
#   · 本任务口径只比 **PC + rd 写值**（"浮点先不比对"）。2A 的提交探针
#     debug0_wb_rf_wen/wdata 对访存地址、CSR 变更**没有**观测通路，故这两项不比对；
#     访存数据正确性由"存→取回读"链路间接体现（rd 写值必须一致）。
#   · 程序内**不得**出现 F/D 指令：探针把 FP 写回也报成 rf_wen[0] + 浮点寄存器号，
#     会把 FP 写当整数写比对而假失败（lock_hello.S 头注已固化该纪律）。
#   · 读 mcycle/minstret/mtime 之类计数器同样会假失败，程序里禁止出现。
#==============================================================================

import argparse
import re
import sys

# ---- DUT trace 解析式 -------------------------------------------------------
DUT_LINE_RE = re.compile(
    r'^(?P<idx>\d+)\s+pc=0x(?P<pc>[0-9a-fA-F]{8})'
    r'\s+wen=(?P<wen>[01])\s+rd=(?P<rd>-?\d+)\s+wdata=0x(?P<wdata>[0-9a-fA-F]{8})$')
DUT_END_RE = re.compile(
    r'^#\s*end\s+commits=(?P<commits>\d+)\s+cycles=(?P<cycles>\d+)'
    r'\s+reason=(?P<reason>\S+)\s+term_pc=0x(?P<term_pc>[0-9a-fA-F]+)'
    r'\s+uart_writes=(?P<uart>\d+)'
    r'(?:\s+magic_aw=(?P<magic_aw>\d+)\s+magic_wdata=(?P<magic_wd>\d+))?\s*$')

# ---- Spike commit log 解析式（本机 1.1.1-dev 实测格式） ---------------------
SPIKE_COMMIT_RE = re.compile(
    r'^core\s+(?P<hart>\d+):\s+(?P<priv>[0-3])\s+0x(?P<pc>[0-9a-fA-F]+)'
    r'\s+\((?P<insn>0x[0-9a-fA-F]+)\)(?P<rest>.*)$')
RE_XREG = re.compile(r'^x(?P<n>\d+)$')
RE_FREG = re.compile(r'^f(?P<n>\d+)$')
RE_CSR = re.compile(r'^c(?P<n>\d+)_(?P<name>\w+)$')
RE_VAL = re.compile(r'^0x[0-9a-fA-F]+$')


class CmpError(Exception):
    """格式/证据类错误（rc=2）。"""


def parse_dut(path):
    """解析 DUT trace：返回 (commits, trailer)。commits[i] = dict(pc,wen,rd,wdata)。"""
    commits = []
    trailer = None
    try:
        fh = open(path, 'r', encoding='utf-8', errors='replace')
    except OSError as e:
        raise CmpError('打不开 DUT trace %s：%s' % (path, e))
    with fh:
        for lno, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            if line.startswith('#'):
                m = DUT_END_RE.match(line)
                if m:
                    trailer = {
                        'commits': int(m.group('commits')),
                        'cycles': int(m.group('cycles')),
                        'reason': m.group('reason'),
                        'term_pc': int(m.group('term_pc'), 16),
                        'uart_writes': int(m.group('uart')),
                        'magic_aw': int(m.group('magic_aw')) if m.group('magic_aw') is not None else None,
                        'magic_wdata': int(m.group('magic_wd')) if m.group('magic_wd') is not None else None,
                    }
                continue
            if not line.strip():
                continue
            m = DUT_LINE_RE.match(line)
            if not m:
                raise CmpError('DUT trace 第 %d 行不符合格式：%r' % (lno, line))
            idx = int(m.group('idx'))
            if idx != len(commits):
                raise CmpError('DUT trace 序号不连续：第 %d 行 idx=%d，期望 %d' % (lno, idx, len(commits)))
            commits.append({
                'pc': int(m.group('pc'), 16),
                'wen': int(m.group('wen')),
                'rd': int(m.group('rd')),
                'wdata': int(m.group('wdata'), 16),
            })
    if trailer is None:
        raise CmpError('DUT trace 缺少末行证据行（# end commits=... reason=...）')
    return commits, trailer


def parse_spike_rest(rest, where):
    """把 commit 行的剩余字段拆成 xN 写 / fN 写 / mem / CSR。

    返回 dict(xw={n:val}, fw={n:val}, mem=[(addr,data)], csr=[(num,val)])。
    出现无法识别的 token ⇒ CmpError（fail-closed，避免"看不懂就当通过"）。
    """
    toks = rest.split()
    out = {'xw': {}, 'fw': {}, 'mem': [], 'csr': []}
    i = 0
    while i < len(toks):
        t = toks[i]
        m = RE_XREG.match(t)
        if m:
            if i + 1 >= len(toks) or not RE_VAL.match(toks[i + 1]):
                raise CmpError('%s：x 寄存器字段后不是 0x 值：%r %r' % (where, t, toks[i + 1:i + 2]))
            out['xw'][int(m.group('n'))] = int(toks[i + 1], 16)
            i += 2
            continue
        m = RE_FREG.match(t)
        if m:
            if i + 1 >= len(toks) or not RE_VAL.match(toks[i + 1]):
                raise CmpError('%s：f 寄存器字段后不是 0x 值：%r %r' % (where, t, toks[i + 1:i + 2]))
            out['fw'][int(m.group('n'))] = int(toks[i + 1], 16)
            i += 2
            continue
        if t == 'mem':
            # 本机实测：**取数（load）只有地址**、**存数（store）是"地址 + 数据"**
            #   core 0: 3 0x80000024 (0x000e2f03) x30 0x00000124 mem 0x80001004
            #   core 0: 3 0x80000020 (0x01de2023) mem 0x80001004 0x00000124
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
            out['csr'].append((int(m.group('n')), int(toks[i + 1], 16)))
            i += 2
            continue
        raise CmpError('%s：无法识别的 commit 字段 %r（本机 spike 格式可能已变化）' % (where, t))
    return out


def parse_spike(path):
    """解析 Spike --log 文件，抽出 commit 行（跳过反汇编行）。"""
    commits = []
    try:
        fh = open(path, 'r', encoding='utf-8', errors='replace')
    except OSError as e:
        raise CmpError('打不开 Spike trace %s：%s' % (path, e))
    with fh:
        for lno, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            if not line.strip():
                continue
            m = SPIKE_COMMIT_RE.match(line)
            if not m:
                continue                      # 反汇编行/其它行：跳过
            where = 'Spike trace 第 %d 行' % lno
            if 'exception' in line:
                raise CmpError('%s：出现 exception（程序发生陷阱，无法作为锁步轨迹）：%r' % (where, line))
            commits.append({
                'pc': int(m.group('pc'), 16),
                'priv': int(m.group('priv')),
                'insn': int(m.group('insn'), 16),
                'rest': parse_spike_rest(m.group('rest'), where),
                'raw': line,
            })
    return commits


def fmt_commit(c):
    if c['wen']:
        return 'pc=0x%08x wen=1 rd=x%-2d wdata=0x%08x' % (c['pc'], c['rd'], c['wdata'])
    return 'pc=0x%08x wen=0 rd=-  wdata=0x%08x' % (c['pc'], c['wdata'])


def main(argv=None):
    ap = argparse.ArgumentParser(description='DUT 提交 trace ↔ Spike commit log 逐条比对（08 §8.3）')
    ap.add_argument('--dut', required=True, help='DUT 提交 trace（tb_lockstep 落盘）')
    ap.add_argument('--spike', required=True, help='Spike 轨迹文件（--log= 产出，含 commit 行）')
    ap.add_argument('--min-commits', type=int, default=60, help='比对条数下限（默认 60）')
    ap.add_argument('--context', type=int, default=20, help='分歧点上下文行数（默认 20）')
    ap.add_argument('--term-pc', type=lambda s: int(s, 0), default=0x80000120,
                    help='lockstep_spin 地址（终止点，来自 ELF 符号）')
    ap.add_argument('--magic-addr', type=lambda s: int(s, 0), default=0x80002000)
    ap.add_argument('--magic-val', type=lambda s: int(s, 0), default=0x600D5EED)
    ap.add_argument('--doorbell-addr', type=lambda s: int(s, 0), default=0x1FE001E0)
    ap.add_argument('--doorbell-val', type=lambda s: int(s, 0), default=0x5A)
    args = ap.parse_args(argv)

    try:
        dut, trailer = parse_dut(args.dut)
        spk = parse_spike(args.spike)
    except CmpError as e:
        print('CMP_ERROR: %s' % e)
        return 2

    print('CMP_SUMMARY: dut_commits=%d spike_commits=%d min_commits=%d' % (len(dut), len(spk), args.min_commits))
    print('CMP_SUMMARY: dut 末行证据 reason=%s term_pc=0x%08x cycles=%d uart_writes=%d'
          % (trailer['reason'], trailer['term_pc'], trailer['cycles'], trailer['uart_writes']))
    if trailer.get('magic_aw') is not None:
        print('CMP_SUMMARY: DUT 侧魔数写 AXI 观测（仅诊断）magic_aw=%d magic_wdata=%d'
              % (trailer['magic_aw'], trailer['magic_wdata']))

    # ---- 证据/长度检查（fail-closed）----
    if trailer['reason'] != 'TERM_PC':
        print('CMP_ERROR: DUT 末行 reason=%s（非 TERM_PC ⇒ 未跑到 lockstep_spin）' % trailer['reason'])
        return 2
    if trailer['term_pc'] != args.term_pc:
        print('CMP_ERROR: DUT 末行 term_pc=0x%08x 与 --term-pc=0x%08x 不一致' % (trailer['term_pc'], args.term_pc))
        return 2
    if trailer['uart_writes'] < 1:
        print('CMP_ERROR: DUT 侧未观测到 UART 结束铃（uart_writes=%d）' % trailer['uart_writes'])
        return 2
    if trailer['commits'] != len(dut):
        print('CMP_ERROR: 末行 commits=%d 与 trace 实际条数 %d 不一致' % (trailer['commits'], len(dut)))
        return 2
    if len(dut) < args.min_commits:
        print('CMP_ERROR: DUT 提交条数 %d < 下限 %d' % (len(dut), args.min_commits))
        return 2
    if len(spk) <= len(dut):
        print('CMP_ERROR: Spike 轨迹仅 %d 条 commit，不足以覆盖 DUT 的 %d 条（≤ ⇒ 无法比对）'
              % (len(spk), len(dut)))
        return 2

    # ---- 逐条比对 ----
    def dump_divergence(n, msg):
        print('CMP_DIVERGENCE: 第 %d 条：%s' % (n, msg))
        lo = max(0, n - args.context)
        hi = min(len(dut), n + 1 + args.context)
        print('---- DUT 上下文（第 %d..%d 条）----' % (lo, hi - 1))
        for i in range(lo, hi):
            mark = '>>' if i == n else '  '
            if i < len(dut):
                print('%s [%4d] DUT   %s' % (mark, i, fmt_commit(dut[i])))
            if i < len(spk):
                print('%s [%4d] SPIKE %s' % (mark, i, spk[i]['raw'].strip()))

    for i in range(len(dut)):
        d, s = dut[i], spk[i]
        if s['priv'] != 3:
            dump_divergence(i, 'Spike 侧特权级=%d（本程序应恒为 M=3；可能发生陷阱/权限变化）' % s['priv'])
            return 1
        if d['pc'] != s['pc']:
            dump_divergence(i, 'DUT pc=0x%08x  spike pc=0x%08x（PC 不等）' % (d['pc'], s['pc']))
            return 1
        if d['wen'] == 1:
            if d['rd'] == 0:
                dump_divergence(i, 'DUT 上报 rd=x0 写（探针口径异常）')
                return 1
            if d['rd'] not in s['rest']['xw']:
                extra = ''
                if s['rest']['fw']:
                    extra = '（Spike 侧是浮点写 f%d：本程序不应出现 FP 指令）' % list(s['rest']['fw'])[0]
                dump_divergence(i, 'DUT 写 rd=x%d =0x%08x，Spike 同 PC 无整数写%s' % (d['rd'], d['wdata'], extra))
                return 1
            sv = s['rest']['xw'][d['rd']]
            if sv != d['wdata']:
                dump_divergence(i, 'DUT rd=x%d 写值=0x%08x  spike 写值=0x%08x' % (d['rd'], d['wdata'], sv))
                return 1
        else:
            if s['rest']['xw']:
                n, v = next(iter(s['rest']['xw'].items()))
                dump_divergence(i, 'DUT 未写寄存器，但 Spike 写了 x%d=0x%08x' % (n, v))
                return 1
            if s['rest']['fw']:
                n = next(iter(s['rest']['fw']))
                dump_divergence(i, 'DUT 未写寄存器，但 Spike 写了浮点 f%d（本程序不应出现 FP 指令）' % n)
                return 1

    # ---- 结束锚点（程序确实跑到结尾）----
    magic_idx = None
    for i in range(len(dut)):
        for (addr, data) in spk[i]['rest']['mem']:
            if addr == args.magic_addr and data == args.magic_val:
                magic_idx = i
    if magic_idx is None:
        print('CMP_ERROR: 被比对前缀内未出现魔数写（mem 0x%08x = 0x%08x）⇒ 程序未跑到结尾'
              % (args.magic_addr, args.magic_val))
        return 2

    last = spk[len(dut) - 1]
    door_hit = any(addr == args.doorbell_addr and data == args.doorbell_val
                   for (addr, data) in last['rest']['mem'])
    if not door_hit:
        print('CMP_ERROR: 被比对的最后一条（第 %d 条，pc=0x%08x）不是 UART 结束铃写（mem 0x%08x = 0x%08x）：%s'
              % (len(dut) - 1, last['pc'], args.doorbell_addr, args.doorbell_val, last['raw'].strip()))
        return 2

    if spk[len(dut)]['pc'] != args.term_pc:
        print('CMP_ERROR: Spike 第 %d 条 pc=0x%08x 不是终止点 lockstep_spin=0x%08x ⇒ DUT 停止位置与程序结尾不对齐'
              % (len(dut), spk[len(dut)]['pc'], args.term_pc))
        return 2

    print('CMP_CHECK: 首条 pc=0x%08x；末条 pc=0x%08x；魔数写见第 %d 条；结束铃见最后一条'
          % (dut[0]['pc'], dut[-1]['pc'], magic_idx))
    print('CMP_CHECK: 逐条比对字段 = PC + 整数 rd 写值（x0 跳过；访存/CSR/浮点无探针，见脚本头注 §四）')
    print('LOCKSTEP: %d/%d PASS' % (len(dut), len(dut)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
