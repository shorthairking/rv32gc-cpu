//==============================================================================
// sim/unit/tb_pmp_check.sv —— PMP 16 项检查单元测试（L0）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A）
// 依据    : docs/design/08-baseline-5stage.md §5.4/§5.5（抉择 3/5/6）
//           docs/kb/isa-notes.md §3.1–§3.4（PMP 三条强制项 + 每笔独立）、T4
//           riscv-isa-manual/src/priv/machine.adoc（Priority and Matching Logic）
//
// 覆盖要求（验收判据 ③，逐条对应）：
//   · TOR   : ≥2 例（含第 0 项 TOR 下界=0、上界=pmpaddr[i]）
//   · NA4   : ≥2 例（G=0 下可用；覆盖 4 B）
//   · NAPOT : ≥2 例（含 N=0 的 8 B 编码 …yyy0、更大块）
//   · OFF   : ≥2 例（不匹配任何地址）
//   · 16 项优先级：**低编号优先**（项 0 与项 1 都命中 ⇒ 项 0 决定结果）
//   · G=0 粒度：NA4 可用且 `pmpaddr` 低位全部有效（**不做低位掩码**）
//   · 无匹配：M 成功 / S 失败 / U 失败
//   · AMO 被 PMP 拒 **恒 cause 7**（T4）
//   · 非对齐跨区域拆两笔，**每笔独立**（部分通过、部分失败）
//
// ★ 地址口径（本 TB 的第一条纪律，2026-09-14 修正）：
//   ISA 规定 `pmpaddr` 编码 RV32 34 位物理地址的 **[33:2]**（即 pmpaddr = PA>>2，
//   [norm:pmp_addr_encoding]，machine.adoc:3379-3383），**不是**字节地址本身。
//   因此本 TB 的所有 `set_addr()` **一律经 pa2addr()/napot_addr() 换算**；
//   断言的访存地址 acc_pa 仍是**字节物理地址**（与 pmp_check 的 acc_pa_i 端口契约一致）。
//
// 判定纪律（08 §8.1"未捕获即失败"）：
//   · 任何断言不成立 ⇒ 立即 $fatal（非零退出码），且**绝不打印 PASS**；
//   · 全部通过才打印最后一行 `TB_PMP_CHECK: PASS`；
//   · 文件内**没有**任何兜底文案含 "PASS" 字样（唯一 PASS 是成功路径的末行）。
//
// 顶层    : tb_pmp_check_top（验收命令用 -s tb_pmp_check_top）
// 风格    : DUT 为纯组合；TB 用 task 做「设配置 → 评结果 → 断言」，无 always @(*)。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_pmp_check_top;

    //--------------------------------------------------------------------------
    // 0. 参数与常量镜像（全部取自真源）
    //--------------------------------------------------------------------------
    localparam integer N        = `RV32GC_PMP_ENTRIES;   // 16
    localparam integer CFG_W    = 8;

    localparam [1:0] A_OFF   = `RV32GC_PMP_A_OFF;
    localparam [1:0] A_TOR   = `RV32GC_PMP_A_TOR;
    localparam [1:0] A_NA4   = `RV32GC_PMP_A_NA4;
    localparam [1:0] A_NAPOT = `RV32GC_PMP_A_NAPOT;

    localparam [1:0] PRIV_U  = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S  = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M  = `RV32GC_PRIV_M;

    // DUT 的访问类型编码（与 pmp_check.v 头部一致）
    localparam [1:0] T_LOAD  = 2'd0;
    localparam [1:0] T_STORE = 2'd1;
    localparam [1:0] T_EXEC  = 2'd2;
    localparam [1:0] T_AMO   = 2'd3;

    localparam [4:0] C_INSN_ACCESS  = `RV32GC_EXC_INSN_ACCESS_FAULT;  // 1
    localparam [4:0] C_LOAD_ACCESS  = `RV32GC_EXC_LOAD_ACCESS_FAULT;  // 5
    localparam [4:0] C_STORE_ACCESS = `RV32GC_EXC_STORE_ACCESS_FAULT; // 7

    //--------------------------------------------------------------------------
    // 1. DUT 端口驱动
    //--------------------------------------------------------------------------
    reg                     clk, rst_n;
    reg  [N*CFG_W-1:0]      cfg;
    reg  [N*32-1:0]         addr_flat;
    reg  [31:0]             acc_pa;
    reg  [4:0]              acc_bytes;
    reg  [1:0]              acc_priv;
    reg  [1:0]              acc_type;

    wire                    allow;
    wire [4:0]              fault_cause;
    wire                    hit;
    wire [3:0]              hit_idx;
    wire                    denied_by_full;

    pmp_check #(
        .PMP_ENTRIES (N)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_i            (cfg),
        .addr_i           (addr_flat),
        .acc_pa_i         (acc_pa),
        .acc_bytes_i      (acc_bytes),
        .acc_priv_i       (acc_priv),
        .acc_type_i       (acc_type),
        .allow_o          (allow),
        .fault_cause_o    (fault_cause),
        .hit_o            (hit),
        .hit_idx_o        (hit_idx),
        .denied_by_full_o (denied_by_full)
    );

    //--------------------------------------------------------------------------
    // 2. 检查计数器（用于统计已执行例数；不干扰 PASS 判定）
    //--------------------------------------------------------------------------
    integer n_tor, n_na4, n_napot, n_off, n_prio, n_nomatch, n_amo, n_split;
    integer n_checks;

    //--------------------------------------------------------------------------
    // 3. 配置写入辅助 task（纯赋值，不含时序语义）
    //--------------------------------------------------------------------------
    // 位域真源（rtl/pkg/rv32_defs.vh §7）：
    //   pmpcfg[i][0]=R, [1]=W, [2]=X, [4:3]=A, [5]=保留0, [6]=保留0, [7]=L
    localparam integer B_R = `RV32GC_PMP_R_BIT;   // 0
    localparam integer B_W = `RV32GC_PMP_W_BIT;   // 1
    localparam integer B_X = `RV32GC_PMP_X_BIT;   // 2
    localparam integer B_A = `RV32GC_PMP_A_LSB;   // 3
    localparam integer B_L = `RV32GC_PMP_L_BIT;   // 7

    task set_entry(input integer i, input [1:0] a, input l, input r, input w, input x);
        reg [CFG_W-1:0] v;
        begin
            // 显式按位组装（不用拼接，避免位宽错位；8 bit 整好）
            v = {CFG_W{1'b0}};
            v[B_R] = r;
            v[B_W] = w;
            v[B_X] = x;
            v[B_A] = a[0];
            v[B_A+1] = a[1];
            v[B_L] = l;
            cfg[i*CFG_W +: CFG_W] = v;
        end
    endtask

    task set_addr(input integer i, input [31:0] a);
        begin
            addr_flat[i*32 +: 32] = a;
        end
    endtask

    //--------------------------------------------------------------------------
    // ISA 口径换算助手（[norm:pmp_addr_encoding]，machine.adoc:3379-3383）：
    //   pmpaddr 编码 34 位物理地址的 [33:2] ⇒ 编程时写 `pa >> 2`。
    //--------------------------------------------------------------------------
    function [31:0] pa2addr(input [31:0] pa);
        pa2addr = pa >> 2;
    endfunction

    // NAPOT 编码（手册表 machine.adoc:3463-3493）：块大小 = 2^(n+3) 字节、
    // 字节基址自然对齐 ⇒ pmpaddr = (base>>2) | (低 n 位全 1)。
    //   n=0 ⇒ 8  B（低位 …yyy0，无 1）；n=1 ⇒ 16 B（…yy01）；n=3 ⇒ 64 B（低 3 位 1）
    function [31:0] napot_addr(input [31:0] byte_base, input integer n);
        napot_addr = (byte_base >> 2) | ((32'd1 << n) - 32'd1);
    endfunction

    task clear_all;
        integer i;
        begin
            for (i = 0; i < N; i = i + 1) begin
                set_entry(i, A_OFF, 1'b0, 1'b0, 1'b0, 1'b0);
                set_addr(i, 32'd0);
            end
        end
    endtask

    // 统一检查 task：断言 allow 与 cause
    task expect_allow(input [255:0] name);
        begin
            n_checks = n_checks + 1;
            if (allow !== 1'b1) begin
                $display("FAIL[%0s]: 期望放行，实际 allow=%b hit=%b idx=%0d full=%b",
                         name, allow, hit, hit_idx, denied_by_full);
                $fatal(1, "TB_PMP_CHECK FAIL");
            end
        end
    endtask

    task expect_deny(input [255:0] name, input [4:0] cause_expected);
        begin
            n_checks = n_checks + 1;
            if (allow !== 1'b0) begin
                $display("FAIL[%0s]: 期望拒绝，实际 allow=%b", name, allow);
                $fatal(1, "TB_PMP_CHECK FAIL");
            end
            if (fault_cause !== cause_expected) begin
                $display("FAIL[%0s]: cause 期望 %0d，实际 %0d", name, cause_expected, fault_cause);
                $fatal(1, "TB_PMP_CHECK FAIL");
            end
        end
    endtask

    // 断言命中的是最低编号项
    task expect_hit_idx(input [255:0] name, input [3:0] idx_expected);
        begin
            n_checks = n_checks + 1;
            if (hit !== 1'b1 || hit_idx !== idx_expected) begin
                $display("FAIL[%0s]: 期望命中项 %0d，实际 hit=%b idx=%0d",
                         name, idx_expected, hit, hit_idx);
                $fatal(1, "TB_PMP_CHECK FAIL");
            end
        end
    endtask

    //==========================================================================
    // 4. 测试主体
    //==========================================================================
    integer i;
    reg [31:0] base;

    initial begin
        $display("======== tb_pmp_check : PMP 16 项匹配与优先级 ========");

        clk = 1'b0; rst_n = 1'b0;
        cfg = {N*CFG_W{1'b0}};
        addr_flat = {N*32{1'b0}};
        acc_pa = 32'd0; acc_bytes = 5'd4; acc_priv = PRIV_M; acc_type = T_LOAD;

        n_tor = 0; n_na4 = 0; n_napot = 0; n_off = 0;
        n_prio = 0; n_nomatch = 0; n_amo = 0; n_split = 0;
        n_checks = 0;

        #1; rst_n = 1'b1; #1;

        //======================================================================
        // 组 0：OFF —— 不匹配任何地址（≥2 例）
        //   A=OFF 的项必须完全不参与匹配（即使 R/W/X 全 1）
        //======================================================================
        clear_all;
        set_entry(0, A_OFF, 1'b0, 1'b1, 1'b1, 1'b1);   // OFF + 全权限
        set_addr (0, pa2addr(32'h0000_1000));           // OFF ⇒ 值无意义，仍按 ISA 口径写
        // 例 0-1：S 模式 load 到该地址 ⇒ 无匹配 ⇒ **失败**
        acc_pa = 32'h0000_1000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_off = n_off + 1;
        if (hit !== 1'b0) begin
            $display("FAIL[OFF-1]: OFF 项不应匹配，实际 hit=%b idx=%0d", hit, hit_idx);
            $fatal(1, "TB_PMP_CHECK FAIL");
        end
        expect_deny("OFF-1(S-load)", C_LOAD_ACCESS);
        // 例 0-2：U 模式 store 到另一地址 ⇒ 无匹配 ⇒ **失败**
        acc_pa = 32'h2000_0000; acc_bytes = 5'd4; acc_priv = PRIV_U; acc_type = T_STORE;
        #1; n_off = n_off + 1;
        if (hit !== 1'b0) begin
            $display("FAIL[OFF-2]: OFF 项不应匹配"); $fatal(1, "TB_PMP_CHECK FAIL");
        end
        expect_deny("OFF-2(U-store)", C_STORE_ACCESS);
        // 例 0-3：M 模式 ⇒ 无匹配成功（对照组）
        acc_pa = 32'h2000_0000; acc_bytes = 5'd4; acc_priv = PRIV_M; acc_type = T_STORE;
        #1; n_off = n_off + 1;
        expect_allow("OFF-3(M-store)");
        $display("  [OFF]    3 例通过（无匹配：S/U 失败、M 成功）");

        //======================================================================
        // 组 1：TOR —— 字地址口径 y ∈ [pmpaddr[i-1], pmpaddr[i])，上界**不含**
        //   对应字节区间 = [pmpaddr[i-1]<<2, (pmpaddr[i]<<2) - 1]（≥2 例）
        //======================================================================
        // ---- 例 1-1：项 0 单独 TOR，下界恒 0，上界 = pmpaddr[0]（字节 0x8000） ----
        clear_all;
        set_entry(0, A_TOR, 1'b0, 1'b1, 1'b1, 1'b1);   // R+W，L=0
        set_addr (0, pa2addr(32'h0000_8000));           // TOR 上界（不含）
        n_tor = n_tor + 1;
        // 1-1a：地址 0x0000_7FFC 在 [0, 0x7FFF] 内 ⇒ S 放行
        acc_pa = 32'h0000_7FFC; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("TOR-1a(in-range)"); expect_hit_idx("TOR-1a(idx0)", 4'd0);
        // 1-1b：地址 0x0000_8000 恰在上界外（TOR 上界不含）⇒ 无匹配 ⇒ S 失败
        acc_pa = 32'h0000_8000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1;
        if (hit !== 1'b0) begin
            $display("FAIL[TOR-1b]: TOR 上界不含，0x8000 不应命中"); 
            $fatal(1, "TB_PMP_CHECK FAIL");
        end
        expect_deny("TOR-1b(upper-bound)", C_LOAD_ACCESS);
        // 1-1c：TOR + L=1 且 S 模式 ⇒ 需 R/W/X 位；只给 R，做 store ⇒ 拒
        set_entry(0, A_TOR, 1'b1, 1'b1, 1'b0, 1'b0);   // L=1，只有 R
        acc_pa = 32'h0000_4000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_STORE;
        #1; expect_deny("TOR-1c(L=1 no-W)", C_STORE_ACCESS);

        // ---- 例 1-2：项 1 TOR 与项 0 TOR 构成区间 ----
        clear_all;
        set_entry(0, A_TOR, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (0, pa2addr(32'h8000_0000));           // 项 0：下界 0，上界 0x7FFF_FFFF
        set_entry(1, A_TOR, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (1, pa2addr(32'hC000_0000));           // 项 1：下界 0x8000_0000，上界 0xBFFF_FFFF
        n_tor = n_tor + 1;
        // 1-2a：地址 0xA000_0000 命中项 1
        acc_pa = 32'hA000_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("TOR-2a(entry1)"); expect_hit_idx("TOR-2a(idx1)", 4'd1);
        // 1-2b：地址 0x4000_0000 命中项 0（优先级更低编号先）
        acc_pa = 32'h4000_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("TOR-2b(entry0)"); expect_hit_idx("TOR-2b(idx0)", 4'd0);
        // 1-2c：地址 0xC000_0000 在项 1 上界外 ⇒ 无匹配 ⇒ S 失败
        acc_pa = 32'hC000_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_deny("TOR-2c(out)", C_LOAD_ACCESS);
        $display("  [TOR]    2 组例通过（下界/上界 + 多项区间）");

        //======================================================================
        // 组 2：NA4 —— G=0 下可用，覆盖 [pmpaddr, pmpaddr+3]（≥2 例）
        //======================================================================
        // ---- 例 2-1：NA4 精确覆盖 4 B，界内放行、界外拒绝 ----
        clear_all;
        set_entry(0, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (0, pa2addr(32'h1000_0000));           // 覆盖 0x1000_0000..0x1000_0003
        n_na4 = n_na4 + 1;
        // 2-1a：界内（末字节 + 3）⇒ 放行
        acc_pa = 32'h1000_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NA4-1a(in)"); expect_hit_idx("NA4-1a(idx0)", 4'd0);
        // 2-1b：界外（+4）⇒ 无匹配 ⇒ S 失败
        acc_pa = 32'h1000_0004; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_deny("NA4-1b(out)", C_LOAD_ACCESS);
        // 2-1c：**G=0 生效证据** —— `pmpaddr` 低位**全部有效、不做掩码**：
        //        NA4 单元 = pmpaddr 的整个字（4 B 一档），相邻单元可分别寻址
        //        （ISA 口径下 NA4 单元必然 4 B 对齐，不存在「非对齐起址」；
        //         旧写法把 pmpaddr 当字节地址，是本 TB 本轮修正的口径错误）。
        set_addr (0, pa2addr(32'h1000_0004));           // 覆盖 0x1000_0004..0x1000_0007
        acc_pa = 32'h1000_0004; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NA4-1c(g0-low-bits-live)");
        // 2-1d：**上一个 4 B 单元**（只差 pmpaddr 最低位）⇒ 无匹配 ⇒ 拒
        //        （若实现错误地对 pmpaddr 低位做掩码，这两档会并成一个块 ⇒ 误放行）
        acc_pa = 32'h1000_0000; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_deny("NA4-1d(low-bit-matters)", C_LOAD_ACCESS);

        // ---- 例 2-2：NA4 + L=1 + U 模式权限位判定 ----
        clear_all;
        set_entry(0, A_NA4, 1'b1, 1'b1, 1'b0, 1'b0);   // L=1，只有 R
        set_addr (0, pa2addr(32'h2000_0000));
        n_na4 = n_na4 + 1;
        // 2-2a：U 模式 load（需 R，有）⇒ 放行
        acc_pa = 32'h2000_0000; acc_bytes = 5'd4; acc_priv = PRIV_U; acc_type = T_LOAD;
        #1; expect_allow("NA4-2a(U-load)");
        // 2-2b：U 模式 store（需 W，无）⇒ 拒 cause 7
        acc_pa = 32'h2000_0000; acc_bytes = 5'd4; acc_priv = PRIV_U; acc_type = T_STORE;
        #1; expect_deny("NA4-2b(U-store-noW)", C_STORE_ACCESS);
        // 2-2c：M 模式 store —— L=1 ⇒ **不**豁免，需 W，无 ⇒ 拒
        acc_pa = 32'h2000_0000; acc_bytes = 5'd4; acc_priv = PRIV_M; acc_type = T_STORE;
        #1; expect_deny("NA4-2c(M-store-L1)", C_STORE_ACCESS);
        $display("  [NA4]    2 组例通过（G=0 生效 + L=1 权限位判定）");

        //======================================================================
        // 组 3：NAPOT —— 覆盖 2^(n+3) 字节（≥2 例），n = pmpaddr 低位**连续 1** 个数
        //   手册编码表（riscv-isa-manual machine.adoc:3463-3493，NAPOT range encoding）：
        //     pmpaddr 低位 …yyy0  ⇒  8  B（n=0）
        //                  …yy01  ⇒ 16  B（n=1）
        //                  …y011  ⇒ 32  B（n=2）
        //                  …0111  ⇒ 64  B（n=3）
        //   ★ 低位是**尺寸编码**（pmpaddr 口径），不是字节基址位。
        //======================================================================
        // ---- 例 3-1：NAPOT n=0（8 B 块，pmpaddr 低位 …yyy0） ----
        clear_all;
        set_addr (0, napot_addr(32'h3000_0000, 0));    // n=0 ⇒ 8 B 块 @0x3000_0000
        set_entry(0, A_NAPOT, 1'b0, 1'b1, 1'b1, 1'b1);
        n_napot = n_napot + 1;
        // 3-1a：块内末字节（+7）放行
        acc_pa = 32'h3000_0007; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NAPOT-1a(n0-in)");
        // 3-1b：块外（+8）拒
        acc_pa = 32'h3000_0008; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_deny("NAPOT-1b(n0-out)", C_LOAD_ACCESS);
        // 3-1c：**NAPOT 低位掩码生效** —— 8 B 块覆盖 **2 个字**，故访问块内
        //        **第二个字** 0x3000_0004（其字地址 ≠ pmpaddr 本身）也命中；
        //        若实现误按「pmpaddr == 访存字」精确比较，则该访问不命中。
        acc_pa = 32'h3000_0004; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NAPOT-1c(n0-second-word)");

        // ---- 例 3-2：NAPOT n=3（64 B 块，pmpaddr 低位 …0111 = 0x7） ----
        clear_all;
        set_addr (0, napot_addr(32'h4000_0000, 3));    // n=3 ⇒ 64 B 块 @0x4000_0000
        set_entry(0, A_NAPOT, 1'b0, 1'b1, 1'b1, 1'b1);
        n_napot = n_napot + 1;
        // 3-2a：块内末字节（+63）放行
        acc_pa = 32'h4000_003F; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NAPOT-2a(n3-in)");
        // 3-2b：块外（+64）拒
        acc_pa = 32'h4000_0040; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_deny("NAPOT-2b(n3-out)", C_LOAD_ACCESS);
        // 3-2c：整笔 4 B 落在块内 ⇒ 放行
        acc_pa = 32'h4000_003C; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NAPOT-2c(n3-4B)");
        // 3-2d：**n=1（16 B）**边界验证 —— pmpaddr 低位 …yy01
        clear_all;
        set_addr (0, napot_addr(32'h5000_0000, 1));    // n=1 ⇒ 16 B 块 @0x5000_0000
        set_entry(0, A_NAPOT, 1'b0, 1'b1, 1'b1, 1'b1);
        acc_pa = 32'h5000_000F; acc_bytes = 5'd1; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_allow("NAPOT-3a(n1-in)");
        acc_pa = 32'h5000_0010; acc_bytes = 5'd1;
        #1; expect_deny("NAPOT-3b(n1-out)", C_LOAD_ACCESS);
        n_napot = n_napot + 1;
        $display("  [NAPOT]  3 组例通过（n=0 8B / n=1 16B / n=3 64B，含低位掩码生效）");

        //======================================================================
        // 组 4：16 项优先级 —— **低编号优先**
        //   项 0 = NAPOT 拒（无权限），项 1 = NAPOT 允许（全权限），覆盖同一地址
        //   ⇒ 必须由**项 0** 决定 ⇒ 拒绝
        //======================================================================
        clear_all;
        // 项 0：覆盖 0x6000_0000 的 NAPOT（64 B；低位 …y011 ⇒ n=3），**无任何权限**
        set_addr (0, napot_addr(32'h6000_0000, 3));
        set_entry(0, A_NAPOT, 1'b1, 1'b0, 1'b0, 1'b0);   // L=1, R=W=X=0 ⇒ 必拒
        // 项 1：覆盖同一地址的 NAPOT，全权限
        set_addr (1, napot_addr(32'h6000_0000, 3));
        set_entry(1, A_NAPOT, 1'b1, 1'b1, 1'b1, 1'b1);   // 全权限
        n_prio = n_prio + 1;
        acc_pa = 32'h6000_0010; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_hit_idx("PRIO-1(low-wins)", 4'd0);
        expect_deny("PRIO-1(low-wins-deny)", C_LOAD_ACCESS);
        // 反证：把项 0 关成 OFF ⇒ 项 1 生效 ⇒ 放行（证明项 1 本身是可匹配的）
        set_entry(0, A_OFF, 1'b0, 1'b0, 1'b0, 1'b0);
        #1; expect_allow("PRIO-2(neg-control)"); expect_hit_idx("PRIO-2(idx1)", 4'd1);

        // ---- 例 4-2：3 项同时命中，验证命中**最低编号**（项 7 优先于项 9） ----
        clear_all;
        set_entry(9, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (9, pa2addr(32'h6100_0000));
        set_entry(7, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (7, pa2addr(32'h6100_0000));
        set_entry(3, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (3, pa2addr(32'h6100_0000));
        n_prio = n_prio + 1;
        acc_pa = 32'h6100_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_hit_idx("PRIO-3(idx3)", 4'd3); expect_allow("PRIO-3(allow)");
        // 关掉项 3 ⇒ 应命中项 7
        set_entry(3, A_OFF, 1'b0, 1'b0, 1'b0, 1'b0);
        #1; expect_hit_idx("PRIO-4(idx7)", 4'd7);
        // 再关掉项 7 ⇒ 应命中项 9
        set_entry(7, A_OFF, 1'b0, 1'b0, 1'b0, 1'b0);
        #1; expect_hit_idx("PRIO-5(idx9)", 4'd9);
        $display("  [PRIO]   2 组例通过（低编号优先，含 3 项递减反证）");

        //======================================================================
        // 组 5：无匹配时的特权级语义 [norm:pmpnoentry_match]
        //   M 成功 / S 失败 / U 失败（本设计实现 16 项）
        //======================================================================
        clear_all;                                       // 全部 OFF
        // 5-1：M 模式 load ⇒ 成功
        acc_pa = 32'h7000_0000; acc_bytes = 5'd4; acc_priv = PRIV_M; acc_type = T_LOAD;
        #1; n_nomatch = n_nomatch + 1;
        expect_allow("NOMATCH-M");
        // 5-2：S 模式 load ⇒ 失败 cause 5
        acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_nomatch = n_nomatch + 1;
        expect_deny("NOMATCH-S", C_LOAD_ACCESS);
        // 5-3：U 模式 load ⇒ 失败 cause 5
        acc_priv = PRIV_U; acc_type = T_LOAD;
        #1; n_nomatch = n_nomatch + 1;
        expect_deny("NOMATCH-U", C_LOAD_ACCESS);
        // 5-4：S 模式 store ⇒ 失败 cause 7
        acc_priv = PRIV_S; acc_type = T_STORE;
        #1; n_nomatch = n_nomatch + 1;
        expect_deny("NOMATCH-S-store", C_STORE_ACCESS);
        // 5-5：S 模式取指 ⇒ 失败 cause 1
        acc_priv = PRIV_S; acc_type = T_EXEC;
        #1; n_nomatch = n_nomatch + 1;
        expect_deny("NOMATCH-S-exec", C_INSN_ACCESS);
        $display("  [NOMATCH]5 例通过（无匹配：M 成功 / S,U 失败，cause 按类型）");

        //======================================================================
        // 组 6：AMO 被 PMP 拒 —— **恒 cause 7**（T4，08 §5.5 抉择 4）
        //======================================================================
        clear_all;
        // 6-1：命中项但**无 W 权限**，AMO 访问 ⇒ 恒 cause 7
        set_entry(0, A_NA4, 1'b1, 1'b1, 1'b0, 1'b0);     // L=1，只有 R
        set_addr (0, pa2addr(32'h8000_0000));
        acc_pa = 32'h8000_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_AMO;
        #1; n_amo = n_amo + 1;
        expect_deny("AMO-1(no-W)", C_STORE_ACCESS);       // 恒 7
        // 6-2：**无匹配项**且 S 模式，AMO ⇒ 恒 cause 7（不是 5）
        clear_all;
        acc_pa = 32'h8000_0000; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_AMO;
        #1; n_amo = n_amo + 1;
        expect_deny("AMO-2(nomatch-S)", C_STORE_ACCESS);  // 恒 7
        // 6-3：U 模式无匹配 AMO ⇒ 恒 cause 7
        acc_priv = PRIV_U; acc_type = T_AMO;
        #1; n_amo = n_amo + 1;
        expect_deny("AMO-3(nomatch-U)", C_STORE_ACCESS);  // 恒 7
        // 6-4：**对照** —— 同一条件下 load 报 cause 5（证明 AMO 的 7 是特化的）
        acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_amo = n_amo + 1;
        expect_deny("AMO-4(ctrl-load-cause5)", C_LOAD_ACCESS);
        $display("  [AMO]    4 例通过（被 PMP 拒**恒 cause 7**；对照 load=5）");

        //======================================================================
        // 组 7：非对齐跨区域**拆两笔**，每笔独立（08 §5.5 抉择 3）
        //   [norm:pmpmisalignedaccess_behavior] 每笔独立检查
        //   TB 侧按 lsu.v 的拆笔规则手工拆成两笔，逐笔调用 DUT：
        //     笔0 首→单元末；笔1 下一单元 → 末
        //======================================================================
        // 场景：地址 0x9000_0002，4 B 访问 ⇒ 拆为
        //   笔0 = 0x9000_0002, 2 B（覆盖 0x9000_0002-03，字 0x2400_0000）
        //   笔1 = 0x9000_0004, 2 B（覆盖 0x9000_0004-05，字 0x2400_0001）
        // 配置：项 0 = NAPOT n=1（16 B @0x9000_0000）⇒ 两笔都被同一项覆盖
        //   （ISA 口径下 NA4 单元必然 4 B 对齐 ⇒ 不能用「起址 0x9000_0002 的 NA4」
        //     表达跨笔场景，改用 16 B NAPOT，两笔同项覆盖的语义不变）
        clear_all;
        set_entry(0, A_NAPOT, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (0, napot_addr(32'h9000_0000, 1));       // 覆盖 0x9000_0000..0F
        // 7-1：笔 0 ⇒ 放行
        acc_pa = 32'h9000_0002; acc_bytes = 5'd2; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_split = n_split + 1;
        expect_allow("SPLIT-1a(beat0-allow)");
        // 7-2：笔 1（0x9000_0004）—— 同一 NA4 项也覆盖它 ⇒ 放行
        acc_pa = 32'h9000_0004; acc_bytes = 5'd2;
        #1; n_split = n_split + 1;
        expect_allow("SPLIT-1b(beat1-also-covered)");

        // ---- 场景 2：**部分通过、部分失败**（每笔独立的可观察证据） ----
        //   项 0 = NA4 只覆盖 0x9000_0002..05 内的一部分:
        //     把项 0 改为 NA4 @ 0x9000_0004（只覆盖笔 1）⇒ 笔 0 无匹配 ⇒ 失败
        clear_all;
        set_entry(0, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (0, pa2addr(32'h9000_0004));
        // 笔 0（0x9000_0002）⇒ 无匹配 ⇒ S 失败
        acc_pa = 32'h9000_0002; acc_bytes = 5'd2; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_split = n_split + 1;
        expect_deny("SPLIT-2a(beat0-deny)", C_LOAD_ACCESS);
        // 笔 1（0x9000_0004）⇒ 命中并放行（证明两笔独立）
        acc_pa = 32'h9000_0004; acc_bytes = 5'd2; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_split = n_split + 1;
        expect_allow("SPLIT-2b(beat1-allow)");

        // ---- 场景 3：整笔匹配强制 [norm:pmpfullmatch_required] ----
        //   项覆盖笔的一部分（不是笔的全部字节）⇒ 该笔失败（与 R/W/X 无关）
        //   项 0 = NA4 覆盖 0x9000_0000..03；一笔 4 B 访问 @0x9000_0002：
        //     笔字节 = 0x9000_0002..05；项覆盖 02..03 ⇒ 只覆盖部分 ⇒ **失败**
        clear_all;
        set_entry(0, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
        set_addr (0, pa2addr(32'h9000_0000));             // 覆盖 0x9000_0000..03
        acc_pa = 32'h9000_0002; acc_bytes = 5'd4; acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; n_split = n_split + 1;
        if (denied_by_full !== 1'b1) begin
            $display("FAIL[SPLIT-3a]: 整笔未全覆盖应置 denied_by_full，实际=%b (hit=%b)",
                     denied_by_full, hit);
            $fatal(1, "TB_PMP_CHECK FAIL");
        end
        expect_deny("SPLIT-3a(partial-cover)", C_LOAD_ACCESS);
        // 反证：同样范围但只访问被完全覆盖的 2 B ⇒ 放行
        acc_pa = 32'h9000_0002; acc_bytes = 5'd2;
        #1; n_split = n_split + 1;
        expect_allow("SPLIT-3b(full-cover-2B)");
        $display("  [SPLIT]  5 例通过（跨区域拆两笔，每笔独立 + 整笔匹配强制）");

        //======================================================================
        // 组 8：G=0 粒度的补充证据 —— 16 项全部可用（低编号项必须先实现）
        //   把 16 项都设成同一 NA4（不同地址），逐项验证第 15 项也生效
        //======================================================================
        clear_all;
        for (i = 0; i < N; i = i + 1) begin
            set_entry(i, A_NA4, 1'b0, 1'b1, 1'b1, 1'b1);
            set_addr (i, pa2addr(32'hA000_0000 + i*32'h10));
        end
        // 第 15 项（最后一项）必须真实生效
        acc_pa = 32'hA000_0000 + 15*32'h10; acc_bytes = 5'd4;
        acc_priv = PRIV_S; acc_type = T_LOAD;
        #1; expect_hit_idx("ALL16-idx15", 4'd15); expect_allow("ALL16-allow15");
        // 第 0 项
        acc_pa = 32'hA000_0000;
        #1; expect_hit_idx("ALL16-idx0", 4'd0);
        $display("  [ALL16]  2 例通过（16 项全部生效，含第 15 项）");

        //======================================================================
        // 汇总与判定
        //======================================================================
        $display("--------------------------------------------------------------");
        $display("  例数统计：TOR=%0d NA4=%0d NAPOT=%0d OFF=%0d PRIO=%0d",
                 n_tor, n_na4, n_napot, n_off, n_prio);
        $display("            NOMATCH=%0d AMO=%0d SPLIT=%0d  总断言=%0d",
                 n_nomatch, n_amo, n_split, n_checks);

        // 覆盖度门禁（判据 ③ 要求 TOR/NA4/NAPOT/OFF 各 ≥2 例）
        if (n_tor < 2 || n_na4 < 2 || n_napot < 2 || n_off < 2) begin
            $display("FAIL: 覆盖度不足（TOR/NA4/NAPOT/OFF 各需 >=2 例）");
            $fatal(1, "TB_PMP_CHECK FAIL");
        end
        if (n_prio < 2 || n_nomatch < 5 || n_amo < 4 || n_split < 5) begin
            $display("FAIL: 覆盖度不足（PRIO>=2 NOMATCH>=5 AMO>=4 SPLIT>=5）");
            $fatal(1, "TB_PMP_CHECK FAIL");
        end

        $display("TB_PMP_CHECK: PASS");
        $finish;
    end

    // 超时保护：本 TB 为纯组合，理论上 #1 即收敛；若卡死则 fail-closed
    initial begin
        #100000;
        $display("FAIL: 超时（TB 未在预期时间内完成）");
        $fatal(1, "TB_PMP_CHECK FAIL");
    end

endmodule
