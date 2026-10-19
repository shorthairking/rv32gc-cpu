#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_decode_driver.sh —— F1 译码包自证驱动（正式源；fresh clone 可复现）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）
# 目的 : 把原先只存在于 build/ 生成目录的反证生成器整理为**正式源**，使
#        `bash sim/functional/test_decode_driver.sh` 在全新克隆（无任何 build/ 产物）
#        上也能完整复现 F1 译码包的包装器自证。build/ 只作为**本次唯一 run 的输出根**。
#
# 做什么 :
#   ① 正控（必须 PASS，且与反证同环境）：
#        P1 no-op TB 副本：把正式 tb_decode_semantics.sv **字节相同**地放进迷你仓库运行；
#        P2/P3/P4 假工具 PATH 垫片：`iverilog`/`vvp`/`sha256sum` 垫片 `exec` 真工具，
#           证明"同一假工具环境"下存在合法正控可过（不是所有假工具都无条件失败）；
#        P5 私有 poison-cwd：调用者 cwd 内放冲突/非法 rtl/pkg 头（不改任何正式头），
#           正确 DUT_ROOT 的编译必须不受影响；并先证明 poison 头"确实有毒"。
#   ② 反证 19 例（必须全部被拒）：
#        原 7 例（dup-pass / no-anchor / no-capture / fails-nz / vec-short /
#        zero-vec / hang）＋ 第一轮 10 例（bad-field / log-failword / defect-repro /
#        unknown-arg / unauthorized-out / sha-fail / fake-iverilog-noartifact /
#        fake-vvp-empty / vec-checks-sum / one-vector-selfconsistent）
#        ＋ TB 本体变异 2 例（mut-del-vector / mut-del-checks；在本次 run 目录里
#        从**正式 TB** 复制变异，正式 TB 不改；并额外要求变异 TB 自己的 run 日志
#        命中 TB 自判证据，防止只靠包装器遮盖）。
#
# 依赖 : 只读仓库正式源（路径由本文件所在目录推导）：
#          scripts/env.sh（工具真源；只读）
#          rtl/decode/{decoder,dec_imm,dec_csr,compressed_expand}.v
#          sim/functional/test_decode.sh
#          sim/functional/tb_decode_semantics.sv
#        **不读取 build/ 下任何既有产物**（不依赖 build/gen、旧负例、旧日志）。
#
# 产物 : <repo>/build/functional/decode/driver-<随机>/（本次唯一 run 根；
#        内含各迷你仓库夹具与该夹具自己的 build/.../run-* 日志）。脚本内无 rm。
#
# 用法 : bash sim/functional/test_decode_driver.sh
# 判定 : 5/5 正控 PASS、19/19 反证被拒 ⇒ 唯一整行 `FUNCTIONAL_DECODE_DRIVER: PASS`，rc=0。
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数：本驱动不接受任何位置参数
#------------------------------------------------------------------------------
if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }

REAL_SH="$SELF_DIR/test_decode.sh"
REAL_TB="$SELF_DIR/tb_decode_semantics.sv"
REAL_ENV="$REPO_ROOT/scripts/env.sh"
REAL_RTL_DIR="$REPO_ROOT/rtl/decode"
REAL_PKG_DIR="$REPO_ROOT/rtl/pkg"

# ---- 夹具自洽依赖前置检查（缺任一即失败；禁止借用别的 cwd 的头文件）----
REAL_PKG_DEFS="$REAL_PKG_DIR/rv32_defs.vh"
REAL_PKG_PARAMS="$REAL_PKG_DIR/core_params.vh"

for f in "$REAL_SH" "$REAL_TB" "$REAL_ENV" \
         "$REAL_RTL_DIR/decoder.v" "$REAL_RTL_DIR/dec_imm.v" \
         "$REAL_RTL_DIR/dec_csr.v" "$REAL_RTL_DIR/compressed_expand.v" \
         "$REAL_PKG_DEFS" "$REAL_PKG_PARAMS"; do
    [ -f "$f" ] || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=src_missing file=%s\n' "$f"; exit 1; }
done

