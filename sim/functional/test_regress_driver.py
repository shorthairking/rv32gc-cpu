#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#==============================================================================
# sim/functional/test_regress_driver.py —— 回归基础设施自证驱动（隔离、假工具、最小 TB）
#==============================================================================
# 目的 : 用**隔离夹具**证明 F0 修复后的判定行为，不依赖真实 RTL、不执行任何真实功能包、
#        不跑 CPU：
#        · scripts/regress.sh：正常例成功；混合 unknown+syntax 失败；仅 pending unknown 也
#          失败；缺依赖默认 strict 失败、放宽 rc0 且日志保留；PASS 后非零、缺锚点、多锚点、
#          多候选锚点、含 FAIL、超时、rc0 但零/空产物、STRICT_SKIP 非法值全部失败；
#          产物/日志每次独立目录，绝不向 sim/unit 写 vvp（含 unit 只读反证）。
#        · sim/functional/run.sh：固定清单只读校验 + 复制到**隔离空包目录**跑缺例反证
#          （任何真实包存在与否都不被执行）；CUSTOM 子集只输出 FUNCTIONAL_CUSTOM 前缀；
#          缺例/空清单/坏锚点/重名/路径逃逸/软链接逃逸/PASS 后非零/缺锚点/多锚点/含 FAIL/
#          DEFECT_REPRODUCED/包超时全部 fail-closed；合法目录内脚本与目录内软链接正常。
#        · 驱动自身：拒绝一切参数（含 --clean-stale），**不删除任何目录/产物**（无 rmtree）；
#          S 只在**本次唯一 ROOT** 下独占创建私有 sentinel 并校验内容/mtime/inode 未被改，
#          不触碰也不扫描共享 runner 下的既有目录；S2 并发跑两个自证，验证各自证据互不覆盖。
# 工具 : 只生成假 iverilog / 假 vvp 与最小 TB（tb_*.sv + dummy.v），不调用真实仿真器。
# 产物 : 全部落在已忽略的 build/functional/runner/selftest-<随机>/ 下；全部保留（证据）。
# 判定 : 任一断言失败 ⇒ 打印 FAIL 明细、rc=1，且**不打印** TEST_REGRESS_DRIVER: PASS；
#        全部通过 ⇒ 恰好打印一行 TEST_REGRESS_DRIVER: PASS，rc=0。
# 用法 : python3 sim/functional/test_regress_driver.py        # 不接受任何参数（含清理选项）
# 依据 : NEXT_SESSION.md §2.1 F0；sim/audit/global-2026-10-18/07-test-infrastructure.md
#        §发现1/2/7 与 REPORT:219（DEFECT_REPRODUCED ≠ 修复通过）；AGENT.md §0.6。
#==============================================================================
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RUNNER_BUILD = REPO / "build" / "functional" / "runner"
REGRESS_SH = REPO / "scripts" / "regress.sh"
FUNCTIONAL_SH = REPO / "sim" / "functional" / "run.sh"
FUNCTIONAL_DIR = REPO / "sim" / "functional"

# 成功聚合行（默认前缀 + CUSTOM 前缀）——任一出现即代表"入口级全绿"
ANCHOR_LINE_RE = r"(?:REGRESS|FUNCTIONAL_CUSTOM|FUNCTIONAL): [0-9]+/[0-9]+ (?:包 )?PASS"
# 仅"完整阶段"成功聚合（CUSTOM 子集绝不能输出它）
FUNCTIONAL_FULL_PASS_RE = r"FUNCTIONAL: [0-9]+/[0-9]+ 包 PASS"

FAILS: list[str] = []
CHECKS = 0
ROOT: Path  # 本次自证的产物根（build/functional/runner/selftest-*）
# 子运行标记（非 RV32_ 前缀，避免被 base_env 过滤）：S2 用它让子运行跳过并发用例防递归。
SELFTEST_CHILD_ENV = "DSH_SELFTEST_CHILD"

#------------------------------------------------------------------------------
# 假工具（仅解析参数/复刻产物，不做真实编译仿真）
#------------------------------------------------------------------------------
FAKE_IVERILOG = r'''#!/usr/bin/env bash
# 假 iverilog：只在夹具内使用。FAKE_IV_MODE 决定行为。
set -u
if [ "${1:-}" = "-V" ]; then printf 'Icarus Verilog version 12.0-fake (selftest)\n'; exit 0; fi
out=""; top=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -s) top="${2:-}"; shift 2 ;;
    -I|-D|-P) shift 2 ;;
    -g*) shift ;;
    *) shift ;;
  esac
done
mode="${FAKE_IV_MODE:-ok}"
case "$mode" in
  ok)
    [ -n "$out" ] || { printf 'fake iverilog: missing -o\n' >&2; exit 1; }
    [ -n "$top" ] || { printf 'fake iverilog: missing -s\n' >&2; exit 1; }
    src="${FAKE_VVP_DIR:?}/${top}.body"
    [ -f "$src" ] || { printf 'fake iverilog: no body for top=%s\n' "$top" >&2; exit 1; }
    cp -- "$src" "$out"
    exit 0 ;;
  noout)
    # rc0 但完全不产出 -o 文件（必须被判失败）
    exit 0 ;;
  emptyout)
    # rc0 但产出空文件（必须被判失败）
    if [ -n "$out" ]; then : > "$out"; fi
    exit 0 ;;
  mixed)
    printf 'rtl/dummy.v:1: error: Unknown module type: core_top\n'
    printf 'tb_x.sv:7: syntax error\n'
    exit 1 ;;
  pending_only)
    printf 'rtl/dummy.v:1: error: Unknown module type: core_top\n'
    exit 1 ;;
  *)
    printf 'fake iverilog: unknown mode=%s\n' "$mode" >&2; exit 1 ;;
esac
'''

FAKE_VVP = r'''#!/usr/bin/env bash
# 假 vvp：打印 body 文件内容，退出码/睡眠由 #FAKE_RC= / #FAKE_SLEEP= 指令控制。
set -u
f="${1:-}"
[ -f "$f" ] || { printf 'fake vvp: no such file: %s\n' "$f" >&2; exit 127; }
rc=0; sleep_s=0; body=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '#FAKE_RC='*)    rc="${line#\#FAKE_RC=}" ;;
    '#FAKE_SLEEP='*) sleep_s="${line#\#FAKE_SLEEP=}" ;;
    *) body="${body}${line}"$'\n' ;;
  esac
done < "$f"
if [ "${sleep_s:-0}" -gt 0 ] 2>/dev/null; then sleep "$sleep_s"; fi
printf '%s' "$body"
exit "$rc"
'''

