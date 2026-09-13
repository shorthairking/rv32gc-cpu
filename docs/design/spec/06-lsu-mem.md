# SPEC-06 访存子系统（LSU / LSQ / D-Cache / L2 / 预取 / 原子指令 / Cache 维护）

> 上游：`00-conventions.md`、`02-uop-and-decode.md`、`03-pipeline-regs.md`（**§2.6 MMU、§2.8 LSU↔Cache/AXI、§5 LSQ 表项严格照用**）、`../03-cache.md`、`../05-ooo.md`、`../04-csr-mmu.md`、`../06-bus-axi.md`、`../kb/03-nand-controller.md`（DMA 无一致性）、`../porting/03-drivers.md`（Zicbom）。与 00/02/03 冲突时**以 00/02/03 为准**（差异见 §1.4）。
> 模块：`rtl/exec/agu.v`、`rtl/mem/{lsu,lsq,dcache,store_buffer,stld_predictor,mshr}.v`、`rtl/bus/{l2_cache,uncached_unit}.v`。

## 1. 访存通路总体

### 1.1 数据流

```
IQ_MEM(24) ─► IS ─► agu.v（VA = rs1 + imm、对齐检查）─► lsu.v ─► mem_bundle_t（03 §1）
   ┌───────────────┬────────────────┬────────────────────┐
   ▼               ▼                ▼                    ▼
lsq.v(LDQ32/STQ32) dcache.v(L1D) uncached_unit.v      DTLB64/PMP16/PTW
stld_pred 1024     8MSHR+SB16+VB4 (设备窗/CLINT/PLIC)  (03 §2.6 / 04 §5)
   │               └─ victim 写回 / refill / PTW / cbo ─┐
   ▼  replay 违例清空（与分支误预测共用清空硬件）        ▼
      l2_cache.v（256KB 8way 32B PIPT、4 源仲裁、next-line 预取）─► axi_master.v
                                    （AXI4，ID 0/1/2/3，行 = 8 beat @32bit）
```

### 1.2 容量与关键参数（与 00 §5、`../03-cache.md` §1 一致）

| 结构 | 规格 | 结构 | 规格 |
|---|---|---|---|
| LDQ / STQ | 32 / 32（`LSQ_LD_DEPTH`/`LSQ_ST_DEPTH`） | L1D | 32 KB、8 路、32 B 行、128 组、VIPT、写回写分配 |
| Store Buffer / Victim Buffer | 16 项 / 4 项 | L1D MSHR | 8 项，乱序返回按 id+地址回填 |
| Store-Set 预测器 | SSIT 1024 项 + LFST 64 项 | 保留集 | 1 项，32 B 行粒度 |
| L2 | 256 KB、8 路、32 B 行、1024 组、PIPT | L2 缓冲 | Refill 4 项 + Victim 4 项 |
| L1D 访问口 | 每周期 1 个：load > store 排空 > PTW > cbo | 预取 | next-line，未完成 ≤ 1 |

### 1.3 延迟表（CPU 周期，从 IS 选中该 uop 算起；AXI 侧 33 MHz）

| 场景 | 延迟 | 组成 |
|---|---|---|
| load 命中、自然对齐、单拍 | **3** | EX(AGU)=1 → MEM(读 Tag/Data+way/字选+对齐)=1 → WB=1 |
| load 命中、非对齐跨字（同行）/ 跨行且第二行命中 | 4 / 4~5 | 第二次 Cache 访问 +1（第二行缺失则按缺失计） |
| load 缺失 → L2 命中 / → L2 缺失 → DDR | **≈17** / 60~100 | 3 + MSHR 分配 1 + L2 12~16 + 回填 1~2；后者再加 AXI 8 beat（≥240 ns）+ DDR |
| 非缓存单拍读 / 非缓存写 | 8~20 / 3（发完即走） | 不走 Cache；写由强序队列排空，`fence` 等待完成 |
| AMO 命中 / 缺失 | 5~6 / 缺失 +2 | 读 Cache → AMO ALU → 新值入 STQ，**提交时**写 Cache |
| store 提交 → L1D 命中写入 / 行缺失写分配 | 1~2 / 18~24 | T 拍入 Store Buffer，T+1 发请求；缺失走 MSHR 字节合并 |
| `cbo.clean/flush` / 非对齐拆分代价 | ≥ DDR 写延迟 / +1 每额外拍 | 维护指令必须穿透到内存（§6.4）；拆分每条最多 2 行 3 拍（§2.4） |

### 1.4 与 00/02/03 的差异记录（均已按"以 00/02/03 为准"处理）

| # | 冲突点 | 处理 |
|---|---|---|
| 1 | `../03-cache.md` §4 写"L2 3 源"，`03-pipeline-regs.md` §2.8 写 4 源 | **取 4 源**：L1I refill / L1D refill / L1D 写回 / 非缓存+维护 |
| 2 | `02` §2 `mem_size[1:0]`（≤WORD）无法编码 FLD/FSD 的 8 B；`02` §4.6 列了 RV32 不存在的 `C.LD/C.SD→LD/SD` | LSU 派生 `size[2:0]`（0=B1=H2=W3=D），与 `03` §4/§5.1 的 3 bit `mem_size/size` 一致；8 B 仅由 `mem_fp=1` 产生（FLD/FSD，含 C.FLD/C.FSD 展开） |
| 3 | `03` §2.8 的 `l2_resp_*` 无返回标识、且无 L1D↔PTW 端口 | 补 `l2_rsp_src[1:0]+l2_rsp_id[1:0]`（§5.2，等价 `06` §2.2"按 RID 匹配"）与 PTW 端口（§4.2）；PTE 读走 L1D、**不**新增 L2 源（与 `04` §5.2"A/D 写回经 D-Cache 保证原子性"一致） |
| 4 | `03` §2.8 `dc_req_amo[5:0]`（op+aq+rl）与 `amo_op[4:0]` 位宽不符 | `dc_req_amo[5:0] = {amo_op[4:1], amo_aq, amo_rl}`：9 种已实现 AMO 的 funct5 最低位恒 0 |
| 5 | `05` §6"replay 清空更年轻者（load 存活）" | replay 取 `redirect_rob_idx = load.rob_idx - 1` ⇒ 该 load 自身也作废并重新取指（§3.6），否则 LSQ 需额外保存 `next_pc` |
| 6 | `04` §2.1 写"未实现的性能计数器读 0" | 建议把 §8.1 的 `perf_cnt_*` 映射到 `mhpmcounter3..31`（需 CSR 侧配合，列为待办） |

## 2. AGU 与 LSU

### 2.1 `agu.v`（`rtl/exec/agu.v`，EX 级）

```verilog
module agu(
  input  wire clk, rst_n, agu_valid;   input wire [31:0] agu_rs1, agu_imm; // 基址（op_a 旁路后）/ 立即数
  input  wire [1:0] agu_size;                                              // 0=B 1=H 2=W 3=D
  output wire [31:0] agu_va;                                               // rs1+imm，32 bit 回绕
  output wire agu_misaligned,          // (va & (size-1)) != 0
              agu_cross_word,          // va[1:0] + nbyte > 4
              agu_cross_line);         // va[4:0] + nbyte > 32
```

### 2.2 `lsu.v`（`rtl/mem/lsu.v`）

> 跨模块总线一律**扁平 packed 向量**（Verilog-2001 无非打包数组端口）；每槽切片 `[W*i +: W]`，`i=0..CORE_WIDTH-1`。

