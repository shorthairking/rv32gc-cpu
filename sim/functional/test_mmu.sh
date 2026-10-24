#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_mmu.sh —— F3 MMU 叶模块包（ptw / tlb / lsu / pmp_check）
#                               功能定向测试入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）
# 依据 : prompts/common.md §3（确定性脚本 + 退出码 + 日志锚点）、F3 验收
#        （唯一整行 `FUNCTIONAL_MMU: PASS`；缺例/少跑/非零/超时/错误标记一律拒）；
#        审计 sim/audit/global-2026-10-18/04-memory-bus.md 04-01/02/03/06。
#
# 做什么 :
#   1) 用 iverilog 编译**本包固定 TB**（sim/functional/tb_mmu_semantics.sv）
#      + DUT_ROOT 下本包依赖的 7 个 RTL 文件（ptw/tlb/lsu/pmp_check/mmio_route/
#      amo_unit/cmo_unit）+ 2 个头文件 ⇒ **10 个实际编译输入**；
#   2) 跑 vvp，把编译/运行输出捕获到**本次独占**的 run 目录；
#   3) 逐向量严格校验摘要/格式/冻结规格/逐向量检查数；缺一即失败；
#   4) 默认 DUT_ROOT = 本仓库根（当前树）；置 DUT_ROOT=<只读源根> 可对旧源码复跑
#      同一 TB 做反证（`--check-baseline` 自动做）。
#
# 三种模式（同一 TB、同一脚本，只换期望）:
#   · 默认（正向）        ：fails=0、total==SPEC_VECTORS、逐向量 checks>0
#                           ⇒ stdout 只多一行 `FUNCTIONAL_MMU: PASS`，rc=0。
#   · --check-baseline    ：当前树必须绿 **且** 冻结基线 201acf61 必须红
#                           （`MMU FAIL [TAG]` 覆盖全部登记缺陷标签、fails>0、
#                            rc!=0、无 PASS 锚点）⇒ 成功打印 `DEFECT_REPRODUCED: ...`，
#                           **绝不**打印正式 PASS 锚点。
#   · --self-test         ：日志判据夹具反证 + 端到端反证（假工具/缺头/零产物/
#                           坏哈希/运行失败/超时/源在运行中变化/失败分支不泄 PASS）
#                           ⇒ 成功打印 `SELFTEST_OK`。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR（功能总入口传入，若设置）
#              > $REPO_ROOT/build/functional/mmu（默认）
#   · 根先 realpath -m 规范化并校验位于 $REPO_ROOT/build/functional 之下，再 mkdir；
#     随后 `mktemp -d <根>/run-XXXXXXXX` 建**独占 run 目录**，本次全部产物都在其中。
#   · 因目录独占，脚本**不做任何 rm**；固定文件名也不会覆盖历史。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP（env.sh 只读、不可改）；
#            二者仍可被调用方以同名环境变量覆盖 ⇒ 保留"假工具"端到端反证能力。
# 源冻结  : DUT 源 + 头 + TB 的 sha256 **编译前与运行后各算一次**并要求逐字节一致
#            （运行中源变化 ⇒ 失败）；条数/格式严格校验（rc0、恰 10 行、64-hex）。
# 编译隔离: 在**实际 DUT_ROOT 的 cwd 子 shell** 内编译，只给快照自身的 -I，
#           **不提供活 REPO_ROOT fallback 头**（Icarus 把调用 cwd 置于 -I 之前）。
#
# 用法 : bash sim/functional/test_mmu.sh
#        DUT_ROOT=<只读源根> bash sim/functional/test_mmu.sh
#        bash sim/functional/test_mmu.sh --check-baseline
#        bash sim/functional/test_mmu.sh --self-test
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
ENV_SH="${REPO_ROOT}/scripts/env.sh"
TB="${REPO_ROOT}/sim/functional/tb_mmu_semantics.sv"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

#------------------------------------------------------------------------------
# 本包冻结规格（与 tb_mmu_semantics.sv 同步；改 TB 必须同步改这里）
#------------------------------------------------------------------------------
readonly SPEC_VECTORS=32
readonly N_HASH_EXPECTED=10       # 7 RTL + 2 vh + TB = 实际编译输入
readonly BASE_COMMIT_SHORT="201acf61"
readonly BASE_COMMIT_FULL="201acf61e118a3fb533e1a96768687a35efa1751"
# ---- 冻结的逐向量规格（独审 P1③：固定 ID/name/checks 与总数）----
#   · 顺序 = 向量编号 1..SPEC_VECTORS；name 必须逐字节相等；
#   · NEW_CHECKS = 当前（已修）树每向量检查数；OLD_CHECKS = 冻结基线 201acf61 的
#     每向量检查数。**两者本来就不同**（旧树 walk 成功时会多跑 CTRL_PTW_TLB_* 检查），
#     故分别冻结、分别校验总数，绝不用一个总数硬压另一棵树。
#   · 任何 TB 改动都必须同步本表（否则门控拒）。
readonly VEC_NAMES="CTRL_XZ_DETECT CTRL_BASE_TR CTRL_BIGPAGE MMU_SVADE_D_TLB_HIT CTRL_SVADE_D1 CTRL_SVADE_A0 MMU_SFENCE_GLOBAL_VA CTRL_SFENCE_ASID_KEEP_G CTRL_SFENCE_VA_ASID_KEEP_G CTRL_SFENCE_ALL MMU_PA34_ROOT MMU_PA34_L0 MMU_PA34_LEAF4K MMU_PA34_LEAF4M CTRL_PA34_PRIO_PERM MMU_PA34_AF_LEGAL CTRL_PA34_SVADE CTRL_PA_LOW MMU_CBM_RO_PTW MMU_CBM_RO_TLB MMU_CBM_D_CHECK CTRL_CBM_A0 CTRL_CBM_RESERVED CTRL_STORE_RO MMU_LSU_CBM_RO CTRL_LSU_CBM_WO MMU_LSU_NEED_PERM CTRL_LSU_CBM_DENY CTRL_LSU_STORE_RO CTRL_LOOKUP2_FETCH MMU_LOOKUP2_D0 CTRL_LSU_LOAD_WO"
readonly NEW_CHECKS="5 21 7 9 9 6 16 9 9 9 11 6 6 5 7 8 6 8 6 9 7 4 5 7 4 3 2 3 3 13 9 3"
readonly OLD_CHECKS="5 11 7 9 9 6 16 9 9 9 17 9 9 8 7 17 6 8 3 9 4 4 5 7 4 3 2 3 3 13 9 3"
readonly CHECKS_TOTAL_NEW=235
readonly CHECKS_TOTAL_OLD=243
# 旧基线必须触发的定向缺陷标签（与 TB 头注一致）；`CTRL_` 前缀为合法控制标签
readonly DEFECT_TAGS="MMU_SVADE_D_TLB_HIT MMU_SFENCE_GLOBAL_VA MMU_PA34_ROOT MMU_PA34_L0 MMU_PA34_LEAF4K MMU_PA34_LEAF4M MMU_PA34_AF_LEGAL MMU_CBM_RO_PTW MMU_CBM_RO_TLB MMU_CBM_D_CHECK MMU_LSU_CBM_RO MMU_LSU_NEED_PERM MMU_LOOKUP2_D0"

usage() {
    cat <<'EOF'
用法：
  test_mmu.sh                  默认：仅正向正确行为（成功打印唯一整行 FUNCTIONAL_MMU: PASS）
  test_mmu.sh --check-baseline 显式反证：当前源绿 + 冻结基线 201acf61 红（成功打印 DEFECT_REPRODUCED）
  test_mmu.sh --self-test      日志判据 + 端到端反证（成功打印 SELFTEST_OK）
环境：
  DUT_ROOT                     正向用例的只读源码根（默认 REPO_ROOT；TB 始终当前包）
  RV32_FUNCTIONAL_PKG_OUT_DIR  总入口指定的产物根（相对路径按 REPO_ROOT 解析）；仍在其下 mktemp 独占 run
  CASE_COMPILE_TIMEOUT / CASE_RUN_TIMEOUT  编译/运行墙钟兜底秒数（默认 300）
授权的输出根：<repo>/build/functional（及其子目录）；此外一律拒绝写入。
EOF
}

MODE="default"
case "${1:-}" in
    ""|--default|default)               MODE="default" ;;
    --check-baseline|check-baseline)    MODE="baseline" ;;
    --self-test|self-test)              MODE="selftest" ;;
    -h|--help|help)                     usage; exit 0 ;;
    *) die "未知参数：${1}（支持 --check-baseline / --self-test / --help）" ;;
esac
[ "$#" -le 1 ] || die "参数过多：$*"

[ -r "$ENV_SH" ] || die "缺少 ${ENV_SH}（工具链环境真源）"
# shellcheck source=../../scripts/env.sh
. "$ENV_SH"
[ -r "$TB" ] || die "缺少功能 TB：${TB}"

