#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_backend_semantics.sh —— F1 后端包功能定向测试入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二）
# 依据 : prompts/common.md §3；F1 后端包验收；独审 P1-1/P1-2/P1-3 + 窄复审收紧。
#
# 做什么 :
#   1) 在 build/functional 下的**私有 run 目录**里建**固定 26 输入闭包快照**
#      （21 RTL 源 + 4 必要头 + TB；逐个存在性校验，缺一即硬拒，**不做 find 动态降数**）；
#   2) **在快照 root 内、用相对路径编译**（`cd <snap>` + `-I rtl/pkg -I .`），
#      不使用工作树 cwd 的任何 include；快照建前/建后各记一次 sha256 清单（文件对文件
#      `cmp`，且 sha256sum 的 rc 必须为 0）并要求相等；
#   3) 逐向量跑 vvp（`+CASE=<n>`），按**逐 token 计数**的严格解析只接受本例完整记录；
#      默认 DUT_ROOT=本仓库根 ⇒ 18/18 `VERDICT=OK`。
#
# 反证（单独模式，不与默认成功混判；**不依赖任何预先存在的 build 夹具**）:
#   `bash sim/functional/test_backend_semantics.sh --self-test`（别名 --negative）：
#     · `git archive 201acf61…` 现场生成旧源码只读快照 ⇒ 同一 TB：7 触发例 DEFECT_SIG、
#       11 控制例 OK；新源码 18/18 OK；
#     · 收口反证（parse_case_log 逐 token / 26 输入闭包与 cwd 隔离 / sha rc / X 敏感）
#       逐类计数并在摘要行报出。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR > OUT_DIR > $REPO_ROOT/build/functional/backend；
#     根规范化并校验位于 build/functional 之下后 `mktemp -d <根>/run-XXXXXXXX` 独占子目录。
#   · 编译输入 = <RUN_DIR>/src-{new,old}/ 下**固定 26 输入**快照；日志逐输入记 sha256。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP；可被同名环境变量覆盖。
#
# 判定（全部满足才算 PASS，否则 exit 1 且**不打印** PASS 锚点）:
#   · 参数：只接受零参数 / `--self-test` / `--negative`
#   · 工具：env.sh source rc=0；RV32_IVERILOG/RV32_VVP 可执行
#   · 闭包：固定 26 输入逐个存在 + sha256 清单（行数/格式严格；sha rc=0；快照前后相等）
#   · 编译：快照 root 内相对路径编译，rc=0 且产出非空 vvp（零产物/超时 ⇒ 失败）
#   · 逐向量：逐 token 计 KIND/VERDICT；每例恰好 1 个 VERDICT、1 个 KIND、无混名/异号
#   · 默认：18/18 OK、零 DEFECT_SIG/DEFECT_REPRODUCED/FAIL；锚点唯一
#   · 反证：旧 7 触发 DEFECT_SIG + 11 控制 OK + 新 18 OK；收口反证全过
#==============================================================================
set -u

NEG=0
if [ "$#" -gt 1 ]; then
    printf 'FUNCTIONAL_BACKEND_SEMANTICS: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test|--negative) NEG=1 ;;
        *) printf 'FUNCTIONAL_BACKEND_SEMANTICS: FAIL reason=unknown_arg argv=%s\n' "$1"; exit 1 ;;
    esac
fi
case "${RV32_BACKEND_SEMANTICS_MODE:-spec}" in
    spec)   ;;
    defect) NEG=1 ;;
    *) printf 'FUNCTIONAL_BACKEND_SEMANTICS: FAIL reason=bad_mode value=%s\n' "${RV32_BACKEND_SEMANTICS_MODE}"; exit 1 ;;
esac
TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-600}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-120}"

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_BACKEND_SEMANTICS: FAIL reason=self_dir_unresolved\n'; exit 1; }
SELF_ABS="$SELF_DIR/$(basename -- "$SELF_PATH")"
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_BACKEND_SEMANTICS: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_backend_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

SPEC_TOTAL=18
SPEC_TRIGGER=7
SPEC_CONTROL=11
OLD_COMMIT="201acf61e118a3fb533e1a96768687a35efa1751"
TRIGGER_CASES="1 2 4 7 9 12 14"

