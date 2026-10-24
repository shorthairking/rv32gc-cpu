#!/usr/bin/env bash
#==============================================================================
# sim/lockstep/run.sh —— Spike 锁步端到端入口（08 §8.3；DUT trace v3）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A-only；本入口不是 2B 锁步，也不为 2B 认证）
# 用法 : ./sim/lockstep/run.sh [选项]
#   （无参数）：跑默认程序 prog/lock_hello.S —— 期望 rc=0 且唯一一行
#               `LOCKSTEP: N/N PASS`（N>=60）
#   --prog <名字|路径>：lock_hello（默认） / csr_hazard（历史 k=0 CSR 缺陷复现程序；
#                       当前树若该旁路已修则按实际比较结果 PASS，不以旧文案当期望）
#                       或任意 .S 路径（须满足 prog/lock_hello.S 头注的结束协议）
#   --march <arch>   : as 的 -march（默认 rv32im_zicsr；FP 程序需 rv32imafdc_zicsr）
#   --pa-mode <m>    : bare（默认，逐相比对 PA=VA）/ translated（无独立 PA oracle
#                      时对 store 显式 CMP_UNSUPPORTED，不默认把 PA 当诊断）
#   --min-commits N  : 比对条数下限（默认 60；csr_hazard 自动降到 10）
#   --self-test      : **只**跑独立 fake-fixture：cmp 用例 + FIFO 单元（不跑
#                      DUT/Spike，不打印正式 `LOCKSTEP: ... PASS`；成功行是
#                      CMP_SELFTEST 与 FFLAGS_FIFO_SELFTEST）
#   --keep           : 兼容旧参数（每次运行本来都保留私有输出）
#
# 一、私有输出（并发安全）
#------------------------------------------------------------------------------
#   每次运行在 `build/functional/lockstep-effects/run.XXXXXX`（mktemp -d）下产出
#   全部中间物与日志；不再写固定的 sim/lockstep/build/dut.trace 等。运行目录内：
#     manifest.inputs.sha256  源码/TB/比对器/程序/link.ld/模型/头文件的 SHA256
#     tool-versions.txt       工具路径、版本、Spike 二进制 SHA256
#     manifest.outputs.sha256  实际产物哈希；BIND.txt 绑定 TB/cmp/run/ELF/DUT/Spike
#     cmdline.txt/RESULT       实际命令 + status/commits/term 结果元数据
#     iverilog.log / dut.log / spike.trace / spike.stderr / cmp.log / run.log
#   结束前用 manifest.inputs.sha256 复核输入未被改动；BIND 行把 TB 源码、比对器、
#   ELF、Spike 日志、DUT trace 的哈希绑定到同一次运行。
#
# 二、流水线（fail-closed）
#------------------------------------------------------------------------------
#   ① as → ld(-T prog/link.ld) → objcopy -O verilog；取 lockstep_spin 符号
#   ② iverilog 编 tb_lockstep（rtl/top/core_top.v + sim/tb/sim_mem_model.sv 只读）
#      → vvp 跑出 v3 dut.trace；TB 自身 C1..C9 全过且恰一行 DUT_TRACE_OK
#   ③ spike 同一条 ELF 跑 commit log（--log-commits --log=spike.trace）
#   ④ cmp_commit.py v3 比较：PC/整数/FP64/store/CSR/fflags/连续 FS/实际 SD + DUT 总线锚点
#   ⑤ 唯一 PASS 行、N>=下限、DUT/Spike 终止证据、哈希绑定与输入不变
#
# 三、判据（任一不满足 ⇒ 非零退出，且绝不输出 PASS 兜底文案）
#------------------------------------------------------------------------------
#   C1 输入工具与关键源存在
#   C2 as/ld/objcopy 成功；ELF 里取到 lockstep_spin
#   C3 iverilog 成功；vvp rc=0；恰一行 `TB_LOCKSTEP: DUT_TRACE_OK `；无 FAIL；
#      dut.trace 非空且含 v3 头
#   C4 spike rc=0；spike.trace 非空且含 commit 行
#   C5 cmp rc=0；stdout 恰一行 `LOCKSTEP: N/N PASS` 且 N>=min；DUT/Spike 终止与
#      DUT 总线 magic/doorbell 证据由 cmp 检查
#   C6 端到端（cmp.log）PASS 行数 == 1
#   C7 manifest 输入复核通过（sha256sum -c）；BIND 行存在且与本次文件一致
#   ★ 本脚本不安装工具、不改 RTL/defs；工具缺失明确报错。
#==============================================================================
set -u -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../.." && pwd -P)"          # 仓库根（rv32gc-cpu/）
PROG_DIR="${HERE}/prog"
OUTROOT="${ROOT}/build/functional/lockstep-effects"

