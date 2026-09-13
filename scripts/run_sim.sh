#!/usr/bin/env bash
#=============================================================================
# run_sim.sh —— 编译并运行端到端仿真（core_top + sim_axi_slave + TB）
#
#   用法: scripts/run_sim.sh <test_name> [iverilog|verilator] [+wave]
#
#   例:   scripts/run_sim.sh hello
#         scripts/run_sim.sh memtest iverilog +wave
#         scripts/run_sim.sh hello verilator
#
# 行为：
#   * 镜像：sim/tests/out/<test>.hex  → +MEM_LO_INIT（缺失时自动调用 sim/tests/build.sh）
#           sim/tests/out/<test>.hi.hex → +MEM_HI_INIT（arch-test 用，可选）
#   * 日志：sim/log/<test>.log       波形：sim/log/<test>.vcd（+wave 时）
#   * rtl/top/core_top.v 存在则自动加 -DCORE_PRESENT；不存在则走 TB 的 no-core 自检
#     （核尚未编译通过时可用 RV32GC_NO_CORE=1 强制无核，验证 TB/从设备/镜像通路）
#   * 失败（编译错误 / TIMEOUT / TEST FAIL / $fatal）非零退出；成功打印 SIM: PASS <test>
#   * 环境变量：RV32GC_NO_CORE=1 强制无核；RV32GC_TIMEOUT=<n> 覆盖 TB 超时拍数
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ $# -lt 1 ]; then
    echo "用法: $0 <test_name> [iverilog|verilator] [+wave]" >&2
    exit 2
fi

TEST="$1"; shift
TOOL="iverilog"
WAVE=0
for a in "$@"; do
    case "$a" in
        iverilog|verilator) TOOL="$a" ;;
        +wave|wave)         WAVE=1 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

LOG_DIR="sim/log"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$TEST.log"
VCD="$LOG_DIR/$TEST.vcd"

#------------------------------------------------------------------------------
# 1. 镜像
#------------------------------------------------------------------------------
LO_HEX="sim/tests/out/$TEST.hex"
HI_HEX="sim/tests/out/$TEST.hi.hex"

if [ ! -f "$LO_HEX" ] && [ -f "sim/tests/$TEST.c" ]; then
    echo "[run_sim] 未找到 $LO_HEX，先编译测试程序"
    sim/tests/build.sh "$TEST"
fi

PLUSARGS=()
if [ -f "$LO_HEX" ]; then
    PLUSARGS+=("+MEM_LO_INIT=$LO_HEX")
else
    echo "[run_sim] 警告: 无 $LO_HEX（不载入主存镜像）"
fi
if [ -f "$HI_HEX" ]; then
    PLUSARGS+=("+MEM_HI_INIT=$HI_HEX")
    PLUSARGS+=("+sig_dump=$LOG_DIR/$TEST.sig")     # arch-test：比对用签名 dump
fi
[ "$WAVE" -eq 1 ] && PLUSARGS+=("+wave=$VCD")
[ -n "${RV32GC_TIMEOUT:-}" ] && PLUSARGS+=("+timeout=$RV32GC_TIMEOUT")

#------------------------------------------------------------------------------
# 2. 源文件（rtl/**/*.v + sim/tb/*.v），pkg/*.vh 只给 -I
#------------------------------------------------------------------------------
RTL_SRCS=()
while IFS= read -r f; do RTL_SRCS+=("$f"); done < <(find rtl -name '*.v' -type f | sort)
TB_SRCS=()
while IFS= read -r f; do TB_SRCS+=("$f"); done < <(find sim/tb -maxdepth 1 -name '*.v' -type f | sort)

# CORE_OK=1 → 例化核；RV32GC_NO_CORE=1 可强制走无核自检（核尚未跑通时用）
CORE_OK=0
DEFS=()
if [ -f "rtl/top/core_top.v" ] && [ "${RV32GC_NO_CORE:-0}" != "1" ]; then
    CORE_OK=1
    DEFS+=("-DCORE_PRESENT")
    echo "[run_sim] core_top 已就绪 → -DCORE_PRESENT"
elif [ "${RV32GC_NO_CORE:-0}" = "1" ]; then
    echo "[run_sim] RV32GC_NO_CORE=1 → 强制无核模式（仅 TB+从设备自检）"
else
    echo "[run_sim] 注意: rtl/top/core_top.v 不存在 → 无核模式（仅编译/elaboration + 从设备自检）"
fi

echo "[run_sim] test=$TEST tool=$TOOL rtl=${#RTL_SRCS[@]} 个文件 tb=${#TB_SRCS[@]} 个文件"
echo "[run_sim] plusargs: ${PLUSARGS[*]:-<无>}"

#------------------------------------------------------------------------------
# 3. 编译 + 运行
#------------------------------------------------------------------------------
rc=0
case "$TOOL" in
  iverilog)
    VVP="$LOG_DIR/$TEST.vvp"
    if ! iverilog -g2005 -Wall -I rtl/pkg -s tb_smoke -o "$VVP" \
            "${DEFS[@]}" "${RTL_SRCS[@]}" "${TB_SRCS[@]}" > "$LOG.comp" 2>&1; then
        cat "$LOG.comp"
        echo "SIM: FAIL $TEST (iverilog 编译失败)"
        exit 1
    fi
    set +e
    vvp "$VVP" "${PLUSARGS[@]}" 2>&1 | tee "$LOG"
    rc="${PIPESTATUS[0]}"
    set -e
    ;;
  verilator)
    OBJ="$LOG_DIR/obj_$TEST"
    # 注意：Verilator 5.020 在 TB 含 $dumpfile/$dumpvars 但未编译 VM_TRACE 时
    #       会在启动阶段段错误，故 verilator 一律加 --trace（+wave 时才真正写 VCD）
    VFLAGS=(--binary --timing -Wno-fatal -Wno-lint --trace +incdir+rtl/pkg
            --top-module tb_smoke --Mdir "$OBJ" -o "V$TEST")
    verilator "${VFLAGS[@]}" "${DEFS[@]}" "${RTL_SRCS[@]}" "${TB_SRCS[@]}" > "$LOG.comp" 2>&1 || {
        cat "$LOG.comp"; echo "SIM: FAIL $TEST (verilator 编译失败)"; exit 1; }
    set +e
    "$OBJ/V$TEST" "${PLUSARGS[@]}" 2>&1 | tee "$LOG"
    rc="${PIPESTATUS[0]}"
    set -e
    ;;
  *)
    echo "未知工具: $TOOL" >&2; exit 2 ;;
esac

#------------------------------------------------------------------------------
# 4. 判定（退出码 + 日志内容双保险）
#------------------------------------------------------------------------------
if [ "$rc" -ne 0 ] || grep -qE 'TIMEOUT|TEST FAIL|NO-CORE CHECK FAIL|FATAL|%Error|Error:' "$LOG"; then
    echo "SIM: FAIL $TEST (rc=$rc, log=$LOG)"
    exit 1
fi
if ! grep -q 'TB: TEST PASS' "$LOG"; then
    echo "SIM: FAIL $TEST (日志中无 'TB: TEST PASS', log=$LOG)"
    exit 1
fi

if [ "$CORE_OK" -eq 1 ]; then
    echo "SIM: PASS $TEST"
else
    echo "SIM: NOTE $TEST 以无核模式通过（core_top 可编译后去掉 RV32GC_NO_CORE 重跑即为端到端）"
    echo "SIM: PASS $TEST"
fi
echo "[run_sim] 日志: $LOG"
[ "$WAVE" -eq 1 ] && echo "[run_sim] 波形: $VCD"
exit 0
