#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/r2_equiv_check.sh —— R2 修复的**语义等价**证据（保持型从设备下逐值比对）
#==============================================================================
# 做法：
#   ① 修复前（commit 68ff5fd 的 RTL + 保持型从设备模型）跑过的 arch-test 会把自己的
#      DUT 签名逐行导出到 `sim/arch_test/work/<用例>/<用例>.dut.data`；
#      `fpga/scratch/out/prefix_work_snapshot/` 是**回归重跑之前**对这些文件的快照
#      （`index.txt` 记录 <用例> <md5>）—— 即"修复前保持型"的参考。
#   ② R2 修复后重跑同一批用例（默认 `DDR_R_NONHOLD`/`R_HOLD_IDLE` 均为保持口径）⇒
#      work/ 下的 `.dut.data` 被覆盖为"修复后保持型"的结果。
#   ③ 本脚本逐用例 md5 比对：**完全一致** ⇒ 保持型从设备下修复前后**逐值等价**
#      （配合 axi_master_ctrl.v §5 的逐拍论证 = 逐拍等价）。
# 说明：签名区覆盖了每条用例的所有架构可见结果（x 寄存器/内存/CSR 写回），
#       441 个用例逐字节一致是很强的等价证据；但我们不把它当作"逐拍"证明——
#       逐拍论证靠 RTL 注释里的"同一拍写入同一个值"推理。
# 用法：bash fpga/scratch/r2_equiv_check.sh
# 退出码：0 = 至少 1 例比对且**全部一致**；1 = 有分歧或没有可比对的用例
#==============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
SNAP="${SCRIPT_DIR}/out/prefix_work_snapshot"
OUT="${SCRIPT_DIR}/out/equiv_check.log"
cd "${REPO_ROOT}" || exit 2

[ -f "${SNAP}/index.txt" ] || { echo "R2_EQUIV: FAIL 缺快照 ${SNAP}/index.txt"; exit 2; }

#   只把"**回归重跑过**（work/ 下的文件 mtime 比快照新）"的用例计入比对集合：
#   mtime 未变的用例 = 本次没重跑，md5 相同是平凡的，不计入证据。
same=0; diff=0; notrun=0; miss=0
: >"${OUT}"
while read -r name md5_old; do
    f="sim/arch_test/work/${name}/${name}.dut.data"
    snap="${SNAP}/${name}.dut.data"
    if [ ! -f "$f" ]; then miss=$((miss+1)); continue; fi
    if [ ! -f "$snap" ] || [ ! "$f" -nt "$snap" ]; then notrun=$((notrun+1)); continue; fi
    md5_new="$(md5sum "$f" | cut -d' ' -f1)"
    if [ "$md5_new" = "$md5_old" ]; then
        same=$((same+1))
    else
        diff=$((diff+1))
        printf 'DIFF %-28s 修复前=%s 修复后=%s\n' "$name" "$md5_old" "$md5_new" >>"${OUT}"
    fi
done <"${SNAP}/index.txt"

total=$((same+diff))
printf 'R2_EQUIV: 本次重跑并比对=%d 一致=%d 分歧=%d（本次未重跑=%d 缺文件=%d）\n' \
       "$total" "$same" "$diff" "$notrun" "$miss" | tee -a "${OUT}"
if [ "$total" -gt 0 ] && [ "$diff" -eq 0 ]; then
    printf 'R2_EQUIV: OK —— 保持型从设备下"修复前 vs 修复后"逐用例签名**逐字节一致**\n' | tee -a "${OUT}"
    exit 0
fi
printf 'R2_EQUIV: FAIL —— 存在分歧或无可比对用例（见 %s）\n' "${OUT}" | tee -a "${OUT}"
exit 1
