# 审计①：后端模块耦合度审计报告（只读 / 不改一行 RTL）

> **审计性质**：纯结构 / 可读性审计。**未修改任何 RTL / TB / 脚本 / 探针 / 临时件**；本文件与
> `fpga/scratch/audit1_check.sh`（fail-closed 计数脚本）是本审计**唯一**写出的文件。
> **未提交 git**，未扩大范围，未转包。
>
> **冻结基准**：`git rev-parse HEAD` = `201d88d03b32b05bbe3d492ad1089b11f7000513`；
> 经 `git diff d00eb03 HEAD -- rtl/` **为空**，故 RTL 内容等价于任务指定的冻结基线 **`d00eb03`**
> （`d00eb03` = "2B-5: EXP-N35B ROB 窄表 nq 36→16 bit"，`201d88d` 只多一个 docs 提交
> `fpga/area-optimization-report.md`）。
>
> **综合参考**（只读，未重新综合）：
> `fpga/out/synth_2b_n35b_16.667ns_utilization_hier.rpt`
> sha256 `edd9cfadac43203c375f578e9955513181c7943629c85daed77de8fad95b5d0a`
> `fpga/out/synth_2b_n35b_16.667ns_utilization.rpt`
> sha256 `0a7faefec2a371286981e5c879b2fda394aabe837589aa66310fb7f5451707e8`
> 全核口径：**Slice LUT 126,699（94.13%）/ Slice Reg 49,597（18.42%）/ RAMB 45 / DSP 21**。
>
> **口径声明（重要）**：本设计的 `flatten_hierarchy = rebuilt`，
> 历史报告 `fpga/scratch/n35a_report.md:73-80` 已实测证明**"容器 ≠ 逻辑归属"**
> （"ROB 的 RTL 在两轮之间未改，差异来自 `rebuilt` 把读侧 mux 改名到了消费者名下"）。
> 因此 §4 的 per-instance LUT **只作为量级参考**，不单独作因果；
> "单模块高负载"的主证据是 **RTL 侧结构度量**（行数 / 职能数 / 端口数 / always-assign-function 数）。
>
> **锚点**：`AUDIT1: PASS`（见 §9；`bash fpga/scratch/audit1_check.sh` 复核）。

---

## 0. 结论摘要（先给答案）

| 问题 | 结论 | 关键数字 |
|---|---|---|
| **是否有"多职能塞进同一模块"？** | **是，且严重**。`backend_top.v` 承载 **§0–§13 共 14 个编号段 + §5.5 子段 + 1 个未编号段**，其中 §4/§9 各 >300 行、每段含 6–7 个互不相关的职能 | 2813 行 / **116 端口** / 20 always / **270 assign** / **108 function** / 13 generate |
| **是否有"跨模块重复实现"？** | **是**。同一 uop 有 **6 套位域布局**（`U/UB/IQN/IW/NQ/RB`，共 197 条宏）；`backend_top.v` 是**唯一**同时引用全部 6 套的文件（330 处引用） | 重复实现 ≥10 组（§3 表） |
| **单一模块高负载量化** | `backend_top` 子树 **104,151 LUT = 全核 82.2%**；其中本模块自身（`(u_back)` 行）627 LUT / **3,479 FF** | 另：`lsq_simple` 22,859 / `rob` 15,442 / 6×`iq` 13,267 |
| **对照：前端顶层是否同样耦合？** | **否**。`front4_top.v` 端口 **112** 个却只有 **1 个 always（epoch FF）+ 7 个 assign**，是**纯互连顶层**；`backend_top.v` 端口 116 却另有 6 个功能子系统 | 行/端口密度：front4_top 3.2，backend_top **24.2** |
| **可读性最差的 5 处** | §5.5 发射宽载荷内存（110 行）、`fp_cvt_map/fp_op_map`（50 行，与 `core_top.v` 重复）、未编号 §EXP-R3b（198 行打断编号）、`p_lq` 死函数、**8 行**"引用绝对行号"的注释 | §5 |
| **修正建议** | 8 条，全部为**预估**、只做"搬移 + 单一真源"、不改功能语义；预估净面积收益 **−0 ~ −350 LUT**，主要收益是**可维护性**而非面积 | §6（须经官方综合门复验） |

---

## 1. 审计维度①：模块内多职能（功能 → 行号清单）

### 1.1 `rtl/back2/backend_top.v`：13 编号段 + 1 未编号段

| 段 | 行区间 | 行数 | 该段**实际承担**的职能（≥2 即为耦合证据） |
|---|---|---|---|
| §0 局部常量与纯函数 | 209–444 | 236 | **6 族纯函数**：`u_*` uop 取值(39)、`p_*` ROB 载荷取值(21)、`w_*` 发射宽载荷取值(35)、`pack_iw`、分支类别 `t_*`(4)、**FP 归一化映射 `fp_cvt_map/fp_op_map`(2)** |
| §1 声明（统一前置） | 445–670 | 226 | 全 116 端口的内部派生 + **8 类**状态声明（D1 reg / 在途 reg / STQ-LQ 归属表 / 检查点表 / 训练 FIFO / 计数 / busy 位图 / IQ 写口打包向量） |
| §2 D1 | 671–863 | 193 | **6 职能**：4×`decoder` 例化 + uop 打包 + `oq` 队列分配 + `unsup/illegal` 判定 + `rs1_used/rs2_int` 使用位推导 + xRET/维护/CSR 前置译码标志 |
| §3 D1 寄存器 | 864–887 | 24 | 单职能（可接受） |
| **§4 D2/D3** | **888–1199** | **312** | **6 职能**：①重命名请求 ②资源检查（`free_ok` / IQ `iq_free_ok` / STQ / LQ）③派发 fire ④ROB 载荷 225 bit 拼接 ⑤**CSR 串行化** ⑥STQ/LQ 槽分配 |
| §5 六个发射队列 | 1200–1386 | 187 | 6×`iq` 例化（单职能，可接受） |
| **§5.5 发射宽载荷** | **1387–1496** | **110** | **4 职能**：①4 bank SDP BRAM 写口分解 ②读口**固定优先级仲裁器** `iwm_arb` + 让位规则 ③获准 bank → 队列归属路由 ④**6×4:1 交叉开关**写 `x_i2_uop` |
| §6 I2 寄存器 + E1 执行 | 1497–1717 | 221 | **5 职能**：I2 流水寄存器 + BRU 执行 + LSU 请求生成 + MDU/FPU 发射 + **CSR→load/FP 可见性门**（`i2_sq_kill_f`@1512、`csr_age_w`@1242） |
| §7 写回总线/唤醒 | 1718–1837 | 120 | 5 职能：写回总线仲裁 + 唤醒广播 + **MDU/FPU 共享物理写口** + 写回窗口过滤 + busy 位图更新 |
| §8 忙碌位图 | 1838–1872 | 35 | 单职能（可接受） |
| **§9 提交（W1）** | **1873–2190** | **318** | **7 职能**：①提交有效/PC 输出 ②**架构 RAT 更新** ③**free-list 回收**（`rel_i_*`/`rel_f_*`）④CSR 提交写 + fflags 累积 ⑤**store 排空（CDQ）入队**（`lsu_dr_valid`@1937）⑥分支训练 ⑦检查点释放 |
| §10 PRF | 2191–2281 | 91 | 3 职能：整数+浮点**读口仲裁**（ALU1∪MDU / LSU∪FPU）+ **写口 6→4 物理合并**（`iprf_p3_src`@2236）+ FLD NaN-box |
| §11 重定向/异常 | 2282–2443 | 162 | 类别 A/C 重定向 + 异常 cause 生成 + **xRET 译码函数**（`xret_kind_f`@2336 / `is_xret_f`@2346）+ 维护操作译码（`maint_kind_f`@2350） |
| §12 提交训练/检查点/RAS | 2444–2467 | 24 | 单职能（可接受） |
| **（未编号）§EXP-R3b** | **2468–2665** | **198** | **提交暂存 4 槽 + 1W/1R 16 深 FIFO**——一个独立的结构重构段被插在 §12 与 §13 之间，**编号断裂** |
| **§13 时序：misc** | **2666–2813** | **148** | **1 个 133 行 always 内含 6+ 职能**：MDU/FPU 在途登记 + 写口挂起/数据锁存 + **STQ 归属表** + **LQ 归属表** + **检查点表登记/释放** + 训练 FIFO + 统计计数 |

