#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_2a_control.sh —— 2A 顶层控制（EPC）与计数器程序序 helper
#==============================================================================
# 目标（用户 2026-10-22 指派）：
#   A. taken 控制转移退休拍中断 EPC 正确（jal/jalr/c.j/taken beq/bne；not-taken 控制）；
#      mret 退休拍 EPC = 返回目标（含 halfword-aligned C 流，含 2 mod 4 高半）。
#   B. mcycle 跨半 carry 的**程序序投影**：W+M 双写者 / 更早写改低半影响后 tick 进位。
#   C. instret 读 = 本条执行前值：相邻两读/写后读/半字 carry/与更老提交/长停顿交错。
#------------------------------------------------------------------------------
# 判据（fail-closed）：
#   · 固定输入闭包（RTL 全树 + 本 TB + fixtures + env + 两脚本）先快照进 RUN_DIR/src，
#     记录 before/after SHA 清单；编译/汇编/运行全程在**快照 root 内**（不读活树）。
#   · 每个 case 由 driver 跑：vvp rc=0、`2A_CTL_RESULT: PASS` 恰 1 行、0 个
#     `2A_CTL_CHK_BAD|2A_CTL_FAIL|2A_CTL_TIMEOUT`、`2A_CTL_CHECKS: total==固定表 bad=0`。
#   · TB 内部把"场景窗口未命中"（dual_writer_window_hit）直接判 bad ⇒ 未覆盖不算通过。
#   · 汇总 cases/checks/controls 与固定表逐项一致后才打印唯一锚点：
#       FUNCTIONAL_2A_CONTROL: PASS
#   · `--rtl-root DIR`：换 RTL 根（旧树/变异树）跑同一矩阵（负控证据）。
#   · `--mutants`：对快照副本注入**具体功能**变异（非编译错），要求对应 case 变红且
#     原因匹配；no-op 变异必须仍绿。
#------------------------------------------------------------------------------
# 产物纪律：只写 REPO_ROOT/build/functional 之下；父给 RV32_FUNCTIONAL_PKG_OUT_DIR 时
#          在其下 mktemp 独占子目录；不删除历史目录；不用 /tmp（除 driver 自检用 $TMPDIR）。
# 身份纪律：执行脚本/TB/driver/fixtures/env 的 SHA 在 source 前后与尾部各复检一次。
# 用法：
#   bash sim/functional/test_2a_control.sh
#   bash sim/functional/test_2a_control.sh --rtl-root build/functional/2a-control-close/old-coretop
#   bash sim/functional/test_2a_control.sh --mutants
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
mkdir -p -- "$REPO_ROOT/build/functional" || { printf 'ERROR: 无法创建 SHA 私有区\n' >&2; exit 1; }
SHA_TMP_ROOT="$(mktemp -d -- "$REPO_ROOT/build/functional/.2a-sha-XXXXXXXX")" || { printf 'ERROR: 无法创建 SHA 私有区\n' >&2; exit 1; }
ENV_SH="${REPO_ROOT}/scripts/env.sh"
TB_REL="sim/functional/tb_2a_control.sv"
DRIVER_REL="sim/functional/test_2a_control_driver.sh"
FIX_REL="sim/functional/fixtures/2a_control"
ANCHOR='FUNCTIONAL_2A_CONTROL: PASS'

MODE="default"; RTL_ROOT_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rtl-root) [ "$#" -ge 2 ] || { printf 'ERROR: --rtl-root needs DIR\n' >&2; exit 2; }
                    RTL_ROOT_ARG="$2"; shift 2 ;;
        --mutants)  MODE="mutants"; shift ;;
        --mret-mie1) MODE="mret-mie1"; shift ;;
        --sha-self-test) MODE="sha-self-test"; shift ;;
        -h|--help)  printf 'usage: %s [--rtl-root DIR] [--mutants]\n' "$0"; exit 0 ;;
        *)          printf 'ERROR: unknown arg %s\n' "$1" >&2; exit 2 ;;
    esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
bad_out() { printf '2A_CONTROL_BAD: %s\n' "$*"; exit 1; }

if [ -n "${DUT_ROOT:-}" ]; then
    dut="$(realpath -m -- "$DUT_ROOT")"
    [ "$dut" = "$REPO_ROOT" ] || die "DUT_ROOT($dut) != script repo root($REPO_ROOT)"