EXPECTED_PKGS = [
    ("test_decode.sh", "FUNCTIONAL_DECODE: PASS"),
    ("test_backend_semantics.sh", "FUNCTIONAL_BACKEND_SEMANTICS: PASS"),
    ("test_privilege.sh", "FUNCTIONAL_PRIVILEGE: PASS"),
    ("test_rename.sh", "FUNCTIONAL_RENAME: PASS"),
    ("test_lsq.sh", "FUNCTIONAL_LSQ: PASS"),
    ("test_memory.sh", "FUNCTIONAL_MEMORY: PASS"),
    ("test_devices.sh", "FUNCTIONAL_DEVICES: PASS"),
    ("test_top_control.sh", "FUNCTIONAL_TOP_CONTROL: PASS"),
    ("test_frontend_faults.sh", "FUNCTIONAL_FRONTEND_FAULTS: PASS"),
]


def write_exec(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def check(cond: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(label)
        print(f"  FAIL: {label}", flush=True)


def base_env() -> dict:
    """清掉一切 RV32_* 继承变量，保证夹具环境自洽。"""
    env = {k: v for k, v in os.environ.items() if not k.startswith("RV32_")}
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    env["LC_ALL"] = "C"
    return env


def run(cmd: list[str], env: dict, cwd: Path | None = None, timeout: int = 180):
    return subprocess.run(cmd, env=env, cwd=str(cwd or REPO),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=timeout)


def save_log(case: str, out: str) -> Path:
    p = ROOT / "logs" / f"{case}.out"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(out, encoding="utf-8")
    return p


def has_pass_summary(out: str) -> bool:
    return re.search(ANCHOR_LINE_RE, out) is not None


def has_full_functional_pass(out: str) -> bool:
    return re.search(FUNCTIONAL_FULL_PASS_RE, out) is not None


def parse_entry_dirs(out: str):
    """解析入口打印的 本次运行目录 / 日志目录 / 包目录（均为绝对路径）。"""
    run_d = log_d = pkg_d = None
    for line in out.splitlines():
        m = re.search(r"本次运行目录=([^（\s]+)", line)
        if m:
            run_d = Path(m.group(1))
        m = re.search(r"日志目录=([^；）\s]+)", line)
        if m:
            log_d = Path(m.group(1))
        m = re.search(r"包目录=([^（\s]+)", line)
        if m:
            pkg_d = Path(m.group(1))
    return run_d, log_d, pkg_d


def parse_selftest_root(out: str) -> Path | None:
    """解析驱动自身打印的 '== selftest root = <绝对路径>'。"""
    m = re.search(r"selftest root = ([^\s]+)", out)
    return Path(m.group(1)) if m else None


def tb_source(top: str, anchor: str) -> str:
    return (f"// selftest mini TB: {top}\n"
            f"module {top};\n"
            f"  initial begin\n"
            f"    $display(\"{anchor}\");\n"
            f"  end\n"
            f"endmodule\n")


def make_case(name: str, tb_sources: dict[str, str], bodies: dict[str, str]) -> Path:
    case = ROOT / name
    (case / "rtl" / "pkg").mkdir(parents=True, exist_ok=True)
    (case / "unit").mkdir(parents=True, exist_ok=True)
    (case / "bin").mkdir(parents=True, exist_ok=True)
    (case / "vvp").mkdir(parents=True, exist_ok=True)
    (case / "rtl" / "dummy.v").write_text("module dummy; endmodule\n", encoding="utf-8")
    write_exec(case / "bin" / "iverilog", FAKE_IVERILOG)
    write_exec(case / "bin" / "vvp", FAKE_VVP)
    for top, src in tb_sources.items():
        (case / "unit" / f"{top}.sv").write_text(src, encoding="utf-8")
    for top, body in bodies.items():
        (case / "vvp" / f"{top}.body").write_text(body, encoding="utf-8")
    return case


def regress_env(case: Path, mode: str, out_override: bool = True,
                extra: dict | None = None) -> dict:
    env = base_env()
    env.update({
        "RV32_IVERILOG": str(case / "bin" / "iverilog"),
        "RV32_VVP": str(case / "bin" / "vvp"),
        "RV32_RTL_DIR": str(case / "rtl"),
        "RV32_PKG_DIR": str(case / "rtl" / "pkg"),
        "RV32_SIM_UNIT_DIR": str(case / "unit"),
        "RV32_BUILD_DIR": str(case / "build"),
        "FAKE_IV_MODE": mode,
        "FAKE_VVP_DIR": str(case / "vvp"),
    })
    if out_override:
        env["RV32_REGRESS_OUT_DIR"] = str(case / "out")
        env["RV32_REGRESS_LOG_DIR"] = str(case / "log")
    if extra:
        env.update(extra)
    return env


def regress_run_dirs(case: Path, out_override: bool = True) -> list[Path]:
    root = (case / "out") if out_override else (case / "build" / "functional" / "runner")
    if not root.is_dir():
        return []
    return sorted(p for p in root.glob("regress-*") if p.is_dir())


def unit_has_vvp(case: Path) -> bool:
    return any((case / "unit").glob("*.vvp"))


def case(name: str, fn) -> None:
    print(f"== case {name}", flush=True)
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 - 任何异常都算该例失败，继续跑其余例
        FAILS.append(f"{name}: exception {exc!r}")
        print(f"  FAIL: {name}: exception {exc!r}", flush=True)


#------------------------------------------------------------------------------
# A. regress 正常例成功 + 产物/日志隔离 + unit 目录只读反证（绝不写 sim/unit 语义）
#------------------------------------------------------------------------------
def c_a_normal_success() -> None:
    case = make_case("regress-normal", {"tb_ok": tb_source("tb_ok", "TB_OK: PASS")},
                     {"tb_ok": "TB_OK: PASS\n"})
    # 把夹具 unit 目录设为只读：若 runner 仍试图把 .vvp 写到 unit 目录就会失败。
    (case / "unit").chmod(0o555)
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-normal", r.stdout)
    check(r.returncode == 0, f"A rc 期望 0 实际 {r.returncode}")
    check("REGRESS: 1/1 PASS" in r.stdout, "A 缺少 'REGRESS: 1/1 PASS' 聚合行")
    check("本次运行目录=" in r.stdout, "A 未打印本次运行目录")
    dirs = regress_run_dirs(case)
    check(len(dirs) == 1, f"A 运行目录数期望 1 实际 {len(dirs)}")
    run_d, log_d = parse_entry_dirs(r.stdout)[:2]
    check(run_d is not None and run_d.is_dir(), "A 打印的运行目录不存在")
    check(run_d is not None and (case / "out").resolve() in run_d.resolve().parents,
          "A 运行目录不在配置的产物根下")
    check(log_d is not None and log_d.is_dir(), "A 打印的日志目录不存在")
    check(log_d is not None and (case / "log").resolve() in log_d.resolve().parents,
          "A 日志目录不在配置的日志根下")
    if run_d:
        check((run_d / "obj" / "tb_ok.vvp").is_file(), "A 缺少本次 run 目录内的 vvp 产物")
    if log_d:
        check((log_d / "tb_ok.compile.log").is_file(), "A 缺少编译日志")
        check((log_d / "tb_ok.run.log").is_file(), "A 缺少运行日志")
    check(not unit_has_vvp(case), "A 向夹具 unit 目录写了 .vvp（禁止）")


#------------------------------------------------------------------------------
# B/B2. regress 空集失败（TB 空 / RTL 空；不产生生成物）
#------------------------------------------------------------------------------
def c_b_empty_set() -> None:
    case = make_case("regress-empty", {}, {})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-empty", r.stdout)
    check(r.returncode != 0, f"B 空集应失败，实际 rc={r.returncode}")
    check("PASS" not in r.stdout, "B 空集失败路径出现了 PASS 字样")
    check("没有 tb_*.sv" in r.stdout, "B 未给出空集原因")
    check(not regress_run_dirs(case), "B 空集不应创建 run 目录")


def c_b2_empty_rtl() -> None:
    case = make_case("regress-nortl", {"tb_ok": tb_source("tb_ok", "TB_OK: PASS")},
                     {"tb_ok": "TB_OK: PASS\n"})
    (case / "rtl" / "dummy.v").unlink()
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-nortl", r.stdout)
    check(r.returncode != 0, f"B2 RTL 空集应失败，实际 rc={r.returncode}")
    check("PASS" not in r.stdout, "B2 RTL 空集失败路径出现了 PASS 字样")
    check("RTL" in r.stdout or "rtl" in r.stdout, "B2 未给出 RTL 空集原因")
    check(not regress_run_dirs(case), "B2 RTL 空集不应创建 run 目录")


#------------------------------------------------------------------------------
# C/D. 混合 unknown+syntax 失败；仅 pending unknown 也失败（旧降级删除反证）
#------------------------------------------------------------------------------
def c_c_mixed_unknown_syntax() -> None:
    case = make_case("regress-mixed", {"tb_mix": tb_source("tb_mix", "TB_MIX: PASS")},
                     {"tb_mix": "TB_MIX: PASS\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "mixed", extra={
        "RV32_REGRESS_PENDING_MODULES": "core_top"}))
    save_log("regress-mixed", r.stdout)
    check(r.returncode == 1, f"C 混合 unknown+syntax 应 rc=1，实际 {r.returncode}")
    check("FAIL" in r.stdout, "C 未判失败")
    check("SKIP" not in r.stdout, "C 出现 SKIP（fail-open 未修）")
    check(not has_pass_summary(r.stdout), "C 失败时出现 PASS 聚合行")
    check("已失效" in r.stdout, "C 未提示 pending 变量已失效")


def c_d_pending_only_must_fail() -> None:
    case = make_case("regress-pending", {"tb_pen": tb_source("tb_pen", "TB_PEN: PASS")},
                     {"tb_pen": "TB_PEN: PASS\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "pending_only", extra={
        "RV32_REGRESS_PENDING_MODULES": "core_top"}))
    save_log("regress-pending", r.stdout)
    check(r.returncode == 1, f"D 仅 pending unknown 应 rc=1，实际 {r.returncode}")
    check("SKIP" not in r.stdout, "D 仅 pending unknown 被 SKIP（旧降级仍在）")
    check(not has_pass_summary(r.stdout), "D 失败时出现 PASS 聚合行")


