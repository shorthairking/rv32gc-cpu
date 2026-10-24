#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_2a_control_driver.sh —— 单个 2A 控制/计数 case 的运行+门控
#==============================================================================
# 职责（只做一件事，判定 fail-closed）：
#   用给定 vvp + plusargs 跑一个 case，然后要求：
#     ① vvp rc == 0（超时 124 也算失败）；
#     ② 日志非空，且整行 `2A_CTL_RESULT: PASS` **恰好 1 次**；
#     ③ 日志中 `2A_CTL_CHK_BAD` / `2A_CTL_FAIL` / `2A_CTL_TIMEOUT` **0 次**；
#     ④ `2A_CTL_CHECKS: total=<N> bad=0` 恰 1 行，且 N == --checks（固定表）。
#   成功打印一行机器可读记录（由 test_2a_control.sh 逐项复检），不打印任何 PASS 锚点；
#   失败打印 `2A_CONTROL_DRIVER_BAD: ...` 并 exit 1（原因不吞）。
#
# 参数：--id --name --scen --kind --hex --ctrl-pc --mret-pc --exp-epc --irq
#       --rdelay --checks --log --vvp [--data-addr --data-val]
# 自检：--self-test 用构造日志反证 ①–④ 的拒绝路径，通过时打印
#       `FUNCTIONAL_2A_CONTROL_DRIVER_NEGATIVE: PASS`。
#==============================================================================
set -euo pipefail

ID=""; NAME=""; SCEN=""; KIND=""; HEXF=""; CTRL_PC="0x00000000"; MRET_PC="0x00000000"
EXP_EPC="0x00000000"; EXP_TVAL="0x00000000"; CANCEL="0"; ARM_HI="0"; DLY_LO="0x00003000"; DLY_HI="0x00003100"; ERR_LO="0x00000000"; ERR_HI="0x00000000"; ERR_KIND="0"; IRQ="0"; RDELAY="0"; CHECKS=""; LOG=""; VVP=""
DATA_ADDR="0x00003000"; DATA_VAL="0x5A5A1234"
LOAD_PC="0x00000000"; BR_PC="0x00000000"; EXP_MARKER="0x00000000"; EXP_BAD_MARKER="0x00000000"
SELF=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --id) ID="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --scen) SCEN="$2"; shift 2 ;;
        --kind) KIND="$2"; shift 2 ;;
        --hex) HEXF="$2"; shift 2 ;;
        --ctrl-pc) CTRL_PC="$2"; shift 2 ;;
        --mret-pc) MRET_PC="$2"; shift 2 ;;
        --exp-epc) EXP_EPC="$2"; shift 2 ;;
        --exp-tval) EXP_TVAL="$2"; shift 2 ;;
        --cancel) CANCEL="$2"; shift 2 ;;
        --arm-hi) ARM_HI="$2"; shift 2 ;;
        --delay-lo) DLY_LO="$2"; shift 2 ;;
        --delay-hi) DLY_HI="$2"; shift 2 ;;
        --err-lo) ERR_LO="$2"; shift 2 ;;
        --err-hi) ERR_HI="$2"; shift 2 ;;
        --err-kind) ERR_KIND="$2"; shift 2 ;;
        --irq) IRQ="$2"; shift 2 ;;
        --rdelay) RDELAY="$2"; shift 2 ;;
        --checks) CHECKS="$2"; shift 2 ;;
        --log) LOG="$2"; shift 2 ;;
        --vvp) VVP="$2"; shift 2 ;;
        --data-addr) DATA_ADDR="$2"; shift 2 ;;
        --data-val) DATA_VAL="$2"; shift 2 ;;
        --load-pc) LOAD_PC="$2"; shift 2 ;;
        --branch-pc) BR_PC="$2"; shift 2 ;;
        --exp-marker) EXP_MARKER="$2"; shift 2 ;;
        --exp-bad-marker) EXP_BAD_MARKER="$2"; shift 2 ;;
        --self-test) SELF=1; shift ;;
        -h|--help) printf 'usage: %s --id N --name S --scen S --hex P --vvp P --log P --checks K [..]\n' "$0"; exit 0 ;;
        *) printf '2A_CONTROL_DRIVER_BAD: unknown_arg=%s\n' "$1"; exit 2 ;;
    esac
