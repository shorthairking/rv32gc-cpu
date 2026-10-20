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
# 做什么（默认 = 跑两个**固定**子域入口；`--self-test` = 只跑本聚合器的杀伤路径）：
#   默认模式下依次调用两个**固定路径**的子域入口（不接受任何路径覆盖，防"替身蒙混"）：
#     · 缺例（子域脚本不在）                    ⇒ 失败，绝不占位 PASS
#     · 任一子域 rc≠0 / 超时 / 缺锚点 / 多锚点   ⇒ 失败
#     · 子域输出含 **任何 DEFECT 字样**          ⇒ 失败
#       （不只 DEFECT_REPRODUCED：DEFECT_SIG 等"缺陷签名/复现"标记同样必须拒；
#         子域自检/旧树反证的产物不得被聚合入口当成功）
#     · 子域输出含 FAIL 字样                    ⇒ 失败
#   只有**两个子域全绿**才打印唯一整行 `FUNCTIONAL_MEMORY: PASS`；否则只打印失败明细。
#
# 计数口径（重要）：
#   本入口只报**包数**（2 个子域），**不把子域内的向量/断言数包装成入口级计数**
#   （见 sim/functional/manifest.tsv 的纪律说明）。
#
# 产物纪律：本次独占 run 目录（mktemp -d，绝不 rm），两个子域的日志都落在其中；
#          子域自己的产物仍走它们自己的 RV32_FUNCTIONAL_PKG_OUT_DIR。
#
# 用法 : bash sim/functional/test_memory.sh
#        bash sim/functional/test_memory.sh --self-test     # 只自检，绝不打印聚合 PASS 锚点
#==============================================================================
set -u

TIMEOUT_SUB_S="${TIMEOUT_SUB_S:-1800}"