```verilog
module lsu(
  input  wire clk, rst_n,
  // ---- 来自 AGU/MEM 级的访存 uop（每拍 ≤`CORE_WIDTH` 条；03 §1 mem_bundle_t）----
  input  wire [`CORE_WIDTH-1:0]    mem_valid, mem_cbo_valid, mem_excp_valid;
  input  wire [`CORE_WIDTH*7-1:0]  mem_pd, mem_rob_idx;                  // [7*i +: 7]
  input  wire [`CORE_WIDTH*5-1:0]  mem_lsq_idx, mem_amo_op;              // [5*i +: 5]（03 §2.2）
  input  wire [`CORE_WIDTH*32-1:0] mem_va, mem_store_data, mem_excp_tval; // [32*i +: 32]
  input  wire [`CORE_WIDTH*64-1:0] mem_fp_data;                          // FP store（fp_op_b[63:0]）
  input  wire [`CORE_WIDTH*3-1:0]  mem_op;                               // 1=LOAD 2=STORE 3=LR 4=SC 5=AMO
  input  wire [`CORE_WIDTH*2-1:0]  mem_size, mem_flags, mem_amo_flags, mem_cbo_op;
  input  wire [`CORE_WIDTH*4-1:0]  mem_excp_cause;                       // [4*i +: 4]
  input  wire [1:0]                mem_priv, mem_cbo_en;                 // 特权级 / {CBCFE|CBZE, CBIE!=00}
  input  wire                      mem_pmp_pass;                         // PMP 组合结果（04 §5.3）
  // ---- LSQ 分配（RN 索引 + 满标志回压，00 §3 lsq_full）----
  output wire [5:0]                lsq_free_cnt_ld, lsq_free_cnt_st;     // 0..32
  input  wire [`CORE_WIDTH-1:0]    lsq_alloc_en, lsq_alloc_is_st;        // 1=STQ（STORE/SC/AMO）
  input  wire [`CORE_WIDTH*5-1:0]  lsq_alloc_idx;                        // [5*i +: 5]
  // ---- DTLB（03 §2.6，字段名严格一致）----
  output wire mmu_req_valid, mmu_req_is_fp;      output wire [31:0] mmu_req_va;
  output wire [8:0] mmu_req_asid;                output wire [1:0] mmu_req_priv, mmu_req_type;
  input  wire mmu_resp_valid, mmu_resp_fault, mmu_busy;   // type：1=load 2=store 3=AMO
  input  wire [31:0] mmu_resp_pa, mmu_resp_tval; input wire [3:0] mmu_resp_cause;  // 12/13/15
  output wire sfence_valid, sfence_all;          output wire [31:0] sfence_va;
  output wire [8:0] sfence_asid;
  // ---- D-Cache 请求/响应（03 §2.8）----
  output wire dc_req_valid, dc_req_we;           output wire [31:0] dc_req_addr, dc_req_wdata;
  output wire [3:0] dc_req_wstrb;                output wire [1:0] dc_req_size, dc_req_lrsc, dc_req_cbo;
  output wire [5:0] dc_req_amo;                  // {amo_op[4:1],amo_aq,amo_rl}；lrsc：1=LR 2=SC 3=AMO
  input  wire dc_req_rdy, dc_resp_valid, dc_resp_miss, dc_resp_fault, dc_sc_fail;
  input  wire [31:0] dc_resp_rdata;              input wire [2:0] dc_resp_mshr_idx;
  input  wire [3:0] dc_resp_cause;
  // ---- 非缓存/设备通道（uncached_unit.v；CLINT/PLIC 核内截获）----
  output wire uc_req_valid, uc_req_we;           output wire [31:0] uc_req_addr, uc_req_wdata;
  output wire [3:0] uc_req_wstrb;                input  wire uc_req_rdy, uc_resp_valid, uc_resp_fault;
  input  wire [31:0] uc_resp_rdata;
  // ---- 写回（MEM→WB，03 §1）----
  output wire [`CORE_WIDTH-1:0]    wb_valid, wb_excp_valid;
  output wire [`CORE_WIDTH*7-1:0]  wb_pd, wb_rob_idx;
  output wire [`CORE_WIDTH*32-1:0] wb_result, wb_excp_tval;   // load 数据 / AMO 旧值 / SC 结果
  output wire [`CORE_WIDTH*3-1:0]  wb_sel;       output wire [`CORE_WIDTH*4-1:0] wb_excp_cause;
  // ---- 提交/清空/重放（00 §3，与 BRU 共用清空硬件；perf_cnt_* 见 §8.1）----
  input  wire rt_commit_valid, rt_commit_is_store, rt_commit_is_amo, rt_commit_is_lr,
              rt_commit_is_cbo, trap_valid, flush_valid, flush_all;
  input  wire [6:0] rt_commit_rob_idx, flush_rob_idx;
  output wire redirect_valid;                    output wire [31:0] redirect_pc;
  output wire [6:0] redirect_rob_idx;
  output wire [63:0] perf_cnt_dcache_access, perf_cnt_dcache_miss, perf_cnt_mshr_full, perf_cnt_stb_full,
                     perf_cnt_fwd_hit, perf_cnt_fwd_partial, perf_cnt_replay, perf_cnt_split,
                     perf_cnt_amo, perf_cnt_lr, perf_cnt_sc_fail, perf_cnt_uncached, perf_cnt_cbo
);
```

### 2.3 地址生成与对齐检查

`va = rs1 + imm`（32 bit 回绕）；`size[2:0]` 由 LSU 派生：`mem_fp && mem_size==W → 3'd3(D)`，其余 `{1'b0, mem_size}`。`align_fault = |(va & (size-1))`，**是否上报见 §2.7**（默认硬件拆分支持非对齐，不上报 4/6）。一条访存只发一次 `mmu_req`；拆分中第二半**跨页**时对第二半 VA 再发一次（`type` 不变）。

### 2.4 非对齐访问拆分规则

每拍最多搬 4 B 且必须落在同一 32 B 行内。记 `o=va[1:0]`、`n=size`：

```
beats = 0; rem = n; p = va;
while (rem > 0) begin
   nb = min(4 - p[1:0], min(32 - p[4:0], rem));   // 行边界处自动断拍
   beats++; p += nb; rem -= nb;
end
```

| size | 不跨行拍数 | 跨 32 B 行 | 说明 |
|---|---|---|---|
| 1 B | 1 | 不可能 | `wstrb = 4'b0001 << o` |
| 2 B | 1（`o≤2`）；`o=3` 时 2 | 仅 `va[4:0]=31 && o=3` → 2 行 | 半字跨界 |
| 4 B | 1（`o=0`）；`o≠0` 时 2 | `va[4:0]>28` → 2 行 | 字跨界 |
| 8 B（FLD/FSD） | `o=0`→2；`o≠0`→3 | `va[4:0]≥25` → 2 行（各行 1~2 拍） | 与 `../03-cache.md` §3"拆两次"一致（该文只讨论 ≤4 B） |

永远**先低地址半部分、再高地址半部分**；第一半数据暂存 `ld_beat0_q[31:0]`，第二半到达后拼成 ≤64 bit 再写回（对上层表现为该指令推迟 1~2 周期写回）。第二半落入另一行且缺失时再走一次 MSHR；拍数计入 `perf_cnt_split`。

### 2.5 访问宽度与字节使能

