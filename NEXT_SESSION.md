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
- **IQ 深度 68→50 ✅（C2，commit `1df7252`，母 Agent 已复跑四套判据全绿）**：`back2_params.vh` 6 个 IQ 深度宏（12/12/6/6/8/6=50，对齐 ROB_N=64 去死容量），iq.v 仅注释同步（已全参数化）。重综合（`2b_iqdep`）：**LUT 239,418→230,998（−8,420，−3.52%）、FF 78,667→76,281（−2,386）**；性能零退化（IPC=2.0000、C5 档仅 p3_fpu +1 拍）。**新面积基线 = 230,998 LUT（171.62%）/ 76,281 FF。** 遗留：①docs/back2_report 旧深度 16/16/8/8/12/8 待同步；②u_wmem RAMB36 16→20（全核 32→36，打包路径差异，非语义）；③runner 日志固定写 synth.vivado.log 会覆盖基线。
- **进行中：ROB 控制表优化（子 Agent `e31deaaa`）**：①只读实测 win_q/updq/nq 真实 LUT（外部 session 称 win_q 17K，本仓库实测 849 LUT，需钉死）；②分析 upd 4 写口同拍碰撞；③低风险实现 done 位独立 bitmap + 自检 `ifdef` 化（+ win_q>3k 才收窄）；④`2b_robtab` 重综合 + BRAM 迁移评估回报。
- **★组级 ROB 架构提案（用户 2026-10-01）→ 已评估并裁决放弃**：评估报告 `fpga/scratch/group_rob_feasibility.md`——控制层**已是组语义**（blk_mask/lane_fire/cmt_chain/精确异常已实现），只有存储层逐指令；组级化净收益仅 −3~6k LUT（1.3~2.5%），大头（IQ 46-50k/唤醒 11k/PRF 17-22k/LSU 40k/updq 11k）与分组无关。**用户裁决按"方案1"：放弃组级 ROB 重写，只做 D1+D2 两个局部改动摘走主要收益，主线继续消冗余+降宽/降口。**
- **后续串行路线（方案1）**：C2 IQ 深度 68→50（在跑）→ **D1** rb_fhead/rb_log 回滚快照按 4-lane 压缩（rename.v，−3~4k）→ **D2** nq 组不变字段上移（rob.v+params+backend_top，−1.2~1.8k）→ **C3** 唤醒矩阵去 _q 半份+共享位图 → **C1** IQ 304→45bit（−15~25k，最大单条，风险高）→ C6/C9/C7/C4/C8（LSQ 转发/uop 字段裁剪/trq 32→16/RB 载荷裁剪/年龄收敛）。每段改 → 四套判据绿 → 重综合实测 → 母 Agent 复跑验收 → 提交。
- **判据口径（沿用）**：深 = tb_core_top_2b 219/219 + tb_back2_iq 151/151 + tb_back2_lockstep 57/57(821 提交, top=`tb_back2_lockstep_top`) + regress 33/33；RTL 全量列表 = `scripts/env.sh` 的 `rv32_rtl_sources`（58 文件）。综合统一经 `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667`，2B 用 `RV32_SYNTH_TOP=core_top_2b RV32_SYNTH_DIRECTIVE=RuntimeOptimized`。

### 1.5.3 📋 交接存档点 #13（2026-10-01：用户暂停 + 要求总结与可行性方案）

- **状态**：7 个杠杆已落地并全部提交（HEAD `299216e`，工作树干净）：L1 `ee99f84` −74k、L3 ROB64 `5b2e35e` −36k、L5 LQ16 `b8a2675` −2.6k、L8 flist_q `0acdb01` −14.3k、C2 IQ68→50 `1df7252` −8.4k、ROB 表优化（done_bitmap 实测净回归已回退；仅 ifdef 化 `299216e` 面积中性）。**366,483→230,998 LUT（−37.0%，171.62%），FF 129,899→76,281**。全部四套判据绿 + 母 Agent 复跑验收。
- **关键学习**：①大 mux 降深给超线性收益（flist_q 256:1→−81% 自身 LUT），小 mux 降深只给 FF（LQ 32:1→−1%）；②控制层已是组语义（blk_mask/cmt_chain），仅存储层逐指令；③综合已裁未读字段（win_q 822 LUT 非外部估 17K、uop_q 44% FF）；④ROB nq+updq 18.3k 是写口结构死重量（upd 三写口同拍异索引不可合并、done_bitmap 拆出反贵 +1.2k、updq→BRAM 不可取）；⑤RB 载荷 416b 仅 ~126b 被消费、nq 与 uop 重叠 31b。
- **剩余杠杆（估）**：C1 IQ 304→45bit −15~25k（最大单条、风险高、+1 级流水）、C3 唤醒去 _q −3~6k、D1 rb_fhead/rb_log 快照压缩 −3~4k（已 interrupt）、C6 LSQ 转发 −1.5~3k、C9 uop 字段 −1~3k、C7 trq 32→16 −1.5~2k、C4 RB 载荷裁剪 −0.4~0.9k+BRAM、C8 年龄收敛 −0.5~1.5k、updq 读口裁剪 −1.1~2.1k、D2 nq 字段上移 −1.2~1.8k。合计估 **−28~51k ⇒ 落地 ~134-151%，到不了 80% 也到不了 100%**。
- **★根本矛盾（待用户裁决）**：4 发射 OoO 的结构宽度（4-wide 派发 / 16 PRF 读口 / 304bit uop / 6 执行部件 / 6 唤醒口）在 xc7a200t（134,600 LUT）装不下；消冗余+降宽降口只能压到 ~134-151%。要 ≤80%（107,680）需架构降档（4→2 发射等）。恢复口径见 §1.5.2 判据 + 用户后续指令。

