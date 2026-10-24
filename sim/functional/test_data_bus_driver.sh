#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_data_bus_driver.sh —— F4 数据总线语义定向驱动
#==============================================================================
# 归属 : F4（数据 PMP/PMA、非投机设备读、kill-drain）—— 产品源 = rtl/top/core_top_2b.v
# 用法 : bash sim/functional/test_data_bus_driver.sh
#        bash sim/functional/test_data_bus_driver.sh --self-test   # 只验判据
#        bash sim/functional/test_data_bus_driver.sh --extension-only # 只跑扩展CPU场景组
#
# 做什么（fail-closed）:
#   1) 私有**不可变快照**：RTL + TB/driver/entry/env + frozen profile .S sources。
#      快照前后各记一次全量 SHA256 清单，必须逐字节相同；profile HEX 只从 SNAP .S 汇编。
#   2) 在 run 目录内用真实工具链汇编 RV32 程序（baseline inline；profile .S 在 SNAP）：
#      PMP 允许/拒绝/边界、非 head 设备 defer、设备读 IRQ 自持、kill/drain 后同 tag 复用。
#   3) 快照 root 内相对 -I 编译 `tb_data_bus_semantics`；程序 hex 绝对路径用 -P 注入；
#      `cont` 地址用 nm 取出后以 +CONT= 运行时注入（TB 在 KILL 设备 AR 后强制
#      trap flush + 重定向，验证迟到旧 R 被 drain 吞掉、新 tag 不被污染）。
#   4) 真跑一次：rc=0、日志非空、唯一整行锚点 `TB_DATA_BUS_SEMANTICS: PASS` 恰好 1 次、
#      无 FAIL/[^A-Za-z]XZ/UNKNOWN；TB 内已含计数/顺序硬断言。
#   5) 汇总唯一整行 `FUNCTIONAL_DATA_BUS: PASS`。
#
# 环境：只从 scripts/env.sh 取工具；产物只落 build/functional/data-bus/run-XXXXXXXX/
#       （父 PKGOUT 由 RV32_FUNCTIONAL_PKG_OUT_DIR 覆盖，须在 build/functional 下）。
#==============================================================================
set -u

MODE="spec"
if [ "$#" -gt 1 ]; then printf 'FUNCTIONAL_DATA_BUS: FAIL reason=unknown_arg\n'; exit 1; fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --self-test) MODE="self-test" ;;
        --extension-only) MODE="extension-only" ;;
        --extension-case-1) MODE="extension-case-1" ;;
        --extension-cases-2-5) MODE="extension-cases-2-5" ;;
        --extension-cases-6-9) MODE="extension-cases-6-9" ;;
        --extension-case-10) MODE="extension-case-10" ;;
        --extension-case-11) MODE="extension-case-11" ;;
        --extension-cases-12-13) MODE="extension-cases-12-13" ;;
        --extension-case-14) MODE="extension-case-14" ;;
        --extension-case-15) MODE="extension-case-15" ;;
        --extension-case-16) MODE="extension-case-16" ;;
        --extension-cases-14-16) MODE="extension-cases-14-16" ;;
        --profile-source-build-only) MODE="profile-source-build-only" ;;
        --profile-targeted-only) MODE="profile-targeted-only" ;;
        *) printf 'FUNCTIONAL_DATA_BUS: FAIL reason=unknown_arg arg=%s\n' "$1"; exit 1 ;;
    esac
fi

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_BUS: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_BUS: FAIL reason=repo_root_unresolved\n'; exit 1; }
ENV_SH="$REPO_ROOT/scripts/env.sh"
TB_REL="sim/functional/tb_data_bus_semantics.sv"
PTW_A_REL="sim/functional/prog/data_bus_ptw_tr_first_ready.S"
PTW_B_REL="sim/functional/prog/data_bus_ptw_if_owner_data_drain.S"
ANCHOR='TB_DATA_BUS_SEMANTICS: PASS'
NEG_ANCHOR='FUNCTIONAL_DATA_BUS_NEGATIVE: PASS'

RUN_DIR=""; RUN_LOG=""
emit_fail() {
    if [ "$MODE" = "self-test" ]; then
        printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    elif [ "$MODE" = "profile-source-build-only" ] || [ "$MODE" = "profile-targeted-only" ]; then
        printf 'DATA_BUS_PROFILE_TARGETED: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    elif [ "$MODE" = "extension-only" ] || [ "$MODE" = "extension-case-1" ] || [ "$MODE" = "extension-cases-2-5" ] || [ "$MODE" = "extension-cases-6-9" ] || [ "$MODE" = "extension-case-10" ] || [ "$MODE" = "extension-case-11" ] || [ "$MODE" = "extension-cases-12-13" ] || [ "$MODE" = "extension-case-14" ] || [ "$MODE" = "extension-case-15" ] || [ "$MODE" = "extension-case-16" ] || [ "$MODE" = "extension-cases-14-16" ]; then
        printf 'DATA_BUS_EXTENSION_ONLY: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    else
        printf 'FUNCTIONAL_DATA_BUS: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_DIR:-<none>}"
    fi
    exit 1
}

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail auth_root
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/data-bus}"
is_auth() { case "$1" in "$AUTH_ROOT"|"$AUTH_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail out_root
is_auth "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM"
mkdir -p -- "$ROOT_NORM" || emit_fail out_root_mkdir
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail out_root_recheck
is_auth "$ROOT_NORM" || emit_fail out_root_escape
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail mktemp
RUN_LOG="$RUN_DIR/test_data_bus_driver.log"
printf 'DATA_BUS_RUN_DIR=%s\n' "$RUN_DIR"
: > "$RUN_LOG" || emit_fail run_log

[ -r "$ENV_SH" ] || emit_fail env_sh_missing
command -v python3 >/dev/null 2>&1 || emit_fail python3_missing
command -v sha256sum >/dev/null 2>&1 || emit_fail sha_missing

#------------------------------------------------------------------------------
# --self-test：只验本脚本判据（唯一锚点 / 非零 rc / 超时 / 坏 token / 缺头）
#------------------------------------------------------------------------------
if [ "$MODE" = "self-test" ]; then
    CP_OK=0; CP_N=0
    FX="$RUN_DIR/fixtures"; mkdir -p -- "$FX"
    check_reject() {
        CP_N=$((CP_N+1))
        if eval "$2"; then echo "CP $1 got=accept want=reject REJECTED" >> "$RUN_LOG"
        else CP_OK=$((CP_OK+1)); echo "CP $1 got=reject want=reject pass" >> "$RUN_LOG"; fi
    }
    printf 'no anchor\n' > "$FX/noanchor.log"
    check_reject noanchor "[ \"\$(grep -cxF '$ANCHOR' '$FX/noanchor.log' || true)\" = 1 ]"
    printf '%s\n%s\n' "$ANCHOR" "$ANCHOR" > "$FX/dupanchor.log"
    check_reject dupanchor "[ \"\$(grep -cxF '$ANCHOR' '$FX/dupanchor.log' || true)\" = 1 ]"
    printf '%s\nFAIL: boom\n' "$ANCHOR" > "$FX/failtok.log"
    check_reject failtok "[ \"\$(grep -cE 'FAIL|[^A-Za-z]XZ|UNKNOWN' '$FX/failtok.log' || true)\" = 0 ]"
    FB="$RUN_DIR/fakebin"; mkdir -p -- "$FB"
    printf '#!/bin/sh\nexit 3\n' > "$FB/vvp_rc"; chmod +x "$FB/vvp_rc"
    printf '#!/bin/sh\nsleep 5\n' > "$FB/vvp_sleep"; chmod +x "$FB/vvp_sleep"
    : > "$FX/dummy.log"
    check_reject nonzero_rc "[ \"\$(timeout 2 '$FB/vvp_rc' >'$FX/dummy.log' 2>&1; echo \$?)\" = 0 ]"
    check_reject timeout_rc "[ \"\$(timeout 1 '$FB/vvp_sleep' >'$FX/dummy.log' 2>&1; echo \$?)\" != 124 ]"
    # 缺头快照必须被拒（私有 fixture，不动正式源）
    mkdir -p -- "$FX/snap/rtl/pkg"
    check_reject snapshot_missing_header "[ -f '$FX/snap/rtl/pkg/rv32_defs.vh' ]"
    # Exercise the real compile/run/source-snapshot caller with isolated fake simulators.
    # Assembly, HEX generation, source hashing, compile CWD, run RC and anchors still use
    # the production driver path; fake tools only replace Icarus/vvp responses.
    FB="$RUN_DIR/fakebin"; mkdir -p -- "$FB"
    REAL_SHA_BIN="$(command -v sha256sum)"
    cat > "$FB/sha256sum" <<'SH'
#!/usr/bin/env bash
raw="${RV32_FUNCTIONAL_PKG_OUT_DIR}/sha-fixture.raw"
count_file="${RV32_FUNCTIONAL_PKG_OUT_DIR}/sha-fixture.count"
count=0; [ -f "$count_file" ] && read -r count < "$count_file"
count=$((count + 1)); printf '%s\n' "$count" > "$count_file"
"$REAL_SHA_BIN" "$@" > "$raw"
rc=$?
target_hit=0
case "${FAKE_SHA_TARGET:-none}:$count" in caller:1|source:7) target_hit=1 ;; esac
if [ "$target_hit" -eq 1 ]; then
  case "${FAKE_SHA_CASE:-ok}" in
    rc9) cat "$raw"; exit 9 ;;
    badhex) python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); b=p.read_bytes(); p.write_bytes(b"g"+b[1:])' "$raw" ;;
    nofinal) python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); b=p.read_bytes(); p.write_bytes(b[:-1])' "$raw" ;;
    extralf) printf '\n' >> "$raw" ;;
    wrongpath) python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); b=p.read_bytes(); a,sep,c=b.partition(b"  "); p.write_bytes(a+sep+b"wrong/path\n")' "$raw" ;;
  esac
fi
cat "$raw"
exit "$rc"
SH
    cat > "$FB/iverilog" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then shift; out="${1:-}"; fi
    shift || true
done
[ -n "$out" ] || exit 71
case "${FAKE_IV_CASE:-ok}" in
  rc9) exit 9 ;;
  noartifact) exit 0 ;;
esac
printf 'fake-vvp-artifact\n' > "$out"
SH
    cat > "$FB/vvp" <<'SH'
#!/usr/bin/env bash
ext_id=""; schema_probe=""; pmp_repeat=0; profile_b=0
for arg in "$@"; do
  case "$arg" in
    +EXT=*) ext_id="${arg#'+EXT='}" ;;
    +SCHEMAPROBE=*) schema_probe="${arg#'+SCHEMAPROBE='}" ;;
    +PROFILE_B_CACHED_DATA) profile_b=1 ;;
    +PMP_REPEAT=*) pmp_repeat="${arg#'+PMP_REPEAT='}" ;;
    +AWSTALL=*|+WSTALL=*) printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
    +WPROBE=UART_LANE) printf 'FAIL: UART WSTRB expected=0001 got=0010\n'; exit 1 ;;
    +WPROBE=UART_WRONG|+WPROBE=UART_ZERO) printf 'FAIL: ecall/maint UART writes injected\n'; exit 1 ;;
    +CTRLPROBE=*) printf 'FAIL: active device-read control X/Z injected\n'; exit 1 ;;
  esac
done
if [ -z "$ext_id" ]; then
  case "$schema_probe" in
    UARTX) printf 'FAIL: ecall/maint UART writes injected\n'; exit 1 ;;
    NCHK0|NCHKX) printf 'FAIL: fixed schema requires nchk=16 injected\n'; exit 1 ;;
  esac
fi
if [ -n "$ext_id" ]; then
  if [ "${FAKE_VVP_CASE:-}" = late_caller_extonly ]; then
    printf '// late caller mutation in extension-only mode\n' >> "$CALLER_ROOT/sim/functional/test_data_bus_driver.sh"
  fi
  if [ "$ext_id" = "11" ] && [ "$pmp_repeat" = "1" ]; then
    printf 'FAIL: extension old store B drain before unique PMP CSR+4 refetch target\n'; exit 1
  fi
  case "$schema_probe" in
    STVAL0|STVALPA|EXTRA_M|EXTRA_S)
      if [ "$ext_id" = "2" ]; then printf 'FAIL: extension S trap count/stval id=2\n'; exit 1; fi ;;
  esac
  if [ "$ext_id" = "17" ]; then
    printf 'PROFILE_A_TRAP_COUNTS M=0 S=0 lifetime=1 tag_reuse=1 ghost=0\n'
    printf 'PROFILE_A_GHOST_BOUNDARIES kill=1 stale=1 idle=1 reuse=1 active=0 neg_mode=0 neg_used=0\n'
  elif [ "$ext_id" = "18" ] && [ "$profile_b" = "1" ]; then
    printf 'PROFILE_B_POST_STALE_IF_STILL_BUSY t=1 owner_va=80400080 request_input_va=80400020\n'
    printf 'PROFILE_B_POST_PTE_REQ t=1 n=0 va=80400080 pa=8001b804\n'
    printf 'PROFILE_B_POST_PTE_DONE t=2 pa=8001b804 pte=20007801\n'
    printf 'PROFILE_B_POST_PTE_REQ t=3 n=1 va=80400080 pa=8001e000\n'
    printf 'PROFILE_B_POST_PTE_DONE t=4 pa=8001e000 pte=20000ccf\n'
    printf 'PROFILE_B_LIFETIME_TRAP_POST summary owner_reuse=0 ghost=0 life=1 M=0 S=0 pte_req=2 pte_rsp=2 root_done=1 leaf_done=1 walk_done=1 seqerr=0 pending=0 complete=1\n'
    printf 'PROFILE_B_GHOST_BOUNDARIES kill=1 stale=1 idle=1 reuse=0 active=1 neg_mode=0 neg_used=0\n'
  fi
  printf 'DATA_BUS_EXTENSION id=%s PASS\n' "$ext_id"; exit 0
