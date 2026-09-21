#!/usr/bin/env bash
#==============================================================================
# sw/boot/build_spi_image.sh —— SPI Flash 引导镜像打包（引导桩 + OpenSBI + U-Boot + DTB）
#==============================================================================
# 项目 : rv32gc-cpu（阶段三 B-3.5 引导链）
# 依据 : docs/porting/01-overview.md §2.2/§2.3/§2.4（XIP 启动、DDR 布局、入口寄存器口径）
#        docs/porting/02-uboot.md §8.6（U-Boot CONFIG_TEXT_BASE=0x0200_0000）
#        docs/porting/03-linux-opensbi.md §4.3（FW_JUMP + FW_JUMP_FDT_ADDR）
#        docs/kb/platform-facts.md §2.3（XIP 主窗口 1 MiB / 别名 0x1FE8_0000）、§3（SPI 16 MiB）
#
# 用法 :
#   sw/boot/build_spi_image.sh [--opensbi FILE] [--uboot FILE] [--dtb FILE] [--clean]
#   默认 payload（可用 --* 覆盖；OpenSBI 先跑 sw/boot/build_opensbi_rv32.sh 产出）：
#     --opensbi  sw/boot/out/opensbi-build/platform/generic/firmware/fw_jump.bin
#     --uboot    <workspace>/u-boot/u-boot.bin
#     --dtb      <workspace>/u-boot/u-boot.dtb
#
# 产物 :
#   sw/boot/out/boot_stub.elf / boot_stub.bin   ← 桩（链接 0x1C00_0000，≤16 KiB）
#   sw/boot/out/spi_flash.img                   ← **单一烧写镜像**（从 Flash 偏移 0 烧）
#   sw/boot/out/spi_flash_img_info.txt          ← 布局表 + 逐段 md5（交付证据）
#   sw/boot/out/pack.log                        ← 构建日志
#
# 判据（全部满足 ⇒ rc=0 且打印 `SPI_IMAGE: OK`；任一不满足 ⇒ `FAIL: <条目>` 且 rc=1）：
#   ① 工具链与三个 payload 文件存在、非空；
#   ② 桩源码 sw/boot/boot_stub.S 的 .equ 常量块可解析，且**每个符号只定义一次**；
#   ③ 桩 .equ 的段偏移 == 本脚本 LAYOUT_*_OFF 声明（**双源漂移检测**：只改一边必红）；
#   ④ 桩 .equ 的段长度 == payload 实际大小补齐到 4 的倍数（u-boot.bin 398 330 B ⇒ 398 332）；
#   ⑤ 桩 .equ 的段目的地址 == 本脚本 LAYOUT_*_DST 声明；
#   ⑥ 布局合法：偏移 4 KiB 对齐、段长/目的地址 4 字节对齐、段间不重叠、
#      镜像总长 ≤ 1 MiB（XIP 主窗口，超出落 DDR3 默认从设备）、且 ≤ 16 MiB（SPI 器件容量）、
#      桩自身 ≤ 桩槽（16 KiB）；
#   ⑦ 桩汇编/链接 rc=0；
#   ⑧ 桩静态核对：入口 == 0x1C000000、`readelf -r` 无任何重定位、反汇编里
#      **无 CSR 指令 / 无 sfence / 无 ecall**（不开 MMU、不读改 CSR）、无压缩指令、
#      无以 x2(sp) 为基址的访存（不用栈）、拷贝只用 lw/sw；
#   ⑨ 桩镜像里的段表**字面值** == .equ 声明（nm 定位 stub_seg_table + 镜像切片核对）；
#   ⑩ 打包后逐段按偏移切片，与源 payload **逐字节相同**（cmp），并打印逐段 md5。
#
# 反证（打包脚本自身的"未捕获即失败"自检，人工执行一次即可复现）：
#   · 缺段   ：`--dtb /nonexistent` ⇒ 判据①红；
#   · 超容量 ：临时把 LAYOUT_DTB_OFF 改到 0x00FFF000（+1 MiB 边界外）或把某段长度改大
#              ⇒ 判据⑥红（镜像总长/窗口越界）；
#   · 双源漂移：只改桩 .equ 的 BOOT_SRC_UBOOT 而不改本脚本 ⇒ 判据③红。
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
WORKSPACE="$(cd -- "${REPO_ROOT}/.." && pwd -P)"
OUT_DIR="${SCRIPT_DIR}/out"
LOG="${OUT_DIR}/pack.log"
INFO="${OUT_DIR}/spi_flash_img_info.txt"

STUB_SRC="${SCRIPT_DIR}/boot_stub.S"
STUB_LDS="${SCRIPT_DIR}/boot_stub.ld"
STUB_ELF="${OUT_DIR}/boot_stub.elf"
STUB_BIN="${OUT_DIR}/boot_stub.bin"
IMG="${OUT_DIR}/spi_flash.img"

