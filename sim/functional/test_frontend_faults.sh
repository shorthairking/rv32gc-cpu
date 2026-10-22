#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_frontend_faults.sh —— F4 前端故障/契约功能定向测试入口
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2B 四发射前端）
# 依据 : prompts/common.md §3（fail-closed：确定性脚本 + 退出码 + 唯一整行锚点）、
#        F4 前端包 A 验收（F05-02/05/07/08/09）与 G1/G2/G3/G4 门禁强化。
#
# 做什么 :
#   1) 校验**完整实际闭包**：
#        产品 16 = 12 RTL + rv32_defs/core_params/front4_params + TB；
#        包   3  = 本入口 + driver + env.sh；env 另按单文件钉死。
#      每个文件都必须存在且**非空**；sha256 块必须"总行数 = 期望、每行 64hex + 精确路径"，
#      多一行/少一行/坏行/重复/路径漂移一律拒（只数合法行不够）。
#   2) 把产品 16 个文件复制进本次 run 的**私有不可变快照**（chmod 444，逐文件复核），
#      编译/运行只使用该快照（cd 快照 + 仅 -I 快照）⇒ 调用者 cwd 的毒化头、活树
#      fallback 都不会被借用；源/包/env 在编译后、运行后**各复核一次**，任何变化即拒。
#   3) 用 iverilog 编译本包固定 TB + 快照 RTL，vvp 运行；编译/运行输出全部落本次
#      独占 run 目录（mktemp -d；脚本内不做任何 rm）。
#   4) 规格按 **TB sha256** 选择，固定 ID/名字/checks/wide，不做"计补偿"：
#        · fixed：最终 TB（6e66dd17…）checks=455 fails=0 wide=12（默认）；
#        · fixed：历史 345 TB（984dd7e4…）345/12、历史 201 TB（6e7a79ae…）201/12、
#                 历史 183 TB（f7e0e19c…）183/12 —— 仅作**有版本绑定的控制**，不替代 455；
#        · old  ：最终 455 TB 对 201acf61 真实旧 RTL checks=429 fails=114 wide=0，
#                 失败 CHECK_FAIL 编号集合固定（114 项）+ 合法 control 36..56；
#        · old345：最终 455 TB 对“当前产品 + 入库 a295 Q2/faultmask 回退 patch”
#                 checks=455 fails=22 wide=12（22 个精确 ID），a295 旧产品可复现正反。
#      未知 TB sha 一律失败（fail-closed）。
#
# 判定（全部满足才 PASS，否则 exit 1 且**绝不**打印 PASS 锚点）:
#   · 参数：不接受位置参数；env.sh source rc=0；工具（含 timeout/sha256sum）非空可执行
#   · 输入：产品/包/env 非空 + sha 块严格合法（rc/总行数/每行 hex+路径）
#   · 编译：rc=0 且 vvp 非空（rc=0 零产物亦失败；超时失败；缺依赖/坏源不得当功能红）
#   · 运行：rc=0（超时失败；零输出失败）
#   · 日志：fixed 不得出现 FAIL/CHECK_FAIL/DEFECT；摘要唯一严格匹配；PASS 锚点恰好 1 行
#   · old  ：摘要 319/67/0、CHECK_FAIL 编号集合逐项一致、control 36..56 全不失败、
#            不得出现 PASS 锚点；退出 1 并给真实失败签名。
#
# 用法 : bash sim/functional/test_frontend_faults.sh
#        DUT_ROOT=<只读源根> bash sim/functional/test_frontend_faults.sh
#        FRONTEND_FAULTS_EXPECT=old DUT_ROOT=<旧源根> bash sim/functional/test_frontend_faults.sh
#        OUT_DIR=<产物根> / RV32_FUNCTIONAL_PKG_OUT_DIR=<产物根>
#==============================================================================
set -u

if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-300}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-300}"
EXPECT="${FRONTEND_FAULTS_EXPECT:-fixed}"
case "$EXPECT" in
    fixed|old|old345) : ;;
    *) printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=unknown_expect value=%s\n' "$EXPECT"
       exit 1 ;;
esac

SELF_PATH="$(readlink -m -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_frontend_faults.sv"
DRIVER_SRC="$SELF_DIR/test_frontend_faults_driver.sh"
ENV_SH="$REPO_ROOT/scripts/env.sh"

