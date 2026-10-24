#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_backend_permission.sh —— F4-1 后端程序序 CSR/特权权限测试
#==============================================================================
# 判定（fail-closed；全部满足才打印唯一 PASS 锚点）:
#   · 固定 31 输入闭包（23 RTL + 4 header + 1 TB + env/script/e25-fixture 三 aux）逐个存在 + SHA 清单 rc=0；
#     copy 前 live source manifest 与副本按相对路径逐项 hash 相等；source/snapshot pre/post 再相等。
#   · 在快照 root 内、相对路径编译；新树定义 `BACKEND_HAS_CSR_CHK/BACKEND_HAS_LSQ_F4/
#     BACKEND_HAS_PMP`（纯接口宏）。
#   · 逐向量 CASE 0..32：每例恰好 1 个 KIND、VERDICT，且KIND符合固定树规格；
#     新树33/33 `VERDICT=OK`，KIND实数计数12/21，零 DEFECT_SIG/FAIL。
#   · 反证（`--negative`/`--self-test`）: `git archive 201acf6` 现场快照，**不定义**
#     接口宏；同一 TB：12 触发例 DEFECT_SIG、13 控制例 OK（case25 为 new-only）。
#   · 旧 3fd 候选对照：**正式 fixture** sim/functional/fixtures/backend_permission_3fd/
#     rtl/back2/backend_top.v（原样 SHA 3fd40417…b05b5）；从本脚本 SNAP_NEW 冻结
#     closure 派生并替换该 fixture，在自有 snapshot 编译。17/18 DEFECT_SIG，其余
#     0..22 的 21 例 OK；缺/改 fixture 硬 FAIL + exit9，不 SKIP、不回退 ignored root。
#   · 固定规格：new 33(12 trig/21 ctl，含 new-only cases)/201 25(12/13)/
#     3fd fixture 23(2/21)；e25 fixture SHA固定并运行6红+1控制；哈希行验证原rc与精确path。
#   · 任何缺失/超时/解析失败/未知 CASE 都直接失败，不打印 PASS。
#
# 产物：build/functional/backend-permission/run-XXXXXXXX（每次独占；不删除历史）。
# 工具：只从 scripts/env.sh 取 RV32_IVERILOG/RV32_VVP；可被同名环境变量覆盖。
#==============================================================================
set -u

NEG=0
CHECK_FIXTURE=0
SHA_SELF=0
PARSER_SELF=0
if [ "$#" -gt 1 ]; then
    printf 'FUNCTIONAL_BACKEND_PERMISSION: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test|--negative) NEG=1 ;;
        --check-3fd-fixture) CHECK_FIXTURE=1 ;;
        --sha-self-test) SHA_SELF=1 ;;
        --parser-self-test) PARSER_SELF=1 ;;
        *) printf 'FUNCTIONAL_BACKEND_PERMISSION: FAIL reason=unknown_arg argv=%s\n' "$1"; exit 1 ;;
    esac
fi

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_BACKEND_PERMISSION: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_BACKEND_PERMISSION: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_backend_permission.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

SPEC_TOTAL=33            # new：0..32（26..29 no-write，30 非零编码零值真写，31/32 RAS call/ret）
SPEC_TRIGGER=12
SPEC_CONTROL=21
NEW_ONLY_CASES="25 26 27 28 29 30 31 32"
OLD201_TOTAL=25          # 201：0..24（无 PMP 口，跳过 case25）
OLD201_TRIGGER=12
OLD201_CONTROL=13
OLD3FD_TOTAL=23          # 3fd fixture：0..22
OLD3FD_TRIGGER=2
OLD3FD_CONTROL=21
TRIGGER_CASES="1 3 4 5 8 12 14 15 17 18 20 23"
OLD_COMMIT="201acf61e118a3fb533e1a96768687a35efa1751"
OLD3FD_SHA=3fd40417134b9b79089602ccfce387a737ba1f91205b6005d2060c529a3b08a7
OLD_E25_SHA=e25b89419a8206027711a508935b0b4663ba7913c2e4281a462f3fb2277f769d
OLD_E25_SOURCE="$SELF_DIR/fixtures/backend_permission_e25/rtl/back2/backend_top.v"
FIXTURE_3FD="${RV32_BACKEND_3FD_FIXTURE:-$SELF_DIR/fixtures/backend_permission_3fd/rtl/back2/backend_top.v}"
TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-600}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-120}"

