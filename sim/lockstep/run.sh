#!/usr/bin/env bash
#==============================================================================
# sim/lockstep/run.sh —— Spike 锁步端到端入口（08 §8.3）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）
# 用法 : ./sim/lockstep/run.sh [选项]
#   （无参数）：跑默认程序 prog/lock_hello.S —— 期望 rc=0 且唯一一行
#               `LOCKSTEP: N/N PASS`（N>=60）
#   --prog <名字|路径>：lock_hello（默认） / csr_hazard（CSR 缺陷复现，**期望 FAIL**）
#                       或任意 .S 路径（须满足 prog/lock_hello.S 头注的结束协议）
#   --min-commits N : 比对条数下限（默认 60；csr_hazard 会自动降到 10）
#   --self-test     : 反证自测——把 dut.trace 复制一份并**故意改一条 rd 写值**，
#                     要求 cmp_commit.py 报分歧且非零退出；随后还原（不污染正常产物）
#   --keep          : 保留中间产物（默认就保留在 sim/lockstep/build/）
#
# 一、流水线（四步，全部 fail-closed）
#------------------------------------------------------------------------------
#   ① 汇编/链接/取 hex：as → ld(-T prog/link.ld) → objcopy -O verilog
#      · .boot @0x1C00_0000（2 条复位跳转桩：本核 RESET_PC 固定为 XIP 主窗口，
#        生产 RTL 禁止 0x8000_0000 别名 ⇒ 用桩进入仿真布局）
#      · .text @0x8000_0000（程序主体，Spike 习惯布局）
#      · 取 lockstep_spin 符号地址作 TB 的终止 PC（TERM_PC）
#   ② DUT：iverilog 编 tb_lockstep（复用 rtl/top/core_top.v + sim/tb/sim_mem_model.sv，
#      只读），vvp 跑出提交 trace `build/dut.trace`（每提交一条一行）
#   ③ Spike：同一条 ELF 跑参考模型，commit 轨迹落 `build/spike.trace`
#   ④ 比对：python3 cmp_commit.py 逐条比对（PC 必须相等 + rd 写值相等），
#      输出唯一 `LOCKSTEP: N/N PASS`
#
# 二、Spike 调用口径（**本机 1.1.1-dev 实测**，与 08 §8.3 的模板差异在此说明）
#------------------------------------------------------------------------------
#   spike --instructions=4096 --pc=0x1C000000 -l --log-commits --log=<trace> \
#         --isa=rv32imafdc_zicsr_zifencei_zicntr_zicbom \
#         -m0x1C000000:0x1000000,0x80000000:0x10000000,0x1FE00000:0x1000 <elf>
#   · `--log-commits`：**本机实测 commit 行落在 `--log=<file>` 文件里**（与
#     AGENT.md §3.1"输出在 stderr"的旧口径并存：不给 --log= 时确实在 stderr）。
#     本脚本按任务口径用文件，并在 cmp_commit.py 里按正则挑出 commit 行
#     （--log 文件里反汇编行与 commit 行交错）。
#   · `--pc=0x1C000000`：DUT 的复位取指地址。不给 --pc 时 Spike 会先跑它内置 boot
#     ROM（0x1000 起 5 条）再跳到 ELF 入口，轨迹前 5 条无法与 DUT 对齐（实测）。
#   · `-m` 三个区域：0x1C00_0000（跳转桩）、**0x8000_0000（任务指定的仿真布局）**、
#     0x1FE0_0000（UART 结束铃）。UART 区**必须**映射：否则 Spike 在结束铃那条
#     store 上取 access fault 并停止，DUT/Spike 无法跑到同一点（实测）。
#   · `--instructions=4096`：程序末尾是死循环（DUT 侧由 TERM_PC 终止），给 Spike 上限。
#
# 三、判据（任一不满足 ⇒ 非零退出，且**绝不**输出 PASS 兜底文案）
#------------------------------------------------------------------------------
#   C1 三个输入文件存在且非空（run.sh / cmp_commit.py / prog/lock_hello.S 由调用方保证）
#   C2 as/ld/objcopy 全部成功；ELF 里取到 lockstep_spin 符号
#   C3 iverilog 编译成功；vvp rc=0 且 stdout 里**恰好一行** `TB_LOCKSTEP: DUT_TRACE_OK`
#      （TB 自身 6 项判据全过；见 tb_lockstep.sv §四），且无 `TB_LOCKSTEP: FAIL`
#   C4 spike rc=0；`build/spike.trace` 非空且含 commit 行
#   C5 cmp_commit.py rc=0，摘要里 dut_commits==compared，且 stdout 里**恰好一行**
#      `LOCKSTEP: N/N PASS` 且 N>=min-commits
#   C6 端到端 stdout 里 PASS 行数 == 1（防"多处兜底 PASS"）
#==============================================================================
set -u -o pipefail

