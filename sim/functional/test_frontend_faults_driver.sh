#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_frontend_faults_driver.sh —— F4 前端故障包自证驱动
#==============================================================================
# 目的 : 在**一次冻结**的产品闭包上复现包装器自证 + 旧基线红/新树绿对照。
#
#   F1 一次冻结：产品 16（12 RTL + 3 头 + TB）取自 FRONTEND_FAULTS_SRC_ROOT；
#      包 3（本入口 wrapper + 本 driver + env.sh）取自当前仓库；逐文件非空 + 严格
#      sha 块（总行数/每行 64hex+精确路径）冻结到本次 run；**所有 mini 只从该冻结
#      派生**，不在 matrix 里重复读活树。
#   P1 正控：最终产品 + 冻结包 ⇒ rc=0、唯一 PASS、checks=455/0/12。
#   P2 隔离：同一 mini 连续两次 ⇒ 两个不同 run 目录且都 PASS；各 mini 自己的
#      canonical PKGOUT（子调用显式清空父 RV32_FUNCTIONAL_PKG_OUT_DIR/OUT_DIR）。
#   P3 父 PKGOUT：driver 自身支持父 PKGOUT（授权树内 + mktemp）；父合法 ⇒ 子 driver
#      正控 PASS；父非法（单独 / 同时给合法 OUT_DIR 两优先级）⇒ 精确拒。
#   P4 Poison-cwd：先用**完整 16 源编译命令**证明毒头真有毒；再在毒 cwd 外启动
#      包装器正控，证明实际 compile cwd 是 run 私有不快照（不是 TB+top 子集）。
#   P5/P5a/P6 历史表：**当前 455 产品 + 入库 183/345/201 TB fixture** ⇒ 各自
#      183/345/201 全绿（版本绑定控制；不是历史 RTL 复跑，不依赖 ignored build/）。
#   P8 a295 正反：当前 455 产品 + 入库 a295 Q2/faultmask 回退 patch ⇒ 精确
#      455/22/12（22 个固定 ID），证明旧产品缺陷可复现且新 TB 已覆盖。
#   N12 旧基线：git 201acf61 + **纯接口/观测兼容垫片**（不改旧逻辑）⇒ 必须红：
#      checks=429 fails=114 wide=0、114 个 CHECK_FAIL 编号固定、control 36..56 不失败；
#      新 TB 的 T18/T19/T20/T21 真实跑并把新特性 ID 列入真实失败集；
#      缺基线 commit 必须失败（绝不 SKIP+ok）。
#   W* 包装器 fail-closed：未知参数 / 编译失败 / 零 vvp / 运行非零 / 超时 / 空输出 /
#      缺摘要 / 重锚点 / 去锚点 / 注入 FAIL / 注入 DEFECT / checks/wide 错 /
#      缺 TB / 缺 driver / TB 未登记（spec 未知）⇒ 各自精确 reason。
#   H* sha 杀伤：合法 stdout 后 exit9 / 空 / 多一行 / 坏行 / 读失败；env 单文件 exit9。
#   M* 跨相漂移：运行中改 RTL/头/TB ⇒ product_changed_after_run；改 env ⇒
#      env_changed_after_run；改 wrapper/driver ⇒ package_changed_after_run。
#   C  合法 no-op 控：所有变异工装在同一管线里**不改任何文件** ⇒ 必须 PASS。
#
# 产物 : <repo>/build/functional/frontend-faults-driver/driver-<随机>/（不 rm）
# 判定 : 全部正控 PASS + 全部反证按**真实原因**被拒 + 冻结前后一致 ⇒ 唯一整行
#        `FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS`，rc=0。
#==============================================================================
set -u

if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

SELF_PATH="$(readlink -m -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || exit 1
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || exit 1
WRAP_SRC="$REPO_ROOT/sim/functional/test_frontend_faults.sh"
DRV_SRC="$SELF_PATH"
ENV_SRC="$REPO_ROOT/scripts/env.sh"
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || exit 1
LEAF="${FF_DRIVER_LEAF:-0}"
SRC_ROOT="${FRONTEND_FAULTS_SRC_ROOT:-$REPO_ROOT}"
BASE_COMMIT="${FRONTEND_FAULTS_BASELINE_COMMIT:-201acf61e118a3fb533e1a96768687a35efa1751}"
#   旧基线 git 仓库：默认当前仓库；clean-checkout mini 可显式指向其 git 源（只影响
#   201acf61 旧源/缺基线反证，不影响产品 source root）。
BASELINE_REPO="${FRONTEND_FAULTS_BASELINE_REPO:-$REPO_ROOT}"
TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-300}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-300}"
#   ★ 与 test_frontend_faults.sh 的 SPEC_DEFAULT_* / SPEC_R0_* 同步。f2 最终 TB 母转
#     最终 spec 后，一次性同步 wrapper 表 + 这里（中间 201/202 都不是最终）。
SPEC_CUR_ID="f4faults-final-455"
SPEC_CUR_CHECKS=455
SPEC_CUR_WIDE=12
SPEC_HIST345_ID="f4faults-hist-345"
SPEC_HIST345_CHECKS=345
SPEC_HIST345_WIDE=12
SPEC_HIST201_ID="f4faults-hist-201"
SPEC_HIST201_CHECKS=201
SPEC_HIST201_WIDE=12
SPEC_LEGACY_ID="f4faults-r0-183"
SPEC_LEGACY_CHECKS=183
SPEC_LEGACY_WIDE=12
SPEC_OLD_ID="f4faults-base201-old"
SPEC_OLD_CHECKS=429
SPEC_OLD_FAILS=114
SPEC_OLD_WIDE=0
SPEC_OLD_FAIL_IDS="1 4 6 8 33 34 35 57 60 61 72 80 85 86 87 88 136 137 157 158 159 160 161 162 164 165 166 168 169 170 173 181 183 184 185 186 187 189 190 191 192 193 194 195 208 209 211 212 213 214 289 290 291 292 293 294 296 298 300 311 312 313 314 315 316 317 318 321 322 323 324 325 328 329 330 331 332 335 336 337 338 339 342 343 344 345 346 349 350 356 357 363 364 370 371 377 378 384 385 391 392 402 403 404 407 411 413 414 415 416 417 422 424 427"
SPEC_OLD_CONTROL_IDS="36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56"
SPEC_OLD_NEW_IDS="321 349 411 424"
SPEC_REV345_CHECKS=455
SPEC_REV345_FAILS=22
SPEC_REV345_WIDE=12
SPEC_REV345_FAIL_IDS="347 348 349 350 351 354 355 356 357 358 361 362 363 364 365 368 369 370 371 372 438 451"
#   历史 TB 以**simulation-only fixture**入库，按 sha256 钉死；不再依赖 build/ 临时目录。
FIXTURES_ROOT="${FRONTEND_FAULTS_FIXTURES_ROOT:-$REPO_ROOT/sim/functional/fixtures}"
HIST345_FIXTURE="$FIXTURES_ROOT/frontend_hist_345/tb_frontend_faults.sv"
HIST201_FIXTURE="$FIXTURES_ROOT/frontend_hist_201/tb_frontend_faults.sv"
HIST183_FIXTURE="$FIXTURES_ROOT/frontend_hist_183/tb_frontend_faults.sv"
A295_PATCH="$FIXTURES_ROOT/frontend_hist_a295/revert_a295.patch"
GEN_SRC="$REPO_ROOT/sim/unit/prog/gen_front4_int_data.py"
HIST345_TB_SHA="984dd7e4a24d12066b01808630954f230875759f5473028f821dc1c9c0ea86b7"
HIST201_TB_SHA="6e7a79ae41feaf8deece5144ac85575c783d1ece74990b09a5063916fe0756d5"
HIST183_TB_SHA="f7e0e19cf1d1ca3c904b9caac6c57ecebb7da0dbf9f13dbaab38bd2e22508b15"
A295_PATCH_SHA="64c00a54b9ff128ec4cf8acb8ab079c881d0db8445a60c0706de3494bb3b1dda"
GEN_SHA="3f835c72ec24e835e18ddd314934d588da03b61e678993c4be693f43f929fb1c"

[ -d "$SRC_ROOT" ] || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=src_root_missing path=%s\n' "$SRC_ROOT"; exit 1; }
SRC_ROOT="$(cd -- "$SRC_ROOT" && pwd -P)" || exit 1
[ -f "$WRAP_SRC" ] || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=entry_missing path=%s\n' "$WRAP_SRC"; exit 1; }
[ -f "$DRV_SRC" ]  || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=driver_missing path=%s\n' "$DRV_SRC"; exit 1; }
[ -f "$ENV_SRC" ]  || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=env_missing path=%s\n' "$ENV_SRC"; exit 1; }

#------------------------------------------------------------------------------
# 0. 输出根：父 PKGOUT（规范化+授权）或默认；mktemp 独占 driver 目录
#------------------------------------------------------------------------------
PARENT_PKGOUT="${RV32_FUNCTIONAL_PKG_OUT_DIR:-}"
if [ -n "$PARENT_PKGOUT" ]; then
    BASE="$(readlink -m -- "$PARENT_PKGOUT")" || {
        printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=parent_pkgout_unresolved path=%s\n' "$PARENT_PKGOUT"; exit 1; }
    case "$BASE" in
        "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
        *) printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=parent_pkgout_unauthorized path=%s auth=%s\n' \
               "$BASE" "$AUTH_ROOT"; exit 1 ;;
    esac
else
    BASE="$AUTH_ROOT/frontend-faults-driver"
fi
mkdir -p -- "$BASE" || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=base_mkdir_failed path=%s\n' "$BASE"; exit 1; }
BASE="$(readlink -m -- "$BASE")" || exit 1
case "$BASE" in "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;; *)
    printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=base_unauthorized path=%s\n' "$BASE"; exit 1 ;; esac
W="$(mktemp -d -- "$BASE/driver-XXXXXXXX")" || {
    printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=workdir_mktemp_failed base=%s\n' "$BASE"; exit 1; }
LOG="$W/driver.log"
: > "$LOG" || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }
exec 3>>"$LOG"

note() { printf '%s\n' "$*" >&3; }
fail() {
    note "DRIVER_FAIL reason=$1"
    printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=%s work_dir=%s\n' "$1" "$W"
    exit 1
}
NT=0; NG=0
sub_ok()   { NT=$((NT + 1)); note "OK   $1"; }
sub_fail() { NT=$((NT + 1)); NG=$((NG + 1)); printf 'DRIVER_SUBFAIL %-34s %s\n' "$1" "$2" | tee -a "$LOG" >&2; }

note "==== test_frontend_faults_driver.sh ===="
note "date       = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT  = $REPO_ROOT"
note "SRC_ROOT   = $SRC_ROOT"
note "W          = $W"
note "LEAF       = $LEAF"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    note "GIT_HEAD   = $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

#------------------------------------------------------------------------------
# 1. 工具真源（只读 env.sh）；source 返回码紧跟捕获
#------------------------------------------------------------------------------
[ -r "$ENV_SRC" ] || fail "env_missing path=$ENV_SRC"
ENV_RC=0
# shellcheck disable=SC1090
. "$ENV_SRC" >> "$LOG" 2>&1 || ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || fail "env_sh_source_rc=$ENV_RC"
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || fail "tool_missing name=RV32_IVERILOG"
[ -n "$VV" ] && [ -x "$VV" ] || fail "tool_missing name=RV32_VVP"
for t in timeout sha256sum mktemp python3 git patch; do
    command -v "$t" >/dev/null 2>&1 || fail "tool_missing name=$t"
