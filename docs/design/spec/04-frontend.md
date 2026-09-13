# SPEC-04 前端子系统（IF0/IF1/IF2/ID 取指侧）

> 上游：`00-conventions.md`（握手/清空/参数）、`02-uop-and-decode.md`（uop 控制位）、`03-pipeline-regs.md`（bundle/表项）、`../02-branch-predictor.md`（锦标赛预测器）、`../03-cache.md`（L1I）、`../01-pipeline.md`（流水级/重定向）。
> 范围：`rtl/frontend/` 的 `pc_gen.v`、`bpu_top.v`（`btb`/`gshare`/`local_pht`/`chooser`/`ras`）、`icache.v`、`fetch_queue.v`。RVC 展开在 `rtl/decode/rvc_expand.v`，本文件只定义**取指侧半字拼接**。位宽/字段名/握手语义全部沿用上游。

---

## 1. 总体框图与流水时序

### 1.1 结构与各级职责

```
                 ┌──────────┐  fetch_pc ──────────►┌────────────┐ pred_taken/pred_target
   redirect ────►│          │                      │  bpu_top   │ btb_hit/br_type
   trap/xret ───►│  pc_gen  │◄─── if_freeze ───────│ IF0 送址   │
   (RT 级)       │  (IF0)   │                      │ IF1 出结果 │◄─ EX resolve / RT commit
                 └────┬─────┘                      └────────────┘
                      │ pc_if0[31:0]
                      ▼
                 ┌──────────┐  IF1: Tag(4 路)/Data(4 路) BRAM 同步读
                 │ icache   │  IF2: Way 选择 + Tag 比较 + 与 ITLB 权限合并 + 生成 16 B 块
                 └────┬─────┘
                      │ 16 B 块 + fill_valid_hw + fill_excp
                      ▼
                 ┌───────────┐  fq_wdata_t: pc/instr16/pred/ghr/excp
                 │fetch_queue│────────────────────────────────► ID（RVC 对齐 → decoder）
                 │  16 项    │◄── pop_valid / pop_ready ───────
                 └───────────┘
```

| 级 | 模块 | 关键动作 | 路径预算（`../01-pipeline.md` §7） |
|---|---|---|---|
| IF0 | `pc_gen` + BPU 地址 | PC 选择；BTB/Gshare/LHT/CPHT/RAS 同步读送址 | 4.5 ns |
| IF1 | `icache` BRAM | Tag/Data 四路并行读出；BPU 结果寄存输出 | 各 1 周期同步读 |
| IF2 | `icache` 判命 | Way 选择、Tag 比较、ITLB 权限合并、块生成、写队列 | 3.0 ns |
| ID 取指侧 | `fetch_queue` | 半字拼接、按 RVC 边界切最多 4 条、异常随 uop 流动 | 4.0 ns |

前端**顺序**执行：任何重定向清空 IF0~ID 取指侧；后端乱序与之无关。**每周期只做 1 次 BPU 查询**（块内第一个分支），与 `../02-branch-predictor.md` §3.2 一致。

### 1.2 时序表（4 条/周期、16 B/周期）

T 为周期号。预测 taken 不产生气泡：IF0 同拍用 BPU 结果替换顺序 PC。

| 场景 | T | T+1 | T+2 | T+3 | 代价 |
|---|---|---|---|---|---|
| **命中**，无预测跳转 | IF0: PC=P | IF1: BRAM 读 | IF2: 命中，写 16 B | IF0: PC=P+16 | 0（稳态 16 B/拍） |
| **命中**，块内 1 个预测 taken 分支 | IF0: PC=P，BTB 命中 | IF1: 结果出 | IF2: 按 `blk_len` 截断写 <16 B；IF0 已取 target | IF1: target 行读 | **0 气泡** |
| 预测跳转到同一 Cache 行 | IF0: PC=P | IF1: 结果出，IF0: PC=target | IF2: 写块 1（tag/way 复用同拍） | IF2: 写块 2 | 0 |
| **缺失**（首次访问） | IF0: PC=P | IF1: tag 出 | IF2: miss，分配 MSHR，`if_freeze=1` 停写队列 | MSHR_WAIT | L2 命中 12~16 +1 |
| 缺失 → **关键 half 先到** | — | — | — | MSHR_WAIT 收到关键 16 B half | 比整行早 ~4 AXI beat |
| 非关键 half 后到 | — | — | — | REFILL 写另一半并释放 MSHR | 不阻塞已解冻取指 |
| **跨行**（PC[4]=1，块跨两行） | IF0: PC=P | IF1: line A 读 | IF2: 写 A 尾部（`valid_hw` 非满） | IF0: P+16；IF1: line B 读 | 0 停顿，靠掩码表达 |
| **RVC 32 bit 跨 16 B 块** | IF2: 写 8 半字，末半字是 32 bit 低半 | — | — | ID: `carry_valid=1`，等下一块 `hw[0]` | ID 停 1 拍 |
| 32 bit 指令**跨 Cache 行** | 同"跨块"（跨行必先跨块） | — | — | 下一块若 L1I 缺失 → 队列排空 → ID 多停缺失拍数 | 缺失延迟 |
| **重定向**（EX 误预测/`jalr`） | IF0: 旧 PC | flush 清 IF1/IF2/ID/队列；IF0: PC=`redirect_pc` | 新 PC 进 IF1 | IF2 写新块（首块可能不满） | 8~10 周期 |
| `jal` 在 ID 解析 | ID 得目标 | IF0: PC=target | — | — | 比上行早 1 拍 |
| **`fence.i`** 提交 | RT 广播 `flush_all` | 前端全清 + L1I 全清 + MSHR 丢弃，`if_freeze=1` | 从 PC+4 重启，首访必 miss | 关键 half 到 → 恢复 | ≈1 次 L2 往返 |
| trap / mret / sret | RT 广播 | IF0: PC=`trap_pc`/`xret_pc` | 新 PC 进 IF1 | IF2 写新块 | 见 §2.2 |
| 队列满 / ID 反压 | IF2 有数据但 `fq_ready=0` | IF0/IF1 冻结 | — | — | 不丢数据，计 `perf_if_freeze_cycles` |

---

## 2. PC 生成器 `pc_gen`

### 2.1 端口清单（Verilog-2001）

```verilog
`include "rv32gc_defs.vh"   // RESET_PC / VADDR_W / ROB_IDX_W

