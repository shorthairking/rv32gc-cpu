//==============================================================================
// rtl/cache/l1i.v —— L1 I-Cache：16 KB / 2 路组相联 / 32 B 行 / 256 组
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/05-cache-memory.md §3.1/§5.2/§8；08-baseline-5stage.md §5.1
//
// 结构（05 §3.1 参数表）：
//   - 容量 **16 KB**、**2 路**、32 B 行、**256 组**（16 × 1024 = 16384 B）
//   - 索引 = VA[12:5]（8 bit）；行内偏移 = VA[4:0]；Tag = VA[31:13]（19 bit）
//   - 只读：I-Cache 不参与写通道（05 §3.2「为何 L1I 不做写通道」）
//   - 替换：2 路**伪 LRU（1 bit/组）**（05 §3.1 表格口径）
//
// ★ XIP 旁路（05 §5.2 三条不可协商口径之第 1 条；08 §5.1 行为要点②）：
//   取指的**物理地址**命中 SPI XIP 窗口（PA[31:20]==12'h1C0 ‖ PA[31:16]==16'h1FE8）
//   ⇒ 走 uncached 直通：**不查 Tag、不写 Tag/Data 阵列、不分配、不驱动 AXI**。
//   判定对象是 **PA 不是 VA**（05 §9 C-7 高风险项：VA/PA 混用是静默错）。
//
// 时序结构（BRAM 只能同步读的必然结果，见 08 §7.3）：
//   - Tag 与 Data 均为同步读（读延迟 1 拍）。
//   - 访问拍 S0：cs_req 有效 ⇒ 两阵列同时以索引寻址；S0 末把**本笔请求**
//     打拍锁存（acc_q / va_tag_q / va_index_q / cs_paddr_q，见 §4.1）。
//   - S0 末：tag 读数据与 data 读数据同拍有效 ⇒ 用**锁存的请求字段**比对，
//     当拍给出 cs_ready/cs_miss/cs_rdata ⇒ **命中路径 1 拍**（与旧实现逐拍等价）。
//   - ★ 组合环口径（2026-09-15 修复，验收判据③）：输出只允许由「寄存的阵列读
//     数据 + 寄存的请求字段」决定，**不得**再用当前输入的 cs_req 做组合限定；
//     否则 cs_req → access → cs_ready → 上游 fetch_rsp_valid → fetch_req_valid
//     → cs_req 构成零延迟组合环（Verilator UNOPTFLAT：
//     core_top.fu_fetch_req_valid；iverilog 亦判环 ⇒ M1 实测全网 x）。
//   - 缺失：S0 末置 miss；驱动填充请求；填充期间 cs_ready=0；
//     每个回填 beat 按 fill_word_idx 写入目标路，最后一拍落 tag+valid。
//
// ★ 参数默认值直接取自真源宏（rtl/pkg/core_params.vh §7）：
//   注意 `RV32GC_L1I_SETS` 等是"计算型宏"，其内层宏引用**必须带反引号**
//   （iverilog 12.0 不会对宏体内的裸名再展开，会让 parameter 初值报
//   "Unable to bind parameter"）。该 pkg 侧问题已于 2026-09-14 修复，
//   因此本文件可以直接使用宏，无需字面量兜底。
//
// 说明（红线 3）：除"状态寄存器更新"与"阵列行为模型"外全部用 assign；
//   阵列例化走 generate。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module l1i #(
    // ---- 组织参数（= core_params.vh §7 的 L1I 口径：16 KB / 2 路 / 32 B 行） ----
    parameter integer WAYS       = `RV32GC_L1I_WAYS,          // 路数 = 2
    parameter integer SETS       = `RV32GC_L1I_SETS,          // 组数 = 256
    parameter integer LINE_BYTES = `RV32GC_L1I_LINE_BYTES,    // 行大小 = 32 B
    parameter integer INDEX_BITS = `RV32GC_L1I_INDEX_BITS,    // VA[12:5]
    parameter integer OFF_BITS   = `RV32GC_L1I_OFFSET_BITS,   // VA[4:0]
    parameter integer TAG_W      = 19,       // VA[31:13]
    parameter integer DATA_W     = 32,       // AXI beat 位宽
    parameter integer OWNER_W    = 2,
    parameter [OWNER_W-1:0] OWNER_I_FILL = 2'd0    // 归属：I-Cache 填充
) (
    input  wire                 clk,
    input  wire                 rst_n,

    //------------------------------------------------------------------
    // 取指单元 <-> L1I
    //------------------------------------------------------------------
    input  wire                 cs_req,        // 取指请求
    input  wire [31:0]          cs_paddr,      // ★ 物理地址（XIP 判定用）
    input  wire [31:0]          cs_vaddr,      // 虚拟地址（索引/tag/偏移用）
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
    input  wire [4:0]           fill_word_idx, // 本 beat 行内字序号（0..7）
    input  wire                 fill_done,     // 最后一 beat 已收（mshr done）

    //------------------------------------------------------------------
    // 维护
    //------------------------------------------------------------------
    input  wire                 inval_all,     // 整体失效（fence.i / cbo.inval）
    output wire                 idle           // 无在途事务
);
    //--------------------------------------------------------------------------
    // 1. 派生常量
    //--------------------------------------------------------------------------
    localparam integer WORD_BYTES  = DATA_W / 8;                  // 4 B/字
    localparam integer WORDS       = LINE_BYTES / WORD_BYTES;      // 8 字/行
    localparam integer WIDX_BITS   = 3;                            // log2(8)
    localparam integer DATA_ADDR_W = INDEX_BITS + WIDX_BITS;       // 11 bit
    localparam integer WAY_W       = 1;                            // 2 路

    //--------------------------------------------------------------------------
    // 2. 地址字段（VA 口径）
    //--------------------------------------------------------------------------
    wire [INDEX_BITS-1:0] va_index  = cs_vaddr[OFF_BITS +: INDEX_BITS];
    wire [TAG_W-1:0]      va_tag    = cs_vaddr[31 -: TAG_W];
    wire [OFF_BITS-1:0]   va_offset = cs_vaddr[OFF_BITS-1:0];

    //--------------------------------------------------------------------------
    // 3. XIP 旁路判定（**物理地址**口径；05 §5.2 口径 1、§9 C-7）
    //--------------------------------------------------------------------------
    wire xip_hit_hi20 = ((cs_paddr[31:20] & `RV32GC_XIP_HI20_MSK) == `RV32GC_XIP_HI20_VAL);
    wire xip_hit_hi16 = (cs_paddr[31:16] == `RV32GC_SPI_HIT_VAL);
    wire xip_bypass   = xip_hit_hi20 | xip_hit_hi16;
    assign cs_uncached = xip_bypass;

    // 进入 Cache 阵列的访问（旁路请求被剔除：不查、不写、不分配）
    wire access = cs_req & ~xip_bypass;

    //--------------------------------------------------------------------------
    // 4. 状态寄存器
    //--------------------------------------------------------------------------
    reg              miss_q;         // 未命中（在途）
    reg              fill_active_q;  // 填充在途
    reg              fill_taken_q;   // 本笔填充请求已被接受（防重复发起）
    reg [31:0]       fill_line_q;    // 在途填充行基址（物理地址，唯一赋值点）
    reg              fill_way_q;     // 在途填充目标路（2 路 ⇒ 1 bit）
    reg [SETS-1:0]   plru_q;         // 伪 LRU：1 ⇒ way1 为 LRU，0 ⇒ way0 为 LRU

    //--------------------------------------------------------------------------
    // 4.1 ★ 访问流水寄存器（组合环修复：请求接受打拍 + 数据/命中由寄存器决定）
    //     语义：acc_q 恒等于"上一拍那笔请求是否为本 Cache 访问"（= 旧式组合
    //     `access` 延迟 1 拍）；va_*_q 与 cs_paddr_q 是**同一次阵列读**所对应的
    //     请求字段（都在同一个时钟沿锁存）。因此用它们做命中比较/数据选择/
    //     行基址生成，与旧实现逐拍等价，但彻底切断了输出对 cs_req 的组合依赖。
    //--------------------------------------------------------------------------
    reg              acc_q;          // 上一拍接受的访问（组合环的断点）
    reg [TAG_W-1:0]  va_tag_q;       // 该笔访问的 VA tag（命中比较用）
    reg [INDEX_BITS-1:0] va_index_q; // 该笔访问的组索引（伪 LRU 更新用）
    reg [31:0]       cs_paddr_q;     // 该笔访问的物理地址（填充行基址来源）
    reg              fill_done_q;    // ★ 填充收尾拍：阵列同址被写 ⇒ 读数据需再取一拍

    //--------------------------------------------------------------------------
    // 5. Tag 阵列（每路）与数据阵列（每路）
    //--------------------------------------------------------------------------
    wire [TAG_W-1:0] tag_rdata [0:WAYS-1];
    wire             tag_vld   [0:WAYS-1];
    wire [DATA_W-1:0] data_rdata[0:WAYS-1];

    // 填充写口（两路共享地址/数据，仅目标路拉写使能）
    wire [INDEX_BITS-1:0]  fill_idx  = fill_line_q[OFF_BITS +: INDEX_BITS];
    wire [TAG_W-1:0]       fill_tag  = fill_line_q[31 -: TAG_W];
    wire [DATA_ADDR_W-1:0] fill_waddr = {fill_idx, fill_word_idx[WIDX_BITS-1:0]};

    genvar gw;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_way
            wire way_sel      = (fill_way_q == gw[0]);
            wire way_fill_dat = fill_active_q & fill_valid & way_sel;
            wire way_fill_tag = fill_active_q & fill_done  & way_sel;

            cache_tag_array #(
                .TAG_W  (TAG_W),
                .SETS   (SETS),
                .ADDR_W (INDEX_BITS)
            ) u_tag (
                .clk        (clk),
                // 写优先级：失效 > 填充落 tag
                // ★ inval_all 必须真正清 valid：否则 fence.i / cbo.inval 后
                //   旧 tag 仍命中 ⇒ 取到陈旧指令（静默错）。
                .wr_en      (inval_all | way_fill_tag),
                .wr_addr    (inval_all ? va_index
                                       : fill_line_q[OFF_BITS +: INDEX_BITS]),
                .wr_tag     (fill_tag),
                .wr_valid   (inval_all ? 1'b0 : 1'b1),
                .wr_dirty   (1'b0),                  // I-Cache 无 dirty
                .rd_en      (access),
                .rd_addr    (va_index),
                .rd_tag_r   (tag_rdata[gw]),
                .rd_valid_r (tag_vld[gw]),
                .rd_dirty_r ()
            );

            cache_array_bram #(
                .DW     (DATA_W),
                .DEPTH  (SETS * WORDS),
                .ADDR_W (DATA_ADDR_W)
            ) u_data (
                .clk      (clk),
                .a_en     (way_fill_dat),
                .a_we     (4'hF),                    // 整字写（beat 粒度）
                .a_addr   (fill_waddr),
                .a_din    (fill_data),
                .a_dout_r (),
                .b_en     (access),
                .b_addr   ({va_index, va_offset[OFF_BITS-1 -: WIDX_BITS]}),
                .b_dout_r (data_rdata[gw])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 6. 命中判定（tag 读数据与**锁存请求字段**同拍对应 ⇒ 当拍比较；1 拍命中）
    //    tag_rdata/tag_vld 是上一拍索引寻址读出的寄存器值，va_tag_q 是同一拍
    //    锁存的请求 tag ⇒ 两者严格同龄；不使用当前输入的 cs_vaddr/cs_req。
    //--------------------------------------------------------------------------
    wire hit0_q = tag_vld[0] & (tag_rdata[0] == va_tag_q);
    wire hit1_q = tag_vld[1] & (tag_rdata[1] == va_tag_q);
    wire any_hit_q = hit0_q | hit1_q;

    //--------------------------------------------------------------------------
    // 7. 替换选择：伪 LRU（1 bit/组）
    //    取**本笔完成访问的组索引**（va_index_q）：命中更新与填充选路必须
    //    针对同一笔访问，避免请求已改址时选错组。
    //--------------------------------------------------------------------------
    wire lru_is_way1  = plru_q[va_index_q];    // 1 ⇒ way1 优先被替换
    wire fill_way_sel = lru_is_way1;

    //--------------------------------------------------------------------------
    // 8. 输出（全部由寄存器决定：阵列读数据 + 请求锁存字段；无 cs_req 组合依赖）
    //--------------------------------------------------------------------------
    wire [31:0] hit_data = hit1_q ? data_rdata[1] : data_rdata[0];

    // 本拍输出的资格：① 上一拍确实接受了一笔 Cache 访问（acc_q）
    //              ② 该笔访问的阵列输出**未被同拍写入污染**（~fill_done_q，见下）
    // ★ fill_done_q 口径：填充最后一拍在"落 tag/valid"的同时也做了一次阵列读，
    //   但行为模型（与 BRAM 同址同拍先读后写一致）给出的是**写前**旧值 ⇒ 下一拍
    //   若直接用该读值判定，会对刚填好的行误报 miss 并**重复发起一笔填充**。
    //   故收尾拍的下一拍只压制判定一拍，让阵列把同一地址再读一次（请求仍持有，
    //   rd_en=access 自然再读），此后即正常命中。TB 的空闲拍访问不受影响。
    wire eval_q = acc_q & ~fill_done_q;

    // 一笔"新缺失"：上一拍有访问、未命中、且当前无在途填充
    // ★ 只有在没有在途填充时才可能发起新填充；在途期间不得重复发起
    //   （否则 fill_req 会在收尾拍抖动，造成上游重复记账）。
    wire new_miss = eval_q & ~any_hit_q & ~fill_active_q;

    assign idle      = ~miss_q & ~fill_active_q;
    assign cs_miss   = eval_q & (miss_q | ~any_hit_q);
    assign cs_ready  = eval_q & ~miss_q & ~fill_active_q & any_hit_q;
    assign cs_rdata  = hit_data;

    // 填充请求：新缺失且未被接受 ⇒ 保持拉高直到被接受（valid&&ready 握手）
    assign fill_req   = new_miss & ~fill_taken_q;
    assign fill_paddr = {cs_paddr_q[31:OFF_BITS], {OFF_BITS{1'b0}}};
    assign fill_owner = OWNER_I_FILL;
    assign fill_beats = WORDS[4:0] - 5'd1;     // 8 beat ⇒ 7

    // 请求已被接受（本拍握手成功）
    wire fill_take = fill_req & fill_accepted;

    //--------------------------------------------------------------------------
    // 9. 时序：状态更新
    //    必须用 always 块：状态元件（寄存器），无法用 assign 表达。
    //    推进条件一律用 valid && ready（三件套纪律）。
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            miss_q        <= 1'b0;
            fill_active_q <= 1'b0;
            fill_taken_q  <= 1'b0;
            fill_line_q   <= 32'h0;
            fill_way_q    <= 1'b0;
            plru_q        <= {SETS{1'b0}};
            acc_q         <= 1'b0;
            va_tag_q      <= {TAG_W{1'b0}};
            va_index_q    <= {INDEX_BITS{1'b0}};
            cs_paddr_q    <= 32'h0;
            fill_done_q   <= 1'b0;
        end else if (inval_all) begin
            // 整体失效（fence.i / cbo.inval）：同时丢弃在途访问的判定资格
            //   （失效写口刚改过阵列 ⇒ 本拍读数据不再可信，下一拍再重读）
            miss_q        <= 1'b0;
            fill_active_q <= 1'b0;
            fill_taken_q  <= 1'b0;
            plru_q        <= {SETS{1'b0}};
            acc_q         <= 1'b0;
            fill_done_q   <= 1'b1;
        end else begin
            // ---- ★ 请求接受打拍：把本拍被接受的请求（连同其地址字段）锁存 ----
            //   下次判定/选路只用这组寄存器值（阵列读数据与它们同沿产生）。
            acc_q      <= access;
            va_tag_q   <= va_tag;
            va_index_q <= va_index;
            cs_paddr_q <= cs_paddr;

            // ---- 填充收尾脉冲（默认清零 ⇒ 只维持一拍）----
            fill_done_q <= 1'b0;

            // ---- 伪 LRU：命中时保护命中路（另一位成为 LRU） ----
            if (eval_q & any_hit_q) begin
                plru_q[va_index_q] <= ~hit1_q;    // 命中 way1 ⇒ LRU=way0
            end

            // ---- 填充握手：接受后转入"在途填充" ----
            if (fill_take) begin
                fill_active_q <= 1'b1;
                fill_taken_q  <= 1'b1;
                fill_line_q   <= fill_paddr;
                fill_way_q    <= fill_way_sel;
                miss_q        <= 1'b1;
            end

            // ---- 在途填充推进：最后一 beat 到齐 ⇒ 释放 ----
            //   同拍落 tag/valid（写口）⇒ 触发 fill_done_q 压制下一拍判定，
            //   让阵列重读一次（消除"刚填完却报 miss ⇒ 重复填充"）。
            if (fill_active_q & fill_valid & fill_done) begin
                fill_active_q <= 1'b0;
                fill_taken_q  <= 1'b0;
                miss_q        <= 1'b0;
                fill_done_q   <= 1'b1;
            end

            // ---- 命中 ⇒ 清 miss ----
            if (eval_q & any_hit_q & ~miss_q) begin
                miss_q <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 10. 参数自检：锁定与 core_params.vh §7 的口径一致（字面量 ↔ 宏对照）
    //--------------------------------------------------------------------------
    initial begin
        // 与真源宏逐项比对（编译期即锁定：参数默认值必须等于 core_params.vh 口径）
        if (WAYS != `RV32GC_L1I_WAYS) begin
            $display("L1I FAIL: WAYS=%0d 应为 %0d", WAYS, `RV32GC_L1I_WAYS);
            $fatal(1, "L1I PARAM FAIL");
        end
        if (SETS != `RV32GC_L1I_SETS) begin
            $display("L1I FAIL: SETS=%0d 应为 %0d", SETS, `RV32GC_L1I_SETS);
            $fatal(1, "L1I PARAM FAIL");
        end
        if (LINE_BYTES != `RV32GC_L1I_LINE_BYTES) begin
            $display("L1I FAIL: LINE_BYTES=%0d 应为 %0d", LINE_BYTES, `RV32GC_L1I_LINE_BYTES);
            $fatal(1, "L1I PARAM FAIL");
        end
        if (INDEX_BITS != 8 || OFF_BITS != 5 || TAG_W != 19) begin
            $display("L1I FAIL: 索引/偏移/tag 位宽不符");
            $fatal(1, "L1I PARAM FAIL");
        end
        if ((SETS * WAYS * LINE_BYTES) != `RV32GC_L1I_SIZE_BYTES) begin
            $display("L1I FAIL: 容量 = %0d B，应为 %0d B（16 KB）",
                     SETS * WAYS * LINE_BYTES, `RV32GC_L1I_SIZE_BYTES);
            $fatal(1, "L1I PARAM FAIL");
        end
        if (WORDS != 8) begin
            $display("L1I FAIL: 每行字数 = %0d，应为 8", WORDS);
            $fatal(1, "L1I PARAM FAIL");
        end
    end

endmodule