#==============================================================================
# 布局声明（**唯一真源之二**；与 boot_stub.S 的 .equ 块逐项比对，不一致必红）
#   ★ 改布局 = 同时改这里与 boot_stub.S；两处都改完再跑本脚本（判据③/⑤）。
#==============================================================================
LAYOUT_STUB_OFF=0x000000
LAYOUT_STUB_SLOT=0x004000        # 桩槽 16 KiB（= OPENSBI_OFF - STUB_OFF）
LAYOUT_OPENSBI_OFF=0x004000
LAYOUT_OPENSBI_DST=0x01000000    # FW_TEXT_START
LAYOUT_UBOOT_OFF=0x080000
LAYOUT_UBOOT_DST=0x02000000      # U-Boot CONFIG_TEXT_BASE
LAYOUT_DTB_OFF=0x0E8000
LAYOUT_DTB_DST=0x03000000        # FW_JUMP_FDT_ADDR
LAYOUT_XIP_SIZE=0x00100000       # XIP 主窗口 1 MiB（镜像总长上界）
LAYOUT_FLASH_SIZE=0x01000000     # SPI NOR 16 MiB（器件容量上界）

TOOLCHAIN_PREFIX="${TOOLCHAIN_PREFIX:-/opt/riscv/bin/riscv32-unknown-linux-gnu-}"
CC="${TOOLCHAIN_PREFIX}gcc"
OBJCOPY="${TOOLCHAIN_PREFIX}objcopy"
OBJDUMP="${TOOLCHAIN_PREFIX}objdump"
READELF="${TOOLCHAIN_PREFIX}readelf"
NM="${TOOLCHAIN_PREFIX}nm"
OD="${OD:-od}"

OPEN_SBI_BIN="${OUT_DIR}/opensbi-build/platform/generic/firmware/fw_jump.bin"
UBOOT_BIN="${WORKSPACE}/u-boot/u-boot.bin"
UBOOT_DTB="${WORKSPACE}/u-boot/u-boot.dtb"

while [ $# -gt 0 ]; do
    case "$1" in
        --opensbi) OPEN_SBI_BIN="$2"; shift 2 ;;
        --uboot)   UBOOT_BIN="$2";     shift 2 ;;
        --dtb)     UBOOT_DTB="$2";     shift 2 ;;
        --out)     OUT_DIR="$2"; LOG="${OUT_DIR}/pack.log"; INFO="${OUT_DIR}/spi_flash_img_info.txt"
                   STUB_ELF="${OUT_DIR}/boot_stub.elf"; STUB_BIN="${OUT_DIR}/boot_stub.bin"
                   IMG="${OUT_DIR}/spi_flash.img"; shift 2 ;;
        --clean)   rm -f "${OUT_DIR}"/boot_stub.elf "${OUT_DIR}"/boot_stub.bin \
                         "${OUT_DIR}"/spi_flash.img "${OUT_DIR}"/spi_flash_img_info.txt
                   shift ;;
        -h|--help) sed -n '2,60p' "$SCRIPT_PATH"; exit 0 ;;
        *)         printf 'ERROR: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*" ; }