AS="${AS:-/opt/riscv/bin/riscv32-unknown-linux-gnu-as}"
LD="${LD:-/opt/riscv/bin/riscv32-unknown-linux-gnu-ld}"
OBJCOPY="${OBJCOPY:-/opt/riscv/bin/riscv32-unknown-linux-gnu-objcopy}"
NM="${NM:-/opt/riscv/bin/riscv32-unknown-linux-gnu-nm}"
SPIKE="${SPIKE:-/opt/riscv/bin/spike}"
IV="${IV:-iverilog}"
VVP="${VVP:-vvp}"
PY="${PY:-python3}"

ISA="rv32imafdc_zicsr_zifencei_zicntr_zicbom"
SPIKE_PC="0x1C000000"
SPIKE_MEM="0x1C000000:0x1000000,0x80000000:0x10000000,0x1FE00000:0x1000"
SPIKE_INSN_MAX=4096

PROG="lock_hello"
MARCH="rv32im_zicsr"
PA_MODE="bare"
MIN_COMMITS=60
SELF_TEST=0
DUT_TIMEOUT_S="${DUT_TIMEOUT_S:-600}"

while [ $# -gt 0 ]; do
    case "$1" in
        --prog|--march|--pa-mode|--min-commits)
            opt="$1"
            if [ $# -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                echo "run.sh: ${opt} 缺少非空参数值" >&2; exit 2
            fi
            case "${opt}" in
                --prog)        PROG="$2" ;;
                --march)       MARCH="$2" ;;
                --pa-mode)     PA_MODE="$2" ;;
                --min-commits) MIN_COMMITS="$2" ;;
            esac
            shift 2 ;;
        --self-test)   SELF_TEST=1; shift ;;
        --keep)        shift ;;
        -h|--help)     sed -n '2,70p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "run.sh: 未知参数 $1（用 --help 看用法）" >&2; exit 2 ;;
    esac
done

# Reject invalid CLI values before creating any run directory or evidence file.
case "${PA_MODE}" in bare|translated) ;; *)
    echo "run.sh: --pa-mode 只接受 bare 或 translated：${PA_MODE}" >&2; exit 2 ;;
esac
if ! [[ "${MIN_COMMITS}" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "run.sh: --min-commits 必须是 1..999999999 的正整数：${MIN_COMMITS}" >&2; exit 2
fi
if ! [[ "${MARCH}" =~ ^rv32[a-z][a-z0-9_]*$ ]]; then
    echo "run.sh: --march 格式非法：${MARCH}" >&2; exit 2
fi
case "${PROG}" in
    lock_hello|csr_hazard) SRC="${PROG_DIR}/${PROG}.S" ;;
    *.S) SRC="${PROG}" ;;
    *) echo "run.sh: --prog 只接受 lock_hello / csr_hazard / *.S 路径：${PROG}" >&2; exit 2 ;;
