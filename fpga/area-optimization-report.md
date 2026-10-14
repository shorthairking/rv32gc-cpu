# RV32GC 2B 乱序核 —— 总结性报告

> 本文件是**唯一**的"总结性报告"落点（用户约定：每次更新都在此文件修改，不新建 md）。
> 固定四部分：① 项目当前状况 → ② 主要问题与成因 → ③ 解决方案与优化路径 → ④ 补充信息。
> 数据均为实测原始值，随综合 tag/commit 可复现，禁止编造或夸大/缩小。
> 更新日期：2026-10-07

---

## ① 项目当前状况（架构 / 技术 / 资源）

### 1.1 一句话定位

一个面向 **chiplab / xc7a200t** 的 **RV32GC 4-发射乱序（OoO）处理器**（项目内代号 2B），当前处于**后端面积优化**阶段：已从 366,483 LUT（272.28%）压到 **143,992 LUT（106.98%）**，目标 ≤80%（107,680 LUT）。

### 1.2 架构（微架构框架）

```
front4 前端（4 宽取指/译码 + 分支预测 + I-Cache + fetch）
   │  一次取 4 条指令（用户底线，不允许改）
   ▼
back2 后端（乱序执行）
   ├ rename ×2（整数/浮点分离；RAT + checkpoint RAT 快照 + free-list）
   ├ 6 个分布式发射队列 IQ（ALU0/ALU1=12、BRU=6、MDU=6、LSU=8、FPU=6）
   ├ 整数 PRF 64×32（6 读口/4 写口）+ 浮点 PRF 64×64（2 写口）
   ├ ROB 64 项（宽载荷入 4-bank SDP BRAM + 2-entry 退休窗）
   ├ LSQ：SQ 32 / LQ 8（store→load 字节转发）
   └ 6 个执行部件：ALU0 / ALU1 / BRU / MDU / LSU / FPU
   ▼
2 宽提交（2-wide commit，4-issue ≠ 4-commit）→ 分支训练（trq，单写口 FIFO）
```

- 关键结构参数（当前 HEAD `cabd7fa`）：整数物理寄存器 **NREG_I=64**（PDW_I=6bit）、浮点 64（6bit）、ROB 64、SQ 32、LQ 8、IQ 总容量 50（np_q 已 2W bank）、checkpoint 16、**commit 2-wide（分配仍 4-wide）**、free-list FL_DEPTH=64、**FPU 已把 add/mul 并入 FMA（只剩 FMA+cvt+div/sqrt+cmp）**。
- 流水线：前端 4 宽取指 → rename（4 宽分配）→ IQ 唤醒/选择（4-wide issue）→ 发射 → 执行 → 写回（4 写口）→ **2 宽提交**。

### 1.3 使用技术

| 层 | 技术 |
|---|---|
| RTL | SystemVerilog（组合逻辑用 `assign`/`function`，`always` 仅时序），参数化宏布局真源 `back2_params.vh` |
| 仿真 | iverilog 12.0（`rv32_rtl_sources` 58 文件全量编译）+ 锁步比对 Spike 黄金 |
| 综合 | Vivado 2023.2 batch（`run_vivado_batch.sh` 统一入口；**RuntimeOptimized** 配方，16.667ns/60MHz） |
| 平台 | chiplab 龙芯实验箱，xc7a200tfbg676-2，DDR3 AXI + XIP + confreg |
| IP | mult/div（Vivado IP，仿真行为模型双分支）；BRAM 用 XPM/rob_wide_mem 行为模型 |

### 1.4 资源占用率（当前，`synth_2b_n15_16.667ns_utilization.rpt`）

| 资源 | 占用 | 器件 | 百分比 |
|---|---:|---:|---:|
| **Slice LUTs** | **143,992** | 134,600 | **106.98%**（目标 80%） |
| Slice Registers | 68,170 | 269,200 | 25.32% |
| RAMB36 | 40 | 365 | 10.96% |
| RAMB18 | 10 | 730 | 1.37% |
| DSP48E1 | 23 | 740 | 3.11% |

**资源特征**：**LUT 仍是唯一超标的资源**（115.89%，从 133.69% 进一步下降）；FF/BRAM/DSP 有大量余量。这是"用 FF/BRAM 换 LUT"路线的物理基础。

---

## ② 主要问题与成因

### 2.1 核心问题：LUT 超 80% 目标，剩余缺口靠"结构宽度"

**事实**：当前 143,992 LUT = 106.98%，到 ≤80%（107,680 LUT）仍差 **−36,312 LUT（−25.2%）**。

**成因（用数据印证）**：

**(a) 结构级面积归因（`fpga/scratch/area_attrib_nreg.md`，信号名口径 raw LUT）**：

