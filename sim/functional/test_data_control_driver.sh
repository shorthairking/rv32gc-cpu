#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_data_control_driver.sh —— F4 数据侧 LSQ 包反证/控制驱动
#==============================================================================
# 依赖 : sim/functional/test_data_control.sh（唯一 PASS 锚点来源）
#
# 做什么（默认全跑）：
#   1) 私有不可变输入冻结：
#      · deps_cur  = 当前树 rtl/back2/{lsq_simple.v,back2_params.vh}；
#      · deps_base = git `201acf61` 的同一对文件（旧树反证）；
#      · frozen/   = 本次包脚本 + TB + scripts/env.sh（两相共用，逐字节冻结）。
#   2) 正控：fixed（新接口 14/92）与 legacy（新 RTL/旧接口 4/12，输入显式驱 0）。
#   3) 旧树反证：old 模式必须复现两个 level 向量 defect=1、fails>0、绝不 PASS、rc=1。
#   4) 合同反证：probe 模式证明“跨 flush 旧完成必须由 Top 丢弃”是必要的（marker 唯一）。
#   5) 自检（私有 fixture，不改正式源）：编译工具缺失 / vvp 非零 / 缺摘要 /
#      日志含 FAIL / 日志含 DEFECT / spec checks 漂移 / 运行中改源触发 SHA 拒 /
#      probe 无 marker 拒。
#   6) SHA：所有哈希捕获原始 rc、校验 64hex、共享清单固定 3 行逐路径；每相前后
#      复核共享/cur/base 不变，变化即拒。
#
# 产物：父 PKGOUT（RV32_FUNCTIONAL_PKG_OUT_DIR）> 本仓库 build/functional/data-control-driver；
#       每相/每自检各自 mktemp 独占；不删除任何文件。
# 用法：bash sim/functional/test_data_control_driver.sh
#==============================================================================
set -u

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'DC_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'DC_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }
PKG_SH="$SELF_DIR/test_data_control.sh"
TB_SH="$SELF_DIR/tb_data_control.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'DC_DRIVER: FAIL reason=auth_root_readlink_failed\n'; exit 1; }

if [ "$#" -ne 0 ]; then
    printf 'DC_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi
[ -f "$PKG_SH" ] || { printf 'DC_DRIVER: FAIL reason=pkg_missing\n'; exit 1; }
[ -f "$TB_SH" ]  || { printf 'DC_DRIVER: FAIL reason=tb_missing\n'; exit 1; }
[ -r "$ENV_SH" ] || { printf 'DC_DRIVER: FAIL reason=env_missing\n'; exit 1; }

ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/data-control-driver}"
case "$(readlink -m -- "$ROOT_RAW")" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) printf 'DC_DRIVER: FAIL reason=out_root_unauthorized root=%s\n' "$ROOT_RAW"; exit 1 ;;
esac
mkdir -p -- "$(readlink -m -- "$ROOT_RAW")" || {
    printf 'DC_DRIVER: FAIL reason=out_root_mkdir_failed\n'; exit 1; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")"
DRV="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || {
    printf 'DC_DRIVER: FAIL reason=mktemp_failed root=%s\n' "$ROOT_NORM"; exit 1; }

