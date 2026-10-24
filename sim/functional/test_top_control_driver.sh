#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_top_control_driver.sh —— 顶层 Zicntr/mtime/MPP 语义驱动
#==============================================================================
# 归属 : F4-0/F1-B 顶层接线验收（两 top 的计数器本体 + CSR 视图 + 时间源）
# 用法 : bash sim/functional/test_top_control_driver.sh
#        bash sim/functional/test_top_control_driver.sh --self-test   # 只验判据
#
# 做什么（全部 fail-closed）:
#   1) 私有**不可变快照**：rtl/**/*.{v,vh} + sim/tb/sim_mem_model.sv +
#      sim/functional/tb_top_control_semantics.sv（不递归 build/，不复制程序）；
#      快照前后各记一次全量 SHA256 清单，必须逐字节相同。
#   2) 在本 run 目录内**用真实工具链汇编**最小 RV32 程序（源码 inline 于本脚本）：
#        · 2A 变体链接 @0x1C00_0000（复位 XIP 取指）；
#        · 2B 变体链接 @0x8000_0000（该核 a[31:20]==0x800 映射到 0x0000_xxxx）。
#      结果通道按 DUT 分路（详见 TB 头）：
#        · 2A：按字节写 UART（0x1FE0_01E0，非缓存路径）⇒ 不依赖 D-cache 写回；
#        · 2B：写 DDR 邮箱字（0x8000_2000 起）+ cbo.flush 写回 ⇒ TB 读存储模型。
#          （2B 的 uncached 强副作用 store 重放/竞态未闭环，字节流会被重复字节打乱；
#            邮箱字写幂等。）
#   3) 在快照 root 内（cwd=SNAP、相对 -I）编译 `tb_top_control_semantics`，
#      程序 hex 的绝对路径用 -P 参数注入（不改 TB 源）。
#   4) 真跑两次（2A / 2B），各自：rc=0、日志非空、唯一整行锚点
#      `TB_TOP_CONTROL_SEMANTICS: PASS` 恰好 1 次、无 FAIL/XZ/UNKNOWN。
#   5) 汇总 `TOP_CONTROL_SEMANTICS runs=2 ok=2` 与唯一整行
#      `FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS`。
#
# 环境钩子（只读 A/B；不改产品代码）:
#   RV32_TC_DUT_ROOT=<完整一致的另一棵源根> 用该树的 RTL/TB/MEM/env 同源复跑；
#   RV32_TC_RTL_ROOT 仅作旧变量别名，也会统一切换全部源/辅助输入，禁止混树。
#   RV32_FUNCTIONAL_PKG_OUT_DIR=<产物父目录>（须在 build/functional 下）
#
# 产物：`build/functional/top-control-semantics/run-XXXXXXXX/`（每次 mktemp，
#       不删除、不覆盖；本脚本不做任何 rm）。
#==============================================================================
set -u

MODE="spec"
if [ "$#" -gt 1 ]; then printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: FAIL reason=unknown_arg\n'; exit 1; fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test) MODE="self-test" ;;
        *) printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: FAIL reason=unknown_arg arg=%s\n' "$1"; exit 1 ;;
    esac
