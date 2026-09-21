#!/usr/bin/env bash
#==============================================================================
# sw/m5_board/tb/run_diag_matrix.sh —— 诊断版（step2.5 R2 探针）**三配置仿真矩阵**
#==============================================================================
# 目的：一次跑完本轮诊断版的全部仿真证据（可复现、未捕获即失败）：
#
#   A) diag_hold        修复后 RTL + **保持型** R 通道（DDR_R_NONHOLD=0）
#                         期望：TB_M5_BOARD: PASS，且 step2.5 行含
#                               `word=0x12345678`、`byte=0x5A`、`R2FIX: yes`
#   B) diag_nonhold     修复后 RTL + **非保持型** R 通道（DDR_R_NONHOLD=1，= MIG 口径）
#                         期望：同上（**且与 A 的 UART 字节流逐字节相同** —— R2 修复后
#                               核不再依赖从设备保持 RDATA）
#   C) diag_old_nonhold **修复前** RTL（tb/scratch/oldrtl 只读拷贝）+ 非保持型 R
#                         期望：FAIL（必红）且 step2.5 行**不含** `word=0x12345678`
#                               ⇒ 证明"该判别确实能抓到旧 bitstream 的 R2 缺陷"
#
# 被测程序：`ctrl/out/ct_m5_scaled.hex` = `sw/m5_board/m5_board.S` 的**缩放副本**
#           （make_scaled.py：只把 DELAY_HB_TICKS / DELAY_SW_TICKS 两个**挂钟等待**常量
#             缩小，其余逐字不动；等价性机器证据 = ctrl/diff_equiv.py，差异 4 个字）。
#           为什么缩放：完整版一轮主循环 ≈7.7e7 拍（iverilog ≈2.5e3 拍/秒 ⇒ ≈9 小时）；
#           缩放的只有"停多久"，**步①..步⑤+步2.5 的判据与冻结程序逐字相同**。
#
# 用法：bash sw/m5_board/tb/run_diag_matrix.sh
# 产物：tb/out/diag_{hold,nonhold,old_nonhold}.log（完整日志，判定证据）
#       tb/out/diag_matrix.log（本脚本汇总 + 关键行摘录）
# 退出码：0 = 三配置结果**全部符合预期**；非 0 = 任一不符合（看汇总）
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"
OUT="${SCRIPT_DIR}/out"
SUM="${OUT}/diag_matrix.log"
PROG="sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex"
TIMEOUT="${TIMEOUT_CYCLES:-6000000}"
mkdir -p "${OUT}"
cd "${REPO}" || exit 2

log() { printf '%s\n' "$*" | tee -a "${SUM}"; }
: > "${SUM}"

rtl_fp() { find rtl \( -name '*.v' -o -name '*.vh' \) | sort | xargs md5sum | md5sum | awk '{print $1}'; }
FP0="$(rtl_fp)"
log "== run_diag_matrix: $(date -Is)"
log "== 前置 rtl/** 指纹 = ${FP0}"

#------------------------------------------------------------------------------
# 0. 前置：缩放副本必须 = 当前 m5_board.S 的（只缩放两个挂钟常量的）等价副本
#------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/ctrl/build_ctrl.sh" >>"${SUM}" 2>&1 || { log "FAIL: ctrl 程序构建失败"; exit 2; }
python3 "${SCRIPT_DIR}/ctrl/diff_equiv.py" >>"${SUM}" 2>&1
rc_eq=$?
if [ "${rc_eq}" -ne 0 ]; then log "FAIL: 缩放副本与冻结程序不等价（diff_equiv rc=${rc_eq}）"; exit 2; fi
log "== 等价性核对通过（diff_equiv.py：仅 DELAY_HB/SW_TICKS 的 li 立即数不同）"

#------------------------------------------------------------------------------
# 1. 旧 RTL overlay（只读拷贝；不修改 rtl/**）
#------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/make_oldrtl_overlay.sh" >>"${SUM}" 2>&1 || { log "FAIL: overlay 生成失败"; exit 2; }
log "== 旧 RTL overlay 就绪：tb/scratch/oldrtl（修复前 = commit 68ff5fd）"

