#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_top_control.sh —— F4-0 顶层控制/错误接口定向测试（fail-closed）
#==============================================================================
# 范围：只读 RTL（两 top 已由本包同批接线，但本脚本不写 RTL）；产物只落
#       repo/build/functional/top-control/<mktemp run>/。
# 做什么：
#   1) 以**完整依赖的私有不可变快照**为唯一输入：rtl/**/*.{v,vh} + sim/functional 全部
#      （mandatory 子域 helper 脚本 + 其 TB）+ sim/tb + sim/unit/prog + scripts/env.sh +
#      5 个定向 TB；快照前后各记一次 SHA256 清单（排除 snapshot 内 build/ 产物）；
#   2) 在**快照 root 内、相对路径**编译 `core_top` / `core_top_2b`（elaboration 检查）
#      与 5 个定向 TB（boot / m3 / core_top_2b / l1d / l1i）；
#   3) 逐 TB 真跑：rc=0、输出非空、唯一 PASS 锚点（整行恰好 1 次）、无 FAIL/XZ/UNKNOWN；
#   4) **固定 mandatory 子域 helper 正向调用**（6 个，缺文件/缺捕获一律 fail，绝不
#      SKIP/OPEN/PASS）：backend_permission / rob_window / counter_time / data_control /
#      data_bus / 2a_control（新 owner 发布 test_2a_control.sh 后自动纳入）。每个 helper 只从本包**冻结快照闭包**调用（DUT_ROOT=SNAP，不回落 live
#      树），独立 mktemp PKGOUT（不得与父 RUN_DIR 重叠），判据 = rc0（超时即失败）+
#      非空日志 + 该 helper **自己的唯一锚点**恰 1 行 + 无 FAIL/DEFECT_REPRODUCED。
#      子域统计单独打印（TOP_CONTROL_SUBDOMAINS），**不并入** 5 个 TB 的包计数。
# 默认只有正确期望；`--self-test` 为独立的反证模式（缺/重锚点、非零 rc、超时、XZ），
# 通过时只打印 `FUNCTIONAL_TOP_CONTROL_NEGATIVE: PASS`，绝不打印默认锚点。
# 工具：只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP。
#==============================================================================
set -u
NEG=0
if [ "$#" -gt 1 ]; then printf 'FUNCTIONAL_TOP_CONTROL: FAIL reason=unknown_arg\n'; exit 1; fi
if [ "$#" -eq 1 ]; then
  case "$1" in --self-test) NEG=1 ;; *) printf 'FUNCTIONAL_TOP_CONTROL: FAIL reason=unknown_arg\n'; exit 1 ;; esac
fi
case "${RV32_TOP_CONTROL_MODE:-spec}" in spec) ;; self-test) NEG=1 ;; *) printf 'FUNCTIONAL_TOP_CONTROL: FAIL reason=bad_mode\n'; exit 1 ;; esac

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF_ABS="$SELF_DIR/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)"
DUT_ROOT="${RV32_TC_DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" && pwd -P)" || { printf 'FUNCTIONAL_TOP_CONTROL: FAIL reason=dut_root_unresolved\n'; exit 1; }
[ -f "$DUT_ROOT/sim/functional/test_top_control.sh" ] && cmp -s -- "$SELF_ABS" "$DUT_ROOT/sim/functional/test_top_control.sh" \
  || { printf 'FUNCTIONAL_TOP_CONTROL: FAIL reason=entry_source_mismatch\n'; exit 1; }
ENV_SH="$DUT_ROOT/scripts/env.sh"
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/top-control}"
RUN_DIR=""; SUM_OK="-"; SUM_BAD="-"
emit_fail() {
  if [ "$NEG" -eq 1 ]; then
    printf 'FUNCTIONAL_TOP_CONTROL_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
  else
    printf 'TOP_CONTROL_TESTS total=%s ok=%s bad=%s\n' "$((${#TB_LIST[@]}))" "$SUM_OK" "$SUM_BAD"
    if [ -n "$HDOM_TOTAL" ]; then
      printf 'TOP_CONTROL_SUBDOMAINS total=%s ok=%s bad=%s\n' "$HDOM_TOTAL" "$HDOM_OK" "$HDOM_BAD"
    fi
    printf 'FUNCTIONAL_TOP_CONTROL: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
  fi
  exit 1
}
is_auth() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail out_root
is_auth "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM"
mkdir -p -- "$ROOT_NORM" || emit_fail out_root_mkdir
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail out_root_recheck
is_auth "$ROOT_NORM" || emit_fail out_root_escape
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail mktemp
RUN_LOG="$RUN_DIR/test_top_control.log"
printf 'TOP_CONTROL_RUN_DIR=%s\n' "$RUN_DIR"
: > "$RUN_LOG" || emit_fail run_log
echo "MODE = $([ "$NEG" -eq 1 ] && echo self-test || echo spec)" >> "$RUN_LOG"

# Arrays are initialized before any preflight can call emit_fail.
TB_LIST=()
command -v python3 >/dev/null 2>&1 || emit_fail python3_missing
command -v sha256sum >/dev/null 2>&1 || emit_fail sha_missing

# ---- 定向 TB 清单：<文件>:<top>:<锚点>:<超时秒> ----
TB_LIST=(
  "sim/unit/tb_boot_stub.sv|tb_boot_stub|TB_BOOT_STUB: PASS|900"
  "sim/unit/tb_m3_ddr3.sv|tb_m3_ddr3|TB_M3_DDR3: PASS|1200"
  "sim/unit/tb_core_top_2b.sv|tb_core_top_2b|TB_CORE_TOP_2B: PASS|1200"
  "sim/unit/tb_l1d.sv|tb_l1d_top|TB_L1D_UNIT: PASS|600"
  "sim/unit/tb_l1i.sv|tb_l1i_top|TB_L1I_UNIT: PASS|600"
)
SIM_DEPS=( sim/tb/sim_mem_model.sv sim/unit/prog/boot_stub_words.svh sim/unit/prog/back2_lockstep_data.svh )
SOURCE_FILES=()
while IFS= read -r -d '' f; do SOURCE_FILES+=("$f"); done < <(cd -- "$DUT_ROOT" && find rtl -type f \( -name '*.v' -o -name '*.vh' \) -print0)
SOURCE_FILES+=(scripts/env.sh)
if [ "$NEG" -eq 1 ]; then
  # Self-test snapshot binds only the code actually exercised; never depends on unrelated live helper internals.
  SOURCE_FILES+=(sim/functional/test_top_control.sh sim/functional/test_top_control_driver.sh \
    sim/functional/tb_top_control_semantics.sv sim/tb/sim_mem_model.sv)