> **度量**：`grep -cE "^\s*assign" = 270`、`grep -cE "^\s*always" = 20`、
> `grep -cE "^\s*function" = 108`、`grep -cE "^\s*generate" = 13`、端口 **116**、行数 **2813**。
> **注释占比 30%（856/2814 行）**——注释密度极高本身即是"逻辑难以自解释、必须靠长注释维系"的信号。

### 1.2 其余后端模块的功能清单

| 模块 | 行数 | 端口 | always | assign | gen | func | 编号职能段（行号） |
|---|---|---|---|---|---|---|---|
| `rob.v` | 918 | 49 | 6 | 45 | 8 | 5 | §0 存储体与指针(170)、§1 索引派生与余量(329)、**§1.1 年龄唯一计算点(339)**、**§1.5 BRAM 写/读轮转+头部窗口(355)**、§2 余量(521)、§3 提交载荷/异常输出(535)、§4 观测(564)、§5 时序(599)、§5.3b typed 表独立写进程(734)、§6 typed 表 assertion(817)。**基本单职能（ROB），耦合度低** |
| `rename.v` | 1029 | 31 | 5 | 62 | 18 | 0 | §0 状态(147)、§0.1 RAT 快照回滚(229)、§1 同拍 lane 组合推导(264)、§2.9/§2.10 不变式自检(753/818)、§3 时序(837)、§3.0 架构 RAT 更新(891)、§3.1 全冲刷(916)、§3.2 回滚启动(947)、§3.4 常规日志+RAT+提交+快照(968)。**基本单职能（重命名），耦合度低** |
| `iq.v` | 516 | 30 | 6 | 21 | 6 | 7 | §1 队列存储(182)、§2 就绪判定+最老优先(226)、§3 空位分配 bank 均衡(326)、§4 计数输出(439)、§5 时序(444)。**单职能（发射队列），耦合度低** |
| `lsq_simple.v` | 1483 | **80** | 2 | 79 | 21 | 2 | §0 STQ(187)、§0b 悬空净化+翻译定妥门(220)、§1 D3 分配(280)、§2 更老 store 检查+字节转发(364)、§2.1 保守闸门(366)、§2.2 字节级转发(389)、§2.3 纯等待变体(523)、§3 LQ(593)、**§3.3 CDQ 排空队列(773)**、**§3.4 store 地址翻译引擎(829)**、§4 时序(1055)。**职能数偏多：LSQ 本体 + 地址翻译引擎 + 排空队列 = 3 个子系统**，端口 80 |
| `prf.v` | **99** | **11** | 1 | 1 | 1 | 0 | **单职能（物理寄存器堆）**。是本设计中**分离度最好的模块**，可作拆分目标的模板 |
| `rob_wide_mem.v` | 162 | 8 | 3 | 1 | 2 | 0 | 单职能（4 bank SDP 存储封装） |
| `front4_top.v`（**对照**） | 361 | **112** | **1** | **7** | 0 | 0 | §0 内部互联(199)、§1 pc_gen4(221)、§2 预测器(247)、§3 ifetch4(297)、§4 统计(352)。**纯互连顶层**：112 端口、唯一 always 是 epoch FF |

### 1.3 行数 >100 的 always / assign / generate 段（逐一列名）

| 类型 | 行号 | 行数 | 名称 / 职能 | 文件 |
|---|---|---|---|---|
| `generate` | 676–862 | **187** | `g_dec`：4 lane × (decoder 例化 + illegal/unsup/rs-use + `oq` 分配 + uop 打包 + 前置译码) | backend_top.v |
| `always` | 2671–2803 | **133** | §13 misc 状态更新（MDU/FPU 在途 + STQ/LQ 表 + 检查点表 + 训练 FIFO + 统计） | backend_top.v |
| `generate` | 1052–1107 | 56 | IQ 写口条数/序号压缩（`q_wr_n` / `q_ord` / `lane_q`） | backend_top.v |
| `generate` | 1903–1956 | 54 | 提交组 lane 展开（架构写/释放/CDQ 入队） | backend_top.v |
| `always` | 2027–2066 | 40 | 提交点 CSR 单 lane 动态读口 + fflags 累积 | backend_top.v |
| `always` | 1843–1871 | 29 | 写回总线合并 + 唤醒广播 | backend_top.v |
| `generate` | 2557–2584 | 28 | EXP-R3b 训练 FIFO 写口 | backend_top.v |
| `always` | 1520–1546 | 27 | E1 BRU 执行 | backend_top.v |
| `assign` | 1385–1408 | 24 | §5.5 IQ 宽载荷写口 bank 分解 | backend_top.v |
| `always` | 2391–2412 | 22 | 重定向/异常 cause 合成 | backend_top.v |
| `always` | 867–886 | 20 | D1 流水寄存器 | backend_top.v |
| `generate` | 1463–1482 | 20 | §5.5 读口仲裁（`iwm_gnt` 让位） | backend_top.v |
| `generate` | 922–940 | 19 | 浮点操作数来源判定 | backend_top.v |

