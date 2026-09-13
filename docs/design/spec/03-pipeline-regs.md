# SPEC-03 流水级寄存器、表项格式与接口 bundle

> 上游：`00-conventions.md`、`02-uop-and-decode.md`。本文件定义**所有跨模块接口**的位域，是并行开发各模块的"接口契约"。

---

## 1. 流水级寄存器（整数最小路径）

| 级间 | 寄存器名 | 字段 |
|---|---|---|
| IF0→IF1 | `if1_pc_q` | `pc[31:0]`, `pred[1:0]`（pred_taken/btb_hit）, `ghr[11:0]`, `ckpt_hint[1:0]` |
| IF1→IF2 | `if2_pc_q` | `pc[31:0]`, `pred[1:0]`, `ghr[11:0]`, `paddr[31:0]`, `hit`, `way[2:0]`, `excp[3:0]`（TLB 缺失/页错误经 IF2 处理） |
| IF2→取指队列 | `fq_wdata_t` | **以 16 B 取指块为单位**写入（块头 + 8 个半字表项，共 732 bit/项，字段定义见 `spec/04-frontend.md` §5）；块内携带 `pc/pred/ghr/excp/excp_tval`，半字携带 RVC 边界信息 |
| ID→RN | `uop_id_t` | §2.1 |
| RN→DP | `uop_rn_t` | §2.2 |
| IS→EX | `ex_bundle_t` | §2.3 |
| EX→MEM | `mem_bundle_t` | `pd[6:0]`, `rob_idx[6:0]`, `alu_result[31:0]`, `store_data[31:0]`, `mem_op[2:0]`, `mem_size[1:0]`, `mem_flags[1:0]`, `amo_op[4:0]`, `amo_flags[1:0]`, `wb_sel[2:0]`, `excp_valid`, `excp_cause[3:0]`, `excp_tval[31:0]`, `is_fp_dest` |
| MEM→WB | `wb_bundle_t` | `pd[6:0]`, `rob_idx[6:0]`, `result[31:0]`, `load_data[31:0]`, `wb_sel[2:0]`, `rd_is_fp`, `excp_valid`, `excp_cause[3:0]`, `excp_tval[31:0]`, `mem_fault_valid` |
| WB→RT | ROB 表项更新（§4） | — |

## 2. 接口 bundle

### 2.1 `uop_id_t`（ID → RN，每拍 `CORE_WIDTH` 条）

| 字段 | 宽度 | 说明 |
|---|---|---|
| `valid` | 1 | 本槽有效 |
| `pc` | 32 | 指令 PC |
| `instr` | 32 | 原始指令（RVC 已展开） |
| `imm` | 32 | 立即数 |
| `rs1_arch`, `rs2_arch`, `rd_arch` | 5×3 | 架构寄存器号 |
| `csr_addr` | 12 | CSR 地址 |
| `ctrl` | 73 | 见 `02-uop-and-decode.md` §2 |
| `pred` | 2 | `{pred_taken, btb_hit}` |
| `ghr` | 12 | 预测时 GHR |
| `excp_cause` | 4 | 译码期异常 |

### 2.2 `uop_rn_t`（RN → DP → IQ/LSQ）

| 字段 | 宽度 | 说明 |
|---|---|---|
| `valid` | 1 | — |
| `ctrl` | 73 | 控制位（`uop_ctrl_t`，含 `use_rs3`） |
| `pc` | 32 | — |
| `imm` | 32 | — |
| `ps1`, `ps2`, `ps3` | 7×3 | 源物理寄存器号（`use_rsX=0` 时仍填 P0）；`ps3` 仅 FMA 使用（`use_rs3`，架构源 `instr[31:27]`） |
| `pd` | 7 | 目标物理寄存器号（不写寄存器时填 P0） |
| `rob_idx` | 7 | ROB 索引 |
| `lsq_idx` | 5 | LSQ 索引（仅访存类） |
| `pred`, `ghr` | 2+12 | 供 RT 更新预测器 |

### 2.3 `ex_bundle_t`（IS → EX）

| 字段 | 宽度 | 说明 |
|---|---|---|
| `valid` | 1 | — |
| `ctrl` | 73 | 控制位整体携带（执行单元各取所需） |
| `pd`, `rob_idx` | 7+7 | — |
| `op_a`, `op_b` | 32+32 | 经旁路网络后的操作数（A = rs1/pc/zero，B = rs2/imm/4） |
| `pc`, `imm` | 32+32 | 分支目标/AGU 用 |
| `fp_op_a`, `fp_op_b`, `fp_op_c` | 64×3 | 浮点操作数（含 FMA 的第三操作数） |

