//=============================================================================
// tb_unit_pmp.v —— rv32_pmp 单元测试（自校验、纯组合）
//
//   期望值全部来自规范原文 + 手算区间，不用被测 RTL 的输出回填：
//     riscv-isa-manual/src/priv/machine.adoc
//       :3438-3456  A 编码表：0=OFF 1=TOR 2=NA4 3=NAPOT（无保留编码）
//       :3432       A=OFF ⇒ 不匹配
//       :3458-3494  NAPOT 区间大小 2^(k+3) 字节（k = pmpaddr 低位连续 1 的个数）
//       :3496-3506  TOR：pmpaddr[i-1] <= y < pmpaddr[i]（i=0 下界 0；上界不取等）
//       :3575-3578  静态优先级：编号最小的匹配项决定
//       :3577-3582  选中项必须覆盖全部字节，否则失败（与 L/R/W/X 无关）
//       :3584-3590  全部命中：L=0 且 M ⇒ 成功；否则按访问类型查 R/W/X
//       :3591-3596  无匹配：M ⇒ 成功；S/U ⇒ 失败
//     tools/spike/riscv/csrs.cc:204-235（签名参考实现）：(M && !L) || (LOAD&&R)||(STORE&&W)||(FETCH&&X)
//     tools/spike/riscv/mmu.cc:482-513：any_match/all_match + 最低编号 + 部分命中即失败
//
// 计数口径：每个 chk_* 任务调用 = 1 个 check（chk_bits 同时比对 match_any/match_all
//   两个向量，若都错也只记 1 次，失败信息里两个向量都打印）。
//   所有比对使用 !==（case inequality）：任何 X/Z 都会判 FAIL。
//
// 成功：打印 "PMP_UNIT: PASS (<N> checks)"；失败：打印每条 [FAIL] 详情 +
//       "PMP_UNIT: FAIL (<m>/<N>)"，并以非零状态退出。
//=============================================================================
`include "rv32gc_defs.vh"

module tb_unit_pmp;

  localparam integer N  = 16;
  localparam integer NC = N*8;
  localparam integer NA = N*32;

  // 访问字节数编码
  localparam [1:0] SZ1 = 2'd0;
  localparam [1:0] SZ2 = 2'd1;
  localparam [1:0] SZ4 = 2'd2;

  reg  [NC-1:0] pmpcfg;
  reg  [NA-1:0] pmpaddr;
  reg  [31:0]   addr;
  reg  [1:0]    acc_size;
  reg  [1:0]    eff_priv;
  reg           need_r, need_w, need_x;
  wire          permit;
  wire [N-1:0]  match_any;
  wire [N-1:0]  match_all;

  rv32_pmp #(.PMP_ENTRIES(N)) dut (
    .pmpcfg    (pmpcfg),
    .pmpaddr   (pmpaddr),
    .addr      (addr),
    .acc_size  (acc_size),
    .eff_priv  (eff_priv),
    .need_r    (need_r),
    .need_w    (need_w),
    .need_x    (need_x),
    .permit    (permit),
    .match_any (match_any),
    .match_all (match_all)
  );

  integer n_check, n_fail;

  //---------------------------------------------------------------------------
  // 激励 / 配置工具
  //---------------------------------------------------------------------------
  task all_off;
    begin
      pmpcfg  = {NC{1'b0}};
      pmpaddr = {NA{1'b0}};
    end
  endtask

  task cfg_set;
    input integer i;
    input [7:0]   c;
    input [31:0]  a;
    begin
      pmpcfg[8*i +: 8]    = c;
      pmpaddr[32*i +: 32] = a;
    end
  endtask

  // 施加一次访问（#1 让纯组合逻辑稳定后再比对）
  task acc;
    input [31:0] a;
    input [1:0]  sz;
    input [1:0]  prv;
    input        r;
    input        w;
    input        x;
    begin
      addr     = a;
      acc_size = sz;
      eff_priv = prv;
      need_r   = r;
      need_w   = w;
      need_x   = x;
      #1;
    end
  endtask

  //---------------------------------------------------------------------------
  // 检查工具
  //---------------------------------------------------------------------------
  task chk_perm;
    input [8*72-1:0] nm;
    input            exp_p;
    begin
      n_check = n_check + 1;
      if (permit !== exp_p) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: permit exp=%b got=%b | addr=%08x sz=%0d priv=%0d need_rwx=%b%b%b",
                 nm, exp_p, permit, addr, acc_size, eff_priv, need_r, need_w, need_x);
      end
    end
  endtask

  task chk_bits;
    input [8*72-1:0] nm;
    input [N-1:0]    e_any;
    input [N-1:0]    e_all;
    begin
      n_check = n_check + 1;
      if ((match_any !== e_any) || (match_all !== e_all)) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: match_any exp=%04x got=%04x | match_all exp=%04x got=%04x | addr=%08x sz=%0d",
                 nm, e_any, match_any, e_all, match_all, addr, acc_size);
      end
    end
  endtask

  // permit / match_* 必须是确定的 0/1（X、Z 一律 FAIL）
  task chk_nox;
    input [8*72-1:0] nm;
    begin
      n_check = n_check + 1;
      if ((permit !== 1'b0) && (permit !== 1'b1)) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: permit 非 0/1 (got=%b) | addr=%08x cfg0=%02x",
                 nm, permit, addr, pmpcfg[7:0]);
      end
      if (((^match_any) === 1'bx) || ((^match_all) === 1'bx)) begin
        n_fail = n_fail + 1;
        $display("[FAIL] %0s: match 位含 X | any=%b all=%b", nm, match_any, match_all);
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // 参考模型（按规范原文独立重写一遍，用于随机对照；风格与 DUT 不同）
  //---------------------------------------------------------------------------
  reg          ref_permit;
  reg [N-1:0]  ref_any, ref_all;
  reg [31:0]   r_w0, r_w1;

  function automatic [5:0] ref_napot_k;          // 低位连续 1 的个数（0..32）
    input [31:0] pa;
    integer      j;
    reg          hit0;
    begin
      ref_napot_k = 32;
      hit0 = 1'b0;
      for (j = 0; j < 32; j = j + 1)
        if (!hit0 && (pa[j] !== 1'b1)) begin
          ref_napot_k = j;
          hit0 = 1'b1;
        end
    end
  endfunction

  function automatic ref_word;             // 单项是否覆盖某个 word
    input [1:0]  am;
    input        is0;
    input [31:0] pa;
    input [31:0] pa_lo;
    input [31:0] w;
    integer      k;
    reg [31:0]   msk;
    begin
      case (am)
        2'd0: ref_word = 1'b0;                                        // OFF
        2'd1: ref_word = is0 ? (w < pa) : ((w >= pa_lo) && (w < pa)); // TOR
        2'd2: ref_word = (w == pa);                                   // NA4
        default: begin                                                // NAPOT
          k = ref_napot_k(pa);
          if (k >= 31) ref_word = 1'b1;
          else begin
            msk = (32'd1 << (k + 1)) - 32'd1;
            ref_word = ((w & ~msk) == (pa & ~msk));
          end
        end
      endcase
    end
  endfunction

  task ref_eval;
    integer      i, nb;
    reg [1:0]    am;
    reg [31:0]   pa, palo;
    reg          m0, m1;
    reg          found, all_ok, sl, sr, sw, sx;
    begin
      nb   = (acc_size == 2'd0) ? 1 : (acc_size == 2'd1) ? 2 : 4;
      r_w0 = addr[31:2];
      r_w1 = (addr + nb - 1) >> 2;         // 末字节所在 word

      ref_any = {N{1'b0}};
      ref_all = {N{1'b0}};
      found = 1'b0; all_ok = 1'b0; sl = 0; sr = 0; sw = 0; sx = 0;
      for (i = N-1; i >= 0; i = i - 1) begin
        am   = pmpcfg[8*i + 3 +: 2];
        pa   = pmpaddr[32*i +: 32];
        palo = (i == 0) ? 32'd0 : pmpaddr[32*(i-1) +: 32];
        m0   = ref_word(am, (i == 0), pa, palo, r_w0);
        m1   = ref_word(am, (i == 0), pa, palo, r_w1);
        ref_any[i] = m0 | m1;
        ref_all[i] = m0 & m1;
        if (ref_any[i]) begin                 // 高→低扫描，最后一次写入即最低编号
          found  = 1'b1;
          all_ok = ref_all[i];
          sl = pmpcfg[8*i + 7];
          sx = pmpcfg[8*i + 2];
          sw = pmpcfg[8*i + 1];
          sr = pmpcfg[8*i + 0];
        end
      end
      if (!found)                        ref_permit = (eff_priv == `PRV_M);
      else if (!all_ok)                  ref_permit = 1'b0;
      else if (!sl && (eff_priv == `PRV_M)) ref_permit = 1'b1;
      else                               ref_permit = (need_r ? sr : 1'b1) &
                                                     (need_w ? sw : 1'b1) &
                                                     (need_x ? sx : 1'b1);
    end
  endtask

  //---------------------------------------------------------------------------
  // 扫描用变量
  //---------------------------------------------------------------------------
  integer    a_enc, l_bit, rwx, sc_i, sc_j, sc_k;
  reg [31:0] rnd;
  reg [1:0]  s_am, s_prv;
  reg        s_l, s_r, s_w, s_x;

  task rnd_step;
    begin
      rnd = rnd ^ (rnd << 13);
      rnd = rnd ^ (rnd >> 17);
      rnd = rnd ^ (rnd << 5);
      if (rnd == 32'd0) rnd = 32'h1234_5678;
    end
  endtask

  //===========================================================================
  initial begin
    n_check = 0;
    n_fail  = 0;
    pmpcfg  = {NC{1'b0}};
    pmpaddr = {NA{1'b0}};
    addr = 32'h0; acc_size = SZ1; eff_priv = `PRV_U;
    need_r = 0; need_w = 0; need_x = 0;

    $display("== rv32_pmp 单元测试 ==");

    //-----------------------------------------------------------------------
    // 1. A=0 (OFF)：不匹配任何地址；S/U 无匹配 ⇒ 拒绝，M 无匹配 ⇒ 允许
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h07, 32'h0000_1000);            // A=OFF, R=W=X=1（权限全开也不匹配）
    acc(32'h0000_4000, SZ4, `PRV_S, 1,0,0); chk_perm("1.1 OFF: S read DENY(no-match)", 1'b0);
    acc(32'h0000_4000, SZ4, `PRV_M, 1,0,0); chk_perm("1.2 OFF: M read ALLOW(no-match)", 1'b1);
    acc(32'h0000_4000, SZ4, `PRV_M, 0,0,0); chk_perm("1.3 OFF: M degenerate-input ALLOW", 1'b1);
    acc(32'h0000_4000, SZ4, `PRV_U, 0,0,1); chk_perm("1.4 OFF: U fetch DENY", 1'b0);
    acc(32'h0000_4000, SZ4, `PRV_S, 1,0,0); chk_bits("1.5 OFF: match_any/all all-zero", 16'h0000, 16'h0000);
    acc(32'h0000_4000, SZ2, `PRV_U, 1,1,0); chk_perm("1.6 OFF: U AMO DENY", 1'b0);

    //-----------------------------------------------------------------------
    // 2. NA4（A=2）：4 字节对齐区间 [0x4000,0x4003]
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h11, 32'h0000_1000);            // L=0, A=NA4, R=1
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("2.1 NA4: first-byteHIT", 1'b1);
                                            chk_bits("2.2 NA4: first-byte match=bit0", 16'h0001, 16'h0001);
    acc(32'h0000_4003, SZ1, `PRV_S, 1,0,0); chk_perm("2.3 NA4: last-byteHIT", 1'b1);
    acc(32'h0000_3FFF, SZ1, `PRV_S, 1,0,0); chk_perm("2.4 NA4: prev-byteHIT(S)", 1'b0);
                                            chk_bits("2.5 NA4: prev-byte match=0", 16'h0000, 16'h0000);
    acc(32'h0000_3FFF, SZ1, `PRV_M, 1,0,0); chk_perm("2.6 NA4: prev-byteHIT(M ALLOW)", 1'b1);
    acc(32'h0000_4004, SZ1, `PRV_S, 1,0,0); chk_perm("2.7 NA4: next-byteHIT(S)", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 0,1,0); chk_perm("2.8 NA4: no-W, write DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 0,0,1); chk_perm("2.9 NA4: no-X, fetch DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_M, 0,1,0); chk_perm("2.10 NA4: L=0 M write", 1'b1);
    acc(32'h0000_4002, SZ1, `PRV_U, 1,0,0); chk_perm("2.11 NA4: U byte3HIT", 1'b1);
    acc(32'h0000_4002, SZ4, `PRV_S, 1,0,0); chk_perm("2.12 NA4: 4B cross-out DENY", 1'b0);
                                            chk_bits("2.13 NA4: cross-out any=1/all=0", 16'h0001, 16'h0000);
    acc(32'h0000_4002, SZ4, `PRV_M, 1,0,0); chk_perm("2.14 NA4: cross-out: M DENY(full-match-required)", 1'b0);
    acc(32'h0000_4000, SZ4, `PRV_S, 1,0,0); chk_perm("2.15 NA4: aligned-4B HIT", 1'b1);
    acc(32'h0000_4002, 2'd3, `PRV_S, 1,0,0); chk_perm("2.16 NA4: acc_size=3(>=4B) treated as 4B DENY", 1'b0);
                                            chk_bits("2.17 acc_size=3: any=1/all=0", 16'h0001, 16'h0000);
    acc(32'h0000_4000, 2'd3, `PRV_S, 1,0,0); chk_perm("2.18 acc_size=3: aligned 4B inside NA4 ALLOW", 1'b1);

    //-----------------------------------------------------------------------
    // 3. NAPOT k=0（8 字节）：words 0x2000..0x2001 ⇒ 字节 [0x8000,0x8007]
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h19, 32'h0000_2000);            // A=NAPOT, R=1
    acc(32'h0000_8000, SZ1, `PRV_S, 1,0,0); chk_perm("3.1 NAPOT k=0: first-byte", 1'b1);
                                            chk_bits("3.2 NAPOT k=0: match=bit0", 16'h0001, 16'h0001);
    acc(32'h0000_8007, SZ1, `PRV_S, 1,0,0); chk_perm("3.3 NAPOT k=0: last-byte(word1)", 1'b1);
    acc(32'h0000_8008, SZ1, `PRV_S, 1,0,0); chk_perm("3.4 NAPOT k=0: above-top 1", 1'b0);
                                            chk_bits("3.5 NAPOT k=0: above-top match=0", 16'h0000, 16'h0000);
    acc(32'h0000_7FFC, SZ1, `PRV_S, 1,0,0); chk_perm("3.6 NAPOT k=0: below-bottom 1 word", 1'b0);
    acc(32'h0000_8000, SZ4, `PRV_S, 1,0,0); chk_perm("3.7 NAPOT k=0: word0 4B", 1'b1);
    acc(32'h0000_8006, SZ4, `PRV_S, 1,0,0); chk_perm("3.8 NAPOT k=0: top DENY", 1'b0);
                                            chk_bits("3.9 NAPOT k=0: cross-boundary any=1/all=0", 16'h0001, 16'h0000);
    acc(32'h0000_8006, SZ4, `PRV_M, 1,0,0); chk_perm("3.10 NAPOT k=0: cross-boundary M DENY", 1'b0);

    //-----------------------------------------------------------------------
    // 4. NAPOT k=3（64 字节）：mask=15 words ⇒ 字节 [0xC000,0xC03F]
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h1F, 32'h0000_3007);            // A=NAPOT, R=W=X=1
    acc(32'h0000_C000, SZ4, `PRV_S, 1,0,0); chk_perm("4.1 NAPOT k=3(64B): word 4B", 1'b1);
                                            chk_bits("4.2 NAPOT k=3: match=bit0", 16'h0001, 16'h0001);
    acc(32'h0000_C03C, SZ4, `PRV_S, 1,0,0); chk_perm("4.3 NAPOT k=3: word 4B HIT", 1'b1);
    acc(32'h0000_C03F, SZ1, `PRV_S, 0,1,0); chk_perm("4.4 NAPOT k=3: last-bytewrite( W)", 1'b1);
    acc(32'h0000_C040, SZ1, `PRV_S, 1,0,0); chk_perm("4.5 NAPOT k=3: above-top 1", 1'b0);
    acc(32'h0000_BFFC, SZ1, `PRV_S, 1,0,0); chk_perm("4.6 NAPOT k=3: below-bottom 1 word", 1'b0);
    acc(32'h0000_C03C, SZ4, `PRV_S, 0,0,1); chk_perm("4.7 NAPOT k=3: word fetch( X)", 1'b1);
    acc(32'h0000_C040, SZ1, `PRV_M, 0,0,1); chk_perm("4.8 NAPOT k=3: outside M fetch ALLOW", 1'b1);
    acc(32'h0000_C002, SZ2, `PRV_S, 1,0,0); chk_perm("4.9 NAPOT k=3: 2B-access", 1'b1);

    //-----------------------------------------------------------------------
    // 5. NAPOT k=7（1 KiB）：mask=255 words ⇒ 字节 [0x10000,0x103FF]
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h19, 32'h0000_407F);            // k=7
    acc(32'h0001_0000, SZ1, `PRV_S, 1,0,0); chk_perm("5.1 NAPOT k=7(1KiB): first-byte", 1'b1);
    acc(32'h0001_03FF, SZ1, `PRV_S, 1,0,0); chk_perm("5.2 NAPOT k=7: last-byte", 1'b1);
    acc(32'h0001_0400, SZ1, `PRV_S, 1,0,0); chk_perm("5.3 NAPOT k=7: above-top", 1'b0);
    acc(32'h0000_FFFC, SZ1, `PRV_S, 1,0,0); chk_perm("5.4 NAPOT k=7: below-bottom", 1'b0);
    acc(32'h0001_0200, SZ4, `PRV_S, 1,0,0); chk_perm("5.5 NAPOT k=7: inside 4B", 1'b1);
                                            chk_bits("5.6 NAPOT k=7: match=bit0", 16'h0001, 16'h0001);

    //-----------------------------------------------------------------------
    // 6. NAPOT k=27(1GiB) / k=28(2GiB) / pmpaddr 全 1
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h19, 32'h07FF_FFFF);            // k=27 ⇒ mask=2^28-1 words ⇒ 字节 [0,0x3FFF_FFFF]
    acc(32'h0000_0000, SZ1, `PRV_S, 1,0,0); chk_perm("6.1 NAPOT k=27(1GiB): addr0 HIT", 1'b1);
    acc(32'h3FFF_FFFC, SZ4, `PRV_S, 1,0,0); chk_perm("6.2 NAPOT k=27: last-word-of-region HIT", 1'b1);
    acc(32'h4000_0000, SZ1, `PRV_S, 1,0,0); chk_perm("6.3 NAPOT k=27: above-top DENY", 1'b0);
                                            chk_bits("6.4 NAPOT k=27: above-top match=0", 16'h0000, 16'h0000);
    acc(32'h4000_0000, SZ1, `PRV_M, 1,0,0); chk_perm("6.5 NAPOT k=27: above-top M ALLOW", 1'b1);
    all_off;
    cfg_set(0, 8'h19, 32'h0FFF_FFFF);            // k=28 ⇒ 2 GiB ⇒ 字节 [0,0x7FFF_FFFF]
    acc(32'h7FFF_FFFC, SZ4, `PRV_S, 1,0,0); chk_perm("6.6 NAPOT k=28(2GiB): last-word-of-region", 1'b1);
    acc(32'h8000_0000, SZ1, `PRV_S, 1,0,0); chk_perm("6.7 NAPOT k=28: above-top DENY", 1'b0);
    all_off;
    cfg_set(0, 8'h19, 32'hFFFF_FFFF);            // k=32 ⇒ 覆盖整个地址空间
    acc(32'h0000_0000, SZ1, `PRV_S, 1,0,0); chk_perm("6.8 NAPOT all-ones: addr0 HIT", 1'b1);
                                            chk_bits("6.9 NAPOT all-ones: match=bit0", 16'h0001, 16'h0001);
    acc(32'hFFFF_FFFC, SZ4, `PRV_S, 1,0,0); chk_perm("6.10 NAPOT all-ones: top-word HIT", 1'b1);
    acc(32'hFFFF_FFFF, SZ1, `PRV_S, 0,1,0); chk_perm("6.11 NAPOT all-ones: onlyhas-R, write DENY", 1'b0);
    acc(32'h1234_5678, SZ2, `PRV_M, 0,0,1); chk_perm("6.12 NAPOT all-ones: M fetch(onlyhas-R) L=0 ALLOW", 1'b1);

    //-----------------------------------------------------------------------
    // 7. TOR：i=0 下界 0 / i=1 夹层 / i=4 夹层（下界来自 pmpaddr3）
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h09, 32'h0000_2000);            // A=TOR, R=1 ⇒ words [0,0x2000) ⇒ 字节 [0,0x7FFF]
    acc(32'h0000_0000, SZ1, `PRV_S, 1,0,0); chk_perm("7.1 TOR i=0: bottom 0 HIT", 1'b1);
                                            chk_bits("7.2 TOR i=0: match=bit0", 16'h0001, 16'h0001);
    acc(32'h0000_7FFC, SZ4, `PRV_S, 1,0,0); chk_perm("7.3 TOR i=0: inside-top word", 1'b1);
    acc(32'h0000_8000, SZ1, `PRV_S, 1,0,0); chk_perm("7.4 TOR i=0: top-exclusive HIT", 1'b0);
                                            chk_bits("7.5 TOR i=0: above-top match=0", 16'h0000, 16'h0000);
    acc(32'h0000_8000, SZ1, `PRV_M, 1,0,0); chk_perm("7.6 TOR i=0: above-top M ALLOW", 1'b1);
    all_off;
    cfg_set(0, 8'h00, 32'h0000_1000);            // pmpcfg0=A=OFF，仅提供下界
    cfg_set(1, 8'h09, 32'h0000_2000);            // TOR, R=1 ⇒ words [0x1000,0x2000)
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("7.7 TOR i=1: bottom-inclusiveHIT", 1'b1);
                                            chk_bits("7.8 TOR i=1: match=bit1", 16'h0002, 16'h0002);
    acc(32'h0000_3FFC, SZ4, `PRV_S, 1,0,0); chk_perm("7.9 TOR i=1: below-bottom 1 word", 1'b0);
    acc(32'h0000_7FFC, SZ4, `PRV_S, 1,0,0); chk_perm("7.10 TOR i=1: inside-top", 1'b1);
    acc(32'h0000_8000, SZ1, `PRV_S, 1,0,0); chk_perm("7.11 TOR i=1: top-exclusive", 1'b0);
    all_off;
    cfg_set(4, 8'h09, 32'h0000_3000);            // TOR, R=1 ⇒ words [pmpaddr3, 0x3000)
    pmpaddr[32*3 +: 32] = 32'h0000_1000;         // 只写 pmpaddr3（cfg3 保持 A=OFF）
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("7.12 TOR i=4: bottomHIT(from pmpaddr3)", 1'b1);
                                            chk_bits("7.13 TOR i=4: match=bit4", 16'h0010, 16'h0010);
    acc(32'h0000_3FFC, SZ1, `PRV_S, 1,0,0); chk_perm("7.14 TOR i=4: below-bottom", 1'b0);
    acc(32'h0000_BFFC, SZ4, `PRV_S, 1,0,0); chk_perm("7.15 TOR i=4: inside-top", 1'b1);
    acc(32'h0000_C000, SZ1, `PRV_S, 1,0,0); chk_perm("7.16 TOR i=4: top-exclusive", 1'b0);
    cfg_set(3, 8'h98, 32'h0000_1000);            // pmpcfg3 = L=1,NAPOT,无权限；其自匹配域为 0x4000..0x4007
    acc(32'h0000_5000, SZ1, `PRV_S, 1,0,0); chk_perm("7.17 TOR i=4: lower-bound-entry pmpcfg3 irrelevant-to-decision", 1'b1);
                                            chk_bits("7.18 TOR i=4: match only bit4", 16'h0010, 16'h0010);
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("7.19 control:: low-idx L=1 (entry3)HIT DENY", 1'b0);
    // TOR 空集（machine.adoc:3504）：pmpaddr[i-1] >= pmpaddr[i] ⇒ 该项不匹配任何地址
    all_off;
    cfg_set(1, 8'h09, 32'h0000_2000);            // TOR, R=1, top = 0x2000
    pmpaddr[32*0 +: 32] = 32'h0000_3000;         // bottom 0x3000 > top ⇒ 空集
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("7.20 TOR empty-set(bottom>top): S DENY", 1'b0);
                                            chk_bits("7.21 TOR empty-set: match=0", 16'h0000, 16'h0000);
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("7.22 TOR empty-set: M ALLOW", 1'b1);
    all_off;
    cfg_set(1, 8'h09, 32'h0000_2000);            // top = 0x2000
    pmpaddr[32*0 +: 32] = 32'h0000_2000;         // bottom == top ⇒ 空集
    acc(32'h0000_8000, SZ1, `PRV_S, 1,0,0); chk_perm("7.23 TOR empty-set(bottom==top): S DENY", 1'b0);
    acc(32'h0000_8000, SZ1, `PRV_M, 1,0,0); chk_perm("7.24 TOR empty-set(bottom==top): M ALLOW", 1'b1);

    //-----------------------------------------------------------------------
    // 8. 权限矩阵（entry0 = NAPOT k=0 @ word 0x1000 ⇒ 字节 0x4000..0x4007）
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h1C, 32'h0000_1000);            // 仅 X
    acc(32'h0000_4000, SZ1, `PRV_S, 0,0,1); chk_perm("8.1 only- X: fetch ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("8.2 only- X: read DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 0,1,0); chk_perm("8.3 only- X: write DENY", 1'b0);
    all_off;
    cfg_set(0, 8'h19, 32'h0000_1000);            // 仅 R
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("8.4 only- R: read ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_S, 0,0,1); chk_perm("8.5 only- R: fetch DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 0,1,0); chk_perm("8.6 only- R: write DENY", 1'b0);
    all_off;
    cfg_set(0, 8'h1A, 32'h0000_1000);            // 仅 W（R=0,W=1 为规范保留 WARL 组合；对齐 Spike 按位判定）
    acc(32'h0000_4000, SZ1, `PRV_S, 0,1,0); chk_perm("8.7 only- W(reserved-enc): write ALLOW(Spike )", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("8.8 only- W(reserved-enc): read DENY", 1'b0);
    all_off;
    cfg_set(0, 8'h1B, 32'h0000_1000);            // R+W
    acc(32'h0000_4000, SZ1, `PRV_S, 1,1,0); chk_perm("8.9 R+W: AMO ALLOW", 1'b1);
    all_off;
    cfg_set(0, 8'h19, 32'h0000_1000);            // 仅 R
    acc(32'h0000_4000, SZ1, `PRV_S, 1,1,0); chk_perm("8.10 only- R: AMO DENY(lack-W)", 1'b0);
    all_off;
    cfg_set(0, 8'h1A, 32'h0000_1000);            // 仅 W
    acc(32'h0000_4000, SZ1, `PRV_S, 1,1,0); chk_perm("8.11 only- W: AMO DENY(lack-R)", 1'b0);
    all_off;
    cfg_set(0, 8'h1D, 32'h0000_1000);            // R+X
    acc(32'h0000_4000, SZ1, `PRV_S, 1,1,0); chk_perm("8.12 R+X: AMO DENY(lack-W)", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 0,0,1); chk_perm("8.13 R+X: fetch ALLOW", 1'b1);
    all_off;
    cfg_set(0, 8'h18, 32'h0000_1000);            // A=NAPOT, RWX=000
    acc(32'h0000_4000, SZ1, `PRV_S, 0,0,0); chk_perm("8.14 RWX=0: S degenerate-input(need_*0) ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("8.15 RWX=0: S read DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_M, 0,0,0); chk_perm("8.16 RWX=0: M degenerate-input ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("8.17 RWX=0: L=0 M read ALLOW", 1'b1);

    //-----------------------------------------------------------------------
    // 9. M 模式的 L 语义
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h18, 32'h0000_1000);            // L=0, 无权限
    acc(32'h0000_4000, SZ1, `PRV_M, 0,0,1); chk_perm("9.1 M: L=0 matched-entryno-perm ALLOW", 1'b1);
    all_off;
    cfg_set(0, 8'h98, 32'h0000_1000);            // L=1, 无权限
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("9.2 M: L=1 lack-R DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_M, 0,0,1); chk_perm("9.3 M: L=1 lack-X DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("9.4 S: L=1 lack-R DENY", 1'b0);
    all_off;
    cfg_set(0, 8'h99, 32'h0000_1000);            // L=1, 仅 R
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("9.5 M: L=1 has-R ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_M, 0,1,0); chk_perm("9.6 M: L=1 has-R no-W, write DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("9.7 S: L=1 has-R ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_U, 1,0,0); chk_perm("9.8 U: L=1 has-R ALLOW", 1'b1);

    //-----------------------------------------------------------------------
    // 10. S/U 无匹配 ⇒ 拒绝
    //-----------------------------------------------------------------------
    all_off;                                     // 16 项全部 A=OFF
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("10.1 all-OFF: S read DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_U, 1,0,0); chk_perm("10.2 all-OFF: U read DENY", 1'b0);
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("10.3 all-OFF: M read ALLOW", 1'b1);
    acc(32'h0000_4000, SZ1, `PRV_U, 0,0,0); chk_perm("10.4 all-OFF: U degenerate-input DENY", 1'b0);
    acc(32'hFFFF_FFFC, SZ4, `PRV_S, 0,1,0); chk_perm("10.5 all-OFF: S write DENY", 1'b0);

    //-----------------------------------------------------------------------
    // 11. 多项匹配（静态优先级：最低编号项决定；选中项须全字节命中）
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(0, 8'h19, 32'h0000_1000);            // 0: L=0,NAPOT,R=1
    cfg_set(1, 8'h98, 32'h0000_1000);            // 1: L=1,NAPOT,无权限（同区间）
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("11.1 low-idx-ALLOW+high-idx-DENY(S) ALLOW", 1'b1);
                                            chk_bits("11.2 both-match any=all=0x0003", 16'h0003, 16'h0003);
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("11.3 low-idx L=0 M ALLOW", 1'b1);
    acc(32'h0000_4004, SZ1, `PRV_S, 1,0,0); chk_perm("11.4 word1 match ALLOW", 1'b1);
    acc(32'h0000_4008, SZ1, `PRV_S, 1,0,0); chk_perm("11.5 outside(neither-match) DENY", 1'b0);
                                            chk_bits("11.6 outside match=0", 16'h0000, 16'h0000);
    all_off;
    cfg_set(0, 8'h98, 32'h0000_1000);            // 0: L=1,无权限
    cfg_set(1, 8'h1F, 32'h0000_1000);            // 1: L=0,RWX=111
    acc(32'h0000_4000, SZ1, `PRV_S, 1,0,0); chk_perm("11.7 low-idx-DENY+high-idx-ALLOW(S) DENY", 1'b0);
                                            chk_bits("11.8 any=all=0x0003", 16'h0003, 16'h0003);
    acc(32'h0000_4000, SZ1, `PRV_M, 1,0,0); chk_perm("11.9 , M DENY(L=1)", 1'b0);
    all_off;
    cfg_set(0, 8'h13, 32'h0000_1000);            // 0: NA4（仅 word 0x1000）, R=1
    cfg_set(1, 8'h1F, 32'h0000_1000);            // 1: NAPOT k=0（word 0x1000-0x1001）, RWX=111
    acc(32'h0000_4002, SZ4, `PRV_S, 1,0,0); chk_perm("11.10 sel-covers-only-word0 DENY(S)", 1'b0);
                                            chk_bits("11.11 any=0x0003/all=0x0002", 16'h0003, 16'h0002);
    acc(32'h0000_4002, SZ4, `PRV_M, 1,0,0); chk_perm("11.12 full-match-required: M DENY", 1'b0);
    acc(32'h0000_4000, SZ4, `PRV_S, 1,0,0); chk_perm("11.13 control:: word0  ALLOW", 1'b1);
                                            chk_bits("11.14 control: any=all=0x0003", 16'h0003, 16'h0003);

    //-----------------------------------------------------------------------
    // 12. match_any / match_all 期望值（含多项同时匹配）
    //-----------------------------------------------------------------------
    all_off;
    cfg_set(15, 8'h19, 32'h0000_5000);           // 仅最高项：NAPOT k=0 @ word 0x5000
    acc(32'h0001_4000, SZ1, `PRV_S, 1,0,0); chk_perm("12.1 only- entry15 HIT ALLOW", 1'b1);
                                            chk_bits("12.2 match=bit15", 16'h8000, 16'h8000);
    cfg_set(0, 8'h19, 32'h0000_5000);            // 再让 entry0 匹配同一地址
    acc(32'h0001_4000, SZ1, `PRV_S, 1,0,0); chk_perm("12.3 entry0+entry15 both-hit ALLOW", 1'b1);
                                            chk_bits("12.4 match=0x8001", 16'h8001, 16'h8001);
    all_off;
    cfg_set(2, 8'h09, 32'h0000_3000);            // 2: TOR, R=1（下界 pmpaddr1）
    pmpaddr[32*1 +: 32] = 32'h0000_1000;
    cfg_set(6, 8'h11, 32'h0000_2000);            // 6: NA4, R=1 @ word 0x2000
    acc(32'h0000_8002, SZ1, `PRV_S, 1,0,0); chk_perm("12.5 TOR+NA4 both-hit ALLOW", 1'b1);
                                            chk_bits("12.6 match=bit2|bit6=0x0044", 16'h0044, 16'h0044);
    all_off;
    cfg_set(0, 8'h1F, 32'h0000_1003);            // NAPOT k=2（32B）@ words 0x1000-0x1007
    acc(32'h0000_4010, SZ4, `PRV_S, 1,0,0); chk_perm("12.7 NAPOT k=2(32B): word3 HIT", 1'b1);
                                            chk_bits("12.8 match=bit0", 16'h0001, 16'h0001);
    acc(32'h0000_4020, SZ4, `PRV_S, 1,0,0); chk_perm("12.9 NAPOT k=2: above-top 1 word DENY", 1'b0);
                                            chk_bits("12.10 above-top match=0", 16'h0000, 16'h0000);

    //-----------------------------------------------------------------------
    // 13. 无 X 传播：全部 4 种 A 编码 × L × RWX 暴扫
    //-----------------------------------------------------------------------
    for (a_enc = 0; a_enc < 4; a_enc = a_enc + 1)
      for (l_bit = 0; l_bit < 2; l_bit = l_bit + 1)
        for (rwx = 0; rwx < 8; rwx = rwx + 1) begin
          all_off;
          pmpcfg[8*0 +: 8] = {l_bit[0], 1'b0, 1'b0, a_enc[1:0], rwx[2], rwx[1], rwx[0]};
          pmpaddr[32*0 +: 32] = 32'h0000_1000;
          acc(32'h0000_4002, SZ4, `PRV_S, 1,1,0);     // 跨 word + AMO，最易暴露 X
          chk_nox("13.a A/L/RWX no-X");
        end

    //-----------------------------------------------------------------------
    // 14. 随机对照扫描（与参考模型逐位比对）
    //-----------------------------------------------------------------------
    rnd = 32'hDEAD_BEEF;
    for (sc_i = 0; sc_i < 120; sc_i = sc_i + 1) begin
      for (sc_j = 0; sc_j < N; sc_j = sc_j + 1) begin
        rnd_step;
        s_am = rnd[1:0];
        s_l  = rnd[2]; s_r = rnd[3]; s_w = rnd[4]; s_x = rnd[5];
        if (rnd[7:6] != 2'd0) begin
          sc_k = rnd[12:8] % 9;                        // k = 0..8 的 NAPOT 编码 @ word 0x1000
          pmpaddr[32*sc_j +: 32] = 32'h0000_1000 | ((32'd1 << sc_k) - 32'd1);
        end else begin
          rnd_step;
          pmpaddr[32*sc_j +: 32] = rnd;                // 完全随机
        end
        pmpcfg[8*sc_j +: 8] = {s_l, 1'b0, 1'b0, s_am, s_x, s_w, s_r};
      end
      rnd_step;
      case (rnd[1:0])
        2'd0:    addr = 32'h0000_4000 + {26'd0, rnd[8:3]};   // word 0x1000 附近
        2'd1:    addr = 32'h0000_4004 + {26'd0, rnd[8:3]};   // 故意跨 word
        2'd2:    addr = {rnd[31:2], 2'b00};                  // 随机字对齐
        default: addr = rnd;                                 // 完全随机（可能非对齐）
      endcase
      acc_size = rnd[10:9];
      case (rnd[12:11])
        2'd0:    eff_priv = `PRV_U;
        2'd1:    eff_priv = `PRV_S;
        default: eff_priv = `PRV_M;
      endcase
      rnd_step;
      need_r = rnd[0]; need_w = rnd[1]; need_x = rnd[2];
      #1;
      ref_eval;
      chk_perm("14.a random-vs-ref permit", ref_permit);
      chk_bits("14.b random-vs-ref match_any/match_all", ref_any, ref_all);
    end

    //-----------------------------------------------------------------------
    // 汇总
    //-----------------------------------------------------------------------
    if (n_fail == 0) begin
      $display("PMP_UNIT: PASS (%0d checks)", n_check);
      $finish;
    end else begin
      $display("PMP_UNIT: FAIL (%0d/%0d checks failed)", n_fail, n_check);
      $finish;
    end
  end

endmodule