---

## 2. 审计维度②：扇入扇出热点

### 2.1 宽（≥40 bit）/ 深（≥64 项）信号扇出表（`backend_top.v`，逐通道位数 × 引用次数）

| 行 | 信号 | 位宽 | 深度 | 文本引用 | 总线位数 | 备注 |
|---|---|---|---|---|---|---|
| 545 | `iq_wuop` | 7200 | — | 9 | **7200** | 6 队列 × 4 写口 × 300 bit **单条打包向量**，只被 6 个 `.wr_uop()` 端口消费 |
| 618 | **`x_i2_uop`** | **212** | **6** | **106** | **1272** | **全后端最高扇出网**：E1 发射宽载荷，被 `w_*`(35 个函数) + §6/§10 直接消费 |
| 490/491 | `d1_lat_uop` / `d1_uop_q` | 300 | 4 | 32 / 31 | 1200 | D1 全宽 uop（4 lane） |
| 1049 | `lane_uop_fin` | 300 | 4 | 24 | 1200 | 派发前最终 uop |
| 629 | `rob_pay_w` | 900 | — | 3 | 900 | ROB 载荷拼接结果（4×225） |
| 530/533 | `iwm_wdata` / `iwm_rdata` | 848 | — | 3 / 3 | 848 | §5.5 宽载荷 BRAM 写/读数据 |
| 627 | `cmt_pay` | 450 | — | **19** | 450 | 提交载荷窗口（2×225），被 `p_*` 函数群唯一扇入 |
| 574 | `iprf_rd` | 352 | — | 15 | 352 | 整数 PRF 11 读口 |
| 588 | `fprf_rd` | 320 | — | 7 | 320 | 浮点 PRF 5 读口 |
| 547 | `iq_wrdy` | 264 | — | 9 | 264 | 唤醒就绪位（6×4×11） |
| 606 | `wbi_data` | 192 | — | 4 | 192 | 写回总线（6×32） |
| 546 | `iq_wrob` | 144 | — | 9 | 144 | IQ 槽 → ROB 索引 |
| 173 | `iprf_ra` (66)/`fprf_ra` | 66 | — | 14 | 66 | PRF 读地址（11 口） |

> 共 **24** 条 ≥40 bit 或 ≥64 深声明（`audit1_check.sh` 只做存在性计数）。
> 其中 **`iq_wuop`(7200) 与 `iq_wrdy`/`iq_wrob` 这类"6 队列打包成一条向量"的写法**，
> 使一条 `assign` 同时横跨 6 个不同模块实例——这是"跨模块聚集"的 RTL 形态。

### 2.2 跨模块控制信号扇出

| 信号 | 出现模块数 | 模块清单 |
|---|---|---|
| `epoch` | **8** | back2: backend_top / iq / lsq_simple / prf / rob；front4: front4_top / ifetch4 / pc_gen4 |
| `squash_idx` | **5** | backend_top / iq / lsq_simple / rename / rob |
| `rob_head` | **4** | backend_top / iq / lsq_simple / rob |
| `iss_ready` | **3** | backend_top / iq / lsq_simple |
| `free_cnt` | **3** | backend_top / iq / rename |
| `wr_valid` | 2 | backend_top / iq |
| `win_rd` | 2 | backend_top / rob |
| `rob_alloc_idx0` | **1** | backend_top（**只在顶层存在**：派发索引的唯一拼接点） |

### 2.3 已签名（Signature）的函数群扇入

| 项 | 证据 | 引用 |
|---|---|---|
| `p_*` 函数群（21 个，279–303） | 编译期即 **`cmt_pay` / `win_rd` 的唯一扇入**；定义处注释自陈"被 `sim/unit/tb_back2_lockstep.sv` 按**层次名**调用（`p_pc/p_pdi/p_pdio/p_di/p_cls/p_st/p_csr`）⇒ **名字与签名不得改**" | `backend_top.v:277-278`；`n35a_report.md:304,339` |
| `p_lq`（295） | **零调用者**（全文件仅此 1 处文本）。注释自陈"当前**无调用者**……保留定义仅为位域真源完整" | `backend_top.v:293-295` |
| `x_i2_uop` 写 mux | 6 条 `assign` 由 `iwm_own_q` 选 bank，构成 §5.5 的 4:1 交叉开关；其扇入 = `iwm_rdata`（BRAM 输出寄存器） | `backend_top.v:1489-1493` |
| `lsq_simple.v` §3.3 CDQ 写口 | 入队许可 `dr_room_ok` 依赖**本模块内** `cdq_cnt` 寄存器态 + `stq_blk_any_w`；而"何时可以入队"的**触发链在 `backend_top.v` 的提交块**（`lsu_dr_valid`@1937） | `lsq_simple.v:773-827`；`backend_top.v:1937-1961` |
| `iwm_gnt`（1463–1482） | 全部 6 位移位/让位规则内联在顶层；`iss_ready` ⊃ `iwm_gnt`（注释自陈"不构成组合环"）| `backend_top.v:1456-1461` |

---

## 3. 审计维度③：重复实现表（同一函数/信号在 ≥2 模块出现）

