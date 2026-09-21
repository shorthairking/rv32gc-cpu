#!/usr/bin/env bash
#==============================================================================
# sw/m5_board/tb/ip/run_mdu_ip_xsim.sh —— xsim 跑 **mdu 的 IP 分支**（真实 div_gen/mult_gen）
#==============================================================================
# 目的：RTL 的 `RV32GC_USE_VIVADO_IP` 分支（= **板上实际跑的**分支）首次进入仿真闭环。
#   iverilog 不能编译 Vivado 的加密 IP 网表（M4 遗留 R3）⇒ 用 xsim（自带解密密钥）
#   + 预编译 `unisims_ver` 原语库 + `glbl`。
#
# 用法：bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh               # 期望全过（rc=0）
#       bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh --expect-fail # 修复前复现（期望有 FAIL，rc=0 表示"确实复现"）
#   环境：MDU_SRC=<路径>  覆盖被测 mdu.v（默认 rtl/exec/mdu.v）。
#         反证用本目录的 **修复前只读副本**（`git show HEAD:rtl/exec/mdu.v` 取出，md5 d96ed0ce…）：
#             MDU_SRC=sw/m5_board/tb/ip/mdu_prefix_ref.v bash .../run_mdu_ip_xsim.sh --expect-fail
#         全程**不修改 rtl/**（只读替换被测文件）。
# 产物：sw/m5_board/tb/ip/out/ 下：<mode>_mdu.log（mode = xsim 或 prefix，后者用于反证）
#        以及 tb_mdu_ip.<mode>.lines（TB_MDU_IP: 行的摘录）
# 纪律：只读 rtl/**、fpga/ip/**；只写本目录。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd -P)"        # <rv32gc-cpu>
IPDIR="${REPO}/fpga/ip"
OUT="${SCRIPT_DIR}/out"
XSIM_DIR="${SCRIPT_DIR}/xsim.dir"
EXPECT_FAIL=0
[ "${1:-}" = "--expect-fail" ] && EXPECT_FAIL=1
MDU_SRC="${MDU_SRC:-${REPO}/rtl/exec/mdu.v}"        # 被测 mdu.v（反证时指向修复前只读副本）
case "${MDU_SRC}" in /*) ;; *) MDU_SRC="${REPO}/${MDU_SRC}" ;; esac   # 相对路径按仓库根解析
mkdir -p "${OUT}" "${XSIM_DIR}"
cd "${SCRIPT_DIR}" || exit 2

# 真实 IP 网表（加密功能模型；xsim 可解密）
IP_SRCS=(
    "${IPDIR}/rv32_div/rv32_div_sim_netlist.v"
    "${IPDIR}/rv32_mult_signed/rv32_mult_signed_sim_netlist.v"
    "${IPDIR}/rv32_mult_su/rv32_mult_su_sim_netlist.v"
    "${IPDIR}/rv32_mult_unsigned/rv32_mult_unsigned_sim_netlist.v"
)
for f in "${IP_SRCS[@]}"; do
    [ -r "$f" ] || { printf 'ERROR: 缺 IP 网表 %s\n' "$f" >&2; exit 2; }
done

# ---- Vivado 环境（真源 = scripts/env.sh §5；坑① LD_LIBRARY_PATH、坑③ HOME）----
. "${REPO}/scripts/env.sh"
export VIVADO_ROOT="${VIVADO_ROOT:-/home/shorthair/fpga/Vivado/2023.2}"
export VIVADO_LIB_DIR="${VIVADO_LIB_DIR:-${VIVADO_ROOT}/lib/lnx64.o/Rhel/9}"
export LD_LIBRARY_PATH="${VIVADO_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export HOME="${VIVADO_HOME:-${REPO}/.vivado_home}"
mkdir -p "${HOME}"
GLBL="${VIVADO_ROOT}/data/verilog/src/glbl.v"
[ -x "${VIVADO_ROOT}/bin/xvlog" ] || { printf 'ERROR: 找不到 xvlog\n' >&2; exit 2; }
[ -r "${GLBL}" ] || { printf 'ERROR: 缺 %s\n' "${GLBL}" >&2; exit 2; }

log() { printf '%s\n' "$*"; }
MODE=$([ "${EXPECT_FAIL}" -eq 1 ] && echo prefix || echo xsim)   # 反证与正例的日志分开命名
log "== mdu IP 分支 xsim 自检：EXPECT_FAIL=${EXPECT_FAIL}（日志后缀 ${MODE}）"
log "== RTL 指纹（*.v） = $(find "${REPO}/rtl" -name '*.v' | sort | xargs md5sum | md5sum | cut -d' ' -f1)"
log "== 被测 mdu.v = ${MDU_SRC}"
log "== mdu.v md5  = $(md5sum "${MDU_SRC}" | cut -d' ' -f1)"

#------------------------------------------------------------------------------
# 1. 编译：mdu.v（带 IP 宏）+ 真实 IP 网表 + TB + glbl
#    ★ `-d RV32GC_USE_VIVADO_IP` = 与综合脚本同口径（唯一让 RTL 走 IP 分支的开关）
#------------------------------------------------------------------------------
rc=0
"${VIVADO_ROOT}/bin/xvlog" -m64 -i "${XSIM_DIR}" --nolog -d RV32GC_USE_VIVADO_IP \
    -i "${REPO}" -i "${REPO}/rtl/pkg" \
    "${MDU_SRC}" "${IP_SRCS[@]}" "${SCRIPT_DIR}/tb_mdu_ip.v" "${GLBL}" \
    > "${OUT}/xvlog_${MODE}.log" 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
    log "FAIL: xvlog 编译失败（rc=${rc}，见 ${OUT}/xvlog_${MODE}.log）"; tail -n 30 "${OUT}/xvlog_${MODE}.log"; exit 1
fi
log "PASS: xvlog 编译通过（mdu IP 分支 + 4 个加密 IP 网表）"

#------------------------------------------------------------------------------
# 2. 精化 + 运行
#------------------------------------------------------------------------------
"${VIVADO_ROOT}/bin/xelab" -m64 -i "${XSIM_DIR}" --nolog --debug off \
    -L unisims_ver -L secureip -snapshot tb_mdu_ip_sim tb_mdu_ip glbl \
    > "${OUT}/xelab_${MODE}.log" 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
    log "FAIL: xelab 失败（rc=${rc}，见 ${OUT}/xelab_${MODE}.log）"; tail -n 30 "${OUT}/xelab_${MODE}.log"; exit 1
fi
log "PASS: xelab 通过（snapshot=tb_mdu_ip_sim）"

( cd "${XSIM_DIR}/.." && "${VIVADO_ROOT}/bin/xsim" --xsimdir "${XSIM_DIR}" --nolog \
    tb_mdu_ip_sim --runall ) > "${OUT}/xsim_${MODE}.log" 2>&1 || rc=$?

grep -h 'TB_MDU_IP:' "${OUT}/xsim_${MODE}.log" | tee "${OUT}/tb_mdu_ip.${MODE}.lines"
n_pass=$(grep -c 'TB_MDU_IP: PASS ' "${OUT}/xsim_${MODE}.log" || true)
n_fail=$(grep -c 'TB_MDU_IP: FAIL ' "${OUT}/xsim_${MODE}.log" || true)

if [ "${EXPECT_FAIL}" -eq 1 ]; then
    # 复现模式：**必须**至少有一条 FAIL，才算"复现成功"
    if [ "${n_fail}" -gt 0 ]; then
        log "RESULT_MDU_IP_XSIM: 已复现缺陷（向量 FAIL=${n_fail}，PASS=${n_pass}）—— 见 ${OUT}/xsim_${MODE}.log"
        exit 0
    fi
    log "RESULT_MDU_IP_XSIM: FAIL 未能复现（PASS=${n_pass} FAIL=0）"
    exit 1
fi

if [ "${n_fail}" -ne 0 ] || ! grep -q 'TB_MDU_IP: PASS$' "${OUT}/xsim_${MODE}.log"; then
    log "RESULT_MDU_IP_XSIM: FAIL（向量 PASS=${n_pass} FAIL=${n_fail}；见 ${OUT}/xsim_${MODE}.log）"
    exit 1
fi
log "RESULT_MDU_IP_XSIM: OK —— IP 分支 8 条 M 指令向量全过（PASS=${n_pass}）"
exit 0
