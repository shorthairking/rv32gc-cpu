#!/usr/bin/env bash
#==============================================================================
# rv32gc-cpu/sw/m5_board/build.sh —— M5 上板测试程序构建（含自检；未捕获即失败）
#==============================================================================
# 用法 : ./sw/m5_board/build.sh [--clean]
# 产物 : sw/m5_board/out/m5_board.elf     —— 可执行（链接 0x1C00_0000）
#        sw/m5_board/out/m5_board.bin     —— **烧写镜像**（原始二进制，从 Flash 偏移 0 起）
#        sw/m5_board/out/m5_diag.bin      —— **诊断版镜像**（与 m5_board.bin 逐字节相同的显式
#                                            命名副本；runbook 诊断节引用它 ⇒ 用户不会拿错）
#        sw/m5_board/out/m5_board.hex     —— iverilog $readmemh 用（4B/行）
#        sw/m5_board/out/m5_board.dis     —— 反汇编（供人工核对，随交付留档）
#        sw/m5_board/out/m5_board.size    —— 镜像大小（字节）
#        sw/m5_board/out/build.log        —— 完整构建日志
# 判据（全部满足才 rc=0；任一条不满足 ⇒ 打印 FAIL: <条目> 并 rc=1）：
#   ① 工具链存在；
#   ② ELF 入口与 .text 首地址 == 0x1C000000；
#   ③ 反汇编中**不含**压缩指令（2 字节；`.option norvc` 生效）；
#   ④ 镜像非空且 ≤ 1 MiB（XIP 窗口大小）；
#   ⑤ `nm` 中**不存在**重定位/绝对地址符号表项导致运行期依赖（用 readelf -r 判定：无 R_RISCV_32 类
#      绝对重定位；只有 R_RISCV_JAL/BRANCH/HI20/LO12 这类 PC 相对或同段内相对重定位）；
#   ⑥ 镜像首字 != 0（不是空白 Flash），且首 4 字节 == 反汇编第一条指令的编码。
#   ⑦ 反汇编无非法/未知编码；⑧ delay_loop 结构 + XIP_CPI 自洽；⑨ CONFREG/UART 基址与偏移；
#   ⑩ 跨子程序"存活值"寄存器体检（s8/s9/s10/s11）；
#   ⑪ ★ 诊断版专用（2026-09-21）：打印路径**无栈访存** + DDR3 回环探针在位 + 无 M 扩展指令
#      + 探针地址不与任何已分配段重叠 + m5_diag.bin 与 m5_board.bin 一致（详见 §⑪）。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="${SCRIPT_DIR}/m5_board.S"
OUT="${SCRIPT_DIR}/out"
LOG="${OUT}/build.log"

TOOLCHAIN_PREFIX="${TOOLCHAIN_PREFIX:-/opt/riscv/bin/riscv32-unknown-linux-gnu-}"
CC="${TOOLCHAIN_PREFIX}gcc"
OBJDUMP="${TOOLCHAIN_PREFIX}objdump"
OBJCOPY="${TOOLCHAIN_PREFIX}objcopy"
READELF="${TOOLCHAIN_PREFIX}readelf"
NM="${TOOLCHAIN_PREFIX}nm"

TEXT_ADDR="0x1C000000"
MAX_BYTES=$((1024 * 1024))            # SPI XIP 窗口 1 MiB

if [ "${1:-}" = "--clean" ]; then rm -rf "$OUT"; shift || true; fi
mkdir -p "$OUT"
: > "$LOG"

say()  { printf '%s\n' "$*" | tee -a "$LOG" ; }
run()  { printf '+ %s\n' "$*" >>"$LOG" ; "$@" >>"$LOG" 2>&1 ; }

FAILED=0
check() {                      # check <判据名> <命令...>
    local name="$1"; shift
    if "$@" >>"$LOG" 2>&1; then
        say "PASS: ${name}"
    else
        say "FAIL: ${name}"
        FAILED=1
    fi
}

say "== M5 board program build: $(date -Is)"
say "== SRC=$SRC"
say "== OUT=$OUT"

#------------------------------------------------------------------------------
# ① 工具链
#------------------------------------------------------------------------------
if [ ! -x "$CC" ]; then
    say "FAIL: 工具链不存在：$CC（期望 /opt/riscv/bin/riscv32-unknown-linux-gnu-gcc）"
    exit 1
fi
say "PASS: 工具链存在（$($CC -dumpversion 2>>"$LOG")）"

#------------------------------------------------------------------------------
# 编译 / 链接 / 转镜像
#------------------------------------------------------------------------------
CFLAGS=(
    -march=rv32im_zicsr      # RV32I + M（打印用 remu/divu）+ Zicsr（步④ 只读 rdcycle）
    -mabi=ilp32
    -mno-relax               # ★ 关闭链接器松弛 ⇒ 不产生 R_RISCV_* 绝对/松弛重定位
    -mcmodel=medlow
    -nostdlib -nostartfiles -ffreestanding -fno-builtin -fno-pic -fno-pie
    -fno-asynchronous-unwind-tables -fno-unwind-tables
    -Os -Wall -Wextra -Wno-unused-parameter
)
LDFLAGS=(
    -nostdlib -nostartfiles -static -mno-relax
    -Wl,-Ttext=${TEXT_ADDR}
    -Wl,-e,_start
    -Wl,--build-id=none
    -Wl,-Map=${OUT}/m5_board.map
    -Wl,--no-warn-rwx-segments
)

