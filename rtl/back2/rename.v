//==============================================================================
// rtl/back2/rename.v —— 物理寄存器重命名（RAT + free list + 变更日志 + 检查点）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §3.1（结构）、§3.2（整数 96 / 浮点 64，分离
//         free list；架构基线 32 复位预置给 RAT）、§3.3（重命名规则 R1–R6）、
//         §3.4（16 检查点 + **RAT 变更日志**恢复；free list 头快照）、§9（检查点取舍）。
//         docs/design/02-pipeline.md §3.6（D2：RAT 读改写 + 空闲分配 + 同块内前递）、
//         §4.1 S3（自由表不足 ⇒ 冻结）、§5 硬规则 3（推测态回滚不依赖回滚路径回收寄存器）。
//
// 【一个实例 = 一个重命名域】整数域（PDW=7/NREG=96/FREE_N=64/NSRC=2）与浮点域
//   （PDW=6/NREG=64/FREE_N=32/NSRC=3，第 3 源给 FMA 的 rs3）各例化一份 —— 参数化复用，
//   避免两套实现分叉。
//
// 【规则实现】
//   R4 同块内 RAW：同拍 4 条中后面的源命中前面 lane 的目的 ⇒ 直接前递新物理号。
//   R5 同块 WAW/WAR：按 lane 序从前到后处理（RAT 写入后者覆盖前者）。
//   R6 提交释放 `pdest_old`（**不是** pdest）—— 写反会静默错值或永久泄漏。
//
// 【回滚（分支误判）两条入口】
//   ① `restore_valid/restore_id`：按前端的检查点 id 恢复（03 §3.4 的设计口径）；
//   ② `restore_rob_valid/restore_rob_idx`：按**分支的 ROB 索引**恢复（本实现的补充：
//      前端只在"块尾预测跳转"分配检查点，块中其它条件分支误判时没有检查点——此时若
//      退回全冲刷要重建 free list，代价过大；故维护一张按 ROB 索引的
//      {日志写指针, free list 头} 快照表，任何 ROB 索引都可作为回滚点）。
//   两条入口共用同一套回滚 FSM。
//
// 回滚口径：
//   · free list **只回退 head**：比回滚点更年轻的指令不可能在其存活期间提交，故"已释放
//     区间"与"待回收的头部区间"不可能重叠（不会双重登记/静默错值）；若连 tail 一起
//     回退，则会丢掉提交真实发生的释放 ⇒ 物理寄存器泄漏。
//   · 变更日志按绝对位置**逆序、每拍 4 条窗口**回放：窗口内"最早写入者胜"，与逐条
//     逆序回放等价（净效果 = 每个 arn 恢复为该窗口最早那条的 old 值）。
//
// 【全冲刷（提交点异常）】架构 RAT 复制 + free list 重建 FSM（逐拍扫描 NREG 项，凡未被
//   架构 RAT 引用者依次压回）；架构引用位图 `ar_used_q` 在提交点增量维护。
//
// 风格  : 组合逻辑 `assign`/条件表达式；always 块只用于存储体与指针（时序元件）。
//         ★ 不使用"读存储器"的 function（iverilog 12.0 实测返回错误结果，
//           见 rtl/front4/README.md §7.1）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module rename #(
    parameter integer W          = `BACK2_DISP_W,
    parameter integer NSRC       = 2,
    parameter integer PDW        = `BACK2_PREG_I_W,
    parameter integer NREG       = `BACK2_PRF_I_N,
    parameter integer FREE_N     = `BACK2_FREE_I_N,
    parameter integer ARCH_N     = `BACK2_ARCH_N,
    parameter integer ARN_W      = `BACK2_ARN_W,
    parameter integer FL_PTR_W   = `BACK2_FL_PTR_W,
    parameter integer LOG_N      = `BACK2_RATLOG_N,
    parameter integer LOG_PTR_W  = `BACK2_RATLOG_N,
    parameter integer CKPT_N     = `BACK2_CKPT_N,
    parameter integer CKPT_ID_W  = `BACK2_CKPT_ID_W,
    parameter integer ROB_IDX_W  = `BACK2_ROB_IDX_W,
    parameter integer CHK        = 1,             // 不变式自检（默认开）
    parameter integer TRACE      = 0,             // 1 = 打印每次 preg 分配/释放（诊断）
    parameter integer TRB        = 0              // 1 = 打印回滚点与快照写入（B27 定案诊断）
) (
    input  wire                  clk,
    input  wire                  rst_n,

    //==================================================================
    // 派发（D2）：本拍块内各 lane 的重命名请求（lane 0 最老，且自 lane0 连续）
    //   ★ `lane_fire` = 本块**本拍真正派发**（D3 fire）。`lane_valid` 只表示
    //     "D1 寄存器里放着这一块"，它可能连续多拍保持有效（等队列余量/检查点），
    //     因此**所有状态更新**（RAT / 变更日志 / free list 指针 / 回滚点登记）
    //     必须与 `lane_fire` 相与；只用 lane_valid 会在"等待拍"里反复重放同一块，
    //     把 RAT 与 free list 打乱（实测：ROB/IQ 反复分配同一块、后端假提交）。
    //   组合检查类输出（free_ok / lane_pd_*）仍按 lane_valid 计算，避免
    //     lane_fire → 分配数 → free_ok → 派发判据 的组合环。
    //==================================================================
    input  wire [W-1:0]          lane_valid,
    input  wire                  lane_fire,
    input  wire [W-1:0]          lane_need_dst,
    input  wire [W*ARN_W-1:0]    lane_dst_arn,
    input  wire [W*NSRC-1:0]     lane_need_s,
    input  wire [W*NSRC*ARN_W-1:0] lane_s_arn,

    output wire [W*PDW-1:0]      lane_pd_dst,
    output wire [W*PDW-1:0]      lane_pd_old,
    output wire [W*NSRC*PDW-1:0] lane_pd_s,

    output wire                  free_ok,
    output wire [7:0]            free_cnt_o,

    //==================================================================
    // 提交（W1）：架构 RAT 更新 + 旧映射释放（R6）
    //==================================================================
    input  wire [W-1:0]          cmt_we,
    input  wire [W*ARN_W-1:0]    cmt_arn,
    input  wire [W*PDW-1:0]      cmt_pd,
    input  wire [W-1:0]          rel_we,
    input  wire [W*PDW-1:0]      rel_preg,

    //==================================================================
    // 派发期登记"按 ROB 索引的回滚点"
    //==================================================================
    input  wire                  rob_snap_valid,
    input  wire [W*ROB_IDX_W-1:0] rob_snap_idx,

    //==================================================================
    // 检查点 / 回滚 / 全冲刷
    //==================================================================
    input  wire                  snap_valid,
    input  wire [CKPT_ID_W-1:0]  snap_id,
    input  wire [1:0]            snap_lane,
    input  wire                  restore_valid,
    input  wire [CKPT_ID_W-1:0]  restore_id,
    input  wire                  restore_rob_valid,
    input  wire [ROB_IDX_W-1:0]  restore_rob_idx,
    input  wire                  flush_all,
    output wire                  busy,

    //==================================================================
    // 观测
    //==================================================================
    output wire [LOG_PTR_W-1:0]  log_wr_o,
    output wire [15:0]           cnt_restore_o
);

    //==========================================================================
    // 0. 状态
    //==========================================================================
    reg  [PDW-1:0]       rat_q   [0:ARCH_N-1];
    reg  [PDW-1:0]       arat_q  [0:ARCH_N-1];
    reg  [NREG-1:0]      ar_used_q;
    reg  [PDW-1:0]       flist_q [0:255];
    reg  [FL_PTR_W-1:0]  fhead_q, ftail_q;

    localparam integer LOG_AW   = $clog2(LOG_N);   // log array address width (128 -> 7 bit; index wraps naturally)
    wire [LOG_AW-1:0]  lg_wr_a  = log_wr_q[LOG_AW-1:0];   // write address (B27 fix: slice, no mask)
    reg  [ARN_W-1:0]     lg_arn  [0:LOG_N-1];
    reg  [PDW-1:0]       lg_old  [0:LOG_N-1];
    reg                  lg_val  [0:LOG_N-1];
    reg  [LOG_PTR_W-1:0] log_wr_q;

    reg  [FL_PTR_W-1:0]  ck_fhead [0:CKPT_N-1];
    reg  [LOG_PTR_W-1:0] ck_log   [0:CKPT_N-1];
    reg                  ck_val   [0:CKPT_N-1];

    // 按 ROB 索引的回滚点快照（"该 uop 分配完成之后"的状态）
    reg  [FL_PTR_W-1:0]  rb_fhead [0:127];
    reg  [LOG_PTR_W-1:0] rb_log   [0:127];

    reg                  undo_act;
    reg  [LOG_PTR_W-1:0] undo_ptr;
    reg  [8:0]           undo_dist;
    reg  [15:0]          cnt_rst_q;

    reg                  rb_act;
    reg  [8:0]           rb_cnt;
    reg  [FL_PTR_W-1:0]  rb_head;

    //==========================================================================
    // 1. 同拍 lane 组合推导
    //==========================================================================
    wire [2:0] ord_d [0:W-1];
    wire [2:0] ord_r [0:W-1];
    assign ord_d[0] = 3'd0;
    assign ord_r[0] = 3'd0;

    genvar g, k;
    generate
    for (g = 1; g < W; g = g + 1) begin : g_ord
        assign ord_d[g] = ord_d[g-1] + {2'b0, (lane_valid[g-1] & lane_need_dst[g-1])};
        assign ord_r[g] = ord_r[g-1] + {2'b0, rel_we[g-1]};
    end
    endgenerate

    wire [2:0] alloc_n_w = ord_d[W-1] + {2'b0, (lane_valid[W-1] & lane_need_dst[W-1])};

    // ---- 门控版本（= lane_valid & lane_fire）：**只允许时序块使用** ----
    wire [W-1:0] lvf = lane_valid & {W{lane_fire}};
    wire [2:0] ord_df [0:W-1];
    assign ord_df[0] = 3'd0;
    generate
    for (g = 1; g < W; g = g + 1) begin : g_ordf
        assign ord_df[g] = ord_df[g-1] + {2'b0, (lvf[g-1] & lane_need_dst[g-1])};
    end
    endgenerate
    wire [2:0] alloc_n_f = ord_df[W-1] + {2'b0, (lvf[W-1] & lane_need_dst[W-1])};
    //   ★ 日志条数 = **有效 lane 数**（每条有效 lane 都写一条 lg_* 记录，含
    //     lg_val=0 的"不写目的寄存器"条目），与 free list 消耗数（只数需要目的
    //     寄存器的 lane）**不是一回事**。旧实现让二者共用 alloc_n_w ⇒ 日志指针
    //     漂移 ⇒ 回滚重放错位的记录 ⇒ RAT 恢复错误 ⇒ 出现"源映射 == 自身新目的"
    //     的自环（rename.v §2.9 自检实测命中：lane 1/2 arn=8 均为 preg=66）
    //     ⇒ 该 uop 永远等不到写回、队列永久停顿。
    wire [2:0] valid_n_f = {2'b0, lvf[0]} + {2'b0, lvf[1]} +
                           {2'b0, lvf[2]} + {2'b0, lvf[3]};
    wire [3:0] rel_n_w   = {3'b0, rel_we[0]} + {3'b0, rel_we[1]} +
                           {3'b0, rel_we[2]} + {3'b0, rel_we[3]};
    wire [2:0] valid_n_w = {2'b0, lane_valid[0]} + {2'b0, lane_valid[1]} +
                           {2'b0, lane_valid[2]} + {2'b0, lane_valid[3]};

    // ---- 1.1 free list 组合读（目的新物理号）----
    wire [PDW-1:0] ev_pd_dst [0:W-1];
    generate
    for (g = 0; g < W; g = g + 1) begin : g_dst
        assign ev_pd_dst[g] = flist_q[fhead_q + {{(FL_PTR_W-3){1'b0}}, ord_d[g]}];
    end
    endgenerate

    // ---- 1.2 目的旧映射（同块 WAW 前递：取**最近的前驱 lane** 的新映射）----
    //   ★ 优先级必须是 s2 > s1 > s0（下标越大越"近"）。旧实现写成 s0 > s1 > s2
    //     ⇒ 一块内 4 条同写 x8 时，lane2/lane3 的"旧映射"取到 lane0 的新映射，
    //     于是三条指令的 PDIOLD 全等 ⇒ 提交时**同一物理号被释放 3 次** ⇒
    //     free list 出现重复项（实测 flist=41 41 41…、39 39…）⇒ 同一物理号发给
    //     两个 uop（自环）⇒ 后端停顿。
    wire [PDW-1:0] ev_pd_old [0:W-1];
    generate
    for (g = 0; g < W; g = g + 1) begin : g_old
        wire s0 = (g > 0) & lane_valid[0] & lane_need_dst[0] &
                  (lane_dst_arn[0*ARN_W +: ARN_W] == lane_dst_arn[g*ARN_W +: ARN_W]);
        wire s1 = (g > 1) & lane_valid[1] & lane_need_dst[1] &
                  (lane_dst_arn[1*ARN_W +: ARN_W] == lane_dst_arn[g*ARN_W +: ARN_W]);
        wire s2 = (g > 2) & lane_valid[2] & lane_need_dst[2] &
                  (lane_dst_arn[2*ARN_W +: ARN_W] == lane_dst_arn[g*ARN_W +: ARN_W]);
        assign ev_pd_old[g] = s2 ? ev_pd_dst[2] : s1 ? ev_pd_dst[1] : s0 ? ev_pd_dst[0]
                                  : rat_q[lane_dst_arn[g*ARN_W +: ARN_W]];
    end
    endgenerate

    // ---- 1.3 源物理号（R4 前递 + RAT），NSRC 个源口 ----
    //   同块源前递同样取**最近的前驱 lane**（p2 > p1 > p0）；旧实现反序 ⇒ 读到更早
    //   lane 的旧值（静默错数据，且与 §1.2 的重复释放同源）。
    wire [PDW-1:0] ev_pd_s [0:W*NSRC-1];
    generate
    for (g = 0; g < W; g = g + 1) begin : g_src
        for (k = 0; k < NSRC; k = k + 1) begin : g_k
            wire [ARN_W-1:0] sa = lane_s_arn[(g*NSRC + k)*ARN_W +: ARN_W];
            wire p0 = (g > 0) & lane_valid[0] & lane_need_dst[0] &
                      (lane_dst_arn[0*ARN_W +: ARN_W] == sa);
            wire p1 = (g > 1) & lane_valid[1] & lane_need_dst[1] &
                      (lane_dst_arn[1*ARN_W +: ARN_W] == sa);
            wire p2 = (g > 2) & lane_valid[2] & lane_need_dst[2] &
                      (lane_dst_arn[2*ARN_W +: ARN_W] == sa);
            assign ev_pd_s[g*NSRC + k] = p2 ? ev_pd_dst[2] : p1 ? ev_pd_dst[1] :
                                         p0 ? ev_pd_dst[0] : rat_q[sa];
        end
    end
    endgenerate

    generate
    for (g = 0; g < W; g = g + 1) begin : g_out
        assign lane_pd_dst[g*PDW +: PDW] = ev_pd_dst[g];
        assign lane_pd_old[g*PDW +: PDW] = ev_pd_old[g];
        for (k = 0; k < NSRC; k = k + 1) begin : g_outk
            assign lane_pd_s[(g*NSRC + k)*PDW +: PDW] = ev_pd_s[g*NSRC + k];
        end
    end
    endgenerate

    // ---- 1.4 余量（S3：本块分配数 ≤ **现有**空闲数）----
    //   ★ 不允许把"本拍提交释放的物理号"计入可分配额度：释放值落盘在 **ftail**
    //     指向的槽，而分配读的是 `flist_q[fhead + ord_d[]]` 数组原值——一旦
    //     alloc_n 越过 ftail，读到的就是**尚未成为空闲**的陈旧槽内容（那些物理号
    //     可能仍在 RAT 里被引用）⇒ 同一个物理号被发两次 ⇒ 源映射撞上自身新目的
    //     （自环）⇒ 该 uop 永远等不到写回。实测：flist[fhead..]=62 62 62 52 66 66 66
    //     全是重复项，随之出现 RENAME-CHK 自环并使后端永久停顿。
    //   代价：分配与释放同拍时保守停一拍（相对原来的错误乐观判据）。
    wire [8:0] free_cnt_w   = {1'b0, (ftail_q - fhead_q)};
    assign free_ok    = (free_cnt_w >= {6'b0, alloc_n_w});
    assign free_cnt_o = free_cnt_w[7:0];

    // ---- 1.5 提交时架构引用位图更新（逐槽顺序：先清旧、后置新）----
    reg [NREG-1:0] ar_used_next;
    integer        u;
    always @(*) begin
        ar_used_next = ar_used_q;
        for (u = 0; u < W; u = u + 1) begin
            if (cmt_we[u]) begin
                ar_used_next = (ar_used_next &
                                ~({{(NREG-1){1'b0}}, 1'b1} << arat_q[cmt_arn[u*ARN_W +: ARN_W]]))
                               | ({{(NREG-1){1'b0}}, 1'b1} << cmt_pd[u*PDW +: PDW]);
            end
        end
    end

    // ---- 1.6b 有效 lane 的**压缩序号**（日志槽位的唯一真源）----
    //   ★★ 日志口径（§2 与 B15 修复后的口径）是"**每条有效 lane 一条记录、连续排列**"，
    //      写指针 `log_wr_q` 按**有效 lane 数**推进。因此槽位必须用"本 lane 之前有几条
    //      有效 lane"（rank），**不能**用 lane 下标：mask 有洞时（例如仅 lane1/lane3 有效）
    //      用下标会把记录写到推进范围之外，在被推进区间里留下**陈旧的 lg_val=1 洞**；
    //      回滚重放于是读到上一条无关指令的旧记录 ⇒ RAT 被恢复成过期映射、free list 与
    //      RAT 失步（实测：`RENAME-CHK DUP: 分配 preg=65 但 RAT[arn=12] 仍引用它`，
    //      程序 0 即可复现；程序 1 在其后 ~430 拍因同一 preg 被二次分配而自环停顿）。
    wire [2:0] lg_rank [0:W-1];
    generate
    for (g = 0; g < W; g = g + 1) begin : g_lgr
        assign lg_rank[g] = (g == 0) ? 3'd0 : (lg_rank[g-1] + {2'b0, lvf[g-1]});
    end
    endgenerate
    // 本 lane 记录之后（含本 lane）的日志指针
    wire [2:0] lg_after [0:W-1];
    generate
    for (g = 0; g < W; g = g + 1) begin : g_lga
        assign lg_after[g] = lg_rank[g] + {2'b0, lvf[g]};
    end
    endgenerate

    // ---- 1.6 派发期回滚点（"该 lane 分配完成之后"）----
    wire [FL_PTR_W-1:0]   dn_fhead [0:W-1];
    wire [LOG_PTR_W-1:0]  dn_log   [0:W-1];
    generate
    for (g = 0; g < W; g = g + 1) begin : g_dn
        assign dn_fhead[g] = fhead_q + {{(FL_PTR_W-3){1'b0}},
                              (ord_d[g] + {2'b0, (lane_valid[g] & lane_need_dst[g])})};
        assign dn_log[g]   = log_wr_q + {{(LOG_PTR_W-3){1'b0}}, lg_after[g]};
    end
    endgenerate

    // ---- 1.7 检查点快照指针（含 ckpt lane 在内）----
    wire [2:0] snap_ord = (snap_lane == 2'd0) ? 3'd0 :
                          (snap_lane == 2'd1) ? 3'd1 :
                          (snap_lane == 2'd2) ? 3'd2 : 3'd3;
    wire       snap_ndst = (snap_lane == 2'd0) ? (lane_valid[0] & lane_need_dst[0]) :
                           (snap_lane == 2'd1) ? (lane_valid[1] & lane_need_dst[1]) :
                           (snap_lane == 2'd2) ? (lane_valid[2] & lane_need_dst[2]) :
                                                 (lane_valid[3] & lane_need_dst[3]);
    wire [FL_PTR_W-1:0] snap_fhead_w = fhead_q +
        {{(FL_PTR_W-3){1'b0}}, (ord_d[snap_lane[1:0]] + {2'b0, snap_ndst})};
    wire [LOG_PTR_W-1:0] snap_log_w  = log_wr_q + {{(LOG_PTR_W-3){1'b0}}, lg_after[snap_lane[1:0]]};
    wire [LOG_PTR_W-1:0] undo_tgt_w  = restore_valid ? ck_log[restore_id] : rb_log[restore_rob_idx];
    wire [FL_PTR_W-1:0]  undo_fhead_w= restore_valid ? ck_fhead[restore_id] : rb_fhead[restore_rob_idx];

    //==========================================================================
    // 2. 回滚窗口（每拍 4 条逆序；窗口内最早写入者胜）
    //==========================================================================
    wire [2:0] u_k = (undo_dist >= 9'd4) ? 3'd4 :
                     (undo_dist >= 9'd3) ? 3'd3 :
                     (undo_dist >= 9'd2) ? 3'd2 :
                     (undo_dist >= 9'd1) ? 3'd1 : 3'd0;
    wire [LOG_AW-1:0] u_p3 = undo_ptr[LOG_AW-1:0] - 3'd4;
    wire [LOG_AW-1:0] u_p2 = undo_ptr[LOG_AW-1:0] - 3'd3;
    wire [LOG_AW-1:0] u_p1 = undo_ptr[LOG_AW-1:0] - 3'd2;
    wire [LOG_AW-1:0] u_p0 = undo_ptr[LOG_AW-1:0] - 3'd1;

    wire u_v3 = (u_k == 3'd4) & lg_val[u_p3];
    wire u_v2 = (u_k >= 3'd3) & lg_val[u_p2];
    wire u_v1 = (u_k >= 3'd2) & lg_val[u_p1];
    wire u_v0 = (u_k >= 3'd1) & lg_val[u_p0];
    //   ★★ free list 归还量 = 本窗口**真正被重放的、消耗目的寄存器的**条数
    //      （`u_v*` 已由 `lg_val` 门控 ⇒ 恰好是"分配过 preg 的条目"）。归还与 RAT 重放
    //      **同源**：RAT 回滚了几条，free list 就归还几个 preg ⇒ 结构上不可能失步。
    wire [2:0] u_ret = {2'b0, u_v3} + {2'b0, u_v2} + {2'b0, u_v1} + {2'b0, u_v0};
    wire u_a2 = u_v2 & ~(u_v3 & (lg_arn[u_p3] == lg_arn[u_p2]));
    wire u_a1 = u_v1 & ~((u_v3 & (lg_arn[u_p3] == lg_arn[u_p1])) |
                         (u_a2 & (lg_arn[u_p2] == lg_arn[u_p1])));
    wire u_a0 = u_v0 & ~((u_v3 & (lg_arn[u_p3] == lg_arn[u_p0])) |
                         (u_a2 & (lg_arn[u_p2] == lg_arn[u_p0])) |
                         (u_a1 & (lg_arn[u_p1] == lg_arn[u_p0])));

    assign busy          = undo_act | rb_act;
    assign log_wr_o      = log_wr_q;
    assign cnt_restore_o = cnt_rst_q;

    //==========================================================================
    // 2.9 不变式自检（CHK=1）：源映射不得等于**本指令自己的新目的映射**
    //     ——否则该 uop 会等一个自己永远不写回的物理号（自环 ⇒ 队列永久停顿）。
    //     这是重命名正确性的最小闭环检查，默认开启（只在违规时打印）。
    //==========================================================================
    integer cj, ck;
    //   TRACE=1 时打印每次"分配/释放"物理号（诊断 free list 重复项用）
    integer tj;
    always @(posedge clk) begin
        if (TRACE && rst_n) begin
            for (tj = 0; tj < W; tj = tj + 1) begin
                if (lvf[tj] & lane_need_dst[tj])
                    $display("[preg-alloc t=%0t] fhead=%0d preg=%0d arn=%0d rob_snap=%0d",
                             $time, fhead_q, lane_pd_dst[tj*PDW +: PDW],
                             lane_dst_arn[tj*ARN_W +: ARN_W], tj);
                if (rel_we[tj])
                    $display("[preg-rel   t=%0t] ftail=%0d preg=%0d (slot %0d)",
                             $time, ftail_q, rel_preg[tj*PDW +: PDW], tj);
            end
        end
        if (CHK && rst_n) begin
            for (cj = 0; cj < W; cj = cj + 1) begin
                //   ★ 分配一致性（比自环检查更早、更硬）：**本拍真正消耗掉的** free list 项
                //     不得仍被任何架构寄存器引用。命中即说明 free list 与 RAT 失去一致性
                //     （典型成因：回滚把 fhead 退到"仍被引用"的旧位置，或同一 preg 被释放两次）。
                //     门控用 lvf（= lane_valid & lane_fire）而不是 lane_valid：块未派发时
                //     的 preg 只是"预读"，未真正消耗 free list，否则会误报。
                if (lvf[cj] & lane_need_dst[cj]) begin
                    for (ck = 0; ck < ARCH_N; ck = ck + 1) begin
                        if (rat_q[ck] == lane_pd_dst[cj*PDW +: PDW])
                            $display("RENAME-CHK DUP: lane %0d 分配 preg=%0d 但 RAT[arn=%0d] 仍引用它 | fhead=%0d ftail=%0d pdiold=%0d",
                                     cj, lane_pd_dst[cj*PDW +: PDW], ck, fhead_q, ftail_q,
                                     lane_pd_old[cj*PDW +: PDW]);
                    end
                end
                if (lane_valid[cj] & lane_need_dst[cj]) begin
                    for (ck = 0; ck < NSRC; ck = ck + 1) begin
                        if (lane_need_s[cj*NSRC + ck] &
                            (lane_s_arn[(cj*NSRC+ck)*ARN_W +: ARN_W] ==
                             lane_dst_arn[cj*ARN_W +: ARN_W]) &
                            (lane_pd_s[(cj*NSRC+ck)*PDW +: PDW] ==
                             lane_pd_dst[cj*PDW +: PDW]))
                            $display("RENAME-CHK FAIL: lane %0d src %0d arn=%0d 映射到自身新目的 preg=%0d（自环）| fhead=%0d ftail=%0d flist[fhead..+7]=%0d %0d %0d %0d %0d %0d %0d %0d | lane dst/ord=%0d/%0d %0d/%0d %0d/%0d %0d/%0d",
                                     cj, ck, lane_dst_arn[cj*ARN_W +: ARN_W],
                                     lane_pd_dst[cj*PDW +: PDW],
                                     fhead_q, ftail_q,
                                     flist_q[fhead_q], flist_q[fhead_q+1], flist_q[fhead_q+2],
                                     flist_q[fhead_q+3], flist_q[fhead_q+4], flist_q[fhead_q+5],
                                     flist_q[fhead_q+6], flist_q[fhead_q+7],
                                     lane_pd_dst[0*PDW +: PDW], ord_d[0],
                                     lane_pd_dst[1*PDW +: PDW], ord_d[1],
                                     lane_pd_dst[2*PDW +: PDW], ord_d[2],
                                     lane_pd_dst[3*PDW +: PDW], ord_d[3]);
                    end
                end
            end
        end
    end

    //==========================================================================
    // 3. 时序
    //==========================================================================
    integer j2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fhead_q   <= {FL_PTR_W{1'b0}};
            //   ★★ 2B-4 修复（锁步 p4_fpu 暴露）：free list 尾指针必须 = **本实例**的
            //     空闲项数 `FREE_N`（整型域 64 / 浮点域 **32**），不能硬编码 64。
            //     旧实现在浮点域把 `ftail` 置 64，而 `flist_q[0..FREE_N-1] = ARCH_N+j`
            //     只填了前 32 项 ⇒ 该域**虚报 32 个空闲项**，前 32 次分配用完后
            //     fhead 越过 32 读到的全是初始化清零值 **preg=0**（= f0 的基线映射）
            //     ⇒ 与"读改写同一架构寄存器"（`fadd.s f22,f22,f1`）撞出自环
            //     （实测 `RENAME-CHK FAIL: ... arn=22 ... preg=0 | fhead=32 ftail=87
            //       flist[fhead..+7]=0 0 0 0 0 0 0 0`）。
            ftail_q   <= FREE_N[FL_PTR_W-1:0];
            log_wr_q  <= {LOG_PTR_W{1'b0}};
            undo_act  <= 1'b0; undo_ptr <= {LOG_PTR_W{1'b0}}; undo_dist <= 9'd0;
            rb_act    <= 1'b0; rb_cnt <= 9'd0; rb_head <= {FL_PTR_W{1'b0}};
            cnt_rst_q <= 16'h0;
            ar_used_q <= {{(NREG-ARCH_N){1'b0}}, {ARCH_N{1'b1}}};
            for (j2 = 0; j2 < ARCH_N; j2 = j2 + 1) begin
                rat_q [j2] <= j2[PDW-1:0];
                arat_q[j2] <= j2[PDW-1:0];
            end
            for (j2 = 0; j2 < 256; j2 = j2 + 1) flist_q[j2] <= {PDW{1'b0}};
            for (j2 = 0; j2 < FREE_N; j2 = j2 + 1) flist_q[j2] <= (ARCH_N + j2);
            for (j2 = 0; j2 < LOG_N; j2 = j2 + 1) begin
                lg_arn[j2] <= {ARN_W{1'b0}}; lg_old[j2] <= {PDW{1'b0}}; lg_val[j2] <= 1'b0;
            end
            for (j2 = 0; j2 < CKPT_N; j2 = j2 + 1) begin
                ck_fhead[j2] <= {FL_PTR_W{1'b0}}; ck_log[j2] <= {LOG_PTR_W{1'b0}};
                ck_val[j2]   <= 1'b0;
            end
            for (j2 = 0; j2 < 128; j2 = j2 + 1) begin
                rb_fhead[j2] <= {FL_PTR_W{1'b0}}; rb_log[j2] <= {LOG_PTR_W{1'b0}};
            end
        end else begin
            //==================================================================
            // 3.0 提交侧（架构）更新：**每拍无条件执行**
            //   ★ 关键修复：`arat_q`/`ar_used_q`/free list 释放都是**提交侧**语义，
            //     必须与"派发侧/回滚侧"解耦。旧实现把它们放在 §3.4「常规」分支里，
            //     于是回滚期间（undo_act 可长达上百拍）到达的提交被整个丢掉：
            //       · `ar_used_q` 少记/多记 ⇒ flush_all 的 free list 重建（rb_act）
            //         放出仍在架构引用中的物理号 ⇒ 该号被再次分配 ⇒ **重复项**；
            //       · 提交释放被丢 ⇒ **泄漏**。
            //     实测：flist[fhead..]=62 62 62 52 66 66 66（重复）+ 空闲数掉到 2。
            //   注：`flush_all`（陷阱）拍 `cmt_ok=0` ⇒ cmt_we/rel_we 全 0，无副作用；
            //       `rb_act` 拍 rel_we=0（陷阱后无在飞指令）⇒ 不与该分支的 ftail 赋值冲突。
            //==================================================================
            for (j2 = 0; j2 < W; j2 = j2 + 1) begin
                if (cmt_we[j2]) arat_q[cmt_arn[j2*ARN_W +: ARN_W]] <= cmt_pd[j2*PDW +: PDW];
            end
            ar_used_q <= ar_used_next;
            for (j2 = 0; j2 < W; j2 = j2 + 1) begin
                if (rel_we[j2]) flist_q[ftail_q + {{(FL_PTR_W-3){1'b0}}, ord_r[j2]}]
                                    <= rel_preg[j2*PDW +: PDW];
            end
            ftail_q <= ftail_q + {{(FL_PTR_W-4){1'b0}}, rel_n_w};

            //------------------------------------------------------------------
            // 3.1 全冲刷（最高优先级）
            //------------------------------------------------------------------
            if (flush_all) begin
                undo_act <= 1'b0;
                for (j2 = 0; j2 < ARCH_N; j2 = j2 + 1) rat_q[j2] <= arat_q[j2];
                for (j2 = 0; j2 < CKPT_N; j2 = j2 + 1) ck_val[j2] <= 1'b0;
                log_wr_q <= {LOG_PTR_W{1'b0}};
                fhead_q  <= {FL_PTR_W{1'b0}};
                rb_act   <= 1'b1;
                rb_cnt   <= 9'd0;
                rb_head  <= {FL_PTR_W{1'b0}};
            end else if (rb_act) begin
                if (rb_cnt < NREG) begin
                    if (!ar_used_q[rb_cnt[PDW-1:0]]) begin
                        flist_q[rb_head] <= rb_cnt[PDW-1:0];
                        rb_head <= rb_head + 1'b1;
                    end
                    rb_cnt <= rb_cnt + 9'd1;
                end else begin
                    rb_act  <= 1'b0;
                    fhead_q <= {FL_PTR_W{1'b0}};
                    ftail_q <= rb_head;
                end
            end else if (restore_valid | restore_rob_valid) begin
                //------------------------------------------------------------------
                // 3.2 回滚启动（检查点入口 或 ROB 索引入口）
                //------------------------------------------------------------------
                //   ★★【B27 试验记录，已回退】曾把 free list 归还改为"跟随 §3.3 的 RAT 重放
                //      逐条递减"（同源法）。结果：RENAME-CHK 违规**归零**（重复项/自环消失），
                //      但程序 0 只提交 116/161 就停顿 ⇒ 归还量 < 实际分配量 ⇒ **preg 泄漏**
                //      直至 free list 耗尽。根因是"日志重放范围（undo_tgt）与分配范围本就
                //      不同代"，两条路径都会偏，只是偏的方向相反（快照偏多⇒重复；重放偏少
                //      ⇒泄漏）。故回退到快照路径（程序 0 全绿），真正修法见报告 §1 B27。
                fhead_q   <= undo_fhead_w;
                undo_ptr  <= log_wr_q;
                undo_dist <= {1'b0, (log_wr_q - undo_tgt_w)};
                undo_act  <= (log_wr_q != undo_tgt_w);
                if (restore_valid) ck_val[restore_id] <= 1'b0;
                cnt_rst_q <= cnt_rst_q + 16'd1;
            end else if (undo_act) begin
                //------------------------------------------------------------------
                // 3.3 逆序回放窗口
                //------------------------------------------------------------------
                if (u_v3) rat_q[lg_arn[u_p3]] <= lg_old[u_p3];
                if (u_a2) rat_q[lg_arn[u_p2]] <= lg_old[u_p2];
                if (u_a1) rat_q[lg_arn[u_p1]] <= lg_old[u_p1];
                if (u_a0) rat_q[lg_arn[u_p0]] <= lg_old[u_p0];
                undo_ptr  <= undo_ptr - {{(LOG_PTR_W-3){1'b0}}, u_k};
                if (undo_dist <= 9'd4) undo_act <= 1'b0;
                else                   undo_dist <= undo_dist - {6'b0, u_k};
            end else begin
                //------------------------------------------------------------------
                // 3.4 常规：变更日志 + RAT + 提交 + 快照登记
                //------------------------------------------------------------------
                for (j2 = 0; j2 < W; j2 = j2 + 1) begin
                    if (lvf[j2]) begin
                        //   slot = log_wr_q + lg_rank[j2] (valid-lane rank; see 1.6b)
                        lg_arn[lg_wr_a + lg_rank[j2]] <= lane_dst_arn[j2*ARN_W +: ARN_W];
                        lg_old[lg_wr_a + lg_rank[j2]] <= ev_pd_old[j2];
                        lg_val[lg_wr_a + lg_rank[j2]] <= lane_need_dst[j2];
                    end
                end
                for (j2 = 0; j2 < W; j2 = j2 + 1) begin
                    if (lvf[j2] & lane_need_dst[j2])
                        rat_q[lane_dst_arn[j2*ARN_W +: ARN_W]] <= ev_pd_dst[j2];
                end
                if (rob_snap_valid & lane_fire) begin
                    for (j2 = 0; j2 < W; j2 = j2 + 1) begin
                        if (lane_valid[j2]) begin
                            rb_fhead[rob_snap_idx[j2*ROB_IDX_W +: ROB_IDX_W]] <= dn_fhead[j2];
                            rb_log  [rob_snap_idx[j2*ROB_IDX_W +: ROB_IDX_W]] <= dn_log[j2];
                        end
                    end
                end
                if (snap_valid) begin
                    ck_fhead[snap_id] <= snap_fhead_w;
                    ck_log  [snap_id] <= snap_log_w;
                    ck_val  [snap_id] <= 1'b1;
                end
                log_wr_q <= log_wr_q + {{(LOG_PTR_W-3){1'b0}}, valid_n_f};   // 每条有效 lane 一条日志
                fhead_q  <= fhead_q + {{(FL_PTR_W-3){1'b0}}, alloc_n_f};     // 仅需目的寄存器的 lane 消耗 free list
            end
        end
    end

endmodule