| # | 重复对象 | 位置 A（行号） | 位置 B/C（行号） | 判定 |
|---|---|---|---|---|
| D1 | **同一 uop 的 6 套位域布局** | `back2_params.vh`：`BACK2_U_`(70 宏) / `BACK2_UB_`(16) / `BACK2_IQN_`(14) / `BACK2_IW_`(52) / `BACK2_NQ_`(11) / `BACK2_RB_`(44) = **197 宏 / 6 布局** | 引用者：`backend_top`(**6 套全用**, 330 处) > `rob`(4 套, 63 处) > `iq`(3 套, 36 处) | **布局爆炸**：`backend_top.v` 是唯一必须同时理解全部 5 个**外部模块内部存储布局**（IQN/NQ/RB 分别属 iq/rob）的文件 |
| D2 | **1 bit 标志位重复译码** | `u_is_csr`@247 / `u_is_st`@250 / `u_di`@251 / `u_df`@252 / `u_s1i`@254 / `u_s1f`@256 + `u_ckv`@267 / `u_fpls`@253 / `u_is_br`@248 | `p_csr`@288 / `p_st`@287 / `p_di`@285 / `p_df`@286 / `p_ckv`@289 ‖ `w_is_csr`@325 / `w_is_st`@327 / `w_di`@328 / `w_df`@329 / `w_s1i`@331 / `w_s1f`@332 / `w_ckv`@333 / `w_fpls`@330 / `w_is_br`@326 | **9 条宏在 ≥2 族重复，其中 7 条在 u/p/w 三族各实现一次**（如 `BACK2_UB_IS_CSR` 3 份）|
| D3 | **uop → 窄载荷 重打包** | `pack_iqn`（uop 300→40 bit，`iq.v:142-159`） | `pack_iw`（uop 300→212 bit，`backend_top.v:343-370`） | 二者共享 5 组源字段（PS1I/PS2I/PS1F/PS2F/PS3F + 3 个 `UB_*`）；`iq.v:140` 自陈"UOPW 与 IQW 的布局**真源**分别是…" |
| D4 | **FP 归一化操作码映射** | `core_top.v:517`（`fp_op_map`）+ `core_top.v:496`（`fp_cvt_map`） | `backend_top.v:410`（`fp_op_map`）+ `backend_top.v:394`（`fp_cvt_map`） | **逐 case 等价的两份拷贝**；`backend_top.v:379-380` 自陈"必须与 `rtl/top/core_top.v` 的 `fp_op_map(de_fp_op, insn)` **逐条等价**"——即靠注释维持一致性 |
| D5 | **4 bank 写口轮转公式** | `rob.v:364` `wsel[gw]=gw[1:0]-tail_w[1:0]`；`rob.v:397` `bw_woff=wt[ROB_IDX_W-1:2]`；`rob.v:398` `bw_wdata=alloc_payload[wsel]` | `backend_top.v:1411` `lw=gw_iwm[1:0]-rob_alloc_idx0[1:0]`；`1413` `iwm_woff=rb_ix_w[lw][5:2]`；`1415` `iwm_wdata=pack_iw(lane_uop_fin[lw])` | **逐位同式**；`backend_top.v:1404` 自陈"与 `rob.v` §1.5 的 `wsel` **逐位同式**" |
| D6 | **`(idx − rob_head) mod ROB_N` 年龄原语** | `rob.v:351` `age_sq_w = squash_idx - head_q`（唯一点）｜`iq.v:249-253` `age_q[ge] = rob_q[ge] - rob_head`（模块内唯一点） | `backend_top.v` **19 处手写**：1241/1242/1255（CSR 年龄）、1516（发射窗口）、1615/1618（MDU/FPU 在途）、1811（`in_rob_win`）、1818–1823（6 lane 写回窗）、2035（CSR 挂起）、2264/2265/2277/2278（PRF 写口）、2771（检查点） | `rob.v:349-350` 自陈"各消费模块**不再各自重算**"——**该目标未在 `backend_top.v` 达成**（反证：19 处仍在） |
| D7 | **"仍在 ROB 窗口内"判据 `(x−head) < cnt`** | `backend_top.v` 内联 **13 次**（`grep -cE "< *rob_cnt_w"`），集中在 1818–1823（6 次）、2264/2265/2277/2278（4 次） | `rob.v` 提供 `cnt_o` 与 `slot_ok` | 谓词未命名、未函数化 ⇒ `prf.v` 端口注释反而要**解释调用方**为什么这么写（`prf.v:46-54`） |
| D8 | **lane 压缩序号（前缀和）** | `rename.v:269-279` `ord_r[]`；`rename.v:449-459` `lg_rank[]` | `lsq_simple.v:813-824` `dr_rank[]`；`backend_top.v:905-912` `q_ord[]` | **4 处独立实现**同一"有效 lane 紧凑编号"模式 |
| D9 | **IQ 入队许可（admission）** | `iq.v:367-374`：`a_n = Σ wr_valid` → `wr_ok = (a_n <= wr_cap)` | `backend_top.v:904-912`（`q_wr_n`）、`983-989`（`iq_free_ok[0..5]`、`iq_room_ok`） | **同一不变式两侧各算一遍**；`iq.v:108` 自陈风险"总空位够、某 bank 放不下时让 iq 内部 `wr_ok=0` ⇒ **静默丢项**" —— 重复实现 + 静默失败模式 |
| D10 | **store"已提交但永不落地"的 CDQ 契约** | `lsq_simple.v:773-827`（CDQ 本体 + 余量门） | `backend_top.v:1937-1961`（`lsu_dr_valid/idx` 入队许可）+ `1937-1961` 注释直接引用 `rob.v:213` 的 `cmt_st_drain` | 契约横跨 **3 个模块**（rob 的提交链 → top 的入队许可 → lsq 的队列），任一处改动需同步理解另外两处 |

---

## 4. 审计维度④：单一模块高负载量化

### 4.1 `backend_top` 子树 LUT/FF 归属（`..._utilization_hier.rpt`，**rebuilt 口径，仅作量级**）

| 实例 | 模块 | Total LUTs | 占 backend 子树 | FFs |
|---|---|---|---|---|
| `u_lsu` | lsq_simple | **22,859** | 21.9% | 6,521 |
| `u_rob` | rob | **15,442** | 14.8% | 2,048 |
| `u_iq0..u_iq5`（6 个） | iq ×6 | 2,352+2,672+1,887+1,769+2,560+2,027 = **13,267** | 12.7% | 2,812 |
| `u_ren_f` | rename__parameterized0 | 11,950 | 11.5% | 4,850 |
| `u_iwmem` | rob_wide_mem | 9,986 | 9.6% | 0 |
| `u_fpu` | fpu | 9,136 | 8.8% | 3,771 |
| `u_ren_i` | rename | 9,068 | 8.7% | 4,850 |
| `u_prf_i` | prf | 6,327 | 6.1% | 2,048 |
| `u_prf_f` | prf__parameterized0 | 4,271 | 4.1% | 4,096 |
| `u_mdu` | mdu | 1,681 | 1.6% | 3,470 |
| **`(u_back)` 本模块自身** | **backend_top** | **627** | **0.6%** | **3,479** |
| （子实例合计） | — | 103,987 | 99.8% | 34,466 |
| **`u_back` 子树总计** | backend_top | **104,151** | 100% | 37,945 |
| 全核 | core_top_2b | 126,699 | **82.2%（占全核）** | 49,597 |

