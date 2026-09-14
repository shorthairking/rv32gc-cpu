#!/usr/bin/env bash
#==============================================================================
# scripts/env.sh —— 工具链与环境封装（**唯一真源**；被 scripts/*.sh 与 fpga/*.sh source）
#==============================================================================
# 项目 : rv32gc-cpu（RV32-GC / 阶段二 2A 单发射顺序 5 级基线核）
# 依据 : AGENT.md §2（环境事实：Vivado 2023.2、/opt/riscv GCC 16.1.0、iverilog 12.0、
#        Verilator 5.020）；AGENT.md §3.3（工具口径）；docs/kb/tools-and-flow.md §2/§3；
#        docs/design/08-baseline-5stage.md §3.2（scripts/env.sh 职责）与 §3.3 第 3 条。
# 用法 : `. scripts/env.sh`（或 `source scripts/env.sh`）—— 只设变量/函数，**无任何副作用**，
#        可反复 source；本文件**不得** exit（source 者在 set -e 下会被 return 1 中止）。
#
# ---------------------------------------------------------------------------
# ★ 宏定义纪律（本文件的存在理由之一；见 AGENT.md §3.3 / 08 §3.3）
#   1) **禁止**把 iverilog `-D` 的宏值写成 C 风格 `0x…` 前缀十六进制 —— iverilog 不认，
#      会直接导致编译失败（旧项目踩过的坑）。
#   2) iverilog `-D` 的宏值**必须**是 Verilog 字面量，例如：
#          -DRESET_PC=32'h1C000000          （本设计上板取指口径，见 core_params.vh）
#      —— 注意 shell 里含单引号，必须整体加引号：-D"RESET_PC=32'h1C000000"。
#   3) 定义前先自检：rv32_assert_macro_literal "NAME=VALUE"（见下 §4），不合格即返回非 0。
#   4) 本文件自身**不含**任何 `-D<宏>=C风格十六进制` 形式的宏。
# ---------------------------------------------------------------------------
# 约定 : 仅 bash（用到数组与 BASH_SOURCE）；变量一律 `RV32_`/`VIVADO_` 前缀，避免污染。
#==============================================================================

#------------------------------------------------------------------------------
# 0. 仓库根（按本文件位置推导，不依赖调用者 cwd）
#------------------------------------------------------------------------------
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -e "${BASH_SOURCE[0]}" ]; then
    RV32_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
else
    RV32_ENV_DIR="$(pwd -P)"
fi
RV32_ROOT="$(cd -- "${RV32_ENV_DIR}/.." && pwd -P)" || return 1
export RV32_ENV_DIR RV32_ROOT

#------------------------------------------------------------------------------
# 1. RISC-V 工具链（/opt/riscv；riscv32-unknown-linux-gnu-，GCC 16.1.0）
#    真源口径见 AGENT.md §2；路径缺失时只置变量不报错（用 rv32_env_check 显式检查）
#------------------------------------------------------------------------------
RV32_TOOLCHAIN_ROOT="${RISCV_TOOLCHAIN_ROOT:-/opt/riscv}"
RV32_TOOLCHAIN_BIN="${RV32_TOOLCHAIN_ROOT}/bin"
RV32_TOOLCHAIN_PREFIX="${RISCV_TOOLCHAIN_PREFIX:-riscv32-unknown-linux-gnu-}"
export RV32_TOOLCHAIN_ROOT RV32_TOOLCHAIN_BIN RV32_TOOLCHAIN_PREFIX

RV32_GCC="${RV32_TOOLCHAIN_BIN}/${RV32_TOOLCHAIN_PREFIX}gcc"
RV32_OBJCOPY="${RV32_TOOLCHAIN_BIN}/${RV32_TOOLCHAIN_PREFIX}objcopy"
RV32_OBJDUMP="${RV32_TOOLCHAIN_BIN}/${RV32_TOOLCHAIN_PREFIX}objdump"
RV32_READELF="${RV32_TOOLCHAIN_BIN}/${RV32_TOOLCHAIN_PREFIX}readelf"
RV32_SPIKE="${RV32_TOOLCHAIN_ROOT}/bin/spike"   # 锁步参考模型（NEXT_SESSION §6.5）
export RV32_GCC RV32_OBJCOPY RV32_OBJDUMP RV32_READELF RV32_SPIKE

#------------------------------------------------------------------------------
# 2. 仿真器（iverilog / vvp / Verilator；AGENT.md §2：已安装可用）
#------------------------------------------------------------------------------
RV32_IVERILOG="$(command -v iverilog || true)"
RV32_VVP="$(command -v vvp || true)"
RV32_VERILATOR="$(command -v verilator || true)"
export RV32_IVERILOG RV32_VVP RV32_VERILATOR

