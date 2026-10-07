# RV32GC 2B 乱序核 —— 总结性报告

> 本文件是**唯一**的"总结性报告"落点（用户约定：每次更新都在此文件修改，不新建 md）。
> 固定四部分：① 项目当前状况 → ② 主要问题与成因 → ③ 解决方案与优化路径 → ④ 补充信息。
> 数据均为实测原始值，随综合 tag/commit 可复现，禁止编造或夸大/缩小。
> 更新日期：2026-10-06

---

## ① 项目当前状况（架构 / 技术 / 资源）

### 1.1 一句话定位

一个面向 **chiplab / xc7a200t** 的 **RV32GC 4-发射乱序（OoO）处理器**（项目内代号 2B），当前处于**后端面积优化**阶段：已从 366,483 LUT（272.28%）压到 **155,986 LUT（115.89%）**，目标 ≤80%（107,680 LUT）。

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

- 关键结构参数（当前 HEAD `d36849c`）：整数物理寄存器 **NREG_I=64**（PDW_I=6bit）、浮点 64（6bit）、ROB 64、SQ 32、LQ 8、IQ 总容量 50、checkpoint 16、**commit 2-wide（分配仍 4-wide）**、free-list FL_DEPTH=64。
- 流水线：前端 4 宽取指 → rename（4 宽分配）→ IQ 唤醒/选择（4-wide issue）→ 发射 → 执行 → 写回（4 写口）→ **2 宽提交**。

### 1.3 使用技术

| 层 | 技术 |
|---|---|
| RTL | SystemVerilog（组合逻辑用 `assign`/`function`，`always` 仅时序），参数化宏布局真源 `back2_params.vh` |
| 仿真 | iverilog 12.0（`rv32_rtl_sources` 58 文件全量编译）+ 锁步比对 Spike 黄金 |
| 综合 | Vivado 2023.2 batch（`run_vivado_batch.sh` 统一入口；**RuntimeOptimized** 配方，16.667ns/60MHz） |
| 平台 | chiplab 龙芯实验箱，xc7a200tfbg676-2，DDR3 AXI + XIP + confreg |
| IP | mult/div（Vivado IP，仿真行为模型双分支）；BRAM 用 XPM/rob_wide_mem 行为模型 |

### 1.4 资源占用率（当前，`synth_2b_n3_16.667ns_utilization.rpt`）

| 资源 | 占用 | 器件 | 百分比 |
|---|---:|---:|---:|
| **Slice LUTs** | **155,986** | 134,600 | **115.89%**（目标 80%） |
| Slice Registers | 70,303 | 269,200 | 26.12% |
| RAMB36 | 40 | 365 | 10.96% |
| RAMB18 | 10 | 730 | 1.37% |
| DSP48E1 | 34 | 740 | 4.59% |

**资源特征**：**LUT 仍是唯一超标的资源**（115.89%，从 133.69% 进一步下降）；FF/BRAM/DSP 有大量余量。这是"用 FF/BRAM 换 LUT"路线的物理基础。

---

## ② 主要问题与成因

### 2.1 核心问题：LUT 超 80% 目标，剩余缺口靠"结构宽度"

**事实**：当前 155,986 LUT = 115.89%，到 ≤80%（107,680 LUT）仍差 **−48,306 LUT（−31.0%）**。

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

**结论（有数据支撑）**：结构宽度重构（commit 4→2、ROB 窗 8→2、写口 6→4、free-list 128→64）已拿到 −57.4%，但到 80% 还需动 FPU 数据通路 / IQ 窄队列 / LSQ 转发这类"硬"结构，其中 FU 数量/频率改动需用户审阅。

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

**后续方向（都需先报用户审阅 FU/频率，或属高复杂度）**：
1. **FPU 数据通路重构**（FU_FPU 21k）：div/sqrt 已是最大单块，但 iterative 化被容量数据否决（占忙拍 51%）——需权衡"面积 vs FP 密集程序延迟"。
2. **IQ 窄队列 np_q（14.7k）**：4 写口源于 4-wide 分配（hard），可考虑"type-specific IQ payload"（union 编码）或 IQ 深度微调。
3. **LSQ 字节转发 fwdp_data（14k）**：STQ_N=32 的字节级转发 mux，可考虑两级过滤（word-address 先行过滤）。
4. **PRF 读侧 2-cycle operand read**（answer.md §八）：读口 16→4 用"固定数据路径"（IQ0→固定 operand stage→FU0），而非 EXP-A 的全局 collector。

---

## ④ 补充信息

1. **本阶段正确性收获（比面积更重要）**：
   - rename 回滚取点错位（在飞两指令同 pdi 撞车）——已修。
   - PRF busy 表清零用全局 epoch 导致的死锁（与 rob.v §5.2 同源）——已修（被 TRQ 垃圾训练掩盖）。
   - TRQ 三处记账缺陷——已修，预测器训练数据从"近半垃圾"变正确。
   - LSQ 非 8B 对齐 load 命中错字的转发缺陷——已修（commit 2 宽拉长 store 存活期后暴露）。
2. **验证纪律**：`tb_core_top_2b` 219/219 + `tb_back2_iq` 151/151 + `tb_back2_lockstep` 57/57（提交 821）+ `regress.sh` 33/33；IPC=2.0 + C5 五档；逐拍等价；重综合 tag 命名。
3. **面积演进全史**（commit 级）：366,483 → L1 −74,086 → ROB64 −36,052 → LQ16 −2,597 → flist_q −14,330 → C2 −8,420 → EXP-B −6,807 → C1 −14,340 → C6 −8,879 → D1 −1,434 → C7 −546 → C4+C9 −488 → C8 −425 → D2 −874 → EXP-R1 −3,536 → EXP-R3b −2,479 → LQ16→8 −1,002 → NREG −10,239 → **N1 −16,022 → flist_q(128→64) −2,093 → N4 −3,171 → N3 −2,677** = **155,986**（累计 −57.4%）。
4. **已知遗留**：设计文档口径滞后（NREG 96→64、nq 49→37、RB 416→229、commit 4→2 等未同步）；动态探针 `dyn_probe_r` 需适配 EXP-R1 后的 rename 接口；NREG=64 余量仅 6 个物理号；时序 WNS≈−48ns（155%→116% 下仍深度不收敛，拟合后需重点 STA）。