fi
case "${FAKE_VVP_CASE:-ok}" in
  ok) printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
  late_snapshot) printf '# late snapshot drift\n' >> "$(dirname -- "$1")/src/scripts/env.sh"; printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
  late_source_env) printf '# late source env drift\n' >> "$DUT_ROOT/scripts/env.sh"; printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
  late_source_aux) printf '// late source aux drift\n' >> "$DUT_ROOT/sim/functional/tb_data_bus_semantics.sv"; printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
   late_caller_aux) printf '# late actual caller profile-source drift\n' >> "$CALLER_ROOT/sim/functional/prog/data_bus_ptw_tr_first_ready.S"; printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
  late_snapshot_aux) printf '// late snapshot aux drift\n' >> "$(dirname -- "$1")/src/sim/functional/tb_data_bus_semantics.sv"; printf 'TB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
  rc9) printf 'fake rc9\n'; exit 9 ;;
  badtoken) printf 'TB_DATA_BUS_SEMANTICS: PASS\nFAIL injected\n'; exit 0 ;;
  noanchor) printf 'no expected anchor\n'; exit 0 ;;
  dupanchor) printf 'TB_DATA_BUS_SEMANTICS: PASS\nTB_DATA_BUS_SEMANTICS: PASS\n'; exit 0 ;;
  timeout) sleep 5; exit 0 ;;
  *) exit 72 ;;
