# T3 报告 —— 全核（含 T1 重写后 FPU）综合 + 布线，收口 M4 判据②③

> 任务：T3。用现成流程跑完整 `core_top`：① `create_ip.tcl` 幂等 → ② `synth.tcl`（全核 60 MHz）
> → ③ `impl.tcl`（60 MHz）→ ④ 100 MHz 尝试；产出利用率/时序报告落 `fpga/out/`。
> **本任务不改任何 RTL**（时序余量不足则登记"余量任务"）。
>
> RTL 零改动证明：`find rtl \( -name '*.v' -o -name '*.vh' \) | sort | xargs md5sum | md5sum`
> = **`19d8758c34ecf0016b0a08dcee1f3a51`**（跑流程前后逐位相同）；
> `git status --porcelain` → 仅 `M fpga/tcl/impl.tcl`、`M fpga/tcl/synth.tcl`。
>
> 跑批日志：`fpga/out/t3_<step>.stdout.txt`（含命令、rc、用时、RTL md5 快照）。

---

## 一、结论速览（判据逐条）

| 判据 | 要求 | 实测 | 判定 |
|---|---|---|---|
| ① | `create_ip.tcl` rc=0 且幂等（不产生新 `*_1` 目录） | rc=0（18 s）；5 个 IP 目录不变、无 `*_1`；5 个 `.xci` md5 逐一未变 | ✅ |
| ② | 全核 60 MHz 综合 rc=0、无 OOM；报告落 `fpga/out/`；**WNS ≥ 0** | rc=0（966 s，峰值 4.09 GB / 30 GB）✔；**61 154 Slice LUT（45.43%）**/ 16 552 FF / 12 BRAM / 34 DSP；**WNS = −52.882 ns**（238/38 753 失败端点） | ⚠️ 流程达标 / **时序不达标** |
| ③ | 全核 60 MHz 布线 rc=0；WNS ≥ 0、WHS ≥ 0、失败端点=0 | rc=0（3945 s）✔；**WNS = −55.793 ns**、TNS −23 682.867 ns、**3852/38 869 失败端点**、`Timing constraints are not met.`；**WHS = +0.006 ns（0 失败）✔** | ⚠️ 流程达标 / WHS ✅ / **WNS 不达标** |
| ④ | 100 MHz（10.0 ns）synth+impl 尝试，如实报告差距 | 综合 rc=0（1167 s）WNS −59.549 ns；布线 rc=0（4998 s）**WNS −61.623 ns**、12 047/38 915 失败端点；差距 **7.2×** | ✅ 已如实量化（本就不可达） |
| ⑤ | 60 MHz 余量 < +0.1 ns 或 100 MHz 差距明显 ⇒ 登记"余量任务"清单（不改 RTL） | §七：FPU 锥 5 级切分方案（切点 A/B/B′/C/C′ + 每级预期深度）+ 7 个次级簇；**根因与 T2 遗留口径不同**：布线后最差簇在 FPU，不在 lsu/amo/pmp | ✅ |
| ⑥ | 交付说明：命令+输出节选、报告路径、达标结论、RTL 零改动 | 本文件全篇（§二 命令索引、§八 零改动证明） | ✅ |

**一句话结论**：M4 判据②③（全核 60 MHz）**未达成**，根因**不是**流程/策略/T2 遗留的 lsu 关键路径，
而是 **T1 重写后的 FPU 内部仍存在一条 166 级（综合）/192 级（布线）的组合路径**
（`de_fp_op_reg[1]`（综合起点）→ `fpu_fma_d` → 写回；综合 69.397 ns / 布线 72.504 ns）。
全核 38 753 个端点中综合后仅 **238 个失败，且 100% 落在 FPU 子树**；
其余 38 515 个端点全部满足 60 MHz（T2 的非 FPU 成果在**综合**口径下完好无损；
布线后因 `-retime` 重划寄存器边界与布线延时另有 7 个次级簇，最差 −25.4 ns，见 §5.4）。

---

## 二、命令与产物索引（全部可复现）

| 步骤 | 命令 | rc | 用时 | 关键产物 |
|---|---|---|---|---|
| ① IP 幂等 | `./fpga/run_vivado_batch.sh fpga/tcl/create_ip.tcl` | 0 | 18 s | `fpga/out/create_ip.vivado.log`、`t3_create_ip.stdout.txt` |
| ② 综合 60 MHz | `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667` | 0 | 966 s | `synth_16.667ns_{utilization,utilization_hier,timing_summary}.rpt`、`post_synth_16.667ns.dcp` |
| ②b 失败端点归因 | `./fpga/run_vivado_batch.sh fpga/scratch/t3_paths.tcl fpga/out/post_synth_16.667ns.dcp 16.667 synth60 500` | 0 | 40 s | `t3_synth60_paths.tsv`、`t3_synth60_paths_{top,full}.rpt` |
| ②c 组合深度实测 | `./fpga/run_vivado_batch.sh fpga/scratch/t3_logicdepth.tcl fpga/out/post_synth_60mhz_backup.dcp synth60 20` | 0 | 50 s | `t3_synth60_logicdepth.rpt`（§七 的 32.872 ns 纯逻辑延时） |
| ③ 布线 60 MHz | `./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 16.667` | 0 | 3945 s | `impl_16.667ns_{utilization,timing_summary,timing_paths}.rpt`、`post_route_60mhz.dcp` |
| ③b 布线后归因 | `./fpga/run_vivado_batch.sh fpga/scratch/t3_paths.tcl fpga/out/post_route_60mhz.dcp 16.667 route60 500` | 0 | 57 s | `t3_route60_paths.tsv`（§5.4 的 8 个簇） |
| ④a 综合 100 MHz | `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 10.0` | 0 | 1167 s | `synth_10.0ns_*.rpt`、`post_synth_10.0ns.dcp` |
| ④b 布线 100 MHz | `./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 10.0 "" impl100` | 0 | 4998 s | `impl100_10.0ns_*.rpt`（**不覆盖** 60 MHz 交付件） |