### 1.5.4 📋 交接存档点 #14（2026-10-01：采纳 answer.md v0.1 架构，EXP-A 在跑）

- **方向切换**：从"消冗余/降宽/降口"（已落地 7 杠杆 366,483→230,998 LUT=171.62%，到不了 ≤100%）转向**数据驱动的架构重构**。三组动态数据（`docs/design/10-dynamic-behavior.md`，20 基准/49,116 拍）结论：整数 PRF 执行期读峰值 4/11、FP 99.8% 拍为 0、upd 同拍并发≥2 仅 0.02%、rob 峰值 45/64、某 IQ full 而其它空槽 10.28%（主责 MDU/FPU 私有队列）。
- **v0.1 架构（外部 answer.md，gitignore 内；四实验 EXP-A→B→C→D 各独立验证，原则=不改 FU 数/派发/提交宽度只改存储与搬运）**：
  - **EXP-A（在跑，子 Agent `c1f7f3c2`）**：PRF 读口 16/8→**4/2** + `operand_collector.v`（整数 4R 覆盖峰值 4 不加延迟、提交走 in-order commit collector、CSR 消灭 port15、overflow 停拍不丢）；`2b_oc` 重综合。
  - **EXP-B**：ROB `updq`(102b)→BR/FF/EXC 三张 typed 表（每表单写源、删 upd_csr 死口、stale 用 epoch+valid）。
  - **EXP-C**：IQ 6→3 集群（INT30/MLS14/FP6，总 50 不变；分组 selector 6×5+6way）。
  - **EXP-D**：IQ 30/14/6→24/14/6 容量 sweep。
  - 暂不动：ROB 深度 64（48 非 2 幂会牵 age/wrap）、wakeup（v0.3）、LSU、rename、FU。
- **判据（沿用）**：四套判据绿（219/219+iq151+锁步57+regress33）+ IPC/C5（OC 会让 3 源 FMA +1 拍、罕见提交读 +1 拍，按需重标定）+ `RV32_SYNTH_TAG=2b_<exp>` 重综合（RuntimeOptimized/16.667ns）。

