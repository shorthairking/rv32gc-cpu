//==============================================================================
// rtl/back2/rob.v —— 重排序缓冲（ROB，ROB_N 项；★ L3 由 128 降为 64）：顺序提交 ≤4 条/拍 + 精确异常
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §2.1（字段与环形组织）、§2.2（顺序提交关键路径：
//         ① !done 必须停 ② 异常在头部精确触发 ③ 提交宽度是上限）、§8.1（E1/E2/E3 精确性
//         要点）、§8.2（epoch）；
//         docs/design/02-pipeline.md §3.7（D3 派发：ROB 余量不足 ⇒ 整块停顿 S5）、
//         §3.11（W1 提交）、§5（衔接硬规则 1：ROB 项连续分配）。
//
// 【组织】环形缓冲：head = 提交点、tail = 派发点；`cnt_q` = 有效项数（0..ROB_N）。
//   · 项有效性由 (idx - head) mod ROB_N < cnt 派生（★ L3：ROB_IDX_W 恒 == log2(ROB_N)） ⇒ **不需要 valid 位数组**，冲刷只需
//     改 cnt（03 §8.1 E6 的"分布式删除"问题的 ROB 侧解法）。
//   · `done` 位由各写回口置位；非法项由 ALU0 以 no-op 执行后置位（保证头部不会永久卡住）。
//   · `exc != 0` 的项到达头部 ⇒ 本拍不提交、拉高 trap_valid（精确异常点）。
//   · store 项在头部提交时**同时**向简化访存队列发排空（本里程碑口径：store 只在提交后
//     写存储，保证异常回滚不会双重写，03 §6.2/§9）。
//
// 【载荷】每项 = BACK2_RB_W 位打包向量（`back2_params.vh` §2 为唯一布局真源）：
//   ★★ C4（416→229 bit；★ EXP-R2 再 229→225）：只保留「rob.v 自己 + 提交路径 + `pack_nq`
//   重建 nq」真正读的位；
//     旧的 uop(304) 全量副本（其中 IMM/ARND/源物理号/控制码/TVAL 重复副本…）与 CSRW(32)
//     全部删除。字段表与逐字段证据见 `back2_params.vh` §2 的 C4 段注释。
//
// ★★ EXP-B（架构 v0.1 §16–§21）：**可更新字段从"一张 102 bit 多写源表 `updq`"拆成
//    三张"每表单写源"typed 表**：
//      · `br_q`（分支结果：taken + tgt）  —— 唯一写源 **BRU**（`upd_tr`）
//      · `ff_q`（FP flags[4:0]）           —— 唯一写源 **FPU**（`upd_ff`）
//      · `ex_q`（异常 TVAL[31:0]）         —— 唯一写源 **LSU**（`upd_exc`）
//      · 死口 `upd_csr` 整条删除（动态实测恒 0）；CSR 提交期源改从载荷 `uop.PS1I` 取。
//    每表自带 {valid, epoch}（epoch 复用项内 2 bit 口径）：提交/陷阱时
//    `valid && epoch == 项内 epoch` 才采用 ⇒ flush/squash 不必清 64 项（旧项天然作废）。
//    对外接口（`cmt_payload`/`cmt_narrow`/`cmt_st_*`/`trap_*`/`csr_pay`）**逐位不变**。
//    动态依据：`upd_tr/ff/exc` 同拍并发 ≥2 仅 0.02%（3 拍）、`upd_csr_valid` 恒 0
//    （docs/design/10-dynamic-behavior.md §1.3）。
//
// 风格  : 组合逻辑全部 `assign`/函数（红线 3）；always 块只用于存储体与指针（时序元件）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module rob #(
    parameter integer ROB_N      = `BACK2_ROB_N,
    parameter integer ROB_IDX_W  = `BACK2_ROB_IDX_W,
    //   ★★ EXP-N1：**分配宽度与提交宽度彻底分离**（原来两者共用 `COMMIT_W`）。
    //     · ALLOC_W  = 派发/分配宽度（4，保持不动）——决定 `alloc_*` 口与 BRAM 写口数；
    //     · COMMIT_W = 提交/退休宽度（2）——决定退休选择/前缀链/架构更新/输出口宽度。
    //     两者分离后"4 发射 + 2 提交"在结构上才成立（只改一个共用宏无法表达）。
    parameter integer ALLOC_W    = `BACK2_ALLOC_W,
    parameter integer COMMIT_W   = `BACK2_COMMIT_W,
    parameter integer RB_W       = `BACK2_RB_W,
    parameter integer WB_N       = `BACK2_WB_N,
    parameter integer DBG_CSR    = 0        // B29 定案探针
) (
    input  wire                    clk,
    input  wire                    rst_n,

    //==================================================================
    // 派发（D3）：连续 ALLOC_W 项（lane 0 最老）
    //   ★★ EXP-N1：本组口的宽度是 **ALLOC_W**（= 4，派发宽度未变），不是 COMMIT_W。
    //==================================================================
    input  wire                    alloc_valid,
    input  wire [2:0]              alloc_n,          // 1..ALLOC_W
    output wire                    alloc_ready,      // 余量 ≥ alloc_n
    output wire [ROB_IDX_W-1:0]    alloc_idx0,       // 本块首项索引
    input  wire [ALLOC_W-1:0]      alloc_lane_valid,
    input  wire [ALLOC_W*RB_W-1:0] alloc_payload,
    input  wire [`BACK2_EPOCH_W-1:0] alloc_epoch,     // 本块分配时的流世代（存入项内）

    //==================================================================
    // 完成（写回口）：置 done
    //==================================================================
    input  wire [WB_N-1:0]                 wb_valid,
    input  wire [WB_N*ROB_IDX_W-1:0]       wb_rob_idx,
    input  wire [WB_N*`BACK2_EPOCH_W-1:0]  wb_epoch,     // §8.2 epoch：过期写回不得置 done

    //==================================================================
    // 执行期字段回写（每张 typed 表**恰好一个写源**；本里程碑够用）
    //   ★ EXP-B：原 `upd_csr_*` 三口已删（`backend_top.v` 早已硬接 1'b0；动态实测恒 0）
    //==================================================================
    input  wire                    upd_tr_valid,
    input  wire [ROB_IDX_W-1:0]    upd_tr_idx,
    input  wire                    upd_tr_taken,
    input  wire [31:0]             upd_tr_target,
    input  wire                    upd_ff_valid,
    input  wire [ROB_IDX_W-1:0]    upd_ff_idx,
    input  wire [4:0]              upd_ff_flags,
    input  wire                    upd_exc_valid,
    input  wire [ROB_IDX_W-1:0]    upd_exc_idx,
    input  wire [3:0]              upd_exc_code,
    input  wire [31:0]             upd_exc_tval,

    //==================================================================
    // 提交（W1）：环境（存储排空口可发射 ⇒ store 才能提交）
    //==================================================================
    input  wire                    mem_wr_ready,
    output wire [COMMIT_W-1:0]     cmt_valid,        // 本拍按程序序提交的槽（前缀连续）
    output wire [COMMIT_W*RB_W-1:0] cmt_payload,
    //   ★★ 2B-5 第 3 步①（窄位先行）：**每 lane 的窄控制字**（组合读、零延迟）
    //     —— 供第 2/3 步把宽字段改成 BRAM 同步读（+1 拍）后，提交决策/前缀链/排空选择
    //     等**延迟敏感路径**仍走 FF 组合读。
    output wire [COMMIT_W*NQ_W-1:0] cmt_narrow,
    //   ★★ 2B-5 第 3 步②：派发期**预译码标志**（每 lane 5 bit：{mret, sret, maint_kind[2:0]}）
    //     ⇒ 提交侧不再需读 4 lane 的 32 bit 指令字去译码 xRET/维护操作。
    //   ★★ EXP-N1：本口是**派发侧**数据 ⇒ 宽度 = ALLOC_W*5（不是 COMMIT_W*5）。
    input  wire [ALLOC_W*5-1:0] alloc_pre,
    //   ★ ② CSR 提交合成的**单 lane 动态读口**（索引 = 提交组内 CSR lane 的绝对 ROB 索引）
    input  wire [ROB_IDX_W-1:0]  csr_lane_idx,
    output wire [`BACK2_CMT_CSR_W-1:0] csr_pay,
    output wire [COMMIT_W-1:0]     cmt_st_drain,     // 该槽为 store 且本拍排空
    output wire [COMMIT_W-1:0]     cmt_st_ckpt,      // 该槽携带检查点（释放用）
    output wire [COMMIT_W-1:0]     cmt_st_branch,    // 该槽是控制转移（训练用）

    //==================================================================
    // 精确异常（提交点）
    //==================================================================
    output wire                    trap_valid,
    output wire [31:0]             trap_pc,
    output wire [3:0]              trap_cause,
    output wire [31:0]             trap_tval,

    //==================================================================
    // 冲刷：squash_idx 及其**之后（更年轻）**的项全部作废（含该项保留）
    //        flush_all = 全清（异常/中断；head 不动）
    //==================================================================
    input  wire                    squash_valid,
    input  wire [ROB_IDX_W-1:0]    squash_idx,
    input  wire                    flush_all,
    //   ★ 2B-4 第 4a 段：**陷阱退役**（无副作用弹出头部异常项）。
    //     陷阱在头部被精确抛出（`trap_valid`）时，该指令**不得提交**（`slot_ok` 已含 `~slot_exc`），
    //     但硬件处理程序已接管 ⇒ 它必须从此消失，否则 `flush_all` 保留头部 ⇒ 重取后又立刻再陷阱
    //     （死循环）。本信号与 `trp_flush_v_i` 同拍：head 前移 1、cnt 保持 0。
    input  wire                    trap_retire,

    //==================================================================
    // 观测
    //==================================================================
    output wire [ROB_IDX_W-1:0]    head_o,
    output wire [ROB_IDX_W:0]      cnt_o,
    //   ★★ C8：**统一年龄输出**（"距 ROB 头距离"的全核唯一计算点）——
    //     `squash_age_o = (squash_idx − head_q) mod ROB_N`
    //     全核所有"更年轻 ⇔ age(项) > age(冲刷点)"判据一律改用它：`iq.v` ×6
    //     （冲刷作废掩码）、`backend_top.v` 的 MDU/FPU/I2 杀链与 CSR 追踪表、
    //     以及本模块 §5 的 `cnt_q` 重建。**语义与各站点的本地重算逐位一致**
    //     （两侧都是 ROB_IDX_W 位的模 ROB_N 减法，见 §1.1）。
    output wire [ROB_IDX_W-1:0]    squash_age_o,
    output wire                    empty_o,
    output wire                    head_done_o,
    output wire [3:0]              head_exc_o,
    output wire [31:0]             cmt_cnt_o,       // 累计提交条数（性能统计）
    output wire [`BACK2_EPOCH_W-1:0] epoch_o
);

    //==========================================================================
    // 0. 存储体与指针
    //==========================================================================
    //   ★★ B2：`pl_q` 已删（宽载荷改由 `rob_wide_mem` 承担：写侧每表项 mux 塔缩为每 bank 1 个 4:1 选择）
    //   ★★ EXP-N1：**预取宽度口径**（= 每拍从 BRAM 预取的项数；不由 COMMIT_W 决定）：
    //     PF_W = 4 必须覆盖 BRAM 同步读延迟（1 拍）× 每拍提交前进量（≤ COMMIT_W = 2）
    //     = 2，取 4 是为"连续满宽提交（2/拍）时窗口仍领先 2 拍"留余量。
    //     **不能**跟着 COMMIT_W 缩到 2：预取地址 T 拍算出、数据 T+2 拍可用，每拍只预取 2 项
    //     会让连续 2/拍提交组落到窗口之外 ⇒ 每拍插气泡（性能判据不允许）。
    localparam integer PF_W = 4;
    //   ★★ EXP-N1：头部窗口/预取/BRAM 读侧保持 4 宽（见上）；收窄的是**提交侧消费**（2 lane）。
    reg  [RB_W-1:0]      win_q   [0:7];       // ★ B3：头部窗口（C4 后 RB_W=229；★ EXP-R2 后 225）
    reg  [ROB_IDX_W-1:0] win_idx [0:7];       // 每槽 7 bit 全索引标签
    reg                  win_val [0:7];       // 每槽有效（复位/冲刷清零）
    reg  [ROB_IDX_W-1:0] e_of_r_q[0:PF_W-1];  // 预取读地址的**打拍版**（读数据下一拍到达时用它定标签）
    //   ★★ 危险修正（p11 实测）：BRAM 为 `read_first` ⇒ "同拍被写的项，当拍读到旧值"。
    //     若预取地址正好是本拍刚分配的项（ROB 近空：清洗后 head≈tail），窗口会被填入**旧载荷**
    //     但标签恰好命中 ⇒ 会交付错误 PC。修法：记下**上一拍的分配索引**，填充时若命中则
    //     **丢弃本次填充并把该槽置为无效**（下一拍重读即可）；冲刷时也全部置无效。
    reg  [ROB_IDX_W-1:0] alloc_idx_q[0:PF_W-1];
    reg  [PF_W-1:0]      alloc_idx_v_q;
    wire [RB_W-1:0]      pl_rdata[0:PF_W-1];  // PF_W bank 同步读回数据
    wire [1:0]           wsel    [0:PF_W-1];  // 写轮转：bank i 对应的 lane 序号 = (i - tail[1:0]) & 3
    wire [1:0]           rsel    [0:PF_W-1];  // 读轮转：读口 i 对应的项序号 = (i - head_pred[1:0]) & 3
    //   ★★ 2B-5 第 3 步①：**窄控制表** `nq`（FF 阵列，组合读）
    //     · 收编原 `done_q` + `rep_q`（epoch）+ 提交/前缀链/排空/陷阱判定所需的控制位与索引；
    //     · **宽字段（PC/TVAL/CSRW/TRTGT/FFLAGS 等）仍在 `pl_q`**，本步不动；
    //     · 本步将 rob.v **自用的关键读**（done/exc/is_store/ckpt/is_branch/trap_cause/epoch）
    //       全部改走 `nq`（行为逐位等价），并导出 `cmt_narrow` 供下一步改造 backend_top。
    //     字段布局（MSB→LSB）：
    //       pre{mret,sret,maint_kind[2:0]} trtaken pdf[5:0] pdi[5:0] arn[4:0]
    //       is_csr is_fp_wen is_int_wen ckpt_valid is_branch is_store exc[3:0] epoch[1:0] done
    //     ★★ D2：原 `lq[3:0] stq[4:0] csrop[2:0]`（12 bit）在 `nq` 里**只写不读**（唯一"读"
    //       是 §5 自检对 nq/nq_chk 的恒等区间比对）⇒ 已删，`NQ_W` 49→37；
    //       布局真源 = back2_params.vh §2，本文件不得另存一份位号。
    //     ★★ EXP-R2：`pdi` 由 `PREG_I_W` 定宽（7→6）⇒ `NQ_W` 37→36，其上整段下移 1。
    localparam integer NQ_W      = `BACK2_NQ_W;
    localparam integer NQ_DONE   = `BACK2_NQ_DONE;
    localparam integer NQ_EP_L   = `BACK2_NQ_EP_L;
    localparam integer NQ_EXC_L  = `BACK2_NQ_EXC_L;
    localparam integer NQ_STORE  = `BACK2_NQ_STORE;
    localparam integer NQ_BR     = `BACK2_NQ_BR;
    localparam integer NQ_CKV    = `BACK2_NQ_CKV;
    localparam integer NQ_DI     = `BACK2_NQ_DI;
    localparam integer NQ_DF     = `BACK2_NQ_DF;
    localparam integer NQ_CSR    = `BACK2_NQ_CSR;
    localparam integer NQ_ARN_L  = `BACK2_NQ_ARN_L;
    localparam integer NQ_PDI_L  = `BACK2_NQ_PDI_L;
    localparam integer NQ_PDF_L  = `BACK2_NQ_PDF_L;
    localparam integer NQ_TRT    = `BACK2_NQ_TRT;
    localparam integer NQ_MK_L   = `BACK2_NQ_MK_L;
    reg  [NQ_W-1:0]      nq    [0:ROB_N-1];
    //   ★★ EXP-B（架构 v0.1 §16–§19）：**三张 typed 单写源更新表**（替代原 102 bit `updq`）
    //     · 动机：原 `updq` 每表项有 8 个写源（4 派发 lane + CSR/BRU/FPU/LSU 四口）⇒
    //       每表项一个多写源写 mux（面积探针实测 ≈11 k LUT，docs/design/09 §2.3 第 3 行）；
    //       动态实测 `upd_tr/ff/exc` 同拍并发 ≥2 仅 0.02% ⇒ **无需共享写口**，
    //       三张表各留一个写源即可，写侧退化为"每表一次索引译码 + 数据直连"。
    //     · 每表 {valid, epoch}：写口在**目标项自己的 epoch**（`nq[idx].epoch`）下置位；
    //       提交/陷阱时 `valid && epoch == 项内 epoch` 才采用 ⇒ 索引被复用/跨冲刷的旧表项
    //       epoch 不同，天然作废（不必在 flush/squash 清 64 项）。
    //     · 数据数组不置复位（valid=0 时被 merge 的回落支路屏蔽，无 x 传播）；
    //       valid/epoch 数组复位清零（仿真下不会出现 x 判定）。
    reg                          br_v_q  [0:ROB_N-1];
    reg  [`BACK2_TBL_EP_W-1:0]   br_ep_q [0:ROB_N-1];
    reg  [`BACK2_BR_TGT_W-1:0]   br_tgt_q[0:ROB_N-1];
    reg  [`BACK2_BR_TAKEN_W-1:0] br_taken_q[0:ROB_N-1];
    reg                          ff_v_q  [0:ROB_N-1];
    reg  [`BACK2_TBL_EP_W-1:0]   ff_ep_q [0:ROB_N-1];
    reg  [`BACK2_FF_W-1:0]       ff_q    [0:ROB_N-1];
    reg                          ex_v_q  [0:ROB_N-1];
    reg  [`BACK2_TBL_EP_W-1:0]   ex_ep_q [0:ROB_N-1];
    reg  [`BACK2_EX_TVAL_W-1:0]  ex_tval_q[0:ROB_N-1];

    //   拼接：载荷的不可更新部分 + 三张 typed 表的命中值（纯布线 + 单层选择，无多写源 mux）
    //     命中判据由调用方给出（`*_use` = 表 valid && 表 epoch == 项内 epoch && 该字段真被读）；
    //     未命中回落到"该字段在载荷里的原值"（br/ff 的原值恒 0 ⇒ 直接用常量，见下）
    //   ★★ EXP-B 回落支路口径（与综合面积直接相关，勿随手改）：
    //     · br/ff 两个回落支路用**常量 0**：载荷的 [405:401]/[400]/[399:368] 由
    //       `backend_top.v` 的 ROB 载荷组装式**恒写 `5'b0 / 1'b0 / 32'h0`**（"执行期回写"
    //       占位，且载荷只有派发一个写源）⇒ 与读 `pl[...]` **逐位等价**；本文件 §6 的
    //       `ROB-ASSERT-PAY0` 自检在仿真里逐拍钉死该前提。
    //       为何不读 `pl[...]`：那会让 BRAM 的**读数据位宽**多出 38 bit ⇒ 实测每 bank
    //       从 5 个 RAMB36 撑到 6 个（全核 +4 RAMB36、u_wmem +1.5 k LUT 的**假成本**）。
    //     · ex（TVAL）的回落支路**必须**读 `pl[367:336]`：非法指令/取指异常的 mtval
    //       就存在那里（唯一真源，见 §3 `trap_tval`）。
    function [RB_W-1:0] merge_upd;
        input [RB_W-1:0]              pl;
        input                         br_use; input [`BACK2_BR_TAKEN_W-1:0] br_tk;
        input [`BACK2_BR_TGT_W-1:0]   br_tgt;
        input                         ff_use; input [`BACK2_FF_W-1:0]       ff_d;
        input                         ex_use; input [`BACK2_EX_TVAL_W-1:0]  ex_tv;
        begin
            //   ★★ C4：字段序随新布局（见 back2_params.vh §2 的位域表）。结构**未变**：
            //     · FFLAGS / TRTAKEN / TRTGT 三段仍是「表命中值 or 常量 0」的占位；
            //     · TVAL 段仍是「ex 表命中值 or 载荷原值」；
            //     · TVAL 以下（LQ/STQ/PDFDST/…/EXC）整段直通载荷。
            //   ⚠ CSRW 段（旧 [335:304]）已从载荷删除（EXP-B 起 `csr_pay` 直接取载荷
            //     uop.PS1I）⇒ 本式的最后一段下移到 `RB_TVAL_LSB-1`。
            merge_upd = { pl[RB_W-1:`BACK2_RB_FFLAGS_MSB+1],
                          ff_use ? ff_d : {`BACK2_FF_W{1'b0}},
                          br_use ? br_tk : {`BACK2_BR_TAKEN_W{1'b0}},
                          br_use ? br_tgt : {`BACK2_BR_TGT_W{1'b0}},
                          ex_use ? ex_tv : pl[`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB],
                          pl[`BACK2_RB_TVAL_LSB-1:0] };
        end
    endfunction

    //   打包：从宽载荷 + epoch + done 生成窄字（分配与一致性自检共用）
    //   ★★ C4：本函数从载荷取的每个字段都必须用 **`BACK2_RB_*`（载荷布局）** 宏 ——
    //     旧版直接借用 `BACK2_U_*`（uop 布局）只是因为旧载荷的低 304 位恰好就是 uop；
    //     载荷重排后两者不再重合（唯一仍然重合的是 [19:0] 的 EXC+FLAGS 块，见参数表）。
    //   ★★ D2：删除 `lq[3:0]/stq[4:0]/csrop[2:0]` 三段（只写不读）；其余字段与
    //     `BACK2_NQ_*` 位号一一对应（位号真源在 back2_params.vh）。
    function [NQ_W-1:0] pack_nq;
        input [RB_W-1:0] p; input [`BACK2_EPOCH_W-1:0] ep; input dn; input [4:0] pre;
        begin
            pack_nq = { pre,                                           // [36:32] {mret,sret,maint_kind}
                        p[`BACK2_RB_TRTAKEN],                          // [31]
                        p[`BACK2_RB_PDFDST_MSB:`BACK2_RB_PDFDST_LSB],  // [30:25]
                        p[`BACK2_RB_PDIDST_MSB:`BACK2_RB_PDIDST_LSB],  // [24:18]
                        p[`BACK2_RB_ARND_MSB:`BACK2_RB_ARND_LSB],      // [17:13]
                        p[`BACK2_UB_IS_CSR],                           // [12]
                        p[`BACK2_UB_RD_F_WEN],                         // [11]
                        p[`BACK2_UB_RD_I_WEN],                         // [10]
                        p[`BACK2_UB_CKPT_VALID],                       // [9]
                        p[`BACK2_UB_IS_BRANCH],                        // [8]
                        p[`BACK2_UB_IS_STORE],                         // [7]
                        p[`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB],        // [6:3]
                        ep,                                            // [2:1]
                        dn };                                          // [0]
        end
    endfunction
    //   ★ 项内 epoch 由 `nq` 的 [2:1] 承载（原独立的 `rep_q` 数组已无任何读写 ⇒ 删除；
    //     原因仍是"不要把 epoch 塞进 416 bit 载荷"：载荷内的字段要在时钟块里按 7 个
    //     写回索引读 ⇒ iverilog 会展开成 7×(ROB_N×416) 的组合读森林，仿真慢 ~12×）。
    reg  [ROB_IDX_W-1:0] head_q;
    reg  [ROB_IDX_W:0]   cnt_q;              // 0..ROB_N（8 bit）
    reg  [31:0]          cmt_cnt_q;
    reg  [`BACK2_EPOCH_W-1:0] epoch_q;       // §8.2：冲刷递增；过期写回被过滤

    //==========================================================================
    // 1. 索引派生与余量
    //==========================================================================
    // 环形指针增量：ROB_N 恒为 2 的幂（L3 后 = 64）⇒ 截断即取模
    function [ROB_IDX_W-1:0] idx_add(input [ROB_IDX_W-1:0] a, input [ROB_IDX_W:0] d);
        begin idx_add = a + d[ROB_IDX_W-1:0]; end
    endfunction

    wire [ROB_IDX_W-1:0] tail_w = idx_add(head_q, cnt_q);

    //==========================================================================
    // 1.1 ★★ C8：年龄（"距头距离"）的唯一计算点
    //==========================================================================
    //   口径（与 `iq.v` §2/§5、`backend_top.v` 的杀链**逐位一致**，勿改宽度）：
    //     · ROB_N = 2^ROB_IDX_W ⇒ `ROB_IDX_W` 位无符号减法**天然取模**：
    //       `squash_idx - head_q` 在 ROB_IDX_W 位上下文里就是 `(squash_idx − head_q) mod ROB_N`
    //       （与 `idx_add()` 的"截断即取模"同一口径）；
    //     · 消费侧一律**零扩展**到 `rob_cnt` 的位宽（ROB_IDX_W+1）再比较 ——
    //       `rob_cnt = ROB_N` 时在 ROB_IDX_W 位里表示为 0，窄位比较会把"满窗口"
    //       误判成"空窗口"（`iq.v` §5 有实测注释）。
    //   ★ 本线是"更年轻 ⇔ age(项) > age(冲刷点)"这套模 N 语义在全核的**唯一实现**；
    //     各消费模块不再各自重算 `squash_idx − rob_head`（原 9 份：rob 1 + iq 6 +
    //     backend_top 1 + lsq 1）。
    wire [ROB_IDX_W-1:0] age_sq_w = squash_idx - head_q;
    assign squash_age_o = age_sq_w;

    //==========================================================================
    // 1.5 ★ B2/B3：BRAM 写/读轮转 + 头部窗口
    //==========================================================================
    //   派发 ALLOC_W 条 lane 索引连续（tail..tail+ALLOC_W-1），提交 ≤COMMIT_W 项索引也连续。
    //   ⇒ 两边都是 "{0,1,2,3} 的旋转"，bank=i 的写/读只需选择对应那一项。
    //   ★★ EXP-N1：`PF_W` 已在 §0 声明（预取宽度，见那里的口径说明）。
    wire [ROB_IDX_W-1:0] hpred_w = idx_add(head_q, {{(ROB_IDX_W-3){1'b0}}, cmt_n_w});
    genvar gw;
    generate
    for (gw = 0; gw < PF_W; gw = gw + 1) begin : g_rot
        assign wsel[gw] = gw[1:0] - tail_w[1:0];
        assign rsel[gw] = gw[1:0] - hpred_w[1:0];
    end
    endgenerate

    //   窗口读（**提交组每 lane 一个 8:1 mux**）+ 命中判定
    //   ★★ EXP-N1：只有 COMMIT_W（=2）个 lane 需要读窗口 ⇒ 这里从 4 lane 缩到 2 lane
    //     （原 4 lane 的 win_rd/win_lane_ok 与它们的 8:1 mux 全部消失）。
    wire [RB_W-1:0] win_rd [0:COMMIT_W-1];
    wire [COMMIT_W-1:0] win_lane_ok;
    generate
    for (gw = 0; gw < COMMIT_W; gw = gw + 1) begin : g_winrd
        wire [ROB_IDX_W-1:0] ei = idx_add(head_q, gw[ROB_IDX_W-1:0]);
        assign win_rd[gw]      = win_q[ei[2:0]];
        assign win_lane_ok[gw] = win_val[ei[2:0]] & (win_idx[ei[2:0]] == ei);
    end
    endgenerate

    //   BRAM 实例（B1 交付的模块：4 bank × SDP，同步读）
    //   ★★ EXP-N1：**写侧 4 口**（= ALLOC_W，派发宽度未变）、**读侧 PF_W=4 口**（预取口径，
    //     见上）。两者都不随 COMMIT_W 变化 ⇒ 本段结构不变；提交侧只是少消费 2 个 lane。
    wire [PF_W-1:0]        bw_we;
    wire [PF_W*5-1:0]      bw_woff, bw_roff;
    wire [PF_W*RB_W-1:0]   bw_wdata, bw_rdata;
    generate
    for (gw = 0; gw < PF_W; gw = gw + 1) begin : g_bw
        //   （函数返回值不能直接做位选（iverilog）⇒ 先存临时线）
        wire [ROB_IDX_W-1:0] wt = idx_add(tail_w,  {{5{1'b0}}, wsel[gw]});
        wire [ROB_IDX_W-1:0] rt = idx_add(hpred_w, {{5{1'b0}}, rsel[gw]});
        //   `wsel[gw]` 是 2 bit（bank = idx[1:0]）⇒ 恒 < 4 = ALLOC_W，索引天然合法
        assign bw_we[gw]   = alloc_fire & alloc_lane_valid[wsel[gw]] & (wsel[gw] < alloc_n);
        assign bw_woff[gw*5 +: 5] = wt[ROB_IDX_W-1:2];
        assign bw_wdata[gw*RB_W +: RB_W] = alloc_payload[wsel[gw]*RB_W +: RB_W];
        assign bw_roff[gw*5 +: 5] = rt[ROB_IDX_W-1:2];
        assign pl_rdata[gw] = bw_rdata[gw*RB_W +: RB_W];
    end
    endgenerate

    rob_wide_mem #(.NW(PF_W), .BW(32), .DW(RB_W), .AW(ROB_IDX_W), .OW(5), .CHK(0)) u_wmem (
        .clk(clk), .rst_n(rst_n),
        .we(bw_we), .woff(bw_woff), .wdata(bw_wdata),
        .re({PF_W{1'b1}}),  .roff(bw_roff), .rdata(bw_rdata));

    //   ★ B3「read_first 同址危险」判据（纯 `assign` 展开，供 §5.35 的窗口填充使用）：
    //     `dang_hit[k]` = 预取口 k 的目标索引 `e_of_r_q[k]` 是否命中**上一拍刚分配的槽**
    //     （命中 ⇒ 本次读回的是旧载荷，必须丢弃并把该窗口槽置无效，下一拍重读）。
    //   ★★ EXP-N1：预取口数 = PF_W，分配槽数 = ALLOC_W（两者均不随 COMMIT_W 变化）。
    wire [ALLOC_W-1:0] dang_hit [0:PF_W-1];
    genvar gz, gk;
    generate
    for (gz = 0; gz < PF_W; gz = gz + 1) begin : g_dang
        for (gk = 0; gk < ALLOC_W; gk = gk + 1) begin : g_dangk
            assign dang_hit[gz][gk] = alloc_idx_v_q[gk] & (alloc_idx_q[gk] == e_of_r_q[gz]);
        end
    end
    endgenerate

    // 提交链（先算，用于同拍释放余量）
    //   ★★ EXP-N1：以下**全部**是提交侧 ⇒ 宽度 = COMMIT_W（= 2），4 份复制变 2 份。
    wire [COMMIT_W-1:0] slot_in_range;
    wire [COMMIT_W-1:0] slot_done;
    wire [COMMIT_W-1:0] slot_exc;
    wire [COMMIT_W-1:0] slot_store;
    wire [COMMIT_W-1:0] slot_st_ok;
    wire [COMMIT_W-1:0] slot_ok;

    //   ★★ EXP-N1：退休选择从 `head0/head1/head2/head3` 收窄为 `head0/head1`
    //     （`slot_idx[gi] = (head + gi) mod ROB_N`，gi < COMMIT_W）。
    wire [ROB_IDX_W-1:0] slot_idx [0:COMMIT_W-1];
    genvar gsi;
    generate
    for (gsi = 0; gsi < COMMIT_W; gsi = gsi + 1) begin : g_slot
        assign slot_idx[gsi] = idx_add(head_q, gsi[ROB_IDX_W:0]);
    end
    endgenerate

    genvar gi;
    //   ★★ EXP-B：三张 typed 表在提交组 4 个 lane 上的"采用判据"（模块级数组：断言块也要看）
    wire [COMMIT_W-1:0] slot_is_br;
    wire [COMMIT_W-1:0] slot_is_fp;
    wire [COMMIT_W-1:0] br_use, ff_use, ex_use;
    generate
    for (gi = 0; gi < COMMIT_W; gi = gi + 1) begin : g_cmt
        assign slot_in_range[gi] = (cnt_q > gi);
        assign slot_done[gi]     = nq[slot_idx[gi]][NQ_DONE];
        assign slot_exc[gi]      = |nq[slot_idx[gi]][NQ_EXC_L +: 4];
        assign slot_store[gi]    = nq[slot_idx[gi]][NQ_STORE];
        assign slot_st_ok[gi]    = ~slot_store[gi] | mem_wr_ready;
        //   ★ B3：窗口未命中 ⇒ 本 lane 不可提交（插一拍气泡；**绝不交付错误 PC/tval**）
        assign slot_ok[gi]       = slot_in_range[gi] & slot_done[gi] & ~slot_exc[gi] & slot_st_ok[gi]
                                 & win_lane_ok[gi];

        //   ★★ EXP-B：typed 表采用判据 = 表 valid && 表 epoch == **本项项内 epoch** && 本项真消费该字段
        //     · `is_branch` 取 `nq`（= 载荷 IS_BRANCH，同源）；`is_fp` 只存在载荷里 ⇒ 取窗口读回值；
        //     · ex 的判据：`exc` **派发期为空、现在非空** ⇒ 该异常只可能由 LSU 的 `upd_exc`
        //       回写而来（`nq.exc` 全文只有两个写源：派发 `pack_nq` 与 `upd_exc`）⇒ 此时才吃 ex 表；
        //       派发期异常（非法/ecall/ebreak/取指异常）的 mtval 必须回落**载荷 TVAL**。
        wire [`BACK2_EPOCH_W-1:0] ep_gi   = nq[slot_idx[gi]][NQ_EP_L +: `BACK2_EPOCH_W];
        wire [3:0]                exc_gi  = nq[slot_idx[gi]][NQ_EXC_L +: 4];
        //   ★★ C4：载荷的 EXC/FLAGS 两段按硬约束**保持 uop 原绝对位**（见 back2_params §2
        //     的位域表），故这里 `BACK2_U_EXC_*` / `BACK2_UB_IS_FP` 在载荷上仍逐位成立。
        wire [3:0]                pexc_gi = win_rd[gi][`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB];
        assign slot_is_br[gi] = nq[slot_idx[gi]][NQ_BR];
        assign slot_is_fp[gi] = win_rd[gi][`BACK2_UB_IS_FP];
        assign br_use[gi] = br_v_q[slot_idx[gi]] & (br_ep_q[slot_idx[gi]] == ep_gi) & slot_is_br[gi];
        assign ff_use[gi] = ff_v_q[slot_idx[gi]] & (ff_ep_q[slot_idx[gi]] == ep_gi) & slot_is_fp[gi];
        assign ex_use[gi] = ex_v_q[slot_idx[gi]] & (ex_ep_q[slot_idx[gi]] == ep_gi)
                          & (|exc_gi) & (pexc_gi == 4'd0);
    end
    endgenerate

    // 前缀链：第 i 槽可提交 ⇒ 前面所有槽都可提交
    wire [COMMIT_W-1:0] cmt_chain;
    assign cmt_chain[0] = slot_ok[0];
    generate
    for (gi = 1; gi < COMMIT_W; gi = gi + 1) begin : g_chain
        assign cmt_chain[gi] = cmt_chain[gi-1] & slot_ok[gi];
    end
    endgenerate
    assign cmt_valid = cmt_chain;

    // 提交条数
    reg [2:0] cmt_n_w;
    integer   ci;
    always @(*) begin
        cmt_n_w = 3'd0;
        for (ci = 0; ci < COMMIT_W; ci = ci + 1) begin
            if (cmt_chain[ci]) cmt_n_w = cmt_n_w + 3'd1;
        end
    end

    //==========================================================================
    // 2. 余量（提交与派发同拍：先释放再分配）
    //==========================================================================
    //   ★ `alloc_ready` 是**纯余量判据**（与端口注释一致），**不得**含 alloc_valid：
    //     派发侧的 `disp_ok` 要用它做本轮能否派发的判据，而 `alloc_valid` 正是由
    //     `disp_ok` 派生的（D3 fire）——把 alloc_valid 卷进来会形成组合环
    //     （旧版即如此，为了绕环又把 alloc_valid 接成"D1 有块就分配"，导致同一块
    //     每拍重复分配、ROB 提交流全为重复项；实测现象：前端不推进、ROB cnt 恒定）。
    wire alloc_fire = alloc_valid & (room_free >= {5'b0, alloc_n});
    wire [ROB_IDX_W:0] cnt_after_cmt = cnt_q - {5'b0, cmt_n_w};
    wire [ROB_IDX_W:0] room_free     = ROB_N[ROB_IDX_W:0] - cnt_after_cmt;
    assign alloc_ready = (room_free >= {5'b0, alloc_n});
    assign alloc_idx0  = tail_w;

    //==========================================================================
    // 3. 提交载荷/异常输出
    //==========================================================================
    generate
    for (gi = 0; gi < COMMIT_W; gi = gi + 1) begin : g_cmtout
        assign cmt_payload[gi*RB_W +: RB_W] =
            merge_upd(win_rd[gi],
                      br_use[gi], br_taken_q[slot_idx[gi]], br_tgt_q[slot_idx[gi]],
                      ff_use[gi], ff_q[slot_idx[gi]],
                      ex_use[gi], ex_tval_q[slot_idx[gi]]);
        assign cmt_narrow[gi*NQ_W +: NQ_W]  = nq[slot_idx[gi]];
        assign cmt_st_drain[gi] = cmt_chain[gi] & slot_store[gi];
        assign cmt_st_ckpt[gi]  = cmt_chain[gi] & nq[slot_idx[gi]][NQ_CKV];
        assign cmt_st_branch[gi]= cmt_chain[gi] & nq[slot_idx[gi]][NQ_BR];
    end
    endgenerate

    // 异常：仅当该槽已完成且为头部（slot 0）
    assign trap_valid = slot_in_range[0] & slot_done[0] & slot_exc[0] & win_lane_ok[0];
    assign trap_pc    = win_q[slot_idx[0][2:0]][`BACK2_RB_PC_MSB:`BACK2_RB_PC_LSB];
    assign trap_cause = nq[slot_idx[0]][NQ_EXC_L +: 4];
    //   ★★ EXP-B：mtval 取 ex 表（LSU 数据侧异常）或**载荷 TVAL**（派发期异常：非法指令的
    //     原始指令位 / 取指异常的故障 VA）——判据与提交侧 `ex_use` 同源（`ex_use[0]`）。
    assign trap_tval  = ex_use[0] ? ex_tval_q[slot_idx[0]]
                                  : win_q[slot_idx[0][2:0]][`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB];

    //==========================================================================
    // 4. 观测输出
    //==========================================================================
    //   ★ ② CSR 提交合成**单 lane 动态读口**：只读被选中的那一项（而非 4 lane 全读）
    //   ★★ EXP-B：`tval` 段（= 原始指令位，判 zimm 形式用）改从**载荷 `BACK2_RB_TVAL`** 取；
    //      `csrw` 段（其低 PW_I 位 = 该 CSR 指令自己的 PS1I）改从**载荷 uop.PS1I** 取 ——
    //      两者在拆分前分别等于 `updq.TVAL` 与 `updq.CSRW`（后者从不被回写，恒为派发期
    //      `{25'b0, PS1I}`）⇒ 对外 79 bit 布局与语义**逐位不变**，且不再需要 64 项 32 bit 表。
    //   ★★ EXP-R2：`csrw` 段仍是**零扩展的 32 bit 字段** —— 填充宽度由 `BACK2_PREG_I_W`
    //      算出（不再写死 25'b0）。若仍写 25'b0，整条 79 bit 拼接会缩短 1 bit ⇒
    //      tval/csra/csrop 全体错位（backend_top 按 [78:47]/[46:15]/[14:3]/[2:0] 取段）。
    assign csr_pay = { win_q[csr_lane_idx[2:0]][`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB],
                       {{(32-`BACK2_PREG_I_W){1'b0}},
                        win_q[csr_lane_idx[2:0]][`BACK2_RB_PS1I_MSB:`BACK2_RB_PS1I_LSB]},
                       win_q[csr_lane_idx[2:0]][`BACK2_RB_CSRADDR_MSB:`BACK2_RB_CSRADDR_LSB],
                       win_q[csr_lane_idx[2:0]][`BACK2_RB_CSROP_MSB:`BACK2_RB_CSROP_LSB] };

    assign head_o      = head_q;
    assign cnt_o       = cnt_q;
    assign empty_o     = (cnt_q == 0);
    assign head_done_o = nq[head_q][NQ_DONE];
    assign head_exc_o  = nq[head_q][NQ_EXC_L +: 4];
    assign cmt_cnt_o   = cmt_cnt_q;
    assign epoch_o     = epoch_q;

    //==========================================================================
    // 5. 时序：分配 / 完成 / 字段回写 / 提交 / 冲刷
    //==========================================================================
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q    <= {ROB_IDX_W{1'b0}};
            cnt_q     <= {(ROB_IDX_W+1){1'b0}};
            cmt_cnt_q <= 32'h0;
            epoch_q   <= {`BACK2_EPOCH_W{1'b0}};
            for (k = 0; k < 8; k = k + 1) begin
                win_q[k]   <= {RB_W{1'b0}};
                win_idx[k] <= {ROB_IDX_W{1'b0}};
                win_val[k] <= 1'b0;
            end
            for (k = 0; k < PF_W; k = k + 1) e_of_r_q[k] <= {ROB_IDX_W{1'b0}};
            for (k = 0; k < ROB_N; k = k + 1) begin
                nq[k]     <= {NQ_W{1'b0}};
                //   ★★ EXP-B：三张 typed 表只复位 {valid, epoch}（数据数组在 valid=0 时被
                //     merge 的回落支路屏蔽 ⇒ 无 x 传播；不置复位也让综合更容易落 LUTRAM）
                br_v_q[k]  <= 1'b0;  br_ep_q[k]  <= {`BACK2_TBL_EP_W{1'b0}};
                ff_v_q[k]  <= 1'b0;  ff_ep_q[k]  <= {`BACK2_TBL_EP_W{1'b0}};
                ex_v_q[k]  <= 1'b0;  ex_ep_q[k]  <= {`BACK2_TBL_EP_W{1'b0}};
            end
        end else begin
            // ---- 5.1 派发写入（新项：done 清零；仅真正派发拍 = alloc_fire）----
            //   ★★ EXP-N1：本循环是**分配侧** ⇒ 上界 = ALLOC_W（=4，派发宽度未变）。
            if (alloc_fire) begin
                for (k = 0; k < ALLOC_W; k = k + 1) begin
                    if (alloc_lane_valid[k] & (k < alloc_n)) begin
`ifndef RV32GC_USE_VIVADO_IP
                        //   ★ C4：CSRW 段已从载荷删除 ⇒ 探针改打「CSR 源」= 载荷 PS1I
                        //     （提交级 `csr_pay` 的 csrw 段正是由它拼出，语义等价）。
                        if (DBG_CSR) $display("[rob-alloc t=%0t] k=%0d idx=%0d pay_ps1i=0x%02x", $time, k, idx_add(tail_w, k[ROB_IDX_W:0]), alloc_payload[k*RB_W + `BACK2_RB_PS1I_LSB +: `BACK2_PREG_I_W]);
`endif
                        nq[idx_add(tail_w, k[ROB_IDX_W:0])] <=
                            pack_nq(alloc_payload[k*RB_W +: RB_W], alloc_epoch, 1'b0,
                                    alloc_pre[k*5 +: 5]);
                        //   ★★ EXP-B：派发期**不再**把可更新字段复制进更新表 —— 三张 typed 表
                        //     只由各自的执行部件写（BRU/FPU/LSU），派发写只落 `nq` 与 BRAM 载荷。
                    end
                end
            end

            // ---- 5.2 写回置 done ----
            //   ★ epoch 过滤必须比**项内记录的分配时 epoch**，而不是全局当前 epoch：
            //     冲刷（squash）会保留"比分支更老"的项，而这些项可能**正在执行中**
            //     （已在 IQ 发射、1~2 拍后写回）。它们的写回带的是**发射时**的 epoch，
            //     若拿全局 epoch 比就会全部被过滤 ⇒ 这些项永远不 done ⇒ ROB 头卡死
            //     且无任何在飞指令（实测：head pc=0x8000_0044、hdone=0、IQ 全空、永久停顿）。
            //   按项内 epoch 比较同时保留原目标：索引被新项复用后，旧写回 epoch 与新项
            //     epoch 不同 ⇒ 不会给新项误置 done（03 §8.2）。
            for (k = 0; k < WB_N; k = k + 1) begin
                if (wb_valid[k] &&
                    (wb_epoch[k*`BACK2_EPOCH_W +: `BACK2_EPOCH_W] ==
                     nq[wb_rob_idx[k*ROB_IDX_W +: ROB_IDX_W]][NQ_EP_L +: `BACK2_EPOCH_W]))
                    nq[wb_rob_idx[k*ROB_IDX_W +: ROB_IDX_W]][NQ_DONE] <= 1'b1;
            end

            // ---- 5.3 ★★ EXP-B：三张 typed 表写入（**每表恰好一个写源** ⇒ 无共享写口/无仲裁）----
            //   写口与该项的写回（5.2 置 done）**同沿**：此时该项尚未提交 ⇒ 索引不可能被复用
            //   ⇒ `nq[idx].epoch` 就是该项自己的 epoch（写入口径 == 提交比对口径）。
            if (upd_tr_valid) begin
                nq[upd_tr_idx][NQ_TRT]   <= upd_tr_taken;   // 提交侧 `tcp_tk` 仍吃 nq（保持原状）
                br_v_q[upd_tr_idx]       <= 1'b1;
                br_ep_q[upd_tr_idx]      <= nq[upd_tr_idx][NQ_EP_L +: `BACK2_EPOCH_W];
                br_tgt_q[upd_tr_idx]     <= upd_tr_target;
                br_taken_q[upd_tr_idx]   <= upd_tr_taken;
            end
            if (upd_ff_valid) begin
                ff_v_q[upd_ff_idx]       <= 1'b1;
                ff_ep_q[upd_ff_idx]      <= nq[upd_ff_idx][NQ_EP_L +: `BACK2_EPOCH_W];
                ff_q[upd_ff_idx]         <= upd_ff_flags;
            end
            if (upd_exc_valid) begin
                nq[upd_exc_idx][NQ_EXC_L +: 4] <= upd_exc_code;
                ex_v_q[upd_exc_idx]      <= 1'b1;
                ex_ep_q[upd_exc_idx]     <= nq[upd_exc_idx][NQ_EP_L +: `BACK2_EPOCH_W];
                ex_tval_q[upd_exc_idx]   <= upd_exc_tval;
            end

            // ---- 5.35 ★ B3：头部窗口填充（上一拍发出的预取读在本拍到达）----
            //   读口 i 对应项 `e_of_r_q[i]`（上一拍的 head_pred 算出）⇒ 写入槽 `[2:0]`、打全索引标签、置有效。
            //   ★★ EXP-N1：本循环是**预取侧** ⇒ 上界 = PF_W（=4，不随 COMMIT_W 变化）。
            for (k = 0; k < PF_W; k = k + 1) begin
                //   危险判定：该项是否在“读命令发出的那一拍”刚好被分配写入
                if (|dang_hit[k]) begin
                    if (win_val[e_of_r_q[k][2:0]] & (win_idx[e_of_r_q[k][2:0]] == e_of_r_q[k]))
                        win_val[e_of_r_q[k][2:0]] <= 1'b0;      // 旧内容不可用 ⇒ 置无效
                end else begin
                    win_q  [e_of_r_q[k][2:0]] <= pl_rdata[k];
                    win_idx[e_of_r_q[k][2:0]] <= e_of_r_q[k];
                    win_val[e_of_r_q[k][2:0]] <= 1'b1;
                end
            end
            //   预取地址打拍（下一拍用它给读回的数据定标签）
            for (k = 0; k < PF_W; k = k + 1) e_of_r_q[k] <= idx_add(hpred_w, {{5{1'b0}}, rsel[k]});
            //   记下本拍分配的索引（下一拍用于上面的危险判定）
            //   ★★ EXP-N1：分配槽数 = ALLOC_W（派发宽度，未变）。
            for (k = 0; k < ALLOC_W; k = k + 1) begin
                alloc_idx_q[k]   <= idx_add(tail_w, k[ROB_IDX_W-1:0]);
                alloc_idx_v_q[k] <= alloc_fire & alloc_lane_valid[k] & (k < alloc_n);
            end

            // ---- 5.4 指针推进（提交 / 冲刷 / 分配）----
            if (flush_all) begin
                for (k = 0; k < 8; k = k + 1) win_val[k] <= 1'b0;   // ★ 冲刷后窗口不可信
                cnt_q   <= {(ROB_IDX_W+1){1'b0}};
                //   ★ 陷阱退役：头部异常项**弹出**（其余全清）；否则只清 cnt（原口径）
                head_q  <= trap_retire ? idx_add(head_q, {{ROB_IDX_W-1{1'b0}}, 1'b1})
                                       : {ROB_IDX_W{1'b0}};
                epoch_q <= epoch_q + 1'b1;
            end else if (squash_valid) begin
                epoch_q <= epoch_q + 1'b1;
                // 保留 [head, squash_idx]（含分支自身）
                //   ★ C8：改用 §1.1 的唯一年龄计算点（原为就地重算 `squash_idx - head_q`）
                cnt_q <= {1'b0, age_sq_w} + {{ROB_IDX_W{1'b0}}, 1'b1};
            end else begin
                head_q <= idx_add(head_q, cmt_n_w);
                cnt_q  <= cnt_q - {5'b0, cmt_n_w}
                          + (alloc_fire ? {5'b0, alloc_n} : {(ROB_IDX_W+1){1'b0}});
                if (cmt_chain[0]) cmt_cnt_q <= cmt_cnt_q + {29'b0, cmt_n_w};
            end
        end
    end

    //   ★ 2B-5 第 3 步①自检：窄表与宽载荷的共用字段必须**逐位一致**
    //     （迁移期双写；任何漏写/写错位置都会在此报出）。
    //   ★★ 2B-5 第 3 步②（自检 `ifdef` 化）：整个自检块只做 `$display`（无任何 RTL 语义），
    //     但综合侧仍要解析 `if (DBG_CSR && ...)` 并在参数为 0 时做常量折叠。本步把它**整体**
    //     收进 `` `ifndef RV32GC_USE_VIVADO_IP ``（综合入口 `synth_design` 显式定义该宏，
    //     见 fpga/tcl/synth.tcl；iverilog/Verilator 回归从不定义 ⇒ 行为模型侧自检**保持等价**）
    //     ⇒ 综合分支连语句都不存在，零残留、零依赖综合器的折叠能力。
    //   ★ B2 后自检口径：宽载荷已入 BRAM，改在**预取填充拍**对比：
    //     读回的载荷拼出的窄字段 必须等于 `nq`（掩掉由 `upd_exc` 写的 `exc[3:0]`）。
`ifndef RV32GC_USE_VIVADO_IP
    integer nk;
    reg [NQ_W-1:0] nq_chk;
    always @(posedge clk) begin
        if (DBG_CSR && rst_n) begin
            for (nk = 0; nk < 4; nk = nk + 1) begin
                //   仅在"本拍真的可用"时比对：
                //     ① 该索引不是本拍/上拍刚分配的（read_first 会读到旧值）
                //     ② 该项在 ROB 当前范围内（否则读到的是无效位）
                //     ③ `trtaken` 与 `exc` 由 `upd_tr/upd_exc` 写入 `nq`（载荷侧不再更新）⇒ 掩掉
                if (!(alloc_idx_v_q[0] & (alloc_idx_q[0] == e_of_r_q[nk]) |
                      alloc_idx_v_q[1] & (alloc_idx_q[1] == e_of_r_q[nk]) |
                      alloc_idx_v_q[2] & (alloc_idx_q[2] == e_of_r_q[nk]) |
                      alloc_idx_v_q[3] & (alloc_idx_q[3] == e_of_r_q[nk])) &&
                    (((e_of_r_q[nk] - head_q) & 7'h7F) < cnt_q)) begin
                    nq_chk = pack_nq(pl_rdata[nk], nq[e_of_r_q[nk]][NQ_EP_L +: `BACK2_EPOCH_W], 1'b0,
                                     nq[e_of_r_q[nk]][NQ_MK_L +: 5]);
                    if ((nq[e_of_r_q[nk]][NQ_W-1:NQ_TRT+1]   !== nq_chk[NQ_W-1:NQ_TRT+1]) ||
                        (nq[e_of_r_q[nk]][NQ_TRT-1:NQ_EXC_L+4] !== nq_chk[NQ_TRT-1:NQ_EXC_L+4]) ||
                        (nq[e_of_r_q[nk]][NQ_EXC_L-1:1]        !== nq_chk[NQ_EXC_L-1:1]))
                        $display("ROB-NQ-CHK MISMATCH: idx=%0d nq=0x%011x pay=0x%011x",
                                 e_of_r_q[nk], nq[e_of_r_q[nk]], nq_chk);
                end
            end
        end
    end
`endif

    //==========================================================================
    // 6. ★★ EXP-B §29：typed 表 assertion（仿真专属；`ifndef RV32GC_USE_VIVADO_IP`）
    //==========================================================================
    //   ① 写口自检（单写源正确性）：上一拍的三个写口必须**逐位落到对应表**（valid/epoch/数据）。
    //      —— 三张表各只有一个写源（`br_q`←upd_tr / `ff_q`←upd_ff / `ex_q`←upd_exc），
    //      故同拍 br/ff/exc 写**不同表绝不冲突**（结构上各自独立写口，无需任何仲裁）；
    //      本自检即该不变式的逐拍证据（含"同拍多表写同一索引"的边界拍）。
    //   ② 采用不变式：提交的分支必有 br 表命中；提交的 FP 必有 ff 表命中；
    //      头部陷阱且"派发期无异常、现异常"（⇒ 异常由 LSU 回写）必有 ex 表命中。
    //      ⚠ `commit_exc → ex_v_q` 不能用 `cmt_valid` 作前件：`slot_ok` 已含 `~slot_exc`
    //        ⇒ 带异常项**永不提交**，其断言锚点只能是 `trap_valid`（头部精确陷阱点）。
    //   失败打印一律带 `ROB-ASSERT` 字样（判定脚本按该字样判失败，兜底文案不含 PASS）。
`ifndef RV32GC_USE_VIVADO_IP
    integer bk;
    reg                    w_br_v, w_ff_v, w_ex_v;
    reg [ROB_IDX_W-1:0]    w_br_i, w_ff_i, w_ex_i;
    reg [`BACK2_BR_TAKEN_W-1:0] w_br_tk;
    reg [`BACK2_BR_TGT_W-1:0]   w_br_tg;
    reg [`BACK2_FF_W-1:0]       w_ff_d;
    reg [`BACK2_EX_TVAL_W-1:0]  w_ex_tv;
    reg [`BACK2_EPOCH_W-1:0]    w_br_ep, w_ff_ep, w_ex_ep;
    //   ⚠ 本块的"写口影子"必须**随异步复位清零**：否则复位前采到的写口会在复位后的
    //     第一个 posedge 与（已被复位清零的）表内容比对 ⇒ 程序边界的假失败（实测过）。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_br_v <= 1'b0; w_ff_v <= 1'b0; w_ex_v <= 1'b0;
        end else begin
            // ---- ① 写口自检（核对上一拍的写）----
            if (w_br_v) begin
                if (br_v_q[w_br_i]   !== 1'b1)          $display("ROB-ASSERT-BR FAIL: valid  idx=%0d", w_br_i);
                if (br_ep_q[w_br_i]  !== w_br_ep)       $display("ROB-ASSERT-BR FAIL: epoch  idx=%0d", w_br_i);
                if (br_tgt_q[w_br_i] !== w_br_tg)       $display("ROB-ASSERT-BR FAIL: tgt    idx=%0d", w_br_i);
                if (br_taken_q[w_br_i] !== w_br_tk)     $display("ROB-ASSERT-BR FAIL: taken  idx=%0d", w_br_i);
            end
            if (w_ff_v) begin
                if (ff_v_q[w_ff_i]   !== 1'b1)          $display("ROB-ASSERT-FF FAIL: valid  idx=%0d", w_ff_i);
                if (ff_ep_q[w_ff_i]  !== w_ff_ep)       $display("ROB-ASSERT-FF FAIL: epoch  idx=%0d", w_ff_i);
                if (ff_q[w_ff_i]     !== w_ff_d)        $display("ROB-ASSERT-FF FAIL: flags  idx=%0d", w_ff_i);
            end
            if (w_ex_v) begin
                if (ex_v_q[w_ex_i]   !== 1'b1)          $display("ROB-ASSERT-EX FAIL: valid  idx=%0d", w_ex_i);
                if (ex_ep_q[w_ex_i]  !== w_ex_ep)       $display("ROB-ASSERT-EX FAIL: epoch  idx=%0d", w_ex_i);
                if (ex_tval_q[w_ex_i] !== w_ex_tv)      $display("ROB-ASSERT-EX FAIL: tval   idx=%0d", w_ex_i);
            end
            // ---- ② 采用不变式（提交组 4 lane）----
            for (bk = 0; bk < COMMIT_W; bk = bk + 1) begin
                if (cmt_valid[bk] & slot_is_br[bk] & ~br_use[bk])
                    $display("ROB-ASSERT-BR FAIL: commit branch without br table t=%0t lane=%0d idx=%0d",
                             $time, bk, slot_idx[bk]);
                if (cmt_valid[bk] & slot_is_fp[bk] & ~ff_use[bk])
                    $display("ROB-ASSERT-FF FAIL: commit fp without ff table t=%0t lane=%0d idx=%0d",
                             $time, bk, slot_idx[bk]);
            end
            if (trap_valid & (|nq[slot_idx[0]][NQ_EXC_L +: 4])
                           & (win_rd[0][`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB] == 4'd0)
                           & ~ex_use[0])
                $display("ROB-ASSERT-EX FAIL: trap with LSU exc but no ex table t=%0t idx=%0d",
                         $time, slot_idx[0]);
            // ---- 采样本拍三个写口（下一拍核对）----
            w_br_v  <= upd_tr_valid;
            w_br_i  <= upd_tr_idx;
            w_br_ep <= nq[upd_tr_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            w_br_tg <= upd_tr_target;
            w_br_tk <= upd_tr_taken;
            w_ff_v  <= upd_ff_valid;
            w_ff_i  <= upd_ff_idx;
            w_ff_ep <= nq[upd_ff_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            w_ff_d  <= upd_ff_flags;
            w_ex_v  <= upd_exc_valid;
            w_ex_i  <= upd_exc_idx;
            w_ex_ep <= nq[upd_exc_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            w_ex_tv <= upd_exc_tval;
        end
    end

    //   ★★ EXP-B：载荷占位字段恒 0 自检 —— `merge_upd` 的 br/ff 回落支路用**常量 0**
    //     的前提（载荷 [405:401]/[400]/[399:368] 只有派发一个写源、恒写 5'b0/1'b0/32'h0，
    //     见 `backend_top.v` 的 ROB 载荷组装式）。口径与上面的 nq 自检一致：只在"该索引
    //     非本拍/上拍刚分配"且"在 ROB 当前范围内"时比对（否则读到的是无效/旧值）。
    integer zk;
    always @(posedge clk) begin
        if (rst_n) begin
            for (zk = 0; zk < 4; zk = zk + 1) begin
                if (!(alloc_idx_v_q[0] & (alloc_idx_q[0] == e_of_r_q[zk]) |
                      alloc_idx_v_q[1] & (alloc_idx_q[1] == e_of_r_q[zk]) |
                      alloc_idx_v_q[2] & (alloc_idx_q[2] == e_of_r_q[zk]) |
                      alloc_idx_v_q[3] & (alloc_idx_q[3] == e_of_r_q[zk])) &&
                    (((e_of_r_q[zk] - head_q) & 7'h7F) < cnt_q)) begin
                    if ((pl_rdata[zk][`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB] !== 5'h0) ||
                        (pl_rdata[zk][`BACK2_RB_TRTAKEN] !== 1'b0) ||
                        (pl_rdata[zk][`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB] !== 32'h0))
                        $display("ROB-ASSERT-PAY0 FAIL: 载荷占位字段非 0（merge 回落常量前提被破坏）idx=%0d fflags=%b trtaken=%b trtgt=0x%08x",
                                 e_of_r_q[zk],
                                 pl_rdata[zk][`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB],
                                 pl_rdata[zk][`BACK2_RB_TRTAKEN],
                                 pl_rdata[zk][`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB]);
                end
            end
        end
    end
`endif

endmodule
