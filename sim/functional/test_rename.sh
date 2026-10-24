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
#   3) 默认 DUT_ROOT = 本仓库根 ⇒ 要求 22/22 向量 `VERDICT=OK`。
#
# 反证（单独模式，绝不与默认成功混在同一判定里；**不依赖任何预先存在的 build 夹具**）:
#   `bash sim/functional/test_rename.sh --self-test`（或 `--negative` / RV32_RENAME_MODE=defect）
#     · 用 `git -C <repo> archive 201acf61…` **现场生成**旧源码只读快照；
#     · 对旧快照跑**同一冻结 TB**：10 个触发向量全部 `DEFECT_SIG`（02-2/02-3 + 审阅 P1），
#       12 个控制向量全部 `OK`（旧代码在合法序列上也正确）；
#     · 再对当前树（新源码）跑同一核算 TB：22/22 `OK`；
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
#   · 逐向量：0..21 每例恰好一条严格格式 `CASE <n> <name> KIND=<k> VERDICT=<v> nchk=<N>`；
#             `KIND` 必须与脚本冻结分类一致；`nchk` 必须 ≥ MIN_NCHK（防少跑/空跑）
#   · 默认：22/22 `OK`；日志零 `DEFECT_SIG` / 零 `DEFECT_REPRODUCED` / 零 `FAIL`
#   · 反证：旧树 10 触发全 `DEFECT_SIG` 且 12 控制全 `OK`；新树 22/22 `OK`
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
SPEC_TOTAL=25
SPEC_TRIGGER=11
SPEC_CONTROL=14
# 8/9=02-2；10/11/12/13/15=02-3；16/17/18=审阅 P1（死组重入抢仍活旧组影子）
TRIGGER_CASES="8 9 10 11 12 13 15 16 17 18 22"
# 逐向量检查数下限（防少跑/空跑冒充：TB 若把某向量压成空转，nchk 会低于此表）
min_nchk_for() {
    case "$1" in
        0) echo 20;; 1) echo 15;; 2) echo 30;; 3) echo 15;; 4) echo 15;;
        5) echo 50;; 6) echo 50;; 7) echo 15;; 8) echo 15;; 9) echo 15;;
        10) echo 50;; 11) echo 60;; 12) echo 50;; 13) echo 20;; 14) echo 80;; 15) echo 90;;
        16) echo 50;; 17) echo 60;; 18) echo 50;; 19) echo 20;;
        20) echo 50;; 21) echo 50;; 22) echo 50;; 23) echo 50;; 24) echo 50;;
        *) echo 0;;
    esac
}
#   ★ 冻结的 (id → 向量名) 表：逐向量必须**同名**出现（防 TB 改名/换绑/异号冒充）。
#     与 tb_rename_semantics.sv 的 run_case 表一一对应；缺项按失败处理（fail-closed）。
case_name_of() {
    case "$1" in
        0) echo int_x0_hard_zero;;    1) echo fp_f0_writable;;
        2) echo basic_commit_release;;3) echo ckpt_save_restore;;
        4) echo missing_ckpt_rob;;    5) echo flush_rebuild_high;;
        6) echo cmt_flush_same_cycle;;7) echo cmt_restore_same;;
        8) echo t_mask_residue_basic;;9) echo t_mask_residue_audit;;
        10) echo t_wrap_group0;;      11) echo t_wrap_midgroup;;
        12) echo t_wrap_stress;;      13) echo t_high_preg_rollback;;
        14) echo rand_mix_light;;     15) echo rand_mix_split;;
        16) echo t_shadow_steal_min;; 17) echo t_same_group_2nd;;
        18) echo t_dead_reentry_alloc;;19) echo ctrl_post_rb_alloc;;
        20) echo ctrl_tailq_boundary;;21) echo ctrl_full_no_fire;;
        22) echo t_full_arc_restore;; 23) echo t_retired_prefix_mask;;
        24) echo t_stress_legal;;
        *) echo "";;
    esac
}
OLD_COMMIT="201acf61e118a3fb533e1a96768687a35efa1751"

# 本包只直接编译 rename 及其必要头（不依赖 backend_top / 其他正在变化的域）。
#   ★ EXP-F2 审阅：必需头是**固定清单**，缺任一即硬拒（不再用 find 动态发现 ⇒ 缺头不会
#     被"少一个文件"悄悄吞掉）；编译输入 sha256 清单条数也是固定值（= RTL 1 + 头 1 + TB 1）。
DEP_FILES=( rtl/back2/rename.v )
REQ_HEADERS=( rtl/back2/back2_params.vh )

