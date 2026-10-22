#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_rob_window.sh —— ROB 头部窗口语义（P1 根修）功能定向包
#==============================================================================
# 项目 : rv32gc-cpu（阶段二后端；P1「ROB 窗口接收未分配槽旧宽存数据」）
# 依据 : prompts/common.md §3（判定 fail-closed：确定性脚本 + 退出码 + 日志锚点）、
#        sim/functional/manifest.tsv（本包锚点 = 唯一整行 `FUNCTIONAL_ROB_WINDOW: PASS`）。
#
# 做什么 :
#   1) 只复制本包**实际依赖闭包**（rob.v / rob_wide_mem.v / back2_params.vh / TB）到本次
#      run 目录的不可变快照，逐文件记 sha256；编译输入**只来自快照**，并固定 cwd=快照根。
#   2) iverilog 编译（`-s tb_rob_window_semantics`），逐向量 `+CASE=<n>` 独立进程运行；
#      默认要求 10/10 `VERDICT=OK`、每向量 `nchk >= 冻结下限`、窗口四态 `raw=0`。
#   3) 反证（单独模式 `--self-test` / `--negative`，绝不与默认成功混判）：
#      · 由**同一份冻结 rob.v** 现场生成"修前候选"（只去掉 e_ok/e_bad 窗口采信门，
#        保留 head_pc_valid_o 输出接口），替换次数必须精确命中，否则失败；
#      · 对修前候选跑**同一冻结 TB**：case0（不分配）必须 OK；case1..8 必须全部
#        `DEFECT_SIG`，且日志必须出现 P1 根因签名（`RAW win` / `head_pc_valid=1 but PC stale`
#        / `commit ... got_pc`）与 `ROB_WINDOW_COV ... raw>0`；case9（同族正控）在
#        defect 候选上也会被通用旧值根因打红，单独记录；
#      · 再对当前树（新源码）跑同一 TB：10/10 OK。
#   3b) `--b227`（冻结旧候选，只读）：同一 TB 跑 in-tree fixture
#      `sim/functional/fixtures/rob_window_b227` 的 e_bad=flush-only 实现
#      （显式 RV32_ROBWIN_B227_ROOT 可指向同身份外部副本）⇒ 原 case0..7 全绿 + 新 case8 `DEFECT_SIG`（逐拍
#      head_pc_valid stale / RAW age<2）+ 同族正控 case9 绿。
#   4) 运行前后复核全部冻结输入 sha256 逐字节一致；哈希捕获原始 rc 并要求恰一行 64-hex。
#
# 产物纪律：产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR > OUT_DIR > $REPO_ROOT/build/functional/rob-window；
#          根必须在 $REPO_ROOT/build/functional 授权树内；`mktemp -d` 独占 run 目录，不删除历史。
#
# 判定（全部满足才算 PASS，否则 exit 1 且不打印 PASS 锚点）:
#   · 参数：零参 / `--self-test` / `--negative`；未知参数即失败
#   · 工具：scripts/env.sh source rc=0；RV32_IVERILOG/RV32_VVP 非空可执行；timeout/sha256sum 存在
#   · 编译：rc=0 且产出**非空** vvp（零产物/超时 ⇒ 失败）
#   · 逐向量：0..7 每例恰一条严格格式 `CASE <id> <name> KIND=<k> VERDICT=<v> nchk=<N>`；
#             name/KIND 与脚本冻结表一致；nchk 非零且 >= 冻结下限；日志无 `MISMATCH`
#   · 默认：10/10 OK；`ROB_WINDOW_COV` 每例 raw=0，case0 hit=0，case1..9 (hit+miss)>0
#   · 反证：旧候选 case0 OK + case1..8 DEFECT_SIG（case9 单独记录）；新树 10/10 OK
#   · b227：旧候选 case0..7+9 OK、case8 DEFECT_SIG；新树 10/10 OK；冻结输入未变
#   · 摘要：`^ROB_WINDOW_VECTORS ` / `^ROB_WINDOW_NEGATIVE_MATRIX ` 各恰一行且字段精确
#   · 锚点：默认 `FUNCTIONAL_ROB_WINDOW: PASS` 恰 1 行；反证为 0 行且反向锚点恰 1 行
#
# 用法 : bash sim/functional/test_rob_window.sh
#        bash sim/functional/test_rob_window.sh --self-test
#        DUT_ROOT=<只读源根> bash sim/functional/test_rob_window.sh
#        OUT_DIR=<产物根>    bash sim/functional/test_rob_window.sh
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数 / 模式
#------------------------------------------------------------------------------
NEG=0
B227=0
MUTHPV=0
HARNESS=0
B227SELFTEST=0
if [ "$#" -gt 1 ]; then
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test|--negative) NEG=1 ;;
        --b227) B227=1 ;;
        --mut-hpv) MUTHPV=1 ;;
        --harness-selftest) HARNESS=1 ;;
        --b227-selftest) B227SELFTEST=1 ;;
        *) printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=unknown_arg argv=%s\n' "$1"; exit 1 ;;
    esac
fi
case "${RV32_ROBWIN_MODE:-spec}" in
    spec)   ;;
    defect) NEG=1 ;;
    b227)   B227=1 ;;
    mut-hpv) MUTHPV=1 ;;
    harness-selftest) HARNESS=1 ;;
    b227-selftest) B227SELFTEST=1 ;;
    *) printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=bad_mode value=%s\n' "${RV32_ROBWIN_MODE}"; exit 1 ;;
esac
if [ "$NEG" -eq 1 ] && [ "$B227" -eq 1 ]; then
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=conflicting_modes negative+b227\n'; exit 1
fi
if [ "$MUTHPV" -eq 1 ] && { [ "$NEG" -eq 1 ] || [ "$B227" -eq 1 ]; }; then
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=conflicting_modes mut-hpv+other\n'; exit 1
fi
if [ "$HARNESS" -eq 1 ] && { [ "$NEG" -eq 1 ] || [ "$B227" -eq 1 ] || [ "$MUTHPV" -eq 1 ]; }; then
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=conflicting_modes harness+other\n'; exit 1
fi
if [ "$B227SELFTEST" -eq 1 ] && { [ "$NEG" -eq 1 ] || [ "$B227" -eq 1 ] || [ "$MUTHPV" -eq 1 ] || [ "$HARNESS" -eq 1 ]; }; then
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=conflicting_modes b227-selftest+other\n'; exit 1
fi

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-600}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-120}"

#------------------------------------------------------------------------------
# 1. 路径解析（按脚本自身位置推导，不依赖调用者 cwd）
#------------------------------------------------------------------------------
SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_rob_window_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

# ---- 本包冻结规格（与 TB 的 CASE 表 / is_trigger() 同步）----
SPEC_TOTAL=11
SPEC_TRIGGER=8
SPEC_CONTROL=3
TRIGGER_CASES="1 2 3 4 5 6 7 8"
MIN_NCHK=(20 40 140 255 28 45 160 40 28 38 44)
#   ★ 正式复验可移交性：b227 旧候选 = **in-tree 固定 fixture**（从母只读 r0 逐字复制，
#     仅 simulation 目录，不进产品 RTL 树，避免重复模块收集）。
#     默认根 = $DUT_ROOT/sim/functional/fixtures/rob_window_b227；不再 hardcode 母本机
#     build/functional/rob-review-r0-w1oii3zz（干净 checkout 可重建）。
#     显式 RV32_ROBWIN_B227_ROOT 仍允许（必须是同一 b227 三依赖身份，只读）。
B227_ROB_SHA="b227f017a03d8d90af02e9113f823a48a4ae63963443b0fe72b765953ccb05b5"
B227_WIDE_SHA="41ae6420e434b7748f62a0a8f3e09685723d97c78890fc6e2c327f2f9e0f41fc"
B227_PARAMS_SHA="066c8a7a30eac41c81f64788a3c3f80c4330f2ebec908ba5f940ad9bd1b48e34"
B227_ROOT="${RV32_ROBWIN_B227_ROOT:-$REPO_ROOT/sim/functional/fixtures/rob_window_b227}"

case_name_of() {
    case "$1" in
        0) echo empty_no_stale_pc;;
        1) echo prefetch_stale_realloc;;
        2) echo shallow_alloc_raw;;
        3) echo wrap_flush_reuse;;
        4) echo squash_kill_reuse;;
        5) echo stale_trap_pc;;
        6) echo two_wide_sustained;;
        7) echo alloc_commit_flush_same;;
        8) echo squash_read_cross;;
        9) echo squash_diff_idx_ctrl;;
        10) echo hpv_live_nondone;;
        *) echo "";;
    esac
}

