# T5 报告 —— 非 FPU 域 0.507 ns 时序收口 + regress 23/23 恢复

> 任务：把全核布线 @60 MHz（16.667 ns）的 **WNS 由 −0.507 ns 收到 ≥ 0**（90 个失败端点
> 全在非 FPU 域：lsu/ptw/pmp/fetch/core_top 的 M 级），并恢复 `./scripts/regress.sh`
> 的 **23/23 PASS**。
> 项目根 `/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev 分支，基线提交 `ac81129`）；
> Vivado 2023.2 一律经 `./fpga/run_vivado_batch.sh`（三坑统一入口）。

---

## 一、结论速览（判据逐条）

| # | 判据 | 结果 | 证据 |
|---|---|---|---|
| ① | `impl.tcl 16.667` rc=0 且**布线 WNS ≥ 0**（失败端点 0） | ✅ **WNS = +0.031 ns**，TNS = 0，**失败端点 0 / 49 214**，Fmax ≈ **60.11 MHz** | §六 |
| ② | `./scripts/regress.sh` → `REGRESS: 23/23 PASS` | ✅ **`REGRESS: 23/23 PASS`**（运行 23/通过 23/跳过 0/失败 0，总时长 8 min 19 s；`tb_m3_ddr3` 走放宽档通过） | §八 |
| ③ | 功能回归 I 39/39、PMP* 63/63、Sv 29/29、F 80/80、D 106/106 | ✅ **全绿**（另加 M 8/8） | §五 |
| ④ | 反证链：bypass 新增寄存级 ⇒ **布线 WNS 必须变差**；`cp` 恢复 md5 一致 | ✅ **+0.031 → −0.503 ns**（恶化 0.534 ns，失败端点 0 → 46）；`cp` 恢复后 md5 三方一致；未用 git checkout/stash/reset | §七 |
| ⑤ | 交付说明（打拍路径/复位口径/语义论证、PBLOCK 实验过程与结论、`tb_m3_ddr3` 处置、前后 WNS/Fmax） | ✅ 本文件 §四/§六/§八/§九 | — |

**一句话**：把 PMP 的 NAPOT 掩码解码（6 级 LUT + 跨模块长线）换成恒等式 `a^(a+1)`、
把优先级网络换成显式共享的前缀或树、并给 lsu 的地址入口加一级 M 级寄存副本，
**全核布线 WNS 由 −0.507 ns → +0.031 ns（失败端点 90 → 0，LUT −10.7 %）**，
原先 100 % 落在非 FPU 域的失败端点**全部清零**——全核最差路径重新回到 FPU 内部
（+0.031 ns，未变负），功能回归与单元回归全绿。

---

## 二、命令与产物索引（全部可复现）

| 步骤 | 命令 | 产物 |
|---|---|---|
| 冻结 RTL md5 | `find rtl sim/unit -name '*.v' -o -name '*.sv' -o -name '*.vh' \| sort \| xargs md5sum \| md5sum` | `970d1271e245cde9892d168cfd3590a2` |
| 综合 60 MHz | `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667` | `fpga/out/synth_16.667ns_timing_summary.rpt`（副本 `t5_final_synth_16.667ns_timing_summary.rpt`）、`post_synth_16.667ns.dcp` |
| 布线 60 MHz | `./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 16.667` | `fpga/out/impl_16.667ns_timing_summary.rpt` |
| 失败端点全量归因 | `./fpga/run_vivado_batch.sh fpga/scratch/t4_cones.tcl fpga/out/post_route.dcp 16.667 t5route` | `fpga/out/t4_t5route_failpaths.tsv` / `t4_t5route_cones.tsv` |
| 物理位置/距离归因（**只读分析，本次新增**） | `./fpga/run_vivado_batch.sh fpga/scratch/t5_place.tcl fpga/out/post_route.dcp 16.667 <tag>` | `fpga/out/t5_<tag>_place_dist.tsv` / `t5_<tag>_bbox.tsv` |
| post-synth（未改名）失败/最差路径（**只读分析，本次新增**） | `./fpga/run_vivado_batch.sh fpga/scratch/t5_synthpaths.tcl fpga/out/post_synth.dcp 16.667 <tag>` | `fpga/out/t5_<tag>_synthpaths.rpt` / `.tsv` |
| 单元回归 | `./scripts/regress.sh` | 控制台 + `sim/unit/*.vvp` |
| 功能组 | `./sim/arch_test/run.sh --group <G> --jobs 16` | `sim/arch_test/work/*/result.txt` |
| 反证 | `/tmp/t5_bypass`（RTL 副本；`cp` 备份/恢复，**未用 git checkout/stash/reset**） | §七 |
| 布局/约束实验（只到 place） | `./fpga/run_vivado_batch.sh fpga/scratch/t5_place_exp.tcl ExtraNetDelay_high` | `fpga/out/t5_placeexp_ExtraNetDelay_high.rpt` |
| 布局档**全流程**对照（不改交付档） | `RV32_IMPL_TAG=implalt ./fpga/run_vivado_batch.sh fpga/scratch/t5_impl_alt.tcl 16.667` | `fpga/out/implalt_16.667ns_*.rpt`、`t5_alt_post_route.dcp` |
| 表达式级等价性（临时 TB，不进仓库） | `cd /tmp/t5_pmp && iverilog -g2012 -s tb_pmp_expr_equiv -o expreq.vvp tb_pmp_expr_equiv.sv && vvp expreq.vvp` | 控制台（100 114 + 65 536 组逐位一致） |

★ 本次新增的 4 个**只读分析/实验**脚本（均落在 `.gitignore` 的 `fpga/scratch/`，非交付物）：
`t5_place.tcl`（失败端点物理 LOC/曼哈顿距离 + 关键层次包围盒）、
`t5_synthpaths.tcl`（post-synth 网表上的最差路径全文，名字未被 opt/phys_opt 改写）、
`t5_place_exp.tcl`（只到 place 的布局 directive 对照）、
`t5_impl_alt.tcl`（`ExtraNetDelay_high` 全流程对照档，产物写 `implalt_*`，不覆盖交付档）。

---

## 三、归因：这 0.507 ns 到底是什么

### 3.1 两个簇，一个共同结构

`fpga/out/t4_t4route_failpaths.tsv`（90 条，T4 布线后）按起点/终点聚类后**只有两族**：

| 簇 | 条数 | 起点 → 终点 | 最差 | 逻辑级 | logic/route |
|---|---|---|---|---|---|
| **A** | 51 | `em_imm_val_reg[1]_replica` → `m_state_q*/m_exc_tval_q*/m_exc_q/m_exc_cause_q*/m_rd_data_q/m_done_q/m_cmo_probe_q/m_page_fault_q/l1d_maint_*_q` | −0.507（17.049 ns） | 33~35 | 6.62 / **10.43**（route 61 %） |
| **B** | 39 | `u_csr_file/pmp_addr_r_reg[*]` → `fd_valid*/fd_exc_valid`、`u_ptw/fault_{,cause_}r_reg`、`m_state_q*`/`m_pa_q*` 的 CE | −0.473（16.991 ns） | 27~30 | 4.23 / **12.76**（route **75 %**） |

两簇的**公共结构**是：

```
[地址：em_rs1_val + em_imm_val] 或 [PMP 配置：pmp_addr_r]
        ↓
   pmp_check（16 项：NAPOT 掩码解码 → 32 位区间比较 → 优先级选择）
        ↓
  lsu 异常/cause 选择  →  M 级 FSM 的 D/CE（m_state_q / m_exc_* / m_pa_q …）