esac
[ -s "${SRC}" ] || { echo "run.sh: 程序源不存在或为空：${SRC}" >&2; exit 2; }
[ -s "${PROG_DIR}/link.ld" ] || { echo "run.sh: 链接脚本缺失：${PROG_DIR}/link.ld" >&2; exit 2; }
SRC="$(realpath -e -- "${SRC}")" || { echo "run.sh: 无法解析程序路径：${SRC}" >&2; exit 2; }
STEM="$(basename "${SRC}" .S)"
if [ -x "${AS}" ] && ! printf '.text\n' | "${AS}" -march="${MARCH}" -o /dev/null - >/dev/null 2>&1; then
    echo "run.sh: --march 不是当前 assembler 接受的 ISA：${MARCH}" >&2; exit 2
fi

mkdir -p "${OUTROOT}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$(mktemp -d "${OUTROOT}/run.XXXXXX")" || {
    echo "run.sh: 无法创建私有输出目录 ${OUTROOT}/run.XXXXXX" >&2; exit 2; }
[ -n "${RUN_DIR}" ] && [ -d "${RUN_DIR}" ] || { echo "run.sh: 私有输出目录无效" >&2; exit 2; }
BUILD="${RUN_DIR}"
RUN_LOG="${BUILD}/run.log"

# 完整控制台输出同时落到本轮私有 run.log；退出时关管道并等 tee 刷完。
exec 3>&1 4>&2
exec > >(tee "${RUN_LOG}") 2>&1
cleanup() { exec 1>&3 2>&4; wait; }
trap cleanup EXIT

fail() {
    if [ -n "${BUILD:-}" ] && [ -d "${BUILD}" ]; then
        { echo "status=fail"; echo "reason=$*"; echo "run_id=${RUN_ID:-}"; } \
            > "${BUILD}/RESULT" 2>/dev/null || true
    fi
    echo "LOCKSTEP_RUN: FAIL $*" >&2
    exit 1
}

echo "== sim/lockstep/run.sh（DUT trace v3；2A-only）"
echo "== RUN_ID=${RUN_ID}"
echo "== RUN_DIR=${RUN_DIR}"

#------------------------------------------------------------------------------
# 0. 工具存在性 + 版本快照（缺失明确报错；不由脚本安装）
#------------------------------------------------------------------------------
for t in "${AS}" "${LD}" "${OBJCOPY}" "${NM}" "${SPIKE}"; do
    [ -x "${t}" ] || fail "找不到可执行文件 ${t}（环境缺失；请联系用户配置 /opt/riscv）"
done
command -v "${IV}"  >/dev/null 2>&1 || fail "找不到 iverilog"
command -v "${VVP}" >/dev/null 2>&1 || fail "找不到 vvp"
command -v "${PY}"  >/dev/null 2>&1 || fail "找不到 python3"
command -v timeout >/dev/null 2>&1 || fail "找不到 timeout（coreutils）"
command -v sha256sum >/dev/null 2>&1 || fail "找不到 sha256sum"

{
    echo "RUN_ID=${RUN_ID}"
    echo "DATE=$(date -Is)"
    echo "PWD=${ROOT}"
    echo "UNAME=$(uname -a)"
    echo "AS=${AS}"; "${AS}" --version 2>&1 | head -1
    echo "LD=${LD}"; "${LD}" --version 2>&1 | head -1
    echo "OBJCOPY=${OBJCOPY}"; "${OBJCOPY}" --version 2>&1 | head -1
    echo "NM=${NM}"; "${NM}" --version 2>&1 | head -1
    echo "SPIKE=${SPIKE}"; sha256sum "${SPIKE}"
    echo "IV=${IV}"; "${IV}" -V 2>&1 | head -2
    echo "VVP=${VVP}"; "${VVP}" -V 2>&1 | head -2
    echo "PY=${PY}"; "${PY}" --version 2>&1
    echo "MARCH=${MARCH}"; echo "ISA=${ISA}"
} > "${BUILD}/tool-versions.txt" 2>&1
echo "== 工具版本快照：${BUILD}/tool-versions.txt"

