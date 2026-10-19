#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_mmu_driver.sh —— F3 MMU 包**反证驱动**
#                                    （旧树红 / 新树绿 / 控制两边正确）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）
# 依赖 : sim/functional/test_mmu.sh（包入口，唯一 `FUNCTIONAL_MMU: PASS` 锚点来源）
#
# 做什么（默认全跑；`--self-test` 只跑包装器杀伤路径自检）：
#   1) **私有不可变快照**：
#        · deps_cur/ —— 当前工作树 7 个 RTL + 2 个头 + TB 的**私有拷贝**（chmod 444），
#          与并发改动隔离；两相共用同一份，保证"旧新矩阵共享同一 TB"。
#        · frozen/   —— 包脚本 test_mmu.sh + TB + scripts/env.sh 的冻结副本
#          （两相共享输入的真身；阶段间若变化 ⇒ 判定失败）。
#        · deps_base/—— 用 `git show <BASE>:<path>` 取 201acf61 的 7 RTL + 2 头
#          （**不递归复制 build**，不碰工作树），chmod 444 并记录/复核 sha256。
#   2) **正控（新树）**：DUT_ROOT=<deps_cur> 跑 test_mmu.sh（默认口径）
#      ⇒ 必须 rc=0、唯一 PASS 锚点、total/checks/fails 精确匹配冻结规格。
#   3) **反证（旧树）**：DUT_ROOT=<deps_base> 跑**同一 TB/同一脚本**
#      ⇒ 必须 rc=1、**不得**出现 PASS 锚点、11 个根因的 `MMU FAIL [TAG]` 齐全、
#        逐向量行数 == 规格、fails>0、且**没有任何 `CTRL_` 控制标签失败**。
#   4) **控制两边正确**：两棵树都校验 `MMU FAIL [CTRL_` 出现 0 次
#      （否则"修复"可能只是放宽判据）。
#   5) **包装器自检**（--self-test）：注入 编译失败 / 空 vvp / 运行非零 / 缺摘要 /
#      日志含 FAIL / 日志含 DEFECT_REPRODUCED / 少向量 / 缺 PASS 锚点 八类反例，
#      逐一要求**精确 reason + rc≠0 + 无 PASS 泄漏**。
#
# 产物纪律：产物根固定在本仓库 `build/functional/` 授权树内（或父入口传入的
#           RV32_FUNCTIONAL_PKG_OUT_DIR），每次 `mktemp -d` 独占 run 目录，**不做任何 rm**。
# 工具真源：`scripts/env.sh`（只读）；本驱动只经 test_mmu.sh 间接使用 iverilog/vvp。
#
# 用法 : bash sim/functional/test_mmu_driver.sh
#        bash sim/functional/test_mmu_driver.sh --self-test
#        MMU_BASELINE_COMMIT=<sha> bash sim/functional/test_mmu_driver.sh
#==============================================================================
set -u

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'MMU_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'MMU_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }
PKG_SH="$SELF_DIR/test_mmu.sh"
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'MMU_DRIVER: FAIL reason=auth_root_readlink_failed\n'; exit 1; }

MODE="full"
if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    MODE="selftest"
elif [ "$#" -ne 0 ]; then
    printf 'MMU_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi

[ -f "$PKG_SH" ] || { printf 'MMU_DRIVER: FAIL reason=pkg_missing path=%s\n' "$PKG_SH"; exit 1; }
ENV_SH="$REPO_ROOT/scripts/env.sh"
[ -r "$ENV_SH" ] || { printf 'MMU_DRIVER: FAIL reason=env_sh_missing path=%s\n' "$ENV_SH"; exit 1; }
# shellcheck source=../../scripts/env.sh
. "$ENV_SH"
VVP_BIN="${RV32_VVP:-}"
[ -n "$VVP_BIN" ] && [ -x "$VVP_BIN" ] || { printf 'MMU_DRIVER: FAIL reason=vvp_missing\n'; exit 1; }

ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/mmu-driver}"
case "$(readlink -m -- "$ROOT_RAW")" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) printf 'MMU_DRIVER: FAIL reason=out_root_unauthorized root=%s\n' "$ROOT_RAW"; exit 1 ;;
esac
mkdir -p -- "$(readlink -m -- "$ROOT_RAW")" || {
    printf 'MMU_DRIVER: FAIL reason=out_root_mkdir_failed\n'; exit 1; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")"
DRV="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || {
    printf 'MMU_DRIVER: FAIL reason=mktemp_run_dir_failed root=%s\n' "$ROOT_NORM"; exit 1; }

