#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_data_bus_irq.sh —— 数据总线 IRQ/PLIC 包入口（fail-closed）
#==============================================================================
# 归属 : 2B 数据总线（真实外部 IRQ 取消普通 head cached load；真实 PLIC claim/complete）
# 用法 : bash sim/functional/test_data_bus_irq.sh                # 默认：三模式全跑
#        bash sim/functional/test_data_bus_irq.sh --self-test     # 判据+合法负控灵敏度
#        DUT_ROOT=<含 rtl/ 的冻结源根> bash ...                   # 显式指定被测源
#
# 固定三 case（三模式都必须真跑；未触发/缺 mode 一律失败，不是 PASS）:
#   IRQ_LOAD  (mode=1, checks=18)：普通 head cached load A 的真实 AXI AR 后，外部
#                        intrpt[1] 拉高，A 的 R 首 beat 延迟 100 拍 ⇒ A 未 done 时取
#                        IRQ、mepc=A、cause=0x8000000B；claim/complete 各 1、in-service
#                        恰一次；A 的 8 个迟 R 由 L1D fill(owner=DFIL) 消费、A 无 load
#                        写回；B（不同 PA/known）与 claim 各拿自己的数据。
#   IRQ_ONLY  (mode=2, checks=13)：纯 IRQ 无 load 控制（wait_loop 提交后拉 pin）。
#   IRQ_REUSE (mode=3, checks=19)：同 IRQ_LOAD，且 B 实际复用 A 的 LQ tag 仍拿 B known。
#
# 入口契约（由 data_bus 默认包持有者 2b93 挂接；本文件不自己进 manifest/Top 域）:
#   data_bus 包必须调用 `bash sim/functional/test_data_bus_irq.sh` 且要求其输出中
#   **恰好一行** `FUNCTIONAL_DATA_BUS_IRQ: PASS`；本包内部三 mode 均为 mandatory。
#
# 冻结纪律（P1 退修后）:
#   · **执行前**先绑定：env 原件 + 实际入口原件 + 全部 actual RTL(.v/.vh) + 新 TB +
#     局部 mem model + 3 程序 = 一张按序完整清单；逐项 sha256(原 rc)/行数/精确路径；
#     `sha256sum` 的 rc 必须为 0，块必须"总行数=期望、每行 64hex+精确路径、无重复/漏项/
#     尾垃圾"。这份 **source identity** 在任何 copy/source/compile 之前取得。
#   · 随即 copy 到一次快照后对同一相对清单再取 **snapshot identity**，逐项 hash 与
#     source identity **精确相等**；快照文件 chmod 444。env/入口也 copy 进快照并同一
#     freeze；随后 **source 冻结副本**（不是 live env），source 前后再取 hash 相等。
#   · 实际编译/执行只用快照副本（cd 快照 root、相对 -I/相对文件）。跑完再取 source 与
#     snapshot 两侧身份，必须分别与执行前相等（源未被动、快照未变）。
#   · 工具 rc 原样捕获：gcc/objcopy/python3/nm 各自 rc 紧跟捕获；hex 逐行校验；
#     nm 先落文件查 rc，再要求唯一 32-bit hex 符号（不接受 `| awk` 丢 rc）。
#
# 判定（全部满足才打印 FUNCTIONAL 锚点；否则 exit 1 且不打印）:
#   · DUT_ROOT: 默认本仓库根；默认根 rtl 脏且未显式允许 ⇒ 拒绝运行（不冒全阶段）。
#   · 每 mode rc=0、非空日志、唯一 TB 模式锚点、`DATA_BUS_IRQ_CASE ... checks=<固定>`
#     恰一次、零 FAIL/DEFECT/XZ/UNKNOWN；三 case 各恰一次；最后唯一整行
#     `FUNCTIONAL_DATA_BUS_IRQ: PASS`。
#   · TB `chk` 为 4 态（cond !== 1'b1）：X/Z 一律 FAIL，不被 !cond 跳过。
# 产物 : 只写 build/functional 下的 $RV32_FUNCTIONAL_PKG_OUT_DIR 或 data-bus-irq 的
#        mktemp run 目录（不删除历史；不写产品 RTL/TB/脚本）。
#==============================================================================
set -u

MODE="spec"
if [ "$#" -gt 1 ]; then printf 'FUNCTIONAL_DATA_BUS_IRQ: FAIL reason=unknown_arg\n'; exit 1; fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test|--negative) MODE="self-test" ;;
        *) printf 'FUNCTIONAL_DATA_BUS_IRQ: FAIL reason=unknown_arg arg=%s\n' "$1"; exit 1 ;;
    esac
fi

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_BUS_IRQ: FAIL reason=self_dir_unresolved\n'; exit 1; }
SELF_PATH="$SELF_DIR/$(basename -- "$SELF_PATH")"
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_BUS_IRQ: FAIL reason=repo_root_unresolved\n'; exit 1; }
ENV_SH="$REPO_ROOT/scripts/env.sh"
TB_REL="sim/functional/tb_data_bus_irq.sv"
MODEL_REL="sim/functional/data_bus_irq_mem_model.sv"
PROG_REL="sim/functional/prog"
ANCHOR='FUNCTIONAL_DATA_BUS_IRQ: PASS'
NEG_ANCHOR='FUNCTIONAL_DATA_BUS_IRQ_NEGATIVE: PASS'
NEG_FAIL='FUNCTIONAL_DATA_BUS_IRQ_NEGATIVE'
PYTHON_BIN="${PYTHON_BIN:-python3}"
REAL_SHA_BIN="$(command -v sha256sum || true)"

RUN_DIR=""; RUN_LOG=""
emit_fail() {
    if [ "$MODE" = "self-test" ]; then
        printf '%s: FAIL reason=%s run_dir=%s\n' "$NEG_FAIL" "$1" "${RUN_DIR:-<none>}"
    else
        printf 'FUNCTIONAL_DATA_BUS_IRQ: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

#------------------------------------------------------------------------------
# 0. 产物根（父 PKGOUT 优先；canonical + mktemp）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail auth_root
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/data-bus-irq}"
is_auth() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail out_root
is_auth "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM"
mkdir -p -- "$ROOT_NORM" || emit_fail out_root_mkdir
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail out_root_recheck
is_auth "$ROOT_NORM" || emit_fail out_root_escape
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail mktemp
RUN_LOG="$RUN_DIR/test_data_bus_irq.log"
printf 'DATA_BUS_IRQ_RUN_DIR=%s\n' "$RUN_DIR"
: > "$RUN_LOG" || emit_fail run_log