if [ "${STEM}" = "csr_hazard" ] && [ "${MIN_COMMITS}" = "60" ]; then MIN_COMMITS=10; fi

# --self-test：独立 fake fixtures，不跑 DUT/Spike，不打印正式 PASS
if [ "${SELF_TEST}" = "1" ]; then
    command -v "${PY}" >/dev/null 2>&1 || fail "找不到 python3"
    SELFTEST="${HERE}/selftest_cmp.py"
    [ -s "${SELFTEST}" ] || fail "缺少独立自测脚本 ${SELFTEST}"
    echo "== --self-test：独立 fake-fixture 比对器自测（不运行 DUT/Spike）"
    sha256sum "${SELFTEST}" "${HERE}/cmp_commit.py" "${BASH_SOURCE[0]}" \
        > "${BUILD}/selftest.manifest" || fail "生成 selftest 清单失败"
    {
        echo "BIND selftest_cmp.py=$(sha256sum "${SELFTEST}" | awk '{print $1}')"
        echo "BIND cmp_commit.py=$(sha256sum "${HERE}/cmp_commit.py" | awk '{print $1}')"
        echo "BIND run.sh=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
        echo "BIND completion=self-test-only (not a lockstep DUT/Spike run)"
    } > "${BUILD}/selftest.BIND"
    cat "${BUILD}/selftest.BIND"
    # FIFO 单元自测（纯 fake 序列，不依赖 DUT/Spike）
    FIFO_SRC="${HERE}/selftest_fflags_fifo.sv"
    [ -s "${FIFO_SRC}" ] || fail "缺少 ${FIFO_SRC}"
    "${IV}" -g2012 -s selftest_fflags_fifo -o "${BUILD}/fifo.vvp" "${FIFO_SRC}" \
        > "${BUILD}/fifo.iverilog.log" 2>&1 || { tail -20 "${BUILD}/fifo.iverilog.log"; fail "FIFO 单元编译失败"; }
    "${VVP}" "${BUILD}/fifo.vvp" > "${BUILD}/fifo.log" 2>&1
    FIFO_RC=$?
    cat "${BUILD}/fifo.log"
    [ "${FIFO_RC}" -eq 0 ] || fail "FIFO 单元自测 rc=${FIFO_RC}"
    FIFO_PASS="$(grep -cE '^FFLAGS_FIFO_SELFTEST: [0-9]+/[0-9]+ PASS$' "${BUILD}/fifo.log" || true)"
    [ "${FIFO_PASS}" = "1" ] || fail "FIFO 单元成功行数=${FIFO_PASS}（期望恰 1）"
    echo "BIND fifo_unit_sha256=$(sha256sum "${FIFO_SRC}" | awk '{print $1}')" >> "${BUILD}/selftest.BIND"
    "${PY}" "${SELFTEST}" --workdir "${BUILD}/selftest" \
        > "${BUILD}/selftest.log" 2>&1
    ST_RC=$?
    cat "${BUILD}/selftest.log"
    [ "${ST_RC}" -eq 0 ] || fail "--self-test rc=${ST_RC}（见 ${BUILD}/selftest.log）"
    ST_PASS="$(grep -cE '^CMP_SELFTEST: [0-9]+/[0-9]+ PASS$' "${BUILD}/selftest.log" || true)"
    [ "${ST_PASS}" = "1" ] || fail "--self-test 成功行数=${ST_PASS}（期望恰 1）"
    if grep -qE '^LOCKSTEP: [0-9]+/[0-9]+ PASS$' "${BUILD}/selftest.log"; then
        fail "--self-test 不得打印正式锁步 PASS 行"
    fi
    { echo "status=ok"; echo "mode=self-test"; echo "rc=0"; echo "run_id=${RUN_ID}"; } \
        > "${BUILD}/RESULT"
    echo "== --self-test：独立 fake fixtures 通过（未运行 DUT/Spike，不是正式锁步证据）"
    exit 0