DRV_LOG="$DRV/driver.log"
: > "$DRV_LOG" || { printf 'MMU_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }
exec 3>>"$DRV_LOG"

note() { printf '%s\n' "$*" >&3; }
fail() {
    note "DRIVER_FAIL reason=$1"
    printf 'MMU_DRIVER: FAIL reason=%s run_dir=%s\n' "$1" "$DRV"
    exit 1
}

#------------------------------------------------------------------------------
# 本包冻结规格（必须与 test_mmu.sh / tb_mmu_semantics.sv 一致）
#------------------------------------------------------------------------------
readonly SPEC_VECTORS=26
readonly N_HASH_EXPECTED=10
readonly BASE_COMMIT_FULL="201acf61e118a3fb533e1a96768687a35efa1751"
readonly DEFECT_TAGS="MMU_SVADE_D_TLB_HIT MMU_SFENCE_GLOBAL_VA MMU_PA34_ROOT MMU_PA34_L0 MMU_PA34_LEAF4K MMU_PA34_LEAF4M MMU_CBM_RO_PTW MMU_CBM_RO_TLB MMU_CBM_D_CHECK MMU_LSU_CBM_RO MMU_LSU_NEED_PERM"

RTL_REL_LIST=(
    rtl/csr/ptw.v
    rtl/csr/tlb.v
    rtl/mem/lsu.v
    rtl/mem/pmp_check.v
    rtl/mem/mmio_route.v
    rtl/mem/amo_unit.v
    rtl/mem/cmo_unit.v
)
HDR_REL_LIST=( rtl/pkg/rv32_defs.vh rtl/pkg/core_params.vh )
TB_REL="sim/functional/tb_mmu_semantics.sv"

note "==== test_mmu_driver.sh ===="
note "date       = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT  = $REPO_ROOT"
note "DRV        = $DRV"
note "MODE       = $MODE"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    note "GIT_HEAD   = $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

file_sha() { sha256sum -- "$1" | awk '{print $1}'; }

#==============================================================================
# A. 私有不可变快照
#==============================================================================
CUR="$DRV/deps_cur"
SNAP="$DRV/deps_base"
FRZ="$DRV/frozen"
BASE_COMMIT="${MMU_BASELINE_COMMIT:-201acf61}"

mkdir -p -- "$CUR/rtl/csr" "$CUR/rtl/mem" "$CUR/rtl/pkg" || fail "cur_snapshot_mkdir_failed"
for f in "${RTL_REL_LIST[@]}"; do
    mkdir -p -- "$CUR/$(dirname -- "$f")" || fail "cur_snapshot_subdir"
    cp -- "$REPO_ROOT/$f" "$CUR/$f" || fail "cur_snapshot_copy_$f"
    chmod 444 -- "$CUR/$f" || fail "cur_snapshot_chmod_$f"
    [ "$(file_sha "$REPO_ROOT/$f")" = "$(file_sha "$CUR/$f")" ] || fail "cur_snapshot_mismatch_$f"
done
for f in "${HDR_REL_LIST[@]}"; do
    mkdir -p -- "$CUR/$(dirname -- "$f")" || fail "cur_snapshot_subdir"
    cp -- "$REPO_ROOT/$f" "$CUR/$f" || fail "cur_snapshot_copy_$f"
    chmod 444 -- "$CUR/$f" || fail "cur_snapshot_chmod_$f"
    [ "$(file_sha "$REPO_ROOT/$f")" = "$(file_sha "$CUR/$f")" ] || fail "cur_snapshot_mismatch_$f"
done
note "CUR        = $CUR"
for f in "${RTL_REL_LIST[@]}"; do note "CUR_SHA $f = $(file_sha "$CUR/$f")"; done

#   frozen/：两相共用的包脚本 + TB + env.sh（阶段间共享输入的真身）
mkdir -p -- "$FRZ/sim/functional" "$FRZ/scripts" || fail "frozen_mkdir_failed"
cp -- "$PKG_SH" "$FRZ/sim/functional/test_mmu.sh" || fail "frozen_pkg_copy_failed"
cp -- "$REPO_ROOT/$TB_REL" "$FRZ/$TB_REL" || fail "frozen_tb_copy_failed"
cp -- "$REPO_ROOT/scripts/env.sh" "$FRZ/scripts/env.sh" || fail "frozen_env_copy_failed"
chmod 444 -- "$FRZ/sim/functional/test_mmu.sh" "$FRZ/$TB_REL" "$FRZ/scripts/env.sh" \
    || fail "frozen_chmod_failed"
cmp -s -- "$PKG_SH" "$FRZ/sim/functional/test_mmu.sh" || fail "frozen_pkg_mismatch"
cmp -s -- "$REPO_ROOT/$TB_REL" "$FRZ/$TB_REL" || fail "frozen_tb_mismatch"
cmp -s -- "$REPO_ROOT/scripts/env.sh" "$FRZ/scripts/env.sh" || fail "frozen_env_mismatch"

shared_sha_of() {
    sha256sum -- "$1/sim/functional/test_mmu.sh" \
                 "$1/$TB_REL" \
                 "$1/scripts/env.sh" 2>/dev/null | awk '{print $1}' | tr '\n' ' '
}
check_shared_unchanged() {
    local now
    now="$(shared_sha_of "$1")"
    [ -n "$now" ] || return 1
    [ "$now" = "$2" ] || return 1
    return 0
}

if [ "$MODE" = "full" ]; then
    git -C "$REPO_ROOT" cat-file -e "${BASE_COMMIT}^{commit}" 2>>"$DRV_LOG" \
        || fail "baseline_commit_missing commit=$BASE_COMMIT"
    for f in "${RTL_REL_LIST[@]}" "${HDR_REL_LIST[@]}"; do
        mkdir -p -- "$SNAP/$(dirname -- "$f")" || fail "snapshot_mkdir_failed"
        git -C "$REPO_ROOT" show "${BASE_COMMIT}:${f}" > "$SNAP/$f" || fail "snapshot_extract_$f"
        chmod 444 -- "$SNAP/$f" || fail "snapshot_chmod_$f"
    done
    note "SNAP       = $SNAP"
    note "SNAP_COMMIT= $BASE_COMMIT"
    for f in "${RTL_REL_LIST[@]}"; do note "SNAP_SHA $f = $(file_sha "$SNAP/$f")"; done
fi

SHARED_SHA_PRE="$(shared_sha_of "$FRZ")"
note "FRZ        = $FRZ"
note "SHARED_SHA = $SHARED_SHA_PRE"

#------------------------------------------------------------------------------
# 通用：跑一次包脚本，捕获 stdout/stderr 到指定日志
#------------------------------------------------------------------------------
run_pkg() {  # run_pkg <pkg_script> <logfile> [env KEY=VAL ...]
    local pkg="$1"; local log="$2"; shift 2
    env "$@" bash "$pkg" > "$log" 2>&1
}

pkg_field() {  # pkg_field <log> <field>
    sed -n "s/^mmu: .*[[:space:]]$2=\\([0-9]\\+\\).*/\\1/p" "$1" | head -1
}

anchor_count() {  # anchor_count <log> <anchor>
    grep -cxF -- "$2" "$1" 2>/dev/null || true
}

#==============================================================================
# B. --self-test：包装器杀伤路径自检
#==============================================================================
if [ "$MODE" = "selftest" ]; then
    st="$DRV/selftest"; mkdir -p "$st" || fail "selftest_mkdir_failed"
    pass=0; total=0

    #   ---- 夹具：合法包脚本（打印完整摘要 + 唯一锚点）----
    mk_good() {
        local out="$1" i
        : > "$out"
        for ((i = 1; i <= SPEC_VECTORS; i++)); do printf 'VEC %d checks=1 fails=0\n' "$i" >> "$out"; done
        printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$SPEC_VECTORS" >> "$out"
        printf 'mmu: compile_rc=0 vvp_ok=1 hash_lines=10 hash_badhex=0 run_rc=0 total=%d checks=%d fails=0 vec_lines=%d anchor_lines=1 pass_substr=1\n' \
               "$SPEC_VECTORS" "$SPEC_VECTORS" "$SPEC_VECTORS" >> "$out"
        printf 'FUNCTIONAL_MMU: PASS\n' >> "$out"
    }

    #   ---- 复用包入口的**真实门控**（不复制判据）：把夹具当运行日志喂给它 ----
    #   做法：源出包脚本的 gate_positive_log 会因 `case "$MODE"` 直接执行 main，
    #   故这里改为调用**包脚本自身的默认模式**跑假 vvp 造出真日志，再用
    #   本驱动的独立判据校验 rc/锚点/摘要 —— 判据不复制，只看端到端结果。
    killer_case() {   # <名称> <期望> <假 vvp> <检查函数名>
        local name="$1" expect="$2" vvp="$3" chk="$4" got log rc=0
        log="$st/${name}.log"
        #   ★ DUT_ROOT 必须显式给：冻结副本的 REPO_ROOT 是 $FRZ（只有 TB/env.sh），
        #     不给就会在"缺 DUT 源"上提前 die ⇒ 反例被误判成"杀伤成功"。
        #   冻结副本的 REPO_ROOT = $FRZ ⇒ 其授权产物根是 $FRZ/build/functional
        env RV32_VVP="$vvp" DUT_ROOT="$CUR" \
            RV32_FUNCTIONAL_PKG_OUT_DIR="$FRZ/build/functional/mmu_${name}" \
            bash "$FRZ/sim/functional/test_mmu.sh" > "$log" 2>&1 || rc=$?
        total=$((total + 1))
        case "$chk" in
            pass)    if [ "$rc" -eq 0 ] && [ "$(anchor_count "$log" 'FUNCTIONAL_MMU: PASS')" = "1" ]; then got=pass; else got=reject; fi ;;
            #   ★ 反例必须"真的被门控拒"：rc≠0 **且** 无正式锚点 **且** 包入口打印了
            #     它自己的 POSITIVE_CHECK_FAILED 诊断（排除"提前 die 也算杀伤"的假绿）
            kill)    if [ "$rc" -ne 0 ] && [ "$(anchor_count "$log" 'FUNCTIONAL_MMU: PASS')" = "0" ] \
                        && [ "$(grep -c 'POSITIVE_CHECK_FAILED' "$log" 2>/dev/null || true)" = "1" ]; then got=kill; else got=leak; fi ;;
            *)       got=reject ;;
        esac
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK rc=%s\n' "$name" "$expect" "$got" "$rc"
        else
            printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH rc=%s\n' "$name" "$expect" "$got" "$rc"
        fi
        note "SELFTEST $name expect=$expect got=$got rc=$rc log=$log"
    }

    #   ---- 夹具：各种"坏"假 vvp ----
    cat > "$st/vvp_fail" <<'EOS'
