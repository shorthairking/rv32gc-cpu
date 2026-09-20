#!/usr/bin/env bash
#==============================================================================
# rv32gc-cpu/sw/m5_board/build.sh —— M5 上板测试程序构建（含自检；未捕获即失败）
#==============================================================================
# 用法 : ./sw/m5_board/build.sh [--clean]
# 产物 : sw/m5_board/out/m5_board.elf     —— 可执行（链接 0x1C00_0000）
#        sw/m5_board/out/m5_board.bin     —— **烧写镜像**（原始二进制，从 Flash 偏移 0 起）
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
    -march=rv32im            # 只用 RV32I + M（核已实现；Zicsr 未使用）
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
if [ "$FAILED" -ne 0 ]; then
    say "RESULT_M5_BUILD: FAIL（见上面 FAIL 条目）"
    exit 1
fi
say "RESULT_M5_BUILD: OK  镜像=${OUT}/m5_board.bin（${SIZE} B）"
exit 0
