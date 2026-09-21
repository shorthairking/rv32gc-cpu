#!/usr/bin/env bash
#==============================================================================
# sw/boot/check_stub_layout.sh —— "桩常量表 ↔ 打包脚本布局"机器一致性核对（+ 仿真字表生成）
#==============================================================================
# 项目 : rv32gc-cpu（阶段三 B-3.5 引导链）
# 依据 : AGENT.md §3.2（位域/接口先改唯一真源再同步；回归脚本"未捕获即失败"）
#        docs/porting/01-overview.md §2.2/§2.3（XIP 启动与 DDR 布局）
#
# 为什么需要这个脚本（双源漂移检测）：
#   布局在**两处**声明（这是有意的：桩必须自己知道自己要拷什么）：
#     ① sw/boot/boot_stub.S 的 .equ 常量块   —— 桩运行时用的偏移/目的/长度；
#     ② sw/boot/build_spi_image.sh 的 LAYOUT_* —— 打包脚本按它写镜像。
#   两处不一致 ⇒ 桩会从错误的偏移读、或写到错误的目的地址，而**编译期毫无提示**。
#   本脚本用**独立实现**（不与打包脚本共用函数）把两处逐项对账，并再拉两个外部真值：
#     ③ 真实 payload 文件大小（补齐到 4）与桩 .equ 段长对账；
#     ④ 已打包 spi_flash.img 的**分段切片**与源 payload 逐字节对账（端到端）。
#
# 用法 :
#   sw/boot/check_stub_layout.sh                    # 核对（rc=0 = 一致；rc=1 = 漂移/缺失）
#   sw/boot/check_stub_layout.sh --update-sim-words # 生成/刷新 TB 内嵌字表（见下）
#   sw/boot/check_stub_layout.sh --sim-lens 0x1000 0x2000 0x400   # 仿真构型段长（配合上一行）
#   sw/boot/check_stub_layout.sh --opensbi F --uboot F --dtb F     # payload 路径覆盖
#
# 判据（默认模式；全部满足 ⇒ rc=0 且打印 `STUB_LAYOUT: OK`）：
#   ① 桩 .equ 常量块可解析且每个符号唯一；
#   ② 桩 .equ 的 段偏移/目的地址/段数/Flash 基址/XIP 容量 == build_spi_image.sh 的 LAYOUT_*；
#   ③ 桩 .equ 段长 == 真实 payload 大小补齐到 4 的倍数；
#   ④ 布局合法（4 KiB 对齐 / 段不重叠 / 总长 ≤ 1 MiB XIP 窗口）；
#   ⑤ spi_flash.img 存在，且每段 [偏移, 偏移+长度) 切片与源 payload 逐字节相同；
#   ⑥ 仿真字表未过期：用同一份 boot_stub.S + --defsym 小长度**重新汇编**，生成的
#      sim/unit/prog/boot_stub_words.svh 与磁盘上的逐字节一致（否则提示跑 --update-sim-words）。
#
# --update-sim-words 做什么：
#   用**同一份 boot_stub.S**（只把三个 BOOT_LEN_* 用 --defsym 换成小值；偏移/目的地址不变）
#   汇编出仿真构型，并与 sim/unit/prog/boot_stub_probe.S 一起，生成：
#     · sim/unit/prog/boot_stub_sim.hex    —— 桩镜像（objcopy -O verilog，审计/差分用）
#     · sim/unit/prog/boot_stub_words.svh  —— TB `include 的字表与布局常量
#     字表里的**布局常量取自汇编后的符号表**（nm），而不是脚本自己的数字 ⇒ 桩源码一改、
#     重跑本命令，TB 立刻跟着变（"改错一个常量 ⇒ TB 必红"的反证实验就靠这条链）。
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
WORKSPACE="$(cd -- "${REPO_ROOT}/.." && pwd -P)"

STUB_SRC="${SCRIPT_DIR}/boot_stub.S"
STUB_LDS="${SCRIPT_DIR}/boot_stub.ld"
PACK_SH="${SCRIPT_DIR}/build_spi_image.sh"
IMG="${SCRIPT_DIR}/out/spi_flash.img"
OPEN_SBI_BIN="${SCRIPT_DIR}/out/opensbi-build/platform/generic/firmware/fw_jump.bin"
UBOOT_BIN="${WORKSPACE}/u-boot/u-boot.bin"
UBOOT_DTB="${WORKSPACE}/u-boot/u-boot.dtb"