DRV_LOG="$DRV/driver.log"
: > "$DRV_LOG" || { printf 'DC_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }
exec 3>>"$DRV_LOG"
note() { printf '%s\n' "$*" >&3; }
fail() {
    note "DRIVER_FAIL reason=$1"
    printf 'DC_DRIVER: FAIL reason=%s run_dir=%s\n' "$1" "$DRV"
    exit 1
}

#==============================================================================
# S. SHA 收口：原 rc 捕获 + 64hex + 路径逐字 + 固定行数
#==============================================================================
validated_sha_output() {  # 原始 stdout 文件已捕获；仅在严格验证后输出 SHA 列
    python3 - "$@" <<'PY'
import os, pathlib, re, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
paths = sys.argv[2:]
if b'\0' in raw or b'\r' in raw:
    print('sha_bytes', file=sys.stderr); raise SystemExit(1)
if not raw.endswith(b'\n'):
    print('sha_unterminated', file=sys.stderr); raise SystemExit(1)
rows = raw.split(b'\n')[:-1]
if len(rows) != len(paths):
    print(f'sha_lines={len(rows)}', file=sys.stderr); raise SystemExit(1)
hashes = []
for i, (row, path) in enumerate(zip(rows, paths), 1):
    m = re.fullmatch(rb'([0-9a-f]{64})  (.*)', row)
    if not m:
        print(f'sha_format line={i}', file=sys.stderr); raise SystemExit(1)
    if m.group(2) != os.fsencode(path):
        print(f'sha_path line={i}', file=sys.stderr); raise SystemExit(1)
    hashes.append(m.group(1).decode())
print(' '.join(hashes), end='')
PY
}
file_sha() {
    local raw rc result
    raw="$(mktemp -- "$DRV/sha-one-XXXXXXXX")" || return 1
    sha256sum -- "$1" >"$raw"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'sha_rc path=%s rc=%s\n' "$1" "$rc" >&3; return 1; }
    result="$(validated_sha_output "$raw" "$1" 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'sha_invalid path=%s reason=%s\n' "$1" "$result" >&3; return 1; }
    [ "${#result}" -eq 64 ] || { printf 'sha_len path=%s\n' "$1" >&3; return 1; }
    printf '%s' "$result"
}
sha_of() {
    local h
    h="$(file_sha "$1")" || fail "sha_failed path=$1"
    [ -n "$h" ] || fail "sha_empty path=$1"
    printf '%s' "$h"
}
need_hash() {
    case "$1" in ""|*[!0-9a-f]*) fail "sha_bad_value path=$2" ;; esac
    [ "${#1}" -eq 64 ] || fail "sha_bad_value path=$2"
}

note "==== test_data_control_driver.sh ===="
note "date      = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT = $REPO_ROOT"
note "DRV       = $DRV"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    note "GIT_HEAD  = $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

#==============================================================================
# A. 私有输入冻结
#==============================================================================
CUR="$DRV/deps_cur"; BASE="$DRV/deps_base"; BASE0="$DRV/deps_base_0da"; FRZ="$DRV/frozen"
BASE_COMMIT="${DC_BASELINE_COMMIT:-201acf61}"
BASE0_COMMIT="${DC_BASELINE_0DA_COMMIT:-0da0e14}"
BASE0_LSQ_SHA_EXPECT="2e084792d05db0d47ed4cc6e329edab9d3dc3b53536cb5c632e10be85b611e6c"
mkdir -p -- "$CUR/rtl/back2" "$BASE/rtl/back2" "$BASE0/rtl/back2" \
              "$FRZ/sim/functional" "$FRZ/scripts" \
    || fail "snapshot_mkdir_failed"
cp -- "$REPO_ROOT/rtl/back2/lsq_simple.v" "$CUR/rtl/back2/lsq_simple.v" || fail "cur_lsq_copy"
cp -- "$REPO_ROOT/rtl/back2/back2_params.vh" "$CUR/rtl/back2/back2_params.vh" || fail "cur_hdr_copy"
git -C "$REPO_ROOT" cat-file -e "${BASE_COMMIT}^{commit}" 2>>"$DRV_LOG" \
    || fail "baseline_commit_missing commit=$BASE_COMMIT"
git -C "$REPO_ROOT" show "${BASE_COMMIT}:rtl/back2/lsq_simple.v" > "$BASE/rtl/back2/lsq_simple.v" \
    || fail "base_lsq_extract"
git -C "$REPO_ROOT" show "${BASE_COMMIT}:rtl/back2/back2_params.vh" > "$BASE/rtl/back2/back2_params.vh" \
    || fail "base_hdr_extract"
git -C "$REPO_ROOT" cat-file -e "${BASE0_COMMIT}^{commit}" 2>>"$DRV_LOG" \
    || fail "base0da_commit_missing commit=$BASE0_COMMIT"
git -C "$REPO_ROOT" show "${BASE0_COMMIT}:rtl/back2/lsq_simple.v" > "$BASE0/rtl/back2/lsq_simple.v" \
    || fail "base0da_lsq_extract"
git -C "$REPO_ROOT" show "${BASE0_COMMIT}:rtl/back2/back2_params.vh" > "$BASE0/rtl/back2/back2_params.vh" \
    || fail "base0da_hdr_extract"