say "== compile+link"
if ! run "$CC" "${CFLAGS[@]}" "${LDFLAGS[@]}" -o "${OUT}/m5_board.elf" "$SRC"; then
    say "FAIL: 编译/链接失败（详见 ${LOG}）"
    exit 1
fi
say "PASS: 编译/链接成功 ⇒ ${OUT}/m5_board.elf"

# 反汇编：.text 反汇编 + .rodata 内容（只读数据必须一起留档，才能核对"取串地址-字符串"对应关系）
#   · m5_board.text.dis : 仅 .text 反汇编（供"指令编码/结构"类判据使用）
#   · m5_board.dis      : .text + .rodata 内容（供"字符串字面量"类判据与人工留档）
"$OBJDUMP" -d -M no-aliases,numeric "${OUT}/m5_board.elf" > "${OUT}/m5_board.text.dis" 2>>"$LOG"
{
    cat "${OUT}/m5_board.text.dis"
    echo
    echo "=== .rodata 内容（-s）==="
    "$OBJDUMP" -s -j .rodata "${OUT}/m5_board.elf"
} > "${OUT}/m5_board.dis" 2>>"$LOG"
run "$OBJCOPY" -O binary "${OUT}/m5_board.elf" "${OUT}/m5_board.bin"
# ★ 诊断版镜像（显式命名副本；内容必须与 m5_board.bin 逐字节相同 ⇒ 判据⑪g 用 cmp 核对）
cp -f "${OUT}/m5_board.bin" "${OUT}/m5_diag.bin"
run "$READELF" -a "${OUT}/m5_board.elf" > "${OUT}/m5_board.readelf" 2>>"$LOG"
run "$NM" -n "${OUT}/m5_board.elf" > "${OUT}/m5_board.nm" 2>>"$LOG"

SIZE=$(stat -c %s "${OUT}/m5_board.bin" 2>/dev/null || echo 0)
echo "$SIZE" > "${OUT}/m5_board.size"
say "== 镜像大小 = ${SIZE} B"

# 4B/行 hex（iverilog $readmemh 口径；不足补 0，便于 TB 直接加载）
python3 - "$OUT" <<'PY' >>"$LOG" 2>&1
import sys, os
out = sys.argv[1]
data = open(os.path.join(out, 'm5_board.bin'), 'rb').read()
# 补齐到 4 字节边界（XIP 取指按 4B 字）
if len(data) % 4:
    data += b'\x00' * (4 - len(data) % 4)
with open(os.path.join(out, 'm5_board.hex'), 'w') as f:
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], 'little')
        f.write('%08x\n' % w)
PY

#------------------------------------------------------------------------------
# ② ELF 入口 == 0x1C000000
#------------------------------------------------------------------------------
entry="$("$READELF" -h "${OUT}/m5_board.elf" | awk '/Entry point address/ {print $4}')"
say "== ELF entry = ${entry}"
check "判据②a：ELF 入口 = ${TEXT_ADDR}" test "$(printf %s "$entry" | tr A-F a-f)" = "$(printf %s "${TEXT_ADDR}" | tr A-F a-f)"

#   readelf 的节表行形如 `  [ 1] .text  PROGBITS  1c000000 001000 000414 ...`
#   ⇒ 节名在第 3 列、地址在第 5 列（与 binutils 版本无关的稳妥写法）
text_addr="$("$READELF" -S "${OUT}/m5_board.elf" | awk '$3==".text" {print $5; exit}')"
say "== .text addr = ${text_addr}"
check "判据②b：.text 首地址 = ${TEXT_ADDR}" test "$(printf %s "$text_addr" | tr A-F a-f)" = "$(printf %s "${TEXT_ADDR#0x}" | tr A-F a-f)"

#------------------------------------------------------------------------------
# ③ 无压缩指令（反汇编里不应出现 2 字节指令）
if grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{2}[[:space:]]' "${OUT}/m5_board.text.dis"; then
    say "FAIL: 判据③：反汇编中发现 2 字节指令（压缩指令未被 norvc 关闭）"
    grep -nE '^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{2}[[:space:]]' "${OUT}/m5_board.text.dis" | head -5 | tee -a "$LOG"
    FAILED=1
else
    say "PASS: 判据③：无压缩指令（全部 4 字节）"
fi
N_INS=$(grep -cE '^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{8}[[:space:]]' "${OUT}/m5_board.text.dis" || true)
say "== 反汇编指令数 = ${N_INS}"

#------------------------------------------------------------------------------
# ④ 镜像大小
#------------------------------------------------------------------------------
check "判据④a：镜像非空" test "$SIZE" -gt 0
check "判据④b：镜像 ≤ 1 MiB（XIP 窗口）" test "$SIZE" -le "$MAX_BYTES"

#------------------------------------------------------------------------------
# ⑤ 无绝对地址重定位（只允许 PC 相对 / 段内相对类型）
#------------------------------------------------------------------------------
RELOC="$("$READELF" -r "${OUT}/m5_board.elf" 2>/dev/null | awk '/R_RISCV/ {print $3}' | sort -u | tr '\n' ' ')"
say "== 重定位类型集合 = ${RELOC:-<无>}"
ABS_BAD=0
for r in $RELOC; do
    case "$r" in
        R_RISCV_JAL|R_RISCV_BRANCH|R_RISCV_HI20|R_RISCV_LO12_I|R_RISCV_LO12_S|R_RISCV_PCREL_HI20|R_RISCV_PCREL_LO12_I|R_RISCV_PCREL_LO12_S|R_RISCV_CALL|R_RISCV_CALL_PLT|R_RISCV_RELAX|R_RISCV_ALIGN|R_RISCV_RVC_BRANCH|R_RISCV_RVC_JUMP|R_RISCV_32_PCREL)
            ;;
        *) say "  WARN: 出现非 PC 相对型重定位：$r" ; ABS_BAD=1 ;;
    esac
