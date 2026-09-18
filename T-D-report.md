================================================================================
T-D 交付报告（编码子 Agent）—— 2A 基线核 sfence.vma 译码 + 取指侧 Sv32 翻译
================================================================================

【结论】
1) 三件事全部完成并自证：
   ① sfence.vma 译码 + TLB/冲刷/L1D/L1I/取指重定向接线（W 级提交拍执行）；
   ② 取指侧 Sv32 翻译接通（TLB 第二查询口 + PTW 由 M 级引擎串行复用 + 结果/故障
      锁存 + 陈旧响应归属校验）；
   ③ SV32_SUPPORTED 已在 rvtest_config.h 打开、rv32gc-2a.yaml 同步声明 Sv32。
2) Sv32 家族 37/40 通过（可运行用例 100% 之外仅剩 2 类口径差异，见"遗留"）：
     Sv        29 pass / 2 fail（2 例 = 上游 NORUN 的 mstatus.SBE 用例，**Spike 自身
                                 跑失败、无参考可比**，run.sh 标 "(spike)"）
     SvPMP      2 pass / 2 fail（sv32_pmp_on_pte_{S,U}mode：PTE 读的 PMP 权限口径）
     SvPMPZicbo 4 pass / 0 fail
     SvZicbo    0 pass / 2 fail（首因 = menvcfg.CBIE/CBCFE 不可写，属 csr_file 范围外）
     Svade      2 pass / 0 fail
     Svbare     3 pass / 0 fail（回归项）
   ⇒ 反证/直证/全量回归/lint 全部达标（见【证据】）。
3) 顺带修掉 6 个"先前从未被任何用例覆盖"的 Sv32 路径缺陷（其中 3 个会让数据侧
   Sv32 完全不可用），详见【证据】6。

================================================================================
【证据】
================================================================================
■ 1. sfence.vma 译码与冲刷（验收：Sv32 家族 + 反证）
  · 译码（rtl/decode/decoder.v §4.9）：funct7=0001001、funct3=000、**rd=00000**、
    opcode=1110011（MASK 0xFE007FFF / MATCH 0x12000073，与 binutils 逐位一致）
    ⇒ rd≠0 落 ill_instr；rs1=VA 操作数、rs2=ASID 操作数（取值任意，非保留）。
    ★ **对派活书的一处更正**：任务书正文括号里写"rs2≠0 属保留，应非法"——与 ISA
      不符（supervisor.adoc norm:sfence_vma_asid_only 明确 rs2 即 ASID；测试
      Sv/sv32_global_pte_Smode.S 就执行 `sfence.vma x0, t0`）。本实现按 ISA：
      rs2≠0 = 按 ASID 部分冲刷（G=1 项保留），否则该用例必红。
  · 执行点（rtl/top/core_top.v §9.3/§12.3.1）：W 级提交拍 `sfence_sync_pending`
    当拍完成四件事：① tlb.sfence_valid=1（粒度冲刷：全/按 VA/按 ASID/交集，tlb.v L3）；
    ② L1D `inval_all`（256 拍内部扫描，防陈旧页表行）；③ L1I 全阵列失效（复用
    fence.i 扫描）；④ 更年轻 M/E/D 槽作废 + F 重定向到 mw_pc_next（不走上一次
    同步的 fencei_pc_q——那会跳错路径，已在注释中留证）。
  · U 模式执行 sfence.vma ⇒ 非法指令（S 模式指令；Spike require_privilege(PRV_S)）。
    mstatus.TVM 门控**未实现**（派活书明确不要求，sv_mstatus_tvm_test 仍在 exclude）。
  · satp 写：沿用 L4（**不**自动冲刷 TLB，与 Spike/ISA 一致）；仅作废取指侧翻译
    结果锁存（页表根变了）。
  · 反证（cp 备份，全程 md5）：
      修复版 core_top.v md5 = 954db4246cee2b6ff68bd78a8daf62c6
      no-op 版（sfence_sync_pending=1'b0，整个 W 级冲刷/重定向机制关闭）
                              md5 = 4e661e0a21a9b3e61dcd9be675cb37a6
        sv32_global_pte_Smode  FAIL（签名 16/40 行不同）
        sv32_global_pte_Umode  FAIL（16/40）
        sv32_Svade_Smode       FAIL（68/108）
        （sv32_invalid_pte_Smode / sv32_misaligned_page_Smode 仍 PASS —— 它们不依赖旧条目失效）
      cp 恢复后 md5 回到 954db424…，5 例全 PASS（Svade 复跑 2/2 PASS 另附）。
      ⇒ "sfence.vma 真的在起作用"这一点被反证钉死。