#------------------------------------------------------------------------------
# 3. 路径常量（RTL / 仿真 / FPGA 输出；供各脚本复用，避免各自拼路径）
#------------------------------------------------------------------------------
RV32_RTL_DIR="${RV32_ROOT}/rtl"
RV32_PKG_DIR="${RV32_RTL_DIR}/pkg"          # 唯一真源 *.vh（rv32_defs.vh / core_params.vh）
RV32_SIM_DIR="${RV32_ROOT}/sim"
RV32_SIM_UNIT_DIR="${RV32_SIM_DIR}/unit"    # L0 单元 TB（tb_*.sv）
RV32_FPGA_DIR="${RV32_ROOT}/fpga"
RV32_FPGA_TCL_DIR="${RV32_FPGA_DIR}/tcl"
RV32_FPGA_IP_DIR="${RV32_FPGA_DIR}/ip"      # create_ip.tcl 产物（*/*.xci）
RV32_OUT_DIR="${RV32_FPGA_DIR}/out"         # 综合/实现报告与检查点（.gitignore 已忽略）
export RV32_RTL_DIR RV32_PKG_DIR RV32_SIM_DIR RV32_SIM_UNIT_DIR
export RV32_FPGA_DIR RV32_FPGA_TCL_DIR RV32_FPGA_IP_DIR RV32_OUT_DIR

# 平台器件（AGENT.md §2 / docs/kb/platform-facts.md；综合与实现均用同一 part）
VIVADO_PART="${VIVADO_PART:-xc7a200tfbg676-2}"
export VIVADO_PART

#------------------------------------------------------------------------------
# 4. 综合/仿真编译选项与宏字面量自检
#------------------------------------------------------------------------------
# iverilog 公共选项（不含任何 -D）：
#   -g2012            : TB 是 SystemVerilog（sim/unit/tb_*.sv）
#   -I rtl/pkg        : RTL 内部混用两种 include 写法（`` `include "rv32_defs.vh" `` 与
#                       `` `include "rtl/pkg/rv32_defs.vh" ``），两处都要能解析
#   -I <repo root>    : 解析 "rtl/pkg/xxx.vh" 形式的相对包含
# ★ 仿真回归**从不**定义 RV32GC_USE_VIVADO_IP（红线 2：仿真走行为模型，见 08 §7.3）
RV32_IV_FLAGS=( -g2012 -I "${RV32_PKG_DIR}" -I "${RV32_ROOT}" )
export RV32_IV_FLAGS

# 宏名真源（综合定义、仿真不定义）
RV32_IP_MACRO="RV32GC_USE_VIVADO_IP"
export RV32_IP_MACRO

# 校验一个 iverilog -D 实参是否符合"Verilog 字面量"纪律：
#   rv32_assert_macro_literal "RESET_PC=32'h1C000000"  → 0（正确写法）
#   rv32_assert_macro_literal "RESET_PC=<C 风格 0x 前缀>" → 1（iverilog 会炸；本文件不写该形式）
#   rv32_assert_macro_literal "RV32GC_USE_VIVADO_IP"   → 0（无 "=" 的定义标志，允许）
# 无 "=" 视为仅定义标志；有 "=" 时取值不得以 C 风格十六进制前缀（0x / 0X）开头。
rv32_assert_macro_literal() {
    local d="${1:-}" name val
    if [ -z "$d" ]; then
        printf 'ERROR: rv32_assert_macro_literal 需要 "NAME=VALUE" 形式的实参\n' >&2
        return 1
    fi
    case "$d" in
        *=*) ;;
        *) return 0 ;;
    esac
    name="${d%%=*}"
    val="${d#*=}"
    case "$val" in
        0x*|0X*)
            printf 'ERROR: 宏 %s 的取值用了 C 风格十六进制前缀（iverilog 不认）；' "$name" >&2
            printf '请改用 Verilog 字面量，例如 -D%s=32'"'"'h1C000000\n' "$name" >&2
            return 1
            ;;
    esac
    return 0
}

# RTL 源文件全集（按路径排序 ⇒ 编译顺序确定；regress.sh 与综合共用同一份集合）
rv32_rtl_sources() {
    find "${RV32_RTL_DIR}" -type f -name '*.v' | LC_ALL=C sort
}