#------------------------------------------------------------------------------
# 2. 判定状态与输出助手（stdout 只放摘要 + 唯一锚点；细节进 run 目录日志）
#------------------------------------------------------------------------------
RUN_DIR=""
SUM_OK="-"; SUM_BAD="-"
#   ★ 冻结 TB 与"源 TB 起始 sha"（RUN_DIR 建立后赋值）：新旧两阶段都编译同一份冻结副本。
FREEZE_TB=""
FREEZE_SHA=""
TB_SRC_SHA0=""
PKG_SRC=""
PKG_SHA0=""
ENV_SHA0=""

#   ★★ 审阅 P1-4：单值 sha256 必须捕获 sha256sum 的**原始 rc**，并要求**恰一行 64-hex**。
#     `$(sha256sum … | awk …)` 会把 rc 换成 awk 的（恒 0）⇒ 读失败被静默当"内容变了/没变"。
is_sha1() {
    case "${1:-}" in *[!0-9a-f]*) return 1;; esac
    [ "${#1}" -eq 64 ]
}

sha1_of() {
    local f="$1" raw rc n line v
    [ -f "$f" ] || { echo "sha1_of: not a file: $f" >> "$RUN_LOG"; return 1; }
    raw="$(mktemp -- "$RUN_DIR/sha1-raw-XXXXXXXX")" || return 1
    sha256sum -- "$f" > "$raw" 2>>"$RUN_LOG"; rc=$?
    [ "$rc" -eq 0 ] || { echo "sha1_of: sha256sum rc=$rc file=$f" >> "$RUN_LOG"; return 1; }
    n="$(wc -l < "$raw")"
    [ "$n" -eq 1 ] || { echo "sha1_of: raw LF lines=$n (expect exactly 1) file=$f" >> "$RUN_LOG"; return 1; }
    IFS= read -r line < "$raw" || { echo "sha1_of: missing terminating LF file=$f" >> "$RUN_LOG"; return 1; }
    printf '%s\n' "$line" | cmp -s - "$raw" || { echo "sha1_of: raw bytes malformed file=$f" >> "$RUN_LOG"; return 1; }
    case "$line" in [0-9a-f][0-9a-f]*) ;; *) echo "sha1_of: malformed line file=$f" >> "$RUN_LOG"; return 1;; esac
    v="${line:0:64}"
    is_sha1 "$v" && [ "${line:64:2}" = '  ' ] && [ "${line:66}" = "$f" ] \
        || { echo "sha1_of: malformed hash/path file=$f" >> "$RUN_LOG"; return 1; }
    printf '%s\n' "$v"
    return 0
}

