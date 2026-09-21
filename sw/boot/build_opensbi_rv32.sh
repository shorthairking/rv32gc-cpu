#!/usr/bin/env bash
#==============================================================================
# sw/boot/build_opensbi_rv32.sh —— RV32 OpenSBI（FW_JUMP / PLATFORM=generic）可复现构建
#==============================================================================
# 项目 : rv32gc-cpu（阶段三 B-3.5 引导链）
# 依据 : docs/porting/03-linux-opensbi.md §4（FW_JUMP + FW_JUMP_FDT_ADDR 路线、构建命令）
#        docs/porting/01-overview.md §2.3（DDR 布局：OpenSBI 0x0100_0000 / U-Boot 0x0200_0000）
#        docs/porting/02-uboot.md §8.6（U-Boot CONFIG_TEXT_BASE = 0x0200_0000）
#
# 用法 :
#   sw/boot/build_opensbi_rv32.sh [-j N] [--opensbi DIR] [--out DIR]
#   默认 : opensbi 树 = <workspace>/opensbi（本机克隆）；产物 = sw/boot/out/opensbi-build/
#
# 产物 :
#   <out>/opensbi-build/platform/generic/firmware/fw_jump.bin   ← 引导链的 OpenSBI 段
#   <out>/opensbi-build/platform/generic/firmware/fw_jump.elf
#   <out>/opensbi_build_info.txt                                ← 版本/命令/大小/md5（交付证据）
#   <out>/opensbi_build.log                                     ← 完整构建日志
#
# 判据（全部满足 ⇒ rc=0；任一不满足 ⇒ 打印 FAIL: <条目> 并 rc=1）：
#   ① opensbi/ 树存在，且构建前后 `git status --porcelain` **逐字不变**
#      （本脚本只允许"用构建参数"，绝不允许改 opensbi 源码 —— 建在 O=<out> 外部构建目录里）；
#   ② make rc=0；
#   ③ fw_jump.bin 存在且非空、大小 4 字节对齐（引导桩按整字拷贝）；
#   ④ ELF 入口 = 0x0100_0000（FW_TEXT_START）且 ELF32（RV32）；
#   ⑤ fw_jump 的跳转地址常量 == 0x0200_0000（FW_JUMP_ADDR，反汇编 `_jump_addr` 处 .word）；
#   ⑥ FDT 目的地址常量 == 0x0300_0000（FW_JUMP_FDT_ADDR，反汇编 fw_next_arg1 的 lui a0,0x3000）；
#   ⑦ 反汇编 `_fw_start` 首地址 == 0x0100_0000（镜像偏移 0 就是入口 ⇒ 桩从偏移 0 拷即可）。
#
# 为什么这三组地址是本项目口径（改之前先读 docs/porting/01-overview.md §2.3/§2.4）：
#   FW_TEXT_START   = 0x0100_0000 —— OpenSBI 运行地址（引导桩把 fw_jump.bin 拷到这里）
#   FW_JUMP_ADDR    = 0x0200_0000 —— 下一级 = U-Boot，必须与 CONFIG_TEXT_BASE 逐字一致
#   FW_JUMP_FDT_ADDR= 0x0300_0000 —— OpenSBI 把 a1 传入的 DTB 搬到 0x0300_0000 后
#                                    再 mret 到 U-Boot（a1 原样 = 我们的 DTB 目的地址）
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
WORKSPACE="$(cd -- "${REPO_ROOT}/.." && pwd -P)"

OPEN_SBI_DIR="${WORKSPACE}/opensbi"
OUT_DIR="${SCRIPT_DIR}/out"
JOBS=""
LOG="${OUT_DIR}/opensbi_build.log"
INFO="${OUT_DIR}/opensbi_build_info.txt"

TOOLCHAIN_PREFIX="${TOOLCHAIN_PREFIX:-/opt/riscv/bin/riscv32-unknown-linux-gnu-}"
CROSS_COMPILE="$(basename -- "${TOOLCHAIN_PREFIX}")"
CC="${TOOLCHAIN_PREFIX}gcc"
OBJDUMP="${TOOLCHAIN_PREFIX}objdump"
READELF="${TOOLCHAIN_PREFIX}readelf"
NM="${TOOLCHAIN_PREFIX}nm"

FW_TEXT_START=0x01000000
FW_JUMP_ADDR=0x02000000
FW_JUMP_FDT_ADDR=0x03000000
PLATFORM=generic

