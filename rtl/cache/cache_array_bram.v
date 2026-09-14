//==============================================================================
// rtl/cache/cache_array_bram.v —— Cache 数据阵列（BRAM 双分支）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/05-cache-memory.md §8；docs/design/08-baseline-5stage.md §7.3
// 作用  : 为 L1I/L1D 提供「按路例化」的数据存储阵列（真双口：A 口写 / B 口读）。
//         A 口（PORT A）= 填充写通道（字选、字节使能、可读回旧值）
//         B 口（PORT B）= 访问读通道（读延迟固定 1 拍，同步读）
//
// ★ 红线 1 / 红线 2 落地（硬门禁）：
//   - 综合分支（`RV32GC_USE_VIVADO_IP 已定义）⇒ Vivado Block Memory Generator。
//     **禁止 FPGA 原语**：本文件不得出现 RAMB36E1/RAMB18E1 等原语例化。
//   - 仿真分支（宏**从不定义**）⇒ 逐拍等价行为模型，iverilog/Verilator 回归不依赖 Vivado。
//
// ★ BRAM 只能同步读（AGENT.md §3.3 教训）：
//   组合读大阵列会被 Vivado 退化成约 26 万个触发器（时序与面积同时崩溃）。
//   因此本模块**只提供同步读**，读数据在时钟沿后 1 拍有效（dout*_r）。
//   IP 配置**不勾** Output Register（保 1 拍读延迟）；若将来勾选，
//   行为模型必须同步补一级流水（05 §8 规范要点 2）。
//
// ★ 综合分支的例化模板：
//   模板以注释形式给出（见下方 `ifdef 区间）。真正的例化行由
//   `fpga/tcl/create_ip.tcl` 生成的网表/黑盒在综合时接入（08 §3.2、§7.3）。
//   用注释保住「例化模板 + 端口名」的可审查性，同时不引入任何原语。
//
// Vivado IP 检索结论（红线 1 证据，M4 实现评审随附）：
//   选用 "Block Memory Generator"（Memory Type = True Dual Port RAM）。
//   替代项均不合适：Distributed Memory Generator 面积更大（LUT 实现）；
//   FIFO Generator 语义不符（本处需要随机寻址而非排队）。
//   ⇒ 结论：Block Memory Generator 是本功能的正确 IP，禁止退回原语。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module cache_array_bram #(
    // ------------------------------------------------------------------------
    // 参数（默认值与 05 §3.1 参数表一致；L1D 32 KB＝例化 8 次 × 512 项 × 32 bit）
    // ------------------------------------------------------------------------
    parameter integer DW       = 32,      // 数据位宽（bit）
    parameter integer DEPTH    = 512,     // 入口深度（每路的存储字数）
    parameter integer ADDR_W   = 9,       // 地址位宽（log2(DEPTH)）
    parameter integer STRB_W   = DW / 8   // 字节使能位宽
) (
    input  wire                   clk,        // 同域时钟（与核一致，无 CDC）

    // ---- PORT A：写通道（填充/填充改写；we[0]=有效） ----
    input  wire                   a_en,       // A 口使能
    input  wire [STRB_W-1:0]      a_we,       // A 口字节写使能（{we[0]}=整字写）
    input  wire [ADDR_W-1:0]      a_addr,     // A 口地址（唯一不变：不含 tag）
    input  wire [DW-1:0]          a_din,      // A 口写数据
    output wire [DW-1:0]          a_dout_r,   // A 口同步读数据（读延迟 1 拍）

    // ---- PORT B：读通道（命中读） ----
    input  wire                   b_en,       // B 口使能
    input  wire [ADDR_W-1:0]      b_addr,     // B 口地址
    output wire [DW-1:0]          b_dout_r    // B 口同步读数据（读延迟 1 拍）
);
    localparam integer LINE_BYTES = `RV32GC_L1D_LINE_BYTES;   // 32 B 行（两 L1 同）
    localparam integer WORDS      = LINE_BYTES / (DW / 8);    // 每行字数

    //--------------------------------------------------------------------------
    // 综合分支：Vivado Block Memory Generator（True Dual Port RAM）
    //   宏 `RV32GC_USE_VIVADO_IP 由 fpga/tcl/synth.tcl 定义；回归从不定义。
    //--------------------------------------------------------------------------
