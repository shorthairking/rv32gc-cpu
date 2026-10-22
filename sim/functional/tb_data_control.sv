//==============================================================================
// sim/functional/tb_data_control.sv —— F4 数据侧 LSQ 最小契约功能包（fail-closed）
//------------------------------------------------------------------------------
// 项目 : rv32gc-cpu（2B 后端 LSQ 叶；Top owner 负责 PMP/PMA/IRQ/kill-drain）
//
// 两种编译形态（**纯宏绑定**，同一份 TB 源码）：
//   · `-D LSQ_DATA_CTRL`：新接口形态。连接全部新口，跑 CDQ 所有权 + 数据侧契约向量。
//   · 不定义宏：旧接口形态。只连旧口，跑 CDQ 所有权/level 反证向量（可在旧树上编译）。
//     旧树（201acf61）预期出现重复入队；新树在该形态必须一次。
//
// 判据纪律：
//   · 每个向量打印 `VEC id name checks=n fails=n defect=d`；
//   · `chk` 用 `!== 1'b1`（X/Z 也算失败）；
//   · 旧行为签名（重复 store 入队）单独 `mark_defect`，旧树反证时要求 d=1；
//   · 只通过真实端口握手推进，不 force DUT 状态。
//
// 新接口向量的独立 gold：
//   · req 字节：bmask=字节道集合，bytes=popcount；base=addr&~3，实际字节=base+j(mask[j])；
//   · cause：load 5/13、store 7/15；非法/未知 active ⇒ fail-closed（load 5/store 7）+ 粘滞；
//   · defer：非 head 设备 load 不 done/wb/exc，等 head 后恰一次重发；
//   · side：token 保持到提交释放，不在 WB 清；partial squash 保更老 owner；
//   · flush 拍不发新 load 请求；跨 flush 旧响应由 Top kill/drain 合同丢弃。
//
// 运行（由 sim/functional/test_data_control.sh 调用）：
//   iverilog -g2012 -I <DUT_ROOT> -s tb_data_control_top -o x.vvp \
//       [-D LSQ_DATA_CTRL] sim/functional/tb_data_control.sv <DUT_ROOT>/rtl/back2/lsq_simple.v
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module tb_data_control_top;
    localparam integer STQ_N  = `BACK2_STQ_N;
    localparam integer STQ_IW = `BACK2_STQ_IDX_W;
    localparam integer OUT_N  = `BACK2_MEM_OUT_N;
    localparam integer LQ_IW  = `BACK2_LQ_IDX_W;
    localparam integer TAG_W  = `BACK2_MEM_TAG_W;
    localparam integer ROBW   = `BACK2_ROB_IDX_W;
    localparam integer PDW_I  = `BACK2_PREG_I_W;
    localparam integer PDW_F  = `BACK2_PREG_F_W;
    localparam integer W      = `BACK2_DISP_W;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    //--------------------------------------------------------------------------
    // 0. DUT 端口（旧口 + 宏控制的新口）
    //--------------------------------------------------------------------------
    reg              flush_all = 0, squash = 0;
    reg [ROBW-1:0]   squash_idx = 0, rob_head = 0;
    reg [W-1:0]      alloc_valid = 0;
    reg [W*ROBW-1:0] alloc_rob = 0;
    wire             alloc_ok;
    wire [W*STQ_IW-1:0] alloc_idx;
    reg [W-1:0]         lalloc_valid = 0;
    reg [W*ROBW-1:0]    lalloc_rob = 0;
    wire                lalloc_ok;
    wire [W*LQ_IW-1:0]  lalloc_idx;
    reg                 exe_valid = 0, exe_is_store = 0, exe_is_fp = 0;
    reg [ROBW-1:0]      exe_rob = 0;
    reg [`BACK2_EPOCH_W-1:0] exe_epoch = 0;
    reg [31:0]          exe_addr = 0, exe_wdata = 0, exe_wdata_hi = 0;
    reg [2:0]           exe_size = 0;
    reg                 exe_unsign = 0, exe_dst_i = 0, exe_dst_f = 0;
    reg [PDW_I-1:0]     exe_pdest_i = 0;
    reg [PDW_F-1:0]     exe_pdest_f = 0;
    reg [STQ_IW-1:0]    exe_stq_idx = 0;
    reg [LQ_IW-1:0]     exe_lq_idx = 0;
    reg [ROBW-1:0]      iss_rob = 0;
    wire                iss_ok, dr_empty_o;
    reg [W-1:0]         dr_valid = 0;
    reg [W*STQ_IW-1:0]  dr_idx = 0;
    wire                dr_room_ok;
    reg [2:0]           cmt_n = 0;

    wire             mem_req_valid, mem_req_wen;
    wire [31:0]      mem_req_addr, mem_req_wdata;
    wire [3:0]       mem_req_wstrb;
    wire [TAG_W-1:0] mem_req_tag;
    reg              mem_req_ready = 0;
    wire             mem_rsp_valid;
    wire [31:0]      mem_rsp_rdata;
    wire [TAG_W-1:0] mem_rsp_tag;
    wire             mem_rsp_err;
    reg              mem_rsp_valid_r = 0;
    reg [31:0]       mem_rsp_rdata_r = 0;
    reg [TAG_W-1:0]  mem_rsp_tag_r = 0;
    reg              mem_rsp_err_r = 0;

    wire             exc_valid_o;
    wire [ROBW-1:0]  exc_rob_o;
    wire [3:0]       exc_cause_o;
    wire [31:0]      exc_tval_o;
    wire             wb_valid;
    wire [ROBW-1:0]  wb_rob;
    wire [`BACK2_EPOCH_W-1:0] wb_epoch;
    wire             wb_dst_i, wb_dst_f;
    wire [PDW_I-1:0] wb_pdest_i;
    wire [PDW_F-1:0] wb_pdest_f;
    wire [31:0]      wb_data, wb_data_hi;
    wire             wb_f64;
    wire             st_done_valid;
    wire [ROBW-1:0]  st_done_rob;
    wire [`BACK2_EPOCH_W-1:0] st_done_epoch;

    reg              st_xlate_en = 0;
    reg [3:0]        st_xlate_ctx = 0;
    wire             st_xlate_valid;
    wire [31:0]      st_xlate_va;
    wire [STQ_IW-1:0] st_xlate_idx;
    wire [3:0]       st_xlate_ctx_o;
    wire             st_xlate_ready;
    wire             st_xlate_done;
    wire [31:0]      st_xlate_pa;
    wire             st_xlate_fault;
    wire [7:0]       stq_cnt_o;
    wire [31:0]      cnt_load_o, cnt_store_o, cnt_fwd_o, cnt_stq_stall_o;

`ifdef LSQ_DATA_CTRL
    // ---- 新接口（仅新形态连接；旧条件编译形态完全不引用）----
    reg  [3:0]       mem_rsp_cause = 0;
    reg              mem_rsp_defer = 0;
    reg              mem_rsp_side  = 0;
    wire [3:0]       st_xlate_fault_cause;
    wire [3:0]       mem_req_bytes;
    wire [3:0]       mem_req_bmask;
    wire [ROBW-1:0]  mem_req_rob;
    wire             mem_req_is_head;
    wire [7:0]       st_xlate_bmask8;
    wire [3:0]       st_xlate_bytes;
    wire             st_xlate_xpg;
    wire             side_issue_valid;
    wire [ROBW-1:0]  side_issue_rob;
    wire             side_pending;
    wire [ROBW-1:0]  side_pending_rob;
    wire [OUT_N-1:0] ld_kill_tags;
`endif

    assign mem_rsp_valid = mem_rsp_valid_r;
    assign mem_rsp_rdata = mem_rsp_rdata_r;
    assign mem_rsp_tag   = mem_rsp_tag_r;
    assign mem_rsp_err   = mem_rsp_err_r;

    lsq_simple #(.DBG(0)) u_lsq (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .squash(squash),
        .squash_idx(squash_idx), .rob_head(rob_head),
        .alloc_valid(alloc_valid), .alloc_rob(alloc_rob), .alloc_ok(alloc_ok),
        .alloc_idx(alloc_idx),
        .lalloc_valid(lalloc_valid), .lalloc_rob(lalloc_rob), .lalloc_ok(lalloc_ok),
        .lalloc_idx(lalloc_idx),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch), .exe_addr(exe_addr),
        .exe_wdata(exe_wdata), .exe_wdata_hi(exe_wdata_hi), .exe_size(exe_size),
        .exe_unsign(exe_unsign), .exe_dst_i(exe_dst_i), .exe_dst_f(exe_dst_f),
        .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f),
        .exe_stq_idx(exe_stq_idx), .exe_lq_idx(exe_lq_idx),
        .iss_rob(iss_rob), .iss_ok(iss_ok), .dr_empty_o(dr_empty_o),
        .dr_valid(dr_valid), .dr_idx(dr_idx), .dr_room_ok(dr_room_ok),
        .cmt_n(cmt_n),
        .mem_req_valid(mem_req_valid), .mem_req_wen(mem_req_wen),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_wstrb(mem_req_wstrb), .mem_req_tag(mem_req_tag),
        .mem_req_ready(mem_req_ready), .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_rdata(mem_rsp_rdata), .mem_rsp_tag(mem_rsp_tag),
        .mem_rsp_err(mem_rsp_err),
