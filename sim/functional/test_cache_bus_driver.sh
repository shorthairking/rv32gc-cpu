#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_cache_bus_driver.sh —— F3 包**反证驱动**（旧树红 / 新树绿 / 控制两边正确）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二）
# 依赖 : sim/functional/test_cache_bus.sh（包入口，唯一 FUNCTIONAL_CACHE_BUS: PASS 锚点来源）
#
# 做什么（默认全跑；`--self-test` 只跑包装器杀伤路径自检）：
#   1) **私有不可变基线快照**：用 `git show <BASE>:` 取出 201acf61 的**最小依赖集**
#      （l1d.v / l1i.v / axi_master_ctrl.v / cache_tag_array.v / cache_array_bram.v /
#        rv32_defs.vh / core_params.vh）到本次独占 run 目录（不递归复制 build、
#      不碰工作树），chmod 444 并记录/复核 sha256（运行前后一致）。
#       —— 快照含**完整实际头文件**，编译用 `-I <快照根>`，不借调用 cwd、
#          也不 fallback 到活树头文件。
#   2) **正控（新树）**：DUT_ROOT=<当前工作树> 跑 test_cache_bus.sh（默认 fixed 口径）
#      ⇒ 必须 rc=0、唯一 PASS 锚点、fails=0 defect=0、冻结规格精确。
#   3) **反证（旧树）**：DUT_ROOT=<基线快照>、CACHE_BUS_EXPECT=old 跑**同一 TB**
#      ⇒ 必须 rc=1、**不得**出现 PASS 锚点、3 个根因的 DEFECT_REPRODUCED 行齐全、
#      逐向量 defect 签名齐全、fails>0。
#   4) **控制两边正确**：对两棵树都校验控制向量的 fails=0 defect=0
#      （否则"修复"可能只是放宽判据）。
#   5) **包装器自检**：注入 编译失败 / 空 vvp / 运行非零 / 缺摘要 / 日志含 FAIL /
#      日志含 DEFECT_REPRODUCED / 少向量 七类反例，逐一要求**精确 reason + rc≠0 + 无 PASS**。
#
# 产物纪律：产物根固定在本仓库 build/functional/ 授权树内（或父入口传入的 PKGOUT），
#          每次 mktemp -d 独占 run 目录，**不做任何 rm**。
# 工具真源：scripts/env.sh（只读）；本驱动只经 test_cache_bus.sh 间接使用 iverilog/vvp。
#
# 用法 : bash sim/functional/test_cache_bus_driver.sh
#        bash sim/functional/test_cache_bus_driver.sh --self-test
#        CACHE_BUS_BASELINE_COMMIT=<sha> bash sim/functional/test_cache_bus_driver.sh
#==============================================================================
set -u

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'CACHE_BUS_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'CACHE_BUS_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }
PKG_SH="$SELF_DIR/test_cache_bus.sh"
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'CACHE_BUS_DRIVER: FAIL reason=auth_root_readlink_failed\n'; exit 1; }

MODE="full"
if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    MODE="selftest"
elif [ "$#" -ne 0 ]; then
    printf 'CACHE_BUS_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi

[ -f "$PKG_SH" ] || { printf 'CACHE_BUS_DRIVER: FAIL reason=pkg_missing path=%s\n' "$PKG_SH"; exit 1; }

ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/cache-bus-driver}"
case "$(readlink -m -- "$ROOT_RAW")" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) printf 'CACHE_BUS_DRIVER: FAIL reason=out_root_unauthorized root=%s\n' "$ROOT_RAW"; exit 1 ;;
esac
mkdir -p -- "$(readlink -m -- "$ROOT_RAW")" || {
    printf 'CACHE_BUS_DRIVER: FAIL reason=out_root_mkdir_failed\n'; exit 1; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")"
DRV="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || {
    printf 'CACHE_BUS_DRIVER: FAIL reason=mktemp_run_dir_failed root=%s\n' "$ROOT_NORM"; exit 1; }

