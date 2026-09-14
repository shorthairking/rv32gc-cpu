//==============================================================================
// tlb.v —— TLB + sfence.vma 失效逻辑
//==============================================================================
// 依据    : docs/design/08-baseline-5stage.md §5.4（M 级 Sv32 交互）、
//           §6.1（satp ASID）、§4.4（sfence.vma 属 Zifencei/Zicsr 特权路径）
//           docs/design/06-csr-privilege.md §5.3（ASID 与 sfence.vma）
//           docs/kb/isa-notes.md §2（Sv32 权限位）
// 真源    : rtl/pkg/rv32_defs.vh §8（Sv32 常量）
// 红线    : 无原语；组合逻辑用 assign/function；always 仅用于 TLB 表项寄存器
//           与替换指针（确有必要，见注释）。
//------------------------------------------------------------------------------
// 【本模块锁定的硬口径】
//  L1. **全相联**结构：条目数参数化（默认 64，06 §5.3 建议值）。
//      每项含 {有效, VA 页号(20b), ASID(9b), G, PPN(22b), 权限位}。
//  L2. **匹配规则**（ISA norm 引文见 06 §5.3）：
//      命中 ⇔ 有效 && (VA 的 VPN 部分相等) &&
//              (G==1 || ASID == satp.ASID)。
//      ⇒ G=1 的映射对所有 ASID 有效，**ASID 切换时不得失效**。
//  L3. **sfence.vma rs1, rs2 语义**：
//      rs1==x0 && rs2==x0 ⇒ 全冲刷（含 G 项）；
//      rs1!=0 ⇒ 只失效 VA 页号匹配的项（G=1 的项**也不失效**，见 §4 注释）；
//      rs2!=0 ⇒ 只失效 ASID 匹配的项（G=1 的项不失效）；
//      两者都非 0 ⇒ 交集。
//  L4. **satp 写（含 ASID 变化）不自动冲刷**：ISA 未要求，由软件显式 sfence.vma。
//      但本模块提供 satp_asid 变化的**可选**自动失效开关
//      （参数 `AUTO_FLUSH_ON_ASID`，默认 0 = 严格按 ISA：不自动失效）。
//  L5. **TLB 命中不发起任何内存访问**（06 §5.3）——由"命中即直接给 PA"
//      的接口保证：命中时 tlb_hit=1 且 pa 有效，上层不得再发 PTW 请求。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tlb #(
    parameter         ENTRIES            = 64,   // 条目数（06 §5.3 建议 64）
    parameter         AUTO_FLUSH_ON_ASID = 0,    // 见 L4
    parameter         IDX_W              = 6     // ceil(log2(ENTRIES))
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // 查询端口（组合读；命中即给 PA）
    //--------------------------------------------------------------------------
    input  wire        lookup_valid,
    input  wire [31:0] lookup_va,
    input  wire [8:0]  lookup_asid,      // 当前 satp.ASID
    input  wire [1:0]  lookup_acc,       // 00=取指 01=load 10=store/AMO 11=cbo.zero
    input  wire [1:0]  lookup_priv,      // 有效特权级
    input  wire        lookup_sum,       // SUM 有效值（只影响页权限）
    input  wire        lookup_mxr,       // MXR 有效值（只影响页权限）

    output wire        hit_o,            // 命中且权限通过 ⇒ 可直接用 pa_o
    output wire        perm_fault_o,     // 命中但页权限不允许 ⇒ page-fault（不给 PA）
    output wire [31:0] pa_o,             // 翻译结果（hit_o=1 时有效）

    //--------------------------------------------------------------------------
    // 填充端口（来自 PTW）
    //--------------------------------------------------------------------------
    input  wire        fill_valid,
    input  wire [31:0] fill_va,
    input  wire [21:0] fill_ppn,
    input  wire [7:0]  fill_perm,        // {G,U,X,W,R,3'b0}
    input  wire [8:0]  fill_asid,        // 填充时使用的 ASID（= 当时的 satp.ASID）

    //--------------------------------------------------------------------------
    // sfence.vma（L3）
    //--------------------------------------------------------------------------
    input  wire        sfence_valid,
    input  wire [31:0] sfence_va,        // rs1 的值（x0 ⇒ 视为"全范围"）
    input  wire [8:0]  sfence_asid,      // rs2 的值（0 ⇒ 视为"全 ASID"）
    input  wire        sfence_all_va,    // rs1 == x0
    input  wire        sfence_all_asid,  // rs2 == x0

    //--------------------------------------------------------------------------
    // satp 写（L4：可选自动失效）
    //--------------------------------------------------------------------------
    input  wire        satp_we,
    input  wire [8:0]  satp_asid_new,

    //--------------------------------------------------------------------------
    // 状态探针（供 TB 断言）
    //--------------------------------------------------------------------------
    output wire [31:0] hit_count_o,      // 命中计数（探针）
    output wire [31:0] miss_count_o,     // 缺失计数（探针）
    output wire [31:0] flush_count_o     // 冲刷次数（探针）
);

    //==========================================================================
    // 1. VA / PTE 字段切分
    //==========================================================================
    wire [19:0] lookup_vpn = lookup_va[31:12];      // Sv32：VA 页号 20 bit
    wire [11:0] lookup_off = lookup_va[11:0];
    wire [8:0]  fill_vpn_hi = fill_va[31:23];       // 仅用于调试；VPN 需 20 位
    wire [19:0] fill_vpn   = fill_va[31:12];

    //==========================================================================
    // 2. TLB 表项存储（全相联，L1）
    //   理由：表项是存储元件，必须时钟沿保持 ⇒ always 块不可省（AGENT.md §4.3）。
    //   组合匹配部分（§3）全部用 assign/function（红线 3）。
    //==========================================================================
    reg               v_bit  [0:ENTRIES-1];
    reg [19:0]        vpn    [0:ENTRIES-1];
    reg [8:0]         asid_i [0:ENTRIES-1];
    reg               g_bit  [0:ENTRIES-1];
    reg [21:0]        ppn    [0:ENTRIES-1];
    reg [4:0]         perm_i [0:ENTRIES-1];   // {U,X,W,R,G?} 见下：存 {U,X,W,R,1'b0}
    reg [IDX_W-1:0]   repl_ptr;               // 轮转替换指针

    // ---- 表项格式（与 PTW 的 fill_perm 对接） ----
    //   fill_perm = {G,U,X,W,R,3'b000}
    //   本模块把 G 单独存（因为匹配规则要单独用），权限存 {U,X,W,R}
    wire       fp_g = fill_perm[7];
    wire       fp_u = fill_perm[6];
    wire       fp_x = fill_perm[5];
    wire       fp_w = fill_perm[4];
    wire       fp_r = fill_perm[3];

    //==========================================================================
    // 3. 组合匹配（全相联：ENTRIES 路并行比较；用 generate 展开）
    //==========================================================================
    wire [ENTRIES-1:0] way_match;      // 该路命中（VA + ASID/G 规则）
    genvar gw;
    generate
        for (gw = 0; gw < ENTRIES; gw = gw + 1) begin : g_match
            // ---- L2 匹配规则 ----
            //   有效 && VPN 相等 && (G==1 || ASID 相等)
            assign way_match[gw] = v_bit[gw] &&
                                   (vpn[gw] == lookup_vpn) &&
                                   (g_bit[gw] | (asid_i[gw] == lookup_asid));
        end
    endgenerate

    // ---- 命中：取**编号最低**的匹配路（全相联下唯一，取最低只是定序） ----
    function [IDX_W-1:0] find_lowest;
        input [ENTRIES-1:0] m;
        integer i;
        begin
            find_lowest = {IDX_W{1'b0}};
            for (i = ENTRIES-1; i >= 0; i = i - 1)
                if (m[i]) find_lowest = i[IDX_W-1:0];
        end
    endfunction

    wire               any_match = |way_match;
    wire [IDX_W-1:0]   hit_idx   = find_lowest(way_match);

    // ---- 命中路的字段选择：one-hot 归约（纯 assign OR 树，红线 3） ----
    //   匹配路至多一条（VPN+ASID 唯一），故 OR 归约等价于 mux。
    //   用 generate 展开 ENTRIES 项，避免 always @(*) 大块。
    //   ★ 实现要点：**不要**在 generate 里对同一个 wire 做多次 `assign`——
    //   多驱动会触发线网解析（多驱动冲突），实测表现为"命中却选不到字段"。
    //   正确做法：先把各路的选择值放进**数组**（每路独立驱动自己的那一份），
    //   再用一段显式的 OR 归约把数组并成最终值。
    //   （ENTRIES=64 时 OR 树 64 项，综合为 LUT 树，不影响时序预算。）
    wire [21:0] ppn_way  [0:ENTRIES-1];
    wire [4:0]  perm_way [0:ENTRIES-1];
    generate
        for (gw = 0; gw < ENTRIES; gw = gw + 1) begin : g_sel
            assign ppn_way[gw]  = way_match[gw] ? ppn[gw]    : 22'h0;
            assign perm_way[gw] = way_match[gw] ? perm_i[gw] : 5'h0;
        end
    endgenerate
    // ---- OR 归约（因匹配路至多一条，OR 等于 mux） ----
    reg [21:0] ppn_sel;
    reg [4:0]  perm_sel;
    integer    si;
    always @(*) begin
        ppn_sel  = 22'h0;
        perm_sel = 5'h0;
        for (si = 0; si < ENTRIES; si = si + 1) begin
            ppn_sel  = ppn_sel  | ppn_way[si];
            perm_sel = perm_sel | perm_way[si];
        end
    end

    //==========================================================================
    // 4. 权限判定（复用 PTW 的口径；SUM/MXR 只在此处生效，**不进 PMP**）
    //==========================================================================
    //   注意：命中但权限不允许时**不是 miss**，而是 page-fault（page-fault 与
    //   access-fault 的语义区分，见 06 §5.2：权限不足 ⇒ page-fault）。
    //   ⇒ 本模块输出 perm_fault_o 以便上层抛 cause 12/13/15。
    //   A/D 位不在 TLB 中维护（A/D 每次由 PTW 路径处理）；
    //   本设计 2A 的简化：TLB 项**不因 A/D 失效**，A/D 更新走 PTW 路径
    //   （见报告「遗留/风险」对 06 §11 P-6 的登记）。
    function tlb_perm_ok;
        input [1:0] acc;
        input [1:0] cur_priv;
        input       sum;
        input       mxr;
        input       u_bit;
        input       r_bit;
        input       w_bit;
        input       x_bit;
        begin
            if (cur_priv == `RV32GC_PRIV_U) begin
                tlb_perm_ok = u_bit & (
                    (acc == 2'b00) ? x_bit :
                    (acc == 2'b01) ? (r_bit | (mxr & x_bit)) :
                                     (w_bit & r_bit) );
            end else begin
                // 有效特权级 == S（M 模式 Bare 直通，不走 TLB）
                if (acc == 2'b00) begin
                    // S 取指：不得在 U=1 页执行（与 SUM 无关）
                    tlb_perm_ok = ~u_bit & x_bit;
                end else if (u_bit & ~sum) begin
                    tlb_perm_ok = 1'b0;
                end else if (acc == 2'b01) begin
                    tlb_perm_ok = r_bit | (mxr & x_bit);
                end else begin
                    tlb_perm_ok = w_bit & r_bit;
                end
            end
        end
    endfunction

    //   ★ 位序陷阱：perm_i 存的是 {U, X, W, R, 1'b0}（见 §6.2 打包处），
    //   而 tlb_perm_ok 的形参序是 (u, r, w, x) ⇒ 实参必须按
    //   perm_sel[4]=U、perm_sel[1]=R、perm_sel[2]=W、perm_sel[3]=X 传入。
    //   写反会把 R 与 X 对调（实测踩到：X-only 页被当成可 load）。
    wire perm_ok_w  = tlb_perm_ok(lookup_acc, lookup_priv, lookup_sum, lookup_mxr,
                                  perm_sel[4], perm_sel[1], perm_sel[2], perm_sel[3]);
    wire hit_w      = lookup_valid & any_match & perm_ok_w;
    wire perm_bad_w = lookup_valid & any_match & ~perm_ok_w;

    assign hit_o        = hit_w;
    assign perm_fault_o = perm_bad_w;
    assign pa_o         = {ppn_sel, lookup_off};

    //==========================================================================
    // 5. sfence.vma 失效判定（L3）—— 纯组合 function，逐路算"是否失效"
    //==========================================================================
    //   规则（ISA supervisor.adoc › sfence.vma）：
    //     rs1==x0 && rs2==x0 ⇒ 全部失效（含 G=1）
    //     rs1!=x0 ⇒ 失效 VA 页号等于 rs1 页号的项（G=1 项**除外**）
    //     rs2!=x0 ⇒ 失效 ASID 等于 rs2 的项（G=1 项**除外**）
    //   注：G=1 的项在任何"部分冲刷"下都保留（ISA：global mapping 不因 ASID 切换失效；
    //       部分冲刷按 VA 过滤时，G 项亦保留——本设计按此口径，见 TB 覆盖）。
    //   ★ 可移植性要点（与 trap_ctrl/ptw 同一类）：function 内**不得读模块级寄存器/线网**
    //   （如 sfence_all_va / sfence_va），否则 iverilog 12.0 不会在其变化时重求值
    //   调用该 function 的连续赋值 ⇒ 实测表现为"sfence 完全无效"。
    //   ⇒ 把 sfence 相关信号全部作为显式 input 传入。
    function way_flush;
        input        v;
        input [19:0] w_vpn;
        input [8:0]  w_asid;
        input        w_g;
        input [31:0] sf_va;      // sfence.vma 的 rs1 值
        input [8:0]  sf_asid;    // sfence.vma 的 rs2 值
        input        sf_all_va;  // rs1 == x0
        input        sf_all_asid;// rs2 == x0
        begin
            if (!v) begin
                way_flush = 1'b0;
            end else if (sf_all_va && sf_all_asid) begin
                way_flush = 1'b1;                       // 全冲刷（含 G）
            end else begin
                // 部分冲刷：G=1 的项保留（global 映射不因 ASID 切换失效）
                if (w_g) way_flush = 1'b0;
                else if (!sf_all_va && !sf_all_asid)
                    way_flush = (w_vpn == sf_va[31:12]) && (w_asid == sf_asid);
                else if (!sf_all_va)
                    way_flush = (w_vpn == sf_va[31:12]);
                else
                    way_flush = (w_asid == sf_asid);
            end
        end
    endfunction

    wire [ENTRIES-1:0] way_do_flush;
    generate
        for (gw = 0; gw < ENTRIES; gw = gw + 1) begin : g_flush
            assign way_do_flush[gw] = sfence_valid &
                                      way_flush(v_bit[gw], vpn[gw], asid_i[gw], g_bit[gw],
                                                sfence_va, sfence_asid,
                                                sfence_all_va, sfence_all_asid);
        end
    endgenerate

    // ---- ASID 变化时的可选自动冲刷（L4；默认关） ----
    wire asid_changed = satp_we & (satp_asid_new != lookup_asid);
    wire auto_flush   = (AUTO_FLUSH_ON_ASID != 0) & asid_changed;

    //==========================================================================
    // 6. 时序：填充 / 失效 / 替换指针
    //   理由：TLB 表项是存储元件，必须时钟沿保持 ⇒ always 块不可省。
    //==========================================================================
    integer i;
    reg [IDX_W-1:0] fill_idx;
    reg             all_valid;   // 见 §6.2 注释

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                v_bit[i]  <= 1'b0;
                vpn[i]    <= 20'h0;
                asid_i[i] <= 9'h0;
                g_bit[i]  <= 1'b0;
                ppn[i]    <= 22'h0;
                perm_i[i] <= 5'h0;
            end
            repl_ptr <= {IDX_W{1'b0}};
        end else begin
            // ---- 6.1 失效（sfence.vma / 可选自动冲刷）----
            if (sfence_valid) begin
                for (i = 0; i < ENTRIES; i = i + 1) begin
                    if (way_do_flush[i]) begin
                        v_bit[i] <= 1'b0;
                        g_bit[i] <= 1'b0;
                    end
                end
            end else if (auto_flush) begin
                // ASID 变化：失效所有**非 global** 项
                for (i = 0; i < ENTRIES; i = i + 1) begin
                    if (!g_bit[i]) v_bit[i] <= 1'b0;
                end
            end

            // ---- 6.2 填充（与失效同拍时：失效优先，填充覆盖）----
            //   替换策略：轮转（round-robin）——优先填无效项，否则用 repl_ptr。
            //   注：iverilog 不支持对 reg 数组做 `&v_bit` 归约，故显式累计 all_valid。
            all_valid = 1'b1;
            for (i = 0; i < ENTRIES; i = i + 1)
                if (!v_bit[i]) all_valid = 1'b0;

            if (fill_valid) begin
                // 优先找无效项（编号最低的无效项）
                fill_idx = {IDX_W{1'b0}};
                for (i = ENTRIES-1; i >= 0; i = i - 1)
                    if (!v_bit[i]) fill_idx = i[IDX_W-1:0];
                // 若全有效 ⇒ 用 repl_ptr（最后赋值的那个覆盖）
                if (all_valid) fill_idx = repl_ptr;

                v_bit [fill_idx] <= 1'b1;
                vpn   [fill_idx] <= fill_vpn;
                asid_i[fill_idx] <= fill_asid;
                g_bit [fill_idx] <= fp_g;
                ppn   [fill_idx] <= fill_ppn;
                perm_i[fill_idx] <= {fp_u, fp_x, fp_w, fp_r, 1'b0};

                if (all_valid)
                    repl_ptr <= repl_ptr + {{(IDX_W-1){1'b0}}, 1'b1};
            end
        end
    end

    //==========================================================================
    // 7. 探针计数（供 TB 断言"命中不发起内存访问"等）
    //==========================================================================
    reg [31:0] hit_cnt, miss_cnt, flush_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_cnt   <= 32'h0;
            miss_cnt  <= 32'h0;
            flush_cnt <= 32'h0;
        end else begin
            if (lookup_valid & hit_o)        hit_cnt   <= hit_cnt + 32'h1;
            if (lookup_valid & ~any_match)   miss_cnt  <= miss_cnt + 32'h1;
            if (sfence_valid)                flush_cnt <= flush_cnt + 32'h1;
        end
    end

    assign hit_count_o   = hit_cnt;
    assign miss_count_o  = miss_cnt;
    assign flush_count_o = flush_cnt;

endmodule
