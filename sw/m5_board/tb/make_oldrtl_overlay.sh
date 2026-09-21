#!/usr/bin/env bash
#==============================================================================
# sw/m5_board/tb/make_oldrtl_overlay.sh —— 「旧 RTL 注入」用的**只读 RTL 拷贝**
#==============================================================================
# 目的：给反证实验（旧采样 RTL + 非保持型 R 通道模型 ⇒ DDR3 回环必红）提供一份
#       **不修改 rtl/** ** 的 RTL 源树：
#         tb/scratch/oldrtl/  = rtl/** 的逐字节拷贝 + 两个文件替换为 **R2 修复前**版本
#         （rtl/axi/axi_master_ctrl.v、rtl/top/core_top.v）
#       run_tb.sh 支持 `RTL_DIR=<目录>` 覆盖 RTL 源目录 ⇒ 编译时读这份拷贝。
#
# 纪律（本任务的 RTL 红线）：
#   · **不修改 rtl/**：本脚本只读 rtl/**（cp -r）与 git 对象库（`git show`，只读）；
#     绝不使用 git checkout/stash/reset/clean。
#   · 脚本前后各打印一次 rtl/**（*.v + *.vh）的 md5 汇总，**必须相同**（自证）。
#   · 旧版本来源 = commit `68ff5fd`（R2 修复前，见 fpga/scratch/R2-report.md §1）；
#     取出后做两项内容断言：旧 axi_master_ctrl.v **不含** rdata_hold；
#     旧 core_top.v **含** `axi_rdata_q = rdata`（实时直通）。
#
# 用法：bash sw/m5_board/tb/make_oldrtl_overlay.sh [--clean]
# 产物：sw/m5_board/tb/scratch/oldrtl/**（RTL 源树拷贝；.gitignore 之外的工作区文件）
# 退出码：0 = overlay 就绪且 rtl/** 未被改动；非 0 = 前置/断言失败
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"          # <rv32gc-cpu>
OVL="${SCRIPT_DIR}/scratch/oldrtl"
OLD_REV="68ff5fd"                                           # R2 修复前的提交（只读 git show）

cd "${REPO}" || exit 2

rtl_fp() { find rtl \( -name '*.v' -o -name '*.vh' \) | sort | xargs md5sum | md5sum | awk '{print $1}'; }

FP_BEFORE="$(rtl_fp)"
printf '== overlay 目标目录 = %s\n' "${OVL}"
printf '== 前置：rtl/** 指纹（*.v+*.vh）= %s\n' "${FP_BEFORE}"

if [ "${1:-}" = "--clean" ]; then rm -rf "${OVL}"; fi
mkdir -p "${OVL}"

#------------------------------------------------------------------------------
# 1. rtl/** 逐字节拷贝（只读源；不改源）
#------------------------------------------------------------------------------
cp -a rtl/. "${OVL}/" || { printf 'ERROR: 拷贝 rtl/** 失败\n' >&2; exit 2; }
printf '== 已拷贝 rtl/** ⇒ %s（%d 个 .v）\n' "${OVL}" "$(find "${OVL}" -name '*.v' | wc -l)"

#------------------------------------------------------------------------------
# 2. 两个文件替换为修复前版本（git show 只读取出；不用 checkout）
#------------------------------------------------------------------------------
git show "${OLD_REV}:rtl/axi/axi_master_ctrl.v" > "${OVL}/axi/axi_master_ctrl.v" || exit 2
git show "${OLD_REV}:rtl/top/core_top.v"        > "${OVL}/top/core_top.v"        || exit 2

#------------------------------------------------------------------------------
# 3. 内容断言（确认"旧采样"真的就位）
#------------------------------------------------------------------------------
if grep -q 'rdata_hold' "${OVL}/axi/axi_master_ctrl.v"; then
    printf 'FAIL: 旧 axi_master_ctrl.v 仍含 rdata_hold（取出的是修复后版本？）\n' >&2; exit 1
fi
printf 'PASS: 旧 axi_master_ctrl.v 不含 rdata_hold（= 修复前）\n'
if ! grep -q 'axi_rdata_q[[:space:]]*=[[:space:]]*rdata;' "${OVL}/top/core_top.v"; then
    printf 'FAIL: 旧 core_top.v 不含 `axi_rdata_q = rdata`（实时直通）⇒ 不是修复前版本\n' >&2; exit 1
fi
printf 'PASS: 旧 core_top.v 含 `axi_rdata_q = rdata`（实时直通 = 修复前采样点）\n'

#------------------------------------------------------------------------------
# 4. 自证：rtl/** 一字未改
#------------------------------------------------------------------------------
FP_AFTER="$(rtl_fp)"
printf '== 后置：rtl/** 指纹（*.v+*.vh）= %s\n' "${FP_AFTER}"
if [ "${FP_BEFORE}" != "${FP_AFTER}" ]; then
    printf 'FAIL: rtl/** 指纹变化 ⇒ 本脚本动过 RTL（不允许）\n' >&2; exit 1
fi
printf 'PASS: rtl/** 指纹前后一致（未修改任何 RTL）\n'
printf 'OVERLAY_OLDRTL: OK（%s；旧版本 = %s）\n' "${OVL}" "${OLD_REV}"
exit 0