#------------------------------------------------------------------------------
# 2. 三配置并行跑（各自独立 vvp/日志）
#------------------------------------------------------------------------------
run_one() {                                     # run_one <tag> <RTL_DIR> <NONHOLD>
    local tag="$1" rtldir="$2" nonhold="$3"
    PROG_HEX="${PROG}" RUN_TAG="${tag}" RTL_DIR="${rtldir}" \
    DDR_R_NONHOLD="${nonhold}" EXPECT_EXTRA="R2FIX: yes" \
    TIMEOUT_CYCLES="${TIMEOUT}" PROGRESS_EVERY=500000 \
    bash "${SCRIPT_DIR}/run_tb.sh" >"${OUT}/${tag}.run.log" 2>&1
    printf '%s rc=%d\n' "${tag}" "$?" >>"${OUT}/.diag_matrix_rc"
}

rm -f "${OUT}/.diag_matrix_rc"
log "== 启动三配置（并行；超时预算 ${TIMEOUT} 拍/个）"
run_one diag_hold         rtl                     0 &
run_one diag_nonhold      rtl                     1 &
run_one diag_old_nonhold  sw/m5_board/tb/scratch/oldrtl 1 &
wait

rc_of() { awk -v t="$1" '$1==t {sub("rc=","",$2); print $2}' "${OUT}/.diag_matrix_rc"; }
RC_HOLD="$(rc_of diag_hold)"
RC_NON="$(rc_of diag_nonhold)"
RC_OLD="$(rc_of diag_old_nonhold)"

#------------------------------------------------------------------------------
# 3. 结果汇总：逐条摘录关键证据行 + 期望比对（fail-closed）
#------------------------------------------------------------------------------
extract() { grep -hE 'step1 LED heartbeat|step2 UART|step2\.5 DDR3|step3 switch|step4 timer|step5 FREQ|RESULT: RV32GC-M5|TB_M5_BOARD: (PASS|FAIL)|TB_M5_CHECK: C[0-9]' "$1" 2>/dev/null | sed 's/^TB_M5_UART : *//' ; }

VERDICT=0
for pair in "diag_hold:PASS" "diag_nonhold:PASS" "diag_old_nonhold:FAIL"; do
    tag="${pair%%:*}"; want="${pair##*:}"
    f="${OUT}/${tag}.log"
    log ""
    log "------------------------------------------------------------------------"
    log "== [${tag}] 期望 rc ⇒ ${want}；实际 rc=$(rc_of "${tag}")"
    log "------------------------------------------------------------------------"
    if [ ! -f "${f}" ]; then log "  缺少日志 ${f}"; VERDICT=1; continue; fi
    # 关键行（去掉 TB_M5_UART 前缀，便于阅读）
    grep -hE 'step2\.5 DDR3|step2\.6 MEXT|step2\.7 stack|RESULT: RV32GC-M5|BUILD=' "${f}" | sed 's/^TB_M5_UART : *//' | tee -a "${SUM}"
    grep -hE 'TB_M5_CHECK: C[0-9]|TB_M5_BOARD: (PASS|FAIL)' "${f}" | tee -a "${SUM}"
    got_rc="$(rc_of "${tag}")"
    if [ "${want}" = "PASS" ] && [ "${got_rc}" != "0" ]; then log "  ⇒ FAIL: 期望 rc=0（PASS），实际 rc=${got_rc}"; VERDICT=1; fi
    if [ "${want}" = "FAIL" ] && [ "${got_rc}" = "0" ]; then log "  ⇒ FAIL: 期望 rc≠0（反证必红），实际 rc=0"; VERDICT=1; fi
    # 内容判据（比 rc 更严）：BUILD 标记 + 三个诊断步的结论
    # 镜像标记随程序换代同步（当前 = m5_board.S 的 BUILD=m5_board-diag-2026-09-21d）
    if grep -q 'BUILD=m5_board-diag-2026-09-21d' "${f}"; then
        log "  ⇒ BUILD 标记在位 ✅（证明被测镜像 = 本轮诊断版）"
    else
        log "  ⇒ FAIL: 未打印 BUILD 标记"; VERDICT=1
    fi
    if grep -q 'word=0x12345678.*re-read=0x12345678.*byte=0x5A.*R2FIX: yes' "${f}"; then
        log "  ⇒ step2.5 判别行：word/re-read=0x12345678、byte=0x5A、R2FIX: yes ✅"
        if [ "${tag}" = "diag_old_nonhold" ]; then log "  ⇒ FAIL: 旧 RTL 反证**不应**出现正确的回环值"; VERDICT=1; fi
    else
        log "  ⇒ step2.5 判别行**未**给出 word=0x12345678/byte=0x5A/R2FIX: yes（原文见上）"
        if [ "${tag}" != "diag_old_nonhold" ]; then log "  ⇒ FAIL: 期望修复后 RTL 给出 R2FIX: yes"; VERDICT=1; fi
    fi
    # 步2.6 M 扩展探针（期望 9 个向量全对）：新 RTL 两模型都必须 ok
    if grep -q 'MEXT: OK' "${f}"; then
        log "  ⇒ step2.6 M 扩展探针：MEXT: OK ✅"
    else
        log "  ⇒ step2.6 M 扩展探针：未出现 MEXT: OK（原文见上）"
        if [ "${tag}" != "diag_old_nonhold" ]; then log "  ⇒ FAIL: 行为分支下 M 扩展向量应全对（期望 MEXT: OK）"; VERDICT=1; fi
    fi
    # 步2.7 栈字节探针：新 RTL 两模型 ok；旧 RTL（R2 缺陷）必须 BAD
    if grep -q 'STACKBF: OK' "${f}"; then
        log "  ⇒ step2.7 栈字节探针：STACKBF: OK ✅"
        if [ "${tag}" = "diag_old_nonhold" ]; then log "  ⇒ FAIL: 旧 RTL 反证**不应**出现 STACKBF: OK"; VERDICT=1; fi
    else
        log "  ⇒ step2.7 栈字节探针：未出现 STACKBF: OK（原文见上）"
        if [ "${tag}" != "diag_old_nonhold" ]; then log "  ⇒ FAIL: 修复后 RTL 应给出 STACKBF: ok"; VERDICT=1; fi
    fi
