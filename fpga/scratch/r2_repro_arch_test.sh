#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/r2_repro_arch_test.sh —— R2 缺陷（R 通道晚拍采样）复现/反证脚本
#==============================================================================
# 缺陷（已登记，M5 上板实测暴露）：
#   核内 AXI 主控制器只在 **R 握手拍**（`axi_master_ctrl.v` 的 `r_fire`）拿到 RDATA；
#   而 M 级 uncached 数据读（MDTA，`core_top.v` 的 M_S_AXI）把 rdata 采进 `m_rd_data_q`
#   的时点是 **R 握手之后第 2 拍**（r_fire → ST_DONE 的 done 拍 → `axi_done_q` 再打一拍）。
#   ⇒ 从设备若**不在握手之后继续保持 RDATA**（真实 MIG / 流水化互连 / 严格 AXI4），
#     读到的是总线上"别的东西"（本 TB 实测：0 或别的事务的数据）⇒ .data/.bss 损坏。
#
# 本脚本做什么（**只读既有产物 + 自己编译 vvp，不改任何判据**）：
#   用 `sim/tb/tb_arch_test.sv` 的 `R_HOLD_IDLE` 开关跑同一个 arch-test 用例：
#     R_HOLD_IDLE=1 ⇒ 保持型从设备（TB 历史口径：RDATA 恒为 rd_addr_q 内容）
#     R_HOLD_IDLE=0 ⇒ **非保持型**（严格 AXI4 / MIG 口径：RDATA 只在 rvalid&rready 拍有效）
#   两次都用同一份 `.hex` / `spike.sig`，逐行比对 DUT 签名与 Spike 参考签名（与
#   `sim/arch_test/run.sh` §7.7 完全同口径）。
#
# 用法：bash fpga/scratch/r2_repro_arch_test.sh [用例名] [R_HOLD_IDLE] [RUN_TAG]
#   默认：I-add-00 / 0 / r2_<用例>_hold<值>
#   环境：TIMEOUT_CYCLES（默认 4000000，= run.sh 口径）；复现"读错导致跑飞"时可用
#         更小的预算把"未到终止点"尽快钉成 FAIL（判定语义不变，只是提前收尾）。
# 前置：`sim/arch_test/work/<用例>/` 有 run.sh 的产物；缺失时本脚本自动先跑一次
#       `./sim/arch_test/run.sh <用例>`（会写 sim/arch_test/work/，不改仓库源码）。
# 退出码：0 = DUT 签名与 Spike 参考**完全一致**且 TB 打印唯一 PASS 锚点；1 = 不一致/未 PASS
# 纪律：本脚本**不打印任何兜底 PASS 文案**；判定失败路径一律 `R2_REPRO: ... FAIL`
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
OUT_DIR="${SCRIPT_DIR}/out"
mkdir -p "${OUT_DIR}"

TEST_NAME="${1:-I-add-00}"
R_HOLD_IDLE="${2:-0}"
RUN_TAG="${3:-r2_${TEST_NAME}_hold${R_HOLD_IDLE}}"
TIMEOUT_CYCLES="${TIMEOUT_CYCLES:-4000000}"

WD="${REPO_ROOT}/sim/arch_test/work/${TEST_NAME}"
VVP_LOG="${OUT_DIR}/${RUN_TAG}.log"
CMP_LOG="${OUT_DIR}/${RUN_TAG}.compile.log"
IV="${IV:-$(command -v iverilog || true)}"
VVP="${VVP:-$(command -v vvp || true)}"

cd "${REPO_ROOT}" || { printf 'R2_REPRO: %s FAIL 无法进入仓库根\n' "${RUN_TAG}" >&2; exit 2; }

#------------------------------------------------------------------------------
# 0. 前置产物（缺失则先跑一次官方入口生成；产物在 work/ 下，不改源码）
#------------------------------------------------------------------------------
if [ ! -f "${WD}/run.console.log" ] || [ ! -f "${WD}/spike.sig" ]; then
    printf 'R2_REPRO: %s 前置产物缺失 ⇒ 先运行 ./sim/arch_test/run.sh %s\n' "${RUN_TAG}" "${TEST_NAME}"
    if ! ./sim/arch_test/run.sh "${TEST_NAME}" >"${CMP_LOG}.prereq" 2>&1; then
        printf 'R2_REPRO: %s FAIL 前置用例生成失败（见 %s.prereq）\n' "${RUN_TAG}" "${CMP_LOG}" >&2
        exit 1
    fi
