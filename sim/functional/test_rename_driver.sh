#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_rename_driver.sh —— F2 重命名包**验收夹具自检**（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2B-5）
# 依据 : prompts/common.md §3（关键特性配正反证；关特性/注缺陷后必须 FAIL，否则视为未测到）、
#        sim/functional/manifest.tsv（本包锚点 = 唯一整行 `FUNCTIONAL_RENAME: PASS`）。
#
# 做什么（只读产品代码；夹具/产物全部落在 build/functional/rename/driver-*/，绝不 rm）:
#   D1  未知参数                → rc=1 且 reason=unknown_arg，stdout 无任何 PASS 锚点
#   D2  非法模式                → rc=1 且 reason=bad_mode
#   D3  越权 OUT_DIR            → rc=1 且 reason=out_root_unauthorized（规范化后校验）
#   D4  缺工具                  → rc=1 且 reason=tool_missing name=RV32_VVP
#   D5  **合法假工具正控**：包装真工具（记录调用）→ rc=0 且锚点恰 1 行 + 冻结计数摘要
#   D6  假 iverilog 产出 0 字节 vvp → rc=1 且 reason=compile_new_failed
#   D7  假 vvp 伪造输出（spoof/badcase/small/extra）→ rc=1，原因按类绑定
#   D8  **变异夹具的 mini 无变异正控**：同形态夹具 + 未变异 TB → 必须 rc=0 且锚点 1
#   D9  变异①（nchk 伪报为 1）   → rc=1 且日志含"< 冻结下限"；**不得**因编译/缺头等旁因失败
#   D10 变异②（TB 自行打印锚点） → rc=1 且 reason=pass_anchor_count=*
#   D11 变异③（改向量名）       → rc=1 且日志含"严格 CASE 行不匹配"
#   D12 **依赖故意损坏**（删必需头）→ rc=1 且 reason=snapshot_new_failed（**不计**变异命中）
#   D13 旧树 DUT_ROOT 拒绝      → rc=1，且失败向量集合 == 冻结触发集（绑定真实向量失败）
#   D14 毒 cwd（诱饵 rtl/ 与头）→ 仍 rc=0（快照 + 快照 root cwd 编译，与调用者 cwd 无关）
#   D15 阶段间改源 TB           → 自检模式 rc=1 且 reason=source_tb_changed_between_phases
#   D16 产物纪律：连续两次运行各自独占 run 目录、均保留（不 rm 历史）
#   D17 编译输入 sha256 清单：条数固定(=3)、格式严格、运行后校验通过（前后不变）
#
# 判定：每项核 rc + stdout/日志中的**绑定原因** + 锚点计数；任一不符即 FAIL（exit 1）。
#       D8 与 D9/D10/D11 成对：先证明"未变异夹具能通过"，再证明"变异后以该原因失败"
#       ⇒ 反向命中成立（且 D9–D11 显式排除编译/缺头/工具等旁因，D12 证明依赖损坏不计命中）。
#       全部通过时 stdout 恰好一行 `FUNCTIONAL_RENAME_DRIVER: PASS`。
#
# 用法 : bash sim/functional/test_rename_driver.sh
#==============================================================================
set -u

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }
ENTRY="$SELF_DIR/test_rename.sh"
TB="$SELF_DIR/tb_rename_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"
OLD_COMMIT="201acf61e118a3fb533e1a96768687a35efa1751"
SPEC_SUMMARY='^RENAME_VECTORS total=25 trigger=11 control=14 ok=25 bad=0$'
SPEC_TRIGGERS="8 9 10 11 12 13 15 16 17 18 22"