DEP_FILES=(
    rtl/back2/backend_top.v rtl/back2/rename.v rtl/back2/rob.v rtl/back2/rob_wide_mem.v
    rtl/back2/iq.v rtl/back2/prf.v rtl/back2/lsq_simple.v
    rtl/front4/bpu_ras.v
    rtl/decode/decoder.v rtl/decode/dec_csr.v rtl/decode/dec_imm.v rtl/decode/compressed_expand.v
    rtl/exec/alu.v rtl/exec/bru.v rtl/exec/mdu.v rtl/exec/fpu.v rtl/exec/fpu_add.v
    rtl/exec/fpu_mul.v rtl/exec/fpu_div_sqrt.v rtl/exec/fpu_cmp.v rtl/exec/fpu_cvt.v
    rtl/exec/fpu_fma_shared.v rtl/csr/csr_file.v
)
HDR_FILES=(
    rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh
    rtl/back2/back2_params.vh rtl/front4/front4_params.vh
)
AUX_FILES=(scripts/env.sh sim/functional/test_backend_permission.sh sim/functional/fixtures/backend_permission_e25/rtl/back2/backend_top.v)
INPUT_N=$(( ${#DEP_FILES[@]} + ${#HDR_FILES[@]} + 1 + ${#AUX_FILES[@]} ))
TB_IN_SNAP="sim/functional/tb_backend_permission.sv"

RUN_DIR=""
emit_fail() {
    if [ "$NEG" -eq 1 ]; then
        printf 'FUNCTIONAL_BACKEND_PERMISSION_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    else
        printf 'BACKEND_PERMISSION_VECTORS total=%s trigger=%s control=%s ok=- bad=-\n' \
               "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL"
        printf 'FUNCTIONAL_BACKEND_PERMISSION: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/backend-permission}}"
is_authorized() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_readlink_failed root=$ROOT_RAW"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM"
mkdir -p -- "$ROOT_NORM" || emit_fail "out_root_mkdir_failed"
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail "out_root_recheck_failed"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized_after_mkdir"
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail "mktemp_run_dir_failed"
RUN_LOG="$RUN_DIR/test_backend_permission.log"
VVP_OUT="$RUN_DIR/tb_backend_permission.vvp"
printf 'BACKEND_PERMISSION_RUN_DIR=%s\n' "$RUN_DIR"
: > "$RUN_LOG" || emit_fail "run_log_create_failed"
{
    echo "==== test_backend_permission.sh : F4-1 backend permission ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "MODE            = $([ "$NEG" -eq 1 ] && echo self-test || echo spec)"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "FIXED_INPUTS    = ${#DEP_FILES[@]} RTL + ${#HDR_FILES[@]} header + 1 TB + ${#AUX_FILES[@]} aux = $INPUT_N"
    echo "OLD_COMMIT      = $OLD_COMMIT"
    echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "=========================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

[ -r "$ENV_SH" ] || emit_fail "env_sh_unreadable"
command -v timeout >/dev/null 2>&1 || emit_fail "tool_missing timeout"
command -v sha256sum >/dev/null 2>&1 || emit_fail "tool_missing sha256sum"
REAL_SHA="$(command -v sha256sum)"

#   ★ 哈希行必须：sha256sum 原 rc=0、恰好一行、64 hex + 双空格 + **精确 path**、
#     不取首字段、不接受空/固定诊断串。所有 manifest 与 fixture 都走这里。
hash_line_parse() {   # line path [expect_sha]
    local line="$1" path="$2" expect="${3:-}" hex
    printf '%s\n' "$line" | LC_ALL=C grep -Eq '^[0-9a-f]{64}  [^ ].*$' || return 1
    hex="${line%% *}"
    [ "${#hex}" -eq 64 ] || return 1
    case "$line" in "$hex  $path") ;; *) return 1 ;; esac
    [ -z "$expect" ] || [ "$hex" = "$expect" ] || return 1
    return 0
}
hash_line_exact() {   # path [expect_sha] -> prints the exact hash line
    local LC_ALL=C
    local path="$1" expect="${2:-}" raw line rc nlines nbytes expected_bytes last
    [ -f "$path" ] || return 1
    raw="$(mktemp -- "$RUN_DIR/.sha-raw.XXXXXXXX")" || return 1
    "$REAL_SHA" -- "$path" >"$raw" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f -- "$raw"; return 1; }
    nlines="$(wc -l <"$raw")" || { rm -f -- "$raw"; return 1; }
    nbytes="$(wc -c <"$raw")" || { rm -f -- "$raw"; return 1; }
    [ "$nlines" -eq 1 ] || { rm -f -- "$raw"; return 1; }
    IFS= read -r line <"$raw" || { rm -f -- "$raw"; return 1; }
    expected_bytes=$((${#line} + 1))
    last="$(tail -c 1 -- "$raw" | od -An -tx1 | tr -d ' \n')"
    [ "$nbytes" -eq "$expected_bytes" ] && [ "$last" = 0a ] || { rm -f -- "$raw"; return 1; }
    hash_line_parse "$line" "$path" "$expect" || { rm -f -- "$raw"; return 1; }
    rm -f -- "$raw"
    printf '%s\n' "$line"
}
fixture_3fd_check() {
    local line
    [ -f "$FIXTURE_3FD" ] || return 1
    line="$(hash_line_exact "$FIXTURE_3FD" "$OLD3FD_SHA")" || return 1
    [ -n "$line" ] || return 1
    return 0
}
sha_selftest() {
    local d real mode name ok=0 total=0 snap got
    d="$RUN_DIR/sha-self-test"; mkdir -p -- "$d" || return 1
    real="$REAL_SHA"
    cat > "$d/sha256sum" <<'EOS'
#!/bin/sh
out="$("$FAKE_REAL_SHA" "$@")" || exit $?
case "$FAKE_SHA_MODE" in
  valid) printf '%s\n' "$out" ;;
  extra_lf) printf '%s\n\n' "$out" ;;
  multi_blank) printf '%s\n\n\n' "$out" ;;
  unterminated) printf '%s' "$out" ;;
  wrongpath) printf '%s\n' "${out% *}  /wrong/path" ;;
  garbage) printf '%s\nJUNK\n' "$out" ;;
  nul) printf '%s\n' "$out"; printf '\0' ;;
  stdout_rc9) printf '%s\n' "$out"; exit 9 ;;
