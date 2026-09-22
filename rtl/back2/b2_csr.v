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
    input  wire [31:0] wdata
);

    //--------------------------------------------------------------------------
    // 寄存器
    //--------------------------------------------------------------------------
    reg [31:0] mscratch_q;
    reg [31:0] mepc_q;
    reg [31:0] mcause_q;
    reg [31:0] mtvec_q;
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
    localparam [11:0] CSR_MVENDORID = 12'hF11;
    localparam [11:0] CSR_MARCHID   = 12'hF12;
    localparam [11:0] CSR_MIMPID    = 12'hF13;
    localparam [11:0] CSR_MHARTID   = 12'hF14;

    //--------------------------------------------------------------------------
    // 读口（组合）
    //--------------------------------------------------------------------------
    assign frm_o    = fcsr_q[7:5];
    assign fflags_o = fcsr_q[4:0];

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
            mtvec_q    <= 32'h0;
            mstatus_q  <= 32'h0000_1800;     // MPP = M（复位进 M 模式）
            fcsr_q     <= 32'h0;
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
                default: ;
            endcase
        end
    end

endmodule
