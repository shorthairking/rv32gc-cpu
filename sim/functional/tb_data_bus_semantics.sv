//==============================================================================
// sim/functional/tb_data_bus_semantics.sv
//   —— F4 数据总线语义定向 TB（真实 core_top_2b + 真实 RV32 程序 + 可控 AXI 从设备）
//==============================================================================
// 覆盖（只证本包接线，不冒充整核验收）：
//   D1 PMP load 允许 / 拒绝（cause 5）/ 跨入拒绝区的真实字节边界
//   D2 PMP store 退休前预检（cause 7）；被拒 store 零物理写
//   D3 普通 cacheable load 正常（不被设备规则堵）
//   D4 非 head 设备 load 零副作用 defer：慢 DDR 读在途时不得发设备 AR
//   D5 设备读 IRQ 自持：AR→R→退休全程 arm|side_pending 不断档；期间不得交付中断；
//      退休后 MTIP 恰一次；设备读不重放
//   D6 kill/drain：设备读 AR 后强制 trap 重定向 ⇒ 迟到旧 R 被吞；同 tag 新 load 正确
//
// 唯一成功行：`TB_DATA_BUS_SEMANTICS: PASS`（恰好一次；失败 $fatal）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module tb_data_bus_semantics #(
    parameter integer CLK_HALF_NS  = 5,
    parameter integer RESET_CYCLES = 20,
    parameter integer MAX_CYCLES   = 400000,
    parameter [8*512-1:0] PROG_HEX = ""
) ();

    localparam [31:0] UART_D   = 32'h1FE0_01E0;
    localparam [31:0] KILL_D   = 32'h1FE0_01E4;
    localparam [31:0] SLOW_A   = 32'h8001_3000;
    localparam [31:0] MAILBOX  = 32'h1FE0_1000;   // uncached 窗（TB 直接看 DDR 数组）
    localparam [31:0] KNOWN_A  = 32'h8001_5000;
    localparam [31:0] TD       = 32'h1FE0_0240;   // PMP cfg 动态 store
    localparam [31:0] TS       = 32'h1FE0_0250;   // same-group CSR+store
    localparam [31:0] TP       = 32'h1FE0_0260;   // PMPADDR 动态
    localparam [31:0] TC       = 32'h1FE0_0270;   // 非 PMP CSR 正控
    localparam [31:0] SLOW_CFG   = 32'h8001_6000;
    localparam [31:0] SLOW_CFG2  = 32'h8001_6020;
    localparam [31:0] SLOW_ADDR  = 32'h8001_6040;
    localparam [31:0] SLOW_DATA2 = 32'h8001_6060;
    localparam [31:0] CBO_ADDR   = 32'h8001_7000;
    localparam [31:0] DENY_A   = 32'h8001_1000;
    localparam [31:0] MAGIC    = 32'h4442_5331;   // "DBS1"
    localparam [31:0] DONE     = 32'hDEAD_BEEF;

    function [7:0] expected_uart_byte;
        input integer n;
        begin
            case (n)
                0: expected_uart_byte = 8'hAA;
                1: expected_uart_byte = 8'hBB;
                2: expected_uart_byte = 8'h5A;
                default: expected_uart_byte = 8'hxx;
            endcase
        end
    endfunction

    function [31:0] next_w_addr;
        input [31:0] addr, start_addr;
        input [3:0] len;
        input [2:0] size;
        input [1:0] burst;
        reg [31:0] step_bytes, span_bytes, wrap_base, candidate;
        begin
            step_bytes = 32'd1 << size;
            case (burst)
                2'b00: next_w_addr = addr; // FIXED
                2'b01: next_w_addr = addr + step_bytes; // INCR
                2'b10: begin // WRAP
                    span_bytes = (len + 1) * step_bytes;
                    wrap_base = (start_addr / span_bytes) * span_bytes;
                    candidate = addr + step_bytes;
                    next_w_addr = (candidate >= (wrap_base + span_bytes)) ? wrap_base : candidate;
                end
                default: next_w_addr = 32'hxxxxxxxx;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;
    reg rst_n = 1'b0;
    integer rc;
    initial begin
        rst_n = 1'b0;
        for (rc = 0; rc < RESET_CYCLES; rc = rc + 1) @(posedge clk);
        rst_n = 1'b1;
    end

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    wire [3:0]  arid, rid, awid, wid, bid;
    wire [31:0] araddr, rdata, awaddr, wdata;
    wire [3:0]  arlen, awlen, wstrb;
    wire [2:0]  arsize, arprot, awsize, awprot;
    wire [1:0]  arburst, arlock, awburst, awlock, rresp, bresp;
    wire [3:0]  arcache, awcache;
    wire        arvalid, arready, rvalid, rlast, rready;
    wire        awvalid, awready, wvalid, wlast, wready, bvalid, bready;

    reg  [7:0]  intrpt_r;
    always @(*) intrpt_r = 8'h00;

    core_top_2b u_dut (
        .aclk(clk), .intrpt(intrpt_r), .aresetn(rst_n),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .ws_valid(), .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0),
        .rf_rdata(),
        .debug0_wb_pc(), .debug0_wb_rf_wen(),
        .debug0_wb_rf_wnum(), .debug0_wb_rf_wdata()
    );

    //--------------------------------------------------------------------------
    // AXI 从设备（DDR + XIP + 两个设备地址；单笔在途）
    //--------------------------------------------------------------------------
    function [31:0] map_addr; input [31:0] a;
        begin map_addr = (a[31:20] == 12'h800) ? {12'h000, a[19:0]} : a; end
    endfunction

    reg [31:0] ddr [0:32767];   // 128 KiB 字节窗（程序 + 数据）
    reg [31:0] xip [0:1023];
    integer    i;
    integer    dev_cnt, kill_cnt, mb_wr_cnt;
    integer    tgtTD_wr, tgtTS_wr, tgtTP_wr, tgtTC_wr;
    integer    uart_wr_cnt;
    reg [7:0]  uart_wr_q [0:7];
    reg [31:0] r_addr;
    reg [3:0]  r_left;
    reg [7:0]  r_dly;
    reg        r_busy;
    reg        slow_pend;
    reg        w_busy;
    reg [31:0] w_addr;
    reg [3:0]  w_left;
    reg [3:0]  w_id;
    reg [2:0]  w_size;
    reg [1:0]  w_burst;
    reg [31:0] w_start;
    reg [3:0]  w_len;
    reg        b_pending;
    reg [7:0]  b_dly;
    reg [8*24-1:0] wprobe_mode;
    reg [8*16-1:0] schema_probe_mode, ctrl_probe_mode;
    integer ctrl_probe_state;
    reg [3:0]  aw_stall_cfg, w_stall_cfg, aw_stall_left, w_stall_left;
    reg [31:0] wprobe_forced_data, wprobe_aw_data;
    reg [3:0]  wprobe_aw_strb;
    reg [31:0] rerr_target;
    reg        rerr_enabled, rerr_used;
    integer    rerr_count, ext_id, ext_denied_w_count, ext_slow_w_count;
    integer    ext_root_pte_ar, ext_leaf_pte_ar, ext_high_alias_count;
    reg [31:0] rdelay_target, ext_branch_redirect_target, ext_itlb_target;
    integer    rdelay_cycles, ext_rdelay_ar_count, ext_rdelay_beats;
    integer    ext_branch_redirect_count, ext_itlb_req_count;
    integer    ext_cached_data_ar_count, ext_cached_data_beats;
    integer    ext_root_pte_hit_count, ext_root_pte_hit_first_cycle, ext_data_ptw_accept_count, ext_tagkill_count;
    integer    ext_tagkill_ad_state, ext_arstall_wait_count, ext_arstall_cancel_count;
    integer    ext_arstall_accept_count, ext_arstall_accept_cycle, ext_tagkill_cycle, ext_arstall_rbeats;
    integer    ext_arstall_first_held_cycle, ext_data_rdelay_ar_cycle, ext_data_rdelay_rsp_cycle;
    integer    ext_ptehit_tagkill_count, ext_kill_tr_want_count, ext_kill_d_accept_count, ext_kill_handshake_count;
    integer    ext_kill_ptw_idle_count, ext_kill_req_ready_count, ext_kill_owner_fetch_count;
    integer    a_stale_cycle_count, a_ghost_rsp_count, a_cancel_lifetime_cycles;
    integer    a_tag_reuse_count, a_m_trap_count, a_s_trap_count, a_tr_ready_want_count;
    reg        a_kill_seen, a_stale_seen, a_stale_idle_seen, a_cancel_lifetime_active;
    reg        a_owner_reuse_seen, a_profile_s_window;
    reg [2:0]  a_cancel_tag;
    reg [31:0] a_cancel_va;
    integer    a_cancel_kill_samples, a_cancel_stale_samples, a_cancel_idle_samples;
    integer    a_ghost_neg_mode;
    reg        a_ghost_neg_used;
    wire       a_ghost_kill_event, a_ghost_neg_fire, a_ghost_monitor_rsp_v;
    wire [2:0] a_ghost_monitor_rsp_tag;
    integer    b_initial_tag, b_cancelled_tag, b_target_start_count, b_same_tag_reuse_count;
    integer    b_stale_busy_cycles, b_stale_exit_fetch_busy, b_fetch_pte_service_count;
    integer    b_warm_tr_count, b_target_tr_count, b_warm_accept_count;
    integer    b_owner_fetch_kill_count, b_tagkill_fetch_busy_count;
    integer    b_ghost_rsp_count, b_cancel_lifetime_cycles, b_owner_reuse_count;
    integer    b_m_trap_count, b_s_trap_count;
    integer    b_post_req_index, b_post_rsp_count, b_post_sequence_error;
    integer    b_post_root_done, b_post_leaf_done, b_post_walk_done_count;
    reg        b_kill_seen, b_stale_seen, b_stale_idle_seen;
    reg        b_cancel_lifetime_active, b_owner_reuse_seen, b_profile_s_window;
    reg        b_post_exit_active, b_post_pending, b_post_complete;
    reg [2:0]  b_cancel_tag;
    reg [31:0] b_post_pending_pa, b_fetch_va;
    integer    b_cancel_kill_samples, b_cancel_stale_samples, b_cancel_idle_samples;
    integer    b_ghost_neg_mode, b_post_walk_neg_used;
    reg        b_ghost_neg_used, b_post_walk_dup_pulse;
    wire       b_ghost_kill_event, b_ghost_neg_fire, b_ghost_monitor_rsp_v;
    wire [2:0] b_ghost_monitor_rsp_tag;
    wire       b_post_walk_done_actual, b_post_walk_done_monitor;
    integer    profile_bad_data_count;
    reg        profile_bad_data_enabled;
    reg [31:0] profile_bad_data_target;
    reg [31:0] bdelay_target, ext_pmp_after_pc, arstall_target;
    integer arstall_cycles;
    reg [7:0] arstall_left;
    reg arstall_enabled, arstall_seen, arstall_active;
    reg ext_root_pte_hit_prev, ext_tagkill_prev;
    wire arstall_block;
    integer    bdelay_cycles, ext_bdelay_w_count, ext_bdelay_b_count, ext_bdelay_wait_cycles;
    integer    ext_bdelay_start_cycle, ext_bdelay_rsp_cycle, ext_pmp_after_count, ext_pmp_after_cycle;
    integer    pmp_repeat_mode, pmp_repeat_state;
    reg        rdelay_enabled, rdelay_active, ext_branch_match_prev, ext_itlb_match_prev;
    reg        bdelay_enabled, bdelay_active;
    reg        wprobe_force_active, wprobe_aw_payload_valid;
    integer    wprobe_state;
    wire [31:0] slave_wdata;
    wire [3:0]  slave_wstrb;

    assign a_ghost_kill_event = (ext_id == 17) &&
                                (u_dut.d_tag_cancel_live_load_w === 1'b1) &&
                                (u_dut.d_va_q === 32'h00400000);
    assign a_ghost_neg_fire = (a_ghost_neg_mode == 1 && a_ghost_kill_event && !a_ghost_neg_used) ||
                              (a_ghost_neg_mode == 2 && a_cancel_lifetime_active && !a_ghost_neg_used &&
                               !a_stale_seen && (u_dut.ad_st_q === 4'd11)) ||
                              (a_ghost_neg_mode == 3 && a_cancel_lifetime_active && !a_ghost_neg_used &&
                               a_stale_seen && (u_dut.ad_st_q === 4'd0) &&
                                !(u_dut.d_start && (u_dut.lsu_req_tag === a_cancel_tag)));
    assign a_ghost_monitor_rsp_v = (u_dut.d_rsp_v_w === 1'b1) || a_ghost_neg_fire;
    assign a_ghost_monitor_rsp_tag = a_ghost_neg_fire ?
                                    (a_ghost_kill_event ? u_dut.d_tag_q[2:0] : a_cancel_tag) :
                                    u_dut.d_rsp_tag_w;
    assign b_ghost_kill_event = (ext_id == 18) && $test$plusargs("PROFILE_B_CACHED_DATA") &&
                                (u_dut.d_tag_cancel_live_load_w === 1'b1) &&
                                (u_dut.d_va_q === 32'h00401200);
    assign b_ghost_neg_fire = (b_ghost_neg_mode == 1 && b_ghost_kill_event && !b_ghost_neg_used) ||
                              (b_ghost_neg_mode == 2 && b_cancel_lifetime_active && !b_ghost_neg_used &&
                               !b_stale_seen && (u_dut.ad_st_q === 4'd11)) ||
                              (b_ghost_neg_mode == 3 && b_cancel_lifetime_active && !b_ghost_neg_used &&
                               b_stale_seen && (u_dut.ad_st_q === 4'd0));
    assign b_ghost_monitor_rsp_v = (u_dut.d_rsp_v_w === 1'b1) || b_ghost_neg_fire;
    assign b_ghost_monitor_rsp_tag = b_ghost_neg_fire ?
                                    (b_ghost_kill_event ? u_dut.d_tag_q[2:0] : b_cancel_tag) :
                                    u_dut.d_rsp_tag_w;
    assign b_post_walk_done_actual = (b_post_exit_active && b_post_complete &&
                                      u_dut.ptw_req_done && u_dut.ptw_owner_fetch_w &&
                                      (u_dut.u_ptw.va_r === b_fetch_va));
    assign b_post_walk_done_monitor = b_post_walk_done_actual || b_post_walk_dup_pulse;

    assign arstall_block = (arstall_enabled === 1'b1) && (arvalid === 1'b1) &&
                           (map_addr(araddr) === map_addr(arstall_target)) && (arstall_left != 8'd0);
    assign arready = ~r_busy && ~arstall_block;
    assign awready = ~w_busy && ~b_pending && (aw_stall_left == 4'h0);
    assign wready  = w_busy && (w_stall_left == 4'h0);
    // TB-only bus view is transparent; probe modes alter the real connected W wires
    // only after an AW has been accepted and while W is stalled.
    assign slave_wdata = wdata;
    assign slave_wstrb = wstrb;
    assign bvalid  = b_pending & (b_dly == 4'h0);
    assign bid     = 4'd0;
    assign bresp   = 2'b00;
    assign rid     = 4'd0;
    assign rresp   = (rerr_enabled && !rerr_used && (rvalid === 1'b1) && (r_addr === map_addr(rerr_target)))
                   ? 2'b10 : 2'b00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_busy <= 1'b0; r_addr <= 32'h0; r_left <= 4'h0; r_dly <= 8'h0; rdelay_active <= 1'b0;
            slow_pend <= 1'b0; w_busy <= 1'b0; w_addr <= 32'h0; w_left <= 4'h0; w_id <= 4'h0;
            w_size <= 3'h0; w_burst <= 2'b01; w_start <= 32'h0; w_len <= 4'h0;
            aw_stall_left <= aw_stall_cfg; w_stall_left <= 4'h0;
            b_pending <= 1'b0; b_dly <= 4'h0; bdelay_active <= 1'b0;
        end else begin
            if (((awvalid !== 1'b0) && (awvalid !== 1'b1)) ||
                ((awready !== 1'b0) && (awready !== 1'b1)) ||
                ((wvalid !== 1'b0) && (wvalid !== 1'b1)) ||
                ((wready !== 1'b0) && (wready !== 1'b1))) begin
                $display("FAIL: AXI write control X/Z aw=%b/%b w=%b/%b", awvalid, awready, wvalid, wready); $fatal;
            end
            if ((awvalid === 1'b1) && (awready === 1'b1) &&
                (((^awaddr) === 1'bx) || ((^awlen) === 1'bx) || ((^awid) === 1'bx) ||
                 ((^awsize) === 1'bx) || ((^awburst) === 1'bx))) begin
                $display("FAIL: accepted AW payload contains X/Z addr=%08x len=%x id=%x", awaddr, awlen, awid); $fatal;
            end
            if ((awvalid === 1'b1) && (awready === 1'b1) && ((awsize > 3'd2) || (awburst == 2'b11))) begin
                $display("FAIL: unsupported accepted AW size/burst size=%0d burst=%b", awsize, awburst); $fatal;
            end
            if ((wvalid === 1'b1) && (wready === 1'b1) &&
                (((^wdata) === 1'bx) || ((^wstrb) === 1'bx) ||
                 ((wlast !== 1'b0) && (wlast !== 1'b1)))) begin
                $display("FAIL: accepted W payload contains X/Z data=%08x strb=%x last=%b", wdata, wstrb, wlast); $fatal;
            end
            if (profile_bad_data_enabled && (rvalid === 1'b1) && (rready === 1'b1) &&
                (r_addr === profile_bad_data_target) && (rdata_r === 32'hDEAD_C0DE)) begin
                profile_bad_data_count <= profile_bad_data_count + 1;
                $display("PROFILE_BAD_DATA_INJECT t=%0t addr=%08x data=%08x", $time, r_addr, rdata_r);
            end
            if ((rvalid === 1'b1) && (rready === 1'b1) && (rresp !== 2'b00)) begin
                rerr_used <= 1'b1; rerr_count <= rerr_count + 1;
                $display("TB_ONLY_RRESP_ERROR addr=%08x resp=%b beat_count=%0d", r_addr, rresp, rerr_count + 1);
            end
            if (rdelay_active && (rvalid === 1'b1) && (rready === 1'b1)) begin
                ext_rdelay_beats <= ext_rdelay_beats + 1;
                if ((ext_id == 10) && (map_addr(r_addr) == map_addr(rdelay_target)) &&
                    (ext_data_rdelay_ar_cycle >= 0) && (ext_data_rdelay_rsp_cycle < 0)) begin
                    ext_data_rdelay_rsp_cycle <= cyc;
                    $display("DBG_DATA_RDELAY_FIRST_R cycle=%0d addr=%08x", cyc, r_addr);
                end
                if (r_left == 4'h0) rdelay_active <= 1'b0;
            end
            if (((ext_id == 12) || (ext_id == 13)) && (rvalid === 1'b1) && (rready === 1'b1) &&
                (r_addr >= 32'h0001_d200) && (r_addr <= 32'h0001_d21c))
                ext_cached_data_beats <= ext_cached_data_beats + 1;
            if (arstall_enabled && (arvalid === 1'b1) && (arready === 1'b0) &&
                (map_addr(araddr) === map_addr(arstall_target))) begin
                arstall_seen <= 1'b1; arstall_active <= 1'b1;
                if (ext_arstall_wait_count == 0) begin
                    ext_arstall_first_held_cycle <= cyc;
                    $display("DBG_ARSTALL_FIRST_HELD cycle=%0d addr=%08x", cyc, map_addr(araddr));
                end
                ext_arstall_wait_count <= ext_arstall_wait_count + 1;
                if (arstall_left != 8'h0) arstall_left <= arstall_left - 8'h1;
            end
            if (arstall_active && (arvalid === 1'b0)) begin
                arstall_active <= 1'b0; arstall_enabled <= 1'b0;
                ext_arstall_cancel_count <= ext_arstall_cancel_count + 1;
                $display("TB_ONLY_ARSTALL_CANCEL target=%08x wait_cycles=%0d", arstall_target, ext_arstall_wait_count);
            end
            if (arstall_enabled && (arvalid === 1'b1) && (arready === 1'b1) &&
                (map_addr(araddr) === map_addr(arstall_target))) begin
                arstall_enabled <= 1'b0; arstall_active <= 1'b0;
                ext_arstall_accept_count <= ext_arstall_accept_count + 1;
                ext_arstall_accept_cycle <= cyc;
                $display("TB_ONLY_ARSTALL_ACCEPT target=%08x wait_cycles=%0d cycle=%0d", arstall_target, ext_arstall_wait_count, cyc);
            end
            if ((ext_id == 16) && (rvalid === 1'b1) && (rready === 1'b1) &&
                (r_addr >= 32'h0001_b000) && (r_addr <= 32'h0001_b01c))
                ext_arstall_rbeats <= ext_arstall_rbeats + 1;
            // ---- 读 ----
            if (!r_busy) begin
                if (arvalid & arready) begin
                    if (ext_id != 0) begin
                        if (map_addr(araddr) == 32'h0001_b000) ext_root_pte_ar <= ext_root_pte_ar + 1;
                        if (map_addr(araddr) == 32'h0001_c000) ext_leaf_pte_ar <= ext_leaf_pte_ar + 1;
                        if (((ext_id == 12) || (ext_id == 13)) &&
                            (map_addr(araddr) == 32'h0001_d200))
                            ext_cached_data_ar_count <= ext_cached_data_ar_count + 1;
                        if (((ext_id == 6) && (map_addr(araddr) == 32'h0003_0000)) ||
                            (((ext_id == 7) || (ext_id == 14)) && (map_addr(araddr) == 32'h0000_5000)))
                            ext_high_alias_count <= ext_high_alias_count + 1;
                    end
                    r_busy <= 1'b1;
                    r_addr <= map_addr(araddr);
                    r_left <= arlen;
                    if (rdelay_enabled && (map_addr(araddr) == map_addr(rdelay_target))) begin
                        r_dly <= rdelay_cycles[7:0]; rdelay_active <= 1'b1;
                        ext_rdelay_ar_count <= ext_rdelay_ar_count + 1;
                        if ((ext_id == 10) && (u_dut.ptw_owner_fetch_w === 1'b0) &&
                            (ext_data_rdelay_ar_cycle < 0)) begin
                            ext_data_rdelay_ar_cycle <= cyc;
                            $display("DBG_DATA_RDELAY_AR cycle=%0d addr=%08x", cyc, map_addr(araddr));
                        end
                        $display("TB_ONLY_RDELAY_ACCEPT addr=%08x beats=%0d cycles=%0d",
                                 map_addr(araddr), arlen + 1, rdelay_cycles);
                    end else if (map_addr(araddr) == SLOW_A) begin
                        r_dly <= 8'd30; slow_pend <= 1'b1;
                    end else if (map_addr(araddr) == SLOW_DATA2) begin
                        r_dly <= 8'd200;
                    end else if ((map_addr(araddr) == SLOW_CFG) ||
                                 (map_addr(araddr) == SLOW_CFG2) ||
                                 (map_addr(araddr) == SLOW_ADDR)) begin
                        r_dly <= 8'd60;
                    end else if ((map_addr(araddr) == UART_D) ||
                                 (map_addr(araddr) == KILL_D)) begin
                        r_dly <= 8'd50;
                    end else r_dly <= 8'd0;
                end
            end else begin
                if (r_dly != 8'h0) r_dly <= r_dly - 8'h1;
                else if (rvalid & rready) begin
                    if (r_left == 4'h0) begin
                        r_busy <= 1'b0;
                        if (r_addr == SLOW_A) slow_pend <= 1'b0;
                    end else begin
                        r_left <= r_left - 4'h1;
                        r_addr <= r_addr + 32'd4;
                    end
                end
            end
            // ---- 写 ----
            if (!w_busy) begin
                if (aw_stall_left != 4'h0) aw_stall_left <= aw_stall_left - 4'h1;
                else if (awvalid & awready) begin
                    w_busy <= 1'b1; w_addr <= map_addr(awaddr); w_left <= awlen; w_id <= awid;
                    w_size <= awsize; w_burst <= awburst; w_start <= map_addr(awaddr); w_len <= awlen;
                    w_stall_left <= w_stall_cfg;
                end
            end else if (w_stall_left != 4'h0) begin
                w_stall_left <= w_stall_left - 4'h1;
            end else if (wvalid & wready) begin
                // AXI4 W has no transaction ID: the single outstanding AW owns ordered W beats.
                // Keep its ID for the corresponding B response association below.
                if (wlast !== (w_left == 4'h0)) begin
                    $display("FAIL: W/AW length association mismatch last=%b expected=%b left=%0d",
                             wlast, (w_left == 4'h0), w_left); $fatal;
                end
                if (!(w_addr >= 32'h1C00_0000 && w_addr < 32'h1FE0_0000)) begin
                    if (slave_wstrb[0]) ddr[w_addr[16:2]][ 7: 0] <= slave_wdata[ 7: 0];
                    if (slave_wstrb[1]) ddr[w_addr[16:2]][15: 8] <= slave_wdata[15: 8];
                    if (slave_wstrb[2]) ddr[w_addr[16:2]][23:16] <= slave_wdata[23:16];
                    if (slave_wstrb[3]) ddr[w_addr[16:2]][31:24] <= slave_wdata[31:24];
                end
                if (w_left == 4'h0) begin w_busy <= 1'b0; b_pending <= 1'b1;
                    aw_stall_left <= aw_stall_cfg;
                    if (bdelay_enabled && (w_addr == map_addr(bdelay_target))) begin
                        b_dly <= bdelay_cycles[7:0]; bdelay_active <= 1'b1;
                        ext_bdelay_start_cycle <= cyc; ext_bdelay_w_count <= ext_bdelay_w_count + 1;
                        $display("TB_ONLY_BDELAY_ACCEPT addr=%08x cycles=%0d", w_addr, bdelay_cycles);
                    end else b_dly <= (w_addr == UART_D) ? 8'd20 : 4'd4;
                end
                else begin w_left <= w_left - 4'h1;
                    w_addr <= next_w_addr(w_addr, w_start, w_len, w_size, w_burst);
                    w_stall_left <= w_stall_cfg; end
            end
            if (((bvalid !== 1'b0) && (bvalid !== 1'b1)) ||
                ((bready !== 1'b0) && (bready !== 1'b1))) begin
                $display("FAIL: AXI B control X/Z valid=%b ready=%b", bvalid, bready); $fatal;
            end
            if ((bvalid === 1'b1) && (bready === 1'b1) && (bid !== w_id)) begin
                $display("FAIL: B/AW ID association mismatch bid=%x awid=%x", bid, w_id); $fatal;
            end
            if (b_pending) begin
                if (b_dly != 4'h0) b_dly <= b_dly - 4'h1;
                else if (bready) begin
                    b_pending <= 1'b0;
                    if (bdelay_active) begin
                        ext_bdelay_b_count <= ext_bdelay_b_count + 1;
                        ext_bdelay_wait_cycles <= cyc - ext_bdelay_start_cycle;
                        ext_bdelay_rsp_cycle <= cyc; bdelay_active <= 1'b0;
                        $display("TB_ONLY_BDELAY_RESPONSE cycles=%0d", cyc - ext_bdelay_start_cycle);
                    end
                end
            end
            // ---- 设备读计数 + 邮箱 uncached 写计数（duplicate accept 观测）----
            if (arvalid & arready) begin
                if (map_addr(araddr) == UART_D) dev_cnt  <= dev_cnt  + 1;
                if (map_addr(araddr) == KILL_D) kill_cnt <= kill_cnt + 1;
            end
            // Side-effect accounting follows accepted W beats, never AW payload.
            // w_addr/w_left are independently latched at AW and advanced per W handshake.
            if (wvalid & wready) begin
                if (w_addr == 32'h0001_1000) ext_denied_w_count <= ext_denied_w_count + 1;
                if (w_addr == 32'h1FE0_1200) ext_slow_w_count <= ext_slow_w_count + 1;
                if ((ext_id == 11) && (pmp_repeat_mode != 0) && (pmp_repeat_state == 0) &&
                    (w_addr == 32'h1FE0_1128) && (slave_wstrb === 4'b1111) &&
                    (slave_wdata === 32'd1)) begin
                    pmp_repeat_state <= 1;
                    $display("TB_ONLY_PMP_REPEAT armed after accepted target-count store");
                end
                if (slave_wstrb !== 4'b0000) begin
                    // Fixed accepted-beat set: 2 header + 16 results + DONE + 2 extras = 21.
                    if (((w_addr >= 32'h1FE0_1000 && w_addr < 32'h1FE0_104C)) ||
                        (w_addr >= 32'h1FE0_1080 && w_addr < 32'h1FE0_1088))
                        mb_wr_cnt <= mb_wr_cnt + 1;
                    if (w_addr == TD) tgtTD_wr <= tgtTD_wr + 1;
                    if (w_addr == TS) tgtTS_wr <= tgtTS_wr + 1;
                    if (w_addr == TP) tgtTP_wr <= tgtTP_wr + 1;
                    if (w_addr == TC) tgtTC_wr <= tgtTC_wr + 1;
                    if (w_addr == UART_D) begin
                        if (slave_wstrb !== 4'b0001) begin
                            $display("FAIL: UART WSTRB expected=0001 at held AW=%08x got=%x",
                                     w_addr, slave_wstrb); $fatal;
                        end
                        if (uart_wr_cnt < 8) uart_wr_q[uart_wr_cnt] <= slave_wdata[7:0];
                        uart_wr_cnt <= uart_wr_cnt + 1;
                    end
                end
            end
        end
    end

    assign rvalid = r_busy & (r_dly == 8'h0);
    assign rlast  = rvalid & (r_left == 4'h0);
    reg [31:0] rdata_r;
    always @(*) begin
        if (r_addr == UART_D)       rdata_r = 32'hA5A5_0000 | dev_cnt;
        else if (r_addr == KILL_D)  rdata_r = 32'hDEAD_BEEF;
        else if (r_addr == SLOW_CFG)   rdata_r = 32'h1898_9818;
        else if (r_addr == SLOW_CFG2)  rdata_r = 32'h9898_9818;
        else if (r_addr == SLOW_ADDR)  rdata_r = 32'h07F8_0243;   // pmpaddr4 = Napot(TW)
        else if (r_addr == SLOW_DATA2) rdata_r = 32'h3333_3333;
        else if (r_addr >= 32'h1C00_0000 && r_addr < 32'h1FE0_0000)
                                    rdata_r = xip[(r_addr - 32'h1C00_0000) >> 2];
        else                        rdata_r = ddr[r_addr[16:2]];
        if (profile_bad_data_enabled && (r_addr == profile_bad_data_target))
            rdata_r = 32'hDEAD_C0DE;
    end
    assign rdata = rdata_r;

    //--------------------------------------------------------------------------
    // 程序装载
    //--------------------------------------------------------------------------
    integer fd, ch;
    reg [31:0] tok;
    integer    cur_addr, base_addr;
    task load_hex;
        input [8*512-1:0] path;
        begin
            if (path == "") begin $display("FAIL: no PROG_HEX"); $fatal; end
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FAIL: open prog %0s", path); $fatal; end
            cur_addr = 0;
            while (!$feof(fd)) begin
                ch = $fgetc(fd);
                while (ch == 32 || ch == 10 || ch == 13 || ch == 9) ch = $fgetc(fd);
                if (ch == -1) begin
                    // eof
                end else if (ch == 8'h40) begin          // '@'
                    tok = 0;
                    ch = $fgetc(fd);
                    while (ch != 10 && ch != 13 && ch != -1) begin
                        if (ch >= 8'h30 && ch <= 8'h39) tok = {tok[27:0], 4'h0} | (ch - 8'h30);
                        else if (ch >= 8'h61 && ch <= 8'h66) tok = {tok[27:0], 4'h0} | (ch - 8'h61 + 10);
                        else if (ch >= 8'h41 && ch <= 8'h46) tok = {tok[27:0], 4'h0} | (ch - 8'h41 + 10);
                        ch = $fgetc(fd);
                    end
                    cur_addr = tok;
                end else begin
                    tok = 0;
                    while (ch != 10 && ch != 13 && ch != -1) begin
                        if (ch >= 8'h30 && ch <= 8'h39) tok = {tok[27:0], 4'h0} | (ch - 8'h30);
                        else if (ch >= 8'h61 && ch <= 8'h66) tok = {tok[27:0], 4'h0} | (ch - 8'h61 + 10);
                        else if (ch >= 8'h41 && ch <= 8'h46) tok = {tok[27:0], 4'h0} | (ch - 8'h41 + 10);
                        ch = $fgetc(fd);
                    end
                    ddr[cur_addr[16:2]] = tok;
                    cur_addr = cur_addr + 4;
                end
            end
            $fclose(fd);
        end
    endtask

    initial begin
        wprobe_mode = "NONE"; schema_probe_mode = "NONE"; ctrl_probe_mode = "NONE";
        ctrl_probe_state = 0; aw_stall_cfg = 4'h0; w_stall_cfg = 4'h0;
        rerr_target = 32'h0; rerr_enabled = 1'b0; rerr_used = 1'b0; rerr_count = 0;
        rdelay_target = 32'h0; rdelay_cycles = 0; rdelay_enabled = 1'b0; rdelay_active = 1'b0;
        ext_rdelay_ar_count = 0; ext_rdelay_beats = 0;
        ext_branch_redirect_target = 32'h0; ext_itlb_target = 32'h0;
        ext_branch_redirect_count = 0; ext_itlb_req_count = 0;
        ext_branch_match_prev = 1'b0; ext_itlb_match_prev = 1'b0;
        bdelay_target = 32'h0; bdelay_cycles = 0; bdelay_enabled = 1'b0; bdelay_active = 1'b0;
        ext_bdelay_w_count = 0; ext_bdelay_b_count = 0; ext_bdelay_wait_cycles = 0;
        ext_bdelay_start_cycle = 0; ext_bdelay_rsp_cycle = 0;
        ext_pmp_after_pc = 32'h0; ext_pmp_after_count = 0; ext_pmp_after_cycle = 0;
        pmp_repeat_mode = 0; pmp_repeat_state = 0;
        arstall_target = 32'h0; arstall_cycles = 0; arstall_left = 8'h0;
        arstall_enabled = 1'b0; arstall_seen = 1'b0; arstall_active = 1'b0;
        ext_root_pte_hit_count = 0; ext_root_pte_hit_first_cycle = -1;
        ext_data_ptw_accept_count = 0; ext_tagkill_count = 0;
        ext_tagkill_ad_state = -1; ext_arstall_wait_count = 0; ext_arstall_cancel_count = 0;
        ext_arstall_accept_count = 0; ext_arstall_accept_cycle = 0; ext_tagkill_cycle = 0; ext_arstall_rbeats = 0;
        ext_arstall_first_held_cycle = -1; ext_data_rdelay_ar_cycle = -1; ext_data_rdelay_rsp_cycle = -1;
        ext_ptehit_tagkill_count = 0; ext_kill_tr_want_count = 0;
        ext_kill_d_accept_count = 0; ext_kill_handshake_count = 0;
        ext_kill_ptw_idle_count = 0; ext_kill_req_ready_count = 0; ext_kill_owner_fetch_count = 0;
        a_stale_cycle_count = 0; a_ghost_rsp_count = 0; a_cancel_lifetime_cycles = 0;
        a_tag_reuse_count = 0; a_m_trap_count = 0; a_s_trap_count = 0; a_tr_ready_want_count = 0;
        a_kill_seen = 1'b0; a_stale_seen = 1'b0; a_stale_idle_seen = 1'b0;
        a_cancel_lifetime_active = 1'b0; a_owner_reuse_seen = 1'b0;
        a_profile_s_window = 1'b0; a_ghost_neg_used = 1'b0;
        a_cancel_tag = 3'd0; a_cancel_va = 32'd0;
        a_cancel_kill_samples = 0; a_cancel_stale_samples = 0; a_cancel_idle_samples = 0;
        a_ghost_neg_mode = 0;
        if ($value$plusargs("PROFILE_A_GHOST_NEGCTRL=%d", a_ghost_neg_mode)) begin
            if ((a_ghost_neg_mode < 1) || (a_ghost_neg_mode > 3)) begin
                $display("FAIL: PROFILE_A_GHOST_NEGCTRL mode must be 1..3"); $fatal;
            end
            $display("PROFILE_A_GHOST_NEGCTRL_ARMED mode=%0d", a_ghost_neg_mode);
        end
        b_initial_tag = -1; b_cancelled_tag = -1; b_target_start_count = 0; b_same_tag_reuse_count = 0;
        b_stale_busy_cycles = 0; b_stale_exit_fetch_busy = 0; b_fetch_pte_service_count = 0;
        b_warm_tr_count = 0; b_target_tr_count = 0; b_warm_accept_count = 0;
        b_owner_fetch_kill_count = 0; b_tagkill_fetch_busy_count = 0;
        b_ghost_rsp_count = 0; b_cancel_lifetime_cycles = 0; b_owner_reuse_count = 0;
        b_cancel_kill_samples = 0; b_cancel_stale_samples = 0; b_cancel_idle_samples = 0;
        b_ghost_neg_mode = 0; b_ghost_neg_used = 1'b0;
        b_post_walk_neg_used = 0; b_post_walk_dup_pulse = 1'b0;
        b_m_trap_count = 0; b_s_trap_count = 0;
        b_post_req_index = 0; b_post_rsp_count = 0; b_post_sequence_error = 0;
        b_post_root_done = 0; b_post_leaf_done = 0; b_post_walk_done_count = 0;
        b_kill_seen = 1'b0; b_stale_seen = 1'b0; b_stale_idle_seen = 1'b0;
        b_cancel_lifetime_active = 1'b0; b_owner_reuse_seen = 1'b0; b_profile_s_window = 1'b0;
        b_post_exit_active = 1'b0; b_post_pending = 1'b0; b_post_complete = 1'b0;
        b_cancel_tag = 3'd0; b_post_pending_pa = 32'd0; b_fetch_va = 32'd0;
        if ($value$plusargs("PROFILE_B_GHOST_NEGCTRL=%d", b_ghost_neg_mode)) begin
            if ((b_ghost_neg_mode < 1) || (b_ghost_neg_mode > 3)) begin
                $display("FAIL: PROFILE_B_GHOST_NEGCTRL mode must be 1..3"); $fatal;
            end
            $display("PROFILE_B_GHOST_NEGCTRL_ARMED mode=%0d", b_ghost_neg_mode);
        end
        profile_bad_data_count = 0; profile_bad_data_enabled = 1'b0; profile_bad_data_target = 32'd0;
        if ($value$plusargs("PROFILE_BAD_DATA_ADDR=%h", profile_bad_data_target)) begin
            profile_bad_data_enabled = 1'b1;
            $display("PROFILE_BAD_DATA_ENABLED addr=%08x value=deadc0de", profile_bad_data_target);
        end
        ext_root_pte_hit_prev = 1'b0; ext_tagkill_prev = 1'b0;
        if ($value$plusargs("RERR_ADDR=%h", rerr_target)) begin
            rerr_enabled = 1'b1;
            $display("TB_ONLY_RRESP_INJECTION target=%08x (one accepted beat)", rerr_target);
        end
        if ($value$plusargs("RDELAY_ADDR=%h", rdelay_target)) begin
            if (!$value$plusargs("RDELAY_CYCLES=%d", rdelay_cycles) ||
                (rdelay_cycles < 1) || (rdelay_cycles > 255)) begin
                $display("FAIL: RDELAY requires cycles 1..255"); $fatal;
            end
            rdelay_enabled = 1'b1;
            $display("TB_ONLY_RDELAY target=%08x cycles=%0d", rdelay_target, rdelay_cycles);
        end
        if ($value$plusargs("BRANCH_TARGET=%h", ext_branch_redirect_target))
            $display("TB_ONLY_BRANCH_TARGET pc=%08x", ext_branch_redirect_target);
        if ($value$plusargs("ITLB_TARGET=%h", ext_itlb_target))
            $display("TB_ONLY_ITLB_TARGET va=%08x", ext_itlb_target);
        if ($value$plusargs("BDELAY_ADDR=%h", bdelay_target)) begin
            if (!$value$plusargs("BDELAY_CYCLES=%d", bdelay_cycles) ||
                (bdelay_cycles < 1) || (bdelay_cycles > 255)) begin
                $display("FAIL: BDELAY requires cycles 1..255"); $fatal;
            end
            bdelay_enabled = 1'b1;
            $display("TB_ONLY_BDELAY target=%08x cycles=%0d", bdelay_target, bdelay_cycles);
        end
        if ($value$plusargs("PMP_AFTER_PC=%h", ext_pmp_after_pc))
            $display("TB_ONLY_PMP_AFTER_PC pc=%08x", ext_pmp_after_pc);
        if ($value$plusargs("PMP_REPEAT=%d", pmp_repeat_mode) && (pmp_repeat_mode != 0))
            $display("TB_ONLY_PMP_REPEAT enabled (negative monitor probe)");
        if ($value$plusargs("ARSTALL_ADDR=%h", arstall_target)) begin
            if (!$value$plusargs("ARSTALL_CYCLES=%d", arstall_cycles) ||
                (arstall_cycles < 1) || (arstall_cycles > 255)) begin
                $display("FAIL: ARSTALL requires cycles 1..255"); $fatal;
            end
            arstall_enabled = 1'b1; arstall_left = arstall_cycles[7:0];
            $display("TB_ONLY_ARSTALL target=%08x cycles=%0d", arstall_target, arstall_cycles);
        end
        if ($value$plusargs("WPROBE=%s", wprobe_mode))
            $display("TB_ONLY_WPROBE mode=%0s (external slave-side mutation; not natural DUT behavior)", wprobe_mode);
        if ($value$plusargs("SCHEMAPROBE=%s", schema_probe_mode))
            $display("TB_ONLY_SCHEMAPROBE mode=%0s (mailbox oracle mutation; not natural DUT behavior)", schema_probe_mode);
        if ($value$plusargs("CTRLPROBE=%s", ctrl_probe_mode))
            $display("TB_ONLY_CTRLPROBE mode=%0s (hierarchical four-state injection; not natural DUT behavior)", ctrl_probe_mode);
        if ($value$plusargs("AWSTALL=%d", i)) begin
            if (i < 0 || i > 15) begin $display("FAIL: AWSTALL out of range %0d", i); $fatal; end
            aw_stall_cfg = i[3:0];
        end
        if ($value$plusargs("WSTALL=%d", i)) begin
            if (i < 0 || i > 15) begin $display("FAIL: WSTALL out of range %0d", i); $fatal; end
            w_stall_cfg = i[3:0];
        end
        if (((wprobe_mode == "UART_WRONG") || (wprobe_mode == "UART_ZERO") ||
             (wprobe_mode == "UART_LANE")) && (w_stall_cfg == 0))
            w_stall_cfg = 4'd2;
        wprobe_forced_data = 32'h0; wprobe_aw_data = 32'h0; wprobe_aw_strb = 4'h0;
        wprobe_force_active = 1'b0; wprobe_aw_payload_valid = 1'b0; wprobe_state = 0;
        dev_cnt = 0; kill_cnt = 0; mb_wr_cnt = 0;
        ext_denied_w_count = 0; ext_slow_w_count = 0;
        ext_root_pte_ar = 0; ext_leaf_pte_ar = 0; ext_high_alias_count = 0;
        ext_cached_data_ar_count = 0; ext_cached_data_beats = 0;
        tgtTD_wr = 0; tgtTS_wr = 0; tgtTP_wr = 0; tgtTC_wr = 0;
        uart_wr_cnt = 0; for (i = 0; i < 8; i = i + 1) uart_wr_q[i] = 8'h0;
        for (i = 0; i < 32768; i = i + 1) ddr[i] = 32'h0000_0013;
        for (i = 0; i < 1024; i = i + 1) xip[i] = 32'h0000_0013;
        xip[0] = 32'h800002b7;      // lui x5, 0x80000
        xip[1] = 32'h00028067;      // jalr x0, 0(x5)
        ddr[32'h15000 >> 2] = 32'h5A5A_5A5A;
        ddr[32'h13000 >> 2] = 32'h1122_3344;
        ddr[SLOW_CFG[16:2]]   = 32'h1898_9818;
        ddr[SLOW_CFG2[16:2]]  = 32'h9898_9818;
        ddr[SLOW_ADDR[16:2]]  = 32'h07F8_0243;
        ddr[SLOW_DATA2[16:2]] = 32'h3333_3333;
        load_hex(PROG_HEX);
        ext_id = 0;
        if ($value$plusargs("EXT=%d", ext_id))
            $display("DATA_BUS_EXTENSION_REQUEST id=%0d", ext_id);
        if (ext_id != 0) begin
            // CPU-driven Sv32 fixture: VA 0x00401200 -> uncached PA 0x1fe01200; code
            // superpage at VA 0x80000000 and uncached report window at 0x1fe01100.
            ddr[32'h1f000 >> 2] = ext_id;
            ddr[32'h1b000 >> 2] = 32'h0;
            ddr[(32'h1b000 >> 2) + 1] = 32'h20007001; // root[1] -> level-0 table @8001c000
            ddr[(32'h1b000 >> 2) + 127] = 32'h07f000cf; // I/O superpage @1fc00000
            ddr[(32'h1b000 >> 2) + 512] = 32'h200000cf; // code superpage @80000000
            ddr[32'h1c000 >> 2] = 32'h0;
            ddr[(32'h1c000 >> 2) + 1] = 32'h07f804c7; // VA 00401000 page -> uncached PA 1fe01000 RW
            ddr[32'h1200 >> 2] = 32'h12345678; // VA 00401200 -> PA 1fe01200
            if (ext_id == 6)
                ddr[(32'h1b000 >> 2) + 1] = 32'h4000c001; // level-0 root PPN=22'h100030
            if ((ext_id == 7) || (ext_id == 14))
                ddr[(32'h1c000 >> 2) + 1] = 32'h400014c7; // leaf PPN=22'h100005
            if ((ext_id == 8) || (ext_id == 9))
                ddr[(32'h1c000 >> 2) + 1] = 32'h00000000; // V=0 page-fault control
            if ((ext_id == 12) || (ext_id == 13)) begin
                ddr[(32'h1c000 >> 2) + 1] = 32'h200074c7; // DATA_VA -> cached PA 8001d200
                ddr[32'h1d200 >> 2] = 32'h12345678;
            end
            if ((ext_id == 10) || (ext_id == 15) || (ext_id == 16) ||
                (ext_id == 17) || (ext_id == 18)) begin
                ddr[(32'h1b000 >> 2) + 513] = 32'h200000cf; // new ITLB VPN1=513 -> same code PA
                ddr[32'h1c000 >> 2] = 32'h00000000; // wrong-path VPN0=0 is invalid
                ddr[(32'h1c000 >> 2) + 8] = 32'h07f804c7; // training VPN0=8
                ddr[(32'h1c000 >> 2) + 16] = 32'h07f804c7; // training VPN0=16
                ddr[(32'h1c000 >> 2) + 24] = 32'h07f804c7; // training VPN0=24
            end
            if ((ext_id == 17) || (ext_id == 18)) begin
                ddr[(32'h1b000 >> 2) + 512] = 32'h20007401; // profile code VPN1=512 -> L0 @8001d000
                ddr[(32'h1b000 >> 2) + 513] = 32'h20007801; // fall-through VPN1=513 -> L0 @8001e000
                ddr[(32'h1d000 >> 2)] = 32'h200000cf; // normal S code page @80000000
                ddr[(32'h1d000 >> 2) + 16'h3fd] = 32'h200000cf; // high alias to extension_done
                ddr[(32'h1d000 >> 2) + 1023] = 32'h200008cf; // branch code page @80002000
                ddr[(32'h1e000 >> 2)] = 32'h20000ccf; // new IF VPN page @80003000
                if ((ext_id == 18) && $test$plusargs("PROFILE_B_CACHED_DATA")) begin
                    ddr[(32'h1c000 >> 2) + 1] = 32'h20007cc7; // VA00401000/00401200 -> cached PA8001f000
                    ddr[32'h1f200 >> 2] = 32'h12345678;
                end
            end
            ddr[32'h1100 >> 2] = 32'h0; ddr[32'h1104 >> 2] = 32'h0;
            ddr[32'h1108 >> 2] = 32'h0; ddr[32'h110c >> 2] = 32'h0;
            ddr[32'h1110 >> 2] = 32'h0; ddr[32'h1114 >> 2] = 32'h0;
            ddr[32'h1118 >> 2] = 32'h0; ddr[32'h111c >> 2] = 32'h0;
            ddr[32'h1120 >> 2] = 32'h0; ddr[32'h1124 >> 2] = 32'h0;
            ddr[32'h1128 >> 2] = 32'h0;
        end
    end

    //--------------------------------------------------------------------------
    // TB 断言 + kill 注入
    //--------------------------------------------------------------------------
    integer errs, arm_gap, irq_in_io, cyc, irq_pend_io, arm_seen;
    reg        dev_rd_pend;
    reg [31:0] dev_rd_addr;
    reg [1:0]  kill_ph;
    reg [31:0] cont_pc;
    initial begin
        errs = 0; arm_gap = 0; irq_in_io = 0; cyc = 0;
        irq_pend_io = 0; arm_seen = 0;
        dev_rd_pend = 0; dev_rd_addr = 0; kill_ph = 0;
        cont_pc = 32'h0;
        if (!$value$plusargs("CONT=%h", cont_pc)) begin
            $display("FAIL: +CONT=<hex> required"); $fatal;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cyc <= cyc + 1;
            if (arvalid & arready & ((map_addr(araddr) == UART_D) ||
                                     (map_addr(araddr) == KILL_D))) begin
                dev_rd_pend <= 1'b1;
                dev_rd_addr <= map_addr(araddr);
            end else if (dev_rd_pend && rvalid && rready) begin
                dev_rd_pend <= 1'b0;
            end
            if (dev_rd_pend) begin
                // Four-state fail-closed checks: active controls must be known even on KILL.
                if (((u_dut.io_arm_q !== 1'b0) && (u_dut.io_arm_q !== 1'b1)) ||
                    ((u_dut.side_pending_w !== 1'b0) && (u_dut.side_pending_w !== 1'b1)) ||
                    ((u_dut.tc_trap_valid !== 1'b0) && (u_dut.tc_trap_valid !== 1'b1)) ||
                    ((u_dut.tc_trap_is_int !== 1'b0) && (u_dut.tc_trap_is_int !== 1'b1)) ||
                    ((u_dut.csr_mip_o[7] !== 1'b0) && (u_dut.csr_mip_o[7] !== 1'b1))) begin
                    $display("FAIL: active device-read control X/Z arm=%b side=%b trap=%b int=%b mip7=%b",
                             u_dut.io_arm_q, u_dut.side_pending_w, u_dut.tc_trap_valid,
                             u_dut.tc_trap_is_int, u_dut.csr_mip_o[7]); $fatal;
                end
                if (u_dut.io_arm_q === 1'b1) arm_seen <= arm_seen + 1;
                // KILL 设备读是注入 trap：只豁免保护连续性，控制信号仍必须已知。
                if (u_dut.csr_mip_o[7] === 1'b1) irq_pend_io <= irq_pend_io + 1;
                if ((u_dut.io_arm_q !== 1'b1) && (u_dut.side_pending_w !== 1'b1) &&
                    (dev_rd_addr != KILL_D)) begin
                    arm_gap <= arm_gap + 1;
                    if (arm_gap < 4)
                        $display("FAIL: device read 0x%08x in flight but protection dropped", dev_rd_addr);
                end
                if ((u_dut.tc_trap_valid === 1'b1) && (u_dut.tc_trap_is_int === 1'b1)) begin
                    irq_in_io <= irq_in_io + 1;
                    if (irq_in_io < 4)
                        $display("FAIL: interrupt delivered while device read 0x%08x in flight", dev_rd_addr);
                end
            end
            if (slow_pend && arvalid & arready &&
                ((map_addr(araddr) == UART_D) || (map_addr(araddr) == KILL_D))) begin
                errs <= errs + 1;
                $display("FAIL: device AR while slow DDR read pending");
            end
            // kill 注入：KILL 设备 AR 后一拍强制 flush + 重定向到 cont
            if ((kill_ph == 2'd0) && arvalid & arready && (map_addr(araddr) == KILL_D))
                kill_ph <= 2'd1;
            if (kill_ph == 2'd1) begin
                force u_dut.be_trp_flush = 1'b1;
                force u_dut.be_trp_redirect_v = 1'b1;
                force u_dut.be_trp_redirect_pc = cont_pc;
                kill_ph <= 2'd2;
            end else if (kill_ph == 2'd2) begin
                release u_dut.be_trp_flush;
                release u_dut.be_trp_redirect_v;
                release u_dut.be_trp_redirect_pc;
                kill_ph <= 2'd3;      // 完成
            end
        end
    end

    //--------------------------------------------------------------------------
    // Deliberate negative-control: after the first accepted execution-count store, inject
    // one duplicate redirect to the same real target. The normal suite never enables this.
    always @(negedge clk) begin
        if (rst_n && (pmp_repeat_mode != 0) && (pmp_repeat_state == 1)) begin
            force u_dut.pmp_next_pc_q = ext_pmp_after_pc;
            force u_dut.pmp_redir_w = 1'b1;
            pmp_repeat_state = 2;
            $display("TB_ONLY_PMP_REPEAT injected duplicate redirect pc=%08x", ext_pmp_after_pc);
        end else if (rst_n && (pmp_repeat_state == 2)) begin
            release u_dut.pmp_redir_w;
            release u_dut.pmp_next_pc_q;
            pmp_repeat_state = 3;
        end
    end

    // TB-only bus-fault probes. AW is accepted with correct W payload; then W is held
    // stalled for two cycles and the connected W data/strobe is forced wrong at the slave
    // interface before the actual W handshake. Default natural runs never force these wires.
    always @(posedge clk) begin
        if (rst_n && (wprobe_state == 0) && (wprobe_mode != "NONE") &&
            (awvalid === 1'b1) && (awready === 1'b1) && (map_addr(awaddr) == UART_D)) begin
            wprobe_aw_data = wdata;
            wprobe_aw_strb = wstrb;
            wprobe_aw_payload_valid = ((^wdata) !== 1'bx) && ((^wstrb) !== 1'bx);
            wprobe_state = 1;
            $display("TB_ONLY_WPROBE_AW addr=%08x wvalid=%b wdata=%08x wstrb=%x", map_addr(awaddr), wvalid, wdata, wstrb);
        end else if (rst_n && (wprobe_state == 1) && (wvalid === 1'b1) && (wready === 1'b0)) begin
            if (!wprobe_aw_payload_valid ||
                (wprobe_aw_data[7:0] !== expected_uart_byte(uart_wr_cnt)) ||
                (wdata[7:0] !== expected_uart_byte(uart_wr_cnt)) || (wstrb === 4'b0000)) begin
                $display("FAIL: W probe AW-phase payload not expected data=%08x current=%08x strobe=%x expected=%02x",
                         wprobe_aw_data, wdata, wstrb, expected_uart_byte(uart_wr_cnt)); $fatal;
            end
            if (wprobe_mode == "UART_WRONG") begin
                wprobe_forced_data = {wdata[31:8], (wdata[7:0] ^ 8'h01)};
                force wdata = wprobe_forced_data;
            end else if (wprobe_mode == "UART_ZERO") begin
                force wstrb = 4'b0000;
            end else if (wprobe_mode == "UART_LANE") begin
                force wstrb = 4'b0010;
            end
            wprobe_force_active = 1'b1;
            wprobe_state = 2;
        end else if (rst_n && (wprobe_state == 2) && (wvalid === 1'b1) && (wready === 1'b1)) begin
            $display("TB_ONLY_WPROBE_ACCEPTED addr=%08x raw_now=%08x raw_strb=%x", w_addr, wdata, wstrb);
            #1;
            release wdata;
            release wstrb;
            wprobe_force_active = 1'b0;
            wprobe_state = 3;
        end
    end

    // TB-only four-state control probes used by --self-test counterproofs.
    // The injection is delayed across a full active device-read sample and is never used
    // in the default natural positive run.
    always @(posedge clk) begin
        if (rst_n && dev_rd_pend && ctrl_probe_state == 0) begin
            case (ctrl_probe_mode)
                "ARM_X": begin force u_dut.io_arm_q = 1'bx; ctrl_probe_state = 1; end
                "ARM_Z": begin force u_dut.io_arm_q = 1'bz; ctrl_probe_state = 1; end
                "SIDE_X": begin force u_dut.side_pending_w = 1'bx; ctrl_probe_state = 1; end
                "SIDE_Z": begin force u_dut.side_pending_w = 1'bz; ctrl_probe_state = 1; end
                "TRAP_X": begin force u_dut.tc_trap_valid = 1'bx; ctrl_probe_state = 1; end
                "TRAP_Z": begin force u_dut.tc_trap_valid = 1'bz; ctrl_probe_state = 1; end
                default: ctrl_probe_state = 2;
            endcase
        end else if (rst_n && dev_rd_pend && ctrl_probe_state == 1) begin
            #1;
            release u_dut.io_arm_q;
            release u_dut.side_pending_w;
            release u_dut.tc_trap_valid;
            ctrl_probe_state = 2;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (ext_id == 17) begin
                if ((u_dut.ad_st_q === 4'd5) && (u_dut.d_ptw_want_w === 1'b1) &&
                    (u_dut.ptw_idle_w === 1'b1) && (u_dut.ptw_req_ready_w === 1'b1))
                    a_tr_ready_want_count <= a_tr_ready_want_count + 1;
                if ((u_dut.d_tag_cancel_live_load_w === 1'b1) &&
                    (u_dut.d_ptw_want_w === 1'b1) && (u_dut.d_ptw_accept_w === 1'b1)) begin
                    $display("PROFILE_A_OLD_GATE_RED t=%0t ad=%0d va=%08x tag=%0d accept=%b idle=%b ready=%b",
                             $time, u_dut.ad_st_q, u_dut.d_va_q, u_dut.d_tag_q,
                             u_dut.d_ptw_accept_w, u_dut.ptw_idle_w, u_dut.ptw_req_ready_w);
                    $fatal;
                end
                if (!a_profile_s_window && (u_dut.csr_priv_2 === 2'b01)) begin
                    a_profile_s_window <= 1'b1;
                    $display("PROFILE_A_S_WINDOW_START t=%0t", $time);
                end
                if (a_profile_s_window && u_dut.tc_trap_valid) begin
                    if (u_dut.tc_trap_target === 2'b11) a_m_trap_count <= a_m_trap_count + 1;
                    else if (u_dut.tc_trap_target === 2'b01) a_s_trap_count <= a_s_trap_count + 1;
                    $display("PROFILE_A_TRAP_EVENT t=%0t target=%b cause=%08x epc=%08x",
                             $time, u_dut.tc_trap_target, u_dut.tc_trap_cause, u_dut.tc_trap_epc);
                end
                if ((u_dut.d_tag_cancel_live_load_w === 1'b1) &&
                    (u_dut.d_va_q === 32'h00400000)) begin
                    a_kill_seen <= 1'b1;
                    a_cancel_lifetime_active <= 1'b1;
                    a_cancel_tag <= u_dut.d_tag_q[2:0];
                    a_cancel_va <= u_dut.d_va_q;
                    a_cancel_kill_samples <= a_cancel_kill_samples + 1;
                    if (u_dut.ad_st_q === 4'd5) a_kill_seen <= 1'b1;
                    if (a_ghost_monitor_rsp_v &&
                        (a_ghost_monitor_rsp_tag === u_dut.d_tag_q[2:0])) begin
                        a_ghost_rsp_count <= a_ghost_rsp_count + 1;
                        if (a_ghost_neg_fire) a_ghost_neg_used <= 1'b1;
                        $display("PROFILE_A_GHOST_RSP_OBSERVED t=%0t phase=kill tag=%0d actual=%b injected=%b",
                                 $time, u_dut.d_tag_q[2:0], u_dut.d_rsp_v_w, a_ghost_neg_fire);
                    end
                end else if (a_cancel_lifetime_active) begin
                    a_cancel_lifetime_cycles <= a_cancel_lifetime_cycles + 1;
                    if (a_ghost_monitor_rsp_v && (a_ghost_monitor_rsp_tag === a_cancel_tag)) begin
                        a_ghost_rsp_count <= a_ghost_rsp_count + 1;
                        if (a_ghost_neg_fire) a_ghost_neg_used <= 1'b1;
                        $display("PROFILE_A_GHOST_RSP_OBSERVED t=%0t phase=cancel-life ad=%0d tag=%0d actual=%b injected=%b",
                                 $time, u_dut.ad_st_q, a_cancel_tag, u_dut.d_rsp_v_w, a_ghost_neg_fire);
                    end
                    if (u_dut.ad_st_q === 4'd11) begin
                        a_stale_seen <= 1'b1;
                        a_stale_cycle_count <= a_stale_cycle_count + 1;
                        a_cancel_stale_samples <= a_cancel_stale_samples + 1;
                    end
                    if (a_stale_seen && (u_dut.ad_st_q === 4'd0)) begin
                        a_stale_idle_seen <= 1'b1;
                        a_cancel_idle_samples <= a_cancel_idle_samples + 1;
                    end
                    if (u_dut.d_start && (u_dut.lsu_req_tag === a_cancel_tag)) begin
                        a_owner_reuse_seen <= 1'b1;
                        a_tag_reuse_count <= a_tag_reuse_count + 1;
                        a_cancel_lifetime_active <= 1'b0;
                        $display("PROFILE_A_CANCEL_TAG_REUSED t=%0t tag=%0d va=%08x",
                                 $time, a_cancel_tag, u_dut.lsu_req_a);
                    end
                end
            end
        end
    end
    always @(posedge clk) begin
        if (rst_n && (ext_id == 18) && $test$plusargs("PROFILE_B_CACHED_DATA")) begin
            if (!b_profile_s_window && (u_dut.csr_priv_2 === 2'b01)) begin
                b_profile_s_window <= 1'b1;
                $display("PROFILE_B_S_WINDOW_START t=%0t", $time);
            end
            if (b_profile_s_window && u_dut.tc_trap_valid) begin
                if (u_dut.tc_trap_target === 2'b11) b_m_trap_count <= b_m_trap_count + 1;
                else if (u_dut.tc_trap_target === 2'b01) b_s_trap_count <= b_s_trap_count + 1;
                $display("PROFILE_B_TRAP_EVENT t=%0t target=%b cause=%08x epc=%08x",
                         $time, u_dut.tc_trap_target, u_dut.tc_trap_cause, u_dut.tc_trap_epc);
            end
            if (u_dut.d_ptw_want_w && (u_dut.d_va_q === 32'h00401000))
                b_warm_tr_count <= b_warm_tr_count + 1;
            if (u_dut.d_ptw_want_w && (u_dut.d_va_q === 32'h00401200))
                b_target_tr_count <= b_target_tr_count + 1;
            if (u_dut.ptw_req_v_w && u_dut.ptw_free_w && u_dut.d_ptw_accept_w &&
                (u_dut.ptw_req_va_w === 32'h00401000))
                b_warm_accept_count <= b_warm_accept_count + 1;
            if (u_dut.d_start && (u_dut.lsu_req_we === 1'b0) &&
                (u_dut.lsu_req_a === 32'h00401200)) begin
                b_target_start_count <= b_target_start_count + 1;
                if (!b_kill_seen) b_initial_tag <= u_dut.lsu_req_tag;
                else if (u_dut.lsu_req_tag === b_cancelled_tag[2:0])
                    b_same_tag_reuse_count <= b_same_tag_reuse_count + 1;
                $display("PROFILE_B_DATA_START t=%0t va=%08x tag=%0d xlat=%b",
                         $time, u_dut.lsu_req_a, u_dut.lsu_req_tag, u_dut.d_xlat_need_w);
            end
            if ((u_dut.d_tag_cancel_live_load_w === 1'b1) &&
                (u_dut.d_va_q === 32'h00401200)) begin
                b_kill_seen <= 1'b1;
                b_cancelled_tag <= u_dut.d_tag_q;
                b_cancel_tag <= u_dut.d_tag_q[2:0];
                b_cancel_lifetime_active <= 1'b1;
                b_cancel_kill_samples <= b_cancel_kill_samples + 1;
                b_fetch_va <= u_dut.u_ptw.va_r;
                $display("PROFILE_B_INFLIGHT_IF_OWNER t=%0t active_va=%08x request_input_va=%08x owner=%b",
                         $time, u_dut.u_ptw.va_r, u_dut.ptw_req_va_w, u_dut.ptw_owner_fetch_w);
                if (u_dut.ptw_owner_fetch_w && !u_dut.ptw_idle_w)
                    b_tagkill_fetch_busy_count <= b_tagkill_fetch_busy_count + 1;
                if (u_dut.ptw_kill_w && u_dut.ptw_owner_fetch_w)
                    b_owner_fetch_kill_count <= b_owner_fetch_kill_count + 1;
                $display("PROFILE_B_DATA_KILL t=%0t ad=%0d va=%08x tag=%0d axi_pend=%b l1d_busy=%b owner_fetch=%b ptw_idle=%b ptw_kill=%b",
                         $time, u_dut.ad_st_q, u_dut.d_va_q, u_dut.d_tag_q,
                         u_dut.d_axi_pend_q, u_dut.l1d_busy_w,
                         u_dut.ptw_owner_fetch_w, u_dut.ptw_idle_w, u_dut.ptw_kill_w);
                if (b_ghost_monitor_rsp_v &&
                    (b_ghost_monitor_rsp_tag === u_dut.d_tag_q[2:0])) begin
                    b_ghost_rsp_count <= b_ghost_rsp_count + 1;
                    if (b_ghost_neg_fire) b_ghost_neg_used <= 1'b1;
                    $display("PROFILE_B_GHOST_RSP_OBSERVED t=%0t phase=kill tag=%0d actual=%b injected=%b",
                             $time, u_dut.d_tag_q[2:0], u_dut.d_rsp_v_w, b_ghost_neg_fire);
                end
            end else if (b_cancel_lifetime_active) begin
                b_cancel_lifetime_cycles <= b_cancel_lifetime_cycles + 1;
                if (u_dut.ad_st_q === 4'd0) b_cancel_idle_samples <= b_cancel_idle_samples + 1;
                if (u_dut.d_start && (u_dut.lsu_req_tag === b_cancel_tag)) begin
                    b_owner_reuse_seen <= 1'b1;
                    b_owner_reuse_count <= b_owner_reuse_count + 1;
                    b_cancel_lifetime_active <= 1'b0;
                    if (b_ghost_neg_fire) b_ghost_neg_used <= 1'b1;
                    $display("PROFILE_B_CANCEL_TAG_REUSED t=%0t tag=%0d va=%08x",
                             $time, b_cancel_tag, u_dut.lsu_req_a);
                end else if (b_ghost_monitor_rsp_v && (b_ghost_monitor_rsp_tag === b_cancel_tag)) begin
                    b_ghost_rsp_count <= b_ghost_rsp_count + 1;
                    if (b_ghost_neg_fire) b_ghost_neg_used <= 1'b1;
                    $display("PROFILE_B_GHOST_RSP_OBSERVED t=%0t phase=cancel-life ad=%0d tag=%0d actual=%b injected=%b",
                             $time, u_dut.ad_st_q, b_cancel_tag, u_dut.d_rsp_v_w, b_ghost_neg_fire);
                end
            end
            if (b_kill_seen && (u_dut.ad_st_q === 4'd11)) begin
                b_stale_seen <= 1'b1;
                b_stale_busy_cycles <= b_stale_busy_cycles + 1;
                if (b_cancel_lifetime_active) b_cancel_stale_samples <= b_cancel_stale_samples + 1;
                if (u_dut.ptw_owner_fetch_w && !u_dut.ptw_idle_w)
                    $display("PROFILE_B_STALE_FETCH_BUSY t=%0t l1d_idle=%b pte_req=%b pte_go=%b",
                             $time, u_dut.l1d_idle, u_dut.ptw_pte_req_valid, u_dut.pte_rd_go_w);
                if (u_dut.l1d_idle && u_dut.ptw_owner_fetch_w && !u_dut.ptw_idle_w)
                    b_stale_exit_fetch_busy <= b_stale_exit_fetch_busy + 1;
            end
            if (b_stale_seen && (u_dut.ad_st_q === 4'd0) &&
                u_dut.ptw_owner_fetch_w && !u_dut.ptw_idle_w) begin
                b_stale_idle_seen <= 1'b1;
                if (!b_post_exit_active) begin
                    b_post_exit_active <= 1'b1;
                    $display("PROFILE_B_POST_STALE_IF_STILL_BUSY t=%0t owner_va=%08x request_input_va=%08x", $time, u_dut.u_ptw.va_r, u_dut.ptw_req_va_w);
                end
            end
            if ((b_post_exit_active ||
                 (b_stale_seen && (u_dut.ad_st_q === 4'd0) && u_dut.ptw_owner_fetch_w && !u_dut.ptw_idle_w)) &&
                u_dut.ptw_owner_fetch_w && (u_dut.u_ptw.va_r === b_fetch_va)) begin
                if (u_dut.pte_rd_go_w) begin
                    if (b_post_pending) b_post_sequence_error <= b_post_sequence_error + 1;
                    if ((b_post_req_index == 0) && (u_dut.ptw_pte_req_pa !== 32'h8001b804))
                        b_post_sequence_error <= b_post_sequence_error + 1;
                    else if ((b_post_req_index == 1) && (u_dut.ptw_pte_req_pa !== 32'h8001e000))
                        b_post_sequence_error <= b_post_sequence_error + 1;
                    else if (b_post_req_index > 1) b_post_sequence_error <= b_post_sequence_error + 1;
                    b_post_pending <= 1'b1;
                    b_post_pending_pa <= u_dut.ptw_pte_req_pa;
                    b_post_req_index <= b_post_req_index + 1;
                    $display("PROFILE_B_POST_PTE_REQ t=%0t n=%0d va=%08x pa=%08x",
                             $time, b_post_req_index, u_dut.u_ptw.va_r, u_dut.ptw_pte_req_pa);
                end
                if (u_dut.pte_resp_valid_w) begin
                    if (!b_post_pending) b_post_sequence_error <= b_post_sequence_error + 1;
                    else if ((b_post_pending_pa === 32'h8001b804) &&
                             (u_dut.pte_resp_data_w === 32'h20007801)) begin
                        b_post_root_done <= b_post_root_done + 1;
                        b_post_rsp_count <= b_post_rsp_count + 1;
                        b_post_pending <= 1'b0;
                        $display("PROFILE_B_POST_PTE_DONE t=%0t pa=%08x pte=%08x",
                                 $time, b_post_pending_pa, u_dut.pte_resp_data_w);
                    end else if ((b_post_pending_pa === 32'h8001e000) &&
                                 (u_dut.pte_resp_data_w === 32'h20000ccf)) begin
                        b_post_leaf_done <= b_post_leaf_done + 1;
                        b_post_rsp_count <= b_post_rsp_count + 1;
                        b_post_pending <= 1'b0;
                        b_post_complete <= 1'b1;
                        $display("PROFILE_B_POST_PTE_DONE t=%0t pa=%08x pte=%08x",
                                 $time, b_post_pending_pa, u_dut.pte_resp_data_w);
                    end else begin
                        b_post_sequence_error <= b_post_sequence_error + 1;
                        b_post_pending <= 1'b0;
                    end
                end
                if (b_post_walk_done_monitor) begin
                    b_post_walk_done_count <= b_post_walk_done_count + 1;
                    $display("PROFILE_B_POST_WALK_DONE_OBSERVED t=%0t owner_va=%08x neg_duplicate=%b",
                             $time, u_dut.u_ptw.va_r, b_post_walk_dup_pulse);
                end
                if (b_post_walk_done_actual && $test$plusargs("PROFILE_B_REPEAT_DONE_NEGCTRL") &&
                    (b_post_walk_neg_used == 0)) begin
                    b_post_walk_dup_pulse <= 1'b1;
                    b_post_walk_neg_used <= 1;
                    $display("PROFILE_B_REPEAT_DONE_NEGCTRL_INJECT t=%0t owner_va=%08x",
                             $time, u_dut.u_ptw.va_r);
                end else b_post_walk_dup_pulse <= 1'b0;
            end
            if (u_dut.pte_rd_go_w && u_dut.ptw_owner_fetch_w) begin
                b_fetch_pte_service_count <= b_fetch_pte_service_count + 1;
                $display("PROFILE_B_FETCH_PTE_SERVICE t=%0t pa=%08x", $time, u_dut.ptw_pte_req_pa);
            end
        end
    end

    // 调试探针（定向失败时定位用；不参与判据）
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            if ((ext_id == 10) || (ext_id == 15) || (ext_id == 16) ||
                (ext_id == 17) || (ext_id == 18)) begin
                if ((u_dut.redirect_valid === 1'b1) &&
                    (u_dut.redirect_pc === ext_branch_redirect_target)) begin
                    if (!ext_branch_match_prev) begin
                        ext_branch_redirect_count <= ext_branch_redirect_count + 1;
                        $display("DBG_BRANCH_REDIRECT t=%0t pc=%08x", $time, u_dut.redirect_pc);
                    end
                    ext_branch_match_prev <= 1'b1;
                end else ext_branch_match_prev <= 1'b0;
                if ((u_dut.ptw_req_v_w === 1'b1) && (u_dut.ptw_free_w === 1'b1) &&
                    (u_dut.d_ptw_accept_w === 1'b0) &&
                    (u_dut.ptw_req_va_w[31:22] === ext_itlb_target[31:22])) begin
                    if (!ext_itlb_match_prev) begin
                        ext_itlb_req_count <= ext_itlb_req_count + 1;
                        $display("DBG_ITLB_PTW_ACCEPT t=%0t va=%08x", $time, u_dut.ptw_req_va_w);
                    end
                    ext_itlb_match_prev <= 1'b1;
                end else ext_itlb_match_prev <= 1'b0;
            end
            if (ext_id == 15) begin
                if ((u_dut.ad_st_q === 4'd6) && (u_dut.l1d_cs_ready === 1'b1) &&
                    (u_dut.d_pte_pa_q === 32'h8001b004)) begin
                    if (!ext_root_pte_hit_prev) begin
                        if (ext_root_pte_hit_count == 0) ext_root_pte_hit_first_cycle <= cyc;
                        ext_root_pte_hit_count <= ext_root_pte_hit_count + 1;
                        $display("DBG_ROOT_PTE_L1D_HIT t=%0t pa=%08x", $time, u_dut.d_pte_pa_q);
                    end
                    if (u_dut.d_tag_cancel_live_load_w === 1'b1) begin
                        ext_ptehit_tagkill_count <= ext_ptehit_tagkill_count + 1;
                        $display("DBG_ROOT_PTE_HIT_TAGKILL t=%0t ad=%0d", $time, u_dut.ad_st_q);
                    end
                    ext_root_pte_hit_prev <= 1'b1;
                end else ext_root_pte_hit_prev <= 1'b0;
            end else ext_root_pte_hit_prev <= 1'b0;
            if ((ext_id == 10) || (ext_id == 15) || (ext_id == 16) ||
                (ext_id == 17) || (ext_id == 18)) begin
                if ((u_dut.ptw_req_v_w === 1'b1) && (u_dut.ptw_free_w === 1'b1) &&
                    (u_dut.d_ptw_accept_w === 1'b1) && (u_dut.ptw_req_va_w === 32'h00400000)) begin
                    ext_data_ptw_accept_count <= ext_data_ptw_accept_count + 1;
                    $display("DBG_DATA_PTW_ACCEPT t=%0t va=%08x", $time, u_dut.ptw_req_va_w);
                end
                if (u_dut.d_tag_cancel_live_load_w === 1'b1) begin
                    if (!ext_tagkill_prev) begin
                        ext_tagkill_count <= ext_tagkill_count + 1;
                        ext_tagkill_ad_state <= u_dut.ad_st_q; ext_tagkill_cycle <= cyc;
                        if (u_dut.ptw_idle_w === 1'b1) ext_kill_ptw_idle_count <= ext_kill_ptw_idle_count + 1;
                        if (u_dut.ptw_req_ready_w === 1'b1) ext_kill_req_ready_count <= ext_kill_req_ready_count + 1;
                        if (u_dut.ptw_owner_fetch_w === 1'b1) ext_kill_owner_fetch_count <= ext_kill_owner_fetch_count + 1;
                        if (u_dut.d_ptw_want_w === 1'b1) ext_kill_tr_want_count <= ext_kill_tr_want_count + 1;
                        if (u_dut.d_ptw_accept_w === 1'b1) ext_kill_d_accept_count <= ext_kill_d_accept_count + 1;
                        if ((u_dut.ptw_req_v_w === 1'b1) && (u_dut.ptw_free_w === 1'b1) &&
                            (u_dut.d_ptw_accept_w === 1'b1))
                            ext_kill_handshake_count <= ext_kill_handshake_count + 1;
                        $display("DBG_DATA_TAGKILL t=%0t ad=%0d tr_want=%b ptw_req_v=%b ptw_free=%b d_accept=%b req_va=%08x owner_fetch=%b ptw_idle=%b req_ready=%b m_tr_src=%b ptw_kill=%b",
                                 $time, u_dut.ad_st_q, u_dut.d_ptw_want_w, u_dut.ptw_req_v_w,
                                 u_dut.ptw_free_w, u_dut.d_ptw_accept_w, u_dut.ptw_req_va_w,
                                 u_dut.ptw_owner_fetch_w, u_dut.ptw_idle_w, u_dut.ptw_req_ready_w,
                                 u_dut.m_tr_src_q, u_dut.ptw_kill_w);
                    end
                    ext_tagkill_prev <= 1'b1;
                end else ext_tagkill_prev <= 1'b0;
            end else ext_tagkill_prev <= 1'b0;
            if ((ext_id == 11) && (u_dut.pmp_redir_w === 1'b1) &&
                (u_dut.be_trp_redirect_pc === ext_pmp_after_pc)) begin
                ext_pmp_after_count <= ext_pmp_after_count + 1;
                ext_pmp_after_cycle <= cyc;
                $display("DBG_PMP_AFTER_REDIRECT cycle=%0d pc=%08x event=%0d",
                         cyc, u_dut.be_trp_redirect_pc, ext_pmp_after_count + 1);
            end
            if (arvalid & arready) $display("AXI_AR t=%0t addr=0x%08x", $time, map_addr(araddr));
            if (rvalid & rready)   $display("AXI_R  t=%0t addr=0x%08x data=0x%08x dev=%0d",
                                            $time, r_addr, rdata_r, dev_cnt);
            if (u_dut.stx_fast_go_w && (u_dut.stx_fast_pmp_pa_w[31:16] == 16'h1FE0))
                $display("DBG_FAST t=%0t pa=%08x bytes=%0d cfg1=%08x allow=%b",
                         $time, u_dut.stx_fast_pmp_pa_w, u_dut.stx_bm_bytes_w,
                         u_dut.pmp_cfg_flat[63:32], u_dut.pmp_allow_w);
            if (u_dut.trp_exc_w)
                $display("DBG_TRAP t=%0t cause=%0d pc=%08x epc=%08x tval=%08x",
                         $time, u_dut.tc_trap_cause, u_dut.tc_trap_pc,
                         u_dut.tc_trap_epc, u_dut.tc_trap_tval);
            if (u_dut.pmp_cmt_w)
                $display("DBG_PMPCMT t=%0t next=%08x pend=%b", $time, u_dut.pmp_cmt_next_pc_w, u_dut.pmp_pend_q);
            if (u_dut.pmp_redir_w)
                $display("DBG_PMPREDIR t=%0t pc=%08x", $time, u_dut.be_trp_redirect_pc);
            if (u_dut.d_start)
                $display("D_START t=%0t we=%b head=%b unc=%b cp=%b xlat=%b a=0x%08x",
                         $time, u_dut.lsu_req_we, u_dut.mem_req_is_head_w,
                         u_dut.d_unc_w, u_dut.d_clint_plic, u_dut.d_xlat_need_w, u_dut.lsu_req_a);
            if (u_dut.i_fire && (u_dut.i_own_new == 3'd2))
                $display("DUNC_FIRE t=%0t addr=0x%08x wr=%b", $time, u_dut.i_addr_new, u_dut.i_req_wr);
            if (u_dut.d_rsp_v_w)
                $display("D_RSP t=%0t tag=%0d defer=%b side=%b cause=%0d ad=%0d",
                         $time, u_dut.d_rsp_tag_w, u_dut.mem_rsp_defer_w,
                         u_dut.mem_rsp_side_w, u_dut.mem_rsp_cause_w, u_dut.ad_st_q);
        end
    end

    //--------------------------------------------------------------------------
    // 结果判定（邮箱在 uncached 窗，AXI 写直接落 DDR 数组）
    //--------------------------------------------------------------------------
    reg [31:0] mb [0:63];
    integer    k, nchk, timeout, done_at;
    reg [31:0] w;
    initial begin
        #1;
        if (ext_id == 0) begin
        timeout = 0; w = 0; done_at = -1;
        while (timeout < MAX_CYCLES) begin
            @(posedge clk);
            timeout = timeout + 1;
            for (k = 0; k < 64; k = k + 1) mb[k] = ddr[(32'h1000 >> 2) + k];
            done_at = -1;
            for (k = 0; k < 64; k = k + 1) if (mb[k] == DONE && done_at < 0) done_at = k;
            if (done_at > 0) begin
                if (schema_probe_mode == "NCHK0") mb[1] = 32'd0;
                if (schema_probe_mode == "NCHKX") mb[1] = 32'hxxxxxxxx;
                if (schema_probe_mode == "UARTX") uart_wr_q[0] = 8'hxx;
                if (mb[0] !== MAGIC) begin
                    $display("FAIL: bad magic 0x%08x", mb[0]); $fatal;
                end
                if (mb[1] !== 32'd16) begin
                    $display("FAIL: fixed schema requires nchk=16 (got %08x)", mb[1]); $fatal;
                end
                nchk = 16;
                $display("DATA_BUS_RESULT nchk=%0d done_at=%0d", nchk, done_at);
                if (done_at !== 18) begin
                    $display("FAIL: fixed schema requires done_at=18 (got %0d)", done_at); $fatal;
                end
                if (uart_wr_cnt !== 3 || uart_wr_q[0] !== 8'hAA || uart_wr_q[1] !== 8'hBB || uart_wr_q[2] !== 8'h5A) begin
                    $display("FAIL: ecall/maint UART writes cnt=%0d q=%02x %02x %02x (want 3 AA BB 5A)",
                             uart_wr_cnt, uart_wr_q[0], uart_wr_q[1], uart_wr_q[2]);
                    $fatal;
                end
                $display("DATA_BUS_UART cnt=%0d q=%02x %02x %02x",
                         uart_wr_cnt, uart_wr_q[0], uart_wr_q[1], uart_wr_q[2]);
                for (i = 0; i < nchk; i = i + 1) begin
                    $display("  r%0d = %0d", i + 1, mb[2 + i]);
                    if (mb[2 + i] !== 32'd1) begin
                        $display("FAIL: r%0d != 1 (got %0d)", i + 1, mb[2 + i]);
                        $display("  dbg s7=0x%08x s8=0x%08x", ddr[(32'h1050)>>2], ddr[(32'h1054)>>2]);
                        $display("  dbg tgtTD=%0d tgtTS=%0d tgtTP=%0d tgtTC=%0d mb_wr=%0d",
                                 tgtTD_wr, tgtTS_wr, tgtTP_wr, tgtTC_wr, mb_wr_cnt);
                        for (k = 0; k < 18; k = k + 1) $display("  mb[%0d]=%0d", k, mb[k]);
                        $display("  dbg t6@108c=%0d cfg@1088=%08x", ddr[32'h108C>>2], ddr[32'h1088>>2]);
                        $display("  dbg cfg1=%08x cfg0=%08x pmpaddr6=%08x",
                                 u_dut.pmp_cfg_flat[63:32], u_dut.pmp_cfg_flat[31:0],
                                 u_dut.pmp_addr_flat[6*32 +: 32]);
                        $fatal;
                    end
                end
                $display("DATA_BUS_COUNTS dev_uart=%0d kill_dev=%0d mb_wr=%0d uart_wr=%0d uart0=%02x uart1=%02x tgtTD=%0d tgtTS=%0d tgtTP=%0d tgtTC=%0d arm_gap=%0d irq_in_io=%0d errs=%0d kill_ph=%0d arm_seen=%0d irq_pend_io=%0d",
                         dev_cnt, kill_cnt, mb_wr_cnt, uart_wr_cnt, uart_wr_q[0], uart_wr_q[1],
                         tgtTD_wr, tgtTS_wr, tgtTP_wr, tgtTC_wr,
                         arm_gap, irq_in_io, errs, kill_ph, arm_seen, irq_pend_io);
                $display("  dbg s7=0x%08x s8=0x%08x", ddr[(32'h1050)>>2], ddr[(32'h1054)>>2]);
                if (dev_cnt  !== 2) begin $display("FAIL: UART device reads=%0d want=2", dev_cnt); $fatal; end
                // native uncached store 每 descriptor 只 accept 一次：2 header + 14 results + 2 extra + DONE
                if (mb_wr_cnt !== 21) begin $display("FAIL: mailbox uncached writes=%0d want=21 (duplicate accept)", mb_wr_cnt); $fatal; end
                // PMP 动态：旧预检的年轻 store 必须 0 写；非 PMP CSR 正控必须 1 写
                if (uart_wr_cnt !== 3 || uart_wr_q[0] !== 8'hAA || uart_wr_q[1] !== 8'hBB || uart_wr_q[2] !== 8'h5A)
                    begin $display("FAIL: ecall/maint UART writes cnt=%0d q=%02x %02x %02x (want 3 AA BB 5A)",
                                   uart_wr_cnt, uart_wr_q[0], uart_wr_q[1], uart_wr_q[2]); $fatal; end
                if (tgtTD_wr !== 0) begin $display("FAIL: PMP cfg-dynamic store wrote %0d (want 0)", tgtTD_wr); $fatal; end
                if (tgtTS_wr !== 0) begin $display("FAIL: same-group store wrote %0d (want 0)", tgtTS_wr); $fatal; end
                if (tgtTP_wr !== 0) begin $display("FAIL: PMPADDR-dynamic store wrote %0d (want 0)", tgtTP_wr); $fatal; end
                if (tgtTC_wr !== 1) begin $display("FAIL: non-PMP CSR control store wrote %0d (want 1)", tgtTC_wr); $fatal; end
                if ((ddr[(32'h1000 + 32'h84) >> 2] & 32'hFF) !== 32'h5A)
                    begin $display("FAIL: byte store data lost: 0x%08x", ddr[(32'h1000 + 32'h3C) >> 2]); $fatal; end
                if (kill_cnt !== 1) begin $display("FAIL: KILL device reads=%0d want=1", kill_cnt); $fatal; end
                if (arm_gap  !== 0) begin $display("FAIL: io protection gap=%0d", arm_gap); $fatal; end
                if (irq_in_io !== 0) begin $display("FAIL: irq during device IO=%0d", irq_in_io); $fatal; end
                if (errs     !== 0) begin $display("FAIL: tb errs=%0d", errs); $fatal; end
                if (kill_ph  !== 2'd3) begin $display("FAIL: kill not injected ph=%0d", kill_ph); $fatal; end
                if (arm_seen === 0) begin $display("FAIL: device IO never armed (scenario not reached)"); $fatal; end
                if (irq_pend_io === 0) begin $display("FAIL: MTIP never pending during device IO (scenario not reached)"); $fatal; end
                // 被拒 store 零物理写：DENY 窗口保持初值 0x13
                if (ddr[32'h11000 >> 2] !== 32'h0000_0013) begin
                    $display("FAIL: denied store wrote memory: 0x%08x", ddr[32'h11000 >> 2]); $fatal;
                end
                $display("TB_DATA_BUS_SEMANTICS: PASS");
                $finish;
            end
        end
        $display("FAIL: timeout (dev=%0d kill=%0d arm_gap=%0d irq_io=%0d errs=%0d)",
                 dev_cnt, kill_cnt, arm_gap, irq_in_io, errs);
        $fatal;
        end
    end

    // Independent product extension mailbox; base 16-check schema stays fixed.
    integer ext_timeout;
    reg [31:0] ext_cause, ext_traps, ext_value, ext_tval;
    integer ext_denied_w, ext_slow_w, ext_root_ar, ext_leaf_ar, ext_alias_ar;
    integer ext_rdelay_ars, ext_rdelay_nbeats, ext_branch_redirs, ext_itlb_reqs;
    integer ext_cached_data_ars, ext_cached_data_nbeats;
    integer ext_bdelay_ws, ext_bdelay_bs, ext_bdelay_wait, ext_bdelay_rsp, ext_pmp_after_n, ext_pmp_after_t;
    integer ext_ptehit_n, ext_ptehit_first_cycle, ext_dptw_accept_n, ext_tagkill_n, ext_tagkill_state, ext_arstall_wait, ext_arstall_cancel;
    integer ext_arstall_accept_n, ext_arstall_accept_t, ext_tagkill_t, ext_arstall_beats;
    integer ext_arstall_first_held_t, ext_data_rdelay_ar_t, ext_data_rdelay_rsp_t;
    integer ext_m_traps, ext_s_traps, ext_s6_exec;
    integer ext_ptehit_kill, ext_kill_tr_want, ext_kill_d_accept, ext_kill_handshake;
    integer ext_kill_idle, ext_kill_ready, ext_kill_owner;
    reg [31:0] ext_branch_marker, ext_itlb_marker;
    initial begin
        #1;
        if (ext_id != 0) begin
            ext_timeout = 0;
            while (ext_timeout < MAX_CYCLES) begin
                @(posedge clk); ext_timeout = ext_timeout + 1;
                if (ddr[32'h1100 >> 2] === 32'h4558544f) begin
                    if (schema_probe_mode == "STVAL0") ddr[32'h1114 >> 2] = 32'h00000000;
                    if (schema_probe_mode == "STVALPA") ddr[32'h1114 >> 2] = 32'h8001c000;
                    if (schema_probe_mode == "EXTRA_M") ddr[32'h1120 >> 2] = ddr[32'h1120 >> 2] + 1;
                    if (schema_probe_mode == "EXTRA_S") ddr[32'h1124 >> 2] = ddr[32'h1124 >> 2] + 1;
                    ext_cause = ddr[32'h1104 >> 2];
                    ext_traps = ddr[32'h1108 >> 2];
                    ext_value = ddr[32'h110c >> 2];
                    ext_tval = ddr[32'h1114 >> 2];
                    ext_denied_w = ext_denied_w_count; ext_slow_w = ext_slow_w_count;
                    ext_root_ar = ext_root_pte_ar; ext_leaf_ar = ext_leaf_pte_ar;
                    ext_alias_ar = ext_high_alias_count;
                    ext_rdelay_ars = ext_rdelay_ar_count; ext_rdelay_nbeats = ext_rdelay_beats;
                    ext_branch_redirs = ext_branch_redirect_count; ext_itlb_reqs = ext_itlb_req_count;
                    ext_cached_data_ars = ext_cached_data_ar_count;
                    ext_cached_data_nbeats = ext_cached_data_beats;
                    ext_bdelay_ws = ext_bdelay_w_count; ext_bdelay_bs = ext_bdelay_b_count;
                    ext_bdelay_wait = ext_bdelay_wait_cycles; ext_bdelay_rsp = ext_bdelay_rsp_cycle;
                    ext_pmp_after_n = ext_pmp_after_count; ext_pmp_after_t = ext_pmp_after_cycle;
                    ext_ptehit_n = ext_root_pte_hit_count; ext_ptehit_first_cycle = ext_root_pte_hit_first_cycle;
                    ext_dptw_accept_n = ext_data_ptw_accept_count;
                    ext_tagkill_n = ext_tagkill_count; ext_tagkill_state = ext_tagkill_ad_state;
                    ext_arstall_wait = ext_arstall_wait_count; ext_arstall_cancel = ext_arstall_cancel_count;
                    ext_arstall_accept_n = ext_arstall_accept_count; ext_arstall_accept_t = ext_arstall_accept_cycle;
                    ext_tagkill_t = ext_tagkill_cycle; ext_arstall_beats = ext_arstall_rbeats;
                    ext_arstall_first_held_t = ext_arstall_first_held_cycle;
                    ext_data_rdelay_ar_t = ext_data_rdelay_ar_cycle;
                    ext_data_rdelay_rsp_t = ext_data_rdelay_rsp_cycle;
                    ext_m_traps = ddr[32'h1120 >> 2]; ext_s_traps = ddr[32'h1124 >> 2];
                    ext_s6_exec = ddr[32'h1128 >> 2];
                    ext_ptehit_kill = ext_ptehit_tagkill_count; ext_kill_tr_want = ext_kill_tr_want_count;
                    ext_kill_d_accept = ext_kill_d_accept_count; ext_kill_handshake = ext_kill_handshake_count;
                    ext_kill_idle = ext_kill_ptw_idle_count; ext_kill_ready = ext_kill_req_ready_count;
                    ext_kill_owner = ext_kill_owner_fetch_count;
                    ext_branch_marker = ddr[32'h1118 >> 2]; ext_itlb_marker = ddr[32'h111c >> 2];
                    $display("DATA_BUS_EXTENSION_RESULT id=%0d cause=%0d traps=%0d value=%08x tval=%08x rerr=%0d denied_w=%0d slow_w=%0d root_ar=%0d leaf_ar=%0d alias_ar=%0d rdelay_ar=%0d rdelay_beats=%0d br_redir=%0d itlb_req=%0d br_mark=%08x itlb_mark=%08x cached_ar=%0d cached_beats=%0d bdelay_w=%0d bdelay_b=%0d bdelay_wait=%0d bdelay_rsp_cycle=%0d pmp_after_n=%0d pmp_after_cycle=%0d ptehit=%0d ptehit_first_cycle=%0d dptw_accept=%0d tagkill=%0d tagkill_ad=%0d arstall_wait=%0d arstall_cancel=%0d arstall_accept=%0d arstall_accept_cycle=%0d tagkill_cycle=%0d arstall_beats=%0d ptehit_tagkill=%0d kill_tr_want=%0d kill_d_accept=%0d kill_handshake=%0d kill_idle=%0d kill_ready=%0d kill_owner_fetch=%0d m_traps=%0d s_traps=%0d s6_exec=%0d data_rdelay_ar_cycle=%0d data_rdelay_rsp_cycle=%0d arstall_first_held_cycle=%0d",
                             ext_id, ext_cause, ext_traps, ext_value, ext_tval, rerr_count,
                             ext_denied_w, ext_slow_w, ext_root_ar, ext_leaf_ar, ext_alias_ar,
                             ext_rdelay_ars, ext_rdelay_nbeats, ext_branch_redirs, ext_itlb_reqs,
                             ext_branch_marker, ext_itlb_marker, ext_cached_data_ars, ext_cached_data_nbeats,
                              ext_bdelay_ws, ext_bdelay_bs, ext_bdelay_wait, ext_bdelay_rsp,
                              ext_pmp_after_n, ext_pmp_after_t, ext_ptehit_n, ext_ptehit_first_cycle, ext_dptw_accept_n,
                               ext_tagkill_n, ext_tagkill_state, ext_arstall_wait, ext_arstall_cancel,
                               ext_arstall_accept_n, ext_arstall_accept_t, ext_tagkill_t, ext_arstall_beats, ext_ptehit_kill, ext_kill_tr_want,
                               ext_kill_d_accept, ext_kill_handshake, ext_kill_idle, ext_kill_ready, ext_kill_owner, ext_m_traps, ext_s_traps, ext_s6_exec,
                              ext_data_rdelay_ar_t, ext_data_rdelay_rsp_t, ext_arstall_first_held_t);
                    if (((ext_id >= 2) && (ext_id <= 9)) || (ext_id == 12) ||
                         (ext_id == 13) || (ext_id == 14)) begin
                         if ((ext_m_traps !== 0) || (ext_s_traps !== 1) ||
                             (ext_tval !== 32'h00401200)) begin
                             $display("FAIL: extension S trap count/stval id=%0d m=%0d s=%0d stval=%08x",
                                      ext_id, ext_m_traps, ext_s_traps, ext_tval); $fatal;
                         end
                     end
                     if ((ext_id == 1) && ((ext_m_traps !== 1) || (ext_s_traps !== 0))) begin
                         $display("FAIL: extension M/S trap count id=1 m=%0d s=%0d", ext_m_traps, ext_s_traps); $fatal;
                     end
                     if (((ext_id == 10) || (ext_id == 11) || (ext_id == 15) || (ext_id == 16) || (ext_id == 17) || (ext_id == 18)) &&
                         ((ext_m_traps !== 0) || (ext_s_traps !== 0) || (ext_tval !== 0))) begin
                         $display("FAIL: extension unexpected trap id=%0d m=%0d s=%0d stval=%08x",
                                  ext_id, ext_m_traps, ext_s_traps, ext_tval); $fatal;
                     end
                     if ((ext_id == 17) && profile_bad_data_enabled) begin
                          if ((profile_bad_data_count === 1) && (ext_value === 32'hDEAD_C0DE)) begin
                              $display("PROFILE_A_BAD_LOAD_DATA_RED injections=%0d reported=%08x",
                                       profile_bad_data_count, ext_value);
                              $fatal;
                          end else begin
                              $display("PROFILE_A_BAD_DATA_NEGCTRL_NOT_TRIGGERED injections=%0d reported=%08x",
                                       profile_bad_data_count, ext_value);
                              $fatal;
                          end
                      end
                      if (ext_id == 17) $display("PROFILE_A_TRAP_COUNTS M=%0d S=%0d lifetime=%0d tag_reuse=%0d ghost=%0d",
                          a_m_trap_count, a_s_trap_count, a_cancel_lifetime_cycles, a_tag_reuse_count, a_ghost_rsp_count);
                      if ($test$plusargs("PROFILE_B_CACHED_DATA")) begin
                          $display("PROFILE_B_SUMMARY initial_tag=%0d killed_tag=%0d starts=%0d same_tag_reuse=%0d warm_tr=%0d target_tr=%0d warm_accept=%0d stale_busy=%0d stale_exit_busy=%0d stale_idle_fetch_busy=%b fetch_pte_service=%0d tagkill_fetch_busy=%0d fetch_owner_kills=%0d",
                                   b_initial_tag, b_cancelled_tag, b_target_start_count,
                                   b_same_tag_reuse_count, b_warm_tr_count, b_target_tr_count, b_warm_accept_count,
                                   b_stale_busy_cycles, b_stale_exit_fetch_busy,
                                   b_stale_idle_seen, b_fetch_pte_service_count, b_tagkill_fetch_busy_count, b_owner_fetch_kill_count);
                          $display("PROFILE_B_LIFETIME_TRAP_POST summary owner_reuse=%0d ghost=%0d life=%0d M=%0d S=%0d pte_req=%0d pte_rsp=%0d root_done=%0d leaf_done=%0d walk_done=%0d seqerr=%0d pending=%b complete=%b",
                                   b_owner_reuse_count, b_ghost_rsp_count, b_cancel_lifetime_cycles,
                                   b_m_trap_count, b_s_trap_count, b_post_req_index, b_post_rsp_count,
                                   b_post_root_done, b_post_leaf_done, b_post_walk_done_count,
                                   b_post_sequence_error, b_post_pending, b_post_complete);
                      end
                      if (ext_id == 17) begin
                           $display("PROFILE_A_GHOST_BOUNDARIES kill=%0d stale=%0d idle=%0d reuse=%0d active=%b neg_mode=%0d neg_used=%b",
                               a_cancel_kill_samples, a_cancel_stale_samples, a_cancel_idle_samples,
                               a_tag_reuse_count, a_cancel_lifetime_active, a_ghost_neg_mode, a_ghost_neg_used);
                           if (a_ghost_neg_mode != 0) begin
                               if (a_ghost_neg_used && (a_ghost_rsp_count === 1)) begin
                                   $display("PROFILE_A_GHOST_MONITOR_SENSITIVITY_RED mode=%0d count=%0d",
                                            a_ghost_neg_mode, a_ghost_rsp_count);
                                   $fatal;
                               end else begin
                                   $display("PROFILE_A_GHOST_NEGCTRL_NOT_TRIGGERED mode=%0d used=%b count=%0d",
                                            a_ghost_neg_mode, a_ghost_neg_used, a_ghost_rsp_count);
                                   $fatal;
                               end
                           end
                       end
                       if ((ext_id == 18) && $test$plusargs("PROFILE_B_CACHED_DATA")) begin
                           $display("PROFILE_B_GHOST_BOUNDARIES kill=%0d stale=%0d idle=%0d reuse=%0d active=%b neg_mode=%0d neg_used=%b",
                                    b_cancel_kill_samples, b_cancel_stale_samples, b_cancel_idle_samples,
                                    b_owner_reuse_count, b_cancel_lifetime_active, b_ghost_neg_mode, b_ghost_neg_used);
                           if (b_ghost_neg_mode != 0) begin
                               if (b_ghost_neg_used && (b_ghost_rsp_count === 1)) begin
                                   $display("PROFILE_B_GHOST_MONITOR_SENSITIVITY_RED mode=%0d count=%0d",
                                            b_ghost_neg_mode, b_ghost_rsp_count);
                                   $fatal;
                               end else begin
                                   $display("PROFILE_B_GHOST_NEGCTRL_NOT_TRIGGERED mode=%0d used=%b count=%0d",
                                            b_ghost_neg_mode, b_ghost_neg_used, b_ghost_rsp_count);
                                   $fatal;
                               end
                           end
                           if ($test$plusargs("PROFILE_B_REPEAT_DONE_NEGCTRL")) begin
                               if (b_post_walk_done_count > 1) begin
                                   $display("PROFILE_B_REPEAT_WALK_DONE_RED count=%0d expected=1", b_post_walk_done_count);
                                   $fatal;
                               end else begin
                                   $display("PROFILE_B_REPEAT_DONE_NEGCTRL_NOT_TRIGGERED count=%0d",
                                            b_post_walk_done_count);
                                   $fatal;
                               end
                           end
                       end
                       case (ext_id)
                        1: if ((ext_cause !== 32'd7) || (ext_traps !== 32'd1) ||
                                (ext_m_traps !== 1) || (ext_s_traps !== 0) ||
                               (ext_value !== 32'ha5a5b6b6) || (ext_tval !== 32'h80011000) ||
                               (rerr_count !== 0) || (ext_denied_w !== 0) || (ext_slow_w !== 1)) begin
                               $display("FAIL: extension fast store-fault then Sv32 slow store"); $fatal; end
                        2: if ((ext_cause !== 32'd5) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'h12345678) || (rerr_count !== 1) ||
                               (ext_denied_w !== 0) || (ext_slow_w !== 0)) begin
                               $display("FAIL: extension PTE R-error load terminal/retry"); $fatal; end
                        3: if ((ext_cause !== 32'd7) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'ha5a5b6b6) || (rerr_count !== 1) ||
                               (ext_denied_w !== 0) || (ext_slow_w !== 1)) begin
                               $display("FAIL: extension PTE R-error store terminal/retry"); $fatal; end
                        4: if ((ext_cause !== 32'd5) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'h00000000) || (rerr_count !== 0) ||
                               (ext_denied_w !== 0) || (ext_slow_w !== 0)) begin
                               $display("FAIL: extension PTE PMP load access-fault"); $fatal; end
                        5: if ((ext_cause !== 32'd7) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'ha5a5b6b6) || (rerr_count !== 0) ||
                               (ext_denied_w !== 0) || (ext_slow_w !== 0)) begin
                               $display("FAIL: extension PTE PMP store access-fault"); $fatal; end
                        6: if ((ext_cause !== 32'd5) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'h00000000) || (ext_root_ar !== 1) ||
                               (ext_leaf_ar !== 0) || (ext_alias_ar !== 0) || (rerr_count !== 0)) begin
                               $display("FAIL: extension Sv32 34-bit level-0 PPN access-fault"); $fatal; end
                        7: if ((ext_cause !== 32'd5) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'h00000000) || (ext_root_ar !== 1) ||
                               (ext_leaf_ar !== 1) || (ext_alias_ar !== 0) || (rerr_count !== 0)) begin
                               $display("FAIL: extension Sv32 34-bit leaf PPN access-fault"); $fatal; end
                        8: if ((ext_cause !== 32'd13) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'h00000000) || (ext_root_ar !== 1) ||
                               (ext_leaf_ar !== 1) || (ext_slow_w !== 0) || (rerr_count !== 0)) begin
                               $display("FAIL: extension Sv32 invalid leaf load page-fault control"); $fatal; end
                        9: if ((ext_cause !== 32'd15) || (ext_traps !== 32'd1) ||
                               (ext_value !== 32'ha5a5b6b6) || (ext_root_ar !== 1) ||
                               (ext_leaf_ar !== 1) || (ext_slow_w !== 0) || (rerr_count !== 0)) begin
                               $display("FAIL: extension Sv32 invalid leaf store page-fault control"); $fatal; end
                        10: if ((ext_cause !== 32'd0) || (ext_traps !== 32'd0) ||
                                (ext_value !== 32'ha5a5b6b6) || (ext_rdelay_ars !== 2) ||
                                (ext_rdelay_nbeats !== 16) || (ext_branch_redirs !== 1) ||
                                (ext_itlb_reqs < 1) || (ext_leaf_ar !== 2) || (ext_dptw_accept_n !== 1) ||
                                 (ext_tagkill_n !== 1) || (ext_tagkill_state !== 7) ||
                                 (ext_data_rdelay_ar_t < 0) || (ext_data_rdelay_rsp_t <= ext_tagkill_t) ||
                                 (ext_tagkill_t <= ext_data_rdelay_ar_t) || (ext_slow_w !== 1) ||
                                (ext_branch_marker !== 32'h0000b101) ||
                                (ext_itlb_marker !== 32'h0000b202) ||
                                (ext_denied_w !== 0) || (rerr_count !== 1)) begin
                                $display("FAIL: extension branch-killed Sv32 miss drains and reuses safely"); $fatal; end
                        11: if ((ext_cause !== 32'd0) || (ext_traps !== 32'd0) ||
                                 (ext_value !== 32'h5a5a2222) || (rerr_count !== 0) ||
                                 (ext_slow_w !== 1) || (ext_bdelay_ws !== 1) ||
                                 (ext_bdelay_bs !== 1) || (ext_bdelay_wait < 8) ||
                                 (ext_pmp_after_n !== 1) || (ext_s6_exec !== 1) || (ext_pmp_after_t <= ext_bdelay_rsp)) begin
                                 $display("FAIL: extension old store B drain before unique PMP CSR+4 refetch target"); $fatal; end
                         14: if ((ext_cause !== 32'd7) || (ext_traps !== 32'd1) ||
                                 (ext_value !== 32'ha5a5b6b6) || (ext_root_ar !== 1) ||
                                 (ext_leaf_ar !== 1) || (ext_alias_ar !== 0) ||
                                 (ext_slow_w !== 0) || (ext_denied_w !== 0) || (rerr_count !== 0)) begin
                                 $display("FAIL: high-PA Sv32 store access-fault 7 without truncation"); $fatal; end
                         15: if ((ext_cause !== 32'd0) || (ext_traps !== 32'd0) ||
                                 (ext_value !== 32'ha5a5b6b6) || (ext_rdelay_ars !== 2) ||
                                 (ext_rdelay_nbeats !== 16) || (ext_branch_redirs !== 1) ||
                                 (ext_itlb_reqs !== 1) || (ext_root_ar !== 1) || (ext_leaf_ar !== 2) ||
                                 (ext_ptehit_n !== 2) || (ext_ptehit_first_cycle < 0) ||
                                  (ext_ptehit_first_cycle >= ext_tagkill_t) || (ext_ptehit_kill !== 0) ||
                                 (ext_tagkill_n !== 1) || (ext_tagkill_state !== 7) ||
                                 (ext_kill_tr_want !== 0) || (ext_kill_d_accept !== 0) ||
                                 (ext_kill_handshake !== 0) || (ext_slow_w !== 1) ||
                                 (ext_branch_marker !== 32'h0000b101) || (ext_itlb_marker !== 32'h0000b202) ||
                                 (ext_denied_w !== 0) || (rerr_count !== 1)) begin
                                 $display("FAIL: extension branch-kill after natural root-PTE L1D hit"); $fatal; end
                         16: if ((ext_cause !== 32'd0) || (ext_traps !== 32'd0) ||
                                 (ext_value !== 32'ha5a5b6b6) || (ext_branch_redirs !== 1) ||
                                 (ext_itlb_reqs !== 1) || (ext_root_ar !== 1) || (ext_leaf_ar !== 1) ||
                                 (ext_dptw_accept_n !== 1) || (ext_tagkill_n !== 1) ||
                                 (ext_tagkill_state !== 7) || (ext_kill_tr_want !== 0) ||
                                 (ext_kill_d_accept !== 0) || (ext_kill_handshake !== 0) ||
                                 (ext_arstall_wait !== 120) ||
                                 (ext_arstall_cancel !== 0) || (ext_arstall_accept_n !== 1) ||
                                 (ext_arstall_first_held_t < 0) || (ext_arstall_first_held_t >= ext_tagkill_t) ||
                                  (ext_tagkill_t >= ext_arstall_accept_t) || (ext_arstall_beats !== 8) ||
                                 (ext_slow_w !== 1) || (ext_branch_marker !== 32'h0000b101) ||
                                 (ext_itlb_marker !== 32'h0000b202) || (ext_denied_w !== 0) ||
                                 (rerr_count !== 0)) begin
                                 $display("FAIL: extension canceled initial data-PTW/AR stall drains before tag reuse"); $fatal; end
                         17: if ((ext_cause !== 32'd0) || (ext_traps !== 32'd0) ||
                                  (ext_m_traps !== 0) || (ext_s_traps !== 0) || (ext_tval !== 0) ||
                                  (ext_value !== 32'ha5a5b6b6) || (ext_branch_redirs !== 1) ||
                                  (ext_itlb_reqs !== 1) || (ext_rdelay_ars !== 1) ||
                                  (ext_rdelay_nbeats !== 8) || (ext_root_ar !== 1) || (ext_leaf_ar !== 1) ||
                                  (ext_dptw_accept_n !== 0) || (ext_tagkill_n !== 1) ||
                                  (ext_tagkill_state !== 5) || (a_tr_ready_want_count <= 0) ||
                                  (ext_kill_idle !== 1) || (ext_kill_ready !== 1) ||
                                  (ext_kill_owner !== 1) || (ext_kill_tr_want !== 1) ||
                                  (ext_kill_d_accept !== 0) || (ext_kill_handshake !== 0) ||
                                  (ext_slow_w !== 1) ||
                                  (ext_branch_marker !== 32'h0000b101) || (ext_itlb_marker !== 32'h0000b202) ||
                                  (ext_denied_w !== 0) || (rerr_count !== 0) ||
                                  (a_kill_seen !== 1'b1) || (a_stale_seen !== 1'b1) ||
                                  (a_stale_idle_seen !== 1'b1) || (a_stale_cycle_count < 1) ||
                                  (a_stale_cycle_count > 2) || (a_cancel_kill_samples < 1) ||
                                  (a_cancel_stale_samples < 1) || (a_cancel_idle_samples < 1) ||
                                  (a_cancel_lifetime_active !== 1'b0) ||
                                  (a_owner_reuse_seen !== 1'b1) || (a_tag_reuse_count < 1) ||
                                  (a_ghost_rsp_count !== 0) || (a_profile_s_window !== 1'b1) ||
                                  (a_m_trap_count !== 0) || (a_s_trap_count !== 0)) begin
                                  $display("FAIL: profile A strict TR admission/cancel lifetime checker"); $fatal; end
                         18: if ((ext_cause !== 32'd0) || (ext_traps !== 32'd0) ||
                                  (ext_m_traps !== 0) || (ext_s_traps !== 0) || (ext_tval !== 0) ||
                                  (ext_value !== 32'ha5a5b6b6) || (ext_branch_redirs !== 1) ||
                                  (ext_itlb_reqs !== 1) || (ext_rdelay_ars !== 1) ||
                                  (ext_rdelay_nbeats !== 8) || (ext_root_ar !== 1) || (ext_leaf_ar !== 1) ||
                                  (ext_tagkill_n !== 1) || (ext_tagkill_state !== 3) ||
                                  (b_initial_tag !== 2) || (b_cancelled_tag !== 2) ||
                                  (b_target_start_count !== 2) || (b_warm_tr_count < 1) ||
                                  (b_warm_accept_count < 1) || (b_target_tr_count !== 0) ||
                                  (b_tagkill_fetch_busy_count !== 1) || (b_cancel_kill_samples < 1) ||
                                  (b_cancel_stale_samples < 1) || (b_cancel_idle_samples < 1) ||
                                  (b_stale_busy_cycles < 1) ||
                                  (b_stale_busy_cycles > 64) || (b_stale_exit_fetch_busy < 1) ||
                                  (b_stale_idle_seen !== 1'b1) || (b_fetch_pte_service_count < 2) ||
                                  (b_owner_fetch_kill_count !== 0) || (ext_dptw_accept_n !== 0) ||
                                  (b_cancel_lifetime_active !== 1'b1) || (b_owner_reuse_seen !== 1'b0) ||
                                  (b_owner_reuse_count !== 0) || (b_cancel_lifetime_cycles < 1) ||
                                  (b_ghost_rsp_count !== 0) || (b_fetch_va !== 32'h80400080) ||
                                  (b_profile_s_window !== 1'b1) || (b_m_trap_count !== 0) ||
                                  (b_s_trap_count !== 0) || (b_post_req_index !== 2) ||
                                  (b_post_rsp_count !== 2) || (b_post_root_done !== 1) ||
                                  (b_post_leaf_done !== 1) || (b_post_walk_done_count !== 1) ||
                                  (b_post_sequence_error !== 0) || (b_post_pending !== 1'b0) ||
                                  (b_post_complete !== 1'b1) ||
                                  (ext_branch_marker !== 32'h0000b101) || (ext_itlb_marker !== 32'h0000b202) ||
                                  (ext_denied_w !== 0) || (rerr_count !== 0)) begin
                                  $display("FAIL: profile B DATA stale drain under active IF owner"); $fatal; end
                         12, 13: if ((ext_cause !== 32'd5) || (ext_traps !== 32'd1) ||
                                     (ext_value !== 32'h12345678) || (rerr_count !== 1) ||
                                     (ext_root_ar !== 1) || (ext_leaf_ar !== 1) ||
                                     (ext_cached_data_ars !== 2) || (ext_cached_data_nbeats !== 16) ||
                                     (ext_slow_w !== 0) || (ext_denied_w !== 0)) begin
                                     $display("FAIL: extension cached DATA RRESP beat-0/7 AF5 retry"); $fatal; end
                        default: begin $display("FAIL: unknown extension id=%0d", ext_id); $fatal; end
                    endcase
                    $display("DATA_BUS_EXTENSION id=%0d PASS", ext_id);
                    $finish;
                end
            end
            $display("FAIL: extension timeout id=%0d rerr=%0d cause=%08x traps=%08x",
                     ext_id, rerr_count, ddr[32'h1104 >> 2], ddr[32'h1108 >> 2]);
            $fatal;
        end
    end

endmodule