cp -- "$PKG_SH" "$FRZ/sim/functional/test_data_control.sh" || fail "frozen_pkg_copy"
cp -- "$TB_SH"  "$FRZ/sim/functional/tb_data_control.sv"  || fail "frozen_tb_copy"
cp -- "$ENV_SH" "$FRZ/scripts/env.sh" || fail "frozen_env_copy"
chmod 444 -- "$CUR/rtl/back2/lsq_simple.v" "$CUR/rtl/back2/back2_params.vh" \
             "$BASE/rtl/back2/lsq_simple.v" "$BASE/rtl/back2/back2_params.vh" \
             "$BASE0/rtl/back2/lsq_simple.v" "$BASE0/rtl/back2/back2_params.vh" \
             "$FRZ/sim/functional/test_data_control.sh" \
             "$FRZ/sim/functional/tb_data_control.sv" "$FRZ/scripts/env.sh" \
    || fail "chmod_failed"
cmp -s -- "$PKG_SH" "$FRZ/sim/functional/test_data_control.sh" || fail "frozen_pkg_mismatch"
cmp -s -- "$TB_SH"  "$FRZ/sim/functional/tb_data_control.sv"  || fail "frozen_tb_mismatch"
cmp -s -- "$ENV_SH" "$FRZ/scripts/env.sh" || fail "frozen_env_mismatch"

shared_sha_of() {
    local root="$1" raw rc result
    raw="$(mktemp -- "$DRV/sha-shared-XXXXXXXX")" || return 1
    sha256sum -- "$root/sim/functional/test_data_control.sh" \
                  "$root/sim/functional/tb_data_control.sv" \
                  "$root/scripts/env.sh" >"$raw" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'shared_sha_rc=%s\n' "$rc" >&3; return 1; }
    result="$(validated_sha_output "$raw" "$root/sim/functional/test_data_control.sh" \
        "$root/sim/functional/tb_data_control.sv" "$root/scripts/env.sh" 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'shared_sha_invalid reason=%s\n' "$result" >&3; return 1; }
    printf '%s ' "$result"
}

CUR_LSQ_SHA="$(sha_of "$CUR/rtl/back2/lsq_simple.v")"; need_hash "$CUR_LSQ_SHA" cur_lsq
CUR_HDR_SHA="$(sha_of "$CUR/rtl/back2/back2_params.vh")"; need_hash "$CUR_HDR_SHA" cur_hdr
BASE_LSQ_SHA="$(sha_of "$BASE/rtl/back2/lsq_simple.v")"; need_hash "$BASE_LSQ_SHA" base_lsq
BASE_HDR_SHA="$(sha_of "$BASE/rtl/back2/back2_params.vh")"; need_hash "$BASE_HDR_SHA" base_hdr
BASE0_LSQ_SHA="$(sha_of "$BASE0/rtl/back2/lsq_simple.v")"; need_hash "$BASE0_LSQ_SHA" base0da_lsq
BASE0_HDR_SHA="$(sha_of "$BASE0/rtl/back2/back2_params.vh")"; need_hash "$BASE0_HDR_SHA" base0da_hdr
[ "$BASE0_LSQ_SHA" = "$BASE0_LSQ_SHA_EXPECT" ] || fail "base0da_lsq_sha_mismatch got=$BASE0_LSQ_SHA"
PKG_SHA="$(sha_of "$FRZ/sim/functional/test_data_control.sh")"; need_hash "$PKG_SHA" frozen_pkg
TB_SHA="$(sha_of "$FRZ/sim/functional/tb_data_control.sv")"; need_hash "$TB_SHA" frozen_tb
ENV_SHA="$(sha_of "$FRZ/scripts/env.sh")"; need_hash "$ENV_SHA" frozen_env
SHARED_SHA_PRE="$(shared_sha_of "$FRZ")" || fail "shared_sha_pre"
[[ "$SHARED_SHA_PRE" =~ ^[0-9a-f]{64}\ [0-9a-f]{64}\ [0-9a-f]{64}\ $ ]] \
    || fail "shared_sha_bad_value"
