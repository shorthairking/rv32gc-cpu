#!/usr/bin/env bash
#==============================================================================
# sim/arch_test/run.sh —— 2A 基线核的 arch-test（ACT4）底座入口
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A；docs/design/08-baseline-5stage.md §8.2/§8.2.1、
#        docs/design/07-verification.md §4/§9.2 的 V-3/V-4/V-5）
#
# 【这个脚本测什么】
#   把 riscv-arch-test（ACT4 版）的 rv32i 非特权用例，端到端跑在**本核 RTL**上：
#     ① 编译用例    ：riscv32-unknown-linux-gnu-gcc + 本目录 link.ld（+ boot_stub.S 复位桩）
#     ② Spike 参考  ：同一份 ELF 在 Spike 上跑出参考签名（`+signature-granularity=4`，每行一字）
#     ③ DUT 仿真    ：ELF → hex → sim/tb/tb_arch_test.sv（例化 core_top）→ 导出 DUT 签名
#     ④ 逐行比对    ：DUT 签名数据列 vs Spike 参考签名数据列，逐行比、不带任何模糊匹配
#
# 【怎么判（"未捕获即失败"，AGENT.md §0.6 / 08 §8.1）】
#   · 每个用例只有走完 ①②③④ 且**每一步都被显式捕获**才可能 PASS；
#   · 步骤失败/输出缺失/行数不符/超时/未捕获 ⇒ 该用例 FAIL 并 rc≠0；
#   · **兜底与默认分支的文案里不含 PASS 字样**：唯一成功文案是
#       `RV32_ARCH_TEST: <用例> PASS (compared=<n> lines, first_diff=none)`
#     以及全部用例通过后的 `RV32_ARCH_TEST_RUN: PASS (<n>/<n>)`；
#   · 本脚本不含任何"匹配不到也算过"的逻辑（旧项目假 PASS 事故的教训）。
#
# 【用法】
#   ./sim/arch_test/run.sh I-nop-00                  # 单个用例（名字/相对路径均可）
#   ./sim/arch_test/run.sh I-add-00 M-add-00         # 多个用例
#   ./sim/arch_test/run.sh --list                    # 列出可选用例（含是否被排除）
#   ./sim/arch_test/run.sh --check-exclude           # 校验 exclude.list 每条规则都有命中
#   ./sim/arch_test/run.sh --directed dm_csr_raw     # 跑 sim/arch_test/*.S 定向程序（非 ACT 用例）
#   ./sim/arch_test/run.sh --group I                 # 组批量模式（见下）：按组跑一批用例
#   ./sim/arch_test/run.sh --group rv32i/I           #   组名 = 目录名 / 相对路径 / 用例名 glob
#   ./sim/arch_test/run.sh --group 'I-a*' --limit 5  #   冒烟：只跑过滤后的前 5 例
#   ./sim/arch_test/run.sh --group rv32i/I --jobs 16 #   组模式多进程并行：16 个并发进程（默认 nproc）
#   选项：-v（打印 TB 心跳/提交诊断）、--timeout-vvp N、--cycles N、--limit N、--jobs N
#
# 【组批量模式（--group）】
#   组名解析（按 arch-test 仓库实际目录结构）：
#     · 目录名     ：`I` / `M` / `Zicsr` / `rv32i` / `priv/Sv` …… ⇒ 该目录（含子目录）全部用例；
#     · 相对路径   ：`tests/rv32i/I` ⇒ 同义；
#     · 用例名 glob：`I-a*` / `I-nop-00` / `M-*`（可带 `tests/…` 前缀路径 glob）。
#   执行口径：候选清单 → **按 exclude.list 逐条过滤**（被过滤的每条都打印 INFO，绝不静默丢弃）
#             → --limit 截断 → 逐例走与单例模式**完全相同**的判定流水线（同超时/同判据）→ 聚合。
#   并行（--jobs N，N>1）：候选清单**先截断再分发**，每一例各起一个**独立子进程**：
#     · 该例完整 stdout/stderr ⇒ work/<用例>/run.console.log；
#     · 该例判定 ⇒ work/<用例>/result.txt（`<pass|fail|skip>|<用例>|<fail标签>|<compared行数>`）；
#     · 子进程退出码 ⇒ work/<用例>/run.rc；
#     父进程 join 全部子进程后，**按候选清单顺序回放**各例控制台日志（日志形态与串行版同构），
#     并在父进程内**唯一一次**聚合全局计数 ⇒ 并行下不存在计数器/数组竞争。
#     ★ 未捕获即失败（并行同样成立）：只有 result.txt 明确记 pass **且** worker rc=0 才计通过；
#       子进程异常退出/结果文件缺失或损坏/rc 与结论矛盾 ⇒ 该例计 FAIL，并打印 worker rc 与
#       该例控制台日志末尾（绝不静默丢失）；组计数自检（pass+fail+skip=运行例数）再兜底。
#     --jobs 只对 --group 生效，N≤0 或非数字一律硬失败（**不静默回退串行**）；--jobs 1 走原串行路径。
#   聚合输出（必打）：
#     `GROUP <组>: <pass> pass / <fail> fail / <skip> skip`   （三者之和 = 实际运行例数）
#   全绿时**额外**打一行紧凑判语 `GROUP <组>: <pass>/<pass+fail> pass`；
#   有任何 fail（或一例都没跑成）⇒ 该行**不打印**，最终退出码非零（未捕获即失败）。
#   ★ 失败路径同样不含任何 PASS 兜底文案（见文首纪律）。
#
# 【样例（端到端）】
#   ./sim/arch_test/run.sh I-nop-00
#   → 期望（RTL 修复后）：`RV32_ARCH_TEST: I-nop-00 PASS (compared=15020 lines, first_diff=none)`
#                     + `RV32_ARCH_TEST_RUN: PASS (1/1)`，rc=0
#   → 当前实测（见交付说明）：DUT 在 ACT 启动自检处失败（CSR 写后读距离 1 读到旧值），
#     本脚本如实报 FAIL 并给出首个分歧与两侧 dump，**不会**给出任何 PASS。
#
# 【依赖】
#   iverilog/vvp、/opt/riscv/bin/{riscv32-unknown-linux-gnu-gcc,objdump,nm,objcopy,spike}、
#   python3（仅用于读 sail.json 的 JSON）；**不依赖** uv/ruby/UDB（本机没有）。
#
# 【中间产物（保留供复核）】
#   sim/arch_test/work/<用例>/{<用例>.elf,.hex,.spike.sig,.dut.signature,.spike.log,.dut.log,
#                              tb.vvp,iverilog.log,nm.txt}
#==============================================================================
set -u -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
ARCH_TEST_ROOT="${RV32_ARCH_TEST_ROOT:-$(cd -- "${REPO_ROOT}/.." && pwd -P)/riscv-arch-test}"
CFG="${SCRIPT_DIR}/test_config.yaml"
LINK_LD="${SCRIPT_DIR}/link.ld"
SAIL_JSON="${SCRIPT_DIR}/sail.json"
EXCLUDE_LIST="${SCRIPT_DIR}/exclude.list"
WORK_DIR="${SCRIPT_DIR}/work"

