//==============================================================================
// rtl/mem/pmp_check.v —— PMP 16 项物理内存保护检查（M 级，纯组合）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 出处    : docs/design/08-baseline-5stage.md §5.4（M 级）、§5.5 抉择 3/4/5/6、
//           §6.5（PMP 粒度裁决 G=0）
//           docs/kb/isa-notes.md §3.1–§3.4（PMP 三条强制项 + 每笔独立）
//           riscv-isa-manual/src/priv/machine.adoc
//             「Physical Memory Protection CSRs」（PMP CSRs / Priority and Matching Logic）
// 唯一真源: rtl/pkg/rv32_defs.vh §7（PMP 常量）/ §6（cause 码）
//           rtl/pkg/core_params.vh §6（PMP 项数 16、G=0）
//           **include 顺序：先 rv32_defs.vh 后 core_params.vh**（AGENT.md §3.2）
//------------------------------------------------------------------------------
// 实现口径（逐条对应规范强制项 / 本设计抉择，不得各自发挥）：
//
//  [norm:pmpentrypriority] 静态优先级 —— 编号最低的、能匹配该访存操作**任意字节**
//      的 PMP 项，决定该操作成功或失败。本模块用 for 循环**从 0 到 N-1 递增**扫描，
//      首次命中即锁定（`hit_any` → `hit_idx`），高编号项一律不得覆盖。
//
//  [norm:pmpfullmatch_required] 整笔匹配 —— 命中的项必须覆盖该笔操作的**全部字节**，
//      只覆盖一部分 ⇒ 该笔失败（与 R/W/X 位无关）。本模块对每项同时算
//      `sub_any`（是否覆盖任一字节，用于**选**项）与 `sub_all`（是否覆盖全部字节，
//      用于**判**权）：选中项若 `sub_all=0` ⇒ 直接 denied，不继续看后面的项。
//
//  [norm:pmpmisalignedaccess_behavior] 每笔独立 —— 本模块只检查**一笔**访问
//      （单地址 + 字节数）。非对齐访问由上层 `lsu.v` 拆成多笔、**每笔独立调用**，
//      因此部分副作用可落地（08 §5.5 抉择 3）。
//
//  [norm:pmprwxcheck] L/R/W/X 判定 ——
//      · L=0 且访问特权级为 M ⇒ 成功；
//      · 否则（L=1，或访问特权级为 S/U）⇒ 仅当访问类型对应的 R/W/X 位为 1 才成功。
//
//  [norm:pmpnoentry_match] 无匹配项 —— M 模式成功；S/U 模式**若至少实现了一项
//      PMP 则失败**。本设计实现 16 项（`RV32GC_PMP_ENTRIES`>0）⇒ S/U 无匹配恒失败
//      （08 §5.5 抉择 6）。NOTE：全部项 A=OFF 时所有 S/U 访存失败。
//
//  [T4] AMO/SC 被 PMP 拒 **恒 cause 7**（store/AMO access fault）——
//      由输入端口 `is_amo_like` 表达访问类型归属，本模块只报「拒 + 该访问类型的
//      access-fault cause」；AMO 的内部读+写两相由 `amo_unit.v` 统一按 store 口径
//      上报，故对外**只可能是 cause 7**。
//
//  G=0 粒度（08 §6.5 用户裁决）—— `pmpaddr` 读写**不做低位掩码**；
//      **NA4 可用**（A=10 覆盖 4 B）；NAPOT 的编码为「N 个连续 1 的最低地址位 + 1 个 0」，
//      本模块用「尾随 0 计数」解出 NAPOT 掩码，天然支持 N=0（=8 B 块，编码 …0001）。
//
//------------------------------------------------------------------------------
// 风格（AGENT.md §4.3 组合逻辑红线）：
//   模块内**无 always 块**；全部为 `assign` 连续赋值 + `function`（每项匹配、
//   NAPOT 掩码解码、cause 编码）。位宽全部显式。
//
// 输入/输出契约（供 lsu.v 例化；端口名与位宽改一处即全量同步）：
//   clk / rst_n         : 时钟与同步复位（本模块纯组合，仅为握手与风格一致性保留，
//                         不参与任何逻辑；保留以便后续插入时序断言）
//   cfg_i[2*N*8-1:0]    : N 项 pmpcfg 的平铺视图：{..., cfg1[7:0], cfg0[7:0]}
//                         （第 i 项的 8 bit 位于 [i*8+7 : i*8]）
//   addr_i[15:0]        : N 项 pmpaddr[31:0]（每项 32 bit，仅 [29:0] 有效）
//   acc_pa_i[31:0]      : 本笔访问的**物理地址**（S 级 PA，PMP 检查在翻译之后）
//   acc_bytes_i[4:0]    : 本笔访问字节数（1/2/4；非对齐拆分后每笔为 1 或多个字节）
//   acc_priv_i[1:0]     : 发起访问的有效特权级（MPRV=1 时已由 lsu 换成 MPP）
//   acc_type_i[1:0]     : 访问类型 —— 0=load、1=store、2=execute、3=AMO/LRSC/CMO
//   allow_o             : 本笔是否放行（1=通过）
//   fault_cause_o[4:0]  : allow_o=0 时给出的 cause 码（1/5/7，见下）
//   hit_o               : 本笔是否命中了某项 PMP（诊断/覆盖用）
//   hit_idx_o[3:0]      : 命中的最低编号项（hit_o=1 时有效）
//   denied_by_full_o    : 是否因「整笔未全覆盖」而失败（诊断/覆盖用）
//
// cause 映射 [DOC:docs/kb/isa-notes.md T2/T4；rv32_defs.vh §6.1]：
//   execute 被拒 ⇒ cause 1（instruction access fault）
//   load    被拒 ⇒ cause 5（load access fault）
//   store / AMO / LRSC / CMO 被拒 ⇒ cause 7（store/AMO access fault）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module pmp_check #(
    parameter integer PMP_ENTRIES = `RV32GC_PMP_ENTRIES,   // 16（真源；不得在此改值）
    parameter integer PMP_G       = `RV32GC_PMP_GRANULARITY, // 0（G=0 ⇒ NA4 可用）
    parameter integer ADDR_W      = 32,                      // 物理地址宽度
    parameter integer BYTES_W     = 5                        // 字节数位宽（最大 16 B 亦够）
) (
    input  wire                     clk,            // 时钟（本模块纯组合，仅登记）
    input  wire                     rst_n,          // 同步复位（同上）

    // ---- PMP 配置与地址（来自 csr_file，按项平铺） ----
    input  wire [PMP_ENTRIES*8-1:0] cfg_i,          // 每项 8 bit：{L,0,A[1:0],X,W,R}
    input  wire [PMP_ENTRIES*32-1:0] addr_i,        // 每项 32 bit pmpaddr（有效 [29:0]）

    // ---- 本笔访问（单笔：拆笔由 lsu.v 负责） ----
    input  wire [ADDR_W-1:0]        acc_pa_i,       // 访问物理地址（翻译后的 S 级 PA）
    input  wire [BYTES_W-1:0]       acc_bytes_i,    // 本笔字节数（1/2/4）
    input  wire [1:0]               acc_priv_i,     // 有效特权级：00=U 01=S 11=M
    input  wire [1:0]               acc_type_i,     // 0=load 1=store 2=execute 3=AMO/LRSC/CMO

    // ---- 结果 ----
    output wire                     allow_o,        // 1=放行
    output wire [`RV32GC_CAUSE_W-1:0] fault_cause_o, // allow_o=0 时的 cause
    output wire                     hit_o,          // 是否命中某项
    output wire [3:0]               hit_idx_o,      // 命中的最低编号项
    output wire                     denied_by_full_o// 因整笔未全覆盖而失败
);

    //==========================================================================
    // 1. 局部常量（从真源取，禁止在本模块重定义取值）
    //==========================================================================
    localparam [2:0] T_LOAD  = 3'd0;   // 访问类型编码（本模块内部约定）
    localparam [2:0] T_STORE = 3'd1;
    localparam [2:0] T_EXEC  = 3'd2;
    localparam [2:0] T_AMO   = 3'd3;

    localparam [1:0] A_OFF   = `RV32GC_PMP_A_OFF;
    localparam [1:0] A_TOR   = `RV32GC_PMP_A_TOR;
    localparam [1:0] A_NA4   = `RV32GC_PMP_A_NA4;
    localparam [1:0] A_NAPOT = `RV32GC_PMP_A_NAPOT;

    localparam [1:0] PRIV_U  = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S  = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M  = `RV32GC_PRIV_M;

    //==========================================================================
    // 2. 纯组合辅助函数
    //==========================================================================
    // ---- 2.1 NAPOT 掩码解码 -------------------------------------------------
    // NAPOT 编码：`pmpaddr` 低位为「N 个连续 1 后接一个 0」（独占尾随 0）。
    //   编码 …0001 ⇒ N=0 ⇒ 8 B 块（掩码低 3 位）
    //   编码 …0011 ⇒ N=1 ⇒ 16 B 块
    //   编码 …0111 ⇒ N=2 ⇒ 32 B 块
    // 即块内偏移位宽 = (尾随 0 个数 + 1)，块大小 = 2^(trailing_zeros+1) 字节。
    // 本函数返回「块大小 - 1」形式的字节掩码（低位全 1 的掩码）。
    function [ADDR_W-1:0] napot_bytemask;
        input [ADDR_W-1:0] pa;       // pmpaddr
        integer z;                   // 尾随 0 计数
        begin
            z = 0;
            // 从最低位起数连续 0；z 最多到 ADDR_W-1（pa==0 在规范中不是合法 NAPOT
            // 编码，此处保守退化，绝不让 X/Z 传播到掩码）。
            while ((z < ADDR_W-1) && (pa[z] == 1'b0)) begin
                z = z + 1;
            end
            if (z >= ADDR_W-1) begin
                // 退化：4 B 块（最低 2 位全 1 ⇒ 掩码 = 3）
                napot_bytemask = {{(ADDR_W-2){1'b0}}, 2'b11};
            end else begin
                // 块内偏移位宽 = z + 1 ⇒ 字节掩码 = (1 << (z+1)) - 1
                // 注意 z 最大 30 ⇒ z+1 最大 31，移位量位宽足够且不越界。
                napot_bytemask = ({{(ADDR_W-1){1'b0}}, 1'b1} << (z + 1)) - 1'b1;
            end
        end
    endfunction

    // ---- 2.2 单笔访问命中判定 -----------------------------------------------
    // 返回 1 表示 addr 落在该项覆盖范围内；同时给出「是否覆盖首字节 / 是否覆盖
    // 全部字节」。整笔匹配用 all（规范强制），选项用 any（规范强制）。
    // 说明：用整笔字节区间 [addr, addr+bytes-1] 与项区间求交。
    function hit_any_byte;
        input [ADDR_W-1:0] lo;      // 本笔首地址
        input [ADDR_W-1:0] hi;      // 本笔末地址（= lo + bytes - 1）
        input [ADDR_W-1:0] base_l;  // 项覆盖起点（含）
        input [ADDR_W-1:0] base_h;  // 项覆盖终点（含）
        begin
            hit_any_byte = (lo <= base_h) && (hi >= base_l);
        end
    endfunction

    function hit_all_bytes;
        input [ADDR_W-1:0] lo;
        input [ADDR_W-1:0] hi;
        input [ADDR_W-1:0] base_l;
        input [ADDR_W-1:0] base_h;
        begin
            hit_all_bytes = (lo >= base_l) && (hi <= base_h);
        end
    endfunction

    // ---- 2.3 访问类型 → access-fault cause 码 -------------------------------
    // [DOC:docs/kb/isa-notes.md T2/T4；T4：AMO/SC 恒 cause 7]
    function [`RV32GC_CAUSE_W-1:0] type_to_fault_cause;
        input [1:0] t;
        begin
            case (t)
                T_EXEC   : type_to_fault_cause = `RV32GC_EXC_INSN_ACCESS_FAULT;  // 1
                T_LOAD   : type_to_fault_cause = `RV32GC_EXC_LOAD_ACCESS_FAULT;  // 5
                T_STORE,
                T_AMO    : type_to_fault_cause = `RV32GC_EXC_STORE_ACCESS_FAULT; // 7
                default  : type_to_fault_cause = `RV32GC_EXC_STORE_ACCESS_FAULT; // 7
            endcase
        end
    endfunction

    // ---- 2.4 访问类型 → 所需权限位（R/W/X） ---------------------------------
    // 返回 {need_r, need_w, need_x}：非 M 模式（或 L=1）时按此三项判权。
    // AMO/LRSC/CMO 按 store 口径（既读又写）—— T4 只约束**异常 cause**，
    // 权限判定按规范「store/AMO」同族处理（cmo.adoc 同族 store/AMO 语义）。
    function [2:0] type_to_perm;
        input [1:0] t;
        begin
            case (t)
                T_LOAD : type_to_perm = 3'b100;   // need R
                T_STORE: type_to_perm = 3'b010;   // need W
                T_EXEC : type_to_perm = 3'b001;   // need X
                T_AMO  : type_to_perm = 3'b010;   // store/AMO 同族 ⇒ 需 W（T4）
                default: type_to_perm = 3'b010;
            endcase
        end
    endfunction

    //==========================================================================
    // 3. 本笔访问字节区间（含端点）
    //==========================================================================
    // 注意：hi 用零扩展加法，溢出（跨 4 GB）在 RV32 物理地址空间不存在；
    // 显式加宽 1 位再截断以免综合工具误判位宽。
    wire [ADDR_W:0] acc_lo_x = {1'b0, acc_pa_i};
    wire [ADDR_W:0] acc_hi_x = acc_lo_x + {{(ADDR_W+1-BYTES_W){1'b0}}, acc_bytes_i} - 1'b1;
    wire [ADDR_W-1:0] acc_lo = acc_pa_i;
    wire [ADDR_W-1:0] acc_hi = acc_hi_x[ADDR_W-1:0];

    wire [2:0] need_perm = type_to_perm(acc_type_i);
    wire       need_r    = need_perm[2];
    wire       need_w    = need_perm[1];
    wire       need_x    = need_perm[0];

    // 访问特权级是 M 吗（MPRV=1 时 lsu 已把 acc_priv_i 换成 MPP）
    wire is_m_mode = (acc_priv_i == PRIV_M);

    //==========================================================================
    // 4. 逐项解码：项区间 + 是否覆盖任一字节 + 是否覆盖全部字节 + 权限是否足够
    //==========================================================================
    // 用 generate + 每项独立的连续赋值网（无 always）。选中的命中项由 §5 的
    // 优先级网络从 0 号起扫描决定。
    wire [(PMP_ENTRIES*8)-1:0]  cfg_flat;
    wire [(PMP_ENTRIES*32)-1:0] addr_flat;
    assign cfg_flat  = cfg_i;
    assign addr_flat = addr_i;

    // 每项的覆盖区间（组合）
    wire [ADDR_W-1:0] ent_low  [0:PMP_ENTRIES-1];
    wire [ADDR_W-1:0] ent_high [0:PMP_ENTRIES-1];
    wire              ent_any  [0:PMP_ENTRIES-1];
    wire              ent_all  [0:PMP_ENTRIES-1];
    wire              ent_ok   [0:PMP_ENTRIES-1];   // 命中且权限足够（该项可放行）
    wire [1:0]        ent_a    [0:PMP_ENTRIES-1];
    wire              ent_l    [0:PMP_ENTRIES-1];

    genvar gi;
    generate
        for (gi = 0; gi < PMP_ENTRIES; gi = gi + 1) begin : G_PMP_ENTRY
            wire [7:0]        c    = cfg_flat[gi*8 +: 8];
            wire [ADDR_W-1:0] a    = addr_flat[gi*32 +: 32];

            // 上一项的 pmpaddr（用于 TOR 的下界）。第 0 项的下界恒为 0。
            wire [ADDR_W-1:0] a_prev = (gi == 0) ? {ADDR_W{1'b0}}
                                                 : addr_flat[(gi-1)*32 +: 32];

            // A 字段与 L 位
            assign ent_a[gi] = c[`RV32GC_PMP_A_LSB +: 2];
            assign ent_l[gi] = c[`RV32GC_PMP_L_BIT];

            // ---- 各项覆盖区间（单位：字节地址） ----
            // A=OFF   ：无覆盖（区间退化为空，由 ent_any 的 A!=OFF 门控）
            // A=TOR   ：[pmpaddr[i-1] , pmpaddr[i] - 1]（i=0 时下界为 0）
            //           规范口径：y < pmpaddr[i] 即被覆盖；下界取上一项地址。
            //           ★ 注意 TOR 的地址语义是「pmpaddr 直接就是字节地址」，不做 4 B 移位
            //             （G=0 且本设计 pmpaddr 值为地址口径，见 core_params §6）。
            // A=NA4   ：[pmpaddr , pmpaddr + 3]（G=0 ⇒ 可用）
            // A=NAPOT ：[pmpaddr & ~mask , (pmpaddr & ~mask) | mask]（NAPOT 向下对齐）
            wire [ADDR_W-1:0] napot_msk = napot_bytemask(a);

            assign ent_low[gi] =
                (ent_a[gi] == A_TOR)   ? a_prev :
                (ent_a[gi] == A_NA4)   ? a :
                (ent_a[gi] == A_NAPOT) ? (a & ~napot_msk) :
                                         a;      // OFF：区间无意义（由 ent_any 门控）

            assign ent_high[gi] =
                (ent_a[gi] == A_TOR)   ? (a - 1'b1) :
                (ent_a[gi] == A_NA4)   ? (a + 32'd3) :
                (ent_a[gi] == A_NAPOT) ? ((a & ~napot_msk) | napot_msk) :
                                         a;

            // ---- 覆盖判定 ----
            // ent_any：命中该笔的**任一字节**（规范用于**选**项）
            // ent_all：覆盖该笔的**全部字节**（规范用于**判**权，整笔匹配强制）
            wire a_off = (ent_a[gi] == A_OFF);
            assign ent_any[gi] = !a_off &&
                                 hit_any_byte(acc_lo, acc_hi, ent_low[gi], ent_high[gi]);
            assign ent_all[gi] = !a_off &&
                                 hit_all_bytes(acc_lo, acc_hi, ent_low[gi], ent_high[gi]);

            // ---- 权限判定 [norm:pmprwxcheck] ----
            // L=0 且访问特权级为 M ⇒ 成功；
            // 否则（L=1 或 S/U）⇒ 仅当对应 R/W/X 位为 1 才成功。
            wire m_bypass = (!ent_l[gi]) && is_m_mode;
            wire perm_ok  = (need_r && c[`RV32GC_PMP_R_BIT]) ||
                            (need_w && c[`RV32GC_PMP_W_BIT]) ||
                            (need_x && c[`RV32GC_PMP_X_BIT]);
            assign ent_ok[gi] = ent_all[gi] && (m_bypass || perm_ok);
        end
    endgenerate

    //==========================================================================
    // 5. 优先级网络：从 0 号起递增扫描，首个「覆盖任一字节」的项锁定
    //    [norm:pmpentrypriority] 编号最低者决定成败
    //==========================================================================
    wire [PMP_ENTRIES-1:0] sel_onehot;
    wire [3:0]             sel_idx;

    // 5.1 计算每项的「之前均无命中」条件
    wire [PMP_ENTRIES-1:0] no_prior_hit;   // 第 i 位 = 项 0..i-1 全未命中
    assign no_prior_hit[0] = 1'b1;
    genvar gj;
    generate
        for (gj = 1; gj < PMP_ENTRIES; gj = gj + 1) begin : G_PRIO
            // no_prior_hit[i] = no_prior_hit[i-1] && !ent_any[i-1]
            assign no_prior_hit[gj] = no_prior_hit[gj-1] && !ent_any[gj-1];
        end
    endgenerate

    genvar gk;
    generate
        for (gk = 0; gk < PMP_ENTRIES; gk = gk + 1) begin : G_SEL
            assign sel_onehot[gk] = no_prior_hit[gk] && ent_any[gk];
        end
    endgenerate

    // 5.2 把 one-hot 编码成索引（组合或树；16 项 ⇒ 4 bit）
    //     纯 assign 表达，不用 always。
    assign sel_idx = { (|sel_onehot[15:8]),
                       (|sel_onehot[15:12]) | (|sel_onehot[11:8]),
                       (|sel_onehot[15:14]) | (|sel_onehot[13:12]) |
                       (|sel_onehot[11:10]) | (|sel_onehot[9:8]),
                       (sel_onehot[15] | sel_onehot[13] | sel_onehot[11] |
                        sel_onehot[9]  | sel_onehot[7]  | sel_onehot[5]  |
                        sel_onehot[3]  | sel_onehot[1]) };

    // 5.3 汇总：是否命中、被选中项是否整笔全覆盖、被选中项权限是否足够
    wire hit_any_flat = |sel_onehot;

    // 选中项的 ent_all / ent_ok（AND-OR 多路选择，纯 assign）
    wire sel_all = |(sel_onehot & {ent_all[15], ent_all[14], ent_all[13], ent_all[12],
                                   ent_all[11], ent_all[10], ent_all[9],  ent_all[8],
                                   ent_all[7],  ent_all[6],  ent_all[5],  ent_all[4],
                                   ent_all[3],  ent_all[2],  ent_all[1],  ent_all[0]});

    wire sel_ok  = |(sel_onehot & {ent_ok[15],  ent_ok[14],  ent_ok[13],  ent_ok[12],
                                   ent_ok[11],  ent_ok[10],  ent_ok[9],   ent_ok[8],
                                   ent_ok[7],   ent_ok[6],   ent_ok[5],   ent_ok[4],
                                   ent_ok[3],   ent_ok[2],   ent_ok[1],   ent_ok[0]});

    //==========================================================================
    // 6. 判定输出
    //==========================================================================
    // [norm:pmpnoentry_match]：无匹配 ⇒ M 成功、S/U 失败（本设计实现 16 项）。
    //   显式写成参数化表达式：若 PMP_ENTRIES==0 则任何特权级都成功。
    wire no_match_m_ok = is_m_mode || (PMP_ENTRIES == 0);

    assign allow_o = hit_any_flat ? sel_ok : no_match_m_ok;

    // 失败原因分类：
    //   · 有命中但整笔未全覆盖 ⇒ denied_by_full_o=1（权益与 R/W/X 无关）
    //   · 有命中且全覆盖但权限不足 ⇒ denied_by_full_o=0
    //   · 无命中且 S/U ⇒ denied_by_full_o=0（no-match 语义）
    assign denied_by_full_o = hit_any_flat && !sel_all;

    assign hit_o     = hit_any_flat;
    assign hit_idx_o = sel_idx;

    // cause：仅在被拒时有效
    assign fault_cause_o = type_to_fault_cause(acc_type_i);

endmodule