MODE="full"
if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    MODE="selftest"
elif [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_MEMORY: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_MEMORY: FAIL reason=repo_root_unresolved\n'; exit 1; }

#   ★ 固定入口（默认模式）：不允许被环境变量替换 —— "两个正确的固定入口"是口径本体。
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

log "==== test_memory.sh : Memory domain aggregate (MODE=$MODE) ===="
log "date      = $(date -Is 2>/dev/null || date)"
log "RUN_DIR   = $RUN_DIR"
log "REPO_ROOT = $REPO_ROOT"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    log "GIT_HEAD  = $(git -C "$REPO_ROOT" rev-parse HEAD)"
else
    log "GIT_HEAD  = unavailable"
fi

#------------------------------------------------------------------------------
# 2. 子域判定（聚合器的唯一判定逻辑；默认/自检共用）
#    aggregate <sub> <script> <anchor> <pkgout> <logfile>
#      ⇒ 0 = 该子域通过；1 = 失败（失败原因写到 $SUM_LOG 与 stdout 的 reason 变量）
#------------------------------------------------------------------------------
SUB_REASON=""

check_subdomain() {  # check_subdomain <name> <script> <anchor> <pkgout> <logfile>
    local name="$1" script="$2" anchor="$3" pkgout="$4" logfile="$5"
    local rc n_anchor n_fail n_defect n_tail_ok

    if [ ! -f "$script" ]; then
        SUB_REASON="missing_subdomain=$name path=$script"
        return 1
    fi
    if [ ! -x "$script" ]; then
        SUB_REASON="subdomain_not_executable=$name path=$script"
        return 1
    fi

    env "RV32_FUNCTIONAL_PKG_OUT_DIR=$pkgout" \
        timeout "$TIMEOUT_SUB_S" bash "$script" > "$logfile" 2>&1
    rc=$?
    log "-- $name rc=$rc log=$logfile --"
    #   ★ 注意：判定基于**完整日志**（cat 全量），不是 tail 片段 —— 尾部之外出现的
    #     FAIL/DEFECT 也必须拦住。
    cat -- "$logfile" >> "$SUM_LOG"

    if [ "$rc" -eq 124 ]; then
        SUB_REASON="subdomain_timeout=$name"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        SUB_REASON="subdomain_rc=$name rc=$rc"
        return 1
    fi
    if [ ! -s "$logfile" ]; then
        SUB_REASON="subdomain_empty_log=$name"
        return 1
    fi

    n_anchor="$(grep -cxF "$anchor" "$logfile" || true)"
    if [ "$n_anchor" != "1" ]; then
        SUB_REASON="subdomain_anchor=$name count=$n_anchor"
        return 1
    fi

    #   ★ 任何 DEFECT 字样都拒（DEFECT_REPRODUCED / DEFECT_SIG / 自造 DEFECT_*）：
    #     聚合入口只认"正确行为"，不认"缺陷被复现/被签名"。
    n_defect="$(grep -c 'DEFECT' "$logfile" || true)"
    if [ "$n_defect" != "0" ]; then
        SUB_REASON="subdomain_defect_marker=$name count=$n_defect"
        return 1
    fi

    n_fail="$(grep -c 'FAIL' "$logfile" || true)"
    if [ "$n_fail" != "0" ]; then
        SUB_REASON="subdomain_log_fail=$name count=$n_fail"
        return 1
    fi

    #   兜底：日志里不得出现超时标记（子域自己应给出 rc≠0，这里再保一道）
    n_tail_ok="$(grep -c 'TIMEOUT' "$logfile" || true)"
    if [ "$n_tail_ok" != "0" ]; then
        SUB_REASON="subdomain_timeout_marker=$name"
        return 1
    fi

    return 0
}

#------------------------------------------------------------------------------
# 3. 默认模式：两个**固定**子域
#------------------------------------------------------------------------------
mem_fail() {
    log "MEMORY_FAIL reason=$1"
    printf 'FUNCTIONAL_MEMORY: 失败 1 / 共 2 包（子域失败）\n'
    printf 'FUNCTIONAL_MEMORY: FAIL reason=%s run_dir=%s\n' "$1" "$RUN_DIR"
    exit 1
}

if [ "$MODE" = "full" ]; then
    check_subdomain "cache-bus" "$CACHE_SH" "$CACHE_ANCHOR" "$RUN_DIR/pkg_cache_bus" "$RUN_DIR/cache_bus.stdout.log" \
        || mem_fail "$SUB_REASON"
    check_subdomain "mmu" "$MMU_SH" "$MMU_ANCHOR" "$RUN_DIR/pkg_mmu" "$RUN_DIR/mmu.stdout.log" \
        || mem_fail "$SUB_REASON"

    log "MEMORY_OK subdomains=cache-bus,mmu"
    printf 'FUNCTIONAL_MEMORY: 2/2 包 PASS\n'
    printf 'FUNCTIONAL_MEMORY: PASS\n'
    exit 0
fi

#==============================================================================
# 4. 自检模式：私有替身（stub）逐类反例；**绝不**打印聚合 PASS 锚点
#    ★ 自检只在 --self-test 下生效，且默认模式不接受任何路径覆盖 ⇒
#      "自证/旧树/替身" 永远不会混进默认 PASS。
#==============================================================================
#   ★ 自检里有一个"超时"反例：把子域超时压到 2s，避免整体要等默认 1800s。
TIMEOUT_SUB_S="${MEMORY_SELFTEST_TIMEOUT_S:-2}"
ST_DIR="$RUN_DIR/stubs"
mkdir -p -- "$ST_DIR" || { printf 'FUNCTIONAL_MEMORY: FAIL reason=stub_dir_failed\n'; exit 1; }

ST_FAIL=0
ST_N=0
st_case() {  # st_case <name> <want_reason> <cache_body> <mmu_body>
    local nm="$1" want="$2" cbody="$3" mbody="$4"
    local csh="$ST_DIR/cache_$nm.sh" msh="$ST_DIR/mmu_$nm.sh"
    local clog="$RUN_DIR/st_${nm}_cache.log" mlog="$RUN_DIR/st_${nm}_mmu.log"
    local ok=1

    ST_N=$((ST_N + 1))
    printf '%s\n' "$cbody" > "$csh"; chmod 755 "$csh"
    printf '%s\n' "$mbody" > "$msh"; chmod 755 "$msh"

    SUB_REASON=""
    if check_subdomain "cache-bus" "$csh" "$CACHE_ANCHOR" "$RUN_DIR/stpkg/${nm}_c" "$clog"; then
        ok=0; SUB_REASON="unexpected_double_pass"
    fi
    #   上面 cache 已失败时不再跑 mmu（与默认模式一致：首个失败即停）
    case "$SUB_REASON" in
        *"$want"*) : ;;
        *) ok=0 ;;
    esac
    log "SELFTEST $nm want=$want got=$SUB_REASON ok=$ok"
    printf 'MEMORY_SELFTEST case=%s ok=%s want=%s got=%s\n' "$nm" "$ok" "$want" "$SUB_REASON"
    [ "$ok" = "1" ] || ST_FAIL=1
}

#   正向替身（两个都干净、锚点唯一、无 DEFECT/FAIL）
OK_CACHE='#!/usr/bin/env bash
echo "FUNCTIONAL_CACHE_BUS: PASS"
exit 0'
OK_MMU='#!/usr/bin/env bash
echo "FUNCTIONAL_MMU: PASS"
exit 0'

