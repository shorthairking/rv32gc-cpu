//=============================================================================
// tb_clint_plic.v —— 核内 CLINT（rv32_clint）+ PLIC（rv32_plic）单元测试
//   自校验：期望值全部来自规范/设计规格手算，不用被测 RTL 的输出回填。
//
// 规范出处（路径相对 workspace 根 /home/shorthair/dsh/rv32-cpu）
//   [1] riscv-isa-manual/src/priv/machine.adoc:2512-2587  mtime/mtimecmp（64 位、可写）
//   [2] riscv-isa-manual/src/priv/machine.adoc:2525-2527  计数器回绕
//   [3] riscv-isa-manual/src/priv/machine.adoc:2531-2536  mtime>=mtimecmp ⇒ MTIP
//   [4] riscv-isa-manual/src/priv/machine.adoc:2593-2596  MTIP 变化"最终但不立即"
//   [5] riscv-isa-manual/src/priv/machine.adoc:2598-2612  RV32 写 mtimecmp 的安全写序
//   [6] riscv-isa-manual/src/priv/machine.adoc:1416-1418  msip bit[31:1] 读 0、bit0
//   [7] docs/design/spec/07-priv-csr-mmu.md:416-436      本项目 CLINT 规格（含 suppress）
//   [8] docs/design/spec/07-priv-csr-mmu.md:438-453      PLIC 寄存器映射（SiFive 兼容）
//   [9] docs/design/spec/07-priv-csr-mmu.md:455-470      PLIC gateway/claim/complete 流程
//
// 计数口径：每个 chk1/chk32 调用 = 1 个 check；比对使用 !==（case inequality），
//   任何 X/Z 都判 FAIL。成功打印 "CLINT_PLIC_UNIT: PASS (<N> checks)"；
//   失败打印每条 [FAIL] 明细 + "CLINT_PLIC_UNIT: FAIL (<m>/<N>)" 并以非零状态退出（$fatal）。
//
// 已固化在期望值里的两处"本设计取舍"（见 rv32_clint.v / rv32_plic.v 文件头）：
//   · CLINT 写 mtime 与 tick 递增同拍时**写优先**（写的那一拍不 +1）—— C3.8。
//   · CLINT 写 mtimecmp 高半若使候选值 < mtime 则 suppress 一次中断，直到写低半 —— C5.*。
//   · 复位时 mtime=mtimecmp=0 ⇒ mtip=1（比较式天然结果，与真实 CLINT 一致）—— C1.7。
//=============================================================================
`timescale 1ns/1ps
`include "rv32gc_defs.vh"

