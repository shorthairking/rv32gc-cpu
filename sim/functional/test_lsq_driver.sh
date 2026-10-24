#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_lsq_driver.sh —— F2 LSQ 包**反证驱动**（旧树红 / 新树绿 / 控制两边正确）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2B 乱序后端）
# 依赖 : sim/functional/test_lsq.sh（包入口，唯一 FUNCTIONAL_LSQ: PASS 锚点来源）
#
# 做什么（默认全跑；`--self-test` 只跑包装器杀伤路径自检）：
#   1) **私有不可变输入冻结**（初审 #3）：
#      · `deps_cur`：当前工作树 `rtl/back2/{lsq_simple.v,back2_params.vh}` 的私有拷贝；
#      · `deps_base`：`git show 201acf61:…` 提取的两个旧文件；
#      · `frozen/`：**新旧两相共用**的包脚本 + TB + `scripts/env.sh` 私有拷贝
#        （两相都跑这一份冻结副本 ⇒ 阶段间任何共享输入变化都必须被拒）。
#      全部拷贝 chmod 444，并在每相前后复核 sha256。
#   2) **正控（修复树）**：先跑一次**正式注册入口** `sim/functional/test_lsq.sh`
#      （证明 manifest 里的条目可用），再用 `frozen/` 副本对 `deps_cur` 跑 fixed 口径，
#      要求 rc=0、唯一 PASS 锚点、`fails=0 defect=0 xz=0`、冻结规格精确。
#   3) **反证（旧树）**：用**同一份 frozen 副本**对 `deps_base` 跑 `LSQ_EXPECT=old`
#      ⇒ rc=1、不得出现 PASS、5 个根因 `DEFECT_REPRODUCED` 齐全、10 个缺陷向量 defect=1。
#   4) **控制两边正确**：两相都校验控制向量 `fails=0 defect=0`。
#   5) **包装器自检**（私有 fixture，不改正式源，共 20 例）：编译失败 / 零 vvp / 运行非零 /
#      缺摘要 / 日志含 FAIL / 日志含 DEFECT_REPRODUCED / 少向量 / 毒 cwd 但 DUT_ROOT 正确
#      （必须 PASS）/ 重复 ID / 错名 / 零检查+别例补偿 checksum / 共享 TB 被改必须拒 /
#      共享+单文件 sha 清单 rc9 与少数行必须拒 / **+LSQ_XZ_PROBE 正控**（真实 chk 收 X/Z、
#      私有替身注 X/Z ⇒ gate 精确拒）/ **弱 chk、删 monitor、坏有效字段口径三种变异必须
#      判 MISS** / REAL 相活源前后变动必须拒。
#   6) **SHA 收口**：所有哈希先 capture 原始 rc、校验非空 64hex（共享清单 3 行逐路径），
#      `||fail` 后才比较/打印；REAL 相虽用正式活入口，但前后对照冻结集合，变化即拒。
#
# 产物纪律：产物根固定在本仓库 `build/functional/` 授权树内（或父入口传入的 PKGOUT），
#          每次 `mktemp -d` 独占 run 目录，**不做任何 rm**。
# 用法 : bash sim/functional/test_lsq_driver.sh
#        bash sim/functional/test_lsq_driver.sh --self-test
#        LSQ_BASELINE_COMMIT=<sha> bash sim/functional/test_lsq_driver.sh
#==============================================================================
set -u

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'LSQ_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'LSQ_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }
PKG_SH="$SELF_DIR/test_lsq.sh"
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'LSQ_DRIVER: FAIL reason=auth_root_readlink_failed\n'; exit 1; }

MODE="full"
if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    MODE="selftest"
elif [ "$#" -ne 0 ]; then
    printf 'LSQ_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi

[ -f "$PKG_SH" ] || { printf 'LSQ_DRIVER: FAIL reason=pkg_missing path=%s\n' "$PKG_SH"; exit 1; }

ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/lsq-driver}"
case "$(readlink -m -- "$ROOT_RAW")" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) printf 'LSQ_DRIVER: FAIL reason=out_root_unauthorized root=%s\n' "$ROOT_RAW"; exit 1 ;;
esac
mkdir -p -- "$(readlink -m -- "$ROOT_RAW")" || {
    printf 'LSQ_DRIVER: FAIL reason=out_root_mkdir_failed\n'; exit 1; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")"
DRV="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || {
    printf 'LSQ_DRIVER: FAIL reason=mktemp_run_dir_failed root=%s\n' "$ROOT_NORM"; exit 1; }