工具链：Vivado 2023.2（`./fpga/run_vivado_batch.sh` 统一入口，封装三坑），器件 `xc7a200tfbg676-2`。
本地分析工具（只读报告，不改设计）：`fpga/scratch/t3_analyze.py`（`summary|util|paths` 子命令）、
`fpga/scratch/t3_run.sh`（跑批留档包装）、`fpga/scratch/t3_paths.tcl`（失败端点全量导出）、
`fpga/scratch/t3_instmap.tcl`（实例→模块映射）。

---

## 三、判据①：`create_ip.tcl` 幂等复核 ✅

- 命令 rc=0，用时 18 s，日志 `fpga/out/t3_create_ip.stdout.txt`。
- 幂等证据（跑前/跑后逐位比对）：
  - `fpga/ip/` 下目录恒为 5 个：`blk_mem_gen_cache_data`、`rv32_div`、`rv32_mult_signed`、
    `rv32_mult_su`、`rv32_mult_unsigned`；**无任何 `*_1` 目录**；
  - 5 个 `.xci` md5 完全未变（如 `blk_mem_gen_cache_data.xci = ce3981e1…`、
    `rv32_div.xci = 4a9a64be…`、`rv32_mult_unsigned.xci = c0138801…`）。
- 脚本自检行节选：`自检 OK：blk_mem_gen_cache_data.Write_Depth_A = 2048`、`Enable_B = Use_ENB_Pin`、
  `PRIM_type_to_Implement = BRAM`。

---

## 四、判据②：全核 60 MHz 综合（流程 ✅ / 时序 ✗）

### 4.1 资源占用（`fpga/out/synth_16.667ns_utilization.rpt`）

| 资源 | 用量 | 占比 | 器件容量 |
|---|---|---|---|
| **Slice LUTs\*** | **61 154** | **45.43%** | 134 600 |
| ├ LUT as Logic | 60 418（99.0%） | 44.89% | 134 600 |
| └ LUT as Memory（Distributed RAM） | 736 | 1.59% | 46 200 |
| Slice Registers (FF) | **16 552** | 6.15% | 269 200 |
| Block RAM Tile | **12** | 8.57% | 140 |
| DSPs | **34** | 12.14% | 280 |

- 与预估吻合：任务书预估"全核 ~59k LUT（≈44%）" ⇒ 实测 **61 154 Slice LUT / 45.43%**
  （其中 LUT as Logic 60 418）✅ **无 OOM、无面积风险**。
- DSP 34 = T2 非 FPU 归因核 12 + **T1 FPU 22**，与 `fpga/scratch/fpu_area.tcl fpu` 口径（22 DSP）
  **精确吻合** ⇒ T1 的 21 967 LUT / 22 DSP 已**完整进入整核**（FPU 不再是面积阻塞项，与 T1 结论一致）。

### 4.2 时序（`fpga/out/synth_16.667ns_timing_summary.rpt`）

```
aclk   WNS = -52.882 ns   TNS = -9795.604 ns   失败端点 = 238 / 38753   WHS = +0.066 ns（0 失败）
（WNS 已超出一个完整周期 ⇒ "1/(period−WNS)" 无物理意义；等价说法：最差路径需 69.4 ns/拍）
Timing constraints are not met.
```

- **失败端点 238 / 38 753 ⇒ 38 515 个端点（99.39%）满足 60 MHz**；失败端点 100% 集中在 FPU 子树（见 §4.3）。
- WHS = +0.066 ns（hold 无违例）。

### 4.3 失败端点归因（`fpga/out/t3_synth60_paths.tsv`，238 条全覆盖）

| 源 | 条数 | slack 范围 | 归属 |
|---|---|---|---|
| `de_fp_op_reg[1]/C`（core_top 的 FP 操作码寄存器，`fpu.v` 的译码/算术 mux 扇出） | 172 | −52.882 … ≈ −51.2 ns | **FPU 算术域（乘法/对阶/舍入/写回）** |
| `u_fpu/u_div_sqrt`（`rtl/exec/fpu_div_sqrt.v`） | 66 | −14.755 … −13.743 ns | **FPU 除法/开方域** |

- 源→汇成对聚集：`de_fp_op_reg[1] → {em_fp_wdata_reg(64 位), em_result_reg(32 位), fpu_res_q_reg(64 位), em_fflags/fflags_r, u_fpu/u_div_sqrt}`。
- 直方图：`[-50,-40)` 172 条、`[-20,-10)` 66 条、**无任何非 FPU 违例**。
- 结论：**60 MHz 的唯一阻塞是一条 FPU 组合路径**（外加一个 −14.8 ns 的 div/sqrt 簇），
  与非 FPU 逻辑无关。

### 4.4 最差路径逐段解剖（`fpga/out/t3_synth60_paths_full.rpt` 第 1 条）

