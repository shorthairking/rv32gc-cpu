//==============================================================================
// sim/functional/tb_counter_time.sv
//   —— F1-B 计数器/时间/MPP 接口契约**功能级**用例（独立包，不入默认清单）
//==============================================================================
// 目的 : 验证 F1-B 叶接口契约（csr_file 视图/写请求/预览 + clint mtime_o + MPP WARL）。
//   ★ 本体归属声明：mcycle/minstret 的单一 64 位本体在**顶层**（本包不实现、不验证
//     顶层本体）。本 TB 用一个**TB 侧参考本体**（contract model）消费 DUT 的
//     mcycle_we_o/…/cnt_wdata_o，按已批准的程序序合同推进，并把结果回灌
//     cycle_i/instret_i 供 DUT 视图读取。它只证明"接口 + 合同可实现且自洽"，
//     **不代表 CPU 计数已闭环**（须由 71 在真实 top 落地后另行验证）。
//
// 程序序合同（KB 实读，zicsr.adoc:173-180 / 191-255）:
//   · "If a CSR access instruction writes such a CSR, the explicit write is done instead
//      of the update from the side effect. In particular, a value written to instret by
//      one instruction will be the value read by the following instruction."
//   · norm:csrw_order："an explicit CSR write suppresses and overrides any implicit
//      writes or modifications to the same CSR by **the same instruction**."
//   · norm:csraccessorder："a CSR access is performed after ... prior instructions ...
//      and before ... subsequent instructions"。
//   ★ 71 已证 CSR 写**不独占**提交：backend 增组合输出 csr_cmt_lane_o[1:0]（valid 同
//     csr_we_o，来自真实 qualified 提交 lane），top 用 commit_valid 在该 lane 前后计
//     older/younger。据此，写周期（同拍提交组）的合同为：
//       pre  = body + N_older          （更老指令先退休）
//       mid  = 半字替换(pre, 写值)      （写本条自身的隐式 +1 **不计**）
//       body'= mid + N_young           （更年轻指令在写之后退休）
//     非写周期：body' = body + N_older + 1 + N_young。
//     本 TB 的外部参考本体按此实现（n_older/n_young 显式驱动，模拟提交组位次），
//     **不再**用"全组 delta 先加后覆盖"的旧口径。
//     mcycle（与 minstret 规则不同，不得混用）：mcycle 是 clock 计数、非指令副效应，
//     zicsr 的"显式写代替副作用"不适用；写拍**先做整 64 位 +1（tick），再只覆盖
//     被写的半字**，另一半保留本拍增量/进位（RV32 "writes change only bits 31-0/63-32"）。
//     ★ 位次可达性：n_older/n_young 是通用模型（4 条）；本核 COMMIT_W=2，真实 Top
//       验证只须覆盖 2 退休组合：CSR lane0 + ALU1（older=0,younger=1）与
//       ALU0 + CSR lane1（older=1,younger=0）；不据本 TB 断言 3 退休可达。
//
// 覆盖向量（固定 12 个，每个 ≥1 条 `!==` 四态安全断言）:
//   V1 别名/time≠cycle；V2 写赢本条（2A 独占拍）；V3 older/write/younger（n_young=2）；
//   V4 写拍读旧值/W 预览新值（RMW 序）；V5 非写 64 位溢出进位；
//   V6 写低半抑制进位；V7 写高半不动低半；V8 minstret 高半写+次拍进位；
//   V9 mtime MMIO 写→time/timeh 同步（time≠cycle）；V10 MPP 非法编码落地合法+两预览；
//   V11 PMP 本项 L 锁（旧逻辑）；V12 counteren/TVM 旧逻辑。
//
// 判定 : 失败行 `FUNCTIONAL_COUNTER_TIME FAIL [TAG]: ...`；全过才打印
//        `FUNCTIONAL_COUNTER_TIME_VECTORS total=12 checks=<C> fails=0`、12 行
//        `CT VEC <i> checks=<d> fails=0` 与唯一整行 `FUNCTIONAL_COUNTER_TIME: PASS`。
// 顶层 : tb_counter_time
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_counter_time;

    localparam integer SPEC_VECTORS = 12;
    localparam integer SPEC_CHECKS  = 50;

    //--------------------------------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    integer n_pass = 0;
    integer n_fail = 0;
    integer n_vec  = 0;
    integer vec_chk_base  = 0;
    integer vec_fail_base = 0;
    integer vec_sum_checks = 0;
    reg [8*32-1:0] vec_name = "unnamed";

    task settle_vec;
        integer c, f;
        begin
            c = (n_pass + n_fail) - vec_chk_base;
            f = n_fail - vec_fail_base;
            if (c <= 0) begin
                f = f + 1; n_fail = n_fail + 1;
                $display("FUNCTIONAL_COUNTER_TIME FAIL [VEC_EMPTY]: vector %0d checks=0", n_vec);
            end
            vec_sum_checks = vec_sum_checks + c;
            $display("CT VEC %0d name=%0s checks=%0d fails=%0d", n_vec, vec_name, c, f);
        end
    endtask

    task vec_begin;
        begin
            if (n_vec > 0) settle_vec;
            n_vec = n_vec + 1;
            vec_chk_base  = n_pass + n_fail;
            vec_fail_base = n_fail;
        end
    endtask

    task chk32;
        input [8*40-1:0] tag;
        input [31:0]     got;
        input [31:0]     exp;
        begin
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("FUNCTIONAL_COUNTER_TIME FAIL [%0s]: got=0x%08x exp=0x%08x (t=%0t)",
                         tag, got, exp, $time);
            end else n_pass = n_pass + 1;
        end
    endtask

    task chk1;
        input [8*40-1:0] tag;
        input            got;
        input            exp;
        begin
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("FUNCTIONAL_COUNTER_TIME FAIL [%0s]: got=%0b exp=%0b (t=%0t)",
                         tag, got, exp, $time);
            end else n_pass = n_pass + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 本体（TB 侧参考模型；见文件头"本体归属声明"）
    //--------------------------------------------------------------------------
    reg  [63:0] body_cyc = 64'h0;
    reg  [63:0] body_ins = 64'h0;
    wire [63:0] cycle_i   = body_cyc;
    wire [63:0] instret_i = body_ins;
    reg         body_hold = 1'b0;      // 1=停表（便于绝对读检查）
    reg  [1:0]  n_older   = 2'd0;      // 写者 lane 之前（更老）的同拍退休数
    reg  [1:0]  n_young   = 2'd0;      // 写者 lane 之后（更年轻）的同拍退休数

    //   mcycle 下一值：写拍**先 tick（b+1）再覆盖被写半字**；另一半保留 tick 的
    //   增量/进位。停表（hold）只抑制"无写"的自由 tick；写拍仍按 tick+覆盖 建模
    //   （mcycle 自由运行，停表只是 TB 设初值的手段）。
    function [63:0] f_cyc_next;
        input [63:0] b; input wr_lo; input wr_hi; input [31:0] wd; input hold;
        reg [63:0] tick;
        begin
            tick = b + 64'd1;
            f_cyc_next = wr_lo ? {tick[63:32], wd} :
                         wr_hi ? {wd, tick[31:0]}  :
                         hold  ? b : tick;
        end
    endfunction

    //   minstret 下一值：pre=body+older；写⇒半字覆盖(不计本条)；否则 pre+1；最后 +younger。
    function [63:0] f_ins_next;
        input [63:0] b; input [1:0] older; input [1:0] younger;
        input wr_lo; input wr_hi; input [31:0] wd; input hold;
        reg [63:0] pre, mid;
        begin
            pre = b + {62'b0, older};
            if (wr_lo)      mid = {pre[63:32], wd};
            else if (wr_hi) mid = {wd, pre[31:0]};
            else            mid = hold ? b : (pre + 64'd1);
            f_ins_next = mid + {62'b0, younger};
        end
    endfunction

    //--------------------------------------------------------------------------
    // DUT：csr_file
    //--------------------------------------------------------------------------
    reg  [11:0] raddr = 12'h0;
    wire [31:0] rdata;
    reg         wen = 0;
    reg  [11:0] waddr = 12'h0;
    reg  [31:0] wdata = 32'h0;
    reg         w_illegal = 0;
    wire [31:0] rdata_w;
    reg  [31:0] byp_wdata = 32'h0;
    wire [31:0] byp_rdata;
    reg  [1:0]  tb_priv = `RV32GC_PRIV_M;
    reg  [11:0] chk_addr = 12'h0;
    wire        chk_illegal, chk_ro_write;
    wire [31:0] mstatus_o;
    wire [31:0] pc_set, pc_clr;
    wire [63:0] mtime_i;
    wire        mcycle_we, mcycleh_we, minstret_we, minstreth_we;
    wire [31:0] cnt_wdata;
    wire [127:0] pmp_cfg_o;
    wire [511:0] pmp_addr_o;
    wire [31:0] satp_o, menvcfg_o, senvcfg_o, mcounteren_o, scounteren_o;
    wire [31:0] mtvec_o, stvec_o, medeleg_o, mideleg_o, mie_o, mip_o;
    wire [31:0] mepc_o, sepc_o;

    csr_file dut (
        .clk(clk), .rst_n(rst_n),
        .raddr(raddr), .rdata(rdata),
        .wen(wen), .waddr(waddr), .wdata(wdata), .w_illegal(w_illegal),
        .rdata_w(rdata_w), .byp_wdata(byp_wdata), .byp_rdata(byp_rdata),
        .priv(tb_priv), .chk_addr(chk_addr),
        .chk_illegal(chk_illegal), .chk_ro_write(chk_ro_write),
        .mstatus_o(mstatus_o), .mstatus_set(pc_set), .mstatus_clr(pc_clr),
        .trap_we(4'h0), .trap_epc_i(32'h0), .trap_cause_i(32'h0),
        .trap_tval_i(32'h0), .trap_data_i(32'h0),
        .irq_msip(1'b0), .irq_mtip(1'b0), .irq_meip(1'b0),
        .irq_stip(1'b0), .irq_seip(1'b0),
        .cycle_i(cycle_i), .instret_i(instret_i), .mtime_i(mtime_i),
        .mcycle_we_o(mcycle_we), .mcycleh_we_o(mcycleh_we),
        .minstret_we_o(minstret_we), .minstreth_we_o(minstreth_we),
        .cnt_wdata_o(cnt_wdata),
        .pmp_cfg_o(pmp_cfg_o), .pmp_addr_o(pmp_addr_o),
        .satp_o(satp_o), .menvcfg_o(menvcfg_o), .senvcfg_o(senvcfg_o),
        .mcounteren_o(mcounteren_o), .scounteren_o(scounteren_o),
        .mtvec_o(mtvec_o), .stvec_o(stvec_o),
        .medeleg_o(medeleg_o), .mideleg_o(mideleg_o),
        .mie_o(mie_o), .mip_o(mip_o), .mepc_o(mepc_o), .sepc_o(sepc_o)
    );

    //--------------------------------------------------------------------------
    // DUT：priv_ctrl（仅用于 MPP/eff_priv 口径；其内部特权级复位=M）
    //--------------------------------------------------------------------------
    reg         p_csr_wen = 0;
    reg  [11:0] p_csr_waddr = 12'h0;
    reg  [31:0] p_csr_wdata = 32'h0;
    wire [1:0]  pc_priv_o, pc_eff_priv_o, pc_priv_next_o, pc_mpp_o;
    wire        pc_mprv_o, pc_sum_o, pc_mxr_o, pc_tvm_o, pc_tw_o, pc_tsr_o;
    wire        pc_fetch_m, pc_flush_req;

    priv_ctrl u_pc (
        .clk(clk), .rst_n(rst_n),
        .trap_valid(1'b0), .trap_target(`RV32GC_PRIV_M),
        .xret_valid(1'b0), .xret_kind(2'b00),
        .mstatus_i(mstatus_o), .csr_wen(p_csr_wen),
        .csr_waddr(p_csr_waddr), .csr_wdata(p_csr_wdata),
        .mstatus_set(pc_set), .mstatus_clr(pc_clr),
        .priv_o(pc_priv_o), .eff_priv_o(pc_eff_priv_o), .mprv_o(pc_mprv_o),
        .sum_o(pc_sum_o), .mxr_o(pc_mxr_o), .mpp_o(pc_mpp_o),
        .tvm_o(pc_tvm_o), .tw_o(pc_tw_o), .tsr_o(pc_tsr_o),
        .fetch_priv_is_m_o(pc_fetch_m), .flush_req(pc_flush_req),
        .priv_next_o(pc_priv_next_o)
    );

    //--------------------------------------------------------------------------
    // DUT：clint（mtime_o → csr_file.time 影子）
    //--------------------------------------------------------------------------
    reg         c_req_valid = 0;
    reg         c_req_write = 0;
    reg  [31:0] c_req_addr = 32'h0;
    reg  [31:0] c_req_wdata = 32'h0;
    reg  [3:0]  c_req_strb = 4'hF;
    wire [31:0] c_rdata;
    wire        c_hit, c_msip, c_mtip;

    clint u_clint (
        .aclk(clk), .aresetn(rst_n),
        .req_valid(c_req_valid), .req_write(c_req_write),
        .req_addr(c_req_addr), .req_wdata(c_req_wdata), .req_wstrb(c_req_strb),
        .resp_rdata(c_rdata), .resp_hit(c_hit),
        .msip_o(c_msip), .mtip_o(c_mtip), .mtime_o(mtime_i)
    );

    localparam [31:0] MTIMECMP_OFF  = `RV32GC_CLINT_MTIMECMP_OFF;
    localparam [31:0] MTIMECMPH_OFF = `RV32GC_CLINT_MTIMECMPH_OFF;
    localparam [31:0] MTIME_OFF     = `RV32GC_CLINT_MTIME_OFF;
    localparam [31:0] MTIMEH_OFF    = `RV32GC_CLINT_MTIMEH_OFF;

    //--------------------------------------------------------------------------
    // TB 参考本体：消费 DUT 的 we/cnt_wdata，按合同推进并回灌
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            body_cyc <= 64'h0;
            body_ins <= 64'h0;
        end else begin
            // ★ 契约：older → 半字覆盖（写本条不计）→ younger（见文件头）
            body_cyc <= f_cyc_next(body_cyc, mcycle_we, mcycleh_we, cnt_wdata, body_hold);
            body_ins <= f_ins_next(body_ins, n_older, n_young,
                                   minstret_we, minstreth_we, cnt_wdata, body_hold);
        end
    end

    //--------------------------------------------------------------------------
    // MMIO 任务（clint）
    //--------------------------------------------------------------------------
    task mmio_wr;
        input [31:0] off;
        input [31:0] d;
        begin
            @(negedge clk);
            c_req_addr = off; c_req_wdata = d; c_req_strb = 4'hF;
            c_req_write = 1'b1; c_req_valid = 1'b1;
            @(posedge clk); #1;
            c_req_valid = 1'b0; c_req_write = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // 复位
    //--------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n = 1'b0; body_hold = 1'b0; n_young = 2'd0;
            repeat (4) @(posedge clk); #1;
            rst_n = 1'b1; repeat (2) @(posedge clk); #1;
            body_hold = 1'b1;               // 默认停表，便于绝对检查
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    reg [31:0] rdv;

    initial begin
        $display("---- tb_counter_time: F1-B 计数器/时间/MPP 接口契约 ----");
        do_reset;

        //======================================================================
        // V1：别名（mcycle=cycle、minstret=instret）与 time≠cycle
        //======================================================================
        vec_begin;
        vec_name = "V1_alias_time";
        body_cyc = 64'h0000_0001_CAFE_0000;
        body_ins = 64'h0000_0002_1234_0000;
        mmio_wr(MTIMEH_OFF, 32'h0000_00AA);
        mmio_wr(MTIME_OFF,  32'hBBCC_DDEE);
        #1;
        raddr = `RV32GC_CSR_CYCLE;    #1; chk32("V1_CYCLE",    rdata, 32'hCAFE_0000);
        raddr = `RV32GC_CSR_CYCLEH;   #1; chk32("V1_CYCLEH",   rdata, 32'h0000_0001);
        raddr = `RV32GC_CSR_MCYCLE;   #1; chk32("V1_MCYCLE",   rdata, 32'hCAFE_0000);
        raddr = `RV32GC_CSR_MCYCLEH;  #1; chk32("V1_MCYCLEH",  rdata, 32'h0000_0001);
        raddr = `RV32GC_CSR_INSTRET;  #1; chk32("V1_INSTRET",  rdata, 32'h1234_0000);
        raddr = `RV32GC_CSR_MINSTRET; #1; chk32("V1_MINSTRET", rdata, 32'h1234_0000);
        raddr = `RV32GC_CSR_TIME;     #1;
        chk32("V1_TIME_EQ_MTIME", rdata, mtime_i[31:0]);
        chk1("V1_TIME_NE_CYCLE", (rdata !== cycle_i[31:0]), 1'b1);
        raddr = `RV32GC_CSR_TIMEH;    #1;
        chk32("V1_TIMEH_EQ_MTIME", rdata, mtime_i[63:32]);

        //======================================================================
        // V2：写赢本条（2A 独占提交拍：写指令自身 +1 被抑制）
        //======================================================================
        vec_begin;
        vec_name = "V2_write_wins_self";
        body_hold = 1'b1; body_ins = 64'h0000_0000_0000_03E8;   // 1000
        @(negedge clk);
        waddr = `RV32GC_CSR_MINSTRET; wdata = 32'h0000_03E8; wen = 1'b1;
        raddr = `RV32GC_CSR_MINSTRET; n_young = 2'd0; #1;
        chk1("V2_WE", minstret_we, 1'b1);
        chk32("V2_WDATA", cnt_wdata, 32'h0000_03E8);
        chk32("V2_RD_OLD", rdata, 32'h0000_03E8);          // 写指令自身读到旧值
        chk32("V2_PREVIEW_NEW", rdata_w, 32'h0000_03E8);   // 下一条读到写值
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; #1;
        chk32("V2_WRITE_WINS_SELF", body_ins[31:0], 32'h0000_03E8);
        raddr = `RV32GC_CSR_INSTRET; #1;
        chk32("V2_NEXT_READ", rdata, 32'h0000_03E8);

        //======================================================================
        // V3：older / write / younger（同拍更年轻退休必须在写值之后累加）
        //======================================================================
        vec_begin;
        vec_name = "V3_older_write_younger";
        body_hold = 1'b1; body_ins = 64'h0000_0000_0000_03E8;   // 1000（停表设初值）
        @(negedge clk);
        waddr = `RV32GC_CSR_MINSTRET; wdata = 32'h0000_07D0; wen = 1'b1;   // X=2000
        //   通用位次模型（older=1/写/younger=2）；本核 COMMIT_W=2，真实 Top 只须覆盖
        //   CSR lane0+ALU1 与 ALU0+CSR lane1 两个 2 退休组合（见文件头）。
        n_older = 2'd1; n_young = 2'd2; #1;
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; n_older = 2'd0; n_young = 2'd0; #1;
        //   pre=1001（older 先退）; 写值 2000 覆盖（本条不计 +1）; +2 younger ⇒ 2002
        chk32("V3_OLDER_WRITE_YOUNGER", body_ins[31:0], 32'h0000_07D2);   // 2002
        body_hold = 1'b0; @(posedge clk); #1;
        chk32("V3_THEN_NORMAL_RETIRE", body_ins[31:0], 32'h0000_07D3);   // 2003
        body_hold = 1'b1;

        //======================================================================
        // V4：写拍"读旧写新"（RMW 序）：rdata 旧值、rdata_w/byp 写值
        //======================================================================
        vec_begin;
        vec_name = "V4_rmw_order";
        body_hold = 1'b1; body_ins = 64'h0000_0000_0000_1000;
        @(negedge clk);
        waddr = `RV32GC_CSR_MINSTRET; wdata = 32'h0000_1001; wen = 1'b1;
        raddr = `RV32GC_CSR_MINSTRET; byp_wdata = 32'h0000_2000; #1;
        chk32("V4_RD_OLD", rdata, 32'h0000_1000);
        chk32("V4_W_PREVIEW", rdata_w, 32'h0000_1001);
        chk32("V4_M_PREVIEW", byp_rdata, 32'h0000_2000);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0; #1;

        //======================================================================
        // V5：非写拍 64 位进位（低半全 1 + 1 ⇒ 高半 +1）
        //======================================================================
        vec_begin;
        vec_name = "V5_carry64";
        body_hold = 1'b0;
        body_cyc = 64'h0000_0002_FFFF_FFFF; n_young = 2'd0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        chk32("V5_CARRY_LOW",  body_cyc[31:0], 32'h0000_0001);
        chk32("V5_CARRY_HIGH", body_cyc[63:32], 32'h0000_0003);
        body_hold = 1'b1;

        //======================================================================
        // V6：写低半抑制本拍 tick（高半不得因抑制掉的那拍进位）
        //======================================================================
        vec_begin;
        vec_name = "V6_mcycle_lo_carry";
        body_hold = 1'b1;
        body_cyc = 64'h0000_0002_FFFF_FFFF;
        @(negedge clk);
        waddr = `RV32GC_CSR_MCYCLE; wdata = 32'h0000_0000; wen = 1'b1; n_young = 2'd0;
        raddr = `RV32GC_CSR_CYCLEH; #1;
        chk1("V6_WE_LOW", mcycle_we, 1'b1);
        //   ★ scope：rdata_w 只预览"显式半字写"，不含同沿 tick（见 csr_file 注释）
        chk32("V6_RDATA_W_NO_TICK", rdata_w, 32'h0000_0002);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; #1;
        //   ★ 规则：先 64 位 tick（低半 FFFF_FFFF +1 ⇒ 进位），再只覆盖低半
        chk32("V6_WRITE_LOW_CARRY",  body_cyc[63:32], 32'h0000_0003);
        chk32("V6_WRITE_LOW_VALUE",  body_cyc[31:0],  32'h0000_0000);
        //   下一拍继续自由 +1 ⇒ 低半 1，高半保持 3
        body_hold = 1'b0; @(posedge clk); #1;
        chk32("V6_NEXT_TICK_LOW",  body_cyc[31:0],  32'h0000_0001);
        chk32("V6_NEXT_TICK_HIGH", body_cyc[63:32], 32'h0000_0003);
        body_hold = 1'b1;

        //======================================================================
        // V7：写高半不动低半（也抑制本拍 tick）
        //======================================================================
        vec_begin;
        vec_name = "V7_mcycle_hi_count";
        body_hold = 1'b1;
        body_cyc = 64'h0000_0002_0000_0000;
        @(negedge clk);
        waddr = `RV32GC_CSR_MCYCLEH; wdata = 32'h0000_0005; wen = 1'b1; #1;
        chk1("V7_WE_HIGH", mcycleh_we, 1'b1);
        chk1("V7_NO_LOW_WE", mcycle_we, 1'b0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; #1;
        //   ★ 规则：先 64 位 tick（低半 +1），再只覆盖高半 ⇒ 低半 = 1
        chk32("V7_HIGH_WRITTEN", body_cyc[63:32], 32'h0000_0005);
        chk32("V7_LOW_COUNTS",   body_cyc[31:0],  32'h0000_0001);

        //======================================================================
        // V8：minstret 高半写 + 次拍进位；低半保持
        //======================================================================
        vec_begin;
        vec_name = "V8_minstret_hi_older";
        body_hold = 1'b1;
        body_ins = 64'h0000_0001_FFFF_FFFF;     // 低半全 1（停表设初值）
        @(negedge clk);
        waddr = `RV32GC_CSR_MINSTRETH; wdata = 32'h0000_0002; wen = 1'b1;
        n_older = 2'd1; n_young = 2'd0; #1;     // older 使 pre 进位到高半
        chk1("V8_WE_HIGH", minstreth_we, 1'b1);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; n_older = 2'd0; #1;
        //   pre={2,0}（低半进位、高半 2）; 高半写 2 ⇒ {2,0}; 低半保留 pre 的 0
        chk32("V8_OLDER_CARRY_INTO_PRE", body_ins[63:32], 32'h0000_0002);
        chk32("V8_HALF_WRITE_KEEPS_LOW", body_ins[31:0],  32'h0000_0000);
        body_hold = 1'b0; @(posedge clk); #1;
        chk32("V8_NEXT_RETIRE",  body_ins[31:0],  32'h0000_0001);
        body_hold = 1'b1;

        //======================================================================
        // V9：MMIO 写 mtime ⇒ time/timeh 同步；time≠cycle
        //======================================================================
        vec_begin;
        vec_name = "V9_mtime_time";
        body_cyc = 64'h0000_0000_1111_2222;
        mmio_wr(MTIMEH_OFF, 32'h0000_0000);
        mmio_wr(MTIME_OFF,  32'h0000_0000);
        @(negedge clk);
        c_req_addr = MTIME_OFF; c_req_write = 1'b0; c_req_valid = 1'b1; #1;
        chk1("V9_MMIO_HIT", c_hit, 1'b1);
        raddr = `RV32GC_CSR_TIME; #1;
        chk32("V9_TIME_EQ_MTIME", rdata, c_rdata);
        chk1("V9_TIME_NE_CYCLE", (rdata !== cycle_i[31:0]), 1'b1);
        @(posedge clk); #1;
        c_req_valid = 1'b0; c_req_write = 1'b0;
        //   软件写 mtime 高字后 timeh 跟随
        mmio_wr(MTIMEH_OFF, 32'h0000_0009);
        raddr = `RV32GC_CSR_TIMEH; #1;
        chk32("V9_TIMEH_EQ_MTIME", rdata, mtime_i[63:32]);

        //======================================================================
        // V10：MPP 非法编码 2'b10 ⇒ 落地/读回/preview 全为合法 S
        //======================================================================
        vec_begin;
        vec_name = "V10_mpp_warl";
        @(negedge clk);
        waddr = `RV32GC_CSR_MSTATUS; wdata = (32'h2 << `RV32GC_MSTATUS_MPP_LSB);
        wen = 1'b1; raddr = `RV32GC_CSR_MSTATUS; byp_wdata = wdata; #1;
        chk32("V10_W_PREVIEW_LEGAL", rdata_w, 32'h0000_0800);
        chk32("V10_M_PREVIEW_LEGAL", byp_rdata, 32'h0000_0800);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0; #1;
        raddr = `RV32GC_CSR_MSTATUS; #1;
        chk32("V10_READBACK_LEGAL", rdata, 32'h0000_0800);
        chk32("V10_MSTATUS_O_LEGAL", mstatus_o & 32'h0000_1800, 32'h0000_0800);
        //   priv_ctrl 旁路（MPRV=1 + MPP=10 写）⇒ mpp_o=S、eff_priv=S
        @(negedge clk);
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_MSTATUS;
        p_csr_wdata = (32'h2 << `RV32GC_MSTATUS_MPP_LSB) | (32'h1 << `RV32GC_MSTATUS_MPRV_BIT);
        #1;
        chk32("V10_PC_MPP_LEGAL", {30'b0, pc_mpp_o}, 32'h1);
        chk32("V10_PC_EFF_S",     {30'b0, pc_eff_priv_o}, 32'h1);
        p_csr_wen = 1'b0; #1;

        //======================================================================
        // V11：PMP 本项 L 锁（旧逻辑不回退）
        //======================================================================
        vec_begin;
        vec_name = "V11_pmp_lock";
        @(negedge clk);
        waddr = `RV32GC_CSR_PMPCFG0; wdata = 32'h0000_009F; wen = 1'b1; #1;
        @(posedge clk); #1; @(negedge clk); wen = 1'b0; #1;
        @(negedge clk);
        waddr = `RV32GC_CSR_PMPADDR0; wdata = 32'h0000_1234; wen = 1'b1; #1;
        @(posedge clk); #1; @(negedge clk); wen = 1'b0; #1;
        raddr = `RV32GC_CSR_PMPADDR0; #1;
        chk32("V11_PMP_OWN_L_LOCK", rdata, 32'h0);

        //======================================================================
        // V12：counteren / TVM 旧逻辑不回退
        //======================================================================
        vec_begin;
        vec_name = "V12_counteren_tvm";
        @(negedge clk);
        waddr = `RV32GC_CSR_MCOUNTEREN; wdata = 32'h0; wen = 1'b1; #1;
        @(posedge clk); #1; @(negedge clk); wen = 1'b0; #1;
        tb_priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        chk1("V12_CNTR_S_GATED", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_SATP; #1;
        chk1("V12_TVM_OFF_OK", chk_illegal, 1'b0);
        //   TVM=1 ⇒ S 访问 satp 非法
        @(negedge clk);
        waddr = `RV32GC_CSR_MSTATUS; wdata = (32'h1 << `RV32GC_MSTATUS_TVM_BIT);
        wen = 1'b1; #1;
        @(posedge clk); #1; @(negedge clk); wen = 1'b0; #1;
        tb_priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_SATP; #1;
        chk1("V12_TVM_S_ILL", chk_illegal, 1'b1);
        tb_priv = `RV32GC_PRIV_M; chk_addr = 12'h0; #1;

        //======================================================================
        // 汇总
        //======================================================================
        settle_vec;
        if (n_vec !== SPEC_VECTORS) begin
            n_fail = n_fail + 1;
            $display("FUNCTIONAL_COUNTER_TIME FAIL [VECTOR_COUNT]: vectors=%0d exp=%0d",
                     n_vec, SPEC_VECTORS);
        end
        if (vec_sum_checks !== SPEC_CHECKS) begin
            n_fail = n_fail + 1;
            $display("FUNCTIONAL_COUNTER_TIME FAIL [CHECK_SUM]: checks=%0d exp=%0d",
                     vec_sum_checks, SPEC_CHECKS);
        end
        $display("CT SPEC total=%0d checks=%0d", SPEC_VECTORS, SPEC_CHECKS);
        $display("---- tb_counter_time: checks=%0d pass=%0d fail=%0d vectors=%0d ----",
                 n_pass + n_fail, n_pass, n_fail, n_vec);
        $display("FUNCTIONAL_COUNTER_TIME_VECTORS total=%0d checks=%0d fails=%0d",
                 n_vec, vec_sum_checks, n_fail);
        if (n_fail != 0) begin
            $display("FUNCTIONAL_COUNTER_TIME: FAIL %0d", n_fail);
            $fatal(1, "FUNCTIONAL_COUNTER_TIME FAIL");
        end
        $display("FUNCTIONAL_COUNTER_TIME: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    initial begin
        #400000;
        $display("FUNCTIONAL_COUNTER_TIME FAIL [TIMEOUT]");
        $fatal(1, "FUNCTIONAL_COUNTER_TIME FAIL");
    end

endmodule
