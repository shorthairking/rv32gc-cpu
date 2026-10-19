#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_devices.sh —— F1 设备包（CLINT/PLIC）功能入口
#   模式：默认（正向） / --check-baseline（显式反证） / --self-test（脚本判据反证）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 依据 : prompts/common.md §3（fail-closed：脚本 + 退出码 + 日志锚点）；
#        sim/functional/run.sh（总入口：rc==0 / 唯一整行锚点 / 零 FAIL /
#        零 DEFECT_REPRODUCED）；已通过审计的 sim/functional/test_decode.sh 做法。
#
# 范围 : 只编译 rtl/clint/clint.v 与 rtl/plic/plic.v（本包依赖）+ 当前包 TB
#        sim/functional/tb_devices_semantics.sv；**不**引入其它 RTL 域。
#
# 用法 :
#   bash sim/functional/test_devices.sh                 # 默认：仅正向正确行为
#   bash sim/functional/test_devices.sh --check-baseline# 显式反证：新绿 + 201acf61 旧红
#   bash sim/functional/test_devices.sh --self-test     # 只反证本脚本自身判据
#
# 输出接口（总入口契约）:
#   · 默认成功 stdout = 一行摘要 + **唯一整行** `FUNCTIONAL_DEVICES: PASS`
#     （锚点由 wrapper 显式打印；底层 TB 日志只落盘，不 cat 同锚点）；
#     成功 stdout 不含 `FAIL`、不含 `DEFECT_REPRODUCED`；`PASS` 子串恰 1 次。
#   · --check-baseline 成功 = 摘要 + `DEFECT_REPRODUCED: <标签>`，**绝不**打印整行
#     `FUNCTIONAL_DEVICES: PASS`。
#   · --self-test 成功 = `SELFTEST_OK`（不含正式锚点、不打印 `PASS`）。
#
# 产物路径（规范化 → 授权树校验 → 才 mkdir → 复校 → mktemp 独占 run 目录）:
#   · 产物根 ROOT = RV32_FUNCTIONAL_PKG_OUT_DIR（总入口传入；相对值按 REPO_ROOT 解析）
#                    > AUTH_ROOT（独立调用，= <repo>/build/functional）
#     —— 父 PKGOUT **作为 root**，每次调用在其下 `mktemp -d run-XXXXXXXX` 建独占
#        run 目录，绝不把传入目录本身当 RUN_DIR 固定覆写。
#   · ROOT 必须先 `realpath -m` 规范化并校验位于 AUTH_ROOT 之下（按 `/` 边界，
#     不用 `devices*` 前缀放行兄弟目录）；mkdir 后再规范化复校一次。
#   · 默认模式**不**创建/清理任何旧树 cache。
#
# 判定（fail-closed；任一不满足 ⇒ 非零退出、不打印正式锚点）:
#   · 参数：只接受 0 个参数或已知模式；其余即失败
#   · 工具：env.sh 可 source；iverilog/vvp/timeout/realpath/mktemp 可用；sha256sum 可执行
#   · SHA ：clint.v / plic.v / rv32_defs.vh / core_params.vh / TB 共 5 个**实际编译
#           输入**的 sha256 必须 rc=0、行数==5、每行 64 位小写 hex；任一失败即失败
#           （不用 `|| true`，失败也不回退成 `?` 仍通过）
#   · 冻结：编译前与运行后对同一组输入各算一次哈希，必须逐字节相同（源中途被改即失败）
#   · 编译：rc=0 且产出 vvp **非空**（rc=0 零/缺产物 ⇒ 硬失败；超时 ⇒ 失败）
#   · 运行：rc=0（超时 124 ⇒ 失败）
#   · 日志：存在且非空（无捕获 ⇒ 失败）
#   · 计数：`FUNCTIONAL_DEVICES_VECTORS:` **前缀行恰 1**，再严格解析为十进制且
#           **恰等于冻结规格 SPEC_VECTORS=55**（缺/多/坏字段/值错一律失败）
#   · 标记：日志 `FAIL` 行==0、`PASS` 子串==1、`DEFECT_REPRODUCED`==0
#   · 锚点：整行 `FUNCTIONAL_DEVICES: PASS` 恰 1 行
#   · TB 本体另有 SPEC_VECTORS 自判（防 Standalone 少跑），两层必须一致
#
# 反证模式（--check-baseline）: 当前源必须全过；再在**本次 run 私有目录**内
#   `git archive 201acf61`（精确提交、无 cache、不 rm 旧目录）取源复跑同一 TB，
#   要求：编译 rc=0、运行 rc!=0、官方锚点 0、向量行唯一且==55、FAIL>0、
#   8 个定向缺陷标签全部出现、`CTRL_` 控制标签 FAIL==0。
#
# 自检模式（--self-test，共 25 项）: ① 15 个日志/rc 夹具验证正向门控（缺/多锚点、
#   缺/多/坏向量、值错、含 FAIL、含 DEFECT_REPRODUCED、合法+坏向量混合、空捕获、
#   缺文件、超时、非零 rc）；② 假 IV（rc0 无产物/空产物）+ 假 VVP（打印合法锚点）
#   必须被拒且 reason=compile_rc=90；③ sha256 工具失败必须被拒且 reason=sha_rc=1；
#   ④ 编译后篡改 DUT 源（前后哈希不一致）必须被拒且 reason=freeze_rc=93；
#   ⑤ 唯一合法摘要但值 54 / 坏格式 ⇒ 精确 rc=1 且 reason=vector_value=...
#   （该诊断路径此前因 P_VECOK 未赋值在 set -u 下崩溃）；⑥ DUT_ROOT 头隔离正控：
#   私有 poison-cwd 冲突头 + 完整 DUT_ROOT ⇒ 仍通过，且所记 5 输入全来自 DUT_ROOT
#   （含绝对 TB）、不含 $REPO_ROOT/rtl 活树头；⑦ 同一父 root 顺序/并发两次 ⇒
#   run 目录互异、日志独立。
#
# 纪律 : 不改 sim/audit 冻结 defect runner；不改他人 source；不 run 全树/总入口/综合。
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数
#------------------------------------------------------------------------------
MODE="default"
if [ "$#" -ge 1 ]; then
    case "$1" in
        --default|default)               MODE="default" ;;
        --check-baseline|check-baseline) MODE="baseline" ;;
        --self-test|self-test)           MODE="selftest" ;;
        -h|--help|help)
            printf '用法: %s [--check-baseline|--self-test|--help]\n' "$0"; exit 0 ;;
        *) printf 'FUNCTIONAL_DEVICES: FAIL reason=unknown_arg argv=%s\n' "$1"; exit 1 ;;
    esac