fi
RTL_ROOT="$REPO_ROOT"
if [ -n "$RTL_ROOT_ARG" ]; then
    case "$RTL_ROOT_ARG" in /*) RTL_ROOT="$RTL_ROOT_ARG" ;; *) RTL_ROOT="$REPO_ROOT/$RTL_ROOT_ARG" ;; esac
    RTL_ROOT="$(realpath -m -- "$RTL_ROOT")"
fi
[ -d "$RTL_ROOT/rtl" ] || die "RTL root 缺少 rtl/：$RTL_ROOT"

sha1f() {
    local f="$1" raw line rc=0 nlines nbytes expected_bytes last
    [ -f "$f" ] || return 1
    raw="$(mktemp -- "$SHA_TMP_ROOT/file-raw.XXXXXXXX")" || return 1
    sha256sum -- "$f" >"$raw" 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || { rm -f -- "$raw"; return "$rc"; }
    nlines="$(wc -l <"$raw")" || { rm -f -- "$raw"; return 1; }
    nbytes="$(wc -c <"$raw")" || { rm -f -- "$raw"; return 1; }
    [ "$nlines" -eq 1 ] || { rm -f -- "$raw"; return 90; }
    IFS= read -r line <"$raw" || { rm -f -- "$raw"; return 90; }
    expected_bytes=$((${#line} + 1))
    last="$(tail -c 1 -- "$raw" | od -An -tx1 | tr -d ' \\n')"
    [ "$nbytes" -eq "$expected_bytes" ] && [ "$last" = 0a ] || { rm -f -- "$raw"; return 90; }
    [[ "${line:0:64}" =~ ^[0-9a-f]{64}$ ]] && [ "${line:64:2}" = '  ' ] \
        && [ "${line:66}" = "$f" ] || { rm -f -- "$raw"; return 91; }
    rm -f -- "$raw"
    printf '%s' "${line:0:64}"
}
[ -r "$ENV_SH" ] || die "缺少 $ENV_SH"
[ -r "$REPO_ROOT/$TB_REL" ] || die "缺少 TB $TB_REL"
[ -r "$REPO_ROOT/$DRIVER_REL" ] || die "缺少 driver $DRIVER_REL"
[ -d "$REPO_ROOT/$FIX_REL" ] || die "缺少 fixtures $FIX_REL"
for t in sha256sum realpath mktemp timeout; do command -v "$t" >/dev/null 2>&1 || die "缺少 $t"; done

AUX_SHA0="$(sha1f "$SCRIPT_PATH")" || die "sha(script) rc=$?"
AUX_TB0="$(sha1f "$REPO_ROOT/$TB_REL")" || die "sha(tb) rc=$?"
AUX_DRV0="$(sha1f "$REPO_ROOT/$DRIVER_REL")" || die "sha(driver) rc=$?"
AUX_ENV0="$(sha1f "$ENV_SH")" || die "sha(env) rc=$?"
fix_sha() {
    local manifest sorted f h out bn rc=0
    manifest="$(mktemp -- "$SHA_TMP_ROOT/fixture-list.XXXXXXXX")" || return 1
    sorted="${manifest}.sorted"
    : > "$manifest" || { rm -f -- "$manifest"; return 1; }
    for f in "$REPO_ROOT/$FIX_REL"/*.S; do
        [ -f "$f" ] || { rm -f -- "$manifest" "$sorted"; return 1; }
        h="$(sha1f "$f")" || { rc=$?; rm -f -- "$manifest" "$sorted"; return "$rc"; }
        bn="${f##*/}"
        printf '%s  %s\n' "$h" "$bn" >> "$manifest" || { rm -f -- "$manifest" "$sorted"; return 1; }
    done
    LC_ALL=C sort -- "$manifest" > "$sorted" || { rm -f -- "$manifest" "$sorted"; return 1; }
    out="$(sha1f "$sorted")" || { rc=$?; rm -f -- "$manifest" "$sorted"; return "$rc"; }
    rm -f -- "$manifest" "$sorted"
    printf '%s' "$out"
}
sha_meta_selftest() {
    local d real mode got expect ok=0 total=0 saved_path="$PATH"
    d="$RUN_DIR/sha-meta"; mkdir -p -- "$d" || return 1
    real="$(command -v sha256sum)" || return 1
    cat > "$d/sha256sum" <<'EOS'
#!/bin/sh
out="$("$FAKE_REAL_SHA" "$@")" || exit $?
case "$FAKE_SHA_MODE" in
 valid) printf '%s\n' "$out" ;;
 extra_lf) printf '%s\n\n' "$out" ;;
 multi_blank) printf '%s\n\n\n' "$out" ;;
 unterminated) printf '%s' "$out" ;;
 wrongpath) h="${out%%  *}"; p="${out#*  }"; printf '%s  X%s\n' "$h" "${p#?}" ;;
 garbage) printf '%s\nJUNK\n' "$out" ;;
 nul) printf '%s\n' "$out"; printf '\0' ;;
 stdout_rc9) printf '%s\n' "$out"; exit 9 ;;
esac
EOS
    chmod +x "$d/sha256sum" || return 1
    PATH="$d:$PATH"; export PATH
    export FAKE_REAL_SHA="$real"
    for mode in valid extra_lf multi_blank unterminated wrongpath garbage nul stdout_rc9; do
        export FAKE_SHA_MODE="$mode"
        case "$mode" in valid) expect=0 ;; wrongpath) expect=91 ;; stdout_rc9) expect=9 ;; *) expect=90 ;; esac
        total=$((total + 1))
        if sha1f "$REPO_ROOT/$DRIVER_REL" >/dev/null 2>&1; then got=0; else got=$?; fi
        if [ "$got" -eq "$expect" ]; then ok=$((ok + 1)); printf '2A_SHA_META: caller=sha1f mode=%s reason=rc_%s OK\n' "$mode" "$got"
        else printf '2A_SHA_META: caller=sha1f mode=%s expected_rc=%s got_rc=%s MISMATCH\n' "$mode" "$expect" "$got"; fi
        total=$((total + 1))
        if fix_sha >/dev/null 2>&1; then got=0; else got=$?; fi
        if [ "$got" -eq "$expect" ]; then ok=$((ok + 1)); printf '2A_SHA_META: caller=fix_sha mode=%s reason=rc_%s OK\n' "$mode" "$got"
        else printf '2A_SHA_META: caller=fix_sha mode=%s expected_rc=%s got_rc=%s MISMATCH\n' "$mode" "$expect" "$got"; fi

        total=$((total + 1))
        if manifest >/dev/null 2>&1; then got=0; else got=$?; fi
        if [ "$got" -eq "$expect" ]; then ok=$((ok + 1)); printf '2A_SHA_META: caller=manifest_prepost mode=%s reason=rc_%s OK\n' "$mode" "$got"
        else printf '2A_SHA_META: caller=manifest_prepost mode=%s expected_rc=%s got_rc=%s MISMATCH\n' "$mode" "$expect" "$got"; fi
    done
    PATH="$saved_path"; export PATH
    printf '2A_SHA_META_SUMMARY: total=%s ok=%s bad=%s\n' "$total" "$ok" "$((total-ok))"
    [ "$ok" -eq "$total" ]
}
AUX_FIX0="$(fix_sha)" || die "sha(fixtures) rc=$?"

ENV_RC=0
set +e
# shellcheck source=../../scripts/env.sh
. "$ENV_SH"
ENV_RC=$?
set -e
[ "$ENV_RC" -eq 0 ] || die "source env.sh 非零 rc=$ENV_RC"

aux_recheck() {
    local where="$1" fx
    [ "$(sha1f "$SCRIPT_PATH")" = "$AUX_SHA0" ] || die "script 变了 @$where"
    [ "$(sha1f "$REPO_ROOT/$TB_REL")" = "$AUX_TB0" ] || die "TB 变了 @$where"
    [ "$(sha1f "$REPO_ROOT/$DRIVER_REL")" = "$AUX_DRV0" ] || die "driver 变了 @$where"
    [ "$(sha1f "$ENV_SH")" = "$AUX_ENV0" ] || die "env 变了 @$where"
    fx="$(fix_sha)"; [ "$fx" = "$AUX_FIX0" ] || die "fixtures 变了 @$where"
}
aux_recheck "after-source"

IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"; GCC="${RV32_GCC:-}"; OCP="${RV32_OBJCOPY:-}"; RE="${RV32_READELF:-}"
[ -n "$IV" ] && [ -x "$IV" ] || die "缺少 iverilog"
[ -n "$VV" ] && [ -x "$VV" ] || die "缺少 vvp"
[ -n "$GCC" ] && [ -x "$GCC" ] || die "缺少 gcc"
[ -n "$OCP" ] && [ -x "$OCP" ] || die "缺少 objcopy"
[ -n "$RE" ] && [ -x "$RE" ] || die "缺少 readelf"

# ---- 产物根：规范化 → 授权 → mktemp 独占 ----
AUTH_ROOT="$(realpath -m -- "$REPO_ROOT/build/functional")"
is_auth() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/2a-control}"
case "$ROOT_RAW" in /*) ROOT_CAND="$ROOT_RAW" ;; *) ROOT_CAND="$REPO_ROOT/$ROOT_RAW" ;; esac
ROOT_CAND="$(realpath -m -- "$ROOT_CAND")" || die "产物根规范化失败"
is_auth "$ROOT_CAND" || die "产物根不在授权树：$ROOT_CAND"
mkdir -p -- "$ROOT_CAND" || die "无法创建产物根"
ROOT_CAND="$(realpath -m -- "$ROOT_CAND")" || die "产物根再规范化失败"
is_auth "$ROOT_CAND" || die "产物根逃出授权树"
RUN_DIR="$(mktemp -d -- "$ROOT_CAND/run-XXXXXXXX")" || die "mktemp 失败"
RUN_LOG="$RUN_DIR/run.log"; : > "$RUN_LOG"
printf '2A_CONTROL_RUN_DIR=%s\n' "$RUN_DIR" | tee -a "$RUN_LOG"
printf '2A_CONTROL_MODE=%s RTL_ROOT=%s\n' "$MODE" "$RTL_ROOT" | tee -a "$RUN_LOG"
#==============================================================================
# 快照：闭包复制到 RUN_DIR/src
#==============================================================================
SNAP="$RUN_DIR/src"; mkdir -p -- "$SNAP"
copy_abs() { mkdir -p -- "$SNAP/$(dirname -- "$1")" && cp -p -- "$2" "$SNAP/$1"; }
while IFS= read -r f; do
    rel="${f#"$RTL_ROOT"/}"
    copy_abs "$rel" "$f" || die "snapshot copy $f"
done < <(find "$RTL_ROOT/rtl" -type f \( -name '*.v' -o -name '*.vh' \) | LC_ALL=C sort)
copy_abs "$TB_REL" "$REPO_ROOT/$TB_REL" || die "snapshot tb"
copy_abs "$DRIVER_REL" "$REPO_ROOT/$DRIVER_REL" || die "snapshot driver"
mkdir -p -- "$SNAP/$FIX_REL"
cp -p -- "$REPO_ROOT/$FIX_REL"/*.S "$SNAP/$FIX_REL/" || die "snapshot fixtures"
copy_abs "scripts/env.sh" "$ENV_SH" || die "snapshot env"

manifest() {
    local tmp rel h rc=0
    tmp="$(mktemp -- "$RUN_DIR/.manifest-raw.XXXXXXXX")" || return 1
    : > "$tmp" || { rm -f -- "$tmp"; return 1; }
    while IFS= read -r rel; do
        h="$(sha1f "$SNAP/${rel#./}")" || { rc=$?; rm -f -- "$tmp"; return "$rc"; }
        printf '%s  %s\n' "$h" "$rel" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    done < <(cd -- "$SNAP" && find . -type f -not -path './build/*' | LC_ALL=C sort)
    LC_ALL=C sort -- "$tmp"
    rc=$?
    rm -f -- "$tmp"
    return "$rc"
}
if [ "$MODE" = "sha-self-test" ]; then
    sha_meta_selftest || die "SHA meta self-test failed"
    printf 'FUNCTIONAL_2A_CONTROL_SHA_META: PASS\n'
    exit 0
fi
manifest > "$RUN_DIR/inputs.sha.before" || die "manifest before"
[ -s "$RUN_DIR/inputs.sha.before" ] || die "manifest 空"

#==============================================================================
# 编译 TB（一次）与汇编程序变体
#==============================================================================
COMPILE_LOG="$RUN_DIR/compile.log"
RTLSRC="$(cd -- "$SNAP" && find rtl -name '*.v' | LC_ALL=C sort | tr '\n' ' ')"
( cd -- "$SNAP" && timeout 600 "$IV" -g2012 -I rtl/pkg -I . -s tb_2a_control \
      -o "$RUN_DIR/tb_2a_control.vvp" $RTLSRC "$TB_REL" ) > "$COMPILE_LOG" 2>&1 \
    || bad_out "tb_compile log=$COMPILE_LOG"
[ -s "$RUN_DIR/tb_2a_control.vvp" ] || bad_out "tb_vvp_empty"

PROG_DIR="$RUN_DIR/prog"; mkdir -p -- "$PROG_DIR"
: > "$RUN_DIR/asm.log"
asm_one() {   # $1=outbase $2=source-relative $3..=defs
    local base="$1" src="$2"; shift 2
    local defs="" d
    for d in "$@"; do [ -n "$d" ] && defs="$defs -D$d"; done
    # shellcheck disable=SC2086
    "$GCC" $defs -march=rv32imafdc_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
        -Wl,--build-id=none -Ttext=0x00010000 -o "$PROG_DIR/$base.elf" "$SNAP/$src" >> "$RUN_DIR/asm.log" 2>&1 \
        || { bad_out "asm_elf base=$base"; }
    "$OCP" -O verilog --verilog-data-width=4 "$PROG_DIR/$base.elf" "$PROG_DIR/$base.hex" \
        >> "$RUN_DIR/asm.log" 2>&1 || { bad_out "asm_hex base=$base"; }
    [ -s "$PROG_DIR/$base.hex" ] || { bad_out "asm_hex_empty base=$base"; }
}
sym() {   # $1=elf $2=symbol
    local v
    v="$("$RE" -sW -- "$1" | awk -v s="$2" '$8==s {print $2; exit}')"
    [ -n "$v" ] || return 1
    printf '0x%08x' "$((16#$v))"
}

asm_one irq_jal     "$FIX_REL/irq_ctl.S"  CTL_JAL
asm_one irq_jalr    "$FIX_REL/irq_ctl.S"  CTL_JALR
asm_one irq_cj      "$FIX_REL/irq_ctl.S"  CTL_CJ
asm_one irq_beq     "$FIX_REL/irq_ctl.S"  CTL_BEQ
asm_one irq_bne     "$FIX_REL/irq_ctl.S"  CTL_BNE
asm_one irq_beq_nt  "$FIX_REL/irq_ctl.S"  CTL_BEQ_NT
asm_one irq_mret    "$FIX_REL/irq_mret.S"
asm_one irq_mret_mie1 "$FIX_REL/irq_mret.S" MRET_MIE1
asm_one irq_mret_mie1_hi "$FIX_REL/irq_mret.S" MRET_MIE1 MRET_HI
asm_one irq_mret_hi "$FIX_REL/irq_mret.S" MRET_HI
asm_one cnt_order   "$FIX_REL/cnt_order.S"
asm_one cnt_order_neg_old "$FIX_REL/cnt_order.S" P7_NEG_OLD
asm_one cnt_order_neg_post "$FIX_REL/cnt_order.S" P7_NEG_POST
asm_one c_hi_jalr16 "$FIX_REL/c_hi.S" HH_JALR16
asm_one c_hi_32x    "$FIX_REL/c_hi.S" HH_32X
asm_one c_hi_ptail  "$FIX_REL/c_hi.S" HH_PAGETAIL
asm_one c_hi_cancel "$FIX_REL/c_hi.S" HH_CANCEL
asm_one c_hi_fault  "$FIX_REL/c_hi.S" HH_FAULT
asm_one c_hi_haz    "$FIX_REL/c_hi.S" HH_HAZ
asm_one fp_flags    "$FIX_REL/fp_flags.S"
asm_xip_one() {   # $1=outbase $2=source-relative $3..=defs
    local base="$1" src="$2"; shift 2
    local defs="" d
    for d in "$@"; do [ -n "$d" ] && defs="$defs -D$d"; done
    # shellcheck disable=SC2086
    "$GCC" $defs -march=rv32imafdc_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
        -Wl,--build-id=none -Ttext=0x1c000000 -o "$PROG_DIR/$base.elf" "$SNAP/$src" >> "$RUN_DIR/asm.log" 2>&1 \
        || { bad_out "asm_xip_elf base=$base"; }
    "$OCP" -O verilog --verilog-data-width=4 "$PROG_DIR/$base.elf" "$PROG_DIR/$base.hex" \
        >> "$RUN_DIR/asm.log" 2>&1 || { bad_out "asm_xip_hex base=$base"; }
    [ -s "$PROG_DIR/$base.hex" ] || { bad_out "asm_xip_hex_empty base=$base"; }
}
asm_xip_one xip_haz_nt "$FIX_REL/xip_haz.S" OLD_ONE
asm_xip_one xip_haz_t  "$FIX_REL/xip_haz.S" EXPECT_TAKEN
asm_one c_hi_err_first "$FIX_REL/c_hi_err.S" ERR_FIRST
asm_one c_hi_err_hi16  "$FIX_REL/c_hi_err.S" ERR_HI16
asm_one c_hi_err_hi32  "$FIX_REL/c_hi_err.S" ERR_HI32
asm_one c_hi_err_hipg  "$FIX_REL/c_hi_err.S" ERR_HI32PG
asm_one c_hi_err_late  "$FIX_REL/c_hi_err.S" ERR_LATE

# 固定 case 表：
#   id|name|scen|kind|base|ctrl_sym|mret_sym|exp_sym|irq|rdelay|expect_checks|extra
#   extra：空 / CANCEL（要求取消窗口命中）/ TVAL_PLUS2（EXP_TVAL = exp_epc+2）
declare -a CASES=(
 "1|irq_jal|irq_ctl|jal|irq_jal|ctl_pc||target|1|0|12|"
 "2|irq_jalr|irq_ctl|jalr|irq_jalr|ctl_pc||target|1|0|12|"
 "3|irq_cj|irq_ctl|cj|irq_cj|ctl_pc||target|1|0|11|"
 "4|irq_beq|irq_ctl|beq|irq_beq|ctl_pc||target|1|0|11|"
 "5|irq_bne|irq_ctl|bne|irq_bne|ctl_pc||target|1|0|11|"
 "6|irq_beq_nt|irq_ctl_nt|beq_nt|irq_beq_nt|ctl_pc|||1|0|12|"
 "7|irq_mret|mret_mpie0||irq_mret||mret_pc|ret_target|1|0|8|"
 "8|irq_mret_hi|mret_mpie0||irq_mret_hi||mret_pc|ret_target|1|0|8|"
 "9|cnt_order|cnt_order||cnt_order||||0|40|16|"
 "10|hh_jalr16|hi_exec||c_hi_jalr16||||0|0|2|"
 "11|hh_32x|hi_exec||c_hi_32x||||0|0|2|"
 "12|hh_pagetail|hi_exec||c_hi_ptail||||0|0|2|"
 "13|hh_cancel|hi_exec||c_hi_cancel||||0|40|3|CANCEL_DLY"
 "14|hh_fault|hi_fault||c_hi_fault|||fault_insn|0|0|7|TVAL_PLUS2"
 "15|fp_flags|fp_flags||fp_flags||||0|0|5|"
 "16|err_first|err_exec||c_hi_err_first|||t_insn|0|0|6|ERR_SAME"
 "17|err_hi16|err_exec||c_hi_err_hi16|||t_insn|0|0|6|ERR_SAME"
 "18|err_hi32|err_exec||c_hi_err_hi32|||t_insn|0|0|6|ERR_NEXT"
 "19|err_hi32pg|err_exec||c_hi_err_hipg|||t_insn|0|0|6|ERR_NEXT_DEC"
 "20|err_late|err_late||c_hi_err_late|||t_insn|0|40|7|ERR_LATE"
 "21|hh_haz|haz_exec||c_hi_haz||||0|0|5|"
 "22|irq_mret_mie1|mret_mie1||irq_mret_mie1||mret_pc|ret_target|1|0|10|"
 "23|irq_mret_mie1_hi|mret_mie1||irq_mret_mie1_hi||mret_pc|ret_target|1|0|10|"
  "24|xip_haz_not|xip_haz||xip_haz_nt||||0|20|10|XIP_NOT"
  "25|xip_haz_taken|xip_haz||xip_haz_t||||0|20|10|XIP_TAKEN"
)
N_CASES="${#CASES[@]}"
N_CHECKS_EXPECT=198

# 计算某 case 的 ctrl_pc / mret_pc / exp_epc（写入全局 CASE_CTRL/CASE_MRET/CASE_EXP）
set_case_args() {   # $1=rec
    local rec="$1" id name scen kind base csym msym esym irq rdelay expchk extra
    IFS='|' read -r id name scen kind base csym msym esym irq rdelay expchk extra <<<"$rec"
    CASE_CANCEL=0; CASE_ARM_HI=0; CASE_TVAL="0x00000000"
    CASE_ERR_LO="0x00000000"; CASE_ERR_HI="0x00000000"; CASE_ERR_KIND=0
    CASE_DLO="0x00003000"; CASE_DHI="0x00003100"
    CASE_LOAD_PC="0x00000000"; CASE_BRANCH_PC="0x00000000"
    CASE_MARKER="0x00000000"; CASE_BAD_MARKER="0x00000000"
    CASE_DATA_VAL="0"
    local elf="$PROG_DIR/$base.elf"
    CASE_CTRL="0x00000000"; CASE_MRET="0x00000000"; CASE_EXP="0x00000000"
    if [ -n "$csym" ]; then CASE_CTRL="$(sym "$elf" "$csym")" || bad_out "sym $csym @$base"; fi
    if [ -n "$msym" ]; then CASE_MRET="$(sym "$elf" "$msym")" || bad_out "sym $msym @$base"; fi
    if [ -n "$esym" ]; then
        CASE_EXP="$(sym "$elf" "$esym")" || bad_out "sym $esym @$base"
    elif [ "$scen" = "irq_ctl_nt" ]; then
        CASE_EXP="$(printf '0x%08x' "$((16#${CASE_CTRL#0x} + 4))")"
    fi
    case "$extra" in
        CANCEL)     CASE_CANCEL=1 ;;
        TVAL_PLUS2) CASE_TVAL="$(printf '0x%08x' "$((16#${CASE_EXP#0x} + 2))")" ;;
        ERR_SAME|ERR_NEXT|ERR_NEXT_DEC) CASE_TVAL="$CASE_EXP"
                    local line
                    if [ "$extra" = "ERR_SAME" ]; then
                        line=$((16#${CASE_EXP#0x} & ~31))
                    else
                        line=$(( (16#${CASE_EXP#0x} + 2) & ~31))
                        CASE_TVAL="$(printf '0x%08x' "$((16#${CASE_EXP#0x} + 2))")"
                    fi
                    CASE_ERR_LO="$(printf '0x%08x' "$line")"
                    CASE_ERR_HI="$(printf '0x%08x' "$((line + 32))")"
                    [ "$extra" = "ERR_NEXT_DEC" ] && CASE_ERR_KIND=3 || CASE_ERR_KIND=2 ;;
        ERR_LATE)  CASE_ARM_HI=1; CASE_ERR_KIND=2
                    local line
                    line=$(( (16#${CASE_EXP#0x} + 2) & ~31))
                    CASE_TVAL="$(printf '0x%08x' "$((16#${CASE_EXP#0x} + 2))")"
                    CASE_ERR_LO="$(printf '0x%08x' "$line")"
                    CASE_ERR_HI="$(printf '0x%08x' "$((line + 32))")"
                    CASE_DLO="$CASE_ERR_LO"; CASE_DHI="$CASE_ERR_HI" ;;
        CANCEL_DLY) CASE_CANCEL=1; CASE_ARM_HI=1
                    local insn
                    insn="$(sym "$elf" hh_insn)" || bad_out "sym hh_insn @$base"
                    CASE_DLO="$(printf '0x%08x' "$((16#${insn#0x} + 2))")"
                    CASE_DHI="$(printf '0x%08x' "$((16#${insn#0x} + 34))")" ;;
        XIP_NOT)   CASE_LOAD_PC="$(sym "$elf" load_pc)" || bad_out "sym load_pc @$base"
                    CASE_BRANCH_PC="$(sym "$elf" branch_pc)" || bad_out "sym branch_pc @$base"
                    CASE_MARKER="0x00001111"; CASE_BAD_MARKER="0x00000000"; CASE_DATA_VAL="0" ;;
        XIP_TAKEN) CASE_LOAD_PC="$(sym "$elf" load_pc)" || bad_out "sym load_pc @$base"
                    CASE_BRANCH_PC="$(sym "$elf" branch_pc)" || bad_out "sym branch_pc @$base"
                    CASE_MARKER="0x0000600d"; CASE_BAD_MARKER="0x00000000"; CASE_DATA_VAL="1" ;;
    esac
}

run_case() {   # $1=rec
    local rec="$1" id name scen kind base csym msym esym irq rdelay expchk extra
    IFS='|' read -r id name scen kind base csym msym esym irq rdelay expchk extra <<<"$rec"
    set_case_args "$rec"
    local log="$RUN_DIR/case_${id}_${name}.log" dout="$RUN_DIR/driver_${id}_${name}.out"
    local rc=0
    bash "$SNAP/$DRIVER_REL" --id "$id" --name "$name" --scen "$scen" --kind "$kind" \
        --hex "$PROG_DIR/$base.hex" --ctrl-pc "$CASE_CTRL" --mret-pc "$CASE_MRET" \
        --exp-epc "$CASE_EXP" --exp-tval "$CASE_TVAL" --cancel "$CASE_CANCEL" \
        --delay-lo "$CASE_DLO" --delay-hi "$CASE_DHI" --arm-hi "$CASE_ARM_HI" \
        --err-lo "$CASE_ERR_LO" --err-hi "$CASE_ERR_HI" --err-kind "$CASE_ERR_KIND" \
        --load-pc "$CASE_LOAD_PC" --branch-pc "$CASE_BRANCH_PC" \
        --exp-marker "$CASE_MARKER" --exp-bad-marker "$CASE_BAD_MARKER" \
        --data-val "$CASE_DATA_VAL" \
        --irq "$irq" --rdelay "$rdelay" --checks "$expchk" \
        --log "$log" --vvp "$RUN_DIR/tb_2a_control.vvp" > "$dout" 2>&1 || rc=$?
    cat -- "$dout" >> "$RUN_LOG"
    [ "$rc" -eq 0 ] || { cat -- "$dout" >&2; return 1; }
    local line
    line="$(grep -m1 -E '^2A_CONTROL_CASE: ' "$dout" || true)"
    [ -n "$line" ] || { printf '2A_CONTROL_BAD: driver_line_missing id=%s\n' "$id"; return 1; }
    case "$line" in
        *"id=$id name=$name "*"checks=$expchk "*"result=pass") : ;;
        *) printf '2A_CONTROL_BAD: driver_line_mismatch id=%s line=%s\n' "$id" "$line"; return 1 ;;
    esac
    printf '%s\n' "$line"
}

#------------------------------------------------------------------------------
# 窄边界确证（不进门禁）：MRET 退休/架构下一边界上外部中断仍 eligible 时，
#   mstatus 落地必须 MIE=0 / MPIE=1 / MPP=M；同时给同拍 xret/trap 帧与 set/clr。
#   本模式**失败不打印 PASS 锚点**（它是确证，不是正向功能项）；结果行：
#     `2A_MRET_BOUNDARY: OK` / `2A_MRET_BOUNDARY: DEFECT ...`
#------------------------------------------------------------------------------
if [ "$MODE" = "mret-mie1" ]; then
    rec="99|irq_mret_mie1|mret_mie1||irq_mret_mie1||mret_pc|ret_target|1|0|9|"
    set_case_args "$rec"
    log="$RUN_DIR/case_21_irq_mret_mie1.log"
    bash "$SNAP/$DRIVER_REL" --id 99 --name irq_mret_mie1 --scen mret_mie1 --kind "" \
         --hex "$PROG_DIR/irq_mret_mie1.hex" --ctrl-pc "$CASE_CTRL" --mret-pc "$CASE_MRET" \
         --exp-epc "$CASE_EXP" --exp-tval "$CASE_TVAL" --cancel 0 \
         --delay-lo 0x00003000 --delay-hi 0x00003100 --arm-hi 0 \
         --err-lo 0x0 --err-hi 0x0 --err-kind 0 --irq 1 --rdelay 0 --checks 9 \
         --log "$log" --vvp "$RUN_DIR/tb_2a_control.vvp" > "$RUN_DIR/drv21.out" 2>&1 || true
    grep -E "2A_CTL_MRET_FRAME|2A_CTL_MRET_TRAPS|2A_CTL_TRAP " "$log" || true
    frame_stable="$(sed -n 's/.*stable_masked=0x//p' "$log" | head -1)"
    n_int="$(sed -n 's/.*n_int_trap=\([0-9]*\).*/\1/p' "$log" | head -1)"
    if [ "${n_int:-0}" = "1" ] && [ "$((16#${frame_stable:-0}))" = "$((16#1880))" ]; then
        printf '2A_MRET_BOUNDARY: OK int_traps=1 mstatus_stable_mask=0x1880\n'
        exit 0
    fi
    printf '2A_MRET_BOUNDARY: DEFECT int_traps=%s mstatus_stable_mask=0x%s（同拍 xret+trap 的 mstatus 集合 OR：MIE 被 xret 置 1 ⇒ 处理程序入口多取一次中断；帧见上）\n' \
           "${n_int:-?}" "${frame_stable:-?}"
    exit 1
