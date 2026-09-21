#!/usr/bin/env bash
#==============================================================================
# sw/m5_board/tb/ip/run_ip_div_xsim.sh —— 用 **xsim** 跑真实 div_gen IP 的时序探针
#==============================================================================
# 为什么是 xsim：`fpga/ip/rv32_div/rv32_div_sim_netlist.v` 是 Vivado 生成的**加密**
#   （`pragma protect` / IEEE 1735）功能模型 ⇒ iverilog/Verilator 都不能编译；
#   xsim（xvlog/xelab/xsim）自带解密密钥 ⇒ 只有它能跑这层"真实 IP 行为"。
#
# 用法：bash sw/m5_board/tb/ip/run_ip_div_xsim.sh
# 产物：sw/m5_board/tb/ip/out/{xvlog.log,xelab.log,xsim.log}
# 退出码：0 = 全部向量 PASS 且出现 TB_IP_DIV: DONE；非 0 = 编译/仿真/向量失败
# 纪律：只读 rtl/**、fpga/ip/**；只写本目录 out/（+ 就地 xsim.dir/*.sim 产物）。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd -P)"        # <rv32gc-cpu>
IP="${REPO}/fpga/ip/rv32_div/rv32_div_sim_netlist.v"
OUT="${SCRIPT_DIR}/out"
XSIM_DIR="${SCRIPT_DIR}/xsim.dir"
mkdir -p "${OUT}" "${XSIM_DIR}"
cd "${SCRIPT_DIR}" || exit 2

[ -r "${IP}" ] || { printf 'ERROR: 缺真实 IP 网表 %s\n' "${IP}" >&2; exit 2; }

# ---- Vivado 环境（口径真源 = scripts/env.sh §5；坑① LD_LIBRARY_PATH、坑③ HOME）----
. "${REPO}/scripts/env.sh"
export VIVADO_ROOT="${VIVADO_ROOT:-/home/shorthair/fpga/Vivado/2023.2}"
export VIVADO_LIB_DIR="${VIVADO_LIB_DIR:-${VIVADO_ROOT}/lib/lnx64.o/Rhel/9}"
export LD_LIBRARY_PATH="${VIVADO_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export HOME="${VIVADO_HOME:-${REPO}/.vivado_home}"
mkdir -p "${HOME}"
[ -x "${VIVADO_ROOT}/bin/xvlog" ] || { printf 'ERROR: 找不到 xvlog（%s/bin）\n' "${VIVADO_ROOT}" >&2; exit 2; }
GLBL="${VIVADO_ROOT}/data/verilog/src/glbl.v"      # unisim 原语依赖的全局 GSR 模块
[ -r "${GLBL}" ] || { printf 'ERROR: 缺 unisim 全局模块 %s\n' "${GLBL}" >&2; exit 2; }

log() { printf '%s\n' "$*" ; }

log "== xsim 环境：VIVADO_ROOT=${VIVADO_ROOT}  HOME=${HOME}"
log "== IP 网表：${IP}（md5 $(md5sum "${IP}" | cut -d' ' -f1)）"

#------------------------------------------------------------------------------
# 1. 编译（xvlog：我们的 TB + 真实 IP 网表）
#------------------------------------------------------------------------------
rc=0
"${VIVADO_ROOT}/bin/xvlog" -m64 -i "${XSIM_DIR}" --nolog \
    "${SCRIPT_DIR}/tb_ip_div.v" "${IP}" "${GLBL}" > "${OUT}/xvlog.log" 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
    log "FAIL: xvlog 编译失败（rc=${rc}，见 ${OUT}/xvlog.log）"
    tail -n 30 "${OUT}/xvlog.log"
    exit 1
fi
log "PASS: xvlog 编译通过（含加密 IP 网表解密）"

#------------------------------------------------------------------------------
# 2. 精化（xelab）
#   ★ 真实 IP 网表里例化的是 Xilinx **unisim 原语**（FDRE/LUT*/CARRY4/GND…）⇒ 必须
#     把预编译库 `unisims_ver` 链进来（`-L unisims_ver`，由 $VIVADO_ROOT/data/xsim/
#     xsim.ini 映射；secureip 供 MIG 等用）。这与"实现分支跑的是真实原语"的事实一致。
#------------------------------------------------------------------------------
#   ★ `glbl` 是 unisim 原语依赖的**全局 GSR 模块**（FDRE.v 里引用）⇒ 必须作为第二个
#     顶层一起精化（`xelab ... work.glbl`）。
"${VIVADO_ROOT}/bin/xelab" -m64 -i "${XSIM_DIR}" --nolog --debug off \
    -L unisims_ver -L secureip \
    -snapshot tb_ip_div_sim tb_ip_div glbl \
    > "${OUT}/xelab.log" 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
    log "FAIL: xelab 精化失败（rc=${rc}，见 ${OUT}/xelab.log）"
    tail -n 30 "${OUT}/xelab.log"
    exit 1
fi
log "PASS: xelab 精化通过（snapshot=tb_ip_div_sim）"

#------------------------------------------------------------------------------
# 3. 运行
#------------------------------------------------------------------------------
#   xsim 的参数拼写与 xelab 不同：工作目录用 `--xsimdir`（不是 -i），
#   `--runall` = 跑完 run all 并退出。
( cd "${XSIM_DIR}/.." && "${VIVADO_ROOT}/bin/xsim" --xsimdir "${XSIM_DIR}" --nolog \
    tb_ip_div_sim --runall ) > "${OUT}/xsim.log" 2>&1 || rc=$?
grep -h 'TB_IP_DIV:' "${OUT}/xsim.log" | tee "${OUT}/tb_ip_div.lines"

n_pass=$(grep -c 'TB_IP_DIV: PASS' "${OUT}/xsim.log" || true)
n_fail=$(grep -c 'TB_IP_DIV: FAIL' "${OUT}/xsim.log" || true)
n_done=$(grep -c 'TB_IP_DIV: DONE' "${OUT}/xsim.log" || true)
log "== 向量判定：PASS=${n_pass}  FAIL=${n_fail}  DONE=${n_done}"

if [ "${n_fail}" -ne 0 ] || [ "${n_done}" -ne 1 ] || [ "${n_pass}" -lt 6 ]; then
    log "RESULT_IP_DIV_XSIM: FAIL（见 ${OUT}/xsim.log）"
    exit 1
fi
log "RESULT_IP_DIV_XSIM: OK —— 真实 div_gen IP 在这些向量上握手/结果均正确（单拍 tvalid 输入）"
exit 0
