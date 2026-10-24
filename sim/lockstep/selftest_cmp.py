#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#==============================================================================
# sim/lockstep/selftest_cmp.py —— cmp_commit.py 的独立 fake-fixture 自测
#==============================================================================
# 只写 --workdir（run.sh 传本轮私有目录），不跑 DUT/Spike、不写 /tmp、不打印
# 正式 `LOCKSTEP: ... PASS`。每个用例校验**精确 rc + 专属域/行原因**，不是只看
# "非零 + 大类"；只有全部用例通过才打印 `CMP_SELFTEST: N/N PASS`，否则 FAIL。
# 覆盖：整数/store(addr,data,mask)/CSR 身份与 post-WARL/PA/FP64/x-f/fflags 实际
# poststate/FS-SD/store 总线锚点/解析器重复与未知行/FIFO 由独立 SV 单元自测。
#==============================================================================
import argparse
import copy
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CMP = os.path.join(HERE, 'cmp_commit.py')

MAGIC_ADDR = 0x80002000
MAGIC_VAL = 0x600D5EED
DOORBELL_ADDR = 0x1FE001E0
DOORBELL_VAL = 0x5A
TERM_PC = 0x8000003C

CSR_NAME = {0x001: 'fflags', 0x002: 'frm', 0x003: 'fcsr',
            0x300: 'mstatus', 0x340: 'mscratch', 0x3B0: 'pmpaddr0'}


def c(pc, insn, **kw):
    d = {'pc': pc, 'insn': insn, 'xw': None, 'fw': None,
         'store': None, 'cw': None, 'cvo': 0, 'fl': None,
         'sp_csr': [], 'sp_mem': []}
    d.update(kw)
    return d


def build_control():
    cs = [
        c(0x1C000000, 0x800002B7, xw=(5, 0x80000000)),
        c(0x1C000004, 0x00028067),
        c(0x80000000, 0x80002437, xw=(8, 0x80002000)),
        c(0x80000004, 0x10040413, xw=(8, 0x80002100)),
        c(0x80000008, 0x12345337, xw=(6, 0x12345000)),
        c(0x8000000C, 0x67830313, xw=(6, 0x12345678)),
        c(0x80000010, 0x006401A3,
          store={'ssz': 0, 's0a': 0x80002103, 's0d': 0x78000000, 's0b': 0x8},
          sp_mem=[(0x80002103, 0x78)]),
        c(0x80000014, 0x00641123,
          store={'ssz': 1, 's0a': 0x80002102, 's0d': 0x56780000, 's0b': 0xC},
          sp_mem=[(0x80002102, 0x5678)]),
        c(0x80000018, 0x00642223,
          store={'ssz': 2, 's0a': 0x80002104, 's0d': 0x12345678, 's0b': 0xF},
          sp_mem=[(0x80002104, 0x12345678)]),
        c(0x8000001C, 0x001616F3, xw=(13, 0x00000008), cw=(0x001, 0x13),
          sp_csr=[(0x001, 0x13)]),
        c(0x80000020, 0x003717F3, xw=(15, 0x00000013), cw=(0x003, 0x00000005),
          sp_csr=[(0x001, 0x00000005), (0x002, 0x00000000)]),
        c(0x80000024, 0x340894F3, xw=(9, 0x00000000), cw=(0x340, 0xABCDE000),
          sp_csr=[(0x340, 0xABCDE000)]),
        c(0x80000028, 0x02947553, fw=(10, 0x3FF0000000000000),
          sp_csr=[(0x300, 0x80006000)]),
        c(0x8000002C, 0x1860F3D3, fw=(7, 0xFFFFFFFF7F800000), fl=0x08,
          sp_csr=[(0x001, 0x00000008)]),
        c(0x80000030, 0x1860F653, fw=(12, 0xFFFFFFFF7F800000), fl=0x08,
          sp_csr=[(0x001, 0x00000008)]),
        c(0x80000034, 0x0062A023,
          store={'ssz': 2, 's0a': MAGIC_ADDR, 's0d': MAGIC_VAL, 's0b': 0xF},
          sp_mem=[(MAGIC_ADDR, MAGIC_VAL)]),
        c(0x80000038, 0x01C3A023,
          store={'ssz': 2, 's0a': DOORBELL_ADDR, 's0d': DOORBELL_VAL, 's0b': 0xF},
          sp_mem=[(DOORBELL_ADDR, DOORBELL_VAL)]),
    ]
    tr = {
        'commits': len(cs), 'cycles': 1234, 'reason': 'TERM_PC',
        'term_pc': TERM_PC, 'uart_writes': 1,
        'magic_aw': 1, 'magic_w': 1, 'magic_addr': MAGIC_ADDR,
        'magic_data': MAGIC_VAL, 'magic_strb': 0xF,
        'doorbell_aw': 1, 'doorbell_w': 1, 'doorbell_addr': DOORBELL_ADDR,
        'doorbell_data': DOORBELL_VAL, 'doorbell_strb': 0xF,
        'obs_err': 0, 'bus_err': 0,
    }
    return cs, tr