#------------------------------------------------------------------------------
# 0. 路径/环境
#------------------------------------------------------------------------------
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../.." && pwd -P)"          # 仓库根（rv32gc-cpu/）
BUILD="${HERE}/build"
PROG_DIR="${HERE}/prog"

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
MIN_COMMITS=60
SELF_TEST=0
DUT_TIMEOUT_S="${DUT_TIMEOUT_S:-600}"

while [ $# -gt 0 ]; do
    case "$1" in
        --prog)        PROG="${2:-}"; shift 2 ;;
        --min-commits) MIN_COMMITS="${2:-}"; shift 2 ;;
        --self-test)   SELF_TEST=1; shift ;;
        --keep)        shift ;;
        -h|--help)     sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "run.sh: 未知参数 $1（用 --help 看用法）" >&2; exit 2 ;;
    esac
done

# 程序名 → 路径（允许直接给 .S 路径）
case "${PROG}" in
    lock_hello|csr_hazard)  SRC="${PROG_DIR}/${PROG}.S" ;;
    *.S)                    SRC="${PROG}" ;;
    *) echo "run.sh: --prog 只接受 lock_hello / csr_hazard / *.S 路径：${PROG}" >&2; exit 2 ;;
esac
STEM="$(basename "${SRC}" .S)"
# csr_hazard 是短程序（复现用）⇒ 默认门槛降到 10；显式 --min-commits 优先
if [ "${STEM}" = "csr_hazard" ] && [ "${MIN_COMMITS}" = "60" ]; then MIN_COMMITS=10; fi

mkdir -p "${BUILD}"
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

fail() { echo "LOCKSTEP_RUN: FAIL $*" >&2; exit 1; }

# 工具存在性（环境缺失 ⇒ 明确报错，不静默跳过；AGENT.md §0.4 不由脚本安装）
for t in "${AS}" "${LD}" "${OBJCOPY}" "${NM}" "${SPIKE}"; do
    [ -x "${t}" ] || fail "找不到可执行文件 ${t}（环境缺失；请联系用户配置 /opt/riscv）"
done
command -v "${IV}"  >/dev/null 2>&1 || fail "找不到 iverilog"
command -v "${VVP}" >/dev/null 2>&1 || fail "找不到 vvp"
command -v "${PY}"  >/dev/null 2>&1 || fail "找不到 python3"
command -v timeout >/dev/null 2>&1 || fail "找不到 timeout（coreutils）"

echo "== sim/lockstep/run.sh：PROG=${STEM}（${SRC}）"
echo "== 仓库根：${ROOT}"
echo "== 产物目录：${BUILD}"

#------------------------------------------------------------------------------
# 1. 汇编 / 链接 / 取 hex / 取符号
#------------------------------------------------------------------------------
"${AS}" -march=rv32im_zicsr -o "${OBJ}" "${SRC}" || fail "as 失败（${SRC}）"
"${LD}" -T "${PROG_DIR}/link.ld" -o "${ELF}" "${OBJ}" || fail "ld 失败（${ELF}）"
"${OBJCOPY}" -O verilog --verilog-data-width=4 "${ELF}" "${HEX}" || fail "objcopy 失败"
[ -s "${HEX}" ] || fail "hex 为空：${HEX}"

SPIN_HEX="$("${NM}" "${ELF}" | awk '/[[:space:]]lockstep_spin$/{print $1}')"
[ -n "${SPIN_HEX}" ] || fail "ELF 里找不到 lockstep_spin 符号（程序须定义该标签）"
TERM_PC="0x${SPIN_HEX}"
echo "== ELF=${ELF}；lockstep_spin=0x${SPIN_HEX}（TB 终止点）"

#------------------------------------------------------------------------------
# 2. DUT：iverilog + vvp（复用 core_top + sim_mem_model，只读）
#------------------------------------------------------------------------------
RTL_SRCS=()
while IFS= read -r -d '' f; do RTL_SRCS+=("$f"); done < <(find "${ROOT}/rtl" -name '*.v' -print0 | sort -z)
[ "${#RTL_SRCS[@]}" -gt 0 ] || fail "rtl/**/*.v 为空"