fi

if [ "$MODE" = "default" ]; then
    pass=0; total_chk=0
    for rec in "${CASES[@]}"; do
        IFS='|' read -r _id _nm _sc _kd _bs _cs _ms _es _iq _rd expchk _ex <<<"$rec"
        if run_case "$rec"; then
            pass=$((pass + 1)); total_chk=$((total_chk + expchk))
        else
            printf '2A_CONTROL_SUMMARY: cases=%d pass=%d bad=%d checks=%d\n' \
                   "$N_CASES" "$pass" "$((N_CASES - pass))" "$total_chk"
            printf '2A_CONTROL_RESULT: NOT-ACCEPTED\n'
            exit 1
        fi
    done
    [ "$pass" -eq "$N_CASES" ] || { printf '2A_CONTROL_RESULT: NOT-ACCEPTED\n'; exit 1; }
    printf '2A_CONTROL_SUMMARY: cases=%d pass=%d bad=0 checks=%d controls=1\n' "$N_CASES" "$pass" "$total_chk"
    [ "$N_CASES" -eq 25 ] || die "固定表 cases=$N_CASES != 25"
    [ "$total_chk" -eq "$N_CHECKS_EXPECT" ] || die "固定表 checks=$total_chk != $N_CHECKS_EXPECT"
    manifest > "$RUN_DIR/inputs.sha.after" || die "manifest after"
    cmp -s "$RUN_DIR/inputs.sha.before" "$RUN_DIR/inputs.sha.after" || die "快照在运行期间被改动"
    aux_recheck "tail"
    printf '%s\n' "$ANCHOR"
    exit 0