FAILED=0
pass() { printf 'PASS: %s\n' "$*" ; }
fail() { printf 'FAIL: %s\n' "$*" ; FAILED=1 ; }
norm_hex() { printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0x//; s/^0*//' ; }
check_eq() {   # check_eq <条目> <实得> <期望>
    if [ "$(norm_hex "$1")" = "$(norm_hex "$2")" ]; then
        pass "$3"
    else
        fail "$3（实得 $1，期望 $2）"
    fi
}
hexval() { printf '%d' "$(( $1 ))" ; }

mkdir -p "$OUT_DIR"
: > "$LOG"

say "== SPI 引导镜像打包：$(date -Is)"
say "== 仓库根   = ${REPO_ROOT}"
say "== 产物目录 = ${OUT_DIR}"
say "== payload  = OpenSBI ${OPEN_SBI_BIN}"
say "              U-Boot  ${UBOOT_BIN}"
say "              DTB     ${UBOOT_DTB}"

#------------------------------------------------------------------------------
# 判据①：工具链 + payload 存在且非空
#------------------------------------------------------------------------------
if [ ! -x "$CC" ]; then
    fail "判据①：工具链不存在：$CC（期望 /opt/riscv/bin/riscv32-unknown-linux-gnu-gcc）"
    say "SPI_IMAGE: FAILED（先解决工具链）"
    exit 1
fi
for pair in "OpenSBI:${OPEN_SBI_BIN}" "U-Boot:${UBOOT_BIN}" "DTB:${UBOOT_DTB}"; do
    name="${pair%%:*}"; path="${pair#*:}"
    if [ ! -s "$path" ]; then
        fail "判据①：${name} payload 缺失或为空：${path}（缺段禁止出镜像）"
    fi
done
if [ "$FAILED" -eq 0 ]; then
    pass "判据①：工具链 + 三个 payload 齐备（OpenSBI $(stat -c%s "$OPEN_SBI_BIN") B，U-Boot $(stat -c%s "$UBOOT_BIN") B，DTB $(stat -c%s "$UBOOT_DTB") B）"
else
    say "SPI_IMAGE: FAILED（缺段 ⇒ 不出镜像）"
    exit 1
fi

#------------------------------------------------------------------------------
# 判据②：解析桩 .equ 常量块（每个符号必须唯一）
#------------------------------------------------------------------------------
[ -r "$STUB_SRC" ] || { fail "判据②：桩源码不可读：${STUB_SRC}"; say "SPI_IMAGE: FAILED"; exit 1; }
#   .equ 取值允许 `0x...` 与十进制（如 .equ BOOT_SEG_COUNT, 3）两种写法；
#   解析结果统一归一成**裸十六进制数字**（不带 0x），调用侧一律写成 "0x$(...)"。
parse_equ_raw()   { sed -n "s/^[[:space:]]*\.equ[[:space:]]\+$1[[:space:]]*,[[:space:]]*\(0[xX][0-9A-Fa-f]\+\|[0-9]\+\).*$/\1/p" "$STUB_SRC" | head -n 1 ; }
parse_equ_count() { sed -n "s/^[[:space:]]*\.equ[[:space:]]\+$1[[:space:]]*,[[:space:]]*\(0[xX][0-9A-Fa-f]\+\|[0-9]\+\).*$/\1/p" "$STUB_SRC" | wc -l ; }
parse_equ_get() {
    local raw; raw="$(parse_equ_raw "$1")"
    [ -n "$raw" ] || { printf ''; return 0; }
    case "$raw" in
        0x*|0X*) printf '%s' "${raw#0x}" ;;
        *)       printf '%X' "$raw" ;;
    esac
}

EQU_SYMS="BOOT_FLASH_BASE BOOT_XIP_SIZE BOOT_SEG_COUNT
          BOOT_SRC_OPENSBI BOOT_DST_OPENSBI BOOT_LEN_OPENSBI
          BOOT_SRC_UBOOT   BOOT_DST_UBOOT   BOOT_LEN_UBOOT
          BOOT_SRC_DTB     BOOT_DST_DTB     BOOT_LEN_DTB
          BOOT_NEXT_ENTRY  BOOT_FDT_DST     BOOT_HARTID"
equ_bad=0
for s in $EQU_SYMS; do
    c="$(parse_equ_count "$s")"
    if [ "$c" -ne 1 ]; then
        fail "判据②：桩 .equ 符号 ${s} 出现 ${c} 次（要求恰好 1 次：唯一真源）"
        equ_bad=1
    fi
done
[ "$equ_bad" -eq 0 ] && pass "判据②：桩 .equ 常量块 15 个符号各定义一次（无重复/无缺失）"

E_SEG_COUNT="$(parse_equ_get BOOT_SEG_COUNT)"
E_FLASH_BASE="$(parse_equ_get BOOT_FLASH_BASE)"
E_XIP_SIZE="$(parse_equ_get BOOT_XIP_SIZE)"
E_SRC_OPENSBI="$(parse_equ_get BOOT_SRC_OPENSBI)"; E_DST_OPENSBI="$(parse_equ_get BOOT_DST_OPENSBI)"; E_LEN_OPENSBI="$(parse_equ_get BOOT_LEN_OPENSBI)"
E_SRC_UBOOT="$(parse_equ_get BOOT_SRC_UBOOT)";     E_DST_UBOOT="$(parse_equ_get BOOT_DST_UBOOT)";     E_LEN_UBOOT="$(parse_equ_get BOOT_LEN_UBOOT)"
E_SRC_DTB="$(parse_equ_get BOOT_SRC_DTB)";         E_DST_DTB="$(parse_equ_get BOOT_DST_DTB)";         E_LEN_DTB="$(parse_equ_get BOOT_LEN_DTB)"
E_NEXT_ENTRY="$(parse_equ_get BOOT_NEXT_ENTRY)";   E_FDT_DST="$(parse_equ_get BOOT_FDT_DST)"