module tb_clint_plic;

  //---------------------------------------------------------------------------
  // 时钟
  //---------------------------------------------------------------------------
  reg clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n;
  initial rst_n = 1'b0;

  //---------------------------------------------------------------------------
  // DUT 接口
  //---------------------------------------------------------------------------
  // CLINT 偏移
  localparam [31:0] C_MSIP    = 32'h0000_0000;
  localparam [31:0] C_CMP_LO  = 32'h0000_4000;
  localparam [31:0] C_CMP_HI  = 32'h0000_4004;
  localparam [31:0] C_TIME_LO = 32'h0000_BFF8;
  localparam [31:0] C_TIME_HI = 32'h0000_BFFC;

  // PLIC 偏移（SiFive PLIC 1.0.0：ctx 步长 0x1000）
  localparam [31:0] P_PEND = 32'h0000_1000;
  localparam [31:0] P_EN0  = 32'h0000_2000;
  localparam [31:0] P_EN1  = 32'h0000_2080;
  localparam [31:0] P_THR0 = 32'h0020_0000;
  localparam [31:0] P_THR1 = 32'h0020_1000;
  localparam [31:0] P_CLM0 = 32'h0020_0004;
  localparam [31:0] P_CLM1 = 32'h0020_1004;

  reg         c_req, c_we, c_tick;
  reg  [31:0] c_addr, c_wdata;
  reg  [3:0]  c_wstrb;
  wire [31:0] c_rdata;
  wire        c_msip, c_mtip;

  reg         p_req, p_we;
  reg  [31:0] p_addr, p_wdata;
  reg  [3:0]  p_wstrb;
  reg  [7:0]  p_src;
  wire [31:0] p_rdata;
  wire        p_meip, p_seip;

  rv32_clint dut_clint (
    .clk   (clk),
    .rst_n (rst_n),
    .tick  (c_tick),
    .req   (c_req),
    .we    (c_we),
    .addr  (c_addr),
    .wstrb (c_wstrb),
    .wdata (c_wdata),
    .rdata (c_rdata),
    .msip  (c_msip),
    .mtip  (c_mtip)
  );

  rv32_plic #(.NSRC(8)) dut_plic (
    .clk   (clk),
    .rst_n (rst_n),
    .src   (p_src),
    .req   (p_req),
    .we    (p_we),
    .addr  (p_addr),
    .wstrb (p_wstrb),
    .wdata (p_wdata),
    .rdata (p_rdata),
    .meip  (p_meip),
    .seip  (p_seip)
  );

  //---------------------------------------------------------------------------
  // 计数
  //---------------------------------------------------------------------------
  integer n_check, n_fail;
  reg [8*96-1:0] nm;
  integer k, i;
  reg [31:0] rv;

  //---------------------------------------------------------------------------
  // 基础驱动任务
  //---------------------------------------------------------------------------
  task reset_all;
    begin
      rst_n   = 1'b0;
      c_req   = 1'b0; c_we = 1'b0; c_addr = 32'h0; c_wdata = 32'h0;
      c_wstrb = 4'h0; c_tick = 1'b0;
      p_req   = 1'b0; p_we = 1'b0; p_addr = 32'h0; p_wdata = 32'h0;
      p_wstrb = 4'h0; p_src = 8'h0;
      repeat (3) @(posedge clk);
      #1;
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
      #1;
    end
  endtask

  // CLINT 单拍写（副作用在该拍上升沿提交）
  task cw;
    input [31:0] off;
    input [31:0] data;
    input [3:0]  strb;
    begin
      c_addr  = `CLINT_BASE + off;
      c_we    = 1'b1;
      c_wstrb = strb;
      c_wdata = data;
      c_req   = 1'b1;
      @(posedge clk);
      #1;
      c_req   = 1'b0;
      c_we    = 1'b0;
      c_wstrb = 4'h0;
      c_wdata = 32'h0;
    end
  endtask

  // CLINT 组合读（先采样、后过一拍）
  task cr;
    input  [31:0] off;
    output [31:0] val;
    begin
      c_addr  = `CLINT_BASE + off;
      c_we    = 1'b0;
      c_wstrb = 4'h0;
      c_req   = 1'b1;
      #1;
      val = c_rdata;
      @(posedge clk);
      #1;
      c_req = 1'b0;
    end
  endtask

  // tick 拉高恰好 n 拍（= mtime +n），结束时 tick 落回 0
  task ctick;
    input integer n;
    begin
      c_tick = 1'b1;
      for (i = 0; i < n; i = i + 1) begin
        @(posedge clk);
        #1;
      end
      c_tick = 1'b0;
    end
  endtask

  // PLIC 单拍写
  task pw;
    input [31:0] off;
    input [31:0] data;
    input [3:0]  strb;
    begin
      p_addr  = `PLIC_BASE + off;
      p_we    = 1'b1;
      p_wstrb = strb;
      p_wdata = data;
      p_req   = 1'b1;
      @(posedge clk);
      #1;
      p_req   = 1'b0;
      p_we    = 1'b0;
      p_wstrb = 4'h0;
      p_wdata = 32'h0;
    end
  endtask

  // PLIC 组合读（claim 的副作用在该拍上升沿提交；先采样再放行时钟）
  task pr;
    input  [31:0] off;
    output [31:0] val;
    begin
      p_addr  = `PLIC_BASE + off;
      p_we    = 1'b0;
      p_wstrb = 4'h0;
      p_req   = 1'b1;
      #1;
      val = p_rdata;
      @(posedge clk);
      #1;
      p_req = 1'b0;
    end
  endtask

  // 空转 n 拍（req 拉低）
  task pstep;
    input integer n;
    begin
      p_req = 1'b0;
      p_we  = 1'b0;
      for (i = 0; i < n; i = i + 1) begin
        @(posedge clk);
        #1;
      end
    end
  endtask

  // 设置平台源电平并空转 2 拍（让 gateway 锁存）
  task psrc;
    input [7:0] v;
    begin
      p_src = v;
      pstep(2);
    end
  endtask

  //---------------------------------------------------------------------------
  // 检查任务（!== 比较：X/Z 一律 FAIL）
  //---------------------------------------------------------------------------
  task chk32;
    input [8*96-1:0] name;
    input [31:0]     exp;
    input [31:0]     got;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: exp=%08x got=%08x", name, exp, got);
      end
    end
  endtask

  task chk1;
    input [8*96-1:0] name;
    input            exp;
    input            got;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: exp=%b got=%b", name, exp, got);
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // 看门狗（正常流程几微秒结束；1 ms 未结束视为挂死）
  //---------------------------------------------------------------------------
  initial begin
    #1_000_000;
    $display("[FAIL] watchdog timeout: 仿真未在 1ms 内结束");
    $fatal;
  end

  //---------------------------------------------------------------------------
  // 主流程
  //---------------------------------------------------------------------------
  initial begin
    n_check = 0;
    n_fail  = 0;

    //=======================================================================
    // 第 1 部分：CLINT
    //=======================================================================
    //---- C1 复位值 ------------------------------------------------------
    reset_all;
    cr(C_MSIP, rv);    chk32("C1.1 msip 复位读 0", 32'h0, rv);
    chk1 ("C1.2 msip 复位输出 0", 1'b0, c_msip);
    cr(C_TIME_LO, rv); chk32("C1.3 mtime_lo 复位 0", 32'h0, rv);
    cr(C_TIME_HI, rv); chk32("C1.4 mtime_hi 复位 0", 32'h0, rv);
    cr(C_CMP_LO, rv);  chk32("C1.5 mtimecmp_lo 复位 0", 32'h0, rv);
    cr(C_CMP_HI, rv);  chk32("C1.6 mtimecmp_hi 复位 0", 32'h0, rv);
    chk1 ("C1.7 复位 mtime=mtimecmp=0 ⇒ mtip=1（比较式天然结果）", 1'b1, c_mtip);

    //---- C2 msip（RW，仅 bit0；含 wstrb）--------------------------------
    reset_all;
    cw(C_MSIP, 32'h0000_0001, 4'hF);
    cr(C_MSIP, rv); chk32("C2.1 msip 写 1 读回 1", 32'h1, rv);
    chk1 ("C2.2 msip 写 1 输出拉高", 1'b1, c_msip);
    cw(C_MSIP, 32'hFFFF_FFFF, 4'hF);
    cr(C_MSIP, rv); chk32("C2.3 msip 写全 1 只读回 bit0（[31:1] 恒 0）", 32'h1, rv);
    chk1 ("C2.4 msip 保持 1", 1'b1, c_msip);
    cw(C_MSIP, 32'h0000_0000, 4'hF);
    cr(C_MSIP, rv); chk32("C2.5 msip 写 0 读回 0", 32'h0, rv);
    chk1 ("C2.6 msip 写 0 输出落 0", 1'b0, c_msip);
    cw(C_MSIP, 32'h0000_0001, 4'b0001);
    cr(C_MSIP, rv); chk32("C2.7 msip sb(byte0)=1 置位", 32'h1, rv);
    cw(C_MSIP, 32'h0000_0000, 4'b0010);
    cr(C_MSIP, rv); chk32("C2.8 msip 写 byte1（wstrb 不含 byte0）不变", 32'h1, rv);
    cw(C_MSIP, 32'h0000_0000, 4'b0001);
    cr(C_MSIP, rv); chk32("C2.9 msip sb(byte0)=0 清零", 32'h0, rv);

    //---- C3 mtime 递增 / 写两半 / 回绕 / 与 tick 同拍 -------------------
    reset_all;
    ctick(10);
    cr(C_TIME_LO, rv); chk32("C3.1 mtime 10 拍后 lo=10", 32'd10, rv);
    cr(C_TIME_HI, rv); chk32("C3.2 mtime hi=0", 32'h0, rv);
    ctick(5);
    cr(C_TIME_LO, rv); chk32("C3.3 再 5 拍 lo=15", 32'd15, rv);
    cw(C_TIME_LO, 32'h0000_0100, 4'hF);
    cr(C_TIME_LO, rv); chk32("C3.4 写 mtime_lo=0x100 读回", 32'h100, rv);
    cr(C_TIME_HI, rv); chk32("C3.5 写 mtime_lo 不影响 hi", 32'h0, rv);
    cw(C_TIME_HI, 32'h0000_0001, 4'hF);
    cr(C_TIME_LO, rv); chk32("C3.6 写 mtime_hi 不影响 lo", 32'h100, rv);
    cr(C_TIME_HI, rv); chk32("C3.7 写 mtime_hi=1 读回", 32'h1, rv);
    c_tick = 1'b1;
    cw(C_TIME_LO, 32'h0000_2000, 4'hF);      // 与 tick 同拍：写优先，不 +1
    ctick(3);                                 // 之后 3 拍 +3（ctick 结束时 tick=0）
    cr(C_TIME_LO, rv); chk32("C3.8 写 mtime 与 tick 同拍：写优先（0x2000+3）", 32'h2003, rv);
    cr(C_TIME_HI, rv); chk32("C3.9 mtime hi 保持 1", 32'h1, rv);
    // 32 位进位
    cw(C_TIME_HI, 32'h0000_0000, 4'hF);
    cw(C_TIME_LO, 32'hFFFF_FFFF, 4'hF);
    cr(C_TIME_LO, rv); chk32("C3.10 写 mtime_lo=0xFFFFFFFF", 32'hFFFF_FFFF, rv);
    ctick(1);
    cr(C_TIME_LO, rv); chk32("C3.11 进位后 lo=0", 32'h0, rv);
    cr(C_TIME_HI, rv); chk32("C3.12 进位后 hi=1", 32'h1, rv);
    // 64 位比较跨 32 位边界：cmp={1,0} 与 mtime={1,0}
    cw(C_CMP_HI, 32'h0000_0001, 4'hF);
    cw(C_CMP_LO, 32'h0000_0000, 4'hF);
    chk1 ("C3.13 mtime={1,0} >= cmp={1,0} ⇒ mtip=1", 1'b1, c_mtip);
    cw(C_CMP_HI, 32'h0000_0001, 4'hF);
    cw(C_CMP_LO, 32'h0000_0001, 4'hF);       // cmp = mtime+1
    chk1 ("C3.14 cmp=mtime+1 ⇒ mtip=0", 1'b0, c_mtip);
    ctick(1);                                 // mtime = {1,1} = cmp
    cr(C_TIME_LO, rv); chk32("C3.15 进位后 mtime lo=1", 32'h1, rv);
    chk1 ("C3.16 mtime 到点 ⇒ mtip=1", 1'b1, c_mtip);

    //---- C4 mtip 边界：mtimecmp = mtime-1 / = mtime / = mtime+1 --------
    reset_all;
    cw(C_TIME_HI, 32'h0, 4'hF);
    cw(C_TIME_LO, 32'd100, 4'hF);
    cr(C_TIME_LO, rv); chk32("C4.1 构造 mtime=100", 32'd100, rv);
    cw(C_CMP_HI, 32'h0, 4'hF);
    cw(C_CMP_LO, 32'd100, 4'hF);             // cmp == mtime
    chk1 ("C4.2 cmp==mtime ⇒ mtip=1", 1'b1, c_mtip);
    cw(C_CMP_HI, 32'h0, 4'hF);
    cw(C_CMP_LO, 32'd101, 4'hF);             // cmp == mtime+1
    chk1 ("C4.3 cmp=mtime+1 ⇒ mtip=0", 1'b0, c_mtip);
    ctick(1);
    chk1 ("C4.4 mtime 追平 cmp ⇒ mtip=1", 1'b1, c_mtip);
    cw(C_CMP_HI, 32'h0, 4'hF);
    cw(C_CMP_LO, 32'd100, 4'hF);             // cmp == mtime-1
    chk1 ("C4.5 cmp=mtime-1 ⇒ mtip=1", 1'b1, c_mtip);
    cw(C_CMP_HI, 32'h0, 4'hF);
    cw(C_CMP_LO, 32'd102, 4'hF);             // cmp == mtime+1，撤销挂起
    chk1 ("C4.6 cmp 提高到 mtime+1 ⇒ mtip 回落 0", 1'b0, c_mtip);
    ctick(2);
    chk1 ("C4.7 mtime 再追上 ⇒ mtip=1", 1'b1, c_mtip);

    //---- C5 mtimecmp 高半抑制（suppress）与规范写序 --------------------
    reset_all;
    cw(C_TIME_HI, 32'h0000_0001, 4'hF);
    cw(C_TIME_LO, 32'h0000_0000, 4'hF);      // mtime = 0x1_0000_0000
    cr(C_TIME_HI, rv); chk32("C5.1 mtime={1,0}", 32'h1, rv);
    cw(C_CMP_HI, 32'h0000_0002, 4'hF);
    cw(C_CMP_LO, 32'h0000_0000, 4'hF);       // cmp = {2,0} > mtime
    chk1 ("C5.2 cmp={2,0} > mtime ⇒ mtip=0", 1'b0, c_mtip);
    cw(C_CMP_HI, 32'h0000_0000, 4'hF);       // 候选 {0,0}=0 < mtime ⇒ suppress
    chk1 ("C5.3 写高半使候选值<mtime ⇒ 抑制 mtip=0", 1'b0, c_mtip);
    cr(C_CMP_HI, rv); chk32("C5.4 高半写入已生效（读回 0）", 32'h0, rv);
    chk1 ("C5.5 抑制在下一拍仍保持", 1'b0, c_mtip);
    cw(C_CMP_LO, 32'h0000_0000, 4'hF);       // 写低半清 suppress ⇒ cmp=0 ⇒ mtip=1
    chk1 ("C5.6 写低半清抑制后按 cmp 重新评估 ⇒ mtip=1", 1'b1, c_mtip);
    // 规范 [5] 的安全写序：lo=-1 → hi → lo=目标
    reset_all;
    cw(C_TIME_HI, 32'h0, 4'hF);
    cw(C_TIME_LO, 32'd50, 4'hF);             // mtime = 50
    cw(C_CMP_LO, 32'hFFFF_FFFF, 4'hF);
    chk1 ("C5.7 写序 lo=-1：cmp 远大于 mtime ⇒ mtip=0", 1'b0, c_mtip);
    cw(C_CMP_HI, 32'h0, 4'hF);
    chk1 ("C5.8 写序 hi：无伪中断 ⇒ mtip=0", 1'b0, c_mtip);
    cw(C_CMP_LO, 32'd60, 4'hF);              // 最终 cmp=60 > mtime=50
    chk1 ("C5.9 写序收尾 lo=60 ⇒ mtip=0", 1'b0, c_mtip);
    ctick(10);
    chk1 ("C5.10 mtime 到 60 ⇒ mtip=1", 1'b1, c_mtip);

    //---- C6 wstrb（sb/sh）与未实现偏移 --------------------------------
    reset_all;
    cw(C_TIME_HI, 32'h0, 4'hF);
    cw(C_TIME_LO, 32'h0, 4'hF);
    cw(C_TIME_LO, 32'h0000_00AA, 4'b0001);
    cr(C_TIME_LO, rv); chk32("C6.1 sb 写 mtime_lo byte0", 32'h0000_00AA, rv);
    cw(C_TIME_LO, 32'h0000_BB00, 4'b0010);
    cr(C_TIME_LO, rv); chk32("C6.2 sb 写 byte1", 32'h0000_BBAA, rv);
    cw(C_TIME_LO, 32'h0000_1234, 4'b0011);
    cr(C_TIME_LO, rv); chk32("C6.3 sh 写低半字", 32'h0000_1234, rv);
    cw(C_TIME_LO, 32'hABCD_0000, 4'b1100);
    cr(C_TIME_LO, rv); chk32("C6.4 sh 写高半字", 32'hABCD_1234, rv);
    cw(C_CMP_LO, 32'h0, 4'hF);
    cw(C_CMP_LO, 32'h0000_5678, 4'b0011);
    cr(C_CMP_LO, rv); chk32("C6.5 sh 写 mtimecmp_lo", 32'h0000_5678, rv);
    cr(C_TIME_HI, rv); chk32("C6.6 sh 写 mtime_lo 不影响 hi", 32'h0, rv);
    cr(32'h0000_0004, rv); chk32("C6.7 未实现偏移 0x0004 读 0", 32'h0, rv);
    cr(32'h0000_8000, rv); chk32("C6.8 未实现偏移 0x8000 读 0", 32'h0, rv);
    cw(32'h0000_C000, 32'hDEAD_BEEF, 4'hF);  // 写忽略，无副作用
    cr(C_TIME_LO, rv); chk32("C6.9 未实现偏移写不影响 mtime", 32'hABCD_1234, rv);
    cr(C_MSIP, rv);    chk32("C6.10 未实现偏移写不影响 msip", 32'h0, rv);
    cr(32'hE000_0000, rv); chk32("C6.11 CLINT 窗口外的偏移读 0", 32'h0, rv);

    //=======================================================================
    // 第 2 部分：PLIC
    //=======================================================================
    //---- P0 复位值 ------------------------------------------------------
    reset_all;
    for (k = 1; k <= 8; k = k + 1) begin
      pr(4*k, rv);
      $sformat(nm, "P0.%0d priority[%0d] 复位读 0", k, k);
      chk32(nm, 32'h0, rv);
    end
    pr(32'h0, rv);  chk32("P0.9  priority[0]（source 0 保留）读 0", 32'h0, rv);
    pr(P_PEND, rv); chk32("P0.10 pending 复位 0", 32'h0, rv);
    pr(P_EN0, rv);  chk32("P0.11 enable[ctx0] 复位 0", 32'h0, rv);
    pr(P_EN1, rv);  chk32("P0.12 enable[ctx1] 复位 0", 32'h0, rv);
    pr(P_THR0, rv); chk32("P0.13 threshold[ctx0] 复位 0", 32'h0, rv);
    pr(P_THR1, rv); chk32("P0.14 threshold[ctx1] 复位 0", 32'h0, rv);
    pr(P_CLM0, rv); chk32("P0.15 claim[ctx0] 无候选读 0", 32'h0, rv);
    pr(P_CLM1, rv); chk32("P0.16 claim[ctx1] 无候选读 0", 32'h0, rv);
    chk1("P0.17 meip 复位 0", 1'b0, p_meip);
    chk1("P0.18 seip 复位 0", 1'b0, p_seip);

    //---- P1 priority / enable / threshold 读回与 WARL ------------------
    reset_all;
    for (k = 1; k <= 8; k = k + 1) begin
      pw(4*k, 32'h0000_1000 + k, 4'hF);
      pr(4*k, rv);
      $sformat(nm, "P1.%0d priority[%0d] 读回", k, k);
      chk32(nm, 32'h0000_1000 + k, rv);
    end
    pw(32'h0, 32'hFFFF_FFFF, 4'hF);
    pr(32'h0, rv);  chk32("P1.9  priority[0] 写忽略、读 0", 32'h0, rv);
    pw(32'h24, 32'h0000_0007, 4'hF);         // source 9 = 越界
    pr(32'h24, rv); chk32("P1.10 越界 priority 写忽略、读 0", 32'h0, rv);
    pr(32'h0C, rv); chk32("P1.11 越界写不影响 priority[3]", 32'h0000_1003, rv);
    pw(32'h0C, 32'h0000_00AA, 4'b0001);
    pr(32'h0C, rv); chk32("P1.12 priority sb 写 byte0", 32'h0000_10AA, rv);
    pw(32'h0C, 32'h0000_BB00, 4'b0010);
    pr(32'h0C, rv); chk32("P1.13 priority sb 写 byte1", 32'h0000_BBAA, rv);
    pw(P_EN0, 32'hFFFF_FFFF, 4'hF);
    pr(P_EN0, rv);  chk32("P1.14 enable[ctx0] 只保留 bit[8:1]（bit0 恒 0）", 32'h0000_01FE, rv);
    pw(P_EN1, 32'h0000_0002, 4'hF);
    pr(P_EN1, rv);  chk32("P1.15 enable[ctx1] 读回", 32'h0000_0002, rv);
    pr(P_EN0, rv);  chk32("P1.16 ctx1 写不影响 ctx0", 32'h0000_01FE, rv);
    pw(P_THR0, 32'h0000_0005, 4'hF);
    pr(P_THR0, rv); chk32("P1.17 threshold[ctx0] 读回 5", 32'h0000_0005, rv);
    pw(P_THR0, 32'hFFFF_FFF8, 4'hF);
    pr(P_THR0, rv); chk32("P1.18 threshold WARL：只保留低 3 位", 32'h0000_0000, rv);
    pw(P_THR1, 32'h0000_0003, 4'hF);
    pr(P_THR1, rv); chk32("P1.19 threshold[ctx1] 读回 3", 32'h0000_0003, rv);
    pr(P_THR0, rv); chk32("P1.20 ctx1 threshold 写不影响 ctx0", 32'h0000_0000, rv);
    pr(32'h1004, rv);    chk32("P1.21 pending 区未实现字 0x1004 读 0", 32'h0, rv);
    pr(32'h3000, rv);    chk32("P1.22 enable 区未实现字 0x3000 读 0", 32'h0, rv);
    pr(32'h202000, rv);  chk32("P1.23 未实现的 ctx2 区域读 0", 32'h0, rv);
    pr(32'hE000_0000, rv); chk32("P1.24 PLIC 窗口外的偏移读 0", 32'h0, rv);

    //---- P2 单源：pending → meip → claim → complete --------------------
    reset_all;
    pw(4, 32'd2, 4'hF);                       // priority[1] = 2
    pw(P_EN0, 32'h0000_0002, 4'hF);           // ctx0 使能 source 1
    pw(P_THR0, 32'd0, 4'hF);
    chk1("P2.1 无源 ⇒ meip=0", 1'b0, p_meip);
    psrc(8'h01);                              // source 1（= src[0]）拉高
    pr(P_PEND, rv); chk32("P2.2 源拉高 ⇒ pending 置位 0x02", 32'h0000_0002, rv);
    chk1("P2.3 meip=1", 1'b1, p_meip);
    chk1("P2.4 seip=0（ctx1 未使能）", 1'b0, p_seip);
    psrc(8'h00);                              // 源拉低
    pr(P_PEND, rv); chk32("P2.5 源拉低后 pending 锁存保持", 32'h0000_0002, rv);
    chk1("P2.6 meip 保持 1", 1'b1, p_meip);
    pr(P_CLM0, rv); chk32("P2.7 claim[ctx0] 返回 source 1", 32'h1, rv);
    chk1("P2.8 claim 后 meip=0", 1'b0, p_meip);
    pr(P_PEND, rv); chk32("P2.9 claim 清 pending", 32'h0, rv);
    psrc(8'h01);                              // 源仍高
    pr(P_PEND, rv); chk32("P2.10 已 claim 未 complete：不重新挂起", 32'h0, rv);
    chk1("P2.11 in-service 期间 meip=0", 1'b0, p_meip);
    pw(P_CLM0, 32'd1, 4'hF);                  // complete
    pr(P_PEND, rv); chk32("P2.12 complete 后源仍高 ⇒ 重新挂起", 32'h0000_0002, rv);
    chk1("P2.13 重新挂起后 meip=1", 1'b1, p_meip);
    pr(P_CLM0, rv); chk32("P2.14 再次 claim 返回 1", 32'h1, rv);
    psrc(8'h00);                              // 源拉低后才 complete
    pw(P_CLM0, 32'd1, 4'hF);
    pr(P_PEND, rv); chk32("P2.15 源已低：complete 后不重新挂起", 32'h0, rv);
    chk1("P2.16 meip=0", 1'b0, p_meip);
    psrc(8'h01);
    pr(P_CLM0, rv); chk32("P2.17 claim 返回 1", 32'h1, rv);
    pw(P_CLM0, 32'd0, 4'hF);
    chk1("P2.18 complete(0)：源 0 不参与，忽略", 1'b0, p_meip);
    pw(P_CLM0, 32'd9, 4'hF);
    chk1("P2.19 complete(越界源号)：忽略", 1'b0, p_meip);
    pr(P_PEND, rv); chk32("P2.20 无效 complete 不改 pending", 32'h0, rv);
    pw(P_CLM0, 32'd1, 4'hF);
    pr(P_PEND, rv); chk32("P2.21 有效 complete 后重新挂起", 32'h0000_0002, rv);
    pw(P_PEND, 32'h0, 4'hF);
    pr(P_PEND, rv); chk32("P2.22 pending 只读：写忽略", 32'h0000_0002, rv);

    //---- P3 priority=0 / enable / threshold 门控 -----------------------
    reset_all;
    psrc(8'h01);
    pr(P_PEND, rv); chk32("P3.1 priority=0 也置 pending（gateway 不看优先级）", 32'h0000_0002, rv);
    chk1("P3.2 priority=0 ⇒ meip=0", 1'b0, p_meip);
    pw(P_EN0, 32'h0000_0002, 4'hF);
    chk1("P3.3 仅 enable、priority=0 ⇒ meip=0", 1'b0, p_meip);
    pr(P_CLM0, rv); chk32("P3.4 priority=0 的源不可 claim（返回 0）", 32'h0, rv);
    pr(P_PEND, rv); chk32("P3.5 claim 未取到时不误清 pending", 32'h0000_0002, rv);
    pw(4, 32'd3, 4'hF);
    chk1("P3.6 priority=3 > thr=0 ⇒ meip=1", 1'b1, p_meip);
    pw(P_THR0, 32'd2, 4'hF);
    chk1("P3.7 thr=2 < priority ⇒ meip=1", 1'b1, p_meip);
    pw(P_THR0, 32'd3, 4'hF);
    chk1("P3.8 thr=3 == priority ⇒ meip=0（须严格大于）", 1'b0, p_meip);
    pw(P_THR0, 32'd4, 4'hF);
    chk1("P3.9 thr=4 > priority ⇒ meip=0", 1'b0, p_meip);
    pr(P_PEND, rv); chk32("P3.10 提高 threshold 不影响 pending", 32'h0000_0002, rv);
    pw(P_THR0, 32'd0, 4'hF);
    chk1("P3.11 thr 调回 0 ⇒ meip=1", 1'b1, p_meip);
    pw(P_EN0, 32'h0, 4'hF);
    chk1("P3.12 清 enable ⇒ meip=0", 1'b0, p_meip);
    pr(P_PEND, rv); chk32("P3.13 清 enable 不影响 pending", 32'h0000_0002, rv);
    pw(P_EN0, 32'h0000_0002, 4'hF);
    chk1("P3.14 重新 enable ⇒ meip=1", 1'b1, p_meip);

    //---- P4 多源：最高优先级 / 同级最小编号 ----------------------------
    reset_all;
    pw(4, 32'd2, 4'hF);                       // priority[1]=2
    pw(8, 32'd5, 4'hF);                       // priority[2]=5
    pw(P_EN0, 32'h0000_0006, 4'hF);
    psrc(8'h03);                              // source 1 + 2
    pr(P_PEND, rv); chk32("P4.1 两源同时挂起", 32'h0000_0006, rv);
    chk1("P4.2 meip=1", 1'b1, p_meip);
    pr(P_CLM0, rv); chk32("P4.3 claim 取最高优先级 source 2", 32'h2, rv);
    pr(P_PEND, rv); chk32("P4.4 只剩 source 1 挂起", 32'h0000_0002, rv);
    pr(P_CLM0, rv); chk32("P4.5 再 claim 取 source 1", 32'h1, rv);
    pr(P_PEND, rv); chk32("P4.6 pending 清空", 32'h0, rv);
    pr(P_CLM0, rv); chk32("P4.7 无候选时 claim 返回 0", 32'h0, rv);
    chk1("P4.8 全部 claim 后 meip=0", 1'b0, p_meip);
    reset_all;
    pw(4,  32'd7, 4'hF);
    pw(8,  32'd7, 4'hF);
    pw(12, 32'd7, 4'hF);                      // priority[3] 在偏移 4*3 = 0x0C
    pw(P_EN0, 32'h0000_000E, 4'hF);
    psrc(8'h07);                              // source 1 + 2 + 3，同优先级
    pr(P_CLM0, rv); chk32("P4.9 同级取编号最小 ⇒ 1", 32'h1, rv);
    pr(P_CLM0, rv); chk32("P4.10 再由小到大 ⇒ 2", 32'h2, rv);
    pr(P_CLM0, rv); chk32("P4.11 再由小到大 ⇒ 3", 32'h3, rv);

    //---- P5 ctx0(M) 与 ctx1(S) 相互独立 --------------------------------
    reset_all;
    pw(4,  32'd2, 4'hF);                      // priority[1]=2
    pw(20, 32'd6, 4'hF);                      // priority[5]=6
    pw(P_EN0, 32'h0000_0002, 4'hF);           // ctx0 只使能 source 1
    pw(P_EN1, 32'h0000_0020, 4'hF);           // ctx1 只使能 source 5
    psrc(8'h11);                              // source 1 + source 5
    chk1("P5.1 ctx0 看到 source 1 ⇒ meip=1", 1'b1, p_meip);
    chk1("P5.2 ctx1 看到 source 5 ⇒ seip=1", 1'b1, p_seip);
    pr(P_CLM0, rv); chk32("P5.3 claim[ctx0] = 1", 32'h1, rv);
    chk1("P5.4 claim(ctx0) 后 meip=0", 1'b0, p_meip);
    chk1("P5.5 ctx1 不受影响 ⇒ seip=1", 1'b1, p_seip);
    pr(P_PEND, rv); chk32("P5.6 pending 仍含 source 5（bit5）", 32'h0000_0020, rv);
    pr(P_CLM1, rv); chk32("P5.7 claim[ctx1] = 5", 32'h5, rv);
    chk1("P5.8 claim(ctx1) 后 seip=0", 1'b0, p_seip);
    chk1("P5.9 source 1 仍在服务 ⇒ meip=0", 1'b0, p_meip);
    pw(P_CLM1, 32'd5, 4'hF);
    chk1("P5.10 complete(ctx1,5) ⇒ seip 恢复 1", 1'b1, p_seip);
    chk1("P5.11 ctx0 的 meip 仍 0", 1'b0, p_meip);
    pw(P_CLM0, 32'd1, 4'hF);
    chk1("P5.12 complete(ctx0,1) ⇒ meip=1", 1'b1, p_meip);
    reset_all;
    pw(4, 32'd2, 4'hF);
    pw(P_EN0, 32'h0000_0002, 4'hF);
    pw(P_EN1, 32'h0000_0002, 4'hF);
    pw(P_THR0, 32'd0, 4'hF);
    pw(P_THR1, 32'd4, 4'hF);                  // ctx1 阈值更高
    psrc(8'h01);
    chk1("P5.13 同一源：ctx0 thr=0 ⇒ meip=1", 1'b1, p_meip);
    chk1("P5.14 同一源：ctx1 thr=4>pri=2 ⇒ seip=0", 1'b0, p_seip);
    pr(P_CLM1, rv); chk32("P5.15 ctx1 被 threshold 挡住 ⇒ claim=0", 32'h0, rv);
    pr(P_PEND, rv); chk32("P5.16 ctx1 未取到 ⇒ pending 保留", 32'h0000_0002, rv);

    //---- P6 source 0 保留 / pending bit0 / 连续 claim 顺序 -------------
    reset_all;
    for (k = 1; k <= 8; k = k + 1) pw(4*k, k, 4'hF);   // priority[k] = k
    pw(P_EN0, 32'h0000_01FE, 4'hF);
    pw(P_EN1, 32'h0000_01FE, 4'hF);
    psrc(8'hFF);                              // 8 个源全拉高
    pr(P_PEND, rv); chk32("P6.1 全源挂起、bit0 恒 0", 32'h0000_01FE, rv);
    for (k = 1; k <= 8; k = k + 1) begin
      pr(P_CLM0, rv);
      $sformat(nm, "P6.%0d 连续 claim 第 %0d 次取优先级最高的 source %0d", k+1, k, 9-k);
      chk32(nm, 9-k, rv);
    end
    pr(P_CLM0, rv); chk32("P6.10 全部取完后 claim=0", 32'h0, rv);
    pr(P_PEND, rv); chk32("P6.11 全部 claim 后 pending=0", 32'h0, rv);
    chk1("P6.12 meip=0", 1'b0, p_meip);
    pw(32'h0, 32'hFFFF_FFFF, 4'hF);
    pr(32'h0, rv); chk32("P6.13 priority[0] 写忽略、读 0", 32'h0, rv);
    pw(P_EN0, 32'hFFFF_FFFF, 4'hF);
    pr(P_EN0, rv); chk32("P6.14 enable[ctx0] bit0 恒 0", 32'h0000_01FE, rv);
    pr(P_EN1, rv); chk32("P6.15 enable[ctx1] bit0 恒 0", 32'h0000_01FE, rv);

    //---- P7 未实现偏移/只读写：无副作用 ---------------------------------
    reset_all;
    pw(4, 32'd2, 4'hF);
    pw(P_EN0, 32'h0000_0002, 4'hF);
    psrc(8'h01);
    pw(32'h1004, 32'hFFFF_FFFF, 4'hF);
    pw(32'h3000, 32'hFFFF_FFFF, 4'hF);
    pw(32'h202000, 32'hFFFF_FFFF, 4'hF);
    pw(P_PEND, 32'h0, 4'hF);
    pr(P_PEND, rv); chk32("P7.1 写入未实现/只读寄存器后 pending 不变", 32'h0000_0002, rv);
    chk1("P7.2 meip 仍 1", 1'b1, p_meip);
    pr(P_EN0, rv); chk32("P7.3 enable 未被未实现写破坏", 32'h0000_0002, rv);
    pr(4, rv);     chk32("P7.4 priority[1] 未被未实现写破坏", 32'd2, rv);

    //=======================================================================
    // 汇总
    //=======================================================================
    if (n_fail == 0) begin
      $display("CLINT_PLIC_UNIT: PASS (%0d checks)", n_check);
      $finish;
    end else begin
      $display("CLINT_PLIC_UNIT: FAIL (%0d/%0d checks failed)", n_fail, n_check);
      $fatal;   // 非零退出
    end
  end

endmodule
