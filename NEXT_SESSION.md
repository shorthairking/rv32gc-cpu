# NEXT_SESSION.md — RV32-GC 新项目（重启版）跨会话交接

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu/`（dev 分支；master = 旧项目冻结历史，勿动）。
> 更新日期：2026-09-16（阶段二 2A M2 收尾中）。

## 1. 项目状态（截至本文件更新时）

- 阶段 0 ✅：重启五件套（AGENT.md / README.md / USAGE.md / prompts/×3）已提交，载体口径统一（commit `22ee44e`）。
- **阶段一 ✅（2026-09-14 完成，已 git 提交）**：15 篇文档全部落盘并通过母 Agent 复跑验收（文件/图/参数/引用标记/禁词六类判据），ISA 口径 T1–T8 引用闭环完成，知识库已重建（3711 文档，旧残留已清）。**当前停下等待用户审阅阶段一产物与 §5 裁决清单**。
  - `docs/design/01-overview-datapath.md` 02-pipeline 03-out-of-order 04-predictor 05-cache-memory 06-csr-privilege 07-verification（7 篇）
  - `docs/porting/01-overview.md` 02-uboot 03-linux-opensbi 04-nand-driver 05-rootfs（5 篇）
  - `docs/kb/platform-facts.md` isa-notes.md tools-and-flow.md（3 篇）

## 1.5 当前状态（2026-09-21 晚：2A 收官 + 2B/U-Boot 双线并行）

- **2A M1–M5 全部收官**（tag `2A-M5` 已推远端；master=dev=9fac069）：arch-test 全绿、60 MHz 时序达标（WNS +0.031/0 失败端点，面积 39.4%）、上板 `RESULT: RV32GC-M5-OK` @33 MHz 同域；板上三缺陷修复（R2 rdata 锁存 `7a06825`、mdu div_gen 字段序 `4a86a05`、步④ 窗口 `2e93a4f`）。
- **A 线 2B（用户已批）**：2B-1 前端+预测器 ✅（`f42827e`：regress 26/26、准确率 mixed 90.85% 选择器优于单侧、Spike 黄金轨迹 248/248）；**2B-2 后端 ✅（tag `2B-2`）**：三程序锁步 C1–C5 全绿（161/178/126 条、443/721/913 拍、CHK 零违规、无停顿，母代理亲跑复验）、tb_back2_iq 151/151、tb_back2_ipc **IPC=2.0000**（6000 条/3000 拍）、regress **30/30 PASS**（T6 墙钟档）；缺陷台账 sim/unit/back2_report.md（B1–B29，其中真 RTL 缺陷：B24 lsq mem_size log2 口径、B27 日志下标不回绕、B28 同块 store→load 发射序（INORD_LOAD 队列级闸门）、B29 CSR 写数据字段语义（提交拍 PRF[ps1i] 现算）；C5 分档下限 0.30/0.19/0.1094 带 ≥26% 裕量）。**2B-3 LSQ ✅（tag `2B-3`）**：LQ 32+SQ 32 两步扩容全绿——SQ 16→32/LQ 4→32/索引与标签位宽/ROB 载荷 STQ 位域（MSB 409→410、LSB 恒 406、RB_W 恒 416，探针钉死）；真乱序边界（stq_rob 分配期写入、LQ E1 入队+提交点释放、写回乱序标签匹配、逐字节转发 32 候选最年轻胜、store 提交序排空）；锁步 30/30 与基线逐位一致（443/721/913 拍，C5 无需重测）、iq 151/151、fwd 10/10、ipc 2.0000、regress **31/31**（母代理亲跑）。遗留→2B-4：同拍多 store 提交组排空（rob.v 潜在缺陷，实测 0 拍不可达）、放开 load 越过更老未就绪 load 需 LQ 分配改 D3 期（载荷 [415:411] 有 5bit 空位）、LQ 释放专用单元用例。后续 2B-4 合体 → 2B-5 时序上板。
- **B 线 U-Boot（基线=上游 fork dev 分支）**：B-1/B-2 板级骨架 ✅（u-boot `3d9e78e8e80`）；B-3 NAND 驱动 ✅（u-boot `124a604ebc5`，自包含 BCH-4 + DMA 描述符，13.6 万断言）；B-3.5 引导链 ✅（`1c8fce2`）；**QEMU chiplab machine ✅**（qemu/ chiplab-qemu-dev，-M chiplab，报告 docs/chiplab-qemu/）；**B-4/B-5 + E6–E8 ✅**（u-boot dev `0729af1c746`+`90373e8469b`，saveenv 持久/bootcmd 自动执行全绿）；**官方重打包 ✅**（spi_flash.img 956276B md5 27a9d9a5，旧件 .pre-E8.bak）；**Linux L-m1 ✅ + L-m2 ✅**（linux dev `46200caf`+`04e80124`，qemu `b7e2881e16`+`3c095bf329`，rv32gc-cpu tag `L2-NAND`；内核 0x03400000 可用内存 76MiB、NAND BCH-4 布局跨层交叉验证全 PASS，判据 L1–L8 全绿，报告 docs/linux-port/）；**L-m3 ✅（UBIFS rootfs + 纯 NAND 冷启）**：根因=NAND_SUBPAGE_READ 子页读被框架接管（restamp_ecc 未清 ⇒ 短读全 0xFF），另修 READSTART/4 周期地址解析/fail-closed DATA_IN/initramfs sync/内核 image_size 口径/nandwrite -p；零注入冷启全链 PASS（U-Boot 从 NAND 读 kernel/dtb/initrd → booti → UBIFS 根 ubi0:rootfs，/persist.count 跨 QEMU 重启 1→3，母代理亲跑 `L-M3 (UBIFS + NAND boot): PASS`）；linux dev 已提交，rv32gc-cpu tag `L3-UBIFS`；遗留（可选）：精简 defconfig、真 ecc.read_subpage 性能优化；报告 docs/linux-port/README.md §9。**MAC/TFTP ✅（tag `B-TFTP`）**：u-boot dev `e14e7f924b7`（chiplab_dmfe.c 811 行 Tulip 语义驱动、PHYLIB legacy MDIO 位拍、CSR6.PB 与项、MAC 地址 pdata->enetaddr）、qemu `ff45aed9cf`（hw/net/chiplab_dmfe.c 寄存器级模型挂 0x1ff00000）；QEMU 三阶段 regs/full/persist 全 PASS（ping 10.0.2.2 alive、tftpboot 三镜像字节一致、booti→UBIFS 根、bootcmd tftp 优先+NAND 回退冷启自动执行，母代理亲跑）；**官方重打包**：boot_stub.S BOOT_LEN_UBOOT 0x620AC→0x66830 + BOOT_LEN_DTB 0x1774→0x1830（DTS 加 MAC 节点后 dtb 6189B），spi_flash.img 956464B md5 **174a5a8970684e9f4bb7cc2e54ad43bd**（旧件 .pre-MAC.bak）；板上 TFTP runbook=docs/linux-port/mac-tftp-boot.md（对齐官方网页 §5.6，bootcmd 仅 ';' 串因 HUSH 关闭）；MAC 中断=PLIC 源 0（非源 5，RTL int_out[0]）。遗留：axi_mux_sim 不译码 MAC ⇒ 上板实测为最终判据；U-Boot 段余量仅 6096B。
- **远端**：rv32gc-cpu origin 已切 SSH（git@github.com:shorthairking/rv32gc-cpu.git）；master/tag/dev 已推。u-boot/linux 两 fork 仓各建 dev 分支（u-boot 已切 SSH，linux 已切 SSH）。

### 1.5.1 📋 交接存档点 #11（2026-09-24 夜，用户新开 session 继续；本会话已停）

- **★子 Agent 路由口径（用户 2026-10-01 裁决，最高优先级）**：**两个 opencode-go provider 并存放行、档位 `high`**——`provider` 取 `"opencode-go"` 或 `"opencode-go-chat"`（都放行；精确名以新会话 `list_subagent_models` 实查为准）、`model: "deepseek-v4.1-flash"`、`reasoning_effort: "high"`（允许由 xhigh 降档）。宿主配置 = profile patch `~/.dsh/profiles/web/cordis.patch.yml` 的 `subagent-model-selection-settings`（**`~/.dsh/settings.yaml` 已被 dsh 移除，勿再引用**）；**已存在的会话不重算，必须新开会话才生效**。新会话**先 `list_subagent_models` 实查确认** provider 名再派活；注意 `subagent_fork` 无路由字段属设计如此。
- **一句话现状**：2B 功能仿真全部完成（tb_core_top_2b 219/219、regress 33/33、锁步 57/57、iq 151/151）；2B-5 面积压缩主干已落地（ROB BRAM 化完成），最新 tag **2B-4.45**（本地 b13e4cc 已 push 成功）。**面积仍超器件**：全核 366 483 LUT = 272.28%（xc7a200t 134 600）。
- **面积现状（综合实测，tag 2B-4.45）**：ROB LUT 133 034→106 704(-19.8%)、ROB FF→15 246(-44.8%)、BRAM 19→35(+16)、全核 FF 142 259→129 899。剩余大头（hier 报告）：u_rob 106.7k、u_ren_i 50 248、u_ren_f 49 894、u_lsu 43 357、u_prf_i 23 696、u_fpu 23 811、u_front 18 488。
- **★用户优化方向（新会话照此执行）**：①**先分析后分配**——先派一个只读子代理（info/testing 型）深挖综合/布局报告（`fpga/out/synth_2b_16.667ns_utilization_hier.rpt` + 对 `post_synth_2b*.dcp` 跑 `report_utilization -cells`），定位各模块 LUT 的具体去向（是比较逻辑 / 冗余 tag / 写口 mux / 多写源表项 mux 等），把结论回报母代理；母代理拿到报告**分析后再**进行任务分配；②**多子代理并行**——后端（rename/LSU/ROB 剩余 nq+updq 写 mux/prf 等）多个模块并行派 coding 优化，各自保四套判据绿（深 219/219+iq151+lockstep57+regress33、浅 219/219+regress33），文件不冲突。
- **已定位的已知杠杆（供分析子代理聚焦）**：nq[128]×50 与 updq[128]×102 的多写源每表项写 mux；窗口收窄 §B4.53.1 100bit 位图（窗口 FF 3.3k→0.8k、RAMB36 16→8）；新增 8 组合环（alloc 握手 alloc_fire→bw_we/bw_woff 与 alloc_ready←cmt_n_w←win_lane_ok，set_false_path 打断=假路径风险）；PLIC→E1 使能组合锥 138 级（impl 首要时序对象）。
- **后续路线**：分析→并行优化（窗口收窄/nq+updq 写 mux/rename 瘦身检查点 16→8/LSU 转发降宽/组合环修复）→ 综合复测 → impl 布线 → 60MHz → 100MHz → 上板。面积压不到容量需用户决策（换器件/降规格都碰硬指标）。
- **备份/日志**：../.b2chk/（*.s41-*.s77、baseline_preB2_*.rpt、postB2_*.rpt、synth_2bprobe*.log、绿证 log）、fpga/out/synth_2b_16.667ns_*.rpt + post_synth_2b*.dcp。恢复方式：新会话按 AGENT.md §7/§9 开工清单（读 AGENT.md → git status → NEXT_SESSION.md → list_subagent_models）→ 按本点①②执行。

### 1.5.2 📋 交接存档点 #12（2026-10-01：L1 收官 + 用户授权降条目 + ROB 64 在跑）

- **★用户裁决（2026-10-01）**：按分析报告"选项 2"执行——**放宽 §1 条目数量硬指标**（用户："后端的条目数量指标对于四发射来说太多了"）。授权：ROB 128→64、LQ 32→16、PRF 96→64，配合 IQ 载荷瘦身与 ROB 四写口合并。**§1 中"ROB 128 项 / LSQ / 物理寄存器重命名"原硬指标已解除，可改**；但 4 发射/特权级/Cache/主频等其余指标不变。
- **L1 ✅（commit `ee99f84`，母 Agent 已复跑四套判据全绿）**：`rename.v:57` `LOG_PTR_W` 由 `` `BACK2_RATLOG_N ``(128) 改为 `` `BACK2_RATLOG_PTR_W ``(8)（1 行参数错绑；rb_log/ck_log 位宽 128→8）。重综合实测（`RV32_SYNTH_TAG=2b_l1`，RuntimeOptimized/16.667ns）：**LUT 366,483→292,397（−74,086，−20.22%）、FF 129,899→95,150（−34,749，−26.75%）**；时序 WNS −62.876→−59.844 ns、失败端点 167,410→98,066。**新面积基线 = 292,397 LUT（217.23%）/ 95,150 FF（35.35%）**。
- **ROB 128→64 ✅（L3，commit `5b2e35e`，母 Agent 已复跑四套判据全绿）**：`back2_params.vh`（ROB_N/RATLOG_N 128→64、ROB_IDX_W 7→6、RATLOG_PTR_W 恒 8）+ 全后端年龄算术由 `&7'h7F` 模128 改**模 N 精确年龄序**（含 CSR→load/FP 可见性门：原半分窗启发式在 N=64 下会死锁，改"两侧相对 ROB 头精确年龄比较"）+ `rename.v` rb_* 硬编码 `[0:127]`→`[0:LOG_N-1]` + `tb_back2_iq.sv` 6 个 iq 实例钉 `.ROB_IDX_W(7)`（TB 激励 7bit 硬编码，钉住保原覆盖；集成 6bit 由 lockstep/regress 覆盖，已接受）。重综合（`2b_rob64`，RuntimeOptimized）：**LUT 292,397→256,345（−36,052，−12.33%）、FF 95,150→83,303（−11,847）**；性能无一项跌破阈值（IPC=2.0000、C5 档全高，无需重标定）。**新面积基线 = 256,345 LUT（190.45%）/ 83,303 FF**。
- **LQ 32→16 ✅（L5，commit `b8a2675`，母 Agent 已复跑四套判据全绿）**：`back2_params.vh`（LQ_N 32→16、LQ_IDX_W 5→4、MEM_TAG_W 6→5、RB_LQ_MSB 415→414）+ **nq 窄控制字 4 宏同步**（NQ_W 50→49、MK_L 45→44、SRET 48→47、MRET 49→48；lq 字段在 stq 之上故只下移其上字段）。重综合（`2b_lq16`）：**LUT 256,345→253,748（−2,597，−1.01%）、FF 83,303→80,408（−2,895，−3.48%）**；性能无阈值跌破（IPC=2.0000、C5 档与基线逐位相同）。**★教训：LQ 降深主要省 FF（ld_* 阵列精确减半），LUT 大头在转发/比较 mux、不在深度 ⇒ 后续优先"大 mux 减深/减口/减宽"而非小 mux 降深。新面积基线 = 253,748 LUT（188.52%）/ 80,408 FF。**
- **flist_q 256→128 ✅（L8，commit `0acdb01`，母 Agent 已复跑四套判据全绿）**：`rename.v` flist_q `[0:255]`→`[0:127]`，FL_PTR_W 恒 8、下标截 7bit；功能与基线**逐字节等价**。重综合（`2b_flist`）：**LUT 253,748→239,418（−14,330，−5.65%）、FF 80,408→78,667**（收益全在 u_ren_i/u_ren_f）。**★关键修正教训：大 mux（256:1）降深给超线性 LUT 收益（flist_q 自身 ~17k→~3k），小 mux（32:1）降深只给 FF（LQ −1%）⇒ "降深换 LUT"只在 mux fan-in 大时有效——这反过来印证用户"降深应超线性"的直觉（针对大 mux）。新面积基线 = 239,418 LUT（177.87%）/ 78,667 FF。**
- **进行中：IQ 深度 68→50（C2，子 Agent `1f020d52`）**：`back2_params.vh` 6 个 IQ 深度宏（ALU0/ALU1 16→12、BRU/MDU 8→6、LSU 12→8、FPU 8→6、MAX_D 16→12，总量 68→50，对齐 ROB_N=64 去死容量）；`RV32_SYNTH_TAG=2b_iqdep` 重综合。
- **★组级 ROB 架构提案（用户 2026-10-01）→ 已评估并裁决放弃**：评估报告 `fpga/scratch/group_rob_feasibility.md`——控制层**已是组语义**（blk_mask/lane_fire/cmt_chain/精确异常已实现），只有存储层逐指令；组级化净收益仅 −3~6k LUT（1.3~2.5%），大头（IQ 46-50k/唤醒 11k/PRF 17-22k/LSU 40k/updq 11k）与分组无关。**用户裁决按"方案1"：放弃组级 ROB 重写，只做 D1+D2 两个局部改动摘走主要收益，主线继续消冗余+降宽/降口。**
- **后续串行路线（方案1）**：C2 IQ 深度 68→50（在跑）→ **D1** rb_fhead/rb_log 回滚快照按 4-lane 压缩（rename.v，−3~4k）→ **D2** nq 组不变字段上移（rob.v+params+backend_top，−1.2~1.8k）→ **C3** 唤醒矩阵去 _q 半份+共享位图 → **C1** IQ 304→45bit（−15~25k，最大单条，风险高）→ C6/C9/C7/C4/C8（LSQ 转发/uop 字段裁剪/trq 32→16/RB 载荷裁剪/年龄收敛）。每段改 → 四套判据绿 → 重综合实测 → 母 Agent 复跑验收 → 提交。
- **判据口径（沿用）**：深 = tb_core_top_2b 219/219 + tb_back2_iq 151/151 + tb_back2_lockstep 57/57(821 提交, top=`tb_back2_lockstep_top`) + regress 33/33；RTL 全量列表 = `scripts/env.sh` 的 `rv32_rtl_sources`（58 文件）。综合统一经 `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667`，2B 用 `RV32_SYNTH_TOP=core_top_2b RV32_SYNTH_DIRECTIVE=RuntimeOptimized`。