check_eq "0x${E_SRC_OPENSBI:-0}" "$LAYOUT_OPENSBI_OFF" "判据③a：桩 BOOT_SRC_OPENSBI == LAYOUT_OPENSBI_OFF"
check_eq "0x${E_SRC_UBOOT:-0}"   "$LAYOUT_UBOOT_OFF"   "判据③b：桩 BOOT_SRC_UBOOT == LAYOUT_UBOOT_OFF"
check_eq "0x${E_SRC_DTB:-0}"     "$LAYOUT_DTB_OFF"     "判据③c：桩 BOOT_SRC_DTB == LAYOUT_DTB_OFF"
check_eq "0x${E_FLASH_BASE:-0}"  "0x1C000000"          "判据③d：桩 BOOT_FLASH_BASE == XIP 主窗口 0x1C000000"
check_eq "0x${E_XIP_SIZE:-0}"    "$LAYOUT_XIP_SIZE"    "判据③e：桩 BOOT_XIP_SIZE == LAYOUT_XIP_SIZE"
check_eq "0x${E_SEG_COUNT:-0}"   "0x3"                 "判据③f：桩 BOOT_SEG_COUNT == 3（段数）"
check_eq "0x${E_DST_OPENSBI:-0}" "$LAYOUT_OPENSBI_DST" "判据⑤a：桩 BOOT_DST_OPENSBI == LAYOUT_OPENSBI_DST"
check_eq "0x${E_DST_UBOOT:-0}"   "$LAYOUT_UBOOT_DST"   "判据⑤b：桩 BOOT_DST_UBOOT == LAYOUT_UBOOT_DST"
check_eq "0x${E_DST_DTB:-0}"     "$LAYOUT_DTB_DST"     "判据⑤c：桩 BOOT_DST_DTB == LAYOUT_DTB_DST"
check_eq "0x${E_NEXT_ENTRY:-0}"  "$LAYOUT_OPENSBI_DST" "判据⑤d：桩 BOOT_NEXT_ENTRY == OpenSBI 目的地址（跳转入口）"
check_eq "0x${E_FDT_DST:-0}"     "$LAYOUT_DTB_DST"     "判据⑤e：桩 BOOT_FDT_DST == DTB 目的地址（a1 口径）"

#------------------------------------------------------------------------------
# 判据④：段长 == payload 补齐到 4 的倍数
#   （整字 lw/sw 拷贝要求段长 4 字节对齐；打包时把 payload 零补齐到该长度）
#------------------------------------------------------------------------------
len_real() {   # len_real <file> → 补齐到 4 的倍数后的字节数
    local n; n="$(stat -c%s "$1")"
    printf '%d' "$(( (n + 3) / 4 * 4 ))"
}
R_OPEN_SBI="$(len_real "$OPEN_SBI_BIN")"
R_UBOOT="$(len_real "$UBOOT_BIN")"
R_DTB="$(len_real "$UBOOT_DTB")"
check_eq "0x${E_LEN_OPENSBI:-0}" "0x$(printf '%X' "$R_OPEN_SBI")" "判据④a：桩 BOOT_LEN_OPENSBI == fw_jump.bin 补齐长度"
check_eq "0x${E_LEN_UBOOT:-0}"   "0x$(printf '%X' "$R_UBOOT")"     "判据④b：桩 BOOT_LEN_UBOOT == u-boot.bin 补齐长度"
check_eq "0x${E_LEN_DTB:-0}"     "0x$(printf '%X' "$R_DTB")"       "判据④c：桩 BOOT_LEN_DTB == u-boot.dtb 补齐长度"

#------------------------------------------------------------------------------
# 判据⑥：布局合法性（对齐 / 不重叠 / 窗口与器件容量）
#------------------------------------------------------------------------------
align_ok() { printf '%d' "$(( $1 % $2 ))" ; }
align_check() {   # align_check <kind> <name> <val> <unit>
    if [ "$(align_ok "$3" "$4")" -ne 0 ]; then
        fail "判据⑥：${2} ${1} ${3} 未按 ${4} 字节对齐"
    fi
}
align_check "偏移"   "STUB"    "$LAYOUT_STUB_OFF"   4096
align_check "偏移"   "OPENSBI" "$LAYOUT_OPENSBI_OFF" 4096
align_check "偏移"   "UBOOT"   "$LAYOUT_UBOOT_OFF"   4096
align_check "偏移"   "DTB"     "$LAYOUT_DTB_OFF"     4096
align_check "长度"   "OPENSBI" "0x$(printf '%X' "$R_OPEN_SBI")" 4
align_check "长度"   "UBOOT"   "0x$(printf '%X' "$R_UBOOT")"    4
align_check "长度"   "DTB"     "0x$(printf '%X' "$R_DTB")"      4
align_check "目的地址" "OPENSBI" "$LAYOUT_OPENSBI_DST" 4
align_check "目的地址" "UBOOT"   "$LAYOUT_UBOOT_DST"   4
align_check "目的地址" "DTB"     "$LAYOUT_DTB_DST"     4
END_OPENSBI=$(( LAYOUT_OPENSBI_OFF + R_OPEN_SBI ))
END_UBOOT=$(( LAYOUT_UBOOT_OFF + R_UBOOT ))
END_DTB=$(( LAYOUT_DTB_OFF + R_DTB ))
if (( END_OPENSBI > LAYOUT_UBOOT_OFF )); then
    fail "判据⑥：OpenSBI 段 [0x$(printf '%X' "$LAYOUT_OPENSBI_OFF"),0x$(printf '%X' "$END_OPENSBI")) 与 U-Boot 段 @0x$(printf '%X' "$LAYOUT_UBOOT_OFF") 重叠（OpenSBI 长大 ⇒ 必须上调 UBOOT/DTB 偏移，两处同步改）"
