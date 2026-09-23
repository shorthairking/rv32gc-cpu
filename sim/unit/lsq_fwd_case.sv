//==============================================================================
// sim/unit/tb_back2_lsq_fwd.sv —— 2B-3 验收判据④：**访存转发覆盖用例**（LSQ 直驱）
//------------------------------------------------------------------------------
// 方法学：不经前端/重命名，直接以握手信号驱动 `lsq_simple`（2B-3 将替换为真乱序 lsq.v，
//   接口保持一致 ⇒ 本用例可原样复用于新模块），逐场景构造"更老 store + 更年轻 load"：
//     C1 字节 store → 字 load：**部分转发**（掩码 0b0001）+ 访存合并 ⇒ 字节 0 来自 store
//     C2 两个字节 store（A+0/A+1）→ 字 load：**部分重叠合并**（0b0011）
//     C3 同一字节的**两个 store**（更老 0x11 / 更年轻 0x22）→ 字节 load ⇒ 取**更年轻**者 0x22
//     C4 字 store → 同址字 load：**全转发** ⇒ 不产生访存请求（mem_req_valid 保持 0）
//     C5 地址不相交的 store → 字 load：**零转发** ⇒ 发访存且结果 = 存储器原值
//     C6 半字 store → 半字 load：掩码 0b0011 且结果取 store 数据
//   判据：每条场景都必须得到期望的 `wb_data` / `mem_req_valid`；任何超时即 FAIL（fail-closed）。
// 运行：iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/lsqf.vvp \
//         $(find rtl -name '*.v' | sort) sim/unit/tb_back2_lsq_fwd.sv && vvp /tmp/lsqf.vvp
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module tb_back2_lsq_fwd_top;
    localparam integer STQ_N = `BACK2_STQ_N;
    localparam integer STQ_IW= `BACK2_STQ_IDX_W;
    localparam integer OUT_N = `BACK2_MEM_OUT_N;
    localparam integer TAG_W = `BACK2_MEM_TAG_W;
    localparam integer ROBW  = `BACK2_ROB_IDX_W;
    localparam integer PDW_I = `BACK2_PREG_I_W;
    localparam integer PDW_F = `BACK2_PREG_F_W;

    reg clk = 1'b0;  always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg              flush_all = 0, squash = 0;
    reg [ROBW-1:0]   squash_idx = 0, rob_head = 0;
    reg [3:0]        alloc_valid = 0;
    wire             alloc_ok;
    wire [4*STQ_IW-1:0] alloc_idx;
    reg              exe_valid = 0, exe_is_store = 0, exe_is_fp = 0;
    reg [ROBW-1:0]   exe_rob = 0;
    reg [`BACK2_EPOCH_W-1:0] exe_epoch = 0;
    reg [31:0]       exe_addr = 0, exe_wdata = 0;
    reg [2:0]        exe_size = 0;
    reg              exe_unsign = 0, exe_dst_i = 0, exe_dst_f = 0;
    reg [PDW_I-1:0]  exe_pdest_i = 0;
    reg [PDW_F-1:0]  exe_pdest_f = 0;
    reg [STQ_IW-1:0] exe_stq_idx = 0;
    wire             iss_ok;
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
    wire             wb_valid;
    wire [ROBW-1:0]  wb_rob;
    wire [`BACK2_EPOCH_W-1:0] wb_epoch;
    wire             wb_dst_i, wb_dst_f;
    wire [PDW_I-1:0] wb_pdest_i;
    wire [PDW_F-1:0] wb_pdest_f;
    wire [31:0]      wb_data;
    wire             st_done_valid;
    wire [ROBW-1:0]  st_done_rob;
    wire [`BACK2_EPOCH_W-1:0] st_done_epoch;
    wire [7:0]       stq_cnt_o;
    wire [31:0]      cnt_load_o, cnt_store_o, cnt_fwd_o, cnt_stq_stall_o;

    lsq_simple #(.DBG(0)) u_lsq (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .squash(squash),
        .squash_idx(squash_idx), .rob_head(rob_head),
        .alloc_valid(alloc_valid), .alloc_ok(alloc_ok), .alloc_idx(alloc_idx),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch), .exe_addr(exe_addr), .exe_wdata(exe_wdata),
        .exe_size(exe_size), .exe_unsign(exe_unsign), .exe_dst_i(exe_dst_i), .exe_dst_f(exe_dst_f),
        .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f), .exe_stq_idx(exe_stq_idx),
        .iss_ok(iss_ok), .dr_valid(dr_valid), .dr_idx(dr_idx),
        .mem_req_valid(mem_req_valid), .mem_req_wen(mem_req_wen), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb), .mem_req_tag(mem_req_tag),
        .mem_req_ready(mem_req_ready), .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_tag(mem_rsp_tag),
        .wb_valid(wb_valid), .wb_rob(wb_rob), .wb_epoch(wb_epoch), .wb_dst_i(wb_dst_i),
        .wb_dst_f(wb_dst_f), .wb_pdest_i(wb_pdest_i), .wb_pdest_f(wb_pdest_f), .wb_data(wb_data),
        .st_done_valid(st_done_valid), .st_done_rob(st_done_rob), .st_done_epoch(st_done_epoch),
        .stq_cnt_o(stq_cnt_o), .cnt_load_o(cnt_load_o), .cnt_store_o(cnt_store_o),
        .cnt_fwd_o(cnt_fwd_o), .cnt_stq_stall_o(cnt_stq_stall_o)
    );

    integer n_chk = 0, n_fail = 0;
    task chk(input cond, input [255:0] nm);
        begin
            n_chk = n_chk + 1;
            if (!cond) begin n_fail = n_fail + 1; $display("FAIL[lsq-fwd]: %0s", nm); end
        end
    endtask

    // ---- 单条 store 入队并 E1 ----
    task st_issue(input [ROBW-1:0] rob, input [31:0] a, input [31:0] d, input [2:0] sz);
        reg [STQ_IW-1:0] slot;
        begin
            @(negedge clk);
            alloc_valid = 4'h1; exe_valid = 1'b0;
            //   ★ 槽号必须在**分配拍**采样：`alloc_idx[0]` 是空闲表的组合读，
            //     在 `alloc_valid=1` 的那一拍它指向"下一拍将被分配的槽"。
            slot = alloc_idx[0*STQ_IW +: STQ_IW];
            @(posedge clk);                       // 分配发生
            @(negedge clk);
            alloc_valid = 4'h0;
            exe_valid = 1'b1; exe_is_store = 1'b1; exe_stq_idx = slot;
            exe_rob = rob; exe_addr = a; exe_wdata = d; exe_size = sz;
            @(posedge clk);                       // E1：地址/数据/掩码入 STQ
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0;
        end
    endtask

    // ---- 单条 load 入队（E1）----
    task ld_issue(input [ROBW-1:0] rob, input [31:0] a, input [2:0] sz, input uns);
        begin
            @(negedge clk);
            exe_valid = 1'b1; exe_is_store = 1'b0; exe_rob = rob;
            exe_addr = a; exe_size = sz; exe_unsign = uns;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0;
        end
    endtask

    // ---- 等待写回（最多 12 拍）；同时若发访存请求则按要求给响应 ----
    task wait_wb(input [31:0] rdata, output [31:0] got, output integer saw_req);
        integer t;
        begin
            got = 32'h0; saw_req = 0; mem_rsp_valid = 1'b0;
            for (t = 0; t < 16; t = t + 1) begin
                @(negedge clk);
                //   ★ 修（§B3.3 ①）：一旦看到过请求就**连续**给响应（sticky），
                //     因为 LSU 的 pend_any/mem_req_ready 交错可能使请求延后 ≥2 拍。
                if (mem_req_valid) begin
                    saw_req = 1;
                    mem_rsp_valid = 1'b1; mem_rsp_tag = mem_req_tag; mem_rsp_rdata = rdata;
                end
                @(posedge clk);
                if (wb_valid) begin got = wb_data; t = 16; end
            end
            @(negedge clk); mem_rsp_valid = 1'b0;
        end
    endtask

    // ---- 驱动 store 提交排空（dr_valid/dr_idx），使其离开 STQ ----
    task drain_store(input [STQ_IW-1:0] slot);
        begin
            @(negedge clk); dr_valid = 4'h1; dr_idx = {3'b0, slot};
            @(posedge clk);
            @(negedge clk); dr_valid = 4'h0;
        end
    endtask

    reg [31:0] v;
    integer    rq;

    //   ★ 用例内层次探针（母代理 2B-3 第 3 段指令）：逐拍打印被测模块内部关键信号，
    //     用于判定三点：① store 是否真入 STQ 且 stq_av=1；② age 窗口比较；③ load 是否被拒。
    integer dbgc = 0;
    always @(posedge clk) begin
        if (rst_n && (dbgc < 46)) begin
            dbgc = dbgc + 1;
            $display("[fwd-case c=%0d] anyunk=%b issok=%b stqcnt=%0d cntst=%0d | stq0 v=%b av=%b msk=%b a=0x%08x rob=%0d | exe v=%b st=%b rob=%0d a=0x%08x sz=%0d | reqv=%b wen=%b rspv=%b wbv=%b wbd=0x%08x",
                     dbgc, u_lsq.any_unk_w, iss_ok, stq_cnt_o, cnt_store_o,
                     u_lsq.stq_v[0], u_lsq.stq_av[0], u_lsq.stq_msk[0],
                     u_lsq.stq_a[0], u_lsq.stq_rob[0],
                     exe_valid, exe_is_store, exe_rob, exe_addr, exe_size,
                     mem_req_valid, mem_req_wen, mem_rsp_valid, wb_valid, wb_data);
            $display("                pend_any=%b dr_any=%b pend_sel=%0d dr_valid=%b dr_idx=%0d rdy=%b rspv=%b wbv=%b",
                     u_lsq.pend_any, u_lsq.dr_any, u_lsq.pend_sel, dr_valid, dr_idx,
                     mem_req_ready, mem_rsp_valid, wb_valid);
        end
    end
    reg [STQ_IW-1:0] s0, s1;

    initial begin
        $display("== 2B-3 转发覆盖用例（LSQ 直驱）启动");
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        rob_head = 7'd0;

        // ---------- C1：字节 store(A) → 字 load(A)：部分转发 + 合并 ----------
        st_issue(7'd1, 32'h8000_1000, 32'h0000_00AA, 3'd0);   // sb 0xAA
        ld_issue(7'd2, 32'h8000_1000, 3'd2, 1'b0);                // lw
        wait_wb(32'h1122_3344, v, rq);
        chk(rq == 1, "C1 部分转发仍须访存");
        chk(v == 32'h1122_33AA, "C1 字节 0 来自 store（0xAA），其余来自存储器");

        // ---------- C2：两个字节 store(A+0/A+1) → 字 load：部分重叠合并 ----------
        st_issue(7'd3, 32'h8000_2000, 32'h0000_0055, 3'd0);   // sb 0x55 @+0
        st_issue(7'd4, 32'h8000_2001, 32'h0000_0066, 3'd0);   // sb 0x66 @+1
        ld_issue(7'd5, 32'h8000_2000, 3'd2, 1'b0);                // lw
        wait_wb(32'hAABB_CCDD, v, rq);
        chk(rq == 1, "C2 两个字节 store 仍须访存（部分命中）");
        chk(v == 32'hAABB_6655, "C2 字节 0/1 合并自两条 store");

        // ---------- C3：同字节两条 store（更老 0x11 / 更年轻 0x22）→ lbu ⇒ 更年轻者 ----------
        st_issue(7'd6, 32'h8000_3000, 32'h0000_0011, 3'd0);
        st_issue(7'd7, 32'h8000_3000, 32'h0000_0022, 3'd0);
        ld_issue(7'd8, 32'h8000_3000, 3'd0, 1'b1);                // lbu
        wait_wb(32'hDEAD_BEEF, v, rq);
        chk(v == 32'h0000_0022, "C3 同字节取更年轻 store 的数据");

        // ---------- C4：字 store → 同址字 load：全转发，不访存 ----------
        st_issue(7'd9, 32'h8000_4000, 32'hCAFE_F00D, 3'd2);   // sw
        ld_issue(7'd10, 32'h8000_4000, 3'd2, 1'b0);               // lw
        wait_wb(32'h0000_0000, v, rq);
        chk(rq == 0, "C4 全转发不得产生访存请求");
        chk(v == 32'hCAFE_F00D, "C4 数据来自 store");

        // ---------- C5：地址不相交 ⇒ 零转发、结果 = 存储器 ----------
        st_issue(7'd11, 32'h8000_5000, 32'hFFFF_FFFF, 3'd2);
        ld_issue(7'd12, 32'h8000_6000, 3'd2, 1'b0);
        wait_wb(32'h0BAD_F00D, v, rq);
        chk(rq == 1, "C5 无命中须访存");
        chk(v == 32'h0BAD_F00D, "C5 结果应为存储器原值");

        // ---------- C6：半字 store → 半字 load（掩码 0b0011） ----------
        st_issue(7'd13, 32'h8000_7000, 32'h0000_7A5A, 3'd1);  // sh
        ld_issue(7'd14, 32'h8000_7000, 3'd1, 1'b1);               // lhu
        wait_wb(32'h1357_2468, v, rq);
        chk(v == 32'h0000_7A5A, "C6 半字转发正确");

        // ---------- 结果 ----------
        if (n_fail == 0) begin
            $display("== 检查项合计 %0d 项全部满足（转发掩码/合并/最年轻优先/全转发不访存/无命中走访存）", n_chk);
            $display("TB_BACK2_LSQ_FWD: PASS");
        end else begin
            $display("== 检查项 %0d 项中失败 %0d 项", n_chk, n_fail);
            $display("FAIL: TB_BACK2_LSQ_FWD 判据不满足");
            $fatal(1, "TB_BACK2_LSQ_FWD 失败");
        end
        $finish;
    end

    // 全局超时兜底（fail-closed）
    initial begin
        #200000;
        $display("FAIL: TB_BACK2_LSQ_FWD 超时");
        $fatal(1, "TB_BACK2_LSQ_FWD 超时");
    end
endmodule
