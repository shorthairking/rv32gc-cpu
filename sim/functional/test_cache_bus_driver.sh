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
#        rv32_defs.vh / core_params.vh = 7 个）+ TB 恒取本包。快照落本次独占 run 目录
#      （不递归复制 build、不碰工作树），chmod 444 并记录/复核 sha256（运行前后一致）。
#      ★ `snapshot_sha` 的 rc **原样传播**（不经管道吞掉）；哈希块必须"恰好 7 行且全为
#        64 位 hex"，多一行坏行也必须拒。
#   2) **正控（新树）**：DUT_ROOT=<当前树私有快照> 跑 test_cache_bus.sh（fixed 口径）
#      ⇒ 必须 rc=0、唯一 PASS 锚点、逐向量规格精确。
#   3) **反证（旧树）**：DUT_ROOT=<基线快照>、CACHE_BUS_EXPECT=old 跑**同一 TB**
#      ⇒ 必须 rc=1、**不得**出现 PASS 锚点、3 个根因的 DEFECT_REPRODUCED 行齐全、
#      逐向量 defect 签名齐全、fails>0。
#   4) **输入一致性**：两次运行必须使用**同一 TB / 同一包脚本 / 同一 env**，且包日志里
#      记录的 TB SHA 必须等于仓库当前 TB 的 SHA（防止旧新用了不同 TB 而不自知）。
#   5) **控制向量两边正确**：两棵树都校验 fails=0 defect=0。
#   6) **包装器自检**（精确 reason + rc≠0 + 无 PASS）：
#        · 既有 7 类：编译失败 / 空 vvp / 运行非零 / 缺摘要 / 日志含 FAIL /
#          日志含 DEFECT_REPRODUCED / 少向量
#        · 严格逐向量 6 类：重复名 / 错名 / 多向量 / 0 检查凑数 / 错检查数 / 摘要自报不一致
#        · 环境 4 类：毒化 cwd 不影响结果（正控）/ 共享依赖运行中被改 / 哈希多坏行 / 哈希 exit9
#
# 产物纪律：产物根固定在本仓库 build/functional/ 授权树内（或父入口传入的 PKGOUT），
#          每次 mktemp -d 独占 run 目录，**不做任何 rm**。
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

HASH_ERR=""; HASH_OUT=""; HASH_SEQ=0
# Capture raw bytes first; preserve sha256sum's rc and verify exactly one LF line
# with the exact caller path (not just a digest-shaped prefix).
hash_one() {
    local f="$1" raw rc parsed
    HASH_ERR=""; HASH_OUT=""; HASH_SEQ=$((HASH_SEQ + 1))
    raw="$DRV/hash-one-$HASH_SEQ.raw"
    sha256sum -- "$f" >"$raw" 2>>"$DRV_LOG"; rc=$?
    if [ "$rc" -ne 0 ]; then HASH_ERR="hash_rc=$rc file=$f"; return 1; fi
    parsed="$(python3 - "$raw" "$f" <<'PY'
import pathlib, re, sys
b=pathlib.Path(sys.argv[1]).read_bytes(); p=sys.argv[2].encode()
if not b.endswith(b"\n") or b"\0" in b or b"\r" in b: raise SystemExit(1)
ls=b[:-1].split(b"\n")
if len(ls)!=1: raise SystemExit(1)
m=re.fullmatch(rb"([0-9a-f]{64})  (.+)",ls[0])
if not m or m.group(2)!=p: raise SystemExit(1)
sys.stdout.write(m.group(1).decode())
PY
)" || { HASH_ERR="hash_format file=$f"; return 1; }
    HASH_OUT="$parsed"
    return 0
}

#   逐文件 copy 一致性：**两侧分别校验**（rc/非空/hex）后再比较
verify_copy_equal() {  # verify_copy_equal <src> <dst> <tag>
    local src="$1" dst="$2" tag="$3" hs hd
    hash_one "$src" || { HASH_ERR="src_${HASH_ERR}"; return 1; }
    hs="$HASH_OUT"
    hash_one "$dst" || { HASH_ERR="dst_${HASH_ERR}"; return 1; }
    hd="$HASH_OUT"
    #   双保险：空值绝不参与相等判定（防"两失败 ⇒ 空==空 ⇒ 通过"）
    if [ -z "$hs" ] || [ -z "$hd" ]; then HASH_ERR="empty_hash tag=$tag"; return 1; fi
    [ "$hs" = "$hd" ] || { HASH_ERR="mismatch src=$hs dst=$hd tag=$tag"; return 1; }
    return 0
}

is_hex64() {
    case "$1" in
        *[!0-9a-f]*|"") return 1 ;;
    esac
    [ "${#1}" -eq 64 ] || return 1
    return 0
}

# Raw stdout is retained in the private driver run; preserve the command rc.
snapshot_sha() { # <root> <raw>; stdout bytes go to raw, return original sha rc
    local r="$1" raw="$2"
    ( cd -- "$r" && sha256sum -- $BASE_FILES ) >"$raw" 2>>"$DRV_LOG"
}
snapshot_sha_validate() { # <raw>
    python3 - "$1" $BASE_FILES <<'PY'
import pathlib,re,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); paths=sys.argv[2:]
if not b.endswith(b"\n") or b"\0" in b or b"\r" in b: raise SystemExit(1)
ls=b[:-1].split(b"\n")
if len(ls)!=len(paths): raise SystemExit(1)
seen=set()
for line,path in zip(ls,paths):
 m=re.fullmatch(rb"[0-9a-f]{64}  (.+)",line)
 if not m or m.group(1)!=path.encode() or path in seen: raise SystemExit(1)
 seen.add(path)
PY
}

