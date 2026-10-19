#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_memory.sh —— Memory 域**聚合入口**（cache-bus + mmu 两个正确入口）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二）
# 依据 : prompts/common.md §3（确定性脚本 + 退出码 + 日志锚点）；审计
#        `sim/audit/global-2026-10-18/04-memory-bus.md` 的 Memory 域两子域：
#          · cache-bus : 04-04 / 04-05 / 04-07（sim/functional/test_cache_bus.sh）
#          · mmu       : 04-01 / 04-02 / 04-03 / 04-06（sim/functional/test_mmu.sh）
#
# 做什么 :
#   依次调用**两个固定子域入口**（各自拥有自己的判定、反证与自检），本脚本只做聚合：
#     · 缺例（子域脚本不在）            ⇒ 失败，绝不占位 PASS
#     · 任一子域 rc≠0 / 超时 / 缺锚点   ⇒ 失败
#     · 任一子域输出含 FAIL / DEFECT_REPRODUCED ⇒ 失败
#   只有**两个子域全绿**才打印唯一整行 `FUNCTIONAL_MEMORY: PASS`。
#
# 计数口径（重要）：
#   本入口只报**包数**（2 个子域），**不把子域内的向量/断言数包装成入口级计数**
#   （见 sim/functional/manifest.tsv 的纪律说明）。
#
# 产物纪律：本次独占 run 目录（mktemp -d，绝不 rm），两个子域的日志都落在其中；
#          子域自己的产物仍走它们自己的 RV32_FUNCTIONAL_PKG_OUT_DIR。
#
# 用法 : bash sim/functional/test_memory.sh
#        RV32_FUNCTIONAL_PKG_OUT_DIR=<授权根下的目录> bash sim/functional/test_memory.sh
#        MEMORY_SKIP_MMU=1 ...   # **仅**用于本包自测（不产生 PASS，见下）
#==============================================================================
set -u

if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_MEMORY: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

TIMEOUT_SUB_S="${TIMEOUT_SUB_S:-1800}"

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=repo_root_unresolved\n'; exit 1; }

CACHE_SH="$SELF_DIR/test_cache_bus.sh"
MMU_SH="$SELF_DIR/test_mmu.sh"

CACHE_ANCHOR='FUNCTIONAL_CACHE_BUS: PASS'
MMU_ANCHOR='FUNCTIONAL_MMU: PASS'

#------------------------------------------------------------------------------
# 1. 产物根（授权树校验 → mkdir → mktemp 独占 run 目录）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=auth_root_readlink_failed\n'; exit 1; }
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/memory}"
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=out_root_readlink_failed\n'; exit 1; }
case "$ROOT_NORM" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) printf 'FUNCTIONAL_MEMORY: FAIL reason=out_root_unauthorized root=%s\n' "$ROOT_NORM"; exit 1 ;;
esac
mkdir -p -- "$ROOT_NORM" || { printf 'FUNCTIONAL_MEMORY: FAIL reason=out_root_mkdir_failed\n'; exit 1; }
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=mktemp_run_dir_failed\n'; exit 1; }

SUM_LOG="$RUN_DIR/test_memory.log"
: > "$SUM_LOG" || { printf 'FUNCTIONAL_MEMORY: FAIL reason=sum_log_create_failed\n'; exit 1; }

log() { printf '%s\n' "$*" >> "$SUM_LOG"; }

log "==== test_memory.sh : Memory domain aggregate ===="
log "date      = $(date -Is 2>/dev/null || date)"
log "RUN_DIR   = $RUN_DIR"
log "REPO_ROOT = $REPO_ROOT"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    log "GIT_HEAD  = $(git -C "$REPO_ROOT" rev-parse HEAD)"
else
    log "GIT_HEAD  = unavailable"
fi

mem_fail() {
    log "MEMORY_FAIL reason=$1"
    printf 'FUNCTIONAL_MEMORY: 失败 1 / 共 2 包（子域失败）\n'
    printf 'FUNCTIONAL_MEMORY: FAIL reason=%s run_dir=%s\n' "$1" "$RUN_DIR"
    exit 1
}

#------------------------------------------------------------------------------
# 2. 子域 1：cache-bus
#------------------------------------------------------------------------------
[ -f "$CACHE_SH" ] || mem_fail "missing_subdomain=cache-bus path=$CACHE_SH"

CACHE_LOG="$RUN_DIR/cache_bus.stdout.log"
env "RV32_FUNCTIONAL_PKG_OUT_DIR=$RUN_DIR/pkg_cache_bus" \
    timeout "$TIMEOUT_SUB_S" bash "$CACHE_SH" > "$CACHE_LOG" 2>&1
CACHE_RC=$?
log "-- cache-bus rc=$CACHE_RC --"
cat -- "$CACHE_LOG" >> "$SUM_LOG"
[ "$CACHE_RC" -eq 124 ] && mem_fail "subdomain_timeout=cache-bus"
[ "$CACHE_RC" -eq 0 ]   || mem_fail "subdomain_rc=cache-bus rc=$CACHE_RC"
N_ANCHOR="$(grep -cxF "$CACHE_ANCHOR" "$CACHE_LOG" || true)"
[ "$N_ANCHOR" = "1" ] || mem_fail "subdomain_anchor=cache-bus count=$N_ANCHOR"
N_FAIL="$(grep -c 'FAIL' "$CACHE_LOG" || true)"
[ "$N_FAIL" = "0" ] || mem_fail "subdomain_log_fail=cache-bus count=$N_FAIL"
N_DR="$(grep -c 'DEFECT_REPRODUCED' "$CACHE_LOG" || true)"
[ "$N_DR" = "0" ] || mem_fail "subdomain_defect_marker=cache-bus count=$N_DR"

#------------------------------------------------------------------------------
# 3. 子域 2：mmu
#------------------------------------------------------------------------------
[ -f "$MMU_SH" ] || mem_fail "missing_subdomain=mmu path=$MMU_SH"

MMU_LOG="$RUN_DIR/mmu.stdout.log"
env "RV32_FUNCTIONAL_PKG_OUT_DIR=$RUN_DIR/pkg_mmu" \
    timeout "$TIMEOUT_SUB_S" bash "$MMU_SH" > "$MMU_LOG" 2>&1
MMU_RC=$?
log "-- mmu rc=$MMU_RC --"
cat -- "$MMU_LOG" >> "$SUM_LOG"
[ "$MMU_RC" -eq 124 ] && mem_fail "subdomain_timeout=mmu"
[ "$MMU_RC" -eq 0 ]   || mem_fail "subdomain_rc=mmu rc=$MMU_RC"
N_ANCHOR="$(grep -cxF "$MMU_ANCHOR" "$MMU_LOG" || true)"
[ "$N_ANCHOR" = "1" ] || mem_fail "subdomain_anchor=mmu count=$N_ANCHOR"
N_FAIL="$(grep -c 'FAIL' "$MMU_LOG" || true)"
[ "$N_FAIL" = "0" ] || mem_fail "subdomain_log_fail=mmu count=$N_FAIL"
N_DR="$(grep -c 'DEFECT_REPRODUCED' "$MMU_LOG" || true)"
[ "$N_DR" = "0" ] || mem_fail "subdomain_defect_marker=mmu count=$N_DR"

#------------------------------------------------------------------------------
# 4. 结论：两个子域全绿 ⇒ 唯一 PASS 锚点（只报包数）
#------------------------------------------------------------------------------
log "MEMORY_OK subdomains=cache-bus,mmu"
printf 'FUNCTIONAL_MEMORY: 2/2 包 PASS\n'
printf 'FUNCTIONAL_MEMORY: PASS\n'
exit 0
