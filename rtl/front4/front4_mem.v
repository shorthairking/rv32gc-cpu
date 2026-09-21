//==============================================================================
// rtl/front4/front4_mem.v —— 2B-1 前端表的存储包装（综合=IP / 仿真=行为模型 双分支）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md §2「存储实现约束」——所有表都用 Vivado 存储 IP，
//         并配 `ifdef 仿真行为模型双分支，保证 iverilog/Verilator 回归不依赖 Vivado。
//         AGENT.md §4 红线 1（禁原语；先检索 IP）、红线 2（IP 例化必须双分支）。
//
// 【IP 检索结论（红线 1 要求的过程与结论，写在这里以免重复检索）】
//   · 需求是"小容量、同步读、读延迟 1 拍、每拍 2 读 + 1 写"的查找表。
//   · Vivado 2023.2 可选：① Block Memory Generator（blk_mem_gen_*，需预生成 .xci，
//     本任务文件范围**禁改** fpga/tcl/create_ip.tcl 与 fpga/ip/ ⇒ 无法本任务落地）；
//     ② **XPM 存储宏（xpm_memory_*）**：Vivado 原生自带的参数化存储 IP 宏，端口与
//     参数由 Vivado 保证映射到 BRAM/Distributed RAM，**不需要 xci 文件**，也不需要
//     任何 FPGA 原语（原语是 RAMB36E1 那一层；XPM 宏内部才用它）。
//   ⇒ 采用 ②：综合分支例化 xpm_memory_tdpram / xpm_memory_sdpram；
//     仿真分支（iverilog/Verilator）走下面逐拍等价的行为模型。
//   · 行为模型与 XPM 的一致性口径：同步读、READ_LATENCY=1（读数据在时钟沿后 1 拍
//     有效）、WRITE_MODE=read_first（同址同拍"写 + 读" ⇒ 读出**旧值**）、
//     en=0 时读口保持（不产生新读）。
//
// 【双分支一致性验证】
//   · iverilog 回归（regress.sh）恒走仿真分支：行为模型是 TB 的唯一依据。
//   · 综合分支的语法/端口正确性由 Vivado xsim（xvlog/xelab，`-L xpm`）单独编译验证；
//     见 rtl/front4/README.md §7 的一键命令与实测输出。
//
// 仅两个模块：front4_mem_2r1w（2 读 1 写；GPHT/LHT/LPHT/选择器）与
//             front4_mem_1r1w（1 读 1 写；BTB 的单路阵列）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/front4/front4_params.vh"