esac
EOS
    chmod +x "$d/sha256sum" || return 1
    REAL_SHA="$d/sha256sum"; export FAKE_REAL_SHA="$real"
    for mode in valid extra_lf multi_blank unterminated wrongpath garbage nul stdout_rc9; do
        FAKE_SHA_MODE="$mode"; export FAKE_SHA_MODE
        total=$((total + 1))
        if [ "$mode" = valid ]; then
            if hash_line_exact "$FIXTURE_3FD" "$OLD3FD_SHA" >/dev/null; then ok=$((ok + 1)); printf 'BACKEND_SHA_META: mode=valid raw_reason=single_LF accept=OK\n'; fi
        elif hash_line_exact "$FIXTURE_3FD" "$OLD3FD_SHA" >/dev/null 2>&1; then
            printf 'BACKEND_SHA_META: mode=%s expected=reject got=accept\n' "$mode"
        else
            ok=$((ok + 1)); printf 'BACKEND_SHA_META: mode=%s expected=reject got=reject\n' "$mode"
        fi
    done
    # Also exercise the true fixture identity caller for valid and malformed stdout.
    FAKE_SHA_MODE=valid; export FAKE_SHA_MODE; total=$((total + 1))
    if fixture_3fd_check; then ok=$((ok + 1)); printf 'BACKEND_SHA_META: fixture_valid raw_reason=single_LF accept=OK\n'; fi
    FAKE_SHA_MODE=extra_lf; export FAKE_SHA_MODE; total=$((total + 1))
    if fixture_3fd_check; then printf 'BACKEND_SHA_META: fixture_extra_lf expected=reject got=accept\n'; else ok=$((ok + 1)); printf 'BACKEND_SHA_META: fixture_extra_lf expected=reject got=reject\n'; fi
    # The real manifest_write -> snapshot_manifest pre/post chain uses the same actual helper.
    snap="$d/snap"
    snapshot_root "$REPO_ROOT" "$snap" || return 1
    for mode in valid extra_lf multi_blank unterminated wrongpath garbage nul stdout_rc9; do
        FAKE_SHA_MODE="$mode"; export FAKE_SHA_MODE; total=$((total + 1))
        if manifest_write "$snap" "$d/manifest_${mode}.txt" >/dev/null 2>&1; then got=0; else got=1; fi
        if [ "$mode" = valid ]; then
            if [ "$got" -eq 0 ]; then ok=$((ok + 1)); printf 'BACKEND_SHA_META: manifest mode=valid raw_reason=single_LF accept=OK\n'; else printf 'BACKEND_SHA_META: manifest mode=%s expected=accept got=reject\n' "$mode"; fi
        elif [ "$got" -ne 0 ]; then ok=$((ok + 1)); printf 'BACKEND_SHA_META: manifest mode=%s raw_reason=invalid_sha_line reject=OK\n' "$mode"
        else printf 'BACKEND_SHA_META: manifest mode=%s expected=reject got=accept\n' "$mode"; fi
    done
    REAL_SHA="$real"
    printf 'BACKEND_SHA_META_SUMMARY: total=%s ok=%s bad=%s\n' "$total" "$ok" "$((total-ok))"
    [ "$ok" -eq "$total" ]
}
emit_fixture_fail() {
    if [ "$NEG" -eq 1 ]; then
        printf 'FUNCTIONAL_BACKEND_PERMISSION_NEGATIVE: FAIL reason=%s run_dir=%s\n' \
               "$1" "${RUN_DIR:-<none>}"
    else
        printf 'FUNCTIONAL_BACKEND_PERMISSION: FAIL reason=%s run_dir=%s\n' \
               "$1" "${RUN_DIR:-<none>}"
    fi
    exit 9
}

if [ "$CHECK_FIXTURE" -eq 1 ]; then
    if fixture_3fd_check; then
        printf 'FUNCTIONAL_BACKEND_PERMISSION_FIXTURE: PASS path=%s sha=%s\n' \
               "$FIXTURE_3FD" "$OLD3FD_SHA"
        exit 0
    fi
    printf 'FUNCTIONAL_BACKEND_PERMISSION_FIXTURE: FAIL reason=fixture_3fd_missing_or_sha path=%s\n' \
           "$FIXTURE_3FD"
    exit 9
fi

#   ★ 3fd fixture 是包的一部分：缺/改在**任何 PASS 之前**硬失败（exit 9），
#     不允许先打印 new/negative PASS 再 SKIP；spec 与 self-test 都一样。
if ! fixture_3fd_check; then
    emit_fixture_fail "fixture_3fd_missing_or_sha path=$FIXTURE_3FD"
fi

snapshot_root() {   # root snap
    local root="$1" snap="$2" rel
    [ -d "$root" ] || return 1
    mkdir -p -- "$snap" || return 1
    for rel in "${DEP_FILES[@]}" "${HDR_FILES[@]}"; do
        [ -f "$root/$rel" ] || { echo "snapshot: MISSING $root/$rel" >> "$RUN_LOG"; return 1; }
        mkdir -p -- "$snap/$(dirname -- "$rel")" || return 1
        cp -p -- "$root/$rel" "$snap/$rel" || return 1
    done
    [ -f "$TB_SRC" ] || return 1
    mkdir -p -- "$snap/$(dirname -- "$TB_IN_SNAP")" || return 1
    cp -p -- "$TB_SRC" "$snap/$TB_IN_SNAP" || return 1
    for rel in "${AUX_FILES[@]}"; do
        [ -f "$REPO_ROOT/$rel" ] || { echo "snapshot: MISSING auxiliary $REPO_ROOT/$rel" >> "$RUN_LOG"; return 1; }
        mkdir -p -- "$snap/$(dirname -- "$rel")" || return 1
        cp -p -- "$REPO_ROOT/$rel" "$snap/$rel" || return 1
    done
    return 0
}
snapshot_manifest() {   # snap -> exact per-file hash lines, sorted
    local snap="$1" rel line tmp rc
    tmp="$RUN_DIR/.manifest.$$.$RANDOM"
    ( cd -- "$snap" || exit 1
      for rel in "${DEP_FILES[@]}" "${HDR_FILES[@]}" "$TB_IN_SNAP" "${AUX_FILES[@]}"; do
          line="$(hash_line_exact "$rel" || exit 1)" || exit 1
          printf '%s\n' "$line" || exit 1
      done ) > "$tmp" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then rm -f -- "$tmp"; return 1; fi
    LC_ALL=C sort "$tmp"
    rc=$?
    rm -f -- "$tmp"
    return "$rc"
}
manifest_write() { snapshot_manifest "$1" > "$2"; }
source_manifest() {   # root -> identical relative-path manifest for live source identity
    local root="$1" rel line tmp rc
    tmp="$RUN_DIR/.source-manifest.$$.$RANDOM"
    ( cd -- "$root" || exit 1
      for rel in "${DEP_FILES[@]}" "${HDR_FILES[@]}" "$TB_IN_SNAP" "${AUX_FILES[@]}"; do
          line="$(hash_line_exact "$rel" || exit 1)" || exit 1
          printf '%s\n' "$line" || exit 1
      done ) > "$tmp" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then rm -f -- "$tmp"; return 1; fi
    LC_ALL=C sort "$tmp"; rc=$?; rm -f -- "$tmp"; return "$rc"
}
source_identity_check() {   # source + frozen copy both remain identical to pre-copy map
    local phase="$1"
    source_manifest "$REPO_ROOT" > "$RUN_DIR/source_after_${phase}.txt" || return 1
    manifest_write "$SNAP_NEW" "$RUN_DIR/man_new_after_${phase}.txt" || return 1
    cmp -s "$RUN_DIR/source_before.txt" "$RUN_DIR/source_after_${phase}.txt" || return 1
    cmp -s "$RUN_DIR/source_before.txt" "$RUN_DIR/man_new_after_${phase}.txt" || return 1
    printf 'SOURCE_IDENTITY phase=%s pre=copy=source_after=snapshot_after files=%s\n' "$phase" "$INPUT_N" >> "$RUN_LOG"
}