fi

HEX="${WD}/${TEST_NAME}.hex"
REF_SIG="${WD}/${TEST_NAME}.spike.sig"
DUT_SIG="${OUT_DIR}/${RUN_TAG}.dut.signature"
[ -f "${HEX}" ]     || { printf 'R2_REPRO: %s FAIL 缺 %s\n' "${RUN_TAG}" "${HEX}" >&2; exit 1; }
[ -f "${REF_SIG}" ] || { printf 'R2_REPRO: %s FAIL 缺 %s\n' "${RUN_TAG}" "${REF_SIG}" >&2; exit 1; }

#------------------------------------------------------------------------------
# 1. 从 run.sh 的 INFO 行取 sig 基址/字数/tohost（与 run.sh 同源，不硬编码）
#------------------------------------------------------------------------------
INFO_LINE="$(grep -m1 'RV32_ARCH_TEST_INFO: .* 符号 sig=' "${WD}/run.console.log" || true)"
[ -n "${INFO_LINE}" ] || { printf 'R2_REPRO: %s FAIL 取不到 INFO 行（%s/run.console.log）\n' "${RUN_TAG}" "${WD}" >&2; exit 1; }
SIG_B="$(printf '%s' "${INFO_LINE}" | sed -n 's/.*sig=\[0x\([0-9a-fA-F]*\),.*/\1/p')"
SIG_WORDS="$(printf '%s' "${INFO_LINE}" | sed -n 's/.*words=\([0-9]*\) .*/\1/p')"
TOHOST="$(printf '%s' "${INFO_LINE}" | sed -n 's/.*tohost=0x\([0-9a-fA-F]*\).*/\1/p')"
[ -n "${SIG_B}" ] && [ -n "${SIG_WORDS}" ] && [ -n "${TOHOST}" ] || {
    printf 'R2_REPRO: %s FAIL INFO 行解析失败：%s\n' "${RUN_TAG}" "${INFO_LINE}" >&2; exit 1; }

#------------------------------------------------------------------------------
# 2. 编译 TB（与 run.sh §7.5 同口径 + 本脚本的 R_HOLD_IDLE 开关）
#------------------------------------------------------------------------------
mapfile -t RTL_SRCS < <(find rtl -name '*.v' | LC_ALL=C sort)
[ "${#RTL_SRCS[@]}" -gt 0 ] || { printf 'R2_REPRO: %s FAIL rtl 源为空\n' "${RUN_TAG}" >&2; exit 2; }

{
    printf '== R2_REPRO: 用例=%s R_HOLD_IDLE=%s（0=非保持/MIG 口径，1=保持型）\n' "${TEST_NAME}" "${R_HOLD_IDLE}"
    printf '== 期  望：R_HOLD_IDLE=0 时，**修复前**的核应读错（签名分歧）；修复后应完全一致\n'
    printf '== hex=%s\n' "${HEX}"
    printf '== sig=%s +%s words, tohost=0x%s\n' "${SIG_B}" "${SIG_WORDS}" "${TOHOST}"
    printf '== RTL 指纹 = %s\n' "$(find rtl -name '*.v' | sort | xargs md5sum | md5sum | cut -d' ' -f1)"
} | tee "${CMP_LOG}"

"${IV}" -g2012 -I rtl/pkg -I . -s tb_arch_test -o "${OUT_DIR}/${RUN_TAG}.vvp" \
    -P "tb_arch_test.PROG_HEX=\"${HEX}\"" \
    -P "tb_arch_test.SIG_FILE=\"${DUT_SIG}\"" \
    -P "tb_arch_test.SIG_BASE=32'h${SIG_B}" \
    -P "tb_arch_test.SIG_WORDS=${SIG_WORDS}" \
    -P "tb_arch_test.TOHOST_ADDR=32'h${TOHOST}" \
    -P "tb_arch_test.TIMEOUT_CYCLES=${TIMEOUT_CYCLES:-4000000}" \
    -P "tb_arch_test.R_HOLD_IDLE=${R_HOLD_IDLE}" \
    "${RTL_SRCS[@]}" sim/tb/tb_arch_test.sv >>"${CMP_LOG}" 2>&1 || {
        printf 'R2_REPRO: %s FAIL iverilog 编译失败（见 %s）\n' "${RUN_TAG}" "${CMP_LOG}" >&2; exit 1; }