DRV_LOG="$DRV/driver.log"
: > "$DRV_LOG" || { printf 'LSQ_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }
exec 3>>"$DRV_LOG"

note() { printf '%s\n' "$*" >&3; }
fail() {
    note "DRIVER_FAIL reason=$1"
    printf 'LSQ_DRIVER: FAIL reason=%s run_dir=%s\n' "$1" "$DRV"
    exit 1
}

#==============================================================================
# S. SHA 收口（窄复审 P1）：单文件哈希直接捕原始 rc，校验恰好 1 行 / 64 位小写 hex /
#    路径逐字匹配；调用端一律“先 capture 并 ||fail、非空 64hex 再比较/打印”，
#    绝不在 `[ "$(hash a)" = "$(hash b)" ]` / `note "$(hash)"` 里直接调用。
#==============================================================================
validated_sha_output() {  # 原始字节文件已捕获；仅在严格验证后输出 SHA 列
    python3 - "$@" <<'PY'
import os, pathlib, re, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
paths = sys.argv[2:]
if b'\0' in raw or b'\r' in raw:
    print('sha256_bytes', file=sys.stderr); raise SystemExit(1)
if not raw.endswith(b'\n'):
    print('sha256_unterminated', file=sys.stderr); raise SystemExit(1)
rows = raw.split(b'\n')[:-1]
if len(rows) != len(paths):
    print(f'sha256_lines={len(rows)}', file=sys.stderr); raise SystemExit(1)
hashes = []
for i, (row, path) in enumerate(zip(rows, paths), 1):
    m = re.fullmatch(rb'([0-9a-f]{64})  (.*)', row)
    if not m:
        print(f'sha256_format line={i}', file=sys.stderr); raise SystemExit(1)
    if m.group(2) != os.fsencode(path):
        print(f'sha256_path line={i}', file=sys.stderr); raise SystemExit(1)
    hashes.append(m.group(1).decode())
print(' '.join(hashes), end='')
PY
}
file_sha() {  # capture raw stdout and rc first, validate exact one-row record
    local raw rc result
    raw="$(mktemp -- "$DRV/sha-one-XXXXXXXX")" || return 1
    sha256sum -- "$1" >"$raw"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'sha256_failed path=%s rc=%s\n' "$1" "$rc" >&2; return 1; }
    result="$(validated_sha_output "$raw" "$1" 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'sha256_invalid path=%s reason=%s\n' "$1" "$result" >&2; return 1; }
    [ "${#result}" -eq 64 ] || { printf 'sha256_hexlen path=%s\n' "$1" >&2; return 1; }
    printf '%s' "$result"
}

sha_of() {  # 取哈希并传播失败（绝不让空值参与比较）
    local h
    h="$(file_sha "$1")" || fail "sha256_failed path=$1"
    [ -n "$h" ] || fail "sha256_empty path=$1"
    printf '%s' "$h"
}

need_hash() {  # need_hash <value> <path>
    case "$1" in
        ""|*[!0-9a-f]*) fail "sha256_bad_value path=$2" ;;
    esac
    [ "${#1}" -eq 64 ] || fail "sha256_bad_value path=$2"
}

need_shared_hash() {  # need_shared_hash <value> <root>
    printf '%s' "$1" | grep -qE '^[0-9a-f]{64} [0-9a-f]{64} [0-9a-f]{64} $' \
        || fail "shared_sha_bad_value root=$2"
}

note "==== test_lsq_driver.sh ===="
note "date       = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT  = $REPO_ROOT"
note "DRV        = $DRV"
note "MODE       = $MODE"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    note "GIT_HEAD   = $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

IDENT_LSQ_SHA="$(sha_of "$REPO_ROOT/rtl/back2/lsq_simple.v")" || fail "sha256_failed identity_lsq"
need_hash "$IDENT_LSQ_SHA" "$REPO_ROOT/rtl/back2/lsq_simple.v"
IDENT_HDR_SHA="$(sha_of "$REPO_ROOT/rtl/back2/back2_params.vh")" || fail "sha256_failed identity_hdr"
need_hash "$IDENT_HDR_SHA" "$REPO_ROOT/rtl/back2/back2_params.vh"
IDENT_TB_SHA="$(sha_of "$SELF_DIR/tb_lsq_semantics.sv")" || fail "sha256_failed identity_tb"
need_hash "$IDENT_TB_SHA" "$SELF_DIR/tb_lsq_semantics.sv"
IDENT_PKG_SHA="$(sha_of "$PKG_SH")" || fail "sha256_failed identity_pkg"
need_hash "$IDENT_PKG_SHA" "$PKG_SH"
note "LSQ_SHA    = $IDENT_LSQ_SHA"
note "HDR_SHA    = $IDENT_HDR_SHA"
note "TB_SHA     = $IDENT_TB_SHA"
note "PKG_SHA    = $IDENT_PKG_SHA"

#==============================================================================
# A. 私有不可变输入冻结
#==============================================================================
CUR="$DRV/deps_cur"
SNAP="$DRV/deps_base"
FRZ="$DRV/frozen"
BASE_COMMIT="${LSQ_BASELINE_COMMIT:-201acf61}"

#   `deps_cur`：当前工作树两文件的私有拷贝（两相/自检共用；与并发改动隔离）
mkdir -p -- "$CUR/rtl/back2" || fail "cur_snapshot_mkdir_failed"
cp -- "$REPO_ROOT/rtl/back2/lsq_simple.v" "$CUR/rtl/back2/lsq_simple.v" || fail "cur_snapshot_lsq_copy"
cp -- "$REPO_ROOT/rtl/back2/back2_params.vh" "$CUR/rtl/back2/back2_params.vh" || fail "cur_snapshot_hdr_copy"
chmod 444 -- "$CUR/rtl/back2/lsq_simple.v" "$CUR/rtl/back2/back2_params.vh" || fail "cur_snapshot_chmod"
CUR_LSQ_SHA="$(sha_of "$CUR/rtl/back2/lsq_simple.v")" || fail "sha256_failed cur_lsq"
need_hash "$CUR_LSQ_SHA" "$CUR/rtl/back2/lsq_simple.v"
CUR_HDR_SHA="$(sha_of "$CUR/rtl/back2/back2_params.vh")" || fail "sha256_failed cur_hdr"
need_hash "$CUR_HDR_SHA" "$CUR/rtl/back2/back2_params.vh"
[ "$IDENT_LSQ_SHA" = "$CUR_LSQ_SHA" ] || fail "cur_snapshot_lsq_mismatch"
[ "$IDENT_HDR_SHA" = "$CUR_HDR_SHA" ] || fail "cur_snapshot_hdr_mismatch"
note "CUR        = $CUR"
note "CUR_LSQ_SHA= $CUR_LSQ_SHA"
note "CUR_HDR_SHA= $CUR_HDR_SHA"