PROBE_SRC="${REPO_ROOT}/sim/unit/prog/boot_stub_probe.S"
SIM_HEX="${REPO_ROOT}/sim/unit/prog/boot_stub_sim.hex"
SIM_SVH="${REPO_ROOT}/sim/unit/prog/boot_stub_words.svh"

TOOLCHAIN_PREFIX="${TOOLCHAIN_PREFIX:-/opt/riscv/bin/riscv32-unknown-linux-gnu-}"
CC="${TOOLCHAIN_PREFIX}gcc"
OBJCOPY="${TOOLCHAIN_PREFIX}objcopy"
NM="${TOOLCHAIN_PREFIX}nm"

MODE="verify"
SIM_LEN_OPENSBI=0x1000     # 仿真构型：4 KiB（≥ probe 程序；TB 会断言）
SIM_LEN_UBOOT=0x2000       # 仿真构型：8 KiB
SIM_LEN_DTB=0x400          # 仿真构型：1 KiB

while [ $# -gt 0 ]; do
    case "$1" in
        --update-sim-words) MODE="update"; shift ;;
        --sim-lens)         SIM_LEN_OPENSBI="$2"; SIM_LEN_UBOOT="$3"; SIM_LEN_DTB="$4"; shift 4 ;;
        --opensbi)          OPEN_SBI_BIN="$2"; shift 2 ;;
        --uboot)            UBOOT_BIN="$2";   shift 2 ;;
        --dtb)              UBOOT_DTB="$2";   shift 2 ;;
        -h|--help)          sed -n '2,55p' "$SCRIPT_PATH"; exit 0 ;;
        *)                  printf 'ERROR: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
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
len_real() { local n; n="$(stat -c%s "$1")"; printf '%d' "$(( (n + 3) / 4 * 4 ))" ; }

#==============================================================================
# 一、解析两处声明（互为独立实现）
#==============================================================================
[ -r "$STUB_SRC" ] || { fail "① 桩源码不可读：${STUB_SRC}"; say "STUB_LAYOUT: FAILED"; exit 1; }
[ -r "$PACK_SH" ]  || { fail "① 打包脚本不可读：${PACK_SH}";  say "STUB_LAYOUT: FAILED"; exit 1; }

equ_cnt() { sed -n "s/^[[:space:]]*\.equ[[:space:]]\+$1[[:space:]]*,[[:space:]]*\(0x[0-9A-Fa-f]\+\|[0-9]\+\).*$/\1/p" "$STUB_SRC" | wc -l ; }
equ_raw() { sed -n "s/^[[:space:]]*\.equ[[:space:]]\+$1[[:space:]]*,[[:space:]]*\(0x[0-9A-Fa-f]\+\|[0-9]\+\).*$/\1/p" "$STUB_SRC" | head -n 1 ; }
equ_get() {   # → 裸十六进制数字（不带 0x）
    local raw; raw="$(equ_raw "$1")"
    [ -n "$raw" ] || { printf ''; return 0; }
    case "$raw" in
        0x*|0X*) printf '%s' "${raw#0x}" ;;
        *)       printf '%X' "$raw" ;;
    esac
}
lay_get() {   # 从 build_spi_image.sh 的声明行取裸十六进制（不含 0x；与 equ_get 口径一致）
    sed -n "s/^$1=0[xX]\([0-9A-Fa-f]\+\).*$/\1/p" "$PACK_SH" | head -n 1
}

SYMS="BOOT_FLASH_BASE BOOT_XIP_SIZE BOOT_SEG_COUNT
      BOOT_SRC_OPENSBI BOOT_DST_OPENSBI BOOT_LEN_OPENSBI
      BOOT_SRC_UBOOT   BOOT_DST_UBOOT   BOOT_LEN_UBOOT
      BOOT_SRC_DTB     BOOT_DST_DTB     BOOT_LEN_DTB
      BOOT_NEXT_ENTRY  BOOT_FDT_DST"
sym_bad=0
for s in $SYMS; do
    c="$(equ_cnt "$s")"
    [ "$c" -eq 1 ] || { fail "① 桩 .equ 符号 ${s} 出现 ${c} 次（要求 1 次）"; sym_bad=1; }