- **EXP-A 负结果（已回退，工作树干净）**：PRF 读口 16/8→4/2 + `operand_collector.v` 功能五套判据全绿（219/219+iq151+锁步57+regress34+IPC2.0、cmt_prf_wait 仅 7 拍），但重综合（`2b_oc`）**全核 230,998→277,477（+46,479 LUT，206.15%）**：u_prf_i −11,922(−76.2%)/u_prf_f −4,323(−65.6%)（PRF 读 mux 确为有效杠杆 −16,245）被 **u_oc +19,500（数据路由回 6 槽的变量下标 mux 固有代价）+ 时序驱动反共享 u_ren_f +31,308 + IQ×6 +15,518（oc_rdy 长组合锥）**吞掉。**教训：FPGA 上 operand collector 的固定代价 > mux 省量，此路不通**。已回退（2 新文件存 `fpga/scratch/expA_*`）。另：端口仲裁必须"执行期优先"（提交优先暴露 rename 潜在重复分配 pdi 撞车，记为 blocker）。
- **EXP-B ✅（commit `e90f7fc`，母 Agent 已复跑四套判据全绿）**：`updq`(102b 多写源)→ 三张单写源 typed 表（br_q/ff_q/ex_q，各带 {valid,epoch}），删 `upd_csr` 死口，CSRW 改从载荷 uop.PS1I，merge_upd 回落 br/ff 用常量 0（配 ROB-ASSERT-PAY0 钉前提，避免 BRAM 读位宽假成本）。重综合（`2b_expb`）：**LUT 230,998→224,191（−6,807，−2.95%）、FF 76,281→76,731（+450）、BRAM 不变**；u_rob 42,114→34,133（**−7,981，−18.95%**=消除多写源写 mux 的兑现）；性能零变化（IPC 五档与基线 diff 为空）、时序略好。**新面积基线 = 224,191 LUT（166.56%）/ 76,731 FF。** 遗留：①判据命令用默认 CYC_LIMIT（`-P...1200` 是诊断口径会假失败）；②C5 注释值与实测滞后（HEAD 既有）；③反证 TB 在 repo 外 .b2chk/expb/。
- **EXP-C 负结果（已回退，工作树干净）**：IQ 6→3 集群功能全绿（219/151/57/34/IPC2.0 逐拍一致），但综合（pin 修复前 rename.v）**全核 224,191→226,528 LUT（+2,337）**；IQ_INT 30 项 3 口 +3,576 反涨（读 mux 变 3 份 30:1 + FU 过滤 + 单模块混多 FU 使位裁剪失效）> IQ_MLS −1,723。**EXP-D 不建议做**。**★三实验战略结论：EXP-A 时分(负)/EXP-C 共享(负)/EXP-B 稀疏单写源(正 −6.8k) ⇒ FPGA 上"共享/时分"新增路由代价>省量，"稀疏/减宽/减口"才正解。**
- **C1 ✅（commit `4c7039b`，母 Agent 已复跑四套判据全绿）**：IQ 载荷 304→**40bit** 窄载荷（唤醒 tag/use + 3 发射门控位），宽字段 uop[279:0] 发射拍从新增 4 bank SDP BRAM（u_iwmem，复用 rob_wide_mem 本体）按 rob 索引读回；BRAM 输出寄存器顶替原 x_i2_uop ⇒ **不增加发射级数**（IPC=2.0 不变，锁步仅程序2 +2 拍）。重综合（`2b_c1`）：**LUT 224,191→209,851（−14,340，−6.40%）、FF 76,731→71,424（−5,307）、RAMB36 36→56（+20，仍 15.3%）**。诚实分解：IQ 窄化省 −25,734 LUT/−13,200 FF、读路径新增 +4,667 LUT/+16 RAMB36；读口仲裁冲突仅 0.88%。**新面积基线 = 209,851 LUT（155.91%）/ 71,424 FF。** 遗留：时序 BRAM→交叉开关→PRF 关键锥待拟合后 STA；C4（RB 载荷 416→~200，可再省 RAMB36 + 同步裁 IW_W）。
- **C3 负(收口)/C6/D1/C7/C4+C9/C8/D2（减宽/减口序列收官，HEAD `fd52a73`）**：C3 唤醒去冗余三方向全证伪（比较器锥实测仅 ~1.4k LUT、天花板 ~−0.9k，且在关键路径上）。C6 LSQ 字节转发重写 `c1c3679` **−8,879**；D1 rb 快照组压缩 `a16b77f` **−1,434**（全核≈局部 30%，时序重排吞收益）；C7 trq 32→16 `c4ad505` **−546**；C4+C9 RB 416→229+IW 280→215 `c3db31b` **LUT −488、RAMB36 −12(52→40)**；C8 年龄收敛 `4e29738` **−425**；D2 nq 死字段 `fd52a73` **−874**。**当前基线 = 197,205 LUT（146.51%）/ 68,909 FF / RAMB36 40。累计 366,483→197,205 = −46.2%。**
- **★诚实结论：消冗余/减宽/减口杠杆已基本耗尽**。C3/C4/C8/D2 反复证实审计估计虚高 2-3×（综合早已裁掉未读位/重复比较器），只剩死字段/重复表达式这类 −0.2~0.9k 小额。到 ≤80%（107,680 LUT）还差 **−89,525（−45.4%）**，纯消冗余到不了。**结构性缺口需用户裁决**（4 发射宽度是禁区，当前 147% 已是"消冗余+减宽+稀疏"路线的极限附近）。
- **EXP-R1 ✅（commit `f4a84ce`，母 Agent 复跑四套判据全绿）**：rename log→RAT checkpoint snapshot（改表示）。**LUT 197,205→193,669（−3,536，−1.79%）、FF 68,909→75,128（+6,219，用 FF 余量换 LUT）、回滚延迟 ceil(dist/4)→1 拍**；rename 家族 −2,990（−10.4%）；逐拍等价 + tb_fl S4/S8=0。**★answer.md §一 的 lg_*≈11k+rb_log≈6k 是旧时点，实测日志仅 5,289 LUT ⇒ 该方向天花板 ~5.3k，非 10~20k。** 朴素快照版反 +1,372，靠"lane 门控折叠+组号奇偶分表"转正。**新基线 = 193,669 LUT（143.88%）/ 75,128 FF。**
- **EXP-R 容量数据（commit `3c8a773`，docs/design/11 + 探针×5）**：NREG 96→64 余量薄（max live 整 58）；SQ 32→16 不可（高水位 20）、**LQ 16→8 有余量（高水位 6）**；检查点压缩不可（池满 16）；FPU div/sqrt 不值（占忙拍 51%）。**TRQ 3 bug 坐实**：D1 trq_cnt 双赋值永不递减+指针越界（性能缺陷）、D2 ck_busy_q 位宽、D3 ck_val 无释放。
- **本轮计划完成（改表示路线，HEAD `fb1dfa7`，工作树干净）**：
  - **EXP-R3a**（`20da16e`）：修 TRQ 记账（D1 cnt 双赋值/D1b 指针/D2 ck_busy 位宽）+ **busy 表清零 epoch→在窗**（修 p13 死锁，与 rob.v §5.2 同源）。纯正确性，C5 略好。
  - **EXP-R3b**（`6f3b2c3`）：TRQ 改 4 槽暂存+单写口 FIFO（多写源→单写源），**−2,479 LUT**。
  - **EXP-R3c 负**：TRQ FIFO 16→4 局部 −174 LUT 被全局重映射 +1.5k 吞掉（net +1,392），已回退。**教训：局部 <200 LUT 的小裁剪会被 ~1.4k 重映射噪声淹没。**
  - **LQ 16→8**（`82b7b8c`）：u_lsu −6.3k 被 u_prf_i 重映射吞掉大半，**net −1,002 LUT/−1,481 FF**。
  - **EXP-R2 NREG 96→64**（`fb1dfa7`）：级联减宽（PDW_I 7→6、FREE_I 64→32），**−10,239 LUT（−5.38%）/−2,148 FF**，C5 逐位零退化（64 够用，余量 6 号）。
