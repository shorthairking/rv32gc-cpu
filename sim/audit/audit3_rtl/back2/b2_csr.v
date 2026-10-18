//==============================================================================
// rtl/back2/b2_csr.v —— 2B-2 里程碑的最小 CSR 文件（乱序后端提交点写、执行点读）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §4.1（CSR 只在 ALU0 执行，避免两处副作用）、
//         §8.3（"CSR 的副作用顺序由提交序保证（CSR 只在 W1 提交点更新）"）。
//
// 【本里程碑边界（交付说明同步登记）】
//   · 只实现**整数寄存器类** CSR：mscratch / mepc / mcause / mtvec / mstatus（最小）
//     + 浮点 fflags / frm / fcsr（fcsr 的 frm/fflags 由 FPU 结果与 csr 指令共同驱动）
//     + 只读 ID 类（mvendorid/marchid/mimpid/mhartid = 0）。
//   · 其余地址一律判**非法指令**（cause 2）—— 由 `csr_ill_o` 在派发期标记，提交点精确抛。
//   · **不含** trap/委托/中断/计数器（mcycle/minstret 等）落地：它们属 2B-4/2C（完整
//     特权栈）。本里程碑不能在锁步程序里使用这些 CSR（程序侧显式约束）。
//   · 读口是**组合**的：CSR 指令只在"到达 ROB 头"时才被允许发射（backend_top 强制），
//     因此读到的值一定是所有更老 CSR 写**已提交**后的值；写口只在提交时生效
//     （csrrw 语义：读到旧值、提交时写新值）——两者的组合即 §8.3 的顺序口径。
//
// 风格  : 读口 `assign` + 条件表达式；always 块只用于 CSR 寄存器（时序元件）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/back2/back2_params.vh"

