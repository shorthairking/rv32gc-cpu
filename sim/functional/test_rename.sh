#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_rename.sh —— F2 重命名包功能定向测试入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2B-5）
# 依据 : prompts/common.md §3（判定 fail-closed：确定性脚本 + 退出码 + 日志锚点）、
#        sim/functional/manifest.tsv（本包锚点 = 唯一整行 `FUNCTIONAL_RENAME: PASS`）、
#        sim/audit/global-2026-10-18/02-backend.md 条目 02-2 / 02-3。
#
# 做什么 :
#   1) 只复制本包**实际依赖闭包**（rtl/back2/rename.v + rtl/**/*.vh + TB）到本次 run
#      目录的不可变快照里，逐文件记 sha256；编译输入**只来自快照**，绝不依赖工作树
#      抖动，也不递归复制整个 repo/build；
#   2) iverilog 编译快照（`-s tb_rename_semantics`），逐向量跑 `+CASE=<n>`；
#   3) 默认 DUT_ROOT = 本仓库根 ⇒ 要求 16/16 向量 `VERDICT=OK`。
#
# 反证（单独模式，绝不与默认成功混在同一判定里；**不依赖任何预先存在的 build 夹具**）:
#   `bash sim/functional/test_rename.sh --self-test`（或 `--negative` / RV32_RENAME_MODE=defect）
#     · 用 `git -C <repo> archive 201acf61…` **现场生成**旧源码只读快照；
#     · 对旧快照跑**同一 TB**：7 个触发向量全部 `DEFECT_SIG`（02-2/02-3 缺陷复现），
#       9 个控制向量全部 `OK`（旧代码在合法序列上也正确）；
#     · 再对当前树（新源码）跑同一 TB：16/16 `OK`；
#     · 通过时只打印 `FUNCTIONAL_RENAME_NEGATIVE: PASS`，**绝不**打印默认锚点。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR（总入口传入）> OUT_DIR（显式指定）
#              > $REPO_ROOT/build/functional/rename（默认）
#   · 根先 readlink -m 规范化，再校验位于 $REPO_ROOT/build/functional 之下，然后 mkdir；
#     随后 `mktemp -d <根>/run-XXXXXXXX` 建本次独占 run 目录，全部产物都在其中 ⇒ 不 rm。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP；二者仍可被同名环境变量
#            覆盖 ⇒ 保留"假工具"反证能力。墙钟兜底 TIMEOUT_COMPILE_S / TIMEOUT_RUN_S
#            （默认 600 / 120 s）。
#
# 判定（全部满足才算 PASS，否则 exit 1 且不打印 PASS 锚点）:
#   · 参数：零参 / `--self-test` / `--negative`；未知参数即失败
#   · 工具：env.sh 可读且 source rc=0；RV32_IVERILOG/RV32_VVP 非空可执行
#   · 依赖：闭包文件齐全；sha256 **行数与 64-hex 行格式**严格校验（不得 `|| true` 吞错）
#   · 编译：rc=0 且 `-s tb_rename_semantics` 产出**非空** vvp（零产物/超时 ⇒ 失败）
#   · 逐向量：0..15 每例恰好一条严格格式 `CASE <n> <name> KIND=<k> VERDICT=<v> nchk=<N>`；
#             `KIND` 必须与脚本冻结分类一致；`nchk` 必须 ≥ MIN_NCHK（防少跑/空跑）
#   · 默认：16/16 `OK`；日志零 `DEFECT_SIG` / 零 `DEFECT_REPRODUCED` / 零 `FAIL`
#   · 反证：旧树 7 触发全 `DEFECT_SIG` 且 9 控制全 `OK`；新树 16/16 `OK`
#   · 哈希：编译输入 sha256 在**运行前后完全一致**（防中途被改）
#   · 摘要：先统计 `^RENAME_VECTORS ` / `^RENAME_NEGATIVE_MATRIX ` 前缀行，再严格匹配字段
#   · 锚点：默认 `FUNCTIONAL_RENAME: PASS` 恰好 1 行；反证模式为 0 行且反向锚点恰好 1 行
#
# 用法 : bash sim/functional/test_rename.sh
#        bash sim/functional/test_rename.sh --self-test
#        DUT_ROOT=<只读源根> bash sim/functional/test_rename.sh
#        OUT_DIR=<产物根>    bash sim/functional/test_rename.sh
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数 / 模式
#------------------------------------------------------------------------------
NEG=0
if [ "$#" -gt 1 ]; then
    printf 'FUNCTIONAL_RENAME: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test|--negative) NEG=1 ;;
        *) printf 'FUNCTIONAL_RENAME: FAIL reason=unknown_arg argv=%s\n' "$1"; exit 1 ;;
    esac