module pc_gen (
  input  wire                clk, rst_n,
  // —— 复位 / 清空 / 停顿 ——
  input  wire                flush_all,        // 异常/中断/调试/fence.i/sfence：全局清空
  input  wire                fencei_hold,      // fence.i 后停取指直到 L1I 清完
  input  wire                wfi_hold,         // WFI 挂起
  input  wire                if_freeze,        // miss / 队列满 / ID 停顿
  // —— 提交级重定向组 ——
  input  wire                trap_valid,       // RT 级 trap/中断
  input  wire [`VADDR_W-1:0] trap_pc,          // mtvec/stvec(+4*cause)，trap_ctrl 算好
  input  wire                xret_valid,       // mret/sret
  input  wire [`VADDR_W-1:0] xret_pc,          // mepc/sepc
  input  wire                redirect_valid,   // EX/MEM 误预测、jalr、LSU replay、ID 级 jal
  input  wire [`VADDR_W-1:0] redirect_pc,
  input  wire [6:0]          redirect_rob_idx, // 年龄语义见 00-conventions §3
  // —— BPU 反馈 ——
  input  wire                pred_valid,       // 0 = BTB 未命中
  input  wire                pred_taken,
  input  wire [`VADDR_W-1:0] pred_target,      // BTB target 或 RAS 栈顶
  // —— 输出 ——
  output wire [`VADDR_W-1:0] pc_if0,
  output wire                pc_if0_valid,
  output reg  [`VADDR_W-1:0] pc_q              // 顺序取指点
);
```

### 2.2 PC 选择优先级

同拍多源有效时自上而下取第一个有效者；全部无效时 `pc_q + 16`。

| 优先级 | 源 | 条件 | PC 取值 | 清空前端 |
|---|---|---|---|---|
| 0 | 复位 | `!rst_n` | `` `RESET_PC `` | 是 |
| 1 | trap / 中断 | `flush_all && trap_valid` | `trap_pc` | 是 |
| 2 | `mret`/`sret` | `flush_all && xret_valid` | `xret_pc` | 是 |
| 3 | 重定向（EX/MEM） | `redirect_valid`：BRU 误预测/`jalr`/replay | `redirect_pc` | 是（带 `redirect_rob_idx`） |
| 4 | 重定向（ID 级 `jal`） | `redirect_valid`：ID 已解析出目标 | `redirect_pc` | 是（早 1 拍） |
| 5 | 全局清空 | `flush_all` 且无 trap/xret（调试断点、`sfence.vma`） | `pc_q`（原地重取） | 是 |
| 6 | 分支预测 taken | `pred_valid && pred_taken` | `pred_target` | 否 |
| 7 | 停顿 | `wfi_hold` 或 `if_freeze` | `pc_q` | 否 |
| 8 | 顺序 | 默认 | `pc_q + 16` | 否 |

```verilog
always @(*) begin                       // 优先级 8→0 逐级覆盖，与上表一一对应
  pc_next = pc_q + 32'd16;                                     // 8 顺序
  if (pred_valid && pred_taken) pc_next = pred_target;         // 6
  if (flush_all && !trap_valid && !xret_valid) pc_next = pc_q; // 5
  if (redirect_valid)                 pc_next = redirect_pc;   // 3/4
  if (flush_all && xret_valid)        pc_next = xret_pc;       // 2
  if (flush_all && trap_valid)        pc_next = trap_pc;       // 1
  if (!rst_n)                         pc_next = `RESET_PC;     // 0