#------------------------------------------------------------------------------
# E/F. 缺依赖：默认 strict=1 失败(rc3)；显式放宽 rc0 但日志仍保留
#------------------------------------------------------------------------------
def c_ef_missing_dep() -> None:
    case = make_case("regress-dep", {"tb_dep": tb_source("tb_dep", "TB_DEP: PASS")},
                     {"tb_dep": "TB_DEP: PASS\n"})
    extra = {"RV32_REGRESS_EXTRA_DEPS": "tb_dep:rtl/definitely_missing.v"}
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok", extra=extra))
    save_log("regress-dep-strict", r.stdout)
    check(r.returncode == 3, f"E 默认 strict 缺依赖应 rc=3，实际 {r.returncode}")
    check("SKIP" in r.stdout, "E 未给出 SKIP 原因")
    check(not has_pass_summary(r.stdout), "E 跳过时出现 PASS 聚合行")
    dirs = regress_run_dirs(case)
    check(len(dirs) == 1 and dirs[0].is_dir(), "E 跳过时运行/日志目录未保留")

    case2 = make_case("regress-dep-lax", {"tb_dep": tb_source("tb_dep", "TB_DEP: PASS")},
                      {"tb_dep": "TB_DEP: PASS\n"})
    r2 = run(["bash", str(REGRESS_SH)], regress_env(case2, "ok", extra={
        "RV32_REGRESS_EXTRA_DEPS": "tb_dep:rtl/definitely_missing.v",
        "RV32_REGRESS_STRICT_SKIP": "0"}))
    save_log("regress-dep-lax", r2.stdout)
    check(r2.returncode == 0, f"F 放宽 strict 应 rc=0，实际 {r2.returncode}")
    check("SKIP" in r2.stdout, "F 未给出 SKIP 原因")
    check(not has_pass_summary(r2.stdout), "F 部分运行时出现 PASS 聚合行")
    dirs2 = regress_run_dirs(case2)
    check(len(dirs2) == 1 and dirs2[0].is_dir(),
          "F rc0 时日志目录被删除（07 §发现2 未修）")