■ 2. 取指侧 Sv32 翻译真实生效（验收③直证）
  · 定向程序 sim/arch_test/dm_sv32_fetch.S（新增，--directed 运行）：
      把**代码页**映射到非恒等 VA：VA 0x4000_0000 ⇒ PA 0x8000_0000（4 MiB 超级页），
      M 模式建表 → 写 satp → `sfence.vma` → mret 进 S 模式在 VA 处执行 → 经 VA 访存
      → ecall 回 M 模式写签名。
  · 结果：`./sim/arch_test/run.sh --directed dm_sv32_fetch` → PASS(4/4 行, first_diff=none)
    （Spike 参考 = 5a5a1234 / 5a5a1234 / 5a5a1345 / 00000009）。
    ★ 若取指把 PC 当物理地址用，取指会打到未登记区间 0x4000_00a4（RAM 只覆盖
      0x8000_0000+）⇒ DECERR/cause 1 ⇒ 必 FAIL。实测 DUT 日志"未登记区域访问 读=0"。
  · TB 层临时探针取证（**已删除**，仅取证时编译 -DRV32GC_DBG_SV32）：
      [DBG] TR-START va=400000a4 priv=1 satp=80080004 tlbhit=0 …
      [DBG-TLB] FILL idx=0 va=400000a4 vpn=40000 ppn=080000 perm=38
      [DBG] TR-DONE va=400000a4 pa=800000a4 flt=0 cause=0
      [DBG] FREQ va=400000a4 pa=800000a4 unc=0 done=1 tlbhit=1 tlppa=800000a4
    ⇒ 取指请求地址 = 页表翻译后的 PA（PPN 0x080000 = PA 0x8000_0000 >> 12）✓

■ 3. 全量回归（SV32_SUPPORTED 打开后**所有**二进制都变，必须整组重跑）
  ★ 本轮数字来自**最终 RTL**（md5_final.txt 所列版本，12:00–12:38 整轮复跑；
    另有一轮 11:16–11:55 的等价结果，两轮逐组一致）/tmp/rv32acc/full2.log。
  ./sim/arch_test/run.sh --group <组> --jobs N：
    rv32i/I 39/39   F 78/78   D 104/104   M 8/8   Zicsr 6/6   Zicntr 2/2
    Zicbom 3/3      Zifencei 1/1   Zaamo 9/9   Zalrsc 2/2
    tests/priv/PMP* 63/63        Svbare 3/3
  全部 `GROUP <组>: N pass / 0 fail / 0 skip` + `RV32_ARCH_TEST_RUN: PASS (N/N)`，rc=0。
  ./scripts/regress.sh → `REGRESS: 22/22 PASS`（rc=0；日志 /tmp/rv32acc/regress_final.log；
    含 tb_ptw —— 见 §7 的 TB 同步说明）。

■ 4. 各组 IN 数（`run.sh --list` 实测，与排除后实际数一致）
    Sv 31（全 sv32_*；sv39/48/57 已排除）、SvPMP 4、SvPMPZicbo 4、SvZicbo 2、
    Svade 2、Svbare 3 ⇒ Sv32 家族合计 43 例；本任务转绿 37 例。

■ 5. Verilator lint（同命令对比 HEAD 与当前树：-Wall -Wno-fatal --top-module core_top）
    基线(HEAD) : 463 warnings，UNOPTFLAT=0，IMPLICIT=0
    当前       : 462 warnings，UNOPTFLAT=0，IMPLICIT=0
    diff 只有一条"被消掉"的旧警告（tlb.v 的 34 bit 拼接 WIDTHTRUNC，随 PA 重建
    口径修正一并消失）⇒ **无任何新增 warning**（更无 UNOPTFLAT/IMPLICIT）。
    （对照命令与产物：/tmp/rv32lint/{base,new}.lint）

