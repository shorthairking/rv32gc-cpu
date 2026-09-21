//==============================================================================
// sim/unit/tb_front4_frontend.sv —— 2B-1 四发射顺序前端单元 TB（F1–F4 全链）
//==============================================================================
// 被测  : rtl/front4/front4_top.v（pc_gen4 + predictor_top + ifetch4）
//         + **真 2A L1I**（rtl/cache/l1i.v，只读复用）+ TB 侧行填充模型 + XIP 直连模型
// 规格  : docs/design/02-pipeline.md §3.1–§3.4（F1–F4）、§4（4 路取指停顿/冻结）、
//         §6（重定向类别 A/D）；docs/design/04-predictor.md §2（F2 查表）；
//         docs/design/08-baseline-5stage.md §4.3/§5.1（2A 取指/L1I 契约）。
//
// 【判据（逐条可复现；全部 $fatal ⇒ 未捕获即失败）】
//   C1 **4 路分组**：后端反压让取指缓冲预取，释放后**一拍交出 4 条**（mask=4'hF），
//      4 个 lane 的 PC/指令位/长度逐条正确；随后顺序流与期望列表 0 分歧。
//   C2 **跨字/跨行拼接**：32 bit 指令的低半在 4 B 字/32 B 行**末尾**时，必须等下一个
//      字/行到齐才交付，且拼出的 32 bit 指令位与原像一致（两条用例：0x8002、0x801E）。
//   C3 **跳转组终止**：块尾为"预测跳转"（方向预测 taken / 直接跳转）⇒ 块在它终止、
//      `blk_taken=1`、`blk_next_pc` = 预测目标；下一块**必须**从该目标开始。
//   C4 **XIP 旁路**：取指 PA 命中 SPI 窗口 ⇒ `l1i_req_valid` 恒 0（不查 L1I）、
//      数据来自直连通路；用"两个存储体放不同指令"做**差分**判据（防假过）。
//   C5 **回退重定向**：`redirect_valid` 后，下一块必须从 `redirect_pc` 开始，
//      且不得再出现旧流的任何指令（陈旧数据必须被 epoch 丢弃）。
//   C6 **取指 PMP**：把一条 32 bit 指令跨到的第二个 parcel 划到"无 X 权限"的 PMP 区间，
//      该 lane 必须打 fault（cause=1、tval=故障 parcel 的 VA）、块在它终止、
//      前端冻结直到重定向。
//
// 说明：本 TB **不**自证"持续带宽"——2A L1I 是 1 字/拍，4 路分组靠缓冲吸收突发
//   （C1 用后端反压制造该场景）。持续带宽口径差异见 rtl/front4/README.md §4。
// 顶层  : tb_front4_frontend_top
// 锚点  : TB_FRONT4_FRONTEND: PASS（整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module tb_front4_frontend_top;

    localparam integer CLK_PERIOD = 10;
    localparam [31:0]  DDR_BASE   = 32'h8000_0000;
    localparam [31:0]  XIP_BASE   = `RV32GC_RESET_PC;      // 0x1C00_0000
    localparam integer N_PMP      = `RV32GC_PMP_ENTRIES;

    //--------------------------------------------------------------------------
    // 时钟/复位
    //--------------------------------------------------------------------------
    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_FRONT4_FRONTEND 判据不满足");
            end
        end
    endtask
    task automatic chk_eq32(input [31:0] got, input [31:0] exp, input string msg);
        begin
            n_checks = n_checks + 1;
            if (got !== exp) begin
                $display("FAIL: %s 期望 0x%08x 实得 0x%08x（第 %0d 项）", msg, exp, got, n_checks);
                $fatal(1, "TB_FRONT4_FRONTEND 判据不满足");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 指令编码辅助（真编码，保证 ifetch4 的分支分类器可用）
    //--------------------------------------------------------------------------
    function automatic [31:0] enc_jal(input [4:0] rd, input [20:0] imm21);
        begin
            enc_jal = {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, 7'b110_1111};
        end
    endfunction
    function automatic [31:0] enc_jalr(input [4:0] rd, input [4:0] rs1, input [11:0] imm12);
        begin
            enc_jalr = {imm12, rs1, 3'b000, rd, 7'b110_0111};
        end
    endfunction
    function automatic [31:0] enc_beq(input [4:0] rs1, input [4:0] rs2, input [12:0] imm13);
        begin
            enc_beq = {imm13[12], imm13[10:5], rs2, rs1, 3'b000,
                       imm13[4:1], imm13[11], 7'b110_0011};
        end
    endfunction
    function automatic [15:0] enc_c_j(input [11:0] imm12);
        begin // CJ 型：offset[11|4|9:8|10|6|7|3:1|5]
            enc_c_j = {3'b101, imm12[11], imm12[4], imm12[9:8], imm12[10],
                       imm12[6], imm12[7], imm12[3:1], imm12[5], 2'b01};
        end
    endfunction
    function automatic [15:0] enc_c_addi(input [4:0] rd, input [5:0] imm6);
        begin
            enc_c_addi = {3'b000, imm6[5], rd, imm6[4:0], 2'b01};
        end
    endfunction
    function automatic [31:0] enc_addi(input [4:0] rd, input [4:0] rs1, input [11:0] imm12);
        begin
            enc_addi = {imm12, rs1, 3'b000, rd, 7'b001_0011};
        end
    endfunction

    //--------------------------------------------------------------------------
    // 存储体：DDR（走真 L1I + 行填充）与 XIP（走直连通路）
    //--------------------------------------------------------------------------
    reg [31:0] mem_ddr [0:65535];      // 按 PA[17:2] 索引（256 KB 视窗）
    reg [31:0] mem_xip [0:4095];       // 按 PA[13:2] 索引（16 KB 视窗）
    integer    j;
    initial begin
        for (j = 0; j < 65536; j = j + 1) mem_ddr[j] = 32'h0000_0013;   // 默认 nop
        for (j = 0; j < 4096;  j = j + 1) mem_xip[j] = 32'h0000_0013;
    end

    function automatic [31:0] ddr_rd(input [31:0] pa);
        begin ddr_rd = mem_ddr[pa[17:2]]; end
    endfunction
    function automatic [31:0] xip_rd(input [31:0] pa);
        begin xip_rd = mem_xip[pa[13:2]]; end
    endfunction
    // 按**字节地址**写一条 32 bit 指令（IALIGN=16 ⇒ 可能落在奇 parcel 上，
    //   这时它的两个 16 bit parcel 分处相邻两个字 ⇒ 必须分别写入，否则会覆盖前一条指令）
    task automatic wr32(input [31:0] pa, input [31:0] v);
        integer widx;
        begin
            widx = pa[17:2];
            if (pa[1] == 1'b0) begin
                mem_ddr[widx] = v;
            end else begin
                // 指令低半在**本字高半**，指令高半在**下一字低半**
                mem_ddr[widx]   = {v[15:0], mem_ddr[widx][15:0]};
                mem_ddr[widx+1] = {mem_ddr[widx+1][31:16], v[31:16]};
            end
        end
    endtask
    task automatic wr16(input [31:0] pa, input [15:0] v);     // 按半字地址（parcel）写
        integer widx;
        begin
            widx = pa[17:2];
            if (pa[1] == 1'b0) mem_ddr[widx] = {mem_ddr[widx][31:16], v};
            else               mem_ddr[widx] = {v, mem_ddr[widx][15:0]};
        end
    endtask
    task automatic xip_wr32(input [31:0] pa, input [31:0] v);
        integer widx;
        begin
            widx = pa[13:2];
            if (pa[1] == 1'b0) mem_xip[widx] = v;
            else begin
                mem_xip[widx]   = {v[15:0], mem_xip[widx][15:0]};
                mem_xip[widx+1] = {mem_xip[widx+1][31:16], v[31:16]};
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // DUT 端口
    //--------------------------------------------------------------------------
    reg         rst_hold;
    reg         redirect_valid, redirect_use_ckpt;
    reg  [31:0] redirect_pc;
    reg  [3:0]  redirect_ckpt;
    reg         break_point, fe_stall;

    wire        blk_valid, blk_taken, fe_fetch_fault, fe_frozen;
    reg         blk_ready;
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
    reg  [31:0] train_pc;
    reg         train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    reg  [31:0] train_target;
    reg         train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    reg         train_pred_valid, train_btb_hit, train_btb_way;
    reg  [31:0] train_pred_target;
    wire        train_ready;

    reg         ckpt_free_valid;
    reg  [3:0]  ckpt_free_id;
    reg         ras_cmt_push_valid, ras_cmt_pop_valid;
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

    wire [31:0] bpu_br_total, bpu_br_mispred, bpu_dir_mispred, bpu_target_mispred;
    wire [31:0] bpu_gshare_right, bpu_local_right, bpu_sel_global, bpu_sel_local;
    wire [31:0] bpu_ras_push, bpu_ras_pop, bpu_ras_overflow, bpu_ras_repair;
    wire [31:0] bpu_ckpt_full_stall, bpu_train_overflow, bpu_btb_alloc;
    wire [31:0] cnt_grp, cnt_parcels, cnt_fault, cnt_restart, cnt_stall, cnt_req, cnt_redirect;
    wire [15:0] ghr_o;
    wire [31:0] fetch_pc_o, head_pc_o;
    wire [1:0]  epoch_o;

    //--------------------------------------------------------------------------
    // 真 2A L1I + 行填充模型
    //--------------------------------------------------------------------------
    reg         l1i_cs_req;
    reg  [31:0] l1i_cs_addr, l1i_cs_line;
    wire        l1i_cs_ready, l1i_cs_uncached, l1i_cs_miss, l1i_idle;
    wire [31:0] l1i_cs_rdata;
    wire        l1i_fill_req;
    wire [31:0] l1i_fill_paddr;
    wire [1:0]  l1i_fill_owner;
    wire [4:0]  l1i_fill_beats;
    reg         l1i_fill_accepted, l1i_fill_valid, l1i_fill_done;
    reg  [31:0] l1i_fill_data;
    reg  [4:0]  l1i_fill_word_idx;
    reg         l1i_inval_all;

    l1i u_l1i (
        .clk(clk), .rst_n(rst_n),
        .cs_req(l1i_cs_req), .cs_paddr(l1i_cs_line), .cs_vaddr(l1i_cs_addr),
        .cs_ready(l1i_cs_ready), .cs_rdata(l1i_cs_rdata),
        .cs_uncached(l1i_cs_uncached), .cs_miss(l1i_cs_miss),
        .fill_req(l1i_fill_req), .fill_paddr(l1i_fill_paddr),
        .fill_owner(l1i_fill_owner), .fill_beats(l1i_fill_beats),
        .fill_accepted(l1i_fill_accepted), .fill_valid(l1i_fill_valid),
        .fill_data(l1i_fill_data), .fill_word_idx(l1i_fill_word_idx),
        .fill_done(l1i_fill_done), .inval_all(l1i_inval_all), .idle(l1i_idle)
    );

    // 行填充响应（逐 beat，读 TB 存储体；带 1 拍间隔模拟 DDR 延迟）
    integer fill_k;
    reg     filling;
    initial begin
        l1i_fill_accepted = 1'b0; l1i_fill_valid = 1'b0; l1i_fill_done = 1'b0;
        l1i_fill_data = 32'h0; l1i_fill_word_idx = 5'h0; filling = 1'b0;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1i_fill_accepted <= 1'b0; l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            l1i_fill_word_idx <= 5'h0;
        end else begin
            l1i_fill_accepted <= l1i_fill_req & ~filling & ~l1i_fill_accepted;
            if (l1i_fill_req & ~filling & ~l1i_fill_accepted) begin
                filling <= 1'b1;
                l1i_fill_word_idx <= 5'h0;
                l1i_fill_valid <= 1'b0;
                l1i_fill_done <= 1'b0;
            end else if (filling) begin
                if (!l1i_fill_valid) begin
                    l1i_fill_valid <= 1'b1;
                    l1i_fill_data <= mem_ddr[l1i_fill_paddr[17:2] + l1i_fill_word_idx];
                    l1i_fill_done <= (l1i_fill_word_idx == 5'd7);
                end else begin
                    l1i_fill_valid <= 1'b0;
                    if (l1i_fill_word_idx == 5'd7) begin
                        filling <= 1'b0;
                        l1i_fill_done <= 1'b1;
                    end else begin
                        l1i_fill_word_idx <= l1i_fill_word_idx + 5'd1;
                        l1i_fill_data <= mem_ddr[l1i_fill_paddr[17:2] + l1i_fill_word_idx + 5'd1];
                        l1i_fill_valid <= 1'b1;
                        l1i_fill_done <= (l1i_fill_word_idx == 5'd6);
                    end
                end
            end else begin
                l1i_fill_valid <= 1'b0;
                l1i_fill_done <= 1'b0;
            end
        end
    end

    // XIP 直连模型（1 拍延迟 + 地址回显）
    reg        unc_rsp_valid;
    reg [31:0] unc_rsp_pa, unc_rsp_data;
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
    // 前端实例
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

    // L1I 请求接线（DUT cs 侧 → 真 l1i）
    always @(*) begin
        l1i_cs_req  = l1i_req_valid;
        l1i_cs_addr = l1i_req_addr;
        l1i_cs_line = l1i_req_line;
    end

    //--------------------------------------------------------------------------
    // 期望流参照（TB 侧）：PC → {insn, len32}
    //--------------------------------------------------------------------------
    reg [31:0] exp_pc   [0:1023];
    reg [31:0] exp_insn [0:1023];
    reg        exp_l32  [0:1023];
    integer    n_exp;
    integer    exp_idx;             // 已交付的期望项数

    task automatic exp_add(input [31:0] pc, input [31:0] insn, input len32);
        begin
            exp_pc[n_exp] = pc; exp_insn[n_exp] = insn; exp_l32[n_exp] = len32;
            n_exp = n_exp + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 交付检查（逐 lane 与期望流比对；组结构也被记录）
    //--------------------------------------------------------------------------
    integer    n_lane_seen;
    reg        check_en;            // 期望流比对开关（复位后的 XIP 首取不参与比对）
    reg        check_tol;           // 1 = 期望表耗尽后允许继续交付（只计数不比对）
    integer    grp_idx;
    reg [3:0]  grp0_mask; reg [31:0] grp0_pc0; integer n_grp4;    // C1 统计
    integer    i4_found;
    integer    xip_l1i_hits;         // C4：XIP 地址上出现的 L1I 请求数（必须为 0）
    // 故障捕获（C6：必须在**交付那一拍**采样，冻结后 lane 组合输出已换成新块）
    reg        fault_seen;
    reg [31:0] fault_tval_cap;
    reg [4:0]  fault_cause_cap;
    reg [31:0] fault_pc_cap;
    integer    n_taken_grp;          // C3 统计

    task automatic walk_group;
        integer li, k;
        reg [31:0] p;
        begin
            for (li = 0; li < 4; li = li + 1) begin
                if (blk_mask[li]) begin
                    // 与期望流比对（逐 lane 对齐；C3 终止时下一组从目标继续）
                    if (exp_idx >= n_exp) begin
                        if (!check_tol) begin
                            $display("FAIL: 交付超出期望流（exp_idx=%0d，lane pc=0x%08x）",
                                     exp_idx, lane_pc[li*32 +: 32]);
                            $fatal(1, "TB_FRONT4_FRONTEND 交付超出期望");
                        end
                    end else begin
                        chk_eq32(lane_pc[li*32 +: 32], exp_pc[exp_idx],
                                 "交付 lane 的 PC 必须与期望流一致");
                        chk_eq32(lane_insn[li*32 +: 32], exp_insn[exp_idx],
                                 "交付 lane 的指令位必须与期望一致（含跨字/跨行拼接）");
                        chk(lane_len32[li] === exp_l32[exp_idx], "交付 lane 的指令长度必须正确");
                        if (lane_fault[li]) begin
                            fault_seen      = 1'b1;
                            fault_tval_cap  = lane_fault_tval[li*32 +: 32];
                            fault_cause_cap = lane_fault_cause[li*5 +: 5];
                            fault_pc_cap    = lane_pc[li*32 +: 32];
                        end
                        chk_eq32(lane_pa[li*32 +: 32], lane_pc[li*32 +: 32],
                                 "Bare 模式：lane PA 必须等于 lane VA");
                    end
                    exp_idx = (exp_idx < n_exp) ? (exp_idx + 1) : exp_idx;
                    n_lane_seen = n_lane_seen + 1;
                end
            end
            // 组结构：终止拍必须是"预测跳转"且 next_pc == 末 lane 的预测目标
            if (blk_taken) begin
                n_taken_grp = n_taken_grp + 1;
                begin : tk_ck
                    integer kk;
                    reg [31:0] tgt;
                    kk = 3;
                    while ((kk >= 0) && !blk_mask[kk]) kk = kk - 1;
                    tgt = lane_pred_target[kk*32 +: 32];
                    chk_eq32(blk_next_pc, tgt, "跳转终止组的 next_pc 必须等于末 lane 的预测目标");
                    chk(lane_pred_taken[kk] === 1'b1, "终止 lane 的预测方向必须为 taken");
                end
            end
            // 期望流按顺序推进：若本组跳转终止 ⇒ 期望索引跳到目标处
            if (blk_taken) begin
                begin : jump_exp
                    integer m;
                    m = exp_idx;
                    // 期望流中目标之后的项：本 TB 构造轨迹时保证目标是顺序后的某一项
                    //   ⇒ 这里把 exp_idx 对齐到"PC == next_pc"的第一项
                    while ((m < n_exp) && (exp_pc[m] != blk_next_pc)) m = m + 1;
                    chk(m < n_exp, "期望流中必须包含跳转目标（TB 构造保证）");
                    exp_idx = m;
                end
            end
            grp_idx = grp_idx + 1;
        end
    endtask

    // 交付拍：采样并检查（blk_ready 恒 1，除非测试主动反压）
    always @(posedge clk) begin
        if (rst_n && check_en && blk_valid && blk_ready) begin
            if (grp_idx == 0) begin
                grp0_mask = blk_mask; grp0_pc0 = lane_pc[31:0];
                if (blk_mask == 4'hF) i4_found = i4_found + 1;
            end else if (blk_mask == 4'hF) i4_found = i4_found + 1;
            walk_group();
        end
    end

    // C4 监视：XIP 地址上绝不允许出现 L1I 请求
    always @(posedge clk) begin
        if (rst_n && l1i_req_valid &&
            (((l1i_req_addr[31:20] & `RV32GC_XIP_HI20_MSK) == `RV32GC_XIP_HI20_VAL) ||
             (l1i_req_addr[31:16] == `RV32GC_SPI_HIT_VAL)))
            xip_l1i_hits = xip_l1i_hits + 1;
    end

    //--------------------------------------------------------------------------
    // 基本操作任务
    //--------------------------------------------------------------------------
    task automatic dut_init;
        begin
            rst_n = 1'b0; rst_hold = 1'b0;
            redirect_valid = 1'b0; redirect_pc = 32'h0;
            redirect_use_ckpt = 1'b0; redirect_ckpt = 4'h0;
            break_point = 1'b0; fe_stall = 1'b0; blk_ready = 1'b1;
            train_valid = 1'b0; train_pc = 32'h0;
            train_is_cond = 1'b0; train_taken = 1'b0; train_is_indirect = 1'b0;
            train_is_call = 1'b0; train_is_return = 1'b0; train_target = 32'h0;
            train_pred_taken = 1'b0; train_pred_sel_global = 1'b0;
            train_pred_gdir = 1'b0; train_pred_ldir = 1'b0;
            train_pred_valid = 1'b0; train_btb_hit = 1'b0; train_btb_way = 1'b0;
            train_pred_target = 32'h0;
            ckpt_free_valid = 1'b0; ckpt_free_id = 4'h0;
            ras_cmt_push_valid = 1'b0; ras_cmt_pop_valid = 1'b0;
            d2_push_valid = 1'b0; d2_pop_valid = 1'b0;
            d2_push_addr = 32'h0; d2_pop_addr = 32'h0;
            priv = `RV32GC_PRIV_M;                    // M 模式 + 无 PMP 项 ⇒ 取指全放行
            pmpcfg_i = {N_PMP*8{1'b0}};
            pmpaddr_i = {N_PMP*32{1'b0}};
            l1i_inval_all = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // 训练一条条件分支（把方向预测拉成期望值）
    task automatic train_cond(input [31:0] pc, input taken, input integer times);
        integer t;
        begin
            for (t = 0; t < times; t = t + 1) begin
                @(negedge clk);
                train_valid = 1'b1; train_pc = pc;
                train_is_cond = 1'b1; train_taken = taken;
                train_is_indirect = 1'b0; train_is_call = 1'b0; train_is_return = 1'b0;
                train_target = pc + 32'd4;
                train_pred_taken = taken; train_pred_sel_global = 1'b0;
                train_pred_gdir = taken; train_pred_ldir = taken;
                train_pred_valid = 1'b0; train_pred_target = 32'h0;
                train_btb_hit = 1'b0; train_btb_way = 1'b0;
                @(posedge clk);
                @(negedge clk);
                train_valid = 1'b0;
                // 排空训练引擎（避免与随后的取指查表抢更新时序）
                while (u_dut.u_bpu.upd_busy !== 1'b0) @(posedge clk);
                @(negedge clk);
            end
        end
    endtask

    // 重定向（类别 C：全冲刷）
    task automatic do_redirect(input [31:0] pc);
        begin
            @(negedge clk);
            redirect_valid = 1'b1; redirect_pc = pc;
            redirect_use_ckpt = 1'b0; redirect_ckpt = 4'h0;
            @(posedge clk);
            @(negedge clk);
            redirect_valid = 1'b0;
        end
    endtask

    task automatic wait_expect(input integer n_expected, input integer max_cycles);
        integer c;
        begin
            c = 0;
            while ((n_lane_seen < n_expected) && (c < max_cycles)) begin
                @(posedge clk); c = c + 1;
            end
            if (n_lane_seen < n_expected) begin
                $display("FAIL: 等待交付 %0d 条超时（实测 %0d 条，%0d 拍）",
                         n_expected, n_lane_seen, max_cycles);
                $fatal(1, "TB_FRONT4_FRONTEND 交付超时");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 程序映像与期望流构造
    //--------------------------------------------------------------------------
    //   C1/C2 用同一段程序（DDR 0x8000_0000 起）：
    //     0x8000 c.addi x1,1      (16)
    //     0x8002 addi  x2,x0,2    (32)   ← 跨 4 B 字（低半在字高半）
    //     0x8006 c.addi x3,1      (16)
    //     0x8008 nop              (32)
    //     0x800C c.addi x4,1      (16)
    //     0x800E addi  x5,x0,5    (32)
    //     0x8012 c.nop            (16)
    //     0x8014 nop              (32)
    //     0x8018 c.addi x6,1      (16)
    //     0x801A c.addi x7,1      (16)
    //     0x801C nop              (32)
    //     0x801E addi  x8,x0,8    (32)   ← 低半是 32 B 行最后一个 parcel（跨行）
    //     0x8022 c.nop            (16)
    //     0x8024 jal x1,+8        (32)   ← 预测跳转（直接跳转，恒 taken）
    //     0x8028 nop  ← 被跳过（不期望）
    //     0x802C c.addi x9,1      (16)   ← 跳转目标
    //     0x802E nop              (32)
    //--------------------------------------------------------------------------
    task automatic build_image;
        begin
            // ---- 程序映像（DDR 0x8000_0000 起；地址逐条不重叠）----
            wr16(32'h8000_0000, enc_c_addi(5'd1, 6'd1));            // 0x8000 c.addi x1,1  (16)
            wr32(32'h8000_0002, enc_addi(5'd2, 5'd0, 12'd2));       // 0x8002 addi x2,0,2  (32, 跨字)
            wr16(32'h8000_0006, enc_c_addi(5'd3, 6'd1));            // 0x8006 c.addi x3,1  (16)
            wr32(32'h8000_0008, enc_addi(5'd0, 5'd0, 12'd0));       // 0x8008 nop          (32)
            wr16(32'h8000_000C, enc_c_addi(5'd4, 6'd1));            // 0x800C c.addi x4,1  (16)
            wr32(32'h8000_000E, enc_addi(5'd5, 5'd0, 12'd5));       // 0x800E addi x5,0,5  (32, 跨字)
            wr16(32'h8000_0012, enc_c_addi(5'd0, 6'd0));            // 0x8012 c.nop        (16)
            wr32(32'h8000_0014, enc_addi(5'd0, 5'd0, 12'd0));       // 0x8014 nop          (32)
            wr16(32'h8000_0018, enc_c_addi(5'd6, 6'd1));            // 0x8018 c.addi x6,1  (16)
            wr16(32'h8000_001A, enc_c_addi(5'd7, 6'd1));            // 0x801A c.addi x7,1  (16)
            wr16(32'h8000_001C, enc_c_addi(5'd0, 6'd0));            // 0x801C c.nop        (16)
            wr32(32'h8000_001E, enc_addi(5'd8, 5'd0, 12'd8));       // 0x801E addi x8,0,8  (32, **跨 32 B 行**)
            wr16(32'h8000_0022, enc_c_addi(5'd9, 6'd1));            // 0x8022 c.addi x9,1  (16)
            wr32(32'h8000_0024, enc_addi(5'd0, 5'd0, 12'd0));       // 0x8024 nop          (32)
            wr32(32'h8000_0028, enc_jal(5'd1, 21'd8));              // 0x8028 jal x1,+8 → 0x8030
            wr32(32'h8000_002C, enc_addi(5'd0, 5'd0, 12'd0));       // 0x802C nop（被跳过）
            wr16(32'h8000_0030, enc_c_addi(5'd10, 6'd1));           // 0x8030 c.addi x10,1（目标）
            wr32(32'h8000_0032, enc_addi(5'd0, 5'd0, 12'd0));       // 0x8032 nop          (32)
            // ---- 期望流（按预测路径；jal 为直接跳转 ⇒ 恒 taken，块在它终止）----
            exp_add(32'h8000_0000, {16'h0, enc_c_addi(5'd1, 6'd1)}, 1'b0);
            exp_add(32'h8000_0002, enc_addi(5'd2, 5'd0, 12'd2), 1'b1);
            exp_add(32'h8000_0006, {16'h0, enc_c_addi(5'd3, 6'd1)}, 1'b0);
            exp_add(32'h8000_0008, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
            exp_add(32'h8000_000C, {16'h0, enc_c_addi(5'd4, 6'd1)}, 1'b0);
            exp_add(32'h8000_000E, enc_addi(5'd5, 5'd0, 12'd5), 1'b1);
            exp_add(32'h8000_0012, {16'h0, enc_c_addi(5'd0, 6'd0)}, 1'b0);
            exp_add(32'h8000_0014, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
            exp_add(32'h8000_0018, {16'h0, enc_c_addi(5'd6, 6'd1)}, 1'b0);
            exp_add(32'h8000_001A, {16'h0, enc_c_addi(5'd7, 6'd1)}, 1'b0);
            exp_add(32'h8000_001C, {16'h0, enc_c_addi(5'd0, 6'd0)}, 1'b0);
            exp_add(32'h8000_001E, enc_addi(5'd8, 5'd0, 12'd8), 1'b1);
            exp_add(32'h8000_0022, {16'h0, enc_c_addi(5'd9, 6'd1)}, 1'b0);
            exp_add(32'h8000_0024, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
            exp_add(32'h8000_0028, enc_jal(5'd1, 21'd8), 1'b1);
            exp_add(32'h8000_0030, {16'h0, enc_c_addi(5'd10, 6'd1)}, 1'b0);
            exp_add(32'h8000_0032, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
            // 程序之后的填充（TB 存储体默认值 = 32 bit nop 0x0000_0013 组成的字），
            //   按 **parcel 流** 推期望：每个 nop 字拆成 0x0013 / 0x0000 两个 16 bit parcel
            exp_add(32'h8000_0036, 32'h0000_0000, 1'b0);
            exp_add(32'h8000_0038, 32'h0000_0013, 1'b0);
            exp_add(32'h8000_003A, 32'h0000_0000, 1'b0);
            exp_add(32'h8000_003C, 32'h0000_0013, 1'b0);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer c2, c3;
    initial begin
        n_checks = 0; n_lane_seen = 0; exp_idx = 0; grp_idx = 0; check_en = 1'b0; check_tol = 1'b0;
        n_grp4 = 0; i4_found = 0; xip_l1i_hits = 0; n_taken_grp = 0;
        fault_seen = 1'b0; fault_tval_cap = 32'h0; fault_cause_cap = 5'h0; fault_pc_cap = 32'h0;
        n_exp = 0; grp0_mask = 4'h0; grp0_pc0 = 32'h0;
        build_image();
        dut_init();

        //======================================================================
        // C1 + C2 + C3：DDR 段（反压预取 ⇒ 4 路分组；流与期望 0 分歧）
        //======================================================================
        $display("== C1/C2/C3：DDR 段分组、跨字/跨行拼接、跳转终止");
        do_redirect(DDR_BASE);
        // 用**后端反压**（blk_ready=0）让前端把整行预取进 parcel 缓冲
        //   （L1I 走缺失→行填充；这段也可观察"1 字/拍"持续带宽下缓冲的蓄水作用）
        blk_ready = 1'b0;
        repeat (200) @(posedge clk);
        blk_ready = 1'b1;
        check_en  = 1'b1;
        exp_idx   = 0; n_lane_seen = 0;
        $display("DBG C1 buf[0]v=%b d=%h va=%h | buf[1]v=%b d=%h va=%h | buf[2]v=%b d=%h va=%h | buf[3]v=%b d=%h va=%h",
                 u_dut.u_ifetch4.buf_q[0][0], u_dut.u_ifetch4.buf_q[0][16:1], u_dut.u_ifetch4.buf_q[0][48:17],
                 u_dut.u_ifetch4.buf_q[1][0], u_dut.u_ifetch4.buf_q[1][16:1], u_dut.u_ifetch4.buf_q[1][48:17],
                 u_dut.u_ifetch4.buf_q[2][0], u_dut.u_ifetch4.buf_q[2][16:1], u_dut.u_ifetch4.buf_q[2][48:17],
                 u_dut.u_ifetch4.buf_q[3][0], u_dut.u_ifetch4.buf_q[3][16:1], u_dut.u_ifetch4.buf_q[3][48:17]);
        // 释放后应能一拍交出 4 条（缓冲已预取）
        wait_expect(4, 400);
        chk(i4_found >= 1, "C1 释放反压后必须出现 4 路（mask=4'hF）分组");
        chk(grp0_mask === 4'hF, "C1 第一个分组必须是 4 路满块");
        chk_eq32(grp0_pc0, DDR_BASE, "C1 第一个分组的 lane0 PC 必须是取指起点");
        // 继续跑到 jal 终止（期望流共 16 条：14 条 DDR 顺序 + 目标 2 条）
        wait_expect(16, 600);
        check_en = 1'b0;              // 后续填充指令不再参与比对（期望表到此为止）
        chk(n_taken_grp >= 1, "C3 必须出现至少一次跳转终止组");
        chk(cnt_restart >= 32'd1, "C3 跳转终止必须触发取指流重启（cnt_restart ≥ 1）");
        // C2 专项：跨字指令（0x8002）与跨行指令（0x801E）已在上面的逐条比对中覆盖
        $display("   C1/C2/C3 完成：交付 %0d 条，4 路分组 %0d 次，跳转终止 %0d 次",
                 n_lane_seen, i4_found, n_taken_grp);

        //======================================================================
        // C4 XIP 旁路（差分判据：DDR 与 XIP 同偏移放不同指令）
        //======================================================================
        $display("== C4：XIP 旁路（不查 L1I，数据来自直连通路）");
        xip_wr32(XIP_BASE + 32'h10, enc_addi(5'd11, 5'd0, 12'h123));   // XIP 侧
        xip_wr32(XIP_BASE + 32'h14, enc_addi(5'd12, 5'd0, 12'h456));
        // DDR 侧同偏移（0x8000_0010/14）已由 build_image 写入其它指令 ⇒ 数据不同
        exp_idx = 0; n_exp = 0; exp_add(XIP_BASE + 32'h10, enc_addi(5'd11, 5'd0, 12'h123), 1'b1);
        exp_add(XIP_BASE + 32'h14, enc_addi(5'd12, 5'd0, 12'h456), 1'b1);
        exp_add(XIP_BASE + 32'h18, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);   // XIP 侧默认 nop
        exp_add(XIP_BASE + 32'h1C, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
        exp_add(XIP_BASE + 32'h20, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
        exp_add(XIP_BASE + 32'h24, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
        n_lane_seen = 0;
        check_en = 1'b1; check_tol = 1'b1;      // C4 尾部填充不参与比对
        do_redirect(XIP_BASE + 32'h10);
        repeat (20) @(posedge clk);
        wait_expect(2, 400);
        check_en = 1'b0;
        chk(xip_l1i_hits === 0, "C4 命中 SPI 窗口时绝不允许向 L1I 发起请求");
        $display("   C4 完成：XIP 交付 2 条，L1I 上 XIP 地址请求数 = %0d", xip_l1i_hits);

        //======================================================================
        // C5 回退重定向（陈旧数据必须被丢弃）
        //======================================================================
        $display("== C5：回退重定向");
        exp_idx = 0; n_exp = 0; n_lane_seen = 0;
        exp_add(DDR_BASE + 32'h0022, {16'h0, enc_c_addi(5'd9, 6'd1)}, 1'b0);
        exp_add(DDR_BASE + 32'h0024, enc_addi(5'd0, 5'd0, 12'd0), 1'b1);
        exp_add(DDR_BASE + 32'h0028, enc_jal(5'd1, 21'd8), 1'b1);
        exp_add(DDR_BASE + 32'h0030, {16'h0, enc_c_addi(5'd10, 6'd1)}, 1'b0);
        check_en = 1'b1; check_tol = 1'b1;      // C5 尾部填充不参与比对
        do_redirect(DDR_BASE + 32'h0022);
        wait_expect(4, 400);
        check_en = 1'b0;
        chk(epoch_o >= 2'd1, "C5 重定向必须推进 epoch（丢弃在途/陈旧响应）");
        $display("   C5 完成：重定向后交付 %0d 条（无陈旧数据）", n_lane_seen);

        //======================================================================
        // C6 取指 PMP：把 0x8020 起的区间设为无 X 权限
        //   程序里 0x801E 的 32 bit 指令跨到 0x8020 ⇒ 第二个 parcel 被拒 ⇒
        //   lane 打 fault、cause=1、tval = 0x8020、块在它终止、前端冻结
        //======================================================================
        $display("== C6：取指 PMP（无 X 权限 ⇒ fault + 冻结）");
        // PMP 项 15（扁平最高字节）：**NA4** 精确覆盖 4 B：PA 0x8000_0020..0x8000_0023，
        //   X=0 W=0 R=0 ⇒ 该 4 B 内取指被拒；其余项全 OFF（M 模式无匹配 ⇒ 放行）。
        //   ★ pmpaddr 口径 = PA>>2（PA 是**物理地址**，本程序在 0x8000_0000 ⇒
        //     pmpaddr = 0x8000_0020>>2 = 0x2000_0008，**不是** 0x2008）
        //   ★ L=1（locked）：M 模式下**只有 locked 项**才约束访问（ISA 口径）
        pmpcfg_i[N_PMP*8-1 -: 8] = 8'h90;         // {L=1,0,A=NA4(10),X=0,W=0,R=0}
        pmpaddr_i[N_PMP*32-1 -: 32] = 32'h2000_0008;
        exp_idx = 0; n_exp = 0; n_lane_seen = 0;
        // 期望：0x801E 这条**不能**作为完整指令交付（第二个 parcel 无 X）⇒ 该 lane 打 fault
        exp_add(DDR_BASE + 32'h001E, enc_addi(5'd8, 5'd0, 12'd8), 1'b1);
        check_en = 1'b1; check_tol = 1'b1;
        do_redirect(DDR_BASE + 32'h001E);
        begin : c6_wait
            integer c6;
            c6 = 0;
            while ((cnt_fault === 32'd0) && (c6 < 400)) begin
                @(posedge clk); c6 = c6 + 1;
            end
        end
        chk(cnt_fault >= 32'd1, "C6 无 X 权限的 parcel 必须触发取指 fault（cnt_fault ≥ 1）");
        #1;
        chk(u_dut.u_ifetch4.fault_hold_q === 1'b1,
            "C6 取指 fault 后前端必须冻结（fault_hold_q = 1，等后端重定向）");
        $display("   C6 故障：lane PC=0x%08x tval=0x%08x cause=%0d（期望 PC=0x8000_001E / tval=0x8000_0020 / cause=1）",
                 fault_pc_cap, fault_tval_cap, fault_cause_cap);
        chk(fault_seen === 1'b1, "C6 必须观察到带故障的 lane 交付");
        chk_eq32(fault_pc_cap, 32'h8000_001E, "C6 故障 lane 的指令地址必须是 0x8000_001E");
        chk_eq32(fault_tval_cap, 32'h8000_0020,
                 "C6 故障 tval 必须是故障 parcel 的 VA（第二 parcel 0x8000_0020）");
        chk(fault_cause_cap === 5'd1, "C6 故障 cause 必须是 1（instruction access fault）");
        pmpcfg_i = {N_PMP*8{1'b0}};               // 撤销 PMP 限制
        pmpaddr_i = {N_PMP*32{1'b0}};
        $display("   C6 完成：fault 次数 %0d，冻结生效", cnt_fault);

        //======================================================================
        // 汇总
        //======================================================================
        $display("== 检查项合计 %0d 项全部满足（分组 %0d 组 / 交付 %0d lane / 4 路块 %0d 次）",
                 n_checks, grp_idx, n_lane_seen, i4_found);
        $display("TB_FRONT4_FRONTEND: PASS");
        $finish;
    end

    // 全局超时兜底
    initial begin
        #(CLK_PERIOD * 400_000);
        $display("FAIL: TB 超时");
        $fatal(1, "TB_FRONT4_FRONTEND 超时");
    end

endmodule