# 本包只编译 ROB 及其宽存/参数头（不依赖 backend_top / 其他正在变化的域）。
DEP_FILES=( rtl/back2/rob.v rtl/back2/rob_wide_mem.v )
REQ_HEADERS=( rtl/back2/back2_params.vh )
FROZEN_COUNT=$(( ${#DEP_FILES[@]} + ${#REQ_HEADERS[@]} + 1 ))   # + 冻结 TB

#------------------------------------------------------------------------------
# 2. 判定状态与输出助手
#------------------------------------------------------------------------------
RUN_DIR=""
SUM_OK="-"; SUM_BAD="-"
FREEZE_TB=""
FREEZE_SHA=""
TB_SRC_SHA0=""
PKG_SRC=""
PKG_SHA0=""
ENV_SHA0=""

is_sha1() {
    case "${1:-}" in *[!0-9a-f]*) return 1;; esac
    [ "${#1}" -eq 64 ]
}

sha1_of() {
    local f="$1" out rc n v
    [ -f "$f" ] || { echo "sha1_of: not a file: $f" >> "$RUN_LOG"; return 1; }
    out="$(sha256sum -- "$f" 2>>"$RUN_LOG")"; rc=$?
    [ "$rc" -eq 0 ] || { echo "sha1_of: sha256sum rc=$rc file=$f" >> "$RUN_LOG"; return 1; }
    n="$(printf '%s\n' "$out" | grep -cE '^[0-9a-f]{64}  ' || true)"
    [ "$n" -eq 1 ] || { echo "sha1_of: hex-line count=$n (expect 1) file=$f" >> "$RUN_LOG"; return 1; }
    v="$(printf '%s\n' "$out" | cut -c1-64)"
    is_sha1 "$v" || { echo "sha1_of: malformed hex '$v' file=$f" >> "$RUN_LOG"; return 1; }
    printf '%s\n' "$v"
    return 0
}

sha1_checked() {
    local f="$1" v
    v="$(sha1_of "$f")" || return 1
    is_sha1 "$v" || return 1
    printf '%s\n' "$v"
    return 0
}

b227_identity_check() {  # $1=root；成功 stdout 为空 rc=0；失败 stdout=精确 reason
    local root="$1" rel exp h pair
    for pair in "rtl/back2/rob.v:$B227_ROB_SHA" \
                "rtl/back2/rob_wide_mem.v:$B227_WIDE_SHA" \
                "rtl/back2/back2_params.vh:$B227_PARAMS_SHA"; do
        rel="${pair%%:*}"; exp="${pair#*:}"
        [ -f "$root/$rel" ] || { printf 'b227_identity_missing:%s' "$rel"; return 1; }
        h="$(sha1_checked "$root/$rel")" || { printf 'b227_identity_sha_unavailable:%s' "$rel"; return 1; }
        [ "$h" = "$exp" ] || { printf 'b227_identity_mismatch:%s:got=%s:exp=%s' "$rel" "$h" "$exp"; return 1; }
    done
    return 0
}

verify_tb_frozen() {
    local now
    [ -n "$FREEZE_TB" ] && [ -f "$FREEZE_TB" ] || return 1
    is_sha1 "${FREEZE_SHA:-}" || return 1
    now="$(sha1_checked "$FREEZE_TB")" || return 1
    [ "$now" = "$FREEZE_SHA" ] || return 1
    return 0
}

verify_tb_src_unchanged() {
    local now
    is_sha1 "${TB_SRC_SHA0:-}" || return 1
    now="$(sha1_checked "$TB_SRC")" || return 1
    [ "$now" = "$TB_SRC_SHA0" ] || return 1
    return 0
}

verify_pkg_unchanged() {
    local now
    is_sha1 "${PKG_SHA0:-}" || return 1
    now="$(sha1_checked "$PKG_SRC")" || return 1
    [ "$now" = "$PKG_SHA0" ] || return 1
    return 0
}

verify_env_unchanged() {
    local now
    is_sha1 "${ENV_SHA0:-}" || return 1
    now="$(sha1_checked "$ENV_SH")" || return 1
    [ "$now" = "$ENV_SHA0" ] || return 1
    return 0
}

emit_fail() {
    if [ "$NEG" -eq 1 ]; then
        printf 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    elif [ "$B227" -eq 1 ]; then
        printf 'FUNCTIONAL_ROB_WINDOW_B227: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    elif [ "$MUTHPV" -eq 1 ]; then
        printf 'FUNCTIONAL_ROB_WINDOW_HPV: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    elif [ "$HARNESS" -eq 1 ]; then
        printf 'ROB_WINDOW_HARNESS_SELFTEST: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    elif [ "$B227SELFTEST" -eq 1 ]; then
        printf 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    else
        printf 'ROB_WINDOW_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
               "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$SUM_OK" "$SUM_BAD"
        printf 'FUNCTIONAL_ROB_WINDOW: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

#------------------------------------------------------------------------------
# 3. 产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run 目录（绝不 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/rob-window}}"

is_authorized() {
    case "$1" in
        "$AUTH_ROOT" | "$AUTH_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_readlink_failed root=$ROOT_RAW"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM auth=$AUTH_ROOT"
mkdir -p -- "$ROOT_NORM" || emit_fail "out_root_mkdir_failed root=$ROOT_NORM"
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail "out_root_recheck_readlink_failed"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized_after_mkdir root=$ROOT_NORM"

RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail "mktemp_run_dir_failed root=$ROOT_NORM"
RUN_LOG="$RUN_DIR/test_rob_window.log"
VVP_OUT="$RUN_DIR/tb_rob_window_semantics.vvp"
printf 'ROB_WINDOW_RUN_DIR=%s\n' "$RUN_DIR"

: > "$RUN_LOG" || emit_fail "run_log_create_failed"

{
    echo "==== test_rob_window.sh : ROB head-window semantics (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "MODE            = $([ "$NEG" -eq 1 ] && echo self-test || echo spec)"
    echo "SELF_DIR        = $SELF_DIR"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "AUTH_ROOT       = $AUTH_ROOT"
    echo "TB_SRC          = $TB_SRC"
    echo "SPEC            = total=$SPEC_TOTAL trigger=$SPEC_TRIGGER control=$SPEC_CONTROL min_nchk=per_case"
    echo "FROZEN_COUNT    = $FROZEN_COUNT (RTL ${#DEP_FILES[@]} + header ${#REQ_HEADERS[@]} + TB 1)"
    echo "=========================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

#------------------------------------------------------------------------------
# 3b. 冻结 TB（新旧两阶段共用）+ 记录源 TB / env 的起始 sha256
#------------------------------------------------------------------------------
[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"
TB_SRC_SHA0="$(sha1_checked "$TB_SRC")" || emit_fail "tb_sha_unavailable"
FREEZE_TB="$RUN_DIR/tb-frozen.sv"
cp -p -- "$TB_SRC" "$FREEZE_TB" || emit_fail "freeze_tb_copy_failed"
FREEZE_SHA="$(sha1_checked "$FREEZE_TB")" || emit_fail "freeze_tb_sha_unavailable"
[ "$FREEZE_SHA" = "$TB_SRC_SHA0" ] || emit_fail "freeze_tb_sha_mismatch"
PKG_SRC="$SELF_PATH"
PKG_SHA0="$(sha1_checked "$PKG_SRC")" || emit_fail "pkg_sha_unavailable"
ENV_SHA0="$(sha1_checked "$ENV_SH")"  || emit_fail "env_sha_unavailable"
{
    echo "TB_FROZEN       = $FREEZE_TB"
    echo "TB_FROZEN_SHA   = $FREEZE_SHA"
    echo "PKG_SRC         = $PKG_SRC"
    echo "PKG_SHA         = $PKG_SHA0"
    echo "ENV_SH          = $ENV_SH"
    echo "ENV_SH_SHA      = $ENV_SHA0"
} >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 4. 工具真源：scripts/env.sh（只读）；工具缺失/不可执行即失败
#------------------------------------------------------------------------------
[ -r "$ENV_SH" ] || emit_fail "env_sh_unreadable path=$ENV_SH"
ENV_RC=0
# shellcheck disable=SC1090
. "$ENV_SH" >> "$RUN_LOG" 2>&1 || ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"
verify_env_unchanged || emit_fail "env_changed_while_sourcing"

IV="${RV32_IVERILOG:-}"
VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing name=RV32_IVERILOG value=${IV:-unset}"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing name=RV32_VVP value=${VV:-unset}"
command -v timeout   >/dev/null 2>&1 || emit_fail "tool_missing name=timeout"
command -v sha256sum >/dev/null 2>&1 || emit_fail "tool_missing name=sha256sum"
echo "RV32_IVERILOG   = $IV" >> "$RUN_LOG"
echo "RV32_VVP        = $VV" >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 5a. 不可变输入快照：只复制本包实际依赖闭包（$1=源根 $2=快照目录）
#------------------------------------------------------------------------------
snapshot_root() {
    local root="$1" snap="$2" rel f
    [ -d "$root" ] || { echo "snapshot: source root missing $root" >> "$RUN_LOG"; return 1; }
    mkdir -p -- "$snap" || return 1
    for rel in "${DEP_FILES[@]}"; do
        [ -f "$root/$rel" ] || { echo "snapshot: missing $root/$rel" >> "$RUN_LOG"; return 1; }
        mkdir -p -- "$snap/$(dirname -- "$rel")" || return 1
        cp -p -- "$root/$rel" "$snap/$rel" || return 1
    done
    for rel in "${REQ_HEADERS[@]}"; do
        [ -f "$root/$rel" ] || { echo "snapshot: MISSING required header $root/$rel" >> "$RUN_LOG"; return 1; }
        mkdir -p -- "$snap/$(dirname -- "$rel")" || return 1
        cp -p -- "$root/$rel" "$snap/$rel" || return 1
    done
    cp -p -- "$FREEZE_TB" "$snap/tb-frozen.sv" || return 1
    return 0
}

#------------------------------------------------------------------------------
# 5b. 编译**快照**；记录**实际所有编译源**的 sha256（行数+格式严格校验）
#     $1=快照根 $2=输出 vvp $3=阶段标签
#------------------------------------------------------------------------------
compile_root() {
    local root="$1" vvp="$2" tag="$3"
    local tb="$root/tb-frozen.sv"
    local f rc n sha_out n_lines n_ok sha_rc n_expect
    [ -d "$root" ] || { echo "[$tag] source root missing: $root" >> "$RUN_LOG"; return 1; }
    [ -f "$tb" ]      || { echo "[$tag] frozen TB missing: $tb" >> "$RUN_LOG"; return 1; }
    local files=() missing=0
    for f in "${DEP_FILES[@]}"; do
        if [ -f "$root/$f" ]; then files+=( "$root/$f" ); else
            echo "[$tag] MISSING dependency: $root/$f" >> "$RUN_LOG"; missing=1
        fi
    done
    local hdrs=()
    for f in "${REQ_HEADERS[@]}"; do
        if [ -f "$root/$f" ]; then hdrs+=( "$root/$f" ); else
            echo "[$tag] MISSING required header: $root/$f" >> "$RUN_LOG"; missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1
    n_expect=$(( ${#files[@]} + ${#hdrs[@]} + 1 ))
    if [ "$n_expect" -ne "$FROZEN_COUNT" ]; then
        echo "[$tag] fixed closure count mismatch: $n_expect != $FROZEN_COUNT" >> "$RUN_LOG"; return 1
    fi

    sha_out="$(sha256sum -- "$tb" "${files[@]}" "${hdrs[@]}" 2>&1)"; sha_rc=$?
    if [ "$sha_rc" -ne 0 ]; then echo "[$tag] sha256 command rc=$sha_rc" >> "$RUN_LOG"; return 1; fi
    n_lines="$(printf '%s\n' "$sha_out" | grep -c . || true)"
    n_ok="$(printf '%s\n' "$sha_out" | grep -cE '^[0-9a-f]{64}  ' || true)"
    if [ "$n_ok" -ne "$n_expect" ] || [ "$n_lines" -ne "$n_ok" ]; then
        echo "[$tag] sha256 line check failed lines=$n_lines hex=$n_ok expect=$n_expect" >> "$RUN_LOG"
        printf '%s\n' "$sha_out" >> "$RUN_LOG"
        return 1
    fi
    printf '%s\n' "$sha_out" > "$RUN_DIR/$tag.sha" || return 1
    {
        echo "-- [$tag] SNAPSHOT_ROOT = $root"
        echo "-- [$tag] TB = $tb"
        echo "-- [$tag] inputs: ${#files[@]} RTL + ${#hdrs[@]} header + 1 TB = $n_expect (sha256 below) --"
        printf '%s\n' "$sha_out"
    } >> "$RUN_LOG"

    ( cd -- "$root" && timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 \
            -I "$root/rtl/pkg" -I "$root" -I . \
            -s tb_rob_window_semantics -o "$vvp" "$tb" "${files[@]}" ) \
            > "$RUN_LOG.compile.$tag" 2>&1
    rc=$?
    cat -- "$RUN_LOG.compile.$tag" >> "$RUN_LOG" || return 1
    if [ "$rc" -eq 124 ]; then echo "[$tag] compile timeout" >> "$RUN_LOG"; return 124; fi
    if [ "$rc" -ne 0 ]; then echo "[$tag] compile rc=$rc" >> "$RUN_LOG"; return "$rc"; fi
    n=$(stat -c %s -- "$vvp" 2>/dev/null || echo 0)
    if [ ! -s "$vvp" ]; then echo "[$tag] compile rc=0 but zero-size vvp (need -s artifact)" >> "$RUN_LOG"; return 1; fi
    echo "[$tag] compile ok, vvp bytes=$n" >> "$RUN_LOG"
    return 0
}

verify_sha_unchanged() {
    local tag="$1" now
    [ -s "$RUN_DIR/$tag.sha" ] || { echo "[$tag] sha list missing" >> "$RUN_LOG"; return 1; }
    now="$(sha256sum -c --quiet -- "$RUN_DIR/$tag.sha" 2>&1)"; local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[$tag] inputs changed during run (sha256 -c rc=$rc):" >> "$RUN_LOG"
        printf '%s\n' "$now" >> "$RUN_LOG"
        return 1
    fi
    echo "[$tag] sha256 before/after identical (inputs unchanged)" >> "$RUN_LOG"
    return 0
}

#------------------------------------------------------------------------------
# 6. 跑单向量并判定（严格格式 + 冻结 name/KIND + nchk 下限 + 四态）
#    $1 = vvp  $2 = case  $3 = 期望 verdict  $4 = 阶段标签  $5 = 是否要求 raw=0
#------------------------------------------------------------------------------
judge_log() {  # $1=log $2=case $3=expect $4=tag $5=need_rawzero；判定单例日志（不跑 vvp）
    local log="$1" case="$2" expect="$3" tag="$4" need_rawzero="$5"
    local n_case kind verdict exp_kind exp_name minn nchk nV nK cov raw e h m n_cov_all n_def n_fail
    exp_name="$(case_name_of "$case")"
    [ -n "$exp_name" ] || { echo "[$tag] case $case 不在冻结 ID/name 表（fail-closed）" >> "$RUN_LOG"; return 1; }

    n_case="$(grep -cE '^CASE ' "$log" || true)"
    if [ "$n_case" -ne 1 ]; then
        echo "[$tag] case $case 的 CASE 行数=$n_case（期望 1；额外/异号/重复皆拒）" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true
        return 1
    fi
    if ! grep -qE "^CASE ${case} ${exp_name} KIND=(trigger|control) VERDICT=(OK|DEFECT_SIG) nchk=[0-9]+$" "$log"; then
        echo "[$tag] case $case 严格 CASE 行不匹配（期望 id=$case name=$exp_name）" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true
        return 1
    fi
    nV="$(grep -oE 'VERDICT=' "$log" | wc -l)"; nK="$(grep -oE 'KIND=' "$log" | wc -l)"
    if [ "$nV" -ne 1 ] || [ "$nK" -ne 1 ]; then
        echo "[$tag] case $case 字段冲突/重复 KIND=$nK VERDICT=$nV" >> "$RUN_LOG"; return 1
    fi
    kind="$(sed -nE "s/^CASE ${case} ${exp_name} KIND=([a-z]+) .*/\1/p" "$log")"
    verdict="$(sed -nE "s/^CASE ${case} ${exp_name} KIND=[a-z]+ VERDICT=([A-Z_]+).*/\1/p" "$log")"
    nchk="$(sed -nE "s/^CASE ${case} ${exp_name} KIND=[a-z]+ VERDICT=[A-Z_]+ nchk=([0-9]+)$/\1/p" "$log")"

    minn="${MIN_NCHK[$case]}"
    if [ -z "$nchk" ] || [ "$nchk" -eq 0 ]; then
        echo "[$tag] case $case nchk=$nchk（必须真实非零）" >> "$RUN_LOG"; return 1
    fi
    if [ "$nchk" -lt "$minn" ]; then
        echo "[$tag] case $case nchk=$nchk < 冻结下限 $minn" >> "$RUN_LOG"; return 1
    fi

    exp_kind=control
    local tc
    for tc in $TRIGGER_CASES; do [ "$tc" = "$case" ] && exp_kind=trigger; done
    if [ "$kind" != "$exp_kind" ]; then
        echo "[$tag] case $case KIND=$kind expect=$exp_kind (TB/脚本漂移)" >> "$RUN_LOG"; return 1
    fi
    if [ "$verdict" != "$expect" ]; then
        echo "[$tag] case $case VERDICT=$verdict expect=$expect" >> "$RUN_LOG"
        cat -- "$log" >> "$RUN_LOG"; return 1
    fi

    # ---- ★ 审阅 P1-2a：DEFECT 策略（默认拒任意 DEFECT；负模式只许唯一预期 CASE 行）----
    n_def="$(grep -c 'DEFECT' "$log" || true)"
    if [ "$expect" = "OK" ]; then
        [ "$n_def" -eq 0 ] || { echo "[$tag] case $case OK 日志含任意 DEFECT=$n_def（含 DEFECT_ARBITRARY/REPRODUCED 等）" >> "$RUN_LOG"; return 1; }
    else
        #   只允许严格 CASE 行里的那一个 DEFECT_SIG；额外 DEFECT 行/标记一律拒
        [ "$n_def" -eq 1 ] || { echo "[$tag] case $case DEFECT_SIG 日志含 DEFECT 行=$n_def（期望仅 CASE 行 1 行）" >> "$RUN_LOG"; return 1; }
        [ "$(grep -cE "^CASE ${case} ${exp_name} KIND=(trigger|control) VERDICT=DEFECT_SIG nchk=[0-9]+$" "$log" || true)" -eq 1 ] \
            || { echo "[$tag] case $case DEFECT 不在严格 CASE 行" >> "$RUN_LOG"; return 1; }
    fi
    n_fail="$(grep -c 'FAIL' "$log" || true)"
    [ "$n_fail" -eq 0 ] || { echo "[$tag] case $case 日志含 FAIL=$n_fail" >> "$RUN_LOG"; return 1; }

    # ---- ★ 审阅 P1-2b：COV 前缀**恰 1 行**且必须是本 case（异号 COV99/重复皆拒）----
    n_cov_all="$(grep -cE '^ROB_WINDOW_COV ' "$log" || true)"
    if [ "$n_cov_all" -ne 1 ]; then
        echo "[$tag] case $case COV 行总数=$n_cov_all（期望 1；异号/重复皆拒）" >> "$RUN_LOG"; return 1
    fi
    n_case="$(grep -cE "^ROB_WINDOW_COV case=${case} empty=[0-9]+ hit=[0-9]+ miss=[0-9]+ raw=[0-9]+$" "$log" || true)"
    if [ "$n_case" -ne 1 ]; then
        echo "[$tag] case $case 四态行数=$n_case（期望 1）" >> "$RUN_LOG"; return 1
    fi
    cov="$(grep -E "^ROB_WINDOW_COV case=${case} " "$log")"
    e="$(printf '%s\n' "$cov" | sed -nE 's/.* empty=([0-9]+) .*/\1/p')"
    h="$(printf '%s\n' "$cov" | sed -nE 's/.* hit=([0-9]+) .*/\1/p')"
    m="$(printf '%s\n' "$cov" | sed -nE 's/.* miss=([0-9]+) .*/\1/p')"
    raw="$(printf '%s\n' "$cov" | sed -nE 's/.* raw=([0-9]+)$/\1/p')"
    for v in "$e" "$h" "$m" "$raw"; do
        case "$v" in ''|*[!0-9]*) echo "[$tag] case $case 四态字段非法" >> "$RUN_LOG"; return 1;; esac
    done
    if [ "$need_rawzero" -eq 1 ] && [ "$raw" -ne 0 ]; then
        echo "[$tag] case $case raw=$raw（新树必须为 0：窗口不得吃未分配/旧世代载荷）" >> "$RUN_LOG"; return 1
    fi
    if [ "$expect" = "OK" ]; then
        if [ "$case" -eq 0 ]; then
            [ "$h" -eq 0 ] && [ "$e" -gt 0 ] || { echo "[$tag] case0 四态期望 empty>0,hit=0" >> "$RUN_LOG"; return 1; }
        else
            [ $((h+m)) -gt 0 ] || { echo "[$tag] case $case 四态 hit+miss=0（窗口从未经历有效/无效）" >> "$RUN_LOG"; return 1; }
            [ "$h" -gt 0 ] || { echo "[$tag] case $case hit=0（根修不得把有效窗口永久压死）" >> "$RUN_LOG"; return 1; }
        fi
        #   默认/正控成功日志：不得含任何 MISMATCH（根因暴露 |
        [ "$(grep -c 'MISMATCH' "$log" || true)" -eq 0 ] \
            || { echo "[$tag] case $case 成功日志含 MISMATCH" >> "$RUN_LOG"; return 1; }
    fi

    cat -- "$log" >> "$RUN_LOG"
    printf 'VEC %s %s %s kind=%s verdict=%s nchk=%s cov(E/H/M/R)=%s/%s/%s/%s\n' \
           "$tag" "$case" "$exp_name" "$kind" "$verdict" "$nchk" "$e" "$h" "$m" "$raw" >> "$RUN_LOG"
    return 0
}

run_one() {
    local vvp="$1" case="$2" expect="$3" tag="$4" need_rawzero="$5"
    local log rc sz
    log="$RUN_DIR/${tag}_case_${case}.log"
    [ -n "$(case_name_of "$case")" ] || { echo "[$tag] case $case 不在冻结 ID/name 表（fail-closed）" >> "$RUN_LOG"; return 1; }

    timeout "$TIMEOUT_RUN_S" "$VV" "$vvp" "+CASE=$case" > "$log" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "[$tag] case $case run timeout (${TIMEOUT_RUN_S}s)" >> "$RUN_LOG"; return 124
    fi
    if [ "$rc" -ne 0 ]; then
        echo "[$tag] case $case run rc=$rc" >> "$RUN_LOG"; cat -- "$log" >> "$RUN_LOG"; return "$rc"
    fi
    sz=$(stat -c %s -- "$log" 2>/dev/null || echo 0)
    if [ "$sz" -eq 0 ]; then echo "[$tag] case $case zero output" >> "$RUN_LOG"; return 1; fi

    judge_log "$log" "$case" "$expect" "$tag" "$need_rawzero"
}

check_vec_lines() {
    local tag="$1" expect="$2" n bad c expn n1
    n="$(grep -cE "^VEC ${tag} [0-9]+ [a-z0-9_]+ kind=(trigger|control) verdict=[A-Z_]+ nchk=[0-9]+ cov\(E/H/M/R\)=[0-9]+/[0-9]+/[0-9]+/[0-9]+$" "$RUN_LOG" || true)"
    [ "$n" = "$expect" ] || emit_fail "vec_count_${tag}=$n expect=$expect"
    for c in $(seq 0 $((SPEC_TOTAL-1))); do
        expn="$(case_name_of "$c")"
        [ -n "$expn" ] || emit_fail "vec_name_table_missing id=$c"
        n1="$(grep -cE "^VEC ${tag} ${c} ${expn} kind=(trigger|control) verdict=[A-Z_]+ nchk=[0-9]+ cov" "$RUN_LOG" || true)"
        [ "$n1" -eq 1 ] || emit_fail "vec_name_${tag}_case${c}=${n1} expect=1"
    done
    bad="$(awk -v t="$tag" '
        $1=="VEC" && $2==t { seen[$3]++ }
        END { for (k in seen) if (seen[k]!=1) b++; printf "%d", b+0 }
    ' "$RUN_LOG")"
    [ "$bad" = "0" ] || emit_fail "vec_dup_${tag}=$bad"
}

#------------------------------------------------------------------------------
# 6b. 包装器自检模式（--harness-selftest）：合成日志喂 judge_log
#     覆盖审阅 P1-2：任意 DEFECT（含 ARBITRARY/REPRODUCED）、异号/重复 COV、
#     额外 CASE/异号 DEFECT/FAIL/错 VERDICT 必须被拒；正常 default/negative 日志必须过。
#------------------------------------------------------------------------------
if [ "$HARNESS" -eq 1 ]; then
    HS_DIR="$RUN_DIR/harness"
    mkdir -p -- "$HS_DIR" || emit_fail "harness_mkdir_failed"
    HS_PASS=0; HS_KILL=0
    hs_make() {  # $1=file; 其余按行写入
        local f="$1"; shift
        : > "$f" || return 1
        printf '%s\n' "$@" > "$f"
    }
    hs_expect() {  # $1=name $2=expect_rc(0/1) $3=case $4=expect_verdict $5=need_rawzero $6=log
        local name="$1" want="$2" case="$3" exp="$4" nrz="$5" log="$6" rc
        judge_log "$log" "$case" "$exp" "hs_$name" "$nrz"
        rc=$?
        if [ "$want" -eq 0 ]; then
            if [ "$rc" -ne 0 ]; then echo "[harness] $name expected ACCEPT got rc=$rc" >> "$RUN_LOG"; return 1; fi
            HS_PASS=$((HS_PASS+1))
        else
            if [ "$rc" -eq 0 ]; then echo "[harness] $name expected REJECT got accept" >> "$RUN_LOG"; return 1; fi
            HS_KILL=$((HS_KILL+1))
        fi
        return 0
    }

    hs_make "$HS_DIR/good_default.log" \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25'
    hs_make "$HS_DIR/good_neg.log" \
        'MISMATCH case=8 cyc=14 head_pc_valid=1 but PC stale got=b0000004 exp=b0000100' \
        'ROB_WINDOW_COV case=8 empty=7 hit=8 miss=3 raw=1' \
        'CASE 8 squash_read_cross KIND=trigger VERDICT=DEFECT_SIG nchk=34'
    hs_make "$HS_DIR/m_defect_arb.log" \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25' \
        'DEFECT_ARBITRARY payload'
    hs_make "$HS_DIR/m_defect_rep.log" \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25' \
        'DEFECT_REPRODUCED x'
    hs_make "$HS_DIR/m_cov99.log" \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'ROB_WINDOW_COV case=99 empty=1 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25'
    hs_make "$HS_DIR/m_covdup.log" \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25'
    hs_make "$HS_DIR/m_case99.log" \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25' \
        'CASE 99 unknown KIND=control VERDICT=OK nchk=1'
    hs_make "$HS_DIR/m_neg_extra_def.log" \
        'MISMATCH case=8 raw' \
        'ROB_WINDOW_COV case=8 empty=7 hit=8 miss=3 raw=1' \
        'CASE 8 squash_read_cross KIND=trigger VERDICT=DEFECT_SIG nchk=34' \
        'DEFECT_OTHER x'
    hs_make "$HS_DIR/m_neg_case9.log" \
        'MISMATCH case=8 raw' \
        'ROB_WINDOW_COV case=8 empty=7 hit=8 miss=3 raw=1' \
        'CASE 8 squash_read_cross KIND=trigger VERDICT=DEFECT_SIG nchk=34' \
        'CASE 9 squash_diff_idx_ctrl KIND=control VERDICT=DEFECT_SIG nchk=40'
    hs_make "$HS_DIR/m_neg_fail.log" \
        'MISMATCH case=8 raw' \
        'ROB_WINDOW_COV case=8 empty=7 hit=8 miss=3 raw=1' \
        'CASE 8 squash_read_cross KIND=trigger VERDICT=DEFECT_SIG nchk=34' \
        'FAIL something'
    hs_make "$HS_DIR/m_neg_ok.log" \
        'ROB_WINDOW_COV case=8 empty=7 hit=8 miss=3 raw=1' \
        'CASE 8 squash_read_cross KIND=trigger VERDICT=OK nchk=34'
    hs_make "$HS_DIR/m_neg_cov7.log" \
        'MISMATCH case=8 raw' \
        'ROB_WINDOW_COV case=7 empty=7 hit=8 miss=3 raw=1' \
        'CASE 8 squash_read_cross KIND=trigger VERDICT=DEFECT_SIG nchk=34'
    hs_make "$HS_DIR/m_default_mis.log" \
        'MISMATCH case=0 x' \
        'ROB_WINDOW_COV case=0 empty=15 hit=0 miss=0 raw=0' \
        'CASE 0 empty_no_stale_pc KIND=control VERDICT=OK nchk=25'

    hs_expect good_default 0 0 OK 1 "$HS_DIR/good_default.log" || emit_fail "harness_good_default"
    hs_expect good_negative 0 8 DEFECT_SIG 0 "$HS_DIR/good_neg.log" || emit_fail "harness_good_negative"
    hs_expect defect_arbitrary 1 0 OK 1 "$HS_DIR/m_defect_arb.log" || emit_fail "harness_defect_arbitrary"
    hs_expect defect_reproduced 1 0 OK 1 "$HS_DIR/m_defect_rep.log" || emit_fail "harness_defect_reproduced"
    hs_expect cov99_extra 1 0 OK 1 "$HS_DIR/m_cov99.log" || emit_fail "harness_cov99"
    hs_expect cov_dup 1 0 OK 1 "$HS_DIR/m_covdup.log" || emit_fail "harness_cov_dup"
    hs_expect case99_extra 1 0 OK 1 "$HS_DIR/m_case99.log" || emit_fail "harness_case99"
    hs_expect neg_extra_defect 1 8 DEFECT_SIG 0 "$HS_DIR/m_neg_extra_def.log" || emit_fail "harness_neg_extra_defect"
    hs_expect neg_case9_defect 1 8 DEFECT_SIG 0 "$HS_DIR/m_neg_case9.log" || emit_fail "harness_neg_case9"
    hs_expect neg_fail_line 1 8 DEFECT_SIG 0 "$HS_DIR/m_neg_fail.log" || emit_fail "harness_neg_fail"
    hs_expect neg_ok_verdict 1 8 DEFECT_SIG 0 "$HS_DIR/m_neg_ok.log" || emit_fail "harness_neg_ok"
    hs_expect neg_cov_wrong_case 1 8 DEFECT_SIG 0 "$HS_DIR/m_neg_cov7.log" || emit_fail "harness_neg_cov_wrong"
    hs_expect default_mismatch 1 0 OK 1 "$HS_DIR/m_default_mis.log" || emit_fail "harness_default_mismatch"

    [ "$HS_PASS" -eq 2 ] || emit_fail "harness_pass_count=$HS_PASS expect=2"
    [ "$HS_KILL" -eq 11 ] || emit_fail "harness_kill_count=$HS_KILL expect=11"
    printf 'ROB_WINDOW_HARNESS_MATRIX good=2/2 kill=11/11\n' >> "$RUN_LOG"
    N_SUM="$(grep -c '^ROB_WINDOW_HARNESS_MATRIX ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "harness_summary_count=$N_SUM"
    if [ "$(grep -m1 '^ROB_WINDOW_HARNESS_MATRIX ' "$RUN_LOG")" != 'ROB_WINDOW_HARNESS_MATRIX good=2/2 kill=11/11' ]; then
        emit_fail "harness_summary_format"
    fi
    #   ★ 注意：负 fixture 的"预期拒绝"诊断本身会带 FAIL 字样（被拒日志未追加），
    #     故这里不能用 `grep FAIL` 作为全局判据；以 HS_PASS/HS_KILL + 唯一锚点为准。
    N_PASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "harness_default_anchor=$N_PASS"
    printf 'ROB_WINDOW_HARNESS_SELFTEST: PASS\n' >> "$RUN_LOG"
    N_HP="$(grep -cxF 'ROB_WINDOW_HARNESS_SELFTEST: PASS' "$RUN_LOG" || true)"
    [ "$N_HP" = "1" ] || emit_fail "harness_anchor_count=$N_HP"

    printf 'ROB_WINDOW_HARNESS_MATRIX good=2/2 kill=11/11\n'
    printf 'ROB_WINDOW_HARNESS_SELFTEST: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 7. 新源码（当前树 / DUT_ROOT）：8 向量全部 OK
#------------------------------------------------------------------------------
DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"
echo "DUT_ROOT        = $DUT_ROOT" >> "$RUN_LOG"

SNAP_NEW="$RUN_DIR/src-new"
snapshot_root "$DUT_ROOT" "$SNAP_NEW" || emit_fail "snapshot_new_failed root=$DUT_ROOT"
echo "SNAP_NEW        = $SNAP_NEW" >> "$RUN_LOG"
verify_tb_frozen || emit_fail "frozen_tb_changed_before_new"
compile_root "$SNAP_NEW" "$VVP_OUT" "new" || emit_fail "compile_new_failed"

OK_N=0; BAD_N=0
for c in $(seq 0 $((SPEC_TOTAL-1))); do
    if run_one "$VVP_OUT" "$c" "OK" "new" 1; then OK_N=$((OK_N+1)); else BAD_N=$((BAD_N+1)); fi
done
SUM_OK="$OK_N"; SUM_BAD="$BAD_N"
[ "$BAD_N" -eq 0 ] || emit_fail "new_source_bad_vectors=$BAD_N"
[ "$OK_N" -eq "$SPEC_TOTAL" ] || emit_fail "new_source_ok=$OK_N expect=$SPEC_TOTAL"
check_vec_lines "new" "$SPEC_TOTAL"
verify_sha_unchanged "new" || emit_fail "new_inputs_changed"

#------------------------------------------------------------------------------
# 8. 反证模式（单独）：冻结 rob.v → 精确生成"修前候选"（仅去 e_ok/e_bad 采信门）
#------------------------------------------------------------------------------
make_defect_candidate() {
    local src="$1" dst="$2" n0 n1
    [ -f "$src" ] || { echo "defect: source missing $src" >> "$RUN_LOG"; return 1; }
    sed -e 's/win_val\[0\] <= fhit0_w & ~fdang0_w & e_ok_q\[fsel0_w\] & ~e_bad_q;/win_val[0] <= fhit0_w \& ~fdang0_w;/' \
        -e 's/win_val\[1\] <= fhit1_w & ~fdang1_w & e_ok_q\[fsel1_w\] & ~e_bad_q;/win_val[1] <= fhit1_w \& ~fdang1_w;/' \
        -- "$src" > "$dst" || return 1
    n0="$(grep -cF 'win_val[0] <= fhit0_w & ~fdang0_w;' -- "$dst" || true)"
    n1="$(grep -cF 'win_val[1] <= fhit1_w & ~fdang1_w;' -- "$dst" || true)"
    if [ "$n0" -ne 1 ] || [ "$n1" -ne 1 ]; then
        echo "defect: replacement count n0=$n0 n1=$n1 (expect 1/1)" >> "$RUN_LOG"; return 1
    fi
    if grep -qF 'e_ok_q[fsel0_w] & ~e_bad_q' -- "$dst" || grep -qF 'e_ok_q[fsel1_w] & ~e_bad_q' -- "$dst"; then
        echo "defect: e_ok/e_bad gate still present" >> "$RUN_LOG"; return 1
    fi
    #   保留 head_pc_valid_o 输出接口（同一冻结 TB 可编译）：断言该端口仍在
    grep -qF 'assign head_pc_valid_o' -- "$dst" || { echo "defect: head_pc_valid_o missing" >> "$RUN_LOG"; return 1; }
    return 0
}

if [ "$NEG" -eq 1 ]; then
    #   阶段间一致性：冻结 TB / 源 TB / 包脚本 / env 均不得变
    verify_tb_frozen          || emit_fail "frozen_tb_changed_between_phases"
    verify_tb_src_unchanged   || emit_fail "source_tb_changed_between_phases"
    verify_pkg_unchanged      || emit_fail "pkg_changed_between_phases"
    verify_env_unchanged      || emit_fail "env_changed_between_phases"

    SNAP_OLD="$RUN_DIR/src-old-defect"
    mkdir -p -- "$SNAP_OLD/rtl/back2" || emit_fail "snap_old_mkdir_failed"
    for rel in "${DEP_FILES[@]}"; do
        mkdir -p -- "$SNAP_OLD/$(dirname -- "$rel")" || emit_fail "snap_old_mkdir_failed rel=$rel"
        cp -p -- "$SNAP_NEW/$rel" "$SNAP_OLD/$rel" || emit_fail "snap_old_copy_failed rel=$rel"
    done
    for rel in "${REQ_HEADERS[@]}"; do
        mkdir -p -- "$SNAP_OLD/$(dirname -- "$rel")" || emit_fail "snap_old_mkdir_failed rel=$rel"
        cp -p -- "$SNAP_NEW/$rel" "$SNAP_OLD/$rel" || emit_fail "snap_old_copy_failed rel=$rel"
    done
    cp -p -- "$FREEZE_TB" "$SNAP_OLD/tb-frozen.sv" || emit_fail "snap_old_tb_copy_failed"
    make_defect_candidate "$SNAP_NEW/rtl/back2/rob.v" "$SNAP_OLD/rtl/back2/rob.v" \
        || emit_fail "defect_candidate_generation_failed"
    echo "SNAP_OLD        = $SNAP_OLD" >> "$RUN_LOG"

    OLD_VVP="$RUN_DIR/tb_rob_window_semantics_old.vvp"
    compile_root "$SNAP_OLD" "$OLD_VVP" "old" || emit_fail "compile_old_failed"

    OLD_TRIG_OK=0; OLD_TRIG_BAD=0; OLD_CTL_OK=0; OLD_CTL_BAD=0
    OLD_CTRL9_OK=0; OLD_CTRL9_BAD=0; OLD_RAW_TOTAL=0
    for c in $(seq 0 $((SPEC_TOTAL-1))); do
        exp="DEFECT_SIG"
        [ "$c" -eq 0 ] && exp="OK"
        [ "$c" -eq 10 ] && exp="OK"
        #   case9 在"去掉 e_ok/e_bad 的 defect 候选"上也会被通用旧值根因打红（预期）；
        #   它在 b227 旧候选上的同族正控绿由 --b227 模式单独证明。
        #   case10（safe-head 正活性）在 defect/b227 上都应绿（warm-up 隔离后窗口已新鲜）。
        if run_one "$OLD_VVP" "$c" "$exp" "old" 0; then
            if [ "$exp" = "DEFECT_SIG" ] && [ "$c" -eq 9 ]; then OLD_CTRL9_OK=$((OLD_CTRL9_OK+1))
            elif [ "$exp" = "DEFECT_SIG" ]; then OLD_TRIG_OK=$((OLD_TRIG_OK+1))
            else OLD_CTL_OK=$((OLD_CTL_OK+1)); fi
            if [ "$exp" = "DEFECT_SIG" ]; then
                #   根因签名必须真实出现（不是靠超时/编译错误冒充）
                if ! grep -qE 'MISMATCH.*(RAW win|head_pc_valid=1 but PC stale|commit lane=.*got_pc)' "$RUN_DIR/old_case_${c}.log"; then
                    emit_fail "old_case_${c}_no_root_signature"
                fi
                rawc="$(sed -nE 's/^ROB_WINDOW_COV .* raw=([0-9]+)$/\1/p' "$RUN_DIR/old_case_${c}.log")"
                [ -n "$rawc" ] || emit_fail "old_case_${c}_no_cov"
                OLD_RAW_TOTAL=$((OLD_RAW_TOTAL+rawc))
            fi
        else
            if [ "$exp" = "DEFECT_SIG" ] && [ "$c" -eq 9 ]; then OLD_CTRL9_BAD=$((OLD_CTRL9_BAD+1))
            elif [ "$exp" = "DEFECT_SIG" ]; then OLD_TRIG_BAD=$((OLD_TRIG_BAD+1))
            else OLD_CTL_BAD=$((OLD_CTL_BAD+1)); fi
        fi
    done
    check_vec_lines "old" "$SPEC_TOTAL"
    verify_sha_unchanged "old" || emit_fail "old_inputs_changed"
    [ "$OLD_TRIG_BAD" -eq 0 ] || emit_fail "old_trigger_not_reproduced_bad=$OLD_TRIG_BAD"
    [ "$OLD_TRIG_OK" -eq "$SPEC_TRIGGER" ] || emit_fail "old_trigger_ok=$OLD_TRIG_OK expect=$SPEC_TRIGGER"
    [ "$OLD_CTL_BAD" -eq 0 ] || emit_fail "old_control_bad=$OLD_CTL_BAD"
    [ "$OLD_CTL_OK" -eq 2 ] || emit_fail "old_control_ok=$OLD_CTL_OK expect=2"
    [ "$OLD_CTRL9_BAD" -eq 0 ] || emit_fail "old_case9_not_reproduced_bad=$OLD_CTRL9_BAD"
    [ "$OLD_CTRL9_OK" -eq 1 ] || emit_fail "old_case9_ok=$OLD_CTRL9_OK expect=1"
    [ "$OLD_RAW_TOTAL" -gt 0 ] || emit_fail "old_raw_total=0 (RAW 根因签名未观测到)"
    #   ★ 负模式整本日志的 DEFECT 白名单：只许预期 CASE/VEC 行与负矩阵字段；
    #     DEFECT_ARBITRARY/REPRODUCED/异号 DEFECT 一律拒。
    N_DEF_ANY="$(grep -c 'DEFECT' "$RUN_LOG" || true)"
    N_DEF_ALLOW="$(grep -cE '^(CASE [0-9]+ [a-z0-9_]+ KIND=(trigger|control) VERDICT=DEFECT_SIG nchk=[0-9]+|VEC old [0-9]+ [a-z0-9_]+ kind=(trigger|control) verdict=DEFECT_SIG nchk=[0-9]+ cov.*|ROB_WINDOW_NEGATIVE_MATRIX .*old_case9=DEFECT_SIG.*)$' "$RUN_LOG" || true)"
    [ "$N_DEF_ANY" -eq "$N_DEF_ALLOW" ] || emit_fail "neg_unexpected_DEFECT_lines any=$N_DEF_ANY allowed=$N_DEF_ALLOW"

    printf 'ROB_WINDOW_NEGATIVE_MATRIX old_trigger=%s/%s old_control=%s/%s old_case9=DEFECT_SIG old_raw=%s new_ok=%s/%s defect=e_ok_bad_removed\n' \
           "$OLD_TRIG_OK" "$SPEC_TRIGGER" "$OLD_CTL_OK" "2" "$OLD_RAW_TOTAL" "$OK_N" "$SPEC_TOTAL" \
           >> "$RUN_LOG"

    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
    N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
    [ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"

    N_SUM="$(grep -c '^ROB_WINDOW_NEGATIVE_MATRIX ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "neg_summary_count=$N_SUM"
    SUM_LINE="$(grep -m1 '^ROB_WINDOW_NEGATIVE_MATRIX ' "$RUN_LOG" || true)"
    if [[ "$SUM_LINE" =~ ^ROB_WINDOW_NEGATIVE_MATRIX\ old_trigger=([0-9]+)/([0-9]+)\ old_control=([0-9]+)/([0-9]+)\ old_case9=DEFECT_SIG\ old_raw=([0-9]+)\ new_ok=([0-9]+)/([0-9]+)\ defect=e_ok_bad_removed$ ]]; then
        { [ "${BASH_REMATCH[1]}" = "$SPEC_TRIGGER" ] && [ "${BASH_REMATCH[2]}" = "$SPEC_TRIGGER" ] \
          && [ "${BASH_REMATCH[3]}" = "2" ] && [ "${BASH_REMATCH[4]}" = "2" ] \
          && [ "${BASH_REMATCH[5]}" -gt 0 ] \
          && [ "${BASH_REMATCH[6]}" = "$SPEC_TOTAL" ] && [ "${BASH_REMATCH[7]}" = "$SPEC_TOTAL" ]; } \
          || emit_fail "neg_summary_fields_mismatch line=$SUM_LINE"
    else
        emit_fail "neg_summary_format"
    fi

    verify_tb_src_unchanged || emit_fail "source_tb_changed_during_run"
    verify_tb_frozen        || emit_fail "frozen_tb_changed_during_run"
    verify_pkg_unchanged    || emit_fail "pkg_changed_during_run"
    verify_env_unchanged    || emit_fail "env_changed_during_run"
    N_PASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "default_anchor_present_in_self_test=$N_PASS"
    printf 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS\n' >> "$RUN_LOG"
    N_NEGPASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' "$RUN_LOG" || true)"
    [ "$N_NEGPASS" = "1" ] || emit_fail "negative_anchor_count=$N_NEGPASS"

    printf 'ROB_WINDOW_NEGATIVE_MATRIX old_trigger=%s/%s old_control=%s/%s old_case9=DEFECT_SIG old_raw=%s new_ok=%s/%s defect=e_ok_bad_removed\n' \
           "$OLD_TRIG_OK" "$SPEC_TRIGGER" "$OLD_CTL_OK" "2" "$OLD_RAW_TOTAL" "$OK_N" "$SPEC_TOTAL"
    printf 'ROB_WINDOW_CANDIDATE removed_guard_mutation source=generated_from_fixed_rob\n'
    printf 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 8b. b227 旧候选模式（单独）：母冻结的 e_bad=flush-only 实现 + 同一新 TB
#     · 原 8 用例（0..7）必须全绿（保持原 8/7+1 不回归）；
#     · 新独立 goldcase8 必须红，且逐拍签名是 head_pc_valid stale / RAW age<2；
#     · 同族正控 case9 必须绿；b227 源只读、前后 sha 不变。
#------------------------------------------------------------------------------
if [ "$B227" -eq 1 ]; then
    verify_tb_frozen          || emit_fail "frozen_tb_changed_between_phases"
    verify_tb_src_unchanged   || emit_fail "source_tb_changed_between_phases"
    verify_pkg_unchanged      || emit_fail "pkg_changed_between_phases"
    verify_env_unchanged      || emit_fail "env_changed_between_phases"

    #   默认根 = 当前 DUT_ROOT 下的正式 fixture；显式 env 仍允许（身份必须一致）。
    if [ -z "${RV32_ROBWIN_B227_ROOT:-}" ]; then
        B227_ROOT="$DUT_ROOT/sim/functional/fixtures/rob_window_b227"
    fi
    [ -d "$B227_ROOT" ] || emit_fail "b227_root_missing path=$B227_ROOT"
    if ! B227_REASON="$(b227_identity_check "$B227_ROOT")"; then
        emit_fail "invalid_b227_identity reason=${B227_REASON:-unknown} root=$B227_ROOT"
    fi
    B227_SHA0="$(sha1_checked "$B227_ROOT/rtl/back2/rob.v")" || emit_fail "b227_sha_unavailable"
    B227_WIDE0="$(sha1_checked "$B227_ROOT/rtl/back2/rob_wide_mem.v")" || emit_fail "b227_wide_sha_unavailable"
    B227_PARAM0="$(sha1_checked "$B227_ROOT/rtl/back2/back2_params.vh")" || emit_fail "b227_params_sha_unavailable"
    [ "$B227_SHA0" = "$B227_ROB_SHA" ] || emit_fail "b227_sha_mismatch got=$B227_SHA0 exp=$B227_ROB_SHA"
    [ "$B227_WIDE0" = "$B227_WIDE_SHA" ] || emit_fail "b227_wide_sha_mismatch got=$B227_WIDE0 exp=$B227_WIDE_SHA"
    [ "$B227_PARAM0" = "$B227_PARAMS_SHA" ] || emit_fail "b227_params_sha_mismatch got=$B227_PARAM0 exp=$B227_PARAMS_SHA"
    echo "B227_ROOT       = $B227_ROOT" >> "$RUN_LOG"
    echo "B227_ROB_SHA    = $B227_SHA0" >> "$RUN_LOG"
    echo "B227_WIDE_SHA   = $B227_WIDE0" >> "$RUN_LOG"
    echo "B227_PARAMS_SHA = $B227_PARAM0" >> "$RUN_LOG"
    printf 'ROB_WINDOW_CANDIDATE b227_original_fixture root=%s\n' "$B227_ROOT" >> "$RUN_LOG"

    SNAP_B="$RUN_DIR/src-b227"
    snapshot_root "$B227_ROOT" "$SNAP_B" || emit_fail "snapshot_b227_failed root=$B227_ROOT"
    echo "SNAP_B227       = $SNAP_B" >> "$RUN_LOG"
    B227_VVP="$RUN_DIR/tb_rob_window_semantics_b227.vvp"
    compile_root "$SNAP_B" "$B227_VVP" "b227" || emit_fail "compile_b227_failed"

    B227_OTHER_OK=0; B227_OTHER_BAD=0; B227_TRIG_OK=0; B227_TRIG_BAD=0; B227_RAW=0
    for c in $(seq 0 $((SPEC_TOTAL-1))); do
        exp="OK"
        [ "$c" -eq 8 ] && exp="DEFECT_SIG"
        need_raw=1
        [ "$c" -eq 8 ] && need_raw=0
        if run_one "$B227_VVP" "$c" "$exp" "b227" "$need_raw"; then
            if [ "$c" -eq 8 ]; then B227_TRIG_OK=$((B227_TRIG_OK+1)); else B227_OTHER_OK=$((B227_OTHER_OK+1)); fi
        else
            if [ "$c" -eq 8 ]; then B227_TRIG_BAD=$((B227_TRIG_BAD+1)); else B227_OTHER_BAD=$((B227_OTHER_BAD+1)); fi
        fi
    done
    check_vec_lines "b227" "$SPEC_TOTAL"
    verify_sha_unchanged "b227" || emit_fail "b227_inputs_changed"

    B227_SHA1="$(sha1_checked "$B227_ROOT/rtl/back2/rob.v")" || emit_fail "b227_sha_recheck_unavailable"
    [ "$B227_SHA1" = "$B227_SHA0" ] || emit_fail "b227_source_changed_during_run"
    if ! B227_REASON="$(b227_identity_check "$B227_ROOT")"; then
        emit_fail "b227_identity_changed_during_run reason=${B227_REASON:-unknown} root=$B227_ROOT"
    fi

    [ "$B227_TRIG_BAD" -eq 0 ] || emit_fail "b227_new_case_not_reproduced_bad=$B227_TRIG_BAD"
    [ "$B227_TRIG_OK" -eq 1 ] || emit_fail "b227_new_case_ok=$B227_TRIG_OK expect=1"
    [ "$B227_OTHER_BAD" -eq 0 ] || emit_fail "b227_other_case_bad=$B227_OTHER_BAD"
    [ "$B227_OTHER_OK" -eq $((SPEC_TOTAL-1)) ] || emit_fail "b227_other_ok=$B227_OTHER_OK expect=$((SPEC_TOTAL-1))"
    #   新 case8 的逐拍根因签名 + RAW 计数
    grep -qE 'MISMATCH .*head_pc_valid=1 but PC stale' "$RUN_DIR/b227_case_8.log"         || emit_fail "b227_case8_no_safevalid_stale_signature"
    grep -qE 'MISMATCH .*RAW win .*age=[01] \(<2\)' "$RUN_DIR/b227_case_8.log"         || emit_fail "b227_case8_no_raw_signature"
    B227_RAW="$(sed -nE 's/^ROB_WINDOW_COV case=8 .* raw=([0-9]+)$/\1/p' "$RUN_DIR/b227_case_8.log")"
    [ -n "$B227_RAW" ] && [ "$B227_RAW" -gt 0 ] || emit_fail "b227_case8_raw=0"

    printf 'ROB_WINDOW_B227_MATRIX old_ok=%s/%s old_case8=DEFECT_SIG control_ok=2/2 new_ok=%s/%s root=b227\n'            "$B227_OTHER_OK" "$((SPEC_TOTAL-1))" "$OK_N" "$SPEC_TOTAL" >> "$RUN_LOG"
    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
    N_SUM="$(grep -c '^ROB_WINDOW_B227_MATRIX ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "b227_summary_count=$N_SUM"
    SUM_LINE="$(grep -m1 '^ROB_WINDOW_B227_MATRIX ' "$RUN_LOG" || true)"
    printf '%s\n' "$SUM_LINE" | grep -qE '^ROB_WINDOW_B227_MATRIX old_ok=10/10 old_case8=DEFECT_SIG control_ok=2/2 new_ok=11/11 root=b227$'         || emit_fail "b227_summary_format line=$SUM_LINE"

    verify_tb_src_unchanged || emit_fail "source_tb_changed_during_run"
    verify_tb_frozen        || emit_fail "frozen_tb_changed_during_run"
    verify_pkg_unchanged    || emit_fail "pkg_changed_during_run"
    verify_env_unchanged    || emit_fail "env_changed_during_run"
    N_PASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "default_anchor_present_in_b227=$N_PASS"
    N_NEG="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' "$RUN_LOG" || true)"
    [ "$N_NEG" = "0" ] || emit_fail "negative_anchor_present_in_b227=$N_NEG"
    printf 'FUNCTIONAL_ROB_WINDOW_B227: PASS\n' >> "$RUN_LOG"
    N_BPASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227: PASS' "$RUN_LOG" || true)"
    [ "$N_BPASS" = "1" ] || emit_fail "b227_anchor_count=$N_BPASS"

    printf 'ROB_WINDOW_B227_MATRIX old_ok=%s/%s old_case8=DEFECT_SIG control_ok=2/2 new_ok=%s/%s root=b227\n'            "$B227_OTHER_OK" "$((SPEC_TOTAL-1))" "$OK_N" "$SPEC_TOTAL"
    printf 'ROB_WINDOW_CANDIDATE b227_original_fixture root=%s\n' "$B227_ROOT"
    printf 'FUNCTIONAL_ROB_WINDOW_B227: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 8b2. 正式 fixture 身份/可移交性自检（--b227-selftest）：
#   · 默认根必须是 in-tree sim/functional/fixtures/rob_window_b227（不得 fallback 母 r0）；
#   · 三依赖逐字 SHA 必须钉死；missing / rob 变异 / wide 变异 / header 变异必须拒；
#   · 不依赖本机 build/functional/rob-review-r0-w1oii3zz。
#------------------------------------------------------------------------------
if [ "$B227SELFTEST" -eq 1 ]; then
    verify_tb_frozen          || emit_fail "frozen_tb_changed_between_phases"
    verify_tb_src_unchanged   || emit_fail "source_tb_changed_between_phases"
    verify_pkg_unchanged      || emit_fail "pkg_changed_between_phases"
    verify_env_unchanged      || emit_fail "env_changed_between_phases"

    if [ -n "${RV32_ROBWIN_B227_ROOT:-}" ]; then
        emit_fail "b227_selftest_env_override_set value=$RV32_ROBWIN_B227_ROOT"
    fi
    DEF_B227="$DUT_ROOT/sim/functional/fixtures/rob_window_b227"
    B227_ROOT="$DEF_B227"
    case "$DEF_B227" in
        *"/build/functional/rob-review"*) emit_fail "b227_selftest_default_points_to_mother_dir root=$DEF_B227" ;;
    esac
    if ! B227_REASON="$(b227_identity_check "$DEF_B227")"; then
        emit_fail "b227_selftest_default_identity reason=${B227_REASON:-unknown} root=$DEF_B227"
    fi
    echo "B227_DEFAULT_ROOT = $DEF_B227" >> "$RUN_LOG"

    B227_ID_OK=0
    check_b227_expect() {  # $1=label $2=root $3=want(0/1) $4=needle
        local label="$1" root="$2" want="$3" needle="$4" reason rc=0
        reason="$(b227_identity_check "$root")" || rc=$?
        if [ "$want" -eq 0 ]; then
            [ "$rc" -eq 0 ] || { echo "[b227-selftest] $label expected OK rc=$rc reason=$reason" >> "$RUN_LOG"; return 1; }
        else
            [ "$rc" -ne 0 ] && printf '%s' "$reason" | grep -qF "$needle"                 || { echo "[b227-selftest] $label expected REJECT needle=$needle rc=$rc reason=$reason" >> "$RUN_LOG"; return 1; }
        fi
        B227_ID_OK=$((B227_ID_OK+1))
        echo "[b227-selftest] $label want=$want needle=${needle:-ok}" >> "$RUN_LOG"
        return 0
    }

    #   合法默认根
    check_b227_expect default_in_tree "$DEF_B227" 0 "" || emit_fail "b227_selftest_default"
    #   missing
    check_b227_expect missing_root "$RUN_DIR/b227-no-such-root" 1 'b227_identity_missing:rtl/back2/rob.v'         || emit_fail "b227_selftest_missing"
    #   逐文件变异（rob / wide / header）
    for mut in rob wide header; do
        MD="$RUN_DIR/b227-mut-$mut"
        mkdir -p -- "$MD/rtl/back2" || emit_fail "b227_selftest_mkdir_failed mut=$mut"
        cp -- "$DEF_B227/rtl/back2/rob.v" "$MD/rtl/back2/rob.v" || emit_fail "b227_selftest_copy_failed"
        cp -- "$DEF_B227/rtl/back2/rob_wide_mem.v" "$MD/rtl/back2/rob_wide_mem.v" || emit_fail "b227_selftest_copy_failed"
        cp -- "$DEF_B227/rtl/back2/back2_params.vh" "$MD/rtl/back2/back2_params.vh" || emit_fail "b227_selftest_copy_failed"
        chmod u+w -- "$MD/rtl/back2/rob.v" "$MD/rtl/back2/rob_wide_mem.v" "$MD/rtl/back2/back2_params.vh" \
            || emit_fail "b227_selftest_chmod_failed"
        case "$mut" in
            rob)    printf '\n// b227 mutation\n' >> "$MD/rtl/back2/rob.v" ;;
            wide)   printf '\n// b227 mutation\n' >> "$MD/rtl/back2/rob_wide_mem.v" ;;
            header) printf '\n// b227 mutation\n' >> "$MD/rtl/back2/back2_params.vh" ;;
        esac
        rel="rtl/back2/rob.v"
        [ "$mut" = "wide" ] && rel="rtl/back2/rob_wide_mem.v"
        [ "$mut" = "header" ] && rel="rtl/back2/back2_params.vh"
        check_b227_expect "${mut}_mutation" "$MD" 1 "b227_identity_mismatch:$rel"             || emit_fail "b227_selftest_mutation mut=$mut"
    done
    [ "$B227_ID_OK" -eq 5 ] || emit_fail "b227_selftest_id_count=$B227_ID_OK expect=5"

    printf 'ROB_WINDOW_B227_ID_MATRIX identity=ok missing=red rob_mut=red wide_mut=red header_mut=red default_root=in_tree\n' >> "$RUN_LOG"
    N_SUM="$(grep -c '^ROB_WINDOW_B227_ID_MATRIX ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "b227_selftest_summary_count=$N_SUM"
    SUM_LINE="$(grep -m1 '^ROB_WINDOW_B227_ID_MATRIX ' "$RUN_LOG" || true)"
    [ "$SUM_LINE" = 'ROB_WINDOW_B227_ID_MATRIX identity=ok missing=red rob_mut=red wide_mut=red header_mut=red default_root=in_tree' ] \
        || emit_fail "b227_selftest_summary_format line=$SUM_LINE"
    N_PASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "b227_selftest_default_anchor=$N_PASS"
    N_NEG="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' "$RUN_LOG" || true)"
    [ "$N_NEG" = "0" ] || emit_fail "b227_selftest_neg_anchor=$N_NEG"
    N_B="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227: PASS' "$RUN_LOG" || true)"
    [ "$N_B" = "0" ] || emit_fail "b227_selftest_b227_anchor=$N_B"
    printf 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS\n' >> "$RUN_LOG"
    N_S="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS' "$RUN_LOG" || true)"
    [ "$N_S" = "1" ] || emit_fail "b227_selftest_anchor_count=$N_S"

    printf 'ROB_WINDOW_B227_ID_MATRIX identity=ok missing=red rob_mut=red wide_mut=red header_mut=red default_root=in_tree\n'
    printf 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 8c. hpv 变异模式（单独）：safe-head 正活性杀 stuck0 / &done
#   同一冻结 TB + 固定树 rob.v 现场替换唯一 `assign head_pc_valid_o`；
#   case10 必须红（逐拍 hpv=0 while head live and not done），固定树 case10 必须绿。
#------------------------------------------------------------------------------
if [ "$MUTHPV" -eq 1 ]; then
    verify_tb_frozen          || emit_fail "frozen_tb_changed_between_phases"
    verify_tb_src_unchanged   || emit_fail "source_tb_changed_between_phases"
    verify_pkg_unchanged      || emit_fail "pkg_changed_between_phases"
    verify_env_unchanged      || emit_fail "env_changed_between_phases"

    #   固定树 case10 绿（正活性正控）
    run_one "$VVP_OUT" 10 "OK" "hpvfix" 1 || emit_fail "hpv_fixed_case10_not_ok"

    MUT_OK=0
    for mut in stuck0 done; do
        SNAP_M="$RUN_DIR/src-hpv-$mut"
        mkdir -p -- "$SNAP_M/rtl/back2" || emit_fail "hpv_snap_mkdir_failed mut=$mut"
        for rel in "${DEP_FILES[@]}"; do
            mkdir -p -- "$SNAP_M/$(dirname -- "$rel")" || emit_fail "hpv_snap_mkdir_failed rel=$rel"
            cp -p -- "$SNAP_NEW/$rel" "$SNAP_M/$rel" || emit_fail "hpv_snap_copy_failed rel=$rel"
        done
        for rel in "${REQ_HEADERS[@]}"; do
            mkdir -p -- "$SNAP_M/$(dirname -- "$rel")" || emit_fail "hpv_snap_mkdir_failed rel=$rel"
            cp -p -- "$SNAP_NEW/$rel" "$SNAP_M/$rel" || emit_fail "hpv_snap_copy_failed rel=$rel"
        done
        cp -p -- "$FREEZE_TB" "$SNAP_M/tb-frozen.sv" || emit_fail "hpv_snap_tb_copy_failed"
        if [ "$mut" = "stuck0" ]; then
            sed 's/.*assign head_pc_valid_o.*/    assign head_pc_valid_o = 1'"'"'b0;/'                 -- "$SNAP_NEW/rtl/back2/rob.v" > "$SNAP_M/rtl/back2/rob.v" \
                || emit_fail "hpv_mut_stuck0_sed_failed"
            grep -qF "assign head_pc_valid_o = 1'b0;" "$SNAP_M/rtl/back2/rob.v" \
                || emit_fail "hpv_mut_stuck0_missing"
        else
            sed 's/.*assign head_pc_valid_o.*/    assign head_pc_valid_o = (cnt_q != {(ROB_IDX_W+1){1'"'"'b0}}) \& win_lane_ok[0] \& head_done_o;/'                 -- "$SNAP_NEW/rtl/back2/rob.v" > "$SNAP_M/rtl/back2/rob.v" \
                || emit_fail "hpv_mut_done_sed_failed"
            grep -qF 'head_done_o;' "$SNAP_M/rtl/back2/rob.v" \
                || emit_fail "hpv_mut_done_missing"
        fi
        #   固定树原行不得残留（替换必须精确命中唯一 assign）
        if grep -qF 'assign head_pc_valid_o = (cnt_q != {(ROB_IDX_W+1){1'"'"'b0}}) & win_lane_ok[0];' "$SNAP_M/rtl/back2/rob.v"; then
            emit_fail "hpv_mut_old_line_remains mut=$mut"
        fi
        MV="$RUN_DIR/tb_hpv_$mut.vvp"
        compile_root "$SNAP_M" "$MV" "hpv-$mut" || emit_fail "hpv_compile_failed mut=$mut"
        run_one "$MV" 10 "DEFECT_SIG" "hpv_$mut" 0 || emit_fail "hpv_mut_not_red mut=$mut"
        grep -qE 'MISMATCH case=10 .*hpv=0 while head live and not done' "$RUN_DIR/hpv_${mut}_case_10.log" \
            || emit_fail "hpv_mut_no_liveness_signature mut=$mut"
        MUT_OK=$((MUT_OK+1))
    done
    [ "$MUT_OK" -eq 2 ] || emit_fail "hpv_mut_ok=$MUT_OK expect=2"

    N_DEF_ANY="$(grep -c 'DEFECT' "$RUN_LOG" || true)"
    N_DEF_ALLOW="$(grep -cE '^(CASE 10 hpv_live_nondone KIND=control VERDICT=DEFECT_SIG nchk=[0-9]+|VEC hpv_(stuck0|done) 10 hpv_live_nondone kind=control verdict=DEFECT_SIG nchk=[0-9]+ cov.*)$' "$RUN_LOG" || true)"
    [ "$N_DEF_ANY" -eq "$N_DEF_ALLOW" ] || emit_fail "hpv_unexpected_DEFECT_lines any=$N_DEF_ANY allowed=$N_DEF_ALLOW"
    printf 'ROB_WINDOW_HPV_MATRIX fixed_ok=1/1 stuck0=DEFECT_SIG done=DEFECT_SIG\n' >> "$RUN_LOG"
    N_SUM="$(grep -c '^ROB_WINDOW_HPV_MATRIX ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "hpv_summary_count=$N_SUM"
    SUM_LINE="$(grep -m1 '^ROB_WINDOW_HPV_MATRIX ' "$RUN_LOG" || true)"
    [ "$SUM_LINE" = 'ROB_WINDOW_HPV_MATRIX fixed_ok=1/1 stuck0=DEFECT_SIG done=DEFECT_SIG' ] \
        || emit_fail "hpv_summary_format line=$SUM_LINE"
    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"

    verify_tb_src_unchanged || emit_fail "source_tb_changed_during_run"
    verify_tb_frozen        || emit_fail "frozen_tb_changed_during_run"
    verify_pkg_unchanged    || emit_fail "pkg_changed_during_run"
    verify_env_unchanged    || emit_fail "env_changed_during_run"
    N_PASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "default_anchor_present_in_hpv=$N_PASS"
    N_NEG="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' "$RUN_LOG" || true)"
    [ "$N_NEG" = "0" ] || emit_fail "negative_anchor_present_in_hpv=$N_NEG"
    N_B="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227: PASS' "$RUN_LOG" || true)"
    [ "$N_B" = "0" ] || emit_fail "b227_anchor_present_in_hpv=$N_B"
    printf 'FUNCTIONAL_ROB_WINDOW_HPV: PASS\n' >> "$RUN_LOG"
    N_HP="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_HPV: PASS' "$RUN_LOG" || true)"
    [ "$N_HP" = "1" ] || emit_fail "hpv_anchor_count=$N_HP"

    printf 'ROB_WINDOW_HPV_MATRIX fixed_ok=1/1 stuck0=DEFECT_SIG done=DEFECT_SIG\n'
    printf 'FUNCTIONAL_ROB_WINDOW_HPV: PASS\n'
    exit 0
fi

#   ★ 收尾：源 TB / 包脚本 / env 在整个运行期间不得变化
verify_tb_src_unchanged || emit_fail "source_tb_changed_during_run"
verify_pkg_unchanged    || emit_fail "pkg_changed_during_run"
verify_env_unchanged    || emit_fail "env_changed_during_run"

#------------------------------------------------------------------------------
# 9. 默认模式：摘要 + 唯一锚点（先计数前缀，再严格格式）
#------------------------------------------------------------------------------
printf 'ROB_WINDOW_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
       "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" "$BAD_N" >> "$RUN_LOG"
printf 'FUNCTIONAL_ROB_WINDOW: PASS\n' >> "$RUN_LOG"

N_SUM="$(grep -c '^ROB_WINDOW_VECTORS ' "$RUN_LOG" || true)"
[ "$N_SUM" = "1" ] || emit_fail "summary_count=$N_SUM"
SUM_LINE="$(grep -m1 '^ROB_WINDOW_VECTORS ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^ROB_WINDOW_VECTORS\ total=([0-9]+)\ trigger=([0-9]+)\ control=([0-9]+)\ ok=([0-9]+)\ bad=([0-9]+)$ ]]; then
    { [ "${BASH_REMATCH[1]}" = "$SPEC_TOTAL" ] && [ "${BASH_REMATCH[2]}" = "$SPEC_TRIGGER" ] \
      && [ "${BASH_REMATCH[3]}" = "$SPEC_CONTROL" ] && [ "${BASH_REMATCH[4]}" = "$SPEC_TOTAL" ] \
      && [ "${BASH_REMATCH[5]}" = "0" ]; } || emit_fail "summary_fields_mismatch line=$SUM_LINE"
else
    emit_fail "summary_format"
fi

N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
[ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
[ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"
N_DEFSIG="$(grep -c 'DEFECT_SIG' "$RUN_LOG" || true)"
[ "$N_DEFSIG" = "0" ] || emit_fail "log_has_DEFECT_SIG=$N_DEFSIG"
N_DEFANY="$(grep -c 'DEFECT' "$RUN_LOG" || true)"
[ "$N_DEFANY" = "0" ] || emit_fail "log_has_any_DEFECT=$N_DEFANY"
N_MIS="$(grep -c 'MISMATCH' "$RUN_LOG" || true)"
[ "$N_MIS" = "0" ] || emit_fail "log_has_MISMATCH=$N_MIS"
N_PASS="$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$RUN_LOG" || true)"
[ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"

printf 'ROB_WINDOW_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
       "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" "$BAD_N"
printf 'FUNCTIONAL_ROB_WINDOW: PASS\n'
exit 0