note "CUR_LSQ_SHA    = $CUR_LSQ_SHA"
note "CUR_HDR_SHA    = $CUR_HDR_SHA"
note "BASE201_COMMIT = $BASE_COMMIT"
note "BASE201_LSQ_SHA= $BASE_LSQ_SHA"
note "BASE201_HDR_SHA= $BASE_HDR_SHA"
note "BASE0DA_COMMIT = $BASE0_COMMIT"
note "BASE0DA_LSQ_SHA= $BASE0_LSQ_SHA"
note "BASE0DA_HDR_SHA= $BASE0_HDR_SHA"
note "PKG_SHA        = $PKG_SHA"
note "TB_SHA         = $TB_SHA"
note "ENV_SHA        = $ENV_SHA"
note "SHARED_SHA     = $SHARED_SHA_PRE"
note "MATRIX_INPUTS  = pkg:$PKG_SHA tb:$TB_SHA env:$ENV_SHA cur:$CUR_LSQ_SHA/$CUR_HDR_SHA base201:$BASE_LSQ_SHA/$BASE_HDR_SHA base0da:$BASE0_LSQ_SHA/$BASE0_HDR_SHA"

check_inputs_unchanged() {
    local now
    now="$(shared_sha_of "$FRZ")" || fail "shared_sha_now"
    [ "$now" = "$SHARED_SHA_PRE" ] || fail "shared_inputs_changed"
    [ "$(sha_of "$CUR/rtl/back2/lsq_simple.v")" = "$CUR_LSQ_SHA" ] || fail "cur_lsq_changed"
    [ "$(sha_of "$CUR/rtl/back2/back2_params.vh")" = "$CUR_HDR_SHA" ] || fail "cur_hdr_changed"
    [ "$(sha_of "$BASE/rtl/back2/lsq_simple.v")" = "$BASE_LSQ_SHA" ] || fail "base_lsq_changed"
    [ "$(sha_of "$BASE/rtl/back2/back2_params.vh")" = "$BASE_HDR_SHA" ] || fail "base_hdr_changed"
    [ "$(sha_of "$BASE0/rtl/back2/lsq_simple.v")" = "$BASE0_LSQ_SHA" ] || fail "base0da_lsq_changed"
    [ "$(sha_of "$BASE0/rtl/back2/back2_params.vh")" = "$BASE0_HDR_SHA" ] || fail "base0da_hdr_changed"
}

#==============================================================================
# B. 跑一相（冻结包 + 私有 PKGOUT）
#==============================================================================
PHASE_N=0
run_phase() {  # run_phase <name> <dut_root> <expect> <extra_env...>
    local name="$1"; local dut="$2"; local expect="$3"; shift 3
    local outdir log rc
    PHASE_N=$((PHASE_N + 1))
    outdir="$DRV/frozen/build/functional/$name"
    mkdir -p -- "$outdir" || fail "phase_out_mkdir_$name"
    log="$DRV/$name.log"
    env RV32_FUNCTIONAL_PKG_OUT_DIR="$outdir" DUT_ROOT="$dut" DC_EXPECT="$expect" \
        "$@" bash "$FRZ/sim/functional/test_data_control.sh" > "$log" 2>&1
    rc=$?
    note "PHASE $name rc=$rc log=$log"
    RC=$rc
}

pkg_field() {
    awk -v k="$2" '/^DC_VECTORS /{
        for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == k) { print a[2]; exit } }
    }' "$1"
}

#==============================================================================
# C. 正控 fixed（新接口全量）
#==============================================================================
run_phase fixed "$CUR" fixed
[ "$RC" = "0" ] || fail "fixed_rc=$RC"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$DRV/fixed.log" || fail "fixed_no_pass"
[ "$(pkg_field "$DRV/fixed.log" total)" = "16" ] || fail "fixed_total"
[ "$(pkg_field "$DRV/fixed.log" checks)" = "113" ] || fail "fixed_checks"
[ "$(pkg_field "$DRV/fixed.log" fails)" = "0" ] || fail "fixed_fails"
[ "$(pkg_field "$DRV/fixed.log" defect)" = "0" ] || fail "fixed_defect"
[ "$(pkg_field "$DRV/fixed.log" xz)" = "0" ] || fail "fixed_xz"
check_inputs_unchanged

#==============================================================================
# D. 正控 legacy（新 RTL / 旧接口，新输入显式驱 0）
#==============================================================================
run_phase legacy "$CUR" legacy
[ "$RC" = "0" ] || fail "legacy_rc=$RC"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$DRV/legacy.log" || fail "legacy_no_pass"
[ "$(pkg_field "$DRV/legacy.log" total)" = "5" ] || fail "legacy_total"
[ "$(pkg_field "$DRV/legacy.log" checks)" = "19" ] || fail "legacy_checks"
check_inputs_unchanged

