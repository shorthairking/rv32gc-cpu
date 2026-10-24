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
readonly SPEC_VECTORS=32
readonly N_HASH_EXPECTED=10
readonly BASE_COMMIT_FULL="201acf61e118a3fb533e1a96768687a35efa1751"
readonly DEFECT_TAGS="MMU_SVADE_D_TLB_HIT MMU_SFENCE_GLOBAL_VA MMU_PA34_ROOT MMU_PA34_L0 MMU_PA34_LEAF4K MMU_PA34_LEAF4M MMU_PA34_AF_LEGAL MMU_CBM_RO_PTW MMU_CBM_RO_TLB MMU_CBM_D_CHECK MMU_LSU_CBM_RO MMU_LSU_NEED_PERM MMU_LOOKUP2_D0"
# ---- 冻结的逐向量规格（与 test_mmu.sh / tb_mmu_semantics.sv 同步）----
readonly CHECKS_TOTAL_NEW=235
readonly CHECKS_TOTAL_OLD=243
readonly VEC_NAMES="CTRL_XZ_DETECT CTRL_BASE_TR CTRL_BIGPAGE MMU_SVADE_D_TLB_HIT CTRL_SVADE_D1 CTRL_SVADE_A0 MMU_SFENCE_GLOBAL_VA CTRL_SFENCE_ASID_KEEP_G CTRL_SFENCE_VA_ASID_KEEP_G CTRL_SFENCE_ALL MMU_PA34_ROOT MMU_PA34_L0 MMU_PA34_LEAF4K MMU_PA34_LEAF4M CTRL_PA34_PRIO_PERM MMU_PA34_AF_LEGAL CTRL_PA34_SVADE CTRL_PA_LOW MMU_CBM_RO_PTW MMU_CBM_RO_TLB MMU_CBM_D_CHECK CTRL_CBM_A0 CTRL_CBM_RESERVED CTRL_STORE_RO MMU_LSU_CBM_RO CTRL_LSU_CBM_WO MMU_LSU_NEED_PERM CTRL_LSU_CBM_DENY CTRL_LSU_STORE_RO CTRL_LOOKUP2_FETCH MMU_LOOKUP2_D0 CTRL_LSU_LOAD_WO"
readonly NEW_CHECKS="5 21 7 9 9 6 16 9 9 9 11 6 6 5 7 8 6 8 6 9 7 4 5 7 4 3 2 3 3 13 9 3"

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

#------------------------------------------------------------------------------
# ★ 2026-10（独审 P1④）：原来的 `sha256sum | awk` 管道**吞掉** sha 的原始 rc，
#   且无 pipefail ⇒ 假 sha（rc≠0 但仍打印合法行）会被当成成功。
#   这里改为：先落盘、检查 rc、逐行判 64-hex，再取哈希；任何一步失败即返回非 0。
#------------------------------------------------------------------------------
SHA_BIN="${SHA_BIN:-sha256sum}"

sha_one() {   # sha_one <file> -> stdout 64-hex；失败返回非 0
    local f="$1" out rc=0 line
    out="$(mktemp "$DRV/h.XXXXXX")" || return 1
    "$SHA_BIN" -- "$f" >"$out" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then rm -f -- "$out"; return 1; fi
    if [ "$(wc -l < "$out")" -ne 1 ]; then rm -f -- "$out"; return 1; fi
    line="$(cat -- "$out")"
    case "$line" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'  '*) ;;
        *) rm -f -- "$out"; return 1 ;;
    esac
    printf '%s\n' "${line%% *}"
    rm -f -- "$out"
    return 0
}

file_sha() { sha_one "$1"; }