```
o = p[1:0]; nb = min(4-o, rem);          // store 每拍（数据源 swd[63:0]）
wstrb = (((1<<nb)-1) << o);              // 行内第二次访问时 swd 已右移
wdata = swd[31:0] << (8*o);   swd >>= (8*nb);  p += nb;  rem -= nb;
```

| store | `o` | 拍1 `wstrb` | 拍2 `wstrb` | 数据 |
|---|---|---|---|---|
| SB / SH / SW | 任意 | 按公式（SB `1<<o`、SH `3<<o`、SW `4'hF<<o` 截断） | 越字时用剩余字节低位掩码 | 拍2 用 `swd>>(32-8o)` |
| SH `o=3` / SW `o=0` | 3 / 0 | `4'h8` / `4'hF` | `4'h1` / — | 拍2 用 `swd>>8` |
| SD `o=0` / `o≠0` | 0 / 1~3 | `4'hF` / 按公式 | `4'hF` / 按公式 | `swd`、`swd>>32`（`o≠0` 共 3 拍） |

**load 对齐器**：`data = {beatN, …, beat1, beat0} >> (8*o)`（N=1：≤4 B 访问；N=2：8 B 且 `o≠0`），再按 `size`/`unsigned` 符号或零扩展（`size=3` 不扩展）。第二拍复用同行命中路径，不重复分配 MSHR。

### 2.6 浮点访存（FLW/FLD/FSW/FSD）

FP store 数据取 `ex_bundle.fp_op_b[63:0]`（`mem_fp_data`）：FSW 用 `[31:0]`、FSD 用 `[63:0]`，整数 `store_data` 不参与。**FLW**（`size=W,is_fp=1`）得到 32 bit 后写 FP PRF 时**必须 NaN boxing** `{32'hFFFF_FFFF, word}`（不改 `fflags`）；**FLD**（`size=D`）64 bit 原样写入、不 boxing；**FSW** 忽略高 32 bit（store 不检查 boxing）；**FSD** 拆 2~3 拍（§2.4），转发/写回按 8 B。`mmu_req_is_fp=1` 仅用于归因/调试，页错误 cause 仍为 13/15；`mstatus.FS` 在 ID 级检查（02 §6）。

### 2.7 访存异常判定与 `tval`

| cause | 触发条件（本设计） | `tval` | 优先级 |
|---|---|---|---|
| 4 / 6 地址非对齐 | ① LR/SC/AMO 非自然对齐（规范不允许模拟）；② 定义 `` `MISALIGNED_TRAP `` 时任意非自然对齐 load/store（bring-up/arch-test）；③ 非对齐跨两页且两页属性不同 | 原始 VA（③ 取最先出错半部分 VA） | **最低**：仅当无更高优先级异常时上报（规范 "If not higher priority"） |
| 5 / 7 访问错误 | ① PMP 失败（翻译后立即判定，精确）；② 物理地址落在未实现窗口；③ 非缓存/AXI `resp != 2'b00` | 出错 VA | 中 |
| 13 / 15 页错误 | DTLB/PTW 翻译失败（V=0、权限、非法 PTE） | 出错 VA；拆分越页时是**出错半部分的 VA（可高于原 VA）** | 高 |

选择逻辑：`mmu_resp_fault ? {13,15} : (pmp_fail|fault ? {5,7} : (align_fault ? {4,6} : 0))`，两半部分按**低半部分优先**（first encountered）。`fault_va` 存入 LSQ 表项，ROB 异常 payload 的 `excp_tval` 取 LSQ 的 `fault_va`（03 §4）。store/AMO 的翻译与 PMP 在发射期完成 ⇒ 4/5/6/7/13/15 **全部在提交点精确上报**；仅"已提交后的 AXI 写响应错误"非精确（06 §2.1 总线错误路径记账）。`cbo.zero` 允许 `rs1` 非块对齐（Zicboz 明确不要求）。

## 3. LSQ（`rtl/mem/lsq.v`）

### 3.1 端口（要点）