#------------------------------------------------------------------------------
# G. PASS 之后非零退出必须失败
#------------------------------------------------------------------------------
def c_g_pass_then_nonzero() -> None:
    case = make_case("regress-nz", {"tb_nz": tb_source("tb_nz", "TB_NZ: PASS")},
                     {"tb_nz": "#FAKE_RC=3\nTB_NZ: PASS\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-nz", r.stdout)
    check(r.returncode == 1, f"G PASS 后 rc=3 应失败，实际 {r.returncode}")
    check("运行退出码=3" in r.stdout, "G 未把非零退出码作为失败原因")
    check(not has_pass_summary(r.stdout), "G 失败时出现 PASS 聚合行")


#------------------------------------------------------------------------------
# H/I/J. 缺锚点 / 输出多锚点 / 源码多候选锚点 都必须失败
#------------------------------------------------------------------------------
def c_hi_anchor() -> None:
    case = make_case("regress-noanchor", {"tb_na": tb_source("tb_na", "TB_NA: PASS")},
                     {"tb_na": "TB_NA: nothing-to-see\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-noanchor", r.stdout)
    check(r.returncode == 1, f"H 缺锚点应失败，实际 {r.returncode}")
    check("整行命中 0 次" in r.stdout, "H 未报告锚点整行命中 0 次")

    case2 = make_case("regress-dupanchor", {"tb_da": tb_source("tb_da", "TB_DA: PASS")},
                      {"tb_da": "TB_DA: PASS\nTB_DA: PASS\n"})
    r2 = run(["bash", str(REGRESS_SH)], regress_env(case2, "ok"))
    save_log("regress-dupanchor", r2.stdout)
    check(r2.returncode == 1, f"I 多锚点应失败，实际 {r2.returncode}")
    check("整行命中 2 次" in r2.stdout, "I 未报告锚点整行命中 2 次")


def c_j_source_multi_anchor() -> None:
    src = ("module tb_da3;\n"
           "  initial begin\n"
           "    $display(\"TB_DA3: PASS\");\n"
           "    $display(\"TB_DA3_UNIT: PASS\");\n"
           "  end\n"
           "endmodule\n")
    case = make_case("regress-srcmulti", {"tb_da3": src}, {"tb_da3": "TB_DA3: PASS\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-srcmulti", r.stdout)
    check(r.returncode == 1, f"J 多候选锚点应失败，实际 {r.returncode}")
    check("锚点不唯一" in r.stdout, "J 未报告锚点不唯一")


#------------------------------------------------------------------------------
# K/L. 输出含 FAIL / 超时
#------------------------------------------------------------------------------
def c_k_contains_fail() -> None:
    case = make_case("regress-failword", {"tb_f": tb_source("tb_f", "TB_F: PASS")},
                     {"tb_f": "TB_F: PASS\nFAIL: injected-defect\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok"))
    save_log("regress-failword", r.stdout)
    check(r.returncode == 1, f"K 含 FAIL 应失败，实际 {r.returncode}")
    check("FAIL 字样出现 1 行" in r.stdout, "K 未报告 FAIL 字样计数")


def c_l_timeout() -> None:
    case = make_case("regress-timeout", {"tb_to": tb_source("tb_to", "TB_TO: PASS")},
                     {"tb_to": "#FAKE_SLEEP=3\nTB_TO: PASS\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok", extra={"TB_TIMEOUT": "1"}))
    save_log("regress-timeout", r.stdout)
    check(r.returncode == 1, f"L 超时应失败，实际 {r.returncode}")
    check("运行退出码=124" in r.stdout, "L 未把 124 作为超时失败原因")


#------------------------------------------------------------------------------
# M. 并发两次不互覆（同一 OUT/LOG 根，两个独立 run 目录）
#------------------------------------------------------------------------------
def c_m_concurrency() -> None:
    case = make_case("regress-concurrent", {"tb_cc": tb_source("tb_cc", "TB_CC: PASS")},
                     {"tb_cc": "TB_CC: PASS\n"})
    env = regress_env(case, "ok")
    p1 = subprocess.Popen(["bash", str(REGRESS_SH)], env=env, cwd=str(REPO),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    p2 = subprocess.Popen(["bash", str(REGRESS_SH)], env=env, cwd=str(REPO),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    o1, _ = p1.communicate(timeout=180)
    o2, _ = p2.communicate(timeout=180)
    save_log("regress-concurrent-1", o1)
    save_log("regress-concurrent-2", o2)
    check(p1.returncode == 0 and p2.returncode == 0,
          f"M 并发两次应都 rc=0，实际 {p1.returncode}/{p2.returncode}")
    dirs = regress_run_dirs(case)
    check(len(dirs) == 2, f"M 并发应产生 2 个独立 run 目录，实际 {len(dirs)}")
    run1, log1 = parse_entry_dirs(o1)[:2]
    run2, log2 = parse_entry_dirs(o2)[:2]
    check(run1 is not None and run2 is not None and run1 != run2,
          f"M 两次运行目录未隔离：{run1} / {run2}")
    check(log1 is not None and log2 is not None and log1 != log2,
          f"M 两次日志目录未隔离：{log1} / {log2}")
    for tag, rd, ld in (("1", run1, log1), ("2", run2, log2)):
        check(rd is not None and rd.is_dir(), f"M 运行 {tag} 的 run 目录不存在")
        check(ld is not None and ld.is_dir(), f"M 运行 {tag} 的日志目录不存在")
        if ld:
            log = ld / "tb_cc.run.log"
            check(log.is_file(), f"M 运行 {tag} 缺少自己的运行日志：{ld}")
            check(log.is_file() and "TB_CC: PASS" in log.read_text(encoding="utf-8"),
                  f"M 运行 {tag} 的日志内容异常：{log}")


#------------------------------------------------------------------------------
# N. 默认产物根：不显式覆盖时落在 <BUILD>/functional/runner 下
#------------------------------------------------------------------------------
def c_n_default_out_root() -> None:
    case = make_case("regress-defaultout", {"tb_d": tb_source("tb_d", "TB_D: PASS")},
                     {"tb_d": "TB_D: PASS\n"})
    r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok", out_override=False))
    save_log("regress-defaultout", r.stdout)
    check(r.returncode == 0, f"N 默认产物根运行应 rc=0，实际 {r.returncode}")
    dirs = regress_run_dirs(case, out_override=False)
    check(len(dirs) == 1, f"N 默认根下应有 1 个 run 目录，实际 {len(dirs)}")
    check(str(case / "build" / "functional" / "runner") in r.stdout,
          "N 未打印默认产物根下的运行目录")


#------------------------------------------------------------------------------
# R. 真实 sim/unit 只读发现：全部 TB 取到唯一顶层/锚点（不编译任何 RTL、不跑 CPU）
#------------------------------------------------------------------------------
def c_r_real_discovery() -> None:
    unit = REPO / "sim" / "unit"
    tbs = sorted(unit.glob("tb_*.sv"))
    check(len(tbs) >= 33,
          f"R 真实 sim/unit 的 tb_*.sv 不得少于基线 33（用例不得删除），实际 {len(tbs)}")
    if not tbs:
        return
    entries = " ".join(f"{p.stem}:rtl/__selftest_missing_dep__" for p in tbs)
    case = ROOT / "regress-realdiscover"
    (case / "bin").mkdir(parents=True, exist_ok=True)
    write_exec(case / "bin" / "iverilog", FAKE_IVERILOG)
    write_exec(case / "bin" / "vvp", FAKE_VVP)
    env = base_env()
    env.update({
        "RV32_IVERILOG": str(case / "bin" / "iverilog"),
        "RV32_VVP": str(case / "bin" / "vvp"),
        "RV32_RTL_DIR": str(REPO / "rtl"),
        "RV32_SIM_UNIT_DIR": str(unit),
        "RV32_BUILD_DIR": str(case / "build"),
        "RV32_REGRESS_OUT_DIR": str(case / "out"),
        "RV32_REGRESS_LOG_DIR": str(case / "log"),
        "RV32_REGRESS_EXTRA_DEPS": entries,
        "RV32_REGRESS_STRICT_SKIP": "0",
        "FAKE_IV_MODE": "ok",
        "FAKE_VVP_DIR": str(case / "vvp"),
    })
    r = run(["bash", str(REGRESS_SH)], env)
    save_log("regress-realdiscover", r.stdout)
    n_skip = r.stdout.count("SKIP  —— 依赖未落盘：")
    check(r.returncode == 0, f"R 放宽 strict 下应 rc=0，实际 {r.returncode}")
    check(n_skip == len(tbs),
          f"R 真实 TB 应逐个取到唯一锚点后 SKIP（期望 {len(tbs)}，实际 {n_skip}）")
    check("锚点不唯一" not in r.stdout, "R 真实 TB 中存在锚点不唯一的用例")
    check("找不到 `module` 声明" not in r.stdout, "R 真实 TB 中存在取不到顶层的用例")
    check(not has_pass_summary(r.stdout), "R 全部跳过时出现 PASS 聚合行")


#------------------------------------------------------------------------------
# T. 编译 rc0 但零产物 / 空产物 ⇒ 必须失败
#------------------------------------------------------------------------------
def c_t_zero_product() -> None:
    for mode in ("noout", "emptyout"):
        case = make_case(f"regress-{mode}", {"tb_op": tb_source("tb_op", "TB_OP: PASS")},
                         {"tb_op": "TB_OP: PASS\n"})
        r = run(["bash", str(REGRESS_SH)], regress_env(case, mode))
        save_log(f"regress-{mode}", r.stdout)
        check(r.returncode == 1, f"T[{mode}] rc0 无/空产物应失败，实际 {r.returncode}")
        check("未产出非空 vvp" in r.stdout, f"T[{mode}] 未给出零产物失败原因")
        check(not has_pass_summary(r.stdout), f"T[{mode}] 失败时出现 PASS 聚合行")


#------------------------------------------------------------------------------
# U. STRICT_SKIP 只接受 0/1；非法显式值一律拒绝（不回退 rc0）
#------------------------------------------------------------------------------
def c_u_strict_skip_values() -> None:
    for bad in ("true", "2", "01", "false", "", "yes", "TRUE", "-1"):
        case = make_case(f"regress-strict-{bad or 'empty'}",
                         {"tb_s": tb_source("tb_s", "TB_S: PASS")},
                         {"tb_s": "TB_S: PASS\n"})
        r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok", extra={
            "RV32_REGRESS_STRICT_SKIP": bad}))
        save_log(f"regress-strict-{bad or 'empty'}", r.stdout)
        check(r.returncode == 1,
              f"U[{bad!r}] 非法 STRICT_SKIP 应 rc=1，实际 {r.returncode}")
        check("只接受 0 或 1" in r.stdout, f"U[{bad!r}] 未拒绝非法 STRICT_SKIP")
        check(not has_pass_summary(r.stdout), f"U[{bad!r}] 非法值出现了 PASS 聚合行")
        check(not regress_run_dirs(case), f"U[{bad!r}] 非法值不应创建 run 目录")
    for good in ("0", "1"):
        case = make_case(f"regress-strict-ok-{good}",
                         {"tb_s": tb_source("tb_s", "TB_S: PASS")},
                         {"tb_s": "TB_S: PASS\n"})
        r = run(["bash", str(REGRESS_SH)], regress_env(case, "ok", extra={
            "RV32_REGRESS_STRICT_SKIP": good}))
        save_log(f"regress-strict-ok-{good}", r.stdout)
        check(r.returncode == 0, f"U[{good!r}] 合法值应 rc=0，实际 {r.returncode}")
        check("REGRESS: 1/1 PASS" in r.stdout, f"U[{good!r}] 缺少全绿聚合行")


#------------------------------------------------------------------------------
# 功能入口 run.sh：夹具构造与执行
#------------------------------------------------------------------------------
def make_func_fixture(name: str, rows: list[tuple[str, str, str]],
                      scripts: dict[str, str],
                      symlinks: dict[str, str] | None = None) -> Path:
    func = ROOT / name / "func"
    func.mkdir(parents=True, exist_ok=True)
    lines = ["# selftest fixture manifest"]
    for script, anchor, desc in rows:
        lines.append(f"{script}\t{anchor}\t{desc}")
    (func / "manifest.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
    for fname, body in scripts.items():
        (func / fname).write_text(body, encoding="utf-8")
    for link, target in (symlinks or {}).items():
        os.symlink(target, func / link)
    return func


def func_env(func_dir: Path, out: Path, pkg_timeout: str = "60") -> dict:
    env = base_env()
    env["RV32_FUNCTIONAL_DIR"] = str(func_dir)
    env["RV32_FUNCTIONAL_OUT_DIR"] = str(out)
    env["RV32_FUNCTIONAL_PKG_TIMEOUT"] = pkg_timeout
    return env


GOOD_ALPHA = "#!/usr/bin/env bash\necho \"FUNCTIONAL_ALPHA: PASS\"\n"
GOOD_BETA = "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\n"
ROWS_GOOD = [("test_alpha.sh", "FUNCTIONAL_ALPHA: PASS", "fixture alpha"),
             ("test_beta.sh", "FUNCTIONAL_BETA: PASS", "fixture beta")]


def functional_negative(name: str, rows, scripts, expect_msg: str | None = None,
                        extra_env: dict | None = None,
                        symlinks: dict[str, str] | None = None,
                        pkg_timeout: str = "60") -> None:
    case_root = ROOT / name
    func = make_func_fixture(name, rows, scripts, symlinks)
    env = func_env(func, case_root / "fout", pkg_timeout=pkg_timeout)
    if extra_env:
        env.update(extra_env)
    r = run(["bash", str(FUNCTIONAL_SH)], env)
    save_log(name, r.stdout)
    check(r.returncode == 1, f"{name} 应 rc=1，实际 {r.returncode}")
    check("FAIL" in r.stdout, f"{name} 未判失败")
    check(not has_pass_summary(r.stdout), f"{name} 失败时出现 PASS 聚合行")
    if expect_msg:
        check(expect_msg in r.stdout, f"{name} 未给出预期原因（{expect_msg}）")
    check((case_root / "fout").is_dir(), f"{name} 未保留本次 run 目录")


#------------------------------------------------------------------------------
# V. 固定清单只读校验 + 复制到隔离空包目录跑缺例反证（真实包绝不被执行）
#------------------------------------------------------------------------------
def c_v_isolated_missing_case() -> None:
    rows = []
    for line in (FUNCTIONAL_DIR / "manifest.tsv").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        rows.append((parts[0], parts[1]))
    check(rows == EXPECTED_PKGS, f"V 固定清单应为规定的 9 包/锚点，实际 {rows}")

    case_root = ROOT / "functional-isolated-empty"
    iso = case_root / "func"
    iso.mkdir(parents=True, exist_ok=True)
    # 只复制清单文本到隔离空包目录：目录内不含任何 test_*.sh
    (iso / "manifest.tsv").write_text(
        (FUNCTIONAL_DIR / "manifest.tsv").read_text(encoding="utf-8"), encoding="utf-8")
    r = run(["bash", str(FUNCTIONAL_SH)], func_env(iso, case_root / "fout"))
    save_log("functional-isolated-empty", r.stdout)

    _, _, pkg_d = parse_entry_dirs(r.stdout)
    check(pkg_d is not None and pkg_d == iso.resolve(),
          f"V 入口必须使用隔离空包目录，实际包目录={pkg_d}")
    check(pkg_d != FUNCTIONAL_DIR, "V 入口使用了真实 sim/functional 目录（真实包可能被执行）")
    check(not any(iso.glob("test_*.sh")), "V 隔离目录不应含包脚本")
    check(r.returncode == 1, f"V 隔离空包目录应 rc=1，实际 {r.returncode}")
    check(r.stdout.count("（缺例：脚本未落盘") == len(rows),
          f"V 缺例报告数应为 {len(rows)}，实际 {r.stdout.count('（缺例：脚本未落盘')}")
    check(not has_pass_summary(r.stdout), "V 缺例时出现成功聚合行")
    check(not has_full_functional_pass(r.stdout), "V CUSTOM 输出冒充完整阶段 FUNCTIONAL:N/N")
    check(f"FUNCTIONAL_CUSTOM: 失败 {len(rows)} / 共 {len(rows)} 包" in r.stdout,
          "V 未按 CUSTOM 标记失败聚合")
    check("SKIP" not in r.stdout, "V 功能入口对缺例出现了 SKIP（不允许）")
    check("入口类型=CUSTOM" in r.stdout, "V 未标注 CUSTOM 入口类型")


#------------------------------------------------------------------------------
# P/P2. CUSTOM 正向：普通夹具全绿；目录内软链接正常；绝不输出完整阶段前缀
#------------------------------------------------------------------------------
def c_p_custom_positive() -> None:
    case_root = ROOT / "functional-ok"
    func = make_func_fixture("functional-ok", ROWS_GOOD,
                             {"test_alpha.sh": GOOD_ALPHA, "test_beta.sh": GOOD_BETA})
    r = run(["bash", str(FUNCTIONAL_SH)], func_env(func, case_root / "fout"))
    save_log("functional-ok", r.stdout)
    check(r.returncode == 0, f"P 全绿应 rc=0，实际 {r.returncode}")
    check("FUNCTIONAL_CUSTOM: 2/2 包 PASS" in r.stdout, "P 缺少 CUSTOM 2/2 包 PASS 聚合行")
    check(not has_full_functional_pass(r.stdout),
          "P CUSTOM 子集输出了完整阶段 FUNCTIONAL: N/N 包 PASS（禁止）")
    check("入口类型=CUSTOM" in r.stdout, "P 未标注 CUSTOM 入口类型")
    check("本次运行目录=" in r.stdout, "P 未打印运行目录")


def c_p2_indir_symlink_ok() -> None:
    case_root = ROOT / "functional-indir-link"
    func = make_func_fixture(
        "functional-indir-link", ROWS_GOOD,
        {"real_alpha.sh": GOOD_ALPHA, "test_beta.sh": GOOD_BETA},
        symlinks={"test_alpha.sh": "real_alpha.sh"})
    r = run(["bash", str(FUNCTIONAL_SH)], func_env(func, case_root / "fout"))
    save_log("functional-indir-link", r.stdout)
    check(r.returncode == 0, f"P2 目录内软链接应 rc=0，实际 {r.returncode}")
    check("FUNCTIONAL_CUSTOM: 2/2 包 PASS" in r.stdout, "P2 缺少 CUSTOM 2/2 包 PASS")
    check(not has_full_functional_pass(r.stdout), "P2 CUSTOM 输出冒充完整阶段前缀")


#------------------------------------------------------------------------------
# Q. run.sh fail-closed 反证族（含 DEFECT_REPRODUCED / 包超时）
#------------------------------------------------------------------------------
def c_q_functional_negatives() -> None:
    functional_negative(
        "func-nz", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA,
         "test_beta.sh": "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\nexit 5\n"},
        expect_msg="rc=5")
    functional_negative(
        "func-noanchor", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA,
         "test_beta.sh": "#!/usr/bin/env bash\necho \"no anchor\"\n"},
        expect_msg="锚点整行命中 0 次")
    functional_negative(
        "func-dupanchor", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA,
         "test_beta.sh": "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\n"
                         "echo \"FUNCTIONAL_BETA: PASS\"\n"},
        expect_msg="锚点整行命中 2 次")
    functional_negative(
        "func-failword", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA,
         "test_beta.sh": "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\n"
                         "echo \"FAIL: injected\"\n"},
        expect_msg="FAIL 字样出现 1 行")
    # 合法 FUNCTIONAL_* 锚点 + 旧错误复现标记 ⇒ 仍必须失败
    functional_negative(
        "func-defect", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA,
         "test_beta.sh": "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\n"
                         "echo \"DEFECT_REPRODUCED\"\n"},
        expect_msg="DEFECT_REPRODUCED")
    functional_negative(
        "func-missingpkg", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA},
        expect_msg="缺例")
    functional_negative(
        "func-emptymanifest", [],
        {"test_alpha.sh": GOOD_ALPHA},
        expect_msg="无有效包条目")
    functional_negative(
        "func-badanchor",
        [("test_alpha.sh", "FUNCTIONAL_WRONG: PASS", "bad anchor")],
        {"test_alpha.sh": GOOD_ALPHA},
        expect_msg="锚点与约定不符")
    functional_negative(
        "func-dupscript",
        [("test_alpha.sh", "FUNCTIONAL_ALPHA: PASS", "dup1"),
         ("test_alpha.sh", "FUNCTIONAL_ALPHA: PASS", "dup2")],
        {"test_alpha.sh": GOOD_ALPHA},
        expect_msg="清单脚本重复")
    functional_negative(
        "func-escape",
        [("../evil.sh", "FUNCTIONAL_EVIL: PASS", "escape")],
        {},
        expect_msg="路径非法")
    # 包脚本超时 ⇒ 失败（rc=124）
    functional_negative(
        "func-timeout",
        [("test_slow.sh", "FUNCTIONAL_SLOW: PASS", "slow package")],
        {"test_slow.sh": "#!/usr/bin/env bash\nsleep 5\necho \"FUNCTIONAL_SLOW: PASS\"\n"},
        expect_msg="rc=124", pkg_timeout="1")


