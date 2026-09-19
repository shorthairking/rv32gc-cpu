# T2 报告 —— 非 FPU 核关键路径流水化 + 隐式声明修复

> 任务：T2（非 FPU 归因核布线后 **WNS ≥ 0 @ 60 MHz**）+ M4 遗留 T4（`core_top.v` 13 处
> `[Synth 8-8895]` 隐式声明清零）。
> 交付 RTL md5：`rtl/top/core_top.v = 43cbbe2ee846c1393a2125b78d3bfaaf`、
> `rtl/csr/csr_file.v = bbd4b4d14c0b9c3e89f942f3d395551b`。
> 走查口径：`fpga/scratch/nofpu_synth.tcl 16.667` + `fpga/scratch/nofpu_impl.tcl 16.667`
> （FPU 摘除机制**未改**：仍排除 `rtl/exec/fpu*.v` 并读 `fpga/scratch/nofpu/fpu_stub.v`）。

---

## 一、结论（判据逐条）

| 判据 | 基线（M4，`fpga/out/scratch_nofpu_impl_timing_summary.rpt` 等） | 本次交付 | 判定 |
|---|---|---|---|
| ① 综合 `SYNTH_OK` + WNS 优于基线 | −2.783 ns（Fmax 51.41 MHz） | **+0.649 ns（Fmax 62.43 MHz）** | ✅ 改善 3.432 ns |
| ② 布线 `RESULT_NOFPU_IMPL: OK` 且 **WNS ≥ 0 @60 MHz** | −5.812 ns（44.49 MHz；2115 失败端点；"Timing constraints are not met"） | **+0.010 ns（Fmax 60.03 MHz）**；WHS +0.048；**0 失败端点**；"All user specified timing constraints are met." | ✅ 改善 5.822 ns / +15.54 MHz |
| ③ `[Synth 8-8895]` 计数 = 0 | 13 | **0** | ✅ |
| ④a `./scripts/regress.sh` | 23/23 | **23/23 PASS**（默认 300 s 单 TB 超时） | ✅ |
| ④b `--group rv32i/I --jobs N` | 39/39 | **39/39 PASS** | ✅ |
| ④c `--group 'tests/priv/PMP*'` | 63/63 | **63/63 PASS** | ✅ |
| ④d `--group Sv` | 29/29 | **29/29 PASS** | ✅ |
| ⑤ 反证链（旁路新增寄存级 ⇒ 时序回退） | — | 旁路 L1D 请求寄存级后：综合 −0.290 ns / 布线 **−0.437 ns（58.47 MHz）**（同一流程同一脚本） | ✅ 回退 0.447 ns |
| 附加（交付版 RTL 复跑） | — | **rv32i/F 80/80**、M 8/8、Zicsr 6/6、Zifencei 1/1、Zicbom 3/3、Zaamo 9/9、Zalrsc 2/2、SvPMP 4/4、Svade 2/2、Svbare 3/3、SvZicbo 2/2、SvPMPZicbo 4/4 **全绿** | ✅ |

面积（布线后）：Slice LUT 37201（27.80%，基线 37382）／FF 15695／BRAM 12／DSP 12
—— 加寄存器后 LUT **未增反降**（寄存器化让 opt/phys_opt 少掉了若干重复逻辑）。

---

## 二、改动清单（逐处：路径 → 位置 → 时钟/复位/使能口径 → 为何语义不变）

> 全部改动只加**时序寄存器/输出口**，不改任何判定式、优先级、协议或激励关系。
> 所有新寄存级一律：时钟 `aclk`（唯一时钟）、异步低有效复位 `aresetn`、
> 复位值 = 该信号的"空/无效"值（0），与同文件既有寄存器完全同口径。

### 1. PLIC/CLINT 中断判决输出寄存一拍（`core_top.v` §8.1）
- **路径**：`u_plic/threshold_r →（32 源优先级树 + 阈值比较 + 仲裁）→ plic_meip/seip
  → csr_file mip 组合视图 → trap_ctrl → trap_valid/m_kill_fsm → M 级访存路由与
  L1D 阵列使能`（默认流程最差路径 37 级 / 22.8 ns，route 77%）。