note "==== test_cache_bus_driver.sh ===="
note "date       = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT  = $REPO_ROOT"
note "DRV        = $DRV"
note "MODE       = $MODE"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    note "GIT_HEAD   = $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
hash_one "$SELF_DIR/tb_cache_bus_semantics.sv" || fail "repo_tb_hash ${HASH_ERR}"
TB_SHA_REPO="$HASH_OUT"
hash_one "$PKG_SH" || fail "repo_pkg_hash ${HASH_ERR}"
PKG_SHA_REPO="$HASH_OUT"
hash_one "$REPO_ROOT/rtl/cache/l1d.v" || fail "repo_l1d_hash ${HASH_ERR}"
L1D_SHA_REPO="$HASH_OUT"
hash_one "$REPO_ROOT/rtl/cache/l1i.v" || fail "repo_l1i_hash ${HASH_ERR}"
L1I_SHA_REPO="$HASH_OUT"
hash_one "$REPO_ROOT/rtl/axi/axi_master_ctrl.v" || fail "repo_axi_hash ${HASH_ERR}"
AXI_SHA_REPO="$HASH_OUT"
#   ★ 跨相冻结还要管 env.sh：起始值在这里固定，两相都必须等于它
hash_one "$REPO_ROOT/scripts/env.sh" || fail "repo_env_hash ${HASH_ERR}"
ENV_SHA_START="$HASH_OUT"
is_hex64 "$TB_SHA_REPO"  || fail "repo_tb_hash_not_hex64"
is_hex64 "$PKG_SHA_REPO" || fail "repo_pkg_hash_not_hex64"
is_hex64 "$L1D_SHA_REPO" || fail "repo_l1d_hash_not_hex64"
is_hex64 "$L1I_SHA_REPO" || fail "repo_l1i_hash_not_hex64"
is_hex64 "$AXI_SHA_REPO" || fail "repo_axi_hash_not_hex64"
is_hex64 "$ENV_SHA_START" || fail "repo_env_hash_not_hex64"
note "L1D_SHA    = $L1D_SHA_REPO"
note "L1I_SHA    = $L1I_SHA_REPO"
note "AXI_SHA    = $AXI_SHA_REPO"
note "TB_SHA     = $TB_SHA_REPO"
note "PKG_SHA    = $PKG_SHA_REPO"
note "ENV_SHA    = $ENV_SHA_START"
note "TB_SHA_REPO= $TB_SHA_REPO"

# 基线依赖清单（最小集；含完整实际头）= 7 个
BASE_FILES="rtl/cache/l1d.v rtl/cache/l1i.v rtl/cache/cache_tag_array.v \
rtl/cache/cache_array_bram.v rtl/axi/axi_master_ctrl.v rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh"
SNAP_N=7

#==============================================================================
# A. 快照（不可变；git show 提取，不递归 build）
#==============================================================================
BASE_COMMIT="${CACHE_BUS_BASELINE_COMMIT:-201acf61}"
SNAP="$DRV/deps_base"
CUR="$DRV/deps_cur"

# ★★ P1-SHA 加固：所有哈希**捕获点**都必须
#     (a) 显式取 rc（`var="$(f)" || fail`，不靠管道/note 内替换吞掉）；
#     (b) 拒绝空输出与非法 hex；
#     (c) 比较前先各自校验非空 —— 否则"两边都失败 ⇒ 空==空 ⇒ 通过"是最隐蔽的假绿。
# ★ 块校验：恰好 SNAP_N 行、且 SNAP_N 行全为 64 位 hex（不允许额外坏行）
snapshot_sha_check() {  # raw file + tag; fail closed on exact list/bytes
    local raw="$1" tag="$2"
    snapshot_sha_validate "$raw" || fail "${tag}_format_or_path"
}

if [ "$MODE" = "full" ]; then
    git -C "$REPO_ROOT" cat-file -e "${BASE_COMMIT}^{commit}" 2>>"$DRV_LOG" \
        || fail "baseline_commit_missing commit=$BASE_COMMIT"
    #   ---- 当前树（被测修复）的**私有不可变快照**：与其它域并发改动隔离 ----
    for f in $BASE_FILES; do
        mkdir -p -- "$CUR/$(dirname -- "$f")" || fail "cur_snapshot_mkdir_failed"
        cp -- "$REPO_ROOT/$f" "$CUR/$f" || fail "cur_snapshot_copy f=$f"
        chmod 444 -- "$CUR/$f" || fail "cur_snapshot_chmod f=$f"
        verify_copy_equal "$REPO_ROOT/$f" "$CUR/$f" "cur f=$f" \
            || fail "cur_snapshot_copy_check f=$f ${HASH_ERR}"
    done
    CUR_SHA_PRE_RAW="$DRV/cur_sha_pre.raw"
    snapshot_sha "$CUR" "$CUR_SHA_PRE_RAW"; rc=$?
    [ "$rc" -eq 0 ] || fail "cur_snapshot_sha_rc=$rc"
    snapshot_sha_check "$CUR_SHA_PRE_RAW" "cur_snapshot_sha"
    CUR_SHA_PRE="$(cat -- "$CUR_SHA_PRE_RAW")"
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
    SNAP_SHA_PRE_RAW="$DRV/snapshot_sha_pre.raw"
    snapshot_sha "$SNAP" "$SNAP_SHA_PRE_RAW"; rc=$?
    [ "$rc" -eq 0 ] || fail "snapshot_sha_rc=$rc"
    snapshot_sha_check "$SNAP_SHA_PRE_RAW" "snapshot_sha"
    SNAP_SHA_PRE="$(cat -- "$SNAP_SHA_PRE_RAW")"
    note "SNAP       = $SNAP"
    note "SNAP_COMMIT= $BASE_COMMIT"
    note "SNAP_SHA   = $SNAP_SHA_PRE"
    [ "$SNAP_SHA_PRE" != "$CUR_SHA_PRE" ] || fail "snapshot_identical_to_cur (nothing to prove)"
fi

# --self-test is a supported standalone mode: prepare its required current-tree
# DUT snapshot explicitly (without creating/reading the old baseline snapshot).
if [ "$MODE" = "selftest" ]; then
    for f in $BASE_FILES; do
        mkdir -p -- "$CUR/$(dirname -- "$f")" || fail "selftest_cur_mkdir_failed"
        cp -- "$REPO_ROOT/$f" "$CUR/$f" || fail "selftest_cur_copy f=$f"
        chmod 444 -- "$CUR/$f" || fail "selftest_cur_chmod f=$f"
        verify_copy_equal "$REPO_ROOT/$f" "$CUR/$f" "selftest_cur f=$f" \
            || fail "selftest_cur_copy_check f=$f ${HASH_ERR}"
    done
    CUR_SHA_RAW="$DRV/selftest_cur_sha.raw"
    snapshot_sha "$CUR" "$CUR_SHA_RAW"; rc=$?
    [ "$rc" -eq 0 ] || fail "selftest_cur_sha_rc=$rc"
    snapshot_sha_check "$CUR_SHA_RAW" "selftest_cur_sha"
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

#------------------------------------------------------------------------------
# 跨相冻结：TB / 包 / env 三者都必须"单一、起始值、两相相同"
#   ★ 只比 TB/pkg 不够：env.sh 在两相之间被改会让"同一 TB"实际跑在不同工具/环境下。
#   ★ 每次取 SHA 都要 rc=0 + 非空 + 64 hex（不允许空==空）。
#------------------------------------------------------------------------------
ENV_ERR=""
sha_from_log() {  # sha_from_log <log> <regex-path-suffix>
    sed -n "s|^\([0-9a-f]\{64\}\)  /.*$2\$|\1|p" "$1" | head -1
}

