//=============================================================================
// rv32_ifetch.v —— 取指单元（基线核：单行缓冲 + AXI 整行读）
//
// 功能：缓存当前 PC 所在的 32 B 行（16 个半字），向流水线提供 pc 处的两个半字：
//   hw0 = 半字[pc]，hw1 = 半字[pc+2]；若 hw0[1:0] != 2'b11 则为 16 位压缩指令，
//   否则由上层拼成 32 位指令（见 rv32gc_core.v）。
// 时序：line_valid=0 时发起 AXI 8-beat 读；数据返回后同拍/次拍可用。
// 说明：阶段 2A 后续会用带 TLB 的 I-Cache 替换本模块（接口保持不变）。
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

  // ---- D16② SPI-XIP 取指判定（由 rv32gc_core.v 用 `IS_SPI_XIP(fetch_pc) 算好）----
  input  wire         xip_bypass,     // 1 = 本次取指地址落在 SPI Flash XIP 窗口

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
  output wire         fetch_err
);

  reg [255:0] line_q;
  reg [31:0]  line_tag_q;      // PC[31:5]
  reg         line_vld_q;
  reg         busy_q;          // 正在等待 AXI 返回
  reg         err_q;           // 取指总线错误（sticky，flush 清除）
  /* verilator lint_off UNUSED */
  reg         line_xip_q;      // 本行来自 SPI-XIP 窗口？—— 2A-4 的 I-Cache 必须禁止其填充
  reg         req_xip_q;       // 在途请求行的窗口归属（请求发起拍采样，响应拍写入 line_xip_q）
  /* verilator lint_on UNUSED */

  //-----------------------------------------------------------------------------
  // D16② 「命中 SPI 窗口绕过 I-Cache」的判定点（本阶段无 Cache，行为不变）
  //
  // 本模块当前只有**单行取指缓冲** `line_q`：它是取指的功能性缓冲，去掉就取不到指令，
  // 不是 Cache，所以"绕过"在此阶段无行为差异。为使该约束**不可遗忘**，判定点在这里落地为
  // 两个信号：
  //   · xip_bypass —— 组合判定，本拍取指地址落在 SPI-XIP 窗口（`0x1C00_0000` 1 MiB 或
  //                   别名 `0x1FE8_0000` 64 KiB，见 `rv32gc_defs.vh` 的 `IS_SPI_XIP`）；
  //   · line_xip_q —— 填充时记录：当前缓冲行来自 XIP 窗口。
  // 阶段 2A-4 引入真正的 I-Cache 时**必须**用它们禁止 XIP 行被缓存：
  //   ① 填充侧：`line_xip_q=1` 的行不得写入 Cache 阵列 —— 不能只看请求侧的 xip_bypass，
  //      因为 Cache 命中的是**之前取过的行**；
  //   ② 请求侧：`xip_bypass=1` 时不得从 Cache 阵列命中，每拍都走总线 XIP 读。
  // 否则 XIP 读被缓存且平台无一致性维护 → 取指错乱（D16「否决原因③」）。
  //-----------------------------------------------------------------------------

  wire        hit = line_vld_q && (pc[31:5] == line_tag_q[31:5]);   // 比较行号（line_tag_q 存的是完整字节地址）
  assign line_valid = hit;
  assign if_rsp_ready = 1'b1;  // 收到即接收
  assign fetch_err    = err_q;

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
      end

      // 2) 冲刷：使当前行失效（后赋值优先），但不清 busy_q
      if (flush) begin
        line_vld_q   <= 1'b0;
        err_q        <= 1'b0;
        if_req_valid <= 1'b0;
      end

      // 3) 发起新取指（未命中、无在途请求、且本拍未冲刷）
      if (!hit && !busy_q && !if_req_valid && !flush && !err_q) begin
        if_req_valid <= 1'b1;
        if_req_addr  <= {pc[31:5], 5'b0};
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