#------------------------------------------------------------------------------
# 1. 工具真源（只读 scripts/env.sh）：拿真工具路径供"垫片委托"用
#------------------------------------------------------------------------------
if [ ! -r "$REAL_ENV" ]; then
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=env_sh_unreadable path=%s\n' "$REAL_ENV"; exit 1
fi
# shellcheck disable=SC1090
. "$REAL_ENV" >/dev/null 2>&1
ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=env_sh_source_rc=%s\n' "$ENV_RC"; exit 1; }
REAL_IV="${RV32_IVERILOG:-}"
REAL_VV="${RV32_VVP:-}"
REAL_SHA="$(command -v sha256sum || true)"
[ -n "$REAL_IV" ] && [ -x "$REAL_IV" ] || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=real_tool_missing iverilog\n'; exit 1; }
[ -n "$REAL_VV" ] && [ -x "$REAL_VV" ] || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=real_tool_missing vvp\n'; exit 1; }
[ -n "$REAL_SHA" ] && [ -x "$REAL_SHA" ] || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=real_tool_missing sha256sum\n'; exit 1; }

#------------------------------------------------------------------------------
# 2. 本次唯一 run 根（授权树内 mktemp；无 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=auth_root_readlink_failed\n'; exit 1; }
case "$AUTH_ROOT" in /*) : ;; *) printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=auth_root_relative\n'; exit 1 ;; esac
mkdir -p -- "$AUTH_ROOT" || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=auth_root_mkdir_failed\n'; exit 1; }
# fresh clone 下 build/functional/decode 可能不存在 ⇒ 先建本次 run 根的父目录（不用 rm）
DECODE_ROOT="$AUTH_ROOT/decode"
mkdir -p -- "$DECODE_ROOT" || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=decode_root_mkdir_failed root=%s\n' "$DECODE_ROOT"; exit 1; }
DRIVER_ROOT="$(mktemp -d -- "$DECODE_ROOT/driver-XXXXXXXX")" || {
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=mktemp_driver_root_failed root=%s\n' "$DECODE_ROOT"; exit 1; }
DRIVER_LOG="$DRIVER_ROOT/driver.log"
: > "$DRIVER_LOG" || { printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }

N_POS=0; N_POS_OK=0
N_NEG=0; N_NEG_OK=0

driver_fail() {
    printf 'FUNCTIONAL_DECODE_DRIVER: FAIL reason=%s driver_root=%s\n' "$1" "$DRIVER_ROOT"
    exit 1
}

#------------------------------------------------------------------------------
# 3. 迷你仓库骨架（全部取自正式源；不碰 build/ 既有产物）
#    自洽要求：每棵迷你仓库自带 scripts/env.sh、rtl/decode/4 模块、
#    rtl/pkg/{rv32_defs.vh,core_params.vh}、sim/functional/test_decode.sh；
#    运行时 cwd 固定为迷你仓库本身 ⇒ **不得借用调用者 cwd 的任何输入**。
#------------------------------------------------------------------------------
build_repo() {   # $1=dir（TB 由调用方随后放置）
    local dir="$1"
    mkdir -p -- "$dir/scripts" "$dir/rtl/decode" "$dir/rtl/pkg" "$dir/sim/functional" || return 1
    cp -f -- "$REAL_ENV" "$dir/scripts/env.sh" || return 1
    cp -f -- "$REAL_RTL_DIR/decoder.v" "$REAL_RTL_DIR/dec_imm.v" \
             "$REAL_RTL_DIR/dec_csr.v" "$REAL_RTL_DIR/compressed_expand.v" \
             "$dir/rtl/decode/" || return 1
    cp -f -- "$REAL_PKG_DEFS" "$REAL_PKG_PARAMS" "$dir/rtl/pkg/" || return 1
    cp -f -- "$REAL_SH" "$dir/sim/functional/test_decode.sh" || return 1
    cmp -s -- "$REAL_SH" "$dir/sim/functional/test_decode.sh" || {
        echo "FIXTURE DRIFT: $dir/sim/functional/test_decode.sh"; exit 1; }
    # 自洽校验：夹具必须自带全部编译依赖（含两个正式头），否则 fail-closed
    local need
    for need in "rtl/decode/decoder.v" "rtl/decode/dec_imm.v" \
                "rtl/decode/dec_csr.v" "rtl/decode/compressed_expand.v" \
                "rtl/pkg/rv32_defs.vh" "rtl/pkg/core_params.vh" \
                "scripts/env.sh" "sim/functional/test_decode.sh"; do
        [ -f "$dir/$need" ] || {
            echo "FIXTURE INCOMPLETE: $dir/$need"; exit 1; }
    done
    cmp -s -- "$REAL_PKG_DEFS" "$dir/rtl/pkg/rv32_defs.vh" || {
        echo "FIXTURE DRIFT: $dir/rtl/pkg/rv32_defs.vh"; exit 1; }
    cmp -s -- "$REAL_PKG_PARAMS" "$dir/rtl/pkg/core_params.vh" || {
        echo "FIXTURE DRIFT: $dir/rtl/pkg/core_params.vh"; exit 1; }
    return 0
}

# gen_tb <out> <nvec> <checks1> <checks_rest> <summary> <npass> [extra_line]
gen_tb() {
    local out="$1" nvec="$2" c1="$3" cr="$4" summary="$5" npass="$6" extra="${7:-}" k
    {
        printf '%s\n' '`timescale 1ns/1ps' 'module tb_decode_semantics_top;' \
                      '  integer i, c;' '  initial begin'
        if [ "$nvec" -gt 0 ]; then
            printf '    for (i=1;i<=%d;i=i+1) begin\n' "$nvec"
            printf '      c = (i==1) ? %d : %d;\n' "$c1" "$cr"
            printf '%s\n' '      $display("VEC %0d FAKE%0d checks=%0d fails=0", i, i, c);'
            printf '%s\n' '    end'
        fi
        printf '    $display("%s");\n' "$summary"
        [ -n "$extra" ] && printf '    $display("%s");\n' "$extra"
        k=0
        while [ "$k" -lt "$npass" ]; do
            printf '%s\n' '    $display("FUNCTIONAL_DECODE: PASS");'
            k=$((k + 1))
        done
        printf '%s\n' '    $finish;' '  end' 'endmodule'
    } > "$out" || return 1
    return 0
}

# 假工具 PATH 垫片：<dir>/<name> 内容 = exec <real> "$@"
make_shim() {    # $1=dir $2=name $3=real
    local dir="$1" name="$2" real="$3"
    mkdir -p -- "$dir" || return 1
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'exec "%s" "$@"\n' "$real"
    } > "$dir/$name" || return 1
    chmod +x "$dir/$name" || return 1
    return 0
}

#------------------------------------------------------------------------------
# 4. 判据助手
#    · 所有夹具均在**自身目录**为 cwd 运行（CAPTURE_CWD）⇒ 不许借用调用者 cwd 输入
#    · 反证必须精确 rc==1（wrapper 把底层 124/其它一律映为 exit 1），且 stdout 必须
#      恰有 1 行正式 `FUNCTIONAL_DECODE: FAIL reason=<字段> run_dir=/…`，其 reason
#      以期望字段**起始**匹配；不再用"非零 + 任意位置 grep"当拒绝。
#------------------------------------------------------------------------------
newest_own_log() {  # $1=迷你仓库目录
    ls -dt "$1"/build/functional/decode/run-*/test_decode.log 2>/dev/null | head -1
}