#==============================================================================
# E. 旧树反证（两条独立基线：201acf61 与 0da0e14/文件sha 2e084...）
#    必须因**重复 take** 具体 reason 红：两个 level 向量 defect=1；控制向量全绿；
#    绝不 PASS；新接口数据语义在旧树无端口，不做覆盖声明。
#==============================================================================
run_phase old201 "$BASE" old
[ "$RC" = "1" ] || fail "old201_rc=$RC"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$DRV/old201.log" && fail "old201_printed_pass"
[ "$(pkg_field "$DRV/old201.log" defect)" = "2" ] || fail "old201_defect"
[ "$(pkg_field "$DRV/old201.log" fails)" -gt 0 ] || fail "old201_fails"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: DEFECT_REPRODUCED root=cdq_take_duplicate' "$DRV/old201.log" \
    || fail "old201_marker"
grep -q 'old_tree_defects_confirmed' "$DRV/old201.log" || fail "old201_reason"
check_inputs_unchanged

run_phase old0da "$BASE0" old
[ "$RC" = "1" ] || fail "old0da_rc=$RC"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$DRV/old0da.log" && fail "old0da_printed_pass"
[ "$(pkg_field "$DRV/old0da.log" defect)" = "2" ] || fail "old0da_defect"
[ "$(pkg_field "$DRV/old0da.log" fails)" -gt 0 ] || fail "old0da_fails"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: DEFECT_REPRODUCED root=cdq_take_duplicate' "$DRV/old0da.log" \
    || fail "old0da_marker"
grep -q 'old_tree_defects_confirmed' "$DRV/old0da.log" || fail "old0da_reason"
note "BASELINE_ROW commit=$BASE0_COMMIT lsq_sha=$BASE0_LSQ_SHA result=DEFECT_REPRODUCED defect=2"
note "BASELINE_ROW commit=$BASE_COMMIT lsq_sha=$BASE_LSQ_SHA result=DEFECT_REPRODUCED defect=2"
check_inputs_unchanged

#==============================================================================
# F. 合同反证（probe：跨 flush 旧完成被新槽接受 ⇒ kill-drain 合同必要）
#==============================================================================
run_phase probe "$CUR" probe
[ "$RC" = "0" ] || fail "probe_rc=$RC"
[ "$(grep -cxF 'FUNCTIONAL_DATA_CONTROL: PROBE_CONFIRMED' "$DRV/probe.log" || true)" = "1" ] \
    || fail "probe_marker"
grep -qxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$DRV/probe.log" && fail "probe_printed_pass"
check_inputs_unchanged

#==============================================================================
# G. 自检（私有 fixture）
#==============================================================================
ST=0
st_begin() { ST=$((ST + 1)); note "SELFTEST $ST $1"; }
st_fail() { fail "selftest_$ST:$1"; }

#   私有 fixture 包（可改 spec / TB），其余与冻结包同内容
make_fixture() { # make_fixture <dir>
    local f="$1"
    mkdir -p -- "$f/sim/functional" "$f/scripts" || fail "fixture_mkdir"
    cp -- "$FRZ/sim/functional/test_data_control.sh" "$f/sim/functional/" || fail "fixture_pkg"
    cp -- "$FRZ/sim/functional/tb_data_control.sv" "$f/sim/functional/" || fail "fixture_tb"
    cp -- "$ENV_SH" "$f/scripts/env.sh" || fail "fixture_env"
    printf '%s' "$f"
}
run_fixture() { # run_fixture <fdir> <name> <expect> <overrides...>
    local f="$1" name="$2" expect="$3"; shift 3
    local outdir="$f/build/functional/$name" rc
    mkdir -p -- "$outdir" || fail "fixture_out_mkdir"
    env RV32_FUNCTIONAL_PKG_OUT_DIR="$outdir" DUT_ROOT="$CUR" DC_EXPECT="$expect" \
        "$@" bash "$f/sim/functional/test_data_control.sh" \
        > "$DRV/$name.log" 2>&1
    rc=$?
    note "FIXTURE $name rc=$rc"
    RC=$rc
}

