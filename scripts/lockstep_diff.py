#!/usr/bin/env python3
"""lockstep_diff.py —— 比对 Spike 提交轨迹与 RTL 提交轨迹，输出首个分歧点。
用法: lockstep_diff.py <spike.log> <rtl.log>
Spike 行格式: core 0: 3 0x00000000 (0x00010117) x2 0x00080000
RTL  行格式: C<cyc> pc=<hex> instr=<hex> rd=<dec> wd=<hex> wen=<b>
"""
import re, sys

def parse_spike(path):
    out = []
    # 例: core   0: 3 0x00000000 (0x00080117) x2  0x00080000
    pat = re.compile(r'core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(?:\s+x(\d+)\s+0x([0-9a-f]+))?')
    for line in open(path, errors='replace'):
        m = pat.search(line)
        if not m:
            continue
        pc, instr = int(m.group(1), 16), int(m.group(2), 16)
        rd = int(m.group(3)) if m.group(3) else None
        wd = int(m.group(4), 16) if m.group(4) else 0
        out.append((pc, instr, rd, wd))
    return out

def parse_rtl(path):
    out = []
    pat = re.compile(r'^C\d+ pc=([0-9a-f]+) instr=([0-9a-f]+) rd=(\d+) wd=([0-9a-f]+) wen=(\d)')
    for line in open(path, errors='replace'):
        m = pat.match(line)
        if not m:
            continue
        pc = int(m.group(1), 16); instr = int(m.group(2), 16)
        rd = int(m.group(3)); wd = int(m.group(4), 16); wen = int(m.group(5))
        out.append((pc, instr, rd if wen else None, wd))
    return out

def main():
    pc_only = '--pc-only' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    sp, rtl = parse_spike(args[0]), parse_rtl(args[1])
    print("spike commits=%d  rtl commits=%d" % (len(sp), len(rtl)))
    n = min(len(sp), len(rtl))
    for i in range(n):
        a, b = sp[i], rtl[i]
        # 比对 PC 与写回（rd/wd），不比对 RVC 展开后的 instr（spike 显示原始指令）
        if a[0] != b[0] or (not pc_only and (a[2] or -1) != (b[2] or -1)) or (not pc_only and a[3] != b[3]):
            print("首个分歧 @ commit %d:" % (i + 1))
            print("  spike: pc=%08x instr=%08x rd=%s wd=%08x" % (a[0], a[1], a[2], a[3]))
            print("  rtl  : pc=%08x instr=%08x rd=%s wd=%08x" % (b[0], b[1], b[2], b[3]))
            for j in range(max(0, i - 4), min(n, i + 3)):
                print("   [%d] spike pc=%08x rd=%s wd=%08x | rtl pc=%08x rd=%s wd=%08x" %
                      (j + 1, sp[j][0], sp[j][2], sp[j][3], rtl[j][0], rtl[j][2], rtl[j][3]))
            return 1
    if len(sp) != len(rtl):
        print("前缀一致，但长度不同（spike=%d rtl=%d）" % (len(sp), len(rtl)))
        return 0
    print("LOCKSTEP: 全部 %d 条提交一致" % n)
    return 0

sys.exit(main())