■ 6. 为让 Sv32 真正可跑而必须修掉的既有缺陷（全部在允许改动文件内）
    B1 TLB 的 PA 重建错位（rtl/csr/tlb.v + ptw.v）：`fill_ppn=PA[31:10]` + `{ppn,off}`
       34 bit 拼接截断 ⇒ PPN[21:20]≠0 的页（**本平台 RAM 全在 0x8000_0000+**）PA 整体
       错位，实测 VA 0x9040_7014 → PA 0x8000_7014（应 0x8000_9014）。改为 32 bit 物理
       空间下的 20 bit 页号（PA[31:12]，高 2 位补 0）。
    B2 L1I 读/写地址口径不一致（core_top.v §5.3）：l1i.v 读路径用 cs_vaddr 的索引/tag、
       填充写路径用 cs_paddr 的行基址 ⇒ 非恒等映射下"读地址≠写地址"，表现为**每拍
       miss 的填行活锁**。修法：翻译开启时把查询地址也切成 PA（L1I 变 PIPT），
       l1i.v 本体不动。
    B3 L1D 里的陈旧页表行（core_top.v §9.6）：PTE 隐式读走 L1D，而软件的 PTE 写走 AXI
       旁路 L1D ⇒ L1D 持有陈旧 PTE。修法：sfence.vma 拍给 L1D `inval_all`（内部 256 拍
       逐组失效；L1D 内不可能有脏行——数据存取全走 AXI、A/D 写路径按 Svade 已不可达）。
    B4 陈旧取指响应竞态（core_top.v §5.4）：l1i 响应属于"上一拍被接受的请求"，而顶层
       `fetch_rsp_va` 假定响应属于当前 PC ⇒ 重定向（陷阱/xRET/分支/fence.i/sfence.vma）
       与响应到达同拍时会**把旧地址处的指令塞给新 PC**（实测 Sv/sv32_misaligned_page_
       Smode：陷阱后 PC=mtvec 却执行了旧地址的 nop ⇒ 处理程序向量号差 1 ⇒ 签名 1 字不同）。
       修法：给缓存口径请求记"请求时的 PC"，响应仅在 PC 未变时算数，否则丢弃并自动重发。
    B5 PTW 不可中止（ptw.v 新增 kill 端口）：PTE 响应由 M 级 FSM 提供，FSM 因陷阱中止后
       PTW 停在 S_L1_W/S_AD ⇒ req_ready 恒 0 ⇒ 此后所有 Sv32 访问永久挂死。修法：kill
       立即回 IDLE，并同拍压住 fill_valid（防失效竞态把陈旧翻译灌进 TLB）。
    B6 遍历被无限重启（core_top.v §9.2 ptw_done_q）：PTW 完成脉冲只维持 1 拍，若 FSM
       正在服务 PTE 读（PTEA/PTER/PTEW）就会漏接，回到 M_S_TR 后 PTW 已受理同一请求
       ⇒ ~10 拍零提交死循环。修法：完成脉冲粘滞记账（M_S_TR 拍即消费清零）。
    B7 取指 PMP 的 mtval 写成了 PA（fetch_unit.v）：PMP 匹配要用翻译后 PA，但 mtval 恒为
       VA（norm:mtvalvaddrnot_paddr）——原实现同一个信号两用，SvPMP/sv32_pmp_on_pa_* 全红。
       Bare 模式下两者逐位相同 ⇒ tb_fetch_unit 判据不受影响。
    B8 cbo.* 的翻译权限（core_top.v）：原按"写"判（AMO 同族）⇒ RX 页上 cbo.clean/flush/
       inval 被误判 page-fault；参考模型 Spike 用 LOAD 判权限、把异常折算成 store 类
       （mmu.h:253-259 `clean_inval()`）。修法：cbo 翻译按 R（2'b01），cause 用
       `cbo_cause_fix()` 把 13→15 / 5→7。修后 SvZicbo 的首个分歧（病例 4/5 的假故障）消失。
    B9 load-use 互锁补 sfence 的 rs2（core_top.v §12）：`lw t0,..; sfence.vma x0,t0`
       原先会读到未完成的旧 ASID 值。