def fs_of(cs):
    fs = 0
    out = []
    for d in cs:
        if d['fw'] is not None:
            fs = 3
        if 'fs' in d:
            fs = d['fs']
        out.append(fs)
    return out


def emit_dut(cs, trailer):
    lines = ['# DUT commit trace v3 — RV32GC 2A Spike lockstep (sim/lockstep/tb_lockstep.sv)',
             '# format: <idx> pc=... xw= xrd= xval= fw= frd= fval= st= ssz= s0a= s0p= s0d= s0b= s1a= s1p= s1d= s1b= cw= cad= cva= cvo= fl= ff= fs= sd= obs=',
             '# x=真实 GPR 写回; f=真实 FP 64bit 写回; st=M_S_ISS 真实 store 请求; cw=显式 CSR 写; fl/ff=实际 fflags 更新; fs=实际 mstatus.FS; sd=实际 csr_mstatus_view[31]（不由 TB 推算）']
    fs = fs_of(cs)
    for i, d in enumerate(cs):
        xw = 1 if d['xw'] else 0
        xrd = d['xw'][0] if d['xw'] else -1
        xval = d['xw'][1] if d['xw'] else 0
        fw = 1 if d['fw'] else 0
        frd = d['fw'][0] if d['fw'] else -1
        fval = d['fw'][1] if d['fw'] else 0
        stf = d['store'] or {}
        st = 1 if d['store'] else 0
        if st and stf.get('ssz') == 3:
            st = 2
        s0a = stf.get('s0a', 0); s0p = stf.get('s0p', s0a)
        s1a = stf.get('s1a', 0); s1p = stf.get('s1p', s1a)
        s0b = stf.get('s0b', 0); s1b = stf.get('s1b', 0)
        cw = 1 if d['cw'] else 0
        cad = d['cw'][0] if d['cw'] else 0
        cva = d['cw'][1] if d['cw'] else 0
        cvo = d.get('cvo', 0) if d['cw'] else 0
        fl = 1 if d['fl'] is not None else 0
        ff = d['fl'] if d['fl'] is not None else 0
        sd = d.get('sd', 1 if fs[i] == 3 else 0)
        lines.append(
            '%d pc=0x%08x xw=%d xrd=%d xval=0x%08x fw=%d frd=%d fval=0x%016x '
            'st=%d ssz=%d s0a=0x%08x s0p=0x%08x s0d=0x%08x s0b=0x%x '
            's1a=0x%08x s1p=0x%08x s1d=0x%08x s1b=0x%x '
            'cw=%d cad=0x%03x cva=0x%08x cvo=0x%08x fl=%d ff=0x%05x fs=%d sd=%d obs=1'
            % (i, d['pc'], xw, xrd, xval, fw, frd, fval,
               st, stf.get('ssz', 0), s0a, s0p, stf.get('s0d', 0), s0b,
               s1a, s1p, stf.get('s1d', 0), s1b, cw, cad, cva, cvo, fl, ff, fs[i], sd))
    lines.append(
        '# end commits=%d cycles=%d reason=%s term_pc=0x%08x uart_writes=%d '
        'magic_aw=%d magic_w=%d magic_addr=0x%08x magic_data=0x%08x magic_strb=0x%x '
        'doorbell_aw=%d doorbell_w=%d doorbell_addr=0x%08x doorbell_data=0x%08x '
        'doorbell_strb=0x%x obs_err=%d bus_err=%d'
        % (trailer['commits'], trailer['cycles'], trailer['reason'],
           trailer['term_pc'], trailer['uart_writes'],
           trailer['magic_aw'], trailer['magic_w'], trailer['magic_addr'],
           trailer['magic_data'], trailer['magic_strb'],
           trailer['doorbell_aw'], trailer['doorbell_w'], trailer['doorbell_addr'],
           trailer['doorbell_data'], trailer['doorbell_strb'],
           trailer['obs_err'], trailer['bus_err']))
    return '\n'.join(lines) + '\n'


