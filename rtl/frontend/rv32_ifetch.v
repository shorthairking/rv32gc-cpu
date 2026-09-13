//=============================================================================
// rv32_ifetch.v —— 取指单元（基线核：单行缓冲 + AXI 整行读）
//
// 功能：缓存当前 PC 所在的 32 B 行（16 个半字），向流水线提供 pc 处的两个半字：
//   hw0 = 半字[pc]，hw1 = 半字[pc+2]；若 hw0[1:0] != 2'b11 则为 16 位压缩指令，
//   否则由上层拼成 32 位指令（见 rv32gc_core.v）。
// 时序：line_valid=0 时发起整行请求；数据返回后同拍/次拍可用。
// 说明：行请求的下游从第 18 轮起是 **L1 指令 Cache**（`rtl/frontend/rv32_icache.v`，
//   16 KB/128 组/4 路/32 B、VIPT、RR 替换），命中 1 拍返回、缺失才发 AXI 读并填充；
//   本模块的请求/响应握手与直连 AXI 时完全一致（接口保持不变）。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_ifetch (
  input  wire         clk,
  input  wire         rst_n,

  input  wire [31:0]  pc,             // 当前取指地址（任意对齐，2 字节粒度）
  output wire [15:0]  hw0,
  output wire [15:0]  hw1,
  output wire         line_valid,     // 该 PC 所在行已就绪

  input  wire         flush,          // 重定向/异常：丢弃当前行

  // ---- MMU（Sv32）取指翻译结果（由 rv32mmu_top 组合给出）----
  //   pa_valid=1 才允许比对行标签/发请求；总线地址与行标签一律用 **PA**（同一个 PA 可映射到多个 VA）
  input  wire         pa_valid,       // 1 = pa 可用（无需翻译 / 翻译命中且权限+A/D 通过）
  input  wire [31:0]  pa,             // pc 对应的物理地址
  input  wire         xlate_fault,    // 取指页错误（cause 12）
  input  wire         xlate_fault_pf, // xlate_fault 的分类：1 = 页错误（cause 12）；
                                      // 0 = 访问错误（cause 1）—— 页表读被 PMP 拒绝或
                                      // 页表读总线错误，见 rv32mmu_top.if_fault_is_access

  // ---- D16② SPI-XIP 取指判定（由 rv32gc_core.v 用 `IS_SPI_XIP(pa) 算好）----
  input  wire         xip_bypass,     // 1 = 本次取指地址（PA）落在 SPI Flash XIP 窗口
  output wire         req_xip,        // 在途请求行的窗口归属（= req_xip_q）→ rv32_icache 判定点

  // ---- AXI 取指客户端（rv32_axi_master） ----
  output reg          if_req_valid,
  output reg  [31:0]  if_req_addr,
  input  wire         if_req_ready,
  input  wire         if_rsp_valid,
  input  wire [255:0] if_rsp_data,
  input  wire         if_rsp_err,
  output wire         if_rsp_ready,

  // ---- 取指总线错误（AXI 读响应 err）----
  // 出错的行**不填充**（line_vld_q 保持 0），错误保持到 flush（核取走陷阱后会 flush）。
  // 必须保持：否则核会在同一地址反复重试，或把没取到的行当指令执行。
  output wire         fetch_err,
  // ---- 取指页错误（MMU）：与总线错误共用"停止取指 + 等流水线排空"通道，但 cause=12 ----
  output wire         fetch_pf
);

  reg [255:0] line_q;
  reg [31:0]  line_tag_q;      // PC[31:5]
  reg         line_vld_q;
  reg         busy_q;          // 正在等待 AXI 返回
  reg         err_q;           // 取指错误（sticky，flush 清除）
  reg         err_pf_q;        // 上者的类型：1 = MMU 页错误（cause 12），0 = 总线错误（cause 1）
  /* verilator lint_off UNUSED */
  reg         line_xip_q;      // 本行来自 SPI-XIP 窗口？—— I-Cache 必须禁止其填充（本模块只缓冲，
                               //   真正的 Cache 填充判定在 rv32_icache 内按**请求地址**做）
  /* verilator lint_on UNUSED */
  reg         req_xip_q;       // 在途请求行的窗口归属（请求发起拍采样，响应拍写入 line_xip_q）
                               //   ⇒ 输出给 rv32_icache（D16② 请求侧判定点）

  assign req_xip = req_xip_q;

  //-----------------------------------------------------------------------------
  // D16② 「命中 SPI-XIP 窗口绕过 I-Cache」的判定点（第 18 轮：Cache 已上线）
  //
  // 本模块只有**单行取指缓冲** `line_q`（功能性缓冲，不是 Cache）。真正的 L1I 是
  // `rtl/frontend/rv32_icache.v`，插在本模块与 `rv32_axi_master` 之间并共用同一握手。
  // 判定点在这里落地为两个信号，接线见 `rv32gc_core.v`：
  //   · xip_bypass —— 组合判定，本拍取指地址（PA）落在 SPI-XIP 窗口（`0x1C00_0000` 1 MiB 或
  //                   别名 `0x1FE8_0000`，见 `rv32gc_defs.vh` 的 `IS_SPI_XIP`）；
  //   · req_xip_q  —— 在途请求行的窗口归属，输出 `req_xip` 给 `rv32_icache`：
  //                   ① 请求侧：XIP 请求**禁止命中**，每拍都走总线 XIP 读；
  //   · line_xip_q —— 响应到达时记录"本缓冲行来自 XIP 窗口"（本模块用，供调试观察）。
  // 填充侧禁令由 `rv32_icache` 按**在途请求地址**自行再判一次（填充发生在若干拍之后，
  // 必须看那一笔请求自己的窗口归属，不能只看请求侧的瞬态判定）。
  // 否则 XIP 读被缓存且平台无一致性维护 → 取指错乱（D16「否决原因③」）。
  //-----------------------------------------------------------------------------

  wire        hit = pa_valid && line_vld_q && (pa[31:5] == line_tag_q[31:5]);  // 比较**物理**行号
  assign line_valid = hit;
  assign if_rsp_ready = 1'b1;  // 收到即接收
  assign fetch_err    = err_q;
  assign fetch_pf     = err_pf_q;

  // 行内选择：半字索引 = pc[4:1]，第 idx 个半字位于位偏移 idx*16
  wire [3:0]  idx = pc[4:1];
  assign hw0 = line_q[{idx, 4'b0000} +: 16];
  assign hw1 = (idx == 4'd15) ? 16'd0 : line_q[{idx, 4'b0000} + 16 +: 16];

  always @(posedge clk) begin
    if (!rst_n) begin
      line_q      <= 256'd0;
      line_tag_q  <= 32'hFFFF_FFFF;
      line_vld_q  <= 1'b0;
      line_xip_q  <= 1'b0;
      req_xip_q   <= 1'b0;
      busy_q      <= 1'b0;
      err_q       <= 1'b0;
      err_pf_q    <= 1'b0;
      if_req_valid<= 1'b0;
      if_req_addr <= 32'd0;
    end else begin
      // 1) 接收 AXI 数据（即使同拍发生 flush 也要接收，否则 busy_q 会永久卡住）
      if (if_rsp_valid) begin
        line_q     <= if_rsp_data;
        line_tag_q <= if_req_addr;
        line_xip_q <= req_xip_q;   // D16②：记录本行是否来自 XIP 窗口（2A-4 禁止其入 Cache）
        busy_q     <= 1'b0;
        line_vld_q <= if_rsp_err ? 1'b0 : 1'b1;   // 总线错误 ⇒ 该行不可用
        err_q      <= if_rsp_err;                 // 并锁存错误直到 flush
        err_pf_q   <= 1'b0;                       // 总线错误（cause 1）
      end

      // 1b) MMU 取指页错误：同一"错误粘性 + 停止取指"通道，类型按 xlate_fault_pf 取
      //     （1 ⇒ cause 12 页错误；0 ⇒ cause 1 访问错误，见上游 if_fault_is_access）
      if (xlate_fault) begin
        err_q      <= 1'b1;
        err_pf_q   <= xlate_fault_pf;
        line_vld_q <= 1'b0;
      end

      // 2) 冲刷：使当前行失效（后赋值优先），但不清 busy_q
      if (flush) begin
        line_vld_q   <= 1'b0;
        err_q        <= 1'b0;
        err_pf_q     <= 1'b0;
        if_req_valid <= 1'b0;
      end

      // 3) 发起新取指（未命中、无在途请求、本拍未冲刷、PA 可用）
      //    ⚠ 必须用 pa_valid 门控：翻译未完成时发请求会取到**错误行**（VA 当 PA 用）
      if (!hit && !busy_q && !if_req_valid && !flush && !err_q && pa_valid) begin
        if_req_valid <= 1'b1;
        if_req_addr  <= {pa[31:5], 5'b0};   // 总线地址 = PA（行标签也由此而来）
        req_xip_q    <= xip_bypass;   // 采样"本请求行是否属于 SPI-XIP 窗口"
        busy_q       <= 1'b1;
      end

      // 4) 请求被接受
      if (if_req_valid && if_req_ready) begin
        if_req_valid <= 1'b0;
      end
    end
  end

endmodule
