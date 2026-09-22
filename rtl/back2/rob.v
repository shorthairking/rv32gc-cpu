//==============================================================================
// rtl/back2/rob.v —— 重排序缓冲（ROB，128 项）：顺序提交 ≤4 条/拍 + 精确异常
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §2.1（字段与环形组织）、§2.2（顺序提交关键路径：
//         ① !done 必须停 ② 异常在头部精确触发 ③ 提交宽度是上限）、§8.1（E1/E2/E3 精确性
//         要点）、§8.2（epoch）；
//         docs/design/02-pipeline.md §3.7（D3 派发：ROB 余量不足 ⇒ 整块停顿 S5）、
//         §3.11（W1 提交）、§5（衔接硬规则 1：ROB 项连续分配）。
//
// 【组织】环形缓冲：head = 提交点、tail = 派发点；`cnt_q` = 有效项数（0..128）。
//   · 项有效性由 (idx - head) mod 128 < cnt 派生 ⇒ **不需要 valid 位数组**，冲刷只需
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
    reg  [RB_W-1:0]      pl_q  [0:ROB_N-1];
    reg                  done_q[0:ROB_N-1];
    //   ★ 项内 epoch 单独放一个 2 bit 小数组（而不是塞进 416 bit 载荷）：
    //     载荷内的字段要在"时钟块里按 7 个写回索引读" ⇒ iverilog 会展开成
    //     7×(128×416) 的组合读森林，仿真吞吐直接掉一个数量级（实测 ~12× 变慢）。
    reg  [`BACK2_EPOCH_W-1:0] rep_q [0:ROB_N-1];
    reg  [ROB_IDX_W-1:0] head_q;
    reg  [ROB_IDX_W:0]   cnt_q;              // 0..ROB_N（8 bit）
    reg  [31:0]          cmt_cnt_q;
    reg  [`BACK2_EPOCH_W-1:0] epoch_q;       // §8.2：冲刷递增；过期写回被过滤

    //==========================================================================
    // 1. 索引派生与余量
    //==========================================================================
    // 环形指针增量：ROB_N 恒为 2 的幂（128）⇒ 截断即取模
    function [ROB_IDX_W-1:0] idx_add(input [ROB_IDX_W-1:0] a, input [ROB_IDX_W:0] d);
        begin idx_add = a + d[ROB_IDX_W-1:0]; end
    endfunction

    wire [ROB_IDX_W-1:0] tail_w = idx_add(head_q, cnt_q);

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
        assign slot_done[gi]     = done_q[slot_idx[gi]];
        assign slot_exc[gi]      = |pl_q[slot_idx[gi]][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB];
        assign slot_store[gi]    = pl_q[slot_idx[gi]][`BACK2_UB_IS_STORE];
        assign slot_st_ok[gi]    = ~slot_store[gi] | mem_wr_ready;
        assign slot_ok[gi]       = slot_in_range[gi] & slot_done[gi] & ~slot_exc[gi] & slot_st_ok[gi];
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
        assign cmt_payload[gi*RB_W +: RB_W] = pl_q[slot_idx[gi]];
        assign cmt_st_drain[gi] = cmt_chain[gi] & slot_store[gi];
        assign cmt_st_ckpt[gi]  = cmt_chain[gi] &
                                  pl_q[slot_idx[gi]][`BACK2_UB_CKPT_VALID];
        assign cmt_st_branch[gi]= cmt_chain[gi] &
                                  pl_q[slot_idx[gi]][`BACK2_UB_IS_BRANCH];
    end
    endgenerate

    // 异常：仅当该槽已完成且为头部（slot 0）
    assign trap_valid = slot_in_range[0] & slot_done[0] & slot_exc[0];
    assign trap_pc    = pl_q[slot_idx[0]][`BACK2_U_PC_MSB:`BACK2_U_PC_LSB];
    assign trap_cause = pl_q[slot_idx[0]][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB];
    assign trap_tval  = pl_q[slot_idx[0]][`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB];

    //==========================================================================
    // 4. 观测输出
    //==========================================================================
    assign head_o      = head_q;
    assign cnt_o       = cnt_q;
    assign empty_o     = (cnt_q == 0);
    assign head_done_o = done_q[head_q];
    assign head_exc_o  = pl_q[head_q][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB];
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
            for (k = 0; k < ROB_N; k = k + 1) begin
                pl_q[k]   <= {RB_W{1'b0}};
                done_q[k] <= 1'b0;
                rep_q[k]  <= {`BACK2_EPOCH_W{1'b0}};
            end
        end else begin
            // ---- 5.1 派发写入（新项：done 清零；仅真正派发拍 = alloc_fire）----
            if (alloc_fire) begin
                for (k = 0; k < COMMIT_W; k = k + 1) begin
                    if (alloc_lane_valid[k] & (k < alloc_n)) begin
                        pl_q[idx_add(tail_w, k[ROB_IDX_W:0])]   <= alloc_payload[k*RB_W +: RB_W];
                        if (DBG_CSR) $display("[rob-alloc t=%0t] k=%0d idx=%0d pay_csrw=0x%08x", $time, k, idx_add(tail_w, k[ROB_IDX_W:0]), alloc_payload[k*RB_W + `BACK2_RB_CSRW_MSB -: 32]);
                        rep_q[idx_add(tail_w, k[ROB_IDX_W:0])] <= alloc_epoch;
                        done_q[idx_add(tail_w, k[ROB_IDX_W:0])] <= 1'b0;
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
                     rep_q[wb_rob_idx[k*ROB_IDX_W +: ROB_IDX_W]]))
                    done_q[wb_rob_idx[k*ROB_IDX_W +: ROB_IDX_W]] <= 1'b1;
            end

            // ---- 5.3 执行期字段回写 ----
            if (upd_csr_valid) begin
                pl_q[upd_csr_idx][`BACK2_RB_CSRW_MSB:`BACK2_RB_CSRW_LSB] <= upd_csr_wdata;
                if (DBG_CSR) $display("[rob-upd t=%0t] idx=%0d wdata=0x%08x", $time, upd_csr_idx, upd_csr_wdata);
            end
            if (upd_tr_valid) begin
                pl_q[upd_tr_idx][`BACK2_RB_TRTAKEN] <= upd_tr_taken;
                pl_q[upd_tr_idx][`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB] <= upd_tr_target;
            end
            if (upd_ff_valid) pl_q[upd_ff_idx][`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB]
                                   <= upd_ff_flags;
            if (upd_exc_valid) begin
                pl_q[upd_exc_idx][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB] <= upd_exc_code;
                pl_q[upd_exc_idx][`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB] <= upd_exc_tval;
            end

            // ---- 5.4 指针推进（提交 / 冲刷 / 分配）----
            if (flush_all) begin
                cnt_q   <= {(ROB_IDX_W+1){1'b0}};
                head_q  <= {ROB_IDX_W{1'b0}};
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

endmodule
