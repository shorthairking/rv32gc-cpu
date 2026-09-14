#!/usr/bin/env bash
#==============================================================================
# run_vivado_batch.sh —— 批处理方式跑 Vivado（默认 2023.2 本地 Linux 版）
#
# 为什么要这个包装脚本：
#   ① 本会话的 DSH 文件沙箱只允许写 workspace（/home/shorthair/dsh/rv32-cpu）。
#      Vivado 启动时会写 `$HOME/.Xilinx/Vivado/<ver>/app.xml`，在沙箱下会被拒绝并
#      直接 abort（实测：`Failed to create directory to save app.xml`）。
#      这里把 HOME 重定向到 /tmp（沙箱放行的临时区）⇒ 无需提权即可跑。
#   ② 本机是 Ubuntu 24.04，而 Vivado 2023.2 自带的依赖目录只有 Ubuntu/{18,20,22}、
#      Rhel/{8,9}、SuSE —— 加载器按发行版找不到匹配目录，于是 `librdi_commontasks.so`
#      加载失败：`libtinfo.so.5: cannot open shared object file`（系统只有 libtinfo.so.6）。
#      修法：把 `lib/lnx64.o/Rhel/9` 加进 LD_LIBRARY_PATH（该目录**只有** libtinfo.so.5，
#      不会覆盖其它系统库）；优先级放在 Vivado 自己库目录之后。
#   ③ 固化 Vivado 版本/路径，避免每轮手敲 settings64.sh。
#
# 用法：
#   fpga/run_vivado_batch.sh <script.tcl> [tclargs...]
# 环境变量：
#   VIVADO_VER=2023.2                 Vivado 版本（目录名）
#   VIVADO_ROOT=/home/shorthair/fpga/Vivado/<ver>
#   VIVADO_HOME=/tmp/vivado_home_<ver>  重定向后的 HOME
#   VIVADO_JOBS（不经本脚本使用，由 tcl 内的 -jobs 决定）
#==============================================================================
set -u
VIVADO_VER=${VIVADO_VER:-2023.2}
VIVADO_ROOT=${VIVADO_ROOT:-/home/shorthair/fpga/Vivado/$VIVADO_VER}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# HOME 指向工作区内目录（已 gitignore）：既绕开沙箱对 ~/.Xilinx 的拒绝，又是本机实测可行的口径
export HOME=${VIVADO_HOME:-$REPO_ROOT/.vivado_home}

if [ ! -x "$VIVADO_ROOT/bin/vivado" ]; then
    echo "ERROR: 找不到 Vivado: $VIVADO_ROOT/bin/vivado" >&2
    exit 1
fi
if [ $# -lt 1 ]; then
    echo "用法: $0 <script.tcl> [tclargs...]" >&2
    exit 1
fi

TCL=$1; shift
mkdir -p "$HOME"

echo "== run_vivado_batch: ver=$VIVADO_VER root=$VIVADO_ROOT HOME=$HOME tcl=$TCL args=$* =="
# shellcheck disable=SC1091
source "$VIVADO_ROOT/settings64.sh"
# Ubuntu 24.04 无 libtinfo.so.5（Vivado 自带目录里只有 Ubuntu/18|20|22）⇒ 借 Rhel/9 的那一份
TINFO_DIR="$VIVADO_ROOT/lib/lnx64.o/Rhel/9"
if [ -f "$TINFO_DIR/libtinfo.so.5" ]; then
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$TINFO_DIR"
fi
cd "$(dirname "$TCL")/../.." 2>/dev/null || true
exec "$VIVADO_ROOT/bin/vivado" -mode batch -notrace -source "$TCL" -tclargs "$@"