# ---- 固定输入闭包（**不再 find**；缺任一即硬拒）----
DEP_FILES=(
    rtl/back2/backend_top.v rtl/back2/rename.v rtl/back2/rob.v rtl/back2/rob_wide_mem.v
    rtl/back2/iq.v rtl/back2/prf.v rtl/back2/lsq_simple.v
    rtl/decode/decoder.v rtl/decode/dec_csr.v rtl/decode/dec_imm.v rtl/decode/compressed_expand.v
    rtl/exec/alu.v rtl/exec/bru.v rtl/exec/mdu.v rtl/exec/fpu.v rtl/exec/fpu_add.v
    rtl/exec/fpu_mul.v rtl/exec/fpu_div_sqrt.v rtl/exec/fpu_cmp.v rtl/exec/fpu_cvt.v
    rtl/exec/fpu_fma_shared.v
)
HDR_FILES=(
    rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh
    rtl/back2/back2_params.vh rtl/front4/front4_params.vh
)
INPUT_N=$(( ${#DEP_FILES[@]} + ${#HDR_FILES[@]} + 1 ))   # 21 + 4 + TB = 26
TB_IN_SNAP="tb_backend_semantics.sv"

RUN_DIR=""
SUM_OK="-"; SUM_BAD="-"
emit_fail() {
    if [ "$NEG" -eq 1 ]; then
        printf 'FUNCTIONAL_BACKEND_SEMANTICS_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    else
        printf 'BACKEND_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
               "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$SUM_OK" "$SUM_BAD"
        printf 'FUNCTIONAL_BACKEND_SEMANTICS: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/backend}}"
is_authorized() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_readlink_failed root=$ROOT_RAW"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM auth=$AUTH_ROOT"
mkdir -p -- "$ROOT_NORM" || emit_fail "out_root_mkdir_failed root=$ROOT_NORM"
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail "out_root_recheck_readlink_failed"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized_after_mkdir root=$ROOT_NORM"
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail "mktemp_run_dir_failed root=$ROOT_NORM"
RUN_LOG="$RUN_DIR/test_backend_semantics.log"
VVP_OUT="$RUN_DIR/tb_backend_semantics.vvp"
printf 'BACKEND_RUN_DIR=%s\n' "$RUN_DIR"
: > "$RUN_LOG" || emit_fail "run_log_create_failed"
{
    echo "==== test_backend_semantics.sh : F1 backend semantics (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "MODE            = $([ "$NEG" -eq 1 ] && echo self-test || echo spec)"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "FIXED_INPUTS    = ${#DEP_FILES[@]} RTL + ${#HDR_FILES[@]} header + 1 TB = $INPUT_N"
    echo "OLD_COMMIT      = $OLD_COMMIT"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "=========================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

[ -r "$ENV_SH" ] || emit_fail "env_sh_unreadable path=$ENV_SH"
. "$ENV_SH" >> "$RUN_LOG" 2>&1
ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing name=RV32_IVERILOG value=${IV:-unset}"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing name=RV32_VVP value=${VV:-unset}"
command -v timeout >/dev/null 2>&1 || emit_fail "tool_missing name=timeout"
command -v sha256sum >/dev/null 2>&1 || emit_fail "tool_missing name=sha256sum"
REAL_SHA="$(command -v sha256sum)"
echo "RV32_IVERILOG   = $IV" >> "$RUN_LOG"
echo "RV32_VVP        = $VV" >> "$RUN_LOG"
echo "REAL_SHA256SUM  = $REAL_SHA" >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 5a. 固定 26 输入闭包快照（逐个存在性硬校验；不 find、不动态降数）
#------------------------------------------------------------------------------
snapshot_root() {
    local root="$1" snap="$2" rel
    [ -d "$root" ] || { echo "snapshot: root missing $root" >> "$RUN_LOG"; return 1; }
    mkdir -p -- "$snap" || return 1
    for rel in "${DEP_FILES[@]}" "${HDR_FILES[@]}"; do
        [ -f "$root/$rel" ] || { echo "snapshot: REQUIRED INPUT MISSING: $root/$rel" >> "$RUN_LOG"; return 1; }
        mkdir -p -- "$snap/$(dirname -- "$rel")" || return 1
        cp -p -- "$root/$rel" "$snap/$rel" || return 1
        cmp -s -- "$root/$rel" "$snap/$rel" || { echo "snapshot: source-copy mismatch: $rel" >> "$RUN_LOG"; return 1; }
    done
    [ -f "$TB_SRC" ] || { echo "snapshot: TB missing $TB_SRC" >> "$RUN_LOG"; return 1; }
    cp -p -- "$TB_SRC" "$snap/$TB_IN_SNAP" || return 1
    cmp -s -- "$TB_SRC" "$snap/$TB_IN_SNAP" || { echo "snapshot: source-copy mismatch: $TB_IN_SNAP" >> "$RUN_LOG"; return 1; }
    return 0
}

# Capture raw bytes to a private file, check original rc and exact ordered path list,
# only then normalize/sort. Never infer row count from command-substitution text.
MANIFEST_SEQ=0
snapshot_manifest() { # <snap> <raw-file> -> validated sorted manifest on stdout
    local snap="$1" raw="$2" rc
    ( cd -- "$snap" || exit 1
      sha256sum -- "${DEP_FILES[@]}" "${HDR_FILES[@]}" "$TB_IN_SNAP" ) >"$raw"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    python3 - "$raw" "${DEP_FILES[@]}" "${HDR_FILES[@]}" "$TB_IN_SNAP" <<'PY' || return 1
import pathlib,re,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); paths=sys.argv[2:]
if not b.endswith(b"\n") or b"\0" in b or b"\r" in b: raise SystemExit(1)
ls=b[:-1].split(b"\n")
if len(ls)!=len(paths): raise SystemExit(1)
seen=set()
for line,path in zip(ls,paths):
 m=re.fullmatch(rb"([0-9a-f]{64})  (.+)",line)
 if not m or m.group(2)!=path.encode() or path in seen: raise SystemExit(1)
 seen.add(path)
PY
    LC_ALL=C sort -- "$raw"
}
manifest_write() { # <snap> <outfile>; raw bytes retained next to output
    MANIFEST_SEQ=$((MANIFEST_SEQ + 1))
    snapshot_manifest "$1" "$RUN_DIR/manifest-$MANIFEST_SEQ.raw" >"$2"
}
manifest_matches() { # <snap> <reference> <tag>
    MANIFEST_SEQ=$((MANIFEST_SEQ + 1))
    local out="$RUN_DIR/manifest-check-$MANIFEST_SEQ.txt"
    snapshot_manifest "$1" "$RUN_DIR/manifest-check-$MANIFEST_SEQ.raw" >"$out" || return 1
    cmp -s "$2" "$out"
}

#------------------------------------------------------------------------------
# 5b. 在**快照 root 内、相对路径**编译（不用工作树 cwd 的任何 include）
#------------------------------------------------------------------------------
compile_root() {
    local snap="$1" vvp="$2" tag="$3" rel rc n sha_out n_lines n_ok missing=0
    [ -d "$snap" ] || { echo "[$tag] snapshot root missing: $snap" >> "$RUN_LOG"; return 1; }
    for rel in "${DEP_FILES[@]}" "${HDR_FILES[@]}"; do
        [ -f "$snap/$rel" ] || { echo "[$tag] MISSING snapshot input: $snap/$rel" >> "$RUN_LOG"; missing=1; }
    done
    [ -f "$snap/$TB_IN_SNAP" ] || { echo "[$tag] MISSING snapshot TB: $snap/$TB_IN_SNAP" >> "$RUN_LOG"; missing=1; }
    [ "$missing" -eq 0 ] || return 1

    MANIFEST_SEQ=$((MANIFEST_SEQ + 1))
    local raw="$RUN_DIR/manifest-compile-$MANIFEST_SEQ.raw"
    sha_out="$(snapshot_manifest "$snap" "$raw")"; rc=$?
    [ "$rc" -eq 0 ] || { echo "[$tag] snapshot_manifest rc=$rc (硬拒; raw=$raw)" >> "$RUN_LOG"; return 1; }
    n_lines="$(wc -l < "$raw")"
    if [ "$n_lines" -ne "$INPUT_N" ]; then
        echo "[$tag] sha256 raw line check failed lines=$n_lines expect=$INPUT_N" >> "$RUN_LOG"
        return 1
    fi
    {
        echo "-- [$tag] SNAPSHOT_ROOT = $snap"
        echo "-- [$tag] fixed inputs (${#DEP_FILES[@]} RTL + ${#HDR_FILES[@]} header + 1 TB = $INPUT_N) sha256 --"
        printf '%s\n' "$sha_out"
    } >> "$RUN_LOG"

    # 关键：cwd = 快照 root；相对 `-I` 与相对源路径 ⇒ 工作树头/cwd 不可能被借入
    #   ★ F4-1 接口宏：只有**新树**定义 `BACKEND_HAS_CSR_CHK`（新增 CSR 检查端口）；
    #     201 旧树不定义 ⇒ 同一 TB 用纯接口适配分支编译，**不改变黄金/不伪造执行**。
    local defs=""
    [ "$tag" = "old" ] || defs="-DBACKEND_HAS_CSR_CHK -DBACKEND_HAS_LSQ_F4"
    ( cd -- "$snap" && \
      timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 $defs -I rtl/pkg -I . \
              -s tb_backend_semantics -o "$vvp" "$TB_IN_SNAP" "${DEP_FILES[@]}" ) \
        > "$RUN_LOG.compile.$tag" 2>&1
    rc=$?
    cat -- "$RUN_LOG.compile.$tag" >> "$RUN_LOG" || return 1
    if [ "$rc" -eq 124 ]; then echo "[$tag] compile timeout" >> "$RUN_LOG"; return 124; fi
    if [ "$rc" -ne 0 ]; then echo "[$tag] compile rc=$rc" >> "$RUN_LOG"; return "$rc"; fi
    n=$(stat -c %s -- "$vvp" 2>/dev/null || echo 0)
    if [ ! -s "$vvp" ]; then echo "[$tag] compile rc=0 but zero-size vvp (need -s artifact)" >> "$RUN_LOG"; return 1; fi
    echo "[$tag] compile ok, vvp bytes=$n (cwd=$snap)" >> "$RUN_LOG"
    return 0
}

#------------------------------------------------------------------------------
# 6. CASE 记录**逐 token**严格解析：同一行重复/冲突也计入
#    输出： "<ncase> <name> <kind> <nvtot> <verdict> <nktot> <nkdistinct> <nnames> <nforeign>"
#------------------------------------------------------------------------------
parse_case_log() {
    awk -v want="$2" '
        /^CASE [0-9]+ / {
            c = $2 + 0
            if (c != want + 0) { foreign++; next }
            ncase++
            nm = $3; names[nm]++
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^KIND=/) {
                    k = $i; sub(/^KIND=/, "", k); sub(/[^a-z].*/, "", k); kinds[k]++; nktot++
                }
                if ($i ~ /^VERDICT=/) {
                    v = $i; sub(/^VERDICT=/, "", v); sub(/[^A-Z_].*/, "", v); vers[v]++; nvtot++
                }
            }
        }
        END {
            nkd = 0; for (x in kinds) { nkd++; kk = x }
            nnm = 0; for (x in names) { nnm++; kn = x }
            for (x in vers) kv = x
            printf "%d %s %s %d %s %d %d %d %d\n", ncase+0, kn, kk, nvtot+0, kv, nktot+0, nkd+0, nnm+0, foreign+0
        }
    ' "$1"
}

log_wellformed() {   # $1=log $2=case
    local rec ncase name kind nvtot verdict nktot nkd nnm foreign
    rec="$(parse_case_log "$1" "$2")"
    read -r ncase name kind nvtot verdict nktot nkd nnm foreign <<<"$rec"
    [ "$foreign" = "0" ] && [ "$ncase" -ge 1 ] && [ "$nvtot" = "1" ] && \
        [ "$nktot" = "1" ] && [ "$nkd" = "1" ] && [ "$nnm" = "1" ]
}

#------------------------------------------------------------------------------
# 7. 跑单向量并严格判定；通过时把 `VEC <tag> <case> …` 写 RUN_LOG
#------------------------------------------------------------------------------
run_one() {
    local vvp="$1" case="$2" expect="$3" tag="$4" extra="${5:-}" log rc rec
    local ncase name kind nvtot verdict nktot nkd nnm foreign exp_kind c
    log="$RUN_DIR/${tag}_case_${case}.log"
    timeout "$TIMEOUT_RUN_S" "$VV" "$vvp" "+CASE=$case" $extra > "$log" 2>&1; rc=$?
    if [ "$rc" -eq 124 ]; then echo "[$tag] case $case run timeout" >> "$RUN_LOG"; return 124; fi
    if [ "$rc" -ne 0 ]; then echo "[$tag] case $case run rc=$rc" >> "$RUN_LOG"; return "$rc"; fi
    [ -s "$log" ] || { echo "[$tag] case $case zero output" >> "$RUN_LOG"; return 1; }

    rec="$(parse_case_log "$log" "$case")"
    read -r ncase name kind nvtot verdict nktot nkd nnm foreign <<<"$rec"
    if [ "$foreign" != "0" ]; then
        echo "[$tag] case $case has foreign CASE record(s)=$foreign" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true; return 1
    fi
    if [ "$ncase" -lt 1 ] || [ "$nvtot" != "1" ] || [ "$nktot" != "1" ] || [ "$nkd" != "1" ] || [ "$nnm" != "1" ]; then
        echo "[$tag] case $case malformed records ncase=$ncase nVT=$nvtot nKT=$nktot nKD=$nkd nNM=$nnm" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true; return 1
    fi
    exp_kind=control
    for c in $TRIGGER_CASES; do [ "$c" = "$case" ] && exp_kind=trigger; done
    if [ "$kind" != "$exp_kind" ]; then
        echo "[$tag] case $case KIND=$kind expect=$exp_kind (TB/script drift)" >> "$RUN_LOG"; return 1
    fi
    if [ "$verdict" != "$expect" ]; then
        echo "[$tag] case $case VERDICT=$verdict expect=$expect" >> "$RUN_LOG"
        grep -E '^CASE ' "$log" >> "$RUN_LOG" || true; return 1
    fi
    cat -- "$log" >> "$RUN_LOG"
    printf 'VEC %s %s %s kind=%s verdict=%s\n' "$tag" "$case" "$name" "$kind" "$verdict" >> "$RUN_LOG"
    return 0
}

check_vec_lines() {
    local tag="$1" expect="$2" n bad
    n="$(grep -cE "^VEC ${tag} [0-9]+ [^ ]+ kind=(trigger|control) verdict=[A-Z_]+$" "$RUN_LOG" || true)"
    [ "$n" = "$expect" ] || emit_fail "vec_count_${tag}=$n expect=$expect"
    bad="$(awk -v t="$tag" '
        $1=="VEC" && $2==t {
            if ($0 !~ ("^VEC " t " [0-9]+ [^ ]+ kind=(trigger|control) verdict=[A-Z_]+$")) b++;
            seen[$3]++;
        }
        END { for (k in seen) if (seen[k]!=1) b++; printf "%d", b+0 }
    ' "$RUN_LOG")"
    [ "$bad" = "0" ] || emit_fail "vec_format_or_dup_${tag}=$bad"
}

#==============================================================================
# 8. 新源码：固定 26 输入快照 → 18 向量全 OK；快照前后清单必须相等
#==============================================================================
DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"
echo "DUT_ROOT        = $DUT_ROOT" >> "$RUN_LOG"
[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"

SNAP_NEW="$RUN_DIR/src-new"
snapshot_root "$DUT_ROOT" "$SNAP_NEW" || emit_fail "snapshot_new_failed root=$DUT_ROOT (missing fixed 26-input closure)"
echo "SNAP_NEW        = $SNAP_NEW" >> "$RUN_LOG"
manifest_write "$SNAP_NEW" "$RUN_DIR/man_new_before.txt" || emit_fail "manifest_new_before_failed"

compile_root "$SNAP_NEW" "$VVP_OUT" "new" || emit_fail "compile_new_failed"

OK_N=0; BAD_N=0
for c in $(seq 0 $((SPEC_TOTAL-1))); do
    if run_one "$VVP_OUT" "$c" "OK" "new"; then OK_N=$((OK_N+1)); else BAD_N=$((BAD_N+1)); fi
done
SUM_OK="$OK_N"; SUM_BAD="$BAD_N"
check_vec_lines "new" "$SPEC_TOTAL"
[ "$BAD_N" -eq 0 ] || emit_fail "new_source_bad_vectors=$BAD_N"
[ "$OK_N" -eq "$SPEC_TOTAL" ] || emit_fail "new_source_ok=$OK_N expect=$SPEC_TOTAL"
manifest_write "$SNAP_NEW" "$RUN_DIR/man_new_after.txt" || emit_fail "manifest_new_after_failed"
cmp -s "$RUN_DIR/man_new_before.txt" "$RUN_DIR/man_new_after.txt" || emit_fail "snapshot_new_mutated_during_run"

if [ "$NEG" -eq 0 ]; then
    printf 'BACKEND_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
           "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" "$BAD_N" >> "$RUN_LOG"
    printf 'FUNCTIONAL_BACKEND_SEMANTICS: PASS\n' >> "$RUN_LOG"
    N_SUM="$(grep -c '^BACKEND_VECTORS ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "1" ] || emit_fail "summary_count=$N_SUM"
    SUM_LINE="$(grep -m1 '^BACKEND_VECTORS ' "$RUN_LOG" || true)"
    if [[ "$SUM_LINE" =~ ^BACKEND_VECTORS\ total=([0-9]+)\ trigger=([0-9]+)\ control=([0-9]+)\ ok=([0-9]+)\ bad=([0-9]+)$ ]]; then
        { [ "${BASH_REMATCH[1]}" = "$SPEC_TOTAL" ] && [ "${BASH_REMATCH[2]}" = "$SPEC_TRIGGER" ] \
          && [ "${BASH_REMATCH[3]}" = "$SPEC_CONTROL" ] && [ "${BASH_REMATCH[4]}" = "$SPEC_TOTAL" ] \
          && [ "${BASH_REMATCH[5]}" = "0" ]; } || emit_fail "summary_fields_mismatch line=$SUM_LINE"
    else
        emit_fail "summary_format"
    fi
    [ "$(grep -c 'FAIL' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_FAIL"
    [ "$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_defect_reproduced"
    [ "$(grep -c 'DEFECT_SIG' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_DEFECT_SIG"
    [ "$(grep -cxF 'FUNCTIONAL_BACKEND_SEMANTICS: PASS' "$RUN_LOG" || true)" = "1" ] || emit_fail "pass_anchor_count"
    printf 'BACKEND_VECTORS total=%s trigger=%s control=%s ok=%s bad=%s\n' \
           "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" "$BAD_N"
    printf 'FUNCTIONAL_BACKEND_SEMANTICS: PASS\n'
    exit 0
fi

#==============================================================================
# 9. 反证模式（自测）：旧源码矩阵 + 收口反证
#==============================================================================
command -v git >/dev/null 2>&1 || emit_fail "tool_missing name=git (self-test)"
command -v tar >/dev/null 2>&1 || emit_fail "tool_missing name=tar (self-test)"

OLD_DIR="$RUN_DIR/old-$OLD_COMMIT"
OLD_TAR="$RUN_DIR/old-$OLD_COMMIT.tar"
mkdir -p -- "$OLD_DIR" || emit_fail "old_snapshot_mkdir_failed"
git -C "$REPO_ROOT" archive "$OLD_COMMIT" > "$OLD_TAR" 2>> "$RUN_LOG" || emit_fail "git_archive_failed"
tar -x -f "$OLD_TAR" -C "$OLD_DIR" >> "$RUN_LOG" 2>&1 || emit_fail "old_snapshot_extract_failed"
echo "OLD_DIR         = $OLD_DIR" >> "$RUN_LOG"

SNAP_OLD="$RUN_DIR/src-old"
snapshot_root "$OLD_DIR" "$SNAP_OLD" || emit_fail "snapshot_old_failed root=$OLD_DIR"
echo "SNAP_OLD        = $SNAP_OLD" >> "$RUN_LOG"
manifest_write "$SNAP_OLD" "$RUN_DIR/man_old_before.txt" || emit_fail "manifest_old_before_failed"
OLD_VVP="$RUN_DIR/tb_backend_semantics_old.vvp"
compile_root "$SNAP_OLD" "$OLD_VVP" "old" || emit_fail "compile_old_failed"

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
[ "$OLD_TRIG_BAD" -eq 0 ] || emit_fail "old_trigger_not_reproduced_bad=$OLD_TRIG_BAD"
[ "$OLD_TRIG_OK" -eq "$SPEC_TRIGGER" ] || emit_fail "old_trigger_ok=$OLD_TRIG_OK expect=$SPEC_TRIGGER"
[ "$OLD_CTL_BAD" -eq 0 ] || emit_fail "old_control_bad=$OLD_CTL_BAD"
[ "$OLD_CTL_OK" -eq "$SPEC_CONTROL" ] || emit_fail "old_control_ok=$OLD_CTL_OK expect=$SPEC_CONTROL"
manifest_write "$SNAP_OLD" "$RUN_DIR/man_old_after.txt" || emit_fail "manifest_old_after_failed"
cmp -s "$RUN_DIR/man_old_before.txt" "$RUN_DIR/man_old_after.txt" || emit_fail "snapshot_old_mutated_during_run"

#------------------------------------------------------------------------------
# 9b. 收口反证（parser 逐token / 闭包与 cwd+poison / sha rc / X 敏感）
#------------------------------------------------------------------------------
CP_P_OK=0;   CP_P_N=0
CP_C_OK=0;   CP_C_N=0
CP_S_OK=0;   CP_S_N=0
CP_X_OK=0;   CP_X_N=0

# (1) parser：逐 token 计；异号/重复 VERDICT（含同一行）/重复冲突 KIND（含同一行）必拒
FX="$RUN_DIR/fixtures"; mkdir -p -- "$FX"
printf 'CASE 3 M_CSRRW_MSTATUS KIND=control priv=11\nCASE 3 M_CSRRW_MSTATUS VERDICT=OK\n' > "$FX/good.log"
printf 'CASE 99 OTHER KIND=control\nCASE 99 OTHER VERDICT=OK\nCASE 3 M_CSRRW_MSTATUS KIND=control\nCASE 3 M_CSRRW_MSTATUS VERDICT=UNEXPECTED\n' > "$FX/mixed.log"
printf 'CASE 3 M_CSRRW_MSTATUS KIND=control\nCASE 3 M_CSRRW_MSTATUS VERDICT=OK\nCASE 3 M_CSRRW_MSTATUS VERDICT=OK\n' > "$FX/dupverdict.log"
printf 'CASE 3 M_CSRRW_MSTATUS KIND=trigger\nCASE 3 M_CSRRW_MSTATUS KIND=control\nCASE 3 M_CSRRW_MSTATUS VERDICT=OK\n' > "$FX/kindconf.log"
# 同一行内重复/冲突（行级 match 会漏，逐 token 必须拒）
printf 'CASE 3 M_CSRRW_MSTATUS KIND=control VERDICT=OK VERDICT=UNEXPECTED\n' > "$FX/sameline_verdict.log"
printf 'CASE 3 M_CSRRW_MSTATUS KIND=control KIND=trigger VERDICT=OK\n' > "$FX/sameline_kind.log"
for fx in good:accept mixed:reject dupverdict:reject kindconf:reject sameline_verdict:reject sameline_kind:reject; do
    f="${fx%%:*}"; want="${fx##*:}"; CP_P_N=$((CP_P_N+1))
    if log_wellformed "$FX/$f.log" 3; then got=accept; else got=reject; fi
    if [ "$got" = "$want" ]; then
        CP_P_OK=$((CP_P_OK+1)); printf 'CP parser %s got=%s want=%s pass\n' "$f" "$got" "$want" >> "$RUN_LOG"
    else
        printf 'CP parser %s got=%s want=%s REJECTED\n' "$f" "$got" "$want" >> "$RUN_LOG"
    fi
done

# (2a) "仅 RTL、缺 4 必要头"的 DUT_ROOT（真实 repo cwd 下函数级）必须被拒
FIX_ONLY="$RUN_DIR/fix-rtl-only"; mkdir -p -- "$FIX_ONLY"
for rel in "${DEP_FILES[@]}"; do mkdir -p -- "$FIX_ONLY/$(dirname -- "$rel")"; cp -p -- "$SNAP_NEW/$rel" "$FIX_ONLY/$rel"; done
CP_C_N=$((CP_C_N+1))
if ( cd -- "$REPO_ROOT" && snapshot_root "$FIX_ONLY" "$RUN_DIR/fix-only-snap" ); then
    printf 'CP closure rtl-only got=accept want=reject REJECTED\n' >> "$RUN_LOG"
else
    CP_C_OK=$((CP_C_OK+1)); printf 'CP closure rtl-only got=reject want=reject pass\n' >> "$RUN_LOG"
fi

# (2b) 完整快照从**任意 cwd**（/=）编译（正控）
CP_C_N=$((CP_C_N+1))
if ( cd / && compile_root "$SNAP_NEW" "$RUN_DIR/cp_foreign.vvp" "cp-foreign" ) \
   && manifest_matches "$SNAP_NEW" "$RUN_DIR/man_new_before.txt" cp_foreign; then
    CP_C_OK=$((CP_C_OK+1)); printf 'CP closure foreign-cwd got=accept want=accept pass\n' >> "$RUN_LOG"
else
    printf 'CP closure foreign-cwd got=reject want=accept REJECTED\n' >> "$RUN_LOG"
fi

# (2c) 私有 fixture 源根头（追加注释）被改 → 该快照编译不受影响
FIX_SRC="$RUN_DIR/fix-mut-src"; FIX_SNAP="$RUN_DIR/fix-mut-snap"
CP_C_N=$((CP_C_N+1))
if snapshot_root "$DUT_ROOT" "$FIX_SRC" && snapshot_root "$FIX_SRC" "$FIX_SNAP" \
   && manifest_write "$FIX_SNAP" "$RUN_DIR/man_mut_before.txt"; then
    printf '\n// FIXTURE-ONLY mutation (private fixture; NOT a repo header)\n' >> "$FIX_SRC/rtl/pkg/rv32_defs.vh"
    if ( cd / && compile_root "$FIX_SNAP" "$RUN_DIR/cp_mut.vvp" "cp-mut" ) \
       && manifest_write "$FIX_SNAP" "$RUN_DIR/man_mut_after.txt" \
       && cmp -s "$RUN_DIR/man_mut_before.txt" "$RUN_DIR/man_mut_after.txt" \
       && ! cmp -s -- "$FIX_SRC/rtl/pkg/rv32_defs.vh" "$FIX_SNAP/rtl/pkg/rv32_defs.vh"; then
        CP_C_OK=$((CP_C_OK+1)); printf 'CP closure mutation-isolated(comment) got=isolated want=isolated pass\n' >> "$RUN_LOG"
    else
        printf 'CP closure mutation-isolated(comment) got=leaked want=isolated REJECTED\n' >> "$RUN_LOG"
    fi
else
    printf 'CP closure mutation-isolated(comment) fixture_setup REJECTED\n' >> "$RUN_LOG"
fi

# (2d) 脚本级负控：外部 DUT_ROOT **仅 RTL、缺 4 必要头**，调用 cwd = 真实 repo ⇒ 必须拒
FIX_ONLY_SNAP_OUT="$RUN_DIR/cp_ext_rtlonly.out"
CP_C_N=$((CP_C_N+1))
if ( cd -- "$REPO_ROOT" && \
     DUT_ROOT="$FIX_ONLY" RV32_BACKEND_SEMANTICS_MODE=spec OUT_DIR="$RUN_DIR/cp-sub-rtlonly" \
     bash "$SELF_ABS" ) > "$FIX_ONLY_SNAP_OUT" 2>&1; then
    printf 'CP closure script-ext-rtlonly got=accept want=reject REJECTED\n' >> "$RUN_LOG"
else
    if grep -q 'snapshot_new_failed' "$FIX_ONLY_SNAP_OUT" \
       && ! grep -qxF 'FUNCTIONAL_BACKEND_SEMANTICS: PASS' "$FIX_ONLY_SNAP_OUT"; then
        CP_C_OK=$((CP_C_OK+1))
        printf 'CP closure script-ext-rtlonly got=reject(snapshot_new_failed) want=reject pass\n' >> "$RUN_LOG"
    else
        printf 'CP closure script-ext-rtlonly got=reject_other want=reject REJECTED\n' >> "$RUN_LOG"
        cat -- "$FIX_ONLY_SNAP_OUT" >> "$RUN_LOG"
    fi
fi

# (2e) 脚本级正控：**完整源根快照 + 异地 cwd** ⇒ 必须 PASS（与 2d 明确区分）
FIX_COMPLETE="$RUN_DIR/fix-complete"
FIX_COMPLETE_OUT="$RUN_DIR/cp_foreign_script.out"
CP_C_N=$((CP_C_N+1))
if snapshot_root "$SNAP_NEW" "$FIX_COMPLETE" \
   && ( cd / && DUT_ROOT="$FIX_COMPLETE" RV32_BACKEND_SEMANTICS_MODE=spec \
        OUT_DIR="$RUN_DIR/cp-sub-complete" bash "$SELF_ABS" ) > "$FIX_COMPLETE_OUT" 2>&1 \
   && [ "$(grep -cxF 'FUNCTIONAL_BACKEND_SEMANTICS: PASS' "$FIX_COMPLETE_OUT" || true)" = "1" ]; then
    CP_C_OK=$((CP_C_OK+1))
    printf 'CP closure script-complete-foreign-cwd got=accept want=accept pass\n' >> "$RUN_LOG"
else
    printf 'CP closure script-complete-foreign-cwd got=reject want=accept REJECTED\n' >> "$RUN_LOG"
    cat -- "$FIX_COMPLETE_OUT" >> "$RUN_LOG"
fi

# (2f) poison-cwd：私有 cwd 里放**冲突头**（rv32_defs.vh 清空），先证它会命中"回退 cd"
#      口径（cwd + 相对 -I），再证真 compile_root（cd 进快照）不受影响。
POISON="$RUN_DIR/poison-cwd"
mkdir -p -- "$POISON/rtl/pkg" "$POISON/rtl/back2" "$POISON/rtl/front4"
cp -p -- "$SNAP_NEW/rtl/pkg/core_params.vh"    "$POISON/rtl/pkg/"
cp -p -- "$SNAP_NEW/rtl/back2/back2_params.vh" "$POISON/rtl/back2/"
cp -p -- "$SNAP_NEW/rtl/front4/front4_params.vh" "$POISON/rtl/front4/"
: > "$POISON/rtl/pkg/rv32_defs.vh"     # 毒：清空（与真头冲突）
DEPS_ABS=(); for rel in "${DEP_FILES[@]}"; do DEPS_ABS+=( "$SNAP_NEW/$rel" ); done

# (2f-i) 毒头**确实**影响"回退 cd"口径：cwd=POISON + 相对 -I + 快照绝对源 ⇒ 必失败
CP_C_N=$((CP_C_N+1))
( cd -- "$POISON" && "$IV" -g2012 -I rtl/pkg -I . -s tb_backend_semantics \
    -o "$RUN_DIR/poison_removedcd.vvp" "$SNAP_NEW/$TB_IN_SNAP" "${DEPS_ABS[@]}" ) \
    > "$RUN_DIR/poison_removedcd.log" 2>&1
if [ $? -ne 0 ]; then
    CP_C_OK=$((CP_C_OK+1)); printf 'CP closure poison-effective(cd-removed fails) got=fail want=fail pass\n' >> "$RUN_LOG"
else
    printf 'CP closure poison-effective(cd-removed fails) got=pass want=fail REJECTED\n' >> "$RUN_LOG"
fi

# (2f-ii) 同一命令、POISON 头换回真头 ⇒ 成功（证明上一步失败确由毒头引起）
CP_C_N=$((CP_C_N+1))
cp -p -- "$SNAP_NEW/rtl/pkg/rv32_defs.vh" "$POISON/rtl/pkg/rv32_defs.vh"
( cd -- "$POISON" && "$IV" -g2012 -I rtl/pkg -I . -s tb_backend_semantics \
    -o "$RUN_DIR/poison_realhdr.vvp" "$SNAP_NEW/$TB_IN_SNAP" "${DEPS_ABS[@]}" ) \
    > "$RUN_DIR/poison_realhdr.log" 2>&1
if [ $? -eq 0 ]; then
    CP_C_OK=$((CP_C_OK+1)); printf 'CP closure poison-cause-isolated(cd-removed ok with real) got=ok want=ok pass\n' >> "$RUN_LOG"
else
    printf 'CP closure poison-cause-isolated(cd-removed ok with real) got=fail want=ok REJECTED\n' >> "$RUN_LOG"
fi

# (2f-iii) **重新武装毒头**后验证第三步：① "回退 cd" 变异（cwd=POISON + 相对 -I）必须
#          仍失败（毒头生效）；② 真 compile_root 从**毒 cwd** 必须成功且快照清单不变。
#          （上一版第 2 步换回真头后未复毒，第三步实际跑在真头环境 —— 现补状态恢复。）
CP_C_N=$((CP_C_N+1))
: > "$POISON/rtl/pkg/rv32_defs.vh"     # re-arm：第三步必须在毒头生效下验证
( cd -- "$POISON" && "$IV" -g2012 -I rtl/pkg -I . -s tb_backend_semantics \
    -o "$RUN_DIR/poison_removedcd2.vvp" "$SNAP_NEW/$TB_IN_SNAP" "${DEPS_ABS[@]}" ) \
    > "$RUN_DIR/poison_removedcd2.log" 2>&1
rc_cdremoved2=$?
if [ "$rc_cdremoved2" -ne 0 ] \
   && ( cd -- "$POISON" && compile_root "$SNAP_NEW" "$RUN_DIR/cp_poison.vvp" "cp-poison" ) \
   && manifest_matches "$SNAP_NEW" "$RUN_DIR/man_new_before.txt" cp_foreign; then
    CP_C_OK=$((CP_C_OK+1))
    printf 'CP closure poison-rearmed(cd-removed fails & snapshot ok) got=fail+accept want=fail+accept pass (poison=re-armed)\n' >> "$RUN_LOG"
else
    printf 'CP closure poison-rearmed(cd-removed fails & snapshot ok) got=rc_cdremoved=%s want=fail+accept REJECTED\n' "$rc_cdremoved2" >> "$RUN_LOG"
fi

# (3) sha256sum 非零但输出完整正确 26 行 ⇒ 必须硬拒（不靠 pipefail 吞 rc）
FAKEBIN="$RUN_DIR/fakebin-nzsha"; mkdir -p -- "$FAKEBIN"
{
    printf '#!/usr/bin/env bash\n'
    printf '"%s" "$@"\n' "$REAL_SHA"
    printf 'exit 9\n'
} > "$FAKEBIN/sha256sum"
chmod 0755 "$FAKEBIN/sha256sum"
CP_S_N=$((CP_S_N+1))
( cd -- "$SNAP_NEW" && PATH="$FAKEBIN:$PATH" sha256sum -- "${DEP_FILES[@]}" "${HDR_FILES[@]}" "$TB_IN_SNAP" ) \
    > "$RUN_DIR/fake_sha.raw" 2>&1
fake_rc=$?
fake_lines="$(grep -cE '^[0-9a-f]{64}  ' "$RUN_DIR/fake_sha.raw" || true)"
if [ "$fake_rc" -eq 9 ] && [ "$fake_lines" -eq "$INPUT_N" ]; then
    if PATH="$FAKEBIN:$PATH" snapshot_manifest "$SNAP_NEW" "$RUN_DIR/fake_sha.selftest.raw" \
        > "$RUN_DIR/fake_sha.manifest" 2>&1; then
        printf 'CP sha nonzero-full-output got=accept want=reject REJECTED\n' >> "$RUN_LOG"
    else
        CP_S_OK=$((CP_S_OK+1))
        printf 'CP sha nonzero-full-output got=reject want=reject pass (raw_rc=9 raw_lines=%s)\n' "$fake_lines" >> "$RUN_LOG"
    fi
else
    printf 'CP sha nonzero-full-output precondition_failed raw_rc=%s raw_lines=%s REJECTED\n' "$fake_rc" "$fake_lines" >> "$RUN_LOG"
fi

# Exercise the actual default-package manifest_write caller (26 fixed inputs).
# Each fake tool passes through real output, mutates only the 26-input invocation,
# and the child must fail specifically at manifest_new_before before compile/vvp.
SHA_MATRIX_BIN="$RUN_DIR/sha-matrix-bin"; mkdir -p -- "$SHA_MATRIX_BIN"
cat > "$SHA_MATRIX_BIN/sha256sum" <<'SH'
#!/usr/bin/env bash
"$REAL_SHA_ORIG" "$@" >"$SHA_MATRIX_RAW"; rc=$?
if [ "$#" -ne 27 ]; then cat -- "$SHA_MATRIX_RAW"; exit "$rc"; fi
python3 - "$SHA_MATRIX_RAW" "$SHA_MATRIX_MODE" <<'PY'
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
if [ "$SHA_MATRIX_MODE" = exit9 ]; then exit 9; else exit "$rc"; fi
SH
chmod +x "$SHA_MATRIX_BIN/sha256sum"
for hm in extra1 blanks unterminated wrongpath garbage nulcr exit9; do
    CP_S_N=$((CP_S_N+1))
    out="$RUN_DIR/sha-matrix-$hm.out"
    env PATH="$SHA_MATRIX_BIN:$PATH" REAL_SHA_ORIG="$REAL_SHA" \
        SHA_MATRIX_RAW="$RUN_DIR/sha-matrix-$hm.raw" SHA_MATRIX_MODE="$hm" \
        RV32_BACKEND_SEMANTICS_MODE=spec OUT_DIR="$RUN_DIR/sha-matrix-$hm-out" \
        bash "$SELF_ABS" >"$out" 2>&1
    hm_rc=$?
    if [ "$hm_rc" -eq 1 ] && grep -q 'reason=manifest_new_before_failed' "$out" \
       && ! grep -qxF 'FUNCTIONAL_BACKEND_SEMANTICS: PASS' "$out"; then
        CP_S_OK=$((CP_S_OK+1))
        printf 'CP sha actual-manifest caller mode=%s rc=%s reason=manifest_new_before_failed pass\\n' "$hm" "$hm_rc" >> "$RUN_LOG"
    else
        printf 'CP sha actual-manifest caller mode=%s rc=%s REJECTED\\n' "$hm" "$hm_rc" >> "$RUN_LOG"
        cat -- "$out" >> "$RUN_LOG"
    fi
done

# (4) X 敏感：csr_we/commit_valid/fprf_we 注 X ⇒ XZ；XINJ=0 正控 ⇒ OK
for spec in "1:XZ" "2:XZ" "3:XZ" "0:OK"; do
    x="${spec%%:*}"; want="${spec##*:}"; CP_X_N=$((CP_X_N+1))
    xlog="$RUN_DIR/xchk_${x}.log"
    timeout "$TIMEOUT_RUN_S" "$VV" "$VVP_OUT" "+CASE=3" "+XINJ=$x" > "$xlog" 2>&1
    if [ $? -eq 0 ] && [ -s "$xlog" ]; then
        rec="$(parse_case_log "$xlog" 3)"
        read -r ncase name kind nvtot verdict nktot nkd nnm foreign <<<"$rec"
        if [ "$foreign" = "0" ] && [ "$nvtot" = "1" ] && [ "$verdict" = "$want" ]; then
            CP_X_OK=$((CP_X_OK+1))
            printf 'CP xinj XINJ=%s got=%s want=%s pass\n' "$x" "$verdict" "$want" >> "$RUN_LOG"
            cat -- "$xlog" >> "$RUN_LOG"
            continue
        fi
    fi
    printf 'CP xinj XINJ=%s got=? want=%s REJECTED\n' "$x" "$want" >> "$RUN_LOG"
done

CP_TOTAL=$((CP_P_N + CP_C_N + CP_S_N + CP_X_N)); CP_OK=$((CP_P_OK + CP_C_OK + CP_S_OK + CP_X_OK))
printf 'BACKEND_COUNTERPROOFS parser=%s/%s closure=%s/%s sha=%s/%s xinj=%s/%s total=%s/%s\n' \
       "$CP_P_OK" "$CP_P_N" "$CP_C_OK" "$CP_C_N" "$CP_S_OK" "$CP_S_N" "$CP_X_OK" "$CP_X_N" "$CP_OK" "$CP_TOTAL" \
       >> "$RUN_LOG"
[ "$CP_P_OK" -eq "$CP_P_N" ] || emit_fail "counterproof_parser=$CP_P_OK/$CP_P_N"
[ "$CP_C_OK" -eq "$CP_C_N" ] || emit_fail "counterproof_closure=$CP_C_OK/$CP_C_N"
[ "$CP_S_OK" -eq "$CP_S_N" ] || emit_fail "counterproof_sha=$CP_S_OK/$CP_S_N"
[ "$CP_X_OK" -eq "$CP_X_N" ] || emit_fail "counterproof_xinj=$CP_X_OK/$CP_X_N"
[ "$CP_OK" -eq "$CP_TOTAL" ] || emit_fail "counterproof_total=$CP_OK/$CP_TOTAL"

printf 'BACKEND_NEGATIVE_MATRIX old_trigger=%s/%s old_control=%s/%s new_ok=%s/%s commit=%s\n' \
       "$OLD_TRIG_OK" "$SPEC_TRIGGER" "$OLD_CTL_OK" "$SPEC_CONTROL" "$OK_N" "$SPEC_TOTAL" "$OLD_COMMIT" >> "$RUN_LOG"

[ "$(grep -c 'FAIL' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_FAIL"
[ "$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_defect_reproduced"
N_SUM="$(grep -c '^BACKEND_NEGATIVE_MATRIX ' "$RUN_LOG" || true)"
[ "$N_SUM" = "1" ] || emit_fail "neg_summary_count=$N_SUM"
SUM_LINE="$(grep -m1 '^BACKEND_NEGATIVE_MATRIX ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^BACKEND_NEGATIVE_MATRIX\ old_trigger=([0-9]+)/([0-9]+)\ old_control=([0-9]+)/([0-9]+)\ new_ok=([0-9]+)/([0-9]+)\ commit=([0-9a-f]+)$ ]]; then
    { [ "${BASH_REMATCH[1]}" = "$SPEC_TRIGGER" ] && [ "${BASH_REMATCH[2]}" = "$SPEC_TRIGGER" ] \
      && [ "${BASH_REMATCH[3]}" = "$SPEC_CONTROL" ] && [ "${BASH_REMATCH[4]}" = "$SPEC_CONTROL" ] \
      && [ "${BASH_REMATCH[5]}" = "$SPEC_TOTAL" ] && [ "${BASH_REMATCH[6]}" = "$SPEC_TOTAL" ] \
      && [ "${BASH_REMATCH[7]}" = "$OLD_COMMIT" ]; } || emit_fail "neg_summary_fields_mismatch line=$SUM_LINE"
else
    emit_fail "neg_summary_format"
fi
[ "$(grep -cxF 'FUNCTIONAL_BACKEND_SEMANTICS: PASS' "$RUN_LOG" || true)" = "0" ] || emit_fail "default_anchor_in_selftest"
printf 'FUNCTIONAL_BACKEND_SEMANTICS_NEGATIVE: PASS\n' >> "$RUN_LOG"
[ "$(grep -cxF 'FUNCTIONAL_BACKEND_SEMANTICS_NEGATIVE: PASS' "$RUN_LOG" || true)" = "1" ] || emit_fail "negative_anchor_count"

printf 'BACKEND_COUNTERPROOFS parser=%s/%s closure=%s/%s sha=%s/%s xinj=%s/%s total=%s/%s\n' \
       "$CP_P_OK" "$CP_P_N" "$CP_C_OK" "$CP_C_N" "$CP_S_OK" "$CP_S_N" "$CP_X_OK" "$CP_X_N" "$CP_OK" "$CP_TOTAL"
printf 'BACKEND_NEGATIVE_MATRIX old_trigger=%s/%s old_control=%s/%s new_ok=%s/%s commit=%s\n' \
       "$OLD_TRIG_OK" "$SPEC_TRIGGER" "$OLD_CTL_OK" "$SPEC_CONTROL" "$OK_N" "$SPEC_TOTAL" "$OLD_COMMIT"
printf 'FUNCTIONAL_BACKEND_SEMANTICS_NEGATIVE: PASS\n'
exit 0