RUN_OUT=""
RUN_RC=0
CAPTURE_CWD=""
capture() {  # $@ = 命令；若 CAPTURE_CWD 非空则先 cd 到该目录
    if [ -n "$CAPTURE_CWD" ]; then
        RUN_OUT="$( cd -- "$CAPTURE_CWD" && "$@" 2>&1 )"
    else
        RUN_OUT="$("$@" 2>&1)"
    fi
    RUN_RC=$?
}

# 正式失败行计数（整行锚点；参数非法等早期失败行不带 run_dir 也算）
count_fail_lines() {
    printf '%s\n' "$RUN_OUT" | grep -c '^FUNCTIONAL_DECODE: FAIL reason=' || true
}

# 从唯一正式失败行提取 reason 字段（剥离可能的 ` run_dir=...` 后缀；无匹配输出空）
extract_fail_reason() {
    local line
    line="$(printf '%s\n' "$RUN_OUT" | grep -m1 '^FUNCTIONAL_DECODE: FAIL reason=' || true)"
    [ -n "$line" ] || return 0
    line="${line#FUNCTIONAL_DECODE: FAIL reason=}"
    printf '%s\n' "${line%% run_dir=*}"
}

# 正控：必须 rc=0 + 唯一 PASS 锚点 + 无 FAIL 字样（在 $dir 为 cwd 下运行）
run_expect_pass() {  # $1=case 名 $2=夹具目录 ; 其余=命令
    local name="$1" dir="$2"; shift 2
    N_POS=$((N_POS + 1))
    CAPTURE_CWD="$dir"; capture "$@"; CAPTURE_CWD=""
    if [ "$RUN_RC" -ne 0 ]; then
        echo "DRIVER-POS-FAIL($name): rc=$RUN_RC (expect 0)"
        printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
        driver_fail "positive_${name}_rc=$RUN_RC"
    fi
    if [ "$(printf '%s\n' "$RUN_OUT" | grep -cxF 'FUNCTIONAL_DECODE: PASS')" != "1" ]; then
        echo "DRIVER-POS-FAIL($name): PASS anchor count != 1"
        printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
        driver_fail "positive_${name}_anchor"
    fi
    if printf '%s\n' "$RUN_OUT" | grep -q 'FAIL'; then
        echo "DRIVER-POS-FAIL($name): output contains FAIL"
        driver_fail "positive_${name}_fail_word"
    fi
    N_POS_OK=$((N_POS_OK + 1))
    echo "DRIVER-POS-OK($name): rc=0 唯一 PASS 锚点"
}