if [ "$SHA_SELF" -eq 1 ]; then
    sha_selftest || emit_fail "sha_selftest_failed"
    printf 'FUNCTIONAL_BACKEND_PERMISSION_SHA_META: PASS\n'
    exit 0
fi

compile_root() {   # snap vvp tag
    local snap="$1" vvp="$2" tag="$3" rc n sha_out n_ok n_lines
    [ -d "$snap" ] || return 1
    sha_out="$(snapshot_manifest "$snap")" || return 1
    n_lines="$(printf '%s\n' "$sha_out" | grep -c . || true)"
    n_ok="$(printf '%s\n' "$sha_out" | grep -cE '^[0-9a-f]{64}  ' || true)"
    [ "$n_lines" = "$INPUT_N" ] && [ "$n_ok" = "$INPUT_N" ] || {
        echo "[$tag] sha manifest lines=$n_lines hex=$n_ok expect=$INPUT_N" >> "$RUN_LOG"; return 1; }
    printf '%s\n' "$sha_out" >> "$RUN_LOG"
    local defs=""
    defs=""
    [ "$tag" = "old" ] || defs="-DBACKEND_HAS_CSR_CHK -DBACKEND_HAS_LSQ_F4"
    case "$tag" in new|e25) defs="$defs -DBACKEND_HAS_PMP" ;; esac
    ( cd -- "$snap" && \
      timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 $defs -I rtl/pkg -I . \
              -s tb_backend_permission -o "$vvp" "$TB_IN_SNAP" "${DEP_FILES[@]}" ) \
        > "$RUN_LOG.compile.$tag" 2>&1
    rc=$?
    cat -- "$RUN_LOG.compile.$tag" >> "$RUN_LOG" || return 1
    [ "$rc" -eq 124 ] && { echo "[$tag] compile timeout" >> "$RUN_LOG"; return 124; }
    [ "$rc" -eq 0 ] || { echo "[$tag] compile rc=$rc" >> "$RUN_LOG"; return "$rc"; }
    [ -s "$vvp" ] || { echo "[$tag] zero-size vvp" >> "$RUN_LOG"; return 1; }
    n=$(stat -c %s -- "$vvp" 2>/dev/null || echo 0)
    echo "[$tag] compile ok vvp_bytes=$n cwd=$snap" >> "$RUN_LOG"
    return 0
}

run_one() {   # vvp case expect verdict_tag [extra_plusargs]
    local vvp="$1" case="$2" expect="$3" tag="$4" extra="${5:-}" log rc
    local verdict_lines kind_lines verdict_line kind_line verdict kind expected_kind
    log="$RUN_DIR/${tag}_case_${case}.log"
    LAST_REASON=""
    # shellcheck disable=SC2086
    timeout "$TIMEOUT_RUN_S" "$VV" "$vvp" "+CASE=$case" $extra > "$log" 2>&1; rc=$?
    [ "$rc" -eq 124 ] && { LAST_REASON="timeout"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return 124; }
    [ "$rc" -eq 0 ] || { LAST_REASON="rc=$rc"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return "$rc"; }
    verdict_lines="$(grep -cE "^CASE ${case} .* VERDICT=" "$log" || true)"
    [ "$verdict_lines" = "1" ] || { LAST_REASON="verdict_lines=$verdict_lines"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return 1; }
    verdict_line="$(grep -E "^CASE ${case} .* VERDICT=" "$log")"
    verdict="$(printf '%s\n' "$verdict_line" | sed -nE "s/^CASE ${case} [A-Z0-9_]+ VERDICT=(OK|DEFECT_SIG|UNEXPECTED|XZ)$/\\1/p")"
    [ -n "$verdict" ] || { LAST_REASON="verdict_record_invalid"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return 1; }
    kind_lines="$(grep -cE "^CASE ${case} .* KIND=" "$log" || true)"
    [ "$kind_lines" = "1" ] || { LAST_REASON="kind_lines=$kind_lines"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return 1; }
    kind_line="$(grep -E "^CASE ${case} .* KIND=" "$log")"
    kind="$(printf '%s\n' "$kind_line" | sed -nE "s/^CASE ${case} [A-Z0-9_]+ KIND=(trigger|control) priv=[01xXzZ]+ n=[0-9]+ setup_ms=0x[[:xdigit:]]{8} setup_mc=0x[[:xdigit:]]{8}$/\\1/p")"
    [ -n "$kind" ] || { LAST_REASON="kind_record_invalid"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return 1; }
    expected_kind=control
    case "$tag:$case" in
        old3fd:17|old3fd:18) expected_kind=trigger ;;
        old3fd:*) expected_kind=control ;;
        *) case " $TRIGGER_CASES " in *" $case "*) expected_kind=trigger ;; esac ;;
    esac
    [ "$kind" = "$expected_kind" ] || { LAST_REASON="KIND=$kind expect=$expected_kind"; echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"; return 1; }
    LAST_KIND="$kind"
    [ "$verdict" = "$expect" ] || {
        LAST_REASON="VERDICT=$verdict expect=$expect"
        echo "[$tag] case $case $LAST_REASON" >> "$RUN_LOG"
        grep -E "^CASE " "$log" >> "$RUN_LOG" || true; return 1; }
    if [ "$tag" = "old" ]; then
        case " $TRIGGER_CASES " in *" $case "*) [ "$kind" = "trigger" ] || return 1 ;; *) [ "$kind" = "control" ] || return 1 ;; esac
    fi
    cat -- "$log" >> "$RUN_LOG"
    printf 'VEC %s %s kind=%s verdict=%s\n' "$tag" "$case" "$kind" "$verdict" >> "$RUN_LOG"
    return 0
}