done
REAL_IV="$IV"; REAL_VV="$VV"; REAL_SHA="$(command -v sha256sum)"

#------------------------------------------------------------------------------
# 2. 闭包定义 + 哈希工具（rc 传播、空/坏 hex 拒、双保险非空比较）
#------------------------------------------------------------------------------
RTL_REL=(
    rtl/front4/front4_top.v rtl/front4/ifetch4.v rtl/front4/pc_gen4.v
    rtl/front4/predictor_top.v rtl/front4/bpu_btb.v rtl/front4/bpu_gshare.v
    rtl/front4/bpu_local_hist.v rtl/front4/bpu_ras.v rtl/front4/bpu_selector.v
    rtl/front4/front4_mem.v rtl/front4/front4_table_2lu_1upd.v rtl/mem/pmp_check.v
)
HDR_REL=( rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh rtl/front4/front4_params.vh )
PROD_REL=( "${RTL_REL[@]}" "${HDR_REL[@]}" )
PROD_N=$(( ${#PROD_REL[@]} + 1 ))              # + TB = 16
PKG_N=3                                        # wrapper + driver + env

HASH_OUT=""; HASH_ERR=""
SHA_RAW="$W/.sha_raw.$$"
raw_block_ok() {  # <raw> <expect_lines>
    local raw="$1" want="$2" bytes lf last
    # Validate bytes before cat/head/command substitution can normalize them.
    python3 - "$raw" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
if b'\0' in b or any(c < 0x20 and c not in (0x0a,) for c in b):
    raise SystemExit(1)
PY
    [ "$?" -eq 0 ] || return 1
    bytes="$(wc -c < "$raw")"; [ "$bytes" -gt 0 ] || return 1
    last="$(tail -c 1 "$raw" | od -An -tu1 | tr -d ' \n')"
    [ "$last" = "10" ] || return 1
    lf="$(tr -cd '\n' < "$raw" | wc -c)"
    [ "$lf" -eq "$want" ] || return 1
    if grep -q '^$' "$raw"; then return 1; fi
    if grep -q "$(printf '\r')" "$raw"; then return 1; fi
    return 0
}
hash_one() {
    local f="$1" raw rc bytes line p h
    HASH_ERR=""; HASH_OUT=""; raw="$SHA_RAW"
    : > "$raw" || { HASH_ERR="hash_tmp file=$f"; return 1; }
    sha256sum -- "$f" > "$raw" 2>>"$LOG"; rc=$?
    [ "$rc" -eq 0 ] || { HASH_ERR="hash_rc=$rc file=$f"; return 1; }
    raw_block_ok "$raw" 1 || { HASH_ERR="hash_rawline file=$f"; return 1; }
    bytes="$(wc -c < "$raw")"
    line="$(head -c "$((bytes - 1))" "$raw")"
    if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ (.*)$ ]]; then
        HASH_ERR="hash_format file=$f"; return 1
    fi
    h="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
    [ "$p" = "$f" ] || { HASH_ERR="hash_path=$p file=$f"; return 1; }
    case "$h" in *[!0-9a-f]*|"") HASH_ERR="hash_badhex file=$f"; return 1 ;; esac
    [ "${#h}" -eq 64 ] || { HASH_ERR="hash_len=${#h} file=$f"; return 1; }
    HASH_OUT="$h"
    return 0
}
verify_copy_equal() {  # <src> <dst> <tag>
    local src="$1" dst="$2" tag="$3" hs hd
    hash_one "$src" || { HASH_ERR="src_${HASH_ERR}"; return 1; }; hs="$HASH_OUT"
    hash_one "$dst" || { HASH_ERR="dst_${HASH_ERR}"; return 1; }; hd="$HASH_OUT"
    [ -n "$hs" ] && [ -n "$hd" ] || { HASH_ERR="empty_hash tag=$tag"; return 1; }
    [ "$hs" = "$hd" ] || { HASH_ERR="mismatch src=$hs dst=$hd tag=$tag"; return 1; }
    return 0
}
is_hex64() { case "$1" in *[!0-9a-f]*|"") return 1 ;; esac; [ "${#1}" -eq 64 ]; }

EXPECT_N=0; EXPECT_PATHS=()
validate_block() {  # <output> <tag>
    local out="$1" tag="$2" line h p i n
    local -a L
    [ -n "$out" ] || fail "${tag}_empty"
    mapfile -t L <<< "$out"
    n="${#L[@]}"
    [ "$n" -eq "$EXPECT_N" ] || fail "${tag}_lines=$n expect=$EXPECT_N"
    for ((i = 0; i < n; i++)); do
        line="${L[$i]}"
        [[ "$line" =~ ^([0-9a-f]{64})\ \ (.*)$ ]] || fail "${tag}_bad_line=$((i + 1))"
        h="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
        is_hex64 "$h" || fail "${tag}_bad_hex=$((i + 1))"
        [ "$p" = "${EXPECT_PATHS[$i]}" ] || fail "${tag}_path=$((i + 1)) got=$p expect=${EXPECT_PATHS[$i]}"
    done
}
sha_list() {  # <file...> ⇒ SHA_LIST_OUT（规范行）/ SHA_LIST_RC；原始行先验
    SHA_LIST_OUT=""; SHA_LIST_RC=0
    : > "$SHA_RAW" || { SHA_LIST_RC=1; return 1; }
    sha256sum -- "$@" > "$SHA_RAW" 2>>"$LOG"; SHA_LIST_RC=$?
    [ "$SHA_LIST_RC" -eq 0 ] || { SHA_LIST_OUT=""; return "$SHA_LIST_RC"; }
    raw_block_ok "$SHA_RAW" "$#" || { SHA_LIST_RC=1; SHA_LIST_OUT=""; return 1; }
    SHA_LIST_OUT="$(cat "$SHA_RAW")"
    return 0
}

