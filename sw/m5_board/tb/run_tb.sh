#!/usr/bin/env bash
#==============================================================================
# sw/m5_board/tb/run_tb.sh —— M5 上板程序核级仿真：编译 + 运行 + 判定（未捕获即失败）
#==============================================================================
# 用法 : bash sw/m5_board/tb/run_tb.sh
# 环境 : PROG_HEX=<路径>         覆盖被测程序 hex（默认 sw/m5_board/out/m5_board.hex）
#        TIMEOUT_CYCLES=<拍数>   覆盖超时预算（默认 4000000，TB 参数同值）
#        TOP=<模块名>            覆盖顶层（默认 tb_m5_board；控制实验用同名 TB 即可不改）
#        RUN_TAG=<标签>          日志/产物名后缀（默认 tb_m5_board）
#        TRACE_PRINT_N / UART_PRINT_MAX / PROGRESS_EVERY 亦可透传
#        R_STICKY=<0|1>          CONFREG 侧 R 数据保持（默认 1 = 上板 confreg_syn 口径）
#        DDR_R_NONHOLD=<0|1>     ★ 下游（DDR3/XIP）侧 R 数据保持：默认 0 = 原样透传；
#                                1 = 非保持型 R 通道模型（严格 AXI4 / MIG 口径：
#                                    RDATA 只在 R 握手拍有效，其余拍为 0）
#        RD_TRACE_WINDOW=<N>     >0 ⇒ 打印首笔读起 N 拍的 R 通道/M 级采样（诊断）
# 产物 : sw/m5_board/tb/out/<RUN_TAG>.vvp      编译产物
#        sw/m5_board/tb/out/<RUN_TAG>.log      完整运行日志（判定证据）
#        sw/m5_board/tb/out/<RUN_TAG>.compile.log
# 退出码：0 = 唯一 PASS 锚点恰好 1 行且无 FAIL 字样；非 0 = 任一判据未达成/编译失败
# 纪律 : 只读 rtl/**、sim/**；本脚本**不打印任何兜底 PASS 文案**。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TB_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd -- "${TB_DIR}/../../.." && pwd -P)"
OUT_DIR="${TB_DIR}/out"
mkdir -p "${OUT_DIR}"

RUN_TAG="${RUN_TAG:-tb_m5_board}"
TOP="${TOP:-tb_m5_board}"
PROG_HEX="${PROG_HEX:-sw/m5_board/out/m5_board.hex}"
TIMEOUT_CYCLES="${TIMEOUT_CYCLES:-4000000}"
TRACE_PRINT_N="${TRACE_PRINT_N:-48}"
UART_PRINT_MAX="${UART_PRINT_MAX:-4096}"
PROGRESS_EVERY="${PROGRESS_EVERY:-100000}"
R_STICKY="${R_STICKY:-1}"
DDR_R_NONHOLD="${DDR_R_NONHOLD:-0}"

VVP="${VVP:-$(command -v vvp || true)}"
IV="${IV:-$(command -v iverilog || true)}"
VVP_LOG="${OUT_DIR}/${RUN_TAG}.log"
CMP_LOG="${OUT_DIR}/${RUN_TAG}.compile.log"
VVP_OUT="${OUT_DIR}/${RUN_TAG}.vvp"

[ -n "${IV}" ]  && [ -x "${IV}" ]  || { printf 'ERROR: 找不到 iverilog\n' >&2; exit 2; }
[ -n "${VVP}" ] && [ -x "${VVP}" ] || { printf 'ERROR: 找不到 vvp\n' >&2; exit 2; }

cd "${REPO_ROOT}" || { printf 'ERROR: 无法进入仓库根 %s\n' "${REPO_ROOT}" >&2; exit 2; }

# RTL 源全集（与 scripts/env.sh 的 rv32_rtl_sources 同口径：find rtl -name '*.v' | sort）
mapfile -t RTL_SRCS < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
[ "${#RTL_SRCS[@]}" -gt 0 ] || { printf 'ERROR: rtl/**/*.v 为空\n' >&2; exit 2; }

