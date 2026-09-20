#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/t3_run.sh —— T3 跑批包装（临时，非交付物）
#==============================================================================
# 用法：./fpga/scratch/t3_run.sh <tag> <tcl> [tclargs...]
# 作用：经统一入口 ./fpga/run_vivado_batch.sh 跑一步 Vivado，并把 **stdout/stderr**
#       与退出码同时留档到 fpga/out/t3_<tag>.stdout.txt（run_vivado_batch.sh 自己
#       只留 Vivado 的 tee 日志 <tcl名>.vivado.log，不含入口的环境打印与退出码）。
# 目的：T3 交付要求"各步命令与输出节选 + rc" 可复现；本脚本只做记录，不改流程。
# ★ 不改 RTL、不改约束；只读跑流程。
#==============================================================================
set -uo pipefail

TAG="${1:?用法: t3_run.sh <tag> <tcl> [tclargs...]}"; shift
TCL="${1:?缺 tcl}"; shift

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUT="${REPO_ROOT}/fpga/out"
mkdir -p "$OUT"
LOG="${OUT}/t3_${TAG}.stdout.txt"

{
    printf '################################################################\n'
    printf '# T3 step : %s\n' "$TAG"
    printf '# 命令    : ./fpga/run_vivado_batch.sh %s %s\n' "$TCL" "$*"
    printf '# 开始    : %s\n' "$(date -Is)"
    printf '# RTL md5 : %s\n' "$(find "${REPO_ROOT}/rtl" \( -name '*.v' -o -name '*.vh' \) | sort | xargs md5sum | md5sum | awk '{print $1}')"
    printf '################################################################\n'
} | tee "$LOG"

start=$SECONDS
( cd "$REPO_ROOT" && ./fpga/run_vivado_batch.sh "$TCL" "$@" ) 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
{
    printf '################################################################\n'
    printf '# T3 step : %s  退出码 = %d  用时 = %d s\n' "$TAG" "$rc" "$((SECONDS - start))"
    printf '# 结束    : %s\n' "$(date -Is)"
    printf '################################################################\n'
} | tee -a "$LOG"
exit "$rc"