done
[ "$sym_bad" -eq 0 ] && pass "① 桩 .equ 常量块 $(set -- $SYMS; echo $#) 个符号各定义一次"

E_SRC_OPENSBI="$(equ_get BOOT_SRC_OPENSBI)"; E_DST_OPENSBI="$(equ_get BOOT_DST_OPENSBI)"; E_LEN_OPENSBI="$(equ_get BOOT_LEN_OPENSBI)"
E_SRC_UBOOT="$(equ_get BOOT_SRC_UBOOT)";     E_DST_UBOOT="$(equ_get BOOT_DST_UBOOT)";     E_LEN_UBOOT="$(equ_get BOOT_LEN_UBOOT)"
E_SRC_DTB="$(equ_get BOOT_SRC_DTB)";         E_DST_DTB="$(equ_get BOOT_DST_DTB)";         E_LEN_DTB="$(equ_get BOOT_LEN_DTB)"
E_FLASH_BASE="$(equ_get BOOT_FLASH_BASE)";   E_XIP_SIZE="$(equ_get BOOT_XIP_SIZE)"
E_SEG_COUNT="$(equ_get BOOT_SEG_COUNT)";     E_NEXT_ENTRY="$(equ_get BOOT_NEXT_ENTRY)"
E_FDT_DST="$(equ_get BOOT_FDT_DST)"

L_STUB_OFF="$(lay_get LAYOUT_STUB_OFF)";         L_STUB_SLOT="$(lay_get LAYOUT_STUB_SLOT)"
L_OSB_OFF="$(lay_get LAYOUT_OPENSBI_OFF)";       L_OSB_DST="$(lay_get LAYOUT_OPENSBI_DST)"
L_UB_OFF="$(lay_get LAYOUT_UBOOT_OFF)";          L_UB_DST="$(lay_get LAYOUT_UBOOT_DST)"
L_DTB_OFF="$(lay_get LAYOUT_DTB_OFF)";           L_DTB_DST="$(lay_get LAYOUT_DTB_DST)"
L_XIP_SIZE="$(lay_get LAYOUT_XIP_SIZE)";         L_FLASH_SIZE="$(lay_get LAYOUT_FLASH_SIZE)"

#==============================================================================
# 二、② 两处声明逐项对账
#==============================================================================
check_eq "0x${E_SRC_OPENSBI:-0}" "0x${L_OSB_OFF:-0}" "②a 桩 BOOT_SRC_OPENSBI == LAYOUT_OPENSBI_OFF"
check_eq "0x${E_SRC_UBOOT:-0}"   "0x${L_UB_OFF:-0}"  "②b 桩 BOOT_SRC_UBOOT == LAYOUT_UBOOT_OFF"
check_eq "0x${E_SRC_DTB:-0}"     "0x${L_DTB_OFF:-0}" "②c 桩 BOOT_SRC_DTB == LAYOUT_DTB_OFF"
check_eq "0x${E_DST_OPENSBI:-0}" "0x${L_OSB_DST:-0}" "②d 桩 BOOT_DST_OPENSBI == LAYOUT_OPENSBI_DST"
check_eq "0x${E_DST_UBOOT:-0}"   "0x${L_UB_DST:-0}"  "②e 桩 BOOT_DST_UBOOT == LAYOUT_UBOOT_DST"
check_eq "0x${E_DST_DTB:-0}"     "0x${L_DTB_DST:-0}" "②f 桩 BOOT_DST_DTB == LAYOUT_DTB_DST"
check_eq "0x${E_FLASH_BASE:-0}"  "0x1C000000"        "②g 桩 BOOT_FLASH_BASE == XIP 主窗口 0x1C000000"
check_eq "0x${E_XIP_SIZE:-0}"    "0x${L_XIP_SIZE:-0}" "②h 桩 BOOT_XIP_SIZE == LAYOUT_XIP_SIZE"
check_eq "0x${E_SEG_COUNT:-0}"   "0x3"               "②i 桩 BOOT_SEG_COUNT == 3"
check_eq "0x${E_NEXT_ENTRY:-0}"  "0x${L_OSB_DST:-0}" "②j 桩 BOOT_NEXT_ENTRY == OpenSBI 目的地址"
check_eq "0x${E_FDT_DST:-0}"     "0x${L_DTB_DST:-0}" "②k 桩 BOOT_FDT_DST == DTB 目的地址"

