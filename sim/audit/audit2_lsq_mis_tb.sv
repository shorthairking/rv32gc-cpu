//==============================================================================
// audit2_lsq_mis_tb.sv —— AUDIT2 只读审计夹具：非对齐 store 的落地字节检查
//------------------------------------------------------------------------------
// 目的（只做观测，不改任何产品 RTL）：
//   用与 sim/unit/tb_back2_lsq_fwd.sv 相同的 LSQ 直驱法，构造一条 **4 B 非对齐 store**
//   （sw @ base+1），并逐字节检查夹具存储映像 `mem[]` 的落地结果。
//   ISA 口径：非对齐访问要么由硬件正确完成，要么抛地址非对齐异常（二选一，不允许"部分
//   落地且不报异常"）。本核 lsq_simple.v:1007 的 `st_mis_w` 只覆盖 `exe_size==3`（8 B），
//   故 ≤4 B 非对齐 store 走"硬件完成"分支 ⇒ 期望全部 4 字节落地。
//
// 运行（仓库根）：
//   iverilog -g2012 -I . -o /tmp/audit2_lsq_mis.vvp \
//       rtl/back2/lsq_simple.v fpga/scratch/audit2_lsq_mis_tb.sv && vvp /tmp/audit2_lsq_mis.vvp
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module audit2_lsq_mis_tb;
    localparam integer STQ_N = `BACK2_STQ_N;
    localparam integer STQ_IW= `BACK2_STQ_IDX_W;
    localparam integer OUT_N = `BACK2_MEM_OUT_N;
    localparam integer TAG_W = `BACK2_MEM_TAG_W;
    localparam integer ROBW  = `BACK2_ROB_IDX_W;
    localparam integer PDW_I = `BACK2_PREG_I_W;
    localparam integer PDW_F = `BACK2_PREG_F_W;
    localparam integer LQ_IW = `BACK2_LQ_IDX_W;

    reg clk = 1'b0;  always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg              flush_all = 0, squash = 0;
    reg [ROBW-1:0]   squash_idx = 0, rob_head = 0;
    reg [3:0]        alloc_valid = 0;
    reg [4*ROBW-1:0] alloc_rob = 0;
    reg [ROBW-1:0]   iss_rob = 0;
    reg [2:0]        cmt_n = 0;
    wire             alloc_ok;
    reg [3:0]        lalloc_valid = 0;
    reg [4*ROBW-1:0] lalloc_rob = 0;
    wire             lalloc_ok;
    wire [4*LQ_IW-1:0] lalloc_idx;
    reg [LQ_IW-1:0]  exe_lq_idx = 0;
    wire [4*STQ_IW-1:0] alloc_idx;
    reg              exe_valid = 0, exe_is_store = 0, exe_is_fp = 0;
    reg [ROBW-1:0]   exe_rob = 0;
    reg [`BACK2_EPOCH_W-1:0] exe_epoch = 0;
    reg [31:0]       exe_addr = 0, exe_wdata = 0, exe_wdata_hi = 0;
    reg [2:0]        exe_size = 0;
    reg              exe_unsign = 0, exe_dst_i = 0, exe_dst_f = 0;
    reg [PDW_I-1:0]  exe_pdest_i = 0;
    reg [PDW_F-1:0]  exe_pdest_f = 0;
    reg [STQ_IW-1:0] exe_stq_idx = 0;
    wire             iss_ok, dr_empty_o, dr_room_ok;
    reg [3:0]        dr_valid = 0;
    reg [4*STQ_IW-1:0] dr_idx = 0;
    wire             mem_req_valid, mem_req_wen;
    wire [31:0]      mem_req_addr, mem_req_wdata;
    wire [3:0]       mem_req_wstrb;
    wire [TAG_W-1:0] mem_req_tag;
    reg              mem_req_ready = 1;
    reg              mem_rsp_valid = 0;
    reg [31:0]       mem_rsp_rdata = 0;
    reg [TAG_W-1:0]  mem_rsp_tag = 0;
    reg              mem_rsp_err = 0;
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
    reg [3:0]        st_xlate_ctx = 4'h0;
    wire             st_xlate_valid;
    wire [31:0]      st_xlate_va;
    wire [STQ_IW-1:0] st_xlate_idx;
    wire [3:0]       st_xlate_ctx_o;
    reg              st_xlate_ready = 0;
    reg              st_xlate_done = 0;
    reg [31:0]       st_xlate_pa = 0;
    reg              st_xlate_fault = 0;
    wire [7:0]       stq_cnt_o;
    wire [31:0]      cnt_load_o, cnt_store_o, cnt_fwd_o, cnt_stq_stall_o;

    lsq_simple #(.DBG(0)) u_lsq (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .squash(squash),
        .squash_idx(squash_idx), .rob_head(rob_head),
        .alloc_valid(alloc_valid), .alloc_rob(alloc_rob),
        .alloc_ok(alloc_ok), .alloc_idx(alloc_idx),
        .lalloc_valid(lalloc_valid), .lalloc_rob(lalloc_rob),
        .lalloc_ok(lalloc_ok), .lalloc_idx(lalloc_idx),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch), .exe_addr(exe_addr), .exe_wdata(exe_wdata),
        .exe_wdata_hi(exe_wdata_hi),
        .exe_size(exe_size), .exe_unsign(exe_unsign), .exe_dst_i(exe_dst_i), .exe_dst_f(exe_dst_f),
        .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f), .exe_stq_idx(exe_stq_idx),
        .exe_lq_idx(exe_lq_idx),
        .iss_rob(iss_rob), .iss_ok(iss_ok),
        .dr_empty_o(dr_empty_o),
        .dr_valid(dr_valid), .dr_idx(dr_idx), .dr_room_ok(dr_room_ok),
        .cmt_n(cmt_n),
        .mem_req_valid(mem_req_valid), .mem_req_wen(mem_req_wen), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb), .mem_req_tag(mem_req_tag),
        .mem_req_ready(mem_req_ready), .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_tag(mem_rsp_tag), .mem_rsp_err(mem_rsp_err),
        .exc_valid_o(exc_valid_o), .exc_rob_o(exc_rob_o), .exc_cause_o(exc_cause_o),
        .exc_tval_o(exc_tval_o),
        .wb_valid(wb_valid), .wb_rob(wb_rob), .wb_epoch(wb_epoch), .wb_dst_i(wb_dst_i),
        .wb_dst_f(wb_dst_f), .wb_pdest_i(wb_pdest_i), .wb_pdest_f(wb_pdest_f), .wb_data(wb_data),
        .wb_data_hi(wb_data_hi), .wb_f64(wb_f64),
        .st_done_valid(st_done_valid), .st_done_rob(st_done_rob), .st_done_epoch(st_done_epoch),
        .st_xlate_en(st_xlate_en), .st_xlate_ctx(st_xlate_ctx),
        .st_xlate_valid(st_xlate_valid), .st_xlate_va(st_xlate_va), .st_xlate_idx(st_xlate_idx),
        .st_xlate_ctx_o(st_xlate_ctx_o),
        .st_xlate_ready(st_xlate_ready), .st_xlate_done(st_xlate_done),
        .st_xlate_pa(st_xlate_pa), .st_xlate_fault(st_xlate_fault),
        .stq_cnt_o(stq_cnt_o), .cnt_load_o(cnt_load_o), .cnt_store_o(cnt_store_o),
        .cnt_fwd_o(cnt_fwd_o), .cnt_stq_stall_o(cnt_stq_stall_o)
    );

    // ---- 夹具存储映像（与 l1d 口径一致：wstrb 只作用于 mem_req_addr[15:2] 这个对齐字）----
    localparam integer MEMW = 16384;
    reg [31:0] mem [0:MEMW-1];
    wire [13:0] midx = mem_req_addr[15:2];
    integer mi;
    task set_mem(input [31:0] a, input [31:0] d); begin mem[a[15:2]] = d; end endtask

    // 观测：每一笔 store 请求（addr/wdata/wstrb）打印出来
    always @(posedge clk) begin
        if (rst_n && mem_req_valid && mem_req_wen)
            $display("[store-req] addr=0x%08x wdata=0x%08x wstrb=%b", mem_req_addr, mem_req_wdata, mem_req_wstrb);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (mi = 0; mi < MEMW; mi = mi + 1) mem[mi] = 32'h0;
        end else begin
            mem_rsp_valid <= mem_req_valid & mem_req_ready & ~mem_req_wen;
            mem_rsp_tag   <= mem_req_tag;
            mem_rsp_rdata <= mem[midx];
            if (mem_req_valid & mem_req_ready & mem_req_wen) begin
                if (mem_req_wstrb[0]) mem[midx][7:0]   <= mem_req_wdata[7:0];
                if (mem_req_wstrb[1]) mem[midx][15:8]  <= mem_req_wdata[15:8];
                if (mem_req_wstrb[2]) mem[midx][23:16] <= mem_req_wdata[23:16];
                if (mem_req_wstrb[3]) mem[midx][31:24] <= mem_req_wdata[31:24];
            end
        end
    end

    // ---- store 入队并 E1（同 tb_back2_lsq_fwd.sv 的 st_issue）----
    task st_issue(input [ROBW-1:0] rob, input [31:0] a, input [31:0] d, input [2:0] sz,
                  output [STQ_IW-1:0] slot_o);
        reg [STQ_IW-1:0] slot;
        begin
            @(negedge clk);
            alloc_valid = 4'h1; exe_valid = 1'b0;
            alloc_rob[0*ROBW +: ROBW] = rob;
            iss_rob = rob;
            slot = alloc_idx[0*STQ_IW +: STQ_IW];
            slot_o = slot;
            @(posedge clk);
            @(negedge clk);
            alloc_valid = 4'h0;
            exe_valid = 1'b1; exe_is_store = 1'b1; exe_stq_idx = slot;
            exe_rob = rob; exe_addr = a; exe_wdata = d; exe_size = sz;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0;
        end
    endtask

    task drain_store(input [STQ_IW-1:0] slot);
        integer w;
        begin
            @(negedge clk); dr_valid = 4'h1; dr_idx = {3'b0, slot};
            @(posedge clk);
            @(negedge clk); dr_valid = 4'h0;
            for (w = 0; w < 6; w = w + 1) @(posedge clk);
            @(negedge clk);
        end
    endtask

    reg [STQ_IW-1:0] s0;
    integer n_fail = 0;
    task chk(input cond, input [8*80-1:0] nm);
        begin
            if (cond !== 1'b1) begin n_fail = n_fail + 1; $display("FAIL[audit2-lsq]: %0s", nm); end
            else $display("PASS[audit2-lsq]: %0s", nm);
        end
    endtask
    task rd(input [31:0] a, output [31:0] d); begin d = mem[a[15:2]]; end endtask

    reg [31:0] w0, w1;
    initial begin
        $display("== AUDIT2 misaligned-store landing check ==");
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        rob_head = 6'd0; st_xlate_en = 1'b0;

        // A: aligned sw control
        set_mem(32'h8000_2000, 32'h1111_1111);
        st_issue(6'd1, 32'h8000_2000, 32'hDEAD_BEEF, 3'd2, s0);
        drain_store(s0);
        rd(32'h8000_2000, w0);
        $display("A aligned sw: mem[0x2000]=0x%08x (ISA exp 0xdeadbeef)", w0);
        chk(w0 === 32'hDEAD_BEEF, "A aligned sw all-4-bytes landed");

        // B: 4B misaligned sw @ base+1
        set_mem(32'h8000_1000, 32'h1122_3344);
        set_mem(32'h8000_1004, 32'h5566_7788);
        st_issue(6'd2, 32'h8000_1001, 32'hAABB_CCDD, 3'd2, s0);
        drain_store(s0);
        rd(32'h8000_1000, w0); rd(32'h8000_1004, w1);
        $display("B misaligned sw@+1: mem[0x1000]=0x%08x (ISA exp 0xbbccdd44)", w0);
        $display("B misaligned sw@+1: mem[0x1004]=0x%08x (ISA exp 0x556677aa)", w1);
        chk(w0 === 32'hBBCC_DD44, "B1 low 3 bytes landed per ISA");
        chk(w1 === 32'h5566_77AA, "B2 crossing byte @base+4 landed per ISA");
        chk(exc_valid_o !== 1'b1, "B3 no misaligned-store exception raised");

        // C: 2B misaligned sh @ base+3
        set_mem(32'h8000_3000, 32'h0102_0304);
        set_mem(32'h8000_3004, 32'h0A0B_0C0D);
        st_issue(6'd3, 32'h8000_3003, 32'h0000_7A5A, 3'd1, s0);
        drain_store(s0);
        rd(32'h8000_3000, w0); rd(32'h8000_3004, w1);
        $display("C misaligned sh@+3: mem[0x3000]=0x%08x (ISA exp 0x5a020304)", w0);
        $display("C misaligned sh@+3: mem[0x3004]=0x%08x (ISA exp 0x0a0b0c7a)", w1);
        chk(w0 === 32'h5A02_0304, "C1 low byte landed per ISA");
        chk(w1 === 32'h0A0B_0C7A, "C2 crossing byte @base+4 landed per ISA");

        if (n_fail == 0) $display("AUDIT2_LSQ_MIS: ALL-PASS");
        else             $display("AUDIT2_LSQ_MIS: FAIL n=%0d", n_fail);
        $finish;
    end

    initial begin
        #200000;
        $display("AUDIT2_LSQ_MIS: TIMEOUT");
        $fatal(1, "timeout");
    end
endmodule
