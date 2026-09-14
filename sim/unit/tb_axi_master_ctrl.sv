//==============================================================================
// sim/unit/tb_axi_master_ctrl.sv —— AXI4 主端口控制器单元测试
//   覆盖：单笔在途、valid&&ready 握手、4 K 边界拆两笔、bresp/rresp 处理
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §7.1/§7.2；AGENT.md §3.3（三件套）
// 顶层  : tb_axi_master_ctrl_top（验收命令 -s tb_axi_master_ctrl_top）
//
// 判定纪律（fail-closed，08 §8.1）：起始 fail；只有走完全部检查才 PASS；
//   兜底/超时输出不含 PASS；退出码由显式计数器决定。
//
// 覆盖（对应任务验收判据③ tb_axi 部分）：
//   C1 单笔在途：busy=1 期间 req_ready=0（新请求被反压）
//   C2 读交易：AR 握手 → 8 拍 R → 完成脉冲，owner/地址正确
//   C3 写交易：AW + 8 拍 W + B → 完成脉冲
//   C4 握手纪律：m_arvalid 必须等到 m_arready 才撤销（valid&&ready 推进）
//   C5 4 K 边界拆两笔：首笔在边界处截断，自动发第二笔，两笔地址接续
//   C6 bresp/rresp 非 OKAY ⇒ resp_error 可见（不静默吞掉）
//   C7 端口常量：SIZE=3'b010、LOCK 高位=0、ID 4 bit、LEN ≤ 15
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_axi_master_ctrl_top;

    //--------------------------------------------------------------------------
    // 检查计数（fail-closed）
    //--------------------------------------------------------------------------
    integer checks_run;
    integer checks_failed;
    integer checks_passed;

    task automatic chk(input logic cond, input string name);
        begin
            checks_run = checks_run + 1;
            if (cond) checks_passed = checks_passed + 1;
            else begin
                checks_failed = checks_failed + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 时钟/复位
    //--------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // DUT 信号
    //--------------------------------------------------------------------------
    logic        req_valid, req_is_write;
    logic [1:0]  req_owner;
    logic [31:0] req_addr;
    logic [3:0]  req_len;
    logic [4:0]  req_beats;
    logic        req_split;
    logic [4:0]  req_beats_1;
    logic [4:0]  req_beats_2;
    logic [3:0]  req_id;
    logic        req_ready;

    logic        wdata_valid;
    logic [31:0] wdata_data;
    logic        wdata_ready;

    logic        rdata_valid;
    logic [31:0] rdata_data;
    logic [3:0]  rdata_id;
    logic        rdata_last;
    logic        rdata_ready;

    logic        done;
    logic [1:0]  done_owner;
    logic [31:0] done_addr;
    logic        resp_error;
    logic [1:0]  resp_code;

    logic [3:0]  m_awid;
    logic [31:0] m_awaddr;
    logic [3:0]  m_awlen;
    logic [2:0]  m_awsize;
    logic [1:0]  m_awburst;
    logic [2:0]  m_awlock;
    logic [3:0]  m_awcache;
    logic [2:0]  m_awprot;
    logic        m_awvalid;
    logic        m_awready;

    logic [31:0] m_wdata;
    logic [3:0]  m_wstrb;
    logic        m_wlast;
    logic        m_wvalid;
    logic        m_wready;

    logic [3:0]  m_bid;
    logic [1:0]  m_bresp;
    logic        m_bvalid;
    logic        m_bready;

    logic [3:0]  m_arid;
    logic [31:0] m_araddr;
    logic [3:0]  m_arlen;
    logic [2:0]  m_arsize;
    logic [1:0]  m_arburst;
    logic [2:0]  m_arlock;
    logic [3:0]  m_arcache;
    logic [2:0]  m_arprot;
    logic        m_arvalid;
    logic        m_arready;

    logic [3:0]  m_rid;
    logic [31:0] m_rdata;
    logic [1:0]  m_rresp;
    logic        m_rlast;
    logic        m_rvalid;
    logic        m_rready;

    logic        busy;
    logic [1:0]  owner;

    axi_master_ctrl dut (
        .clk (clk), .rst_n (rst_n),
        .req_valid (req_valid), .req_is_write (req_is_write), .req_owner (req_owner),
        .req_addr (req_addr), .req_len (req_len), .req_beats (req_beats),
        .req_split (req_split), .req_beats_1 (req_beats_1), .req_beats_2 (req_beats_2),
        .req_id (req_id), .req_ready (req_ready),
        .wdata_valid (wdata_valid), .wdata_data (wdata_data), .wdata_ready (wdata_ready),
        .rdata_valid (rdata_valid), .rdata_data (rdata_data), .rdata_id (rdata_id),
        .rdata_last (rdata_last), .rdata_ready (rdata_ready),
        .done (done), .done_owner (done_owner), .done_addr (done_addr),
        .resp_error (resp_error), .resp_code (resp_code),
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
        .busy (busy), .owner (owner)
    );

    //--------------------------------------------------------------------------
    // 从设备行为模型（简化的 AXI 从端，供 TB 驱动 R/W 数据流）
    //   设计：用"延迟计数器"控制各通道 ready 的出现时机；R 通道在 AR 握手后
    //   逐拍吐出 arlen+1 个 beat；B 通道在 W 最后一拍后给响应。
    //   全部用 always 块（时序元件），其余判定在 TB 主进程里做。
    //--------------------------------------------------------------------------
    integer ar_ready_delay;   // AR ready 延迟拍数
    integer aw_ready_delay;
    integer w_ready_delay;
    integer b_delay;
    integer r_delay;
    logic [1:0] b_resp_set;
    logic [1:0] r_resp_set;

    integer ar_seen, aw_seen;
    logic [31:0] ar_addr_seen [0:7];
    logic [31:0] aw_addr_seen [0:7];
    logic [3:0]  ar_len_seen  [0:7];
    logic [3:0]  aw_len_seen  [0:7];

    integer ar_cnt, aw_cnt, w_cnt;

    // ---- AR ready ----
    always @(posedge clk) begin
        if (!rst_n) begin ar_cnt <= 0; m_arready <= 1'b0; end
        else if (!m_arvalid) begin ar_cnt <= 0; m_arready <= 1'b0; end
        else if (m_arvalid && !m_arready) begin
            if (ar_cnt >= ar_ready_delay) m_arready <= 1'b1;
            else                           ar_cnt <= ar_cnt + 1;
        end else if (m_arvalid && m_arready) begin
            m_arready <= 1'b0; ar_cnt <= 0;
        end
    end

    // ---- AW ready ----
    always @(posedge clk) begin
        if (!rst_n) begin aw_cnt <= 0; m_awready <= 1'b0; end
        else if (!m_awvalid) begin aw_cnt <= 0; m_awready <= 1'b0; end
        else if (m_awvalid && !m_awready) begin
            if (aw_cnt >= aw_ready_delay) m_awready <= 1'b1;
            else                          aw_cnt <= aw_cnt + 1;
        end else if (m_awvalid && m_awready) begin
            m_awready <= 1'b0; aw_cnt <= 0;
        end
    end

    // ---- W ready ----
    always @(posedge clk) begin
        if (!rst_n) begin w_cnt <= 0; m_wready <= 1'b0; end
        else if (!m_wvalid) begin w_cnt <= 0; m_wready <= 1'b0; end
        else if (m_wvalid && !m_wready) begin
            if (w_cnt >= w_ready_delay) m_wready <= 1'b1;
            else                        w_cnt <= w_cnt + 1;
        end else if (m_wvalid && m_wready) begin
            m_wready <= 1'b0; w_cnt <= 0;
        end
    end

    // ---- 记录 AR / AW 握手 ----
    always @(posedge clk) begin
        if (rst_n && m_arvalid && m_arready && ar_seen < 8) begin
            ar_addr_seen[ar_seen] <= m_araddr;
            ar_len_seen [ar_seen] <= m_arlen;
            ar_seen <= ar_seen + 1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && m_awvalid && m_awready && aw_seen < 8) begin
            aw_addr_seen[aw_seen] <= m_awaddr;
            aw_len_seen [aw_seen] <= m_awlen;
            aw_seen <= aw_seen + 1;
        end
    end

    // ---- R 通道：AR 握手后，先等 r_delay 拍，然后逐 beat 吐 ----
    integer      r_pending_q;    // 剩余 beat 数
    integer      r_gap_q;        // 起始间隔计数
    logic [31:0] r_base_q;
    logic [3:0]  r_len_q;
    logic        r_busy_q;       // 正在吐 beat

    always @(posedge clk) begin
        if (!rst_n) begin
            m_rvalid <= 1'b0; m_rdata <= 32'h0; m_rresp <= 2'b00;
            m_rlast <= 1'b0;  m_rid <= 4'h0;
            r_pending_q <= 0; r_gap_q <= 0; r_busy_q <= 1'b0;
            r_base_q <= 32'h0; r_len_q <= 4'h0;
        end else begin
            if (m_arvalid && m_arready) begin
                // 收到读地址：登记本笔要吐的 beat 数
                r_pending_q <= {1'b0, m_arlen} + 1;
                r_gap_q     <= r_delay;
                r_base_q    <= m_araddr;
                r_len_q     <= m_arlen;
                r_busy_q    <= 1'b1;
                m_rvalid    <= 1'b0;
                m_rresp     <= r_resp_set;   // 本笔响应码：整笔保持
            end else if (r_busy_q) begin
                if (r_gap_q > 0) begin
                    r_gap_q  <= r_gap_q - 1;
                    m_rvalid <= 1'b0;
                end else if (!m_rvalid) begin
                    // 起一拍（rresp 已在本笔 arm 时登记，整笔保持）
                    m_rvalid <= 1'b1;
                    m_rdata  <= r_base_q;
                    m_rid    <= dut.id_q;
                    m_rlast  <= (r_pending_q == 1);
                end else if (m_rvalid && m_rready) begin
                    // 本拍被收下
                    if (r_pending_q <= 1) begin
                        m_rvalid    <= 1'b0;
                        r_busy_q    <= 1'b0;
                        r_pending_q <= 0;
                    end else begin
                        r_pending_q <= r_pending_q - 1;
                        r_base_q    <= r_base_q + 32'd4;
                        m_rdata     <= r_base_q + 32'd4;
                        m_rlast     <= (r_pending_q == 2);
                    end
                end
            end else begin
                m_rvalid <= 1'b0;
            end
        end
    end

    // ---- B 通道：W 最后一拍被收下后，延迟 b_delay 拍给响应 ----
    logic       w_last_q;
    integer     b_cnt_q;
    logic       b_armed_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_bvalid <= 1'b0; m_bid <= 4'h0; m_bresp <= 2'b00;
            w_last_q <= 1'b0; b_cnt_q <= 0; b_armed_q <= 1'b0;
        end else begin
            if (m_wvalid && m_wready && m_wlast) b_armed_q <= 1'b1;
            if (b_armed_q) begin
                if (b_cnt_q < b_delay) b_cnt_q <= b_cnt_q + 1;
                else if (!m_bvalid)    m_bvalid <= 1'b1;
            end
            if (m_bvalid && m_bready) begin
                m_bvalid  <= 1'b0;
                b_armed_q <= 1'b0;
                b_cnt_q   <= 0;
            end
            m_bresp <= b_resp_set;
            m_bid   <= dut.id_q;
        end
    end

    //--------------------------------------------------------------------------
    // 辅助任务
    //--------------------------------------------------------------------------
    task automatic do_reset;
        begin
            rst_n = 1'b0;
            req_valid = 1'b0; req_is_write = 1'b0; req_owner = 2'd0;
            req_addr = 32'h0; req_len = 4'h0; req_beats = 5'd1;
            req_split = 1'b0; req_id = 4'h0; req_beats_1 = 5'd1; req_beats_2 = 5'd0;
            wdata_valid = 1'b0; wdata_data = 32'h0;
            m_arready = 1'b0; m_awready = 1'b0; m_wready = 1'b0;
            m_bvalid = 1'b0; m_bresp = 2'b00; m_bid = 4'h0;
            m_rvalid = 1'b0; m_rdata = 32'h0; m_rresp = 2'b00;
            m_rlast = 1'b0; m_rid = 4'h0;
            ar_ready_delay = 0; aw_ready_delay = 0; w_ready_delay = 0;
            b_delay = 1; r_delay = 1;
            b_resp_set = 2'b00; r_resp_set = 2'b00;
            ar_seen = 0; aw_seen = 0;
            ar_cnt = 0; aw_cnt = 0; w_cnt = 0;
            r_pending_q = 0; r_gap_q = 0; r_busy_q = 1'b0; r_base_q = 32'h0; r_len_q = 4'h0;
            w_last_q = 1'b0; b_cnt_q = 0; b_armed_q = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // 发起一次请求（读或写），持有到被接受
    task automatic issue_req(input logic wr, input logic [31:0] addr,
                             input logic [4:0] beats, input logic split,
                             input logic [1:0] own);
        begin
            req_is_write = wr;
            req_addr     = addr;
            req_beats    = beats;
            req_len      = beats[3:0] - 4'd1;
            req_split    = split;
            // 非拆分请求：首笔即全部；拆分请求由调用点显式给 req_beats_1/2
            req_beats_1  = beats;
            req_beats_2  = 5'd0;
            req_owner    = own;
            // ★ 时序纪律：req_valid 必须在**整拍**保持到 DUT 在 posedge 采样到
            //   valid && ready。先拉高，再等一个 posedge 让 DUT 采样。
            req_valid = 1'b1;
            @(posedge clk);           // DUT 在此沿采样 req_valid && req_ready
            // 若本拍未被接受（req_ready=0），继续维持 valid 直到接受
            while (req_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;         // 接受后撤销
            @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    integer k;
    integer done_count_pulse;
    logic [31:0] captured_addr;
    logic [1:0]  captured_owner;

    // 监测 done 脉冲
    always @(posedge clk) begin
        if (rst_n && done) begin
            done_count_pulse = done_count_pulse + 1;
            captured_addr    = done_addr;
            captured_owner   = done_owner;
        end
    end

    initial begin
        checks_run = 0; checks_failed = 0; checks_passed = 0;
        done_count_pulse = 0;
        captured_addr = 32'h0; captured_owner = 2'h0;

        $display("---- tb_axi_master_ctrl: AXI4 五通道控制器单元测试 ----");

        do_reset();

        //======================================================================
        // C7：端口常量（08 §7.2）
        //======================================================================
        begin
            // 用一次读交易观察 AR 通道字段常量
            issue_req(1'b0, 32'h0000_1000, 5'd8, 1'b0, 2'd0);
            // 等 AR 出现
            k = 0;
            while (m_arvalid !== 1'b1 && k < 50) begin @(negedge clk); k = k + 1; end
            chk(m_arsize  === 3'b010,      "C7 AxSIZE 应为 3'b010（4 B）");
            chk(m_arlock  === 3'b000,      "C7 AxLOCK 高位应为 0（平台只接 [0:0]）");
            chk(m_arburst === 2'b01,       "C7 AxBURST 应为 INCR");
            chk(m_arcache === 4'b1111,     "C7 可缓存填充 AxCACHE 应为 1111");
            chk(m_arprot  === 3'b010,      "C7 AxPROT 应为 3'b010");
            chk(m_arid    === 4'd0,        "C7 AxID 2A 应为 4'd0");
            chk(m_arlen   === 4'd7,        "C7 8 beat ⇒ AxLEN=7");
            // 完成这次读
            k = 0;
            while (done_count_pulse == 0 && k < 200) begin @(posedge clk); k = k + 1; end
            chk(done_count_pulse >= 1, "C2 读交易应产生 done 脉冲");
            chk(ar_seen == 1, "C2 读交易应有 1 次 AR 握手");
            chk(ar_addr_seen[0] === 32'h0000_1000, "C2 AR 地址应正确");
            chk(ar_len_seen[0] === 4'd7, "C2 AR LEN 应正确");
            repeat (4) @(posedge clk);
        end

        //======================================================================
        // C1：单笔在途（busy 期间 req_ready=0）
        //======================================================================
        begin
            integer bus_seen;
            // 读交易，在途期间观察 req_ready
            ar_ready_delay = 3;   // 拉长在途窗口
            req_is_write = 1'b0; req_addr = 32'h0000_2000; req_beats = 5'd8;
            req_len = 4'd7; req_split = 1'b0; req_owner = 2'd1;
            req_valid = 1'b1;
            @(posedge clk);
            while (req_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            @(posedge clk);
            bus_seen = 0;
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge clk);
                if (busy === 1'b1) begin
                    bus_seen = bus_seen + 1;
                    chk(req_ready === 1'b0, "C1 busy 期间 req_ready 应为 0（单笔在途）");
                end
            end
            chk(bus_seen > 0, "C1 应观察到 busy=1 的单笔在途窗口");
            k = 0;
            while (done_count_pulse < 2 && k < 300) begin @(posedge clk); k = k + 1; end
            ar_ready_delay = 0;
            repeat (4) @(posedge clk);
        end

        //======================================================================
        // C3：写交易（AW + W + B）
        //======================================================================
        begin
            integer base;
            base = done_count_pulse;
            issue_req(1'b1, 32'h0000_3000, 5'd8, 1'b0, 2'd2);
            // 驱动 8 拍写数据（valid && ready 握手）
            for (k = 0; k < 8; k = k + 1) begin
                @(negedge clk);
                wdata_valid = 1'b1;
                wdata_data  = 32'hD000_0000 + k[31:0];
                // 等待 wready
                while (wdata_ready !== 1'b1) @(negedge clk);
                @(posedge clk);
            end
            @(negedge clk); wdata_valid = 1'b0;
            k = 0;
            while (done_count_pulse == base && k < 300) begin @(posedge clk); k = k + 1; end
            chk(done_count_pulse > base, "C3 写交易应产生 done 脉冲");
            chk(aw_seen == 1, "C3 写交易应有 1 次 AW 握手");
            chk(aw_addr_seen[0] === 32'h0000_3000, "C3 AW 地址应正确");
            chk(aw_len_seen[0] === 4'd7, "C3 AW LEN 应正确");
            chk(captured_owner === 2'd2, "C3 done_owner 应为发起时的 owner=2");
            repeat (4) @(posedge clk);
        end

        //======================================================================
        // C4：握手纪律 —— valid 保持到 ready（valid&&ready 推进）
        //======================================================================
        begin
            integer holes;
            integer base;
            base  = done_count_pulse;
            holes = 0;
            // 读交易，从设备 AR ready 延迟 5 拍
            ar_ready_delay = 5;
            req_is_write = 1'b0; req_addr = 32'h0000_4000; req_beats = 5'd4;
            req_len = 4'd3; req_split = 1'b0; req_owner = 2'd0;
            req_valid = 1'b1;
            // ★ 与 issue_req 同一时序纪律：先让 DUT 采样到 valid && ready
            @(posedge clk);
            while (req_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            // 观察：在 ready 尚未拉高前，valid 必须保持 1（不得撤销）
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge clk);
                if (m_arvalid === 1'b1 && m_arready === 1'b0) begin
                    holes = holes + 1;
                end
            end
            chk(holes > 0, "C4 应观察到 valid=1/ready=0 的等待窗口");
            // 一旦握手成功，valid 必须撤销
            k = 0;
            while (!(m_arvalid === 1'b1 && m_arready === 1'b1) && k < 100) begin
                @(posedge clk); k = k + 1;
            end
            @(posedge clk); #1;
            chk(m_arvalid === 1'b0, "C4 AR 握手完成后 valid 应撤销");
            ar_ready_delay = 0;
            k = 0;
            while (done_count_pulse == base && k < 300) begin @(posedge clk); k = k + 1; end
            repeat (4) @(posedge clk);
        end

        //======================================================================
        // C5：4 K 边界拆两笔
        //     起始 0x0000_3FF8（4 K 前 8 字节）请求 8 beat(32 B) ⇒
        //     首笔只能 2 beat 到边界，第二笔补齐剩余 6 beat，地址接续。
        //======================================================================
        begin
            integer base;
            integer ar_before;
            base      = done_count_pulse;
            ar_before = ar_seen;
            req_is_write = 1'b0;
            req_addr  = 32'h0000_3FF8;
            req_beats = 5'd8;
            req_len   = 4'd7;
            req_split = 1'b1;              // 声明需拆
            // 4 K 拆分口径（与 axi_req_desc 一致）：
            //   起始 0x3FF8 ⇒ 到边界 0x4000 还剩 8 B = 2 beat
            //   剩余 = 8 - 2 = 6 beat
            req_beats_1 = 5'd2;
            req_beats_2 = 5'd6;
            req_owner = 2'd0;
            req_valid = 1'b1;
            @(posedge clk);
            while (req_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            @(posedge clk);
            // 等两笔都完成：done 只在**整个请求（含第二笔）完成后**给出，
            // 因此以 done 脉冲为界即可；再加一次 AR 计数收尾等待。
            k = 0;
            while (done_count_pulse == base && k < 800) begin @(posedge clk); k = k + 1; end
            // 第二笔的 AR 握手可能在同一拍稍后记账，补等两拍
            repeat (4) @(posedge clk);
            chk(ar_seen >= ar_before + 2, "C5 跨 4 K 应拆成 2 笔（2 次 AR 握手）");
            chk(ar_addr_seen[ar_before]   === 32'h0000_3FF8,
                "C5 首笔地址应为请求起始地址");
            chk(ar_len_seen[ar_before]    === 4'd1,
                "C5 首笔应被截断到 2 beat（AxLEN=1，不越 4 K）");
            chk(ar_addr_seen[ar_before+1] === 32'h0000_4000,
                "C5 第二笔地址应接续到 4 K 边界");
            chk(ar_len_seen[ar_before+1]  === 4'd5,
                "C5 第二笔应为剩余 6 beat（AxLEN=5）");
            repeat (4) @(posedge clk);
        end

        //======================================================================
        // C6：bresp/rresp 非 OKAY ⇒ resp_error 可见
        //======================================================================
        begin
            integer base;
            integer err_seen;
            base = done_count_pulse;
            // 读交易并让 rresp = SLVERR
            // ★ 从设备在 AR 握手那一拍就登记 rresp，因此必须**先**配置响应码。
            r_resp_set = 2'b10;
            err_seen = 0;
            repeat (2) @(posedge clk);
            req_is_write = 1'b0; req_addr = 32'h0000_5000; req_beats = 5'd4;
            req_len = 4'd3; req_split = 1'b0; req_owner = 2'd0;
            req_valid = 1'b1;
            @(posedge clk);
            while (req_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            @(posedge clk);
            // 观察 resp_error：这里的响应码在 AR 握手那拍就登记了，因此
            // 本笔的 resp_error 可能**早于**本循环开始。改用一个明确的观察窗口：
            // 等到本笔 done 之后再确认"窗口内某拍曾出现 resp_error"。
            // 为实现这一点，用 err_pending 的"曾经置位"语义：监测 resp_error
            // 的任意时刻置位（由上面的 done 监视同一进程更新 err_seen）。
            // 观察窗口：从发起后固定观察 60 拍，覆盖 AR→R→done 全程
            for (k = 0; k < 60; k = k + 1) begin
                @(posedge clk);
                if (resp_error === 1'b1) err_seen = err_seen + 1;
            end
            chk(err_seen > 0, "C6 rresp≠OKAY 应产生 resp_error（不静默吞掉）");
            r_resp_set = 2'b00;
            repeat (4) @(posedge clk);

            // 写交易并让 bresp = DECERR
            base = done_count_pulse;
            b_resp_set = 2'b11;   // 在发起前配置（从设备在 W 结束时采样）
            err_seen = 0;
            repeat (2) @(posedge clk);
            issue_req(1'b1, 32'h0000_6000, 5'd4, 1'b0, 2'd2);
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge clk);
                wdata_valid = 1'b1;
                wdata_data  = 32'hE000_0000 + k[31:0];
                while (wdata_ready !== 1'b1) @(negedge clk);
                @(posedge clk);
            end
            @(negedge clk); wdata_valid = 1'b0;
            // 观察窗口：固定 80 拍覆盖 AW→W→B→done
            for (k = 0; k < 80; k = k + 1) begin
                @(posedge clk);
                if (resp_error === 1'b1) err_seen = err_seen + 1;
            end
            chk(err_seen > 0, "C6 bresp≠OKAY 应产生 resp_error");
            b_resp_set = 2'b00;
            repeat (4) @(posedge clk);
        end

        //======================================================================
        // 判定（fail-closed）：唯一 PASS 字样
        //======================================================================
        $display("---- tb_axi_master_ctrl 检查统计: run=%0d passed=%0d failed=%0d ----",
                 checks_run, checks_passed, checks_failed);

        if (checks_run == 0) begin
            $display("TB_AXI_MASTER_CTRL_UNIT: FAIL (no checks executed)");
            $fatal(1, "fail-closed: 未执行任何检查");
        end
        if (checks_failed != 0) begin
            $display("TB_AXI_MASTER_CTRL_UNIT: FAIL (%0d/%0d checks failed)",
                     checks_failed, checks_run);
            $fatal(1, "fail-closed: 存在失败检查");
        end
        if (checks_passed != checks_run) begin
            $display("TB_AXI_MASTER_CTRL_UNIT: FAIL (passed != run)");
            $fatal(1, "fail-closed: 计数不一致");
        end

        $display("TB_AXI_MASTER_CTRL_UNIT: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 全局超时兜底
    //--------------------------------------------------------------------------
    initial begin
        #600000;
        $display("TB_AXI_MASTER_CTRL_UNIT: FAIL (timeout)");
        $fatal(1, "fail-closed: 仿真超时");
    end

endmodule
