//==============================================================================
// rtl/back2/rob_wide_mem.v —— ROB 宽字段存储：**4 bank × Simple Dual Port**（1W+1R，同步读）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-5 面积压缩：ROB 宽载荷 BRAM 化，报告 §B4.49/§B4.50/§B4.51）
// 角色  : 替代 `rob.v` 里 `reg [415:0] pl_q [0:127]` 的**大容量存储**部分。
//
// 【为什么是"4 bank × 1W1R"而不是一块大 RAM】（报告 §B4.47.3/§B4.49.1）
//   · 派发每拍最多 **4 条**分配写；4 条 lane 的 ROB 索引**连续** ⇒ `bank = idx[1:0]`
//     恰好把 4 条写分散到 4 个不同 bank ⇒ **每 bank 每拍至多 1 次写，无仲裁**；
//   · 头部窗口预取每拍最多 4 个新项读，索引同样连续 ⇒ 每 bank 至多 1 次读，**无读冲突**；
//   · 单实例 BRAM/XPM 最多 2 写口，4 写/拍**必须** bank 化 ⇒ bank 化后每 bank 天然 1W1R，
//     与"Simple Dual Port"一一对应（这也是选 SDP 而非 TDP 的原因：省一半端口资源）。
//   · 深度 32 × 宽 416 = 13.3 kbit/bank ⇒ 每 bank 1 个 RAMB36（无需级联）。
//
// 【同拍写+读口径】`WRITE_MODE="read_first"`（行为模型同口径）：同址同拍写+读**读出旧值**。
//   本设计满足该前提：窗口预取读的是"已写入 ≥1 拍"的旧项；新分配项**当拍不读**。
//
// 【IP 口径（AGENT.md §4 红线 1/2）】综合分支例化 **Vivado XPM**（`xpm_memory_sdpram`，
//   Vivado 原生参数化存储 IP 宏，无需生成 .xci、无需改 synth.tcl），仿真分支走
//   `ifdef RV32GC_USE_VIVADO_IP` 的**逐拍等价行为模型**（与 front4_mem.v 完全同构）。
//   XPM 是同步读；组合读的存储 IP 不存在（本仓库既有检索结论，见
//   rtl/front4/bpu_local_hist.v 头注）⇒ 提交路径的"组合读"需求由 **FF 头部窗口** 满足
//   （`rob.v` 侧，见报告 §B4.50.2）。
//==============================================================================