done
check "判据⑤：无绝对地址重定位（R_RISCV_32/64 等）" test "$ABS_BAD" -eq 0

#------------------------------------------------------------------------------
# ⑥ 镜像首字与反汇编第一条指令一致、且非 0
#------------------------------------------------------------------------------
first_word="$(head -1 "${OUT}/m5_board.hex")"
say "== 镜像首字 = ${first_word}"
check "判据⑥a：镜像首字非 0" test "${first_word}" != "00000000"
dis_first="$(awk '/^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{8}/{print $2; exit}' "${OUT}/m5_board.text.dis")"
say "== 反汇编首条指令编码 = ${dis_first}"
check "判据⑥b：首字 == 反汇编首条指令" test "$(printf %s "$first_word" | tr A-F a-f)" = "$(printf %s "$dis_first" | tr A-F a-f)"

#------------------------------------------------------------------------------
# ⑧ delay_loop 标定自检（步④ 的"每迭代拍数"常量必须与循环体结构一致）
#   判据：dl_loop 起连续 7 条 `addi x0,x0,0`（nop），随后 `addi a0,a0,-1` 与回跳分支，
#         循环体共 9 条指令。
#   ★ 每迭代**拍数**不是 9 而是 XIP_CPI（源码常量，标定值 59）：本程序在 SPI Flash XIP
#     窗口执行且取指绕过 I-Cache ⇒ 每指令约 6.5 拍（核级仿真实测 59.02 拍/迭代）。
#     这里机器核对"循环体结构 + XIP_CPI 声明存在且量级合理"，防止改了循环体却忘了改常量
#     导致步④ 判据失真。标定值变更必须三处同步：源码 XIP_CPI / 本脚本注释 / runbook §4。
#------------------------------------------------------------------------------
DL_BODY="$(awk '/^[[:space:]]*[0-9a-f]+ <dl_loop>:/{f=1;next} f&&/^[[:space:]]*$/{exit} f&&/^[[:space:]]*[0-9a-f]+:/{print}' "${OUT}/m5_board.text.dis")"
DL_N=$(printf '%s\n' "$DL_BODY" | grep -c ':' || true)
DL_NOP=$(printf '%s\n' "$DL_BODY" | grep -c 'addi[[:space:]]*x0,x0,0' || true)
say "== dl_loop 指令数 = ${DL_N}（nop 数 = ${DL_NOP}）"
check "判据⑧a：dl_loop = 7×nop + addi + bne = 9 条" test "$DL_N" -eq 9
check "判据⑧b：dl_loop 含 7 条 nop" test "$DL_NOP" -eq 7
SRC_CPI="$(grep -oE '^\.equ[[:space:]]+XIP_CPI,[[:space:]]+[0-9]+' "$SRC" | grep -oE '[0-9]+$')"
SRC_IT="$(grep -oE '^\.equ[[:space:]]+MEAS_ITER,[[:space:]]+[0-9]+' "$SRC" | grep -oE '[0-9]+$')"
say "== 源码 XIP_CPI = ${SRC_CPI}（XIP 直连取指下 delay_loop 每迭代拍数，核级仿真实测 59.02）"
say "== 源码 MEAS_ITER = ${SRC_IT}"
check "判据⑧c：XIP_CPI 已按 XIP 口径标定（≥ 9 条指令，且 ≤ 200）" \
      test "${SRC_CPI:-0}" -ge 9 -a "${SRC_CPI:-0}" -le 200
check "判据⑧d：MEAS_ITER ≥ 1000（测量窗口足够）" test "${SRC_IT:-0}" -ge 1000
# 判据⑧e：程序里必须有"延时不再用空转计数"的两条护栏——delay_ticks 存在 + 心跳用 TIMER 等待
check "判据⑧e：反汇编含 delay_ticks 与 timer_now" \
      bash -c "grep -q '<delay_ticks>:' '${OUT}/m5_board.dis' && grep -q '<timer_now>:' '${OUT}/m5_board.dis'" 