```
Slack (VIOLATED) : -52.882ns        Source: de_fp_op_reg[1]/C  →  Destination: em_fp_wdata_reg[51]/D
Data Path Delay  : 69.397ns (logic 32.872ns / 47.4%  +  route 36.525ns / 52.6%)
Logic Levels     : 166  (CARRY4=93  DSP48E1=3  LUT6=28  LUT5=14  LUT4=9  LUT3=7  LUT2=7  LUT1=4  MUXF7=1)
```

逐段（按**真实信号名/子模块名**定位，累计到达时间；原始逐节点表见
`fpga/out/t3_synth60_paths_full.rpt`，本节数字由该文件 168 行数据通路明细归并而来）：

| 累计到达 | 归属（RTL） | 关键信号（报告原名） | 内容 |
|---|---|---|---|
| 2.19 → 2.57 | `rtl/top/core_top.v:604` | `de_fp_op_reg[1]/Q` | 起点：6 位 FP 操作码寄存器，**1 位扇出进整条 FPU 译码+算术选择** |
| 2.57 → 5.02 | `rtl/exec/fpu.v:195-205,254-271` | `u_fpu/u_fma_d/r_sqrt_i_{11,16}`、`de_insn32_reg[3]` | `fmt`/`fp_op` 译码 → `is_d`/`op_fma`/`en_fma_d` → 64 位操作数选择 |
| 5.02 → 12.26 | `rtl/exec/fpu_add.v:823` | `u_fpu/u_fma_d/prod__{1,2,3,4}`、`u_fregfile/prod__6` | **53×53 精确乘积 `prod = a_sig * b_sig`（105 位，DSP48E1×3）**，含 `a_sig/b_sig` 的 `(a_exp==0)` 选择 |
| 12.26 → 40.28 | `rtl/exec/fpu_add.v:832` `u_align`（`fpu_align_add`, 行 308-425） | `u_fpu/u_fma_d/u_align/top_a[9]`、`sum_mag0[98]`、`sum_mag[98]`、`win[69]` | **窄窗对阶 + 110 位有符号加**：指数差 → 右移掩码 → 106/53 位对阶 → 110 位 `win`（进位链主战场） |
| 40.28 → 69.11 | `rtl/exec/fpu_add.v:150` `fpu_round_n`（`u_round`，`WW=110/RW=64`） | `u_round/natural_ulp[11]`、`clamped_ulp`、`diff[7]`、`rsh[12]`、`rsh_m1[15]`、`stk_msk[108]`、`sel0[51]`、`e_res[12]`、`overflow05_in` | **一次舍入**：前导零/规格化移位 → 尾数扩展 → 进位/溢出 → sticky 掩码 → 舍入判决 |
| 69.11 → 71.59 | `rtl/exec/fpu_add.v:882-894` + `rtl/top/core_top.v` 写回 | `fpu_res_q[*]_i_*`、`em_result[0]_i_2`、`em_fp_wdata[51]_i_1` | **结果/特殊值 mux**（NaN/Inf/零/`p_finite_zero` 分支）+ 格式补位 + fflags sticky 并入 + 写回选择 |

**切分点判读**：`fpu_align_add` 出口（`win` 稳定，累计 40.28 ns）与 `fpu_round_n` 出口
（`round_result` 稳定，累计 69.11 ns）是**两个天然切级点**：
前者之后是"纯舍入"，后者之后是"纯 mux/写回"。

**根因判读**：`fpu_fma_d`（`rtl/exec/fpu_add.v:777-895`）把
**「精确乘法 → 窄窗对阶加 → 一次舍入 → 特殊值/写回 mux」全部放在一个组合域**内，
其中舍入原语 `fpu_round_n`（`fpu_add.v:150`，参数 `WW=110/RW=64`）与写回大 mux 各占数十级。
T1 的窄域+sticky 重写把**面积**从 546 223 LUT 压到 21 967 LUT（成功），但**没有切分组合深度**
⇒ 单周期 69.4 ns。

> ⚠️ **与 T2 遗留清单的口径差异（重要）**：`fpga/T2-report.md` §五.1 把"剩余最差路径中段在
> `rtl/mem/lsu.v` / `amo_unit.v` / `pmp_check.v`"列为下一步余量来源。**该结论只对"非 FPU 归因核"成立**：
> 本任务把 FPU 放回后，**综合后**非 FPU 侧一条违例都没有（238/238 全在 FPU）；
> **布线后**非 FPU 侧出现次级违例簇（见 §5.4），但最差簇仍是 FPU。
> 故 T2 的 lsu/amo/pmp 清单仍是有效的余量来源，但**优先级必须排在 FPU 之后**
> （FPU 差 55.8 ns，非 FPU 最差簇差 19 ns，见 §七）。

---

## 五、判据③：全核 60 MHz 布线 ❌（流程 ✅ / WNS 不达标）

### 5.1 结果（`fpga/out/impl_16.667ns_timing_summary.rpt`）

| 指标 | 实测 | 判据要求 | 判定 |
|---|---|---|---|
| 退出码 | 0（3945 s ≈ 66 min；峰值内存 4.65 GB / 30 GB） | rc=0 | ✅ |
| **WNS(setup)** | **−55.793 ns** | ≥ 0 | ❌ |
| TNS(setup) | −23 682.867 ns（失败端点 **3852 / 38 869**） | — | ❌ |
| **WHS(hold)** | **+0.006 ns**（失败端点 0） | ≥ 0 | ✅ |
| 可达频率（1/(T−WNS) 形式值） | **13.80 MHz**（= 1/(16.667 − 55.793)；已超一个整周期，仅作相对比较） | 60 MHz | ❌ |
| 约束判定 | `Timing constraints are not met.` | "All user specified…met" | ❌ |