# 反证：必须 rc==1 + 无 PASS 锚点 + 恰 1 行正式 FAIL + reason 前缀命中
run_expect_reject() {  # $1=dir $2=reason_prefix ; 其余=命令
    local dir="$1" pat="$2"; shift 2
    local name n_fl reason
    name="$(basename -- "$dir")"
    N_NEG=$((N_NEG + 1))
    CAPTURE_CWD="$dir"; capture "$@"; CAPTURE_CWD=""
    if [ "$RUN_RC" -ne 1 ]; then
        echo "DRIVER-NEG-FAIL($name): rc=$RUN_RC (expect exactly 1)"
        printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
        driver_fail "negative_${name}_rc=$RUN_RC"
    fi
    if printf '%s\n' "$RUN_OUT" | grep -qxF 'FUNCTIONAL_DECODE: PASS'; then
        echo "DRIVER-NEG-FAIL($name): printed PASS line"
        printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
        driver_fail "negative_${name}_printed_pass"
    fi
    n_fl="$(count_fail_lines)"
    if [ "$n_fl" != "1" ]; then
        echo "DRIVER-NEG-FAIL($name): formal FAIL lines=$n_fl (expect 1)"
        printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
        driver_fail "negative_${name}_fail_lines=$n_fl"
    fi
    reason="$(extract_fail_reason)"
    case "$reason" in
        "$pat"*) : ;;
        *)  echo "DRIVER-NEG-FAIL($name): reason='$reason' not prefixed by '$pat'"
            printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
            driver_fail "negative_${name}_reason" ;;
    esac
    N_NEG_OK=$((N_NEG_OK + 1))
    echo "DRIVER-NEG-OK($name): rc=1 reason=$reason"
}

# TB 变异反证：同上严格判据 + 额外要求变异 TB 自己的 run 日志命中 TB 自判证据
run_expect_reject_log() {  # $1=dir $2=reason_prefix $3=log_pat ; 其余=命令
    local dir="$1" spat="$2" lpat="$3"; shift 3
    local name log n_fl reason
    name="$(basename -- "$dir")"
    N_NEG=$((N_NEG + 1))
    CAPTURE_CWD="$dir"; capture "$@"; CAPTURE_CWD=""
    if [ "$RUN_RC" -ne 1 ]; then
        echo "DRIVER-NEG-FAIL($name): rc=$RUN_RC (expect exactly 1)"
        driver_fail "mutation_${name}_rc=$RUN_RC"
    fi
    if printf '%s\n' "$RUN_OUT" | grep -qxF 'FUNCTIONAL_DECODE: PASS'; then
        echo "DRIVER-NEG-FAIL($name): printed PASS line"
        driver_fail "mutation_${name}_printed_pass"
    fi
    n_fl="$(count_fail_lines)"
    if [ "$n_fl" != "1" ]; then
        echo "DRIVER-NEG-FAIL($name): formal FAIL lines=$n_fl (expect 1)"
        driver_fail "mutation_${name}_fail_lines=$n_fl"
    fi
    reason="$(extract_fail_reason)"
    case "$reason" in
        "$spat"*) : ;;
        *)  echo "DRIVER-NEG-FAIL($name): reason='$reason' not prefixed by '$spat'"
            driver_fail "mutation_${name}_stdout_reason" ;;
    esac
    log="$(newest_own_log "$dir")"
    if [ -z "$log" ] || [ ! -f "$log" ] || ! grep -qE -- "$lpat" "$log"; then
        echo "DRIVER-NEG-FAIL($name): TB self-check /$lpat/ not found in own run log"
        [ -n "$log" ] && grep -nE 'CHECK_FAIL|DECODE_VECTORS' "$log" | head -5 | sed 's/^/    | /'
        driver_fail "mutation_${name}_tb_selfcheck"
    fi
    N_NEG_OK=$((N_NEG_OK + 1))
    echo "DRIVER-NEG-OK($name): rc=1 reason=$reason + TB自判/$lpat/"
}