`timescale 1ns / 1ps

module rob_wide_mem #(
    parameter integer NW   = 4,             // bank 数 = 每组连续索引的宽度
    parameter integer BW   = 32,            // 每 bank 深度
    parameter integer DW   = 416,           // 字宽（ROB 载荷位宽 RB_W）
    parameter integer AW   = 7,             // 全局索引位宽（log2(NW*BW)）
    parameter integer OW   = 5,             // bank 内偏移位宽（log2(BW)）
    parameter integer CHK  = 0              // 1 = 打开"写读一致性"自检（仿真；默认关）
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- 写口（每 bank 一个；`we[i]` 对应 bank i）----
    input  wire [NW-1:0]           we,
    input  wire [NW*OW-1:0]        woff,     // bank 内偏移（= idx[AW-1:2]）
    input  wire [NW*DW-1:0]        wdata,

    // ---- 读口（每 bank 一个，同步读：`re` 后 **1 拍** 出 `rdata`）----
    input  wire [NW-1:0]           re,
    input  wire [NW*OW-1:0]        roff,
    output wire [NW*DW-1:0]        rdata
);

    // ---------------------------------------------------------------------
    // 组合逻辑风格（AGENT.md §4 红线 3）：bank 索引换算用 assign
    // ---------------------------------------------------------------------
    genvar gb;

`ifdef RV32GC_USE_VIVADO_IP
    //==========================================================================
    // 综合分支：Vivado XPM Simple Dual Port RAM ×NW（1 写 + 1 读，READ_LATENCY=1）
    //   端口/参数名与 Vivado 2023.2 XPM 源码逐字对齐（见 front4_mem.v 同款先例）。
    //==========================================================================
    generate
    for (gb = 0; gb < NW; gb = gb + 1) begin : g_bank
        xpm_memory_sdpram #(
            .MEMORY_SIZE        (BW * DW),
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
            .ADDR_WIDTH_A       (OW),
            .ADDR_WIDTH_B       (OW),
            .WRITE_DATA_WIDTH_A (DW),
            .READ_DATA_WIDTH_B  (DW),
            .BYTE_WRITE_WIDTH_A (DW),
            .READ_RESET_VALUE_B ("0"),
            //   ★ XPM 修正（探针实测 [Synth 8-7136]）：SDP 的写模式参数叫 **`WRITE_MODE_B`**
            //     （端口 A 写 / 端口 B 读；法定值 no_change/read_first/write_first），与行为模型同口径。
            .WRITE_MODE_B       ("read_first"),
            .READ_LATENCY_B     (1),
            .RST_MODE_B         ("SYNC")
        ) u_sdp (
            //   ★ XPM 修正（探针实测 [Synth 8-11365]）：SDP **没有** `rsta/regcea`（端口 A 无复位/无输出寄存器），
            //     **也没有** `injectsbiterrb/injectdbiterrb`（注入只在 A 侧）。端口名单以 XPM 源码为准：
            //       sleep clka ena wea addra dina injectsbiterra injectdbiterra
            //       clkb rstb enb regceb addrb doutb sbiterrb dbiterrb
            .sleep          (1'b0),
            .clka           (clk),
            .ena            (we[gb]),
            .wea            (we[gb]),
            .addra          (woff[gb*OW +: OW]),
            .dina           (wdata[gb*DW +: DW]),
            .injectsbiterra (1'b0),
            .injectdbiterra (1'b0),
            .clkb           (clk),
            .rstb           (~rst_n),
            .enb            (re[gb]),
            .regceb         (1'b1),
            .addrb          (roff[gb*OW +: OW]),
            .doutb          (rdata[gb*DW +: DW]),
            .sbiterrb       (),
            .dbiterrb       ()
        );
    end
    endgenerate

`else
    //==========================================================================
    // 仿真分支：逐拍等价行为模型（同步读 1 拍；同址同拍写+读读旧值 = read_first）
    //==========================================================================
    reg [DW-1:0] mem [0:NW*BW-1];
    reg [DW-1:0] dout_r [0:NW-1];
    integer      bi;

    always @(posedge clk) begin
        for (bi = 0; bi < NW; bi = bi + 1) begin
            if (we[bi]) mem[bi*BW + woff[bi*OW +: OW]] <= wdata[bi*DW +: DW];
            //   与 XPM `RST_MODE_B="SYNC"/READ_RESET_VALUE_B="0"` 逐拍等价：复位期间读输出清零
            if (!rst_n)     dout_r[bi] <= {DW{1'b0}};
            else if (re[bi]) dout_r[bi] <= mem[bi*BW + roff[bi*OW +: OW]];
        end
    end

    generate
    for (gb = 0; gb < NW; gb = gb + 1) begin : g_rd
        assign rdata[gb*DW +: DW] = dout_r[gb];
    end
    endgenerate
`endif

    //==========================================================================
    // 可选自检（CHK=1）：写完下一拍读回必须逐位一致（覆盖 bank 边界与连续索引）
    //   —— 综合默认关（零成本）；单测 `tb_back2_rob_wide_mem` 打开。
    //==========================================================================
`ifdef RV32GC_USE_VIVADO_IP
    //   XPM 分支不做仿真自检（综合不可见）
`else
    integer ck;
    reg [DW-1:0] ck_exp [0:NW*BW-1];
    reg          ck_en  [0:NW*BW-1];
    always @(posedge clk) if (rst_n && CHK) begin
        for (ck = 0; ck < NW*BW; ck = ck + 1) begin
            if (ck_en[ck] && (mem[ck] !== ck_exp[ck]))
                $display("ROB_WIDE_MEM FAIL: addr=%0d got=%h exp=%h", ck, mem[ck], ck_exp[ck]);
        end
    end
    always @(posedge clk) if (CHK) begin
        for (ck = 0; ck < NW; ck = ck + 1)
            if (we[ck]) begin
                ck_exp[ck*BW + woff[ck*OW +: OW]] <= wdata[ck*DW +: DW];
                ck_en [ck*BW + woff[ck*OW +: OW]] <= 1'b1;
            end
    end
`endif

endmodule
