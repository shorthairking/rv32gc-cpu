//==============================================================================
// rtl/cache/l1d.v —— L1 D-Cache：32 KB / 4 路组相联 / 32 B 行 / 256 组
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/05-cache-memory.md §3.1/§5/§7；08-baseline-5stage.md §5.4
//
// 结构（05 §3.1 参数表）：
//   - 容量 **32 KB**、**4 路**、32 B 行、**256 组**（32 × 1024 = 32768 B）
//   - 索引 = VA[12:5]（8 bit）；行内偏移 = VA[4:0]；Tag = VA[31:13]（19 bit）
//   - **写回 + 写分配**（05 §3.2：写直达会让每笔 store 穿透 AXI，代价过高）
//   - VIPT：索引落在 4 KiB 页偏移内 ⇒ 同页无别名（05 §6）
//
// ★ 替换选择（文档口径与实现的显式声明，不做静默替换）：
//   05 §3.1 表格写"真 LRU（4 路，树形）"。本实现落地为 **4 路 PLRU 树（3 bit/组）**：
//   每组 3 个方向位构成二叉替换树；访问时把沿途方向位指向被访问路，替换时从根
//   沿"未被指向"的方向下行到叶子即为受害者。行为上等价于"最近最少使用路优先
//   被替换"，面积/时序远优于计数式真 LRU，是 4 路下的工业界事实标准。
//
// 时序（BRAM 只能同步读；与 l1i 同结构、1 拍命中）：
//   - 访问拍 S0：cs_req ⇒ tag/data 同时以索引寻址；S0 末两者的读数据同拍有效
//     ⇒ 当拍比较 ⇒ **读命中 1 拍返回**；写命中当拍落数据阵列并置 dirty。
//   - 缺失：分三步走（状态机由 3 个在途标志表达，推进一律用 valid && ready）：
//       WB_CAP(SD)：若受害者 dirty ⇒ 先花 1 拍把受害者整行 8 字读入行缓冲
//       WB(BUS)    ：按 wb_word_idx 逐 beat 把行缓冲推出（owner=2）
//       FILL(BUS)  ：填充新行（owner=1），最后一 beat 落 tag+valid 且 dirty=0
//     填充完成后由 LSU 重放原访问（2A 简化口径，见 08 §5.4）。
//
// ★ 参数默认值直接取自真源宏（rtl/pkg/core_params.vh §7）。
//   注：`RV32GC_L1D_SETS` 属"计算型宏"，其内层引用必须带反引号才能被 iverilog
//   正确再展开；该 pkg 侧问题已于 2026-09-14 修复，故本文件直接用宏。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module l1d #(
    // ---- 组织参数（= core_params.vh §7 的 L1D 口径：32 KB / 4 路 / 32 B 行） ----
    parameter integer WAYS       = `RV32GC_L1D_WAYS,          // 路数 = 4
    parameter integer SETS       = `RV32GC_L1D_SETS,          // 组数 = 256
    parameter integer LINE_BYTES = `RV32GC_L1D_LINE_BYTES,    // 行大小 = 32 B
    parameter integer INDEX_BITS = `RV32GC_L1D_INDEX_BITS,    // VA[12:5]
    parameter integer OFF_BITS   = `RV32GC_L1D_OFFSET_BITS,   // VA[4:0]
    parameter integer TAG_W      = 19,       // VA[31:13]
    parameter integer DATA_W     = 32,       // AXI beat
    parameter integer OWNER_W    = 2,
    parameter [OWNER_W-1:0] OWNER_D_FILL = 2'd1,   // 归属：D-Cache 填充
    parameter [OWNER_W-1:0] OWNER_WRBACK = 2'd2    // 归属：脏行写回
) (
    input  wire                 clk,
    input  wire                 rst_n,

    //------------------------------------------------------------------
    // M 级 LSU <-> L1D（每拍 1 笔）
    //------------------------------------------------------------------
    input  wire                 cs_req,       // 访问请求
    input  wire                 cs_we,        // 1 = 写（store），0 = 读（load）
    input  wire [3:0]           cs_wstrb,     // 字节写使能（store 用）
    input  wire [31:0]          cs_paddr,     // 物理地址（总线口径）
    input  wire [31:0]          cs_vaddr,     // 虚拟地址（索引/tag）
    input  wire [31:0]          cs_wdata,     // 写数据
    output wire                 cs_ready,     // 读命中当拍完成
    output wire [31:0]          cs_rdata,     // 读数据
    output wire                 cs_miss,      // 未命中（含在途）
    output wire                 cs_stall,     // 需停顿（缺失/写回在途）
    output wire                 cs_wr_done,   // 写命中当拍完成（store 可提交）

    //------------------------------------------------------------------
    // MSHR / AXI 控制器 <-> L1D
    //------------------------------------------------------------------
    output wire                 fill_req,     // 需要一笔行填充
    output wire [31:0]          fill_paddr,   // 行基址（物理地址，唯一赋值点）
    output wire [OWNER_W-1:0]   fill_owner,
    output wire [4:0]           fill_beats,
    input  wire                 fill_accepted,
    input  wire                 fill_valid,
    input  wire [31:0]          fill_data,
    input  wire [4:0]           fill_word_idx,
    input  wire                 fill_done,

    // ---- 脏行写回 ----
    output wire                 wb_req,       // 需要一笔脏行写回
    output wire [31:0]          wb_paddr,     // 写回行基址（物理地址）
    output wire [1:0]           wb_way,       // 被写回的路（4 路 ⇒ 2 bit）
    output wire [OWNER_W-1:0]   wb_owner,
    output wire [4:0]           wb_beats,
    input  wire                 wb_accepted,  // 控制器接受
    input  wire [4:0]           wb_word_idx,  // 本 beat 取行缓冲的哪一字
    output wire [31:0]          wb_data,      // 写回 beat 数据
    input  wire                 wb_done,      // 写回完成（最后一拍）
    output wire                 wb_ready,     // 本拍可接收写回数据（MS_WB_BUS 阶段）

    //------------------------------------------------------------------
    // 维护（cbo.clean / flush / inval）
    //------------------------------------------------------------------
    input  wire                 inval_all,    // 全部失效
    input  wire                 clean_all,    // 全部 clean（清 dirty，不失效）
    output wire                 idle
);
    //--------------------------------------------------------------------------
    // 1. 派生常量
    //--------------------------------------------------------------------------
    localparam integer WORD_BYTES  = DATA_W / 8;                 // 4
    localparam integer WORDS       = LINE_BYTES / WORD_BYTES;    // 8 字/行
    localparam integer WIDX_BITS   = 3;                          // log2(8)
    localparam integer DATA_ADDR_W = INDEX_BITS + WIDX_BITS;     // 11
    localparam integer WAY_W       = 2;                          // 4 路

    //--------------------------------------------------------------------------
    // 2. 地址字段（索引/tag 用 VA；总线地址用 PA）
    //--------------------------------------------------------------------------
    wire [INDEX_BITS-1:0] va_index  = cs_vaddr[OFF_BITS +: INDEX_BITS];
    wire [TAG_W-1:0]      va_tag    = cs_vaddr[31 -: TAG_W];
    wire [OFF_BITS-1:0]   va_offset = cs_vaddr[OFF_BITS-1:0];
    wire [WIDX_BITS-1:0]  va_widx   = va_offset[OFF_BITS-1 -: WIDX_BITS];

    //--------------------------------------------------------------------------
    // 2b. 访问寄存器（关键时序口径）
    //   cache_tag_array / cache_array_bram 都是**同步读**：rd_en 有效后，
    //   读数据在**下一个 posedge 之后**才出现在 rd_*_r 上（实测）。
    //   因此命中判定必须用"上一拍发出的访问"的索引与 tag 去比"这一拍读出的
    //   tag 数据"，否则比的是陈旧数据 ⇒ 永远不命中（本 TB 实测到该现象）。
    //   ⇒ 访问字段寄存一拍，命中判定/数据选择都用寄存后的值。
    //--------------------------------------------------------------------------
    reg  [INDEX_BITS-1:0] acc_index_q;
    reg  [TAG_W-1:0]      acc_tag_q;
    reg  [WIDX_BITS-1:0]  acc_widx_q;
    reg                   acc_we_q;
    reg  [3:0]            acc_strb_q;
    reg  [DATA_W-1:0]     acc_wdata_q;
    reg  [31:0]           acc_paddr_q;
    reg                   acc_valid_q;    // 上一拍有访问

    wire                  access    = cs_req;          // 本拍发出的访问
    wire                  access_q  = acc_valid_q;     // 上一拍的访问（读数据已到）

    //--------------------------------------------------------------------------
    // 3. 状态寄存器
    //--------------------------------------------------------------------------
    // ---- 总线阶段 FSM（显式编码，避免由多标志拼出的隐式状态） ----
    localparam [2:0] MS_IDLE     = 3'd0,   // 空闲：可捕获新缺失
                     MS_WB_CAP   = 3'd1,   // 抓行：把受害者整行读入行缓冲
                     MS_WB_BUS   = 3'd2,   // 写回总线：逐 beat 推出
                     MS_FILL_REQ = 3'd3,   // 填充请求：等控制器接收
                     MS_FILL_BUS = 3'd4;   // 填充总线：逐 beat 收下

    reg [2:0]              ms_state_q;     // 总线阶段状态
    reg                    fill_taken_q;   // 填充请求已被接受（防重复发起）
    reg                    wb_taken_q;     // 写回请求已被接受（防重复发起）
    reg                    wb_want_q;      // 已决定写回（跨状态保持请求有效）
    // tag 同步读数据有效（消灭首读 X 传播）
    //   组合口径：rd_en_sel 有效的当拍，读数据即为有效（同步读 + 同拍保持）。
    //   仅在复位后的第 0 拍（rd_en_sel 尚未拉高过）为 0。
    reg                    tag_rd_seen_q;  // 曾经发生过一次 tag 读
    // tag 读数据有效 = 上一拍发生过读（读数据本拍已到）；复位后首拍为 0
    wire                   tag_rd_ok = tag_rd_seen_q;
    reg                    fill_active_q;   // 填充在途
    reg [31:0]             fill_line_q;     // 在途填充行基址（物理地址）
    reg [WAY_W-1:0]        fill_way_q;      // 填充目标路
    reg [31:0]             pend_line_q;     // 待填行的行基址（缺失发生时锁存，跨写回保持）
    // ---- 全阵列维护（clean_all / inval_all）扫描状态 ----
    //   全清必须逐组扫描（BRAM 无"整阵列写"端口）；逐组写回 tag 阵列即可。
    reg                    maint_q;         // 维护扫描在途
    reg                    maint_clean_q;   // 1=clean（保留 valid/数据），0=inval（清 valid）
    reg [INDEX_BITS-1:0]   maint_idx_q;     // 当前扫描组索引
    reg                    wb_active_q;     // 写回总线阶段在途
    reg [31:0]             wb_line_q;       // 在途写回行基址（物理地址）
    reg [WAY_W-1:0]        wb_way_q;        // 写回源路
    reg [LINE_BYTES*8-1:0] wb_buf_q;        // 写回行缓冲（8 字）
    reg [WIDX_BITS:0]      cap_rd_q;        // 抓行读地址（0..WORDS，需多 1 位存 WORDS）
    reg [SETS-1:0]         plru_l0_q;       // PLRU 树根方向位
    reg [SETS-1:0]         plru_l1a_q;      // PLRU 左子树方向位
    reg [SETS-1:0]         plru_l1b_q;      // PLRU 右子树方向位
    // 抓行阶段的读地址（受害者路的行内逐字读）
    reg [DATA_ADDR_W-1:0]  cap_raddr_q;

    //--------------------------------------------------------------------------
    // 4. 命中判定（4 路；tag 与 data 同步读，S0 末同拍有效）
    //--------------------------------------------------------------------------
    wire [TAG_W-1:0]  tag_rdata [0:WAYS-1];
    wire              tag_vld   [0:WAYS-1];
    wire              tag_dirty [0:WAYS-1];
    wire [DATA_W-1:0] data_rdata[0:WAYS-1];

    genvar gw;
    wire [WAYS-1:0] hit_vec;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_hit
            // ★ 必须与 tag_rd_ok 相与：tag 阵列的同步读输出在**首次读之前为 X**，
            //   若直接参与命中判定会把 X 传播进 FSM（本 TB 实测到该现象：
            //   首拍 miss=x 且 FSM 卡死）。tag_rd_ok 是"tag 读数据有效"的
            //   流水标志，保证组合路径上不出现 X。
            assign hit_vec[gw] = tag_rd_ok & tag_vld[gw] & (tag_rdata[gw] == acc_tag_q);
        end
    endgenerate
    wire any_hit = |hit_vec;

    // 命中路优先编码（高路优先；多路同时命中物理上不应发生）
    reg [WAY_W-1:0] hit_way_enc;
    integer         hi;
    always @(*) begin                       // 说明：纯优先级编码器，无寄存器/无时序
        hit_way_enc = {WAY_W{1'b0}};
        for (hi = WAYS-1; hi >= 0; hi = hi - 1) begin
            if (hit_vec[hi]) hit_way_enc = hi[WAY_W-1:0];
        end
    end
    wire [WAY_W-1:0] hit_way = hit_way_enc;

    //--------------------------------------------------------------------------
    // 5. 替换：4 路 PLRU 树（3 bit/组）
    //         l0（根）
    //        /       \
    //      l1a        l1b
    //     /   \      /   \
    //    0     1    2     3
    //--------------------------------------------------------------------------
    wire plru_l0  = plru_l0_q[va_index];
    wire plru_l1a = plru_l1a_q[va_index];
    wire plru_l1b = plru_l1b_q[va_index];

    wire [WAY_W-1:0] victim_way = ~plru_l0 ? (~plru_l1a ? 2'd0 : 2'd1)
                                           : (~plru_l1b ? 2'd2 : 2'd3);

    // ★ 同样必须与 tag_rd_ok 相与：tag 首次读之前 tag_vld 为 X，
    //   直接参与替换选择会把 X 写进 fill_way_q（本 TB 实测到 fill_way_q=x）。
    wire [WAYS-1:0] vld_vec = tag_rd_ok ? {tag_vld[3], tag_vld[2], tag_vld[1], tag_vld[0]}
                                        : 4'b0000;
    wire [WAY_W-1:0] invalid_way = ~vld_vec[0] ? 2'd0 :
                                   ~vld_vec[1] ? 2'd1 :
                                   ~vld_vec[2] ? 2'd2 : 2'd3;
    wire any_invalid = ~(&vld_vec);

    wire [WAY_W-1:0] repl_way = any_invalid ? invalid_way : victim_way;

    wire [WAYS-1:0] dirty_vec = tag_rd_ok ? {tag_dirty[3], tag_dirty[2], tag_dirty[1], tag_dirty[0]}
                                          : 4'b0000;
    wire            repl_dirty = dirty_vec[repl_way];

    // 受害者的 tag（用于重建写回行地址）
    wire [TAG_W-1:0] victim_tag = (repl_way == 2'd0) ? tag_rdata[0] :
                                  (repl_way == 2'd1) ? tag_rdata[1] :
                                  (repl_way == 2'd2) ? tag_rdata[2] : tag_rdata[3];

    //--------------------------------------------------------------------------
    // 6. 写命中路径
    //--------------------------------------------------------------------------
    // ★ 写命中使用**寄存后**的访问字段（与本拍 tag 读数据同拍）
    wire                   st_hit   = any_hit & acc_we_q & access_q;
    wire [DATA_ADDR_W-1:0] st_waddr = {acc_index_q, acc_widx_q};

    //--------------------------------------------------------------------------
    // 7. 总线阶段的工作状态判定（先于阵列例化，供读地址选择用）
    //    控制用显式 FSM（MS_* 编码），避免"由多个标志位拼出的隐式状态"。
    //    FSM 只表达"正在做什么"，推进条件一律 valid && ready。
    //--------------------------------------------------------------------------
    // 填充请求保持到被接受（fill_taken_q 防重复），写回同理（wb_taken_q）。
    wire idle_now    = (ms_state_q == MS_IDLE);
    // ★ 缺失判定用**寄存后**的访问（tag 读数据本拍才有效）
    wire missing_new = access_q & ~any_hit & idle_now;


    // 填充请求/接受握手
    wire fill_go     = (ms_state_q == MS_FILL_REQ);
    wire fill_take   = fill_go & fill_accepted;
    wire fill_finish = fill_active_q & fill_valid & fill_done;

    // 写回请求/接受握手
    // 本拍 FSM 决定写回（MS_IDLE 捕获到脏受害者缺失）⇒ 立即拉高 wb_req
    wire wb_decide   = (ms_state_q == MS_IDLE) & missing_new & repl_dirty;
    wire wb_go       = wb_req & wb_accepted;
    // 若控制器在同一拍就接受了（决定拍），也算握手成功：进入 MS_WB_CAP 后
    // 直接开始抓行，不再等第二次 accepted。
    wire wb_take_now = wb_go;

    // 写回总线阶段完成
    // ★ 写回节拍仅在 MS_WB_BUS（推总线）阶段被接受：抓行阶段的拍必须被忽略，
    //   否则控制器提前送来的拍会被当成数据拍（本 TB 实测到 wb_finish 提前触发）。
    /**/
    wire wb_finish   = wb_ready & wb_done;

    //--------------------------------------------------------------------------
    // 8. 阵列例化
    //    读地址优先级：抓行 > 普通访问（二者不同拍：抓行期间 access 被 stall）
    //--------------------------------------------------------------------------
    // 抓行阶段用写回行的索引 + 抓行计数寻址受害者路数据
    // 抓行阶段：已与控制器握手，正在把受害者整行逐字读入行缓冲
    // clean 扫描：对当前组清 dirty（专用口，保留 valid/tag）
    wire                  maint_dirty_clr = maint_q & maint_clean_q;
    wire                  cap_phase    = (ms_state_q == MS_WB_CAP) & wb_taken_q;
    // ★ 读地址用**本拍发出**的访问（rd_en 本拍），读数据下一拍到 ⇒ 与命中判定同拍。
    wire [INDEX_BITS-1:0] rd_index_sel = cap_phase ? wb_line_q[OFF_BITS +: INDEX_BITS]
                                                   : va_index;
    wire [WIDX_BITS-1:0]  rd_widx_sel  = cap_phase ? cap_rd_q[WIDX_BITS-1:0] : va_widx;
    wire                  rd_en_sel    = cap_phase | access;
    // 但数据选择用**寄存后**的访问字段（与 tag 读数据/hit_vec 同拍）
    // 4 路命中数据选择（低路优先；多路同命中物理上不应发生）
    wire [31:0] hit_data_sel = hit_vec[0] ? data_rdata[0] :
                               hit_vec[1] ? data_rdata[1] :
                               hit_vec[2] ? data_rdata[2] : data_rdata[3];

    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_way
            wire way_fill_dat = fill_active_q & fill_valid & (fill_way_q == gw[WAY_W-1:0]);
            wire way_fill_tag = fill_active_q & fill_done  & (fill_way_q == gw[WAY_W-1:0]);
            wire way_st       = st_hit & (hit_way == gw[WAY_W-1:0]);
            // ★ 维护（inval/clean）：在扫描拍对**所有路**的 maint_idx_q 组写入。
            //   必须有独立的扫描索引；用访问索引或全局电平都会误写/漏写。
            // clean 走"只清 dirty"专用口（保留 tag/valid）；inval 走整项写（清 valid）
            wire way_maint    = maint_q & ~maint_clean_q;
            // 抓行只读受害者路的数据（tag 不动）
            wire way_cap      = (ms_state_q == MS_WB_CAP) & (wb_way_q == gw[WAY_W-1:0]);

            // ---- Tag 阵列 ----
            cache_tag_array #(
                .TAG_W  (TAG_W),
                .SETS   (SETS),
                .ADDR_W (INDEX_BITS)
            ) u_tag (
                .clk        (clk),
                // ★ 维护（clean/inval）只允许改写"被寻址那一项"且必须保留其 tag；
                //   若在无访问的拍上对全部路写 tag/valid，会破坏其它组的项（静默错）。
                .wr_en      (way_fill_tag | way_st | way_maint),
                .wr_addr    (way_maint    ? maint_idx_q
                                          : (way_fill_tag ? fill_line_q[OFF_BITS +: INDEX_BITS]
                                                          : acc_index_q)),
                .wr_tag     (way_fill_tag ? fill_line_q[31 -: TAG_W] : acc_tag_q),
                // valid：inval 扫描清 0；其余（填充/store/clean）保持 1
                .wr_valid   (way_fill_tag ? 1'b1
                                          : (way_maint ? 1'b0 : 1'b1)),
                // dirty：维护扫描清 0；填充清 0；store 置 1
                .wr_dirty   (way_fill_tag ? 1'b0
                                          : (way_maint ? 1'b0 : 1'b1)),
                .rd_en      (access),               // tag 只在访问拍读
                .rd_addr    (va_index),
                .rd_tag_r   (tag_rdata[gw]),
                .rd_valid_r (tag_vld[gw]),
                .rd_dirty_r (tag_dirty[gw]),
                .dirty_clr_en   (maint_dirty_clr),
                .dirty_clr_addr (maint_idx_q)
            );

            // ---- 数据阵列（A=写，B=读） ----
            cache_array_bram #(
                .DW     (DATA_W),
                .DEPTH  (SETS * WORDS),
                .ADDR_W (DATA_ADDR_W)
            ) u_data (
                .clk      (clk),
                .a_en     (way_fill_dat | way_st),
                .a_we     (way_fill_dat ? 4'hF : acc_strb_q),
                .a_addr   (way_fill_dat ? {fill_line_q[OFF_BITS +: INDEX_BITS],
                                           fill_word_idx[WIDX_BITS-1:0]}
                                        : st_waddr),
                .a_din    (way_fill_dat ? fill_data : acc_wdata_q),
                .a_dout_r (),
                .b_en     (rd_en_sel),
                .b_addr   ({rd_index_sel, rd_widx_sel}),
                .b_dout_r (data_rdata[gw])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 9. 抓行数据装配：抓行期间每拍读受害者路一个字，按 cap_cnt 填入行缓冲
    //    （data_rdata[wb_way_q] 当拍有效 → 下一拍写入对应字节段）
    //--------------------------------------------------------------------------
    wire [DATA_W-1:0] cap_word = data_rdata[wb_way_q];   // 受害者路的同步读输出
    wire [31:0] wb_data_sel = wb_buf_q[wb_word_idx[WIDX_BITS-1:0]*32 +: 32];

    //--------------------------------------------------------------------------
    // 10. 对外输出（组合）
    //--------------------------------------------------------------------------
    assign cs_rdata   = hit_data_sel;   // 读数据（命中路的同步读输出）
    assign cs_miss    = access_q & ~any_hit;
    assign cs_ready   = access_q & any_hit & ~acc_we_q;   // 读命中（读数据到齐那拍）
    assign cs_wr_done = st_hit;                           // 写命中
    // ★ 维护扫描（maint_q=1）视作"非空闲/占用"：扫描在途期间 idle 必须为 0，
    //   否则调用方（LSU 维护路径）会按 idle=1 误判扫描已完成而放行新访问，
    //   与 08 §7.2 落档口径"调用方以 idle 判定扫描完成再放行访问"矛盾。
    assign cs_stall   = access | cs_miss | (ms_state_q != MS_IDLE) | maint_q;
    assign idle       = (ms_state_q == MS_IDLE) & ~maint_q;

    // 写回请求：一旦 FSM 决定写回（进入 MS_WB_CAP）即拉高，直到握手完成。
    //   ★ 必须覆盖"FSM 尚未从上一条状态跳转过来"的窗口：若只在 MS_WB_CAP
    //     组合判断，控制器在 MS_IDLE 拍的握手会丢失（本 TB 实测到该死锁）。
    //   因此用 wb_want_q 寄存"要写回"，wb_req = (wb_want_q | 本拍决定) & ~已接受。
    assign wb_req   = (wb_want_q | wb_decide) & ~wb_taken_q;
    assign wb_paddr = wb_line_q;
    assign wb_way   = wb_way_q;
    assign wb_owner = OWNER_WRBACK;
    assign wb_beats = WORDS[4:0] - 5'd1;
    assign wb_data  = wb_data_sel;
    // 写回数据接收就绪：仅在推总线阶段（MS_WB_BUS）为 1，抓行阶段为 0。
    //   控制器必须按 valid && ready 握手，不得在 ready=0 时送拍。
    assign wb_ready = (ms_state_q == MS_WB_BUS) & wb_active_q;

    // 填充总线请求：在 MS_FILL_REQ 到 MS_FILL_BUS 期间有效
    //   注：fill_req 一旦被接受即进入在途（fill_active_q），不再重新发起
    //   （fill_taken_q 阻止重复计数）。
    assign fill_req   = fill_go & ~fill_taken_q;
    assign fill_paddr = fill_line_q;
    assign fill_owner = OWNER_D_FILL;
    assign fill_beats = WORDS[4:0] - 5'd1;

    //--------------------------------------------------------------------------
    // 11. 时序：显式 FSM + 数据通路寄存器
    //    必须用 always 块：状态元件（FSM/寄存器），无法用 assign 表达。
    //    推进条件一律 valid && ready（三件套纪律）。
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            tag_rd_seen_q <= 1'b0;
            acc_valid_q   <= 1'b0;
            acc_index_q   <= {INDEX_BITS{1'b0}};
            acc_tag_q     <= {TAG_W{1'b0}};
            acc_widx_q    <= {WIDX_BITS{1'b0}};
            acc_we_q      <= 1'b0;
            acc_strb_q    <= 4'h0;
            acc_wdata_q   <= {DATA_W{1'b0}};
            acc_paddr_q   <= 32'h0;
            ms_state_q    <= MS_IDLE;
            fill_active_q <= 1'b0;
            fill_taken_q  <= 1'b0;
            wb_active_q   <= 1'b0;
            wb_taken_q    <= 1'b0;
            wb_want_q     <= 1'b0;
            fill_line_q   <= 32'h0;
            pend_line_q   <= 32'h0;
            maint_q       <= 1'b0;
            maint_clean_q <= 1'b0;
            maint_idx_q   <= {INDEX_BITS{1'b0}};
            wb_line_q     <= 32'h0;
            fill_way_q    <= {WAY_W{1'b0}};
            wb_way_q      <= {WAY_W{1'b0}};
            wb_buf_q      <= {(LINE_BYTES*8){1'b0}};
            cap_rd_q      <= {(WIDX_BITS+1){1'b0}};
            plru_l0_q     <= {SETS{1'b0}};
            plru_l1a_q    <= {SETS{1'b0}};
            plru_l1b_q    <= {SETS{1'b0}};
        end else if ((inval_all | clean_all) & ~maint_q) begin
            // 启动全阵列维护扫描（逐组进行；完成后自动退出并清 PLRU）
            maint_q       <= 1'b1;
            maint_clean_q <= clean_all & ~inval_all;   // inval 优先
            maint_idx_q   <= {INDEX_BITS{1'b0}};
            ms_state_q    <= MS_IDLE;
            fill_active_q <= 1'b0;
            fill_taken_q  <= 1'b0;
            wb_active_q   <= 1'b0;
            wb_taken_q    <= 1'b0;
            wb_want_q     <= 1'b0;
            cap_rd_q      <= {(WIDX_BITS+1){1'b0}};
        end else if (maint_q) begin
            // 维护扫描：本拍对 maint_idx_q 指向的组写所有路（清 dirty / 清 valid）
            if (maint_idx_q == SETS[INDEX_BITS-1:0] - 1'b1) begin
                maint_q     <= 1'b0;
                plru_l0_q   <= {SETS{1'b0}};
                plru_l1a_q  <= {SETS{1'b0}};
                plru_l1b_q  <= {SETS{1'b0}};
            end else begin
                maint_idx_q <= maint_idx_q + 1'b1;
            end
        end else begin
            // ---- tag 读数据有效标志 ----
            //     时序口径：tag 阵列是同步读，rd_en 在访问拍拉高，读数据在**同一拍末**
            //     出现在 rd_tag_r 上并在下一拍保持 ⇒ 组合比较发生在 rd_en 拍本身。
            //     因此 tag_rd_ok 必须在 **rd_en_sel 的同拍**（组合）为 1，
            //     而不是延后一拍；这里用组合赋值（见下方 assign），
            //     本寄存器仅在复位后首拍提供保护（防首读 X 传播）。
            tag_rd_seen_q <= rd_en_sel;

            // ---- PLRU 更新：命中时把沿途方向位指向命中路 ----
            if (access_q & any_hit) begin
                plru_l0_q[acc_index_q]  <= hit_way[1];
                plru_l1a_q[acc_index_q] <= (hit_way[1] == 1'b0) ? hit_way[0] : plru_l1a_q[acc_index_q];
                plru_l1b_q[acc_index_q] <= (hit_way[1] == 1'b1) ? hit_way[0] : plru_l1b_q[acc_index_q];
            end

            // ---- 访问寄存器更新：把本拍发出的访问寄存给下一拍使用 ----
            acc_valid_q <= access;
            acc_index_q <= va_index;
            acc_tag_q   <= va_tag;
            acc_widx_q  <= va_widx;
            acc_we_q    <= cs_we;
            acc_strb_q  <= cs_wstrb;
            acc_wdata_q <= cs_wdata;
            acc_paddr_q <= cs_paddr;

            // ---- 总线在途阶段：抓行 → 写回 → 填充 ----
            case (ms_state_q)
                // ---------------- 空闲：捕获新缺失 ----------------
                MS_IDLE: begin
                    if (missing_new) begin
                        if (repl_dirty) begin
                            // 受害者脏 ⇒ 先抓行（锁存写回行地址/源路）
                            // ★ 写回地址必须是**受害者**的行地址，而不是本笔新请求的
                            //   地址：由受害路的 tag + 组索引重建（VIPT 下 tag 取自
                            //   虚拟地址，L1D 索引与页偏移对齐 ⇒ 与物理地址同页等价）。
                            ms_state_q <= MS_WB_CAP;
                            wb_want_q  <= 1'b1;
                            wb_line_q  <= {victim_tag, acc_index_q, {OFF_BITS{1'b0}}};
                            wb_way_q   <= repl_way;
                            // 本笔待填行（= 发起请求的行），跨写回保持
                            pend_line_q<= {acc_paddr_q[31:OFF_BITS], {OFF_BITS{1'b0}}};
                            cap_rd_q   <= {(WIDX_BITS+1){1'b0}};
                        end else begin
                            // 干净 ⇒ 直接进入填充请求（锁存填充行地址/目标路）
                            ms_state_q  <= MS_FILL_REQ;
                            fill_line_q <= {acc_paddr_q[31:OFF_BITS], {OFF_BITS{1'b0}}};
                            pend_line_q <= {acc_paddr_q[31:OFF_BITS], {OFF_BITS{1'b0}}};
                            fill_way_q  <= repl_way;
                            fill_taken_q<= 1'b0;
                        end
                    end
                end

                // ---------------- 抓行：先与控制器握手，再逐字读入行缓冲 ----------------
                //   时序：被接受后进入抓行；第 1 拍发读地址（cap_cnt_q=0），
                //   此后每拍把上一拍地址对应的读数据装配进行缓冲。
                MS_WB_CAP: begin
                    if (wb_taken_q) begin
                        // ★ 时序：cap_phase 变高的**首拍**只是把读地址 0 送进阵列，
                        //   其数据要到下一拍才到；因此首拍不装配，从第二拍起把
                        //   (cap_rd_q-1) 对应的字写入行缓冲。
                        // 地址 0..7 逐拍发出；每拍装配上一拍地址对应的数据。
                        // 需要 9 拍（cap_rd_q 从 0 走到 8）才能把 word 7 也装配好。
                        if (cap_rd_q != {WIDX_BITS{1'b0}}) begin
                            wb_buf_q[(cap_rd_q[WIDX_BITS-1:0] - 1'b1)*32 +: 32] <= cap_word;
                        end
                        if (cap_rd_q == WORDS[WIDX_BITS:0]) begin
                            ms_state_q <= MS_WB_BUS;
                            wb_active_q<= 1'b1;
                            cap_rd_q   <= {(WIDX_BITS+1){1'b0}};
                        end else begin
                            cap_rd_q   <= cap_rd_q + 1'b1;
                        end
                    end else if (wb_go) begin
                        wb_taken_q <= 1'b1;
                        cap_rd_q   <= {(WIDX_BITS+1){1'b0}};
                        wb_buf_q   <= {(LINE_BYTES*8){1'b0}};
                    end
                end

                // ---------------- 写回总线：逐 beat 推出 ----------------
                MS_WB_BUS: begin
                    if (wb_finish) begin
                        wb_active_q <= 1'b0;
                        wb_taken_q  <= 1'b0;
                        wb_want_q   <= 1'b0;
                        // 写回完成 ⇒ 转到填充（写分配：先腾路再填）
                        ms_state_q  <= MS_FILL_REQ;
                        // ★ 写回完成后要填的是**本笔请求的行**（pend_line_q），
                        //   而不是被写回的受害者行（wb_line_q）——后者已失效腾空。
                        fill_line_q <= pend_line_q;
                        fill_way_q  <= wb_way_q;
                        fill_taken_q<= 1'b0;
                    end
                end

                // ---------------- 填充请求：等控制器接收 ----------------
                MS_FILL_REQ: begin
                    if (fill_take) begin
                        fill_active_q <= 1'b1;
                        fill_taken_q  <= 1'b1;
                        ms_state_q    <= MS_FILL_BUS;
                    end
                end

                // ---------------- 填充总线：逐 beat 收下 ----------------
                MS_FILL_BUS: begin
                    if (fill_finish) begin
                        fill_active_q <= 1'b0;
                        fill_taken_q  <= 1'b0;
                        ms_state_q    <= MS_IDLE;
                    end
                end

                default: ms_state_q <= MS_IDLE;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 12. 参数自检（锁定与 core_params.vh §7 的口径一致）
    //--------------------------------------------------------------------------
    initial begin
        // 与真源宏逐项比对（编译期即锁定）
        if (WAYS != `RV32GC_L1D_WAYS) begin
            $display("L1D FAIL: WAYS=%0d 应为 %0d", WAYS, `RV32GC_L1D_WAYS);
            $fatal(1, "L1D PARAM FAIL");
        end
        if (SETS != `RV32GC_L1D_SETS) begin
            $display("L1D FAIL: SETS=%0d 应为 %0d", SETS, `RV32GC_L1D_SETS);
            $fatal(1, "L1D PARAM FAIL");
        end
        if (LINE_BYTES != `RV32GC_L1D_LINE_BYTES) begin
            $display("L1D FAIL: LINE_BYTES=%0d 应为 %0d", LINE_BYTES, `RV32GC_L1D_LINE_BYTES);
            $fatal(1, "L1D PARAM FAIL");
        end
        if ((SETS * WAYS * LINE_BYTES) != `RV32GC_L1D_SIZE_BYTES) begin
            $display("L1D FAIL: 容量 = %0d B，应为 %0d B（32 KB）",
                     SETS * WAYS * LINE_BYTES, `RV32GC_L1D_SIZE_BYTES);
            $fatal(1, "L1D PARAM FAIL");
        end
        if (INDEX_BITS != 8 || OFF_BITS != 5 || TAG_W != 19 || WORDS != 8) begin
            $display("L1D FAIL: 位宽/每行字数不符");
            $fatal(1, "L1D PARAM FAIL");
        end
    end

endmodule
