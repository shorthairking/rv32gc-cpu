#!/usr/bin/env bash
#==============================================================================
# sw/m5_board/tb/ctrl/build_ctrl.sh —— 控制实验程序的构建（自包含；仅写 tb/ 内）
#==============================================================================
# 产物（sw/m5_board/tb/ctrl/out/）：
#   ct_selftest.hex     控制实验 A：测试台自检（应使 TB 判 PASS）
#   ct_m5_scaled.S/.hex 控制实验 B：m5_board.S 的缩放副本（4 个计数常量缩放）
# 口径与 sw/m5_board/build.sh 一致：riscv32-unknown-linux-gnu-gcc、-march=rv32im、
#   -mabi=ilp32、-mno-relax、-nostdlib、-Wl,-Ttext=0x1C000000、objcopy → 4B/行 hex。
# 纪律：不改动 sw/m5_board/m5_board.S、build.sh、rtl/**、sim/**；仅读它们。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
OUT="${SCRIPT_DIR}/out"
mkdir -p "${OUT}"

PREFIX="${TOOLCHAIN_PREFIX:-/opt/riscv/bin/riscv32-unknown-linux-gnu-}"
CC="${PREFIX}gcc"
OBJCOPY="${PREFIX}objcopy"
OBJDUMP="${PREFIX}objdump"

[ -x "${CC}" ] || { printf 'ERROR: 找不到工具链 %s\n' "${CC}" >&2; exit 2; }

CFLAGS=( -march=rv32im -mabi=ilp32 -mno-relax -mcmodel=medlow
         -nostdlib -nostartfiles -ffreestanding -fno-builtin -fno-pic -fno-pie
         -Os -Wall )
LDFLAGS=( -nostdlib -nostartfiles -static -mno-relax
          -Wl,-Ttext=0x1C000000 -Wl,-e,_start -Wl,--build-id=none
          -Wl,--no-warn-rwx-segments )

# 控制实验 B 的源码由 make_scaled.py 机械生成（含命中次数断言）
python3 "${SCRIPT_DIR}/make_scaled.py" || exit 1

rc=0
for name in ct_selftest ct_m5_scaled ct_delay_probe; do
    case "${name}" in
        ct_selftest)   src="${SCRIPT_DIR}/${name}.S" ;;       # 手写
        ct_m5_scaled)  src="${OUT}/${name}.S" ;;              # make_scaled.py 生成
        ct_delay_probe) src="${SCRIPT_DIR}/${name}.S" ;;      # 手写
    esac
    elf="${OUT}/${name}.elf"
    bin="${OUT}/${name}.bin"
    hex="${OUT}/${name}.hex"
    [ -f "${src}" ] || { printf 'FAIL: 缺 %s\n' "${src}" >&2; rc=1; continue; }
    if ! "${CC}" "${CFLAGS[@]}" "${LDFLAGS[@]}" -o "${elf}" "${src}" 2>&1; then
        printf 'FAIL: %s 编译失败\n' "${name}" >&2; rc=1; continue
    fi
    "${OBJDUMP}" -d -M no-aliases,numeric "${elf}" > "${OUT}/${name}.dis"
    "${OBJCOPY}" -O binary "${elf}" "${bin}"
    python3 - "${bin}" "${hex}" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
if len(data) % 4:
    data += b'\x00' * (4 - len(data) % 4)
with open(sys.argv[2], 'w') as f:
    for i in range(0, len(data), 4):
        f.write('%08x\n' % int.from_bytes(data[i:i+4], 'little'))
PY
    printf 'OK  : %-14s elf=%s hex=%s words=%d\n' "${name}" "${elf}" "${hex}" \
           "$(wc -l < "${hex}")"
done
exit "${rc}"