check_cross_phase_env() {  # check_cross_phase_env <pos_log> <neg_log> <start_sha>
    local pl="$1" nl="$2" start="$3" ps ns
    ENV_ERR=""
    ps="$(sha_from_log "$pl" 'scripts/env\.sh')"
    ns="$(sha_from_log "$nl" 'scripts/env\.sh')"
    is_hex64 "$ps" || { ENV_ERR="pos_env_sha_invalid=${ps:-empty}"; return 1; }
    is_hex64 "$ns" || { ENV_ERR="neg_env_sha_invalid=${ns:-empty}"; return 1; }
    is_hex64 "$start" || { ENV_ERR="start_env_sha_invalid=${start:-empty}"; return 1; }
    [ "$ps" = "$start" ] || { ENV_ERR="pos_env_sha_differs pos=$ps start=$start"; return 1; }
    [ "$ns" = "$start" ] || { ENV_ERR="neg_env_sha_differs neg=$ns start=$start"; return 1; }
    return 0
}

check_cross_phase_inputs() {  # <pos_log> <neg_log> <start_tb> <start_pkg>
    local pl="$1" nl="$2" stb="$3" spkg="$4" a b c d
    a="$(sha_from_log "$pl" 'tb_cache_bus_semantics\.sv')"
    b="$(sha_from_log "$nl" 'tb_cache_bus_semantics\.sv')"
    c="$(sha_from_log "$pl" 'test_cache_bus\.sh')"
    d="$(sha_from_log "$nl" 'test_cache_bus\.sh')"
    is_hex64 "$a" || { INPUT_ERR="pos_tb_sha_invalid=${a:-empty}"; return 1; }
    is_hex64 "$b" || { INPUT_ERR="neg_tb_sha_invalid=${b:-empty}"; return 1; }
    is_hex64 "$c" || { INPUT_ERR="pos_pkg_sha_invalid=${c:-empty}"; return 1; }
    is_hex64 "$d" || { INPUT_ERR="neg_pkg_sha_invalid=${d:-empty}"; return 1; }
    [ "$a" = "$b" ] || { INPUT_ERR="tb_sha_differs"; return 1; }
    [ "$c" = "$d" ] || { INPUT_ERR="pkg_sha_differs"; return 1; }
    [ "$a" = "$stb" ] || { INPUT_ERR="tb_sha_not_start"; return 1; }
    [ "$c" = "$spkg" ] || { INPUT_ERR="pkg_sha_not_start"; return 1; }
    return 0
}

#==============================================================================
# B. 正控（新树 fixed）+ 反证（旧树 old）+ 输入一致性
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
    [ "$(pkg_field "$NEG_LOG" defect)" = "24" ] || fail "neg_defect=$(pkg_field "$NEG_LOG" defect)"

    POS_RUNLOG="$(pkg_run_log "$DRV/pkg_pos")"
    NEG_RUNLOG="$(pkg_run_log "$DRV/pkg_old")"
    [ -n "$POS_RUNLOG" ] || fail "pos_runlog_missing"
    [ -n "$NEG_RUNLOG" ] || fail "neg_runlog_missing"
    note "POS_RUNLOG = $POS_RUNLOG"
    note "NEG_RUNLOG = $NEG_RUNLOG"
    [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$POS_RUNLOG" || true)" = "1" ] || fail "pos_runlog_pass_anchor"
    [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$NEG_RUNLOG" || true)" = "0" ] || fail "neg_runlog_pass_anchor"

    #   ---- 输入一致性：两次运行必须用同一 TB/包/env；且等于仓库当前 TB ----
    check_cross_phase_inputs "$POS_RUNLOG" "$NEG_RUNLOG" "$TB_SHA_REPO" "$PKG_SHA_REPO" \
        || fail "cross_phase_inputs $INPUT_ERR"
    check_cross_phase_env "$POS_RUNLOG" "$NEG_RUNLOG" "$ENV_SHA_START" \
        || fail "cross_phase_env $ENV_ERR"

    #   ---- 逐向量 defect 签名 / 控制向量两边正确 ----
    for dv in wb_first_valid_zero_delay wb_two_victims_distinct wb_accept_delay3 \
              axi_split_read_single_done axi_split_write_single_done \
              l1i_fill_err_early l1i_fill_err_last l1i_two_err_lines_alternate \
              l1d_fill_err_mid l1d_wb_b_fail_keeps_dirty l1d_maint_clean_b_fail \
              axi_r_err_early axi_r_err_mid axi_r_err_last axi_b_err_write \
              axi_split_first_err_last_ok axi_err_clear_next_req \
              axi_r_resp_x_fail_closed axi_b_resp_x_fail_closed \
              l1i_fill_err_x_early l1i_fill_err_x_last l1d_fill_err_x_mid \
              l1d_wb_err_x_keeps_dirty l1d_maint_flush_b_fail_two_ways; do
        grep -q "^VEC [0-9]\+ $dv checks=[0-9]\+ fails=[1-9][0-9]* defect=1$" "$NEG_RUNLOG" \
            || fail "neg_defect_sig_missing vec=$dv"
    done
    for cv in ctrl_wb_clean_no_req ctrl_axi_nonsplit_single_done \
              ctrl_l1d_fill_hit ctrl_axi_error_free_chain; do
        grep -q "^VEC [0-9]\+ $cv checks=[0-9]\+ fails=0 defect=0$" "$POS_RUNLOG" \
            || fail "pos_control_mismatch vec=$cv"
        grep -q "^VEC [0-9]\+ $cv checks=[0-9]\+ fails=0 defect=0$" "$NEG_RUNLOG" \
            || fail "neg_control_mismatch vec=$cv"
    done

    #   ---- 快照不可变复核（rc 原样检查）----
    SNAP_SHA_POST_RAW="$DRV/snapshot_sha_post.raw"
    snapshot_sha "$SNAP" "$SNAP_SHA_POST_RAW"; rc=$?
    [ "$rc" -eq 0 ] || fail "snapshot_post_sha_rc=$rc"
    snapshot_sha_check "$SNAP_SHA_POST_RAW" "snapshot_post_sha"
    SNAP_SHA_POST="$(cat -- "$SNAP_SHA_POST_RAW")"
    [ "$SNAP_SHA_PRE" = "$SNAP_SHA_POST" ] || fail "snapshot_modified"
    CUR_SHA_POST_RAW="$DRV/cur_sha_post.raw"
    snapshot_sha "$CUR" "$CUR_SHA_POST_RAW"; rc=$?
    [ "$rc" -eq 0 ] || fail "cur_post_sha_rc=$rc"
    snapshot_sha_check "$CUR_SHA_POST_RAW" "cur_post_sha"
    CUR_SHA_POST="$(cat -- "$CUR_SHA_POST_RAW")"
    [ "$CUR_SHA_PRE" = "$CUR_SHA_POST" ] || fail "cur_snapshot_modified"
