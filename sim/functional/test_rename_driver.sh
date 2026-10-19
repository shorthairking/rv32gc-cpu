#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_rename_driver.sh —— F2 重命名包**验收夹具自检**（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2B-5）
# 依据 : prompts/common.md §3（关键特性配正反证；关特性/注缺陷后必须 FAIL，否则视为未测到）、
#        sim/functional/manifest.tsv（本包锚点 = 唯一整行 `FUNCTIONAL_RENAME: PASS`）。
#
# 做什么（只读产品代码；所有夹具/产物落在 build/functional/rename/driver-*/，绝不 rm）:
#   D1  未知参数          → 入口 rc=1 且 reason=unknown_arg，stdout 无任何 PASS 锚点
#   D2  非法模式          → 入口 rc=1 且 reason=bad_mode
#   D3  越权 OUT_DIR      → 入口 rc=1 且 reason=out_root_unauthorized（规范化后校验）
#   D4  缺工具            → 入口 rc=1 且 reason=tool_missing name=RV32_VVP
#   D5  **合法假工具正控**：包装真工具（记录调用）→ 入口仍 rc=0 且锚点恰 1 行
#   D6  假 iverilog 产出 0 字节 vvp（rc=0）→ 入口 rc=1 且 reason=compile_new_failed
#   D7  假 vvp 只打印伪造 PASS 行 → 入口 rc=1（无 CASE 行 ⇒ 失败，且不打印锚点）
#   D8  假 vvp 打印格式坏的 CASE 行（缺 nchk）→ 入口 rc=1（严格格式拒绝）
#   D9  假 vvp 打印 nchk 远低于下限的 CASE 行 → 入口 rc=1（防少跑/空跑）
#   D10 TB 变异①：某向量提前收工（nchk 低于下限）→ 入口拒绝
#   D11 TB 变异②：TB 自行打印伪造 `FUNCTIONAL_RENAME: PASS` → 锚点计数 ≠1 ⇒ 拒绝
#   D12 产物纪律：连续两次运行各自独占 run 目录、均保留（不 rm 历史）
#   D13 DUT_ROOT 生效：指向 201acf61 旧树 ⇒ 默认模式必须失败（触发例旧红）
#
# 判定：每条逐项核 rc + stdout 关键 reason + 锚点计数；任一不符即 FAIL（exit 1）。
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