> **两处必须诚实登记的口径问题**：
> ① 子实例合计 + 本模块自身 = 104,614，比报告给出的 104,151 多 **463 LUT** ——
>    层次报表在 `rebuilt` 下存在重复/错挂，**不能逐行当守恒账**。
> ② 本模块自身仅 **627 LUT**，与其 1,849 行代码量严重不匹配，根因同上：
>    `rebuilt` 会把顶层的组合逻辑改名到消费者容器下
>    （`n35a_report.md:73-80`、`n35a_report.md:431`、`n34a_report.md:418`）。
> **故本维度的主证据是 RTL 结构度量（4.2），LUT 表只用于说明"面积集中在子模块"这一事实。**

### 4.2 RTL 结构度量（可复现、不受 `rebuilt` 影响）

| 模块 | 行数 | 端口 | always | assign | generate | function | 行/端口 | 注释% |
|---|---|---|---|---|---|---|---|---|
| **`backend_top.v`** | **2813** | **116** | 20 | **270** | 13 | **108** | **24.2** | 30% |
| `lsq_simple.v` | 1483 | **80** | 2 | 79 | 21 | 2 | 18.5 | 40% |
| `rob.v` | 918 | 49 | 6 | 45 | 8 | 5 | 18.7 | 42% |
| `rename.v` | 1029 | 31 | 5 | 62 | 18 | 0 | 33.2 | 34% |
| `iq.v` | 516 | 30 | 6 | 21 | 6 | 7 | 17.2 | 34% |
| `prf.v` | **99** | **11** | 1 | 1 | 1 | 0 | **9.0** | 50% |
| `rob_wide_mem.v` | 162 | 8 | 3 | 1 | 2 | 0 | 20.3 | 29% |
| **`front4_top.v`（对照）** | 361 | **112** | **1** | **7** | 0 | 0 | **3.2** | 21% |

**关键对照**：`front4_top.v` 端口数（112）几乎与 `backend_top.v`（116）相同，
但前者是**纯互连**（1 always / 7 assign / 行端口密度 3.2），
后者在同样的接口规模上**额外承载 6 个功能子系统**（行端口密度 **24.2**，是其 **7.6 倍**）。
这直接回答用户关切：**"译码 / dispatch / 发射被塞进同一个模块"确有其事，且只有后端这样做。**

### 4.3 重复译码的接口成本

| 项 | 数值 | 引用 |
|---|---|---|
| `backend_top.v` 引用的位域布局套数 | **6 / 6** | §3 D1 |
| `backend_top.v` 内纯字段取值函数 | **95 / 108**（u39 + p21 + w35） | `grep -cE "^\s*function"` 分族统计 |
| 内联"窗口内"谓词次数 | **13** | `grep -cE "< *rob_cnt_w"` |
| 手写年龄减法次数 | **19** | §3 D6 |
| 注释中引用**绝对行号**的行数 | **8** = 7 处"文件:行号"（174, 802, 1509, 1945, 2304, 2330, 2345）+ 1 处裸行区间（1867 `"与 2105-2106"`） | `grep -nE "//.*(\.v\|core_top\|tb_csr_file)[\`: ]*[0-9]{3,4}"` = 7；`grep -nE "//.*与 [0-9]{3,4}-[0-9]{3,4}"` = 1 |
| 注释中引用其它模块文件的次数 | `rob.v` 17 / `core_top` 10 / `iq.v` 9 / `back2_params` 9 | §8 命令 |
| 因 TB 层次名调用而**冻结**的函数签名 | ≥7（`p_pc/p_pdi/p_pdio/p_di/p_cls/p_st/p_csr`） | `backend_top.v:277-278` |

---

## 5. 审计维度⑤：可读性抽样（5 处，带行号）

| 抽样 | 位置（行号） | 现象 | 为什么属于"该逻辑属于别的模块" |
|---|---|---|---|
| **S1** | `backend_top.v:394-443`（50 行） | `fp_cvt_map` / `fp_op_map` 两个 FP 归一化译码函数 | 与 `core_top.v:496/517` **逐 case 等价**（§3 D4），且与 `rtl/decode/fp_map`（`rtl/decode/` 目录）职责重叠；靠注释"必须逐条等价"维系 |
| **S2** | `backend_top.v:1387-1496`（110 行） | §5.5 发射宽载荷：4 bank SDP 例化 + 读口仲裁 + 让位规则 + 6×4:1 交叉开关 | 这是 **IQ 的存储/读口子系统**，与 `iq.v`（发射队列）强耦合却住在顶层；写口公式又与 `rob.v` §1.5 重复（§3 D5） |
| **S3** | `backend_top.v:2468-2665`（198 行） | 未编号段 **§EXP-R3b**（4 槽提交暂存 + 1W/1R 16 深 FIFO） | 一个独立可命名结构被打断编号插在 §12/§13 之间；同一文件 §13 的 133 行 always 里又有"训练 FIFO"子块（2746-2758）——**同一 FIFO 的写口与状态更新分居两段** |
| **S4** | `backend_top.v:295` | `function [LQ_IDX_W-1:0] p_lq;` —— **零调用者** | 注释自陈"保留定义仅为'位域真源'完整"；`p_*` 族的**位域真源**应由 `back2_params.vh` 承担，而非死函数 |
| **S5** | `backend_top.v:174` / `:802` / `:1509` / `:1867` / `:1945` / `:2304` / `:2330` / `:2345`（共 **8 行**） | 注释直接写**绝对行号**：`"与 2105-2106"`、`"（rob.v:213）"`、`"`iq.v:279-287`"`、`"`core_top`:1715"`、`"`core_top.v:1418/1679/1694/1709`"`、`"`dec_csr.v:222-237`"`、`"`priv_ctrl.v:155`"`、`"`core_top.v:1418`"` | 行号锚点在任一次插入/删除后即失效。**"an absent naming"** 的典型：因为谓词/契约没有**名字**（如"窗口内"、"更老 store 可入队"、"xRET 识别"），只能用行号指代 |