#------------------------------------------------------------------------------
# 0. 工具链（复用 scripts/env.sh 的封装；缺变量时退回默认路径）
#------------------------------------------------------------------------------
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/env.sh" 2>/dev/null || true
GCC="${RV32_GCC:-/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc}"
OBJCOPY="${RV32_OBJCOPY:-/opt/riscv/bin/riscv32-unknown-linux-gnu-objcopy}"
OBJDUMP="${RV32_OBJDUMP:-/opt/riscv/bin/riscv32-unknown-linux-gnu-objdump}"
NM="${GCC%-gcc}-nm"
SPIKE="${RV32_SPIKE:-/opt/riscv/bin/spike}"
IVERILOG="${RV32_IVERILOG:-$(command -v iverilog || true)}"
VVP="${RV32_VVP:-$(command -v vvp || true)}"

die() { printf 'RV32_ARCH_TEST_ERROR: %s\n' "$*" >&2; exit 2; }

#------------------------------------------------------------------------------
# 1. 读 test_config.yaml（只用 awk 取少量标量键；缺键 ⇒ 硬失败）
#------------------------------------------------------------------------------
cfg_get() {  # cfg_get <section|-> <key>
    local section="$1" key="$2"
    if [ "$section" = "-" ]; then
        awk -v k="$key" '$0 ~ "^"k":[[:space:]]" { sub("^"k":[[:space:]]*", ""); sub(/[[:space:]]*#.*/, ""); print; exit }' "$CFG"
    else
        awk -v s="$section" -v k="$key" '
            $0 ~ "^"s":" { insec=1; next }
            insec && $0 ~ "^[^[:space:]]" { insec=0 }
            insec && $0 ~ "^[[:space:]]+"k":" { sub("^[[:space:]]+"k":[[:space:]]*", ""); sub(/[[:space:]]*#.*/, ""); print; exit }
        ' "$CFG"
    fi
}
cfg_need() {  # cfg_need <section> <key> <var>
    local v; v="$(cfg_get "$1" "$2")"
    [ -n "$v" ] || die "test_config.yaml 缺键：$1.$2"
    printf -v "$3" '%s' "$v"
}

[ -f "$CFG" ] || die "找不到 $CFG"
[ -f "$LINK_LD" ] || die "找不到 $LINK_LD"
[ -f "$EXCLUDE_LIST" ] || die "找不到 $EXCLUDE_LIST"
[ -d "$ARCH_TEST_ROOT/tests" ] || die "找不到 arch-test 仓库（RV32_ARCH_TEST_ROOT=$ARCH_TEST_ROOT）"

cfg_need - name CFG_NAME
cfg_need - compiler_exe CFG_CC
cfg_need - objdump_exe CFG_OBJDUMP
cfg_need - ref_model_exe CFG_REF
cfg_need - linker_script CFG_LD
cfg_need - dut_include_dir CFG_INC
cfg_need - include_priv_tests CFG_PRIV
cfg_need - spike_isa SPIKE_ISA
cfg_need - timeout_vvp_seconds TIMEOUT_VVP
cfg_need - timeout_cycles TIMEOUT_CYCLES
cfg_need memory ram_base RAM_BASE
cfg_need memory ram_size RAM_SIZE
cfg_need memory boot_base BOOT_BASE
cfg_need memory tohost TOHOST_ADDR

# 命令行可覆盖的项
OPT_VVP_TIMEOUT=""; OPT_CYCLES=""; OPT_VERBOSE=0
OPT_LIMIT=0; GROUP=""
OPT_JOBS=""; OPT_JOBS_SET=0      # --jobs：只对 --group 生效；空 ⇒ 组模式默认取 nproc
MODE="run"; TESTS=()

usage() { awk 'NR>1 && /^set -u -o pipefail/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)          MODE="list" ;;
        --check-exclude) MODE="check-exclude" ;;
        --directed)      MODE="directed" ;;
        --group)         shift; GROUP="${1:-}" ;;
        --limit)         shift; OPT_LIMIT="${1:-}" ;;
        --jobs)          shift; OPT_JOBS="${1:-}"; OPT_JOBS_SET=1 ;;
        --timeout-vvp)   shift; OPT_VVP_TIMEOUT="${1:-}" ;;
        --cycles)        shift; OPT_CYCLES="${1:-}" ;;
        -v|--verbose)    OPT_VERBOSE=1 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              die "未知选项：$1（-h 看用法）" ;;
        *)               TESTS+=("$1") ;;
    esac
    shift
done
[ -n "$OPT_VVP_TIMEOUT" ] && TIMEOUT_VVP="$OPT_VVP_TIMEOUT"
[ -n "$OPT_CYCLES" ] && TIMEOUT_CYCLES="$OPT_CYCLES"

# ---- --group / --limit 的参数校验（fail-closed：参数不合法一律硬失败）----
if [ -n "$GROUP" ]; then
    [ "${#TESTS[@]}" -eq 0 ] || die "--group 与位置参数（单例清单）不能同时使用：组模式已指定 ${GROUP}"
    case "$MODE" in
        run) MODE="group" ;;
        *)   die "--group 不能与 --list/--check-exclude/--directed 同时使用（当前模式：${MODE}）" ;;
    esac
elif [ "$OPT_LIMIT" != "0" ]; then
    die "--limit 只用于 --group 组模式（当前未指定 --group）"
fi
if [ "$OPT_LIMIT" != "0" ]; then
    case "$OPT_LIMIT" in
        ''|*[!0-9]*) die "--limit 需要正整数，收到：${OPT_LIMIT}" ;;
    esac
    [ "$OPT_LIMIT" -gt 0 ] || die "--limit 需要正整数，收到：${OPT_LIMIT}"
fi

# ---- --jobs（并行度）参数校验（fail-closed：不合法一律硬失败，绝不静默回退串行）----
if [ "$OPT_JOBS_SET" -eq 1 ]; then
    case "$OPT_JOBS" in
        ''|*[!0-9]*) die "--jobs 需要正整数，收到：${OPT_JOBS}" ;;
    esac
    [ "$OPT_JOBS" -gt 0 ] || die "--jobs 需要正整数，收到：${OPT_JOBS}"
