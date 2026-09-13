# SPEC-05 乱序后端微架构规格书（RN / ROB / IQ / PRF / 精确恢复）

> 上游：`00-conventions.md`（全局约定、清空协议、写回口分配）、`02-uop-and-decode.md`（`uop_ctrl_t` 72 bit）、`03-pipeline-regs.md`（**所有 bundle 与表项位域以它为准**）、`../05-ooo.md`（乱序总体设计）、`../01-pipeline.md`（流水级与冒险）。
> 本文件是后端 RTL 的直接实现依据：端口可直接照抄为 Verilog-2001（不用 SystemVerilog 专有语法），伪代码可直接改写为 `always` 块。位域冲突一律以 00/02/03 为准，本文件发现的偏差集中列在 §9。

---

## 1. 后端总体结构与时序

```
              ┌────────── rename_top（rat / freelist / checkpoint）──────────┐
 ID ─uop_id_t─►│ 读 RAT(8R) → 分配 pd(≤4) → 分配 rob_idx(4) → 分配 ckpt(≤1) │
              └──────────────┬─────────────────────────────────────────────┘
                             │ uop_rn_t
              ┌──────────────▼───── dispatch（组合，无流水寄存器）──────────┐
              │ ALU/BRU/MDU→iq_int(3 口)；LSU→iq_mem(2 口)+lsq；FPU→iq_fp  │
              └───┬───────────────┬──────────────────────┬────────────────┘
                  ▼ IS            ▼ IS                   ▼ IS   唤醒+选择+读 PRF（同拍）
              EX：ALU0/ALU1/BRU/MDU  AGU/LSU             FPU
                  └───────────────┴──────────┬───────────┘
              WB：写 PRF + tag 广播唤醒 + 标记 ROB done
              RT：ROB 头部顺序提交 ≤4 条（CSR 写 / store 落盘 / 分支 / 异常副作用）
```

### 1.1 各级每周期能力与握手

| 级 | 每周期最多 / 握手条件 | 反压 |
|---|---|---|
| RN | 4 条重命名 + 4 个 ROB 项 + 4 个 `pd` + ≤1 个 checkpoint（`id_valid[3:0]`，`rn_ready` 高才接收） | `rn_ready = !rob_full && !iq_full[*] && !lsq_full && (无分支‖ckpt_alloc_ok)` |
| DP | 4 条分发（iq_int 3 / iq_mem 2 / iq_fp 2 写口），纯组合（`rn_valid`） | 任一目标队列满 → **整组不接收**（不允许部分接收，保持程序序） |
| IS | 最多 6 个执行口发射（分配表见 §4.5）（表项 `valid & !issued & ready1 & ready2`） | FU 非流水忙（DIV/FSQRT）→ 该口 `issue_ready=0` |
| EX | ALU0/ALU1/BRU/MDU/AGU/FPU 并行（`ex_valid`） | 分支解析/store 就绪同拍产生 |
| MEM | 1 次 D-Cache 访问 + 转发比较（`mem_valid`） | D-Cache 单口、MSHR 满、TLB 缺失 |
| WB | 6 个写回口（`03` §2.4 固定分配）（`wb_valid[5:0]`） | 无（口与 FU 一一对应） |
| RT | 4 条提交（头部 `valid & done`） | 头部未 `done` → `head_block`，全后端停顿 |

### 1.2 "4 条/周期"的保持与损失

| 级 | 保持 4 条的充分条件 | 损失场景 / 代价 |
|---|---|---|---|
| IF/ID | I-Cache 命中、16 B 内 4 条 32 位指令 | 缺失、RVC 跨行、分支翻转（缺失延迟 / 1~3 拍） |
| RN | ROB ≥4 空项、空闲表 ≥4、checkpoint 可用、三类 IQ 均有余量 | ROB/IQ/LSQ 满、ckpt 耗尽、空闲表不足（§2.6 守卫），容量释放即恢复 |
| DP | 同类指令数 ≤ 该队列写口数 | 同拍某类扎堆（iq_int>3、iq_mem>2、iq_fp>2），整组停 1 拍 |
| IS | 队列内就绪表项 ≥4 | 就绪项 <4、MDU/FPU 长延迟占口，唤醒到达即恢复 |
| WB | ALU/BRU/AGU 1 拍出结果 | MUL 3 拍、DIV 32 拍、FDIV ~35 拍、load 3 拍，写口按序释放 |
| RT | 头部连续 4 项 `done`、无 `is_serial`、无异常/中断、store 就绪 | head 阻塞、`is_serial` 单条、清空、store 未就绪（§3.4） |
| 端到端 | 执行口 6 个但 BRU/MDU/LSU/FPU 各 1 | 混合负载瓶颈在执行口，预期 1.5~3.0 IPC |


---

## 2. 重命名级 `rename_top`

### 2.1 端口清单（`rtl/rename/`）

```verilog
module rename_top( input wire clk, rst_n,
  // ID 侧（03 §2.1）：id_valid[3:0]；id_pc/id_imm/id_pred/id_ghr/id_excp_cause ×4；id_rs1_arch/id_rs2_arch/id_rd_arch[4:0]×4
  input  wire [3:0] id_valid, input wire [71:0] id_ctrl [3:0], input wire id_branch_present, input wire [1:0] id_branch_slot,
  // RN 侧（03 §2.2 uop_rn_t）：rn_valid/rn_ps1/rn_ps2/rn_pd/rn_rob_idx/rn_lsq_idx ×4；ctrl/pc/imm/pred/ghr 直通
  output wire [3:0] rn_valid, output wire [6:0] rn_ps1 [3:0], output wire [6:0] rn_ps2 [3:0],
  output wire [6:0] rn_pd [3:0], output wire [6:0] rn_rob_idx [3:0], output wire [4:0] rn_lsq_idx [3:0],
  input  wire rn_ready,                                  // 下游 DP 组合给出
  // ROB 分配（03 §4）：rob_alloc_en/pc/ctrl/rd_arch/pd/pd_old/pred/ghr/lsq_idx/ckpt_idx ×4
  output wire [3:0] rob_alloc_en, output wire [6:0] rob_alloc_pd [3:0], output wire [6:0] rob_alloc_pd_old [3:0],
  output wire [31:0] rob_alloc_pc [3:0], output wire [4:0] rob_alloc_rd_arch [3:0], output wire [71:0] rob_alloc_ctrl [3:0],
  input  wire [6:0] rob_tail_q, input wire rob_full,
  // 提交级回收（RT ≤4 条）：rt_commit_en/rd_arch/rd_wen/rd_is_fp/pd/pd_old
  input  wire [3:0] rt_commit_en, input wire rt_commit_rd_wen [3:0], input wire [4:0] rt_commit_rd_arch [3:0],
  input  wire [6:0] rt_commit_pd [3:0], input wire [6:0] rt_commit_pd_old [3:0],
  // 清空/重定向（00 §3、03 §2.5）
  input  wire flush_valid, input wire [6:0] flush_rob_idx, input wire flush_all,
  input  wire redirect_valid, input wire [6:0] redirect_rob_idx, input wire unresolved_stall,
  input  wire restore_ckpt_valid, input wire [1:0] restore_ckpt_idx,
  output wire rn_stall, output wire [3:0] ckpt_valid, output wire [6:0] ckpt_rob_idx [3:0],
  output wire [127:0] free_vec_int_dbg, output wire [127:0] free_vec_fp_dbg );
```