module b2_csr (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 读口（组合；执行拍）----
    input  wire [11:0] raddr,
    output wire [31:0] rdata,
    output wire        raddr_ill,
    output wire [2:0]  frm_o,          // 供 FPU 解析 DYN
    output wire [4:0]  fflags_o,

    // ---- 写口（提交点）----
    input  wire        we,
    input  wire [11:0] waddr,
    input  wire [31:0] wdata,

    //--------------------------------------------------------------------------
    // ★★ 2B-4 第 4a 段：**陷阱硬件写路径 + 中断输入**（本里程碑新增）
    //--------------------------------------------------------------------------
    //   进入（`trp_enter_v` 一拍）：mepc←trap_pc、mcause←cause、mtval←tval、
    //                              mstatus：MPIE←MIE、MIE←0、MPP←11（本段恒 M 模式）
    //   退出（`trp_exit_v` 一拍）  ：mstatus：MIE←MPIE、MPIE←1、MPP←00（mret 语义）
    //   · 优先级：硬件路径 > 软件 csrw（同一拍不可能同时发生——前者由提交/陷阱拍驱动，
    //     后者由 CSR 指令在 ROB 头提交驱动；给硬件更高优先级是"陷阱不会被 csrw 挤掉"的
    //     保守口径，与 2A `csr_file` 的 trap > we 一致）。
    //   · `mtip_i`：CLINT 的 MTIP（mip.MTIP = bit7），纯组合进 mip 只读视图。
    input  wire        trp_enter_v,
    input  wire [31:0] trp_enter_pc,
    input  wire [31:0] trp_enter_cause,
    input  wire [31:0] trp_enter_tval,
    input  wire        trp_exit_v,
    input  wire        mtip_i,
    output wire [31:0] mtvec_o,        // 顶层 trap FSM 取重定向目标（组合读）
    output wire [31:0] mepc_o,
    output wire [31:0] mstatus_o,
    output wire [31:0] mie_o
);

    //--------------------------------------------------------------------------
    // 寄存器
    //--------------------------------------------------------------------------
    reg [31:0] mscratch_q;
    reg [31:0] mepc_q;
    reg [31:0] mcause_q;
    reg [31:0] mtvec_q;
    reg [31:0] mtval_q;
    reg [31:0] mie_q;                  // 只保留 MSIE(3)/MTIE(7)/MEIE(11) 三位
    reg [31:0] mstatus_q;
    reg [31:0] fcsr_q;                 // {24'b0, frm[7:5], fflags[4:0]}

    //--------------------------------------------------------------------------
    // 地址常量（见 rv32_defs.vh 的 CSR 段；此处只列本模块实现者）
    //--------------------------------------------------------------------------
    localparam [11:0] CSR_FFLAGS  = 12'h001;
    localparam [11:0] CSR_FRM     = 12'h002;
    localparam [11:0] CSR_FCSR    = 12'h003;
    localparam [11:0] CSR_MSTATUS = 12'h300;
    localparam [11:0] CSR_MTVEC   = 12'h305;
    localparam [11:0] CSR_MSCRATCH= 12'h340;
    localparam [11:0] CSR_MEPC    = 12'h341;
    localparam [11:0] CSR_MCAUSE  = 12'h342;
    localparam [11:0] CSR_MTVAL   = 12'h343;
    localparam [11:0] CSR_MIE     = 12'h304;
    localparam [11:0] CSR_MIP     = 12'h344;
    localparam [11:0] CSR_MVENDORID = 12'hF11;
    localparam [11:0] CSR_MARCHID   = 12'hF12;
    localparam [11:0] CSR_MIMPID    = 12'hF13;
    localparam [11:0] CSR_MHARTID   = 12'hF14;

    //--------------------------------------------------------------------------
    // 读口（组合）
    //--------------------------------------------------------------------------
    assign frm_o    = fcsr_q[7:5];
    assign fflags_o = fcsr_q[4:0];
    assign mtvec_o  = mtvec_q;
    assign mepc_o   = mepc_q;
    assign mstatus_o= mstatus_q;
    assign mie_o    = mie_q;

    reg [31:0] rd_mux;
    reg        rd_ill;
    always @(*) begin
        rd_ill = 1'b0;
        case (raddr)
            CSR_FFLAGS:    rd_mux = {27'h0, fcsr_q[4:0]};
            CSR_FRM:       rd_mux = {29'h0, fcsr_q[7:5]};
            CSR_FCSR:      rd_mux = {24'h0, fcsr_q[7:0]};
            CSR_MSTATUS:   rd_mux = mstatus_q;
            CSR_MTVEC:     rd_mux = mtvec_q;
            CSR_MSCRATCH:  rd_mux = mscratch_q;
            CSR_MEPC:      rd_mux = mepc_q;
            CSR_MCAUSE:    rd_mux = mcause_q;
            CSR_MTVAL:     rd_mux = mtval_q;
            CSR_MIE:       rd_mux = mie_q;
            //   mip 是**只读**视图：本段只驱动 MTIP（bit7），其余位恒 0
            //   （MSIP/MEIP 由 CLINT/PLIC 驱动，见报告 §B4.4 的占位登记）
            CSR_MIP:       rd_mux = {24'b0, mtip_i, 7'b0};
            CSR_MVENDORID: rd_mux = 32'h0;
            CSR_MARCHID:   rd_mux = 32'h0;
            CSR_MIMPID:    rd_mux = 32'h0;
            CSR_MHARTID:   rd_mux = 32'h0;
            default: begin rd_mux = 32'h0; rd_ill = 1'b1; end
        endcase
    end
    assign rdata = rd_mux;
    assign raddr_ill = rd_ill;

    //--------------------------------------------------------------------------
    // 写口（提交点；地址非法 ⇒ 上层已在派发期标记非法指令，不会走到这里）
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mscratch_q <= 32'h0;
            mepc_q     <= 32'h0;
            mcause_q   <= 32'h0;
            mtval_q    <= 32'h0;
            mie_q      <= 32'h0;
            mtvec_q    <= 32'h0;
            mstatus_q  <= 32'h0000_1800;     // MPP = M（复位进 M 模式）
            fcsr_q     <= 32'h0;
        end else if (trp_enter_v) begin
            //   ★ 陷阱进入：**不**动 mtvec（软件写）；mepc 低位对齐 IALIGN=16
            mepc_q            <= {trp_enter_pc[31:1], 1'b0};
            mcause_q          <= trp_enter_cause;
            mtval_q           <= trp_enter_tval;
            mstatus_q[7]      <= mstatus_q[3];      // MPIE ← MIE
            mstatus_q[3]      <= 1'b0;              // MIE  ← 0
            mstatus_q[12:11]  <= 2'b11;             // MPP  ← M（本段恒 M）
        end else if (trp_exit_v) begin
            //   ★ mret 退出：MIE←MPIE、MPIE←1、MPP←00（U；本段无 U 栈，按 ISA 语义）
            mstatus_q[3]      <= mstatus_q[7];
            mstatus_q[7]      <= 1'b1;
            mstatus_q[12:11]  <= 2'b00;
        end else if (we) begin
            case (waddr)
                CSR_FFLAGS:   fcsr_q[4:0]  <= wdata[4:0];
                CSR_FRM:      fcsr_q[7:5]  <= wdata[7:5];
                CSR_FCSR:     fcsr_q[7:0]  <= wdata[7:0];
                CSR_MSTATUS:  mstatus_q    <= wdata;
                CSR_MTVEC:    mtvec_q      <= wdata;
                CSR_MSCRATCH: mscratch_q   <= wdata;
                CSR_MEPC:     mepc_q       <= {wdata[31:1], 1'b0};   // IALIGN=16：最低位恒 0
                CSR_MCAUSE:   mcause_q     <= wdata;
                CSR_MTVAL:    mtval_q      <= wdata;
                CSR_MIE:      mie_q        <= wdata & 32'h0000_0888;   // MSIE|MTIE|MEIE
                //   CSR_MIP：MTIP 只读（软件写 mip 本段无副作用，按 WARL 吞写）
                default: ;
            endcase
        end
    end

endmodule
