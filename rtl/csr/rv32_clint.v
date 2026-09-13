//=============================================================================
// rv32_clint.v —— 核内 CLINT（Core Local INTerruptor，hart0）
//   · 决策 D5：CLINT 基址 0x1F00_0000，**核内截获、不下 AXI**（chiplab 平台没有
//     该窗口；核内实现才能让标准 RISC-V 内核驱动/OpenSBI 直接工作）。
//   · 寄存器（偏移相对 `CLINT_BASE，rtl/pkg/rv32gc_defs.vh:129）：
//       0x0000  msip      (32 位，仅 bit0 有效，RW)      → mip.MSIP (bit 3)
//       0x4000  mtimecmp_lo   0x4004  mtimecmp_hi   (64 位比较值，RW)
//       0xBFF8  mtime_lo      0xBFFC  mtime_hi      (64 位自由运行计数，RW)
//   · 复位全 0；未实现偏移**读 0、写忽略**（见"本设计取舍"）。
//
// 规范出处（路径相对 workspace 根 /home/shorthair/dsh/rv32-cpu）
//   [1] riscv-isa-manual/src/priv/machine.adoc:2512-2587
//         mtime/mtimecmp 为 memory-mapped 机器级定时器；简单固定频率系统可让
//         mtime 与核时钟同频（我们的实现：mtime = 核时钟计数）
//   [2] riscv-isa-manual/src/priv/machine.adoc:2525-2527
//         mtime 溢出回绕（64 位无符号计数器）
//   [3] riscv-isa-manual/src/priv/machine.adoc:2531-2536 (norm:mtimeintrmtip)
//         mtime >= mtimecmp ⇒ MTIP 挂起；写 mtimecmp > mtime 撤销
//   [4] riscv-isa-manual/src/priv/machine.adoc:2593-2596 (norm:mtimeintrmtip_visibility)
//         比较结果变化"最终但不立即"反映到 MTIP，允许毛刺 → 本模块用寄存器输出
//   [5] riscv-isa-manual/src/priv/machine.adoc:2598-2612 (norm:mtimecmprv32wr)
//         RV32：对 mtimecmp 的写只改 32 位一半；规范给出的写序是
//         "先写 -1 到低半 → 写高半 → 最后写低半"，避免中间值产生伪中断
//   [6] riscv-isa-manual/src/priv/machine.adoc:1416-1418 (norm:msipszacc/msip_enc)
//         msip 是 32 位 RW 寄存器，bit[31:1] 读 0，bit0 即 mip.MSIP
//   [7] riscv-isa-manual/src/priv/machine.adoc:1401-1414 (norm:mipmtiprdonly 等)
//         mip.MTIP / mip.MSIP 只读，由 memory-mapped 定时器/软件中断寄存器驱动
//   [8] docs/design/spec/07-priv-csr-mmu.md:416-436（§8.1 本项目 CLINT 规格）
//         第 426-427 行的比较式与 **suppress 触发器**要求；第 434 行：
//         "写高半若会导致 mtimecmp<mtime，须抑制一次中断"
//   [9] rtl/pkg/rv32gc_defs.vh:129  `CLINT_BASE = 32'h1F00_0000
//
// 本设计取舍（规范留有余地处，均已在单元测试中固化为期望值）
//   · **mtime 的时基**：仿真环境没有独立时基，"按真实时间"不可实现，故
//     mtime 直接**按核时钟每拍 +1**（`tick` 使能，主 Agent 接常量 1'b1）。
//     在 FPGA 上若要让 mtime 表示墙钟时间，应由 tick 端按分频后的 1 Hz 驱动。
//     这是明确写下的近似，不是"真实时间"。
//   · **suppress 触发器**（[8] 第 434 行，为兼容 [5] 的 RV32 写序）：
//       写 mtimecmp 高半时，若拼出的候选值 {new_hi, mtimecmp_lo} < mtime，
//       则 suppress<=1（mtip 强制 0），直到**下一次写 mtimecmp 低半**时清 0。
//       正常顺序（低半最后写）下 suppress 不会残留，mtip 恒等于
//       (mtime >= mtimecmp)；只有"只写高半/先写高半且候选值偏小"的瞬间被抑制。
//   · **写与递增同拍**：写 mtime 的那一拍不递增（写优先），即 mtime 的更新值为
//     写入值，而不是"写入值 + 1"。软件可据此精确定时。
//   · **字节使能**：msip / mtime / mtimecmp 均支持 sw/sh/sb（按 wstrb 逐字节合并）。
//     写 msip 时只有 wstrb[0] 覆盖到 byte0 才更新 bit0。
//   · **未实现偏移**：读返回 32'h0、写忽略（不产生副作用、不报错）。选 0 而不是
//     X，是为了让驱动探测寄存器时得到确定值。
//   · `rdata` 只由 `addr` 译码，不受 `req` 门控（调用方在 req && !we 时采样）。
//   · 地址译码用**完整 32 位偏移**精确比较，不做窗口内别名（1 MiB 窗口内非
//     寄存器地址一律落到 default 分支）。
//=============================================================================
`include "rv32gc_defs.vh"        // 仅用 `CLINT_BASE（rv32gc_defs.vh:129）