| 子模块 | 端口要点（位宽/方向） |
|---|---|
| `rat.v`（整数/浮点各一份，`map[31:0]×7 bit`，`03` §6） | 读：`rs1/rs2_arch[3:0][4:0]`+`is_fp` → `ps[3:0][6:0]`（**组合读**）；写：RN 分配 4 口 `alloc_wen/rd/is_fp/pd` + RT 提交 4 口 `cmt_wen/rd/is_fp/pd`；恢复：`restore_en`+`rat_restore[32][6:0]`；输出 `rat_committed_int/fp[32][6:0]`（提交态影子） |
| `freelist.v`（各 128 位向量，`03` §6） | `free_vec_q[127:0]`（1=空闲，**bit0 恒 0**）、`free_cnt_q[7:0]`；`alloc_req[2:0]`(0~4)→`alloc_pd[3:0][6:0]`/`alloc_ok`；回收 `free_en/pd`（提交 4 口 + 清空 4 口）；`restore_free_vec[127:0]`；输出 `fre_committed[127:0]` |
| `checkpoint.v`（4 个 × 720 bit） | `ckpt_alloc_en/rob_idx[6:0]`→`ckpt_alloc_ok`；`ckpt_free_idx/en`、`ckpt_free_all`；`ckpt_restore_idx[1:0]`→`ckpt_hit`/`ckpt_hit_rob_idx[6:0]`；`ckpt_valid[3:0]`、`ckpt_rob_idx[3:0][6:0]`；存储体 `{rat_int[32×7], rat_fp[32×7], fre_vec[128], ras_ptr[4:0], ras_top[31:0], ghr[11:0]}` |

**checkpoint[0]** = 提交态快照（等价 `rat_committed`+`fre_committed`），`ckpt_alloc_ok` 只用 idx 1~3，它是 §2.6 反走兜底的基准。

### 2.2 4 宽重命名的读/写端口时序（同拍完成）

| 时刻 | 动作 |
|---|---|
| 拍 T 组合 | **读**：`rs1/rs2_arch` → `rat_ps1/ps2`（组合）；`rd_wen` 计数 → `alloc_req` → 优先编码器给 `alloc_pd[0..3]`。4 条 × 2 源 = **8 读口**（`05-ooo.md` §2） |
| 拍 T 组合 | **同拍旁路**：第 k 条的源 == 第 j 条（j<k）的 `rd_arch` 且 `rd_wen=1` → `ps = alloc_pd[j]`（§2.5） |
| 拍 T 组合 | **ready 判定**：`ready_j = !busy_vec[ps_j]`，`ps_j==P0` 恒 ready |
| 拍 T 组合 | **checkpoint 分配**：取组内**最年轻**分支；快照 = 该分支重命名**之前**的 RAT/free/RAS/GHR + 该分支 `rob_idx`（分支自身 `pd` 不进快照） |
| T→T+1 边沿 | **写**：RAT 写 4 个 `alloc_pd`、`busy_vec[pd]=1`、`free_vec[pd]=0`、ROB 分配 4 项（`03` §6） |
| T→T+1 边沿 | **提交写**：RT 的 ≤4 条同时写 RAT（`rd_arch→pd`）并把 `pd_old` 送回 `free_vec` |

时序预算：RAT 组合读 + 优先编码器 + 旁路 MUX ≤5.0 ns（`../01-pipeline.md` §7）。超时则先把 `alloc_pd` 编码器打一拍（多 1 级重命名流水），**不得**把 8 读口改成两周期读。

### 2.3 `x0` → P0 规则

| 规则 | 实现 |
|---|---|
| 恒映射 + 分配 | `rat[x0]=rat[f0]=P0`，不随重命名写口改变（`alloc_wen` 对 `rd_arch==0` 强制 0）；`rd_arch==x0` 或 `rd_wen=0` 时不分配新 `pd`（`pd=7'd0`），但 **ROB 表项照常分配**（保持提交序与异常定位，`05-ooo.md` §2） |
| P0 保护 + 读 | `free_vec[0]` 恒 0（不分配、不回收）；写回口 `wb_pd==0` 只标 ROB done，**不写 PRF、不广播唤醒**；源为 P0 时 `ready=1` 且读回 0（与 `alu_a_sel=zero` 独立，两者都不得依赖未定义值） |
| 浮点 | `f0` 同理；`rd_is_fp` 决定查浮点 RAT / 浮点空闲表 |

### 2.4 双 RAT 与同拍读/写冲突

| 冲突 | 规则 |
|---|---|
| RN 分配写 vs RT 提交写命中同一 `rd_arch` | **RT 优先**（架构序更老）；RN 该槽当拍不分配 `pd`（`alloc_req` 减 1）并拉低 `rn_ready`，下拍重做 —— 防止活锁，必须实现 |
| 同组两条分配写命中同一 `rd_arch`（组内 WAW） | 更年轻者胜出，前一条写口屏蔽；前一条仍分配 `pd` 并由更年轻者负责回收，**不泄漏** |
| 浮点 ↔ 整数 | RAT / 空闲表 / busy 表 / PRF **完全独立**；`fmv.x.w`/`fmv.w.x` 按目标类型分配，跨类型取值由执行单元完成，重命名不做跨表旁路 |
| 清空/重定向同拍 | `flush_valid \| redirect_valid` 时 RN **所有写口屏蔽**（RAT/busy/free/ROB/ckpt），恢复值下一拍写入（§6.4） |

### 2.5 空闲表分配伪代码（含同拍互相依赖的 `pd` 旁路）

```verilog
// 1) 只为 rd_wen=1、rd_arch!=0、且不与本拍提交写冲突的目标申请
req_num = 0;
for (k = 0; k < 4; k = k + 1)
  if (id_valid[k] && ctrl[k][`RD_WEN] && rd_arch[k] != 5'd0 && !cmt_wen_same_rd[k])
    begin alloc_mask[k] = 1'b1; req_num = req_num + 1; end
