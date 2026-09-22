//==============================================================================
// rtl/back2/lsq_simple.v —— **过渡方案**简化访存队列（顺序发射 / 写回可乱序 / 提交排空）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2；完整 LSQ 属 2B-3）
// 规格  : docs/design/03-out-of-order.md §6（LSQ 结构与访存序、load→store 转发、提交时
//         释放）的**过渡子集**；本里程碑显式边界见下（交付说明同步登记）。
//
// 【本里程碑口径】
//   · **顺序发射**：LSU 单端口；IQ-LSU 的最老优先选择保证按程序序进入本模块。
//   · **写回可乱序**：≤`OUT_N` 笔 load 可同时在途，响应按标签各自写回 —— 这是与纯
//     顺序核最本质的差别（2A 核为"单笔在途 + 顺序写回"）。
//   · **字节级 load→store 转发**（§6.2）：load 发射拍扫描**更老且地址已确认**的 store，
//     按字内字节道取**最年轻**的更老匹配者；全部字节命中 ⇒ 不访问存储、次拍直接写回。
//     更老的 store 地址未生成 ⇒ 该 load **不可发射**（保守但正确；地址信息在
//     顺序发射下必然齐备 ⇒ 本规则只在 store 与其紧邻 load 同拍起步时生效）。
//   · **store 提交排空**：地址/数据在 E1 生成后驻留 STQ，**只在 ROB 提交该 store 时**
//     才写入存储（§6.2 / §9：异常回滚不可能双重写）；排空与 load 请求共用单请求口，
//     且**排空拍不发 load 请求**，保证 load 读到的存储内容严格晚于它必须看到的 store 写。
//   · **不做**（留 2B-3）：未对齐拆笔、PMP/MMU 检查落地、AMO/LR-SC、cbo.*、fence 屏障项、
//     64 bit（fld/fsd）访存。本模块只做 ≤4 B 的对齐访存。
//   · **地址唯一来源**：STQ/SQ 的地址字段只写一次、只写物理地址（Bare 口径 VA=PA；
//     Sv32 接线留 2B-3/2B-4）。
//
// 风格  : 组合逻辑用 `assign` + 条件表达式；两处 always 块分别为
//         ①"字节级转发归约"（组合、逐项比较 STQ 阵列——转发网络必须比较的场合）；
//         ②"STQ / 在途 load 表"（时序元件）。★ 不使用读存储器的 function。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module lsq_simple #(
    parameter integer STQ_N    = `BACK2_STQ_N,
    parameter integer STQ_IW   = `BACK2_STQ_IDX_W,
    parameter integer OUT_N    = `BACK2_MEM_OUT_N,
    parameter integer TAG_W    = `BACK2_MEM_TAG_W,
    parameter integer ROB_IDX_W= `BACK2_ROB_IDX_W,
    parameter integer PDW_I    = `BACK2_PREG_I_W,
    parameter integer PDW_F    = `BACK2_PREG_F_W,
    parameter integer W        = `BACK2_DISP_W,
    parameter integer DBG = 0              // 1 = 每拍打印 load/store 槽状态（诊断）
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  flush_all,            // trap：全清
    input  wire                  squash,               // 分支误判
    input  wire [ROB_IDX_W-1:0]  squash_idx,
    input  wire [ROB_IDX_W-1:0]  rob_head,

    // ---- D3 派发：为 store 分配 STQ 项（≤4/拍，程序序）----
    input  wire [W-1:0]          alloc_valid,
    output wire                  alloc_ok,
    output wire [W*STQ_IW-1:0]   alloc_idx,

    // ---- E1：LSU 执行（单发射；地址由 backend_top 的 AGU 算好）----
    input  wire                  exe_valid,
    input  wire                  exe_is_store,
    input  wire                  exe_is_fp,
    input  wire [ROB_IDX_W-1:0]  exe_rob,
    input  wire [`BACK2_EPOCH_W-1:0] exe_epoch,
    input  wire [31:0]           exe_addr,
    input  wire [31:0]           exe_wdata,
    input  wire [2:0]            exe_size,
    input  wire                  exe_unsign,
    input  wire                  exe_dst_i,
    input  wire                  exe_dst_f,
    input  wire [PDW_I-1:0]      exe_pdest_i,
    input  wire [PDW_F-1:0]      exe_pdest_f,
    input  wire [STQ_IW-1:0]     exe_stq_idx,

    // ---- 发射前检查（接 IQ 的 iss_ready）----
    output wire                  iss_ok,               // 有空余在途槽 且 无更老未定址 store

    // ---- 提交排空（ROB 头 store 项）----
    input  wire [W-1:0]          dr_valid,
    input  wire [W*STQ_IW-1:0]   dr_idx,

    // ---- 访存请求口（单请求；load 带标签）----
    output wire                  mem_req_valid,
    output wire                  mem_req_wen,
    output wire [31:0]           mem_req_addr,
    output wire [31:0]           mem_req_wdata,
    output wire [3:0]            mem_req_wstrb,
    output wire [TAG_W-1:0]      mem_req_tag,
    input  wire                  mem_req_ready,
    input  wire                  mem_rsp_valid,
    input  wire [31:0]           mem_rsp_rdata,
    input  wire [TAG_W-1:0]      mem_rsp_tag,

    // ---- 写回（load 结果）----
    output wire                  wb_valid,
    output wire [ROB_IDX_W-1:0]  wb_rob,
    output wire [`BACK2_EPOCH_W-1:0] wb_epoch,
    output wire                  wb_dst_i,
    output wire                  wb_dst_f,
    output wire [PDW_I-1:0]      wb_pdest_i,
    output wire [PDW_F-1:0]      wb_pdest_f,
    output wire [31:0]           wb_data,

    // ---- store E1 完成（地址+数据就绪 ⇒ ROB done）----
    output wire                  st_done_valid,
    output wire [ROB_IDX_W-1:0]  st_done_rob,
    output wire [`BACK2_EPOCH_W-1:0] st_done_epoch,

    // ---- 观测 ----
    output wire [7:0]            stq_cnt_o,
    output wire [31:0]           cnt_load_o,
    output wire [31:0]           cnt_store_o,
    output wire [31:0]           cnt_fwd_o,
    output wire [31:0]           cnt_stq_stall_o
);

    //==========================================================================
    // 0. STQ
    //==========================================================================
    reg                  stq_v   [0:STQ_N-1];
    reg                  stq_av  [0:STQ_N-1];        // 地址已生成（只写一次）
    reg                  stq_dv  [0:STQ_N-1];
    reg  [31:0]          stq_a   [0:STQ_N-1];        // ★ 物理地址（唯一来源）
    reg  [31:0]          stq_d   [0:STQ_N-1];        // 已对位到字内字节道
    reg  [3:0]           stq_msk [0:STQ_N-1];
    reg  [ROB_IDX_W-1:0] stq_rob [0:STQ_N-1];
    reg                  stq_ret [0:STQ_N-1];
    reg  [STQ_IW-1:0]    stq_head_q, stq_tail_q;

    wire [7:0] age_rob  = (exe_rob - rob_head) & 7'h7F;      // 发射项年龄

    //==========================================================================
    // 1. D3 分配（store 项）
    //==========================================================================
    wire [4:0] stq_used = {1'b0, stq_v[0]}  + {1'b0, stq_v[1]}  + {1'b0, stq_v[2]}  +
                          {1'b0, stq_v[3]}  + {1'b0, stq_v[4]}  + {1'b0, stq_v[5]}  +
                          {1'b0, stq_v[6]}  + {1'b0, stq_v[7]}  + {1'b0, stq_v[8]}  +
                          {1'b0, stq_v[9]}  + {1'b0, stq_v[10]} + {1'b0, stq_v[11]} +
                          {1'b0, stq_v[12]} + {1'b0, stq_v[13]} + {1'b0, stq_v[14]} +
                          {1'b0, stq_v[15]};
    wire [4:0] stq_need = {3'b0, alloc_valid[0]} + {3'b0, alloc_valid[1]} +
                          {3'b0, alloc_valid[2]} + {3'b0, alloc_valid[3]};
    assign alloc_ok = ((STQ_N[4:0]) - stq_used) >= stq_need;

    reg [STQ_IW-1:0] ai [0:W-1];
    wire alloc_hits_head = (ai[0] == stq_head_q) & alloc_ok & alloc_valid[0];
    integer fj, wk;
    always @(*) begin
        for (fj = 0; fj < W; fj = fj + 1) ai[fj] = {STQ_IW{1'b0}};
        wk = 0;
        for (fj = 0; fj < STQ_N; fj = fj + 1) begin
            if (!stq_v[fj] && (wk < W)) begin
                ai[wk] = fj[STQ_IW-1:0];
                wk = wk + 1;
            end
        end
    end
    genvar ga;
    generate
    for (ga = 0; ga < W; ga = ga + 1) begin : g_ai
        assign alloc_idx[ga*STQ_IW +: STQ_IW] = ai[ga];
    end
    endgenerate

    //==========================================================================
    // 2. 更老未定址 store 检查 + 字节级转发（组合，load 发射拍）
    //==========================================================================
    reg  [3:0]  fwd_hit_w;
    reg  [31:0] fwd_data_w;
    reg         any_unk_w;
    reg  [3:0]  lmask_w;
    integer     b, j, q;
    reg  [7:0]  best_age, cur_age;
    reg  [1:0]  bl;

    always @(*) begin
        // ---- 2.1 更老未定址 store（阻塞 load 发射）----
        any_unk_w = 1'b0;
        for (q = 0; q < STQ_N; q = q + 1) begin
            //   ★【B28 未修·现场】此处用 `stq_rob[q]` 判年龄，而该字段只在 E1 写入 ⇒ 已分配未执行的
            //     store 里是上一占用者的陈旧值 ⇒ 更老的未定址 store 可能漏检 ⇒ 更年轻的 load 抢跑
            //     ⇒ 漏转发（实测 sb→lbu 读到内存填充 0x13，程序 2 C1 第 11 条分歧）。
            //     两次修复尝试均已回退：(a) "任意未定址 store 都挡 load" ⇒ 死锁（更老 load ↔ 依赖它的
            //     更年轻 store 互等，乱序核卡在 20 条）；(b) 分配期记录 ROB 索引 ⇒ 仍卡在 20 条。
            //     下一轮用 DBG_LSU=1 + TB DBG_CYCLES 打印 stq_v/av/dv/msk 与 load 的 iss/rdy 逐拍现场。
            if (stq_v[q] && !stq_av[q] &&
                (((stq_rob[q] - rob_head) & 7'h7F) < age_rob)) any_unk_w = 1'b1;
        end
        // ---- 2.2 字节级转发 ----
        fwd_hit_w  = 4'h0;
        fwd_data_w = 32'h0;
        //   ★★ `exe_size` 的编码是 **log2(字节数)**，不是字节数！唯一真源 `decoder.v`
        //      `mem_size_o`：LB/SB=3'd0、LH/SH=3'd1、LW/SW=3'd2、AMO=3'd2、flw=3'd2、
        //      fld=3'd3（其注释里的"1/2/4 B"是**字节数说明**，不是字段取值）。
        //      本里程碑只做 ≤4 B 对齐访问 ⇒ 用显式 case 给出字节掩码；
        //      3'd3（8 B，fld/fsd）超出本里程碑范围，按 4 B 处理（2B-3 补 64 bit 访存）。
        case (exe_size)
            3'd0:    lmask_w = 4'h1 << exe_addr[1:0];
            3'd1:    lmask_w = 4'h3 << exe_addr[1:0];
            default: lmask_w = 4'hF << exe_addr[1:0];
        endcase
        for (b = 0; b < 4; b = b + 1) begin
            best_age = 8'd255;
            bl       = exe_addr[1:0] + b[1:0];
            if (lmask_w[b] && ((exe_addr[1:0] + b[1:0]) < 3'd4)) begin
                for (j = 0; j < STQ_N; j = j + 1) begin
                    if (stq_v[j] && stq_av[j] && stq_msk[j][bl] &&
                        (((stq_rob[j] - rob_head) & 7'h7F) < age_rob) &&
                        (stq_a[j][31:2] == exe_addr[31:2])) begin
                        cur_age = (stq_rob[j] - rob_head) & 7'h7F;
                        if (cur_age <= best_age) begin
                            best_age = cur_age;
                            fwd_hit_w[b] = 1'b1;
                            fwd_data_w[8*b +: 8] = stq_d[j][8*bl +: 8];
                        end
                    end
                end
            end
        end
    end

    wire fwd_all_w = ((fwd_hit_w & lmask_w) == lmask_w);

    //==========================================================================
    // 3. 在途 load 表
    //==========================================================================
    reg                  ld_v    [0:OUT_N-1];
    reg                  ld_req  [0:OUT_N-1];        // 请求已发（等响应）
    reg  [ROB_IDX_W-1:0] ld_rob  [0:OUT_N-1];
    reg  [`BACK2_EPOCH_W-1:0] ld_ep [0:OUT_N-1];
    reg                  ld_di   [0:OUT_N-1];
    reg                  ld_df   [0:OUT_N-1];
    reg  [PDW_I-1:0]     ld_pi   [0:OUT_N-1];
    reg  [PDW_F-1:0]     ld_pf   [0:OUT_N-1];
    reg  [31:0]          ld_addr [0:OUT_N-1];
    reg  [2:0]           ld_size [0:OUT_N-1];
    reg                  ld_uns  [0:OUT_N-1];
    reg  [3:0]           ld_hm   [0:OUT_N-1];
    reg  [31:0]          ld_hd   [0:OUT_N-1];
    reg  [TAG_W-1:0]     ld_tag  [0:OUT_N-1];

    wire [OUT_N-1:0] ld_free = ~{ld_v[3], ld_v[2], ld_v[1], ld_v[0]};
    wire ld_slot_ok = |ld_free;

    // 发射许可：有空槽 且 无更老未定址 store（store 项不需槽，但统一门控损失可忽略）
    assign iss_ok = ld_slot_ok & ~any_unk_w;

    // ---- 待发请求项（已分配、未发请求）与响应匹配 ----
    reg        pend_any;
    reg [1:0]  pend_sel;
    reg        rsp_ok;
    reg [1:0]  rsp_sel;
    reg [1:0]  newslot;
    reg        newslot_ok;
    integer    nq;
    always @(*) begin
        pend_any = 1'b0; pend_sel = 2'd0;
        for (nq = 0; nq < OUT_N; nq = nq + 1) begin
            if (ld_v[nq] && !ld_req[nq] && !pend_any) begin
                pend_any = 1'b1; pend_sel = nq[1:0];
            end
        end
        rsp_ok = 1'b0; rsp_sel = 2'd0;
        for (nq = 0; nq < OUT_N; nq = nq + 1) begin
            if (mem_rsp_valid && ld_v[nq] && ld_req[nq] && (ld_tag[nq] == mem_rsp_tag)
                && !rsp_ok) begin
                rsp_ok = 1'b1; rsp_sel = nq[1:0];
            end
        end
        newslot_ok = 1'b0; newslot = 2'd0;
        for (nq = 0; nq < OUT_N; nq = nq + 1) begin
            if (ld_free[nq] && !newslot_ok) begin
                newslot_ok = 1'b1; newslot = nq[1:0];
            end
        end
    end

    // ---- 请求发射：store 排空优先；排空拍不发 load 请求 ----
    reg [STQ_IW-1:0] dr_sel;
    reg              dr_any;
    integer          dk;
    always @(*) begin
        dr_sel = {STQ_IW{1'b0}};
        dr_any = 1'b0;
        for (dk = W-1; dk >= 0; dk = dk - 1)
            if (dr_valid[dk]) begin dr_sel = dr_idx[dk*STQ_IW +: STQ_IW]; dr_any = 1'b1; end
    end
    wire dr_fire = dr_any & mem_req_ready;
    wire ld_fire = pend_any & ~dr_any & mem_req_ready;

    assign mem_req_valid = dr_fire | ld_fire;
    assign mem_req_wen   = dr_fire;
    assign mem_req_addr  = dr_fire ? stq_a[dr_sel]   : ld_addr[pend_sel];
    assign mem_req_wdata = dr_fire ? stq_d[dr_sel]   : 32'h0;
    assign mem_req_wstrb = dr_fire ? stq_msk[dr_sel] : 4'h0;
    assign mem_req_tag   = dr_fire ? {TAG_W{1'b1}}   : ld_tag[pend_sel];

    // ---- 写回：响应到达 或（部分/全部）转发 + 响应 合并 ----
    wire [31:0] wb_word = mem_rsp_rdata;
    wire [31:0] wb_merge = { ld_hm[rsp_sel][3] ? ld_hd[rsp_sel][31:24] : wb_word[31:24],
                             ld_hm[rsp_sel][2] ? ld_hd[rsp_sel][23:16] : wb_word[23:16],
                             ld_hm[rsp_sel][1] ? ld_hd[rsp_sel][15:8]  : wb_word[15:8],
                             ld_hm[rsp_sel][0] ? ld_hd[rsp_sel][7:0]   : wb_word[7:0] };
    function [31:0] ext_load(input [31:0] w, input [1:0] off, input [2:0] sz, input uns);
        reg [7:0]  b0;
        reg [15:0] h0;
        begin
            b0 = w[8*off +: 8];
            h0 = (off[1] == 1'b0) ? w[15:0] : w[31:16];
            //   ★ 同 §2.2：`sz` 是 log2(字节数) ⇒ 0=字节、1=半字、≥2=字（8 B 属 2B-3）
            case (sz)
                3'd0: ext_load = uns ? {24'h0, b0} : {{24{b0[7]}}, b0};
                3'd1: ext_load = uns ? {16'h0, h0} : {{16{h0[15]}}, h0};
                default: ext_load = w;
            endcase
        end
    endfunction

    // 全转发项：E1 次拍直接写回（单寄存器直通）
    reg         fwdp_v;
    reg [ROB_IDX_W-1:0] fwdp_rob;
    reg [`BACK2_EPOCH_W-1:0] fwdp_ep;
    reg         fwdp_di, fwdp_df;
    reg [PDW_I-1:0] fwdp_pi;
    reg [PDW_F-1:0] fwdp_pf;
    reg [31:0]  fwdp_data;
    reg [2:0]   fwdp_size;
    reg [1:0]   fwdp_off;
    reg         fwdp_uns;

    assign wb_valid   = fwdp_v | rsp_ok;
    assign wb_rob     = fwdp_v ? fwdp_rob  : ld_rob[rsp_sel];
    assign wb_epoch   = fwdp_v ? fwdp_ep   : ld_ep[rsp_sel];
    assign wb_dst_i   = fwdp_v ? fwdp_di   : ld_di[rsp_sel];
    assign wb_dst_f   = fwdp_v ? fwdp_df   : ld_df[rsp_sel];
    assign wb_pdest_i = fwdp_v ? fwdp_pi   : ld_pi[rsp_sel];
    assign wb_pdest_f = fwdp_v ? fwdp_pf   : ld_pf[rsp_sel];
    assign wb_data    = fwdp_v ? ext_load(fwdp_data, fwdp_off, fwdp_size, fwdp_uns)
                               : ext_load(wb_merge, ld_addr[rsp_sel][1:0],
                                          ld_size[rsp_sel], ld_uns[rsp_sel]);

    assign st_done_valid = exe_valid & exe_is_store;
    assign st_done_rob   = exe_rob;
    assign st_done_epoch = exe_epoch;

    //   ★ stq_used 只有 5 bit（STQ_N=16）⇒ 必须**零扩展**到 8 bit；写 [7:0] 属于
    //     向量外位选，iverilog/Vivado 都返回 **x**（诊断口观测为 x）。
    assign stq_cnt_o = {3'b0, stq_used};

    //==========================================================================
    // 4. 时序
    //==========================================================================
    reg [31:0] cnt_ld_q, cnt_st_q, cnt_fwd_q, cnt_stall_q;
    integer    si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stq_head_q <= {STQ_IW{1'b0}};
            stq_tail_q <= {STQ_IW{1'b0}};
            cnt_ld_q <= 32'h0; cnt_st_q <= 32'h0; cnt_fwd_q <= 32'h0; cnt_stall_q <= 32'h0;
            fwdp_v <= 1'b0; fwdp_rob <= {ROB_IDX_W{1'b0}}; fwdp_ep <= {`BACK2_EPOCH_W{1'b0}};
            fwdp_di <= 1'b0; fwdp_df <= 1'b0; fwdp_pi <= {PDW_I{1'b0}};
            fwdp_pf <= {PDW_F{1'b0}}; fwdp_data <= 32'h0; fwdp_size <= 3'h0;
            fwdp_off <= 2'h0; fwdp_uns <= 1'b0;
            for (si = 0; si < STQ_N; si = si + 1) begin
                stq_v[si] <= 1'b0; stq_av[si] <= 1'b0; stq_dv[si] <= 1'b0;
                stq_a[si] <= 32'h0; stq_d[si] <= 32'h0; stq_msk[si] <= 4'h0;
                stq_rob[si] <= {ROB_IDX_W{1'b0}}; stq_ret[si] <= 1'b0;
            end
            for (si = 0; si < OUT_N; si = si + 1) begin
                ld_v[si] <= 1'b0; ld_req[si] <= 1'b0; ld_rob[si] <= {ROB_IDX_W{1'b0}};
                ld_ep[si] <= {`BACK2_EPOCH_W{1'b0}}; ld_di[si] <= 1'b0; ld_df[si] <= 1'b0;
                ld_pi[si] <= {PDW_I{1'b0}}; ld_pf[si] <= {PDW_F{1'b0}};
                ld_addr[si] <= 32'h0; ld_size[si] <= 3'h0; ld_uns[si] <= 1'b0;
                ld_hm[si] <= 4'h0; ld_hd[si] <= 32'h0; ld_tag[si] <= {TAG_W{1'b0}};
            end
        end else if (flush_all) begin
            for (si = 0; si < STQ_N; si = si + 1) begin
                stq_v[si] <= 1'b0; stq_av[si] <= 1'b0; stq_dv[si] <= 1'b0; stq_ret[si] <= 1'b0;
            end
            for (si = 0; si < OUT_N; si = si + 1) begin
                ld_v[si] <= 1'b0; ld_req[si] <= 1'b0;
            end
            stq_head_q <= {STQ_IW{1'b0}};
            stq_tail_q <= {STQ_IW{1'b0}};
            fwdp_v <= 1'b0;
        end else begin
            // ---- 4.1 默认：清全转发直通项 ----
            fwdp_v <= 1'b0;

            // ---- 4.2 派发分配（store 项）----
            if (alloc_ok) begin
                for (si = 0; si < W; si = si + 1) begin
                    if (alloc_valid[si]) begin
                        stq_v[ai[si]]   <= 1'b1;
                        stq_av[ai[si]]  <= 1'b0;
                        stq_dv[ai[si]]  <= 1'b0;
                        stq_ret[ai[si]] <= 1'b0;
                    end
                end
            end

            // ---- 4.3 E1 ----
            if (exe_valid && exe_is_store) begin
                stq_av[exe_stq_idx]  <= 1'b1;
                stq_dv[exe_stq_idx]  <= 1'b1;
                stq_a[exe_stq_idx]   <= exe_addr;                        // 物理地址唯一来源
                stq_d[exe_stq_idx]   <= exe_wdata << {exe_addr[1:0], 3'b000};
                stq_msk[exe_stq_idx] <= lmask_w;
                stq_rob[exe_stq_idx] <= exe_rob;
                cnt_st_q <= cnt_st_q + 32'd1;
                if (any_unk_w) cnt_stall_q <= cnt_stall_q + 32'd1;
            end else if (exe_valid) begin
                cnt_ld_q <= cnt_ld_q + 32'd1;
                if (|fwd_hit_w) cnt_fwd_q <= cnt_fwd_q + 32'd1;
                if (fwd_all_w) begin
                    // 全字节转发 ⇒ 不占表项、不访存，次拍写回
                    fwdp_v    <= 1'b1;
                    fwdp_rob  <= exe_rob;
                    fwdp_ep   <= exe_epoch;
                    fwdp_di   <= exe_dst_i;
                    fwdp_df   <= exe_dst_f;
                    fwdp_pi   <= exe_pdest_i;
                    fwdp_pf   <= exe_pdest_f;
                    fwdp_data <= fwd_data_w;
                    fwdp_size <= exe_size;
                    fwdp_off  <= exe_addr[1:0];
                    fwdp_uns  <= exe_unsign;
                end else if (newslot_ok) begin
                    ld_v   [newslot] <= 1'b1;
                    ld_req [newslot] <= 1'b0;
                    ld_rob [newslot] <= exe_rob;
                    ld_ep  [newslot] <= exe_epoch;
                    ld_di  [newslot] <= exe_dst_i;
                    ld_df  [newslot] <= exe_dst_f;
                    ld_pi  [newslot] <= exe_pdest_i;
                    ld_pf  [newslot] <= exe_pdest_f;
                    ld_addr[newslot] <= exe_addr;
                    ld_size[newslot] <= exe_size;
                    ld_uns [newslot] <= exe_unsign;
                    ld_hm  [newslot] <= fwd_hit_w;
                    ld_hd  [newslot] <= fwd_data_w;
                    //   ★ newslot 只有 2 bit（4 个在途槽）⇒ 必须零扩展到 TAG_W=3；
                    //     写 [TAG_W-1:0] 会取到向量外的位 ⇒ tag 为 **x** ⇒ 响应无法匹配（挂死）。
                    ld_tag [newslot] <= {{(TAG_W-2){1'b0}}, newslot};
                end
            end

            // ---- 4.4 请求 / 响应推进 ----
            if (ld_fire) ld_req[pend_sel] <= 1'b1;
            // ---- 4.5 store 排空标记与回收 ----
            //   队头回收：已排空（stq_ret）或已作废（冲刷/未执行前被清）⇒ 指针前移。
            //   ★ 若本拍分配器正好要写队头槽（队头无效时才可能），本拍不回收，
            //     否则会把新项顶掉（下拍再回收，不会饿死）。
            if (dr_fire) stq_ret[dr_sel] <= 1'b1;
            if (!alloc_hits_head && (!stq_v[stq_head_q] | stq_ret[stq_head_q])) begin
                stq_v[stq_head_q] <= 1'b0;
                stq_head_q <= stq_head_q + 1'b1;
            end

            // ---- 4.6 冲刷 ----
            if (squash) begin
                for (si = 0; si < STQ_N; si = si + 1) begin
                    if (stq_v[si] &&
                        (((stq_rob[si] - rob_head) & 7'h7F) > ((squash_idx - rob_head) & 7'h7F)))
                        stq_v[si] <= 1'b0;
                end
                for (si = 0; si < OUT_N; si = si + 1) begin
                    if (ld_v[si] &&
                        (((ld_rob[si] - rob_head) & 7'h7F) > ((squash_idx - rob_head) & 7'h7F))) begin
                        ld_v[si]   <= 1'b0;
                        ld_req[si] <= 1'b0;
                    end
                end
            end
        end
    end

    assign cnt_load_o    = cnt_ld_q;
    assign cnt_store_o   = cnt_st_q;
    assign cnt_fwd_o     = cnt_fwd_q;
    assign cnt_stq_stall_o = cnt_stall_q;


    // ---- 诊断打印（DBG=1；默认 0 ⇒ 无输出）----
    integer dl;
    always @(posedge clk) begin
        if (DBG && rst_n) begin
            //   ★ B28 判别探针：计数器 + STQ 逐项转储（v/av/dv/msk/a/d/rob）
            $display("[lsu-dbg %m] cnt_ld=%0d cnt_st=%0d cnt_fwd=%0d cnt_stall=%0d stq_head=%0d any_unk=%b iss_ok=%b",
                     cnt_ld_q, cnt_st_q, cnt_fwd_q, cnt_stall_q, stq_head_q, any_unk_w, iss_ok);
            for (dl = 0; dl < STQ_N; dl = dl + 1)
                if (stq_v[dl])
                    $display("[lsu-dbg %m] stq[%0d] v=%b av=%b dv=%b msk=%b a=0x%08x d=0x%08x rob=%0d ret=%b",
                             dl, stq_v[dl], stq_av[dl], stq_dv[dl], stq_msk[dl],
                             stq_a[dl], stq_d[dl], stq_rob[dl], stq_ret[dl]);
            for (dl = 0; dl < OUT_N; dl = dl + 1)
                if (ld_v[dl])
                    $display("[lsu-dbg %m] ld slot=%0d req=%b tag=%0d rob=%0d ep=%0d addr=0x%08x",
                             dl, ld_req[dl], ld_tag[dl], ld_rob[dl], ld_ep[dl], ld_addr[dl]);
            $display("[lsu-dbg %m] pend_any=%b rsp_ok=%b dr_any=%b rspv=%b rsp_tag=%0d stq_head=%0d",
                     pend_any, rsp_ok, dr_any, mem_rsp_valid, mem_rsp_tag, stq_head_q);
            //   ★ B28 判别探针：E1 当拍信息 + pending 槽对每个 STQ 项的**命中条件分解**
            $display("[lsu-dbg %m] E1 exe_valid=%b is_store=%b rob=%0d addr=0x%08x size=%0d | fwd_hit=%b fwd_all=%b lmask=%b newslot=%0d",
                     exe_valid, exe_is_store, exe_rob, exe_addr, exe_size,
                     fwd_hit_w, fwd_all_w, lmask_w, newslot);
            if (pend_any) begin
                $display("[lsu-dbg %m] PEND sel=%0d addr=0x%08x size=%0d rob=%0d rob_head=%0d age_l=%0d",
                         pend_sel, ld_addr[pend_sel], ld_size[pend_sel], ld_rob[pend_sel],
                         rob_head, ((ld_rob[pend_sel] - rob_head) & 7'h7F));
                for (dl = 0; dl < STQ_N; dl = dl + 1)
                    if (stq_v[dl])
                        $display("[lsu-dbg %m]   stq[%0d] av=%b msk=%b a=0x%08x age_s=%0d addr_eq=%b mskhit=%b age_lt=%b",
                                 dl, stq_av[dl], stq_msk[dl], stq_a[dl],
                                 ((stq_rob[dl] - rob_head) & 7'h7F),
                                 (stq_a[dl][31:2] == ld_addr[pend_sel][31:2]),
                                 stq_msk[dl][ld_addr[pend_sel][1:0]],
                                 (((stq_rob[dl] - rob_head) & 7'h7F) <
                                  ((ld_rob[pend_sel] - rob_head) & 7'h7F)));
            end
        end
    end

endmodule
