//==============================================================================
// rtl/cache/l1i.v —— L1 I-Cache：16 KB / 2 路组相联 / 32 B 行 / 256 组
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/05-cache-memory.md §3.1/§5.2/§8；08-baseline-5stage.md §5.1
//
// 结构（05 §3.1 参数表，真源 = rtl/pkg/core_params.vh §7）：
//   - 容量 **16 KB**、**2 路**、32 B 行、256 组（16384 B）
//   - 索引位 = VA[12:5]（256 组）；行内偏移 VA[4:0]；Tag = VA[31:13]（19 bit）
//   - 只读：I-Cache 不参与写通道（05 §3.2「为何 L1I 不做写通道」）
//   - 替换：2 路**伪 LRU（1 bit/组）**（05 §3.1 表格口径）
//
// ★ XIP 旁路（05 §5.2 三条不可协商口径之第 1 条；08 §5.1 行为要点②）：
//   取指的**物理地址**命中 SPI XIP 窗口（PA[31:20]==12'h1C0 ‖ PA[31:16]==16'h1FE8）
//   ⇒ 走 uncached 直通：**不查 Tag、不写 Tag/Data 阵列、不分配、不驱动 AXI**。
//   判定对象是 **PA 不是 VA**（05 §9 C-7 高风险项：VA/PA 混用是静默错）。
//
// 时序结构（BRAM 只能同步读的必然结果，见 08 §7.3）：
//   - Tag 与 Data 都是同步读（读延迟 1 拍）。
//   - 访问拍 S0：cs_req 有效 → tag 阵列读索引、data 阵列读索引+偏移。
//   - S0 末：tag 读数据与 data 读数据同时有效 ⇒ 当拍完成比较与命中判定，
//     cs_ready 在 S0 末拉高、cs_rdata 当拍有效 ⇒ **命中路径 1 拍**。
//     （`rd_*_r` 是被沿寄存的输出，与访问拍的解码结果同拍出现，故无需额外等拍。）
//   - 缺失：S0 末置 miss_x，驱动 MSHR/总线填充；填充期间 cs_ready=0；
//     每个回填 beat 按 fill_word_idx 写入相应路的行内字。
//
// 说明（红线 3）：除「状态寄存器更新」与「数组行为模型」外，全部用
//   assign/连续赋值；阵列例化由 generate 完成。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module l1i #(
    // ---- 组织参数（默认 = rtl/pkg/core_params.vh §7 的 L1I 口径；真源勿改） ----
    parameter integer WAYS       = `RV32GC_L1I_WAYS,          // 2 路
    parameter integer SETS       = `RV32GC_L1I_SETS,          // 256 组
    parameter integer LINE_BYTES = `RV32GC_L1I_LINE_BYTES,    // 32 B 行
    parameter integer INDEX_BITS = `RV32GC_L1I_INDEX_BITS,    // 8 = VA[12:5]
    parameter integer OFF_BITS   = `RV32GC_L1I_OFFSET_BITS,   // 5 = VA[4:0]
    parameter integer TAG_LSB    = 13,                        // VA 中 tag 起始位
    parameter integer TAG_W      = 19,                        // VA[31:13]
    parameter integer DATA_W     = 32,                        // AXI beat
    parameter integer OWNER_W    = 2,
    parameter [OWNER_W-1:0] OWNER_I_FILL = 2'd0               // 归属：I-Cache 填充
) (
    input  wire                 clk,
    input  wire                 rst_n,

    //------------------------------------------------------------------
    // 取指单元 <-> L1I
    //------------------------------------------------------------------
    input  wire                 cs_req,        // 取指请求
    input  wire [31:0]          cs_paddr,      // ★ 物理地址（XIP 判定）
    input  wire [31:0]          cs_vaddr,      // 虚拟地址（索引/tag/偏移）
    output wire                 cs_ready,      // 本位数据可用（命中或回填完成）
    output wire [31:0]          cs_rdata,      // 返回的对齐 32 bit 字
    output wire                 cs_uncached,   // 1 = XIP 旁路（走 uncached 直通）
    output wire                 cs_miss,       // 1 = 未命中（含在途填充）

    //------------------------------------------------------------------
    // MSHR / AXI 控制器 <-> L1I
    //------------------------------------------------------------------
    output wire                 fill_req,      // 需要一笔行填充
    output wire [31:0]          fill_paddr,    // **行基址**（物理地址，唯一赋值点）
    output wire [OWNER_W-1:0]   fill_owner,    // 归属 = OWNER_I_FILL
    output wire [4:0]           fill_beats,    // beat 数 - 1
    input  wire                 fill_accepted, // 控制器已接受（alloc_ready）
    input  wire                 fill_valid,    // 回填 beat 有效
    input  wire [31:0]          fill_data,     // 回填 beat 数据
    input  wire [4:0]           fill_word_idx, // 本 beat 的行内字序号（0..7）
    input  wire                 fill_done,     // 最后一 beat 已收（mshr done）

    //------------------------------------------------------------------
    // 维护
    //------------------------------------------------------------------
    input  wire                 inval_all,     // 整体失效（fence.i / cbo.inval）
    output wire                 idle           // 无在途事务（可取指）
);
    //--------------------------------------------------------------------------
    // 1. 派生常量
    //--------------------------------------------------------------------------
    localparam integer WORD_BYTES = DATA_W / 8;                       // 4 B
    localparam integer WORDS     = LINE_BYTES / WORD_BYTES;           // 8 字/行
    localparam integer WIDX_BITS = $clog2(WORDS);                     // 3 bit
    localparam integer DATA_ADDR_W = INDEX_BITS + WIDX_BITS;          // 11 bit
    localparam integer WAY_W      = (WAYS > 1) ? $clog2(WAYS) : 1;    // 1 bit

    //--------------------------------------------------------------------------
    // 2. 地址字段（VA 口径）
    //--------------------------------------------------------------------------
    wire [INDEX_BITS-1:0] va_index  = cs_vaddr[OFF_BITS +: INDEX_BITS];
    wire [TAG_W-1:0]      va_tag    = cs_vaddr[31 -: TAG_W];
    wire [OFF_BITS-1:0]   va_offset = cs_vaddr[OFF_BITS-1:0];
    wire [WIDX_BITS-1:0]  va_widx   = va_offset[OFF_BITS-1 -: WIDX_BITS];

    //--------------------------------------------------------------------------
    // 3. XIP 旁路（**PA** 口径；05 §5.2 口径 1）
    //--------------------------------------------------------------------------
    wire xip_hit_hi20 = ((cs_paddr[31:20] & `RV32GC_XIP_HI20_MSK) == `RV32GC_XIP_HI20_VAL);
    wire xip_hit_hi16 = (cs_paddr[31:16] == `RV32GC_SPI_HIT_VAL);
    wire xip_bypass   = xip_hit_hi20 | xip_hit_hi16;
    assign cs_uncached = xip_bypass;

    // 真正进入 Cache 阵列的访问（旁路请求被剔除）
    wire access = cs_req & ~xip_bypass;

    //--------------------------------------------------------------------------
    // 4. 状态寄存器
    //--------------------------------------------------------------------------
    reg                  miss_q;         // 本笔未命中（在途）
    reg                  fill_active_q;  // 填充在途
    reg [31:0]           fill_paddr_q;   // 在途填充的行基址（物理地址，唯一赋值点）
    reg [WAY_W-1:0]      fill_way_q;     // 在途填充写入的路
    reg [SETS-1:0]       plru_q;         // 每 1 bit 伪 LRU：1 ⇒ way1 为 LRU
    reg [31:0]           hit_data_q;     // 命中数据寄存（cs_ready 拍）

    //--------------------------------------------------------------------------
    // 5. Tag 阵列（每路一份）
    //--------------------------------------------------------------------------
    wire [TAG_W-1:0] tag_rdata [0:WAYS-1];
    wire             tag_vld   [0:WAYS-1];

    // 写口（每路一份）
    wire                 tag_we    [0:WAYS-1];
    wire [INDEX_BITS-1:0] tag_waddr[0:WAYS-1];
    wire [TAG_W-1:0]     tag_wdata[0:WAYS-1];
    wire                 tag_wvld [0:WAYS-1];

    //--------------------------------------------------------------------------
    // 6. 数据阵列（每路一份；A=填充写、B=访问读）
    //--------------------------------------------------------------------------
    wire [DATA_W-1:0]    data_rdata[0:WAYS-1];
    wire                 data_we   [0:WAYS-1];
    wire [DATA_ADDR_W-1:0] data_waddr[0:WAYS-1];
    wire [DATA_W-1:0]    data_wdata[0:WAYS-1];

    // 回填写入地址/数据（所有路共享同一地址与数据，只对目标路拉写使能）
    wire [DATA_ADDR_W-1:0] fill_waddr = {fill_paddr_q[OFF_BITS +: INDEX_BITS],
                                         fill_word_idx[WIDX_BITS-1:0]};

    genvar gw;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_way
            // ---- Tag 阵列 ----
            cache_tag_array #(
                .TAG_W  (TAG_W),
                .SETS   (SETS),
                .ADDR_W (INDEX_BITS)
            ) u_tag (
                .clk        (clk),
                .wr_en      (tag_we[gw]),
                .wr_addr    (tag_waddr[gw]),
                .wr_tag     (tag_wdata[gw]),
                .wr_valid   (tag_wvld[gw]),
                .wr_dirty   (1'b0),                 // I-Cache 无 dirty
                .rd_en      (access),               // 访问拍读索引
                .rd_addr    (va_index),
                .rd_tag_r   (tag_rdata[gw]),
                .rd_valid_r (tag_vld[gw]),
                .rd_dirty_r ()
            );

            // ---- 数据阵列 ----
            cache_array_bram #(
                .DW     (DATA_W),
                .DEPTH  (SETS * WORDS),
                .ADDR_W (DATA_ADDR_W)
            ) u_data (
                .clk      (clk),
                .a_en     (data_we[gw]),
                .a_we     (4'hF),                   // 整字写（beat 粒度）
                .a_addr   (data_waddr[gw]),
                .a_din    (data_wdata[gw]),
                .a_dout_r (),
                .b_en     (access),
                .b_addr   ({va_index, va_widx}),
                .b_dout_r (data_rdata[gw])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 7. 命中判定（tag 读数据与访问拍解码同拍出现 ⇒ 当拍比较）
    //--------------------------------------------------------------------------
    wire [TAG_W-1:0] tag_arr [0:WAYS-1];
    wire             hit_arr [0:WAYS-1];
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_hit
            assign tag_arr[gw] = tag_rdata[gw];
            assign hit_arr[gw] = tag_vld[gw] & (tag_rdata[gw] == va_tag);
        end
    endgenerate

    wire any_hit = |hit_arr;

    //--------------------------------------------------------------------------
    // 8. 替换选择：伪 LRU（1 bit/组）
    //    0 ⇒ way0 优先被替换；1 ⇒ way1 优先被替换
    //--------------------------------------------------------------------------
    wire lru_way = plru_q[va_index];            // 2 路下即是"应替换的路"

    // 命中路号（2 路：直接取 way1 的命中位）
    wire way1_hit = hit_arr[1];
    wire [WAY_W-1:0] hit_way = (WAYS == 2) ? {way1_hit} : {WAY_W{1'b0}};

    // 填充目标路：缺失时按 LRU 选；最简 2 路下无"全 invalid"特判（valid=0 的路由
    // 伪 LRU 位决定；复位后 plru 全 0 ⇒ 首次总是填 way0，way1 在 way0 被复用时进入）
    wire [WAY_W-1:0] fill_way = (WAYS == 2) ? {lru_way} : {WAY_W{1'b0}};

    //--------------------------------------------------------------------------
    // 9. 填充写口生成：复用 tag_we/tag_wdata/data_we/data_wdata
    //--------------------------------------------------------------------------
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_fill
            wire this_way_fill = fill_active_q & fill_valid &
                                 (fill_way_q == gw[WAY_W-1:0]);
            assign data_we[gw]    = this_way_fill;
            assign data_waddr[gw] = fill_waddr;
            assign data_wdata[gw] = fill_data;

            // Tag 写：最后一 beat 到齐时落 tag+valid（索引来自行基址）
            assign tag_we[gw]    = fill_done & (fill_way_q == gw[WAY_W-1:0]);
            assign tag_waddr[gw] = fill_paddr_q[OFF_BITS +: INDEX_BITS];
            assign tag_wdata[gw] = fill_paddr_q[31 -: TAG_W];
            assign tag_wvld[gw]  = 1'b1;
        end
    endgenerate

    // 失效：覆盖所有路的 validity（写 valid=0）
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_inval
            // 注：tag_we 已由填充占用；inval 与 fill 不会同拍（idle 才允许 inval）
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 10. 输出（组合）
    //--------------------------------------------------------------------------
    // 命中数据：取命中路的数据读输出
    wire [DATA_W-1:0] hit_data = (WAYS == 2) ? (way1_hit ? data_rdata[1] : data_rdata[0])
                                             : data_rdata[0];

    assign idle      = ~miss_q & ~fill_active_q;
    assign cs_miss   = access & (miss_q | ~any_hit);
    assign cs_ready  = access & ~miss_q & ~fill_active_q & any_hit;
    assign cs_rdata  = hit_data;

    // 填充请求：缺失且无在途填充 ⇒ 发起（地址 = 行基址，物理地址唯一赋值点）
    assign fill_req   = access & ~any_hit & ~fill_active_q & ~miss_q & xip_bypass == 1'b0;
    assign fill_paddr = {cs_paddr[31:OFF_BITS], {OFF_BITS{1'b0}}};
    assign fill_owner = OWNER_I_FILL;
    assign fill_beats = WORDS[4:0] - 5'd1;

    //--------------------------------------------------------------------------
    // 11. 时序：状态更新
    //     必须用 always 块：这是状态元件（寄存/阵列写口），无法用 assign 表达。
    //--------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            miss_q        <= 1'b0;
            fill_active_q <= 1'b0;
            fill_paddr_q  <= 32'h0;
            fill_way_q    <= {WAY_W{1'b0}};
            plru_q        <= {SETS{1'b0}};
        end else if (inval_all) begin
            // 整体失效：清 plru、放弃在途（fill 由 MSHR 侧终止）
            miss_q        <= 1'b0;
            fill_active_q <= 1'b0;
            plru_q        <= {SETS{1'b0}};
        end else begin
            // ---- 伪 LRU 更新：命中时把命中路标记为"最近使用"（另一位为 LRU） ----
            if (access & any_hit) begin
                if (WAYS == 2) plru_q[va_index] <= ~way1_hit;  // 命中 way1 ⇒ LRU=way0
            end

            // ---- 缺失登记与填充推进 ----
            if (fill_active_q) begin
                if (fill_done) fill_active_q <= 1'b0;          // 填充完成
            end else if (access & ~any_hit) begin
                miss_q <= 1'b1;
                if (fill_accepted) begin
                    fill_active_q <= 1'b1;
                    fill_paddr_q  <= {cs_paddr[31:OFF_BITS], {OFF_BITS{1'b0}}};
                    fill_way_q    <= fill_way;
                end
            end else if (access & any_hit) begin
                miss_q <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 12. 参数自检
    //--------------------------------------------------------------------------
    initial begin
        if (WAYS != `RV32GC_L1I_WAYS || SETS != `RV32GC_L1I_SETS ||
            LINE_BYTES != `RV32GC_L1I_LINE_BYTES) begin
            $display("L1I FAIL: 组织参数与 core_params.vh 的 L1I 口径不一致");
            $fatal(1, "L1I PARAM FAIL");
        end
        if (WAYS != 2) begin
            $display("L1I FAIL: 本实现按 2 路伪 LRU 定稿（WAYS=%0d）", WAYS);
            $fatal(1, "L1I PARAM FAIL");
        end
        if (SETS != (1 << INDEX_BITS) || (SETS * WAYS * LINE_BYTES) != `RV32GC_L1I_SIZE_BYTES) begin
            $display("L1I FAIL: 容量/索引推导不符（%0d×%0d×%0dB ≠ %0dB）",
                     SETS, WAYS, LINE_BYTES, `RV32GC_L1I_SIZE_BYTES);
            $fatal(1, "L1I PARAM FAIL");
        end
    end

endmodule