#------------------------------------------------------------------------------
# 5. 正控（先跑 no-op TB 副本；假工具环境必须有合法正控可过）
#------------------------------------------------------------------------------
echo "DRIVER_ROOT: $DRIVER_ROOT"

d="$DRIVER_ROOT/pos-noop-tb"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
cmp -s -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv" || driver_fail "noop_tb_drift"
run_expect_pass "pos-noop-tb" "$d" bash "$d/sim/functional/test_decode.sh"

d="$DRIVER_ROOT/pos-fake-iv-real"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
make_shim "$d/fakebin" iverilog "$REAL_IV" || driver_fail "shim_iv_failed"
run_expect_pass "pos-fake-iv-real" "$d" env -u RV32_IVERILOG -u RV32_VVP PATH="$d/fakebin:$PATH" bash "$d/sim/functional/test_decode.sh"

d="$DRIVER_ROOT/pos-fake-vvp-real"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
make_shim "$d/fakebin" vvp "$REAL_VV" || driver_fail "shim_vvp_failed"
run_expect_pass "pos-fake-vvp-real" "$d" env -u RV32_IVERILOG -u RV32_VVP PATH="$d/fakebin:$PATH" bash "$d/sim/functional/test_decode.sh"

d="$DRIVER_ROOT/pos-path-sha-real"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
make_shim "$d/fakebin" sha256sum "$REAL_SHA" || driver_fail "shim_sha_failed"
run_expect_pass "pos-path-sha-real" "$d" env -u RV32_IVERILOG -u RV32_VVP PATH="$d/fakebin:$PATH" bash "$d/sim/functional/test_decode.sh"

# P5 私有 poison-cwd 正控（不改任何正式头）：
#   调用者 cwd 里放一份**冲突/非法**的 rtl/pkg 头；正确 DUT_ROOT 的编译必须不受影响。
#   先证明该 poison 头"确实有毒"（在 poison cwd 下仅以 cwd 为 include 根编译必失败），
#   避免出现"poison 无效因而控制空过"的假绿。
d="$DRIVER_ROOT/pos-poison-cwd"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
poison="$d/poison-cwd"
mkdir -p -- "$poison/rtl/pkg" || driver_fail "poison_mkdir_failed"
printf '%s\n' 'POISON_HEADER_MUST_NOT_BE_USED_BY_DUT_ROOT_COMPILE' \
    > "$poison/rtl/pkg/rv32_defs.vh" || driver_fail "poison_write_failed"
printf '%s\n' 'POISON_HEADER_MUST_NOT_BE_USED_BY_DUT_ROOT_COMPILE' \
    > "$poison/rtl/pkg/core_params.vh" || driver_fail "poison_write_failed"
( cd -- "$poison" && "$REAL_IV" -g2012 -I . -s compressed_expand \
      -o "$poison/poison_probe.vvp" "$d/rtl/decode/compressed_expand.v" ) >/dev/null 2>&1
[ "$?" -ne 0 ] || driver_fail "poison_header_not_effective"
run_expect_pass "pos-poison-cwd" "$poison" env DUT_ROOT="$d" bash "$d/sim/functional/test_decode.sh"