parser_selftest() {
    local fake mode expected total=0 ok=0
    fake="$RUN_DIR/parser_fake_vvp.sh"
    cat > "$fake" <<'EOS'
#!/usr/bin/env bash
set -u
mode="${PARSER_MODE:-valid}"
case "$mode" in
    kind_changed) printf '%s\n' 'CASE 1 S_TVM_SATP_ILL KIND=control priv=01 n=3 setup_ms=0x00000000 setup_mc=0x00000000' ;;
    kind_missing) : ;;
    kind_duplicate_line)
        printf '%s\n' 'CASE 1 S_TVM_SATP_ILL KIND=trigger priv=01 n=3 setup_ms=0x00000000 setup_mc=0x00000000'
        printf '%s\n' 'CASE 1 S_TVM_SATP_ILL KIND=trigger priv=01 n=3 setup_ms=0x00000000 setup_mc=0x00000000' ;;
    kind_ambiguous_same_line)
        printf '%s\n' 'CASE 1 S_TVM_SATP_ILL KIND=trigger KIND=control priv=01 n=3 setup_ms=0x00000000 setup_mc=0x00000000' ;;
    *) printf '%s\n' 'CASE 1 S_TVM_SATP_ILL KIND=trigger priv=01 n=3 setup_ms=0x00000000 setup_mc=0x00000000' ;;
esac
case "$mode" in
    verdict_changed) printf '%s\n' 'CASE 1 S_TVM_SATP_ILL VERDICT=UNEXPECTED' ;;
    verdict_missing) : ;;
    verdict_duplicate_line)
        printf '%s\n' 'CASE 1 S_TVM_SATP_ILL VERDICT=OK'
        printf '%s\n' 'CASE 1 S_TVM_SATP_ILL VERDICT=OK' ;;
    verdict_ambiguous_same_line) printf '%s\n' 'CASE 1 S_TVM_SATP_ILL VERDICT=OK VERDICT=UNEXPECTED' ;;
    *) printf '%s\n' 'CASE 1 S_TVM_SATP_ILL VERDICT=OK' ;;
esac
EOS
    chmod +x -- "$fake" || return 1
    VV="$fake"
    for mode in valid kind_changed kind_missing kind_duplicate_line kind_ambiguous_same_line \
                verdict_changed verdict_missing verdict_duplicate_line verdict_ambiguous_same_line; do
        total=$((total + 1))
        PARSER_MODE="$mode"; export PARSER_MODE
        case "$mode" in
            valid) expected="" ;;
            kind_changed) expected="KIND=control expect=trigger" ;;
            kind_missing) expected="kind_lines=0" ;;
            kind_duplicate_line) expected="kind_lines=2" ;;
            kind_ambiguous_same_line) expected="kind_record_invalid" ;;
            verdict_changed) expected="VERDICT=UNEXPECTED expect=OK" ;;
            verdict_missing) expected="verdict_lines=0" ;;
            verdict_duplicate_line) expected="verdict_lines=2" ;;
            verdict_ambiguous_same_line) expected="verdict_record_invalid" ;;
        esac
        if [ "$mode" = valid ]; then
            if run_one "$fake" 1 OK parser; then ok=$((ok + 1)); else return 1; fi
        else
            if run_one "$fake" 1 OK parser; then return 1; fi
            [ "$LAST_REASON" = "$expected" ] || {
                echo "PARSER_META mode=$mode expected=$expected got=$LAST_REASON" >> "$RUN_LOG"; return 1; }
            grep -qxF "[parser] case 1 $expected" "$RUN_LOG" || return 1
            ok=$((ok + 1))
        fi
    done
    printf 'BACKEND_PERMISSION_PARSER_META total=%s ok=%s bad=%s\n' "$total" "$ok" "$((total-ok))"
    [ "$ok" -eq "$total" ]
}

if [ "$PARSER_SELF" -eq 1 ]; then
    parser_selftest || emit_fail "parser_selftest_failed"
    printf 'FUNCTIONAL_BACKEND_PERMISSION_PARSER_META: PASS\n'
    exit 0
fi

#==============================================================================
# 新树
#==============================================================================
SNAP_NEW="$RUN_DIR/src-new"
source_manifest "$REPO_ROOT" > "$RUN_DIR/source_before.txt" || emit_fail "source_manifest_before_failed"
snapshot_root "$REPO_ROOT" "$SNAP_NEW" || emit_fail "snapshot_new_failed"
manifest_write "$SNAP_NEW" "$RUN_DIR/man_new_before.txt" || emit_fail "manifest_new_before_failed"
cmp -s "$RUN_DIR/source_before.txt" "$RUN_DIR/man_new_before.txt" || emit_fail "source_copy_identity_mismatch"
# Source only the frozen copied environment, preserving its original shell status.
if . "$SNAP_NEW/scripts/env.sh" >> "$RUN_LOG" 2>&1; then env_rc=0; else env_rc=$?; fi
[ "$env_rc" -eq 0 ] || emit_fail "env_snapshot_source_failed_rc=$env_rc"
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing RV32_IVERILOG"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing RV32_VVP"
echo "EXEC_ENV path=$SNAP_NEW/scripts/env.sh rc=$env_rc cwd_compile=$SNAP_NEW" >> "$RUN_LOG"
compile_root "$SNAP_NEW" "$VVP_OUT" "new" || emit_fail "compile_new_failed"