## 1.6 状态（M4 已收口；M5 上板待用户硬件参与）

## 2. 本会话关键裁决（2026-09-14，用户拍板）

1. 新项目载体 = **就地沿用 `rv32gc-cpu/` dev 分支**（不再另建 rv32gc-cpu-v2/；旧实现文件已从磁盘移除，历史在 master）。
2. 用户已发"开始阶段一"指令：info 复核 → coding 重写 docs/design+porting+kb → 收尾提交 → 停下审阅。
3. 子 Agent 路由（2026-10-01 更新）：`provider` 取 `opencode-go` 或 `opencode-go-chat`（**两者放行**）、`model=deepseek-v4.1-flash`、`reasoning_effort=high`（OpenCode Go 网关；旧 xhigh 与 deepseek-official 口径作废）。

## 3. 平台硬事实快照（info 复核 + 母 Agent 复跑，引用分级见 docs/kb/platform-facts.md）

- `core_top` 例化 `chiplab/chip/soc_demo/loongson/soc_top.v:723`，48 端口；位宽真源 `config.h`（addr32/id4/len4/size3/burst2/lock 只接[0:0]/data32）。平台文档 nscscc_readme.md/Quick-Start.md 的 8bit len 与 [7:0] intrpt 为**过时文档**。
- DDR3 = AXI 默认从设备 0x0–0x07FF_FFFF；XIP 0x1C00_0000（别名 0x1FE8_0000）；无 boot ROM ⇒ RESET_PC=0x1C000000；confreg_sim 0x1FAF_0000 / confreg_syn 0x1FD0_0000 / UART 0x1FE0_01E0 / NAND 0x1FE7_8000(+0x40)。
- **CLINT 0x1F00_0000 / PLIC 0x1F10_0000 未被平台占用但会落 DDR3 默认通路 ⇒ 必须核内截获**。
- 时钟：clk_out1=50 MHz / clk_out2=33 MHz；上板口径 cpu_clk=uncore_clk=33 MHz 同域；config.h FREQ=33。
- `intrpt` 平台只接 [4:0]（`{3'b0,int_out[4:0]}`；int_out={1'b0,dma_int,nand_int,spi_inta_o,uart0_int,mac_int}）。
- **chiplab 工作树 dirty（HEAD a2e11b3）**：modified = soc_top.v（33MHz 补丁）、system_run.xpr、mig_axi_32.xci、axi_clock_converter_0.xcix；untracked = axi_2x1_mux 一批 Vivado 生成物。**处置待用户裁决**（纳入新基线 or 回退）。
- 软件底座：la32r-uboot 用 `RISCV_MMODE/RISCV_SMODE`（**无 RISCV_M_MODE 宏**；SIFIVE_CLINT depends RISCV_MMODE ⇒ S 模式 U-Boot 定时器走 SBI）；la32r-Linux=5.14.0（RISCV_M_MODE default !MMU，S 模式+SBI 路线成立）；opensbi/u-boot(2026.10)/linux(7.3-rc2) 本机可用。
- 分区 `256K(env),50M(kernel)ro,1M(dtb),-(rootfs)` 为**项目自定义约定**（旧 PROMPT.md:86），块对齐核算已通过：2+400+8+614=1024 块精确整除；起址 env 0x0 / kernel 0x40000 / dtb 0x3240000 / rootfs 0x3340000。
- **NAND 几何矛盾（门禁 D1）**："块 128 KiB"与"页 2048+64"不可同时成立；唯一自洽 = 主区 64 页×2048 + 备用 64×64。**D1/D2/D5 未关闭前禁止写 NAND 驱动实现与 UBIFS 参数定稿**。
- 环境：GCC 16.1.0 / Verilator 5.020 / iverilog 12.0 / Vivado 2023.2（坑①证据成立：需 LD_LIBRARY_PATH 前缀 lib/lnx64.o/Rhel/9）。**Spike 无源码无二进制（需重取编译）**；`fpga/run_vivado_batch.sh` 待建。

## 4. ISA 口径（已定版，引用见 docs/kb/isa-notes.md）

T1 mtval 写指令位=可选（本设计选择实现）；T2 取指 PMP 按 memory operation 独立检查、2B-parcel 是本设计选择（非规范强制）、无执行权限报 instruction access fault；T3 非对齐 vs page/access fault 优先级=实现可选（本设计选非对齐优先）；T4 AMO 被 PMP 拒恒 cause 7；T5 陷阱不降级委托、medeleg 逻辑 64 位（RV32 经 medelegh 别名）；T6 中断取点规范未明说（本设计纪律：副作用已落地之后取）；T7 MPRV 按 MPP 语义、xRET 到 <M 清 MPRV；T8 Zicbom rs1 不要求块对齐、CMO 不产生非对齐异常；menvcfg.CBIE/CBCFE 门控 S/U 模式 cbo.*。

## 5. 阶段一审阅裁决（2026-09-14，用户已拍板，全部生效）

1. **chiplab 回退**：已回退干净（HEAD `a2e11b3`，0 dirty；原接线 `clk_out1=cpu_clk`(50M)/`clk_out2=uncore_clk`(33M) 恢复）；不采用旧项目任何修改。
2. **chiplab 可改**：本项目可不受限制地修改 chiplab（按需，含 `soc_top.v`/`intrpt` 扩展）。
3. **CMO block size**（已定）：cbo.clean/flush block=64B（L2 行）、cbo.zero=32B（L1D 行）；设备树属性 `riscv,cbom-block-size`/`riscv,cboz-block-size` 发现；无自定义 CSR。
4. **mtvec/stvec Vectored**（已定）：实现。
5. **NAND**（已定）：无原始资料；以 chiplab RTL（`nand.v`/`apb_dev_top_with_nand.v`）与 la32r-Linux 驱动（`ls1a_nand.c`）为准；**不改 chiplab NAND 模块**；几何口径按"块 128KiB=主区 64 页×2048B，备用区另行"工作。
6. **Spike**（已定）：由用户在沙箱外编译，目标安装路径 `/opt/riscv/bin/spike`；编译命令见 §6；编好后知会母 Agent 记录版本。
7. **PMP 粒度**（已定）：保持 G=0（NA4 可用）；资源允许前提下性能优先，资源告警再议。

## 6. 常用命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu   # 项目仓库（dev 分支）
git log --oneline -3                          # 22ee44e = 阶段0 载体定稿
kb_manage action=reindex                      # 常驻知识库重建（docs/kb 变更后必跑）
node ../dsh-extension/bin/riscv-kb.js search "<词>"   # kb CLI
source /home/shorthair/fpga/Vivado/2023.2/settings64.sh
export LD_LIBRARY_PATH=/home/shorthair/fpga/Vivado/2023.2/lib/lnx64.o/Rhel/9:$LD_LIBRARY_PATH
/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc --version
```

## 6.5 Spike 编译（用户执行，沙箱外；装好后通知母 Agent）

```bash
# 1) 依赖（需 sudo，沙箱内不可用，由用户执行）
sudo apt-get install device-tree-compiler libboost-regex-dev libboost-system-dev

# 2) 取源码（二选一）
# A) 独立仓库（推荐）
git clone https://github.com/riscv-software-src/riscv-isa-sim ~/riscv-isa-sim
cd ~/riscv-isa-sim
# B) 或复用工具链子模块（版本与工具链匹配）
# cd /home/shorthair/dsh/rv32-cpu/riscv-gnu-toolchain && git submodule update --init spike && cd spike

# 3) 编译安装到 /opt/riscv（与工具链同前缀）
mkdir build && cd build
../configure --prefix=/opt/riscv --enable-commitlog
#   若提示不认识 --enable-commitlog（老版本无该选项），去掉它重试
make -j$(nproc)
sudo make install
spike --version     # 预期 /opt/riscv/bin/spike
```

- 验证（可选）：`spike --isa=rv32imafdc_zicsr_zifencei_zicntr_zicbom <elf>`。
- arch-test 官方调用口径：`spike --instructions=100000000 -l --log-commits --log=<trace> --isa=rv32imafd_zicclsm_zicsr_zifencei_zicntr_zaamo_zalrsc`（`--log-commits` 输出在 **stderr**）。
- ✅ **已就绪（2026-09-14）**：`/opt/riscv/bin/spike` 1.1.1-dev，经母 Agent 实测（ISA 串解析、commitlog 走 stderr、`--instructions` 限流、裸 ELF 需 `-m` 映射含头 PT_LOAD）。

## 7. 纪律提醒（对本文件读者）

- **kb 检索环境（2026-09-14 发现，待处理）**：常驻 `kb_search` 的 LSA 语义层已退化（返回无关命中）；`kb_get`（path+行号）与直接 `read` 手册源文件完全正常。已做：CLI `node dsh-extension/bin/riscv-kb.js build --no-lsa` 把磁盘索引重建为纯词法版；**待用户重启 `dsh web` 使常驻进程重载**。重启前子 Agent 查 ISA 细节一律用 `kb_get`/`read`（`riscv-isa-manual/src/**`），不依赖 `kb_search` 排序。
- 母 Agent 只调度；子 Agent 路由 `opencode-go` 或 `opencode-go-chat` 的 `deepseek-v4.1-flash`（2026-10-01 用户裁决：两 provider 并存放行），**reasoning_effort 一律 "high"**（允许由 xhigh 降档）；知识盲区：kb → 联网 → 自试≤3 → 上报。
- **goal 纪律（AGENT.md §0.7，2026-09-17 收紧）**：母 Agent 未在自己 session 运行实质性任务（bash 验证/文件读写）时禁止 create_goal/update_goal resume；派发子 Agent 后结束回合等宿主完成通知（子 Agent 结束自动唤醒母 Agent 交接）；禁止轮询；子 Agent 自驱一次做完；goal 工具仅顶层 Agent 可用。历史 goal（goal-783b30b5）已 paused 且按新规不再 resume。
- 旧项目（master 分支、kb 中 rv32gc-project 来源）只作反面教训，禁止照抄。
- 阶段一结束必须停下等用户审阅后再进阶段二（2A 顺序 5 级基线核）。