#==============================================================================
# 三、③ 段长 ↔ 真实 payload 大小；④ 布局合法性（独立重算，不复用打包脚本函数）
#==============================================================================
for triple in "OpenSBI:${OPEN_SBI_BIN}:${E_LEN_OPENSBI}:" "U-Boot:${UBOOT_BIN}:${E_LEN_UBOOT}:" \
              "DTB:${UBOOT_DTB}:${E_LEN_DTB}:"; do
    name="${triple%%:*}"; rest="${triple#*:}"
    path="${rest%%:*}";   want="${rest#*:}"; want="${want%%:*}"
    if [ ! -s "$path" ]; then
        fail "③${name} payload 缺失或为空：${path}（无法核对段长；先构建该 payload）"
        continue
    fi
    real="$(len_real "$path")"
    check_eq "0x${want:-0}" "$(printf '0x%X' "$real")" "③${name} 桩段长 == 真实大小补齐到 4（$(stat -c%s "$path") B → ${real} B）"
done

END_O=$(( 0x${L_OSB_OFF} + 0x${E_LEN_OPENSBI:-0} ))
END_U=$(( 0x${L_UB_OFF} + 0x${E_LEN_UBOOT:-0} ))
END_D=$(( 0x${L_DTB_OFF} + 0x${E_LEN_DTB:-0} ))
TOTAL="$END_D"
if (( 0x${L_OSB_OFF} % 4096 == 0 && 0x${L_UB_OFF} % 4096 == 0 && 0x${L_DTB_OFF} % 4096 == 0 )); then
    pass "④a 段偏移全部 4 KiB 对齐（0x${L_OSB_OFF} / 0x${L_UB_OFF} / 0x${L_DTB_OFF}）"
else
    fail "④a 段偏移未 4 KiB 对齐（0x${L_OSB_OFF} / 0x${L_UB_OFF} / 0x${L_DTB_OFF}）"
fi
if (( END_O <= 0x${L_UB_OFF} )); then
    pass "④b OpenSBI 段 [0x${L_OSB_OFF},0x$(printf '%X' "$END_O")) 不压 U-Boot 段 @0x${L_UB_OFF}（余量 $(( 0x${L_UB_OFF} - END_O )) B）"
else
    fail "④b OpenSBI 段 [0x${L_OSB_OFF},0x$(printf '%X' "$END_O")) 压到 U-Boot 段 @0x${L_UB_OFF}（OpenSBI 长大 ⇒ 上调 UBOOT/DTB 偏移，两处同步改）"
fi
if (( END_U <= 0x${L_DTB_OFF} )); then
    pass "④c U-Boot 段 [0x${L_UB_OFF},0x$(printf '%X' "$END_U")) 不压 DTB 段 @0x${L_DTB_OFF}（余量 $(( 0x${L_DTB_OFF} - END_U )) B）"
else
    fail "④c U-Boot 段 [0x${L_UB_OFF},0x$(printf '%X' "$END_U")) 压到 DTB 段 @0x${L_DTB_OFF}（U-Boot 长大 ⇒ 上调 DTB 偏移，两处同步改）"
fi
if (( TOTAL <= 0x${L_XIP_SIZE} && TOTAL <= 0x${L_FLASH_SIZE} )); then
    pass "④d 镜像总长 0x$(printf '%X' "$TOTAL") = ${TOTAL} B ≤ XIP 1 MiB 且 ≤ SPI 16 MiB（余量 $(( 0x${L_XIP_SIZE} - TOTAL )) B）"
else
    fail "④d 镜像总长 0x$(printf '%X' "$TOTAL") 越界（XIP 窗口 0x${L_XIP_SIZE}）"
fi
if (( (0x${E_LEN_OPENSBI:-0}) % 4 == 0 && (0x${E_LEN_UBOOT:-0}) % 4 == 0 && (0x${E_LEN_DTB:-0}) % 4 == 0 )); then
    pass "④e 三段段长均 4 字节对齐（整字 lw/sw 拷贝前提）"
else
    fail "④e 段长存在非 4 字节对齐项（整字拷贝会越界）"
fi

