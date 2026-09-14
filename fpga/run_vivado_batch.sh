#!/usr/bin/env bash
#==============================================================================
# fpga/run_vivado_batch.sh —— Vivado 2023.2 batch **统一入口**（封装三坑）
#==============================================================================
# 用法 : ./fpga/run_vivado_batch.sh <tcl> [tclargs...]
#            <tcl>        : 要执行的 Tcl 脚本（可给相对仓库根的路径，如 fpga/tcl/synth.tcl）
#            [tclargs...] : 透传给 Tcl 的 argv（Vivado 会以 -tclargs 传入）
#         ./fpga/run_vivado_batch.sh --dry-run <tcl> [tclargs...]
#                      : **不启动 Vivado**，只设置环境并打印将执行的完整命令行 + 三坑证据
#                        （用于脚本自检/CI 前置检查；等价于 RV32_VIVADO_DRY_RUN=1）
#         ./fpga/run_vivado_batch.sh --help
#
# 三坑封装（真源：docs/kb/tools-and-flow.md §3；08 §7.1 第 7 条 / §M4 环境门禁）：
#   坑① Ubuntu 24.04 只有 libtinfo.so.6，Vivado 2023.2 需要 libtinfo.so.5
#        ⇒ export LD_LIBRARY_PATH=<VIVADO_ROOT>/lib/lnx64.o/Rhel/9:$LD_LIBRARY_PATH
#          （必须**前置**；重复调用不会重复堆叠）
#   坑② 工程模式自动层次引擎失效，找不到 top
#        ⇒ 本入口配套的 fpga/tcl/synth.tcl / impl.tcl 走**非工程模式**
#          （read_verilog + synth_design -top core_top），非工程模式没有 source 管理，
#          故 `source_mgmt_mode` 不需要设置；若将来改走工程模式，必须补
#          `set_property source_mgmt_mode None [current_project]` 并显式指定 top。
#   坑③ 沙箱 HOME 被污染 / 权限失败
#        ⇒ export HOME=<repo>/.vivado_home（Vivado 的 .Xil/.vivado* 状态写进该目录）
#
# ★ 纪律（08 §7.1 第 7 条）：
#   **禁止**在任何地方直接散落 `vivado -mode batch`；所有 Vivado 调用一律经本脚本，
#   否则三坑会被逐个重新踩一遍（旧项目教训）。
# ★ 本脚本只负责"环境 + 调用 + 日志"，不改变任何 RTL/约束；综合属 M4，脚本自身不做决策。
# ★ 环境变量覆盖（可选）：VIVADO_ROOT / VIVADO_BIN / VIVADO_SETTINGS / VIVADO_LIB_DIR /
#   VIVADO_HOME；默认值来自 scripts/env.sh（唯一真源），env.sh 缺失时回退本文件内置默认。
# 退出码 : 透传 Vivado 的退出码（0 = 成功）；参数/环境检查失败 → 2。
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# 0. 定位仓库根（不依赖调用者 cwd）并载入统一环境
#------------------------------------------------------------------------------
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"                  # <repo>/fpga
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"          # <repo>
ENV_SH="${REPO_ROOT}/scripts/env.sh"

# 载入唯一真源环境（存在则 source；缺失只警告，回退下面内置默认——保证入口始终可用）
if [ -r "$ENV_SH" ]; then
    # shellcheck source=../scripts/env.sh
    . "$ENV_SH"
else
    printf 'WARN: 未找到 %s ⇒ 使用本脚本内置默认路径\n' "$ENV_SH" >&2
fi

VIVADO_ROOT="${VIVADO_ROOT:-/home/shorthair/fpga/Vivado/2023.2}"
VIVADO_BIN="${VIVADO_BIN:-${VIVADO_ROOT}/bin/vivado}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-${VIVADO_ROOT}/settings64.sh}"
VIVADO_LIB_DIR="${VIVADO_LIB_DIR:-${VIVADO_ROOT}/lib/lnx64.o/Rhel/9}"
VIVADO_HOME="${VIVADO_HOME:-${REPO_ROOT}/.vivado_home}"
OUT_DIR="${RV32_OUT_DIR:-${REPO_ROOT}/fpga/out}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
    sed -n '2,30p' "$SCRIPT_PATH" | sed -n 's/^# \{0,1\}//p'
}

#------------------------------------------------------------------------------
# 1. 参数解析
#------------------------------------------------------------------------------
DRY_RUN="${RV32_VIVADO_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --)           shift; break ;;
        -*)           die "未知选项：$1（用 --help 查看用法）" ;;
        *)            break ;;
    esac
done