#!/bin/sh
exit 1
EOS
    cat > "$st/vvp_quiet" <<'EOS'
#!/bin/sh
exit 0
EOS
    cat > "$st/vvp_badsum" <<'EOS'
#!/bin/sh
printf 'FUNCTIONAL_MMU_VECTORS total=25 checks=25 fails=0\n'
exit 0
EOS
    cat > "$st/vvp_fails" <<'EOS'
#!/bin/sh
printf 'FUNCTIONAL_MMU_VECTORS total=26 checks=26 fails=1\n'
exit 1
EOS
    cat > "$st/vvp_failline" <<'EOS'
#!/bin/sh
i=1
while [ "$i" -le 26 ]; do printf 'VEC %d checks=1 fails=0\n' "$i"; i=$((i+1)); done
printf 'MMU FAIL [MMU_PA34_ROOT]: x\n'
printf 'FUNCTIONAL_MMU_VECTORS total=26 checks=26 fails=0\n'
printf 'FUNCTIONAL_MMU: PASS\n'
exit 0
EOS
    cat > "$st/vvp_defect" <<'EOS'
#!/bin/sh
i=1
while [ "$i" -le 26 ]; do printf 'VEC %d checks=1 fails=0\n' "$i"; i=$((i+1)); done
printf 'DEFECT_REPRODUCED: X\n'
printf 'FUNCTIONAL_MMU_VECTORS total=26 checks=26 fails=0\n'
printf 'FUNCTIONAL_MMU: PASS\n'
exit 0
EOS
    cat > "$st/vvp_shortvec" <<'EOS'