`ifdef LSQ_NEW_PORTS_TIE
        //   旧接口形态但 DUT 是新 RTL：新 active 输入必须显式驱 known 0，
        //   不用 Z 兼容逃生口（与产品全真连相反，仅旧 bench 适配）。
        .mem_rsp_cause(4'd0), .mem_rsp_defer(1'b0), .mem_rsp_side(1'b0),
        .st_xlate_fault_cause(4'd0),
`endif
`ifdef LSQ_DATA_CTRL
        .mem_rsp_cause(mem_rsp_cause), .mem_rsp_defer(mem_rsp_defer),
        .mem_rsp_side(mem_rsp_side),
        .mem_req_bytes(mem_req_bytes), .mem_req_bmask(mem_req_bmask),
        .mem_req_rob(mem_req_rob), .mem_req_is_head(mem_req_is_head),
        .st_xlate_bmask8(st_xlate_bmask8), .st_xlate_bytes(st_xlate_bytes),
        .st_xlate_xpg(st_xlate_xpg), .st_xlate_fault_cause(st_xlate_fault_cause),
        .side_issue_valid(side_issue_valid), .side_issue_rob(side_issue_rob),
        .side_pending(side_pending), .side_pending_rob(side_pending_rob),
        .ld_kill_tags(ld_kill_tags),
`endif
        .exc_valid_o(exc_valid_o), .exc_rob_o(exc_rob_o),
        .exc_cause_o(exc_cause_o), .exc_tval_o(exc_tval_o),
        .wb_valid(wb_valid), .wb_rob(wb_rob), .wb_epoch(wb_epoch),
        .wb_dst_i(wb_dst_i), .wb_dst_f(wb_dst_f), .wb_pdest_i(wb_pdest_i),
        .wb_pdest_f(wb_pdest_f), .wb_data(wb_data), .wb_data_hi(wb_data_hi),
        .wb_f64(wb_f64),
        .st_done_valid(st_done_valid), .st_done_rob(st_done_rob),
        .st_done_epoch(st_done_epoch),
        .st_xlate_en(st_xlate_en), .st_xlate_ctx(st_xlate_ctx),
        .st_xlate_valid(st_xlate_valid), .st_xlate_va(st_xlate_va),
        .st_xlate_idx(st_xlate_idx), .st_xlate_ctx_o(st_xlate_ctx_o),
        .st_xlate_ready(st_xlate_ready), .st_xlate_done(st_xlate_done),
        .st_xlate_pa(st_xlate_pa), .st_xlate_fault(st_xlate_fault),
        .stq_cnt_o(stq_cnt_o), .cnt_load_o(cnt_load_o), .cnt_store_o(cnt_store_o),
        .cnt_fwd_o(cnt_fwd_o), .cnt_stq_stall_o(cnt_stq_stall_o)
    );

    //==========================================================================
    // 1. 独立存储模型 + 请求/响应/写回观测
    //==========================================================================
    reg [31:0] mem [0:1023];
    integer    mi;
    initial begin
        for (mi = 0; mi < 1024; mi = mi + 1)
            mem[mi] = {8'h44 ^ mi[7:0], 8'h33 ^ mi[7:0], 8'h22 ^ mi[7:0], 8'h11 ^ mi[7:0]};
    end
    function [31:0] mword(input [31:0] a);
        begin
            mword = mem[a[11:2]];
        end
    endfunction

    integer    n_req, n_ldreq, n_wr, n_wb, n_exc;
`ifdef LSQ_DATA_CTRL
    integer    n_side_issue;
    reg [ROBW-1:0] side_issue_rob_c;
    reg [OUT_N-1:0] kill_tags_c;
`endif
    reg [31:0] rq_addr [0:63];
    reg        rq_wen  [0:63];
    reg [3:0]  rq_bm   [0:63];
    reg [3:0]  rq_by   [0:63];
    reg [ROBW-1:0] rq_rob [0:63];
    reg        rq_head [0:63];
    reg [TAG_W-1:0] rq_tag [0:63];
    reg [31:0] wr_a [0:63];
    reg [31:0] wr_d [0:63];
    reg [3:0]  wr_s [0:63];
    reg [31:0] last_wb_data, last_wb_rob;
    reg        last_wb_di, last_wb_df;
    reg [3:0]  last_exc_cause;
    reg [31:0] last_exc_tval;
    reg [ROBW-1:0] last_exc_rob;
    //   最近一笔 load 请求（单口串行测试用）
    reg        pend_v;
    reg [TAG_W-1:0] pend_tag;
    reg [31:0] pend_addr;
    reg        pend_wen;
    reg [3:0]  pend_bm, pend_by;
    reg [ROBW-1:0] pend_rob;
    reg        pend_head;

    integer bi;
    always @(posedge clk) begin
        if (rst_n) begin
            if ((mem_req_valid === 1'b1) && (mem_req_ready === 1'b1)) begin
                if (n_req < 64) begin
                    rq_addr[n_req] <= mem_req_addr;
                    rq_wen [n_req] <= mem_req_wen;
                    rq_tag [n_req] <= mem_req_tag;