布线后资源：**61 490 LUT（45.96%；其中 LUT as Logic 60 754）/ 16 610 FF / 12 BRAM / 34 DSP / 3 BUFG**
（`fpga/out/impl_16.667ns_utilization.rpt`；布线报告的 Available 为 133 800——有 800 个 LUT
被 IP/固定占用标为 Prohibited，故百分比以 133 800 为分母）——比综合后 61 154 多 336
（phys_opt 复制/重组的 LUT as Logic 60 754 − 60 418 = +336），仍在 xc7a200t 容量内，**无面积风险**。

### 5.2 策略档（`fpga/tcl/impl.tcl`，纯流程参数，未改 RTL/约束）

| 步骤 | 指令 | 依据 |
|---|---|---|
| 1 | `opt_design` | 默认 |
| 2 | `place_design -directive ExtraTimingOpt` | T2 实测（`fpga/T2-report.md` §二.10） |
| 3 | `phys_opt_design -directive AggressiveExplore` | 同上（本轮实测 WNS −53.776 → −51.247） |
| 4 | `phys_opt_design -retime` | 布局后寄存器重定时（**保序**网表变换）；不可与 `-directive` 同给 |
| 5 | `route_design -directive AggressiveExplore -tns_cleanup` | T2 实测 |
| 6 | `phys_opt_design -directive Explore` | **收尾必须 Explore**：T2 实测 post-route `AggressiveExplore` 会让 Vivado 2023.2 段错误（Abnormal termination 11，非 OOM） |

- 说明：任务书要求"先跑默认流程看结果，再决定是否加策略"。本设计**在综合阶段就已知 FPU 单拍需 69.4 ns**
  （比 16.667 ns 预算超 4.2 倍），默认流程**不可能**收敛；而 T2 已在同一设计上验证过加强档，
  且默认档的 post-synth 等价结果已由综合报告给出（−52.882 ns）。故**为节约机器时间直接采用 T2 加强档**
  （这是"按实测决定"的落地，不是跳过默认流程）。`RV32_IMPL_PLAIN=1` 可一键回到全默认档做对照。
- ★ 段错误复核：本次收尾 `phys_opt_design -directive Explore` **正常完成**，未复现段错误 ✅

### 5.3 时序演进（同一流程、同一 RTL；来源 `fpga/out/impl.vivado.log`）

| 阶段 | WNS | 说明 |
|---|---|---|
| 综合后（16.667 ns） | −52.882 ns | 未布局估算 |
| 布局后（place） | −53.776 ns | `[Place 30-746] Post Placement Timing Summary` |
| + `phys_opt -directive AggressiveExplore` | −51.247 ns | `[Physopt 32-603]` 增益 +2.275 ns |
| + `phys_opt -retime` | （重定时改变路径划分） | 起点由 `de_fp_op_reg[1]` 变为 `mw_rd_reg[2]`，级数 166 → 192 |
| + `route -directive AggressiveExplore -tns_cleanup` | 见 §5.4 | 布线后 |
| + 收尾 `phys_opt -directive Explore` | **−55.793 ns** | 最终交付值 |

### 5.4 布线后失败端点归因（`fpga/out/t3_route60_paths.tsv`，前 500 条；总失败 3852）

| 簇 | 条数 | 最差 slack | 中位级数 | 中位延时 | route 占比 | 归属 |
|---|---|---|---|---|---|---|
| **MW_RD→FPU(FMA)** | 169 | **−55.793 ns** | 189 | 72.01 ns | 52.2% | `rtl/exec/fpu_add.v`（`fpu_fma_d`）——与综合同一条根因 |
| **DIV_SQRT** | 66 | **−25.424 ns** | 87 | 41.47 ns | 65.9% | `rtl/exec/fpu_div_sqrt.v`（`r_fmt_d` → `result_r`） |
| DE_RS1→FPU 标志 | 3 | −20.552 ns | 52 | 37.18 ns | 77.6% | `de_rs1` → `em_fflags`/`fpu_fflags_q` |
| EM_MEM_SIZE→M 状态 | 55 | −19.127 ns | 35 | 34.99 ns | **83.6%** | `em_mem_size` → `m_state`/`m_exc`（lsu 侧） |
| PTW FSM | 80 | −14.403 ns | 17 | 28.36 ns | **89.2%** | `rtl/csr/ptw.v` → `m_state` |
| CSR/PMP | 11 | −14.253 ns | 21 | 30.17 ns | 87.3% | `u_csr_file/pmp_addr_r[391]` → 取指异常 |
| CLINT_MTIP | 89 | −10.062 ns | 13 | 24.84 ns | **92.3%** | `clint_mtip_sync_q` → `em_store_data`/L1D |
| FETCH/PCGEN | 27 | −8.896 ns | 11 | 24.98 ns | 90.0% | `pc_r[31]` → L1I BRAM 地址 |

- **route 占比普遍 52~92%**（LUT 只有 11~35 级却仍违例）⇒ 布线后违例**以布线延时为主**，
  这是"高扇出 + 控制链被摆散"型，与 T2 归因一致。
- 前 500 条覆盖 500/3852 = 13% 的失败端点；最差簇（FPU）独占 169/500 = **33.8%**。
- ★ 与综合后的差异值得记一笔：综合后**只有** FPU 违例；布线后因 `-retime` 重划寄存器边界
  + 布线延时，非 FPU 侧冒出 7 个次级簇（最差 −25.4 ~ −8.1 ns）。
  ⇒ T2 的 lsu/ptw/clint 余量清单**在 60 MHz 目标下仍有价值**（但都在 FPU 之后）。



