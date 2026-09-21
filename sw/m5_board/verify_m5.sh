#!/usr/bin/env bash
#==============================================================================
# rv32gc-cpu/sw/m5_board/verify_m5.sh —— M5 交付自检（可复现、未捕获即失败）
#==============================================================================
# 用法 : ./sw/m5_board/verify_m5.sh
# 判据 : 见 M5 任务书（接线核对 / 平台 bitstream / 上板程序 / 手册 / 核 RTL 冻结）。
#        任一不满足 ⇒ 打印 "V5: FAIL <条目>" 并 rc=1；全部满足才打印唯一汇总行
#        "V5: ALL CHECKS PASS"（脚本**没有**兜底 PASS 文案）。
# 依赖 : 只读检查 + 一次 `sw/m5_board/build.sh` 复跑（编译上板程序）。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"                 # <rv32gc-cpu>
LAB="$(cd -- "${REPO}/../chiplab" && pwd -P)"                  # <chiplab>
SOC="${LAB}/chip/soc_demo/loongson/soc_top.v"
CFG="${LAB}/chip/soc_demo/loongson/config.h"
OUT="${LAB}/fpga/loongson/2023.2/rv32gc_out"
SWOUT="${SCRIPT_DIR}/out"

FAIL=0
ok()   { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=1; }
chk()  { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

echo "== V5 自检开始：REPO=$REPO  LAB=$LAB"
echo

#------------------------------------------------------------------------------
# V1 平台接线（33 MHz 同域 + 48 端口全连接 + FREQ=33）
#------------------------------------------------------------------------------
echo "--- V1 平台接线 ---"
chk "V1a：soc_top.v 存在 clk_pll_33.clk_out1 留空（50 MHz 不再使用）" \
    grep -qE '^\s*\.clk_out1\(\),' "$SOC"
chk "V1b：soc_top.v 有 assign cpu_clk = uncore_clk" \
    grep -qE '^assign[[:space:]]+cpu_clk[[:space:]]*=[[:space:]]*uncore_clk;' "$SOC"
chk "V1c：soc_top.v 的 aclk = uncore_clk" \
    grep -qE '^assign[[:space:]]+aclk[[:space:]]*=[[:space:]]*uncore_clk;' "$SOC"
chk "V1d：intrpt 接 {3'b0, int_out[4:0]}" \
    grep -qE "\.intrpt\s*\(\{3'b0, *int_out\[4:0\]\}\)" "$SOC"
chk "V1e：config.h FREQ = 32'd33000000" \
    grep -qE "^.define FREQ 32'd33000000" "$CFG"

# 48 端口全连接（去注释后逐个核对；无悬空/无空连接/无核未声明端口）
python3 - "$REPO" "$SOC" <<'PY' && ok "V1f：core_top 48 端口全部连接（无悬空/无空连接/无未声明）" || bad "V1f：core_top 端口连接不完整"
import re, sys
repo, soc_path = sys.argv[1], sys.argv[2]
core = open(repo + '/rtl/top/core_top.v').read()
m = re.search(r'module core_top\s*\((.*?)\);', core, re.S)
ports = [d[2] for d in re.findall(r'(input|output)\s+(?:wire\s+)?(\[[^\]]*\]\s*)?(\w+)', m.group(1))]
soc = open(soc_path).read()
i = soc.find('core_top cpu_mid('); j = soc.find('\n);', i)
inst = re.sub(r'//[^\n]*', '', soc[i:j])
conns = re.findall(r'\.(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)', inst)
names = [c[0] for c in conns]
missing = [p for p in ports if p not in names]
extra   = [c for c in names if c not in ports]
empty   = [c[0] for c in conns if c[1].strip() == '']
print(f"    声明 {len(ports)} / 连接 {len(names)} / 未连接 {missing or '无'} / 未声明 {extra or '无'} / 空连接 {empty or '无'}")
sys.exit(0 if (len(ports) == 48 and not missing and not extra and not empty and len(names) == 48) else 1)
PY

#------------------------------------------------------------------------------
# V2 平台综合 + bitstream + 时序
#------------------------------------------------------------------------------
echo "--- V2 平台 bitstream 与时序 ---"
BIT="${OUT}/rv32gc_chiplab_soc.bit"
chk "V2a：bitstream 存在且非空（${BIT}）" test -s "$BIT"
chk "V2b：构建日志含 RESULT_RV32GC_BUILD: OK" \
    grep -q "RESULT_RV32GC_BUILD: OK" "${OUT}/rv32gc_build.vivado.log"
chk "V2c：时序摘要含 'All user specified timing constraints are met'" \
    grep -q "All user specified timing constraints are met" "${OUT}/impl_timing_summary.rpt"
# WNS/WHS ≥ 0 且失败端点 0（取 Design Timing Summary 首次出现的数据行）
read -r WNS TNS NFAIL WHS THS NHFAIL <<EOF2
$(awk '/Design Timing Summary/{f=1} f&&/^[[:space:]]+-?[0-9]+\.[0-9]+/{print $1, $2, $3, $5, $6, $7; exit}' "${OUT}/impl_timing_summary.rpt")
EOF2
echo "    WNS=$WNS ns / TNS=$TNS / setup 失败端点=$NFAIL ；WHS=$WHS ns / THS=$THS / hold 失败端点=$NHFAIL"
NFAIL="${NFAIL:-1}"; NHFAIL="${NHFAIL:-1}"
chk "V2d：WNS ≥ 0" bash -c "awk 'BEGIN{exit !(${WNS:-0} >= 0)}'"
chk "V2e：WHS ≥ 0" bash -c "awk 'BEGIN{exit !(${WHS:-0} >= 0)}'"
chk "V2f：时序失败端点 = 0" test "${NFAIL:-1}" = "0"
chk "V2g：实现后利用率报告存在" test -s "${OUT}/impl_utilization.rpt"
chk "V2h：实现 DRC 无 Error" bash -c "! grep -qE '^\|.*\| *(Error|Critical Warning) *\|' '${OUT}/impl_drc.rpt'"

#------------------------------------------------------------------------------
# V3 上板程序（编译 + 链接 + PC 相对 + 五步序列）
#------------------------------------------------------------------------------
echo "--- V3 上板程序 ---"
if bash "${SCRIPT_DIR}/build.sh" >/dev/null 2>&1; then ok "V3a：sw/m5_board/build.sh 复跑通过（rc=0，全部判据 PASS）"
else bad "V3a：sw/m5_board/build.sh 复跑失败（见 ${SWOUT}/build.log）"; fi
chk "V3b：ELF 存在" test -s "${SWOUT}/m5_board.elf"
chk "V3c：烧写镜像存在且 ≤ 1 MiB" bash -c "test -s '${SWOUT}/m5_board.bin' && [ \$(stat -c %s '${SWOUT}/m5_board.bin') -le 1048576 ]"
chk "V3d：无绝对地址重定位（readelf -r 无 R_RISCV_32/64）" \
    bash -c "! '${TOOLCHAIN_PREFIX:-/opt/riscv/bin/riscv32-unknown-linux-gnu-}readelf' -r '${SWOUT}/m5_board.elf' 2>/dev/null | grep -qE 'R_RISCV_(32|64)\b'"
#   字符串在 .rodata，objdump -s 的十六进制 dump 里以 ASCII 列呈现 ⇒ 直接对 .dis 全文匹配
first_missing_string() {   # 返回第一个缺失的标志串（全部存在则 rc=0）
    local s
    for s in step1 step2 step3 "timer delta" step5 "RV32GC-M5"; do
        grep -q -- "$s" "${SWOUT}/m5_board.dis" || { printf '   缺少字符串: %s\n' "$s"; return 1; }
    done
    return 0
}
chk "V3e：五步序列字符串齐备（step1..step5 + RESULT 行，见 .rodata dump）" \
    first_missing_string

#------------------------------------------------------------------------------
# V4 手册
#------------------------------------------------------------------------------
echo "--- V4 手册 ---"
chk "V4a：sw/M5-board-runbook.md 存在且含烧写步骤" \
    grep -q "programmer_by_uart.bit" "${REPO}/sw/M5-board-runbook.md"
chk "V4b：手册含 115200 串口口径" grep -q "115200" "${REPO}/sw/M5-board-runbook.md"
chk "V4c：手册含失败回报清单" grep -q "必报信息清单" "${REPO}/sw/M5-board-runbook.md"

#------------------------------------------------------------------------------
# V5 核 RTL 冻结（改动必须**恰好**是 R2 修复的两文件 + md5 汇总基线）
#   2026-09-21 R2 修复：`rtl/axi/axi_master_ctrl.v`（+rdata_hold 锁存）与
#   `rtl/top/core_top.v`（数据读/AMO 读相改取锁存值）是**授权范围内**的唯一改动；
#   本判据把"允许的改动白名单"写死 ⇒ 既能在父 Agent 提交前通过，也能在提交后
#   （git 干净）通过，且任何**其它** RTL 改动一律判失败。
#   md5 基线：**2026-09-21 第三轮（M 扩展 div_gen 字段序修复）后** = 66e3225645b6f29375c786fe166448d6
#             R2 修复后 = c558e750441afc0b13c3dbb3776bcbd3（第三轮前）
#             R2 修复前 = f41d1f253d5e0e5baa8030e118af87c1
#   白名单（第三轮）：R2 两文件 + `rtl/exec/mdu.v`（div_gen 字段序修复）。
#------------------------------------------------------------------------------
echo "--- V5 核 RTL 冻结 ---"
RTL_DIRTY="$(git -C "$REPO" status --porcelain rtl/ 2>/dev/null | awk '{print $2}' | sort | tr '\n' ' ')"
if [ -z "$RTL_DIRTY" ]; then
    ok "V5a：git status rtl/ 为空（核 RTL 已提交冻结）"
elif [ "$RTL_DIRTY" = "rtl/axi/axi_master_ctrl.v rtl/top/core_top.v " ]; then
    ok "V5a：rtl/ 的未提交改动恰好是 R2 修复的两个文件（父 Agent 提交后即为空）"
elif [ "$RTL_DIRTY" = "rtl/axi/axi_master_ctrl.v rtl/exec/mdu.v rtl/top/core_top.v " ]; then
    ok "V5a：rtl/ 的未提交改动恰好是 R2 两文件 + mdu.v（M 扩展字段序修复，第三轮授权范围）"
elif [ "$RTL_DIRTY" = "rtl/exec/mdu.v " ]; then
    ok "V5a：rtl/ 的未提交改动恰好是 mdu.v（第三轮 M 扩展字段序修复；R2 两文件已提交冻结）"
else
    bad "V5a：rtl/ 下出现了授权**白名单之外**的改动"; printf '    %s\n' "$RTL_DIRTY"
fi
RTL_MD5="$(cd "$REPO" && find rtl -name '*.v' -o -name '*.vh' | sort | xargs md5sum | md5sum | awk '{print $1}')"
echo "    rtl/** 全树 md5 汇总 = ${RTL_MD5}"
chk "V5b：rtl/** md5 汇总等于第三轮基线 66e3225645b6f29375c786fe166448d6（R2 + mdu 字段序修复）" \
    test "${RTL_MD5}" = "66e3225645b6f29375c786fe166448d6"

echo
if [ "$FAIL" -ne 0 ]; then
    echo "V5: FAIL（上面有 FAIL 条目）"
    exit 1
fi
echo "V5: ALL CHECKS PASS"
exit 0
