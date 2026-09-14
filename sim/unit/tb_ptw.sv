//==============================================================================
// tb_ptw.sv —— ptw（Sv32 两级页表遍历）单元测试
//==============================================================================
// 测什么  : ① **两级页表命中**：一级指针 → 二级叶子 ⇒ 正确 PA（4 KiB 页）；
//           ② **4 MiB 大页**：一级命中叶子且 PPN[0]=0 ⇒ PA = {PPN[1], VA[21:0]}；
//              错位超级页（PPN[0]≠0）⇒ page-fault（cause 12/13/15）；
//           ③ **缺页 cause 12 / 13 / 15**（取指/load/store）：
//              V=0、R=0&&W=1 保留、二级仍为指针（i<0）、权限不足（U/SUM/MXR）;
//           ④ **★ 页表隐式访存过 PMP 被拒 ⇒ access-fault**（判据⑤核心）：
//              取指原访问 ⇒ cause 1；load ⇒ cause 5；store/AMO ⇒ cause 7；
//              **不是** page-fault。且 PMP 被拒时**不得**发出 PTE 物理读。
//           ⑤ A/D 位：A=0 或（写且 D=0）⇒ 触发硬件更新流程（pte_ad_update）。
// 怎么判  : 每条断言具体数值；失败即 $fatal（非零退出）；兜底分支不含 PASS。
// 失败长什么样: `TB_PTW FAIL: <项> got=... exp=...` 后 $fatal(1, "TB_PTW_UNIT: FAIL")。
// 顶层    : tb_ptw_top（验收命令用 -s tb_ptw_top）
//------------------------------------------------------------------------------
// 【测试用存储模型】一个简单行为内存：
//   - 只有两个页表页（根页表 + 二级页表），各 4 KiB；
//   - 页表项通过 mem[] 数组按物理地址索引（仅保留低 16 位做索引，够用）；
//   - pte_req 走**同步**模型：3 拍后返回数据（模拟真实读延迟），
//     PMP 由 TB 按可配置的"禁止物理区间"组合判定 —— 这就是判据④的注入点。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_ptw_top;

    //--------------------------------------------------------------------------
    // 地址与页表布局常量
    //--------------------------------------------------------------------------
    localparam [31:0] ROOT_PPN  = 22'h00020;              // 根页表物理页号
    localparam [31:0] ROOT_BASE = 32'h0002_0000;          // ROOT_PPN << 12
    localparam [31:0] L1_PPN    = 22'h00030;              // 二级页表物理页号
    localparam [31:0] L1_BASE   = 32'h0003_0000;          // L1_PPN << 12
    localparam [31:0] L1_BIG_PPN= 22'h00040;              // 4 MiB 大页的 PPN（低 10 位须为 0）
    localparam [31:0] SATP_SV32 = 32'h8000_0000 | ROOT_PPN;

    //--------------------------------------------------------------------------
    // 时钟/复位
    //--------------------------------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // PTW 接口
    //--------------------------------------------------------------------------
    reg         req_valid = 0;
    reg  [31:0] req_va = 0;
    reg  [1:0]  req_acc = 2'b01;
    reg  [1:0]  req_priv = `RV32GC_PRIV_S;
    reg         req_sum = 0;
    reg         req_mxr = 0;
    reg  [31:0] satp = SATP_SV32;
    wire        req_ready, req_done, fault_o;
    wire [31:0] pa_o;
    wire [4:0]  fault_cause_o;
    wire [31:0] fault_tval_o;
    wire        pte_req_valid;
    wire [31:0] pte_req_pa;
    reg         pte_req_ready = 1;
    reg         pte_resp_valid = 0;
    reg  [31:0] pte_resp_data = 0;
    wire        pmp_req_valid;
    wire [31:0] pmp_req_addr;
    wire [1:0]  pmp_req_acc, pmp_req_priv;
    reg         pmp_resp_ok = 1;
    wire        pte_ad_update;
    wire [31:0] pte_ad_pa, pte_ad_data;
    reg         pte_ad_done = 0;
    wire        fill_valid;
    wire [31:0] fill_va, fill_pa;
    wire [21:0] fill_ppn;
    wire [7:0]  fill_perm;

    ptw dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_va(req_va), .req_acc(req_acc),
        .req_priv(req_priv), .req_sum(req_sum), .req_mxr(req_mxr), .satp(satp),
        .req_ready(req_ready), .req_done(req_done), .pa_o(pa_o), .fault_o(fault_o),
        .fault_cause_o(fault_cause_o), .fault_tval_o(fault_tval_o),
        .pte_req_valid(pte_req_valid), .pte_req_pa(pte_req_pa),
        .pte_req_ready(pte_req_ready), .pte_resp_valid(pte_resp_valid),
        .pte_resp_data(pte_resp_data),
        .pmp_req_valid(pmp_req_valid), .pmp_req_addr(pmp_req_addr),
        .pmp_req_acc(pmp_req_acc), .pmp_req_priv(pmp_req_priv),
        .pmp_resp_ok(pmp_resp_ok),
        .pte_ad_update(pte_ad_update), .pte_ad_pa(pte_ad_pa),
        .pte_ad_data(pte_ad_data), .pte_ad_done(pte_ad_done),
        .fill_valid(fill_valid), .fill_va(fill_va), .fill_pa(fill_pa),
        .fill_ppn(fill_ppn), .fill_perm(fill_perm)
    );

    //--------------------------------------------------------------------------
    // 页表项存储模型（组合读；TB 在测试前填好）
    //--------------------------------------------------------------------------
    reg [31:0] pte_mem [0:1023];   // 按 ((PA>>2) & 0x3FF) 索引（页表项 4 B 对齐）
    integer k;

    // ---- 页表项索引：把 PTE 物理地址映射到 1024 项的测试存储 ----
    //   注：ROOT_BASE/L1_BASE 都是 4 KiB 对齐的多页地址，直接取 (pa>>2) 低位会
    //   与"另一个页表页的同一 VPN 索引"撞车 ⇒ 测试存储按**非重叠的 sram 布局**
    //   设计：根页表放在索引 0x000-0x0FF，二级页表放在 0x100-0x1FF，
    //   并由 pte_index() 统一映射（见下）。这样两级索引互不干扰。
    function [9:0] pte_index;
        input [31:0] pa;
        begin
            //   pa[9:2]  = 页内项索引（每页 1024 项，本 TB 只用低半）
            //   pa[18]   = 区分 0x2_0000(ROOT)/0x3_0000(L1) 与 0x4_0000(大页)
            //   pa[16]   = 区分 ROOT 与 L1
            //   ⇒ {pa[18], pa[16], pa[9:2]} 是 10 bit、对三个页表页互不重叠。
            pte_index = {pa[18], pa[16], pa[9:2]};
        end
    endfunction

    // ---- PTE 编码工具 ----
    function [31:0] mk_pte;
        input [21:0] ppn;
        input        d, a, g_b, u, x, w, r, v;
        begin
            mk_pte = (ppn << `RV32GC_PTE_PPN_LSB) |
                     ({31'b0, d}  << `RV32GC_PTE_D_BIT) |
                     ({31'b0, a}  << `RV32GC_PTE_A_BIT) |
                     ({31'b0, g_b}<< `RV32GC_PTE_G_BIT) |
                     ({31'b0, u}  << `RV32GC_PTE_U_BIT) |
                     ({31'b0, x}  << `RV32GC_PTE_X_BIT) |
                     ({31'b0, w}  << `RV32GC_PTE_W_BIT) |
                     ({31'b0, r}  << `RV32GC_PTE_R_BIT) |
                     ({31'b0, v}  << `RV32GC_PTE_V_BIT);
        end
    endfunction

    // ---- 简单同步读模型：pte_req 有效后 **2 拍** 返回数据 ----
    //   TB 的存储阵列用**组合读**（assign 式），2 拍延迟足以验证 FSM 的握手。
    //   ★ 握手要点（实测踩到）：`pte_resp_valid` 与 `pte_resp_data` 必须**分拍**建立。
    //     若在同一个 NBA 周期里同时置 valid 和数据，DUT 在该拍采到的
    //     `pte_resp_data` 仍是**旧值**（0），会误判为 V=0 ⇒ 假 page-fault。
    //     正确做法：第 2 拍先把数据打进 `pte_resp_data`，第 3 拍再拉 `pte_resp_valid`。
    reg [1:0] rd_dly = 2'd0;
    reg [31:0] rd_pa_q = 32'h0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_dly <= 2'd0; pte_resp_valid <= 1'b0; pte_resp_data <= 32'h0;
        end else begin
            pte_resp_valid <= 1'b0;
            if (pte_req_valid & pte_req_ready & (rd_dly == 2'd0)) begin
                rd_pa_q <= pte_req_pa;
                rd_dly  <= 2'd1;
            end else if (rd_dly == 2'd1) begin
                // 先建立数据（valid 仍为 0）
                pte_resp_data <= pte_mem[pte_index(rd_pa_q)];
                rd_dly        <= 2'd2;
            end else if (rd_dly == 2'd2) begin
                // 数据已稳定 ⇒ 再拉 valid（同拍数据不再变化）
                rd_dly         <= 2'd0;
                pte_resp_valid <= 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // ★ PMP 模型（判据④的注入点）
    //   pmp_deny_lo / pmp_deny_hi 构成一个"禁止区间"（含端点，按 PTE 物理地址判定）。
    //   pmp_resp_ok = ~(该区间有效 && 地址落在区间内)
    //--------------------------------------------------------------------------
    reg        pmp_deny_en = 0;
    reg [31:0] pmp_deny_lo = 32'h0, pmp_deny_hi = 32'h0;
    always @(*) begin
        if (pmp_deny_en && (pmp_req_addr >= pmp_deny_lo) && (pmp_req_addr <= pmp_deny_hi))
            pmp_resp_ok = 1'b0;
        else
            pmp_resp_ok = 1'b1;
    end

    //--------------------------------------------------------------------------
    // 记分板
    //--------------------------------------------------------------------------
    integer n_pass = 0, n_fail = 0;
    reg     sim_ok = 1'b0;   // 仅在全部检查通过后置 1

    task expect_eq32;
        input [8*40-1:0] name; input [31:0] got; input [31:0] exp;
        begin
            if (got !== exp) begin
                $display("TB_PTW FAIL: %0s got=0x%08x exp=0x%08x", name, got, exp);
                n_fail = n_fail + 1;
            end else n_pass = n_pass + 1;
        end
    endtask

    task expect_eq1;
        input [8*40-1:0] name; input got; input exp;
        begin
            if (got !== exp) begin
                $display("TB_PTW FAIL: %0s got=%0b exp=%0b", name, got, exp);
                n_fail = n_fail + 1;
            end else n_pass = n_pass + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 发起一次翻译并等待结束
    //--------------------------------------------------------------------------
    //   返回后：fault_o / fault_cause_o / pa_o 有效。
    //   ★ 若 PMP 被拒，FSM 应在 S_L1/S_L0 直接出结果（不发 PTE 读），
    //     因此这里同时记录"本次是否发出过 PTE 物理读"。
    reg saw_pte_req;
    reg saw_ad_update;
    // ---- 粘性 done 标志：避免循环错过 req_done 的单拍脉冲 ----
    reg done_latch;
    always @(posedge clk) if (req_done) done_latch <= 1'b1;
    // ---- fill_valid 同样只高 1 拍（S_DONE）⇒ 粘住供断言（同 done_latch 理由）----
    reg fill_latch; reg [31:0] fill_va_l, fill_pa_l; reg [21:0] fill_ppn_l; reg [7:0] fill_perm_l;
    always @(posedge clk) if (fill_valid) begin
        fill_latch  <= 1'b1;
        fill_va_l   <= fill_va;  fill_pa_l  <= fill_pa;
        fill_ppn_l  <= fill_ppn; fill_perm_l<= fill_perm;
    end
    always @(posedge clk) if (pte_req_valid) saw_pte_req <= 1'b1;

    task do_translate;
        input [31:0] va;
        input [1:0]  acc;
        input [1:0]  pv;
        input        sum_b;
        input        mxr_b;
        begin
            @(negedge clk);
            saw_pte_req = 1'b0;
            done_latch  = 1'b0;
            fill_latch  = 1'b0;
            pte_ad_done = 1'b0;
            req_va = va; req_acc = acc; req_priv = pv;
            req_sum = sum_b; req_mxr = mxr_b;
            req_valid = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;
            // 等 done（最多 200 拍，避免挂死）
            //   ★ 在等待过程中**自动完成 A/D 更新**：只要 DUT 拉 pte_ad_update，
            //     就把 pte_ad_data 写回页表存储并回一拍 pte_ad_done。
            //     ⇒ 这样"需要更新 A/D"的用例也能正常走完（对应真实 lsu 的行为）。
            //     另记录本次是否触发过 A/D 更新（供断言用）。
            //   ★ 采样时机（实测踩到）：req_done 在 S_DONE 那一拍为高、下一拍回落。
            //   用 always 块把 req_done 黏住（done_latch），避免轮询循环错过
            //   单拍脉冲导致所有用例误报“超时”。
            k = 0;
            saw_ad_update = 1'b0;
            while (!done_latch && k < 200) begin
                #1;                       // 离开时钟沿，进入稳定期后再采样
                if (!done_latch && pte_ad_update) begin
                    saw_ad_update = 1'b1;
                    pte_mem[pte_index(pte_ad_pa)] = pte_ad_data;
                    pte_ad_done = 1'b1;
                end else begin
                    pte_ad_done = 1'b0;
                end
                @(posedge clk);
                k = k + 1;
            end
            pte_ad_done = 1'b0;
            if (k >= 200) begin
                $display("TB_PTW FAIL: 翻译超时（va=%08x st=%0d acc=%b priv=%b pte_req_valid=%b pte_req_pa=%08x pte_resp_valid=%b)", va, dut.st, acc, pv, pte_req_valid, pte_req_pa, pte_resp_valid);
                n_fail = n_fail + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    initial begin
        $display("---- tb_ptw: ptw（Sv32 两级遍历）单元测试 ----");

        // ---- 清空页表存储 ----
        for (k = 0; k < 1024; k = k + 1) pte_mem[k] = 32'h0;

        rst_n = 0; repeat(4) @(posedge clk); #1;
        rst_n = 1; repeat(2) @(posedge clk); #1;

        expect_eq1("复位后 req_ready=1", req_ready, 1'b1);

        //======================================================================
        // A. 【判据⑤】两级页表命中（4 KiB 页）
        //======================================================================
        //   VA = 0x0000_0000_... 采用 VA = {VPN1, VPN0, off}
        //   VA = 0x8040_2123 ⇒ VPN1 = 0x201, VPN0 = 0x002, off = 0x123
        //   一级 PTE（索引 VPN1）：指针，PPN = L1_PPN
        //   二级 PTE（索引 VPN0）：叶子 RW，PPN = 0x00055，A=1 D=1 U=0
        //   期望 PA = (0x55 << 12) | 0x123 = 0x0005_5123
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] = mk_pte(L1_PPN, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1); // 指针
        //   注：指针只需 V=1（R=W=X=0）
        //   一级指针：V=1、R=W=X=0、PPN=L1_PPN。
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] = mk_pte(L1_PPN, 1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 1'b1);
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))]   = mk_pte(22'h00055, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);

        pmp_deny_en = 1'b0;
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("A: 两级遍历成功（无 fault）", fault_o, 1'b0);
        expect_eq32("A: 4 KiB 页 PA = (PPN<<12)|off", pa_o, 32'h0005_5123);
        expect_eq1("A: 发出过 PTE 物理读（两级各一次）", saw_pte_req, 1'b1);
        expect_eq1("A: fill_valid 拉高（粘存观测）", fill_latch, 1'b1);
        expect_eq32("A: fill_va = 请求 VA", fill_va_l, 32'h8040_2123);
        expect_eq32("A: fill_ppn = PA[31:10]", {10'b0, fill_ppn_l}, 32'h0000_0154);

        //======================================================================
        // B. 【判据⑤】4 MiB 大页（一级命中叶子）
        //======================================================================
        //   VA = 0x8040_2123 ⇒ VPN1 = 0x201
        //   一级 PTE 直接是叶子（RWX），PPN[0] 必须为 0（= 4 MiB 对齐）
        //   期望 PA = (PPN[1] << 22) | VA[21:0]；PPN[1] = PTE.PPN[21:10]
        //   本用例 PPN = 0 ⇒ PA = VA[21:0] = 0x2123
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] =
            mk_pte(22'h000_000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);  // 4 MiB 叶子
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("B: 4 MiB 大页成功", fault_o, 1'b0);
        //   ★ 4 MiB  大页物理地址 = (PPN[1] << 22) | VA[21:0]；PPN[1] = PTE 的 PPN[21:10]。
        expect_eq32("B: 4 MiB 页 PA = {PPN[1], VA[21:0]}",
                    pa_o, (32'h0000_0000 << 22) | (32'h8040_2123 & 32'h003F_FFFF));

        //   ---- 大页 PPN[1] 非 0 的情形 ----
        //   ★ 4 MiB 大页要求 PTE 的 PPN[0]（= pte[19:10]）为 0，PPN[1]（= pte[31:20]）
        //     才是页基址。故构造 PPN = 0x00400 ⇒ PPN[1] = 1、PPN[0] = 0。
        //     期望 PA = (1 << 22) | VA[21:0] = 0x0040_2123。
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] =
            mk_pte(22'h000_400, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("B: 大页 PPN[1]=1 成功", fault_o, 1'b0);
        expect_eq32("B: 大页 PA = (PPN[1]<<22) | VA[21:0]",
                    pa_o, (32'h1 << 22) | (32'h8040_2123 & 32'h003F_FFFF));

        //   ---- ★ 错位超级页：PPN[0] ≠ 0 ⇒ page-fault ----
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] =
            mk_pte(22'h000_003, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);  // PPN[0]=3
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("B: ★ 错位超级页 ⇒ fault", fault_o, 1'b1);
        expect_eq32("B: ★ 错位超级页 cause = 13（load page fault）",
                    {27'b0, fault_cause_o}, 32'h0000_000D);

        //======================================================================
        // C. 【判据⑤】缺页 cause 12 / 13 / 15
        //======================================================================
        //   ---- C1：一级 PTE 的 V=0 ⇒ page-fault（load ⇒ 13）----
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] = 32'h0000_0000;   // V=0
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("C1: V=0 ⇒ fault", fault_o, 1'b1);
        expect_eq32("C1: V=0 load 缺页 cause = 13",
                    {27'b0, fault_cause_o}, 32'h0000_000D);
        //   ---- 取指 ⇒ 12 ----
        do_translate(32'h8040_2123, 2'b00, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq32("C1: V=0 取指缺页 cause = 12",
                    {27'b0, fault_cause_o}, 32'h0000_000C);
        //   ---- store ⇒ 15 ----
        do_translate(32'h8040_2123, 2'b10, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq32("C1: V=0 store 缺页 cause = 15",
                    {27'b0, fault_cause_o}, 32'h0000_000F);

        //   ---- C2：R=0 && W=1（保留编码）⇒ page-fault ----
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] =
            mk_pte(22'h00030, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1);  // V=1,W=1,R=0
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("C2: R=0&&W=1 保留编码 ⇒ fault", fault_o, 1'b1);
        expect_eq32("C2: 保留编码 cause = 13",
                    {27'b0, fault_cause_o}, 32'h0000_000D);

        //   ---- C3：二级 PTE 仍是指针（i<0）⇒ page-fault ----
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] = mk_pte(L1_PPN, 1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 1'b1);   // 一级指针
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))]   = mk_pte(22'h00055, 1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 1'b1);   // 二级也是指针（R=W=X=0）
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("C3: 二级仍为指针 ⇒ fault", fault_o, 1'b1);
        expect_eq32("C3: 二级指针 cause = 13",
                    {27'b0, fault_cause_o}, 32'h0000_000D);

        //   ---- C4：权限不足 —— load 访问 X-only 页 ⇒ load page fault ----
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))] =
            mk_pte(22'h00055, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1);  // X=1 only
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("C4: load X-only 页 ⇒ fault", fault_o, 1'b1);
        expect_eq32("C4: load X-only cause = 13",
                    {27'b0, fault_cause_o}, 32'h0000_000D);
        //   ---- ★ MXR=1 ⇒ 允许 load 读 X=1 页 ----
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b1);
        expect_eq1("C4: ★ MXR=1 ⇒ load 可读 X=1 页（无 fault）", fault_o, 1'b0);
        expect_eq32("C4: MXR 生效后 PA 正确", pa_o, 32'h0005_5123);
        //   ---- MXR 只影响 load：取指 X=1 页仍 OK ----
        do_translate(32'h8040_2123, 2'b00, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("C4: 取指 X=1 页 OK", fault_o, 1'b0);

        //   ---- C5：U 位与 SUM（只在页权限判定里，不入 PMP）----
        //   S 模式访问 U=1 页：SUM=0 ⇒ fault；SUM=1 ⇒ OK
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))] =
            mk_pte(22'h00055, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1);  // U=1, RW
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("C5: S 访问 U=1 页且 SUM=0 ⇒ fault", fault_o, 1'b1);
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b1, 1'b0);
        expect_eq1("C5: ★ SUM=1 ⇒ S 可访问 U=1 页", fault_o, 1'b0);
        //   ---- ★ S 取指在 U=1 页 ⇒ 恒 fault（与 SUM 无关）----
        do_translate(32'h8040_2123, 2'b00, `RV32GC_PRIV_S, 1'b1, 1'b0);
        expect_eq1("C5: ★ S 取指 U=1 页 ⇒ 恒 fault（SUM 不放开取指）",
                   fault_o, 1'b1);
        //   ---- U 模式访问 U=0 页 ⇒ fault ----
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))] =
            mk_pte(22'h00055, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);  // U=0
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_U, 1'b0, 1'b0);
        expect_eq1("C5: U 访问 U=0 页 ⇒ fault", fault_o, 1'b1);

        //======================================================================
        // D. 【判据⑤核心】★ 页表隐式访存过 PMP 被拒 ⇒ 对应原访问类型 access-fault
        //======================================================================
        //   恢复一个正常的二级叶子
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] = mk_pte(L1_PPN, 1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 1'b1);   // 一级指针
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))]   =
            mk_pte(22'h00055, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);
        //   一级 PTE 地址 = ROOT_BASE + VPN1*4 = 0x20000 + 0x804 = 0x20804
        //   二级 PTE 地址 = L1_BASE   + VPN0*4 = 0x30000 + 0x008 = 0x30008

        //   ---- D1：一级 PTE 访问被 PMP 拒，原访问 = load ⇒ cause 5 ----
        pmp_deny_en = 1'b1; pmp_deny_lo = 32'h0002_0800; pmp_deny_hi = 32'h0002_08FF;
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("D1: ★ PTE 访问被 PMP 拒 ⇒ fault", fault_o, 1'b1);
        expect_eq32("D1: ★ load 原访问 ⇒ cause 5（load access fault，非 page fault）",
                    {27'b0, fault_cause_o}, 32'h0000_0005);
        expect_eq1("D1: ★ PMP 拒时**不发** PTE 物理读（前置拦截）",
                   saw_pte_req, 1'b0);

        //   ---- D2：同上，原访问 = 取指 ⇒ cause 1 ----
        do_translate(32'h8040_2123, 2'b00, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq32("D2: ★ 取指原访问 ⇒ cause 1（instruction access fault）",
                    {27'b0, fault_cause_o}, 32'h0000_0001);

        //   ---- D3：同上，原访问 = store/AMO ⇒ cause 7 ----
        do_translate(32'h8040_2123, 2'b10, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq32("D3: ★ store/AMO 原访问 ⇒ cause 7（store access fault）",
                    {27'b0, fault_cause_o}, 32'h0000_0007);
        //   ---- cbo.zero（acc=11）按 store 判定 ⇒ cause 7 ----
        do_translate(32'h8040_2123, 2'b11, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq32("D3: cbo.zero(acc=11) ⇒ 按 store ⇒ cause 7",
                    {27'b0, fault_cause_o}, 32'h0000_0007);

        //   ---- D4：只拒**二级** PTE（一级放行）⇒ 仍按原访问类型报 access-fault ----
        pmp_deny_lo = 32'h0003_0000; pmp_deny_hi = 32'h0003_00FF;
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("D4: 二级 PTE 被拒 ⇒ fault", fault_o, 1'b1);
        expect_eq32("D4: 二级 PTE 被拒 ⇒ cause 5（load access fault）",
                    {27'b0, fault_cause_o}, 32'h0000_0005);
        expect_eq1("D4: 一级 PTE 读已发出（PMP 只拦二级）", saw_pte_req, 1'b1);
        expect_eq32("D4: 故障 tval = 虚拟地址（非 PTE 物理地址）",
                    fault_tval_o, 32'h8040_2123);

        //   ---- D5：PMP 放行 ⇒ 正常翻译（反证：证明 D1-D4 是 PMP 造成的）----
        pmp_deny_en = 1'b0;
        do_translate(32'h8040_2123, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("D5: PMP 放行 ⇒ 翻译成功（反证）", fault_o, 1'b0);
        expect_eq32("D5: PA 正确", pa_o, 32'h0005_5123);

        //======================================================================
        // E. A/D 位硬件更新路径
        //======================================================================
        //   ---- A=0 ⇒ 触发 pte_ad_update，等 pte_ad_done 后继续 ----
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))] =
            mk_pte(22'h00055, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);  // A=0
        //   手动推进：发起请求后不自动给 pte_ad_done，先检查 pte_ad_update 拉高
        @(negedge clk);
        req_va = 32'h8040_2123; req_acc = 2'b10; req_priv = `RV32GC_PRIV_S;
        req_sum = 1'b0; req_mxr = 1'b0; req_valid = 1'b1;
        @(negedge clk); req_valid = 1'b0;
        k = 0;
        while (!pte_ad_update && k < 100) begin @(posedge clk); #1; k = k + 1; end
        expect_eq1("E: A=0 ⇒ pte_ad_update 拉高", pte_ad_update, 1'b1);
        expect_eq32("E: pte_ad_data 置 A 位（bit6）",
                    pte_ad_data & (32'h1 << `RV32GC_PTE_A_BIT),
                    32'h1 << `RV32GC_PTE_A_BIT);
        expect_eq32("E: 写访问 ⇒ pte_ad_data 同时置 D 位（bit7）",
                    pte_ad_data & (32'h1 << `RV32GC_PTE_D_BIT),
                    32'h1 << `RV32GC_PTE_D_BIT);
        //   ---- 完成更新 ⇒ 翻译继续并成功 ----
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))] = pte_ad_data;   // 模拟原子更新落地
        @(negedge clk); pte_ad_done = 1'b1;
        @(negedge clk); pte_ad_done = 1'b0;
        k = 0;
        while (!req_done && k < 100) begin @(posedge clk); #1; k = k + 1; end
        expect_eq1("E: 更新后翻译成功", fault_o, 1'b0);
        expect_eq32("E: 更新后 PA 正确", pa_o, 32'h0005_5123);

        //   ---- A=1,D=1 ⇒ 不需要更新，直接完成 ----
        pte_mem[pte_index(L1_BASE + (32'h002 << 2))] =
            mk_pte(22'h00055, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);
        pte_ad_done = 1'b0;
        do_translate(32'h8040_2123, 2'b10, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq1("E: A/D 已置位 ⇒ 无需更新、翻译成功", fault_o, 1'b0);
        expect_eq32("E: PA 正确", pa_o, 32'h0005_5123);

        //======================================================================
        // F. 故障 tval 恒为虚拟地址（E5；norm:mtvalvaddrnot_paddr）
        //======================================================================
        pte_mem[pte_index(ROOT_BASE + (32'h201 << 2))] = 32'h0000_0000;   // V=0
        do_translate(32'hDEAD_B000, 2'b01, `RV32GC_PRIV_S, 1'b0, 1'b0);
        expect_eq32("F: 故障 tval = VA（非 PTE 物理地址）",
                    fault_tval_o, 32'hDEAD_B000);

        //======================================================================
        // 汇总
        //======================================================================
        $display("---- tb_ptw: pass=%0d fail=%0d ----", n_pass, n_fail);
        if (n_fail != 0) begin
            $display("TB_PTW FAIL: %0d 项断言失败", n_fail);
            $fatal(1, "TB_PTW_UNIT: FAIL");
        end
        if (n_pass == 0) begin
            $display("TB_PTW FAIL: 未捕获任何检查（fail-closed）");
            $fatal(1, "TB_PTW_UNIT: FAIL");
        end
        //   ★ PASS 标幅改到 final 块里打印：
        //   iverilog 会在 $finish 后输出 "x.sv:N: $finish called at ..."，
        //   若标幅在 initial 里打就不会是最后一行。
        //   final 块的输出恰好落在该回显之后 ⇒ 满足
        //   "末行 = <TB>_UNIT: PASS"的验收判据（且 PASS 唯一）。
        sim_ok = 1'b1;
        $finish;
    end

    initial begin
        #500000;
        $display("TB_PTW FAIL: 超时（未走完检查）");
        $fatal(1, "TB_PTW_UNIT: FAIL");
    end


    //--------------------------------------------------------------------------
    // PASS 横幅（唯一 PASS 字样，且保证是输出的**最后一行**）
    //   iverilog 在 $finish 后会回显 "file:line: $finish called at ..."，
    //   故横幅放在 final 块里打印（其输出落于该回显之后）。
    //   ★ fail-closed：sim_ok 只有在走完全部检查且 n_fail==0 时才被置 1，
    //     任何提前 $fatal / 超时路径都不会打印 PASS。
    //--------------------------------------------------------------------------
    final begin
        if (sim_ok && (n_fail == 0) && (n_pass > 0))
            $display("TB_PTW_UNIT: PASS");
    end

endmodule