fi
case "${RV32_RENAME_MODE:-spec}" in
    spec)   ;;
    defect) NEG=1 ;;
    *) printf 'FUNCTIONAL_RENAME: FAIL reason=bad_mode value=%s\n' "${RV32_RENAME_MODE}"; exit 1 ;;
esac

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-600}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-120}"

#------------------------------------------------------------------------------
# 1. 路径解析（按脚本自身位置推导，不依赖调用者 cwd）
#------------------------------------------------------------------------------
SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_RENAME: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_RENAME: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_rename_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

# ---- 本包冻结规格（与 tb_rename_semantics.sv 的 CASE 表 / is_trigger() 同步）----
SPEC_TOTAL=20
SPEC_TRIGGER=10
SPEC_CONTROL=10
# 8/9=02-2；10/11/12/13/15=02-3；16/17/18=审阅 P1（死组重入抢仍活旧组影子）
TRIGGER_CASES="8 9 10 11 12 13 15 16 17 18"
# 逐向量检查数下限（防少跑/空跑冒充：TB 若把某向量压成空转，nchk 会低于此表）
min_nchk_for() {
    case "$1" in
        0) echo 20;; 1) echo 15;; 2) echo 30;; 3) echo 15;; 4) echo 15;;
        5) echo 50;; 6) echo 50;; 7) echo 15;; 8) echo 15;; 9) echo 15;;
        10) echo 50;; 11) echo 60;; 12) echo 50;; 13) echo 20;; 14) echo 80;; 15) echo 90;;
        16) echo 50;; 17) echo 60;; 18) echo 50;; 19) echo 20;;
        *) echo 20;;
    esac
}
OLD_COMMIT="201acf61e118a3fb533e1a96768687a35efa1751"

# 本包只直接编译 rename 及其必要头（不依赖 backend_top / 其他正在变化的域）
DEP_FILES=( rtl/back2/rename.v )

#------------------------------------------------------------------------------
# 2. 判定状态与输出助手（stdout 只放摘要 + 唯一锚点；细节进 run 目录日志）
#------------------------------------------------------------------------------
RUN_DIR=""
SUM_OK="-"; SUM_BAD="-"