# 预检（不 source live env；只用 PATH 的 coreutils）
for t in timeout sha256sum mktemp readlink python3; do
    command -v "$t" >/dev/null 2>&1 || emit_fail "tool_missing=$t"
done
[ -n "$REAL_SHA_BIN" ] || emit_fail "tool_missing=sha256sum"

#------------------------------------------------------------------------------
# 1. DUT_ROOT（默认本仓库；脏树门控；不使用 ignored abc 目录作默认 fallback）
#------------------------------------------------------------------------------
DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found"
[ -d "$DUT_ROOT/rtl" ] || emit_fail "dut_root_missing_rtl root=$DUT_ROOT"
DIRTY_N=0
if [ "$DUT_ROOT" = "$REPO_ROOT" ]; then
    if git -C "$DUT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        DIRTY_N="$(git -C "$DUT_ROOT" status --porcelain -- rtl | wc -l | tr -d ' ')"
    fi
    if [ "$DIRTY_N" != "0" ] && [ "${RV32_DATA_BUS_IRQ_ALLOW_DIRTY:-0}" != "1" ]; then
        emit_fail "source_dirty_default_root dirty_rtl=$DIRTY_N（产品写者未冻；显式 DUT_ROOT=<冻结快照> 或 RV32_DATA_BUS_IRQ_ALLOW_DIRTY=1）"
    fi
fi
{
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "MODE            = $MODE"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "SELF_PATH       = $SELF_PATH"
    echo "DUT_ROOT        = $DUT_ROOT"
    echo "DIRTY_RTL       = $DIRTY_N"
    echo "RUN_DIR         = $RUN_DIR"
    if git -C "$DUT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$DUT_ROOT" rev-parse HEAD)"
        echo "GIT_STATUS_SHA  = $(git -C "$DUT_ROOT" status --porcelain | sha256sum | awk '{print $1}')"
        echo "GIT_STATUS_N    = $(git -C "$DUT_ROOT" status --porcelain | wc -l)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
} >> "$RUN_LOG"