#   ★★ 原 P1 根因补完：**所有** sha 使用点都走这里 —— 先赋值、核 rc、再核"非空且恰 64 hex"，
#     之后才允许比较/写日志。禁止内联 `[ "$(hash a)" = "$(hash b)" ]` 或 note 嵌 $(hash)：
#     两次失败都得到空串 ⇒ 空==空会**假绿**。
sha1_checked() {
    local f="$1" v
    v="$(sha1_of "$f")" || return 1
    is_sha1 "$v" || return 1
    printf '%s\n' "$v"
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
# 3b. 冻结 TB（新旧两阶段共用）+ 记录源 TB / env 的起始 sha256
#------------------------------------------------------------------------------
[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"
TB_SRC_SHA0="$(sha1_checked "$TB_SRC")" || emit_fail "tb_sha_unavailable"
is_sha1 "$TB_SRC_SHA0" || emit_fail "tb_sha_malformed"
FREEZE_TB="$RUN_DIR/tb-frozen.sv"
cp -p -- "$TB_SRC" "$FREEZE_TB" || emit_fail "freeze_tb_copy_failed"
FREEZE_SHA="$(sha1_checked "$FREEZE_TB")" || emit_fail "freeze_tb_sha_unavailable"
is_sha1 "$FREEZE_SHA" || emit_fail "freeze_tb_sha_malformed"
[ "$FREEZE_SHA" = "$TB_SRC_SHA0" ] || emit_fail "freeze_tb_sha_mismatch"
#   包自身（本脚本）与 env 也纳入"共享输入固定清单"，运行前后必须逐字节一致
PKG_SRC="$SELF_PATH"
PKG_SHA0="$(sha1_checked "$PKG_SRC")" || emit_fail "pkg_sha_unavailable"
ENV_SHA0="$(sha1_checked "$ENV_SH")"  || emit_fail "env_sha_unavailable"
is_sha1 "$PKG_SHA0" || emit_fail "pkg_sha_malformed"
is_sha1 "$ENV_SHA0" || emit_fail "env_sha_malformed"
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
#   ★★ source 的返回码必须**紧跟 source 捕获并先拒**（原缺陷：先 verify_env_unchanged
#     再取 $?，verify 返回 0 会把 source 的非 0 吞掉 ⇒ 私有 env 末尾 return 9 被当成功）。
ENV_RC=0
# shellcheck disable=SC1090
. "$ENV_SH" >> "$RUN_LOG" 2>&1 || ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"
#   ★ env 是共享输入：source 前后 sha 必须一致（被改即拒；env.sh 依赖自身位置推导根，
#     故按"sha 钉死 + 立即复核"冻结，而不是把文件搬走导致工具路径全错）。
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
    for rel in "${REQ_HEADERS[@]}"; do
        [ -f "$root/$rel" ] || { echo "snapshot: MISSING required header $root/$rel" >> "$RUN_LOG"; return 1; }
        mkdir -p -- "$snap/$(dirname -- "$rel")" || return 1
        cp -p -- "$root/$rel" "$snap/$rel" || return 1
    done
    return 0
}

#------------------------------------------------------------------------------
# 5b. 编译**快照**；记录**实际所有编译源**的 sha256（行数+格式严格校验）
#     $1 = 快照根   $2 = 输出 vvp   $3 = 阶段标签   $4 = 快照内 TB 路径
#     同时把 sha256 清单写到 <标签>.sha，供运行结束后"前后一致"复核。
#------------------------------------------------------------------------------
compile_root() {
    local root="$1" vvp="$2" tag="$3" tb="$FREEZE_TB" f rc n sha_out n_lines sha_rc n_expect sha_raw line i expected_path
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
    if [ "$n_expect" -ne 3 ]; then
        echo "[$tag] fixed closure count mismatch: $n_expect != 3" >> "$RUN_LOG"; return 1
    fi

    # ---- SHA：**不得**用 `|| true` 吞失败；行数与 64-hex 行格式必须严格 ----
    sha_raw="$RUN_DIR/$tag.sha.raw"
    sha256sum -- "$tb" "${files[@]}" "${hdrs[@]}" > "$sha_raw" 2>>"$RUN_LOG"; sha_rc=$?
    if [ "$sha_rc" -ne 0 ]; then echo "[$tag] sha256 command rc=$sha_rc" >> "$RUN_LOG"; return 1; fi
    n_lines="$(wc -l < "$sha_raw")"
    if [ "$n_lines" -ne "$n_expect" ]; then
        echo "[$tag] sha256 raw LF lines=$n_lines expect=$n_expect" >> "$RUN_LOG"
        cat -- "$sha_raw" >> "$RUN_LOG"
        return 1
    fi
    local all_paths=( "$tb" "${files[@]}" "${hdrs[@]}" )
    : > "$RUN_DIR/$tag.sha" || return 1
    i=0
    while IFS= read -r line; do
        expected_path="${all_paths[$i]:-}"
        case "$line" in [0-9a-f][0-9a-f]*) ;; *) echo "[$tag] malformed sha line index=$i" >> "$RUN_LOG"; return 1;; esac
        is_sha1 "${line:0:64}" && [ "${line:64:2}" = '  ' ] \
            && [ "${line:66}" = "$expected_path" ] || {
                echo "[$tag] sha line/path mismatch index=$i expected=$expected_path" >> "$RUN_LOG"; return 1; }
        printf '%s\n' "$line" >> "$RUN_DIR/$tag.sha" || return 1
        i=$((i+1))
    done < "$sha_raw"
    [ "$i" -eq "$n_expect" ] || { echo "[$tag] sha line count mismatch parsed=$i expect=$n_expect" >> "$RUN_LOG"; return 1; }
    cmp -s -- "$sha_raw" "$RUN_DIR/$tag.sha" || { echo "[$tag] raw sha bytes differ from canonical manifest" >> "$RUN_LOG"; return 1; }
    sha_out="$(<"$RUN_DIR/$tag.sha")"
    {
        echo "-- [$tag] SNAPSHOT_ROOT = $root"
        echo "-- [$tag] TB = $tb"
        echo "-- [$tag] inputs: ${#files[@]} RTL + ${#hdrs[@]} header + 1 TB = $n_expect (sha256 below) --"
        printf '%s\n' "$sha_out"
    } >> "$RUN_LOG"

    #   ★ 编译 cwd = **快照根**（相对 include 只可能在快照内解析；不受调用者 cwd 影响）。
    ( cd -- "$root" && timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 \
            -I "$root/rtl/pkg" -I "$root" -I . \
            -s tb_rename_semantics -o "$vvp" "$tb" "${files[@]}" ) \
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
    local vvp="$1" case="$2" expect="$3" tag="$4" log rc sz n_case kind verdict exp_kind
    local exp_name minn nchk nV nK
    log="$RUN_DIR/${tag}_case_${case}.log"
    exp_name="$(case_name_of "$case")"
    [ -n "$exp_name" ] || { echo "[$tag] case $case 不在冻结 ID/name 表（fail-closed）" >> "$RUN_LOG"; return 1; }

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

    # ① 该次运行必须**恰好一条** `^CASE ` 行（多行/异号/额外行一律拒）
    n_case="$(grep -cE '^CASE ' "$log" || true)"
    if [ "$n_case" -ne 1 ]; then
        echo "[$tag] case $case 的 CASE 行数=$n_case（期望 1；额外/异号/重复皆拒）" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true
        return 1
    fi
    # ② 整行锚定 + **id 与冻结 name 双重绑定**（改绑/改名/异号/坏格式皆拒；
    #    锚定正则天然拒绝重复字段与夹带字段）
    if ! grep -qE "^CASE ${case} ${exp_name} KIND=(trigger|control) VERDICT=(OK|DEFECT_SIG)( reason=timeout)? nchk=[0-9]+$" "$log" \
       && ! grep -qE "^CASE ${case} ${exp_name} KIND=(trigger|control) VERDICT=DEFECT_SIG reason=timeout$" "$log"; then
        echo "[$tag] case $case 严格 CASE 行不匹配（期望 id=$case name=$exp_name）" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true
        return 1
    fi
    # ③ 冲突字段：KIND=/VERDICT= 各出现且仅 1 次
    nV="$(grep -oE 'VERDICT=' "$log" | wc -l)"; nK="$(grep -oE 'KIND=' "$log" | wc -l)"
    if [ "$nV" -ne 1 ] || [ "$nK" -ne 1 ]; then
        echo "[$tag] case $case 字段冲突/重复 KIND=$nK VERDICT=$nV" >> "$RUN_LOG"; return 1
    fi
    kind="$(sed -nE "s/^CASE ${case} ${exp_name} KIND=([a-z]+) .*/\1/p" "$log")"
    verdict="$(sed -nE "s/^CASE ${case} ${exp_name} KIND=[a-z]+ VERDICT=([A-Z_]+).*/\1/p" "$log")"

    # ④ 逐向量检查数：**必须真实非零**，且不低于该向量的冻结下限（防少跑/空跑冒充）
    minn="$(min_nchk_for "$case")"
    if grep -qE "^CASE ${case} ${exp_name} KIND=(trigger|control) VERDICT=(OK|DEFECT_SIG)( reason=timeout)? nchk=([0-9]+)$" "$log"; then
        nchk="$(sed -nE "s/^CASE ${case} ${exp_name} KIND=[a-z]+ VERDICT=[A-Z_]+( reason=timeout)? nchk=([0-9]+)$/\2/p" "$log")"
        if [ -z "$nchk" ] || [ "$nchk" -eq 0 ]; then
            echo "[$tag] case $case nchk=$nchk（必须真实非零）" >> "$RUN_LOG"; return 1
        fi
        if [ "$nchk" -lt "$minn" ]; then
            echo "[$tag] case $case nchk=$nchk < 冻结下限 $minn" >> "$RUN_LOG"; return 1
        fi
    else
        # 仅允许 timeout 形式（无 nchk），且只能是 DEFECT_SIG
        echo "[$tag] case $case 无 nchk 字段（只接受 reason=timeout 的 DEFECT_SIG）" >> "$RUN_LOG"
        return 1
    fi

    exp_kind=control
    for c in $TRIGGER_CASES; do [ "$c" = "$case" ] && exp_kind=trigger; done
    if [ "$kind" != "$exp_kind" ]; then
        echo "[$tag] case $case KIND=$kind expect=$exp_kind (TB/脚本漂移)" >> "$RUN_LOG"; return 1
    fi
    if [ "$verdict" != "$expect" ]; then
        echo "[$tag] case $case VERDICT=$verdict expect=$expect" >> "$RUN_LOG"
        cat -- "$log" >> "$RUN_LOG"
        return 1
    fi
    cat -- "$log" >> "$RUN_LOG"
    printf 'VEC %s %s %s kind=%s verdict=%s nchk=%s\n' "$tag" "$case" "$exp_name" "$kind" "$verdict" "${nchk:--}" >> "$RUN_LOG"
    return 0
}