esac
SH
    chmod +x "$FB/sha256sum" "$FB/iverilog" "$FB/vvp"
    PROBE_SOURCE_BASE="${DUT_ROOT:-$REPO_ROOT}"
    PROBE_SOURCE_BASE="$(cd -- "$PROBE_SOURCE_BASE" 2>/dev/null && pwd -P)" || emit_fail self_probe_source_root
    make_probe_source_root() {
        local root="$1"
        mkdir -p -- "$root/rtl" "$root/sim/functional/prog" "$root/scripts"
        cp -a -- "$PROBE_SOURCE_BASE/rtl/." "$root/rtl/"
        cp -p -- "$REPO_ROOT/sim/functional/tb_data_bus_semantics.sv" \
            "$REPO_ROOT/sim/functional/test_data_bus_driver.sh" \
            "$REPO_ROOT/sim/functional/test_data_bus.sh" "$root/sim/functional/"
        cp -p -- "$REPO_ROOT/$PTW_A_REL" "$REPO_ROOT/$PTW_B_REL" "$root/sim/functional/prog/"
        cp -p -- "$REPO_ROOT/scripts/env.sh" "$root/scripts/env.sh"
    }
    DRIVER_TEST_ROOT="$RUN_DIR/fixtures/冻结 DUT 树"
    SRC_DRIFT_ENV="$RUN_DIR/fixtures/source-drift-env"
    SRC_DRIFT_AUX="$RUN_DIR/fixtures/source-drift-aux"
    CALLER_DRIFT_ROOT="$RUN_DIR/fixtures/actual-caller-drift"
    CALLER_DRIFT_EXTONLY_ROOT="$RUN_DIR/fixtures/actual-caller-extonly-drift"
    make_probe_source_root "$DRIVER_TEST_ROOT"
    make_probe_source_root "$SRC_DRIFT_ENV"
    make_probe_source_root "$SRC_DRIFT_AUX"
    make_probe_source_root "$CALLER_DRIFT_ROOT"
    make_probe_source_root "$CALLER_DRIFT_EXTONLY_ROOT"
    run_driver_case() {
        local name="$1" mode="$2" want="$3" timeout_s="${4:-10}" ivmode="${5:-ok}" shamode="${6:-ok}" droot="${7:-$DRIVER_TEST_ROOT}" rc=0
        local sha_target="${11:-none}"
        local pkgout="${8:-$RUN_DIR/fixtures/driver-$name-pkg}"
        local caller_script="${9:-$SELF_DIR/test_data_bus_driver.sh}"
        local driver_arg="${10:-}"
        local caller_root="$(cd -- "$(dirname -- "$caller_script")/../.." && pwd -P)"
        local out="$RUN_DIR/fixtures/driver-$name.out"
        local driver_args=(); [ -n "$driver_arg" ] && driver_args+=("$driver_arg")
        mkdir -p -- "$pkgout"
        env PATH="$FB:$PATH" REAL_SHA_BIN="$REAL_SHA_BIN" FAKE_SHA_CASE="$shamode" \
            FAKE_SHA_TARGET="$sha_target" DUT_ROOT="$droot" CALLER_ROOT="$caller_root" \
            RV32_IVERILOG="$FB/iverilog" RV32_VVP="$FB/vvp" FAKE_VVP_CASE="$mode" FAKE_IV_CASE="$ivmode" \
            TIMEOUT_RUN_S="$timeout_s" RV32_FUNCTIONAL_PKG_OUT_DIR="$pkgout" \
            bash "$caller_script" "${driver_args[@]}" > "$out" 2>&1 || rc=$?
        case "$name" in good*)
            [ "$rc" -eq 0 ] && [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$out" || true)" = 1 ] &&
            [ "$(grep -cE 'FAIL|DEFECT' "$out" || true)" = 0 ] || return 1
            ;;
        *)
            [ "$rc" -ne 0 ] && grep -qF "reason=$want" "$out" &&
            [ "$(grep -cE '(^|[[:space:]])(FUNCTIONAL_DATA_BUS|TB_DATA_BUS_SEMANTICS): PASS' "$out" || true)" = 0 ] || return 1
            ;;
        esac
        return 0
    }
    run_driver_case good ok none || emit_fail self_driver_good
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_driver_good pass' >> "$RUN_LOG"
    run_driver_case good_unicode_root ok good 10 ok ok "$DRIVER_TEST_ROOT" "$RUN_DIR/fixtures/pkg root 测试" \
        || emit_fail self_unicode_root
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_unicode_root pass' >> "$RUN_LOG"
    run_driver_case actual_rc9 rc9 run_rc=9 || emit_fail self_driver_rc9
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_driver_rc9 pass' >> "$RUN_LOG"
    run_driver_case actual_badtoken badtoken bad_tokens=1 || emit_fail self_driver_badtoken
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_driver_badtoken pass' >> "$RUN_LOG"
    run_driver_case actual_noanchor noanchor anchor=0 || emit_fail self_driver_noanchor
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_driver_noanchor pass' >> "$RUN_LOG"
    run_driver_case actual_dupanchor dupanchor anchor=2 || emit_fail self_driver_dupanchor
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_driver_dupanchor pass' >> "$RUN_LOG"
    run_driver_case actual_timeout timeout run_timeout 1 || emit_fail self_driver_timeout
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_driver_timeout pass' >> "$RUN_LOG"
    run_driver_case actual_iverilog_rc9 ok compile_rc=9 10 rc9 || emit_fail self_iverilog_rc9
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_iverilog_rc9 pass' >> "$RUN_LOG"
    run_driver_case actual_iverilog_noartifact ok compile_zero 10 noartifact || emit_fail self_iverilog_noartifact
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_iverilog_noartifact pass' >> "$RUN_LOG"
    run_driver_case actual_late_snapshot_drift late_snapshot snapshot_mutated || emit_fail self_late_snapshot_drift
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_late_snapshot_drift pass' >> "$RUN_LOG"
    run_driver_case actual_late_snapshot_aux late_snapshot_aux snapshot_mutated || emit_fail self_late_snapshot_aux
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_late_snapshot_aux pass' >> "$RUN_LOG"
    run_driver_case actual_late_source_env late_source_env source_mutated 10 ok ok "$SRC_DRIFT_ENV" || emit_fail self_late_source_env
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_late_source_env pass' >> "$RUN_LOG"
    run_driver_case actual_late_source_aux late_source_aux source_mutated 10 ok ok "$SRC_DRIFT_AUX" || emit_fail self_late_source_aux
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_late_source_aux pass' >> "$RUN_LOG"
    run_driver_case actual_late_caller_aux late_caller_aux caller_mutated 10 ok ok "$DRIVER_TEST_ROOT" \
        "$CALLER_DRIFT_ROOT/build/functional/data-bus/late-caller-pkg" "$CALLER_DRIFT_ROOT/sim/functional/test_data_bus_driver.sh" \
        || emit_fail self_late_caller_aux
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_late_caller_aux pass' >> "$RUN_LOG"
    run_driver_case actual_ext_only_caller_drift late_caller_extonly caller_mutated 10 ok ok "$DRIVER_TEST_ROOT" \
        "$CALLER_DRIFT_EXTONLY_ROOT/build/functional/data-bus/ext-only-caller-pkg" \
        "$CALLER_DRIFT_EXTONLY_ROOT/sim/functional/test_data_bus_driver.sh" --extension-case-1 || emit_fail self_ext_only_caller_drift
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_ext_only_caller_drift pass' >> "$RUN_LOG"
    run_driver_case actual_caller_sha_rc9 ok caller_sha_rc_before=9 10 ok rc9 "$DRIVER_TEST_ROOT" "" "" "" caller || emit_fail self_caller_sha_rc9
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_caller_sha_rc9 pass' >> "$RUN_LOG"
    run_driver_case actual_caller_sha_badhex ok caller_sha_format_before 10 ok badhex "$DRIVER_TEST_ROOT" "" "" "" caller || emit_fail self_caller_sha_badhex
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_caller_sha_badhex pass' >> "$RUN_LOG"
    run_driver_case actual_sha_rc9 ok source_sha_rc_before=9 10 ok rc9 "$DRIVER_TEST_ROOT" "" "" "" source || emit_fail self_sha_rc9
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_sha_rc9 pass' >> "$RUN_LOG"
    run_driver_case actual_sha_badhex ok source_sha_format_before 10 ok badhex "$DRIVER_TEST_ROOT" "" "" "" source || emit_fail self_sha_badhex
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_sha_badhex pass' >> "$RUN_LOG"
    run_driver_case actual_sha_nofinal ok source_sha_format_before 10 ok nofinal "$DRIVER_TEST_ROOT" "" "" "" source || emit_fail self_sha_nofinal
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_sha_nofinal pass' >> "$RUN_LOG"
    run_driver_case actual_sha_extralf ok source_sha_format_before 10 ok extralf "$DRIVER_TEST_ROOT" "" "" "" source || emit_fail self_sha_extralf
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_sha_extralf pass' >> "$RUN_LOG"
    run_driver_case actual_sha_wrongpath ok source_sha_format_before 10 ok wrongpath "$DRIVER_TEST_ROOT" "" "" "" source || emit_fail self_sha_wrongpath
    CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_sha_wrongpath pass' >> "$RUN_LOG"
    [ "$CP_OK" -eq "$CP_N" ] || emit_fail "counterproof=$CP_OK/$CP_N"
    printf 'FUNCTIONAL_DATA_BUS: PASS\n' > "$RUN_DIR/fixtures/positive-caller.token"
    [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$RUN_DIR/fixtures/positive-caller.token" || true)" = 1 ] || emit_fail self_positive_token
    if [ "${RV32_DATA_BUS_ENTRY_REENTRY:-0}" != "1" ]; then
        ENTRY_LOG="$RUN_DIR/fixtures/actual-entry-selftest.log"
        mkdir -p -- "$RUN_DIR/fixtures/entry-selftest-pkg"
        env RV32_DATA_BUS_ENTRY_REENTRY=1 DUT_ROOT="$DRIVER_TEST_ROOT" RV32_FUNCTIONAL_PKG_OUT_DIR="$RUN_DIR/fixtures/entry-selftest-pkg" \
            timeout "${TIMEOUT_DATA_BUS_S:-900}" bash "$SELF_DIR/test_data_bus.sh" --self-test > "$ENTRY_LOG" 2>&1
        ENTRY_RC=$?
        [ "$ENTRY_RC" -eq 0 ] && [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS_NEGATIVE: PASS' "$ENTRY_LOG" || true)" = 1 ] &&
            [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$ENTRY_LOG" || true)" = 0 ] || emit_fail actual_entry_selftest
        CP_N=$((CP_N+1)); CP_OK=$((CP_OK+1)); echo 'CP actual_entry_selftest pass' >> "$RUN_LOG"
    fi
    printf 'DATA_BUS_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N" >> "$RUN_LOG"
    printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: PASS\n' >> "$RUN_LOG"
    [ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$RUN_LOG" || true)" = "0" ] || emit_fail default_anchor_in_neg
    printf 'DATA_BUS_COUNTERPROOFS total=%s/%s\n' "$CP_OK" "$CP_N"
    printf 'FUNCTIONAL_DATA_BUS_NEGATIVE: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 1. Source-before -> per-relative-path frozen copy -> bytewise copy verification.
#    DUT_ROOT is explicit and canonical; default remains the invoking repository.
#------------------------------------------------------------------------------
DUT_ROOT_RAW="${DUT_ROOT:-$REPO_ROOT}"
[ -d "$DUT_ROOT_RAW" ] || emit_fail dut_root_missing
DUT_ROOT_CANON="$(cd -- "$DUT_ROOT_RAW" 2>/dev/null && pwd -P)" || emit_fail dut_root_unresolved
for required in rtl "$TB_REL" "$PTW_A_REL" "$PTW_B_REL" sim/functional/test_data_bus_driver.sh sim/functional/test_data_bus.sh scripts/env.sh; do
    [ -e "$DUT_ROOT_CANON/$required" ] || emit_fail "dut_source_missing_$required"
done
# The DUT RTL may come from a pinned older tree, but test/entry/env bytes must be the
# exact cohort this caller is running; stale test closures are rejected, never fallbacked.
for test_rel in "$TB_REL" "$PTW_A_REL" "$PTW_B_REL" sim/functional/test_data_bus_driver.sh sim/functional/test_data_bus.sh scripts/env.sh; do
    cmp -s "$REPO_ROOT/$test_rel" "$DUT_ROOT_CANON/$test_rel" || emit_fail "test_cohort_mismatch_$test_rel"
done
CALLER_LIST="$RUN_DIR/caller.paths"
printf '%s\n' "$TB_REL" "$PTW_A_REL" "$PTW_B_REL" sim/functional/test_data_bus_driver.sh sim/functional/test_data_bus.sh scripts/env.sh \
    | LC_ALL=C sort -u > "$CALLER_LIST" || emit_fail caller_source_list
caller_manifest() {
    local sha_rc=0 rel
    while IFS= read -r rel; do
        [ -f "$REPO_ROOT/$rel" ] || return 1
        ( cd -- "$REPO_ROOT" && sha256sum -- "$rel" ) || { sha_rc=$?; return "$sha_rc"; }
    done < "$CALLER_LIST"
}
SNAP="$RUN_DIR/src"
mkdir -p -- "$SNAP" || emit_fail snap_mkdir
SRC_LIST="$RUN_DIR/source.paths"
( cd -- "$DUT_ROOT_CANON" && {
    find rtl -type f \( -name '*.v' -o -name '*.vh' \)
    printf '%s\n' "$TB_REL" "$PTW_A_REL" "$PTW_B_REL" sim/functional/test_data_bus_driver.sh sim/functional/test_data_bus.sh scripts/env.sh
} | LC_ALL=C sort -u ) > "$SRC_LIST" || emit_fail source_list
[ -s "$SRC_LIST" ] || emit_fail source_list_empty
validate_sha_raw() {
    python3 - "$1" "${2:-$SRC_LIST}" <<'PY'
import pathlib, re, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
paths_raw = pathlib.Path(sys.argv[2]).read_bytes()
if not raw or b"\0" in raw or b"\r" in raw or not raw.endswith(b"\n"):
    raise SystemExit(2)
paths = paths_raw.splitlines()
lines = raw[:-1].split(b"\n")
if len(lines) != len(paths) or len(set(paths)) != len(paths):
    raise SystemExit(3)
for line, path in zip(lines, paths):
    if len(line) != 64 + 2 + len(path) or not re.fullmatch(rb"[0-9a-f]{64}  " + re.escape(path), line):
        raise SystemExit(4)
PY
}
strict_sha256_file() {
    local file="$1" raw_file="$2" rc_file="$3" sha_rc
    [ -f "$file" ] || return 1
    mkdir -p -- "$(dirname -- "$raw_file")" || return 1
    sha256sum -- "$file" > "$raw_file"
    sha_rc=$?
    printf '%s\n' "$sha_rc" > "$rc_file" || return 1
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    python3 - "$file" "$raw_file" <<'PY'
import os, pathlib, re, sys
path = os.fsencode(sys.argv[1])
raw = pathlib.Path(sys.argv[2]).read_bytes()
if not raw.endswith(b'\n') or raw.count(b'\n') != 1:
    raise SystemExit(2)
line = raw[:-1]
if len(line) != 66 + len(path) or line[64:66] != b'  ' or line[66:] != path:
    raise SystemExit(3)
if not re.fullmatch(rb'[0-9a-f]{64}', line[:64]):
    raise SystemExit(4)
sys.stdout.write(line[:64].decode('ascii'))
PY
}
caller_manifest > "$RUN_DIR/caller.sha.before"
CALLER_BEFORE_RC=$?
[ "$CALLER_BEFORE_RC" -eq 0 ] || emit_fail "caller_sha_rc_before=$CALLER_BEFORE_RC"
validate_sha_raw "$RUN_DIR/caller.sha.before" "$CALLER_LIST" || emit_fail caller_sha_format_before
source_manifest() {
    local sha_rc=0
    while IFS= read -r rel; do
        [ -f "$DUT_ROOT_CANON/$rel" ] || return 1
        ( cd -- "$DUT_ROOT_CANON" && sha256sum -- "$rel" ) || { sha_rc=$?; return "$sha_rc"; }
    done < "$SRC_LIST"
}
copy_rel() {
    local rel="$1"
    mkdir -p -- "$SNAP/$(dirname -- "$rel")" && cp -p -- "$DUT_ROOT_CANON/$rel" "$SNAP/$rel"
}
source_manifest > "$RUN_DIR/source.sha.before"
SOURCE_BEFORE_RC=$?
[ "$SOURCE_BEFORE_RC" -eq 0 ] || emit_fail "source_sha_rc_before=$SOURCE_BEFORE_RC"
validate_sha_raw "$RUN_DIR/source.sha.before" || emit_fail source_sha_format_before
while IFS= read -r f; do copy_rel "$f" || emit_fail "snap_copy_$f"; done < "$SRC_LIST"
copy_manifest() {
    local sha_rc=0
    while IFS= read -r rel; do
        [ -f "$SNAP/$rel" ] || return 1
        ( cd -- "$SNAP" && sha256sum -- "$rel" ) || { sha_rc=$?; return "$sha_rc"; }
    done < "$SRC_LIST"
}
copy_manifest > "$RUN_DIR/src.sha.copy"
COPY_RC=$?
[ "$COPY_RC" -eq 0 ] || emit_fail "copy_sha_rc=$COPY_RC"
validate_sha_raw "$RUN_DIR/src.sha.copy" || emit_fail copy_sha_format
cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/src.sha.copy" || emit_fail source_copy_mismatch
caller_snapshot_manifest() {
    local sha_rc=0 rel
    while IFS= read -r rel; do
        [ -f "$SNAP/$rel" ] || return 1
        ( cd -- "$SNAP" && sha256sum -- "$rel" ) || { sha_rc=$?; return "$sha_rc"; }
    done < "$CALLER_LIST"
}
verify_after_inputs() {
    source_manifest > "$RUN_DIR/source.sha.after"
    SOURCE_AFTER_RC=$?
    [ "$SOURCE_AFTER_RC" -eq 0 ] || emit_fail "source_sha_rc_after=$SOURCE_AFTER_RC"
    validate_sha_raw "$RUN_DIR/source.sha.after" || emit_fail source_sha_format_after
    copy_manifest > "$RUN_DIR/src.sha.after"
    COPY_AFTER_RC=$?
    [ "$COPY_AFTER_RC" -eq 0 ] || emit_fail "snapshot_sha_rc_after=$COPY_AFTER_RC"
    validate_sha_raw "$RUN_DIR/src.sha.after" || emit_fail snapshot_sha_format_after
    cmp -s "$RUN_DIR/source.sha.before" "$RUN_DIR/source.sha.after" || emit_fail source_mutated
    cmp -s "$RUN_DIR/src.sha.copy" "$RUN_DIR/src.sha.after" || emit_fail snapshot_mutated
    caller_manifest > "$RUN_DIR/caller.sha.after"
    CALLER_AFTER_RC=$?
    [ "$CALLER_AFTER_RC" -eq 0 ] || emit_fail "caller_sha_rc_after=$CALLER_AFTER_RC"
    validate_sha_raw "$RUN_DIR/caller.sha.after" "$CALLER_LIST" || emit_fail caller_sha_format_after
    cmp -s "$RUN_DIR/caller.sha.before" "$RUN_DIR/caller.sha.after" || emit_fail caller_mutated
}
caller_snapshot_manifest > "$RUN_DIR/caller.sha.snapshot"
CALLER_SNAPSHOT_RC=$?
[ "$CALLER_SNAPSHOT_RC" -eq 0 ] || emit_fail "caller_snapshot_sha_rc=$CALLER_SNAPSHOT_RC"
validate_sha_raw "$RUN_DIR/caller.sha.snapshot" "$CALLER_LIST" || emit_fail caller_snapshot_sha_format
cmp -s "$RUN_DIR/caller.sha.before" "$RUN_DIR/caller.sha.snapshot" || emit_fail caller_snapshot_mismatch
{
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "DUT_ROOT        = $DUT_ROOT_CANON"
    echo "RUN_DIR         = $RUN_DIR"
    echo "SOURCE_GRAPH_N  = $(wc -l < "$SRC_LIST")"
} >> "$RUN_LOG"
# Source the frozen env; preserve its real return code before any other command.
[ -r "$SNAP/scripts/env.sh" ] || emit_fail snapshot_env_missing
# shellcheck disable=SC1090
. "$SNAP/scripts/env.sh" >> "$RUN_LOG" 2>&1
ENV_RC=$?
printf 'FROZEN_ENV_RC=%s\n' "$ENV_RC" >> "$RUN_LOG"
[ "$ENV_RC" -eq 0 ] || emit_fail "frozen_env_rc=$ENV_RC"
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
GCC="${RV32_GCC:-}"; OBJCOPY="${RV32_OBJCOPY:-}"
NM="${RV32_TOOLCHAIN_BIN:-}/${RV32_TOOLCHAIN_PREFIX:-}nm"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail iverilog_missing
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail vvp_missing
[ -n "$GCC" ] && [ -x "$GCC" ] || emit_fail gcc_missing
[ -n "$OBJCOPY" ] && [ -x "$OBJCOPY" ] || emit_fail objcopy_missing
[ -x "$NM" ] || emit_fail nm_missing
RTLSRC="$(cd -- "$SNAP" && find rtl -name '*.v' | LC_ALL=C sort | tr '\n' ' ')"

#------------------------------------------------------------------------------
# 2. 定向程序（PMP / defer / IRQ / kill-drain）
#------------------------------------------------------------------------------
PROG_DIR="$RUN_DIR/prog"; mkdir -p -- "$PROG_DIR" || emit_fail prog_dir
cat > "$PROG_DIR/dbs.S" <<'ASM'
    .section .text.init,"ax",@progbits
    .globl _start
    .option norvc
    .equ UART,   0x1FE001E0
    .equ KILLDEV,0x1FE001E4
    .equ MB,     0x1FE01000
    .equ DENY,   0x80011000
    .equ ALLOW,  0x80012000
    .equ SLOW,   0x80013000
    .equ KNOWN,  0x80015000
    .equ MTIMECMP,0x1F004000
    .equ MTIME,  0x1F00BFF8
    .equ TD,      0x1FE00240
    .equ TS,      0x1FE00250
    .equ TP,      0x1FE00260
    .equ TC,      0x1FE00270
    .equ SLOW_CFG,  0x80016000
    .equ SLOW_CFG2, 0x80016020
    .equ SLOW_ADDR, 0x80016040
    .equ SLOW_DATA2,0x80016060
    .equ CBO_ADDR,  0x80017000
    .equ MAGIC,  0x44425331
    .equ DONE,   0xDEADBEEF

_start:
    la    t0, trap
    csrw  mtvec, t0
    # PMP：entry0 = 16B @DENY 锁定、R/W/X=0（拒绝）；entry1 = 16B @ALLOW 锁定、RW
    li    t0, 0x20004403
    csrw  0x3b0, t0
    li    t0, 0x20004803
    csrw  0x3b1, t0
    li    t0, 0x00009B98
    csrw  0x3a0, t0

    # ★ F4/PMP 动态：entry4 L=0 allow @TP（pmpaddr 案）；entry5 L=1 deny @TP；
    #   entry6 allow @TD（cfg store 案）；entry7 allow @TS（same-group 案）。
    li    t0, TP
    srli  t0, t0, 2
    ori   t0, t0, 1
    csrw  0x3b4, t0
    csrw  0x3b5, t0
    li    t0, TD
    srli  t0, t0, 2
    ori   t0, t0, 1
    csrw  0x3b6, t0
    li    t0, TS
    srli  t0, t0, 2
    ori   t0, t0, 1
    csrw  0x3b7, t0
    li    t0, 0x18189818
    csrw  0x3a1, t0
    csrr  t0, 0x3a1
    li    t1, 0x1FE01088
    sw    t0, 0(t1)

    li    s1, MB
    li    t0, MAGIC
    sw    t0, 0(s1)
    addi  s1, s1, 4
    li    t0, 16
    sw    t0, 0(s1)
    addi  s1, s1, 4

    # r1：允许区 store/load
    li    s2, ALLOW
    li    t2, 0x12345678
    sw    t2, 0(s2)
    lw    t3, 0(s2)
    li    a0, 0
    bne   t3, t2, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r2：拒绝区 load ⇒ cause 5、tval=DENY
    li    s3, DENY
    lw    t3, 0(s3)
    li    a0, 0
    li    t1, 5
    bne   t6, t1, 1f
    li    t1, DENY
    bne   t5, t1, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r3：拒绝区 store ⇒ 退休前预检 cause 7（零物理写，TB 验）
    li    t2, 0x0BADF00D
    sw    t2, 0(s3)
    li    a0, 0
    li    t1, 7
    bne   t6, t1, 1f
    li    t1, DENY
    bne   t5, t1, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r4：跨入拒绝区边界的真实字节（lw@DENY-2 拆笔，越界笔必拒）⇒ cause 5
    addi  t2, s3, -2
    lw    t3, 0(t2)
    li    a0, 0
    li    t1, 5
    bne   t6, t1, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r5：普通 cacheable load
    li    s4, KNOWN
    lw    t3, 0(s4)
    li    a0, 0
    li    t1, 0x5A5A5A5A
    bne   t3, t1, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r6：慢 DDR load 后跟年轻设备 load（非 head ⇒ 零副作用 defer）
    li    s5, SLOW
    li    s6, UART
    lw    s7, 0(s5)
    lw    s8, 0(s6)
    li    a0, 0
    li    t1, 0x11223344
    bne   s7, t1, 1f
    li    t1, 0xA5A50001
    bne   s8, t1, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4
    li    t0, 0x1FE01050
    sw    s7, 0(t0)
    sw    s8, 4(t0)

    # r7：设备读 IRQ 自持（MTIP 在 50 拍延迟 R 期间 pending；退休后才交付一次）
    li    t0, MTIME
    lw    t1, 0(t0)
    addi  t1, t1, 24
    li    t0, MTIMECMP
    sw    t1, 0(t0)
    sw    x0, 4(t0)
    li    t0, 0x80
    csrw  0x304, t0
    csrr  t0, 0x300
    ori   t0, t0, 8
    csrw  0x300, t0
    lw    s9, 0(s6)
    nop
    csrr  t0, 0x300
    andi  t0, t0, -9
    csrw  0x300, t0
    li    a0, 0
    li    t1, 1
    bne   s11, t1, 1f
    li    t1, 0xA5A50002
    bne   s9, t1, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r8：kill/drain —— 设备读被 TB 强制 trap 重定向到 cont；迟到旧 R 必须被吞
    li    s10, KILLDEV
    lw    s10, 0(s10)
    li    a0, 0
    sw    a0, 0(s1)          # 不可达（若到达 ⇒ r8 之外还会错位）
    addi  s1, s1, 4
cont:
    li    t0, KNOWN
    lw    t1, 0(t0)
    li    a0, 0
    li    t2, 0x5A5A5A5A
    bne   t1, t2, 1f
    li    a0, 1
1:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r9：合法 ECALL trap + 已提交 uncached store 接管（0xAA；UART B 延迟跨 trap flush）
    li    t6, 0
    li    t0, UART
    li    t1, 0xAA
    sb    t1, 0(t0)
    ecall
    li    t0, UART          # handler 用 t0 做 mcause/mepc，返回后必须重载基址
    li    t1, 0xBB
    sb    t1, 0(t0)
    li    a0, 1
    sw    a0, 0(s1)
    addi  s1, s1, 4

    # r10：1 字节**uncached UART store** 后无 idle 立即 cbo.flush（维护等 CDQ 空；
    #       committed store 必须照走并在 terminal 前不被 flush 杀掉；TB 验 UART 第 3 字节 0x5A）
    li    t6, 0
    li    t0, 0x70
    csrw  menvcfg, t0
    li    t0, UART
    li    t1, 0x5A
    sb    t1, 0(t0)
    li    t0, CBO_ADDR
    cbo.flush (t0)
    li    a0, 1
    sw    a0, 0(s1)
    addi  s1, s1, 4

    # r11：PMPCFG 动态 store —— 旧 allow 下预检、CSR 提交新 deny，flush 重取后必须 cause7/零写
    li    t6, 0
    li    t1, 0xA0A0A0A0
    li    a1, TD
    li    s0, SLOW_CFG
    lw    t0, 0(s0)
    csrw  0x3a1, t0
    sw    t1, 0(a1)
    li    t0, 0x1FE0108C
    sw    t6, 0(t0)
    # ★ 正式 pre-final 对齐 store（同 10373 debugfix）：+1 合法 uncached store 让年轻 store
    #   落在 PMP 事件沿的 STQ 年龄；e25 必须在入 CDQ 前被 pmp_hold 阻（TS/TP=0）。
    li    t0, 0x1FE01094
    sw    t6, 0(t0)
    li    t4, 0x0BAD          # sentinel：若 PMP redirect 从分支目标进入（检查被跳过）则 t4 不更新
    li    a0, 0
    li    t1, 7
    bne   t6, t1, 1f
    li    t4, 0xBEEF
    li    a0, 1
1:  li    t1, 0xBEEF
    beq   t4, t1, 2f
    li    a0, 0
2:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r10：same-group（CSR lane0 + store lane1）——5f3 candidate 限 + Top flush 后重取 cause7/零写
    li    t6, 0
    li    t1, 0xB0B0B0B0
    li    a1, TS
    li    s0, SLOW_CFG2
    lw    t0, 0(s0)
    csrw  0x3a1, t0
    sw    t1, 0(a1)
    li    t4, 0x0BAD          # sentinel：若 PMP redirect 从分支目标进入（检查被跳过）则 t4 不更新
    li    a0, 0
    li    t1, 7
    bne   t6, t1, 1f
    li    t4, 0xBEEF
    li    a0, 1
1:  li    t1, 0xBEEF
    beq   t4, t1, 2f
    li    a0, 0
2:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r11：PMPADDR 动态（entry4 旧 allow 移走 ⇒ entry5 deny）——flush 重取后 cause7/零写
    li    t6, 0
    li    t1, 0xC0C0C0C0
    li    a1, TP
    li    s0, SLOW_ADDR
    lw    t0, 0(s0)
    csrw  0x3b4, t0
    sw    t1, 0(a1)
    li    t4, 0x0BAD          # sentinel：若 PMP redirect 从分支目标进入（检查被跳过）则 t4 不更新
    li    a0, 0
    li    t1, 7
    bne   t6, t1, 1f
    li    t4, 0xBEEF
    li    a0, 1
1:  li    t1, 0xBEEF
    beq   t4, t1, 2f
    li    a0, 0
2:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r12：非 PMP CSR 正控（mscratch）——不 flush、正常写、无 trap
    li    t6, 0
    li    t0, 0x1234
    csrw  0x340, t0
    li    t1, 0xD0D0D0D0
    li    a1, TC
    sw    t1, 0(a1)
    li    t0, 0x1FE01090
    sw    t6, 0(t0)
    li    t4, 0x0BAD
    li    a0, 0
    bne   t6, x0, 1f
    li    t4, 0xBEEF
    li    a0, 1
1:  li    t1, 0xBEEF
    beq   t4, t1, 2f
    li    a0, 0
2:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r13：新 deny 已生效后（数据依赖 200 拍慢 load）store ⇒ cause7/零写（正控）
    li    t6, 0
    li    s0, SLOW_DATA2
    lw    t1, 0(s0)
    li    a1, TD
    sw    t1, 0(a1)
    li    t4, 0x0BAD          # sentinel：若 PMP redirect 从分支目标进入（检查被跳过）则 t4 不更新
    li    a0, 0
    li    t1, 7
    bne   t6, t1, 1f
    li    t4, 0xBEEF
    li    a0, 1
1:  li    t1, 0xBEEF
    beq   t4, t1, 2f
    li    a0, 0
2:  sw    a0, 0(s1)
    addi  s1, s1, 4

    # r14：已提交 uncached store 跨 PMP flush —— 紧随其后触发 PMP 事件，结果不得丢
    li    t6, 0
    li    a0, 1
    sw    a0, 0(s1)
    addi  s1, s1, 4
    li    t0, 0x98989818
    csrw  0x3a1, t0

    # 额外 uncached store（同代不同 data / 1 字节；放在结果向量之后，TB 计恰一次 accept）
    li    t0, MB
    li    t1, 0x7E7E7E7E
    sw    t1, 0x80(t0)
    li    t1, 0x5A
    sb    t1, 0x84(t0)
    li    t2, DONE
    sw    t2, 0(s1)
2:  j 2b

trap:
    csrr  t0, mcause
    bltz  t0, irq
    mv    t6, t0
    csrr  t5, mtval
    csrr  t0, mepc
    addi  t0, t0, 4
    csrw  mepc, t0
    mret
irq:
    addi  s11, s11, 1
    li    t0, MTIMECMP
    li    t1, -1
    sw    t1, 0(t0)
    sw    t1, 4(t0)
    mret
ASM

# Independent CPU-driven Sv32 extension program. The table and one-shot AXI RRESP
# conditions are seeded by TB memory-model plusargs; no internal DUT forcing is used.
cat > "$PROG_DIR/dbs_ext.S" <<'ASM'
    .section .text.init,"ax",@progbits
    .globl _start
    .option norvc
    .equ EXT_ID,  0x8001F000
    .equ DENY_M,  0x80011000
    .equ DATA_VA, 0x00401200
    .equ RESULT,  0x1FE01100
_start:
    li    s1, 0
    li    s2, 0
    li    s3, 0
    li    s9, 0
    la    t0, m_trap
    csrw  mtvec, t0
    li    t0, 0x0000A0A0     # delegate S load/store AF and page-fault causes
    csrw  0x302, t0
    li    s0, EXT_ID
    lw    s0, 0(s0)
    la    t0, s_trap
    csrw  stvec, t0
    li    t0, 0x8008001b
    csrw  satp, t0
    sfence.vma x0, x0
    li    t0, 1
    beq   s0, t0, pmp_fast_setup
    li    t0, 4
    beq   s0, t0, pmp_pte_setup
    li    t0, 5
    bne   s0, t0, pmp_allow_setup
pmp_pte_setup:
    # Locked deny exactly the lower-level PTE line; catch-all permits everything else.
    li    t0, 0x20007003
    csrw  0x3b0, t0
    li    t0, -1
    csrw  0x3b1, t0
    li    t0, 0x00001f98
    csrw  0x3a0, t0
    j     pmp_setup_done
pmp_fast_setup:
    # Locked 16-byte deny with satp already active; cause-7 fast store fault precedes S slow walk.
    li    t0, 0x20004403
    csrw  0x3b0, t0
    li    t0, -1
    csrw  0x3b1, t0
    li    t0, 0x00001f98
    csrw  0x3a0, t0
    li    t0, DENY_M
    li    t1, 0xD00D0001
    sw    t1, 0(t0)
    j     pmp_setup_done
pmp_allow_setup:
    # S-mode report/data windows require an explicit catch-all permission entry.
    li    t0, -1
    csrw  0x3b1, t0
    li    t0, 0x00001f00
    csrw  0x3a0, t0
    j     pmp_setup_done
pmp_setup_done:
    li    t0, 11
    beq   s0, t0, pmp_bdelay_scenario
    li    t0, 15
    bne   s0, t0, pmp_setup_continue
    li    t0, 0x8001B004
    lw    t1, 0(t0)          # naturally prewarm root[1] for the later AD_PTE hit
pmp_setup_continue:
    csrr  t0, mstatus
    li    t1, 0xffffe7ff
    and   t0, t0, t1
    li    t1, 0x800
    or    t0, t0, t1
    csrw  mstatus, t0
    la    t0, s_start
    csrw  mepc, t0
    mret

m_trap:
    csrr  s1, mcause
    csrr  s2, mtval
    addi  s3, s3, 1
    csrr  t0, mepc
    addi  t0, t0, 4
    csrw  mepc, t0
    mret

pmp_bdelay_scenario:
    li    s6, 0
    li    t0, 0x1FE01200
    li    t1, 0x1234ABCD
    sw    t1, 0(t0)         # accepted older store; external B delayed 12 cycles
    li    t0, 0x00001B00
    csrw  0x3a0, t0         # real pmpcfg0 update must refetch at PC+4
    .globl pmp_after_csr
pmp_after_csr:
    addi  s6, s6, 1
    li    t0, RESULT+40
    sw    s6, 0(t0)         # report actual post-redirect target execution count
    li    t2, 0x5A5A2222
    j     extension_done

s_start:
    # Scenario 1 must make the first post-fault data op a slow Sv32 store.
    li    t0, 1
    beq   s0, t0, fast_after_fault
    # Warm the I/O superpage TLB entry so the other trap loggers do not disturb
    # the targeted data-PTE transaction.
    li    t0, RESULT+16
    sw    x0, 0(t0)
    li    t0, 2
    beq   s0, t0, pte_load_error
    li    t0, 3
    beq   s0, t0, pte_store_error
    li    t0, 4
    beq   s0, t0, pte_load_pmp
    li    t0, 5
    beq   s0, t0, pte_store_pmp
    li    t0, 6
    beq   s0, t0, pte_root_high
    li    t0, 7
    beq   s0, t0, pte_leaf_high
    li    t0, 8
    beq   s0, t0, invalid_leaf_load
    li    t0, 9
    beq   s0, t0, invalid_leaf_store
    li    t0, 10
    beq   s0, t0, branch_kill_scenario
    li    t0, 14
    beq   s0, t0, high_leaf_store
    li    t0, 15
    beq   s0, t0, branch_kill_scenario
    li    t0, 16
    beq   s0, t0, branch_kill_scenario
    li    t0, 12
    beq   s0, t0, cached_load_error_early
    li    t0, 13
    beq   s0, t0, cached_load_error_late
    j     extension_bad

fast_after_fault:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # first S-mode data op: slow Sv32 store, no intervening success
    lw    t2, 0(t0)
    j     extension_done

pte_load_error:
    li    t0, DATA_VA
    lw    t2, 0(t0)         # first walk sees one RRESP error; trap skips this op
    lw    t2, 0(t0)         # same VA retries and must complete after one-shot error
    j     extension_done

pte_store_error:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # first PTE read error => store/AMO access fault 7
    sw    t2, 0(t0)         # one-shot response consumed; retry must commit
    lw    t2, 0(t0)
    j     extension_done

pte_load_pmp:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # PMP rejects the implicit PTE read => load AF 5
    j     extension_done

pte_store_pmp:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # same PTE PMP rejection => store AF 7
    j     extension_done

pte_root_high:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # high PPN in root's next-level pointer => AF5, no alias
    j     extension_done

pte_leaf_high:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # high PPN in leaf => AF5, no truncated data read
    j     extension_done

invalid_leaf_load:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # V=0 control must be load page-fault 13
    j     extension_done

invalid_leaf_store:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # V=0 control must be store page-fault 15, no W
    j     extension_done

high_leaf_store:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # high PA store must access-fault 7 without truncation/W
    j     extension_done

cached_load_error_early:
    li    t0, DATA_VA
    lw    t2, 0(t0)         # cached DATA RRESP SLVERR beat 0 => one load AF5
    lw    t2, 0(t0)         # one-shot error consumed; retry must return data
    j     extension_done

cached_load_error_late:
    li    t0, DATA_VA
    lw    t2, 0(t0)         # cached DATA RRESP SLVERR beat 7 => one load AF5
    lw    t2, 0(t0)         # one-shot error consumed; retry must return data
    j     extension_done

branch_kill_scenario:
    li    s6, 4
    li    s7, 1
    li    s8, 0x00400000
branch_mdu_loop:
    div   t6, s6, s7         # older iterative MDU dependency
    beq   t6, x0, branch_redirect_target
    bnez  s6, branch_mdu_skipload
    lw    t5, 0(s8)          # only final predicted fall-through: cold invalid PTE0 load
branch_mdu_skipload:
    addi  s6, s6, -1
    j     branch_mdu_loop

    .globl branch_redirect_target
branch_redirect_target:
    li    t0, RESULT+24
    li    t1, 0x0000B101
    sw    t1, 0(t0)         # evidence that the real taken target retired
    la    t0, fresh_vpn_target
    li    t1, 0x00400000
    add   t0, t0, t1        # jump to same physical code through a fresh VPN1=513
    jr    t0

    .globl fresh_vpn_target
fresh_vpn_target:
    li    t0, RESULT+28
    li    t1, 0x0000B202
    sw    t1, 0(t0)         # evidence that the new ITLB VPN was reached
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # correct post-kill slow store reuses canceled tag safely
    lw    t2, 0(t0)
    j     extension_done

s_trap:
    mv    s4, t0            # preserve the faulting program's address operands
    mv    s5, t1
    csrr  t0, scause
    mv    s1, t0            # record the actual architectural S cause
    li    t1, RESULT
    sw    t0, 4(t1)
    lw    t0, 8(t1)
    addi  t0, t0, 1
    sw    t0, 8(t1)
    addi  s9, s9, 1         # actual S-trap count; never synthesize a constant
    csrr  t0, stval
    mv    s2, t0            # record the actual faulting virtual address
    csrr  t0, sepc
    addi  t0, t0, 4
    csrw  sepc, t0
    mv    t0, s4
    mv    t1, s5
    sret

extension_bad:
    li    t2, 0xBAD00000
extension_done:
    li    t0, 1
    bne   s0, t0, 1f
    li    t0, RESULT
    sw    s1, 4(t0)         # fast M-mode store AF7 captured only in registers
    sw    s3, 8(t0)
1:  li    t0, RESULT+20
    sw    s2, 0(t0)
    li    t0, RESULT+32
    sw    s3, 0(t0)         # actual M-mode trap count
    li    t0, RESULT+36
    sw    s9, 0(t0)         # actual S-mode trap count
    li    t0, RESULT+40
    sw    s6, 0(t0)         # actual case-11 post-redirect target executions
    li    t0, RESULT+12
    sw    t2, 0(t0)
    li    t0, 0x4558544F
    li    t1, RESULT
    sw    t0, 0(t1)
1:  j     1b

ASM

assemble_one() {
    "$GCC" -march=rv32ima_zicsr_zifencei_zicbom -mabi=ilp32 -nostdlib -nostartfiles \
        -Ttext=0x80000000 -o "$PROG_DIR/dbs.elf" "$PROG_DIR/dbs.S" \
        > "$RUN_DIR/asm.log" 2>&1 || { cat "$RUN_DIR/asm.log" >> "$RUN_LOG"; return 1; }
    "$OBJCOPY" -O binary "$PROG_DIR/dbs.elf" "$PROG_DIR/dbs.bin" >> "$RUN_DIR/asm.log" 2>&1 || return 1
    local size; size=$(stat -c %s -- "$PROG_DIR/dbs.bin") || return 1
    [ "$size" -gt 0 ] || return 1
    (( size % 4 == 0 )) || return 1
    python3 - "$PROG_DIR/dbs.bin" 0x80000000 "$PROG_DIR/dbs.hex" <<'PY'
import struct, sys
data = open(sys.argv[1],'rb').read()
with open(sys.argv[3],'w') as f:
    f.write('@%08x\n' % int(sys.argv[2],0))
    for w in struct.unpack('<%dI' % (len(data)//4), data):
        f.write('%08x\n' % w)
PY
    echo "PROG bytes=$size words=$((size/4)) sha256=$(sha256sum "$PROG_DIR/dbs.hex" | awk '{print $1}')" >> "$RUN_LOG"
}
assemble_one || emit_fail assemble
CONT_ADDR="$("$NM" "$PROG_DIR/dbs.elf" | awk '$3=="cont"{print $1}')"
[ -n "$CONT_ADDR" ] || emit_fail cont_symbol_missing
printf 'CONT_ADDR=0x%s\n' "$CONT_ADDR" >> "$RUN_LOG"

PROFILE_A_HEX_PIN=""
PROFILE_B_HEX_PIN=""
PROFILE_TEST_B_BUILD_A_HEX_DRIFT=0
build_profile_image() {
    local name="$1" rel="$2" stem="$PROG_DIR/profile-$1" size src_sha src_sha_after bin_sha hex_sha sha_rc
    local source_path="$SNAP/$rel" source_raw="$stem.source.sha.raw" source_rc="$stem.source.sha.rc"
    local bin_raw="$stem.bin.sha.raw" bin_rc="$stem.bin.sha.rc" hex_raw="$stem.hex.sha.raw" hex_rc="$stem.hex.sha.rc"
    [ -f "$source_path" ] || return 1
    src_sha="$(strict_sha256_file "$source_path" "$source_raw" "$source_rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    ( cd -- "$SNAP" && "$GCC" -march=rv32ima_zicsr_zifencei_zicbom -mabi=ilp32 \
        -nostdlib -nostartfiles -Ttext=0x80000000 -o "$stem.elf" "$rel" ) \
        > "$stem.asm.log" 2>&1 || { cat "$stem.asm.log" >> "$RUN_LOG"; return 1; }
    if [ "$name" = b ] && [ "$PROFILE_TEST_B_BUILD_A_HEX_DRIFT" -eq 1 ]; then
        [ -n "$PROFILE_A_HEX_PIN" ] && [ -f "$PROG_DIR/profile-a.hex" ] || return 1
        local a_before a_after
        a_before="$(strict_sha256_file "$PROG_DIR/profile-a.hex" "$stem.test-a-before.sha.raw" "$stem.test-a-before.sha.rc")"; sha_rc=$?
        [ "$sha_rc" -eq 0 ] || return "$sha_rc"
        printf '\n' >> "$PROG_DIR/profile-a.hex" || return 1
        a_after="$(strict_sha256_file "$PROG_DIR/profile-a.hex" "$stem.test-a-after.sha.raw" "$stem.test-a-after.sha.rc")"; sha_rc=$?
        [ "$sha_rc" -eq 0 ] || return "$sha_rc"
        printf 'PROFILE_HEX_DRIFT_INJECT stage=b-assemble-before-objcopy path=%s pin_sha256=%s before_sha256=%s after_sha256=%s appended=LF\n' \
            "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" "$a_before" "$a_after" >> "$RUN_LOG"
        [ "$a_before" = "$PROFILE_A_HEX_PIN" ] && [ "$a_after" != "$PROFILE_A_HEX_PIN" ] || return 1
        PROFILE_TEST_B_BUILD_A_HEX_DRIFT=0
    fi
    "$OBJCOPY" -O binary "$stem.elf" "$stem.bin" >> "$stem.asm.log" 2>&1 || return 1
    size="$(stat -c %s -- "$stem.bin")" || return 1
    [ "$size" -gt 0 ] && (( size % 4 == 0 )) || return 1
    python3 - "$stem.bin" 0x80000000 "$stem.hex" <<'PY' || return 1
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if not raw or len(raw) % 4:
    raise SystemExit('profile binary must be nonempty and word-aligned')
with open(sys.argv[3], 'w', encoding='ascii', newline='\n') as f:
    f.write('@%08x\n' % int(sys.argv[2], 0))
    for word in struct.unpack('<%dI' % (len(raw) // 4), raw):
        f.write('%08x\n' % word)
PY
    bin_sha="$(strict_sha256_file "$stem.bin" "$bin_raw" "$bin_rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    hex_sha="$(strict_sha256_file "$stem.hex" "$hex_raw" "$hex_rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    src_sha_after="$(strict_sha256_file "$source_path" "$stem.source-after.sha.raw" "$stem.source-after.sha.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    if [ "$src_sha" != "$src_sha_after" ]; then
        printf 'PROFILE_SOURCE_IDENTITY_RED name=%s before=%s after=%s\n' "$name" "$src_sha" "$src_sha_after" >> "$RUN_LOG"
        return 1
    fi
    printf '%s\n' "$hex_sha" > "$stem.hex.pin" || return 1
    if [ "$name" = a ]; then
        [ -z "$PROFILE_A_HEX_PIN" ] || return 1
        PROFILE_A_HEX_PIN="$hex_sha"
    elif [ "$name" = b ]; then
        [ -z "$PROFILE_B_HEX_PIN" ] || return 1
        PROFILE_B_HEX_PIN="$hex_sha"
    else
        return 1
    fi
    printf 'PROFILE_SOURCE_BUILD name=%s source_path=%s source_sha256=%s source_after_sha256=%s source_raw=%s source_rc=%s bin_path=%s bin_sha256=%s bin_raw=%s bin_rc=%s hex_path=%s hex_sha256=%s hex_raw=%s hex_rc=%s pin_path=%s pin_sha256=%s\n' \
        "$name" "$source_path" "$src_sha" "$src_sha_after" "$source_raw" "$source_rc" "$stem.bin" "$bin_sha" "$bin_raw" "$bin_rc" "$stem.hex" "$hex_sha" "$hex_raw" "$hex_rc" "$stem.hex.pin" "$hex_sha" >> "$RUN_LOG"
}
profile_args_for_run() {
    case "$1" in
        a) PROFILE_RUN_ARGS=("+CONT=0x${CONT_ADDR}" +EXT=17 +PROFILE_A_TR_FIRST_READY \
            +RDELAY_ADDR=8001e000 +RDELAY_CYCLES=200 +BRANCH_TARGET=80400020 +ITLB_TARGET=8040e040) ;;
        b) PROFILE_RUN_ARGS=("+CONT=0x${CONT_ADDR}" +EXT=18 +PROFILE_B_CACHED_DATA \
            +RDELAY_ADDR=8001f200 +RDELAY_CYCLES=50 +BRANCH_TARGET=80400020 +ITLB_TARGET=8040e040) ;;
        *) return 1 ;;
    esac
}
profile_compile_run() {
    local name="$1" compile_root="$2" input_hex="$3" out="$4" expected_hex="$5" expected_pin="$6"
    shift 6
    local compile_log="$out/compile.log" log="$out/probe.log" compile_rc=0 sim_rc=0 arg sha_rc
    local source_sha_pre source_sha_post input_sha_pre input_sha_post embedded_sha_pre embedded_sha_post
    local -a args=("$@")
    mkdir -p -- "$out/sha" || return 1
    [ -f "$expected_hex" ] && [ -f "$input_hex" ] || return 1
    [[ "$expected_pin" =~ ^[0-9a-f]{64}$ ]] || return 1
    source_sha_pre="$(strict_sha256_file "$expected_hex" "$out/sha/source-pre.raw" "$out/sha/source-pre.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    input_sha_pre="$(strict_sha256_file "$input_hex" "$out/sha/input-pre.raw" "$out/sha/input-pre.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    if [ "$source_sha_pre" != "$expected_pin" ] || [ "$input_sha_pre" != "$expected_pin" ] || ! cmp -s -- "$expected_hex" "$input_hex"; then
        printf 'PROFILE_HEX_PIN_RED stage=pre-compile name=%s pin_path=%s pin_sha256=%s source_hex=%s source_sha256=%s input_hex=%s input_sha256=%s vvp_invoked=0\n' \
            "$name" "$expected_hex.pin" "$expected_pin" "$expected_hex" "$source_sha_pre" "$input_hex" "$input_sha_pre" > "$log"
        printf '97\n' > "$out/compile.rc"; printf '97\n' > "$out/sim.rc"
        PROFILE_COMPILE_RC=97; PROFILE_SIM_RC=97
        printf 'PROFILE_COMPILE_PIN_RESULT name=%s compile_rc=97 vvp_invoked=0 identity=RED\n' "$name" >> "$RUN_LOG"
        return 0
    fi
    cp -- "$input_hex" "$out/probe.hex" || return 1
    embedded_sha_pre="$(strict_sha256_file "$out/probe.hex" "$out/sha/embedded-pre.raw" "$out/sha/embedded-pre.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    if [ "$embedded_sha_pre" != "$expected_pin" ] || ! cmp -s -- "$expected_hex" "$out/probe.hex"; then
        printf 'PROFILE_HEX_PIN_RED stage=pre-compile name=%s pin_path=%s pin_sha256=%s source_hex=%s source_sha256=%s input_hex=%s input_sha256=%s embedded_hex=%s embedded_sha256=%s vvp_invoked=0\n' \
            "$name" "$expected_hex.pin" "$expected_pin" "$expected_hex" "$source_sha_pre" "$input_hex" "$input_sha_pre" "$out/probe.hex" "$embedded_sha_pre" > "$log"
        printf '97\n' > "$out/compile.rc"; printf '97\n' > "$out/sim.rc"
        PROFILE_COMPILE_RC=97; PROFILE_SIM_RC=97
        printf 'PROFILE_COMPILE_PIN_RESULT name=%s compile_rc=97 vvp_invoked=0 identity=RED\n' "$name" >> "$RUN_LOG"
        return 0
    fi
    printf 'PROFILE_HEX_BIND stage=pre name=%s pin_path=%s pin_sha256=%s source_built_hex=%s input_hex=%s embedded_hex=%s source_sha256=%s input_sha256=%s embedded_sha256=%s sha_raw_dir=%s\n' \
        "$name" "$expected_hex.pin" "$expected_pin" "$expected_hex" "$input_hex" "$out/probe.hex" "$source_sha_pre" "$input_sha_pre" "$embedded_sha_pre" "$out/sha" >> "$RUN_LOG"
    printf 'PROFILE_RUN name=%s cwd=%s embedded_hex=%s source_hex=%s pin_sha256=%s argv=' \
        "$name" "$compile_root" "$out/probe.hex" "$expected_hex" "$expected_pin" >> "$RUN_LOG"
    for arg in "${args[@]}"; do printf '%s ' "$arg" >> "$RUN_LOG"; done
    printf '\n' >> "$RUN_LOG"
    ( cd -- "$compile_root" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
        -s tb_data_bus_semantics -P "tb_data_bus_semantics.PROG_HEX=\"$out/probe.hex\"" \
        -o "$out/tb.vvp" $RTLSRC "$TB_REL" ) > "$compile_log" 2>&1 || compile_rc=$?
    printf '%s\n' "$compile_rc" > "$out/compile.rc"
    PROFILE_COMPILE_RC="$compile_rc"
    if [ "$compile_rc" -eq 0 ] && [ -s "$out/tb.vvp" ]; then
        timeout "${TIMEOUT_EXT_RUN_S:-60}" "$VV" "$out/tb.vvp" "${args[@]}" > "$log" 2>&1 || sim_rc=$?
    elif [ "$compile_rc" -eq 0 ]; then
        compile_rc=95; PROFILE_COMPILE_RC="$compile_rc"; printf '%s\n' "$compile_rc" > "$out/compile.rc"
    fi
    source_sha_post="$(strict_sha256_file "$expected_hex" "$out/sha/source-post.raw" "$out/sha/source-post.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    input_sha_post="$(strict_sha256_file "$input_hex" "$out/sha/input-post.raw" "$out/sha/input-post.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    embedded_sha_post="$(strict_sha256_file "$out/probe.hex" "$out/sha/embedded-post.raw" "$out/sha/embedded-post.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    if ! cmp -s -- "$expected_hex" "$input_hex" || ! cmp -s -- "$expected_hex" "$out/probe.hex" || \
       [ "$source_sha_post" != "$expected_pin" ] || [ "$input_sha_post" != "$expected_pin" ] || \
       [ "$embedded_sha_post" != "$expected_pin" ]; then
        printf 'PROFILE_HEX_PIN_RED stage=post-run name=%s pin_path=%s pin_sha256=%s source_post=%s input_post=%s embedded_post=%s vvp_invoked=1\n' \
            "$name" "$expected_hex.pin" "$expected_pin" "$source_sha_post" "$input_sha_post" "$embedded_sha_post" >> "$RUN_LOG"
        return 1
    fi
    printf 'PROFILE_HEX_BIND stage=post-run name=%s pin_path=%s pin_sha256=%s source_built_hex=%s embedded_hex=%s source_sha256=%s input_sha256=%s embedded_sha256=%s sha_raw_dir=%s\n' \
        "$name" "$expected_hex.pin" "$expected_pin" "$expected_hex" "$out/probe.hex" "$source_sha_post" "$input_sha_post" "$embedded_sha_post" "$out/sha" >> "$RUN_LOG"
    printf '%s\n' "$sim_rc" > "$out/sim.rc"
    PROFILE_SIM_RC="$sim_rc"
    printf 'PROFILE_RUN_RESULT name=%s compile_rc=%s sim_rc=%s\n' "$name" "$compile_rc" "$sim_rc" >> "$RUN_LOG"
    return 0
}
profile_replay() {
    local name="$1" vvp="$2" embedded_hex="$3" expected_hex="$4" expected_pin="$5" out="$6"
    shift 6
    local log="$out/probe.log" sim_rc=0 arg sha_rc source_sha_pre source_sha_post embedded_sha_pre embedded_sha_post
    local -a args=("$@")
    mkdir -p -- "$out/sha" || return 1
    [ -f "$expected_hex" ] && [ -f "$embedded_hex" ] || return 1
    [[ "$expected_pin" =~ ^[0-9a-f]{64}$ ]] || return 1
    source_sha_pre="$(strict_sha256_file "$expected_hex" "$out/sha/source-pre.raw" "$out/sha/source-pre.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    embedded_sha_pre="$(strict_sha256_file "$embedded_hex" "$out/sha/embedded-pre.raw" "$out/sha/embedded-pre.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    printf 'PROFILE_REPLAY name=%s vvp=%s embedded_hex=%s source_built_hex=%s pin_path=%s pin_sha256=%s embedded_pre=%s source_pre=%s sha_raw_dir=%s argv=' \
        "$name" "$vvp" "$embedded_hex" "$expected_hex" "$expected_hex.pin" "$expected_pin" "$embedded_sha_pre" "$source_sha_pre" "$out/sha" >> "$RUN_LOG"
    for arg in "${args[@]}"; do printf '%s ' "$arg" >> "$RUN_LOG"; done
    printf '\n' >> "$RUN_LOG"
    if [ "$source_sha_pre" != "$expected_pin" ] || [ "$embedded_sha_pre" != "$expected_pin" ] || \
       ! cmp -s -- "$expected_hex" "$embedded_hex"; then
        printf 'PROFILE_HEX_PIN_RED stage=pre-vvp name=%s embedded_hex=%s source_built_hex=%s pin_path=%s pin_sha256=%s embedded_sha256=%s source_sha256=%s vvp_invoked=0\n' \
            "$name" "$embedded_hex" "$expected_hex" "$expected_hex.pin" "$expected_pin" "$embedded_sha_pre" "$source_sha_pre" > "$log"
        printf '0\n' > "$out/compile.rc"; printf '97\n' > "$out/sim.rc"
        PROFILE_COMPILE_RC=0; PROFILE_SIM_RC=97
        printf 'PROFILE_REPLAY_RESULT name=%s compile_rc=0 sim_rc=97 vvp_invoked=0 identity=RED\n' "$name" >> "$RUN_LOG"
        return 0
    fi
    timeout "${TIMEOUT_EXT_RUN_S:-60}" "$VV" "$vvp" "${args[@]}" > "$log" 2>&1 || sim_rc=$?
    source_sha_post="$(strict_sha256_file "$expected_hex" "$out/sha/source-post.raw" "$out/sha/source-post.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    embedded_sha_post="$(strict_sha256_file "$embedded_hex" "$out/sha/embedded-post.raw" "$out/sha/embedded-post.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    if ! cmp -s -- "$expected_hex" "$embedded_hex" || [ "$source_sha_post" != "$expected_pin" ] || \
       [ "$embedded_sha_post" != "$expected_pin" ]; then
        printf 'PROFILE_HEX_PIN_RED stage=post-vvp name=%s embedded_hex=%s source_built_hex=%s pin_path=%s pin_sha256=%s embedded_pre=%s embedded_post=%s source_pre=%s source_post=%s vvp_invoked=1\n' \
            "$name" "$embedded_hex" "$expected_hex" "$expected_hex.pin" "$expected_pin" "$embedded_sha_pre" "$embedded_sha_post" "$source_sha_pre" "$source_sha_post" >> "$log"
        sim_rc=97
    else
        printf 'PROFILE_HEX_BIND stage=post-vvp name=%s embedded_hex=%s source_built_hex=%s pin_path=%s pin_sha256=%s embedded_sha256=%s source_sha256=%s sha_raw_dir=%s\n' \
            "$name" "$embedded_hex" "$expected_hex" "$expected_hex.pin" "$expected_pin" "$embedded_sha_post" "$source_sha_post" "$out/sha" >> "$log"
    fi
    printf '0\n' > "$out/compile.rc"
    printf '%s\n' "$sim_rc" > "$out/sim.rc"
    PROFILE_COMPILE_RC=0; PROFILE_SIM_RC="$sim_rc"
    printf 'PROFILE_REPLAY_RESULT name=%s compile_rc=0 sim_rc=%s vvp_invoked=1\n' "$name" "$sim_rc" >> "$RUN_LOG"
    return 0
}
profile_expect_pass() {
    local id="$1" log="$2"
    [ "$PROFILE_COMPILE_RC" = 0 ] && [ "$PROFILE_SIM_RC" = 0 ] &&
    [ "$(grep -cxF "DATA_BUS_EXTENSION id=$id PASS" "$log" || true)" = 1 ] &&
    [ "$(grep -cE 'FAIL|UNKNOWN|[^A-Za-z]XZ' "$log" || true)" = 0 ]
}
profile_expect_red() {
    local log="$1" anchor_re="$2"
    [ "$PROFILE_COMPILE_RC" = 0 ] && [ "$PROFILE_SIM_RC" = 1 ] &&
    [ "$(grep -cE "$anchor_re" "$log" || true)" = 1 ] &&
    [ "$(grep -c 'DATA_BUS_EXTENSION id=.* PASS' "$log" || true)" = 0 ]
}
profile_expect_build_pin_red() {
    local log="$1"
    [ "$PROFILE_COMPILE_RC" = 97 ] && [ "$PROFILE_SIM_RC" = 97 ] &&
    [ "$(grep -cE 'PROFILE_HEX_PIN_RED stage=pre-compile name=a_b_build_pin_drift .* vvp_invoked=0' "$log" || true)" = 1 ]
}
profile_expect_hex_identity_red() {
    local log="$1"
    [ "$PROFILE_COMPILE_RC" = 0 ] && [ "$PROFILE_SIM_RC" = 97 ] &&
    [ "$(grep -cE 'PROFILE_HEX_PIN_RED stage=pre-vvp name=a_embedded_hex_drift .* vvp_invoked=0' "$log" || true)" = 1 ]
}
profile_hex_identity_negative() {
    local name="$1" vvp="$2" embedded_hex="$3" source_hex="$4" source_pin="$5" out="$6" replay_rc=0 decoy_sha sha_rc
    shift 6
    local -a args=("$@")
    mkdir -p -- "$out" || return 1
    mkdir -p -- "$out/sha" || return 1
    cp -- "$source_hex" "$out/unconsumed-copy.hex" || return 1
    decoy_sha="$(strict_sha256_file "$out/unconsumed-copy.hex" "$out/sha/decoy.raw" "$out/sha/decoy.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] || return "$sha_rc"
    python3 - "$embedded_hex" <<'PY' || { cp -- "$source_hex" "$embedded_hex"; return 1; }
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding='ascii').splitlines()
for i, line in enumerate(lines):
    if line and not line.startswith('@'):
        lines[i] = ('0' if line[0] != '0' else '1') + line[1:]
        p.write_text('\n'.join(lines) + '\n', encoding='ascii')
        break
else:
    raise SystemExit('no data word found to perturb')
PY
    profile_replay "$name" "$vvp" "$embedded_hex" "$source_hex" "$source_pin" "$out" "${args[@]}" || replay_rc=$?
    cp -- "$source_hex" "$embedded_hex" || return 1
    cmp -s -- "$source_hex" "$embedded_hex" || return 1
    cmp -s -- "$source_hex" "$out/unconsumed-copy.hex" || return 1
    [ "$replay_rc" -eq 0 ] || return 1
    profile_expect_hex_identity_red "$out/probe.log" || return 1
    printf 'PROFILE_HEX_DRIFT_NEGCTRL name=%s embedded_hex=%s unconsumed_copy=%s unconsumed_copy_sha256=%s restored=1 vvp_invoked=0\n' \
        "$name" "$embedded_hex" "$out/unconsumed-copy.hex" "$decoy_sha" >> "$RUN_LOG"
}
run_profile_positive_set() {
    local scope="$1" root="$2"
    local a_good="$root/profile-a/good" b_good="$root/profile-b/good"
    local pin_restore="$root/profile-a/build-pin-restore.hex" pin_probe="$root/profile-a/build-pin-drift"
    local restore_sha pin_sha sha_rc pin_probe_rc=0
    build_profile_image a "$PTW_A_REL" || return 1
    mkdir -p -- "$root/profile-a" || return 1
    cp -- "$PROG_DIR/profile-a.hex" "$pin_restore" || return 1
    restore_sha="$(strict_sha256_file "$pin_restore" "$root/profile-a/build-pin-restore.sha.raw" "$root/profile-a/build-pin-restore.sha.rc")"; sha_rc=$?
    [ "$sha_rc" -eq 0 ] && [ "$restore_sha" = "$PROFILE_A_HEX_PIN" ] || return 1
    if [ "$scope" = targeted ]; then
        profile_args_for_run a || return 1
        PROFILE_TEST_B_BUILD_A_HEX_DRIFT=1
        if ! build_profile_image b "$PTW_B_REL"; then
            PROFILE_TEST_B_BUILD_A_HEX_DRIFT=0
            cp -- "$pin_restore" "$PROG_DIR/profile-a.hex" || return 1
            return 1
        fi
        PROFILE_TEST_B_BUILD_A_HEX_DRIFT=0
        profile_compile_run a_b_build_pin_drift "$SNAP" "$PROG_DIR/profile-a.hex" "$pin_probe" \
            "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" "${PROFILE_RUN_ARGS[@]}" || pin_probe_rc=$?
        cp -- "$pin_restore" "$PROG_DIR/profile-a.hex" || return 1
        pin_sha="$(strict_sha256_file "$PROG_DIR/profile-a.hex" "$root/profile-a/build-pin-restored.sha.raw" "$root/profile-a/build-pin-restored.sha.rc")"; sha_rc=$?
        [ "$sha_rc" -eq 0 ] && [ "$pin_sha" = "$PROFILE_A_HEX_PIN" ] || return 1
        cmp -s -- "$pin_restore" "$PROG_DIR/profile-a.hex" || return 1
        [ "$pin_probe_rc" -eq 0 ] || return 1
        profile_expect_build_pin_red "$pin_probe/probe.log" || return 1
        printf 'PROFILE_HEX_B_BUILD_PIN_NEGCTRL stage=b-assemble-before-objcopy path=%s pin_sha256=%s restored_sha256=%s compile_invoked=0 vvp_invoked=0\n' \
            "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" "$pin_sha" >> "$RUN_LOG"
    else
        build_profile_image b "$PTW_B_REL" || return 1
    fi
    mkdir -p -- "$a_good" "$b_good" || return 1
    profile_args_for_run a || return 1
    profile_compile_run a_good "$SNAP" "$PROG_DIR/profile-a.hex" "$a_good" "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" "${PROFILE_RUN_ARGS[@]}" || return 1
    profile_expect_pass 17 "$a_good/probe.log" || return 1
    grep -Eq 'PROFILE_A_TRAP_COUNTS M=0 S=0 lifetime=[1-9][0-9]* tag_reuse=1 ghost=0' "$a_good/probe.log" || return 1
    grep -Eq 'PROFILE_A_GHOST_BOUNDARIES kill=1 stale=[1-9][0-9]* idle=[1-9][0-9]* reuse=1 active=0 neg_mode=0 neg_used=0' "$a_good/probe.log" || return 1
    profile_args_for_run b || return 1
    profile_compile_run b_good "$SNAP" "$PROG_DIR/profile-b.hex" "$b_good" "$PROG_DIR/profile-b.hex" "$PROFILE_B_HEX_PIN" "${PROFILE_RUN_ARGS[@]}" || return 1
    profile_expect_pass 18 "$b_good/probe.log" || return 1
    grep -Eq 'PROFILE_B_LIFETIME_TRAP_POST summary owner_reuse=0 ghost=0 life=[1-9][0-9]* M=0 S=0 pte_req=2 pte_rsp=2 root_done=1 leaf_done=1 walk_done=1 seqerr=0 pending=0 complete=1' "$b_good/probe.log" || return 1
    grep -Eq 'PROFILE_B_GHOST_BOUNDARIES kill=1 stale=[1-9][0-9]* idle=[1-9][0-9]* reuse=0 active=1 neg_mode=0 neg_used=0' "$b_good/probe.log" || return 1
    [ "$(grep -c 'PROFILE_B_POST_PTE_REQ .*n=0 va=80400080 pa=8001b804' "$b_good/probe.log" || true)" = 1 ] || return 1
    [ "$(grep -c 'PROFILE_B_POST_PTE_DONE .*pa=8001b804 pte=20007801' "$b_good/probe.log" || true)" = 1 ] || return 1
    [ "$(grep -c 'PROFILE_B_POST_PTE_REQ .*n=1 va=80400080 pa=8001e000' "$b_good/probe.log" || true)" = 1 ] || return 1
    [ "$(grep -c 'PROFILE_B_POST_PTE_DONE .*pa=8001e000 pte=20000ccf' "$b_good/probe.log" || true)" = 1 ] || return 1
    grep -Fq 'PROFILE_B_POST_STALE_IF_STILL_BUSY' "$b_good/probe.log" || return 1
    PROFILE_A_GOOD="$a_good"; PROFILE_B_GOOD="$b_good"
    printf 'DATA_BUS_PROFILE_POSITIVE_SET scope=%s A17=PASS B18=PASS\n' "$scope" >> "$RUN_LOG"
}
if [ "$MODE" = "profile-targeted-only" ]; then
    mkdir -p -- "$RUN_DIR/oldgate"
    run_profile_positive_set targeted "$RUN_DIR" || emit_fail profile_positive_set
    profile_args_for_run a || emit_fail profile_a_args
    profile_hex_identity_negative a_embedded_hex_drift "$PROFILE_A_GOOD/tb.vvp" "$PROFILE_A_GOOD/probe.hex" \
        "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" "$RUN_DIR/profile-a/hex-identity-neg" "${PROFILE_RUN_ARGS[@]}" || emit_fail profile_hex_identity_negative
    # Same generated A image, with exactly the legacy one-line TopB admission expression restored.
    OLDGATE_SOURCE="$RUN_DIR/oldgate/source"
    OLDGATE_ROOT="$RUN_DIR/oldgate/snapshot"
    mkdir -p -- "$OLDGATE_SOURCE" "$OLDGATE_ROOT"
    cp -a -- "$SNAP/." "$OLDGATE_SOURCE/" || emit_fail oldgate_source_copy
    cp -a -- "$OLDGATE_SOURCE/." "$OLDGATE_ROOT/" || emit_fail oldgate_snapshot_copy
    oldgate_manifest() {
        local root="$1" out="$2"
        while IFS= read -r rel; do (cd -- "$root" && sha256sum -- "$rel") || return 1; done < "$SRC_LIST" > "$out"
    }
    oldgate_manifest "$OLDGATE_SOURCE" "$RUN_DIR/oldgate/source.sha.before" || emit_fail oldgate_source_sha_before
    oldgate_manifest "$OLDGATE_ROOT" "$RUN_DIR/oldgate/snapshot.sha.copy.prepatch" || emit_fail oldgate_snapshot_sha_prepatch
    cmp -s "$RUN_DIR/oldgate/source.sha.before" "$RUN_DIR/src.sha.copy" || emit_fail oldgate_source_not_frozen_copy
    python3 - "$SNAP" "$OLDGATE_SOURCE" "$OLDGATE_ROOT" "$SRC_LIST" "$RUN_DIR/oldgate/topb.delta.txt" <<'PY' || emit_fail oldgate_patch