def c_q_symlink_escapes() -> None:
    # Q11 文件软链接逃逸：test_beta.sh -> 包目录外的可执行文件（即使它会打印合法锚点）
    case_root = ROOT / "func-symlink-file"
    outside = case_root / "outside"
    outside.mkdir(parents=True, exist_ok=True)
    (outside / "evil.sh").write_text(
        "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\n", encoding="utf-8")
    func = make_func_fixture(
        "func-symlink-file", ROWS_GOOD,
        {"test_alpha.sh": GOOD_ALPHA},
        symlinks={"test_beta.sh": str(outside / "evil.sh")})
    r = run(["bash", str(FUNCTIONAL_SH)], func_env(func, case_root / "fout"))
    save_log("func-symlink-file", r.stdout)
    check(r.returncode == 1, f"Q11 文件软链接逃逸应 rc=1，实际 {r.returncode}")
    check("realpath 逃出包目录" in r.stdout, "Q11 未报告 realpath 逃逸")
    check(not has_pass_summary(r.stdout), "Q11 失败时出现成功聚合行")

    # Q12 父目录软链接逃逸：manifest 指向 link/test_beta.sh，link -> 包目录外目录
    case_root2 = ROOT / "func-symlink-parent"
    outside2 = case_root2 / "outside2"
    outside2.mkdir(parents=True, exist_ok=True)
    (outside2 / "test_beta.sh").write_text(
        "#!/usr/bin/env bash\necho \"FUNCTIONAL_BETA: PASS\"\n", encoding="utf-8")
    func2 = make_func_fixture(
        "func-symlink-parent",
        [("test_alpha.sh", "FUNCTIONAL_ALPHA: PASS", "alpha"),
         ("link/test_beta.sh", "FUNCTIONAL_BETA: PASS", "beta via dir link")],
        {"test_alpha.sh": GOOD_ALPHA},
        symlinks={"link": str(outside2)})
    r2 = run(["bash", str(FUNCTIONAL_SH)], func_env(func2, case_root2 / "fout"))
    save_log("func-symlink-parent", r2.stdout)
    check(r2.returncode == 1, f"Q12 父目录软链接逃逸应 rc=1，实际 {r2.returncode}")
    check("realpath 逃出包目录" in r2.stdout, "Q12 未报告 realpath 逃逸")
    check(not has_pass_summary(r2.stdout), "Q12 失败时出现成功聚合行")