fi

#------------------------------------------------------------------------------
# 1. 输入清单哈希（绑定源码/TB/比对器/程序/链接脚本/内存模型/头文件）
#------------------------------------------------------------------------------
RTL_SRCS=()
while IFS= read -r -d '' f; do RTL_SRCS+=("${f#${ROOT}/}"); done < <(find "${ROOT}/rtl" -name '*.v' -print0 | sort -z)
[ "${#RTL_SRCS[@]}" -gt 0 ] || fail "rtl/**/*.v 为空"
RTL_HDRS=()
while IFS= read -r -d '' f; do RTL_HDRS+=("${f#${ROOT}/}"); done < <(
    find "${ROOT}/rtl" \( -name '*.vh' -o -name '*.svh' \) -print0 | sort -z)
[ "${#RTL_HDRS[@]}" -gt 0 ] || fail "rtl/** RTL include header 闭包为空"

cd "${ROOT}" || fail "无法进入仓库根 ${ROOT}"
INPUTS=("${RTL_SRCS[@]}" "${RTL_HDRS[@]}" \
        "sim/lockstep/tb_lockstep.sv" "sim/lockstep/selftest_fflags_fifo.sv" \
        "sim/lockstep/cmp_commit.py" "sim/lockstep/run.sh" \
        "sim/lockstep/selftest_cmp.py" "sim/tb/sim_mem_model.sv" "scripts/env.sh" \
        "$(realpath --relative-to="${ROOT}" "${SRC}")" "sim/lockstep/prog/link.ld")
for f in "${INPUTS[@]}"; do
    [ -s "${f}" ] || { cd "${ROOT}"; fail "输入文件缺失/为空：${f}"; }
done
sha256sum "${INPUTS[@]}" > "${BUILD}/manifest.inputs.sha256" || fail "生成输入哈希清单失败"
for required_hdr in rtl/front4/front4_params.vh rtl/back2/back2_params.vh; do
    grep -Fq "  ${required_hdr}" "${BUILD}/manifest.inputs.sha256" \
        || fail "输入清单缺少实际 include header：${required_hdr}"
done
INPUTS_SHA="$(sha256sum "${BUILD}/manifest.inputs.sha256" | awk '{print $1}')"
echo "== 输入清单：${#INPUTS[@]} 个文件（RTL=${#RTL_SRCS[@]} headers=${#RTL_HDRS[@]}，含scripts/env.sh），manifest SHA256=${INPUTS_SHA}"

ELF="${BUILD}/${STEM}.elf"
HEX="${BUILD}/${STEM}.hex"
OBJ="${BUILD}/${STEM}.o"
DUT_TRACE="${BUILD}/dut.trace"
DUT_LOG="${BUILD}/dut.log"
SPIKE_TRACE="${BUILD}/spike.trace"
SPIKE_ERR="${BUILD}/spike.stderr"
SPIKE_OUT="${BUILD}/spike.stdout"
VVPF="${BUILD}/tb_lockstep.vvp"
CMP_LOG="${BUILD}/cmp.log"

#------------------------------------------------------------------------------
# 2. 汇编 / 链接 / 取 hex / 取符号
#------------------------------------------------------------------------------
echo "== as -march=${MARCH} ${SRC}"
"${AS}" -march="${MARCH}" -o "${OBJ}" "${SRC}" || fail "as 失败（${SRC}；march=${MARCH}）"
"${LD}" -T "${PROG_DIR}/link.ld" -o "${ELF}" "${OBJ}" || fail "ld 失败（${ELF}）"
"${OBJCOPY}" -O verilog --verilog-data-width=4 "${ELF}" "${HEX}" || fail "objcopy 失败"
[ -s "${HEX}" ] || fail "hex 为空：${HEX}"
SPIN_HEX="$("${NM}" "${ELF}" | awk '/[[:space:]]lockstep_spin$/{print $1}')"
[ -n "${SPIN_HEX}" ] || fail "ELF 里找不到 lockstep_spin 符号（程序须定义该标签）"
TERM_PC="0x${SPIN_HEX}"
echo "== ELF=${ELF}；lockstep_spin=0x${SPIN_HEX}（TB 终止点）"

