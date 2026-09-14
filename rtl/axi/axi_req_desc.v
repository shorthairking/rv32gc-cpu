//==============================================================================
// rtl/axi/axi_req_desc.v —— AXI 请求描述符生成与地址窗口译码（PMA 表）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/08-baseline-5stage.md §7.1 要点 4/5/6、§7.2
//         docs/design/05-cache-memory.md §4.2、§5.2（PMA 表）
//
// 职责  :
//   ① **PMA 窗口译码**：把物理地址 PA 译成"存储类型 + 是否可缓存 + 是否必须核内截获"。
//      —— 08 §7.1 要点 6 要求本文件的窗口译码与 rtl/mem/mmio_route.v 的截获判定
//         **共用同一份 PMA 表，只写一次**。本文件即该表的唯一实现处：
//         mmio_route.v 应直接例化/复用本模块的输出，不得另写一份译码。
//   ② **AXI burst 描述符生成**：把一笔行填充/写回/uncached 访问翻译成
//      {addr, len, size, burst, cache, prot} 的 AXI 字段，并做
//      **4 K 边界拆分**（AXI 强制：一次突发不得跨越 4 KB）。
//   ③ 端口常量（08 §7.2）：AxSIZE=3'b010、AxLEN≤4'd15、AxLOCK=2'b00（高位显式置 0）、
//      ID 4 bit / LEN 4 bit / DATA 32 bit。
//
// ★ 地址寄存器唯一赋值点（08 §7.1 要点 3；AGENT.md §3.3）：
//   本模块**只接受物理地址**（paddr）。输出 desc_addr 由唯一一处组合逻辑生成，
//   不允许出现第二个赋值点，更不允许把 VA 接进来（VA/PA 混用是静默错）。
//
// ★ CLINT/PLIC 必须核内截获（05 §5.2 口径 3）：命中 0x1F00_0000/0x1F10_0000
//   ⇒ is_clint/is_plic 拉高、is_uncached 拉高，**禁止发 AXI**（平台 axi_mux 未占用
//   该区间，一旦放行会静默落到 DDR3 默认通路，写坏内存）。
//
// ★ 4 K 边界（08 §7.1 要点 5；05 §9 C-5）：
//   每笔突发的 beat 数受两个约束取小：
//     (a) 请求剩余 beat 数；
//     (b) 从当前地址到下一个 4 KB 边界可容纳的 beat 数。
//   若第一笔未覆盖全部请求 ⇒ split=1，由控制器发第二笔（地址接续）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module axi_req_desc #(
    parameter integer ADDR_W  = 32,
    parameter integer LEN_W   = 4,      // AxLEN 4 bit ⇒ ≤16 beat
    parameter integer SIZE_W  = 3,      // AxSIZE
    parameter integer BURST_W = 2,      // AxBURST
    parameter integer CACHE_W = 4,      // AxCACHE
    parameter integer PROT_W  = 3,      // AxPROT
    parameter integer ID_W    = 4       // AxID
) (
    //------------------------------------------------------------------
    // 请求（**物理地址**口径；VA/PA 不混用）
    //------------------------------------------------------------------
    input  wire                 req_valid,   // 有描述符请求
    input  wire [ADDR_W-1:0]    req_paddr,   // 请求起始物理地址
    input  wire [LEN_W:0]       req_beats,   // 请求 beat 数（1..16，不是"减一"）
    input  wire                 req_is_write,// 1 = 写（写回），0 = 读（填充）
    input  wire [ID_W-1:0]      req_id,      // AXI ID（2A 只用 4'd0，见 §7.2）

    //------------------------------------------------------------------
    // PMA 译码结果（**PMA 表唯一实现处**，供 mmio_route.v 共用）
    //------------------------------------------------------------------
    output wire                 pma_cacheable,  // 可缓存（Write-Back，可预取）
    output wire                 pma_uncached,   // 不可缓存（MMIO/XIP 外设区）
    output wire                 pma_is_ddr,     // DDR3 默认从设备
    output wire                 pma_is_xip,     // SPI Flash XIP 窗口（取指绕过 I-Cache）
    output wire                 pma_is_clint,   // 核内 CLINT ⇒ **绝不发 AXI**
    output wire                 pma_is_plic,    // 核内 PLIC  ⇒ **绝不发 AXI**
    output wire                 pma_is_apb,     // 平台 APB 外设（UART/NAND）
    output wire                 pma_is_confreg, // confreg（仿真/上板）
    output wire                 pma_is_mac,     // MAC（不使用）
    output wire                 pma_must_intercept, // 必须核内截获（CLINT/PLIC）

    //------------------------------------------------------------------
    // AXI 描述符（组合输出；唯一赋值点）
    //------------------------------------------------------------------
    output wire                 desc_valid,  // 描述符有效
    output wire [ADDR_W-1:0]    desc_addr,   // AxADDR（物理地址）
    output wire [LEN_W-1:0]     desc_len,    // AxLEN（beat 数 - 1）
    output wire [SIZE_W-1:0]    desc_size,   // AxSIZE = 3'b010
    output wire [BURST_W-1:0]   desc_burst,  // AxBURST = INCR/WRAP
    output wire [CACHE_W-1:0]   desc_cache,  // AxCACHE
    output wire [PROT_W-1:0]    desc_prot,   // AxPROT
    output wire [2:0]           desc_lock,   // AxLOCK（**高位显式 0**，平台只接 [0:0]）
    output wire [ID_W-1:0]      desc_id,     // AxID
    output wire [LEN_W:0]       desc_beats,  // 本笔实际 beat 数（1..16）
    output wire                 desc_split,  // 1 = 需拆第二笔（跨 4 K）
    output wire                 desc_legal,  // 0 = 本笔不可发 AXI（如 CLINT/PLIC）
    output wire [LEN_W:0]       desc_to_4k   // 到下一个 4 K 边界还能放多少 beat（信息）
);
    //--------------------------------------------------------------------------
    // 1. PMA 窗口译码（**唯一实现处**；05 §5.2 的 PMA 表）
    //--------------------------------------------------------------------------
    // DDR3：PA[31:28] == 4'h0 ⇒ 可缓存（05 §5.2 首个判定节点）
    wire is_ddr = (req_paddr[31:28] == `RV32GC_DDR_HI4_VAL);

    // SPI XIP：PA[31:20]==12'h1C0（主窗口）或 PA[31:16]==16'h1FE8（别名）
    wire is_xip_hi20 = ((req_paddr[31:20] & `RV32GC_XIP_HI20_MSK) == `RV32GC_XIP_HI20_VAL);
    wire is_xip_hi16 = (req_paddr[31:16] == `RV32GC_SPI_HIT_VAL);
    wire is_xip      = is_xip_hi20 | is_xip_hi16;

    // 核内 CLINT / PLIC：必须核内截获，绝不发 AXI（05 §5.2 口径 3）
    wire is_clint = ((req_paddr[31:16] & `RV32GC_CLINT_HIT_MSK) == `RV32GC_CLINT_HIT_VAL);
    wire is_plic  = ((req_paddr[31:16] & `RV32GC_CLINT_HIT_MSK) == `RV32GC_PLIC_HIT_VAL);

    // 平台外设区：UART / NAND（APB）、confreg（仿真/上板）、MAC
    wire is_uart    = (req_paddr[31:16] == `RV32GC_APB_UART_VAL);
    wire is_nand    = (req_paddr[31:16] == `RV32GC_APB_NAND_VAL);
    wire is_apb     = is_uart | is_nand;
    wire is_conf_sim= (req_paddr[31:16] == `RV32GC_CONF_SIM_VAL);
    wire is_conf_syn= (req_paddr[31:16] == `RV32GC_CONF_SYN_VAL);
    wire is_confreg = is_conf_sim | is_conf_syn;
    wire is_mac     = (req_paddr[31:16] == `RV32GC_MAC_HIT_VAL);

    assign pma_is_ddr        = is_ddr;
    assign pma_is_xip        = is_xip;
    assign pma_is_clint      = is_clint;
    assign pma_is_plic       = is_plic;
    assign pma_is_apb        = is_apb;
    assign pma_is_confreg    = is_confreg;
    assign pma_is_mac        = is_mac;
    assign pma_must_intercept= is_clint | is_plic;

    // 可缓存 = 仅 DDR3；其余一律不可缓存（外设有副作用 / XIP 无一致性）
    assign pma_cacheable = is_ddr;
    assign pma_uncached  = ~is_ddr;

    //--------------------------------------------------------------------------
    // 2. 4 K 边界拆分（08 §7.1 要点 5；AXI 强制不得跨 4 KB）
    //    全部用显式位宽的无符号算术（LEN_W+1 = 5 bit 足以表示 0..31 beat）
    //--------------------------------------------------------------------------
    localparam [LEN_W:0] BEATS_MAX    = {1'b0, `RV32GC_AXI_LEN_MAX} + 5'd1;  // 16
    localparam [LEN_W:0] BEATS_ONE    = 5'd1;
    localparam [12:0]    BYTES_4K     = 13'd4096;

    // 当前地址到下一个 4 K 边界的剩余字节数（off==0 时为 4096）
    wire [11:0]    off_in_4k    = req_paddr[11:0];
    wire [12:0]    bytes_to_4k  = BYTES_4K - {1'b0, off_in_4k};
    // 可放 beat 数 = bytes_to_4k / 4（4 B/beat），13 bit 右移 2 ⇒ 11 bit（0..1024）
    wire [10:0]    beats_4k_raw = bytes_to_4k[12:2];
    // 5 bit 饱和：只要 ≥16 就直接饱和到 16（拆分判定只需要 min 的正确性）
    wire [LEN_W:0] beats_to_4k  = (beats_4k_raw >= {6'b0, BEATS_MAX})
                                ? BEATS_MAX
                                : {6'b0, beats_4k_raw[3:0]};

    // 请求 beat 数先按 AXI 上限（16）截断
    wire [LEN_W:0] req_capped   = (req_beats > BEATS_MAX) ? BEATS_MAX : req_beats;

    // 本笔 beat 数 = min(req_capped, beats_to_4k)；保底 ≥ 1
    wire [LEN_W:0] beats_min    = (beats_to_4k < req_capped) ? beats_to_4k : req_capped;
    wire [LEN_W:0] beats_this   = (beats_min < BEATS_ONE) ? BEATS_ONE : beats_min;

    // 是否还有剩余（需拆第二笔）
    wire [LEN_W:0] beats_remain = req_capped - beats_this;

    assign desc_beats  = beats_this;
    assign desc_split  = (beats_remain != {LEN_W+1{1'b0}});
    assign desc_to_4k  = beats_to_4k;

    //--------------------------------------------------------------------------
    // 3. AXI 字段生成（08 §7.2 端口常量）
    //--------------------------------------------------------------------------
    assign desc_addr  = req_paddr;                        // **物理地址唯一赋值点**
    assign desc_len   = beats_this[LEN_W-1:0] - 4'd1;     // AxLEN = beat 数 - 1
    assign desc_size  = `RV32GC_AXI_SIZE_4B;              // 3'b010（4 B）
    // 行填充用 INCR（WRAP 仅用于 2A 之后的 L1I 半行对齐；此处统一 INCR 更保守）
    assign desc_burst = `RV32GC_AXI_BURST_INCR;           // 2'b01
    // 缓存属性：可缓存行填充用 1111；MMIO/XIP 用 0000
    assign desc_cache = pma_cacheable ? `RV32GC_AXI_CACHE_CACHED
                                      : `RV32GC_AXI_CACHE_UNCACHED;
    assign desc_prot  = `RV32GC_AXI_PROT_DATA;            // 3'b010
    assign desc_lock  = {1'b0, `RV32GC_AXI_LOCK_NORMAL};  // 高位显式 0
    assign desc_id    = req_id;

    // 合法性：命中核内截获窗口 ⇒ 不得发 AXI；无请求 ⇒ 无效
    assign desc_legal = req_valid & ~pma_must_intercept;
    assign desc_valid = req_valid;

    //--------------------------------------------------------------------------
    // 4. 参数自检
    //--------------------------------------------------------------------------
    initial begin
        if (LEN_W != 4) begin
            $display("AXI_REQ_DESC FAIL: LEN_W=%0d 应等于 4（平台 config.h）", LEN_W);
            $fatal(1, "AXI_REQ_DESC PARAM FAIL");
        end
        if (ADDR_W != 32 || ID_W != 4) begin
            $display("AXI_REQ_DESC FAIL: ADDR_W/ID_W 应为 32/4");
            $fatal(1, "AXI_REQ_DESC PARAM FAIL");
        end
        if (`RV32GC_AXI_SIZE_4B != 3'b010 || `RV32GC_AXI_LEN_MAX != 4'd15) begin
            $display("AXI_REQ_DESC FAIL: size/len 常量不符");
            $fatal(1, "AXI_REQ_DESC PARAM FAIL");
        end
    end

endmodule
