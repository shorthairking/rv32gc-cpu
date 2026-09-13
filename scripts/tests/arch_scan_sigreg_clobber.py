#!/usr/bin/env python3
"""arch_scan_sigreg_clobber.py —— 扫描 ACT4 生成的测试汇编，找出"签名指针被测试自身覆盖"的用例

背景（RV32GC 核 bring-up 时定位到的 ACT4 框架缺陷）
----------------------------------------------------
ACT4 生成器在"签名指针寄存器"与"被测指令操作数寄存器"冲突时，会发出

    mv x<new_sig>, x<old_sig>   # switch signature pointer register

这条搬运**依赖 old_sig 仍持有当前签名指针**。但当覆盖点把 old_sig 当作自己的
rs1/rd（例如 cp_rs1 的 bin b2 用 x2 作基址）时，测试自己发出的

    LA(x2, scratch)  →  auipc x2, … / addi x2, x2, imm

已经把 old_sig 写成 scratch 地址，于是这条 mv 把 **scratch 地址**当成签名指针
搬到新寄存器；此后所有 SIGUPD 都读写 scratch（被测数据区），自校验必然失败。

真实案例（riscv-arch-test/tests/rv32i/Zalrsc/Zalrsc-sc.w-00.S）
    cp_rs1_nx0 bin b2（test: 2）：
      ...
      lw  sp, 0(x17)          # 该用例第一条 SIGUPD 的签名比较（x17 是指针）
      ...
      mv  x2, x17             # b1 结束时把签名指针交给 x2（生成器发出的合法搬运）
      RVTEST_SIGUPD(x2, ...)  # 用 x2 做第二处签名比较（此时还不能证明被覆盖）
      LA(x2, scratch)         # ← 测试自身把 x2 改成 scratch 基址
      lr.w x0, (x2) / sc.w …  # b2 正体
      RVTEST_SIGUPD(x17, ...) # 指针已换成 x17
      LA(x2, scratch)
      lw  x4, 0(x17)          # ← 本应读 scratch，实际读签名区（x17 = 签名指针）
    根因：b1 的 SIGUPD 之后发出的 `mv x17, x2`（switch signature pointer）搬的是
    已经被 LA(x2, scratch) 覆盖过的 x2。

判定算法（纯文本，不需要跑仿真；模型是"寄存器值"而非"寄存器名"）
----------------------------------------------------------------
模拟值来源 pval(reg) ∈ {SIGPTR, LA_X, OTHER, ⊥}：
  * `SIGUPD(xS)`               → pval(xS) = SIGPTR
  * `addi xA, xA, (SIG_STRIDE>>s)` → 若 pval(xA)==SIGPTR 则保持（指针推进）
  * `mv xD, xS` 或 `addi xD, xS, 0`
                               → 若 pval(xS)==SIGPTR 则 pval(xD) = SIGPTR；
                                 否则按"搬运非指针值"（仅当该行是
                                 `# switch signature pointer register` 时才报告）
  * `LA(xD, …)` / `LI(xD, …)` / `lw xD, …` / `auipc xD, …`
                               → pval(xD) = LA_X / OTHER
  * 其它写 xD                   → pval(xD) = OTHER

当出现 `mv xN, xO # switch signature pointer register` 时：
  * pval(xO) != SIGPTR → 致命报告（xO 已被覆盖，搬走的是错值）
  * pval(xO) == SIGPTR → 记 pval(xN) = SIGPTR

用法:
    python3 scripts/tests/arch_scan_sigreg_clobber.py [路径 …]
    默认扫描 <workspace>/riscv-arch-test/tests/rv32i/**/*.S

退出码: 0 = 未发现；1 = 发现可疑文件；2 = 参数/路径错误。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

OTHER = "OTHER"
LA_X = "LA_IMMED"


def scan_file(path: Path) -> list[tuple[int, str]]:
    findings: list[tuple[int, str]] = []
    pval: dict[int, str] = {}

    for i, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue

        # --- 1) SIGUPD：参数里的寄存器此刻持有签名指针 ---
        m = re.search(r"RVTEST_SIGUPD(?:_FFLAGS)?\(\s*x(\d+)", line)
        if m:
            pval[int(m.group(1))] = "SIGPTR"
            continue

        # --- 2) 生成器的签名指针换寄存器 ---
        m = re.search(r"\bmv\s+x(\d+)\s*,\s*x(\d+)\s*#\s*switch signature pointer register", line)
        if m:
            dst, src = int(m.group(1)), int(m.group(2))
            if pval.get(src) != "SIGPTR":
                findings.append(
                    (i, f"致命：mv x{dst},x{src} # switch signature pointer —— x{src} 已被测试覆盖 "
                        f"(该寄存器此刻不是签名指针)，后续 SIGUPD 会写错位置")
                )
            pval = {dst: "SIGPTR"}  # 之后指针只应在 dst 里
            continue

        # --- 3) 指针推进：addi xA, xA, (SIG_STRIDE>>s) ---
        m = re.search(r"\baddi\s+x(\d+)\s*,\s*x(\d+)\s*,\s*\(SIG_STRIDE\s*>>\s*(\d+)\)", line)
        if m:
            rd, rs = int(m.group(1)), int(m.group(2))
            if rd == rs and pval.get(rs) == "SIGPTR":
                continue  # 指针推进，保持
            pval[rd] = OTHER
            continue

        # --- 4) la / li 序列（LA(x,r) 是注释，实际的 auipc/addi 在后面的行） ---
        m = re.search(r"\bLA\s*\(\s*x(\d+)\s*,", raw)
        if m:
            pval[int(m.group(1))] = LA_X
            continue

        # --- 5) 自增用 ##f：addi xN, xN, -N（重试计数等）---
        m = re.search(r"^\s*addi\s+x(\d+)\s*,\s*x(\d+)\s*,", line)
        if m:
            rd, rs = int(m.group(1)), int(m.group(2))
            if rd != rs:
                pval[rd] = pval.get(rs, OTHER) if pval.get(rs) == "SIGPTR" else OTHER
            continue

        # --- 6) 其它会写寄存器的高频指令（保守：置为 OTHER 只有当 rd 明确）---
        m = re.search(r"^\s*(la|li|lui|auipc|lw|lh|lb|lbu|lhu|lr\.w|sc\.w|ld|"
                      r"mv|li|slli|srli|srai|andi|ori|xori|add|sub|slt|sltu|"
                      r"amo\w+)\s+x(\d+)\s*,", line)
        if m:
            pval[int(m.group(2))] = OTHER
            continue
        m = re.search(r"^\s*SREG\s+x(\d+)\s*,", line)
        if m:
            continue
        m = re.search(r"^\s*LREG\s+x(\d+)\s*,", line)
        if m:
            pval[int(m.group(1))] = OTHER
            continue

    return findings


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    default_root = root.parent / "riscv-arch-test" / "tests" / "rv32i"
    args = sys.argv[1:]
    targets: list[Path] = []
    if args:
        for a in args:
            p = Path(a)
            if p.is_dir():
                targets.extend(sorted(p.rglob("*.S")))
            elif p.is_file():
                targets.append(p)
            else:
                print(f"ERROR: 路径不存在 {a}", file=sys.stderr)
                return 2
    else:
        targets = sorted(default_root.rglob("*.S"))
    if not targets:
        print("ERROR: 未找到待扫描的 .S 文件", file=sys.stderr)
        return 2

    suspicious = 0
    for t in targets:
        f = scan_file(t)
        if not f:
            continue
        suspicious += 1
        try:
            rel = t.relative_to(default_root)
        except ValueError:
            rel = t
        print(f"[FATAL] {rel}: {len(f)} 处")
        for ln, msg in f[:5]:
            print(f"        :{ln} {msg}")

    print(f"\n扫描 {len(targets)} 个 .S：受影响的测试文件 {suspicious} 个")
    return 1 if suspicious else 0


if __name__ == "__main__":
    sys.exit(main())