#------------------------------------------------------------------------------
# S. 驱动自身拒绝一切参数（含 --clean-stale），绝不删除/改写**本次 ROOT 内**的已有证据
#    ★ 只用本次运行的唯一 ROOT 下的私有 sentinel；不引用、不清理共享 runner 下任何已有目录；
#      独占创建（拒绝已存在/软链接），被拒调用前后校验内容/mtime/inode 未变。
#------------------------------------------------------------------------------
def c_s_reject_args_no_delete() -> None:
    sentinel = ROOT / "private-sentinel"          # 私有：只在本 run 独占 ROOT 内
    check(not sentinel.exists() and not sentinel.is_symlink(),
          "S 前置：私有 sentinel 路径不应存在且不得是软链接")
    if sentinel.exists() or sentinel.is_symlink():
        raise RuntimeError(f"S 私有 sentinel 路径被占用（拒绝复用/软链接）：{sentinel}")
    sentinel.mkdir(parents=False, exist_ok=False)  # 独占创建；父目录=本次 ROOT 已存在

    ev = sentinel / "evidence.txt"
    content0 = b"private evidence v1\n"
    ev.write_bytes(content0)
    ev.chmod(0o600)
    st0 = ev.stat()
    mtime0, ino0 = st0.st_mtime_ns, st0.st_ino

    def verify_private(tag: str) -> None:
        check(not sentinel.is_symlink() and sentinel.is_dir(),
              f"S{tag} 私有 sentinel 目录被替换/删除/改为软链接")
        check(ev.is_file() and not ev.is_symlink(),
              f"S{tag} 私有证据文件被删除/替换/改为软链接")
        try:
            cur = ev.read_bytes()
            st = ev.stat()
        except OSError as exc:
            check(False, f"S{tag} 私有证据不可读：{exc!r}")
            return
        check(cur == content0, f"S{tag} 私有证据内容被改写")
        check(st.st_mtime_ns == mtime0, f"S{tag} 私有证据 mtime 被改写")
        check(st.st_ino == ino0, f"S{tag} 私有证据 inode 被替换")

    for args in (["--clean-stale"], ["--bogus"], ["clean"]):
        r = run([sys.executable, str(Path(__file__).resolve()), *args], base_env())
        check(r.returncode == 2,
              f"S 参数 {args} 应被非零拒绝（rc=2），实际 {r.returncode}")
        check("未知参数" in r.stdout or "不支持" in r.stdout,
              f"S 参数 {args} 未给出拒绝原因")
        verify_private(f"[{args[0]}]")
    verify_private("[end]")


