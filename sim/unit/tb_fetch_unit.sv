//==============================================================================
// sim/unit/tb_fetch_unit.sv —— rtl/fetch/fetch_unit.v 单元测试
//==============================================================================
// 测什么  : F 级顶层三件事（docs/design/08-baseline-5stage.md §5.1；§4.3）——
//           ① 复位首取 = RESET_PC = 0x1C00_0000（+ `fetch_pc_pa` 恒等 `fetch_pc`）；
//           ② XIP 旁路判定**用物理地址**：PA[31:20]==12'h1C0 || PA[31:16]==16'h1FE8
//              ⇒ uncached=1（两个窗口都要判到，且 DDR3/非 XIP 不得误置）；
//           ③ 取指 PMP 按 **16-bit parcel 逐个检查**：无 X ⇒ cause=1、
//              mtval = **该 parcel 的虚拟地址**、fetch_exc_pc = 故障指令起始地址；
//              无匹配项时 M 允许 / S、U 拒绝；
//           ④ 32 bit 指令跨 parcel ⇒ 交出的必须是**完整 32 bit**，不得半条指令。
// 怎么判  : 全部检查 $fatal；失败路径只打 FAIL + $fatal；
//           走完全部用例才在最后一行打印 `TB_FETCH_UNIT_UNIT: PASS`。
// 失败长相: "FAIL: <用例名> 期望 x 实得 y" 后跟 $fatal 与非零退出码。
// 反证实验: -DFETCH_UNIT_XOR_MUTATION 使判定值偏移，TB 必须 FAIL（08 §8.5）。
// 顶层    : tb_fetch_unit_top
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_fetch_unit_top;

    //---- 真源常量 ----
    localparam [31:0] RESET_PC   = `RV32GC_RESET_PC;    // 0x1C00_0000
    localparam [31:0] XIP_ALIAS  = `RV32GC_XIP_ALIAS;   // 0x1FE8_0000
    localparam [31:0] DDR_BASE   = `RV32GC_DDR_BASE;    // 0x0000_0000
    localparam [1:0]  PRIV_M     = `RV32GC_PRIV_M;
    localparam [1:0]  PRIV_S     = `RV32GC_PRIV_S;
    localparam [1:0]  PRIV_U     = `RV32GC_PRIV_U;
    localparam [4:0]  CAUSE_IAF  = `RV32GC_EXC_INSN_ACCESS_FAULT;   // 1

    localparam integer CLK_PERIOD = 10;
    localparam integer N_PMP      = `RV32GC_PMP_ENTRIES;            // 16

    // C5 用例（跨字 32 bit 指令）：指令起始 2 B 对齐 ⇒ 第二 parcel 落在下一个 4 B 字
    localparam [31:0] INS_VAB = RESET_PC + 32'h2;   // 指令起始 VA
    localparam [31:0] P1_VA   = RESET_PC + 32'h4;   // 第二 parcel 所在 4 B 字

    //---- DUT 端口 ----
    reg         aclk, aresetn;
    reg         rst_hold, rst_valid;
    reg         redirect_exc_valid;  reg [31:0] redirect_exc_pc;
    reg         redirect_bru_valid;  reg [31:0] redirect_bru_pc;
    reg         break_point;
    reg         fetch_pause;
    reg         insn_accept;

    reg         sv32_translate_en, sv32_translate_done;
    reg         sv32_translate_fault;
    reg  [31:0] sv32_translate_paddr;

    reg  [1:0]  priv;
    reg  [N_PMP*8-1:0]  pmpcfg_i;
    reg  [N_PMP*32-1:0] pmpaddr_i;

    wire        fetch_req_valid;
    wire [31:0] fetch_req_pa;
    wire        fetch_req_uncached;
    wire        fetch_req_cacheable;

    reg  [31:0] fetch_rsp_data;
    reg  [31:0] fetch_rsp_va;
    reg         fetch_rsp_valid;
    wire        fetch_rsp_ready;

    wire [31:0] fetch_pc, fetch_pc_pa, fetch_data, fetch_data_pa;
    wire [15:0] parcel_o;
    wire        parcel_is_lo, parcel_is_lo_pa;
    wire        fetch_valid, fetch_ilen32;
    wire [31:0] fetch_insn_va, fetch_insn_pa;
    wire        uncached;
    wire [31:0] fetch_uncached_pa;

    wire        fetch_exc_valid;
    wire [4:0]  fetch_exc_cause;
    wire [31:0] fetch_exc_tval, fetch_exc_pc;

    integer checks_run, checks_fail;

    fetch_unit #(
        .PMP_ENTRIES (`RV32GC_PMP_ENTRIES),
        .PMP_ENTRY_W (`RV32GC_PMP_ENTRY_W)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .rst_hold(rst_hold), .rst_valid(rst_valid),
        .redirect_exc_valid(redirect_exc_valid), .redirect_exc_pc(redirect_exc_pc),
        .redirect_bru_valid(redirect_bru_valid), .redirect_bru_pc(redirect_bru_pc),
        .break_point(break_point),
        .fetch_pause(fetch_pause), .insn_accept(insn_accept),
        .sv32_translate_en(sv32_translate_en),
        .sv32_translate_done(sv32_translate_done),
        .sv32_translate_fault(sv32_translate_fault),
        .sv32_translate_paddr(sv32_translate_paddr),
        .priv(priv), .pmpcfg_i(pmpcfg_i), .pmpaddr_i(pmpaddr_i),
        .fetch_req_valid(fetch_req_valid), .fetch_req_pa(fetch_req_pa),
        .fetch_req_uncached(fetch_req_uncached),
        .fetch_req_cacheable(fetch_req_cacheable),
        .fetch_rsp_data(fetch_rsp_data), .fetch_rsp_va(fetch_rsp_va),
        .fetch_rsp_valid(fetch_rsp_valid), .fetch_rsp_ready(fetch_rsp_ready),
        .fetch_pc(fetch_pc), .fetch_pc_pa(fetch_pc_pa),
        .fetch_data(fetch_data), .fetch_data_pa(fetch_data_pa),
        .parcel_o(parcel_o), .parcel_is_lo(parcel_is_lo),
        .parcel_is_lo_pa(parcel_is_lo_pa),
        .fetch_valid(fetch_valid), .fetch_ilen32(fetch_ilen32),
        .fetch_insn_va(fetch_insn_va), .fetch_insn_pa(fetch_insn_pa),
        .uncached(uncached), .fetch_uncached_pa(fetch_uncached_pa),
        .fetch_exc_valid(fetch_exc_valid), .fetch_exc_cause(fetch_exc_cause),
        .fetch_exc_tval(fetch_exc_tval), .fetch_exc_pc(fetch_exc_pc)
    );

    initial aclk = 1'b0;
    always #(CLK_PERIOD/2) aclk = ~aclk;

    //--------------------------------------------------------------------------
    // 判定任务
    //--------------------------------------------------------------------------
    task automatic chk32;
        input [255:0] name;
        input [31:0]  exp;
        input [31:0]  got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %08x 实得 %08x", name, exp, got);
                $fatal(1, "TB_FETCH_UNIT FAIL");
            end else begin
                $display("  ok  %0s = %08x", name, got);
            end
        end
    endtask

    task automatic chk1;
        input [255:0] name;
        input         exp;
        input         got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %b 实得 %b", name, exp, got);
                $fatal(1, "TB_FETCH_UNIT FAIL");
            end else begin
                $display("  ok  %0s = %b", name, got);
            end
        end
    endtask

    task automatic chk5;
        input [255:0] name;
        input [4:0]   exp;
        input [4:0]   got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %0d 实得 %0d", name, exp, got);
                $fatal(1, "TB_FETCH_UNIT FAIL");
            end else begin
                $display("  ok  %0s = %0d", name, got);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // PMP 编程助手（G=0，4 B 粒度）：把项 idx 设为 NAPOT 覆盖 4 B @ pa_base，权限 rwx
    //--------------------------------------------------------------------------
    task automatic pmp_set_na4_rwx;
        input integer idx;
        input [31:0]  pa_base;
        reg   [7:0]   cfg;
        begin
            cfg = 8'h00;
            cfg[`RV32GC_PMP_R_BIT] = 1'b1;
            cfg[`RV32GC_PMP_W_BIT] = 1'b1;
            cfg[`RV32GC_PMP_X_BIT] = 1'b1;
            cfg[`RV32GC_PMP_A_LSB +: 2] = `RV32GC_PMP_A_NA4;
            pmpcfg_i[idx*8 +: 8]   = cfg;
            pmpaddr_i[idx*32 +: 32] = pa_base >> 2;
        end
    endtask

    // 清掉项 idx 的 X 位（只留 R/W）—— 用于构造「无执行权限 ⇒ cause 1」用例
    task automatic pmpcfg_x_clear;
        input integer idx;
        reg   [7:0]  cfg_t;
        begin
            cfg_t = pmpcfg_i[idx*8 +: 8];
            cfg_t[`RV32GC_PMP_X_BIT] = 1'b0;
            pmpcfg_i[idx*8 +: 8] = cfg_t;
        end
    endtask

    // 把项 idx 设为 NAPOT 覆盖整个 2^sz_log2 字节块（基址对齐）
    task automatic pmp_set_napot;
        input integer idx;
        input [31:0]  pa_base;
        input integer sz_log2;      // 块大小 = 2^sz_log2
        input         allow_x;
        reg   [7:0]   cfg_t;
        reg   [31:0]  a_t;
        begin
            cfg_t = 8'h00;
            cfg_t[`RV32GC_PMP_R_BIT] = 1'b1;
            cfg_t[`RV32GC_PMP_W_BIT] = 1'b1;
            cfg_t[`RV32GC_PMP_X_BIT] = allow_x;
            cfg_t[`RV32GC_PMP_A_LSB +: 2] = `RV32GC_PMP_A_NAPOT;
            // NAPOT 编码：基址右移 2 后，低位补 (sz_log2-3-?) 个 1
            //   块大小 2^sz_log2 字节 ⇒ 偏移位 [sz_log2-1:0]，pmpaddr 低位为
            //   (sz_log2-2) 个 1（因 pmpaddr 以 4 B 为单位，最低位对应 8 B 块）
            a_t = (pa_base >> 2) | ((32'hFFFF_FFFF) >> (34 - sz_log2));
            pmpcfg_i[idx*8 +: 8]    = cfg_t;
            pmpaddr_i[idx*32 +: 32] = a_t;
        end
    endtask

    task automatic pmp_clear_all;
        begin
            pmpcfg_i  = {N_PMP*8{1'b0}};
            pmpaddr_i = {N_PMP*32{1'b0}};
        end
    endtask

    //--------------------------------------------------------------------------
    // 复位助手
    //--------------------------------------------------------------------------
    task automatic do_reset;
        begin
            @(negedge aclk);
            aresetn = 1'b0;
            rst_hold = 1'b0; rst_valid = 1'b0; break_point = 1'b0;
            redirect_exc_valid = 1'b0; redirect_exc_pc = 32'h0;
            redirect_bru_valid = 1'b0; redirect_bru_pc = 32'h0;
            fetch_pause = 1'b0; insn_accept = 1'b1;
            sv32_translate_en = 1'b0; sv32_translate_done = 1'b0;
            sv32_translate_fault = 1'b0; sv32_translate_paddr = 32'h0;
            priv = PRIV_M;
            pmp_clear_all;
            fetch_rsp_data = 32'h0; fetch_rsp_va = 32'h0; fetch_rsp_valid = 1'b0;
            repeat (2) @(posedge aclk);
            @(negedge aclk) aresetn = 1'b1;
            @(posedge aclk); #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 用例
    //--------------------------------------------------------------------------
    integer k;
    initial begin
        checks_run = 0; checks_fail = 0;
        aclk = 1'b0; aresetn = 1'b0;
        rst_hold = 1'b0; rst_valid = 1'b0; break_point = 1'b0;
        redirect_exc_valid = 1'b0; redirect_exc_pc = 32'h0;
        redirect_bru_valid = 1'b0; redirect_bru_pc = 32'h0;
        fetch_pause = 1'b0; insn_accept = 1'b1;
        sv32_translate_en = 1'b0; sv32_translate_done = 1'b0;
        sv32_translate_fault = 1'b0; sv32_translate_paddr = 32'h0;
        priv = PRIV_M;
        pmpcfg_i = {N_PMP*8{1'b0}}; pmpaddr_i = {N_PMP*32{1'b0}};
        fetch_rsp_data = 32'h0; fetch_rsp_va = 32'h0; fetch_rsp_valid = 1'b0;

        $display("---- tb_fetch_unit: RESET_PC / XIP 旁路 / 取指 PMP(parcel) ----");

        //==================================================================
        // C1: 复位 ⇒ fetch_pc = RESET_PC；M1 无 MMU ⇒ fetch_pc_pa == fetch_pc
        //==================================================================
        do_reset;
        chk32("C1 reset fetch_pc == RESET_PC", RESET_PC, fetch_pc);
        chk32("C1 M1 Bare: fetch_pc_pa == fetch_pc", fetch_pc, fetch_pc_pa);
        // 复位后 PC 落在 XIP 主窗口 ⇒ uncached 必须已置起（组合判定，用 PA）
        chk1 ("C1 RESET_PC is uncached (XIP hi20==1C0)", 1'b1, uncached);
        chk1 ("C1 fetch_req_uncached follows uncached",  1'b1, fetch_req_uncached);
        chk1 ("C1 fetch_req_cacheable = ~uncached",      1'b0, fetch_req_cacheable);

        //==================================================================
        // C2: XIP 旁路判定 —— 三个地址点逐点验证（**用物理地址**）
        //     2a RESET_PC（PA[31:20]==1C0）⇒ uncached
        //     2b XIP 别名（PA[31:16]==1FE8）⇒ uncached
        //     2c DDR3（PA[31:28]==0）⇒ cached（不得误置 uncached）
        //==================================================================
        //---- C2a: XIP 主窗口内的另一个地址（证明是位段判定，不是只认 RESET_PC）----
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1; redirect_bru_pc = RESET_PC + 32'h0008_0000;
        end
        #1; @(posedge aclk); #1;
        chk32("C2a fetch_pc in XIP main window", RESET_PC + 32'h0008_0000, fetch_pc);
        chk1 ("C2a uncached (PA[31:20]==1C0)", 1'b1, uncached);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C2b: XIP 别名窗口 0x1FE8_0000 ----
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1; redirect_bru_pc = XIP_ALIAS + 32'h100;
        end
        #1; @(posedge aclk); #1;
        chk32("C2b fetch_pc in XIP alias", XIP_ALIAS + 32'h100, fetch_pc);
        chk1 ("C2b uncached (PA[31:16]==1FE8)", 1'b1, uncached);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C2c: DDR3 区（PA[31:28]==0）⇒ **不得** uncached ----
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1; redirect_bru_pc = DDR_BASE + 32'h1000;
        end
        #1; @(posedge aclk); #1;
        chk32("C2c fetch_pc in DDR3", DDR_BASE + 32'h1000, fetch_pc);
        chk1 ("C2c NOT uncached (DDR3 is cacheable)", 1'b0, uncached);
        chk1 ("C2c fetch_req_uncached=0",             1'b0, fetch_req_uncached);
        chk1 ("C2c fetch_req_cacheable=1",            1'b1, fetch_req_cacheable);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C2d: 边界反证 —— 0x1FE8 窗口的**下一个** 64 KiB（0x1FE9_0000）不得命中 ----
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1; redirect_bru_pc = 32'h1FE9_0000;
        end
        #1; @(posedge aclk); #1;
        chk1("C2d 0x1FE9_xxxx is NOT XIP (alias window bound)", 1'b0, uncached);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C2e: 主窗口边界 —— 0x1C0F_FFFF 命中，0x1C10_0000 不命中 ----
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1; redirect_bru_pc = 32'h1C0F_FFFE;
        end
        #1; @(posedge aclk); #1;
        chk1("C2e 0x1C0F_FFFE in XIP main window", 1'b1, uncached);
        @(negedge aclk) redirect_bru_pc = 32'h1C10_0000;
        #1; @(posedge aclk); #1;
        chk1("C2e 0x1C10_0000 out of XIP main window", 1'b0, uncached);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //==================================================================
        // C3: 取指 PMP —— 无 PMP 项时按特权级（norm:pmpnoentry_match）
        //     M ⇒ 允许；S/U ⇒ 拒绝（已实现 16 项）
        //==================================================================
        do_reset;                     // 全 PMP OFF，priv=M
        // 送入一个取指字（16 bit 压缩指令 0x0505）并让 fetch_rsp 有效
        @(negedge aclk) begin
            fetch_rsp_data  = 32'h0000_0505;
            fetch_rsp_va    = RESET_PC;
            fetch_rsp_valid = 1'b1;
            priv            = PRIV_M;
        end
        #1;
        chk1("C3 M-mode, no PMP entry: no exc", 1'b0, fetch_exc_valid);
        chk1("C3 M-mode: fetch_valid",          1'b1, fetch_valid);
        chk32("C3 fetch_data = compressed insn", 32'h0000_0505, fetch_data);
        chk1 ("C3 fetch_ilen32=0",              1'b0, fetch_ilen32);
        chk32("C3 parcel_o (compressed = low half)", 32'h0000_0505, {16'h0, parcel_o});
        chk1 ("C3 parcel_is_lo=1 for compressed",   1'b1, parcel_is_lo);
        @(negedge aclk) fetch_rsp_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C3b: S 模式、无任何 PMP 项 ⇒ 拒绝（cause=1） ----
        @(negedge aclk) begin
            priv            = PRIV_S;
            fetch_rsp_data  = 32'h0000_0505;
            fetch_rsp_va    = RESET_PC;
            fetch_rsp_valid = 1'b1;
        end
        #1;
        chk1 ("C3b S-mode no PMP: exception", 1'b1, fetch_exc_valid);
        chk5 ("C3b S-mode no PMP: cause=1 (IAF)", CAUSE_IAF, fetch_exc_cause);
        chk32("C3b mtval = faulting parcel VA", RESET_PC, fetch_exc_tval);
        chk1 ("C3b fetch_valid suppressed on exc", 1'b0, fetch_valid);
        @(negedge aclk) fetch_rsp_valid = 1'b0;
        @(posedge aclk); #1;

        //==================================================================
        // C4: 取指 PMP 命中项**无 X 权限** ⇒ cause=1（§5.1 ③；§6.3 T2）
        //     S 模式 + 覆盖 RESET_PC 的 RW（无 X）项 ⇒ 拒
        //==================================================================
        do_reset;
        pmp_set_na4_rwx(0, RESET_PC);
        // 把项 0 的 X 位清掉（只留 RW）
        pmpcfg_x_clear(0);
        @(negedge aclk) begin
            priv            = PRIV_S;
            fetch_rsp_data  = 32'h0000_0505;
            fetch_rsp_va    = RESET_PC;
            fetch_rsp_valid = 1'b1;
        end
        #1;
        chk1 ("C4 RW-only entry: exception", 1'b1, fetch_exc_valid);
        chk5 ("C4 cause=1 (no execute perm)", CAUSE_IAF, fetch_exc_cause);
        chk32("C4 mtval = parcel VA", RESET_PC, fetch_exc_tval);
        // M 模式也受 PMP 约束（PMP 对 M 模式同样生效）
        @(negedge aclk) priv = PRIV_M;
        #1;
        chk1("C4 M-mode also blocked by non-X entry", 1'b1, fetch_exc_valid);
        @(negedge aclk) fetch_rsp_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C4b: 同项改为带 X ⇒ 允许（证明 C4 的拒绝来自 X 位，非别的原因）----
        do_reset;
        pmp_set_na4_rwx(0, RESET_PC);
        @(negedge aclk) begin
            priv            = PRIV_U;
            fetch_rsp_data  = 32'h0000_0505;
            fetch_rsp_va    = RESET_PC;
            fetch_rsp_valid = 1'b1;
        end
        #1;
        chk1("C4b X entry allows U-mode fetch", 1'b0, fetch_exc_valid);
        chk1("C4b fetch_valid",                 1'b1, fetch_valid);
        @(negedge aclk) fetch_rsp_valid = 1'b0;
        @(posedge aclk); #1;

        //==================================================================
        // C5: 逐 parcel 检查 —— 32 bit 指令的**第二个 parcel** 故障 ⇒
        //     mtval 必须是 **+2 的虚拟地址**（§5.1 ③「写该 parcel 的 VA」）
        //==================================================================
        // ★ 关键（G=0 ⇒ 4 B 粒度）：NA4 的「项匹配域」是 4 B 对齐的**一个字**。
        //   因此要让「第二个 parcel 故障」真的可观测，必须让该 parcel 落在
        //   **另一个 4 B 字**里 —— 即 32 bit 指令**不从 4 B 边界开始**
        //   （指令起始 VA = RESET_PC+2，第二 parcel 落在 RESET_PC+4）。
        //   这同时是「跨字 32 bit 指令」的真用例。
        do_reset;
        // 项 0: 覆盖 RESET_PC..RESET_PC+3（起始 parcel 所在字），带 X
        pmp_set_na4_rwx(0, RESET_PC);
        // 项 1: 覆盖 RESET_PC+4..RESET_PC+7（第二 parcel 所在字），**无 X**
        pmp_set_na4_rwx(1, P1_VA);
        pmpcfg_x_clear(1);
        // 送入取指字：字对 VA = RESET_PC 时，低半 0x0513（[1:0]==11 ⇒ 32 bit）
        @(negedge aclk) begin
            priv            = PRIV_S;
            fetch_rsp_data  = 32'h0015_0513;
            fetch_rsp_va    = RESET_PC;
            fetch_rsp_valid = 1'b1;
        end
        #1;
        chk1 ("C5 32-bit insn: ilen32=1", 1'b1, fetch_ilen32);
        chk1 ("C5 first parcel has X (no fault yet)", 1'b1, fetch_valid | fetch_exc_valid);
        // 让取指字对齐到 RESET_PC+2（指令起始）—— 使用 cross-word 场景：
        // 交出的指令起始 = RESET_PC+2，第二 parcel = RESET_PC+4。
        @(negedge aclk) begin
            // 指令起始 = RESET_PC+2 ⇒ 起始 parcel 地址 = RESET_PC+2，
            // 其 +2 parcel 落在 RESET_PC+4（项 1 的 4 B 字，无 X）⇒ 必须报 cause 1
            fetch_rsp_data = 32'h0015_0513;
            fetch_rsp_va   = INS_VAB;
        end
        #1;
        chk1 ("C5 second parcel lacks X: exception", 1'b1, fetch_exc_valid);
        chk5 ("C5 cause=1 for second parcel", CAUSE_IAF, fetch_exc_cause);
        chk32("C5 mtval = VA of FAULTY parcel", P1_VA, fetch_exc_tval);
        chk32("C5 exc_pc = instruction start VA", INS_VAB, fetch_exc_pc);
        @(negedge aclk) fetch_rsp_valid = 1'b0;
        @(posedge aclk); #1;

        //---- C5b: 对照 —— 两个 parcel 都有 X ⇒ 无异常，且交出完整 32 bit ----
        do_reset;
        pmp_set_na4_rwx(0, RESET_PC);          // 起始 parcel 允许
        pmp_set_na4_rwx(1, RESET_PC + 32'h4);  // +2 parcel 也允许（带 X）
        @(negedge aclk) begin
            priv            = PRIV_S;
            fetch_rsp_data  = 32'h0015_0513;
            fetch_rsp_va    = RESET_PC;
            fetch_rsp_valid = 1'b1;
        end
        #1;
        chk1 ("C5b both parcels X: no exception", 1'b0, fetch_exc_valid);
        chk1 ("C5b ilen32=1",                     1'b1, fetch_ilen32);
        chk1 ("C5b fetch_valid",                  1'b1, fetch_valid);
        @(negedge aclk) fetch_rsp_valid = 1'b0;
        @(posedge aclk); #1;

        //==================================================================
        // C6: 无 MMU（2A/M1）：sv32_translate_en=0 时 fetch_pc_pa 必须恒等 fetch_pc
        //     并且**不得**因为翻译端口乱给值而改变判定
        //==================================================================
        do_reset;
        @(negedge aclk) begin
            redirect_bru_valid  = 1'b1; redirect_bru_pc = RESET_PC + 32'h40;
            sv32_translate_paddr = 32'hDEAD_BEEF;   // 故意给一个不相干的值
            sv32_translate_en    = 1'b0;
        end
        #1; @(posedge aclk); #1;
        chk32("C6 Bare: pa == va (ignores translate paddr)",
              RESET_PC + 32'h40, fetch_pc_pa);
        chk1 ("C6 Bare: uncached follows PA (still XIP)", 1'b1, uncached);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //==================================================================
        // C7: 翻译接口预留可用（M2 口径）：en=1 时 PA 取翻译结果，
        //     且翻译失败 ⇒ cause=12（instruction page fault）、tval = VA
        //==================================================================
        @(negedge aclk) begin
            redirect_bru_valid   = 1'b1; redirect_bru_pc = DDR_BASE + 32'h8000;
            sv32_translate_en    = 1'b1;
            sv32_translate_done  = 1'b1;
            sv32_translate_fault = 1'b0;
            sv32_translate_paddr = RESET_PC + 32'h100;   // 翻译到 XIP 窗口
        end
        #1; @(posedge aclk); #1;
        chk32("C7 translated PA used", RESET_PC + 32'h100, fetch_pc_pa);
        chk1 ("C7 uncached decided by translated PA", 1'b1, uncached);
        // 翻译失败
        @(negedge aclk) begin
            sv32_translate_fault = 1'b1;
            priv                 = PRIV_S;
            fetch_rsp_data       = 32'h0000_0505;
            fetch_rsp_va         = DDR_BASE + 32'h8000;
            fetch_rsp_valid      = 1'b1;
        end
        #1;
        chk1 ("C7 page fault raises exception",          1'b1, fetch_exc_valid);
        chk5 ("C7 cause=12 (instruction page fault)",
              `RV32GC_EXC_INSN_PAGE_FAULT, fetch_exc_cause);
        chk32("C7 page-fault tval = VA (not PA)", DDR_BASE + 32'h8000, fetch_exc_tval);

        //==================================================================
        // 结束判定
        //==================================================================
        checks_run = checks_run + 1;
        if (checks_run <= 0) begin
            $display("FAIL: 未捕获任何检查项");
            $fatal(1, "TB_FETCH_UNIT FAIL");
        end
        if (checks_fail != 0) begin
            $display("FAIL: %0d 项失败", checks_fail);
            $fatal(1, "TB_FETCH_UNIT FAIL");
        end
        $display("checks_run=%0d checks_fail=%0d", checks_run, checks_fail);
        $display("TB_FETCH_UNIT_UNIT: PASS");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: 仿真超时（TB 未走完用例）");
        $fatal(1, "TB_FETCH_UNIT FAIL");
    end

endmodule