emit_fail() {
    if [ "$NEG" -eq 1 ]; then
        printf 'FUNCTIONAL_RENAME_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    else
        printf 'RENAME_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
               "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$SUM_OK" "$SUM_BAD"
        printf 'FUNCTIONAL_RENAME: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

#------------------------------------------------------------------------------
# 3. 产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run 目录（绝不 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/rename}}"

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
RUN_LOG="$RUN_DIR/test_rename.log"
VVP_OUT="$RUN_DIR/tb_rename_semantics.vvp"
printf 'RENAME_RUN_DIR=%s\n' "$RUN_DIR"

: > "$RUN_LOG" || emit_fail "run_log_create_failed"

{
    echo "==== test_rename.sh : F2 rename semantics (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "MODE            = $([ "$NEG" -eq 1 ] && echo self-test || echo spec)"
    echo "SELF_DIR        = $SELF_DIR"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "AUTH_ROOT       = $AUTH_ROOT"
    echo "TB_SRC          = $TB_SRC"
    echo "SPEC            = total=$SPEC_TOTAL trigger=$SPEC_TRIGGER control=$SPEC_CONTROL min_nchk=per_case"
    echo "OLD_COMMIT      = $OLD_COMMIT"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "=========================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

#------------------------------------------------------------------------------
# 4. 工具真源：scripts/env.sh（只读）；工具缺失/不可执行即失败
#------------------------------------------------------------------------------
[ -r "$ENV_SH" ] || emit_fail "env_sh_unreadable path=$ENV_SH"
# shellcheck disable=SC1090
. "$ENV_SH" >> "$RUN_LOG" 2>&1
ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"

IV="${RV32_IVERILOG:-}"
VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing name=RV32_IVERILOG value=${IV:-unset}"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing name=RV32_VVP value=${VV:-unset}"
command -v timeout   >/dev/null 2>&1 || emit_fail "tool_missing name=timeout"
command -v sha256sum >/dev/null 2>&1 || emit_fail "tool_missing name=sha256sum"
echo "RV32_IVERILOG   = $IV" >> "$RUN_LOG"
echo "RV32_VVP        = $VV" >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 5a. 不可变输入快照：只复制本包实际依赖闭包（rename + rtl/**/*.vh + TB）
#     $1 = 源根（DUT_ROOT / 旧快照）   $2 = 快照目录
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
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        mkdir -p -- "$snap/$(dirname -- "$f")" || return 1
        cp -p -- "$root/$f" "$snap/$f" || return 1
    done < <( cd -- "$root" && find rtl -name '*.vh' 2>/dev/null | LC_ALL=C sort )
    [ -f "$TB_SRC" ] || { echo "snapshot: TB missing $TB_SRC" >> "$RUN_LOG"; return 1; }
    cp -p -- "$TB_SRC" "$snap/tb_rename_semantics.sv" || return 1
    return 0
}

#------------------------------------------------------------------------------
# 5b. 编译**快照**；记录**实际所有编译源**的 sha256（行数+格式严格校验）
#     $1 = 快照根   $2 = 输出 vvp   $3 = 阶段标签   $4 = 快照内 TB 路径
#     同时把 sha256 清单写到 <标签>.sha，供运行结束后"前后一致"复核。
#------------------------------------------------------------------------------
compile_root() {
    local root="$1" vvp="$2" tag="$3" tb="$4" f rc n sha_out n_lines n_ok sha_rc n_expect
    [ -d "$root" ] || { echo "[$tag] source root missing: $root" >> "$RUN_LOG"; return 1; }
    local files=() missing=0
    for f in "${DEP_FILES[@]}"; do
        if [ -f "$root/$f" ]; then files+=( "$root/$f" ); else
            echo "[$tag] MISSING dependency: $root/$f" >> "$RUN_LOG"; missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1
    local hdrs=()
    while IFS= read -r f; do
        [ -n "$f" ] && hdrs+=( "$root/$f" )
    done < <( cd -- "$root" && find rtl -name '*.vh' 2>/dev/null | LC_ALL=C sort )
    n_expect=$(( ${#files[@]} + ${#hdrs[@]} + 1 ))

    # ---- SHA：**不得**用 `|| true` 吞失败；行数与 64-hex 行格式必须严格 ----
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

    timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 -I "$root/rtl/pkg" -I "$root" \
            -s tb_rename_semantics -o "$vvp" "$tb" "${files[@]}" \
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

# 运行结束后复核编译输入未被改动（sha256 前后逐字节一致）
#   $1 = 标签
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
# 6. 跑单向量并判定（严格格式 + 冻结 KIND 校验 + nchk 下限）
#    $1 = vvp   $2 = case   $3 = 期望 verdict   $4 = 阶段标签
#------------------------------------------------------------------------------
run_one() {
    local vvp="$1" case="$2" expect="$3" tag="$4" log rc sz n_line kind verdict exp_kind
    log="$RUN_DIR/${tag}_case_${case}.log"
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

    #   ★ TB 必须恰好输出一行严格格式的 CASE 行（多/少/坏格式均拒）
    n_line="$(grep -cE "^CASE ${case} [A-Za-z0-9_]+ KIND=(trigger|control) VERDICT=(OK|DEFECT_SIG)( reason=timeout)? nchk=[0-9]+$" "$log" || true)"
    if [ "$n_line" -ne 1 ]; then
        echo "[$tag] case $case strict CASE line count=$n_line (expect 1)" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true
        return 1
    fi
    kind="$(sed -nE "s/^CASE ${case} [A-Za-z0-9_]+ KIND=([a-z]+) .*/\1/p" "$log")"
    verdict="$(sed -nE "s/^CASE ${case} [A-Za-z0-9_]+ KIND=[a-z]+ VERDICT=([A-Z_]+).*/\1/p" "$log")"
    # nchk 下限：防"少跑/空跑"被当成功
    if ! grep -qE "^CASE ${case} [A-Za-z0-9_]+ KIND=(trigger|control) VERDICT=(OK|DEFECT_SIG)( reason=timeout)? nchk=([0-9]+)$" "$log"; then
        # 允许 timeout 行（无 nchk）但只作为 DEFECT_SIG
        if ! grep -qE "^CASE ${case} [A-Za-z0-9_]+ KIND=(trigger|control) VERDICT=DEFECT_SIG reason=timeout$" "$log"; then
            echo "[$tag] case $case no parseable nchk" >> "$RUN_LOG"; return 1
        fi
    else
        local nchk
        local minn
        minn="$(min_nchk_for "$case")"
        nchk="$(sed -nE "s/^CASE ${case} [A-Za-z0-9_]+ KIND=[a-z]+ VERDICT=[A-Z_]+( reason=timeout)? nchk=([0-9]+)$/\2/p" "$log")"
        if [ -z "$nchk" ] || [ "$nchk" -lt "$minn" ]; then
            echo "[$tag] case $case nchk=$nchk < MIN_NCHK=$minn" >> "$RUN_LOG"; return 1
        fi
    fi
    exp_kind=control
    for c in $TRIGGER_CASES; do [ "$c" = "$case" ] && exp_kind=trigger; done
    if [ "$kind" != "$exp_kind" ]; then
        echo "[$tag] case $case KIND=$kind expect=$exp_kind (TB/script drift)" >> "$RUN_LOG"; return 1
    fi
    if [ "$verdict" != "$expect" ]; then
        echo "[$tag] case $case VERDICT=$verdict expect=$expect" >> "$RUN_LOG"
        cat -- "$log" >> "$RUN_LOG"
        return 1
    fi
    cat -- "$log" >> "$RUN_LOG"
    printf 'VEC %s %s kind=%s verdict=%s\n' "$tag" "$case" "$kind" "$verdict" >> "$RUN_LOG"
    return 0
}

# 严格校验某阶段的 VEC 行：数量 == 期望例数、格式规范、例号各出现且仅一次
check_vec_lines() {
    local tag="$1" expect="$2" n bad
    n="$(grep -cE "^VEC ${tag} [0-9]+ kind=(trigger|control) verdict=[A-Z_]+$" "$RUN_LOG" || true)"
    [ "$n" = "$expect" ] || emit_fail "vec_count_${tag}=$n expect=$expect"
    bad="$(awk -v t="$tag" '
        $1=="VEC" && $2==t {
            if ($0 !~ ("^VEC " t " [0-9]+ kind=(trigger|control) verdict=[A-Z_]+$")) b++;
            seen[$3]++;
        }
        END { for (k in seen) if (seen[k]!=1) b++; printf "%d", b+0 }
    ' "$RUN_LOG")"
    [ "$bad" = "0" ] || emit_fail "vec_format_or_dup_${tag}=$bad"
}

#------------------------------------------------------------------------------
# 7. 新源码（当前树 / DUT_ROOT）：16 向量全部 VERDICT=OK
#------------------------------------------------------------------------------
DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"
echo "DUT_ROOT        = $DUT_ROOT" >> "$RUN_LOG"

[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"
SNAP_NEW="$RUN_DIR/src-new"
snapshot_root "$DUT_ROOT" "$SNAP_NEW" || emit_fail "snapshot_new_failed root=$DUT_ROOT"
echo "SNAP_NEW        = $SNAP_NEW" >> "$RUN_LOG"
compile_root "$SNAP_NEW" "$VVP_OUT" "new" "$SNAP_NEW/tb_rename_semantics.sv" \
    || emit_fail "compile_new_failed"

OK_N=0; BAD_N=0
for c in $(seq 0 $((SPEC_TOTAL-1))); do
    if run_one "$VVP_OUT" "$c" "OK" "new"; then OK_N=$((OK_N+1)); else BAD_N=$((BAD_N+1)); fi
done
SUM_OK="$OK_N"; SUM_BAD="$BAD_N"
check_vec_lines "new" "$SPEC_TOTAL"
verify_sha_unchanged "new" || emit_fail "new_inputs_changed"
[ "$BAD_N" -eq 0 ] || emit_fail "new_source_bad_vectors=$BAD_N"
[ "$OK_N" -eq "$SPEC_TOTAL" ] || emit_fail "new_source_ok=$OK_N expect=$SPEC_TOTAL"

#------------------------------------------------------------------------------
# 8. 反证模式（单独）：201acf61 现场 Git 快照 → 触发例旧红/控制例旧正确；新源码已全绿
#------------------------------------------------------------------------------
if [ "$NEG" -eq 1 ]; then
    command -v git >/dev/null 2>&1 || emit_fail "tool_missing name=git (self-test mode)"
    command -v tar >/dev/null 2>&1 || emit_fail "tool_missing name=tar (self-test mode)"

    OLD_DIR="$RUN_DIR/old-$OLD_COMMIT"
    mkdir -p -- "$OLD_DIR" || emit_fail "old_snapshot_mkdir_failed"
    OLD_TAR="$RUN_DIR/old-$OLD_COMMIT.tar"
    git -C "$REPO_ROOT" archive "$OLD_COMMIT" > "$OLD_TAR" 2>> "$RUN_LOG" \
        || emit_fail "git_archive_failed commit=$OLD_COMMIT"
    tar -x -f "$OLD_TAR" -C "$OLD_DIR" >> "$RUN_LOG" 2>&1 \
        || emit_fail "old_snapshot_extract_failed"
    [ -f "$OLD_DIR/rtl/back2/rename.v" ] || emit_fail "old_snapshot_missing_rename"
    echo "OLD_DIR         = $OLD_DIR" >> "$RUN_LOG"

    OLD_VVP="$RUN_DIR/tb_rename_semantics_old.vvp"
    SNAP_OLD="$RUN_DIR/src-old"
    snapshot_root "$OLD_DIR" "$SNAP_OLD" || emit_fail "snapshot_old_failed root=$OLD_DIR"
    echo "SNAP_OLD        = $SNAP_OLD" >> "$RUN_LOG"
    compile_root "$SNAP_OLD" "$OLD_VVP" "old" "$SNAP_OLD/tb_rename_semantics.sv" \
        || emit_fail "compile_old_failed"

    OLD_TRIG_OK=0; OLD_TRIG_BAD=0; OLD_CTL_OK=0; OLD_CTL_BAD=0
    for c in $(seq 0 $((SPEC_TOTAL-1))); do
        exp="OK"
        for t in $TRIGGER_CASES; do [ "$t" = "$c" ] && exp="DEFECT_SIG"; done
        if run_one "$OLD_VVP" "$c" "$exp" "old"; then
            if [ "$exp" = "DEFECT_SIG" ]; then OLD_TRIG_OK=$((OLD_TRIG_OK+1)); else OLD_CTL_OK=$((OLD_CTL_OK+1)); fi
        else
            if [ "$exp" = "DEFECT_SIG" ]; then OLD_TRIG_BAD=$((OLD_TRIG_BAD+1)); else OLD_CTL_BAD=$((OLD_CTL_BAD+1)); fi
        fi
    done
    check_vec_lines "old" "$SPEC_TOTAL"
    verify_sha_unchanged "old" || emit_fail "old_inputs_changed"
    [ "$OLD_TRIG_BAD" -eq 0 ] || emit_fail "old_trigger_not_reproduced_bad=$OLD_TRIG_BAD"
    [ "$OLD_TRIG_OK" -eq "$SPEC_TRIGGER" ] || emit_fail "old_trigger_ok=$OLD_TRIG_OK expect=$SPEC_TRIGGER"
    [ "$OLD_CTL_BAD" -eq 0 ] || emit_fail "old_control_bad=$OLD_CTL_BAD"
    [ "$OLD_CTL_OK" -eq "$SPEC_CONTROL" ] || emit_fail "old_control_ok=$OLD_CTL_OK expect=$SPEC_CONTROL"

    printf 'RENAME_NEGATIVE_MATRIX old_trigger=%s/%s old_control=%s/%s new_ok=%s/%s commit=%s\n' \
           "$OLD_TRIG_OK" "$SPEC_TRIGGER" "$OLD_CTL_OK" "$SPEC_CONTROL" "$OK_N" "$SPEC_TOTAL" "$OLD_COMMIT" \
           >> "$RUN_LOG"

    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
    N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
    [ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"

    N_SUM="$(grep -c '^RENAME_NEGATIVE_MATRIX ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "neg_summary_count=$N_SUM"
    SUM_LINE="$(grep -m1 '^RENAME_NEGATIVE_MATRIX ' "$RUN_LOG" || true)"
    if [[ "$SUM_LINE" =~ ^RENAME_NEGATIVE_MATRIX\ old_trigger=([0-9]+)/([0-9]+)\ old_control=([0-9]+)/([0-9]+)\ new_ok=([0-9]+)/([0-9]+)\ commit=([0-9a-f]+)$ ]]; then
        { [ "${BASH_REMATCH[1]}" = "$SPEC_TRIGGER" ] && [ "${BASH_REMATCH[2]}" = "$SPEC_TRIGGER" ] \
          && [ "${BASH_REMATCH[3]}" = "$SPEC_CONTROL" ] && [ "${BASH_REMATCH[4]}" = "$SPEC_CONTROL" ] \
          && [ "${BASH_REMATCH[5]}" = "$SPEC_TOTAL" ] && [ "${BASH_REMATCH[6]}" = "$SPEC_TOTAL" ] \
          && [ "${BASH_REMATCH[7]}" = "$OLD_COMMIT" ]; } || emit_fail "neg_summary_fields_mismatch line=$SUM_LINE"
    else
        emit_fail "neg_summary_format"
    fi

    N_PASS="$(grep -cxF 'FUNCTIONAL_RENAME: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "default_anchor_present_in_self_test=$N_PASS"
    printf 'FUNCTIONAL_RENAME_NEGATIVE: PASS\n' >> "$RUN_LOG"
    N_NEGPASS="$(grep -cxF 'FUNCTIONAL_RENAME_NEGATIVE: PASS' "$RUN_LOG" || true)"
    [ "$N_NEGPASS" = "1" ] || emit_fail "negative_anchor_count=$N_NEGPASS"

    printf 'RENAME_NEGATIVE_MATRIX old_trigger=%s/%s old_control=%s/%s new_ok=%s/%s commit=%s\n' \
           "$OLD_TRIG_OK" "$SPEC_TRIGGER" "$OLD_CTL_OK" "$SPEC_CONTROL" "$OK_N" "$SPEC_TOTAL" "$OLD_COMMIT"
    printf 'FUNCTIONAL_RENAME_NEGATIVE: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 9. 默认模式：摘要 + 唯一锚点（先计数前缀，再严格格式）
#------------------------------------------------------------------------------
printf 'RENAME_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
       "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" "$BAD_N" >> "$RUN_LOG"
printf 'FUNCTIONAL_RENAME: PASS\n' >> "$RUN_LOG"

N_SUM="$(grep -c '^RENAME_VECTORS ' "$RUN_LOG" || true)"
[ "$N_SUM" = "1" ] || emit_fail "summary_count=$N_SUM"
SUM_LINE="$(grep -m1 '^RENAME_VECTORS ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^RENAME_VECTORS\ total=([0-9]+)\ trigger=([0-9]+)\ control=([0-9]+)\ ok=([0-9]+)\ bad=([0-9]+)$ ]]; then
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
N_PASS="$(grep -cxF 'FUNCTIONAL_RENAME: PASS' "$RUN_LOG" || true)"
[ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"

printf 'RENAME_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
       "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" "$BAD_N"
printf 'FUNCTIONAL_RENAME: PASS\n'
exit 0
