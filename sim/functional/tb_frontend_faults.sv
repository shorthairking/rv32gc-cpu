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
//   T18 **检查点池闭环（2026-10-20）**：held 取消与外部提交释放**同拍**两个 id 都归还
//      （旧单口 mux 会丢一个）；held 在首次呈现拍预留 id 后，旧分支释放 id0 不影响
//      实际 owner id1；最后 id/池满时 held 不因 poolBusy 卡住；clear_all 后真实池位全 0。
//   T19 **breakpoint freeze 合同**：冻结只抑制呈现/消费，不取消 hold 快照、不释放已预留
//      id；冻结期间 RAS 变化不得改 payload；解冻恢复同块/同 id；freeze+redirect 组合仍
//      按 redirect 取消并归还 id。
//   T20 **真实 fault1/done0**：跨页高半 / 高半起始 / 对齐首 parcel 三种合法 MMU 响应下，
//      fault 为终态（done=0）、cause/tval 精准、零毒 PA、消费后冻结、更年轻内容截断。
//   T21 **故障响应晚于前缀字入缓冲**：故障响应单拍脉冲（AF 只在响应拍有效）+ L1I 延迟，
//      前缀块照常交付且不跨页，故障标记作为新块 lane0 交付；证明前端在响应拍锁存
//      fault/AF，而不是标记入队拍现采实时输入。
//   T22 **RVC Q2 分类**：只有 funct3==100 且 bit12/rs2/rd 条件成立的 c.jr/c.jalr 才是
//      控制流；SLLI/LWSP/FLDSP/FLWSP/SWSP/FSDSP/FSWSP/MV/ADD/reserved/EBREAK 在非空
//      RAS/BTB 命中下不得 taken/alloc/终止；真 0x8082( RET)/0x9082(ICALL) 仍跳。
//   T23 **冻结后首次呈现（F2）**：F4 前缀请求在途后 freeze，前缀响应与下页 marker
//      均入缓冲再解冻；首次呈现 mask=0011 时块外 marker 不得令全局 fault 伪高，
//      消费后新流 marker 的 cause/tval 仍准确。
//   T24 **older-taken + 更年轻 marker（F2）**：页尾 taken 块首次呈现时 mask 外
//      下一页 marker 不得污染全局 fault；restart 后新流不得继承年轻 marker。
//
// 纪律 : 不 force 内部状态、不改预测器内部；层次引用只做**只读**观测（池位/保持态）；
//        全部刺激经真实端口时序驱动。
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
    wire [31:0] cnt_fault_o;

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
        .fetch_pc_o(fetch_pc_o), .head_pc_o(head_pc_o), .epoch_o(), .ghr_o(),
        .cnt_fault(cnt_fault_o)
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
    //   按半字地址写（T22 的 RVC 用例只改低/高半，不覆盖同字另一条 16 bit）
    task automatic wr16(input [31:0] pa, input [15:0] v);
        integer wi;
        begin
            wi = pa[17:2];
            if (pa[1] == 1'b0) mem[wi] = {mem[wi][31:16], v};
            else               mem[wi] = {v, mem[wi][15:0]};
        end
    endtask
    function automatic [31:0] mem_rd(input [31:0] pa);
        begin mem_rd = mem[pa[17:2]]; end
    endfunction

    //--------------------------------------------------------------------------
    // 行为级 L1I：请求后 l1i_lat 拍 ready；记录每次真实请求地址（毒地址断言用）
    //   l1i_lat=1（默认）与历史逐拍等价；>1 用于制造"翻译故障响应早于前缀字数据
    //   入缓冲"的合法时序窗口（故障标记必须等 push_from 追上才能入队）。
    //--------------------------------------------------------------------------
    reg        l1i_pend;
    reg [31:0] l1i_addr_q;
    integer    l1i_lat;
    reg [7:0]  l1i_wait_q;
    reg [31:0] req_log [0:255];
    integer    n_req;
    initial begin l1i_lat = 1; l1i_wait_q = 8'h0; end
    always @(posedge clk) begin
        if (!rst_n) begin
            l1i_ready <= 1'b0; l1i_pend <= 1'b0; l1i_addr_q <= 32'h0;
            l1i_wait_q <= 8'h0;
        end else begin
            l1i_ready <= 1'b0;
            if (l1i_req_valid && !l1i_pend && !err_auto) begin
                l1i_pend   <= 1'b1;
                l1i_addr_q <= l1i_req_addr;
                l1i_wait_q <= (l1i_lat > 1) ? (l1i_lat - 1) : 0;
                if (n_req < 256) req_log[n_req] = l1i_req_addr;
                n_req <= n_req + 1;
            end else if (l1i_pend) begin
                if (l1i_wait_q != 0) begin
                    l1i_wait_q <= l1i_wait_q - 8'd1;
                end else begin
                    l1i_pend  <= 1'b0;
                    l1i_ready <= 1'b1;
                end
            end
        end
    end
    always @(*) l1i_rdata = mem_rd(l1i_addr_q);

    //--------------------------------------------------------------------------
    // 行为级翻译：按 VA 页查表；1 拍后 done/fault/af/paddr（paddr 保留页内偏移）
    //   tr_mode（测试控制，do_reset 归 0）：
    //     0 = 历史口径：done 恒 1（fault 与 done 同拍、均电平保持）；
    //     1 = **真实 fault1/done0**：故障 word 的 done=0、fault 保持到消费；
    //     2 = **故障响应单拍脉冲**：done=0、fault 只 1 拍（真实 MMU 响应可被后续
    //         归属/优先级事件撤掉；前端必须锁存终态），成功仍保持 done 电平；
    //     1/2 下 AF 分类只在**响应拍**有效（之后端口可被后续遍历复用），
    //     用于证明前端在响应拍锁存 cause，而不是标记入队时才现采。
    //   响应按"请求 VA"归属：同一 VA 只响应一次；VA 变化 = 新请求重新响应。
    //--------------------------------------------------------------------------
    reg [31:0] pg_pa  [0:255];
    reg        pg_flt [0:255];
    reg        pg_af  [0:255];
    reg        tr_done_q, tr_flt_q, tr_af_q;
    reg [31:0] tr_pa_q;
    reg [31:0] tr_off_q;
    reg [31:0] tr_va_q;      // 响应所属请求 VA（防 restart 后旧响应错配新 word）
    reg [1:0]  tr_mode;
    reg        tr_served_q;
    reg [31:0] tr_served_va_q;
    integer    pi;
    initial begin
        for (pi = 0; pi < 256; pi = pi + 1) begin
            pg_pa[pi] = 32'h0; pg_flt[pi] = 1'b0; pg_af[pi] = 1'b0;
        end
        tr_mode = 2'd0; tr_served_q = 1'b0; tr_served_va_q = 32'h0;
    end
    wire [7:0] tr_pg = tr_req_va[19:12];
    wire       tr_new_req = (tr_req_va != tr_served_va_q);
    wire       tr_serve   = sv32_translate_en & tr_req_valid &
                            (~tr_served_q | tr_new_req);
    always @(posedge clk) begin
        if (!rst_n) begin
            tr_done_q <= 1'b0; tr_flt_q <= 1'b0; tr_af_q <= 1'b0;
            tr_pa_q <= 32'h0; tr_off_q <= 32'h0; tr_va_q <= 32'h0;
            tr_served_q <= 1'b0; tr_served_va_q <= 32'h0;
        end else if (sv32_translate_en && tr_req_valid) begin
            if (tr_serve) begin
                tr_done_q <= (tr_mode == 2'd0) ? 1'b1 : ~pg_flt[tr_pg];
                tr_flt_q  <= pg_flt[tr_pg];
                tr_af_q   <= pg_af[tr_pg];
                tr_pa_q   <= pg_pa[tr_pg];
                tr_off_q  <= {20'h0, tr_req_va[11:0]};
                tr_va_q   <= tr_req_va;
                tr_served_q <= 1'b1;
                tr_served_va_q <= tr_req_va;
            end else begin
                case (tr_mode)
                    2'd1: begin
                        tr_done_q <= ~pg_flt[tr_pg];
                        tr_flt_q  <= pg_flt[tr_pg];        // fault 电平保持
                        tr_af_q   <= pg_af[tr_pg];
                    end
                    2'd2: begin
                        tr_done_q <= ~pg_flt[tr_pg];
                        tr_flt_q  <= 1'b0;                 // 故障只脉冲 1 拍
                        tr_af_q   <= 1'b0;
                    end
                    default: begin
                        tr_done_q <= 1'b1;
                        tr_flt_q  <= pg_flt[tr_pg];        // 历史：fault 与 done 同拍
                        tr_af_q   <= pg_af[tr_pg];
                    end
                endcase
            end
        end else begin
            tr_done_q <= 1'b0; tr_flt_q <= 1'b0; tr_af_q <= 1'b0;
            tr_served_q <= 1'b0;
        end
    end
    //   只有"响应所属 VA == 当前请求 VA"时才有效（owner/VA 关联；防旧响应污染新请求）
    wire tr_match = (tr_va_q == tr_req_va);
    assign sv32_translate_done     = tr_done_q & tr_match;
    assign sv32_translate_fault    = tr_flt_q  & tr_match;
    assign sv32_translate_fault_af = tr_af_q   & tr_match;
    assign sv32_translate_paddr    = (tr_pa_q | tr_off_q);

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
            tr_mode = 2'd0; l1i_lat = 1;
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
    reg        obs_feff;
    reg [3:0]  obs_mask, obs_ckv, obs_len4;
    reg [11:0] obs_cls4;
    reg [31:0] obs_next;
    reg [127:0] obs_pc4, obs_insn4, obs_cause4, obs_tval4, obs_tgt4;
    reg [3:0]   obs_pt4, obs_bh4;
    reg [15:0]  obs_ck4;
    reg [19:0]  obs_fault4;

    // 反压握手：先 ready=0 等块呈现（触发 F05-07 快照），negedge 采样；再 ready=1 一拍消费。
    // 观察快照（negedge 采样；保持/冻结期间可反复调用）
    task automatic snapshot_obs;
        begin
            @(negedge clk); #1;
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
            obs_ck4   = {lane_ckpt[15:12], lane_ckpt[11:8], lane_ckpt[7:4], lane_ckpt[3:0]};
            obs_fault4= lane_fault;
            obs_feff  = fe_fetch_fault;
            obs_cls4  = lane_cls;
        end
    endtask

    task automatic grab_block;
        integer guard;
        begin
            guard = 0;
            blk_ready = 1'b0;
            @(posedge clk);
            while (!blk_valid && guard < 4000) begin
                @(posedge clk); guard = guard + 1;
            end
            snapshot_obs;
            blk_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            blk_ready = 1'b0;
        end
    endtask

    // 等块首次呈现并采样，但**不消费**（保持/冻结用例）
    task automatic wait_present_hold;
        integer guard;
        begin
            guard = 0;
            blk_ready = 1'b0;
            while (!blk_valid && guard < 4000) begin
                @(posedge clk); guard = guard + 1;
            end
            snapshot_obs;
        end
    endtask

    // 消费当前 held 块（ready 单拍）
    task automatic fire_held;
        begin
            @(negedge clk); blk_ready = 1'b1;
            @(posedge clk); #1;
            @(negedge clk); blk_ready = 1'b0;
        end
    endtask

    // 检查点池整体清空（冻结取指，避免 clear 与呈现/分配同拍带来的有意歧义）
    task automatic pool_clear;
        begin
            @(negedge clk); fe_stall = 1'b1; ckpt_clear_all = 1'b1;
            @(posedge clk);
            @(negedge clk); ckpt_clear_all = 1'b0; fe_stall = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
        end
    endtask

    function automatic [3:0] ckid(input integer lane);
        begin ckid = obs_ck4[lane*4 +: 4]; end
    endfunction

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

    function automatic [31:0] enc_jal(input [4:0] rd, input [20:0] imm21);
        begin
            enc_jal = {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, 7'b110_1111};
        end
    endfunction
    function automatic [15:0] enc_c_j(input [11:0] imm12);
        begin // CJ 型：offset[11|4|9:8|10|6|7|3:1|5]
            enc_c_j = {3'b101, imm12[11], imm12[4], imm12[9:8], imm12[10],
                       imm12[6], imm12[7], imm12[3:1], imm12[5], 2'b01};
        end
    endfunction
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
        // T6（初审 P1-1/P1-2）：反压保持的**真 RET 块**（PC6 跨字 ret）——
        //   ① 只在首次进入 hold 采快照：保持期间 RAS 顶变化不得改 payload；
        //   ② 稳定 ID：held ckpt 就是 pool 里**已分配**的 id（不是 fire 拍才分配）。
        //======================================================================
        // 先在 PC 0x40 造一个已分配、尚未释放的较老 taken 块（占 id0）
        do_reset;
        @(negedge clk); ckpt_clear_all = 1'b1; @(posedge clk); @(negedge clk); ckpt_clear_all = 1'b0;
        // 把 pool 全部 id 归还（自包含：不受前面用例遗留分配影响）
        for (k = 0; k < 16; k = k + 1) begin
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = k[3:0];
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
        end
        repeat (2) @(posedge clk);
        wr(32'h8000_0040, enc_jal(5'd0, 21'h20));      // jal x0,+0x20 ⇒ 目标 0x80000060
        do_redirect(32'h8000_0040);
        blk_ready = 1'b1;
        grab_until_pc(32'h8000_0040, ln, fnd);
        chk(fnd === 1 && ln === 0, "T6: 较老 taken 块应先分配检查点");
        chk(obs_ckv[0] === 1'b1, "T6: 较老 taken 块必须声明检查点");
        chk(obs_ck4[3:0] === 4'd0, "T6: 较老 taken 块应拿到 id0（lane0）");
        // 不释放 id0（模拟较老 branch 仍在后端）
        // 程序：parcel0/2/4 = c.nop，PC6 = jalr x0,0(x1)（32bit，高半在 parcel8）
        wr(32'h8000_0000, {16'h0001, 16'h0001});
        wr(32'h8000_0004, {16'h8067, 16'h0001});       // parcel4=nop, parcel6=0x8067
        wr(32'h8000_0008, {16'h0000, 16'h0000});       // parcel8=ret 高半 0x0000
        do_redirect(32'h8000_0000);
        // redirect 会冲 RAS ⇒ **redirect 之后**再压合法非空 RAS
        fe_stall = 1'b1;
        @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_9000;
        @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
        @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_A000;
        @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
        fe_stall = 1'b0;
        blk_ready = 1'b0;
        repeat (120) @(posedge clk);
        fnd = 0;
        for (k = 0; k < 30 && !fnd; k = k + 1) begin
            @(posedge clk);
            while (!blk_valid) @(posedge clk);
            @(negedge clk); #1;
            if (lane_pc[127:96] === 32'h8000_0006) fnd = 1;
            else begin
                blk_ready = 1'b1; @(posedge clk); @(negedge clk); blk_ready = 1'b0;
            end
        end
        chk(fnd === 1, "T6: 应呈现含 PC6 真 RET 的 4 路块");
        begin : t6
            reg [3:0]  m0, ck0; reg [31:0] n0, t0, p0, i0, p30;
            integer hold_id;
            m0  = blk_mask; n0 = blk_next_pc;
            p0  = lane_pc[31:0]; i0 = lane_insn[31:0];
            p30 = lane_pc[127:96];
            t0  = lane_pred_target[127:96];
            ck0 = lane_ckpt_valid;
            hold_id = obs_ck4[15:12];   // lane3（RET）
            chk(m0 === 4'b1111, "T6: 应呈现 4 路 taken 块（mask=1111）");
            chk(p30 === 32'h8000_0006, "T6: lane3 必须是 PC6 的 RET");
            chk(i0 === 32'h0000_0001, "T6: lane0 指令位正确");
            chk(lane_insn[127:96] === 32'h0000_8067, "T6: lane3 必须是 jalr 指令位");
            chk(n0 === 32'h8000_A000, "T6: taken 目标必须为压入后的 RAS 顶 0x8000A000");
            chk(t0 === 32'h8000_A000, "T6: lane3 预测目标必须为 RAS 顶 0x8000A000");
            chk(ck0 === 4'b1000, "T6: 检查点只归 lane3（分支 lane）");
            // ① 稳定 ID：held 期间 pool 里 id1 必须已分配
            // 让较老 branch 提交释放 id0（关键：不释放 id1）
            // ② 保持期间改变 RAS 顶（pop + push 到 0xB000）；不得重采快照
            @(negedge clk); d2_pop_valid = 1'b1; d2_pop_addr = 32'h8000_A000;
            @(posedge clk); @(negedge clk); d2_pop_valid = 1'b0;
            @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_B000;
            @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
            repeat (8) @(posedge clk);
            #1;
            chk(blk_valid === 1'b1, "T6: 反压期间 blk_valid 必须保持");
            chk(blk_mask === m0, "T6: 反压期间 mask 必须不变");
            chk(blk_next_pc === n0, "T6: 反压期间 blk_next_pc 必须保持 0x8000A000（RAS 变化不得重采）");
            chk(lane_pred_target[127:96] === t0, "T6: 反压期间 ret 预测目标不得被新 RAS 顶篡改");
            chk(lane_pc[127:96] === p30, "T6: 反压期间 lane3 PC 必须不变");
            chk(lane_insn[127:96] === 32'h0000_8067, "T6: 反压期间 lane3 指令位必须不变");
            chk(lane_ckpt_valid === ck0, "T6: 反压期间 ckpt_valid 必须稳定");
            // 释放：必须按快照目标 0xA000 走，而不是新 RAS 顶
            blk_ready = 1'b1;
            @(posedge clk); #1;
            // 模拟后端提交释放 held id
            // 释放 held id（公共 free 口），保持与后端契约一致
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = hold_id;
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
        end
        // flush 取消：redirect 必须取消被反压的块，且归还预留 id
        @(negedge clk); redirect_valid = 1'b1; redirect_pc = 32'h8000_0000;
        @(posedge clk); #1;
        chk(blk_valid === 1'b0, "T6: redirect 必须取消被反压的块");
        @(negedge clk); redirect_valid = 1'b0;

        //======================================================================
        // T17（初审 P1-3）：较老 taken 内部 restart 必须丢弃**年轻**故障/错误状态。
        //   正证：restart 到合法目标后能继续取指；反证：年轻 fault/error 不得错标到新流。
        //======================================================================
        begin : t17
            integer g3, seen_ok;
            // (a) 年轻 translation fault
            do_reset;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000;
            pg_pa[8'h01] = 32'h8000_1000;
            pg_flt[8'h01] = 1'b1; pg_pa[8'h02] = 32'h8000_2000;
            wr(32'h8000_0ff8, enc_jal(5'd0, 21'h1008));   // jal x0,+0x1008 ⇒ 0x80002000
            do_redirect(32'h8000_0ff8);
            blk_ready = 1'b0;
            @(posedge clk);
            while (!blk_valid) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_mask === 4'b0001, "T17a: 较老 JAL 必须是单 lane taken 块");
            chk(blk_next_pc === 32'h8000_2000, "T17a: 较老 JAL 必须 taken 到 0x80002000");
            // ★ 块保持（不消费），给年轻 word 足够拍数被抓取并 consume 故障
            repeat (60) @(posedge clk);
            seen_ok = 1;
            // 放行 restart（restart 必须清 seen）
            blk_ready = 1'b1; @(posedge clk); @(negedge clk); blk_ready = 1'b0;
            // restart 后必须能继续到合法目标 0x2000（无永久 stall / 无错误 fault）
            grab_until_pc(32'h8000_2000, ln, fnd);
            chk(fnd === 1, "T17a: restart 后必须能取到合法目标 0x80002000（seen 已清）");
            chk(obs_fault4 === 4'b0000, "T17a: 年轻 fault 不得错标到 restart 后新流");
            $display("DBG T17a: cnt_fault=%0d obs_fault=%b mask=%b pc=%h %h %h %h cause=%h tval=%h",
                     cnt_fault_o, obs_fault4, obs_mask,
                     obs_pc4[31:0], obs_pc4[63:32], obs_pc4[95:64], obs_pc4[127:96],
                     obs_cause4, obs_tval4);
            chk(cnt_fault_o === 32'd0, "T17a: 不得交付任何取指 fault");
            // (b) 年轻 response error（年轻 word 0x1000 的行使能错误）
            do_reset;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000; pg_pa[8'h01] = 32'h8000_1000;
            pg_pa[8'h02] = 32'h8000_2000;
            pg_flt[8'h01] = 1'b0; pg_af[8'h01] = 1'b0;   // 本子例用**响应错误**，不是翻译 fault
            err_en = 1; err_line = 32'h8000_1000;   // PA 行（VA 0x80001000 映射到 0x80001000）
            wr(32'h8000_0ff8, enc_jal(5'd0, 21'h1008));
            do_redirect(32'h8000_0ff8);
            blk_ready = 1'b0;
            @(posedge clk);
            while (!blk_valid) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_mask === 4'b0001 && blk_next_pc === 32'h8000_2000,
                "T17b: 较老 JAL 必须是 taken 到 0x80002000 的单 lane 块");
            repeat (60) @(posedge clk);
            seen_ok = 1;
            blk_ready = 1'b1; @(posedge clk); @(negedge clk); blk_ready = 1'b0;
            grab_until_pc(32'h8000_2000, ln, fnd);
            chk(fnd === 1, "T17b: restart 后必须能取到合法目标（err 状态已清）");
            chk(obs_fault4 === 4'b0000, "T17b: 年轻 response error 不得错标到新流");
            err_en = 0;
            do_redirect(32'h8000_0000);
        end

        //======================================================================
        // T18（检查点池闭环，2026-10-20）：**两个独立释放口 + 真实池位/owner**
        //   a) held 取消（redirect）与外部提交释放**同拍**发生在两个不同 id 上
        //      ⇒ 两个 id 都必须归还（旧 front4_top 单口 mux 外部优先会丢一个）；
        //   b) 旧分支占 id0 → held 新块在首次呈现拍预留 id1 → 旧释放 id0 → fire
        //      后真实 owner 仍是 id1（不是"id 输出非 X"就算过）；
        //   c) 最后 id/池满：15 个已分配 + 第 16 个 held ⇒ 池满时 held 块继续呈现
        //      并可消费；clear_all 后 16 位真实清零。
        //======================================================================
        begin : t18_pool
            integer ii, g18;

            // ---- a) 双 free 同拍 ----
            do_reset;
            pool_clear;
            wr(32'h8000_0040, enc_jal(5'd0, 21'h20));       // → 0x8000_0060
            do_redirect(32'h8000_0040);
            blk_ready = 1'b1;
            grab_until_pc(32'h8000_0040, ln, fnd);
            chk(fnd === 1 && ln === 0, "T18a: 较老 JAL 必须单 lane 呈现");
            chk(obs_ckv === 4'b0001 && ckid(0) === 4'd0,
                "T18a: 较老 taken 必须在呈现拍分配 id0");
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b1,
                "T18a: 真实池 id0 必须已分配（不回滚为 fire 拍才分配）");
            chk(u_dut.u_bpu.ck_valid_q[1] === 1'b0, "T18a: 构造：id1 仍空闲");
            wr(32'h8000_0080, enc_jal(5'd0, 21'h20));       // → 0x8000_00a0
            do_redirect(32'h8000_0080);
            wait_present_hold;
            chk(obs_v === 1'b1, "T18a: 反压 held 新块必须呈现");
            chk(obs_ckv === 4'b0001 && ckid(0) === 4'd1,
                "T18a: held 新块必须在首次呈现拍预留 id1");
            chk(u_dut.u_bpu.ck_valid_q[1] === 1'b1,
                "T18a: 真实池 id1 必须已分配");
            // 同拍：redirect 取消 held（归还 id1）+ 后端释放 id0
            @(negedge clk);
            redirect_valid = 1'b1; redirect_pc = 32'h8000_0000;
            ckpt_free_valid = 1'b1; ckpt_free_id = 4'd0;
            @(posedge clk); #1;
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b0 &&
                u_dut.u_bpu.ck_valid_q[1] === 1'b0,
                "T18a: heldcancel+外部 free 同拍必须两个 id 都归还（不得 mux 丢一个）");
            chk(u_dut.u_bpu.ckpt_full === 1'b0,
                "T18a: 两个 free 兑现后池不得残留 full");
            @(negedge clk); redirect_valid = 1'b0; ckpt_free_valid = 1'b0;
            repeat (2) @(posedge clk);

            // ---- b) held owner 稳定：id0 被更老分支占用，held 用 id1 ----
            do_reset;
            pool_clear;
            wr(32'h8000_00c0, enc_jal(5'd0, 21'h20));       // → 0x8000_00e0
            do_redirect(32'h8000_00c0);
            blk_ready = 1'b1;
            grab_until_pc(32'h8000_00c0, ln, fnd);
            chk(fnd === 1 && obs_ckv === 4'b0001 && ckid(0) === 4'd0,
                "T18b: 较老分支必须占用 id0");
            wr(32'h8000_0100, enc_jal(5'd0, 21'h20));       // → 0x8000_0120
            do_redirect(32'h8000_0100);
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_ckv === 4'b0001 && ckid(0) === 4'd1,
                "T18b: held 块预留 id1（最低空闲）");
            // 后端提交较老分支：释放 id0，不得影响 held 的 id1
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = 4'd0;
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
            #1;
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b0 &&
                u_dut.u_bpu.ck_valid_q[1] === 1'b1,
                "T18b: 释放旧 id0 后 held 仍独占 id1");
            snapshot_obs;
            chk(obs_v === 1'b1 && ckid(0) === 4'd1,
                "T18b: 释放 id0 后 held 的 lane_ckpt 仍为 1");
            fire_held;
            chk(u_dut.u_bpu.ck_valid_q[1] === 1'b1,
                "T18b: fire 拍真实 pool owner 仍是 id1（不是重新分配/覆盖）");
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b0,
                "T18b: fire 不得把已释放的 id0 重新占上");
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = 4'd1;
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
            #1;
            chk(u_dut.u_bpu.ck_valid_q[1] === 1'b0,
                "T18b: 后端释放 held id1 后池位必须清零");

            // ---- c) 最后 id / 池满不倒灌 held ----
            do_reset;
            pool_clear;
            for (ii = 0; ii < 15; ii = ii + 1) begin
                wr(32'h8000_6000 + ii*64, enc_jal(5'd0, 21'h4));
                do_redirect(32'h8000_6000 + ii*64);
                blk_ready = 1'b1;
                grab_until_pc(32'h8000_6000 + ii*64, ln, fnd);
                chk(fnd === 1 && ln === 0, "T18c: 第 i 个 taken 块必须呈现");
                chk(obs_ckv === 4'b0001 && ckid(0) === ii[3:0],
                    "T18c: 每次分配必须取最低空闲 id（0..14）");
                chk(u_dut.u_bpu.ck_valid_q[ii] === 1'b1,
                    "T18c: 真实池对应 id 必须已分配");
            end
            wr(32'h8000_6000 + 15*64, enc_jal(5'd0, 21'h4));
            do_redirect(32'h8000_6000 + 15*64);
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_ckv === 4'b0001 && ckid(0) === 4'd15,
                "T18c: 最后空闲 id15 必须在 held 首次呈现拍预留");
            chk(u_dut.u_bpu.ckpt_full === 1'b1,
                "T18c: 第 16 项分配后池必须为满");
            repeat (4) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_valid === 1'b1 && u_dut.u_bpu.ck_valid_q[15] === 1'b1,
                "T18c: 池满/最后 id 时已 reserved 的 held 块不得被卡住");
            fire_held;
            chk(u_dut.u_bpu.ck_valid_q[15] === 1'b1,
                "T18c: held 消费后 owner 仍由后端持有（不得提前释放）");
            pool_clear;
            for (ii = 0; ii < 16; ii = ii + 1)
                chk(u_dut.u_bpu.ck_valid_q[ii] === 1'b0,
                    "T18c: ckpt_clear_all 后 16 个真实池位必须全 0");
            chk(u_dut.u_bpu.ckpt_full === 1'b0, "T18c: clear_all 后不得为 full");
        end

        //======================================================================
        // T19（breakpoint freeze 合同，2026-10-20）：
        //   ① 断点冻结**不取消** held 快照、不释放 reserved id；只抑制呈现/消费；
        //   ② 冻结期间 RAS 顶变化不得篡改快照；解冻恢复**同 payload/同 id**；
        //   ③ 维护 freeze + redirect 同拍 ⇒ 仍按 redirect 取消并归还 id（组合照常）。
        //======================================================================
        begin : t19_freeze
            reg [3:0]  fm0, fckv0;
            reg [31:0] fn0, fpc3, fins3, ftgt3;
            integer    fid, g19;
            do_reset;
            pool_clear;
            // 同 T6：parcel0/2/4 = c.nop，PC6 = jalr x0,0(x1)（32bit，高半在 parcel8）
            wr(32'h8000_0000, {16'h0001, 16'h0001});
            wr(32'h8000_0004, {16'h8067, 16'h0001});
            wr(32'h8000_0008, {16'h0000, 16'h0000});
            do_redirect(32'h8000_0000);
            fe_stall = 1'b1;
            @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_9000;
            @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
            @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_A000;
            @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
            fe_stall = 1'b0;
            wait_present_hold;
            chk(obs_v === 1'b1, "T19: held RET 块必须呈现");
            chk(obs_mask === 4'b1111, "T19: 必须是 4 路块（mask=1111）");
            chk(obs_pc4[127:96] === 32'h8000_0006, "T19: lane3 必须是 PC6 的 RET");
            chk(obs_insn4[127:96] === 32'h0000_8067, "T19: lane3 必须是 jalr 指令位");
            chk(obs_next === 32'h8000_A000, "T19: taken 目标必须是 RAS 顶 0xA000");
            chk(obs_ckv === 4'b1000 && ckid(3) === 4'd0,
                "T19: 只有 RET lane 持有 ckpt id0");
            fm0 = obs_mask; fn0 = obs_next; fpc3 = obs_pc4[127:96];
            fins3 = obs_insn4[127:96]; ftgt3 = obs_tgt4[127:96];
            fckv0 = obs_ckv; fid = ckid(3);
            chk(u_dut.u_bpu.ck_valid_q[fid] === 1'b1,
                "T19: held 的 id 必须在真实池中已预留");
            // breakpoint 冻结（无 redirect）
            @(negedge clk); break_point = 1'b1;
            repeat (6) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_valid === 1'b0, "T19: 断点冻结期间不得呈现/消费块");
            chk(u_dut.u_ifetch4.blk_hold_q === 1'b1,
                "T19: 断点冻结必须保留 hold 快照（不得取消）");
            chk(u_dut.u_bpu.ck_valid_q[fid] === 1'b1,
                "T19: 断点冻结不得释放 reserved id");
            chk(lane_pc[127:96] === fpc3 && lane_pred_target[127:96] === ftgt3,
                "T19: 冻结期间载荷（PC/目标）必须保持");
            // 冻结期间改变 RAS 顶：pop 旧顶 + push 新顶（不得篡改快照）
            @(negedge clk); d2_pop_valid = 1'b1; d2_pop_addr = 32'h8000_A000;
            @(posedge clk); @(negedge clk); d2_pop_valid = 1'b0;
            @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_B000;
            @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_valid === 1'b0 && lane_pred_target[127:96] === ftgt3,
                "T19: 冻结期间 RAS 变化不得改写 held 快照目标");
            // 解冻：同一块、同 id、同 payload
            @(negedge clk); break_point = 1'b0;
            @(posedge clk); @(negedge clk); #1;
            chk(blk_valid === 1'b1, "T19: 解冻必须恢复呈现同一块（不是丢弃重建）");
            chk(blk_mask === fm0 && blk_next_pc === fn0,
                "T19: 解冻后 mask/next_pc 必须与冻结前一致");
            chk(lane_pc[127:96] === fpc3 && lane_insn[127:96] === fins3,
                "T19: 解冻后 lane3 PC/指令位必须一致");
            chk(lane_ckpt_valid === fckv0 && lane_ckpt[15:12] === fid[3:0],
                "T19: 解冻后 ckpt 归属/id 必须一致");
            chk(lane_pred_target[127:96] === ftgt3,
                "T19: 解冻后预测目标必须是快照值（不是新 RAS 顶 0xB000）");
            fire_held;
            chk(u_dut.u_bpu.ck_valid_q[fid] === 1'b1,
                "T19: fire 后 owner 仍在池中（由后端提交释放）");
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = fid[3:0];
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
            #1;
            chk(u_dut.u_bpu.ck_valid_q[fid] === 1'b0,
                "T19: 无重复/无泄漏：后端释放后池位清零");

            // ---- ③ 维护 freeze + redirect 同拍 ----
            do_reset;
            pool_clear;
            wr(32'h8000_0140, enc_jal(5'd0, 21'h20));       // → 0x8000_0160
            do_redirect(32'h8000_0140);
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_ckv === 4'b0001 && ckid(0) === 4'd0,
                "T19b: held 块先预留 id0");
            @(negedge clk);
            redirect_valid = 1'b1; redirect_pc = 32'h8000_0000;
            fe_stall = 1'b1; break_point = 1'b1;
            @(posedge clk); #1;
            chk(blk_valid === 1'b0, "T19b: freeze+redirect 同拍必须取消呈现");
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b0,
                "T19b: freeze+redirect 组合仍须归还 held id");
            @(negedge clk);
            redirect_valid = 1'b0; fe_stall = 1'b0; break_point = 1'b0;
            repeat (2) @(posedge clk);

            // ---- ④ 首次呈现遇 freeze：不得"偷偷 alloc"无 owner ----
            do_reset;
            pool_clear;
            wr(32'h8000_0180, enc_jal(5'd0, 21'h20));       // → 0x8000_01a0
            fe_stall = 1'b1;
            do_redirect(32'h8000_0180);
            repeat (8) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_valid === 1'b0, "T19c: 冻结期间不得呈现块");
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b0,
                "T19c: 首次呈现被 freeze 挡住时不得偷偷分配检查点");
            @(negedge clk); fe_stall = 1'b0;
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_ckv === 4'b0001 && ckid(0) === 4'd0,
                "T19c: 解冻后的首次呈现才分配 id0（owner 可见）");
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b1,
                "T19c: 解冻呈现拍真实池位才置 1");
            @(negedge clk); redirect_valid = 1'b1; redirect_pc = 32'h8000_0000;
            @(posedge clk);
            @(negedge clk); redirect_valid = 1'b0;
            #1;
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b0,
                "T19c: redirect 取消 held 必须归还 id0（无泄漏）");
        end

        //======================================================================
        // T20（真实 fault1/done0）：故障 word 的 done=0、fault 电平保持到消费。
        //   · 跨页高半（T1 同形）：cause=1(AF) / tval=下一页首地址 / 零毒 PA；
        //   · 高半起始（T3 同形）：tval=PC+2；
        //   · 首 parcel（对齐 word）：lane0 故障、前缀为空、更年轻截断。
        //======================================================================
        begin : t20_done0
            integer g20;
            // a) 跨页 + AF + done0
            do_reset;
            tr_mode = 2'd1;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000;
            pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b1;
            pg_pa[8'h01] = 32'hDEAD_0000;
            wr(32'h8000_0ffc, {16'h006f, 16'h0001});   // 0xffe 起 32bit jal，高半在 0x1000
            do_redirect(32'h8000_0ffc);
            grab_until_pc(32'h8000_0ffe, ln, fnd);
            chk(fnd === 1, "T20a: done=0+fault=1 也必须交付故障块");
            chk(obs_mask === ((4'b0001 << ln) | ((4'b0001 << ln) - 4'b0001)),
                "T20a: 块必须在故障 lane 处终止");
            chk((obs_cause4[ln*5 +: 5]) === 5'd1,
                "T20a: AF 分类必须为 cause 1（done=0 不得退化成 page fault）");
            chk_eq32(obs_tval4[ln*32 +: 32], 32'h8000_1000,
                     "T20a: tval 必须是下一页首地址（故障 parcel VA）");
            wait_frozen;
            chk(u_dut.u_ifetch4.fault_hold_q === 1'b1,
                "T20a: 故障块消费后必须冻结到重定向");
            for (g20 = 0; g20 < n_req; g20 = g20 + 1)
                chk(req_log[g20] !== 32'hDEAD_0000,
                    "T20a: done=0 的故障绝不能用毒 PA 发取指请求");
            do_redirect(32'h8000_0000);

            // b) 高半起始 + page fault + done0
            do_reset;
            tr_mode = 2'd1;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_flt[8'h03] = 1'b1; pg_pa[8'h03] = 32'hDEAD_3000;
            do_redirect(32'h8000_3002);
            grab_until_pc(32'h8000_3002, ln, fnd);
            chk(fnd === 1 && ln === 0, "T20b: 故障块必须从 0x80003002 开始");
            chk((obs_cause4[0 +: 5]) === 5'd12, "T20b: page fault cause 必须为 12");
            chk_eq32(obs_tval4[0 +: 32], 32'h8000_3002,
                     "T20b: tval 必须是 PC+2（不是 word base）");
            for (g20 = 0; g20 < n_req; g20 = g20 + 1)
                chk(req_log[g20] !== 32'hDEAD_3000,
                    "T20b: 毒 PA 不得出现在任何取指请求");
            do_redirect(32'h8000_0000);

            // c) 对齐 word 首 parcel 故障 + 更年轻截断
            do_reset;
            tr_mode = 2'd1;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_flt[8'h02] = 1'b1; pg_pa[8'h02] = 32'hDEAD_2000;
            wr(32'h8000_2000, {16'h0001, 16'h0001});
            do_redirect(32'h8000_2000);
            grab_until_pc(32'h8000_2000, ln, fnd);
            chk(fnd === 1 && ln === 0, "T20c: 对齐 word 故障必须在 lane0");
            chk(obs_mask === 4'b0001, "T20c: 故障块必须只有故障 lane");
            chk((obs_cause4[0 +: 5]) === 5'd12, "T20c: 首 parcel page fault cause=12");
            chk_eq32(obs_tval4[0 +: 32], 32'h8000_2000, "T20c: tval=故障 word VA");
            repeat (8) @(posedge clk);
            chk(blk_valid === 1'b0,
                "T20c: 故障消费后更年轻内容必须截断（不再呈现）");
            do_redirect(32'h8000_0000);

            // d) 上下文切到 Bare（en 撤掉，无 redirect）：旧 fault 锁存必须清除，
            //    F3 按 VA=PA 继续，不得悬挂在已失效的翻译结果上。
            do_reset;
            tr_mode = 2'd2; l1i_lat = 3;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000;
            pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b1;
            pg_pa[8'h01] = 32'hDEAD_1000;
            wr(32'h8000_0ffc, {16'h0001, 16'h0001});
            wr(32'h8000_1000, {16'h0001, 16'h0001});
            do_redirect(32'h8000_0ffc);
            blk_ready = 1'b0;
            fnd = 0;
            //   只读**旧/新树都有**的 `f3_tr_fault`（不引用新树私有锁存寄存器），
            //   保证本 TB 也能在旧 baseline 上编译（旧树此处只 1 拍高）。
            for (g20 = 0; g20 < 80 && !fnd; g20 = g20 + 1) begin
                @(posedge clk);
                if (u_dut.u_ifetch4.f3_tr_fault === 1'b1) fnd = 1;
            end
            chk(fnd === 1, "T20d: 应观测到故障响应（真实 done0/pulse）");
            @(negedge clk); sv32_translate_en = 1'b0;   // 上下文改 Bare（无 redirect）
            repeat (4) @(posedge clk);
            @(negedge clk); #1;
            chk(u_dut.u_ifetch4.f3_tr_fault === 1'b0,
                "T20d: 翻译撤销后旧 fault 状态必须清除");
            grab_until_pc(32'h8000_1000, ln, fnd);
            chk(fnd === 1, "T20d: 撤翻译后 F3 必须按 Bare 继续（不得悬挂）");
            chk(lane_fault[ln] === 1'b0,
                "T20d: 已撤销的翻译 fault 不得污染后续 Bare word");
            chk_eq32(obs_pc4[ln*32 +: 32], 32'h8000_1000,
                     "T20d: Bare 继续取指的 PC 必须正确");
            do_redirect(32'h8000_0000);
        end

        //======================================================================
        // T21（故障响应"晚于前缀字入缓冲"的合法时序）：
        //   · 故障响应是**单拍脉冲**（真实 MMU 的 owner/优先级事件可撤掉响应），
        //     且 AF 分类只在响应拍有效；前端必须在响应拍锁存终态（fault+AF），
        //     不能在"标记入队拍"再采实时输入。
        //   · L1I 延迟 2 拍 ⇒ 故障 word 的前缀字仍在 F4、push_from 尚未追上，
        //     故障标记必须等前缀字入缓冲后才入队（旧实现此时已丢故障）。
        //   · 期望：前缀两 lane 照交（页尾块 next=下一页首地址），下一页的故障
        //     标记作为新块 lane0 交付、cause=1（AF 锁存）、tval=故障 word VA、
        //     零毒 PA、消费后冻结/更年轻截断。
        //======================================================================
        begin : t21_pulse
            integer g21;
            do_reset;
            tr_mode = 2'd2; l1i_lat = 2;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000;
            pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b1;
            pg_pa[8'h01] = 32'hDEAD_1000;
            wr(32'h8000_0ffc, {16'h0001, 16'h0001});   // 0xffc/0xffe = c.nop（页尾）
            do_redirect(32'h8000_0ffc);
            //   页边界规则：前缀两 lane 属本块，块在页尾终止（next=0x1000，不跨页）
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_mask === 4'b0011,
                "T21: 前缀块必须先呈现 0xffc/0xffe 两 lane");
            chk(obs_next === 32'h8000_1000,
                "T21: 页尾前缀块必须在 0xffe 后终止且 next=下一页首地址");
            chk(obs_insn4[31:0] === 32'h0000_0001 &&
                obs_insn4[63:32] === 32'h0000_0001,
                "T21: 前缀 lane 的指令位必须正确（不得用故障标记顶替）");
            chk(obs_feff === 1'b0, "T21: 前缀块首次呈现不得提前报 fault");
            //   保持前缀块期间，下一页 marker 已入缓冲（在 mask 之外）⇒ 对外故障必须
            //   仍为 0（mask 语义）；随后消费前缀块，故障标记进入下一块 lane0。
            repeat (6) @(posedge clk);
            snapshot_obs;
            chk(blk_valid === 1'b1 && blk_mask === 4'b0011,
                "T21: 前缀块保持期间 mask 必须稳定");
            chk(obs_feff === 1'b0,
                "T21: 前缀块 mask 外的下一页 marker 不得让 fe_fetch_fault 提前置位");
            fire_held;
            //   故障标记属于下一页 ⇒ 新块 lane0；响应脉冲已撤，AF 必须已锁存
            grab_until_pc(32'h8000_1000, ln, fnd);
            chk(fnd === 1 && ln === 0,
                "T21: 故障标记必须是新页块的 lane0");
            chk(obs_mask === 4'b0001,
                "T21: 故障块必须在故障 lane 处终止");
            chk((obs_cause4[0 +: 5]) === 5'd1,
                "T21: AF 分类必须在响应拍锁存（实时 af 已撤 ⇒ 仍须 cause=1）");
            chk_eq32(obs_tval4[0 +: 32], 32'h8000_1000,
                     "T21: tval 必须是故障 word 的 VA");
            chk((obs_fault4 & obs_mask) === 4'b0001,
                "T21: 本块 mask 内只有故障 lane 置 fault（mask 外 marker 不属本块）");
            chk(obs_feff === 1'b1,
                "T21: 故障块呈现时 fe_fetch_fault 必须为 1");
            wait_frozen;
            chk(u_dut.u_ifetch4.fault_hold_q === 1'b1,
                "T21: 脉冲故障消费后必须进入 fault hold");
            for (g21 = 0; g21 < n_req; g21 = g21 + 1)
                chk(req_log[g21] !== 32'hDEAD_1000,
                    "T21: 故障/被撤响应期间绝不得用毒 PA 发请求");
            repeat (8) @(posedge clk);
            chk(blk_valid === 1'b0, "T21: 故障后更年轻内容必须截断");
            do_redirect(32'h8000_0000);
        end

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
        // ★ 实际活动 F4 错行：在该 word 的取指窗口内持续打**不匹配行** err，
        //   该 word 必须按原数据正常完成（不是"设置一个永远不作用的全局变量"）。
        do_reset; err_en = 0;
        wr(32'h8000_0100, {16'h0080, 16'h006f});
        do_redirect(32'h8000_0100);
        blk_ready = 1'b0;
        @(negedge clk); err_force = 1; err_force_pa = 32'h8000_0200;   // 不匹配行
        repeat (10) @(posedge clk);
        @(negedge clk); err_force = 0;
        grab_until_pc(32'h8000_0100, ln, fnd);
        chk(fnd === 1, "T11: 错行 err 后该 word 必须正常完成并交付");
        chk(obs_fault4[ln*4 + 0] === 1'b0, "T11: 活动 F4 的错行 err 必须被忽略（不产生 fault）");
        chk_eq32(obs_insn4[ln*32 +: 32], 32'h0080_006f,
                 "T11: 错行 err 后原指令位必须正确");
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
        // T22（F1 审计 2026-10-22）：RVC Q2 分类必须按 **funct3==100** 限定 JR/JALR。
        //   旧式漏 funct3 ⇒ c.slli/c.lwsp/c.fldsp/c.flwsp（bit12=0, rd!=0, rs2=0）
        //   被误判成 C_RET：RAS 非空/BTB 命中时伪 taken/重启，跳过顺序指令。
        //   覆盖：全部合法 Q2 非 CF（SLLI/LWSP/SWSP/FP 栈 load/store/MV/ADD/reserved/
        //   EBREAK）在非空 RAS 下不得 taken/alloc/终止；真 0x8082/0x9082 仍跳。
        //======================================================================
        begin : t22_q2
            reg [15:0] q2i [0:10];
            integer    qi;
            q2i[0]  = 16'h0082;   // C.SLLI
            q2i[1]  = 16'h2082;   // C.FLDSP f1,0(sp)
            q2i[2]  = 16'h4082;   // C.LWSP x1,0(sp)  ← 审计实锤
            q2i[3]  = 16'h6082;   // C.FLWSP f1,0(sp)
            q2i[4]  = 16'h808A;   // C.MV x1,x2
            q2i[5]  = 16'h908A;   // C.ADD x1,x2
            q2i[6]  = 16'hA006;   // C.FSDSP
            q2i[7]  = 16'hC006;   // C.SWSP
            q2i[8]  = 16'hE006;   // C.FSWSP
            q2i[9]  = 16'h8002;   // reserved C.JR x0
            q2i[10] = 16'h9002;   // C.EBREAK
            for (qi = 0; qi < 11; qi = qi + 1) begin : q2case
                reg [31:0] qpc;
                qpc = 32'h8000_7000 + qi*32'h80;
                do_reset;
                wr16(qpc,      q2i[qi]);
                wr16(qpc+2,    16'h0001);
                wr16(qpc+4,    16'h0001);
                wr16(qpc+6,    16'h0001);
                do_redirect(qpc);
                fe_stall = 1'b1;
                @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_9000;
                @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
                fe_stall = 1'b0;
                blk_ready = 1'b1;
                grab_until_pc(qpc, ln, fnd);
                $display("T22 CASE %0d insn=0x%04x fnd=%0d ln=%0d mask=%b next=%h cls=%h pt=%b ckv=%b feff=%b",
                         qi, q2i[qi], fnd, ln, obs_mask, obs_next,
                         obs_cls4[2:0], obs_pt4[0], obs_ckv, obs_feff);
                chk(fnd === 1 && ln === 0, "T22: 合法 Q2 非 CF 必须从本 PC 呈现");
                chk(obs_mask === 4'b1111,
                    "T22: 合法 Q2 非 CF 不得终止块（必须 4 lane 顺序）");
                chk_eq32(obs_next, qpc + 32'd8, "T22: 非 CF 的 next_pc 必须顺序 +8");
                chk(obs_ckv === 4'b0000, "T22: 非 CF 不得分配检查点");
                chk(obs_pt4[0] === 1'b0, "T22: 非 CF 不得被预测 taken");
                chk(obs_cls4[2:0] === 3'd0, "T22: 非 CF 分类必须是 C_NONE");
                chk(obs_feff === 1'b0, "T22: 非 CF 不得报取指 fault");
            end
            // ---- 真 C.JR ra（0x8082）仍 RET/taken，目标=RAS 顶 ----
            begin : q2_ret
                reg [31:0] qpc;
                qpc = 32'h8000_7800;
                do_reset;
                wr16(qpc, 16'h8082); wr16(qpc+2, 16'h0001);
                do_redirect(qpc);
                fe_stall = 1'b1;
                @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = 32'h8000_9000;
                @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
                fe_stall = 1'b0; blk_ready = 1'b1;
                grab_until_pc(qpc, ln, fnd);
                chk(fnd === 1 && ln === 0, "T22: 真 C.JR ra 必须呈现");
                chk(obs_mask === 4'b0001 && obs_next === 32'h8000_9000,
                    "T22: 真 C.JR ra 必须 taken 到 RAS 顶（仍 RET）");
                chk(obs_cls4[2:0] === 3'd4 && obs_pt4[0] === 1'b1,
                    "T22: 真 C.JR ra 必须分类 RET 且预测 taken");
                chk(obs_ckv === 4'b0001 && ckid(0) === 4'd0,
                    "T22: 真 C.JR ra 必须分配检查点");
            end
            // ---- 真 C.JALR ra（0x9082，BTB 命中）仍跳 ----
            begin : q2_jalr
                reg [31:0] qpc;
                qpc = 32'h8000_7880;
                do_reset;
                wr16(qpc, 16'h9082); wr16(qpc+2, 16'h0001);
                train_ind(qpc, 32'h8000_A000);
                repeat (80) @(posedge clk);
                do_redirect(qpc);
                blk_ready = 1'b1;
                grab_until_pc(qpc, ln, fnd);
                chk(fnd === 1 && ln === 0, "T22: 真 C.JALR ra 必须呈现");
                chk(obs_mask === 4'b0001 && obs_next === 32'h8000_A000,
                    "T22: 真 C.JALR ra 必须按 BTB 目标 taken");
                chk(obs_cls4[2:0] === 3'd6 && obs_pt4[0] === 1'b1,
                    "T22: 真 C.JALR ra 必须分类 ICALL 且预测 taken");
                chk(obs_ckv === 4'b0001, "T22: 真 C.JALR ra 必须分配检查点");
            end
        end

        //======================================================================
        // T23（F2 审计 2026-10-22）：冻结期间的"先应答/先入 marker、后首次呈现"。
        //   F4 前缀请求已在途 → freeze → 前缀响应/下一页 marker 均入缓冲 → 解冻后
        //   **首次呈现** mask=0011，但 lane2/3 是 mask 外的下一页 marker。
        //   对外 fe_fetch_fault 必须按 mask 归约（不得被块外 marker 污染）；
        //   消费前缀后，新流 marker 的 cause/tval 仍必须准确。
        //======================================================================
        begin : t23_frozen_first
            integer g23;
            do_reset;
            tr_mode = 2'd1; l1i_lat = 3;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000;
            pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b0;
            pg_pa[8'h01] = 32'hDEAD_1000;
            wr(32'h8000_0ffc, {16'h0001, 16'h0001});   // 页尾两 c.nop
            wr(32'h8000_1000, {16'h0001, 16'h0001});
            do_redirect(32'h8000_0ffc);
            // 等 F4 的前缀请求真正在途（此时再 freeze，响应仍会返回并 push）
            fnd = 0;
            for (g23 = 0; g23 < 80 && !fnd; g23 = g23 + 1) begin
                @(posedge clk);
                if (l1i_req_valid && (l1i_req_addr === 32'h8000_0ffc)) fnd = 1;
            end
            chk(fnd === 1, "T23: 必须观察到前缀 F4 请求在途");
            @(negedge clk); fe_stall = 1'b1;
            repeat (14) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_valid === 1'b0, "T23: 冻结期间不得首次呈现");
            chk(u_dut.u_ifetch4.buf_cnt_q >= 5'd4,
                "T23: 冻结期间前缀两 parcel + 下页两 marker 必须已入缓冲");
            // 解冻后第一次呈现：comb 块 mask=0011，块外 marker 不得令全局 fault 高
            @(negedge clk); fe_stall = 1'b0; blk_ready = 1'b0;
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_mask === 4'b0011,
                "T23: 首次呈现必须是页尾前缀块 mask=0011");
            chk(obs_next === 32'h8000_1000,
                "T23: 前缀块 next 必须是下一页首地址（不跨页）");
            chk((obs_fault4 & obs_mask) === 4'b0000,
                "T23: 本块 mask 内不得有故障 lane");
            chk(obs_fault4[2] === 1'b1,
                "T23: mask 外 lane2 必须已是下页翻译故障 marker");
            chk(obs_feff === 1'b0,
                "T23: mask 外下一页 marker 不得令 fe_fetch_fault 伪高（F2）");
            // 消费前缀后，新流 marker 仍准确
            fire_held;
            grab_until_pc(32'h8000_1000, ln, fnd);
            chk(fnd === 1 && ln === 0, "T23: 新流必须从 0x1000 marker 开始");
            chk(obs_mask === 4'b0001 && obs_fault4[0] === 1'b1,
                "T23: 新流故障块必须在 marker lane 终止");
            chk((obs_cause4[0 +: 5]) === 5'd12,
                "T23: 新流 page fault cause 必须仍为 12");
            chk_eq32(obs_tval4[0 +: 32], 32'h8000_1000,
                     "T23: 新流 tval 必须仍为故障 word VA");
            wait_frozen;
            chk(u_dut.u_ifetch4.fault_hold_q === 1'b1,
                "T23: 新流故障消费后仍必须冻结");
            do_redirect(32'h8000_0000);
        end

        //======================================================================
        // T24（F2 审计 2026-10-22）：older-taken + 更年轻 marker 的因果隔离。
        //   页尾 lane1 是预测 taken 的 c.j，更年轻的下一页 marker 在 mask 外；
        //   冻结到 marker 入缓冲后首次呈现：全局 fault 必须为 0、块仍 taken 到
        //   分支目标；restart 后新流不得继承年轻 marker 的 fault。
        //======================================================================
        begin : t24_taken_young
            integer g24;
            do_reset;
            tr_mode = 2'd1; l1i_lat = 3;
            sv32_translate_en = 1'b1; priv = `RV32GC_PRIV_M;
            pg_pa[8'h00] = 32'h8000_0000;
            pg_flt[8'h01] = 1'b1; pg_af[8'h01] = 1'b0;
            pg_pa[8'h01] = 32'hDEAD_1000;
            // 0xffc c.nop；0xffe c.j → 0x8000_0800（页尾 taken，块在 lane1 终止）
            wr16(32'h8000_0ffc, 16'h0001);
            wr16(32'h8000_0ffe, enc_c_j(12'h802));   // -0x7FE ⇒ 0x80000800
            do_redirect(32'h8000_0ffc);
            fnd = 0;
            for (g24 = 0; g24 < 80 && !fnd; g24 = g24 + 1) begin
                @(posedge clk);
                if (l1i_req_valid && (l1i_req_addr === 32'h8000_0ffc)) fnd = 1;
            end
            chk(fnd === 1, "T24: 必须观察到前缀 F4 请求在途");
            @(negedge clk); fe_stall = 1'b1;
            repeat (14) @(posedge clk);
            @(negedge clk); #1;
            chk(blk_valid === 1'b0, "T24: 冻结期间不得首次呈现");
            @(negedge clk); fe_stall = 1'b0; blk_ready = 1'b0;
            wait_present_hold;
            chk(obs_v === 1'b1 && obs_mask === 4'b0011,
                "T24: 首次呈现必须是页尾 taken 块 mask=0011");
            chk(obs_next === 32'h8000_0800,
                "T24: older taken 的 next 必须是分支目标");
            chk(obs_ckv === 4'b0010 && ckid(1) === 4'd0,
                "T24: 只允许 taken lane1 声明检查点 id0");
            chk((obs_fault4 & obs_mask) === 4'b0000,
                "T24: 本块 mask 内不得有故障（年轻 marker 在 mask 外）");
            chk(obs_fault4[2] === 1'b1,
                "T24: 更年轻 lane2 的 marker fault 必须存在（mask 外）");
            chk(obs_feff === 1'b0,
                "T24: 年轻 marker 不得令 fe_fetch_fault 伪高（F2）");
            fire_held;
            chk(u_dut.u_bpu.ck_valid_q[0] === 1'b1,
                "T24: taken fire 后 owner id0 仍由后端持有");
            // restart 后新流：不得继承年轻 marker 的 fault
            grab_until_pc(32'h8000_0800, ln, fnd);
            chk(fnd === 1, "T24: restart 后必须取到分支目标 0x8000_0800");
            chk((obs_fault4 & obs_mask) === 4'b0000,
                "T24: restart 后新流不得继承年轻 marker 的 fault");
            chk(blk_taken === 1'b0, "T24: 分支目标流不得被年轻 marker 误 taken");
            do_redirect(32'h8000_0000);
        end

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