[ -f "$ENTRY" ] || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=entry_missing path=%s\n' "$ENTRY"; exit 1; }
[ -f "$TB" ]    || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=tb_missing path=%s\n' "$TB"; exit 1; }

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || exit 1
mkdir -p -- "$AUTH_ROOT/rename" || exit 1
W="$(mktemp -d -- "$AUTH_ROOT/rename/driver-XXXXXXXX")" || {
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=workdir_mktemp_failed\n'; exit 1; }
LOG="$W/driver.log"
: > "$LOG" || exit 1
printf 'FUNCTIONAL_RENAME_DRIVER_WORK=%s\n' "$W"

# 工具真源（只读；env.sh 允许读不可改）
# shellcheck disable=SC1090
. "$ENV_SH" >> "$LOG" 2>&1 || {
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=env_sh_source_failed\n'; exit 1; }
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=real_iverilog_missing\n'; exit 1; }
[ -n "$VV" ] && [ -x "$VV" ] || { printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=real_vvp_missing\n'; exit 1; }

NG=0
sub_fail() { printf 'DRV %-34s %s\n' "$1" "$2" | tee -a "$LOG" >&2; NG=$((NG+1)); }
sub_ok()   { printf 'DRV %-34s OK\n' "$1" >> "$LOG"; }

# 运行入口：$1.. = 入口参数；环境由调用者以 env 前缀注入
# 输出：RC / OUT（stdout）
run_entry() {
    OUT="$(bash "$ENTRY" "$@" 2>&1)"; RC=$?
    printf -- '---- run_entry %s (rc=%s) ----\n%s\n' "$*" "$RC" "$OUT" >> "$LOG"
}

log_run() { printf -- '---- %s rc=%s ----\n%s\n' "$1" "$2" "$3" >> "$LOG"; }

count_anchor() { printf '%s\n' "$1" | grep -cxF 'FUNCTIONAL_RENAME: PASS' || true; }
count_neg()    { printf '%s\n' "$1" | grep -cxF 'FUNCTIONAL_RENAME_NEGATIVE: PASS' || true; }

#------------------------------------------------------------------------------
# D5：合法假工具正控（包装真工具；仿真跑通即应 PASS）
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

#------------------------------------------------------------------------------
# 伪工具工厂：$1=目录  $2=mode
#   badsize = 不产出任何 vvp（exit 0）
#   spoof   = vvp 只打印伪造 PASS 行
#   badcase = vvp 打印缺 nchk 的 CASE 行
#   small   = vvp 打印 nchk=1 的 CASE 行
#------------------------------------------------------------------------------
mk_fake_tools() {
    local d="$1" mode="$2"
    mkdir -p -- "$d" || return 1
    if [ "$mode" = "badsize" ]; then
        #   0 字节产物：假 iverilog 直接 exit 0，不写 vvp
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/iverilog" || return 1
    else
        #   假 iverilog 写出**非空**占位 vvp，让入口走到"跑 vvp"这一步再被输出校验挡住
        cat > "$d/iverilog" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
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
echo "CASE $c int_x0_hard_zero KIND=control VERDICT=OK nchk=1"
exit 0
EOF
            ;;
    esac
    chmod +x -- "$d/vvp" 2>/dev/null || return 1
    return 0
}

#------------------------------------------------------------------------------
# TB 变异夹具：$1=fixture 根  $2=mode(early|spoof)
#   构造独立小仓库：scripts/env.sh（复制）+ rtl/back2/{rename.v,back2_params.vh}
#   + sim/functional/{test_rename.sh, tb_rename_semantics.sv(变异)} + build/functional
#------------------------------------------------------------------------------
mk_tb_fixture() {
    local fx="$1" mode="$2"
    mkdir -p -- "$fx/scripts" "$fx/rtl/back2" "$fx/sim/functional" "$fx/build/functional" || return 1
    cp -p -- "$ENV_SH" "$fx/scripts/env.sh" || return 1
    cp -p -- "$REPO_ROOT/rtl/back2/rename.v" "$fx/rtl/back2/rename.v" || return 1
    cp -p -- "$REPO_ROOT/rtl/back2/back2_params.vh" "$fx/rtl/back2/back2_params.vh" || return 1
    cp -p -- "$ENTRY" "$fx/sim/functional/test_rename.sh" || return 1
    local mut="$fx/sim/functional/tb_rename_semantics.sv"
    cp -p -- "$TB" "$mut" || return 1
    case "$mode" in
        early)
            #   变异①：把每条 CASE 行的 nchk 统一伪报成 1（"空跑/少跑冒充满跑"）⇒
            #   入口的逐向量 nchk 下限必须拒绝。
            sed -i 's/ckind, nchk);/ckind, 1);/' "$mut" || return 1
            [ "$(grep -c 'ckind, 1);' "$mut")" -ge 2 ] || return 1
            ;;
        spoof)
            #   变异②：TB 自行打印伪造正式锚点 ⇒ 入口锚点计数应 ≠1 而拒绝
            sed -i 's|if (errs == 0)|if (errs == 0) $display("FUNCTIONAL_RENAME: PASS");\n        if (errs == 0)|' "$mut" || return 1
            grep -q 'FUNCTIONAL_RENAME: PASS' "$mut" || return 1
            ;;
        *) return 1 ;;
    esac
    chmod +x -- "$fx/sim/functional/test_rename.sh" || return 1
    return 0
}

#==============================================================================
# 逐项
#==============================================================================

# ---- D1 未知参数 ----
run_entry --bogus-arg
log_run "D1_unknown_arg" "$RC" "$OUT"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=unknown_arg' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D1_unknown_arg" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D1_unknown_arg"; fi