fi

#==============================================================================
# 变异模式：--mutants
#==============================================================================
if [ "$MODE" = "mutants" ]; then
    MUTOK=0; MUTN=0; MUTBAD=0
    mkdir -p -- "$RUN_DIR/mut"

    build_variant() {   # $1=dir $2=mutation-id
        local d="$1" mid="$2"
        rm -rf -- "$d"; cp -a -- "$SNAP" "$d"
        python3 - "$d" "$mid" <<'PY'
import os, sys
d, mid = sys.argv[1], sys.argv[2]
def load(rel):
    with open(os.path.join(d, rel)) as f:
        return f.read()
def save(rel, txt):
    with open(os.path.join(d, rel), "w") as f:
        f.write(txt)
core = load("rtl/top/core_top.v")
fet  = load("rtl/fetch/fetch_unit.v")
def rep(old, new, txt):
    if old not in txt:
        print("MUT_PATCH_MISS", file=sys.stderr); raise SystemExit(3)
    return txt.replace(old, new, 1)
if mid == "noop":
    core = rep("// rtl/top/core_top.v", "// rtl/top/core_top.v", core)
elif mid == "epc_link":
    core = rep("mw_pc_next      <= em_archnext_q;", "mw_pc_next      <= em_pc_next;", core)
elif mid == "xret_link":
    core = rep("wire [31:0] mw_archnext_w = mw_xret_valid ? xret_epc_pc : mw_pc_next;",
               "wire [31:0] mw_archnext_w = mw_pc_next;", core)
elif mid == "link_target":
    core = rep("wire [31:0] em_n_pcnext = e_link;",
               "wire [31:0] em_n_pcnext = (e_is_ctl_xfer & e_bru_taken & ~de_ill & ~de_exc_valid) ? e_bru_target : e_link;", core)
elif mid == "inst_no_w":
    # 可达变异：投影漏掉 W 槽退休 +1（2A 前端固定 2 拍/条 ⇒ M 槽在 E 有效拍恒空，
    # 故 M 分支不可达、只能作为源级完备性；W 分支才是可达语义）。
    core = rep("(inst_retire_w ? instret_cnt + 64'd1 : instret_cnt)",
               "instret_cnt", core)
elif mid == "bus_mepc_old":
    # 变异（回注旧总线错误口径）：D 级 PC 取 live fetch_pc（这是 mepc 的真正来源，
    # trap_ctrl.epc_raw 对异常取 commit_pc = mw_pc = fd_pc 链），高半 32 bit 第二字
    # 取指错时 mepc 会变成第二字地址（应为指令起始）。同时回注 fetch_exc_pc 旧口径。
    core = rep("                fd_pc        <= fu_fetch_insn_va;",
               "                fd_pc        <= fetch_bus_err ? fu_fetch_pc : fu_fetch_insn_va;", core)
    core = rep("assign fetch_exc_pc    = fu_exc_gated ? fu_exc_pc    : fu_fetch_insn_va;",
               "assign fetch_exc_pc    = fu_exc_gated ? fu_exc_pc    : fu_fetch_pc;", core)
elif mid == "hi_gate":
    # 变异（旧缺陷回注）：高半起始一律不出指令（原 insn_valid_w 门控）
    fet = rep("wire        insn_valid_w = insn_start_lo ? insn_valid\n                                             : (hi32_q ? 1'b1 : ~start_is32);",
              "wire        insn_valid_w = insn_valid & insn_start_lo;", fet)
elif mid == "hi_nocancel":
    # 变异：redirect 不清在途首 parcel（旧 carry 泄漏）
    fet = rep("        end else if (redirect_exc_valid | redirect_bru_valid) begin\n            hi32_q        <= 1'b0;\n        end else if (hi32_take) begin",
              "        end else if (hi32_take) begin", fet)
elif mid == "mc_no_tick":
    core = rep("wire [63:0] mc_e1 = cycle_cnt + 64'd1;", "wire [63:0] mc_e1 = cycle_cnt;", core)
elif mid == "xip_unstalled_redirect":
    core = rep("e_bru_taken & pipe_adv &", "e_bru_taken &", core)
else:
    raise SystemExit("unknown mutation " + mid)
save("rtl/top/core_top.v", core)
save("rtl/fetch/fetch_unit.v", fet)
PY
        local rl
        rl="$(cd -- "$d" && find rtl -name '*.v' | LC_ALL=C sort | tr '\n' ' ')"
        ( cd -- "$d" && timeout 600 "$IV" -g2012 -I rtl/pkg -I . -s tb_2a_control \
              -o "$d/tb.vvp" $rl "$TB_REL" ) > "$d/compile.log" 2>&1 || return 1
        [ -s "$d/tb.vvp" ] || return 1
        return 0
    }

    run_p7_negative() {   # $1=base $2=bad-check $3=control-check
        local base="$1" bad_check="$2" control_check="$3"
        local log="$RUN_DIR/mut/${base}.log" dout="$RUN_DIR/mut/${base}.out" rc=0
        MUTN=$((MUTN + 1))
        if bash "$SNAP/$DRIVER_REL" --id 90 --name "$base" --scen cnt_order --kind "" \
            --hex "$PROG_DIR/${base}.hex" --irq 0 --rdelay 40 --data-val 0 --checks 16 \
            --log "$log" --vvp "$RUN_DIR/tb_2a_control.vvp" > "$dout" 2>&1; then
            printf '2A_CONTROL_MUT: mut=%s result=green(UNEXPECTED) log=%s\n' "$base" "$log"
            MUTBAD=$((MUTBAD + 1)); return 1
        else
            rc=$?
        fi
        local bad_count
        bad_count="$(grep -c '^2A_CTL_CHK_BAD:' "$log" || true)"
        if [ "$rc" -eq 0 ] || [ "$bad_count" -ne 1 ] || \
           ! grep -q "^2A_CTL_CHK_BAD: ${bad_check} " "$log" || \
           ! grep -q "^2A_CTL_CHK: ${control_check} = 0x00000001 ok$" "$log" || \
           ! grep -q '^2A_CTL_CHECKS: total=16 bad=1$' "$log"; then
            printf '2A_CONTROL_MUT: mut=%s result=red-wrong-reason bad_count=%s log=%s\n' "$base" "$bad_count" "$log"
            MUTBAD=$((MUTBAD + 1)); return 1
        fi
        MUTOK=$((MUTOK + 1))
        printf '2A_CONTROL_MUT: mut=%s result=red(ok) only=%s control=%s\n' "$base" "$bad_check" "$control_check"
        return 0
    }

    run_mutant() {   # $1=mut-id $2=rec $3=want-regex
        local mid="$1" rec="$2" want="$3"
        local d="$RUN_DIR/mut/$mid" id name scen kind base csym msym esym irq rdelay expchk extra
        IFS='|' read -r id name scen kind base csym msym esym irq rdelay expchk extra <<<"$rec"
        MUTN=$((MUTN + 1))
        if ! build_variant "$d" "$mid"; then
            printf '2A_CONTROL_MUT: mut=%s case=%s result=compile_bad\n' "$mid" "$name"
            MUTBAD=$((MUTBAD + 1)); return 1
        fi
        set_case_args "$rec"
        local ctrl_pc="$CASE_CTRL" mret_pc="$CASE_MRET" exp_epc="$CASE_EXP"
        local log="$d/case_${id}_${name}.log"
        bash "$d/$DRIVER_REL" --id "$id" --name "$name" --scen "$scen" --kind "$kind" \
            --hex "$PROG_DIR/$base.hex" --ctrl-pc "$ctrl_pc" --mret-pc "$mret_pc" \
            --exp-epc "$exp_epc" --exp-tval "$CASE_TVAL" --cancel "$CASE_CANCEL" \
            --delay-lo "$CASE_DLO" --delay-hi "$CASE_DHI" --arm-hi "$CASE_ARM_HI" \
        --err-lo "$CASE_ERR_LO" --err-hi "$CASE_ERR_HI" --err-kind "$CASE_ERR_KIND" \
            --load-pc "$CASE_LOAD_PC" --branch-pc "$CASE_BRANCH_PC" \
            --exp-marker "$CASE_MARKER" --exp-bad-marker "$CASE_BAD_MARKER" \
            --data-val "$CASE_DATA_VAL" \
            --irq "$irq" --rdelay "$rdelay" --checks "$expchk" \
            --log "$log" --vvp "$d/tb.vvp" > "$d/driver.out" 2>&1
        local drc=$?
        local line
        if [ "$mid" = "noop" ]; then
            if [ "$drc" -eq 0 ] && grep -qxF '2A_CTL_RESULT: PASS' "$log"; then
                MUTOK=$((MUTOK + 1))
                printf '2A_CONTROL_MUT: mut=%s case=%s result=still-green(ok)\n' "$mid" "$name"
                return 0
            fi
            printf '2A_CONTROL_MUT: mut=%s case=%s result=noop-red(UNEXPECTED) log=%s\n' "$mid" "$name" "$log"
            MUTBAD=$((MUTBAD + 1)); return 1
        fi
        if [ "$drc" -ne 0 ] && grep -qxF '2A_CTL_RESULT: PASS' "$log" 2>/dev/null; then
            printf '2A_CONTROL_MUT: mut=%s case=%s result=pass-anchor-but-driver-red log=%s\n' "$mid" "$name" "$log"
            MUTBAD=$((MUTBAD + 1)); return 1
        fi
        [ "$drc" -ne 0 ] || { printf '2A_CONTROL_MUT: mut=%s case=%s result=green(UNEXPECTED) log=%s\n' "$mid" "$name" "$log"; MUTBAD=$((MUTBAD + 1)); return 1; }
        if ! grep -qE "$want" "$log"; then
            printf '2A_CONTROL_MUT: mut=%s case=%s result=red-wrong-reason(%s) log=%s\n' "$mid" "$name" "$want" "$log"
            MUTBAD=$((MUTBAD + 1)); return 1
        fi
        MUTOK=$((MUTOK + 1))
        printf '2A_CONTROL_MUT: mut=%s case=%s result=red(ok) reason=%s\n' "$mid" "$name" "$want"
        return 0
    }

    run_mutant noop         "9|cnt_order|cnt_order||cnt_order||||0|40|16|" '2A_CTL_CHK_BAD' || true
    run_mutant epc_link     "1|irq_jal|irq_ctl|jal|irq_jal|ctl_pc||target|1|0|12|" '2A_CTL_CHK_BAD: mem_mepc' || true
    run_mutant xret_link    "22|irq_mret_mie1|mret_mie1||irq_mret_mie1||mret_pc|ret_target|1|0|10|" '2A_CTL_CHK_BAD: mem_mepc' || true
    run_mutant link_target  "2|irq_jalr|irq_ctl|jalr|irq_jalr|ctl_pc||target|1|0|12|" '2A_CTL_CHK_BAD: mem_link' || true
    run_mutant inst_no_w    "9|cnt_order|cnt_order||cnt_order||||0|40|16|" '2A_CTL_CHK_BAD: half_carry_hi' || true
    run_mutant mc_no_tick   "9|cnt_order|cnt_order||cnt_order||||0|40|16|" '2A_CTL_CHK_BAD: mcycle_w_carry' || true
    run_mutant hi_gate      "10|hh_jalr16|hi_exec||c_hi_jalr16||||0|0|2|" '2A_CTL_CHK_BAD: hi_path_marker' || true
    run_mutant bus_mepc_old "18|err_hi32|err_exec||c_hi_err_hi32|||t_insn|0|0|6|ERR_NEXT" '2A_CTL_CHK_BAD: err_mepc_insn' || true
    run_mutant xip_unstalled_redirect "24|xip_haz_not|xip_haz||xip_haz_nt||||0|20|10|XIP_NOT" '2A_CTL_CHK_BAD: xip_branch_exactly_once|xip_target_marker' || true
    run_p7_negative cnt_order_neg_old rmw_read_old rmw_post_read || true
    run_p7_negative cnt_order_neg_post rmw_post_read rmw_read_old || true

    printf '2A_CONTROL_MUT_SUMMARY: total=%d ok=%d bad=%d\n' "$MUTN" "$MUTOK" "$MUTBAD"
    [ "$MUTN" -eq 11 ] || die "变异数 $MUTN != 11"
    [ "$MUTBAD" -eq 0 ] && [ "$MUTOK" -eq "$MUTN" ] || die "变异未全部按预期（ok=$MUTOK/$MUTN bad=$MUTBAD）"
    manifest > "$RUN_DIR/inputs.sha.after" || die "manifest after"
    cmp -s "$RUN_DIR/inputs.sha.before" "$RUN_DIR/inputs.sha.after" || die "快照在运行期间被改动"
    aux_recheck "tail"
    printf 'FUNCTIONAL_2A_CONTROL_MUTANTS: PASS\n'
    exit 0
fi

die "unknown mode $MODE"