done

#------------------------------------------------------------------------------
# 门控核心：gate_log <log> <rc> <expect-checks> → 0/1 + 置 GATE_WHY
#------------------------------------------------------------------------------
GATE_WHY=""
GATE_TOTAL=""
gate_log() {
    local log="$1" rc="$2" expchk="$3" sz npass nbad nline ntot nbadc
    GATE_WHY=""; GATE_TOTAL=""
    sz="$(stat -c %s -- "$log" 2>/dev/null || printf 0)"
    if [ "${sz:-0}" -le 0 ]; then GATE_WHY="empty_log"; return 1; fi
    if [ "$rc" -eq 124 ]; then GATE_WHY="timeout"; return 1; fi
    if [ "$rc" -ne 0 ]; then GATE_WHY="vvp_rc=$rc"; return 1; fi
    npass="$(grep -cxF '2A_CTL_RESULT: PASS' "$log" || true)"
    if [ "$npass" != "1" ]; then GATE_WHY="pass_anchor=$npass"; return 1; fi
    nbad="$(grep -cE '2A_CTL_CHK_BAD|2A_CTL_FAIL|2A_CTL_TIMEOUT' "$log" || true)"
    if [ "${nbad:-0}" != "0" ]; then GATE_WHY="bad_tokens=$nbad"; return 1; fi
    nline="$(grep -cE '^2A_CTL_CHECKS: ' "$log" || true)"
    if [ "${nline:-0}" != "1" ]; then GATE_WHY="checks_lines=$nline"; return 1; fi
    ntot="$(grep -m1 -E '^2A_CTL_CHECKS: ' "$log" | sed -E 's/.*total=([0-9]+).*/\1/')"
    nbadc="$(grep -m1 -E '^2A_CTL_CHECKS: ' "$log" | sed -E 's/.*bad=([0-9]+).*/\1/')"
    case "$ntot" in ''|*[!0-9]*) GATE_WHY="checks_parse"; return 1 ;; esac
    if [ "$ntot" != "$expchk" ]; then GATE_WHY="checks=$ntot/exp=$expchk"; return 1; fi
    if [ "$nbadc" != "0" ]; then GATE_WHY="checks_bad=$nbadc"; return 1; fi
    GATE_TOTAL="$ntot"
    return 0
}

#------------------------------------------------------------------------------
# --self-test：用构造日志反证门控（不接受假 PASS / 多锚点 / 坏 token / 错 checks）
#------------------------------------------------------------------------------
if [ "$SELF" -eq 1 ]; then
    d="$(mktemp -d -- "${TMPDIR:-.}/2a-ctl-drv-st-XXXXXXXX")"
    cp_ok=0; cp_n=0
    check_reject() {  # $1=name $2=log $3=rc $4=exp
        cp_n=$((cp_n + 1))
        if gate_log "$2" "$3" "$4"; then
            printf '2A_CONTROL_DRIVER_SELFTEST: %s got=accept want=reject\n' "$1"
        else
            cp_ok=$((cp_ok + 1)); printf '2A_CONTROL_DRIVER_SELFTEST: %s reject_reason=%s ok\n' "$1" "$GATE_WHY"
        fi
    }
    check_accept() {  # $1=name $2=log $3=rc $4=exp
        cp_n=$((cp_n + 1))
        if gate_log "$2" "$3" "$4"; then
            cp_ok=$((cp_ok + 1)); printf '2A_CONTROL_DRIVER_SELFTEST: %s accept(ok)\n' "$1"
        else
            printf '2A_CONTROL_DRIVER_SELFTEST: %s got=reject(%s) want=accept\n' "$1" "$GATE_WHY"
        fi
    }
    : > "$d/empty.log"
    check_reject empty "$d/empty.log" 0 12
    printf '2A_CTL_RESULT: PASS\n2A_CTL_CHECKS: total=12 bad=0\n' > "$d/good.log"
    check_accept good "$d/good.log" 0 12
    printf '2A_CTL_CHECKS: total=12 bad=0\n' > "$d/noanchor.log"
    check_reject no_anchor "$d/noanchor.log" 0 12
    printf '2A_CTL_RESULT: PASS\n2A_CTL_RESULT: PASS\n2A_CTL_CHECKS: total=12 bad=0\n' > "$d/dup.log"
    check_reject dup_anchor "$d/dup.log" 0 12
    printf '2A_CTL_RESULT: PASS\n2A_CTL_CHK_BAD: x\n2A_CTL_CHECKS: total=12 bad=1\n' > "$d/chkbad.log"
    check_reject chk_bad "$d/chkbad.log" 0 12
    printf '2A_CTL_RESULT: PASS\n2A_CTL_CHECKS: total=12 bad=0\n' > "$d/rc.log"
    check_reject vvp_rc "$d/rc.log" 7 12
    check_reject vvp_timeout "$d/rc.log" 124 12
    printf '2A_CTL_RESULT: PASS\n2A_CTL_CHECKS: total=11 bad=0\n' > "$d/cnt.log"
    check_reject checks_mismatch "$d/cnt.log" 0 12
    rm -rf -- "$d"
    printf '2A_CONTROL_DRIVER_SELFTEST: total=%d ok=%d\n' "$cp_n" "$cp_ok"
    [ "$cp_ok" -eq "$cp_n" ] || { printf '2A_CONTROL_DRIVER_SELFTEST: NOT-ACCEPTED\n'; exit 1; }
    printf 'FUNCTIONAL_2A_CONTROL_DRIVER_NEGATIVE: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 正常调用