#------------------------------------------------------------------------------
# 3. DUT：iverilog + vvp（只读复用 core_top + sim_mem_model）
#------------------------------------------------------------------------------
echo "== iverilog 编译 tb_lockstep（RTL 源 ${#RTL_SRCS[@]} 个 + sim_mem_model）"
"${IV}" -g2012 -I rtl/pkg -I . -s tb_lockstep \
      -P "tb_lockstep.MIN_COMMITS=${MIN_COMMITS}" \
      -P "tb_lockstep.TERM_PC=32'h${SPIN_HEX}" \
      -P "tb_lockstep.PROG_HEX=\"${HEX}\"" \
      -P "tb_lockstep.DUT_TRACE=\"${DUT_TRACE}\"" \
      -o "${VVPF}" \
      "${RTL_SRCS[@]}" sim/lockstep/tb_lockstep.sv sim/lockstep/selftest_fflags_fifo.sv sim/tb/sim_mem_model.sv \
      > "${BUILD}/iverilog.log" 2>&1 || { tail -30 "${BUILD}/iverilog.log"; fail "iverilog 编译失败"; }
[ -s "${VVPF}" ] || fail "vvp 产物缺失：${VVPF}"

echo "== vvp 运行（timeout ${DUT_TIMEOUT_S}s）"
timeout "${DUT_TIMEOUT_S}" "${VVP}" "${VVPF}" > "${DUT_LOG}" 2>&1
DUT_RC=$?
[ "${DUT_RC}" -eq 0 ] || fail "DUT 仿真 rc=${DUT_RC}（超时/判据未过；见 ${DUT_LOG}）"
DUT_OK_LINES="$(grep -c '^TB_LOCKSTEP: DUT_TRACE_OK ' "${DUT_LOG}" || true)"
[ "${DUT_OK_LINES}" = "1" ] || fail "DUT 日志里 DUT_TRACE_OK 行数=${DUT_OK_LINES}（期望恰好 1；见 ${DUT_LOG}）"
grep -q '^TB_LOCKSTEP: FAIL' "${DUT_LOG}" && fail "DUT 日志出现 TB_LOCKSTEP: FAIL（见 ${DUT_LOG}）"
[ -s "${DUT_TRACE}" ] || fail "dut.trace 为空"
grep -q 'DUT commit trace v3' "${DUT_TRACE}" || fail "dut.trace 不是 v3 格式（见 ${DUT_TRACE}）"
echo "== $(grep -m1 '^TB_LOCKSTEP: DUT_TRACE_OK ' "${DUT_LOG}" | cut -c1-200)"
echo "== $(grep -m1 '^TB_LOCKSTEP_DIAG: 观测域条数' "${DUT_LOG}" | cut -c1-200)"

#------------------------------------------------------------------------------
# 4. Spike：参考模型（同一条 ELF）
#------------------------------------------------------------------------------
echo "== spike（--log-commits --log=spike.trace；ISA=${ISA}）"
timeout "${DUT_TIMEOUT_S}" "${SPIKE}" \
    --instructions="${SPIKE_INSN_MAX}" --pc="${SPIKE_PC}" -l --log-commits \
    --log="${SPIKE_TRACE}" --isa="${ISA}" -m"${SPIKE_MEM}" "${ELF}" \
    > "${SPIKE_OUT}" 2> "${SPIKE_ERR}"
SPIKE_RC=$?
[ "${SPIKE_RC}" -eq 0 ] || fail "spike rc=${SPIKE_RC}（见 ${SPIKE_ERR}）"
[ -s "${SPIKE_TRACE}" ] || fail "spike.trace 为空"
if ! grep -qE '^core[[:space:]]+[0-9]+:' "${SPIKE_TRACE}"; then
    fail "spike.trace 不含 commit 行（见 ${SPIKE_TRACE}）"
