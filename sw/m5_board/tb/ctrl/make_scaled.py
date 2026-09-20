#!/usr/bin/env python3
#==============================================================================
# sw/m5_board/tb/ctrl/make_scaled.py —— 生成"缩放控制实验"程序（控制实验 B）
#==============================================================================
# 目的：被冻结的 m5_board.S 在 RTL 仿真里**跑不完**（步④ 的 N_MEAS=2e6 × 10 条指令
#       ≈ 2e7 条指令；步③ 另有 2e5 次迭代；再加上 UART 每字符最多 2000 次 LSR 等待
#       迭代）。本脚本对它做**纯机械、可核对**的 4 处"计数常量缩放"，其余字符
#       （地址口径、判据常量 TPI_SIG/TPI_TOL、字符串、五步结构、udiv …）逐字不动，
#       从而在可承受的仿真时间里观察"程序逻辑本身会判 OK 还是 BAD"。
#
# 4 处替换（每处都断言**恰好命中 1 次**，否则非零退出 —— 拒绝静默改错）：
#   ① `.equ N_MEAS,      2000000`        → `1000`         （步④ 迭代数）
#   ② `addi  a1, x0, 2000  # 等待上限`    → `addi a1, x0, 4`（puts_char 的 LSR 等待上限；
#        仿真内存模型不建模 LSR ⇒ 真机上一拍即回，仿真里则会白等满 2000 次）
#   ③ `li    a0, 20000     # 心跳延时`    → `200`
#   ④ `li    a0, 200000    # 步③ 延时`   → `2000`
#
# 用法：python3 sw/m5_board/tb/ctrl/make_scaled.py
# 产物：sw/m5_board/tb/ctrl/out/ct_m5_scaled.S（+ 打印源文件 md5，供留档）
#==============================================================================
import hashlib
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent.parent / "m5_board.S"          # sw/m5_board/m5_board.S（只读）
OUT_DIR = HERE / "out"
DST = OUT_DIR / "ct_m5_scaled.S"

RULES = [
    # (说明, 正则, 替换, 期望命中次数)
    #   ★ 只缩放"**与判据无关**的 TIMER 挂钟等待"（DELAY_HB_TICKS / DELAY_SW_TICKS）：
    #     它们只决定"停多久"，不参与任何判定 ⇒ 缩放后步④/步⑤ 的判据与冻结程序逐字相同。
    #   ★ **不缩放** MEAS_ITER / XIP_CPI / TGT_TICKS / TGT_TOL（步④ 的被判量），
    #     也不缩放 puts_char 的 LSR 等待上限（新版已由作者从 2000 降到 64，
    #     仿真里每字符 ≈2.7e3 拍 ⇒ 无需再动，保持"只改挂钟等待"的最小偏离）。
    ("心跳间隔 DELAY_HB_TICKS", r"\.equ DELAY_HB_TICKS,(\s+)8000000", r".equ DELAY_HB_TICKS,\g<1>100000", 1),
    ("步③ 停留 DELAY_SW_TICKS", r"\.equ DELAY_SW_TICKS,(\s+)10000000", r".equ DELAY_SW_TICKS,\g<1>200000", 1),
]

def main() -> int:
    if not SRC.is_file():
        print(f"FAIL: 找不到源程序 {SRC}", file=sys.stderr)
        return 2
    text = SRC.read_text(encoding="utf-8", errors="strict")
    src_md5 = hashlib.md5(text.encode()).hexdigest()

    for name, pat, rep, want in RULES:
        text, n = re.subn(pat, rep, text)
        if n != want:
            print(f"FAIL: 替换「{name}」命中 {n} 次（期望 {want} 次）⇒ 源程序已变，拒绝生成",
                  file=sys.stderr)
            return 1
        print(f"OK  : 替换「{name}」命中 {n} 次")

    header = (
        "#==============================================================================\n"
        "# 【自动生成，请勿手改】ct_m5_scaled.S —— 控制实验 B：m5_board.S 的缩放副本\n"
        f"# 源文件: ../../m5_board.S   md5={src_md5}\n"
        "# 生成器: ../make_scaled.py（仅缩放 4 个计数常量；地址/判据/字符串逐字不动）\n"
        "# 用途  : 在可承受的仿真时间里看程序逻辑本身判 OK 还是 BAD（非交付固件）\n"
        "#==============================================================================\n"
    )
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    DST.write_text(header + text, encoding="utf-8")
    print(f"== 源 md5 = {src_md5}")
    print(f"== 生成   = {DST}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