#------------------------------------------------------------------------------
[ -n "$ID" ] && [ -n "$NAME" ] && [ -n "$SCEN" ] && [ -n "$HEXF" ] && [ -n "$VVP" ] && [ -n "$LOG" ] \
    || { printf '2A_CONTROL_DRIVER_BAD: missing_args\n'; exit 2; }
[ -n "$CHECKS" ] || { printf '2A_CONTROL_DRIVER_BAD: missing_checks\n'; exit 2; }
[ -s "$HEXF" ] || { printf '2A_CONTROL_DRIVER_BAD: hex_missing=%s\n' "$HEXF"; exit 2; }
[ -s "$VVP" ] || { printf '2A_CONTROL_DRIVER_BAD: vvp_missing=%s\n' "$VVP"; exit 2; }
command -v vvp >/dev/null 2>&1 || { printf '2A_CONTROL_DRIVER_BAD: vvp_tool_missing\n'; exit 2; }

mkdir -p -- "$(dirname -- "$LOG")"
rc=0
timeout 600 vvp "$VVP" \
    "+SCEN=$SCEN" "+KIND=$KIND" "+DDRPROG=$HEXF" \
    "+CTRL_PC=$CTRL_PC" "+MRET_PC=$MRET_PC" "+EXP_EPC=$EXP_EPC" \
    "+LOAD_PC=$LOAD_PC" "+BR_PC=$BR_PC" "+EXP_MARKER=$EXP_MARKER" "+EXP_BAD_MARKER=$EXP_BAD_MARKER" \
    "+IRQ=$IRQ" "+RDELAY=$RDELAY" \
    "+DATA_ADDR=$DATA_ADDR" "+DATA_VAL=$DATA_VAL" \
    "+EXP_TVAL=$EXP_TVAL" "+CANCEL=$CANCEL" \
    "+DELAY_LO=$DLY_LO" "+DELAY_HI=$DLY_HI" "+ARM_HI=$ARM_HI" \
    "+ERR_LO=$ERR_LO" "+ERR_HI=$ERR_HI" "+ERR_KIND=$ERR_KIND" > "$LOG" 2>&1 || rc=$?

if ! gate_log "$LOG" "$rc" "$CHECKS"; then
    printf '2A_CONTROL_DRIVER_BAD: id=%s name=%s reason=%s log=%s\n' "$ID" "$NAME" "$GATE_WHY" "$LOG"
    exit 1
fi
got="$GATE_TOTAL"
hits="$(grep -m1 -E '^2A_CTL_DIAG: done=' "$LOG" | sed -E 's/.*hits\{([^}]*)\}.*/\1/' || true)"
printf '2A_CONTROL_CASE: id=%s name=%s scen=%s ctrl_pc=%s exp_epc=%s checks=%s hits=%s result=pass\n' \
       "$ID" "$NAME" "$SCEN" "$CTRL_PC" "$EXP_EPC" "$got" "${hits:-none}"
exit 0
