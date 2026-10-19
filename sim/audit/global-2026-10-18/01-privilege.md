# 全局审计分域 01：特权 / CSR / 中断 / PMP / CLINT / PLIC

## 【结论】

**完成所列主责实现和五个单元测试的全文件静态审计；不满足功能正确性放行条件。** 合并根因后报告 **P0×2、P1×12、P2×1**。所有“会发生”均为静态推导，不是仿真结果；本轮未运行仿真、构建、安装或变异实验。

Baseline：[BASELINE.json](<BASELINE.json#L1-L6>)；实际只读 `git rev-parse HEAD` 得 `b284df704e4b0984cef8fa8062ada01656eca287`。源树 hash 使用母任务冻结值 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`，**本轮未重新计算**。`git status --short -- rtl sim/unit` 只列三份既有 Markdown 修改，未列 RTL/SV 源码修改。

### 实际读取 / 检查范围

| 文件 | 实际读取范围 | 检查边界 |
|---|---|---|
| [csr_file](<../../../rtl/csr/csr_file.v#L1-L1127>) | 1–1127，读全 | 白名单、权限、WARL、读写/旁路、共享视图、PMP 锁、计数器、trap 原子写 |
| [priv_ctrl](<../../../rtl/csr/priv_ctrl.v#L1-L259>) | 1–259，读全 | 旁路、特权状态、xRET、MPRV/SUM/MXR、trap 更新 |
| [trap_ctrl](<../../../rtl/csr/trap_ctrl.v#L1-L328>) | 1–328，读全 | 中断资格、全局门控、委托、优先级、向量、cause/tval/epc |
| [dec_csr](<../../../rtl/decode/dec_csr.v#L1-L243>) | 1–243，读全 | CSR 存在/权限/只读、缺失动态门控、CBO 门控 |
| [pmp_check](<../../../rtl/mem/pmp_check.v#L1-L476>) | 1–476，读全 | TOR/NA4/NAPOT、最低项优先、整笔匹配、权限/cause；只判默认 16 项/G=0/32-bit PA |
| [clint](<../../../rtl/clint/clint.v#L1-L164>) | 1–164，读全 | MMIO 译码、比较、自增、写优先级、strobe |
| [plic](<../../../rtl/plic/plic.v#L1-L443>) | 1–443，读全 | 映射、pending/gateway、仲裁、阈值、claim/complete、strobe |
| [tb_csr_file](<../../unit/tb_csr_file.sv#L1-L730>) | 1–730，读全 | 实际激励/断言、错误 oracle、未接旁路端口、闭环边界 |
| [tb_trap_ctrl](<../../unit/tb_trap_ctrl.sv#L1-L615>) | 1–615，读全 | 中断矩阵缺口、旁路只测置位、trap/xRET |
| [tb_pmp_check](<../../unit/tb_pmp_check.sv#L1-L585>) | 1–585，读全 | 模式/优先级/整笔与拆笔覆盖，CSR 锁不在此 TB 内 |
| [tb_clint](<../../unit/tb_clint.sv#L1-L514>) | 1–514，读全 | 定时器相等边界错误 oracle、恒零 AXI 检查 |
| [tb_plic](<../../unit/tb_plic.sv#L1-L481>) | 1–481，读全 | 阈值错误 oracle、claim/complete 与网关测试缺口 |
| [core_top](<../../../rtl/top/core_top.v>) | 接口抽查：1410–1434、2470–2564、4178–4195；全文件关键词搜索 | CSR/priv 接线、动态权限、计数器截断；未读全流水线/CDC/MMIO FSM |
| [core_top_2b](<../../../rtl/top/core_top_2b.v>) | 接口抽查：1490–1569；全文件关键词搜索 | CSR/priv/trap 接线；未读全提交/重定向/CDC |
| [backend_top](<../../../rtl/back2/backend_top.v>) | 接口抽查：680–764、1960–2114、2310–2354；全文件 priv/CSR 关键词搜索 | M 常量译码、CSR 提交、xRET 识别；其余 ROB/执行链非主责 |
| [decoder](<../../../rtl/decode/decoder.v#L700-L799>) | 700–799 接口抽查 | CSR/sys 输出与操作码；未读全编码合法性 |
| [mmio_route](<../../../rtl/mem/mmio_route.v#L1-L174>) | 1–174，读全 | CLINT/PLIC 窗口截获，不等价于验证 top 最终 AXI 门控 |
| [旧 audit2](<../audit2_report.md#L90-L179>) | 90–179；先读实现后参考 | D2–D7 历史线索；旧行号不作为当前证据 |
| [旧 audit3](<../audit3_report.md>) | 仅关键词搜索 | 未读全，不依其结论 |
| PTW / TLB、其他测试/文档 | 未读 | 明确交其他分域，不作合规背书 |

## 【变更】

仅新建本报告；产品、已有测试和文档无写入，无 git 提交、无转包。

## 【证据】

### 证据类型与规格来源

- **事实 F**：当前源码/测试的具体表达式、接口与断言。
- **静态推导 S**：给定输入/架构状态代入表达式后的结果；无需假称已有运行日志。
- **待实验 E**：每条建议的最小验证尚未运行，集成可达性/时序应以新增测试确认。
- 已实际调用 `skill('riscv-kb')`，工具返回 `unknown or no longer available`。使用授权的可靠只读 CLI `node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search '<query>'` / `get <id>`；未重建缓存。
- 读取的 ISA KB 证据：machine 1.13 `norm:pmplbitwriteprotection`（chunk 10614，源 3544–3565）；`mtimeintrpending`（10581，2514–2589，明确 **greater than or equal**）；`cycleinstrethpmcounteroprdonly`/`timeoprdonly`（10557，1562–1623）；counteren（10556 / 10761）；TVM（10534，730–790）；TSR（10535 / 10586）；中断资格和 restricted sip/sie（10549 / 10554，1327–1522）。可用下方查询原样复取。
- PLIC 不在所检 ISA 手册相关段中，另读取 [官方 ratified PLIC 1.0.0 原文](<https://raw.githubusercontent.com/riscv/riscv-plic-spec/master/riscv-plic.adoc>)：Interrupt Gateways、Interrupt Claim Process、Interrupt Completion。关键原文：gateway **不能撤回**已送入 PLIC core 的请求；收到 completion 前不能转发该源下一请求；claim **不受 priority threshold 影响**；completion 对该 context 未使能源应忽略。

### P0-01（新发现）：2B 以 M 权限译码所有指令，S/U 的 M CSR 及 xRET 权限隔离失守

**F**：[backend_top:698–712](<../../../rtl/back2/backend_top.v#L698-L712>) 将 `decoder.priv_i` 硬接 `PRIV_M`，而非模块的 `priv_i`。[backend_top:736–755](<../../../rtl/back2/backend_top.v#L736-L755>) 将 mret/sret/sfence 列为合法 SYS；检查中无当前模式/TSR。[core_top_2b:1505–1510](<../../../rtl/top/core_top_2b.v#L1505-L1510>) 又将 csr_file 的 `chk_illegal/chk_ro_write` 悬空。[backend_top:2001–2016](<../../../rtl/back2/backend_top.v#L2001-L2016>) 在 CSR commit 中不复查特权；[core_top_2b:1525–1535](<../../../rtl/top/core_top_2b.v#L1525-L1535>) 直接接受 xRET 提交事件，TSR 输出也悬空。全文件 `priv_i` 搜索仅见接口及 ecall cause 使用。

**S / 触发**：合法进入 U 或 S 后，`csrrw x0,mstatus,t0` 仍按 M 译码，写入 MPP=M；写 mepc 后执行 mret，提交识别无低模式拒绝，priv_ctrl 依据 MPP 转到 M。即便不走 mret，低模式可直接改变 PMP/委托/中断等 M 状态。影响是确定的特权隔离缺失，不是仅“能力未实现”。

**测试为何漏**：主责 csr_file TB 直接手动给 `priv` 检查输出，未经过 2B 的常量译码接线；trap TB 手动给合法事件，不测低模式指令如何被拒。当前查阅范围内没有该提权端到端负例；其他 back2 测试未全读，不能声称全仓绝无覆盖。

**建议**：在执行/提交可信边界按实际架构 privilege 复查 CSR、MRET/SRET/SFENCE（并复查 TVM/TSR），对跨 privilege 切换已派发指令做 flush/重检查，不能只将早期 decoder 常量替换而遗漏在飞状态。

**E / 最小验证**：M 配置 U 可执行区并 mret 到 U，U 读 mstatus/写 pmpcfg/执行 mret 各应 cause 2 且 CSR 不变；同样测试 S；以普通合法 U CSR 作为对照。危险指令不应产生提交副作用。与后端分域交叉核实上述提交链。

### P0-02（已知未修，旧 D3）：PMP 本项 L 不锁自身 pmpaddr

**F**：[csr_file:499–507](<../../../rtl/csr/csr_file.v#L499-L507>) 仅用 `pmp_tor_locked`；[544–555](<../../../rtl/csr/csr_file.v#L544-L555>) 只检查 **i+1 的 L/TOR**，不检查 i 的 L，且 i=15 直接不锁。[998–999](<../../../rtl/csr/csr_file.v#L998-L999>) 照写落地。cfg 锁本身在 [535–538](<../../../rtl/csr/csr_file.v#L535-L538>) 正确，不抵消地址漏洞。

**S / 触发**：写 pmpaddr0 配好区域，再置 cfg0.L=1（OFF/TOR/NA4/NAPOT 均适用），随后写 pmpaddr0 新地址仍成功。锁定保护区可被移动；L 原本应连 M 访问也约束，属于安全正确性问题。

**测试为何漏**：[tb_csr_file:555–561](<../../unit/tb_csr_file.sv#L555-L561>) 不但未漏测，而是**明确期望 L 项自身地址仍可写**，将错误固化；该字节 0x8F 的 A 实为 TOR，并非注释所说 NAPOT。PMP checker TB 不包含 CSR 存储。

**建议**：地址锁条件 = own.L OR successor.(L && TOR)，旁路与实际落盘共用；i=15 仍检查 own.L。

**E**：遍历 16 项和四种 A，先写地址→锁→改地址→读回必须不变；含 TOR 前驱及未锁对照；当前错误 TB 期望须按规范修正。用锁定区边界两侧访问确认权限区未移动。

### P1-01（已知未修，旧 D4）：counteren 不参与低模式计数器访问权限

**F**：[dec_csr:50–70](<../../../rtl/decode/dec_csr.v#L50-L70>) 没有 counteren 输入；[98–103、187–194](<../../../rtl/decode/dec_csr.v#L98-L194>) 白名单后仅判地址权限/只读写。csr_file [601–608](<../../../rtl/csr/csr_file.v#L601-L608>) 也不判计数器使能。2B [1519](<../../../rtl/top/core_top_2b.v#L1519>) 两使能输出悬空；2A 仅引出，没有消费（全文件搜索）。

**S / 触发**：复位 mcounteren=0，S/U 执行 `csrr a0,cycle/time/instret`（含高半）却合法；U 还忽略 scounteren。违反隔离与规范 cause 2 要求。

**测试为何漏**：[tb_csr_file:450–454](<../../unit/tb_csr_file.sv#L450-L454>) 在 U 模式直接期望 cycle 合法，未配置 counteren，也没有经译码执行的负例。

**建议 / E**：加入动态门控：S 要 mcounteren 对应 CY/TM/IR，U 要两者 AND，M 忽略；对三个计数器及高半做 privilege×两级位组合，紧邻 CSR 写的权限也应正确；禁用位必须 cause 2，启用对照必须读成功。

### P1-02（已知未修，旧 D5）：TVM 位可写但不约束 S 的 satp / SFENCE.VMA

**F**：[core_top:1419–1426](<../../../rtl/top/core_top.v#L1419-L1426>) 直接注明 TVM 未实现，拒绝项只有 U sfence；[2555](<../../../rtl/top/core_top.v#L2555>) 输出到 obs_tvm。dec_csr 无 TVM 输入。2B [1534](<../../../rtl/top/core_top_2b.v#L1534>) 悬空且 [backend_top:736](<../../../rtl/back2/backend_top.v#L736>) sfence 无条件白名单。

**S / 触发**：M 置 TVM=1 后进入 S，S `csrr/csrw satp` 和 `sfence.vma` 不抛 cause 2；M 无法拦截 S 页表上下文更改。与 PTW/TLB 内部算法无关。

**测试为何漏**：csr_file 仅检查 TVM 存储/satp R/W；主责五 TB 没有 S+TVM=1 的实际指令负例。

**建议 / E**：在实际特权检查边界加入 S&&TVM&&(satp access||sfence)；读、写 satp 都检查。M+TVM=1 允许、S+0 允许、S+1 拒、U 始终拒，并确认拒绝时 satp/翻译状态不变。

### P1-03（已知未修，旧 D7）：2B 宣告 misa.A，却拒全部 A 指令；M 模式 WFI 也无条件非法

**F**：[csr_file:742–750](<../../../rtl/csr/csr_file.v#L742-L750>) misa.A=1，服务两 top；[backend_top:733–741](<../../../rtl/back2/backend_top.v#L733-L741>) `opt==5` 一律 unsup，wfi 未纳入 is_sys_ok（SYS 无条件 unsup）。

**S / 触发**：2B 中 M 执行合法 AMO/LR/SC 均 cause 2，misa 与实际 ISA 不一致；M WFI 不受 TW 限制、允许实现 NOP，但不能因此一律判非法。此项仅 2B，不沿用“2A A 也坏”的结论。

**测试为何漏**：主责 TB 只测试 checker 的 AMO cause、misa 常量，未执行 2B A/WFI。其他域 A 实现细节不在此展开。

**建议 / E**：补实现与声明一致的 A；若明确临时不支持，应分核配置 misa/ISA 并登记非 RV32GC。M WFI 至少合法 NOP。逐 AMO/LR/SC 与 M WFI 指令跑合法性负/正对照；TW=1 的 S WFI 单独检查。

### P1-04（已知未修，旧 D9 线索）：未委托 SSI/STI/SEI 被永久屏蔽，而不是送 M

**F**：[trap_ctrl:183–192](<../../../rtl/csr/trap_ctrl.v#L183-L192>) 对 `is_s_irq=1` 恒要求 mideleg=1 且 priv!=M；[200–202](<../../../rtl/csr/trap_ctrl.v#L200-L202>) 按 cause 固定把 1/5/9 归这一类。后面的 irq_goes_m 无法恢复已过滤候选。

**S / 触发**：MIE=1，mideleg[9]=0，mie.SEIE=1，mip.SEIP=1，priv=M，commit_valid=1，无异常；规范应进 M cause 0x80000009，当前 trap_valid=0。S/U 且未委托也应以 M 目标按高特权规则投递，当前仍 0。

**测试为何漏**：[tb_trap_ctrl:287–303](<../../unit/tb_trap_ctrl.sv#L287-L303>) 只测“已委托在 M 屏蔽/在 S 投递”；[337–346](<../../unit/tb_trap_ctrl.sv#L337-L346>) 未委托六源同时挂起，仅看 MEI，完全遮住 1/5/9 丢失。

**建议 / E**：按每 bit 实际委托决定目标，再按目标与当前模式决定全局使能；不能按 cause 名称把 S source 等同 S target。逐 1/5/9 × delegate 0/1 × M/S/U × MIE/SIE，检查有效/目标/cause；MEI 与低模式已委托源作为优先级对照。

### P1-05（新发现）：sie/sip 没有按 mideleg 做受限别名，S 可改未委托 M 管辖位

**F**：[csr_file:716–718、733–735](<../../../rtl/csr/csr_file.v#L716-L735>) 仅固定屏蔽到 1/5/9，不与 mideleg 相与；[1049–1051](<../../../rtl/csr/csr_file.v#L1049-L1051>) sie 写掩码用固定 IMPL_MSK；[1058–1059](<../../../rtl/csr/csr_file.v#L1058-L1059>) sip.SSIP 写也不看委托。规范要求未委托位在 sip/sie 中 read-only zero。

**S / 触发**：mideleg=0，mie.SEIE=1 或 mip.SSIP=1；读 sie/sip 应 0 却可见；S 写 sie 清 SEIE 或 sip 清 SSIP 能修改 M 管辖状态。即使 D9 目前把它们错屏蔽，此别名错误仍独立存在，修 D9 后影响更明显。

**测试为何漏**：[tb_csr_file:490–498](<../../unit/tb_csr_file.sv#L490-L498>) 测 sie 时之前已把 mideleg 写为全部支持位，没有未委托/部分委托对照。

**建议 / E**：读视图与可写掩码均使用实际 mideleg；写入需保持非委托 mie/mip 软件位。遍历 delegate=0/单 bit/全 1，用 M 写本体，再由 S 读写别名，确认只触及委托位。

### P1-06（新发现）：priv_ctrl 的“替换旁路”实际是 old OR new，无法同拍清位

**F**：[priv_ctrl:86–95](<../../../rtl/csr/priv_ctrl.v#L86-L95>) M 写时 `mstat_bypass=csr_wdata`，表达式 `(old & ~new) | (new & new)` 代数等于 `old | new`；sstatus 分支同样不清旧 1。[core_top:2543–2546](<../../../rtl/top/core_top.v#L2543-L2546>) / [core_top_2b:1529–1530](<../../../rtl/top/core_top_2b.v#L1529-L1530>) 实际接入提交写口。

**S / 触发**：旧 MPRV=1、MPP=S，当前 M；同拍提交 `csrw mstatus,x0`，应立刻 eff_priv=M，实际旁路仍用 MPRV=1 得 S；SUM/MXR/TW/TSR 清零或 MPP 降位也有同类错误。该拍年轻访存/权限或 trap 状态推导可使用旧权限，次拍存储虽正确不能撤销本拍错误。

**测试为何漏**：[tb_trap_ctrl:442–463](<../../unit/tb_trap_ctrl.sv#L442-L463>) 只测 old=0→new=1，能区分“有无旁路”，不能区分 OR 与替换；反证关闭旁路也不覆盖 1→0。

**建议 / E**：用真正的字段可写掩码，而非把写数据当 mask：`(old & ~mask) | (post_warl_new & mask)`；MSTATUS/SSTATUS 分别掩码。每字段测试 0→1、1→0、MPP=M→S/U，检查提交沿之前组合输出，再与沿后架构值一致性对比。

### P1-07（新发现）：mcycle/minstret 不自动计数，也不是 cycle/instret 同一计数器的可写本体

**F**：[csr_file:759–760](<../../../rtl/csr/csr_file.v#L759-L760>) M 计数器由独立软件寄存器拼出；[827–836](<../../../rtl/csr/csr_file.v#L827-L836>) cycle/instret 另读外部输入；[1103–1106](<../../../rtl/csr/csr_file.v#L1103-L1106>) M 本体只有软件写，没有自增。注释声称“自洽口径”不能覆盖规范 read-only shadow 要求。另 2A [2499–2500](<../../../rtl/top/core_top.v#L2499-L2500>) 把输入高 32 位恒置零，虽内部有 64-bit 计数器，经过 [4188–4189](<../../../rtl/top/core_top.v#L4188-L4189>) 的 32-bit wire 截断后失去高半。

**S / 触发**：复位后执行多条指令，mcycle/minstret 仍 0，而 cycle/instret 变化；`csrw mcycle,t0` 后 cycle 不反映写入；2A cycleh/instreth 始终 0（约 2^32 周期/退休后露出回绕错误）。

**测试为何漏**：[tb_csr_file:503–513](<../../unit/tb_csr_file.sv#L503-L513>) 有意用外部 cycle_i 固定值，再对 M 寄存器另行写读，各自能通过却不检查别名一致/自增；TB 高半直接注入，未经过 top 截断。

**建议 / E**：统一 64-bit 可写本体与影子，正确计周期/退休，并明确写本拍优先关系；贯通两 top 高半。测试写 mcycle/minstret 后 URO 影子读同值、等待 N 拍/退休计数增长、高低半进位；用接近溢出初值避免长跑。

### P1-08（新发现）：time/timeh 影子错误地接到 cycle，而非 CLINT mtime

**F**：[csr_file:833–834](<../../../rtl/csr/csr_file.v#L833-L834>) TIME/H 返回 cycle_i；接口无独立 mtime 输入。两 top 分别 [2499](<../../../rtl/top/core_top.v#L2499>) / [1517](<../../../rtl/top/core_top_2b.v#L1517>) 传 CPU 周期计数；[clint:147–152](<../../../rtl/clint/clint.v#L147-L152>) 的 mtime 可独立写，无法保持影子。

**S / 触发**：M 写 CLINT mtime=一个与 cycle 明显不同的值（含高半），再读 time/timeh；当前返回 cycle 而不是软件刚设的 mtime。即便二者同频，写 mtime 后必分离。影响 OS/固件时间基准与 timer deadline 一致性。

**测试为何漏**：五个 TB 将 CSR 与 CLINT 分离；csr_file TB 没有 time 对 mtime 的闭环，CLINT TB 只看 MMIO 与 MTIP。

**建议 / E**：time 直接/同步影射 CLINT mtime（或将 time 访问 trap 并由软件按规范模拟）；高低半都覆盖。写入独特 64-bit mtime 后 MMIO 与 CSR 采样应仅差合法读取延迟对应 tick，不能返回无关周期数。

### P1-09（新发现）：CLINT MTIP 比较使用 >，规范要求 >=；测试明确固化错误

**F**：[clint:121–123](<../../../rtl/clint/clint.v#L121-L123>) 用严格大于。ISA `mtimeintrpending` 明确 mtime≥mtimecmp 时 pending。可容许传播延迟不等于把相等条件定义为不挂起。

**S / 触发**：mtime=mtimecmp=T 时 MTIP=0 而非 1。连续软件写 mtime=T 可让相等保持多拍，排除“一拍传播延迟”的解释。常规定时器至少延后一 tick，在保持相等时可无限不挂起。

**测试为何漏**：[tb_clint:313–369](<../../unit/tb_clint.sv#L313-L369>) 特意钉住相等并期望 0；这不是漏测，是规格 oracle 反向，将正确 >= 当作错误变异。

**建议 / E**：改比较 >=，同步修正设计注释与 TB oracle；T−1/T/T+1 三点（固定 high half、含64-bit高半决定）分别 0/1/1，保持相等数拍验证最终 pending=1。

### P1-10（新发现）：PLIC gateway 撤回已挂起请求，且 completion 前允许新沿再次投递

**F**：[plic:393–399](<../../../rtl/plic/plic.v#L393-L399>) 源变低直接清 pending；源再上升立即置位，没有每源 outstanding/busy 状态；[409–429](<../../../rtl/plic/plic.v#L409-L429>) claim 清 pending、complete 高电平重挂。complete 仅检查 ID 范围，没有 context enable 检查。官方规范禁止 gateway 撤回已接受请求，并规定 completion 前不得转发下一请求；未使能 context completion 应忽略。

**S / 触发 A**：源高一拍→IP=1→在软件 claim 前变低，下一拍 IP=0，中断丢失。**B**：claim 后尚未 complete，源低→高又把 IP 置 1，可被同/另一 context 再 claim，破坏每源串行服务。**C**：源被 ctx0 claim，ctx1 不使能源却写 completion，可在高电平时重新置 IP，提前放行该源。

**测试为何漏**：[tb_plic:332–342](<../../unit/tb_plic.sv#L332-L342>) 撤电平发生在各源已 claim 后，没测“先撤再 claim”；[410–419](<../../unit/tb_plic.sv#L410-L419>) 将未受 completion 管控的新沿当作正常新 pending。没有等待 completion 时新沿和 wrong-context disabled completion 的负例。

**建议 / E**：每源 gateway busy/outstanding 从首次请求到有效 completion 保持；IP 只因 claim 清、不因输入低撤回；busy 时新沿按选定 edge policy 忽略/累计但不提前投递，completion 必须检查该 context enable。最小分别执行 A/B/C，检查 IP、claim ID、通知计数；再做高电平有效 completion 后重挂对照。

### P1-11（新发现）：PLIC claim 错受 threshold 过滤

**F**：[plic:285–289](<../../../rtl/plic/plic.v#L285-L289>) cand_raw 同时含 enable 和 priority>threshold；[324](<../../../rtl/plic/plic.v#L324>) claim_id 从同一候选仲裁，阈值因此同时屏蔽通知和 claim。官方规范明确 claim 不受 threshold，可将阈值设最大以关闭通知并轮询 claim。

**S / 触发**：源1 pending、enabled、priority=7、threshold=7；MEIP 应0，但 claim 应返回1并清 IP；当前返回0，轮询模式无法取走 pending。

**测试为何漏**：[tb_plic:280–287](<../../unit/tb_plic.sv#L280-L287>) 正好覆盖该状态却断言 claim=0，错误 oracle。

**建议 / E**：claim 候选用 pending&enable&priority!=0；notification 候选再加 threshold；最高优先/同优先低号规则共用但输入区分。测 threshold=max 时 notification=0、claim仍返回有效源且清 IP，priority=0 不应 claim。

### P1-12（新发现）：2A M 模式 SRET 被 TSR 误禁

**F**：[core_top:1423–1426](<../../../rtl/top/core_top.v#L1423-L1426>) `de_sret & ((priv==U) | csr_tsr)` 不限定 TSR 仅 S 有效。规范 TVM/TW/TSR 段明确 TSR 拦截 S-mode SRET；M 可执行低一级 xRET。

**S / 触发**：M 先置 TSR=1，设 sepc/SPP，执行 SRET；应执行 S 栈返回，当前 cause 2。M 固件使用 SRET 辅助切换/恢复会意外陷阱。

**测试为何漏**：trap/priv TB 直接注入 xret_valid，不经过 e_priv_ill；未测 M+TSR=1 的指令合法性。

**建议 / E**：拒绝条件限定 U 或 (S&&TSR)。检查 M+TSR=0/1 均允许，S+1 拒、S+0 允许，U 均拒；同时验证 SIE/SPIE/SPP/MPRV 与目标 PC，不只测没有 cause 2。

### P2-01（新发现，验证证据不足）：CLINT/PLIC “不发 AXI”断言恒真，不能证明集成路由

**F**：[tb_clint:80、121、138](<../../unit/tb_clint.sv#L80-L138>) 与 [tb_plic:111、153、170](<../../unit/tb_plic.sv#L111-L170>) 将 axi_like_activity 硬接0再断言0。文件头称未来增加 AXI 端口会自动编译失败，也不成立：命名例化可留未连接端口。设备没有 AXI 输出只证明局部结构，不证明 top 没并行向 AXI 发同一访问。

**影响 / 测试盲区**：即使 top 丢失 no_axi 门控、重复向 DDR 发 CLINT/PLIC 写，这两个 TB 仍不受影响；报告不能把其 PASS 当集成“无 AXI”证据。当前 [mmio_route:163–166](<../../../rtl/mem/mmio_route.v#L163-L166>) 静态截获正确，但最终 top 门控本轮未读全，不报告其已有功能错误。

**建议 / E**：在两 top 或真实 LSU/MMIO 集成 TB 监视 AR/AW/W 握手，CLINT/PLIC 全窗口（含 threshold/claim）访问必须0，外部普通 MMIO 对照必须非0；删除/降格恒真断言的证明性表述。实际关门控变异后该检查必须失败。

### 旧线索处置（避免复制已修结论）

| 线索 | 当前判断 |
|---|---|
| D2 U 模式被 SIE 掩蔽 | **已修无需重报**：[trap_ctrl:184–186](<../../../rtl/csr/trap_ctrl.v#L184-L186>) 对 U 取常量1。仅静态确认；主责 TB 仍缺 U+SIE=0 的显式回归，因此不能给已运行验收结论。 |
| D3 自身 PMP L 锁 | 已知未修，P0-02。 |
| D4 counteren | 已知未修，P1-01。 |
| D5 TVM | 已知未修，P1-02。 |
| D6 Vectored WARL | **已修无需重报**：[csr_file:469–479](<../../../rtl/csr/csr_file.v#L469-L479>) Vectored 清低8位，与 trap_ctrl 基址一致；保留 MODE 字段处理需单独双写旁路回归。 |
| D7 A/WFI | 已知未修，P1-03，仅2B。 |
| D9 未委托 S-source 中断 | 独立代入已确认未修，P1-04；不依赖旧报告标签的结论。 |
| D1 / D8 | 非本域主责，未独立复核其修复，不复制/再报。 |

### 只读查询复现示例（已查询；不是仿真命令）

```sh
pwd
git rev-parse HEAD
git status --short -- rtl sim/unit
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search 'pmplbitwriteprotection source:isa-manual'
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js get 10581
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js get 10557
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search 'mcounteren clear attempts source:isa-manual'
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search 'sip sie mideleg source:isa-manual'
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search 'TSR SRET S-mode source:isa-manual'
```

输出摘要分别为 HEAD 匹配、只列既有 Markdown 状态；KB 返回带上述规范锚点的段落。工具输出未保存为日志文件（不在允许写范围内）；本报告不冒充已有独立实验日志。

## 【遗留 / 风险】

1. 这是默认配置静态全局分域审计，**不证明全部特权架构合规**；最小验证全部待实验，无实际 PASS/FAIL 运行结果。特别是年轻访存与 CSR 同拍旁路、trap 与写 CSR 同拍优先级，还需两 top 实际时序反证。
2. PMP checker 的正常 TOR/NA4/NAPOT、首个任意字节匹配、全笔覆盖、L=0 M bypass、S/U 无匹配拒绝在已读表达式中未另发现确定错误；未验证零字节、跨32-bit顶端、非默认 PMP_ENTRIES/ADDR_W/G 参数，不能把注释的“参数化”当作已通过证据。AMO 只需W的假设依赖 R=0/W=1 保留组合与上游访问分类，未扩大为本域确定错误；LR/SC/CMO 具体权限另交内存域。
3. CSR 还存在值得独立后续检查的边界：mstatus.MPP 非法编码的**存储读回**未 WARL 化（priv_ctrl 只在使用时 legalize）；csr_file SD 用 FS!=Off 而非 Dirty，但两 top 有 FS/SD 覆盖，本轮不把模块局部表达式当已确认 top 功能错误；SEIP 软件位在 CSRRS/CSRRC 时应排除外部源回读污染，需沿实际读改写路径做专门反证；M/W 双写保留字段旁路的现值来源需补相邻双写试验。以上未计入确定问题数。
4. CLINT strobe 未统一用于 mtime/mtimecmp，PLIC strb_word_ok 只限制 resp_hit、没限制时序副作用；由于本轮未完整查两 top 的访问大小拒绝/接受契约，仅保留接口风险，不夸成已确认标准 LW/SW 路径错误。
5. PLIC 默认5源/2上下文审计充分；更大源号映射只有4-bit、complete 对 src_level 只取 comp_id[2:0]、上下文译码固定0/1，参数扩大不在本轮功能配置背书内。priority 变更但 cand 掩码不变时 function 隐式读数组对模拟器敏感性也未实验。
6. PTW/TLB 不在主责、未读；两 top、decoder、back2 仅上述接口抽查，未知集成问题不等于不存在。P0-01 已及时发送母 Agent，请与后端分域合并去重并优先确认修复设计。
7. 保留此前未提交 Markdown；本轮仅此报告新增。riscv-kb skill 不可加载是实际工具限制，已通过指定可靠只读 CLI 取得规格，未重建缓存或安装任何东西。