#!/bin/sh
i=1
while [ "$i" -le 25 ]; do printf 'VEC %d checks=1 fails=0\n' "$i"; i=$((i+1)); done
printf 'FUNCTIONAL_MMU_VECTORS total=26 checks=26 fails=0\n'
printf 'FUNCTIONAL_MMU: PASS\n'
exit 0
EOS
    cat > "$st/vvp_noanchor" <<'EOS'
#!/bin/sh
i=1
while [ "$i" -le 26 ]; do printf 'VEC %d checks=1 fails=0\n' "$i"; i=$((i+1)); done
printf 'FUNCTIONAL_MMU_VECTORS total=26 checks=26 fails=0\n'
exit 0
EOS
    chmod +x "$st"/vvp_*

    # 正控：真实工具 + 真实快照 ⇒ 必须绿
    killer_case real_tool_ok      pass   "$VVP_BIN" pass
    # 八类反例：全部必须 rc≠0 且**无**正式锚点
    killer_case vvp_fail          kill   "$st/vvp_fail"      kill
    killer_case vvp_quiet         kill   "$st/vvp_quiet"     kill
    killer_case bad_summary_total kill   "$st/vvp_badsum"    kill
    killer_case summary_fails     kill   "$st/vvp_fails"     kill
    killer_case log_has_fail      kill   "$st/vvp_failline"  kill
    killer_case log_has_defect    kill   "$st/vvp_defect"    kill
    killer_case vec_short         kill   "$st/vvp_shortvec"  kill
    killer_case no_anchor         kill   "$st/vvp_noanchor"  kill

    # ---- 冻结快照 sha 自检：deps_cur 与工作树一致；frozen 与源一致 ----
    total=$((total + 1))
    ok=1
    for f in "${RTL_REL_LIST[@]}" "${HDR_REL_LIST[@]}"; do
        [ "$(file_sha "$CUR/$f")" = "$(file_sha "$REPO_ROOT/$f")" ] || ok=0
    done
    [ "$ok" = "1" ] && [ "$(shared_sha_of "$FRZ")" = "$SHARED_SHA_PRE" ] || ok=0
    if [ "$ok" = "1" ]; then pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK\n' snapshots_frozen yes yes
    else printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH\n' snapshots_frozen yes no; fi

    printf 'SELFTEST_FIXTURES: %s\n' "$st"
    printf 'SELFTEST_TOTAL: %d/%d\n' "$pass" "$total"
    if [ "$pass" -eq "$total" ]; then printf 'MMU_DRIVER_SELFTEST_OK\n'; exit 0; fi
    printf 'MMU_DRIVER_SELFTEST_BAD: %d/%d\n' "$pass" "$total"
    exit 1
