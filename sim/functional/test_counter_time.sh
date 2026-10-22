#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_counter_time.sh —— F1-B 计数器/时间/MPP 接口契约功能入口
#   （独立包：**不入** sim/functional/manifest.tsv 默认清单；产物 build/functional/counter-time）
#==============================================================================
# 依据 : F1-B 叶包验收（接口名称/时序见 rtl/csr/csr_file.v §计数器端口）：
#        单一 64 位本体留两 top；csr_file 新增 mtime_i + 4 个半字 we + cnt_wdata；
#        CLINT 新增 mtime_o；MPP 在 csr_landing 与 priv_ctrl 旁路统一 WARL。
#        规范：zicsr.adoc:173-180（instret 显式写代替本条副作用）、191-255
#              （norm:csraccessorder / csrr_order / csrw_order）、
#              machine.adoc:1523-1561（mcycle=clock 计数；RV32 半字只改写选中半）、
#              machine.adoc:1624-1658（mcountinhibit）、353-445（MPP WARL）。
# 合同 : mcycle：写拍先整 64 位 tick(+1)，再只覆盖被写半；另一半保留本拍增量/进位。
#        minstret：pre=body+older；半字覆盖(写本条 +1 不计)；+younger。
#        rdata_w/byp_rdata 的计数器别名预览**只含显式半字写**，不含同沿 tick/退休
#        （scope 见 csr_file 注释；跨半 carry 的程序序冒险由 top/2A owner 验）。
#
# 做什么 : 编译 rtl/csr/{csr_file,priv_ctrl}.v + rtl/clint/clint.v + 2 个头文件 +
#          本包 TB sim/functional/tb_counter_time.sv，跑 vvp 并做 fail-closed 门控。
#          TB 内的计数器"本体"是**TB 侧参考模型**（只验证接口+合同可实现），
#          不代表 CPU 计数已闭环；真实 top 由 71 落地后另验。
#
# 产物纪律 : 授权根 <repo>/build/functional；本包默认根 <根>/counter-time；
#            父给 RV32_FUNCTIONAL_PKG_OUT_DIR 时也在其下 mktemp 独占 run-XXXXXXXX；
#            全部产物写在该 run 内；不删除任何历史目录；不用 /tmp。
#
# 身份纪律 : 执行脚本自身 SCRIPT_PATH 也计入冻结哈希（6 编译输入 + env + 脚本 = 8 项）；
#            source **之前**抓 SCRIPT_PATH/TB/ENV_SH 三者起始 SHA，source 后**立即**复检
#            （防 env 自改/换文件），默认尾部再核一次；selftest 每 case/末尾核三者
#            仍等起始。ENV_SH 强绑定 actual 路径（无外部另覆写成 B 而 source A）。
# 环境纪律 : source scripts/env.sh 时**显式捕获原 rc 并拒绝非 0**（防 `set +e; return 9`
#            绕过 set -e）。
#
# 判定（默认模式；全部满足才 PASS）:
#   · 8 个哈希输入存在；编译前/运行后各 sha256（rc0/条数=8/逐行 64-hex），且 cmp 一致；
#     （6 编译输入 + env + 执行脚本自身；aux 三者另在 source 前后与默认尾部复检）
#   · 在**实际 DUT_ROOT 的 cwd 子 shell** 内编译，只给快照自身 -I（不含活 REPO_ROOT），
#     源/TB/产物全绝对路径；rc=0 且 vvp 非空；超时/非零即失败；
#   · 运行 rc=0、日志非空；日志不得出现 `FAIL`/`DEFECT`；
#   · `CT SPEC total=12 checks=50` 恰 1 行且与脚本内**固定 12 项表**一致；
#     每向量 `CT VEC <i> name=<n> checks=<c> fails=0` 恰 12 行、编号 1..12 各 1 次、
#     name/checks 逐项等于固定表、checks>=1、fails=0、总和==50；
#   · 摘要 `FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=50 fails=0` 恰 1 行；
#   · 整行 `FUNCTIONAL_COUNTER_TIME: PASS` 恰 1 行且整份日志 PASS 子串恰 1 次。
#   失败分支只打印诊断计数与日志路径（不 tail 底层日志，避免泄漏 PASS 锚点），rc=1。
#   --self-test：日志判据夹具（真 spec 构造的 12 项正控 + 少检查/零补偿/错名/缺字段/
#                额外异号行/垃圾行/空/多/源-包-TB-env 变动等反证）+ 端到端反证
#                （缺头/坏 sha rc/零产物/运行失败/源变化/合法 stdout 后非 0/无捕获/
#                  fresh 子进程坏 hash 非空断言/跨 case 源快照不变）。
#
# 说明 : 不提供 --check-baseline：本包 TB 依赖 F1-B 新端口，冻结基线 201acf61 的
#        csr_file 无这些端口，无法用同一 TB 复跑；旧行为对照由 privilege/devices
#        既有包与 tb_csr_file 的 §P 覆盖（回归证据随交付给出）。
# 用法 : bash sim/functional/test_counter_time.sh [--self-test]
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
ENV_SH="${REPO_ROOT}/scripts/env.sh"   # 强绑定 actual 路径；无外部覆写（内部夹具用私有根副本）
TB="${REPO_ROOT}/sim/functional/tb_counter_time.sv"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

readonly SPEC_VECTORS=12
readonly SPEC_CHECKS=50
readonly N_HASH_EXPECTED=8
readonly ANCHOR='FUNCTIONAL_COUNTER_TIME: PASS'

# ---- 固定 12 项真 spec 表（ID / name / checks）；TB 的 CT SPEC + VEC 行须逐项一致 ----
declare -A VEC_NAME=(
    [1]=V1_alias_time          [2]=V2_write_wins_self   [3]=V3_older_write_younger
    [4]=V4_rmw_order           [5]=V5_carry64          [6]=V6_mcycle_lo_carry
    [7]=V7_mcycle_hi_count     [8]=V8_minstret_hi_older [9]=V9_mtime_time
    [10]=V10_mpp_warl          [11]=V11_pmp_lock       [12]=V12_counteren_tvm
)
declare -A VEC_CHK=(
    [1]=9 [2]=6 [3]=2 [4]=3 [5]=2 [6]=6 [7]=4 [8]=4 [9]=4 [10]=6 [11]=1 [12]=3
)