while [ $# -gt 0 ]; do
    case "$1" in
        -j)          JOBS="$2"; shift 2 ;;
        -j*)         JOBS="${1#-j}"; shift ;;
        --opensbi)   OPEN_SBI_DIR="$2"; shift 2 ;;
        --out)       OUT_DIR="$2"; LOG="${OUT_DIR}/opensbi_build.log"; INFO="${OUT_DIR}/opensbi_build_info.txt"; shift 2 ;;
        --clean)     rm -rf "${OUT_DIR}/opensbi-build"; shift ;;
        -h|--help)   sed -n '2,45p' "$SCRIPT_PATH"; exit 0 ;;
        *)           printf 'ERROR: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$JOBS" ] || JOBS="$( (nproc 2>/dev/null || echo 4) )"

say() { printf '%s\n' "$*" ; }
FAILED=0
check() {                     # check <判据名> <命令...>
    local name="$1"; shift
    if "$@" >>"$LOG" 2>&1; then
        say "PASS: ${name}"
    else
        say "FAIL: ${name}"
        FAILED=1
    fi
}
check_eq() {                  # check_eq <判据名> <实得> <期望>
    local name="$1" got="$2" exp="$3"
    local g e
    g="$(norm_hex "$got")"
    e="$(norm_hex "$exp")"
    if [ "$g" = "$e" ]; then
        say "PASS: ${name}（= ${exp}）"
    else
        say "FAIL: ${name}（实得 ${got}，期望 ${exp}）"
        FAILED=1
    fi
}
# 十六进制文本归一（"0x01000000" / "0x1000000" / "01000000" 视为相等）
norm_hex() { printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0x//; s/^0*//' ; }
# 从符号表取符号地址（找不到返回空串；失败不中断脚本）
sym_addr() { { nm_symbols "$1" | awk -v s="$2" '$NF==s {print $1; exit}'; } 2>/dev/null || true ; }
nm_symbols() { { "$NM" -n "$1"; } 2>/dev/null || true ; }

mkdir -p "$OUT_DIR"
: > "$LOG"

say "== OpenSBI RV32 FW_JUMP 构建：$(date -Is)"
say "== opensbi 树 = ${OPEN_SBI_DIR}"
say "== 产物目录   = ${OUT_DIR}/opensbi-build"
say "== 参数       = PLATFORM=${PLATFORM} FW_JUMP=y FW_TEXT_START=${FW_TEXT_START} FW_JUMP_ADDR=${FW_JUMP_ADDR} FW_JUMP_FDT_ADDR=${FW_JUMP_FDT_ADDR}"

if [ ! -x "$CC" ]; then
    say "FAIL: 工具链不存在：$CC（期望 /opt/riscv/bin/riscv32-unknown-linux-gnu-gcc）"
    exit 1
fi
if [ ! -d "$OPEN_SBI_DIR" ] || [ ! -f "${OPEN_SBI_DIR}/Makefile" ]; then
    say "FAIL: opensbi 树不可用：${OPEN_SBI_DIR}（--opensbi DIR 覆盖）"
    exit 1
fi

#------------------------------------------------------------------------------
# 判据①：源码树清洁度（构建前后必须逐字不变；只允许外部构建目录 O=<out>）
#------------------------------------------------------------------------------
STATUS_BEFORE="$(git -C "$OPEN_SBI_DIR" status --porcelain 2>/dev/null || true)"
REV="$(git -C "$OPEN_SBI_DIR" log -1 --format='%H %ad %s' --date=short 2>/dev/null || echo '<非 git 树>')"
say "== opensbi 版本：${REV}"
say "== 构建前 dirty 行数：$(printf '%s\n' "$STATUS_BEFORE" | grep -c . || true)"

#------------------------------------------------------------------------------
# 构建（外部构建目录；不改源码树）
#------------------------------------------------------------------------------
BUILD_DIR="${OUT_DIR}/opensbi-build"
MAKE_ARGS=( -C "$OPEN_SBI_DIR" O="$BUILD_DIR" PLATFORM="$PLATFORM"
            CROSS_COMPILE="$CROSS_COMPILE"
            FW_JUMP=y
            FW_TEXT_START="$FW_TEXT_START"
            FW_JUMP_ADDR="$FW_JUMP_ADDR"
            FW_JUMP_FDT_ADDR="$FW_JUMP_FDT_ADDR"
            -j"$JOBS" )
say "== make ${MAKE_ARGS[*]}"
printf '+ make %s\n' "${MAKE_ARGS[*]}" >>"$LOG"
rc=0
make "${MAKE_ARGS[@]}" >>"$LOG" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    say "PASS: 判据②：make rc=0"
else
    say "FAIL: 判据②：make rc=${rc}（日志尾部）"
    tail -n 20 "$LOG" | sed 's/^/    /'
    exit 1
fi

STATUS_AFTER="$(git -C "$OPEN_SBI_DIR" status --porcelain 2>/dev/null || true)"
DIRTY_AFTER="$(printf '%s\n' "$STATUS_AFTER" | grep -c . || true)"
if [ "$STATUS_BEFORE" = "$STATUS_AFTER" ]; then
    say "PASS: 判据①：opensbi 源码树在构建前后逐字未变（dirty 行数 ${DIRTY_AFTER}）"
else
    say "FAIL: 判据①：opensbi 源码树被改动（构建前后 git status 不一致）—— 本脚本只许用构建参数"
    diff <(printf '%s\n' "$STATUS_BEFORE") <(printf '%s\n' "$STATUS_AFTER") | sed 's/^/    /' || true
    FAILED=1
fi

FW_BIN="${BUILD_DIR}/platform/${PLATFORM}/firmware/fw_jump.bin"
FW_ELF="${BUILD_DIR}/platform/${PLATFORM}/firmware/fw_jump.elf"
[ -f "$FW_BIN" ] || { say "FAIL: 判据③：产物不存在 ${FW_BIN}"; exit 1; }
SIZE="$(stat -c%s "$FW_BIN")"
MD5="$(md5sum "$FW_BIN" | awk '{print $1}')"

say "== 产物："
say "   fw_jump.bin : ${FW_BIN}"
say "   size        : ${SIZE} B ($(printf '0x%X' "$SIZE"))"
say "   md5         : ${MD5}"
say "   fw_jump.elf : ${FW_ELF}"

#------------------------------------------------------------------------------
# 判据③：大小与对齐
#------------------------------------------------------------------------------
if [ "$SIZE" -gt 0 ] && [ $((SIZE % 4)) -eq 0 ]; then
    say "PASS: 判据③：fw_jump.bin 非空且 4 字节对齐（${SIZE} B）"
else
    say "FAIL: 判据③：fw_jump.bin 为空或非 4 字节对齐（size=${SIZE}）"
    FAILED=1
fi

#------------------------------------------------------------------------------
# 判据④：ELF 入口/类别（RV32）
#------------------------------------------------------------------------------
ENTRY="$( { "$READELF" -h "$FW_ELF" | awk '/Entry point address/ {print $NF}'; } 2>/dev/null || true )"
CLASS="$( { "$READELF" -h "$FW_ELF" | awk '/Class:/ {print $2}'; } 2>/dev/null || true )"
check_eq "判据④a：ELF 入口 = FW_TEXT_START" "${ENTRY:-<空>}" "$FW_TEXT_START"
check_eq "判据④b：ELF class = ELF32（RV32）" "${CLASS:-<空>}" "ELF32"

#------------------------------------------------------------------------------
# 判据⑤/⑥/⑦：三个地址常量与入口偏移都在反汇编里机器核对
#   ⑤ `_jump_addr`（.rodata）处的 .word == FW_JUMP_ADDR
#   ⑥ fw_next_arg1 的 `li a0, FW_JUMP_FDT_ADDR`（lui a0,0x3000）
#   ⑦ `_fw_start` 的地址 == FW_TEXT_START
#------------------------------------------------------------------------------
DIS="$( { "$OBJDUMP" -d "$FW_ELF"; } 2>/dev/null || true )"
#   ★ 纪律：判定一律用 `grep -c` 数数再比大小，**不用 `grep -q`** —— 本脚本 set -o pipefail，
#     `printf | grep -q` 里 grep 提前退出会让 printf 收 SIGPIPE ⇒ 管道整体判非零（假 FAIL）。
HIT_FW_START="$( { printf '%s\n' "$DIS" | grep -cE '^01000000 <_fw_start>:' ; } 2>/dev/null || true )"
HIT_FDT_LUI="$(  { printf '%s\n' "$DIS" | grep -cE 'lui[[:space:]]+a0,[[:space:]]*0x3000'   ; } 2>/dev/null || true )"

# 判据⑤：精确核对 FIRMWARE 里 FW_JUMP_ADDR 的**字面值**（不靠模糊的 lui 扫描）
ADDR_JUMP="$(sym_addr "$FW_ELF" _jump_addr)"
if [ -n "$ADDR_JUMP" ] && [ $((0x${ADDR_JUMP} - 0x${FW_TEXT_START#0x})) -ge 0 ] \
   && [ $((0x${ADDR_JUMP} - 0x${FW_TEXT_START#0x})) -lt "$SIZE" ]; then
    JUMP_WORD="$(od -An -tx4 -N4 -j $((0x${ADDR_JUMP} - 0x${FW_TEXT_START#0x})) "$FW_BIN" \
                 | tr -d ' \n' | tr 'A-F' 'a-f' | sed 's/^0*//')"
    check_eq "判据⑤：_jump_addr 字面值 == FW_JUMP_ADDR（符号 @0x${ADDR_JUMP}）" "0x${JUMP_WORD:-0}" "$FW_JUMP_ADDR"
else
    say "FAIL: 判据⑤：符号表里找不到 _jump_addr（或地址越界）：'${ADDR_JUMP:-<空>}'（FW_JUMP_ADDR 无法机器核对）"
    FAILED=1
fi

# 判据⑥：FW_JUMP_FDT_ADDR 由 fw_next_arg1 的 `li a0, 0x03000000` 落地
if [ "${HIT_FDT_LUI:-0}" -ge 1 ]; then
    say "PASS: 判据⑥：fw_next_arg1 的 lui a0,0x3000 命中 ${HIT_FDT_LUI} 处（FW_JUMP_FDT_ADDR=${FW_JUMP_FDT_ADDR}）"
else
    say "FAIL: 判据⑥：反汇编中找不到 fw_next_arg1 的 lui a0,0x3000（FW_JUMP_FDT_ADDR 未落地）"
    FAILED=1
fi

# 判据⑦：镜像偏移 0 = 入口（_fw_start 在 FW_TEXT_START，且 .bin 从该地址开始）
ADDR_FW_START="$(sym_addr "$FW_ELF" _fw_start)"
check_eq "判据⑦a：符号 _fw_start == FW_TEXT_START" "0x${ADDR_FW_START:-0}" "$FW_TEXT_START"
FIRST_WORD="$(od -An -tx4 -N4 -j 0 "$FW_BIN" | tr -d ' \n')"
DIS_FIRST="$( { printf '%s\n' "$DIS" | awk '/^01000000 <_fw_start>:/ {getline_ok=1; next} getline_ok && /^ / {print $2; exit}' ; } 2>/dev/null || true )"
if [ "${HIT_FW_START:-0}" -eq 1 ] && [ -n "$DIS_FIRST" ] \
   && [ "$(norm_hex "$FIRST_WORD")" = "$(norm_hex "$DIS_FIRST")" ]; then
    say "PASS: 判据⑦b：fw_jump.bin 首字（${FIRST_WORD}）== 0x01000000 处首条指令（${DIS_FIRST}）"
else
    say "FAIL: 判据⑦b：镜像首字与 0x01000000 处首条指令不一致（bin=${FIRST_WORD} dis=${DIS_FIRST:-<空>}，_fw_start 标注命中 ${HIT_FW_START:-0}）"
    FAILED=1
fi

#------------------------------------------------------------------------------
# 证据留档（交付说明引用本文件）
#------------------------------------------------------------------------------
{
    printf '# OpenSBI RV32 FW_JUMP 构建证据（sw/boot/build_opensbi_rv32.sh 生成）\n'
    printf '时间          : %s\n' "$(date -Is)"
    printf 'opensbi 版本  : %s\n' "$REV"
    printf '源码树 dirty  : %s 行（构建前后一致：%s）\n' \
           "${DIRTY_AFTER:-0}" \
           "$([ "$STATUS_BEFORE" = "$STATUS_AFTER" ] && echo yes || echo no)"
    printf '构建命令      : make %s\n' "${MAKE_ARGS[*]}"
    printf 'fw_jump.bin   : %s\n' "$FW_BIN"
    printf 'fw_jump.bin 大小: %s B (0x%X)\n' "$SIZE" "$SIZE"
    printf 'fw_jump.bin md5 : %s\n' "$MD5"
    printf 'fw_jump.elf   : %s\n' "$FW_ELF"
    printf 'ELF 入口      : %s（期望 %s）\n' "${ENTRY:-<空>}" "$FW_TEXT_START"
    printf 'FW_JUMP_ADDR  : %s\n' "$FW_JUMP_ADDR"
    printf 'FW_JUMP_FDT_ADDR: %s\n' "$FW_JUMP_FDT_ADDR"
} > "$INFO"
say "== 证据已写入：${INFO}"

if [ "$FAILED" -eq 0 ]; then
    say "OPENSBI_BUILD: OK（${SIZE} B，md5 ${MD5}）"
    exit 0
fi
say "OPENSBI_BUILD: FAILED（见上）"
exit 1