{
    printf '== run_tb.sh: repo=%s\n' "${REPO_ROOT}"
    printf '== PROG_HEX=%s\n' "${PROG_HEX}"
    printf '== TIMEOUT_CYCLES=%s TOP=%s RUN_TAG=%s\n' "${TIMEOUT_CYCLES}" "${TOP}" "${RUN_TAG}"
    printf '== rtl 源 %d 个；RTL 指纹 = %s\n' "${#RTL_SRCS[@]}" \
        "$(find rtl -name '*.v' | sort | xargs md5sum | md5sum | cut -d' ' -f1)"
} | tee "${CMP_LOG}"

#------------------------------------------------------------------------------
# 1. 编译
#------------------------------------------------------------------------------
set -o pipefail
"${IV}" -g2012 -I rtl/pkg -I . -s "${TOP}" -o "${VVP_OUT}" \
    -P "${TOP}.PROG_HEX=\"${PROG_HEX}\"" \
    -P "${TOP}.TIMEOUT_CYCLES=${TIMEOUT_CYCLES}" \
    -P "${TOP}.TRACE_PRINT_N=${TRACE_PRINT_N}" \
    -P "${TOP}.UART_PRINT_MAX=${UART_PRINT_MAX}" \
    -P "${TOP}.PROGRESS_EVERY=${PROGRESS_EVERY}" \
    -P "${TOP}.R_STICKY=${R_STICKY}" \
    -P "${TOP}.DDR_R_NONHOLD=${DDR_R_NONHOLD}" \
    -P "${TOP}.RD_TRACE_WINDOW=${RD_TRACE_WINDOW:-0}" \
    "${RTL_SRCS[@]}" \
    sim/tb/sim_mem_model.sv \
    "${TB_DIR}/confreg_axi_filter.v" \
    "${TB_DIR}/tb_m5_board.sv" \
    2>&1 | tee -a "${CMP_LOG}"
rc_iv=${PIPESTATUS[0]}
if [ "${rc_iv}" -ne 0 ]; then
    printf 'RESULT_M5_TB(%s): FAIL iverilog 编译失败 rc=%d（见 %s）\n' "${RUN_TAG}" "${rc_iv}" "${CMP_LOG}" >&2
    exit 1
fi

#------------------------------------------------------------------------------
# 2. 运行（stdout+stderr 全量入日志；stdbuf 行缓冲 ⇒ 长跑时可实时看进度）
#------------------------------------------------------------------------------
if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "${VVP}" -M . -m . "${VVP_OUT}" > "${VVP_LOG}" 2>&1
else
    "${VVP}" -M . -m . "${VVP_OUT}" > "${VVP_LOG}" 2>&1
fi
rc_vvp=$?
tail -n 200 "${VVP_LOG}"

#------------------------------------------------------------------------------
# 3. 判定（三重：vvp 退出码 / PASS 锚点唯一 / 无 FAIL 字样）
#------------------------------------------------------------------------------
n_pass=$(grep -cxF 'TB_M5_BOARD: PASS' "${VVP_LOG}" || true)
n_fail=$(grep -cF 'FAIL' "${VVP_LOG}" || true)
rc=0
if [ "${rc_vvp}" -ne 0 ]; then rc=1; fi
if [ "${n_pass}" -ne 1 ]; then rc=1; fi
if [ "${n_fail}" -ne 0 ]; then rc=1; fi

printf '\n== 判定证据：vvp_rc=%d  整行 PASS 锚点数=%d（须为 1）  含 FAIL 行数=%d（须为 0）\n' \
       "${rc_vvp}" "${n_pass}" "${n_fail}"
printf '== 日志：%s\n' "${VVP_LOG}"
if [ "${rc}" -eq 0 ]; then
    printf 'RESULT_M5_TB(%s): 判定完成（rc=0）\n' "${RUN_TAG}"
else
    printf 'RESULT_M5_TB(%s): FAIL（rc=%d）—— 见日志判定行\n' "${RUN_TAG}" "${rc}" >&2
fi
exit "${rc}"