#   非空 + 恰 64 个 hex（调用方**必须先赋值并检查返回值**，不能直接嵌进 $( ) 比较：
#   两次 file_sha 都失败时两侧都是空串，"空==空"会假通过 —— 独审 P1）
sha64_ok() {
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

#   取一个文件的可信 SHA：失败时**返回非 0 且不打印**（绝不在 $( ) 里调 fail ——
#   fail 只会退出那个子 shell，父层拿到的是它打印的文本，比较就变成"文本 vs 文本"）。
#   调用方必须：`sha="$(need_sha f)" || fail reason`，再确认 sha64_ok。
need_sha() {   # need_sha <file>
    local h
    h="$(file_sha "$1")" || return 1
    sha64_ok "$h" || return 1
    printf '%s' "$h"
    return 0
}

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
    src_sha="$(need_sha "$REPO_ROOT/$f")" || fail "cur_src_sha_fail_$f"
    cp_sha="$(need_sha "$CUR/$f")"        || fail "cur_copy_sha_fail_$f"
    [ "$src_sha" = "$cp_sha" ] || fail "cur_snapshot_mismatch_$f"
    note "CUR_SHA $f = $cp_sha"
done
for f in "${HDR_REL_LIST[@]}"; do
    mkdir -p -- "$CUR/$(dirname -- "$f")" || fail "cur_snapshot_subdir"
    cp -- "$REPO_ROOT/$f" "$CUR/$f" || fail "cur_snapshot_copy_$f"
    chmod 444 -- "$CUR/$f" || fail "cur_snapshot_chmod_$f"
    src_sha="$(need_sha "$REPO_ROOT/$f")" || fail "cur_src_sha_fail_$f"
    cp_sha="$(need_sha "$CUR/$f")"        || fail "cur_copy_sha_fail_$f"
    [ "$src_sha" = "$cp_sha" ] || fail "cur_snapshot_mismatch_$f"
    note "CUR_SHA $f = $cp_sha"
done
note "CUR        = $CUR"

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

#   共享输入 = 包脚本 + TB + env.sh（**恰好 3 个**）。
#   返回：成功时打印 3 个 64-hex（空格分隔）；任一文件缺失 / sha rc≠0 /
#   行数≠3 / 任一行非 64-hex ⇒ 返回 1 且不打印任何东西。
shared_sha_of() {
    local root="$1" out rc=0 n bad f out_s=""
    out="$(mktemp "$DRV/s.XXXXXX")" || return 1
    "$SHA_BIN" -- "$root/sim/functional/test_mmu.sh" \
                 "$root/$TB_REL" \
                 "$root/scripts/env.sh" >"$out" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then rm -f -- "$out"; return 1; fi
    n="$(wc -l < "$out")"
    if [ "$n" -ne 3 ]; then rm -f -- "$out"; return 1; fi
    bad="$(grep -cvE '^[0-9a-f]{64}  ' "$out" || true)"; bad="${bad:-0}"
    if [ "$bad" -ne 0 ]; then rm -f -- "$out"; return 1; fi
    while IFS= read -r f; do out_s="${out_s}${f%% *} "; done < "$out"
    rm -f -- "$out"
    printf '%s' "${out_s% }"
    return 0
}
check_shared_unchanged() {
    local now
    now="$(shared_sha_of "$1")" || return 1
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
    for f in "${RTL_REL_LIST[@]}"; do
        snap_sha="$(need_sha "$SNAP/$f")" || fail "snap_sha_fail_$f"
        note "SNAP_SHA $f = $snap_sha"
    done
fi

SHARED_SHA_PRE="$(shared_sha_of "$FRZ")" || fail "shared_sha_fail"
[ -n "$SHARED_SHA_PRE" ] || fail "shared_sha_empty"
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

    #   ---- 冻结表（与包脚本一致）：name / NEW checks ----
    VN=(); VC=()
    read -r -a VN <<<"$VEC_NAMES"
    read -r -a VC <<<"$NEW_CHECKS"

    mk_good() {
        local out="$1" i
        : > "$out"
        for ((i = 1; i <= SPEC_VECTORS; i++)); do
            printf 'VEC %d name=%s checks=%d fails=0\n' "$i" "${VN[$((i-1))]}" "${VC[$((i-1))]}" >> "$out"
        done
        printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW" >> "$out"
        printf 'mmu: compile_rc=0 vvp_ok=1 hash_lines=10 hash_badhex=0 run_rc=0 total=%d checks=%d fails=0 vec_lines=%d anchor_lines=1 pass_substr=1\n' \
               "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW" "$SPEC_VECTORS" >> "$out"
        printf 'FUNCTIONAL_MMU: PASS\n' >> "$out"
    }

    killer_case() {   # <名称> <期望 pass|kill> <假 vvp> <期望 reason 片段>
        local name="$1" expect="$2" vvp="$3" exp_reason="$4"
        local got log rc=0
        log="$st/${name}.log"
        rm -f -- "$st/${name}.marker"
        #   ★ DUT_ROOT 必须显式给：冻结副本的 REPO_ROOT 是 $FRZ（只有 TB/env.sh），
        #     不给就会在"缺 DUT 源"上提前 die ⇒ 反例被误判成"杀伤成功"。
        #   冻结副本的授权产物根是 $FRZ/build/functional。
        env RV32_VVP="$vvp" DUT_ROOT="$CUR" \
            RV32_FUNCTIONAL_PKG_OUT_DIR="$FRZ/build/functional/mmu_${name}" \
            MMU_FIXTURE_MARKER="$st/${name}.marker" \
            bash "$FRZ/sim/functional/test_mmu.sh" > "$log" 2>&1 || rc=$?
        total=$((total + 1))
        #   ★ 独审 P2：杀伤必须"精确 rc=1 + 对应 reason + 证明 VVP 真被调用 +
        #     编译成功（无关的编译失败不得计杀伤）"。
        local compile_ok=0 vvp_ran=0 reason_ok=0 anchor_n
        grep -q 'compile_rc=0' "$log" && compile_ok=1
        [ -f "$st/${name}.marker" ] && vvp_ran=1
        [ -n "$exp_reason" ] && grep -q "reason=${exp_reason}" "$log" && reason_ok=1
        anchor_n="$(anchor_count "$log" 'FUNCTIONAL_MMU: PASS')"
        case "$expect" in
            pass) if [ "$rc" -eq 0 ] && [ "$anchor_n" = "1" ] && [ "$compile_ok" = 1 ]; then got=pass; else got=reject; fi ;;
            kill) if [ "$rc" -eq 1 ] && [ "$anchor_n" = "0" ] && [ "$compile_ok" = 1 ] \
                      && [ "$reason_ok" = 1 ] && [ "$vvp_ran" = 1 ]; then got=kill; else got=leak; fi ;;
            *)    got=reject ;;
        esac
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK rc=%s reason=%s vvp=%s\n' \
                "$name" "$expect" "$got" "$rc" "$exp_reason" "$vvp_ran"
        else
            printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH rc=%s compile_ok=%s reason_ok=%s vvp_ran=%s\n' \
                "$name" "$expect" "$got" "$rc" "$compile_ok" "$reason_ok" "$vvp_ran"
        fi
        note "SELFTEST $name expect=$expect got=$got rc=$rc compile_ok=$compile_ok reason_ok=$reason_ok vvp_ran=$vvp_ran log=$log"
    }

    #   ---- 假 vvp 夹具：都先 touch marker（证明 VVP 真被调用）----
    emit_vecs() {   # emit_vecs <count>
        local n="$1" i
        for ((i = 1; i <= n; i++)); do
            printf 'VEC %d name=%s checks=%d fails=0\n' "$i" "${VN[$((i-1))]}" "${VC[$((i-1))]}"
        done
    }
    mk_fake() {   # mk_fake <name> <payload_file> <rc>
        local nm="$1" pay="$2" rc="$3"
        {
            printf '#!/bin/sh\n'
            printf '%s\n' '[ -n "${MMU_FIXTURE_MARKER:-}" ] && : > "$MMU_FIXTURE_MARKER"'
            printf 'cat <<'"'"'EOP'"'"'\n'
            cat -- "$pay"
            printf 'EOP\n'
            printf 'exit %s\n' "$rc"
        } > "$st/$nm"
        chmod +x "$st/$nm"
    }
    cat > "$st/vvp_fail" <<'EOS'