#------------------------------------------------------------------------------
# 6. 反证 19 例（夹具全部在本次 run 根内生成）
#------------------------------------------------------------------------------
GOOD_SUM='DECODE_VECTORS total=80 nonzero_insn=79 checks=260 fails=0'

# 1) 重复 PASS 锚点
d="$DRIVER_ROOT/dup-pass"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 181 1 "$GOOD_SUM" 2
run_expect_reject "$d" 'pass_anchor_count=2' bash "$d/sim/functional/test_decode.sh"

# 2) 缺 PASS 锚点
d="$DRIVER_ROOT/no-anchor"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 181 1 "$GOOD_SUM" 0
run_expect_reject "$d" 'pass_anchor_count=0' bash "$d/sim/functional/test_decode.sh"

# 3) 完全无捕获
d="$DRIVER_ROOT/no-capture"; build_repo "$d"
printf '%s\n' '`timescale 1ns/1ps' 'module tb_decode_semantics_top;' \
    '  initial begin $display("say nothing useful"); $finish; end' 'endmodule' \
    > "$d/sim/functional/tb_decode_semantics.sv"
run_expect_reject "$d" 'summary_count=0' bash "$d/sim/functional/test_decode.sh"

# 4) 摘要 fails≠0
d="$DRIVER_ROOT/fails-nz"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 181 1 \
    'DECODE_VECTORS total=80 nonzero_insn=79 checks=260 fails=1' 1
run_expect_reject "$d" 'summary_fails_nz=1' bash "$d/sim/functional/test_decode.sh"

# 5) 向量数少于摘要 total
d="$DRIVER_ROOT/vec-short"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 79 181 1 "$GOOD_SUM" 1
run_expect_reject "$d" 'vec_line_count=79' bash "$d/sim/functional/test_decode.sh"

# 6) 零向量自洽摘要
d="$DRIVER_ROOT/zero-vec"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 0 0 0 \
    'DECODE_VECTORS total=0 nonzero_insn=0 checks=0 fails=0' 1
run_expect_reject "$d" 'summary_total_zero' bash "$d/sim/functional/test_decode.sh"

# 7) 摘要多出坏字段
d="$DRIVER_ROOT/bad-field"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 181 1 \
    'DECODE_VECTORS total=80 nonzero_insn=79 checks=260 fails=0 extra=1' 1
run_expect_reject "$d" 'summary_format' bash "$d/sim/functional/test_decode.sh"

# 8) 运行输出出现任意 FAIL 字样
d="$DRIVER_ROOT/log-failword"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 181 1 "$GOOD_SUM" 1 \
    'NOTE something FAIL here'
run_expect_reject "$d" 'log_has_FAIL=1' bash "$d/sim/functional/test_decode.sh"

# 9) 运行输出出现 DEFECT_REPRODUCED
d="$DRIVER_ROOT/defect-repro"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 181 1 "$GOOD_SUM" 1 \
    'CASE 1 RESULT=DEFECT_REPRODUCED'
run_expect_reject "$d" 'log_has_defect_reproduced=1' bash "$d/sim/functional/test_decode.sh"

# 10) 逐向量 checks 之和与摘要不符
d="$DRIVER_ROOT/vec-checks-sum"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 80 1 1 "$GOOD_SUM" 1
run_expect_reject "$d" 'vec_checks_sum=80' bash "$d/sim/functional/test_decode.sh"

# 11) 1 向量自洽摘要冒充完整包
d="$DRIVER_ROOT/one-vector-selfconsistent"; build_repo "$d"
gen_tb "$d/sim/functional/tb_decode_semantics.sv" 1 1 1 \
    'DECODE_VECTORS total=1 nonzero_insn=1 checks=1 fails=0' 1
run_expect_reject "$d" 'summary_total=1 expect=80' bash "$d/sim/functional/test_decode.sh"

# 12) 挂死（run 超时）
d="$DRIVER_ROOT/hang"; build_repo "$d"
printf '%s\n' '`timescale 1ns/1ps' 'module tb_decode_semantics_top;' \
    '  reg clk = 1'"'"'b0;' '  always #1 clk = ~clk;' \
    '  initial $display("---- hang fixture ----");' 'endmodule' \
    > "$d/sim/functional/tb_decode_semantics.sv"
run_expect_reject "$d" 'run_timeout' env TIMEOUT_RUN_S=2 bash "$d/sim/functional/test_decode.sh"

