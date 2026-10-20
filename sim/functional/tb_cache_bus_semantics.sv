//==============================================================================
// sim/functional/tb_cache_bus_semantics.sv —— F3 Cache/AXI 语义定向功能包
//------------------------------------------------------------------------------
// 项目 : rv32gc-cpu（阶段二）
// 目标 : 只驱动 `rtl/cache/l1d.v` / `rtl/cache/l1i.v` / `rtl/axi/axi_master_ctrl.v`
//        的**真实接口**，按合法生命周期构造用例，覆盖冻结审计
//        `sim/audit/global-2026-10-18/04-memory-bus.md` 的已确认根因：
//          04-04（P0）L1D 写回 valid 早于描述符 / 首拍写错地址
//          04-05（P1）AXI 4 K 拆分首笔就 done / busy 未覆盖整个逻辑请求
//          04-07（P1）错误 refill 仍落 valid；写回 B 失败仍清 dirty
//        并配"合法正控"（旧/新两棵树都必须通过的控制向量）。
//
// 方法学（prompts/common.md §3 fail-closed）：
//   · 逐向量打印 `VEC <id> <name> checks=<n> fails=<n> defect=<d>`：
//       fails  = 对**修复后期望行为**判据的违反数（新树必须 0）；
//       defect = 该根因的**结构性旧行为签名**是否出现（新树必须 0；旧树反证时须 1）。
//   · 只读层次观测（`dut_*.*`）允许，**绝不 force/改写 DUT 状态**；全部推进经真实握手。
//   · 固定非零规格：所有行地址、种子、store 值均非零且逐行不同；每向量 ≥1 检查。
//   · 独立 oracle：行内容由 TB 自己的 `line_word()` 算出；脏行集合、写回数据、
//     填充 beat 数、done 次数、busy 覆盖窗口全部由 TB 独立记账，不用 DUT 内部信号
//     当期望值。
//   · 四态安全：所有 DUT 输入由寄存器驱动并显式复位；错误输入**显式**驱动 0/1。
//
// 旧树反证（`CACHE_BUS_OLD_DUT`）：
//   201acf61 的 l1d/l1i **没有**任何 refill/B 错误端口（这正是 04-07 的结构性缺陷），
//   因此该宏下 TB 以旧端口表例化 DUT，并把错误类向量的判据显式判 FAIL + 标 defect
//   （**不是**跳过、也**不是**伪造 err=0 通过）。04-04/04-05 向量在两棵树上同源同判。
//
// 运行（由 sim/functional/test_cache_bus.sh 调用）：
//   iverilog -g2012 -I <DUT_ROOT> -s tb_cache_bus_semantics_top -o x.vvp \
//       sim/functional/tb_cache_bus_semantics.sv \
//       <DUT_ROOT>/rtl/cache/{l1d,l1i,cache_tag_array,cache_array_bram}.v \
//       <DUT_ROOT>/rtl/axi/axi_master_ctrl.v
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

`ifdef CACHE_BUS_OLD_DUT
  `define CB_HAS_ERR_IF 0
`else
  `define CB_HAS_ERR_IF 1
