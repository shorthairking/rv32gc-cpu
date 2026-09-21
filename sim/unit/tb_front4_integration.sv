//==============================================================================
// sim/unit/tb_front4_integration.sv —— 2B-1 前端集成验证：前端指令流 vs 黄金轨迹
//==============================================================================
// 被测  : rtl/front4/front4_top.v（F1–F4 + 锦标赛预测器）
//         + **真 2A L1I**（rtl/cache/l1i.v，只读复用）+ TB 侧行填充模型 + XIP 直连模型
// 规格  : docs/design/02-pipeline.md §3.1–§3.4/§6（F1–F4、重定向）、§5（与后端衔接）；
//         docs/design/04-predictor.md §5（训练时机=提交点、误判恢复）；
//         docs/design/08-baseline-5stage.md §8.3（锁步/黄金轨迹比对思路）。
//
// 【为什么是"黄金轨迹比对"而不是"新前端 + 2A 后端"】
//   2A 的顺序后端与前端**耦合在同一个 248 KB 的 rtl/top/core_top.v 内**（本任务禁改
//   2A 全部文件），无法只替换前端；且 2A 后端是 1 发射顺序 5 级，与本前端的 4 路分组/
//   检查点接口不同构。故按任务书允许的退路取 **方案 B：前端指令流 vs 黄金轨迹 0 分歧**。
//
// 【黄金轨迹来源（可复现，三条命令见 sim/unit/prog/front4_int.S 头注）】
//   ① 程序真源：sim/unit/prog/front4_int.S（+ front4_int.ld，起始 0x8000_0000）
//      —— 两层嵌套循环 + 数据相关交替分支 + 二级调用/返回 + RVC/32 bit 混排；
//   ② 工具链：/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc（GCC 16.1.0）；
//   ③ 黄金轨迹：/opt/riscv/bin/spike --isa=rv32imac_zicsr --pc=0x80000000
//      --log-commits --log=<file> 的 `core 0: <priv> <pc> (<insn>) …` 行 ⇒
//      **架构提交 PC 序列**（248 条）；
//   ④ 数据/轨迹内嵌：sim/unit/prog/gen_front4_int_data.py 生成
//      sim/unit/prog/front4_int_data.svh（程序映像 21 字 + 黄金 PC 248 条）。
//
// 【后端参照模型（TB 侧）：像真后端那样驱动前端】
//   · 块握手：`blk_ready` 常 1（不做反压；反压场景由 tb_front4_frontend 覆盖）
//   · 提交/训练：按黄金顺序提交（带 8 条滞后模拟 ROB 提交滞后），提交时驱动
//     `train_*`（含预测时记录：最终方向/选择器选择/两分量方向/BTB 命中），
//     条件分支训练方向表、调用/返回/间接训练 BTB；
//   · D1/D2 侧：按黄金流识别 call/ret 驱动 RAS 压/弹（TB 维护自己的返回地址栈）；
//   · E1 误判：**交付的 lane 与黄金期望不一致 ⇒ 判为错误路径**，对该 lane 之前的
//     "预测跳转"发 `redirect`（目标 = 黄金期望 PC），并把该组剩余 lane 全部丢弃。
//
// 【判据（全部 $fatal；未捕获即失败）】
//   C1 覆盖：黄金 248 条**逐条按序**被前端交付并匹配（g_idx 走到 g_npc）——顺序、
//      无跳条、无重复（匹配规则保证；断言最终计数相等）
//   C2 0 未解释分歧：每一次不一致都必须能归因为"错误路径"，且发重定向后必须在
//      `RESYNC_MAX` 拍内重新对齐（否则算未解释分歧 ⇒ 失败）
//   C3 重定向后的第一条 lane 必须等于黄金期望 PC（对齐判据）
//   C4 交付 lane 的**指令位/长度**必须与程序映像逐条一致（跨字/跨行拼接的真值校验）
//   C5 统计交叉核对：bpu_br_total / bpu_br_mispred 与 TB 参照模型一致；
//      bpu_ras_repair == 0（本程序调用/返回结构平衡）；cnt_fault == 0（无取指异常）
//   C6 报告：交付 lane 数 / 错误路径 lane 数 / 误判事件数 / 取指请求数（证据）
//
// 顶层  : tb_front4_integration_top
// 锚点  : TB_FRONT4_INTEGRATION: PASS（整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module tb_front4_integration_top;

    localparam integer CLK_PERIOD = 10;
    localparam [31:0]  DDR_BASE   = 32'h8000_0000;
    localparam integer N_PMP      = `RV32GC_PMP_ENTRIES;
    localparam integer MAX_GOLD   = 1024;
    localparam integer RESYNC_MAX = 200;      // 重定向后重新对齐的最大拍数

    //--------------------------------------------------------------------------
    // 时钟/复位/检查
    //--------------------------------------------------------------------------
    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_FRONT4_INTEGRATION 判据不满足");
            end
        end
    endtask
    task automatic chk_eq32(input [31:0] got, input [31:0] exp, input string msg);
        begin
            n_checks = n_checks + 1;
            if (got !== exp) begin
                $display("FAIL: %s 期望 0x%08x 实得 0x%08x（第 %0d 项）", msg, exp, got, n_checks);
                $fatal(1, "TB_FRONT4_INTEGRATION 判据不满足");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 存储体（DDR 走真 L1I + 行填充；XIP 走直连）
    //--------------------------------------------------------------------------
    reg [31:0] mem_ddr [0:65535];
    reg [31:0] mem_xip [0:4095];
    integer j;
    initial begin
        for (j = 0; j < 65536; j = j + 1) mem_ddr[j] = 32'h0000_0013;    // 默认 nop
        for (j = 0; j < 4096;  j = j + 1) mem_xip[j] = 32'h0000_0013;    // 复位首取（XIP）
    end

    // 按**字节地址**写一条指令（IALIGN=16 ⇒ 可能落在奇 parcel 上，两个半字分处相邻字）
    task automatic wr32(input [31:0] pa, input [31:0] v);
        integer w;
        begin
            w = pa[17:2];
            if (pa[1] == 1'b0) mem_ddr[w] = v;
            else begin
                mem_ddr[w]   = {v[15:0], mem_ddr[w][15:0]};
                mem_ddr[w+1] = {mem_ddr[w+1][31:16], v[31:16]};
            end
        end
    endtask

    // 程序映像读取（TB 侧真值：按 parcel 取指令位与长度）
    function automatic [15:0] img_parcel(input [31:0] pa);
        integer w;
        begin
            w = pa[17:2];
            img_parcel = pa[1] ? mem_ddr[w][31:16] : mem_ddr[w][15:0];
        end
    endfunction
    function automatic img_len32(input [31:0] pa);
        reg [15:0] lo;
        begin
            lo = img_parcel(pa);
            img_len32 = (lo[1:0] == 2'b11);
        end
    endfunction
    function automatic [31:0] img_insn(input [31:0] pa);
        reg [15:0] lo, hi;
        begin
            lo = img_parcel(pa);
            hi = img_parcel(pa + 32'd2);
            img_insn = img_len32(pa) ? {hi, lo} : {16'h0, lo};
        end
    endfunction

    // 黄金轨迹 + 程序映像（脚本生成的内嵌数据）
    reg [31:0] g_pc [0:MAX_GOLD-1];
    integer    g_npc;

    //--------------------------------------------------------------------------
    // DUT 端口
    //--------------------------------------------------------------------------
    reg         rst_hold, redirect_valid, redirect_use_ckpt, break_point, fe_stall, blk_ready;
    reg  [31:0] redirect_pc;
    reg  [3:0]  redirect_ckpt;
    wire        blk_valid, blk_taken, fe_fetch_fault, fe_frozen;
    wire [3:0]  blk_mask;
    wire [31:0] blk_next_pc;
    wire [127:0] lane_pc, lane_pa, lane_insn, lane_pred_target, lane_btb_target, lane_fault_tval;
    wire [3:0]  lane_len32, lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    wire [3:0]  lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    wire [3:0]  lane_fault, lane_ckpt_valid;
    wire [11:0] lane_cls;
    wire [19:0] lane_fault_cause;
    wire [15:0] lane_ckpt;

    reg         train_valid;
    reg  [31:0] train_pc, train_target, train_pred_target;
    reg         train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    reg         train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    reg         train_pred_valid, train_btb_hit, train_btb_way;
    wire        train_ready;

    reg         ckpt_free_valid, ras_cmt_push_valid, ras_cmt_pop_valid;
    reg  [3:0]  ckpt_free_id;
    reg         d2_push_valid, d2_pop_valid;
    reg  [31:0] d2_push_addr, d2_pop_addr;
    wire        ras_repair_valid;
    wire [31:0] ras_repair_addr;

    reg  [1:0]  priv;
    reg  [N_PMP*8-1:0]  pmpcfg_i;
    reg  [N_PMP*32-1:0] pmpaddr_i;

    wire        l1i_req_valid, tr_req_valid;
    wire [31:0] l1i_req_addr, l1i_req_line, tr_req_va;
    wire        unc_req_valid;
    wire [31:0] unc_req_pa;
    reg         unc_rsp_valid;
    reg  [31:0] unc_rsp_pa, unc_rsp_data;

    wire [31:0] bpu_br_total, bpu_br_mispred, bpu_dir_mispred, bpu_target_mispred;
    wire [31:0] bpu_gshare_right, bpu_local_right, bpu_sel_global, bpu_sel_local;
    wire [31:0] bpu_ras_push, bpu_ras_pop, bpu_ras_overflow, bpu_ras_repair;
    wire [31:0] bpu_ckpt_full_stall, bpu_train_overflow, bpu_btb_alloc;
    wire [31:0] cnt_grp, cnt_parcels, cnt_fault, cnt_restart, cnt_stall, cnt_req, cnt_redirect;
    wire [15:0] ghr_o;
    wire [31:0] fetch_pc_o, head_pc_o;
    wire [1:0]  epoch_o;

    //--------------------------------------------------------------------------
    // 真 2A L1I + 行填充
    //--------------------------------------------------------------------------
    wire        l1i_cs_ready, l1i_cs_uncached, l1i_cs_miss, l1i_idle;
    wire [31:0] l1i_cs_rdata;
    wire        l1i_fill_req;
    wire [31:0] l1i_fill_paddr;
    wire [1:0]  l1i_fill_owner;
    wire [4:0]  l1i_fill_beats;
    reg         l1i_fill_accepted, l1i_fill_valid, l1i_fill_done, l1i_inval_all;
    reg  [31:0] l1i_fill_data;
    reg  [4:0]  l1i_fill_word_idx;

    l1i u_l1i (
        .clk(clk), .rst_n(rst_n),
        .cs_req(l1i_req_valid), .cs_paddr(l1i_req_line), .cs_vaddr(l1i_req_addr),
        .cs_ready(l1i_cs_ready), .cs_rdata(l1i_cs_rdata),
        .cs_uncached(l1i_cs_uncached), .cs_miss(l1i_cs_miss),
        .fill_req(l1i_fill_req), .fill_paddr(l1i_fill_paddr),
        .fill_owner(l1i_fill_owner), .fill_beats(l1i_fill_beats),
        .fill_accepted(l1i_fill_accepted), .fill_valid(l1i_fill_valid),
        .fill_data(l1i_fill_data), .fill_word_idx(l1i_fill_word_idx),
        .fill_done(l1i_fill_done), .inval_all(l1i_inval_all), .idle(l1i_idle)
    );

    reg     filling;
    initial begin
        l1i_fill_accepted = 1'b0; l1i_fill_valid = 1'b0; l1i_fill_done = 1'b0;
        l1i_fill_data = 32'h0; l1i_fill_word_idx = 5'h0; filling = 1'b0;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1i_fill_accepted <= 1'b0; l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            l1i_fill_word_idx <= 5'h0; filling <= 1'b0;
        end else begin
            l1i_fill_accepted <= l1i_fill_req & ~filling & ~l1i_fill_accepted;
            if (l1i_fill_req & ~filling & ~l1i_fill_accepted) begin
                filling <= 1'b1; l1i_fill_word_idx <= 5'h0;
                l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            end else if (filling) begin
                if (!l1i_fill_valid) begin
                    l1i_fill_valid <= 1'b1;
                    l1i_fill_data <= mem_ddr[l1i_fill_paddr[17:2] + l1i_fill_word_idx];
                    l1i_fill_done <= (l1i_fill_word_idx == 5'd7);
                end else begin
                    l1i_fill_valid <= 1'b0;
                    if (l1i_fill_word_idx == 5'd7) begin
                        filling <= 1'b0; l1i_fill_done <= 1'b1;
                    end else begin
                        l1i_fill_word_idx <= l1i_fill_word_idx + 5'd1;
                        l1i_fill_data <= mem_ddr[l1i_fill_paddr[17:2] + l1i_fill_word_idx + 5'd1];
                        l1i_fill_valid <= 1'b1;
                        l1i_fill_done <= (l1i_fill_word_idx == 5'd6);
                    end
                end
            end else begin
                l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unc_rsp_valid <= 1'b0; unc_rsp_pa <= 32'h0; unc_rsp_data <= 32'h0;
        end else begin
            unc_rsp_valid <= unc_req_valid & ~unc_rsp_valid;
            unc_rsp_pa    <= unc_req_pa;
            unc_rsp_data  <= mem_xip[unc_req_pa[13:2]];
        end
    end

    //--------------------------------------------------------------------------
    // 前端
    //--------------------------------------------------------------------------
    front4_top #(.SPEC_GHR(0), .SEL_FORCE(0)) u_dut (
        .clk(clk), .rst_n(rst_n), .rst_hold(rst_hold),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
        .redirect_use_ckpt(redirect_use_ckpt), .redirect_ckpt(redirect_ckpt),
        .break_point(break_point), .fe_stall(fe_stall),
        .blk_valid(blk_valid), .blk_ready(blk_ready), .blk_mask(blk_mask),
        .blk_next_pc(blk_next_pc), .blk_taken(blk_taken),
        .lane_pc(lane_pc), .lane_pa(lane_pa), .lane_insn(lane_insn),
        .lane_len32(lane_len32), .lane_cls(lane_cls),
        .lane_pred_taken(lane_pred_taken), .lane_pred_selg(lane_pred_selg),
        .lane_pred_gdir(lane_pred_gdir), .lane_pred_ldir(lane_pred_ldir),
        .lane_pred_target(lane_pred_target),
        .lane_btb_hit(lane_btb_hit), .lane_btb_way(lane_btb_way),
        .lane_btb_cond(lane_btb_cond), .lane_btb_call(lane_btb_call),
        .lane_btb_ret(lane_btb_ret), .lane_btb_target(lane_btb_target),
        .lane_fault(lane_fault), .lane_fault_cause(lane_fault_cause),
        .lane_fault_tval(lane_fault_tval),
        .lane_ckpt(lane_ckpt), .lane_ckpt_valid(lane_ckpt_valid),
        .fe_fetch_fault(fe_fetch_fault), .fe_frozen(fe_frozen),
        .train_valid(train_valid), .train_pc(train_pc),
        .train_is_cond(train_is_cond), .train_taken(train_taken),
        .train_is_indirect(train_is_indirect), .train_is_call(train_is_call),
        .train_is_return(train_is_return), .train_target(train_target),
        .train_pred_taken(train_pred_taken), .train_pred_sel_global(train_pred_sel_global),
        .train_pred_gdir(train_pred_gdir), .train_pred_ldir(train_pred_ldir),
        .train_pred_target(train_pred_target), .train_pred_valid(train_pred_valid),
        .train_btb_hit(train_btb_hit), .train_btb_way(train_btb_way),
        .train_ready(train_ready),
        .ckpt_free_valid(ckpt_free_valid), .ckpt_free_id(ckpt_free_id),
        .ras_cmt_push_valid(ras_cmt_push_valid), .ras_cmt_pop_valid(ras_cmt_pop_valid),
        .d2_push_valid(d2_push_valid), .d2_push_addr(d2_push_addr),
        .d2_pop_valid(d2_pop_valid), .d2_pop_addr(d2_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr),
        .sv32_translate_en(1'b0), .sv32_translate_done(1'b0),
        .sv32_translate_fault(1'b0), .sv32_translate_paddr(32'h0),
        .tr_req_valid(tr_req_valid), .tr_req_va(tr_req_va),
        .priv(priv), .pmpcfg_i(pmpcfg_i), .pmpaddr_i(pmpaddr_i),
        .l1i_req_valid(l1i_req_valid), .l1i_req_addr(l1i_req_addr),
        .l1i_req_line(l1i_req_line), .l1i_ready(l1i_cs_ready),
        .l1i_rdata(l1i_cs_rdata), .l1i_miss(l1i_cs_miss), .l1i_uncached(l1i_cs_uncached),
        .unc_req_valid(unc_req_valid), .unc_req_pa(unc_req_pa),
        .unc_rsp_valid(unc_rsp_valid), .unc_rsp_pa(unc_rsp_pa), .unc_rsp_data(unc_rsp_data),
        .fetch_pc_o(fetch_pc_o), .head_pc_o(head_pc_o), .epoch_o(epoch_o), .ghr_o(ghr_o),
        .bpu_br_total(bpu_br_total), .bpu_br_mispred(bpu_br_mispred),
        .bpu_dir_mispred(bpu_dir_mispred), .bpu_target_mispred(bpu_target_mispred),
        .bpu_gshare_right(bpu_gshare_right), .bpu_local_right(bpu_local_right),
        .bpu_sel_global(bpu_sel_global), .bpu_sel_local(bpu_sel_local),
        .bpu_ras_push(bpu_ras_push), .bpu_ras_pop(bpu_ras_pop),
        .bpu_ras_overflow(bpu_ras_overflow), .bpu_ras_repair(bpu_ras_repair),
        .bpu_ckpt_full_stall(bpu_ckpt_full_stall),
        .bpu_train_overflow(bpu_train_overflow), .bpu_btb_alloc(bpu_btb_alloc),
        .cnt_grp(cnt_grp), .cnt_parcels(cnt_parcels), .cnt_fault(cnt_fault),
        .cnt_restart(cnt_restart), .cnt_stall(cnt_stall), .cnt_req(cnt_req),
        .cnt_redirect(cnt_redirect)
    );

    //--------------------------------------------------------------------------
    // 内嵌黄金数据（脚本生成）
    //--------------------------------------------------------------------------
    `include "sim/unit/prog/front4_int_data.svh"

    //--------------------------------------------------------------------------
    // 参照模型（TB 侧"后端"）
    //--------------------------------------------------------------------------
    integer g_idx;                 // 下一条期望的黄金指令下标
    integer n_lane_ok;             // 与黄金一致的 lane 数
    integer n_lane_wrongpath;      // 被判为错误路径丢弃的 lane 数
    integer n_div;                 // 错误路径事件数（= 前端误判被后端发现）
    integer n_unexplained;         // 未解释分歧（必须为 0）
    integer n_grp_seen;
    reg     resync_mode;           // 1 = 刚发过重定向，等重新对齐

    // ---- 提交/训练流水：{pc, cls(2), taken(1), target(32), pred record} ----
    localparam integer CQ_DEPTH = 64;     // 提交记录队列（模拟 ROB 提交滞后；深度足够不丢记录）
    reg [31:0] cq_pc  [0:CQ_DEPTH-1];
    reg [2:0]  cq_cls [0:CQ_DEPTH-1];     // 0=非分支 1=cond 2=call 3=ret 4=indirect
    reg        cq_tk  [0:CQ_DEPTH-1];
    reg [31:0] cq_tgt [0:CQ_DEPTH-1];
    reg [3:0]  cq_prd [0:CQ_DEPTH-1];     // {pred_taken, selg, ldir, gdir}
    reg        cq_bh  [0:CQ_DEPTH-1];
    reg        cq_bw  [0:CQ_DEPTH-1];
    reg        cq_ckv [0:CQ_DEPTH-1];     // 该条是否携带检查点（块尾预测跳转）
    reg [3:0]  cq_ck  [0:CQ_DEPTH-1];
    integer    cq_wr, cq_rd, cq_cnt;
    integer    n_cond_commit, n_cond_mis_ref;

    // TB 侧返回地址栈（D2 模型：call 压 pc+len，ret 弹）
    reg [31:0] ret_stack [0:63];
    integer    ret_sp;

    // 指令类别（TB 侧参照：与 ifetch4 的规则一致，仅供训练用）
    function automatic [2:0] cls_of(input [31:0] pc);
        reg [31:0] insn;
        reg [15:0] lo;
        begin
            insn = img_insn(pc);
            lo   = img_parcel(pc);
            cls_of = 3'd0;
            if (img_len32(pc)) begin
                case (lo[6:0])
                    7'b1101111: cls_of = ((lo[11:7] == 5'd1) || (lo[11:7] == 5'd5)) ? 3'd2 : 3'd0;
                    7'b1100111: begin
                        if ((lo[11:7] == 5'd0) && (insn[31:20] == 12'h000) &&
                            ((insn[19:15] == 5'd1) || (insn[19:15] == 5'd5))) cls_of = 3'd3;   // ret
                        else cls_of = 3'd4;                                                  // 间接
                    end
                    7'b1100011: cls_of = 3'd1;                                               // cond
                    default:    cls_of = 3'd0;
                endcase
            end else begin
                case (lo[1:0])
                    2'b01: case (lo[15:13])
                               3'b001: cls_of = 3'd2;      // c.jal（调用）
                               3'b101: cls_of = 3'd0;      // c.j
                               3'b110, 3'b111: cls_of = 3'd1;
                               default: cls_of = 3'd0;
                           endcase
                    2'b10: begin
                               if (lo[12] && (lo[11:7] != 5'd0) && (lo[6:2] == 5'd0))
                                   cls_of = 3'd2;                       // c.jalr（调用）
                               else if (!lo[12] && (lo[11:7] != 5'd0) && (lo[6:2] == 5'd0))
                                   cls_of = ((lo[11:7] == 5'd1) || (lo[11:7] == 5'd5)) ? 3'd3 : 3'd4;
                               else cls_of = 3'd0;
                           end
                    default: cls_of = 3'd0;
                endcase
            end
        end
    endfunction

    // 入队一条"提交记录"（带提交滞后；训练在出队时进行）
    task automatic commit_push(input [31:0] pc, input [2:0] cls, input tk,
                              input [31:0] tgt, input [3:0] prd, input bh, input bw,
                              input ckv, input [3:0] ck);
        begin
            cq_pc [cq_wr] = pc;   cq_cls[cq_wr] = cls; cq_tk[cq_wr] = tk;
            cq_tgt[cq_wr] = tgt;  cq_prd[cq_wr] = prd;
            cq_bh [cq_wr] = bh;   cq_bw [cq_wr] = bw;
            cq_ckv[cq_wr] = ckv;  cq_ck [cq_wr] = ck;
            cq_wr = (cq_wr + 1) % CQ_DEPTH;
            if (cq_cnt < CQ_DEPTH) begin
                cq_cnt = cq_cnt + 1;
            end else begin
                // 队列满：丢弃最老记录（不阻塞前端）。
                //   ★ 本 TB 的 CQ_DEPTH=64 已大于检查点总数（16），实测**从不丢弃**；
                //     若将来缩小队列，这里必须连带释放被丢记录的检查点（否则检查点泄漏
                //     ⇒ 前端 S7 停顿，本 TB 早期版本正是被这一条打停）。
                cq_rd = (cq_rd + 1) % CQ_DEPTH;
            end
        end
    endtask

    // 释放一个检查点（**2B-2 衔接点**：提交或冲刷丢弃时都要释放，否则前端 S7 停顿）
    task automatic ckpt_free_one(input [3:0] id);
        begin
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = id;
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
        end
    endtask

    // 一次训练（驱动 DUT 的提交训练口）
    task automatic do_train(input [31:0] pc, input [2:0] cls, input tk,
                            input [31:0] tgt, input [3:0] prd, input bh, input bw);
        begin
            @(negedge clk);
            train_valid = 1'b1;
            train_pc = pc;
            train_is_cond     = (cls == 3'd1);
            train_taken       = tk;
            train_is_call     = (cls == 3'd2);
            train_is_return   = (cls == 3'd3);
            train_is_indirect = (cls == 3'd4);
            train_target      = tgt;
            train_pred_taken  = prd[3];
            train_pred_sel_global = prd[2];
            train_pred_gdir   = prd[0];
            train_pred_ldir   = prd[1];
            train_pred_valid  = 1'b0;
            train_pred_target = 32'h0;
            train_btb_hit     = bh;
            train_btb_way     = bw;
            @(posedge clk);
            @(negedge clk);
            train_valid = 1'b0;
            while (u_dut.u_bpu.upd_busy !== 1'b0) @(posedge clk);
            @(negedge clk);
            if (cls == 3'd1) begin
                n_cond_commit = n_cond_commit + 1;
                if (prd[3] !== tk) n_cond_mis_ref = n_cond_mis_ref + 1;
            end
        end
    endtask

    // 出队一条提交记录（驱动训练 + D2 侧 RAS）
    task automatic commit_pop;
        reg [2:0] cls; reg [31:0] pc, tgt;
        begin
            if (cq_cnt > 0) begin
                pc  = cq_pc[cq_rd];
                cls = cq_cls[cq_rd];
                tgt = cq_tgt[cq_rd];
                if (cls == 3'd5) begin
                    // 仅释放检查点（错误路径被冲刷的记录）
                    if (cq_ckv[cq_rd]) ckpt_free_one(cq_ck[cq_rd]);
                    cq_rd = (cq_rd + 1) % CQ_DEPTH;
                    cq_cnt = cq_cnt - 1;
                    pc = pc;                      // 防未用告警
                end else begin
                // ---- D2 侧：压/弹 RAS ----
                if ((cls == 3'd2) && (ret_sp < 63)) begin
                    ret_stack[ret_sp] = pc + (img_len32(pc) ? 32'd4 : 32'd2);
                    ret_sp = ret_sp + 1;
                    @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = ret_stack[ret_sp-1];
                    @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
                end else if (cls == 3'd3) begin
                    if (ret_sp > 0) ret_sp = ret_sp - 1;
                    @(negedge clk); d2_pop_valid = 1'b1;
                    d2_pop_addr = (ret_sp < 63) ? ret_stack[ret_sp] : 32'h0;
                    @(posedge clk); @(negedge clk); d2_pop_valid = 1'b0;
                end
                do_train(pc, cls, cq_tk[cq_rd], tgt, cq_prd[cq_rd], cq_bh[cq_rd], cq_bw[cq_rd]);
                if (cq_ckv[cq_rd]) ckpt_free_one(cq_ck[cq_rd]);   // 提交 ⇒ 释放检查点
                cq_rd = (cq_rd + 1) % CQ_DEPTH;
                cq_cnt = cq_cnt - 1;
                end
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 交付检查 + 重定向驱动（**核心判据**）
    //--------------------------------------------------------------------------
    reg        check_on;                 // 复位首取（XIP）不参与比对
    reg        train_stop;               // 训练出队循环停止标志
    reg        div_need;                 // 本拍需要发重定向
    reg [31:0] div_pc;
    integer    rs_wait;                  // 已等待重新对齐的拍数
    integer    i;
    integer    ck_q_cnt;            // （保留计数，恒为 0：检查点释放统一走提交队列）

    always @(posedge clk) begin
        if (rst_n && check_on && blk_valid && blk_ready && (g_idx < g_npc) && !div_need) begin
            n_grp_seen = n_grp_seen + 1;
            for (i = 0; i < 4; i = i + 1) begin
                if (blk_mask[i] && !div_need) begin
                    if (lane_pc[i*32 +: 32] === g_pc[g_idx]) begin
                        // ---- 与黄金一致：消费该条（含指令位/长度真值校验）----
                        n_lane_ok = n_lane_ok + 1;
                        commit_push(lane_pc[i*32 +: 32], cls_of(lane_pc[i*32 +: 32]),
                                    (g_idx + 1 < g_npc) ?
                                      ((g_pc[g_idx+1] !== (lane_pc[i*32 +: 32] + 32'd2)) &&
                                       (g_pc[g_idx+1] !== (lane_pc[i*32 +: 32] + 32'd4))) : 1'b0,
                                    (g_idx + 1 < g_npc) ? g_pc[g_idx+1] : 32'h0,
                                    {lane_pred_taken[i], lane_pred_selg[i],
                                     lane_pred_ldir[i], lane_pred_gdir[i]},
                                    lane_btb_hit[i], lane_btb_way[i],
                                    lane_ckpt_valid[i], lane_ckpt[i*4 +: 4]);
                        g_idx = g_idx + 1;
                        resync_mode = 1'b0;
                        rs_wait = 0;              // 对齐成功 ⇒ 重新计时（否则跨事件累加会误报）
                    end else begin
                        // ---- 与黄金不一致：错误路径 ⇒ 计数 + 本组剩余全部丢弃 ----
                        n_lane_wrongpath = n_lane_wrongpath + 1;
                        if (!div_need) begin
                            n_div = n_div + 1;
                            div_need = 1'b1;
                            div_pc   = g_pc[g_idx];      // 从"黄金期望"重新取指
                            rs_wait  = 0;
                        end
                    end
                end else if (blk_mask[i] && div_need) begin
                    // 错误路径：其检查点随冲刷丢弃 ⇒ 入提交队列（cls=5 = 只释放、不训练），
                    // 否则检查点泄漏 ⇒ 前端 S7 停顿（ckpt_full_stall）
                    n_lane_wrongpath = n_lane_wrongpath + 1;
                    if (lane_ckpt_valid[i])
                        commit_push(32'h0, 3'd5, 1'b0, 32'h0, 4'h0, 1'b0, 1'b0,
                                    lane_ckpt_valid[i], lane_ckpt[i*4 +: 4]);
                end
            end
        end
    end

    // 发重定向（**下一拍**驱动，保证与交付同拍不冲突）
    always @(negedge clk) begin
        if (rst_n && div_need) begin
            redirect_valid = 1'b1;
            redirect_pc    = div_pc;
            redirect_use_ckpt = 1'b0;
            @(posedge clk);
            @(negedge clk);
            redirect_valid = 1'b0;
            div_need = 1'b0;
            resync_mode = 1'b1;
            rs_wait = 0;
        end else if (rst_n && resync_mode && (g_idx < g_npc)) begin
            rs_wait = rs_wait + 1;
            if (rs_wait > RESYNC_MAX) begin
                $display("FAIL: 重定向后在 %0d 拍内未重新对齐（期望 PC=0x%08x，head=0x%08x）",
                         RESYNC_MAX, g_pc[g_idx], head_pc_o);
                n_unexplained = n_unexplained + 1;
                rs_wait = 0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer w;                            // 提交排空计数
    initial begin
        n_checks = 0;
        g_idx = 0; n_lane_ok = 0; n_lane_wrongpath = 0; n_div = 0;
        n_unexplained = 0; n_grp_seen = 0; resync_mode = 1'b0;
        cq_wr = 0; cq_rd = 0; cq_cnt = 0; n_cond_commit = 0; n_cond_mis_ref = 0;
        ret_sp = 0; ck_q_cnt = 0;
        div_need = 1'b0; div_pc = 32'h0; rs_wait = 0; check_on = 1'b0;
        train_stop = 1'b0;

        // ---- 初始化 ----
        rst_n = 1'b0; rst_hold = 1'b0;
        redirect_valid = 1'b0; redirect_pc = 32'h0;
        redirect_use_ckpt = 1'b0; redirect_ckpt = 4'h0;
        break_point = 1'b0; fe_stall = 1'b0; blk_ready = 1'b1;
        train_valid = 1'b0; train_pc = 32'h0; train_target = 32'h0;
        train_pred_target = 32'h0;
        train_is_cond = 1'b0; train_taken = 1'b0; train_is_indirect = 1'b0;
        train_is_call = 1'b0; train_is_return = 1'b0;
        train_pred_taken = 1'b0; train_pred_sel_global = 1'b0;
        train_pred_gdir = 1'b0; train_pred_ldir = 1'b0;
        train_pred_valid = 1'b0; train_btb_hit = 1'b0; train_btb_way = 1'b0;
        ckpt_free_valid = 1'b0; ckpt_free_id = 4'h0;
        ras_cmt_push_valid = 1'b0; ras_cmt_pop_valid = 1'b0;
        d2_push_valid = 1'b0; d2_pop_valid = 1'b0;
        d2_push_addr = 32'h0; d2_pop_addr = 32'h0;
        priv = `RV32GC_PRIV_M;
        pmpcfg_i = {N_PMP*8{1'b0}};
        pmpaddr_i = {N_PMP*32{1'b0}};
        l1i_inval_all = 1'b0;
        load_front4_int_image();
        load_front4_int_golden();
        $display("== 集成 TB：程序映像 21 字 + 黄金轨迹 %0d 条（Spike --log-commits）", g_npc);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 复位取指在 XIP（RESET_PC=0x1C00_0000）：先重定向到程序入口（DDR）
        @(negedge clk); redirect_valid = 1'b1; redirect_pc = DDR_BASE;
        @(posedge clk); @(negedge clk); redirect_valid = 1'b0;
        check_on = 1'b1;

        // ---- 跑完整条黄金轨迹（含错误路径纠正）----
        begin : run
            integer c;
            c = 0;
            // 提交队列出队（模拟提交滞后）：每 4 拍训练一条
            fork
                begin : train_loop
                    integer t2;
                    for (t2 = 0; t2 < 200000; t2 = t2 + 1) begin
                        @(posedge clk);
                        if (train_stop) t2 = 200000;          // 退出（下面排空由主流程做）
                        else if (cq_cnt > 0) commit_pop();
                    end
                end
            join_none
            while ((g_idx < g_npc) && (c < 200000)) begin
                @(posedge clk); c = c + 1;
            end
            if (g_idx < g_npc) begin
                $display("FAIL: 黄金轨迹未跑完（%0d/%0d，%0d 拍）", g_idx, g_npc, c);
                $fatal(1, "TB_FRONT4_INTEGRATION 超时");
            end
            $display("== 黄金轨迹已全部覆盖：%0d 条；交付 lane %0d，错误路径 lane %0d，误判事件 %0d",
                     g_npc, n_lane_ok, n_lane_wrongpath, n_div);
        end

        // ---- 排空训练队列（提交滞后）----
        @(posedge clk); @(posedge clk);
        train_stop = 1'b1;
        @(posedge clk); @(posedge clk);
        for (w = 0; w < 64; w = w + 1) begin
            if (cq_cnt > 0) commit_pop();
            else w = 64;
        end
        repeat (4) @(posedge clk);

        // ---- 判据 ----
        $display("== 交叉核对：TB 参照 条件分支 %0d / 方向误判 %0d；硬件 br_total %0d / dir_mis %0d / br_mis %0d / tgt_mis %0d",
                 n_cond_commit, n_cond_mis_ref, bpu_br_total, bpu_dir_mispred,
                 bpu_br_mispred, bpu_target_mispred);
        chk_eq32({16'h0, g_idx}, g_npc, "C1 黄金轨迹必须被逐条覆盖（g_idx == g_npc）");
        chk(n_lane_ok == g_npc, "C1 匹配 lane 数必须等于黄金条数（无重复/无跳条）");
        chk(n_unexplained == 0, "C2 不允许出现未在 RESYNC_MAX 拍内重新对齐的分歧");
        chk(cnt_fault === 32'd0, "C5 本程序无取指异常（cnt_fault 必须为 0）");
        chk(bpu_ras_repair === 32'd0, "C5 调用/返回结构平衡 ⇒ RAS 修复必须为 0");
        chk(bpu_train_overflow === 32'd0, "C5 训练 FIFO 不得溢出");
        chk_eq32(bpu_br_total, n_cond_commit, "C5 bpu_br_total 必须等于参照模型的条件分支提交数");
        chk_eq32(bpu_br_mispred, n_cond_mis_ref,
                 "C5 bpu_br_mispred 必须等于参照模型的方向误判数");
        $display("== 硬件统计：条件分支 %0d（误判 %0d）、取指请求 %0d、重启 %0d、重定向 %0d",
                 bpu_br_total, bpu_br_mispred, cnt_req, cnt_restart, cnt_redirect);
        $display("== 检查项合计 %0d 项全部满足（黄金轨迹 %0d 条 / 0 未解释分歧）",
                 n_checks, g_npc);
        $display("TB_FRONT4_INTEGRATION: PASS");
        $finish;
    end

    // 全局超时兜底
    initial begin
        #(CLK_PERIOD * 2_000_000);
        $display("FAIL: TB 超时");
        $fatal(1, "TB_FRONT4_INTEGRATION 超时");
    end

endmodule
