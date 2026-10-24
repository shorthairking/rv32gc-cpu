#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_data_bus.sh —— F4 数据总线语义包入口（fail-closed）
#==============================================================================
# 用途：Top 包统一调用本入口；**不注册默认 10 包**（按母 Agent 协调，由后续 Top 包调用）。
#   spec      ：正向（真实 core_top_2b + 定向程序 + 可控 AXI 从设备）
#   --self-test：只验本包判据的反证（唯一锚点/rc/超时/坏 token/缺头），不跑正控
# 产物：build/functional/data-bus/（父 PKGOUT 可用 RV32_FUNCTIONAL_PKG_OUT_DIR 覆盖）
#==============================================================================
set -u
MODE="spec"
if [ "$#" -gt 1 ]; then printf 'FUNCTIONAL_DATA_BUS: FAIL reason=unknown_arg\n'; exit 1; fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test) MODE="self-test" ;;
        *) printf 'FUNCTIONAL_DATA_BUS: FAIL reason=unknown_arg arg=%s\n' "$1"; exit 1 ;;
    esac
fi
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_BUS: FAIL reason=self_dir\n'; exit 1; }
DRV="$SELF_DIR/test_data_bus_driver.sh"
[ -x "$DRV" ] || chmod +x "$DRV" 2>/dev/null || true
[ -f "$DRV" ] || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=driver_missing\n'; exit 1; }
case "${RV32_DATA_BUS_MODE:-spec}" in
    spec) ;;
    self-test) MODE="self-test" ;;
    *) printf 'FUNCTIONAL_DATA_BUS: FAIL reason=bad_mode\n'; exit 1 ;;
esac

AUTH_ROOT="$(readlink -m -- "$(cd -- "$SELF_DIR/../.." && pwd -P)/build/functional")"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/data-bus}"
is_auth() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=out_root\n'; exit 1; }
is_auth "$ROOT_NORM" || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=out_root_unauthorized\n'; exit 1; }
mkdir -p -- "$ROOT_NORM" || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=out_root_mkdir\n'; exit 1; }
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/entry-XXXXXXXX")" || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=mktemp\n'; exit 1; }
LOG="$RUN_DIR/test_data_bus.log"
: > "$LOG"
printf 'DATA_BUS_ENTRY_RUN_DIR=%s\n' "$RUN_DIR"

if [ "$MODE" = "spec" ]; then
    RV32_FUNCTIONAL_PKG_OUT_DIR="$RUN_DIR/spec" timeout "${TIMEOUT_DATA_BUS_S:-1800}" \
        bash "$DRV" > "$RUN_DIR/driver.log" 2>&1
    RC=$?
    cat -- "$RUN_DIR/driver.log" >> "$LOG"
    [ "$RC" -eq 0 ] || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=driver_rc=%s\n' "$RC"; exit 1; }
    [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$RUN_DIR/driver.log" || true)" = "1" ] \
        || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=driver_anchor\n'; exit 1; }
    [ "$(grep -cE 'FAIL|[^A-Za-z]XZ|UNKNOWN' "$RUN_DIR/driver.log" || true)" = "0" ] \
        || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=driver_bad_token\n'; exit 1; }
    # ---- mandatory 子域：真实架构 IRQ/PLIC 链（2eed 发布；缺失即 fail）----
    #      单独 canonical PKGOUT + 独立 rc/超时/唯一 anchor，不并进主 driver 判据。
    IRQ_SH="$SELF_DIR/test_data_bus_irq.sh"
    [ -f "$IRQ_SH" ] || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_subdomain_missing\n'; exit 1; }
    IRQ_ROOT="$AUTH_ROOT/data-bus-irq"
    mkdir -p -- "$IRQ_ROOT" || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_pkgout\n'; exit 1; }
    IRQ_PKG="$(mktemp -d -- "$IRQ_ROOT/entry-XXXXXXXX")" || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_mktemp\n'; exit 1; }
    printf 'DATA_BUS_IRQ_RUN_DIR=%s\n' "$IRQ_PKG"
    # 用主 driver 同一份**冻结源快照**（src/）作 DUT_ROOT，避免脏工作树默认根
    DRV_RUN="$(sed -n 's/^DATA_BUS_RUN_DIR=//p' "$RUN_DIR/driver.log" | tail -1)"
    [ -n "$DRV_RUN" ] && [ -d "$DRV_RUN/src/rtl" ] \
        || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_dut_root_missing\n'; exit 1; }
    DUT_ROOT="$DRV_RUN/src" RV32_FUNCTIONAL_PKG_OUT_DIR="$IRQ_PKG" PKGOUT="$IRQ_PKG" \
        timeout "${TIMEOUT_DATA_BUS_IRQ_S:-1200}" bash "$IRQ_SH" > "$IRQ_PKG/run.log" 2>&1
    IRC=$?
    cat -- "$IRQ_PKG/run.log" >> "$LOG"
    [ "$IRC" -eq 0 ] || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_subdomain_rc=%s\n' "$IRC"; exit 1; }
    [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS_IRQ: PASS' "$IRQ_PKG/run.log" || true)" = "1" ] \
        || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_subdomain_anchor\n'; exit 1; }
    [ "$(grep -cE 'FAIL|DEFECT' "$IRQ_PKG/run.log" || true)" = "0" ] \
        || { printf 'FUNCTIONAL_DATA_BUS: FAIL reason=irq_subdomain_bad_token\n'; exit 1; }
    printf 'DATA_BUS_TESTS total=2 ok=2\n' >> "$LOG"
    printf 'FUNCTIONAL_DATA_BUS: PASS\n' >> "$LOG"
    printf 'DATA_BUS_TESTS total=2 ok=2\n'
    printf 'FUNCTIONAL_DATA_BUS: PASS\n'
    exit 0
fi

# 反证：驱动自带 self-test + 本入口的锚点/坏 token 反证
RV32_FUNCTIONAL_PKG_OUT_DIR="$RUN_DIR/neg" timeout "${TIMEOUT_DATA_BUS_S:-900}" \
    bash "$DRV" --self-test > "$RUN_DIR/driver_neg.log" 2>&1
RC=$?
cat -- "$RUN_DIR/driver_neg.log" >> "$LOG"
[ "$RC" -eq 0 ] || { printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: FAIL reason=driver_neg_rc=%s\n' "$RC"; exit 1; }
[ "$(grep -cxF 'FUNCTIONAL_DATA_BUS_NEGATIVE: PASS' "$RUN_DIR/driver_neg.log" || true)" = "1" ] \
    || { printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: FAIL reason=driver_neg_anchor\n'; exit 1; }
[ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$RUN_DIR/driver_neg.log" || true)" = "0" ] \
    || { printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: FAIL reason=default_anchor\n'; exit 1; }
printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: PASS\n' >> "$LOG"
printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: PASS\n'
exit 0
