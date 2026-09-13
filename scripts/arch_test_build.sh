#!/usr/bin/env bash
#=============================================================================
# arch_test_build.sh —— 用 riscv-arch-test(ACT4) 的测试源构建"自校验 ELF"
#
# 参考签名由 **Spike** 生成（真实参考模型，不是占位值）：
#   phase 1: gcc -DSIGNATURE           -> <name>.sig.elf
#            spike --test-signature=…  -> <name>.sig   （参考签名）
#   phase 2: gcc -DRVTEST_SELFCHECK -DSIGNATURE_FILE="<name>.sig.results"
#            -> <name>.elf            （把参考签名编译进镜像，运行时自比对）
#
# 用法:
#   scripts/arch_test_build.sh <test.S 相对/绝对路径> [outdir] [march] [mabi]
# 例:
#   scripts/arch_test_build.sh riscv-arch-test/tests/rv32i/I/I-add-00.S
#   scripts/arch_test_build.sh riscv-arch-test/tests/rv32i/Zca/c.add-00.S "" rv32imac_zicsr_zifencei ilp32
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "$ROOT/.." && pwd)"
AT_SRC="${AT_SRC:-$WS_ROOT/riscv-arch-test}"
CFG="$ROOT/sim/arch_test/config"
SPIKE="${SPIKE:-$ROOT/tools/spike-install/bin/spike}"
CC="${CC:-riscv32-unknown-linux-gnu-gcc}"

TEST_SRC="$1"
OUT="${2:-$ROOT/sim/arch_test/out}"
# ---------------------------------------------------------------------------
# ISA 串合成：DUT 支持的"基座"扩展 ∪ 用例头部声明的扩展
# ---------------------------------------------------------------------------
# ACT4 每个生成用例都在 START_TEST_CONFIG 头里声明自己需要的 ISA 串，例如：
#   I/Zicsr/Zifencei → rv32i_zicsr_zifencei        （注意：**不含** zicntr）
#   Zicbom           → rv32i_zicbom_zicsr_zifencei
#   Zalrsc           → rv32i_zicsr_zifencei_zalrsc
# 若直接拿头部串去汇编，Zicsr 组会因 `csrrs instret`（属于 Zicntr）被判非法、
# Zicntr 相关 CSR 也取不到 → 参考签名与 DUT 不一致而整组失败（实测 4/6 FAIL）。
# 因此这里做**并集**：基座（DUT 实际实现）rv32imac + zicsr + zifencei + zicntr
# ∪ 头部声明中出现的其它扩展（zicbom/zihintpause/zalrsc/zaamo/...）。
BASE_EXT="imac_zicsr_zifencei_zicntr"
HEADER_MARCH="$(sed -n '/START_TEST_CONFIG/,/END_TEST_CONFIG/p' "$TEST_SRC" \
                | sed -n 's/^[[:space:]]*#[[:space:]]*MARCH:[[:space:]]*\([A-Za-z0-9_.]*\).*/\1/p' \
                | head -1)"
# 从头部串里抽出 rv32 之后的扩展名（去掉 rv32i/rv32im 之类的基础部分）
HEADER_EXT=""
if [ -n "$HEADER_MARCH" ]; then
  HEADER_EXT="$(printf '%s' "$HEADER_MARCH" | sed 's/^rv32[eim]*//')"
fi
# 扩展名规范化 + 去重（含别名归一），避免出现 `_c_..._zca` 这类重复与非法组合：
#   · `c` → `zca`（GCC 不允许 c 与 zca 同时出现，也不允许重复）
#   · `m`/`a` 隐含在基座 rv32imac 里，不再单列；`i`/`e`/`g` 等基础字母同理
#   · `zmmul` 已被 rv32im（M）覆盖
# 实现：用 python3 做集合运算（bash 字符串处理在这里容易出错，且本脚本已有 python 依赖）
MERGED_EXT="$(python3 - "$BASE_EXT" "$HEADER_EXT" <<'PYEOF'
import sys
base = sys.argv[1] if len(sys.argv) > 1 else ""
hdr  = sys.argv[2] if len(sys.argv) > 2 else ""

ALIAS = {"c": "zca", "m": "m", "a": "a", "f": "f", "d": "d",
         "zmmul": "zmmul", "zaamo": "zaamo", "zalrsc": "zalrsc"}
DROP = {"i", "e", "g", "m", "a", "c", "zmmul"}   # 基础字母/别名：由基座承担或不单列

def toks(s):
    s = s.strip().lstrip("_")
    return [t for t in s.split("_") if t]

ordered = []
seen = set()
for t in toks(base):
    t = ALIAS.get(t, t)
    if t in DROP or t in seen:
        continue
    seen.add(t); ordered.append(t)
for t in toks(hdr):
    t = ALIAS.get(t, t)
    if t in DROP or t in seen:
        continue
    seen.add(t); ordered.append(t)