from pathlib import Path
import sys
snap, source, patched_root, manifest, note = map(Path, sys.argv[1:])
rel = 'rtl/top/core_top_2b.v'
old = 'wire        d_ptw_accept_w = d_ptw_want_w & ~d_tag_cancel_live_load_w;'
new = 'wire        d_ptw_accept_w = d_ptw_want_w;'
if (source / rel).read_bytes() != (snap / rel).read_bytes():
    raise SystemExit('old-gate source copy differs from frozen snapshot')
base = (source / rel).read_text()
if base.count(old) != 1:
    raise SystemExit('old-gate source anchor must occur exactly once')
patched = base.replace(old, new, 1)
(patched_root / rel).write_text(patched)
files = manifest.read_text().splitlines()
diff = [p for p in files if (source / p).read_bytes() != (patched_root / p).read_bytes()]
if diff != [rel]:
    raise SystemExit('old-gate snapshot delta must be exactly TopB expression file')
a, b = base.splitlines(), patched.splitlines()
if len(a) != len(b) or sum(x != y for x, y in zip(a, b)) != 1:
    raise SystemExit('old gate changed other TopB lines')
note.write_text('OLD_GATE_ONLY_TOPB_EXPRESSION_DELTA=1\n' +
                'source_topb_sha256=' + __import__('hashlib').sha256(base.encode()).hexdigest() + '\n' +
                'snapshot_topb_sha256=' + __import__('hashlib').sha256(patched.encode()).hexdigest() + '\n')