#!/bin/sh
[ -n "${MMU_FIXTURE_MARKER:-}" ] && : > "$MMU_FIXTURE_MARKER"
exit 1
EOS
    cat > "$st/vvp_quiet" <<'EOS'
#!/bin/sh
[ -n "${MMU_FIXTURE_MARKER:-}" ] && : > "$MMU_FIXTURE_MARKER"
exit 0
EOS
    : > "$st/p_badsum"; printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$((SPEC_VECTORS + 1))" "$CHECKS_TOTAL_NEW" > "$st/p_badsum"
    printf 'FUNCTIONAL_MMU: PASS\n' >> "$st/p_badsum"
    #   ★ 独审 P2：summary_fails 夹具必须**底层 rc=0**，否则测的是"运行非零"而不是摘要门控
    printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=1\n' "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW" > "$st/p_fails"
    printf 'FUNCTIONAL_MMU: PASS\n' >> "$st/p_fails"
    { emit_vecs "$SPEC_VECTORS"; printf 'MMU FAIL [MMU_PA34_ROOT]: x\n'; \
      printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW"; \
      printf 'FUNCTIONAL_MMU: PASS\n'; } > "$st/p_failline"
    { emit_vecs "$SPEC_VECTORS"; printf 'DEFECT_REPRODUCED: X\n'; \
      printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW"; \
      printf 'FUNCTIONAL_MMU: PASS\n'; } > "$st/p_defect"
    { emit_vecs $((SPEC_VECTORS - 1)); \
      printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" \
             "$((CHECKS_TOTAL_NEW - ${VC[$((SPEC_VECTORS-1))]}))"; \
      printf 'FUNCTIONAL_MMU: PASS\n'; } > "$st/p_shortvec"
    { emit_vecs "$SPEC_VECTORS"; \
      printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$CHECKS_TOTAL_NEW"; } > "$st/p_noanchor"
    #   32 行但每行 checks=1（"凑数自证"）⇒ 必须被逐向量规格拒
    { for ((i = 1; i <= SPEC_VECTORS; i++)); do
          printf 'VEC %d name=%s checks=1 fails=0\n' "$i" "${VN[$((i-1))]}"
      done
      printf 'FUNCTIONAL_MMU_VECTORS total=%d checks=%d fails=0\n' "$SPEC_VECTORS" "$SPEC_VECTORS"
      printf 'FUNCTIONAL_MMU: PASS\n'; } > "$st/p_fakechecks"

    mk_fake vvp_badsum   "$st/p_badsum"     0
    mk_fake vvp_fails    "$st/p_fails"      0
    mk_fake vvp_failline "$st/p_failline"   0
    mk_fake vvp_defect   "$st/p_defect"     0
    mk_fake vvp_shortvec "$st/p_shortvec"   0
    mk_fake vvp_noanchor "$st/p_noanchor"   0
    mk_fake vvp_fakechecks "$st/p_fakechecks" 0
    chmod +x "$st"/vvp_*

    # 正控：真实工具 + 真实快照 ⇒ 必须绿
    killer_case real_tool_ok      pass   "$VVP_BIN" ""
    # 反例：全部必须 rc=1 + 对应 reason + 编译成功 + VVP 真被调用
    killer_case vvp_fail          kill   "$st/vvp_fail"      "no_capture"
    killer_case vvp_quiet         kill   "$st/vvp_quiet"     "no_capture"
    killer_case bad_summary_total kill   "$st/vvp_badsum"    "summary_total="
    killer_case summary_fails     kill   "$st/vvp_fails"     "summary_fails=1"
    killer_case log_has_fail      kill   "$st/vvp_failline"  "log_has_FAIL=1"
    killer_case log_has_defect    kill   "$st/vvp_defect"    "log_has_DEFECT=1"
    killer_case vec_short         kill   "$st/vvp_shortvec"  "vec_line_count=31"
    killer_case no_anchor         kill   "$st/vvp_noanchor"  "pass_anchor_count=0"
    killer_case fake_checks       kill   "$st/vvp_fakechecks" "vec_checks_mismatch="

    #   ★ 独审 P1④：共享哈希的"假 sha"反证（不经过包脚本，直接测驱动自己的判据）
    sha_case() {   # <名称> <期望 ok|reject> <sha 工具> <root>
        local name="$1" expect="$2" bin="$3" root="$4" got
        total=$((total + 1))
        if SHA_BIN="$bin" shared_sha_of "$root" >/dev/null 2>&1; then got=ok; else got=reject; fi
        if [ "$got" = "$expect" ]; then
            pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK\n' "$name" "$expect" "$got"
        else
            printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH\n' "$name" "$expect" "$got"
        fi
        note "SELFTEST $name expect=$expect got=$got"
    }
    real_sha="$SHA_BIN"
    sha_case good_sha              ok     "$real_sha"            "$FRZ"
    #   假 sha：打印 3 行完整合法哈希后 exit 9 ⇒ 必须拒（原来管道会吞 rc）
    cat > "$st/sha_rc9" <<EOS
#!/bin/sh
i=0
while [ "\$i" -lt 3 ]; do
  printf '%064d  f\$i\n' 0
  i=\$((i+1))
done
exit 9
EOS
    #   假 sha：只打印 2 行合法哈希、exit 0 ⇒ 必须拒（行数≠3）
    cat > "$st/sha_2lines" <<EOS
#!/bin/sh
printf '%064d  f0\n' 0
printf '%064d  f1\n' 0
exit 0
EOS
    #   假 sha：3 行但其中一行非 64-hex ⇒ 必须拒
    cat > "$st/sha_nonhex" <<EOS
#!/bin/sh
printf '%064d  f0\n' 0
printf 'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ  f1\n'
printf '%064d  f2\n' 0
exit 0
EOS
    chmod +x "$st"/sha_rc9 "$st"/sha_2lines "$st"/sha_nonhex
    sha_case sha_rc9_reject        reject "$st/sha_rc9"     "$FRZ"
    sha_case sha_2lines_reject     reject "$st/sha_2lines"  "$FRZ"
    sha_case sha_nonhex_reject     reject "$st/sha_nonhex"  "$FRZ"
    #   共享输入被改动（阶段间改包/env）⇒ check_shared_unchanged 必须拒
    fz2="$st/frozen_changed"
    cp -a "$FRZ" "$fz2"
    chmod u+w "$fz2/sim/functional/test_mmu.sh"
    printf '\n# tampered\n' >> "$fz2/sim/functional/test_mmu.sh"
    total=$((total + 1))
    if check_shared_unchanged "$fz2" "$SHARED_SHA_PRE"; then
        printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH\n' shared_changed reject ok
    else
        pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK\n' shared_changed reject reject
    fi
    SHA_BIN="$real_sha"

    # ---- 冻结快照 sha 自检：deps_cur 与工作树一致；frozen 与源一致 ----
    total=$((total + 1))
    ok=1
    for f in "${RTL_REL_LIST[@]}" "${HDR_REL_LIST[@]}"; do
        h1="$(file_sha "$CUR/$f")" || { ok=0; break; }
        h2="$(file_sha "$REPO_ROOT/$f")" || { ok=0; break; }
        sha64_ok "$h1" && sha64_ok "$h2" || { ok=0; break; }
        [ "$h1" = "$h2" ] || ok=0
    done
    if [ "$ok" = "1" ]; then
        h3="$(shared_sha_of "$FRZ")" || ok=0
    fi
    [ "$ok" = "1" ] || true
    if [ "$ok" = "1" ]; then pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK\n' snapshots_frozen yes yes
    else printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH\n' snapshots_frozen yes no; fi

    #   ★ 独审 P1：**单文件**身份校验的杀伤链。假 sha 对"单文件"调用（$#=2：-- + file）
    #     委托真 sha 打印**合法一行**后 exit 9；对共享三文件调用（$#=4）正常委托。
    #     ⇒ 驱动必须在 deps_cur 身份校验处 rc=1 且**不**打印任何 PASS。
    cat > "$st/sha_single_bad" <<EOS
#!/bin/sh
if [ "\$#" -eq 2 ]; then
    "$real_sha" "\$@"
    exit 9
fi
exec "$real_sha" "\$@"
EOS
    chmod +x "$st/sha_single_bad"
    #   先自证：该假 sha 的三文件调用确实正常（否则下面的"正式 rc1"可能是别的原因）
    total=$((total + 1))
    if SHA_BIN="$st/sha_single_bad" shared_sha_of "$FRZ" >/dev/null 2>&1; then
        pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK\n' sha_single_shared_ok ok ok
    else
        printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH\n' sha_single_shared_ok ok reject
    fi
    #   正式 run：驱动完整跑一遍（full 模式），必须在单文件身份校验处 rc=1、无 PASS
    formal_log="$st/formal_badsha.log"
    formal_rc=0
    env SHA_BIN="$st/sha_single_bad" bash "$SELF_PATH" > "$formal_log" 2>&1 || formal_rc=$?
    total=$((total + 1))
    if [ "$formal_rc" -eq 1 ] && [ "$(anchor_count "$formal_log" 'MMU_DRIVER_PASS')" = "0" ] \
       && grep -q 'MMU_DRIVER: FAIL reason=cur_src_sha_fail' "$formal_log"; then
        pass=$((pass + 1)); printf 'SELFTEST %-24s expected=%-6s got=%-6s OK rc=%s\n' formal_badsha_rc1 kill kill "$formal_rc"
    else
        printf 'SELFTEST %-24s expected=%-6s got=%-6s MISMATCH rc=%s\n' formal_badsha_rc1 kill "rc=$formal_rc"
    fi
    note "SELFTEST formal_badsha rc=$formal_rc log=$formal_log"

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
#   ★ 独审 P1③：旧树必须**完整跑完** 32 个向量（唯一 ID、name 冻结），
#     不能"凑满 11 个标签 + 半跑"就算反证通过。
[ "$(grep -c '^VEC ' "$NEG_RUN_LOG" 2>/dev/null || true)" = "$SPEC_VECTORS" ] || fail "neg_vec_line_count"
neg_ids="$(sed -n 's/^VEC \([0-9]\+\) name=.*/\1/p' "$NEG_RUN_LOG" | sort -n | uniq | tr '\n' ' ')"
exp_ids="$(seq -s ' ' 1 "$SPEC_VECTORS") "
[ "$neg_ids" = "$exp_ids" ] || fail "neg_vec_ids"
neg_names="$(sed -n 's/^VEC [0-9]\+ name=\([A-Za-z0-9_]\+\).*/\1/p' "$NEG_RUN_LOG" | tr '\n' ' ')"
[ "${neg_names% }" = "$VEC_NAMES" ] || fail "neg_vec_names"
[ "$(grep -c '^FUNCTIONAL_MMU_VECTORS ' "$NEG_RUN_LOG" 2>/dev/null || true)" = "1" ] || fail "neg_summary_count"
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