fi
if (( END_UBOOT > LAYOUT_DTB_OFF )); then
    fail "判据⑥：U-Boot 段 [0x$(printf '%X' "$LAYOUT_UBOOT_OFF"),0x$(printf '%X' "$END_UBOOT")) 与 DTB 段 @0x$(printf '%X' "$LAYOUT_DTB_OFF") 重叠（U-Boot 长大 ⇒ 必须上调 DTB 偏移，两处同步改）"
fi
TOTAL="$END_DTB"
if (( TOTAL > LAYOUT_XIP_SIZE )); then
    fail "判据⑥：镜像总长 0x$(printf '%X' "$TOTAL") > XIP 主窗口 0x$(printf '%X' "$LAYOUT_XIP_SIZE")（超出部分在 0x1C10_0000 之上会静默落 DDR3）"
fi
if (( TOTAL > LAYOUT_FLASH_SIZE )); then
    fail "判据⑥：镜像总长 0x$(printf '%X' "$TOTAL") > SPI 器件容量 0x$(printf '%X' "$LAYOUT_FLASH_SIZE")"
fi
[ "$(align_ok "$LAYOUT_STUB_SLOT" 4)" -eq 0 ] || fail "判据⑥：桩槽 ${LAYOUT_STUB_SLOT} 未 4 字节对齐"
(( LAYOUT_STUB_SLOT <= LAYOUT_OPENSBI_OFF )) || fail "判据⑥：桩槽 0x$(printf '%X' "$LAYOUT_STUB_SLOT") 越过 OpenSBI 偏移 0x$(printf '%X' "$LAYOUT_OPENSBI_OFF")"

if [ "$FAILED" -eq 0 ]; then
    pass "判据⑥：布局合法（总长 0x$(printf '%X' "$TOTAL") = $TOTAL B ≤ XIP 1 MiB ≤ SPI 16 MiB；段间无重叠；对齐合规）"
else
    say "SPI_IMAGE: FAILED（布局非法 ⇒ 不出镜像）"
    exit 1
fi

#------------------------------------------------------------------------------
# 判据⑦：汇编 + 链接桩（链接脚本内有"桩 ≤ 16 KiB 槽"的 ASSERT 兜底）
#------------------------------------------------------------------------------
say "== 汇编桩：${STUB_SRC}"
printf '+ %s\n' "$CC -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles -ffreestanding -Wl,-T,${STUB_LDS} -Wl,-e,_stub_start -Wl,--build-id=none -o ${STUB_ELF} ${STUB_SRC}" >>"$LOG"
if "$CC" -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles -ffreestanding \
        -Wl,-T,"$STUB_LDS" -Wl,-e,_stub_start -Wl,--build-id=none \
        -o "$STUB_ELF" "$STUB_SRC" >>"$LOG" 2>&1 \
   && "$OBJCOPY" -O binary "$STUB_ELF" "$STUB_BIN" >>"$LOG" 2>&1; then
    pass "判据⑦：桩汇编/链接/转镜像 rc=0（boot_stub.bin = $(stat -c%s "$STUB_BIN") B）"
else
    fail "判据⑦：桩汇编/链接失败（详见 ${LOG}）"
    tail -n 15 "$LOG" | sed 's/^/    /'
    say "SPI_IMAGE: FAILED"
    exit 1
fi

#------------------------------------------------------------------------------
# 判据⑧：桩静态核对（入口/重定位/CSR/压缩指令/栈/访存形态）
#------------------------------------------------------------------------------
STUB_SIZE="$(stat -c%s "$STUB_BIN")"
if (( STUB_SIZE <= LAYOUT_STUB_SLOT )); then
    pass "判据⑧a：桩大小 ${STUB_SIZE} B ≤ 桩槽 ${LAYOUT_STUB_SLOT} B（0x4000）"
else
    fail "判据⑧a：桩大小 ${STUB_SIZE} B 超出桩槽 ${LAYOUT_STUB_SLOT} B"
fi