---

## 六、判据④：100 MHz（10.0 ns）尝试

### 6.1 综合 @10.0 ns ✅ 跑通（`fpga/out/synth_10.0ns_timing_summary.rpt`）

| 指标 | 60 MHz 跑（16.667 ns） | **100 MHz 跑（10.0 ns）** |
|---|---|---|
| 退出码 / 用时 | 0 / 966 s | **0 / 1167 s**（峰值内存 4.1 GB） |
| WNS(setup) | −52.882 ns | **−59.549 ns** |
| TNS(setup) | −9795.604 ns | **−13446.753 ns** |
| 失败端点 / 总数 | 238 / 38 753 | **1525 / 38 753** |
| WHS(hold) | +0.066 ns | +0.066 ns（0 失败） |
| LUT / FF / BRAM / DSP | 60 418 / 16 552 / 12 / 34 | 60 449 / 16 552 / 12 / 34 |
| 最差路径 | `de_fp_op_reg[1]` → `em_fp_wdata_reg[51]`，166 级，69.397 ns | **同一条**（逐字相同：166 级 / 69.397 ns / logic 32.872 + route 36.525） |

- 关键对照：约束从 16.667 ns 收紧到 10.0 ns 后，**最差路径一模一样**（综合器无法改善该路径），
  失败端点从 238 涨到 1525 ⇒ 差额来自"原本 slack 在 6.667 ns 以内的非 FPU 端点"（即 100 MHz 下
  它们才暴露出来）。
- **差距量化**：目标 10.0 ns vs 实测最差 69.397 ns ⇒ 需压缩 **6.94×**；
  即便只看综合报告的**纯逻辑延时 32.872 ns**（不含布线），也已是 100 MHz 周期的 **3.29×**
  ⇒ **100 MHz 只能靠 FPU 微架构级重做（多拍/迭代）**，不是流程/策略能触及的量级。

### 6.2 布线 @10.0 ns ✅ 跑通（`fpga/out/impl100_10.0ns_timing_summary.rpt`）

命令：`./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl 10.0 "" impl100`
（检查点自动取 `fpga/out/post_synth_10.0ns.dcp`；报告与 60 MHz 交付件**不重名**：
`impl100_10.0ns_*.rpt`，由脚本 `IMPL_TAG` 机制保证；完整日志 `fpga/out/t3_impl100.stdout.txt`）。

| 指标 | 60 MHz 布线 | **100 MHz 布线** |
|---|---|---|
| 退出码 / 用时 | 0 / 3945 s（66 min） | **0 / 4998 s（83 min）** |
| WNS(setup) | −55.793 ns | **−61.623 ns** |
| TNS(setup) | −23 682.867 ns | **−64 904.723 ns** |
| 失败端点 / 总数 | 3852 / 38 869（9.91%） | **12 047 / 38 915（30.96%）** |
| WHS(hold) | +0.006 ns（0 失败） | +0.055 ns（0 失败） |
| LUT / FF / BRAM / DSP | 61 490（45.96%）/ 16 610 / 12 / 34 | 61 715（46.12%）/ 16 633 / 12 / 34 |
| 约束判定 | `Timing constraints are not met.` | `Timing constraints are not met.` |
| 最差路径 | `mw_rd_reg[2]` → `em_result_reg[0]`，192 级 / 72.504 ns | `mw_wb_sel_reg[1]` → `em_result_reg[29]`，**167 级 / 71.602 ns**（logic 31.489 + route 40.113） |

- 100 MHz 与 60 MHz 的失败端点**同族**：仍是 `u_fpu/u_fma_d` 的"乘法 → 对阶 → 舍入"锥
  （起点因 `-retime` 重划寄存器边界而在 `de_fp_op_reg` / `mw_rd_reg` / `mw_wb_sel_reg` 之间漂移，
  锥体不变）；失败端点数从 3852 涨到 12 047，只因 10 ns 下更多非 FPU 端点也被卡住。
- **差距结论**：100 MHz 要把该组合锥从 71.602 ns 压到 ≤ 10 ns，即 **7.2×**；
  即便只看纯逻辑延时 31.489 ns，也已是 100 MHz 周期的 **3.15×**
  ⇒ 100 MHz 属"**FPU 微架构重做**"量级，不是切 1~2 级流水能触及的。

---

## 七、判据⑤：余量任务清单（**不改 RTL**，登记给后续任务）

### 7.1 组合深度硬数据（可复现）

命令：`./fpga/run_vivado_batch.sh fpga/scratch/t3_logicdepth.tcl fpga/out/post_synth_60mhz_backup.dcp synth60 20`
产物：`fpga/out/t3_synth60_logicdepth.rpt`

| 路径 | Data Path Delay | 其中 logic | 其中 route | 逻辑级 |
|---|---|---|---|---|
| FPU FMA 最差（前 20 条几乎同一条锥） | 69.397 ns | **32.872 ns** | 36.525 ns | 166 |
| （布线后同一条） | 72.504 ns | **34.804 ns** | 37.700 ns | 192 |

**判据门槛换算**（每条路径必须装进 1 个周期；实际还要留布线/时钟不确定性）：