fi
if [ "$MODE" = "group" ]; then
    if [ "$OPT_JOBS_SET" -eq 0 ]; then
        OPT_JOBS="$(nproc 2>/dev/null | tr -d '[:space:]' || true)"
        case "$OPT_JOBS" in
            ''|*[!0-9]*) die "默认并行度取不到（nproc 不可用或输出异常：'${OPT_JOBS}'）；请显式指定 --jobs N" ;;
        esac
        [ "$OPT_JOBS" -gt 0 ] || die "默认并行度取到 0（nproc 输出：'${OPT_JOBS}'）；请显式指定 --jobs N"
    fi
    if [ "$OPT_JOBS" -gt 1 ]; then
        # 并行池用 bash 的 `wait -n` 回收槽位（bash ≥ 4.3）；不支持就硬失败，绝不静默串行
        if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
           { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
            die "并行模式（--jobs ${OPT_JOBS}）依赖 bash≥4.3 的 wait -n；当前 $BASH_VERSION ⇒ 请显式用 --jobs 1"
        fi
    fi
elif [ "$OPT_JOBS_SET" -eq 1 ]; then
    die "--jobs 只用于 --group 组模式（当前模式：${MODE}）"
fi

#------------------------------------------------------------------------------
# 2. 工具存在性检查（缺 ⇒ 硬失败，不静默跳过）
#------------------------------------------------------------------------------
for t in "$GCC" "$OBJCOPY" "$NM" "$SPIKE" "$IVERILOG" "$VVP"; do
    [ -x "$t" ] || die "工具缺失或不可执行：$t（环境问题请报用户，勿在本脚本内安装）"
done
[ -x "$CFG_OBJDUMP" ] || die "objdump 缺失：$CFG_OBJDUMP"

#------------------------------------------------------------------------------
# 3. sail.json → SAIL_* 编译宏（sig 版 ELF 的 sail_macros.h 强制要求这两个宏）
#------------------------------------------------------------------------------
SAIL_DEFS=""
if [ -f "$SAIL_JSON" ]; then
    read -r SAIL_CLINT SAIL_SIG <<<"$(python3 - "$SAIL_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
p=d["platform"]
print(int(p["clint"]["base"]), int(p["simple_interrupt_generator"]["base"]))
PY
)" || true
    if [ -n "${SAIL_CLINT:-}" ] && [ -n "${SAIL_SIG:-}" ]; then
        SAIL_DEFS="-DSAIL_CLINT_BASE_ADDRESS=$(printf '0x%x' "$SAIL_CLINT") -DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=$(printf '0x%x' "$SAIL_SIG")"
    else
        die "sail.json 解析失败（缺 platform.clint.base / platform.simple_interrupt_generator.base）"
    fi
else
    die "找不到 $SAIL_JSON（sig 版 ELF 需要 SAIL_* 宏）"
fi

# Spike 内存映射与 link.ld / TB 一致：RAM + 复位桩窗口 + 核内 CLINT 窗口（按普通 RAM 映射）
SPIKE_MEM="-m${RAM_BASE}:${RAM_SIZE},${BOOT_BASE}:0x1000,0x1f000000:0x10000"

#------------------------------------------------------------------------------
# 4. exclude.list：解析 + 判定 + 逐条校验
#------------------------------------------------------------------------------
exclude_rules() {  # 输出 "<glob>|<reason>"（跳过空行/注释）
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { line=$0; sub(/[[:space:]]*#.*/, "", line); gsub(/[[:space:]]+$/, "", line);
          if (line == "") next;
          reason=$0; sub(/^[^#]*#/, "", reason); gsub(/^[[:space:]]+/, "", reason);
          print line "|" reason }
    ' "$EXCLUDE_LIST"
}

is_excluded() {  # is_excluded <arch-test 相对路径> → 0=被排除（并打印理由）
    local rel="$1" glob reason
    while IFS='|' read -r glob reason; do
        [ -n "$glob" ] || continue
        # shellcheck disable=SC2254
        case "$rel" in
            $glob) printf '%s' "$reason"; return 0 ;;
        esac
    done < <(exclude_rules)
    return 1
}

check_exclude_list() {  # 每条规则至少命中一个真实用例；命中 0 ⇒ FAIL
    local glob reason hits_n=0 bad=0 total=0
    while IFS='|' read -r glob reason; do
        [ -n "$glob" ] || continue
        total=$((total + 1))
        hits_n="$(cd "$ARCH_TEST_ROOT" && find tests -name '*.S' -print 2>/dev/null | while IFS= read -r f; do
                     case "$f" in $glob) printf '%s\n' "$f" ;; esac
                  done | wc -l)"
        if [ "$hits_n" -eq 0 ]; then
            bad=$((bad + 1))
            printf 'RV32_ARCH_TEST_CHECK: exclude.list 规则未命中任何用例 FAIL —— %s\n' "$glob"
        fi
    done < <(exclude_rules)
    printf 'RV32_ARCH_TEST_CHECK: exclude.list 共 %d 条规则，未命中 %d 条\n' "$total" "$bad"
    [ "$bad" -eq 0 ]
}

#------------------------------------------------------------------------------
# 5. 用例解析（名字 / 相对路径 / 路径片段 → 唯一 .S）
#------------------------------------------------------------------------------
all_tests() { (cd "$ARCH_TEST_ROOT" && find tests -name '*.S' | sort); }