[ $# -ge 1 ] || { usage >&2; die "缺少参数：<tcl>"; }
TCL_ARG="$1"; shift
TCL_ARGS=( "$@" )

# Tcl 路径解析：绝对路径 → 直接校验；相对路径 → 先按调用者 cwd，再按仓库根
if [ "${TCL_ARG#/}" != "$TCL_ARG" ]; then
    TCL_PATH="$TCL_ARG"
elif [ -f "$TCL_ARG" ]; then
    TCL_PATH="$(cd -- "$(dirname -- "$TCL_ARG")" && pwd -P)/$(basename -- "$TCL_ARG")"
else
    TCL_PATH="${REPO_ROOT}/${TCL_ARG}"
fi
[ -f "$TCL_PATH" ] || die "Tcl 脚本不存在：${TCL_ARG}（已尝试 cwd 与仓库根 ${REPO_ROOT}）"

#------------------------------------------------------------------------------
# 2. 三坑封装（坑①/②/③）
#------------------------------------------------------------------------------
# 坑①：LD_LIBRARY_PATH 前置 Rhel/9（幂等：已在前缀则不再堆叠）
case ":${LD_LIBRARY_PATH:-}:" in
    *":${VIVADO_LIB_DIR}:"*) : ;;   # 已包含 ⇒ 跳过
    *) export LD_LIBRARY_PATH="${VIVADO_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
esac
[ -d "$VIVADO_LIB_DIR" ] || die "坑① 库目录不存在：${VIVADO_LIB_DIR}（检查 VIVADO_ROOT）"

# 坑③：HOME 指向项目内专用目录（先建目录，避免 Vivado 写 .Xil 失败）
mkdir -p "$VIVADO_HOME" "$OUT_DIR"
export HOME="$VIVADO_HOME"

# 工具与环境文件自检
[ -x "$VIVADO_BIN" ]      || die "Vivado 可执行文件不存在：${VIVADO_BIN}"
[ -r "$VIVADO_SETTINGS" ] || die "Vivado 环境脚本不存在：${VIVADO_SETTINGS}"

# 载入 Vivado 环境（settings64.sh 会设置 XILINX_VIVADO/PATH 等；实测在 set -u 下安全）
# shellcheck disable=SC1090
. "$VIVADO_SETTINGS"

printf '== run_vivado_batch.sh: 三坑封装检查\n'
printf '   坑① LD_LIBRARY_PATH 前置 = %s\n' "$VIVADO_LIB_DIR"
printf '   坑② 非工程模式（read_verilog + synth_design）；source_mgmt_mode 仅工程模式需要，非工程模式不适用\n'
printf '   坑③ HOME = %s\n' "$HOME"
printf '   vivado  = %s\n' "$(command -v vivado || printf '%s' "$VIVADO_BIN")"
printf '   tcl     = %s\n' "$TCL_PATH"
printf '   tclargs = %s\n' "${TCL_ARGS[*]:-<无>}"

# 调用前切到仓库根：Tcl 内的相对路径（rtl/**、fpga/**）口径才唯一确定
cd -- "$REPO_ROOT"

CMD=( "$VIVADO_BIN" -mode batch -notrace -nojournal -nolog -source "$TCL_PATH" )
if [ "${#TCL_ARGS[@]}" -gt 0 ]; then
    CMD+=( -tclargs "${TCL_ARGS[@]}" )
fi

if [ "$DRY_RUN" = "1" ]; then
    printf '== DRY-RUN（未启动 Vivado）将执行：\n'
    printf '   LD_LIBRARY_PATH=%s \\\n' "$LD_LIBRARY_PATH"
    printf '   HOME=%s \\\n' "$HOME"
    printf '   %s\n' "${CMD[*]}"
    printf '== DRY-RUN 结束：环境与命令行齐备（本模式不综合、不实现）\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 3. 执行（控制台输出同时落盘 fpga/out/<tcl 名>.vivado.log，便于 M4 判据⑤ 审查）
#------------------------------------------------------------------------------
LOG="${OUT_DIR}/$(basename -- "$TCL_PATH" .tcl).vivado.log"
printf '== run_vivado_batch.sh: 开始执行（日志 %s）\n' "$LOG"
rc=0
"${CMD[@]}" 2>&1 | tee "$LOG" || rc=$?
printf '== run_vivado_batch.sh: vivado 退出码 = %d（日志 %s）\n' "$rc" "$LOG"
if [ "$rc" -ne 0 ]; then
    printf 'ERROR: Vivado batch 失败（rc=%d）；请查日志 %s\n' "$rc" "$LOG" >&2
fi
exit "$rc"