//------------------------------------------------------------------------------
// 2 读 1 写（端口 A：读 + 写；端口 B：只读）
//------------------------------------------------------------------------------
module front4_mem_2r1w #(
    parameter integer DW    = 64,             // 数据位宽
    parameter integer DEPTH = 1024,           // 深度（必须为 2 的幂）
    parameter integer AW    = 10,             // 地址位宽（调用方显式给出；与 DEPTH 一致性自检）
    parameter [DW-1:0] INIT = {DW{1'b0}}      // 上电初值（行为模型；IP 侧由 PORT 初值给出）
) (
    input  wire              clk,
    input  wire              rst_n,
    // ---- A 口（读/写） ----
    input  wire              a_en,
    input  wire              a_we,
    input  wire [AW-1:0]     a_addr,
    input  wire [DW-1:0]     a_din,
    output wire [DW-1:0]     a_dout,
    // ---- B 口（只读） ----
    input  wire              b_en,
    input  wire [AW-1:0]     b_addr,
    output wire [DW-1:0]     b_dout
);
    // 地址位宽一致性自检（fail-closed：不匹配即 $fatal，绝不静默截断）
    // 综合器忽略 initial（仅仿真生效），故这里同时是"包装契约"的可执行文档。
    initial begin
        if ((1 << AW) != DEPTH) begin
            $display("FRONT4_MEM_2R1W FAIL: AW=%0d 与 DEPTH=%0d 不匹配", AW, DEPTH);
            $fatal(1, "FRONT4_MEM_2R1W AW/DEPTH MISMATCH");
        end
    end

`ifdef RV32GC_USE_VIVADO_IP
    //==========================================================================
    // 综合分支：Vivado XPM True Dual Port RAM（A 口读/写，B 口只读）
    //   READ_LATENCY_A/B=1 ⇒ 读数据在时钟沿后 1 拍有效（与行为模型一致）
    //   WRITE_MODE_A="read_first" ⇒ 同址同拍写+读读出旧值（与行为模型一致）
    //==========================================================================
    wire [DW-1:0] a_dout_i;
    wire [DW-1:0] b_dout_i;

    //   ★ 端口/参数名与 Vivado 2023.2 的 XPM 源码逐字对齐（
    //     $VIVADO/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv；xelab 会把名字写错直接判错）。
    xpm_memory_tdpram #(
        .MEMORY_SIZE        (DEPTH * DW),
        .MEMORY_PRIMITIVE   ("block"),
        .CLOCKING_MODE      ("common_clock"),
        .ECC_MODE           ("no_ecc"),
        .MEMORY_INIT_FILE   ("none"),
        .MEMORY_INIT_PARAM  ("0"),
        .USE_MEM_INIT       (0),
        .WAKEUP_TIME        ("disable_sleep"),
        .AUTO_SLEEP_TIME    (0),
        .MESSAGE_CONTROL    (0),
        .SIM_ASSERT_CHK     (0),
        .MEMORY_OPTIMIZATION("true"),
        .CASCADE_HEIGHT     (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .ADDR_WIDTH_A       (AW),
        .ADDR_WIDTH_B       (AW),
        .READ_DATA_WIDTH_A  (DW),
        .READ_DATA_WIDTH_B  (DW),
        .WRITE_DATA_WIDTH_A (DW),
        .BYTE_WRITE_WIDTH_A (DW),
        .READ_RESET_VALUE_A ("0"),
        .READ_RESET_VALUE_B ("0"),
        .WRITE_MODE_A       ("read_first"),
        .WRITE_MODE_B       ("read_first"),
        .READ_LATENCY_A     (1),
        .READ_LATENCY_B     (1),
        .RST_MODE_A         ("SYNC"),
        .RST_MODE_B         ("SYNC")
    ) u_xpm (
        .sleep          (1'b0),
        .clka           (clk),
        .rsta           (~rst_n),
        .ena            (a_en),
        .regcea         (1'b1),
        .wea            (a_we),
        .addra          (a_addr),
        .dina           (a_din),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .douta          (a_dout_i),
        .sbiterra       (),
        .dbiterra       (),
        .clkb           (clk),
        .rstb           (~rst_n),
        .enb            (b_en),
        .regceb         (1'b1),
        .web            (1'b0),
        .addrb          (b_addr),
        .dinb           ({DW{1'b0}}),
        .injectsbiterrb (1'b0),
        .injectdbiterrb (1'b0),
        .doutb          (b_dout_i),
        .sbiterrb       (),
        .dbiterrb       ()
    );

    assign a_dout = a_dout_i;
    assign b_dout = b_dout_i;

`else
    //==========================================================================
    // 仿真分支（默认）：逐拍等价行为模型
    //==========================================================================
    reg [DW-1:0] mem [0:DEPTH-1];
    reg [DW-1:0] a_dout_r;
    reg [DW-1:0] b_dout_r;

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = INIT;
        a_dout_r = {DW{1'b0}};
        b_dout_r = {DW{1'b0}};
    end

    // A 口：写优先（同址同拍写+读 ⇒ 读出旧值，即 read_first 等价语义）
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we)            mem[a_addr] <= a_din;
            else if (a_addr < DEPTH) a_dout_r <= mem[a_addr];
        end
    end

    // B 口：只读
    always @(posedge clk) begin
        if (b_en && (b_addr < DEPTH)) b_dout_r <= mem[b_addr];
    end

    assign a_dout = a_dout_r;
    assign b_dout = b_dout_r;
`endif

endmodule

//------------------------------------------------------------------------------
// 1 读 1 写（端口 A：只写；端口 B：只读）——BTB 每路阵列
//------------------------------------------------------------------------------
module front4_mem_1r1w #(
    parameter integer DW    = 64,
    parameter integer DEPTH = 1024,
    parameter integer AW    = 10,
    parameter [DW-1:0] INIT = {DW{1'b0}}
) (
    input  wire              clk,
    input  wire              rst_n,
    // ---- A 口（只写） ----
    input  wire              a_en,
    input  wire [AW-1:0]     a_addr,
    input  wire [DW-1:0]     a_din,
    // ---- B 口（只读） ----
    input  wire              b_en,
    input  wire [AW-1:0]     b_addr,
    output wire [DW-1:0]     b_dout
);
    initial begin
        if ((1 << AW) != DEPTH) begin
            $display("FRONT4_MEM_1R1W FAIL: AW=%0d 与 DEPTH=%0d 不匹配", AW, DEPTH);
            $fatal(1, "FRONT4_MEM_1R1W AW/DEPTH MISMATCH");
        end
    end

`ifdef RV32GC_USE_VIVADO_IP
    //==========================================================================
    // 综合分支：Vivado XPM Simple Dual Port RAM（A 口写，B 口读，读延迟 1 拍）
    //==========================================================================
    wire [DW-1:0] b_dout_i;

    //   ★ 端口/参数名与 Vivado 2023.2 的 XPM 源码逐字对齐：
    //     SDPRAM **没有** rsta/regcea/READ_LATENCY_A/WRITE_MODE_A（A 口是纯写口，
    //     写模式固定 read_first），只有 B 口有读延迟寄存器。
    xpm_memory_sdpram #(
        .MEMORY_SIZE        (DEPTH * DW),
        .MEMORY_PRIMITIVE   ("block"),
        .CLOCKING_MODE      ("common_clock"),
        .ECC_MODE           ("no_ecc"),
        .MEMORY_INIT_FILE   ("none"),
        .MEMORY_INIT_PARAM  ("0"),
        .USE_MEM_INIT       (0),
        .WAKEUP_TIME        ("disable_sleep"),
        .AUTO_SLEEP_TIME    (0),
        .MESSAGE_CONTROL    (0),
        .SIM_ASSERT_CHK     (0),
        .MEMORY_OPTIMIZATION("true"),
        .CASCADE_HEIGHT     (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .ADDR_WIDTH_A       (AW),
        .ADDR_WIDTH_B       (AW),
        .WRITE_DATA_WIDTH_A (DW),
        .BYTE_WRITE_WIDTH_A (DW),
        .READ_DATA_WIDTH_B  (DW),
        .READ_RESET_VALUE_B ("0"),
        .READ_LATENCY_B     (1),
        .RST_MODE_A         ("SYNC"),
        .RST_MODE_B         ("SYNC")
    ) u_xpm (
        .sleep          (1'b0),
        .clka           (clk),
        .ena            (a_en),
        .wea            (a_en),
        .addra          (a_addr),
        .dina           (a_din),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .clkb           (clk),
        .rstb           (~rst_n),
        .enb            (b_en),
        .regceb         (1'b1),
        .addrb          (b_addr),
        .doutb          (b_dout_i),
        .sbiterrb       (),
        .dbiterrb       ()
    );

    assign b_dout = b_dout_i;

`else
    //==========================================================================
    // 仿真分支（默认）：逐拍等价行为模型（同址同拍写+读 ⇒ 读出旧值）
    //==========================================================================
    reg [DW-1:0] mem [0:DEPTH-1];
    reg [DW-1:0] b_dout_r;

    integer j;
    initial begin
        for (j = 0; j < DEPTH; j = j + 1) mem[j] = INIT;
        b_dout_r = {DW{1'b0}};
    end

    always @(posedge clk) begin
        if (a_en && (a_addr < DEPTH)) mem[a_addr] <= a_din;
    end

    always @(posedge clk) begin
        if (b_en && (b_addr < DEPTH)) b_dout_r <= mem[b_addr];
    end

    assign b_dout = b_dout_r;
`endif

endmodule