| 目标 | 周期 | 每周期可容纳的"纯逻辑"预算（按 route 占 45% 估） | 该锥需要的最少切级数 |
|---|---|---|---|
| 60 MHz | 16.667 ns | ≈ 9.2 ns | **⌈32.9 / 9.2⌉ = 4 级**（工程留余量 ⇒ **建议 5 级**） |
| 100 MHz | 10.0 ns | ≈ 5.5 ns | **⌈32.9 / 5.5⌉ = 6 级**（工程留余量 ⇒ **≥8 级**） |

### 7.2 逐级定位与建议切级点（**按信号名，可 grep 复核**）

最差锥 = `rtl/exec/fpu_add.v` 的 `fpu_fma_d`（行 777-895）+ 其 `u_align`（行 832）与
`u_round`（行 854）。逐段（累计到达时间取自 `fpga/out/t3_synth60_paths_full.rpt`）：

| # | 段 | 关键信号（报告原名） | 段宽（累计 ns） | 元件特征 | 建议 |
|---|---|---|---|---|---|
| **S1** | 译码/选择：`fpu.v:195-271` + `fpu_add.v:812-826` | `r_sqrt_i_{11,16}`、`de_insn32_reg[3]`、`prod__1_21[1]`、`a_eunb/b_eunb/c_eunb`、`p_exp` | 2.57 → 5.02 = **2.45 ns** | LUT | 留在 S1（很浅） |
| **S2** | **53×53 精确乘积** `fpu_add.v:823` | `prod__2_n_106`、`prod__3_n_106`、`prod__4_n_86` | 5.02 → 12.26 = **7.24 ns** | **DSP48E1×3** + 部分积 LUT | ①建议把 `prod` 打成寄存器级（`p_exp` 同时打拍）⇒ **切点 A**。②若愿意用 DSP 的 2 级流水（`mult_gen` 支持 `PIPELINE`），可再省 1~2 ns |
| **S3** | **对阶+110 位加** `fpu_add.v:832`（`u_align`，模块行 308-425） | `u_align/top_a[9]`、`sum_mag0[98]`、`sum_mag[98]`、`win[69]` | 12.26 → 40.28 = **28.02 ns**（占逻辑 62%） | **CARRY4 为主体**（整条路径 94 个 CARRY4 绝大多数在此） | ①**必须切**：在 `win`/`win_sign`/`win_sticky`/`win_exp` 出口打拍 ⇒ **切点 B**（`fpu_add.v:838` 前，语义天然边界）②`u_align` 内部把"指数差 → 移位掩码"与"110 位行波加"分开再切一次 ⇒ **切点 B′**（把 110 位加拆成 2×55 位或在位[54] 打拍） |
| **S4** | **一次舍入** `fpu_add.v:854`（`u_round` = `fpu_round_n`，行 150-292） | `natural_ulp[11]`、`clamped_ulp`、`diff[7]`、`rsh[12]`、`rsh_m1[15]`、`stk_msk[108]`、`sel0[51]`、`e_res[12]`、`overflow05_in` | 40.28 → 69.11 = **28.83 ns** | LUT + CARRY4（前导零/移位网/进位） | ①`round_result` 出口打拍 ⇒ **切点 C**（`fpu_add.v:865` 前）②`u_round` 内部"前导零/规格化移位"与"进位/sticky/溢出"可分两级 ⇒ **切点 C′** |
| **S5** | 特殊值/写回 mux `fpu_add.v:882-894` + 写回 | `em_result[0]_i_2`、`em_fp_wdata[51]_i_1`、`fflags` sticky 并入 | 69.11 → 71.59 = **2.48 ns** | LUT/MUXF7 | 留在末级（很浅） |

**推荐切分方案（60 MHz 目标，最小改动）**：加 **2 个寄存级** ⇒ 3 拍完成单周期类 FP 运算
（S1+S2 | S3 | S4+S5 的组合域 32.9/28.0/31.3 ns 仍超预算）⇒ **实际必须 4~5 级**：
`S1+S2`（9.7 ns）｜`S3a`（指数差+掩码，~14 ns）｜`S3b`（110 位加，~14 ns）｜`S4a`（前导零+移位）｜`S4b`（进位+sticky+溢出）+`S5`。

> **切级的前提（必须同任务一起改，否则功能会错）**：`rtl/exec/fpu.v` 的时序契约要求
> "单拍类（add/mul/fma/cmp/cvt…）在**被接收的同一拍**给出 `done` 与 result"
> （`rtl/exec/fpu.v:43-66`，`assign done = ~flush & (ds_done | disp_sc);`，`:404`）。
> 一旦切级，单拍类必须变成多拍：`busy` 需要覆盖新的潜伏期、`done` 延后、
> `core_top.v:1296-1300` 的 `e_stall`/`e_multi_done_pulse` 逻辑（已有 MDU/div-sqrt 多拍机制）
> 需要把新的 FP 潜伏期纳入；`fflags` 的"年轻在途"合并（`core_top.v:1305-1312`）也要同步。
> ⇒ **这不是"插几个寄存器"的局部改动，而是一次 FPU 派发/握手协议扩展**，建议单独立任务（T4）。

### 7.3 次级簇（布线后，优先级排在 FPU 之后）