MODE="default"
case "${1:-}" in
    ""|--default|default) MODE="default" ;;
    --self-test|self-test) MODE="selftest" ;;
    -h|--help|help) printf '用法：%s [--self-test]\n' "$0"; exit 0 ;;
    *) die "未知参数：${1}（支持 --self-test / --help；无 --check-baseline，理由见头注）" ;;
esac
[ "$#" -le 1 ] || die "参数过多：$*"

#------------------------------------------------------------------------------
# 环境：显式捕获 source 原 rc（防 sourced 文件 set +e; return 9 绕过 set -e）
#------------------------------------------------------------------------------
# ---- aux 身份：严格单行 64-hex；每 caller 显式 || die/fail（不吞错）----
aux_sha() {
    local f="$1" out n
    out="$(sha256sum -- "$f" 2>/dev/null)" || return $?
    n="$(printf '%s\n' "$out" | wc -l)"
    [ "$n" -eq 1 ] || return 90
    printf '%s\n' "$out" | grep -qE '^[0-9a-f]{64}  ' || return 91
    printf '%s' "${out:0:64}"
}
aux_start_recheck() {   # <where>：三者必须仍等于 source 前起始
    local where="$1" a b c
    a="$(aux_sha "$AUX_SCRIPT")" || die "aux sha(script) 复检失败 @${where}"
    b="$(aux_sha "$AUX_TB")"     || die "aux sha(tb) 复检失败 @${where}"
    c="$(aux_sha "$AUX_ENV")"    || die "aux sha(env) 复检失败 @${where}"
    [ "$a" = "$AUX_SCRIPT0" ] || die "script 在 source 期间变化 @${where}"
    [ "$b" = "$AUX_TB0" ]     || die "TB 在 source 期间变化 @${where}"
    [ "$c" = "$AUX_ENV0" ]    || die "env 在 source 期间变化 @${where}"
}
aux_live_ok() {         # selftest 每 case/末尾：活 aux 仍等起始
    local a b c
    a="$(aux_sha "$AUX_SCRIPT")" || return 1
    b="$(aux_sha "$AUX_TB")"     || return 1
    c="$(aux_sha "$AUX_ENV")"    || return 1
    [ "$a" = "$AUX_SCRIPT0" ] && [ "$b" = "$AUX_TB0" ] && [ "$c" = "$AUX_ENV0" ]
}

[ -r "$ENV_SH" ] || die "缺少 ${ENV_SH}（工具链环境真源）"
[ -r "$TB" ] || die "缺少功能 TB：${TB}"
command -v sha256sum >/dev/null 2>&1 || die "未找到 sha256sum（coreutils）"
AUX_SCRIPT="$SCRIPT_PATH"; AUX_TB="$TB"; AUX_ENV="$ENV_SH"
AUX_SCRIPT0="$(aux_sha "$AUX_SCRIPT")" || die "aux 起始 sha(script) 失败 rc=$?"
AUX_TB0="$(aux_sha "$AUX_TB")"         || die "aux 起始 sha(tb) 失败 rc=$?"
AUX_ENV0="$(aux_sha "$AUX_ENV")"       || die "aux 起始 sha(env) 失败 rc=$?"
ENV_RC=0
set +e
# shellcheck source=../../scripts/env.sh
. "$ENV_SH"
ENV_RC=$?
set -e
[ "$ENV_RC" -eq 0 ] || die "source ${ENV_SH} 返回非零 rc=${ENV_RC}（拒绝继续，防工具已就绪后假成功）"
aux_start_recheck "after-source"

AUTH_ROOT="$(realpath -m -- "${REPO_ROOT}/build/functional")"
command -v realpath >/dev/null 2>&1 || die "未找到 realpath（coreutils）"
is_authorized() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }

#------------------------------------------------------------------------------
# 产物根：规范化 → 授权 → mkdir → 再校验 → 总是 mktemp 独占
#------------------------------------------------------------------------------
resolve_root() {
    local raw="${RV32_FUNCTIONAL_PKG_OUT_DIR:-}" cand
    if [ -n "$raw" ]; then
        case "$raw" in /*) cand="$raw" ;; *) cand="${REPO_ROOT}/${raw}" ;; esac
    else
        cand="${AUTH_ROOT}/counter-time"
    fi
    cand="$(realpath -m -- "$cand")" || die "无法规范化产物根：${raw:-$cand}"
    is_authorized "$cand" || die "产物根不在授权树 ${AUTH_ROOT} 之下：${cand}"
    mkdir -p -- "$cand" || die "无法创建产物根：${cand}"
    cand="$(realpath -m -- "$cand")" || die "产物根再规范化失败：${cand}"
    is_authorized "$cand" || die "产物根 mkdir 后逃出授权树：${cand}"
    printf '%s' "$cand"
}

IV="${RV32_IVERILOG:-}"
VVP="${RV32_VVP:-}"
CASE_COMPILE_TIMEOUT="${CASE_COMPILE_TIMEOUT:-300}"
CASE_RUN_TIMEOUT="${CASE_RUN_TIMEOUT:-300}"

need_sim_tools() {
    [ -n "$IV" ]  && [ -x "$IV" ]  || die "未找到 iverilog（RV32_IVERILOG）"
    [ -n "$VVP" ] && [ -x "$VVP" ] || die "未找到 vvp（RV32_VVP）"
    command -v timeout >/dev/null 2>&1 || die "未找到 timeout（coreutils）"
}

abs_cmd() {
    local c="$1" r
    case "$c" in /*) printf '%s' "$c"; return 0 ;; esac
    if r="$(command -v -- "$c" 2>/dev/null)" && [ -n "$r" ]; then
        case "$r" in /*) printf '%s' "$r"; return 0 ;; esac
        printf '%s/%s' "$PWD" "$r"; return 0
    fi
    printf '%s' "$c"
}

DUT_REL_LIST=( rtl/csr/csr_file.v rtl/csr/priv_ctrl.v rtl/clint/clint.v )
DUT_HDR_REL_LIST=( rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh )

hash_inputs() {   # <out> <files...> → HASH_RC/HASH_LINES/HASH_BADHEX
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

#------------------------------------------------------------------------------
# 编译 + 运行（工具可用第 3/4 参覆盖，供 --self-test 注入）
#   · CASE_INPUTS  : 实际 6 个编译输入（3 RTL + 2 头 + TB）
#   · CASE_HASH_FILES : 上述 6 项 + env + 执行脚本自身 = 8 项（后两者只哈希、不进 iverilog）
#------------------------------------------------------------------------------
case_compile() {
    local name="$1" root="$2" iv="${3:-$IV}" vv="${4:-$VVP}"
    # ★ 入口先把全部结果置明确失败 sentinel（任何 early return 前生效）
    CASE_COMPILE_RC=255; CASE_VVP_OK=0; CASE_HASH_RC=255
    CASE_HASH_LINES=0; CASE_HASH_BADHEX=0; CASE_HASH_CHANGED=0; CASE_RUN_RC=255
    CASE_DIR="${RUN_DIR}/${name}"
    mkdir -p -- "$CASE_DIR"
    CASE_CLOG="${CASE_DIR}/compile.log"
    CASE_RLOG="${CASE_DIR}/run.log"
    CASE_HASH="${CASE_DIR}/inputs_before.sha256"
    CASE_HASH_BEFORE="$CASE_HASH"
    CASE_HASH_AFTER="${CASE_DIR}/inputs_after.sha256"
    CASE_VVP="${CASE_DIR}/${name}.vvp"
    CASE_INPUTS=( "$root/rtl/csr/csr_file.v" "$root/rtl/csr/priv_ctrl.v"
                  "$root/rtl/clint/clint.v"
                  "$root/rtl/pkg/rv32_defs.vh" "$root/rtl/pkg/core_params.vh"
                  "$TB" )
    CASE_HASH_FILES=( "${CASE_INPUTS[@]}" "$ENV_SH" "$SCRIPT_PATH" )
    local f
    for f in "${CASE_HASH_FILES[@]}"; do
        [ -f "$f" ] || { CASE_COMPILE_RC=96; return 0; }
    done
    CASE_COMPILE_RC=0
    hash_inputs "$CASE_HASH_BEFORE" "${CASE_HASH_FILES[@]}"
    CASE_HASH_RC="$HASH_RC"; CASE_HASH_LINES="$HASH_LINES"; CASE_HASH_BADHEX="$HASH_BADHEX"
    [ "$CASE_HASH_RC" -eq 0 ] || return 0
    local iv_abs vv_abs
    iv_abs="$(abs_cmd "$iv")"; vv_abs="$(abs_cmd "$vv")"
    ( cd "$root" && timeout "$CASE_COMPILE_TIMEOUT" "$iv_abs" -g2012 \
        -I "$root" -I "$root/rtl/pkg" \
        -o "$CASE_VVP" -s tb_counter_time \
        "${CASE_INPUTS[@]}" ) >"$CASE_CLOG" 2>&1 || CASE_COMPILE_RC=$?
    if [ "$CASE_COMPILE_RC" -eq 0 ]; then
        if [ -s "$CASE_VVP" ]; then CASE_VVP_OK=1; else CASE_COMPILE_RC=98; fi
    fi
    [ "$CASE_COMPILE_RC" -eq 0 ] || return 0
    CASE_RUN_RC=0
    timeout "$CASE_RUN_TIMEOUT" "$vv_abs" "$CASE_VVP" >"$CASE_RLOG" 2>&1 || CASE_RUN_RC=$?
    hash_inputs "$CASE_HASH_AFTER" "${CASE_HASH_FILES[@]}"
    if [ "$HASH_RC" -ne 0 ]; then
        CASE_HASH_RC="$HASH_RC"
    elif ! cmp -s -- "$CASE_HASH_BEFORE" "$CASE_HASH_AFTER"; then
        CASE_HASH_RC=95; CASE_HASH_CHANGED=1
    fi
}

#------------------------------------------------------------------------------
# 正向门控：CT SPEC + 固定 12 项表 + 摘要 + 锚点
#------------------------------------------------------------------------------
gate_positive_log() {
    local log="$1" rc="$2" spec vsum
    G_ERR=0; G_REASON="ok"
    G_CAPTURE=0; G_ANCHOR=0; G_PASSOCC=0; G_FAILLINES=0; G_DEFECTLINES=0
    G_SUMCNT=0; G_TOTAL="-"; G_CHECKS="-"; G_FAILS="-"
    G_SPECCNT=0; G_SPECTOTAL="-"; G_SPECCHECKS="-"
    G_VECN=0; G_VECSUM=0; G_VECBAD=0; G_VECZERO=0; G_VECFAIL=0
    G_VECNAME=0; G_VECCHK=0; G_VECDUPE=0; G_VECMISS=0
    [ -s "$log" ] && G_CAPTURE=1
    [ "$G_CAPTURE" -eq 1 ] || { G_ERR=1; G_REASON="no_capture"; return 1; }
    [ "$rc" -eq 0 ] || { G_ERR=1; G_REASON="rc=$rc"; return 1; }
    G_FAILLINES="$(grep -c 'FAIL' "$log" 2>/dev/null || true)"; G_FAILLINES="${G_FAILLINES:-0}"
    G_DEFECTLINES="$(grep -c 'DEFECT' "$log" 2>/dev/null || true)"; G_DEFECTLINES="${G_DEFECTLINES:-0}"
    [ "$G_FAILLINES" -eq 0 ] || { G_ERR=1; G_REASON="log_has_FAIL=$G_FAILLINES"; return 1; }
    [ "$G_DEFECTLINES" -eq 0 ] || { G_ERR=1; G_REASON="log_has_DEFECT=$G_DEFECTLINES"; return 1; }
    # ---- CT SPEC：TB 自报的 (12,50) 必须与脚本内固定表完全一致 ----
    G_SPECCNT="$(grep -c '^CT SPEC ' "$log" 2>/dev/null || true)"; G_SPECCNT="${G_SPECCNT:-0}"
    [ "$G_SPECCNT" -eq 1 ] || { G_ERR=1; G_REASON="spec_count=$G_SPECCNT"; return 1; }
    spec="$(grep -m1 '^CT SPEC ' "$log" 2>/dev/null || true)"
    if [[ "$spec" =~ ^CT\ SPEC\ total=([0-9]+)\ checks=([0-9]+)$ ]]; then
        G_SPECTOTAL="${BASH_REMATCH[1]}"; G_SPECCHECKS="${BASH_REMATCH[2]}"
    else
        G_ERR=1; G_REASON="spec_format"; return 1
    fi
    [ "$G_SPECTOTAL" -eq "$SPEC_VECTORS" ] || { G_ERR=1; G_REASON="spec_total=$G_SPECTOTAL"; return 1; }
    [ "$G_SPECCHECKS" -eq "$SPEC_CHECKS" ] || { G_ERR=1; G_REASON="spec_checks=$G_SPECCHECKS"; return 1; }
    # ---- 逐向量：ID/name/checks 逐项等于固定表 ----
    local idx name chk fl i
    local -A seen
    seen=()
    while read -r idx name chk fl; do
        if [ "$idx" = "BAD" ]; then G_VECBAD=$((G_VECBAD+1)); continue; fi
        G_VECN=$((G_VECN+1))
        G_VECSUM=$((G_VECSUM+chk))
        [ "$fl" -eq 0 ]  || G_VECFAIL=$((G_VECFAIL+1))
        [ "$chk" -ge 1 ] || G_VECZERO=$((G_VECZERO+1))
        if [ "${VEC_NAME[$idx]+x}" != "x" ] || [ "${VEC_NAME[$idx]}" != "$name" ]; then
            G_VECNAME=$((G_VECNAME+1))
        fi
        if [ "${VEC_CHK[$idx]:-0}" -ne "$chk" ]; then G_VECCHK=$((G_VECCHK+1)); fi
        if [ -n "${seen[$idx]:-}" ]; then G_VECDUPE=$((G_VECDUPE+1)); else seen["$idx"]=1; fi
    done < <(awk '
        /^CT VEC / {
            if ($0 ~ /^CT VEC [0-9]+ name=[A-Za-z0-9_]+ checks=[0-9]+ fails=[0-9]+$/) {
                name=$4; chk=$5; fl=$6
                sub("^name=", "", name); sub("^checks=", "", chk); sub("^fails=", "", fl)
                print $3, name, chk, fl
            } else print "BAD BAD BAD BAD"
        }' "$log")
    for ((i = 1; i <= SPEC_VECTORS; i = i + 1)); do
        [ -n "${seen[$i]:-}" ] || G_VECMISS=$((G_VECMISS+1))
    done
    [ "$G_VECBAD"   -eq 0 ] || { G_ERR=1; G_REASON="vec_format_bad=$G_VECBAD"; return 1; }
    [ "$G_VECN"     -eq "$SPEC_VECTORS" ] || { G_ERR=1; G_REASON="vec_count=$G_VECN"; return 1; }
    [ "$G_VECZERO"  -eq 0 ] || { G_ERR=1; G_REASON="vec_checks_zero=$G_VECZERO"; return 1; }
    [ "$G_VECFAIL"  -eq 0 ] || { G_ERR=1; G_REASON="vec_fails=$G_VECFAIL"; return 1; }
    [ "$G_VECNAME"  -eq 0 ] || { G_ERR=1; G_REASON="vec_name_mismatch=$G_VECNAME"; return 1; }
    [ "$G_VECCHK"   -eq 0 ] || { G_ERR=1; G_REASON="vec_checks_mismatch=$G_VECCHK"; return 1; }
    [ "$G_VECDUPE"  -eq 0 ] || { G_ERR=1; G_REASON="vec_dup_idx=$G_VECDUPE"; return 1; }
    [ "$G_VECMISS"  -eq 0 ] || { G_ERR=1; G_REASON="vec_missing_idx=$G_VECMISS"; return 1; }
    [ "$G_VECSUM"   -eq "$SPEC_CHECKS" ] || { G_ERR=1; G_REASON="vec_sum=$G_VECSUM"; return 1; }
    # ---- 摘要 ----
    G_SUMCNT="$(grep -c '^FUNCTIONAL_COUNTER_TIME_VECTORS ' "$log" 2>/dev/null || true)"; G_SUMCNT="${G_SUMCNT:-0}"
    [ "$G_SUMCNT" -eq 1 ] || { G_ERR=1; G_REASON="summary_count=$G_SUMCNT"; return 1; }
    vsum="$(grep -m1 '^FUNCTIONAL_COUNTER_TIME_VECTORS ' "$log" 2>/dev/null || true)"
    if [[ "$vsum" =~ ^FUNCTIONAL_COUNTER_TIME_VECTORS\ total=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)$ ]]; then
        G_TOTAL="${BASH_REMATCH[1]}"; G_CHECKS="${BASH_REMATCH[2]}"; G_FAILS="${BASH_REMATCH[3]}"
    else
        G_ERR=1; G_REASON="summary_format"; return 1
    fi
    [ "$G_TOTAL" -eq "$SPEC_VECTORS" ] || { G_ERR=1; G_REASON="summary_total=$G_TOTAL"; return 1; }
    [ "$G_CHECKS" -eq "$SPEC_CHECKS" ] || { G_ERR=1; G_REASON="summary_checks=$G_CHECKS"; return 1; }
    [ "$G_FAILS" -eq 0 ] || { G_ERR=1; G_REASON="summary_fails=$G_FAILS"; return 1; }
    # ---- 锚点 ----
    G_ANCHOR="$(grep -cxF "$ANCHOR" "$log" 2>/dev/null || true)"; G_ANCHOR="${G_ANCHOR:-0}"
    G_PASSOCC="$( { grep -o 'PASS' "$log" 2>/dev/null || true; } | wc -l )"; G_PASSOCC="${G_PASSOCC:-0}"
    [ "$G_ANCHOR"  -eq 1 ] || { G_ERR=1; G_REASON="pass_anchor_count=$G_ANCHOR"; return 1; }
    [ "$G_PASSOCC" -eq 1 ] || { G_ERR=1; G_REASON="pass_substr=$G_PASSOCC"; return 1; }
    return 0
}

run_positive_case() {
    case_compile current "$DUT_ROOT"
    P_COMPILE_RC="$CASE_COMPILE_RC"; P_VVP_OK="$CASE_VVP_OK"
    P_HASH_RC="$CASE_HASH_RC"; P_HASH_LINES="$CASE_HASH_LINES"; P_HASH_BADHEX="$CASE_HASH_BADHEX"
    P_HASH_CHANGED="$CASE_HASH_CHANGED"; P_RUN_RC="$CASE_RUN_RC"
    P_LOG="$CASE_RLOG"; P_CLOG="$CASE_CLOG"; P_DIR="$CASE_DIR"; P_HASH="$CASE_HASH"
    P_TOTAL="-"; P_CHECKS="-"; P_FAILS="-"; P_ANCHOR=0; P_VECN=0; P_PASSOCC=0
    if [ "$P_COMPILE_RC" -ne 0 ]; then P_ERR=1; P_REASON="compile_rc=$P_COMPILE_RC vvp_ok=$P_VVP_OK"; return 1; fi
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
    printf 'counter-time: POSITIVE_CHECK_FAILED reason=%s compile_rc=%s vvp_ok=%s hash_rc=%s hash_lines=%s hash_badhex=%s run_rc=%s total=%s checks=%s fails=%s vec_lines=%s\n' \
           "$P_REASON" "$P_COMPILE_RC" "$P_VVP_OK" "$P_HASH_RC" "$P_HASH_LINES" \
           "${P_HASH_BADHEX:-0}" "$P_RUN_RC" "$P_TOTAL" "$P_CHECKS" "$P_FAILS" "$P_VECN"
    printf 'counter-time: compile_log=%s run_log=%s\n' "${P_CLOG:-<none>}" "${P_LOG:-<none>}"
}

#==============================================================================
# --self-test
#==============================================================================
selftest_main() {
    local st_dir
    mkdir -p "${AUTH_ROOT}/counter-time"
    st_dir="$(mktemp -d "${AUTH_ROOT}/counter-time/selftest.XXXXXXXX")"
    local pass=0 total=0

    mk_good_log() {
        local out="$1" i
        : > "$out"
        printf 'CT SPEC total=%d checks=%d\n' "$SPEC_VECTORS" "$SPEC_CHECKS" >> "$out"
        for ((i = 1; i <= SPEC_VECTORS; i = i + 1)); do
            printf 'CT VEC %d name=%s checks=%d fails=0\n' "$i" "${VEC_NAME[$i]}" "${VEC_CHK[$i]}" >> "$out"
        done
        printf 'FUNCTIONAL_COUNTER_TIME_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$SPEC_CHECKS" >> "$out"
        printf '%s\n' "$ANCHOR" >> "$out"
    }
    run_gate_case() {
        local name="$1" expect="$2" log="$3" rc="$4" got
        total=$((total + 1))
        if gate_positive_log "$log" "$rc"; then got=pass; else got=reject; fi
        if [ "$got" = "$expect" ]; then pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-6s got=%-6s OK\n' "$name" "$expect" "$got"
        else printf 'SELFTEST %-26s expected=%-6s got=%-6s MISMATCH reason=%s\n' "$name" "$expect" "$got" "$G_REASON"; fi
    }

    mk_good_log "${st_dir}/good.log"
    # ---- 固定表/逐项反证（全部由真 spec 正控派生）----
    sed 's/^CT VEC 6 \(.*\) checks=6 fails=0$/CT VEC 6 \1 checks=5 fails=0/' \
        "${st_dir}/good.log" > "${st_dir}/fewer_checks.log"
    sed -e 's/^CT VEC 6 \(.*\) checks=6 fails=0$/CT VEC 6 \1 checks=5 fails=0/' \
        -e 's/^CT VEC 7 \(.*\) checks=4 fails=0$/CT VEC 7 \1 checks=5 fails=0/' \
        "${st_dir}/good.log" > "${st_dir}/zero_comp.log"
    sed 's/^CT VEC 6 name=[^ ]*/CT VEC 6 name=V6_wrong_name/' "${st_dir}/good.log" > "${st_dir}/wrong_name.log"
    sed 's/^CT VEC 6 name=[^ ]* //' "${st_dir}/good.log" > "${st_dir}/missing_field.log"
    sed 's/^CT VEC 6 \(.*\) fails=0$/CT VEC 6 \1 fails=1/' "${st_dir}/good.log" > "${st_dir}/vec_fails.log"
    sed 's/^CT VEC 6 \(.*\) checks=6 fails=0$/CT VEC 6 \1 checks=0 fails=0/' "${st_dir}/good.log" > "${st_dir}/vec_zero.log"
    #   ★ 12×1 攻击：SPEC 仍报 50、摘要报 12，靠"总量"蒙混 ⇒ 逐项表必须判红
    { printf 'CT SPEC total=%d checks=%d\n' "$SPEC_VECTORS" "$SPEC_CHECKS"
      for ((i = 1; i <= SPEC_VECTORS; i = i + 1)); do
          printf 'CT VEC %d name=%s checks=1 fails=0\n' "$i" "${VEC_NAME[$i]}"
      done
      printf 'FUNCTIONAL_COUNTER_TIME_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$SPEC_VECTORS"
      printf '%s\n' "$ANCHOR"
    } > "${st_dir}/all_ones.log"
    grep -v '^CT VEC 12 ' "${st_dir}/good.log" > "${st_dir}/vec_missing.log" || true
    sed 's/^CT VEC 12 /CT VEC 11 /' "${st_dir}/good.log" > "${st_dir}/vec_dup.log"
    { cat "${st_dir}/good.log"; printf 'CT VEC 13 name=V13_extra checks=1 fails=0\n'; } > "${st_dir}/vec_extra.log"
    { cat "${st_dir}/good.log"; printf 'CT VEC 3 name=V3_older_write_younger checks=1 fails=0 junk\n'; } > "${st_dir}/garbage_line.log"
    sed 's/^CT SPEC total=12 checks=50$/CT SPEC total=12 checks=49/' "${st_dir}/good.log" > "${st_dir}/spec_checks.log"
    sed 's/^CT SPEC total=12 checks=50$/CT SPEC total=11 checks=50/' "${st_dir}/good.log" > "${st_dir}/spec_total.log"
    sed 's/^FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=50 fails=0$/FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=49 fails=0/' \
        "${st_dir}/good.log" > "${st_dir}/summary_checks.log"
    sed 's/^FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=50 fails=0$/FUNCTIONAL_COUNTER_TIME_VECTORS total=11 checks=50 fails=0/' \
        "${st_dir}/good.log" > "${st_dir}/summary_total.log"
    sed 's/^FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=50 fails=0$/FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=50 fails=1/' \
        "${st_dir}/good.log" > "${st_dir}/summary_fails.log"
    grep -v "^${ANCHOR}$" "${st_dir}/good.log" > "${st_dir}/no_anchor.log" || true
    cp "${st_dir}/good.log" "${st_dir}/dup_anchor.log"; printf '%s\n' "$ANCHOR" >> "${st_dir}/dup_anchor.log"
    grep -v '^FUNCTIONAL_COUNTER_TIME_VECTORS ' "${st_dir}/good.log" > "${st_dir}/no_summary.log" || true
    cp "${st_dir}/good.log" "${st_dir}/dup_summary.log"
    grep '^FUNCTIONAL_COUNTER_TIME_VECTORS ' "${st_dir}/good.log" >> "${st_dir}/dup_summary.log"
    sed 's/^CT VEC 3 \(.*\) fails=0$/X FAIL [T]: x/' "${st_dir}/good.log" > "${st_dir}/has_fail.log"
    sed 's/^CT VEC 3 \(.*\) fails=0$/DEFECT_REPRODUCED: X/' "${st_dir}/good.log" > "${st_dir}/has_defect.log"
    : > "${st_dir}/empty.log"

    run_gate_case good                   pass   "${st_dir}/good.log"            0
    run_gate_case fewer_checks           reject "${st_dir}/fewer_checks.log"    0
    run_gate_case zero_comp              reject "${st_dir}/zero_comp.log"       0
    run_gate_case all_ones               reject "${st_dir}/all_ones.log"        0
    run_gate_case wrong_name             reject "${st_dir}/wrong_name.log"      0
    run_gate_case missing_field          reject "${st_dir}/missing_field.log"   0
    run_gate_case vec_fails              reject "${st_dir}/vec_fails.log"       0
    run_gate_case vec_zero               reject "${st_dir}/vec_zero.log"        0
    run_gate_case vec_missing            reject "${st_dir}/vec_missing.log"     0
    run_gate_case vec_dup                reject "${st_dir}/vec_dup.log"         0
    run_gate_case vec_extra              reject "${st_dir}/vec_extra.log"       0
    run_gate_case garbage_line           reject "${st_dir}/garbage_line.log"    0
    run_gate_case spec_checks            reject "${st_dir}/spec_checks.log"     0
    run_gate_case spec_total             reject "${st_dir}/spec_total.log"      0
    run_gate_case summary_checks         reject "${st_dir}/summary_checks.log"  0
    run_gate_case summary_total          reject "${st_dir}/summary_total.log"   0
    run_gate_case summary_fails          reject "${st_dir}/summary_fails.log"   0
    run_gate_case no_anchor              reject "${st_dir}/no_anchor.log"       0
    run_gate_case dup_anchor             reject "${st_dir}/dup_anchor.log"      0
    run_gate_case no_summary             reject "${st_dir}/no_summary.log"      0
    run_gate_case dup_summary            reject "${st_dir}/dup_summary.log"     0
    run_gate_case has_fail               reject "${st_dir}/has_fail.log"        0
    run_gate_case has_defect             reject "${st_dir}/has_defect.log"      0
    run_gate_case empty_capture          reject "${st_dir}/empty.log"           0
    run_gate_case missing_file           reject "${st_dir}/nope.log"            0
    run_gate_case timeout_rc             reject "${st_dir}/good.log"            124
    run_gate_case nonzero_rc             reject "${st_dir}/good.log"            1

    # ---- 端到端反证（真实走 case_compile/hash/gate）----
    local e2e="$st_dir/e2e" fb="$st_dir/fakebin"
    mkdir -p "$e2e" "$fb"
    local sb="$e2e/src_ok"
    mkdir -p "$sb/rtl/csr" "$sb/rtl/pkg" "$sb/rtl/clint" || die "selftest: mkdir sb 失败"
    cp -f "$REPO_ROOT/rtl/csr/csr_file.v" "$REPO_ROOT/rtl/csr/priv_ctrl.v" "$sb/rtl/csr/" || die "selftest: cp rtl/csr 失败"
    cp -f "$REPO_ROOT/rtl/clint/clint.v" "$sb/rtl/clint/" || die "selftest: cp rtl/clint 失败"
    cp -f "$REPO_ROOT/rtl/pkg/rv32_defs.vh" "$REPO_ROOT/rtl/pkg/core_params.vh" "$sb/rtl/pkg/" || die "selftest: cp rtl/pkg 失败"
    export GOODLOG="${st_dir}/good.log"
    export MUTATE_PATH=""

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
    cat > "$fb/vvp_fail" <<'EOS'
#!/bin/sh
exit 1
EOS
    cat > "$fb/vvp_quiet" <<'EOS'
#!/bin/sh
exit 0
EOS
    cat > "$fb/vvp_goodlog_rc1" <<'EOS'
#!/bin/sh
cat "$GOODLOG"
exit 1
EOS
    cat > "$fb/vvp_mutate" <<'EOS'
#!/bin/sh
printf '\n/* mutated during run */\n' >> "$MUTATE_PATH"
exit 0
EOS
    local REAL_SHA; REAL_SHA="$(command -v sha256sum)" || die "selftest: 无 sha256sum"
    cat > "$fb/sha_fail" <<EOS
#!/bin/sh
case "\$*" in *csr_file.v*) exit 9 ;; esac
exec ${REAL_SHA} "\$@"
EOS
    chmod +x "$fb"/* || die "selftest: chmod 假工具失败"
    mkdir -p "$e2e/p_rc"; cp -f "$fb/sha_fail" "$e2e/p_rc/sha256sum"; chmod +x "$e2e/p_rc/sha256sum"

    priv_root() {  # <dir>：私有 aux 根（脚本/TB/env 均为副本，绝不动正式源）
        local d="$1"
        rm -rf "$d" || return 1
        mkdir -p "$d/rtl/csr" "$d/rtl/clint" "$d/rtl/pkg" \
                 "$d/sim/functional" "$d/scripts/functional" || return 1
        cp -f "$REPO_ROOT/rtl/csr/csr_file.v" "$REPO_ROOT/rtl/csr/priv_ctrl.v" "$d/rtl/csr/" || return 1
        cp -f "$REPO_ROOT/rtl/clint/clint.v" "$d/rtl/clint/" || return 1
        cp -f "$REPO_ROOT/rtl/pkg/rv32_defs.vh" "$REPO_ROOT/rtl/pkg/core_params.vh" "$d/rtl/pkg/" || return 1
        cp -f "$REPO_ROOT/sim/functional/tb_counter_time.sv" "$d/sim/functional/" || return 1
        cp -f "$REPO_ROOT/scripts/env.sh" "$d/scripts/env.sh" || return 1
        cp -f "$SCRIPT_PATH" "$d/scripts/functional/test_counter_time.sh" || return 1
        chmod +x "$d/scripts/functional/test_counter_time.sh" || return 1
    }

    e2e_case() {   # <名称> <期望> <iverilog> <vvp> <root> [PATH前缀]
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
        aux_live_ok || got="${got}+AUX_LIVE_CHANGED"
        total=$((total + 1))
        if [ "$got" = "$expect" ]; then pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' "$name" "$expect" "$got"
        else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' "$name" "$expect" "$got"; fi
    }
    mutate_case() {  # <名称> <期望> <sandbox 相对路径>
        local name="$1" expect="$2" rel="$3"
        local sbx="$e2e/src_${name}"
        rm -rf "$sbx"; cp -a "$sb" "$sbx" || die "selftest: cp -a sb 失败"
        MUTATE_PATH="$sbx/$rel" e2e_case "$name" "$expect" "$fb/iverilog_ok" "$fb/vvp_mutate" "$sbx"
    }
    inner_case() {  # <名称> <私有根> <期望 reason> <iverilog> <vvp> <变异路径>
        local name="$1" root="$2" reason="$3" iv="$4" vv="$5" mut="$6"
        local out="$e2e/inner_${name}.out" irc=0 got
        set +e
        #   ★ 递归 caller 必须显式钉住私有根的 PKGOUT：否则继承母 repo 的绝对路径
        #     （其 AUTH_ROOT 是母 build/functional，本私有根不在其下）⇒ 先"越授权根"失败，
        #     掩盖 hash_changed 精准 reason。
        DUT_ROOT="$root" RV32_IVERILOG="$iv" RV32_VVP="$vv" MUTATE_PATH="$mut" \
            RV32_FUNCTIONAL_PKG_OUT_DIR="$root/build/functional/counter-time" \
            bash "$root/scripts/functional/test_counter_time.sh" > "$out" 2>&1
        irc=$?
        set -e
        got="rc=$irc"
        aux_live_ok || got="${got}+AUX_LIVE_CHANGED"
        total=$((total + 1))
        if [ "$irc" -eq 1 ] && [ -s "$out" ] && grep -q "$reason" "$out" \
           && ! grep -qxF "$ANCHOR" "$out" && [ "$got" = "rc=1" ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' "$name" "$reason" "rc=1"
        else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' "$name" "$reason" "$got"; fi
    }

    RUN_DIR="$e2e/run_pos"
    if case_compile pos "$sb" "$IV" "$VVP" && gate_positive_log "$CASE_RLOG" "$CASE_RUN_RC" && aux_live_ok; then
        total=$((total + 1)); pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_positive_control pass pass
    else
        total=$((total + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH reason=%s\n' e2e_positive_control pass reject "$G_REASON"
    fi
    #   8 项哈希冻结（6 编译 + env + 执行脚本自身）
    total=$((total + 1))
    if [ "$(wc -l < "$e2e/run_pos/pos/inputs_before.sha256")" -eq "$N_HASH_EXPECTED" ] \
       && grep -q 'env\.sh$' "$e2e/run_pos/pos/inputs_before.sha256" \
       && grep -q 'test_counter_time\.sh$' "$e2e/run_pos/pos/inputs_before.sha256"; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_hash_matrix_8 pass pass
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_hash_matrix_8 pass reject; fi

    local sb_nohdr="$e2e/src_nohdr"; rm -rf "$sb_nohdr"; cp -a "$sb" "$sb_nohdr" || die "selftest: cp nohdr 失败"
    rm -f "$sb_nohdr/rtl/pkg/rv32_defs.vh"
    e2e_case e2e_missing_header "compile_rc=96" "$fb/iverilog_ok" "$fb/vvp_quiet" "$sb_nohdr"
    total=$((total + 1))
    if [ "$CASE_RUN_RC" -eq 255 ] && [ "$CASE_HASH_RC" -eq 255 ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_sentinel_bound "run/hash=255" "run=255,hash=255"
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_sentinel_bound "run/hash=255" "run=$CASE_RUN_RC,hash=$CASE_HASH_RC"; fi
    e2e_case e2e_zero_vvp "compile_rc=98" "$fb/iverilog_zero" "$fb/vvp_quiet" "$sb"
    e2e_case e2e_hash_rc  "hash_rc=9"    "$fb/iverilog_ok"   "$fb/vvp_quiet" "$sb" "$e2e/p_rc"
    e2e_case e2e_run_fail "run_rc=1"     "$fb/iverilog_ok"   "$fb/vvp_fail"  "$sb"

    #   ---- 源/头文件变异（共享 sandbox 副本，各自私有）----
    mutate_case e2e_src_changed    "hash_rc=95" "rtl/csr/csr_file.v"
    mutate_case e2e_header_changed "hash_rc=95" "rtl/pkg/rv32_defs.vh"

    #   ---- 真 aux 变异：私有根副本（TB/env/脚本自身），不碰正式源 ----
    local pr
    pr="$e2e/priv_tb"; priv_root "$pr" || die "selftest: priv_root(tb) 失败"
    inner_case e2e_tb_changed "$pr" "hash_changed_during_run" "$fb/iverilog_ok" "$fb/vvp_mutate" "$pr/sim/functional/tb_counter_time.sv"
    pr="$e2e/priv_env"; priv_root "$pr" || die "selftest: priv_root(env) 失败"
    inner_case e2e_env_changed "$pr" "hash_changed_during_run" "$fb/iverilog_ok" "$fb/vvp_mutate" "$pr/scripts/env.sh"
    pr="$e2e/priv_self"; priv_root "$pr" || die "selftest: priv_root(self) 失败"
    inner_case e2e_self_script_changed "$pr" "hash_changed_during_run" "$fb/iverilog_ok" "$fb/vvp_mutate" "$pr/scripts/functional/test_counter_time.sh"
    pr="$e2e/priv_envself"; priv_root "$pr" || die "selftest: priv_root(envself) 失败"
    printf 'printf "\\n# selfmod-during-source\\n" >> "${BASH_SOURCE[0]}"\n' >> "$pr/scripts/env.sh"
    inner_case e2e_env_selfmod "$pr" "env 在 source 期间变化" "$fb/iverilog_ok" "$fb/vvp_quiet" ""

    #   ---- 合法 stdout 后 rc=1：门控必须拒绝（不能只看日志）----
    RUN_DIR="$e2e/run_log_rc1"
    case_compile log_rc1 "$sb" "$fb/iverilog_ok" "$fb/vvp_goodlog_rc1"
    total=$((total + 1))
    if [ "$CASE_RUN_RC" -eq 1 ] && ! gate_positive_log "$CASE_RLOG" "$CASE_RUN_RC" && aux_live_ok; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_log_ok_rc1 reject reject
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_log_ok_rc1 reject pass; fi

    #   ---- 无捕获（vvp 静默）：门控必须拒绝，且 reason=no_capture ----
    RUN_DIR="$e2e/run_nocap"
    case_compile nocap "$sb" "$fb/iverilog_ok" "$fb/vvp_quiet"
    total=$((total + 1))
    if gate_positive_log "$CASE_RLOG" "$CASE_RUN_RC"; then
        printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_no_capture reject pass
    else pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK reason=%s\n' e2e_no_capture reject reject "$G_REASON"; fi

    #   ---- 末尾：活 aux（脚本/TB/env）必须仍等起始 ----
    total=$((total + 1))
    if aux_live_ok; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_aux_live_end pass pass
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_aux_live_end pass reject; fi

    #   ---- env 非零 rc 反证：`set +e; return 9` 不得绕过（必须 rc=1 并报 rc=9）----
    pr="$e2e/priv_envrc"; priv_root "$pr" || die "selftest: priv_root(envrc) 失败"
    cat > "$pr/scripts/env.sh" <<'EOS'
set +e
return 9
EOS
    inner_case e2e_env_rc9 "$pr" "返回非零 rc=9" "$fb/iverilog_ok" "$fb/vvp_quiet" ""

    #   ---- 父 PKGOUT 隔离：递归 inner 输出不得出现"越授权根" ----
    total=$((total + 1))
    local iok=1 if
    for if in tb_changed env_changed self_script_changed env_selfmod env_rc9; do
        [ -s "$e2e/inner_e2e_${if}.out" ] || iok=0
        grep -q '不在授权树' "$e2e/inner_e2e_${if}.out" 2>/dev/null && iok=0
    done
    if [ "$iok" -eq 1 ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' e2e_inner_root_isolated pass pass
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' e2e_inner_root_isolated pass reject; fi

    #   ---- fresh 子进程：坏 sha（仅 csr_file.v 触发）⇒ rc=1 + 非空 + reason + 无锚点 ----
    local src_rc=0 a=0 saved_path="$PATH" tmpout="$st_dir/fresh.out"
    PATH="$e2e/p_rc:$PATH"
    set +e
    DUT_ROOT="$sb" RV32_FUNCTIONAL_PKG_OUT_DIR="$e2e/fresh_out" \
        bash "$SCRIPT_PATH" > "$tmpout" 2>&1
    src_rc=$?
    set -e
    PATH="$saved_path"
    total=$((total + 1))
    a="$(grep -cxF "$ANCHOR" "$tmpout" || true)"; a="${a:-0}"
    if [ "$src_rc" -eq 1 ] && [ -s "$tmpout" ] && [ "$a" -eq 0 ] \
       && grep -q 'POSITIVE_CHECK_FAILED' "$tmpout" \
       && grep -q 'reason=hash_rc=9' "$tmpout" \
       && ! grep -qi 'unbound variable' "$tmpout"; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expected=%-14s got=%-14s OK\n' fresh_bad_hash "rc=1+reason" "rc=$src_rc"
    else printf 'SELFTEST %-26s expected=%-14s got=%-14s MISMATCH\n' fresh_bad_hash "rc=1+reason" "rc=$src_rc,anchor=$a,bytes=$(wc -c < "$tmpout")"; fi

    printf 'SELFTEST_FIXTURES: %s\n' "$st_dir"
    printf 'SELFTEST_TOTAL: %d/%d\n' "$pass" "$total"
    if [ "$pass" -eq "$total" ]; then printf 'SELFTEST_OK\n'; exit 0; fi
    printf 'SELFTEST_BAD: %d/%d\n' "$pass" "$total"
    exit 1
}

#==============================================================================
# 默认
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

    printf 'counter-time: run_dir=%s\n' "$RUN_DIR"
    printf 'counter-time: dut_root=%s tb=%s env=%s script=%s\n' "$DUT_ROOT" "$TB" "$ENV_SH" "$SCRIPT_PATH"
    if ! run_positive_case; then emit_pos_failure; exit 1; fi

    local h_csr h_priv h_clint h_defs h_par h_tb h_env
    h_csr="$(awk  '$2 ~ /csr_file\.v$/  {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_priv="$(awk '$2 ~ /priv_ctrl\.v$/ {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_clint="$(awk '$2 ~ /clint\.v$/    {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_defs="$(awk '$2 ~ /rv32_defs\.vh$/ {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_par="$(awk  '$2 ~ /core_params\.vh$/ {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_tb="$(awk   '$2 ~ /tb_counter_time\.sv$/ {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_env="$(awk  '$2 ~ /env\.sh$/ {print substr($1,1,12); exit}' "$P_HASH" || true)"
    h_scr="$(awk  '$2 ~ /test_counter_time\.sh$/ {print substr($1,1,12); exit}' "$P_HASH" || true)"
    printf 'counter-time: src_sha256 csr_file=%s priv_ctrl=%s clint=%s rv32_defs=%s core_params=%s tb=%s env=%s script=%s\n' \
           "${h_csr:-?}" "${h_priv:-?}" "${h_clint:-?}" "${h_defs:-?}" "${h_par:-?}" "${h_tb:-?}" "${h_env:-?}" "${h_scr:-?}"
    printf 'counter-time: compile_rc=%s vvp_ok=%s hash_lines=%s hash_badhex=%s run_rc=%s total=%s checks=%s fails=%s vec_lines=%s anchor_lines=%s pass_substr=%s\n' \
           "$P_COMPILE_RC" "$P_VVP_OK" "$P_HASH_LINES" "$P_HASH_BADHEX" "$P_RUN_RC" "$P_TOTAL" \
           "$P_CHECKS" "$P_FAILS" "$P_VECN" "$P_ANCHOR" "$P_PASSOCC"
    printf 'counter-time: log_dir=%s\n' "$P_DIR"
    aux_start_recheck "default-end"
    printf '%s\n' "$ANCHOR"
    exit 0
}

case "$MODE" in
    default)  default_main ;;
    selftest) selftest_main ;;
esac