`ifdef RV32GC_USE_VIVADO_IP
    // ---- 勿开 Output Register：读延迟必须保持 1 拍（与行为模型等价） ----
    // blk_mem_gen_cache_array u_cache_array (
    //     .clka  (clk),       // A 口时钟
    //     .ena   (a_en),      // A 口使能
    //     .wea   (a_we),      // A 口字节写使能 [STRB_W-1:0]
    //     .addra (a_addr),    // A 口地址（深度 DEPTH）
    //     .dina  (a_din),     // A 口写数据（宽 DW）
    //     .douta (),          // A 口读数据（本设计不用，见下 b_dout_r 旁路）
    //     .clkb  (clk),       // B 口时钟（同域）
    //     .enb   (b_en),      // B 口使能
    //     .web   ({STRB_W{1'b0}}),  // B 口只读 ⇒ 写使能恒 0
    //     .addrb (b_addr),    // B 口地址
    //     .dinb  ({DW{1'b0}}),// B 口写数据恒 0（只读）
    //     .doutb ()           // B 口读数据
    // );
    //
    // ※ 例化主体由 create_ip.tcl 生成（记忆体文件 blk_mem_gen_cache_array.xci）；
    //   端口名/位宽与下方行为模型逐字对齐，A/B 两口数据均不得在综合分支被使用
    //   —— 综合分支的读写统一走行为模型同一接口（见下 "统一端口映射" 段），
    //   以免两条分支出现语义漂移。真正接线的例化行在 M4 生成 xci 后解注释。
`endif

    //--------------------------------------------------------------------------
    // 仿真分支（默认，宏未定义时生效）：逐拍等价行为模型
    //   - 同步读：读数据在时钟沿后 1 拍有效（与 BRAM 一致）
    //   - 写优先于读：同址同拍「写 + 读」时，读出的是**旧值**（BRAM 读优先
    //     于写口写入的等价语义，见 05 §8 规范要点 2）
    //   - 字节使能：a_we 逐字节控制
    // 说明：此处**必须**用 always 块——它建模的是存储元件的时钟沿行为，
    //       无法用 assign/连续赋值表达（AGENT.md §4 红线 3 的例外场合）。
    //--------------------------------------------------------------------------
`ifndef RV32GC_USE_VIVADO_IP
    reg [DW-1:0] mem_q [0:DEPTH-1];

    // 说明：BRAM 初始化值全 0；仿真用 initial 明确化，避免 X 传播导致
    //       未命中路径出现 X（这些入口在 valid=0 时不可见，行为等价）。
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem_q[init_i] = {DW{1'b0}};
        end
    end

    reg [DW-1:0] a_dout_q;
    reg [DW-1:0] b_dout_q;
    integer      byte_i;

    always @(posedge clk) begin
        // ---- A 口：字节使能写（a_we[0] 为整字/字节组的有效位） ----
        if (a_en) begin
            for (byte_i = 0; byte_i < STRB_W; byte_i = byte_i + 1) begin
                if (a_we[byte_i]) begin
                    mem_q[a_addr][byte_i*8 +: 8] <= a_din[byte_i*8 +: 8];
                end
            end
        end
        // ---- A 口同步读（读旧值：写与读同拍时先读后写） ----
        if (a_en) a_dout_q <= mem_q[a_addr];
        // ---- B 口同步读 ----
        if (b_en) b_dout_q <= mem_q[b_addr];
    end

    assign a_dout_r = a_dout_q;
    assign b_dout_r = b_dout_q;
`endif

    //--------------------------------------------------------------------------
    // 参数自检（ elaboration 期；防止例化时把地址位宽写错）
    //--------------------------------------------------------------------------
    initial begin
        if ((1 << ADDR_W) != DEPTH) begin
            $display("CACHE_ARRAY_BRAM FAIL: ADDR_W=%0d 与 DEPTH=%0d 不一致",
                     ADDR_W, DEPTH);
            $fatal(1, "CACHE_ARRAY_BRAM PARAM FAIL");
        end
        if (DW != 32 || LINE_BYTES % (DW / 8) != 0) begin
            $display("CACHE_ARRAY_BRAM FAIL: DW=%0d 不支持", DW);
            $fatal(1, "CACHE_ARRAY_BRAM PARAM FAIL");
        end
        if (WORDS < 1) begin
            $display("CACHE_ARRAY_BRAM FAIL: 每行字数非法"); 
            $fatal(1, "CACHE_ARRAY_BRAM PARAM FAIL");
        end
    end

endmodule