fi

#==============================================================================
# C. 包装器自检（精确 reason + rc≠0 + 无 PASS）
#==============================================================================
ST_FAIL=0
ST_N=0
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
REAL_SHA="$(command -v sha256sum || true)"
[ -n "$REAL_VVP" ] && [ -x "$REAL_VVP" ] || fail "real_vvp_missing"
[ -n "$REAL_SHA" ] && [ -x "$REAL_SHA" ] || fail "real_sha256sum_missing"

#   1) 编译失败：DUT 根本身语法错误（头/其它源齐备，确保失败原因是 rc 而非缺文件）
BAD_DUT="$DRV/bad_dut"
for f in $BASE_FILES; do mkdir -p -- "$BAD_DUT/$(dirname -- "$f")"; done
for f in $BASE_FILES; do
    [ "$f" = "rtl/cache/l1d.v" ] && continue
    cp -- "$REPO_ROOT/$f" "$BAD_DUT/$f"
done
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
selftest_start log_defect log_has_defect_marker
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_defect.sh" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st6"
selftest_check $?

#   ---- 严格逐向量自检的公共素材：以**真实正控输出**为模板，只改一处 ----
#   先跑一次干净树拿到 VEC + 摘要行（模板），再逐类注入。
BASE_TMPL="$DRV/vec_template.txt"
run_pkg "$DRV/tmpl.log" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_tmpl" || true
#   ★ VEC/摘要行在**包内 run 日志**里（包 stdout 只放摘要+锚点），不是 stdout。
TMPL_RUNLOG="$(pkg_run_log "$DRV/pkg_tmpl")"
[ -n "$TMPL_RUNLOG" ] || fail "template_runlog_missing"
grep '^VEC ' "$TMPL_RUNLOG" > "$BASE_TMPL" || true
grep '^CACHE_BUS_VECTORS ' "$TMPL_RUNLOG" >> "$BASE_TMPL" || true
TMPL_VEC_N="$(grep -c '^VEC ' "$BASE_TMPL" || true)"
[ "$TMPL_VEC_N" = "28" ] || fail "template_vec_count=$TMPL_VEC_N"

mk_vvp_cat() {  # mk_vvp_cat <script> <file>
    local scr="$1" f="$2"
    cat > "$scr" <<EOF
#!/usr/bin/env bash
cat "$f"
exit 0
EOF
    chmod 755 "$scr"
}

#   7) 少向量（摘要 total=28 但只有 27 条 VEC 行）
grep -v '^CACHE_BUS_VECTORS ' "$BASE_TMPL" | head -n -1 > "$DRV/m_short.txt"
grep '^CACHE_BUS_VECTORS ' "$BASE_TMPL" >> "$DRV/m_short.txt"
mk_vvp_cat "$FAKE/vvp_cat_short.sh" "$DRV/m_short.txt"
selftest_start short_vecs vec_line_count=27
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_short.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st7"
selftest_check $?

#   8) 多向量（摘要仍 28，但多一条 VEC ⇒ vec_line_count=29）
cp -- "$BASE_TMPL" "$DRV/m_extra.txt"
printf 'VEC 29 bogus_extra_vec checks=1 fails=0 defect=0\n' >> "$DRV/m_extra.txt"
# 摘要必须仍在最后一行：把摘要行移回末尾
grep -v '^CACHE_BUS_VECTORS ' "$DRV/m_extra.txt" > "$DRV/m_extra2.txt"
grep '^CACHE_BUS_VECTORS ' "$BASE_TMPL" >> "$DRV/m_extra2.txt"
mk_vvp_cat "$FAKE/vvp_cat_extra.sh" "$DRV/m_extra2.txt"
selftest_start extra_vec vec_line_count=29
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_extra.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st8"
selftest_check $?

#   9) 重复名（第 2 条改成第 1 条的名字 ⇒ 名称逐位不一致）
awk 'BEGIN{n=0} /^VEC /{n++; if(n==2){sub(/VEC 2 [A-Za-z0-9_]+/, "VEC 2 wb_first_valid_zero_delay")}} {print}' \
    "$BASE_TMPL" > "$DRV/m_dup.txt"
mk_vvp_cat "$FAKE/vvp_cat_dup.sh" "$DRV/m_dup.txt"
selftest_start dup_name vec_name=wb_first_valid_zero_delay
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_dup.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st9"
selftest_check $?

#   10) 错名（第 5 条改名）
awk 'BEGIN{n=0} /^VEC /{n++; if(n==5){sub(/VEC 5 [A-Za-z0-9_]+/, "VEC 5 bogus_wrong_name")}} {print}' \
    "$BASE_TMPL" > "$DRV/m_name.txt"
mk_vvp_cat "$FAKE/vvp_cat_name.sh" "$DRV/m_name.txt"
selftest_start wrong_name vec_name=bogus_wrong_name
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_name.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st10"
selftest_check $?

#   11) 0 检查凑数（把第 3 条 checks 改 0，并同步摘要 checks 减去原值 37）
awk 'BEGIN{n=0} /^VEC /{n++; if(n==3){sub(/checks=[0-9]+/, "checks=0")}} {print}' \
    "$BASE_TMPL" > "$DRV/m_zero.txt"
mk_vvp_cat "$FAKE/vvp_cat_zero.sh" "$DRV/m_zero.txt"
selftest_start zero_checks 'vec_zero_checks name=wb_accept_delay3'
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_zero.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st11"
selftest_check $?

#   12) 错检查数（第 4 条 checks 6→7，摘要同步 +1 ⇒ 逐向量不匹配）
awk 'BEGIN{n=0} /^VEC /{n++; if(n==4){sub(/checks=[0-9]+/, "checks=7")}} {print}' \
    "$BASE_TMPL" > "$DRV/m_cnt.txt"
mk_vvp_cat "$FAKE/vvp_cat_cnt.sh" "$DRV/m_cnt.txt"
selftest_start wrong_count 'vec_checks name=ctrl_wb_clean_no_req'
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_cnt.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st12"
selftest_check $?

#   13) 摘要自报不一致（行不变、摘要 checks +1 ⇒ 逐向量之和 != 摘要）
sed -E 's/^(CACHE_BUS_VECTORS total=28 nonzero=28) checks=448 /\1 checks=449 /' \
    "$BASE_TMPL" > "$DRV/m_sum.txt"
mk_vvp_cat "$FAKE/vvp_cat_sum.sh" "$DRV/m_sum.txt"
selftest_start bad_sum vec_checks_sum=448
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_cat_sum.sh" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st13"
selftest_check $?