#------------------------------------------------------------------------------
# 5. Vivado 2023.2（三坑口径；docs/kb/tools-and-flow.md §3）
#    坑① 缺 libtinfo.so.5 → LD_LIBRARY_PATH 前置 $VIVADO_ROOT/lib/lnx64.o/Rhel/9
#    坑② 工程模式自动层次引擎失效 → 非工程模式（read_verilog + synth_design）绕过，
#        工程模式则需 `set_property source_mgmt_mode None [current_project]` + 显式 top
#    坑③ 沙箱 HOME 污染 → HOME=<repo>/.vivado_home
#------------------------------------------------------------------------------
VIVADO_ROOT="${VIVADO_ROOT:-/home/shorthair/fpga/Vivado/2023.2}"
VIVADO_BIN="${VIVADO_BIN:-${VIVADO_ROOT}/bin/vivado}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-${VIVADO_ROOT}/settings64.sh}"
VIVADO_LIB_DIR="${VIVADO_LIB_DIR:-${VIVADO_ROOT}/lib/lnx64.o/Rhel/9}"
VIVADO_HOME="${VIVADO_HOME:-${RV32_ROOT}/.vivado_home}"
export VIVADO_ROOT VIVADO_BIN VIVADO_SETTINGS VIVADO_LIB_DIR VIVADO_HOME

#------------------------------------------------------------------------------
# 6. 自检（显式调用；不自动执行，避免 source 时产生噪音/副作用）
#    rv32_env_check            —— 打印工具可用性表；缺失 ≥1 件返回 1
#    rv32_vivado_env_check     —— 只检查 Vivado 三坑所需路径
#    rv32_print_env            —— 打印本文件导出的关键变量（排障用）
#------------------------------------------------------------------------------
rv32_env_check() {
    local rc=0 t
    for t in "${RV32_GCC}" "${RV32_OBJCOPY}" "${RV32_OBJDUMP}" "${RV32_IVERILOG}" \
             "${RV32_VVP}" "${RV32_VERILATOR}"; do
        if [ -n "$t" ] && [ -x "$t" ]; then
            printf '  OK      %s\n' "$t"
        else
            printf '  MISSING %s\n' "${t:-<命令未找到>}" >&2
            rc=1
        fi
    done
    if [ -x "${RV32_SPIKE}" ]; then printf '  OK      %s\n' "${RV32_SPIKE}"
    else printf '  MISSING %s（锁步参考模型；需用户在沙箱外编译安装）\n' "${RV32_SPIKE}" >&2; fi
    return "$rc"
}

rv32_vivado_env_check() {
    local rc=0
    [ -x "${VIVADO_BIN}" ]      || { printf '  MISSING %s\n' "${VIVADO_BIN}" >&2; rc=1; }
    [ -r "${VIVADO_SETTINGS}" ] || { printf '  MISSING %s\n' "${VIVADO_SETTINGS}" >&2; rc=1; }
    [ -d "${VIVADO_LIB_DIR}" ]  || { printf '  MISSING %s（坑① 库目录）\n' "${VIVADO_LIB_DIR}" >&2; rc=1; }
    [ -n "${VIVADO_HOME}" ]     || { printf '  MISSING VIVADO_HOME\n' >&2; rc=1; }
    [ "$rc" -eq 0 ] && printf '  OK      Vivado 三坑路径齐备（root=%s）\n' "${VIVADO_ROOT}"
    return "$rc"
}

rv32_print_env() {
    cat <<EOF
RV32_ROOT            = ${RV32_ROOT}
RV32_TOOLCHAIN_ROOT  = ${RV32_TOOLCHAIN_ROOT}
RV32_TOOLCHAIN_PREFIX= ${RV32_TOOLCHAIN_PREFIX}
RV32_GCC             = ${RV32_GCC}
RV32_IVERILOG        = ${RV32_IVERILOG:-<未找到>}
RV32_VVP             = ${RV32_VVP:-<未找到>}
RV32_VERILATOR       = ${RV32_VERILATOR:-<未找到>}
RV32_SPIKE           = ${RV32_SPIKE}
RV32_IV_FLAGS        = ${RV32_IV_FLAGS[*]}
RV32_RTL_DIR         = ${RV32_RTL_DIR}
RV32_SIM_UNIT_DIR    = ${RV32_SIM_UNIT_DIR}
RV32_OUT_DIR         = ${RV32_OUT_DIR}
VIVADO_ROOT          = ${VIVADO_ROOT}
VIVADO_BIN           = ${VIVADO_BIN}
VIVADO_SETTINGS      = ${VIVADO_SETTINGS}
VIVADO_LIB_DIR       = ${VIVADO_LIB_DIR}
VIVADO_HOME          = ${VIVADO_HOME}
VIVADO_PART          = ${VIVADO_PART}
EOF
}

# 可选：source 时打印（默认安静，避免污染 regress 输出）
if [ "${RV32_ENV_VERBOSE:-0}" = "1" ]; then
    rv32_print_env
fi