echo "== iverilog 编译 tb_lockstep（RTL 源 ${#RTL_SRCS[@]} 个 + sim/tb/sim_mem_model.sv）"
( cd "${ROOT}" && "${IV}" -g2012 -I rtl/pkg -I . -s tb_lockstep \
      -P "tb_lockstep.MIN_COMMITS=${MIN_COMMITS}" \
      -P "tb_lockstep.TERM_PC=32'h${SPIN_HEX}" \
      -P "tb_lockstep.PROG_HEX=\"sim/lockstep/build/${STEM}.hex\"" \
      -P "tb_lockstep.DUT_TRACE=\"sim/lockstep/build/dut.trace\"" \
      -o "sim/lockstep/build/tb_lockstep.vvp" \
      "${RTL_SRCS[@]}" sim/lockstep/tb_lockstep.sv sim/tb/sim_mem_model.sv ) \
      > "${BUILD}/iverilog.log" 2>&1 || { tail -20 "${BUILD}/iverilog.log"; fail "iverilog 编译失败"; }
[ -s "${VVPF}" ] || fail "vvp 产物缺失：${VVPF}"

echo "== vvp 运行（timeout ${DUT_TIMEOUT_S}s）"
( cd "${ROOT}" && timeout "${DUT_TIMEOUT_S}" "${VVP}" "sim/lockstep/build/tb_lockstep.vvp" ) \
      > "${DUT_LOG}" 2>&1
DUT_RC=$?
[ "${DUT_RC}" -eq 0 ] || fail "DUT 仿真 rc=${DUT_RC}（超时/判据未过；见 ${DUT_LOG}）"
DUT_OK_LINES="$(grep -c '^TB_LOCKSTEP: DUT_TRACE_OK ' "${DUT_LOG}" || true)"
[ "${DUT_OK_LINES}" = "1" ] || fail "DUT 日志里 DUT_TRACE_OK 行数=${DUT_OK_LINES}（期望恰好 1；见 ${DUT_LOG}）"
grep -q '^TB_LOCKSTEP: FAIL' "${DUT_LOG}" && fail "DUT 日志出现 TB_LOCKSTEP: FAIL（见 ${DUT_LOG}）"
[ -s "${DUT_TRACE}" ] || fail "dut.trace 为空"
echo "== $(grep -m1 '^TB_LOCKSTEP: DUT_TRACE_OK ' "${DUT_LOG}" | cut -c1-120)"

#------------------------------------------------------------------------------
# 3. Spike：参考模型（同一条 ELF）
#------------------------------------------------------------------------------
echo "== spike（--log-commits --log=spike.trace；ISA=${ISA}）"
timeout "${DUT_TIMEOUT_S}" "${SPIKE}" \
    --instructions="${SPIKE_INSN_MAX}" --pc="${SPIKE_PC}" -l --log-commits \
    --log="${SPIKE_TRACE}" --isa="${ISA}" -m"${SPIKE_MEM}" "${ELF}" \
    > "${SPIKE_OUT}" 2> "${SPIKE_ERR}"
SPIKE_RC=$?
[ "${SPIKE_RC}" -eq 0 ] || fail "spike rc=${SPIKE_RC}（见 ${SPIKE_ERR}）"
[ -s "${SPIKE_TRACE}" ] || fail "spike.trace 为空"
echo "== spike stderr（应只有 tohost 提示，可忽略）：$(tr '\n' ' ' < "${SPIKE_ERR}" | cut -c1-120)"

#------------------------------------------------------------------------------
# 4. 比对
#------------------------------------------------------------------------------
echo "== cmp_commit.py（逐条比对 PC + rd 写值）"
"${PY}" "${HERE}/cmp_commit.py" \
      --dut "${DUT_TRACE}" --spike "${SPIKE_TRACE}" \
      --term-pc "${TERM_PC}" --min-commits "${MIN_COMMITS}" \
      > "${CMP_LOG}" 2>&1
CMP_RC=$?
cat "${CMP_LOG}"

if [ "${SELF_TEST}" = "1" ]; then
    #------------------------------------------------------------------
    # 4b. 反证自测：故意改一条 rd 写值 ⇒ cmp 必须报分歧且非零退出
    #     （在**副本**上做，不动正式 dut.trace；见头注 --self-test）
    #------------------------------------------------------------------
    echo "== --self-test：故意篡改 dut.trace 副本的一条 rd 写值，要求比对器报分歧"
    BAD="${BUILD}/dut.selftest.trace"
    cp -f "${DUT_TRACE}" "${BAD}"
    "${PY}" - "${BAD}" <<'PYEOF' || fail "自测：篡改脚本失败"