#   1) 缺例：mmu 不存在
ST_N=$((ST_N+1))
printf '%s\n' "$OK_CACHE" > "$ST_DIR/cache_ok.sh"; chmod 755 "$ST_DIR/cache_ok.sh"
SUB_REASON=""
check_subdomain "mmu" "$ST_DIR/does_not_exist.sh" "$MMU_ANCHOR" "$RUN_DIR/stpkg/miss" "$RUN_DIR/st_miss.log" || true
if [[ "$SUB_REASON" == *"missing_subdomain=mmu"* ]]; then
    printf 'MEMORY_SELFTEST case=missing_mmu ok=1 want=missing_subdomain=mmu got=%s\n' "$SUB_REASON"
else
    printf 'MEMORY_SELFTEST case=missing_mmu ok=0 want=missing_subdomain=mmu got=%s\n' "$SUB_REASON"
    ST_FAIL=1
fi

#   2) rc≠0
st_case "sub_rc" "subdomain_rc=cache-bus rc=7" \
'#!/usr/bin/env bash
echo "FUNCTIONAL_CACHE_BUS: PASS"
exit 7' "$OK_MMU"

#   3) 缺锚点
st_case "no_anchor" "subdomain_anchor=cache-bus count=0" \
'#!/usr/bin/env bash
echo "no anchor here"
exit 0' "$OK_MMU"

#   4) 多锚点
st_case "multi_anchor" "subdomain_anchor=cache-bus count=2" \
'#!/usr/bin/env bash
echo "FUNCTIONAL_CACHE_BUS: PASS"
echo "FUNCTIONAL_CACHE_BUS: PASS"
exit 0' "$OK_MMU"

#   5) rc0 + 正确唯一锚点 + **DEFECT_SIG** ⇒ 必须拒（本轮新增的核心口径）
st_case "defect_sig" "subdomain_defect_marker=cache-bus count=1" \
'#!/usr/bin/env bash
echo "FUNCTIONAL_CACHE_BUS: PASS"
echo "DEFECT_SIG vec=1 name=x"
exit 0' "$OK_MMU"

#   6) rc0 + 正确唯一锚点 + DEFECT_REPRODUCED ⇒ 必须拒
st_case "defect_repro" "subdomain_defect_marker=cache-bus count=1" \
'#!/usr/bin/env bash
echo "FUNCTIONAL_CACHE_BUS: PASS"
echo "FUNCTIONAL_CACHE_BUS: DEFECT_REPRODUCED root=04-04"
exit 0' "$OK_MMU"

#   7) 日志含 FAIL（在**非尾部**也要拦住）
st_case "log_fail_head" "subdomain_log_fail=cache-bus count=1" \
'#!/usr/bin/env bash
echo "FAIL: early line"
echo "FUNCTIONAL_CACHE_BUS: PASS"
exit 0' "$OK_MMU"

#   8) 超时
st_case "timeout" "subdomain_timeout=cache-bus" \
'#!/usr/bin/env bash
sleep 30' "$OK_MMU"

#   9) 正向替身：两个都干净 ⇒ check_subdomain 必须都通过（且**不**打印聚合 PASS）
SUB_REASON=""
pos_ok=1
check_subdomain "cache-bus" "$ST_DIR/cache_ok.sh" "$CACHE_ANCHOR" "$RUN_DIR/stpkg/pos_c" "$RUN_DIR/st_pos_c.log" \
    || pos_ok=0
[ -f "$ST_DIR/mmu_ok.sh" ] || { printf '%s\n' "$OK_MMU" > "$ST_DIR/mmu_ok.sh"; chmod 755 "$ST_DIR/mmu_ok.sh"; }
[ "$pos_ok" = "1" ] && { check_subdomain "mmu" "$ST_DIR/mmu_ok.sh" "$MMU_ANCHOR" "$RUN_DIR/stpkg/pos_m" "$RUN_DIR/st_pos_m.log" || pos_ok=0; }
printf 'MEMORY_SELFTEST case=positive_stubs ok=%s\n' "$pos_ok"
[ "$pos_ok" = "1" ] || ST_FAIL=1

[ "$ST_FAIL" = "0" ] || { printf 'FUNCTIONAL_MEMORY: SELFTEST FAIL run_dir=%s\n' "$RUN_DIR"; exit 1; }
#   ★ 自检模式**只**打印自检结论，绝不打印 `FUNCTIONAL_MEMORY: PASS`。
printf 'MEMORY_SELFTEST: PASS cases=%s\n' "$ST_N"
exit 0