DRV_LOG="$DRV/driver.log"
: > "$DRV_LOG" || { printf 'CACHE_BUS_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }
exec 3>>"$DRV_LOG"

note() { printf '%s\n' "$*" >&3; }

fail() {
    note "DRIVER_FAIL reason=$1"
    printf 'CACHE_BUS_DRIVER: FAIL reason=%s run_dir=%s\n' "$1" "$DRV"
    exit 1
}

note "==== test_cache_bus_driver.sh ===="
note "date       = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT  = $REPO_ROOT"
note "DRV        = $DRV"
note "MODE       = $MODE"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    note "GIT_HEAD   = $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
note "L1D_SHA    = $(sha256sum -- "$REPO_ROOT/rtl/cache/l1d.v" | awk '{print $1}')"
note "L1I_SHA    = $(sha256sum -- "$REPO_ROOT/rtl/cache/l1i.v" | awk '{print $1}')"
note "AXI_SHA    = $(sha256sum -- "$REPO_ROOT/rtl/axi/axi_master_ctrl.v" | awk '{print $1}')"
note "TB_SHA     = $(sha256sum -- "$SELF_DIR/tb_cache_bus_semantics.sv" | awk '{print $1}')"
note "PKG_SHA    = $(sha256sum -- "$PKG_SH" | awk '{print $1}')"

# 基线依赖清单（最小集；含完整实际头）
BASE_FILES="rtl/cache/l1d.v rtl/cache/l1i.v rtl/cache/cache_tag_array.v \
rtl/cache/cache_array_bram.v rtl/axi/axi_master_ctrl.v rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh"

#==============================================================================
# A. 基线快照（不可变；git show 提取，不递归 build）
#==============================================================================
BASE_COMMIT="${CACHE_BUS_BASELINE_COMMIT:-201acf61}"
SNAP="$DRV/deps_base"
CUR="$DRV/deps_cur"

snapshot_sha() {  # snapshot_sha <root>
    local r="$1" f out=""
    for f in $BASE_FILES; do
        out="$out$(sha256sum -- "$r/$f" | awk '{print $1}') "
    done
    printf '%s' "$out"
}

if [ "$MODE" = "full" ]; then
    git -C "$REPO_ROOT" cat-file -e "${BASE_COMMIT}^{commit}" 2>>"$DRV_LOG" \
        || fail "baseline_commit_missing commit=$BASE_COMMIT"
    #   ---- 当前树（被测修复）的**私有不可变快照**：与其它域并发改动隔离 ----
    for f in $BASE_FILES; do
        mkdir -p -- "$CUR/$(dirname -- "$f")" || fail "cur_snapshot_mkdir_failed"
        cp -- "$REPO_ROOT/$f" "$CUR/$f" || fail "cur_snapshot_copy f=$f"
        chmod 444 -- "$CUR/$f" || fail "cur_snapshot_chmod f=$f"
        [ "$(sha256sum -- "$REPO_ROOT/$f" | awk '{print $1}')" = \
          "$(sha256sum -- "$CUR/$f" | awk '{print $1}')" ] || fail "cur_snapshot_mismatch f=$f"
    done
    CUR_SHA_PRE="$(snapshot_sha "$CUR")"
    note "CUR        = $CUR"
    note "CUR_SHA    = $CUR_SHA_PRE"
    #   ---- 旧树基线快照（git show 提取；不递归 build、不碰工作树）----
    for f in $BASE_FILES; do
        mkdir -p -- "$SNAP/$(dirname -- "$f")" || fail "snapshot_mkdir_failed"
        git -C "$REPO_ROOT" show "${BASE_COMMIT}:$f" > "$SNAP/$f" 2>>"$DRV_LOG" \
            || fail "snapshot_extract_failed f=$f"
        [ -s "$SNAP/$f" ] || fail "snapshot_empty f=$f"
        chmod 444 -- "$SNAP/$f" || fail "snapshot_chmod_failed f=$f"
    done
    SNAP_SHA_PRE="$(snapshot_sha "$SNAP")"
    note "SNAP       = $SNAP"
    note "SNAP_COMMIT= $BASE_COMMIT"
    note "SNAP_SHA   = $SNAP_SHA_PRE"
    [ "$SNAP_SHA_PRE" != "$CUR_SHA_PRE" ] || fail "snapshot_identical_to_cur (nothing to prove)"
fi

#------------------------------------------------------------------------------
# 通用：跑一次 test_cache_bus.sh，捕获 stdout/stderr 到指定日志
#------------------------------------------------------------------------------
run_pkg() {  # run_pkg <logfile> [env...]
    local log="$1"; shift
    env "$@" bash "$PKG_SH" > "$log" 2>&1
}

pkg_field() {  # pkg_field <log> <field>
    sed -n "s/^CACHE_BUS_VECTORS .*[[:space:]]$2=\([0-9]\+\).*/\1/p" "$1" | head -1
}

pkg_run_log() {  # pkg_run_log <pkgout_root>
    local f
    f="$(ls -1d -- "$1"/run-*/test_cache_bus.log 2>/dev/null | head -1)"
    [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
}

#==============================================================================
# B. 正控（新树 fixed）+ 反证（旧树 old）
#==============================================================================
if [ "$MODE" = "full" ]; then
    POS_LOG="$DRV/pos_fixed.log"
    run_pkg "$POS_LOG" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_pos"
    POS_RC=$?
    note "POS rc=$POS_RC"
    cat -- "$POS_LOG" >&3
    [ "$POS_RC" -eq 0 ] || fail "pos_rc=$POS_RC"
    [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$POS_LOG" || true)" = "1" ] || fail "pos_pass_anchor"
    [ "$(pkg_field "$POS_LOG" fails)" = "0" ] || fail "pos_fails=$(pkg_field "$POS_LOG" fails)"
    [ "$(pkg_field "$POS_LOG" defect)" = "0" ] || fail "pos_defect=$(pkg_field "$POS_LOG" defect)"

    #   ---- 反证（旧树 old）----
    NEG_LOG="$DRV/neg_old.log"
    run_pkg "$NEG_LOG" "CACHE_BUS_EXPECT=old" "DUT_ROOT=$SNAP" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_old"
    NEG_RC=$?
    note "NEG rc=$NEG_RC"
    cat -- "$NEG_LOG" >&3
    [ "$NEG_RC" -eq 1 ] || fail "neg_rc=$NEG_RC expect=1"
    [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$NEG_LOG" || true)" = "0" ] || fail "neg_printed_pass"
    for r in 04-04 04-05 04-07; do
        grep -q "^FUNCTIONAL_CACHE_BUS: DEFECT_REPRODUCED root=$r " "$NEG_LOG" \
            || fail "neg_missing_root=$r"
    done
    grep -q 'reason=old_tree_defects_confirmed' "$NEG_LOG" || fail "neg_missing_reason"
    [ "$(pkg_field "$NEG_LOG" defect)" = "11" ] || fail "neg_defect=$(pkg_field "$NEG_LOG" defect)"

    #   ---- 控制向量两边正确（逐向量证据取包内 run 日志）----
    POS_RUNLOG="$(pkg_run_log "$DRV/pkg_pos")"
    NEG_RUNLOG="$(pkg_run_log "$DRV/pkg_old")"
    [ -n "$POS_RUNLOG" ] || fail "pos_runlog_missing"
    [ -n "$NEG_RUNLOG" ] || fail "neg_runlog_missing"
    note "POS_RUNLOG = $POS_RUNLOG"
    note "NEG_RUNLOG = $NEG_RUNLOG"
    [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$POS_RUNLOG" || true)" = "1" ] || fail "pos_runlog_pass_anchor"
    [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$NEG_RUNLOG" || true)" = "0" ] || fail "neg_runlog_pass_anchor"
    for dv in wb_first_valid_zero_delay wb_two_victims_distinct wb_accept_delay3 \
              axi_split_read_single_done axi_split_write_single_done \
              l1i_fill_err_early l1i_fill_err_last l1i_two_err_lines_alternate \
              l1d_fill_err_mid l1d_wb_b_fail_keeps_dirty l1d_maint_clean_b_fail; do
        grep -q "^VEC [0-9]\+ $dv checks=[0-9]\+ fails=[1-9][0-9]* defect=1$" "$NEG_RUNLOG" \
            || fail "neg_defect_sig_missing vec=$dv"
    done
    for cv in ctrl_wb_clean_no_req ctrl_axi_nonsplit_single_done ctrl_l1d_fill_hit; do
        grep -q "^VEC [0-9]\+ $cv checks=[0-9]\+ fails=0 defect=0$" "$POS_RUNLOG" \
            || fail "pos_control_mismatch vec=$cv"
        grep -q "^VEC [0-9]\+ $cv checks=[0-9]\+ fails=0 defect=0$" "$NEG_RUNLOG" \
            || fail "neg_control_mismatch vec=$cv"
    done

    #   ---- 快照不可变复核 ----
    SNAP_SHA_POST="$(snapshot_sha "$SNAP")"
    [ "$SNAP_SHA_PRE" = "$SNAP_SHA_POST" ] || fail "snapshot_modified"
    CUR_SHA_POST="$(snapshot_sha "$CUR")"
    [ "$CUR_SHA_PRE" = "$CUR_SHA_POST" ] || fail "cur_snapshot_modified"
fi

#==============================================================================
# C. 包装器自检（注入七类反例；要求精确 reason + rc≠0 + 无 PASS）
#==============================================================================
ST_FAIL=0
selftest_start() { ST_NAME="$1"; ST_WANT="$2"; ST_LOG="$DRV/st_$1.log"; }
selftest_check() {  # selftest_check <rc>
    local rc="$1"
    local ok=1
    if [ "$rc" -eq 0 ]; then ok=0; fi
    grep -q "reason=$ST_WANT" "$ST_LOG" || ok=0
    if [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$ST_LOG" || true)" != "0" ]; then ok=0; fi
    note "SELFTEST $ST_NAME rc=$rc want=$ST_WANT ok=$ok"
    cat -- "$ST_LOG" >&3
    printf 'CACHE_BUS_SELFTEST case=%s rc=%s want_reason=%s ok=%s\n' "$ST_NAME" "$rc" "$ST_WANT" "$ok"
    [ "$ok" = "1" ] || ST_FAIL=1
}

FAKE="$DRV/fake"
mkdir -p -- "$FAKE" || fail "fake_mkdir_failed"
REAL_VVP="$(command -v vvp || true)"
[ -n "$REAL_VVP" ] && [ -x "$REAL_VVP" ] || fail "real_vvp_missing"

#   1) 编译失败：DUT 根本身语法错误（同时保留头，确保失败原因是 rc 而非缺文件）
BAD_DUT="$DRV/bad_dut"
for f in $BASE_FILES; do
    mkdir -p -- "$BAD_DUT/$(dirname -- "$f")"
done
cp -- "$REPO_ROOT/rtl/pkg/rv32_defs.vh"   "$BAD_DUT/rtl/pkg/rv32_defs.vh"
cp -- "$REPO_ROOT/rtl/pkg/core_params.vh" "$BAD_DUT/rtl/pkg/core_params.vh"
cp -- "$REPO_ROOT/rtl/cache/l1i.v"              "$BAD_DUT/rtl/cache/l1i.v"
cp -- "$REPO_ROOT/rtl/cache/cache_tag_array.v"  "$BAD_DUT/rtl/cache/cache_tag_array.v"
cp -- "$REPO_ROOT/rtl/cache/cache_array_bram.v" "$BAD_DUT/rtl/cache/cache_array_bram.v"
cp -- "$REPO_ROOT/rtl/axi/axi_master_ctrl.v"    "$BAD_DUT/rtl/axi/axi_master_ctrl.v"
printf 'module l1d; this is not verilog ; endmodule\n' > "$BAD_DUT/rtl/cache/l1d.v"
selftest_start compile_rc compile_rc
run_pkg "$ST_LOG" "DUT_ROOT=$BAD_DUT" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st1"
selftest_check $?

#   2) rc=0 但零 vvp 产物
cat > "$FAKE/iv_noout.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$FAKE/iv_noout.sh"
selftest_start no_vvp compile_no_vvp_output
run_pkg "$ST_LOG" "RV32_IVERILOG=$FAKE/iv_noout.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st2"
selftest_check $?

#   3) 运行非零退出
cat > "$FAKE/vvp_false.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod 755 "$FAKE/vvp_false.sh"
selftest_start run_rc run_rc=7
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_false.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st3"
selftest_check $?

#   4) 缺摘要行（垃圾输出但 rc=0）
cat > "$FAKE/vvp_junk.sh" <<'EOF'
#!/usr/bin/env bash
echo "no summary here"
exit 0
EOF
chmod 755 "$FAKE/vvp_junk.sh"
selftest_start no_summary summary_count=0
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_junk.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st4"
selftest_check $?

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
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_fail.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st5"
selftest_check $?

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
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_defect.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st6"
selftest_check $?

#   7) 少向量（摘要 total=14 但只有 13 条 VEC 行 ⇒ 必须被拒）
cat > "$FAKE/vvp_short.sh" <<'EOF'
#!/usr/bin/env bash
echo "CACHE_BUS_VECTORS total=14 nonzero=14 checks=249 fails=0 defect=0"
i=1
while [ $i -le 12 ]; do echo "VEC $i short_vec$i checks=2 fails=0 defect=0"; i=$((i+1)); done
echo "VEC 13 short_vec13 checks=225 fails=0 defect=0"
exit 0
EOF
chmod 755 "$FAKE/vvp_short.sh"
selftest_start short_vecs vec_line_count=13
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_short.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st7"
selftest_check $?

[ "$ST_FAIL" = "0" ] || fail "selftest_failed"

#==============================================================================
# D. 结论
#==============================================================================
if [ "$MODE" = "full" ]; then
    printf 'CACHE_BUS_DRIVER: positive=ok negative=ok control=ok snapshot=immutable selftest=ok\n'
else
    printf 'CACHE_BUS_DRIVER: selftest=ok\n'
fi
printf 'CACHE_BUS_DRIVER: PASS\n'
note "CACHE_BUS_DRIVER: PASS"
exit 0