#   `frozen/`：两相共用的包脚本 + TB + env.sh（阶段间共享输入的真身）
mkdir -p -- "$FRZ/sim/functional" "$FRZ/scripts" || fail "frozen_mkdir_failed"
cp -- "$PKG_SH" "$FRZ/sim/functional/test_lsq.sh" || fail "frozen_pkg_copy_failed"
cp -- "$SELF_DIR/tb_lsq_semantics.sv" "$FRZ/sim/functional/tb_lsq_semantics.sv" || fail "frozen_tb_copy_failed"
cp -- "$REPO_ROOT/scripts/env.sh" "$FRZ/scripts/env.sh" || fail "frozen_env_copy_failed"
chmod 444 -- "$FRZ/sim/functional/test_lsq.sh" "$FRZ/sim/functional/tb_lsq_semantics.sv" "$FRZ/scripts/env.sh" \
    || fail "frozen_chmod_failed"
cmp -s -- "$PKG_SH" "$FRZ/sim/functional/test_lsq.sh" || fail "frozen_pkg_mismatch"
cmp -s -- "$SELF_DIR/tb_lsq_semantics.sv" "$FRZ/sim/functional/tb_lsq_semantics.sv" || fail "frozen_tb_mismatch"
cmp -s -- "$REPO_ROOT/scripts/env.sh" "$FRZ/scripts/env.sh" || fail "frozen_env_mismatch"

#   共享输入清单（3 条固定路径）—— 同样直接捕 rc、固定 3 行、每行 64hex、路径逐条匹配；
#   任何一项不符都返回非零（“少一条共享 hash”不得被当成正常）。
shared_sha_of() {
    local root="$1" raw rc result
    raw="$(mktemp -- "$DRV/sha-shared-XXXXXXXX")" || return 1
    sha256sum -- "$root/sim/functional/test_lsq.sh" \
                  "$root/sim/functional/tb_lsq_semantics.sv" \
                  "$root/scripts/env.sh" >"$raw" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'shared_sha_rc=%s\n' "$rc" >&3; return 1; }
    result="$(validated_sha_output "$raw" "$root/sim/functional/test_lsq.sh" \
        "$root/sim/functional/tb_lsq_semantics.sv" "$root/scripts/env.sh" 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'shared_sha_invalid reason=%s\n' "$result" >&3; return 1; }
    printf '%s ' "$result"
}

#   ★ REAL 相用活源：其前后必须与冻结时的同一集合逐字一致（否则结果与日志 SHA 错配）。
check_live_unchanged() {  # check_live_unchanged <live_root> <expected_sha>
    local now rc
    now="$(shared_sha_of "$1")"
    rc=$?
    [ "$rc" -eq 0 ] || fail "live_sha_failed root=$1"
    need_shared_hash "$now" "$1"
    [ "$now" = "$2" ] || return 1
    return 0
}

#   ★ 若共享输入在阶段间变化 ⇒ 反证结果无效：**必须拒**。
check_shared_unchanged() {  # check_shared_unchanged <frozen_root> <expected_sha>
    local now rc
    now="$(shared_sha_of "$1")"
    rc=$?
    [ "$rc" -eq 0 ] || fail "shared_sha_failed root=$1"
    need_shared_hash "$now" "$1"
    [ "$now" = "$2" ] || return 1
    return 0
}

if [ "$MODE" = "full" ]; then
    git -C "$REPO_ROOT" cat-file -e "${BASE_COMMIT}^{commit}" 2>>"$DRV_LOG" \
        || fail "baseline_commit_missing commit=$BASE_COMMIT"
    mkdir -p -- "$SNAP/rtl/back2" || fail "snapshot_mkdir_failed"
    git -C "$REPO_ROOT" show "${BASE_COMMIT}:rtl/back2/lsq_simple.v" > "$SNAP/rtl/back2/lsq_simple.v" \
        || fail "snapshot_lsq_extract_failed"
    git -C "$REPO_ROOT" show "${BASE_COMMIT}:rtl/back2/back2_params.vh" > "$SNAP/rtl/back2/back2_params.vh" \
        || fail "snapshot_hdr_extract_failed"
    chmod 444 -- "$SNAP/rtl/back2/lsq_simple.v" "$SNAP/rtl/back2/back2_params.vh" \
        || fail "snapshot_chmod_failed"
    note "SNAP       = $SNAP"
    note "SNAP_COMMIT= $BASE_COMMIT"
    SNAP_LSQ_SHA="$(sha_of "$SNAP/rtl/back2/lsq_simple.v")" || fail "sha256_failed snap_lsq"
    need_hash "$SNAP_LSQ_SHA" "$SNAP/rtl/back2/lsq_simple.v"
    SNAP_HDR_SHA="$(sha_of "$SNAP/rtl/back2/back2_params.vh")" || fail "sha256_failed snap_hdr"
    need_hash "$SNAP_HDR_SHA" "$SNAP/rtl/back2/back2_params.vh"
    note "SNAP_LSQ_SHA= $SNAP_LSQ_SHA"
    note "SNAP_HDR_SHA= $SNAP_HDR_SHA"