#------------------------------------------------------------------------------
# 0. 冻结规格（与 TB sha256 一一对应；TB 改一个字节 ⇒ 未知 sha ⇒ 失败，必须显式登记）
#------------------------------------------------------------------------------
SPEC_DEFAULT_TB_SHA="6e66dd178c83d776f701d2256462dde26a54677ae7360cf3f62b5dca98c0b46d"
SPEC_DEFAULT_ID="f4faults-final-455"
SPEC_DEFAULT_CHECKS=455
SPEC_DEFAULT_WIDE=12

# 版本绑定的历史控制表（**不替代** 455；仅用于旧 TB/旧产品对照）
SPEC_HIST345_TB_SHA="984dd7e4a24d12066b01808630954f230875759f5473028f821dc1c9c0ea86b7"
SPEC_HIST345_ID="f4faults-hist-345"
SPEC_HIST345_CHECKS=345
SPEC_HIST345_WIDE=12
SPEC_HIST201_TB_SHA="6e7a79ae41feaf8deece5144ac85575c783d1ece74990b09a5063916fe0756d5"
SPEC_HIST201_ID="f4faults-hist-201"
SPEC_HIST201_CHECKS=201
SPEC_HIST201_WIDE=12

SPEC_R0_TB_SHA="f7e0e19cf1d1ca3c904b9caac6c57ecebb7da0dbf9f13dbaab38bd2e22508b15"
SPEC_R0_ID="f4faults-r0-183"
SPEC_R0_CHECKS=183
SPEC_R0_WIDE=12

#   ★ 最终 TB 已登记（345/12）。历史 201/183 表只按各自 TB sha 命中，作版本绑定
#     控制，不参与默认判定；任何 TB 字节变化都会变成 tb_spec_unknown（fail-closed）。
SPEC_OLD_TB_SHA="$SPEC_DEFAULT_TB_SHA"
SPEC_OLD_ID="f4faults-base201-old"
SPEC_OLD_CHECKS=429
SPEC_OLD_FAILS=114
SPEC_OLD_WIDE=0
#   真实 201acf61 + 最终 455 TB 的执行数/失败集（实际旧分支执行数，非 319/67 外推）
SPEC_OLD_FAIL_IDS="1 4 6 8 33 34 35 57 60 61 72 80 85 86 87 88 136 137 157 158 159 160 161 162 164 165 166 168 169 170 173 181 183 184 185 186 187 189 190 191 192 193 194 195 208 209 211 212 213 214 289 290 291 292 293 294 296 298 300 311 312 313 314 315 316 317 318 321 322 323 324 325 328 329 330 331 332 335 336 337 338 339 342 343 344 345 346 349 350 356 357 363 364 370 371 377 378 384 385 391 392 402 403 404 407 411 413 414 415 416 417 422 424 427"
#   a295 回退产品（当前产品 + in-tree patch）+ 最终 455 TB 的精确 22 失败集
SPEC_REV345_CHECKS=455
SPEC_REV345_FAILS=22
SPEC_REV345_WIDE=12
SPEC_REV345_FAIL_IDS="347 348 349 350 351 354 355 356 357 358 361 362 363 364 365 368 369 370 371 372 438 451"
#   合法 control：旧树上也必须通过的 T4（跨页 PMP 第二 parcel）与 T5（检查点归属）编号。
SPEC_OLD_CONTROL_IDS="36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56"

