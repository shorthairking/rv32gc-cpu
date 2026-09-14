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
//  ★ 地址口径 —— **ISA 口径**（[norm:pmp_addr_encoding]，
//      riscv-isa-manual/src/priv/machine.adoc:3379-3383）：
//        「Each PMP address register encodes bits 33-2 of a 34-bit physical address
//          for RV32」⇒ **pmpaddr[i] = PA >> 2**，绝**不是**字节地址本身。
//      本模块内部一律在「**字地址**」空间比较（字地址 = PA[33:2]，位宽与 pmpaddr 相同）：
//        · 输入 acc_pa_i 是**字节物理地址**，换算成本笔覆盖的字区间
//          [PA>>2, (PA + bytes - 1)>>2]（与「比较时 pmpaddr<<2」严格等价：PMP 区域最小
//          4 B 且 4 B 对齐 ⇒ 「覆盖任一字节」⟺「覆盖任一字」，「覆盖全部字节」⟺「全部字」）。
//        · TOR 的上下界、NA4 的单元、NAPOT 的块基址/掩码全部在字地址空间表达
//          （TOR 的 y 与 pmpaddr 同尺度；NA4 = 1 个字；NAPOT 掩码 = 低 (n+1) 位）。
//
//  G=0 粒度（08 §6.5 用户裁决）—— `pmpaddr` 读写**不做低位掩码**（32 位全部有效；
//      G≥1 的「低位读作全 1/全 0」掩码见 machine.adoc:3519-3528，本设计 G=0 不适用）；
//      **NA4 可用**（A=10 覆盖 4 B = 1 个字）；NAPOT 块大小 = 2^(n+3) 字节，
//      n = `pmpaddr` 低位**连续 1** 的个数（n=0 ⇒ 8 B，低位模式 …yyy0；
//      全 1 ⇒ 覆盖最大块，见表 machine.adoc:3463-3493）。
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
//   addr_i[N*32-1:0]    : N 项 pmpaddr[31:0]（**ISA 口径**：PA[33:2]；G=0 ⇒ 32 位全部有效）
//   acc_pa_i[31:0]      : 本笔访问的**物理字节地址**（S 级 PA，PMP 检查在翻译之后；
//                         模块内部按 PA>>2 换算到字地址口径后与 pmpaddr 比较）
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
    input  wire [PMP_ENTRIES*32-1:0] addr_i,        // 每项 32 bit pmpaddr（ISA 口径 = PA>>2）

    // ---- 本笔访问（单笔：拆笔由 lsu.v 负责） ----
    input  wire [ADDR_W-1:0]        acc_pa_i,       // 访问**字节**物理地址（翻译后的 S 级 PA）
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

    // ★ 地址换算尺度：pmpaddr = PA >> PMP_SHIFT（RV32 ⇒ 2，[norm:pmp_addr_encoding]）。
    //   本模块的全部匹配都在「字地址」（= PA[33:2]）空间进行，字地址位宽 = pmpaddr 位宽。
    localparam integer PMP_SHIFT = 2;

    // NAPOT 编码承载「连续 1」的位宽 = **整个 pmpaddr**（ISA 口径下 pmpaddr 的 32 位
    // 全部是 PA[33:2] 的位，低位不做掩码）：n 可达 32（全 1 ⇒ 覆盖整空间）。
    localparam integer NAPOT_FIELD_W = ADDR_W;   // 32

    localparam [1:0] PRIV_U  = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S  = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M  = `RV32GC_PRIV_M;

    //==========================================================================
    // 2. 纯组合辅助函数
    //==========================================================================
    // ---- 2.1 NAPOT 掩码解码（**字地址**空间） -------------------------------
    // 手册编码表（riscv-isa-manual machine.adoc:3463-3493，`NAPOT range encoding`；
    // 引子见 machine.adoc:3458-3462 [norm:pmp_napot_encoding_low_bits]）：
    //   pmpaddr 低位模式              匹配类型   覆盖大小
    //   yyyy...yyyy                    NA4        4   B
    //   yyyy...yyy0                    NAPOT      8   B
    //   yyyy...yy01                    NAPOT      16  B
    //   yyyy...y011                    NAPOT      32  B
    //   ...                            ...        ...
    //   yy01...1111                    NAPOT      2^(XLEN)   B
    //   y011...1111                    NAPOT      2^(XLEN+1) B
    //   0111...1111                    NAPOT      2^(XLEN+2) B
    //   1111...1111                    NAPOT      2^(XLEN+3) B
    //
    // ⇒ 决定大小的量是「从 bit0 起**连续 1** 的个数 n」（0 ≤ n ≤ ADDR_W）：
    //     n=0（…yyy0）⇒  8  B = 2^(0+3)
    //     n=1（…yy01）⇒ 16  B = 2^(1+3)
    //     n=2（…y011）⇒ 32  B = 2^(2+3)
    //     n=3（…0111）⇒ 64  B = 2^(3+3)
    //   即 **覆盖字节数 = 2^(n+3)**。换算到本模块的**字地址**空间（1 字 = 4 B）：
    //     覆盖字数 = 2^(n+3)/4 = 2^(n+1) ⇒ 块内字偏移位宽 = n+1，
    //     掩码 m = 低 (n+1) 位全 1，块基址 = pmpaddr & ~m，块顶 = pmpaddr | m。
    //   （自然对齐由编码保证：清掉编码位后基址自动对齐到块大小。）
    //
    //   ★ 关键易错点：**不能**去数尾随 0 个数（地址高位全 0 时会把整个空间算成一个块）。
    //     唯一正确的量是低位「连续 1」的个数；全 1 编码表示最大块。
    function integer napot_ones;
        input [ADDR_W-1:0] a;        // pmpaddr（字地址口径）
        integer k;                   // 低位连续 1 的个数
        begin
            k = 0;
            // 从最低位起数连续 1（NAPOT 编码的核心量）
            while ((k < NAPOT_FIELD_W) && (a[k] == 1'b1)) begin
                k = k + 1;
            end
            napot_ones = k;
        end
    endfunction

    // 返回「块内字地址掩码」（低 n+1 位全 1）。
    // n = ADDR_W-1（全 1 编码）⇒ n+1 = ADDR_W ⇒ 掩码全 1（块取最大，覆盖整个地址空间）；
    // 移位需防越界。
    function [ADDR_W-1:0] napot_wordmask;
        input [ADDR_W-1:0] a;
        integer n;
        begin
            n = napot_ones(a);
            if ((n + 1) >= ADDR_W) begin
                napot_wordmask = {ADDR_W{1'b1}};
            end else begin
                napot_wordmask = ({{(ADDR_W-1){1'b0}}, 1'b1} << (n + 1)) - 1'b1;
            end
        end
    endfunction

    // ---- 2.2 单笔访问命中判定（**字地址**区间，含端点） ----------------------
    // 返回 1 表示本笔访问的字区间与项覆盖的字区间有交集。整笔匹配用 all
    // （规范强制 [norm:pmp_full_match_required]，machine.adoc:3577-3582），
    // 选项用 any（规范强制 [norm:pmp_entry_priority]，machine.adoc:3575-3577）。
    // 说明：区间求交 ⟺ 区间长度非负下的 `lo<=base_h && hi>=base_l`；
    //       项区间为空（TOR 的 pmpaddr[i-1] >= pmpaddr[i]）由上层 ent_valid 门控。
    function hit_any_word;
        input [ADDR_W-1:0] lo;      // 本笔首字（含）
        input [ADDR_W-1:0] hi;      // 本笔末字（含，= (PA + bytes - 1)>>2）
        input [ADDR_W-1:0] base_l;  // 项覆盖起点（含）
        input [ADDR_W-1:0] base_h;  // 项覆盖终点（含）
        begin
            hit_any_word = (lo <= base_h) && (hi >= base_l);
        end
    endfunction

    function hit_all_word;
        input [ADDR_W-1:0] lo;
        input [ADDR_W-1:0] hi;
        input [ADDR_W-1:0] base_l;
        input [ADDR_W-1:0] base_h;
        begin
            hit_all_word = (lo >= base_l) && (hi <= base_h);
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
    // 3. 本笔访问的**字地址**区间（含端点）—— ISA 口径：字地址 = PA[33:2] = PA>>2
    //==========================================================================
    // 输入 acc_pa_i 是**字节**物理地址；末字节 = PA + bytes - 1。
    // 注意：末字节用零扩展加法，溢出（跨 4 GB）在 RV32 物理地址空间不存在；
    // 显式加宽 1 位再移位，避免综合工具误判位宽。
    // 与「把 pmpaddr<<2 还原成字节地址再比较」等价：PMP 区域最小 4 B 且 4 B 对齐，
    // 故「覆盖任一字节」⟺「覆盖任一字」、「覆盖全部字节」⟺「全部字」。
    wire [ADDR_W:0] acc_hi_x = {1'b0, acc_pa_i}
                             + {{(ADDR_W+1-BYTES_W){1'b0}}, acc_bytes_i} - 1'b1;
    wire [ADDR_W-1:0] acc_lo = {{PMP_SHIFT{1'b0}}, acc_pa_i[ADDR_W-1:PMP_SHIFT]};
    wire [ADDR_W-1:0] acc_hi = {{PMP_SHIFT{1'b0}}, acc_hi_x[ADDR_W-1:PMP_SHIFT]};

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

            // ---- 各项覆盖区间（**字地址**单位；1 字 = 4 B） ----
            // A=OFF   ：无覆盖（ent_valid=0）
            // A=TOR   ：y ∈ [pmpaddr[i-1], pmpaddr[i]) —— 上界**不含**
            //           （[norm:pmp_a_field_tor]，machine.adoc:3496-3500）；i=0 时下界 0。
            //           pmpaddr[i-1] >= pmpaddr[i] ⇒ 该匹配**无任何地址**（machine.adoc:3504
            //           NOTE）⇒ ent_valid=0（同时挡掉 a=0 时 (a-1) 回绕的伪区间）。
            // A=NA4   ：y == pmpaddr[i]（1 个字 = 4 B；G=0 ⇒ 可选，machine.adoc:3522）
            // A=NAPOT ：y ∈ [a & ~m, a | m]，m = napot_wordmask(a)
            //           （块基址/块顶在字地址空间，等价于字节口径下 pmpaddr<<2 的还原）
            wire [ADDR_W-1:0] napot_msk  = napot_wordmask(a);
            wire [ADDR_W-1:0] napot_base = a & ~napot_msk;
            wire [ADDR_W-1:0] napot_top  = napot_base | napot_msk;

            wire ent_is_off   = (ent_a[gi] == A_OFF);
            wire ent_is_tor   = (ent_a[gi] == A_TOR);
            wire tor_nonempty = (a_prev < a);          // pmpaddr[i-1] < pmpaddr[i]
            wire ent_valid    = !ent_is_off && (!ent_is_tor || tor_nonempty);

            assign ent_low[gi] =
                ent_is_tor              ? a_prev :
                (ent_a[gi] == A_NAPOT)  ? napot_base :
                                          a;        // NA4 / OFF（OFF 由 ent_valid 门控）

            assign ent_high[gi] =
                ent_is_tor              ? (a - 1'b1) :   // 上界不含 ⇒ 含端点式取 a-1
                (ent_a[gi] == A_NAPOT)  ? napot_top :
                                          a;

            // ---- 覆盖判定 ----
            // ent_any：命中该笔的**任一字节/字**（规范用于**选**项 [norm:pmp_entry_priority]）
            // ent_all：覆盖该笔的**全部字节/字**（规范用于**判**权，整笔匹配强制
            //          [norm:pmp_full_match_required]）
            assign ent_any[gi] = ent_valid &&
                                 hit_any_word(acc_lo, acc_hi, ent_low[gi], ent_high[gi]);
            assign ent_all[gi] = ent_valid &&
                                 hit_all_word(acc_lo, acc_hi, ent_low[gi], ent_high[gi]);

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
    //     编码口径（已穷举 16 个 one-hot 逐个验证）：
    //       idx[k] = 存在任一 sel_onehot[i] 且 (i>>k)&1 == 1
    //       idx[3] set = {8..15}
    //       idx[2] set = {4,5,6,7, 12,13,14,15}
    //       idx[1] set = {2,3, 6,7, 10,11, 14,15}
    //       idx[0] set = {1,3,5,7,9,11,13,15}
    //     ★ 易错点：必须按「(i>>k)&1」的**完整集合**写；凭直觉按 4 项分组会把
    //       高半部误排除（本文件首版即因此把 idx=4 误算为 0，已修正并穷举验证）。
    assign sel_idx = {
        (sel_onehot[15] | sel_onehot[14] | sel_onehot[13] | sel_onehot[12] |
         sel_onehot[11] | sel_onehot[10] | sel_onehot[9]  | sel_onehot[8]),   // idx[3]
        (sel_onehot[15] | sel_onehot[14] | sel_onehot[13] | sel_onehot[12] |
         sel_onehot[7]  | sel_onehot[6]  | sel_onehot[5]  | sel_onehot[4]),   // idx[2]
        (sel_onehot[15] | sel_onehot[14] | sel_onehot[11] | sel_onehot[10] |
         sel_onehot[7]  | sel_onehot[6]  | sel_onehot[3]  | sel_onehot[2]),   // idx[1]
        (sel_onehot[15] | sel_onehot[13] | sel_onehot[11] | sel_onehot[9]  |
         sel_onehot[7]  | sel_onehot[5]  | sel_onehot[3]  | sel_onehot[1])    // idx[0]
    };

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
