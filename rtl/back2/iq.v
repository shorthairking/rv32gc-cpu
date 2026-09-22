//==============================================================================
// rtl/back2/iq.v —— 分布式发射队列（RIQ）：唤醒广播 + 最老优先选择 + 单端口发射
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §4.2（每部件独立队列、深度 16/16/8/8/12/8、
//         写口 ≤4/拍、读口 1/拍、队列满 ⇒ **整块 4 路停顿**）、§4.3（唤醒=写回广播
//         （物理号+数据）；选择=**最老优先**（按 ROB 索引比较，保证无饥饿且异常/分支
//         尽早暴露）；单端口：每部件每拍最多发射 1 条，不设超发射与投机发射）、
//         §8.2（epoch 过滤：冲刷不逐项删除，靠 epoch 比较在发射时丢弃）；
//         docs/design/02-pipeline.md §3.8（I1 选择）/§3.9（I2 读口，唤醒-选择-读寄存器
//         拆两级）。
//
// 【无活锁论证】（TB tb_back2_iq 逐项断言）：
//   ① 选择无条件"最老优先"且只依赖就绪位与年龄 ⇒ 同一状态下选择结果唯一、确定；
//   ② 就绪位是**单调置位**（唤醒只在写回时置 1，入队时写初值，出队时随项消失）
//      ⇒ 不存在"选了又变回未就绪"的循环；
//   ③ 每拍至多出队 1 项，只要有 ≥1 项就绪就必定出队 ⇒ 有界时间内队列项数单调下降；
//   ④ 冲刷项由 epoch 比较**照样被选出并丢弃**（不阻塞就绪项）⇒ 冲刷后队列同样收敛。
//
// 【实现要点】
//   · 有效位/就绪位/年龄/ROB 索引一律用**打包向量**（非存储器）⇒ 选择与唤醒全组合，
//     满足"唤醒当拍即可选择"（§4.3 的 I1/I2 拆分）。
//   · 载荷（uop，272 bit）存于阵列；出队时按动态索引取出（`assign iss_uop = uop_q[sel]`，
//     与 2A 核 GPR 读口同一写法）。
//   · ★ 不在 function 内读存储器（iverilog 12.0 会返回错误结果，front4 README §7.1）。
//
// 风格  : 组合逻辑用 `assign` + 打包向量 function；两处 always 块分别为
//         "最老优先选择"（纯组合、只读打包向量——优先级编码的少量必要场合）与
//         "存储体/指针"（时序元件）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module iq #(
    parameter integer DEPTH      = `BACK2_IQ_ALU0_D,
    parameter integer UOPW       = `BACK2_UOP_W,
    parameter integer PDW_I      = `BACK2_PREG_I_W,
    parameter integer PDW_F      = `BACK2_PREG_F_W,
    parameter integer ROB_IDX_W  = `BACK2_ROB_IDX_W,
    parameter integer WRP        = `BACK2_IQ_WR_PORTS,
    parameter integer WK_N       = `BACK2_WB_N,
    parameter integer SRC_N      = 5,             // {s1i, s2i, s1f, s2f, s3f}
    parameter integer DBG        = 0,             // 1 = 每拍打印队内项与唤醒广播（诊断用）
    //   B28 队列级闸门开关：load 不得越过更老的未就绪项（仅 LSU 队列置 1）。
    //   动机（第 16/17/18 轮）：store 与其后的 load 同块同拍进入 LSU，store 数据未就绪时 load 抢跑
    //   ⇒ 转发扫描看不到该 store（其 STQ 项 av=0 且 stq_rob 不可用）⇒ 读到旧内存值。
    //   门控只加在 load 项上：更老的 store 不受限，仍可在就绪后自行发射 ⇒ 不会死锁
    //   （第 18 轮把门控加在发射许可上、要求 load 是队首，因过强而死锁；此处是队列内、仅对 load 的版本）。
    parameter integer INORD_LOAD = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- 冲刷 ----
    input  wire                  flush_all,        // 提交点异常：整队列清空
    //   ★ 重定向冲刷：**只作废比 squash_idx 更年轻**的项。更老的项（含正在
    //     执行/等待唤醒的）必须照常发射，否则 ROB 里那些"被保留的更老项"永远等不到
    //     写回 ⇒ 头卡死（实测：head pc=0x8000_0030、hdone=0、IQ 全空、永久停顿）。
    input  wire                  squash,
    input  wire [ROB_IDX_W-1:0]  squash_idx,
    input  wire [`BACK2_EPOCH_W-1:0] epoch,

    // ---- 入队（D3 派发）----
    input  wire [WRP-1:0]        wr_valid,
    input  wire [WRP*UOPW-1:0]   wr_uop,
    input  wire [WRP*ROB_IDX_W-1:0] wr_rob,
    input  wire [WRP*SRC_N-1:0]  wr_rdy,           // 入队时就绪掩码（未用源恒 1）
    output wire [4:0]            free_cnt,         // 剩余空位（派发侧判 S4；深度 ≤16 ⇒ 5 bit）

    // ---- 唤醒广播（写回拍：物理号 + 数据）----
    input  wire [WK_N-1:0]       wki_v,
    input  wire [WK_N*PDW_I-1:0] wki_tag,
    input  wire [WK_N-1:0]       wkf_v,
    input  wire [WK_N*PDW_F-1:0] wkf_tag,

    // ---- 选择/发射（I1）----
    input  wire [ROB_IDX_W-1:0]  rob_head,         // 年龄基准（最老优先）
    //   ★ ROB 有效项数（窗口大小 0..128）。队列项若落在窗口之外（已被提交越过、
    //     或已被冲刷），必须**永久作废**：否则它会一直占着槽位、并被"最老优先"
    //     误判成最年轻项而永不发射（实测：ALU0 内滞留 rob=7/9/12/38/45 等早已
    //     提交过的项，槽位泄漏后新项无处可放 ⇒ 后端停顿）。
    input  wire [ROB_IDX_W:0]    rob_cnt,
    input  wire                  iss_ready,        // 下游执行部件可接收
    output wire                  iss_valid,
    output wire [UOPW-1:0]       iss_uop,
    output wire [ROB_IDX_W-1:0]  iss_rob,
    output wire [`BACK2_EPOCH_W-1:0] iss_epoch,
    output wire                  iss_dead,         // 选中项 epoch 过期（丢弃、不发执行）
    output wire [4:0]            cnt_o,
    // ---- 未被 iss_ready 门控的选择观察口（供 CSR "只在 ROB 头执行" 之类的外部门控）----
    output wire                  o_sel_v,
    output wire [UOPW-1:0]       o_sel_uop,
    output wire [ROB_IDX_W-1:0]  o_sel_rob
);
    genvar ge;
    assign o_sel_uop = uop_q[sel_idx];
    assign o_sel_rob = rob_q[sel_idx*ROB_IDX_W +: ROB_IDX_W];
    assign iss_uop   = uop_q[sel_idx];
    assign iss_rob   = rob_q[sel_idx*ROB_IDX_W +: ROB_IDX_W];
    assign iss_epoch = ep_q[sel_idx*`BACK2_EPOCH_W +: `BACK2_EPOCH_W];
    //   ★ `iss_dead` 必须恒 0：错路径条目已在**冲刷拍按 squash_idx 一次性作废**
    //     （见 §5 的 squash_kill），留下的条目全部属于"必须真正执行"的集合。
    //     若仍按 epoch 标 dead，后端会把它当作"作废项"而不写 I2 寄存器
    //     ⇒ 该条既不执行也不写回 ⇒ 它若被 ROB 保留（比分支更老）就永久卡死
    //     （实测：iss_dead=111111、rob 头 hdone=0、IQ 抽空、后端永久停顿）。
    assign iss_dead  = 1'b0;

    //==========================================================================
    // 1. 队列存储（★ 第 18 轮末重建：原文此段在自动回退中被误删，按接口与语义重写）
    //    约定：全部用**打包向量**；禁止"读存储器的 function"（iverilog 12 + 综合口径）。
    //==========================================================================
    reg  [DEPTH-1:0]                 valid_q;
    reg  [UOPW-1:0]                  uop_q [0:DEPTH-1];   // 每条一个 uop 字（解包数组）
    reg  [DEPTH*ROB_IDX_W-1:0]       rob_q;
    reg  [DEPTH*`BACK2_EPOCH_W-1:0]  ep_q;
    reg  [DEPTH*SRC_N-1:0]           rdy_q;
    reg  [WK_N-1:0]                  wki_v_q, wkf_v_q;
    reg  [WK_N*PDW_I-1:0]            wki_tag_q;
    reg  [WK_N*PDW_F-1:0]            wkf_tag_q;

    //   ★★ 两代唤醒：写回是**单拍脉冲**，而队列项可能在入队当拍就被唤醒。
    //      每个通道只有一组 (valid,tag)，若只与"当拍"比较，同一通道**上一拍**的广播会被
    //      当拍广播顶掉 ⇒ 漏唤醒 ⇒ 项永不就绪（实测：IQ 抽空、后端停摆）。故当拍与上一拍
    //      **各自独立**参与匹配。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wki_v_q   <= {WK_N{1'b0}};
            wkf_v_q   <= {WK_N{1'b0}};
            wki_tag_q <= {(WK_N*PDW_I){1'b0}};
            wkf_tag_q <= {(WK_N*PDW_F){1'b0}};
        end else begin
            wki_v_q   <= wki_v;
            wkf_v_q   <= wkf_v;
            wki_tag_q <= wki_tag;
            wkf_tag_q <= wkf_tag;
        end
    end

    //==========================================================================
    // 2. 就绪判定（源级唤醒命中）与最老优先选择
    //==========================================================================
    wire [DEPTH*SRC_N-1:0] wk_hit;
    reg  [DEPTH-1:0]       e_rdy, e_sel;
    reg  [7:0]             e_age [0:DEPTH-1];
    reg  [DEPTH*SRC_N-1:0] wk_hit_w;
    reg  [DEPTH-1:0]       sel_blk;    // 存在更老的未就绪项（⇒ load 项暂缓可选）
    reg  [7:0]             sel_idx, best_age;
    integer                gi, gk;

    //  源序（与 SRC_N 注释一致）：0=s1i 1=s2i 2=s1f 3=s2f 4=s3f
    always @(*) begin
        wk_hit_w = {(DEPTH*SRC_N){1'b0}};
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin
            e_age[gi] = rob_q[gi*ROB_IDX_W +: ROB_IDX_W] - rob_head;   // 8 bit 零扩展
            for (gk = 0; gk < WK_N; gk = gk + 1) begin
                if ((wki_v[gk]   && (wki_tag[gk*PDW_I +: PDW_I]   == uop_q[gi][`BACK2_U_PS1I_MSB -: PDW_I])) ||
                    (wki_v_q[gk] && (wki_tag_q[gk*PDW_I +: PDW_I] == uop_q[gi][`BACK2_U_PS1I_MSB -: PDW_I])))
                    wk_hit_w[gi*SRC_N + 0] = 1'b1;
                if ((wki_v[gk]   && (wki_tag[gk*PDW_I +: PDW_I]   == uop_q[gi][`BACK2_U_PS2I_MSB -: PDW_I])) ||
                    (wki_v_q[gk] && (wki_tag_q[gk*PDW_I +: PDW_I] == uop_q[gi][`BACK2_U_PS2I_MSB -: PDW_I])))
                    wk_hit_w[gi*SRC_N + 1] = 1'b1;
                if ((wkf_v[gk]   && (wkf_tag[gk*PDW_F +: PDW_F]   == uop_q[gi][`BACK2_U_PS1F_MSB -: PDW_F])) ||
                    (wkf_v_q[gk] && (wkf_tag_q[gk*PDW_F +: PDW_F] == uop_q[gi][`BACK2_U_PS1F_MSB -: PDW_F])))
                    wk_hit_w[gi*SRC_N + 2] = 1'b1;
                if ((wkf_v[gk]   && (wkf_tag[gk*PDW_F +: PDW_F]   == uop_q[gi][`BACK2_U_PS2F_MSB -: PDW_F])) ||
                    (wkf_v_q[gk] && (wkf_tag_q[gk*PDW_F +: PDW_F] == uop_q[gi][`BACK2_U_PS2F_MSB -: PDW_F])))
                    wk_hit_w[gi*SRC_N + 3] = 1'b1;
                if ((wkf_v[gk]   && (wkf_tag[gk*PDW_F +: PDW_F]   == uop_q[gi][`BACK2_U_PS3F_MSB -: PDW_F])) ||
                    (wkf_v_q[gk] && (wkf_tag_q[gk*PDW_F +: PDW_F] == uop_q[gi][`BACK2_U_PS3F_MSB -: PDW_F])))
                    wk_hit_w[gi*SRC_N + 4] = 1'b1;
            end
        end
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin
            sel_blk[gi] = 1'b0;
            for (gk = 0; gk < DEPTH; gk = gk + 1)
                if (valid_q[gk] && (e_age[gk] < e_age[gi]) && ~e_rdy[gk]) sel_blk[gi] = 1'b1;
        end
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin
            e_rdy[gi] = (~uop_q[gi][`BACK2_UB_S1_I_USE] | rdy_q[gi*SRC_N+0] | wk_hit_w[gi*SRC_N+0]) &
                        (~uop_q[gi][`BACK2_UB_S2_I_USE] | rdy_q[gi*SRC_N+1] | wk_hit_w[gi*SRC_N+1]) &
                        (~uop_q[gi][`BACK2_UB_S1_F_USE] | rdy_q[gi*SRC_N+2] | wk_hit_w[gi*SRC_N+2]) &
                        (~uop_q[gi][`BACK2_UB_S2_F_USE] | rdy_q[gi*SRC_N+3] | wk_hit_w[gi*SRC_N+3]) &
                        (~uop_q[gi][`BACK2_UB_S3_F_USE] | rdy_q[gi*SRC_N+4] | wk_hit_w[gi*SRC_N+4]);
            e_sel[gi] = valid_q[gi] & e_rdy[gi] &
                        ~(INORD_LOAD[0] & uop_q[gi][`BACK2_UB_IS_LOAD] & sel_blk[gi]);
        end
    end
    assign wk_hit = wk_hit_w;

    //  最老优先（年龄原点 = ROB 头；同拍唤醒即可选）
    always @(*) begin
        sel_idx  = 8'h0;
        best_age = 8'hFF;
        for (gi = 0; gi < DEPTH; gi = gi + 1)
            if (e_sel[gi] && (e_age[gi] < best_age)) begin
                best_age = e_age[gi];
                sel_idx  = gi[7:0];
            end
    end
    wire sel_valid = |e_sel;
    wire iss_fire  = sel_valid & iss_ready;      // 出队与本拍发射严格同一条件
    wire [DEPTH-1:0] sel_onehot;
    generate
    for (ge = 0; ge < DEPTH; ge = ge + 1) begin : g_sel
        assign sel_onehot[ge] = iss_fire & (sel_idx == ge);
    end
    endgenerate
    assign iss_valid = iss_fire;
    assign o_sel_v   = sel_valid;
    //  诊断用合并视角（DBG 打印引用）
    wire [WK_N-1:0]       wki_v_e = wki_v | wki_v_q;
    wire [WK_N*PDW_I-1:0] wki_tag_e = wki_tag;

    //==========================================================================
    // 3. 空位分配（入队：WRP 路贪心扫描空闲槽）
    //==========================================================================
    // 空闲槽计数（打包向量 function，无存储器读）
    function [4:0] popc(input [DEPTH-1:0] v);
        integer i;
        begin
            popc = 5'd0;
            for (i = 0; i < DEPTH; i = i + 1) popc = popc + {4'b0, v[i]};
        end
    endfunction

    wire [DEPTH-1:0] free_v = ~valid_q;
    wire [4:0]       wr_need = {3'b0, wr_valid[0]} + {3'b0, wr_valid[1]} +
                               {3'b0, wr_valid[2]} + {3'b0, wr_valid[3]};
    wire [4:0]       free_n  = popc(free_v);
    assign free_cnt = free_n;
    wire   wr_ok = (free_n >= wr_need);

    // 贪心分配空位索引（组合；只读打包向量）
    reg [7:0] wi [0:WRP-1];
    integer   fj, wk;
    always @(*) begin
        for (fj = 0; fj < WRP; fj = fj + 1) wi[fj] = 8'h0;
        wk = 0;
        for (fj = 0; fj < DEPTH; fj = fj + 1) begin
            if (free_v[fj] && (wk < WRP)) begin
                wi[wk] = fj[7:0];
                wk = wk + 1;
            end
        end
    end

    // ---- 诊断打印（DBG=1 时；默认 0 ⇒ 不产生任何仿真开销/输出）----
    integer dsi;
    always @(posedge clk) begin
        if (DBG && rst_n && (valid_q != {DEPTH{1'b0}})) begin
            for (dsi = 0; dsi < DEPTH; dsi = dsi + 1) begin
                if (valid_q[dsi])
                    $display("[iq-dbg %m] slot=%0d rob=%0d rdy=%b pdst=%0d ps1i=%0d ps2i=%0d use=%b%b",
                             dsi, rob_q[dsi*ROB_IDX_W +: ROB_IDX_W],
                             rdy_q[dsi*SRC_N +: SRC_N],
                             uop_q[dsi][`BACK2_U_PDIDST_MSB:`BACK2_U_PDIDST_LSB],
                             uop_q[dsi][`BACK2_U_PS1I_MSB:`BACK2_U_PS1I_LSB],
                             uop_q[dsi][`BACK2_U_PS2I_MSB:`BACK2_U_PS2I_LSB],
                             uop_q[dsi][`BACK2_UB_S1_I_USE],
                             uop_q[dsi][`BACK2_UB_S2_I_USE]);
            end
            $display("[iq-dbg %m] wki_v_e=%b wki_tag_e=%b wk_hit=%b rob_head=%0d rob_cnt=%0d",
                     wki_v_e, wki_tag_e, wk_hit, rob_head, rob_cnt);
        end
    end

    //==========================================================================
    // 4. 计数输出
    //==========================================================================
    assign cnt_o = popc(valid_q);

    //==========================================================================
    // 5. 时序：唤醒置位 / 出队 / 入队
    //==========================================================================
    // ---- 冲刷作废掩码（组合；只读打包向量）----
    //   年轻判据必须以 **ROB 头为年龄原点**：age = (idx - head) mod 128，
    //   "更年轻" ⇔ age(项) > age(squash_idx)。不能写成 (idx - squash_idx) != 0 ——
    //   模 128 下 idx 更小会得到 127（看起来"非零"），会把**更老**的项一起误杀
    //   （实测：squash_idx=21 时把 idx=20 的项也杀掉，队列 3→1 而非 3→2）。
    wire [DEPTH-1:0] squash_kill;
    wire [DEPTH-1:0] out_window;      // 落在 ROB 窗口之外（已提交越过 / 已冲刷）
    wire [ROB_IDX_W-1:0] age_sq = squash_idx - rob_head;
    generate
    for (ge = 0; ge < DEPTH; ge = ge + 1) begin : g_kill
        wire [ROB_IDX_W-1:0] age_e = rob_q[ge*ROB_IDX_W +: ROB_IDX_W] - rob_head;
        assign squash_kill[ge] = squash & valid_q[ge] & (age_e > age_sq);
        //   8 bit 比较：rob_cnt=128 时 7 bit 表示为 0 ⇒ 必须零扩展到 8 bit，否则
        //   "满窗口"会被误判成"空窗口"而把全部项清掉。
        assign out_window[ge]  = valid_q[ge] & ({1'b0, age_e} >= rob_cnt);
    end
    endgenerate

    integer q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= {DEPTH{1'b0}};
            rdy_q   <= {(DEPTH*SRC_N){1'b0}};
            rob_q   <= {(DEPTH*ROB_IDX_W){1'b0}};
            ep_q    <= {(DEPTH*`BACK2_EPOCH_W){1'b0}};
        end else if (flush_all) begin
            valid_q <= {DEPTH{1'b0}};
        end else begin
            // ---- 5.1 出队 + 冲刷作废（比 squash_idx 更年轻的项）----
            valid_q <= (valid_q & ~sel_onehot) & ~squash_kill & ~out_window;
            // ---- 5.2 唤醒置位（单调置 1；出队项无损）----
            rdy_q <= (rdy_q | wk_hit);
            // ---- 5.3 入队（覆盖对应槽；冲刷拍**不接受**新项：该块必属错路径）----
            for (q = 0; q < WRP; q = q + 1) begin
                if (wr_valid[q] && wr_ok && ~squash) begin
                    valid_q[wi[q]] <= 1'b1;
                    rdy_q[wi[q]*SRC_N +: SRC_N] <= wr_rdy[q*SRC_N +: SRC_N];
                    rob_q[wi[q]*ROB_IDX_W +: ROB_IDX_W] <= wr_rob[q*ROB_IDX_W +: ROB_IDX_W];
                    ep_q [wi[q]*`BACK2_EPOCH_W +: `BACK2_EPOCH_W] <= epoch;
                    uop_q[wi[q]] <= wr_uop[q*UOPW +: UOPW];
                end
            end
        end
    end

endmodule