#------------------------------------------------------------------------------
# 2b. 历史 TB fixture 身份图（simulation-only；逐字入库、sha256 钉死）
#     不依赖 ignored build/；缺失/改一字节 ⇒ 精确拒，绝不 SKIP/静默 fallback。
#------------------------------------------------------------------------------
FIXTURE_PATHS=( "$HIST345_FIXTURE" "$HIST201_FIXTURE" "$HIST183_FIXTURE" "$A295_PATCH" "$GEN_SRC" )
FIXTURE_SHAS=( "$HIST345_TB_SHA" "$HIST201_TB_SHA" "$HIST183_TB_SHA" "$A295_PATCH_SHA" "$GEN_SHA" )
FIXTURE_ROLES=( historical_tb_345 historical_tb_201 historical_tb_183 a295_q2fault_revert_patch golden_generator )
fixture_check() {
    local i p want got
    for ((i = 0; i < ${#FIXTURE_PATHS[@]}; i++)); do
        p="${FIXTURE_PATHS[$i]}"; want="${FIXTURE_SHAS[$i]}"
        [ -f "$p" ] || fail "fixture_missing path=$p"
        [ -s "$p" ] || fail "fixture_empty path=$p"
        hash_one "$p" || fail "fixture_hash_failed path=$p ${HASH_ERR}"
        got="$HASH_OUT"
        is_hex64 "$want" || fail "fixture_expected_sha_bad path=$p"
        [ "$got" = "$want" ] || fail "fixture_sha_mismatch path=$p got=$got expect=$want"
        note "FIXTURE_MAP path=$p sha256=$got role=${FIXTURE_ROLES[$i]}"
    done
}
#   （在冻结完成后再对 FREEZE fixture 调 fixture_check，避免读活路径）

#------------------------------------------------------------------------------
# 3. 一次冻结：产品 16（SRC_ROOT）+ 包 3（当前仓库）+ env 单文件
#------------------------------------------------------------------------------
TB_SRC="$SRC_ROOT/sim/functional/tb_frontend_faults.sv"
[ -f "$TB_SRC" ] || fail "tb_missing path=$TB_SRC"
[ -s "$TB_SRC" ] || fail "tb_empty path=$TB_SRC"
for rel in "${PROD_REL[@]}"; do
    [ -f "$SRC_ROOT/$rel" ] || fail "prod_missing path=$SRC_ROOT/$rel"
    [ -s "$SRC_ROOT/$rel" ] || fail "prod_empty path=$SRC_ROOT/$rel"
done
[ -s "$WRAP_SRC" ] || fail "entry_empty path=$WRAP_SRC"
[ -s "$DRV_SRC" ]  || fail "driver_empty path=$DRV_SRC"
[ -s "$ENV_SRC" ]  || fail "env_empty path=$ENV_SRC"

#   ★ copy 前固定完整源 manifest（产品16 + 包3 + fixture 4 + generator 1 = 24）
SRC_ALL_PATHS=()
for rel in "${PROD_REL[@]}"; do SRC_ALL_PATHS+=( "$SRC_ROOT/$rel" ); done
SRC_ALL_PATHS+=( "$TB_SRC" "$WRAP_SRC" "$DRV_SRC" "$ENV_SRC"
                 "$HIST345_FIXTURE" "$HIST201_FIXTURE" "$HIST183_FIXTURE"
                 "$A295_PATCH" "$GEN_SRC" )
SRC_ALL_N=24
[ "${#SRC_ALL_PATHS[@]}" -eq "$SRC_ALL_N" ] || fail "src_manifest_count=${#SRC_ALL_PATHS[@]}"
for p in "${SRC_ALL_PATHS[@]}"; do
    [ -f "$p" ] || fail "src_manifest_missing path=$p"
    [ -s "$p" ] || fail "src_manifest_empty path=$p"
done
EXPECT_PATHS=( "${SRC_ALL_PATHS[@]}" ); EXPECT_N=$SRC_ALL_N
sha_list "${SRC_ALL_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "src_manifest_sha_rc=$SHA_LIST_RC"
SRC_ALL_PRE="$SHA_LIST_OUT"; validate_block "$SRC_ALL_PRE" "src_manifest_sha_pre"
{
    echo "-- source manifest pre-copy (24 = product16 + pkg3 + fixtures4 + generator1) --"
    printf '%s\n' "$SRC_ALL_PRE"
} >> "$LOG"

FREEZE="$W/freeze"
FREEZE_PROD_PATHS=()
mkdir -p -- "$FREEZE" || fail "freeze_mkdir_failed"
for rel in "${PROD_REL[@]}"; do
    mkdir -p -- "$FREEZE/$(dirname -- "$rel")" || fail "freeze_mkdir rel=$rel"
    cp -p -- "$SRC_ROOT/$rel" "$FREEZE/$rel" || fail "freeze_copy rel=$rel"
    chmod 444 -- "$FREEZE/$rel" || fail "freeze_chmod rel=$rel"
    verify_copy_equal "$SRC_ROOT/$rel" "$FREEZE/$rel" "freeze rel=$rel" || fail "freeze_copy_check rel=$rel ${HASH_ERR}"
    FREEZE_PROD_PATHS+=( "$FREEZE/$rel" )
done
mkdir -p -- "$FREEZE/sim/functional" "$FREEZE/scripts" || fail "freeze_mkdir_aux"
cp -p -- "$TB_SRC" "$FREEZE/sim/functional/tb_frontend_faults.sv" || fail "freeze_tb_copy"
cp -p -- "$WRAP_SRC" "$FREEZE/sim/functional/test_frontend_faults.sh" || fail "freeze_wrap_copy"
cp -p -- "$DRV_SRC"  "$FREEZE/sim/functional/test_frontend_faults_driver.sh" || fail "freeze_drv_copy"
cp -p -- "$ENV_SRC"  "$FREEZE/scripts/env.sh" || fail "freeze_env_copy"
FREEZE_PROD_PATHS+=( "$FREEZE/sim/functional/tb_frontend_faults.sv" )
FREEZE_PKG_PATHS=( "$FREEZE/sim/functional/test_frontend_faults.sh"
                   "$FREEZE/sim/functional/test_frontend_faults_driver.sh"
                   "$FREEZE/scripts/env.sh" )
chmod 444 -- "${FREEZE_PKG_PATHS[@]}" || fail "freeze_pkg_chmod"
[ "${#FREEZE_PROD_PATHS[@]}" -eq "$PROD_N" ] || fail "freeze_prod_count=${#FREEZE_PROD_PATHS[@]}"
[ "${#FREEZE_PKG_PATHS[@]}" -eq "$PKG_N" ] || fail "freeze_pkg_count=${#FREEZE_PKG_PATHS[@]}"

#   fixtures/generator 也进同一冻结（不再读活路径）
mkdir -p -- "$FREEZE/sim/functional/fixtures" "$FREEZE/sim/unit/prog" || fail "freeze_fixture_mkdir"
cp -a -- "$FIXTURES_ROOT/." "$FREEZE/sim/functional/fixtures/" || fail "freeze_fixture_copy"
cp -p -- "$GEN_SRC" "$FREEZE/sim/unit/prog/gen_front4_int_data.py" || fail "freeze_generator_copy"
chmod -R a-w -- "$FREEZE/sim/functional/fixtures" "$FREEZE/sim/unit/prog" || fail "freeze_fixture_chmod"
FREEZE_FIXTURE_PATHS=( "$FREEZE/sim/functional/fixtures/frontend_hist_345/tb_frontend_faults.sv"
                        "$FREEZE/sim/functional/fixtures/frontend_hist_201/tb_frontend_faults.sv"
                        "$FREEZE/sim/functional/fixtures/frontend_hist_183/tb_frontend_faults.sv"
                        "$FREEZE/sim/functional/fixtures/frontend_hist_a295/revert_a295.patch"
                        "$FREEZE/sim/unit/prog/gen_front4_int_data.py" )
FIXTURE_PATHS=( "${FREEZE_FIXTURE_PATHS[@]}" )
fixture_check
EXPECT_PATHS=( "${FREEZE_FIXTURE_PATHS[@]}" ); EXPECT_N=5
sha_list "${FREEZE_FIXTURE_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_fixture_sha_rc=$SHA_LIST_RC"
FRZ_FIX_PRE="$SHA_LIST_OUT"; validate_block "$FRZ_FIX_PRE" "freeze_fixture_sha_pre"
FRZ_HIST345="${FREEZE_FIXTURE_PATHS[0]}"
FRZ_HIST201="${FREEZE_FIXTURE_PATHS[1]}"
FRZ_HIST183="${FREEZE_FIXTURE_PATHS[2]}"
FRZ_A295_PATCH="${FREEZE_FIXTURE_PATHS[3]}"
FRZ_GEN="${FREEZE_FIXTURE_PATHS[4]}"
FREEZE_ALL_PATHS=( "${FREEZE_PROD_PATHS[@]}" "${FREEZE_PKG_PATHS[@]}" "${FREEZE_FIXTURE_PATHS[@]}" )
EXPECT_PATHS=( "${FREEZE_ALL_PATHS[@]}" ); EXPECT_N=$SRC_ALL_N
sha_list "${FREEZE_ALL_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_all_sha_rc=$SHA_LIST_RC"
FREEZE_ALL_PRE="$SHA_LIST_OUT"; validate_block "$FREEZE_ALL_PRE" "freeze_all_sha_pre"
SRC_HASHES="$(printf '%s\n' "$SRC_ALL_PRE" | awk '{print $1}')"
FRZ_HASHES="$(printf '%s\n' "$FREEZE_ALL_PRE" | awk '{print $1}')"
[ "$SRC_HASHES" = "$FRZ_HASHES" ] || fail "freeze_copy_identity_mismatch"
{
    echo "-- freeze manifest (24 files; byte identity vs pre-copy) --"
    printf '%s\n' "$FREEZE_ALL_PRE"
} >> "$LOG"

EXPECT_PATHS=( "${FREEZE_PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
sha_list "${FREEZE_PROD_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_prod_sha_rc=$SHA_LIST_RC"
FRZ_PROD_PRE="$SHA_LIST_OUT"; validate_block "$FRZ_PROD_PRE" "freeze_prod_sha"
EXPECT_PATHS=( "${FREEZE_PKG_PATHS[@]}" ); EXPECT_N=$PKG_N
sha_list "${FREEZE_PKG_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_pkg_sha_rc=$SHA_LIST_RC"
FRZ_PKG_PRE="$SHA_LIST_OUT"; validate_block "$FRZ_PKG_PRE" "freeze_pkg_sha"
EXPECT_PATHS=( "$FREEZE/scripts/env.sh" ); EXPECT_N=1
sha_list "$FREEZE/scripts/env.sh"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_env_sha_rc=$SHA_LIST_RC"
FRZ_ENV_PRE="$SHA_LIST_OUT"; validate_block "$FRZ_ENV_PRE" "freeze_env_sha"
{
    echo "-- freeze product (16 = 12 RTL + 3 header + TB) --"; printf '%s\n' "$FRZ_PROD_PRE"
    echo "-- freeze package (wrapper + driver + env) --"; printf '%s\n' "$FRZ_PKG_PRE"
} >> "$LOG"

check_freeze_unchanged() {  # <phase>
    local phase="$1"
    EXPECT_PATHS=( "${FREEZE_PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
    sha_list "${FREEZE_PROD_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_prod_sha_${phase}_rc=$SHA_LIST_RC"
    validate_block "$SHA_LIST_OUT" "freeze_prod_sha_${phase}"
    [ "$SHA_LIST_OUT" = "$FRZ_PROD_PRE" ] || fail "freeze_prod_changed_phase=$phase"
    EXPECT_PATHS=( "${FREEZE_PKG_PATHS[@]}" ); EXPECT_N=$PKG_N
    sha_list "${FREEZE_PKG_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_pkg_sha_${phase}_rc=$SHA_LIST_RC"
    validate_block "$SHA_LIST_OUT" "freeze_pkg_sha_${phase}"
    [ "$SHA_LIST_OUT" = "$FRZ_PKG_PRE" ] || fail "freeze_pkg_changed_phase=$phase"
    EXPECT_PATHS=( "$FREEZE/scripts/env.sh" ); EXPECT_N=1
    sha_list "$FREEZE/scripts/env.sh"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_env_sha_${phase}_rc=$SHA_LIST_RC"
    [ "$SHA_LIST_OUT" = "$FRZ_ENV_PRE" ] || fail "freeze_env_changed_phase=$phase"
    EXPECT_PATHS=( "${FREEZE_FIXTURE_PATHS[@]}" ); EXPECT_N=5
    sha_list "${FREEZE_FIXTURE_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "freeze_fixture_sha_${phase}_rc=$SHA_LIST_RC"
    validate_block "$SHA_LIST_OUT" "freeze_fixture_sha_${phase}"
    [ "$SHA_LIST_OUT" = "$FRZ_FIX_PRE" ] || fail "freeze_fixture_changed_phase=$phase"
    fixture_check
}
check_freeze_unchanged freeze

#------------------------------------------------------------------------------
# 3b. 当前源根（实际产品 + 包）前后不变：driver 结束前再逐字节复核（防"冻结后活树变"）
#------------------------------------------------------------------------------
SRC_PROD_PATHS=()
for rel in "${PROD_REL[@]}"; do SRC_PROD_PATHS+=( "$SRC_ROOT/$rel" ); done
SRC_PROD_PATHS+=( "$TB_SRC" )
SRC_PKG_PATHS=( "$WRAP_SRC" "$DRV_SRC" "$ENV_SRC"
                "$HIST345_FIXTURE" "$HIST201_FIXTURE" "$HIST183_FIXTURE"
                "$A295_PATCH" "$GEN_SRC" )
SRC_AUX_N=8
EXPECT_PATHS=( "${SRC_PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
sha_list "${SRC_PROD_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "src_prod_sha_rc=$SHA_LIST_RC"
SRC_PROD_PRE="$SHA_LIST_OUT"; validate_block "$SRC_PROD_PRE" "src_prod_sha_pre"
EXPECT_PATHS=( "${SRC_PKG_PATHS[@]}" ); EXPECT_N=$SRC_AUX_N
sha_list "${SRC_PKG_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "src_pkg_sha_rc=$SHA_LIST_RC"
SRC_PKG_PRE="$SHA_LIST_OUT"; validate_block "$SRC_PKG_PRE" "src_pkg_sha_pre"

check_source_root_unchanged() {
    EXPECT_PATHS=( "${SRC_PROD_PATHS[@]}" ); EXPECT_N=$PROD_N
    sha_list "${SRC_PROD_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "src_prod_post_sha_rc=$SHA_LIST_RC"
    validate_block "$SHA_LIST_OUT" "src_prod_sha_post"
    [ "$SHA_LIST_OUT" = "$SRC_PROD_PRE" ] || fail "source_root_product_changed_during_run"
    EXPECT_PATHS=( "${SRC_PKG_PATHS[@]}" ); EXPECT_N=$SRC_AUX_N
    sha_list "${SRC_PKG_PATHS[@]}"; [ "$SHA_LIST_RC" -eq 0 ] || fail "src_pkg_post_sha_rc=$SHA_LIST_RC"
    validate_block "$SHA_LIST_OUT" "src_pkg_sha_post"
    [ "$SHA_LIST_OUT" = "$SRC_PKG_PRE" ] || fail "source_root_package_changed_during_run"
}

#------------------------------------------------------------------------------
# 4. mini 只从冻结派生 + 逐文件复核
#------------------------------------------------------------------------------
make_mini() {  # <dir>
    local d="$1" rel
    mkdir -p -- "$d" "$d/rtl" || fail "mini_mkdir dir=$d"
    cp -a -- "$FREEZE/rtl/." "$d/rtl/" || fail "mini_rtl_copy dir=$d"
    mkdir -p -- "$d/sim/functional" "$d/scripts" "$d/build/functional" || fail "mini_mkdir_aux dir=$d"
    cp -p -- "$FREEZE/sim/functional/tb_frontend_faults.sv" "$d/sim/functional/" || fail "mini_tb_copy dir=$d"
    cp -p -- "$FREEZE/sim/functional/test_frontend_faults.sh" "$d/sim/functional/" || fail "mini_wrap_copy dir=$d"
    cp -p -- "$FREEZE/sim/functional/test_frontend_faults_driver.sh" "$d/sim/functional/" || fail "mini_drv_copy dir=$d"
    cp -p -- "$FREEZE/scripts/env.sh" "$d/scripts/env.sh" || fail "mini_env_copy dir=$d"
    mkdir -p -- "$d/sim/functional/fixtures" "$d/sim/unit/prog" || fail "mini_fixture_mkdir dir=$d"
    cp -a -- "$FREEZE/sim/functional/fixtures/." "$d/sim/functional/fixtures/" || fail "mini_fixture_copy dir=$d"
    cp -p -- "$FREEZE/sim/unit/prog/gen_front4_int_data.py" "$d/sim/unit/prog/" || fail "mini_generator_copy dir=$d"
    chmod -R u+w -- "$d" || fail "mini_chmod dir=$d"
    for rel in "${PROD_REL[@]}"; do
        verify_copy_equal "$FREEZE/$rel" "$d/$rel" "mini_prod dir=$d rel=$rel" \
            || fail "mini_drift dir=$d rel=$rel ${HASH_ERR}"
    done
    verify_copy_equal "$FREEZE/sim/functional/tb_frontend_faults.sv" \
        "$d/sim/functional/tb_frontend_faults.sv" "mini_tb dir=$d" || fail "mini_tb_drift dir=$d ${HASH_ERR}"
    verify_copy_equal "$FREEZE/sim/functional/test_frontend_faults.sh" \
        "$d/sim/functional/test_frontend_faults.sh" "mini_wrap dir=$d" || fail "mini_wrap_drift dir=$d ${HASH_ERR}"
    verify_copy_equal "$FREEZE/sim/functional/test_frontend_faults_driver.sh" \
        "$d/sim/functional/test_frontend_faults_driver.sh" "mini_drv dir=$d" || fail "mini_driver_drift dir=$d ${HASH_ERR}"
    verify_copy_equal "$FREEZE/scripts/env.sh" "$d/scripts/env.sh" "mini_env dir=$d" \
        || fail "mini_env_drift dir=$d ${HASH_ERR}"
    for f in "${FREEZE_FIXTURE_PATHS[@]}"; do
        rel="${f#${FREEZE}/}"
        verify_copy_equal "$f" "$d/$rel" "mini_fixture dir=$d rel=$rel" \
            || fail "mini_fixture_drift dir=$d rel=$rel ${HASH_ERR}"
    done
}

run_pkg() {  # <mini> <log> [VAR=VAL...]
    local d="$1" log="$2"; shift 2
    (
        cd -- "$d" || exit 1
        env -u RV32_FUNCTIONAL_PKG_OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u OUT_DIR \
            "$@" RV32_FUNCTIONAL_PKG_OUT_DIR="$d/build/functional" DUT_ROOT="$d" \
            bash "$d/sim/functional/test_frontend_faults.sh"
    ) > "$log" 2>&1
}
#   统一 recursive helper：普通子 call 一律 mini driver + 显式 mini source/fixture +
#   mini 私有 PKGOUT；mode=default 仅用于 P0（-u source，测 mini 默认），FX 仍绑 mini。
run_child_driver() {  # <default|explicit> <mini-repo> <log> [extra env assignments...]
    local mode="$1" repo="$2" log="$3"; shift 3
    local pkg
    pkg="$(mktemp -d -- "$repo/build/functional/child-XXXXXXXX")" || fail "child_pkgout_mktemp repo=$repo"
    local -a srcarg=()
    if [ "$mode" = "default" ]; then
        srcarg=( -u FRONTEND_FAULTS_SRC_ROOT )
    else
        srcarg=( FRONTEND_FAULTS_SRC_ROOT="$repo" )
    fi
    (
        cd -- "$W" || exit 1
        env -u OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u RV32_FUNCTIONAL_PKG_OUT_DIR \
            "${srcarg[@]}" RV32_FUNCTIONAL_PKG_OUT_DIR="$pkg" \
            FRONTEND_FAULTS_FIXTURES_ROOT="$repo/sim/functional/fixtures" \
            FF_DRIVER_LEAF=1 "$@" \
            bash "$repo/sim/functional/test_frontend_faults_driver.sh"
    ) > "$log" 2>&1
}
count_anchor() { grep -cxF 'FUNCTIONAL_FRONTEND_FAULTS: PASS' "$1" 2>/dev/null || true; }
pkg_summary_field() {  # <log> <field>
    awk -v k="$2" '{
        for (i = 1; i <= NF; i++) {
            split($i, a, "=")
            if (a[1] == k) { print a[2]; exit }
        }
    }' "$1" | head -1
}
pkg_run_log() {  # <mini>
    ls -1d -- "$1"/build/functional/run-*/ 2>/dev/null | tail -1
}

assert_case() {  # <name> <rc> <log> <want_rc> <want_reason> <want_pass>
    local name="$1" rc="$2" log="$3" wrc="$4" wreason="$5" wpass="$6" ok=1 na
    [ "$rc" -eq "$wrc" ] || ok=0
    if [ -n "$wreason" ]; then
        grep -q "reason=$wreason" "$log" 2>/dev/null || ok=0
        # 精确原因：恰好一条 FAIL reason 行，不能"先因后因"混过
        [ "$(grep -cE 'FUNCTIONAL_FRONTEND_FAULTS(:|_DRIVER:) FAIL reason=' "$log" 2>/dev/null || true)" = "1" ] || ok=0
    else
        grep -q 'FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=' "$log" 2>/dev/null && ok=0
    fi
    na="$(count_anchor "$log")"
    [ "$na" = "$wpass" ] || ok=0
    if [ "$ok" -eq 1 ]; then sub_ok "$name"; else
        sub_fail "$name" "rc=$rc want=$wrc reason=$wreason pass=$na want_pass=$wpass"
    fi
}

#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# 5. P1 正控（当前产品）
#------------------------------------------------------------------------------
check_baseline_commit() {
    [ -d "$BASELINE_REPO" ] || fail "baseline_repo_missing path=$BASELINE_REPO"
    git -C "$BASELINE_REPO" cat-file -e "${BASE_COMMIT}^{commit}" 2>>"$LOG" \
        || fail "baseline_commit_missing commit=$BASE_COMMIT"
}
check_baseline_commit
if [ "$LEAF" = "1" ]; then
    M="$W/mini_leaf"
    make_mini "$M"
    run_pkg "$M" "$W/leaf_p1.log"
    RC=$?
    assert_case leaf_parent_pkgout "$RC" "$W/leaf_p1.log" 0 "" 1
    [ "$(pkg_summary_field "$W/leaf_p1.log" checks)" = "$SPEC_CUR_CHECKS" ] || sub_fail leaf_checks "got=$(pkg_summary_field "$W/leaf_p1.log" checks)"
    check_freeze_unchanged leaf
    printf 'FRONTEND_DRIVER_TESTS total=%s failed=%s work_dir=%s\n' "$NT" "$NG" "$W"
    [ "$NG" -eq 0 ] || { printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=subtests_failed count=%s work_dir=%s\n' "$NG" "$W"; exit 1; }
    printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS\n'
    exit 0
fi

# 4b. P0 默认 SRC_ROOT（不设 FRONTEND_FAULTS_SRC_ROOT）+ 合法父 PKGOUT 正控
#     在“clean-checkout 形状”的 mini 仓库里跑它自己的 driver：默认 SRC_ROOT=该 mini，
#     产品/TB 来自同一冻结；fixtures 一并入库式复制；git 基线只借用真实 git 仓库身份。
#------------------------------------------------------------------------------
P0DIR="$W/self-parent-default"; mkdir -p "$P0DIR"
P0REPO="$P0DIR/repo"
make_mini "$P0REPO"
mkdir -p "$P0REPO/sim/functional/fixtures"
cp -a -- "$FREEZE/sim/functional/fixtures/." "$P0REPO/sim/functional/fixtures/" || fail "p0_fixture_copy_failed"
mkdir -p -- "$P0REPO/sim/unit/prog" || fail "p0_generator_mkdir_failed"
cp -p -- "$FRZ_GEN" "$P0REPO/sim/unit/prog/gen_front4_int_data.py" || fail "p0_generator_copy_failed"
P0OUT="$P0REPO/build/functional/parent-out"; mkdir -p "$P0OUT"
run_child_driver default "$P0REPO" "$W/p0_default_parent.log" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P0OUT" FRONTEND_FAULTS_BASELINE_REPO="$BASELINE_REPO"; CHR=$?
if [ "$CHR" -eq 0 ] && grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/p0_default_parent.log" \
   && grep -q '^FRONTEND_DRIVER_TESTS total=1 failed=0' "$W/p0_default_parent.log"; then
    sub_ok P0_default_src_parent_pkgout
else
    sub_fail P0_default_src_parent_pkgout "child_rc=$CHR expect=0 default SRC_ROOT"
fi

P1="$W/mini_p1"; make_mini "$P1"
run_pkg "$P1" "$W/p1.log"; RC=$?
assert_case P1_positive "$RC" "$W/p1.log" 0 "" 1
if [ "$RC" -eq 0 ]; then
    [ "$(pkg_summary_field "$W/p1.log" checks)" = "$SPEC_CUR_CHECKS" ] || sub_fail P1_checks "got=$(pkg_summary_field "$W/p1.log" checks)"
    [ "$(pkg_summary_field "$W/p1.log" fails)" = "0" ] || sub_fail P1_fails "got=$(pkg_summary_field "$W/p1.log" fails)"
    [ "$(pkg_summary_field "$W/p1.log" wide_blocks)" = "$SPEC_CUR_WIDE" ] || sub_fail P1_wide "got=$(pkg_summary_field "$W/p1.log" wide_blocks)"
    RLOG="$(ls -1t "$P1"/build/functional/run-*/test_frontend_faults.log 2>/dev/null | head -1)"
    if [ -n "$RLOG" ]; then
        grep -q -- '-- compile cwd/snapshot: ' "$RLOG" || sub_fail P1_compile_root "missing compile cwd marker"
        grep -q -- "/dut-snapshot$" <(grep -- '-- compile cwd/snapshot: ' "$RLOG") \
            || sub_fail P1_compile_snapshot "compile root is not run-private snapshot"
        grep -q -- 'COMPILE_CMD = ' "$RLOG" || sub_fail P1_compile_cmd "missing compile command"
    else
        sub_fail P1_runlog "missing run log"
    fi
fi
check_freeze_unchanged p1

#------------------------------------------------------------------------------
# 6. P2 隔离（同 mini 两次不同 run 目录）
#------------------------------------------------------------------------------
P2="$W/mini_p2"; make_mini "$P2"
run_pkg "$P2" "$W/p2a.log"; RA=$?
run_pkg "$P2" "$W/p2b.log"; RB=$?
assert_case P2_isolation_a "$RA" "$W/p2a.log" 0 "" 1
assert_case P2_isolation_b "$RB" "$W/p2b.log" 0 "" 1
mapfile -t RDIRS < <(ls -1d -- "$P2"/build/functional/run-*/ 2>/dev/null)
[ "${#RDIRS[@]}" -ge 2 ] && [ "${RDIRS[0]}" != "${RDIRS[1]}" ] \
    && sub_ok P2_distinct_rundirs || sub_fail P2_distinct_rundirs "n=${#RDIRS[@]}"
P2_OUT_OF_ROOT=0
for rd in "${RDIRS[@]}"; do
    case "$rd" in "$P2"/build/functional/run-*) : ;; *) P2_OUT_OF_ROOT=1 ;; esac
done
[ "$P2_OUT_OF_ROOT" -eq 0 ] && sub_ok P2_own_pkgout || sub_fail P2_own_pkgout "run dir outside mini PKGOUT"
check_freeze_unchanged p2

#------------------------------------------------------------------------------
# 7. P3 父 PKGOUT（合法正控 + 非法两优先级；全部用 freeze 派生 mini driver）
#------------------------------------------------------------------------------
P3REPO="$W/mini_p3_repo"; make_mini "$P3REPO"
P3BASE="$P3REPO/build/functional/parent-out"; mkdir -p "$P3BASE"
# 合法控制：父显式 source=mini、fixture=mini（helper 统一绑定）
run_child_driver explicit "$P3REPO" "$W/p3_child.log" RV32_FUNCTIONAL_PKG_OUT_DIR="$P3BASE"; CHR=$?
if [ "$CHR" -eq 0 ] && grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/p3_child.log" \
   && grep -q '^FRONTEND_DRIVER_TESTS total=1 failed=0' "$W/p3_child.log"; then
    sub_ok P3_parent_pkgout_positive
else
    sub_fail P3_parent_pkgout_positive "child_rc=$CHR expect=0"
fi
# 显式 parent source+fixture 合法控制（仍必须用 mini，不读 live）
( export FRONTEND_FAULTS_SRC_ROOT="$REPO_ROOT" \
         FRONTEND_FAULTS_FIXTURES_ROOT="$REPO_ROOT/sim/functional/fixtures"
  run_child_driver explicit "$P3REPO" "$W/p3_child_explicit.log" \
      RV32_FUNCTIONAL_PKG_OUT_DIR="$P3BASE/explicit" )
CHR=$?
if [ "$CHR" -eq 0 ] && grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/p3_child_explicit.log"; then
    sub_ok P3_parent_explicit_roots
else
    sub_fail P3_parent_explicit_roots "child_rc=$CHR expect=0"
fi
# 冻结隔离：坏 mini 源/驱动在“父显式正确 source+fixture”环境下仍必须红，恢复后绿
P3_IF="$P3REPO/rtl/front4/ifetch4.v"
P3_DRV="$P3REPO/sim/functional/test_frontend_faults_driver.sh"
cp -p -- "$P3_IF" "$W/p3_ifetch_save" || fail "p3_save_ifetch"
printf '\nthis is not verilog for p3 isolation\n' >> "$P3_IF" || fail "p3_mut_ifetch"
( export FRONTEND_FAULTS_SRC_ROOT="$REPO_ROOT" \
         FRONTEND_FAULTS_FIXTURES_ROOT="$REPO_ROOT/sim/functional/fixtures"
  run_child_driver explicit "$P3REPO" "$W/p3_child_brokensrc.log" \
      RV32_FUNCTIONAL_PKG_OUT_DIR="$P3BASE/broken-src" )
CHR=$?
[ "$CHR" -ne 0 ] && ! grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/p3_child_brokensrc.log" \
    && sub_ok P3_child_broken_source_red || sub_fail P3_child_broken_source_red "child_rc=$CHR expected fail"
cp -p -- "$W/p3_ifetch_save" "$P3_IF" || fail "p3_restore_ifetch"
cp -p -- "$P3_DRV" "$W/p3_driver_save" || fail "p3_save_driver"
sed -i '2i exit 9' "$P3_DRV" || fail "p3_mut_driver"
( export FRONTEND_FAULTS_SRC_ROOT="$REPO_ROOT" \
         FRONTEND_FAULTS_FIXTURES_ROOT="$REPO_ROOT/sim/functional/fixtures"
  run_child_driver explicit "$P3REPO" "$W/p3_child_brokendrv.log" \
      RV32_FUNCTIONAL_PKG_OUT_DIR="$P3BASE/broken-drv" )
CHR=$?
[ "$CHR" -ne 0 ] && ! grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/p3_child_brokendrv.log" \
    && sub_ok P3_child_broken_driver_red || sub_fail P3_child_broken_driver_red "child_rc=$CHR expected fail"
cp -p -- "$W/p3_driver_save" "$P3_DRV" || fail "p3_restore_driver"
( export FRONTEND_FAULTS_SRC_ROOT="$REPO_ROOT" \
         FRONTEND_FAULTS_FIXTURES_ROOT="$REPO_ROOT/sim/functional/fixtures"
  run_child_driver explicit "$P3REPO" "$W/p3_child_restored.log" \
      RV32_FUNCTIONAL_PKG_OUT_DIR="$P3BASE/restored" )
CHR=$?
if [ "$CHR" -eq 0 ] && grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/p3_child_restored.log"; then
    sub_ok P3_child_restored_green
else
    sub_fail P3_child_restored_green "child_rc=$CHR expect=0"
fi
check_freeze_unchanged p3_iso

# 父非法：source/fixture 仍显式 mini；父 PKGOUT 非法必须优先拒
run_child_driver explicit "$P3REPO" "$W/p3_bad1.log" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$REPO_ROOT/build/not-authorized-frontend"; CHR=$?
assert_case P3_parent_illegal "$CHR" "$W/p3_bad1.log" 1 "parent_pkgout_unauthorized" 0
run_child_driver explicit "$P3REPO" "$W/p3_bad2.log" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$REPO_ROOT/build/not-authorized-frontend" \
    OUT_DIR="$P1/build/functional" RV32_FUNCTIONAL_OUT_DIR="$P1/build/functional"; CHR=$?
assert_case P3_parent_priority "$CHR" "$W/p3_bad2.log" 1 "parent_pkgout_unauthorized" 0
check_freeze_unchanged p3

# 8. P4 Poison-cwd：完整编译命令先证毒，再证包装器用私有快照
#------------------------------------------------------------------------------
POISON="$W/poison_cwd"; mkdir -p "$POISON/rtl/pkg" "$POISON/rtl/front4"
printf 'this is not verilog\n`define RV32GC_PMP_ENTRIES broken\n' > "$POISON/rtl/pkg/rv32_defs.vh"
printf 'this is not verilog\n`define RV32GC_PMP_ENTRY_W broken\n' > "$POISON/rtl/pkg/core_params.vh"
printf 'this is not verilog\n`define FRONT4_LANES broken\n' > "$POISON/rtl/front4/front4_params.vh"
POISON_SRC=()
for rel in "${RTL_REL[@]}"; do POISON_SRC+=( "$P1/$rel" ); done
(
    cd -- "$POISON" || exit 1
    timeout "$TIMEOUT_COMPILE_S" "$REAL_IV" -g2012 -I "$POISON" -s tb_frontend_faults_top \
        -o "$POISON/poison.vvp" "$P1/sim/functional/tb_frontend_faults.sv" \
        "${POISON_SRC[@]}"
) > "$W/p4_poison_compile.log" 2>&1
PRC=$?
[ "$PRC" -ne 0 ] && sub_ok P4_poison_really_poisonous \
    || sub_fail P4_poison_really_poisonous "complete command unexpectedly compiled rc=0"
POISON_RUN="$W/p4_poison_wrap.log"
( cd -- "$POISON" && env -u RV32_FUNCTIONAL_PKG_OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u OUT_DIR \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional" DUT_ROOT="$P1" \
    bash "$P1/sim/functional/test_frontend_faults.sh" ) > "$POISON_RUN" 2>&1
PRC=$?
assert_case P4_poison_cwd_positive "$PRC" "$POISON_RUN" 0 "" 1
PRLOG="$(ls -1t "$P1"/build/functional/run-*/test_frontend_faults.log 2>/dev/null | head -1)"
if [ -n "$PRLOG" ]; then
    CROOT="$(sed -n 's/^-- compile cwd\/snapshot: //p' "$PRLOG" | head -1)"
    case "$CROOT" in
        */run-*/dut-snapshot) sub_ok P4_compile_snapshot_private ;;
        *) sub_fail P4_compile_snapshot_private "got=${CROOT:-empty}" ;;
    esac
    grep -qF "$POISON" "$PRLOG" && sub_fail P4_no_poison_path_in_log "poison path leaked" \
        || sub_ok P4_no_poison_path_in_log
    grep -q -- 'COMPILE_CMD = .* -I ' "$PRLOG" && sub_ok P4_compile_include_present \
        || sub_fail P4_compile_include_present "no -I in compile cmd"
else
    sub_fail P4_compile_snapshot_private "missing run log"
fi
#   合法包正控也可在毒 cwd **之外**启动（同一冻结 mini、显式 PKGOUT）⇒ 必须 PASS
( cd -- "$W" && env -u RV32_FUNCTIONAL_PKG_OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u OUT_DIR \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional" DUT_ROOT="$P1" \
    bash "$P1/sim/functional/test_frontend_faults.sh" ) > "$W/p4_outside.log" 2>&1
PRC=$?
assert_case P4_legal_cwd_outside "$PRC" "$W/p4_outside.log" 0 "" 1
check_freeze_unchanged p4

#------------------------------------------------------------------------------
# 9. P5 183 历史表（**当前 345 产品 + 入库 183 TB fixture**；非历史 RTL 复跑）
#------------------------------------------------------------------------------
P5="$W/mini_p5_183"; make_mini "$P5"
cp -p -- "$FRZ_HIST183" "$P5/sim/functional/tb_frontend_faults.sv" || fail "hist183_fixture_copy_failed"
run_pkg "$P5" "$W/p5.log"; RC=$?
assert_case P5_legacy_183 "$RC" "$W/p5.log" 0 "" 1
[ "$(pkg_summary_field "$W/p5.log" checks)" = "$SPEC_LEGACY_CHECKS" ] && sub_ok P5_checks_183 \
    || sub_fail P5_checks_183 "got=$(pkg_summary_field "$W/p5.log" checks)"
[ "$(pkg_summary_field "$W/p5.log" wide_blocks)" = "$SPEC_LEGACY_WIDE" ] && sub_ok P5_wide_12 \
    || sub_fail P5_wide_12 "got=$(pkg_summary_field "$W/p5.log" wide_blocks)"
P5RUN="$(ls -1t "$P5"/build/functional/run-*/test_frontend_faults.log 2>/dev/null | head -1)"
grep -q 'SPEC_ID         = f4faults-r0-183' "$P5RUN" 2>/dev/null \
    && sub_ok P5_version_bound_spec || sub_fail P5_version_bound_spec "spec id not r0-183"
check_freeze_unchanged p5

#------------------------------------------------------------------------------
# 9a. P5a 345 历史表（当前 455 产品 + 入库 345 TB fixture；版本绑定控制）
#------------------------------------------------------------------------------
P5A="$W/mini_p5a_345"; make_mini "$P5A"
cp -p -- "$FRZ_HIST345" "$P5A/sim/functional/tb_frontend_faults.sv" || fail "hist345_fixture_copy_failed"
run_pkg "$P5A" "$W/p5a.log"; RC=$?
assert_case P5a_hist345_control "$RC" "$W/p5a.log" 0 "" 1
[ "$(pkg_summary_field "$W/p5a.log" checks)" = "$SPEC_HIST345_CHECKS" ] && sub_ok P5a_checks_345 \
    || sub_fail P5a_checks_345 "got=$(pkg_summary_field "$W/p5a.log" checks)"
[ "$(pkg_summary_field "$W/p5a.log" wide_blocks)" = "$SPEC_HIST345_WIDE" ] && sub_ok P5a_wide_12 \
    || sub_fail P5a_wide_12 "got=$(pkg_summary_field "$W/p5a.log" wide_blocks)"
P5ARUN="$(ls -1t "$P5A"/build/functional/run-*/test_frontend_faults.log 2>/dev/null | head -1)"
grep -q 'SPEC_ID         = f4faults-hist-345' "$P5ARUN" 2>/dev/null \
    && sub_ok P5a_version_bound_spec || sub_fail P5a_version_bound_spec "spec id not hist-345"
check_freeze_unchanged p5a

#------------------------------------------------------------------------------
# 9b. P6 201 历史表（**当前 345 产品 + 入库 201 TB fixture**；版本绑定控制）
#------------------------------------------------------------------------------
P6="$W/mini_p6_201"; make_mini "$P6"
cp -p -- "$FRZ_HIST201" "$P6/sim/functional/tb_frontend_faults.sv" || fail "hist201_fixture_copy_failed"
run_pkg "$P6" "$W/p6.log"; RC=$?
assert_case P6_hist201_control "$RC" "$W/p6.log" 0 "" 1
[ "$(pkg_summary_field "$W/p6.log" checks)" = "$SPEC_HIST201_CHECKS" ] && sub_ok P6_checks_201 \
    || sub_fail P6_checks_201 "got=$(pkg_summary_field "$W/p6.log" checks)"
[ "$(pkg_summary_field "$W/p6.log" wide_blocks)" = "$SPEC_HIST201_WIDE" ] && sub_ok P6_wide_12 \
    || sub_fail P6_wide_12 "got=$(pkg_summary_field "$W/p6.log" wide_blocks)"
P6RUN="$(ls -1t "$P6"/build/functional/run-*/test_frontend_faults.log 2>/dev/null | head -1)"
grep -q 'SPEC_ID         = f4faults-hist-201' "$P6RUN" 2>/dev/null \
    && sub_ok P6_version_bound_spec || sub_fail P6_version_bound_spec "spec id not hist-201"
check_freeze_unchanged p6

#------------------------------------------------------------------------------
# 9c. P7 fixture 负控：缺 / 改一字节必须精确拒（不 SKIP/不 fallback）
#------------------------------------------------------------------------------
FXMISS="$W/fixtures_missing"; mkdir -p "$FXMISS"
cp -a -- "$FREEZE/sim/functional/fixtures/." "$FXMISS/" || fail "fixture_neg_copy_missing"
chmod -R u+w -- "$FXMISS" || fail "fixture_neg_chmod_missing"
rm -f -- "$FXMISS/frontend_hist_183/tb_frontend_faults.sv" || fail "fixture_neg_rm_missing"
run_child_driver explicit "$P5" "$W/p7_missing.log" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P5/build/functional/fixneg-parent-missing" \
    FRONTEND_FAULTS_FIXTURES_ROOT="$FXMISS"; CHR=$?
assert_case P7_fixture_missing "$CHR" "$W/p7_missing.log" 1 "src_manifest_missing" 0

FXBAD="$W/fixtures_bad"; mkdir -p "$FXBAD"
cp -a -- "$FREEZE/sim/functional/fixtures/." "$FXBAD/" || fail "fixture_neg_copy_bad"
chmod -R u+w -- "$FXBAD" || fail "fixture_neg_chmod_bad"
printf '\n// fixture mutation during negative test\n' >> "$FXBAD/frontend_hist_201/tb_frontend_faults.sv" \
    || fail "fixture_neg_mutate"
run_child_driver explicit "$P5" "$W/p7_modified.log" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P5/build/functional/fixneg-parent-bad" \
    FRONTEND_FAULTS_FIXTURES_ROOT="$FXBAD"; CHR=$?
assert_case P7_fixture_modified "$CHR" "$W/p7_modified.log" 1 "fixture_sha_mismatch" 0

#------------------------------------------------------------------------------
# 9d. P8 a295 精确 22 失败可复现（当前 455 产品 + in-tree Q2/faultmask 回退 patch）
#------------------------------------------------------------------------------
P8="$W/mini_p8_a295"; make_mini "$P8"
( cd "$P8" && patch -p0 --dry-run < "$FRZ_A295_PATCH" ) > "$W/p8_patch_dry.log" 2>&1
P8DRY=$?
( cd "$P8" && patch -p0 < "$FRZ_A295_PATCH" ) > "$W/p8_patch.log" 2>&1
P8PAT=$?
if [ "$P8DRY" -eq 0 ] && [ "$P8PAT" -eq 0 ]; then
    sub_ok P8_a295_patch_applied
else
    sub_fail P8_a295_patch_applied "dry=$P8DRY apply=$P8PAT"
fi
run_pkg "$P8" "$W/p8.log" FRONTEND_FAULTS_EXPECT=old345; RC=$?
assert_case P8_a295_exact22_red "$RC" "$W/p8.log" 1 "old_baseline_defects_confirmed" 0
[ "$(pkg_summary_field "$W/p8.log" checks)" = "$SPEC_REV345_CHECKS" ] && sub_ok P8_checks_455 \
    || sub_fail P8_checks_455 "got=$(pkg_summary_field "$W/p8.log" checks)"
[ "$(pkg_summary_field "$W/p8.log" fails)" = "$SPEC_REV345_FAILS" ] && sub_ok P8_fails_22 \
    || sub_fail P8_fails_22 "got=$(pkg_summary_field "$W/p8.log" fails)"
[ "$(pkg_summary_field "$W/p8.log" wide_blocks)" = "$SPEC_REV345_WIDE" ] && sub_ok P8_wide_12 \
    || sub_fail P8_wide_12 "got=$(pkg_summary_field "$W/p8.log" wide_blocks)"
P8RUN="$(ls -1t "$P8"/build/functional/run-*/test_frontend_faults.run.log 2>/dev/null | head -1)"
P8GOT="$(grep -o '^CHECK_FAIL([0-9]\+)' "$P8RUN" 2>/dev/null | sed 's/^CHECK_FAIL(//; s/)$//' | sort -n | tr '\n' ' ')"
P8GOT="${P8GOT% }"
P8WANT="$(printf '%s\n' $SPEC_REV345_FAIL_IDS | sort -n | tr '\n' ' ')"; P8WANT="${P8WANT% }"
[ "$P8GOT" = "$P8WANT" ] && sub_ok P8_fail_id_set \
    || sub_fail P8_fail_id_set "got=[$P8GOT]"
grep -q 'FUNCTIONAL_FRONTEND_FAULTS: PASS' "$W/p8.log" && sub_fail P8_no_pass "a295 patch printed PASS" \
    || sub_ok P8_no_pass
check_freeze_unchanged p8

#------------------------------------------------------------------------------
# 10. N12 旧基线：真实 201acf61 + 455 TB ⇒ 429/114/0 + 114 个固定 CHECK_FAIL 编号
#------------------------------------------------------------------------------
OLD="$W/old_rtl"
for rel in "${PROD_REL[@]}"; do
    mkdir -p -- "$OLD/$(dirname -- "$rel")" || fail "old_rtl_mkdir rel=$rel"
    git -C "$BASELINE_REPO" show "${BASE_COMMIT}:$rel" > "$OLD/$rel" 2>>"$LOG" \
        || fail "old_extract_failed rel=$rel"
    [ -s "$OLD/$rel" ] || fail "old_empty rel=$rel"
    chmod 444 -- "$OLD/$rel" || fail "old_chmod rel=$rel"
done
#   201acf61 真源身份图（跨 matrix 记录；仅 top/ifetch 允许被纯 shim 改）
declare -A OLD_SHA
for rel in "${PROD_REL[@]}"; do
    hash_one "$OLD/$rel" || fail "old_identity_hash rel=$rel ${HASH_ERR}"
    OLD_SHA["$rel"]="$HASH_OUT"
    note "OLD_SRC_MAP commit=$BASE_COMMIT path=$rel sha256=$HASH_OUT"
done
chmod u+w -- "$OLD/rtl/front4/front4_top.v" || fail "old_top_unlock"
python3 - "$OLD/rtl/front4/front4_top.v" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = "    input  wire        sv32_translate_fault,"
assert a in s, "shim anchor 1"
s = s.replace(a, a + "\n    input  wire        sv32_translate_fault_af,", 1)
b = "    input  wire        l1i_uncached,"
assert b in s, "shim anchor 2"
s = s.replace(b, b + "\n    input  wire        l1i_rsp_err,\n    input  wire [31:0] l1i_rsp_err_pa,", 1)
c = "    input  wire [31:0] unc_rsp_data,"
assert c in s, "shim anchor 3"
s = s.replace(c, c + "\n    input  wire        unc_rsp_err,", 1)
open(p, "w").write(s)
PY
grep -q 'sv32_translate_fault_af' "$OLD/rtl/front4/front4_top.v" || fail "old_shim_missing_a"
grep -q 'l1i_rsp_err_pa' "$OLD/rtl/front4/front4_top.v" || fail "old_shim_missing_b"
grep -q 'unc_rsp_err' "$OLD/rtl/front4/front4_top.v" || fail "old_shim_missing_c"
chmod 444 -- "$OLD/rtl/front4/front4_top.v"

#   旧 201 没有新 TB 直接探针的 held-block / 翻译故障锁存名；只加**结构观测线**
#   （不改旧逻辑、不改 gold）：blk_hold_q 恒 0；f3_tr_fault 仅按旧端口组合观测。
chmod u+w -- "$OLD/rtl/front4/ifetch4.v" || fail "old_ifetch_unlock"
python3 - "$OLD/rtl/front4/ifetch4.v" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert "blk_hold_q" not in s, "unexpected old blk_hold_q"
assert "f3_tr_fault" not in s, "unexpected old f3_tr_fault"
ins = """
    // ===== TEST-ONLY COMPAT (no old behavior change): new TB hierarchy probes =====
    wire blk_hold_q  = 1'b0;  // old 201 has no held-block snapshot
    wire f3_tr_fault = sv32_translate_en & f3_v_q & sv32_translate_fault;
"""
i = s.rfind("endmodule")
assert i > 0, "endmodule missing"
s = s[:i] + ins + "\n" + s[i:]
open(p, "w").write(s)
PY
grep -q 'TEST-ONLY COMPAT' "$OLD/rtl/front4/ifetch4.v" || fail "old_ifetch_compat_missing"
chmod 444 -- "$OLD/rtl/front4/ifetch4.v"
#   只允许 top/ifetch 两个 shim 文件变化；其余 13 个旧源必须逐字节不变。
SHIM_BAD=""
for rel in "${PROD_REL[@]}"; do
    hash_one "$OLD/$rel" || fail "old_identity_rehash rel=$rel ${HASH_ERR}"
    case "$rel" in
        rtl/front4/front4_top.v|rtl/front4/ifetch4.v)
            [ "$HASH_OUT" != "${OLD_SHA[$rel]}" ] || SHIM_BAD="$SHIM_BAD $rel:not-shimmed"
            ;;
        *)
            [ "$HASH_OUT" = "${OLD_SHA[$rel]}" ] || SHIM_BAD="$SHIM_BAD $rel:changed"
            ;;
    esac
done
[ -z "$SHIM_BAD" ] && sub_ok N12_shim_identity_only \
    || sub_fail N12_shim_identity_only "bad=$SHIM_BAD"

N12="$W/mini_n12_old"; make_mini "$N12"
for rel in "${PROD_REL[@]}"; do cp -p -- "$OLD/$rel" "$N12/$rel" || fail "n12_old_copy rel=$rel"; done
chmod -R u+w -- "$N12/rtl"
run_pkg "$N12" "$W/n12.log" FRONTEND_FAULTS_EXPECT=old; RC=$?
assert_case N12_old_baseline_red "$RC" "$W/n12.log" 1 "old_baseline_defects_confirmed" 0
[ "$(pkg_summary_field "$W/n12.log" checks)" = "$SPEC_OLD_CHECKS" ] && sub_ok N12_checks_429 \
    || sub_fail N12_checks_429 "got=$(pkg_summary_field "$W/n12.log" checks)"
[ "$(pkg_summary_field "$W/n12.log" fails)" = "$SPEC_OLD_FAILS" ] && sub_ok N12_fails_114 \
    || sub_fail N12_fails_114 "got=$(pkg_summary_field "$W/n12.log" fails)"
[ "$(pkg_summary_field "$W/n12.log" wide_blocks)" = "$SPEC_OLD_WIDE" ] && sub_ok N12_wide_0 \
    || sub_fail N12_wide_0 "got=$(pkg_summary_field "$W/n12.log" wide_blocks)"
N12RUN="$(ls -1t "$N12"/build/functional/run-*/test_frontend_faults.run.log 2>/dev/null | head -1)"
if [ -n "$N12RUN" ] && grep -q "^FRONTEND_FAULTS checks=$SPEC_OLD_CHECKS fails=$SPEC_OLD_FAILS wide_blocks=$SPEC_OLD_WIDE$" "$N12RUN" \
   && [ "$(grep -c '^CHECK_FAIL(' "$N12RUN" || true)" = "$SPEC_OLD_FAILS" ]; then
    sub_ok N12_real_functional_signature
else
    sub_fail N12_real_functional_signature "compile-only or wrong signature run=${N12RUN:-none}"
fi
WANT_IDS="$(printf '%s\n' $SPEC_OLD_FAIL_IDS | sort -n | tr '\n' ' ')"
WANT_IDS="${WANT_IDS% }"
GOT_IDS="$(grep -o '^CHECK_FAIL([0-9]\+)' "$N12RUN" 2>/dev/null | sed 's/^CHECK_FAIL(//; s/)$//' | sort -n | tr '\n' ' ')"
GOT_IDS="${GOT_IDS% }"
[ "$GOT_IDS" = "$WANT_IDS" ] && sub_ok N12_fail_id_set \
    || sub_fail N12_fail_id_set "got=[$GOT_IDS]"
for cid in $SPEC_OLD_CONTROL_IDS; do
    grep -q "^CHECK_FAIL($cid):" "$N12RUN" 2>/dev/null && { sub_fail N12_control_id "control $cid failed"; break; }
done
N12_NEW_MISSING=""
for nid in $SPEC_OLD_NEW_IDS; do
    grep -q "^CHECK_FAIL($nid):" "$N12RUN" 2>/dev/null || N12_NEW_MISSING="$N12_NEW_MISSING $nid"
done
[ -z "$N12_NEW_MISSING" ] && sub_ok N12_new_feature_ids \
    || sub_fail N12_new_feature_ids "new-feature failures missing ids=$N12_NEW_MISSING"
grep -q 'FUNCTIONAL_FRONTEND_FAULTS: PASS' "$W/n12.log" && sub_fail N12_no_pass "old baseline printed PASS" \
    || sub_ok N12_no_pass
# 缺 201 基线必须失败（不得 SKIP+ok）
run_child_driver explicit "$P5" "$W/n12_missing.log" \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P5/build/functional/n12-missing-parent" \
    FRONTEND_FAULTS_BASELINE_COMMIT=0000000000000000000000000000000000000000 \
    FRONTEND_FAULTS_BASELINE_REPO="$BASELINE_REPO"; CHR=$?
assert_case N12_missing_baseline_fails "$CHR" "$W/n12_missing.log" 1 "baseline_commit_missing" 0
check_freeze_unchanged n12

#------------------------------------------------------------------------------
# 11. W* 包装器 fail-closed（每例精确 reason + rc≠0 + 无 PASS）
#------------------------------------------------------------------------------
mk_case() { local d="$W/$1"; make_mini "$d"; printf '%s\n' "$d"; }
FAKE="$W/fake"; mkdir -p "$FAKE"
cat > "$FAKE/iv_noout.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/iv_err.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
cat > "$FAKE/vv_empty.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/vv_rc7.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
cat > "$FAKE/vv_slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
exit 0
EOF
cat > "$FAKE/vv_junk.sh" <<'EOF'
#!/usr/bin/env bash
echo "junk output without summary"
exit 0
EOF
chmod 755 "$FAKE"/*.sh

# W1 未知参数
( cd "$P1" && bash sim/functional/test_frontend_faults.sh --bogus ) > "$W/w1.log" 2>&1; RC=$?
assert_case W1_unknown_arg "$RC" "$W/w1.log" 1 "unknown_arg" 0

# W2 编译 rc=0 零 vvp
run_pkg "$P1" "$W/w2.log" RV32_IVERILOG="$FAKE/iv_noout.sh"; RC=$?
assert_case W2_no_vvp "$RC" "$W/w2.log" 1 "compile_no_vvp_output" 0

# W3 编译非零（真实坏 RTL，非假缺陷）
WBAD="$W/mini_badrtl"; make_mini "$WBAD"
printf 'module ifetch4; this is not verilog ; endmodule\n' > "$WBAD/rtl/front4/ifetch4.v"
run_pkg "$WBAD" "$W/w3.log"; RC=$?
assert_case W3_compile_rc "$RC" "$W/w3.log" 1 "compile_rc=" 0

# W4 运行 rc=7
run_pkg "$P1" "$W/w4.log" RV32_VVP="$FAKE/vv_rc7.sh"; RC=$?
assert_case W4_run_rc "$RC" "$W/w4.log" 1 "run_rc=7" 0

# W5 运行超时
run_pkg "$P1" "$W/w5.log" RV32_VVP="$FAKE/vv_slow.sh" TIMEOUT_RUN_S=1; RC=$?
assert_case W5_run_timeout "$RC" "$W/w5.log" 1 "run_timeout" 0

# W6 运行 rc=0 空输出
run_pkg "$P1" "$W/w6.log" RV32_VVP="$FAKE/vv_empty.sh"; RC=$?
assert_case W6_zero_output "$RC" "$W/w6.log" 1 "run_zero_output" 0

# W7 空/垃圾输出（无摘要）
run_pkg "$P1" "$W/w7.log" RV32_VVP="$FAKE/vv_junk.sh"; RC=$?
assert_case W7_no_summary "$RC" "$W/w7.log" 1 "summary_count=0" 0

# W8 模板变异：去锚点 / 重锚点 / 注入 FAIL / 注入 DEFECT / checks / wide
TMPL="$W/template.txt"
{
    printf 'FRONTEND_FAULTS checks=%s fails=0 wide_blocks=%s\n' "$SPEC_CUR_CHECKS" "$SPEC_CUR_WIDE"
    printf 'FUNCTIONAL_FRONTEND_FAULTS: PASS\n'
} > "$TMPL"
mk_cat() { local s="$1" f="$2"; cat > "$s" <<EOF
#!/usr/bin/env bash
cat "$f"
exit 0
EOF
chmod 755 "$s"; }
sed '/FUNCTIONAL_FRONTEND_FAULTS: PASS/d' "$TMPL" > "$W/t_noanchor.txt"
mk_cat "$FAKE/vv_noanchor.sh" "$W/t_noanchor.txt"
run_pkg "$P1" "$W/w8.log" RV32_VVP="$FAKE/vv_noanchor.sh"; RC=$?
assert_case W8_no_anchor "$RC" "$W/w8.log" 1 "pass_anchor_count=0" 0

{ cat "$TMPL"; printf 'FUNCTIONAL_FRONTEND_FAULTS: PASS\n'; } > "$W/t_dupanchor.txt"
mk_cat "$FAKE/vv_dupanchor.sh" "$W/t_dupanchor.txt"
run_pkg "$P1" "$W/w9.log" RV32_VVP="$FAKE/vv_dupanchor.sh"; RC=$?
assert_case W9_dup_anchor "$RC" "$W/w9.log" 1 "pass_anchor_count=2" 0

{ printf 'injected FAIL line\n'; cat "$TMPL"; } > "$W/t_fail.txt"
mk_cat "$FAKE/vv_fail.sh" "$W/t_fail.txt"
run_pkg "$P1" "$W/w10.log" RV32_VVP="$FAKE/vv_fail.sh"; RC=$?
assert_case W10_log_fail "$RC" "$W/w10.log" 1 "log_has_FAIL" 0

{ printf 'injected DEFECT line\n'; cat "$TMPL"; } > "$W/t_defect.txt"
mk_cat "$FAKE/vv_defect.sh" "$W/t_defect.txt"
run_pkg "$P1" "$W/w11.log" RV32_VVP="$FAKE/vv_defect.sh"; RC=$?
assert_case W11_log_defect "$RC" "$W/w11.log" 1 "log_has_defect" 0

BAD_CHECKS=$((SPEC_CUR_CHECKS + 1))
sed "s/checks=$SPEC_CUR_CHECKS/checks=$BAD_CHECKS/" "$TMPL" > "$W/t_badchecks.txt"
mk_cat "$FAKE/vv_badchecks.sh" "$W/t_badchecks.txt"
run_pkg "$P1" "$W/w12.log" RV32_VVP="$FAKE/vv_badchecks.sh"; RC=$?
assert_case W12_wrong_checks "$RC" "$W/w12.log" 1 "summary_checks=$BAD_CHECKS expect=$SPEC_CUR_CHECKS" 0

BAD_WIDE=$((SPEC_CUR_WIDE + 1))
sed "s/wide_blocks=$SPEC_CUR_WIDE/wide_blocks=$BAD_WIDE/" "$TMPL" > "$W/t_badwide.txt"
mk_cat "$FAKE/vv_badwide.sh" "$W/t_badwide.txt"
run_pkg "$P1" "$W/w13.log" RV32_VVP="$FAKE/vv_badwide.sh"; RC=$?
assert_case W13_wrong_wide "$RC" "$W/w13.log" 1 "summary_wide=$BAD_WIDE expect=$SPEC_CUR_WIDE" 0

# W14 缺 TB / W15 缺 driver / W16 TB 未登记
W14="$W/mini_notb"; make_mini "$W14"; rm -f "$W14/sim/functional/tb_frontend_faults.sv"
run_pkg "$W14" "$W/w14.log"; RC=$?
assert_case W14_tb_missing "$RC" "$W/w14.log" 1 "tb_missing" 0
W15="$W/mini_nodrv"; make_mini "$W15"; rm -f "$W15/sim/functional/test_frontend_faults_driver.sh"
run_pkg "$W15" "$W/w15.log"; RC=$?
assert_case W15_driver_missing "$RC" "$W/w15.log" 1 "pkg_missing" 0
W16="$W/mini_unknown_tb"; make_mini "$W16"
printf '\n// spec-unknown mutation\n' >> "$W16/sim/functional/tb_frontend_faults.sv"
run_pkg "$W16" "$W/w16.log"; RC=$?
assert_case W16_tb_spec_unknown "$RC" "$W/w16.log" 1 "tb_spec_unknown" 0

#------------------------------------------------------------------------------
# 12. H* sha 杀伤（合法 stdout 后 exit9 / 空 / 多 / 坏行 / 读失败 / env exit9）
#------------------------------------------------------------------------------
FBIN="$W/fakebin"; mkdir -p "$FBIN"
mk_sha_fake() {  # <mode>
    local mode="$1"
    cat > "$FBIN/sha256sum" <<EOF
#!/usr/bin/env bash
n=\$#
[ "\${1:-}" = "--" ] && n=\$((n - 1))
if [ "\$n" -le 1 ]; then
    "$REAL_SHA" "\$@"
    rc=\$?
    if [ "$mode" = "env_exit9" ]; then exit 9; fi
    exit \$rc
fi
case "$mode" in
    multi_empty) exit 0 ;;
    multi_readfail) exit 1 ;;
esac
tmp="$W/sha_tmp.\$\$"
"$REAL_SHA" "\$@" > "\$tmp"
rc=\$?
case "$mode" in
    multi_nul) python3 - "\$tmp" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); b = p.read_bytes(); i = b.index(b'  ') + 2
sys.stdout.buffer.write(b[:i] + b'\\0' + b[i:])
PY
        exit 0 ;;
    multi_exit9) cat "\$tmp"; exit 9 ;;
    multi_extra) cat "\$tmp"; echo "this-is-not-a-hash-line"; exit 0 ;;
    multi_badline) sed '1s/^./z/' "\$tmp"; exit 0 ;;
    multi_ok) cat "\$tmp"; exit \$rc ;;
esac
exit \$rc
EOF
    chmod 755 "$FBIN/sha256sum"
}
run_fake_sha() {  # <log> <mode> [extra env...]
    local log="$1" mode="$2"; shift 2
    mk_sha_fake "$mode"
    ( cd "$P1" && env -u RV32_FUNCTIONAL_PKG_OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u OUT_DIR \
        PATH="$FBIN:$PATH" "$@" RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional" \
        DUT_ROOT="$P1" bash "$P1/sim/functional/test_frontend_faults.sh" ) > "$log" 2>&1
}
run_fake_sha "$W/h1.log" multi_exit9; RC=$?
assert_case H1_sha_exit9 "$RC" "$W/h1.log" 1 "sha256_pre_rc=9" 0
run_fake_sha "$W/h2.log" multi_empty; RC=$?
assert_case H2_sha_empty "$RC" "$W/h2.log" 1 "sha256_pre_empty" 0
run_fake_sha "$W/h3.log" multi_extra; RC=$?
assert_case H3_sha_extra "$RC" "$W/h3.log" 1 "sha256_pre_lines=17" 0
run_fake_sha "$W/h4.log" multi_badline; RC=$?
assert_case H4_sha_badline "$RC" "$W/h4.log" 1 "sha256_pre_bad_line=1" 0
run_fake_sha "$W/h5.log" multi_readfail; RC=$?
assert_case H5_sha_readfail "$RC" "$W/h5.log" 1 "sha256_pre_rc=1" 0
run_fake_sha "$W/h6.log" env_exit9; RC=$?
assert_case H6_env_sha_exit9 "$RC" "$W/h6.log" 1 "env_sha_pre_rc=9" 0
run_fake_sha "$W/h7.log" multi_nul; RC=$?
assert_case H7_sha_bulk_nul "$RC" "$W/h7.log" 1 "sha256_pre_rc=1" 0
run_fake_sha "$W/h8.log" multi_ok; RC=$?
assert_case H8_sha_bulk_valid "$RC" "$W/h8.log" 0 "" 1
rm -f "$FBIN/sha256sum"

#------------------------------------------------------------------------------
# 12b. 单文件 caller 定点 sha 杀伤（TB / snapshot RTL / fixture），不被 env/bulk 挡
#------------------------------------------------------------------------------
FBIN2="$W/fakebin_single"; mkdir -p "$FBIN2"
mk_single_fake() {  # <mode> <match-substr>
    local mode="$1" match="$2"
    cat > "$FBIN2/sha256sum" <<EOF
#!/usr/bin/env bash
n=\$#
[ "\${1:-}" = "--" ] && n=\$((n - 1))
if [ "\$n" -le 1 ]; then
    case "\$*" in
        *"$match"*) : ;;
        *) exec "$REAL_SHA" "\$@" ;;
    esac
    case "$mode" in
        exit9)
            tmp="\$(mktemp "$W/single_tmp.XXXXXX")" || exit 1
            "$REAL_SHA" "\$@" > "\$tmp" 2>/dev/null
            cat "\$tmp"; rm -f "\$tmp"; exit 9 ;;
        empty) exit 0 ;;
        wrongpath)
            printf '%064d  /definitely/wrong/path\n' 0; exit 0 ;;
        garbage)
            printf 'this is not a sha256sum line\n'; exit 0 ;;
        trail)
            tmp="\$(mktemp "$W/single_tmp.XXXXXX")" || exit 1
            "$REAL_SHA" "\$@" > "\$tmp" 2>/dev/null
            cat "\$tmp"; rm -f "\$tmp"; printf '\n'; exit 0 ;;
        nul)
            tmp="\$(mktemp "$W/single_tmp.XXXXXX")" || exit 1
            "$REAL_SHA" "\$@" > "\$tmp" 2>/dev/null
            python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); b=p.read_bytes(); sys.stdout.buffer.write(b.replace(b"  ", b"\\0 ", 1))' "\$tmp"
            rm -f "\$tmp"; exit 0 ;;
        unterminated)
            tmp="\$(mktemp "$W/single_tmp.XXXXXX")" || exit 1
            "$REAL_SHA" "\$@" > "\$tmp" 2>/dev/null
            head -c "\$(( \$(wc -c < "\$tmp") - 1 ))" "\$tmp"; rm -f "\$tmp"; exit 0 ;;
        valid)
            exec "$REAL_SHA" "\$@" ;;
    esac
fi
exec "$REAL_SHA" "\$@"
EOF
    chmod 755 "$FBIN2/sha256sum"
}
for mode in exit9 empty wrongpath garbage trail nul unterminated valid; do
    mk_single_fake "$mode" "tb_frontend_faults.sv"
    ( cd "$P1" && env -u RV32_FUNCTIONAL_PKG_OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u OUT_DIR \
        -u FRONTEND_FAULTS_SRC_ROOT -u FRONTEND_FAULTS_FIXTURES_ROOT \
        PATH="$FBIN2:$PATH" RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional" DUT_ROOT="$P1" \
        bash "$P1/sim/functional/test_frontend_faults.sh" ) > "$W/h_tb_$mode.log" 2>&1
    RC=$?
    if [ "$mode" = valid ]; then
        assert_case "H_tb_$mode" "$RC" "$W/h_tb_$mode.log" 0 "" 1
    else
        assert_case "H_tb_$mode" "$RC" "$W/h_tb_$mode.log" 1 "tb_sha_unavailable" 0
    fi

    mk_single_fake "$mode" "rtl/front4/ifetch4.v"
    ( cd "$P1" && env -u RV32_FUNCTIONAL_PKG_OUT_DIR -u RV32_FUNCTIONAL_OUT_DIR -u OUT_DIR \
        PATH="$FBIN2:$PATH" RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional" DUT_ROOT="$P1" \
        bash "$P1/sim/functional/test_frontend_faults.sh" ) > "$W/h_rtl_$mode.log" 2>&1
    RC=$?
    if [ "$mode" = valid ]; then
        assert_case "H_rtl_$mode" "$RC" "$W/h_rtl_$mode.log" 0 "" 1
    else
        assert_case "H_rtl_$mode" "$RC" "$W/h_rtl_$mode.log" 1 "snapshot_src_hash_failed" 0
    fi

    mk_single_fake "$mode" "frontend_hist_183/tb_frontend_faults.sv"
    run_child_driver explicit "$P1" "$W/h_fix_$mode.log" \
        PATH="$FBIN2:$PATH" RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional"
    RC=$?
    if [ "$mode" = valid ]; then
        [ "$RC" -eq 0 ] && grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/h_fix_$mode.log" \
            && sub_ok "H_fix_$mode" || sub_fail "H_fix_$mode" "child_rc=$RC want driver PASS"
    else
        assert_case "H_fix_$mode" "$RC" "$W/h_fix_$mode.log" 1 "fixture_hash_failed" 0
    fi
done
rm -f "$FBIN2/sha256sum"

# 12c. Bulk sha_list caller：argc>1 NUL 必须拒；同工具有效 bulk 输出必须通过。
FBIN3="$W/fakebin_bulk"; mkdir -p "$FBIN3"
cat > "$FBIN3/sha256sum" <<EOF
#!/usr/bin/env bash
n=\$#
[ "\${1:-}" = "--" ] && n=\$((n - 1))
if [ "\$n" -gt 1 ] && [ "\${FRONTEND_TEST_SHA_MODE:-valid}" = nul ]; then
    tmp="\$(mktemp "$W/bulk_tmp.XXXXXX")" || exit 1
    "$REAL_SHA" "\$@" > "\$tmp" || exit \$?
    python3 - "\$tmp" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); b = p.read_bytes(); i = b.index(b'  ') + 2
sys.stdout.buffer.write(b[:i] + b'\\0' + b[i:])
PY
    rc=\$?; rm -f "\$tmp"; exit \$rc
fi
exec "$REAL_SHA" "\$@"
EOF
chmod 755 "$FBIN3/sha256sum"
run_child_driver explicit "$P1" "$W/h_bulk_nul.log" \
    PATH="$FBIN3:$PATH" FRONTEND_TEST_SHA_MODE=nul \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional"
RC=$?
assert_case H_driver_bulk_nul "$RC" "$W/h_bulk_nul.log" 1 "src_manifest_sha_rc=1" 0
run_child_driver explicit "$P1" "$W/h_bulk_valid.log" \
    PATH="$FBIN3:$PATH" FRONTEND_TEST_SHA_MODE=valid \
    RV32_FUNCTIONAL_PKG_OUT_DIR="$P1/build/functional"
RC=$?
[ "$RC" -eq 0 ] && grep -qxF 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS' "$W/h_bulk_valid.log" \
    && sub_ok H_driver_bulk_valid || sub_fail H_driver_bulk_valid "child_rc=$RC"

#------------------------------------------------------------------------------
# 13. M* 跨相漂移（运行中改文件；每类精确 reason）
#------------------------------------------------------------------------------
mk_mut_vv() {  # <script> <target>
    cat > "$1" <<EOF
#!/usr/bin/env bash
"$REAL_VV" "\$@"
rc=\$?
printf '\\n// injected mutation during run\\n' >> "$2"
exit \$rc
EOF
    chmod 755 "$1"
}
mut_case() {  # <name> <target-rel> <want-reason>
    local name="$1" rel="$2" reason="$3" d log rc
    d="$W/mini_$name"; log="$W/$name.log"
    make_mini "$d"
    mk_mut_vv "$FAKE/vv_mut_$name.sh" "$d/$rel"
    run_pkg "$d" "$log" RV32_VVP="$FAKE/vv_mut_$name.sh"; rc=$?
    assert_case "$name" "$rc" "$log" 1 "$reason" 0
}
mut_case M1_product_rtl "rtl/front4/pc_gen4.v" "product_changed_after_run"
mut_case M2_product_hdr "rtl/pkg/rv32_defs.vh" "product_changed_after_run"
mut_case M3_tb "sim/functional/tb_frontend_faults.sv" "product_changed_after_run"
mut_case M4_env "scripts/env.sh" "env_changed_after_run"
mut_case M5_wrapper "sim/functional/test_frontend_faults.sh" "package_changed_after_run"
mut_case M6_driver "sim/functional/test_frontend_faults_driver.sh" "package_changed_after_run"
check_freeze_unchanged whm

#------------------------------------------------------------------------------
# 14. C 合法 no-op 控（同一工装、不改文件 ⇒ 必须绿）
#------------------------------------------------------------------------------
NOOP="$W/mini_noop"; make_mini "$NOOP"
run_pkg "$NOOP" "$W/noop.log"; RC=$?
assert_case C1_noop_control "$RC" "$W/noop.log" 0 "" 1

#------------------------------------------------------------------------------
# 15. 汇总：冻结再复核 + 独立锚点
#------------------------------------------------------------------------------
check_freeze_unchanged final
check_source_root_unchanged
if [ "$NG" -ne 0 ]; then
    printf 'FRONTEND_DRIVER_TESTS total=%s failed=%s work_dir=%s\n' "$NT" "$NG" "$W"
    printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: FAIL reason=subtests_failed count=%s work_dir=%s\n' "$NG" "$W"
    exit 1
fi
printf 'FRONTEND_DRIVER_TESTS total=%s failed=0 work_dir=%s\n' "$NT" "$W"
printf 'FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS\n'
note "FUNCTIONAL_FRONTEND_FAULTS_DRIVER: PASS"
exit 0