#------------------------------------------------------------------------------
# 1. 路径/产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run（不 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=auth_root_readlink_failed\n'; exit 1; }
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/frontend-faults}}"
is_authorized() { case "$1" in "$AUTH_ROOT" | "$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=out_root_readlink_failed root=%s\n' "$ROOT_RAW"; exit 1; }
is_authorized "$ROOT_NORM" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=out_root_unauthorized root=%s auth=%s\n' \
        "$ROOT_NORM" "$AUTH_ROOT"; exit 1; }
mkdir -p -- "$ROOT_NORM" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=out_root_mkdir_failed root=%s\n' "$ROOT_NORM"; exit 1; }
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=out_root_recheck_failed\n'; exit 1; }
is_authorized "$ROOT_NORM" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=out_root_unauthorized_after_mkdir root=%s\n' "$ROOT_NORM"; exit 1; }
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=mktemp_run_dir_failed root=%s\n' "$ROOT_NORM"; exit 1; }
RUN_LOG="$RUN_DIR/test_frontend_faults.log"
COMPILE_LOG="$RUN_DIR/test_frontend_faults.compile.log"
RUN_OUT="$RUN_DIR/test_frontend_faults.run.log"
VVP_OUT="$RUN_DIR/tb_frontend_faults.vvp"
: > "$RUN_LOG" || { printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=run_log_create_failed\n'; exit 1; }

SUM_CHECKS="-"; SUM_FAILS="-"; SUM_WIDE="-"; SUM_ID="-"
emit_summary_line() {
    printf 'FRONTEND_FAULTS checks=%s fails=%s wide_blocks=%s\n' \
        "$SUM_CHECKS" "$SUM_FAILS" "$SUM_WIDE"
}
emit_fail() {
    emit_summary_line
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=%s run_dir=%s\n' "$1" "$RUN_DIR"
    exit 1
}

{
    echo "==== test_frontend_faults.sh : F4 frontend faults (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "TB_SRC          = $TB_SRC"
    echo "DRIVER_SRC      = $DRIVER_SRC"
    echo "EXPECT          = $EXPECT"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "================================================================"
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

#------------------------------------------------------------------------------
# 2. 哈希工具：rc **原样传播**；空输出/非 64hex 一律拒（不允许空==空假绿）
#------------------------------------------------------------------------------
SHA_OUT=""; SHA_RC=0
is_hex64() {
    case "$1" in *[!0-9a-f]*|"") return 1 ;; esac
    [ "${#1}" -eq 64 ] || return 1
    return 0
}
hash_many() {  # hash_many <file...> ⇒ SHA_OUT（完整 sha256sum 输出）、SHA_RC
    SHA_OUT="$(sha256sum -- "$@" 2>>"$RUN_LOG")"
    SHA_RC=$?
    return "$SHA_RC"
}
hash_one() {
    SHA_OUT="$(sha256sum -- "$1" 2>>"$RUN_LOG")"
    SHA_RC=$?
    return "$SHA_RC"
}
one_hash_of() {  # one_hash_of <file> ⇒ ONE_HASH；完整单行 64hex + 精确 path，无尾垃圾
    ONE_HASH=""
    local f="$1" line h p n
    hash_one "$f" || return 1
    [ -n "$SHA_OUT" ] || return 1
    n="$(printf '%s\n' "$SHA_OUT" | wc -l)"
    [ "$n" -eq 1 ] || return 1
    line="$SHA_OUT"
    [[ "$line" =~ ^([0-9a-f]{64})\ \ (.*)$ ]] || return 1
    h="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
    [ "$p" = "$f" ] || return 1
    is_hex64 "$h" || return 1
    ONE_HASH="$h"
    return 0
}

#   严格校验 sha 块：总行数 == EXPECT_N；每行 = 64hex + 两个空格 + 精确路径（顺序一致）
EXPECT_N=0; EXPECT_PATHS=()
validate_sha_block() {  # validate_sha_block <output> <tag>
    local out="$1" tag="$2" line h p i n
    local -a L
    [ -n "$out" ] || emit_fail "${tag}_empty"
    mapfile -t L <<< "$out"
    n="${#L[@]}"
    [ "$n" -eq "$EXPECT_N" ] || emit_fail "${tag}_lines=$n expect=$EXPECT_N"
    for ((i = 0; i < n; i++)); do
        line="${L[$i]}"
        if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ (.*)$ ]]; then
            emit_fail "${tag}_bad_line=$((i + 1))"
        fi
        h="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
        is_hex64 "$h" || emit_fail "${tag}_bad_hex=$((i + 1))"
        [ "$p" = "${EXPECT_PATHS[$i]}" ] || \
            emit_fail "${tag}_path=$((i + 1)) got=$p expect=${EXPECT_PATHS[$i]}"
    done
}