end
assign pc_if0       = {pc_next[31:1], 1'b0};   // 强制半字对齐，PC[0] 恒 0
assign pc_if0_valid = rst_n && !if_freeze && !wfi_hold && !fencei_hold;
```

> `flush_all` 与 trap/xret 同拍时 trap/xret 优先（优先级 1/2 > 5），陷阱向量必须覆盖"原地重取"。

### 2.3 `+4` 与 `+2`（RVC 半字边界）

- **顺序推进固定 `+16`**：前端以 16 B 块为单位，`pc_q[3:0]==0` 恒成立；RVC 只改变块内指令条数。
- **块内对齐由 `valid_hw[7:0]` 掩码表达**：重定向可落在块内任意偶地址，首块 `valid_hw = 8'hFF << pc[4:1]`（截到行尾）；ID 只让掩码内的半字参与拼接。
- **`+2` 只出现两处**：① ID 拼接 32 bit 指令 `instr32 = {hw_hi, hw_lo}`，`hw_hi` 属于 `PC+2`（可能在下一次取指块）；② 16 bit 指令的 `pc_next = pc+2` 由 ID 的 RVC 对齐逻辑维护，**不进 `pc_gen`**。
- **不做取指地址非对齐检查**：本设计支持 Zca（C 扩展），`IALIGN=16`，规范明确"With the addition of the Zca extension, no instructions can raise instruction-address-misaligned exceptions"（`riscv-isa-manual/src/unpriv/zca.adoc`，norm:Zcanomisaligned；`rv32.adoc` jal/jalr 一节 NOTE 同义）。因此 **BRU/EX 级也不报 cause=0**：JALR 目标由 BRU 清零 `bit0`，分支/JAL 的立即数最低位恒 0，任何取指地址都是合法的 2 字节对齐地址。
- **`misa.C=0` 时**：`pc_if0[1]` 仍允许为 1（目标由软件对齐）；若取到半字边界上的 32 bit 指令，由 ID 报 `illegal_instr`（cause=2），前端不报地址非对齐。

---

## 3. 锦标赛预测器 `bpu_top`

结构与 `../02-branch-predictor.md` 一致：Gshare + 局部历史 + 选择器 + BTB + RAS，每取指块预测 1 个分支。

### 3.1 子表规格与 BTB 表项位域

| 结构 | 深度 × 宽度 | 索引 | 更新时机 |
|---|---|---|---|
| GHR 推测态 / 架构态 | 12 bit / 12 bit | — | EX 解析立即移位（推测）；RT 提交移位（架构）；重定向从 checkpoint 恢复 |
| GPHT | 4096 × 2 bit | `PC[11:0] ^ GHR[11:0]` | 仅 RT 提交 |
| LHT | 1024 × 8 bit | `PC[9:0]` | 仅 RT 提交 |
| LPHT | 4096 × 2 bit | `{LHT[PC[9:0]], pc_fold4}`（§3.2） | 仅 RT 提交 |
| CPHT | 4096 × 2 bit | `PC[11:0] ^ fold6(GHR)` | 仅 RT 提交 |
| BTB | 512 项 4 路（128 组） | 组 `PC[10:2]`，tag `{PC[31:11],PC[1]}` | 仅 RT 提交（分配/替换） |
| RAS | 32 项 × 30 bit（`ra[31:2]`） | 栈指针 `ras_sp[4:0]` | 预测时推测 push/pop；checkpoint 存快照 |

读时序：全部 **IF0 送址 / IF1 出结果**（BRAM 同步读 1 周期）。计数器语义：`00/01` 不跳转倾向，`10/11` 跳转倾向，**高位为方向**。

**BTB 表项位域（每路 74 bit，4 路 = 296 bit/组）**

| 位段 | 字段 | 宽 | 说明 |
|---|---|---|---|
| `[0]` / `[22:1]` | `valid` / `tag` | 1 / 22 | 有效位；`tag={PC[31:11],PC[1]}`，`PC[1]` 区分奇偶半字（RVC 下目标可半字对齐） |
| `[53:23]` | `target[31:1]` | 31 | 分支目标 bit0=0；`jalr`/`ret` 的 bit1 可能出现，故存到 bit1 |
| `[56:54]` / `[58:57]` | `br_type` / `ctr` | 3 / 2 | 0=cond 1=jal 2=jalr 3=ret 4=call 5=jmp；置信度饱和计数器（10/11=高置信） |
| `[62:59]` / `[66:63]` | `blk_len[4:1]` / `b1_off[4:1]` | 4 / 4 | 分支与块内第一分支在 32 B 行内的半字偏移 → 推出取指块长 |
| `[67]` / `[71:68]` | `b2_valid` / `b2_off[4:1]` | 1 / 4 | 块内第二个分支的存在与半字偏移 |
| `[73:72]` | `lru` | 2 | 每路 LRU 位（组内另配 3 bit 树形状态） |

> 宽度与 `../02-branch-predictor.md` §2 的"tag22+target30+类型2+置信2=56"不同：为支持 RVC 半字对齐目标与"块内第二个分支"扩到 74 bit。总量 512×4×74 ≈ 148 Kbit ≈ 1~2 个 BRAM。
> `b1/b2` 元数据在 BTB 分配时用提交分支的 `pc[4:1]` 生成：行内已有表项且 `b1_off <` 本偏移 → 写 `b2_off`/`b2_valid=1`；否则旧 `b1_off` 下移为 `b2_off`，本分支写 `b1_off`。

### 3.2 索引与哈希的精确表达式

```verilog
wire [11:0] g_idx    = pc_if0[11:0] ^ ghr_spec[11:0];                          // GPHT
wire [9:0]  l_idx    = pc_if0[9:0];                                            // LHT
wire [3:0]  pc_fold4 = pc_if0[11:8] ^ pc_if0[7:4] ^ pc_if0[3:0] ^ {2'b0,pc_if0[9:8]};
wire [11:0] lp_idx   = {lht_rdata[7:0], pc_fold4};                             // LPHT
wire [5:0]  fold6    = ghr_spec[11:6] ^ ghr_spec[5:0];
wire [11:0] cp_idx   = pc_if0[11:0] ^ {6'b0, fold6};                           // CPHT
wire [6:0]  btb_set  = pc_if0[10:2];  wire [21:0] btb_tag = {pc_if0[31:11], pc_if0[1]};
wire g_pred = gpht_rdata[1], l_pred = lpht_rdata[1], sel = cpht_rdata[1];      // sel=1 用全局
assign pred_valid  = (btb_hit_way != 2'd3);
assign pred_taken  = pred_valid && (sel ? g_pred : l_pred) && (btypes[btb_hit_way] != `BT_NONE);
assign pred_target = (btypes[btb_hit_way] == `BT_RET) ? ras_top : btb_target[btb_hit_way];
```

> **BTB 未命中 → 预测不跳转**（顺序取指）；该分支首次执行必然误预测一次，提交后才分配表项（`../02-branch-predictor.md` §3.3）。

### 3.3 每取指块预测 1 个分支

| 情况 | 处理 | 影响 |
|---|---|---|
| 块内 0 分支 | 全 16 B 入队 | 无 |
| 块内 1 分支，BTB 命中 | `blk_len` 给块长，块在分支后截断；下拍取 `pred_target`（taken）或 `PC+16`（untaken） | 无气泡 |
| 块内 2 分支且 `b2_valid=1` | 第一分支按预测走；第二分支被预测 taken 时块**强制在第二分支处截断**（IF2 用 `b2_off` 生成 `fill_valid_hw`），下拍重新查询 | 每 2 分支多 0~1 拍 |
| 块内 ≥3 分支（RVC 最多 8 条 16 bit） | 只记前 2 个，其余按顺序取指穿越，命中时靠误预测恢复 | 实测 <0.5% 的块 |

> 为控面积只做**单查询口**（`bpu_top` 预留 `query2_*` 端口位，不连接）。BRAM 双口可低成本扩为双查询，按 `../02-branch-predictor.md` §3.2"实测 IPC 明显受限时再扩展"。

### 3.4 更新规则伪代码

```verilog
// ---------- EX 解析（BRU）：推测更新，唯一改 GHR/RAS 的地方 ----------
// 输入 resolve_valid/resolve_rob_idx[6:0]/actual_taken/actual_target[31:0]/
//      is_call/is_ret/ckpt_idx[1:0]/mispredict
if (resolve_valid) begin
    ghr_spec <= {ghr_spec[10:0], actual_taken};         // 立即移位，供后续预测使用
    if      (is_ret)  ras_pop();                        // 出栈；下拍栈顶为新目标
    else if (is_call) ras_push(pc + pc_inc);            // 压入返回地址
    if (mispredict) begin
        redirect_valid <= 1'b1; redirect_pc <= actual_target; redirect_rob_idx <= resolve_rob_idx;
        restore_spec_state(ckpt_idx);                   // GHR/RAS 回滚（§3.5）
    end
end

// ---------- RT 提交：架构更新，唯一写 PHT/LHT/BTB 的地方 ----------
if (commit_is_branch) begin
    ghr_arch <= {ghr_arch[10:0], commit_taken};         // 架构 GHR 由提交序列重建
    if (ghr_spec != {ghr_arch[10:0], commit_taken})     // 自检；SIM_ASSERT 下报错
        ghr_spec <= {ghr_arch[10:0], commit_taken};
    gpht[commit_pc[11:0] ^ ghr_snapshot] <= updown2(..., commit_taken);
    lht [commit_pc[9:0]] <= {lht[commit_pc[9:0]][6:0], commit_taken};
    lpht[lp_idx_of(commit_pc, lht[commit_pc[9:0]])] <= updown2(..., commit_taken);
    cpht[cp_idx_of(commit_pc, ghr_snapshot)] <= (g_ok && !l_ok) ? sat_inc(cpht[...]) :
                                                (!g_ok &&  l_ok) ? sat_dec(cpht[...]) : cpht[...];
    btb_update(commit_pc, commit_target, commit_brtype, commit_taken);   // ↓ 见下
    // RAS 在提交级只确认，不改栈（推测 push/pop 已在预测时完成）
end

// ---------- BTB 分配 / 替换（btb_update 内部）----------
set = bpc[10:2]; tag = {bpc[31:11], bpc[1]};
if (way[i] 匹配 tag && valid) begin              // 命中：更新 target/类型/置信度
    way[i].target <= btgt; way[i].br_type <= btype;
    way[i].ctr <= taken ? sat_inc(way[i].ctr) : sat_dec(way[i].ctr);
    lru_update(set, i);
end else begin                                   // 未命中：分配
    j = 存在 !valid way ? 第一个无效 way
                        : 置信度最低且 b2_valid==0 的 way（同分用伪 LRU 决定）;
    way[j] <= BTB_ENTRY_INIT(tag, btgt, btype);
    upd_b1b2_meta(set, bpc[4:1]);                // b1_off/b2_off/b2_valid/blk_len
end
```

> BTB 表项是**纯预测状态**，被替换只可能多一次误预测，不影响正确性 → **无写回、无 victim buffer**。

**RAS push/pop 与溢出/下溢保护**

| 事件 | 条件 | 动作与保护 |
|---|---|---|
| push | `is_call && !is_ret` | `ras[sp] <= pc+pc_inc; sp <= sp+1`；`sp==5'd31` 时**不回绕**，饱和并置 `ras_overflow`（丢弃最老返回地址） |
| pop | `is_ret` | `sp <= sp-1`，目标 = `ras[sp-1]`；`sp==0` 时**不下溢**，置 `ras_underflow`，目标退化为 `PC+16` |
| 恢复 | 重定向且 checkpoint 有效 | `sp <= ckpt.ras_sp`，RAS 内容由 32×30 bit 快照恢复（分配 checkpoint 时快照） |
| 恢复 | 重定向且无 checkpoint | ROB 反走重建（§3.5 优先级 2） |

> RAS 是提示性结构，溢出/下溢**不产生异常**，只置状态位供 `perf_ras_*` 统计。

### 3.5 误预测恢复（checkpoint + ROB 反走兜底）

| 优先级 | 条件 | 动作 | 代价 |
|---|---|---|---|
| 1 | `ckpt_idx` 对应 checkpoint 有效 | `ghr_spec <= ckpt.ghr`；`ras_sp <= ckpt.ras_sp` + 快照恢复；释放该及其后所有 checkpoint | 同拍完成，0 额外代价 |
| 2 | checkpoint 已被更老分支释放/覆盖 | **ROB 反走**：从 ROB 头向 `resolve_rob_idx` 反向扫描，按 `is_branch` 表项的 `actual_taken` 重建 GHR，同时按 call/ret 逆序修正 `ras_sp` | ≤128 拍（ROB 深度），期间 `if_freeze=1` |
| 3 | checkpoint 耗尽（4 个在用） | RN 把该分支标 `ckpt_hint=2'b11`；前端对未被 checkpoint 覆盖的区段进入**保守模式**：GHR 冻结、RAS 不 push/pop，直到 checkpoint 释放 | 准确率下降，正确性不变 |

```verilog
task restore_spec_state(input [1:0] ci);   // 优先级 1 与 2 的分派
  if (ckpt_valid[ci]) begin ghr_spec <= ckpt[ci].ghr; ras_sp <= ckpt[ci].ras_sp;
                            ckpt_valid[ci] <= 1'b0; end   // 更年轻的 checkpoint 一并作废
  else                    rob_rewalk_start <= 1'b1;       // 兜底；if_freeze 保持到 rob_rewalk_done
endtask
```

> 反走期间 `pc_gen` 停在 `redirect_pc`；该路径只在 checkpoint 被更老分支提前回收时触发，`../02-branch-predictor.md` §4 已定义为"保证正确性"的兜底。

---

## 4. I-Cache `icache`

### 4.1 组织与 VIPT 别名安全性证明

| 参数 | 取值 | 推导 |
|---|---|---|
| 容量 / 相联度 / 行大小 | 16 KB / 4 路 / 32 B | `../03-cache.md` §2 |
| 组数 | 128 | 16 KB ÷ (4 × 32 B) |
| 虚拟索引（组号） | `va[11:5]`，7 bit | — |
| 行内偏移 / 物理标记 | `va[4:0]` 5 bit / `pa[31:12]` 20 bit | `` `PADDR_W `` = 32 |

**别名安全性证明**：别名产生的条件是"组数 × 行大小 > 页大小"。本设计 `128 组 × 32 B = 4 KB = 页大小（Sv32 最小页）`。索引位 `va[11:5]` 完全落在**页内偏移** `va[11:0]` 内，不含任何被翻译的位；由于 `pa[11:5] == va[11:5]`，同一物理行在任何 VA 映射下组号必然相同 → **同一物理行只能映射到一个组 → 无别名**。

**实现含义**：L1I 可"VA 低位直接索引 + PA 全地址比较标记"，取指**无需等 ITLB**：ITLB 与 Tag/Data 阵列同拍并行启动，命中判定（Tag 比较 ∧ TLB 权限检查）在 IF2 合并完成 —— 这是取指 2 周期延迟的基础。

### 4.2 表项位域

| 阵列 | 位域（宽） | 说明 |
|---|---|---|
| Tag（每路） | `valid`(1) `tag[19:0]`=`pa[31:12]`(20) `pmp_ok`(1) `poison`(1) `plru[2:0]`(3) `prefetch_pending`(1) | `fence.i`/`cbo.inval` 清 `valid`；PMP 通过标记（PMP 写时全清）；总线错误行（命中即报访问错误）；伪 LRU 树形状态（组内共享）；有未完成 next-line 预取 |
| Data（每路） | `data[255:0]`(256) `be[7:0]`(8) | 32 B；`be` 为每 4 B 的有效掩码（关键字优先填充期间部分有效） |
| MSHR（2 项） | `valid`(1) `pa[31:5]`(27) `set[6:0]`(7) `way[1:0]`(2) `cw_first`(1) `half_valid[1:0]`(2) `req_pc[31:0]`(32) `excp[3:0]`(4) `is_prefetch`(1) `age[1:0]`(2) | 占用中；缺失物理地址（行对齐）；目标位置；关键 half 选择（=`pa[4]`）；两个 16 B half 到达情况；触发缺失的取指 PC（解冻后重建取指点）；缺失期间异常（1=访问错误）；预取占用（不阻塞取指、可被真实缺失抢占）；分配顺序 |

### 4.3 端口清单与读写端口

```verilog
module icache (
  input  wire        clk, rst_n,
  // —— 取指请求（IF0→IF1）——
  input  wire        req_valid,                 // = pc_if0_valid
  input  wire [31:0] req_va,                    // = pc_if0
  output wire        req_ready,                 // miss 时为 0
  // —— TLB（与 Tag 并行；bundle 见 03-pipeline-regs §2.6）——
  output wire        mmu_req_valid,             // = req_valid && !if_freeze
  output wire [31:0] mmu_req_va,
  output wire [8:0]  mmu_req_asid,              // satp.ASID
  output wire [1:0]  mmu_req_priv,              // priv_mode，**不含 MPRV**
  output wire [1:0]  mmu_req_type,              // 恒 2'b00 取指
  output wire        mmu_req_is_fp,             // 恒 0
  input  wire        mmu_resp_valid, mmu_resp_fault, mmu_busy,
  input  wire [31:0] mmu_resp_pa, mmu_resp_tval,
  input  wire [3:0]  mmu_resp_cause,            // 12=页错误 1=访问错误
  // —— 取指块输出（IF2→fetch_queue，逐字段对应 fq_wdata_t）——
  output wire        fill_valid,
  output wire [127:0]fill_data,                 // 相对 fill_va 的 16 B 窗口
  output wire [31:0] fill_va,                   // = if2_pc_q
  output wire [7:0]  fill_valid_hw,             // 半字有效掩码
  output wire [3:0]  fill_excp,                 // 块异常码（0/1/12）
  output wire [7:0]  fill_excp_hw,              // 异常半字掩码
  output wire [31:0] fill_excp_tval,
  output wire [1:0]  fill_pred, fill_ckpt_hint, // {pred_taken,btb_hit} / checkpoint 提示
  output wire [11:0] fill_ghr,
  input  wire        fill_ready,                // = fetch_queue 可写
  // —— L2（refill + next-line 预取）——
  output wire        l2_req_valid, l2_req_prefetch,
  output wire [31:0] l2_req_addr,
  input  wire        l2_resp_valid,
  input  wire [255:0]l2_resp_rdata,             // 整行 32 B
  input  wire [7:0]  l2_resp_be,
  input  wire [3:0]  l2_resp_id,                // 匹配 MSHR，可乱序返回
  // —— CSR / 控制与性能 ——
  input  wire        fencei_valid, cbo_inval_valid, flush_all,
  input  wire [31:0] cbo_addr,
  output wire        fencei_done, if_freeze,
  output wire [31:0] perf_icache_miss, perf_icache_access,
  output wire [3:0]  dbg_ic_state
);
```

**读/写端口时序**：① 读端口（Tag×4 + Data×4）同步读 1 周期——IF0 送 `va[11:5]`，IF1 末 `tag_ways`/`data_ways` 有效，IF2 比较；② 写端口（Tag + Data）同步写 1 周期，`REFILL` 态用 `be` 掩码写；③ 无效化端口单周期，`fencei_valid` 一拍清全部 128 组 × 4 路 `valid`（**非** 512 拍扫描）；④ 预取复用 L2 端口（`l2_req_prefetch=1`），仅 1 个未完成预取（`../03-cache.md` §2）。

### 4.4 状态机

| 状态 | 编码 | 行为 | 转移 |
|---|---|---|---|
| `IDLE` | 4'd0 | 无请求 | `req_valid` → `LOOKUP` |
| `LOOKUP` | 4'd1 | IF1 读阵列；IF2 Tag 比较 + TLB 权限合并 | 命中 → `IDLE`+写队列；TLB fault → `IDLE`+带异常写队列；miss → `MISS` |
| `MISS` | 4'd2 | 分配 MSHR（优先空闲，其次 `is_prefetch` 项）；向 L2 发 `pa[31:5]`；`if_freeze=1` | 成功 → `MSHR_WAIT`；两项均被真实缺失占用 → 留在 `MISS`（计 `perf_icache_mshr_stall`） |
| `MSHR_WAIT` | 4'd3 | 等 L2 并按 `l2_resp_id` 匹配；关键 half 到达置 `half_valid[cw_first]` | 关键 half 到达 → `REFILL` |
| `REFILL` | 4'd4 | 写 Data（带 `be`）与 Tag `valid=1`；关键 half 写完后**立即释放 `if_freeze`** | 另一 half 到达 → `IDLE`；否则保持 |
| `ERROR` | 4'd5 | 总线/访问错误：Tag `valid=1` + `poison=1` 不写数据；命中该行按 `excp=1` 上报 | `fence.i`/`cbo.inval` → `IDLE` |

**并发规则**：① TLB fault 优先于 Tag 命中（权限更严）；② 预取缺失不置 `if_freeze`，可被真实缺失丢弃；③ 同一行的第二个缺失**命中已有 MSHR**，不重复发 L2 请求。

### 4.5 关键字优先（critical-word-first）填充

行 32 B 分两个 16 B half：`half0 = data[127:0]`（行偏移 0–15）、`half1 = data[255:128]`；关键 half = `pa[4]`。L2 返回整行 `l2_resp_rdata[255:0]` + `l2_resp_be[7:0]`（每 4 B 一个字节使能），按 `l2_resp_id` 匹配，**到达顺序可乱序**（`../03-cache.md` §4）。关键 half 到达 → `REFILL` 写 Data → **立即释放 `if_freeze`**，IF0 用 MSHR 的 `req_pc` 重取；另一 half 后台写入，期间 `be` 不完整，若取指落在未到达 half 则再次进 `MISS`（命中同一 MSHR）。收益：缺失延迟从"整行 8 beat"降到"关键 half 4 beat"，AXI 32 bit（4 B/beat）下约省 4 个 AXI 周期。

### 4.6 `fence.i` 与 `cbo` 处理

| 事件 | 触发 | 前端动作 |
|---|---|---|
| `fence.i` 提交 | RT（`is_fencei`） | ① `flush_all` 清 IF0~ID 与 `fetch_queue`；② `fencei_valid` 高 1 拍，L1I 全部 128 组×4 路 `valid` 单周期清零；③ 丢弃全部 MSHR/预取；④ `fencei_done` 回 CSR，释放 `fencei_hold`；⑤ 从 `PC+4` 重取，首访必然 miss |
| `sfence.vma` 提交 / `satp` 写 / ASID 切换 / 特权级变化 | RT 或 CSR | 只需清 ITLB（`../04-csr-mmu.md` §4.4）并 `flush_all` 清在飞取指；L1I 为物理标记**无需失效**（§4.1 索引位不参与翻译） |
| `cbo.inval` / `cbo.flush` | RT | 按 `cbo_addr` 定位行，`pa` 匹配则清 `valid`；**`CBO.INVAL` 在 `menvcfg.CBIE=01/11` 时按 flush 语义执行**（`riscv-isa-manual/src/unpriv/cmo.adoc`）；同时 `flush_all` 丢弃已入队的旧指令。不做 D-Cache snoop：单核无一致性信号，软件须先 `cbo.clean/flush` 数据侧 |
| `cbo.clean` | RT | L1I 只读、无脏行，无动作 |

> **正确性论证**：`fence.i` 保证"其前的显式访存先于其后的取指"（`riscv-isa-manual/src/unpriv/zifencei.adoc`）。本设计在 RT 提交 `fence.i` 时更老的 store 均已提交落盘（`../01-pipeline.md` §4）；随后单周期全清 L1I 并清空取指队列，任何早于 `fence.i` 取入的指令都无法到达 ID，后续取指必然从 L2/主存读到新指令。

### 4.7 缺失时的取指反压

| 信号 | 语义 |
|---|---|
| `if_freeze` | 真实缺失（非预取）未完成时拉高；`pc_gen` 保持 `pc_q`，IF1/IF2 冻结；`fetch_queue` 继续排空供 ID 消费 |
| `req_ready` | `!if_freeze && fill_ready`；`valid`/`ready` 同拍传输，无 skid 歧义 |
| 两级叠加 | `fq_full → fill_ready=0 → if_freeze=1 → pc_gen` 停；全通路无"取指丢弃" |

---

## 5. 取指队列 `fetch_queue`

### 5.1 结构与深度

**深度 16 项**，每项一个 16 B 取指块（≈64 B ≈ 16 条 32 bit 指令），覆盖 L2 命中延迟 12~16 周期。**动态阈值**：4 个 checkpoint 全占用且 ROB 已满 48 项时 `fq_throttle=1`，有效阈值降到 8 项，避免前端比重命名超前过多而放大误预测恢复代价（与 `../05-ooo.md` 的 checkpoint 反压约定一致）。

### 5.2 表项位域（`fq_entry_t`）

存储按 `03-pipeline-regs.md` §1 的 `fq_wdata_t` **逐半字**组织（`INSTR16_W` 位），一个 16 B 取指块 = 8 个半字项；元数据随半字一起流动，ID 侧的 2:1 指令拼接自动带走对应半字的元数据。

| 组 | 位段 | 字段 | 宽 | 说明 |
|---|---|---|---|---|
| 块头 | `[0]` | `blk_valid` | 1 | 块有效 |
| | `[31:1]` | `blk_pc[31:1]` | 31 | 块首半字 PC（bit0=0）= `fill_va` |
| | `[39:32]` | `blk_valid_hw[7:0]` | 8 | 半字有效掩码（重定向落点使块不满时置 0） |
| | `[43:40]` | `blk_b2_off[4:1]` | 4 | 块内第二个分支的半字偏移（0=无），用于 IF2 截断 |
| 半字组 | `[59:44]` | `instr16[15:0]` | 16 | **指令半字本身**（小端序，`hw[0]` 为最低半字） |
| ×8，每项 | `[67:60]` | `excp_hw[7:0]` | 8 | 异常半字掩码：`excp_hw[i]=1` → 下标 i 的半字是异常发生处 |
| 32 bit | `[75:68]` | `hw_off[7:0]` | 8 | 该半字在块内的下标（= 位段序号，等价 `blk_pc[3:1] + i`） |
| | `[77:76]` | `pred[1:0]` | 2 | `{pred_taken, btb_hit}`（该半字所属块的预测） |
| | `[89:78]` | `ghr[11:0]` | 12 | 预测时 GHR（供 RT 更新预测器，`02-uop-and-decode.md` §3） |
| | `[91:90]` | `ckpt_hint[1:0]` | 2 | 预测时可见的 checkpoint 索引 |
| | `[94:92]` | `fq_flags[2:0]` | 3 | `{is_pred_br, is_blk_tail, has_second_br}`（统计/训练对齐用） |
| | `[98:95]` | `excp[3:0]` | 4 | 异常码：0 无 / 1 访问错误 / 12 页错误（§5.4） |
| | `[129:99]` | `excp_tval[30:0]` | 31 | 出错虚拟地址 `PC[31:1]`（复原：`{excp_tval, 1'b0}`） |

每半字项 86 bit，`hw[0]` 排在最低位段。整块 `fq_entry_t` = 44（块头）+ 8×86 = **732 bit**；16 项 ≈ 11.4 Kbit，用分布式 RAM/FF 实现。

> **与 `03-pipeline-regs.md` §1 的关系**：字段名与语义**完全沿用**该文件的 `fq_wdata_t`（`pc`/`instr16`/`pred`/`ghr`/`excp`/`excp_tval`）。本设计只做两点工程化展开：① `instr16` 按半字逐项存储，使 RVC 拼接与元数据搬运共用同一 MUX；② `excp_tval` 只在实际出错的那半字上非零（由块头 `excp_hw` 掩码指示），避免 8 份冗余。`valid`/`ready` 握手语义不变。

### 5.3 RVC 半字拼接规则（跨块 / 跨 Cache 行）

RISC-V 指令是**半字序列**：32 bit 指令 = 相邻两半字 `{hi, lo}`（小端），与自然对齐无关，因此只有一条规则：

```verilog
// ID 级取指对齐：每周期最多产出 4 条 32 bit 指令
// staging[7:0]：队头 1~2 个块的半字；off：当前指令起始半字下标
// carry_valid/carry_hw：暂存"低半在上一块、高半未到"的半字
for (slot = 0; slot < 4; slot = slot + 1) begin
    hw_lo = (off < 8) ? staging[off] : carry_hw;
    if (hw_lo[1:0] != 2'b11) begin                        // 16 bit 指令（含 RVC）
        instr[slot] = {16'b0, hw_lo}; len[slot] = 2; off = off + 1;
    end else if (off + 1 < 8 || next_blk_available) begin  // 32 bit：两半都齐
        hw_hi = (off + 1 < 8) ? staging[off+1] : next_blk.hw[0];
        instr[slot] = {hw_hi, hw_lo}; len[slot] = 4; off = off + 2;
    end else begin                                        // 高半未到：暂存并停止
        carry_valid = 1; carry_hw = hw_lo; break;
    end
end
```

| 场景 | 处理 | 代价 |
|---|---|---|
| 32 bit 完全落在块内 | 直接拼接 | 0 |
| 低半是块内最后一个半字，高半在**下一取指块**（含**跨 Cache 行**：32 B 行按 16 B 对齐切块，16 B 块绝不跨行，跨行必先跨块） | 低半存入 `carry_hw`，下拍取新块 `hw[0]` 作高半 | ID 停 1 拍；下一块 L1I 缺失则延长为缺失延迟 |
| 重定向落点使首块不满 / `carry` 悬空时收到 `flush` | `valid_hw` 之后的半字不参与拼接（按掩码清零）；`carry_valid<=0`、`off<=0` | 0 |

> 拼接只需 **2:1 MUX + 1 个 16 bit 暂存寄存器**，不需要跨块重复取指。跨块最多 1 拍，RVC 下 32 bit 指令跨 16 B 边界的概率 <0.3%。

### 5.4 与 ID 的握手、异常标记与反压

```verilog
module fetch_queue (
  input  wire                   clk, rst_n, flush_all,
  input  wire                   push_valid,                  // IF2 写入
  input  wire [`FQ_ENTRY_W-1:0] push_data,
  output wire                   push_ready,                  // = !full
  input  wire                   pop_valid,                   // ID 消费请求
  input  wire [2:0]             pop_num,                     // 本拍消费的半字数 0~8
  output wire [`FQ_ENTRY_W-1:0] pop_data,
  output wire                   pop_ready,                   // = !empty
  output wire                   empty, full, almost_full,
  output wire [4:0]             fq_count, fq_max_occupancy
);
```

| 握手 | 语义 |
|---|---|
| 入队 | `push_valid && push_ready` **同拍**写入（`00-conventions.md` §3）；`push_ready = !full`；满则 `icache.if_freeze=1`，IF0/IF1 停 |
| 出队 | `pop_ready = !empty`；空时 ID 侧插气泡（`id_valid=0`），**不产生假指令** |
| 半消费 | ID 若只消费前 k 个半字（槽位用尽或 `carry` 悬空），把该块写回队头并把 `valid_hw` 右移 k 位，不占额外表项 |
| 清空 | `flush_all` 一拍清空 16 项并复位 `carry`/`off`；队列内无 `rob_idx`，故一律整清（深度 16 ≪ ROB 128，代价可忽略）；带 `flush_rob_idx` 的**定向**作废由后端按年龄语义完成（`00-conventions.md` §3） |

**异常标记随指令流动**：IF2 把 `fill_excp`/`fill_excp_hw`/`fill_excp_tval` 写入块表项；ID 出队后按异常半字掩码判断该异常是否落在**本条指令的起始半字**上，若是则写 `uop_id_t.ctrl[63]=excp_valid`、`ctrl[67:64]=excp_cause`（`02-uop-and-decode.md` §2），tval 取该指令 PC。异常**不阻塞** uop 流动（`02-uop-and-decode.md` §6），在 RT 级（ROB 头）精确触发。

| 取指侧异常码 | 含义 | 来源 |
|---|---|---|
| 0 / 1 | 无异常 / 指令访问错误 | PMP 拒绝、总线 error（`mmu_resp_cause=1`）或 `poison` 行 |
| 12 | 指令页错误 | `mmu_resp_fault=1` |
| 3 | 断点 | EBREAK 译码产生（非前端） |

> **半字归属规则**：异常只挂在**指令起始**半字上。故障地址若落在奇半字（`pc[1]=1`），说明它是某条 32 bit 指令的高半，此时把 `fill_excp_hw` 右移一位（归属到偶半字），保证异常指令的 `pc` 是偶地址，且 ID 只需一条判定：`fill_excp_hw[off]` → 给当前指令置 `excp_valid/excp_cause`。

---

## 6. 与 MMU / CSR 的接口

### 6.1 取指侧 TLB 请求（复用 `03-pipeline-regs.md` §2.6 bundle）

| 信号 | 前端取值 | 说明 |
|---|---|---|
| `mmu_req_valid` | `req_valid && !if_freeze` | IF0 发出，与 Tag 阵列读**同拍** |
| `mmu_req_va` | `req_va[31:0]` | 当前取指 PC |
| `mmu_req_asid` | `satp.ASID[8:0]` | 9 bit |
| `mmu_req_priv` | `priv_mode[1:0]` | **不含 MPRV 修正**（§6.3） |
| `mmu_req_type` / `mmu_req_is_fp` | `2'b00` / `1'b0` | 取指；不适用 |
| `mmu_resp_*` | IF1 末有效 | `mmu_resp_pa` 供 IF2 比较；`fault/cause/tval` 转 `fill_excp` |

**合并规则**：`hit = tag_match && !mmu_resp_fault`。ITLB 全相联 32 项（`../04-csr-mmu.md` §5.2）与 Tag/Data 并行查询，故 ITLB 命中不额外增加取指延迟。

### 6.2 `satp` / `ASID` / 特权级变化的失效

| 事件 | 失效范围 | 前端动作 |
|---|---|---|
| `satp` 写（MODE/PPN 变化） | ITLB 全部 + L2TLB 全部 | 发 `sfence_all` + `flush_all`；L1I **不失效** |
| `satp.ASID` 变化 | 仅该 ASID 的 ITLB 表项 | 由 TLB 按 ASID 匹配处理；CSR 决定是否 `flush_all` |
| 特权级变化（trap/xret） | ITLB 权限重检 | `flush_all`；表项自带权限位，无需失效 |
| `sfence.vma` 提交 | 按 `rs1`/`rs2` 匹配失效 | 转发 `sfence_valid/va/asid` 到 ITLB + `flush_all` |
| PMP 配置写 | 全部 TLB 的 PMP 标记 + L1I 的 `pmp_ok` | 清全部 TLB 与 `pmp_ok`；`flush_all` |

> L1I 不因地址空间切换失效：它用物理标记（§4.1），ASID/VA 不参与标记比较 —— 这也是 VIPT 的收益之一。

### 6.3 `mstatus.MPRV` 对取指不生效

`mstatus.MPRV` 只让 M 模式的 **load/store** 使用 `MPP` 的特权级与 `satp` 做转换（`riscv-isa-manual` `priv/machine.adoc`，Memory Privilege in mstatus Register）。**取指特权级恒为当前 `priv_mode`**：`取指有效特权级 = priv_mode[1:0]`（永不取 MPP），而 `load/store 有效特权级 = MPRV ? mstatus.MPP : priv_mode`。因此 `icache.mmu_req_priv` 直接接 `priv_mode[1:0]`，与 LSU 的 `mmu_req_priv` **不同源**；`rv32gc_core.v` 中两份逻辑必须分开生成，禁止共用同一 `eff_priv` 信号。

### 6.4 CSR 接口汇总

| CSR 信号 | 方向 | 前端使用 |
|---|---|---|
| `priv_mode[1:0]` / `satp.ASID[8:0]` | CSR→前端 | `mmu_req_priv` / `mmu_req_asid` |
| `is_fencei` / `is_sfence` | RT 提交→前端 | `fencei_valid` / `flush_all` |
| `cbo_op[1:0]` + rs1 值 | RT 提交→前端 | `cbo.inval/flush` 清 L1I 行 |
| `menvcfg.CBIE` | CSR→前端 | `cbo.inval` 是否按 flush 语义 |
| `trap_valid`/`trap_pc`、`xret_valid`/`xret_pc` | RT→`pc_gen` | §2.2 优先级 1/2 |

---

## 7. 性能计数器与调试信号

全部 32 bit、同步清零、映射到 `mhpmcounter3..12`（`../04-csr-mmu.md` §2.1：未实现项读 0 合法）。`flush` 拍不计数，避免统计推测路径。

| 信号 | 宽 | 定义 |
|---|---|---|
| `perf_branch_retired` / `perf_branch_mispred` | 32×2 | RT 提交的分支总数 / EX 解析判定误预测次数（准确率目标 ≥93% CoreMark、≥96% Dhrystone） |
| `perf_btb_miss` | 32 | `pred_valid=0` 的取指块数 |
| `perf_btb_hit_type[3:0]` | 4×32 | 按 `br_type` 分类命中：`[0]`cond `[1]`jal `[2]`jalr `[3]`ret（`[3]` 即 RAS 命中率） |
| `perf_bpu_alloc` / `perf_bpu_evict` | 32×2 | BTB 新分配次数 / 因满或低置信度被替换次数 |
| `perf_chooser_global` | 32 | `cpht_rdata[1]==1` 的预测次数（选择器收敛性） |
| `perf_ras_overflow` / `perf_ras_underflow` | 32×2 | §3.4 饱和计数 |
| `perf_if_freeze_cycles` / `perf_fq_full_cycles` | 32×2 | `if_freeze` 高周期数 / 队列满周期数 |
| `perf_fq_max_occupancy` | 5 | 队列占用高水位（调深度用） |
| `perf_icache_access` / `perf_icache_miss` | 32×2 | L1I 访问次数 / 缺失次数（不含预取） |
| `perf_icache_mshr_stall` | 32 | 两个 MSHR 全满导致的停顿周期（>5% → 考虑加 MSHR） |
| `perf_icache_prefetch[1:0]` | 32×2 | next-line 预取发起次数 / 其命中次数 |
| `dbg_fetch_pc` / `dbg_fetch_valid` | 32 / 1 | IF0 的 `pc_if0` 与有效 |
| `dbg_bpu_pred[2:0]` | 3 | `{pred_taken, btb_hit, sel}` |
| `dbg_if_state[3:0]` / `dbg_fq_head_pc` | 4 / 32 | icache 状态机编码（§4.4）/ 队列头 `blk_pc`（定位前端卡死） |

---

## 8. 验证要点（含波形级判据）

| # | 测试 | 期望波形级判据 |
|---|---|---|
| 1 | **局部可预测**：内层 `for(i=0;i<8;i++)` 固定计数循环 | 预热后每个内层循环**恰好 1 次**误预测；`cpht` 高位收敛为 0（选局部）；`lht[PC[9:0]]` 三次迭代内稳定在 `8'h01` |
| 2 | **全局可预测**：`if(a<0)b=-1; if(b<0)...` 相关分支对（同向） | `perf_chooser_global` 对该 PC 占比 >90%；稳态 `perf_branch_mispred` 增量为 0；`gpht[PC[11:0]^GHR]` 高位 = 1 |
| 3 | **相关分支**：`d=a-b; if(d==0)...; if(a==b)...` | 第二个分支稳态零误预测；第一分支解析后 1 拍 `ghr_spec[0] == actual_taken`（第 1~3 项用 `bpu_dbg_*` 后门读表项验证） |
| 4 | **递归（RAS 正常路径）**：深度 20 | `perf_ras_overflow==0`、`perf_ras_underflow==0`；`ras_sp` 进入最深处 = 20、返回后 = 0；返回地址零误预测 |
| 5 | **RAS 平衡**：深度 40 递归 + 手工 `jalr` 制造下溢 | `perf_ras_overflow>0`、`perf_ras_underflow>0`，但 `dbg_commit_pc` 序列与参考模型**完全一致**；`ras_sp` 在 `5'd31` 饱和、在 `5'd0` 不再递减 |
| 6 | **推测污染：PHT/BTB 不被错误路径更新** | 构造"预测 taken、实际 untaken"的块，错误路径放强 taken 分支序列；`flush` 后经 `bpu_dbg_*` 后门读 `gpht/lpht/cpht/lht/btb` 与 flush 前**逐位相同**（这些结构只在提交时写） |
| 7 | **推测污染：GHR/RAS 回滚** | `redirect_valid` 后 1 拍 `ghr_spec == ckpt[ckpt_idx].ghr` 且 `ras_sp == ckpt.ras_sp`；重放预测与"从未执行错误路径"的参考一致 |
| 8 | **checkpoint 耗尽 → ROB 反走**：连续 5 个分支不提交 | `rob_rewalk_start` 拉高、`if_freeze=1`、反走 ≤128 拍；反走后 `ghr_spec == ghr_arch`，提交 PC 流与参考一致 |
| 9 | **I-Cache 一致性**：改指令 → `fence.i` → 执行该地址 | `fence.i` 提交拍 `fencei_valid` 高 1 拍、4 路 `valid` 同拍全清、`fetch_queue` 空；下一拍取指必 miss（`perf_icache_miss` +1）；`dbg_commit_*` 轨迹反映**新指令** |
| 10 | **`fence.i` 反例**：同序列省略 `fence.i` | 允许执行旧指令，但**不得死锁**：`if_freeze` 不得长期为高、`dbg_fetch_pc` 必须继续推进 |
| 11 | **`cbo.inval`/`cbo.flush` 清 L1I**：改指令 → `cbo.flush`(D) → `cbo.inval`(I) → 执行 | `cbo_inval` 提交后目标行 `valid=0`；后续取指 miss 并读到新指令 |
| 12 | **RVC 跨 16 B 块**：`PC[3:0]==4'hE` 放 32 bit 指令，前后 `c.nop` | ID 输出 `instr[31:0]` 在 1 拍停顿后完整，`carry_valid` 高 1 拍；该 uop 的 `pc` = 边界地址，且与 32 bit 版本译码结果**逐位相同**（`02-uop-and-decode.md` §7.2） |
| 13 | **RVC 跨 Cache 行 + 跨行掩码**：指令起始在行内 `offset=30`（`PC[4]=1`）；另测重定向到 `offset=24` | 前者 `dbg_if_state` 出现两次 `LOOKUP`，下一行 miss 时 ID 停顿 = 缺失延迟；后者首块 `fill_valid_hw` 只有高 4 个半字有效，ID 不为低 4 个半字产出 uop |
| 15 | **缺失反压 + 关键字优先**：冷启动，L2 先返回 `pa[4]` 对应 half | `if_freeze` 在关键 half 到达后当拍/次拍释放（不等整行 8 beat）；两 half 拼接后与内存逐字节相同 |
| 16 | **MSHR 双缺失与乱序返回**：两个不同组交替缺失 | 2 个 MSHR 同时 `valid`；第三个缺失时 `perf_icache_mshr_stall` 递增且不丢请求；`l2_resp_id` 反序返回时各自匹配正确 |
| 17 | **fq 满/空气泡**：`rob_full` 长时间拉高 | `fq_full` 拉高后 `pc_if0` 冻结不变；撤销后从上次 PC 继续（不跳变、不重复提交）；队列空时 ID 收气泡 `id_valid=0` |
| 18 | **32 B 行双块**：顺序取指 1 KB | 每 2 拍产生 1 个 16 B 块，`perf_icache_access` 每 2 拍 +1 |
| 19 | **flush 清 carry**：RVC 跨块拼接当拍注入 `flush_all` | 下拍 `carry_valid==0`、`off==0`；不产出由旧半字拼成的假指令 |
| 20 | **`misa.C=0`** | 清 C 位后 BPU 的 `PC[1]` 恒 0；取到奇半字上的 32 bit 指令报 `excp_cause=2`（非法指令），**不报**取指地址非对齐 |

> 测试平台用 `../08-verification.md` 的 testbench 框架；`bpu_dbg_*` 后门读接口仅在 `` `ifdef SIM_ASSERT `` 下综合，不进 FPGA 实现。