# 13) 未知位置参数
d="$DRIVER_ROOT/unknown-arg"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
run_expect_reject "$d" 'unknown_arg' bash "$d/sim/functional/test_decode.sh" --bogus

# 14) 产物根越出授权树
d="$DRIVER_ROOT/unauthorized-out"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
run_expect_reject "$d" 'out_root_unauthorized' \
    env OUT_DIR="$DRIVER_ROOT/evil-out" bash "$d/sim/functional/test_decode.sh"

# 15) 头 SHA 失败（PATH 垫片 sha256sum 无条件 exit 1）
d="$DRIVER_ROOT/sha-fail"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
mkdir -p -- "$d/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$d/fakebin/sha256sum"
chmod +x "$d/fakebin/sha256sum"
run_expect_reject "$d" 'sha256_dut_rc=1' \
    env -u RV32_IVERILOG -u RV32_VVP PATH="$d/fakebin:$PATH" bash "$d/sim/functional/test_decode.sh"

# 16) 假 iverilog 垫片：rc=0 但零产物
d="$DRIVER_ROOT/fake-iverilog-noartifact"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
mkdir -p -- "$d/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$d/fakebin/iverilog"
chmod +x "$d/fakebin/iverilog"
run_expect_reject "$d" 'compile_no_vvp_output' \
    env -u RV32_IVERILOG -u RV32_VVP PATH="$d/fakebin:$PATH" bash "$d/sim/functional/test_decode.sh"

# 17) 假 vvp 垫片：rc=0 但无任何捕获
d="$DRIVER_ROOT/fake-vvp-empty"; build_repo "$d"
cp -f -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv"
mkdir -p -- "$d/fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$d/fakebin/vvp"
chmod +x "$d/fakebin/vvp"
run_expect_reject "$d" 'summary_count=0' \
    env -u RV32_IVERILOG -u RV32_VVP PATH="$d/fakebin:$PATH" bash "$d/sim/functional/test_decode.sh"

# 18) TB 本体变异：删一个向量整块
d="$DRIVER_ROOT/mut-del-vector"; build_repo "$d"
sed '/v_name = "ILL_ALL_ZERO";/,/v_end;/d' \
    "$REAL_TB" > "$d/sim/functional/tb_decode_semantics.sv"
cmp -s -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv" && driver_fail "mutation_del_vector_noop"
run_expect_reject_log "$d" 'run_rc=1' 'vectors=79 expect=80' \
    bash "$d/sim/functional/test_decode.sh"

# 19) TB 本体变异：删一个向量的全部 CHK
d="$DRIVER_ROOT/mut-del-checks"; build_repo "$d"
sed '/v_name = "CTL_EBREAK_32";/,/v_end;/ { /`CHK(/d }' \
    "$REAL_TB" > "$d/sim/functional/tb_decode_semantics.sv"
cmp -s -- "$REAL_TB" "$d/sim/functional/tb_decode_semantics.sv" && driver_fail "mutation_del_checks_noop"
run_expect_reject_log "$d" 'run_rc=1' 'vector has no check' \
    bash "$d/sim/functional/test_decode.sh"

#------------------------------------------------------------------------------
# 7. 汇总（锚点唯一）
#------------------------------------------------------------------------------
{
    echo "NEG_SRC: $REAL_SH"
    echo "TB_SRC:  $REAL_TB"
    echo "ENV_SRC: $REAL_ENV"
    echo "RTL_SRC: $REAL_RTL_DIR/{decoder,dec_imm,dec_csr,compressed_expand}.v"
    echo "REAL_TOOLS: iverilog=$REAL_IV vvp=$REAL_VV sha256sum=$REAL_SHA"
} | tee -a "$DRIVER_LOG" >/dev/null

echo "DRIVER_POSITIVE: $N_POS_OK/$N_POS"
echo "NEGATIVE: $N_NEG_OK/$N_NEG"
[ "$N_POS_OK" -eq "$N_POS" ] || driver_fail "positive=${N_POS_OK}/${N_POS}"
[ "$N_NEG_OK" -eq "$N_NEG" ] || driver_fail "negative=${N_NEG_OK}/${N_NEG}"
printf 'FUNCTIONAL_DECODE_DRIVER: PASS\n'
exit 0
