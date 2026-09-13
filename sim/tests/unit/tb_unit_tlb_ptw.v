//=============================================================================
// tb_unit_tlb_ptw.v —— rv32_ptw（Sv32 两级遍历）与 rv32_tlb（全相联 CAM）单元测试
//
// 自校验：每个 chk_* 调用 = 1 个 check，全部用 !==（任何 X/Z 都算 FAIL）。
//   成功：TLB_PTW_UNIT: PASS (<N> checks)
//   失败：逐条 [FAIL] 明细 + TLB_PTW_UNIT: FAIL (<m>/<N>)，脚本非零退出。
//
// 期望值口径（全部来自规范原文 + Spike，不由被测 RTL 回填）：
//   riscv-isa-manual/src/priv/supervisor.adoc:1727-1745 —— Sv32 翻译算法
//     :1727-1728 a = satp.ppn × PAGESIZE(=2^12)，i = LEVELS-1 = 1
//     :1730      pte = mem[a + va.vpn[i] × PTESIZE(=4)]（**页表基址 = ppn<<12**）
//     :1732      V=0 或 (R=0&&W=1) ⇒ 页错误
//     :1734-1735 非叶（R=X=0）继续；i<0 ⇒ 页错误（第 2 级仍非叶 ⇒ 页错误）
//     :1737      叶子且 i>0 且 pte.ppn[i-1:0]!=0 ⇒ 页错误（4M 要求 pte[19:10]==0）
//     :1704-1706 非叶的 D/A/U 位保留 ⇒ 置位即非法
//   tools/spike/riscv/mmu.cc:727-733/734/751-758/765-766/805-807（参考实现 walk）
//   tools/spike/riscv/mmu.h:606-611（Sv32: levels=2, idxbits=10, ptesize=4）
//   docs/design/spec/07-priv-csr-mmu.md:267-268（TLB 命中判定与 PA 拼接）
//
// TB 内小内存模型：16 KiB 字阵列（1024→4096 字，PA[13:2] 索引）。
//   PA 0x0000 根页表（satp_ppn=0）   PA 0x1000 二级页表（PPN=1）   PA 0x2000 备用二级表（PPN=2）
//   4K 数据页 PPN=0x30（PA 0x30000，从不取指）  4M 数据页 PPN=0xC00（低 10 位=0）
//   PA[31:14]!=0 ⇒ bus_err（用于总线错误用例）
//=============================================================================
`timescale 1ns/1ps

module tb_unit_tlb_ptw;

  //---------------------------------------------------------------------------
  // 时钟 / 复位
  //---------------------------------------------------------------------------
  reg clk, rst_n;
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // 字符串参数宽度（chk_* 的任务名）
  //---------------------------------------------------------------------------
  localparam integer NM = 8*72;

  //---------------------------------------------------------------------------
  // PTW 接口
  //---------------------------------------------------------------------------
  reg  [31:0] p_va;
  reg  [21:0] p_satp_ppn;
  reg         p_req, p_abort;
  wire        p_bus_req;
  wire [31:0] p_bus_addr;
  wire [31:0] bus_rdata;
  wire        bus_ack, bus_err;
  wire        p_busy, p_done, p_fault;
  wire [21:0] p_ppn;
  wire        p_is_4m;
  wire [7:0]  p_perm;
  wire [31:0] p_fault_va;

  rv32_ptw dut_ptw (
    .clk      (clk),
    .rst_n    (rst_n),
    .req      (p_req),
    .va       (p_va),
    .satp_ppn (p_satp_ppn),
    .bus_req  (p_bus_req),
    .bus_addr (p_bus_addr),
    .bus_rdata(bus_rdata),
    .bus_ack  (bus_ack),
    .bus_err  (bus_err),
    .busy     (p_busy),
    .done     (p_done),
    .fault    (p_fault),
    .ppn      (p_ppn),
    .is_4m    (p_is_4m),
    .perm     (p_perm),
    .fault_va (p_fault_va),
    .abort    (p_abort)
  );

  //---------------------------------------------------------------------------
  // TB 内页表存储 + 页表读从设备
  //---------------------------------------------------------------------------
  localparam integer MEMW = 4096;                 // 16 KiB / 4
  reg [31:0] mem [0:MEMW-1];

  integer    bus_lat;                             // 每级页表读的响应延迟（0 = 组合应答）
  integer    wait_cnt;
  integer    n_access;                            // 本轮流观察到的页表读次数
  reg        cnt_clr;
  reg [31:0] acc_addr [0:7];                      // 各次读的地址

  wire resp_now = p_bus_req & (wait_cnt >= bus_lat);
  wire addr_ok  = (p_bus_addr[31:14] == 18'd0);   // 16 KiB 模型之外 ⇒ 总线错误
  assign bus_ack   = resp_now &  addr_ok;
  assign bus_err   = resp_now & ~addr_ok;
  assign bus_rdata = mem[p_bus_addr[13:2]];

  always @(posedge clk) begin
    if (!rst_n)                 wait_cnt <= 0;
    else if (!p_bus_req)        wait_cnt <= 0;
    else if (!resp_now)         wait_cnt <= wait_cnt + 1;
    else                        wait_cnt <= 0;
  end

  always @(posedge clk) begin
    if (!rst_n || cnt_clr)      n_access <= 0;
    else if (resp_now) begin
      if (n_access < 8)         acc_addr[n_access] <= p_bus_addr;
      n_access <= n_access + 1;
    end
  end

  task wr;
    input [31:0] a;
    input [31:0] d;
    begin mem[a[13:2]] = d; end
  endtask

  //---------------------------------------------------------------------------
  // TLB（8 项 = DUT 主实例）
  //---------------------------------------------------------------------------
  reg  [31:0] t_va;
  reg  [8:0]  t_asid;
  wire        t_hit;
  wire [21:0] t_ppn;
  wire        t_is4m;
  wire [7:0]  t_perm;
  reg         t_fill_en, t_flush;
  reg  [31:0] t_fill_va;
  reg  [8:0]  t_fill_asid;
  reg         t_fill_g, t_fill_4m;
  reg  [21:0] t_fill_ppn;
  reg  [7:0]  t_fill_perm;

  rv32_tlb #(.ENTRIES(8)) dut_tlb (
    .clk       (clk),
    .rst_n     (rst_n),
    .va        (t_va),
    .satp_asid (t_asid),
    .hit       (t_hit),
    .ppn       (t_ppn),
    .is_4m     (t_is4m),
    .perm      (t_perm),
    .fill_en   (t_fill_en),
    .fill_va   (t_fill_va),
    .fill_asid (t_fill_asid),
    .fill_g    (t_fill_g),
    .fill_is_4m(t_fill_4m),
    .fill_ppn  (t_fill_ppn),
    .fill_perm (t_fill_perm),
    .flush_all (t_flush)
  );

  //---------------------------------------------------------------------------
  // TLB（4 项 = 参数化/轮转边界实例）
  //---------------------------------------------------------------------------
  reg  [31:0] t4_va;
  reg  [8:0]  t4_asid;
  wire        t4_hit;
  wire [21:0] t4_ppn;
  wire        t4_is4m;
  wire [7:0]  t4_perm;
  reg         t4_fill_en, t4_flush;
  reg  [31:0] t4_fill_va;
  reg  [8:0]  t4_fill_asid;
  reg         t4_fill_g, t4_fill_4m;
  reg  [21:0] t4_fill_ppn;
  reg  [7:0]  t4_fill_perm;

  rv32_tlb #(.ENTRIES(4)) dut_tlb4 (
    .clk       (clk),
    .rst_n     (rst_n),
    .va        (t4_va),
    .satp_asid (t4_asid),
    .hit       (t4_hit),
    .ppn       (t4_ppn),
    .is_4m     (t4_is4m),
    .perm      (t4_perm),
    .fill_en   (t4_fill_en),
    .fill_va   (t4_fill_va),
    .fill_asid (t4_fill_asid),
    .fill_g    (t4_fill_g),
    .fill_is_4m(t4_fill_4m),
    .fill_ppn  (t4_fill_ppn),
    .fill_perm (t4_fill_perm),
    .flush_all (t4_flush)
  );

  //---------------------------------------------------------------------------
  // PTE / VA / PPN 常量（手算，与规范逐条对应）
  //   PTE = {PPN[21:0], 10'b0} | {24'd0, flags}；perm 回读 = PTE[7:0]
  //---------------------------------------------------------------------------
  localparam [31:0] PTE_ROOT_L2  = 32'h0000_0401;   // 非叶 V=1，PPN=1 → 二级表 PA 0x1000
  localparam [31:0] PTE_4M_OK    = 32'h0030_0049;   // 4M 叶：PPN=0x000C00，V|X|A
  localparam [31:0] PTE_ROOT_G   = 32'h0000_0821;   // 非叶 V|G=1，PPN=2 → PA 0x2000（G 不非法）
  localparam [31:0] PTE_L2_4K    = 32'h0000_C0DF;   // 4K 叶：PPN=0x30，V|R|W|X|U|A|D
  localparam [31:0] PTE_L2_4K_G  = 32'h0000_C463;   // 4K 叶：PPN=0x31，V|R|G|A
  localparam [31:0] PTE_L2B_X    = 32'h0000_0409;   // 4K 叶（X-only）：PPN=1，V|X
  // 注：PTE_V0 / PTE_R0W1 的 PPN 取 0x000C00（低 10 位 = 0）——若 RTL 漏判 V=0 或
  //     R=0&&W=1，这两项会被当成**合法的 4M 叶子**从而 done=1 ⇒ TB 必然抓到该 bug
  //     （若 PPN 低 10 位非 0，漏判只会换成"超级页未对齐"页错误，掩盖真正缺陷）。
  localparam [31:0] PTE_V0       = 32'h0030_004E;   // V=0（其余位是合法叶子位）⇒ 页错误
  localparam [31:0] PTE_R0W1     = 32'h0030_0045;   // V=1,R=0,W=1 ⇒ 页错误
  localparam [31:0] PTE_NL_A     = 32'h0000_0441;   // 非叶 + A ⇒ 页错误
  localparam [31:0] PTE_NL_D     = 32'h0000_0481;   // 非叶 + D ⇒ 页错误
  localparam [31:0] PTE_NL_U     = 32'h0000_0411;   // 非叶 + U ⇒ 页错误
  localparam [31:0] PTE_4M_MIS   = 32'h0030_1049;   // 4M 叶但 ppn[9:0]=4≠0（pte[19:10]≠0）⇒ 页错误
  localparam [31:0] PTE_ROOT_ERR = 32'h0000_1001;   // 非叶 PPN=4 → PA 0x4000 越界 ⇒ 第 2 级 bus_err
  localparam [31:0] PTE_TBL_L0   = 32'h0000_0401;   // 第 2 级仍是表指针 ⇒ 页错误（i<0）

  localparam [21:0] PPN_ROOT   = 22'h000000;        // 根页表 @ PA 0x0000
  localparam [21:0] PPN_L2     = 22'h000001;        // 二级表 @ PA 0x1000
  localparam [21:0] PPN_ERR    = 22'h000004;        // PA 0x4000（越界，触发 bus_err）
  localparam [21:0] PPN_4K     = 22'h000030;        // PA 0x03000
  localparam [21:0] PPN_4M     = 22'h000C00;        // 4M 页（低 10 位 = 0）

  function [31:0] mk_va;                            // {VPN[1], VPN[0], offset}
    input [9:0] v1;
    input [9:0] v0;
    input [11:0] off;
    begin mk_va = {v1, v0, off}; end
  endfunction

  wire [31:0] VA_4K    = mk_va(10'h001, 10'h0A5, 12'h123);  // 走根表[1] → 二级表[0x0A5]
  wire [31:0] VA_4K_0  = mk_va(10'h001, 10'h0A5, 12'h000);  // 同页不同 offset
  wire [31:0] VA_4K_C  = mk_va(10'h001, 10'h0A6, 12'h000);  // 同 VPN[1]、不同 VPN[0]
  wire [31:0] VA_4K_D  = mk_va(10'h005, 10'h0A5, 12'h000);  // 不同 VPN[1]
  wire [31:0] VA_G     = mk_va(10'h003, 10'h0A5, 12'h000);  // 走 V|G 非叶 → 备用二级表
  wire [31:0] VA_4M    = mk_va(10'h002, 10'h1FF, 12'hABC);  // 根表[2] 是 4M 叶
  wire [31:0] VA_4M_B  = mk_va(10'h002, 10'h077, 12'hABC);  // 同 4M 页（VPN[0] 无关）
  wire [31:0] VA_4M_O  = mk_va(10'h006, 10'h1FF, 12'hABC);  // 不同 VPN[1]（TLB 不命中）
  wire [31:0] VA_V0    = mk_va(10'h010, 10'h000, 12'h000);
  wire [31:0] VA_R0W1  = mk_va(10'h011, 10'h000, 12'h000);
  // 非叶 D/A/U 用例：VPN[0] 取 0x0A5 ⇒ 对应二级表项是**合法叶子**。
  //   这样一旦 RTL 漏判"非叶 D|A|U"，遍历会继续并成功（done=1）⇒ TB 必然抓到；
  //   若用其它索引，漏判会因二级表项非法而照样 fault，掩盖 bug。
  wire [31:0] VA_NL_A  = mk_va(10'h012, 10'h0A5, 12'h000);
  wire [31:0] VA_NL_D  = mk_va(10'h013, 10'h0A5, 12'h000);
  wire [31:0] VA_NL_U  = mk_va(10'h014, 10'h0A5, 12'h000);
  wire [31:0] VA_4MMIS = mk_va(10'h015, 10'h000, 12'h000);
  wire [31:0] VA_BE2   = mk_va(10'h016, 10'h000, 12'h000);
  wire [31:0] VA_R0W1L2 = mk_va(10'h019, 10'h0A9, 12'h000);  // 第 2 级 R=0&&W=1
  wire [31:0] VA_TBL0  = mk_va(10'h017, 10'h0A7, 12'h000);
  wire [31:0] VA_V0L2  = mk_va(10'h018, 10'h0A8, 12'h000);
  wire [31:0] VA_ZRO   = mk_va(10'h000, 10'h000, 12'h000);  // 根表[0] 未写（V=0）

  function [31:0] pa_4k;                            // 4K：PA = {PPN[21:0], va[11:0]}
    input [21:0] p;
    input [31:0] v;
    begin pa_4k = {p, v[11:0]}; end
  endfunction

  function [31:0] pa_4m;                            // 4M：PA = {PPN[21:10], va[21:12], va[11:0]}
    input [21:0] p;
    input [31:0] v;
    begin pa_4m = {p[21:10], v[21:0]}; end
  endfunction

  //---------------------------------------------------------------------------
  // 检查任务
  //---------------------------------------------------------------------------
  integer n_check, n_fail;

  task chk1;
    input [NM-1:0] nm;
    input          got;
    input          exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: got=%b exp=%b (va=%08x ppn=%06x acc=%0d)",
                 nm, got, exp, p_va, p_ppn, n_access);
      end
    end
  endtask

  task chk22;
    input [NM-1:0] nm;
    input [21:0]   got;
    input [21:0]   exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: got=%06x exp=%06x (va=%08x)", nm, got, exp, p_va);
      end
    end
  endtask

  task chk8;
    input [NM-1:0] nm;
    input [7:0]    got;
    input [7:0]    exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: got=%02x exp=%02x (va=%08x)", nm, got, exp, p_va);
      end
    end
  endtask

  task chk32;
    input [NM-1:0] nm;
    input [31:0]   got;
    input [31:0]   exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: got=%08x exp=%08x", nm, got, exp);
      end
    end
  endtask

  task chki;
    input [NM-1:0] nm;
    input integer  got;
    input integer  exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: got=%0d exp=%0d (va=%08x)", nm, got, exp, p_va);
      end
    end
  endtask

  // TLB 侧同一套口径
  task tchk1;
    input [NM-1:0] nm;
    input          got;
    input          exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: hit=%b exp=%b (va=%08x asid=%03x)", nm, got, exp, t_va, t_asid);
      end
    end
  endtask

  task tchk22;
    input [NM-1:0] nm;
    input [21:0]   got;
    input [21:0]   exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: ppn=%06x exp=%06x (va=%08x asid=%03x)", nm, got, exp, t_va, t_asid);
      end
    end
  endtask

  task tchk8;
    input [NM-1:0] nm;
    input [7:0]    got;
    input [7:0]    exp;
    begin
      n_check = n_check + 1;
      if (got !== exp) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: perm=%02x exp=%02x (va=%08x asid=%03x)", nm, got, exp, t_va, t_asid);
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // 激励任务
  //---------------------------------------------------------------------------
  task ptw_walk;                                    // 启动一次遍历并等到 done|fault
    input [31:0]  v;
    input [21:0]  sp;
    input integer lat;
    integer g;
    begin
      bus_lat  = lat;
      @(negedge clk); cnt_clr = 1'b1;                 // 页表读计数清零
      @(negedge clk); cnt_clr = 1'b0;
      p_abort  = 1'b0;
      p_va     = v;
      p_satp_ppn = sp;
      p_req    = 1'b1;
      @(negedge clk);
      p_req    = 1'b0;
      g = 0;
      while (!(p_done | p_fault) && (g < 200)) begin
        @(negedge clk);
        g = g + 1;
      end
      if (!(p_done | p_fault)) begin
        n_check = n_check + 1;
        n_fail  = n_fail + 1;
        $display("[FAIL] PTW 超时未出结果: va=%08x satp_ppn=%06x", v, sp);
      end
      @(negedge clk);                                 // 让 n_access 稳定
    end
  endtask

  task ptw_fault_case;                              // 非法用例：fault/done/fault_va/busy 四连检
    input [31:0]   v;
    input [21:0]   sp;
    input [NM-1:0] nm;
    begin
      ptw_walk(v, sp, 1);
      n_check = n_check + 1;
      if (p_fault !== 1'b1) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: fault 应为 1，实得 %b (va=%08x acc=%0d)", nm, p_fault, v, n_access);
      end
      n_check = n_check + 1;
      if (p_done !== 1'b0) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: done 应为 0，实得 %b (va=%08x)", nm, p_done, v);
      end
      n_check = n_check + 1;
      if (p_fault_va !== v) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: fault_va=%08x 应为 %08x", nm, p_fault_va, v);
      end
      n_check = n_check + 1;
      if (p_busy !== 1'b0) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: busy 应为 0，实得 %b (va=%08x)", nm, p_busy, v);
      end
    end
  endtask

  task tlb_fill;                                    // 填充 8 项实例
    input [31:0] v;
    input [8:0]  a;
    input        g;
    input        m4;
    input [21:0] p;
    input [7:0]  pr;
    begin
      @(negedge clk);
      t_fill_en = 1'b1; t_fill_va = v; t_fill_asid = a; t_fill_g = g;
      t_fill_4m = m4;   t_fill_ppn = p; t_fill_perm = pr;
      @(negedge clk);
      t_fill_en = 1'b0;
    end
  endtask

  task tlb_q;                                       // 组合查询
    input [31:0] v;
    input [8:0]  a;
    begin
      t_va = v; t_asid = a; #1;
    end
  endtask

  task tlb_flush;                                   // 跨一个 posedge 的 flush 脉冲
    begin
      @(negedge clk); t_flush = 1'b1;
      @(negedge clk); t_flush = 1'b0;
    end
  endtask

  task tlb4_fill;                                   // 填充 4 项实例
    input [31:0] v;
    input [8:0]  a;
    input [21:0] p;
    begin
      @(negedge clk);
      t4_fill_en = 1'b1; t4_fill_va = v; t4_fill_asid = a; t4_fill_g = 1'b0;
      t4_fill_4m = 1'b0; t4_fill_ppn = p; t4_fill_perm = 8'h1F;
      @(negedge clk);
      t4_fill_en = 1'b0;
    end
  endtask

  //---------------------------------------------------------------------------
  // 主流程
  //---------------------------------------------------------------------------
  integer i, k;

  initial begin : main
    n_check = 0; n_fail = 0;

    //---------- 初始化 ----------
    rst_n = 1'b0;
    p_va = 32'd0; p_satp_ppn = 22'd0; p_req = 1'b0; p_abort = 1'b0;
    bus_lat = 1; wait_cnt = 0; n_access = 0; cnt_clr = 1'b0;
    t_va = 32'd0; t_asid = 9'd0; t_fill_en = 1'b0; t_flush = 1'b0;
    t_fill_va = 32'd0; t_fill_asid = 9'd0; t_fill_g = 1'b0; t_fill_4m = 1'b0;
    t_fill_ppn = 22'd0; t_fill_perm = 8'd0;
    t4_va = 32'd0; t4_asid = 9'd0; t4_fill_en = 1'b0; t4_flush = 1'b0;
    t4_fill_va = 32'd0; t4_fill_asid = 9'd0; t4_fill_g = 1'b0; t4_fill_4m = 1'b0;
    t4_fill_ppn = 22'd0; t4_fill_perm = 8'd0;
    for (i = 0; i < MEMW; i = i + 1) mem[i] = 32'd0;
    for (i = 0; i < 8; i = i + 1) acc_addr[i] = 32'd0;

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    //========================================================== A. 复位后空闲
    chk1("A1 idle busy=0",    p_busy,    1'b0);
    chk1("A2 idle done=0",    p_done,    1'b0);
    chk1("A3 idle fault=0",   p_fault,   1'b0);
    chk1("A4 idle bus_req=0", p_bus_req, 1'b0);

    //========================================================== B. 4K 两级翻译
    wr(32'h0000_0004, PTE_ROOT_L2);                 // 根表[0x001] → 二级表 PA 0x1000
    wr(32'h0000_1294, PTE_L2_4K);                   // 二级表[0x0A5] → 4K 叶 ppn=0x30
    ptw_walk(VA_4K, PPN_ROOT, 1);
    chk1 ("B1 4K done",        p_done,  1'b1);
    chk1 ("B2 4K !fault",      p_fault, 1'b0);
    chk22("B3 4K ppn",         p_ppn,   PPN_4K);
    chk1 ("B4 4K !is_4m",      p_is_4m, 1'b0);
    chk8 ("B5 4K perm=PTE[7:0]", p_perm, 8'hDF);
    chk1 ("B6 4K !busy",       p_busy,  1'b0);
    chki ("B7 4K 两次页表读",   n_access, 2);
    chk32("B8 4K L1 addr={vpn1,2'b00}", acc_addr[0], 32'h0000_0004);
    chk32("B9 4K L2 addr=0x1000+4*vpn0", acc_addr[1], 32'h0000_1294);
    chk32("B10 4K PA compose", pa_4k(p_ppn, p_va), 32'h0003_0123);

    ptw_walk(VA_4K_0, PPN_ROOT, 1);                 // 同页不同 offset
    chk1 ("B11 same-page done",     p_done, 1'b1);
    chk22("B12 same-page ppn",      p_ppn,  PPN_4K);
    chk32("B13 same-page PA=ppn<<12", pa_4k(p_ppn, VA_4K_0), 32'h0003_0000);

    //========================================================== C. 延迟无关性
    ptw_walk(VA_4K, PPN_ROOT, 2);
    chk1 ("C1 lat=2 done",   p_done, 1'b1);
    chk22("C2 lat=2 ppn",    p_ppn,  PPN_4K);
    chki ("C3 lat=2 two reads", n_access, 2);
    ptw_walk(VA_4K, PPN_ROOT, 3);
    chk1 ("C4 lat=3 done",   p_done, 1'b1);
    chk22("C5 lat=3 ppn",    p_ppn,  PPN_4K);
    chki ("C6 lat=3 two reads", n_access, 2);
    ptw_walk(VA_4K, PPN_ROOT, 0);                   // 组合应答（0 延迟）
    chk1 ("C7 lat=0 done",   p_done, 1'b1);
    chk22("C8 lat=0 ppn",    p_ppn,  PPN_4K);
    chki ("C9 lat=0 two reads", n_access, 2);

    //========================================================== D. 4M 超级页
    wr(32'h0000_0008, PTE_4M_OK);                   // 根表[0x002] = 4M 叶
    ptw_walk(VA_4M, PPN_ROOT, 1);
    chk1 ("D1 4M done",     p_done,  1'b1);
    chk1 ("D2 4M !fault",   p_fault, 1'b0);
    chk1 ("D3 4M is_4m",    p_is_4m, 1'b1);
    chk22("D4 4M ppn=高位", p_ppn,   PPN_4M);
    chk8 ("D5 4M perm",     p_perm,  8'h49);
    chki ("D6 4M one read only", n_access, 1);
    chk32("D7 4M L1 地址",  acc_addr[0], 32'h0000_0008);
    chk32("D8 4M PA compose",  pa_4m(p_ppn, p_va), 32'h00DF_FABC);

    ptw_walk(VA_4M_B, PPN_ROOT, 1);                 // VPN[0] 不同 ⇒ 同一 4M 页
    chk1 ("D9 4M VPN0-irrelevant done", p_done, 1'b1);
    chk22("D10 4M VPN0-irrelevant ppn", p_ppn,  PPN_4M);
    chki ("D11 4M VPN0-irrelevant 1 read", n_access, 1);

    //================================================== E. G=1 非叶 PTE 合法
    wr(32'h0000_000C, PTE_ROOT_G);                  // 根表[0x003] = 非叶 V|G
    wr(32'h0000_2294, PTE_L2B_X);                   // 备用二级表[0x0A5] = X-only 叶 ppn=1
    ptw_walk(VA_G, PPN_ROOT, 1);
    chk1 ("E1 nonleaf-G legal done", p_done, 1'b1);
    chk22("E2 nonleaf-G ppn",         p_ppn,  22'h000001);
    chk8 ("E3 X-only leaf perm",     p_perm, 8'h09);
    chk32("E4 nonleaf-G L2 base addr",  acc_addr[1], 32'h0000_2294);

    wr(32'h0000_1298, PTE_L2_4K_G);                 // 二级表[0x0A6] = 4K 叶 V|R|G|A
    ptw_walk(VA_4K_C, PPN_ROOT, 1);
    chk1 ("E5 G-leaf done",        p_done, 1'b1);
    chk22("E6 G-leaf ppn",         p_ppn,  22'h000031);
    chk8 ("E7 G-leaf perm has G", p_perm, 8'h63);

    //================================================== F. 非法 PTE / 总线错误
    wr(32'h0000_0040, PTE_V0);                      // 根表[0x010]
    wr(32'h0000_0044, PTE_R0W1);                    // 根表[0x011]
    wr(32'h0000_0048, PTE_NL_A);                    // 根表[0x012]
    wr(32'h0000_004C, PTE_NL_D);                    // 根表[0x013]
    wr(32'h0000_0050, PTE_NL_U);                    // 根表[0x014]
    wr(32'h0000_0054, PTE_4M_MIS);                  // 根表[0x015]
    wr(32'h0000_0058, PTE_ROOT_ERR);                // 根表[0x016] → 越界 PPN=4
    wr(32'h0000_005C, PTE_ROOT_L2);                 // 根表[0x017] → 二级表
    wr(32'h0000_129C, PTE_TBL_L0);                  // 二级表[0x0A7] = 表指针（i<0）
    wr(32'h0000_0060, PTE_ROOT_L2);                 // 根表[0x018] → 二级表
    wr(32'h0000_12A0, PTE_V0);                      // 二级表[0x0A8] = V=0
    wr(32'h0000_0064, PTE_ROOT_L2);                 // 根表[0x019] → 二级表
    wr(32'h0000_12A4, PTE_R0W1);                    // 二级表[0x0A9] = R=0&&W=1

    ptw_fault_case(VA_V0,    PPN_ROOT, "F1 V=0@L1");
    ptw_fault_case(VA_R0W1,  PPN_ROOT, "F2 R=0&&W=1@L1");
    ptw_fault_case(VA_NL_A,  PPN_ROOT, "F3 nonleaf A=1");
    ptw_fault_case(VA_NL_D,  PPN_ROOT, "F4 nonleaf D=1");
    ptw_fault_case(VA_NL_U,  PPN_ROOT, "F5 nonleaf U=1");
    ptw_fault_case(VA_4MMIS, PPN_ROOT, "F6 4M ppn[0]!=0");
    ptw_fault_case(VA_TBL0,  PPN_ROOT, "F7 L2 still nonleaf");
    ptw_fault_case(VA_V0L2,  PPN_ROOT, "F8 V=0@L2");
    ptw_fault_case(VA_BE2,   PPN_ROOT, "F9 bus_err@L2");
    ptw_fault_case(VA_4K,    PPN_ERR,  "F10 bus_err@L1");
    ptw_fault_case(VA_R0W1L2, PPN_ROOT, "F12 R=0&&W=1@L2");
    ptw_fault_case(VA_ZRO,   PPN_ROOT, "F11 unwritten root PTE(V=0)");

    //========================================================== G. abort 语义
    bus_lat = 3;
    @(negedge clk); cnt_clr = 1'b1; @(negedge clk); cnt_clr = 1'b0;
    p_va = VA_4K; p_satp_ppn = PPN_ROOT; p_req = 1'b1;
    @(negedge clk); p_req = 1'b0;
    @(negedge clk); p_abort = 1'b1;                 // 遍历途中 abort
    @(negedge clk); p_abort = 1'b0;
    @(negedge clk);
    chk1("G1 abort busy=0",    p_busy,    1'b0);
    chk1("G2 abort done=0",    p_done,    1'b0);
    chk1("G3 abort fault=0",   p_fault,   1'b0);
    chk1("G4 abort bus_req=0", p_bus_req, 1'b0);
    repeat (10) @(negedge clk);                     // 在途结果必须被丢弃
    chk1("G5 no result after abort done=0",  p_done,  1'b0);
    chk1("G6 no result after abort fault=0", p_fault, 1'b0);
    ptw_walk(VA_4K, PPN_ROOT, 1);                   // abort 后可正常重新翻译
    chk1("G7 reusable after abort", p_done, 1'b1);

    // req 持续拉高（不撤销）时：结果必须稳定保持，不得自动重启遍历
    bus_lat = 1;
    @(negedge clk); cnt_clr = 1'b1; @(negedge clk); cnt_clr = 1'b0;
    p_va = VA_4K; p_satp_ppn = PPN_ROOT; p_req = 1'b1;   // 拉高后一直保持
    for (i = 0; i < 20; i = i + 1) @(negedge clk);
    chk1("G8 held req: done stays",  p_done,  1'b1);
    chk1("G9 held req: !busy",       p_busy,  1'b0);
    chki("G10 held req: 不重启（共 2 次读）", n_access, 2);
    p_req = 1'b0; @(negedge clk);
    chk1("G11 撤销 req 后结果仍在",   p_done,  1'b1);

    //========================================================== H. TLB 基础
    t_va = 32'd0; t_asid = 9'd0; #1;
    tchk1("H1 no hit after reset", t_hit, 1'b0);

    tlb_fill(VA_4K, 9'h005, 1'b0, 1'b0, PPN_4K, 8'hDF);
    tlb_q(VA_4K, 9'h005);
    tchk1 ("H2 hit after fill",     t_hit,  1'b1);
    tchk22("H3 hit ppn",       t_ppn,  PPN_4K);
    tchk1 ("H4 hit is_4m=0",   t_is4m, 1'b0);
    tchk8 ("H5 hit perm readback", t_perm, 8'hDF);
    tlb_q(VA_4K, 9'h006);
    tchk1("H6 ASID mismatch no hit", t_hit, 1'b0);
    tlb_q(VA_4K, 9'h000);
    tchk1("H7 ASID=0 no hit",     t_hit, 1'b0);
    tlb_q(VA_4K_C, 9'h005);
    tchk1("H8 same VPN1 diff VPN0 no hit", t_hit, 1'b0);
    tlb_q(VA_4K_D, 9'h005);
    tchk1("H9 diff VPN1 no hit",         t_hit, 1'b0);

    //========================================================== I. G 项忽略 ASID
    tlb_fill(VA_G, 9'h005, 1'b1, 1'b0, 22'h000077, 8'h0B);
    tlb_q(VA_G, 9'h009);
    tchk1 ("I1 G=1 cross-ASID hit",  t_hit,  1'b1);
    tchk22("I2 G=1 ppn",           t_ppn,  22'h000077);
    tchk8 ("I3 G=1 perm",          t_perm, 8'h0B);
    tlb_q(VA_G, 9'h000);
    tchk1 ("I4 G=1 ASID=0 also hits", t_hit,  1'b1);
    tlb_q(VA_4K_C, 9'h009);
    tchk1 ("I5 G=1 still compares tag",      t_hit,  1'b0);

    //========================================================== J. 4M 项的命中
    tlb_fill(VA_4M, 9'h003, 1'b0, 1'b1, PPN_4M, 8'h49);
    tlb_q(VA_4M, 9'h003);
    tchk1 ("J1 4M hit",         t_hit,  1'b1);
    tchk1 ("J2 4M is_4m=1",      t_is4m, 1'b1);
    tchk22("J3 4M ppn",          t_ppn,  PPN_4M);
    tlb_q(VA_4M_B, 9'h003);
    tchk1 ("J4 4M VPN0 change still hits", t_hit,  1'b1);
    tchk22("J5 4M VPN0 change ppn",   t_ppn,  PPN_4M);
    tlb_q(VA_4M_O, 9'h003);
    tchk1 ("J6 4M VPN1 change no hit", t_hit,  1'b0);
    tlb_q(VA_4M, 9'h004);
    tchk1 ("J7 4M ASID mismatch",   t_hit,  1'b0);

    //========================================================== K. 多项共存
    tlb_q(VA_4K, 9'h005);
    tchk1 ("K1 old entry remains",       t_hit, 1'b1);
    tlb_q(VA_G, 9'h009);
    tchk1 ("K2 G entry remains",       t_hit, 1'b1);
    tlb_q(VA_ZRO, 9'h005);
    tchk1 ("K3 unrelated addr no hit", t_hit, 1'b0);

    //========================================================== L. 轮转替换(8)
    for (k = 0; k < 8; k = k + 1) begin
      tlb_fill(mk_va(k[9:0], 10'h000, 12'h000), 9'h001, 1'b0, 1'b0, 22'h000100 + k[21:0], 8'h1F);
    end
    tlb_fill(mk_va(10'h008, 10'h000, 12'h000), 9'h001, 1'b0, 1'b0, 22'h000108, 8'h1F);
    tlb_q(mk_va(10'h008, 10'h000, 12'h000), 9'h001);
    tchk1 ("L1 9th entry hits",     t_hit, 1'b1);
    tchk22("L2 9th entry ppn",     t_ppn, 22'h000108);
    tlb_q(mk_va(10'h000, 10'h000, 12'h000), 9'h001);
    tchk1 ("L3 1st entry evicted by RR", t_hit, 1'b0);
    for (k = 1; k < 8; k = k + 1) begin
      tlb_q(mk_va(k[9:0], 10'h000, 12'h000), 9'h001);
      tchk1 ("L4 other entries remain", t_hit, 1'b1);
    end

    //========================================================== M. flush_all
    tlb_flush;
    tlb_q(VA_4K, 9'h005);   tchk1("M1 4K entry invalid after flush", t_hit, 1'b0);
    tlb_q(VA_G,  9'h009);   tchk1("M2 G entry invalid after flush",  t_hit, 1'b0);
    tlb_q(VA_4M, 9'h003);   tchk1("M3 4M entry invalid after flush", t_hit, 1'b0);
    tlb_q(mk_va(10'h008, 10'h000, 12'h000), 9'h001);
    tchk1("M4 L-group invalid after flush", t_hit, 1'b0);
    tlb_fill(VA_4K_C, 9'h002, 1'b0, 1'b0, 22'h000031, 8'hC1);
    tlb_q(VA_4K_C, 9'h002);
    tchk1 ("M5 refill after flush", t_hit,  1'b1);
    tchk8 ("M6 refill perm",      t_perm, 8'hC1);

    //========================================================== N. 参数化 4 项
    for (k = 0; k < 4; k = k + 1) begin
      tlb4_fill(mk_va(k[9:0], 10'h001, 12'h000), 9'h002, 22'h000200 + k[21:0]);
    end
    tlb4_fill(mk_va(10'h004, 10'h001, 12'h000), 9'h002, 22'h000204);
    t4_va = mk_va(10'h004, 10'h001, 12'h000); t4_asid = 9'h002; #1;
    n_check = n_check + 1;
    if (t4_hit !== 1'b1 || t4_ppn !== 22'h000204 || t4_perm !== 8'h1F || t4_is4m !== 1'b0) begin
      n_fail = n_fail + 1;
      $display("[FAIL] N1 4 项实例第 5 项: hit=%b ppn=%06x perm=%02x is_4m=%b",
               t4_hit, t4_ppn, t4_perm, t4_is4m);
    end
    t4_va = mk_va(10'h000, 10'h001, 12'h000); #1;
    n_check = n_check + 1;
    if (t4_hit !== 1'b0) begin
      n_fail = n_fail + 1;
      $display("[FAIL] N2 4 项实例未轮转淘汰第 1 项: hit=%b", t4_hit);
    end
    t4_va = mk_va(10'h001, 10'h001, 12'h000); #1;
    n_check = n_check + 1;
    if (t4_hit !== 1'b1) begin
      n_fail = n_fail + 1;
      $display("[FAIL] N3 4 项实例第 2 项丢失: hit=%b", t4_hit);
    end
    t4_va = mk_va(10'h003, 10'h001, 12'h000); #1;
    n_check = n_check + 1;
    if (t4_hit !== 1'b1) begin
      n_fail = n_fail + 1;
      $display("[FAIL] N4 4 项实例第 4 项丢失: hit=%b", t4_hit);
    end

    //================================================ O. PTW → TLB 回填闭环
    tlb_flush;
    ptw_walk(VA_4K, PPN_ROOT, 1);
    tlb_fill(p_va, 9'h007, p_perm[5], p_is_4m, p_ppn, p_perm);   // 用 PTW 输出回填
    tlb_q(VA_4K, 9'h007);
    tchk1 ("O1 hit after PTW refill",   t_hit,  1'b1);
    tchk22("O2 PTW refill ppn matches", t_ppn,  PPN_4K);
    tchk8 ("O3 PTW refill perm matches", t_perm, 8'hDF);
    tchk1 ("O4 PTW refill is_4m",   t_is4m, 1'b0);

    ptw_walk(VA_4M, PPN_ROOT, 1);
    tlb_fill(p_va, 9'h007, p_perm[5], p_is_4m, p_ppn, p_perm);
    tlb_q(VA_4M, 9'h007);
    tchk1 ("O5 4M hit after refill",    t_hit,  1'b1);
    tchk1 ("O6 4M refill is_4m=1",  t_is4m, 1'b1);
    tchk22("O7 4M refill ppn",      t_ppn,  PPN_4M);
    chk32 ("O8 4M refill PA compose", pa_4m(t_ppn, t_va), 32'h00DF_FABC);

    //========================================================== 汇总
    if (n_fail == 0) begin
      $display("TLB_PTW_UNIT: PASS (%0d checks)", n_check);
      $finish;
    end else begin
      $display("TLB_PTW_UNIT: FAIL (%0d/%0d checks failed)", n_fail, n_check);
      $finish;
    end
  end

endmodule