```

### 3.2 三个可量化的"罪魁"（全部取自报告原文，可逐行复核）

1. **PMP 的 NAPOT 掩码解码太长，而且横跨全芯片**。
   `t5_s60_synthpaths.rpt` 第 7 条（`pmp_addr_r_reg[249] → fd_exc_valid_reg`，布线后 −0.473 ns）
   的头段是 **6 级 LUT6**（`i___74_i_16__0 → _13__0 → _10__0 → _7__0 → _4__0 → _1__0`），
   累计 **4.77 ns（占整条路径 28 %）**，其中 route 4.94 ns 全是跨模块长线：
   ```
   net (fo=68, routed) 1.771 ns   u_csr_file/pmp_addr_o[243] → ...
   net (fo=36, routed) 0.804 ns   → u_fetch_unit/u_pmp_chk_hi/...
   ```
   —— 这正是 `napot_ones`（32 位优先编码）+ 变长移位生成的掩码：**5 个 pmp_check 实例
   （lsu×2 / fetch×2 / PTE×1）各自重复算一遍**，配置寄存器 512 bit + cfg 128 bit 的扇出
   把这段逻辑摊到 X84~X114 的整片区域。

2. **优先级/选择网络被复制成一片**（clusters A、B 的尾段，也是最长的一段）。
   布线后网表里出现大量 `*_rewire_rewire` / `*_replica_*` 副本（`u_csr_file/fd_valid_i_*`、
   `u_lsu/u_pmp_a/i___*`），逐级跳 0.3~0.9 ns，**10 级 route 合计 5.4 ns（占 32 %）**——
   来自 `no_prior_hit[gj] = ~|any_flat[gj-1:0]` 那 15 条**宽度各异**的独立归约。

3. **lsu 的地址入口是纯组合加法器**。
   lsu 是纯组合模块，`mem_va = rs1_i + imm_i`（32 位加法器）以及由它派生的
   `hi_addr/拆笔/beat 地址/mtval`、`acc_bytes_i` 都挂在 `em_rs1_val + em_imm_val` 上
   ⇒ cluster A 的 51 个失败端点**全部**以 `em_imm_val_reg[1]` 为起点
   （最差 17.049 ns 里，头段"加法器 → pmp_b 比较器数据口"占 2.46 ns，
   且中间串了一条 `fo=68` 的 0.812 ns 长线）。

### 3.3 为什么不是"摆得太散"（PBLOCK 实验结论）

`t5_place.tcl` 对 90 个失败端点逐条取起点/终点 LOC 并算曼哈顿距离，同时给出关键层次包围盒：

```
器件 SLICE 网格 X[0..163] Y[0..249]（33 650 site）
失败端点曼哈顿距离：min=7  med=23  max=57      ← 不是"两端隔半颗芯片"
u_lsu/u_pmp_a  : cells=1733 X[48..104] Y[91..142]   ← 比较器**本身已经聚在一起**
u_lsu/u_pmp_b  : cells=1766 X[21..85]  Y[93..148]
u_fetch_unit   : cells=4737 X[0..132]  Y[69..178]
u_csr_file     : cells=26459 X[4..141] Y[26..181]   ← 26 k cells，占满 84 %×62 %
pmp_addr_r_reg : X100 一列；m_state_q_reg : X36~39 Y122~128
```

**结论**：pmp 比较器、pmp 配置寄存器、M 级 FSM 三者本身都各自聚团，问题在于
**同一个组合锥要在它们之间来回穿 10~20 跳**（每跳 0.3~0.9 ns）。
即"逻辑级数太多 + 扇出复制摊开"而不是"单个模块被扔到芯片另一头"。
因此本任务**没有采用 PBLOCK**（详见 §六.3 的策略实验记录），而是**从网表结构上砍级数**：
级数少了 ⇒ 需要穿过的跳数自然少 ⇒ route 与 logic 同时下降。

---

## 四、RTL 改动（两处，均"只改时序、不改功能语义"）

### 4.1 `rtl/mem/pmp_check.v`：NAPOT 掩码改用恒等式（删 `napot_ones`）

```verilog
// 改前：数低位连续 1 的个数 n（32 位优先编码）+ 变长移位生成低 n+1 位掩码
napot_wordmask = (1 << (n+1)) - 1;                  // n+1 ≥ 32 时特判全 1
// 改后：
napot_wordmask = a ^ (a + 32'd1);
```

**等价性证明**（写进 RTL 注释）：设 `a` 低位形如 `…yyy0 1^n`（n = 低位连续 1 的个数，
0 ≤ n ≤ 32），则 `a+1 = …yyy1 0^n` ⇒ `a ^ (a+1)` = 低 `n+1` 位全 1、其余位 0，
正是"低 n+1 位掩码"；`n+1 ≥ 32` 的三个边界（`a=2^31-1`、`a=2^32-1`、`a=2^k-1`）
逐位展开同样得到全 1，与原"特判"分支一致。

**收益**：6 级 LUT + 跨模块长线 ⇒ 1 条 32 位增量进位链 + 1 级异或；
全核 LUT 由 **59 427（44.15 %）降到 53 066（39.42 %）**（−6 361，−10.7 %）。
**反证**：表达式级穷举（§七.3）100 114 组掩码逐位一致。

> 说明（cosmetic）：原 `napot_ones` 专属的 `localparam NAPOT_FIELD_W`（= ADDR_W，仅该函数使用）
> 在改写后**成为未引用常量**。**故意保留**：删除它会改动 RTL 文本 ⇒ 使本报告全部
> 时序/回归证据（RTL 快照 md5 `970d1271…`）与已跑完的 1.5 h 实现结果**失去对应关系**；
> 未引用 localparam 不产生任何逻辑，留待下一次真正需要改该文件时一并清理。

### 4.2 `rtl/mem/pmp_check.v`：优先级前缀改为显式共享的 Hillis-Steele 树

```verilog
// 改前：15 条宽度各异的独立归约（工具为每条各建一份前缀逻辑，实测被复制成一片）
assign no_prior_hit[gj] = ~|any_flat[gj-1:0];
// 改后：⌈log2 N⌉ = 4 级前缀或，每级只由上一级推得（中间结果唯一真源）
assign pr[0] = any_flat;
assign pr[k] = pr[k-1] | (pr[k-1] << (1 << (k-1)));   // k = 1..4
wire [PMP_ENTRIES-1:0] prior_any = pr[4] << 1;
wire [PMP_ENTRIES-1:0] no_prior_hit = ~prior_any;
```
**等价性证明**：归纳得 `pr[k][i] = |any[i-(2^k-1) .. i]`（越界位 0）⇒ 4 级后
`prior_any[i] = pr[4][i-1] = |any[0..i-1]`（i=0 ⇒ 0）⇒ 与原逐位归约逐位相同。
**反证**：**穷举全部 2^16 个 `any_flat` 取值**，`no_prior_hit` 逐位一致（§七.3）。

### 4.3 `rtl/top/core_top.v`：新增 M 级访存 VA 寄存副本 `m_lsu_va_q`

| 项 | 内容 |
|---|---|
| 信号 | `reg [31:0] m_lsu_va_q`（§9.1 声明处） |
| 打拍点 | `M_S_IDLE` 且 `m_data_want=1` 的那一拍（与本笔 `m_pa_q` 锁存**同一拍、同一分支**，三个子分支之前 ⇒ IDLE→ISS 与 IDLE→TR 都锁存） |
| 复位口径 | 与其它 M 级数据寄存器一致：**仅异步复位清 0**（陈旧值无害：每个进入 ISS 的访存起点都重写，ISS 之外无人消费） |
| 用法 | lsu 例化的地址入口改接 `.rs1_i(m_lsu_va_q), .imm_i(32'd0)` ⇒ 综合时 `m_lsu_va_q + 0` 折叠，lsu 内部的 32 位地址加法器**消失**，全部地址派生（`hi_addr`/拆笔/beat 地址/`mtval`/AMO·CMO 地址）与 PMP 比较改由**寄存器**起步 |
| 影响面 | `lsu.v` **一行未改**（端口契约不变，`tb_lsu.sv` 仍按原契约 `rs1_i+imm_i` 驱动）；`core_top.v` 的其它 `m_va` 用法（`m_store_strb`、`m_fp8_misalign`、`m_exc_tval_q` 的 D 端、`m_ptw_req_va`、`l1d_vaddr_d`）**保持不变** |

**语义等价性（逐位）论证**：
1. lsu 的**全部输出**只在 `m_state_q == M_S_ISS` 拍被消费 —— 已逐条 grep 核对：
   `m_l1d_go`(§9.6)、`m_cmo_probe_go`/`l1d_maint_*_d`(§9.7)、`m_mmio_*`/AMO/CMO 判决（M_S_ISS 分支）、
   `lsu_amo_rdata_src`(只喂 amo_unit，其输出同样只在 ISS/M_S_AXI 被捕获)；
   其余 lsu 输出（`mem_va_o/mem_pa_o/mem_addr_o/split/beat*/misaligned/pmp_deny/no_axi/xip/
   axi_*/amo_busy/eff_*/need_perm/cmo_block_*`）在 `core_top.v` 中**只有声明与端口连接，无消费者**。
2. 进入 `M_S_ISS` 的必要条件是本 EM 槽在 `M_S_IDLE` 拍 `m_data_want=1`（该拍置 `m_issued_q`），
   此后 `m_busy=1` ⇒ `pipe_adv=0` ⇒ **E/EM 槽全程冻结**（直到本笔访存完成回 IDLE、
   `m_issued_q` 由 `em_go` 清零）。
3. ⇒ 在**所有** M_S_ISS（含 8 B 访存的第二相、AMO/SC 的写相、M_S_DRAIN 重试后回到 ISS）
   拍上，`em_rs1_val/em_imm_val` 与锁存拍逐位相同 ⇒ `m_lsu_va_q == em_rs1_val + em_imm_val` 逐位相同。
4. 反面核对（**唯一**的非 ISS 消费者）：`M_S_AXI` 里的 `m_rd_data_q <= lsu_amo_rd_old` /
   `m_amo_wdata_q <= lsu_amo_wdata`（AMO/SC 第二相）—— 该状态同样满足"EM 冻结"，
   `m_lsu_va_q` 仍等于组合式；且 AMO/SC 的 rd 值由 `rsv_hit = (word_addr == rsv_addr_r)` 决定，
   `rsv_addr_r` 也在 IDLE 拍由同一个 VA 载入（`amo_unit` 的 `rsv_addr_r <= word_addr`），
   两者**同源同拍**，不存在错位。

---

## 五、功能回归（判据③）

| 组 | 结果 | 日志 |
|---|---|---|
| `rv32i/I` | ✅ **39/39 PASS** | `/tmp/t5_arch_rv32i_I.log` |
| `tests/priv/PMP*` | ✅ **63/63 PASS** | `/tmp/t5_arch_tests_priv_PMP__.log` |
| `Sv` | ✅ **29/29 PASS** | `/tmp/t5_arch_Sv.log` |
| `rv32i/F` | ✅ **80/80 PASS** | `/tmp/t5_arch_rv32i_F.log` |
| `rv32i/D` | ✅ **106/106 PASS** | `/tmp/t5_arch_rv32i_D.log` |
| `rv32i/M`（额外自查） | ✅ **8/8 PASS** | `/tmp/t5_arch_rv32i_M.log` |
| 单元 TB（关键 5 个，改动后先跑） | ✅ `tb_pmp_check` / `tb_lsu` / `tb_fetch_unit` / `tb_ptw` / `tb_csr_file` 全 PASS | `/tmp/t5_tb_*.rlog` |

`tb_pmp_check` 的 54 条断言全过（含 `NAPOT n=0/1/3`、`SPLIT-3a 整笔未全覆盖`、
`ALL16-idx15` 16 项优先级），说明 NAPOT 改写与优先级树改写**没有削弱任何既有覆盖**。

---

## 六、时序（判据①）✅

### 6.1 结果（布线后 60 MHz）

```
./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 16.667      # rc=0（19:02:19 → 19:30:24）
fpga/out/impl_16.667ns_timing_summary.rpt（Design State: Physopt postRoute）：
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints   WHS(ns) ...
      0.031        0.000                      0                49214      0.060 ...（THS 失败端点 0）
== impl.tcl: 布线后 WNS(setup) = 0.031 ns @ 16.667ns；WHS(hold) = 0.060 ns；Fmax ≈ 60.11 MHz；失败端点(前 100000) = 0
RESULT_IMPL_impl: OK WNS=0.031 WHS=0.060 FMAX=60.11 NFAIL=0
```

| 指标 | T4 基线（`ac81129`） | **T5** |
|---|---|---|
| **WNS（布线）** | −0.507 ns | ✅ **+0.031 ns** |
| TNS | −23.075 ns | ✅ **0.000 ns** |
| 失败端点 | **90** / 49 600 | ✅ **0** / 49 214 |
| WHS（hold） | +0.044 ns（0 失败） | +0.060 ns（0 失败） |
| Fmax 等价 `1/(T−WNS)` | ≈ 58.2 MHz | ✅ **60.11 MHz** |
| 全核 LUT（综合） | 59 427（44.15 %） | **53 066（39.42 %）**（−6 361，−10.7 %） |
| 全核 FF（综合） | 23 257（8.64 %） | 23 311（8.66 %）（+54 = `m_lsu_va_q` 32 + 复制） |
| 最差路径 | `em_imm_val_reg[1]_replica → m_state_q_reg[0]`（17.049 ns，34 级，route 61 %） | **`u_fpu/u_fma_d/r5_sum_tc_reg[0] → u_fpu/u_fma_d/u_round/b_sign_reg_srl2`**（16.305 ns，49 级，route 56 %） |
| 综合 WNS | +0.422 ns（0 失败端点） | +0.338 ns（0 失败端点；副本 `fpga/out/t5_final_synth_16.667ns_timing_summary.rpt`） |

**进程内轨迹**（`fpga/out/impl.vivado.log`，同一流程、同一 RTL）：

| 阶段 | 布局后 | `phys_opt AggressiveExplore` 后 | `phys_opt -retime` 后 | 布线后 | 收尾 `Explore` 后 |
|---|---|---|---|---|---|
| WNS | −1.138 | +0.032 | +0.032 | **+0.031** | +0.031 |

### 6.2 归因闭环：90 个失败端点 → **0**，且两簇全部退出关键路径

```
./fpga/run_vivado_batch.sh fpga/scratch/t4_cones.tcl fpga/out/post_route.dcp 16.667 t5route
→ fpga/out/t4_t5route_failpaths.tsv：只有表头（**失败路径条数 = 0**）
→ fpga/out/t4_t5route_cones.tsv：u_fpu 最差锥 slack=+0.338（16.179 ns）
```

`impl_timing_paths.rpt`（新）前 20 条按 slack 排序：

| 排名 | slack | 起点 → 终点 | 归属 |
|---|---|---|---|
| 1 | **+0.031** | `u_fpu/u_fma_d/r5_sum_tc_reg[0] → u_fpu/u_fma_d/u_round/b_sign_reg_srl2` | **FPU**（对齐 mid/sum → 舍入级） |
| 2~8 | +0.270 | `em_mem_size_reg[0]_replica → m_exc_cause_q/m_exc_tval_q` 的 CE | 非 FPU（原 cluster A 的残余） |
| 9~16 | +0.282~+0.338 | `u_fpu/u_fma_d/r2_prod_reg[6] → r3_brsh_reg`、`de_fp_op_reg[0] → u_cmp/u_lat/sr_reg` | FPU |
| 17~20 | +0.411 | `em_mem_size_reg[0]_replica → m_exc_*_q` 的 CE | 非 FPU |

**逐簇结账**：

| 原簇 | T4 状态 | T5 状态 | 归因 |
|---|---|---|---|
| B：`pmp_addr_r_reg[*]` → `fd_valid/fd_exc_valid`、`u_ptw/fault_*`、`m_state_q`/`m_pa_q` 的 CE（39 条） | 最差 −0.473 ns（16.991 ns，route 75 %） | **完全退出前 20**（`fd_valid`/`fd_exc_valid`/`fault_*` 已不在名单） | §4.1 NAPOT 掩码恒等式（砍掉 4.77 ns 的配置侧头段）+ §4.2 优先级树 |
| A：`em_imm_val_reg[1]_replica` → M 级异常/状态寄存器（51 条） | 最差 −0.507 ns（17.049 ns，34 级） | 起点退到 `em_mem_size_reg[0]`，最差 **+0.270 ns** | §4.3 `m_lsu_va_q` 寄存级（lsu 地址入口不再吃 `em_rs1*+em_imm` 组合加法器） |
| FPU 侧（本任务禁改） | +0.020 ns（`r3_prod → r3_brsh`） | ✅ **+0.031 ns（= 全核 WNS，**未变负**；路径变为 `r5_sum_tc → u_round/b_sign`）** | 零改动，仅受布局扰动（±0.01 ns 量级） |

> ⇒ **"90 个失败端点 100 % 在非 FPU 域"这一结论被彻底反转**：现在全核最差路径**回到 FPU 内部**
> （FPU 从"第二梯队"变回唯一压线项），非 FPU 域余量 +0.27 ns 以上。

### 6.3 布局/约束实验（T3 §7.3 建议项；结论：**不改布局约束**）

1. **物理位置/距离分析**（`fpga/scratch/t5_place.tcl`，本任务新增，只读）：
   见 §3.3 —— 90 个失败端点的起/终点曼哈顿距离 `min=7 / med=23 / max=57`（器件网格
   `X[0..163] Y[0..249]`），pmp 比较器（`u_lsu/u_pmp_a` X48..104 Y91..142）、
   pmp 配置寄存器（`pmp_addr_r_reg` 集中在 X100 一列）、M 级 FSM（`m_state_q_reg`
   X36..39 Y122..128）**各自都聚团**。⇒ 缺口不是"某两个模块被扔到芯片两头"，
   **PBLOCK 不是对症手段**；对症的是"砍组合级数"（每级省一次 0.3~0.9 ns 的跨区域跳）。
2. **布局 directive 对照**（`fpga/scratch/t5_place_exp.tcl`，同一份 post-synth 网表、只到 place）：

   | place_design -directive | 布局后 WNS | 失败端点 | 说明 |
   |---|---|---|---|
   | `ExtraTimingOpt`（impl.tcl 现用档） | −1.138 | （未打印） | 基线：全流程最终 **+0.031** |
   | `ExtraNetDelay_high`（面向"布线延时优先"，正对本设计 route 占比 56~75 % 的痛点） | **−0.121** | 19 | 见 `fpga/out/t5_placeexp_ExtraNetDelay_high.rpt` |

   **解读（谨慎）**：布局后 WNS 只是"估计值"，与本设计最终布线结果差得**很远**
   （现用档 −1.138 → 最终 +0.031）；因此"−0.121 更好"**不能直接判定**
   `ExtraNetDelay_high` 全流程一定更好。有鉴于此，本任务**另行跑了一次全流程对照**
   （`fpga/scratch/t5_impl_alt.tcl`，只把 place 指令换成 `ExtraNetDelay_high`，其余流程
   逐字相同，产物写 `implalt_*` / `t5_alt_post_route.dcp`，**不覆盖**交付档）：

   | 变体（同网表、同周期、同机） | 布线 WNS | TNS | 失败端点 | Fmax | 最差路径 |
   |---|---|---|---|---|---|
   | **交付档**：`ExtraTimingOpt`（`impl.tcl`，`impl_16.667ns_*`） | ✅ **+0.031** | 0.000 | 0 / 49 214 | 60.11 MHz | FPU `fma_d/r5_sum_tc → u_round/b_sign`（16.305 ns） |
   | 实验档：`ExtraNetDelay_high`（`fpga/scratch/t5_impl_alt.tcl`，`implalt_16.667ns_*` + `t5_alt_post_route.dcp`） | ✅ **+0.212** | 0.000 | 0 / 49 232 | 60.77 MHz | FPU `fma_d/u_round/b_rm → em_result_reg[9]`（16.369 ns） |

   **实测结论**：`ExtraNetDelay_high`（面向"净延时优先"）在本设计上**确实更好**：
   余量由 +0.031 ns 抬到 **+0.212 ns（≈7 倍）**，失败端点仍为 0，限幅项仍在 FPU 内部。
   **但本任务仍以 `ExtraTimingOpt` 档交付**（`impl.tcl` 未改），理由：
   ① 判据①已达成（WNS ≥ 0、0 失败端点），切换策略不改变任何验收结论；
   ② 反证链（§七）的主/对照两轮**都是在 `ExtraTimingOpt` 档下跑的**，若只切换交付档，
   A/B 就不在同一策略下，证据链会自相矛盾；要切换必须**同时重跑反证档**（各约 30 min）；
   ③ 因此把它作为**已验证、可直接采用的备选档**登记在 §九（含脚本与实测数字），
   由母 Agent/用户决定是否在下一阶段切换（切换只需改 `impl.tcl` 第 154 行一处 + 重跑）。

---

## 七、反证链（判据④）

### 7.1 方法与隔离

* 仓库 RTL **全程未动**（改动只在 `/tmp/t5_bypass` 的副本里做）；
* `cp` 复制仓库到 `/tmp/t5_bypass`（排除 `fpga/out`、`.vivado_home`、`.git`）；
* 在副本内把**新增的那一级寄存 bypass 成组合直连**（只改 lsu 例化的两行接线，
  其余 RTL 与主副本**逐字相同**，含 §4.1/§4.2 的两处 pmp_check 改写）：
  ```verilog
  -    .rs1_i            (m_lsu_va_q),
  -    .imm_i            (32'd0),
  +    .rs1_i            (em_rs1_val),
  +    .imm_i            (em_imm_val),
  ```
* 副本内独立跑 `synth.tcl` + `impl.tcl 16.667`（产物落 `/tmp/t5_bypass/fpga/out/`，不污染仓库）；
* **未使用** `git checkout/stash/reset/clean`。

### 7.2 结果（同机、同流程、同周期；只有 lsu 地址入口的两行接线不同）

| 变体 | **布线 WNS** | TNS | 失败端点 | WHS | Fmax 等价 | 最差路径（34 级） |
|---|---|---|---|---|---|---|
| **T5 主**（`m_lsu_va_q` 寄存级在位） | ✅ **+0.031 ns** | 0.000 | **0** / 49 214 | +0.060 | 60.11 MHz | `u_fpu/u_fma_d/r5_sum_tc_reg[0] → u_round/b_sign_reg_srl2`（**FPU**） |
| **T5 + bypass**（同一 RTL，仅把 lsu 地址入口改回 `em_rs1_val/em_imm_val` 组合直连） | ❌ **−0.503 ns** | −13.906 | **46** / 49 184 | +0.040 | 58.24 MHz | `em_rs1_val_reg[0] → m_state_q_reg[1]/D`（**正是原来那簇**，CARRY4=18 / LUT6=10） |

* **bypass ⇒ 布线 WNS 恶化 0.534 ns（+0.031 → −0.503）、失败端点 0 → 46** ⇒ 这一级寄存器是**承重的**，
  不是装饰；而且 bypass 后回到的最差路径**恰好就是 cluster A**（`em_rs1* → m_state_q`，34 级），
  与 §3.2 的归因闭环。
* **两处改动的因果拆分**（bypass 档 46 个失败端点的逐条归因，
  `/tmp/t5_bypass/fpga/out/t4_t5bypass_failpaths.tsv`）：

  | 变体 | 失败端点 | 起点 | 终点分布 |
  |---|---|---|---|
  | T4 基线 | 90 | `em_imm_val_reg[1]`(51) + `pmp_addr_r_reg[*]`(39) | cluster A + cluster B |
  | pmp_check 两处改写（bypass 档） | **46** | **全部** `em_rs1_val_reg` | `m_exc_tval_q`32 / `m_state_q`7 / `m_exc_cause_q`5 / `m_rd_data_q`1 / `m_exc_q`1（**cluster B 的 `fd_valid`/`fd_exc_valid`/`fault_*`/`m_pa_q` 全部消失**） |
  | T5 主（+`m_lsu_va_q`） | **0** | — | — |

  ⇒ **pmp_check 改写消除 cluster B（39 条）并顺带削掉 cluster A 的一部分；
  `m_lsu_va_q` 消除 cluster A 的残余 46 条**。两处改动各自对症、缺一不可。

### 7.3 仓库 RTL 未被反证实验污染（`cp` 证据，**未用 git checkout/stash/reset**）

```
# 反证副本里的 bypass 版本（供对照）
$ md5sum /tmp/t5_bypass_core_top.bypass.bak  /tmp/t5_bypass/rtl/top/core_top.v
a4ee7ec890b123373e08f3c083da124b  /tmp/t5_bypass_core_top.bypass.bak      ← bypass 版（组合直连）
a4ee7ec890b123373e08f3c083da124b  /tmp/t5_bypass/rtl/top/core_top.v

# cp 恢复（把仓库版拷回副本）后，两侧与仓库三者 md5 一致
$ cp <repo>/rtl/top/core_top.v /tmp/t5_bypass/rtl/top/core_top.v && md5sum ...
47d2b126e77bbe74ca8dc2052b2154f3  /tmp/t5_bypass/rtl/top/core_top.v        ← 恢复后 = 仓库版
47d2b126e77bbe74ca8dc2052b2154f3  <repo>/rtl/top/core_top.v
```

* 仓库 `rtl/**` 在反证实验期间**从未被写入**（bypass 只发生在 `/tmp/t5_bypass` 副本内）；
* 所有跑批结束后复测 RTL 快照 md5 仍为 `970d1271e245cde9892d168cfd3590a2`（§十）；
* 全程**未使用** `git checkout / stash / reset / clean`。

### 7.4 表达式级穷举等价性（pmp_check 两处改写的独立反证）

`/tmp/t5_pmp/tb_pmp_expr_equiv.sv`（临时 TB，**不进仓库、不进 regress 清单**）：

```
① NAPOT 掩码：比较 100114 组，不一致 0
② 优先级前缀：比较 65536 组，不一致 0      ← 穷举全部 2^16 个 any_flat 取值
TB_PMP_EXPR_EQUIV: PASS（NAPOT 掩码 100114 组 + 优先级前缀穷举 65536 组，逐位一致）
```

---

## 八、`tb_m3_ddr3` 处置与 regress 23/23（判据②）

### 8.1 选了哪条路，为什么

任务给了两条路：**(a)** `WIN_WORDS 4096→2048`（两侧同步 + 重生成内嵌数组）；
**(b)** `scripts/regress.sh` 墙钟超时按 TB 名放宽。**选 (b)**，理由：

1. **不损失任何覆盖**。(a) 要把 DDR3 遍历窗口砍半，而且窗口一改，**同文件里的
   `SUB_BASE/SUB_END`（"窗口尾页内 1 KiB"专项，0x3C00–0x4000）就落到新窗口之外**，
   `PROBE0/PROBE1` 与 `E_WIN_PAGES/E_WINW/E_WINR` 等 TB 侧期望值也要跟着重算，
   还要**重生成 TB 内嵌的 431 字程序映像**（`$readmemh` 式手写数组）——
   改一处要同步四处，任何一处漏改都会让 C3/计数判据静默失真。
   (b) 只动"墙钟兜底"这一个数字，**TB 自身的 1.2e6 拍预算与全部 C1~C10 判据一字未改**。
2. **失败本来就不是功能失败**（T4 报告 §三.3 有 A/B 证据）：原版 RTL 在同一台机上
   `timeout 300 vvp` 同样 rc=124；TB 日志 0 行 FAIL，进度/计数/结果区观测全部符合预期。
3. **放宽后仍有 2 倍以上余量**：T5 实测该 TB **单跑 805 s 通过**（`PASS`，见 8.2），
   放宽档 1800 s。

### 8.2 改动内容（`scripts/regress.sh`，只改墙钟口径）

```bash
TB_TIMEOUT_TB_M3_DDR3="${TB_TIMEOUT_TB_M3_DDR3:-1800}"
tb_timeout_for() { case "$1" in tb_m3_ddr3) printf '%s' "$TB_TIMEOUT_TB_M3_DDR3" ;;
                                   *)          printf '%s' "$TB_TIMEOUT" ;; esac; }
...
tb_to="$(tb_timeout_for "$stem")"; timeout "$tb_to" "$VVP" "$vvp_out" ...
```
* 其余 22 个 TB **仍守 300 s**（保留"多数 TB 挂死能快速暴露"的纪律）；
* 实际生效的秒数打进 FAIL 诊断（`124 = 超时 ${tb_to}s`）与启动横幅；
* 两个值都可用环境变量覆盖 —— **判据、锚点唯一性、FAIL 计数、"未捕获即失败"语义全部未动**。

### 8.3 tb_m3_ddr3 单跑证据（T5 RTL）

```
compiled @ 18:31:02
vvp rc=0 elapsed=805s
...
[tb_m3_ddr3] AXI 总计: AR=22415 AW=22395 R拍=22846 W拍=22488 首AR=0x1c000000
TB_M3_DDR3: PASS
```
（805 s 是**在两轮 Vivado 综合同时运行**的负载下测的；空载会更快。）

### 8.4 全量 regress（T5 判定）

```
== regress.sh：单 TB 超时=300s（★ T5：tb_m3_ddr3 用放宽档 1800s，其余守默认）
[ 1/23] tb_alu       ... [16/23] tb_m3_ddr3   top=tb_m3_ddr3   PASS  锚点=TB_M3_DDR3（整行命中 1 次，FAIL 0 行）
[23/23] tb_trap_ctrl                 PASS  锚点=TB_TRAP_CTRL_UNIT（整行命中 1 次，FAIL 0 行）
== regress.sh：总数=23 运行=23 通过=23 跳过=0 失败=0
REGRESS: 已通过 TB 清单（23 个）= tb_alu tb_axi_master_ctrl tb_bru tb_clint tb_csr_file tb_decoder
        tb_exe_ctrl tb_fetch_unit tb_fp_load_use tb_fpu tb_fpu_cmp_cvt tb_fregfile tb_l1d tb_l1i
        tb_lsu tb_m3_ddr3 tb_mdu tb_parcel_align tb_pc_gen tb_plic tb_pmp_check tb_ptw tb_trap_ctrl
REGRESS: 23/23 PASS
```

* **`REGRESS: 23/23 PASS`**（运行 23 / 通过 23 / 跳过 0 / 失败 0），`tb_m3_ddr3` 走放宽档通过
  （`锚点=TB_M3_DDR3 整行命中 1 次，FAIL 0 行`）；
* **总时长 8 min 19 s**（19:14:54 → 19:23:13，`stat /tmp/t5_regress.log`；期间两轮 Vivado
  实现流程同时在跑 ⇒ 空载只会更快）；
* 判据强度未变：锚点唯一性 / `FAIL` 零字样 / "未捕获即失败"三条全在，无任何跳过。

---

## 九、遗留 / 风险

1. **余量薄（+0.031 ns）**：全核限幅项已**回到 FPU 内部**
   （`u_fpu/u_fma_d/r5_sum_tc_reg[0] → u_fpu/u_fma_d/u_round/b_sign_reg_srl2`，
   16.305 ns / 49 级 / route 56 %）。FPU 是本任务**禁改**范围 ⇒ 非 FPU 侧已无进一步
   空间可挖；要继续抬余量只能动 FPU（T4 报告 §九.3 的两条路：msb 优先级树形化、
   或"对阶 pre"再切一级；后者会把 `FPU_SC_LAT` 推到 9，需同步 `fpu_delay` 补齐级数、
   `fpu.v` 常量与两个 FPU TB 的 `SC_LAT`）——建议单独立项（T6）。
2. **布局指令对照只做到"实验"级**（§6.3）：`ExtraNetDelay_high` 的**布局后估计**
   明显更好（−0.121 vs −1.138），**全流程实测也确实更好**（**+0.212 vs +0.031**，
   0 失败端点，Fmax 60.77 MHz；脚本 `fpga/scratch/t5_impl_alt.tcl`，产物
   `fpga/out/implalt_16.667ns_*`）。**交付档仍是 `impl.tcl`（ExtraTimingOpt），未改策略档**
   （理由见 §6.3：保持与 §七 反证 A/B 同策略；切换需同时重跑反证档）。
   ⇒ **建议**：若下一阶段需要更大余量（或为 T6 预留空间），把 `impl.tcl` 第 154 行
   `place_design -directive ExtraTimingOpt` 换成 `ExtraNetDelay_high`，并同时重跑
   `/tmp/t5_bypass` 的反证档（各约 30 min），然后复核 FPU 余量。
3. **非 FPU 域第二梯队**：`em_mem_size_reg[0]_replica → m_exc_cause_q/m_exc_tval_q` 的 **CE**
   （+0.270 ns，新前 20 里占 7 条）。若要冲 100 MHz，这是非 FPU 侧第一优先；
   可选做法：把 M 级"非对齐/PMP 结果"在 `M_S_IDLE→ISS` 边界寄存（本任务**未做**，
   因为它有 `pmpcfg` **同拍 CSR 写**的 hazard —— W 级的 `csrw pmpcfg` 正好在 IDLE 拍提交时，
   寄存器化会用到旧配置，属功能风险）。
4. **`m_lsu_va_q` 的维护约定**（已写进 RTL 注释）：它的等价性依赖"lsu 输出只在
   `M_S_ISS` 拍被消费"。**将来若新增 ISS 之外的 lsu 输出消费者**，必须把该消费者改用
   组合式 `m_va`，或把锁存点前移 —— 否则会取到陈旧 VA。
5. **`tb_m3_ddr3` 仍是仿真墙钟大户**：T5 RTL 实测单跑 **805 s**（两轮综合同时在跑的
   负载下）/ 本轮全量 regress 内约 6 min；放宽档 1800 s 有约 2 倍余量。
   若后续网表继续变大，建议二选一：① 走任务书 (a) 方案缩窗口
   （**要同步四处**：`.S` 的 `WIN_WORDS/WIN_END/SUB_BASE/SUB_END` + TB 的 `WINDOW_WORDS`
   + **重生成内嵌 431 字程序映像**）；② 把该 TB 从默认 regress 清单拆出单独跑。
6. **100 MHz 未测**：本任务只收口 60 MHz。T3/T4 的 100 MHz 证据仍在
   `fpga/out/impl100_*.rpt`（当时 WNS 远未收敛），与 T5 无关。
7. 反证实验是在 `/tmp` 的**整树副本**里做的（未动仓库一行）；`/tmp/t5_bypass`、
   `/tmp/t5_pmp` 属临时产物，**不在交付清单内**，可随时删除。

---

## 十、自证命令（复制即可复核本节所有数字）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu

# 冻结口径（跑批前后各测一次，应完全一致）
find rtl sim/unit -name '*.v' -o -name '*.sv' -o -name '*.vh' | sort | xargs md5sum | md5sum
# 期望：970d1271e245cde9892d168cfd3590a2
git status --porcelain
# 期望：仅 M rtl/mem/pmp_check.v  M rtl/top/core_top.v  M scripts/regress.sh（+ 新增的 scratch/report 文件）

# 判据① 布线（权威行）
./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 16.667
awk '/Design Timing Summary/{f=1} f&&/^\s+-?[0-9]/{print;exit}' fpga/out/impl_16.667ns_timing_summary.rpt
# 期望：0.031 0.000 0 49214 0.060 ...
grep -E "RESULT_IMPL_impl" fpga/out/impl.vivado.log
# 期望：RESULT_IMPL_impl: OK WNS=0.031 WHS=0.060 FMAX=60.11 NFAIL=0
awk '/Design Timing Summary/{f=1} f&&/^\s+-?[0-9]/{print;exit}' fpga/out/t5_final_synth_16.667ns_timing_summary.rpt
# 期望（综合，副本）：0.338 0.000 0 49179 0.054 ...

# 判据① 失败端点归因（应为 0 条）
./fpga/run_vivado_batch.sh fpga/scratch/t4_cones.tcl fpga/out/post_route.dcp 16.667 t5route
wc -l fpga/out/t4_t5route_failpaths.tsv      # 期望 1（只有表头）

# 判据② 回归
./scripts/regress.sh                          # 期望 REGRESS: 23/23 PASS

# 判据③ 功能
./sim/arch_test/run.sh --group rv32i/I --jobs 16
./sim/arch_test/run.sh --group 'tests/priv/PMP*' --jobs 16
./sim/arch_test/run.sh --group Sv --jobs 16
./sim/arch_test/run.sh --group rv32i/F --jobs 16
./sim/arch_test/run.sh --group rv32i/D --jobs 16

# 判据④ 反证（隔离在 /tmp，不污染仓库；耗时约 45 min）
cd /tmp/t5_bypass && ./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 16.667
awk '/Design Timing Summary/{f=1} f&&/^\s+-?[0-9]/{print;exit}' fpga/out/impl_16.667ns_timing_summary.rpt
# 期望：-0.503 -13.906 46 49184 0.040 ...（比交付档差 0.534 ns）

# 判据④ 表达式级等价性（秒级）
cd /tmp/t5_pmp && iverilog -g2012 -s tb_pmp_expr_equiv -o expreq.vvp tb_pmp_expr_equiv.sv && vvp expreq.vvp

# 判据⑤ 布局/约束实验（只到 place，约 10 min）
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
./fpga/run_vivado_batch.sh fpga/scratch/t5_place_exp.tcl ExtraNetDelay_high
# 期望：RESULT_T5_PLACEEXP: DIRECTIVE=ExtraNetDelay_high WNS=-0.121 NFAIL=19
```

---

## 附：改动文件清单（`git status --porcelain`）

```
 M rtl/mem/pmp_check.v   —— NAPOT 掩码恒等式（删 napot_ones）+ 优先级前缀共享树
 M rtl/top/core_top.v    —— 新增 m_lsu_va_q 寄存级 + lsu 地址入口改接（+ 复位/锁存点）
 M scripts/regress.sh    —— tb_m3_ddr3 单独墙钟放宽档（其余 22 个 TB 仍 300 s）
?? fpga/T5-report.md     —— 本报告
```
（`fpga/scratch/` 与 `fpga/out/` 都在 `.gitignore` 内 —— 本次新增的 4 个
**只读分析/实验**脚本 `t5_place.tcl`、`t5_synthpaths.tcl`、`t5_place_exp.tcl`、
`t5_impl_alt.tcl` 与全部报告副本不会进版本库，与 T3/T4 的既有约定一致。）

**本次零改动的关键文件**（逐条对照任务书"禁改"清单）：
`rtl/exec/fpu*.v`、`rtl/exec/fregfile.v`、`rtl/exec/exe_ctrl.v`、`rtl/decode/decoder.v`、
`rtl/pkg/*`、`rtl/cache/*`、`rtl/plic/*`、`rtl/clint/*`、`sim/arch_test/*`、
`sim/unit/tb_fpu*.sv`、`fpga/tcl/create_ip.tcl`、`fpga/tcl/synth.tcl`、`fpga/scratch/nofpu_*`；
任务允许但**实际未改**的：`rtl/mem/lsu.v`、`rtl/mem/amo_unit.v`、`rtl/csr/ptw.v`、
`rtl/fetch/fetch_unit.v`、`rtl/csr/csr_file.v`、`fpga/tcl/impl.tcl`、
`sim/unit/tb_m3_ddr3.sv`、`sim/unit/prog/ddr3_memtest.S`。