| 结构 | LUT | 占比 |
|---|---:|---:|
| LSQ | 39,939 | 20.4% |
| FU | 34,021 | 17.4% |
| IQ×6 | 25,704 | 13.1% |
| rename | 13,886 | 7.1% |
| ROB | 11,335 | 5.8% |
| free-list | 8,623 | 4.4% |

- **WRITEBACK = COMMIT = 0 LUT（"有网无 cell"）**：写回/提交组合逻辑已被折叠进 PRF 写口 / nq·win_q / 匿名锥，**不存在可单独砍的 writeback/commit 结构**（这正是 commit 4→2 单靠"参数改"收益小的原因）。
- 10k+ 单结构：`np_q` 14,710、`fwdp_data` 14,160、`LSU_CDQ` 11,314、rename RAT 12,282、ROB 11,335、`d1_uop_q` 8,138。

**(b) "共享/时分复用"会新增路由代价，反超存储省量（两个铁证）**：

| 实验 | 方向 | 实测净 | 结论 |
|---|---|---|---|
| EXP-A PRF 读口 16/8→4/2 + Operand Collector | 时分复用 | **+46,479 LUT** | 负（已回退） |
| EXP-C IQ 6→3 集群 | 共享存储 | **+2,337 LUT** | 负（已回退） |

**(c) "全局重映射噪声"会吞掉小杠杆（反复出现）**：D1 局部 −4,835 全核仅 −1,434；EXP-R3c 局部 −174 全核 **+1,392**；N4 写口 6→4 的 −3,171 **归因不明（`u_prf_i` 自身 +2，省量在未动的 `fpu_div_sqrt` −6,162）**。⇒ 局部 <200 LUT 的裁剪会被 ~1.4k 重映射噪声淹没；小杠杆的净收益"脆弱"。

### 2.2 堵点：剩余 10k+ 结构都是"硬"杠杆

- 已被容量数据否决：SQ 32→16（高水位 20）、检查点压缩 ≤4（池满 16）、FPU iterative div/sqrt（占忙拍 51%）、N5 IQ 合并（FPU/MDU max occ 6、ALU0+ALU1 在 ipc_alu4w 合并 22>12）。
- 剩余 10k+ 结构：**FU_FPU 21k（FPU 数据通路）、np_q 14.7k（IQ 窄队列 4 写口）、fwdp_data 14k（LSQ 字节转发）**——都不是简单多写 mux，是复杂数据通路/转发结构。

**结论（有数据支撑）**：结构宽度重构（commit 4→2、ROB 窗 8→2、写口 6→4、free-list 128→64）+ 数据通路压缩（FPU add/mul 并入 FMA、np_q 2W bank）已拿到 −59.8%，但到 80% 还需动"FPU D 路径 FMA_d（S/D 去复制，53bit 宽度难）" / "fwdp_data（banking 已负）" 这类硬结构，其中 FU 数量/频率改动需用户审阅。**反复实证：只有删完整单元（N8 FPU）或级联减宽（NREG）给持久收益，写 mux 收窄/局部 <3k 的改动 net≈0 或脆弱。**

---

## ③ 可能的解决方案与优化路径

**最新口径（2026-10-04 用户拍板）**：
> 4 发射 + chiplab/xc7a200t 是底线；前端一次取 4 条指令（hard）；**后端至少一次提交 2 条指令，即底线 IPC ≈ 2**（hard）；**FU 数量、资源占用率、时钟频率可改，但需用户审阅**。

已按此完成的**结构宽度重构**（Gate A 阶段，answer.md §十六）：
- **N1 commit 4→2**（−16,022 LUT）：ALLOC_W=4/COMMIT_W=2 两真源分离，退休选择/free-list 回收/架构更新全 2 宽，IPC=2.0 未伤。
- **N3 ROB 退休窗 8→2**（−2,677 LUT）：提交读零 mux，win_q 2125→234 LUT。
- **N4 PRF 写口 6→4**（−3,171 LUT，归因脆弱）：ALU0/1/BRU 直连 + LSU>MDU>FPU 共享口。
- **flist_q 128→64**（−2,093 LUT）：2× 余量裁剪。
- N2 BRU merge 砍掉（FU_ALU=FU_BRU=0 无面积靶子）。