fi
if [ "$#" -gt 1 ]; then
    printf 'FUNCTIONAL_DEVICES: FAIL reason=too_many_args argv=%s\n' "$*"; exit 1
fi

#------------------------------------------------------------------------------
# 1. 路径与工具真源
#------------------------------------------------------------------------------
SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || { printf 'FUNCTIONAL_DEVICES: FAIL reason=self_dir\n'; exit 1; }
# 绝对化：子自检会在其他 cwd（如 poison-cwd）内 `bash "$SELF_PATH"`，相对路径会 127
SELF_PATH="$SELF_DIR/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)"                          || { printf 'FUNCTIONAL_DEVICES: FAIL reason=repo_root\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_devices_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

# 本包冻结规格（与 tb_devices_semantics.sv 的 SPEC_VECTORS 同步；改 TB 必须同步改这里）
readonly SPEC_VECTORS=55
readonly SPEC_DEFECT_TAGS="MTIP_EQ PLIC_CLAIM_THRESH PLIC_RETRACT PLIC_REEDGE PLIC_COMP_EN PLIC_CLAIM_STROBE PLIC_STROBE CLINT_STROBE"

# 摘要占位（失败路径也打印摘要行，便于日志锚定）
SUM_CHECKS="-"; SUM_MISMATCH="-"; SUM_DEFECT="-"
emit_summary_fn() {
    printf 'DEVICES_VECTORS checks=%s mismatches=%s defect_markers=%s\n' \
           "$SUM_CHECKS" "$SUM_MISMATCH" "$SUM_DEFECT"
}
early_fail() {   # <reason>
    emit_summary_fn
    printf 'FUNCTIONAL_DEVICES: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    exit 1
}

[ -r "$ENV_SH" ] || early_fail "env_sh_missing"
# shellcheck disable=SC1090
. "$ENV_SH" >/dev/null 2>&1
ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || early_fail "env_sh_source_rc=$ENV_RC"

IV="${RV32_IVERILOG:-}"
VVP="${RV32_VVP:-}"
SHA_TOOL="${RV32_SHA256SUM:-sha256sum}"
TIMEOUT_COMPILE_S="${CASE_COMPILE_TIMEOUT:-300}"
TIMEOUT_RUN_S="${CASE_RUN_TIMEOUT:-300}"

[ -r "$TB_SRC" ] || early_fail "tb_missing tb=$TB_SRC"

need_tools() {
    [ -n "$IV" ]  && [ -x "$IV" ]  || early_fail "tool_missing name=RV32_IVERILOG value=${IV:-unset}"
    [ -n "$VVP" ] && [ -x "$VVP" ] || early_fail "tool_missing name=RV32_VVP value=${VVP:-unset}"
    command -v timeout  >/dev/null 2>&1 || early_fail "tool_missing name=timeout"
    command -v realpath >/dev/null 2>&1 || early_fail "tool_missing name=realpath"
    command -v mktemp   >/dev/null 2>&1 || early_fail "tool_missing name=mktemp"
    command -v "$SHA_TOOL" >/dev/null 2>&1 || [ -x "$SHA_TOOL" ] || early_fail "tool_missing name=sha256sum value=$SHA_TOOL"
}

#------------------------------------------------------------------------------
# 2. 产物根：规范化 → 授权树校验 → mkdir → 复校 → mktemp 独占 run 目录
#------------------------------------------------------------------------------
AUTH_ROOT="$(realpath -m -- "$REPO_ROOT/build/functional" 2>/dev/null)" || AUTH_ROOT="$REPO_ROOT/build/functional"
is_authorized() {
    case "$1" in
        "$AUTH_ROOT" | "$AUTH_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

RUN_DIR=""; ROOT_NORM=""
resolve_run_dir() {
    local raw="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT}" cand root
    case "$raw" in
        /*) cand="$raw" ;;
        *)  cand="$REPO_ROOT/$raw" ;;
    esac
    root="$(realpath -m -- "$cand" 2>/dev/null)" || early_fail "root_realpath raw=$raw"
    is_authorized "$root" || early_fail "root_unauthorized root=$root auth=$AUTH_ROOT"
    mkdir -p -- "$root" || early_fail "root_mkdir root=$root"
    root="$(realpath -m -- "$root" 2>/dev/null)" || early_fail "root_rerealpath"
    is_authorized "$root" || early_fail "root_unauthorized_after_mkdir root=$root"
    RUN_DIR="$(mktemp -d -- "$root/run-XXXXXXXX")" || early_fail "run_dir_mktemp root=$root"
    ROOT_NORM="$root"
}

#------------------------------------------------------------------------------
# 3. 编译输入哈希（5 个实际输入；严格：rc0 + 行数 + 64hex）与冻结校验
#------------------------------------------------------------------------------
input_files() {   # <dut_root>
    printf '%s\n' \
        "$1/rtl/clint/clint.v" \
        "$1/rtl/plic/plic.v" \
        "$1/rtl/pkg/rv32_defs.vh" \
        "$1/rtl/pkg/core_params.vh" \
        "$TB_SRC"
}

hash_inputs() {   # <dut_root> <outfile> ; rc: 0 ok / 1 sha rc / 2 行数 / 3 缺文件 / 4 格式
    local root="$1" out="$2" f
    local files=()
    while IFS= read -r f; do files+=( "$f" ); done < <(input_files "$root")
    for f in "${files[@]}"; do [ -f "$f" ] || return 3; done
    "$SHA_TOOL" -- "${files[@]}" > "$out" 2>>"${CASE_CLOG:-/dev/null}"
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    local n
    n="$(wc -l < "$out")" || return 2
    [ "$n" -eq "${#files[@]}" ] || return 2
    awk -v want="${#files[@]}" '
        { lines++; if (length($1) == 64 && $1 ~ /^[0-9a-f]+$/) ok++ }
        END { exit !(ok == want && lines == want) }
    ' "$out" || return 4
    return 0
}

#------------------------------------------------------------------------------
# 4. 编译 + 运行一个源根（含 vvp 非空、哈希前后冻结）
#------------------------------------------------------------------------------
case_compile_run() {   # <name> <dut_root>
    local name="$1" root="$2"
    CASE_DIR="${RUN_DIR}/${name}"
    mkdir -p -- "$CASE_DIR" || { CASE_COMPILE_RC=80; return 0; }
    CASE_CLOG="${CASE_DIR}/compile.log"
    CASE_RLOG="${CASE_DIR}/run.log"
    CASE_VVP="${CASE_DIR}/${name}.vvp"
    CASE_HASH_BEFORE="${CASE_DIR}/inputs.before.sha256"
    CASE_HASH_AFTER="${CASE_DIR}/inputs.after.sha256"
    : > "$CASE_CLOG" || { CASE_COMPILE_RC=80; return 0; }
    CASE_HASH_RC=0; CASE_FREEZE_RC=0; CASE_COMPILE_RC=0; CASE_RUN_RC=254

    hash_inputs "$root" "$CASE_HASH_BEFORE"; CASE_HASH_RC=$?
    [ "$CASE_HASH_RC" -eq 0 ] || { CASE_COMPILE_RC=81; return 0; }

    # ★ DUT_ROOT 头隔离（小 diff，不动其它逻辑）：编译在**源 root 的 cwd 子 shell** 内进行，
    #   只给 `-I . -I rtl/pkg`（= 该 root 自己的头），**移除 $REPO_ROOT 活树 fallback**，
    #   TB 走绝对路径 ⇒ 所记 5 个输入就是实际编译所用；DUT_ROOT 缺头不会静默借活树头。
    (
        cd -- "$root" || exit 91
        timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 \
            -I . -I rtl/pkg \
            -o "$CASE_VVP" -s tb_devices_semantics \
            rtl/clint/clint.v rtl/plic/plic.v "$TB_SRC"
    ) >"$CASE_CLOG" 2>&1
    CASE_COMPILE_RC=$?
    # ★ 编译 rc=0 但无/空 vvp 产物 ⇒ 硬失败（假 IV 不能靠"合法打印"蒙混）
    if [ "$CASE_COMPILE_RC" -eq 0 ] && [ ! -s "$CASE_VVP" ]; then
        CASE_COMPILE_RC=90
        printf 'compile artifact missing/empty: %s\n' "$CASE_VVP" >> "$CASE_CLOG"
    fi
    [ "$CASE_COMPILE_RC" -eq 0 ] || return 0

    CASE_RUN_RC=0
    timeout "$TIMEOUT_RUN_S" "$VVP" "$CASE_VVP" >"$CASE_RLOG" 2>&1
    CASE_RUN_RC=$?

    hash_inputs "$root" "$CASE_HASH_AFTER"; CASE_HASH_AFTER_RC=$?
    if [ "$CASE_HASH_AFTER_RC" -ne 0 ]; then CASE_FREEZE_RC=92; return 0; fi
    cmp -s "$CASE_HASH_BEFORE" "$CASE_HASH_AFTER" || CASE_FREEZE_RC=93
    return 0
}

#------------------------------------------------------------------------------
# 5. 正向门控：读 <log> + rc ⇒ G_*（G_ERR==0 通过）
#------------------------------------------------------------------------------
gate_positive_log() {
    local log="$1" rc="$2"
    G_CAPTURE=0; G_ANCHOR=0; G_VECPREFIX=0; G_VECVALUE=""; G_VECOK=0
    G_FAILLINES=0; G_PASSOCC=0; G_DEFECT=0; G_ERR=0
    [ -s "$log" ] && G_CAPTURE=1
    G_ANCHOR="$(grep -cxF 'FUNCTIONAL_DEVICES: PASS' "$log" 2>/dev/null)"; G_ANCHOR="${G_ANCHOR:-0}"
    # ★ 先计"全部 FUNCTIONAL_DEVICES_VECTORS: 前缀"行数，必须恰 1；再严格解析值
    G_VECPREFIX="$(grep -c '^FUNCTIONAL_DEVICES_VECTORS:' "$log" 2>/dev/null)"; G_VECPREFIX="${G_VECPREFIX:-0}"
    if [ "$G_VECPREFIX" -eq 1 ]; then
        local line
        line="$(grep -m1 '^FUNCTIONAL_DEVICES_VECTORS:' "$log" 2>/dev/null)"
        if printf '%s' "$line" | grep -qE '^FUNCTIONAL_DEVICES_VECTORS: [0-9]+$'; then
            G_VECVALUE="${line#FUNCTIONAL_DEVICES_VECTORS: }"
            [ "$G_VECVALUE" = "$SPEC_VECTORS" ] && G_VECOK=1
        fi
    fi
    G_FAILLINES="$(grep -c 'FAIL' "$log" 2>/dev/null)"; G_FAILLINES="${G_FAILLINES:-0}"
    G_PASSOCC="$( { grep -o 'PASS' "$log" 2>/dev/null; } | wc -l )"; G_PASSOCC="${G_PASSOCC:-0}"
    G_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$log" 2>/dev/null)"; G_DEFECT="${G_DEFECT:-0}"

    [ "$G_CAPTURE"   -eq 1 ] || G_ERR=1
    [ "$rc"          -eq 0 ] || G_ERR=1
    [ "$G_ANCHOR"    -eq 1 ] || G_ERR=1
    [ "$G_VECPREFIX" -eq 1 ] || G_ERR=1
    [ "$G_VECOK"     -eq 1 ] || G_ERR=1
    [ "$G_FAILLINES" -eq 0 ] || G_ERR=1
    [ "$G_PASSOCC"   -eq 1 ] || G_ERR=1
    [ "$G_DEFECT"    -eq 0 ] || G_ERR=1
    return "$G_ERR"
}

run_positive_case() {   # 正向跑当前源根；结果写入 P_*；返回 0=通过
    case_compile_run current "$DUT_ROOT"
    P_COMPILE_RC="$CASE_COMPILE_RC"; P_RUN_RC="$CASE_RUN_RC"
    P_HASH_RC="$CASE_HASH_RC"; P_FREEZE_RC="$CASE_FREEZE_RC"
    P_DIR="$CASE_DIR"; P_CLOG="$CASE_CLOG"; P_LOG="$CASE_RLOG"
    P_HASH="$CASE_HASH_BEFORE"; P_VVP="$CASE_VVP"
    local eff_rc="$P_RUN_RC"
    [ "$P_COMPILE_RC" -eq 0 ] || eff_rc=254
    [ "$P_HASH_RC" -eq 0 ] || eff_rc=254
    [ "$P_FREEZE_RC" -eq 0 ] || eff_rc=254
    gate_positive_log "$P_LOG" "$eff_rc"
    P_VECOK="$G_VECOK"
    P_ANCHOR="$G_ANCHOR"; P_VECPREFIX="$G_VECPREFIX"; P_VECVALUE="$G_VECVALUE"
    P_FAILLINES="$G_FAILLINES"; P_PASSOCC="$G_PASSOCC"; P_DEFECT="$G_DEFECT"
    [ "$P_COMPILE_RC" -eq 0 ] || return 1
    [ "$P_HASH_RC" -eq 0 ] || return 1
    [ "$P_FREEZE_RC" -eq 0 ] || return 1
    return "$G_ERR"
}

#==============================================================================
# 6. 默认：仅正向正确行为
#==============================================================================
default_main() {
    need_tools
    resolve_run_dir
    DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
    DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || early_fail "dut_root_unresolved dut=${DUT_ROOT:-unset}"

    local ok=0
    if run_positive_case; then ok=1; fi

    SUM_CHECKS="${P_VECVALUE:-0}"
    SUM_MISMATCH="${P_FAILLINES:-0}"
    SUM_DEFECT="${P_DEFECT:-0}"
    emit_summary_fn

    if [ "$ok" -eq 1 ]; then
        printf 'FUNCTIONAL_DEVICES: PASS\n'
        exit 0
    fi

    local why="gate"
    # ★ 诊断顺序：哈希/冻结失败优先于"编译 rc"（编译侧对哈希失败置 81 哨兵），
    #   使 reason 指向真实失败原因，而不是被哨兵吞掉。
    if   [ "$P_HASH_RC" -ne 0 ];    then why="sha_rc=$P_HASH_RC"
    elif [ "$P_FREEZE_RC" -ne 0 ];  then why="freeze_rc=$P_FREEZE_RC"
    elif [ "$P_COMPILE_RC" -ne 0 ]; then why="compile_rc=$P_COMPILE_RC"
    elif [ "$P_RUN_RC" -ne 0 ];     then why="run_rc=$P_RUN_RC"
    elif [ "$P_ANCHOR" -ne 1 ];     then why="anchor_lines=$P_ANCHOR"
    elif [ "$P_VECPREFIX" -ne 1 ];  then why="vector_prefix_lines=$P_VECPREFIX"
    elif [ "$P_VECOK" != "1" ];     then why="vector_value=${P_VECVALUE:-<none>} expect=$SPEC_VECTORS"
    elif [ "$P_FAILLINES" -ne 0 ];  then why="fail_lines=$P_FAILLINES"
    elif [ "$P_DEFECT" -ne 0 ];     then why="defect_markers=$P_DEFECT"
    fi
    printf 'FUNCTIONAL_DEVICES: FAIL reason=%s run_dir=%s\n' "$why" "${RUN_DIR:-<none>}"
    exit 1
}

#==============================================================================
# 7. --check-baseline：新绿 + 201acf61 旧红（成功不输出正式锚点）
#==============================================================================
baseline_main() {
    need_tools
    command -v git >/dev/null 2>&1 || early_fail "tool_missing name=git"
    command -v tar >/dev/null 2>&1 || early_fail "tool_missing name=tar"
    resolve_run_dir
    DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
    DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || early_fail "dut_root_unresolved dut=${DUT_ROOT:-unset}"

    local cur_ok=0
    if run_positive_case; then cur_ok=1; fi

    local full
    full="$(git -C "$REPO_ROOT" rev-parse "201acf61^{commit}" 2>/dev/null)" || early_fail "baseline_commit_missing"
    [ "$full" = "201acf61e118a3fb533e1a96768687a35efa1751" ] || early_fail "baseline_commit_mismatch got=$full"

    local priv
    priv="$(mktemp -d -- "$RUN_DIR/baseline-src.XXXXXXXX")" || early_fail "baseline_priv_mktemp"
    git -C "$REPO_ROOT" archive "$full" rtl | tar -x -C "$priv" || early_fail "baseline_archive_failed"

    case_compile_run baseline "$priv"
    local b_log="$CASE_RLOG" b_clog="$CASE_CLOG"
    gate_positive_log "$b_log" "$CASE_RUN_RC" || true
    local b_err=0
    [ "$CASE_COMPILE_RC" -eq 0 ] || b_err=1
    [ "$CASE_HASH_RC"    -eq 0 ] || b_err=1
    [ "$CASE_FREEZE_RC"  -eq 0 ] || b_err=1
    [ "$CASE_RUN_RC"     -ne 0 ] || b_err=1
    [ "$G_ANCHOR"    -eq 0 ] || b_err=1
    [ "$G_VECPREFIX" -eq 1 ] || b_err=1
    [ "$G_VECVALUE" = "$SPEC_VECTORS" ] || b_err=1
    [ "$G_FAILLINES" -gt 0 ] || b_err=1
    local tag missing=""
    for tag in $SPEC_DEFECT_TAGS; do
        grep -qF "DEVICES FAIL [${tag}]" "$b_log" 2>/dev/null || missing="$missing $tag"
    done
    [ -z "$missing" ] || b_err=1
    local ctrl
    ctrl="$(grep -c 'DEVICES FAIL \[CTRL_' "$b_log" 2>/dev/null)"; ctrl="${ctrl:-0}"
    [ "$ctrl" -eq 0 ] || b_err=1

    printf 'DEVICES_VECTORS checks=%s mismatches=%s defect_markers=%s\n' \
           "${G_VECVALUE:-0}" "$G_FAILLINES" "$G_DEFECT"
    printf 'devices(baseline): current_ok=%s baseline_compile_rc=%s baseline_run_rc=%s ctrl_err_lines=%s\n' \
           "$cur_ok" "$CASE_COMPILE_RC" "$CASE_RUN_RC" "$ctrl" >&2
    [ -z "$missing" ] || printf 'devices(baseline): missing_defect_tags:%s\n' "$missing" >&2

    if [ "$cur_ok" -eq 1 ] && [ "$b_err" -eq 0 ]; then
        printf 'DEFECT_REPRODUCED: %s\n' "$SPEC_DEFECT_TAGS"
        exit 0
    fi
    printf 'FUNCTIONAL_DEVICES: FAIL reason=baseline_repro current_ok=%s baseline_err=%s run_dir=%s\n' \
           "$cur_ok" "$b_err" "${RUN_DIR:-<none>}"
    exit 1
}

#==============================================================================
# 8. --self-test：只反证本脚本判据
#==============================================================================
selftest_main() {
    need_tools
    local st_dir
    st_dir="$(mktemp -d -- "$AUTH_ROOT/devices-selftest.XXXXXXXX")" || { printf 'SELFTEST_BAD: mktemp\n'; exit 1; }
    local pass=0 total=0

    fixture() { printf '%s\n' "$2" > "$st_dir/$1"; }
    gate_case() {   # <名称> <期望 pass|reject> <日志> <rc>
        local name="$1" expect="$2" log="$3" rc="$4" got
        total=$((total + 1))
        if gate_positive_log "$log" "$rc"; then got=pass; else got=reject; fi
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-26s expect=%-6s got=%-6s OK\n' "$name" "$expect" "$got"
        else
            printf 'SELFTEST %-26s expect=%-6s got=%-6s MISMATCH\n' "$name" "$expect" "$got"
        fi
    }

    # ---- 8.1 日志门控夹具 ----
    fixture good.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
FUNCTIONAL_DEVICES: PASS"
    fixture missing_anchor.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS"
    fixture extra_anchor.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
FUNCTIONAL_DEVICES: PASS
FUNCTIONAL_DEVICES: PASS"
    fixture missing_vectors.log "FUNCTIONAL_DEVICES: PASS"
    fixture dup_vectors.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
FUNCTIONAL_DEVICES: PASS"
    fixture legal_plus_badvec.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
FUNCTIONAL_DEVICES_VECTORS: nope
FUNCTIONAL_DEVICES: PASS"
    fixture bad_vector_only.log "FUNCTIONAL_DEVICES_VECTORS: nope
FUNCTIONAL_DEVICES: PASS"
    fixture wrong_vectors.log "FUNCTIONAL_DEVICES_VECTORS: 54
FUNCTIONAL_DEVICES: PASS"
    fixture has_fail.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
DEVICES FAIL [MTIP_EQ]: x
FUNCTIONAL_DEVICES: PASS"
    fixture has_defect.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
DEFECT_REPRODUCED: x
FUNCTIONAL_DEVICES: PASS"
    fixture defect_plus_badvec.log "FUNCTIONAL_DEVICES_VECTORS: $SPEC_VECTORS
FUNCTIONAL_DEVICES_VECTORS: nope
DEFECT_REPRODUCED: x
FUNCTIONAL_DEVICES: PASS"
    : > "$st_dir/empty.log"

    gate_case good                  pass   "$st_dir/good.log"                0
    gate_case missing_anchor        reject "$st_dir/missing_anchor.log"      0
    gate_case extra_anchor          reject "$st_dir/extra_anchor.log"        0
    gate_case missing_vectors       reject "$st_dir/missing_vectors.log"     0
    gate_case dup_vectors           reject "$st_dir/dup_vectors.log"         0
    gate_case legal_plus_badvec     reject "$st_dir/legal_plus_badvec.log"   0
    gate_case bad_vector_only       reject "$st_dir/bad_vector_only.log"     0
    gate_case wrong_vectors         reject "$st_dir/wrong_vectors.log"       0
    gate_case has_fail              reject "$st_dir/has_fail.log"            0
    gate_case has_defect            reject "$st_dir/has_defect.log"          0
    gate_case defect_plus_badvec    reject "$st_dir/defect_plus_badvec.log"  0
    gate_case empty_capture         reject "$st_dir/empty.log"               0
    gate_case missing_file          reject "$st_dir/does_not_exist.log"      0
    gate_case timeout_rc            reject "$st_dir/good.log"                124
    gate_case nonzero_rc            reject "$st_dir/good.log"                1

    # ---- 8.2 假工具反证：rc0 但无/空 vvp + 假 VVP 打印合法锚点 ----
    local stub_iv_noout="$st_dir/stub_iv_noout.sh"
    local stub_iv_empty="$st_dir/stub_iv_empty.sh"
    local stub_vvp="$st_dir/stub_vvp.sh"
    local stub_sha_fail="$st_dir/stub_sha_fail.sh"
    local stub_iv_create="$st_dir/stub_iv_create.sh"
    local stub_vvp_54="$st_dir/stub_vvp_54.sh"
    local stub_vvp_badvec="$st_dir/stub_vvp_badvec.sh"
    cat > "$stub_iv_noout" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
    cat > "$stub_iv_empty" <<'EOS'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && : > "$out"
exit 0
EOS
    cat > "$stub_vvp" <<'EOS'
#!/usr/bin/env bash
printf 'FUNCTIONAL_DEVICES_VECTORS: 55\nFUNCTIONAL_DEVICES: PASS\n'
exit 0
EOS
    cat > "$stub_sha_fail" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
    # 造"非空 vvp"的假 IV（让编译通过，专测运行/摘要门控）；以及坏摘要假 VVP
    cat > "$stub_iv_create" <<'EOS'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && printf 'fake-vvp\n' > "$out"
exit 0
EOS
    cat > "$stub_vvp_54" <<'EOS'
#!/usr/bin/env bash
printf 'FUNCTIONAL_DEVICES_VECTORS: 54\nFUNCTIONAL_DEVICES: PASS\n'
exit 0
EOS
    cat > "$stub_vvp_badvec" <<'EOS'
#!/usr/bin/env bash
printf 'FUNCTIONAL_DEVICES_VECTORS: nope\nFUNCTIONAL_DEVICES: PASS\n'
exit 0
EOS
    chmod +x "$stub_iv_noout" "$stub_iv_empty" "$stub_vvp" "$stub_sha_fail" \
             "$stub_iv_create" "$stub_vvp_54" "$stub_vvp_badvec"

    local fakero="$st_dir/fakeroot"
    mkdir -p -- "$fakero"

    sub_case() {   # <名称> <期望 pass|reject> <rc文件> <out文件> <必备原因子串|->
        local name="$1" expect="$2" rcfile="$3" outfile="$4" want="$5"
        local rc ok=0 detail=""
        total=$((total + 1))
        rc="$(cat "$rcfile" 2>/dev/null || printf '?')"
        if [ "$expect" = "pass" ]; then
            if [ "$rc" = "0" ]; then ok=1; else detail="rc=$rc(expect 0)"; fi
        else
            # ★ 精确 rc=1 + 规范 reason 子串，二者缺一不算命中（不能只判"非零"）
            if [ "$rc" != "1" ]; then
                detail="rc=$rc(expect 1)"
            elif [ "$want" != "-" ] && ! grep -qF -- "$want" "$outfile" 2>/dev/null; then
                detail="missing_reason[$want]"
            else
                ok=1
            fi
        fi
        if [ "$ok" -eq 1 ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-26s expect=%-6s got=%-6s OK\n' "$name" "$expect" "$expect"
        else
            printf 'SELFTEST %-26s expect=%-6s got=%-6s MISMATCH (%s)\n' "$name" "$expect" "-" "$detail"
        fi
    }

    local rcfile outfile
    rcfile="$st_dir/rc_noout"; outfile="$st_dir/out_noout"
    RV32_IVERILOG="$stub_iv_noout" RV32_VVP="$stub_vvp" RV32_SHA256SUM="$SHA_TOOL" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$fakero" \
        timeout 300 bash "$SELF_PATH" >"$outfile" 2>&1; printf '%s' "$?" > "$rcfile"
    sub_case fake_iv_no_vvp reject "$rcfile" "$outfile" 'FUNCTIONAL_DEVICES: FAIL reason=compile_rc=90'
    if grep -qxF 'FUNCTIONAL_DEVICES: PASS' "$outfile"; then
        printf 'SELFTEST fake_iv_no_vvp: leaked official anchor\n'; pass=$((pass - 1))
    fi

    rcfile="$st_dir/rc_empty"; outfile="$st_dir/out_empty"
    RV32_IVERILOG="$stub_iv_empty" RV32_VVP="$stub_vvp" RV32_SHA256SUM="$SHA_TOOL" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$fakero" \
        timeout 300 bash "$SELF_PATH" >"$outfile" 2>&1; printf '%s' "$?" > "$rcfile"
    sub_case fake_iv_empty_vvp reject "$rcfile" "$outfile" 'FUNCTIONAL_DEVICES: FAIL reason=compile_rc=90'
    if grep -qxF 'FUNCTIONAL_DEVICES: PASS' "$outfile"; then
        printf 'SELFTEST fake_iv_empty_vvp: leaked official anchor\n'; pass=$((pass - 1))
    fi

    rcfile="$st_dir/rc_sha"; outfile="$st_dir/out_sha"
    RV32_IVERILOG="$IV" RV32_VVP="$VVP" RV32_SHA256SUM="$stub_sha_fail" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$fakero" \
        timeout 300 bash "$SELF_PATH" >"$outfile" 2>&1; printf '%s' "$?" > "$rcfile"
    sub_case sha_tool_failure reject "$rcfile" "$outfile" 'FUNCTIONAL_DEVICES: FAIL reason=sha_rc=1'

    # ---- 8.2a 摘要诊断路径反证（P2）：唯一合法摘要但值 54 / 坏格式 ----
    #     必须精确 rc=1 且给出规范 reason=vector_value=...（不是 set -u 崩溃或别的准备错误）
    rcfile="$st_dir/rc_v54"; outfile="$st_dir/out_v54"
    RV32_IVERILOG="$stub_iv_create" RV32_VVP="$stub_vvp_54" RV32_SHA256SUM="$SHA_TOOL" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$fakero" \
        timeout 300 bash "$SELF_PATH" >"$outfile" 2>&1; printf '%s' "$?" > "$rcfile"
    sub_case vector_value_54 reject "$rcfile" "$outfile" \
        'FUNCTIONAL_DEVICES: FAIL reason=vector_value=54 expect=55'

    rcfile="$st_dir/rc_vbad"; outfile="$st_dir/out_vbad"
    RV32_IVERILOG="$stub_iv_create" RV32_VVP="$stub_vvp_badvec" RV32_SHA256SUM="$SHA_TOOL" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$fakero" \
        timeout 300 bash "$SELF_PATH" >"$outfile" 2>&1; printf '%s' "$?" > "$rcfile"
    sub_case vector_bad_format reject "$rcfile" "$outfile" \
        'FUNCTIONAL_DEVICES: FAIL reason=vector_value=<none> expect=55'
    for f in "$st_dir/out_v54" "$st_dir/out_vbad"; do
        if grep -qxF 'FUNCTIONAL_DEVICES: PASS' "$f"; then
            printf 'SELFTEST %s: leaked official anchor\n' "$f"; pass=$((pass - 1))
        fi
    done

    # ---- 8.2b 源冻结反证：编译后篡改 DUT 源 ⇒ 前后哈希不一致，必须被拒 ----
    local droot="$st_dir/dutroot"
    mkdir -p -- "$droot/rtl"
    cp -a -- "$REPO_ROOT/rtl/clint" "$REPO_ROOT/rtl/plic" "$REPO_ROOT/rtl/pkg" "$droot/rtl/" 2>/dev/null \
        || printf 'SELFTEST freeze_tamper: copy failed\n'
    local stub_iv_tamper="$st_dir/stub_iv_tamper.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '"%s" "$@"\n' "$IV"
        printf 'rc=$?\n'
        printf 'printf "\\n// freeze-tamper\\n" >> "%s/rtl/clint/clint.v"\n' "$droot"
        printf 'exit $rc\n'
    } > "$stub_iv_tamper"
    chmod +x "$stub_iv_tamper"
    rcfile="$st_dir/rc_freeze"; outfile="$st_dir/out_freeze"
    RV32_IVERILOG="$stub_iv_tamper" RV32_VVP="$VVP" RV32_SHA256SUM="$SHA_TOOL" \
        DUT_ROOT="$droot" RV32_FUNCTIONAL_PKG_OUT_DIR="$fakero" \
        timeout 300 bash "$SELF_PATH" >"$outfile" 2>&1; printf '%s' "$?" > "$rcfile"
    sub_case freeze_tamper reject "$rcfile" "$outfile" 'FUNCTIONAL_DEVICES: FAIL reason=freeze_rc=93'

    # ---- 8.2c DUT_ROOT 头隔离正控：私有 poison-cwd 冲突头 + 完整 DUT_ROOT ⇒ 仍通过 ----
    #     调用方 cwd 放一份"垃圾 rtl/pkg/*.vh"；DUT_ROOT 自带完整头。编译必须在源 root 的
    #     cwd 内只用该 root 的头 ⇒ poison 不会被采用，且所记 5 输入全来自 DUT_ROOT(+绝对 TB)。
    local droot_ok="$st_dir/dutroot_ok" poisoncwd="$st_dir/poison_cwd"
    mkdir -p -- "$droot_ok/rtl" "$poisoncwd/rtl/pkg"
    cp -a -- "$REPO_ROOT/rtl/clint" "$REPO_ROOT/rtl/plic" "$REPO_ROOT/rtl/pkg" "$droot_ok/rtl/" 2>/dev/null \
        || printf 'SELFTEST dutroot_poison_cwd: copy failed\n'
    printf 'this is not verilog !! poison-cwd header\n' > "$poisoncwd/rtl/pkg/rv32_defs.vh"
    printf 'this is not verilog !! poison-cwd header\n' > "$poisoncwd/rtl/pkg/core_params.vh"
    printf 'this is not verilog !! poison-cwd bare header\n' > "$poisoncwd/rv32_defs.vh"
    local poisonroot="$st_dir/poison_root"; mkdir -p -- "$poisonroot"
    rcfile="$st_dir/rc_poison"; outfile="$st_dir/out_poison"
    ( cd -- "$poisoncwd" && \
      RV32_IVERILOG="$IV" RV32_VVP="$VVP" RV32_SHA256SUM="$SHA_TOOL" \
      DUT_ROOT="$droot_ok" RV32_FUNCTIONAL_PKG_OUT_DIR="$poisonroot" \
      timeout 600 bash "$SELF_PATH" ) >"$outfile" 2>&1
    printf '%s' "$?" > "$rcfile"
    sub_case dutroot_poison_cwd pass "$rcfile" "$outfile" "-"

    # 所记 5 输入必须全来自 DUT_ROOT（2 RTL + 2 头）与绝对 TB，绝不含 $REPO_ROOT/rtl 活树头
    local phash
    phash="$(find "$poisonroot" -name 'inputs.before.sha256' 2>/dev/null | head -n1)"
    total=$((total + 1))
    if [ -n "$phash" ] \
       && [ "$(grep -c -- "$droot_ok/rtl/" "$phash")" -eq 4 ] \
       && [ "$(grep -c -- "$REPO_ROOT/rtl/" "$phash")" -eq 0 ] \
       && [ "$(grep -c -- "$TB_SRC" "$phash")" -eq 1 ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expect=%-6s got=%-6s OK\n' poison_inputs_are_dut pass pass
    else
        printf 'SELFTEST %-26s expect=%-6s got=%-6s MISMATCH (hash=%s)\n' \
               poison_inputs_are_dut pass reject "${phash:-none}"
    fi

    # ---- 8.3 同一父 root 顺序/并发 ⇒ run 目录互异、日志独立 ----
    local proot="$st_dir/parentroot"
    mkdir -p -- "$proot"
    local o1="$st_dir/seq1.out" o2="$st_dir/seq2.out" r1 r2 n_seq
    RV32_IVERILOG="$IV" RV32_VVP="$VVP" RV32_SHA256SUM="$SHA_TOOL" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$proot" timeout 600 bash "$SELF_PATH" >"$o1" 2>&1
    r1=$?
    RV32_IVERILOG="$IV" RV32_VVP="$VVP" RV32_SHA256SUM="$SHA_TOOL" \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$proot" timeout 600 bash "$SELF_PATH" >"$o2" 2>&1
    r2=$?
    total=$((total + 1))
    n_seq="$(find "$proot" -maxdepth 1 -mindepth 1 -type d -name 'run-*' | wc -l)"
    if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$n_seq" -eq 2 ] \
       && [ "$(grep -cxF 'FUNCTIONAL_DEVICES: PASS' "$o1")" -eq 1 ] \
       && [ "$(grep -cxF 'FUNCTIONAL_DEVICES: PASS' "$o2")" -eq 1 ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expect=%-6s got=%-6s OK\n' same_root_sequential pass pass
    else
        printf 'SELFTEST %-26s expect=%-6s got=%-6s MISMATCH (rc=%s/%s dirs=%s)\n' \
               same_root_sequential pass reject "$r1" "$r2" "$n_seq"
    fi

    local c1="$st_dir/conc1.out" c2="$st_dir/conc2.out" pid1 pid2 n_all
    ( RV32_IVERILOG="$IV" RV32_VVP="$VVP" RV32_SHA256SUM="$SHA_TOOL" \
      RV32_FUNCTIONAL_PKG_OUT_DIR="$proot" timeout 600 bash "$SELF_PATH" >"$c1" 2>&1
      printf '%s' "$?" > "$st_dir/rc_c1" ) &
    pid1=$!
    ( RV32_IVERILOG="$IV" RV32_VVP="$VVP" RV32_SHA256SUM="$SHA_TOOL" \
      RV32_FUNCTIONAL_PKG_OUT_DIR="$proot" timeout 600 bash "$SELF_PATH" >"$c2" 2>&1
      printf '%s' "$?" > "$st_dir/rc_c2" ) &
    pid2=$!
    wait "$pid1"; wait "$pid2"
    total=$((total + 1))
    n_all="$(find "$proot" -maxdepth 1 -mindepth 1 -type d -name 'run-*' | wc -l)"
    if [ "$(cat "$st_dir/rc_c1" 2>/dev/null)" = "0" ] && [ "$(cat "$st_dir/rc_c2" 2>/dev/null)" = "0" ] \
       && [ "$n_all" -eq 4 ] \
       && [ "$(grep -cxF 'FUNCTIONAL_DEVICES: PASS' "$c1")" -eq 1 ] \
       && [ "$(grep -cxF 'FUNCTIONAL_DEVICES: PASS' "$c2")" -eq 1 ]; then
        pass=$((pass + 1)); printf 'SELFTEST %-26s expect=%-6s got=%-6s OK\n' same_root_concurrent pass pass
    else
        printf 'SELFTEST %-26s expect=%-6s got=%-6s MISMATCH (dirs=%s)\n' \
               same_root_concurrent pass reject "$n_all"
    fi

    printf 'SELFTEST_FIXTURES: %s\n' "$st_dir"
    printf 'SELFTEST_TOTAL: %d/%d\n' "$pass" "$total"
    if [ "$pass" -eq "$total" ]; then
        printf 'SELFTEST_OK\n'
        exit 0
    fi
    printf 'SELFTEST_BAD: %d/%d\n' "$pass" "$total"
    exit 1
}

#==============================================================================
# 9. 分发
#==============================================================================
case "$MODE" in
    default)  default_main ;;
    baseline) baseline_main ;;
    selftest) selftest_main ;;
esac