#------------------------------------------------------------------------------
# 3. 完整实际闭包（全部 caller 非空）
#------------------------------------------------------------------------------
RTL_REL=(
    rtl/front4/front4_top.v rtl/front4/ifetch4.v rtl/front4/pc_gen4.v
    rtl/front4/predictor_top.v rtl/front4/bpu_btb.v rtl/front4/bpu_gshare.v
    rtl/front4/bpu_local_hist.v rtl/front4/bpu_ras.v rtl/front4/bpu_selector.v
    rtl/front4/front4_mem.v rtl/front4/front4_table_2lu_1upd.v rtl/mem/pmp_check.v
)
HDR_REL=( rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh rtl/front4/front4_params.vh )
PROD_N=$(( ${#RTL_REL[@]} + ${#HDR_REL[@]} + 1 ))          # 12 + 3 + TB = 16
PKG_N=3                                                     # 本入口 + driver + env

[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"
[ -s "$TB_SRC" ] || emit_fail "tb_empty tb=$TB_SRC"
for f in "$SELF_PATH" "$DRIVER_SRC" "$ENV_SH"; do
    [ -f "$f" ] || emit_fail "pkg_missing file=$f"
    [ -s "$f" ] || emit_fail "pkg_empty file=$f"
done

DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || \
    emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"
echo "DUT_ROOT        = $DUT_ROOT" >> "$RUN_LOG"

PROD_PATHS=()
for rel in "${RTL_REL[@]}" "${HDR_REL[@]}"; do
    [ -f "$DUT_ROOT/$rel" ] || emit_fail "dut_src_missing file=$DUT_ROOT/$rel"
    [ -s "$DUT_ROOT/$rel" ] || emit_fail "dut_src_empty file=$DUT_ROOT/$rel"
    PROD_PATHS+=( "$DUT_ROOT/$rel" )
done
PROD_PATHS+=( "$TB_SRC" )
PKG_PATHS=( "$SELF_PATH" "$DRIVER_SRC" "$ENV_SH" )

#------------------------------------------------------------------------------
# 4. env：source 前先钉死 sha；source 返回码**紧跟**捕获；source 后再复核
#------------------------------------------------------------------------------
EXPECT_N=1; EXPECT_PATHS=( "$ENV_SH" )
hash_many "$ENV_SH"
[ "$SHA_RC" -eq 0 ] || emit_fail "env_sha_pre_rc=$SHA_RC"
ENV_SHA_PRE="$SHA_OUT"
validate_sha_block "$ENV_SHA_PRE" "env_sha_pre"

ENV_RC=0
# shellcheck disable=SC1090
. "$ENV_SH" >> "$RUN_LOG" 2>&1 || ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"

hash_many "$ENV_SH"
[ "$SHA_RC" -eq 0 ] || emit_fail "env_sha_post_source_rc=$SHA_RC"
[ "$SHA_OUT" = "$ENV_SHA_PRE" ] || emit_fail "env_changed_while_sourcing"

IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing name=RV32_IVERILOG value=${IV:-unset}"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing name=RV32_VVP value=${VV:-unset}"
command -v timeout   >/dev/null 2>&1 || emit_fail "tool_missing name=timeout"
command -v sha256sum >/dev/null 2>&1 || emit_fail "tool_missing name=sha256sum"
{
    echo "RV32_IVERILOG   = $IV"
    echo "RV32_VVP        = $VV"
    echo "RV32_ROOT_ENV   = ${RV32_ROOT:-unset}"
    echo "ENV_SH_SHA      = ${ENV_SHA_PRE%%[[:space:]]*}"
    echo "PROD_N          = $PROD_N"
    echo "PKG_N           = $PKG_N"
} >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 5. 规格选择：TB sha 必须已登记；checks/wide/fails 固定；未知即拒
#------------------------------------------------------------------------------
one_hash_of "$TB_SRC" || emit_fail "tb_sha_unavailable tb=$TB_SRC"
TB_SHA="$ONE_HASH"
echo "TB_SHA          = $TB_SHA" >> "$RUN_LOG"

SPEC_FAILS=0
if [ "$EXPECT" = "old" ] || [ "$EXPECT" = "old345" ]; then
    [ "$TB_SHA" = "$SPEC_OLD_TB_SHA" ] || emit_fail "old_tb_sha_mismatch got=$TB_SHA expect=$SPEC_OLD_TB_SHA"
    if [ "$EXPECT" = "old" ]; then
        SPEC_ID="$SPEC_OLD_ID"; SPEC_CHECKS=$SPEC_OLD_CHECKS
        SPEC_FAILS=$SPEC_OLD_FAILS; SPEC_WIDE=$SPEC_OLD_WIDE
    else
        SPEC_ID="f4faults-rev-a295-22"; SPEC_CHECKS=$SPEC_REV345_CHECKS
        SPEC_FAILS=$SPEC_REV345_FAILS; SPEC_WIDE=$SPEC_REV345_WIDE
    fi
else
    if [ "$TB_SHA" = "$SPEC_DEFAULT_TB_SHA" ]; then
        SPEC_ID="$SPEC_DEFAULT_ID"; SPEC_CHECKS=$SPEC_DEFAULT_CHECKS
        SPEC_WIDE=$SPEC_DEFAULT_WIDE
    elif [ "$TB_SHA" = "$SPEC_HIST345_TB_SHA" ]; then
        SPEC_ID="$SPEC_HIST345_ID"; SPEC_CHECKS=$SPEC_HIST345_CHECKS
        SPEC_WIDE=$SPEC_HIST345_WIDE
    elif [ "$TB_SHA" = "$SPEC_HIST201_TB_SHA" ]; then
        SPEC_ID="$SPEC_HIST201_ID"; SPEC_CHECKS=$SPEC_HIST201_CHECKS
        SPEC_WIDE=$SPEC_HIST201_WIDE
    elif [ "$TB_SHA" = "$SPEC_R0_TB_SHA" ]; then
        SPEC_ID="$SPEC_R0_ID"; SPEC_CHECKS=$SPEC_R0_CHECKS
        SPEC_WIDE=$SPEC_R0_WIDE
    else
        emit_fail "tb_spec_unknown sha=$TB_SHA"
    fi
fi
SUM_ID="$SPEC_ID"
echo "SPEC_ID         = $SPEC_ID" >> "$RUN_LOG"
echo "SPEC            = checks=$SPEC_CHECKS fails=$SPEC_FAILS wide_blocks=$SPEC_WIDE" >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 6. 产品/包 冻结（pre）：sha 块严格合法
#------------------------------------------------------------------------------
EXPECT_PATHS=( "${PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
hash_many "${PROD_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_pre_rc=$SHA_RC"
PROD_PRE="$SHA_OUT"
validate_sha_block "$PROD_PRE" "sha256_pre"

EXPECT_PATHS=( "${PKG_PATHS[@]}" ); EXPECT_N=$PKG_N
hash_many "${PKG_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "pkg_sha_pre_rc=$SHA_RC"
PKG_PRE="$SHA_OUT"
validate_sha_block "$PKG_PRE" "pkg_sha_pre"

{
    echo "-- pre-run product sha256 (12 RTL + 3 headers + TB = $PROD_N) --"
    printf '%s\n' "$PROD_PRE"
    echo "-- pre-run package sha256 (entry + driver + env = $PKG_N) --"
    printf '%s\n' "$PKG_PRE"
} >> "$RUN_LOG" || emit_fail "run_log_sha_pre_append_failed"

#------------------------------------------------------------------------------
# 7. 私有不可变 DUT 快照（编译/运行只用它；逐文件复核非空 + 字节一致）
#------------------------------------------------------------------------------
SNAP="$RUN_DIR/dut-snapshot"
mkdir -p -- "$SNAP" || emit_fail "snapshot_mkdir_failed"
SNAP_PATHS=()
for rel in "${RTL_REL[@]}" "${HDR_REL[@]}"; do
    mkdir -p -- "$SNAP/$(dirname -- "$rel")" || emit_fail "snapshot_mkdir_failed rel=$rel"
    cp -p -- "$DUT_ROOT/$rel" "$SNAP/$rel" || emit_fail "snapshot_copy_failed rel=$rel"
    chmod 444 -- "$SNAP/$rel" || emit_fail "snapshot_chmod_failed rel=$rel"
    SNAP_PATHS+=( "$SNAP/$rel" )
    one_hash_of "$DUT_ROOT/$rel" || emit_fail "snapshot_src_hash_failed rel=$rel"
    HSRC="$ONE_HASH"
    one_hash_of "$SNAP/$rel" || emit_fail "snapshot_copy_hash_failed rel=$rel"
    [ -n "$HSRC" ] && [ "$HSRC" = "$ONE_HASH" ] || emit_fail "snapshot_copy_mismatch rel=$rel"
done
mkdir -p -- "$SNAP/sim/functional" || emit_fail "snapshot_mkdir_tb_failed"
cp -p -- "$TB_SRC" "$SNAP/sim/functional/tb_frontend_faults.sv" || emit_fail "snapshot_tb_copy_failed"
chmod 444 -- "$SNAP/sim/functional/tb_frontend_faults.sv" || emit_fail "snapshot_tb_chmod_failed"
SNAP_TB="$SNAP/sim/functional/tb_frontend_faults.sv"
SNAP_PATHS+=( "$SNAP_TB" )
one_hash_of "$TB_SRC" || emit_fail "snapshot_tb_src_hash_failed"
[ "$ONE_HASH" = "$TB_SHA" ] || emit_fail "snapshot_tb_hash_drift"
one_hash_of "$SNAP_TB" || emit_fail "snapshot_tb_copy_hash_failed"
[ "$ONE_HASH" = "$TB_SHA" ] || emit_fail "snapshot_tb_copy_mismatch"

EXPECT_PATHS=( "${SNAP_PATHS[@]}" ); EXPECT_N=$PROD_N
hash_many "${SNAP_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "snapshot_sha_pre_rc=$SHA_RC"
SNAP_PRE="$SHA_OUT"
validate_sha_block "$SNAP_PRE" "snapshot_sha_pre"

SNAP_DUT_FILES=()
for rel in "${RTL_REL[@]}"; do SNAP_DUT_FILES+=( "$SNAP/$rel" ); done

#------------------------------------------------------------------------------
# 8. 编译（**cd 快照** + 仅 -I 快照；rc=0 零产物亦失败）
#------------------------------------------------------------------------------
COMPILE_CMD=( "$IV" -g2012 -I "$SNAP" -s tb_frontend_faults_top -o "$VVP_OUT"
              "$SNAP_TB" "${SNAP_DUT_FILES[@]}" )
{
    echo "-- compile cwd/snapshot: $SNAP"
    echo "-- compile sources: TB + ${#SNAP_DUT_FILES[@]} RTL = $(( ${#SNAP_DUT_FILES[@]} + 1 ))"
    printf 'COMPILE_CMD ='
    printf ' %q' "${COMPILE_CMD[@]}"
    printf '\n'
} >> "$RUN_LOG"
(
    cd -- "$SNAP" || exit 1
    timeout "$TIMEOUT_COMPILE_S" "${COMPILE_CMD[@]}" > "$COMPILE_LOG" 2>&1
)
RC=$?
cat -- "$COMPILE_LOG" >> "$RUN_LOG" || emit_fail "run_log_compile_append_failed"
[ "$RC" -eq 124 ] && emit_fail "compile_timeout"
[ "$RC" -ne 0 ] && emit_fail "compile_rc=$RC"
[ -s "$VVP_OUT" ] || emit_fail "compile_no_vvp_output"

#   ---- 编译后固定：产品/包/env/快照 ----
EXPECT_PATHS=( "$ENV_SH" ); EXPECT_N=1
hash_many "$ENV_SH"
[ "$SHA_RC" -eq 0 ] || emit_fail "env_sha_after_compile_rc=$SHA_RC"
[ "$SHA_OUT" = "$ENV_SHA_PRE" ] || emit_fail "env_changed_after_compile"
EXPECT_PATHS=( "${PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
hash_many "${PROD_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_after_compile_rc=$SHA_RC"
validate_sha_block "$SHA_OUT" "sha256_after_compile"
[ "$SHA_OUT" = "$PROD_PRE" ] || emit_fail "product_changed_after_compile"
EXPECT_PATHS=( "${PKG_PATHS[@]}" ); EXPECT_N=$PKG_N
hash_many "${PKG_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "pkg_sha_after_compile_rc=$SHA_RC"
validate_sha_block "$SHA_OUT" "pkg_sha_after_compile"
[ "$SHA_OUT" = "$PKG_PRE" ] || emit_fail "package_changed_after_compile"
EXPECT_PATHS=( "${SNAP_PATHS[@]}" ); EXPECT_N=$PROD_N
hash_many "${SNAP_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "snapshot_sha_after_compile_rc=$SHA_RC"
validate_sha_block "$SHA_OUT" "snapshot_sha_after_compile"
[ "$SHA_OUT" = "$SNAP_PRE" ] || emit_fail "snapshot_changed_after_compile"

#------------------------------------------------------------------------------
# 9. 运行（超时/非零退出/零输出即失败）
#------------------------------------------------------------------------------
(
    cd -- "$RUN_DIR" || exit 1
    timeout "$TIMEOUT_RUN_S" "$VV" "$VVP_OUT" > "$RUN_OUT" 2>&1
)
RC=$?
cat -- "$RUN_OUT" >> "$RUN_LOG" 2>/dev/null || true
parse_summary_besteffort() {
    local line
    line="$(grep -m1 '^FRONTEND_FAULTS ' "$RUN_DIR/test_frontend_faults.run.log" 2>/dev/null || true)"
    if [[ "$line" =~ ^FRONTEND_FAULTS\ checks=([0-9]+)\ fails=([0-9]+)\ wide_blocks=([0-9]+)$ ]]; then
        SUM_CHECKS="${BASH_REMATCH[1]}"; SUM_FAILS="${BASH_REMATCH[2]}"
        SUM_WIDE="${BASH_REMATCH[3]}"
    fi
}
parse_summary_besteffort
[ "$RC" -eq 124 ] && emit_fail "run_timeout"
if [ "$EXPECT" = "old" ] || [ "$EXPECT" = "old345" ]; then
    # 旧树/a295 回退真实功能失败由 TB $fatal 给出非零 rc（Icarus=1）；超时/其它异常仍拒。
    [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ] || emit_fail "old_run_unexpected_rc=$RC"
else
    [ "$RC" -ne 0 ] && emit_fail "run_rc=$RC"
fi
[ -s "$RUN_OUT" ] || emit_fail "run_zero_output"

#   ---- 运行后固定：产品/包/env/快照（任何一相变化都精确拒）----
EXPECT_PATHS=( "$ENV_SH" ); EXPECT_N=1
hash_many "$ENV_SH"
[ "$SHA_RC" -eq 0 ] || emit_fail "env_sha_after_run_rc=$SHA_RC"
[ "$SHA_OUT" = "$ENV_SHA_PRE" ] || emit_fail "env_changed_after_run"
EXPECT_PATHS=( "${PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
hash_many "${PROD_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_after_run_rc=$SHA_RC"
validate_sha_block "$SHA_OUT" "sha256_after_run"
[ "$SHA_OUT" = "$PROD_PRE" ] || emit_fail "product_changed_after_run"
EXPECT_PATHS=( "${PKG_PATHS[@]}" ); EXPECT_N=$PKG_N
hash_many "${PKG_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "pkg_sha_after_run_rc=$SHA_RC"
validate_sha_block "$SHA_OUT" "pkg_sha_after_run"
[ "$SHA_OUT" = "$PKG_PRE" ] || emit_fail "package_changed_after_run"
EXPECT_PATHS=( "${SNAP_PATHS[@]}" ); EXPECT_N=$PROD_N
hash_many "${SNAP_PATHS[@]}"
[ "$SHA_RC" -eq 0 ] || emit_fail "snapshot_sha_after_run_rc=$SHA_RC"
validate_sha_block "$SHA_OUT" "snapshot_sha_after_run"
[ "$SHA_OUT" = "$SNAP_PRE" ] || emit_fail "snapshot_changed_after_run"

#------------------------------------------------------------------------------
# 10. 判定
#------------------------------------------------------------------------------
N_SUMMARY="$(grep -c '^FRONTEND_FAULTS ' "$RUN_OUT" || true)"
[ "$N_SUMMARY" = "1" ] || emit_fail "summary_count=$N_SUMMARY"
SUM_LINE="$(grep -m1 '^FRONTEND_FAULTS ' "$RUN_OUT" || true)"
if [[ "$SUM_LINE" =~ ^FRONTEND_FAULTS\ checks=([0-9]+)\ fails=([0-9]+)\ wide_blocks=([0-9]+)$ ]]; then
    SUM_CHECKS="${BASH_REMATCH[1]}"; SUM_FAILS="${BASH_REMATCH[2]}"; SUM_WIDE="${BASH_REMATCH[3]}"
else
    emit_fail "summary_format"
fi
[ "$SUM_CHECKS" -ne 0 ] || emit_fail "summary_checks_zero"
[ "$SUM_CHECKS" -eq "$SPEC_CHECKS" ] || emit_fail "summary_checks=$SUM_CHECKS expect=$SPEC_CHECKS"
[ "$SUM_FAILS" -eq "$SPEC_FAILS" ] || emit_fail "summary_fails=$SUM_FAILS expect=$SPEC_FAILS"
[ "$SUM_WIDE" -eq "$SPEC_WIDE" ] || emit_fail "summary_wide=$SUM_WIDE expect=$SPEC_WIDE"

N_PASS="$(grep -cxF 'FUNCTIONAL_FRONTEND_FAULTS: PASS' "$RUN_OUT" || true)"

if [ "$EXPECT" = "old" ] || [ "$EXPECT" = "old345" ]; then
    #   ---- 旧基线/a295 回退：固定真实失败签名 + 合法 control；绝不打印 PASS ----
    [ "$N_PASS" = "0" ] || emit_fail "old_mode_printed_pass n=$N_PASS"
    [ "$SUM_FAILS" -gt 0 ] || emit_fail "old_no_failure_observed"
    N_CF="$(grep -c '^CHECK_FAIL(' "$RUN_OUT" || true)"
    [ "$N_CF" = "$SPEC_FAILS" ] || emit_fail "old_check_fail_count=$N_CF expect=$SPEC_FAILS"
    OLD_GOT_IDS="$(grep -o '^CHECK_FAIL([0-9]\+)' "$RUN_OUT" | sed 's/^CHECK_FAIL(//; s/)$//' | sort -n | tr '\n' ' ')"
    OLD_GOT_IDS="${OLD_GOT_IDS% }"
    if [ "$EXPECT" = "old345" ]; then OLD_WANT_SRC="$SPEC_REV345_FAIL_IDS"; else OLD_WANT_SRC="$SPEC_OLD_FAIL_IDS"; fi
    OLD_WANT_IDS="$(printf '%s\n' $OLD_WANT_SRC | sort -n | tr '\n' ' ')"
    OLD_WANT_IDS="${OLD_WANT_IDS% }"
    [ "$OLD_GOT_IDS" = "$OLD_WANT_IDS" ] || \
        emit_fail "old_check_fail_ids got=[$OLD_GOT_IDS] expect=[$OLD_WANT_IDS]"
    for cid in $SPEC_OLD_CONTROL_IDS; do
        printf '%s\n' "$OLD_GOT_IDS" | tr ' ' '\n' | grep -qx "$cid" && \
            emit_fail "old_control_failed id=$cid"
    done
    for cid in $SPEC_OLD_CONTROL_IDS; do
        grep -q "^\(.*\)CHECK_FAIL($cid):" "$RUN_OUT" && emit_fail "old_control_marker id=$cid"
    done
    emit_summary_line
    printf 'FUNCTIONAL_FRONTEND_FAULTS: DEFECT_REPRODUCED root=%s checks=%s fails=%s wide=%s ids=%s\n' \
        "$([ "$EXPECT" = "old345" ] && echo f4-rev-a295 || echo f4-baseline-201acf61)" \
        "$SUM_CHECKS" "$SUM_FAILS" "$SUM_WIDE" "$OLD_GOT_IDS"
    printf 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=old_baseline_defects_confirmed run_dir=%s\n' "$RUN_DIR"
    exit 1
fi

#   ---- fixed：任何 FAIL/CHECK_FAIL/DEFECT 都拒；锚点唯一 ----
N_ANYFAIL="$(grep -c 'FAIL' "$RUN_OUT" || true)"
[ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
N_CF="$(grep -c 'CHECK_FAIL' "$RUN_OUT" || true)"
[ "$N_CF" = "0" ] || emit_fail "log_has_CHECK_FAIL=$N_CF"
N_DEFECT="$(grep -c 'DEFECT' "$RUN_OUT" || true)"
[ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect=$N_DEFECT"
N_TIMEOUT="$(grep -c 'TB 超时\|TIMEOUT' "$RUN_OUT" || true)"
[ "$N_TIMEOUT" = "0" ] || emit_fail "log_has_timeout=$N_TIMEOUT"
[ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"
N_ANCHOR="$(grep -c '^FUNCTIONAL_FRONTEND_FAULTS:' "$RUN_OUT" || true)"
[ "$N_ANCHOR" = "1" ] || emit_fail "fault_anchor_count=$N_ANCHOR"

emit_summary_line
printf 'FUNCTIONAL_FRONTEND_FAULTS: PASS\n'
exit 0