> **附带记录（不占抽样名额）**：
> ① `backend_top.v:983-988` 把 `iq_free_ok[0..5]` **手工展开 6 遍**而不写 `generate`；
> ② `iq.v:133/168` 的 `o_sel_uop` 是 **300 bit × 6 实例 = 1800 bit 的接口兼容位**，
>    自陈"仅为接口兼容保留……综合时被剪除，语义真源是 `o_sel_nq`"；
> ③ `lsq_simple.v:775` 写"`rob.v` 允许同拍最多 **4** 条 store 提交"，而 `COMMIT_W` 现为 **2**
>    （`backend_top.v:507-509` 记录了 4→2 的收窄）⇒ **契约注释已过期**。

---

## 6. 修正建议表（**全部为"预估"，未做任何实验；面积/时序收益须由官方综合门复验**）

> 原则：只做**搬移 + 单一真源**，不改功能语义、不改位域、不改流水级数。
> 每条建议的第一验收标准是"官方 Slice LUT 不劣化 + WNS 不劣化 + 三 TB 逐字节一致"。

| # | 拆分/重构目标 | 迁入行数（预估） | 覆盖 RTL 行号 | 面积预期（**预估**） | 时序预期（**预估**） | 风险 | 前置条件 |
|---|---|---|---|---|---|---|---|
| **F1** | 新建 `rtl/back2/iq_wdata.v`：把 §5.5 发射宽载荷从顶层搬出（BRAM 例化 + 读口仲裁 + 让位 + 交叉开关） | 110 + ~35 decl | 1387–1496、decl 530–533/1411–1420 | **0**（纯搬移，无逻辑变化） | 中性；边界引入 1 层端口可能 +0.0~−0.05ns | 低 | 与 `iq.v` 的 `iss_ready` 契约保持逐位一致 |
| **F2** | 新建 `rtl/back2/wb_arb.v`：抽 §13 的 MDU/FPU 在途登记 + 写口挂起/数据锁存 + §7 的共享写口仲裁 | ~90 + ~40 decl | 2671–2750、1718–1760 | **0 ~ −150 LUT**（若抽出后写口 mux 更易被识别为独立选择树） | 中性偏好（缩短 `fpu_result`→`wbi_data` 关键路径的容器边界） | 中（在途/挂起状态多，等价性需 300k 拍差分） | 先做 F1，避免同时动 §5.5 与写口 |
| **F3** | 新建 `rtl/back2/cmt_stage.v`：把未编号 §EXP-R3b（4 槽暂存 + 16 深 FIFO）搬出并**恢复编号** | 198 | 2468–2665 | **0**（纯搬移） | 中性 | 低 | 与 §13 的"训练 FIFO"子块（2746–2758）合并到同文件 |
| **F4** | 把 `fp_cvt_map`/`fp_op_map` 与 xRET/维护译码归入 `rtl/decode/`（新建 `fp_map.v` / `ext_decode.v`），**2B 侧改例化引用** | 50 + 25 | 394–443、2336–2360 | **0**（对 2B 是搬移）；若同时让 `core_top.v` 也引用同一份，可消除 §3 D4 的第二份拷贝 | 中性 | 中（`core_top.v` 属 2A 核，**本审计不建议动**；只先做 2B 侧单一真源） | 需确认 `core_top.v` 不在同一综合脚本内被改 |
| **F5** | 用**具名函数/宏**替换 19 处手写年龄减法与 13 处"窗口内"谓词：`BACK2_AGE(x)`、`BACK2_IN_WIN(x)` | 0（替换） | 1241/1242/1255/1516/1615/1618/1811/1818–1823/2035/2264/2265/2277/2278/2771；13 处 `< rob_cnt_w` | **−30 ~ −120 LUT 预估**（6 bit 减法器去重；综合本可 CSE，收益有限） | 中性偏好 | 低（纯重构，可逐点等价性证明） | 无 |
| **F6** | 把 u/p/w 三族的 **9 条重复 1 bit 标志译码**合并为单个位宽参数化访问器 | 0（替换） | 247/248/250/251/252/253/254/256/267 ↔ 285–289/326–333 | **−20 ~ −80 LUT 预估**（多数单 bit 位选已被优化，收益主要来自可读性） | 中性 | 低 | `p_*` 名字受 TB 层次调用冻结 ⇒ **只改 `u_*`/`w_*`，`p_*` 名字与签名不动** |
| **F7** | `backend_top.v:983-988` 的 6 条 `iq_free_ok` 展开改 `generate` 循环 | 0（替换） | 983–988 | **0** | 中性 | 极低 | 无 |
| **F8** | 更新 `iq.v:52-54` 的 `o_sel_uop`（300 bit × 6）与 `iss_uop` 兼容口：在单测 TB 迁到 `o_sel_nq` 后**删端口** | 0（删端口） | `iq.v:133/168`；`backend_top.v:1282-1377` 例化 | **0**（综合已剪除） | 中性 | 中（**依赖 sim/unit TB 改造**，属跨任务） | TB 改造完成后 |

**合计预估**：净面积 **−0 ~ −350 LUT（预估）**，即**远不足以**构成一个面积候选
（对照 N34A 的门槛 ≥1,500 Slice LUT）。
**本审计的结论因此是：拆分的价值在"可读性/可维护性/单点真源"，而非面积。**
若母 Agent 要追面积，应优先走 N34A §5 的 LHT/LOCAL 等真实面积候选，**不要为面积做本次拆分**。

---

## 7. 遗留与风险

1. **`rebuilt` 归因不可作因果**（§4.1 已登记）：本报告的 per-instance LUT 只能作量级参考；
   若需因果级归属，须按 N35A 的做法做**连通性锥**（`n35a_rob2.tcl` 口径），本任务未做（超范围）。
2. **`p_*` 签名被外部 TB 冻结**：`backend_top.v:277-278` 自陈被 `sim/unit/tb_back2_lockstep.sv`
   按层次名调用 ⇒ 任何重命名都会**静默破坏 TB**。F6 已据此限定改动面。
3. **D9（IQ 入队许可双实现）有静默失败模式**：`iq.v:108` 明示"总空位够、某 bank 放不下 ⇒
   静默丢项"。当前 `backend_top.v:983` 用的是 `iq_wr_cap`（bank 上界）而非 `free_cnt`，口径一致，
   但**这是靠两处注释同步维持的**，无编译期/仿真期断言保护。
4. **契约注释已过期**：`lsq_simple.v:775` 仍称"同拍最多 4 条 store 提交"，与 `COMMIT_W=2` 不符（§5 附带记录③）。
5. **本审计未运行任何仿真/综合**：所有面积/时序数字均标"**预估**"，不得直接引用为收益承诺。