### 2.4 写回 bundle（EX/MEM/WB → PRF/ROB/IQ）

| 字段 | 宽度 | 说明 |
|---|---|---|
| `wb_valid[WB_PORTS-1:0]` | 6 | 每写口一位 |
| `wb_pd[i]` | 7 | 目标物理寄存器号（唤醒 tag） |
| `wb_data[i]` | 32/64 | 写回数据（整数 32 / 浮点 64） |
| `wb_is_fp[i]` | 1 | 写口类型 |
| `wb_rob_idx[i]` | 7 | 标记 ROB 完成 |
| `wb_excp_valid[i]`, `wb_excp_cause[i]` | 1+4 | 执行期异常 |

**写口分配**：0=ALU0/BRU 合并、1=ALU1、2=MDU、3=LSU、4=FPU、5=CSR/SYS（系统类不写 PRF，仅标记 ROB 完成）。

**补充字段（与 `05-ooo-core.md` §5 对齐）**：写口 0 另携带 `wb_br_valid/wb_br_taken/wb_br_target[31:0]/wb_br_rob_idx[6:0]`（分支解析结果，用于前端重定向与 checkpoint 释放）；写口 3 另携带 `wb_st_ready`（store 地址+数据就绪，供 LSQ 转发与违例检测），以及 `wb_ld_fault_valid/wb_ld_fault_cause[3:0]/wb_ld_fault_va[31:0]`（load 异常信息写入 LSQ/ROB）。

### 2.5 重定向/清空广播

| 信号 | 宽度 | 说明 |
|---|---|---|
| `redirect_valid` | 1 | 前端立即重定向 |
| `redirect_pc` | 32 | 新 PC |
| `redirect_rob_idx` | 7 | 发起者的 ROB 索引（年轻者作废） |
| `redirect_is_trap` | 1 | 来自 trap（用于 IF2 抑制取指） |
| `flush_all` | 1 | 全清（复位/异常/中断/调试） |

### 2.6 MMU 接口（IF/LSU ↔ TLB/PTW）

| 信号 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `mmu_req_valid` | → | 1 | 翻译请求 |
| `mmu_req_va` | → | 32 | 虚拟地址 |
| `mmu_req_asid` | → | 9 | 当前 ASID（来自 `satp`） |
| `mmu_req_priv` | → | 2 | 有效特权级（含 MPRV 修正） |
| `mmu_req_type` | → | 2 | 0=取指 1=load 2=store 3=AMO |
| `mmu_req_is_fp` | → | 1 | 浮点访存（不影响翻译，仅错误归因） |
| `mmu_resp_valid` | ← | 1 | 翻译完成 |
| `mmu_resp_pa` | ← | 32 | 物理地址 |
| `mmu_resp_fault` | ← | 1 | 页错误 |
| `mmu_resp_cause` | ← | 4 | 12/13/15 |
| `mmu_resp_tval` | ← | 32 | 出错虚拟地址 |
| `mmu_busy` | ← | 1 | PTW 正在遍历（LSU 需等待） |
| `sfence_valid` / `sfence_va` / `sfence_asid` / `sfence_all` | → | 1/32/9/1 | 提交级 TLB 失效请求 |

### 2.7 CSR 接口（读写端口）

| 信号 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `csr_raddr` / `csr_rdata` | 执行级读 | 12 / 32 | 读 CSR（组合读，EX 级用） |
| `csr_waddr` / `csr_wdata` / `csr_wen` | 提交级写 | 12 / 32 / 1 | **只在 RT 级生效**（精确） |
| `csr_wmask` | 提交级写 | 32 | `csrrw/s/c` 的掩码语义（RW=全 1，RS=原值，RC=原值取反） |
| `trap_valid` / `trap_cause` / `trap_tval` / `trap_priv` | 提交级 | 1/4/32/2 | 触发陷阱，CSR 内部生成 `mepc` 等 |
| `intr_pending[5:0]` | CSR→RT | 6 | `{MSI,MTI,MEI,SSI,STI,SEI}` 采样结果 |
| `priv_mode[1:0]` | CSR→全核 | 2 | 当前特权级 |

### 2.8 LSU ↔ Cache/AXI

| 信号 | 宽度 | 说明 |
|---|---|---|
| `dc_req_valid`, `dc_req_we`, `dc_req_addr[31:0]`, `dc_req_wdata[31:0]`, `dc_req_wstrb[3:0]`, `dc_req_size[1:0]`, `dc_req_amo[5:0]`（op+aq+rl）, `dc_req_lr/sc` | — | L1D 请求 |
| `dc_resp_valid`, `dc_resp_rdata[31:0]`, `dc_resp_fault`, `dc_resp_cause[3:0]` | — | L1D 响应 |
| `l2_req_*`（来自 L1I refill / L1D refill / 写回 / 非缓存） | — | L2 仲裁（4 源） |
| `l2_resp_valid`, `l2_resp_rdata[255:0]` | — | L2 返回整行（32 B） |
| `axi_*` | — | 标准 AXI4，见 `06-bus-axi.md`（平台契约） |