[ -f "$ENTRY" ] || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=entry_missing path=%s\n' "$ENTRY"; exit 1; }
[ -f "$TB" ]    || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=tb_missing path=%s\n' "$TB"; exit 1; }

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || exit 1
#   ★★ 母复跑发现的环境隔离缺陷：入口产物根优先级是
#        RV32_FUNCTIONAL_PKG_OUT_DIR > OUT_DIR > 默认
#     driver 若原样继承父变量，所有 fixture 的 OUT_DIR 都会被父变量**遮盖**
#     ⇒ D3 负例实际写合法父目录（rc=0）、D8 跑错根……。
#     修法：driver 自己支持被父变量调用（用它做自己的基目录），但每次**子调用**前显式
#     清空三个输出根变量，再按用例设定 ⇒ 互不遮盖；非法例把"最终有效参数"设非法。
out_env_reset() { unset RV32_FUNCTIONAL_PKG_OUT_DIR RV32_FUNCTIONAL_OUT_DIR OUT_DIR; }
PARENT_PKGOUT="${RV32_FUNCTIONAL_PKG_OUT_DIR:-}"
if [ -n "$PARENT_PKGOUT" ]; then
    BASE="$(readlink -m -- "$PARENT_PKGOUT")" || {
        printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=parent_pkgout_unresolved\n'; exit 1; }
    case "$BASE/" in
        "$AUTH_ROOT"/*) : ;;
        *) printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=parent_pkgout_unauthorized path=%s\n' "$BASE"
           exit 1 ;;
    esac
else
    BASE="$AUTH_ROOT/rename"
fi
mkdir -p -- "$BASE" || exit 1
W="$(mktemp -d -- "$BASE/driver-XXXXXXXX")" || {
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=workdir_mktemp_failed\n'; exit 1; }
LOG="$W/driver.log"
: > "$LOG" || exit 1
printf 'FUNCTIONAL_RENAME_DRIVER_WORK=%s\n' "$W"

# shellcheck disable=SC1090
. "$ENV_SH" >> "$LOG" 2>&1 || {
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=env_sh_source_failed\n'; exit 1; }
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=real_iverilog_missing\n'; exit 1; }
[ -n "$VV" ] && [ -x "$VV" ] || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=real_vvp_missing\n'; exit 1; }

NG=0; NT=0
sub_ok()   { NT=$((NT+1)); printf 'DRV %-36s OK\n' "$1" >> "$LOG"; }
sub_fail() { printf 'DRV %-36s %s\n' "$1" "$2" | tee -a "$LOG" >&2; NG=$((NG+1)); }
log_run()  { printf -- '---- %s rc=%s ----\n%s\n' "$1" "$2" "$3" >> "$LOG"; }
count_anchor() { printf '%s\n' "$1" | grep -cxF 'FUNCTIONAL_RENAME: PASS' || true; }

run_entry() {
    OUT="$(bash "$ENTRY" "$@" 2>&1)"; RC=$?
    log_run "entry $*" "$RC" "$OUT"
}

#------------------------------------------------------------------------------
# 工具夹具
#------------------------------------------------------------------------------
mk_wrap_tools() {
    local d="$1"
    mkdir -p -- "$d" || return 1
    cat > "$d/iverilog" <<EOF
#!/usr/bin/env bash
echo "\$0 \$*" >> "$d/tool-calls.log"
exec "$IV" "\$@"
EOF
    cat > "$d/vvp" <<EOF
#!/usr/bin/env bash
echo "\$0 \$*" >> "$d/tool-calls.log"
exec "$VV" "\$@"
EOF
    chmod +x "$d/iverilog" "$d/vvp"
}

#   $2=mode: badsize（不产出 vvp）| spoof（只打印伪造 PASS）| badcase（缺 nchk）
#            | small（nchk=1）| extra（两条 CASE 行）
mk_fake_tools() {
    local d="$1" mode="$2"
    mkdir -p -- "$d" || return 1
    if [ "$mode" = "badsize" ]; then
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/iverilog" || return 1
    else
        cat > "$d/iverilog" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
[ -n "$out" ] && printf 'dummy-artifact\n' > "$out"
exit 0
EOF
    fi
    chmod +x -- "$d/iverilog" || return 1
    [ "$mode" = "badsize" ] && return 0
    case "$mode" in
        spoof)
            cat > "$d/vvp" <<'EOF'
#!/usr/bin/env bash
echo "FUNCTIONAL_RENAME: PASS"
exit 0
EOF
            ;;
        badcase)
            cat > "$d/vvp" <<'EOF'
#!/usr/bin/env bash
echo "CASE 0 int_x0_hard_zero KIND=control VERDICT=OK"
exit 0
EOF
            ;;
        small)
            cat > "$d/vvp" <<'EOF'
#!/usr/bin/env bash
c=0
for a in "$@"; do case "$a" in +CASE=*) c="${a#+CASE=}";; esac; done
echo "CASE $c ctrl_full_no_fire KIND=control VERDICT=OK nchk=1"
exit 0
EOF
            ;;
        extra)
            cat > "$d/vvp" <<'EOF'
#!/usr/bin/env bash
c=0
for a in "$@"; do case "$a" in +CASE=*) c="${a#+CASE=}";; esac; done
echo "CASE $c ctrl_full_no_fire KIND=control VERDICT=OK nchk=99"
echo "CASE $c ctrl_full_no_fire KIND=control VERDICT=OK nchk=99"
exit 0
EOF
            ;;
        *) return 1 ;;
    esac
    chmod +x -- "$d/vvp" 2>/dev/null || return 1
    return 0
}

#------------------------------------------------------------------------------
# TB 变异夹具（独立小仓库：scripts/env.sh + rtl/back2/{rename.v,back2_params.vh}
#               + sim/functional/{test_rename.sh, 变异 TB} + build/functional）
#   $2 = none（无变异，用于 mini 正控）| nchk | spoof | name | noheader
#------------------------------------------------------------------------------
mk_tb_fixture() {
    local fx="$1" mode="$2" mut
    mkdir -p -- "$fx/scripts" "$fx/rtl/back2" "$fx/sim/functional" "$fx/build/functional" || return 1
    cp -p -- "$ENV_SH" "$fx/scripts/env.sh" || return 1
    cp -p -- "$REPO_ROOT/rtl/back2/rename.v" "$fx/rtl/back2/rename.v" || return 1
    cp -p -- "$REPO_ROOT/rtl/back2/back2_params.vh" "$fx/rtl/back2/back2_params.vh" || return 1
    cp -p -- "$ENTRY" "$fx/sim/functional/test_rename.sh" || return 1
    mut="$fx/sim/functional/tb_rename_semantics.sv"
    cp -p -- "$TB" "$mut" || return 1
    case "$mode" in
        none) ;;
        nchk)
            sed -i 's/ckind, nchk);/ckind, 1);/' "$mut" || return 1
            [ "$(grep -c 'ckind, 1);' "$mut")" -ge 2 ] || return 1
            ;;
        spoof)
            sed -i 's|if (errs == 0)|if (errs == 0) $display("FUNCTIONAL_RENAME: PASS");\n        if (errs == 0)|' "$mut" || return 1
            grep -q 'FUNCTIONAL_RENAME: PASS' "$mut" || return 1
            ;;
        name)
            sed -i 's/cname="ctrl_full_no_fire"/cname="ctrl_full_no_fireX"/' "$mut" || return 1
            grep -q 'ctrl_full_no_fireX' "$mut" || return 1
            ;;
        noheader)
            rm -f -- "$fx/rtl/back2/back2_params.vh" || return 1
            ;;
        *) return 1 ;;
    esac
    chmod +x -- "$fx/sim/functional/test_rename.sh" || return 1
    return 0
}

run_fixture() {
    local fx="$1"; shift
out_env_reset
    OUT="$(OUT_DIR="$fx/build/functional/out" bash "$fx/sim/functional/test_rename.sh" "$@" 2>&1)"; RC=$?
    log_run "fixture $(basename -- "$fx") $*" "$RC" "$OUT"
}

#==============================================================================
# 逐项
#==============================================================================

# ---- D1 未知参数 ----
run_entry --bogus-arg
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=unknown_arg' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D1_unknown_arg" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D1_unknown_arg"; fi

# ---- D2 非法模式 ----
OUT="$(RV32_RENAME_MODE=weird bash "$ENTRY" 2>&1)"; RC=$?
log_run "D2" "$RC" "$OUT"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=bad_mode' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D2_bad_mode" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D2_bad_mode"; fi

# ---- D3 越权产物根：两种"最终有效参数"形式都必须真非法（不得靠父调用 unset 伪修）----
ok3=1
out_env_reset
OUT="$(OUT_DIR="$REPO_ROOT/build/rename-unauth" bash "$ENTRY" 2>&1)"; RC=$?
log_run "D3a_unauth_OUT_DIR" "$RC" "$OUT"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'reason=out_root_unauthorized' \
    && [ "$(count_anchor "$OUT")" = "0" ] || ok3=0
#   包优先变量形式：即便同时给了合法 OUT_DIR，PKGOUT 非法也必须被拒（证明优先级被真正走通）
out_env_reset
OUT2="$(RV32_FUNCTIONAL_PKG_OUT_DIR="$REPO_ROOT/build/rename-unauth2" OUT_DIR="$W/d3-legal-shadow" \
        bash "$ENTRY" 2>&1)"; RC2=$?
log_run "D3b_unauth_PKGOUT" "$RC2" "$OUT2"
[ "$RC2" -eq 1 ] && printf '%s\n' "$OUT2" | grep -q 'reason=out_root_unauthorized' \
    && [ "$(count_anchor "$OUT2")" = "0" ] || ok3=0
if [ "$ok3" -eq 0 ]; then
    sub_fail "D3_out_unauthorized" "rc=$RC/$RC2 expect=1 (OUT_DIR and PKGOUT forms)"
else sub_ok "D3_out_unauthorized"; fi

# ---- D4 缺工具 ----
OUT="$(RV32_VVP=/nonexistent/vvp bash "$ENTRY" 2>&1)"; RC=$?
log_run "D4" "$RC" "$OUT"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=tool_missing name=RV32_VVP' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D4_tool_missing" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D4_tool_missing"; fi

# ---- D5 合法假工具正控 ----
WT="$W/wrap-tools"
if mk_wrap_tools "$WT"; then
out_env_reset
    OUT="$(RV32_IVERILOG="$WT/iverilog" RV32_VVP="$WT/vvp" OUT_DIR="$W/d5-out" bash "$ENTRY" 2>&1)"; RC=$?
    log_run "D5" "$RC" "$OUT"
    if [ "$RC" -ne 0 ] || [ "$(count_anchor "$OUT")" != "1" ] \
       || ! printf '%s\n' "$OUT" | grep -qE "$SPEC_SUMMARY" \
       || [ ! -s "$WT/tool-calls.log" ]; then
        sub_fail "D5_fake_tool_positive" "rc=$RC expect=0 anchor=$(count_anchor "$OUT")"
    else sub_ok "D5_fake_tool_positive"; fi
else
    sub_fail "D5_fake_tool_positive" "wrap_tool_setup_failed"
fi

# ---- D6 0 字节产物 ----
FT="$W/fake-badsize"
if mk_fake_tools "$FT" badsize; then
out_env_reset
    OUT="$(RV32_IVERILOG="$FT/iverilog" RV32_VVP="$VV" OUT_DIR="$W/d6-out" bash "$ENTRY" 2>&1)"; RC=$?
    log_run "D6" "$RC" "$OUT"
    if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=compile_new_failed' \
       || [ "$(count_anchor "$OUT")" != "0" ]; then
        sub_fail "D6_zero_size_artifact" "rc=$RC expect=1 reason_or_anchor_mismatch"
    else sub_ok "D6_zero_size_artifact"; fi
else
    sub_fail "D6_zero_size_artifact" "fake_tool_setup_failed"
fi

# ---- D7 假 vvp 伪造输出（按类绑定原因）----
for m in spoof badcase small extra; do
    FT="$W/fake-$m"
    if mk_fake_tools "$FT" "$m"; then
out_env_reset
        OUT="$(RV32_IVERILOG="$FT/iverilog" RV32_VVP="$FT/vvp" OUT_DIR="$W/d7-$m" bash "$ENTRY" 2>&1)"; RC=$?
        log_run "D7_$m" "$RC" "$OUT"
        ok=1
        [ "$RC" -eq 1 ] || ok=0
        [ "$(count_anchor "$OUT")" = "0" ] || ok=0
        case "$m" in
            spoof)   printf '%s\n' "$OUT" | grep -qE 'reason=(new_source_bad_vectors|pass_anchor_count|vec_count_new)' || ok=0 ;;
            *)       printf '%s\n' "$OUT" | grep -qE 'reason=(new_source_bad_vectors|vec_count_new)' || ok=0 ;;
        esac
        if [ "$ok" -eq 0 ]; then
            sub_fail "D7_fake_vvp_$m" "rc=$RC expect=1 anchor=$(count_anchor "$OUT")"
        else sub_ok "D7_fake_vvp_$m"; fi
    else
        sub_fail "D7_fake_vvp_$m" "fake_tool_setup_failed"
    fi
done

# ---- D8 mini 无变异正控（与变异夹具同形态，未改 TB 必须通过）----
FX0="$W/fix-none"
if mk_tb_fixture "$FX0" none; then
    run_fixture "$FX0"
    if [ "$RC" -ne 0 ] || [ "$(count_anchor "$OUT")" != "1" ] \
       || ! printf '%s\n' "$OUT" | grep -qE "$SPEC_SUMMARY"; then
        sub_fail "D8_mini_positive_control" "rc=$RC expect=0 anchor=$(count_anchor "$OUT")"
    else sub_ok "D8_mini_positive_control"; fi
else
    sub_fail "D8_mini_positive_control" "fixture_setup_failed"
fi

# ---- D9/D10/D11 TB 变异：必须在同一夹具形态上以**该变异对应原因**失败 ----
MUT_NCHK='< 冻结下限'
MUT_SPOOF='reason=pass_anchor_count='
MUT_NAME='严格 CASE 行不匹配'
for m in nchk spoof name; do
    FX="$W/fix-$m"
    if mk_tb_fixture "$FX" "$m"; then
        run_fixture "$FX"
        ok=1
        [ "$RC" -eq 1 ] || ok=0
        [ "$(count_anchor "$OUT")" = "0" ] || ok=0
        # 自身日志：该次失败必须留下独占 run 目录与该向量的日志
        RD="$(printf '%s\n' "$OUT" | sed -n 's/^RENAME_RUN_DIR=//p')"
        [ -n "$RD" ] && [ -s "$RD/test_rename.log" ] || ok=0
        # 原因绑定：spoof 看 stdout 的锚点计数；nchk/name 看**该 run 自己的日志**里的判定点
        case "$m" in
            nchk)  grep -qF "$MUT_NCHK"  "$RD/test_rename.log" 2>/dev/null || ok=0 ;;
            spoof) printf '%s\n' "$OUT" | grep -qF "$MUT_SPOOF" || ok=0 ;;
            name)  grep -qF "$MUT_NAME"  "$RD/test_rename.log" 2>/dev/null || ok=0 ;;
        esac
        # 原因绑定：不得是编译/缺头/工具等旁因
        printf '%s\n' "$OUT" | grep -qE 'reason=(compile_new_failed|tool_missing|snapshot_new_failed|tb_sha_unavailable|frozen_tb_)' && ok=0
        if [ "$ok" -eq 0 ]; then
            sub_fail "D_mutation_$m" "rc=$RC expect=1 reason_bind_failed"
        else sub_ok "D_mutation_$m"; fi
    else
        sub_fail "D_mutation_$m" "fixture_setup_failed"
    fi
done

# ---- D12 依赖故意损坏（删必需头）⇒ 依赖类失败，且**不得**算作变异命中 ----
FXH="$W/fix-noheader"
if mk_tb_fixture "$FXH" noheader; then
    run_fixture "$FXH"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    printf '%s\n' "$OUT" | grep -q 'reason=snapshot_new_failed' || ok=0
    #   关键：这不是 mutation 命中 —— 三条变异专属判定点一条都不许出现（stdout + 自身日志）
    RDH="$(printf '%s\n' "$OUT" | sed -n 's/^RENAME_RUN_DIR=//p')"
    for pat in "$MUT_NCHK" "$MUT_SPOOF" "$MUT_NAME"; do
        printf '%s\n' "$OUT" | grep -qF "$pat" && ok=0
        [ -n "$RDH" ] && [ -s "$RDH/test_rename.log" ] && grep -qF "$pat" "$RDH/test_rename.log" && ok=0
    done
    if [ "$ok" -eq 0 ]; then
        sub_fail "D12_dependency_corruption" "rc=$RC expect=1 reason=snapshot_new_failed_only"
    else sub_ok "D12_dependency_corruption"; fi
else
    sub_fail "D12_dependency_corruption" "fixture_setup_failed"
fi

# ---- D13 旧树 DUT_ROOT 拒绝：失败向量集合必须 == 冻结触发集 ----
OLD="$W/old-tree"
mkdir -p -- "$OLD" || true
if git -C "$REPO_ROOT" archive "$OLD_COMMIT" 2>>"$LOG" | tar -x -C "$OLD" >>"$LOG" 2>&1; then
out_env_reset
    OUT="$(DUT_ROOT="$OLD" OUT_DIR="$W/d13-out" bash "$ENTRY" 2>&1)"; RC=$?
    log_run "D13" "$RC" "$OUT"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    [ "$(count_anchor "$OUT")" = "0" ] || ok=0
    printf '%s\n' "$OUT" | grep -q 'reason=new_source_bad_vectors=11' || ok=0
    RD="$(printf '%s\n' "$OUT" | sed -n 's/^RENAME_RUN_DIR=//p')"
    if [ -n "$RD" ] && [ -s "$RD/test_rename.log" ]; then
        FAILED="$(grep -oE '^\[new\] case [0-9]+ VERDICT=' "$RD/test_rename.log" \
                  | grep -oE '[0-9]+' | LC_ALL=C sort -n | tr '\n' ' ')"
        EXP="$(for t in $SPEC_TRIGGERS; do echo "$t"; done | LC_ALL=C sort -n | tr '\n' ' ')"
        [ "$FAILED" = "$EXP" ] || ok=0
    else
        ok=0
    fi
    if [ "$ok" -eq 0 ]; then
        sub_fail "D13_dut_root_old_tree" "rc=$RC expect=1 failed_vec_set_or_reason_mismatch"
    else sub_ok "D13_dut_root_old_tree"; fi
else
    sub_fail "D13_dut_root_old_tree" "git_archive_failed"
fi

# ---- D14 毒 cwd：诱饵 rtl/rename.v 与头不得影响结果 ----
DECOY="$W/decoy-cwd"
mkdir -p -- "$DECOY/rtl/back2" "$DECOY/rtl/pkg" "$DECOY/scripts" "$DECOY/build/functional" || true
printf 'module rename; endmodule // DECOY\n' > "$DECOY/rtl/back2/rename.v"
printf '`define BACK2_DECOY 1\n'            > "$DECOY/rtl/back2/back2_params.vh"
out_env_reset
OUT="$( cd -- "$DECOY" && OUT_DIR="$DECOY/build/functional/out" bash "$ENTRY" 2>&1 )"; RC=$?
log_run "D14_poison_cwd" "$RC" "$OUT"
if [ "$RC" -ne 0 ] || [ "$(count_anchor "$OUT")" != "1" ] \
   || ! printf '%s\n' "$OUT" | grep -qE "$SPEC_SUMMARY"; then
    sub_fail "D14_poison_cwd" "rc=$RC expect=0 anchor=$(count_anchor "$OUT")"
else sub_ok "D14_poison_cwd"; fi

# ---- D15 阶段间改源 TB：自检模式必须在旧阶段前精确拒绝 ----
FXS="$W/fix-swap"
if mk_tb_fixture "$FXS" none; then
    SWAP_OUT="$W/swap.out"
    : > "$SWAP_OUT"
out_env_reset
    ( OUT_DIR="$FXS/build/functional/out" bash "$FXS/sim/functional/test_rename.sh" \
        > "$SWAP_OUT" 2>&1; echo "rc=$?" >> "$SWAP_OUT" ) &
    BG=$!
    RD=""
    for i in $(seq 1 500); do
        RD="$(sed -n 's/^RENAME_RUN_DIR=//p' "$SWAP_OUT" 2>/dev/null | head -1)"
        [ -n "$RD" ] && [ -s "$RD/test_rename.log" ] && break
        sleep 0.02
    done
    if [ -n "$RD" ] && [ -s "$RD/test_rename.log" ]; then
        for i in $(seq 1 800); do
            grep -qE '^VEC new 3 ' "$RD/test_rename.log" && break
            sleep 0.02
        done
        sed -i 's/cname="ctrl_full_no_fire"/cname="ctrl_full_no_fireX"/' \
            "$FXS/sim/functional/tb_rename_semantics.sv" 2>/dev/null || true
    fi
    wait "$BG" 2>/dev/null || true
    SRC="$(cat -- "$SWAP_OUT" 2>/dev/null || true)"
    log_run "D15_stage_tb_swap" "bg" "$SRC"
    if printf '%s\n' "$SRC" | grep -qE 'reason=source_tb_changed_(between_phases|during_run)' \
       && [ "$(count_anchor "$SRC")" = "0" ]; then
        sub_ok "D15_stage_tb_swap"
    else
        sub_fail "D15_stage_tb_swap" "not_rejected_by_source_tb_changed"
    fi
else
    sub_fail "D15_stage_tb_swap" "fixture_setup_failed"
fi

# ---- D16 产物纪律：两次运行各自独占、均保留 ----
out_env_reset
O1="$(OUT_DIR="$W/d16-out" bash "$ENTRY" 2>&1)"; R1=$?
out_env_reset
O2="$(OUT_DIR="$W/d16-out" bash "$ENTRY" 2>&1)"; R2=$?
log_run "D16_run1" "$R1" "$O1"; log_run "D16_run2" "$R2" "$O2"
D1="$(printf '%s\n' "$O1" | sed -n 's/^RENAME_RUN_DIR=//p')"
D2="$(printf '%s\n' "$O2" | sed -n 's/^RENAME_RUN_DIR=//p')"
if [ "$R1" -ne 0 ] || [ "$R2" -ne 0 ] || [ -z "$D1" ] || [ -z "$D2" ] \
   || [ "$D1" = "$D2" ] || [ ! -d "$D1" ] || [ ! -d "$D2" ]; then
    sub_fail "D16_unique_run_dirs" "r1=$R1 r2=$R2"
else sub_ok "D16_unique_run_dirs"; fi

# ---- D17 编译输入 sha256 清单：固定条数(=3) + 格式 + 运行后校验通过 ----
if [ -n "$D1" ] && [ -s "$D1/new.sha" ]; then
    LINES="$(grep -cE '^[0-9a-f]{64}  ' "$D1/new.sha" || true)"
    if [ "$LINES" -eq 3 ] && sha256sum -c --quiet -- "$D1/new.sha" >/dev/null 2>&1; then
        sub_ok "D17_input_sha_guard"
    else
        sub_fail "D17_input_sha_guard" "lines=$LINES expect=3 sha_check_failed"
    fi
else
    sub_fail "D17_input_sha_guard" "missing new.sha (run_dir=$D1)"
fi

# ---- D18 完整正确输出后 exit 9：必须按"运行失败"拒绝（不得只看输出）----
FT="$W/fake-exit9"
mkdir -p -- "$FT" || true
cat > "$FT/iverilog" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
[ -n "$out" ] && printf 'dummy-artifact\n' > "$out"; exit 0
EOF
cat > "$FT/vvp" <<EOF
#!/usr/bin/env bash
EOF
cat >> "$FT/vvp" <<'EOF'
out="$("REALVVP" "$@" 2>/dev/null)"; rc=$?
printf '%s\n' "$out"
exit 9
EOF
sed -i "s|REALVVP|$VV|" "$FT/vvp"
chmod +x "$FT/iverilog" "$FT/vvp" || true
out_env_reset
OUT="$(RV32_IVERILOG="$FT/iverilog" RV32_VVP="$FT/vvp" OUT_DIR="$W/d18-out" bash "$ENTRY" 2>&1)"; RC=$?
log_run "D18" "$RC" "$OUT"
ok=1
[ "$RC" -eq 1 ] || ok=0
[ "$(count_anchor "$OUT")" = "0" ] || ok=0
RD="$(printf '%s\n' "$OUT" | sed -n 's/^RENAME_RUN_DIR=//p')"
[ -n "$RD" ] && grep -qE 'run rc=9' "$RD/test_rename.log" 2>/dev/null || ok=0
if [ "$ok" -eq 0 ]; then sub_fail "D18_exit9_after_output" "rc=$RC expect=1 reason_bind_failed"
else sub_ok "D18_exit9_after_output"; fi

# ---- D19 共享输入读不出（sha 取不到）⇒ 必须拒，且原因是 tb_sha_unavailable ----
FXR="$W/fix-unreadable"
if mk_tb_fixture "$FXR" none; then
    chmod 000 -- "$FXR/sim/functional/tb_rename_semantics.sv" || true
    run_fixture "$FXR"
    chmod 644 -- "$FXR/sim/functional/tb_rename_semantics.sv" 2>/dev/null || true
    if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=tb_sha_unavailable'; then
        sub_fail "D19_hash_unavailable" "rc=$RC expect=1 reason=tb_sha_unavailable"
    else sub_ok "D19_hash_unavailable"; fi
else
    sub_fail "D19_hash_unavailable" "fixture_setup_failed"
fi

# ---- D20 共享 env 运行中被改 ⇒ 必须精确拒绝 ----
FXE="$W/fix-envswap"
if mk_tb_fixture "$FXE" none; then
    SW2="$W/envswap.out"; : > "$SW2"
out_env_reset
    ( OUT_DIR="$FXE/build/functional/out" bash "$FXE/sim/functional/test_rename.sh" \
        > "$SW2" 2>&1; echo "rc=$?" >> "$SW2" ) &
    BG=$!
    RD=""
    for i in $(seq 1 500); do
        RD="$(sed -n 's/^RENAME_RUN_DIR=//p' "$SW2" 2>/dev/null | head -1)"
        [ -n "$RD" ] && [ -s "$RD/test_rename.log" ] && break
        sleep 0.02
    done
    if [ -n "$RD" ] && [ -s "$RD/test_rename.log" ]; then
        for i in $(seq 1 800); do
            grep -qE '^VEC new 3 ' "$RD/test_rename.log" && break
            sleep 0.02
        done
        printf '\n# swapped\n' >> "$FXE/scripts/env.sh" 2>/dev/null || true
    fi
    wait "$BG" 2>/dev/null || true
    SRC2="$(cat -- "$SW2" 2>/dev/null || true)"
    log_run "D20_env_swap" "bg" "$SRC2"
    if printf '%s\n' "$SRC2" | grep -qE 'reason=env_changed_(during_run|while_sourcing)' \
       && [ "$(count_anchor "$SRC2")" = "0" ]; then
        sub_ok "D20_env_swap"
    else
        sub_fail "D20_env_swap" "not_rejected_by_env_changed"
    fi
else
    sub_fail "D20_env_swap" "fixture_setup_failed"
fi

# ---- D21 单文件 sha 打印完整一行后 exit 9（共享清单调用正常）⇒ 必须精确拒绝 ----
FS="$W/fake-sha"
mkdir -p -- "$FS" || true
REALSHA="$(command -v sha256sum)"
cat > "$FS/sha256sum" <<EOF
#!/usr/bin/env bash
#   单文件调用（sha256sum -- FILE，2 个参数）：先交给真工具打印**真实完整一行**，再 exit 9。
#   多文件（共享输入清单）与 -c 校验：完全正常 —— 证明拒绝来自"单文件 sha 的 rc"而非旁因。
if [ "\$#" -eq 2 ]; then
    "$REALSHA" "\$@"
    exit 9
fi
exec "$REALSHA" "\$@"
EOF
chmod +x "$FS/sha256sum" || true
out_env_reset
OUT="$(PATH="$FS:$PATH" OUT_DIR="$W/d21-out" bash "$ENTRY" 2>&1)"; RC=$?
log_run "D21" "$RC" "$OUT"
ok=1
[ "$RC" -eq 1 ] || ok=0
[ "$(count_anchor "$OUT")" = "0" ] || ok=0
printf '%s\n' "$OUT" | grep -qE 'reason=(tb_sha_unavailable|freeze_tb_sha_unavailable|pkg_sha_unavailable|env_sha_unavailable|tb_sha_malformed|freeze_tb_sha_malformed)' || ok=0
# 反证：同一次运行里"共享清单调用"是正常的（不得报 sha256 命令失败/清单行数不符）
printf '%s\n' "$OUT" | grep -qE 'reason=(sha256|hex_line|manifest)' && ok=0
if [ "$ok" -eq 0 ]; then sub_fail "D21_sha_single_exit9" "rc=$RC expect=1 reason_bind_failed"
else sub_ok "D21_sha_single_exit9"; fi

# ---- D22 私有 env：正常设好工具变量、末尾 return 9、文件全程不改 ⇒ 正式入口必须精确拒 ----
FXSRC="$W/fix-envsrc"
if mk_tb_fixture "$FXSRC" none; then
    cat > "$FXSRC/scripts/env.sh" <<EOF
#!/usr/bin/env bash
#   私有 env（反证用）：正常设置工具变量，末尾 return 9；运行期间本文件不再改动。
RV32_ROOT="$FXSRC"
export RV32_ROOT
RV32_IVERILOG="$IV"
RV32_VVP="$VV"
export RV32_IVERILOG RV32_VVP
return 9
EOF
    SRC_BEFORE="$(sha256sum -- "$FXSRC/scripts/env.sh" | cut -c1-64)"
    run_fixture "$FXSRC"
    SRC_AFTER="$(sha256sum -- "$FXSRC/scripts/env.sh" | cut -c1-64)"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    [ "$(count_anchor "$OUT")" = "0" ] || ok=0
    printf '%s\n' "$OUT" | grep -q 'reason=env_sh_source_rc=9' || ok=0
    #   不得被旁因杀伤：工具缺失/哈希变化/编译失败都不许出现
    printf '%s\n' "$OUT" | grep -qE 'reason=(tool_missing|env_changed|tb_sha|pkg_sha|compile_|snapshot_)' && ok=0
    #   文件全程未被改动（证明拒绝来自 source 返回码，而不是"env 被改"）
    [ "$SRC_BEFORE" = "$SRC_AFTER" ] || ok=0
    if [ "$ok" -eq 0 ]; then
        sub_fail "D22_env_source_rc9" "rc=$RC expect=1 reason=env_sh_source_rc=9"
    else sub_ok "D22_env_source_rc9"; fi
else
    sub_fail "D22_env_source_rc9" "fixture_setup_failed"
fi

# ---- D23 带父 PKGOUT 的 driver 合法正控（leaf 保护，避免递归）----
if [ "${RN_DRIVER_LEAF:-0}" = "1" ]; then
    sub_ok "D23_parent_pkgout_positive"
else
    PP="$W/self-parent"
    mkdir -p -- "$PP" || true
    out_env_reset
    CH="$(RV32_FUNCTIONAL_PKG_OUT_DIR="$PP/rename-driver" RN_DRIVER_LEAF=1 \
          bash "$SELF_PATH" 2>&1)"; CHR=$?
    printf -- '---- D23 child driver rc=%s ----\n%s\n' "$CHR" "$CH" >> "$LOG"
    if [ "$CHR" -eq 0 ] && printf '%s\n' "$CH" | grep -qxF 'FUNCTIONAL_RENAME_DRIVER: PASS' \
       && printf '%s\n' "$CH" | grep -qE '^RENAME_DRIVER_TESTS total=[0-9]+ failed=0'; then
        sub_ok "D23_parent_pkgout_positive"
    else
        sub_fail "D23_parent_pkgout_positive" "child_rc=$CHR expect=0"
    fi
fi

# ---- D24 同一 fixture：父 PKGOUT 非法 ⇒ 拒；父 PKGOUT 合法 ⇒ 正控 PASS ----
FX24="$W/fix-parentpkgout"
if mk_tb_fixture "$FX24" none; then
    ok24=1
    out_env_reset
    OUT="$(RV32_FUNCTIONAL_PKG_OUT_DIR="$W/not-authorized-out" \
            OUT_DIR="$FX24/build/functional/out" \
            bash "$FX24/sim/functional/test_rename.sh" 2>&1)"; RC=$?
    log_run "D24a_unauth" "$RC" "$OUT"
    [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'reason=out_root_unauthorized' \
        && [ "$(count_anchor "$OUT")" = "0" ] || ok24=0
    out_env_reset
    OUT="$(RV32_FUNCTIONAL_PKG_OUT_DIR="$FX24/build/functional/out2" \
            bash "$FX24/sim/functional/test_rename.sh" 2>&1)"; RC2=$?
    log_run "D24b_legal" "$RC2" "$OUT"
    [ "$RC2" -eq 0 ] && [ "$(count_anchor "$OUT")" = "1" ] || ok24=0
    if [ "$ok24" -eq 0 ]; then
        sub_fail "D24_fixture_parent_pkgout" "rc=$RC/$RC2 expect=1/0"
    else sub_ok "D24_fixture_parent_pkgout"; fi
else
    sub_fail "D24_fixture_parent_pkgout" "fixture_setup_failed"
fi

# ---- 汇总 ----
if [ "$NG" -ne 0 ]; then
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=subtests_failed count=%s work_dir=%s\n' "$NG" "$W"
    exit 1
fi
printf 'RENAME_DRIVER_TESTS total=%s failed=0 work_dir=%s\n' "$NT" "$W" | tee -a "$LOG"
printf 'FUNCTIONAL_RENAME_DRIVER: PASS\n'
exit 0