■ 7. 单元 TB 同步（**仅同步被强制改变的口径，不削弱任何判据**）
    · sim/unit/tb_ptw.sv：① 例化补 `.kill(1'b0)` 与 `#(.SVADE(0))`（模块新增端口/参数，
      本 TB 专测"硬件 A/D 更新"通路，故显式选它要测的那条）；② **一条**断言的期望值
      由 `PA[31:10]` 改为 `PA[31:12]`（旧期望正是 B1 缺陷的编码）。其余 49 条断言原文不动。
      改动理由与新旧值都写在注释里（0x0005_5123 ⇒ 0x55）。
    · sim/unit/tb_fetch_unit.sv **未改**（fetch_unit 端口契约未变）。
    · sim/arch_test/exclude.list **未改**（未新增任何 Sv32 排除）。

■ 8. 性能/超时余量（验收"sv32 用例不得进 900s 超时区"）
    Sv32 用例实测拍数：global_pte 12 584、VA_all_ones 10 364、pmp_on_pa 23 682、
    Svade 28 308（TB 上限 1 500 000 拍、墙钟 900 s）⇒ 余量 >50x，无超时/无挂死。
    （说明：sfence.vma 现在会触发 L1I+L1D 各 256 拍全阵列失效，属**有意**的保守实现。）

================================================================================
【遗留/风险】（逐条带证据与建议）
================================================================================
L-1 sv32_pmp_on_pte_{S,U}mode 不过（2/4，SvPMP）——**PTE 隐式访存的 PMP 权限口径**
    现象：测试把 root 页表配成"仅 X"（NAPOT X，无 R/W）后，取指访问期望 cause 1。
    DUT 现口径（08 §5.5 / ptw.v W1）：PTE 读按**原访问类型**判权限 ⇒ 取指按 X 判 ⇒
    放行 ⇒ 不故障；Spike：`pmp_ok(pte_paddr, ptesize, **LOAD**, PRV_S, …)`
    （riscv-isa-sim/riscv/mmu.h:490），异常类型才取原类型 ⇒ cause 1 ✓（与测试期望一致）。
    试改 `pmp_req_acc = ACC_LOAD`（已实测）：该两例的首个差异消失（病例 4/5 假故障不再
    出现、测试跑完不再挂死），但随后仍在"PTE 指向 RVMODEL_ACCESS_FAULT_ADDRESS"那组
    与 Spike 分歧（DUT 报 page fault 0xf / Spike 报 access fault 0x7，且 epc 不同）——
    说明除权限口径外还有**故障次序/来源**的连带差异，需要独立任务（改 ptw.v + 复核
    PMP 组/ SvPMPZicbo 组 + 上游测试语义）后再动。本轮保持项目原口径不动，如实报红。
    证据：sim/arch_test/work/sv32_pmp_on_pte_Smode/{result.txt,dut.data,spike.data}。

L-2 sv32_zicbom_exceptions_{S,U}mode 不过（2/2，SvZicbo）——**首因在 csr_file 的
    menvcfg 位域，超出本任务允许改动范围**
    首因（签名第 90 字）：测试执行 `csrs menvcfg, MENVCFG_CBCFE|MENVCFG_CBIE` 后回读，
    Spike=0x270（CBIE=11、CBCFE=1），DUT=0x210（CBCFE 读 0、CBIE 只置了低位）
    ⇒ DUT 的 menvcfg.CBCFE 不可写/未实现。之后测试的 cbo 门控与陷阱次序整体偏移。
    （cbo 权限口径本身已按 Spike 修好，见 B8：修后病例 4/5 的假 page-fault 已消失，
      分歧从 case-4 推迟到 case-11。）建议独立任务：核对 csr_file.v 的 menvcfg 写掩码
    （CBIE/CBCFE/CBZE）并与 Spike 对齐后复跑本组。

L-3 Sv/sv32_mstatus_sbe_{set,and_sum_set}_Smode 不过（2/31）——**上游 NORUN 用例 +
    参考模型自身失败**
    证据：① 测试头 `REQUIRED_EXTENSIONS: [I, Sv32, NORUN]`（"Remove NORUN once Sail
    supports Big Endian"）；② 手工跑 Spike：`*** FAILED *** (tohost = 1)`（= 程序自报
    失败，exit_code 非 0）；run.sh 因此把该例标为 `(spike)` 失败，DUT 根本没跑。
    ⇒ 无参考可比，非 DUT 缺陷。若要求该组"全绿"，唯一诚实路径是按上游 NORUN 语义把
    这两条登记进 exclude.list（本任务明令**禁止**新增 Sv32 排除，故未做，留给母 Agent 裁决）。