`ifdef LSQ_DATA_CTRL
                    rq_bm  [n_req] <= mem_req_bmask;
                    rq_by  [n_req] <= mem_req_bytes;
                    rq_rob [n_req] <= mem_req_rob;
                    rq_head[n_req] <= mem_req_is_head;
`else
                    rq_bm  [n_req] <= mem_req_wstrb;
                    rq_by  [n_req] <= 4'd0;
                    rq_rob [n_req] <= {ROBW{1'b0}};
                    rq_head[n_req] <= 1'b0;
`endif
                end
                n_req <= n_req + 1;
                if (mem_req_wen) begin
                    if (n_wr < 64) begin
                        wr_a[n_wr] <= mem_req_addr;
                        wr_d[n_wr] <= mem_req_wdata;
                        wr_s[n_wr] <= mem_req_wstrb;
                    end
                    n_wr <= n_wr + 1;
                    for (bi = 0; bi < 4; bi = bi + 1)
                        if (mem_req_wstrb[bi])
                            mem[mem_req_addr[11:2]][8*bi +: 8] <= mem_req_wdata[8*bi +: 8];
                end else begin
                    n_ldreq <= n_ldreq + 1;
                    pend_v    <= 1'b1;
                    pend_tag  <= mem_req_tag;
                    pend_addr <= mem_req_addr;
                    pend_wen  <= 1'b0;
`ifdef LSQ_DATA_CTRL
                    pend_bm   <= mem_req_bmask;
                    pend_by   <= mem_req_bytes;
                    pend_rob  <= mem_req_rob;
                    pend_head <= mem_req_is_head;
`else
                    pend_bm   <= 4'h0;
                    pend_by   <= 4'd0;
                    pend_rob  <= {ROBW{1'b0}};
                    pend_head <= 1'b0;
`endif
                end
            end
            if (wb_valid === 1'b1) begin
                n_wb <= n_wb + 1;
                last_wb_data <= wb_data;
                last_wb_rob  <= {{(32-ROBW){1'b0}}, wb_rob};
                last_wb_di   <= wb_dst_i;
                last_wb_df   <= wb_dst_f;
            end
            if (exc_valid_o === 1'b1) begin
                n_exc <= n_exc + 1;
                last_exc_cause <= exc_cause_o;
                last_exc_tval  <= exc_tval_o;
                last_exc_rob   <= {{(32-ROBW){1'b0}}, exc_rob_o};
            end
`ifdef LSQ_DATA_CTRL
            //   ★ 组合脉冲在 posedge 采样（NBA 更新后 ld_req/ld_v 会变，不能 #1 后再看）
            if (side_issue_valid === 1'b1) begin
                n_side_issue <= n_side_issue + 1;
                side_issue_rob_c <= side_issue_rob;
            end
            if (squash === 1'b1) kill_tags_c <= ld_kill_tags;
`endif
        end
    end

    task resp_now(input [31:0] data);
        begin
            @(negedge clk);
            mem_rsp_valid_r = 1'b1; mem_rsp_rdata_r = data; mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 1'b0;
`ifdef LSQ_DATA_CTRL
            mem_rsp_defer = 1'b0; mem_rsp_side = 1'b0; mem_rsp_cause = 4'd0;
`endif
            @(posedge clk); #1;
            @(negedge clk);
            mem_rsp_valid_r = 1'b0;
`ifdef LSQ_DATA_CTRL
            mem_rsp_defer = 1'b0; mem_rsp_side = 1'b0;
`endif
        end
    endtask

`ifdef LSQ_DATA_CTRL
    task resp_err_cause(input [3:0] cause, input [31:0] data, input side);
        begin
            @(negedge clk);
            mem_rsp_valid_r = 1'b1; mem_rsp_rdata_r = data; mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 1'b0; mem_rsp_defer = 1'b0; mem_rsp_side = side;
            mem_rsp_cause = cause;
            @(posedge clk); #1;
            @(negedge clk);
            mem_rsp_valid_r = 1'b0; mem_rsp_side = 1'b0; mem_rsp_cause = 4'd0;
        end
    endtask
    task resp_defer;
        begin
            @(negedge clk);
            mem_rsp_valid_r = 1'b1; mem_rsp_rdata_r = 32'hDEAD_0000;
            mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 1'b0; mem_rsp_defer = 1'b1; mem_rsp_side = 1'b0;
            mem_rsp_cause = 4'd0;
            @(posedge clk); #1;
            @(negedge clk);
            mem_rsp_valid_r = 1'b0; mem_rsp_defer = 1'b0;
        end
    endtask
`endif

    //==========================================================================
    // 2. store 翻译适配器模型（单笔在途；可注入 fault/cause/延迟）
    //==========================================================================
    localparam TB_IDLE = 2'd0, TB_BUSY = 2'd1, TB_WAIT = 2'd2;
    reg [1:0]  tb_st;
    reg [31:0] tb_va;
    reg        tb_done;
    reg [31:0] tb_pa;
    reg        tb_flt;
    reg [3:0]  tb_cause;
    reg        stx_adapt_en = 1;
    reg        xl_fault = 0;
    reg [3:0]  xl_cause = 0;
    integer    xl_delay = 0;
    reg [3:0]  tb_dly;
    //   观测：最近一次被接受的翻译请求
    integer    xl_n;
    reg [31:0] xl_va_c;
    reg [STQ_IW-1:0] xl_idx_c;
    reg [3:0]  xl_ctx_c;
    reg [7:0]  xl_bm8_c;
    reg [3:0]  xl_by_c;
    reg        xl_xpg_c;
    reg        xl_hi_c;

    function [31:0] xlate_pa(input [31:0] va);
        begin
            //   固定、非零页映射；同页低 12 bit 保持（PA 低 2 bit 与 VA 同）。
            if      (va[31:12] == 20'h00000) xlate_pa = 32'h3000_0000 | {20'h0, va[11:0]};
            else if (va[31:12] == 20'h00001) xlate_pa = 32'h4000_0000 | {20'h0, va[11:0]};
            else                             xlate_pa = 32'h5000_0000 | {20'h0, va[11:0]};
        end
    endfunction

    wire tb_go = (tb_st == TB_IDLE) & stx_adapt_en & st_xlate_valid;
    assign st_xlate_ready = tb_go;
    assign st_xlate_done  = tb_done;
    assign st_xlate_pa    = tb_pa;
    assign st_xlate_fault = tb_flt;
`ifdef LSQ_DATA_CTRL
    assign st_xlate_fault_cause = tb_cause;
    //   翻译请求字段观测（接受拍）
    always @(posedge clk) begin
        if (rst_n && tb_go) begin
            xl_n     <= xl_n + 1;
            xl_va_c  <= st_xlate_va;
            xl_idx_c <= st_xlate_idx;
            xl_ctx_c <= st_xlate_ctx_o;
            xl_bm8_c <= st_xlate_bmask8;
            xl_by_c  <= st_xlate_bytes;
            xl_xpg_c <= st_xlate_xpg;
            xl_hi_c  <= (st_xlate_va[1:0] == 2'b00) ? 1'b0 : 1'b0; // 仅记录，不参与判定
        end
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_st <= TB_IDLE; tb_done <= 1'b0; tb_pa <= 0; tb_flt <= 0; tb_cause <= 0;
            tb_dly <= 0;
        end else begin
            case (tb_st)
                TB_IDLE: begin
                    tb_done <= 1'b0;
                    if (tb_go) begin
                        tb_va <= st_xlate_va;
                        tb_dly <= xl_delay[3:0];
                        tb_st <= TB_BUSY;
                    end
                end
                TB_BUSY: begin
                    if (tb_dly != 4'd0) tb_dly <= tb_dly - 4'd1;
                    else begin
                        tb_pa    <= xlate_pa(tb_va);
                        tb_flt   <= xl_fault;
                        tb_cause <= xl_cause;
                        tb_done  <= 1'b1;
                        tb_st    <= TB_WAIT;
                    end
                end
                default: begin
                    tb_done <= 1'b0;
                    tb_st   <= TB_IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // 3. 判定基础设施
    //==========================================================================
    integer g_total, g_nonzero, g_checks, g_fails, g_defect;
    integer v_checks, v_fails, v_defect;
    reg [8*32-1:0] v_name;

    task vec_begin(input [8*32-1:0] nm);
        begin
            v_name = nm; v_checks = 0; v_fails = 0; v_defect = 0;
            g_total = g_total + 1;
            $display("VEC_START %0d %0s", g_total, nm);
        end
    endtask
    task vec_end;
        begin
            if (v_checks > 0) g_nonzero = g_nonzero + 1;
            $display("VEC %0d %0s checks=%0d fails=%0d defect=%0d",
                     g_total, v_name, v_checks, v_fails, v_defect);
            g_checks = g_checks + v_checks;
            g_fails  = g_fails  + v_fails;
            g_defect = g_defect + v_defect;
        end
    endtask
    task chk(input ok, input [8*64-1:0] what);
        begin
            v_checks = v_checks + 1;
            if (ok !== 1'b1) begin
                v_fails = v_fails + 1;
                $display("CHK_BAD vec=%0d name=%0s what=%0s", g_total, v_name, what);
            end
        end
    endtask
    task mark_defect;
        begin
            v_defect = 1;
            $display("DEFECT_SIG vec=%0d name=%0s", g_total, v_name);
        end
    endtask
    function is_known32(input [31:0] v);
        begin
            is_known32 = (^v !== 1'bx);
        end
    endfunction
    function is_known4(input [3:0] v);
        begin
            is_known4 = (^v !== 1'bx);
        end
    endfunction
    function is_known8(input [7:0] v);
        begin
            is_known8 = (^v !== 1'bx);
        end
    endfunction

    //   四态监视（只查**有效窗口内的控制/真实 payload**；inactive payload 是 don't-care）：
    reg xz_hit;
    integer g_xz;
    always @(*) begin
        xz_hit = 1'b0;
        if (rst_n === 1'b1) begin
            if ((mem_req_valid !== 1'b0) && (mem_req_valid !== 1'b1)) xz_hit = 1'b1;
            if ((mem_req_wen   !== 1'b0) && (mem_req_wen   !== 1'b1)) xz_hit = 1'b1;
            if ((wb_valid     !== 1'b0) && (wb_valid     !== 1'b1)) xz_hit = 1'b1;
            if ((exc_valid_o  !== 1'b0) && (exc_valid_o  !== 1'b1)) xz_hit = 1'b1;
            if ((st_xlate_valid !== 1'b0) && (st_xlate_valid !== 1'b1)) xz_hit = 1'b1;
`ifdef LSQ_DATA_CTRL
            if ((side_pending !== 1'b0) && (side_pending !== 1'b1)) xz_hit = 1'b1;
`endif
            if (mem_req_valid === 1'b1) begin
                if (!is_known32(mem_req_addr) || !is_known32({28'h0, mem_req_tag}))
                    xz_hit = 1'b1;
`ifdef LSQ_DATA_CTRL
                if (!is_known4(mem_req_bytes) || !is_known4(mem_req_bmask))
                    xz_hit = 1'b1;
                if ((mem_req_wen === 1'b1) && !is_known4(mem_req_wstrb))
                    xz_hit = 1'b1;
`endif
            end
            if (wb_valid === 1'b1) begin
                if (!is_known32(wb_data) || !is_known32({{(32-ROBW){1'b0}}, wb_rob}))
                    xz_hit = 1'b1;
            end
            if (exc_valid_o === 1'b1) begin
                if (!is_known4(exc_cause_o) || !is_known32(exc_tval_o))
                    xz_hit = 1'b1;
            end
            if (st_xlate_valid === 1'b1) begin
                if (!is_known32(st_xlate_va) || !is_known4(st_xlate_ctx_o))
                    xz_hit = 1'b1;
`ifdef LSQ_DATA_CTRL
                if (!is_known8(st_xlate_bmask8) || !is_known4(st_xlate_bytes))
                    xz_hit = 1'b1;
`endif
            end
        end
    end
    always @(posedge clk) if (xz_hit === 1'b1) g_xz <= g_xz + 1;

    //==========================================================================
    // 4. 驱动任务
    //==========================================================================
    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0; flush_all = 0; squash = 0;
            alloc_valid = 0; lalloc_valid = 0; dr_valid = 0;
            exe_valid = 0; exe_is_store = 0; exe_is_fp = 0;
            mem_req_ready = 0; st_xlate_en = 0; st_xlate_ctx = 0;
            stx_adapt_en = 1; xl_fault = 0; xl_cause = 0; xl_delay = 0;
            rob_head = 0; squash_idx = 0; cmt_n = 0;
            mem_rsp_valid_r = 0; mem_rsp_err_r = 0;
`ifdef LSQ_DATA_CTRL
            mem_rsp_defer = 0; mem_rsp_side = 0; mem_rsp_cause = 0;
`endif
            exe_wdata_hi = 0; iss_rob = 0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            n_req = 0; n_ldreq = 0; n_wr = 0; n_wb = 0; n_exc = 0;
`ifdef LSQ_DATA_CTRL
            n_side_issue = 0; side_issue_rob_c = 0; kill_tags_c = 0;
`endif
            pend_v = 0; pend_tag = 0; pend_addr = 0; pend_bm = 0; pend_by = 0;
            pend_rob = 0; pend_head = 0;
            xl_n = 0; xl_va_c = 0; xl_idx_c = 0; xl_ctx_c = 0;
            xl_bm8_c = 0; xl_by_c = 0; xl_xpg_c = 0; xl_hi_c = 0;
            last_wb_data = 0; last_wb_rob = 0; last_wb_di = 0; last_wb_df = 0;
            last_exc_cause = 0; last_exc_tval = 0; last_exc_rob = 0;
        end
    endtask

    task alloc_store(input [ROBW-1:0] rb, output [STQ_IW-1:0] idx);
        begin
            @(negedge clk);
            alloc_valid = 4'b0001; alloc_rob = rb;
            #1; idx = alloc_idx[STQ_IW-1:0];
            @(posedge clk); #1;
            alloc_valid = 4'b0000;
        end
    endtask
    task alloc_load(input [ROBW-1:0] rb, output [LQ_IW-1:0] idx);
        begin
            @(negedge clk);
            lalloc_valid = 4'b0001; lalloc_rob = rb;
            #1; idx = lalloc_idx[LQ_IW-1:0];
            @(posedge clk); #1;
            lalloc_valid = 4'b0000;
        end
    endtask
    task exe_store(input [STQ_IW-1:0] slot, input [ROBW-1:0] rb,
                   input [31:0] a, input [31:0] d, input [2:0] sz, input [31:0] dhi);
        begin
            @(negedge clk);
            exe_valid = 1; exe_is_store = 1; exe_is_fp = 0;
            exe_stq_idx = slot; exe_rob = rb; exe_addr = a; exe_wdata = d;
            exe_wdata_hi = dhi; exe_size = sz;
            @(posedge clk); #1;
            exe_valid = 0; exe_is_store = 0;
        end
    endtask
    task exe_load(input [LQ_IW-1:0] slot, input [ROBW-1:0] rb,
                  input [31:0] a, input [2:0] sz);
        begin
            @(negedge clk);
            exe_valid = 1; exe_is_store = 0; exe_is_fp = 0;
            exe_lq_idx = slot; exe_rob = rb; exe_addr = a; exe_size = sz;
            exe_dst_i = 1; exe_pdest_i = 5'd3;
            @(posedge clk); #1;
            exe_valid = 0; exe_dst_i = 0;
        end
    endtask
    task set_head(input [ROBW-1:0] h);
        begin
            @(negedge clk); rob_head = h; #1;
        end
    endtask
    //   单拍合法提交（控制向量用；**不**把 level 持续多个周期，避免把“重复 take”
    //   根因混进控制向量。level 持续由专门的 defect 向量覆盖）。
    task take_once(input [STQ_IW-1:0] s);
        begin
            @(negedge clk);
            mem_req_ready = 1; dr_valid = 4'b0001; dr_idx = s;
            @(posedge clk); #1;
            @(negedge clk); dr_valid = 4'b0000; #1;
        end
    endtask

    //==========================================================================
    // 5. CDQ 所有权 / level 反证（旧口即可；两种形态都跑）
    //==========================================================================
    task vec_cdq_level_once;
        reg [STQ_IW-1:0] s0;
        integer k;
        begin
            vec_begin("cdq_level_take_once");
            do_reset();
            alloc_store(6'd7, s0);
            exe_store(s0, 6'd7, 32'h0000_0100, 32'hA5A5_5A5A, 3'd2, 32'h0);
            set_head(6'd7);
            @(negedge clk);
            mem_req_ready = 1; dr_valid = 4'b0001; dr_idx = s0;
            for (k = 0; k < 12; k = k + 1) @(posedge clk);
            @(negedge clk); dr_valid = 0; mem_req_ready = 0; #1;
            chk(n_wr === 1, "level dr_valid: exactly one CDQ/store write");
            chk((n_wr >= 1) && (wr_a[0] === 32'h0000_0100), "write address");
            chk((n_wr >= 1) && (wr_d[0] === 32'hA5A5_5A5A), "write data");
            chk(dr_empty_o === 1'b1, "CDQ drained");
            if (n_wr !== 1) mark_defect();
            vec_end();
        end
    endtask

    task vec_cdq_level_after_drain;
        reg [STQ_IW-1:0] s0;
        integer k;
        begin
            vec_begin("cdq_level_after_drain");
            do_reset();
            alloc_store(6'd9, s0);
            exe_store(s0, 6'd9, 32'h0000_0200, 32'h1234_5678, 3'd2, 32'h0);
            set_head(6'd9);
            @(negedge clk);
            mem_req_ready = 1; dr_valid = 4'b0001; dr_idx = s0;
            for (k = 0; k < 24; k = k + 1) @(posedge clk);
            @(negedge clk); dr_valid = 0; mem_req_ready = 0; #1;
            chk(n_wr === 1, "level after drain: no re-enqueue");
            chk(dr_empty_o === 1'b1, "CDQ empty after sustained level");
            if (n_wr !== 1) mark_defect();
            vec_end();
        end
    endtask

    task vec_cdq_reuse;
        reg [STQ_IW-1:0] s0, s1;
        integer k;
        begin
            vec_begin("cdq_new_slot_ownership");
            do_reset();
            alloc_store(6'd20, s0);
            exe_store(s0, 6'd20, 32'h0000_0400, 32'h1111_2222, 3'd2, 32'h0);
            set_head(6'd20);
            take_once(s0);
            repeat (4) @(posedge clk);
            chk(n_wr === 1, "old store enqueued once");
            alloc_store(6'd21, s1);
            exe_store(s1, 6'd21, 32'h0000_0500, 32'h3333_4444, 3'd2, 32'h0);
            //   新 store 未提交 ⇒ 不得写
            repeat (3) @(posedge clk);
            chk(n_wr === 1, "no write for uncommitted new slot");
            //   新 store 合法提交拍 ⇒ 恰一次
            @(negedge clk); rob_head = 6'd21; #1;
            take_once(s1);
            repeat (4) @(posedge clk);
            chk(n_wr === 2, "new store enqueued exactly once");
            chk((n_wr >= 2) && (wr_d[1] === 32'h3333_4444), "new store data");
            @(negedge clk); mem_req_ready = 0; #1;
            vec_end();
        end
    endtask

    //   真实同 index 复用：先把 32 槽填满，取队头 store 排空/回收，再 alloc 必然复用
    //   同一 index（其余槽全占用）⇒ 验证 alloc 清 `stq_cmt` 后新占用者恰一次。
    task vec_cdq_reuse_same;
        reg [STQ_IW-1:0] s_new, head;
        integer k, si;
        begin
            vec_begin("cdq_slot_reuse_same_index");
            do_reset();
            @(negedge clk);
            alloc_valid = 4'b1111;
            alloc_rob = {6'd3, 6'd2, 6'd1, 6'd0};
            for (k = 0; k < 8; k = k + 1) @(posedge clk);   // 32 项填满
            @(negedge clk); alloc_valid = 0; #1;
            for (si = 0; si < STQ_N; si = si + 1)
                exe_store(si[STQ_IW-1:0], si[ROBW-1:0],
                          32'h0000_0500 + (si << 2), 32'hA000_0000 | si, 3'd2, 32'h0);
            //   队头 store 合法提交/排空（level 只拉在它自己的拍）
            @(negedge clk);
            head = u_lsq.stq_head_q;
            rob_head = 6'd0;
            #1;
            take_once(head);
            repeat (4) @(posedge clk);
            chk(n_wr === 1, "head store drained once");
            chk((n_wr >= 1) && (wr_d[0] === (32'hA000_0000 | head)), "head store data");
            //   alloc 必然复用该 index（其余 31 槽仍占用）
            alloc_store(6'd40, s_new);
            chk(s_new === head, "same index reused after reclaim");
            exe_store(s_new, 6'd40, 32'h0000_0600, 32'hB000_0000 | head, 3'd2, 32'h0);
            repeat (3) @(posedge clk);
            chk(n_wr === 1, "reused slot not taken before its commit");
            @(negedge clk); rob_head = 6'd40; #1;
            take_once(s_new);
            repeat (4) @(posedge clk);
            chk(n_wr === 2, "reused slot enqueued exactly once");
            chk((n_wr >= 2) && (wr_d[1] === (32'hB000_0000 | head)), "reused slot new data");
            @(negedge clk); mem_req_ready = 0; #1;
            vec_end();
        end
    endtask

    task vec_cdq_flush_push;
        reg [STQ_IW-1:0] s0;
        integer k;
        begin
            vec_begin("cdq_flush_push_once");
            do_reset();
            alloc_store(6'd30, s0);
            exe_store(s0, 6'd30, 32'h0000_0600, 32'hCAFE_BABE, 3'd2, 32'h0);
            set_head(6'd30);
            @(negedge clk);
            mem_req_ready = 1;
            flush_all = 1; dr_valid = 4'b0001; dr_idx = s0;
            @(posedge clk); #1;
            @(negedge clk); flush_all = 0; dr_valid = 4'b0000; #1;
            //   控制向量：flush 同拍 push 恰一次；level 持续残拍由 defect 向量覆盖
            for (k = 0; k < 8; k = k + 1) @(posedge clk);
            @(negedge clk); mem_req_ready = 0; #1;
            chk(n_wr === 1, "flush+push drains exactly once");
            chk((n_wr >= 1) && (wr_d[0] === 32'hCAFE_BABE), "flush push data");
            chk(dr_empty_o === 1'b1, "CDQ empty after flush push");
            vec_end();
        end
    endtask

`ifdef LSQ_DATA_CTRL
    //==========================================================================
    // 6. 新接口向量（数据侧契约）
    //==========================================================================
    integer ldreq_target;
    //   等到“下一笔 load 请求已被接受”（用 n_ldreq 计数，避免两拍 load 的第二拍
    //   在 clear_pend 之前就再次发出的竞态）。
    task wait_next_req;
        begin
            ldreq_target = n_ldreq + 1;
            while (n_ldreq < ldreq_target) @(posedge clk);
            #1;
        end
    endtask

    //   6.1 真实字节/区间 + ROB 头身份
    task vec_req_bytes;
        reg [LQ_IW-1:0] sl;
        begin
            vec_begin("dc_req_bytes_head");
            do_reset();
            //   LB @ +3
            alloc_load(6'd3, sl);
            exe_load(sl, 6'd3, 32'h0000_1003, 3'd0);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd3; #1;
            wait_next_req;
            chk(pend_bm === 4'h8, "LB @+3 bmask=0x8");
            chk(pend_by === 4'd1, "LB @+3 bytes=1");
            chk(pend_rob === 6'd3, "load ROB identity");
            chk(pend_head === 1'b1, "load is ROB head");
            resp_now(32'h0000_00AB);
            //   LH @ +3（跨 4B 字，两拍）
            alloc_load(6'd4, sl);
            exe_load(sl, 6'd4, 32'h0000_2003, 3'd1);
            rob_head = 6'd4;
            wait_next_req;
            chk(pend_bm === 4'h8, "LH @+3 first beat bmask=0x8");
            chk(pend_by === 4'd1, "LH @+3 first beat bytes=1");
            resp_now(32'h0000_0000);
            wait_next_req;
            chk(pend_bm === 4'h1, "LH @+3 second beat bmask=0x1");
            chk(pend_by === 4'd1, "LH @+3 second beat bytes=1");
            chk(pend_head === 1'b1, "second beat carries head identity");
            resp_now(32'h0000_0000);
            //   LW @ +1（跨字，首拍 3 字节、次拍 1 字节）
            alloc_load(6'd5, sl);
            exe_load(sl, 6'd5, 32'h0000_3001, 3'd2);
            rob_head = 6'd5;
            wait_next_req;
            chk(pend_bm === 4'hE, "LW @+1 first beat bmask=0xE");
            chk(pend_by === 4'd3, "LW @+1 first beat bytes=3");
            resp_now(32'h0000_0000);
            wait_next_req;
            chk(pend_bm === 4'h1, "LW @+1 second beat bmask=0x1");
            chk(pend_by === 4'd1, "LW @+1 second beat bytes=1");
            resp_now(32'h0000_0000);
            //   FLD @ 8B 对齐（两拍各 4 字节；非法 8B 非对齐仍走既有 cause 4，不暗扩）
            alloc_load(6'd6, sl);
            exe_load(sl, 6'd6, 32'h0000_4000, 3'd3);
            rob_head = 6'd6;
            wait_next_req;
            chk(pend_bm === 4'hF, "FLD beat0 bmask=0xF");
            chk(pend_by === 4'd4, "FLD beat0 bytes=4");
            resp_now(32'h0000_0000);
            wait_next_req;
            chk(pend_bm === 4'hF, "FLD beat1 bmask=0xF");
            chk(pend_by === 4'd4, "FLD beat1 bytes=4");
            resp_now(32'h0000_0000);
            vec_end();
        end
    endtask

    //   6.2 load cause 5/13 + legacy err
    task vec_load_cause;
        reg [LQ_IW-1:0] sl;
        begin
            vec_begin("dc_load_cause_af_pf");
            do_reset();
            //   AF = 5
            alloc_load(6'd10, sl);
            exe_load(sl, 6'd10, 32'h0000_5000, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd10; #1;
            wait_next_req;
            resp_err_cause(4'd5, 32'hFFFF_FFFF, 1'b0);
            @(posedge clk); #1;
            chk(n_exc === 1, "AF raises exception");
            chk(last_exc_cause === 4'd5, "AF cause = 5");
            chk(last_exc_tval === 32'h0000_5000, "AF mtval = VA");
            chk(n_wb === 1 && last_wb_di === 1'b0 && last_wb_df === 1'b0,
                "AF completes without register writeback");
            //   PF = 13
            alloc_load(6'd11, sl);
            exe_load(sl, 6'd11, 32'h0000_5100, 3'd2);
            rob_head = 6'd11;
            wait_next_req;
            resp_err_cause(4'd13, 32'h0000_0000, 1'b0);
            @(posedge clk); #1;
            chk(n_exc === 2, "PF raises exception");
            chk(last_exc_cause === 4'd13, "PF cause = 13");
            chk(last_exc_tval === 32'h0000_5100, "PF mtval = VA");
            //   旧兼容：err=1 & cause=0 ⇒ 13
            alloc_load(6'd12, sl);
            exe_load(sl, 6'd12, 32'h0000_5200, 3'd2);
            rob_head = 6'd12;
            wait_next_req;
            @(negedge clk);
            mem_rsp_valid_r = 1; mem_rsp_rdata_r = 32'h0; mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 1; mem_rsp_cause = 4'd0;
            mem_rsp_defer = 0; mem_rsp_side = 0;
            @(posedge clk); #1;
            @(negedge clk); mem_rsp_valid_r = 0; mem_rsp_err_r = 0;
            @(posedge clk); #1;
            chk(last_exc_cause === 4'd13, "legacy err=1 cause=0 => 13");
            chk(u_lsq.proto_err_q === 1'b0, "legal causes do not set proto_err");
            vec_end();
        end
    endtask

    //   6.3 非法/未知 active 字段 fail-closed
    task vec_illegal;
        reg [LQ_IW-1:0] sl;
        begin
            vec_begin("dc_illegal_active");
            do_reset();
            //   已知但非法 cause=6 ⇒ 5 + 粘滞，不得正常写回
            alloc_load(6'd13, sl);
            exe_load(sl, 6'd13, 32'h0000_5300, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd13; #1;
            wait_next_req;
            resp_err_cause(4'd6, 32'h1122_3344, 1'b0);
            @(posedge clk); #1;
            chk(n_exc === 1, "illegal active cause rejected");
            chk(last_exc_cause === 4'd5, "illegal active cause -> access fault 5");
            chk(last_wb_di === 1'b0, "no normal writeback for illegal active");
            chk(u_lsq.proto_err_q === 1'b1, "proto_err sticky on illegal active");
            //   未知 active（defer 为 X）⇒ 同样 fail-closed
            do_reset();
            alloc_load(6'd14, sl);
            exe_load(sl, 6'd14, 32'h0000_5400, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd14; #1;
            wait_next_req;
            @(negedge clk);
            mem_rsp_valid_r = 1; mem_rsp_rdata_r = 32'h0; mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 0; mem_rsp_cause = 4'd0;
            mem_rsp_defer = 1'bx; mem_rsp_side = 1'b0;
            @(posedge clk); #1;
            @(negedge clk); mem_rsp_valid_r = 0; mem_rsp_defer = 0;
            @(posedge clk); #1;
            chk(n_exc === 1, "unknown active defer rejected");
            chk(last_exc_cause === 4'd5, "unknown active defer -> access fault 5");
            chk(u_lsq.proto_err_q === 1'b1, "proto_err sticky on unknown active");
            vec_end();
        end
    endtask

    //   6.4 store 翻译 cause 7/15 + 真实字节
    task vec_store_xlate;
        reg [STQ_IW-1:0] s0, s1, s2;
        integer k;
        begin
            vec_begin("dc_store_xlate_bytes_cause");
            do_reset();
            //   8B store：E1 预翻译请求 bmask8=0xFF, bytes=8, xpg=0
            alloc_store(6'd40, s0);
            set_head(6'd40 - 6'd8);          // 窗口外：预翻译故障不判坏
            @(negedge clk); st_xlate_en = 1; st_xlate_ctx = 4'h0; #1;
            exe_store(s0, 6'd40, 32'h0000_6000, 32'hAAAA_BBBB, 3'd3, 32'hCCCC_DDDD);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 0; #1;
            for (k = 0; k < 4; k = k + 1) @(posedge clk);
            chk(xl_n >= 1, "E1 pre-translate issued");
            chk(xl_bm8_c === 8'hFF, "8B store low request bmask8=0xFF");
            chk(xl_by_c === 4'd8, "8B store bytes=8");
            chk(xl_xpg_c === 1'b0, "aligned 8B not page-crossing");
            //   4B 跨字（非跨页）store：bmask8=0x1E, bytes=4
            alloc_store(6'd41, s1);
            st_xlate_en = 1;
            exe_store(s1, 6'd41, 32'h0000_6105, 32'h0102_0304, 3'd2, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 0; #1;
            for (k = 0; k < 4; k = k + 1) @(posedge clk);
            chk(xl_bm8_c === 8'h1E, "SW @+1 non-cross bmask8=0x1E");
            chk(xl_by_c === 4'd4, "SW @+1 bytes=4");
            //   跨页 SH：低字请求 bmask8=0x08/bytes=1/xpg=1；高字独立 VA=0x1000
            alloc_store(6'd42, s2);
            st_xlate_en = 1; xl_fault = 0;
            exe_store(s2, 6'd42, 32'h0000_0FFF, 32'h0000_0000, 3'd1, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 0; #1;
            for (k = 0; k < 4; k = k + 1) @(posedge clk);
            chk(xl_bm8_c === 8'h08, "SH @0xFFF low bmask8=0x08");
            chk(xl_by_c === 4'd1, "SH @0xFFF low bytes=1");
            chk(xl_xpg_c === 1'b1, "SH @0xFFF xpg=1");
            //   推进到提交窗：高字独立翻译请求（VA 高字基址）
            @(negedge clk); rob_head = 6'd42; st_xlate_en = 1; #1;
            for (k = 0; k < 8; k = k + 1) @(posedge clk);
            chk(xl_n >= 4, "high page request issued separately");
            chk(xl_va_c === 32'h0000_1000, "high part VA = (VA&~3)+4");
            chk(xl_bm8_c === 8'h01, "high part bmask8=0x01 (actual byte)");
            chk(xl_by_c === 4'd1, "high part bytes=1");
            vec_end();
        end
    endtask

    //   6.5 store 翻译故障 cause 7/15（精确、无写）
    task vec_store_fault;
        reg [STQ_IW-1:0] s0;
        integer k;
        begin
            vec_begin("dc_store_fault_cause");
            do_reset();
            //   AF 7
            alloc_store(6'd50, s0);
            set_head(6'd50 - 6'd8);
            @(negedge clk); st_xlate_en = 1; xl_fault = 1; xl_cause = 4'd7; #1;
            exe_store(s0, 6'd50, 32'h0000_7000, 32'h0, 3'd2, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 1; #1;
            @(negedge clk); rob_head = 6'd50; #1;   // 进入提交窗
            for (k = 0; k < 12; k = k + 1) @(posedge clk);
            chk(n_exc === 1, "store AF precise exception");
            chk(last_exc_cause === 4'd7, "store AF cause = 7");
            chk(last_exc_tval === 32'h0000_7000, "store AF mtval = VA");
            chk(n_wr === 0, "faulted store never drained");
            chk(u_lsq.proto_err_q === 1'b0, "legal store AF not proto error");
            //   PF 15
            do_reset();
            alloc_store(6'd51, s0);
            set_head(6'd51 - 6'd8);
            @(negedge clk); st_xlate_en = 1; xl_fault = 1; xl_cause = 4'd15; #1;
            exe_store(s0, 6'd51, 32'h0000_7100, 32'h0, 3'd2, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 1; #1;
            @(negedge clk); rob_head = 6'd51; #1;
            for (k = 0; k < 12; k = k + 1) @(posedge clk);
            chk(n_exc === 1, "store PF precise exception");
            chk(last_exc_cause === 4'd15, "store PF cause = 15");
            chk(u_lsq.proto_err_q === 1'b0, "legal store PF not proto error");
            //   旧兼容：fault=1 & cause=0 ⇒ 15
            do_reset();
            alloc_store(6'd52, s0);
            set_head(6'd52 - 6'd8);
            @(negedge clk); st_xlate_en = 1; xl_fault = 1; xl_cause = 4'd0; #1;
            exe_store(s0, 6'd52, 32'h0000_7200, 32'h0, 3'd2, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 1; #1;
            @(negedge clk); rob_head = 6'd52; #1;
            for (k = 0; k < 12; k = k + 1) @(posedge clk);
            chk(n_exc === 1, "legacy store fault precise exception");
            chk(last_exc_cause === 4'd15, "legacy fault=1 cause=0 => 15");
            chk(u_lsq.proto_err_q === 1'b0, "legacy store fault not proto error");
            //   非法 active cause=5（store 只允许 0/7/15）⇒ fail-closed 7 + 粘滞
            do_reset();
            alloc_store(6'd53, s0);
            set_head(6'd53 - 6'd8);
            @(negedge clk); st_xlate_en = 1; xl_fault = 0; xl_cause = 4'd5; #1;
            exe_store(s0, 6'd53, 32'h0000_7300, 32'h0, 3'd2, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 1; #1;
            @(negedge clk); rob_head = 6'd53; #1;
            for (k = 0; k < 12; k = k + 1) @(posedge clk);
            chk(n_exc === 1, "illegal store cause raises exception");
            chk(last_exc_cause === 4'd7, "illegal store cause -> 7");
            chk(u_lsq.proto_err_q === 1'b1, "illegal store cause proto sticky");
            chk(n_wr === 0, "illegal store cause never drained");
            //   done 拍 cause 为 X（未知 active）⇒ fail-closed 7 + 粘滞，不得当正常 PA
            do_reset();
            alloc_store(6'd54, s0);
            set_head(6'd54 - 6'd8);
            @(negedge clk); st_xlate_en = 1; xl_fault = 0; xl_cause = 4'bxxxx; #1;
            exe_store(s0, 6'd54, 32'h0000_7400, 32'h0, 3'd2, 32'h0);
            @(posedge clk); #1;
            @(negedge clk); st_xlate_en = 1; #1;
            @(negedge clk); rob_head = 6'd54; #1;
            for (k = 0; k < 12; k = k + 1) @(posedge clk);
            chk(n_exc === 1, "unknown store cause raises exception");
            chk(last_exc_cause === 4'd7, "unknown store cause -> 7");
            chk(u_lsq.proto_err_q === 1'b1, "unknown store cause proto sticky");
            chk(n_wr === 0, "unknown store cause never drained");
            vec_end();
        end
    endtask

    //   6.6 defer：非 head 设备 load 不 done/wb、不阻老普通 load；变 head 恰一次
    task vec_defer;
        reg [LQ_IW-1:0] s_dev, s_old, s_yng;
        integer k;
        begin
            vec_begin("dc_defer_nonhead_head_once");
            do_reset();
            //   程序序：老普通 load(rob=20) -> 设备 load(rob=21) -> 年轻普通 load(rob=22)
            alloc_load(6'd20, s_old);
            alloc_load(6'd21, s_dev);
            alloc_load(6'd22, s_yng);
            //   只执行设备 load（非 head）→ 请求 → defer
            exe_load(s_dev, 6'd21, 32'h0000_8000, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd20; #1;
            wait_next_req;
            chk(pend_head === 1'b0, "device load is non-head at accept");
            resp_defer();
            @(posedge clk); #1;
            chk(n_wb === 0 && n_exc === 0, "defer is not done/wb/exc");
            //   年轻普通 load 仍可服务（不被 held 设备 load 串行）
            exe_load(s_yng, 6'd22, 32'h0000_8100, 3'd2);
            wait_next_req;
            chk(pend_tag === {{(TAG_W-LQ_IW){1'b0}}, s_yng}, "young normal load selected");
            resp_now(mword(32'h0000_8100));
            @(posedge clk); #1;
            chk(n_wb === 1 && last_wb_di === 1'b1, "young normal load writes back");
            //   老普通 load 仍可服务
            exe_load(s_old, 6'd20, 32'h0000_8200, 3'd2);
            wait_next_req;
            resp_now(mword(32'h0000_8200));
            @(posedge clk); #1;
            chk(n_wb === 2, "older normal load writes back");
            //   设备 load 变 head：恰一次重发，is_head=1
            @(negedge clk); rob_head = 6'd21; #1;
            wait_next_req;
            chk(pend_tag === {{(TAG_W-LQ_IW){1'b0}}, s_dev}, "held device load re-selected");
            chk(pend_head === 1'b1, "re-selected only when it is ROB head");
            chk(pend_bm === 4'hF && pend_by === 4'd4, "device word bytes/mask");
            resp_now(32'h5A5A_1234);
            @(posedge clk); #1;
            chk(n_wb === 3 && last_wb_data === 32'h5A5A_1234, "device load writes once");
            //   不再发第二次
            for (k = 0; k < 6; k = k + 1) @(posedge clk);
            chk(n_ldreq === 4, "exactly four load requests total");
            vec_end();
        end
    endtask

    //   6.7 side token：WB 与 retire 之间不断档
    task vec_side;
        reg [LQ_IW-1:0] sl;
        integer k;
        begin
            vec_begin("dc_side_token_retire");
            do_reset();
            alloc_load(6'd60, sl);
            exe_load(sl, 6'd60, 32'h0000_9000, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd60; #1;
            wait_next_req;
            chk(pend_head === 1'b1, "side load is head");
            //   带 side 的正常响应
            @(negedge clk);
            mem_rsp_valid_r = 1; mem_rsp_rdata_r = 32'hFEED_F00D; mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 0; mem_rsp_cause = 4'd0; mem_rsp_defer = 0; mem_rsp_side = 1;
            @(posedge clk); #1;
            chk(n_side_issue === 1, "side_issue pulses");
            chk(side_issue_rob_c === 6'd60, "side_issue_rob identity");
            chk(side_pending === 1'b1, "side_pending set in response cycle");
            @(negedge clk); mem_rsp_valid_r = 0; mem_rsp_side = 0;
            //   WB 后、commit 前：token 必须保持
            for (k = 0; k < 5; k = k + 1) @(posedge clk);
            chk(n_wb === 1 && last_wb_data === 32'hFEED_F00D, "side load WB once");
            chk(side_pending === 1'b1 && side_pending_rob === 6'd60,
                "side token survives WB->retire gap");
            //   提交释放 → token 落 0
            @(negedge clk); cmt_n = 3'd1; #1;
            @(posedge clk); #1;
            @(negedge clk); cmt_n = 3'd0; #1;
            @(posedge clk); #1;
            chk(side_pending === 1'b0, "side token drops at commit release");
            vec_end();
        end
    endtask

    //   6.8 partial squash 保更老 side owner + 年轻 kill tag
    task vec_squash_side;
        reg [LQ_IW-1:0] s_side, s_yng;
        integer k;
        begin
            vec_begin("dc_squash_side_owner");
            do_reset();
            alloc_load(6'd30, s_side);
            alloc_load(6'd31, s_yng);
            exe_load(s_side, 6'd30, 32'h0000_A000, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd30; #1;
            wait_next_req;
            @(negedge clk);
            mem_rsp_valid_r = 1; mem_rsp_rdata_r = 32'h0; mem_rsp_tag_r = pend_tag;
            mem_rsp_err_r = 0; mem_rsp_cause = 4'd0; mem_rsp_defer = 0; mem_rsp_side = 1;
            @(posedge clk); #1;
            @(negedge clk); mem_rsp_valid_r = 0; mem_rsp_side = 0;
            //   年轻 load 在途（未响应）
            exe_load(s_yng, 6'd31, 32'h0000_A100, 3'd2);
            wait_next_req;
            chk(side_pending === 1'b1, "older side token present before squash");
            //   squash 点 = rob 72：老 side(70) 保留，年轻(71) 被杀
            @(negedge clk); rob_head = 6'd30; squash_idx = 6'd30; squash = 1; #1;
            @(posedge clk); #1;
            @(negedge clk); squash = 0; #1;
            chk(side_pending === 1'b1 && side_pending_rob === 6'd30,
                "partial squash keeps older IO owner");
            chk(kill_tags_c[s_yng] === 1'b1, "young in-flight load kill tag");
            chk(kill_tags_c[s_side] === 1'b0, "older side load not killed");
            vec_end();
        end
    endtask

    //   6.9 flush 拍不发新 load；同拍响应不产生 wb/exc
    task vec_flush;
        reg [LQ_IW-1:0] sl;
        integer req_before;
        begin
            vec_begin("dc_flush_no_new_load");
            do_reset();
            alloc_load(6'd40, sl);
            exe_load(sl, 6'd40, 32'h0000_B000, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd40; #1;
            wait_next_req;                    // 已有一笔在途
            req_before = n_ldreq;
            //   同拍 flush + 一个匹配响应：不得产生 wb/exc，也不得发新 load 请求
            @(negedge clk);
            flush_all = 1; mem_rsp_valid_r = 1; mem_rsp_rdata_r = 32'hBAD0_BAD0;
            mem_rsp_tag_r = pend_tag; mem_rsp_err_r = 0; mem_rsp_cause = 4'd0;
            mem_rsp_defer = 0; mem_rsp_side = 0;
            @(posedge clk); #1;
            chk(n_ldreq === req_before, "no new load request in flush cycle");
            @(negedge clk); flush_all = 0; mem_rsp_valid_r = 0; #1;
            @(posedge clk); #1;
            chk(n_wb === 0 && n_exc === 0, "flush cycle response suppressed");
            vec_end();
        end
    endtask

    //   6.9b squash 与响应同拍：响应已被 LSQ 消费 ⇒ 不得再置 kill tag
    task vec_squash_rsp_same;
        reg [LQ_IW-1:0] sl;
        begin
            vec_begin("dc_squash_rsp_same_cycle");
            do_reset();
            alloc_load(6'd31, sl);
            exe_load(sl, 6'd31, 32'h0000_A200, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd30; #1;
            wait_next_req;
            //   同拍：响应（匹配 tag）+ squash 点 30（该 load 更年轻）
            @(negedge clk);
            mem_rsp_valid_r = 1; mem_rsp_rdata_r = 32'hCAFE_1234;
            mem_rsp_tag_r = pend_tag; mem_rsp_err_r = 0; mem_rsp_cause = 4'd0;
            mem_rsp_defer = 0; mem_rsp_side = 0;
            squash_idx = 6'd30; squash = 1;
            @(posedge clk); #1;
            @(negedge clk); squash = 0; mem_rsp_valid_r = 0; #1;
            chk(kill_tags_c === {OUT_N{1'b0}}, "same-cycle rsp not marked for kill");
            chk(n_wb === 1, "same-cycle rsp still completes");
            chk(n_exc === 0, "same-cycle rsp no exception");
            vec_end();
        end
    endtask

    //   6.10 跨 flush 响应代际（Top kill/drain 合同）
    task vec_flush_gen;
        reg [LQ_IW-1:0] s0;
        integer req_before;
        begin
            vec_begin("dc_flush_rsp_generation");
            do_reset();
            //   旧 load 取到槽 0，发出但不回；flush 清掉（Top 合同：旧完成永不再呈现）
            alloc_load(6'd50, s0);
            exe_load(s0, 6'd50, 32'h0000_C000, 3'd2);
            @(negedge clk); mem_req_ready = 1; rob_head = 6'd50; #1;
            wait_next_req;                    // 旧 tag 记在 pend_tag
            @(negedge clk); flush_all = 1; #1;
            @(posedge clk); #1;
            @(negedge clk); flush_all = 0; #1;
            //   新 load 复用同 tag；Top 丢弃旧响应，只回新响应
            alloc_load(6'd0, s0);
            exe_load(s0, 6'd0, 32'h0000_C100, 3'd2);
            rob_head = 6'd0;
            wait_next_req;
            chk(pend_tag === {{(TAG_W-LQ_IW){1'b0}}, s0}, "new load reuses tag");
            resp_now(32'h1357_9BDF);
            @(posedge clk); #1;
            chk(n_wb === 1 && last_wb_data === 32'h1357_9BDF,
                "contract-honoring Top: new slot gets its own data");
            chk(n_exc === 0, "no spurious exception across flush");
            vec_end();
        end
    endtask
`endif

    //==========================================================================
    // 7. 主序列
    //==========================================================================
    integer plus_stale;
    initial begin
        g_total = 0; g_nonzero = 0; g_checks = 0; g_fails = 0; g_defect = 0; g_xz = 0;

        vec_cdq_level_once();
        vec_cdq_level_after_drain();
        vec_cdq_reuse();
        vec_cdq_reuse_same();
        vec_cdq_flush_push();

`ifdef LSQ_DATA_CTRL
        plus_stale = 0;
        if ($test$plusargs("DC_STALE_PROBE")) begin
            //   **真实端口时序反证**：故意违反 Top “flush 后丢弃旧完成”的合同 ——
            //   旧 uncached 完成在新 load 复用同一 tag 后送达，LSQ 单靠 tag/slot 有效位
            //   无法区分代际 ⇒ 必须接受为**新槽**的数据。这证明 Top 的 kill+drain 合同
            //   （旧完成彻底消费/清完再接受新请求）是必要的，不是靠“AD_WAIT 首拍不采”。
            //   本模式不打印 PASS/摘要锚点。
            reg [TAG_W-1:0] old_tag;
            reg [31:0] old_data, new_data;
            reg [LQ_IW-1:0] pslot;
            begin
                do_reset();
                old_data = 32'hDEAD_0001;
                new_data = 32'h1234_5678;
                alloc_load(6'd1, pslot);
                exe_load(pslot, 6'd1, 32'h0000_D000, 3'd2);
                @(negedge clk); mem_req_ready = 1; rob_head = 6'd1; #1;
                wait_next_req;
                old_tag = pend_tag;
                //   旧 load 在途未回；flush（Top 本应 kill/drain 旧完成）
                @(negedge clk); flush_all = 1; #1;
                @(posedge clk); #1;
                @(negedge clk); flush_all = 0; #1;
                //   新 load 复用同 tag；Top 本应丢弃旧完成后再接受新请求
                alloc_load(6'd2, pslot);
                exe_load(pslot, 6'd2, 32'h0000_D100, 3'd2);
                rob_head = 6'd2;
                wait_next_req;
                //   故意送入旧响应（tag 相同）——若 LSQ 接受为新槽数据，即证明合同必要
                @(negedge clk);
                mem_rsp_valid_r = 1; mem_rsp_rdata_r = old_data;
                mem_rsp_tag_r = old_tag; mem_rsp_err_r = 0; mem_rsp_cause = 4'd0;
                mem_rsp_defer = 0; mem_rsp_side = 0;
                @(posedge clk); #1;
                @(negedge clk); mem_rsp_valid_r = 0;
                if ((n_wb === 1) && (last_wb_data === old_data)) begin
                    $display("DC_STALE_PROBE_CONFIRMED");
                end else begin
                    $display("DC_STALE_PROBE_FAIL observed wb=%0d data=%08x", n_wb, last_wb_data);
                end
                $finish;
            end
        end
        vec_req_bytes();
        vec_load_cause();
        vec_illegal();
        vec_store_xlate();
        vec_store_fault();
        vec_defer();
        vec_side();
        vec_squash_side();
        vec_flush();
        vec_flush_gen();
        vec_squash_rsp_same();
`endif

        $display("DC_VECTORS total=%0d nonzero=%0d checks=%0d fails=%0d defect=%0d xz=%0d",
                 g_total, g_nonzero, g_checks, g_fails, g_defect, g_xz);
        if (g_fails === 0 && g_defect === 0)
            $display("FUNCTIONAL_DATA_CONTROL: PASS");
        else
            $display("FUNCTIONAL_DATA_CONTROL: FAIL internal_checks");
        $finish;
    end
endmodule