AUTH_ROOT="$(realpath -m -- "${REPO_ROOT}/build/functional")"
command -v realpath >/dev/null 2>&1 || die "未找到 realpath（coreutils）"

is_authorized() {
    case "$1" in
        "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

#------------------------------------------------------------------------------
# 0. 产物根：规范化 → 授权树校验 → mkdir → 再校验 → **总是** mktemp 独占 run 目录
#------------------------------------------------------------------------------
resolve_root() {
    local raw="${RV32_FUNCTIONAL_PKG_OUT_DIR:-}" cand
    if [ -n "$raw" ]; then
        case "$raw" in
            /*) cand="$raw" ;;
            *)  cand="${REPO_ROOT}/${raw}" ;;   # 总入口约定：相对路径相对仓库根
        esac
    else
        cand="${AUTH_ROOT}/mmu"
    fi
    cand="$(realpath -m -- "$cand")" || die "无法规范化产物根：${raw:-$cand}"
    is_authorized "$cand" || die "产物根不在授权树 ${AUTH_ROOT} 之下：${cand}"
    mkdir -p -- "$cand" || die "无法创建产物根：${cand}"
    cand="$(realpath -m -- "$cand")" || die "产物根再规范化失败：${cand}"
    is_authorized "$cand" || die "产物根 mkdir 后逃出授权树：${cand}"
    printf '%s' "$cand"
}

#------------------------------------------------------------------------------
# 1. 通用：编译 + 运行一个源根；再对运行日志做门控
#------------------------------------------------------------------------------
CASE_COMPILE_TIMEOUT="${CASE_COMPILE_TIMEOUT:-300}"
CASE_RUN_TIMEOUT="${CASE_RUN_TIMEOUT:-300}"
IV="${RV32_IVERILOG:-}"
VVP="${RV32_VVP:-}"

need_sim_tools() {
    [ -n "$IV" ]  && [ -x "$IV" ]  || die "未找到 iverilog（RV32_IVERILOG）"
    [ -n "$VVP" ] && [ -x "$VVP" ] || die "未找到 vvp（RV32_VVP）"
    command -v timeout >/dev/null 2>&1 || die "未找到 timeout（coreutils）"
}

# 本包实际依赖（7 RTL + 2 vh + TB = 10）
DUT_REL_LIST=(
    rtl/csr/ptw.v
    rtl/csr/tlb.v
    rtl/mem/lsu.v
    rtl/mem/pmp_check.v
    rtl/mem/mmio_route.v
    rtl/mem/amo_unit.v
    rtl/mem/cmo_unit.v
)
DUT_HDR_REL_LIST=( rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh )

abs_cmd() {
    local c="$1" r
    case "$c" in /*) printf '%s' "$c"; return 0 ;; esac
    if r="$(command -v -- "$c" 2>/dev/null)" && [ -n "$r" ]; then
        case "$r" in /*) printf '%s' "$r"; return 0 ;; esac
        printf '%s/%s' "$PWD" "$r"; return 0
    fi
    printf '%s' "$c"
}

# 哈希一个清单：写入 <out>，结果放 HASH_RC / HASH_LINES / HASH_BADHEX
#   HASH_RC: 0 正常；非 0 = sha256sum rc；97 = 条数不符；96 = 存在非 64-hex 行
hash_inputs() {
    local out="$1"; shift
    HASH_RC=0; HASH_LINES=0; HASH_BADHEX=0
    sha256sum -- "$@" > "$out" 2>>"${CASE_CLOG:-/dev/null}" || HASH_RC=$?
    [ "$HASH_RC" -eq 0 ] || return 0
    HASH_LINES="$(wc -l < "$out" 2>/dev/null || printf 0)"
    [ "$HASH_LINES" -eq "$N_HASH_EXPECTED" ] || HASH_RC=97
    HASH_BADHEX="$(grep -cvE '^[0-9a-f]{64} ' "$out" 2>/dev/null || true)"; HASH_BADHEX="${HASH_BADHEX:-0}"
    [ "$HASH_BADHEX" -eq 0 ] || HASH_RC=96
    return 0
}

case_compile() {   # <name> <root> [iv] [vv] [extra_iverilog_args] [tb_file]
    local name="$1" root="$2" iv="${3:-$IV}" vv="${4:-$VVP}"
    local extra="${5:-}" tb_file="${6:-$TB}"
    # Select the new TB named-port branch only for source roots that actually expose
    # the input. Frozen 201acf61 intentionally compiles the legacy port map unchanged.
    if grep -Eq 'input[[:space:]]+wire[[:space:]]+pte_resp_err' "$root/rtl/csr/ptw.v"; then
        extra="${extra} -DPTW_PTE_RESP_ERR_PORT"
    fi
    CASE_DIR="${RUN_DIR}/${name}"
    mkdir -p -- "$CASE_DIR"
    CASE_CLOG="${CASE_DIR}/compile.log"
    CASE_RLOG="${CASE_DIR}/run.log"
    CASE_HASH="${CASE_DIR}/compile_inputs.sha256"          # 兼容旧命名：= 编译前清单
    CASE_HASH_BEFORE="${CASE_DIR}/inputs_before.sha256"
    CASE_HASH_AFTER="${CASE_DIR}/inputs_after.sha256"
    CASE_VVP="${CASE_DIR}/${name}.vvp"
    CASE_COMPILE_RC=0; CASE_VVP_OK=0; CASE_HASH_RC=0; CASE_HASH_LINES=0
    CASE_HASH_BADHEX=0; CASE_HASH_CHANGED=0; CASE_RUN_RC=0
    CASE_INPUTS=( "$tb_file" )
    local f
    for f in "${DUT_REL_LIST[@]}" "${DUT_HDR_REL_LIST[@]}"; do
        CASE_INPUTS+=( "$root/$f" )
    done
    for f in "${CASE_INPUTS[@]}"; do
        [ -f "$f" ] || { CASE_COMPILE_RC=96; return 0; }   # 缺实际输入（含头文件）
    done
    # ---- 编译前哈希（rc0/条数/64-hex；失败即失败，不编译）----
    hash_inputs "$CASE_HASH_BEFORE" "${CASE_INPUTS[@]}"
    CASE_HASH_RC="$HASH_RC"; CASE_HASH_LINES="$HASH_LINES"; CASE_HASH_BADHEX="$HASH_BADHEX"
    if [ "$CASE_HASH_RC" -eq 0 ]; then
        cp -f -- "$CASE_HASH_BEFORE" "$CASE_HASH" 2>/dev/null || true
    else
        return 0
    fi
    # ---- 编译（★ 隔离口径）：在**实际 DUT_ROOT 的 cwd 子 shell** 内编译；
    #     只给快照自身的 -I，源/TB/产物一律绝对路径；工具先解析为绝对路径。
    local iv_abs vv_abs
    iv_abs="$(abs_cmd "$iv")"; vv_abs="$(abs_cmd "$vv")"
    # shellcheck disable=SC2086
    ( cd "$root" && timeout "$CASE_COMPILE_TIMEOUT" "$iv_abs" -g2012 $extra \
        -I "$root" -I "$root/rtl/pkg" \
        -o "$CASE_VVP" -s tb_mmu_semantics \
        "${CASE_INPUTS[@]}" ) >"$CASE_CLOG" 2>&1 || CASE_COMPILE_RC=$?
    if [ "$CASE_COMPILE_RC" -eq 0 ]; then
        if [ -s "$CASE_VVP" ]; then CASE_VVP_OK=1; else CASE_COMPILE_RC=98; fi
    fi
    [ "$CASE_COMPILE_RC" -eq 0 ] || return 0
    # ---- 运行 ----
    timeout "$CASE_RUN_TIMEOUT" "$vv_abs" "$CASE_VVP" >"$CASE_RLOG" 2>&1 || CASE_RUN_RC=$?
    # ---- 运行后哈希并与编译前 cmp（运行中源变化 ⇒ 失败）----
    hash_inputs "$CASE_HASH_AFTER" "${CASE_INPUTS[@]}"
    if [ "$HASH_RC" -ne 0 ]; then
        CASE_HASH_RC="$HASH_RC"
    elif ! cmp -s -- "$CASE_HASH_BEFORE" "$CASE_HASH_AFTER"; then
        CASE_HASH_RC=95; CASE_HASH_CHANGED=1
    fi
}

#------------------------------------------------------------------------------
# 逐向量严格解析（正向/反证共用；独审 P1③）
#   · 行格式：`VEC <i> name=<NAME> checks=<d> fails=<d>`（同前缀，恰 SPEC_VECTORS 行）
#   · 编号 1..SPEC 恰各一次；name 逐字节等于冻结表；checks 逐等于期望表；
#     每行 checks>=1；汇总 checks == 期望总数。
#   结果放 PV_*（全局）；任一项不合格由调用方按原因拒绝。
#------------------------------------------------------------------------------
declare -A PV_FAIL=()
parse_vec_lines() {   # parse_vec_lines <log> <expected_checks_list>
    local log="$1" exp="$2"
    local -a C N
    read -r -a C <<<"$exp"
    read -r -a N <<<"$VEC_NAMES"
    local line idx nm ck fl i
    local -A seen=()
    PV_LINES=0; PV_BADFMT=0; PV_NAMEBAD=0; PV_CHKBAD=0; PV_FAILVEC=0
    PV_ZERO=0; PV_MISS=0; PV_EXTRA=0; PV_SUM=0; PV_ANYFAIL=0
    PV_FAIL=()
    while IFS= read -r line; do
        PV_LINES=$((PV_LINES + 1))
        if [[ ! "$line" =~ ^VEC\ ([0-9]+)\ name=([A-Za-z0-9_]+)\ checks=([0-9]+)\ fails=([0-9]+)$ ]]; then
            PV_BADFMT=$((PV_BADFMT + 1)); continue
        fi
        idx=$((10#${BASH_REMATCH[1]})); nm="${BASH_REMATCH[2]}"
        ck=$((10#${BASH_REMATCH[3]})); fl=$((10#${BASH_REMATCH[4]}))
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$SPEC_VECTORS" ]; then
            PV_EXTRA=$((PV_EXTRA + 1)); continue
        fi
        seen[$idx]=$(( ${seen[$idx]:-0} + 1 ))
        [ "$nm" = "${N[$((idx - 1))]}" ] || PV_NAMEBAD=$((PV_NAMEBAD + 1))
        [ "$ck" -eq "${C[$((idx - 1))]}" ] || PV_CHKBAD=$((PV_CHKBAD + 1))
        [ "$ck" -ge 1 ] || PV_ZERO=$((PV_ZERO + 1))
        [ "$fl" -eq 0 ] || PV_FAILVEC=$((PV_FAILVEC + 1))
        PV_FAIL[$idx]="$fl"
        PV_ANYFAIL=$((PV_ANYFAIL + fl))
        PV_SUM=$((PV_SUM + ck))
    done < <(grep '^VEC ' "$log" 2>/dev/null || true)
    for ((i = 1; i <= SPEC_VECTORS; i++)); do
        [ "${seen[$i]:-0}" -eq 1 ] || PV_MISS=$((PV_MISS + 1))
    done
    for i in "${!seen[@]}"; do
        [ "${seen[$i]}" -gt 1 ] && PV_EXTRA=$((PV_EXTRA + 1))
    done
    return 0
}

# ---- 正向门控：读取 <log> + rc；G_ERR==0 即通过，G_REASON 给首个失败原因 ----
gate_positive_log() {
    local log="$1" rc="$2" vsum_line
    G_ERR=0; G_REASON="ok"
    G_CAPTURE=0; G_ANCHOR=0; G_PASSOCC=0; G_FAILLINES=0; G_DEFECTLINES=0
    G_SUMCNT=0; G_TOTAL="-"; G_CHECKS="-"; G_FAILS="-"
    G_VECN=0; G_VECSUM=0; G_VECBAD=0; G_VECZERO=0; G_VECFAIL=0; G_VECMISS=0; G_VECEXTRA=0

    #   ★ 独审 P2：四态观测的失败给出**精确 reason**（而不是笼统 log_has_FAIL / rc），
    #     便于证明"负向刺激确实打到了真实 monitor"。放在最前：即使 TB 因 fails>0
    #     以非零退出，也先归因为 xz_control。
    if grep -q 'MMU FAIL \[XZ_CONTROL\]' "$log" 2>/dev/null; then
        G_ERR=1; G_REASON="xz_control"; return 1
    fi
    [ -s "$log" ] && G_CAPTURE=1
    [ "$G_CAPTURE" -eq 1 ] || { G_ERR=1; G_REASON="no_capture"; return 1; }
    [ "$rc" -eq 0 ] || { G_ERR=1; G_REASON="rc=$rc"; return 1; }

    # 先"拒任意 FAIL / DEFECT"，再解析摘要
    G_FAILLINES="$(grep -c 'FAIL' "$log" 2>/dev/null || true)"; G_FAILLINES="${G_FAILLINES:-0}"
    G_DEFECTLINES="$(grep -c 'DEFECT' "$log" 2>/dev/null || true)"; G_DEFECTLINES="${G_DEFECTLINES:-0}"
    [ "$G_FAILLINES" -eq 0 ] || { G_ERR=1; G_REASON="log_has_FAIL=$G_FAILLINES"; return 1; }
    [ "$G_DEFECTLINES" -eq 0 ] || { G_ERR=1; G_REASON="log_has_DEFECT=$G_DEFECTLINES"; return 1; }

    # 摘要：同前缀恰 1 行，再严格解析
    G_SUMCNT="$(grep -c '^FUNCTIONAL_MMU_VECTORS ' "$log" 2>/dev/null || true)"; G_SUMCNT="${G_SUMCNT:-0}"
    [ "$G_SUMCNT" -eq 1 ] || { G_ERR=1; G_REASON="summary_count=$G_SUMCNT"; return 1; }
    vsum_line="$(grep -m1 '^FUNCTIONAL_MMU_VECTORS ' "$log" 2>/dev/null || true)"
    if [[ "$vsum_line" =~ ^FUNCTIONAL_MMU_VECTORS\ total=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)$ ]]; then
        G_TOTAL="${BASH_REMATCH[1]}"; G_CHECKS="${BASH_REMATCH[2]}"; G_FAILS="${BASH_REMATCH[3]}"
    else
        G_ERR=1; G_REASON="summary_format"; return 1
    fi
    [ "$G_TOTAL"  -eq "$SPEC_VECTORS" ] || { G_ERR=1; G_REASON="summary_total=$G_TOTAL expect=$SPEC_VECTORS"; return 1; }
    [ "$G_CHECKS" -gt 0 ] || { G_ERR=1; G_REASON="summary_checks_zero"; return 1; }
    [ "$G_FAILS"  -eq 0 ] || { G_ERR=1; G_REASON="summary_fails=$G_FAILS"; return 1; }

    # 逐向量：行数/ID/name/checks/总数逐项对冻结表（独审 P1③）
    parse_vec_lines "$log" "$NEW_CHECKS"
    G_VECN="$PV_LINES"; G_VECSUM="$PV_SUM"; G_VECBAD="$PV_BADFMT"
    G_VECZERO="$PV_ZERO"; G_VECFAIL="$PV_FAILVEC"; G_VECMISS="$PV_MISS"; G_VECEXTRA="$PV_EXTRA"
    [ "$G_VECN"     -eq "$SPEC_VECTORS" ]      || { G_ERR=1; G_REASON="vec_line_count=$G_VECN total=$SPEC_VECTORS"; return 1; }
    [ "$G_VECBAD"   -eq 0 ]                    || { G_ERR=1; G_REASON="vec_format_bad=$G_VECBAD"; return 1; }
    [ "$PV_NAMEBAD" -eq 0 ]                    || { G_ERR=1; G_REASON="vec_name_mismatch=$PV_NAMEBAD"; return 1; }
    [ "$PV_CHKBAD"  -eq 0 ]                    || { G_ERR=1; G_REASON="vec_checks_mismatch=$PV_CHKBAD"; return 1; }
    [ "$G_VECZERO"  -eq 0 ]                    || { G_ERR=1; G_REASON="vec_checks_zero=$G_VECZERO"; return 1; }
    [ "$G_VECFAIL"  -eq 0 ]                    || { G_ERR=1; G_REASON="vec_fails=$G_VECFAIL"; return 1; }
    [ "$G_VECMISS"  -eq 0 ]                    || { G_ERR=1; G_REASON="vec_missing_idx=$G_VECMISS"; return 1; }
    [ "$G_VECEXTRA" -eq 0 ]                    || { G_ERR=1; G_REASON="vec_extra_idx=$G_VECEXTRA"; return 1; }
    [ "$G_VECSUM"   -eq "$CHECKS_TOTAL_NEW" ]  || { G_ERR=1; G_REASON="vec_checks_sum=$G_VECSUM expect=$CHECKS_TOTAL_NEW"; return 1; }
    [ "$G_VECSUM"   -eq "$G_CHECKS" ]          || { G_ERR=1; G_REASON="vec_checks_sum_ne_summary"; return 1; }

    # 锚点：整行恰 1；整份日志 PASS 子串恰 1
    G_ANCHOR="$(grep -cxF 'FUNCTIONAL_MMU: PASS' "$log" 2>/dev/null || true)"; G_ANCHOR="${G_ANCHOR:-0}"
    G_PASSOCC="$( { grep -o 'PASS' "$log" 2>/dev/null || true; } | wc -l )"; G_PASSOCC="${G_PASSOCC:-0}"
    [ "$G_ANCHOR"  -eq 1 ] || { G_ERR=1; G_REASON="pass_anchor_count=$G_ANCHOR"; return 1; }
    [ "$G_PASSOCC" -eq 1 ] || { G_ERR=1; G_REASON="pass_substr=$G_PASSOCC"; return 1; }
    return 0
}

# ---- 反证门控：旧树日志必须"红得符合预期"（供 baseline_main 与 --self-test 共用）----
gate_baseline_log() {
    local log="$1" rc="$2" bline vstat
    B_ERR=0; B_REASON="ok"
    B_ANCHOR=0; B_SUMCNT=0; B_TOTAL="-"; B_CHECKS="-"; B_FAILS="-"
    B_VECN=0; B_VECSUM=0; B_VECBAD=0; B_MISSING=""; B_CTRL=0
    [ -s "$log" ] || { B_ERR=1; B_REASON="baseline_no_capture"; return 1; }
    [ "$rc" -ne 0 ] || { B_ERR=1; B_REASON="baseline_run_rc=0"; return 1; }
    B_ANCHOR="$(grep -cxF 'FUNCTIONAL_MMU: PASS' "$log" 2>/dev/null || true)"; B_ANCHOR="${B_ANCHOR:-0}"
    [ "$B_ANCHOR" -eq 0 ] || { B_ERR=1; B_REASON="baseline_anchor=$B_ANCHOR"; return 1; }
    B_SUMCNT="$(grep -c '^FUNCTIONAL_MMU_VECTORS ' "$log" 2>/dev/null || true)"; B_SUMCNT="${B_SUMCNT:-0}"
    [ "$B_SUMCNT" -eq 1 ] || { B_ERR=1; B_REASON="baseline_summary_count=$B_SUMCNT"; return 1; }
    bline="$(grep -m1 '^FUNCTIONAL_MMU_VECTORS ' "$log" 2>/dev/null || true)"
    if [[ "$bline" =~ ^FUNCTIONAL_MMU_VECTORS\ total=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)$ ]]; then
        B_TOTAL="${BASH_REMATCH[1]}"; B_CHECKS="${BASH_REMATCH[2]}"; B_FAILS="${BASH_REMATCH[3]}"
    else
        B_ERR=1; B_REASON="baseline_summary_format"; return 1
    fi
    [ "$B_TOTAL"  -eq "$SPEC_VECTORS" ] || { B_ERR=1; B_REASON="baseline_total=$B_TOTAL expect=$SPEC_VECTORS"; return 1; }
    [ "$B_CHECKS" -gt 0 ] || { B_ERR=1; B_REASON="baseline_checks_zero"; return 1; }
    [ "$B_FAILS"  -gt 0 ] || { B_ERR=1; B_REASON="baseline_fails_zero"; return 1; }
    #   ★ 独审 P1③：旧树也必须**完整跑完**并逐项对冻结表（OLD_CHECKS），
    #     且逐向量判定"缺陷向量必须红 / 控制向量必须绿"——不能靠凑满标签、
    #     半途退出就把 ctrl_ok 当成通过。
    parse_vec_lines "$log" "$OLD_CHECKS"
    B_VECN="$PV_LINES"; B_VECSUM="$PV_SUM"; B_VECBAD="$PV_BADFMT"
    [ "$B_VECN" -eq "$SPEC_VECTORS" ] || { B_ERR=1; B_REASON="baseline_vec_lines=$B_VECN"; return 1; }
    [ "$B_VECBAD" -eq 0 ]             || { B_ERR=1; B_REASON="baseline_vec_bad=$B_VECBAD"; return 1; }
    [ "$PV_NAMEBAD" -eq 0 ]           || { B_ERR=1; B_REASON="baseline_vec_name_mismatch=$PV_NAMEBAD"; return 1; }
    [ "$PV_CHKBAD" -eq 0 ]            || { B_ERR=1; B_REASON="baseline_vec_checks_mismatch=$PV_CHKBAD"; return 1; }
    [ "$PV_ZERO" -eq 0 ]              || { B_ERR=1; B_REASON="baseline_vec_checks_zero=$PV_ZERO"; return 1; }
    [ "$PV_MISS" -eq 0 ]              || { B_ERR=1; B_REASON="baseline_vec_missing_idx=$PV_MISS"; return 1; }
    [ "$PV_EXTRA" -eq 0 ]             || { B_ERR=1; B_REASON="baseline_vec_extra_idx=$PV_EXTRA"; return 1; }
    [ "$B_VECSUM" -eq "$CHECKS_TOTAL_OLD" ] || { B_ERR=1; B_REASON="baseline_vec_sum=$B_VECSUM expect=$CHECKS_TOTAL_OLD"; return 1; }
    [ "$B_VECSUM" -eq "$B_CHECKS" ]   || { B_ERR=1; B_REASON="baseline_vec_sum_ne_summary"; return 1; }
    #   · 缺陷向量：每一条都必须 fails>0（不是"只要总 fails>0"）
    #   · 控制向量：每一条都必须 fails=0
    local i nm
    local -a NB
    read -r -a NB <<<"$VEC_NAMES"
    for ((i = 1; i <= SPEC_VECTORS; i++)); do
        nm="${NB[$((i - 1))]}"
        case "$nm" in
            CTRL_*)
                [ "${PV_FAIL[$i]:-0}" -eq 0 ] || { B_ERR=1; B_REASON="baseline_ctrl_vec_red:$nm"; return 1; }
                ;;
            *)
                [ "${PV_FAIL[$i]:-0}" -gt 0 ] || { B_ERR=1; B_REASON="baseline_defect_vec_green:$nm"; return 1; }
                ;;
        esac
    done
    B_MISSING="$(missing_defect_tags "$log")"
    [ -z "$B_MISSING" ] || { B_ERR=1; B_REASON="baseline_missing_tags:$B_MISSING"; return 1; }
    B_CTRL="$(grep -c 'MMU FAIL \[CTRL_' "$log" 2>/dev/null || true)"; B_CTRL="${B_CTRL:-0}"
    [ "$B_CTRL" -eq 0 ] || { B_ERR=1; B_REASON="baseline_ctrl_fails=$B_CTRL"; return 1; }
    return 0
}

missing_defect_tags() {
    local log="$1" tag missing=""
    for tag in $DEFECT_TAGS; do
        grep -qF "MMU FAIL [${tag}]" "$log" 2>/dev/null || missing="${missing} ${tag}"
    done
    printf '%s' "$missing"
}

run_positive_case() {
    case_compile current "$DUT_ROOT"
    P_COMPILE_RC="$CASE_COMPILE_RC"; P_VVP_OK="$CASE_VVP_OK"
    P_HASH_RC="$CASE_HASH_RC"; P_HASH_LINES="$CASE_HASH_LINES"
    P_HASH_BADHEX="$CASE_HASH_BADHEX"; P_HASH_CHANGED="$CASE_HASH_CHANGED"
    P_RUN_RC="$CASE_RUN_RC"; P_LOG="$CASE_RLOG"; P_CLOG="$CASE_CLOG"
    P_DIR="$CASE_DIR"; P_HASH="$CASE_HASH"
    P_TOTAL="-"; P_CHECKS="-"; P_FAILS="-"; P_ANCHOR=0; P_VECN=0; P_PASSOCC=0
    if [ "$P_COMPILE_RC" -ne 0 ]; then
        P_ERR=1; P_REASON="compile_rc=$P_COMPILE_RC vvp_ok=$P_VVP_OK"; return 1
    fi
    if [ "$P_HASH_RC" -ne 0 ]; then
        P_ERR=1
        if [ "$P_HASH_CHANGED" -eq 1 ]; then P_REASON="hash_changed_during_run"
        else P_REASON="hash_rc=$P_HASH_RC lines=$P_HASH_LINES badhex=$P_HASH_BADHEX"; fi
        return 1
    fi
    if gate_positive_log "$P_LOG" "$P_RUN_RC"; then P_ERR=0; P_REASON="ok"; else P_ERR=1; P_REASON="$G_REASON"; fi
    P_TOTAL="$G_TOTAL"; P_CHECKS="$G_CHECKS"; P_FAILS="$G_FAILS"
    P_ANCHOR="$G_ANCHOR"; P_VECN="$G_VECN"; P_PASSOCC="$G_PASSOCC"
    return "$P_ERR"
}

emit_pos_failure() {
    printf 'mmu: POSITIVE_CHECK_FAILED reason=%s compile_rc=%s vvp_ok=%s hash_rc=%s hash_lines=%s hash_badhex=%s run_rc=%s total=%s checks=%s fails=%s vec_lines=%s\n' \
           "$P_REASON" "$P_COMPILE_RC" "$P_VVP_OK" "$P_HASH_RC" "$P_HASH_LINES" \
           "${P_HASH_BADHEX:-0}" "$P_RUN_RC" "$P_TOTAL" "$P_CHECKS" "$P_FAILS" "$P_VECN"
    printf 'mmu: compile_log=%s run_log=%s\n' "${P_CLOG:-<none>}" "${P_LOG:-<none>}"
}

#==============================================================================
# 2. --self-test：日志判据夹具反证 + 端到端反证
#==============================================================================
selftest_main() {
    local st_dir
    mkdir -p "${AUTH_ROOT}/mmu"
    st_dir="$(mktemp -d "${AUTH_ROOT}/mmu/selftest.XXXXXXXX")"
    local pass=0 total=0

    #   合法夹具必须逐向量带 name 且 checks == NEW_CHECKS（否则"32×1 checks 自证"
    #   这种凑数日志会被误当成合法 —— 独审 P1③）
    mk_good_log() {
        local out="$1" i
        local -a N C
        read -r -a N <<<"$VEC_NAMES"
        read -r -a C <<<"$NEW_CHECKS"
        : > "$out"
        printf '%s\n' '---- tb_mmu_semantics ----' >> "$out"
        for ((i = 1; i <= SPEC_VECTORS; i++)); do
            printf 'VEC %d name=%s checks=%d fails=0\n' "$i" "${N[$((i - 1))]}" "${C[$((i - 1))]}" >> "$out"
        done
        printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' \
               "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW" >> "$out"
        printf 'FUNCTIONAL_MMU: PASS\n' >> "$out"
    }

    run_gate_case() {   # <名称> <期望 pass|reject> <日志> <rc>
        local name="$1" expect="$2" log="$3" rc="$4" got
        total=$((total + 1))
        if gate_positive_log "$log" "$rc"; then got=pass; else got=reject; fi
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1))
            printf 'SELFTEST %-26s expected=%-6s got=%-6s OK\n' "$name" "$expect" "$got"
        else
            printf 'SELFTEST %-26s expected=%-6s got=%-6s MISMATCH reason=%s\n' "$name" "$expect" "$got" "$G_REASON"
        fi
    }

    run_bl_case() {
        local name="$1" expect="$2" log="$3" rc="$4" got
        total=$((total + 1))
        if gate_baseline_log "$log" "$rc"; then got=pass; else got=reject; fi
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1))
            printf 'SELFTEST %-26s expected=%-6s got=%-6s OK\n' "$name" "$expect" "$got"
        else
            printf 'SELFTEST %-26s expected=%-6s got=%-6s MISMATCH reason=%s\n' "$name" "$expect" "$got" "$B_REASON"
        fi
    }

    mk_good_log "${st_dir}/good.log"
    grep -v '^FUNCTIONAL_MMU: PASS$' "${st_dir}/good.log" > "${st_dir}/no_anchor.log" || true
    cp "${st_dir}/good.log" "${st_dir}/dup_anchor.log"; printf 'FUNCTIONAL_MMU: PASS\n' >> "${st_dir}/dup_anchor.log"
    grep -v '^FUNCTIONAL_MMU_VECTORS ' "${st_dir}/good.log" > "${st_dir}/no_summary.log" || true
    cp "${st_dir}/good.log" "${st_dir}/dup_summary.log"; printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW" >> "${st_dir}/dup_summary.log"
    sed 's/^FUNCTIONAL_MMU_VECTORS total=32 checks=235 fails=0$/FUNCTIONAL_MMU_VECTORS total=32 checks=235/' \
        "${st_dir}/good.log" > "${st_dir}/bad_summary_fmt.log"
    sed 's/^FUNCTIONAL_MMU_VECTORS total=32 /FUNCTIONAL_MMU_VECTORS total=31 /' \
        "${st_dir}/good.log" > "${st_dir}/bad_total.log"
    sed "s/^FUNCTIONAL_MMU_VECTORS total=32 checks=235 fails=0$/FUNCTIONAL_MMU_VECTORS total=32 checks=0 fails=0/" \
        "${st_dir}/good.log" > "${st_dir}/zero_checks.log"
    sed 's/^FUNCTIONAL_MMU_VECTORS total=32 checks=235 fails=0$/FUNCTIONAL_MMU_VECTORS total=32 checks=235 fails=1/' \
        "${st_dir}/good.log" > "${st_dir}/summary_fails.log"
    grep -v "^VEC ${SPEC_VECTORS} " "${st_dir}/good.log" > "${st_dir}/vec_missing_line.log" || true
    sed "s/^VEC ${SPEC_VECTORS} /VEC $((SPEC_VECTORS - 1)) /" "${st_dir}/good.log" > "${st_dir}/vec_dup_idx.log"
    sed "s/^VEC ${SPEC_VECTORS} /VEC $((SPEC_VECTORS + 1)) /" "${st_dir}/good.log" > "${st_dir}/vec_extra_idx.log"
    local v5line
    v5line="$(grep '^VEC 5 ' "${st_dir}/good.log")"
    grep -v '^VEC 5 ' "${st_dir}/good.log" > "${st_dir}/vec_bad_fmt.log" || true
    printf '%s\n' "$(printf '%s' "$v5line" | sed 's/ checks=[0-9]*//')" >> "${st_dir}/vec_bad_fmt.log"
    grep -v '^VEC 5 ' "${st_dir}/good.log" > "${st_dir}/vec_zero.log" || true
    printf '%s\n' "$(printf '%s' "$v5line" | sed 's/ checks=[0-9]*/ checks=0/')" >> "${st_dir}/vec_zero.log"
    grep -v '^VEC 5 ' "${st_dir}/good.log" > "${st_dir}/vec_fails.log" || true
    printf '%s\n' "$(printf '%s' "$v5line" | sed 's/ fails=[0-9]*/ fails=1/')" >> "${st_dir}/vec_fails.log"
    #   ★ 独审 P1③：减 checks（不补偿）与"补偿式"（一减一加、总数不变）都必须被拒
    grep -v '^VEC 5 ' "${st_dir}/good.log" > "${st_dir}/vec_reduced.log" || true
    printf '%s\n' "$(printf '%s' "$v5line" | sed 's/ checks=[0-9]*/ checks=1/')" >> "${st_dir}/vec_reduced.log"
    grep -v '^VEC [56] ' "${st_dir}/good.log" > "${st_dir}/vec_compensated.log" || true
    printf '%s\n' "$(printf '%s' "$v5line" | sed 's/ checks=[0-9]*/ checks=1/')" >> "${st_dir}/vec_compensated.log"
    printf '%s\n' "$(grep '^VEC 6 ' "${st_dir}/good.log" | sed 's/ checks=[0-9]*/ checks=99/')" >> "${st_dir}/vec_compensated.log"
    #   校验和仍与摘要一致（补偿式攻击的真面目）—— 只改 VEC 行，不动摘要
    sed 's/^VEC 5 .*/VEC 5 name=CTRL_SVADE_A0 checks=1 fails=0/' "${st_dir}/good.log" > "${st_dir}/vec_name_bad.log"
    sed 's/^---- tb_mmu_semantics ----$/MMU FAIL [MMU_PA34_ROOT]: x/' "${st_dir}/good.log" > "${st_dir}/has_fail.log"
    sed 's/^---- tb_mmu_semantics ----$/DEFECT_REPRODUCED: X/' "${st_dir}/good.log" > "${st_dir}/has_defect.log"
    : > "${st_dir}/empty.log"

    run_gate_case good                pass   "${st_dir}/good.log"              0
    run_gate_case no_anchor           reject "${st_dir}/no_anchor.log"         0
    run_gate_case dup_anchor          reject "${st_dir}/dup_anchor.log"        0
    run_gate_case no_summary          reject "${st_dir}/no_summary.log"        0
    run_gate_case dup_summary         reject "${st_dir}/dup_summary.log"       0
    run_gate_case bad_summary_fmt     reject "${st_dir}/bad_summary_fmt.log"   0
    run_gate_case bad_total           reject "${st_dir}/bad_total.log"         0
    run_gate_case zero_checks         reject "${st_dir}/zero_checks.log"       0
    run_gate_case summary_fails       reject "${st_dir}/summary_fails.log"     0
    run_gate_case vec_missing_line    reject "${st_dir}/vec_missing_line.log"  0
    run_gate_case vec_dup_idx         reject "${st_dir}/vec_dup_idx.log"       0
    run_gate_case vec_extra_idx       reject "${st_dir}/vec_extra_idx.log"     0
    run_gate_case vec_bad_fmt         reject "${st_dir}/vec_bad_fmt.log"       0
    run_gate_case vec_zero            reject "${st_dir}/vec_zero.log"          0
    run_gate_case vec_fails           reject "${st_dir}/vec_fails.log"         0
    run_gate_case vec_reduced         reject "${st_dir}/vec_reduced.log"       0
    run_gate_case vec_compensated     reject "${st_dir}/vec_compensated.log"   0
    run_gate_case vec_name_bad        reject "${st_dir}/vec_name_bad.log"      0
    run_gate_case has_fail            reject "${st_dir}/has_fail.log"          0
    run_gate_case has_defect          reject "${st_dir}/has_defect.log"        0
    run_gate_case empty_capture       reject "${st_dir}/empty.log"             0
    run_gate_case missing_file        reject "${st_dir}/does_not_exist.log"    0
    run_gate_case timeout_rc          reject "${st_dir}/good.log"              124
    run_gate_case nonzero_rc          reject "${st_dir}/good.log"              1

    # ---- 反证门控夹具：旧红（fails>0 + 标签全在 + CTRL 0）通过；新绿被拒 ----
    #   ★ 反证夹具：旧树逐向量 = OLD_CHECKS；缺陷向量红、控制向量绿。
    local bl_ok="${st_dir}/bl_ok.log" tag i nm
    local -a BN BC
    read -r -a BN <<<"$VEC_NAMES"
    read -r -a BC <<<"$OLD_CHECKS"
    : > "$bl_ok"
    for ((i = 1; i <= SPEC_VECTORS; i++)); do
        nm="${BN[$((i - 1))]}"
        case "$nm" in
            CTRL_*) printf 'VEC %d name=%s checks=%d fails=0\n' "$i" "$nm" "${BC[$((i - 1))]}" >> "$bl_ok" ;;
            *)      printf 'VEC %d name=%s checks=%d fails=1\n' "$i" "$nm" "${BC[$((i - 1))]}" >> "$bl_ok" ;;
        esac
    done
    for tag in $DEFECT_TAGS; do printf 'MMU FAIL [%s]: x\n' "$tag" >> "$bl_ok"; done
    printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=%d\n' \
           "$SPEC_VECTORS" "$CHECKS_TOTAL_OLD" "$(grep -o 'fails=1' "$bl_ok" | wc -l)" >> "$bl_ok"
    run_bl_case baseline_red_ok       pass   "$bl_ok"                    1
    run_bl_case baseline_green_rej    reject "${st_dir}/good.log"        0
    run_bl_case baseline_rc0_rej      reject "$bl_ok"                    0
    grep -v 'MMU_PA34_L0' "$bl_ok" > "${st_dir}/bl_tag_missing.log" || true
    run_bl_case baseline_tag_missing  reject "${st_dir}/bl_tag_missing.log" 1
    #   半跑：只保留前 10 个向量（其余行删掉）——即便标签凑满也必须拒
    awk '/^VEC /{n++; if (n>10) next} {print}' "$bl_ok" > "${st_dir}/bl_half.log"
    run_bl_case baseline_half_run     reject "${st_dir}/bl_half.log"     1
    #   缺陷向量变绿（把 MMU_PA34_ROOT 那行 fails 改 0）⇒ 拒
    sed 's/^\(VEC 11 name=MMU_PA34_ROOT checks=[0-9]*\) fails=1$/\1 fails=0/' "$bl_ok" > "${st_dir}/bl_defect_green.log"
    run_bl_case baseline_defect_green reject "${st_dir}/bl_defect_green.log" 1
    #   控制向量变红 ⇒ 拒
    sed 's/^\(VEC 1 name=CTRL_XZ_DETECT checks=[0-9]*\) fails=0$/\1 fails=1/' "$bl_ok" > "${st_dir}/bl_ctrl_red.log"
    run_bl_case baseline_ctrl_vec_red reject "${st_dir}/bl_ctrl_red.log" 1
    printf 'MMU FAIL [CTRL_X]: x\n' >> "$bl_ok"
    run_bl_case baseline_ctrl_fail    reject "$bl_ok"                    1

    local miss_full miss_one
    miss_full="$(missing_defect_tags "$bl_ok")"
    miss_one="$(missing_defect_tags "${st_dir}/bl_tag_missing.log")"
    total=$((total + 2))
    if [ -z "$miss_full" ]; then pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-6s got=%-6s OK\n' tags_full none none
    else printf 'SELFTEST %-26s expected=%-6s got=%-6s MISMATCH\n' tags_full none "$miss_full"; fi
    if [ "$miss_one" = " MMU_PA34_L0" ]; then pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-6s got=%-6s OK\n' tags_one_missing MMU_PA34_L0 "$miss_one"
    else printf 'SELFTEST %-26s expected=%-6s got=%-6s MISMATCH\n' tags_one_missing MMU_PA34_L0 "$miss_one"; fi

    # ---- 冻结基线哈希自检（git 中该短哈希 == 冻结全哈希）----
    local full
    total=$((total + 1))
    if full="$(git -C "$REPO_ROOT" rev-parse "${BASE_COMMIT_SHORT}^{commit}" 2>/dev/null)" && [ "$full" = "$BASE_COMMIT_FULL" ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-6s got=%-6s OK\n' frozen_commit "$BASE_COMMIT_FULL" "$full"
    else
        printf 'SELFTEST %-26s expected=%-6s got=%-6s MISMATCH\n' frozen_commit "$BASE_COMMIT_FULL" "${full:-<none>}"
    fi

    #======================================================================
    # 端到端反证（真实走 case_compile/hash/gate/subprocess；沙箱只在本 selftest 目录内）
    #======================================================================
    local e2e="$st_dir/e2e" fb="$st_dir/fakebin"
    mkdir -p "$e2e" "$fb"
    local sb="$e2e/src_ok"
    mkdir -p "$sb/rtl/csr" "$sb/rtl/mem" "$sb/rtl/pkg"
    cp -f "$REPO_ROOT"/rtl/csr/{ptw.v,tlb.v} "$sb/rtl/csr/"
    cp -f "$REPO_ROOT"/rtl/mem/{lsu.v,pmp_check.v,mmio_route.v,amo_unit.v,cmo_unit.v} "$sb/rtl/mem/"
    cp -f "$REPO_ROOT/rtl/pkg/rv32_defs.vh" "$REPO_ROOT/rtl/pkg/core_params.vh" "$sb/rtl/pkg/"

    cat > "$fb/iverilog_ok" <<'EOS'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
printf 'fake vvp payload\n' > "$out"
exit 0
EOS
    cat > "$fb/iverilog_zero" <<'EOS'
#!/bin/sh
exit 0
EOS
    cat > "$fb/iverilog_fail" <<'EOS'
#!/bin/sh
exit 3
EOS
    cat > "$fb/vvp_fail" <<'EOS'
#!/bin/sh
exit 1
EOS
    cat > "$fb/vvp_sleep" <<'EOS'
#!/bin/sh
sleep 5
exit 0
EOS
    cat > "$fb/vvp_quiet" <<'EOS'
#!/bin/sh
exit 0
EOS
    cat > "$fb/vvp_mutate" <<EOS
#!/bin/sh
printf '\\n// mutated during run\\n' >> "$sb/rtl/csr/ptw.v"
exit 0
EOS
    cat > "$fb/sha_fail" <<'EOS'
#!/bin/sh
exit 9
EOS
    cat > "$fb/sha_short" <<'EOS'
#!/bin/sh
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  x\n'
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  y\n'
printf 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  z\n'
exit 0
EOS
    cat > "$fb/sha_nonhex" <<'EOS'
#!/bin/sh
i=0
while [ "$i" -lt 10 ]; do
    printf 'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ  f%s\n' "$i"
    i=$((i + 1))
done
exit 0
EOS
    chmod +x "$fb"/*
    mkdir -p "$e2e/p_rc" "$e2e/p_short" "$e2e/p_nonhex"
    cp -f "$fb/sha_fail"   "$e2e/p_rc/sha256sum"
    cp -f "$fb/sha_short"  "$e2e/p_short/sha256sum"
    cp -f "$fb/sha_nonhex" "$e2e/p_nonhex/sha256sum"
    chmod +x "$e2e"/p_rc/sha256sum "$e2e"/p_short/sha256sum "$e2e"/p_nonhex/sha256sum

    local e2e_start
    e2e_start=$(date +%s)

    e2e_case() {   # <名称> <期望结果串> <iverilog> <vvp> <sandbox> [PATH 前缀]
        local name="$1" expect="$2" iv="$3" vv="$4" root="$5" pathpfx="${6:-}"
        local saved_path="$PATH" got
        RUN_DIR="$e2e/run_${name}"
        [ -n "$pathpfx" ] && PATH="$pathpfx:$PATH"
        case_compile "$name" "$root" "$iv" "$vv"
        PATH="$saved_path"
        if [ "$CASE_COMPILE_RC" -ne 0 ]; then got="compile_rc=$CASE_COMPILE_RC"
        elif [ "$CASE_HASH_RC" -ne 0 ]; then got="hash_rc=$CASE_HASH_RC"
        elif [ "$CASE_RUN_RC" -ne 0 ]; then got="run_rc=$CASE_RUN_RC"
        else got="ok"; fi
        total=$((total + 1))
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' "$name" "$expect" "$got"
        else
            printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' "$name" "$expect" "$got"
        fi
    }

    # 合法同工具正控：真实 iverilog/vvp + 真实沙箱源 ⇒ 全链通过
    RUN_DIR="$e2e/run_pos_control"
    if case_compile pos_control "$sb" "$IV" "$VVP" && gate_positive_log "$CASE_RLOG" "$CASE_RUN_RC"; then
        total=$((total + 1)); pass=$((pass + 1))
        printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_positive_control pass pass
    else
        total=$((total + 1))
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH reason=%s\n' \
               e2e_positive_control pass "reject($G_REASON)" "rc=$CASE_RUN_RC"
    fi
    # 缺头：删掉沙箱 rv32_defs.vh ⇒ 输入预检 96
    local sb_nohdr="$e2e/src_nohdr"
    cp -a "$sb" "$sb_nohdr"; rm -f "$sb_nohdr/rtl/pkg/rv32_defs.vh"
    e2e_case e2e_missing_header "compile_rc=96" "$fb/iverilog_ok" "$fb/vvp_quiet" "$sb_nohdr"
    e2e_case e2e_zero_vvp       "compile_rc=98" "$fb/iverilog_zero" "$fb/vvp_quiet" "$sb"
    e2e_case e2e_compile_rc     "compile_rc=3"  "$fb/iverilog_fail" "$fb/vvp_quiet" "$sb"
    e2e_case e2e_hash_rc        "hash_rc=9"  "$fb/iverilog_ok" "$fb/vvp_quiet" "$sb" "$e2e/p_rc"
    e2e_case e2e_hash_lines     "hash_rc=97" "$fb/iverilog_ok" "$fb/vvp_quiet" "$sb" "$e2e/p_short"
    e2e_case e2e_hash_nonhex    "hash_rc=96" "$fb/iverilog_ok" "$fb/vvp_quiet" "$sb" "$e2e/p_nonhex"
    e2e_case e2e_run_nonzero    "run_rc=1"   "$fb/iverilog_ok" "$fb/vvp_fail"  "$sb"
    RUN_DIR="$e2e/run_timeout"
    local old_rto="$CASE_RUN_TIMEOUT"; CASE_RUN_TIMEOUT=1
    case_compile e2e_run_timeout "$sb" "$fb/iverilog_ok" "$fb/vvp_sleep"
    CASE_RUN_TIMEOUT="$old_rto"
    total=$((total + 1))
    if [ "$CASE_RUN_RC" -eq 124 ]; then pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_run_timeout "run_rc=124" "run_rc=$CASE_RUN_RC"
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_run_timeout "run_rc=124" "run_rc=$CASE_RUN_RC"; fi
    e2e_case e2e_src_changed    "hash_rc=95" "$fb/iverilog_ok" "$fb/vvp_mutate" "$sb"
    RUN_DIR="$e2e/run_nocap"
    case_compile e2e_nocap "$sb" "$fb/iverilog_ok" "$fb/vvp_quiet"
    total=$((total + 1))
    if gate_positive_log "$CASE_RLOG" "$CASE_RUN_RC"; then
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_no_capture reject pass
    else
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK reason=%s\n' e2e_no_capture reject reject "$G_REASON"
    fi

    #======================================================================
    # ★ 独审 P2：四态 monitor 的**真实刺激**反证（不是谓词常量自测）
    #   · 负向构建：-DMMU_XZ_NEG 把 TB 驱动的活跃控制线打成 X
    #     ⇒ 真 xz 计数 → vecend 报 XZ_CONTROL → 正式 gate 必须 reason=xz_control 拒；
    #   · 变异体：把 monitor 的判定改成恒假 ⇒ 同一负向构建**不得**再出现 XZ_CONTROL，
    #     证明上一条不是"标签写死"而是真的依赖 monitor。
    #======================================================================
    xz_case() {   # <名称> <tb 文件>
        local nm="$1" tbf="$2"
        RUN_DIR="$e2e/run_${nm}"
        #   自检模式没有 DUT_ROOT（正式入口才有）⇒ 用本函数前面已建的沙箱源副本
        case_compile "$nm" "${XZ_DUT:-$sb}" "$IV" "$VVP" "-DMMU_XZ_NEG" "$tbf"
        local got=ok
        if [ "$CASE_COMPILE_RC" -ne 0 ]; then got="compile_rc=$CASE_COMPILE_RC"
        elif [ "$CASE_HASH_RC" -ne 0 ]; then got="hash_rc=$CASE_HASH_RC"
        elif [ "$CASE_RUN_RC" -eq 0 ]; then got="run_rc=0"
        fi
        XZ_RC="$CASE_RUN_RC"; XZ_LOG="$CASE_RLOG"; XZ_COMPILE="$CASE_COMPILE_RC"
        XZ_GOT="$got"
    }
    xz_case xz_neg_detected "$TB"
    total=$((total + 1))
    if [ "$XZ_COMPILE" -eq 0 ] && [ "$XZ_RC" -ne 0 ] \
       && grep -q 'MMU FAIL \[XZ_CONTROL\]' "$XZ_LOG" 2>/dev/null \
       && gate_positive_log "$XZ_LOG" "$XZ_RC"; then
        :   # gate_positive_log 返回 0 表示"通过"，此处不应发生
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_xz_neg_detected "xz_control" "gate_pass"
    elif [ "$XZ_COMPILE" -eq 0 ] && [ "$XZ_RC" -ne 0 ] \
         && [ "$G_REASON" = "xz_control" ] \
         && grep -q 'MMU FAIL \[XZ_CONTROL\]' "$XZ_LOG" 2>/dev/null \
         && [ "$(grep -cxF 'FUNCTIONAL_MMU: PASS' "$XZ_LOG" 2>/dev/null || true)" = "0" ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK reason=%s\n' e2e_xz_neg_detected xz_control xz_control "$G_REASON"
    else
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH reason=%s\n' e2e_xz_neg_detected xz_control "${XZ_GOT:-?}" "${G_REASON:-?}"
    fi

    #   ---- 变异体：把 monitor 判定改恒假（只在私有沙箱副本里改，不碰正式 TB）----
    MUT_DIR="$e2e/xz_mutant"
    mkdir -p "$MUT_DIR"
    MUT_TB="$MUT_DIR/tb_mmu_semantics_mut.sv"
    sed 's/if (xz_cnt != 0) begin/if (1'"'"'b0) begin/' "$TB" > "$MUT_TB"
    if cmp -s "$TB" "$MUT_TB"; then
        total=$((total + 1))
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_xz_mutant "mutated" "sed_noop"
    else
        xz_case xz_mutant "$MUT_TB"
        total=$((total + 1))
        if [ "$XZ_COMPILE" -eq 0 ] && ! grep -q 'MMU FAIL \[XZ_CONTROL\]' "$XZ_LOG" 2>/dev/null; then
            pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_xz_mutant "no_xz_tag" "no_xz_tag"
        else
            printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH rc=%s\n' e2e_xz_mutant "no_xz_tag" "still_tagged" "$XZ_RC"
        fi
    fi
    #   注：合法 0/1 值的正控由本函数前面的 e2e_positive_control（不带宏）覆盖。

    # ---- 端到端正控：调用 cwd 里放**私有 poison 头**，完整源 root 仍能编译 ----
    local poison="$e2e/poison_cwd" sb_poison="$e2e/src_poison"
    mkdir -p "$poison/rtl/pkg" "$sb_poison/rtl/csr" "$sb_poison/rtl/mem" "$sb_poison/rtl/pkg"
    cp -f "$REPO_ROOT"/rtl/csr/{ptw.v,tlb.v} "$sb_poison/rtl/csr/"
    cp -f "$REPO_ROOT"/rtl/mem/{lsu.v,pmp_check.v,mmio_route.v,amo_unit.v,cmo_unit.v} "$sb_poison/rtl/mem/"
    cp -f "$REPO_ROOT/rtl/pkg/rv32_defs.vh" "$REPO_ROOT/rtl/pkg/core_params.vh" "$sb_poison/rtl/pkg/"
    printf '%s\n' '@@@ POISON HEADER: must never be read @@@' > "$poison/rtl/pkg/rv32_defs.vh"
    printf '%s\n' '@@@ POISON HEADER: must never be read @@@' > "$poison/rtl/pkg/core_params.vh"
    local saved_cwd="$PWD"
    cd "$poison"
    RUN_DIR="$e2e/run_poison_cwd"
    case_compile poison_cwd "$sb_poison" "$IV" "$VVP"
    cd "$saved_cwd"
    total=$((total + 1))
    if [ "$CASE_COMPILE_RC" -eq 0 ] && [ "$CASE_HASH_RC" -eq 0 ] \
       && gate_positive_log "$CASE_RLOG" "$CASE_RUN_RC"; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_poison_cwd_isolated pass pass
    else
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH compile_rc=%s hash_rc=%s reason=%s\n' \
               e2e_poison_cwd_isolated pass "reject" "$CASE_COMPILE_RC" "$CASE_HASH_RC" "$G_REASON"
    fi

    # 脚本失败分支：子进程走默认模式 + 假 vvp（运行 rc=1）⇒ rc 精确 1 且 stdout 无正式锚点
    local sout src_rc=0
    sout="$(RV32_VVP="$fb/vvp_fail" bash "$SCRIPT_PATH" 2>&1)" || src_rc=$?
    total=$((total + 1))
    local a_cnt
    a_cnt="$(printf '%s\n' "$sout" | grep -cxF 'FUNCTIONAL_MMU: PASS' || true)"; a_cnt="${a_cnt:-0}"
    if [ "$src_rc" -eq 1 ] && [ "$a_cnt" -eq 0 ] \
       && printf '%s\n' "$sout" | grep -q 'POSITIVE_CHECK_FAILED' \
       && ! printf '%s\n' "$sout" | grep -q 'PASS'; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_fail_branch_no_pass "rc=1,no_anchor" "rc=$src_rc,anchor=$a_cnt"
    else
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_fail_branch_no_pass "rc=1,no_anchor" "rc=$src_rc,anchor=$a_cnt"
    fi
    local e2e_end; e2e_end=$(date +%s)
    printf 'SELFTEST_E2E_SECONDS: %s\n' "$((e2e_end - e2e_start))"

    printf 'SELFTEST_FIXTURES: %s\n' "$st_dir"
    printf 'SELFTEST_TOTAL: %d/%d\n' "$pass" "$total"
    if [ "$pass" -eq "$total" ]; then
        printf 'SELFTEST_OK\n'
        exit 0
    fi
    printf 'SELFTEST_BAD: %d/%d\n' "$pass" "$total"
    exit 1
}

#==============================================================================
# 3. 默认：仅正向正确行为
#==============================================================================
default_main() {
    need_sim_tools
    local root; root="$(resolve_root)"
    RUN_DIR="$(mktemp -d -- "${root}/run-XXXXXXXX")" || die "mktemp -d 失败（根=${root}）"
    DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
    DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || die "DUT_ROOT 不可用：${DUT_ROOT:-<空>}"
    local f
    for f in "${DUT_REL_LIST[@]}" "${DUT_HDR_REL_LIST[@]}"; do
        [ -r "${DUT_ROOT}/${f}" ] || die "DUT_ROOT 缺 ${f}：${DUT_ROOT}"
    done

    printf 'mmu: run_dir=%s\n' "$RUN_DIR"
    printf 'mmu: dut_root=%s tb=%s\n' "$DUT_ROOT" "$TB"

    if ! run_positive_case; then
        emit_pos_failure
        exit 1
    fi

    local h_ptw h_tlb h_lsu h_pmp h_mmio h_amo h_cmo h_defs h_par h_tb
    h_ptw="$(awk  '$2 ~ /ptw\.v$/         {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_tlb="$(awk  '$2 ~ /tlb\.v$/         {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_lsu="$(awk  '$2 ~ /lsu\.v$/         {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_pmp="$(awk  '$2 ~ /pmp_check\.v$/   {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_mmio="$(awk '$2 ~ /mmio_route\.v$/  {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_amo="$(awk  '$2 ~ /amo_unit\.v$/    {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_cmo="$(awk  '$2 ~ /cmo_unit\.v$/    {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_defs="$(awk '$2 ~ /rv32_defs\.vh$/  {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_par="$(awk  '$2 ~ /core_params\.vh$/ {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    h_tb="$(awk   '$2 ~ /tb_mmu_semantics\.sv$/ {print substr($1,1,12); exit}' "$P_HASH" 2>/dev/null || true)"
    printf 'mmu: src_sha256 ptw=%s tlb=%s lsu=%s pmp_check=%s mmio_route=%s amo_unit=%s cmo_unit=%s rv32_defs=%s core_params=%s tb=%s\n' \
           "${h_ptw:-?}" "${h_tlb:-?}" "${h_lsu:-?}" "${h_pmp:-?}" "${h_mmio:-?}" "${h_amo:-?}" "${h_cmo:-?}" \
           "${h_defs:-?}" "${h_par:-?}" "${h_tb:-?}"
    printf 'mmu: compile_rc=%s vvp_ok=%s hash_lines=%s hash_badhex=%s run_rc=%s total=%s checks=%s fails=%s vec_lines=%s anchor_lines=%s pass_substr=%s\n' \
           "$P_COMPILE_RC" "$P_VVP_OK" "$P_HASH_LINES" "$P_HASH_BADHEX" "$P_RUN_RC" "$P_TOTAL" \
           "$P_CHECKS" "$P_FAILS" "$P_VECN" "$P_ANCHOR" "$P_PASSOCC"
    printf 'mmu: log_dir=%s\n' "$P_DIR"
    printf 'FUNCTIONAL_MMU: PASS\n'
    exit 0
}

#==============================================================================
# 4. --check-baseline：新绿 + 201acf61 旧红（成功不输出正式锚点）
#==============================================================================
baseline_main() {
    need_sim_tools
    command -v git >/dev/null 2>&1 || die "未找到 git（反证需要）"
    command -v tar >/dev/null 2>&1 || die "未找到 tar（反证需要）"
    local root; root="$(resolve_root)"
    RUN_DIR="$(mktemp -d -- "${root}/run-XXXXXXXX")" || die "mktemp -d 失败（根=${root}）"
    DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
    DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || die "DUT_ROOT 不可用：${DUT_ROOT:-<空>}"
    local f
    for f in "${DUT_REL_LIST[@]}" "${DUT_HDR_REL_LIST[@]}"; do
        [ -r "${DUT_ROOT}/${f}" ] || die "DUT_ROOT 缺 ${f}：${DUT_ROOT}"
    done

    printf 'mmu(baseline): run_dir=%s\n' "$RUN_DIR"

    # 4.1 当前源必须绿；此处**不**打印正式锚点
    local cur_ok=1
    run_positive_case || cur_ok=0

    # 4.2 冻结基线：本次 run 私有目录内 git archive 精确提交（无 cache、无 rm 旧目录）
    local full priv
    full="$(git -C "$REPO_ROOT" rev-parse "${BASE_COMMIT_SHORT}^{commit}" 2>/dev/null)" \
        || die "git 中找不到冻结基线 ${BASE_COMMIT_SHORT}"
    [ "$full" = "$BASE_COMMIT_FULL" ] \
        || die "基线提交哈希不符：期望 ${BASE_COMMIT_FULL}，实得 ${full}"
    priv="$(mktemp -d "${RUN_DIR}/baseline-src.XXXXXXXX")" || die "mktemp -d 失败"
    git -C "$REPO_ROOT" archive "$full" rtl | tar -x -C "$priv" || die "git archive ${full} rtl 失败"
    printf 'mmu(baseline): baseline_src=%s commit=%s\n' "$priv" "$full"

    case_compile baseline "$priv"
    local b_err=0
    if ! gate_baseline_log "$CASE_RLOG" "$CASE_RUN_RC"; then b_err=1; fi

    printf 'mmu(baseline): current_ok=%s current_total=%s current_checks=%s current_fails=%s\n' \
           "$cur_ok" "$P_TOTAL" "$P_CHECKS" "$P_FAILS"
    printf 'mmu(baseline): compile_rc=%s vvp_ok=%s hash_rc=%s hash_lines=%s run_rc=%s summary_count=%s total=%s checks=%s fails=%s vec_lines=%s vec_bad=%s vec_sum=%s ctrl_fails=%s\n' \
           "$CASE_COMPILE_RC" "$CASE_VVP_OK" "$CASE_HASH_RC" "$CASE_HASH_LINES" "$CASE_RUN_RC" \
           "$B_SUMCNT" "$B_TOTAL" "$B_CHECKS" "$B_FAILS" "$B_VECN" "$B_VECBAD" "$B_VECSUM" "$B_CTRL"
    printf 'mmu(baseline): hash_file=%s\n' "$CASE_HASH"
    if [ -r "$CASE_RLOG" ]; then
        printf -- '--- baseline defect tags ---\n'
        grep -o 'MMU FAIL \[[A-Z_0-9]*\]' "$CASE_RLOG" | sort | uniq -c || true
    fi
    if [ -n "$B_MISSING" ]; then
        printf 'mmu(baseline): missing_defect_tags:%s\n' "$B_MISSING"
    fi

    [ "$CASE_COMPILE_RC" -eq 0 ] || { b_err=1; B_REASON="${B_REASON};compile_rc=$CASE_COMPILE_RC"; }
    [ "$CASE_VVP_OK" -eq 1 ]     || { b_err=1; B_REASON="${B_REASON};no_vvp"; }
    [ "$CASE_HASH_RC" -eq 0 ]    || { b_err=1; B_REASON="${B_REASON};hash_rc=$CASE_HASH_RC"; }

    if [ "$cur_ok" -eq 1 ] && [ "$b_err" -eq 0 ]; then
        printf 'DEFECT_REPRODUCED: %s\n' "$DEFECT_TAGS"
        printf 'mmu(baseline): log_dirs=%s %s\n' "$P_DIR" "$CASE_DIR"
        exit 0
    fi
    [ "$cur_ok" -eq 1 ] || emit_pos_failure
    printf 'mmu(baseline): BASELINE_REPRO_CHECK_FAILED reason=%s\n' "$B_REASON"
    printf 'mmu(baseline): baseline_compile_log=%s baseline_run_log=%s\n' "${CASE_CLOG:-<none>}" "${CASE_RLOG:-<none>}"
    exit 1
}

#==============================================================================
# 5. 入口分发
#==============================================================================
case "$MODE" in
    default)  default_main ;;
    baseline) baseline_main ;;
    selftest) selftest_main ;;
esac
