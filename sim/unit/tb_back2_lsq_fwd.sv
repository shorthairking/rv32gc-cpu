//==============================================================================
// sim/unit/tb_back2_lsq_fwd.sv —— EXP-N29B：**纯等待变体**下的 LSQ 直驱覆盖用例
//------------------------------------------------------------------------------
// 方法学：不经前端/重命名，直接以握手信号驱动 `lsq_simple`，逐场景构造"更老 store +
//   更年轻 load"。★ N29B 起 `lsq_simple` **完全移除 store→load 转发**（无逐字节合并、
//   无"全转发直通"快路）：load 一律**等到它依赖的更老 store 对 L1D 真实可见**
//   （= 该 store 完成提交 + CDQ 排空 + L1D 写完成）之后才访存。
//
//   ⇒ 本夹具的**场景内存模型**必须与之一致（N12B §3 登记的"语义互斥"收口）：
//     · store 提交排空（`dr_valid`/`dr_idx` → `mem_req_valid & mem_req_wen`）**把数据按
//       `mem_req_wstrb` 写进夹具的存储映像** `mem[]`；
//     · **store 提交必须先于 load 完成**：夹具在 load 发访存之前显式驱动该更老 store 的
//       提交（`drain_store`），随后 load 读回的就是"store 字节 + 内存字节"的合并结果。
//
//   场景（与 N12B 之前**逐位同构**，只把"数据从转发来"改成"数据从落地后的存储映像来"）：
//     C1 字节 store → 字 load：1 字节覆盖 + 其余来自内存初值
//     C2 两个字节 store（A+0/A+1）→ 字 load：两字节拼接 + 其余来自内存
//     C3 同一字节的**两个 store**（更老 0x11 / 更年轻 0x22）→ 字节 load ⇒ 取**更年轻**者 0x22
//     C4 字 store → 同址字 load：**必须访存**（N29B 无直通快路）且结果 = 落地值
//     C5 地址不相交的 store → 字 load：**无依赖 ⇒ 不等待**，结果 = 存储器初值
//     C6 半字 store → 半字 load：结果取落地后的半字
//   判据：每条场景都必须得到期望的 `wb_data` / `mem_req_valid`（load 请求笔数）；
//         任何超时即 FAIL（fail-closed）。
//
//   ★ 数据判据（写回值）与 N12B 之前的**参考逐位相等**：期望值 = "store 字节 ⊕ 内存初值"。
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
    //   ★ 2B-3 第 6 段第二步新增端口：STQ 分配随带的 ROB 索引（年龄在分配期写入）、
    //     发射闸门的**候选** ROB 索引、以及提交点释放窗口 `cmt_n`。
    //     本用例是"LSQ 直驱"夹具（不经 ROB/IQ）⇒ `cmt_n` 恒 0（不模拟提交点），
    //     LQ 释放路径由锁步/regress 的端到端用例覆盖；LQ 深度 32 ≫ 本用例 5 笔 load。
    reg [4*ROBW-1:0] alloc_rob = 0;
    reg [ROBW-1:0]   iss_rob = 0;
    reg [2:0]        cmt_n = 0;
    wire             alloc_ok;
    //   ★ 2B-4 第二步新增：LQ 槽在 **D3 派发期**分配 ⇒ 直驱夹具也要显式派发一次 LQ 分配，
    //     并把分到的槽号在 E1 通过 `exe_lq_idx` 送回（与 backend_top 的用法一致）。
    localparam integer LQ_IW = `BACK2_LQ_IDX_W;
    reg [3:0]        lalloc_valid = 0;
    reg [4*ROBW-1:0] lalloc_rob = 0;
    wire             lalloc_ok;
    wire [4*LQ_IW-1:0] lalloc_idx;
    reg [LQ_IW-1:0]  exe_lq_idx = 0;
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
        .alloc_valid(alloc_valid), .alloc_rob(alloc_rob),
        .alloc_ok(alloc_ok), .alloc_idx(alloc_idx),
        .lalloc_valid(lalloc_valid), .lalloc_rob(lalloc_rob),
        .lalloc_ok(lalloc_ok), .lalloc_idx(lalloc_idx),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch), .exe_addr(exe_addr), .exe_wdata(exe_wdata),
        .exe_size(exe_size), .exe_unsign(exe_unsign), .exe_dst_i(exe_dst_i), .exe_dst_f(exe_dst_f),
        .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f), .exe_stq_idx(exe_stq_idx),
        .exe_lq_idx(exe_lq_idx),
        .iss_rob(iss_rob), .iss_ok(iss_ok), .dr_valid(dr_valid), .dr_idx(dr_idx),
        .cmt_n(cmt_n),
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
    //   ★ 检查名宽度 64 B（原 32 B 会把中文 UTF-8 串截断成半个字符 ⇒ 日志乱码）
    task chk(input cond, input [8*64-1:0] nm);
        begin
            n_chk = n_chk + 1;
            if (!cond) begin n_fail = n_fail + 1; $display("FAIL[lsq-fwd]: %0s", nm); end
        end
    endtask

    // ---- 单条 store 入队并 E1 ----
    task st_issue(input [ROBW-1:0] rob, input [31:0] a, input [31:0] d, input [2:0] sz,
                  output [STQ_IW-1:0] slot_o);
        reg [STQ_IW-1:0] slot;
        begin
            @(negedge clk);
            alloc_valid = 4'h1; exe_valid = 1'b0;
            alloc_rob[0*ROBW +: ROBW] = rob;   // 分配期即给出 ROB 索引（年龄唯一写点）
            iss_rob = rob;
            //   ★ 槽号必须在**分配拍**采样：`alloc_idx[0]` 是空闲表的组合读，
            //     在 `alloc_valid=1` 的那一拍它指向"下一拍将被分配的槽"。
            slot = alloc_idx[0*STQ_IW +: STQ_IW];
            slot_o = slot;
            @(posedge clk);                       // 分配发生
            @(negedge clk);
            alloc_valid = 4'h0;
            exe_valid = 1'b1; exe_is_store = 1'b1; exe_stq_idx = slot;
            exe_rob = rob; exe_addr = a; exe_wdata = d; exe_size = sz;
            @(posedge clk);                       // E1：地址/数据/掩码入 STQ
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0;
        end
    endtask

    // ---- 单条 load：**D3 派发分配 LQ 槽** → E1（★ 2B-4 第二步口径）----
    task ld_issue(input [ROBW-1:0] rob, input [31:0] a, input [2:0] sz, input uns);
        reg [LQ_IW-1:0] lslot;
        begin
            @(negedge clk);
            lalloc_valid = 4'h1;
            lalloc_rob[0*ROBW +: ROBW] = rob;
            lslot = lalloc_idx[0*LQ_IW +: LQ_IW];   // 分配拍采样（组合读空闲表）
            @(posedge clk);                          // 分配发生
            @(negedge clk);
            lalloc_valid = 4'h0;
            exe_valid = 1'b1; exe_is_store = 1'b0; exe_rob = rob;
            exe_lq_idx = lslot;
            iss_rob = rob;
            exe_addr = a; exe_size = sz; exe_unsign = uns;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0;
        end
    endtask

    // ---- ★★ N29B 存储映像 + 响应模型 ----
    //   · **store 落地**：`mem_req_valid & mem_req_wen`（= CDQ 排空口发出的写）按
    //     `mem_req_wstrb` 写进 `mem[]` —— 这就是"对 L1D 真实可见"的夹具侧建模。
    //   · **load 响应**：`mem_req_valid & ~mem_req_wen` 受理后**次拍**给出带同 tag 的单拍
    //     响应，数据 = 该对齐字（L1D 口径：响应不做字节旋转，与 `l1d.v cs_rdata` 一致）。
    //   · 请求是**单拍握手脉冲**（`ld_fire` 当拍把 `ld_req` 置 1 ⇒ 下一拍 `mem_req_valid`
    //     已回落）⇒ 必须在 **posedge** 采样握手拍。
    localparam integer MEMW = 16384;                 // 64 KiB / 4（覆盖本夹具全部地址）
    reg [31:0] mem [0:MEMW-1];
    wire [13:0] midx = mem_req_addr[15:2];
    //   ★ N29B：写回 / load 请求**粘滞捕获** —— load 可能在夹具驱动 store 提交的那几拍里
    //     就完成写回（store 排空 1 笔/拍），若只在 `wait_wb` 里轮询会漏掉那一拍。
    reg        wb_seen_m = 1'b0;
    reg [31:0] wb_data_m = 32'h0;
    reg        req_seen_m = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_seen_m <= 1'b0; wb_data_m <= 32'h0; req_seen_m <= 1'b0;
        end else begin
            if (wb_valid) begin wb_seen_m <= 1'b1; wb_data_m <= wb_data; end
            if (mem_req_valid & mem_req_ready & ~mem_req_wen) req_seen_m <= 1'b1;
        end
    end
    integer    mi;
    task set_mem(input [31:0] a, input [31:0] d);
        begin mem[a[15:2]] = d; end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_tag   <= {TAG_W{1'b0}};
            mem_rsp_rdata <= 32'h0;
            for (mi = 0; mi < MEMW; mi = mi + 1) mem[mi] = 32'h0;
        end else begin
            mem_rsp_valid <= mem_req_valid & mem_req_ready & ~mem_req_wen;
            mem_rsp_tag   <= mem_req_tag;
            mem_rsp_rdata <= mem[midx];
            if (mem_req_valid & mem_req_ready &  mem_req_wen) begin
                if (mem_req_wstrb[0]) mem[midx][7:0]   <= mem_req_wdata[7:0];
                if (mem_req_wstrb[1]) mem[midx][15:8]  <= mem_req_wdata[15:8];
                if (mem_req_wstrb[2]) mem[midx][23:16] <= mem_req_wdata[23:16];
                if (mem_req_wstrb[3]) mem[midx][31:24] <= mem_req_wdata[31:24];
            end
        end
    end

    // ---- 等待写回（最多 40 拍）；load 请求由上面的响应模型自动应答 ----
    //   ★ N29B：不再有"先给响应数据"的入参 —— 数据来自 `mem[]`（store 落地已写进去）。
    task wait_wb(output [31:0] got, output integer saw_req);
        integer t; reg done;
        begin
            got = 32'h0; saw_req = 0; done = 1'b0;
            for (t = 0; (t < 60) && !done; t = t + 1) begin
                @(posedge clk);
                if (wb_seen_m) begin got = wb_data_m; done = 1'b1; end
            end
            saw_req = req_seen_m ? 1 : 0;
            @(negedge clk);
            if (!done) begin
                n_chk = n_chk + 1; n_fail = n_fail + 1;
                $display("FAIL[lsq-fwd]: 等待 load 写回超时（60 拍）");
            end
            //   清粘滞位供下一场景（每场景恰一次写回 / 恰一笔 load 请求）
            wb_seen_m = 1'b0; req_seen_m = 1'b0; wb_data_m = 32'h0;
        end
    endtask

    // ---- LQ 占用统计（判据③的 C7：提交点释放的可观测判据）----
    function integer lq_occ;
        integer q;
        begin
            lq_occ = 0;
            for (q = 0; q < OUT_N; q = q + 1) if (u_lsq.ld_v[q]) lq_occ = lq_occ + 1;
        end
    endfunction

    // ---- 驱动 store 提交排空（dr_valid/dr_idx）：入 CDQ → 排空口写进 `mem[]` ----
    //   ★ N29B：`dr_room_ok` 要求 CDQ 余量 ≥ 2W=8（CDQ_N=8）⇒ 必须等上一笔真正排空
    //     （`dr_fire`）之后才能提交下一笔；多等几拍是安全的（排空 1 笔/拍）。
    task drain_store(input [STQ_IW-1:0] slot);
        integer w;
        begin
            @(negedge clk); dr_valid = 4'h1; dr_idx = {3'b0, slot};
            @(posedge clk);
            @(negedge clk); dr_valid = 4'h0;
            for (w = 0; w < 4; w = w + 1) @(posedge clk);
            @(negedge clk);
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

        // ---------- C1：字节 store(A) → 字 load(A)：走等待 + 访存（字节 0 来自落地值）----------
        //   参考（逐位等价）：期望 = 内存初值 0x1122_3344 的字节 0 被 store 的 0xAA 覆盖。
        set_mem(32'h8000_1000, 32'h1122_3344);
        st_issue(7'd1, 32'h8000_1000, 32'h0000_00AA, 3'd0, s0);   // sb 0xAA
        ld_issue(7'd2, 32'h8000_1000, 3'd2, 1'b0);                // lw（依赖更老 store ⇒ 等）
        drain_store(s0);                                          // store 提交 → 落地进 mem[]
        wait_wb(v, rq);
        chk(rq == 1, "C1 有依赖 ⇒ 等待后仍须访存（请求 1 笔）");
        chk(v == 32'h1122_33AA, "C1 字节 0 = store 落地值，其余 = 存储映像初值");

        // ---------- C2：两个字节 store(A+0/A+1) → 字 load：两字节拼接 ----------
        set_mem(32'h8000_2000, 32'hAABB_CCDD);
        st_issue(7'd3, 32'h8000_2000, 32'h0000_0055, 3'd0, s0);   // sb 0x55 @+0
        st_issue(7'd4, 32'h8000_2001, 32'h0000_0066, 3'd0, s1);   // sb 0x66 @+1
        ld_issue(7'd5, 32'h8000_2000, 3'd2, 1'b0);                // lw
        drain_store(s0);                                          // 按程序序提交（更老在前）
        drain_store(s1);
        wait_wb(v, rq);
        chk(rq == 1, "C2 两字节拼接 ⇒ 须访存（请求 1 笔）");
        chk(v == 32'hAABB_6655, "C2 字节 0/1 = 两条 store 落地值，其余 = 初值");

        // ---------- C3：同字节两条 store（更老 0x11 / 更年轻 0x22）→ lbu ⇒ 更年轻者 ----------
        set_mem(32'h8000_3000, 32'hDEAD_BEEF);
        st_issue(7'd6, 32'h8000_3000, 32'h0000_0011, 3'd0, s0);
        st_issue(7'd7, 32'h8000_3000, 32'h0000_0022, 3'd0, s1);
        ld_issue(7'd8, 32'h8000_3000, 3'd0, 1'b1);                // lbu
        drain_store(s0);                                          // 程序序 ⇒ 年轻者后落地
        drain_store(s1);
        wait_wb(v, rq);
        chk(v == 32'h0000_0022, "C3 同字节 ⇒ 更年轻 store 后落地，读回 0x22");

        // ---------- C4：字 store → 同址字 load：**纯等待变体下必须访存** ----------
        set_mem(32'h8000_4000, 32'h0BAD_0000);
        st_issue(7'd9, 32'h8000_4000, 32'hCAFE_F00D, 3'd2, s0);   // sw
        ld_issue(7'd10, 32'h8000_4000, 3'd2, 1'b0);               // lw（单条完整覆盖）
        drain_store(s0);
        wait_wb(v, rq);
        chk(rq == 1, "C4 无直通快路 ⇒ 覆盖也必须等 store 落地后访存（请求 1 笔）");
        chk(v == 32'hCAFE_F00D, "C4 数据 = 落地后的存储映像");

        // ---------- C5：地址不相交 ⇒ 无依赖 ⇒ 不等待、结果 = 存储器初值 ----------
        set_mem(32'h8000_6000, 32'h0BAD_F00D);
        st_issue(7'd11, 32'h8000_5000, 32'hFFFF_FFFF, 3'd2, s0);
        ld_issue(7'd12, 32'h8000_6000, 3'd2, 1'b0);
        drain_store(s0);
        wait_wb(v, rq);
        chk(rq == 1, "C5 无命中须访存");
        chk(v == 32'h0BAD_F00D, "C5 结果应为存储器初值");

        // ---------- C6：半字 store → 半字 load（掩码 0b0011） ----------
        set_mem(32'h8000_7000, 32'h1357_2468);
        st_issue(7'd13, 32'h8000_7000, 32'h0000_7A5A, 3'd1, s0);  // sh
        ld_issue(7'd14, 32'h8000_7000, 3'd1, 1'b1);               // lhu
        drain_store(s0);
        wait_wb(v, rq);
        chk(v == 32'h0000_7A5A, "C6 半字 = store 落地值");

        // ---------- C7（第 11 项）：LQ **提交点释放**（2B-3 第二步的释放语义）----------
        //   旧口径是"响应到达即释放槽"；现口径是"响应只置 ld_dn（数据已齐），槽留到该 load
        //   按程序序提交才释放"。本用例直驱该路径：
        //     ① 发一条无命中 load（走存储器）→ 等写回；
        //     ② 写回后断言 LQ 占用 **+1**（数据已齐但槽仍占 —— 证明不是"响应即释放"）；
        //     ③ 驱动 `rob_head` 指向该 load 的 rob 号并给 `cmt_n=1`（模拟 ROB 提交组）；
        //     ④ 断言 LQ 占用回到原值（槽被提交点释放）。
        //   ★ 恰好**一项**检查（判据③要求 tb_back2_lsq_fwd 由 10 项增为 11 项）。
        begin : c7
            integer occ0, occ1, occ2;
            occ0 = lq_occ();
            set_mem(32'h8000_9000, 32'h5566_7788);
            ld_issue(7'd20, 32'h8000_9000, 3'd2, 1'b0);
            wait_wb(v, rq);
            occ1 = lq_occ();
            rob_head = 7'd20; cmt_n = 3'd1;          // ROB 提交该 load
            @(posedge clk);
            @(negedge clk);
            cmt_n = 3'd0;
            occ2 = lq_occ();
            chk((occ1 == (occ0 + 1)) && (occ2 == occ0),
                "C7 LQ 提交点释放：写回后仍占用（+1）、提交后释放（回原值）");
        end

        // ---------- 结果 ----------
        if (n_fail == 0) begin
            $display("== 检查项合计 %0d 项全部满足（纯等待：有依赖即等 store 落地后访存 / 无依赖不等待 / 程序序覆盖 / 提交点释放）", n_chk);
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