- **位置**：`plic_meip_sync_q/plic_seip_sync_q/clint_msip_sync_q/clint_mtip_sync_q`，
  在 `plic`/`clint` 例化与 `csr_file.irq_*` 之间；**不写进 plic.v/clint.v**
  （那两个模块的单元 TB 在同拍检查 `meip_o/seip_o`，会破既有判据）。
- **语义**：中断源是异步外部事件，ISA 不约束"源拉高→mip 可见"的拍数；源为电平，
  寄存不会丢中断；`mip` 的**软件可写位**不经此处 ⇒ CSR 读写/WARL/同拍旁路不变。
  唯一可观测差异：中断被看到晚 1 拍（陷阱入口晚 1 拍）。

### 2. L1D 请求判决寄存一拍（`core_top.v` §9.6）
- **路径**：`M 级路由/写使能判定（lsu_exc/lsu_route/m_mem_wr_op…）→ l1d_cs_req →
  L1D 全部内部寄存器 CE/S/R 脚与 BRAM ENBWREN`（默认流程 37 级；post-synth 归因中
  失败端点绝大多数是 L1D 内部 CE/S/R：plru_*×768、wb_buf×224、acc_* …）。
- **位置**：`l1d_req_q/l1d_we_q/l1d_paddr_q/l1d_vaddr_q/l1d_strb_q/l1d_wdata_q`；
  输出侧保留 `~m_kill_fsm`（与改前**逐字同式**）。
- **语义**：请求仍是单拍脉冲（源 `m_l1d_go|PTER|PADW` 都是 1 拍态）；L1D 的
  `cs_ready/cs_wr_done/cs_miss` 相应晚 1 拍，而 M 级 FSM 在这些状态**等的就是电平**
  ⇒ 只多等 1 拍；冲刷拍不产生访问这条**没有丝毫放松**（错路径 store 依旧不可能落阵列）；
  相邻两笔 L1D 访问之间至少隔 1 个非请求态 ⇒ 不丢请求；**访问笔数不变**。

### 3. L1D 维护脉冲寄存一拍 + `fencei_hold` + `M_S_CMO` 守卫（`core_top.v` §9.6/§13）
- **路径**：`sfence_sync_pending / l1d_cmo_inval →（inval_all|clean_all）→ L1D FSM
  的 S/R 脚`（post-synth 最差一族尾部）。
- **位置**：`l1d_maint_inval_q/l1d_maint_clean_q`；`M_S_CMO` 完成判据加
  `~l1d_maint_go`（防"扫描尚未真正启动（maint_q 仍 0、idle 仍 1）"那一拍被误判完成）；
  `fencei_busy_q`→`fencei_hold = fencei_busy | fencei_busy_q`（前端冻结/冲刷延长 1 拍）。
- **语义**：扫描时长（256 拍）与"完成后 idle=1"口径不变，只是**晚 1 拍启动**；
  fencei_hold 保证"前端恢复取指时 L1D 扫描一定已结束"（否则 L1D 在 maint 拍不登记
  访问 ⇒ PTE 读被静默丢弃、FSM 悬挂）；多失效一次无害（ISA 允许 over-fence，L1D 无脏行）。

### 4. 取指异常冻结标志寄存一拍（`core_top.v` §5.2.1）
- **路径**：`取指 PMP 判定 → fetch_exc_valid → fetch_exc_pending → fetch_pause →
  fu_fetch_req_valid → l1i_cs_req → L1I 阵列读使能`（同拍从 PMP 进位链串到 BRAM 使能）。
- **位置**：`fetch_exc_pending_q`，**只**替换 `fetch_pause` 里的那一份；异常**注入**仍用
  当拍 `fetch_exc_pending`（`fetch_exc_inject`）⇒ "异常挂到哪条指令、tval/mepc 取什么"
  逐位不变，仅"F 停止推进"晚 1 拍。代价只在**取指异常**发生时多 1~2 拍（正常路径零代价）。

