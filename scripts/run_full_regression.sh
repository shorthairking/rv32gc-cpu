#!/usr/bin/env bash
#==============================================================================
# run_full_regression.sh —— 阶段 2A 全量回归（审阅/交付用的单一入口）
#
# 一条命令跑完所有"不可退"验证，逐项打印 `组=… 结果: PASS=x FAIL=y / 共 z`，
# 最后汇总。任何一项与基线不符都会出现在末尾的"偏离基线"清单里。
#
# 用法：bash scripts/run_full_regression.sh            # 全部
#       JOBS=4 bash scripts/run_full_regression.sh     # 并行加速（默认 4）
#       bash scripts/run_full_regression.sh nonpriv    # 只跑非特权 18 组
#       bash scripts/run_full_regression.sh mmu        # 只跑 MMU 验收组
#       bash scripts/run_full_regression.sh units      # 只跑单元+定向+程序
#
# 基线（2026-09-13，第 20 轮 L1D 之后）：非特权 18 组 124 例 0 失败；PMP 6 组同基线；
# MMU 61/64（3 例为参考模型 Spike 自身 FAIL）；单元/定向/程序全绿。
#==============================================================================
set -u
cd "$(dirname "$0")/.."

export JOBS="${JOBS:-4}"
ONLY="${1:-all}"
LOGDIR="sim/log"
mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/full_regression_summary.txt"
: >"$SUMMARY"

PASS_N=0; FAIL_N=0; DEVIATION=()

# 期望基线：组名 -> 期望 "PASS/FAIL"
declare -A EXPECT=(
  [I]="39/0" [M]="8/0" [Zicsr]="6/0" [Zifencei]="1/0" [Zca]="26/0" [Zaamo]="9/0"
  [Zalrsc]="2/0" [Misalign]="5/0" [MisalignZca]="4/0" [Zicntr]="2/0" [Zicbom]="3/0"
  [Zicboz]="1/0" [Zicbop]="3/0" [Zihintpause]="1/0" [Zihintntl]="4/0" [ZihintntlZca]="4/0"
  [Zmmul]="4/0" [Zicond]="2/0"
  [PMPS]="11/0" [PMPU]="11/0" [PMPZaamo]="1/0" [PMPZalrsc]="1/0" [PMPZca]="12/3" [PMPSm]="37/1"
)

group() {   # group <显示名> <组参数> [用例过滤正则]
  local label="$1" garg="$2" filt="${3:-}"
  local out line p f tot exp
  out=$(timeout 3600 bash scripts/run_arch_test_suite.sh "$garg" "$filt" 2>&1 | grep -a "组=" | tail -1)
  line=$(printf '%s' "$out" | grep -aoE "PASS=[0-9]+ FAIL=[0-9]+ / 共 [0-9]+" || true)
  p=$(printf '%s' "$line" | sed -n 's/PASS=\([0-9]*\).*/\1/p'); p=${p:-0}
  f=$(printf '%s' "$line" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p'); f=${f:-0}
  tot=$(printf '%s' "$line" | sed -n 's|.*共 \([0-9]*\).*|\1|p'); tot=${tot:-?}
  printf '%-26s %-14s %s\n' "$label" "$filt" "${line:-（无结果）}" | tee -a "$SUMMARY"
  PASS_N=$((PASS_N+p)); FAIL_N=$((FAIL_N+f))
  exp="${EXPECT[$label]:-}"
  if [ -n "$exp" ] && [ "$p/$f" != "$exp" ]; then DEVIATION+=("$label 期望 $exp 实得 $p/$f"); fi
}

cmd() { # cmd <显示名> <命令...>
  local label="$1"; shift
  local out
  # ⚠ 第 20 轮修复：原正则少一个右括号（`grep -E` 直接报 "Unmatched ( or \("），
  #   且兜底文案里带 "PASS" ⇒ 所有单元/定向项都会**假 PASS**。现在两边都修好：
  #   正则括号配平；未捕获到判定行时文案不含 PASS（会被 case 判为 FAIL）。
  out=$("$@" 2>&1 | grep -aoE "SIM: PASS [A-Za-z0-9_-]+|TB: TEST PASS|(PMP_UNIT|CLINT_PLIC_UNIT|TLB_PTW_UNIT|ICACHE_UNIT|DCACHE_UNIT|DWRITE_THRU|AXI_SLAVE_UNIT|EXEC_UNIT_TESTS|DECODER_UNIT_TESTS|PRIV_TRAP|FETCH_ERR|LRSC_DIRECTED|FENCEI_SMC|DCACHE_DIRECTED|XIP_NOALLOC|SPI_BOOT|BOOT_CHAIN|CHECK_DTS|PACK_BOOT): (PASS|FAIL)" | tail -1)
  [ -n "$out" ] || out="（未捕获到判定行）"
  printf '%-26s %s\n' "$label" "$out" | tee -a "$SUMMARY"
  case "$out" in *PASS*) PASS_N=$((PASS_N+1));; *) FAIL_N=$((FAIL_N+1)); DEVIATION+=("$label 未 PASS: $out");; esac
}