fi

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: FAIL reason=self_dir_unresolved\n'; exit 1; }
SELF_ABS="$SELF_DIR/$(basename -- "$SELF_PATH")"
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: FAIL reason=repo_root_unresolved\n'; exit 1; }
# Select one coherent source tree: an RTL-only override used to mix live TB/env
# with frozen RTL. RV32_TC_DUT_ROOT is the canonical whole-tree override; retain
# the legacy variable as an alias, but apply it to every source/auxiliary input.
DUT_ROOT="${RV32_TC_DUT_ROOT:-${RV32_TC_RTL_ROOT:-$REPO_ROOT}}"
DUT_ROOT="$(cd -- "$DUT_ROOT" && pwd -P)" || {
    printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: FAIL reason=dut_root_unresolved\n'; exit 1; }
ENV_SH="$DUT_ROOT/scripts/env.sh"
TB_REL="sim/functional/tb_top_control_semantics.sv"
MEM_REL="sim/tb/sim_mem_model.sv"
ANCHOR='TB_TOP_CONTROL_SEMANTICS: PASS'
NEG_ANCHOR='FUNCTIONAL_TOP_CONTROL_SEMANTICS_NEGATIVE: PASS'

RUN_DIR=""; RUN_LOG=""; SUM_RUNS="-"; SUM_OK="-"
emit_fail() {
    if [ "$MODE" = "self-test" ]; then
        printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    else
        printf 'TOP_CONTROL_SEMANTICS runs=%s ok=%s\n' "$SUM_RUNS" "$SUM_OK"
        printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail auth_root
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/top-control-semantics}"
is_auth() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail out_root
is_auth "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM"
mkdir -p -- "$ROOT_NORM" || emit_fail out_root_mkdir
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail out_root_recheck
is_auth "$ROOT_NORM" || emit_fail out_root_escape
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail mktemp
RUN_LOG="$RUN_DIR/test_top_control_driver.log"
printf 'TOP_CONTROL_SEMANTICS_RUN_DIR=%s\n' "$RUN_DIR"
printf 'TOP_CONTROL_DUT_ROOT=%s\n' "$DUT_ROOT"
: > "$RUN_LOG" || emit_fail run_log

[ -f "$DUT_ROOT/sim/functional/test_top_control_driver.sh" ] && \
  cmp -s -- "$SELF_ABS" "$DUT_ROOT/sim/functional/test_top_control_driver.sh" \
  || emit_fail driver_source_mismatch
TC_SOURCE_FILES=()
while IFS= read -r -d '' f; do TC_SOURCE_FILES+=("$f"); done < <(cd -- "$DUT_ROOT" && find rtl -type f \( -name '*.v' -o -name '*.vh' \) -print0)
TC_SOURCE_FILES+=(scripts/env.sh "$MEM_REL" "$TB_REL" sim/functional/test_top_control_driver.sh)
manifest_paths() {
    python3 - "$1" "${TC_SOURCE_FILES[@]}" <<'PY'
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
manifest_paths "$DUT_ROOT" > "$RUN_DIR/source.sha.before" || emit_fail source_manifest_before
[ -s "$RUN_DIR/source.sha.before" ] || emit_fail source_manifest_empty
[ -r "$ENV_SH" ] || emit_fail env_sh_missing
# shellcheck disable=SC1090
source_env_guard "$ENV_SH"; ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || { [ "$ENV_RC" -eq 5 ] && emit_fail env_source_mutated; emit_fail "env_guard_rc=$ENV_RC"; }
manifest_paths "$DUT_ROOT" > "$RUN_DIR/source.sha.after-env" || emit_fail source_manifest_after_env
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.after-env" || emit_fail env_source_mutated
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
GCC="${RV32_GCC:-}"; OBJCOPY="${RV32_OBJCOPY:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail iverilog_missing
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail vvp_missing
[ -n "$GCC" ] && [ -x "$GCC" ] || emit_fail gcc_missing
[ -n "$OBJCOPY" ] && [ -x "$OBJCOPY" ] || emit_fail objcopy_missing
command -v python3 >/dev/null 2>&1 || emit_fail python3_missing
command -v sha256sum >/dev/null 2>&1 || emit_fail sha_missing

# Testable caller used by both the real runs and --self-test fixtures.
run_one() {
    local tag="$1" log="$RUN_DIR/run.$1.log" rc np nb sz a
    local -a pa=()
    shift
    for a in "$@"; do pa+=("+$a"); done
    timeout "${TIMEOUT_RUN_S:-900}" "$VV" "$RUN_DIR/tb_top_control_semantics.vvp" \
        "${pa[@]}" > "$log" 2>&1
    rc=$?
    [ "$rc" -eq 124 ] && { echo "RUN_TIMEOUT $tag" >> "$RUN_LOG"; return 124; }
    [ "$rc" -ne 0 ] && { echo "RUN_RC $tag rc=$rc" >> "$RUN_LOG"; cat "$log" >> "$RUN_LOG"; return "$rc"; }
    sz=$(stat -c %s -- "$log" 2>/dev/null || echo 0)
    [ "$sz" -gt 0 ] || { echo "RUN_EMPTY $tag" >> "$RUN_LOG"; return 1; }
    np=$(grep -cxF "$ANCHOR" "$log" || true)
    [ "$np" = "1" ] || { echo "ANCHOR_COUNT $tag=$np" >> "$RUN_LOG"; grep -E 'PASS|FAIL' "$log" >> "$RUN_LOG" || true; return 1; }
    nb=$(grep -cE 'FAIL|DEFECT_REPRODUCED|(^|[^A-Za-z])XZ|UNKNOWN' "$log" || true)
    [ "$nb" = "0" ] || { echo "BAD_TOKENS $tag=$nb" >> "$RUN_LOG"; return 1; }
    cat -- "$log" >> "$RUN_LOG"
    printf 'RUN %s ok\n' "$tag" >> "$RUN_LOG"
    return 0
}

#------------------------------------------------------------------------------
# ★ --self-test：只验本脚本判据（唯一锚点 / 非零 rc / 超时 / 坏 token），
#   不做快照/汇编/编译（那是正控；反证模式必须独立且快）。
#------------------------------------------------------------------------------
if [ "$MODE" = "self-test" ]; then
    CP_OK=0; CP_N=0
    FX="$RUN_DIR/fixtures"; mkdir -p -- "$FX"
    cat > "$FX/env-stable.sh" <<'SH'
: # stable env fixture
SH
    CP_N=$((CP_N+1)); if source_env_guard "$FX/env-stable.sh"; then CP_OK=$((CP_OK+1)); echo 'CP env_guard_stable pass' >> "$RUN_LOG"; else echo 'CP env_guard_stable REJECTED' >> "$RUN_LOG"; fi
    cat > "$FX/env-self-append.sh" <<'SH'
printf '# appended\\n' >> "${BASH_SOURCE[0]}"
SH
    CP_N=$((CP_N+1)); ENV_GUARD_RC=0; source_env_guard "$FX/env-self-append.sh" || ENV_GUARD_RC=$?
    if [ "$ENV_GUARD_RC" -eq 5 ]; then CP_OK=$((CP_OK+1)); echo 'CP env_self_append_rc0 exact-source-reject pass' >> "$RUN_LOG"; else echo "CP env_self_append_rc0 wrong_rc=$ENV_GUARD_RC REJECTED" >> "$RUN_LOG"; fi
    check_reject() {
        CP_N=$((CP_N+1))
        if eval "$2"; then echo "CP $1 got=accept want=reject REJECTED" >> "$RUN_LOG"
        else CP_OK=$((CP_OK+1)); echo "CP $1 got=reject want=reject pass" >> "$RUN_LOG"; fi
    }
    printf 'no anchor\n' > "$FX/noanchor.log"
    check_reject noanchor "[ \"\$(grep -cxF '$ANCHOR' '$FX/noanchor.log' || true)\" = 1 ]"
    printf '%s\n%s\n' "$ANCHOR" "$ANCHOR" > "$FX/dupanchor.log"
    check_reject dupanchor "[ \"\$(grep -cxF '$ANCHOR' '$FX/dupanchor.log' || true)\" = 1 ]"
    printf '%s\nFAIL: boom\n' "$ANCHOR" > "$FX/failtok.log"
    check_reject failtok "[ \"\$(grep -cE 'FAIL|[^A-Za-z]XZ|UNKNOWN' '$FX/failtok.log' || true)\" = 0 ]"
    FB="$RUN_DIR/fakebin"; mkdir -p -- "$FB"
    printf '#!/bin/sh\nexit 3\n' > "$FB/vvp_rc"; chmod +x "$FB/vvp_rc"
    printf '#!/bin/sh\nsleep 5\n' > "$FB/vvp_sleep"; chmod +x "$FB/vvp_sleep"
    : > "$FX/dummy.log"
    check_reject nonzero_rc "[ \"\$(timeout 2 '$FB/vvp_rc' >'$FX/dummy.log' 2>&1; echo \$?)\" = 0 ]"
    check_reject timeout_rc "[ \"\$(timeout 1 '$FB/vvp_sleep' >'$FX/dummy.log' 2>&1; echo \$?)\" != 124 ]"
    cat > "$FB/fake-vvp" <<'SH'
#!/usr/bin/env bash
case "${FAKE_VVP_MODE:-ok}" in
  ok) printf 'stat rows=3\n%s\n' 'TB_TOP_CONTROL_SEMANTICS: PASS' ;;
  missing) printf 'stat rows=3\n' ;;
  duplicate) printf '%s\n%s\n' 'TB_TOP_CONTROL_SEMANTICS: PASS' 'TB_TOP_CONTROL_SEMANTICS: PASS' ;;
  defect) printf '%s\nDEFECT_REPRODUCED\n' 'TB_TOP_CONTROL_SEMANTICS: PASS' ;;
  xz) printf '%s\nXZ invalid\n' 'TB_TOP_CONTROL_SEMANTICS: PASS' ;;
  unknown) printf '%s\nUNKNOWN opcode\n' 'TB_TOP_CONTROL_SEMANTICS: PASS' ;;
  rc9) printf 'stat rows=3\n%s\n' 'TB_TOP_CONTROL_SEMANTICS: PASS'; exit 9 ;;
  timeout) sleep 3 ;;