fi
echo "== spike stderr（应只有 tohost 提示，可忽略）：$(tr '\n' ' ' < "${SPIKE_ERR}" | cut -c1-160)"

#------------------------------------------------------------------------------
# 5. 比对
#------------------------------------------------------------------------------
echo "== cmp_commit.py v3（PC/整数/FP64/store/CSR/fflags/连续 FS+实际 SD + DUT 总线锚点）"
"${PY}" "${HERE}/cmp_commit.py" \
      --dut "${DUT_TRACE}" --spike "${SPIKE_TRACE}" \
      --term-pc "${TERM_PC}" --min-commits "${MIN_COMMITS}" \
      --pa-mode "${PA_MODE}" \
      > "${CMP_LOG}" 2>&1
CMP_RC=$?
cat "${CMP_LOG}"
[ "${CMP_RC}" -eq 0 ] || fail "比对失败（cmp_commit rc=${CMP_RC}；见 ${CMP_LOG}）"

PASS_LINES="$(grep -cE '^LOCKSTEP: [0-9]+/[0-9]+ PASS$' "${CMP_LOG}" || true)"
[ "${PASS_LINES}" = "1" ] || fail "成功行数=${PASS_LINES}（期望恰好 1；见 ${CMP_LOG}）"
N_CMP="$(sed -nE 's#^LOCKSTEP: ([0-9]+)/([0-9]+) PASS$#\1 \2#p' "${CMP_LOG}" | head -1 | awk '{print $1}')"
[ -n "${N_CMP}" ] || fail "无法从成功行解析 N"
[ "${N_CMP}" -ge "${MIN_COMMITS}" ] || fail "N=${N_CMP} < 下限 ${MIN_COMMITS}"
TOTAL_PASS="$(grep -cE '^LOCKSTEP: [0-9]+/[0-9]+ PASS$' "${CMP_LOG}" || true)"
[ "${TOTAL_PASS}" = "1" ] || fail "端到端成功行数=${TOTAL_PASS}（期望恰好 1）"

#------------------------------------------------------------------------------
# 6. 结果元数据 / 命令清单 / 产物哈希 / BIND / 输入未变复核
#------------------------------------------------------------------------------
{
    echo "status=ok"
    echo "mode=lockstep"
    echo "rc=0"
    echo "commits=${N_CMP}"
    echo "run_id=${RUN_ID}"
    echo "term=TERM_PC term_pc=${TERM_PC} uart_writes=1"
    echo "pa_mode=${PA_MODE}"
} > "${BUILD}/RESULT"
{
    echo "AS=${AS} -march=${MARCH} -o ${OBJ} ${SRC}"
    echo "LD=${LD} -T ${PROG_DIR}/link.ld -o ${ELF} ${OBJ}"
    echo "OBJCOPY=${OBJCOPY} -O verilog --verilog-data-width=4 ${ELF} ${HEX}"
    echo "IVERILOG=${IV} -g2012 -I rtl/pkg -I . -s tb_lockstep -P tb_lockstep.MIN_COMMITS=${MIN_COMMITS} -P tb_lockstep.TERM_PC=32'h${SPIN_HEX} -P tb_lockstep.PROG_HEX=${HEX} -P tb_lockstep.DUT_TRACE=${DUT_TRACE} <RTL_SRCS> sim/lockstep/tb_lockstep.sv sim/lockstep/selftest_fflags_fifo.sv sim/tb/sim_mem_model.sv"
    echo "VVP=${VVP} ${VVPF}"
    echo "SPIKE=${SPIKE} --instructions=${SPIKE_INSN_MAX} --pc=${SPIKE_PC} -l --log-commits --log=${SPIKE_TRACE} --isa=${ISA} -m${SPIKE_MEM} ${ELF}"
    echo "CMP=${PY} ${HERE}/cmp_commit.py --dut ${DUT_TRACE} --spike ${SPIKE_TRACE} --term-pc ${TERM_PC} --min-commits ${MIN_COMMITS} --pa-mode ${PA_MODE}"
} > "${BUILD}/cmdline.txt"