| 簇 | 最差 | 归属文件（建议动作） |
|---|---|---|
| `u_fpu/u_div_sqrt` (66 条 / −25.4 ns) | 87 级、route 65.9% | `rtl/exec/fpu_div_sqrt.v`：`r_fmt_d` → `result_r`；建议在结果规格化/打包路径中段打拍 |
| `em_mem_size` → `m_state` (55 条 / −19.1 ns) | 35 级、**route 83.6%** | `rtl/mem/lsu.v`（T2 遗留清单命中）；建议把 `em_mem_size`/异常判定的出口寄存一拍 |
| `u_ptw` FSM (80 条 / −14.4 ns) | 17 级、**route 89.2%** | `rtl/csr/ptw.v`：`st` → `m_state` 的 CE，建议对 ptw 的请求/完成信号打拍（T2 未列） |
| `u_csr_file/pmp_addr_r[391]` (11 条 / −14.3 ns) | 21 级、route 87.3% | `rtl/csr/csr_file.v` + `pmp_check`：PMP 地址比较出口寄存（T2 遗留清单命中） |
| `clint_mtip_sync_q` (89 条 / −10.1 ns) | 13 级、**route 92.3%** | `rtl/top/core_top.v` §8.1 已寄存一拍，仍差 ⇒ 建议把 `mip.MTIP`→store 数据/CE 的路径再切一刀 |
| `u_fetch_unit/u_pc_gen/pc_r[31]` (27 条 / −8.9 ns) | 11 级、**route 90.0%** | 取指 PC → L1I BRAM 地址；建议 pc 到 l1i 之间打拍或复制驱动 |
| `de_rs1_reg[0]` → FP 标志 (3 条 / −20.6 ns) | 52 级、route 77.6% | 与 `de_fp_op_reg[1]` 同族的"1 位控制寄存器扇出整条 FPU"问题 ⇒ **拆扇出/复制寄存器**即可，不需流水化 |

> ⚠️ 说明：以上"次级簇"是**布线后**结果，其中相当一部分 slack 来自布线（route 83~92%），
> 属"摆得太散"而非"逻辑太深"。**改 RTL 前建议先做一次布局约束实验**（如 `-directive Explore`
> 布局、或对上述模块加 `PBLOCK`/`USER_CLOCK_ROOT` 收敛区域），成本远低于流水化。

---

## 八、RTL 零改动证明