fi

#==============================================================================
# C. 正控 / 反证 / 控制两边正确（full 模式）
#==============================================================================
[ "$(git -C "$REPO_ROOT" rev-parse "${BASE_COMMIT}^{commit}" 2>/dev/null)" = "$BASE_COMMIT_FULL" ] \
    || fail "baseline_commit_hash_mismatch"

# ---- C1：正控（新树）----
POS_LOG="$DRV/pos_fixed.log"
run_pkg "$FRZ/sim/functional/test_mmu.sh" "$POS_LOG" \
    "DUT_ROOT=$CUR" "RV32_FUNCTIONAL_PKG_OUT_DIR=$FRZ/build/functional/mmu_pos"
POS_RC=$?
note "POS rc=$POS_RC"
[ "$POS_RC" -eq 0 ] || fail "pos_rc=$POS_RC"
[ "$(anchor_count "$POS_LOG" 'FUNCTIONAL_MMU: PASS')" = "1" ] || fail "pos_pass_anchor"
[ "$(pkg_field "$POS_LOG" fails)" = "0" ] || fail "pos_fails=$(pkg_field "$POS_LOG" fails)"
[ "$(pkg_field "$POS_LOG" total)" = "$SPEC_VECTORS" ] || fail "pos_total=$(pkg_field "$POS_LOG" total)"
[ "$(grep -c 'MMU FAIL' "$POS_LOG" 2>/dev/null || true)" = "0" ] || fail "pos_has_fail_lines"
check_shared_unchanged "$FRZ" "$SHARED_SHA_PRE" || fail "shared_inputs_changed_after_pos"