#==============================================================================
# 四、⑤ 已打包镜像分段切片 ⇄ 源 payload（端到端对账）
#==============================================================================
if [ -s "$IMG" ]; then
    for quad in "OpenSBI:${L_OSB_OFF}:0x${E_LEN_OPENSBI}:${OPEN_SBI_BIN}" \
                "U-Boot:${L_UB_OFF}:0x${E_LEN_UBOOT}:${UBOOT_BIN}" \
                "DTB:${L_DTB_OFF}:0x${E_LEN_DTB}:${UBOOT_DTB}"; do
        name="${quad%%:*}"; rest="${quad#*:}"
        off="${rest%%:*}";  rest="${rest#*:}"
        len="${rest%%:*}";  src="${rest#*:}"
        if [ ! -s "$src" ]; then fail "⑤${name} 源 payload 缺失：${src}"; continue; fi
        len_src="$(stat -c%s "$src")"
        if dd if="$IMG" bs=1 skip="$(( 0x${off} ))" count="$len_src" status=none 2>/dev/null | cmp -s - "$src"; then
            pass "⑤${name} 镜像切片 @0x$(printf '%X' "$(( 0x${off} ))") 与源 payload 逐字节相同（${len_src} B，段长 0x$(printf '%X' "$(( 0x${len} ))")）"
        else
            fail "⑤${name} 镜像切片 @0x$(printf '%X' "$(( 0x${off} ))") 与源 payload 不一致（跑 build_spi_image.sh 重打包）"
        fi
    done
else
    fail "⑤ 未找到 ${IMG}（先跑 sw/boot/build_spi_image.sh 产出镜像）"
fi