OK_N=0; BAD_N=0; NEW_TRIG=0; NEW_CTL=0
for c in $(seq 0 $((SPEC_TOTAL-1))); do
    if run_one "$VVP_OUT" "$c" "OK" "new"; then
        OK_N=$((OK_N+1))
        if [ "$LAST_KIND" = trigger ]; then NEW_TRIG=$((NEW_TRIG+1)); else NEW_CTL=$((NEW_CTL+1)); fi
    else BAD_N=$((BAD_N+1)); fi
done
[ "$BAD_N" -eq 0 ] || emit_fail "new_bad=$BAD_N"
[ "$OK_N" -eq "$SPEC_TOTAL" ] || emit_fail "new_ok=$OK_N expect=$SPEC_TOTAL"
[ "$NEW_TRIG" -eq "$SPEC_TRIGGER" ] || emit_fail "new_trigger=$NEW_TRIG expect=$SPEC_TRIGGER"
[ "$NEW_CTL" -eq "$SPEC_CONTROL" ] || emit_fail "new_control=$NEW_CTL expect=$SPEC_CONTROL"
manifest_write "$SNAP_NEW" "$RUN_DIR/man_new_after.txt" || emit_fail "manifest_new_after_failed"
cmp -s "$RUN_DIR/man_new_before.txt" "$RUN_DIR/man_new_after.txt" || emit_fail "snapshot_new_mutated"
[ "$(grep -c 'FAIL' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_FAIL"
[ "$(grep -c 'DEFECT_SIG' "$RUN_LOG" || true)" = "0" ] || emit_fail "log_has_DEFECT_SIG"
# Same frozen test ELF inputs, replacing only backend_top with exact pre-change e25 candidate.
E25_SRC_LINE="$(hash_line_exact "$OLD_E25_SOURCE" "$OLD_E25_SHA")" || emit_fail "old_e25_identity_failed"
printf 'OLD_E25_SOURCE %s\n' "$E25_SRC_LINE" >> "$RUN_LOG"
SNAP_E25="$RUN_DIR/src-e25"
mkdir -p -- "$SNAP_E25" || emit_fail "snapshot_e25_mkdir_failed"
cp -a -- "$SNAP_NEW"/. "$SNAP_E25"/ || emit_fail "snapshot_e25_copy_failed"
cp -p -- "$OLD_E25_SOURCE" "$SNAP_E25/rtl/back2/backend_top.v" || emit_fail "snapshot_e25_backend_copy_failed"
hash_line_exact "$SNAP_E25/rtl/back2/backend_top.v" "$OLD_E25_SHA" >/dev/null || emit_fail "snapshot_e25_backend_identity_failed"
manifest_write "$SNAP_E25" "$RUN_DIR/man_e25_before.txt" || emit_fail "manifest_e25_before_failed"
E25_VVP="$RUN_DIR/tb_backend_permission_e25.vvp"
compile_root "$SNAP_E25" "$E25_VVP" "e25" || emit_fail "compile_e25_failed"
E25_RED=0; E25_CTRL=0
for c in 26 27 28 29 31 32; do
    if run_one "$E25_VVP" "$c" "UNEXPECTED" "e25"; then E25_RED=$((E25_RED+1)); else emit_fail "old_e25_case_${c}_not_red"; fi
done
if run_one "$E25_VVP" 30 "OK" "e25"; then E25_CTRL=1; else emit_fail "old_e25_truewrite_control_failed"; fi
[ "$E25_RED" -eq 6 ] || emit_fail "old_e25_red=$E25_RED expect=6"
[ "$E25_CTRL" -eq 1 ] || emit_fail "old_e25_control=$E25_CTRL expect=1"
manifest_write "$SNAP_E25" "$RUN_DIR/man_e25_after.txt" || emit_fail "manifest_e25_after_failed"
cmp -s "$RUN_DIR/man_e25_before.txt" "$RUN_DIR/man_e25_after.txt" || emit_fail "snapshot_e25_mutated"
[ "$(hash_line_exact "$OLD_E25_SOURCE" "$OLD_E25_SHA")" = "$E25_SRC_LINE" ] || emit_fail "old_e25_source_mutated"
printf 'BACKEND_PERMISSION_E25 red=%s/6 control=%s/1 hash=%s\n' "$E25_RED" "$E25_CTRL" "$OLD_E25_SHA" >> "$RUN_LOG"
source_identity_check new_suite || emit_fail "source_identity_new_suite_failed"

if [ "$NEG" -eq 0 ]; then
    printf 'BACKEND_PERMISSION_VECTORS total=%s trigger=%s control=%s ok=%s bad=0\n' \
           "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" >> "$RUN_LOG"
    printf 'FUNCTIONAL_BACKEND_PERMISSION: PASS\n' >> "$RUN_LOG"
    printf 'BACKEND_PERMISSION_NEW_SPEC total=%s trigger=%s control=%s new_only_cases=%s\n' \
           "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$NEW_ONLY_CASES"
    printf 'BACKEND_PERMISSION_VECTORS total=%s trigger=%s control=%s ok=%s bad=0\n' \
           "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N"
    printf 'BACKEND_PERMISSION_E25 red=%s/6 control=%s/1 hash=%s\n' "$E25_RED" "$E25_CTRL" "$OLD_E25_SHA"
    printf 'FUNCTIONAL_BACKEND_PERMISSION: PASS\n'
    exit 0
fi

#==============================================================================
# 反证：201 旧树同一 TB（不定义接口宏）
#==============================================================================
command -v git >/dev/null 2>&1 || emit_fail "tool_missing git"
command -v tar >/dev/null 2>&1 || emit_fail "tool_missing tar"
OLD_DIR="$RUN_DIR/old-$OLD_COMMIT"
OLD_TAR="$RUN_DIR/old-$OLD_COMMIT.tar"
mkdir -p -- "$OLD_DIR" || emit_fail "old_dir_failed"
git -C "$REPO_ROOT" archive "$OLD_COMMIT" > "$OLD_TAR" 2>> "$RUN_LOG" || emit_fail "git_archive_failed"
tar -x -f "$OLD_TAR" -C "$OLD_DIR" >> "$RUN_LOG" 2>&1 || emit_fail "old_extract_failed"
SNAP_OLD="$RUN_DIR/src-old"
snapshot_root "$OLD_DIR" "$SNAP_OLD" || emit_fail "snapshot_old_failed"
manifest_write "$SNAP_OLD" "$RUN_DIR/man_old_before.txt" || emit_fail "manifest_old_before_failed"
OLD_VVP="$RUN_DIR/tb_backend_permission_old.vvp"
compile_root "$SNAP_OLD" "$OLD_VVP" "old" || emit_fail "compile_old_failed"

OLD_TRIG=0; OLD_CTL=0; OLD_BAD=0
for c in $(seq 0 $((OLD201_TOTAL-1))); do
    exp="OK"
    case " $TRIGGER_CASES " in *" $c "*) exp="DEFECT_SIG" ;; esac
    if run_one "$OLD_VVP" "$c" "$exp" "old"; then
        case "$exp" in DEFECT_SIG) OLD_TRIG=$((OLD_TRIG+1)) ;; *) OLD_CTL=$((OLD_CTL+1)) ;; esac
    else
        OLD_BAD=$((OLD_BAD+1))
    fi