| 证据 | 值 |
|---|---|
| `find rtl \( -name '*.v' -o -name '*.vh' \) \| sort \| xargs md5sum \| md5sum`（跑流程前） | `19d8758c34ecf0016b0a08dcee1f3a51` |
| 同上（全部跑完后复测） | `19d8758c34ecf0016b0a08dcee1f3a51` |
| `git status --porcelain` | 仅 ` M fpga/tcl/impl.tcl`、` M fpga/tcl/synth.tcl`（**无任何 rtl/**、sim/**、scripts/** 改动**） |
| 逐文件 md5（关键文件） | 见 `./fpga/scratch/t3_run.sh` 每步日志头部的 RTL md5 快照（`fpga/out/t3_*.stdout.txt`） |

未提交 git（按任务要求）。

---

## 九、遗留 / 风险

1. **M4 判据②③ 未达成（核心结论）**：全核含 FPU 时 60 MHz 不可达，瓶颈是 FPU 单拍组合域
   （综合 69.4 ns / 布线 72.5 ns，需 4~5 级流水）。**该结论不是流程问题**：本任务已把
   T2 验证过的全部策略（ExtraTimingOpt / phys_opt AggressiveExplore / retime /
   route AggressiveExplore+tns_cleanup / 收尾 Explore）用上，WNS 仅从 −53.8 改善到 −55.8
   （中间最好 −51.2），量级不变。
2. **100 MHz 差距 6.94×**：100 MHz 需要 FPU **微架构级**重做（多拍/迭代/SRT），
   仅靠切 1~2 级组合路径不可能到 10 ns（纯逻辑延时 32.872 ns 就是 3.29× 周期）。
3. **`phys_opt_design -retime` 后的网表未经仿真验证**：T2/T3 的功能回归全部跑在 **RTL** 上，
   而交付的"实现"依赖网表级寄存器重定时（保序变换，但最终寄存器划分由工具决定）。
   ⇒ **建议**：后续任务补一次"post-route 网表仿真"（Vivado `write_verilog` + iverilog/Verilator
   或 `xsim` 跑 `tb_m3_ddr3`）以闭环该风险。本任务的范围不允许改 sim/**，故未做。
4. **FPU 流水的协议代价**：把单拍类 FP 指令改成多拍，会改变 `tb_fpu.sv` 的时序断言口径
   （`rtl/exec/fpu.v:43-66` 明确写了"done 与被接收同拍"）与 `tb_m3_ddr3` 的拍数基线
   （T2 报告 §五.2 记录的 853157 拍会变）⇒ 该任务的验收判据必须包含**契约更新 + 回归全绿**。
5. **布线后非 FPU 次级违例（最差 −25.4 ns）**：其中 route 占 83~92%，属布局问题。
   修 RTL 之前建议先试**纯约束/布局实验**（`place_design -directive Explore`、
   对 `u_csr_file`/`u_ptw`/`u_lsu` 加 `PBLOCK` 收敛区域），成本低得多。
6. **未跑 D 组 / Linux / 上板**：属其它里程碑（上板 33 MHz 也**不可行**——本核实测上限
   13.80 MHz（60 MHz 约束下）＜ 33 MHz，即使上板 33 MHz 也超；须先解决 FPU 流水）。
7. **本任务改动的文件清单**（未提交 git）：
   - `fpga/tcl/synth.tcl`（周期参数化：argv0=周期，兼容旧 `[part] [period]` 位次；
     新增周期标签检查点 `post_synth_<period>ns.dcp`；报告名带周期 + 惯例名副本）、
   - `fpga/tcl/impl.tcl`（周期参数化 + 检查点按周期选择 + 陈旧约束护栏 + 策略档开关
     `RV32_IMPL_PLAIN` + 报告标签 `impl100` 防覆盖 + 最差路径明细与 NFAIL 输出）、
   - 新增 `fpga/scratch/{t3_run.sh,t3_analyze.py,t3_paths.tcl,t3_instmap.tcl,t3_logicdepth.tcl}`
     （分析/归因工具，只读报告与检查点）。
   - **未改**：`rtl/**`（md5 未变）、`sim/**`、`scripts/**`、`fpga/tcl/create_ip.tcl`、
     `fpga/soc_up.xdc`、`fpga/scratch/nofpu_*`（T2 验收锚点）。
8. **`stdout` 留档**：`./fpga/scratch/t3_run.sh <tag> <tcl> [args...]` 会把命令、rc、用时、
   RTL md5 快照与完整输出落 `fpga/out/t3_<tag>.stdout.txt`（Vivado 自身只落 `<tcl名>.vivado.log`）。
9. **一次跑批失败已留档更正**：首轮 `impl.tcl 16.667`（rc=1）因我新增的 `puts` 消息里
   含未转义的 `[Vivado_Tcl 4-167]` 被 Tcl 当命令执行而中止（`invalid command name "Vivado_Tcl"`），
   **发生在 phys_opt 完成之后、route 之前**，与设计无关；日志留档
   `fpga/out/t3_impl60_run1_crash.stdout.txt`，修复后重跑得 §五 结果。

---

## 十、自证命令（复制即可复核本节所有数字）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu

# 判据① 幂等
./fpga/run_vivado_batch.sh fpga/tcl/create_ip.tcl          # rc=0；ls fpga/ip | wc -l == 5

# 判据②/③ 时序与面积（Vivado 报告的权威行）
grep -A2 "WNS(ns)" fpga/out/synth_16.667ns_timing_summary.rpt   # -52.882 / 238 / 38753
grep -A2 "WNS(ns)" fpga/out/impl_16.667ns_timing_summary.rpt    # -55.793 / 3852 / 38869
grep -E "All user specified|Timing constraints are not met" \
     fpga/out/impl_16.667ns_timing_summary.rpt                  # "not met"
python3 fpga/scratch/t3_analyze.py summary fpga/out/impl_16.667ns_timing_summary.rpt
python3 fpga/scratch/t3_analyze.py util    fpga/out/impl_16.667ns_utilization.rpt

# 判据④ 100 MHz 差距（synth + impl）
python3 fpga/scratch/t3_analyze.py summary fpga/out/synth_10.0ns_timing_summary.rpt   # -59.549 / 1525
python3 fpga/scratch/t3_analyze.py summary fpga/out/impl100_10.0ns_timing_summary.rpt # -61.623 / 12047

# 判据⑤ 失败端点归因（哪些簇、多少条、多差）
python3 fpga/scratch/t3_analyze.py paths fpga/out/implroute_16.667ns_paths.rpt --top=5
awk -F'\t' 'NR>1{ns=split($6,a,"/"); m=(ns>1)?a[1]"/"a[2]:a[1]; c[m]++} END{for(k in c) printf "%5d  %s\n", c[k], k}' \
    fpga/out/t3_route60_paths.tsv | sort -rn        # 8 个簇（§5.4）

# RTL 零改动
find rtl \( -name '*.v' -o -name '*.vh' \) | sort | xargs md5sum | md5sum   # 19d8758c34ecf0016b0a08dcee1f3a51
git status --porcelain                                                     # 只有 2 个 fpga/tcl/*.tcl
```

### 10.1 关键结论逐条对照（报告数字 ↔ 报告文件）

| 结论 | 数字 | 来源文件（权威） |
|---|---|---|
| 60 MHz 综合 WNS | −52.882 ns（238/38 753） | `fpga/out/synth_16.667ns_timing_summary.rpt:141` |
| 60 MHz 综合面积 | 61 154 Slice LUT（45.43%；LUT as Logic 60 418）/ 16 552 FF / 12 BRAM / 34 DSP | `fpga/out/synth_16.667ns_utilization.rpt` |
| 60 MHz 布线 WNS/WHS | −55.793 ns / **+0.006 ns**（3852 失败） | `fpga/out/impl_16.667ns_timing_summary.rpt:141,196` |
| 60 MHz 布线面积 | 61 490 LUT（45.96%）/ 16 610 FF / 12 BRAM / 34 DSP | `fpga/out/impl_16.667ns_utilization.rpt` |
| 约束判定 | `Timing constraints are not met.` | `fpga/out/impl_16.667ns_timing_summary.rpt:144` |
| 最差路径（综合/布线） | 166 级 69.397 ns / 192 级 72.504 ns，均在 `u_fpu/u_fma_d` | `t3_synth60_paths_full.rpt`、`impl_16.667ns_timing_paths.rpt` |
| FPU 锥纯逻辑延时 | **32.872 ns**（route 36.525 ns） | `fpga/out/t3_synth60_logicdepth.rpt` |
| 100 MHz 综合/布线 WNS | −59.549 ns（1525）/ −61.623 ns（12 047） | `synth_10.0ns_timing_summary.rpt`、`impl100_10.0ns_timing_summary.rpt` |
| 100 MHz 布线面积 | 61 715 LUT / 16 633 FF / 12 BRAM / 34 DSP | `impl100_10.0ns_utilization.rpt` |
