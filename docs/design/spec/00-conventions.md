# SPEC-00 全局设计约定（编码规范、握手、命名、参数）

> 本文件是 `docs/design/spec/` 下所有模块规格的**共同基础**，写 RTL 前必须先读本文件。
> 上游：`../00-overview.md`；微指令格式见 `02-uop-and-decode.md`；流水级寄存器见 `03-pipeline-regs.md`。

---

## 1. 语言与编码风格

| 项目 | 约定 |
|---|---|
| 语言 | Verilog-2001 可综合子集 + `ifdef` 宏；**不使用 SystemVerilog 专有语法**（保证 iverilog/verilator/XSim 都能编译） |
| 文件 | 一个文件一个模块，文件名 = 模块名（`rv32_alu.v`）；包/宏放 `rtl/pkg/rv32gc_defs.vh` |
| 端口 | 全部 `input/output`（不用 `inout`）；时钟 `clk`、同步复位 `rst_n`（低有效）；端口按功能分组并用注释分隔 |
| 命名 | 小写下划线；`*_q` = 寄存器输出，`*_d`/`*_next` = 组合下一拍值，`*_en` = 使能，`*_val` = 有效，`*_rdy` = 就绪 |
| 位序 | `[MSB:LSB]`；常量带位宽（`32'd0`） |
| 组合逻辑 | `always @(*)` + `default` 赋值，避免 latch；三态与 `x` 传播仅用于仿真断言 |
| 时序逻辑 | 统一 `always @(posedge clk) if (!rst_n) ... else ...`（同步复位，便于 FPGA 时序收敛） |
| 存储器 | BRAM 推断：``(* ram_style = "block" *)``；分布式 RAM：``(* ram_style = "distributed" *)``；**不手工例化原语** |
| 断言 | `` `ifdef SIM_ASSERT `` 包裹，仅仿真综合；不在综合路径中引入 `$display` |
| 参数化 | 通过 `` `define ``（`CORE_WIDTH`、`AXI64`、`AXI128`、`RV32GC_DEBUG`）在编译期配置，**不使用 Verilog parameter 传递跨模块配置**（避免端口爆炸） |

## 2. 时钟、复位与同步

| 项目 | 约定 |
|---|---|
| 时钟域 | 全核单时钟 `clk`（= 平台 `cpu_clk`）；平台 uncore 的 CDC 由 `axi_clock_converter_0` 完成，核内不处理 |
| 复位 | 外部 `aresetn`（异步、低有效）→ 核内两级同步器 → 同步复位 `rst_n`（**低有效，同步释放**） |
| 复位值 | PC = `` `RESET_PC ``（默认 `32'h0000_0000`）；CSR 取规范复位值；Cache/TLB/BPU 的 valid 位清零；ROB/IQ/LSQ 的空标志置位 |
| 复位后首条指令 | 从 `RESET_PC` 取指，特权级 = M，`mstatus.MIE=0` |

## 3. 流水线握手与"清空（flush）"协议

前端采用 **valid/ready** 双向握手，后端采用 **有效位 + 清空广播**：

| 机制 | 语义 |
|---|---|
| `valid`/`ready` | 上游发 `valid`，下游在 `ready` 为高的同拍接收；**同一拍完成传输**（无 skid 语义歧义） |
| `stall` | 后端容量不足时拉低对应 `ready`（`rob_full`、`iq_full[type]`、`lsq_full`） |
| `flush_valid` | 清空广播，携带 `flush_rob_idx[6:0]`：**所有 `rob_idx` 比它年轻的 uop 全部作废** |
| `flush_all` | 全清（复位、`fence.i`、异常/中断、调试断点） |
| 重定向 | `redirect_valid` + `redirect_pc[31:0]` + `redirect_rob_idx[6:0]`：前端立刻从新 PC 取指，后端同时按下述规则清空 |
| 清空的**年龄定义** | ROB 索引是循环队列下标；"更年轻"用索引差值判断：`is_younger(a,b) = ((a - b) & 7'h7f) != 0 && ((a - b) & 7'h7f) < 64`（128 项环形） |

**谁发起清空**：BRU 误预测（含 `jalr`）、LSU 重放（replay）、CSR/异常提交、`sfence.vma`/`fence.i` 提交、调试断点、PLIC/CLINT 中断提交。

## 4. 流水级与命名对应

| 级 | 前缀 | 说明 |
|---|---|---|
| IF0 | `if0_` | PC 生成 + BPU 查询 |
| IF1 | `if1_` | I-Cache 读（BRAM 输出） |
| IF2 | `if2_` | 命中判定 + 取指队列写入 |
| ID | `id_` | 译码 + RVC 展开 |
| RN | `rn_` | 重命名 + ROB/空闲表分配 |
| DP | `dp_` | 分发到 IQ/LSQ |
| IS | `is_` | 发射（唤醒/选择/读 PRF） |
| EX | `ex_` | 执行 |
| MEM | `mem_` | 访存 |
| WB | `wb_` | 写回 + 唤醒 |
| RT | `rt_` | 提交 |

## 5. 关键参数