ENTRY="$( { "$READELF" -h "$STUB_ELF" | awk '/Entry point address/ {print $NF}'; } 2>/dev/null || true )"
check_eq "${ENTRY:-0}" "0x1C000000" "判据⑧b：桩 ELF 入口 == 0x1C000000（复位取指 / XIP 主窗口）"

RELOC_N="$( { "$READELF" -r "$STUB_ELF" | grep -c 'R_RISCV' ; } 2>/dev/null || true )"
if [ "${RELOC_N:-0}" -eq 0 ]; then
    pass "判据⑧c：桩 ELF 零重定位（readelf -r 无 R_RISCV_* ⇒ 纯 PC 相对，无运行期地址解析）"
else
    fail "判据⑧c：桩 ELF 含 ${RELOC_N} 条重定位（破坏「纯 PC 相对」口径）"
fi

DIS="$( { "$OBJDUMP" -d "$STUB_ELF"; } 2>/dev/null || true )"
CSR_N="$(  { printf '%s\n' "$DIS" | grep -cE '\b(csrrw|csrrs|csrrc|csrrwi|csrrsi|csrrci)\b' ; } 2>/dev/null || true )"
SFENCE_N="$( { printf '%s\n' "$DIS" | grep -cE '\b(sfence\.vma|fence\.i|ecall|ebreak|mret|sret|wfi)\b' ; } 2>/dev/null || true )"
SP_N="$(   { printf '%s\n' "$DIS" | grep -cE '\b(lw|sw|lh|lhu|sh|lb|lbu|sb)[[:space:]]+[a-z0-9]+,[[:space:]]*-?[0-9]+\(sp\)' ; } 2>/dev/null || true )"
#   压缩指令在 objdump 里是 4 个十六进制数字（32 bit 指令是 8 个）⇒ 用"4 位后紧跟空白"判定
C_N="$(    { printf '%s\n' "$DIS" | grep -cE '^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{4}[[:space:]]' ; } 2>/dev/null || true )"
MEM_FORMS="$( { printf '%s\n' "$DIS" | grep -oE '\b(lw|sw|lh|lhu|sh|lb|lbu|sb)\b' | LC_ALL=C sort -u | tr '\n' ' ' ; } 2>/dev/null || true )"
if [ "${CSR_N:-0}" -eq 0 ] && [ "${SFENCE_N:-0}" -eq 0 ]; then
    pass "判据⑧d：桩反汇编无 CSR 指令、无 sfence/fence.i/ecall/ebreak/mret/sret/wfi（不开 MMU、不改 CSR）"
else
    fail "判据⑧d：桩反汇编出现 CSR=${CSR_N:-0} 条、特权/同步指令=${SFENCE_N:-0} 条（桩必须只做拷贝+跳转）"
fi
if [ "${C_N:-0}" -eq 0 ]; then
    pass "判据⑧e：桩全程 32 bit 指令（无压缩指令，取指口径与冻结 2A 核一致）"
else
    fail "判据⑧e：桩反汇编含 ${C_N} 条 16 bit 压缩指令（应保持 norvc）"
fi
if [ "${SP_N:-0}" -eq 0 ]; then
    pass "判据⑧f：桩无栈访存（无以 sp 为基址的 lw/sw，无 .bss/栈依赖）"
else
    fail "判据⑧f：桩出现 ${SP_N} 处 sp 基址访存（引导桩不得依赖栈）"
fi
mem_form_bad=0
for f in $MEM_FORMS; do
    case "$f" in lw|sw) ;; *) mem_form_bad=1 ;; esac
done
if [ "$mem_form_bad" -eq 0 ] && [ -n "${MEM_FORMS// /}" ]; then
    pass "判据⑧g：桩只使用 lw/sw 两种访存（实测：${MEM_FORMS}）"
else
    fail "判据⑧g：桩出现 lw/sw 之外的访存或完全没有访存（实测：${MEM_FORMS:-<空>}）—— 拷贝必须整字进行"
fi