print("_".join(ordered))
PYEOF
)"
if [ -n "${3:-}" ]; then
  MARCH="$3"
elif [ -n "${MARCH:-}" ]; then
  MARCH="$MARCH"
else
  MARCH="rv32${MERGED_EXT}"
fi
MABI="${4:-ilp32}"
NAME="$(basename "$TEST_SRC" .S)"
echo "[build] $NAME: MARCH=$MARCH (头部=${HEADER_MARCH:-无})"

mkdir -p "$OUT"

if [ ! -x "$SPIKE" ]; then
  echo "ERROR: 未找到 Spike（$SPIKE）。请先编译：见 docs/kb/06-toolchain-build.md §3.1" >&2
  exit 1
fi

# Spike 的 --isa= 只接受它认识的扩展名；这里只剥离"Spike 不认识/由基 ISA 隐含"的：
#   _zmmul / _zca / _zcd / _zcf  —— Spike 不认识（C 已覆盖 Zca/Zcd/Zcf）
# **保留** _zicsr / _zifencei / _zicntr —— 它们决定参考模型是否实现 CSR/指令栅栏/计数器：
#   * 剥掉 _zicntr  → Spike 把 `csrrs instret` 当非法指令 → Zicsr 组误判失败
#   * 剥掉 _zifencei → Spike 把 `fence.i` 当非法指令 → Zifencei 组陷阱计数不符而失败
SPIKE_ISA="$(echo "$MARCH" | sed -e 's/_zmmul//' -e 's/_zca//' -e 's/_zcd//' -e 's/_zcf//')"
ISA_STR="rv32${SPIKE_ISA#rv32}"

COMMON=(-Wl,--no-warn-rwx-segments
        -I"$CFG" -I"$AT_SRC/tests/env" -T"$CFG/link.ld"
        -O0 -g -mcmodel=medany -nostdlib -nostartfiles
        -march="$MARCH" -mabi="$MABI"
        -DTEST_FLEN=32 "-DTEST_FILE=\"$NAME.S\"")

echo "[1/2] 构建签名 ELF: $NAME.sig.elf  (march=$MARCH)"
"$CC" "${COMMON[@]}" -DSIGNATURE \
      -DSAIL_CLINT_BASE_ADDRESS=0x02000000 \
      -DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0x0c000000 \
      -o "$OUT/$NAME.sig.elf" "$TEST_SRC"

echo "[2/2] Spike 生成参考签名 -> $NAME.sig，再构建自校验 ELF: $NAME.elf"
timeout 300 "$SPIKE" --isa="$ISA_STR" "+signature=$OUT/$NAME.sig" \
         "+signature-granularity=4" "$OUT/$NAME.sig.elf" \
         > "$OUT/$NAME.spike.log" 2>&1 || true

if [ ! -s "$OUT/$NAME.sig" ]; then
  echo "ERROR: Spike 未生成签名文件（$OUT/$NAME.sig）。日志尾部：" >&2
  tail -20 "$OUT/$NAME.spike.log" >&2
  exit 1
fi

# ACT4 期望的 .results 文件：与框架 framework/src/act/sig_modify.py 完全一致的格式
#   - 每行加 ".word 0x" 前缀（XLEN=32）
#   - 最后一行前插入 sig_end_canary 标签
#   - 命中 canary 常量的行后插入 final_sig_offset / final_trap_sig_offset / trap_sigptr 标签
python3 - "$OUT/$NAME.sig" "$OUT/$NAME.results" <<'PY'
import sys, pathlib
sig_file, result_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
xlen = 32
datatype = ".word" if xlen == 32 else ".quad"
trap_canary           = "d3a91f6c"          if xlen == 32 else "d3a91f6c8b47e25d"
final_sig_canary      = "4b8e2d17"          if xlen == 32 else "4b8e2d17a6c0f953"
final_trap_canary     = "7a110ff5"          if xlen == 32 else "7a110ff5c0def00d"
lines = [l.strip() for l in sig_file.read_text().splitlines() if l.strip()]
with result_file.open("w") as f:
    for i, line in enumerate(lines):
        if i == len(lines) - 1:
            f.write("sig_end_canary:\n")
        f.write(f"{datatype} 0x{line}\n")
        if final_sig_canary in line:
            f.write("final_sig_offset:\n")
        if final_trap_canary in line:
            f.write("final_trap_sig_offset:\n")
        if trap_canary in line:
            f.write("trap_sigptr:\n")
PY

"$CC" "${COMMON[@]}" -DRVTEST_SELFCHECK -DSIGNATURE_FILE="\"$OUT/$NAME.results\"" -DXLEN=32 \
      -o "$OUT/$NAME.elf" "$TEST_SRC"

echo "OK: $OUT/$NAME.elf"
