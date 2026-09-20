#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fpga/scratch/t3_analyze.py —— T3 时序/面积报告提取（临时，非交付物）

用法：
    python3 fpga/scratch/t3_analyze.py summary <timing_summary.rpt> [more.rpt ...]
    python3 fpga/scratch/t3_analyze.py paths   <timing_paths.rpt>   [--top N]
    python3 fpga/scratch/t3_analyze.py util    <utilization.rpt>
    python3 fpga/scratch/t3_analyze.py endpoints <timing_summary.rpt>

只读解析 Vivado 文本报告，不改任何设计文件。作用：
  * summary   : 从 report_timing_summary 抽 WNS/TNS/WHS/THS/失败端点/时钟周期
  * paths     : 从 report_timing 明细抽"最差 N 条路径"的 slack/逻辑级/数据延时/
                route 占比/源汇/中段模块归属（T3 判据⑤ 的余量任务清单原料）
  * util      : 从 report_utilization 抽 LUT/FF/BRAM/DSP 用量与占比
  * endpoints : 统计失败端点按"源模块 → 目的模块"聚集（诊断用）
"""
import re
import sys
from collections import Counter


def read(path):
    with open(path, "r", errors="replace") as fh:
        return fh.read()


def num(pat, text, default="n/a"):
    m = re.search(pat, text)
    return m.group(1).strip() if m else default


# --------------------------------------------------------------------------
# summary
# --------------------------------------------------------------------------
def cmd_summary(files):
    for f in files:
        t = read(f)
        print("=" * 78)
        print("报告 :", f)
        m = re.search(r"^\|\s*Design Name\s*:\s*(\S+)", t, re.M)
        state = num(r"Design State\s*:\s*(.+)", t, "?")
        print("  设计 :", m.group(1) if m else "?", "| 状态 :", state.strip())

        # ---- Design Timing Summary 表（列固定：WNS TNS #fail #total WHS THS ...）----
        lines = t.splitlines()
        row = None
        for i, l in enumerate(lines):
            if "WNS(ns)" in l and "TNS(ns)" in l:
                for j in range(i + 1, min(i + 6, len(lines))):
                    cand = lines[j].split()
                    if len(cand) >= 10 and re.match(r"^-?[\d.]+$", cand[0]):
                        row = cand
                        break
                break
        if row:
            wns, tns, nfail, ntot = row[0], row[1], row[2], row[3]
            whs, ths, hfail, htot = row[4], row[5], row[6], row[7]
            wpws, tpws, pfail, ptot = row[8], row[9], row[10], row[11]
            print("  WNS(setup) = %s ns   TNS = %s ns   失败端点 = %s / %s" %
                  (wns, tns, nfail, ntot))
            print("  WHS(hold)  = %s ns   THS = %s ns   失败端点 = %s / %s" %
                  (whs, ths, hfail, htot))
            print("  WPWS       = %s ns   TPWS = %s ns  失败端点 = %s / %s" %
                  (wpws, tpws, pfail, ptot))
            per = None
            cm = re.search(r"^\s*(\S+)\s+\{[^}]*\}\s+([\d.]+)\s+([\d.]+)\s*$", t, re.M)
            if cm:
                per = float(cm.group(2))
                print("  时钟       : %s  period=%s ns  freq=%s MHz" %
                      (cm.group(1), cm.group(2), cm.group(3)))
            else:
                rm = re.search(r"Requirement:\s*([\d.]+)ns", t)
                if rm:
                    per = float(rm.group(1))
                    print("  时钟周期   : %s ns（取自路径 Requirement）" % rm.group(1))
            if per and re.match(r"^-?[\d.]+$", wns):
                fmax = 1000.0 / (per - float(wns))
                print("  实测 Fmax  : %.2f MHz  （= 1/(period-WNS)，period=%.3f ns）" %
                      (fmax, per))
        else:
            print("  WARN: 未解析到 Design Timing Summary 表")
        if "All user specified timing constraints are met" in t:
            print("  约束判定   : All user specified timing constraints are met.  ✓")
        elif "Timing constraints are not met" in t:
            print("  约束判定   : Timing constraints are NOT met.  ✗")
        else:
            print("  约束判定   : （报告内未找到判定句）")
        if re.search(r"Endpoint Slack", t):
            hm = re.search(r"Endpoint Slack[^\n]*\n(.*?)\n\s*\n", t, re.S)
            if hm:
                print("  --- 失败端点 slack 直方图 ---")
                for line in hm.group(1).splitlines():
                    if line.strip() and set(line.strip()) != {"-"}:
                        print("   " + line.rstrip())


# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------
PATH_HEAD = re.compile(
    r"^\s*Slack \((MET|VIOLATED)\)\s*:\s*(-?[\d.]+)ns", re.M)
SRC_RE = re.compile(r"^\s*Source:\s*(\S+)", re.M)
DST_RE = re.compile(r"^\s*Destination:\s*(\S+)", re.M)
DPD_RE = re.compile(
    r"Data Path Delay:\s*(-?[\d.]+)ns\s*\(logic\s*([\d.]+)ns\s*\(([\d.]+)%\)\s*route\s*([\d.]+)ns\s*\(([\d.]+)%\)")
LL_RE = re.compile(r"Logic Levels:\s*(\d+)\s*\((.*)\)")


def fmt_delay(m):
    if not m:
        return "?"
    return "logic %.3f (%.1f%%) + route %.3f (%.1f%%) = %.3f ns" % (
        float(m.group(2)), float(m.group(3)),
        float(m.group(4)), float(m.group(5)), float(m.group(1)))


def unwind(res):
    """去掉实例后缀/位选/replica，得到"信号或寄存器基名"（用于归因统计）"""
    r = re.sub(r"/(C|Q|D|CE|R|S|CLR|PRE)$", "", res)
    r = re.sub(r"_replica\d*(_repN\d*)?$", "", r)
    r = re.sub(r"_reg(\[\d+\])?$", "", r)
    r = re.sub(r"\[[^\]]*\]", "", r)
    return r


def mod_of(res):
    """把源/汇资源名归到**模块**：取层次路径的第一段（顶层实例名），
    再对内部信号给出"所属文件级模块"提示。"""
    r = unwind(res)
    parts = [p for p in r.split("/") if p]
    if len(parts) >= 2:
        return "%s/*（%s）" % (parts[0], parts[1])
    return parts[0] if parts else res


def load_instmap(path):
    """读取 fpga/out/t3_instmap.tsv：实例层次名 -> 模块名（最长前缀匹配）"""
    m = {}
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    m[parts[0]] = parts[1]
    except OSError as e:
        print("WARN: 读不到实例映射 %s（%s）" % (path, e))
    return m


def owner_module(res, instmap):
    """把网表资源名归到**最深**的已知实例（= 信号所属模块）"""
    r = res.strip()
    r = re.sub(r"/(C|Q|D|CE|R|S|CLR|PRE)$", "", r)
    r = re.sub(r"\[[^\]]*\]", "", r)
    r = re.sub(r"_replica\d*(_repN\d*)?$", "", r)
    r = re.sub(r"/[A-Za-z_0-9]*_i_\d+$", "", r)
    parts = r.split("/")
    for k in range(len(parts), 0, -1):
        cand = "/".join(parts[:k])
        if cand in instmap:
            return "%s [%s]" % (instmap[cand], cand)
    return "?（顶层/未登记）%s" % ("/".join(parts[:1]) if parts else r)


def cmd_paths(files, top=20, instmap_path=None, slack_max=None):
    instmap = load_instmap(instmap_path) if instmap_path else {}
    for f in files:
        t = read(f)
        idx = [m.start() for m in PATH_HEAD.finditer(t)]
        print("=" * 78)
        print("报告 :", f, " （找到 %d 条路径明细）" % len(idx))
        srcs, dsts = Counter(), Counter()
        mods = Counter()
        pairmods = Counter()
        shown = 0
        for i, s in enumerate(idx):
            e = idx[i + 1] if i + 1 < len(idx) else len(t)
            seg = t[s:e]
            head = PATH_HEAD.search(seg)
            slack = float(head.group(2))
            src = SRC_RE.search(seg)
            dst = DST_RE.search(seg)
            src = src.group(1) if src else "?"
            dst = dst.group(1) if dst else "?"
            dpd = DPD_RE.search(seg)
            ll = LL_RE.search(seg)
            if shown < top and (slack_max is None or slack <= slack_max):
                shown += 1
                # 路径中段模块归属：统计该路径所有 netlist 资源里出现的实例模块
                steps = re.findall(r"^\s+\S+\s+\S+\s+[\d.]+\s+[\d.]+\s+[rf]\s+(\S+)\s*$",
                                   seg, re.M)
                mid = Counter()
                for st in steps:
                    om = owner_module(st, instmap)
                    if om.startswith("?"):
                        om = "(顶层) " + om.split("）")[-1]
                    mid[om] += 1
                print("-" * 74)
                print("#%d  slack %+0.3f ns  [%s]" % (shown, slack, head.group(1)))
                print("    源   :", src)
                print("    汇   :", dst)
                print("    源模块: %s" % owner_module(src, instmap))
                print("    汇模块: %s" % owner_module(dst, instmap))
                print("    延时 :", fmt_delay(dpd))
                if ll:
                    print("    级数 : %s  组成 %s" % (ll.group(1), ll.group(2)))
                print("    中段模块（按出现次数）: " +
                      ", ".join("%s×%d" % (k, v) for k, v in mid.most_common(6)))
            srcs[owner_module(src, instmap) if instmap else mod_of(src)] += 1
            dsts[owner_module(dst, instmap) if instmap else mod_of(dst)] += 1
            pairmods["%s  ->  %s" % (owner_module(src, instmap) if instmap else mod_of(src),
                                     owner_module(dst, instmap) if instmap else mod_of(dst))] += 1
        print("=" * 78)
        print("按【源模块】聚集（全部 %d 条，取前 12）:" % len(idx))
        for k, v in srcs.most_common(12):
            print("   %4d  %s" % (v, k))
        print("按【汇模块】聚集:")
        for k, v in dsts.most_common(12):
            print("   %4d  %s" % (v, k))
        print("按【源模块 → 汇模块】成对聚集:")
        for k, v in pairmods.most_common(12):
            print("   %4d  %s" % (v, k))


def cmd_endpoints(files):
    for f in files:
        t = read(f)
        print("=" * 78)
        print("失败端点归因 :", f)
        # timing summary 的 "Failing Endpoints" 表不易解析，改为按 slack 直方图 + 计数
        for pat, label in ((r"Number of failing end points\s*:\s*(\d+)", "失败端点(setup)"),
                           (r"Number of hold failing end points\s*:\s*(\d+)", "失败端点(hold)")):
            m = re.search(pat, t, re.I)
            if m:
                print("  %s = %s" % (label, m.group(1)))
        # 直方图（summary 里的 "Endpoint Slack" 段）
        m = re.search(r"Endpoint Slack.*?\n(.*?)\n\s*\n", t, re.S)
        if m:
            print("  --- Endpoint Slack 直方图 ---")
            for line in m.group(1).splitlines():
                if line.strip() and not line.strip().startswith("-"):
                    print("  " + line.rstrip())


# --------------------------------------------------------------------------
# util
# --------------------------------------------------------------------------
def cmd_util(files):
    for f in files:
        t = read(f)
        print("=" * 78)
        print("报告 :", f)
        want = ("Slice LUTs", "Slice Registers", "Block RAM Tile", "DSPs",
                "LUT as Logic", "LUT as Memory", "CLB", "Bonded IOB", "BUFGCTRL")
        for line in t.splitlines():
            s = line.strip()
            if not s.startswith("|"):
                continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if len(cells) < 3 or cells[1] in ("", "Used"):
                continue
            if cells[0] in want:
                print("   %-22s Used=%-8s (%-8s) Avail=%s" %
                      (cells[0], cells[1], cells[2],
                       cells[3] if len(cells) > 3 else ""))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    top, instmap, slack_max = 20, None, None
    files = []
    for a in sys.argv[2:]:
        if a.startswith("--top="):
            top = int(a.split("=", 1)[1])
        elif a.startswith("--instmap="):
            instmap = a.split("=", 1)[1]
        elif a.startswith("--slack-max="):
            slack_max = float(a.split("=", 1)[1])
        else:
            files.append(a)
    if cmd == "summary":
        cmd_summary(files)
    elif cmd == "paths":
        cmd_paths(files, top, instmap, slack_max)
    elif cmd == "util":
        cmd_util(files)
    elif cmd == "endpoints":
        cmd_endpoints(files)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