fi

SHARED_SHA_PRE="$(shared_sha_of "$FRZ")" || fail "shared_sha_failed"
need_shared_hash "$SHARED_SHA_PRE" "$FRZ"
note "FRZ        = $FRZ"
note "SHARED_SHA = $SHARED_SHA_PRE"

#------------------------------------------------------------------------------
# 通用：跑一次包脚本（可指定脚本路径），捕获 stdout/stderr 到指定日志
#------------------------------------------------------------------------------
run_pkg() {  # run_pkg <pkg_script> <logfile> [env KEY=VAL ...]
    local pkg="$1"; local log="$2"; shift 2
    env "$@" bash "$pkg" > "$log" 2>&1
}

pkg_field() {  # pkg_field <log> <field>
    sed -n "s/^LSQ_VECTORS .*[[:space:]]$2=\\([0-9]\\+\\).*/\\1/p" "$1" | head -1
}

pkg_run_log() {  # pkg_run_log <pkgout_root>
    local f
    f="$(ls -1d -- "$1"/run-*/test_lsq.log 2>/dev/null | head -1)"
    [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
}

#==============================================================================
# B. 正控 / 反证 / 控制两边正确（full 模式）
#==============================================================================
if [ "$MODE" = "full" ]; then
    #   ---- B0：正式注册入口自证（manifest 里的那个脚本本身）----
    #   ★ 窄复审补充：REAL 相跑的是**活**包脚本/活 TB/活 env.sh ⇒ 必须在它前后对照
    #     冻结时的同一输入集合；否则“结果”与日志里记录（frozen）的 SHA 会错配。
    LIVE_SHA_PRE="$(shared_sha_of "$REPO_ROOT")" || fail "live_sha_failed_before_real"
    need_shared_hash "$LIVE_SHA_PRE" "$REPO_ROOT"
    note "LIVE_SHA_PRE = $LIVE_SHA_PRE"
    [ "$LIVE_SHA_PRE" = "$SHARED_SHA_PRE" ] || fail "live_source_changed_before_real"
    REAL_LOG="$DRV/real_fixed.log"
    run_pkg "$PKG_SH" "$REAL_LOG" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_real"
    REAL_RC=$?
    check_live_unchanged "$REPO_ROOT" "$LIVE_SHA_PRE" || fail "live_source_changed_during_real"
    note "REAL rc=$REAL_RC"
    [ "$REAL_RC" -eq 0 ] || fail "real_entry_rc=$REAL_RC"
    [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$REAL_LOG" || true)" = "1" ] || fail "real_entry_pass_anchor"
    [ "$(pkg_field "$REAL_LOG" fails)" = "0" ] || fail "real_entry_fails"
    [ "$(pkg_field "$REAL_LOG" defect)" = "0" ] || fail "real_entry_defect"
    [ "$(pkg_field "$REAL_LOG" xz)" = "0" ] || fail "real_entry_xz"

    #   ---- B1：冻结副本正控（fixed）----
    POS_LOG="$DRV/pos_fixed.log"
    run_pkg "$FRZ/sim/functional/test_lsq.sh" "$POS_LOG" \
        "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$FRZ/build/functional/lsq_pos"
    POS_RC=$?
    note "POS rc=$POS_RC"
    [ "$POS_RC" -eq 0 ] || fail "pos_rc=$POS_RC"
    [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$POS_LOG" || true)" = "1" ] || fail "pos_pass_anchor"
    [ "$(pkg_field "$POS_LOG" fails)" = "0" ] || fail "pos_fails=$(pkg_field "$POS_LOG" fails)"
    [ "$(pkg_field "$POS_LOG" defect)" = "0" ] || fail "pos_defect=$(pkg_field "$POS_LOG" defect)"
    [ "$(pkg_field "$POS_LOG" xz)" = "0" ] || fail "pos_xz=$(pkg_field "$POS_LOG" xz)"
    check_shared_unchanged "$FRZ" "$SHARED_SHA_PRE" || fail "shared_inputs_changed_after_pos"

    #   ---- B2：冻结副本反证（old）----
    NEG_LOG="$DRV/neg_old.log"
    run_pkg "$FRZ/sim/functional/test_lsq.sh" "$NEG_LOG" \
        "LSQ_EXPECT=old" "DUT_ROOT=$SNAP" "RV32_FUNCTIONAL_PKG_OUT_DIR=$FRZ/build/functional/lsq_neg"
    NEG_RC=$?
    note "NEG rc=$NEG_RC"
    [ "$NEG_RC" -eq 1 ] || fail "neg_rc=$NEG_RC expect=1"
    [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$NEG_LOG" || true)" = "0" ] || fail "neg_printed_pass"
    for r in F1 F2 F3 F4 F5; do
        grep -q "^FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=$r " "$NEG_LOG" || fail "neg_missing_root=$r"
    done
    grep -q 'reason=old_tree_defects_confirmed' "$NEG_LOG" || fail "neg_missing_reason"
    [ "$(pkg_field "$NEG_LOG" defect)" = "12" ] || fail "neg_defect=$(pkg_field "$NEG_LOG" defect)"
    [ "$(pkg_field "$NEG_LOG" xz)" = "0" ] || fail "neg_xz=$(pkg_field "$NEG_LOG" xz)"
    check_shared_unchanged "$FRZ" "$SHARED_SHA_PRE" || fail "shared_inputs_changed_after_neg"

    #   ---- B3：控制向量两边正确（逐向量证据取包内 run 日志）----
    POS_RUNLOG="$(pkg_run_log "$FRZ/build/functional/lsq_pos")"
    NEG_RUNLOG="$(pkg_run_log "$FRZ/build/functional/lsq_neg")"
    [ -n "$POS_RUNLOG" ] || fail "pos_runlog_missing"
    [ -n "$NEG_RUNLOG" ] || fail "neg_runlog_missing"
    note "POS_RUNLOG = $POS_RUNLOG"
    note "NEG_RUNLOG = $NEG_RUNLOG"
    [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$POS_RUNLOG" || true)" = "1" ] || fail "pos_runlog_pass_anchor"
    [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$NEG_RUNLOG" || true)" = "0" ] || fail "neg_runlog_pass_anchor"
    for dv in f1_lq_release_wrap63 f1_lq_release_multiwrap f1_stq_window_wrap63 \
              f1_squash_keeps_committed f1_flush_reclaim_no_dup_rsp f2_stq_slot_select32 \
              f3_flush_drains_cdq f4_split_low_no_release f5_cross_page_indep_pa \
              f5_cross_page_fault flush_wb_same_cycle flush_stq_xlate_act; do
        grep -q "^VEC [0-9]\+ $dv checks=[0-9]\+ fails=[1-9][0-9]* defect=1$" "$NEG_RUNLOG" \
            || fail "neg_defect_sig_missing vec=$dv"
    done
    for cv in f1_lq_no_release_neg f2_high_slot_drain_content f4_single_beat_retire \
              ctrl_no_forward_policy ctrl_young_indep_load xz_checker_selfcheck; do
        grep -q "^VEC [0-9]\+ $cv checks=[0-9]\+ fails=0 defect=0$" "$POS_RUNLOG" \
            || fail "pos_control_mismatch vec=$cv"
        grep -q "^VEC [0-9]\+ $cv checks=[0-9]\+ fails=0 defect=0$" "$NEG_RUNLOG" \
            || fail "neg_control_mismatch vec=$cv"
    done

    #   ---- B4：私有快照/冻结输入不可变复核 ----
    B4_CUR_SHA="$(sha_of "$CUR/rtl/back2/lsq_simple.v")" || fail "sha256_failed b4_cur"
    need_hash "$B4_CUR_SHA" "$CUR/rtl/back2/lsq_simple.v"
    B4_LIVE_SHA="$(sha_of "$REPO_ROOT/rtl/back2/lsq_simple.v")" || fail "sha256_failed b4_live"
    need_hash "$B4_LIVE_SHA" "$REPO_ROOT/rtl/back2/lsq_simple.v"
    [ "$B4_CUR_SHA" = "$B4_LIVE_SHA" ] || fail "deps_cur_lsq_changed"
    check_shared_unchanged "$FRZ" "$SHARED_SHA_PRE" || fail "shared_inputs_changed_final"
fi

#==============================================================================
# C. 包装器自检（私有 fixture；要求精确 reason + 期望 rc + 无 PASS）
#==============================================================================
ST_FAIL=0
selftest_start() { ST_NAME="$1"; ST_WANT="$2"; ST_LOG="$DRV/st_$1.log"; }
selftest_check() {  # selftest_check <rc> <want_reason|PASS>
    local rc="$1" want="$2"
    local ok=1
    if [ "$want" = "PASS" ]; then
        [ "$rc" -eq 0 ] || ok=0
        [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$ST_LOG" || true)" = "1" ] || ok=0
    else
        [ "$rc" -ne 0 ] || ok=0
        grep -q "reason=$ST_WANT" "$ST_LOG" || ok=0
        [ "$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$ST_LOG" || true)" = "0" ] || ok=0
    fi
    note "SELFTEST $ST_NAME rc=$rc want=$ST_WANT ok=$ok"
    cat -- "$ST_LOG" >&3
    printf 'LSQ_SELFTEST case=%s rc=%s want_reason=%s ok=%s\n' "$ST_NAME" "$rc" "$ST_WANT" "$ok"
    [ "$ok" = "1" ] || ST_FAIL=1
}

FAKE="$DRV/fake"
mkdir -p -- "$FAKE" || fail "fake_mkdir_failed"
REAL_VVP="$(command -v vvp || true)"
[ -n "$REAL_VVP" ] && [ -x "$REAL_VVP" ] || fail "real_vvp_missing"

#   1) 编译失败：DUT 根本身语法错误（私有 fixture）
BAD_DUT="$DRV/bad_dut/rtl/back2"
mkdir -p -- "$BAD_DUT" || fail "bad_dut_mkdir_failed"
cp -- "$CUR/rtl/back2/back2_params.vh" "$BAD_DUT/back2_params.vh" || fail "bad_dut_hdr_copy"
printf 'module lsq_simple; this is not verilog ; endmodule\n' > "$BAD_DUT/lsq_simple.v"
selftest_start compile_rc compile_rc
run_pkg "$PKG_SH" "$ST_LOG" "DUT_ROOT=$DRV/bad_dut" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st1"
selftest_check $? "$ST_WANT"

#   2) rc=0 但零 vvp 产物
cat > "$FAKE/iv_noout.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$FAKE/iv_noout.sh"
selftest_start no_vvp compile_no_vvp_output
run_pkg "$PKG_SH" "$ST_LOG" "RV32_IVERILOG=$FAKE/iv_noout.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st2"
selftest_check $? "$ST_WANT"

#   3) 运行非零退出
cat > "$FAKE/vvp_false.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod 755 "$FAKE/vvp_false.sh"
selftest_start run_rc run_rc=7
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_false.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st3"
selftest_check $? "$ST_WANT"

#   4) 缺摘要行（垃圾输出但 rc=0）
cat > "$FAKE/vvp_junk.sh" <<'EOF'
#!/usr/bin/env bash
echo "no summary here"
exit 0
EOF
chmod 755 "$FAKE/vvp_junk.sh"
selftest_start no_summary summary_count=0
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_junk.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st4"
selftest_check $? "$ST_WANT"

#   5) 合法摘要 + 注入 FAIL 行（必须被拒）
cat > "$FAKE/vvp_fail.sh" <<EOF
#!/usr/bin/env bash
"$REAL_VVP" "\$@"
rc=\$?
echo "injected FAIL line"
exit \$rc
EOF
chmod 755 "$FAKE/vvp_fail.sh"
selftest_start log_fail log_has_FAIL
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_fail.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st5"
selftest_check $? "$ST_WANT"

#   6) 合法摘要 + 注入 DEFECT_REPRODUCED 行（必须被拒）
cat > "$FAKE/vvp_defect.sh" <<EOF
#!/usr/bin/env bash
"$REAL_VVP" "\$@"
rc=\$?
echo "injected DEFECT_REPRODUCED marker"
exit \$rc
EOF
chmod 755 "$FAKE/vvp_defect.sh"
selftest_start log_defect log_has_defect_reproduced
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_defect.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st6"
selftest_check $? "$ST_WANT"

#   7) 少向量（摘要 total=16 但只 14 条 VEC 行 ⇒ 必须被拒）
cat > "$FAKE/vvp_short.sh" <<'EOF'
#!/usr/bin/env bash
echo "LSQ_VECTORS total=18 nonzero=18 checks=285 fails=0 defect=0 xz=0"
i=1
while [ $i -le 13 ]; do echo "VEC $i short_vec$i checks=2 fails=0 defect=0"; i=$((i+1)); done
echo "VEC 14 short_vec14 checks=259 fails=0 defect=0"
exit 0
EOF
chmod 755 "$FAKE/vvp_short.sh"
selftest_start short_vecs vec_line_count=14
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_short.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st7"
selftest_check $? "$ST_WANT"

#   8) 毒 cwd 但 DUT_ROOT 正确 ⇒ **必须正常 PASS**（真源只来自 DUT_ROOT 子 shell）
POISON="$DRV/poison_cwd"
mkdir -p -- "$POISON/rtl/back2" || fail "poison_mkdir_failed"
cp -- "$CUR/rtl/back2/back2_params.vh" "$POISON/rtl/back2/back2_params.vh" || fail "poison_hdr_copy"
chmod u+w -- "$POISON/rtl/back2/back2_params.vh" || fail "poison_hdr_chmod"
printf '`define BACK2_STQ_N 8\n' >> "$POISON/rtl/back2/back2_params.vh"
selftest_start poison_cwd PASS
( cd -- "$POISON" && run_pkg "$PKG_SH" "$ST_LOG" "DUT_ROOT=$CUR" \
      "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st8" )
selftest_check $? "$ST_WANT"

#   9) 重复 ID（VEC 2 改成 VEC 1 ⇒ 缺 2）必须被拒
cat > "$FAKE/vvp_dupid.sh" <<EOF
#!/usr/bin/env bash
"$REAL_VVP" "\$@" | sed 's/^VEC 2 /VEC 1 /'
exit \${PIPESTATUS[0]}
EOF
chmod 755 "$FAKE/vvp_dupid.sh"
selftest_start dup_id vec_ids_not_1_to_N
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_dupid.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st9"
selftest_check $? "$ST_WANT"

#   10) 错名（改名但 checks 不变）必须被拒
cat > "$FAKE/vvp_badname.sh" <<EOF
#!/usr/bin/env bash
"$REAL_VVP" "\$@" | sed 's/f1_lq_no_release_neg/WRONG_VEC_NAME/'
exit \${PIPESTATUS[0]}
EOF
chmod 755 "$FAKE/vvp_badname.sh"
selftest_start bad_name spec_table_mismatch
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_badname.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st10"
selftest_check $? "$ST_WANT"

#   11) 零检查 + 别例补偿 checksum（总 checks 不变）必须被拒
cat > "$FAKE/vvp_zerochk.sh" <<EOF
#!/usr/bin/env bash
"$REAL_VVP" "\$@" | awk '{ if (\$1=="VEC" && \$2==1) sub(/checks=[0-9]+/,"checks=0"); else if (\$1=="VEC" && \$2==16) sub(/checks=[0-9]+/,"checks=6"); print }'
exit \${PIPESTATUS[0]}
EOF
chmod 755 "$FAKE/vvp_zerochk.sh"
selftest_start zero_checks vec_zero_checks
run_pkg "$PKG_SH" "$ST_LOG" "RV32_VVP=$FAKE/vvp_zerochk.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st11"
selftest_check $? "$ST_WANT"

#   12) 阶段间共享 TB 被改必须拒（私有 fixture：拷贝冻结输入 → 改 TB → 同一检测器必须判不一致）
FIX="$DRV/fixture_shared"
mkdir -p -- "$FIX/sim/functional" "$FIX/scripts" || fail "fixture_mkdir_failed"
cp -- "$FRZ/sim/functional/test_lsq.sh" "$FIX/sim/functional/test_lsq.sh" || fail "fixture_pkg_copy"
cp -- "$FRZ/sim/functional/tb_lsq_semantics.sv" "$FIX/sim/functional/tb_lsq_semantics.sv" || fail "fixture_tb_copy"
cp -- "$FRZ/scripts/env.sh" "$FIX/scripts/env.sh" || fail "fixture_env_copy"
chmod u+w -- "$FIX/sim/functional/tb_lsq_semantics.sv" || fail "fixture_tb_chmod"
FIX_SHA_PRE="$(shared_sha_of "$FIX")" || fail "fixture_shared_sha_failed"
need_shared_hash "$FIX_SHA_PRE" "$FIX"
printf '\n// fixture mutation (must be rejected)\n' >> "$FIX/sim/functional/tb_lsq_semantics.sv"
if check_shared_unchanged "$FIX" "$FIX_SHA_PRE"; then
    note "SELFTEST shared_tb_change detector failed to notice mutation"
    printf 'LSQ_SELFTEST case=shared_tb_change rc=0 want_reason=shared_tb_changed ok=0\n'
    ST_FAIL=1
else
    note "SELFTEST shared_tb_change detector rejected mutation"
    printf 'LSQ_SELFTEST case=shared_tb_change rc=1 want_reason=shared_tb_changed ok=1\n'
fi

#   13) 哈希清单：3 条**合法**行后工具 rc=9 ⇒ 必须按原始 rc 拒（旧管道会吞 rc）
REAL_SHA="$(command -v sha256sum || true)"
[ -n "$REAL_SHA" ] && [ -x "$REAL_SHA" ] || fail "real_sha256sum_missing"
SHA_RC9_DIR="$DRV/fake_sha_rc9"
mkdir -p -- "$SHA_RC9_DIR" || fail "fake_sha_rc9_mkdir"
cat > "$SHA_RC9_DIR/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@"
exit 9
EOF
chmod 755 -- "$SHA_RC9_DIR/sha256sum"
selftest_start sha_rc9 sha256sum_rc=9
run_pkg "$PKG_SH" "$ST_LOG" "PATH=$SHA_RC9_DIR:$PATH" \
    "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st13"
selftest_check $? "$ST_WANT"

#   14) 少一条共享哈希（3 条固定路径只回 2 行）⇒ 必须拒
SHA_SHORT_DIR="$DRV/fake_sha_short"
mkdir -p -- "$SHA_SHORT_DIR" || fail "fake_sha_short_mkdir"
cat > "$SHA_SHORT_DIR/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@" | head -2
exit 0
EOF
chmod 755 -- "$SHA_SHORT_DIR/sha256sum"
selftest_start sha_short sha256_lines=2
run_pkg "$PKG_SH" "$ST_LOG" "PATH=$SHA_SHORT_DIR:$PATH" \
    "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st14"
selftest_check $? "$ST_WANT"

#   15) +LSQ_XZ_PROBE 正控（未变异）：真实 chk 收 X/Z + 私有观测替身注 X/Z ⇒ gate 必须
#       以精确 reason 拒绝（证明 checker/monitor/有效字段口径真的会拦）。
cat > "$FAKE/vvp_probe.sh" <<EOF
#!/usr/bin/env bash
"$REAL_VVP" "\$@" +LSQ_XZ_PROBE
EOF
chmod 755 -- "$FAKE/vvp_probe.sh"
selftest_start xz_probe xz_probe_tripped
run_pkg "$FRZ/sim/functional/test_lsq.sh" "$ST_LOG" \
    "RV32_VVP=$FAKE/vvp_probe.sh" "DUT_ROOT=$CUR" \
    "RV32_FUNCTIONAL_PKG_OUT_DIR=$FRZ/build/functional/xzprobe"
selftest_check $? "$ST_WANT"

#   16-18) 变异杀伤：只改**私有 fixture**（弱化 chk / 删除 monitor / 破坏有效字段口径），
#       探针必须给出 `XZ_PROBE_MISS` 且对应字段为 0 ⇒ gate 以 `xz_probe_miss` 拒。
xz_mut_case() {  # xz_mut_case <name> <sed-expr> <expected-miss-field>
    local nm="$1" sx="$2" field="$3" fix rc runlog
    fix="$DRV/xzfix_$nm"
    mkdir -p -- "$fix/sim/functional" "$fix/scripts" || fail "xzfix_${nm}_mkdir"
    cp -- "$FRZ/sim/functional/test_lsq.sh" "$fix/sim/functional/test_lsq.sh" || fail "xzfix_${nm}_pkg"
    cp -- "$FRZ/sim/functional/tb_lsq_semantics.sv" "$fix/sim/functional/tb_lsq_semantics.sv" || fail "xzfix_${nm}_tb"
    cp -- "$FRZ/scripts/env.sh" "$fix/scripts/env.sh" || fail "xzfix_${nm}_env"
    chmod u+w -- "$fix/sim/functional/tb_lsq_semantics.sv" || fail "xzfix_${nm}_chmod"
    sed -i "$sx" "$fix/sim/functional/tb_lsq_semantics.sv" || fail "xzfix_${nm}_sed"
    if cmp -s -- "$FRZ/sim/functional/tb_lsq_semantics.sv" "$fix/sim/functional/tb_lsq_semantics.sv"; then
        note "SELFTEST $nm mutation_not_applied"
        printf 'LSQ_SELFTEST case=%s rc=- want_reason=xz_probe_miss ok=0\n' "$nm"
        ST_FAIL=1
        return
    fi
    selftest_start "$nm" xz_probe_miss
    run_pkg "$fix/sim/functional/test_lsq.sh" "$ST_LOG" \
        "RV32_VVP=$FAKE/vvp_probe.sh" "DUT_ROOT=$CUR" \
        "RV32_FUNCTIONAL_PKG_OUT_DIR=$fix/build/functional/xzprobe"
    rc=$?
    selftest_check "$rc" "$ST_WANT"
    runlog="$(pkg_run_log "$fix/build/functional/xzprobe")"
    if [ -n "$runlog" ] && grep -q "XZ_PROBE_MISS .*$field" "$runlog"; then
        note "SELFTEST $nm field=$field observed"
    else
        note "SELFTEST $nm missing_field=$field runlog=${runlog:-none}"
        printf 'LSQ_SELFTEST case=%s rc=%s want_reason=xz_probe_miss field=%s ok=0\n' "$nm" "$rc" "$field"
        ST_FAIL=1
    fi
}
xz_mut_case weak_chk "s|if (ok !== 1'b1) begin|if (!ok) begin|" "chk=0"
xz_mut_case no_monitor "s|always @(posedge clk) if (xz_hit === 1'b1) g_xz <= g_xz + 1;|always @(posedge clk) begin end|" "mon=0"
xz_mut_case bad_gate "s|((wen !== 1'b1) \\|\\| (is_known(w32) && is_known(s32)))|(is_known(w32) \\&\\& is_known(s32))|" "dc=0"

#   20) 单文件哈希：真实正常 1 行输出后工具 rc=9 ⇒ `sha_of` 必须失败（不是空值通过）
SHA1_RC9_DIR="$DRV/fake_sha1_rc9"
mkdir -p -- "$SHA1_RC9_DIR" || fail "fake_sha1_rc9_mkdir"
cat > "$SHA1_RC9_DIR/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@"
exit 9
EOF
chmod 755 -- "$SHA1_RC9_DIR/sha256sum"
( PATH="$SHA1_RC9_DIR:$PATH"; sha_of "$CUR/rtl/back2/lsq_simple.v" ) \
    > "$DRV/st_sha_file_rc9.log" 2>&1
SHA1_RC=$?
if [ "$SHA1_RC" -ne 0 ] && grep -q 'reason=sha256_failed' "$DRV/st_sha_file_rc9.log"; then
    note "SELFTEST sha_file_rc9 rejected rc=$SHA1_RC"
    printf 'LSQ_SELFTEST case=sha_file_rc9 rc=%s want_reason=sha256_failed ok=1\n' "$SHA1_RC"
else
    note "SELFTEST sha_file_rc9 NOT rejected rc=$SHA1_RC"
    printf 'LSQ_SELFTEST case=sha_file_rc9 rc=%s want_reason=sha256_failed ok=0\n' "$SHA1_RC"
    ST_FAIL=1
fi

#   19) REAL 相活源变动必须拒（私有 fixture：同一检测器两次调用之间改 TB）
LIVEFIX="$DRV/fixture_live"
mkdir -p -- "$LIVEFIX/sim/functional" "$LIVEFIX/scripts" || fail "livefix_mkdir"
cp -- "$FRZ/sim/functional/test_lsq.sh" "$LIVEFIX/sim/functional/test_lsq.sh" || fail "livefix_pkg"
cp -- "$FRZ/sim/functional/tb_lsq_semantics.sv" "$LIVEFIX/sim/functional/tb_lsq_semantics.sv" || fail "livefix_tb"
cp -- "$FRZ/scripts/env.sh" "$LIVEFIX/scripts/env.sh" || fail "livefix_env"
chmod u+w -- "$LIVEFIX/sim/functional/tb_lsq_semantics.sv" || fail "livefix_chmod"
LIVEFIX_SHA="$(shared_sha_of "$LIVEFIX")" || fail "livefix_sha_failed"
need_shared_hash "$LIVEFIX_SHA" "$LIVEFIX"
check_live_unchanged "$LIVEFIX" "$LIVEFIX_SHA" || { note "SELFTEST live_source_change baseline mismatch"; ST_FAIL=1; }
printf '\n// live-source mutation (must be rejected)\n' >> "$LIVEFIX/sim/functional/tb_lsq_semantics.sv"
if check_live_unchanged "$LIVEFIX" "$LIVEFIX_SHA"; then
    note "SELFTEST live_source_change detector failed to notice mutation"
    printf 'LSQ_SELFTEST case=live_source_change rc=0 want_reason=live_source_changed ok=0\n'
    ST_FAIL=1
else
    note "SELFTEST live_source_change detector rejected mutation"
    printf 'LSQ_SELFTEST case=live_source_change rc=1 want_reason=live_source_changed ok=1\n'
fi

[ "$ST_FAIL" = "0" ] || fail "selftest_failed"

#==============================================================================
# D. 结论
#==============================================================================
if [ "$MODE" = "full" ]; then
    printf 'LSQ_DRIVER: positive=ok negative=ok control=ok frozen_inputs=immutable selftest=ok\n'
else
    printf 'LSQ_DRIVER: selftest=ok\n'
fi
printf 'LSQ_DRIVER: PASS\n'
note "LSQ_DRIVER: PASS"
exit 0