esac
SH
    chmod +x "$FB/fake-vvp"; : > "$RUN_DIR/tb_top_control_semantics.vvp"
    VV="$FB/fake-vvp"; TIMEOUT_RUN_S=1
    check_accept() { CP_N=$((CP_N+1)); if eval "$2"; then CP_OK=$((CP_OK+1)); echo "CP $1 pass" >> "$RUN_LOG"; else echo "CP $1 REJECTED" >> "$RUN_LOG"; fi; }
    run_one_exact_reject() { local mode="$1" reason="$2" rc=0; FAKE_VVP_MODE="$mode" run_one fixture TOP2B=0 || rc=$?; [ "$rc" -eq 0 ] && return 0; grep -Fqx "$reason" "$RUN_LOG" && return 1; return 2; }
    check_exact_run_reject() { CP_N=$((CP_N+1)); if eval "$2"; then echo "CP $1 got=accept REJECTED" >> "$RUN_LOG"; else local rc=$?; if [ "$rc" -eq 1 ]; then CP_OK=$((CP_OK+1)); echo "CP $1 exact-reason pass" >> "$RUN_LOG"; else echo "CP $1 wrong-reason rc=$rc REJECTED" >> "$RUN_LOG"; fi; fi; }
    check_accept actual_run_one_multiline "run_one fixture TOP2B=0"
    check_exact_run_reject actual_run_one_missing_anchor "run_one_exact_reject missing 'ANCHOR_COUNT fixture=0'"
    check_exact_run_reject actual_run_one_duplicate_anchor "run_one_exact_reject duplicate 'ANCHOR_COUNT fixture=2'"
    check_exact_run_reject actual_run_one_defect "run_one_exact_reject defect 'BAD_TOKENS fixture=1'"
    check_exact_run_reject actual_run_one_XZ "run_one_exact_reject xz 'BAD_TOKENS fixture=1'"
    check_exact_run_reject actual_run_one_UNKNOWN "run_one_exact_reject unknown 'BAD_TOKENS fixture=1'"
    check_exact_run_reject actual_run_one_rc9 "run_one_exact_reject rc9 'RUN_RC fixture rc=9'"
    check_exact_run_reject actual_run_one_timeout "run_one_exact_reject timeout 'RUN_TIMEOUT fixture'"
    [ "$CP_OK" -eq "$CP_N" ] || emit_fail "counterproof=$CP_OK/$CP_N"
    printf 'TOP_CONTROL_SEMANTICS_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N" >> "$RUN_LOG"
    printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS_NEGATIVE: PASS\n' >> "$RUN_LOG"
    [ "$(grep -cxF 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS' "$RUN_LOG" || true)" = "0" ] || emit_fail default_anchor_in_neg
    printf 'TOP_CONTROL_SEMANTICS_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N"
    printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS_NEGATIVE: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 1. 私有快照（完整 RTL 编译闭包 + 必要 sim 依赖 + 本包 TB）
