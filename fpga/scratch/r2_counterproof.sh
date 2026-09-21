#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/r2_counterproof.sh —— R2 修复的**反证实验**（cp 备份 → 临时还原旧采样
#   → 非保持型 R 模型下必 FAIL → 恢复并自证 md5）
#==============================================================================
# 纪律（任务红线）：
#   · **不使用** git checkout / stash / reset / clean —— 旧版本用 `git show HEAD:<path>`
#     取出（只读），恢复用**自己 cp 的备份**；全程 md5 自证（前后指纹必须一致）。
#   · 任何退出路径（含中断）都必须把 RTL 恢复到**修复后**的状态（trap EXIT）。
#
# 实验矩阵（全部在本脚本内跑完）：
#   A) 旧采样 + 非保持型 R：arch-test I-add-00 `R_HOLD_IDLE=0` ⇒ 应 FAIL（读错）
#   B) 旧采样 + 非保持型 R：M5 TB（缩放五步程序）`DDR_R_NONHOLD=1` ⇒ 应 FAIL
#   C) 恢复修复后 RTL：md5 与备份逐字节一致 ⇒ 恢复自证
# 用法：bash fpga/scratch/r2_counterproof.sh
# 退出码：0 = 反证链完整成立（A/B 都 FAIL 且 C 恢复成功）；其它 = 链不成立，需人工看日志
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
OUT_DIR="${SCRIPT_DIR}/out"
mkdir -p "${OUT_DIR}"
cd "${REPO_ROOT}" || exit 2

AXI="rtl/axi/axi_master_ctrl.v"
TOP="rtl/top/core_top.v"
BK_DIR="${OUT_DIR}/r2_counterproof_backup"
mkdir -p "${BK_DIR}"

log() { printf '%s\n' "$*" | tee -a "${OUT_DIR}/r2_counterproof.log"; }

#------------------------------------------------------------------------------
# 0. 前置：当前必须是**修复后**的 RTL（否则反证无意义）
#------------------------------------------------------------------------------
: >"${OUT_DIR}/r2_counterproof.log"
for f in "$AXI" "$TOP"; do
    grep -q 'rdata_hold' "$f" || { log "R2_COUNTERPROOF: 前置失败 —— $f 不含 rdata_hold（不是修复后版本）"; exit 2; }
done
git diff --quiet -- "$AXI" "$TOP" || true

MD5_FIX_AXI="$(md5sum "$AXI" | cut -d' ' -f1)"
MD5_FIX_TOP="$(md5sum "$TOP" | cut -d' ' -f1)"
log "== 修复后 RTL 指纹：axi_master_ctrl=$MD5_FIX_AXI  core_top=$MD5_FIX_TOP"

cp -p "$AXI" "${BK_DIR}/axi_master_ctrl.fixed.v"
cp -p "$TOP" "${BK_DIR}/core_top.fixed.v"

restore() {
    cp -p "${BK_DIR}/axi_master_ctrl.fixed.v" "$AXI"
    cp -p "${BK_DIR}/core_top.fixed.v" "$TOP"
    local a t
    a="$(md5sum "$AXI" | cut -d' ' -f1)"; t="$(md5sum "$TOP" | cut -d' ' -f1)"
    if [ "$a" = "$MD5_FIX_AXI" ] && [ "$t" = "$MD5_FIX_TOP" ]; then
        log "== C) 恢复自证：md5 与备份一致（axi=$a core_top=$t）"
    else
        log "== C) 恢复失败！！ axi=$a（期望 $MD5_FIX_AXI） core_top=$t（期望 $MD5_FIX_TOP）"
    fi
}
trap restore EXIT