# ---- D2 非法模式 ----
OUT="$(RV32_RENAME_MODE=weird bash "$ENTRY" 2>&1)"; RC=$?
log_run "D2_bad_mode" "$RC" "$OUT"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=bad_mode' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D2_bad_mode" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D2_bad_mode"; fi

# ---- D3 越权 OUT_DIR ----
OUT="$(OUT_DIR="$REPO_ROOT/build/rename-unauth" bash "$ENTRY" 2>&1)"; RC=$?
log_run "D3_out_unauthorized" "$RC" "$OUT"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=out_root_unauthorized' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D3_out_unauthorized" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D3_out_unauthorized"; fi

# ---- D4 缺工具 ----
OUT="$(RV32_VVP=/nonexistent/vvp bash "$ENTRY" 2>&1)"; RC=$?
log_run "D4_tool_missing" "$RC" "$OUT"
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=tool_missing name=RV32_VVP' \
   || [ "$(count_anchor "$OUT")" != "0" ]; then
    sub_fail "D4_tool_missing" "rc=$RC expect=1 reason_or_anchor_mismatch"
else sub_ok "D4_tool_missing"; fi

# ---- D5 合法假工具正控 ----
WT="$W/wrap-tools"
if mk_wrap_tools "$WT"; then
    OUT="$(RV32_IVERILOG="$WT/iverilog" RV32_VVP="$WT/vvp" OUT_DIR="$W/d5-out" bash "$ENTRY" 2>&1)"; RC=$?
    log_run "D5_fake_tool_positive" "$RC" "$OUT"
    if [ "$RC" -ne 0 ] || [ "$(count_anchor "$OUT")" != "1" ] \
       || ! printf '%s\n' "$OUT" | grep -q '^RENAME_VECTORS total=20 trigger=10 control=10 ok=20 bad=0$' \
       || [ ! -s "$WT/tool-calls.log" ]; then
        sub_fail "D5_fake_tool_positive" "rc=$RC expect=0 anchor=$(count_anchor "$OUT")"
    else sub_ok "D5_fake_tool_positive"; fi
else
    sub_fail "D5_fake_tool_positive" "wrap_tool_setup_failed"
fi

# ---- D6 假 iverilog 产出 0 字节 vvp ----
FT="$W/fake-badsize"
if mk_fake_tools "$FT" badsize; then
    OUT="$(RV32_IVERILOG="$FT/iverilog" RV32_VVP="$VV" OUT_DIR="$W/d6-out" bash "$ENTRY" 2>&1)"; RC=$?
    log_run "D6_zero_size_artifact" "$RC" "$OUT"
    if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'reason=compile_new_failed' \
       || [ "$(count_anchor "$OUT")" != "0" ]; then
        sub_fail "D6_zero_size_artifact" "rc=$RC expect=1 reason_or_anchor_mismatch"
    else sub_ok "D6_zero_size_artifact"; fi
else
    sub_fail "D6_zero_size_artifact" "fake_tool_setup_failed"
fi

# ---- D7/D8/D9 假 vvp 伪造输出 ----
for m in spoof badcase small; do
    FT="$W/fake-$m"
    if mk_fake_tools "$FT" "$m"; then
        OUT="$(RV32_IVERILOG="$FT/iverilog" RV32_VVP="$FT/vvp" OUT_DIR="$W/d7-$m" bash "$ENTRY" 2>&1)"; RC=$?
        log_run "D7_spoof_vvp_$m" "$RC" "$OUT"
        if [ "$RC" -ne 1 ] || [ "$(count_anchor "$OUT")" != "0" ]; then
            sub_fail "D7_spoof_vvp_$m" "rc=$RC expect=1 anchor=$(count_anchor "$OUT")"
        else sub_ok "D7_spoof_vvp_$m"; fi
    else
        sub_fail "D7_spoof_vvp_$m" "fake_tool_setup_failed"
    fi
done