#------------------------------------------------------------------------------
# S2. 两个并发自证运行都成功，且各自 ROOT 的证据互不覆盖（隔离 fake，不跑 CPU）
#     · 子运行用 DSH_SELFTEST_CHILD=1 跳过本用例，避免递归；其余用例全部照跑。
#     · 只比较两次运行各自的 ROOT 路径与内容，不扫描共享 runner 作不变断言。
#------------------------------------------------------------------------------
def c_s2_concurrent_runs_isolated() -> None:
    if os.environ.get(SELFTEST_CHILD_ENV) == "1":
        print("  -- 子运行：跳过 S2 并发用例（防递归）", flush=True)
        return
    env = base_env()
    env[SELFTEST_CHILD_ENV] = "1"
    cmd = [sys.executable, str(Path(__file__).resolve())]
    p1 = subprocess.Popen(cmd, env=env, cwd=str(REPO),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    p2 = subprocess.Popen(cmd, env=env, cwd=str(REPO),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    o1, _ = p1.communicate(timeout=900)
    o2, _ = p2.communicate(timeout=900)
    save_log("selftest-concurrent-1", o1)
    save_log("selftest-concurrent-2", o2)
    check(p1.returncode == 0 and p2.returncode == 0,
          f"S2 两个并发自证应都 rc=0，实际 {p1.returncode}/{p2.returncode}")
    check("TEST_REGRESS_DRIVER: PASS" in o1 and "TEST_REGRESS_DRIVER: PASS" in o2,
          "S2 并发子运行未各自通过")

    roots = [parse_selftest_root(o1), parse_selftest_root(o2)]
    check(all(r is not None for r in roots), f"S2 未能解析子运行 ROOT：{roots}")
    check(roots[0] is not None and roots[1] is not None and roots[0] != roots[1],
          f"S2 两次并发运行未隔离到不同 ROOT：{roots}")
    for tag, root, out in (("1", roots[0], o1), ("2", roots[1], o2)):
        if root is None:
            continue
        check(root.is_dir(), f"S2 运行{tag} 的 ROOT 不存在：{root}")
        check(str(ROOT) not in str(root),
              f"S2 运行{tag} 复用了父运行 ROOT（证据会互覆）：{root}")
        rlog = root / "logs" / "regress-normal.out"
        check(rlog.is_file(), f"S2 运行{tag} 缺少自己的 regress 日志：{rlog}")
        if rlog.is_file():
            check("REGRESS: 1/1 PASS" in rlog.read_text(encoding="utf-8", errors="replace"),
                  f"S2 运行{tag} 的 regress 日志内容不属于自己")
        pev = root / "private-sentinel" / "evidence.txt"
        check(pev.is_file(), f"S2 运行{tag} 缺少自己的私有证据：{pev}")
        if pev.is_file():
            check(pev.read_bytes() == b"private evidence v1\n",
                  f"S2 运行{tag} 的私有证据被其它运行覆盖")
        check(f"selftest root = {root}" in out,
              f"S2 运行{tag} 输出中的 ROOT 与实际不符")


def main() -> int:
    global ROOT
    if len(sys.argv) > 1:
        print(f"FAIL: 不支持/未知参数被拒绝（不删除任何产物）：{sys.argv[1:]}", flush=True)
        print("用法: python3 sim/functional/test_regress_driver.py", flush=True)
        return 2
    RUNNER_BUILD.mkdir(parents=True, exist_ok=True)
    ROOT = Path(tempfile.mkdtemp(prefix="selftest-", dir=str(RUNNER_BUILD)))
    print(f"== selftest root = {ROOT}", flush=True)
    print(f"== repo root     = {REPO}", flush=True)

    case("A-regress-normal", c_a_normal_success)
    case("B-regress-empty", c_b_empty_set)
    case("B2-regress-empty-rtl", c_b2_empty_rtl)
    case("C-regress-mixed", c_c_mixed_unknown_syntax)
    case("D-regress-pending-only", c_d_pending_only_must_fail)
    case("E/F-regress-missing-dep", c_ef_missing_dep)
    case("G-regress-pass-then-nonzero", c_g_pass_then_nonzero)
    case("H/I-regress-anchor", c_hi_anchor)
    case("J-regress-source-multi-anchor", c_j_source_multi_anchor)
    case("K-regress-contains-fail", c_k_contains_fail)
    case("L-regress-timeout", c_l_timeout)
    case("M-regress-concurrency", c_m_concurrency)
    case("N-regress-default-out-root", c_n_default_out_root)
    case("R-regress-real-discovery", c_r_real_discovery)
    case("T-regress-zero-product", c_t_zero_product)
    case("U-strict-skip-values", c_u_strict_skip_values)
    case("V-functional-isolated-missing", c_v_isolated_missing_case)
    case("P-functional-custom-positive", c_p_custom_positive)
    case("P2-functional-indir-symlink", c_p2_indir_symlink_ok)
    case("Q-functional-negatives", c_q_functional_negatives)
    case("Q11/Q12-symlink-escapes", c_q_symlink_escapes)
    case("S-args-rejected-no-delete", c_s_reject_args_no_delete)
    case("S2-concurrent-runs-isolated", c_s2_concurrent_runs_isolated)

    print(f"== 断言数={CHECKS} 失败数={len(FAILS)}", flush=True)
    if FAILS:
        for f in FAILS:
            print(f"FAIL: {f}", flush=True)
        print(f"FAIL: 自证未全部通过（{len(FAILS)}/{CHECKS}）；证据目录 {ROOT}", flush=True)
        return 1
    print(f"TEST_REGRESS_DRIVER: PASS（{CHECKS} 项断言；证据目录 {ROOT}）", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
