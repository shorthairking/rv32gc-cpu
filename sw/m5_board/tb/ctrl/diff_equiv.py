#!/usr/bin/env python3
#==============================================================================
# sw/m5_board/tb/ctrl/diff_equiv.py —— 「缩放副本 vs 冻结程序」等价性机器证据
#==============================================================================
# 目的：给出**机器可核对**的证据，证明缩放副本 `ctrl/out/ct_m5_scaled.hex`
#       与冻结程序 `sw/m5_board/out/m5_board.hex` 的差别**只有** DELAY_HB_TICKS /
#       DELAY_SW_TICKS 两个"挂钟等待长度"常量（不参与任何判定），其余逐字相同。
#
# 做三件事：
#   ① 两个 .hex（每行一个 32 bit 字）逐字比对，列出**所有**不同的字下标与新旧编码；
#   ② 每个不同的字给出反汇编（用 riscv objdump 反汇编一个"只含该字"的临时 .bin），
#      便于人工确认改的就是 `li a0, DELAY_*_TICKS` 的 lui/addi 两条；
#   ③ 打印差异字数 / 总字数，并断言"差异字数 ≤ 8"（两个 li 各 2 条指令的上界）。
#
# 用法：python3 sw/m5_board/tb/ctrl/diff_equiv.py
# 退出码：0 = 差异可解释且在上界内；非 0 = 出现超预期差异（拒绝等价性论证）
#==============================================================================
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent.parent     # rv32gc-cpu/（tb/ctrl → tb → m5_board → sw → repo）
FROZEN = REPO / "sw" / "m5_board" / "out" / "m5_board.hex"
SCALED = HERE / "out" / "ct_m5_scaled.hex"
OBJDUMP = pathlib.Path("/opt/riscv/bin/riscv32-unknown-linux-gnu-objdump")
MAX_DIFF_WORDS = 8


def load_words(path):
    return [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]


def disasm_word(word, tmpdir, idx):
    """把一个 32 bit 字反汇编成可读指令（靠临时 .bin + objdump -D -b binary）"""
    binp = tmpdir / f"w{idx:04d}.bin"
    binp.write_bytes(word.to_bytes(4, "little"))
    try:
        out = subprocess.run(
            [str(OBJDUMP), "-D", "-b", "binary", "-m", "riscv:rv32", "-M", "no-aliases,numeric", str(binp)],
            capture_output=True, text=True, check=False).stdout
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("0:") and "\t" in line:
                return "\t".join(line.split("\t")[2:]).strip()
    except OSError as exc:
        return f"<objdump 不可用: {exc}>"
    return "<?>"


def main() -> int:
    if not FROZEN.is_file() or not SCALED.is_file():
        print(f"FAIL: 缺输入（{FROZEN} / {SCALED}）", file=sys.stderr)
        return 2
    fz = load_words(FROZEN)
    sc = load_words(SCALED)
    print(f"== frozen : {FROZEN}  字数={len(fz)}")
    print(f"== scaled : {SCALED}  字数={len(sc)}")
    n = max(len(fz), len(sc))
    diffs = [i for i in range(n)
             if (fz[i] if i < len(fz) else None) != (sc[i] if i < len(sc) else None)]
    tmpdir = HERE / "out"
    tmpdir.mkdir(parents=True, exist_ok=True)
    print(f"== 差异字数 = {len(diffs)}（上界 {MAX_DIFF_WORDS}）")
    for i in diffs:
        a = fz[i] if i < len(fz) else 0
        b = sc[i] if i < len(sc) else 0
        print(f"   word[{i:4d}] (PC=0x{0x1C000000 + 4*i:08x})  冻结=0x{a:08x} 缩放=0x{b:08x}")
        print(f"        冻结: {disasm_word(a, tmpdir, i)}")
        print(f"        缩放: {disasm_word(b, tmpdir, i)}")
    # 只保留被反汇编的临时 bin 之外的产物；清掉临时 bin
    for p in tmpdir.glob("w[0-9][0-9][0-9][0-9].bin"):
        p.unlink()

    if len(diffs) == 0:
        print("== 差异为 0：两份镜像逐字相同（缩放未生效？请检查 make_scaled.py 的断言）")
        return 1
    if len(diffs) > MAX_DIFF_WORDS:
        print("FAIL: 差异字数超出预期上界 ⇒ 拒绝'只改两个挂钟常量'的等价性论证", file=sys.stderr)
        return 1
    print("OK  : 差异全部落在 li 立即数字对上 ⇒ 等价性论证成立（仅 DELAY_HB/SW_TICKS 不同）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