# 严格校验某阶段的 VEC 行：数量 == 期望例数、格式规范、例号各出现且仅一次
check_vec_lines() {
    local tag="$1" expect="$2" n bad
    n="$(grep -cE "^VEC ${tag} [0-9]+ [a-z0-9_]+ kind=(trigger|control) verdict=[A-Z_]+ nchk=([0-9]+|-)$" "$RUN_LOG" || true)"
    [ "$n" = "$expect" ] || emit_fail "vec_count_${tag}=$n expect=$expect"
    #   ★ 逐 id 的 name 覆盖校验：每个 id 必须恰好一条"冻结 name"的 VEC 行（改名/换绑即拒）
    local c expn n1
    for c in $(seq 0 $((SPEC_TOTAL-1))); do
        expn="$(case_name_of "$c")"
        [ -n "$expn" ] || emit_fail "vec_name_table_missing id=$c"
        n1="$(grep -cE "^VEC ${tag} ${c} ${expn} kind=(trigger|control) verdict=[A-Z_]+ nchk=([0-9]+|-)$" "$RUN_LOG" || true)"
        [ "$n1" -eq 1 ] || emit_fail "vec_name_${tag}_case${c}=${n1} expect=1"
    done
    bad="$(awk -v t="$tag" '
        $1=="VEC" && $2==t {
            if ($0 !~ ("^VEC " t " [0-9]+ [a-z0-9_]+ kind=(trigger|control) verdict=[A-Z_]+ nchk=([0-9]+|-)$")) b++;
            seen[$3]++;
        }
        END { for (k in seen) if (seen[k]!=1) b++; printf "%d", b+0 }
    ' "$RUN_LOG")"
    [ "$bad" = "0" ] || emit_fail "vec_format_or_dup_${tag}=$bad"
}

