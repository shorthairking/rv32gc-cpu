#!/usr/bin/env python3
# audit3_scan.py —— 只读扫描 rtl/**，输出结构化候选清单（不修改任何 RTL）
# 用法: python3 fpga/scratch/audit3_scan.py > fpga/scratch/audit3_scan.out
import os, re, sys, json
from collections import defaultdict, Counter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'rtl')
ROOT = os.path.normpath(ROOT)

files = []
for dp, dn, fn in os.walk(ROOT):
    for f in sorted(fn):
        if f.endswith('.v'):
            files.append(os.path.join(dp, f))
files.sort()

BASE = os.path.dirname(ROOT)
def rel(p): return os.path.relpath(p, BASE)

assign_re = re.compile(r'^\s*assign\s+([A-Za-z_][\w]*)\s*=\s*(.+?);\s*(?://.*)?$')
plain_rhs = re.compile(r'^([A-Za-z_][\w]*)$')
nb_re = re.compile(r'^\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*<=\s')
blk_re = re.compile(r'^\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=\s*(?!=)')
if_re = re.compile(r'\bif\s*\((.*)\)\s*(?:begin)?\s*$')
case_item_re = re.compile(r"^\s*(?:default\s*:|\s*[^:]+:)\s*(?:begin)?")

assigns = []          # (file,line,lhs,rhs)
nb_writes = []        # (file,line,sig)
blk_writes = []
if_lines = []

for p in files:
    with open(p, encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()
    for i, ln in enumerate(lines, 1):
        code = ln.split('//')[0]
        m = assign_re.match(ln)
        if m:
            assigns.append((p, i, m.group(1), m.group(2).strip()))
        m = nb_re.match(code)
        if m:
            nb_writes.append((p, i, m.group(1)))
        m = blk_re.match(code)
        if m:
            blk_writes.append((p, i, m.group(1)))
        m = if_re.match(code.rstrip())
        if m:
            if_lines.append((p, i, m.group(1).strip()))

out = []
def P(*a): out.append(' '.join(str(x) for x in a))

P('### A. assign 总数:', len(assigns))
P('### B. 非阻塞写总数:', len(nb_writes), ' 阻塞写总数:', len(blk_writes))

# ---- A1: 自赋值 assign X = X; ----
P('\n## A1 assign 自赋值 (assign X = X;)')
n = 0
for p, i, lhs, rhs in assigns:
    if rhs == lhs:
        P(f'  {rel(p)}:{i}: {lhs} = {lhs}')
        n += 1
P('  count=', n)

# ---- A2: 纯搬运链 A->B->C (rhs 为单一标识符) ----
driver = defaultdict(list)
for p, i, lhs, rhs in assigns:
    driver[(p, lhs)].append((p, i, rhs))
pure = {}   # lhs -> (file,line,src) 仅当该 lhs 只有 1 个 driver 且 rhs 为纯标识符
for (fp, lhs), lst in driver.items():
    if len(lst) == 1:
        p, i, rhs = lst[0]
        m = plain_rhs.match(rhs)
        if m:
            pure[lhs] = (p, i, m.group(1))

P('\n## A2 纯搬运链 (assign 链长>=2, 各级 rhs 均为单一标识符)')
chains = 0
seen = set()
for start in sorted(pure):
    path = [start]
    cur = start
    ok = True
    while cur in pure and len(path) < 12:
        src = pure[cur][2]
        if src in path:
            path.append(src + ' <CYCLE>')
            break
        path.append(src)
        cur = src
    if len(path) >= 3:
        key = tuple(path)
        if key in seen: continue
        seen.add(key)
        p, i, _ = pure[start]
        locs = [f'{rel(pure[x][0])}:{pure[x][1]}' for x in path[:-1] if x in pure]
        P(f'  len={len(path)-1} {rel(p)}:{i}  ' + ' -> '.join(path))
        P(f'      driver locs: ' + ', '.join(locs))
        chains += 1
P('  chain_count=', chains)

# ---- A3: 同一 LHS 被 assign 多次（覆盖链 / dead bits） ----
P('\n## A3 同一 LHS 多 driver (assign 覆盖链)')
md = 0
for (fp, lhs), lst in sorted(driver.items()):
    if len(lst) > 1:
        locs = ', '.join(f'{rel(p)}:{i}' for p, i, _ in lst)
        P(f'  {lhs} x{len(lst)}: {locs}')
        md += 1
P('  multi_driver_signal_count=', md)

# ---- A4: 重复 RHS（同周期重复计算，未共享 CSE） ----
P('\n## A4 同一 RHS 表达式在 >=4 处重复出现（同周期重复计算候选）')
rhs_cnt = Counter()
rhs_loc = defaultdict(list)
for p, i, lhs, rhs in assigns:
    if len(rhs) < 4: continue
    if rhs in ('1\'b0', '1\'b1', '0'): continue
    rhs_cnt[rhs] += 1
    rhs_loc[rhs].append(f'{rel(p)}:{i}')
for rhs, c in rhs_cnt.most_common(40):
    if c >= 4:
        P(f'  x{c}  {rhs[:110]}')
        P(f'        at: ' + ', '.join(rhs_loc[rhs][:12]) + (' ...' if c > 12 else ''))

# ---- A5: 同一 reg 在 always 块内被写多次（覆盖链） ----
P('\n## A5 同一信号非阻塞/阻塞写次数 >=3 (僵尸写口候选)')
wcnt = Counter()
wloc = defaultdict(list)
for p, i, s in nb_writes + blk_writes:
    wcnt[(p, s)] += 1
    wloc[(p, s)].append(f'{rel(p)}:{i}')
for (fp, s), c in wcnt.most_common(40):
    if c >= 3:
        P(f'  {rel(fp)}: {s} x{c}: ' + ', '.join(wloc[(fp,s)][:16]) + (' ...' if c > 16 else ''))

# ---- A6: 同一 always 块内重复 if 条件 ----
P('\n## A6 同一文件内 if 条件文本出现 >=3 次（可合并/冗余判定候选）')
ifcnt = Counter((rel(p), c) for p, i, c in if_lines)
for (f, c), k in ifcnt.most_common(30):
    if k >= 3:
        P(f'  x{k}  {f}:  if ({c[:100]})')

sys.stdout.write('\n'.join(out) + '\n')