#   14) 毒化 cwd（正控）：cwd 里放**错误**的 rtl/pkg 头，包必须仍用 DUT_ROOT 的头而 PASS
POISON="$DRV/poison_cwd"
mkdir -p -- "$POISON/rtl/pkg" "$POISON/rtl/cache" "$POISON/rtl/axi" || fail "poison_mkdir"
cat > "$POISON/rtl/pkg/rv32_defs.vh" <<'EOF'
// poisoned header: must never be used
`define RV32GC_AXI_RESP_OKAY 2'bzz
this is not verilog
EOF
cat > "$POISON/rtl/pkg/core_params.vh" <<'EOF'
// poisoned header: wrong geometry must never be used
`define RV32GC_L1D_WAYS 8
this is not verilog
EOF
POISON_LOG="$DRV/poison_cwd.log"
( cd -- "$POISON" && env DUT_ROOT="$CUR" RV32_FUNCTIONAL_PKG_OUT_DIR="$DRV/pkg_poison" \
      bash "$PKG_SH" > "$POISON_LOG" 2>&1 )
POISON_RC=$?
note "POISON_CWD rc=$POISON_RC"
cat -- "$POISON_LOG" >&3
[ "$POISON_RC" -eq 0 ] || fail "poison_cwd_rc=$POISON_RC"
[ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$POISON_LOG" || true)" = "1" ] || fail "poison_cwd_pass_anchor"

#   15) 共享依赖运行中被改（写回失败源文件必须被冻结检查抓到）
MUT_DUT="$DRV/mut_dut"
for f in $BASE_FILES; do
    mkdir -p -- "$MUT_DUT/$(dirname -- "$f")"
    cp -- "$REPO_ROOT/$f" "$MUT_DUT/$f"
done
cat > "$FAKE/vvp_mutate.sh" <<EOF
#!/usr/bin/env bash
cat "$BASE_TMPL"
echo "// injected mutation during run" >> "$MUT_DUT/rtl/cache/l1i.v"
exit 0
EOF
chmod 755 "$FAKE/vvp_mutate.sh"
selftest_start shared_mutation source_changed_during_run
run_pkg "$ST_LOG" "RV32_VVP=$FAKE/vvp_mutate.sh" "DUT_ROOT=$MUT_DUT" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st15"
selftest_check $?

#   16) 哈希块多一条坏行（必须按"总行数"拒，而不是只数合法行）
FAKEBIN="$DRV/fakebin"
mkdir -p -- "$FAKEBIN" || fail "fakebin_mkdir"
cat > "$FAKEBIN/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@"
echo "this-is-not-a-hash-line"
exit 0
EOF
chmod 755 "$FAKEBIN/sha256sum"
selftest_start hash_extra_line sha256_pre_format
run_pkg "$ST_LOG" "PATH=$FAKEBIN:$PATH" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st16"
selftest_check $?

#   17) 哈希输出完整 7 行后 exit 9（必须保原 rc 拒绝，不能被"行数够"蒙混）
cat > "$FAKEBIN/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@"
exit 9
EOF
chmod 755 "$FAKEBIN/sha256sum"
selftest_start hash_exit9 sha256_pre_rc=9
run_pkg "$ST_LOG" "PATH=$FAKEBIN:$PATH" "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_st17"
selftest_check $?
#   还原 fakebin（后续矩阵自建）
rm -f "$FAKEBIN/sha256sum"

# 精确攻击包入口的 A(8 行)/B(2 行) 实际 caller；合法输出/原rc先由工具真源控绿，
# 下列各形态必须在对应 pre-run caller 被拒，不能由工具/参数检查抢先拒绝。
make_freeze_mutator() {
    cat > "$FAKEBIN/sha256sum" <<'SH'
#!/usr/bin/env bash
"$REAL_SHA" "$@" >"$HASH_TMP"; rc=$?
mutate=0
if [ "$HASH_TARGET" = main ] && [ "$#" -eq 9 ]; then mutate=1; fi
if [ "$HASH_TARGET" = aux ] && [ "$#" -eq 3 ]; then mutate=1; fi
if [ "$mutate" -eq 0 ]; then cat -- "$HASH_TMP"; exit "$rc"; fi
python3 - "$HASH_TMP" "$HASH_MODE" <<'PY'
import pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); m=sys.argv[2]
if m=='extra1': b+=b.split(b'\n',1)[0]+b'\n'
elif m=='blanks': b+=b'\n\n'
elif m=='unterminated': b=b[:-1]
elif m=='wrongpath': b=b.replace(b'  ',b'  wrong-path-',1)
elif m=='garbage': b+=b'NOT-A-HASH\n'
elif m=='nulcr': b+=b'\0\r\n'
sys.stdout.buffer.write(b)
PY
if [ "$HASH_MODE" = exit9 ]; then exit 9; else exit "$rc"; fi
SH
    chmod +x "$FAKEBIN/sha256sum"
}
for ht in main aux; do
    for hm in extra1 blanks unterminated wrongpath garbage nulcr exit9; do
        make_freeze_mutator
        if [ "$ht" = main ]; then prefix=sha256_pre; else prefix=sha256_aux_pre; fi
        if [ "$hm" = exit9 ]; then want="${prefix}_rc=9"; else want="${prefix}_format"; fi
        selftest_start "raw_${ht}_${hm}" "$want"
        run_pkg "$ST_LOG" "PATH=$FAKEBIN:$PATH" "REAL_SHA=$REAL_SHA" \
            "HASH_TMP=$DRV/hash_${ht}_${hm}.raw" "HASH_TARGET=$ht" "HASH_MODE=$hm" \
            "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_raw_${ht}_${hm}"
        selftest_check $?
    done
done
rm -f "$FAKEBIN/sha256sum"

#   18) **单文件**哈希：真实完整输出后 exit 9（多文件/共享调用仍正常）⇒
#       copy 一致性检查必须按 rc 拒绝，绝不能"两边都失败 ⇒ 空==空 ⇒ 通过"。
cat > "$FAKEBIN/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@"
rc=\$?
# 单文件调用（忽略分隔符 --）：先给出**真实完整**哈希行，再 exit 9
n=\$#
if [ "\${1:-}" = "--" ]; then n=\$((n - 1)); fi
if [ "\$n" -eq 1 ]; then exit 9; fi
exit \$rc
EOF
chmod 755 "$FAKEBIN/sha256sum"
HS_A="$DRV/hash_self_a.txt"; HS_B="$DRV/hash_self_b.txt"
printf 'identical content for hash self-test\n' > "$HS_A"
cp -- "$HS_A" "$HS_B"
OLD_PATH="$PATH"; PATH="$FAKEBIN:$PATH"
verify_copy_equal "$HS_A" "$HS_B" "selftest-copy"; VCE_RC=$?; VCE_ERR="$HASH_ERR"
PATH="$OLD_PATH"
ST_N=$((ST_N + 1))
if [ "$VCE_RC" -eq 0 ] || [[ "$VCE_ERR" != *"hash_rc=9"* ]]; then
    printf 'CACHE_BUS_SELFTEST case=copy_hash_exit9 rc=%s err=%s ok=0\n' "$VCE_RC" "$VCE_ERR"
    ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=copy_hash_exit9 rc=%s err=%s ok=1\n' "$VCE_RC" "$VCE_ERR"