done
[ "$OLD_BAD" -eq 0 ] || emit_fail "old_bad=$OLD_BAD"
[ "$OLD_TRIG" -eq "$OLD201_TRIGGER" ] || emit_fail "old_trigger=$OLD_TRIG expect=$OLD201_TRIGGER"
[ "$OLD_CTL" -eq "$OLD201_CONTROL" ] || emit_fail "old_control=$OLD_CTL expect=$OLD201_CONTROL"
manifest_write "$SNAP_OLD" "$RUN_DIR/man_old_after.txt" || emit_fail "manifest_old_after_failed"
cmp -s "$RUN_DIR/man_old_before.txt" "$RUN_DIR/man_old_after.txt" || emit_fail "snapshot_old_mutated"

printf 'BACKEND_PERMISSION_NEGATIVE_RESULT old_total=%s/%s old_trigger=%s/%s old_control=%s/%s new_ok=%s/%s commit=%s\n' \
       "$OLD201_TOTAL" "$OLD201_TOTAL" "$OLD_TRIG" "$OLD201_TRIGGER" "$OLD_CTL" "$OLD201_CONTROL" "$OK_N" "$SPEC_TOTAL" "$OLD_COMMIT" >> "$RUN_LOG"

#==============================================================================
# 旧 3fd 候选对照：**正式 fixture**，不从 ignored build root 回退、不 SKIP。
#   fixture 只含 backend_top.v（SHA 3fd…）；其余依赖/头/TB/env 来自本脚本起始
#   SNAP_NEW 的同一冻结 closure，替换该文件后在该自有 snapshot 内编译。
#   缺/改 fixture ⇒ 合法 FAIL 行 + exit 9，绝不打印 PASS/SKIP。
#==============================================================================
if ! fixture_3fd_check; then
    emit_fixture_fail "fixture_3fd_missing_or_sha path=$FIXTURE_3FD"
fi

SNAP_3FD="$RUN_DIR/src-old3fd"
mkdir -p -- "$SNAP_3FD" || emit_fail "snapshot_3fd_mkdir_failed"
cp -a -- "$SNAP_NEW"/. "$SNAP_3FD"/ || emit_fail "snapshot_3fd_copy_failed"
cp -p -- "$FIXTURE_3FD" "$SNAP_3FD/rtl/back2/backend_top.v" || emit_fail "snapshot_3fd_fixture_copy_failed"
hash_line_exact "$SNAP_3FD/rtl/back2/backend_top.v" "$OLD3FD_SHA" >/dev/null || \
    emit_fixture_fail "fixture_3fd_copy_mismatch path=$SNAP_3FD/rtl/back2/backend_top.v"
manifest_write "$SNAP_3FD" "$RUN_DIR/man_3fd_before.txt" || emit_fail "manifest_3fd_before_failed"
VVP_3FD="$RUN_DIR/tb_backend_permission_3fd.vvp"
compile_root "$SNAP_3FD" "$VVP_3FD" "old3fd" || emit_fail "compile_3fd_failed"

T3=0; C3=0; B3=0
for c in $(seq 0 $((OLD3FD_TOTAL-1))); do
    exp="OK"
    case "$c" in 17|18) exp="DEFECT_SIG" ;; esac
    if run_one "$VVP_3FD" "$c" "$exp" "old3fd" "+EXPECT_3FD"; then
        case "$exp" in DEFECT_SIG) T3=$((T3+1)) ;; *) C3=$((C3+1)) ;; esac
    else
        B3=$((B3+1))
    fi
