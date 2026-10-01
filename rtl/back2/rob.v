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
//   uop(272) + CSR 新值 + 异常 tval + 分支实际方向/目标 + 浮点 flags + store 队列索引。
//
// 风格  : 组合逻辑全部 `assign`/函数（红线 3）；always 块只用于存储体与指针（时序元件）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module rob #(
    parameter integer ROB_N      = `BACK2_ROB_N,
    parameter integer ROB_IDX_W  = `BACK2_ROB_IDX_W,
    parameter integer COMMIT_W   = `BACK2_COMMIT_W,
    parameter integer RB_W       = `BACK2_RB_W,
    parameter integer WB_N       = `BACK2_WB_N,
    parameter integer DBG_CSR    = 0        // B29 定案探针
) (
    input  wire                    clk,
    input  wire                    rst_n,

    //==================================================================
    // 派发（D3）：连续 COMMIT_W 项（lane 0 最老）
    //==================================================================
    input  wire                    alloc_valid,
    input  wire [2:0]              alloc_n,          // 1..COMMIT_W
    output wire                    alloc_ready,      // 余量 ≥ alloc_n
    output wire [ROB_IDX_W-1:0]    alloc_idx0,       // 本块首项索引
    input  wire [COMMIT_W-1:0]     alloc_lane_valid,
    input  wire [COMMIT_W*RB_W-1:0] alloc_payload,
    input  wire [`BACK2_EPOCH_W-1:0] alloc_epoch,     // 本块分配时的流世代（存入项内）

    //==================================================================
    // 完成（写回口）：置 done
    //==================================================================
    input  wire [WB_N-1:0]                 wb_valid,
    input  wire [WB_N*ROB_IDX_W-1:0]       wb_rob_idx,
    input  wire [WB_N*`BACK2_EPOCH_W-1:0]  wb_epoch,     // §8.2 epoch：过期写回不得置 done

    //==================================================================
    // 执行期字段回写（每个至多 1 路/拍；本里程碑够用）
    //==================================================================
    input  wire                    upd_csr_valid,
    input  wire [ROB_IDX_W-1:0]    upd_csr_idx,
    input  wire [31:0]             upd_csr_wdata,
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
    input  wire [COMMIT_W*5-1:0] alloc_pre,
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
    reg  [RB_W-1:0]      win_q   [0:7];       // ★ B3：头部窗口（先存全字；B4 可按 100 bit 形态收窄）
    reg  [ROB_IDX_W-1:0] win_idx [0:7];       // 每槽 7 bit 全索引标签
    reg                  win_val [0:7];       // 每槽有效（复位/冲刷清零）
    reg  [ROB_IDX_W-1:0] e_of_r_q[0:3];       // 预取读地址的**打拍版**（读数据下一拍到达时用它定标签）
    //   ★★ 危险修正（p11 实测）：BRAM 为 `read_first` ⇒ "同拍被写的项，当拍读到旧值"。
    //     若预取地址正好是本拍刚分配的项（ROB 近空：清洗后 head≈tail），窗口会被填入**旧载荷**
    //     但标签恰好命中 ⇒ 会交付错误 PC。修法：记下**上一拍的分配索引**，填充时若命中则
    //     **丢弃本次填充并把该槽置为无效**（下一拍重读即可）；冲刷时也全部置无效。
    reg  [ROB_IDX_W-1:0] alloc_idx_q[0:3];
    reg  [3:0]           alloc_idx_v_q;
    wire [RB_W-1:0]      pl_rdata[0:3];       // 4 bank 同步读回数据
    wire [1:0]           wsel    [0:3];       // 写轮转：bank i 对应的 lane 序号 = (i - tail[1:0]) & 3
    wire [1:0]           rsel    [0:3];       // 读轮转：读口 i 对应的项序号 = (i - head_pred[1:0]) & 3
    //   ★★ 2B-5 第 3 步①：**窄控制表** `nq`（FF 阵列，组合读）
    //     · 收编原 `done_q` + `rep_q`（epoch）+ 提交/前缀链/排空/陷阱判定所需的控制位与索引；
    //     · **宽字段（PC/TVAL/CSRW/TRTGT/FFLAGS 等）仍在 `pl_q`**，本步不动；
    //     · 本步将 rob.v **自用的关键读**（done/exc/is_store/ckpt/is_branch/trap_cause/epoch）
    //       全部改走 `nq`（行为逐位等价），并导出 `cmt_narrow` 供下一步改造 backend_top。
    //     字段布局（MSB→LSB）：
    //       lq[3:0] stq[4:0] trtaken csrop[2:0] pdf[5:0] pdi[6:0] arn[4:0]
    //       is_csr is_fp_wen is_int_wen ckpt_valid is_branch is_store exc[3:0] epoch[1:0] done
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
    localparam integer NQ_CSROP_L= `BACK2_NQ_CSROP_L;
    localparam integer NQ_TRT    = `BACK2_NQ_TRT;
    localparam integer NQ_STQ_L  = `BACK2_NQ_STQ_L;
    localparam integer NQ_LQ_L   = `BACK2_NQ_LQ_L;
    localparam integer NQ_MK_L   = `BACK2_NQ_MK_L;
    reg  [NQ_W-1:0]      nq    [0:ROB_N-1];
    //   ★★ 2B-5 B2/B3 前置：**可更新字段独立 FF 表** `updq`（载荷的 [405:304] = 102 bit）
    //     · 动机：BRAM 分 bank 后每 bank 只有 **1 个写口**，4 条派发写已占满 ⇒ 字段回写只能落在 FF 表；
    //     · 本步先把它们**从 `pl_q` 的写入里拿走**（`pl_q` 只剩派发写：对应位自动被 Vivado 裁掉），
    //       读取时用 `merge_upd()` 拼回原坐标 ⇒ **对外接口与行为逐位不变**；
    //     · 这也是下一步“`pl_q` 整体换 `rob_wide_mem` + 头部窗口”的前提（到那时 `pl_q` 只剩派发写、可直接换成 DRAM）。
    reg  [`BACK2_UPDQ_W-1:0] updq [0:ROB_N-1];

    //   拼接：取 `pl_q` 的不可更新部分 + `updq` 的可更新部分（纯布线，无 mux）
    function [RB_W-1:0] merge_upd;
        input [RB_W-1:0] pl; input [`BACK2_UPDQ_W-1:0] ud;
        begin
            merge_upd = { pl[RB_W-1:`BACK2_UPD_PAY_LSB+`BACK2_UPDQ_W],
                          ud,
                          pl[`BACK2_UPD_PAY_LSB-1:0] };
        end
    endfunction

    //   打包：从宽载荷 + epoch + done 生成窄字（分配与一致性自检共用）
    function [NQ_W-1:0] pack_nq;
        input [RB_W-1:0] p; input [`BACK2_EPOCH_W-1:0] ep; input dn; input [4:0] pre;
        begin
            pack_nq = { pre,                                           // [48:44] {mret,sret,maint_kind}
                        p[`BACK2_RB_LQ_MSB:`BACK2_RB_LQ_LSB],          // [43:40]（2B-5 L5：LQ 16 ⇒ 4 bit）
                        p[`BACK2_RB_STQ_MSB:`BACK2_RB_STQ_LSB],        // [39:35]
                        p[`BACK2_RB_TRTAKEN],                          // [34]
                        p[`BACK2_U_CSROP_MSB:`BACK2_U_CSROP_LSB],      // [33:31]
                        p[`BACK2_U_PDFDST_MSB:`BACK2_U_PDFDST_LSB],    // [30:25]
                        p[`BACK2_U_PDIDST_MSB:`BACK2_U_PDIDST_LSB],    // [24:18]
                        p[`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB],        // [17:13]
                        p[`BACK2_UB_IS_CSR],                           // [12]
                        p[`BACK2_UB_RD_F_WEN],                         // [11]
                        p[`BACK2_UB_RD_I_WEN],                         // [10]
                        p[`BACK2_UB_CKPT_VALID],                       // [9]
                        p[`BACK2_UB_IS_BRANCH],                        // [8]
                        p[`BACK2_UB_IS_STORE],                         // [7]
                        p[`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB],          // [6:3]
                        ep,                                            // [2:1]
                        dn };                                          // [0]
        end
    endfunction
    //   ★ 项内 epoch 单独放一个 2 bit 小数组（而不是塞进 416 bit 载荷）：
    //     载荷内的字段要在"时钟块里按 7 个写回索引读" ⇒ iverilog 会展开成
    //     7×(ROB_N×416) 的组合读森林，仿真吞吐直接掉一个数量级（实测 ~12× 变慢）。
    reg  [`BACK2_EPOCH_W-1:0] rep_q [0:ROB_N-1];
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
    // 1.5 ★ B2/B3：BRAM 写/读轮转 + 头部窗口
    //==========================================================================
    //   派发 4 条 lane 索引连续（tail..tail+3），提交/预取 4 项索引也连续（head..head+3）
    //   ⇒ 两边都是 "{0,1,2,3} 的旋转"，bank=i 的写/读只需选择对应那一项。
    wire [ROB_IDX_W-1:0] hpred_w = idx_add(head_q, {4'b0, cmt_n_w});
    genvar gw;
    generate
    for (gw = 0; gw < 4; gw = gw + 1) begin : g_rot
        assign wsel[gw] = gw[1:0] - tail_w[1:0];
        assign rsel[gw] = gw[1:0] - hpred_w[1:0];
    end
    endgenerate

    //   窗口读（提交组每 lane 一个 8:1 mux）+ 命中判定
    wire [RB_W-1:0] win_rd [0:3];
    wire [3:0]      win_lane_ok;
    generate
    for (gw = 0; gw < 4; gw = gw + 1) begin : g_winrd
        wire [ROB_IDX_W-1:0] ei = idx_add(head_q, gw[ROB_IDX_W-1:0]);
        assign win_rd[gw]      = win_q[ei[2:0]];
        assign win_lane_ok[gw] = win_val[ei[2:0]] & (win_idx[ei[2:0]] == ei);
    end
    endgenerate

    //   BRAM 实例（B1 交付的模块：4 bank × SDP，同步读）
    wire [3:0]        bw_we;
    wire [4*5-1:0]    bw_woff, bw_roff;
    wire [4*RB_W-1:0] bw_wdata, bw_rdata;
    generate
    for (gw = 0; gw < 4; gw = gw + 1) begin : g_bw
        //   （函数返回值不能直接做位选（iverilog）⇒ 先存临时线）
        wire [ROB_IDX_W-1:0] wt = idx_add(tail_w,  {{5{1'b0}}, wsel[gw]});
        wire [ROB_IDX_W-1:0] rt = idx_add(hpred_w, {{5{1'b0}}, rsel[gw]});
        assign bw_we[gw]   = alloc_fire & alloc_lane_valid[wsel[gw]] & (wsel[gw] < alloc_n);
        assign bw_woff[gw*5 +: 5] = wt[ROB_IDX_W-1:2];
        assign bw_wdata[gw*RB_W +: RB_W] = alloc_payload[wsel[gw]*RB_W +: RB_W];
        assign bw_roff[gw*5 +: 5] = rt[ROB_IDX_W-1:2];
        assign pl_rdata[gw] = bw_rdata[gw*RB_W +: RB_W];
    end
    endgenerate

    rob_wide_mem #(.NW(4), .BW(32), .DW(RB_W), .AW(ROB_IDX_W), .OW(5), .CHK(0)) u_wmem (
        .clk(clk), .rst_n(rst_n),
        .we(bw_we), .woff(bw_woff), .wdata(bw_wdata),
        .re(4'hF),  .roff(bw_roff), .rdata(bw_rdata));

    // 提交链（先算，用于同拍释放余量）
    wire [COMMIT_W-1:0] slot_in_range;
    wire [COMMIT_W-1:0] slot_done;
    wire [COMMIT_W-1:0] slot_exc;
    wire [COMMIT_W-1:0] slot_store;
    wire [COMMIT_W-1:0] slot_st_ok;
    wire [COMMIT_W-1:0] slot_ok;

    wire [ROB_IDX_W-1:0] slot_idx0 = head_q;
    wire [ROB_IDX_W-1:0] slot_idx1 = idx_add(head_q, 1);
    wire [ROB_IDX_W-1:0] slot_idx2 = idx_add(head_q, 2);
    wire [ROB_IDX_W-1:0] slot_idx3 = idx_add(head_q, 3);
    wire [ROB_IDX_W-1:0] slot_idx [0:COMMIT_W-1];
    assign slot_idx[0] = slot_idx0;
    assign slot_idx[1] = slot_idx1;
    assign slot_idx[2] = slot_idx2;
    assign slot_idx[3] = slot_idx3;

    genvar gi;
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
        assign cmt_payload[gi*RB_W +: RB_W] = merge_upd(win_rd[gi], updq[slot_idx[gi]]);
        assign cmt_narrow[gi*NQ_W +: NQ_W]  = nq[slot_idx[gi]];
        assign cmt_st_drain[gi] = cmt_chain[gi] & slot_store[gi];
        assign cmt_st_ckpt[gi]  = cmt_chain[gi] & nq[slot_idx[gi]][NQ_CKV];
        assign cmt_st_branch[gi]= cmt_chain[gi] & nq[slot_idx[gi]][NQ_BR];
    end
    endgenerate

    // 异常：仅当该槽已完成且为头部（slot 0）
    assign trap_valid = slot_in_range[0] & slot_done[0] & slot_exc[0] & win_lane_ok[0];
    assign trap_pc    = win_q[slot_idx0[2:0]][`BACK2_U_PC_MSB:`BACK2_U_PC_LSB];
    assign trap_cause = nq[slot_idx[0]][NQ_EXC_L +: 4];
    assign trap_tval  = updq[slot_idx[0]][`BACK2_UPD_TVAL_LSB +: 32];

    //==========================================================================
    // 4. 观测输出
    //==========================================================================
    //   ★ ② CSR 提交合成**单 lane 动态读口**：只读被选中的那一项（而非 4 lane 全读）
    assign csr_pay = { updq[csr_lane_idx][`BACK2_UPD_TVAL_LSB +: 32],
                       updq[csr_lane_idx][`BACK2_UPD_CSRW_LSB +: 32],
                       win_q[csr_lane_idx[2:0]][`BACK2_U_CSRADDR_MSB:`BACK2_U_CSRADDR_LSB],
                       win_q[csr_lane_idx[2:0]][`BACK2_U_CSROP_MSB:`BACK2_U_CSROP_LSB] };

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
            for (k = 0; k < 4; k = k + 1) e_of_r_q[k] <= {ROB_IDX_W{1'b0}};
            for (k = 0; k < ROB_N; k = k + 1) begin
                nq[k]     <= {NQ_W{1'b0}};
                updq[k]   <= {`BACK2_UPDQ_W{1'b0}};
            end
        end else begin
            // ---- 5.1 派发写入（新项：done 清零；仅真正派发拍 = alloc_fire）----
            if (alloc_fire) begin
                for (k = 0; k < COMMIT_W; k = k + 1) begin
                    if (alloc_lane_valid[k] & (k < alloc_n)) begin
                        if (DBG_CSR) $display("[rob-alloc t=%0t] k=%0d idx=%0d pay_csrw=0x%08x", $time, k, idx_add(tail_w, k[ROB_IDX_W:0]), alloc_payload[k*RB_W + `BACK2_RB_CSRW_MSB -: 32]);
                        nq[idx_add(tail_w, k[ROB_IDX_W:0])] <=
                            pack_nq(alloc_payload[k*RB_W +: RB_W], alloc_epoch, 1'b0,
                                    alloc_pre[k*5 +: 5]);
                        updq[idx_add(tail_w, k[ROB_IDX_W:0])] <=
                            alloc_payload[k*RB_W + `BACK2_UPD_PAY_LSB +: `BACK2_UPDQ_W];
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

            // ---- 5.3 执行期字段回写 ----
            if (upd_csr_valid) begin
                updq[upd_csr_idx][`BACK2_UPD_CSRW_LSB +: 32] <= upd_csr_wdata;
                if (DBG_CSR) $display("[rob-upd t=%0t] idx=%0d wdata=0x%08x", $time, upd_csr_idx, upd_csr_wdata);
            end
            if (upd_tr_valid) begin
                nq[upd_tr_idx][NQ_TRT] <= upd_tr_taken;
                updq[upd_tr_idx][`BACK2_UPD_TRTAKEN] <= upd_tr_taken;
                updq[upd_tr_idx][`BACK2_UPD_TRTGT_LSB +: 32] <= upd_tr_target;
            end
            if (upd_ff_valid) updq[upd_ff_idx][`BACK2_UPD_FFLAGS_LSB +: 5] <= upd_ff_flags;
            if (upd_exc_valid) begin
                nq[upd_exc_idx][NQ_EXC_L +: 4] <= upd_exc_code;
                updq[upd_exc_idx][`BACK2_UPD_TVAL_LSB +: 32] <= upd_exc_tval;
            end

            // ---- 5.35 ★ B3：头部窗口填充（上一拍发出的预取读在本拍到达）----
            //   读口 i 对应项 `e_of_r_q[i]`（上一拍的 head_pred 算出）⇒ 写入槽 `[2:0]`、打全索引标签、置有效。
            for (k = 0; k < 4; k = k + 1) begin
                //   危险判定：该项是否在“读命令发出的那一拍”刚好被分配写入
                if (alloc_idx_v_q[0] & (alloc_idx_q[0] == e_of_r_q[k]) |
                    alloc_idx_v_q[1] & (alloc_idx_q[1] == e_of_r_q[k]) |
                    alloc_idx_v_q[2] & (alloc_idx_q[2] == e_of_r_q[k]) |
                    alloc_idx_v_q[3] & (alloc_idx_q[3] == e_of_r_q[k])) begin
                    if (win_val[e_of_r_q[k][2:0]] & (win_idx[e_of_r_q[k][2:0]] == e_of_r_q[k]))
                        win_val[e_of_r_q[k][2:0]] <= 1'b0;      // 旧内容不可用 ⇒ 置无效
                end else begin
                    win_q  [e_of_r_q[k][2:0]] <= pl_rdata[k];
                    win_idx[e_of_r_q[k][2:0]] <= e_of_r_q[k];
                    win_val[e_of_r_q[k][2:0]] <= 1'b1;
                end
            end
            //   预取地址打拍（下一拍用它给读回的数据定标签）
            for (k = 0; k < 4; k = k + 1) e_of_r_q[k] <= idx_add(hpred_w, {{5{1'b0}}, rsel[k]});
            //   记下本拍分配的索引（下一拍用于上面的危险判定）
            for (k = 0; k < 4; k = k + 1) begin
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
                cnt_q <= {1'b0, (squash_idx - head_q)} + {{ROB_IDX_W{1'b0}}, 1'b1};
            end else begin
                head_q <= idx_add(head_q, cmt_n_w);
                cnt_q  <= cnt_q - {5'b0, cmt_n_w}
                          + (alloc_fire ? {5'b0, alloc_n} : {(ROB_IDX_W+1){1'b0}});
                if (cmt_chain[0]) cmt_cnt_q <= cmt_cnt_q + {29'b0, cmt_n_w};
            end
        end
    end

    //   ★ 2B-5 第 3 步①自检：窄表与宽载荷的共用字段必须**逐位一致**
    //     （迁移期双写；任何漏写/写错位置都会在此报出）。默认关（综合零成本）。
    //   ★ B2 后自检口径：宽载荷已入 BRAM，改在**预取填充拍**对比：
    //     读回的载荷拼出的窄字段 必须等于 `nq`（掩掉由 `upd_exc` 写的 `exc[3:0]`）。
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

endmodule