def emit_spike(cs):
    lines = []
    for d in cs:
        toks = ['core   0: 3 0x%08x (0x%08x)' % (d['pc'], d['insn'])]
        if d['xw']:
            toks.append('x%-2d 0x%08x' % (d['xw'][0], d['xw'][1]))
        if d['fw']:
            toks.append('f%-2d 0x%016x' % (d['fw'][0], d['fw'][1]))
        for (a, v) in d['sp_mem']:
            toks.append('mem 0x%08x' % a if v is None else 'mem 0x%08x 0x%x' % (a, v))
        for (num, val) in d['sp_csr']:
            toks.append('c%d_%s 0x%08x' % (num, CSR_NAME.get(num, 'csr'), val))
        lines.append(' '.join(toks))
    lines.append('core   0: 3 0x%08x (0x0000006f)' % TERM_PC)
    return '\n'.join(lines) + '\n'


def parse_primary(out):
    for line in out.splitlines():
        m = re.match(r'^(CMP_DIVERGENCE|CMP_ERROR|CMP_UNSUPPORTED):\s*(.*)$', line)
        if not m:
            continue
        diag = {'category': m.group(1), 'message': m.group(2)}
        dm = re.search(r'第\s*(\d+)\s*条：.*?pc=0x([0-9a-fA-F]+)\s+'
                       r'field=([^ ;]+)\s+got=([^ ;]+)\s+ref=([^ ;]+)', m.group(2))
        if dm:
            diag.update({'index': int(dm.group(1)), 'pc': int(dm.group(2), 16),
                         'field': dm.group(3), 'got': dm.group(4), 'ref': dm.group(5)})
        return diag
    return None


def primary_matches(actual, expected):
    return actual is not None and all(actual.get(k) == v for k, v in expected.items())


def run_cmp(work, name, dut_text, spike_text, pa_mode='bare'):
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    dp = os.path.join(d, 'dut.trace')
    sp = os.path.join(d, 'spike.trace')
    with open(dp, 'w', encoding='utf-8') as f:
        f.write(dut_text)
    with open(sp, 'w', encoding='utf-8') as f:
        f.write(spike_text)
    cmd = [sys.executable, CMP, '--dut', dp, '--spike', sp,
           '--min-commits', '10', '--term-pc', '0x%x' % TERM_PC,
           '--magic-addr', '0x%x' % MAGIC_ADDR, '--magic-val', '0x%x' % MAGIC_VAL,
           '--doorbell-addr', '0x%x' % DOORBELL_ADDR,
           '--doorbell-val', '0x%x' % DOORBELL_VAL,
           '--pa-mode', pa_mode, '--no-pass-line']
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def replace_field(line, field, value):
    pat = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(field) + r'=[^ ]+')
    if not pat.search(line):
        raise RuntimeError('fixture 行缺少字段 %s：%r' % (field, line))
    return pat.sub('%s=%s' % (field, value), line, count=1)