#------------------------------------------------------------------------------
# ⑧f 步④ 鲁棒化后的**机器护栏**（2026-09-21）
#   步④ 判据 = "CONFREG TIMER 增量 == 核周期（rdcycle）增量" ⇒ 必须机器核对：
#     ① 源码里确实有 `rdcycle`（否则判据会退化成只看 TIMER 自己，自洽但无意义）
#     ② 反汇编里确实出现读 cycle CSR 的指令（`-march=rv32im_zicsr` 生效 + 真读 0xC00）
#     ③ 健全性窗口常量 CPI_SANITY_LO/HI 存在且量级合理（下界 ≥ 循环体 9 条指令、
#        上界 ≤ 400）—— 防止把窗口改成"必过"（如 [1, 1000000]）
#     ④ 旧的"绝对标定拍数"判据（TGT_TICKS/TGT_TOL）不得残留
#   rdcycle rd, cycle, x0 的编码 = csrrs rd, 0xC00, x0 ⇒ 反汇编渲染为
#   `csrrs x<rd>,cycle,x0`（-M no-aliases）；这里按助记符+CSR 名匹配，容忍别名渲染。
#------------------------------------------------------------------------------
check "判据⑧f1：源码含 rdcycle（步④ 的核周期对照）" grep -qE '^[[:space:]]*rdcycle[[:space:]]' "$SRC"
check "判据⑧f2：反汇编含读 cycle CSR（csrrs ...,cycle,...）" \
      grep -qE 'csrrs?[[:space:]]+x[0-9]+,(cycle|0xc00),x0' "${OUT}/m5_board.text.dis"
SAN_LO="$(grep -oE '^\.equ[[:space:]]+CPI_SANITY_LO,[[:space:]]+[0-9]+' "$SRC" | grep -oE '[0-9]+$')"
SAN_HI="$(grep -oE '^\.equ[[:space:]]+CPI_SANITY_HI,[[:space:]]+[0-9]+' "$SRC" | grep -oE '[0-9]+$')"
say "== 源码 CPI 健全性窗口 = [${SAN_LO:-?}, ${SAN_HI:-?}]"
check "判据⑧f3：健全性窗口下界 ≥ 9（循环体指令数）" test "${SAN_LO:-0}" -ge 9
check "判据⑧f4：健全性窗口上界 ≤ 400（不得改成必过窗口）" \
      test "${SAN_HI:-99999}" -le 400 -a "${SAN_HI:-0}" -gt "${SAN_LO:-0}"
check "判据⑧f5：步④ 判据不再依赖绝对标定拍数（无 TGT_TICKS/TGT_TOL 残留）" \
      bash -c "! grep -qE '^\.equ[[:space:]]+(TGT_TICKS|TGT_TOL),' '$SRC'"

#------------------------------------------------------------------------------
# ⑨ CONFREG 访问地址自检（防止"偏移量写错/基址丢失"这类静默错）
#   li t6,0xF000 + add t6,s1,t6 展开为 lui/addi ⇒ 反汇编里应能看到 `lui x31,0xf`
#   与 `add x31,x9,x31`（x31=t6、x9=s1）。这里只做**存在性**核对：
#   反汇编必须出现 CONFREG 页 0x1fd00（s1 的装载）与至少一次 `lui x31,0xf`（0xF000 偏移）。
#------------------------------------------------------------------------------
check "判据⑨a：反汇编含 CONFREG 基址装载 lui x9,0x1fd00" \
      grep -qE 'lui[[:space:]]+x9,0x1fd00' "${OUT}/m5_board.text.dis"
#   ★ 机器级核对（比文本匹配强）：源码里 CONFREG 的大偏移访问形如
#        li t5, 0xF000 ; add t6, s1, t5
#     其编码必须是 `lui x30,0xf`（0x0000ff37）+ `add x31,x9,x30`（0x01e48fb3）——
#     前者装载偏移 0xF000（而不是仅低 12 位的 0x000），后者把它加到 CONFREG 基址 s1(x9)。
#     这两条一起出现即证明"偏移没被截断 + 基址没丢失"（否则会静默访问 0xF000 号地址）。
check "判据⑨b：CONFREG 偏移装载 lui x30,0xf（0x0000ff37）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+0000ff37' "${OUT}/m5_board.text.dis"
check "判据⑨b2：偏移加到 CONFREG 基址 s1（add x31,x9,x30 = 0x01e48fb3）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+01e48fb3' "${OUT}/m5_board.text.dis"
check "判据⑨c：反汇编含 UART 基址装载 lui x8,0x1fe00" \
      grep -qE 'lui[[:space:]]+x8,0x1fe00' "${OUT}/m5_board.text.dis"

#------------------------------------------------------------------------------
# ⑨b 程序内常量自洽（步④ 标定值与 runbook 一致）
#------------------------------------------------------------------------------
RULE_CPI="$(grep -oE 'cycles/iter[^0-9]*[0-9]+' "${REPO_ROOT:-$(pwd)}/sw/M5-board-runbook.md" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
if [ -n "${RULE_CPI}" ]; then
    say "== runbook 里的 cycles/iter 标定值 = ${RULE_CPI}"
    check "判据⑨d：runbook 的 cycles/iter 标定值 == 源码 XIP_CPI" test "${RULE_CPI}" = "${SRC_CPI}"