- **★新基线 = 179,949 LUT（133.69%）/ 71,884 FF。累计 366,483→179,949 = −50.9%。** 到 ≤80%（107,680）仍差 −72,269（−40.2%），结构性缺口依旧（4 发射是禁区）。
- **后续候选（未派）**：type-specific IQ payload（1~4k）、delayed scoreboard wakeup（4~8k）、ROB 64→48（1~5k）、文档口径同步（NREG 96→64 等）。FP div/sqrt / SQ 32→16 / 检查点压缩已被容量数据否决。

### 1.5.5 📋 交接存档点 #16（2026-10-07 用户令上下文压缩；当前进度全量落盘）

- **★当前基线 = 147,472 LUT（109.56%）/ 68,142 FF / 40 RAMB36 / 10 RAMB18 / 23 DSP。累计 366,483→147,472 = −59.8%。HEAD `01594fa`，工作树干净。目标 ≤80%（107,680），仍差 −39,792（−27.0%）。**
- **面积演进全史（commit 级，366,483→147,472）**：L1 −74,086 → ROB64 −36,052 → LQ16 −2,597 → flist_q −14,330 → C2 −8,420 → EXP-B(ROB typed 表) −6,807 → C1(IQ 载荷 304→40) −14,340 → C6(LSQ 转发) −8,879 → D1(rb 快照) −1,434 → C7(trq) −546 → C4+C9(RB/IW) −488 → C8(年龄) −425 → D2(nq) −874 → EXP-R1(RAT 快照) −3,536 → EXP-R3b(TRQ 单写) −2,479 → LQ16→8 −1,002 → NREG 96→64 −10,239 → N1(commit 4→2) −16,022 → flist_q 128→64 −2,093 → N4(PRF 写口 6→4) −3,171(脆弱) → N3(ROB 退休窗 8→2) −2,677 → LSQ age 8→6 −1,875 → N8(FPU add/mul 并入 FMA) −5,679 → N10(np_q 2W bank) −960。
- **★关键教训（反复实证）**：①只有**删完整单元**（N8 FPU −5.7k）或**级联减宽**（NREG −10.2k、commit 4→2 −16k）给持久收益；②**写 mux 收窄 / 局部 <3k 的改动 net≈0 或脆弱**（N4 u_prf_i 自身 +2、N9-② CDQ 净 −349、N10 np_q 43% 被吞）；③"共享/时分复用"反涨（EXP-A collector +46k、EXP-C IQ 6→3 +2.3k、N7 SQ banking 只省 0.4%）；④全局重映射噪声 ~1.4k，局部 <200 LUT 会被吞成负值。
- **★N11 面积归因（只读，`fpga/scratch/area_attrib_n11.md`，HEAD 当前）**：全核 147,472；**独立 LUT 23,627(14.9%) / 共享≥2 cone 134,540(84.9%) / 未归因 377(0.24%) ⇒ 84.9% LUT 在多结构 cone 交集，结构 LUT 数不可当可相减收益**（这是"局部省了全核没降"的根因）。当前真实量级：fwdp_data 已改名 **ld_hd=8,671**（非旧 14.2k）、FMA=6,149（fma_s 2,022+fma_d 4,127）、CVT=3,508、FP-DIV=3,956、np_q=7,684、PRF 读侧 13,720 LUT+8,448 MUXF。匿名>5k cone 1 个=6,524 LUT 100% u_ren_f。**下一个 10k+ 可动排序**：①存储包装 ~20.6k（u_iwmem 12,075+12RAMB36 纯组合 glue + XPM/bank 8,532，唯一 ≥10k 且不耦合 IPC/频率）②匿名云 16.1k ③PRF 读侧 13.7k ④ld_hd 8.7k ⑤d1_uop_q 8,249+nq 6,931 ⑥FSM 4,099 ⑦BPU lht_mem+lru_q 未映射 LUTRAM ⑧DEBUG 1,365(tie-off)。
- **★当前计划（answer.md 最新版 §七，N11 已完，用户令：执行完 N12→N15，中途不询问）**：
  - **N12**（LSQ 保守转发，answer.md §二，最值得先做）：先动态统计（older-store 候选数分布/单条完整覆盖比例/多 store 拼接比例/未定址 load 数），再 A/B 测"单条 store 完整覆盖才转发、其余等排空"——比 banking 更有结构差异；门槛=锁步+回归+memory stress 全绿 + 非对齐/跨 word/部分 mask 全过 + 全核净 LUT 下降 + C5 不跌。
  - **N13**（FPU S/D 共享 + FMA/CVT round-pack 共享，answer.md §三）：A 仅共享控制/后处理（低风险）→ B 共享对齐/规格化（中）→ C 全合并 53bit（高）；每方案独立综合，FMA_d 仅 4.1k 单靠它补不满缺口，无收益就停。N13B=FMA 与 CVT 共享 round/pack（先定位公共逻辑）。
  - **N14**（np_q 存储重构，answer.md §四）：先确定访问语义（每拍写几项/是否需任意异步读/哪些字段参与 wakeup vs 选中后），再试"选择元数据(FF/LUT) + 宽 payload(BRAM/reg)"分离；成功标准=全核净 LUT 降，不是 RAMB 增加。
  - **N15**（PRF 读侧 + SQ 32→24，条件性）：仅当 N11 归因/动态数据支持才做；PRF 读侧必须固定 lane 路径不重做 EXP-A global collector；SQ 32→24 先加 sq_cnt 直方图/满阻塞统计。
  - **Gate 门槛**：B1 147,472→<135,000（需一个大结构净收益）；B2→<120,000；B3→≤107,680。