# ---- C2：反证（旧树）----
NEG_LOG="$DRV/neg_base.log"
run_pkg "$FRZ/sim/functional/test_mmu.sh" "$NEG_LOG" \
    "DUT_ROOT=$SNAP" "RV32_FUNCTIONAL_PKG_OUT_DIR=$FRZ/build/functional/mmu_neg"
NEG_RC=$?
note "NEG rc=$NEG_RC"
[ "$NEG_RC" -ne 0 ] || fail "neg_rc_zero"
#   包入口在失败路径**绝不**打印正式锚点，只打印 POSITIVE_CHECK_FAILED 与日志路径
[ "$(anchor_count "$NEG_LOG" 'FUNCTIONAL_MMU: PASS')" = "0" ] || fail "neg_pass_anchor_present"
[ "$(grep -c 'POSITIVE_CHECK_FAILED' "$NEG_LOG" 2>/dev/null || true)" = "1" ] || fail "neg_no_positive_failed_line"
#   缺陷标签在**底层运行日志**里（包入口故意不 tail 底层日志，避免泄漏 PASS）
NEG_RUN_LOG="$(sed -n 's/^mmu: compile_log=.* run_log=\(.*\)$/\1/p' "$NEG_LOG" | head -1)"
[ -n "$NEG_RUN_LOG" ] && [ -r "$NEG_RUN_LOG" ] || fail "neg_run_log_unresolved"
note "NEG_RUN_LOG = $NEG_RUN_LOG"
[ "$(grep -c 'MMU FAIL' "$NEG_RUN_LOG" 2>/dev/null || true)" -gt 0 ] || fail "neg_no_fail_lines"
missing=""
for tag in $DEFECT_TAGS; do
    grep -qF "MMU FAIL [${tag}]" "$NEG_RUN_LOG" 2>/dev/null || missing="${missing} ${tag}"
done
[ -z "$missing" ] || fail "neg_missing_tags:$missing"
[ "$(grep -c 'MMU FAIL \[CTRL_' "$NEG_RUN_LOG" 2>/dev/null || true)" = "0" ] || fail "neg_ctrl_fails"
#   旧树也不得出现正式锚点（双重保险）
[ "$(anchor_count "$NEG_RUN_LOG" 'FUNCTIONAL_MMU: PASS')" = "0" ] || fail "neg_runlog_pass_anchor"
check_shared_unchanged "$FRZ" "$SHARED_SHA_PRE" || fail "shared_inputs_changed_after_neg"

# ---- C3：控制两边正确（两棵树 CTRL_ 失败均为 0）----
#   正控成功时包入口只打印 `mmu: log_dir=<...>`（失败路径才打印 compile_log/run_log）
POS_RUN_LOG="$(sed -n 's/^mmu: log_dir=\(.*\)$/\1\/run.log/p' "$POS_LOG" | head -1)"
[ -n "$POS_RUN_LOG" ] && [ -r "$POS_RUN_LOG" ] || fail "pos_run_log_unresolved"
[ "$(grep -c 'MMU FAIL \[CTRL_' "$POS_RUN_LOG" 2>/dev/null || true)" = "0" ] || fail "pos_ctrl_fails"

printf 'MMU_DRIVER: new_green=1 old_red=1 ctrl_ok=1 defect_tags=%s\n' "$(printf '%s' "$DEFECT_TAGS" | wc -w)"
printf 'MMU_DRIVER: run_dir=%s\n' "$DRV"
printf 'MMU_DRIVER_PASS\n'
exit 0