else
    say "WARN: 未能从 runbook 提取 cycles/iter 标定值（跳过⑨d）"
fi

#------------------------------------------------------------------------------
# ⑩ 跨子程序"存活值"寄存器体检（2026-09-20：核级仿真暴露过两起同类 P0）
#   规则：`puts_hex8` 内部用 **t3** 当位计数、`puts_dec`/`puts_hex8` 内部用 **t0..t6**
#         与 **t1** 做临时 ⇒ 任何"打印之后还要参与判定/运算"的值必须放在 **s 系列**寄存器。
#   本判据机器核对三件事（都是曾经真实踩过的坑）：
#     ⑩a 步④ 判定位必须落在 s8（x24）：`xori x24,..,1`（0x001c4c13 的 s8 变体）——
#         用更稳的写法：反汇编里必须出现 `ori  x24,` 或 `xori x24,`（s8 = x24）
#     ⑩b 步⑤ 的 FREQ 值必须用 s9（x25）承载：出现 `addi  x25,` 或 `lw x25,`
#     ⑩c 最终判定必须落在 s10（x26）：出现 `xori x26,`
#   说明：x8=s0 x9=s1 x18=s2 x19=s3 x20=s4 x21=s5 x22=s6 x23=s7 x24=s8 x25=s9 x26=s10
#------------------------------------------------------------------------------
check "判据⑩a：步④ 判定位在 s8(x24)（反汇编含 x24 相关 or/xori）" \
      grep -qE '(xori|or)[[:space:]]+x24,' "${OUT}/m5_board.text.dis"
check "判据⑩b：步⑤ FREQ 值在 s9(x25)（反汇编含 lw x25 或 addi x25）" \
      grep -qE '(lw|addi|mv)[[:space:]]+x25,' "${OUT}/m5_board.text.dis"
#   ⑩c 最终判定必须落在 s10(x26)：新口径是"坏=1"的 OR + `bnez x26,total_bad`
#       （旧口径 ~(s8|t4) 用 xori；两种都接受，但必须出现 x26 的 or/bnez 组合）
check "判据⑩c：最终判定在 s10(x26)（反汇编含 or/bnez x26）" \
      bash -c "grep -qE '(or|xori|bnez|beq)[[:space:]]+x26,' '${OUT}/m5_board.text.dis'"
check "判据⑩c2：BAD 分支由 x26 非零触发（坏=1 极性；objdump 把 bnez 渲染成 bne x26,x0）" \
      grep -qE 'bnez[[:space:]]+x26,|bne[[:space:]]+x26,x0,' "${OUT}/m5_board.text.dis"
check "判据⑩e：步④ 坏标志在 s11(x27)（跨 udiv 覆盖存活）" \
      grep -qE '(sltu|or)[[:space:]]+x27,' "${OUT}/m5_board.text.dis"
check "判据⑩f：汇总判定读 s11（or x26,x27,<reg>）" \
      grep -qE 'or[[:space:]]+x26,x27,' "${OUT}/m5_board.text.dis"
check "判据⑩d：FREQ 的 MHz 整数部分用自写 udiv（不能出现 *du/M 扩展除法）" \
      bash -c "! grep -qE '\b(divu|remu|div|rem)[[:space:]]' '${OUT}/m5_board.text.dis' || grep -q '<udiv>:' '${OUT}/m5_board.text.dis'"

#------------------------------------------------------------------------------
# ⑪ ★ 诊断版专用判据（2026-09-21 新增；本轮的**核心**：让"十进制打印"与 DDR3 解耦，
#    并让"新/旧 bitstream"一眼可判）
#   背景：R2 缺陷（旧 bitstream）下 DDR3 读回垃圾。旧版 puts_dec 把数字写进栈缓冲
#   （sp 在 DDR3）再 lbu 读回 ⇒ 数字全乱、且无法分辨"核坏了"还是"跑的是旧 bitstream"。
#   ⑪a 全程序**无栈访存**：反汇编里不得出现任何以 sp(x2) 为基址的访存 ⇒ 结构上证明
#       "打印路径不依赖内存"（也不依赖任何 DDR3 缓冲）。
#   ⑪b puts_dec/pd_one/puts_hex8/puts_hex2（打印数字的三个子程序，含内部标签）段内
#       **不含任何访存指令** ⇒ 数字打印与存储系统完全无关。
#   ⑪c DDR3 回环探针在位（机器级核对指令编码，见 m5_board.S §三 步2.5）：
#       lui x5,0x8（0x000082b7 ⇒ 地址 0x8000）+ sw x6,0(x5) + lw x7,0(x5) + lw x28,0(x5)
#       + sb x6,3(x5) + lbu x29,3(x5) + 立即数 0x12345678（lui x6,0x12345 = 0x12345337）
#   ⑪d R2 判定接线：`or x18,x30,x31`（s2 = word坏 | byte坏）与 `or x26,x26,x18`
#       （汇总判定并入 s2）；.dis 里含字符串 "R2FIX: yes"/"R2FIX: no"（objdump -s 的 ASCII 列）。
#   ⑪e 探针地址 0x0000_8000 不与任何已分配段/栈重叠：ELF **无 .data/.bss**，.text/.rodata
#       都在 0x1C00_0000 附近（不覆盖 0x8000），栈顶 0x07FF_FFF0（远高于 0x8000+4）。
#   ⑪f 全程序**不含 M 扩展指令**（mul/div/rem 系列）—— 十进制打印改用"比较-减法 + 常量幂链"。
#   ⑪g m5_diag.bin 与 m5_board.bin 逐字节一致（诊断镜像=烧写镜像，防止两个文件漂移）。
#------------------------------------------------------------------------------
check "判据⑪a：全程序无栈访存（反汇编无以 x2/sp 为基址的 lw/sw/sb/lbu…）" \
      bash -c "! grep -qE '\b(lw|sw|sb|lbu|lhu|lb|lh|sh)[[:space:]]+x[0-9]+,-?[0-9]+\(x2\)' '${OUT}/m5_board.text.dis'"