#   假 vvp 工具
FAKE="$DRV/fake"; mkdir -p -- "$FAKE" || fail "fake_mkdir"
cat > "$FAKE/vvp_nonzero.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
cat > "$FAKE/vvp_fail.sh" <<'EOF'
#!/usr/bin/env bash
"$REAL_VVP" "$@" || exit $?
printf 'FAIL injected\n'
EOF
cat > "$FAKE/vvp_defect.sh" <<'EOF'
#!/usr/bin/env bash
"$REAL_VVP" "$@" || exit $?
printf 'DEFECT_REPRODUCED injected\n'
EOF
cat > "$FAKE/vvp_nosummary.sh" <<'EOF'
#!/usr/bin/env bash
"$REAL_VVP" "$@" | grep -v '^DC_VECTORS ' || true
EOF
cat > "$FAKE/vvp_nomarker.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/vvp_sha.sh" <<'EOF'
#!/usr/bin/env bash
# 运行中改共享 TB 源码 ⇒ 包的运行前后 SHA 必须拒
printf '\n// sha mutation\n' >> "$SHA_TB"
exit 0
EOF
chmod +x "$FAKE"/*.sh || fail "fake_chmod"
REAL_VVP="$(bash -c '. "$1"; printf %s "$RV32_VVP"' _ "$ENV_SH")"
[ -x "$REAL_VVP" ] || fail "real_vvp_missing"

#   G1 工具缺失
st_begin tool_missing
run_phase t_tool "$CUR" fixed RV32_IVERILOG=/nonexistent/iverilog
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'tool_missing' "$DRV/t_tool.log" || st_fail "reason"

#   G2 vvp 非零
st_begin vvp_nonzero
run_phase t_nonzero "$CUR" fixed RV32_VVP="$FAKE/vvp_nonzero.sh" REAL_VVP="$REAL_VVP"
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'run_rc=' "$DRV/t_nonzero.log" || st_fail "reason"

#   G3 缺摘要
st_begin no_summary
run_phase t_nosum "$CUR" fixed RV32_VVP="$FAKE/vvp_nosummary.sh" REAL_VVP="$REAL_VVP"
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'summary_count=' "$DRV/t_nosum.log" || st_fail "reason"

#   G4 日志含 FAIL（fixed 拒）
st_begin fail_text
run_phase t_fail "$CUR" fixed RV32_VVP="$FAKE/vvp_fail.sh" REAL_VVP="$REAL_VVP"
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'log_has_FAIL=' "$DRV/t_fail.log" || st_fail "reason"

#   G5 日志含 DEFECT_REPRODUCED（fixed 拒）
st_begin defect_text
run_phase t_defect "$CUR" fixed RV32_VVP="$FAKE/vvp_defect.sh" REAL_VVP="$REAL_VVP"
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'log_has_defect_reproduced=' "$DRV/t_defect.log" || st_fail "reason"

#   G6 spec checks 漂移
st_begin spec_drift
FX="$(make_fixture "$DRV/fixture_spec")"
sed -i '0,/SPEC_CHECKS=113/s//SPEC_CHECKS=112/' "$FX/sim/functional/test_data_control.sh" \
    || fail "fixture_sed"
run_fixture "$FX" t_spec fixed
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'summary_checks=' "$DRV/t_spec.log" || st_fail "reason"

#   G7 运行中改 TB ⇒ SHA 拒
st_begin source_changed
FX="$(make_fixture "$DRV/fixture_sha")"
chmod 644 "$FX/sim/functional/tb_data_control.sv" || fail "fixture_sha_chmod"
run_fixture "$FX" t_sha fixed RV32_VVP="$FAKE/vvp_sha.sh" SHA_TB="$FX/sim/functional/tb_data_control.sv"
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'source_changed_during_run' "$DRV/t_sha.log" || st_fail "reason"

#   G8 probe 无 marker ⇒ 拒
st_begin probe_no_marker
run_phase t_probe "$CUR" probe RV32_VVP="$FAKE/vvp_nomarker.sh"
[ "$RC" = "1" ] || st_fail "not_rejected"
grep -q 'stale_probe_marker_count=0' "$DRV/t_probe.log" || st_fail "reason"

check_inputs_unchanged
note "SELFTESTS passed = $ST"
note "DC_DRIVER: PASS phases=5 selftests=$ST"
printf 'DC_DRIVER: PASS phases=5 selftests=%s run_dir=%s\n' "$ST" "$DRV"
exit 0