PY
    oldgate_manifest "$OLDGATE_ROOT" "$RUN_DIR/oldgate/snapshot.sha.before" || emit_fail oldgate_snapshot_sha_before
    cp -- "$PROG_DIR/profile-a.hex" "$RUN_DIR/oldgate/probe.hex" || emit_fail oldgate_hex_copy
    cmp -s -- "$PROG_DIR/profile-a.hex" "$PROFILE_A_GOOD/probe.hex" || emit_fail profile_a_good_hex_identity
    cmp -s -- "$PROG_DIR/profile-a.hex" "$RUN_DIR/oldgate/probe.hex" || emit_fail oldgate_hex_identity
    profile_compile_run a_oldgate "$OLDGATE_ROOT" "$RUN_DIR/oldgate/probe.hex" "$RUN_DIR/oldgate/run" "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" "${PROFILE_RUN_ARGS[@]}" || emit_fail oldgate_compile_run
    profile_expect_red "$RUN_DIR/oldgate/run/probe.log" 'PROFILE_A_OLD_GATE_RED t=[0-9]+ ad=5 va=00400000 tag=3 accept=1 idle=1 ready=1' || emit_fail oldgate_exact_red
    for phase in 1 2 3; do
        profile_replay "a_ghost_phase_${phase}" "$PROFILE_A_GOOD/tb.vvp" "$PROFILE_A_GOOD/probe.hex" "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" \
            "$RUN_DIR/profile-a/ghost-phase-${phase}" "${PROFILE_RUN_ARGS[@]}" "+PROFILE_A_GHOST_NEGCTRL=${phase}" || emit_fail "profile_a_ghost_phase_${phase}_run"
        profile_expect_red "$RUN_DIR/profile-a/ghost-phase-${phase}/probe.log" "PROFILE_A_GHOST_MONITOR_SENSITIVITY_RED mode=${phase} count=1" || emit_fail "profile_a_ghost_phase_${phase}_red"
        [ "$(grep -c 'PROFILE_A_GHOST_RSP_OBSERVED .*injected=1' "$RUN_DIR/profile-a/ghost-phase-${phase}/probe.log" || true)" = 1 ] || emit_fail "profile_a_ghost_phase_${phase}_tap"
    done
    profile_replay a_bad_data_neg "$PROFILE_A_GOOD/tb.vvp" "$PROFILE_A_GOOD/probe.hex" "$PROG_DIR/profile-a.hex" "$PROFILE_A_HEX_PIN" \
        "$RUN_DIR/profile-a/bad-data-neg" "${PROFILE_RUN_ARGS[@]}" +PROFILE_BAD_DATA_ADDR=1fe01200 || emit_fail profile_a_bad_data_run
    profile_expect_red "$RUN_DIR/profile-a/bad-data-neg/probe.log" 'PROFILE_A_BAD_LOAD_DATA_RED injections=1 reported=deadc0de' || emit_fail profile_a_bad_data_negative
    profile_args_for_run b || emit_fail profile_b_args
    for phase in 1 2 3; do
        profile_replay "b_ghost_phase_${phase}" "$PROFILE_B_GOOD/tb.vvp" "$PROFILE_B_GOOD/probe.hex" "$PROG_DIR/profile-b.hex" "$PROFILE_B_HEX_PIN" \
            "$RUN_DIR/profile-b/ghost-phase-${phase}" "${PROFILE_RUN_ARGS[@]}" "+PROFILE_B_GHOST_NEGCTRL=${phase}" || emit_fail "profile_b_ghost_phase_${phase}_run"
        profile_expect_red "$RUN_DIR/profile-b/ghost-phase-${phase}/probe.log" "PROFILE_B_GHOST_MONITOR_SENSITIVITY_RED mode=${phase} count=1" || emit_fail "profile_b_ghost_phase_${phase}_red"
        [ "$(grep -c 'PROFILE_B_GHOST_RSP_OBSERVED .*injected=1' "$RUN_DIR/profile-b/ghost-phase-${phase}/probe.log" || true)" = 1 ] || emit_fail "profile_b_ghost_phase_${phase}_tap"
    done
    profile_replay b_repeat_done_neg "$PROFILE_B_GOOD/tb.vvp" "$PROFILE_B_GOOD/probe.hex" "$PROG_DIR/profile-b.hex" "$PROFILE_B_HEX_PIN" \
        "$RUN_DIR/profile-b/repeat-done-neg" "${PROFILE_RUN_ARGS[@]}" +PROFILE_B_REPEAT_DONE_NEGCTRL || emit_fail profile_b_repeat_done_run
    profile_expect_red "$RUN_DIR/profile-b/repeat-done-neg/probe.log" 'PROFILE_B_REPEAT_WALK_DONE_RED count=2 expected=1' || emit_fail profile_b_repeat_done_red
    [ "$(grep -c 'PROFILE_B_REPEAT_DONE_NEGCTRL_INJECT' "$RUN_DIR/profile-b/repeat-done-neg/probe.log" || true)" = 1 ] || emit_fail profile_b_repeat_done_injection
    oldgate_manifest "$OLDGATE_SOURCE" "$RUN_DIR/oldgate/source.sha.after" || emit_fail oldgate_source_sha_after
    oldgate_manifest "$OLDGATE_ROOT" "$RUN_DIR/oldgate/snapshot.sha.after" || emit_fail oldgate_snapshot_sha_after
    cmp -s "$RUN_DIR/oldgate/source.sha.before" "$RUN_DIR/oldgate/source.sha.after" || emit_fail oldgate_source_mutated
    cmp -s "$RUN_DIR/oldgate/snapshot.sha.before" "$RUN_DIR/oldgate/snapshot.sha.after" || emit_fail oldgate_snapshot_mutated
    verify_after_inputs
    printf 'DATA_BUS_PROFILE_TARGETED: PASS\n'
    exit 0