### 5. AXI 请求仲裁结果寄存一拍（`core_top.v` §11.1）
- **路径**：`翻译后的取指 PA → XIP 判定 → axi_req_*_sel 5 选 1 大 mux →
  axi_req_desc 的 4K 边界/beat 计算 → len_q/beats_q/first_beats_q/addr_q`
  （phys_opt 后最差路径 22.48 ns = logic 6.17 + route 16.31）。
- **位置**：`axi_rq_v_q/owner/addr/beats/iswr`；装载条件 = 控制器 `req_ready`，
  并"优先交接已有登记"⇒ **单笔在途不破、不丢请求**。
- **语义（含一处**关键缺陷修复**，详见 §三）**：交接拍**只对 MDTA**保留冲刷取消
  （与原设计"只有 `m_axi_want` 带 `~m_kill_fsm`、wr/d-fill/i-fill 都不带"**逐条一致**）；
  填充是幂等读、写回写的是已缓存行数据，在冲刷拍放行都安全；MDTA 可能是错路径 store
  （尤其 MMIO 写），必须当拍取消。XIP 地址标签改为在**交接拍**取寄存后的地址，
  与真正发出的地址严格同源。

### 6. 取指侧 TLB 查找结果寄存一拍（`core_top.v` §9.4.1）
- **路径**：`u_fetch_unit/u_pc_gen/pc_r →（TLB VPN/ASID 比较 + 命中优先级 mux）→
  f_tlb_pa → fetch_pc_pa → 取指 PMP → fetch_valid → F→D 载荷 fd_*`（布线后 17.86 ns，route 72%）。
- **位置**：`f_tr_pa_v_q/f_tr_pa_flt_q/f_tr_pa_q/f_tr_pc_q`；使用判据
  `f_tr_res_v = f_tr_pa_v_q & (f_tr_pc_q == fu_fetch_pc)`。
- **语义**：只在 `f_tr_need`（Sv32 且非 M）时多花 1 拍；Bare/M 模式**完全不参与**
  （零拍数变化）；结果必须对应当前 PC（重定向 ⇒ 判据立即为 0 ⇒ 退回"未就绪"、
  冻结 F、压制异常）；`f_tr_ready`（发起页表遍历的判据）仍用**组合** TLB 结果
  ⇒ 命中时绝不误发遍历；**作废条件 `m_kill_fsm | satp_wr_pulse`**（关键：陷阱/xRET
  改特权级后本寄存器停止刷新，若 mret 返回同一 VA 会用到旧翻译 ⇒ 必须显式作废）；
  异常压制改用 `f_tr_use = f_tr_res_v | f_tr_flt_hit`（陈旧 PA 上算出的 PMP/总线异常
  不可能被上报）。

### 7. CMO 探测地址掩码改为"寄存器选择"（`core_top.v` §11.1/§13）
- **路径**：`em_rs1_val → lsu(amo/PMP) → m_cmo_probe_go → m_mmio_pa_q 的 D 端 mux`
  （综合最差路径 16.015 ns）。
- **位置**：`m_mmio_pa_q` 改为**无条件**锁存 `m_pa_eff`；块对齐掩码挪到使用处
  `m_mmio_pa_eff = m_cmo_probe_q ? (m_mmio_pa_q & M_CMO_BLOCK_MSK) : m_mmio_pa_q`
  （选择端是**寄存器** `m_cmo_probe_q`）。
- **语义**：`m_mmio_pa_q` 的唯一使用处就是 MDTA 请求地址，而"是否 CMO 探测笔"由
  寄存器 `m_cmo_probe_q`（探测期间恒 1）表征 ⇒ 两种写法在探测拍给出**逐位相同**的地址。

### 8. `csr_file` 增加 xRET 专用 `mepc_o/sepc_o` 出口（`csr_file.v` + `core_top.v`）
- **路径**：`全部 CSR 寄存器 → 地址译码 → 组合读口大 mux（csr_rdata_raw）→
  xret_epc_pc → pc_gen → pc_r/D`。
- **位置**：`csr_file` 新增两个**只增不改**的输出口（取值 `{mepc_r[31:1],1'b0}` /
  `{sepc_r[31:1],1'b0}`，与读口对同地址的分支**逐位相同**）；`core_top` 的
  `xret_epc_pc` 改取这两个口；`csr_raddr_mux` 与 D 级 CSR 读通路**不动**。