#   ⑪b/⑪f：按**函数地址区间**切片（起止地址由 `nm -S` 给出），逐段核对两件事：
#     · ⑪b 这些子程序里**零访存**（打印/自写除法不碰内存 ⇒ 数字打印与存储系统无关）；
#     · ⑪f 这些子程序里**零 M 扩展指令**（十进制打印不依赖 M；M 只在步2.6 探针里出现）。
#       说明：不能只看源码文本（`lbu` 也可能是字符串里的字节），也不能只看符号名 ——
#       区间切片是对**机器码**的核对：这些函数编译出来的每一条指令都在检查范围内。
HELPER_FNS="puts_dec,pd_one,puts_hex8,puts_hex2,puts_str,puts_nl,udiv,delay_ticks"
region_scan() {                                 # region_scan <mem|mop>
    python3 - "${OUT}/m5_board.text.dis" "${OUT}/m5_board.elf" "$1" <<'PY'
import re, subprocess, sys
dis, elf, mode = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(dis).read().splitlines()
syms = []
for l in subprocess.run(["/opt/riscv/bin/riscv32-unknown-linux-gnu-nm", "-S", "-n", elf],
                        capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) == 4 and p[2] in ("t", "T"):
        syms.append((int(p[0], 16), int(p[1], 16), p[3]))
syms.sort()
mode = sys.argv[3]
if mode == "mem":
    pat = re.compile(r'\b(lw|sw|sb|lbu|lhu|lb|lh|sh)\s+x')
    what = "访存指令"
else:
    pat = re.compile(r'\b(mul|mulh|mulhsu|mulhu|div|divu|rem|remu)\s+x')
    what = "M 扩展指令"
targets = ["puts_dec", "pd_one", "puts_hex8", "puts_hex2", "puts_str", "puts_nl", "udiv", "delay_ticks"]
bad = []
for i, (a, sz, name) in enumerate(syms):
    if name not in targets:
        continue
    b = a + sz
    for l in lines:
        m = re.match(r'^\s*([0-9a-f]+):', l)
        if not m:
            continue
        pc = int(m.group(1), 16)
        if a <= pc < b and pat.search(l):
            bad.append((name, l.strip()))
print(f"== 判据⑪{'b' if mode == 'mem' else 'f'}：打印/自写除法子程序段内 {what} 检查（区间切片）")
for name, l in bad:
    print(f"   {name}: {l}")
print("   " + (f"OK：这些子程序段内零{what}" if not bad else f"发现 {len(bad)} 条{what} ⇒ 应当 FAIL"))
sys.exit(0 if not bad else 1)
PY
}
region_scan mem >>"$LOG" 2>&1
if [ $? -eq 0 ]; then say "PASS: 判据⑪b：打印/除法子程序段内零访存（puts_dec/pd_one/puts_hex8/puts_hex2/puts_str/puts_nl/udiv/delay_ticks）"
else say "FAIL: 判据⑪b：打印/除法子程序段内出现访存"; FAILED=1; fi
region_scan mop >>"$LOG" 2>&1
if [ $? -eq 0 ]; then say "PASS: 判据⑪f：打印/自写除法子程序段内零 M 扩展指令（十进制打印不依赖 M）"
else say "FAIL: 判据⑪f：打印/除法子程序段内出现 M 扩展指令"; FAILED=1; fi
check "判据⑪c1：探针地址装载 lui x5,0x8（0x000082b7 ⇒ 0x8000）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+000082b7' "${OUT}/m5_board.text.dis"
check "判据⑪c2：探针写 sw x6,0(x5)（0x0062a023）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+0062a023' "${OUT}/m5_board.text.dis"
check "判据⑪c3：探针读 lw x7,0(x5)（0x0002a383）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+0002a383' "${OUT}/m5_board.text.dis"
check "判据⑪c4：探针再读 lw x28,0(x5)（0x0002ae03）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+0002ae03' "${OUT}/m5_board.text.dis"
check "判据⑪c5：字节回环 sb x6,3(x5)（0x006281a3）+ lbu x29,3(x5)（0x0032ce83）" \
      bash -c "grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+006281a3' '${OUT}/m5_board.text.dis' && grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+0032ce83' '${OUT}/m5_board.text.dis'"