#------------------------------------------------------------------------------
# 判据⑨：桩镜像里的段表字面值 == .equ 声明（nm 定位 + 镜像切片）
#------------------------------------------------------------------------------
NM_ALL="$( { "$NM" -n "$STUB_ELF"; } 2>/dev/null || true )"
sym_val() { printf '%s\n' "$NM_ALL" | awk -v s="$1" '$NF==s {print $1; exit}' ; }
TBL_ADDR="$(sym_val stub_seg_table)"
TBL_END="$(sym_val stub_seg_table_end)"
if [ -n "$TBL_ADDR" ] && [ -n "$TBL_END" ]; then
    TBL_OFF=$(( 0x${TBL_ADDR} - 0x1C000000 ))
    TBL_BYTES=$(( 0x${TBL_END} - 0x${TBL_ADDR} ))
    TBL_HEX="$( { $OD -An -tx4 -N"$TBL_BYTES" -j"$TBL_OFF" "$STUB_BIN" | tr -s ' ' '\n' | grep -v '^$'; } 2>/dev/null || true )"
    EXP_HEX="$(printf '%08x\n%08x\n%08x\n%08x\n%08x\n%08x\n%08x\n%08x\n%08x\n' \
                "$LAYOUT_OPENSBI_OFF" "$LAYOUT_OPENSBI_DST" "$R_OPEN_SBI" \
                "$LAYOUT_UBOOT_OFF"   "$LAYOUT_UBOOT_DST"   "$R_UBOOT" \
                "$LAYOUT_DTB_OFF"     "$LAYOUT_DTB_DST"     "$R_DTB")"
    if [ "$(printf '%s' "$TBL_HEX" | tr 'A-F' 'a-f')" = "$(printf '%s' "$EXP_HEX" | tr 'A-F' 'a-f')" ]; then
        pass "判据⑨：桩镜像段表 @+0x$(printf '%X' "$TBL_OFF") == {偏移,目的,长度}×3（与 .equ/布局逐字一致）"
    else
        fail "判据⑨：桩镜像段表与声明不一致"
        printf '    实得：%s\n    期望：%s\n' "$(printf '%s' "$TBL_HEX" | tr '\n' ' ')" "$(printf '%s' "$EXP_HEX" | tr '\n' ' ')"
    fi
else
    fail "判据⑨：符号表找不到 stub_seg_table/stub_seg_table_end（无法核对段表字面值）"
fi

if [ "$FAILED" -ne 0 ]; then
    say "SPI_IMAGE: FAILED（桩静态核对未过 ⇒ 不出镜像）"
    exit 1
fi

#------------------------------------------------------------------------------
# 打包镜像：零填充 + 逐段按偏移写入
#------------------------------------------------------------------------------
say "== 打包镜像：${IMG}（总长 0x$(printf '%X' "$TOTAL") = ${TOTAL} B）"
rm -f "$IMG"
# 稀疏占位：整镜像零填充（未用区域全 0 ⇒ md5 稳定；烧写时按整镜像写）
dd if=/dev/zero of="$IMG" bs=4096 count=$(( TOTAL / 4096 )) status=none
if [ "$(( TOTAL % 4096 ))" -ne 0 ]; then
    dd if=/dev/zero of="$IMG" bs=1 count="$(( TOTAL - (TOTAL / 4096) * 4096 ))" seek="$(( (TOTAL / 4096) * 4096 ))" conv=notrunc status=none >>"$LOG" 2>&1
fi
place() {   # place <file> <offset> <padded_len>
    local f="$1" off="$2" len="$3" tmp="$4"
    cp -f "$f" "$tmp"
    truncate -s "$len" "$tmp"
    dd if="$tmp" of="$IMG" bs=4096 seek="$(( off / 4096 ))" conv=notrunc status=none >>"$LOG" 2>&1
}
place "$STUB_BIN"     "$LAYOUT_STUB_OFF"     "$STUB_SIZE"   "${OUT_DIR}/.pad_stub"
place "$OPEN_SBI_BIN" "$LAYOUT_OPENSBI_OFF"  "$R_OPEN_SBI"  "${OUT_DIR}/.pad_opensbi"
place "$UBOOT_BIN"    "$LAYOUT_UBOOT_OFF"    "$R_UBOOT"     "${OUT_DIR}/.pad_uboot"
place "$UBOOT_DTB"    "$LAYOUT_DTB_OFF"      "$R_DTB"       "${OUT_DIR}/.pad_dtb"
rm -f "${OUT_DIR}/.pad_stub" "${OUT_DIR}/.pad_opensbi" "${OUT_DIR}/.pad_uboot" "${OUT_DIR}/.pad_dtb"