#------------------------------------------------------------------------------
SNAP="$RUN_DIR/src"
mkdir -p -- "$SNAP" || emit_fail snap_mkdir
#   ★ 全部输入统一取 DUT_ROOT（canonical RV32_TC_DUT_ROOT；legacy RV32_TC_RTL_ROOT 同义）。
RTL_ROOT="$DUT_ROOT"
copy_rel() { mkdir -p -- "$SNAP/$(dirname -- "$1")" && cp -p -- "$DUT_ROOT/$1" "$SNAP/$1"; }
while IFS= read -r f; do copy_rel "$f" || emit_fail "snap_copy_$f"; done \
    < <( cd -- "$DUT_ROOT" && find rtl -type f \( -name '*.v' -o -name '*.vh' \) | LC_ALL=C sort )
for f in scripts/env.sh "$MEM_REL" "$TB_REL" sim/functional/test_top_control_driver.sh; do
    [ -f "$DUT_ROOT/$f" ] || emit_fail "dep_missing_$f"
    mkdir -p -- "$SNAP/$(dirname -- "$f")" && cp -p -- "$DUT_ROOT/$f" "$SNAP/$f" \
        || emit_fail "snap_copy_$f"
done
manifest() {
    python3 - "$SNAP" <<'PY'
import base64, os, re, subprocess, sys
root = os.fsencode(sys.argv[1])
paths = []
for here, dirs, files in os.walk(root):
    for name in files:
        paths.append(os.path.relpath(os.path.join(here,name), root))
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
{
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RTL_ROOT        = $RTL_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
        echo "GIT_STATUS_SHA  = $(git -C "$REPO_ROOT" status --porcelain | sha256sum | awk '{print $1}')"
        echo "GIT_STATUS_N    = $(git -C "$REPO_ROOT" status --porcelain | wc -l)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
} >> "$RUN_LOG"
manifest_paths "$SNAP" > "$RUN_DIR/source.sha.copy" || emit_fail source_manifest_copy
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.copy" || emit_fail source_copy_mismatch
manifest > "$RUN_DIR/src.sha.before" || emit_fail manifest_before
[ -s "$RUN_DIR/src.sha.before" ] || emit_fail manifest_empty

mapfile -d '' -t RTL_FILES < <(cd -- "$SNAP" && find rtl -name '*.v' -print0)

#------------------------------------------------------------------------------
# 2. 最小真实程序（inline 源码 ⇒ 工具链汇编/链接/objcopy ⇒ hex）
#------------------------------------------------------------------------------
PROG_DIR="$RUN_DIR/prog"
mkdir -p -- "$PROG_DIR" || emit_fail prog_dir
cat > "$PROG_DIR/tc_sem.S" <<'ASM'
    .section .text.init,"ax",@progbits
    .globl _start
    .option norvc
    .equ UART,  0x1FE001E0
    .equ MTIME, 0x1F00BFF8
    .equ MAGIC, 0x54433031
    .equ DONE,  0xDEADBEEF
#ifdef TOP2B
    .equ NCHK, 13
#else
    # 14 既有项 + 16 个跨半 carry 扫描项 + carry_seen + carry_read_ok = 32
    .equ NCHK, 32
#endif

#   结果发射（按 DUT 分通道）：
#     · 2A：32 位字按字节写 UART 数据寄存器（非缓存路径；TB 侧拼字）。
#     · 2B：写 DDR 邮箱字（0x8000_2000 起），最后 cbo.flush 三行写回；TB 直接读
#       存储模型。理由：2B 的 uncached 强副作用 store 竞态/重放尚未闭环
#       （F4-1 未完成项）⇒ 不能用"一字节一条 uncached store"当结果通道；
#       邮箱字写幂等（重放写同址同值），flush 后判据确定。
#   注意：2A 从 XIP 取指，取指停顿使"指令条数 ≠ 拍数"，故所有窗口按
#   "拍数上限"给足余量；只有**写替代自身 +1 / 高半不受 tick 影响**这类
#   与拍数无关的量才做精确判据。

    .macro EMIT
#ifdef TOP2B
        sw   a0, 0(s1)
        addi s1, s1, 4
#else
        sb   a0, 0(s0)
        srli t6, a0, 8
        sb   t6, 0(s0)
        srli t6, a0, 16
        sb   t6, 0(s0)
        srli t6, a0, 24
        sb   t6, 0(s0)
#endif
    .endm

#   2B：CSR 指令之间插入间隔，确保相邻 CSR 落在**不同派发块**（本核对"同块多条 CSR"
#   的串行化不在本包判据内，避免把后端 CSR 读时序混入计数语义检查）。
    .macro GAP
#ifdef TOP2B
        .rept 6
        nop
        .endr
#endif
    .endm

_start:
    li   s0, UART
#ifdef TOP2B
    # 放开 cbo 门控（CBCFE=1 / CBIE=11）并初始化邮箱游标
    li   t0, 0x00000070
    csrw 0x30A, t0
    li   s1, 0x80002000
#endif
    li   a0, MAGIC
    EMIT
    li   a0, NCHK
    EMIT

# C1: 写 mcycleh → 紧邻读 cycleh（mcycle↔cycle 别名，高半与拍数无关 ⇒ 精确）
    li   t0, 0x12345678
    csrw 0xB80, t0
    GAP
    csrr t1, 0xC80
    GAP
    li   a0, 0
    bne  t1, t0, 1f
    li   a0, 1
1:  EMIT

# C2: 写 mcycle 低半 = 0 → 读 cycle 低半必须**小于写前值**（别名；不假定拍数）
    csrr t0, 0xC00
    GAP
    csrw 0xB00, x0
    GAP
    csrr t1, 0xC00
    GAP
    li   a0, 0
    bgeu t1, t0, 1f
    li   a0, 1
1:  EMIT

# C3: 64 位本体进位：低半写 0xFFFF_FFFE ⇒ 至少一次自然溢出，高半 ∈ {1,2}
#     （高半 1 = 只进位一次；2 仅在写拍前低半恰为 0xFFFF_FFFF 时出现）
    csrw 0xB00, x0
    GAP
    csrw 0xB80, x0
    GAP
    nop
    nop
    nop
    li   t0, 0xFFFFFFFE
    csrw 0xB00, t0
    GAP
    nop
    nop
    nop
    nop
    nop
    csrr t1, 0xB00
    GAP
    csrr t2, 0xB80
    GAP
    li   a0, 0
    li   t3, 1
    bltu t2, t3, 1f
    li   t3, 3
    bgeu t2, t3, 1f
    li   a0, 1
1:  EMIT

# C4: 写高半不动低半（低半继续 tick）、高半精确
    csrr t3, 0xB00
    GAP
    li   t0, 0xABCD1234
    csrw 0xB80, t0
    GAP
    nop
    nop
    csrr t4, 0xB00
    GAP
    csrr t5, 0xB80
    GAP
    li   a0, 0
    bne  t5, t0, 1f
    bgeu t3, t4, 1f
    sub  t6, t4, t3
    li   t1, 4096
    bgeu t6, t1, 1f
    li   a0, 1
1:  EMIT

# C5: MMIO 写 CLINT mtime → time 读到新值窗口；timeh==0；cycleh 仍为 0x0BADF00D
    li   t0, 0x0BADF00D
    csrw 0xB80, t0
    GAP
    nop
    nop
    li   t1, MTIME
    li   t2, 0x11223344
    sw   t2, 0(t1)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    csrr t3, 0xC01
    GAP
    csrr t4, 0xC81
    GAP
    csrr t5, 0xC80
    GAP
    li   a0, 0
    bne  t4, zero, 1f
    bne  t5, t0, 1f
    li   t6, 0x11223344
    bltu t3, t6, 1f
    li   t6, 0x11233344
    bgeu t3, t6, 1f
    beq  t3, t5, 1f
    li   a0, 1
1:  EMIT

# C6: mtime 自由计数：两次读 time 严格递增且差在窗口内
    csrr t3, 0xC01
    GAP
    .rept 8
    nop
    .endr
    csrr t4, 0xC01
    GAP
    li   a0, 0
    bgeu t3, t4, 1f
    sub  t6, t4, t3
    li   t1, 0x10000
    bgeu t6, t1, 1f
    li   a0, 1
1:  EMIT

# C7: MPP WARL：写 2'b10（保留/H）⇒ 读回 S(01)
    li   t0, 0x1000
    csrw 0x300, t0
    GAP
    csrr t1, 0x300
    GAP
    srli t1, t1, 11
    andi t1, t1, 3
    li   a0, 0
    li   t3, 1
    bne  t1, t3, 1f
    li   a0, 1
1:  EMIT

# C8: MPP = M(11) 保持
    li   t0, 0x1800
    csrw 0x300, t0
    GAP
    csrr t1, 0x300
    GAP
    srli t1, t1, 11
    andi t1, t1, 3
    li   a0, 0
    li   t3, 3
    bne  t1, t3, 1f
    li   a0, 1
1:  EMIT

# C9: MPP = U(00) 保持
    li   t0, 0
    csrw 0x300, t0
    GAP
    csrr t1, 0x300
    GAP
    srli t1, t1, 11
    andi t1, t1, 3
    li   a0, 0
    bne  t1, zero, 1f
    li   a0, 1
1:  EMIT

# C10: 写 mcycle 低半 → mcycle/cycle 都在"写值 + 拍数窗口"内且一致
    li   t0, 0x12345678
    csrw 0xB00, t0
    GAP
    nop
    nop
    csrr t1, 0xB00
    GAP
    csrr t2, 0xC00
    GAP
    li   a0, 0
    bltu t1, t0, 1f
    sub  t6, t1, t0
    li   t3, 4096
    bgeu t6, t3, 1f
    bltu t2, t0, 1f
    sub  t6, t2, t0
    bgeu t6, t3, 1f
    li   a0, 1
1:  EMIT

# C11: 写 minstret 低半 → 读 minstret（2A 精确复读；2B 拍数窗口）
    li   t0, 0x00010000
    csrw 0xB02, t0
    GAP
    csrr t1, 0xB02
    GAP
    li   a0, 0
#ifdef TOP2B
    bltu t1, t0, 1f
    sub  t6, t1, t0
    li   t3, 256
    bgeu t6, t3, 1f
#else
    bne  t1, t0, 1f
#endif
    li   a0, 1
1:  EMIT

# C12: 写 minstreth → 读 instreth 精确；低半保持递增
    li   t0, 0x0000ABCD
    csrw 0xB82, t0
    GAP
    csrr t1, 0xB82
    GAP
    csrr t2, 0xB02
    GAP
    li   a0, 0
    bne  t1, t0, 1f
    li   t3, 0x00010000
    bltu t2, t3, 1f
    li   t3, 0x00020000
    bgeu t2, t3, 1f
    li   a0, 1
1:  EMIT

# C13: 写 minstret 低半 = 0x8000_0000 不得改高半（写低不伪命中读高）
    li   t0, 0x80000000
    csrw 0xB02, t0
    GAP
    csrr t1, 0xB82
    GAP
    csrr t2, 0xB02
    GAP
    li   a0, 0
    li   t3, 0x0000ABCD
    bne  t1, t3, 1f
    bltu t2, t0, 1f
    sub  t6, t2, t0
    li   t3, 4096
    bgeu t6, t3, 1f
    li   a0, 1
1:  EMIT

#ifndef TOP2B
# C14（仅 2A）：RMW 先后 —— csrrs 的读必须看到刚写入的 minstret（写替代自身 +1），
#     新值 = old | mask；随后读回应为 new（两级旁路）。mask 提前备好，避免
#     把"更老指令的 +1"混进期望值（那属周期级 oracle 覆盖范围）。
    li   t1, 2
    li   t0, 0x1000
    csrw 0xB02, t0
    GAP
    csrrs t2, 0xB02, t1
    GAP
    csrr t3, 0xB02
    GAP
    li   a0, 0
    li   t4, 0x1000
    bne  t2, t4, 1f
    li   t4, 0x1002
    bne  t3, t4, 1f
    li   a0, 1
1:  EMIT
#endif

#ifndef TOP2B
# ---- C15（仅 2A）：**跨半 carry 危险对**真实软件扫描 ----
#   序列：setup 写 mcycle 低半 = 0xFFFFFFFF-d → A: 写 mcycle 低半 = 0 → B: 紧邻读 cycleh。
#   · A 的 W 沿若 body low==0xFFFFFFFF，则 tick 进位使 high 2→3（写后本体 3_0）。
#   · B 在程序序上晚于 A ⇒ 读到 high 必须为 3（不是 2）。
#   d 扫描 0..15 用来补偿 setup→A 的流水/取指延迟（不 force、不直写 DUT 计数器）。
#   判据：每个 d 的布尔 = (body_high != 3) | (B_read == 3)；另出 carry_seen 与
#         carry_read_ok（必须触发进位且 B 读到 3，否则"未覆盖"按 fail）。
    li   s2, 0
    li   s3, 0
    li   s4, 0
    li   s5, 0
    li   s6, 0
    li   s7, 0
.Lscan_loop:
    nop; nop; nop; nop; nop; nop; nop; nop
    csrw 0xB00, x0
    li   t0, 2
    csrw 0xB80, t0
    li   t0, 0xFFFFFFFF
    sub  t0, t0, s7
    csrw 0xB00, t0
    csrw 0xB00, x0
    csrr t1, 0xC80
    csrr t2, 0xB00
    csrr t3, 0xC80
    li   a0, 0
    li   t4, 3
    bne  t3, t4, .Lsd_ok
    beq  t1, t4, .Lsd_ok
    j    .Lsd_emit
.Lsd_ok:
    li   a0, 1
.Lsd_emit:
    EMIT
    li   t4, 3
    bne  t3, t4, .Lsd_next
    li   t4, 1
    beq  s2, t4, .Lsd_next
    li   s2, 1
    mv   s3, s7
    mv   s4, t1
    mv   s5, t2
    mv   s6, t3
.Lsd_next:
    addi s7, s7, 1
    li   t4, 16
    bne  s7, t4, .Lscan_loop
    mv   a0, s2
    EMIT
    li   a0, 0
    beq  s2, zero, .Lsd_info
    li   t4, 3
    bne  s4, t4, .Lsd_info
    li   a0, 1
.Lsd_info:
    EMIT
    li   a0, 0x5443494E
    EMIT
    mv   a0, s3
    EMIT
    mv   a0, s4
    EMIT
    mv   a0, s5
    EMIT
    mv   a0, s6
    EMIT
#endif

#ifdef TOP2B
# C15（仅 2B，无结果字）：制造两种可达的 2 提交组合 ——
#   lane0=CSR(minstret)+lane1=ALU 与 lane0=ALU+lane1=CSR(minstret)；
#   TB 侧逐拍计入 n_b_l0csr_l1alu / n_b_l0alu_l1csr，两者都必须 > 0。
#   为覆盖不同 ROB/提交对齐，两种模式在循环里交替出现。
#   ★ 只碰 x7/x13..x17（**不得**碰 s0/s1/a0..a2 —— s1 是 2B 邮箱游标，
#     被本循环改坏会把最后的 DONE 写到邮箱之外；x8=s0、x9=s1、x10..x12=a0..a2）
    li   t5, 24
2:  csrw 0xB02, x0
    addi x7,  x7,  1
    addi x13, x13, 1
    addi x14, x14, 1
    csrw 0xB02, x0
    addi x15, x15, 1
    addi x16, x16, 1
    addi x17, x17, 1
    addi t5, t5, -1
    bne  t5, zero, 2b
#endif

    li   a0, DONE
    EMIT
#ifdef TOP2B
    # 邮箱三行写回（cbo.flush = writeback + invalidate；幂等，可由重放重复执行）。
    #   ★ 第二轮延迟后再 flush：2B 的已提交 store 经 CDQ/适配器**异步落 L1D**，
    #     维护写回拍可能先于最后一笔 store 的合并 ⇒ 单轮 flush 会漏最后一行；
    #     本包只做**观测/结果通道**，不改该异步策略（用户已要求阶段末统一审）。
    li   t6, 0x80002000
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
    li   t5, 64
3:  addi t5, t5, -1
    bne  t5, zero, 3b
    li   t6, 0x80002000
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
#endif
9:  j 9b

ASM

assemble_one() {   # $1=defs(可空) $2=link $3=outbase
    local defs="$1" link="$2" base="$3"
    # shellcheck disable=SC2086
    "$GCC" $defs -march=rv32imac_zicsr_zicbom -mabi=ilp32 -nostdlib -nostartfiles \
        -Ttext="$link" -o "$PROG_DIR/$base.elf" "$PROG_DIR/tc_sem.S" \
        > "$RUN_DIR/asm.$base.log" 2>&1
    local rc=$?
    [ "$rc" -eq 0 ] || { cat "$RUN_DIR/asm.$base.log" >> "$RUN_LOG"; return "$rc"; }
    "$OBJCOPY" -O binary "$PROG_DIR/$base.elf" "$PROG_DIR/$base.bin" \
        >> "$RUN_DIR/asm.$base.log" 2>&1 || return 1
    local size
    size=$(stat -c %s -- "$PROG_DIR/$base.bin") || return 1
    [ "$size" -gt 0 ] || return 1
    (( size % 4 == 0 )) || { echo "PROG_SIZE_NOT_WORD_ALIGNED $base size=$size" >> "$RUN_LOG"; return 1; }
    python3 - "$PROG_DIR/$base.bin" "$link" "$PROG_DIR/$base.hex" <<'PY'
import struct, sys
bin_path, base, out_path = sys.argv[1], int(sys.argv[2], 0), sys.argv[3]
data = open(bin_path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
with open(out_path, 'w') as f:
    f.write('@%08x\n' % base)
    for w in words:
        f.write('%08x\n' % w)
PY
    local prc=$?
    [ "$prc" -eq 0 ] || return 1
    { echo "PROG $base link=0x$link bytes=$size words=$((size/4)) sha256=$(sha256sum "$PROG_DIR/$base.hex" | awk '{print $1}')"; } >> "$RUN_LOG"
    return 0
}

assemble_one "" "0x1C000000" "prog_2a" || emit_fail assemble_2a
assemble_one "-DTOP2B" "0x80000000" "prog_2b" || emit_fail assemble_2b
[ -s "$PROG_DIR/prog_2a.hex" ] || emit_fail hex_2a_missing
[ -s "$PROG_DIR/prog_2b.hex" ] || emit_fail hex_2b_missing
manifest_program() {
    python3 - "$PROG_DIR" tc_sem.S prog_2a.hex prog_2b.hex <<'PY'
import base64, os, re, subprocess, sys
root = os.fsencode(sys.argv[1])
for rel in sorted(os.fsencode(x) for x in sys.argv[2:]):
    r = subprocess.run([b'sha256sum', b'--', rel], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.stderr.buffer.write(r.stderr); sys.exit(r.returncode or 1)
    m = re.fullmatch(rb'([0-9a-f]{64})  ' + re.escape(rel) + rb'\n', r.stdout)
    if not m:
        sys.stderr.write('sha256sum_raw_output_invalid\n'); sys.exit(1)
    sys.stdout.buffer.write(m.group(1) + b' ' + base64.b64encode(rel) + b'\n')
PY
}
manifest_program > "$RUN_DIR/program.sha.before" || emit_fail program_manifest_before

#------------------------------------------------------------------------------
# 3. 编译（在快照 root 内、相对 -I；程序路径用编译期参数注入）
#------------------------------------------------------------------------------
COMPILE_LOG="$RUN_DIR/compile.log"
( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
    -s tb_top_control_semantics \
    -P "tb_top_control_semantics.PROG2A=\"$PROG_DIR/prog_2a.hex\"" \
    -P "tb_top_control_semantics.PROG2B=\"$PROG_DIR/prog_2b.hex\"" \
    -o "$RUN_DIR/tb_top_control_semantics.vvp" "${RTL_FILES[@]}" "$TB_REL" ) > "$COMPILE_LOG" 2>&1
C_RC=$?
[ "$C_RC" -eq 0 ] || { cat "$COMPILE_LOG" >> "$RUN_LOG"; emit_fail "compile_rc=$C_RC"; }
[ -s "$RUN_DIR/tb_top_control_semantics.vvp" ] || emit_fail compile_zero

#------------------------------------------------------------------------------
# 4. 两次真跑 + 判定
#------------------------------------------------------------------------------
SUM_RUNS=3; SUM_OK=0
run_one 2a     TOP2B=0              || emit_fail "run_2a"
SUM_OK=1
#   ★ C15：同一 2A 程序改由 DDR（L1I 缓存）驻留执行 —— 相邻 CSR 指令 1 拍/条，
#     写 mcycle 低半的 W/M 沿与读 cycleh 的 E 同拍 ⇒ 真实交叠窗口可达；
#     该运行里 C15 的交叠覆盖与"后条读==3"是**硬判据**（XIP 运行只做功能采样）。
run_one 2a_ddr TOP2B=0 DDR2A=1      || emit_fail "run_2a_ddr"
SUM_OK=2
run_one 2b     TOP2B=1              || emit_fail "run_2b"
SUM_OK=3

manifest_paths "$DUT_ROOT" > "$RUN_DIR/source.sha.after" || emit_fail source_manifest_after
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.after" || emit_fail source_mutated
manifest_paths "$SNAP" > "$RUN_DIR/source.sha.snap-after" || emit_fail source_manifest_snap_after
cmp -s "$RUN_DIR/source.sha.copy" "$RUN_DIR/source.sha.snap-after" || emit_fail snapshot_inputs_mutated
manifest_program > "$RUN_DIR/program.sha.after" || emit_fail program_manifest_after
cmp -s "$RUN_DIR/program.sha.before" "$RUN_DIR/program.sha.after" || emit_fail generated_program_mutated
manifest > "$RUN_DIR/src.sha.after" || emit_fail manifest_after
cmp -s "$RUN_DIR/src.sha.before" "$RUN_DIR/src.sha.after" || emit_fail snapshot_mutated

printf 'TOP_CONTROL_SEMANTICS runs=%s ok=%s\n' "$SUM_RUNS" "$SUM_OK" >> "$RUN_LOG"
printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS\n' >> "$RUN_LOG"
[ "$(grep -cxF 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS' "$RUN_LOG" || true)" = "1" ] || emit_fail anchor_count
[ "$(grep -cF 'FAIL' "$RUN_LOG" || true)" = "0" ] || emit_fail log_fail
printf 'TOP_CONTROL_SEMANTICS runs=%s ok=%s\n' "$SUM_RUNS" "$SUM_OK"
printf 'FUNCTIONAL_TOP_CONTROL_SEMANTICS: PASS\n'
exit 0