else
  for d in sim/functional sim/tb sim/unit/prog; do
    while IFS= read -r -d '' f; do SOURCE_FILES+=("$f"); done < <(cd -- "$DUT_ROOT" && find "$d" -type f -print0)
  done
  SOURCE_FILES+=("${SIM_DEPS[@]}")
  for e in "${TB_LIST[@]}"; do IFS='|' read -r tb _ _ _ <<<"$e"; SOURCE_FILES+=("$tb"); done
fi
manifest_files() {
  python3 - "$1" "${SOURCE_FILES[@]}" <<'PY'
import base64, os, re, subprocess, sys
root = os.fsencode(sys.argv[1])
for rel in sorted({os.fsencode(text) for text in sys.argv[2:]}):
    r = subprocess.run([b'sha256sum', b'--', rel], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.stderr.buffer.write(r.stderr); sys.exit(r.returncode or 1)
    m = re.fullmatch(rb'([0-9a-f]{64})  ' + re.escape(rel) + rb'\n', r.stdout)
    if not m:
        sys.stderr.write('sha256sum_raw_output_invalid\n'); sys.exit(1)
    sys.stdout.buffer.write(m.group(1) + b' ' + base64.b64encode(rel) + b'\n')
PY
}
raw_file_sha() {
  python3 - "$1" <<'PY'
import os, re, subprocess, sys
path = os.fsencode(sys.argv[1])
r = subprocess.run([b'sha256sum', b'--', path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if r.returncode != 0:
    sys.stderr.buffer.write(r.stderr); sys.exit(r.returncode or 1)
m = re.fullmatch(rb'([0-9a-f]{64})  ' + re.escape(path) + rb'\n', r.stdout)
if not m:
    sys.stderr.write('sha256sum_raw_output_invalid\n'); sys.exit(1)
sys.stdout.buffer.write(m.group(1) + b'\n')
PY
}
source_env_guard() {
  local env_file="$1" before after rc
  before="$(raw_file_sha "$env_file")" || return 2
  . "$env_file" >> "$RUN_LOG" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || return 3
  after="$(raw_file_sha "$env_file")" || return 4
  [ "$before" = "$after" ] || return 5
  return 0
}
manifest_files "$DUT_ROOT" > "$RUN_DIR/source.sha.before" || emit_fail source_manifest_before
[ -s "$RUN_DIR/source.sha.before" ] || emit_fail source_manifest_empty
[ -r "$ENV_SH" ] || emit_fail env_sh_missing
source_env_guard "$ENV_SH"; ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || { [ "$ENV_RC" -eq 5 ] && emit_fail env_source_mutated; emit_fail "env_guard_rc=$ENV_RC"; }
manifest_files "$DUT_ROOT" > "$RUN_DIR/source.sha.after-env" || emit_fail source_manifest_after_env
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.after-env" || emit_fail env_source_mutated
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail iverilog_missing
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail vvp_missing
command -v sha256sum >/dev/null 2>&1 || emit_fail sha_missing

# ---- 固定 mandatory 子域 helper（正向）：<脚本>:<该 helper 唯一锚点>:<超时秒> ----
#   ★ 五个都必须存在并跑过；缺一 ⇒ 本包失败（不是 SKIP、不是 OPEN、更不打印 PASS）。
#   ★ 锚点按各 helper 自身约定（manifest 约定：FUNCTIONAL_<NAME>: PASS）。
HELPER_LIST=(
  "sim/functional/test_backend_permission.sh|FUNCTIONAL_BACKEND_PERMISSION: PASS|1200"
  "sim/functional/test_rob_window.sh|FUNCTIONAL_ROB_WINDOW: PASS|1200"
  "sim/functional/test_counter_time.sh|FUNCTIONAL_COUNTER_TIME: PASS|900"
  "sim/functional/test_data_control.sh|FUNCTIONAL_DATA_CONTROL: PASS|1800"
  "sim/functional/test_data_bus.sh|FUNCTIONAL_DATA_BUS: PASS|1800"
  # 第 6 个 mandatory（母 2026-10-22 指派；新 owner 发布后自动纳入；缺即 fail、不得 SKIP）
  "sim/functional/test_2a_control.sh|FUNCTIONAL_2A_CONTROL: PASS|1200"
)
HELPER_EXPECT=6                  # 固定 mandatory 数（母 2026-10-22 合同）
HDOM_TOTAL=""; HDOM_OK="-"; HDOM_BAD="-"
#   ★ 子域计数纪律：total **只能**来自固定 HELPER_LIST 的真实长度（并硬约束 ==6、
#     非空、无重复、每项 3 段），不得把成功数 OK 抄成 total；统计与 5-TB 分开。
helper_paths_ok() {   # 参数=各 helper rel 路径：非空、无重复
  local p seen=""
  [ "$#" -gt 0 ] || return 1
  for p in "$@"; do
    [ -n "$p" ] || return 1
    case " $seen " in *" $p "*) return 1 ;; esac
    seen="$seen $p"
  done
  return 0
}
validate_helper_list() {   # 输出精确原因；成功时返回 0
  local e rel n=${#HELPER_LIST[@]} rels=() fields
  [ "$n" -gt 0 ] || { echo "empty_list"; return 1; }
  [ "$n" -eq "$HELPER_EXPECT" ] || { echo "count=$n,want=$HELPER_EXPECT"; return 1; }
  for e in "${HELPER_LIST[@]}"; do
    fields=$(printf '%s' "$e" | awk -F'|' '{print NF}')
    [ "$fields" -eq 3 ] || { echo "fields=$fields,entry=$e"; return 1; }
    IFS='|' read -r rel _ _ <<<"$e"
    [ -n "$rel" ] || { echo "empty_rel"; return 1; }
    rels+=("$rel")
  done
  helper_paths_ok "${rels[@]}" || { echo "duplicate_rel"; return 1; }
  return 0
}
hd_aggregate_ok() {   # $1=total $2=ok $3=bad：total 非空且==6、ok==total、bad==0
  [ -n "$1" ] && [ "$1" = "$HELPER_EXPECT" ] && \
    [ "$2" -eq "$1" ] && [ "$3" -eq 0 ]
}
helper_list_err="$(validate_helper_list || true)"
[ -z "$helper_list_err" ] || emit_fail "helper_list:$helper_list_err"
HDOM_TOTAL=${#HELPER_LIST[@]}

# ---- 快照：完整依赖闭包（RTL + helper 脚本/TB + 环境 + 5 TB），不递归 build ----
SNAP="$RUN_DIR/src"
mkdir -p -- "$SNAP" || emit_fail snap_mkdir
copy_rel() { mkdir -p -- "$SNAP/$(dirname -- "$1")" && cp -p -- "$DUT_ROOT/$1" "$SNAP/$1"; }
copy_tree() {   # $1=相对目录（整棵复制；helper 的**冻结闭包**）
  local d="$1" f
  [ -d "$DUT_ROOT/$d" ] || emit_fail "snap_tree_missing_$d"
  while IFS= read -r f; do copy_rel "$f" || emit_fail "snap_copy_$f"; done \
    < <( cd -- "$DUT_ROOT" && find "$d" -type f | LC_ALL=C sort )
}
while IFS= read -r f; do copy_rel "$f" || emit_fail "snap_copy_$f"; done \
  < <( cd -- "$DUT_ROOT" && find rtl -type f \( -name '*.v' -o -name '*.vh' \) | LC_ALL=C sort )
#   helper 正向只从这些冻结目录/环境调用；DUT_ROOT 一律指本快照，不回落 live 树。
copy_rel scripts/env.sh
if [ "$NEG" -eq 1 ]; then
  for f in sim/functional/test_top_control.sh sim/functional/test_top_control_driver.sh \
    sim/functional/tb_top_control_semantics.sv sim/tb/sim_mem_model.sv; do
    [ -f "$DUT_ROOT/$f" ] || emit_fail "snap_dep_missing_$f"
    copy_rel "$f" || emit_fail "snap_copy_$f"
  done
else
  copy_tree sim/functional
  copy_tree sim/tb
  copy_tree sim/unit/prog
  for f in "${SIM_DEPS[@]}"; do [ -f "$DUT_ROOT/$f" ] || emit_fail "snap_dep_missing_$f"; copy_rel "$f" || emit_fail "snap_copy_$f"; done
  for e in "${TB_LIST[@]}"; do IFS='|' read -r tb top anchor tmo <<<"$e"; [ -f "$DUT_ROOT/$tb" ] || emit_fail "tb_missing_$tb"; copy_rel "$tb" || emit_fail "snap_copy_$tb"; done
fi
#   helper 的 PKGOUT 授权树必须在 $SNAP/build/functional 下（它们按自身 REPO_ROOT 校验）；
#   该子树**排除**在快照不可变清单之外（只收源码，不收产物）。
SNAP_BUILD="$SNAP/build/functional"
mkdir -p -- "$SNAP_BUILD" || emit_fail snap_build_mkdir

manifest() {
  python3 - "$SNAP" <<'PY'
import base64, os, re, subprocess, sys
root = os.fsencode(sys.argv[1])
paths = []
for here, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if not (os.path.relpath(os.path.join(here,d), root) == b'build')]
    for name in files:
        p = os.path.join(here, name)
        rel = os.path.relpath(p, root)
        if rel.startswith(b'build' + os.sep.encode()):
            continue
        paths.append(rel)
paths.sort()
for rel in paths:
    arg = b'./' + rel
    r = subprocess.run([b'sha256sum', b'--', arg], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.stderr.buffer.write(r.stderr); sys.exit(r.returncode or 1)
    m = re.fullmatch(rb'([0-9a-f]{64})  ' + re.escape(arg) + rb'\n', r.stdout)
    if not m:
        sys.stderr.write('sha256sum_raw_output_invalid\n'); sys.exit(1)
    sys.stdout.buffer.write(m.group(1) + b' ' + base64.b64encode(rel) + b'\n')
PY
}
manifest_files "$SNAP" > "$RUN_DIR/source.sha.copy" || emit_fail source_manifest_copy
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.copy" || emit_fail source_copy_mismatch
manifest > "$RUN_DIR/inputs.sha.before" || emit_fail manifest_before
[ -s "$RUN_DIR/inputs.sha.before" ] || emit_fail manifest_empty

mapfile -d '' -t RTL_FILES < <(cd -- "$SNAP" && find rtl -name '*.v' -print0)

# ---- 在快照内编译：cwd=SNAP、相对 -I；输出 vvp 用绝对路径 ----
compile_one() {   # $1=top $2=tb(可空) $3=out
  local top="$1" tb="$2" out="$3" log
  log="$RUN_DIR/compile.$top.log"
  local -a tb_args=()
  [ -n "$tb" ] && tb_args+=("$tb")
  ( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-600}" "$IV" -g2012 -I rtl/pkg -I . \
      -s "$top" -o "$out" "${RTL_FILES[@]}" "${tb_args[@]}" ) > "$log" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || { echo "COMPILE_FAIL $top rc=$rc" >> "$RUN_LOG"; cat "$log" >> "$RUN_LOG"; return 1; }
  [ -s "$out" ] || { echo "COMPILE_ZERO $top" >> "$RUN_LOG"; return 1; }
  return 0
}

# ---- 跑一个 TB：唯一锚点 + 无 FAIL/XZ + rc=0 + 非空 ----
run_tb() {   # $1=tb $2=anchor $3=timeout
  local tb="$1" anchor="$2" tmo="$3" log rc n_pass n_bad sz
  log="$RUN_DIR/$(basename -- "$tb" .sv).log"
  timeout "$tmo" "$VV" "$RUN_DIR/$(basename -- "$tb" .sv).vvp" > "$log" 2>&1; rc=$?
  [ "$rc" -eq 124 ] && { echo "RUN_TIMEOUT $tb" >> "$RUN_LOG"; return 124; }
  [ "$rc" -ne 0 ] && { echo "RUN_RC $tb rc=$rc" >> "$RUN_LOG"; cat "$log" >> "$RUN_LOG"; return "$rc"; }
  sz=$(stat -c %s -- "$log" 2>/dev/null || echo 0); [ "$sz" -gt 0 ] || { echo "RUN_EMPTY $tb" >> "$RUN_LOG"; return 1; }
  n_pass=$(grep -cxF "$anchor" "$log" || true)
  [ "$n_pass" = "1" ] || { echo "ANCHOR_COUNT $tb=$n_pass" >> "$RUN_LOG"; grep -E "$anchor|FAIL" "$log" >> "$RUN_LOG" || true; return 1; }
  n_bad=$(grep -cE 'FAIL|DEFECT_REPRODUCED|(^|[^A-Za-z])XZ|UNKNOWN' "$log" || true)
  [ "$n_bad" = "0" ] || { echo "BAD_TOKENS $tb=$n_bad" >> "$RUN_LOG"; return 1; }
  cat -- "$log" >> "$RUN_LOG"
  printf 'TB %s anchor=%s ok\n' "$tb" "$anchor" >> "$RUN_LOG"
  return 0
}

pkgo_isolated() {   # helper 的 PKGOUT 必须落在**快照授权 build 树**内（与父 RUN_DIR 产物分开）
  case "$1" in
    "$SNAP_BUILD"/*) return 0 ;;
    *) return 1 ;;
  esac
}
judge_log() {       # $1=日志 $2=该 helper 唯一锚点；非空 + 锚点恰 1 + 无 FAIL/DEFECT
  local log="$1" anchor="$2" sz npass nbad
  [ -f "$log" ] || return 1
  sz=$(stat -c %s -- "$log" 2>/dev/null || echo 0)
  [ "$sz" -gt 0 ] || return 1
  npass=$(grep -cxF "$anchor" "$log" || true)
  [ "$npass" = "1" ] || return 1
  nbad=$(grep -cE 'FAIL|DEFECT_REPRODUCED' "$log" || true)
  [ "$nbad" = "0" ] || return 1
  return 0
}
judge_semantic_capture() {
  local log="$1" np nb sz
  [ -f "$log" ] || return 1
  sz=$(stat -c %s -- "$log" 2>/dev/null || echo 0); [ "$sz" -gt 0 ] || return 1
  np=$(grep -cxF 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS' "$log" || true)
  [ "$np" = "1" ] || return 1
  nb=$(grep -cE 'FAIL|DEFECT_REPRODUCED|(^|[^A-Za-z])XZ|UNKNOWN' "$log" || true)
  [ "$nb" = "0" ]
}
run_helper() {      # $1=快照内脚本相对路径 $2=锚点 $3=超时秒
  local rel="$1" anchor="$2" tmo="$3" name out log rc sz npass nbad
  name="$(basename -- "$rel" .sh)"
  #   缺文件 = 缺例 ⇒ 直接失败（绝不 SKIP/PASS）
  [ -f "$SNAP/$rel" ] || { echo "SUBDOMAIN_MISSING $rel" >> "$RUN_LOG"; return 1; }
  #   每 helper 独立 mktemp PKGOUT（在快照的授权 build 树内；与父 RUN_DIR 隔离）
  out="$(mktemp -d -- "$SNAP_BUILD/$name-XXXXXXXX")" || { echo "SUBDOMAIN_MKTEMP $name" >> "$RUN_LOG"; return 1; }
  pkgo_isolated "$out" || { echo "SUBDOMAIN_PKGOUT_OVERLAP $name out=$out" >> "$RUN_LOG"; return 1; }
  log="$out/parent-capture.log"
  ( cd -- "$SNAP" && DUT_ROOT="$SNAP" RV32_FUNCTIONAL_PKG_OUT_DIR="$out" \
      timeout "$tmo" bash "$SNAP/$rel" ) > "$log" 2>&1
  rc=$?
  [ "$rc" -eq 124 ] && { echo "SUBDOMAIN_TIMEOUT $name tmo=$tmo" >> "$RUN_LOG"; return 124; }
  [ "$rc" -ne 0 ] && { echo "SUBDOMAIN_RC $name rc=$rc" >> "$RUN_LOG"; tail -30 "$log" >> "$RUN_LOG"; return "$rc"; }
  sz=$(stat -c %s -- "$log" 2>/dev/null || echo 0)
  [ "$sz" -gt 0 ] || { echo "SUBDOMAIN_EMPTY $name" >> "$RUN_LOG"; return 1; }
  npass=$(grep -cxF "$anchor" "$log" || true)
  [ "$npass" = "1" ] || { echo "SUBDOMAIN_ANCHOR $name=$npass" >> "$RUN_LOG"; grep -E 'PASS|FAIL|DEFECT' "$log" >> "$RUN_LOG" || true; return 1; }
  nbad=$(grep -cE 'FAIL|DEFECT_REPRODUCED' "$log" || true)
  [ "$nbad" = "0" ] || { echo "SUBDOMAIN_BADTOK $name=$nbad" >> "$RUN_LOG"; return 1; }
  cat -- "$log" >> "$RUN_LOG"
  printf 'SUBDOMAIN %s anchor=%s out=%s ok\n' "$rel" "$anchor" "$out" >> "$RUN_LOG"
  return 0
}
if [ "$NEG" -eq 0 ]; then
  # ---- 子域 helper 判据（元函数；spec 与 --self-test 共用，便于 fixture 反证）----

# ---- 正控：两 top elaboration + 5 TB 真跑 ----
  if ! compile_one core_top "" "$RUN_DIR/core_top.vvp"; then emit_fail compile_core_top; fi
  if ! compile_one core_top_2b "" "$RUN_DIR/core_top_2b.vvp"; then emit_fail compile_core_top_2b; fi
  SUM_OK=0; SUM_BAD=0
  for e in "${TB_LIST[@]}"; do
    IFS='|' read -r tb top anchor tmo <<<"$e"
    vvp="$RUN_DIR/$(basename -- "$tb" .sv).vvp"
    if compile_one "$top" "$tb" "$vvp" && run_tb "$tb" "$anchor" "$tmo"; then
      SUM_OK=$((SUM_OK+1))
    else
      SUM_BAD=$((SUM_BAD+1))
    fi
  done
  [ "$SUM_BAD" -eq 0 ] || emit_fail "bad_tests=$SUM_BAD"
  [ "$SUM_OK" -eq "${#TB_LIST[@]}" ] || emit_fail "ok_tests=$SUM_OK"
  # ---- F1-B 顶层 Zicntr/mtime/MPP 语义包（独立驱动；程序汇编 + 两 top 真跑）----
  #   父判据：驱动 rc=0 且其唯一成功锚点恰好 1 次；失败原因不吞（计入本包 FAIL）。
  SEM_LOG="$RUN_DIR/top_control_semantics.log"
  SEM_RC=0
  env -u RV32_TC_RTL_ROOT RV32_TC_DUT_ROOT="$SNAP" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$SNAP_BUILD/top-control-semantics" \
    timeout "${TIMEOUT_SEMANTICS_S:-1800}" bash "$SNAP/sim/functional/test_top_control_driver.sh" \
    > "$SEM_LOG" 2>&1 || SEM_RC=$?
  cat -- "$SEM_LOG" >> "$RUN_LOG"
  [ "$SEM_RC" -eq 0 ] || emit_fail "semantics_driver_rc=$SEM_RC"
  grep -Fqx "TOP_CONTROL_DUT_ROOT=$SNAP" "$SEM_LOG" || emit_fail semantics_driver_root
  judge_semantic_capture "$SEM_LOG" || emit_fail semantics_driver_capture
  # ---- 固定 mandatory 子域 helper 正向（冻结闭包 + 独立 PKGOUT；任一不满足即失败）----
  HDOM_OK=0; HDOM_BAD=0
  for e in "${HELPER_LIST[@]}"; do
    IFS='|' read -r hrel hanchor htmo <<<"$e"
    if run_helper "$hrel" "$hanchor" "$htmo"; then
      HDOM_OK=$((HDOM_OK+1))
    else
      HDOM_BAD=$((HDOM_BAD+1))
    fi
  done
  [ -n "$HDOM_TOTAL" ] || emit_fail subdomain_total_empty
  [ "$HDOM_TOTAL" -eq "$HELPER_EXPECT" ] || emit_fail "subdomain_total=$HDOM_TOTAL,want=$HELPER_EXPECT"
  [ "$HDOM_BAD" -eq 0 ] || emit_fail "subdomain_bad=$HDOM_BAD"
  [ "$HDOM_OK" -eq "$HDOM_TOTAL" ] || emit_fail "subdomain_ok=$HDOM_OK,total=$HDOM_TOTAL"
  hd_aggregate_ok "$HDOM_TOTAL" "$HDOM_OK" "$HDOM_BAD" || emit_fail subdomain_aggregate
  # ---- 快照未变：编译/真跑全部结束后再取 after（正控的不可变证据）----
  manifest_files "$DUT_ROOT" > "$RUN_DIR/source.sha.after" || emit_fail source_manifest_after
  cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.after" || emit_fail source_mutated
  manifest_files "$SNAP" > "$RUN_DIR/source.sha.snap-after" || emit_fail source_manifest_snap_after
  cmp -s "$RUN_DIR/source.sha.copy" "$RUN_DIR/source.sha.snap-after" || emit_fail snapshot_inputs_mutated
  manifest > "$RUN_DIR/inputs.sha.after" || emit_fail manifest_after
  cmp -s "$RUN_DIR/inputs.sha.before" "$RUN_DIR/inputs.sha.after" || emit_fail snapshot_mutated
  printf 'TOP_CONTROL_TESTS total=%s ok=%s bad=%s\n' "${#TB_LIST[@]}" "$SUM_OK" "$SUM_BAD" >> "$RUN_LOG"
  printf 'TOP_CONTROL_SUBDOMAINS total=%s ok=%s bad=%s\n' "$HDOM_TOTAL" "$HDOM_OK" "$HDOM_BAD" >> "$RUN_LOG"
  printf 'FUNCTIONAL_TOP_CONTROL: PASS\n' >> "$RUN_LOG"
  [ "$(grep -cxF 'FUNCTIONAL_TOP_CONTROL: PASS' "$RUN_LOG" || true)" = "1" ] || emit_fail anchor_count
  [ "$(grep -c 'FAIL' "$RUN_LOG" || true)" = "0" ] || emit_fail log_fail
  printf 'TOP_CONTROL_TESTS total=%s ok=%s bad=%s\n' "${#TB_LIST[@]}" "$SUM_OK" "$SUM_BAD"
  printf 'TOP_CONTROL_SUBDOMAINS total=%s ok=%s bad=%s\n' "$HDOM_TOTAL" "$HDOM_OK" "$HDOM_BAD"
  printf 'FUNCTIONAL_TOP_CONTROL: PASS\n'
  exit 0
fi

# ---- 反证模式：只验本脚本的 fail-closed 判据（不重跑正控）----
#   ★ 语义驱动自带 `--self-test`（锚点/rc/超时/坏 token/快照缺头五类反证），
#     在此一并复验；它只打印 NEGATIVE 锚点，绝不打印默认 PASS。
SELF_LOG="$RUN_DIR/top_control_semantics_selftest.log"
SELF_RC=0
env -u RV32_TC_RTL_ROOT RV32_TC_DUT_ROOT="$SNAP" \
  RV32_FUNCTIONAL_PKG_OUT_DIR="$SNAP_BUILD/top-control-semantics-neg" \
  timeout "${TIMEOUT_SEMANTICS_S:-900}" bash "$SNAP/sim/functional/test_top_control_driver.sh" --self-test \
  > "$SELF_LOG" 2>&1 || SELF_RC=$?
cat -- "$SELF_LOG" >> "$RUN_LOG"
[ "$SELF_RC" -eq 0 ] || emit_fail "semantics_selftest_rc=$SELF_RC"
grep -Fqx "TOP_CONTROL_DUT_ROOT=$SNAP" "$SELF_LOG" || emit_fail semantics_selftest_root
[ "$(grep -cxF 'FUNCTIONAL_TOP_CONTROL_SEMANTICS_NEGATIVE: PASS' "$SELF_LOG" || true)" = "1" ] \
  || emit_fail semantics_selftest_anchor
CP_OK=0; CP_N=0
FX="$RUN_DIR/fixtures"; mkdir -p -- "$FX"
# 真实 source_env_guard：确认rc0普通ENV放行、自修改ENV于源阶段按准确返回码拒绝。
cat > "$FX/env-stable.sh" <<'SH'
: # stable env fixture
SH
CP_N=$((CP_N+1)); if source_env_guard "$FX/env-stable.sh"; then CP_OK=$((CP_OK+1)); echo 'CP env_guard_stable pass' >> "$RUN_LOG"; else echo 'CP env_guard_stable REJECTED' >> "$RUN_LOG"; fi
cat > "$FX/env-self-append.sh" <<'SH'
printf '# appended\\n' >> "${BASH_SOURCE[0]}"
SH
CP_N=$((CP_N+1)); ENV_GUARD_RC=0; source_env_guard "$FX/env-self-append.sh" || ENV_GUARD_RC=$?
if [ "$ENV_GUARD_RC" -eq 5 ]; then CP_OK=$((CP_OK+1)); echo 'CP env_self_append_rc0 exact-source-reject pass' >> "$RUN_LOG"; else echo "CP env_self_append_rc0 wrong_rc=$ENV_GUARD_RC REJECTED" >> "$RUN_LOG"; fi
check_reject() {   # $1=name $2=cmd
  CP_N=$((CP_N+1))
  if eval "$2"; then echo "CP $1 got=accept want=reject REJECTED" >> "$RUN_LOG"
  else CP_OK=$((CP_OK+1)); echo "CP $1 got=reject want=reject pass" >> "$RUN_LOG"; fi
}
# 唯一锚点判据的 3 个反证（直接复用测试用 grep 语义）
printf 'no anchor here\n' > "$FX/noanchor.log"
check_reject noanchor "[ \"\$(grep -cxF 'TB_X: PASS' '$FX/noanchor.log' || true)\" = 1 ]"
printf 'TB_X: PASS\nTB_X: PASS\n' > "$FX/dupanchor.log"
check_reject dupanchor "[ \"\$(grep -cxF 'TB_X: PASS' '$FX/dupanchor.log' || true)\" = 1 ]"
printf 'stats rows=3\nFUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS\n' > "$FX/semantic-valid.log"
CP_N=$((CP_N+1)); if judge_semantic_capture "$FX/semantic-valid.log"; then CP_OK=$((CP_OK+1)); echo 'CP parent_semantic_positive pass' >> "$RUN_LOG"; else echo 'CP parent_semantic_positive REJECTED' >> "$RUN_LOG"; fi
printf 'stats rows=3\nFUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS\nDEFECT_REPRODUCED\n' > "$FX/semantic-defect.log"
check_reject parent_semantic_defect "judge_semantic_capture '$FX/semantic-defect.log'"
printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS\nXZ invalid\n' > "$FX/semantic-xz.log"
check_reject parent_semantic_xz "judge_semantic_capture '$FX/semantic-xz.log'"
printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS\nUNKNOWN opcode\n' > "$FX/semantic-unknown.log"
check_reject parent_semantic_unknown "judge_semantic_capture '$FX/semantic-unknown.log'"
printf 'TB_X: PASS\nFAIL: boom\n' > "$FX/failtok.log"
check_reject failtok "[ \"\$(grep -cE 'FAIL|[^A-Za-z]XZ|UNKNOWN' '$FX/failtok.log' || true)\" = 0 ]"
# 非零 rc / 超时 反证：假 vvp
FB="$RUN_DIR/fakebin"; mkdir -p -- "$FB"
printf '#!/bin/sh\nexit 3\n' > "$FB/vvp_rc"; chmod +x "$FB/vvp_rc"
printf '#!/bin/sh\nsleep 5\n' > "$FB/vvp_sleep"; chmod +x "$FB/vvp_sleep"
printf 'x\n' > "$FX/dummy.log"
check_reject nonzero_rc "[ \"\$(timeout 2 '$FB/vvp_rc' >'$FX/dummy.log' 2>&1; echo \$?)\" = 0 ]"
check_reject timeout_rc "[ \"\$(timeout 1 '$FB/vvp_sleep' >'$FX/dummy.log' 2>&1; echo \$?)\" != 124 ]"
# 闭包：缺头快照必须被拒（用正控快照删一个头到私有 fixture，不改正式源）
FIXMISS="$RUN_DIR/fix-miss"; cp -a "$SNAP" "$FIXMISS"
rm -f "$FIXMISS/rtl/pkg/rv32_defs.vh"
check_reject snapshot_missing_header "[ -f '$FIXMISS/rtl/pkg/rv32_defs.vh' ]"
# 正式compile_one/run_tb caller配真/假产物和各失败阶段（使用私有fake工具）。
check_exact_caller_reject() { CP_N=$((CP_N+1)); if eval "$2"; then echo "CP $1 got=accept REJECTED" >> "$RUN_LOG"; else local rc=$?; if [ "$rc" -eq 1 ]; then CP_OK=$((CP_OK+1)); echo "CP $1 exact-reason pass" >> "$RUN_LOG"; else echo "CP $1 wrong-reason rc=$rc REJECTED" >> "$RUN_LOG"; fi; fi; }
run_tb_expect() { local mode="$1" reason="$2" rc=0; FAKE_VVP_MODE="$mode" run_tb fixture.sv 'TB_FIX: PASS' 1 || rc=$?; [ "$rc" -eq 0 ] && return 0; grep -Fqx "$reason" "$RUN_LOG" && return 1; return 2; }
check_caller_accept() { CP_N=$((CP_N+1)); if eval "$2"; then CP_OK=$((CP_OK+1)); echo "CP $1 pass" >> "$RUN_LOG"; else echo "CP $1 REJECTED" >> "$RUN_LOG"; fi; }
cat > "$FB/fake-vvp" <<'SH'
#!/usr/bin/env bash
case "${FAKE_VVP_MODE:-ok}" in
  ok) printf 'statistics: n=4\nTB_FIX: PASS\n' ;;
  missing) printf 'statistics: n=4\n' ;;
  duplicate) printf 'TB_FIX: PASS\nTB_FIX: PASS\n' ;;
  defect) printf 'TB_FIX: PASS\nDEFECT_REPRODUCED\n' ;;
  fail) printf 'TB_FIX: PASS\nFAIL: fixture\n' ;;
  xz) printf 'TB_FIX: PASS\nXZ invalid\n' ;;
  unknown) printf 'TB_FIX: PASS\nUNKNOWN opcode\n' ;;
  empty) : ;;
  rc9) printf 'TB_FIX: PASS\n'; exit 9 ;;
  timeout) sleep 3 ;;
esac
SH
chmod +x "$FB/fake-vvp"; VV="$FB/fake-vvp"; : > "$RUN_DIR/fixture.vvp"
check_caller_accept actual_run_tb_multiline "run_tb_expect ok ignored"
check_exact_caller_reject actual_run_tb_missing_anchor "run_tb_expect missing 'ANCHOR_COUNT fixture.sv=0'"
check_exact_caller_reject actual_run_tb_duplicate_anchor "run_tb_expect duplicate 'ANCHOR_COUNT fixture.sv=2'"
check_exact_caller_reject actual_run_tb_defect "run_tb_expect defect 'BAD_TOKENS fixture.sv=1'"
check_exact_caller_reject actual_run_tb_FAIL "run_tb_expect fail 'BAD_TOKENS fixture.sv=1'"
check_exact_caller_reject actual_run_tb_XZ "run_tb_expect xz 'BAD_TOKENS fixture.sv=1'"
check_exact_caller_reject actual_run_tb_UNKNOWN "run_tb_expect unknown 'BAD_TOKENS fixture.sv=1'"
check_exact_caller_reject actual_run_tb_empty "run_tb_expect empty 'RUN_EMPTY fixture.sv'"
check_exact_caller_reject actual_run_tb_rc9 "run_tb_expect rc9 'RUN_RC fixture.sv rc=9'"
check_exact_caller_reject actual_run_tb_timeout "run_tb_expect timeout 'RUN_TIMEOUT fixture.sv'"
# 两top真实elaboration，确保空TB参数不会以空文件名传入真实/fake IV。
compile_one core_top '' "$RUN_DIR/self-elab-core_top.vvp" || emit_fail self_elab_core_top
compile_one core_top_2b '' "$RUN_DIR/self-elab-core_top_2b.vvp" || emit_fail self_elab_core_top_2b
printf 'TOP_CONTROL_REAL_ELAB core_top=ok core_top_2b=ok\n' >> "$RUN_LOG"
cat > "$FB/fake-iverilog" <<'SH'
#!/usr/bin/env bash
out=''
for arg in "$@"; do [ -n "$arg" ] || { echo EMPTY_SOURCE_ARG; exit 9; }; done
while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; out="$1"; fi; shift; done
case "${FAKE_IV_MODE:-good}" in
  good) printf 'VVP\n' > "$out" ;;
  zero) : ;;
  rc9) printf 'compile failure\n' >&2; exit 9 ;;
esac
SH
chmod +x "$FB/fake-iverilog"; IV="$FB/fake-iverilog"
compile_one_expect() { local mode="$1" top="$2" out="$3" reason="$4" rc=0; FAKE_IV_MODE="$mode" compile_one "$top" '' "$out" || rc=$?; [ "$rc" -eq 0 ] && return 0; grep -Fqx "$reason" "$RUN_LOG" && return 1; return 2; }
check_caller_accept actual_compile_one_nonempty "compile_one_expect good fixture '$RUN_DIR/compile-good.vvp' ignored"
check_exact_caller_reject actual_compile_one_zero "compile_one_expect zero fixture '$RUN_DIR/compile-zero.vvp' 'COMPILE_ZERO fixture'"
check_exact_caller_reject actual_compile_one_rc9 "compile_one_expect rc9 fixture '$RUN_DIR/compile-rc9.vvp' 'COMPILE_FAIL fixture rc=9'"
# 5 mandatory helper 由正式 run_helper caller 经私有替身逐阶段反证 ----
#   替身只验证 caller 判据，不宣称任何真实 mandatory helper 的功能通过。
FAKE_HELPER_REL=build/functional/selftest_top_control_helper.sh
cat > "$SNAP/$FAKE_HELPER_REL" <<'SH'
#!/usr/bin/env bash
case "${SELFTEST_HELPER_MODE:-ok}" in
  ok) printf 'statistics: rows=3\nFUNCTIONAL_DATA_BUS: PASS\n' ;;
  defect) printf 'FUNCTIONAL_DATA_BUS: PASS\nDEFECT_REPRODUCED\n' ;;
  wrong) printf 'FUNCTIONAL_OTHER: PASS\n' ;;
  duplicate) printf 'FUNCTIONAL_DATA_BUS: PASS\nFUNCTIONAL_DATA_BUS: PASS\n' ;;
  empty) : ;;
  rc) printf 'statistics: rows=1\nFUNCTIONAL_DATA_BUS: PASS\n'; exit 9 ;;
  timeout) sleep 3 ;;
esac
SH
run_fake_helper() { SELFTEST_HELPER_MODE="$1" run_helper "$FAKE_HELPER_REL" 'FUNCTIONAL_DATA_BUS: PASS' "$2"; }
run_fake_helper_reject() {
  local mode="$1" tmo="$2" reason="$3"
  run_fake_helper "$mode" "$tmo" && return 0
  grep -Fqx "$reason" "$RUN_LOG" && return 1
  return 2
}
check_exact_reject() {
  CP_N=$((CP_N+1))
  if eval "$2"; then echo "CP $1 got=accept want=reject REJECTED" >> "$RUN_LOG"
  else local rc=$?; if [ "$rc" -eq 1 ]; then CP_OK=$((CP_OK+1)); echo "CP $1 got=reject reason=exact pass" >> "$RUN_LOG";
       else echo "CP $1 got=reject reason=wrong rc=$rc REJECTED" >> "$RUN_LOG"; fi; fi
}
check_accept() {   # $1=name $2=cmd
  CP_N=$((CP_N+1))
  if eval "$2"; then CP_OK=$((CP_OK+1)); echo "CP $1 got=accept want=accept pass" >> "$RUN_LOG"
  else echo "CP $1 got=reject want=accept REJECTED" >> "$RUN_LOG"; fi
}
# 正式manifest调用的raw-SHA协议反证：真实unicode/空格路径 + fake sha256sum坏响应。
SHA_DIR="$RUN_DIR/fake-sha"; mkdir -p -- "$SHA_DIR" "$FX/unicode 空格"
printf 'input\n' > "$FX/unicode 空格/Δ源 file"
SOURCE_FILES_SAVED=("${SOURCE_FILES[@]}")
SOURCE_FILES=("unicode 空格/Δ源 file")
cat > "$SHA_DIR/sha256sum" <<'SH'
#!/usr/bin/env bash
case "${FAKE_SHA_MODE:-valid}" in
  valid) printf '%064d  %s\n' 0 "$2" ;;
  rc9) exit 9 ;;
  wrong_path) printf '%064d  wrong\n' 0 ;;
  missing_lf) printf '%064d  %s' 0 "$2" ;;
  nul) printf '%064d  %s\0\n' 0 "$2" ;;
  extra_lf) printf '%064d  %s\n\n' 0 "$2" ;;
  trailing) printf '%064d  %s junk\n' 0 "$2" ;;
esac
SH
chmod +x "$SHA_DIR/sha256sum"
sha_fake_case() { local mode="$1" expect="$2" rc=0; FAKE_SHA_MODE="$mode" PATH="$SHA_DIR:$PATH" manifest_files "$FX" > "$FX/sha.out" 2> "$FX/sha.err" || rc=$?; [ "$rc" -eq "$expect" ] || return 0; [ "$expect" -eq 0 ] && return 0; return 1; }
check_accept rawsha_unicode_space_path "sha_fake_case valid 0 && [ -s '$FX/sha.out' ]"
check_reject rawsha_rc9 "sha_fake_case rc9 9"
check_reject rawsha_wrong_path "sha_fake_case wrong_path 1"
check_reject rawsha_missing_lf "sha_fake_case missing_lf 1"
check_reject rawsha_nul "sha_fake_case nul 1"
check_reject rawsha_extra_lf "sha_fake_case extra_lf 1"
check_reject rawsha_trailing "sha_fake_case trailing 1"
SOURCE_FILES=("${SOURCE_FILES_SAVED[@]}")
# 通过实际 run_helper -> frozen caller 命令、超时与judge_log；全是假helper。
check_accept actual_helper_multiline_positive "run_fake_helper ok 4"
check_exact_reject actual_helper_defect_token "run_fake_helper_reject defect 4 'SUBDOMAIN_BADTOK selftest_top_control_helper=1'"
check_exact_reject actual_helper_wrong_anchor "run_fake_helper_reject wrong 4 'SUBDOMAIN_ANCHOR selftest_top_control_helper=0'"
check_exact_reject actual_helper_duplicate_anchor "run_fake_helper_reject duplicate 4 'SUBDOMAIN_ANCHOR selftest_top_control_helper=2'"
check_exact_reject actual_helper_empty_output "run_fake_helper_reject empty 4 'SUBDOMAIN_EMPTY selftest_top_control_helper'"
check_exact_reject actual_helper_rc9 "run_fake_helper_reject rc 4 'SUBDOMAIN_RC selftest_top_control_helper rc=9'"
check_exact_reject actual_helper_timeout "run_fake_helper_reject timeout 1 'SUBDOMAIN_TIMEOUT selftest_top_control_helper tmo=1'"
HB="$RUN_DIR/hb"; mkdir -p -- "$HB"
printf 'FUNCTIONAL_OTHER: PASS\n' > "$HB/fakeanchor.log"
check_reject subdomain_fake_anchor "judge_log '$HB/fakeanchor.log' 'FUNCTIONAL_DATA_BUS: PASS'"
printf 'FUNCTIONAL_DATA_BUS: PASS\nDEFECT_REPRODUCED\n' > "$HB/defect.log"
check_reject subdomain_defect "judge_log '$HB/defect.log' 'FUNCTIONAL_DATA_BUS: PASS'"
printf 'FUNCTIONAL_DATA_BUS: PASS\nFUNCTIONAL_DATA_BUS: PASS\n' > "$HB/dup.log"
check_reject subdomain_dupanchor "judge_log '$HB/dup.log' 'FUNCTIONAL_DATA_BUS: PASS'"
: > "$HB/empty.log"
check_reject subdomain_empty "judge_log '$HB/empty.log' 'FUNCTIONAL_DATA_BUS: PASS'"
printf 'FUNCTIONAL_DATA_BUS: PASS\n' > "$HB/ok.log"
check_accept subdomain_ok_positive "judge_log '$HB/ok.log' 'FUNCTIONAL_DATA_BUS: PASS'"
#   父 PKGOUT 隔离：落在 RUN_DIR 内必须被拒、之外必须接受
check_reject pkgoout_overlap "pkgo_isolated '$RUN_DIR/inner'"
mkdir -p -- "$SNAP_BUILD/iso-probe"
check_accept pkgoout_outside "pkgo_isolated '$SNAP_BUILD/iso-probe'"
#   缺必需子域：清单里任一 helper 文件不存在 ⇒ preflight 必须拒绝
check_reject subdomain_missing "[ -f '$SNAP/sim/functional/test_backend_permission.sh' ] && [ -f '$SNAP/sim/functional/test___missing_2a_control__.sh' ]"
# ---- 子域聚合计数反证（total **只能**来自固定 HELPER_LIST 长度，不得用 OK 冒充）----
check_accept subdomain_agg_6ok    "hd_aggregate_ok 6 6 0"
check_reject subdomain_agg_zero   "hd_aggregate_ok '' 0 0"
check_reject subdomain_agg_short  "hd_aggregate_ok 6 5 0"
check_reject subdomain_agg_bad    "hd_aggregate_ok 6 6 1"
check_reject subdomain_agg_total5 "hd_aggregate_ok 5 5 0"
check_accept helper_list_real     "validate_helper_list"
check_accept helper_paths6        "helper_paths_ok sim/functional/test_backend_permission.sh sim/functional/test_rob_window.sh sim/functional/test_counter_time.sh sim/functional/test_data_control.sh sim/functional/test_data_bus.sh sim/functional/test_2a_control.sh"
check_reject helper_paths_dup     "helper_paths_ok a b a d e f"
check_reject helper_paths_empty   "helper_paths_ok a b '' d e f"
check_reject helper_paths_none    "helper_paths_ok"
# 六个mandatory各自缺失：让正式run_helper逐个拒绝真实清单相对路径。
SNAP_SAVED="$SNAP"; SNAP_BUILD_SAVED="$SNAP_BUILD"
SNAP="$FX/empty-snap"; SNAP_BUILD="$SNAP/build/functional"; mkdir -p "$SNAP"
for e in "${HELPER_LIST[@]}"; do
  IFS='|' read -r hrel hanchor htmo <<<"$e"
  CP_N=$((CP_N+1)); run_helper "$hrel" "$hanchor" "$htmo" && { echo "CP missing_$hrel got=accept REJECTED" >> "$RUN_LOG"; continue; }
  if grep -Fqx "SUBDOMAIN_MISSING $hrel" "$RUN_LOG"; then CP_OK=$((CP_OK+1)); echo "CP missing_$hrel exact-reason pass" >> "$RUN_LOG";
  else echo "CP missing_$hrel wrong-reason REJECTED" >> "$RUN_LOG"; fi
done
SNAP="$SNAP_SAVED"; SNAP_BUILD="$SNAP_BUILD_SAVED"

[ "$CP_OK" -eq "$CP_N" ] || emit_fail "counterproof=$CP_OK/$CP_N"
# ---- 反证模式也验全部输入源/快照未变（fixtures 仅落入授权 build 子树）----
manifest_files "$DUT_ROOT" > "$RUN_DIR/source.sha.after" || emit_fail source_manifest_after
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.after" || emit_fail source_mutated
manifest_files "$SNAP" > "$RUN_DIR/source.sha.snap-after" || emit_fail source_manifest_snap_after
cmp -s "$RUN_DIR/source.sha.copy" "$RUN_DIR/source.sha.snap-after" || emit_fail snapshot_inputs_mutated
manifest > "$RUN_DIR/inputs.sha.after" || emit_fail manifest_after
cmp -s "$RUN_DIR/inputs.sha.before" "$RUN_DIR/inputs.sha.after" || emit_fail snapshot_mutated
printf 'TOP_CONTROL_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N" >> "$RUN_LOG"
printf 'FUNCTIONAL_TOP_CONTROL_NEGATIVE: PASS\n' >> "$RUN_LOG"
[ "$(grep -cxF 'FUNCTIONAL_TOP_CONTROL: PASS' "$RUN_LOG" || true)" = "0" ] || emit_fail default_anchor_in_neg
printf 'TOP_CONTROL_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N"
printf 'FUNCTIONAL_TOP_CONTROL_NEGATIVE: PASS\n'
exit 0