- **★用户口径（2026-10-04 拍板，最高优先级）**：4 发射 + chiplab/xc7a200t 是底线；前端 4 取指（hard）；后端至少 2 提交/拍（IPC≈2，hard）；**FU 数量/资源占用/时钟频率可改但需用户审阅**。
- **判据口径（每次改动必过，母 Agent 复跑）**：tb_core_top_2b 219/219 + tb_back2_iq 151/151 + tb_back2_lockstep 57 项/提交 821/RENAME-CHK 0/FAIL 0 + regress 33/33；IPC=2.0 + C5 五档（0.3927/0.2472/0.1435/0.0847/0.0593，下限 0.30/0.19/0.1094/0.0625/0.0469）；综合 `RV32_SYNTH_TOP=core_top_2b RV32_SYNTH_TAG=2b_<x> RV32_SYNTH_DIRECTIVE=RuntimeOptimized ./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667`（60MHz，每 tag 标注）。
- **正确性收获（本阶段，比面积更重要）**：rename 回滚取点 pdi 撞车（51a06cf）、PRF busy 表 epoch 死锁（20da16e）、TRQ 三记账缺陷、LSQ 非对齐转发错字（dc36336）、FMUL 零符号（bf7b3e7）。div/sqrt 参数 RV32GC_FDIV/FSQRT_CYCLES=32 是死参数（实际 114 拍位串行），非面积杠杆，文档口径待澄清。
- **遗留**：文档口径滞后（NREG 96→64/nq 49→37/RB 416→229/commit 4→2/FPU 6→2 算术单元）；动态探针 dyn_probe_r 需适配 EXP-R1 后 rename 接口；NREG=64 余量仅 6 号；时序 WNS≈−50ns 深度不收敛。

### 1.5.6 📋 交接存档点 #17（2026-10-15：Gate E 收官 + 三轮审计完成，**迁移下一 session 处置审计发现**）