| 宏 | 默认 | 含义 |
|---|---|---|
| `CORE_WIDTH` | 4 | 取指/译码/重命名/发射/提交宽度（可为 2 的降级配置） |
| `ROB_DEPTH` | 128 | ROB 项数（必须是 2 的幂） |
| `IQ_INT_DEPTH` | 32 | 整型发射队列深度 |
| `IQ_MEM_DEPTH` | 24 | 访存发射队列深度 |
| `IQ_FP_DEPTH` | 16 | 浮点发射队列深度 |
| `LSQ_LD_DEPTH` | 32 | load 队列深度 |
| `LSQ_ST_DEPTH` | 32 | store 队列深度 |
| `PRF_INT_DEPTH` | 128 | 整数物理寄存器数 |
| `PRF_FP_DEPTH` | 128 | 浮点物理寄存器数 |
| `PREG_IDX_W` | 7 | 物理寄存器索引位宽 |
| `ROB_IDX_W` | 7 | ROB 索引位宽 |
| `BTB_ENTRIES/BTB_WAYS` | 512 / 4 | BTB 容量与相联度（74 bit/路，见 `04-frontend.md` §3） |
| `GPHT_ENTRIES/LPHT_ENTRIES/CPHT_ENTRIES/LHT_ENTRIES` | 4096/4096/4096/1024 | 锦标赛预测器各表（Gshare 全局 PHT、局部 PHT、选择器 PHT、局部历史表） |
| `RAS_DEPTH` | 32 | 返回地址栈深度（指针 `ras_ptr[5:0]`，6 位以支持 32 项 + 空/满判定） |
| `AXI_DATA_W` | 32（`` `AXI64 `` → 64、`` `AXI128 `` → 128） | AXI 数据宽度 |
| `CACHE_LINE` | 32 B | 所有 Cache 的行大小（含 L2） |
| `PADDR_W` | 32 | 物理地址宽度 |
| `VADDR_W` | 32 | 虚拟地址宽度 |

## 6. 目录与文件规划（阶段二实现时按此落地）

```
rtl/
├── pkg/rv32gc_defs.vh        # 宏、编码常量、uop 位域定义
├── top/core_top.v            # 平台兼容壳（AXI/调试/中断/时钟复位）
├── top/rv32gc_core.v         # 核内顶层（前端+后端+存储+特权）
├── frontend/pc_gen.v  bpu_top.v  btb.v  gshare.v  local_pht.v  chooser.v  ras.v
│            icache.v  fetch_queue.v  rvc_expand.v
├── decode/decoder.v  imm_gen.v  uop_pack.v
├── rename/rat.v  freelist.v  checkpoint.v  rob.v
├── issue/iq_int.v  iq_mem.v  iq_fp.v  wakeup_select.v  prf.v  bypass.v
├── exec/alu.v  bru.v  mul_dsp.v  div_iter.v  agu.v
│        fpu_top.v  fma.v  fdiv.v  fcvt.v  fcmp.v  fclass.v
├── mem/lsu.v  lsq.v  dcache.v  store_buffer.v  stld_predictor.v  mshr.v  l2_cache.v
├── mmu/tlb.v  ptw.v  pmp.v
├── csr/csr_file.v  trap_ctrl.v  clint.v  plic.v  counter.v
└── bus/axi_master.v  uncached_unit.v  addr_decode.v
sim/tb/…            # 见 ../08-verification.md
```

## 7. 调试与可观测性接口（贯穿所有模块）

| 信号 | 约定 |
|---|---|
| `dbg_commit_valid` / `dbg_commit_pc` / `dbg_commit_rd` / `dbg_commit_wdata` / `dbg_commit_wen` | RT 级每条提交指令产生一拍；**格式固定**，用于与 Spike 轨迹比对（见 `09-verification-interface.md`） |
| `dbg_state[7:0]` | 编码当前特权级 + 流水线状态（供 ILA/数码管显示） |
| 性能计数 | `perf_cnt_*`：分支数/误预测数、I-Cache 缺失、D-Cache 缺失、L2 缺失、发射槽空、ROB 满周期数（可读 `mhpmcounter` 或专用调试寄存器） |

## 8. 待实现顺序（RTL 开发顺序，自底向上）

1. `pkg` + `alu` + `mul_dsp` + `div_iter`（单元测试）
2. `decoder` + `imm_gen` + `uop_pack`（对照 RV32IMAFDC 译码表逐条测试）
3. `csr_file` + `trap_ctrl` + `clint` + `plic` + `pmp`
4. `icache` + `dcache` + `l2_cache` + `mshr` + `store_buffer`
5. `tlb` + `ptw`
6. `axi_master` + `uncached_unit` + `addr_decode`
7. `pc_gen` + `bpu_*` + `fetch_queue`（顺序核先用简单 BPU，后替换为锦标赛）
8. `core_top` + 顺序 5 级流水集成（阶段 2A 交付）
9. `rat` + `freelist` + `rob` + `iq_*` + `prf` + `lsq` + `stld_predictor` → 乱序集成（阶段 2B）