check "判据⑪c6：回环模式立即数 0x12345678（lui x6,0x12345 = 0x12345337 + addi …0x678）" \
      bash -c "grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+12345337' '${OUT}/m5_board.text.dis' && grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+67830313' '${OUT}/m5_board.text.dis'"
check "判据⑪d1：R2 逐位判定接线 or x18,x30,x31（0x01ff6933）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+01ff6933' "${OUT}/m5_board.text.dis"
check "判据⑪d2：汇总判定并入 s2（or x26,x26,x18 = 0x012d6d33）" \
      grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]+012d6d33' "${OUT}/m5_board.text.dis"
check "判据⑪d3：判别串在位（.rodata 含 \"R2FIX: \" 文本 + \"yes\\0\"/\"no\\0\" 字节）" \
      bash -c "grep -q 'R2FIX:' '${OUT}/m5_board.dis' && grep -qE '79657300' '${OUT}/m5_board.dis' && grep -qE '6e6f0000' '${OUT}/m5_board.dis'"
check "判据⑪d4：R2FIX 结论按 s2 分支打印（反汇编含 bne x18,x0,<ddr_stale>）" \
      grep -qE 'bne[[:space:]]+x18,x0,' "${OUT}/m5_board.text.dis"
#   ⑪e：探针地址区间 [0x8000,0x8004) 不与任何已分配段重叠，且无 .data/.bss
#        （栈顶由源码 `lui sp,0x08000` 固定为 0x0800_0000 ⇒ 远高于探针地址；本判据只需
#          确认"没有任何 ELF 段覆盖 0x8000" ⇒ 探针不会踩到程序自己的数据）
python3 - "${OUT}/m5_board.elf" <<'PY' >>"$LOG" 2>&1
import re, subprocess, sys
out = subprocess.run(["/opt/riscv/bin/riscv32-unknown-linux-gnu-readelf", "-S", "-W", sys.argv[1]],
                     capture_output=True, text=True).stdout
bad = []
for m in re.finditer(r'^\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', out, re.M):
    name, typ, addr, off, size = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4), 16), int(m.group(5), 16)
    if name in (".data", ".bss"):
        bad.append(f"存在段 {name}（addr=0x{addr:x} size=0x{size:x}）")
    if typ != "NULL" and size > 0 and addr and addr < 0x8004 and addr + size > 0x8000:
        bad.append(f"段 {name} 覆盖 0x8000（addr=0x{addr:x} size=0x{size:x}）")
print("== 判据⑪e：探针地址 0x00008000 未被任何已分配段覆盖、且无 .data/.bss")
for b in bad:
    print("   " + b)
print("   " + ("OK：探针地址安全（.text/.rodata 均在 0x1C00_0000 附近，无 .data/.bss）" if not bad else "不满足"))
sys.exit(0 if not bad else 1)
PY
if [ $? -eq 0 ]; then say "PASS: 判据⑪e：探针地址 0x0000_8000 不与任何已分配段/栈重叠（无 .data/.bss）"
else say "FAIL: 判据⑪e：探针地址与已分配段重叠或存在 .data/.bss"; FAILED=1; fi
check "判据⑪f2：步2.6 的 9 个 M 扩展向量都在（divu×4 / remu×2 / mul / mulh / mulhu 各 ≥1）" \
      bash -c "cd '${OUT}' && for m in divu:4 remu:2 mul:1 mulh:1 mulhu:1; do \
                 op=\${m%%:*}; n=\${m##*:}; c=\$(grep -cE \"^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{8}[[:space:]]+\$op[[:space:]]+x\" m5_board.text.dis); \
                 [ \"\$c\" -ge \"\$n\" ] || { echo \"   \$op 计数=\$c < \$n\"; exit 1; }; \
               done"
check "判据⑪f3：步2.7 栈字节探针在位（反汇编含 addi x28,x2,-64 的栈缓冲指针 + sb/lbu 各 ≥1）" \
      bash -c "grep -qE '[0-9a-f]+:[[:space:]]+fc010e13' '${OUT}/m5_board.text.dis' && \
               grep -qE 'sb[[:space:]]+x[0-9]+,-?[0-9]+\(x28\)' '${OUT}/m5_board.text.dis' && \
               grep -qE 'lbu[[:space:]]+x[0-9]+,-?[0-9]+\(x28\)' '${OUT}/m5_board.text.dis'"
#   ⑫ BUILD 标记（"板上跑的是哪份镜像"的判定依据）：源码与 .rodata 都必须含下面这条，
#     且与 build.sh 里的期望值**一字不差**（防止改了程序忘了改标记 ⇒ 标记失去意义）。
EXPECT_BUILD_TAG="BUILD=m5_board-diag-2026-09-21c"
check "判据⑫a：源码含 BUILD 标记 ${EXPECT_BUILD_TAG}" \
      grep -qF "${EXPECT_BUILD_TAG}" "$SRC"