fi
note "SELFTEST copy_hash_exit9 rc=$VCE_RC err=$VCE_ERR"

#   19) 单文件哈希：输出为空且 exit 0 ⇒ 必须按"空输出"拒绝
cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$FAKEBIN/sha256sum"
PATH="$FAKEBIN:$PATH"
hash_one "$HS_A"; HO_RC=$?; HO_ERR="$HASH_ERR"; HO_EMPTY="$HASH_OUT"
PATH="$OLD_PATH"
ST_N=$((ST_N + 1))
if [ "$HO_RC" -eq 0 ] || [ -n "$HO_EMPTY" ] || [[ "$HO_ERR" != *"hash_format"* ]]; then
    printf 'CACHE_BUS_SELFTEST case=hash_empty rc=%s out=%s err=%s ok=0\n' "$HO_RC" "$HO_EMPTY" "$HO_ERR"
    ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=hash_empty rc=%s err=%s ok=1\n' "$HO_RC" "$HO_ERR"
fi

#   20) 单文件哈希：非 hex 的"完整输出" ⇒ 必须按 badhex 拒绝
cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
echo "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz  fake"
exit 0
EOF
chmod 755 "$FAKEBIN/sha256sum"
PATH="$FAKEBIN:$PATH"
hash_one "$HS_A"; HO_RC=$?; HO_ERR="$HASH_ERR"; HO_BAD="$HASH_OUT"
PATH="$OLD_PATH"
ST_N=$((ST_N + 1))
if [ "$HO_RC" -eq 0 ] || [ -n "$HO_BAD" ] || [[ "$HO_ERR" != *"hash_format"* ]]; then
    printf 'CACHE_BUS_SELFTEST case=hash_badhex rc=%s out=%s err=%s ok=0\n' "$HO_RC" "$HO_BAD" "$HO_ERR"
    ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=hash_badhex rc=%s err=%s ok=1\n' "$HO_RC" "$HO_ERR"
fi
rm -f "$FAKEBIN/sha256sum"

#   21) **多文件/共享**哈希：输出完整 7 行后 exit 9 ⇒ snapshot_sha 的 rc 必须原样为 9
#       （覆盖"初始快照"这条调用路径；证明不是只有单文件 helper 保 rc）。
SNAP_SELF="$DRV/snap_self"
for f in $BASE_FILES; do
    mkdir -p -- "$SNAP_SELF/$(dirname -- "$f")"
    cp -- "$REPO_ROOT/$f" "$SNAP_SELF/$f"
done
cat > "$FAKEBIN/sha256sum" <<EOF
#!/usr/bin/env bash
"$REAL_SHA" "\$@"
exit 9
EOF
chmod 755 "$FAKEBIN/sha256sum"
PATH="$FAKEBIN:$PATH"
SNAP_SELF_RAW="$DRV/snapshot_self.raw"
snapshot_sha "$SNAP_SELF" "$SNAP_SELF_RAW"; SNAP_SELF_RC=$?
PATH="$OLD_PATH"
SNAP_SELF_LINES="$(wc -l < "$SNAP_SELF_RAW")"
ST_N=$((ST_N + 1))
if [ "$SNAP_SELF_RC" -ne 9 ] || [ "$SNAP_SELF_LINES" -ne "$SNAP_N" ] || ! snapshot_sha_validate "$SNAP_SELF_RAW"; then
    printf 'CACHE_BUS_SELFTEST case=snapshot_hash_exit9 rc=%s lines=%s ok=0\n' "$SNAP_SELF_RC" "$SNAP_SELF_LINES"
    ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=snapshot_hash_exit9 rc=%s lines=%s ok=1\n' "$SNAP_SELF_RC" "$SNAP_SELF_LINES"
fi
note "SELFTEST snapshot_hash_exit9 rc=$SNAP_SELF_RC lines=$SNAP_SELF_LINES"

# Exact byte/path mutations for the actual single-file hash_one and 7-file
# snapshot_sha helpers. Each mutation starts from the real, LF-terminated output.
{
    printf '#!/usr/bin/env bash\n'
    printf '"%s" "$@" >"$HASH_TMP"; rc=$?\n' "$REAL_SHA"
    cat <<'SH'
mutate=0
if [ "$HASH_KIND" = single ] && [ "$#" -eq 2 ]; then mutate=1; fi
if [ "$HASH_KIND" = snapshot ] && [ "$#" -eq 8 ]; then mutate=1; fi
if [ "$mutate" -eq 0 ]; then cat -- "$HASH_TMP"; exit "$rc"; fi
python3 - "$HASH_TMP" "$HASH_MODE" <<'PY'
import pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); m=sys.argv[2]
if m=='extra1': b+=b.split(b'\n',1)[0]+b'\n'
elif m=='blanks': b+=b'\n\n'
elif m=='unterminated': b=b[:-1]
elif m=='wrongpath': b=b.replace(b'  ',b'  wrong-path-',1)
elif m=='garbage': b+=b'NOT-A-HASH\n'
elif m=='nulcr': b+=b'\0\r\n'
sys.stdout.buffer.write(b)
PY
if [ "$HASH_MODE" = exit9 ]; then exit 9; else exit "$rc"; fi
SH
} > "$FAKEBIN/sha256sum"
chmod 755 "$FAKEBIN/sha256sum"
for hm in extra1 blanks unterminated wrongpath garbage nulcr; do
    OLD_PATH="$PATH"; PATH="$FAKEBIN:$PATH"
    HASH_KIND=single HASH_MODE="$hm" HASH_TMP="$DRV/hash_one_${hm}.raw" \
        hash_one "$HS_A"; HO_RC=$?; HO_ERR="$HASH_ERR"
    PATH="$OLD_PATH"
    ST_N=$((ST_N+1))
    if [ "$HO_RC" -eq 0 ] || [[ "$HO_ERR" != *hash_format* ]]; then
        printf 'CACHE_BUS_SELFTEST case=hash_one_%s rc=%s err=%s ok=0\n' "$hm" "$HO_RC" "$HO_ERR"; ST_FAIL=1
    else
        printf 'CACHE_BUS_SELFTEST case=hash_one_%s rc=%s err=%s ok=1\n' "$hm" "$HO_RC" "$HO_ERR"
    fi
    OLD_PATH="$PATH"; PATH="$FAKEBIN:$PATH"
    HASH_KIND=snapshot HASH_MODE="$hm" HASH_TMP="$DRV/snapshot_${hm}.raw" \
        snapshot_sha "$SNAP_SELF" "$DRV/snapshot_${hm}.captured.raw"; SH_RC=$?
    PATH="$OLD_PATH"
    ST_N=$((ST_N+1))
    if [ "$SH_RC" -ne 0 ] || snapshot_sha_validate "$DRV/snapshot_${hm}.captured.raw"; then
        printf 'CACHE_BUS_SELFTEST case=snapshot_%s rc=%s ok=0\n' "$hm" "$SH_RC"; ST_FAIL=1
    else
        printf 'CACHE_BUS_SELFTEST case=snapshot_%s rc=%s validation=reject ok=1\n' "$hm" "$SH_RC"
    fi