#==============================================================================
# 2. 严格 hash helper（rc 原样传播；块内容/行数/路径逐项校验）
#==============================================================================
HASH_RAW=""; HASH_RC=0; HASH_SEQ=0; VAL_ERR=""; NM_ERR=""; NM_SYM=""; HEX_ERR=""
is_hex64() { case "$1" in *[!0-9a-f]*|"") return 1 ;; esac; [ "${#1}" -eq 64 ]; }
hash_files() {   # $@ = exact file list ; ⇒ HASH_RAW（原始 stdout 落盘）/HASH_RC
    #   严格计数必须基于**原始 stdout**：不能对 $(...) 已剥尾的字符串计数（会吞额外空尾行）
    HASH_SEQ=$((HASH_SEQ + 1))
    mkdir -p -- "$RUN_DIR/hashraw" || return 1
    HASH_RAW="$RUN_DIR/hashraw/raw_$(printf '%04d' "$HASH_SEQ").txt"
    sha256sum -- "$@" > "$HASH_RAW" 2>>"$RUN_LOG"
    HASH_RC=$?
    return "$HASH_RC"
}
declare -a EXPECT_PATHS=()
validate_block() {   # $1=raw FILE $2=rc $3=tag ; expected = EXPECT_PATHS
    #   必须校验**原始 stdout 文件**：额外空尾行要计入行数并被拒
    local raw="$1" rc="$2" tag="$3" line h p i n dup
    VAL_ERR=""
    if [ "$rc" -ne 0 ]; then VAL_ERR="${tag}_rc=$rc"; return 1; fi
    if [ ! -f "$raw" ] || [ ! -s "$raw" ]; then VAL_ERR="${tag}_empty"; return 1; fi
    # Validate raw bytes before Bash/mapfile can normalize or discard anything.
    python3 - "$raw" "${#EXPECT_PATHS[@]}" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
want = int(sys.argv[2])
if (not b.endswith(b'\n') or b.count(b'\n') != want or b'\0' in b
        or b'\r' in b or any(c < 0x20 for c in b if c != 0x0a)):
    raise SystemExit(1)
PY
    local raw_rc=$?
    if [ "$raw_rc" -ne 0 ]; then VAL_ERR="${tag}_raw_bytes"; return 1; fi
    local -a L=()
    mapfile -t L < "$raw"
    n="${#L[@]}"
    if [ "$n" -ne "${#EXPECT_PATHS[@]}" ]; then
        VAL_ERR="${tag}_lines=$n expect=${#EXPECT_PATHS[@]}"; return 1
    fi
    dup="$(printf '%s\n' "${EXPECT_PATHS[@]}" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
    if [ "$dup" != "0" ]; then VAL_ERR="${tag}_expect_dup=$dup"; return 1; fi
    for ((i = 0; i < n; i++)); do
        line="${L[$i]}"
        if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ (.*)$ ]]; then
            VAL_ERR="${tag}_bad_line=$((i + 1))"; return 1
        fi
        h="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
        is_hex64 "$h" || { VAL_ERR="${tag}_bad_hex=$((i + 1))"; return 1; }
        if [ "$p" != "${EXPECT_PATHS[$i]}" ]; then
            VAL_ERR="${tag}_path=$((i + 1))"; return 1
        fi
    done
    return 0
}
block_hashes_file() { awk '{print $1}' "$1"; }
validate_hex_file() {   # @80000000 + 纯 8hex 行；非空、无尾垃圾
    local f="$1" line i n
    [ -s "$f" ] || { HEX_ERR="empty"; return 1; }
    local -a L=()
    mapfile -t L < "$f"
    n="${#L[@]}"
    [ "$n" -ge 2 ] || { HEX_ERR="lines=$n"; return 1; }
    [ "${L[0]}" = "@80000000" ] || { HEX_ERR="base=${L[0]}"; return 1; }
    for ((i = 1; i < n; i++)); do
        line="${L[$i]}"
        [[ "$line" =~ ^[0-9a-f]{8}$ ]] || { HEX_ERR="bad_word=$((i + 1))"; return 1; }
    done
    return 0
}
hex_convert() {   # $1=python $2=bin $3=base $4=out
    local py="$1" bin="$2" base="$3" out="$4" rc
    "$py" - "$bin" "$base" "$out" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
assert len(data) % 4 == 0 and len(data) > 0
with open(sys.argv[3], 'w') as f:
    f.write('@%08x\n' % int(sys.argv[2], 0))
    for w in struct.unpack('<%dI' % (len(data)//4), data):
        f.write('%08x\n' % w)
PY
    rc=$?
    if [ "$rc" -ne 0 ]; then HEX_ERR="python_rc=$rc"; return 1; fi
    if ! validate_hex_file "$out"; then return 1; fi
    return 0
}
nm_symbol() {   # $1=nm_cmd $2=elf $3=sym ; ⇒ NM_SYM
    local nm="$1" elf="$2" sym="$3" out rc n
    NM_ERR=""; NM_SYM=""
    out="$RUN_DIR/nm_$(basename -- "$elf").txt"
    "$nm" "$elf" > "$out" 2>>"$RUN_LOG"
    rc=$?
    if [ "$rc" -ne 0 ]; then NM_ERR="nm_rc=$rc"; return 1; fi
    [ -s "$out" ] || { NM_ERR="nm_empty"; return 1; }
    local -a L=()
    mapfile -t L < <(awk -v s="$sym" '$3==s {print $1}' "$out")
    n="${#L[@]}"
    if [ "$n" -ne 1 ]; then NM_ERR="sym_count_$sym=$n"; return 1; fi
    NM_SYM="${L[0]}"
    if [[ ! "$NM_SYM" =~ ^[0-9a-f]{8}$ ]]; then NM_ERR="sym_not_32bit=$NM_SYM"; return 1; fi
    return 0
}

#==============================================================================
# 3. 冻结（source identity 先于任何 copy；env/入口同 freeze；编译/执行只用副本）
#==============================================================================
SNAP="$RUN_DIR/src"
mkdir -p -- "$SNAP" || emit_fail snap_mkdir
declare -a RTL_SRC=() RTL_REL=() RTL_SNAP=()
mapfile -t RTL_SRC < <(find "$DUT_ROOT/rtl" -type f \( -name '*.v' -o -name '*.vh' \) | LC_ALL=C sort)
[ "${#RTL_SRC[@]}" -gt 0 ] || emit_fail "rtl_closure_empty root=$DUT_ROOT"
for f in "${RTL_SRC[@]}"; do
    rel="${f#"$DUT_ROOT"/}"
    RTL_REL+=( "$rel" ); RTL_SNAP+=( "$SNAP/$rel" )
done
AUX_SRC=( "$SELF_DIR/$(basename -- "$TB_REL")" "$SELF_DIR/$(basename -- "$MODEL_REL")"
          "$SELF_DIR/prog/data_bus_irq_load.S" "$SELF_DIR/prog/data_bus_irq_reuse.S"
          "$SELF_DIR/prog/data_bus_irq_only.S" "$ENV_SH" "$SELF_PATH" )
AUX_SNAP=( "$SNAP/$TB_REL" "$SNAP/$MODEL_REL"
           "$SNAP/$PROG_REL/data_bus_irq_load.S" "$SNAP/$PROG_REL/data_bus_irq_reuse.S"
           "$SNAP/$PROG_REL/data_bus_irq_only.S" "$SNAP/meta/scripts/env.sh"
           "$SNAP/meta/sim/functional/test_data_bus_irq.sh" )
for f in "${AUX_SRC[@]}"; do [ -f "$f" ] || emit_fail "aux_missing $f"; [ -s "$f" ] || emit_fail "aux_empty $f"; done
SRC_ALL=( "${RTL_SRC[@]}" "${AUX_SRC[@]}" )
SNAP_ALL=( "${RTL_SNAP[@]}" "${AUX_SNAP[@]}" )
for f in "${RTL_SRC[@]}"; do [ -s "$f" ] || emit_fail "rtl_empty $f"; done

# 3a. source identity：copy/source/compile 之前
EXPECT_PATHS=( "${SRC_ALL[@]}" )
hash_files "${SRC_ALL[@]}"; SRC_RC=$HASH_RC; SRC_RAW="$HASH_RAW"
[ "$SRC_RC" -eq 0 ] || emit_fail "source_sha_rc=$SRC_RC"
validate_block "$SRC_RAW" "$SRC_RC" "source_identity" || emit_fail "source_identity: $VAL_ERR"
mapfile -t SRC_H < <(block_hashes_file "$SRC_RAW")
{
    echo "-- source identity BEFORE copy/source/compile (n=${#SRC_ALL[@]}; RTL=${#RTL_SRC[@]} aux=${#AUX_SRC[@]}) --"
    cat -- "$SRC_RAW"
} >> "$RUN_LOG"

# 3b. copy 到快照（RTL 相对结构 + aux 映射），chmod 444
for i in "${!RTL_REL[@]}"; do
    mkdir -p -- "$SNAP/$(dirname -- "${RTL_REL[$i]}")" || emit_fail "snap_mkdir rel=${RTL_REL[$i]}"
    cp -p -- "${RTL_SRC[$i]}" "${RTL_SNAP[$i]}" || emit_fail "snap_copy rel=${RTL_REL[$i]}"
    chmod 444 -- "${RTL_SNAP[$i]}" || emit_fail "snap_chmod rel=${RTL_REL[$i]}"
done
for i in "${!AUX_SRC[@]}"; do
    mkdir -p -- "$(dirname -- "${AUX_SNAP[$i]}")" || emit_fail "snap_mkdir aux=$i"
    cp -p -- "${AUX_SRC[$i]}" "${AUX_SNAP[$i]}" || emit_fail "snap_copy aux=$i"
    chmod 444 -- "${AUX_SNAP[$i]}" || emit_fail "snap_chmod aux=$i"
done

# 3c. snapshot identity：逐项 hash 与 source identity 精确相等
EXPECT_PATHS=( "${SNAP_ALL[@]}" )
hash_files "${SNAP_ALL[@]}"; SNAP_RC=$HASH_RC; SNAP_RAW="$HASH_RAW"
[ "$SNAP_RC" -eq 0 ] || emit_fail "snap_sha_rc=$SNAP_RC"
validate_block "$SNAP_RAW" "$SNAP_RC" "snapshot_identity" || emit_fail "snapshot_identity: $VAL_ERR"
mapfile -t SNAP_H < <(block_hashes_file "$SNAP_RAW")
for i in "${!SRC_H[@]}"; do
    [ "${SRC_H[$i]}" = "${SNAP_H[$i]}" ] || emit_fail "copy_mismatch idx=$i src=${SRC_H[$i]} snap=${SNAP_H[$i]}"
done
{
    echo "-- snapshot identity AFTER copy (must equal source identity) --"
    cat -- "$SNAP_RAW"
    echo "-- aux freeze map (source -> snapshot; env/entry included) --"
    for i in "${!AUX_SRC[@]}"; do
        echo "AUX_MAP ${AUX_SRC[$i]} -> ${AUX_SNAP[$i]}"
    done
} >> "$RUN_LOG"

# 3d. env：source 冻结副本；source 前后 hash 不变
ENV_FROZEN="$SNAP/meta/scripts/env.sh"
EXPECT_PATHS=( "$ENV_SH" ); hash_files "$ENV_SH"; ENV_RC_H=$HASH_RC; ENV_RAW="$HASH_RAW"
[ "$ENV_RC_H" -eq 0 ] || emit_fail "env_sha_rc=$ENV_RC_H"
validate_block "$ENV_RAW" "$ENV_RC_H" "env_live" || emit_fail "env_live: $VAL_ERR"
ENV_H="$(block_hashes_file "$ENV_RAW")"
EXPECT_PATHS=( "$ENV_FROZEN" ); hash_files "$ENV_FROZEN"; EF_RC=$HASH_RC; EF_RAW="$HASH_RAW"
[ "$EF_RC" -eq 0 ] || emit_fail "env_frozen_sha_rc=$EF_RC"
validate_block "$EF_RAW" "$EF_RC" "env_frozen" || emit_fail "env_frozen: $VAL_ERR"
[ "$(block_hashes_file "$EF_RAW")" = "$ENV_H" ] || emit_fail "env_frozen_hash_drift"
ENV_RC=0
# shellcheck disable=SC1090
. "$ENV_FROZEN" >> "$RUN_LOG" 2>&1 || ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"
EXPECT_PATHS=( "$ENV_FROZEN" ); hash_files "$ENV_FROZEN"; EP_RC=$HASH_RC; EP_RAW="$HASH_RAW"
[ "$EP_RC" -eq 0 ] || emit_fail "env_post_sha_rc=$EP_RC"
validate_block "$EP_RAW" "$EP_RC" "env_post" || emit_fail "env_post: $VAL_ERR"
[ "$(block_hashes_file "$EP_RAW")" = "$ENV_H" ] || emit_fail "env_changed_while_sourcing"

IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
GCC="${RV32_GCC:-}"; OBJCOPY="${RV32_OBJCOPY:-}"
NM="${RV32_TOOLCHAIN_BIN:-}/${RV32_TOOLCHAIN_PREFIX:-}nm"
for t in "$IV" "$VV" "$GCC" "$OBJCOPY" "$NM"; do
    [ -n "$t" ] && [ -x "$t" ] || emit_fail "tool_missing=$t"
done
{
    echo "RV32_IVERILOG   = $IV"
    echo "RV32_VVP        = $VV"
    echo "RV32_GCC        = $GCC"
    echo "RV32_OBJCOPY    = $OBJCOPY"
    echo "RV32_NM         = $NM"
    echo "PYTHON_BIN      = $PYTHON_BIN"
    echo "ENV_SH_SHA      = $ENV_H"
    echo "SNAPSHOT_FILES  = ${#SNAP_ALL[@]} (RTL ${#RTL_SRC[@]} + aux ${#AUX_SRC[@]})"
    "$IV" -V 2>&1 | head -1 || true
    "$GCC" --version 2>&1 | head -1 || true
} >> "$RUN_LOG"

RTLSRC="$(cd -- "$SNAP" && find rtl -name '*.v' | LC_ALL=C sort | tr '\n' ' ')"

#==============================================================================
# 4. 工具调用 helper（rc 原样；spec 与 self-test 共用同一 caller）
#==============================================================================
run_vvp() {   # $1=vvp $2=log ; 其余 = plusargs ; ⇒ RUN_VVP_RC
    # RUN_VVP_TOOL 仅 self-test 用于"同一 caller 喂假工具"；spec 恒用冻结 env 的 $VV
    local vvp="$1" log="$2"; shift 2
    timeout "${TIMEOUT_RUN_S:-900}" "${RUN_VVP_TOOL:-$VV}" "$vvp" "$@" > "$log" 2>&1
    RUN_VVP_RC=$?
    return "$RUN_VVP_RC"
}
assemble_one() {   # $1=load|reuse|only
    local n="$1" rc size
    "$GCC" -march=rv32ima_zicsr_zifencei_zicbom -mabi=ilp32 -nostdlib -nostartfiles \
        -Ttext=0x80000000 -o "$PROG_DIR/dbirq_$n.elf" \
        "$SNAP/$PROG_REL/data_bus_irq_$n.S" > "$RUN_DIR/asm_$n.log" 2>&1
    rc=$?; [ "$rc" -eq 0 ] || emit_fail "gcc_rc_$n=$rc"
    "$OBJCOPY" -O binary "$PROG_DIR/dbirq_$n.elf" "$PROG_DIR/dbirq_$n.bin" >> "$RUN_DIR/asm_$n.log" 2>&1
    rc=$?; [ "$rc" -eq 0 ] || emit_fail "objcopy_rc_$n=$rc"
    size="$(stat -c %s -- "$PROG_DIR/dbirq_$n.bin")"; rc=$?
    [ "$rc" -eq 0 ] || emit_fail "stat_rc_$n=$rc"
    [ "$size" -gt 0 ] || emit_fail "prog_size_zero_$n"
    (( size % 4 == 0 )) || emit_fail "prog_size_unaligned_$n=$size"
    hex_convert "$PYTHON_BIN" "$PROG_DIR/dbirq_$n.bin" 0x80000000 "$PROG_DIR/dbirq_$n.hex" \
        || emit_fail "hex_convert_$n: $HEX_ERR"
    EXPECT_PATHS=( "$PROG_DIR/dbirq_$n.elf" "$PROG_DIR/dbirq_$n.hex" )
    hash_files "${EXPECT_PATHS[@]}"; P_RC=$HASH_RC; P_RAW="$HASH_RAW"
    [ "$P_RC" -eq 0 ] || emit_fail "prog_sha_rc_$n=$P_RC"
    validate_block "$P_RAW" "$P_RC" "prog_sha_$n" || emit_fail "prog_sha_$n: $VAL_ERR"
    { printf 'PROG %s bytes=%s words=%s\n' "$n" "$size" "$((size/4))"; cat -- "$P_RAW"; } >> "$RUN_LOG"
}

#==============================================================================
# 5. self-test：原 8 反证 + 严格 helper 反证 + 真实负控/合法同形控
#==============================================================================
if [ "$MODE" = "self-test" ]; then
    CP_OK=0; CP_N=0
    check_reject() {   # $1=name $2=eval ; 期望 eval 返回非零（caller 拒）
        CP_N=$((CP_N+1))
        if eval "$2"; then echo "CP $1 got=accept want=reject REJECTED" >> "$RUN_LOG"
        else CP_OK=$((CP_OK+1)); echo "CP $1 got=reject want=reject pass" >> "$RUN_LOG"; fi
    }
    check_accept() {   # $1=name $2=eval ; 期望 eval 返回零（caller 接受）
        CP_N=$((CP_N+1))
        if eval "$2"; then CP_OK=$((CP_OK+1)); echo "CP $1 got=accept want=accept pass" >> "$RUN_LOG"
        else echo "CP $1 got=reject want=accept REJECTED" >> "$RUN_LOG"; fi
    }
    FX="$RUN_DIR/fixtures"; mkdir -p -- "$FX"
    FB="$RUN_DIR/fakebin"; mkdir -p -- "$FB"

    # ---- 5a. 原 8 反证（入口锚点/坏 token/mode/zero-check/tool rc/timeout/缺头） ----
    printf 'no anchor\n' > "$FX/noanchor.log"
    check_reject noanchor "[ \"\$(grep -cxF '$ANCHOR' '$FX/noanchor.log' || true)\" = 1 ]"
    printf '%s\n%s\n' "$ANCHOR" "$ANCHOR" > "$FX/dupanchor.log"
    check_reject dupanchor "[ \"\$(grep -cxF '$ANCHOR' '$FX/dupanchor.log' || true)\" = 1 ]"
    printf '%s\nFAIL: boom\n' "$ANCHOR" > "$FX/failtok.log"
    check_reject failtok "[ \"\$(grep -cE 'FAIL|DEFECT|[^A-Za-z]XZ|UNKNOWN' '$FX/failtok.log' || true)\" = 0 ]"
    printf 'DATA_BUS_IRQ_CASE id=IRQ_LOAD mode=1 checks=18 result=PASS\nDATA_BUS_IRQ_CASE id=IRQ_ONLY mode=2 checks=13 result=PASS\n' > "$FX/twomode.log"
    check_reject missing_mode "[ \"\$(grep -c '^DATA_BUS_IRQ_CASE ' '$FX/twomode.log' || true)\" = 3 ]"
    printf 'DATA_BUS_IRQ_CASE id=IRQ_LOAD mode=1 checks=0 result=PASS\n' > "$FX/zerochk.log"
    check_reject zero_check "[ \"\$(grep -cE '^DATA_BUS_IRQ_CASE .* checks=[1-9][0-9]* result=PASS$' '$FX/zerochk.log' || true)\" = 1 ]"
    printf '#!/bin/sh\nexit 3\n' > "$FB/vvp_rc"; chmod +x "$FB/vvp_rc"
    printf '#!/bin/sh\nsleep 5\n' > "$FB/vvp_sleep"; chmod +x "$FB/vvp_sleep"
    : > "$FX/dummy.log"
    check_reject nonzero_rc "timeout 2 '$FB/vvp_rc' >'$FX/dummy.log' 2>&1; [ \$? -eq 0 ]"
    check_reject timeout_rc "timeout 1 '$FB/vvp_sleep' >'$FX/dummy.log' 2>&1; [ \$? -ne 124 ]"
    mkdir -p -- "$FX/snap/rtl/pkg"
    check_reject snapshot_missing_header "[ -f '$FX/snap/rtl/pkg/rv32_defs.vh' ]"

    # ---- 5b. 严格 manifest caller（同一 validate_block）：合法/每种 malformed 精准拒 ----
    printf 'aaa\n' > "$FX/f1"; printf 'bbb\n' > "$FX/f2"; printf 'ccc\n' > "$FX/f3"
    EXPECT_PATHS=( "$FX/f1" "$FX/f2" "$FX/f3" )
    hash_files "${EXPECT_PATHS[@]}"; GOOD_F="$HASH_RAW"; GRC="$HASH_RC"
    check_accept manifest_good "validate_block '$GOOD_F' '$GRC' t"
    # 正常一终止 LF 的合法 N 行块（上面 GOOD_F）必须接受；多 +1 / 多空尾行必须精确拒
    cp -p "$GOOD_F" "$FX/m_blank1"; printf '\n' >> "$FX/m_blank1"
    check_reject manifest_blank_tail1 "validate_block '$FX/m_blank1' 0 t"
    cp -p "$GOOD_F" "$FX/m_blank2"; printf '\n\n' >> "$FX/m_blank2"
    check_reject manifest_blank_tail2 "validate_block '$FX/m_blank2' 0 t"
    python3 - "$GOOD_F" "$FX/m_no_final_lf" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(b[:-1])
PY
    check_reject manifest_no_final_lf "validate_block '$FX/m_no_final_lf' 0 t"
    python3 - "$GOOD_F" "$FX/m_nul" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(b.replace(b'  ', b'\0 ', 1))
PY
    check_reject manifest_nul "validate_block '$FX/m_nul' 0 t"
    cp -p "$GOOD_F" "$FX/m_trail"; printf 'deadbeef  /x\n' >> "$FX/m_trail"
    check_reject manifest_trailing "validate_block '$FX/m_trail' 0 t"
    sed "2s#  .*#  $FX/f1#" "$GOOD_F" > "$FX/m_dup"
    check_reject manifest_duplicate "validate_block '$FX/m_dup' 0 t"
    sed '3d' "$GOOD_F" > "$FX/m_missing"
    check_reject manifest_missing "validate_block '$FX/m_missing' 0 t"
    sed '1s/^[0-9a-f]/x/' "$GOOD_F" > "$FX/m_hex"
    check_reject manifest_badhex "validate_block '$FX/m_hex' 0 t"
    sed "1s#  .*#  $FX/nope#" "$GOOD_F" > "$FX/m_path"
    check_reject manifest_wrongpath "validate_block '$FX/m_path' 0 t"
    : > "$FX/m_empty"
    check_reject manifest_empty "validate_block '$FX/m_empty' 0 t"
    # 真实工具"输出完整合法但 rc=9"⇒ 同一 caller 必须拒
    printf '#!/bin/sh\n%s "$@"\nr=$?\nexit 9\n' "$REAL_SHA_BIN" > "$FB/sha256sum"; chmod +x "$FB/sha256sum"
    OLD_PATH="$PATH"; export PATH="$FB:$PATH"
    hash_files "${EXPECT_PATHS[@]}" >/dev/null 2>&1
    BADRC="$HASH_RC"; BADRAW="$HASH_RAW"
    export PATH="$OLD_PATH"
    check_reject manifest_rc9 "validate_block '$BADRAW' '$BADRC' t"
    check_accept manifest_rc9_precondition "[ \"\$BADRC\" = 9 ] && [ \"\$(grep -cE '^[0-9a-f]{64}  ' '$BADRAW')\" = 3 ]"

    # ---- 5c. 转换 python3：合法输出后 exit 9 ⇒ hex_convert 必须拒；真工具控过 ----
    printf '@80000000\n00000013\n' > "$FX/good.hex"
    printf '#!/bin/sh\ncp "%s" "$4"\nexit 9\n' "$FX/good.hex" > "$FB/py9"; chmod +x "$FB/py9"
    printf '\x13\x00\x00\x00' > "$FX/in.bin"
    check_reject hex_convert_rc9 "hex_convert '$FB/py9' '$FX/in.bin' 0x80000000 '$FX/out9.hex'"
    check_accept hex_convert_rc9_sig "[ \"\$HEX_ERR\" = 'python_rc=9' ]"
    check_accept hex_convert_good "hex_convert '$PYTHON_BIN' '$FX/in.bin' 0x80000000 '$FX/out.hex'"

    # ---- 5d. nm：先 rc 后解析；合法输出后 exit 9 / 重复 / 非 32bit ⇒ 拒 ----
    "$GCC" -march=rv32ima_zicsr_zifencei_zicbom -mabi=ilp32 -nostdlib -nostartfiles \
        -Ttext=0x80000000 -o "$RUN_DIR/selfnm.elf" "$SNAP/$PROG_REL/data_bus_irq_load.S" \
        >> "$RUN_LOG" 2>&1 || emit_fail self_nm_assemble
    nm_symbol "$NM" "$RUN_DIR/selfnm.elf" A_load || emit_fail "self_nm_ground: $NM_ERR"
    GOT_A="$NM_SYM"
    cp -p -- "$RUN_DIR/nm_selfnm.elf.txt" "$RUN_DIR/selfnm.real.txt" || emit_fail self_nm_real_copy
    printf '#!/bin/sh\ncat "%s/selfnm.real.txt"\nexit 9\n' "$RUN_DIR" > "$FB/nm9"; chmod +x "$FB/nm9"
    check_reject nm_rc9 "nm_symbol '$FB/nm9' '$RUN_DIR/selfnm.elf' A_load"
    check_accept nm_rc9_sig "[ \"\$NM_ERR\" = 'nm_rc=9' ]"
    printf '#!/bin/sh\necho "80000000 t A_load"\necho "80000004 t A_load"\n' > "$FB/nmdup"; chmod +x "$FB/nmdup"
    check_reject nm_dup "nm_symbol '$FB/nmdup' '$RUN_DIR/selfnm.elf' A_load"
    check_accept nm_dup_sig "[ \"\$NM_ERR\" = 'sym_count_A_load=2' ]"
    printf '#!/bin/sh\necho "zzzzzzzz t A_load"\n' > "$FB/nmbad"; chmod +x "$FB/nmbad"
    check_reject nm_not32 "nm_symbol '$FB/nmbad' '$RUN_DIR/selfnm.elf' A_load"
    check_accept nm_not32_sig "[ \"\$NM_ERR\" = 'sym_not_32bit=zzzzzzzz' ]"
    check_accept nm_good "nm_symbol '$NM' '$RUN_DIR/selfnm.elf' A_load && [ \"\$NM_SYM\" = '$GOT_A' ]"

    # ---- 5e. run caller：合法日志后 exit 9 / 超时 ⇒ 拒（同一 run_vvp） ----
    printf '%s\n' 'TB_DATA_BUS_IRQ: PASS mode=1' > "$FX/fake_pass.log"
    printf '#!/bin/sh\ncat "%s/fake_pass.log"\nexit 9\n' "$FX" > "$FB/vvp9"; chmod +x "$FB/vvp9"
    RUN_VVP_TOOL="$FB/vvp9"
    check_reject run_rc9 "run_vvp '$FX/fake_pass.log' '$FX/fake_run9.log'; [ \"\$RUN_VVP_RC\" = 0 ]"
    check_accept run_rc9_sig "[ \"\$RUN_VVP_RC\" = 9 ]"
    RUN_VVP_TOOL="$FB/vvp_sleep"
    OLD_TRT="${TIMEOUT_RUN_S:-}"
    TIMEOUT_RUN_S=1
    check_reject run_timeout "run_vvp '$FX/fake_pass.log' '$FX/fake_runT.log'; [ \"\$RUN_VVP_RC\" = 0 ]"
    check_accept run_timeout_sig "[ \"\$RUN_VVP_RC\" = 124 ]"
    TIMEOUT_RUN_S="$OLD_TRT"
    RUN_VVP_TOOL="$VV"

    # ---- 5f. 真实 mode-1 控制 / B 篡改 / 监测字段 X 注入（同一冻结 TB） ----
    PROG_DIR="$RUN_DIR/prog"; mkdir -p -- "$PROG_DIR" || emit_fail self_prog_dir
    assemble_one load || emit_fail self_assemble_load
    nm_symbol "$NM" "$PROG_DIR/dbirq_load.elf" A_load || emit_fail "self_apc: $NM_ERR"
    APC="$NM_SYM"
    ( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
        -P "tb_data_bus_irq.PROG_HEX=\"$PROG_DIR/dbirq_load.hex\"" \
        -P "tb_data_bus_irq.MODE=1" -P "tb_data_bus_irq.A_PC=0x$APC" \
        -P "tb_data_bus_irq.WAIT_PC=0x0" -o "$RUN_DIR/self.vvp" \
        $RTLSRC "$TB_REL" "$MODEL_REL" ) >> "$RUN_LOG" 2>&1 || emit_fail self_compile
    run_vvp "$RUN_DIR/self.vvp" "$RUN_DIR/self_ctl.log" || { cat "$RUN_DIR/self_ctl.log" >> "$RUN_LOG"; emit_fail "self_control_rc=$RUN_VVP_RC"; }
    [ "$(grep -cxF 'TB_DATA_BUS_IRQ: PASS mode=1' "$RUN_DIR/self_ctl.log" || true)" = "1" ] || emit_fail self_control_anchor
    run_vvp "$RUN_DIR/self.vvp" "$RUN_DIR/self_tamper.log" +TAMPER_B=1
    TRC=$RUN_VVP_RC
    cat "$RUN_DIR/self_tamper.log" >> "$RUN_LOG"
    [ "$TRC" -ne 0 ] || emit_fail self_tamper_rc_zero
    [ "$(grep -cF 'FAIL: 程序自检 C1 = 0' "$RUN_DIR/self_tamper.log" || true)" = "1" ] || emit_fail self_tamper_signature
    [ "$(grep -cxF 'TB_DATA_BUS_IRQ: PASS mode=1' "$RUN_DIR/self_tamper.log" || true)" = "0" ] || emit_fail self_tamper_false_pass
    for x in "XINJ_CAUSE=1|mcause = 0x8000000B (MEI)" "XINJ_EPC=1|中断 mepc = A_load PC"; do
        pa="${x%%|*}"; sig="${x#*|}"
        run_vvp "$RUN_DIR/self.vvp" "$RUN_DIR/self_x_${pa%%=*}.log" "+$pa"
        XRC=$RUN_VVP_RC
        cat "$RUN_DIR/self_x_${pa%%=*}.log" >> "$RUN_LOG"
        [ "$XRC" -ne 0 ] || emit_fail "x_inject_${pa}_rc_zero"
        [ "$(grep -cF "FAIL: $sig" "$RUN_DIR/self_x_${pa%%=*}.log" || true)" = "1" ] || emit_fail "x_inject_${pa}_signature"
        [ "$(grep -cxF 'TB_DATA_BUS_IRQ: PASS mode=1' "$RUN_DIR/self_x_${pa%%=*}.log" || true)" = "0" ] || emit_fail "x_inject_${pa}_false_pass"
    done
    # ---- 5f-2. mode3 tag 同 X / 同 Z 负工装（已知同 tag 正控；用 == 让 chk!==1 拒 X） ----
    assemble_one reuse || emit_fail self_assemble_reuse
    nm_symbol "$NM" "$PROG_DIR/dbirq_reuse.elf" A_load || emit_fail "self_apc3: $NM_ERR"
    APC3="$NM_SYM"
    ( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
        -P "tb_data_bus_irq.PROG_HEX=\"$PROG_DIR/dbirq_reuse.hex\"" \
        -P "tb_data_bus_irq.MODE=3" -P "tb_data_bus_irq.A_PC=0x$APC3" \
        -P "tb_data_bus_irq.WAIT_PC=0x0" -o "$RUN_DIR/self_m3.vvp" \
        $RTLSRC "$TB_REL" "$MODEL_REL" ) >> "$RUN_LOG" 2>&1 || emit_fail self_m3_compile
    run_vvp "$RUN_DIR/self_m3.vvp" "$RUN_DIR/self_m3_ctl.log" || { cat "$RUN_DIR/self_m3_ctl.log" >> "$RUN_LOG"; emit_fail "self_m3_control_rc=$RUN_VVP_RC"; }
    check_accept m3_control "[ \"\$(grep -cxF 'TB_DATA_BUS_IRQ: PASS mode=3' '$RUN_DIR/self_m3_ctl.log')\" = 1 ]"
    for tg in XINJ_TAGX XINJ_TAGZ; do
        run_vvp "$RUN_DIR/self_m3.vvp" "$RUN_DIR/self_m3_$tg.log" "+$tg=1"
        M3RC=$RUN_VVP_RC
        cat "$RUN_DIR/self_m3_$tg.log" >> "$RUN_LOG"
        check_reject "m3_${tg}_rc" "[ \"\$M3RC\" = 0 ]"
        check_accept "m3_${tg}_sig" "[ \"\$(grep -cF 'FAIL: B 实际复用 A 的 LQ tag（same tag）' '$RUN_DIR/self_m3_$tg.log')\" = 1 ]"
        check_reject "m3_${tg}_pass" "[ \"\$(grep -cxF 'TB_DATA_BUS_IRQ: PASS mode=3' '$RUN_DIR/self_m3_$tg.log')\" = 1 ]"
    done
    printf 'DATA_BUS_IRQ_NEGCTRL tamper_signature=1 control_green=1 tamper_red=1 xinject_cause=1 xinject_epc=1 tagx=1 tagz=1\n' >> "$RUN_LOG"

    # ---- 5g. 收口：source/snapshot 身份不变 ----
    EXPECT_PATHS=( "${SRC_ALL[@]}" ); hash_files "${SRC_ALL[@]}"; S2_RC=$HASH_RC; S2_RAW="$HASH_RAW"
    [ "$S2_RC" -eq 0 ] || emit_fail self_src_sha_rc
    validate_block "$S2_RAW" "$S2_RC" "self_source_after" || emit_fail "self_source_after: $VAL_ERR"
    [ "$(block_hashes_file "$S2_RAW")" = "$(printf '%s\n' "${SRC_H[@]}")" ] || emit_fail self_source_mutated
    EXPECT_PATHS=( "${SNAP_ALL[@]}" ); hash_files "${SNAP_ALL[@]}"; K2_RC=$HASH_RC; K2_RAW="$HASH_RAW"
    [ "$K2_RC" -eq 0 ] || emit_fail self_snap_sha_rc
    validate_block "$K2_RAW" "$K2_RC" "self_snapshot_after" || emit_fail "self_snapshot_after: $VAL_ERR"
    [ "$(block_hashes_file "$K2_RAW")" = "$(printf '%s\n' "${SNAP_H[@]}")" ] || emit_fail self_snapshot_mutated

    [ "$CP_OK" -eq "$CP_N" ] || emit_fail "counterproof=$CP_OK/$CP_N"
    printf 'DATA_BUS_IRQ_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N" >> "$RUN_LOG"
    printf '%s\n' "$NEG_ANCHOR" >> "$RUN_LOG"
    [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS_IRQ: PASS' "$RUN_LOG" || true)" = "0" ] || emit_fail default_anchor_in_neg
    printf 'DATA_BUS_IRQ_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N"
    printf 'DATA_BUS_IRQ_NEGCTRL tamper_signature=1 control_green=1 tamper_red=1 xinject_cause=1 xinject_epc=1 tagx=1 tagz=1\n'
    printf '%s\n' "$NEG_ANCHOR"
    exit 0
fi

#==============================================================================
# 6. spec：汇编 + 逐 mode 编译/真跑/判定
#==============================================================================
PROG_DIR="$RUN_DIR/prog"; mkdir -p -- "$PROG_DIR" || emit_fail prog_dir
assemble_one load  || emit_fail assemble_load
assemble_one reuse || emit_fail assemble_reuse
assemble_one only  || emit_fail assemble_only
nm_symbol "$NM" "$PROG_DIR/dbirq_load.elf"  A_load    || emit_fail "sym_load: $NM_ERR"
APC_LOAD="$NM_SYM"
nm_symbol "$NM" "$PROG_DIR/dbirq_reuse.elf" A_load    || emit_fail "sym_reuse: $NM_ERR"
APC_REUSE="$NM_SYM"
nm_symbol "$NM" "$PROG_DIR/dbirq_only.elf"  wait_loop || emit_fail "sym_only: $NM_ERR"
WPC_ONLY="$NM_SYM"
printf 'SYMS A_load(load)=0x%s A_load(reuse)=0x%s wait_loop(only)=0x%s\n' \
       "$APC_LOAD" "$APC_REUSE" "$WPC_ONLY" >> "$RUN_LOG"

run_case() {   # $1=mode $2=ID $3=prog $4=A_PC $5=WAIT_PC $6=expect_checks
    local mode="$1" id="$2" prog="$3" apc="$4" wpc="$5" exp="$6"
    local vvp="$RUN_DIR/tb_irq_m$mode.vvp" log="$RUN_DIR/run_m$mode.log" rc na nb nc
    {
        echo "-- m$mode compile cwd=$SNAP (relative -I; frozen copies only)"
        echo "-- m$mode inputs: $(printf '%s ' "$TB_REL" "$MODEL_REL")+ RTL(${#RTL_SRC[@]}) + prog hex=$(basename -- "$PROG_DIR/dbirq_$prog.hex")"
    } >> "$RUN_LOG"
    ( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
        -P "tb_data_bus_irq.PROG_HEX=\"$PROG_DIR/dbirq_$prog.hex\"" \
        -P "tb_data_bus_irq.MODE=$mode" -P "tb_data_bus_irq.A_PC=0x$apc" \
        -P "tb_data_bus_irq.WAIT_PC=0x$wpc" -o "$vvp" \
        $RTLSRC "$TB_REL" "$MODEL_REL" ) > "$RUN_DIR/compile_m$mode.log" 2>&1
    rc=$?; [ "$rc" -eq 0 ] || { cat "$RUN_DIR/compile_m$mode.log" >> "$RUN_LOG"; emit_fail "compile_m$mode=$rc"; }
    [ -s "$vvp" ] || emit_fail "compile_zero_m$mode"
    echo "RUN_CMD m$mode = \"${RUN_VVP_TOOL:-$VV}\" $vvp" >> "$RUN_LOG"
    run_vvp "$vvp" "$log"; rc=$RUN_VVP_RC
    [ "$rc" -eq 124 ] && emit_fail "timeout_m$mode"
    [ "$rc" -ne 0 ] && { cat "$log" >> "$RUN_LOG"; emit_fail "run_rc_m$mode=$rc"; }
    [ -s "$log" ] || emit_fail "run_empty_m$mode"
    na="$(grep -cxF "TB_DATA_BUS_IRQ: PASS mode=$mode" "$log" || true)"
    [ "$na" = "1" ] || { cat "$log" >> "$RUN_LOG"; emit_fail "mode_anchor_m$mode=$na"; }
    nb="$(grep -cE 'FAIL|DEFECT|[^A-Za-z]XZ|UNKNOWN' "$log" || true)"
    [ "$nb" = "0" ] || { cat "$log" >> "$RUN_LOG"; emit_fail "bad_tokens_m$mode=$nb"; }
    nc="$(grep -cE "^DATA_BUS_IRQ_CASE id=$id mode=$mode checks=$exp result=PASS$" "$log" || true)"
    [ "$nc" = "1" ] || { grep -E 'DATA_BUS_IRQ_CASE|FAIL' "$log" >> "$RUN_LOG" || true;
                         emit_fail "case_m$mode=$nc expect=$exp"; }
    cat -- "$log" >> "$RUN_LOG"
    printf 'DATA_BUS_IRQ_CASE id=%s mode=%s checks=%s result=PASS\n' "$id" "$mode" "$exp"
}

run_case 1 IRQ_LOAD  load  "$APC_LOAD"  0x0        18
run_case 3 IRQ_REUSE reuse "$APC_REUSE" 0x0        19
run_case 2 IRQ_ONLY  only  0x0          "$WPC_ONLY" 13

#==============================================================================
# 7. 收口：source/snapshot 两侧身份不变；三 case；唯一 FUNCTIONAL 锚点
#==============================================================================
EXPECT_PATHS=( "${SRC_ALL[@]}" ); hash_files "${SRC_ALL[@]}"; SA_RC=$HASH_RC; SA_RAW="$HASH_RAW"
[ "$SA_RC" -eq 0 ] || emit_fail "source_after_sha_rc=$SA_RC"
validate_block "$SA_RAW" "$SA_RC" "source_after" || emit_fail "source_after: $VAL_ERR"
[ "$(block_hashes_file "$SA_RAW")" = "$(printf '%s\n' "${SRC_H[@]}")" ] || emit_fail source_mutated_during_run
EXPECT_PATHS=( "${SNAP_ALL[@]}" ); hash_files "${SNAP_ALL[@]}"; KA_RC=$HASH_RC; KA_RAW="$HASH_RAW"
[ "$KA_RC" -eq 0 ] || emit_fail "snapshot_after_sha_rc=$KA_RC"
validate_block "$KA_RAW" "$KA_RC" "snapshot_after" || emit_fail "snapshot_after: $VAL_ERR"
[ "$(block_hashes_file "$KA_RAW")" = "$(printf '%s\n' "${SNAP_H[@]}")" ] || emit_fail snapshot_mutated_during_run
printf 'DATA_BUS_IRQ_FREEZE source_n=%s snapshot_n=%s source_unchanged=1 snapshot_unchanged=1\n' \
       "${#SRC_ALL[@]}" "${#SNAP_ALL[@]}" >> "$RUN_LOG"

NCASE="$(grep -hcE '^DATA_BUS_IRQ_CASE id=(IRQ_LOAD|IRQ_ONLY|IRQ_REUSE) mode=[123] checks=[1-9][0-9]* result=PASS$' \
         "$RUN_DIR/run_m1.log" "$RUN_DIR/run_m2.log" "$RUN_DIR/run_m3.log" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
[ "$NCASE" = "3" ] || emit_fail "case_total=$NCASE"
for pair in "1|IRQ_LOAD|18" "2|IRQ_ONLY|13" "3|IRQ_REUSE|19"; do
    m="${pair%%|*}"; rest="${pair#*|}"; id="${rest%%|*}"; exp="${rest#*|}"
    n="$(grep -cE "^DATA_BUS_IRQ_CASE id=$id mode=$m checks=$exp result=PASS$" "$RUN_DIR/run_m$m.log" || true)"
    [ "$n" = "1" ] || emit_fail "case_fixed_m$m n=$n"
done
printf 'DATA_BUS_IRQ_CASES total=3 ok=3 fail=0\n' | tee -a "$RUN_LOG"
printf '%s\n' "$ANCHOR" | tee -a "$RUN_LOG"
[ "$(grep -cxF "$ANCHOR" "$RUN_LOG" || true)" = "1" ] || emit_fail driver_anchor
exit 0