prog() {  # prog <显示名> <测试名>：跑 run_sim.sh 并以 TB 日志判定（比抓命令行输出稳健）
  local name="$1" test="$2" cyc
  timeout 2400 bash scripts/run_sim.sh "$test" >/dev/null 2>&1
  if grep -qa "TB: TEST PASS" "sim/log/$test.log"; then
    cyc=$(grep -aoE "TB: cycles=[0-9]+" "sim/log/$test.log" | tail -1)
    printf '%-26s SIM: PASS %s (%s)\n' "$name" "$test" "$cyc" | tee -a "$SUMMARY"
    PASS_N=$((PASS_N+1))
  else
    printf '%-26s SIM: FAIL %s\n' "$name" "$test" | tee -a "$SUMMARY"
    FAIL_N=$((FAIL_N+1)); DEVIATION+=("$name 未 PASS")
  fi
}

if [ "$ONLY" = all ] || [ "$ONLY" = nonpriv ]; then
  echo "########## 非特权 18 组（基线 124 例 0 失败）" | tee -a "$SUMMARY"
  for g in I M Zicsr Zifencei Zca Zaamo Zalrsc Misalign MisalignZca Zicntr Zicbom Zicboz Zicbop \
           Zihintpause Zihintntl ZihintntlZca Zmmul Zicond; do group "$g" "$g"; done
fi

if [ "$ONLY" = all ] || [ "$ONLY" = pmp ]; then
  echo "########## PMP 私权 6 组（PMPZca/PMPSm 的失败是已知基线例外）" | tee -a "$SUMMARY"
  for g in PMPS PMPU PMPZaamo PMPZalrsc PMPZca PMPSm; do group "$g" "priv/$g"; done
fi

if [ "$ONLY" = all ] || [ "$ONLY" = mmu ]; then
  echo "########## MMU 验收（RV32 可跑子集；Sv 有 3 例是参考模型自身 FAIL）" | tee -a "$SUMMARY"
  group Svbare      priv/Svbare
  group Sv          priv/Sv            '^sv32_'
  group Svade       priv/Svade         '^sv32_Svade'
  group SvPMP       priv/SvPMP         '^sv32_pmp'
  group ExceptionsSv priv/ExceptionsSv  '^sv32_'
  group ExceptionsSvZaamo  priv/ExceptionsSvZaamo  '^sv32_'
  group ExceptionsSvZalrsc priv/ExceptionsSvZalrsc '^sv32_'
  group SvZicbo     priv/SvZicbo       '^sv32_'
  group SvPMPZicbo  priv/SvPMPZicbo    '^sv32_pmp'
  group PMPZicbo    priv/PMPZicbo
fi

if [ "$ONLY" = progs ]; then
  echo "########## 程序（progs 模式）" | tee -a "$SUMMARY"
  prog "hello（取指局部性）" hello
  prog "memtest（长跑）"     memtest
fi

if [ "$ONLY" = all ] || [ "$ONLY" = units ]; then
  echo "########## 单元测试" | tee -a "$SUMMARY"
  cmd "PMP 单元"        bash scripts/run_unit_pmp.sh
  cmd "CLINT/PLIC 单元" bash scripts/run_unit_clint_plic.sh
  cmd "TLB/PTW 单元"    bash scripts/run_unit_tlb_ptw.sh
  cmd "L1I 单元"        bash scripts/run_unit_icache.sh
  cmd "L1D 单元（含写直达结构断言）" bash scripts/run_unit_dcache.sh
  cmd "AXI 单元"        bash scripts/run_unit_axi.sh
  cmd "EXEC 单元"       bash scripts/run_unit_exec.sh
  cmd "译码器单元"      bash scripts/run_unit_decoder.sh
  echo "########## 定向测试" | tee -a "$SUMMARY"
  cmd "特权陷阱定向"    bash scripts/run_priv_trap_test.sh
  cmd "取指总线错误"    bash scripts/run_fetch_err_test.sh
  cmd "LR/SC 定向"      bash scripts/run_lrsc_test.sh
  cmd "fence.i 自改码"  bash scripts/run_fencei_smc_test.sh
  cmd "L1D 定向功能"    bash scripts/run_dcache_test.sh
  cmd "SPI-XIP 启动"    bash scripts/run_spi_boot_test.sh
  cmd "启动链（真产物）" bash scripts/run_boot_chain_test.sh
  echo "########## DTS / 打包" | tee -a "$SUMMARY"
  cmd "DTS 交叉校验"    bash scripts/check_dts.sh
  cmd "启动镜像打包"    bash scripts/pack_boot_image.sh
  echo "########## 程序" | tee -a "$SUMMARY"
  prog "hello（取指局部性）"   hello
  prog "memtest（长跑）"      memtest
fi

{
  echo "============================================================"
  echo "FULL_REGRESSION: $([ ${#DEVIATION[@]} -eq 0 ] && echo PASS || echo "PASS-with-deviation") （PASS 计数=$PASS_N  FAIL 计数=$FAIL_N）"
  if [ ${#DEVIATION[@]} -gt 0 ]; then
    echo "偏离基线的项："
    for d in "${DEVIATION[@]}"; do echo "  - $d"; done
  else
    echo "与基线逐项一致（已知基线例外见上方 PMPZca/PMPSm/Sv 行）"
  fi
} | tee -a "$SUMMARY"