// 2) 空闲表优先编码：从低位（最早释放）起取 req_num 个互不相同的空闲位
scan = free_vec_q & 128'hFFFF_FFFF_FFFF_FFFE;        // 屏蔽 bit0(P0)
for (k = 0; k < 4; k = k + 1)
  if (alloc_mask[k]) begin
    for (i = 127; i >= 0; i = i - 1)                  // 取 scan 中最低位 1
      if (scan[i] && (sel[k] == 7'd0 || i < sel[k])) sel[k] = i[6:0];
    scan = scan & ~(128'd1 << sel[k]);                // 清除，保证 4 个 pd 互异
  end else sel[k] = 7'd0;
// 3) 同拍依赖旁路 + 就绪判定（生成 uop_rn_t）
for (k = 0; k < 4; k = k + 1) begin
  rn_pd[k] = alloc_mask[k] ? sel[k] : 7'd0;  rn_rob_idx[k] = (rob_tail_q + k) & 7'h7f;
  for (s = 0; s < 2; s = s + 1) begin
    src_arch = (s==0) ? id_rs1_arch[k] : id_rs2_arch[k];
    use_src  = (s==0) ? ctrl[k][`USE_RS1] : ctrl[k][`USE_RS2];  byp_hit = 1'b0;
    for (j = 0; j < k; j = j + 1)                     // 只看更老的组内指令
      if (id_valid[j] && alloc_mask[j] && (id_rd_arch[j] == src_arch))
        begin byp_hit = 1'b1; byp_pd = sel[j]; end    // ← 第 k 条读第 j 条的 pd
    if (!use_src || src_arch == 5'd0) begin ps[k][s]=7'd0; rdy[k][s]=1'b1; end
    else if (byp_hit)                 begin ps[k][s]=byp_pd; rdy[k][s]=1'b0; end  // 未写回
    else begin ps[k][s]=rat_rd(src_arch,is_fp); rdy[k][s]=!busy_vec[ps[k][s]]; end
  end
end
```

**关键点**：旁路产生的 `ps` 一定"未就绪"（生产者本拍才分配，最早在 WB 唤醒），绝不能当 ready，否则依赖链读到 PRF 垃圾。`ready` 初值在 **DP 入队同拍**按 `busy_vec` 重新采样（§4.3），避免 RN→DP 打拍造成漏唤醒。

### 2.6 checkpoint 分配/释放/耗尽回退

| 事件 | 规则 |
|---|---|
| 分配 | 每周期 **≤1 个**，只给组内最年轻的分支（`is_branch‖is_jalr‖is_jal`）；同组多分支只建一个，其余靠 ROB 反走 |
| 释放 | 分支**正确**提交 → 释放其 `payload.ckpt_idx`；`flush_all` → 全部释放（idx 1~3） |
| 耗尽 | `ckpt_alloc_ok=0` 且组内有分支：**不建 checkpoint**，分支照常重命名入 ROB，但经 `fill_ckpt_hint=2'b11` 通知前端（`04-frontend.md` §2.4 取指包字段）进入**保守模式**（GHR 冻结、RAS 不 push/pop），与 `04` §3.5#3 一致 —— RN **不停顿**，只损失预测精度不损失正确性 |
| 恢复 | 有 checkpoint 释放后撤销 `fill_ckpt_hint`/保守模式；该区段若发生误预测则走 ROB 反走（§2.7） |
| 死锁守卫 | `ckpt_alloc_ok=0` 且 ROB 中无未提交分支（`ckpt_branch_inflight=0`）→ `SIM_ASSERT(ckpt_stuck)`；硬件保守动作：强制释放全部 ckpt 并放行 |
| 超前瞻守卫 | ROB 已满 48 项且 4 个 checkpoint 全占用 → 前端 `fq_throttle=1`（取指队列阈值降到 8 项），避免前端跑比重命名超前过多（`04` §3.5 动态阈值） |
| 空闲表守卫 | `free_cnt < alloc_req` → `rn_ready=0` 并计 `fre_starve`；**不允许**忽略 `alloc_ok` 继续分配 |

### 2.7 ROB 反走恢复：逐拍算法伪代码

**语义**：触发（`redirect_valid && !ckpt_hit`）后作废 `(flush_rob_idx, tail]` 全部表项，把 RAT/free/busy 回滚到"`flush_rob_idx` 这条指令已重命名完成"的状态（与该指令仍留在 ROB 中一致）。

```verilog
if (redirect_valid && !ckpt_hit)                       // 启动：冻结 ID→RN + 组合清年轻表项
  begin walk_go<=1; walk_ptr<=rob_tail_q; walk_target<=redirect_rob_idx; rn_stall<=1;
        rob_rewalk_start<=1; flush_younger_comb(redirect_rob_idx); end   // 前端见 04 §3.5
else if (walk_go && walk_ptr == walk_target)           // 收敛：walk_target 自身必须存活
  begin walk_go<=0; rn_stall<=0; rob_rewalk_done<=1;                  // 04 收到后解除 if_freeze
        rob_tail_q<=(walk_target+7'd1)&7'h7f; end
else if (walk_go && (rob_valid[walk_ptr] || rob_done[walk_ptr])) begin
  if (rob_rd_wen[walk_ptr] && rob_pd[walk_ptr] != 7'd0)          // ① 回收新物理寄存器
    begin free_vec[rob_pd[walk_ptr]]<=1; busy_vec[rob_pd[walk_ptr]]<=1; end
  if (rob_rd_wen[walk_ptr] && rob_rd_arch[walk_ptr] != 5'd0)     // ② RAT 回滚到 pd_old
    if (rob_rd_is_fp[walk_ptr]) rat_fp [rob_rd_arch[walk_ptr]]<=rob_pd_old[walk_ptr];
    else                        rat_int[rob_rd_arch[walk_ptr]]<=rob_pd_old[walk_ptr];
  rob_valid[walk_ptr] <= 1'b0;  walk_ptr <= (walk_ptr - 7'd1) & 7'h7f;   // ③ 作废并前进
end
```

| 要点 | 说明 |
|---|---|
| 收敛 | `walk_ptr == walk_target` 时**不动**该表项：发起清空的指令（分支/load）必须存活 |
| `pd_old` 回滚 | 只对 `rd_wen=1 && rd_arch!=0` 的项写 RAT；`pd_old` 就是"上一版物理号"，天然是回滚值 |
| 与提交交互 | 反走期间 `head_q` 不动、`walk_ptr` 只退到 `head_q` 之上，**绝不回滚已提交映射**（已提交映射另存于 `rat_committed`） |
| 时间/并发 | 最坏 127 拍；期间 `rn_stall=1`，但 IS/EX/WB/RT 照常（更老指令继续提交，推前 ROB 头） |
| 兜底 | 若反走指针越过 `head_q`，或 checkpoint 已失效且反走无法给出精确目标 → **整清**：`flush_all` 清空全部在途指令，RAT/free 从 `rat_committed`/`fre_committed` 重建（正确但不精确，需重取执行）；该路径仅作最后防线 |

---

## 3. ROB `rob.v`

### 3.1 端口清单

```verilog
module rob( input wire clk, rst_n,
  // 分配（RN，4 条）03 §4：alloc_en/pc[31:0]/ctrl[71:0]/rd_arch[4:0]/pd/pd_old/pred/ghr/lsq_idx/ckpt_idx
  input  wire [3:0] alloc_en, output wire [6:0] rob_tail_q, output wire rob_full, output wire [6:0] rob_free_cnt,
  input  wire [31:0] alloc_pc [3:0], input wire [71:0] alloc_ctrl [3:0], input wire [6:0] alloc_pd [3:0],
  input  wire [6:0] alloc_pd_old [3:0], input wire [4:0] alloc_rd_arch [3:0], input wire [4:0] alloc_lsq_idx [3:0],
  // 写回更新（6 口，03 §2.4）：wb_valid/wb_rob_idx/wb_excp_valid/wb_excp_cause/wb_excp_tval
  input  wire [5:0] wb_valid, input wire [6:0] wb_rob_idx [5:0], input wire [5:0] wb_excp_valid,
  input  wire [3:0] wb_excp_cause [5:0], input wire [31:0] wb_excp_tval [5:0],
  input  wire [5:0] wb_br_resolved, input wire [5:0] wb_br_actual_taken,          // 口 0：分支解析
  input  wire [31:0] wb_br_actual_target [5:0], input wire [5:0] wb_st_ready,      // 口 3：store 就绪
  // 提交（RT ≤4 条）：cmt_valid/pc/rd_arch/rd_wen/rd_is_fp/pd/pd_old/rd_is_store/lsq_idx/is_serial/is_amo/is_branch/ckpt_idx/ghr/pred
  output wire [3:0] cmt_valid, output wire [31:0] cmt_pc [3:0], output wire [6:0] cmt_pd [3:0],
  output wire [6:0] cmt_pd_old [3:0], output wire [4:0] cmt_rd_arch [3:0], output wire [3:0] cmt_is_serial,
  input  wire [3:0] st_cmt_ack, input wire [3:0] csr_cmt_ack, output wire [3:0] cmt_commit_en,
  // 异常/中断/清空
  output wire rob_head_valid, rob_head_done, rob_head_excp, output wire [31:0] rob_head_pc,
  output wire [3:0] rob_head_cause, output wire [31:0] rob_head_tval, output wire [6:0] rob_head_rob_idx,
  input  wire [5:0] intr_pending,                          // 03 §2.7 {MSI,MTI,MEI,SSI,STI,SEI}
  output wire trap_valid, output wire [3:0] trap_cause, output wire [31:0] trap_tval, trap_epc,
  input  wire flush_valid, input wire [6:0] flush_rob_idx, input wire flush_all,
  output wire walk_go_out, output wire [6:0] walk_ptr_out, perf_head_block, perf_rob_full );
```

### 3.2 表项位域

严格照 `03` §4（128 bit）：`valid[0]`、`done[1]`、`rd_wen[2]`、`rd_is_fp[3]`、`rd_arch[8:4]`、`pd[15:9]`、`pd_old[22:16]`、`excp_valid[23]`、`excp_cause[27:24]`、`is_store[28]`、`is_branch[29]`、`is_serial[30]`、`is_amo[31]`、`payload[95:32]`、`pc[127:96]`；`payload` 复用（store/AMO、branch、serial、其它含异常）见 `03` §4 表。两条实现补充：

| 补充 | 内容 |
|---|---|
| store | 地址与数据**都留在 LSQ**，ROB 只存 `{lsq_idx[4:0], mem_size, mem_flags}`（`../05-ooo.md` §3 表中的 `store_addr/store_data/store_size` 不入 ROB） |
| `excp_tval` | 非访存类：`payload={excp_tval[31:0], pad}`；访存类：提交时从 LSQ 表项 `fault_va` 读回（`03` §4） |

### 3.3 分配与写回时序

| 操作 | 时序 |
|---|---|
| 分配 | 与 RN 同拍：`alloc_en[k]` → 写 `rob[tail+k]`；`tail_q <= tail_q + popcount(alloc_en)` |
| 写回 | WB 同拍：`wb_valid[i]` 按 `wb_rob_idx[i]` 置 `done=1`；`wb_excp_valid[i]` 置异常字段与 payload |
| 分支 | 口 0 的 `wb_br_resolved` 写 branch payload：`{ckpt_idx, actual_taken, is_call, is_ret, actual_target, ghr_snapshot}` |
| store | 口 3 的 `wb_st_ready` 把对应 LSQ 项置 `READY`（ROB 只需 `done`） |
| 清空 | `flush_valid` → `is_younger(rob_idx, flush_rob_idx)` 的项 `valid<=0`；`flush_all` → 除已提交外全清 |

### 3.4 4 宽提交逻辑

```verilog
// 1) 从 head 起取连续可提交前缀（≤4）
cmt_num = 0; blocked = 1'b0;
for (k = 0; k < 4; k = k + 1) begin
  idx = (head_q + k) & 7'h7f; ok = rob_valid[idx] && rob_done[idx] && !blocked;
  if (k > 0 && rob_is_serial[(head_q + k - 1) & 7'h7f]) ok = 1'b0;  // 串行指令后暂停一拍
  if (ok && rob_is_store[idx]) ok = stq_ready[idx];                 // store 需 LSQ READY
  cmt_en[k] = ok; if (!ok) blocked = 1'b1; else cmt_num = cmt_num + 1;
end
// 2) 异常/中断在头部插入
intr_go    = (|(intr_pending & mie_q)) && rob_head_valid && rob_head_done
             && !rob_head_excp && !is_serial_committing;          // 串行指令提交拍不采中断
trap_go    = rob_head_valid && rob_head_done && (rob_head_excp || intr_go);
trap_cause = rob_head_excp ? {1'b0, rob_head_cause}                // 同步异常
                           : {1'b1, intr_code6(prio(intr_pending & mie_q))};
trap_epc   = rob_head_pc;  trap_tval = rob_head_excp ? rob_head_tval : 32'd0;
```

| 规则 | 内容 |
|---|---|
| 提交序 | 严格按 `head_q` 递增，**不允许跳过**未 `done` 的表项（head 阻塞） |
| `is_serial` | **单独提交**（`cmt_num=1`）且**下一拍暂停后续提交**（`cmt_pause_q`），让 CSR/特权/MMU 副作用（`mstatus.MIE`、`satp`、`fs`）稳定；同时广播 `flush_valid(该指令 rob_idx)` 清掉更年轻指令 |
| store | 头部 store 且 `done` → 发 `st_cmt_ack` 请求（LSQ 把已提交数据写入 D-Cache/Store Buffer），**收到 ack 才推进 head**（`cmt_en &= st_cmt_ack`），保证提交即可见 |
| CSR | `csr_waddr/csr_wdata/csr_wen/csr_wmask` 只在 RT 生效（`03` §2.7），`csr_cmt_ack` 组合应答，`cmt_en &= csr_cmt_ack` |
| 分支 | 解析不符 → 触发重定向（§6.2）；正确 → 更新 GHR/PHT/BTB/RAS 并释放 `ckpt_idx` |
| AMO | `is_amo` 提交时释放 LR 保留集 |
| 回收 | 每条提交：`pd_old`（!=P0）送回空闲表，`pd` 成为新架构映射（RAT 写口），`minstret += cmt_num`；`rd_wen=0` 或 `rd_arch=0` 只推进 head |

### 3.5 中断采样点与 `mstatus.MIE` 时序正确性

| 要求 | 实现与理由 |
|---|---|
| 采样点 | **每周期**在 RT 级采样 `intr_pending & mie_q`，且只在"ROB 头部可提交（`valid && done`）"时触发：中断精确插入在两条指令之间（`../01-pipeline.md` §4、`04` §6） |
| 不可中途打断 | 头部未 `done` 时即使中断挂起也不触发（`head_block` 优先）；`is_serial` 提交拍不触发 |
| 与异常优先级 | **同步异常优先**；异常发生时头部指令不提交、年轻项被清空，中断只能在新的头部重新采样 |
| `MIE` 更新时序 | `csr_wen`/trap 对 `mstatus` 的更新与 `cmt_commit_en` **同拍**生效，而 `intr_go` 使用**提交前的 `mie_q`**。故：① `csrrs mstatus,MIE` 打开的使能当拍不生效，最早在**下一条指令边界**采到；② `MRET`（`MIE←MPIE`）提交拍 `MIE` 仍为旧值，中断最早在其**下一条指令**边界被取；③ trap 进入时 `xIE←0` 与重定向同拍生效，保证 handler 首条指令不被同级中断打断 |
| 重定向 | `trap_valid` → `flush_all=1`（前端 + IQ/LSQ/ROB 全清）→ `redirect_pc = {xtvec.base,2'b00}`（`MODE=1` 且为中断时 `+cause×4`，`04` §6）；`redirect_is_trap=1` 抑制 IF2 写入 |
| `WFI` | `is_serial` + `sys_op=WFI`：不推进 head，直到 `\|(intr_pending & mie_q)`（**不看全局 `MIE`**，规范要求）；唤醒后 `mepc = WFI 的 PC + 4` |

---

## 4. 发射队列 `iq_*.v` 与 `wakeup_select.v`

### 4.1 队列与表项

| 队列 | 文件 | 深度 | DP 写口 | IS 读口 | 服务 FU |
|---|---|---|---|---|---|
| 整型 | `iq_int.v` | 32（`IQ_INT_DEPTH`） | 3/周期 | 4/周期 | ALU0、ALU1、BRU、MDU |
| 访存 | `iq_mem.v` | 24（`IQ_MEM_DEPTH`） | 2/周期 | 2/周期 | AGU/LSU（load/store/AMO/CBO） |
| 浮点 | `iq_fp.v` | 16（`IQ_FP_DEPTH`） | 2/周期 | 1/周期 | FPU（FMA/FDIV/FCVT/FCMP/FCLASS） |

表项 = `03` §3 `iq_entry_t`：`valid`、`issued`、`ready1`、`ready2`、`ps1/ps2/pd`（7×3）、`rob_idx[6:0]`、`lsq_idx[4:0]`、`ctrl[71:0]`、`imm[31:0]`、`pc[31:0]`、`age[4:0]`。**本设计省略 `age`**（`03` §3 允许"可省略，由 `rob_idx` 判断"），年龄统一由 `rob_idx` 环形比较给出，省 5×72 bit。

### 4.2 `valid/issued/ready1/ready2` 状态机

| 现态 | 事件 | 次态 |
|---|---|---|
| 空 | DP 写入 | `valid=1, issued=0, ready_j = !busy_vec[ps_j]`（`ps==P0` → 1） |
| 就绪（`ready1&ready2`） | 被选中并发射 | `issued=1` |
| 就绪 | 未入选 | 保持，下拍继续参选 |
| 已发射 | `wb_valid[i] && wb_pd[i]==pd` | 释放（`valid=0`），腾出表项 |
| 任意 | `flush_all` 或 `is_younger(rob_idx, flush_rob_idx)` | 释放 |

**防漏唤醒**：`ready` 必须在 **DP 入队同拍**按 `busy_vec` 采样，而不是沿用 RN 的组合值。若 RN→DP 之间插流水寄存器，须用打拍后的 `busy_vec` 重采，否则"RN 拍未就绪、DP 拍生产者已写回"的指令会永久悬挂。等价写法：`ready = !busy_vec[ps] | (本拍任一写口 pd==ps)`。

### 4.3 唤醒网络

```verilog
for (e = 0; e < IQ_DEPTH; e = e + 1) for (s = 0; s < 2; s = s + 1) begin
  hit = 1'b0;
  for (i = 0; i < 6; i = i + 1)
    if (wb_valid[i] && (wb_pd[i] != 7'd0) && (wb_pd[i] == ent[e].ps[s])
        && (wb_is_fp[i] == ent[e].is_fp))            // 整数/浮点写口不跨类唤醒
      hit = 1'b1;
  ent_next[e].ready[s] = flush_clear ? 1'b0 : (ent[e].ready[s] | hit);
end
```

| 规则 | 说明 |
|---|---|
| 多写口同拍 | 6 个写口**并行**比较，可同拍唤醒多个表项；同一表项两源被两口唤醒也允许 |
| 写口→队列映射 | 口 0(ALU0/BRU)/1(ALU1)/2(MDU)/3(LSU) 唤醒整型与访存队列；口 4(FPU) 只唤醒浮点队列；口 5(CSR/SYS) **不唤醒**（不写 PRF） |
| load 的特殊性 | load 数据在 WB 级（口 3）有效，与 ALU 共用同一 tag 广播，**无需专用路径**；但唤醒**只发生一次且必然发生**：Cache 缺失时表项留在 LSQ，MSHR 回填后重新访存，再在 WB 广播。缺失期间依赖者 `ready` 保持 0（不做投机唤醒，`../01-pipeline.md` §2.1） |
| 长延迟 | DIV/FDIV/FSQRT 只在 WB 级唤醒，唤醒与写回严格同拍，**不允许提前唤醒** |
| 漏唤醒防护 | `SIM_ASSERT`：`issued=1` 超过 `MAX_LAT`（建议 128）拍仍未写回 → 报错 |
| 唤醒-发射同拍 | 唤醒置位与发射选择同拍组合完成，因此唤醒当拍即可发射；读 PRF 的数据由旁路补齐（§5.2） |

### 4.4 最老就绪优先选择（`rob_idx` 环形年龄 + 级联屏蔽）

```verilog
function is_younger; input [6:0] a, b;      // a 是否比 b 年轻（00 §3 原文，放 rv32gc_defs.vh）
  begin is_younger = (((a-b) & 7'h7f) != 7'h00) && (((a-b) & 7'h7f) < 7'd64); end
endfunction
mask = {IQ_DEPTH{1'b1}};                    // 屏蔽向量，每轮清掉已选中的表项
for (n = 0; n < N; n = n + 1) begin
  sel[n] = INVALID;
  for (e = 0; e < IQ_DEPTH; e = e + 1)
    if (ent[e].valid && !ent[e].issued && ent[e].ready1 && ent[e].ready2 && mask[e]
        && (sel[n]==INVALID || is_younger(ent[sel[n]].rob_idx, ent[e].rob_idx))) sel[n]=e;
  if (sel[n] != INVALID) mask[sel[n]] = 1'b0;
end
```

| 要点 | 说明 |
|---|---|
| 年龄全序 | 在途项 ≤ ROB 深度 128；`is_younger` 的半区间判据（差值 ∈[1,63]）在窗口 ≤64 时构成全序，不会出现"既非更老也非更年轻"的第三态 |
| 级联屏蔽 | 先选最老 → 屏蔽 → 再选次老…面积近似 O(N×M)；`../01-pipeline.md` §7 降级项 1 即把该组合逻辑拆为两级流水 |
| 互斥 | 同一表项不会被选两次，因此 4 条发射的 `pd`/`lsq_idx` 天然互异 |
| 空转 | `sel[n]=INVALID` 时该口 `ex_valid=0`，不影响其他口 |

### 4.5 发射→执行单元分配表

| 队列 | 目标 FU | 每周期条数 | 写回口（`03` §2.4） | 备注 |
|---|---|---|---|---|
| 整型 32 | ALU0 | 1 | 0 | 优先口 |
| 整型 32 | ALU1 | 1 | 1 | — |
| 整型 32 | BRU（条件分支 + JAL/JALR） | 1 | 0（与 ALU0 合并） | 分支解析 + 重定向 |
| 整型 32 | MDU | 1 | 2 | MUL 3 拍流水；DIV/REM 非流水 32 拍，占口期间 `issue_ready=0` |
| 访存 24 | AGU/LSU：load | 1 | 3 | load 优先 |
| 访存 24 | AGU/LSU：store/AMO/CBO | 1 | 3 | 与 load 争 D-Cache 单口时让位 |
| 浮点 16 | FPU 流水运算（FMA/FMUL/FADD…） | 1 | 4 | 流水 1 条/周期 |
| 浮点 16 | FPU 非流水（FDIV/FSQRT/FCVT） | 同口 | 4 | 占用期间该口不接收新 uop |

- 整型队列单周期上限 **4 条**（ALU0/ALU1/BRU/MDU 各 1），DP 侧只用 3 个写口（MDU 与 ALU 争用时按"最老就绪"统一仲裁）。
- 访存队列上限 **2 条**：D-Cache 单口，实际并行模式为 "1 load + 1 store"，2 条 load 串行。
- 浮点队列上限 **1 条**（`../05-ooo.md` §4 允许 1~2；4 发射混合负载下取 1 口省面积，IPC 不足时再扩为 2 口）。

### 4.6 发射级读 PRF + 旁路（生成 `03` §2.3 的 `op_a/op_b`）

```verilog
for (p = 0; p < 4; p = p + 1) for (s = 0; s < 2; s = s + 1) begin
  ps = sel_entry[p].ps[s];  byp_sel = BYP_PRF;
  if (is_fu_pipe_match (ps)) byp_sel = BYP_FU;    // 口 0/1/2/4：含 MUL 3 拍、DIV/FPU 末拍
  if (is_load_wb_match (ps)) byp_sel = BYP_LOAD;  // 口 3：load 数据（与 FU 同拍时 FU 优先）
  if (is_ex_stage_match(ps)) byp_sel = BYP_EX;    // EX 拍结果，优先级最高
  op_data[p][s] = (ps==7'd0) ? 32'd0 : mux4(byp_sel, prf_rd[p][s], ex_result, load_wb_data, fu_wb_data);
end                                            // op_a/op_b 再按 alu_a_sel/alu_b_sel 在 EX 入口选择
```

| 规则 | 说明 |
|---|---|
| 时序 | IS 拍：唤醒 + 选择 + 读 PRF；EX 拍：用 `op_a/op_b`。PRF 同步读，1 级流水隐藏 MUX 延迟（`../05-ooo.md` §5） |
| `imm_shamt` | 取 `imm[4:0]` 零扩展（`imm_gen` 生成，RN 之后不再改动） |
| 浮点 | `fp_op_a/fp_op_b/fp_op_c`（64 bit）同样走旁路；`fp_op_c` 仅 FMA 类（`fp_op ∈ 19~22`）使用 |
| 反压 | FU 非流水忙 → 该口 `issue_ready=0`，`sel[n]=INVALID`，表项保持就绪等待 |

**RT 级提交向量（供锁步/轨迹，`09-verification-interface.md` §2.2）**：`dbg_commit_valid[3:0]`、`dbg_commit_pc[3:0][31:0]`、`dbg_commit_instr[3:0][31:0]`（RVC 已展开）、`dbg_commit_rd[3:0][4:0]`、`dbg_commit_wen[3:0]`、`dbg_commit_wdata[3:0][63:0]`（整数用 `[31:0]`，**浮点 64 位必须走这里**）、`dbg_commit_is_fp[3:0]`、`dbg_commit_excp_valid[3:0]`/`dbg_commit_excp_cause[3:0][3:0]`；平台端口 `debug0_wb_*` 保持 32 位不变、**不得**承载 F/D 值。

---

## 5. PRF `prf.v` 与旁路 `bypass.v`

### 5.1 端口与分 Bank

```verilog
module prf( input wire clk, rst_n,
  input wire [6:0] rd_addr [7:0], output wire [31:0] rd_data_int [7:0], output wire [63:0] rd_data_fp [7:0],
  input wire [5:0] wr_en, input wire [6:0] wr_pd [5:0], input wire [63:0] wr_data [5:0],
  input wire [5:0] wr_is_fp,                               // 口 0/1/2/3 整型，口 4 浮点，口 5 不写 PRF
  input wire [4:0] dbg_reg_num, output wire [31:0] dbg_rdata );
module bypass(
  input wire [6:0] src_pd [3:0][1:0], input wire src_valid [3:0][1:0],
  input wire [5:0] wb_valid, input wire [6:0] wb_pd [5:0], input wire [63:0] wb_data [5:0],
  input wire [5:0] wb_is_fp, input wire [31:0] ex_result [3:0], input wire [3:0] ex_valid,
  output wire [63:0] op_data [3:0][1:0], output wire [3:0] op_hit_load, output wire [3:0] op_hit_ex );
```

| PRF | 容量 | 读口 | 写口 | Bank 划分 | 仲裁 |
|---|---|---|---|---|---|
| 整数 | 128×32（4 Kbit） | 8（4 条×2 源） | 4（口 0/1/2/3） | 2 Bank × 64 项，`bank = pd[6]` | 每 Bank 4 读 2 写；同 Bank 读冲突按口序 0>1>2>3 优先，被压下的口由**旁路补齐**（旁路命中即不需要 PRF 值；未命中属分配器缺陷 → `SIM_ASSERT`） |
| 浮点 | 128×64（8 Kbit） | 8 | 1（口 4） | 2 Bank × 64 项，`bank = pd[6]` | 同上；浮点仅 1 写口，无写冲突 |

- 实现：FF 阵列（可选 `(* ram_style = "distributed" *)`）；复位时**必须写 P0=0**，其余项不初始化（`busy_vec` 保证不被读）。读口映射：`rd_addr[2p]`= 第 p 口源 A、`rd_addr[2p+1]`= 源 B；`is_fp` 决定读整数还是浮点 Bank。
- **写口冲突优先级**：`load(口3) > ALU0/BRU(口0) > ALU1(口1) > MDU(口2) > FPU(口4)`。物理上 6 个写口与 Bank 固定连线，冲突只发生在**同 Bank 同拍 2 写**：按优先级写入 1 个，被压下的那路**保留在写口寄存器下一拍重试**（`wb_stall_hold`），同时**照常广播唤醒**（唤醒与写数据解耦，不漏唤醒、不丢数据）。比"丢写 + 插 1 拍"（`01-pipeline.md` §2.4）代价更低且不死锁。

### 5.2 旁路网络来源优先级

| 优先级 | 来源 | 数据 | 生效时机 | 说明 |
|---|---|---|---|---|
| 1（最高） | EX 拍结果 | `ex_result[3:0]` | EX 同拍 | ALU/BRU/AGU 组合结果（同拍双 EX 转发与断言） |
| 2 | FU 流水结果（口 0/1/2/4） | `wb_data` | MEM/WB 拍 | 含 MUL 3 拍、DIV/FPU 末拍；与 load 同拍时 FU 优先（同拍不可能同 `pd`，仅定义 tie-break） |
| 3 | load 结果（口 3） | `wb_data[3]` | WB 拍 | Cache 缺失时由 MSHR 回填后重新访存，再走本级 |
| 4（最低） | PRF 读出值 | `prf_rd_int/fp` | IS 拍 | 源已 ready 且无写回冲突 |

| 规则 | 说明 |
|---|---|
| 比较粒度 | 每源（8 个）一个 6→1 比较 + 一个 4:1 MUX（`../05-ooo.md` §5"每源一个 4:1 MUX"） |
| tag 匹配 | 只比 `pd`（唤醒 tag），不比 `rob_idx`；重命名保证同一 `pd` 不会被两条在途指令写 |
| 类型隔离 | `wb_is_fp[i]` 必须与源的 `is_fp` 一致才旁路；跨类型（`fmv.x.w`）由执行单元在 EX 完成 |
| `P0` | 源 `pd==0` 直接给 0，不参与比较 |
| 时序 | 旁路 MUX + ALU 加法器 ≤5.0 ns；超标时先砍优先级 1（只服务同拍 store→load，可由 LSU 内部转发替代） |

---

## 6. 精确异常与恢复

### 6.1 异常在 ROB 头部触发的完整时序

| 拍 | 动作 |
|---|---|
| T | 头部 `valid && done && excp_valid` → 组合产生 `trap_valid/cause/tval/epc`；同拍 **`flush_all=1`**：前端、RN 流水、IQ、LSQ、ROB 的更年轻表项全部作废；`redirect_valid=1`、`redirect_pc=trap_vector`、`redirect_is_trap=1` |
| T | CSR 同拍：`xepc←trap_epc`、`xcause←trap_cause`、`xtval←trap_tval`、`xPIE←xIE`、`xIE←0`、`xPP←当前特权级`（`04` §6；委托由 `medeleg/mideleg` 决定写 M 还是 S） |
| T+1 | 前端从 `mtvec/stvec` 取指；IQ/LSQ/ROB 已无更年轻表项；空闲表回收全部在途 `pd`（§6.4）；若回收逐拍完成则 `rn_stall` 保持到 `free_cnt` 稳态 |
| T+2 | 取指块进入 ID/RN，trap handler 开始流出；`trap_valid` 落下 |

**精确性保证**：① 只有头部指令能触发；② 头部指令本身无架构副作用（`rd` 不写、store 不落盘、CSR 不生效，`04` §6）；③ 更老指令全部已提交，重定向后不会重执行。

### 6.2 分支误预测：checkpoint 恢复 vs ROB 反走

```verilog
mispredict = br_resolved && (actual_taken != pred_taken || (actual_taken && actual_target != pred_target));
ckpt_hit   = 1'b0;
for (i = 1; i < 4; i = i + 1)
  if (ckpt_valid[i] && (ckpt_rob_idx[i] == redirect_rob_idx)) ckpt_hit = 1'b1;   // 双重校验，见 §9 C4
```

| 情形 | 恢复方式 | 代价 |
|---|---|---|
| **陈旧 checkpoint 风险** | `payload.ckpt_idx` 只有 2 bit、同一槽会被后续分支复用，故命中判据**必须**是 `ckpt_valid[i] && ckpt_rob_idx[i]==redirect_rob_idx`（不能只比 idx），不等则走反走 | — |
| `ckpt_hit=1` | **checkpoint 恢复**：整表写回 `rat_int/rat_fp/free_vec/ras/ghr`，`rob_tail ← ckpt_rob_idx+1`，释放更年轻表项 | 1~2 拍 |
| `ckpt_hit=0` | **ROB 反走**（§2.7）：逐拍回滚 RAT/free | ≤128 拍 |
| `flush_all`（复位/`fence.i`/调试） | 全清 + 从 `rat_committed`/`fre_committed` 重建 | 立即 |

### 6.3 部分清空规则对比表

| 触发 | `flush_rob_idx` | RAT/free 恢复 | LSQ | IQ | ROB | 前端 |
|---|---|---|---|---|---|---|
| 分支误预测（ckpt 命中） | 分支 | checkpoint 整表恢复 | 年轻项作废 | 年轻项作废 | 年轻项作废，`tail=分支+1` | 重定向到真实目标 |
| 分支误预测（无反走/耗尽） | 分支 | 逐拍反走 | 同上 | 同上 | 同上（反走结束时更新 `tail`） | 同拍重定向 |
| LSU replay（store 违例/DCache 重放） | **`load.rob_idx - 1`**（`06` §3.6，load 自身也作废） | 逐拍反走（load 亦回滚） | 该 load 置 `replay`；**该 load 及更年轻项**作废 | 同上 | 同上 | 重定向到**该 load 的 PC**（重新取指） |
| 串行指令提交（CSR/SYS/FENCE） | 该指令 | 无需恢复（存活项不动） | 年轻项作废 | 年轻项作废 | 年轻项作废 | **不重定向**，继续顺序取指 |
| 异常 / 中断 | `flush_all` | 从 `rat_committed` 重建 | 全清 | 全清 | 全清（保留已提交） | 重定向到 `xtvec/stvec` |
| `fence.i` / 调试断点 | `flush_all` | 同上 | 同上 | 同上 | 同上 | 重定向到 `PC+4`/调试入口 |

**两者差异**：① 都要重取指（replay 的目标 PC = 该 load 的 PC）；② **被清指令的 `pd` 全部回收**（含 replay 的 load 自身 —— `06` §3.6 取 `flush_rob_idx = load.rob_idx - 7'd1`，因为 load 不再保留、无需为其保存 `next_pc`）；③ 分支可用 checkpoint，**replay 不能**（checkpoint 只记在分支点）→ 必须反走；④ replay 期间 LSQ 同步作废该 load 的项与 `replay` 标志、保守清保留集（`06` §3.6）。
> 若将来改为"load 存活、由 LSQ 重发"，则 `flush_rob_idx` 取 `load.rob_idx`、load 的 `pd` 保留、RAT 不回滚该 load 的映射 —— 本文件的清空/回滚硬件两种方案都支持（只差一个 `-1`）。

### 6.4 清空层次与"清空中又清空"的边界

| 层次 | 信号/行为 |
|---|---|
| 前端 | `flush_valid`（带 `rob_idx`）→ IF/ID 丢弃年轻取指；`flush_all` → 清取指队列并复位 BPU 推测状态（GHR 从 checkpoint/`rat_committed` 恢复），`00` §3 |
| RN | 清空同拍**屏蔽所有写口**（RAT/busy/free/ROB/ckpt），恢复动作在后续拍完成，防止"清空拍又写入错误映射" |
| IQ/LSQ/ROB | 每项比较 `is_younger(ent.rob_idx, flush_rob_idx)`，命中则组合置无效，当拍生效 |

| 边界场景 | 处理 |
|---|---|
| 清空拍同时有写回 | **清空优先**：`done` 更新被丢弃（表项已无效）；PRF 写仍照常（写错物理号无害：该 `pd` 已回收、不会被读），但**不广播唤醒** |
| 清空拍同时有发射 | `issue_ready` 全 0；已发射未写回的指令随表项作废，其 `pd` 由反走/checkpoint 回收 |
| 连续两拍清空 | 以**更老**的 `flush_rob_idx` 为准：反走未收敛时**接管** `walk_ptr` 并把 `walk_target` 更新为更老索引；若第二次更年轻则忽略（其目标已作废）。实现上 `walk_go` 期间只接受 `is_younger(new_target, walk_target)` 为真的更新 |
| 反走中出现 checkpoint 可恢复的清空 | **不中途切换**，反走走到收敛（保持不变量），代价是少量周期 |
| 提交与清空同拍 | 已提交表项不受影响（`head_q` 在提交拍推进，清空只作用于 `head_q` 之上）；`flush_all` 与 `flush_valid` 同拍时 `flush_all` 胜出 |

### 6.5 `flush_rob_idx` 年龄比较函数

```verilog
// rv32gc_defs.vh（00 §3 原文，唯一实现，全模块共用）
function is_younger; input [6:0] a, b;                 // a 是否比 b 年轻
  begin is_younger = (((a - b) & 7'h7f) != 7'h00) && (((a - b) & 7'h7f) < 7'd64); end
endfunction
function is_older_or_eq; input [6:0] a, b; begin is_older_or_eq = !is_younger(a, b); end endfunction
wire ent_kill = flush_all | (flush_valid & is_younger(ent_rob_idx, flush_rob_idx));
```

注意 `is_older_or_eq(a,b)` 对 `a==b` 与"a 更老"都为真，故清空时**不能**用它把发起者自己清掉：`flush_valid` 的语义是"**严格更年轻**者作废"（`00` §3），与 `is_younger` 的 `!=0` 判据一致。

---

## 7. 性能计数器

| 计数名 | 位宽 | 更新条件 |
|---|---|---|
| `perf_cycle` / `perf_instret` | 64 / 64 | 每拍 +1；`+cmt_num`（受 `mcountinhibit.CY/IR`） |
| `perf_issue_cnt[5:0]` | 32×6 | 每个执行口 `ex_valid` 时 +1（各 FU 发射槽占用） |
| `perf_issue_slot_used` | 32 | `+popcount(ex_valid[5:0])`，利用率 = `/(perf_cycle×6)` |
| `perf_commit_slot_used` | 32 | `+cmt_num`，提交带宽利用率 = `/(perf_cycle×4)` |
| `perf_stall_rob_full` / `perf_stall_lsq_full[1:0]` / `perf_stall_iq_full[2:0]` | 32 / 32×2 / 32×3 | ROB 满 / load-store 队列满 / `iq_full[int/mem/fp]` 周期 +1 |

| `perf_stall_wakeup[2:0]` / `perf_stall_head_block` | 32×3 / 32 | 队列非空但 `sel==INVALID`（按队列）/ 头部未 `done` 的周期 +1 |
| `perf_flush_cnt[2:0]` / `perf_flush_killed[2:0]` | 32×3 / 32×3 | 分支误预测 / replay / 异常中断 的次数；每次清空累计作废 ROB 表项数 |
| `perf_walk_cycle` | 32 | `walk_go` 周期 +1（反走开销） |
| `perf_store_fwd_hit` / `perf_load_replay` | 32×2 | LSQ 转发命中 / load 重放 |

**互斥归因**：`perf_stall_*` 每拍**最多一个**加 1，优先级 `rob_full > iq_full > lsq_full > wakeup > head_block`，避免"stall 之和 > 周期数"。这些计数映射到 `mhpmcounter3..15`（`04` §2.1 允许其余读 0），并可由 `RV32GC_DEBUG` 导出为调试寄存器。

---

## 8. 验证要点（每项给出可执行判据）

| # | 验证项 | 可执行判据 |
|---|---|---|
| 1 | 重命名 WAW/WAR/RAW | 随机序列（4 条同写 `rd`、4 条互依赖）+ 顺序核锁步，逐条比对 `debug0_wb_pc/rf_wnum/rf_wdata`（`../08-verification.md` §2.4）；每拍断言 `free_vec & busy_vec == 0`、`popcount(free_vec)+popcount(busy_vec)==128` |
| 2 | `x0`/`f0` 与浮点转发 | 断言 `rat_int[0]==0`、`free_vec[0]==0`、`busy_vec[0]==0` 恒成立；`addi x0,x0,1`/`c.li x0`/`fmv.w.x f0,..` 的 `rd=x0` 写必须丢弃；`fadd.s→fmv.x.w→add`、`fld→fadd.d→fsd` 链锁步，且整数旁路不命中浮点 `pd` |
| 4 | ROB 精确异常 | `div`（32 拍）/缺失 `ld` 后紧跟 `ebreak`/非法指令：异常前指令全部提交（`minstret` 增量正确）、异常指令及之后**零副作用**（store 未落盘、rd 未变）、`mepc/mcause/mtval` 与 Spike 一致 |
| 5 | 唤醒不丢失 | `ld→8 条依赖链`、`div→依赖链`、`fdiv.d→依赖链`：不超时（无死锁）、`SIM_ASSERT` 的 `issued>128` 拍不触发、结果与参考一致 |
| 6 | 队列满边界 | 用缩水配置 `IQ_INT_DEPTH=4/IQ_MEM_DEPTH=2/IQ_FP_DEPTH=2` 重跑同一用例：`rn_ready` 正确反压、无表项覆盖（断言"写使能且 `valid && !issued`"为错）、结果仍正确 |
| 7 | 清空边界 | 定向+随机触发：误预测当拍有写回、连续两拍清空、清空与提交同拍、`flush_all` 与 `flush_valid` 同拍；判据：清空后 `free_vec` 等于参考模型期望值（已提交态 + 保留在途项）、不出现重复 `pd` |
| 8 | checkpoint 边界 | 4 个 checkpoint 占满后误预测 → 走反走：`ckpt_alloc_ok=0` 时 `rn_ready=0`、反走收敛后 `tail` 与参考一致、`ckpt_stuck` 断言不触发 |
| 9 | 锁步比对 | `scripts/regress.sh` 跑顺序核 vs 乱序核同一 ELF，`rtl_trace.log` 与 Spike `--log-commits` **逐条完全一致**（PC/rd/数据/异常事件），首个不一致点即 bug 定位点 |
| 10 | 综合时序 | Vivado 100 MHz 下 `WNS ≥ 0`；不满足按 `../01-pipeline.md` §7 的 1→2→3 顺序降级（第 3 步双发射须先经用户批准） |

---

## 9. 与 00/02/03 的偏差与待确认项（以 00/02/03 为准）

| # | 现象 | 本文件处理 |
|---|---|---|
| C1 | `03` §3 含 `age[4:0]`，同表又说"可省略 `age`，由 `rob_idx` 判断"，而 `../05-ooo.md` §4 又提"老化计数/age matrix"；且 `../05-ooo.md` §3 写 `rd_old`、`03` §4 写 `pd_old` | **省略 `age`**，统一用 `rob_idx` 环形年龄（§4.4），字段名一律 **`pd_old`**；若启用 `age` 只影响 IQ 表项宽度与选择器输入 |
| C2 | `03` §2.2 `uop_rn_t.lsq_idx` 为 5 bit，而 load/store 队列各 32 项 | 采用 **load/store 各独立 5 bit 索引空间**，由 `is_store` 决定落到哪张表；若改统一 64 项 LSQ 需 6 bit，必须同步改 `03` |
| C3 | `rob_entry_t.payload` 的 `ckpt_idx` 仅 2 bit，无法区分槽号与分支实例 | 命中判定加 `ckpt_rob_idx[i]==redirect_rob_idx` 双重校验（§6.2），**不改位域** |
| C4 | `02` §2 有 FMA（`fp_op` 19~22），但 `uop_id_t`/`uop_rn_t` 未定义第三源 `rs3` | 约定 rs3 = `instr[31:27]`，在 ID 级随 uop 流动；建议 `02`/`03` 补一句明确 |
| C5 | `../05-ooo.md` §6 写"replay 清空更年轻者（load 存活）"，`06-lsu-mem.md` §1.4#7/§3.6 取 `flush_rob_idx = load.rob_idx - 7'd1`（**load 自身也作废重取**，因为 LSQ 不保存 `next_pc`） | 本文件按 **`06` 的语义**执行（§6.3），硬件两种方案都支持：改成"load 存活"只需把 `flush_rob_idx` 换成 `load.rob_idx` 并保留其 `pd`；建议 `../05-ooo.md` §6 下一版同步 |
| C6 | `01-pipeline.md` §2.4 要求"PRF 写冲突按优先级仲裁并插入 1 周期"；`03` §2.4 的 6 个写回口未含"分支解析/store 就绪"字段 | 写冲突改为"压制重试（`wb_stall_hold`）+ 唤醒照常广播"（§5.1，不插气泡；若评审坚持照 01 则退回插拍）；写口 0 新增 `wb_br_resolved/actual_taken/actual_target`、口 3 新增 `wb_st_ready`（§3.1），建议 `03` 下一版补记 |

---

## 10. RTL 落地顺序

`rtl/pkg/rv32gc_defs.vh`（`uop_ctrl_t` 位域宏、`rob_entry_t`/`iq_entry_t` 位段宏、`is_younger`）→ `rtl/rename/freelist.v`→`rat.v`→`checkpoint.v`→`rename_top.v`→`rob.v`（§2.5/§2.7/§3.4）→ `rtl/issue/iq_int.v`/`iq_mem.v`/`iq_fp.v`→`wakeup_select.v`→`prf.v`/`bypass.v` → `rtl/mem/lsq.v`（`03` §5）+ `rtl/exec/*` → 单元测试 → 乱序集成 → 锁步回归（`../08-verification.md` §2.4）。