module rv32_clint (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        tick,        // mtime 递增使能：本拍 +1（核集成时接 1'b1，见文件头"时基"）
  // ---- 核内访存窗口（命中本窗口时由核内应答，不产生 AXI 请求）----
  input  wire        req,         // 本拍有效访问落在 CLINT 窗口内
  input  wire        we,          // 1=写 0=读
  input  wire [31:0] addr,        // **完整地址**（本模块内部按偏移译码）
  input  wire [3:0]  wstrb,       // 字节使能（支持 sw/sh/sb）
  input  wire [31:0] wdata,
  output wire [31:0] rdata,       // 组合读数据（req && !we 时有效）
  // ---- 中断输出（到 rv32_csr 的 mip）----
  output wire        msip,        // → mip.MSIP (bit 3)
  output wire        mtip         // → mip.MTIP (bit 7)：mtime >= mtimecmp
);

  //---------------------------------------------------------------------------
  // 寄存器偏移（相对 `CLINT_BASE）
  //---------------------------------------------------------------------------
  localparam [31:0] OFF_MSIP     = 32'h0000_0000;
  localparam [31:0] OFF_CMP_LO   = 32'h0000_4000;
  localparam [31:0] OFF_CMP_HI   = 32'h0000_4004;
  localparam [31:0] OFF_TIME_LO  = 32'h0000_BFF8;
  localparam [31:0] OFF_TIME_HI  = 32'h0000_BFFC;

  //---------------------------------------------------------------------------
  // 状态
  //---------------------------------------------------------------------------
  reg        msip_r;        // mip.MSIP
  reg [63:0] mtime_r;       // 自由运行计数器（核时钟计数，见文件头"时基"）
  reg [63:0] mtimecmp_r;    // 64 位比较值
  reg        cmp_supp;      // 写 mtimecmp 高半引起"候选值偏小"时的一次性抑制

  //---------------------------------------------------------------------------
  // 地址译码 / 命中
  //---------------------------------------------------------------------------
  wire [31:0] off = addr - `CLINT_BASE;

  wire wr        = req & we;
  wire hit_msip  = req & (off == OFF_MSIP);
  wire hit_cmp_lo = wr & (off == OFF_CMP_LO);
  wire hit_cmp_hi = wr & (off == OFF_CMP_HI);
  wire hit_time_lo = wr & (off == OFF_TIME_LO);
  wire hit_time_hi = wr & (off == OFF_TIME_HI);

  //---------------------------------------------------------------------------
  // 按 wstrb 逐字节合并（sw/sh/sb 统一走这一条路径）
  //---------------------------------------------------------------------------
  function [31:0] byte_merge;
    input [31:0] old_v;
    input [31:0] new_v;
    input [3:0]  strb;
    integer i;
    begin
      for (i = 0; i < 4; i = i + 1) begin
        if (strb[i]) byte_merge[8*i +: 8] = new_v[8*i +: 8];
        else         byte_merge[8*i +: 8] = old_v[8*i +: 8];
      end
    end
  endfunction

  wire [31:0] msip_nxt   = byte_merge({31'b0, msip_r}, wdata, wstrb);
  wire [31:0] cmp_hi_new = byte_merge(mtimecmp_r[63:32], wdata, wstrb);
  // 候选比较值：本次写高半后（低半仍是旧值）的 64 位值 —— [8] 第 434 行的判据
  wire [63:0] cmp_cand   = {cmp_hi_new, mtimecmp_r[31:0]};

  //---------------------------------------------------------------------------
  // 时序：msip / mtime / mtimecmp / suppress
  //---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      msip_r     <= 1'b0;
      mtime_r    <= 64'd0;
      mtimecmp_r <= 64'd0;
      cmp_supp   <= 1'b0;
    end else begin
      // ---- msip：只有 byte0 的字节使能覆盖且新值 bit0 有效 ----
      if (hit_msip && wr)
        msip_r <= msip_nxt[0];

      // ---- mtime：写优先于递增（写的那一拍不 +1）----
      if (hit_time_lo)
        mtime_r[31:0]  <= byte_merge(mtime_r[31:0],  wdata, wstrb);
      else if (hit_time_hi)
        mtime_r[63:32] <= byte_merge(mtime_r[63:32], wdata, wstrb);
      else if (tick)
        mtime_r        <= mtime_r + 64'd1;

      // ---- mtimecmp：写低半清 suppress；写高半按候选值判是否抑制一次 ----
      if (hit_cmp_lo) begin
        mtimecmp_r[31:0]  <= byte_merge(mtimecmp_r[31:0],  wdata, wstrb);
        cmp_supp          <= 1'b0;
      end else if (hit_cmp_hi) begin
        mtimecmp_r[63:32] <= cmp_hi_new;
        cmp_supp          <= (cmp_cand < mtime_r);
      end
    end
  end

  //---------------------------------------------------------------------------
  // 中断输出（组合，规范 [4] 允许"最终但不立即"）
  //---------------------------------------------------------------------------
  assign msip = msip_r;
  assign mtip = (mtime_r >= mtimecmp_r) & ~cmp_supp;   // 64 位无符号比较

  //---------------------------------------------------------------------------
  // 读数据（组合；未实现偏移读 0）
  //---------------------------------------------------------------------------
  reg [31:0] rdata_r;
  always @(*) begin
    case (off)
      OFF_MSIP:    rdata_r = {31'b0, msip_r};
      OFF_CMP_LO:  rdata_r = mtimecmp_r[31:0];
      OFF_CMP_HI:  rdata_r = mtimecmp_r[63:32];
      OFF_TIME_LO: rdata_r = mtime_r[31:0];
      OFF_TIME_HI: rdata_r = mtime_r[63:32];
      default:     rdata_r = 32'h0000_0000;
    endcase
  end

  assign rdata = rdata_r;

endmodule