done
rm -f "$FAKEBIN/sha256sum"

#   22) **跨相 env 敏感反证**：两相 env SHA 与起始值不同 ⇒ 必须按精确原因拒绝
#       （先证明"相同则通过"，再改一个字节证明会被抓）
EP_A="$DRV/env_mock_pos.log"; EP_B="$DRV/env_mock_neg.log"; EP_C="$DRV/env_mock_bad.log"
ZH="$(printf '0%.0s' $(seq 1 64))"
ONE="$(printf '1%.0s' $(seq 1 64))"
{
  printf '%s  /x/scripts/env.sh\n' "$ZH"
  printf '%s  /x/tb_cache_bus_semantics.sv\n' "$ZH"
  printf '%s  /x/test_cache_bus.sh\n' "$ZH"
} > "$EP_A"
cp -- "$EP_A" "$EP_B"
{
  printf '%s  /x/scripts/env.sh\n' "$ONE"
  printf '%s  /x/tb_cache_bus_semantics.sv\n' "$ZH"
  printf '%s  /x/test_cache_bus.sh\n' "$ZH"
} > "$EP_C"
ST_N=$((ST_N + 1))
if check_cross_phase_env "$EP_A" "$EP_B" "$ZH"; then
    printf 'CACHE_BUS_SELFTEST case=env_same_ok ok=1\n'
else
    printf 'CACHE_BUS_SELFTEST case=env_same_ok ok=0 err=%s\n' "$ENV_ERR"; ST_FAIL=1
fi
ST_N=$((ST_N + 1))
if check_cross_phase_env "$EP_A" "$EP_C" "$ZH"; then
    printf 'CACHE_BUS_SELFTEST case=stage_env_mismatch ok=0 (not detected)\n'; ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=stage_env_mismatch ok=1 err=%s\n' "$ENV_ERR"
fi
note "SELFTEST stage_env_mismatch err=$ENV_ERR"

#   23) **DUT 变异自证 A**：把 rdata_error 从"真实错误 beat"拖到"逻辑末有效 beat"
#       ⇒ 逐 beat oracle 必须红（旧 TB 只数总数/是否在某 valid beat 上是绿的）。
MUT_ERR="$DRV/mut_dut_errdelay"
for f in $BASE_FILES; do
    mkdir -p -- "$MUT_ERR/$(dirname -- "$f")"
    cp -- "$REPO_ROOT/$f" "$MUT_ERR/$f"
done
python3 - "$MUT_ERR/rtl/axi/axi_master_ctrl.v" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
old="    assign rdata_error = r_err;"
new="    assign rdata_error = r_fire & m_rlast & err_acc_q;  // MUTATION: delay to last beat"
assert old in s
open(p,'w').write(s.replace(old,new))
PYEOF
MUT_ERR_LOG="$DRV/mut_errdelay.log"
run_pkg "$MUT_ERR_LOG" "DUT_ROOT=$MUT_ERR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_mut_err"
MUT_ERR_RC=$?
ST_N=$((ST_N + 1))
if [ "$MUT_ERR_RC" -eq 0 ]; then
    printf 'CACHE_BUS_SELFTEST case=mut_early_err_delayed ok=0 (mutation survived)\n'; ST_FAIL=1
elif ! grep -q 'reason=vec_fails name=axi_r_err' "$MUT_ERR_LOG"; then
    printf 'CACHE_BUS_SELFTEST case=mut_early_err_delayed ok=0 (wrong reason)\n'; ST_FAIL=1
elif ! grep -q 'per-beat rdata_valid/error/data/last == independent oracle' \
        "$(pkg_run_log "$DRV/pkg_mut_err")"; then
    printf 'CACHE_BUS_SELFTEST case=mut_early_err_delayed ok=0 (oracle did not fire)\n'; ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=mut_early_err_delayed rc=%s reason=vec_fails(oracle) ok=1\n' "$MUT_ERR_RC"
fi
note "SELFTEST mut_early_err_delayed rc=$MUT_ERR_RC"
cat -- "$MUT_ERR_LOG" >&3

#   24) **DUT 变异自证 B**：在在途窗口把 busy 变成 X ⇒ 控制未知 sticky 计数必须红
#       （去掉/弱化 X 监视器会让它变绿，故这条同时是监视器的"载荷证明"）。
MUT_X="$DRV/mut_dut_busyx"
for f in $BASE_FILES; do
    mkdir -p -- "$MUT_X/$(dirname -- "$f")"
    cp -- "$REPO_ROOT/$f" "$MUT_X/$f"
done
python3 - "$MUT_X/rtl/axi/axi_master_ctrl.v" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
old="    assign busy  = busy_q;"
new=("    reg x_poison_q;\n"
     "    always @(posedge clk) if (!rst_n) x_poison_q <= 1'b0;\n"
     "        else x_poison_q <= (req_valid && req_ready);\n"
     "    assign busy  = x_poison_q ? 1'bx : busy_q;  // MUTATION: X on active control")
assert old in s
open(p,'w').write(s.replace(old,new))
PYEOF
MUT_X_LOG="$DRV/mut_busyx.log"
run_pkg "$MUT_X_LOG" "DUT_ROOT=$MUT_X" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_mut_x"
MUT_X_RC=$?
ST_N=$((ST_N + 1))
if [ "$MUT_X_RC" -eq 0 ]; then
    printf 'CACHE_BUS_SELFTEST case=mut_busy_x ok=0 (mutation survived)\n'; ST_FAIL=1
elif ! grep -q 'reason=vec_fails' "$MUT_X_LOG"; then
    printf 'CACHE_BUS_SELFTEST case=mut_busy_x ok=0 (wrong reason)\n'; ST_FAIL=1