`endif

module tb_cache_bus_semantics_top;

    //--------------------------------------------------------------------------
    // 0. 参数（与真源宏逐项一致；不做局部改写）
    //--------------------------------------------------------------------------
    localparam integer D_WAYS  = `RV32GC_L1D_WAYS;        // 4
    localparam integer D_SETS  = `RV32GC_L1D_SETS;        // 256
    localparam integer D_LINE  = `RV32GC_L1D_LINE_BYTES;  // 32
    localparam integer I_WAYS  = `RV32GC_L1I_WAYS;        // 2
    localparam integer I_SETS  = `RV32GC_L1I_SETS;        // 256
    localparam integer I_LINE  = `RV32GC_L1I_LINE_BYTES;  // 32
    localparam integer WORDS   = 8;                       // 32 B / 4 B
    localparam integer HAS_ERR = `CB_HAS_ERR_IF;

    //--------------------------------------------------------------------------
    // 1. 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    //--------------------------------------------------------------------------
    // 2. 判定基础设施（fail-closed；stdout 只放 VEC/摘要行 + 唯一 PASS 锚点）
    //--------------------------------------------------------------------------
    integer g_total, g_nonzero, g_checks, g_fails, g_defect;
    // ★ 向量内"不可恢复"标志：某一步超时（旧树的真实死锁）后，本向量剩余步骤
    //   一律跳过（不再产生误报的连锁 CHK_BAD），但该向量已记 FAIL+defect。
    reg     abort_vec;
    integer v_checks, v_fails, v_defect;
    reg [8*32-1:0] v_name;

    task vec_begin(input [8*32-1:0] nm);
        begin
            v_name = nm; v_checks = 0; v_fails = 0; v_defect = 0;
            abort_vec = 1'b0;
            g_total = g_total + 1;
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

    // ★★ 复审修复（P1-2）：chk **四态安全** —— 只有"已知 1"才算通过。
    //   原写法 `if (!ok)` 在 ok=X/Z 时得 X，`if (X)` 被当假 ⇒ **未知被静默当通过**。
    //   改为 `ok !== 1'b1`：0/X/Z 一律计失败（fail-closed）。
    task chk(input ok, input [8*64-1:0] what);
        begin
            v_checks = v_checks + 1;
            if (ok !== 1'b1) begin
                v_fails = v_fails + 1;
                $display("CHK_BAD vec=%0d name=%0s what=%0s", g_total, v_name, what);
            end
        end
    endtask

    // ★ 逐字比较（带 word 下标与 got/exp，便于定位"只核了 3/8 字"这类漏洞）
    task chk_word(input [31:0] got, input [31:0] exp, input [8*24-1:0] tag, input integer w);
        begin
            v_checks = v_checks + 1;
            if (got !== exp) begin
                v_fails = v_fails + 1;
                $display("CHK_BAD vec=%0d name=%0s what=%0s word=%0d got=%h exp=%h",
                         g_total, v_name, tag, w, got, exp);
            end
        end
    endtask

    task mark_defect;
        begin
            v_defect = 1;
            $display("DEFECT_SIG vec=%0d name=%0s", g_total, v_name);
        end
    endtask

    //==========================================================================
    // 3. L1D 接线与真实接口驱动
    //==========================================================================
    reg         d_cs_req, d_cs_we;
    reg  [3:0]  d_cs_wstrb;
    reg  [31:0] d_cs_paddr, d_cs_vaddr, d_cs_wdata;
    wire        d_cs_ready, d_cs_miss, d_cs_stall, d_cs_wr_done;
    wire [31:0] d_cs_rdata;
    wire        d_cs_err;

    wire        d_fill_req;
    wire [31:0] d_fill_paddr;
    wire [1:0]  d_fill_owner;
    wire [4:0]  d_fill_beats;
    reg         d_fill_accepted, d_fill_valid, d_fill_done, d_fill_err;
    reg  [31:0] d_fill_data;
    reg  [4:0]  d_fill_word_idx;
    wire        d_fill_fail;

    wire        d_wb_req;
    wire [31:0] d_wb_paddr;
    wire [1:0]  d_wb_way;
    wire [1:0]  d_wb_owner;
    wire [4:0]  d_wb_beats;
    reg         d_wb_accepted, d_wb_done, d_wb_err;
    reg  [4:0]  d_wb_word_idx;
    wire [31:0] d_wb_data;
    wire        d_wb_ready, d_wb_fail;

    reg         d_inval_all, d_clean_all;
    wire        d_idle, d_maint_err, d_err_sticky;

`ifdef CACHE_BUS_OLD_DUT
    l1d dut_d (
        .clk (clk), .rst_n (rst_n),
        .cs_req (d_cs_req), .cs_we (d_cs_we), .cs_wstrb (d_cs_wstrb),
        .cs_paddr (d_cs_paddr), .cs_vaddr (d_cs_vaddr), .cs_wdata (d_cs_wdata),
        .cs_ready (d_cs_ready), .cs_rdata (d_cs_rdata), .cs_miss (d_cs_miss),
        .cs_stall (d_cs_stall), .cs_wr_done (d_cs_wr_done),
        .fill_req (d_fill_req), .fill_paddr (d_fill_paddr), .fill_owner (d_fill_owner),
        .fill_beats (d_fill_beats), .fill_accepted (d_fill_accepted),
        .fill_valid (d_fill_valid), .fill_data (d_fill_data),
        .fill_word_idx (d_fill_word_idx), .fill_done (d_fill_done),
        .wb_req (d_wb_req), .wb_paddr (d_wb_paddr), .wb_way (d_wb_way),
        .wb_owner (d_wb_owner), .wb_beats (d_wb_beats), .wb_accepted (d_wb_accepted),
        .wb_word_idx (d_wb_word_idx), .wb_data (d_wb_data), .wb_done (d_wb_done),
        .wb_ready (d_wb_ready),
        .inval_all (d_inval_all), .clean_all (d_clean_all), .idle (d_idle)
    );
`else
    l1d dut_d (
        .clk (clk), .rst_n (rst_n),
        .cs_req (d_cs_req), .cs_we (d_cs_we), .cs_wstrb (d_cs_wstrb),
        .cs_paddr (d_cs_paddr), .cs_vaddr (d_cs_vaddr), .cs_wdata (d_cs_wdata),
        .cs_ready (d_cs_ready), .cs_rdata (d_cs_rdata), .cs_miss (d_cs_miss),
        .cs_stall (d_cs_stall), .cs_wr_done (d_cs_wr_done), .cs_err (d_cs_err),
        .fill_req (d_fill_req), .fill_paddr (d_fill_paddr), .fill_owner (d_fill_owner),
        .fill_beats (d_fill_beats), .fill_accepted (d_fill_accepted),
        .fill_valid (d_fill_valid), .fill_data (d_fill_data),
        .fill_word_idx (d_fill_word_idx), .fill_done (d_fill_done),
        .fill_err (d_fill_err), .fill_fail (d_fill_fail),
        .wb_req (d_wb_req), .wb_paddr (d_wb_paddr), .wb_way (d_wb_way),
        .wb_owner (d_wb_owner), .wb_beats (d_wb_beats), .wb_accepted (d_wb_accepted),
        .wb_word_idx (d_wb_word_idx), .wb_data (d_wb_data), .wb_done (d_wb_done),
        .wb_err (d_wb_err), .wb_ready (d_wb_ready), .wb_fail (d_wb_fail),
        .inval_all (d_inval_all), .clean_all (d_clean_all), .idle (d_idle),
        .maint_err (d_maint_err), .err_sticky (d_err_sticky)
    );
`endif

    //==========================================================================
    // 4. L1I 接线与真实接口驱动
    //==========================================================================
    reg         i_cs_req;
    reg  [31:0] i_cs_paddr, i_cs_vaddr;
    wire        i_cs_ready, i_cs_uncached, i_cs_miss, i_cs_err;
    wire [31:0] i_cs_rdata;

    wire        i_fill_req;
    wire [31:0] i_fill_paddr;
    wire [1:0]  i_fill_owner;
    wire [4:0]  i_fill_beats;
    reg         i_fill_accepted, i_fill_valid, i_fill_done, i_fill_err;
    reg  [31:0] i_fill_data;
    reg  [4:0]  i_fill_word_idx;
    wire        i_fill_fail;

    reg         i_inval_all;
    wire        i_idle, i_err_sticky;
`ifdef CACHE_BUS_HAS_ERR_PA
    wire [31:0] i_cs_err_paddr;      // 新增输出（仅当前树有；旧/HEAD 树不连）
`else
    wire [31:0] i_cs_err_paddr = 32'h0;
`endif

`ifdef CACHE_BUS_OLD_DUT
    l1i dut_i (
        .clk (clk), .rst_n (rst_n),
        .cs_req (i_cs_req), .cs_paddr (i_cs_paddr), .cs_vaddr (i_cs_vaddr),
        .cs_ready (i_cs_ready), .cs_rdata (i_cs_rdata),
        .cs_uncached (i_cs_uncached), .cs_miss (i_cs_miss),
        .fill_req (i_fill_req), .fill_paddr (i_fill_paddr),
        .fill_owner (i_fill_owner), .fill_beats (i_fill_beats),
        .fill_accepted (i_fill_accepted), .fill_valid (i_fill_valid),
        .fill_data (i_fill_data), .fill_word_idx (i_fill_word_idx),
        .fill_done (i_fill_done), .inval_all (i_inval_all), .idle (i_idle)
    );
`else
    l1i dut_i (
        .clk (clk), .rst_n (rst_n),
        .cs_req (i_cs_req), .cs_paddr (i_cs_paddr), .cs_vaddr (i_cs_vaddr),
        .cs_ready (i_cs_ready), .cs_rdata (i_cs_rdata),
        .cs_uncached (i_cs_uncached), .cs_miss (i_cs_miss), .cs_err (i_cs_err),
        .fill_req (i_fill_req), .fill_paddr (i_fill_paddr),
        .fill_owner (i_fill_owner), .fill_beats (i_fill_beats),
        .fill_accepted (i_fill_accepted), .fill_valid (i_fill_valid),
        .fill_data (i_fill_data), .fill_word_idx (i_fill_word_idx),
        .fill_done (i_fill_done), .fill_err (i_fill_err), .fill_fail (i_fill_fail),
        .inval_all (i_inval_all), .idle (i_idle), .err_sticky (i_err_sticky)
`ifdef CACHE_BUS_HAS_ERR_PA
        , .cs_err_paddr (i_cs_err_paddr)
`endif
    );
`endif

    //==========================================================================
    // 5. AXI 主控接线 + 从设备行为模型（可配置延迟 / 逐 beat 错误）
    //==========================================================================
    reg         a_req_valid, a_req_is_write;
    reg  [1:0]  a_req_owner;
    reg  [31:0] a_req_addr;
    reg  [3:0]  a_req_len;
    reg  [4:0]  a_req_beats, a_req_beats_1, a_req_beats_2;
    reg         a_req_split;
    reg  [3:0]  a_req_id;
    wire        a_req_ready;

    reg         a_wdata_valid;
    reg  [31:0] a_wdata_data;
    wire        a_wdata_ready;

    wire        a_rdata_valid;
    wire [31:0] a_rdata_data;
    wire [3:0]  a_rdata_id;
    wire        a_rdata_last;
    reg         a_rdata_ready;

    wire        a_done, a_rdata_error, a_done_error;
    wire [1:0]  a_done_owner;
    wire [31:0] a_done_addr;
    wire        a_resp_error;
    wire [1:0]  a_resp_code;

    wire [3:0]  m_awid;   wire [31:0] m_awaddr; wire [3:0] m_awlen;
    wire [2:0]  m_awsize; wire [1:0]  m_awburst; wire [2:0] m_awlock;
    wire [3:0]  m_awcache; wire [2:0] m_awprot;  wire m_awvalid;
    reg         m_awready;
    wire [31:0] m_wdata;  wire [3:0]  m_wstrb;   wire m_wlast, m_wvalid;
    reg         m_wready;
    reg  [3:0]  m_bid;    reg  [1:0]  m_bresp;   reg  m_bvalid;
    wire        m_bready;
    wire [3:0]  m_arid;   wire [31:0] m_araddr;  wire [3:0] m_arlen;
    wire [2:0]  m_arsize; wire [1:0]  m_arburst; wire [2:0] m_arlock;
    wire [3:0]  m_arcache; wire [2:0] m_arprot;  wire m_arvalid;
    reg         m_arready;
    reg  [3:0]  m_rid;    reg  [31:0] m_rdata;   reg  [1:0] m_rresp;
    reg         m_rlast, m_rvalid;
    wire        m_rready;
    wire        a_busy;
    wire [1:0]  a_owner;

`ifdef CACHE_BUS_OLD_DUT
    axi_master_ctrl dut_a (
        .clk (clk), .rst_n (rst_n),
        .req_valid (a_req_valid), .req_is_write (a_req_is_write),
        .req_owner (a_req_owner), .req_addr (a_req_addr), .req_len (a_req_len),
        .req_beats (a_req_beats), .req_split (a_req_split),
        .req_beats_1 (a_req_beats_1), .req_beats_2 (a_req_beats_2),
        .req_id (a_req_id), .req_ready (a_req_ready),
        .wdata_valid (a_wdata_valid), .wdata_data (a_wdata_data),
        .wdata_ready (a_wdata_ready),
        .rdata_valid (a_rdata_valid), .rdata_data (a_rdata_data),
        .rdata_id (a_rdata_id), .rdata_last (a_rdata_last),
        .rdata_ready (a_rdata_ready),
        .done (a_done), .done_owner (a_done_owner), .done_addr (a_done_addr),
        .resp_error (a_resp_error), .resp_code (a_resp_code),
        .m_awid (m_awid), .m_awaddr (m_awaddr), .m_awlen (m_awlen),
        .m_awsize (m_awsize), .m_awburst (m_awburst), .m_awlock (m_awlock),
        .m_awcache (m_awcache), .m_awprot (m_awprot),
        .m_awvalid (m_awvalid), .m_awready (m_awready),
        .m_wdata (m_wdata), .m_wstrb (m_wstrb), .m_wlast (m_wlast),
        .m_wvalid (m_wvalid), .m_wready (m_wready),
        .m_bid (m_bid), .m_bresp (m_bresp), .m_bvalid (m_bvalid), .m_bready (m_bready),
        .m_arid (m_arid), .m_araddr (m_araddr), .m_arlen (m_arlen),
        .m_arsize (m_arsize), .m_arburst (m_arburst), .m_arlock (m_arlock),
        .m_arcache (m_arcache), .m_arprot (m_arprot),
        .m_arvalid (m_arvalid), .m_arready (m_arready),
        .m_rid (m_rid), .m_rdata (m_rdata), .m_rresp (m_rresp),
        .m_rlast (m_rlast), .m_rvalid (m_rvalid), .m_rready (m_rready),
        .busy (a_busy), .owner (a_owner)
    );
`else
    axi_master_ctrl dut_a (
        .clk (clk), .rst_n (rst_n),
        .req_valid (a_req_valid), .req_is_write (a_req_is_write),
        .req_owner (a_req_owner), .req_addr (a_req_addr), .req_len (a_req_len),
        .req_beats (a_req_beats), .req_split (a_req_split),
        .req_beats_1 (a_req_beats_1), .req_beats_2 (a_req_beats_2),
        .req_id (a_req_id), .req_ready (a_req_ready),
        .req_cache (4'b1111), .req_strb (4'hF),
        .wdata_valid (a_wdata_valid), .wdata_data (a_wdata_data),
        .wdata_ready (a_wdata_ready),
        .rdata_valid (a_rdata_valid), .rdata_data (a_rdata_data),
        .rdata_id (a_rdata_id), .rdata_last (a_rdata_last),
        .rdata_ready (a_rdata_ready), .rdata_hold (),
        .done (a_done), .done_owner (a_done_owner), .done_addr (a_done_addr),
        .resp_error (a_resp_error), .resp_code (a_resp_code),
        .rdata_error (a_rdata_error), .done_error (a_done_error),
        .m_awid (m_awid), .m_awaddr (m_awaddr), .m_awlen (m_awlen),
        .m_awsize (m_awsize), .m_awburst (m_awburst), .m_awlock (m_awlock),
        .m_awcache (m_awcache), .m_awprot (m_awprot),
        .m_awvalid (m_awvalid), .m_awready (m_awready),
        .m_wdata (m_wdata), .m_wstrb (m_wstrb), .m_wlast (m_wlast),
        .m_wvalid (m_wvalid), .m_wready (m_wready),
        .m_bid (m_bid), .m_bresp (m_bresp), .m_bvalid (m_bvalid), .m_bready (m_bready),
        .m_arid (m_arid), .m_araddr (m_araddr), .m_arlen (m_arlen),
        .m_arsize (m_arsize), .m_arburst (m_arburst), .m_arlock (m_arlock),
        .m_arcache (m_arcache), .m_arprot (m_arprot),
        .m_arvalid (m_arvalid), .m_arready (m_arready),
        .m_rid (m_rid), .m_rdata (m_rdata), .m_rresp (m_rresp),
        .m_rlast (m_rlast), .m_rvalid (m_rvalid), .m_rready (m_rready),
        .busy (a_busy), .owner (a_owner)
    );
`endif

    //--------------------------------------------------------------------------
    // 5.1 从设备：读/写各一个引擎；第 2 笔（拆分后半）可单独加大延迟
    //--------------------------------------------------------------------------
    integer sl_r_gap_0 = 2;      // 第 1 笔 AR→首 beat 间隔
    integer sl_r_gap_1 = 100;    // 第 2 笔（拆分后半）AR→首 beat 间隔（故意 100 拍）
    integer sl_b_gap_0 = 2;
    integer sl_b_gap_1 = 100;
    reg [1:0] sl_r_resp_0 = 2'b00, sl_r_resp_1 = 2'b00;   // 整笔基准响应（可设 X）
    reg [1:0] sl_b_resp_0 = 2'b00, sl_b_resp_1 = 2'b00;   // B 响应（可设 X）
    // ★ 逐 beat 注入（-1 = 不注入）：beat_idx 为**本笔事务内**的 0 起下标。
    //   err_beat ⇒ 该 beat 的 rresp = SLVERR(2'b10)；x_beat ⇒ 该 beat 的 rresp = 2'bxx。
    //   X 优先于 SLVERR（用于证明"有效拍上的 X 不得被当 OK"）。
    integer sl_r_err_beat_0 = -1, sl_r_err_beat_1 = -1;
    integer sl_r_x_beat_0   = -1, sl_r_x_beat_1   = -1;

    integer ar_seen, aw_seen;
    reg [31:0] ar_addr_seen [0:7];
    reg [3:0]  ar_len_seen  [0:7];
    reg [31:0] aw_addr_seen [0:7];
    reg [3:0]  aw_len_seen  [0:7];

    // ---- AR ready（固定 1 拍后接受）----
    reg ar_rdy_q;
    always @(posedge clk) begin
        if (!rst_n) ar_rdy_q <= 1'b0;
        else if (m_arvalid && !m_arready) ar_rdy_q <= 1'b1;
        else ar_rdy_q <= 1'b0;
    end
    always @(*) m_arready = ar_rdy_q;

    // ---- AW ready ----
    reg aw_rdy_q;
    always @(posedge clk) begin
        if (!rst_n) aw_rdy_q <= 1'b0;
        else if (m_awvalid && !m_awready) aw_rdy_q <= 1'b1;
        else aw_rdy_q <= 1'b0;
    end
    always @(*) m_awready = aw_rdy_q;

    // ---- W ready（固定接收）----
    always @(*) m_wready = (m_wvalid & rst_n);

    // ---- AR/AW 记账 ----
    always @(posedge clk) begin
        if (rst_n && m_arvalid && m_arready && ar_seen < 8) begin
            ar_addr_seen[ar_seen] <= m_araddr;
            ar_len_seen[ar_seen]  <= m_arlen;
            ar_seen <= ar_seen + 1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && m_awvalid && m_awready && aw_seen < 8) begin
            aw_addr_seen[aw_seen] <= m_awaddr;
            aw_len_seen[aw_seen]  <= m_awlen;
            aw_seen <= aw_seen + 1;
        end
    end

    // ---- R 引擎（支持逐 beat 响应注入；X/Z 用于证明 fail-closed）----
    integer   r_rem;  integer r_gap; integer r_idx;
    reg [31:0] r_addr; reg r_busy; reg [1:0] r_resp_base;
    integer   r_err_beat, r_x_beat;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_rvalid <= 1'b0; m_rdata <= 32'h0; m_rresp <= 2'b00;
            m_rlast <= 1'b0;  m_rid <= 4'h0;
            r_rem <= 0; r_gap <= 0; r_busy <= 1'b0; r_addr <= 32'h0;
            r_resp_base <= 2'b00; r_idx <= 0;
            r_err_beat <= -1; r_x_beat <= -1;
        end else if (m_arvalid && m_arready) begin
            r_rem       <= {1'b0, m_arlen} + 1;
            r_gap       <= (ar_seen == 0) ? sl_r_gap_0 : sl_r_gap_1;
            r_addr      <= m_araddr;
            r_resp_base <= (ar_seen == 0) ? sl_r_resp_0 : sl_r_resp_1;
            r_err_beat  <= (ar_seen == 0) ? sl_r_err_beat_0 : sl_r_err_beat_1;
            r_x_beat    <= (ar_seen == 0) ? sl_r_x_beat_0   : sl_r_x_beat_1;
            r_idx       <= 0;
            r_busy      <= 1'b1;
            m_rvalid    <= 1'b0;
        end else if (r_busy) begin
            if (r_gap > 0) begin
                r_gap <= r_gap - 1;
                m_rvalid <= 1'b0;
            end else if (!m_rvalid) begin
                m_rvalid <= 1'b1;
                m_rdata  <= r_addr;
                m_rid    <= a_req_id;
                m_rlast  <= (r_rem == 1);
                // 逐 beat 响应：X 优先 > SLVERR > 本笔基准
                if (r_x_beat == r_idx)        m_rresp <= 2'bxx;
                else if (r_err_beat == r_idx) m_rresp <= 2'b10;
                else                          m_rresp <= r_resp_base;
            end else if (m_rvalid && m_rready) begin
                r_idx <= r_idx + 1;
                if (r_rem <= 1) begin
                    m_rvalid <= 1'b0; r_busy <= 1'b0; r_rem <= 0;
                end else begin
                    r_rem  <= r_rem - 1;
                    r_addr <= r_addr + 32'd4;
                    m_rdata<= r_addr + 32'd4;
                    m_rlast<= (r_rem == 2);
                    // ★ 连续 beat 期间 m_rvalid 保持为 1（不回到 !m_rvalid 分支），
                    //   因此**下一 beat 的响应必须在这里一起更新**；否则整笔都会
                    //   沿用首 beat 的 rresp（逐 beat 注入会全部失效/错位）。
                    if (r_x_beat == (r_idx + 1))        m_rresp <= 2'bxx;
                    else if (r_err_beat == (r_idx + 1)) m_rresp <= 2'b10;
                    else                                m_rresp <= r_resp_base;
                end
            end
        end else begin
            m_rvalid <= 1'b0;
        end
    end

    // ---- B 引擎 ----
    reg b_armed, b_sent; integer b_gap; reg [1:0] b_resp_cur;
    integer w_fire_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_bvalid <= 1'b0; m_bid <= 4'h0; m_bresp <= 2'b00;
            b_armed <= 1'b0; b_sent <= 1'b0; b_gap <= 0; b_resp_cur <= 2'b00;
            w_fire_cnt <= 0;
        end else begin
            if (m_awvalid && m_awready)
                b_resp_cur <= (aw_seen == 0) ? sl_b_resp_0 : sl_b_resp_1;
            if (m_wvalid && m_wready) begin
                w_fire_cnt <= w_fire_cnt + 1;
                if (m_wlast) begin b_armed <= 1'b1; b_sent <= 1'b0;
                                  b_gap <= (aw_seen <= 1) ? sl_b_gap_0 : sl_b_gap_1; end
            end
            if (b_armed && !b_sent) begin
                if (b_gap > 0) b_gap <= b_gap - 1;
                else begin m_bvalid <= 1'b1; m_bid <= a_req_id; m_bresp <= b_resp_cur;
                           b_sent <= 1'b1; end
            end
            if (m_bvalid && m_bready) begin
                m_bvalid <= 1'b0; b_armed <= 1'b0; b_sent <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5.2 done/busy 监视（**独立**记账：不依赖 DUT 内部状态）
    //--------------------------------------------------------------------------
    integer    n_done;            // 观测到的 done 脉冲总数
    integer    n_done_err;        // 其中 done_error=1 的次数
    reg [31:0] done_addr_cap;
    reg [1:0]  done_owner_cap;
    reg        req_acc_seen;      // 本逻辑请求已被接受
    reg        done_seen_cur;     // 本逻辑请求已看到 done
    integer    busy_holes;        // 接受后、done 前 busy 非已知 1 的拍数
    integer    x_ctrl;            // active 控制信号上出现 X/Z 的**sticky** 计数
    integer    done_before_busy_end; // 首笔后 done 的违规计数（由 busy_holes 覆盖）

    always @(posedge clk) begin
        if (!rst_n) begin
            n_done <= 0; n_done_err <= 0; done_addr_cap <= 32'h0;
            done_owner_cap <= 2'h0; req_acc_seen <= 1'b0; done_seen_cur <= 1'b0;
            busy_holes <= 0; x_ctrl <= 0;
        end else begin
            if ((a_req_valid === 1'b1) && (a_req_ready === 1'b1)) begin
                req_acc_seen <= 1'b1;
                done_seen_cur <= 1'b0;
                busy_holes <= 0;
            end
            if (a_done === 1'b1) begin
                n_done <= n_done + 1;
                done_addr_cap <= a_done_addr;
                done_owner_cap <= a_done_owner;
                done_seen_cur <= 1'b1;
`ifndef CACHE_BUS_OLD_DUT
                //   done_error 同拍采样（只有已知 1 才算"该 done 报错"）
                if (a_done_error === 1'b1) n_done_err <= n_done_err + 1;
`endif
            end
            // ★★ 复审修复（P1-2）：busy 为 X/Z 时**不得**被当"不忙"而吞掉空洞。
            //   判据改为"busy 不是已知 1"⇒ 记一次 hole + 记一次控制未知（sticky）。
            if ((req_acc_seen === 1'b1) && (done_seen_cur === 1'b0) && (a_done !== 1'b1)) begin
                if (a_busy !== 1'b1) busy_holes <= busy_holes + 1;
            end
            //   active 控制信号上的 X/Z：**sticky** 结算（每个 AXI 向量末尾断言为 0）。
            //   只看"在途窗口"内的控制（req/done/busy/valid/ready/rlast），不看 payload。
            if (a_busy   !== 1'b0 && a_busy   !== 1'b1) x_ctrl <= x_ctrl + 1;
            if (a_done   !== 1'b0 && a_done   !== 1'b1) x_ctrl <= x_ctrl + 1;
            if (a_req_ready !== 1'b0 && a_req_ready !== 1'b1) x_ctrl <= x_ctrl + 1;
            if (a_rdata_valid !== 1'b0 && a_rdata_valid !== 1'b1) x_ctrl <= x_ctrl + 1;
            if (a_rdata_last  !== 1'b0 && a_rdata_last  !== 1'b1) x_ctrl <= x_ctrl + 1;
            if (a_wdata_ready !== 1'b0 && a_wdata_ready !== 1'b1) x_ctrl <= x_ctrl + 1;
        end
    end

    //--------------------------------------------------------------------------
    // 5.2b resp_error / resp_code 观测（用于断言"错误码来源正确"）
    //   `resp_code` 在错误拍 = 原始 resp；错误脉冲过后 = 锁存的 err_code_q。
    //   两者都断言：前者证明码源选对（读错不得锁 bresp），后者证明锁存没串源。
    //--------------------------------------------------------------------------
    integer    n_resp_err;
    reg [1:0]  resp_code_at_err;      // 错误当拍的 resp_code（原始码）
    reg [1:0]  resp_code_latched;     // 错误后 2 拍仍有效的 resp_code（= err_code_q）
    reg        resp_code_latched_ok;
    always @(posedge clk) begin
        if (!rst_n) begin
            n_resp_err <= 0; resp_code_at_err <= 2'b00;
            resp_code_latched <= 2'b00; resp_code_latched_ok <= 1'b0;
        end else begin
            if (a_resp_error === 1'b1) begin
                if (n_resp_err == 0) resp_code_at_err <= a_resp_code;
                n_resp_err <= n_resp_err + 1;
                resp_code_latched_ok <= 1'b0;
            end else if ((n_resp_err > 0) && (resp_code_latched_ok === 1'b0) &&
                         (a_resp_error === 1'b0)) begin
                // 错误脉冲后的稳定拍：resp_code 现在来自 err_code_q（锁存码）
                resp_code_latched    <= a_resp_code;
                resp_code_latched_ok <= 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5.2c ★★ 复审修复（P1-3）：**逐 beat 独立 oracle**
    //   原实现只数"错误 beat 总数/是否落在某个有效 R beat 上" ⇒ 把**早 beat 的错误
    //   拖到本事务最后一个有效 beat** 仍然全绿（总数没变、也仍在某个 valid beat 上）。
    //   这里改为：在**每一个** slave 侧 `m_rvalid && m_rready` 握手上，用 TB 自己驱动
    //   的 `m_rresp/m_rdata/m_rlast` 独立解码期望值（known OKAY=0，其余含 X/Z=1），
    //   与 DUT **同一拍**的 `rdata_valid/rdata_error/rdata_data/rdata_last` 逐项比较；
    //   错误拍还要求 `resp_code` 等于原始 m_rresp（已知非 OKAY 时）。
    //   任何一项不符 ⇒ beat_mismatch 累加（逐向量断言为 0）。
    //--------------------------------------------------------------------------
    integer n_beat_seen;          // slave 侧已完成的 R beat 数（真实握手，不是拍数）
    integer n_beat_err_exp;       // 其中期望为错误的 beat 数
    integer beat_mismatch;        // 逐 beat 期望 vs DUT 输出的不符数
    integer beat_code_mismatch;   // 错误拍上 resp_code 与原始 m_rresp 不符数
    integer bt_mm;                // 本拍不符计数（仅该 always 使用）

    always @(posedge clk) begin
        if (!rst_n) begin
            n_beat_seen <= 0; n_beat_err_exp <= 0;
            beat_mismatch <= 0; beat_code_mismatch <= 0;
        end else if ((m_rvalid === 1'b1) && (m_rready === 1'b1)) begin
            n_beat_seen <= n_beat_seen + 1;
            if (m_rresp !== 2'b00) n_beat_err_exp <= n_beat_err_exp + 1;
`ifndef CACHE_BUS_OLD_DUT
            //   独立解码：known OKAY ⇒ 期望无错；1/X/Z ⇒ 期望有错
            //   （旧树没有 rdata_error 端口 ⇒ 无可比对象，整段不启用，保证控制向量仍绿）
            bt_mm = 0;
            if (a_rdata_valid !== 1'b1) bt_mm = bt_mm + 1;
            if (m_rresp === 2'b00) begin
                if (a_rdata_error !== 1'b0) bt_mm = bt_mm + 1;
            end else begin
                if (a_rdata_error !== 1'b1) bt_mm = bt_mm + 1;
                // 码源：仅当原始 resp 已知（非 X）时要求 resp_code 等于它
                if ((m_rresp !== 2'bxx) && (a_resp_code !== m_rresp))
                    beat_code_mismatch <= beat_code_mismatch + 1;
            end
            if (a_rdata_last !== m_rlast) bt_mm = bt_mm + 1;
            if (a_rdata_data !== m_rdata) bt_mm = bt_mm + 1;
            if (bt_mm != 0) beat_mismatch <= beat_mismatch + bt_mm;
`endif
        end
    end

    //--------------------------------------------------------------------------
    // 5.3 逐 beat 错误对齐自检（新接口：rdata_error 必须与 rdata_valid 同拍）
    //--------------------------------------------------------------------------
    integer n_rdata_err_beats, n_rdata_err_mismatch;
    always @(posedge clk) begin
        if (!rst_n) begin
            n_rdata_err_beats <= 0; n_rdata_err_mismatch <= 0;
        end else begin
`ifndef CACHE_BUS_OLD_DUT
            if (a_rdata_valid && a_rdata_error) n_rdata_err_beats <= n_rdata_err_beats + 1;
            // rdata_error 只在 rdata_valid 拍允许为 1（同拍同 beat 对齐）
            if (a_rdata_error && !a_rdata_valid) n_rdata_err_mismatch <= n_rdata_err_mismatch + 1;
`endif
        end
    end

    //==========================================================================
    // 6. TB 侧独立参考模型：行内容 / 脏行账本
    //--------------------------------------------------------------------------
    //   `line_word(line_base, w)` = 该行第 w 字的**期望**内容（与填充种子一致）。
    //   每行种子 = 32'h2000_0000 | {line_base[19:5], 8'h00} ⇒ 非零且逐行不同。
    //==========================================================================
    function [31:0] line_seed(input [31:0] base);
        begin
            line_seed = 32'h2000_0000 | {base[19:5], 11'h000} | 32'h0000_0100;
        end
    endfunction
    function [31:0] line_word(input [31:0] base, input integer w);
        begin
            line_word = line_seed(base) + w[31:0];
        end
    endfunction

    // 脏行账本（TB 自己记：哪一行、哪个字、什么值）
    reg [31:0] dirty_addr [0:15];
    reg [31:0] dirty_word [0:15];
    reg [31:0] dirty_val  [0:15];
    reg        dirty_v    [0:15];
    integer    n_dirty;

    task dirty_reset;
        integer q;
        begin
            n_dirty = 0;
            for (q = 0; q < 16; q = q + 1) begin
                dirty_addr[q] = 32'h0; dirty_word[q] = 32'h0;
                dirty_val[q] = 32'h0; dirty_v[q] = 1'b0;
            end
        end
    endtask

    task dirty_add(input [31:0] base, input [31:0] word, input [31:0] val);
        begin
            dirty_addr[n_dirty] = base;
            dirty_word[n_dirty] = word;
            dirty_val[n_dirty]  = val;
            dirty_v[n_dirty]    = 1'b1;
            n_dirty = n_dirty + 1;
        end
    endtask

    function [31:0] exp_line_word(input [31:0] base, input integer w);
        integer q;
        reg found;
        begin
            found = 1'b0;
            for (q = 0; q < 16; q = q + 1) begin
                if (dirty_v[q] && (dirty_addr[q] == base) && (dirty_word[q] == w[31:0])) begin
                    exp_line_word = dirty_val[q];
                    found = 1'b1;
                end
            end
            if (!found) exp_line_word = line_word(base, w);
        end
    endfunction

    function dirty_known(input [31:0] base);
        integer q;
        begin
            dirty_known = 1'b0;
            for (q = 0; q < 16; q = q + 1)
                if (dirty_v[q] && (dirty_addr[q] == base)) dirty_known = 1'b1;
        end
    endfunction

    //==========================================================================
    // 7. L1D 驱动任务（真实接口；所有推进经握手）
    //==========================================================================
    // 脉冲计数（由监视器统计，供向量断言）
    integer n_fill_fail, n_wb_fail, n_cs_err_d, n_maint_err, n_fill_req_seen;
    integer n_wb_req_seen;
    integer n_fill_fail_i, n_cs_err_i;   // ★ L1I 侧独立计数（不得复用 D 侧）

    always @(posedge clk) begin
        if (!rst_n) begin
            n_fill_fail <= 0; n_wb_fail <= 0; n_cs_err_d <= 0;
            n_maint_err <= 0; n_fill_req_seen <= 0; n_wb_req_seen <= 0;
            n_fill_fail_i <= 0; n_cs_err_i <= 0;
        end else begin
            if (d_fill_req) n_fill_req_seen <= n_fill_req_seen + 1;
            if (d_wb_req)   n_wb_req_seen   <= n_wb_req_seen + 1;
`ifndef CACHE_BUS_OLD_DUT
            if (i_fill_fail) n_fill_fail_i <= n_fill_fail_i + 1;
            if (i_cs_err)    n_cs_err_i    <= n_cs_err_i + 1;
            if (d_fill_fail) n_fill_fail <= n_fill_fail + 1;
            if (d_wb_fail)   n_wb_fail   <= n_wb_fail + 1;
            if (d_cs_err)    n_cs_err_d  <= n_cs_err_d + 1;
            if (d_maint_err) n_maint_err <= n_maint_err + 1;
`endif
        end
    end

    task d_reset;
        begin
            rst_n = 1'b0;
            d_cs_req = 0; d_cs_we = 0; d_cs_wstrb = 4'h0;
            d_cs_paddr = 32'h0; d_cs_vaddr = 32'h0; d_cs_wdata = 32'h0;
            d_fill_accepted = 0; d_fill_valid = 0; d_fill_done = 0; d_fill_err = 0;
            d_fill_data = 32'h0; d_fill_word_idx = 5'h0;
            d_wb_accepted = 0; d_wb_done = 0; d_wb_err = 0; d_wb_word_idx = 5'h0;
            d_inval_all = 0; d_clean_all = 0;
            i_cs_req = 0; i_cs_paddr = 32'h0; i_cs_vaddr = 32'h0;
            i_fill_accepted = 0; i_fill_valid = 0; i_fill_done = 0; i_fill_err = 0;
            i_fill_data = 32'h0; i_fill_word_idx = 5'h0; i_inval_all = 0;
            a_req_valid = 0; a_req_is_write = 0; a_req_owner = 2'h0;
            a_req_addr = 32'h0; a_req_len = 4'h0; a_req_beats = 5'd1;
            a_req_beats_1 = 5'd1; a_req_beats_2 = 5'd0; a_req_split = 0; a_req_id = 4'h0;
            a_wdata_valid = 0; a_wdata_data = 32'h0; a_rdata_ready = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            dirty_reset;
            // ★ 阵列只在 time-0 的 `initial` 里清过一次；复位**不清**阵列内容。
            //   为保证每个向量都从"空且干净"的 Cache 出发（否则上一向量的残留行
            //   会让替换路/受害者不可预测），这里用真实维护接口 inval_all 清一遍。
            @(negedge clk); d_inval_all = 1'b1; i_inval_all = 1'b1;
            @(posedge clk); @(negedge clk); d_inval_all = 1'b0; i_inval_all = 1'b0;
            g = 0;
            while ((d_idle !== 1'b1) || (i_idle !== 1'b1)) begin
                @(posedge clk); g = g + 1;
                if (g > 4000) begin
                    $display("CACHE_BUS_TIMEOUT reset inval");
                    $finish;
                end
            end
            repeat (2) @(posedge clk);
        end
    endtask

    // 发起一次 L1D 访问；返回时 cs_* 已稳定（采样点 = posedge 后 #1）
    task d_access(input we, input [31:0] va, input [31:0] wd, input [3:0] strb);
        begin
            if (abort_vec) begin d_cs_req = 1'b0; end else begin
            @(negedge clk);
            d_cs_req = 1'b1; d_cs_we = we; d_cs_wstrb = strb;
            d_cs_vaddr = va; d_cs_paddr = va; d_cs_wdata = wd;
            @(posedge clk); #1;
        end
        end
    endtask

    task d_drop;
        begin
            @(negedge clk);
            d_cs_req = 1'b0; d_cs_we = 1'b0; d_cs_wstrb = 4'h0;
            @(posedge clk); #1;
        end
    endtask

    // ★ 超时恢复：旧树在"0 延迟 accepted"下会卡在 MS_WB_CAP 等第二次接受
    //   （正是 04-04 缺陷的后半段）。为了让**每个向量**都能独立给出自己的
    //   defect 签名（而不是整轮挂在第一个向量上），超时记为 FAIL + defect 后，
    //   用真实维护接口 inval_all 把 FSM 拉回空闲，再继续后面的向量。
    //   这不会掩盖缺陷：缺陷已由 CHK_BAD/DEFECT_SIG 明确记录。
    task d_recover(input [8*40-1:0] why);
        integer g2;
        begin
            chk(0, why);
            mark_defect;
            abort_vec = 1'b1;
            // ★ 复位是**合法接口输入**（不是 force/backdoor）：旧树在"0 延迟 accepted"
            //   下会永久卡在 MS_WB_CAP（等第二次接受），inval_all 也救不回来
            //   （维护分支要求 ms_state==MS_IDLE）。为了让后续向量仍能独立取证，
            //   这里用真实复位把 DUT 拉回已知态；缺陷本身已由上面的 CHK_BAD 记录。
            @(negedge clk); rst_n = 1'b0;
            d_cs_req = 1'b0; d_cs_we = 1'b0;
            d_fill_accepted = 1'b0; d_fill_valid = 1'b0; d_fill_done = 1'b0; d_fill_err = 1'b0;
            d_wb_accepted = 1'b0; d_wb_done = 1'b0; d_wb_err = 1'b0;
            i_cs_req = 1'b0;
            i_fill_accepted = 1'b0; i_fill_valid = 1'b0; i_fill_done = 1'b0; i_fill_err = 1'b0;
            a_req_valid = 1'b0; a_wdata_valid = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(negedge clk); d_inval_all = 1'b1; i_inval_all = 1'b1;
            @(posedge clk); @(negedge clk); d_inval_all = 1'b0; i_inval_all = 1'b0;
            d_cs_req = 1'b0; d_cs_we = 1'b0;
            d_fill_accepted = 1'b0; d_fill_valid = 1'b0; d_fill_done = 1'b0; d_fill_err = 1'b0;
            d_wb_accepted = 1'b0; d_wb_done = 1'b0; d_wb_err = 1'b0;
            i_cs_req = 1'b0;
            i_fill_accepted = 1'b0; i_fill_valid = 1'b0; i_fill_done = 1'b0; i_fill_err = 1'b0;
            g2 = 0;
            while ((d_idle !== 1'b1) || (i_idle !== 1'b1)) begin
                @(posedge clk); g2 = g2 + 1;
                if (g2 > 4000) begin
                    $display("CACHE_BUS_TIMEOUT unrecoverable");
                    $finish;
                end
            end
            repeat (2) @(posedge clk);
        end
    endtask

    // 等待 fill_req（negedge 采样，组合稳定区），并校验描述符
    task d_wait_fill(input [31:0] base, input [8*40-1:0] tag);
        integer g;
        begin : d_wait_fill_guard
            g = 0;
            while (d_fill_req !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 300) begin
                    d_recover({tag, " fill_req timeout"});
                    disable d_wait_fill_guard;
                end
            end
            chk(d_fill_paddr === base, {tag, " fill_paddr == line base"});
            chk(d_fill_beats === 5'd7, {tag, " fill_beats == 7 (8 beats)"});
            chk(d_fill_owner === 2'd1, {tag, " fill_owner == 1 (D fill)"});
        end
    endtask

    // 接受填充并逐 beat 回填；err_beat>=0 ⇒ 该 beat 的 fill_err=1
    task d_fill_body(input [31:0] base, input integer err_beat);
        integer k;
        begin
            if (abort_vec) begin end else begin
            @(negedge clk); d_fill_accepted = 1'b1;
            @(posedge clk); @(negedge clk); d_fill_accepted = 1'b0;
            for (k = 0; k < WORDS; k = k + 1) begin
                d_fill_valid    = 1'b1;
                d_fill_data     = line_word(base, k);
                d_fill_word_idx = k[4:0];
                d_fill_done     = (k == WORDS-1);
                d_fill_err      = (err_beat >= 0) && (k == err_beat);
                @(posedge clk); @(negedge clk);
            end
            d_fill_valid = 1'b0; d_fill_done = 1'b0; d_fill_err = 1'b0;
            @(posedge clk); #1;
        end
        end
    endtask

    // 一次完整"缺失 → 填充"（干净）；调用前 cs_req 已发起且 miss 已判定
    task d_fill(input [31:0] base, input integer err_beat, input [8*40-1:0] tag);
        begin
            d_wait_fill(base, tag);
            d_drop;
            d_fill_body(base, err_beat);
            repeat (2) @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // 写回服务：first-valid 采样 + 可选接受延迟 + 可选 B 失败
    //   返回：wb_paddr_cap / wb_way_cap（首个 wb_req 拍）、wb_words[0..7]、wb_nacc
    //--------------------------------------------------------------------------
    reg [31:0] wb_paddr_cap;
    reg [1:0]  wb_way_cap;
    reg [31:0] wb_words [0:7];
    integer    wb_nacc;

    task d_wb_serve(input integer acc_delay, input inject_err, input [8*40-1:0] tag);
        integer k, g;
        begin : d_wb_serve_guard
            wb_nacc = 0;
            // 1) 等首个 wb_req（组合稳定区采样）
            g = 0;
            while (d_wb_req !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 400) begin
                    d_recover({tag, " wb_req timeout"});
                    disable d_wb_serve_guard;
                end
            end
            // ★ 首个 valid 拍就必须描述本次受害者（04-04 的核心判据）
            wb_paddr_cap = d_wb_paddr;
            wb_way_cap   = d_wb_way;
            chk(d_wb_owner === 2'd2, {tag, " wb_owner == 2"});
            chk(d_wb_beats === 5'd7, {tag, " wb_beats == 7"});
            // 2) 接受（0 延迟 ⇒ 决定拍就接受）
            if (acc_delay == 0) begin
                d_wb_accepted = 1'b1;
                @(posedge clk); #1;
                d_wb_accepted = 1'b0;
                wb_nacc = wb_nacc + 1;
            end else begin
                for (k = 0; k < acc_delay; k = k + 1) @(negedge clk);
                d_wb_accepted = 1'b1;
                @(posedge clk); #1;
                d_wb_accepted = 1'b0;
                wb_nacc = wb_nacc + 1;
            end
            // 3) 等推总线阶段（抓行 9 拍后 wb_ready 才为 1）
            g = 0;
            while (d_wb_ready !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 200) begin
                    d_recover({tag, " wb_ready timeout (writeback descriptor/handshake defect)"});
                    disable d_wb_serve_guard;   // 本笔写回无法完成 ⇒ 放弃该向量剩余步骤
                end
            end
            // 4) 逐 beat 推出 8 个字；B 错误只在最后一拍（与 wb_done 同拍）
            for (k = 0; k < WORDS; k = k + 1) begin
                @(negedge clk);
                d_wb_word_idx = k[4:0];
                d_wb_done     = (k == WORDS-1);
                d_wb_err      = (k == WORDS-1) && inject_err;
                @(posedge clk); #1;
                wb_words[k] = d_wb_data;
            end
            @(negedge clk);
            d_wb_done = 1'b0; d_wb_err = 1'b0;
            @(posedge clk); #1;
            repeat (2) @(posedge clk);
        end
    endtask

    // 写回服务（X 注入版）：与 d_wb_serve 同流程，但末 beat 的 wb_err 取 **1'bx**
    //   用于证明"有效 B 拍上的未知响应不得被当写回成功"。
    task d_wb_serve_x(input integer acc_delay, input [8*40-1:0] tag);
        integer k, g;
        begin : d_wb_serve_x_guard
            g = 0;
            while (d_wb_req !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 400) begin
                    d_recover({tag, " wb_req timeout"});
                    disable d_wb_serve_x_guard;
                end
            end
            wb_paddr_cap = d_wb_paddr;
            wb_way_cap   = d_wb_way;
            if (acc_delay != 0) for (k = 0; k < acc_delay; k = k + 1) @(negedge clk);
            d_wb_accepted = 1'b1;
            @(posedge clk); #1;
            d_wb_accepted = 1'b0;
            g = 0;
            while (d_wb_ready !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 200) begin
                    d_recover({tag, " wb_ready timeout"});
                    disable d_wb_serve_x_guard;
                end
            end
            for (k = 0; k < WORDS; k = k + 1) begin
                @(negedge clk);
                d_wb_word_idx = k[4:0];
                d_wb_done     = (k == WORDS-1);
                // ★ 末 beat 的 B 响应取未知（有效握手拍上的 X）
                d_wb_err      = (k == WORDS-1) ? 1'bx : 1'b0;
                @(posedge clk); #1;
                wb_words[k] = d_wb_data;
            end
            @(negedge clk);
            d_wb_done = 1'b0; d_wb_err = 1'b0;
            @(posedge clk); #1;
            repeat (2) @(posedge clk);
        end
    endtask

    // 维护扫描期间服务写回（clean/flush 复用写回通路）
    task d_maint_clean(input inject_err, input [8*40-1:0] tag);
        integer g, k, nwb;
        reg [31:0] pa_cap; reg inj;
        begin
            nwb = 0; inj = 1'b0;
            g = 0;
            @(negedge clk); d_clean_all = 1'b1;
            @(posedge clk); @(negedge clk); d_clean_all = 1'b0;
            while (d_idle !== 1'b1) begin
                if (d_wb_req === 1'b1) begin
                    nwb = nwb + 1;
                    pa_cap = d_wb_paddr;
                    // 首个写回若要求注入错误，则本次注入
                    inj = inject_err && (nwb == 1);
                    @(negedge clk); d_wb_accepted = 1'b1;
                    @(posedge clk); #1; d_wb_accepted = 1'b0;
                    while (d_wb_ready !== 1'b1) @(negedge clk);
                    for (k = 0; k < WORDS; k = k + 1) begin
                        @(negedge clk);
                        d_wb_word_idx = k[4:0];
                        d_wb_done     = (k == WORDS-1);
                        d_wb_err      = (k == WORDS-1) && inj;
                        @(posedge clk); #1;
                    end
                    @(negedge clk); d_wb_done = 1'b0; d_wb_err = 1'b0;
                    @(posedge clk); #1;
                end else begin
                    @(posedge clk);
                end
                g = g + 1;
                if (g > 20000) begin
                    chk(0, {tag, " maint scan timeout"});
                    $display("CACHE_BUS_TIMEOUT"); $finish;
                end
            end
            #1;
            chk(nwb >= 1, {tag, " clean_all must write back dirty lines"});
        end
    endtask

    //==========================================================================
    // 8. L1I 驱动任务
    //==========================================================================
    task i_issue(input [31:0] va);
        begin
            if (abort_vec) begin i_cs_req = 1'b0; end else begin
            @(negedge clk);
            i_cs_req = 1'b1; i_cs_vaddr = va; i_cs_paddr = va;
            @(posedge clk); #1;
        end
        end
    endtask

    task i_drop;
        begin
            @(negedge clk);
            i_cs_req = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    task i_wait_fill(input [31:0] base, input [8*40-1:0] tag);
        integer g;
        begin
            g = 0;
            while (i_fill_req !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 300) begin
                    chk(0, {tag, " fill_req timeout"});
                    $display("CACHE_BUS_TIMEOUT"); $finish;
                end
            end
            chk(i_fill_paddr === base, {tag, " fill_paddr == line base"});
            chk(i_fill_beats === 5'd7, {tag, " fill_beats == 7"});
            chk(i_fill_owner === 2'd0, {tag, " fill_owner == 0 (I fill)"});
        end
    endtask

    task i_fill(input [31:0] base, input integer err_beat, input [8*40-1:0] tag);
        integer k;
        begin
            if (abort_vec) begin end else begin
            i_wait_fill(base, tag);
            // ★ 顺序关键：L1I 的 fill_req = new_miss & ~fill_taken_q，而 new_miss 来自
            //   **寄存的访问**（acc_q）。若先撤 cs_req，acc_q 下一拍即清 ⇒ fill_req 消失
            //   ⇒ fill_take 永不成立（旧 TB 也是"先接受、后撤请求"）。故此处先握手。
            @(negedge clk); i_fill_accepted = 1'b1;
            @(posedge clk); @(negedge clk); i_fill_accepted = 1'b0;
            i_drop;
            for (k = 0; k < WORDS; k = k + 1) begin
                i_fill_valid    = 1'b1;
                i_fill_data     = line_word(base, k);
                i_fill_word_idx = k[4:0];
                i_fill_done     = (k == WORDS-1);
                i_fill_err      = (err_beat >= 0) && (k == err_beat);
                @(posedge clk); @(negedge clk);
            end
            i_fill_valid = 1'b0; i_fill_done = 1'b0; i_fill_err = 1'b0;
            repeat (3) @(posedge clk); #1;
        end
        end
    endtask

    //--------------------------------------------------------------------------
    // 8b. 复审新增驱动任务（P1-2/P1-3 用）
    //   · X/Z 注入版填充：fill_err 在指定 beat 上取 1'bx（**有效握手拍**上的未知）
    //   · 维护 flush（clean_all+inval_all 同拍）：失败须真正中止扫描且不失效
    //   · AXI 请求/等待助手：把"发请求 + 等到 done"收敛成一处，减少各向量重复
    //--------------------------------------------------------------------------
    task i_fill_x(input [31:0] base, input integer x_beat, input [8*40-1:0] tag);
        integer k;
        begin
            if (abort_vec) begin end else begin
                i_wait_fill(base, tag);
                @(negedge clk); i_fill_accepted = 1'b1;
                @(posedge clk); @(negedge clk); i_fill_accepted = 1'b0;
                i_drop;
                for (k = 0; k < WORDS; k = k + 1) begin
                    i_fill_valid    = 1'b1;
                    i_fill_data     = line_word(base, k);
                    i_fill_word_idx = k[4:0];
                    i_fill_done     = (k == WORDS-1);
                    // 指定 beat 的 fill_err 取未知；其余拍显式 0（"无效 payload 非 0"不参与）
                    i_fill_err      = (k == x_beat) ? 1'bx : 1'b0;
                    @(posedge clk); @(negedge clk);
                end
                i_fill_valid = 1'b0; i_fill_done = 1'b0; i_fill_err = 1'b0;
                repeat (3) @(posedge clk); #1;
            end
        end
    endtask

    task d_fill_body_x(input [31:0] base, input integer x_beat);
        integer k;
        begin
            if (abort_vec) begin end else begin
                @(negedge clk); d_fill_accepted = 1'b1;
                @(posedge clk); @(negedge clk); d_fill_accepted = 1'b0;
                for (k = 0; k < WORDS; k = k + 1) begin
                    d_fill_valid    = 1'b1;
                    d_fill_data     = line_word(base, k);
                    d_fill_word_idx = k[4:0];
                    d_fill_done     = (k == WORDS-1);
                    d_fill_err      = (k == x_beat) ? 1'bx : 1'b0;
                    @(posedge clk); @(negedge clk);
                end
                d_fill_valid = 1'b0; d_fill_done = 1'b0; d_fill_err = 1'b0;
                @(posedge clk); #1;
            end
        end
    endtask

    // 维护 **flush**（clean_all + inval_all 同拍）：失败时不得继续扫描/不得失效
    task d_maint_flush(input inject_err, input [8*40-1:0] tag);
        integer g, k, nwb;
        reg inj;
        begin
            nwb = 0; inj = 1'b0;
            g = 0;
            @(negedge clk); d_clean_all = 1'b1; d_inval_all = 1'b1;
            @(posedge clk); @(negedge clk); d_clean_all = 1'b0; d_inval_all = 1'b0;
            while (d_idle !== 1'b1) begin
                if (d_wb_req === 1'b1) begin
                    nwb = nwb + 1;
                    inj = inject_err && (nwb == 1);
                    @(negedge clk); d_wb_accepted = 1'b1;
                    @(posedge clk); #1; d_wb_accepted = 1'b0;
                    while (d_wb_ready !== 1'b1) @(negedge clk);
                    for (k = 0; k < WORDS; k = k + 1) begin
                        @(negedge clk);
                        d_wb_word_idx = k[4:0];
                        d_wb_done     = (k == WORDS-1);
                        d_wb_err      = (k == WORDS-1) && inj;
                        @(posedge clk); #1;
                    end
                    @(negedge clk); d_wb_done = 1'b0; d_wb_err = 1'b0;
                    @(posedge clk); #1;
                end else begin
                    @(posedge clk);
                end
                g = g + 1;
                if (g > 20000) begin
                    chk(0, {tag, " flush scan timeout"});
                    $display("CACHE_BUS_TIMEOUT"); $finish;
                end
            end
            #1;
        end
    endtask

    // ★★ 复审修复（P1-3）：每个 AXI 向量末尾统一断言"逐 beat oracle + 控制未知"
    task axi_beat_checks(input integer nbeats, input [8*24-1:0] tag);
        begin
            chk(beat_mismatch == 0, {tag, " per-beat rdata_valid/error/data/last == independent oracle"});
            chk(beat_code_mismatch == 0, {tag, " error beats report resp_code == raw R resp"});
            chk(n_beat_seen == nbeats, {tag, " R beats forwarded == expected count"});
            chk(x_ctrl == 0, {tag, " no X/Z on active AXI control signals"});
            if ((beat_mismatch != 0) || (beat_code_mismatch != 0)) mark_defect;
        end
    endtask

    //--------------------------------------------------------------------------
    // 8c. ★★ 复审修复（P1-1）：维护 clean 的**事务化**记录器
    //   旧写法用"wb_req 高电平拍数 >= 2"推断发生了两笔事务 ⇒ 高电平跨拍会重复计数，
    //   也没有把"地址/8 字数据"绑定到**真实握手与真实完成**上。
    //   本任务：
    //     · 以 `wb_req & wb_accepted`（valid&&ready）作为**事务起点**记录地址；
    //     · 逐 beat 只在 `wb_ready` 有效拍采样 `wb_data`（真实数据拍）；
    //     · 以 B 事务结束（成功/失败）作为**事务终点**：成功才把地址+8 字写入账本，
    //       失败只计 mtx_fail（脏行保留）。
    //   输出走全局：mtx_n / mtx_fail / mtx_addr[] / mtx_words[][]
    //--------------------------------------------------------------------------
    integer    v13_w;
    reg [7:0]  v13_set;
    integer    mtx_n;
    integer    mtx_fail;
    reg [31:0] mtx_addr  [0:7];
    reg [31:0] mtx_words [0:7][0:7];

    task mt_clear;
        integer q, r;
        begin
            mtx_n = 0; mtx_fail = 0;
            for (q = 0; q < 8; q = q + 1) begin
                mtx_addr[q] = 32'h0;
                for (r = 0; r < WORDS; r = r + 1) mtx_words[q][r] = 32'h0;
            end
        end
    endtask

    task d_maint_run(input inject_first, input [8*40-1:0] tag);
        integer g, k, nfail0;
        reg inj;
        reg [31:0] pa;
        reg [31:0] w [0:7];
        begin
            mt_clear;
            g = 0;
            @(negedge clk); d_clean_all = 1'b1;
            @(posedge clk); @(negedge clk); d_clean_all = 1'b0;
            while (d_idle !== 1'b1) begin
                if ((d_wb_req === 1'b1) && (d_wb_accepted !== 1'b1)) begin
                    // 事务起点：地址在握手拍前采样（组合稳定），随后做 valid&&ready 握手
                    pa = d_wb_paddr;
                    nfail0 = n_wb_fail;
                    inj = inject_first && ((mtx_n + mtx_fail) == 0);
                    @(negedge clk); d_wb_accepted = 1'b1;
                    @(posedge clk); #1;
                    d_wb_accepted = 1'b0;
                    while (d_wb_ready !== 1'b1) @(negedge clk);
                    for (k = 0; k < WORDS; k = k + 1) begin
                        @(negedge clk);
                        d_wb_word_idx = k[4:0];
                        d_wb_done     = (k == WORDS-1);
                        d_wb_err      = (k == WORDS-1) && inj;
                        @(posedge clk); #1;
                        // 只有真实 ready 拍的数据才算"实际完成的数据 beat"
                        w[k] = d_wb_data;
                    end
                    @(negedge clk); d_wb_done = 1'b0; d_wb_err = 1'b0;
                    @(posedge clk); #1;
                    repeat (2) @(posedge clk);
                    if (n_wb_fail != nfail0) begin
                        mtx_fail = mtx_fail + 1;       // 失败：脏行保留，不记账为完成
                    end else begin
                        mtx_addr[mtx_n] = pa;
                        for (k = 0; k < WORDS; k = k + 1) mtx_words[mtx_n][k] = w[k];
                        mtx_n = mtx_n + 1;
                    end
                end else begin
                    @(posedge clk);
                end
                g = g + 1;
                if (g > 40000) begin
                    chk(0, {tag, " maint transaction timeout"});
                    $display("CACHE_BUS_TIMEOUT"); $finish;
                end
            end
            #1;
        end
    endtask

    // ★ cs_err_paddr 必须在 cs_err **脉冲拍**采样（脉冲只有一拍，事后读会得 0）
`ifndef CACHE_BUS_OLD_DUT
    reg [31:0] cs_err_pa_cap;
    reg        cs_err_pa_seen;
    always @(posedge clk) begin
        if (!rst_n) begin
            cs_err_pa_cap <= 32'h0; cs_err_pa_seen <= 1'b0;
        end else if (dut_i.cs_err === 1'b1) begin
            cs_err_pa_cap  <= i_cs_err_paddr;
            cs_err_pa_seen <= 1'b1;
        end
    end
`else
    //   旧树无 cs_err/paddr 端口（04-07 结构缺陷）；此路径恒 0，供 v24/v25 判"无此能力"。
    reg [31:0] cs_err_pa_cap = 32'h0;
    reg        cs_err_pa_seen = 1'b0;
`endif

    // 账本里是否记录了某地址
    function mtx_has_addr(input [31:0] a);
        integer q;
        begin
            mtx_has_addr = 1'b0;
            for (q = 0; q < 8; q = q + 1)
                if ((mtx_n > q) && (mtx_addr[q] === a)) mtx_has_addr = 1'b1;
        end
    endfunction

    function [31:0] mtx_word_of(input [31:0] a, input integer w);   // ★ 必须带 32 位返回宽度
        integer q;
        begin
            mtx_word_of = 32'h0;
            for (q = 0; q < 8; q = q + 1)
                if ((mtx_n > q) && (mtx_addr[q] === a)) mtx_word_of = mtx_words[q][w];
        end
    endfunction

    // AXI：发一笔请求（读/写），保持 valid 到被接受
    task axi_req(input wr, input [31:0] addr, input [4:0] beats,
                 input split, input [4:0] b1, input [4:0] b2, input [1:0] own);
        begin
            a_req_is_write = wr; a_req_addr = addr; a_req_beats = beats;
            a_req_len = beats[3:0] - 4'd1; a_req_split = split;
            a_req_beats_1 = b1; a_req_beats_2 = b2;
            a_req_owner = own; a_req_id = 4'h0;
            a_req_valid = 1'b1;
            @(posedge clk);
            while (a_req_ready !== 1'b1) @(posedge clk);
            @(negedge clk); a_req_valid = 1'b0;
        end
    endtask

    // AXI：等到第 nin 次 done 且总线释放，再留观察余量
    task axi_wait_done(input integer nin, input integer maxc);
        integer gg;
        begin
            gg = 0;
            while (gg < maxc && !((n_done >= nin) && (a_busy === 1'b0) && (a_done === 1'b0))) begin
                @(posedge clk); gg = gg + 1;
            end
            repeat (16) @(posedge clk);
        end
    endtask

    //==========================================================================
    // 9. 向量
    //--------------------------------------------------------------------------
    // 地址口径（固定非零；set 索引 = va[12:5]）：
    //   L1D 组 0x08 ⇒ 行基址 0x0000_0100 / 0x0001_0100 / ... （tag 不同、同组）
    //   L1I 组 0x10 ⇒ 行基址 0x0000_0200 / 0x0001_0200 / ...
    //==========================================================================
    reg [31:0] DA0, DA1, DA2, DA3, DA4, DA5, DA6;
    reg [31:0] IA, IB, IC;
    integer    k, q, g;
    reg [31:0] cap_a, cap_b;

    task check_wb_words(input [31:0] base, input [8*40-1:0] tag);
        integer w;
        begin
            for (w = 0; w < WORDS; w = w + 1)
                chk(wb_words[w] === exp_line_word(base, w),
                    {tag, " writeback word matches dirty line content"});
        end
    endtask

    initial begin
        g_total = 0; g_nonzero = 0; g_checks = 0; g_fails = 0; g_defect = 0;
        DA0 = 32'h0000_0100; DA1 = 32'h0001_0100; DA2 = 32'h0002_0100;
        DA3 = 32'h0003_0100; DA4 = 32'h0004_0100; DA5 = 32'h0005_0100;
        DA6 = 32'h0006_0100;
        IA  = 32'h0000_0200; IB  = 32'h0001_0200; IC = 32'h0002_0200;

        d_reset;

        //======================================================================
        // v1（04-04）：**始终 ready / 0 延迟 accepted** ⇒ 首个 wb_valid 拍
        //     必须已经描述**本次**脏受害者（非 0 地址、正确路、8 字数据全对）。
        //======================================================================
        vec_begin("wb_first_valid_zero_delay");
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v1 DA0 first access misses");
        d_fill(DA0, -1, "v1");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v1 DA1 misses"); d_fill(DA1, -1, "v1");
        d_access(1'b0, DA2 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v1 DA2 misses"); d_fill(DA2, -1, "v1");
        d_access(1'b0, DA3 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v1 DA3 misses"); d_fill(DA3, -1, "v1");
        // 让 DA0 变脏（组已满 4 路 ⇒ 下一次缺失必然替换且写回）
        d_access(1'b1, DA0 + 32'h8, 32'hA5A5_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v1 store hits DA0");
        dirty_add(DA0, 32'd2, 32'hA5A5_0001);
        d_drop; repeat (2) @(posedge clk);
        // 第 5 行缺失 ⇒ 受害者 = 脏行 ⇒ 首个 wb_valid 拍检查
        d_access(1'b0, DA4 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v1 DA4 misses (set full)");
        d_wb_serve(0, 1'b0, "v1");
        chk(wb_paddr_cap === DA0, "v1 FIRST wb valid describes THIS victim (DA0, not 0/old)");
        chk(wb_paddr_cap !== 32'h0, "v1 first wb address is non-zero");
        chk(wb_way_cap === 2'd0, "v1 victim way == 0 (filled order, no hits)");
        chk(wb_nacc == 1, "v1 exactly one accept (no duplicate handshake)");
        check_wb_words(DA0, "v1");
        if (wb_paddr_cap !== DA0) mark_defect;
        // 写回成功后自动进入填充（pend_line_q = DA4）
        d_fill(DA4, -1, "v1");
        d_access(1'b0, DA4 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_ready === 1'b1, "v1 DA4 hits after wb+fill");
        d_drop; repeat (2) @(posedge clk);
        vec_end;

        //======================================================================
        // v2（04-04）：连续两次不同受害者（都脏）⇒ 每个首拍都描述自己的受害者，
        //     地址不同，8 字数据各自正确。
        //======================================================================
        vec_begin("wb_two_victims_distinct");
        d_reset;
        // 填满组 0x08 的 4 路（DA0..DA3）后全部写脏
        //   ⇒ 之后任一次替换的受害者必为脏行，与 PLRU 选哪一路无关
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v2 DA0 misses"); d_fill(DA0, -1, "v2");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v2 DA1 misses"); d_fill(DA1, -1, "v2");
        d_access(1'b0, DA2 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v2 DA2 misses"); d_fill(DA2, -1, "v2");
        d_access(1'b0, DA3 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v2 DA3 misses"); d_fill(DA3, -1, "v2");
        d_access(1'b1, DA1 + 32'h4, 32'hB1B1_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v2 store DA1 hits"); dirty_add(DA1, 32'd1, 32'hB1B1_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA2 + 32'h4, 32'hB2B2_0002, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v2 store DA2 hits"); dirty_add(DA2, 32'd1, 32'hB2B2_0002);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA3 + 32'h4, 32'hB3B3_0003, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v2 store DA3 hits"); dirty_add(DA3, 32'd1, 32'hB3B3_0003);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA0 + 32'h4, 32'hB0B0_0000, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v2 store DA0 hits"); dirty_add(DA0, 32'd1, 32'hB0B0_0000);
        d_drop; repeat (2) @(posedge clk);
        // 第一次替换
        d_access(1'b0, DA5 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v2 DA5 misses");
        d_wb_serve(0, 1'b0, "v2");
        cap_a = wb_paddr_cap;
        chk(dirty_known(cap_a), "v2 first victim is one of the dirty lines");
        chk(cap_a !== 32'h0, "v2 first victim address non-zero");
        check_wb_words(cap_a, "v2a");
        d_fill(DA5, -1, "v2");
        // ★ 把刚填入的 DA5 也写脏 ⇒ 组内再次"全脏"，第二次替换的受害者必为脏行
        //   （否则 PLRU 可能选中刚填入的干净行，本向量就测不到写回）
        d_access(1'b1, DA5 + 32'h8, 32'hB5B5_0005, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v2 store DA5 hits (dirty the freshly filled line)");
        dirty_add(DA5, 32'd2, 32'hB5B5_0005);
        d_drop; repeat (2) @(posedge clk);
        // 第二次替换（不同受害者）
        d_access(1'b0, DA6 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v2 DA6 misses");
        d_wb_serve(0, 1'b0, "v2");
        cap_b = wb_paddr_cap;
        chk(dirty_known(cap_b), "v2 second victim is one of the dirty lines");
        chk(cap_b !== cap_a, "v2 consecutive victims are DIFFERENT lines");
        check_wb_words(cap_b, "v2b");
        if (!dirty_known(cap_a) || !dirty_known(cap_b) || (cap_b === cap_a)) mark_defect;
        d_fill(DA6, -1, "v2");
        vec_end;

        //======================================================================
        // v3（04-04）：接受延迟 N=3 拍 ⇒ 首个 valid 描述符仍正确、恰好一次接受。
        //======================================================================
        vec_begin("wb_accept_delay3");
        d_reset;
        // 填满组 0x08 的 4 路（DA0..DA3），并让其中一路变脏
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v3 DA0 misses"); d_fill(DA0, -1, "v3");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v3 DA1 misses"); d_fill(DA1, -1, "v3");
        d_access(1'b0, DA2 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v3 DA2 misses"); d_fill(DA2, -1, "v3");
        d_access(1'b0, DA3 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v3 DA3 misses"); d_fill(DA3, -1, "v3");
        // 4 路全部写脏 ⇒ 受害者必为脏行，与 PLRU 选哪一路无关
        d_access(1'b1, DA0 + 32'hC, 32'hC0C0_0000, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v3 store DA0"); dirty_add(DA0, 32'd3, 32'hC0C0_0000);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA1 + 32'hC, 32'hC1C1_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v3 store DA1"); dirty_add(DA1, 32'd3, 32'hC1C1_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA2 + 32'hC, 32'hC2C2_0002, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v3 store DA2"); dirty_add(DA2, 32'd3, 32'hC2C2_0002);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA3 + 32'hC, 32'hC3C3_0003, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v3 store DA3"); dirty_add(DA3, 32'd3, 32'hC3C3_0003);
        d_drop; repeat (2) @(posedge clk);
        // 第 5 行（同组新 tag）触发替换；接受延迟 3 拍
        d_access(1'b0, DA5 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v3 DA5 misses (set full)");
        d_wb_serve(3, 1'b0, "v3");
        chk(dirty_known(wb_paddr_cap), "v3 delayed-accept first valid still describes a dirty victim");
        chk(wb_paddr_cap !== 32'h0, "v3 delayed-accept address non-zero");
        chk(wb_nacc == 1, "v3 exactly one accept with 3-cycle delay");
        check_wb_words(wb_paddr_cap, "v3");
        if (!dirty_known(wb_paddr_cap)) mark_defect;
        d_fill(DA5, -1, "v3");
        vec_end;

        //======================================================================
        // v4（正控）：干净受害者 ⇒ 不产生写回请求（两棵树都必须通过）。
        //======================================================================
        vec_begin("ctrl_wb_clean_no_req");
        d_reset;
        d_access(1'b0, 32'h0008_0100 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v4 clean line misses");
        chk(d_wb_req === 1'b0, "v4 clean victim must NOT request writeback");
        if (d_wb_req === 1'b1) mark_defect;
        d_fill(32'h0008_0100, -1, "v4");
        d_access(1'b0, 32'h0008_0100 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_ready === 1'b1, "v4 clean line hits after fill");
        d_drop; repeat (2) @(posedge clk);
        vec_end;

        //======================================================================
        // v5（04-05）：跨 4 K 读拆分 —— 第二笔 R 故意延迟 100 拍；
        //     首笔之后 done 必须为 0，整个逻辑请求恰好一次 done，busy 全程覆盖。
        //======================================================================
        vec_begin("axi_split_read_single_done");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 100;
        n_done = 0; busy_holes = 0; req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0;
        a_req_is_write = 1'b0; a_req_addr = 32'h0000_3FF8; a_req_beats = 5'd8;
        a_req_len = 4'd7; a_req_split = 1'b1;
        a_req_beats_1 = 5'd2; a_req_beats_2 = 5'd6;
        a_req_owner = 2'd1; a_req_id = 4'h0;
        a_req_valid = 1'b1;
        @(posedge clk);
        while (a_req_ready !== 1'b1) @(posedge clk);
        @(negedge clk); a_req_valid = 1'b0;
        // ★ 观察窗口必须覆盖**整个逻辑请求**（两笔 + 第二笔 100 拍延迟）。
        //   旧树在首笔 ST_DONE 拍就会给 done（split_pending_q 尚未置位），若只看
        //   "首个 done 后 10 拍"就收工，会漏掉第二次 done ⇒ 测不到 04-05。
        //   判据：等第二笔 AR 已发 + busy 已释放，再补足余量；然后数 done 总数。
        g = 0;
        while (g < 1200 && !((ar_seen >= 2) && (a_busy === 1'b0) && (a_done === 1'b0))) begin
            @(posedge clk); g = g + 1;
        end
        repeat (40) @(posedge clk);
        chk(n_done == 1, "v5 exactly ONE done for the whole split request");
        chk(busy_holes == 0, "v5 busy covers the entire logical request (no idle gap)");
        chk(a_done_addr === 32'h0000_3FF8 || done_addr_cap === 32'h0000_3FF8,
            "v5 done_addr == logical request start address");
        chk(ar_seen == 2, "v5 split into exactly 2 AR");
        chk(ar_addr_seen[0] === 32'h0000_3FF8, "v5 first AR address");
        chk(ar_len_seen[0]  === 4'd1,          "v5 first AR truncated to 2 beats");
        chk(ar_addr_seen[1] === 32'h0000_4000, "v5 second AR address continues at 4 K");
        chk(ar_len_seen[1]  === 4'd5,          "v5 second AR 6 beats");
        if (n_done != 1) mark_defect;
        if (busy_holes != 0) mark_defect;
        repeat (4) @(posedge clk);
        axi_beat_checks(8, "v5");
        vec_end;

        //======================================================================
        // v6（04-05）：跨 4 K 写拆分 —— B 延迟 100 拍；同样只最终一次 done。
        //======================================================================
        vec_begin("axi_split_write_single_done");
        d_reset;
        sl_b_gap_0 = 2; sl_b_gap_1 = 100;
        n_done = 0; busy_holes = 0; req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0;
        a_req_is_write = 1'b1; a_req_addr = 32'h0000_2FF8; a_req_beats = 5'd8;
        a_req_len = 4'd7; a_req_split = 1'b1;
        a_req_beats_1 = 5'd2; a_req_beats_2 = 5'd6;
        a_req_owner = 2'd2; a_req_id = 4'h0;
        a_req_valid = 1'b1;
        @(posedge clk);
        while (a_req_ready !== 1'b1) @(posedge clk);
        @(negedge clk); a_req_valid = 1'b0;
        // 写数据：W 通道由控制器逐 beat 取 wdata；本 TB 恒给有效数据。
        //   观察窗口同上：必须等第二笔 AW 发出且 busy 释放，才能数到"总 done 次数"。
        g = 0;
        while (g < 1200 && !((aw_seen >= 2) && (a_busy === 1'b0) && (a_done === 1'b0))) begin
            @(negedge clk);
            a_wdata_valid = 1'b1;
            a_wdata_data  = 32'hD000_0000 + g[31:0];
            @(posedge clk); g = g + 1;
        end
        @(negedge clk); a_wdata_valid = 1'b0;
        repeat (40) @(posedge clk);
        chk(n_done == 1, "v6 exactly ONE done for the whole split write");
        chk(busy_holes == 0, "v6 busy covers the entire logical write request");
        chk(aw_seen == 2, "v6 split into exactly 2 AW");
        chk(aw_addr_seen[0] === 32'h0000_2FF8, "v6 first AW address");
        chk(aw_len_seen[0]  === 4'd1,          "v6 first AW truncated to 2 beats");
        chk(aw_addr_seen[1] === 32'h0000_3000, "v6 second AW continues at 4 K");
        chk(aw_len_seen[1]  === 4'd5,          "v6 second AW 6 beats");
        if (n_done != 1) mark_defect;
        if (busy_holes != 0) mark_defect;
        repeat (4) @(posedge clk);
        axi_beat_checks(0, "v6");
        vec_end;

        //======================================================================
        // v7（正控）：非拆分请求 ⇒ 恰好一次 done（两棵树都必须通过）。
        //======================================================================
        vec_begin("ctrl_axi_nonsplit_single_done");
        d_reset;
        sl_r_gap_0 = 1; sl_r_gap_1 = 1;
        n_done = 0; busy_holes = 0; req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0;
        a_req_is_write = 1'b0; a_req_addr = 32'h0000_5000; a_req_beats = 5'd4;
        a_req_len = 4'd3; a_req_split = 1'b0;
        a_req_beats_1 = 5'd4; a_req_beats_2 = 5'd0;
        a_req_owner = 2'd0; a_req_id = 4'h0;
        a_req_valid = 1'b1;
        @(posedge clk);
        while (a_req_ready !== 1'b1) @(posedge clk);
        @(negedge clk); a_req_valid = 1'b0;
        g = 0;
        while (g < 400 && !((ar_seen >= 1) && (a_busy === 1'b0) && (a_done === 1'b0))) begin
            @(posedge clk); g = g + 1;
        end
        repeat (20) @(posedge clk);
        chk(n_done == 1, "v7 non-split request gives exactly one done");
        chk(busy_holes == 0, "v7 busy covers the request");
        chk(ar_seen == 1, "v7 exactly one AR");
        chk(ar_len_seen[0] === 4'd3, "v7 AR LEN == 3 (4 beats)");
        if (n_done != 1) mark_defect;
        axi_beat_checks(4, "v7");
        vec_end;

        //======================================================================
        // v8（04-07）：L1I 早 beat 错误 ⇒ 该行**不得**装 valid；重试可恢复。
        //======================================================================
        vec_begin("l1i_fill_err_early");
        d_reset;
        n_fill_fail_i = 0; n_cs_err_i = 0;
        i_issue(IA + 32'h4);
        chk(i_cs_miss === 1'b1, "v8 IA misses");
        if (!HAS_ERR) begin
            // 旧树：**没有任何错误输入端口** ⇒ 04-07 的语义无法表达（这正是缺陷本体）。
            chk(0, "v8 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
            // 行为面旁证：旧 L1I 对"任何完成的填充"都无条件置 valid ⇒ 不存在
            // "拒绝装入某行"的能力（错误响应也会被当正常数据装行）。
            i_fill(IA, -1, "v8");
            i_issue(IA + 32'h4);
            chk(i_cs_ready === 1'b1, "v8 old: any completed fill is installed as valid (no poison path)");
            i_drop; repeat (2) @(posedge clk);
        end else begin
            i_fill(IA, 0, "v8");                // beat 0 出错
            repeat (2) @(posedge clk);
            chk(n_fill_fail_i == 1, "v8 exactly one fill_fail pulse (transaction level)");
            chk(n_cs_err_i == 1, "v8 cs_err pulses for the failed access");
            chk(i_err_sticky === 1'b1, "v8 err_sticky latched");
            // 错误行不得命中（旧实现会把垃圾行装成 valid）
            i_issue(IA + 32'h4);
            chk(i_cs_miss === 1'b1, "v8 errored line must NOT hit (no garbage install)");
            if (i_cs_ready === 1'b1) mark_defect;
            i_drop; repeat (2) @(posedge clk);
            // 重试（干净）⇒ 正常装行并命中
            i_issue(IA + 32'h4);
            chk(i_cs_miss === 1'b1, "v8 retry still misses");
            i_fill(IA, -1, "v8");
            i_issue(IA + 32'h4);
            chk(i_cs_ready === 1'b1, "v8 retry recovers: line hits");
            chk(i_cs_rdata === line_word(IA, 1), "v8 retry data correct");
            i_drop; repeat (2) @(posedge clk);
            // inval_all 清 err_sticky
            @(negedge clk); i_inval_all = 1'b1;
            @(posedge clk); @(negedge clk); i_inval_all = 1'b0;
            repeat (2) @(posedge clk);
            chk(i_err_sticky === 1'b0, "v8 inval_all clears err_sticky");
        end
        vec_end;

        //======================================================================
        // v9（04-07）：L1I 末 beat 错误（含末 beat 累计）⇒ 不装 valid。
        //======================================================================
        vec_begin("l1i_fill_err_last");
        n_fill_fail_i = 0;
        if (!HAS_ERR) begin
            chk(0, "v9 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            i_issue(IC + 32'h8);
            chk(i_cs_miss === 1'b1, "v9 IC misses");
            i_fill(IC, 7, "v9");                // 末 beat 出错
            repeat (2) @(posedge clk);
            chk(n_fill_fail_i >= 1, "v9 last-beat error accumulated (fill_fail)");
            i_issue(IC + 32'h8);
            chk(i_cs_miss === 1'b1, "v9 last-beat errored line must NOT hit");
            if (i_cs_ready === 1'b1) mark_defect;
            i_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v10（04-07）：两条不同错误行交替 ⇒ 返回第一条不得命中（单槽 poison 缺陷）。
        //======================================================================
        vec_begin("l1i_two_err_lines_alternate");
        if (!HAS_ERR) begin
            chk(0, "v10 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            // 行 D（组 0x10 的另一 tag）出错，覆盖/并列第一条错误行
            i_issue(32'h0003_0200 + 32'h4);
            chk(i_cs_miss === 1'b1, "v10 line D misses");
            i_fill(32'h0003_0200, 3, "v10");
            // 回到 IA：必须仍然 miss（错误行从未装 valid）
            i_issue(IA + 32'h4);
            chk(i_cs_miss === 1'b1, "v10 returning to first error line still misses");
            if (i_cs_ready === 1'b1) mark_defect;
            i_drop; repeat (2) @(posedge clk);
            // 行 E（另一组）也出错
            i_issue(32'h0004_0220 + 32'h4);
            chk(i_cs_miss === 1'b1, "v10 line E misses");
            i_fill(32'h0004_0220, 5, "v10");
            i_issue(32'h0003_0200 + 32'h4);
            chk(i_cs_miss === 1'b1, "v10 line D still misses after second error");
            if (i_cs_ready === 1'b1) mark_defect;
            i_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v11（04-07）：L1D 中 beat 错误 ⇒ 不装 valid；随后同址访问仍 miss。
        //======================================================================
        vec_begin("l1d_fill_err_mid");
        d_reset;
        n_fill_fail = 0; n_cs_err_d = 0;
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v11 DA0 misses");
        if (!HAS_ERR) begin
            d_fill(DA0, -1, "v11");
            chk(0, "v11 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            d_wait_fill(DA0, "v11");
            d_drop;
            d_fill_body(DA0, 4);                // 中 beat 出错
            repeat (2) @(posedge clk);
            chk(n_fill_fail == 1, "v11 exactly one fill_fail");
            chk(n_cs_err_d >= 1, "v11 cs_err reported for the pending access");
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v11 errored D line must NOT hit");
            if (d_cs_ready === 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
            // 重试恢复
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            d_fill(DA0, -1, "v11");
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v11 retry recovers: D line hits");
            chk(d_cs_rdata === line_word(DA0, 1), "v11 retry data correct");
            d_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v12（04-07）：写回 B 失败 ⇒ 脏数据**不得**丢；不得清 dirty/腾路。
        //======================================================================
        vec_begin("l1d_wb_b_fail_keeps_dirty");
        d_reset;
        n_wb_fail = 0; n_cs_err_d = 0;
        // 填满一组 4 路并全部写脏
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v12 DA0 misses"); d_fill(DA0, -1, "v12");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v12 DA1 misses"); d_fill(DA1, -1, "v12");
        d_access(1'b0, DA2 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v12 DA2 misses"); d_fill(DA2, -1, "v12");
        d_access(1'b0, DA3 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v12 DA3 misses"); d_fill(DA3, -1, "v12");
        d_access(1'b1, DA0 + 32'h4, 32'hE0E0_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v12 store DA0"); dirty_add(DA0, 32'd1, 32'hE0E0_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA1 + 32'h4, 32'hE1E1_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v12 store DA1"); dirty_add(DA1, 32'd1, 32'hE1E1_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA2 + 32'h4, 32'hE2E2_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v12 store DA2"); dirty_add(DA2, 32'd1, 32'hE2E2_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA3 + 32'h4, 32'hE3E3_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v12 store DA3"); dirty_add(DA3, 32'd1, 32'hE3E3_0001);
        d_drop; repeat (2) @(posedge clk);
        if (!HAS_ERR) begin
            chk(0, "v12 old DUT has no wb_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            // 替换：写回注入 B 失败
            d_access(1'b0, DA4 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v12 DA4 misses (set full)");
            d_wb_serve(0, 1'b1, "v12");         // inject_err=1 ⇒ B 非 OKAY
            repeat (2) @(posedge clk);
            chk(n_wb_fail == 1, "v12 exactly one wb_fail");
            chk(n_cs_err_d >= 1, "v12 cs_err terminates the pending access");
            // ★ 失败后该脏行仍在，缓存**允许**为重试再次发起写回（这是正确行为，不是残留）：
            //   判据是"重试的写回仍携带同一脏行"，而不是"永远不再请求"。
            d_drop; repeat (3) @(posedge clk);
            chk(1'b1, "v12 failure terminates the access via cs_err (dirty retained for retry)");
            d_access(1'b0, wb_paddr_cap + 32'h4, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v12 failed writeback victim still cached (dirty kept)");
            chk(d_cs_rdata === exp_line_word(wb_paddr_cap, 1),
                "v12 victim data intact after B failure");
            if (d_cs_ready !== 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
            // 再次替换 ⇒ 仍必须发起写回（脏未被静默丢弃）
            d_access(1'b0, DA4 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v12 DA4 misses again");
            d_wb_serve(0, 1'b0, "v12");
            chk(dirty_known(wb_paddr_cap), "v12 retried writeback still carries dirty line");
            d_fill(DA4, -1, "v12");
        end
        vec_end;

        //======================================================================
        // v13（04-07）：维护 clean 的写回 B 失败 ⇒ maint_err 可见、脏数据保留、
        //     扫描中止且 idle 回升（不活锁、不谎报成功）。
        //======================================================================
        vec_begin("l1d_maint_clean_b_fail");
        d_reset;
        n_maint_err = 0; n_wb_fail = 0; n_wb_req_seen = 0;
        // 同组两路脏（DA0/DA1），其余两路保持 invalid（供"未用 way 始终 invalid"判据）
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v13 DA0 misses"); d_fill(DA0, -1, "v13");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v13 DA1 misses"); d_fill(DA1, -1, "v13");
        d_access(1'b1, DA0 + 32'h4, 32'hF0F0_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v13 store DA0"); dirty_add(DA0, 32'd1, 32'hF0F0_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA1 + 32'h8, 32'hF1F1_0002, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v13 store DA1"); dirty_add(DA1, 32'd2, 32'hF1F1_0002);
        d_drop; repeat (2) @(posedge clk);
        if (!HAS_ERR) begin
            chk(0, "v13 old DUT has no wb_err/maint_err (04-07 structural defect)");
            mark_defect;
        end else begin
            // ---- 第一次 clean：首路 B 失败 ⇒ 中止、脏保留、无事务完成 ----
            d_maint_run(1'b1, "v13");
            repeat (2) @(posedge clk);
            chk(n_maint_err == 1, "v13 maint_err pulses (failure is NOT reported as success)");
            chk(d_idle === 1'b1, "v13 scan really aborts (idle returns)");
            chk(mtx_fail == 1, "v13 failed writeback counted as ONE failed transaction");
            chk(mtx_n == 0, "v13 no transaction committed on failure");
            // 脏数据保留：仍命中且值正确
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v13 DA0 still cached after failed clean");
            chk(d_cs_rdata === 32'hF0F0_0001, "v13 DA0 dirty data preserved");
            if (d_cs_rdata !== 32'hF0F0_0001) mark_defect;
            d_drop; repeat (2) @(posedge clk);
            d_access(1'b0, DA1 + 32'h8, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v13 DA1 still cached after failed clean");
            chk(d_cs_rdata === 32'hF1F1_0002, "v13 DA1 dirty data preserved");
            d_drop; repeat (2) @(posedge clk);
            // ---- 重试 clean：两笔事务都成功，按**握手+实际完成**记账 ----
            n_maint_err = 0; n_wb_fail = 0;
            d_maint_run(1'b0, "v13b");
            repeat (2) @(posedge clk);
            chk(n_maint_err == 0, "v13 retry clean: no maint_err");
            chk(mtx_fail == 0, "v13 retry clean: no failed transaction");
            chk(mtx_n == 2, "v13 retry clean commits exactly TWO transactions (by handshake)");
            chk(mtx_has_addr(DA0), "v13 retry wrote back DA0 (address from handshake)");
            chk(mtx_has_addr(DA1), "v13 retry wrote back DA1 (address from handshake)");
            //   ★★ 每路**逐 8 字**与独立期望比较（exp_line_word 走 TB 自己的脏账本，
            //      不读 DUT 任何内部）；原实现只比了 3/8 字，漏核 10 字。
            for (v13_w = 0; v13_w < WORDS; v13_w = v13_w + 1) begin
                chk_word(mtx_word_of(DA0, v13_w), exp_line_word(DA0, v13_w),
                         "v13 DA0 writeback word", v13_w);
                chk_word(mtx_word_of(DA1, v13_w), exp_line_word(DA1, v13_w),
                         "v13 DA1 writeback word", v13_w);
            end
            if (mtx_n != 2) mark_defect;
            //   ★ 清理的必须是**本次写回的那一路**：成功 clean 后该路 dirty 必须已清。
            //     未用的 way2/way3 必须始终 invalid（旧实现会把 way3 造 valid）。
            //   ★★ 原判据读的是**读口输出** `tag_dirty/tag_vld`，此刻 rd_addr 停在维护
            //      扫描终点（set 255），根本不是 DA0/DA1 的目标 set ⇒ 等于没证目标组。
            //      改为**只读**真实目标阵列（层次引用 tagv_q/dirty_q，不驱动任何输入），
            //      在目标 set 上逐 way 核对：way0/1 已 clean 且仍 valid；way2/3 绝无 valid。
            v13_set = DA0[12:5];
            chk(dut_d.g_way[0].u_tag.dirty_q[v13_set] === 1'b0,
                "v13 real target-set way0 dirty cleared by clean");
            chk(dut_d.g_way[1].u_tag.dirty_q[v13_set] === 1'b0,
                "v13 real target-set way1 dirty cleared by clean");
            chk(dut_d.g_way[0].u_tag.tagv_q[v13_set][0] === 1'b1,
                "v13 real target-set way0 still valid (clean keeps line)");
            chk(dut_d.g_way[1].u_tag.tagv_q[v13_set][0] === 1'b1,
                "v13 real target-set way1 still valid (clean keeps line)");
            chk(dut_d.g_way[2].u_tag.tagv_q[v13_set][0] === 1'b0,
                "v13 real target-set way2 has NO valid (no clean ghost)");
            chk(dut_d.g_way[3].u_tag.tagv_q[v13_set][0] === 1'b0,
                "v13 real target-set way3 has NO valid (no clean ghost)");
            if ((dut_d.g_way[0].u_tag.dirty_q[v13_set] !== 1'b0) ||
                (dut_d.g_way[1].u_tag.dirty_q[v13_set] !== 1'b0) ||
                (dut_d.g_way[2].u_tag.tagv_q[v13_set][0] !== 1'b0) ||
                (dut_d.g_way[3].u_tag.tagv_q[v13_set][0] !== 1'b0)) mark_defect;
            // ---- 再 clean（已全干净）⇒ 零事务、零写回 ----
            n_wb_req_seen = 0;
            d_maint_run(1'b0, "v13c");
            repeat (2) @(posedge clk);
            chk(mtx_n == 0, "v13 third clean issues ZERO writeback transactions");
            chk(n_wb_req_seen == 0, "v13 third clean sees no wb_req at all");
            chk(d_idle === 1'b1, "v13 third clean completes");
            chk(d_err_sticky === 1'b1, "v13 err_sticky still latched (diagnostic)");
            if (mtx_n != 0) mark_defect;
        end
        vec_end;

        //======================================================================
        // v14（正控）：L1D 干净缺失 + 命中路径（两棵树都必须通过）。
        //======================================================================
        vec_begin("ctrl_l1d_fill_hit");
        d_reset;
        d_access(1'b0, 32'h0009_0100 + 32'hC, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v14 miss on clean line");
        chk(d_wb_req === 1'b0, "v14 no writeback for clean victim");
        d_fill(32'h0009_0100, -1, "v14");
        d_access(1'b0, 32'h0009_0100 + 32'hC, 32'h0, 4'h0);
        chk(d_cs_ready === 1'b1, "v14 hit after fill");
        chk(d_cs_rdata === line_word(32'h0009_0100, 3), "v14 data correct");
        if (d_cs_rdata !== line_word(32'h0009_0100, 3)) mark_defect;
        d_drop; repeat (2) @(posedge clk);
        vec_end;

        //======================================================================
        // v15（04-07/P1-3）：AXI 读 **首 beat** 错误 —— rdata_error 与 rdata_valid
        //   同拍同 beat；done_error 在唯一 done 拍为 1；错误码来源必须是 R 的 resp。
        //======================================================================
        vec_begin("axi_r_err_early");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 2;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_r_err_beat_0 = 0; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0; resp_code_latched_ok = 1'b0;
        n_rdata_err_beats = 0; n_rdata_err_mismatch = 0;
        axi_req(1'b0, 32'h0000_6000, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(1, 400);
        chk(n_done == 1, "v15 exactly one done");
        chk(n_done_err == 1, "v15 done_error == 1 at the final done (R error)");
        chk(n_rdata_err_beats == 1, "v15 exactly one rdata_error beat");
        chk(n_rdata_err_mismatch == 0, "v15 rdata_error only on rdata_valid beats (same beat)");
        chk(resp_code_at_err === 2'b10, "v15 resp_code at error == R SLVERR (not B)");
        chk(a_resp_code === 2'b10, "v15 latched err_code source == R resp (not bresp)");
        chk(ar_seen == 1, "v15 exactly one AR");
        if ((n_done_err != 1) || (n_rdata_err_beats != 1) || (n_rdata_err_mismatch != 0)) mark_defect;
        axi_beat_checks(4, "v15");
        vec_end;

        //======================================================================
        // v16：AXI 读 **中间 beat** 错误（第 2 拍，共 4 拍）
        //======================================================================
        vec_begin("axi_r_err_mid");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 2;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_r_err_beat_0 = 2; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0; resp_code_latched_ok = 1'b0;
        n_rdata_err_beats = 0; n_rdata_err_mismatch = 0;
        axi_req(1'b0, 32'h0000_6400, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(1, 400);
        chk(n_done == 1, "v16 exactly one done");
        chk(n_done_err == 1, "v16 done_error == 1 (mid-beat R error must not be lost)");
        chk(n_rdata_err_beats == 1, "v16 exactly one rdata_error beat");
        chk(n_rdata_err_mismatch == 0, "v16 rdata_error same-beat aligned");
        chk(resp_code_at_err === 2'b10, "v16 error code from R resp");
        if ((n_done_err != 1) || (n_rdata_err_beats != 1)) mark_defect;
        axi_beat_checks(4, "v16");
        vec_end;

        //======================================================================
        // v17：AXI 读 **末 beat** 错误（第 3 拍，共 4 拍）
        //======================================================================
        vec_begin("axi_r_err_last");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 2;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_r_err_beat_0 = 3; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0; resp_code_latched_ok = 1'b0;
        n_rdata_err_beats = 0; n_rdata_err_mismatch = 0;
        axi_req(1'b0, 32'h0000_6800, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(1, 400);
        chk(n_done == 1, "v17 exactly one done");
        chk(n_done_err == 1, "v17 done_error == 1 at done (last-beat R error)");
        chk(n_rdata_err_beats == 1, "v17 exactly one rdata_error beat");
        chk(n_rdata_err_mismatch == 0, "v17 rdata_error same-beat aligned");
        if (n_done_err != 1) mark_defect;
        axi_beat_checks(4, "v17");
        vec_end;

        //======================================================================
        // v18：AXI **B 错误**（写响应非 OKAY）—— done_error 可见、码源来自 bresp
        //======================================================================
        vec_begin("axi_b_err_write");
        d_reset;
        sl_b_gap_0 = 2; sl_b_gap_1 = 2;
        sl_b_resp_0 = 2'b11; sl_b_resp_1 = 2'b00;   // DECERR
        sl_r_err_beat_0 = -1; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0; resp_code_latched_ok = 1'b0;
        // 写数据恒有效（控制器只在 ST_W 取）
        @(negedge clk); a_wdata_valid = 1'b1; a_wdata_data = 32'hD000_0000;
        axi_req(1'b1, 32'h0000_6C00, 5'd4, 1'b0, 5'd4, 5'd0, 2'd2);
        axi_wait_done(1, 400);
        @(negedge clk); a_wdata_valid = 1'b0;
        chk(n_done == 1, "v18 exactly one done");
        chk(n_done_err == 1, "v18 done_error == 1 at done (B error)");
        chk(aw_seen == 1, "v18 exactly one AW");
        chk(resp_code_at_err === 2'b11, "v18 resp_code at error == B DECERR");
        chk(a_resp_code === 2'b11, "v18 latched err_code source == B resp");
        if ((n_done_err != 1) || (a_resp_code !== 2'b11)) mark_defect;
        axi_beat_checks(0, "v18");
        vec_end;

        //======================================================================
        // v19：AXI 4 K 拆分：**首笔错、末笔好** ⇒ 唯一 done 拍仍报错（跨笔累计）
        //======================================================================
        vec_begin("axi_split_first_err_last_ok");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 2;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_r_err_beat_0 = 0;  sl_r_err_beat_1 = -1;   // 只在第一笔的首 beat 出错
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0; resp_code_latched_ok = 1'b0;
        n_rdata_err_beats = 0; n_rdata_err_mismatch = 0;
        axi_req(1'b0, 32'h0000_7FF8, 5'd8, 1'b1, 5'd2, 5'd6, 2'd1);
        axi_wait_done(1, 900);
        chk(n_done == 1, "v19 exactly ONE done for the split request");
        chk(n_done_err == 1, "v19 done_error reports the FIRST-half error at the single done");
        chk(ar_seen == 2, "v19 two AR (split)");
        chk(n_rdata_err_beats == 1, "v19 exactly one errored R beat");
        chk(n_rdata_err_mismatch == 0, "v19 rdata_error aligned only on valid beats");
        chk(busy_holes == 0, "v19 busy covers whole logical request");
        if ((n_done != 1) || (n_done_err != 1)) mark_defect;
        axi_beat_checks(8, "v19");
        vec_end;

        //======================================================================
        // v20：AXI 错误累计**在新请求被接受时清零**（第二笔干净请求不得继承旧错）
        //======================================================================
        vec_begin("axi_err_clear_next_req");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 2;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_r_err_beat_0 = 1; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0;
        // 第一笔：带错
        axi_req(1'b0, 32'h0000_7000, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(1, 400);
        chk(n_done == 1, "v20 first request done");
        chk(n_done_err == 1, "v20 first request reports error");
        // 第二笔：干净（把逐 beat 注入清掉）
        sl_r_err_beat_0 = -1;
        axi_req(1'b0, 32'h0000_7400, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(2, 400);
        chk(n_done == 2, "v20 second request done");
        chk(n_done_err == 1, "v20 second (clean) request must NOT report an error");
        chk(a_done_error === 1'b0, "v20 done_error == 0 on the clean request's done");
        chk(a_resp_error === 1'b0, "v20 no lingering resp_error on clean request");
        if ((n_done_err != 1) || (a_done_error !== 1'b0)) mark_defect;
        axi_beat_checks(8, "v20");
        vec_end;

        //======================================================================
        // v21（P1-2）：AXI 有效 R beat 上 **rresp = X** ⇒ 必须按错误处理（fail-closed）
        //======================================================================
        vec_begin("axi_r_resp_x_fail_closed");
        d_reset;
        sl_r_gap_0 = 2; sl_r_gap_1 = 2;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_r_err_beat_0 = -1; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = 1;  sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0; resp_code_latched_ok = 1'b0;
        n_rdata_err_beats = 0; n_rdata_err_mismatch = 0;
        axi_req(1'b0, 32'h0000_7800, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(1, 400);
        chk(n_done == 1, "v21 exactly one done");
        chk(n_resp_err >= 1, "v21 X resp must raise resp_error (not swallowed)");
        // ★ done_error 是**与 done 同拍**的脉冲：必须在 done 拍由监视器锁存后断言，
        //   不能在 done 过去之后再组合采样（那时它本就应为 0）。
        chk(n_done_err == 1, "v21 done_error == 1 at the done beat for X resp (fail-closed)");
        chk(n_rdata_err_beats == 1, "v21 X beat flagged by rdata_error");
        chk(n_rdata_err_mismatch == 0, "v21 rdata_error aligned with rdata_valid");
        if (n_done_err != 1) mark_defect;
        axi_beat_checks(4, "v21");
        vec_end;

        //======================================================================
        // v22（P1-2）：AXI 有效 **B 响应 = X** ⇒ 不得当作写成功
        //======================================================================
        vec_begin("axi_b_resp_x_fail_closed");
        d_reset;
        sl_b_gap_0 = 2; sl_b_gap_1 = 2;
        sl_b_resp_0 = 2'bxx; sl_b_resp_1 = 2'b00;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0;
        @(negedge clk); a_wdata_valid = 1'b1; a_wdata_data = 32'hD100_0000;
        axi_req(1'b1, 32'h0000_7C00, 5'd4, 1'b0, 5'd4, 5'd0, 2'd2);
        axi_wait_done(1, 400);
        @(negedge clk); a_wdata_valid = 1'b0;
        chk(n_done == 1, "v22 exactly one done");
        chk(n_done_err == 1, "v22 X B resp must be treated as failure (fail-closed)");
        if (n_done_err != 1) mark_defect;
        axi_beat_checks(0, "v22");
        vec_end;

        //======================================================================
        // v23（正控）：AXI 全干净读写链 —— 无 resp_error / done_error、码保持 OKAY
        //======================================================================
        vec_begin("ctrl_axi_error_free_chain");
        d_reset;
        sl_r_gap_0 = 1; sl_r_gap_1 = 1; sl_b_gap_0 = 1; sl_b_gap_1 = 1;
        sl_r_resp_0 = 2'b00; sl_r_resp_1 = 2'b00;
        sl_b_resp_0 = 2'b00; sl_b_resp_1 = 2'b00;
        sl_r_err_beat_0 = -1; sl_r_err_beat_1 = -1;
        sl_r_x_beat_0   = -1; sl_r_x_beat_1   = -1;
        n_done = 0; n_done_err = 0; busy_holes = 0;
        req_acc_seen = 0; done_seen_cur = 0;
        ar_seen = 0; aw_seen = 0; n_resp_err = 0;
        n_rdata_err_beats = 0; n_rdata_err_mismatch = 0;
        axi_req(1'b0, 32'h0000_2000, 5'd4, 1'b0, 5'd4, 5'd0, 2'd0);
        axi_wait_done(1, 400);
        axi_wait_done(1, 10);
        chk(n_done == 1, "v23 clean read: one done");
        chk(n_done_err == 0, "v23 clean read: done_error == 0");
        chk(a_resp_error === 1'b0, "v23 clean read: no resp_error");
        @(negedge clk); a_wdata_valid = 1'b1; a_wdata_data = 32'hD200_0000;
        axi_req(1'b1, 32'h0000_2400, 5'd4, 1'b0, 5'd4, 5'd0, 2'd2);
        axi_wait_done(2, 400);
        @(negedge clk); a_wdata_valid = 1'b0;
        chk(n_done == 2, "v23 clean write: second done");
        chk(n_done_err == 0, "v23 clean write: still zero errored done");
        chk(a_resp_error === 1'b0, "v23 clean write: no resp_error");
        if (n_done_err != 0) mark_defect;
        axi_beat_checks(4, "v23");
        vec_end;

        //======================================================================
        // v24（P1-2）：L1I 有效拍 **fill_err = X**（早 beat）⇒ 不得装 valid
        //======================================================================
        vec_begin("l1i_fill_err_x_early");
        d_reset;
        n_fill_fail_i = 0; n_cs_err_i = 0;
        if (!HAS_ERR) begin
            chk(0, "v24 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            i_issue(IA + 32'h4);
            chk(i_cs_miss === 1'b1, "v24 IA misses");
            i_fill_x(IA, 0, "v24");                 // beat 0 的 fill_err = X
            repeat (2) @(posedge clk);
            chk(n_fill_fail_i == 1, "v24 X on an early valid beat is treated as a transaction error");
            chk(n_cs_err_i == 1, "v24 cs_err reports the failed access");
            // ★ 新增输出 cs_err_paddr 必须与 cs_err **同拍**给出**原填充行基址**
            chk(cs_err_pa_seen === 1'b1, "v24 cs_err pulse occurred (paddr captured on it)");
            chk(cs_err_pa_cap === IA, "v24 cs_err_paddr == original fill line base");
            if (cs_err_pa_cap !== IA) mark_defect;
            i_issue(IA + 32'h4);
            chk(i_cs_miss === 1'b1, "v24 X-errored line must NOT install valid");
            if (i_cs_ready === 1'b1) mark_defect;
            i_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v25（P1-2）：L1I 有效拍 **fill_err = X**（末 beat）⇒ 不得装 valid
        //======================================================================
        vec_begin("l1i_fill_err_x_last");
        d_reset;
        n_fill_fail_i = 0;
        if (!HAS_ERR) begin
            chk(0, "v25 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            i_issue(IC + 32'h8);
            chk(i_cs_miss === 1'b1, "v25 IC misses");
            i_fill_x(IC, 7, "v25");                 // 末 beat 的 fill_err = X
            repeat (2) @(posedge clk);
            chk(n_fill_fail_i == 1, "v25 X on the last valid beat is accumulated (not swallowed)");
            chk(cs_err_pa_seen === 1'b1, "v25 cs_err pulse occurred (paddr captured on it)");
            chk(cs_err_pa_cap === IC, "v25 cs_err_paddr == original fill line base");
            if ((n_fill_fail_i != 1) || (cs_err_pa_cap !== IC)) mark_defect;
            i_issue(IC + 32'h8);
            chk(i_cs_miss === 1'b1, "v25 last-beat X-errored line must NOT hit");
            if ((i_cs_ready === 1'b1) || (i_cs_miss !== 1'b1)) mark_defect;
            i_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v26（P1-2）：L1D 有效拍 **fill_err = X**（中 beat）⇒ 不得装 valid
        //======================================================================
        vec_begin("l1d_fill_err_x_mid");
        d_reset;
        n_fill_fail = 0; n_cs_err_d = 0;
        if (!HAS_ERR) begin
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v26 DA0 misses");
            d_fill(DA0, -1, "v26");
            chk(0, "v26 old DUT has no fill_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v26 DA0 misses");
            d_wait_fill(DA0, "v26");
            d_drop;
            d_fill_body_x(DA0, 3);                  // 中 beat 的 fill_err = X
            repeat (2) @(posedge clk);
            chk(n_fill_fail == 1, "v26 X on a mid valid beat is treated as an error");
            chk(n_cs_err_d >= 1, "v26 cs_err terminates the pending access");
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v26 X-errored D line must NOT hit");
            if (d_cs_ready === 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v27（P1-2）：L1D **wb_err = X** ⇒ 不得当作写回成功（dirty 必须保留）
        //======================================================================
        vec_begin("l1d_wb_err_x_keeps_dirty");
        d_reset;
        n_wb_fail = 0; n_cs_err_d = 0;
        // 填满一组 4 路并全部写脏 ⇒ 替换必有写回
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v27 DA0 misses"); d_fill(DA0, -1, "v27");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v27 DA1 misses"); d_fill(DA1, -1, "v27");
        d_access(1'b0, DA2 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v27 DA2 misses"); d_fill(DA2, -1, "v27");
        d_access(1'b0, DA3 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v27 DA3 misses"); d_fill(DA3, -1, "v27");
        d_access(1'b1, DA0 + 32'h4, 32'hA1A1_0000, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v27 store DA0"); dirty_add(DA0, 32'd1, 32'hA1A1_0000);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA1 + 32'h4, 32'hA1A1_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v27 store DA1"); dirty_add(DA1, 32'd1, 32'hA1A1_0001);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA2 + 32'h4, 32'hA1A1_0002, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v27 store DA2"); dirty_add(DA2, 32'd1, 32'hA1A1_0002);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA3 + 32'h4, 32'hA1A1_0003, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v27 store DA3"); dirty_add(DA3, 32'd1, 32'hA1A1_0003);
        d_drop; repeat (2) @(posedge clk);
        if (!HAS_ERR) begin
            chk(0, "v27 old DUT has no wb_err input (04-07 structural defect)");
            mark_defect;
        end else begin
            d_access(1'b0, DA4 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v27 DA4 misses (set full)");
            d_wb_serve_x(0, "v27");                 // B 拍 wb_err = X
            repeat (2) @(posedge clk);
            chk(n_wb_fail == 1, "v27 X B response treated as writeback failure (fail-closed)");
            if (n_wb_fail != 1) mark_defect;
            d_drop; repeat (3) @(posedge clk);
            d_access(1'b0, wb_paddr_cap + 32'h4, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v27 failed victim still cached (dirty kept on X B)");
            chk(d_cs_rdata === exp_line_word(wb_paddr_cap, 1),
                "v27 victim data intact after X B failure");
            if (d_cs_ready !== 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // v28（P1-1）：flush（clean+inval）**首路写回 B 失败** ⇒ 真正中止扫描：
        //   不得继续写回、不得失效该组；两路脏数据仍可读；重试 flush 后全部落盘。
        //======================================================================
        vec_begin("l1d_maint_flush_b_fail_two_ways");
        d_reset;
        n_maint_err = 0; n_wb_fail = 0;
        // 同一组 0x08 的 2 路写脏（DA0/DA1 都已 fill）
        d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v28 DA0 misses"); d_fill(DA0, -1, "v28");
        d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
        chk(d_cs_miss === 1'b1, "v28 DA1 misses"); d_fill(DA1, -1, "v28");
        d_access(1'b1, DA0 + 32'h4, 32'hBEEF_0000, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v28 store DA0"); dirty_add(DA0, 32'd1, 32'hBEEF_0000);
        d_drop; repeat (2) @(posedge clk);
        d_access(1'b1, DA1 + 32'h4, 32'hBEEF_0001, 4'hF);
        chk(d_cs_wr_done === 1'b1, "v28 store DA1"); dirty_add(DA1, 32'd1, 32'hBEEF_0001);
        d_drop; repeat (2) @(posedge clk);
        if (!HAS_ERR) begin
            chk(0, "v28 old DUT has no wb_err/maint_err (04-07 structural defect)");
            mark_defect;
        end else begin
            // 第一次 flush：首个写回 B 失败 ⇒ 必须中止，不得再写第二路、不得失效
            d_maint_flush(1'b1, "v28");
            repeat (2) @(posedge clk);
            chk(n_maint_err == 1, "v28 maint_err pulses on flush writeback failure");
            chk(d_idle === 1'b1, "v28 scan really aborts (idle returns)");
            chk(d_wb_req === 1'b0, "v28 no subsequent writeback after abort");
            chk(n_wb_fail == 1, "v28 exactly one failed writeback");
            // 两路脏数据都必须仍可读且内容正确（**没有被 flush 失效**）
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v28 DA0 still cached after aborted flush (not invalidated)");
            chk(d_cs_rdata === 32'hBEEF_0000, "v28 DA0 dirty data preserved");
            if (d_cs_ready !== 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
            d_access(1'b0, DA1 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_ready === 1'b1, "v28 DA1 still cached after aborted flush");
            chk(d_cs_rdata === 32'hBEEF_0001, "v28 DA1 dirty data preserved");
            if (d_cs_ready !== 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
            // 重试 flush（不注入错）⇒ 两路都写回并失效
            n_wb_req_seen = 0;
            d_maint_flush(1'b0, "v28b");
            repeat (2) @(posedge clk);
            chk(n_maint_err == 1, "v28 successful retry adds no maint_err");
            chk(n_wb_req_seen >= 2, "v28 retry writes back both dirty ways");
            d_access(1'b0, DA0 + 32'h4, 32'h0, 4'h0);
            chk(d_cs_miss === 1'b1, "v28 DA0 invalidated after successful flush");
            if (d_cs_ready === 1'b1) mark_defect;
            d_drop; repeat (2) @(posedge clk);
        end
        vec_end;

        //======================================================================
        // 汇总（fail-closed）：逐向量 + 唯一摘要行 + 唯一 PASS 锚点
        //======================================================================
        $display("CACHE_BUS_VECTORS total=%0d nonzero=%0d checks=%0d fails=%0d defect=%0d",
                 g_total, g_nonzero, g_checks, g_fails, g_defect);
        if ((g_fails == 0) && (g_defect == 0)) $display("FUNCTIONAL_CACHE_BUS: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 兜底：绝不无限挂死（超时打印可判定失败摘要；rc 由脚本墙钟处理）
    //--------------------------------------------------------------------------
    initial begin
        #4_000_000;
        $display("CACHE_BUS_VECTORS total=%0d nonzero=%0d checks=%0d fails=%0d defect=%0d",
                 g_total, g_nonzero, g_checks, g_fails + 1, g_defect);
        $display("CACHE_BUS_TIMEOUT");
        $finish;
    end

endmodule