fi
if [ "$MODE" = "profile-source-build-only" ]; then
    build_profile_image a "$PTW_A_REL" || emit_fail profile_a_source_assemble
    build_profile_image b "$PTW_B_REL" || emit_fail profile_b_source_assemble
    profile_args_for_run a || emit_fail profile_a_args
    printf 'PROFILE_ARGS_A=%s\n' "${PROFILE_RUN_ARGS[*]}" >> "$RUN_LOG"
    profile_args_for_run b || emit_fail profile_b_args
    printf 'PROFILE_ARGS_B=%s\n' "${PROFILE_RUN_ARGS[*]}" >> "$RUN_LOG"
    verify_after_inputs
    printf 'DATA_BUS_PROFILE_SOURCE_BUILD: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 3. 编译（快照 root、相对 -I）
#------------------------------------------------------------------------------
COMPILE_LOG="$RUN_DIR/compile.log"
printf 'COMPILE_CWD=%s\nCOMPILE_INCLUDE=-I rtl/pkg -I .\n' "$SNAP" >> "$RUN_LOG"
( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
    -s tb_data_bus_semantics \
    -P "tb_data_bus_semantics.PROG_HEX=\"$PROG_DIR/dbs.hex\"" \
    -o "$RUN_DIR/tb_data_bus_semantics.vvp" $RTLSRC "$TB_REL" ) > "$COMPILE_LOG" 2>&1
