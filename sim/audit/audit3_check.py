#!/usr/bin/env python3
# audit3_check.py —— 审计③验收判定（只读）。判定由脚本做出；"未捕获即失败"。
# 用法: python3 fpga/scratch/audit3_check.py
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, 'audit3_report.md')

fails = []
def check(cond, msg):
    if cond:
        print('  [ok]   ' + msg)
    else:
        print('  [FAIL] ' + msg)
        fails.append(msg)

if not os.path.isfile(REPORT):
    print('AUDIT3: FAIL (report missing: %s)' % REPORT); sys.exit(1)
txt = open(REPORT, encoding='utf-8').read()
lines = txt.split('\n')

print('== 1. 五节齐 ==')
for sec, name in [('①', '死转移/无消费/绕圈'), ('②', '不必要判断/重复计算'),
                  ('③', '死代码与僵尸'), ('④', '风格'), ('⑤', '代码质量 vs 综合优化分级')]:
    check(any(l.startswith('## ' + sec) for l in lines), '存在节 %s (%s)' % (sec, name))
check(any(l.startswith('## ⑥') for l in lines), '存在节 ⑥ 可回购清单')
check(any(l.startswith('## ⑦') for l in lines), '存在节 ⑦ grep 复现命令')

print('== 2. 报告头：冻结基准 HEAD + rpt sha256 ==')
check('d00eb03' in txt, '报告头含冻结基准 HEAD d00eb03')
check('6f91ee7614eda62b06f794feaac7971a76f1767e' in txt, '含 rtl 子树哈希')
check('0a7faefec2a371286981e5c879b2fda394aabe837589aa66310fb7f5451707e8' in txt,
      '含 utilization.rpt sha256')

print('== 3. 条目数 >= 65（A-/B-/C-/D-）==')
items = [l for l in lines if re.match(r'^\| [ABCD]-\d+ \|', l)]
check(len(items) >= 65, '条目行 %d >= 65' % len(items))
per = {}
for l in items:
    per.setdefault(l[2], 0)
    per[l[2]] += 1
print('      明细: ' + ', '.join('%s=%d' % (k, per[k]) for k in sorted(per)))

print('== 4. 每项有行号（rtl/<path>:<line>）==')
bad = [l for l in items if not re.search(r'rtl/[\w/\.]+:\d+', l)]
check(not bad, '全部 %d 项均含 rtl/<path>:<line>' % len(items))
for l in bad[:5]:
    print('      MISSING: ' + l[:120])

print('== 5. 预计影响列非空（可回购清单 R-*）==')
rows = [l for l in lines if re.match(r'^\| R-\d+ \|', l)]
check(len(rows) >= 20, '可回购条目 %d >= 20' % len(rows))
badr = [l for l in rows if not re.search(r'LUT|FF|需实测|影响|area|0\s*/\s*0', l)]
check(not badr, '全部 %d 条可回购项标注了预计影响' % len(rows))
for l in badr[:5]:
    print('      MISSING: ' + l[:120])

print('== 6. 锚点 ==')
check('AUDIT3: PASS' in txt, '报告含锚点 AUDIT3: PASS')

if fails:
    print('AUDIT3: FAIL (%d 项未过)' % len(fails))
    sys.exit(1)
print('AUDIT3: PASS')