L-4 mstatus.TVM 门控未实现（按派活书要求不做）：S 模式 satp 访问/sfence.vma 的 TVM
    陷阱未建模，Sv/sv_mstatus_tvm_test.S 仍在 exclude.list。

L-5 取指通路仍要求"4 B 对齐指令流"（**与本次改动无关的既有边界**）：fetch_unit 的
    parcel 对齐在起始 parcel 位于字高半（PC[1]=1，即上一条为压缩指令）时不出指令，
    C 扩展的 2 mod 4 指令流不支持（Zca 组整体在 exclude.list）。跨页/跨字 32 bit 指令
    的第 2 个 parcel 依赖"4 B 字不跨页"，Sv32 下成立；若将来跑 Zca，需要先补该通路。

L-6 cbo 的 **PMP** 权限口径仍按 W（rtl/mem/lsu.v 的 PT_AMO），与 Spike 的 R 口径不同；
    当前 SvPMPZicbo 4/4 全过（现有用例不构造"PMP 区可 X 不可 R + cbo"组合），故未动
    lsu.v（也不在允许改动清单内）。登记为已知口径差。

L-7 sfence.vma 现触发 L1I+L1D 各 256 拍全阵列失效（保守但 ISA 允许的 over-fence）。
    若后续追求性能，可只在"页表/权限真正变化"的场景失效，或给 L1D 增加"页表行不缓存"
    旁路（需动 cache，本任务禁止）。

L-8 数据侧 L1D 的 VA/PA 口径（cs_vaddr=VA、cs_paddr=PA）在**数据通路全走 AXI** 的 2A
    集成下不暴露；一旦将来把 load/store 接回 L1D，需要与 L1I 同样处理（PIPT 或
    VA-tag+失效），否则会重现 B2 类问题。

================================================================================
【交付物清单 / 复现命令】
================================================================================
改动文件（git status）：rtl/pkg/rv32_defs.vh、rtl/decode/decoder.v、rtl/csr/ptw.v、
  rtl/csr/tlb.v、rtl/fetch/fetch_unit.v、rtl/top/core_top.v、
  sim/arch_test/rvtest_config.h、sim/arch_test/rv32gc-2a.yaml、sim/unit/tb_ptw.sv、
  新增 sim/arch_test/dm_sv32_fetch.S；未提交 git（按纪律）。
最终 md5（/tmp/rv32acc/md5_final.txt，= 全量回归所用版本）：
  rtl/top/core_top.v          954db4246cee2b6ff68bd78a8daf62c6
  rtl/csr/tlb.v               4beabec4fb422b7296402fbf1c9cac0d
  rtl/csr/ptw.v               b893543f37aeb3b28e44ad59edb96d98
  rtl/decode/decoder.v        d9b28f1d935b71ea3802e6323360019e
  rtl/fetch/fetch_unit.v      59fc3b136e7cbf652dc0b045421811b1
  rtl/pkg/rv32_defs.vh        46b9b74b4d2f3ef6921be3160c23f663
  sim/arch_test/rvtest_config.h  ae7ca066cba368a19923c74955733ce4
  sim/arch_test/rv32gc-2a.yaml   190ff49abd9ce3384e248629c522310b
  sim/unit/tb_ptw.sv          b1b62dd53dc3c9972aec72b985df1755
复现：
  ./sim/arch_test/run.sh --group Sv --jobs 16          # 29/31（2 例 NORUN）
  ./sim/arch_test/run.sh --group Svade --jobs 8        # 2/2
  ./sim/arch_test/run.sh --group SvPMPZicbo --jobs 8   # 4/4
  ./sim/arch_test/run.sh --group SvPMP --jobs 8        # 2/4（L-1）
  ./sim/arch_test/run.sh --group SvZicbo --jobs 8      # 0/2（L-2）
  ./sim/arch_test/run.sh --group rv32i/I --jobs 16 ; F ; D ; M ; Zicsr ; Zicntr ;
  Zicbom ; Zifencei ; Zaamo ; Zalrsc ; 'tests/priv/PMP*' ; Svbare
  ./sim/arch_test/run.sh --directed dm_sv32_fetch      # 取指翻译直证
  ./scripts/regress.sh                                 # REGRESS: 22/22 PASS
  bash /tmp/rv32acc/negctl.sh                          # 反证（现网已恢复）