**已完成的"数据通路压缩"（answer.md §十六-十七，N6-N10）**：
- **N8 FADD/FSUB/FMUL 并入 FMA**（−5,679 LUT/−2,190 FF/−11 DSP）：删 4 个完整单元（add_s/add_d/mul_s/mul_d），真实结构删减；FMUL 零符号用 `c=±0 且符号=积符号`（IEEE 乘法零符号恒=操作数符号异或，FMA 零和才受 rm 影响）。
- **N10 np_q 写口 4W→2×2W bank**（−960 LUT）：均衡直写+余量背压，43% 局部被重挂吞。
- N7 SQ banking 负（关闭）：banking 只改树分组、不减叶子，动态候选削减≠LUT。
- N9 LSU_CDQ 归因：是提交排空 FIFO（非 CAM），N1 已降到 6.3k；②"1 入队"负（net −349 落噪声带）。
- div/sqrt：非面积杠杆（114 拍=位串行最小，参数 32 是死参数，修快反加面积）。

**已完成的"Gate B 数据通路压缩"（answer.md §七，N11-N15）**：
- **N11 面积归因重建**（只读）：独立 LUT 23,627（14.9%）/共享≥2 cone 134,540（84.9%）/未归因 377 ⇒ **84.9% LUT 在多结构 cone 交集，结构 LUT 数不可当可相减收益**（"局部省了全核没降"的根因）。
- **N12A/N12-stress + 两处正确性修复**（净 −612 LUT）：非对齐 load 全转发写回值字节错位（`e66241d`）+ ≤4B 非对齐跨 4B 字边界访存缺口（`0a4b178`，复用 8B 两拍机制）。
- **N15 PRF 读口 16/8→11/5**（−2,868 LUT，本轮最大正收益）：3 组"零冲突固定 2:1 合并"（ALU1∪MDU、LSU存数据∪FPU整数源、FPU c∪LSU浮点存数据），只加 6bit 地址 mux、无全局 crossbar；动态 20 程序 49,116 拍 0 冲突、IPC 无损失。
- N12B 保守转发负（回退）：删了逐字节合并树（ld_hd 8.7k→0）但被"胜者 32:1 数据 mux"抵消，net ≈0。
- N13A FMA S/D 控制共享无靶子（控制仅 60/102 LUT）；N14 np_q BRAM 停（1,900bit 太小、单写口、读侧 mux 不减）。

**后续方向（都需先报用户审阅 FU/频率，或属高复杂度）**：
本轮（N16A-N18 + N15-stress）已对上一版"后续方向"逐项实测并**三连否证**，修正如下：

1. **存储包装"20.6k"→ 已否证（N16A）**：u_iwmem/u_xpm/g_bank.u_sdp 三个标签名义 20,505 raw LUT，但**真实 XPM 包装逻辑仅 21 LUT**；其余 99.5% 是 `flatten_hierarchy=rebuilt` 的改挂/重名 artifact（glue 真源 = backend_top 的 iwm_arb + x_i2_uop 4:1×6 交叉开关、rob.v 的窗口/同址保护/填充 mux、BTB lru_q、LPHT 读 mux）。三对象 RAM inference 干净 8/8→BRAM。剩余把手（载荷去重撞读口带宽 / RAMB 超配只省 BRAM / 前端双副本 IPC 敏感）都不指向 LUT 收益。**附带发现语义风险**：综合日志 17 条 `rw_addr_collision=no` ⇒ 综合用 NO_CHANGE 而 RTL/iverilog 是 read_first，同址同拍读写语义分叉（未证假设，建议后续定向一致性检查）。
2. **匿名云"16.1k / 最大锥 6,524"→ 已否证（N17）**：u_ren_f 匿名桶 11,184 raw 中最大连通分量 3,091 LUT **不是 rename 的 RAT/回滚/free-list**，而是 **dispatch（D1 派发寄存器+队列写控制）→ IQ 入队的匿名胶合云**（类别独占：dispatch/IQ 649、checkpoint 13、free-list 2、RAT 0）；`u_ren_f` 本身是 rebuilt 重分区桶（10,960 自动端脚，非 rename 语义边界）。不据此重构 rename。
3. **唤醒矩阵"3.4k"→ 已否证可共享性（N18）**：rdy_q D 锥实测 **4,220 唯一 LUT**（6 队列 1177/1213/410/410/614/396），比较器本体仅 2,591；**无跨源公共子项**（硬反证：无任何 LUT 读入 >3 载荷字段位）；综合器已裁 40%（1,200/3,000 常量传播）；未裁死列 874 LUT < 1.5k 验收线且需改 backend_top（超范围）；且比较锥在关键路径带上（IQ D 端点最差 slack −50.115ns，仅比 WNS 好 2ns）⇒ 加组合深度的省法不划算。位图/标签预译码方向 C3 早已实测 +47% LUT 且 lockstep 失败。
4. **FMA D 路径 → 按 answer.md §五条件冻结（N19 不启动）**：②"可独立拆分/共享的运算阶段"不成立（N13A：可共享派生标志仅 15/15 LUT，净 −6 反涨）；③"明确 LUT/DSP 迁移机会"不成立（乘法已用 DSP；加宽 mux/控制级反扩结构）。
5. **N15 读口合并性能边界 → 已补测（N15-stress）**：定向压力下让位确实触发但**实测 0%~2.67% ≤ 结构性上界 min(两 lane 发射率)=9.95%**（mixed y5=8/1.99%、store 突发 2.67%/最长连续 7 拍、mdu 口 y3=38/7.39%、**现实 RAW 相关负载 0 让位**）；1278 条提交 vs Spike 黄金 0 分歧、FP store 逐字节 0 分歧 ⇒ **N15 无隐藏性能退化，确认保留**。已知夹具级坑：fmadd/fcvt 默认编成 DYN 舍入会导致 FPU 被迫 ROB 头发射（须显式 rne）；iverilog 在 STQ/LQ 近满时吞吐崩塌 >100×（LSU 持续饱和极端工况无法仿真，为已知仿真限制而非 RTL 缺陷）。