sha256sum "${ELF}" "${HEX}" "${VVPF}" "${DUT_TRACE}" "${SPIKE_TRACE}" \
    "${DUT_LOG}" "${CMP_LOG}" "${BUILD}/iverilog.log" "${BUILD}/cmdline.txt" \
    "${BUILD}/RESULT" \
    > "${BUILD}/manifest.outputs.sha256" || fail "生成产物哈希清单失败"
TB_SHA="$(sha256sum sim/lockstep/tb_lockstep.sv | awk '{print $1}')"
CMP_SHA="$(sha256sum sim/lockstep/cmp_commit.py | awk '{print $1}')"
RUN_SHA="$(sha256sum sim/lockstep/run.sh | awk '{print $1}')"
ELF_SHA="$(sha256sum "${ELF}" | awk '{print $1}')"
DUT_SHA="$(sha256sum "${DUT_TRACE}" | awk '{print $1}')"
SPIKE_SHA="$(sha256sum "${SPIKE_TRACE}" | awk '{print $1}')"
{
    echo "BIND tb_lockstep.sv=${TB_SHA}"
    echo "BIND cmp_commit.py=${CMP_SHA}"
    echo "BIND run.sh=${RUN_SHA}"
    echo "BIND fifo_model_sha256=$(sha256sum sim/lockstep/selftest_fflags_fifo.sv | awk '{print $1}')"
    echo "BIND manifest.inputs=${INPUTS_SHA}"
    echo "BIND elf=${ELF_SHA}"
    echo "BIND dut.trace=${DUT_SHA}"
    echo "BIND spike.trace=${SPIKE_SHA}"
    echo "BIND tool_versions_sha256=$(sha256sum "${BUILD}/tool-versions.txt" | awk '{print $1}')"
    echo "BIND cmdline_sha256=$(sha256sum "${BUILD}/cmdline.txt" | awk '{print $1}')"
    echo "BIND result_sha256=$(sha256sum "${BUILD}/RESULT" | awk '{print $1}')"
    echo "BIND completion=TERM_PC=$(grep -m1 '^TB_LOCKSTEP: DUT_TRACE_OK' "${DUT_LOG}" | sed -n 's/.*commits=\([0-9]*\).*/commits=\1/p')"
} > "${BUILD}/BIND.txt" || fail "生成 BIND 绑定失败"
cat "${BUILD}/BIND.txt"

sha256sum -c "${BUILD}/manifest.inputs.sha256" > "${BUILD}/inputs.recheck.log" 2>&1 \
    || { cat "${BUILD}/inputs.recheck.log"; fail "运行后输入哈希与清单不一致（源码/TB 被改动）"; }
[ "$(grep -c 'OK$' "${BUILD}/inputs.recheck.log")" = "${#INPUTS[@]}" ] \
    || fail "输入复核 OK 行数不等于 ${#INPUTS[@]}（见 ${BUILD}/inputs.recheck.log）"
for b in tb_lockstep.sv cmp_commit.py run.sh manifest.inputs elf dut.trace spike.trace; do
    grep -q "^BIND ${b}=" "${BUILD}/BIND.txt" || fail "BIND 缺少 ${b}"
done

echo "== 证据：$(grep -m1 '^CMP_SUMMARY: trace_v=2' "${CMP_LOG}")"
echo "== 覆盖：$(grep -m1 '^CMP_COVERAGE:' "${CMP_LOG}")"
echo "== 产物目录：${RUN_DIR}"
# ★ 不重复打印成功行：唯一成功行已由上面的 cat ${CMP_LOG} 输出
exit 0