#------------------------------------------------------------------------------
# 判据⑩：逐段切片 == 源 payload（逐字节），并打印逐段 md5
#------------------------------------------------------------------------------
say ""
say "------------------------------------------------------------------------"
say " 引导镜像布局表（sw/boot/build_spi_image.sh 声明 + boot_stub.S .equ 双源核对通过）"
say "------------------------------------------------------------------------"
printf ' %-9s %-10s %-10s %-12s %-12s %-34s\n' "段" "Flash偏移" "长度(B)" "目的地址" "余量(B)" "md5（源 payload）"
for row in "STUB:${LAYOUT_STUB_OFF}:${STUB_SIZE}:<XIP 就地执行>:$(( LAYOUT_OPENSBI_OFF - STUB_SIZE )):${STUB_BIN}" \
           "OPENSBI:${LAYOUT_OPENSBI_OFF}:${R_OPEN_SBI}:${LAYOUT_OPENSBI_DST}:$(( LAYOUT_UBOOT_OFF - END_OPENSBI )):${OPEN_SBI_BIN}" \
           "UBOOT:${LAYOUT_UBOOT_OFF}:${R_UBOOT}:${LAYOUT_UBOOT_DST}:$(( LAYOUT_DTB_OFF - END_UBOOT )):${UBOOT_BIN}" \
           "DTB:${LAYOUT_DTB_OFF}:${R_DTB}:${LAYOUT_DTB_DST}:$(( LAYOUT_XIP_SIZE - END_DTB )):${UBOOT_DTB}"; do
    name="${row%%:*}";     row="${row#*:}"
    off="${row%%:*}";      row="${row#*:}"
    len="${row%%:*}";      row="${row#*:}"
    dst="${row%%:*}";      row="${row#*:}"
    slack="${row%%:*}";    src="${row#*:}"
    md5="$(md5sum "$src" | awk '{print $1}')"
    printf ' %-9s 0x%06X   0x%06X   %-12s %-12s %s\n' "$name" "$off" "$len" "$dst" "$slack" "$md5"
    # 切片核对：镜像 [off, off+len) 的前 len_src 字节必须与源文件逐字节相同（尾字节是零补齐）
    len_src="$(stat -c%s "$src")"
    #   ★ dd 的 skip 不认 0x 前缀（实测 `dd: invalid number: '0x0E8000'`）⇒ 先转十进制。
    #   dd 侧 stderr 丢弃（cmp 退出早会让 dd 报 broken pipe，属噪声；判据看 cmp 的 rc）。
    if dd if="$IMG" bs=1 skip="$(( off ))" count="$len_src" status=none 2>/dev/null | cmp -s - "$src"; then
        pass "判据⑩：${name} 段镜像切片 @0x$(printf '%X' "$off") 与源 payload 逐字节相同（${len_src} B）"
    else
        fail "判据⑩：${name} 段镜像切片与源 payload 不一致（偏移 0x$(printf '%X' "$off")）"
    fi
done
say "------------------------------------------------------------------------"
IMG_SIZE="$(stat -c%s "$IMG")"
IMG_MD5="$(md5sum "$IMG" | awk '{print $1}')"
say " 镜像：${IMG}"
say " 大小：${IMG_SIZE} B（0x$(printf '%X' "$IMG_SIZE")）   md5：${IMG_MD5}"
say " 烧写：从 SPI Flash 偏移 0 起写满该镜像（见 sw/M5-board-runbook.md 引导链节）"
say "------------------------------------------------------------------------"

{
    printf '# SPI 引导镜像证据（sw/boot/build_spi_image.sh 生成）\n'
    printf '时间      : %s\n' "$(date -Is)"
    printf '镜像      : %s\n' "$IMG"
    printf '镜像大小  : %s B (0x%X)\n' "$IMG_SIZE" "$IMG_SIZE"
    printf '镜像 md5  : %s\n' "$IMG_MD5"
    printf '布局      : STUB@0x%X(槽0x%X) OPENSBI@0x%X(%s B→0x%X) UBOOT@0x%X(%s B→0x%X) DTB@0x%X(%s B→0x%X)\n' \
           "$LAYOUT_STUB_OFF" "$LAYOUT_STUB_SLOT" "$LAYOUT_OPENSBI_OFF" "$R_OPEN_SBI" "$LAYOUT_OPENSBI_DST" \
           "$LAYOUT_UBOOT_OFF" "$R_UBOOT" "$LAYOUT_UBOOT_DST" "$LAYOUT_DTB_OFF" "$R_DTB" "$LAYOUT_DTB_DST"
    printf '桩镜像    : %s（%s B，入口 0x%X，零重定位）\n' "$STUB_BIN" "$STUB_SIZE" "$(( 0x1C000000 ))"
    printf 'payload md5:\n'
    printf '  boot_stub.bin : %s\n' "$(md5sum "$STUB_BIN" | awk '{print $1}')"
    printf '  OpenSBI       : %s (%s)\n' "$(md5sum "$OPEN_SBI_BIN" | awk '{print $1}')" "$OPEN_SBI_BIN"
    printf '  U-Boot        : %s (%s)\n' "$(md5sum "$UBOOT_BIN" | awk '{print $1}')" "$UBOOT_BIN"
    printf '  DTB           : %s (%s)\n' "$(md5sum "$UBOOT_DTB" | awk '{print $1}')" "$UBOOT_DTB"
} > "$INFO"
say "== 证据已写入：${INFO}"

if [ "$FAILED" -eq 0 ]; then
    say "SPI_IMAGE: OK（${IMG_SIZE} B，md5 ${IMG_MD5}）"
    exit 0
fi
say "SPI_IMAGE: FAILED（见上）"
exit 1