---

## 8. 可复现命令（全部只读；`cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu`）

```bash
# 0) 冻结基准与综合报告哈希
git rev-parse HEAD
git diff d00eb03 HEAD --name-only                 # 期望仅 fpga/area-optimization-report.md
git diff --stat d00eb03 -- rtl/                   # 期望空
sha256sum fpga/out/synth_2b_n35b_16.667ns_utilization.rpt \
          fpga/out/synth_2b_n35b_16.667ns_utilization_hier.rpt

# 1) 模块内多职能：段表 / 块普查 / 职能关键词
grep -nE "^\s*//\s*[0-9]+(\.[0-9]+)*\s+\S" rtl/back2/backend_top.v
grep -cE "^\s*always"  rtl/back2/backend_top.v      # 20
grep -cE "^\s*assign"  rtl/back2/backend_top.v      # 270
grep -cE "^\s*function" rtl/back2/backend_top.v     # 108
grep -cE "^\s*generate" rtl/back2/backend_top.v     # 13
grep -c "BACK2_Q_ALU0" rtl/back2/backend_top.v      # oq 分配唯一处

# 2) 端口数 / 行端口密度（对照 front4）
for f in rtl/back2/*.v rtl/front4/front4_top.v; do \
  printf "%-32s %5s lines %3s ports\n" $f $(wc -l <$f) \
    $(awk '/^module /{m=1} m{b+=gsub(/input|output|inout/,"&")} m&&/\);[ ]*$/{exit} END{print b}' $f); done

# 3) 扇出热点（宽/深信号 + cross-module）
grep -nE "x_i2_uop" rtl/back2/backend_top.v | wc -l          # 106
grep -nE "iq_wuop|rob_pay_w|cmt_pay|x_i2_uop" rtl/back2/backend_top.v | head
for s in epoch squash_idx rob_head iss_ready free_cnt; do \
  printf "%-12s %s\n" $s "$(grep -rl "$s" rtl/back2/*.v rtl/front4/*.v | tr '\n' ' ')"; done

# 4) 重复实现（布局 / 函数族 / 公式 / 原语）
grep -c "define BACK2_" rtl/back2/back2_params.vh
for p in BACK2_U_ BACK2_UB_ BACK2_IQN_ BACK2_IW_ BACK2_NQ_ BACK2_RB_; do \
  echo "$p"; grep -rln "\`$p" rtl/; done
grep -nE "^\s*function\b" rtl/back2/backend_top.v          # 108 行，肉眼可分 u/p/w 三族
grep -n "fp_cvt_map\|fp_op_map" rtl/back2/backend_top.v rtl/top/core_top.v
grep -n "wsel\[gw\]" rtl/back2/rob.v ; grep -n "wire \[1:0\] lw =" rtl/back2/backend_top.v
grep -nE "\-\s*rob_head_w" rtl/back2/backend_top.v | wc -l  # 19（手写年龄）
grep -nE "< *rob_cnt_w"    rtl/back2/backend_top.v | wc -l  # 13（窗口内谓词）
grep -nE "rank|_ord\b" rtl/back2/rename.v rtl/back2/lsq_simple.v rtl/back2/backend_top.v
grep -n "a_n\|wr_ok" rtl/back2/iq.v ; grep -n "iq_free_ok\|iq_room_ok" rtl/back2/backend_top.v

# 5) 单模块高负载（LUT/FF 归属）
grep -nE "^\|     u_[a-z0-9_]+ " fpga/out/synth_2b_n35b_16.667ns_utilization_hier.rpt
grep -nE "^\| Slice (LUTs|Registers)" fpga/out/synth_2b_n35b_16.667ns_utilization.rpt

# 6) 可读性抽样
grep -n "p_lq" rtl/back2/backend_top.v                        # 仅定义，0 调用
grep -nE "//.*(\.v|core_top|tb_csr_file)[\`: ]*[0-9]{3,4}" rtl/back2/backend_top.v   # 7 处 文件:行号
grep -nE "//.*与 [0-9]{3,4}-[0-9]{3,4}" rtl/back2/backend_top.v                      # 1 处 裸行区间
grep -n "o_sel_uop\|iss_uop" rtl/back2/iq.v
grep -n "同拍最多 4 条 store" rtl/back2/lsq_simple.v

# 7) 本报告 fail-closed 自检
bash fpga/scratch/audit1_check.sh                            # 期望末行 AUDIT1: PASS
```

---

## 9. 证据清单（fail-closed 计数；`AUDIT1: PASS` 要求 ≥20 条 + ≥2 多职能 + ≥3 跨模块重复）