下一轮若继续压缩面积，真实剩余靶子（当前口径 raw 155,509）需以唯一 cell 归因重新筛选：`mem` 桶 13,061、`fwdp_data`/`ld_hd` 8,850（N12B 已证"胜者 mux 抵消"，需新表示）、以及 6 个 IQ 桶 + u_ren_i 的匿名分量（约 6k）。

---

## ④ 补充信息

1. **本阶段正确性收获（比面积更重要）**：
   - rename 回滚取点错位（在飞两指令同 pdi 撞车）——已修。
   - PRF busy 表清零用全局 epoch 导致的死锁（与 rob.v §5.2 同源）——已修（被 TRQ 垃圾训练掩盖）。
   - TRQ 三处记账缺陷——已修，预测器训练数据从"近半垃圾"变正确。
   - LSQ 非 8B 对齐 load 命中错字的转发缺陷——已修（commit 2 宽拉长 store 存活期后暴露）。
   - LSQ 非对齐 load 全转发写回值字节错位（`e66241d`）：`ext_load` 取数前右移 a2 字节 + 转发改用完整 64bit 窗口——已修。
   - ≤4B 非对齐 load 跨 4B 字边界访存缺口（`0a4b178`）：复用 8B 两拍机制取齐两个字——已修。
2. **验证纪律**：`tb_core_top_2b` 219/219 + `tb_back2_iq` 151/151 + `tb_back2_lockstep` 57/57（提交 821）+ `regress.sh` 33/33；IPC=2.0 + C5 五档；逐拍等价；重综合 tag 命名；N15 读口合并配 20 程序 49,116 拍动态冲突统计 + N15-stress 定向压力（5 负载 1278 条提交 vs Spike 黄金 0 分歧）。
3. **面积演进全史**（commit 级）：366,483 → L1 −74,086 → ROB64 −36,052 → LQ16 −2,597 → flist_q −14,330 → C2 −8,420 → EXP-B −6,807 → C1 −14,340 → C6 −8,879 → D1 −1,434 → C7 −546 → C4+C9 −488 → C8 −425 → D2 −874 → EXP-R1 −3,536 → EXP-R3b −2,479 → LQ16→8 −1,002 → NREG −10,239 → **N1 −16,022 → flist_q(128→64) −2,093 → N4 −3,171 → N3 −2,677 → LSQ age 8→6 −1,875 → N8 FPU 并入 FMA −5,679 → N10 np_q 2W bank −960 → 非对齐/跨字修复 −612 → N15 PRF 读口 −2,868** = **143,992**（累计 −60.7%）。
4. **已知遗留**：设计文档口径滞后（NREG 96→64、nq 49→37、RB 416→229、commit 4→2、FPU 6→2 算术单元、PRF 读口 16/8→11/5 等未同步）；动态探针 `dyn_probe_r` 需适配 EXP-R1 后的 rename 接口；NREG=64 余量仅 6 个物理号；时序 WNS≈−52ns（107% 下仍深度不收敛，拟合后需重点 STA）；div/sqrt 参数 `RV32GC_FDIV/FSQRT_CYCLES=32` 是死参数（实际 114 拍），文档口径待澄清；N15 读口合并的让位规则上界 min(两 lane 发射率)（本负载集实测 0，FP 存+FMA 密集负载可能见小幅让位）；**BRAM 同址同拍读写语义分叉风险**（综合用 NO_CHANGE、RTL/iverilog 是 read_first，靠协议+dang_hit 保护，属未证假设，建议定向一致性检查）；iverilog 在 STQ/LQ 近满时吞吐崩塌 >100×（仿真限制，LSU 持续饱和工况无法定向仿真）。