elif ! grep -q 'no X/Z on active AXI control signals' \
        "$(pkg_run_log "$DRV/pkg_mut_x")"; then
    printf 'CACHE_BUS_SELFTEST case=mut_busy_x ok=0 (X monitor did not fire)\n'; ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=mut_busy_x rc=%s reason=vec_fails(x_ctrl) ok=1\n' "$MUT_X_RC"
fi
note "SELFTEST mut_busy_x rc=$MUT_X_RC"
cat -- "$MUT_X_LOG" >&3

#   25) **维护专用 word3 损坏变异必红**：只在维护写回时污染 word3，
#       普通写回（v1/v2/v3）不受影响 ⇒ 必须由 v13 的逐字核对抓到。
mk_mut_dut() {  # mk_mut_dut <dir>
    local d="$1" f
    for f in $BASE_FILES; do
        mkdir -p -- "$d/$(dirname -- "$f")"
        cp -- "$REPO_ROOT/$f" "$d/$f"
    done
}

MUT_W3="$DRV/mut_dut_w3"
mk_mut_dut "$MUT_W3"
python3 - "$MUT_W3/rtl/cache/l1d.v" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    wire [31:0] wb_data_sel = wb_buf_q[wb_word_idx[WIDX_BITS-1:0]*32 +: 32];"
lines = [
    "    // MUTATION: corrupt maintenance-only writeback word3",
    "    wire [31:0] wb_data_sel = wb_buf_q[wb_word_idx[WIDX_BITS-1:0]*32 +: 32]",
    "                             ^ ((maint_wb_q && (wb_word_idx == 5'd3)) ? 32'h0000_0001 : 32'h0);",
]
assert old in s, "mutation anchor not found"
open(p, "w").write(s.replace(old, "\n".join(lines)))
PYEOF
MUT_W3_LOG="$DRV/mut_w3.log"
run_pkg "$MUT_W3_LOG" "DUT_ROOT=$MUT_W3" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_mut_w3"
MUT_W3_RC=$?
ST_N=$((ST_N + 1))
if [ "$MUT_W3_RC" -eq 0 ]; then
    printf 'CACHE_BUS_SELFTEST case=mut_maint_word3 ok=0 (mutation survived)\n'; ST_FAIL=1
elif ! grep -q 'reason=vec_fails name=l1d_maint_clean_b_fail' "$MUT_W3_LOG"; then
    printf 'CACHE_BUS_SELFTEST case=mut_maint_word3 ok=0 (wrong reason)\n'; ST_FAIL=1
elif ! grep -q 'v13 DA0 writeback word word=3' "$(pkg_run_log "$DRV/pkg_mut_w3")"; then
    printf 'CACHE_BUS_SELFTEST case=mut_maint_word3 ok=0 (word3 not the hit)\n'; ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=mut_maint_word3 rc=%s reason=vec_fails(word3) ok=1\n' "$MUT_W3_RC"
fi
note "SELFTEST mut_maint_word3 rc=$MUT_W3_RC"
cat -- "$MUT_W3_LOG" >&3

#   26) **目标组凭空 valid 变异必红**：clean 完成拍对所有 way 都写 valid=1
#       ⇒ 目标 set 的 way2/3 变 valid；真实目标阵列探针必须抓到。
MUT_PV="$DRV/mut_dut_phantom"
mk_mut_dut "$MUT_PV"
python3 - "$MUT_PV/rtl/cache/l1d.v" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
old="            wire way_clr      = maint_wb_fin_w & (wb_way_q == gw[WAY_W-1:0]);"
new="            wire way_clr      = maint_wb_fin_w;  // MUTATION: all ways (phantom valid)"
assert old in s
open(p,'w').write(s.replace(old,new))
PYEOF
MUT_PV_LOG="$DRV/mut_phantom.log"
run_pkg "$MUT_PV_LOG" "DUT_ROOT=$MUT_PV" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_mut_pv"
MUT_PV_RC=$?
ST_N=$((ST_N + 1))
if [ "$MUT_PV_RC" -eq 0 ]; then
    printf 'CACHE_BUS_SELFTEST case=mut_target_phantom_valid ok=0 (mutation survived)\n'; ST_FAIL=1
elif ! grep -q 'reason=vec_fails name=l1d_maint_clean_b_fail' "$MUT_PV_LOG"; then
    printf 'CACHE_BUS_SELFTEST case=mut_target_phantom_valid ok=0 (wrong reason)\n'; ST_FAIL=1
elif ! grep -q 'has NO valid (no clean ghost)' "$(pkg_run_log "$DRV/pkg_mut_pv")"; then
    printf 'CACHE_BUS_SELFTEST case=mut_target_phantom_valid ok=0 (probe did not fire)\n'; ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=mut_target_phantom_valid rc=%s reason=vec_fails(ghost) ok=1\n' "$MUT_PV_RC"
fi
note "SELFTEST mut_target_phantom_valid rc=$MUT_PV_RC"
cat -- "$MUT_PV_LOG" >&3

#   27) **合法相同工具控绿**：同一 mk_mut_dut 管线、**不做任何改动** ⇒ 必须 rc=0 且 PASS
#       （证明变异工装本身不会引入失败，上两条红是变异导致而非工装导致）。
MUT_NOOP="$DRV/mut_dut_noop"
mk_mut_dut "$MUT_NOOP"
MUT_NOOP_LOG="$DRV/mut_noop.log"
run_pkg "$MUT_NOOP_LOG" "DUT_ROOT=$MUT_NOOP" "RV32_FUNCTIONAL_PKG_OUT_DIR=$DRV/pkg_mut_noop"
MUT_NOOP_RC=$?
ST_N=$((ST_N + 1))
if [ "$MUT_NOOP_RC" -ne 0 ] || [ "$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$MUT_NOOP_LOG" || true)" != "1" ]; then
    printf 'CACHE_BUS_SELFTEST case=mut_noop_control rc=%s ok=0\n' "$MUT_NOOP_RC"; ST_FAIL=1
else
    printf 'CACHE_BUS_SELFTEST case=mut_noop_control rc=0 pass=1 ok=1\n'
fi
note "SELFTEST mut_noop_control rc=$MUT_NOOP_RC"

[ "$ST_FAIL" = "0" ] || fail "selftest_failed"

#==============================================================================
# D. 结论
#==============================================================================
if [ "$MODE" = "full" ]; then
    printf 'CACHE_BUS_DRIVER: positive=ok negative=ok control=ok inputs=consistent snapshot=immutable selftest=ok\n'
else
    printf 'CACHE_BUS_DRIVER: selftest=ok\n'
fi
printf 'CACHE_BUS_DRIVER: PASS\n'
note "CACHE_BUS_DRIVER: PASS"
exit 0