resolve_test() {  # resolve_test <arg> → 打印 arch-test 相对路径；找不到/多义 → 非 0
    local arg="$1" matches=() kept=()
    local r
    case "$arg" in
        */*.S)  [ -f "${ARCH_TEST_ROOT}/${arg}" ] && { printf '%s' "$arg"; return 0; }; return 1 ;;
    esac
    # ① 精确 basename 命中；多命中时用 exclude.list 过滤（如 I-nop-00 同时存在于
    #    tests/rv32i/ 与 tests/rv64i/，rv64i 被排除 ⇒ 只剩 rv32i 的那一个）
    mapfile -t matches < <(all_tests | while IFS= read -r f; do
        [ "$(basename "$f" .S)" = "$(basename "$arg" .S)" ] && printf '%s\n' "$f"
    done)
    if [ "${#matches[@]}" -gt 1 ]; then
        for r in "${matches[@]}"; do is_excluded "$r" >/dev/null 2>&1 || kept+=("$r"); done
        if [ "${#kept[@]}" -eq 1 ]; then printf '%s' "${kept[0]}"; return 0; fi
        printf '\n' >&2
        printf 'ERROR: 用例名 %s 命中多个（%s）；请用完整相对路径指定\n' "$arg" "${matches[*]}" >&2
        return 1
    fi
    if [ "${#matches[@]}" -eq 1 ]; then printf '%s' "${matches[0]}"; return 0; fi
    # ② 路径片段匹配（同样要求"过滤排除后"唯一）
    mapfile -t matches < <(all_tests | grep -F -- "$arg" || true)
    if [ "${#matches[@]}" -gt 1 ]; then
        kept=()
        for r in "${matches[@]}"; do is_excluded "$r" >/dev/null 2>&1 || kept+=("$r"); done
        if [ "${#kept[@]}" -eq 1 ]; then printf '%s' "${kept[0]}"; return 0; fi
        printf '\n' >&2
        printf 'ERROR: 片段 %s 命中多个（%s）；请用更精确的路径\n' "$arg" "${matches[*]}" >&2
        return 1
    fi
    if [ "${#matches[@]}" -eq 1 ]; then printf '%s' "${matches[0]}"; return 0; fi
    return 1
}

#------------------------------------------------------------------------------
# 5.1 组名解析（--group 用）：目录名 / tests 下相对路径 / 用例名（路径）glob
#     ★ 只做"清单解析"，不做任何判定；是否被排除由调用方按 exclude.list 过滤 ——
#       同一套 is_excluded 真源，避免"组模式与单例模式判定口径分叉"。
#------------------------------------------------------------------------------
group_dir_help() {  # 解析失败时列出可用组名（按 tests 下**实际**目录，不硬编码）
    (cd "$ARCH_TEST_ROOT" && find tests -mindepth 1 -maxdepth 2 -type d | sort)
}

resolve_group() {  # resolve_group <组名> → 打印 arch-test 相对路径（逐行、已排序）
    local arg="$1" f
    case "$arg" in
        # ---- 含通配符：先按 basename 匹配（I-a*），再按相对路径匹配（tests/*/I-a*）----
        *'*'*|*'?'*|*'['*)
            all_tests | while IFS= read -r f; do
                case "$(basename "$f")" in $arg) printf '%s\n' "$f"; continue ;; esac
                case "$f" in $arg) printf '%s\n' "$f" ;; esac
            done
            ;;
        # ---- 纯名字：目录名（I/Zicsr/Sv…）/ tests 下相对路径（rv32i/I）/ 带 tests/ 前缀 ----
        *)
            all_tests | while IFS= read -r f; do
                case "$f" in
                    tests/"${arg}"/*)   printf '%s\n' "$f" ;;
                    tests/*/"${arg}"/*) printf '%s\n' "$f" ;;
                    "${arg}"/*)         printf '%s\n' "$f" ;;
                esac
            done
            ;;
    esac
}

#------------------------------------------------------------------------------
# 6. 用例属性：MARCH / FLEN（口径同 ACT4 的 parse_test_constraints.py）
#------------------------------------------------------------------------------
test_march() {  # 取 YAML 头里的 MARCH，并把 ACT 模板变量 ${XLEN} 展开为 32
    local m
    m="$(awk -F': *' '/^# *MARCH:/ { print $2; exit }' "$1")"
    # 特权用例头普遍写作 `# MARCH: rv${XLEN}i_zicsr_zifencei`（ACT 生成器的模板变量），
    # bash 参数展开**不递归**，不显式替换就会把字面量 `rv${XLEN}i_zicsr_zifencei` 交给
    # GCC（`-march=...` 报错）。口径同官方 ACT4 framework/src/act/toolchain.py:101 的
    # `march = march.replace("${XLEN}", str(xlen))`，本核 MXLEN=32。
    # ★ 替换**只作用于这里取出的这一个 MARCH 字符串**，不触碰脚本其它任何 $ 展开。
    printf '%s' "${m//'${XLEN}'/32}"
}
test_flen() {  # 依据 MARCH 推导 TEST_FLEN（Q=128 / D,g=64 / F=32 / 其余 32）
    local m; m="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    local sl rest; sl="${m%%_*}"; rest="${m#*_}"; sl="${sl#rv32}"; sl="${sl#rv64}"
    case "$sl$rest" in
        *q*) printf '128' ;;
        *d*|*g*) printf '64' ;;
        *f*) printf '32' ;;
        *) printf '32' ;;
    esac
}

#------------------------------------------------------------------------------
# 7. 单个用例的端到端流水线
#------------------------------------------------------------------------------
N_RUN=0; N_PASS=0; N_FAIL=0; N_SKIP=0; N_COMPARE_TOTAL=0
declare -a PASS_NAMES=() FAIL_NAMES=()

# 每例判定结果的**唯一真源**：run_one_body 只把结论写进 $RESULT_FILE（每例自己的文件，
# 并行时互不干扰），由父进程/串行调用方读取后**唯一一次**更新上面这组全局计数 ——
# "判定"与"计数"分离 ⇒ 多进程并行下不存在全局计数器/数组竞争。
#   记录格式（单行）：<pass|fail|skip>|<用例名>|<fail 标签>|<compared 行数>
RESULT_FILE=""
record_result() {  # record_result <pass|fail|skip> <name> <fail_label> <compare_lines>
    [ -n "$RESULT_FILE" ] || return 0
    local label="${3//|/_}"
    printf '%s|%s|%s|%s\n' "$1" "$2" "$label" "$4" >"$RESULT_FILE"
}

# 从 vvp 日志里取 TB 的 PASS 锚点（整行精确匹配；只认 TB 自己打印的那一行）
tb_pass_count() { grep -cxF 'TB_ARCH_TEST: PASS' "$1" 2>/dev/null || true; }

run_one_body() {  # run_one_body <arch-test 相对路径> <kind: act|directed>（只打印 + 落盘判定）
    local rel="$1" kind="$2"
    local name; name="$(basename "$rel" .S)"
    local odir="${WORK_DIR}/${name}"
    local elf="${odir}/${name}.elf" hex="${odir}/${name}.hex"
    local ref_sig="${odir}/${name}.spike.sig" dut_sig="${odir}/${name}.dut.signature"
    local spike_log="${odir}/${name}.spike.log" dut_log="${odir}/${name}.dut.log"
    local iv_log="${odir}/iverilog.log" nm_log="${odir}/nm.txt" vvp_file="${odir}/tb.vvp"
    local ok=1 why="" march flen test_file_arg src

    mkdir -p "$odir"
    printf -- '------------------------------------------------------------------------\n'
    printf 'RV32_ARCH_TEST: 用例 %s（%s）\n' "$name" "$rel"

    # ---- 7.0 排除判定（fail-closed：被排除 ⇒ 拒绝运行，绝不"跑到哪算哪"）----
    local exc_reason
    if exc_reason="$(is_excluded "$rel")"; then
        printf 'RV32_ARCH_TEST: SKIP %s —— 命中 exclude.list（理由：%s）\n' "$name" "$exc_reason"
        record_result skip "$name" "" 0
        return 0
    fi
    if [ "$CFG_PRIV" != "True" ] && [ "$CFG_PRIV" != "true" ]; then
        case "$rel" in
            tests/priv/*)
                printf 'RV32_ARCH_TEST: SKIP %s —— 特权用例（include_priv_tests: False）\n' "$name"
                record_result skip "$name" "" 0; return 0 ;;
        esac
    fi

    if [ "$kind" = "directed" ]; then
        src="${SCRIPT_DIR}/${rel}"; march="rv32i_zicsr_zifencei"; flen="32"
        test_file_arg=()
    else
        src="${ARCH_TEST_ROOT}/${rel}"
        march="$(test_march "$src")"
        if [ -z "$march" ]; then
            printf 'RV32_ARCH_TEST: FAIL %s —— 用例头缺 MARCH\n' "$name"
            record_result fail "$name" "$name(no-MARCH)" 0; return 1
        fi
        flen="$(test_flen "$march")"
        test_file_arg=(-DTEST_FILE="\"${name}.S\"")
    fi

    # ---- 7.1 编译 ----
    local -a cflags=(-march="$march" -mabi=ilp32 -mcmodel=medany -O0 -g -nostdlib -nostartfiles
                     -I "$SCRIPT_DIR" -I "${CFG_INC}" -T "$LINK_LD"
                     -DSIGNATURE -DXLEN=32 -DTEST_FLEN="$flen")
    if [ "$kind" != "directed" ]; then
        cflags+=(-I "${ARCH_TEST_ROOT}/tests/env")
    fi
    # shellcheck disable=SC2086
    if ! "$GCC" "${cflags[@]}" $SAIL_DEFS "${test_file_arg[@]}" \
            "${SCRIPT_DIR}/boot_stub.S" "$src" -o "$elf" >"${odir}/gcc.log" 2>&1; then
        printf 'RV32_ARCH_TEST: FAIL %s —— 编译失败（见 %s）\n' "$name" "${odir}/gcc.log"
        tail -n 15 "${odir}/gcc.log" | sed 's/^/    /'
        record_result fail "$name" "$name(compile)" 0; return 1
    fi

    # ---- 7.2 符号复核（fail-closed：与 link.ld 的约定不符即 FAIL）----
    "$NM" "$elf" >"$nm_log" 2>&1 || { printf 'RV32_ARCH_TEST: FAIL %s —— nm 失败\n' "$name";
                                      record_result fail "$name" "$name(nm)" 0; return 1; }
    local sig_b sig_e tohost entry_sym
    sig_b="$("$NM" "$elf" | awk '$3=="begin_signature"{print $1}')"
    sig_e="$("$NM" "$elf" | awk '$3=="end_signature"{print $1}')"
    tohost="$("$NM" "$elf" | awk '$3=="tohost"{print $1}')"
    entry_sym="$("$NM" "$elf" | awk '$3=="rvtest_entry_point"{print $1}')"
    [ -n "$sig_b" ] && [ -n "$sig_e" ] || { printf 'RV32_ARCH_TEST: FAIL %s —— ELF 缺 begin/end_signature 符号\n' "$name";
                                            record_result fail "$name" "$name(symbols)" 0; return 1; }
    local sig_words; sig_words=$(( (0x$sig_e - 0x$sig_b) / 4 ))
    [ "$sig_words" -gt 0 ] || { printf 'RV32_ARCH_TEST: FAIL %s —— 签名区长度为 0\n' "$name";
                                record_result fail "$name" "$name(sig-empty)" 0; return 1; }
    # tohost：link.ld 固定 0x800F_F000 ⇒ 与 test_config.yaml 的 memory.tohost 必须一致
    printf 'RV32_ARCH_TEST_INFO: %s 符号 sig=[0x%s,0x%s) words=%d tohost=0x%s entry=0x%s\n' \
           "$name" "$sig_b" "$sig_e" "$sig_words" "$tohost" "$entry_sym"
    if [ "$((16#${tohost#0x}))" != "$((TOHOST_ADDR))" ]; then
        printf 'RV32_ARCH_TEST: FAIL %s —— tohost=0x%s 与 link.ld/test_config.yaml 约定 %s 不符\n' \
               "$name" "$tohost" "$TOHOST_ADDR"
        record_result fail "$name" "$name(tohost-addr)" 0; return 1
    fi

    # ---- 7.3 Spike 参考签名 ----
    : >"$ref_sig"
    timeout "$TIMEOUT_VVP" "$SPIKE" --isa="$SPIKE_ISA" $SPIKE_MEM --instructions=200000000 \
        +signature="$ref_sig" +signature-granularity=4 "$elf" >"$spike_log" 2>&1
    local rc_spike=$?
    local ref_lines; ref_lines="$(wc -l <"$ref_sig" 2>/dev/null || echo 0)"
    if [ "$rc_spike" -ne 0 ] || [ "$ref_lines" -ne "$sig_words" ]; then
        printf 'RV32_ARCH_TEST: FAIL %s —— Spike 参考运行失败（rc=%d 行数=%s 期望=%d，见 %s）\n' \
               "$name" "$rc_spike" "$ref_lines" "$sig_words" "$spike_log"
        tail -n 10 "$spike_log" | sed 's/^/    /'
        record_result fail "$name" "$name(spike)" 0; return 1
    fi
    printf 'RV32_ARCH_TEST_INFO: %s Spike 参考签名 %d 行 ⇒ %s\n' "$name" "$ref_lines" "$ref_sig"

    # ---- 7.4 ELF → hex（DDR 区预载）----
    if ! "$OBJCOPY" -O verilog --verilog-data-width=4 "$elf" "$hex" >"${odir}/objcopy.log" 2>&1; then
        printf 'RV32_ARCH_TEST: FAIL %s —— objcopy 转 hex 失败\n' "$name"
        record_result fail "$name" "$name(objcopy)" 0; return 1
    fi
    local hex_records; hex_records="$(grep -c '^@' "$hex" || true)"
    printf 'RV32_ARCH_TEST_INFO: %s hex 记录段 %s 个 ⇒ %s\n' "$name" "$hex_records" "$hex"

    # ---- 7.5 iverilog 编译 TB + RTL ----
    local -a rtl_srcs; mapfile -t rtl_srcs < <(find "${REPO_ROOT}/rtl" -name '*.v' | sort)
    local -a ivflags=(-g2012 -I "${REPO_ROOT}/rtl/pkg" -I "${REPO_ROOT}")
    if ! "$IVERILOG" "${ivflags[@]}" -o "$vvp_file" -s tb_arch_test \
            -P "tb_arch_test.PROG_HEX=\"${hex}\"" \
            -P "tb_arch_test.SIG_FILE=\"${dut_sig}\"" \
            -P "tb_arch_test.SIG_BASE=32'h${sig_b#0x}" \
            -P "tb_arch_test.SIG_WORDS=${sig_words}" \
            -P "tb_arch_test.TOHOST_ADDR=32'h${tohost#0x}" \
            -P "tb_arch_test.TIMEOUT_CYCLES=${TIMEOUT_CYCLES}" \
            -P "tb_arch_test.HEARTBEAT_CYCLES=$([ "$OPT_VERBOSE" -eq 1 ] && echo 200000 || echo 0)" \
            "${rtl_srcs[@]}" "${REPO_ROOT}/sim/tb/tb_arch_test.sv" >"$iv_log" 2>&1; then
        printf 'RV32_ARCH_TEST: FAIL %s —— iverilog 编译失败（见 %s）\n' "$name" "$iv_log"
        tail -n 15 "$iv_log" | sed 's/^/    /'
        record_result fail "$name" "$name(iverilog)" 0; return 1
    fi

    # ---- 7.6 DUT 仿真 ----
    : >"$dut_sig"
    timeout "$TIMEOUT_VVP" "$VVP" "$vvp_file" >"$dut_log" 2>&1
    local rc_dut=$?
    local n_pass_lines; n_pass_lines="$(tb_pass_count "$dut_log")"
    local dut_ok=1
    if [ "$rc_dut" -ne 0 ] || [ "$n_pass_lines" -ne 1 ]; then
        dut_ok=0
        printf 'RV32_ARCH_TEST: DUT 仿真未通过（rc=%d TB 通过锚点行数=%s，见 %s）\n' \
               "$rc_dut" "$n_pass_lines" "$dut_log"
        grep -E 'TB_ARCH_TEST: FAIL|HTIF 终止|超时|DIAG' "$dut_log" | head -n 12 | sed 's/^/    /'
    fi

    # ---- 7.7 签名逐行比对（DUT 数据列 vs Spike 数据列）
    #   ★ 即使 7.6 判失败也**照常导出并比对**：失败用例"分歧在哪"正是定位依据；
    #     比对结论只作证据，最终判定仍要求 7.6 通过（见下面的 ok 汇总）。----
    local dut_lines; dut_lines="$(wc -l <"$dut_sig" 2>/dev/null || echo 0)"
    awk '{print tolower($2)}' "$dut_sig" >"${odir}/${name}.dut.data"
    awk '{print tolower($1)}' "$ref_sig" >"${odir}/${name}.spike.data"
    local ndiff=-1
    if [ "$dut_lines" -eq "$sig_words" ] && [ "$sig_words" -gt 0 ]; then
        # 逐行比对（纯 awk：不用 diff 的格式化输出，避免"格式参数吞掉差异计数"的坑）
        ndiff="$(awk 'NR==FNR { a[FNR]=$0; next } { if ($0 != a[FNR]) n++ } END { print n+0 }' \
                      "${odir}/${name}.dut.data" "${odir}/${name}.spike.data")"
    fi
    if [ "$ndiff" -lt 0 ]; then
        ok=0
        why="签名导出不完整（DUT 行数 $dut_lines ≠ 期望 $sig_words）"
        printf 'RV32_ARCH_TEST: FAIL %s —— %s\n' "$name" "$why"
    elif [ "$ndiff" -ne 0 ]; then
        ok=0
        why="签名与 Spike 参考不一致：$ndiff/$sig_words 行不同"
        printf 'RV32_ARCH_TEST: FAIL %s —— %s\n' "$name" "$why"
        printf '    首个分歧上下文（行号 = 签名区第几字，addr = 0x%s + 4*行号）：\n' "$sig_b"
        awk -v base="$((16#${sig_b#0x}))" '
              NR==FNR { a[FNR]=$0; next }
              { if ($0 != a[FNR]) { printf "    #%d addr=0x%08x dut=%s spike=%s\n", FNR, base + 4*(FNR-1), a[FNR], $0; n++ } }
              n>=8 { exit }
          ' "${odir}/${name}.dut.data" "${odir}/${name}.spike.data"
        printf '    完整两侧数据：%s / %s\n' "${odir}/${name}.dut.data" "${odir}/${name}.spike.data"
    fi
    if [ "$dut_ok" -eq 0 ]; then
        ok=0
        [ -n "$why" ] || why="DUT 仿真未通过（rc=$rc_dut）"
    fi

    if [ "$ok" -eq 1 ]; then
        printf 'RV32_ARCH_TEST: %s PASS (compared=%d lines, first_diff=none)\n' "$name" "$sig_words"
        record_result pass "$name" "" "$sig_words"
        return 0
    fi
    printf 'RV32_ARCH_TEST: FAIL %s —— 判据未全部达成（%s）\n' "$name" "$why"
    printf 'RV32_ARCH_TEST_INFO: %s 产物目录 = %s\n' "$name" "$odir"
    record_result fail "$name" "$name" 0
    return 1
}

#------------------------------------------------------------------------------
# 7.1 每例判定聚合（全局计数的**唯一**写入点）
#     只有 result.txt 明确记 pass **且**调用方 rc=0 才计通过；其余一切
#     （fail/skip 正常路径之外的结果文件缺失、损坏、rc 与结论矛盾、字段非法）
#     一律按"未捕获"计 FAIL 并打印可诊断证据 —— 与文首纪律一致。
#------------------------------------------------------------------------------
uncaught_result() {  # uncaught_result <rel> <rc> <why>
    local rel="$1" rc="$2" why="$3"
    local name; name="$(basename "$rel" .S)"
    local clog="${WORK_DIR}/${name}/run.console.log"
    N_FAIL=$((N_FAIL + 1)); FAIL_NAMES+=("${name}(uncaught)")
    printf 'RV32_ARCH_TEST: FAIL %s —— 未捕获项：%s\n' "$name" "$why"
    printf 'RV32_ARCH_TEST_INFO: %s worker rc=%s；每例结果文件=%s；控制台日志=%s\n' \
           "$name" "$rc" "${WORK_DIR}/${name}/result.txt" "$clog"
    if [ -f "$clog" ]; then
        printf 'RV32_ARCH_TEST_INFO: %s 该例控制台日志末 15 行：\n' "$name"
        tail -n 15 "$clog" | sed 's/^/    /'
    fi
}

aggregate_result() {  # aggregate_result <rel> <rc> → 0=该例记通过或跳过，1=该例记失败
    local rel="$1" rc="$2"
    local name; name="$(basename "$rel" .S)"
    local rfile="${WORK_DIR}/${name}/result.txt"
    local st="" rname="" label="" cmp="0" nlines="0"
    if [ -f "$rfile" ]; then
        nlines="$(wc -l <"$rfile" 2>/dev/null || echo 0)"
        if [ "$nlines" -eq 1 ]; then
            IFS='|' read -r st rname label cmp <"$rfile" || true
        fi
    fi
    case "$st" in
        pass)
            case "$cmp" in
                ''|*[!0-9]*) uncaught_result "$rel" "$rc" "结果文件 compare 字段非法（'$cmp'）"; return 1 ;;
            esac
            [ "$rc" -eq 0 ] || { uncaught_result "$rel" "$rc" "结果文件记通过但 worker rc≠0（矛盾）"; return 1; }
            [ -n "$rname" ] || rname="$name"
            N_COMPARE_TOTAL=$((N_COMPARE_TOTAL + cmp))
            N_PASS=$((N_PASS + 1)); PASS_NAMES+=("$rname")
            return 0 ;;
        fail)
            [ -n "$label" ] || label="${name}(no-label)"
            N_FAIL=$((N_FAIL + 1)); FAIL_NAMES+=("$label")
            return 1 ;;
        skip)
            N_SKIP=$((N_SKIP + 1))
            return 0 ;;
        *)
            uncaught_result "$rel" "$rc" "无有效每例结果文件（行数=${nlines}，文件=${rfile}）"
            return 1 ;;
    esac
}

run_one() {  # run_one <arch-test 相对路径> <kind: act|directed>（串行入口：stdout 直通，与改造前一致）
    local rel="$1" kind="$2"
    local name; name="$(basename "$rel" .S)"
    mkdir -p "${WORK_DIR}/${name}"
    RESULT_FILE="${WORK_DIR}/${name}/result.txt"
    rm -f "$RESULT_FILE"
    local rc=0
    run_one_body "$rel" "$kind" || rc=$?
    local st=0
    aggregate_result "$rel" "$rc" || st=$?
    RESULT_FILE=""
    return "$st"
}

#------------------------------------------------------------------------------
# 7.2 多进程并行（仅 --group 且 --jobs>1）
#     子进程只写自己 work/<用例>/ 下的三件产物（互不冲突，也不碰父进程全局量）：
#       run.console.log —— 该例完整 stdout/stderr（父进程随后按清单顺序回放）
#       result.txt      —— 判定记录（7.1 的唯一真源）
#       run.rc          —— 子进程退出码
#     父进程用 `wait -n` 回收槽位（不猜"谁结束了"：判定一律从文件读），
#     全部 join 完再回放 + 聚合 ⇒ 无竞争、无静默丢失。
#------------------------------------------------------------------------------
run_one_worker() {  # run_one_worker <rel> <kind>
    local rel="$1" kind="$2"
    local name; name="$(basename "$rel" .S)"
    local odir="${WORK_DIR}/${name}"
    local clog="${odir}/run.console.log" rcfile="${odir}/run.rc"
    mkdir -p "$odir"
    : >"$clog"
    rm -f "${odir}/result.txt" "$rcfile"
    RESULT_FILE="${odir}/result.txt"
    printf 'RV32_ARCH_TEST_GROUP_WORKER: %s 并发启动（pid=%d %s）\n' "$name" "$BASHPID" "$(date '+%H:%M:%S')" >&2
    local rc=0
    run_one_body "$rel" "$kind" >>"$clog" 2>&1 || rc=$?
    printf '%d\n' "$rc" >"$rcfile"
    printf 'RV32_ARCH_TEST_GROUP_WORKER: %s 并发收工（pid=%d %s rc=%d）\n' "$name" "$BASHPID" "$(date '+%H:%M:%S')" "$rc" >&2
    return "$rc"
}

# 物理核数（lscpu 取不到 ⇒ 打印空 ⇒ 不做提示；仅用于并发度提示，不参与任何判定）
physical_cores() {
    command -v lscpu >/dev/null 2>&1 || return 0
    lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l
}

# 并发安全前置检查：work/<用例>/ 以**用例 basename** 为键 ⇒ 同 basename 的两例
# （如 rv32i 与 rv64i 的同名用例）会共用产物目录，并行时互相覆盖 result.txt /
# run.console.log ⇒ 可能把失败例误判成通过。故并行前硬失败（串行路径不受影响）。
check_parallel_unique() {  # check_parallel_unique <rel...>
    local -A seen=()
    local -a dup=()
    local rel name
    for rel in "$@"; do
        name="$(basename "$rel" .S)"
        if [ -n "${seen[$name]:-}" ]; then
            dup+=("$name（${seen[$name]} 与 ${rel}）")
        else
            seen[$name]="$rel"
        fi
    done
    if [ "${#dup[@]}" -gt 0 ]; then
        printf 'RV32_ARCH_TEST_GROUP: 并行模式拒绝执行 —— 本批存在同 basename 用例（共用 work/<名字>/，并行会互相覆盖判定）：\n' >&2
        printf '    %s\n' "${dup[@]}" >&2
        printf '    ⇒ 请改用 --jobs 1 串行，或用更精确的组名/glob 排除重名用例。\n' >&2
        exit 2
    fi
    return 0
}

group_run_parallel() {  # group_run_parallel <jobs> <rel...>：并发池，池大小 = jobs
    local jobs="$1"; shift
    local -a rels=("$@")
    local total="${#rels[@]}" idx=0 running=0
    [ "$jobs" -gt "$total" ] && jobs="$total"
    printf 'RV32_ARCH_TEST_GROUP: 并行模式 jobs=%d，本批 %d 例（每例独立子进程；完整输出见 work/<名字>/run.console.log）\n' \
           "$jobs" "$total"
    while [ "$idx" -lt "$total" ] || [ "$running" -gt 0 ]; do
        while [ "$running" -lt "$jobs" ] && [ "$idx" -lt "$total" ]; do
            run_one_worker "${rels[$idx]}" act &
            running=$((running + 1)); idx=$((idx + 1))
        done
        if [ "$running" -gt 0 ]; then
            wait -n || true     # 仅用于回收并发槽位；判定/rc 一律从每例产物文件读
            running=$((running - 1))
        fi
    done
    return 0
}

group_collect_parallel() {  # 父进程 join 后：按候选清单顺序回放控制台日志 + 聚合判定
    local rel name clog rcfile rc
    for rel in "$@"; do
        name="$(basename "$rel" .S)"
        clog="${WORK_DIR}/${name}/run.console.log"
        rcfile="${WORK_DIR}/${name}/run.rc"
        if [ -f "$clog" ]; then
            cat "$clog"
        else
            printf 'RV32_ARCH_TEST_INFO: %s 无控制台日志（%s 不存在）\n' "$name" "$clog"
        fi
        rc="$(cat "$rcfile" 2>/dev/null || true)"
        case "$rc" in ''|*[!0-9]*) rc=127 ;; esac      # 缺 run.rc ⇒ 非 0 ⇒ 走"未捕获"判决
        aggregate_result "$rel" "$rc" || true
    done
    return 0
}

#------------------------------------------------------------------------------
# 8. 模式分发
#------------------------------------------------------------------------------
case "$MODE" in
    check-exclude)
        if check_exclude_list; then
            printf 'RV32_ARCH_TEST_CHECK: PASS —— exclude.list 全部规则均有命中\n'; exit 0
        else
            printf 'RV32_ARCH_TEST_CHECK: FAIL —— exclude.list 存在未命中规则\n'; exit 1
        fi
        ;;
    list)
        printf 'RV32_ARCH_TEST_LIST: 用例（IN=在运行范围 / EX=被 exclude.list 排除）\n'
        while IFS= read -r rel; do
            if exc_reason="$(is_excluded "$rel")"; then
                printf '  EX %s  —— %s\n' "$rel" "$exc_reason"
            else
                printf '  IN %s\n' "$rel"
            fi
        done < <(all_tests)
        exit 0
        ;;
    directed)
        for d in "${TESTS[@]:-}"; do
            [ -n "$d" ] || continue
            f="${SCRIPT_DIR}/$(basename "$d" .S).S"
            [ -f "$f" ] || die "定向程序不存在：$f"
            run_one "$(basename "$f" .S).S" directed
        done
        ;;
    run)
        [ "${#TESTS[@]}" -gt 0 ] || die "未指定用例（-h 看用法）"
        for t in "${TESTS[@]}"; do
            rel="$(resolve_test "$t")" || die "解析不到用例：$t（可用 --list 查看）"
            run_one "$rel" act
        done
        ;;
    group)
        # ---- ① 解析组 → 候选清单（空 ⇒ 硬失败，绝不"跑 0 个算过"）----
        mapfile -t g_all < <(resolve_group "$GROUP")
        if [ "${#g_all[@]}" -eq 0 ]; then
            printf 'RV32_ARCH_TEST_GROUP: 组名 %s 未命中任何用例（候选 0）\n' "$GROUP" >&2
            printf '  可用组名（目录名 / 相对路径；也可直接用用例名 glob，如 I-a*）：\n' >&2
            group_dir_help | sed 's/^/    /' >&2
            exit 2
        fi
        # ---- ② 逐条按 exclude.list 过滤（被过滤的逐条打印，不静默丢弃）----
        g_run=()
        for rel in "${g_all[@]}"; do
            if exc_reason="$(is_excluded "$rel")"; then
                printf 'RV32_ARCH_TEST_GROUP: 过滤 %s —— 命中 exclude.list（%s）\n' "$rel" "$exc_reason"
            else
                g_run+=("$rel")
            fi
        done
        printf 'RV32_ARCH_TEST_GROUP: 组 %s —— 候选 %d 例，exclude.list 过滤 %d 例，待运行 %d 例\n' \
               "$GROUP" "${#g_all[@]}" "$(( ${#g_all[@]} - ${#g_run[@]} ))" "${#g_run[@]}"
        # ---- ③ --limit：只取（过滤后的）前 N 例（冒烟用；截断数量显式可见）----
        if [ "$OPT_LIMIT" -gt 0 ] && [ "${#g_run[@]}" -gt "$OPT_LIMIT" ]; then
            printf 'RV32_ARCH_TEST_GROUP: --limit %d ⇒ 只运行前 %d 例（按路径排序，其余 %d 例本次未运行）\n' \
                   "$OPT_LIMIT" "$OPT_LIMIT" "$(( ${#g_run[@]} - OPT_LIMIT ))"
            g_run=("${g_run[@]:0:$OPT_LIMIT}")
        fi
        if [ "${#g_run[@]}" -eq 0 ]; then
            printf 'RV32_ARCH_TEST_GROUP: 组 %s 过滤后没有可运行用例（0 pass / 0 fail / 0 skip）\n' "$GROUP"
            exit 1
        fi
        # ---- ④ 逐例走**同一条**判定流水线（超时/判据与单例模式完全一致）----
        #       --jobs 1 ⇒ 原串行路径（stdout 直通，行为/输出与改造前一致）；
        #       --jobs N>1 ⇒ 并发池跑，父进程 join 后按候选清单顺序回放 + 聚合。
        g_pass0=$N_PASS; g_fail0=$N_FAIL; g_skip0=$N_SKIP
        if [ "$OPT_JOBS" -le 1 ]; then
            for rel in "${g_run[@]}"; do
                run_one "$rel" act || true      # 单例失败不中断本组：聚合成组结论后统一判
            done
        else
            check_parallel_unique "${g_run[@]}"
            # 并发度提示（只提示、不改变判定）：jobs 超过**物理核数** ⇒ SMT 超订，
            # 单例 vvp 的墙钟≈翻倍，可能触发 timeout_vvp_seconds（rc=124 超时 ⇒ 该例 FAIL）。
            g_phys="$(physical_cores)"
            case "$g_phys" in ''|*[!0-9]*) g_phys="" ;; esac
            if [ -n "$g_phys" ] && [ "$g_phys" -gt 0 ] && [ "$OPT_JOBS" -gt "$g_phys" ]; then
                printf 'RV32_ARCH_TEST_GROUP: 提示 —— jobs=%d 超过物理核数 %d（SMT 超订会让每例仿真墙钟≈翻倍；单例超时仍为 %ss）⇒ 若出现 rc=124 超时判失败，请改用 --jobs %d 或加大 --timeout-vvp\n' \
                       "$OPT_JOBS" "$g_phys" "$TIMEOUT_VVP" "$g_phys" >&2
            fi
            group_run_parallel "$OPT_JOBS" "${g_run[@]}"
            group_collect_parallel "${g_run[@]}"
        fi
        g_pass=$((N_PASS - g_pass0)); g_fail=$((N_FAIL - g_fail0)); g_skip=$((N_SKIP - g_skip0))
        # ---- ⑤ 组聚合（必打一行三项计数；全绿才额外打紧凑判语）----
        printf -- '------------------------------------------------------------------------\n'
        printf 'GROUP %s: %d pass / %d fail / %d skip\n' "$GROUP" "$g_pass" "$g_fail" "$g_skip"
        if [ "$g_fail" -eq 0 ] && [ "$g_pass" -gt 0 ]; then
            printf 'GROUP %s: %d/%d pass\n' "$GROUP" "$g_pass" "$(( g_pass + g_fail ))"
            g_verdict=0
        else
            printf 'GROUP %s: 未通过 —— %d/%d 例成功（fail=%d skip=%d；本组不输出通过判语）\n' \
                   "$GROUP" "$g_pass" "$(( g_pass + g_fail ))" "$g_fail" "$g_skip"
            g_verdict=1
        fi
        # 组计数自检：三项之和必须等于实际调用例数（不成立 ⇒ fail-closed 判失败）
        if [ "$(( g_pass + g_fail + g_skip ))" -ne "${#g_run[@]}" ]; then
            printf 'RV32_ARCH_TEST_GROUP: 组 %s 计数自检不通过（pass+fail+skip=%d ≠ 运行 %d 例）\n' \
                   "$GROUP" "$(( g_pass + g_fail + g_skip ))" "${#g_run[@]}"
            g_verdict=1
        fi
        printf 'RV32_ARCH_TEST_GROUP_VERDICT: %s rc=%d\n' "$GROUP" "$g_verdict"
        ;;
esac

#------------------------------------------------------------------------------
# 9. 汇总（唯一 PASS 文案；任何未捕获/失败 ⇒ rc≠0）
#------------------------------------------------------------------------------
printf -- '========================================================================\n'
printf 'RV32_ARCH_TEST_SUMMARY: 运行=%d 通过=%d 失败=%d 跳过=%d 比对总行数=%d\n' \
       "$((N_PASS + N_FAIL))" "$N_PASS" "$N_FAIL" "$N_SKIP" "$N_COMPARE_TOTAL"
if [ "${#FAIL_NAMES[@]}" -gt 0 ]; then
    printf 'RV32_ARCH_TEST_SUMMARY: 失败用例 = %s\n' "${FAIL_NAMES[*]}"
fi
if [ "${#PASS_NAMES[@]}" -gt 0 ]; then
    printf 'RV32_ARCH_TEST_SUMMARY: 通过用例 = %s\n' "${PASS_NAMES[*]}"
fi
#   ★ 组模式（--group）下还要求组计数自检通过（g_verdict==0），
#     否则即便"通过数>0 且失败数==0"也不得打印成功文案（fail-closed）。
if [ "$N_FAIL" -eq 0 ] && [ "$N_PASS" -gt 0 ] && [ "${g_verdict:-0}" -eq 0 ]; then
    printf 'RV32_ARCH_TEST_RUN: PASS (%d/%d)\n' "$N_PASS" "$((N_PASS + N_FAIL))"
    exit 0
fi
printf 'RV32_ARCH_TEST_RUN: FAIL —— 存在失败或未捕获项（通过 %d，失败 %d，跳过 %d）\n' \
       "$N_PASS" "$N_FAIL" "$N_SKIP"
exit 1