#==============================================================================
# 五、仿真构型汇编 + 字表生成（--update-sim-words 写盘；默认模式只做"未过期"核对）
#==============================================================================
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rv32-stub-layout.XXXXXX")"
cleanup() { rc=$?; [ "$rc" -eq 0 ] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

SIM_STUB_ELF="${TMP_DIR}/boot_stub_sim.elf"
SIM_STUB_BIN="${TMP_DIR}/boot_stub_sim.bin"
SIM_STUB_HEX="${TMP_DIR}/boot_stub_sim.hex"
SIM_SVH_NEW="${TMP_DIR}/boot_stub_words.svh"
PROBE_ELF="${TMP_DIR}/boot_stub_probe.elf"
PROBE_BIN="${TMP_DIR}/boot_stub_probe.bin"

say "== 汇编仿真构型桩（同一份 boot_stub.S，--defsym 覆盖三个段长：0x${SIM_LEN_OPENSBI#0x} / 0x${SIM_LEN_UBOOT#0x} / 0x${SIM_LEN_DTB#0x}）"
"$CC" -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles -ffreestanding \
      -Wa,--defsym,BOOT_LEN_OPENSBI="${SIM_LEN_OPENSBI}" \
      -Wa,--defsym,BOOT_LEN_UBOOT="${SIM_LEN_UBOOT}" \
      -Wa,--defsym,BOOT_LEN_DTB="${SIM_LEN_DTB}" \
      -Wl,-T,"$STUB_LDS" -Wl,-e,_stub_start -Wl,--build-id=none \
      -o "$SIM_STUB_ELF" "$STUB_SRC"
"$OBJCOPY" -O binary "$SIM_STUB_ELF" "$SIM_STUB_BIN"
"$OBJCOPY" -O verilog "$SIM_STUB_ELF" "$SIM_STUB_HEX"

say "== 汇编 TB 占位程序（sim/unit/prog/boot_stub_probe.S，链接 0x01000000）"
"$CC" -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles -ffreestanding \
      -Wl,-Ttext=0x01000000 -Wl,-e,_probe_start -Wl,--build-id=none \
      -o "$PROBE_ELF" "$PROBE_SRC"
"$OBJCOPY" -O binary "$PROBE_ELF" "$PROBE_BIN"

SIM_LEN_OPENSBI_DEC="$(( SIM_LEN_OPENSBI ))"; SIM_LEN_UBOOT_DEC="$(( SIM_LEN_UBOOT ))"; SIM_LEN_DTB_DEC="$(( SIM_LEN_DTB ))"
SIM_PROBE_BYTES="$(stat -c%s "$PROBE_BIN")"
if (( SIM_PROBE_BYTES > SIM_LEN_OPENSBI_DEC )); then
    fail "⑤' 占位程序 ${SIM_PROBE_BYTES} B 超过仿真 OpenSBI 段长 ${SIM_LEN_OPENSBI_DEC} B（--sim-lens 调大）"
fi

SIM_NM="$( { "$NM" -n "$SIM_STUB_ELF"; } 2>/dev/null || true )"
sim_sym() { printf '%s\n' "$SIM_NM" | awk -v s="$1" '$NF==s {print $1; exit}' ; }
PROBE_NM="$( { "$NM" -n "$PROBE_ELF"; } 2>/dev/null || true )"
probe_sym_val() { printf '%s\n' "$PROBE_NM" | awk -v s="$1" '$NF==s {print $1; exit}' ; }

python3 - "$SIM_STUB_BIN" "$PROBE_BIN" "$SIM_STUB_ELF" "$PROBE_ELF" "$SIM_SVH_NEW" \
         "$SIM_LEN_OPENSBI_DEC" "$SIM_LEN_UBOOT_DEC" "$SIM_LEN_DTB_DEC" <<'PY'
import subprocess, sys, io
stub_bin, probe_bin, stub_elf, probe_elf, out_svh, l_osb, l_ub, l_dtb = sys.argv[1:9]
NM = "/opt/riscv/bin/riscv32-unknown-linux-gnu-nm"

def syms(elf):
    out = subprocess.run([NM, "-n", elf], capture_output=True, text=True, check=True).stdout
    d = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3:
            d[p[2]] = p[0]
    return d

def words(path):
    b = open(path, "rb").read()
    assert len(b) % 4 == 0, "镜像不是 4 字节整数倍"
    return [int.from_bytes(b[i:i+4], "little") for i in range(0, len(b), 4)]

sw = words(stub_bin)
pw = words(probe_bin)
ss, ps = syms(stub_elf), syms(probe_elf)

def g(ss, name):
    if name not in ss:
        raise SystemExit("ERROR: 符号表缺 %s（无法生成字表）" % name)
    return int(ss[name], 16)

def hx(v):
    return "32'h%08X" % (v & 0xFFFFFFFF)

sum_stub = sum(sw) & 0xFFFFFFFF
sum_probe = sum(pw) & 0xFFFFFFFF

lines = []
A = lines.append
A("// ==== 自动生成（**不要手改**）================================================")
A("// 生成器 : sw/boot/check_stub_layout.sh --update-sim-words")
A("// 源     : sw/boot/boot_stub.S（同一份桩源码，段长用 --defsym 换成仿真小值）")
A("//          + sim/unit/prog/boot_stub_probe.S（TB 的迷你 OpenSBI 占位程序）")
A("// 布局常量取自**汇编后 ELF 的符号表**（nm）⇒ 桩源码一改、重跑生成器，")
A("// 本文件随之变化，tb_boot_stub 立刻跟着变（改错常量 ⇒ TB 必红）。")
A("//   · 桩镜像 %d 字（逐字和 0x%08X，首字 %s）" % (len(sw), sum_stub, hx(sw[0])))
A("//   · 占位程序 %d 字（逐字和 0x%08X）" % (len(pw), sum_probe))
A("// 期望用途：TB `include 本文件后调用 load_boot_stub_words() 填 Flash 模型，")
A("//          用 boot_sim_probe_word(i) 取占位程序字（同时作为 DDR 期望值）。")
A("//=============================================================================")
A("")
A("localparam integer BOOT_SIM_SEG_COUNT   = %d;"      % g(ss, "BOOT_SEG_COUNT"))
A("localparam [31:0]  BOOT_SIM_FLASH_BASE  = %s;"      % hx(g(ss, "BOOT_FLASH_BASE")))
A("localparam [31:0]  BOOT_SIM_XIP_SIZE    = %s;"      % hx(g(ss, "BOOT_XIP_SIZE")))
A("localparam integer BOOT_SIM_SRC_OPENSBI = %s;"      % hx(g(ss, "BOOT_SRC_OPENSBI")))
A("localparam integer BOOT_SIM_LEN_OPENSBI = %s;"      % hx(g(ss, "BOOT_LEN_OPENSBI")))
A("localparam [31:0]  BOOT_SIM_DST_OPENSBI = %s;"      % hx(g(ss, "BOOT_DST_OPENSBI")))
A("localparam integer BOOT_SIM_SRC_UBOOT   = %s;"      % hx(g(ss, "BOOT_SRC_UBOOT")))
A("localparam integer BOOT_SIM_LEN_UBOOT   = %s;"      % hx(g(ss, "BOOT_LEN_UBOOT")))
A("localparam [31:0]  BOOT_SIM_DST_UBOOT   = %s;"      % hx(g(ss, "BOOT_DST_UBOOT")))
A("localparam integer BOOT_SIM_SRC_DTB     = %s;"      % hx(g(ss, "BOOT_SRC_DTB")))
A("localparam integer BOOT_SIM_LEN_DTB     = %s;"      % hx(g(ss, "BOOT_LEN_DTB")))
A("localparam [31:0]  BOOT_SIM_DST_DTB     = %s;"      % hx(g(ss, "BOOT_DST_DTB")))
A("localparam [31:0]  BOOT_SIM_NEXT_ENTRY  = %s;"      % hx(g(ss, "BOOT_NEXT_ENTRY")))
A("localparam [31:0]  BOOT_SIM_FDT_DST     = %s;"      % hx(g(ss, "BOOT_FDT_DST")))
A("localparam integer BOOT_SIM_HARTID      = %d;"      % g(ss, "BOOT_HARTID"))
A("localparam integer BOOT_SIM_STUB_WORDS  = %d;"      % len(sw))
A("localparam [31:0]  BOOT_SIM_STUB_SUM    = %s;"      % hx(sum_stub))
A("localparam [31:0]  BOOT_SIM_STUB_W0     = %s;"      % hx(sw[0]))
A("localparam [31:0]  BOOT_SIM_STUB_WLAST  = %s;"      % hx(sw[-1]))
A("localparam integer BOOT_SIM_PROBE_WORDS = %d;"      % len(pw))
A("localparam [31:0]  BOOT_SIM_PROBE_SUM   = %s;"      % hx(sum_probe))
A("localparam [31:0]  BOOT_SIM_PROBE_MBOX  = %s;"      % hx(g(ps, "PROBE_MBOX")))
A("localparam [31:0]  BOOT_SIM_PROBE_MAGIC = %s;"      % hx(g(ps, "PROBE_MAGIC")))
A("localparam [31:0]  BOOT_SIM_PROBE_SIG   = %s;"      % hx(g(ps, "PROBE_SIG")))
A("")
A("// 把桩镜像逐字写进 TB 侧 Flash 模型（flash[] 必须在 `include 之前声明）")
A("task automatic load_boot_stub_words;")
A("    begin")
for i in range(0, len(sw), 4):
    chunk = sw[i:i+4]
    A("        " + " ".join("flash[%4d] = %s;" % (i + k, hx(w)) for k, w in enumerate(chunk)))
A("    end")
A("endtask")
A("")
A("// 占位程序第 i 个字（0 ≤ i < BOOT_SIM_PROBE_WORDS；越界返回 NOP）")
A("function [31:0] boot_sim_probe_word;")
A("    input integer i;")
A("    begin")
A("        case (i)")
for i, w in enumerate(pw):
    A("            %4d: boot_sim_probe_word = %s;" % (i, hx(w)))
A("            default: boot_sim_probe_word = 32'h0000_0013;")
A("        endcase")
A("    end")
A("endfunction")
A("")
open(out_svh, "w").write("\n".join(lines) + "\n")
print("生成 %s：桩 %d 字 / 占位程序 %d 字" % (out_svh, len(sw), len(pw)))
PY

if [ "$MODE" = "update" ]; then
    mkdir -p "$(dirname -- "$SIM_SVH")"
    cp -f "$SIM_STUB_HEX" "$SIM_HEX"
    cp -f "$SIM_SVH_NEW" "$SIM_SVH"
    say "== 已写入仿真字表："
    say "   ${SIM_HEX}  （桩镜像 objcopy -O verilog，$(stat -c%s "$SIM_STUB_HEX") B 文本）"
    say "   ${SIM_SVH}  （TB include 的字表，$(stat -c%s "$SIM_SVH") B）"
    say "   桩 md5 ${SIM_STUB_HEX} = $(md5sum "$SIM_HEX" | awk '{print $1}')"
    say "   svh md5 $(md5sum "$SIM_SVH" | awk '{print $1}')"
    rm -rf "$TMP_DIR"
    trap - EXIT
    say "STUB_LAYOUT: OK（已刷新仿真字表；接着跑 ./scripts/regress.sh 验证 tb_boot_stub）"
    exit 0
fi

# 默认模式：核对磁盘上的字表/hex 与"重新汇编生成"的结果一致（防过期/手改）
if [ ! -s "$SIM_SVH" ]; then
    fail "⑥ 仿真字表缺失：${SIM_SVH}（跑 sw/boot/check_stub_layout.sh --update-sim-words 生成）"
else
    if cmp -s "$SIM_SVH" "$SIM_SVH_NEW"; then
        pass "⑥a 仿真字表未过期（$(md5sum "$SIM_SVH" | awk '{print $1}')，与重新汇编结果逐字节一致）"
    else
        fail "⑥a 仿真字表已过期/被手改：${SIM_SVH}（跑 --update-sim-words 刷新；差异首行：$(diff "$SIM_SVH" "$SIM_SVH_NEW" | head -n 3 | tr '\n' ' '))"
    fi
    #   ★ hex 是**审计件**（`*.hex` 在 .gitignore 里，不入库；TB 用的是 .svh）：
    #     缺失 ⇒ 只提示（不阻断）；存在但与重算结果不一致 ⇒ 判红（真漂移）。
    if [ ! -e "$SIM_HEX" ]; then
        say "NOTE: ⑥b 桩仿真镜像 hex 未生成（${SIM_HEX}；\`*.hex\` 被 .gitignore 忽略）—— 需要时跑 --update-sim-words"
    elif cmp -s "$SIM_HEX" "$SIM_STUB_HEX"; then
        pass "⑥b 桩仿真镜像 hex 未过期（$(md5sum "$SIM_HEX" | awk '{print $1}')）"
    else
        fail "⑥b 桩仿真镜像 hex 已过期/被手改：${SIM_HEX}（跑 --update-sim-words 刷新）"
    fi
fi

say ""
say "------------------------------------------------------------------------"
say " 布局对账表（桩 .equ ⇄ 打包脚本 LAYOUT_* ⇄ 真实 payload ⇄ 已打包镜像）"
say "------------------------------------------------------------------------"
printf ' %-8s %-10s %-12s %-12s %-12s %s\n' "段" "Flash偏移" "段长(桩.equ)" "目的地址(桩)" "目的(脚本)" "payload 实际大小"
printf ' %-8s %-10s %-12s %-12s %-12s %s\n' "OPENSBI" "0x$(printf '%X' "$(( 0x${L_OSB_OFF} ))")" "0x${E_LEN_OPENSBI}" "0x${E_DST_OPENSBI}" "0x${L_OSB_DST}" "$(stat -c%s "$OPEN_SBI_BIN" 2>/dev/null || echo '<缺失>') B"
printf ' %-8s %-10s %-12s %-12s %-12s %s\n' "UBOOT"   "0x$(printf '%X' "$(( 0x${L_UB_OFF} ))")"  "0x${E_LEN_UBOOT}"   "0x${E_DST_UBOOT}"   "0x${L_UB_DST}"   "$(stat -c%s "$UBOOT_BIN" 2>/dev/null || echo '<缺失>') B"
printf ' %-8s %-10s %-12s %-12s %-12s %s\n' "DTB"     "0x$(printf '%X' "$(( 0x${L_DTB_OFF} ))")" "0x${E_LEN_DTB}"     "0x${E_DST_DTB}"     "0x${L_DTB_DST}"  "$(stat -c%s "$UBOOT_DTB" 2>/dev/null || echo '<缺失>') B"
say "------------------------------------------------------------------------"
say " 镜像：${IMG}（$(stat -c%s "$IMG" 2>/dev/null || echo 0) B，md5 $(md5sum "$IMG" 2>/dev/null | awk '{print $1}')）"
say " 仿真构型段长（--sim-lens 生效值）：OpenSBI 0x$(printf '%X' "$SIM_LEN_OPENSBI_DEC") / U-Boot 0x$(printf '%X' "$SIM_LEN_UBOOT_DEC") / DTB 0x$(printf '%X' "$SIM_LEN_DTB_DEC")；占位程序 ${SIM_PROBE_BYTES} B"
say "------------------------------------------------------------------------"

if [ "$FAILED" -eq 0 ]; then
    rm -rf "$TMP_DIR"; trap - EXIT
    say "STUB_LAYOUT: OK"
    exit 0
fi
say "STUB_LAYOUT: FAILED（见上；诊断临时目录保留：${TMP_DIR}）"
exit 1