done
[ "$B3" -eq 0 ] || emit_fail "old3fd_bad=$B3"
[ "$T3" -eq "$OLD3FD_TRIGGER" ] || emit_fail "old3fd_trig=$T3 expect=$OLD3FD_TRIGGER"
[ "$C3" -eq "$OLD3FD_CONTROL" ] || emit_fail "old3fd_ctl=$C3 expect=$OLD3FD_CONTROL"
manifest_write "$SNAP_3FD" "$RUN_DIR/man_3fd_after.txt" || emit_fail "manifest_3fd_after_failed"
cmp -s "$RUN_DIR/man_3fd_before.txt" "$RUN_DIR/man_3fd_after.txt" || emit_fail "snapshot_3fd_mutated"
printf 'BACKEND_PERMISSION_3FD old3fd_total=%s/%s old3fd_trigger=%s/%s old3fd_control=%s/%s sha=%s fixture=%s\n' \
       "$OLD3FD_TOTAL" "$OLD3FD_TOTAL" "$T3" "$OLD3FD_TRIGGER" "$C3" "$OLD3FD_CONTROL" \
       "$OLD3FD_SHA" "$FIXTURE_3FD" | tee -a "$RUN_LOG"
printf 'FUNCTIONAL_BACKEND_PERMISSION_3FD_RESULT: ok\n' >> "$RUN_LOG"

#==============================================================================
# self-test：真实 fixture 缺/改 ⇒ exit 9 + 合法 FAIL 行；wrongpath/garbage 解析反证
#==============================================================================
if [ "$NEG" -eq 1 ]; then
    NEGDIR="$RUN_DIR/fixture_neg"
    mkdir -p -- "$NEGDIR" || emit_fail "fixture_neg_dir_failed"

    out="$(RV32_BACKEND_3FD_FIXTURE="$NEGDIR/no-such" "$SELF_PATH" --check-3fd-fixture 2>&1)"; rc=$?
    [ "$rc" -eq 9 ] || emit_fail "fixture_neg_missing_rc=$rc expect=9"
    printf '%s\n' "$out" | grep -qxF \
        "FUNCTIONAL_BACKEND_PERMISSION_FIXTURE: FAIL reason=fixture_3fd_missing_or_sha path=$NEGDIR/no-such" || \
        emit_fail "fixture_neg_missing_stdout"

    cp -p -- "$FIXTURE_3FD" "$NEGDIR/fake3fd.v" || emit_fail "fixture_neg_copy_failed"
    printf '\n// mutated for counterproof\n' >> "$NEGDIR/fake3fd.v" || emit_fail "fixture_neg_mutate_failed"
    out="$(RV32_BACKEND_3FD_FIXTURE="$NEGDIR/fake3fd.v" "$SELF_PATH" --check-3fd-fixture 2>&1)"; rc=$?
    [ "$rc" -eq 9 ] || emit_fail "fixture_neg_modified_rc=$rc expect=9"
    printf '%s\n' "$out" | grep -qxF \
        "FUNCTIONAL_BACKEND_PERMISSION_FIXTURE: FAIL reason=fixture_3fd_missing_or_sha path=$NEGDIR/fake3fd.v" || \
        emit_fail "fixture_neg_modified_stdout"

    out="$(RV32_BACKEND_3FD_FIXTURE="$FIXTURE_3FD" "$SELF_PATH" --check-3fd-fixture 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || emit_fail "fixture_neg_valid_rc=$rc"
    printf '%s\n' "$out" | grep -q '^FUNCTIONAL_BACKEND_PERMISSION_FIXTURE: PASS ' || \
        emit_fail "fixture_neg_valid_stdout"

    valid_line="$(hash_line_exact "$FIXTURE_3FD" "$OLD3FD_SHA")" || emit_fail "fixture_neg_valid_hash_failed"
    hash_line_parse "$valid_line" "$FIXTURE_3FD" "$OLD3FD_SHA" || emit_fail "fixture_neg_parse_valid_failed"
    if hash_line_parse "$valid_line" "$NEGDIR/wrongpath" "$OLD3FD_SHA"; then
        emit_fail "fixture_neg_wrongpath_accepted"
    fi
    if hash_line_parse "garbage" "$FIXTURE_3FD" "$OLD3FD_SHA"; then
        emit_fail "fixture_neg_garbage_accepted"
    fi
    if hash_line_parse "" "$FIXTURE_3FD" "$OLD3FD_SHA"; then
        emit_fail "fixture_neg_empty_accepted"
    fi
    short_line="$(printf '%063d  %s' 0 "$FIXTURE_3FD")"
    if hash_line_parse "$short_line" "$FIXTURE_3FD" "$OLD3FD_SHA"; then
        emit_fail "fixture_neg_shorthex_accepted"
    fi
    printf 'FUNCTIONAL_BACKEND_PERMISSION_FIXTURE_NEGATIVE_RESULT: ok\n' >> "$RUN_LOG"
fi
# Emit PASS anchors only after every mandatory new/old/fixture/meta stage succeeded.
source_identity_check all_mandatory || emit_fail "source_identity_final_failed"
printf 'BACKEND_PERMISSION_VECTORS total=%s trigger=%s control=%s ok=%s bad=0\n' \
       "$SPEC_TOTAL" "$SPEC_TRIGGER" "$SPEC_CONTROL" "$OK_N" | tee -a "$RUN_LOG"
printf 'BACKEND_PERMISSION_NEGATIVE old201=%s/%s trigger=%s/%s control=%s/%s old3fd=%s/%s trigger=%s/%s control=%s/%s e25_red=%s/6 control=%s/1\n' \
       "$OLD201_TOTAL" "$OLD201_TOTAL" "$OLD_TRIG" "$OLD201_TRIGGER" "$OLD_CTL" "$OLD201_CONTROL" \
       "$OLD3FD_TOTAL" "$OLD3FD_TOTAL" "$T3" "$OLD3FD_TRIGGER" "$C3" "$OLD3FD_CONTROL" "$E25_RED" "$E25_CTRL" | tee -a "$RUN_LOG"
printf 'FUNCTIONAL_BACKEND_PERMISSION_NEGATIVE: PASS\n' | tee -a "$RUN_LOG"
if [ "$NEG" -eq 1 ]; then printf 'FUNCTIONAL_BACKEND_PERMISSION_FIXTURE_NEGATIVE: PASS\n' | tee -a "$RUN_LOG"; fi
exit 0