```verilog
module lsq(
  input  wire clk, rst_n, rt_commit_valid, fwd_ld_valid, ss_query_valid, ss_is_store,
             ss_train_valid, flush_valid, flush_all, mshr_refill_valid;
  input  wire [`CORE_WIDTH-1:0] alloc_en, alloc_is_st, wr_en;   // RN 分配 + MEM 级写字段
  input  wire [`CORE_WIDTH*5-1:0] alloc_idx;                    // [5*i +: 5]
  input  wire [6:0] rt_commit_rob_idx, flush_rob_idx;
  input  wire [4:0] fwd_ld_idx, ss_train_stq_idx;
  input  wire [31:0] ss_pc, ss_train_pc;
  input  wire [2:0] mshr_refill_idx;   input wire [26:0] mshr_refill_tag;
  output wire [5:0] free_cnt_ld, free_cnt_st, ss_id;
  output wire [4:0] replay_ld_idx, ld_oldest_idx, st_oldest_idx;
  output wire [2:0] st_state_of_oldest;
  output wire [7:0] fwd_strb;   output wire [63:0] fwd_data;
  output wire [31:0] ld_issue_mask;                     // 可发射 load（已滤掉预测冲突等待）
  output wire fwd_hit, fwd_conflict, replay_valid, ss_hit);
```

### 3.2 表项位域（扩展 `03` §5，两队列基本对称）

| 字段 | 宽 | LDQ | STQ | 说明 |
|---|---|---|---|---|
| `valid` / `rob_idx` / `pc` | 1+7+32 | ✓ | ✓ | 清空年龄比较、replay 重定向、预测器索引 |
| `pd` | 7 | ✓ | — | load/AMO 写回目标 |
| `vaddr` / `paddr` / `addr_valid` | 32+32+1 | ✓ | ✓ | 转发/违例比较用物理地址；`vaddr` 供异常 tval |
| `data` | 32（STQ 64） | ✓ | ✓ | load：拍数据暂存；store：`swd[63:0]` |
| `size` / `is_fp` / `unsigned` | 3+1+1 | ✓ | ✓ | 0=B1=H2=W3=D；FLW 的 NaN boxing；load 扩展方式 |
| `mem_op` | 3 | ✓ | ✓ | LDQ：1/3；STQ：2/4/5 |
| `amo_op` / `amo_aq` / `amo_rl` / `cbo_op` | 5+1+1+2 | — | ✓ | AMO 功能与内存序（§6.2/§6.3）、cbo 命令 |
| `state` | 3 | WAIT_ADDR/WAIT_TRANS/ISSUED/MSHR_WAIT/WB/REPLAY | WAIT_ADDR/WAIT_DATA/READY/COMMITTED | `03` §5.2/§5.3 |
| `issued` / `done` / `committed` | 1+1+1 | ✓ | ✓ | 已发 Cache / 可写回 / 已提交 |
| `fault_valid` / `fault_cause` / `fault_va` | 1+4+32 | ✓ | ✓ | 精确异常，`tval = fault_va` |
| `mshr_idx` / `mshr_valid` / `uncached` | 3+1+1 | ✓ | ✓ | 缺失挂起关联（§3.7）/ 窗口解码 |
| `beat_cnt` / `beat0_data` | 2+32 | ✓ | ✓ | 拆分进度与第一拍数据 |
| `fwd_hit` / `fwd_strb` / `replay` | 1+8+1 | ✓ | — | 转发命中掩码 / 违例置位 |
| `ss_id` / `ss_wait` / `ss_wait_valid`（LDQ）；`ss_id` / `stq_prev_same_set`（STQ） | 6+5+1；6+5 | ✓ | ✓ | store-set 预测器与同 set 链表（§3.5） |

### 3.3 分配与释放

RN 分配索引（`lsq_idx[4:0]`：LOAD/LR→LDQ，STORE/SC/AMO→STQ）；MEM 级写入地址/数据；`free_cnt_*` 回压 RN（`lsq_full`）。LDQ 在 `done` 且已提交后释放；STQ 在 `COMMITTED` 且被 Store Buffer 接收后释放。清空时对 `is_younger(entry.rob_idx, flush_rob_idx)` 的表项置无效（**严格更年轻，绝不误清更老表项**），`flush_all` 全清 + 清保留集。

### 3.4 store→load 转发（精确算法）

对所有更老的 `addr_valid` store（STQ 项 + **Store Buffer 项**，后者恒老于所有在飞 load）并行判定；遍历顺序**从最年轻到最老**，保证新 store 字节优先。

```
fwd_hit=0; fwd_data=0; fwd_strb=0; conflict=0; wait_ss=0;
for (each st in order: youngest → oldest) begin
   if (!st.valid || !is_older(st.rob_idx, ld.rob_idx)) continue;   // 只比较更老 store（00 §3 环形年龄）
   if (!st.addr_valid) begin
      if (ss_predict_conflict(ld.pc, st)) wait_ss = 1;             // 预测冲突 → 等待（§3.5）
      else conflict = 1;                                           // 预测无冲突 → 允许先行
      continue;
   end
   for (b = 0; b < ld.size; b++) begin                             // 按字节比较
      ba = ld.paddr + b;
      if (!fwd_strb[b] && ba >= st.paddr && ba < st.paddr + st.size) begin
         fwd_data[8*b +: 8] = st.swd[8*(ba - st.paddr) +: 8];
         fwd_strb[b] = 1'b1;                                       // 已被更新的 store 填充
      end
   end
end
fwd_hit = |fwd_strb;
ld_data = (expand(fwd_strb) & fwd_data) | (~expand(fwd_strb) & cache_rdata);
```

- **部分重叠**：4 B load 可同时由 2~3 个更老 store 提供，剩余字节取 Cache（`perf_cnt_fwd_partial`）。
- **跨行 load**：转发按整条 load 的字节范围一次判定，两拍 Cache 数据返回后统一按 `fwd_strb` 合并（第一拍存 `beat0_data`）。
- **浮点**：FLW 转发 32 bit 后 NaN boxing；FLD 合并 8 B，`fwd_strb[7:0]` 全用；**AMO 的读旧值**同样走本转发，得到"含更老未落盘 store 字节"的最新值后再 RMW（§6.2）。

### 3.5 store-set 预测器（`rtl/mem/stld_predictor.v`，1024 项）

| 结构 | 位域 | 索引 |
|---|---|---|
| `ssit[1024]` | `{tag[5:0], valid, ss_id[5:0], conf[1:0]}` | `idx = pc[11:2]`、`tag = pc[17:12]`（防别名） |
| `lfst[64]` | `{valid, sq_ptr[4:0]}`：该 set 中最年轻 store 的 STQ 索引 | `ss_id[5:0]` |
| STQ 附加 | `ss_id[5:0]`、`stq_prev_same_set[4:0]`（同 set 链表） | — |

- **查询（分配时）**：store 查 SSIT，命中用其 `ss_id` 并更新 LFST/链表，未命中分配新 `ss_id`（6 bit 轮转）；load 查 SSIT，命中则 `ss_wait ← LFST[ss_id].sq_ptr, ss_wait_valid ← 1`（预测冲突），未命中 → 预测无冲突。
- **等待展开**：`ss_wait_valid && !STQ[ss_wait].addr_valid` → 该 load 不上报"可发射"（在 LSQ 内等待，**不占 IQ**）；被指向 store 地址就绪后 `ss_wait ← STQ[ss_wait].stq_prev_same_set`，直到 `ss_wait_valid=0`。
- **训练时机**：① 违例 replay → `SSIT[pc_ld] ← {tag, 冲突 store 的 ss_id, conf=2'b11}`，该 store 若无 `ss_id` 同时分配并写 `SSIT[pc_st]`；② 预测冲突且确实发生转发 → `conf--`，`conf==0` 置 `valid=0`；③ 清空广播不清预测器（性能结构），命中的 `ss_id` 用 `valid`/`addr_valid` 过滤。面积 ≈ 16 Kb LUTRAM，符合 05 §8 的 BPU 余量。

### 3.6 违例检测与 replay

**不变式**：提交顺序进行，store 的 `addr_valid=0` 时其 ROB 条目不 `done` → ROB 头阻塞 ⇒ **该 store 提交前任何更年轻 load 都不可能提交**，违例只可能在飞 load 上发生、不会逃逸。

```verilog
// 组合检测：地址刚变有效的更老 store 与"已发射未写回"的 load 重叠
for (l=0;l<32;l++) if (LDQ[l].valid && LDQ[l].issued && !LDQ[l].done)
  for (s=0;s<32;s++) if (STQ[s].valid && STQ[s].addr_valid && STQ[s].addr_valid_new
      && is_older(STQ[s].rob_idx, LDQ[l].rob_idx)
      && byte_overlap(STQ[s].paddr,STQ[s].size,LDQ[l].paddr,LDQ[l].size))
    LDQ[l].replay = 1'b1;

// 重放：选最老的 replay load，走与分支误预测完全相同的清空/重定向总线
if (replay_valid && !bru_redirect_valid && !trap_valid) begin      // BRU/trap 优先
  redirect_valid = 1'b1;  redirect_pc = LDQ[replay_ld_idx].pc;
  redirect_rob_idx = LDQ[replay_ld_idx].rob_idx - 7'd1;            // 该 load 及其后全部
end
```

- **清空范围**：`load.rob_idx - 1`（7 bit 环形）→ 该 load 及所有更年轻 uop 作废并重新取指（§1.4#5）；更老表项不受影响。
- **与分支误预测共用硬件**：同一条 `redirect_valid/redirect_pc/redirect_rob_idx` 总线、同一套 checkpoint/freelist 恢复、同一条前端重定向路径（00 §3、05 §7）；LSU 额外清自己的 LSQ 条目与 `replay` 标志，并保守清保留集。
- 已转发命中后才发现的更老 store 重叠（部分重叠转发错误）走同一路径 ⇒ **转发正确性由 replay 兜底**；代价约 10~15 周期（05 §6），计入 `perf_cnt_replay`。

### 3.7 load 缺失挂起与 MSHR 关联

`WAIT_ADDR → WAIT_TRANS(等 mmu_resp_valid) → ISSUED →（缺失）MSHR_WAIT(mshr_idx) → 回填重放 → WB`。缺失时 `dc_resp_miss=1` + `dc_resp_mshr_idx`，LDQ 记 `mshr_idx/mshr_valid`，**不重新占用 IQ**（05 §4）。回填时 D-Cache 发 `mshr_refill_valid+mshr_refill_idx`，LSQ 把匹配表项置回 `ISSUED`（下一拍必然命中），并用 `mshr_refill_tag` 与 `paddr[31:5]` 兜底比对。表项被清空时同步清 D-Cache 中对应 MSHR 的 `ld_wait` 位（防止唤醒已死表项）。

## 4. D-Cache（`rtl/mem/dcache.v`）

### 4.1 组织与位域

128 组 × 8 路 × 32 B = 32 KB，写回 + 写分配，单访问口。
**VIPT 别名证明**：索引用 `VA[11:5]`（7 bit），行内偏移 `VA[4:0]`；组数×行大小 = 128×32 B = 4 KB = 页大小 ⇒ `VA[11:5]` 全在页内偏移内，恒等于 `PA[11:5]` ⇒ 同一物理行不可能落到两个组，**无需 anti-alias**，Tag 比较与 TLB 并行。Tag 因此只需存 `PA[31:12]`（20 bit，`PA[11:5]` 由组索引隐含）。位域：`tag[19:0]`、`valid`、`dirty`、`plru[6:0]`（8 路树形伪 LRU：命中路径更新，替换时按树选择）。

### 4.2 端口（要点）

```verilog
module dcache(
  input  wire clk, rst_n, flush_all, flush_valid;   input wire [6:0] flush_rob_idx;
  // ---- LSU 访问口（03 §2.8，字段名一致）----
  input  wire dc_req_valid, dc_req_we, dc_req_cbo_valid;
  input  wire [31:0] dc_req_addr, dc_req_wdata;      input wire [3:0] dc_req_wstrb;
  input  wire [1:0] dc_req_size, dc_req_lrsc, dc_req_cbo;   input wire [5:0] dc_req_amo;
  output wire dc_req_rdy, dc_resp_valid, dc_resp_miss, dc_resp_fault, dc_sc_fail;
  output wire [31:0] dc_resp_rdata;   output wire [2:0] dc_resp_mshr_idx;
  output wire [3:0] dc_resp_cause;
  // ---- PTW 端口（PTE 读 / A/D 写回，§7.2）----
  input  wire ptw_req_valid, ptw_req_we;             input wire [31:0] ptw_req_addr, ptw_req_wdata;
  input  wire [3:0] ptw_req_wstrb;
  output wire ptw_req_rdy, ptw_resp_valid, ptw_resp_fault;
  output wire [31:0] ptw_resp_rdata;                 output wire [3:0] ptw_resp_cause;
  // ---- Store Buffer 排空口（store_buffer.v）----
  input  wire sb_req_valid;           input wire [31:0] sb_req_addr, sb_req_wdata;
  input  wire [3:0] sb_req_wstrb;     input wire [1:0] sb_req_size;   output wire sb_req_rdy;
  // ---- L2：refill 读 / victim 写回 / cbo 维护（03 §2.8 的 l2_req_*，4 源中的 1、2、3）----
  output wire l2_rd_valid, l2_wb_valid, l2_cbo_valid;
  output wire [31:0] l2_rd_addr, l2_wb_addr, l2_cbo_addr;
  output wire [1:0] l2_rd_id, l2_cbo_op;             output wire [255:0] l2_wb_data;
  input  wire l2_rd_rdy, l2_wb_rdy, l2_cbo_rdy, l2_rsp_valid, l2_rsp_err;
  input  wire [1:0] l2_rsp_src, l2_rsp_id;           input wire [255:0] l2_rsp_data;
  // ---- 状态/计数器 ----
  output wire mshr_full, sb_full;
  output wire [63:0] perf_cnt_hit, perf_cnt_miss, perf_cnt_mshr_full, perf_cnt_victim_full);
```

### 4.3 状态机（主 FSM 管访问口；REFILL/WRITEBACK 与 LOOKUP/HIT 重叠 ⇒ non-blocking）

| 状态 | 动作 | 转移 |
|---|---|---|
| `IDLE` | 端口空闲 | 有请求 → `LOOKUP` |
| `LOOKUP` | 读 Tag/Data 阵列（BRAM 输出下一拍） | 命中 → `HIT`；缺失且有空闲 MSHR → `MISS`；MSHR 满 → 停本态并拉低 `dc_req_rdy`（`mshr_full++`） |
| `HIT` | way/字选择 + 字节旋转；写命中置 `dirty`；LR/SC/AMO/CBO 特例；LRU 更新 | 拆分未完成 → 再 `LOOKUP`（第二拍）；否则 `IDLE` + `dc_resp_valid` |
| `MISS` | 伪 LRU 选 victim：脏 → 申请 VB（满则先 `WRITEBACK`）；向 L2 发 refill 读 | → `MSHR_ALLOC` |
| `MSHR_ALLOC` | 分配 MSHR（tag/set/way/等待位/字节合并缓冲），登记请求者 | → `REFILL`（等待）或 `IDLE`（释放端口继续服务命中） |
| `REFILL` | L2 返回整行：按 `wstrb[31:0]` 合并写数据阵列、置 valid/dirty、建 tag、`mshr_refill_valid` 唤醒等待者 | → `IDLE`（或 `ERROR`） |
| `WRITEBACK` | VB 队首 → L2 整行写（`l2_wb_*`），`l2_wb_rdy` 后释放 | → `IDLE` |
| `ERROR` | L2/AXI 错误（`l2_rsp_err`）：不分配该行，向等待者报 `dc_resp_fault`（load=5，store 记总线错误），作废 MSHR | → `IDLE` |

### 4.4 MSHR（8 项，`rtl/mem/mshr.v`）

| 字段 | 宽 | 说明 |
|---|---|---|
| `valid` / `state` | 1+3 | `IDLE/WAIT_L2/FILL/MERGE/DONE/ERROR` |
| `tag` / `set` / `way_alloc` / `victim_way` | 27+7+3+3 | `tag = PA[31:5]`：合并匹配键（"按地址回填"）；回填位置与受害者 |
| `wdata` / `wstrb` / `dirty` | 256+32+1 | **按字节**合并缓冲：写分配 store 字节、AMO 新值、cbo.zero 的 0；有合并 → 回填后置脏 |
| `ld_wait` / `st_wait` | 32+32 | 等待该行的 LDQ/STB 位向量（回填后唤醒） |
| `amo_valid` / `amo_op` / `aq` / `rl` / `issued` / `err` / `beat_cnt` | 1+4+1+1+1+1+3 | AMO 缺失的 RMW 上下文 / 已发 L2 / 错误 / 已收 beat |

**合并规则**：① 请求 `PA[31:5]` 与 8 个 MSHR 的 `tag` 全并行比较，命中即挂到该 MSHR（不产生第二次 L2 事务）；② **同拍多请求**：LSU 与 Store Buffer/PTW/cbo 同拍竞争端口，仲裁器只授权一个；若被挂起的请求与已授权请求**同行**，两者进入同一 MSHR（`ld_wait`/`st_wait` 同时置位、store 字节进 `wstrb`），不同行则下一拍再发；③ **乱序返回**：按 `l2_rsp_id`（MSHR 索引）精确回填，另用 `tag` 兜底校验，**不假设返回顺序**；④ 同一行多个 store 按字节后者覆盖前者。

### 4.5 Store Buffer（16 项，`rtl/mem/store_buffer.v`）与"提交后写 Cache"

字段：`valid`、`paddr[31:0]`、`swd[63:0]`（SD/FSD 用满）、`size[2:0]`、`is_fp`、`uncached`、`rob_idx[6:0]`、`beat_cnt[1:0]`、`beat0_done`、`fault/cause`（非精确访问错误记账）。
时序：提交拍 T 入队（FF 写入）→ T+1 排空引擎按 §2.4/§2.5 生成拍并请求 L1D（load 请求优先，另有每 4 周期一次的 store 排空令牌防饿死）→ 命中在下一拍写入数据阵列并置 `dirty`；缺失则合并进 MSHR。**同一窗口内访问同一地址的 load 从 Store Buffer 转发**（§3.4），因此 Cache 暂时落后于已提交 store 不影响正确性；提交前任何情况下该 store 数据在 Cache 中不可见（精确异常）。

### 4.6 Victim Buffer 与非阻塞条件

VB 4 项暂存被替换脏行（`{paddr[31:5], data[255:0]}`）后台写 L2，避免 refill 被写回阻塞；VB 满时新 miss 先 `WRITEBACK` 排空一项。**非阻塞条件**：端口空闲 且 命中 ⇒ 无论是否有 MSHR pending 都继续服务命中；新 miss 还需 ① 有空闲 MSHR（否则停 `LOOKUP` 并回压 LSU）、② VB 有空位或可立即排空。REFILL/WRITEBACK 不占访问口（各自独立的数据阵列时序）。LR/SC/AMO 期间锁定该组一拍，锁定期内同组其他请求延后（§6.1/§6.2 的原子性来源）。

## 5. L2 Cache（`rtl/bus/l2_cache.v`）

### 5.1 组织与物理地址位段（PIPT，无别名）

| 位段 | 用途 |
|---|---|
| `PA[4:0]` / `PA[13:5]` / `PA[31:14]` | 行内偏移（32 B）/ **组索引（9 bit → 1024 组）** / Tag（18 bit） |
| refill 突发 | 基址 `{PA[31:5], 3'b000}`；beat `k` = `{PA[31:5], k[2:0]}`（`arsize=3'b010`、`arlen=4'd7`、INCR） |
| next-line 预取 | `PA[31:5]+1`（跨 4 KB 页放弃，§5.5） |

256 KB = 1024 组 × 8 路 × 32 B；写回 + 写分配；**非包含**（non-inclusive）；Tag 位域 `tag[17:0] + valid + dirty + plru[6:0]`。

### 5.2 端口（4 源仲裁；`03` §2.8 的 `l2_req_*` 展开）

```verilog
module l2_cache(
  input  wire clk, rst_n, flush_all;
  // 4 个请求源：0=L1I refill 1=L1D refill 2=L1D 写回 3=非缓存/维护
  input  wire [3:0] l2_req_valid, l2_req_we;     // 每源 1 位（源 0/1 的 we 恒 0）
  output wire [3:0] l2_req_rdy;                  // 同拍授权（独热）
  input  wire [127:0] l2_req_addr, l2_req_wdata32;   // [32*i +: 32]；后者仅源 3
  input  wire [255:0] l2_req_wdata;                  // 源 2：整行 32 B
  input  wire [15:0] l2_req_wstrb;                   // [4*i +: 4] 源 3
  input  wire [7:0] l2_req_cbo, l2_req_id;           // [2*i +: 2]：cbo_op / 源内未完成号（每源 ≤4）
  output wire l2_rsp_valid, l2_rsp_err;              // 每拍最多一个响应：整行或单拍
  output wire [1:0] l2_rsp_src, l2_rsp_id;
  output wire [255:0] l2_rsp_data;   output wire [31:0] l2_rsp_rdata;  // 源 0/1 / 源 3
  // ---- AXI4 主设备（**端口集合/位宽的权威定义见 `08-bus-axi.md` §1**：另含 `wid`、`arlock/awlock`、
  //      `arprot/awprot` 等，由 `bus/axi_master.v` 补齐；本节只列 L2 直接驱动的核心信号）----
  output wire [3:0] arid, awid, arlen, awlen, wstrb, arcache, awcache;
  output wire [31:0] araddr, awaddr, wdata;      output wire [2:0] arsize, awsize;
  output wire [1:0] arburst, awburst;
  output wire arvalid, awvalid, wvalid, wlast, rready, bready;
  input  wire arready, awready, wready, rvalid, bvalid, rlast;
  input  wire [3:0] rid, bid;                    input wire [31:0] rdata;
  input  wire [1:0] rresp, bresp;
  output wire [63:0] perf_cnt_access, perf_cnt_hit, perf_cnt_miss, perf_cnt_prefetch);
```

### 5.3 4 源仲裁与优先级

| 优先级 | 源 | 形态 | 说明 |
|---|---|---|---|
| 1（最高） | 源 1 L1D refill（读） | 32 B 对齐读 | load 缺失在关键路径 |
| 2 | 源 0 L1I refill（读） | 32 B 对齐读 | 取指缺失 |
| 3 | 源 3 非缓存/维护 | 单拍读写 + cbo | 强序；cbo 由 `.clean/.flush` 的串行语义保证 |
| 4 | 源 2 L1D 写回 | 32 B 整行写 | 可延迟；VB 将满时提升到第 1 位 |
| 5 | 预取 | 32 B 读 | 仅无其它源时插入，未完成 ≤ 1 |

固定优先级 + 老化（连续 8 周期被抢占的低优先级源提升一级，防饿死）；每拍只授权一个源。

### 5.4 Refill / Victim Buffer

- **Refill 4 项**：`{tag, set, way, 目标源/ID, beat_cnt, data[255:0], err}`；AXI 返回按 `rid` 分发（源 0→`4'd0`、源 1→`4'd1`、源 2→`4'd2`、源 3→`4'd3`，06 §2.2），收齐 8 beat（`` `AXI64/128 `` 为 4/2 beat）后写阵列并回 `l2_rsp_*`。
- **Victim 4 项**：L2 行被替换且脏 → 入 VB，以 `awid=4'd2` 发 8 beat 写突发；写响应只记账（非精确，06 §2.1）。
- **写分配特例**：源 2 的整行写回在 L2 缺失时**直接分配**（32 B 已完整，无需先读内存），置 dirty 并登记最终写回 DDR，避免 non-inclusive 下的读放大。**所有权转移**：源 0/1 refill 返回时把 L2 中该行置 clean（脏数据所有权转到 L1D），避免同一行两处同时为脏。

### 5.5 next-line 预取器

**触发**：源 0/1 的 refill 请求在 L2 缺失（或命中但判为顺序流）且地址落在可缓存窗口（DDR/SRAM）→ 对 `PA[31:5]+1` 发起预取。**限流**：同时最多 1 个未完成预取；每 4 周期最多 1 次；Refill Buffer 有空位且 AXI 读队列未满才发；`PA[11:0]+32 > 12'hFFF`（跨 4 KB 页）放弃；目标行已在 L2 则不重复预取；预取用独立 ID，可被真实缺失抢占并丢弃结果。预取只填 L2、不直接填 L1（与 `../03-cache.md` §4 一致）；效果用 `perf_cnt_prefetch` 与 L2 命中率评估。

### 5.6 AXI 请求生成（32 B = 8 beat @32bit）

| 请求 | 通道 | 参数 |
|---|---|---|
| L2 refill（源 0/1） | AR/R | `arid={0,1}`、`arlen=4'd7`、`arsize=3'b010`、`arburst=2'b01`、`arcache=4'b1111`、地址 32 B 对齐 |
| L2 写回（VB） | AW/W/B | `awid=4'd2`、`awlen=4'd7`、`awsize=3'b010`，8 beat 顺序输出，`wlast` 在第 8 拍 |
| 非缓存单拍 | AR/R 或 AW/W/B | `id=4'd3`、`len=4'd0`、`size` 按宽度、`cache=4'b0010`（device non-bufferable）、同地址保序 |
| 突发约束 | — | `len ≤ 15`、不跨 4 KB（32 B 行天然满足）；`` `AXI64 ``→`len=3/size=3'b011`，`` `AXI128 ``→`len=1/size=3'b100` |

## 6. 原子指令与 `cbo.*`

### 6.1 `lr.w` / `sc.w` 保留集

保留集 1 项 `{resv_valid, resv_paddr[31:5]}`（**32 B 行粒度**，规范允许 ≥ 被访问字的所有字节）。`lr.w` 与普通 LW 同路径（走 LDQ、可转发），额外设置保留集并标记 ROB `is_amo`（提交时释放）。`sc.w` 走 STQ：命中保留集且有效 → 提交时写入 `rs2` 并写回 rd=0；否则 rd=1 且**不写内存**（`dc_sc_fail`）。

| 清空事件 | 清? | 说明 |
|---|---|---|
| `sc.w` 执行（成功或失败） | ✅ | 规范：`sc` 只能与最近一条 `lr` 配对 |
| 本 hart 任意 store 提交且物理地址落入保留行 | ✅ | 保守策略（规范允许），由 Store Buffer 排空的地址比较实现 |
| `cbo.inval/flush/zero` 命中保留行 | ✅ | 数据被维护指令改变 |
| 进入陷阱（`trap_valid`）或 `mret/sret` / `sfence.vma` / 写 `satp` | ✅ | 上下文与特权级切换、地址空间变化（VA 别名风险） |
| `flush_all`（复位、`fence.i`、调试断点） | ✅ | — |
| 其它 hart 的 store | — | 单核不存在；多核必须补总线 snoop（平台不提供） |
| 设备/DMA 写 | ❌ 硬件不可观测 | **已知限制**：平台无一致性信号（`../kb/03-nand-controller.md` §8），软件不得让 LR/SC 跨越 DMA 传输 |

### 6.2 AMO 读-改-写流水

| 阶段 | 命中 | 缺失 |
|---|---|---|
| 发射 | 按 store 类进 STQ（`is_amo`）；等更老 STQ 项 `addr_valid`（§6.3 `rl`） | 同左 |
| 读 | 请求 D-Cache（`dc_req_lrsc=3`、`dc_req_amo={op,aq,rl}`）读该行，同时做 §3.4 转发合并 | 分配 MSHR，refill 后再读；`amo_valid/amo_op/aq/rl` 存 MSHR |
| 改 / 写回 rd | AMO ALU（复用整型 ALU + 4 bit `amo_op[4:1]`）：`new = f(old, rs2)`，SWAP 取 `rs2`；**旧值**（`wb_sel=MEM`）唤醒依赖者 | 同左 |
| 写内存 | 新值存入 STQ，**ROB 提交时**经 Store Buffer 写 L1D（保证精确异常） | 同左 |

顺序约束：AMO 不与更老 store 交换顺序；更年轻 load 访问同地址时由 §3.4 转发拿到新值（不会读到旧 Cache 内容）；AMO 期间锁定该组一拍。取舍：读在发射期、写在提交期，中间无本 hart 访问插入且系统单核 ⇒ 满足 RVWMO 原子性；与 DMA 共享该行不受保护（同 §6.1 限制）。

### 6.3 `amo_aq` / `amo_rl` 的内存序实现

| 位 | 规范语义 | 本设计 |
|---|---|---|
| `rl=1` | release：之前所有访存必须先于它被观察到 | 发射条件加 `st_drain_ok`：所有更老 STQ 项 `COMMITTED`（数据已进 Store Buffer/L1D），更老非缓存写已排空 |
| `aq=1` | acquire：之后所有访存不得先于它被观察到 | `aq_block` 记分牌：存在"已发射未完成且 `aq=1`"的 AMO 时，更年轻 load/store **不得申请 D-Cache 端口**（在 LSQ 等待，不占 IQ）；AMO 写入完成（提交并落 L1D）后解除 |
| `aq=rl=1` / 是否需要 `fence` | 顺序一致 | 两者叠加；**不需要**注入 `fence` uop：`rl` 由发射条件、`aq` 由记分牌实现，粒度更细（只阻塞访存，不阻塞 ALU）。`fence` 指令仍是 I/O 域屏障（§7.1） |

### 6.4 `cbo.inval/clean/flush/zero` 实现与 `menvcfg` 检查

**权限检查**（ID 级用 CSR 值判定，LSU 二次校验）：`cbo.zero` 需 `CBZE=1`；`cbo.clean/flush` 需 `CBCFE=1`；`cbo.inval` 需 `CBIE!=00`，且 **`CBIE==01` 时把 INVAL 降级执行为 FLUSH**（规范要求的安全行为）。不满足 → 非法指令异常（cause 2、`tval=指令编码`，按 02 §6）；S/U 模式同时受 `senvcfg` 同名位限制。

| 指令 | L1D 动作 | L2 动作（经维护源） |
|---|---|---|
| `cbo.inval` | 按 `PA[31:5]` 查 Tag：命中 → `valid=0`（脏数据丢弃）；不命中 → 空操作 | 维护命令：L2 命中 → `valid=0`（脏丢弃） |
| `cbo.clean` | 命中且脏 → 整行经 VB 写回 L1D→L2 通道；**保留 valid、清 dirty** | 命中 → 若脏则写回 DDR；随后置 clean（数据已到内存，DMA 可见） |
| `cbo.flush` | = clean + inval（脏行先回写再置 `valid=0`） | = clean + inval |
| `cbo.zero` | 命中 → 整行写 0、置 dirty、清转发掩码；不命中 → 分配（refill 或整行写分配）后写 0；`rs1` 允许非块对齐（按 `PA[31:5]` 对齐到块） | 无需动作（L1D 成为所有者；L2 旧副本若脏须在 L1D 分配时回写/清理，避免双脏） |

**关键点（DMA 正确性）**：平台 DMA 直接读写 DDR 且不经过 L2（`../kb/03-nand-controller.md` §3、`../porting/03-drivers.md` §6），因此 `cbo.clean/flush` **必须把数据推过 L2 到达 DDR**（L2 执行写回内存并等待 AXI 写完成），否则驱动 `dma_sync_single_for_device()` 之后 DMA 仍读到旧数据。`cbo.*` 是 `is_serial` 指令（02 §4.5），提交点等待维护命令完成（含 L2 的 AXI 写响应），保证"维护 → 门铃写 → DMA 启动"的软件顺序成立；代价是这几条指令阻塞提交数十周期（频率低，可接受）。

## 7. 非缓存访问与 MMU 交互

> **裁定（2026-09-13）**：非缓存 load/store 采用 **ROB 头部门控**（`rob_idx == rob_head` 时才发往 `uncached_unit`，发出后不重放），L2 **不**暴露 AXI 端口，非缓存单元**直接连 `axi_bridge`**；设备访问 `awcache/arcache = 4'b0000`。详见 `08-bus-axi.md` §9.4b。

### 7.1 设备窗口读写与 `fence` 顺序

- **窗口判定**在 LSU 内按物理地址完成（与 `bus/addr_decode.v` 同一张表，00 §2.2 / 06 §3）：DDR `0x0000_0000-0x07FF_FFFF`、SRAM `0x1C00_0000-0x1C0F_FFFF` → 可缓存；`0x1FD0_0000`/`0x1FAF_0000`/`0x1FE0_0000`/`0x1FE7_8000`/`0x1FE8_0000`/`0x1FF0_0000` → 非缓存；CLINT `0x1F00_0000`、PLIC `0x1F10_0000` → **核内截获，不产生 AXI 访问**（`uncached_unit.v` 直接应答）。
- 非缓存通道：**单拍、单次、不分配 Cache 行、不合并、不重排**，同地址保序；非对齐设备访问按 §2.4 拆成多次单拍（`../03-cache.md` §5）。非缓存 load/store 不进 L1D MSHR；`uc_resp_fault` 对 load 精确上报（写回前等响应），对 store 在提交前完成地址/权限检查，AXI 写响应错误为非精确记账。
- `fence`（提交级 `is_fence`）：① 等所有更老非缓存写完成（AXI `B` 响应）；② 等更老 store 至少进入 L1D 写入队列；③ 等非缓存读返回；全部满足后在 ROB 头部提交（`is_serial`）。`fence.i` 清 L1I/取指队列，`sfence.vma` 清 TLB。

### 7.2 页表 PTE 的 A/D 位硬件更新

- 路径：**PTW 经 L1D 端口读写 PTE**（§1.4#3），`ptw_req_addr` = PTE 物理地址（D-Cache 索引取 `addr[11:5]`，与 VIPT 的 VA 索引在物理地址上等价）。**必须重新读取内存层次的 PTE，不得用 TLB 中缓存的 PTE 做 A/D 更新**（`../04-csr-mmu.md` §5.2）。
- 读：命中 1 拍返回；缺失走 L1D 的 MSHR/refill（PTE 是**可缓存**行，与非缓存设备访问不同）。PTW 据此判定 V/R/W/X/U/A/D。
- 写（A/D 置位）：硬件**原子读-改-写**，`new_pte = old_pte | (A<<6) | (D<<7)`；写回是**一次 32 bit 全字写**（`wstrb=4'hF`），D-Cache 在写期间**锁定该组**（同组其它写延后一拍），保证 PTE 更新原子、不被部分覆盖。
- 顺序（规范要求）：hart 不得在 PTE 更新全局可见之前执行引发该更新的访存。本设计在 **PTW 把 A/D 写回提交进 L1D（单核 coherence point）之后**才返回 `mmu_resp_valid`（保守但规范允许的简化），显式访存必然晚于 PTE 更新。
- 异常优先：PTE 读/写若产生访问错误（PMP 拒绝写回、AXI 错误）→ 报 **访问错误 5/7**，**不置 A/D**；A/D 置位过程中发生异常时，规范允许"A/D 可能已更新但引发它的访存不发生"；**D 位按规范保持精确**（只在写访问前设置）。
- A/D 写回产生的脏行不得因 `flush_all`/重放被丢弃（属体系结构状态）；清空只作废 LSQ/ROB 表项，不清 Cache 数据。对 DMA 的可见性同 §6.4（需 `cbo.clean`）。

### 7.3 一条指令内的异常优先顺序

`页错误 13/15 > 访问错误 5/7 > 非对齐 4/6`；同级时"最先遇到的一半"（低地址半部分）优先。取指侧 cause 0/1/12 由前端处理。所有访存异常在 ROB 提交点精确触发，`tval` 取 LSQ 的 `fault_va`。

## 8. 性能计数器与验证要点

### 8.1 计数器（`perf_cnt_*`，00 §7；建议映射到 `mhpmcounter3..31`，见 §1.4#6）

| 计数器 | 事件 / 用途 |
|---|---|
| `dcache_access` / `dcache_hit` / `dcache_miss` | L1D 请求 / 命中 / 缺失 → 命中率（目标 ≥95%，`../03-cache.md` §9；命名对齐 `09-verification-interface.md` 的 `perf_cnt_dcache_miss`） |
| `l2_access` / `l2_hit` / `l2_miss` / `l2_prefetch` | L2 请求/命中/缺失（目标 ≥80%，`perf_cnt_l2_miss` 见 09）/ 预取发出 |
| `mshr_full` / `stb_full` / `stq_full` / `ldq_full` | 结构满导致的停等周期 → 队列深度是否合理 |
| `fwd_hit` / `fwd_partial` / `split` / `split_cross_line` | 全字节/部分字节转发命中、非对齐拆分（含跨行）计数 |
| `replay` / `replay_mem_cycle` | 违例重放次数 / 重放阻塞周期 → store-set 预测器调参 |
| `amo` / `lr` / `sc_fail` / `uncached` / `cbo` / `tlb_ptw_ad_update` | 原子指令与竞争、设备访问、维护指令、A/D 置位次数 |

### 8.2 验证要点与判据（定向 + 随机两类激励）

| # | 验证项 | 判据 |
|---|---|---|
| 1 | 非对齐 load/store（1/2/4/8 B × 偏移 0~3 × 行内/跨字/跨行） | 与顺序参考模型逐字节一致；拆分拍数与 §2.4 公式一致；不产生伪异常 |
| 2 | 跨 32 B 行访问（含跨行 store、FLD/FSD） | 两行数据均正确；第二行缺失时 MSHR 只分配一次且回填不丢字节 |
| 3 | 部分重叠转发（load 覆盖 2~3 个更老 store 的部分字节） | 每字节来自"程序序上最近的更老 store"；`fwd_strb` 逐字节正确；剩余字节取 Cache |
| 4 | 转发 vs 违例重放（地址后到的更老 store） | 违例必被检出，replay 后与顺序核一致；不误清更老表项；`redirect_rob_idx = rob_idx-1` |
| 5 | store-set 预测器 | 预测冲突时 load 等到更老 store 地址就绪；违例后 SSIT 被正确训练（同 PC 下次预测冲突）；`conf` 递减到 0 后失效 |
| 6 | 原子指令（命中/缺失 × `aq`/`rl` 四种组合） | AMO 读旧写新正确；新值经转发对更年轻 load 可见；`rl=1` 时更老 store 已提交；`aq=1` 时更年轻访存不早于 AMO 写完成 |
| 7 | `lr.w`/`sc.w` 竞争与保留集清空 | 成功/失败返回值正确；§6.1 每个清空事件有定向用例；`sc` 失败绝不写内存；trap/`sfence.vma`/`cbo` 后 `sc` 必失败 |
| 8 | 缺页与 `tval` | 13/15 的 `tval` = 出错 VA（拆分越页时为出错半部分 VA，可高于原 VA）；4/5/6/7 的 `tval` = 原始 VA；优先级符合 §7.3 |
| 9 | MSHR 合并与乱序返回 | 同拍/跨拍同行多请求只发一次 L2 事务且字节合并正确；乱序返回按 `id`/`tag` 精确回填，无错行填充 |
| 10 | Store Buffer 时序与满 | 提交后 1~2 拍写入 L1D；满时精确回压且不丢 store；提交前 Cache 中不可见该 store 数据 |
| 11 | Cache 维护与 DMA 一致性 | `cbo.clean/flush` 后 DDR 中可见新数据（CPU 写 → cbo → 旁路读内存）；`cbo.inval` 后 CPU 读到 DMA 写入的新数据；`CBIE=01` 时 INVAL 退化为 FLUSH；`CBZE/CBCFE=0` 时 S/U 报非法指令 |
| 12 | A/D 位硬件更新 | A 在首次访问后置位、D 仅在写访问前精确置位；随机并发写 PTE 无部分覆盖；PTE 访问错误报 5/7 且不置 A/D |
| 13 | 非缓存强序访问 | 同地址读写保序；`fence` 后设备写已完成（CONFREG/UART 时序观察）；CLINT/PLIC 窗口不产生 AXI 访问 |
| 14 | 清空一致性 | `flush_valid`/`flush_all`/replay/陷阱同时发生时 LSQ/STQ/MSHR/保留集状态一致，无死锁、无漏唤醒（05 §9 压力场景） |