#------------------------------------------------------------------------------
# 7. 新源码（当前树 / DUT_ROOT）：22 向量全部 VERDICT=OK
#------------------------------------------------------------------------------
DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"
echo "DUT_ROOT        = $DUT_ROOT" >> "$RUN_LOG"

[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"
SNAP_NEW="$RUN_DIR/src-new"
snapshot_root "$DUT_ROOT" "$SNAP_NEW" || emit_fail "snapshot_new_failed root=$DUT_ROOT"
echo "SNAP_NEW        = $SNAP_NEW" >> "$RUN_LOG"
verify_tb_frozen || emit_fail "frozen_tb_changed_before_new"
compile_root "$SNAP_NEW" "$VVP_OUT" "new" \
    || emit_fail "compile_new_failed"

OK_N=0; BAD_N=0
for c in $(seq 0 $((SPEC_TOTAL-1))); do
    if run_one "$VVP_OUT" "$c" "OK" "new"; then OK_N=$((OK_N+1)); else BAD_N=$((BAD_N+1)); fi
done
SUM_OK="$OK_N"; SUM_BAD="$BAD_N"
#   ★ 先报"哪些向量失败"（精确原因），再报 VEC 行数（结构原因）：失败向量数信息量更大。
[ "$BAD_N" -eq 0 ] || emit_fail "new_source_bad_vectors=$BAD_N"
[ "$OK_N" -eq "$SPEC_TOTAL" ] || emit_fail "new_source_ok=$OK_N expect=$SPEC_TOTAL"
check_vec_lines "new" "$SPEC_TOTAL"
verify_sha_unchanged "new" || emit_fail "new_inputs_changed"

#------------------------------------------------------------------------------
# 8. 反证模式（单独）：201acf61 现场 Git 快照 → 触发例旧红/控制例旧正确；新源码已全绿（同一冻结 TB）
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
    #   ★ 阶段间一致性：冻结 TB 不得变；源 TB 也不得在阶段间被改（改了即精确拒绝）。
    verify_tb_frozen          || emit_fail "frozen_tb_changed_between_phases"
    verify_tb_src_unchanged   || emit_fail "source_tb_changed_between_phases"
    verify_pkg_unchanged      || emit_fail "pkg_changed_between_phases"
    verify_env_unchanged      || emit_fail "env_changed_between_phases"
    compile_root "$SNAP_OLD" "$OLD_VVP" "old" \
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

    verify_tb_src_unchanged || emit_fail "source_tb_changed_during_run"
    verify_tb_frozen        || emit_fail "frozen_tb_changed_during_run"
    verify_pkg_unchanged    || emit_fail "pkg_changed_during_run"
    verify_env_unchanged    || emit_fail "env_changed_during_run"
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

#   ★ 收尾：源 TB 在整个运行期间不得变化（否则本轮结果不可归属到该 TB 版本）
verify_tb_src_unchanged || emit_fail "source_tb_changed_during_run"
verify_pkg_unchanged    || emit_fail "pkg_changed_during_run"
verify_env_unchanged    || emit_fail "env_changed_during_run"

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