#------------------------------------------------------------------------------
# 3. 运行 + 判定（三重：vvp rc / 唯一 PASS 锚点 / 签名逐行一致）
#------------------------------------------------------------------------------
: >"${DUT_SIG}"
timeout 900 "${VVP}" "${OUT_DIR}/${RUN_TAG}.vvp" >"${VVP_LOG}" 2>&1
rc_vvp=$?
n_pass=$(grep -cxF 'TB_ARCH_TEST: PASS' "${VVP_LOG}" || true)
n_fail=$(grep -cF 'FAIL' "${VVP_LOG}" || true)

dut_lines=$(wc -l <"${DUT_SIG}" 2>/dev/null || echo 0)
ndiff=-1
if [ "${dut_lines}" -eq "${SIG_WORDS}" ] && [ "${SIG_WORDS}" -gt 0 ]; then
    awk '{print tolower($2)}' "${DUT_SIG}" >"${OUT_DIR}/${RUN_TAG}.dut.data"
    # Spike 的 `+signature-granularity=4` 输出为**单列（仅数据）**；用 $NF 兼容
    # "仅数据"与"<addr> <data>"两种写法（与 run.sh §7.7 的 $1 口径等价）。
    awk '{print tolower($NF)}' "${REF_SIG}" >"${OUT_DIR}/${RUN_TAG}.spike.data"
    ndiff="$(awk 'NR==FNR{a[FNR]=$0;next}{if($0!=a[FNR])n++}END{print n+0}' \
                  "${OUT_DIR}/${RUN_TAG}.dut.data" "${OUT_DIR}/${RUN_TAG}.spike.data")"
fi

printf '\n== 判定证据：vvp_rc=%d  PASS 锚点=%s（须 1）  FAIL 字样行=%s（须 0）\n' "${rc_vvp}" "${n_pass}" "${n_fail}"
printf '== 签名行数：DUT=%s / 期望=%s ；与 Spike 参考分歧行数=%s\n' "${dut_lines}" "${SIG_WORDS}" "${ndiff}"
if [ "${ndiff}" -ne 0 ] && [ "${ndiff}" -ge 0 ]; then
    printf '== 首个分歧（行号 = 签名区第几个字，addr = 0x%s + 4*行号）：\n' "${SIG_B}"
    awk -v base="$((16#${SIG_B}))" 'NR==FNR{a[FNR]=$0;next}
         {if($0!=a[FNR]){printf "    #%d addr=0x%08x dut=%s spike=%s\n",FNR,base+4*(FNR-1),a[FNR],$0;n++}}
         n>=5{exit}' "${OUT_DIR}/${RUN_TAG}.dut.data" "${OUT_DIR}/${RUN_TAG}.spike.data"
fi
printf '== 日志：%s\n' "${VVP_LOG}"

rc=0
[ "${rc_vvp}" -eq 0 ] || rc=1
[ "${n_pass}" -eq 1 ] || rc=1
[ "${n_fail}" -eq 0 ] || rc=1
[ "${ndiff}" -eq 0 ] || rc=1
if [ "${rc}" -eq 0 ]; then
    printf 'R2_REPRO(%s): 签名与 Spike 参考完全一致（R_HOLD_IDLE=%s；rc=0）\n' "${RUN_TAG}" "${R_HOLD_IDLE}"
else
    printf 'R2_REPRO(%s): FAIL 核读到的数据与参考不一致/未到终止点（R_HOLD_IDLE=%s；vvp_rc=%d 分歧=%s）\n' \
           "${RUN_TAG}" "${R_HOLD_IDLE}" "${rc_vvp}" "${ndiff}" >&2
fi
exit "${rc}"