- **★当前状态**：RTL 冻结在 **`d00eb03`**（工作树干净；文档 HEAD `201d88d` = 总结报告 Gate E 收官版）。**基线 = 126,699 Slice LUT（94.13%，首破器件容量）/ 49,597 FF（18.42%）/ 40 RAMB36 / 6 RAMB18 / 21 DSP / WNS ≈ −52ns**。累计 366,483→126,699 = **−65.43%**；目标 ≤80%（107,680）仍差 **−19,019**。综合证据 `fpga/out/synth_2b_n35b_16.667ns_utilization.rpt`（sha256 `0a7faefe…07e8`）。
- **Gate E 结果（answer.md 2026-10-15 版，净 −11,894）**：采纳 4 —— N33B div/sqrt 收尾舍入对并入 u_fma −1,712（`08a06ad`）、N34B-1 LHT 写口脱异步复位改 LUTRAM −5,627/−10,289FF（`1c2e0bd`）、N34B-3 同根因 5 阵全修 −2,085/−4,856FF（`8d98117`）、N35B ROB 窄表 nq 36→16 −2,470/−1,252FF + WNS +2.72ns（`d00eb03`）；关闭 3 —— N32 CVT 共享（净上界 1,299~1,458 < 门槛）、N28 ROB 64→48（fail-closed）、N34B-2 LOCAL 删除（净 −915 < 门槛，**patch 留档**）。
- **★★本轮新增：三轮审计已完成（用户 2026-10-15 指令；全程 RTL 零改动，报告与 RTL 逐条行号对应）**：
  - **审计① 模块耦合度** → `fpga/scratch/audit1_report.md`（382 行）+ `audit1_check.sh`（46/46 → `AUDIT1: PASS`）。**用户关切成立且只有后端**：`rtl/back2/backend_top.v` **2813 行/116 端口/20 always/270 assign/108 function**，承载 14 编号段 + 1 未编号段；§4(888–1199) 混 6 职能、§9(1873–2190) 混 7 职能、§13 单 always 133 行混 6+ 职能；**对照 `front4_top.v` 端口 112（近等）却只有 1 always+7 assign，行/端口密度 3.2 vs backend_top 24.2（7.6 倍）**。跨模块重复 **10 组（D1–D10）**：同一 uop **6 套位域布局（197 宏）**、`fp_op_map/fp_cvt_map` 在 `core_top.v:496/517` 与 `backend_top.v:394/410` **各一份**、4-bank 写口轮转公式 `rob.v:364` vs `backend_top.v:1411` 自陈同式、`p_*` 95 个访问函数。建议 8 条（F1–F8）**预估净 −0~−350 LUT ⇒ 达不到面积门槛，拆分价值在可维护性，不要为面积做拆分**。高危提醒：`p_*` 函数签名被 `tb_back2_lockstep.sv` 按层次名冻结（`backend_top.v:277-278` 明文"名字与签名不得改"）；D9（IQ 入队许可双实现）有**静默丢项**风险且无断言保护。
  - **审计② ISA 语义审查（未用 Spike）** → `fpga/scratch/audit2_report.md`（五节齐：26 条指令三态表/差异/未涵盖/排除/复现）+ `audit2_gate.sh`（`AUDIT2: PASS`）+ 实证夹具 `audit2_lsq_mis_tb.sv`。**8 条确定差异**：
    - **D1【严重·最高优先】2B 核 ≤4B 非对齐 store 静默丢跨字字节且不抛异常**：`rtl/back2/lsq_simple.v:413-415`（4bit 掩码截断）/`:1225`（左移 a2 后高位丢失）/`:1230`/`:1007`（`st_mis_w` 只覆盖 size==3）/`:1119-1132`（仅 8B 有第二条 CDQ）；ISA `unpriv/rv32.adoc:640-767` 允许"完成或抛异常"但**不允许部分落地不报异常**。**实测**：`sw@+1 → addr=0x80001001 wdata=0xbbccdd00 wstrb=1110`，`mem[+4]` 应 `0x556677aa` 实为 `0x55667788`；`sh@+3 → wstrb=1000` 同样丢字节。**arch-test 树内零 misalign 用例 ⇒ 回归不能自证**。修法二选一：`st_mis_w` 放宽到任意非对齐⇒cause 6；或复用 8B 两条 CDQ 拆高半字（建议，保持硬件完成）。
    - D2【中】S 级中断在 U 模式被 SIE 误掩蔽（`rtl/csr/trap_ctrl.v:178-186`；ISA `priv/supervisor.adoc:366-489`）→ 改 `(cur_priv==U)?1'b1:SIE`。
    - D3【中】`pmpcfg[i].L=1` 时 `pmpaddr[i]` 仍可写（`csr_file.v:489-498/535-548`；ISA `machine.adoc:3542-3563`）→ `pmp_tor_locked` 并入本项 `cfg[i].L`。
    - D4【中】`mcounteren/scounteren` 门控**完全缺失**（`dec_csr.v:98-103/174-194` 无该输入；`csr_file.v:745` 注释却称已处理，`core_top_2b.v:1519` 输出悬空；ISA/arch-test `ZicntrU.yaml:23-29`）。
    - D5【中】`mstatus.TVM` 未强制（`core_top.v:1423-1426` 自述不实现，`priv_ctrl.v:253` 有 `tvm_o` 无消费者）。
    - D6【低】mtvec/stvec MODE=1 对齐不一致：写路径 `csr_file.v:464-470` 只清低 2 位、trap 路径 `trap_ctrl.v:270` 清低 8 位 ⇒ **读回值≠实际向量基址**。
    - D7【低/中】2B `misa.A=1`（`csr_file.v:733-741`）但 `backend_top.v:740-741/755` 把 AMO/LR/SC（opt==5）连同 wfi 判 cause 2 ⇒ 需架构裁决（按核分档 misa 或登记 2B 里程碑不含 A/WFI）；注意 arch-test/lockstep 实际 DUT 是 **2A** `core_top.v`。
    - D8【低】文档/真源不一致：`alu.v` 头注称 ALU 编码真源在 pkg 但 pkg 无 `ALU_*`（真源 `decoder.v:130-141`，ALU_AUIPC=11 死编码）；`back2_params.vh:615-616` 注释称非对齐不产生 cause 但 `lsq_simple:1012-1013` 确实产生；`bru.v:137` 未按 `is_ctl` 门控 `bru_act_tk`（当前靠下游门控）。
    - **已排除（逐条留行号，无差异）**：ALU 12 运算、BRU、MDU 除零/溢出/mulh 三 signedness、dec_imm、非对齐 ≤4B **load** 跨字、PMP 匹配/优先级/TOR/NAPOT、PTW Sv32 全路径、sfence.vma/fence.i、Zicbom CBIE/CBCFE、CSR 读写权限与 cause 码表、mstatus 陷阱/xRET 位序、Vectored pc、FPU（tb_fpu 3441/0，KNOWN_DEV=0）。
    - **另建议另派**：U3/U4（2B 的 A/WFI）、U5（RVC 立即数未逐条对 `zca.adoc`）。
  - **审计③ 代码质量** → `fpga/scratch/audit3_report.md`（403 行，**126 条**：A 死转移 40 / B 不必要判断 22 / C 死代码 44 / D 风格 20）+ `audit3_check.py`（`AUDIT3: PASS`）。**38 条可回购清单**：§6-1 零影响 28 条可立即删/改（25 个无消费顶层网、35 个未用 param、死寄存器 `ck_ghr_q[0..15]`/`ck_alloc_q`/`ck_fhead`/`ck_log`/`ck_val`/`all_valid_reg`/`fill_idx_reg`/`fpu_fma_shared.v:476 r2_prod[47:17]`、补 `core_top_2b.v:114 wid` 驱动、**修 `front4_top.v:140 ras_repair_addr` 真缺陷**——`front4_top.v:266` 接到了另一个内部网 `ras_repair_addr_w(:218)` ⇒ 该 output 端口整条悬空）；§6-2 需实测 4 条（`rename.v:422` **两个 latch**、`rename.v:303-315` 同构算式去重、19 处同周期重复拼接、26 处 RAM 落 reg）；§6-3 正确性/时序优先 6 条（`backend_top.v:2149-2151` `$display` 格式 8 `%` 只 7 实参、46 处位宽不匹配、80 处 Set/Reset 同优先级、17 处时序环 + 10 处推断 false path、`core_top_2b.v:71` aresetn 同步/异步混用、修复失效 lint 指令）。**无显式 A→B→A 反绕环**；`pend_sel`（`lsq_simple.v:743-745`）是 TB 诊断别名**删前须同步 TB**。**工具基建**：rtl 中 **17 文件 41 处行注释含裸词 `Verilator`** ⇒ Verilator 5.020 整库无法直接 lint；**17 处 `/* verilator … */` 写成 `/*` 后有空格** ⇒ lint 指令全部失效，`plic.v:153-154` 注释宣称已静默是**假证据**；lint 需在净化镜像上做（已在报告 §8 声明）。
  - **审计产物均在 `fpga/scratch/`（.gitignore 内，未提交）**：`audit1_report.md`/`audit1_check.sh`/`audit2_report.md`/`audit2_gate.sh`/`audit2_lsq_mis_tb.sv`/`audit3_report.md`/`audit3_check.py`。若需进版本库须 `git add -f`。