- **语义**：原"借读"读口的唯一用途就是 xRET 重定向，且该拍 D/E/M 槽已被 kill_young 冲刷
  ⇒ 取值口径相同、无副作用。

### 9. 13 处隐式声明修复（`core_top.v`）
清单与位宽核对（"先用后声明"会创建 **1 bit 隐式网**，Vivado 8-8895）：

| # | 标识符 | 使用处 → 原声明处 | 显式位宽（与使用处核对） | 修法 |
|---|---|---|---|---|
| 1 | `e_fp_src2` | §7 FPU 例化 → §12.5 | **64**（`fpu.b` [63:0]）| 前置声明 + 原处改 `assign` |
| 2 | `e_fp_src3` | §7 FPU 例化 → §12.5 | **64**（`fpu.c` [63:0]）| 同上 |
| 3 | `sfence_sync_pending` | §9.3 tlb 例化 → §12.3.1 | 1 | 声明前置到 §1 线网区 |
| 4 | `m_ptw_req_valid` | §9.4.1 assign → 声明区 | 1 | 声明前置 |
| 5 | `m_lsu_req_valid` | §9.5 assign → 声明区 | 1 | 声明前置 |
| 6 | `ptw_pmp_ok` | §9.4 ptw 例化 → §9.4 之后 | 1（`ptw.pmp_resp_ok`）| 声明前置 |
| 7 | `trap_target` | §10 priv_ctrl 例化 → §10 末尾 | **2**（`priv_ctrl.trap_target`[1:0]）| 声明前置 |
| 8 | `trap_we` | §10 csr_file 例化 → §10 末尾 | **4**（`csr_file.trap_we`[3:0]）| 声明前置 |
| 9 | `trap_epc_i` | §10 csr_file 例化 → §10 末尾 | **32** | 声明前置 |
| 10 | `trap_cause_i` | 同上 | **32** | 声明前置 |
| 11 | `trap_tval_i` | 同上 | **32** | 声明前置 |
| 12 | `awlock_raw` | §11.3 axi_master_ctrl 例化 → 例化之后 | **3**（`m_awlock`[2:0]）| 声明前置 |
| 13 | `arlock_raw` | 同上 | **3**（`m_arlock`[2:0]）| 声明前置 |

（另修：`trap_data_i` 随 `trap_*` 组一并前置；`f_tr_res_v/f_tr_use`、`l1d_req_q`
等新引入量也全部满足"先声明后使用"—— iverilog `-Wall` 与 Vivado `8-6901` 均为 0。）

### 10. 实现策略加强（`fpga/scratch/nofpu_impl.tcl`，纯策略参数，不改 RTL/约束）
- 新增 `phys_opt_design -retime`（**布局后寄存器重定时**，保序变换：只沿组合路径
  移动寄存器位置，不改变任何时序行为）—— 实测把布线后 WNS 由 −1.012 推到 −0.279；
- `route_design -directive AggressiveExplore -tns_cleanup`（原 `MoreGlobalIterations`）；
- 收尾 `phys_opt_design -directive Explore`（**在独立实验脚本
  `fpga/scratch/nofpu_postroute_opt.tcl` 上先验证**：WNS −0.279 → +0.010）——
  注意基线用的 `-directive AggressiveExplore` 的 post-route phys_opt 在**本设计
  （含 retime 后网表）**上会让 Vivado 2023.2 **段错误**（非 OOM），故改用 Explore。

---

## 三、过程中发现并修复的**根因级缺陷**（AXI 请求寄存级的静默丢请求）

**现象**：加入第 5 项（AXI 请求寄存级）后，Sv 组由"与基线同集 8 例失败"变为
"另一集 8 例失败"，其中若干例 150 万拍超时；DUT 日志显示
`fetch_pc=0x80000b48 fu_req_v=1 fetch_pause=0`（取指请求挂着）而 AXI 上
**无 AR 在途**、`ar=164 / aw=59827` ⇒ L1I 永远等不到行填充。