| ID | 维度 | 证据（一句话） | 引用 |
|---|---|---|---|
| E01 | 多职能 | `backend_top.v` §4 单段 312 行内混合重命名请求/资源检查/派发/ROB 载荷拼接/CSR 串行化/STQ-LQ 分配 6 职能 | `backend_top.v:888-1199` |
| E02 | 多职能 | `backend_top.v` §9 单段 318 行内混合提交有效/架构 RAT/free-list 回收/CSR 写/CDQ 入队/训练/检查点释放 7 职能 | `backend_top.v:1873-2190` |
| E03 | 多职能 | §13 的单个 133 行 always 内含 MDU-FPU 在途+写口挂起+STQ 表+LQ 表+检查点表+训练 FIFO+统计 6+ 职能 | `backend_top.v:2671-2803` |
| E04 | 多职能 | §2 单段 193 行内含 4×decoder 例化+uop 打包+`oq` 分配+unsup/illegal+rs 使用位+前置译码 6 职能 | `backend_top.v:671-863` |
| E05 | 多职能 | §5.5 单段 110 行内含 BRAM 写口分解+读口仲裁+让位规则+bank 路由+6×4:1 交叉开关 4 职能 | `backend_top.v:1387-1496` |
| E06 | 多职能 | §10 单段 91 行内含整数/浮点读口仲裁+写口 6→4 物理合并+FLD NaN-box 3 职能 | `backend_top.v:2191-2281` |
| E07 | 多职能 | §0 单段 236 行内含 6 族纯函数（u/p/w 取值 + pack + 分支类别 + FP 映射），95/108 函数是字段取值器 | `backend_top.v:209-444` |
| E08 | 多职能 | 未编号 §EXP-R3b（198 行）打断 §12→§13 编号；其"训练 FIFO 写口"与 §13 的 FIFO 状态更新分居两段 | `backend_top.v:2468-2665` vs `2746-2758` |
| E09 | 跨模块重复 | 同一 uop 有 6 套位域布局共 197 宏；`backend_top` 是唯一全用 6 套者（330 引用）> rob(4 套/63) > iq(3 套/36) | `back2_params.vh`；`backend_top.v`；`rob.v`；`iq.v` |
| E10 | 跨模块重复 | 9 条 1 bit 标志宏在 u/p/w 三族重复译码，7 条各实现 3 次（含 `BACK2_UB_IS_CSR`） | `backend_top.v:247-267` ↔ `285-289` ↔ `325-333` |
| E11 | 跨模块重复 | `pack_iqn`(iq.v) 与 `pack_iw`(backend_top.v) 是同一 uop → 两种窄载荷的重复重打包，共享 5 组源字段 | `iq.v:142-159`；`backend_top.v:343-370` |
| E12 | 跨模块重复 | `fp_cvt_map`/`fp_op_map` 在 `core_top.v` 与 `backend_top.v` 各一份，靠注释"必须逐条等价"维系 | `core_top.v:496,517`；`backend_top.v:394,410`；自陈 `379-380` |
| E13 | 跨模块重复 | 4 bank 写口轮转公式逐位同式出现在 rob 与顶层，顶层注释自陈"与 rob.v §1.5 的 wsel 逐位同式" | `rob.v:364,397,398`；`backend_top.v:1411,1413,1415`；自陈 `1404` |
| E14 | 跨模块重复 | 年龄原语 `(idx−head) mod ROB_N`：rob 唯一点 + iq 模块内唯一点，但 `backend_top.v` 仍手写 **19 处** | `rob.v:351`；`iq.v:249-253`；`backend_top.v:1241/1242/1255/1516/1615/1618/1811/1818-1823/2035/2264-2265/2277-2278/2771` |
| E15 | 跨模块重复 | "仍在 ROB 窗口内"谓词 `(x−head)<cnt` 在顶层内联 **13 次**，未命名未函数化 | `backend_top.v`（`grep -cE "< *rob_cnt_w"`）；`rob.v` `cnt_o` |
| E16 | 跨模块重复 | lane 压缩序号（前缀和）4 处独立实现：`ord_r`/`lg_rank`/`dr_rank`/`q_ord` | `rename.v:269-279,449-459`；`lsq_simple.v:813-824`；`backend_top.v:905-912` |
| E17 | 跨模块重复 | IQ 入队许可同一不变式两侧各算一遍，且 `iq.v` 自陈"静默丢项"风险 | `iq.v:367-374`、`iq.v:108`；`backend_top.v:904-912,983-989` |
| E18 | 跨模块重复 | store"已提交但永不落地"契约横跨 rob 提交链 / top 入队许可 / lsq CDQ 三模块，顶层注释直接引 `rob.v:213` | `lsq_simple.v:773-827`；`backend_top.v:1937-1961` |
| E19 | 扇出热点 | `x_i2_uop` 212 bit × 6 队列 = 1272 bit、文本引用 **106** 次，为后端最高扇出网 | `backend_top.v:618` |
| E20 | 扇出热点 | `iq_wuop` 单条 7200 bit 打包向量横跨 6 个 IQ 实例 | `backend_top.v:545,1282-1372` |
| E21 | 扇出热点 | `cmt_pay` 450 bit × 19 引用，是 `p_*` 函数群唯一扇入 | `backend_top.v:627`；`n35a_report.md:339` |
| E22 | 扇出热点 | 跨模块控制扇出：`epoch` 8 模块 / `squash_idx` 5 / `rob_head` 4 / `iss_ready` 3 | §2.2 |
| E23 | 扇出热点 | `p_*`（21 函数）签名被外部 TB 按**层次名**调用而冻结，注释明文"名字与签名不得改" | `backend_top.v:277-278` |
| E24 | 高负载量化 | backend_top 子树 104,151 LUT = 全核 **82.2%**；自身 627 LUT / **3,479 FF** | `utilization_hier.rpt:28-29`；`utilization.rpt:34,39` |
| E25 | 高负载量化 | 面积集中在子模块：lsq 22,859 / rob 15,442 / 6×iq 13,267 / iwmem 9,986 / ren_f 11,950 | `utilization_hier.rpt:88,457,68-73,74,455` |
| E26 | 高负载量化 | 结构度量：backend_top **2813 行 / 116 端口 / 270 assign / 108 函数**，行端口密度 24.2 | §4.2 |
| E27 | 高负载量化 | 对照 `front4_top`：112 端口却仅 1 always + 7 assign，行端口密度 **3.2**（为 backend_top 的 1/7.6） | `front4_top.v:344-359` |
| E28 | 高负载量化 | `rebuilt` 归因不可作因果（子实例合计+自身 = 104,614 ≠ 报告 104,151，差 463） | `utilization_hier.rpt`；`n35a_report.md:73-80` |
| E29 | 可读性 | `fp_cvt_map`/`fp_op_map` 50 行 FP 译码住在顶层，与 `core_top.v` 重复 | `backend_top.v:394-443` |
| E30 | 可读性 | §5.5 发射宽载荷内存（110 行）住在顶层，写口公式与 rob 重复 | `backend_top.v:1387-1496` |
| E31 | 可读性 | `p_lq` 零调用者死函数，注释自陈仅为"位域真源完整" | `backend_top.v:293-295` |
| E32 | 可读性 | **8 行**注释引用绝对行号/文件+行号（7 处 `文件:行号` + 1 处裸区间 `"与 2105-2106"`），谓词/契约缺名 | `backend_top.v:174,802,1509,1867,1945,2304,2330,2345` |
| E33 | 可读性 | `iq_free_ok[0..5]` 手工展开 6 遍而非 `generate`；`o_sel_uop` 300 bit×6 兼容口保留 | `backend_top.v:983-988`；`iq.v:52-54,133,168` |
| E34 | 可读性 | 契约注释过期：`lsq_simple.v:775` 仍称"同拍最多 4 条 store 提交"，`COMMIT_W` 实为 2 | `lsq_simple.v:775`；`backend_top.v:507-509` |
| E35 | 高负载量化 | 后端子模块职能/接口：lsq 80 端口含 3 子系统；prf 99 行 11 端口为分离度模板 | §1.2 |

**AUDIT1: PASS**