## 3. 发射队列表项（`iq_entry_t`，各类队列共用格式）

| 字段 | 宽度 | 说明 |
|---|---|---|
| `valid` | 1 | 表项有效 |
| `issued` | 1 | 已发射（等待写回） |
| `ready1`, `ready2` | 1+1 | 源操作数就绪（写回总线置位） |
| `ps1`, `ps2`, `pd` | 7×3 | 物理寄存器号 |
| `rob_idx` | 7 | ROB 索引（用于清空与提交排序） |
| `lsq_idx` | 5 | 访存类专用 |
| `age` | 5 | 老化计数（用于最老优先选择；与 ROB 索引二选一，见 `05-ooo-core.md`） |
| `ctrl` | 73 | 控制位（`uop_ctrl_t`，含 `use_rs3`） |
| `imm`, `pc` | 32+32 | 立即数与 PC |

**深度**：整型 32（IQ_INT_DEPTH）、访存 24（IQ_MEM_DEPTH）、浮点 16（IQ_FP_DEPTH）。

**选择规则**：每个队列每周期选出"最老且 ready 的 N 条"（N = 该队列可用的执行口数）；用 `rob_idx` 的年龄比较（环形差值）实现"最老优先"，无需额外 age 字段（可省略 `age`，由 `rob_idx` 判断）。

## 4. ROB 表项（`rob_entry_t`，128 bit）

| 位段 | 字段 | 说明 |
|---|---|---|
| `[0]` | `valid` | 表项有效（可被覆盖） |
| `[1]` | `done` | 执行完成 |
| `[2]` | `rd_wen` | 写架构寄存器 |
| `[3]` | `rd_is_fp` | 目标为浮点 |
| `[8:4]` | `rd_arch` | 架构目标寄存器号 |
| `[15:9]` | `pd` | 新物理寄存器号 |
| `[22:16]` | `pd_old` | 旧物理寄存器号（提交时回收） |
| `[23]` | `excp_valid` | 该指令产生异常 |
| `[27:24]` | `excp_cause` | 异常码（4 bit） |
| `[28]` | `is_store` | store 类（提交时落盘） |
| `[29]` | `is_branch` | 分支类（提交时更新预测器） |
| `[30]` | `is_serial` | 串行化（CSR/SYS/FENCE，单独提交并暂停后续提交一拍） |
| `[31]` | `is_amo` | 原子指令（提交时释放保留集） |
| `[95:32]` | `payload[63:0]` | **按类型复用**（见下） |
| `[127:96]` | `pc[31:0]` | 指令 PC |

**`payload` 复用规则**（由 `is_store`/`is_branch`/`is_serial` 选择）：

| 类型 | payload 内容 |
|---|---|
| store / AMO | `{lsq_idx[4:0], mem_size[2:0], mem_flags[1:0], pad}`（数据与地址在 LSQ 中） |
| branch | `{ckpt_idx[1:0], actual_taken, is_call, is_ret, actual_target[31:0], ghr_snapshot[11:0], pad}` |
| serial（CSR/SYS） | `{csr_addr[11:0], csr_wdata[31:0], csr_op[1:0], csr_imm, sys_op[2:0], is_fence, is_fencei, is_sfence, cbo_op[1:0], pad}` |
| 其它（含异常） | `{excp_tval[31:0], pad}`；**访存类异常的 tval 取自 LSQ 表项的 `fault_va`** |

## 5. LSQ 表项

### 5.1 基本字段（load/store 共用，每项）
`valid`, `rob_idx[6:0]`, `pd[6:0]`, `addr[31:0]`, `addr_valid`, `data[31:0]`, `size[2:0]`, `is_fp`, `unsigned`, `fault_valid`, `fault_cause[3:0]`, `fault_va[31:0]`, `fwd_hit`, `replay`, `committed`

### 5.2 load 队列（32 项）
- 状态：`WAIT_ADDR`（地址未生成）→ `WAIT_TRANS`（等 MMU）→ `ISSUED`（已访问 Cache，等待数据）→ `DONE`（可写回）
- 缺失时挂起在 MSHR 上（记录 MSHR 索引），回填后重新访问 Cache（不重新占用 IQ）