C_RC=$?
[ "$C_RC" -eq 0 ] || { cat "$COMPILE_LOG" >> "$RUN_LOG"; emit_fail "compile_rc=$C_RC"; }
[ -s "$RUN_DIR/tb_data_bus_semantics.vvp" ] || emit_fail compile_zero

# Product-specific extension firmware shares the same TB/RTL snapshot but not the
# legacy 16-check schema or HEX image.
EXT_ASM_LOG="$RUN_DIR/extension-asm.log"
"$GCC" -march=rv32ima_zicsr_zifencei_zicbom -mabi=ilp32 -nostdlib -nostartfiles \
    -Ttext=0x80000000 -o "$PROG_DIR/dbs_ext.elf" "$PROG_DIR/dbs_ext.S" \
    > "$EXT_ASM_LOG" 2>&1 || { cat "$EXT_ASM_LOG" >> "$RUN_LOG"; emit_fail extension_assemble; }
"$OBJCOPY" -O binary "$PROG_DIR/dbs_ext.elf" "$PROG_DIR/dbs_ext.bin" >> "$EXT_ASM_LOG" 2>&1 \
    || emit_fail extension_objcopy
python3 - "$PROG_DIR/dbs_ext.bin" 0x80000000 "$PROG_DIR/dbs_ext.hex" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
with open(sys.argv[3], 'w') as f:
    f.write('@%08x\n' % int(sys.argv[2], 0))
    for w in struct.unpack('<%dI' % (len(b)//4), b): f.write('%08x\n' % w)
PY
EXT_COMPILE_LOG="$RUN_DIR/extension-compile.log"
( cd -- "$SNAP" && timeout "${TIMEOUT_COMPILE_S:-900}" "$IV" -g2012 -I rtl/pkg -I . \
    -s tb_data_bus_semantics -P "tb_data_bus_semantics.PROG_HEX=\"$PROG_DIR/dbs_ext.hex\"" \
    -o "$RUN_DIR/tb_data_bus_extension.vvp" $RTLSRC "$TB_REL" ) > "$EXT_COMPILE_LOG" 2>&1
EXT_COMPILE_RC=$?
[ "$EXT_COMPILE_RC" -eq 0 ] || { cat "$EXT_COMPILE_LOG" >> "$RUN_LOG"; emit_fail "extension_compile_rc=$EXT_COMPILE_RC"; }
[ -s "$RUN_DIR/tb_data_bus_extension.vvp" ] || emit_fail extension_compile_zero
printf 'EXT_PROGRAM bytes=%s sha256=%s\n' "$(stat -c %s -- "$PROG_DIR/dbs_ext.bin")" \
    "$(sha256sum "$PROG_DIR/dbs_ext.hex" | awk '{print $1}')" >> "$RUN_LOG"

run_extension_group() {
    local id="$1" rerr="$2" probe="${3:-}" log="$RUN_DIR/extension-$1${3:+-$3}.log" rc=0
    local args=("+CONT=0x${CONT_ADDR}" "+EXT=${id}") branch_pc fresh_pc itlb_va pmp_pc
    [ -n "$rerr" ] && args+=("+RERR_ADDR=${rerr}")
    if [ "$id" = "10" ]; then
        branch_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "branch_redirect_target" {print $1; exit}')
        fresh_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "fresh_vpn_target" {print $1; exit}')
        [ -n "$branch_pc" ] && [ -n "$fresh_pc" ] || return 1
        itlb_va=$(printf '0x%08x' "$((0x${fresh_pc} + 0x00400000))")
        args+=("+RERR_ADDR=8001c000" "+RDELAY_ADDR=8001c000" "+RDELAY_CYCLES=80" "+BRANCH_TARGET=0x${branch_pc}" "+ITLB_TARGET=${itlb_va}")
    elif [ "$id" = "15" ]; then
        branch_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "branch_redirect_target" {print $1; exit}')
        fresh_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "fresh_vpn_target" {print $1; exit}')
        [ -n "$branch_pc" ] && [ -n "$fresh_pc" ] || return 1
        itlb_va=$(printf '0x%08x' "$((0x${fresh_pc} + 0x00400000))")
        args+=("+RERR_ADDR=8001c000" "+RDELAY_ADDR=8001c000" "+RDELAY_CYCLES=80" "+BRANCH_TARGET=0x${branch_pc}" "+ITLB_TARGET=${itlb_va}")
    elif [ "$id" = "16" ]; then
        branch_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "branch_redirect_target" {print $1; exit}')
        fresh_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "fresh_vpn_target" {print $1; exit}')
        [ -n "$branch_pc" ] && [ -n "$fresh_pc" ] || return 1
        itlb_va=$(printf '0x%08x' "$((0x${fresh_pc} + 0x00400000))")
        args+=("+ARSTALL_ADDR=8001b000" "+ARSTALL_CYCLES=120" "+BRANCH_TARGET=0x${branch_pc}" "+ITLB_TARGET=${itlb_va}")
    elif [ "$id" = "11" ]; then
        pmp_pc=$("$NM" "$PROG_DIR/dbs_ext.elf" | awk '$3 == "pmp_after_csr" {print $1; exit}')
        [ -n "$pmp_pc" ] || return 1
        args+=("+BDELAY_ADDR=1fe01200" "+BDELAY_CYCLES=12" "+PMP_AFTER_PC=0x${pmp_pc}")
        [ "$probe" = pmp-repeat ] && args+=("+PMP_REPEAT=1")
    fi
    timeout "${TIMEOUT_EXT_RUN_S:-60}" "$VV" "$RUN_DIR/tb_data_bus_extension.vvp" "${args[@]}" > "$log" 2>&1 || rc=$?
    if [ "$probe" = pmp-repeat ]; then
        if [ "$rc" -ne 0 ] && [ "$(grep -cxF 'FAIL: extension old store B drain before unique PMP CSR+4 refetch target' "$log" || true)" = 1 ] &&
           [ "$(grep -cxF "DATA_BUS_EXTENSION id=$id PASS" "$log" || true)" = 0 ]; then
            printf 'DATA_BUS_EXTENSION_PROBE name=pmp_repeat rc=%s REJECTED\n' "$rc" >> "$RUN_LOG"
            return 0
        fi
        cat -- "$log" >> "$RUN_LOG"
        return 1
    fi
    if [ "$rc" -ne 0 ] || [ "$(grep -cxF "DATA_BUS_EXTENSION id=$id PASS" "$log" || true)" != 1 ] ||
       [ "$(grep -cE 'FAIL|UNKNOWN|[^A-Za-z]XZ' "$log" || true)" != 0 ]; then
        cat -- "$log" >> "$RUN_LOG"
        return 1
    fi
    cat -- "$log" >> "$RUN_LOG"
    printf 'DATA_BUS_EXTENSION_CASE id=%s rc=%s rerr=%s PASS\n' "$id" "$rc" "${rerr:-none}" >> "$RUN_LOG"
}
run_extension_schema_probe() {
    local probe="$1" log="$RUN_DIR/extension-probe-$1.log" rc=0
    local args=("+CONT=0x${CONT_ADDR}" "+EXT=2" "+RERR_ADDR=8001c000" "+SCHEMAPROBE=${probe}")
    timeout "${TIMEOUT_EXT_RUN_S:-60}" "$VV" "$RUN_DIR/tb_data_bus_extension.vvp" "${args[@]}" > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && [ "$(grep -cF 'FAIL: extension S trap count/stval id=2' "$log" || true)" = 1 ] &&
       [ "$(grep -cxF 'DATA_BUS_EXTENSION id=2 PASS' "$log" || true)" = 0 ]; then
        printf 'DATA_BUS_EXTENSION_PROBE name=%s rc=%s REJECTED\n' "$probe" "$rc" >> "$RUN_LOG"
        return 0
    fi
    cat -- "$log" >> "$RUN_LOG"
    return 1
}
EXTENSION_CASES_TOTAL=16
if [ "$MODE" = "extension-case-1" ]; then
    run_extension_group 1 '' || emit_fail extension_fast_store7_slow_store
    EXTENSION_CASES_TOTAL=1
elif [ "$MODE" = "extension-cases-2-5" ]; then
    run_extension_group 2 '8001c000' || emit_fail extension_pte_load_early
    run_extension_group 3 '8001c01c' || emit_fail extension_pte_store_late
    run_extension_group 4 '' || emit_fail extension_pte_pmp_load
    run_extension_group 5 '' || emit_fail extension_pte_pmp_store
    EXTENSION_CASES_TOTAL=4
elif [ "$MODE" = "extension-cases-6-9" ]; then
    run_extension_group 6 '' || emit_fail extension_pa34_root
    run_extension_group 7 '' || emit_fail extension_pa34_leaf
    run_extension_group 8 '' || emit_fail extension_invalid_leaf_load
    run_extension_group 9 '' || emit_fail extension_invalid_leaf_store
    EXTENSION_CASES_TOTAL=4
elif [ "$MODE" = "extension-case-10" ]; then
    run_extension_group 10 '' || emit_fail extension_branch_kill_drain
    EXTENSION_CASES_TOTAL=1
elif [ "$MODE" = "extension-case-11" ]; then
    run_extension_group 11 '' || emit_fail extension_pmp_bdelay_csr_plus4
    EXTENSION_CASES_TOTAL=1
elif [ "$MODE" = "extension-case-14" ]; then
    run_extension_group 14 '' || emit_fail extension_high_pa_store_af7
    EXTENSION_CASES_TOTAL=1
elif [ "$MODE" = "extension-case-15" ]; then
    run_extension_group 15 '' || emit_fail extension_ptehit_branch_kill
    EXTENSION_CASES_TOTAL=1
elif [ "$MODE" = "extension-case-16" ]; then
    run_extension_group 16 '' || emit_fail extension_initial_ptw_tagkill
    EXTENSION_CASES_TOTAL=1
elif [ "$MODE" = "extension-cases-14-16" ]; then
    run_extension_group 14 '' || emit_fail extension_high_pa_store_af7
    run_extension_group 15 '' || emit_fail extension_ptehit_branch_kill
    run_extension_group 16 '' || emit_fail extension_initial_ptw_tagkill
    EXTENSION_CASES_TOTAL=3
elif [ "$MODE" = "extension-cases-12-13" ]; then
    run_extension_group 12 '8001d200' || emit_fail extension_cached_data_rresp_beat0
    run_extension_group 13 '8001d21c' || emit_fail extension_cached_data_rresp_beat7
    EXTENSION_CASES_TOTAL=2
else
    run_extension_group 1 '' || emit_fail extension_fast_store7_slow_store
    run_extension_group 2 '8001c000' || emit_fail extension_pte_load_early
    run_extension_group 3 '8001c01c' || emit_fail extension_pte_store_late
    run_extension_group 4 '' || emit_fail extension_pte_pmp_load
    run_extension_group 5 '' || emit_fail extension_pte_pmp_store
    run_extension_group 6 '' || emit_fail extension_pa34_root
    run_extension_group 7 '' || emit_fail extension_pa34_leaf
    run_extension_group 8 '' || emit_fail extension_invalid_leaf_load
    run_extension_group 9 '' || emit_fail extension_invalid_leaf_store
    run_extension_group 10 '' || emit_fail extension_branch_kill_drain
    run_extension_group 11 '' || emit_fail extension_pmp_bdelay_csr_plus4
    run_extension_group 12 '8001d200' || emit_fail extension_cached_data_rresp_beat0
    run_extension_group 13 '8001d21c' || emit_fail extension_cached_data_rresp_beat7
    run_extension_group 14 '' || emit_fail extension_high_pa_store_af7
    run_extension_group 15 '' || emit_fail extension_ptehit_branch_kill
    run_extension_group 16 '' || emit_fail extension_initial_ptw_tagkill
    if [ "$MODE" = "spec" ]; then
        run_profile_positive_set spec "$RUN_DIR/profile-positive" || emit_fail profile_positive_set
        EXTENSION_CASES_TOTAL=18
    fi
    run_extension_schema_probe STVAL0 || emit_fail extension_stval_zero_counterproof
    run_extension_schema_probe STVALPA || emit_fail extension_stval_pa_counterproof
    run_extension_schema_probe EXTRA_M || emit_fail extension_extra_m_trap_counterproof
    run_extension_schema_probe EXTRA_S || emit_fail extension_extra_s_trap_counterproof
    run_extension_group 11 '' pmp-repeat || emit_fail extension_pmp_repeat_counterproof
fi
if [ "$MODE" = "extension-only" ] || [ "$MODE" = "extension-case-1" ] || [ "$MODE" = "extension-cases-2-5" ] || [ "$MODE" = "extension-cases-6-9" ] || [ "$MODE" = "extension-case-10" ] || [ "$MODE" = "extension-case-11" ] || [ "$MODE" = "extension-cases-12-13" ] || [ "$MODE" = "extension-case-14" ] || [ "$MODE" = "extension-case-15" ] || [ "$MODE" = "extension-case-16" ] || [ "$MODE" = "extension-cases-14-16" ]; then EXTENSION_ONLY_PASS=1; else EXTENSION_ONLY_PASS=0; fi

if [ "$EXTENSION_ONLY_PASS" -eq 1 ]; then
    verify_after_inputs
    printf 'DATA_BUS_EXTENSION_ONLY total=%s ok=%s\n' "$EXTENSION_CASES_TOTAL" "$EXTENSION_CASES_TOTAL"
    printf 'DATA_BUS_EXTENSION_ONLY: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 4. 真跑 + 判定
#------------------------------------------------------------------------------
RUN_ONE_LOG="$RUN_DIR/run.log"
timeout "${TIMEOUT_RUN_S:-900}" "$VV" "$RUN_DIR/tb_data_bus_semantics.vvp" \
    "+CONT=0x${CONT_ADDR}" > "$RUN_ONE_LOG" 2>&1
R_RC=$?
[ "$R_RC" -eq 124 ] && emit_fail run_timeout
[ "$R_RC" -ne 0 ] && { cat "$RUN_ONE_LOG" >> "$RUN_LOG"; emit_fail "run_rc=$R_RC"; }
[ -s "$RUN_ONE_LOG" ] || emit_fail run_empty
NP=$(grep -cxF "$ANCHOR" "$RUN_ONE_LOG" || true)
[ "$NP" = "1" ] || { grep -E 'PASS|FAIL' "$RUN_ONE_LOG" >> "$RUN_LOG" || true; emit_fail "anchor=$NP"; }
NB=$(grep -cE 'FAIL|[^A-Za-z]XZ|UNKNOWN' "$RUN_ONE_LOG" || true)
[ "$NB" = "0" ] || { cat "$RUN_ONE_LOG" >> "$RUN_LOG"; emit_fail "bad_tokens=$NB"; }
grep -E '^(DATA_BUS_RESULT|DATA_BUS_COUNTS|  r[0-9]+ =)' "$RUN_ONE_LOG" >> "$RUN_LOG" || true
cat -- "$RUN_ONE_LOG" >> "$RUN_LOG"

# W/AW association counterproofs using the same compiled DUT image.
# Stall controls are legal positive controls; W payload/strobe corruption is explicitly
# injected at the TB-only slave boundary, never presented as natural product behavior.
run_tb_probe() {
    local name="$1" kind="$2" arg="$3" expect="$4" rc=0 log="$RUN_DIR/probe-$1.log"
    timeout "${TIMEOUT_RUN_S:-900}" "$VV" "$RUN_DIR/tb_data_bus_semantics.vvp" "+CONT=0x${CONT_ADDR}" "$arg" > "$log" 2>&1 || rc=$?
    if [ "$kind" = green ]; then
        [ "$rc" -eq 0 ] && [ "$(grep -cxF "$ANCHOR" "$log" || true)" = 1 ] &&
        [ "$(grep -cE 'FAIL|DEFECT|UNKNOWN|[^A-Za-z]XZ' "$log" || true)" = 0 ] || return 1
    else
        [ "$rc" -ne 0 ] && [ "$(grep -cF "$expect" "$log" || true)" = 1 ] &&
        [ "$(grep -cF 'FAIL' "$log" || true)" = 1 ] &&
        [ "$(grep -cxF "$ANCHOR" "$log" || true)" = 0 ] || return 1
    fi
    cat -- "$log" >> "$RUN_LOG"
    printf 'DATA_BUS_PROBE name=%s kind=%s rc=%s signature=%s\n' "$name" "$kind" "$rc" "$expect" >> "$RUN_LOG"
}
run_tb_probe aw_stall green +AWSTALL=2 PASS || emit_fail probe_aw_stall
run_tb_probe w_stall green +WSTALL=2 PASS || emit_fail probe_w_stall
run_tb_probe uart_wrong red +WPROBE=UART_WRONG 'FAIL: ecall/maint UART writes' || emit_fail probe_uart_wrong
run_tb_probe uart_zero red +WPROBE=UART_ZERO 'FAIL: ecall/maint UART writes' || emit_fail probe_uart_zero
run_tb_probe uart_lane red +WPROBE=UART_LANE 'FAIL: UART WSTRB' || emit_fail probe_uart_lane
run_tb_probe schema_zero red +SCHEMAPROBE=NCHK0 'FAIL: fixed schema requires nchk=16' || emit_fail probe_schema_zero
run_tb_probe schema_x red +SCHEMAPROBE=NCHKX 'FAIL: fixed schema requires nchk=16' || emit_fail probe_schema_x
run_tb_probe uart_x red +SCHEMAPROBE=UARTX 'FAIL: ecall/maint UART writes' || emit_fail probe_uart_x
run_tb_probe arm_x red +CTRLPROBE=ARM_X 'FAIL: active device-read control X/Z' || emit_fail probe_arm_x
run_tb_probe arm_z red +CTRLPROBE=ARM_Z 'FAIL: active device-read control X/Z' || emit_fail probe_arm_z
run_tb_probe side_x red +CTRLPROBE=SIDE_X 'FAIL: active device-read control X/Z' || emit_fail probe_side_x
run_tb_probe side_z red +CTRLPROBE=SIDE_Z 'FAIL: active device-read control X/Z' || emit_fail probe_side_z
run_tb_probe trap_x red +CTRLPROBE=TRAP_X 'FAIL: active device-read control X/Z' || emit_fail probe_trap_x
run_tb_probe trap_z red +CTRLPROBE=TRAP_Z 'FAIL: active device-read control X/Z' || emit_fail probe_trap_z

verify_after_inputs

printf 'FUNCTIONAL_DATA_BUS: PASS\n' >> "$RUN_LOG"
[ "$(grep -cxF 'FUNCTIONAL_DATA_BUS: PASS' "$RUN_LOG" || true)" = "1" ] || emit_fail driver_anchor
printf 'DATA_BUS_EXTENSION total=%s ok=%s\n' "$EXTENSION_CASES_TOTAL" "$EXTENSION_CASES_TOTAL"
printf 'DATA_BUS_TESTS total=14 ok=14\n'
printf 'FUNCTIONAL_DATA_BUS: PASS\n'
exit 0