# ---- D10 / D11 TB 变异拒绝 ----
for m in early spoof; do
    FX="$W/fix-$m"
    if mk_tb_fixture "$FX" "$m"; then
        OUT="$(OUT_DIR="$FX/build/functional/out" bash "$FX/sim/functional/test_rename.sh" 2>&1)"; RC=$?
        log_run "D10_tb_mutation_$m" "$RC" "$OUT"
        if [ "$RC" -ne 1 ] || [ "$(count_anchor "$OUT")" != "0" ]; then
            sub_fail "D10_tb_mutation_$m" "rc=$RC expect=1 anchor=$(count_anchor "$OUT")"
        else sub_ok "D10_tb_mutation_$m"; fi
    else
        sub_fail "D10_tb_mutation_$m" "fixture_setup_failed"
    fi
done

# ---- D12 产物纪律：两次运行各自独占、均保留 ----
O1="$(OUT_DIR="$W/d12-out" bash "$ENTRY" 2>&1)"; R1=$?
O2="$(OUT_DIR="$W/d12-out" bash "$ENTRY" 2>&1)"; R2=$?
log_run "D12_run1" "$R1" "$O1"
log_run "D12_run2" "$R2" "$O2"
D1="$(printf '%s\n' "$O1" | sed -n 's/^RENAME_RUN_DIR=//p')"
D2="$(printf '%s\n' "$O2" | sed -n 's/^RENAME_RUN_DIR=//p')"
if [ "$R1" -ne 0 ] || [ "$R2" -ne 0 ] || [ -z "$D1" ] || [ -z "$D2" ] \
   || [ "$D1" = "$D2" ] || [ ! -d "$D1" ] || [ ! -d "$D2" ]; then
    sub_fail "D12_unique_run_dirs" "r1=$R1 r2=$R2 d1=$D1 d2=$D2"
else sub_ok "D12_unique_run_dirs"; fi

# ---- D13 DUT_ROOT 生效：旧树默认模式必须失败 ----
OLD="$W/old-tree"
mkdir -p -- "$OLD" || true
if git -C "$REPO_ROOT" archive "$OLD_COMMIT" 2>>"$LOG" | tar -x -C "$OLD" >>"$LOG" 2>&1; then
    OUT="$(DUT_ROOT="$OLD" OUT_DIR="$W/d13-out" bash "$ENTRY" 2>&1)"; RC=$?
    log_run "D13_dut_root_old_tree" "$RC" "$OUT"
    if [ "$RC" -ne 1 ] || [ "$(count_anchor "$OUT")" != "0" ]; then
        sub_fail "D13_dut_root_old_tree" "rc=$RC expect=1 anchor=$(count_anchor "$OUT")"
    else sub_ok "D13_dut_root_old_tree"; fi
else
    sub_fail "D13_dut_root_old_tree" "git_archive_failed"
fi

# ---- D14 编译输入哈希：存在、格式严格、且运行后校验通过（前后不变） ----
if [ -n "$D1" ] && [ -s "$D1/new.sha" ]; then
    LINES="$(grep -cE '^[0-9a-f]{64}  ' "$D1/new.sha" || true)"
    if [ "$LINES" -ge 3 ] && sha256sum -c --quiet -- "$D1/new.sha" >/dev/null 2>&1; then
        sub_ok "D14_input_sha_guard"
    else
        sub_fail "D14_input_sha_guard" "lines=$LINES sha_check_failed"
    fi
else
    sub_fail "D14_input_sha_guard" "missing new.sha (run_dir=$D1)"
fi

# ---- 汇总 ----
if [ "$NG" -ne 0 ]; then
    printf 'FUNCTIONAL_RENAME_DRIVER: FAIL reason=subtests_failed count=%s work_dir=%s\n' "$NG" "$W"
    exit 1
fi
printf 'RENAME_DRIVER_TESTS total=14 failed=0 work_dir=%s\n' "$W" | tee -a "$LOG"
printf 'FUNCTIONAL_RENAME_DRIVER: PASS\n'
exit 0