import re, sys
p = sys.argv[1]
lines = open(p, 'r', encoding='utf-8').read().splitlines(True)
# 挑**中间**一条 wen=1（写架构寄存器）的提交，改掉其 wdata 若干位：
# 这样首分歧定位必须落在中段（而不是恰好在第 0 条），自测更有说服力。
cand = []
for i, l in enumerate(lines):
    m = re.match(r'^(\d+) pc=0x([0-9a-f]{8}) wen=1 rd=(\d+) wdata=0x([0-9a-f]{8})$', l.rstrip('\n'))
    if m and int(m.group(3)) != 0:
        cand.append((i, m))
if not cand:
    print('selftest: 找不到可篡改的 wen=1 行'); sys.exit(1)
i, m = cand[len(cand) // 2]
val = int(m.group(4), 16) ^ 0x5A5A5A5A          # 翻掉若干位，制造 rd 写值分歧
lines[i] = '%s pc=0x%s wen=1 rd=%s wdata=0x%08x\n' % (
    m.group(1), m.group(2), m.group(3), val)
print('selftest: 篡改第 %s 条（pc=0x%s rd=x%s）wdata: 0x%08x → 0x%08x' % (
    m.group(1), m.group(2), m.group(3), int(m.group(4), 16), val))
open(p, 'w', encoding='utf-8').writelines(lines)
PYEOF
    "${PY}" "${HERE}/cmp_commit.py" --dut "${BAD}" --spike "${SPIKE_TRACE}" \
          --term-pc "${TERM_PC}" --min-commits "${MIN_COMMITS}" > "${BUILD}/cmp.selftest.log" 2>&1
    BAD_RC=$?
    sed -n '1,14p' "${BUILD}/cmp.selftest.log"
    if [ "${BAD_RC}" -eq 0 ]; then
        rm -f "${BAD}"
        fail "--self-test 失败：篡改 rd 写值后比对器仍然通过（rc=0）——比对器没有真的在比"
    fi
    grep -q 'CMP_DIVERGENCE' "${BUILD}/cmp.selftest.log" || {
        rm -f "${BAD}"
        fail "--self-test 失败：比对器非零退出但未报 CMP_DIVERGENCE";
    }
    if grep -q 'PASS' "${BUILD}/cmp.selftest.log"; then
        rm -f "${BAD}"
        fail "--self-test 失败：篡改后仍打印了成功行"
    fi
    rm -f "${BAD}"                     # 还原：删除副本（正式 dut.trace 从未被改）
    echo "== --self-test：反证成立（篡改一条 rd 写值 ⇒ 报分歧 + rc=${BAD_RC}）"
fi

#------------------------------------------------------------------------------
# 5. 汇总判定（C5/C6：PASS 行必须唯一且 N>=下限）
#------------------------------------------------------------------------------
if [ "${CMP_RC}" -ne 0 ]; then
    fail "比对失败（cmp_commit rc=${CMP_RC}；见 ${CMP_LOG}）"
fi
PASS_LINES="$(grep -cE '^LOCKSTEP: [0-9]+/[0-9]+ PASS$' "${CMP_LOG}" || true)"
[ "${PASS_LINES}" = "1" ] || fail "成功行数=${PASS_LINES}（期望恰好 1；见 ${CMP_LOG}）"
N_CMP="$(sed -nE 's#^LOCKSTEP: ([0-9]+)/([0-9]+) PASS$#\1 \2#p' "${CMP_LOG}" | head -1 | awk '{print $1}')"
[ -n "${N_CMP}" ] || fail "无法从成功行解析 N"
[ "${N_CMP}" -ge "${MIN_COMMITS}" ] || fail "N=${N_CMP} < 下限 ${MIN_COMMITS}"

# 端到端唯一 PASS（把本轮所有输出算一遍：cmp 日志 + 本脚本已输出的行）
TOTAL_PASS="$( { cat "${CMP_LOG}"; } | grep -cE '^LOCKSTEP: [0-9]+/[0-9]+ PASS$' || true)"
[ "${TOTAL_PASS}" = "1" ] || fail "端到端成功行数=${TOTAL_PASS}（期望恰好 1）"

echo "== 证据：$(grep -m1 '^CMP_SUMMARY: dut_commits' "${CMP_LOG}")"
echo "== 产物：${DUT_TRACE} / ${SPIKE_TRACE} / ${CMP_LOG}"
# ★ 不再重复打印成功行：唯一成功行已由上面的 cat ${CMP_LOG} 输出（端到端恰好一次）
exit 0