- **★下一 session 待办（按优先级）**：
  1. **D1 修复**（严重功能性缺陷；2B 若取代 2A 上板即为缺陷；建议最高优先，含"回归不能自证"的定向夹具 `audit2_lsq_mis_tb.sv` 可复用）。
  2. **审计发现处置裁决**：AUDIT2 的 D2–D8、AUDIT3 §6-1 零影响批次（28 条，可一次清理）、§6-3 正确性/时序项（R-33/R-34/R-35 建议单独立项）。**均为"审计→修复"性质，须用户决定是否派活**；注意 D7 需架构裁决、AUDIT1 的 F1–F8 若做须先接受"不为面积"。
  3. **送审池（用户裁决，均未实施）**：①`N34B-2` LOCAL 删除 patch（−915 LUT + BRAM Tile −2 + IPC/C5 无退化，但**与 `AGENT.md §1`"锦标赛预测器（Gshare+局部+选择器）"硬指标冲突**、`04-predictor.md §3.1/3.2` 是被删模块规格，须需求裁决 + 文档修订；`git apply fpga/scratch/n34b2_rtl_and_tb.patch`）；②`AreaOptimized_medium` 配方（Gate C 实测 −13,959，代价 WNS −5.936ns）；③K1 读口折叠（−1,249，patch `n21b_k1_rtl.patch`）。
  4. **下一批面积候选（未启动）**：①**win_idx 加 epoch 位**（N35B 新发现：影子自检 300k 拍报 3 次"提交 lane 窗口载荷≠派发载荷"cyc 94,486/123,246/254,759，既有设计对该窗口的信任缺口；比继续删 nq 更高价值）；②N29B 精确阻塞掩码（长尾治理，面积中性）；③CDQ/StQDH 9 写口串行化重构（清零 26 条 `8-4767` multiple-writes，属结构性立项）；④NREG↔ROB 深度解耦（N28A 建议独立）；⑤CVT 四 rounder 的 OOC 校准（N32A 上端距门槛仅 42 LUT/2.8%，若用户愿接受 OOC 探针）。
  5. **文档口径同步（陈旧清单）**：`rtl/front4/README.md`（结构图/模块表/选择器不变量/准确率表/反证实验/IP 表 5 段）、`docs/design/04-predictor.md`、`rtl/back2/rob_wide_mem.v:22` 注释、`lsq_simple.v:775` 仍称"同拍最多 4 条 store 提交"（`COMMIT_W` 实为 2）、NREG 96→64 / nq 49→16 / RB 416→225 / commit 4→2 / FPU 6→1 算术单元 / PRF 读口 11/5 / 转发已移除 / 六阵 LUTRAM 等。
  6. **未跑项**：arch-test 接入 2B（估算 2~3.5 人日，`sim/arch_test/run.sh:503` 硬编码 2A + `sim/tb/tb_arch_test.sv:209` 例化 `core_top`）、post-route 时序签署（WNS ≈ −52ns 深度不收敛）、`8-6014`/`8-7129` 100 条疑为 Vivado 类别上限（真实 dead FF 规模更大，需只读复跑放开上限）、`8-689` 46 处位宽不匹配逐条核实。