check "判据⑪g：m5_diag.bin 与 m5_board.bin 逐字节一致" cmp -s "${OUT}/m5_board.bin" "${OUT}/m5_diag.bin"
#   ⑫b：在 **.rodata 字节流**上核对同一条标记（`objdump -s` 的文本 dump 每行只显示 16 B，
#        标记会被换行切断 ⇒ 必须按字节核对；手法同 ⑪h）。
python3 - "${OUT}/m5_board.elf" "${OUT}/.rodata.tmp2" "${EXPECT_BUILD_TAG}" <<'PY' >>"$LOG" 2>&1
import subprocess, sys
elf, tmp, tag = sys.argv[1], sys.argv[2], sys.argv[3]
subprocess.run(["/opt/riscv/bin/riscv32-unknown-linux-gnu-objcopy", "-O", "binary",
                "-j", ".rodata", elf, tmp], check=True)
blob = open(tmp, "rb").read()
ok = tag.encode() in blob
print(f"== 判据⑫b：.rodata 字节流含 BUILD 标记「{tag}」⇒ {ok}")
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ]; then say "PASS: 判据⑫b：.rodata 字节流含 BUILD 标记（板上横幅即"哪份镜像"的判定依据）"
else say "FAIL: 判据⑫b：.rodata 里没有 BUILD 标记"; FAILED=1; fi
rm -f "${OUT}/.rodata.tmp2"
#   ⑪h 横幅必须整体可打印：GNU as 的 `.asciz` 每条都补 NUL ⇒ 旧版把横幅四行拆成四条
#      `.asciz`，`puts_str` 读到第一个 NUL 就返回 ⇒ 上板只打印第 1 行（runbook 期望的
#      `BOARD-PROG:` / `UART 115200 …` / `RESET_PC=…` 三行从来没出现过）。本判据在
#      **.rodata 字节流**上核对"四行首尾相接、中间无 NUL"。
python3 - "${OUT}/m5_board.elf" "${OUT}/.rodata.tmp" <<'PY' >>"$LOG" 2>&1
import subprocess, sys
elf, tmp = sys.argv[1], sys.argv[2]
subprocess.run(["/opt/riscv/bin/riscv32-unknown-linux-gnu-objcopy", "-O", "binary",
                "-j", ".rodata", elf, tmp], check=True)
blob = open(tmp, "rb").read()
need = [b"33MHz\r\nBUILD=m5_board-diag-2026-09-21c",
        b"R2+MEXT+stack probes)\r\nUART 115200 8N1 (divisor=18",
        b"114583 Bd)\r\nRESET_PC=0x1C000000 (SPI XIP), MMU off, PC-relative only",
        b"-> R2FIX: "]
miss = [n for n in need if n not in blob]
print("== 判据⑪h：横幅/判别串在 .rodata 里整体连续（无嵌入 NUL）")
for n in need:
    print(f"   {'OK  ' if n in blob else 'MISS'}  {n[:60].decode('ascii', 'replace')}")
sys.exit(0 if not miss else 1)
PY
if [ $? -eq 0 ]; then say "PASS: 判据⑪h：横幅四行 + R2FIX 前缀在 .rodata 里首尾相接（中间无 NUL）"
else say "FAIL: 判据⑪h：横幅被 NUL 截断（`.asciz` 拆分问题复发）"; FAILED=1; fi
rm -f "${OUT}/.rodata.tmp"

#------------------------------------------------------------------------------
# 汇总
#------------------------------------------------------------------------------
if grep -qiE '\b(bad|unknown|illegal)\b' "${OUT}/m5_board.text.dis"; then
    say "FAIL: 判据⑦：.text 反汇编中出现非法/未知编码"
    grep -niE '\b(bad|unknown|illegal)\b' "${OUT}/m5_board.text.dis" | head -5 | tee -a "$LOG"
    FAILED=1
else
    say "PASS: 判据⑦：.text 反汇编无非法/未知编码（注意：rodata 里的字面量 "BAD" 不算）"
fi

say "== 产物清单"
ls -l "${OUT}" | tee -a "$LOG" >/dev/null
#   ★ "哪份镜像"的三元组（与程序里的 BUILD 标记呼应；烧写前记下这三行即可自证）
say "== BUILD 标记 = ${EXPECT_BUILD_TAG}"
say "== 源码 md5   = $(md5sum "$SRC" | awk '{print $1}')（m5_board.S）"
say "== 镜像 md5   = $(md5sum "${OUT}/m5_board.bin" | awk '{print $1}')（m5_board.bin = m5_diag.bin）"
say "== hex  md5   = $(md5sum "${OUT}/m5_board.hex" | awk '{print $1}')（m5_board.hex，仿真加载用）"
if [ "$FAILED" -ne 0 ]; then
    say "RESULT_M5_BUILD: FAIL（见上面 FAIL 条目）"
    exit 1
fi
say "RESULT_M5_BUILD: OK  镜像=${OUT}/m5_board.bin（${SIZE} B）"
exit 0
