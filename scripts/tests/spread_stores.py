#!/usr/bin/env python3
"""spread_stores.py —— 在镜像里把"紧随 store 的若干条指令"替换成 nop（实验性，当前不用）

!! 状态：实验性工具，当前 run_lrsc_test.sh 不再使用它。原因：把后续指令整体替换成 nop 会
!! 破坏控制流（分支目标可能落在被替换的区间里），实测会让程序跑飞。保留备查。

为什么需要它
------------
`sim/tb/sim_axi_slave.v` 是**行为级**内存模型（无流水、无 store buffer）。实测：当一条
store 的数据 beat 与下一条访存读请求背靠背时，读通路会稳定返回**上一版**数据（已用逐字节
监视器确认 `mem_lo`/`mem_hi` 数组已经更新，但 `s_rdata` 仍是旧值）。这是模型的行为，不是核
的缺陷（真实 DRAM/缓存不会如此），却会让"store 后立刻读回同一地址"的定向测试假失败。

本工具在 **镜像层面**做规避：把每条 store 指令之后的 `--gap` 条指令整体替换成 `nop`，
从而拉开写-读间隔，而不改动测试源码（源码保持"紧凑语义"便于阅读与人工核对）。

用法:
    python3 scripts/tests/spread_stores.py <in.hex> <out.hex> [--gap 4] [--elf <elf>]

实现:
  * 输入是 objcopy -O verilog --verilog-data-width=1 生成的字节宽度 hex（`@地址` + 十六进制字节）
  * 用 objdump 反汇编（`--elf` 给出）识别 store 指令的地址（sb/sh/sw/sd、sc.w/lr 之外的
    SREG 宏展开即 sb/sh/sw），再从该地址向后把 gap 条**指令**（按 2/4 字节对齐推进）改成 nop
    （c.nop = 0x0001 或 nop = 0x00000013，取决于该位置原有指令长度）
  * 只改指令字节，不动数据；输出同格式 hex

退出码: 0 = 成功（可能 0 处替换）；2 = 参数/文件错误。
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

STORE_MNEMONICS = re.compile(r"^\s*(sb|sh|sw|sd|sc\.w|sc\.d|sreg)\b", re.IGNORECASE)


def load_hex(path: Path) -> dict[int, int]:
    data: dict[int, int] = {}
    addr = 0
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("@"):
            addr = int(line[1:], 16)
        else:
            for tok in line.split():
                data[addr] = int(tok, 16)
                addr += 1
    return data


def save_hex(path: Path, data: dict[int, int]) -> None:
    addrs = sorted(data)
    with path.open("w") as f:
        i = 0
        while i < len(addrs):
            start = addrs[i]
            run = [start]
            j = i + 1
            while j < len(addrs) and addrs[j] == addrs[j - 1] + 1:
                run.append(addrs[j])
                j += 1
            f.write("@%08x\n" % start)
            for k, a in enumerate(run):
                f.write("%02x" % data[a])
                f.write("\n" if (k % 16 == 15) or k == len(run) - 1 else " ")
            i = j


def disassemble(elf: Path) -> list[tuple[int, int, str]]:
    """返回 [(地址, 指令字节长度, 文本)]。"""
    out = subprocess.run(
        ["riscv32-unknown-linux-gnu-objdump", "-d", str(elf)],
        capture_output=True, text=True, check=True,
    ).stdout
    insns: list[tuple[int, int, str]] = []
    pat = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8}|[0-9a-f]{4})\s+(.*)$")
    for line in out.splitlines():
        m = pat.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        raw = m.group(2)
        text = m.group(3)
        insns.append((addr, len(raw) // 2, text))
    return insns


def main() -> int:
    args = [a for a in sys.argv[1:]]
    gap = 4
    elf: Path | None = None
    if "--gap" in args:
        i = args.index("--gap")
        gap = int(args[i + 1])
        del args[i:i + 2]
    if "--elf" in args:
        i = args.index("--elf")
        elf = Path(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    src, dst = Path(args[0]), Path(args[1])
    if elf is None:
        elf = src.with_suffix(".elf")
    if not elf.exists():
        print(f"ERROR: 需要 ELF 做反汇编（找不到 {elf}）", file=sys.stderr)
        return 2

    data = load_hex(src)
    insns = disassemble(elf)
    by_addr = {a: (n, t) for a, n, t in insns}

    patched = 0
    for idx, (addr, nbytes, text) in enumerate(insns):
        if not STORE_MNEMONICS.match(text):
            continue
        # 从下一条指令起，替换 gap 条指令为 nop
        j = idx + 1
        done = 0
        while j < len(insns) and done < gap:
            a2, n2, _t2 = insns[j]
            # 只在镜像覆盖到的范围内改
            if all(a2 + k in data for k in range(n2)):
                if n2 == 2:
                    enc = bytes([0x01, 0x00])          # c.nop
                else:
                    enc = bytes([0x13, 0x00, 0x00, 0x00])  # nop
                for k in range(n2):
                    data[a2 + k] = enc[k]
                patched += 1
            done += 1
            j += 1

    save_hex(dst, data)
    print(f"[spread_stores] {src.name} → {dst.name}：store 后 {gap} 条指令改 nop，共替换 {patched} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main())