**根因**：L1I/L1D 的 `fill_req` **不是无条件保持**的电平 —— L1I 侧
`fill_req = new_miss & ~fill_taken_q`、`new_miss = acc_q & ~any_hit & ~fill_active_q`，
而 `acc_q <= access = cs_req & ~xip_bypass`，`cs_req` 又受 `~fencei_busy` 门控
⇒ **冲刷拍（陷阱/xRET/fence.i/sfence）一到，`fill_req` 会随取指请求一起撤销**。
原设计里"授予 == 同拍接受"（`axi_free` 与 `req_ready` 同拍）⇒ 被授予的填充绝不会丢；
一旦在**交接拍**叠加 `~m_kill_fsm`，就会把"已登记但尚未交接"的填充**静默丢弃**，
而请求方已不再拉高 ⇒ L1I `miss_q=1`、`fill_active_q=0`、无在途填充 ⇒ 永久等响应（死锁）。

**修法**：回到原设计的**逐条**语义 —— 交接拍只对 **MDTA** 取消
（`axi_req_go = axi_rq_v_q & (~axi_rq_is_mdta | ~m_kill_fsm)`），
装载时也不叠加 `~m_kill_fsm`（MDTA 的冲刷门控本来就在 `m_axi_want` 里）。
修复后：**I 39/39、PMP 63/63、Sv 29/29 全绿**，且 `tb_m3_ddr3` 拍数与基线**完全一致**
（853157 拍、AR/AW 笔数一致）⇒ 该寄存级对访存次数零影响。

---

## 四、证据文件

| 证据 | 文件 |
|---|---|
| 交付版复跑命令 | `./fpga/run_vivado_batch.sh fpga/scratch/nofpu_synth.tcl 16.667` → `RESULT_NOFPU: SYNTH_OK WNS=0.649 FMAX=62.43`；`./fpga/run_vivado_batch.sh fpga/scratch/nofpu_impl.tcl 16.667` → `RESULT_NOFPU_IMPL: OK WNS=0.010 WHS=0.048 FMAX=60.03`（交付版 RTL md5 `43cbbe2e…`；两脚本均确定性，可复现） |
| 综合（交付版） | `fpga/out/t2_synth_final.stdout.txt`、`fpga/out/t2_synth9_timing_summary.rpt` |
| 布线（交付版） | `fpga/out/t2_impl_final_timing_summary.rpt`（`WNS 0.010 / WHS 0.048 / 0 失败端点 / All user specified timing constraints are met.`）、`t2_impl_final_timing_paths.rpt`、`t2_impl_final_utilization.rpt` |
| 反证（旁路寄存级；RTL md5 `caec6c5f…`，事后已 cp 还原为 `43cbbe2e…`） | `fpga/out/t2_falsify_impl_timing_summary.rpt`（`RESULT_NOFPU_IMPL: OK WNS=-0.437 WHS=0.060 FMAX=58.47`）、`t2_falsify_synth.stdout.txt`（`SYNTH_OK WNS=-0.290 FMAX=58.97`）、`t2_falsify_impl.stdout.txt` |
| 注 | 每次 Vivado 运行都会覆盖 `fpga/out/<tcl名>.vivado.log` 与 `scratch_nofpu_*`；交付版与反证版的关键行分别留档为上面的 `t2_*_final*` / `t2_falsify_*` 文件（`scratch_nofpu_impl_*` 已回填为交付版结果，`scratch_nofpu_post_{synth,route}.dcp` 亦为交付版） |
| 隐式声明 | `grep -c "8-8895" fpga/out/nofpu_synth.vivado.log` → `0`（基线 M4 日志为 13） |
| 归因分析（诊断用） | `fpga/scratch/nofpu_analyze.tcl` + `fpga/out/scratch_nofpu_analyze.rpt`（失败端点按源/汇聚集、slack 直方图） |
| 后布线收尾实验 | `fpga/scratch/nofpu_postroute_opt.tcl` + `fpga/out/scratch_nofpu_postroute_opt_timing_summary.rpt` |

时序演进（综合 WNS，同一 `nofpu_synth.tcl 16.667`）：

