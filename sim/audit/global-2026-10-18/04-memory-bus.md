# 04 Cache / MMU / PTW / TLB / 访存与 AXI 静态审计

## 【结论】

基线 HEAD `b284df7`，源码树摘要 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`；审的是当前实现，不限 git diff。确认 7 组实质问题：P0 4 组、P1 3 组、P2 0。全部为**静态代码/事务推演证据**；未运行仿真，以下“最小验证”均为建议，不是已通过或已复现结果。跨域 2B 错误响应问题交 03 合并，不重复计根因。

## 【变更】

仅新建本报告；RTL、测试均未修改；未仿真、构建、安装、提交、转包。

### 实际覆盖深度

“读全”仅说明逐行实际读取，不代表全功能合规。主责无未读文件。

| 主责文件 | 深度 | 已读行 |
|---|---|---|
| [ptw.v](../../../rtl/csr/ptw.v) | 读全 | 1–595 |
| [tlb.v](../../../rtl/csr/tlb.v) | 读全 | 1–449 |
| [l1i.v](../../../rtl/cache/l1i.v) | 读全 | 1–351 |
| [l1d.v](../../../rtl/cache/l1d.v) | 读全 | 1–697 |
| [cache_array_bram.v](../../../rtl/cache/cache_array_bram.v) | 读全 | 1–179 |
| [cache_tag_array.v](../../../rtl/cache/cache_tag_array.v) | 读全 | 1–190 |
| [mshr_simple.v](../../../rtl/cache/mshr_simple.v) | 读全 | 1–140 |
| [axi_master_ctrl.v](../../../rtl/axi/axi_master_ctrl.v) | 读全 | 1–508 |
| [axi_req_desc.v](../../../rtl/axi/axi_req_desc.v) | 读全 | 1–193 |
| [lsu.v](../../../rtl/mem/lsu.v) | 读全 | 1–572 |
| [amo_unit.v](../../../rtl/mem/amo_unit.v) | 读全 | 1–233 |
| [cmo_unit.v](../../../rtl/mem/cmo_unit.v) | 读全 | 1–128 |
| [mmio_route.v](../../../rtl/mem/mmio_route.v) | 读全 | 1–174 |
| [tb_ptw.sv](../../../sim/unit/tb_ptw.sv) | 读全 | 1–557 |
| [tb_l1i.sv](../../../sim/unit/tb_l1i.sv) | 读全 | 1–361 |
| [tb_l1d.sv](../../../sim/unit/tb_l1d.sv) | 读全 | 1–437 |
| [tb_axi_master_ctrl.sv](../../../sim/unit/tb_axi_master_ctrl.sv) | 读全 | 1–642 |
| [tb_lsu.sv](../../../sim/unit/tb_lsu.sv) | 读全 | 1–816 |

交叉读取：两个 top 仅抽查集成/仲裁/错误与地址路径（不是完整覆盖）；[pmp_check.v](../../../rtl/mem/pmp_check.v) 仅检索权限译码等位置，未读全。

## 【证据】

### 04-01 P0：TLB 丢 D，load 填表后 store 绕过 Svade

- **位置/因果**：[PTW:508–524](../../../rtl/csr/ptw.v#L508-L524) 对 load 只要求 A，成功填入 RW 权限；[TLB:124–139](../../../rtl/csr/tlb.v#L124-L139)、[208–255](../../../rtl/csr/tlb.v#L208-L255)、[415–420](../../../rtl/csr/tlb.v#L415-L420) 不保存/检查 D，store 只检查 RW。
- **序列/影响**：合法 RW、A=1、D=0 PTE → load miss/PTW 成功 → store 同 VA TLB hit；不再进入 PTW，漏掉应有 store page fault，写脏追踪失效。静态确定；完整核执行尚未动态验证。
- **测试为何放过**：[TB:78–86](../../../sim/unit/tb_ptw.sv#L78-L86) 显式 SVADE=0，且没有 PTW→TLB→load/store 连续事务；单测一次翻译不能覆盖后继命中。
- **修复/最小验证**：TLB 保存 D（以及 A 策略），D=0 写访问触发重新遍历/异常；默认 SVADE=1 集成测试执行上述序列，断言 load 成功、store cause15、无写请求；D=1 对照必须成功。

### 04-02 P0：按 VA、全 ASID 的 SFENCE 错误保留 global

- **位置**：[TLB:327–337](../../../rtl/csr/tlb.v#L327-L337) 只要不是双全范围就先以 `w_g` 排除失效。
- **序列/影响**：填 G=1 的 VA→P；软件改成 Q；执行 `sfence.vma a0,x0`（a0=VA）；仍命中 P。该指令应覆盖该 VA 的所有地址空间，包括 global；陈旧映射可破坏隔离/正确性。
- **盲区**：指定五个 TB 没有该组合的 TLB 断言；实现注释错误口径不能作为规范依据。
- **修复/验证**：仅 `rs2!=x0` 时排除 global。覆盖 rs1/rs2 四组合、global/non-global、ASID 数值0但寄存器非x0的区别；VA全ASID冲刷后必须 miss，ASID定向冲刷应保留 G。

### 04-03 P0：Sv32 物理地址高两位被静默折叠

- **位置**：[PTW:252–255](../../../rtl/csr/ptw.v#L252-L255)、[364–368](../../../rtl/csr/ptw.v#L364-L368)、[592](../../../rtl/csr/ptw.v#L592)、[TLB:255](../../../rtl/csr/tlb.v#L255)。22-bit PPN+12-bit offset 为34位，却进入32位地址，且没有高位拒绝。
- **序列/影响**：叶 PPN=`22'h100001`、A/D/R/W合法 → 期望 PA=`0x1_00001000`，实际 PA=`0x00001000`；PMP/AXI对低地址放行，访问错误对象。根表/下级表 PPN 高位同样可能读低地址页表。支持32位总线本身不是bug，**将不可达高PA别名为低PA**才是错误。
- **盲区**：[TB:303–320](../../../sim/unit/tb_ptw.sv#L303-L320) 等只用低 PPN；不构造仅高位不同的目标并监测禁止低地址访问。
- **修复/验证**：内部保留34位直至物理范围/PMP/PMA判定；平台仅32位时，对非零高位报原访问类型 access fault，绝不截断后访问。分别验证根、非叶、4KiB叶、4MiB叶高位，与低地址合法对照。

### 04-04 P0：L1D 写回 valid 早于描述符；可把脏数据写到旧地址

- **位置**：[L1D:280](../../../rtl/cache/l1d.v#L280)、[423–425](../../../rtl/cache/l1d.v#L423-L425)、[575–588](../../../rtl/cache/l1d.v#L575-L588)。`wb_decide` 当拍即使 wb_req=1，但 wb_paddr/wb_way 仍是上一笔寄存器值；受害者地址下一沿才锁存。
- **序列/影响**：空闲总线、组满且受害行脏 → 第5行 miss 的决定拍接收 wb_req → 采到旧 wb_line_q（首次为0）。[2A top:2668–2684](../../../rtl/top/core_top.v#L2668-L2684)、[2742–2753](../../../rtl/top/core_top.v#L2742-L2753) 在该拍先登记旧地址，下一拍实际 accepted，随后把当前受害者数据写到旧地址。若独立直接同拍 accepted，MS_IDLE 还未记录 wb_taken_q，后续抓行等待可能卡住；两种时序须分开验证。
- **盲区**：[TB:275–288](../../../sim/unit/tb_l1d.sv#L275-L288) drop_req 后才等请求，再延后 accepted；错过第一个 valid 窗口。
- **修复/验证**：只在描述符锁存后拉 valid；或决定拍直接组合输出本次描述符并同拍记握手。用始终ready接收器断言首次valid地址就是受害行；覆盖地址非0、连续两次不同受害者、accept延迟0/1/N拍，并核全部8字。

### 04-05 P1：AXI split 首笔就产生 done；TB 只核第二次 AR

- **位置**：[控制器:331](../../../rtl/axi/axi_master_ctrl.v#L331)、[471–482](../../../rtl/axi/axi_master_ctrl.v#L471-L482)。首笔进入 ST_DONE 时 split_pending_q 尚为0，因此 done=1；到该拍末才置 pending。
- **序列/影响**：0x3ff8读8beat，首笔2beat → done提前通知完成；第二笔6beat稍后仍发出，并再次done。消费者可能提前释放owner/提交未齐数据，违背“整个拆分请求一次完成”的接口。
- **盲区**：[TB:533–547](../../../sim/unit/tb_axi_master_ctrl.sv#L533-L547) 看到首个done后固定补等4拍、只核两次AR和LEN；未断言总done恰1次，也未要求done时所有R已收到。
- **修复/验证**：done条件排除尚未发出的split；总busy/owner覆盖整个逻辑请求。第二笔R故意延迟100拍，断言首笔后done=0、最终恰1次done；读写拆分均测。

### 04-06 P1：Zicbom 被错误当成必须可写、需要 D 的 store

- **位置**：[LSU:262–272](../../../rtl/mem/lsu.v#L262-L272)、[497–505](../../../rtl/mem/lsu.v#L497-L505) 把所有 CBO 送 PT_AMO/W；[PTW:170–175](../../../rtl/csr/ptw.v#L170-L175)、[355](../../../rtl/csr/ptw.v#L355) 无单独 CBM 类别，store类别检查D；[TLB:230–233](../../../rtl/csr/tlb.v#L230-L233) 同样要求RW。
- **序列/影响**：S模式只读 PTE/PMP 允许load、禁止store，执行 cbo.clean/flush/inval；本应允许，却报store访问/页异常。RW A=1 D=0块也不能因CBM检查D而异常。Zicbom不同于不实现的 cbo.zero。
- **盲区**：[TB:423–445](../../../sim/unit/tb_lsu.sv#L423-L445) 只测M全放行；[758–764](../../../sim/unit/tb_lsu.sv#L758-L764) 直接把“need_perm=W”当正确答案。
- **修复/验证**：CBM独立权限类型，load OR store允许，检查A不检查D；异常cause仍按CBM规范。测试只读、可写、全拒、A=0、D=0及SUM组合；只读与D=0正例必须通过。

### 04-07 P1：错误 refill 仍落 valid；单槽 poison 不能保护多错误行

- **位置**：[L1I:157–173](../../../rtl/cache/l1i.v#L157-L173)、[L1D:333–365](../../../rtl/cache/l1d.v#L333-L365) 没有响应错误输入，末beat无条件置valid。[2A top:3088–3101](../../../rtl/top/core_top.v#L3088-L3101)、[3119–3134](../../../rtl/top/core_top.v#L3119-L3134) 仅记最近一个错误地址。
- **序列/影响**：不同组I行A refill SLVERR并装垃圾 → 行B refill SLVERR覆盖poison地址 → 返回A：A仍缓存命中且不匹配唯一poison槽，可把垃圾当指令。静态确定，动态执行/精确取指响应时序待验证。PTE行也有同类单槽风险，需独立集成验证，不假定读回0总会安全。
- **盲区**：[L1I TB:160–171](../../../sim/unit/tb_l1i.sv#L160-L171)、[L1D TB:179–188](../../../sim/unit/tb_l1d.sv#L179-L188) 只有正常填充，无错误入口；[AXI TB:577–581](../../../sim/unit/tb_axi_master_ctrl.sv#L577-L581) 只核“曾有error”，未核失败行不可命中。
- **修复/验证**：事务级累计error；错误行不装valid或逐行poison，清理条件明确；写回需等B成功再清dirty/替换，不能以最后W代替写成功。验证早/中/末beat错误、两错误行交替、重试恢复、写回B失败保留脏数据。

### 跨域交接（不另计数）：2B 丢弃响应错误

[2B top:1404](../../../rtl/top/core_top_2b.v#L1404) 将 resp_error/resp_code 悬空，[1372–1376](../../../rtl/top/core_top_2b.v#L1372-L1376) 仍按数据/完成推进。SLVERR/DECERR可被当正常数据或写成功；此根因与03合并。需要从后端异常/提交侧统一修复，单独修缓存不能覆盖uncached访问。指定AXI单测不例化2B top，不能证明集成消费error。

### 规范来源（授权 KB CLI，非手册通读）

使用 `node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search '<精确标识符> source:isa-manual'` 与 `get <chunk>`；实际取得：10778（SFENCE四组合）、10787（Svade A/D）、10792（翻译算法及PA组合）、10971（`cbm_access`：load OR store；CBM不检查D）、10785/10610（Sv32物理地址宽度）。来源：[supervisor.adoc](../../../../riscv-isa-manual/src/priv/supervisor.adoc) 1190–1427、1459–1854；[cmo.adoc](../../../../riscv-isa-manual/src/unpriv/cmo.adoc) 311–406。工具输出无仿真证据，不应改写为动态复现。

## 【遗留/风险】

- 不报已修的“PTW使用活req_va”旧问题：当前[193–195](../../../rtl/csr/ptw.v#L193-L195) 明确使用va_r。非叶G未累计按规范至少可视性能降级，不列功能错误；L2未实现不是新bug。
- 两top已把cache查询切PA（PIPT），不能仅凭模块端口名/旧VIPT注释误报VA别名；[2A:894–902](../../../rtl/top/core_top.v#L894-L902)、[2B:1029–1040](../../../rtl/top/core_top_2b.v#L1029-L1040)。SPI绕Icache亦不是bug。
- 尚须小范围补证而未计数：TLB fill与SFENCE同拍只检查被替换槽旧内容（新空槽可能重装旧翻译，外层kill可屏蔽部分场景）；非叶PTE D/A/U保留位漏检；SVADE=0大页AD地址在S_AD中用恒假的cur_is_l1；AXI读错后err_code锁m_bresp而非m_rresp；异常LR建保留与VA而非PA关联；AMO请求单拍契约与多拍读返回未闭环。均不得据本报告声称动态可达已证。
- AXI早/晚RLAST、RID/BID、W背压稳定及consumer ready、同拍alloc/fill，PMP全笔跨度与每笔权限、FENCE在途旧返回归属、AMO/LRSC原子性/异常取消，仍缺动态对抗验证。主责全读不等于这些特性通过。
