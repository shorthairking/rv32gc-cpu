#!/usr/bin/env python3
"""arch_fail_locate.py —— 从本核提交轨迹定位 arch-test 首个失败用例

用法:
    scripts/arch_fail_locate.py <test.elf> <rtl_trace.log> [--hex <image.hex>]

原理:
    ACT4 自校验宏 RVTEST_SIGUPD 在比较失败时执行
        jal <link>, failedtest_<link>_<temp>
        .word <instptr>     ← 被测指令地址（用例标签）
        .word <strptr>      ← 用例描述字符串
    本工具用 nm 取得 failedtest_* 地址，在轨迹里找**第一个**落入其中的提交，
    回看前若干条提交定位那条 jal，再从镜像读出后面两个 .word（instptr/strptr），
    从而直接给出失败用例的地址与描述串。

输出: 失败点上下文（前 12 条 / 后 3 条）、instptr/strptr、strptr 处的字符串。
退出码: 0=找到；1=轨迹里没有 failedtest（可能是其它失败路径或超时）。
"""
import re, subprocess, sys, os

def load_hex(path):
    data = {}
    addr = 0
    if not path or not os.path.exists(path):
        return data
    for line in open(path, errors='replace'):
        line = line.strip()
        if not line:
            continue
        if line.startswith('@'):
            addr = int(line[1:], 16)
        else:
            for tok in line.split():
                data[addr] = int(tok, 16)
                addr += 1
    return data

def read_str(data, a, n=120):
    out = bytearray()
    for i in range(n):
        b = data.get(a + i)
        if b is None or b == 0:
            break
        out.append(b)
    return out.decode('latin1')

def read_word(data, a):
    # 镜像 hex 可能是 0x0 基（objcopy --change-addresses=-0x80000000），两种都试
    for base in (a, a - 0x80000000):
        if all((base + i) in data for i in range(4)):
            return sum(data[base + i] << (8 * i) for i in range(4))
    return None

def read_str_at(data, a, n=120):
    for base in (a, a - 0x80000000):
        if base in data:
            return read_str(data, base, n)
    return ""

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    elf, trace = sys.argv[1], sys.argv[2]
    hexf = None
    if '--hex' in sys.argv:
        hexf = sys.argv[sys.argv.index('--hex') + 1]

    nm = subprocess.run(['riscv32-unknown-linux-gnu-nm', '-n', elf],
                        capture_output=True, text=True).stdout
    ft = {}
    for l in nm.splitlines():
        p = l.split()
        if len(p) == 3 and p[2].startswith('failedtest'):
            ft[int(p[0], 16)] = p[2]
    if not ft:
        print("ERROR: ELF 中没有 failedtest_* 符号")
        return 2

    commits = []
    for l in open(trace, errors='replace'):
        m = re.match(r'^C(\d+) pc=([0-9a-f]+) instr=([0-9a-f]+) rd=(\d+) wd=([0-9a-f]+) wen=(\d)', l)
        if m:
            commits.append((int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16),
                            int(m.group(4)), int(m.group(5), 16)))
    if not commits:
        print("ERROR: 轨迹为空（%s）" % trace)
        return 2

    hit = None
    for i, c in enumerate(commits):
        if c[1] in ft:
            hit = (i, c)
            break
    if hit is None:
        print("未在轨迹中发现 failedtest_* 入口；提交数=%d，最后 PC=%08x" %
              (len(commits), commits[-1][1]))
        return 1

    i, c = hit
    print("首个失败处理入口: %s @ cyc=%d pc=%08x" % (ft[c[1]], c[0], c[1]))
    print("--- 进入失败处理前的 12 条提交:")
    for x in commits[max(0, i - 12):i]:
        print("    cyc=%-8d pc=%08x instr=%08x rd=%2d wd=%08x" % x)
    jal = commits[i - 1] if i > 0 else None
    data = load_hex(hexf)
    if jal is not None:
        instptr = read_word(data, jal[1] + 4)
        strptr = read_word(data, jal[1] + 8)
        print("jal(pc=%08x) 后的 .word: instptr=%s strptr=%s" %
              (jal[1], ("%08x" % instptr) if instptr else "?", ("%08x" % strptr) if strptr else "?"))
        if strptr:
            print("用例描述: %r" % read_str_at(data, strptr))
        if instptr:
            print("被测指令地址: 0x%08x（用 objdump -d --start-address=0x%x 查看该用例）" % (instptr, instptr))
    return 0

sys.exit(main())