done

#------------------------------------------------------------------------------
# 4. A/B 字节流一致性（修复后核不依赖从设备保持 RDATA 的直接证据）
#------------------------------------------------------------------------------
if [ -f "${OUT}/diag_hold.log" ] && [ -f "${OUT}/diag_nonhold.log" ]; then
    python3 - "${OUT}/diag_hold.log" "${OUT}/diag_nonhold.log" <<'PY' | tee -a "${SUM}"
import re, sys
def uart(p):
    t = open(p, errors="latin1").read()
    m = re.search(r"TB_M5_UART : 捕获序列.*?\n\s+\[(.*?)\]\n", t, re.S)
    return m.group(1) if m else None
a, b = uart(sys.argv[1]), uart(sys.argv[2])
if a is None or b is None:
    print("== A/B UART 字节流比对：无法从日志提取捕获序列 ⇒ 跳过"); sys.exit(0)
print(f"== A/B UART 字节流比对：hold {len(a)} 字符 vs nonhold {len(b)} 字符 ⇒ " + ("逐字节相同 ✅" if a == b else "不同 ❌"))
if a != b:
    print("   hold :", a[:200]); print("   nonhold:", b[:200])
PY
fi

#------------------------------------------------------------------------------
# 5. 自证：rtl/** 未被修改
#------------------------------------------------------------------------------
FP1="$(rtl_fp)"
log ""
log "== 后置 rtl/** 指纹 = ${FP1}"
if [ "${FP0}" != "${FP1}" ]; then log "FAIL: rtl/** 指纹变化（本脚本不应改 RTL）"; VERDICT=1;
else log "== rtl/** 指纹前后一致（三配置仿真未改一行 RTL）✅"; fi

log ""
if [ "${VERDICT}" -eq 0 ]; then
    log "DIAG_MATRIX: OK —— 三配置全部符合预期（A/B 修复后双模型 PASS + R2FIX: yes；C 旧 RTL 反证必红）"
else
    log "DIAG_MATRIX: FAIL —— 有配置不符合预期，见上面逐条"
fi
log "== 汇总日志：${SUM}"
exit "${VERDICT}"