def mutate_text(text, fn):
    return '\n'.join(fn(text.splitlines())) + '\n'


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--workdir', default=None)
    args = ap.parse_args(argv)

    if args.workdir:
        base = os.path.abspath(args.workdir)
        os.makedirs(base, exist_ok=True)
        work = tempfile.mkdtemp(prefix='cases.', dir=base)
    else:
        base = os.path.abspath(os.path.join(HERE, '..', '..',
                                            'build', 'functional', 'lockstep-effects'))
        os.makedirs(base, exist_ok=True)
        work = tempfile.mkdtemp(prefix='selftest.', dir=base)

    cs0, tr0 = build_control()
    dut0 = emit_dut(cs0, tr0)
    spk0 = emit_spike(cs0)
    cases = []

    def add(name, rc_exp, sub, mut_cs=None, mut_tr=None, mut_dut=None,
            mut_spk=None, pa_mode='bare', regen_spk=False, primary=None,
            primary_required=False):
        cc = copy.deepcopy(cs0)
        tt = copy.deepcopy(tr0)
        if mut_cs:
            mut_cs(cc)
        if mut_tr:
            mut_tr(tt)
        dt = emit_dut(cc, tt)
        sp = emit_spike(cc) if regen_spk else spk0
        if mut_spk:
            sp = mutate_text(sp, mut_spk)
        if mut_dut:
            dt = mutate_text(dt, mut_dut)
        cases.append({'name': name, 'dut': dt, 'spk': sp,
                      'rc': rc_exp, 'sub': sub, 'pa': pa_mode,
                      'primary': primary, 'primary_required': primary_required})

    def cw_none(cc):
        cc[5]['cw'] = None; cc[5]['cvo'] = 0
        cc[5]['sp_csr'] = [(0x300, 0)]

    def cw_mstatus(val=0, cad=0x300, cvo=0):
        cc = cs0
        cc[5]['cw'] = (cad, val); cc[5]['cvo'] = cvo
        cc[5]['sp_csr'] = [(0x300, val)]
        return cc

    # ---- 合法控制 ----
    cases.append({'name': 'control_valid', 'dut': dut0, 'spk': spk0,
                  'rc': 0, 'sub': 'CMP_CHECK', 'pa': 'bare'})

    # ---- L1 CSR 身份 ----
    def m_csr_missing(cc):
        cc[5]['insn'] = 0x30029073        # csrrw x0, mstatus, t0
        cc[5]['xw'] = None
        cc[5]['cw'] = None; cc[5]['cvo'] = 0
        cc[5]['sp_csr'] = [(0x300, 0x00000000)]
        cc[5]['fs'] = 0
    add('csr_missing_cw_mstatus', 1, '无 cw', mut_cs=m_csr_missing, regen_spk=True)

    def m_csr_wrong_cad(cc):
        cc[5]['insn'] = 0x30029073
        cc[5]['xw'] = None
        cc[5]['cw'] = (0x340, 0x00000000); cc[5]['cvo'] = 0
        cc[5]['sp_csr'] = [(0x300, 0x00000000)]
        cc[5]['fs'] = 0
    add('csr_wrong_cad_mstatus', 1, 'CSR 身份错', mut_cs=m_csr_wrong_cad, regen_spk=True)

    def m_csr_mstatus_value(cc):
        cc[5]['insn'] = 0x30029073
        cc[5]['xw'] = None
        cc[5]['cw'] = (0x300, 0x00000000); cc[5]['cvo'] = 0
        cc[5]['sp_csr'] = [(0x300, 0x00000001)]
        cc[5]['fs'] = 0
    add('csr_mstatus_full_value', 1, 'DUT CSR c768', mut_cs=m_csr_mstatus_value, regen_spk=True)

    def m_csr_mstatus_ok(cc):
        cc[5]['insn'] = 0x30029073
        cc[5]['xw'] = None
        cc[5]['cw'] = (0x300, 0x00000000); cc[5]['cvo'] = 0
        cc[5]['sp_csr'] = [(0x300, 0x00000000)]
        cc[5]['fs'] = 0
    cc = copy.deepcopy(cs0)
    m_csr_mstatus_ok(cc)
    cases.append({'name': 'csr_mstatus_identity_valid', 'dut': emit_dut(cc, tr0),
                  'spk': emit_spike(cc), 'rc': 0, 'sub': 'CMP_CHECK', 'pa': 'bare'})

    def m_fake_pmp(cc):
        cc[5]['cw'] = (0x3B0, 0x00001000); cc[5]['cvo'] = 0x00001000
        cc[5]['sp_csr'] = []
    add('fake_pmp_noop_on_addi', 1, '不是 CSR 写', mut_cs=m_fake_pmp)

    def m_csr_readonly_spurious(cc):
        cc[5]['insn'] = 0x34002573          # csrr a0, mscratch（只读）
        cc[5]['xw'] = (10, 0)
        cc[5]['cw'] = (0x340, 0); cc[5]['cvo'] = 0
        cc[5]['sp_csr'] = []
    add('csr_readonly_spurious_cw', 1, '只读 CSRRS/RC', mut_cs=m_csr_readonly_spurious, regen_spk=True)

    # ---- L1 PMP 锁写 no-op 正反 ----
    def make_noop(cvo):
        cc = copy.deepcopy(cs0)
        cc[5] = c(0x8000000C, 0x3B0E1073, cw=(0x3B0, 0x80001000), cvo=cvo)
        return cc
    cc = make_noop(0x80001000)
    cases.append({'name': 'pmp_locked_noop_valid', 'dut': emit_dut(cc, tr0),
                  'spk': emit_spike(cc), 'rc': 0, 'sub': 'CMP_CHECK', 'pa': 'bare'})
    cc = make_noop(0x80000000)
    cases.append({'name': 'pmp_locked_noop_changed', 'dut': emit_dut(cc, tr0),
                  'spk': emit_spike(cc), 'rc': 1, 'sub': '无该 CSR 记录', 'pa': 'bare'})

    # ---- L2 PA 正反 ----
    def m_pa_low(cc):
        cc[7]['store']['s0p'] = cc[7]['store']['s0a'] + 4
    add('pa_low_mismatch', 1, '物理地址', mut_cs=m_pa_low)

    def make_fsd(high_pa_wrong=False):
        cc = copy.deepcopy(cs0)
        cc[6] = c(0x80000010, 0x00A43027,
                  store={'ssz': 3, 's0a': 0x80002100, 's1a': 0x80002104,
                         's0d': 0x11223344, 's1d': 0x55667788,
                         's0b': 0xF, 's1b': 0xF},
                  sp_mem=[(0x80002100, 0x5566778811223344)])
        if high_pa_wrong:
            cc[6]['store']['s1p'] = 0x80002108
        return cc
    cc = make_fsd(False)
    cases.append({'name': 'fsd_store_valid', 'dut': emit_dut(cc, tr0),
                  'spk': emit_spike(cc), 'rc': 0, 'sub': 'CMP_CHECK', 'pa': 'bare'})
    cc = make_fsd(True)
    cases.append({'name': 'pa_fsd_high_mismatch', 'dut': emit_dut(cc, tr0),
                  'spk': emit_spike(cc), 'rc': 1, 'sub': 'fsd 高相 PA', 'pa': 'bare'})

    def m_pa_translated(cc):
        pass
    add('pa_translated_unsupported', 2, '没有独立 PA oracle', mut_cs=m_pa_translated,
        pa_mode='translated')

    # ---- 原整数/store/CSR/FP/fflags 变异（保留）----
    add('int_value_wrong', 1, 'DUT x5 写值', mut_cs=lambda cc: cc[0].__setitem__('xw', (5, 0xDEADBEEF)))
    add('store_addr_wrong', 1, 'DUT store 地址', mut_cs=lambda cc: cc[6]['store'].__setitem__('s0a', 0x80002100))
    add('store_data_wrong', 1, 'DUT store 数据', mut_cs=lambda cc: cc[8]['store'].__setitem__('s0d', 0x12345679))
    add('store_mask_wrong', 1, 'DUT store strb', mut_cs=lambda cc: cc[8]['store'].__setitem__('s0b', 0x7))
    add('csr_landing_wrong', 1, 'DUT CSR c832', mut_cs=lambda cc: cc[11].__setitem__('cw', (0x340, 0xABCDE001)))
    add('fp_high32_wrong', 1, 'DUT f10 写值', mut_cs=lambda cc: cc[12].__setitem__('fw', (10, 0x4000000000000000)))
    def m_xf(cc):
        cc[13]['fw'] = None; cc[13]['fl'] = None
        cc[13]['xw'] = (7, 0x7F800000)
    add('xf_type_confusion', 1, 'DUT 写 x7', mut_cs=m_xf)
    def m_missing_store(cc):
        cc[6]['store'] = None
    add('store_record_missing', 1, '没有 store 记录', mut_cs=m_missing_store)
    def m_extra_store(cc):
        cc[3]['store'] = {'ssz': 2, 's0a': 0x80003000, 's0d': 1, 's0b': 0xF}
    add('store_record_extra', 1, '声称 store', mut_cs=m_extra_store)
    add('ref_only_termination', 2, 'magic AXI',
        mut_tr=lambda tt: tt.update({'magic_aw': 0, 'magic_w': 0,
                                     'doorbell_aw': 0, 'doorbell_w': 0}))
    add('doorbell_bus_twice', 2, 'doorbell AXI',
        mut_tr=lambda tt: tt.update({'doorbell_w': 2}))
    add('pc_shift', 1, 'PC 不等', mut_cs=lambda cc: cc[5].__setitem__('pc', cc[5]['pc'] + 4))
    add('fflags_wrong', 1, 'DUT CSR c1 落地值', mut_cs=lambda cc: cc[14].__setitem__('fl', 0x10))
    add('sticky_flags_missing', 1, 'Spike 有 CSR c1', mut_cs=lambda cc: cc[14].__setitem__('fl', None))
    add('csr_fflags_conflict', 1, '冲突', mut_cs=lambda cc: cc[10].__setitem__('fl', 0x10))
    add('fs_poststate_wrong', 1, 'field=mstatus.FS', mut_cs=lambda cc: cc[12].__setitem__('fs', 1),
        primary={'category': 'CMP_DIVERGENCE', 'index': 12, 'pc': 0x80000028,
                 'field': 'mstatus.FS', 'got': '1', 'ref': '3'})

    def fs_first_deleted(cc):
        cc[12]['fs'] = 0          # 首次 FS 更新被删；第二次 FP 仍写 3
    add('fs_first_update_deleted', 1, 'field=mstatus.FS', mut_cs=fs_first_deleted,
        primary={'category': 'CMP_DIVERGENCE', 'index': 12, 'pc': 0x80000028,
                 'field': 'mstatus.FS', 'got': '0', 'ref': '3'})

    def fl_first_deleted(cc):
        cc[13]['fl'] = None      # 首次 flags 更新被删；第二次仍记 8
    add('fflags_first_update_deleted', 1, 'Spike 有 CSR c1', mut_cs=fl_first_deleted,
        primary={'category': 'CMP_DIVERGENCE', 'index': 13, 'pc': 0x8000002C,
                 'field': 'fflags', 'got': 'absent', 'ref': '0x00000008'},
        primary_required=True)

    def fl_first_flipped(cc):
        cc[13]['fl'] = 0x10
    add('fflags_first_update_flipped', 1, 'DUT CSR c1 落地值', mut_cs=fl_first_flipped,
        primary={'category': 'CMP_DIVERGENCE', 'index': 13, 'pc': 0x8000002C,
                 'field': 'fflags', 'got': '0x00000010', 'ref': '0x00000008'},
        primary_required=True)

    # ---- L5 FS/SD：reference status 是独立 Spike commit 序列 ----
    def fs_variant(fs, c768, clear_fp_status=False):
        cc = copy.deepcopy(cs0)
        # index 5 是真实 CSRRW mstatus，不把 c768 伪挂在普通整数指令上。
        cc[5]['insn'] = 0x30029073
        cc[5]['xw'] = None
        cc[5]['cw'] = (0x300, c768)
        cc[5]['cvo'] = 0
        cc[5]['fs'] = fs
        cc[5]['sd'] = (c768 >> 31) & 1
        cc[5]['sp_csr'] = [(0x300, c768)]
        if clear_fp_status:
            cc[12]['sp_csr'] = []
        return cc
    for nm, fs, sd, rc, sub, clear_fp_status in [
        ('explicit_fs1_sd0_valid', 1, 0, 0, 'CMP_CHECK', False),
        ('explicit_fs2_sd0_valid', 2, 0, 0, 'CMP_CHECK', False),
        ('explicit_fs3_sd1_valid', 3, 1, 0, 'CMP_CHECK', True),
        ('explicit_fs1_sd1_wrong', 1, 0, 1, 'field=mstatus.SD', False),
        ('explicit_fs3_sd0_wrong', 3, 1, 1, 'field=mstatus.SD', True),
        ('explicit_fs_field_wrong', 2, 0, 1, 'field=mstatus.FS', False),
    ]:
        c768 = (sd << 31) | (fs << 13)
        dut_fs = 1 if nm == 'explicit_fs_field_wrong' else fs
        cc = fs_variant(dut_fs, c768, clear_fp_status)
        if nm == 'explicit_fs1_sd1_wrong':
            cc[5]['sd'] = 1
        if nm == 'explicit_fs3_sd0_wrong':
            cc[5]['sd'] = 0
        cases.append({'name': nm, 'dut': emit_dut(cc, tr0), 'spk': emit_spike(cc),
                      'rc': rc, 'sub': sub, 'pa': 'bare'})

    add('fs_second_no_c768_wrong', 1, 'field=mstatus.FS',
        mut_cs=lambda cc: cc[13].update({'fs': 2}),
        primary={'category': 'CMP_DIVERGENCE', 'index': 13, 'pc': 0x8000002C,
                 'field': 'mstatus.FS', 'got': '2', 'ref': '3'})
    add('sd_second_no_c768_wrong', 1, 'field=mstatus.SD',
        mut_cs=lambda cc: cc[13].update({'sd': 0}),
        primary={'category': 'CMP_DIVERGENCE', 'index': 13, 'pc': 0x8000002C,
                 'field': 'mstatus.SD', 'got': '0', 'ref': '1'})

    # ---- L6 解析器/重复/未知行 ----
    def m_spike_dup_x(lines):
        for i, l in enumerate(lines):
            if ' x5 ' in l and ' 0x' in l:
                lines[i] = l + ' x5  0x80000000'
                return lines
        return lines
    add('spike_dup_x', 2, '重复写 x5', mut_spk=m_spike_dup_x)

    def m_spike_dup_csr(lines):
        for i, l in enumerate(lines):
            if 'c1_fflags' in l:
                lines[i] = l + ' c1_fflags 0x00000013'
                return lines
        return lines
    add('spike_dup_csr_same', 2, '重复 CSR c1', mut_spk=m_spike_dup_csr)

    def m_spike_dup_f(lines):
        for i, l in enumerate(lines):
            if 'f10 0x' in l:
                lines[i] = l + ' f10 0x3ff0000000000000'
                return lines
        return lines
    add('spike_dup_f', 2, '重复写 f10', mut_spk=m_spike_dup_f)

    def m_spike_unknown_core(lines):
        lines[0] = 'core   0: ??? broken'
        return lines
    add('spike_unknown_core', 2, '未知 core 形态', mut_spk=m_spike_unknown_core)

    def m_spike_noncore(lines):
        lines.insert(1, 'not-a-core-line')
        return lines
    add('spike_noncore_line', 2, '不是 core 记录', mut_spk=m_spike_noncore)

    def m_dut_dup_end(lines):
        lines.append(lines[-1])
        return lines
    add('dut_dup_end', 2, '出现在 # end 之后', mut_dut=m_dut_dup_end)

    def m_dut_data_after_end(lines):
        lines.append('99 pc=0x8000003c xw=0 xrd=-1 xval=0x00000000 fw=0 frd=-1 '
                     'fval=0x0000000000000000 st=0 ssz=0 s0a=0x00000000 s0p=0x00000000 '
                     's0d=0x00000000 s0b=0x0 s1a=0x00000000 s1p=0x00000000 '
                     's1d=0x00000000 s1b=0x0 cw=0 cad=0x000 cva=0x00000000 '
                     'cvo=0x00000000 fl=0 ff=0x00000 fs=0 obs=1')
        return lines
    add('dut_data_after_end', 2, '出现在 # end 之后', mut_dut=m_dut_data_after_end)

    def m_dut_unknown(lines):
        for i, l in enumerate(lines):
            if l.startswith('5 '):
                lines[i] = l + ' bogus=1'
                break
        return lines
    add('dut_unknown_shape', 2, '不符合 v3 固定字段', mut_dut=m_dut_unknown)

    def m_fsd_single(lines):
        for i, l in enumerate(lines):
            if l.startswith('6 '):
                lines[i] = replace_field(l, 'ssz', '3')
        return lines
    add('fsd_single_phase', 2, 'fsd 只有单相', mut_dut=m_fsd_single)

    def m_missing_field(lines):
        for i, l in enumerate(lines):
            if l.startswith('15 '):
                lines[i] = l.replace(' obs=1', '')
        return lines
    add('field_missing', 2, '不符合 v3 固定字段', mut_dut=m_missing_field)

    def m_x_field(lines):
        for i, l in enumerate(lines):
            if l.startswith('15 '):
                lines[i] = replace_field(l, 's0d', 'xxxxxxxx')
        return lines
    add('field_x', 2, '不符合 v3 固定字段', mut_dut=m_x_field)

    add('reason_timeout', 2, 'reason=TIMEOUT', mut_tr=lambda tt: tt.update({'reason': 'TIMEOUT'}))

    # ---- 严格 metadata/end grammar 与 Spike 完整 disasm/label ----
    def insert_before_end(lines, extra):
        end = next(i for i, line in enumerate(lines) if line.startswith('# end'))
        lines.insert(end, extra)
        return lines
    add('dut_blank_before_end', 2, '空白行',
        mut_dut=lambda lines: insert_before_end(lines, ''))
    add('dut_blank_after_end', 2, '出现在 # end 之后',
        mut_dut=lambda lines: lines + [''])
    def m_broken_end(lines):
        end = next(i for i, line in enumerate(lines) if line.startswith('# end'))
        valid = lines[end]
        lines[end] = '# end broken'
        lines.append(valid)
        return lines
    add('dut_broken_end_then_valid', 2, '格式损坏', mut_dut=m_broken_end)
    add('dut_duplicate_header', 2, '未知/重复/错位元数据',
        mut_dut=lambda lines: lines[:3] + [lines[0]] + lines[3:])
    add('dut_missing_header_field', 2, '元数据不匹配',
        mut_dut=lambda lines: [lines[0], lines[1].replace(' sd=', ' ')] + lines[2:])
    add('dut_unknown_comment', 2, '未知/重复/错位元数据',
        mut_dut=lambda lines: lines[:3] + ['# arbitrary=1'] + lines[3:])

    legal_spike_prefix = ('core   0: >>>>  _fixture\n'
                          'core   0: 0x1c000000 (0x800002b7) lui t0, 0x80000\n'
                          'core   0: 0x1c000004 (0xfc731ae3) bne t1, t2, pc - 44\n')
    cases.append({'name': 'spike_valid_disasm_label', 'dut': dut0,
                  'spk': legal_spike_prefix + spk0, 'rc': 0,
                  'sub': 'CMP_CHECK', 'pa': 'bare'})
    add('spike_disasm_tail_garbage', 2, '合法完整反汇编',
        mut_spk=lambda lines: [
            'core   0: 0x1c000000 (0x800002b7) lui t0, 0x80000 garbage'] + lines)
    add('spike_disasm_unknown_mnemonic', 2, '未知 core 形态',
        mut_spk=lambda lines: [
            'core 0: 0x1c000000 (0x800002b7) garbage'] + lines)
    add('spike_disasm_lui_extra_operands', 2, '未知 core 形态',
        mut_spk=lambda lines: [
            'core 0: 0x1c000000 (0x800002b7) lui t0, 0x80000, garbage'] + lines)
    add('spike_disasm_lui_bad_immediate', 2, '未知 core 形态',
        mut_spk=lambda lines: [
            'core 0: 0x1c000000 (0x800002b7) lui t0, immediate'] + lines)
    add('spike_label_tail_garbage', 2, '符号标签',
        mut_spk=lambda lines: ['core   0: >>>> _fixture garbage'] + lines)

    v1 = ('# DUT commit trace — RV32GC 2A Spike lockstep (old v1)\n'
          '0 pc=0x1c000000 wen=1 rd=5 wdata=0x80000000\n'
          '# end commits=1 cycles=10 reason=TERM_PC term_pc=0x8000003c uart_writes=1\n')
    cases.append({'name': 'legacy_v1_rejected', 'dut': v1, 'spk': spk0,
                  'rc': 2, 'sub': '旧 v1', 'pa': 'bare'})

    # ---- 执行：rc/category/主诊断精确断言；只有全过才 PASS ----
    n_ok = 0
    actual_diags = {}
    for case in cases:
        rc, out = run_cmp(work, case['name'], case['dut'], case['spk'], case['pa'])
        no_pass = not re.search(r'^LOCKSTEP: [0-9]+/[0-9]+ PASS$', out, re.M)
        diag = parse_primary(out)
        actual_diags[case['name']] = diag
        if rc == 0:
            category_ok = diag is None
        elif rc == 1:
            category_ok = diag is not None and diag['category'] == 'CMP_DIVERGENCE'
        else:
            category_ok = diag is not None and diag['category'] in ('CMP_ERROR', 'CMP_UNSUPPORTED')
        primary_ok = ((not case.get('primary_required') or case.get('primary') is not None)
                      and (case.get('primary') is None
                           or primary_matches(diag, case['primary'])))
        ok = ((rc == case['rc']) and no_pass and (case['sub'] in out)
              and category_ok and primary_ok)
        if ok:
            n_ok += 1
            sys.stdout.write('CMP_SELFTEST_CASE: %s OK (rc=%d, category=%s, primary=%s)\n'
                             % (case['name'], rc,
                                diag['category'] if diag else 'none',
                                case.get('primary')))
        else:
            sys.stdout.write('CMP_SELFTEST_CASE: %s FAIL (rc=%d/exp %d, sub=%r, '
                             'category_ok=%s, primary_ok=%s, got=%r)\n'
                             % (case['name'], rc, case['rc'], case['sub'],
                                category_ok, primary_ok, diag))
            sys.stdout.write('---- 输出 ----\n%s\n' % out)

    # Matcher negative controls: identical broad text is not enough if the first
    # commit, PC, field, or observed/reference values are wrong.
    actual = actual_diags.get('fs_second_no_c768_wrong')
    correct = {'category': 'CMP_DIVERGENCE', 'index': 13, 'pc': 0x8000002C,
               'field': 'mstatus.FS', 'got': '2', 'ref': '3'}
    wrong_expectations = [
        dict(correct, index=14),
        dict(correct, pc=0x80000030),
        dict(correct, field='mstatus.SD', got='0', ref='1'),
    ]
    for n, wrong in enumerate(wrong_expectations, 1):
        guard_ok = primary_matches(actual, correct) and not primary_matches(actual, wrong)
        if guard_ok:
            n_ok += 1
            sys.stdout.write('CMP_SELFTEST_GUARD: wrong-frame/PC/cause-%d rejected OK\n' % n)
        else:
            sys.stdout.write('CMP_SELFTEST_GUARD: wrong-frame/PC/cause-%d FAIL actual=%r\n'
                             % (n, actual))

    # Same c1 reason and values must still fail if the alleged first frame is
    # shifted from index 13/PC 0x8000002c to index 14/PC 0x80000030.
    actual_ff = actual_diags.get('fflags_first_update_flipped')
    correct_ff = {'category': 'CMP_DIVERGENCE', 'index': 13, 'pc': 0x8000002C,
                  'field': 'fflags', 'got': '0x00000010', 'ref': '0x00000008'}
    for label, wrong_ff_diag in (
            ('index', dict(actual_ff, index=14) if actual_ff else None),
            ('pc', dict(actual_ff, pc=0x80000030) if actual_ff else None)):
        guard_ok = (primary_matches(actual_ff, correct_ff)
                    and not primary_matches(wrong_ff_diag, correct_ff))
        if guard_ok:
            n_ok += 1
            sys.stdout.write('CMP_SELFTEST_GUARD: c1 wrong-%s rejected OK\n' % label)
        else:
            sys.stdout.write('CMP_SELFTEST_GUARD: c1 wrong-%s FAIL actual=%r\n'
                             % (label, actual_ff))
    total = len(cases) + len(wrong_expectations) + 2
    if n_ok == total:
        sys.stdout.write('CMP_SELFTEST: %d/%d PASS\n' % (n_ok, total))
        return 0
    sys.stdout.write('CMP_SELFTEST: %d/%d FAIL\n' % (n_ok, total))
    return 1


if __name__ == '__main__':
    sys.exit(main())