| 阶段 | 综合 WNS | Fmax |
|---|---|---|
| 基线 M4 | −2.783 | 51.41 MHz |
| +①PLIC 中断寄存 ②L1D 请求寄存 ③L1D 维护寄存 ④AXI 请求寄存 ⑤mepc/sepc 出口 ⑥13 处隐式声明 | +0.057 | 60.20 MHz |
| +取指异常冻结标志寄存 | +0.274 | 61.01 MHz |
| +AXI 交接拍冲刷门控**修复**（§三） | +0.659 | 62.47 MHz |
| +取指 TLB 结果寄存 | +0.531 | 61.97 MHz |
| +CMO 掩码寄存器选择（RTL 定版） | **+0.649** | **62.43 MHz** |
| 布线（定版 + retime 策略） | −0.279 | 59.01 MHz |
| 布线（+post-route Explore）→ 交付 | **+0.010** | **60.03 MHz** |

---

## 五、遗留 / 风险

1. **WNS 余量极小（+0.010 ns）**：达标但几乎没有余量；温度/电压/版本变化可能翻负。
   若要余量，建议下一步（**需要扩范围**）：剩余的 2~3 条最差路径的**中段逻辑全部在
   `rtl/mem/lsu.v` / `rtl/mem/amo_unit.v` / `rtl/mem/pmp_check.v` 内**
   （`em_rs1_val/em_imm_val → amo 预约地址/PMP 比较进位链 → lsu_exc/lsu_mtval →
   M 级异常捕获与 FSM 状态`，布线后 16.3~16.8 ns、route 60~75%），
   这三个文件**不在本任务允许改动清单**内 ⇒ 本任务只能在 core_top 侧切割其两端。
   若允许改 `pmp_check.v`（如把 NAPOT 掩码/基址预计算成寄存器，或内部分两级流水），
   或允许改 `lsu.v`（把 PMP 判定出口寄存一拍），预计可再拿 2~4 ns 余量。
2. **拍数代价**：Sv32 生效时**每次 PC 变化多 1 拍**、每笔 L1D 访问多 1 拍、
   每笔 AXI 事务发起多 1 拍、取指异常多 1~2 拍。Bare/M 模式（非 Sv 用例）**零拍数变化**：
   `tb_m3_ddr3` 交付版与基线**同为 853157 拍、提交 171576、AR 22415/AW 22395**，
   逐项一致 ⇒ 架构可见行为未变。arch-test 只看签名，全部复跑为绿。
3. **`fencei_hold` 把 fence.i/sfence.vma 的同步窗口延长 1 拍**（257 拍扫描 + 1），
   属性能代价，无功能影响。
4. **`phys_opt_design -retime` 是网表级保序变换**：RTL 不变，但最终网表的寄存器
   划分由工具决定（交付的"实现"依赖该步骤；若换 Vivado 版本，结果可能不同）。
5. **Vivado 2023.2 的 post-route `phys_opt -directive AggressiveExplore` 在本设计上段错误**
   （`Abnormal program termination (11)`，机器空闲、非 OOM；崩溃发生在布线之后，
   会连带丢掉报告）。当前流程用 `-directive Explore` 规避并成功收敛；
   若换流程需注意该坑。
6. **未提交 git**（按任务要求）；改动文件：`rtl/top/core_top.v`、`rtl/csr/csr_file.v`、
   `fpga/scratch/nofpu_impl.tcl`（新增 `fpga/scratch/nofpu_postroute_opt.tcl`、
   `fpga/scratch/nofpu_analyze.tcl`、`fpga/scratch/nofpu_path1.tcl`）。
   `rtl/exec/fpu*.v`、`rtl/exec/fregfile.v`、`sim/**`、`fpga/tcl/**` **一字未动**。
7. **未验证项**：未跑 D 组（106 例）与 Linux/上板（属其它里程碑）。F 组 80/80 已在
   **交付版 RTL** 上复跑为绿（含 `e_fp_src2/e_fp_src3` 由隐式 1 bit 纠正为 64 bit 之后）。
8. **Aq/Zalrsc、Zicbom、SvZicbo 等 IP 原语/IP 复用红线**：本次未新增任何 IP/原语
   （全部为可综合 RTL 寄存器），亦未触碰 `fpga/tcl/**` 既有语义。
