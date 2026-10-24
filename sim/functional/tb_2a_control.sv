//==============================================================================
// tb_2a_control.sv —— 2A 顶层控制/计数程序序定向验收 TB（只读 DUT，不 force）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A = 单发射顺序 5 级核）
// 归属  : 08-05（taken 控制转移退休拍中断 EPC）+ C15/B（计数器读的程序序投影）
//         的**正确行为**回归；由 sim/functional/test_2a_control.sh 驱动。
//------------------------------------------------------------------------------
// 一、被测口径（规范锚点）
//  · trap_ctrl：中断 mepc = **本条（W 槽）执行后的下一条 PC**（trap_ctrl.v E4/T6）。
//    ⇒ taken 控制转移（jal/jalr/c.j/taken branch）必须写**目标**，不是 fall-through；
//      mret/sret 必须写 *epc（返回目标），不是 mret+4；not-taken 写 link。
//  · zicsr.adoc:166-184：显式 CSR 读返回**本条执行前**的值；一条写的值就是后条读的值
//    （minstret 的显式写替代本条隐式 +1）；norm:csraccessorder 更老写的效果后条可见。
//  · machine.adoc:1523-1561：mcycle 计**时钟周期**；RV32 半字写只改选中半（低半写不得
//    改高半，但同沿 tick 的自然进位必须体现到随后读到的高半）。
//------------------------------------------------------------------------------
// 二、结构（全部合法软件 + 外部 AXI 从设备 + 外部 intrpt 引脚；无任何 force）
//  · XIP 0x1C00_0000 只放 3 条跳板（lui/jalr/nop），程序体链在 DDR 0x0001_0000 运行
//    ⇒ L1I 缓存后相邻指令可 1 拍/条（计数器 E/W 交叠窗口可达）。
//  · 数据结果写 DDR 低地址（2A 的 ROUTE_AXI 数据通路不经 L1D）⇒ TB 直接读从设备数组。
//  · 外部中断：TB 在**指定指令处于 E 级**的那一拍把 intrpt[1] 拉高（→ PLIC 源 1 →
//    MEIP，经 PLIC 网关锁存），陷阱恰在该指令的 W 退休拍取得；不预置核内 pending。
//  · 判定：DUT 提交后的 DDR 结果字（程序自检布尔 + 实测值）+ TB 侧 trap 事件观测
//    + 场景命中计数（窗口未命中即 SCENARIO MISS ⇒ 失败）。
//------------------------------------------------------------------------------
// 三、case（--SCEN=...；由脚本按固定表调用）
//   irq_ctl  ：taken 控制转移（KIND=jal|jalr|cj|beq|bne）；EXP_EPC=目标；
//   irq_ctl_nt：not-taken 分支；EXP_EPC=CTRL_PC+4（控制例）；
//   irq_mret ：mret 退休拍中断；EXP_EPC=返回目标（MRET_PC 为 mret 地址）；
//   cnt_order：instret 相邻两读/写后读/半字 carry/load 停顿交错/mcycle 双写者 carry；
//   fp_flags ：fflags 年龄/退休顺序（显式写 vs 年轻 FP；被杀指令不得留 flag）。
//  plusargs：SCEN, DDRPROG, CTRL_PC, MRET_PC, EXP_EPC, KIND, IRQ, DATA_ADDR/VAL。
//==============================================================================
`timescale 1ns/1ps
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_2a_control;

    //--------------------------------------------------------------------------
    // 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg aresetn = 1'b0;

    // ---- 运行基址：程序直接链接/装载在 DDR 0x0001_0000（XIP 只放 3 条跳板）----
    localparam [31:0] RUN_BASE  = 32'h0001_0000;
    localparam [31:0] XIP_BASE  = `RV32GC_XIP_BASE;

    //--------------------------------------------------------------------------
    // plusargs
    //--------------------------------------------------------------------------
    reg [8*512-1:0] scen, kind, ddr_path;
    reg [31:0]      ctrl_pc, mret_pc, exp_epc;
    integer         irq_en;
    reg [31:0]      data_addr;
    integer         data_val;
    integer         rdelay;
    integer         dbg;
    integer         cancel_chk;
    reg [31:0]      load_pc, branch_pc, exp_marker, exp_bad_marker;
    integer         arm_hi_chk;
    reg [31:0]      dly_lo, dly_hi;
    reg [31:0]      err_lo, err_hi;
    integer         err_kind;
    reg [31:0]      exp_tval;

    //--------------------------------------------------------------------------
    // DUT 端口
    //--------------------------------------------------------------------------
    wire [3:0]  arid;   wire [31:0] araddr; wire [3:0] arlen; wire [2:0] arsize;
    wire [1:0]  arburst, arlock; wire [3:0] arcache; wire [2:0] arprot;
    wire        arvalid, arready;
    wire [3:0]  rid;    wire [31:0] rdata;  wire [1:0] rresp; wire rlast, rvalid, rready;
    wire [3:0]  awid;   wire [31:0] awaddr; wire [3:0] awlen; wire [2:0] awsize;
    wire [1:0]  awburst, awlock; wire [3:0] awcache; wire [2:0] awprot;
    wire        awvalid, awready;
    wire [3:0]  wid;    wire [31:0] wdata;  wire [3:0] wstrb; wire wlast, wvalid, wready;
    wire [3:0]  bid;    wire [1:0] bresp;   wire bvalid, bready;
    wire        ws_valid;
    wire [31:0] rf_rdata, debug0_wb_pc, debug0_wb_rf_wdata;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;

    // ---- 外部中断：仅在“被观测指令处于 E”那一拍拉高（组合，不 force）----
    wire arm_by_pc = (ctrl_pc != 32'h0) && u_dut.de_valid && (u_dut.de_pc == ctrl_pc);
    wire arm_mret  = (mret_pc != 32'h0) && u_dut.de_valid && (u_dut.de_pc == mret_pc);
    wire irq_arm_pc  = (irq_en != 0) && (arm_by_pc | arm_mret);
    wire irq_arm_hi  = (arm_hi_chk != 0) && u_dut.u_fetch_unit.hi32_q;
    wire irq_arm     = aresetn && (irq_arm_pc | irq_arm_hi);
    wire [7:0] intrpt = irq_arm ? 8'h02 : 8'h00;   // 引脚 1 → PLIC 源 1 → MEIP

    core_top u_dut (
        .aclk(clk), .intrpt(intrpt), .aresetn(aresetn),
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
        .ws_valid(ws_valid), .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0),
        .rf_rdata(rf_rdata), .debug0_wb_pc(debug0_wb_pc),
        .debug0_wb_rf_wen(debug0_wb_rf_wen), .debug0_wb_rf_wnum(debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata(debug0_wb_rf_wdata)
    );

    //==========================================================================
    // 1. AXI4 从设备：XIP（1 MiB 只读窗口）+ DDR 低 1 MiB（可读写）+ 可配读延迟
    //==========================================================================
    localparam integer DDRW = 1 << 18;          // 262144 words = 1 MiB
    reg [31:0] xip_mem [0:1023];
    reg [31:0] ddr_mem [0:DDRW-1];

    integer load_err;
    integer done_seen;
    integer uart_n;                              // 未用（保留诊断 0）

    function [31:0] mem_word;
        input [31:0] a;
        begin
            if (a >= XIP_BASE && a < XIP_BASE + 32'h10_0000)
                mem_word = xip_mem[(a - XIP_BASE) >> 2];
            else if (a < 32'h0010_0000)
                mem_word = ddr_mem[a >> 2];
            else
                mem_word = 32'h0000_0000;
        end
    endfunction

    // ---- AR / R ----
    reg        rd_busy;
    reg [31:0] rd_addr;
    reg [3:0]  rd_len, rd_cnt;
    reg [31:0] rd_wait;
    reg  [1:0] rd_err;
    wire       in_dly_win = (rd_addr >= dly_lo) && (rd_addr < dly_hi);
    wire       in_err_win = (rd_addr >= err_lo) && (rd_addr < err_hi);
    assign arready = ~rd_busy;
    assign rvalid  = rd_busy && (rd_wait == 32'd0);
    assign rlast   = rd_busy && (rd_cnt == rd_len);
    assign rid     = 4'd0;
    //   错误注入：AR 地址落在 [ERR_LO,ERR_HI) ⇒ 该事务所有 R beat 回 ERR_KIND
    //   （2=SLVERR、3=DECERR）。逐 beat 回错 + 正确 RLAST/长度，保证 AXI 主控
    //   能按事务协议收尾（不靠"少 beat"制造悬挂）。
    assign rresp   = rd_err;
    assign rdata   = mem_word(rd_addr);

    always @(posedge clk) begin
        if (!aresetn) begin
            rd_busy <= 1'b0; rd_addr <= 32'h0; rd_len <= 4'd0; rd_cnt <= 4'd0;
            rd_wait <= 32'd0; rd_err <= 2'b00;
        end else begin
            if (arvalid && arready) begin
                if (dbg != 0) $display("DBG_AR cyc=%0d addr=0x%08h len=%0d size=%0d cache=%b",
                                       cyc, araddr, arlen, arsize, arcache);
                rd_busy <= 1'b1;
                rd_addr <= {araddr[31:2], 2'b00};
                rd_len  <= arlen;
                rd_cnt  <= 4'd0;
                rd_wait <= ((araddr >= dly_lo) && (araddr < dly_hi) &&
                            (rdelay > 0)) ? rdelay : 32'd0;
                rd_err  <= ((araddr >= err_lo) && (araddr < err_hi) &&
                            (err_kind != 0)) ? err_kind[1:0] : 2'b00;
            end else if (rd_busy && rvalid && rready) begin
                if (rd_cnt == rd_len) begin
                    rd_busy <= 1'b0;
                end else begin
                    rd_cnt  <= rd_cnt + 4'd1;
                    rd_addr <= rd_addr + 32'd4;
                end
            end else if (rd_busy && (rd_wait != 32'd0)) begin
                rd_wait <= rd_wait - 32'd1;
            end
        end
    end

    // ---- AW / W / B ----
    reg        wr_pend, bvalid_r;
    reg [31:0] aw_addr;
    assign awready = ~wr_pend & ~bvalid_r;
    assign wready  =  wr_pend & ~bvalid_r;
    assign bvalid  =  bvalid_r;
    assign bid     = 4'd0;
    assign bresp   = 2'b00;

    task automatic wr_word;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  s;
        begin
            if (a < 32'h0010_0000) begin
                if (s[0]) ddr_mem[a >> 2][ 7: 0] <= d[ 7: 0];
                if (s[1]) ddr_mem[a >> 2][15: 8] <= d[15: 8];
                if (s[2]) ddr_mem[a >> 2][23:16] <= d[23:16];
                if (s[3]) ddr_mem[a >> 2][31:24] <= d[31:24];
            end
            // DONE 标记（0x2FFC = 0xDEADBEEF）：由程序最后写入
            if (a == 32'h0000_2FFC && d == 32'hDEAD_BEEF && s == 4'hF)
                done_seen <= 1;
        end
    endtask

    always @(posedge clk) begin
        if (!aresetn) begin
            wr_pend <= 1'b0; bvalid_r <= 1'b0; aw_addr <= 32'h0;
        end else begin
            if (awvalid && awready) begin
                aw_addr <= {awaddr[31:2], 2'b00};
                wr_pend <= 1'b1;
            end
            if (wvalid && wready) begin
                wr_word(aw_addr, wdata, wstrb);
                wr_pend  <= 1'b0;
                bvalid_r <= 1'b1;
            end
            if (bvalid_r && bready) bvalid_r <= 1'b0;
        end
    end

    //==========================================================================
    // 2. 程序装载：objcopy -O verilog 的 `@<word idx>` 词法器 + 链接→运行重定位
    //==========================================================================
    task automatic load_hex;
        input [8*512-1:0] path;
        integer fd, c, v, i;
        reg [31:0] cur;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                load_err = 1;
                $display("2A_CTL_FAIL: cannot open program %0s", path);
            end else begin
                cur = RUN_BASE;
                c = $fgetc(fd);
                while (c != -1) begin
                    if (c == "@") begin
                        c = $fgetc(fd); v = 0;
                        while (((c >= "0") && (c <= "9")) ||
                               ((c >= "a") && (c <= "f")) ||
                               ((c >= "A") && (c <= "F"))) begin
                            if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                            else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                            else                               v = (v << 4) | (c - "A" + 10);
                            c = $fgetc(fd);
                        end
                        // objcopy -O verilog：`@` 是**数据字索引**（byte = v<<2）。
                        // 程序直接链接在 DDR 运行基址 0x0001_0000（@00004000）。
                        cur = v << 2;
                        if (scen == "xip_haz") begin
                            if (cur < XIP_BASE || cur >= XIP_BASE + 32'h10_0000) begin
                                load_err = 2;
                                $display("2A_CTL_FAIL: XIP program @0x%08h outside XIP window", cur);
                            end
                        end else if (cur < 32'h0000_1000 || cur >= 32'h0010_0000) begin
                            load_err = 2;
                            $display("2A_CTL_FAIL: program @0x%08h outside DDR window", cur);
                        end
                    end else if (((c >= "0") && (c <= "9")) ||
                                 ((c >= "a") && (c <= "f")) ||
                                 ((c >= "A") && (c <= "F"))) begin
                        v = 0;
                        while (((c >= "0") && (c <= "9")) ||
                               ((c >= "a") && (c <= "f")) ||
                               ((c >= "A") && (c <= "F"))) begin
                            if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                            else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                            else                               v = (v << 4) | (c - "A" + 10);
                            c = $fgetc(fd);
                        end
                        if (scen == "xip_haz")
                            xip_mem[(cur - XIP_BASE) >> 2] = v[31:0];
                        else if (cur < 32'h0010_0000)
                            ddr_mem[cur >> 2] = v[31:0];
                        cur = cur + 32'd4;
                    end else begin
                        c = $fgetc(fd);
                    end
                end
                $fclose(fd);
                if (scen != "xip_haz") begin
                    // XIP 跳板：lui x5, 0x10 ; jalr x0, 0(x5) ; nop
                    for (i = 0; i < 1024; i = i + 1) xip_mem[i] = 32'h0000_0013;
                    xip_mem[0] = 32'h0001_02B7;   // lui  x5, 0x10  (= 0x0001_0000)
                    xip_mem[1] = 32'h0002_8067;   // jalr x0, 0(x5)
                    xip_mem[2] = 32'h0000_0013;   // nop（取指行对齐）
                end
            end
        end
    endtask

    //==========================================================================
    // 3. 观测（只读层次引用：trap 事件 / 场景窗口命中）
    //==========================================================================
    integer cyc;
    integer n_commit, n_trap, n_int_trap;
    integer trap_at_ctrl, trap_cause_bad, trap_tval_bad, trap_epc_bad;
    integer trap_epc_seen;
    integer hit_mc_dual;      // E 读高半 && W 写 mcycle 低 && M 写 mcycle 低（2A 不可达，留证）
    integer hit_mc_w;         // E 读高半 && W 写 mcycle 低（2A 真实可达窗口）
    integer hit_mc_mwr;       // E 读高半 && M 写 mcycle 低（2A 不可达，留证）
    integer n_read_with_m;    // 计数器读在 E 且 M 槽有效（源+DDR 证据：2A 恒 0）
    integer hi_cancel_hit;    // 高半 32 bit 首 parcel 在途时发生 redirect（取消）次数
    integer commit_at_fault;  // 故障指令被提交的次数（必须 0）
    integer n_em_overlap;     // E/M 同时 valid 的拍数（2A 结构应为 0；高半 C16 新路径重点）
    integer n_hi_deliver;     // 起始 VA[1]=1（高半）的指令交付次数
    integer n_c16_hi;         // 高半起始且 16 bit（C16）的交付次数
    integer n_hi32_take;      // 高半 32 bit 首 parcel 锁存（跨字）次数
    integer xip_load_commit, xip_branch_commit;
    integer xip_branch_m_pending, xip_load_rsp_count, xip_load_rsp_bad;
    reg [31:0] xip_load_rsp_data;
    //  MRET+中断同拍帧（只读层次观测；用于窄边界确证 priv_ctrl 的 mstatus 集合 OR）
    reg        tr_frame_pend;
    reg        tr_frame_xret;
    reg [31:0] tr_frame_ms_pre, tr_frame_ms_post, tr_frame_set, tr_frame_clr;
    reg        tr_frame_int;
    reg [3:0]  tr_frame_cnt;
    reg [31:0] tr_frame_ms_stable;   // trap+6 拍的 mstatus（证明持久，不是单拍毛刺）
    integer hit_fl_merge;     // W 提交 fflags/fcsr 写 && 年轻 FP 在途 flags != 0

    always @(posedge clk) begin
        if (aresetn) cyc <= cyc + 1;
    end

    wire rd_cnt_hi = u_dut.de_valid &&
                     ((u_dut.de_csr_addr == `RV32GC_CSR_MCYCLEH) ||
                      (u_dut.de_csr_addr == `RV32GC_CSR_CYCLEH));
    wire csr_cnt_rd_d =
        (u_dut.de_csr_addr == `RV32GC_CSR_MCYCLE)    | (u_dut.de_csr_addr == `RV32GC_CSR_MCYCLEH) |
        (u_dut.de_csr_addr == `RV32GC_CSR_CYCLE)     | (u_dut.de_csr_addr == `RV32GC_CSR_CYCLEH)  |
        (u_dut.de_csr_addr == `RV32GC_CSR_MINSTRET)  | (u_dut.de_csr_addr == `RV32GC_CSR_MINSTRETH)|
        (u_dut.de_csr_addr == `RV32GC_CSR_INSTRET)   | (u_dut.de_csr_addr == `RV32GC_CSR_INSTRETH);
    wire w_mc_lo = u_dut.mcycle_we_w;
    wire m_mc_lo = u_dut.em_valid && u_dut.em_csr_we && !u_dut.m_exc_any &&
                   (u_dut.em_csr_addr == `RV32GC_CSR_MCYCLE);

    always @(posedge clk) begin
        if (aresetn) begin
            if (dbg != 0 && u_dut.csr_wen_w &&
                ((u_dut.mw_csr_addr == `RV32GC_CSR_FFLAGS) ||
                 (u_dut.mw_csr_addr == `RV32GC_CSR_FCSR)))
                $display("DBG_FF cyc=%0d mw_pc=0x%08h wdata=0x%08h younger=0x%02h em_we=%b em_f=0x%02h e_we=%b e_f=0x%02h fflags_r=0x%02h",
                         cyc, u_dut.mw_pc, u_dut.mw_csr_wdata, u_dut.e_flags_younger,
                         u_dut.em_fflags_we, u_dut.em_fflags, u_dut.e_fflags_we,
                         u_dut.fpu_fflags, u_dut.fflags_r);
            if (dbg != 0 && u_dut.de_valid && (u_dut.de_csr_addr == 12'hC80))
                $display("DBG_C80 cyc=%0d de_pc=0x%08h | em_pc=0x%08h em=%03h ev=%b ewe=%b | mw_pc=0x%08h mw=%03h wwe=%b | wmc=%b",
                         cyc, u_dut.de_pc, u_dut.em_pc, u_dut.em_csr_addr, u_dut.em_valid,
                         u_dut.em_csr_we, u_dut.mw_pc, u_dut.mw_csr_addr, u_dut.csr_wen_w,
                         u_dut.mcycle_we_w);
            if (dbg != 0 && (cyc >= 654) && (cyc <= 668))
                $display("DBG_PIPE cyc=%0d de_v=%b de=0x%08h em_v=%b em=0x%08h mw_v=%b mw=0x%08h adv=%b kill=%b mbusy=%b",
                         cyc, u_dut.de_valid, u_dut.de_pc, u_dut.em_valid, u_dut.em_pc,
                         u_dut.mw_valid, u_dut.mw_pc, u_dut.pipe_adv, u_dut.kill_young, u_dut.m_busy);
            if (dbg != 0 && (cyc >= 128) && (cyc <= 175))
                $display("DBG_F cyc=%0d fpc=0x%08h rspv=%b busy=%b reqv=%b reqpa=0x%08h insn_v=%b l1i_req=%b l1i_rdy=%b l1i_miss=%b",
                         cyc, u_dut.fu_fetch_pc, u_dut.fetch_rsp_valid, u_dut.u_fetch_unit.fetch_busy,
                         u_dut.fu_fetch_req_valid, u_dut.fu_fetch_req_pa, u_dut.fu_fetch_valid,
                         u_dut.l1i_cs_req, u_dut.l1i_cs_ready, u_dut.l1i_cs_miss);
            if (dbg != 0 && (u_dut.l1i_fill_fail | u_dut.l1i_cs_err))
                $display("DBG_L1IERR cyc=%0d fill_fail=%b cs_err=%b paddr=0x%08h",
                         cyc, u_dut.l1i_fill_fail, u_dut.l1i_cs_err, u_dut.l1i_cs_err_pa);
            if (dbg != 0 && u_dut.de_valid && (u_dut.de_pc == ctrl_pc))
                $display("DBG_ARM cyc=%0d de_pc=0x%08h irq_arm=%b intrpt=%02h plic_meip=%b mip11=%b mie11=%b mstatus_mie=%b",
                         cyc, u_dut.de_pc, irq_arm, intrpt, u_dut.plic_meip_sync_q,
                         u_dut.csr_mip[11], u_dut.csr_mie[11],
                         u_dut.csr_mstatus_raw[`RV32GC_MSTATUS_MIE_BIT]);
            if (dbg != 0 && u_dut.trap_valid)
                $display("DBG_TRAP cyc=%0d int=%b cause=0x%08h epc=0x%08h mw_valid=%b mw_pc=0x%08h",
                         cyc, u_dut.trap_is_int, u_dut.trap_cause, u_dut.trap_epc,
                         u_dut.mw_valid, u_dut.mw_pc);
            if (ws_valid) begin
                n_commit <= n_commit + 1;
                if (dbg != 0)
                    $display("DBG_COMMIT cyc=%0d pc=0x%08h wen=%b rd=x%0d wd=0x%08h",
                             cyc, debug0_wb_pc, debug0_wb_rf_wen[0],
                             debug0_wb_rf_wnum, debug0_wb_rf_wdata);
            end
            if (scen == "xip_haz") begin
                if (ws_valid && (debug0_wb_pc == load_pc))
                    xip_load_commit <= xip_load_commit + 1;
                if (ws_valid && (debug0_wb_pc == branch_pc))
                    xip_branch_commit <= xip_branch_commit + 1;
                if (u_dut.de_valid && (u_dut.de_pc == branch_pc) &&
                    u_dut.em_valid && (u_dut.em_pc == load_pc) &&
                    (u_dut.em_mem_op == 4'd1) && !u_dut.m_mem_done)
                    xip_branch_m_pending <= xip_branch_m_pending + 1;
                if (rvalid && rready && (rd_addr == data_addr)) begin
                    xip_load_rsp_count <= xip_load_rsp_count + 1;
                    xip_load_rsp_data <= rdata;
                    if (rdata !== data_val) xip_load_rsp_bad <= xip_load_rsp_bad + 1;
                end
            end
            if (u_dut.trap_valid) begin
                n_trap <= n_trap + 1;
                if (u_dut.trap_is_int) n_int_trap <= n_int_trap + 1;
                $display("2A_CTL_TRAP cyc=%0d int=%b cause=0x%08h epc=0x%08h tval=0x%08h mw_pc=0x%08h mw_valid=%b",
                         cyc, u_dut.trap_is_int, u_dut.trap_cause, u_dut.trap_epc,
                         u_dut.trap_tval, u_dut.mw_pc, u_dut.mw_valid);
                $display("2A_CTL_TRAP_INS cyc=%0d mw_insn=0x%08h fs=%0d mw_exc_tval=0x%08h mw_exc_is_fetch=%b",
                         cyc, u_dut.mw_insn_raw, u_dut.mstatus_fs, u_dut.mw_exc_tval,
                         u_dut.mw_exc_is_fetch);
                if (u_dut.trap_is_int) begin
                    if (ctrl_pc != 32'h0 && u_dut.mw_valid && (u_dut.mw_pc == ctrl_pc))
                        trap_at_ctrl <= trap_at_ctrl + 1;
                    if (mret_pc != 32'h0 && u_dut.mw_valid && (u_dut.mw_pc == mret_pc))
                        trap_at_ctrl <= trap_at_ctrl + 1;
                    if (u_dut.trap_cause != ((32'h1 << `RV32GC_MCAUSE_INT_BIT) | 32'hB))
                        trap_cause_bad <= trap_cause_bad + 1;
                    if (u_dut.trap_tval != 32'h0) trap_tval_bad <= trap_tval_bad + 1;
                    if (exp_epc != 32'h0) begin
                        trap_epc_seen <= u_dut.trap_epc;
                        if (u_dut.trap_epc != exp_epc) trap_epc_bad <= trap_epc_bad + 1;
                    end
                end
            end
            if (rd_cnt_hi && w_mc_lo && m_mc_lo) hit_mc_dual <= hit_mc_dual + 1;
            if (rd_cnt_hi && w_mc_lo) hit_mc_w <= hit_mc_w + 1;
            if (rd_cnt_hi && m_mc_lo && !w_mc_lo) hit_mc_mwr <= hit_mc_mwr + 1;
            if (u_dut.de_valid && csr_cnt_rd_d && u_dut.em_valid)
                n_read_with_m <= n_read_with_m + 1;
            if (u_dut.u_fetch_unit.hi32_q &&
                (u_dut.redirect_exc_v || u_dut.bru_redirect))
                hi_cancel_hit <= hi_cancel_hit + 1;
            if (ws_valid && (exp_epc != 32'h0) && (debug0_wb_pc == exp_epc) && (exp_tval != 32'h0))
                commit_at_fault <= commit_at_fault + 1;
            //  ★ 高半 C16 新路径的潜在 M/E 重叠：真实计数（不假设"低半未动 ⇒ C 流也不可达"）
            if (u_dut.de_valid && u_dut.em_valid) n_em_overlap <= n_em_overlap + 1;
            if (u_dut.fu_fetch_valid && u_dut.fu_fetch_insn_va[1]) begin
                n_hi_deliver <= n_hi_deliver + 1;
                if (!u_dut.fu_fetch_ilen32) n_c16_hi <= n_c16_hi + 1;
            end
            if (u_dut.u_fetch_unit.hi32_take) n_hi32_take <= n_hi32_take + 1;
            //  同拍帧：trap 与 xret 同拍时记下当拍 xret 有效、mstatus 前后值、set/clr
            if (tr_frame_pend) begin
                tr_frame_ms_post <= u_dut.csr_mstatus_raw;
                tr_frame_pend     <= 1'b0;
                tr_frame_cnt      <= 4'd1;
            end else if (tr_frame_cnt != 4'd0) begin
                tr_frame_cnt <= tr_frame_cnt + 4'd1;
                if (tr_frame_cnt == 4'd6) tr_frame_ms_stable <= u_dut.csr_mstatus_raw;
            end
            if (u_dut.trap_valid && (mret_pc != 32'h0) && u_dut.mw_valid &&
                (u_dut.mw_pc == mret_pc)) begin
                tr_frame_pend    <= 1'b1;
                tr_frame_xret    <= u_dut.mw_xret_valid;
                tr_frame_ms_pre  <= u_dut.csr_mstatus_raw;
                tr_frame_set     <= u_dut.mstatus_set;
                tr_frame_clr     <= u_dut.mstatus_clr;
                tr_frame_int     <= u_dut.trap_is_int;
            end
            // 显式 fflags/fcsr 写正在 W 提交，且更年轻在途 FP 指令有 flags（同拍并入窗口）
            if (u_dut.csr_wen_w &&
                ((u_dut.mw_csr_addr == `RV32GC_CSR_FFLAGS) ||
                 (u_dut.mw_csr_addr == `RV32GC_CSR_FCSR)) &&
                (u_dut.e_flags_younger != 5'd0)) hit_fl_merge <= hit_fl_merge + 1;
        end
    end

    //--------------------------------------------------------------------------
    // 4. 判据工具（fail-closed：任何不一致都置 chk_bad 并打印，不打印 PASS 兜底）
    //--------------------------------------------------------------------------
    integer chk_n, chk_bad;
    task automatic chk;
        input [8*64-1:0] nm;
        input [31:0]     got;
        input [31:0]     want;
        begin
            chk_n = chk_n + 1;
            if (got !== want) begin
                chk_bad = chk_bad + 1;
                $display("2A_CTL_CHK_BAD: %0s got=0x%08h want=0x%08h cyc=%0d",
                         nm, got, want, cyc);
            end else begin
                $display("2A_CTL_CHK: %0s = 0x%08h ok", nm, got);
            end
        end
    endtask

    task automatic chk_true;
        input [8*64-1:0] nm;
        input integer    cond;
        begin
            chk_n = chk_n + 1;
            if (!cond) begin
                chk_bad = chk_bad + 1;
                $display("2A_CTL_CHK_BAD: %0s cond=0 cyc=%0d", nm, cyc);
            end else begin
                $display("2A_CTL_CHK: %0s ok", nm);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 5. 主流程
    //--------------------------------------------------------------------------
    integer i, j, wait_cyc, got_done, rc;
    integer n_chk_printed;
    reg [31:0] g;

    initial begin
        // defaults
        scen = "none"; kind = "none"; ddr_path = "none";
        ctrl_pc = 32'h0; mret_pc = 32'h0; exp_epc = 32'h0;
        load_pc = 32'h0; branch_pc = 32'h0; exp_marker = 32'h0; exp_bad_marker = 32'h0;
        irq_en = 0; data_addr = 32'h0000_3000; data_val = 32'd0; rdelay = 0;
        cancel_chk = 0; arm_hi_chk = 0; exp_tval = 32'h0; dly_lo = 32'h0000_3000; dly_hi = 32'h0000_3100;
        err_lo = 32'h0; err_hi = 32'h0; err_kind = 0;
        cyc = 0; n_commit = 0; n_trap = 0; n_int_trap = 0;
        trap_at_ctrl = 0; trap_cause_bad = 0; trap_tval_bad = 0; trap_epc_bad = 0;
        trap_epc_seen = 0;
        hit_mc_dual = 0; hit_mc_w = 0; hit_mc_mwr = 0; hit_fl_merge = 0;
        n_read_with_m = 0; hi_cancel_hit = 0; commit_at_fault = 0; n_em_overlap = 0;
        n_hi_deliver = 0; n_c16_hi = 0; n_hi32_take = 0;
        xip_load_commit = 0; xip_branch_commit = 0; xip_branch_m_pending = 0;
        xip_load_rsp_count = 0; xip_load_rsp_bad = 0; xip_load_rsp_data = 32'h0;
        tr_frame_pend = 0; tr_frame_xret = 0; tr_frame_ms_pre = 0; tr_frame_ms_post = 0;
        tr_frame_set = 0; tr_frame_clr = 0; tr_frame_int = 0;
        tr_frame_cnt = 0; tr_frame_ms_stable = 0;
        chk_n = 0; chk_bad = 0; load_err = 0; done_seen = 0; uart_n = 0;

        dbg = 0;
        rc = $value$plusargs("SCEN=%s", scen);
        rc = $value$plusargs("KIND=%s", kind);
        rc = $value$plusargs("DDRPROG=%s", ddr_path);
        rc = $value$plusargs("CTRL_PC=%h", ctrl_pc);
        rc = $value$plusargs("LOAD_PC=%h", load_pc);
        rc = $value$plusargs("BR_PC=%h", branch_pc);
        rc = $value$plusargs("EXP_MARKER=%h", exp_marker);
        rc = $value$plusargs("EXP_BAD_MARKER=%h", exp_bad_marker);
        rc = $value$plusargs("MRET_PC=%h", mret_pc);
        rc = $value$plusargs("EXP_EPC=%h", exp_epc);
        rc = $value$plusargs("IRQ=%d", irq_en);
        rc = $value$plusargs("DATA_ADDR=%h", data_addr);
        rc = $value$plusargs("DATA_VAL=%d", data_val);
        rc = $value$plusargs("RDELAY=%d", rdelay);
        rc = $value$plusargs("DBG=%d", dbg);
        rc = $value$plusargs("CANCEL=%d", cancel_chk);
        rc = $value$plusargs("ARM_HI=%d", arm_hi_chk);
        rc = $value$plusargs("DELAY_LO=%h", dly_lo);
        rc = $value$plusargs("DELAY_HI=%h", dly_hi);
        rc = $value$plusargs("ERR_LO=%h", err_lo);
        rc = $value$plusargs("ERR_HI=%h", err_hi);
        rc = $value$plusargs("ERR_KIND=%d", err_kind);
        rc = $value$plusargs("EXP_TVAL=%h", exp_tval);

        for (i = 0; i < DDRW; i = i + 1) ddr_mem[i] = 32'h0000_0000;
        for (i = 0; i < 1024; i = i + 1) xip_mem[i] = 32'h0000_0013;
        ddr_mem[data_addr >> 2] = data_val;

        load_hex(ddr_path);
        if (load_err != 0) begin
            $display("2A_CTL_RESULT: FAIL reason=image_load");
            $fatal(1, "2A_CTL_FAIL");
        end

        $display("2A_CTL_CASE: scen=%0s kind=%0s ddr=%0s ctrl_pc=0x%08h mret_pc=0x%08h exp_epc=0x%08h irq=%0d rdelay=%0d",
                 scen, kind, ddr_path, ctrl_pc, mret_pc, exp_epc, irq_en, rdelay);

        repeat (20) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
        $display("2A_CTL_DIAG: reset released");

        i = 0;
        while (!done_seen && (i < 60000)) begin
            @(posedge clk);
            i = i + 1;
        end
        got_done = done_seen;
        repeat (60) @(posedge clk);

        $display("2A_CTL_DIAG: done=%0d commits=%0d traps=%0d int_traps=%0d cyc=%0d hits{dual=%0d mwr=%0d flmerge=%0d cancel=%0d} wcnt=%0d read_with_m=%0d em_ovl=%0d hi_del=%0d c16hi=%0d hi32take=%0d trap_at_ctrl=%0d commit_at_fault=%0d epc_seen=0x%08h",
                 got_done, n_commit, n_trap, n_int_trap, cyc,
                 hit_mc_dual, hit_mc_mwr, hit_fl_merge, hi_cancel_hit, hit_mc_w, n_read_with_m,
                 n_em_overlap, n_hi_deliver, n_c16_hi, n_hi32_take,
                 trap_at_ctrl, commit_at_fault, trap_epc_seen);

        // ---- 通用：DONE ----
        chk_true("done_marker", got_done);

        if (scen == "irq_ctl" || scen == "irq_ctl_nt") begin
            chk_true("exactly_one_int_trap", n_int_trap == 1);
            chk_true("trap_at_ctrl_commit", trap_at_ctrl == 1);
            chk_true("trap_cause_MEI", trap_cause_bad == 0);
            chk_true("trap_tval_zero", trap_tval_bad == 0);
            chk_true("trap_epc_signal", trap_epc_bad == 0);
            chk("mem_target_marker", ddr_mem[32'h2000 >> 2], 32'h0000_600D);
            chk("mem_mepc",          ddr_mem[32'h2014 >> 2], exp_epc);
            chk("mem_mcause",        ddr_mem[32'h2010 >> 2], 32'h8000_000B);
            chk("mem_mtval",         ddr_mem[32'h2018 >> 2], 32'h0);
            chk("mem_trap_count",    ddr_mem[32'h201C >> 2], 32'd1);
            if (scen == "irq_ctl" && (kind == "jal" || kind == "jalr" || kind == "cj")) begin
                if (kind != "cj")
                    chk("mem_link", ddr_mem[32'h2008 >> 2], ctrl_pc + 32'd4);
            end
            if (scen == "irq_ctl_nt") begin
                chk("epc_is_fallthrough", exp_epc, ctrl_pc + 32'd4);
            end
        end else if (scen == "irq_mret") begin
            chk_true("exactly_one_int_trap", n_int_trap == 1);
            chk_true("trap_at_mret_commit", trap_at_ctrl == 1);
            chk_true("trap_cause_MEI", trap_cause_bad == 0);
            chk_true("trap_tval_zero", trap_tval_bad == 0);
            chk_true("trap_epc_signal", trap_epc_bad == 0);
            chk("mem_mepc",       ddr_mem[32'h2014 >> 2], exp_epc);
            chk("mem_mcause",     ddr_mem[32'h2010 >> 2], 32'h8000_000B);
            chk("c_stream_marker", ddr_mem[32'h2004 >> 2], 32'h0000_600D);
        end else if (scen == "mret_mpie0") begin
            //  资格语义（08-06 修后）：MPIE=0 的 xret 后 MIE=0 ⇒ **本边界不取中断**；
            //  mret 已退休（返回目标执行 + mepc 保持），pending 保持，入口状态不动。
            chk("c_stream_marker",    ddr_mem[32'h2004 >> 2], 32'h0000_600D);
            chk("ret_target_marker",  ddr_mem[32'h2008 >> 2], 32'h0000_600D);
            chk("mepc_preserved",     ddr_mem[32'h2024 >> 2], exp_epc);
            chk("mstatus_after_xret", (ddr_mem[32'h2028 >> 2] & 32'h0000_1888), 32'h0000_0080);
            chk("no_int_trap",        ddr_mem[32'h201C >> 2], 32'd0);
            chk_true("no_int_trap_hw", n_int_trap == 0);
            chk_true("bad_path_absent", (ddr_mem[32'h2008 >> 2] != 32'h0000_0BAD));
        end else if (scen == "mret_mie1") begin
            chk_true("exactly_one_int_trap", n_int_trap == 1);
            chk_true("trap_at_mret_commit",  trap_at_ctrl == 1);
            chk_true("trap_cause_MEI",       trap_cause_bad == 0);
            chk("mem_mcause",      ddr_mem[32'h2010 >> 2], 32'h8000_000B);
            chk("mem_mepc",        ddr_mem[32'h2014 >> 2], exp_epc);
            chk("mstatus_sw_mie0_mpie1_mppm", (ddr_mem[32'h2020 >> 2] & 32'h0000_1888), 32'h0000_1880);
            chk("mstatus_hw_mie0_mpie1_mppm", (tr_frame_ms_post & 32'h0000_1888), 32'h0000_1880);
            chk_true("xret_committed_at_trap", tr_frame_xret == 1'b1);
            chk_true("bad_path_absent", (ddr_mem[32'h2008 >> 2] != 32'h0000_0BAD));
            $display("2A_CTL_MRET_FRAME: pre=0x%08h post=0x%08h stable6=0x%08h set=0x%08h clr=0x%08h xret=%b int=%b post_masked=0x%08h stable_masked=0x%08h",
                     tr_frame_ms_pre, tr_frame_ms_post, tr_frame_ms_stable,
                     tr_frame_set, tr_frame_clr, tr_frame_xret, tr_frame_int,
                     (tr_frame_ms_post & 32'h0000_1888), (tr_frame_ms_stable & 32'h0000_1888));
            $display("2A_CTL_MRET_TRAPS: n_int_trap=%0d n_trap=%0d", n_int_trap, n_trap);
        end else if (scen == "xip_haz") begin
            chk_true("xip_same_word_low_c16", (load_pc[31:2] == branch_pc[31:2]) &&
                     (branch_pc == load_pc + 32'd2));
            chk_true("xip_em_overlap", n_em_overlap > 0);
            chk_true("xip_load_exactly_once", xip_load_commit == 1);
            chk_true("xip_branch_exactly_once", xip_branch_commit == 1);
            chk_true("xip_branch_waited_for_m_load", xip_branch_m_pending > 0);
            chk_true("xip_load_response_identity", xip_load_rsp_count == 1);
            chk("xip_load_response_data", xip_load_rsp_data, data_val);
            chk("xip_target_marker", ddr_mem[32'h2000 >> 2], exp_marker);
            chk("xip_bad_path_marker", ddr_mem[32'h2004 >> 2], exp_bad_marker);
            $display("2A_CTL_XIP_HAZ: load_pc=0x%08h branch_pc=0x%08h load_commit=%0d branch_commit=%0d m_pending=%0d load_rsp=%0d rsp_bad=%0d",
                     load_pc, branch_pc, xip_load_commit, xip_branch_commit,
                     xip_branch_m_pending, xip_load_rsp_count, xip_load_rsp_bad);
            $display("2A_CTL_XIP_RSP: addr=0x%08h data=0x%08h expected=0x%08h", data_addr,
                     xip_load_rsp_data, data_val);
        end else if (scen == "haz_exec") begin
            chk("haz_marker",      ddr_mem[32'h2000 >> 2], 32'h0000_600D);
            chk("haz_branch_dep",  ddr_mem[32'h2004 >> 2], 32'h0000_1111);
            chk("haz_mul_dep",     ddr_mem[32'h2008 >> 2], 32'd49);
            chk("haz_fp_dep",      ddr_mem[32'h200C >> 2], 32'h4000_0000);
        end else if (scen == "cnt_order") begin
            // 程序自检：每项为 1 表示该关系成立（精确口径见程序注释）
            chk("adj_two_reads",        ddr_mem[32'h2000 >> 2], 32'd1);
            chk("gap_two_insts",        ddr_mem[32'h2004 >> 2], 32'd1);
            chk("wr_low_then_read",     ddr_mem[32'h2008 >> 2], 32'd1);
            chk("wr_high_then_read",    ddr_mem[32'h200C >> 2], 32'd1);
            chk("half_carry_hi",        ddr_mem[32'h2010 >> 2], 32'd1);
            chk("load_stall_gap",       ddr_mem[32'h2014 >> 2], 32'd1);
            chk("rmw_read_old",         ddr_mem[32'h2018 >> 2], 32'd1);
            chk("rmw_post_read",        ddr_mem[32'h201C >> 2], 32'd1);
            chk("rmw_old_raw",          ddr_mem[32'h2114 >> 2], 32'h0000_1000);
            chk("rmw_post_raw",         ddr_mem[32'h2118 >> 2], 32'h0000_1002);
            // mcycle 跨半 carry（可达窗口 = 更早写改 lo + W 槽写者落盘沿的 tick 进位）
            chk("mcycle_w_carry",       ddr_mem[32'h2020 >> 2], 32'd1);
            chk("mcycle_carry_seen",    ddr_mem[32'h2024 >> 2], 32'd1);
            chk("mcycle_single_ctrl",   ddr_mem[32'h2028 >> 2], 32'd1);
            // 实测值留档（可读性；不参与布尔判定）
            $display("2A_CTL_INFO: i0=0x%08h d1=0x%08h ihi=0x%08h ilo=0x%08h load=0x%08h pdiff=0x%08h rmw=0x%08h/0x%08h",
                     ddr_mem[32'h2100 >> 2], ddr_mem[32'h2104 >> 2],
                     ddr_mem[32'h2108 >> 2], ddr_mem[32'h210C >> 2],
                     ddr_mem[32'h2110 >> 2], ddr_mem[32'h211C >> 2],
                     ddr_mem[32'h2114 >> 2], ddr_mem[32'h2118 >> 2]);
            chk_true("w_writer_window_hit", hit_mc_w > 0);
            // 2A 结构事实（源 + DDR 证据）：E 有效的拍 M 槽为空（前端固定 2 拍/条）
            // ⇒ 投影的 M 分支当前不可达；此处显式留证，若结构变化则本项转红提醒扩测。
            chk("m_slot_absent_in_2a", n_read_with_m, 32'd0);
        end else if (scen == "hi_exec") begin
            chk("hi_path_marker", ddr_mem[32'h2000 >> 2], 32'h0000_600D);
            if (cancel_chk != 0) chk_true("hi_cancel_window_hit", hi_cancel_hit > 0);
        end else if (scen == "hi_fault") begin
            chk("hi_fault_marker_absent", ddr_mem[32'h2000 >> 2], 32'h0000_0000);
            chk("hi_fault_cause_IAF",     ddr_mem[32'h2010 >> 2], 32'd1);
            chk("hi_fault_mepc_insn_va",  ddr_mem[32'h2014 >> 2], exp_epc);
            chk("hi_fault_mtval_parcel",  ddr_mem[32'h2018 >> 2], exp_tval);
            chk("hi_fault_count",         ddr_mem[32'h201C >> 2], 32'd1);
            chk("hi_fault_no_commit",     commit_at_fault, 32'd0);
        end else if (scen == "err_exec") begin
            chk("err_cause_IAF",    ddr_mem[32'h2010 >> 2], 32'd1);
            chk("err_mepc_insn",    ddr_mem[32'h2014 >> 2], exp_epc);
            chk("err_mtval_parcel", ddr_mem[32'h2018 >> 2], exp_tval);
            chk("err_count",        ddr_mem[32'h201C >> 2], 32'd1);
            chk("err_no_commit",    commit_at_fault, 32'd0);
        end else if (scen == "err_late") begin
            chk("late_int_count",   ddr_mem[32'h202C >> 2], 32'd1);
            chk("late_af_count",    ddr_mem[32'h2030 >> 2], 32'd1);
            chk("late_af_cause",    ddr_mem[32'h2034 >> 2], 32'd1);
            chk("late_af_mepc",     ddr_mem[32'h2038 >> 2], exp_epc);
            chk("late_af_mtval",    ddr_mem[32'h203C >> 2], exp_tval);
            chk("late_marker",      ddr_mem[32'h2000 >> 2], 32'h0000_600D);
        end else if (scen == "fp_flags") begin
            chk("fp_flags_merge",   ddr_mem[32'h2000 >> 2], 32'h0000_0011);
            chk("fp_flags_kill",    ddr_mem[32'h2004 >> 2], 32'h0000_0000);
            chk("fp_flags_basic",   ddr_mem[32'h2008 >> 2], 32'h0000_0010);
            chk("fp_flags_ecall_retire", ddr_mem[32'h200C >> 2], 32'h0000_0010);
            $display("2A_CTL_INFO: fp_merge_window_hits=%0d ecall_mepc=0x%08h",
                     hit_fl_merge, ddr_mem[32'h2014 >> 2]);
        end else begin
            chk_true("known_scen", 0);
        end

        $display("2A_CTL_CHECKS: total=%0d bad=%0d", chk_n, chk_bad);
        if (chk_bad != 0) begin
            $display("2A_CTL_RESULT: FAIL bad=%0d", chk_bad);
            $fatal(1, "2A_CTL_FAIL");
        end
        $display("2A_CTL_RESULT: PASS");
        $finish;
    end

    // 超时保护（fail-closed）：任何路径都不打印 PASS
    initial begin
        #2_500_000;
        $display("2A_CTL_RESULT: FAIL timeout cyc=%0d", cyc);
        $fatal(1, "2A_CTL_TIMEOUT");
    end

endmodule
