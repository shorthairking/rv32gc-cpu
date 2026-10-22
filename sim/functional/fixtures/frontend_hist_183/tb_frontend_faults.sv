//==============================================================================
// sim/functional/tb_frontend_faults.sv —— F4 前端叶模块功能定向 TB（故障/契约）
//==============================================================================
// 被测 : rtl/front4/front4_top.v（pc_gen4 + predictor_top + ifetch4）
// 目的 : 用**行为级 L1I/翻译模型**直打 F05-02/05/07/08/09 的正确行为：
//   T1 Sv32 **page fault（cause 12）**：页尾 32 bit 指令的第二 parcel 落在下一页且该页
//      翻译失败 ⇒ 交付 PC=指令起点(…ffe)、cause=12、tval=下一页首地址(…1000)；
//      **绝不**用 `sv32_translate_paddr` 的毒地址发 L1I 请求（记录器断言 0 次）。
//   T2 Sv32 **access fault（cause 1）**：同一路径 AF=1 ⇒ cause=1，tval 仍按 parcel VA。
//   T3 **高半起始**：重定向到 …002、其字基址 …000 翻译失败 ⇒ tval=…002（=PC+2，非 word base）。
//   T4 **第二 parcel 的 PMP 用自身 PA**：两页映射到**不连续** PA；32 bit 指令跨页，
//      仅拒第二页真实 PA ⇒ fault cause=1、tval=第二 parcel VA；基线"起始PA+2"会漏判。
//      （含允许两页的合法对照）
//   T5 **F05-05 检查点归属**：taken 块里只有**真正持有它的分支 lane** 的 ckpt_valid=1。
//   T6 **F05-07 反压稳定**：valid=1/ready=0 期间新增 parcel、改变 RAS 顶，mask/next_pc/
//      lane_pred_target 必须逐拍不变；`redirect` 取消快照（valid 掉、不推进）。
//   T7 **F05-08 逐 lane 真值**：交付 lane 的 insn/len 与映像一致；块首 PC == 上一块
//      blk_next_pc（预测流连续，分歧须由更老预测解释）。
//   T8 **F05-09**：`ras_repair_addr` 已被驱动（不得为 X/Z）。
//   T9 **吞吐**：无反压直线流必须出现 mask=4'b1111 的 4 路块（≥2 次），不因修复降规格。
//   E1 **F05-06 证据（不改预测器）**：记录 lu_en/lu_pc 与 F3 采到 pack 的**真实拍**关系，
//      仅打印 EVIDENCE 行并计数，不做通过/失败断言（本批只取证+方案）。
//
// 纪律 : 不 force 内部状态、不改预测器内部；全部通过真实端口时序驱动/观测。
// 锚点 : 唯一整行 `FUNCTIONAL_FRONTEND_FAULTS: PASS`。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module tb_frontend_faults_top;

    localparam integer N_PMP = `RV32GC_PMP_ENTRIES;

    reg clk, rst_n;
    initial begin clk = 1'b0; forever #5 clk = ~clk; end

    integer n_checks, n_fail;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                n_fail = n_fail + 1;
                $display("CHECK_FAIL(%0d): %s", n_checks, msg);
            end
        end
    endtask
    task automatic chk_eq32(input [31:0] got, input [31:0] exp, input string msg);
        begin
            n_checks = n_checks + 1;
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("CHECK_FAIL(%0d): %s exp=0x%08x got=0x%08x", n_checks, msg, exp, got);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // DUT 端口
    //--------------------------------------------------------------------------
    reg  [31:0] redirect_pc;
    reg         redirect_valid, redirect_use_ckpt, ckpt_clear_all, break_point, fe_stall;
    reg  [3:0]  redirect_ckpt;
    reg         blk_ready;
    wire        blk_valid, blk_taken, fe_fetch_fault, fe_frozen, ras_repair_valid;
    wire [3:0]  blk_mask, lane_len32, lane_pred_taken, lane_btb_hit, lane_btb_way;
    wire [3:0]  lane_btb_cond, lane_btb_call, lane_btb_ret, lane_fault, lane_ckpt_valid;
    wire [31:0] blk_next_pc, ras_repair_addr;
    wire [127:0] lane_pc, lane_pa, lane_insn, lane_pred_target, lane_btb_target, lane_fault_tval;
    wire [11:0] lane_cls;
    wire [19:0] lane_fault_cause;
    wire [15:0] lane_ckpt;

    wire [31:0] fetch_pc_o, head_pc_o;

    reg         ckpt_free_valid; reg [3:0] ckpt_free_id;
    reg         ras_cmt_push_valid, ras_cmt_pop_valid;
    reg         d2_push_valid, d2_pop_valid; reg [31:0] d2_push_addr, d2_pop_addr;

    reg         sv32_translate_en;
    wire        sv32_translate_done, sv32_translate_fault;
    wire        sv32_translate_fault_af;
    wire [31:0] sv32_translate_paddr;
    wire        tr_req_valid; wire [31:0] tr_req_va;

    reg  [1:0]  priv;
    reg  [N_PMP*8-1:0]  pmpcfg_i;
    reg  [N_PMP*32-1:0] pmpaddr_i;

    wire        l1i_req_valid; wire [31:0] l1i_req_addr; wire [31:0] l1i_req_line;
    reg         l1i_ready, l1i_miss, l1i_uncached;
    //  响应错误注入（包B）：err_auto 按行自动注入（模拟 fill_fail），err_force 手动单拍
    reg         err_en; reg [31:0] err_line;
    reg         err_force; reg [31:0] err_force_pa;
    wire        err_auto;
    wire        l1i_rsp_err; wire [31:0] l1i_rsp_err_pa;
    assign err_auto       = err_en & l1i_req_valid &
                            (l1i_req_addr[31:5] == err_line[31:5]);
    assign l1i_rsp_err    = err_force | err_auto;
    assign l1i_rsp_err_pa = err_force ? err_force_pa : {l1i_req_addr[31:5], 5'b0};
    reg  [31:0] l1i_rdata;
    wire        unc_req_valid; wire [31:0] unc_req_pa;
    reg         unc_rsp_valid, unc_rsp_err; reg [31:0] unc_rsp_pa;
    reg  [31:0] unc_rsp_data;

    reg         train_valid; reg [31:0] train_pc, train_target, train_pred_target;
    reg         train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    reg         train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    reg         train_pred_valid, train_btb_hit, train_btb_way;
    wire        train_ready;

    front4_top #(.SPEC_GHR(0), .SEL_FORCE(0)) u_dut (
        .clk(clk), .rst_n(rst_n), .rst_hold(1'b0),
        .redirect_valid(redirect_valid), .ckpt_clear_all(ckpt_clear_all),
        .redirect_pc(redirect_pc), .redirect_use_ckpt(redirect_use_ckpt),
        .redirect_ckpt(redirect_ckpt), .break_point(break_point), .fe_stall(fe_stall),
        .blk_valid(blk_valid), .blk_ready(blk_ready), .blk_mask(blk_mask),
        .blk_next_pc(blk_next_pc), .blk_taken(blk_taken),
        .lane_pc(lane_pc), .lane_pa(lane_pa), .lane_insn(lane_insn),
        .lane_len32(lane_len32), .lane_cls(lane_cls),
        .lane_pred_taken(lane_pred_taken), .lane_pred_selg(), .lane_pred_gdir(),
        .lane_pred_ldir(), .lane_pred_target(lane_pred_target),
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
        .train_btb_hit(train_btb_hit), .train_btb_way(train_btb_way), .train_ready(train_ready),
        .ckpt_free_valid(ckpt_free_valid), .ckpt_free_id(ckpt_free_id),
        .ras_cmt_push_valid(ras_cmt_push_valid), .ras_cmt_pop_valid(ras_cmt_pop_valid),
        .d2_push_valid(d2_push_valid), .d2_push_addr(d2_push_addr),
        .d2_pop_valid(d2_pop_valid), .d2_pop_addr(d2_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr),
        .sv32_translate_en(sv32_translate_en), .sv32_translate_done(sv32_translate_done),
        .sv32_translate_fault(sv32_translate_fault),
        .sv32_translate_fault_af(sv32_translate_fault_af),
        .sv32_translate_paddr(sv32_translate_paddr),
        .tr_req_valid(tr_req_valid), .tr_req_va(tr_req_va),
        .priv(priv), .pmpcfg_i(pmpcfg_i), .pmpaddr_i(pmpaddr_i),
        .l1i_req_valid(l1i_req_valid), .l1i_req_addr(l1i_req_addr),
        .l1i_req_line(l1i_req_line), .l1i_ready(l1i_ready),
        .l1i_rdata(l1i_rdata), .l1i_miss(l1i_miss), .l1i_uncached(l1i_uncached),
        .l1i_rsp_err(l1i_rsp_err), .l1i_rsp_err_pa(l1i_rsp_err_pa),
        .unc_req_valid(unc_req_valid), .unc_req_pa(unc_req_pa),
        .unc_rsp_valid(unc_rsp_valid), .unc_rsp_pa(unc_rsp_pa), .unc_rsp_data(unc_rsp_data),
        .unc_rsp_err(unc_rsp_err),
        .fetch_pc_o(fetch_pc_o), .head_pc_o(head_pc_o), .epoch_o(), .ghr_o()
    );

    //--------------------------------------------------------------------------
    // 存储体（按 PA[17:2] 索引；未初始化 = c.nop）
    //--------------------------------------------------------------------------
    reg [31:0] mem [0:65535];
    integer mi;
    initial begin
        for (mi = 0; mi < 65536; mi = mi + 1) mem[mi] = 32'h0000_0013;
    end
    task automatic wr(input [31:0] pa, input [31:0] d);
        begin mem[pa[17:2]] = d; end
    endtask
    function automatic [31:0] mem_rd(input [31:0] pa);
        begin mem_rd = mem[pa[17:2]]; end
    endfunction

    //--------------------------------------------------------------------------
    // 行为级 L1I：请求后 1 拍 ready；记录每次真实请求地址（毒地址断言用）
    //--------------------------------------------------------------------------
    reg        l1i_pend;
    reg [31:0] l1i_addr_q;
    reg [31:0] req_log [0:255];
    integer    n_req;
    always @(posedge clk) begin
        if (!rst_n) begin
            l1i_ready <= 1'b0; l1i_pend <= 1'b0; l1i_addr_q <= 32'h0;
        end else begin
            l1i_ready <= 1'b0;
            if (l1i_req_valid && !l1i_pend && !err_auto) begin
                l1i_pend   <= 1'b1;
                l1i_addr_q <= l1i_req_addr;
                if (n_req < 256) req_log[n_req] = l1i_req_addr;
                n_req <= n_req + 1;
            end else if (l1i_pend) begin
                l1i_pend  <= 1'b0;
                l1i_ready <= 1'b1;
            end
        end
    end
    always @(*) l1i_rdata = mem_rd(l1i_addr_q);

    //--------------------------------------------------------------------------
    // 行为级翻译：按 VA 页查表；1 拍后 done/fault/af/paddr（paddr 保留页内偏移）
    //--------------------------------------------------------------------------
    reg [31:0] pg_pa  [0:255];
    reg        pg_flt [0:255];
    reg        pg_af  [0:255];
    reg        tr_done_q, tr_flt_q, tr_af_q;
    reg [31:0] tr_pa_q;
    reg [31:0] tr_off_q;
    integer pi;
    initial begin
        for (pi = 0; pi < 256; pi = pi + 1) begin
            pg_pa[pi] = 32'h0; pg_flt[pi] = 1'b0; pg_af[pi] = 1'b0;
        end
    end
    wire [7:0] tr_pg = tr_req_va[19:12];
    always @(posedge clk) begin
        if (!rst_n) begin
            tr_done_q <= 1'b0; tr_flt_q <= 1'b0; tr_af_q <= 1'b0;
            tr_pa_q <= 32'h0; tr_off_q <= 32'h0;
        end else if (sv32_translate_en && tr_req_valid) begin
            tr_done_q <= 1'b1;
            tr_flt_q  <= pg_flt[tr_pg];
            tr_af_q   <= pg_af[tr_pg];
            tr_pa_q   <= pg_pa[tr_pg];
            tr_off_q  <= {20'h0, tr_req_va[11:0]};
        end else begin
            tr_done_q <= 1'b0;
        end
    end
    assign sv32_translate_done     = tr_done_q;
    assign sv32_translate_fault    = tr_flt_q;
    assign sv32_translate_fault_af = tr_af_q;
    assign sv32_translate_paddr    = tr_pa_q | tr_off_q;

    //--------------------------------------------------------------------------
    // 复位/握手工具
    //--------------------------------------------------------------------------
    task automatic do_reset;
        begin
            rst_n = 1'b0; redirect_valid = 0; redirect_pc = 0; redirect_use_ckpt = 0;
            redirect_ckpt = 0; ckpt_clear_all = 0; break_point = 0; fe_stall = 0;
            blk_ready = 0; ckpt_free_valid = 0; ckpt_free_id = 0;
            ras_cmt_push_valid = 0; ras_cmt_pop_valid = 0;
            d2_push_valid = 0; d2_push_addr = 0; d2_pop_valid = 0; d2_pop_addr = 0;
            err_en = 0; err_line = 32'h0; err_force = 0; err_force_pa = 32'h0;
            unc_rsp_err = 0;
            sv32_translate_en = 0; priv = `RV32GC_PRIV_M;
            pmpcfg_i = {N_PMP*8{1'b0}}; pmpaddr_i = {N_PMP*32{1'b0}};
            l1i_miss = 0; l1i_uncached = 0;
            unc_rsp_valid = 0; unc_rsp_pa = 0; unc_rsp_data = 0;
            train_valid = 0; train_pc = 0; train_target = 0; train_pred_target = 0;
            train_is_cond = 0; train_taken = 0; train_is_indirect = 0;
            train_is_call = 0; train_is_return = 0; train_pred_taken = 0;
            train_pred_sel_global = 0; train_pred_gdir = 0; train_pred_ldir = 0;
            train_pred_valid = 0; train_btb_hit = 0; train_btb_way = 0;
            n_req = 0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic do_redirect(input [31:0] pc);
        begin
            @(negedge clk); redirect_valid = 1'b1; redirect_pc = pc;
            @(posedge clk); @(negedge clk); redirect_valid = 1'b0;
        end
    endtask

    // 观察寄存器（逐 lane 快照）
    reg        obs_v;
    reg [3:0]  obs_mask, obs_ckv, obs_len4;
    reg [31:0] obs_next;
    reg [127:0] obs_pc4, obs_insn4, obs_cause4, obs_tval4, obs_tgt4;
    reg [3:0]   obs_pt4, obs_bh4;

    // 反压握手：先 ready=0 等块呈现（触发 F05-07 快照），negedge 采样；再 ready=1 一拍消费。
    task automatic grab_block;
        integer guard;
        begin
            guard = 0;
            blk_ready = 1'b0;
            @(posedge clk);
            while (!blk_valid && guard < 4000) begin
                @(posedge clk); guard = guard + 1;
            end
            @(negedge clk);
            obs_v     = blk_valid;
            obs_mask  = blk_mask;
            obs_next  = blk_next_pc;
            obs_pc4   = lane_pc;
            obs_insn4 = lane_insn;
            obs_len4  = lane_len32;
            obs_cause4= lane_fault_cause;
            obs_tval4 = lane_fault_tval;
            obs_ckv   = lane_ckpt_valid;
            obs_tgt4  = lane_pred_target;
            obs_pt4   = lane_pred_taken;
            obs_bh4   = lane_btb_hit;
            blk_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            blk_ready = 1'b0;
        end
    endtask

    // 连续握手直到（或超过）某 lane 的 PC 命中；返回命中 lane 号（-1=未找到）
    task automatic grab_until_pc(input [31:0] pc, output integer lane, output integer found);
        integer g, i2;
        begin
            found = 0; lane = -1;
            for (g = 0; g < 24 && !found; g = g + 1) begin
                grab_block;
                for (i2 = 0; i2 < 4; i2 = i2 + 1)
                    if (obs_mask[i2] && (obs_pc4[i2*32 +: 32] === pc)) begin
                        found = 1; lane = i2;
                    end
            end
        end
    endtask

    task automatic wait_frozen;
        integer guard;
        begin
            guard = 0;
            while (!fe_frozen && guard < 100) begin @(posedge clk); guard = guard + 1; end
        end
    endtask

    function automatic integer popcount4(input [3:0] v);
        begin popcount4 = v[0] + v[1] + v[2] + v[3]; end
    endfunction

    task automatic train_cond(input [31:0] pc, input tk, input [31:0] tgt);
        integer g;
        begin
            g = 0;
            while (!train_ready && g < 200) begin @(posedge clk); g = g + 1; end
            @(negedge clk);
            train_valid = 1'b1; train_pc = pc; train_is_cond = 1'b1;
            train_taken = tk; train_is_indirect = 1'b0;
            train_is_call = 1'b0; train_is_return = 1'b0;
            train_target = tgt; train_pred_taken = tk;
            train_pred_target = tgt; train_pred_valid = 1'b1;
            train_btb_hit = 1'b0; train_btb_way = 1'b0;
            train_pred_sel_global = 1'b0; train_pred_gdir = 1'b1;
            train_pred_ldir = 1'b0;
            @(posedge clk); @(negedge clk); train_valid = 1'b0;
        end
    endtask
    task automatic train_ind(input [31:0] pc, input [31:0] tgt);
        integer g;
        begin
            g = 0;
            while (!train_ready && g < 200) begin @(posedge clk); g = g + 1; end
            @(negedge clk);
            train_valid = 1'b1; train_pc = pc; train_is_cond = 1'b0;
            train_taken = 1'b1; train_is_indirect = 1'b1;
            train_is_call = 1'b0; train_is_return = 1'b0;
            train_target = tgt; train_pred_taken = 1'b1;
            train_pred_target = tgt; train_pred_valid = 1'b1;
            train_btb_hit = 1'b0; train_btb_way = 1'b0;
            train_pred_sel_global = 1'b0; train_pred_gdir = 1'b1;
            train_pred_ldir = 1'b0;
            @(posedge clk); @(negedge clk); train_valid = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer k, ln, fnd, n_wide;
    reg [31:0] prev_next;
    initial begin
        n_checks = 0; n_fail = 0;
        do_reset;

        //= T8 F05-09：ras_repair_addr 必须被驱动（非 X/Z）
        #1;
        chk((^ras_repair_addr) !== 1'bx,
            "F05-09: ras_repair_addr 不得为 X/Z（必须已被驱动）");

        //======================================================================
        // T1：Sv32 page fault（cause 12）——页尾 32bit 指令的第二 parcel 在下一页
        //======================================================================
        sv32_translate_en = 1'b1;
        priv = `RV32GC_PRIV_M;   // 叶模块直测：翻译由 en 驱动，PMP 走 M 模式（无项=放行）
        pg_pa[8'h00] = 32'h8000_0000;
        pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b0;
        pg_pa[8'h01] = 32'hDEAD_0000;
        wr(32'h8000_0ffc, {16'h006f, 16'h0001});      // parcel ffc=c.nop, ffe=jal 低半
        do_redirect(32'h8000_0ffc);
        grab_until_pc(32'h8000_0ffe, ln, fnd);
        chk(fnd === 1, "T1: 应交付含 0x80000ffe 故障指令的块");
        chk(obs_mask === ((4'b0001 << ln) | ((4'b0001 << ln) - 4'b0001)),
            "T1: 块必须在故障 lane 处终止");
        chk(((obs_cause4[ln*5 +: 5]) === 5'd12),
            "T1: 第二 parcel 翻译页错误 cause 必须为 12");
        chk_eq32(obs_tval4[ln*32 +: 32], 32'h8000_1000,
                 "T1: tval 必须为下一页首地址 0x80001000");
        wait_frozen;
        chk(u_dut.u_ifetch4.fault_hold_q === 1'b1,
            "T1: 故障块交付后必须置故障保持（冻结到重定向）");
        for (k = 0; k < n_req; k = k + 1)
            chk(req_log[k] !== 32'hDEAD_0000,
                "T1: 翻译失败的字绝不能以毒 PA 发 L1I 请求");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T2：同一路径 access fault（cause 1）
        //======================================================================
        do_reset;
        sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;   // 叶模块直测：翻译由 en 驱动，PMP 走 M 模式（无项=放行）
        pg_pa[8'h00] = 32'h8000_0000;
        pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b1;
        wr(32'h8000_0ffc, {16'h006f, 16'h0001});
        do_redirect(32'h8000_0ffc);
        grab_until_pc(32'h8000_0ffe, ln, fnd);
        chk(fnd === 1, "T2: 应交付故障指令块");
        chk(obs_mask === ((4'b0001 << ln) | ((4'b0001 << ln) - 4'b0001)),
            "T2: 块应在故障 lane 处终止");
        chk((obs_cause4[ln*5 +: 5]) === 5'd1,
            "T2: PTE 访问 PMP 违反（AF=1）cause 必须为 1");
        chk_eq32(obs_tval4[ln*32 +: 32], 32'h8000_1000, "T2: tval 仍按故障 parcel VA");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T3：高半起始（重定向到 …002）—— tval 必须 PC+2 而非 word base
        //======================================================================
        do_reset;
        sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;   // 叶模块直测：翻译由 en 驱动，PMP 走 M 模式（无项=放行）
        pg_flt[8'h03] = 1'b1;
        pg_pa[8'h03] = 32'hDEAD_3000;
        do_redirect(32'h8000_3002);
        grab_until_pc(32'h8000_3002, ln, fnd);
        chk(fnd === 1 && ln === 0, "T3: 故障块必须从 0x80003002 开始");
        chk((obs_cause4[0 +: 5]) === 5'd12, "T3: cause 必须为 12");
        chk_eq32(obs_tval4[0 +: 32], 32'h8000_3002,
                 "T3: tval 必须为 PC+2=0x80003002（不是 word base）");
        for (k = 0; k < n_req; k = k + 1)
            chk(req_log[k] !== 32'hDEAD_3000, "T3: 不得以毒 PA 取故障页");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T4：第二 parcel 的 PMP 用自身 PA（两页 PA 不连续）
        //======================================================================
        do_reset;
        sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;   // 叶模块直测：翻译由 en 驱动，PMP 走 M 模式（无项=放行）
        pg_pa[8'h04] = 32'h8000_4000;
        pg_pa[8'h05] = 32'h8020_0000;
        wr(32'h8000_4ffc, {16'h006f, 16'h0001});
        wr(32'h8020_0000, {16'h0000, 16'h0080});       // 第二页首字的高半 parcel
        pmpcfg_i[N_PMP*8-1 -: 8]    = 8'h90;           // L=1, A=NA4, 全无权限
        pmpaddr_i[N_PMP*32-1 -: 32] = 32'h8020_0000 >> 2;
        do_redirect(32'h8000_4ffc);
        grab_until_pc(32'h8000_4ffe, ln, fnd);
        chk(fnd === 1, "T4: 应交付跨页 32bit 指令块");
        chk((obs_cause4[ln*5 +: 5]) === 5'd1,
            "T4: 第二 parcel 的 PMP 拒绝必须是 cause 1");
        chk_eq32(obs_tval4[ln*32 +: 32], 32'h8000_5000,
                 "T4: tval 必须是第二 parcel 的 VA（0x80005000）");
        do_redirect(32'h8000_0000);
        // 合法对照：撤销 PMP ⇒ 同一条指令不得报 fault
        do_reset;
        sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;   // 叶模块直测：翻译由 en 驱动，PMP 走 M 模式（无项=放行）
        pg_pa[8'h04] = 32'h8000_4000; pg_pa[8'h05] = 32'h8020_0000;
        wr(32'h8000_4ffc, {16'h006f, 16'h0001});
        wr(32'h8020_0000, {16'h0000, 16'h0080});
        do_redirect(32'h8000_4ffc);
        grab_until_pc(32'h8000_4ffe, ln, fnd);
        chk(fnd === 1, "T4 控制: 应交付跨页指令块");
        chk(lane_fault[ln] === 1'b0, "T4 控制: 合法跨页指令不得报 fault");
        chk_eq32(obs_insn4[ln*32 +: 32], 32'h0080_006f,
                 "T4 控制: 跨页拼出的 32bit 指令位必须正确");

        //======================================================================
        // T5：F05-05 检查点归属（只有分支 lane 有效）
        //======================================================================
        do_reset;
        wr(32'h8000_0000, {16'h0001, 16'h0001});       // 0,2 = c.nop
        wr(32'h8000_0004, {16'h0080, 16'h006f});       // 4/6 = jal x0,+8
        do_redirect(32'h8000_0000);
        grab_until_pc(32'h8000_0004, ln, fnd);
        chk(fnd === 1, "T5: 应交付含 jal 的块");
        chk(obs_ckv === (4'b0001 << ln),
            "T5: taken 块只有真正持有检查点的分支 lane 的 ckpt_valid=1");
        chk((lane_ckpt[ln*4 +: 4] === lane_ckpt[3:0]) && (lane_ckpt[3:0] !== 4'hx),
            "T5: 检查点 id 必须一致且非 X");
        // 非 taken 对照
        do_reset;
        wr(32'h8000_0000, {16'h0001, 16'h0001});
        wr(32'h8000_0004, {16'h0001, 16'h0001});
        do_redirect(32'h8000_0000);
        grab_block;
        chk(obs_ckv === 4'b0000, "T5 控制: 非 taken 块不得声明检查点");

        //======================================================================
        // T6：F05-07 反压稳定（新增 parcel + RAS 变化 ⇒ 载荷不变）
        //======================================================================
        do_reset;
        @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_9000;
        @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
        @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_A000;
        @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
        wr(32'h8000_0000, {16'h0001, 16'h0001});
        wr(32'h8000_0004, {16'h0001, 16'h0001});
        wr(32'h8000_0008, {16'h0000, 16'h8067});       // 6/8 = jalr x0,0(x1)
        do_redirect(32'h8000_0000);
        // 预取蓄水，再逐块消费直到"含 PC 6 的块"被呈现并保持
        blk_ready = 1'b0;
        repeat (120) @(posedge clk);
        fnd = 0;
        for (k = 0; k < 20 && !fnd; k = k + 1) begin
            @(posedge clk);
            while (!blk_valid) @(posedge clk);
            @(negedge clk); #1;
            if (lane_pc[95:64] === 32'h8000_0006 || lane_pc[127:96] === 32'h8000_0006)
                fnd = 1;
            else begin
                blk_ready = 1'b1; @(posedge clk); @(negedge clk); blk_ready = 1'b0;
            end
        end
        chk(fnd === 1, "T6: 应能呈现含 ret 的块");
        begin : t6
            reg [3:0]  m0; reg [31:0] n0, t0, p0, i0; integer li;
            li = (lane_pc[95:64] === 32'h8000_0006) ? 2 : 3;
            m0 = blk_mask; n0 = blk_next_pc; t0 = lane_pred_target[li*32 +: 32];
            p0 = lane_pc[31:0]; i0 = lane_insn[31:0];
            chk(m0 === 4'b1111, "T6: 蓄水后应呈现 4 路 taken 块");
            // 反压期间：改变 RAS 顶（d2_pop）+ F4 继续压入
            @(negedge clk); d2_pop_valid = 1'b1; d2_pop_addr = 32'h8000_A000;
            @(posedge clk); @(negedge clk); d2_pop_valid = 1'b0;
            repeat (6) @(posedge clk);
            chk(blk_valid === 1'b1, "T6: 反压期间 blk_valid 必须保持");
            chk(blk_mask === m0, "T6: 反压期间 mask 必须不变");
            chk(blk_next_pc === n0, "T6: 反压期间 blk_next_pc 必须不变（RAS 变化不影响）");
            chk(lane_pred_target[li*32 +: 32] === t0, "T6: 反压期间预测目标必须不变");
            chk(lane_pc[31:0] === p0, "T6: 反压期间 lane0 PC 必须不变");
            chk(lane_insn[31:0] === i0, "T6: 反压期间 lane0 指令位必须不变");
        end
        // flush 取消：redirect 必须取消被反压的块
        @(negedge clk); redirect_valid = 1'b1; redirect_pc = 32'h8000_0000;
        @(posedge clk); #1;
        chk(blk_valid === 1'b0, "T6: redirect 必须取消被反压的块（flush 语义）");
        @(negedge clk); redirect_valid = 1'b0;

        //======================================================================
        // T7：F05-08 逐 lane 真值与预测流连续 + T9 吞吐 4 路
        //======================================================================
        do_reset;
        for (k = 0; k < 64; k = k + 1)
            wr(32'h8000_0000 + k*4, {16'h0001, 16'h0001});
        do_redirect(32'h8000_0000);
        prev_next = 32'h8000_0000;
        n_wide = 0;
        for (k = 0; k < 12; k = k + 1) begin
            grab_block;
            chk_eq32(obs_pc4[31:0], prev_next, "T7: 块首 PC 必须等于上一块 next_pc");
            for (ln = 0; ln < 4; ln = ln + 1) begin
                if (obs_mask[ln]) begin
                    chk_eq32(obs_insn4[ln*32 +: 32], 32'h0000_0001,
                             "T7: lane 指令位必须为 c.nop");
                    chk(obs_len4[ln] === 1'b0, "T7: c.nop 必须为 16 bit");
                end
            end
            chk_eq32(obs_next, obs_pc4[31:0] + 2*popcount4(obs_mask),
                     "T7: next_pc 必须等于首 PC + 2*有效 lane 数");
            if (obs_mask === 4'b1111) n_wide = n_wide + 1;
            prev_next = obs_next;
        end
        chk(n_wide >= 2, "T9/吞吐: 无反压直线流必须出现 ≥2 个 4 路块（mask=1111）");

        //======================================================================
        // T10（包B）：错误行 = 0x8000_0020（与首字不同行）；高半 parcel 错误
        //   ⇒ lane1 fault cause=1、tval=0x80000020；更老 lane0 仍正确交付。
        //======================================================================
        do_reset;
        err_en = 1; err_line = 32'h8000_0020;
        wr(32'h8000_001c, {16'h006f, 16'h0001});   // 1c=c.nop, 1e=jal 低半
        do_redirect(32'h8000_001c);
        grab_until_pc(32'h8000_001e, ln, fnd);
        chk(fnd === 1, "T10: 应交付含 0x8000001e 的块");
        chk(ln === 1, "T10: 错误高半 lane 必须为 lane1");
        chk(lane_fault[ln] === 1'b1, "T10: 错误行的高半必须使该 lane 故障");
        chk((obs_cause4[ln*5 +: 5]) === 5'd1, "T10: 响应错误 cause 必须为 1");
        chk_eq32(obs_tval4[ln*32 +: 32], 32'h8000_0020,
                 "T10: tval 必须为错误 parcel 的 VA（0x80000020）");
        chk(obs_insn4[31:0] === 32'h0000_0001, "T10: 更老 lane 的指令位必须正确（仍交付）");
        chk(obs_mask === 4'b0011, "T10: 块必须在错误 lane 处终止");
        chk(obs_insn4[ln*32 +: 32] !== 32'h8000_006f,
            "T10: 不得把错误行的数据当指令");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T12（包B）：低半起始的响应错误（重定向到错误行首）cause=1、tval=行首
        //======================================================================
        do_reset;
        err_en = 1; err_line = 32'h8000_0020;
        do_redirect(32'h8000_0020);
        grab_until_pc(32'h8000_0020, ln, fnd);
        chk(fnd === 1 && ln === 0, "T12: 错误行首必须是新块的 lane0");
        chk((obs_cause4[0 +: 5]) === 5'd1, "T12: 错误行低半 cause 必须为 1");
        chk_eq32(obs_tval4[0 +: 32], 32'h8000_0020, "T12: tval 必须为 0x80000020");
        chk(obs_ckv === 4'b0000, "T12: 错误块不得声明检查点");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T11（包B）：错行/陈旧错误不得污染新 word（行不匹配 ⇒ 忽略）
        //======================================================================
        do_reset;
        err_en = 1; err_line = 32'h8000_0040;          // 不匹配的行
        wr(32'h8000_001c, {16'h006f, 16'h0001});
        wr(32'h8000_0020, {16'h0000, 16'h0080});       // 高半 parcel = 0x0080
        do_redirect(32'h8000_001c);
        grab_until_pc(32'h8000_001e, ln, fnd);
        chk(fnd === 1, "T11: 应交付 0x8000001e lane");
        chk(lane_fault[ln] === 1'b0, "T11: 不匹配行的错误必须被忽略");
        chk_eq32(obs_insn4[ln*32 +: 32], 32'h0080_006f,
                 "T11: 正常跨线拼出的指令位必须正确");
        // 陈旧错误：正常块已交付后，手动单拍错行脉冲不得产生故障
        err_en = 0; err_force = 1; err_force_pa = 32'h8000_0000;
        @(posedge clk); @(negedge clk); err_force = 0;
        grab_block;
        chk(obs_v === 1'b1, "T11: 陈旧错误后仍应正常交付下一块");
        chk(lane_fault === 4'b0000, "T11: 陈旧错误不得污染后续块");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T15（包B）：XIP 直连返回错误（owner+PA 匹配）⇒ cause=1
        //======================================================================
        do_reset;
        wr(32'h1C00_0000, 32'h0000_0013);
        do_redirect(32'h1C00_0000);
        blk_ready = 1'b0;
        fnd = 0;
        for (k = 0; k < 200 && !fnd; k = k + 1) begin
            @(posedge clk);
            if (unc_req_valid && (unc_req_pa == 32'h1C00_0000)) begin
                @(negedge clk);
                unc_rsp_valid = 1'b1; unc_rsp_pa = 32'h1C00_0000;
                unc_rsp_data = 32'hDEAD_BEEF; unc_rsp_err = 1'b1;
                @(posedge clk); @(negedge clk);
                unc_rsp_valid = 1'b0; unc_rsp_err = 1'b0;
                fnd = 1;
            end
        end
        chk(fnd === 1, "T15: 必须观察到 XIP 请求");
        grab_until_pc(32'h1C00_0000, ln, fnd);
        chk(fnd === 1, "T15: XIP 错误后应交付故障块");
        chk((obs_cause4[ln*5 +: 5]) === 5'd1, "T15: XIP 错误 cause 必须为 1");
        chk(obs_insn4[ln*32 +: 32] !== 32'hDEAD_BEEF,
            "T15: XIP 错误数据不得被当指令");
        do_redirect(32'h8000_0000);

        //======================================================================
        // T16（F05-06 取证，仅记录不改预测器）：A/B 交替预训练（不同 BTB 目标）
        //   逐 PC 核对预测响应配对；含停顿对照。不设通过/失败断言（本批只取证）。
        //======================================================================
        begin : f0506
            reg [31:0] A, B, TA, TB;
            integer m, n_mis;
            reg [31:0] gt; reg gk, gh;
            A  = 32'h8000_0040; B  = 32'h8000_0080;
            TA = 32'h8000_1000; TB = 32'h8000_2000;
            n_mis = 0;
            do_reset;
            wr(A, 32'h0001_0067);   // jalr x0,0(x2) ⇒ C_INDIR（32bit）
            wr(B, 32'h0001_0067);
            train_ind(A, TA); train_ind(B, TB);
            repeat (200) @(posedge clk);          // 训练 FIFO 排空
            for (m = 0; m < 3; m = m + 1) begin
                do_redirect(A); grab_block;
                gt = obs_tgt4[31:0]; gk = obs_pt4[0]; gh = obs_bh4[0];
                $display("EVIDENCE F05-06_AB: round=%0d pc=0x%08x tk=%b hit=%b tgt=0x%08x exp=0x%08x",
                         m, A, gk, gh, gt, TA);
                chk((obs_pc4[31:0] === A) && (obs_pt4[0] === 1'b1) &&
                    (obs_bh4[0] === 1'b1) && (obs_tgt4[31:0] === TA),
                    "T16: A 的预测必须与 A 的训练逐项配对（tk/hit/tgt）");
                if (!(gk === 1'b1 && gh === 1'b1 && gt === TA)) n_mis = n_mis + 1;
                // 停顿对照
                fe_stall = 1'b1; repeat (20) @(posedge clk); fe_stall = 1'b0;
                do_redirect(B); grab_block;
                gt = obs_tgt4[31:0]; gk = obs_pt4[0]; gh = obs_bh4[0];
                $display("EVIDENCE F05-06_AB: round=%0d pc=0x%08x tk=%b hit=%b tgt=0x%08x exp=0x%08x",
                         m, B, gk, gh, gt, TB);
                chk((obs_pc4[31:0] === B) && (obs_pt4[0] === 1'b1) &&
                    (obs_bh4[0] === 1'b1) && (obs_tgt4[31:0] === TB),
                    "T16: B 的预测必须与 B 的训练逐项配对（tk/hit/tgt）");
                if (!(gk === 1'b1 && gh === 1'b1 && gt === TB)) n_mis = n_mis + 1;
                fe_stall = 1'b1; repeat (20) @(posedge clk); fe_stall = 1'b0;
            end
            $display("EVIDENCE F05-06_AB_TOTAL: pairs=6 mismatches=%0d", n_mis);
            // ---- 方向对照：C 条件 taken / D 条件 not-taken（不同方向逐 PC 配对）----
            begin : dir
                reg [31:0] C, D, TC, TD;
                integer g2;
                C = 32'h8000_00C0; D = 32'h8000_0100;
                TC = 32'h8000_3000; TD = 32'h8000_4000;
                do_reset;
                wr(C, 32'h0000_0463);   // beq x0,x0,+8
                wr(D, 32'h0000_0463);
                train_cond(C, 1'b1, TC);
                train_cond(D, 1'b0, TD);
                repeat (200) @(posedge clk);
                do_redirect(C); grab_block;
                //   条件分支的目标是**直接目标 PC+imm**（BTB 目标只用于间接跳转），
                //   方向由预测器给：C 训练 taken ⇒ tk=1 且目标=C+8。
                chk((obs_pc4[31:0] === C) && (obs_pt4[0] === 1'b1) &&
                    (obs_tgt4[31:0] === (C + 32'd8)),
                    "T16: C 条件 taken 的方向/直接目标必须正确");
                $display("EVIDENCE F05-06_DIR: pc=0x%08x tk=%b tgt=0x%08x exp=0x%08x",
                         C, obs_pt4[0], obs_tgt4[31:0], C + 32'd8);
                fe_stall = 1'b1; repeat (20) @(posedge clk); fe_stall = 1'b0;
                do_redirect(D); grab_block;
                chk((obs_pc4[31:0] === D) && (obs_pt4[0] === 1'b0),
                    "T16: D 条件 not-taken 的方向必须与其训练配对");
                $display("EVIDENCE F05-06_DIR: pc=0x%08x tk=%b exp=0", D, obs_pt4[0]);
            end
        end

        //======================================================================
        // E1：F05-06 读拍证据（仅记录，不改预测器）
        //======================================================================
        $display("EVIDENCE F05-06: lu_en=%b lu_pc0=0x%08x f3_v=%b f3_va=0x%08x f3_pack=0x%0h",
                 u_dut.lu_en, u_dut.lu_pc0, u_dut.u_ifetch4.f3_v_q,
                 u_dut.u_ifetch4.f3_va_q, u_dut.u_ifetch4.f3_pk_q);

        //======================================================================
        // 汇总
        //======================================================================
        $display("FRONTEND_FAULTS checks=%0d fails=%0d wide_blocks=%0d", n_checks, n_fail, n_wide);
        if (n_checks == 0 || n_fail != 0) begin
            $display("FUNCTIONAL_FRONTEND_FAULTS: FAIL reason=checks fails=%0d", n_fail);
            $fatal(1, "frontend faults FAIL");
        end
        $display("FUNCTIONAL_FRONTEND_FAULTS: PASS");
        $finish;
    end

endmodule