### 5.3 store 队列（32 项）
- 状态：`WAIT_ADDR` → `WAIT_DATA` → `READY`（地址/数据齐备）→ `COMMITTED`（ROB 提交，已写入 Cache/Store Buffer）
- **store→load 转发**：load 在 MEM 级与所有更老的 `READY/COMMITTED` store 做地址比较（按字节），命中则转发
- **违例检测**：load 已发射后，若有更老 store 地址变有效且重叠 → 置 `replay`

## 6. 重命名结构

| 结构 | 位域 | 深度 |
|---|---|---|
| RAT（整数/浮点各一份） | `map[31:0] × 7 bit` | 32 项（架构寄存器 → 物理寄存器） |
| 空闲表 | `free_vec[127:0]`（1=空闲） | 128 位向量，优先编码器每周期分配 4 个 |
| 忙表 | `busy_vec[127:0]`（1=未就绪） | 唤醒时清零 |
| Checkpoint | `{rat_int[32×7], rat_fp[32×7], fre_vec[128], ras_ptr[4:0], ras_top[31:0], ghr[11:0]}` | 4 个（分支时分配） |
| 架构 RAT（提交用） | 同 RAT | 提交时同步更新，异常恢复用 |

**P0 约定**：物理寄存器 0 恒为 0（不分配、不回收、不唤醒），`x0` 恒映射到 P0。

## 7. 主要模块端口清单（框架级）

### 7.1 `core_top`（平台兼容壳，端口与 chiplab 契约完全一致，见 `../06-bus-axi.md` §1）

```verilog
module core_top(
  input  wire        aclk, aresetn,
  input  wire [7:0]  intrpt,
  // AXI4 主设备（32 位数据；`AXI64/`AXI128 时相应加宽）
  output wire [3:0]  arid,   output wire [31:0] araddr, output wire [3:0] arlen,
  output wire [2:0]  arsize, output wire [1:0]  arburst,output wire [1:0] arlock,
  output wire [3:0]  arcache,output wire [2:0]  arprot, output wire       arvalid,
  input  wire        arready,
  input  wire [3:0]  rid,    input  wire [31:0] rdata,  input  wire [1:0] rresp,
  input  wire        rlast,  input  wire        rvalid, output wire       rready,
  output wire [3:0]  awid,   output wire [31:0] awaddr, output wire [3:0] awlen,
  output wire [2:0]  awsize, output wire [1:0]  awburst,output wire [1:0] awlock,
  output wire [3:0]  awcache,output wire [2:0]  awprot, output wire       awvalid,
  input  wire        awready,
  output wire [3:0]  wid,    output wire [31:0] wdata,  output wire [3:0] wstrb,
  output wire        wlast,  output wire        wvalid, input  wire       wready,
  input  wire [3:0]  bid,    input  wire [1:0]  bresp,  input  wire       bvalid,
  output wire        bready,
  // 平台调试/difftest
  input  wire        break_point, infor_flag,
  input  wire [4:0]  reg_num,
  output wire [31:0] rf_rdata,
  output wire        ws_valid,
  output wire [31:0] debug0_wb_pc,
  output wire [3:0]  debug0_wb_rf_wen,
  output wire [4:0]  debug0_wb_rf_wnum,
  output wire [31:0] debug0_wb_rf_wdata
);
```

### 7.2 其余模块的接口以 `§2` 的 bundle 为准

各子模块（`bpu_top`、`icache`、`fetch_queue`、`decoder`、`rat`、`freelist`、`rob`、`iq_*`、`prf`、`alu`、`mdu`、`fpu_top`、`lsu`、`dcache`、`l2_cache`、`tlb`、`ptw`、`pmp`、`csr_file`、`clint`、`plic`、`axi_master`、`uncached_unit`）的**详细端口在对应子系统规格中给出**（`04`~`08`），但必须遵守本节定义的 bundle 位域与握手语义。

## 8. 一致性检查清单（模块联调前逐项核对）

- [ ] `uop_ctrl_t` 位域与 `rv32gc_defs.vh` 中的宏一致（用脚本比对两份定义）；
- [ ] `rob_entry_t` 的 payload 复用规则在 RN/EX/MEM/WB/RT 五处理解一致；
- [ ] 所有清空广播使用同一 `flush_rob_idx` 语义（环形年龄比较函数统一放在 `rv32gc_defs.vh`）；
- [ ] 写回口数量与仲裁优先级一致（0=ALU0/BRU、1=ALU1、2=MDU、3=LSU、4=FPU、5=CSR/SYS）；
- [ ] 所有「有效位 + 索引」的结构在清空时按年轻者作废，且**不误清更老的表项**；
- [ ] CSR 写只在 RT 级生效，执行级读为组合读（`csr_raddr`→`csr_rdata` 同拍）。