- **★环境事实（本 session 实测，下一 session 注意）**：① **`kb_search`/`kb_get`/`kb_manage` 扩展本 session 不可用**（索引根误解析到 `/home/shorthair/.dsh/profiles/web/node_modules`），改走同库 CLI `node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search|get "<关键词>"`（同 store/ranking，带 path:行号）——**下一 session 若 skill 恢复则直接用 skill**；② **n35b 的综合日志真源是 `fpga/out/n35b_synth_run.log`**（`synth_2b_n35b_16.667ns.vivado.log` **不存在**，滚动日志会被覆盖）；③ **LUTRAM 纪律（本轮 6 阵教训）**：可推断分布式 RAM 的阵列，其写口**必须独立于带异步复位的 always 块**（否则 `[Synth 8-4767]` 整表 dissolved 成 FF+读 mux）；而 `8-4767` 的 `multiple writes via different ports`（CDQ/StQDH）是**写口数**问题，搬进程无效；④ 夹具伪随机**统一用规范 xorshift32**（`n34b1_diff_tb.sv` 的"三次左移"变体低 7 位恒定，低位使能激励会退化）；⑤ 逐拍对拍须只在可观测拍比较（FPU 空闲拍 `result` 是 don't-care）；⑥ rebuilt 网表跨容器 `get_pins -of_objects <net>`、`all_fanout -from <RAMB DO>` 不可信，读块边界输出边须 `get_property DIRECTION`。
- **判据口径（无变化，每次改动必过，母 Agent 复跑）**：`tb_core_top_2b` 219/219 + `tb_back2_iq` 151/151 + `tb_back2_lockstep` 57 项/提交 821/FAIL 0 + `./scripts/regress.sh` 33/33；`tb_back2_ipc` IPC=2.0000；C5 五档基线 0.3927/0.2472/**0.1430**/0.0847/0.0593，下限 0.30/0.19/0.1094/0.0625/0.0469；综合 `RV32_SYNTH_TOP=core_top_2b RV32_SYNTH_TAG=2b_<x> RV32_SYNTH_DIRECTIVE=RuntimeOptimized ./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667`；面积只认全核官方 Slice LUT（门槛 ≥1,500），每个采纳实验须同树基线复跑钉死非随机。

## 1.6 状态（M4 已收口；M5 上板待用户硬件参与）

## 2. 本会话关键裁决（2026-09-14，用户拍板）

1. 新项目载体 = **就地沿用 `rv32gc-cpu/` dev 分支**（不再另建 rv32gc-cpu-v2/；旧实现文件已从磁盘移除，历史在 master）。
2. 用户已发"开始阶段一"指令：info 复核 → coding 重写 docs/design+porting+kb → 收尾提交 → 停下审阅。
3. 子 Agent 路由（2026-10-01 更新）：`provider` 取 `opencode-go` 或 `opencode-go-chat`（**两者放行**）、`model=deepseek-v4.1-flash`、`reasoning_effort=high`（OpenCode Go 网关；旧 xhigh 与 deepseek-official 口径作废）。
4. **★任务要求口径更新（2026-10-04 用户拍板，覆盖此前"4 发射是禁区"）**：**4 发射 + 目标平台（chiplab, xc7a200t）是底线、不允许改**。具体：**前端一次取 4 条指令（hard）；后端至少支持一次提交 2 条指令，即底线 IPC 在 2 附近（hard）**。其余（FU 数量、资源占用率、时钟频率等）**可改，但需经用户审阅后再改**。⇒ 后端可从"4-wide 提交 + 6 FU"降为"4-fetch / 2-commit / 更少 FU"，这是关闭 133.69%→80% 结构缺口的关键路径；但 FU 数量/频率改动必须先报用户审阅。
5. **总结性 report 固定内容（2026-10-04，下次提"总结性 report"即照此、勿再声明）**：①项目当前大概状况（架构/技术/资源占用率，快速获取整体框架）；②目前主要问题与成因（详细 + **原始数据印证，禁止编造/夸大或减小**）；③可能的解决方案与优化路径（简写方向）；④其他补充信息。**一律写在同一个 md（`fpga/area-optimization-report.md`）上修改，禁止新建 md。**

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