#------------------------------------------------------------------------------
# 1. 临时还原旧采样：`git show HEAD:<path>`（只读；HEAD = 修复前提交 68ff5fd）
#------------------------------------------------------------------------------
git show "HEAD:${AXI}" >"${BK_DIR}/axi_master_ctrl.old.v" || exit 2
git show "HEAD:${TOP}" >"${BK_DIR}/core_top.old.v" || exit 2
MD5_OLD_AXI="$(md5sum "${BK_DIR}/axi_master_ctrl.old.v" | cut -d' ' -f1)"
MD5_OLD_TOP="$(md5sum "${BK_DIR}/core_top.old.v" | cut -d' ' -f1)"
cp -p "${BK_DIR}/axi_master_ctrl.old.v" "$AXI"
cp -p "${BK_DIR}/core_top.old.v" "$TOP"
log "== 旧采样 RTL 指纹（git HEAD=68ff5fd）：axi_master_ctrl=$MD5_OLD_AXI  core_top=$MD5_OLD_TOP"
grep -q 'axi_rdata_q = rdata' "$TOP" || { log "R2_COUNTERPROOF: 旧版本还原失败（找不到 axi_rdata_q = rdata）"; exit 2; }
log "== 旧采样已就位（core_top 含 \`axi_rdata_q = rdata\` 实时直通）"

#------------------------------------------------------------------------------
# 2. A) arch-test 非保持型 ⇒ 应 FAIL
#------------------------------------------------------------------------------
log "== A) arch-test I-add-00，R_HOLD_IDLE=0（非保持型 R 通道），旧采样 RTL"
TIMEOUT_CYCLES=300000 bash "${SCRIPT_DIR}/r2_repro_arch_test.sh" I-add-00 0 cp_old_nonhold >"${OUT_DIR}/r2_cp_A.log" 2>&1
rc_a=$?
tail -n 4 "${OUT_DIR}/r2_cp_A.log" | tee -a "${OUT_DIR}/r2_counterproof.log"
if [ "$rc_a" -ne 0 ]; then log "== A) 结果 = FAIL（符合预期：旧采样在非保持型从设备下读错）"; else log "== A) 结果 = 竟然 PASS（反证不成立！）"; fi

#------------------------------------------------------------------------------
# 3. B) M5 TB + 非保持型 DDR 侧 ⇒ 应 FAIL（预算内收尾；旧采样下程序会跑飞/卡死）
#------------------------------------------------------------------------------
log "== B) M5 TB（缩放五步程序）DDR_R_NONHOLD=1，旧采样 RTL（预算 200000 拍）"
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex RUN_TAG=r2_cp_B_oldrtl_nonhold \
    DDR_R_NONHOLD=1 TIMEOUT_CYCLES=200000 PROGRESS_EVERY=50000 \
    bash sw/m5_board/tb/run_tb.sh >"${OUT_DIR}/r2_cp_B.log" 2>&1
rc_b=$?
tail -n 6 "${OUT_DIR}/r2_cp_B.log" | tee -a "${OUT_DIR}/r2_counterproof.log"
if [ "$rc_b" -ne 0 ]; then log "== B) 结果 = FAIL（符合预期：DDR3 uncached 读被晚拍采样打飞）"; else log "== B) 结果 = 竟然 PASS（反证不成立！）"; fi

#------------------------------------------------------------------------------
# 4. 恢复（trap EXIT 里执行；这里显式调一次并核对）
#------------------------------------------------------------------------------
restore
trap - EXIT
grep -q 'axi_rdata_hold' "$TOP" && log "== 修复后 RTL 已就位（core_top 使用 axi_rdata_hold）"

rc=0
[ "$rc_a" -ne 0 ] || rc=1
[ "$rc_b" -ne 0 ] || rc=1
if [ "$rc" -eq 0 ]; then
    log "R2_COUNTERPROOF: OK —— 反证链成立（旧采样在非保持型 R 模型下 A/B 双双 FAIL；RTL 已恢复修复后版本）"
else
    log "R2_COUNTERPROOF: FAIL —— 反证链不完整（见上面 A/B 结果），需人工复核"
fi
exit "$rc"
