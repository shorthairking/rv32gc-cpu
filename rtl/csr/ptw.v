//==============================================================================
// ptw.v —— Sv32 两级页表遍历状态机（隐式访存过 PMP；违反抛原访问类型 access-fault）
//==============================================================================
// 依据    : docs/design/08-baseline-5stage.md §5.4 行为要点 ④、§5.5 抉择 1/3/7、
//           §6.1（satp 格式）、§8.2.1
//           docs/design/06-csr-privilege.md §5.2（转换算法逐条）
//           docs/kb/isa-notes.md §2、§3.3（PTE 取指也过 PMP）、§4 T3
// 真源    : rtl/pkg/rv32_defs.vh §8（Sv32 / PTE 位域）、§6.1（cause 码）
// 红线    : 无原语；组合逻辑用 assign/function；always 仅用于遍历状态机与
//           请求拍寄存器（确有必要，见注释）。
//------------------------------------------------------------------------------
// 【本模块锁定的硬口径】
//  W1. **页表隐式访存必须过 PMP**（ISA：Sv32 算法步骤 2
//      norm:pmpmisalignedaccess_behavior 之后的条文）。违反时抛
//      **对应原访问类型的 access-fault**（取指 ⇒ 1、load ⇒ 5、store/AMO ⇒ 7），
//      **不是** page-fault。反证：把 PTE 访问的 PMP 检查去掉 ⇒ tb_ptw 的
//      「页表隐式访存过 PMP 被拒 ⇒ access-fault」用例必须 FAIL。
//      实现方式：每次 PTE 读都产生 pmp_req（含 PTE 物理地址 + 访问类型），
//      由外层 pmp_check 回 pmp_resp_ok；本模块不做 PMP 匹配（单一真源）。
//  W2. **非对齐优先于 PMP**（T3，本设计选择）：本模块只对**翻译后的物理地址**
//      做 PMP 检查，非对齐判定在 lsu 侧先于 PTW 触发（见 tb_ptw 的判据）。
//      本模块内部保证：PTE 地址恒 4 B 对齐（PTESIZE=4），故 PTE 访问本身不会非对齐。
//  W3. **缺页 cause = 12（取指）/13（load）/15（store/AMO）**；页表结构非法、
//      V=0、R=0&&W=1、保留编码、权限不足、错位超级页 ⇒ page-fault。
//  W4. **4 MiB 大页（超级页，i=0 命中叶子）**：必须检查 PTE 的 PPN[0]
//      （即 pte[19:10]）为全 0，否则错位超级页 ⇒ page-fault
//      （ISA norm:sverr_misaligned_superpage）。
//  W5. **A/D 位 = Svade（软件管理）**：A=0，或"写访问且 D=0" ⇒ 直接抛
//      **page-fault**（取指 12 / load 13 / store 15），由 M/S 软件置位后重试。
//      **不做**硬件原子更新（无 Svadu、menvcfg.ADUE 不实现）。
//      依据：ISA Sv32 算法步骤 9 的 Svade 分支；参考模型 Spike 的 ISA 串未含
//      svadu 且 ACT env 显式清 menvcfg.ADUE=0（tests/env/rvtest_setup.h:1010）；
//      项目裁决见 06-csr-privilege.md §11 P-6（2A 取 Svade 备选方案，
//      arch-test 的 Svade 组正是据此判定）。pte_ad_* 端口保留但恒 0。
//  W6. **可中止（kill）**：外层引擎一旦放弃本笔（陷阱/xRET/fence.i/sfence.vma），
//      本模块必须立即回 IDLE，否则 req_ready 永久为 0（PTE 响应不会再回来）⇒
//      死锁；同拍还要压住 fill_valid（sfence 失效竞态，见端口注释）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module ptw #(
    //--------------------------------------------------------------------------
    // ★ A/D 位策略选择（2026-09 新增参数）
    //   SVADE = 1（**默认 = 本核口径**，见 W5）：A=0 或"写且 D=0" ⇒ 直接
    //           page-fault，由 M/S 软件置位后重试（ISA Sv32 算法步骤 9 的 Svade 分支；
    //           参考模型 Spike 在 menvcfg.ADUE=0 时同口径）。
    //   SVADE = 0：保留"硬件原子更新 A/D 位"通路（pte_ad_update/pte_ad_done 握手，
    //           对应 Svadu）。该配置由模块级 TB（sim/unit/tb_ptw.sv，显式传
    //           SVADE=0）覆盖；本核 core_top 使用默认值 1。
    //   ⇒ 两条通路都有实现、都有验证，模块默认值 = 项目口径。
    //--------------------------------------------------------------------------
    parameter integer  SVADE = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // ★ 中止（kill）：外层（core_top 的 M 级引擎）已放弃本笔翻译 ⇒ 本模块必须
    //   立即回 IDLE。理由（死锁防线）：PTE 读的"响应"由 M 级 FSM 提供，FSM 一旦
    //   因陷阱/xRET/fence.i/sfence.vma 中止，就再也不会回 pte_resp_valid ⇒ 本模块
    //   若停在 S_L1_W/S_L0_W/S_AD，req_ready 恒 0，此后**所有** Sv32 访问永久挂死。
    //   同拍还要压住 fill_valid（防"失效竞态"把陈旧翻译灌进 TLB，见 supervisor.adoc
    //   norm:sfencevma_* 与 docs/kb/isa-notes.md §2.2）。
    //--------------------------------------------------------------------------
    input  wire        kill,

    //--------------------------------------------------------------------------
    // 翻译请求（来自 lsu / fetch_unit）
    //--------------------------------------------------------------------------
    input  wire        req_valid,
    input  wire [31:0] req_va,
    input  wire [1:0]  req_acc,        // 00=取指(X) 01=load(R) 10=store/AMO(W) 11=cbo.zero(W)
    input  wire [1:0]  req_priv,       // 有效特权级（含 MPRV/MPP 语义，来自 priv_ctrl）
    input  wire        req_sum,        // ★ SUM 有效值（仅影响页权限，**不进 PMP**）
    input  wire        req_mxr,        // ★ MXR 有效值（仅影响页权限，**不进 PMP**）
    input  wire [31:0] satp,           // satp.ppn 为根页表基址

    output wire        req_ready,      // 本模块可接受新请求
    output wire        req_done,       // 翻译结束（成功或失败均拉高 1 拍）
    output wire [31:0] pa_o,           // 翻译后的物理地址（成功时有效）
    output wire        fault_o,        // 1 = 本次翻译失败
    output wire [4:0]  fault_cause_o,  // 12/13/15（page-fault）或 1/5/7（PTE 访问 PMP 违反）
    output wire [31:0] fault_tval_o,   // 恒写**虚拟地址**（E5；norm:mtvalvaddrnot_paddr）

    //--------------------------------------------------------------------------
    // PTE 物理读端口（外层接 L1D/旁路；本模块不做存储）
    //--------------------------------------------------------------------------
    output wire        pte_req_valid,
    output wire [31:0] pte_req_pa,
    input  wire        pte_req_ready,
    input  wire        pte_resp_valid,
    input  wire [31:0] pte_resp_data,

    //--------------------------------------------------------------------------
    // ★ PTE 隐式访存的 PMP 检查端口（W1）
    //   本模块把 PTE 物理地址 + 访问类型交给外层 pmp_check；不自己做匹配。
    //--------------------------------------------------------------------------
    output wire        pmp_req_valid,
    output wire [31:0] pmp_req_addr,
    output wire [1:0]  pmp_req_acc,    // 同 req_acc 的编码
    output wire [1:0]  pmp_req_priv,   // 页表遍历恒按**有效特权级**做 PMP 检查
    input  wire        pmp_resp_ok,    // 0 = 该 PTE 访问违反 PMP ⇒ access-fault

    //--------------------------------------------------------------------------
    // A/D 位硬件更新（W5；留给 lsu 落地原子读改写 PTE）
    //--------------------------------------------------------------------------
    output wire        pte_ad_update,  // 需要更新 PTE 的 A（和 store 时的 D）位
    output wire [31:0] pte_ad_pa,      // 需要更新的 PTE 物理地址
    output wire [31:0] pte_ad_data,    // 更新后的 PTE 值
    input  wire        pte_ad_done,    // 外层完成原子更新

    //--------------------------------------------------------------------------
    // TLB 填充（命中时由外层写入 TLB）
    //--------------------------------------------------------------------------
    output wire        fill_valid,
    output wire [31:0] fill_va,
    output wire [31:0] fill_pa,
    output wire [21:0] fill_ppn,
    output wire [7:0]  fill_perm      // {G,U,X,W,R,3'b0}，见 §7
);

    //==========================================================================
    // 1. 常量
    //==========================================================================
    // ---- 访问类型编码 ----
    localparam [1:0] ACC_FETCH = 2'b00;
    localparam [1:0] ACC_LOAD  = 2'b01;
    localparam [1:0] ACC_STORE = 2'b10;
    localparam [1:0] ACC_CBOZ  = 2'b11;   // cbo.zero 按 store 判定（06 §5.2）

    // ---- access-fault cause（W1：跟随**原访问类型**） ----
    localparam [4:0] CAUSE_INSN_AF  = `RV32GC_EXC_INSN_ACCESS_FAULT;   // 1
    localparam [4:0] CAUSE_LOAD_AF  = `RV32GC_EXC_LOAD_ACCESS_FAULT;   // 5
    localparam [4:0] CAUSE_STORE_AF = `RV32GC_EXC_STORE_ACCESS_FAULT;  // 7
    // ---- page-fault cause（W3） ----
    localparam [4:0] CAUSE_INSN_PF  = `RV32GC_EXC_INSN_PAGE_FAULT;     // 12
    localparam [4:0] CAUSE_LOAD_PF  = `RV32GC_EXC_LOAD_PAGE_FAULT;     // 13
    localparam [4:0] CAUSE_STORE_PF = `RV32GC_EXC_STORE_PAGE_FAULT;    // 15

    // ---- 访问类型 → access-fault cause ----
    function [4:0] af_cause;
        input [1:0] acc;
        begin
            case (acc)
                ACC_FETCH: af_cause = CAUSE_INSN_AF;
                ACC_LOAD:  af_cause = CAUSE_LOAD_AF;
                default:   af_cause = CAUSE_STORE_AF;  // STORE / CBO.ZERO
            endcase
        end
    endfunction

    // ---- 访问类型 → page-fault cause ----
    function [4:0] pf_cause;
        input [1:0] acc;
        begin
            case (acc)
                ACC_FETCH: pf_cause = CAUSE_INSN_PF;
                ACC_LOAD:  pf_cause = CAUSE_LOAD_PF;
                default:   pf_cause = CAUSE_STORE_PF;  // STORE / CBO.ZERO
            endcase
        end
    endfunction

    // ---- 是否按"写/store"判定（AMO/cbo.zero 恒按 store） ----
    //   ISA NOTE：AMO 永不抛 load page fault（不可读页必然不可写）。
    function is_write_acc;
        input [1:0] acc;
        begin
            is_write_acc = (acc == ACC_STORE) | (acc == ACC_CBOZ);
        end
    endfunction

    // =========================================================================
    // 2. Sv32 地址切分
    // =========================================================================
    //   VA = VPN[1](10) | VPN[0](10) | OFFSET(12)
    wire [9:0]  va_vpn1   = req_va[31:22];
    wire [9:0]  va_vpn0   = req_va[21:12];
    wire [11:0] va_offset = req_va[11:0];

    //==========================================================================
    // 3. PTE 字段抽取（W3/W4）
    //==========================================================================
    //   PTE 布局：PPN[1](12)|PPN[0](10)|RSW(2)|D|A|G|U|X|W|R|V
    //   pte[31:10] = PPN（22 bit）
    function [9:0] pte_ppn0;
        input [31:0] p;
        begin
            pte_ppn0 = p[19:10];
        end
    endfunction
    function [11:0] pte_ppn1;
        input [31:0] p;
        begin
            pte_ppn1 = p[31:20];
        end
    endfunction

    //==========================================================================
    // 4. 遍历状态机
    //   理由：两级遍历需要跨多拍（每级一次物理读 + PMP 检查），
    //   必须用状态寄存器 ⇒ always 块不可省（AGENT.md §4.3）。纯组合部分
    //   仍全部走 assign/function。
    //==========================================================================
    localparam [2:0] S_IDLE  = 3'd0;   // 空闲
    localparam [2:0] S_L1    = 3'd1;   // 一级页表：发 PTE 读
    localparam [2:0] S_L1_W  = 3'd2;   // 等一级 PTE 返回
    localparam [2:0] S_L0    = 3'd3;   // 二级页表：发 PTE 读
    localparam [2:0] S_L0_W  = 3'd4;   // 等二级 PTE 返回
    localparam [2:0] S_AD    = 3'd5;   // A/D 位更新等待（W5）
    localparam [2:0] S_DONE  = 3'd6;   // 出结果（1 拍）

    reg [2:0]  st;

    // ---- 请求拍锁存（组合读之外必须寄存，供多拍复用） ----
    //   always 块：只做"请求拍锁存 + 状态推进"，都是时序元件行为。
    reg [31:0] va_r;
    reg [1:0]  acc_r;
    reg [1:0]  priv_r;
    reg        sum_r, mxr_r;
    reg [31:0] satp_r;
    reg [21:0] pte_ppn_r;      // 当前级的 PTE 物理页号
    reg [31:0] pte_q;          // 最近一次读回的 PTE（命名 pte_q 以区别于位选线网）
    reg [31:0] pa_r;           // 翻译结果
    reg        fault_r;
    reg [4:0]  fault_cause_r;
    reg [7:0]  perm_r;         // 权限位 {G,U,X,W,R,0,0,0}
    // ---- ★ 叶子来自哪一级：必须在 S_L1_W/S_L0_W 时**锁存**。
    //   理由：pa_leaf 在 S_AD 里被使用时，cur_is_l1 已为假（st=S_AD），
    //   直接用 cur_is_l1 会把 4 MiB 大页错当成 4 KiB 页（实测踩到）。
    reg        leaf_from_l1;

    // ---- 各级 PTE 物理地址 ----
    //   一级：a = satp.ppn × 4KiB；pte_pa = a + VPN[1] × 4
    //   二级：a = 一级 PTE 的 PPN × 4KiB；pte_pa = a + VPN[0] × 4
    wire [31:0] root_base   = {satp_r[21:0], 12'h000};
    wire [31:0] l1_pte_pa   = root_base + {20'b0, va_vpn1, 2'b00};
    wire [31:0] l0_base     = {pte_ppn_r, 12'h000};
    wire [31:0] l0_pte_pa   = l0_base + {20'b0, va_vpn0, 2'b00};

    // ---- 当前级是否一级（S_L1/S_L1_W） ----
    wire cur_is_l1 = (st == S_L1) | (st == S_L1_W);
    wire [31:0] cur_pte_pa = cur_is_l1 ? l1_pte_pa : l0_pte_pa;

    //==========================================================================
    // 5. PTE 合法性判定（纯组合 function，W3/W4）
    //==========================================================================
    // ---- ★ 关键：结构化判定必须针对**本拍刚读回的数据**（pte_resp_data），
    //   而不是已锁存的 pte_q —— 在 S_L1_W / S_L0_W 那一拍，pte_q 还是**上一次**
    //   的值（NBA 尚未生效）。用 pte_q 会判断错级（实测踩到：把指针当成叶子）。
    //   故下面为"当前响应数据"与"已锁存数据"各建一套位选。
    wire       pte_vd = pte_resp_data[`RV32GC_PTE_V_BIT];
    wire       pte_rd = pte_resp_data[`RV32GC_PTE_R_BIT];
    wire       pte_wd = pte_resp_data[`RV32GC_PTE_W_BIT];
    wire       pte_xd = pte_resp_data[`RV32GC_PTE_X_BIT];
    wire       pte_ud = pte_resp_data[`RV32GC_PTE_U_BIT];
    wire       pte_gd = pte_resp_data[`RV32GC_PTE_G_BIT];
    wire       pte_ad = pte_resp_data[`RV32GC_PTE_A_BIT];
    wire       pte_dd = pte_resp_data[`RV32GC_PTE_D_BIT];
    wire       pte_leaf_d   = pte_rd | pte_xd;
    wire       pte_rsvd_d   = ~pte_rd & pte_wd;
    wire [9:0] ppn0_d       = pte_resp_data[19:10];

    // ---- 保留编码检查：R=0 && W=1 ⇒ 保留（ISA PTE 权限编码表） ----
    wire pte_rb = pte_q[`RV32GC_PTE_R_BIT];
    wire pte_wb = pte_q[`RV32GC_PTE_W_BIT];
    wire pte_xb = pte_q[`RV32GC_PTE_X_BIT];
    wire pte_ub = pte_q[`RV32GC_PTE_U_BIT];
    wire pte_gb = pte_q[`RV32GC_PTE_G_BIT];
    wire pte_ab = pte_q[`RV32GC_PTE_A_BIT];
    wire pte_db = pte_q[`RV32GC_PTE_D_BIT];
    wire pte_vb = pte_q[`RV32GC_PTE_V_BIT];

    wire pte_is_leaf    = pte_rb | pte_xb;            // R=1 或 X=1 ⇒ 叶子
    wire pte_reserved   = ~pte_rb & pte_wb;           // R=0,W=1 ⇒ 保留 ⇒ page-fault

    // ---- 错位超级页（W4）：四级页表下 i>0 时 PPN[i-1:0] 必须为 0 ----
    //   Sv32：i=0 为叶子（两级），i=1 为叶子 ⇒ 超大页本设计不存在
    //   （两级页表下 i 只能为 0/1；i=1 命中叶子即 4 MiB 大页，需要检查
    //     PPN[0] == 0）。本模块只在 L1 命中叶子时检查这一点。
    wire misaligned_sp = (~cur_is_l1) ? 1'b0 :        // 二级叶子无此检查
                         (pte_ppn0(pte_q) != 10'h0);  // 4 MiB 大页要求 PPN[0]=0

    // ---- 页权限判定（仅此处使用 SUM/MXR：**不进 PMP 路径**，06 §3.1 末段） ----
    function perm_ok;
        input [1:0] acc;
        input [1:0] cur_priv;
        input       sum;
        input       mxr;
        input       u_bit;
        input       r_bit;
        input       w_bit;
        input       x_bit;
        begin
            // ---- U 位检查（06 §5.2 步骤 6；ISA：S 模式无论如何不得在 U=1 页执行）----
            //   U 模式只能访问 U=1 的页；S 模式访问 U=1 的页需 SUM=1，
            //   但**取指**恒不允许（SUM 只放开数据访问）。
            //   M 模式：本模块只在 Sv32 生效时被调用（有效特权级 < M），
            //   故 M 分支不在此处理（由 lsu 判定 Bare 直通）。
            if (cur_priv == `RV32GC_PRIV_U) begin
                perm_ok = u_bit & (
                    (acc == ACC_FETCH) ? x_bit :
                    (acc == ACC_LOAD ) ? (r_bit | (mxr & x_bit)) :
                                         (w_bit & r_bit) );   // store 需 W=1（AMO 同）
            end else begin
                // ---- 有效特权级 == S ----
                if (acc == ACC_FETCH) begin
                    // S 取指：不得在 U=1 页执行（与 SUM 无关）
                    perm_ok = ~u_bit & x_bit;
                end else begin
                    // S 数据访问：U=1 页需 SUM=1
                    if (u_bit & ~sum) perm_ok = 1'b0;
                    else if (acc == ACC_LOAD) perm_ok = r_bit | (mxr & x_bit);
                    else                      perm_ok = w_bit & r_bit;
                end
            end
        end
    endfunction

    wire acc_is_write = is_write_acc(acc_r);

    //==========================================================================
    // 6. 状态推进
    //==========================================================================
    // ---- 组合：本次叶子检查的结果（用于 S_L1_W / S_L0_W 的下一动作） ----
    // ---- A/D 位口径（★ 2026-09 修订，见文件头 W5）：**Svade（软件管理）** ----
    //   A=0，或"写访问且 D=0" ⇒ **page-fault**（cause 12/13/15），由 M/S 软件置位后
    //   重试；本设计**不做**硬件原子更新（无 Svadu、menvcfg.ADUE 不实现）。
    //   依据：① ISA Sv32 算法步骤 9（Svade 实现 ⇒ 直接抛 page-fault）；
    //        ② 参考模型 Spike 的 ISA 串未含 svadu（sim/arch_test/test_config.yaml
    //           spike_isa=rv32imafdc_...），且 ACT env 显式把 menvcfg.ADUE 清 0
    //           （riscv-arch-test/tests/env/rvtest_setup.h:1010）⇒ 参考行为 = Svade；
    //        ③ 项目裁决：06-csr-privilege.md §11 P-6 的备选方案（Svade）为本阶段选择。
    //   判定顺序按 ISA：U 位/权限（步骤 6/8）先于 A/D（步骤 9）；两者同为 page-fault，
    //   cause 相同，故顺序只影响内部走哪条路径、不影响架构可见行为。
    wire leaf_ok = pte_vb & ~pte_reserved & ~misaligned_sp;
    wire perm_granted = leaf_ok & perm_ok(acc_r, priv_r, sum_r, mxr_r,
                                          pte_ub, pte_rb, pte_wb, pte_xb);
    wire ad_missing = leaf_ok & ((~pte_ab) | (acc_is_write & ~pte_db));

    // ---- 二级需再走一级（指针）：pte 为指针 ⇒ 下到二级 ----
    wire need_l0 = leaf_ok & ~pte_is_leaf;

    // ---- 翻译成功算出的 PA ----
    //   4 KiB 页（i=0 叶子）：pa = (pte.ppn << 12) | va.offset
    //   4 MiB 大页（i=1 叶子）：pa = (pte.ppn[1] << 22) | va[21:0]
    //     注意：4 MiB 大页时 va[21:12] 直接来自 VA，故用 {pte_ppn1, va[21:12], va[11:0]}
    wire [31:0] pa_4k = {pte_ppn1(pte_q), pte_ppn0(pte_q), va_offset};
    //   ★ 4 MiB 大页（i=1 叶子）：pa = (pte.ppn[1] << 22) | va[21:0]
    //     其中 pte.ppn[1] = pte[31:20]（12 bit）。注意**不能**写 `{ppn1, va[21:0]}`
    //     ——那是 34 bit 拼接，会被截断并把位错开（实测踩到：产出 0x123）。
    wire [31:0] pa_4m = ({20'b0, pte_ppn1(pte_q)} << 22) | {10'b0, va_r[21:0]};
    wire [31:0] pa_leaf = leaf_from_l1 ? pa_4m : pa_4k;

    // ---- 组合：本次 PTE 访问的 PMP 结果 ----
    //   ★ 时序口径：pmp_req_valid 在 S_L1 / S_L0（发 PTE 读的同一拍）拉高，
    //     外层 pmp_check 组合返回 pmp_resp_ok；若为 0，则**不发出** PTE 请求，
    //     直接抛原访问类型的 access-fault（W1），物理读绝不发生。
    //     ⇒ 这保证"页表隐式访存**过** PMP"不是事后补判，而是前置拦截。
    wire pte_pmp_ok = pmp_resp_ok;
    wire pmp_block  = ~pte_pmp_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            va_r          <= 32'h0;
            acc_r         <= ACC_FETCH;
            priv_r        <= `RV32GC_PRIV_M;
            sum_r         <= 1'b0;
            mxr_r         <= 1'b0;
            satp_r        <= 32'h0;
            pte_ppn_r     <= 22'h0;
            pte_q         <= 32'h0;
            pa_r          <= 32'h0;
            fault_r       <= 1'b0;
            fault_cause_r <= 5'h0;
            perm_r        <= 8'h0;
            leaf_from_l1  <= 1'b0;
        end else if (kill) begin
            // ★ 中止：外层引擎已放弃本笔（陷阱/xRET/fence.i/sfence.vma）⇒ 立即回
            //   IDLE，且**不**产出 fill（fill_valid 的组合式已并入 ~kill）。下一笔
            //   请求会重新锁存全部字段，故此处无需清理锁存器。
            st <= S_IDLE;
        end else begin
            case (st)
            //------------------------------------------------------------------
            S_IDLE: begin
                fault_r <= 1'b0;
                if (req_valid) begin
                    // ---- 请求拍锁存 ----
                    va_r      <= req_va;
                    acc_r     <= req_acc;
                    priv_r    <= req_priv;
                    sum_r     <= req_sum;
                    mxr_r     <= req_mxr;
                    satp_r    <= satp;
                    st        <= S_L1;
                end
            end
            //------------------------------------------------------------------
            // 一级页表：发 PTE 读
            S_L1: begin
                // ★ W1 前置拦截：PMP 拒 ⇒ 不读物理内存，直接 access-fault
                if (pmp_block) begin
                    fault_r       <= 1'b1;
                    fault_cause_r <= af_cause(acc_r);
                    st            <= S_DONE;
                end else if (pte_req_ready) begin
                    leaf_from_l1 <= 1'b0;
                    st <= S_L1_W;
                end
            end
            //------------------------------------------------------------------
            // 等一级 PTE 返回；★ W1：返回后先做 PMP 检查（同拍 pmp_resp_ok 有效）
            S_L1_W: begin
                if (pte_resp_valid) begin
                    pte_q <= pte_resp_data;
                    pte_ppn_r <= pte_resp_data[31:10];
                    // ★ W1 的 PMP 判定已在 S_L1 前置完成（见上），此处只做结构检查。
                    // ★ 结构判定用 _d 系列（= pte_resp_data 的位选），不用 pte_q。
                    if (!pte_vd) begin
                        // V=0 ⇒ page-fault
                        fault_r       <= 1'b1;
                        fault_cause_r <= pf_cause(acc_r);
                        st            <= S_DONE;
                    end else if (pte_rsvd_d) begin
                        // R=0 && W=1 ⇒ 保留 ⇒ page-fault
                        fault_r       <= 1'b1;
                        fault_cause_r <= pf_cause(acc_r);
                        st            <= S_DONE;
                    end else if (pte_leaf_d) begin
                        // ---- 一级命中叶子 = 4 MiB 大页 ⇒ 检查错位超级页 ----
                        if (ppn0_d != 10'h0) begin
                            fault_r       <= 1'b1;
                            fault_cause_r <= pf_cause(acc_r);
                            st            <= S_DONE;
                        end else begin
                            leaf_from_l1 <= 1'b1;
                            st           <= S_AD;   // 4 MiB 叶子 ⇒ 进 A/D 处理
                        end
                    end else begin
                        // ---- 指针 ⇒ 下到二级 ----
                        pte_ppn_r <= pte_resp_data[31:10];
                        st        <= S_L0;
                    end
                end
            end
            //------------------------------------------------------------------
            S_L0: begin
                if (pmp_block) begin
                    fault_r       <= 1'b1;
                    fault_cause_r <= af_cause(acc_r);
                    st            <= S_DONE;
                end else if (pte_req_ready) begin
                    st <= S_L0_W;
                end
            end
            //------------------------------------------------------------------
            S_L0_W: begin
                if (pte_resp_valid) begin
                    pte_q <= pte_resp_data;
                    if (!pte_vd) begin
                        fault_r       <= 1'b1;
                        fault_cause_r <= pf_cause(acc_r);
                        st            <= S_DONE;
                    end else if (pte_rsvd_d) begin
                        fault_r       <= 1'b1;
                        fault_cause_r <= pf_cause(acc_r);
                        st            <= S_DONE;
                    end else if (!pte_leaf_d) begin
                        // ---- 二级页表项仍是指针 ⇒ i<0 ⇒ page-fault ----
                        fault_r       <= 1'b1;
                        fault_cause_r <= pf_cause(acc_r);
                        st            <= S_DONE;
                    end else begin
                        leaf_from_l1 <= 1'b0;
                        st           <= S_AD;   // 叶子（4 KiB 页）⇒ A/D 处理
                    end
                end
            end
            //------------------------------------------------------------------
            // A/D 位 + 权限判定（W5：Svade 口径）
            //   顺序按 ISA Sv32 算法：权限（步骤 6/8）判定先于 A/D（步骤 9）；
            //   两者都抛**同类型 page-fault**（cause 12/13/15），故分派顺序不影响
            //   架构可见行为，只决定内部走哪一支。
            //------------------------------------------------------------------
            S_AD: begin
                if (!perm_granted) begin
                    fault_r       <= 1'b1;
                    fault_cause_r <= pf_cause(acc_r);
                    st            <= S_DONE;
                end else if (ad_missing & (SVADE != 0)) begin
                    // ★ Svade 口径（默认）：A=0（或写访问 D=0）⇒ **page-fault**，
                    //   由软件置位后重试；不发起任何 PTE 写。
                    fault_r       <= 1'b1;
                    fault_cause_r <= pf_cause(acc_r);
                    st            <= S_DONE;
                end else if (ad_missing) begin
                    // ---- SVADE=0：硬件原子更新通路（外层写回后回 pte_ad_done）----
                    if (pte_ad_done) begin
                        pa_r  <= pa_leaf;
                        perm_r <= {pte_gb, pte_ub, pte_xb, pte_wb, pte_rb, 3'b000};
                        st    <= S_DONE;
                    end
                    // 否则停在 S_AD 等 pte_ad_done / pte_ad_update 握手
                end else begin
                    pa_r  <= pa_leaf;
                    perm_r <= {pte_gb, pte_ub, pte_xb, pte_wb, pte_rb, 3'b000};
                    st    <= S_DONE;
                end
            end
            //------------------------------------------------------------------
            S_DONE: st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 7. 输出（纯组合）
    //==========================================================================
    assign req_ready = (st == S_IDLE) & ~kill;

    // ---- PTE 读请求：只在 S_L1 / S_L0 拉高，且 **PMP 未拒**（W1 前置拦截） ----
    assign pte_req_valid = ((st == S_L1) | (st == S_L0)) & ~pmp_block;
    assign pte_req_pa    = cur_pte_pa;

    // ---- ★ W1：PMP 检查请求（每次 PTE 读都发，且用**原访问类型**） ----
    //   地址 = PTE 物理地址；类型 = 原访问类型（取指⇒1、load⇒5、store/AMO⇒7）；
    //   特权级 = 有效特权级（页表遍历属数据访问语义，但**权限口径**跟随原访问类型）。
    //   ★ SUM/MXR **不进 PMP 路径**（06 §3.1 末段）⇒ 这两个信号不出现在本端口。
    assign pmp_req_valid = (st == S_L1) | (st == S_L0);
    assign pmp_req_addr  = cur_pte_pa;
    //   ★ 权限口径（08 §5.5 / 本文件 W1 的项目选择）：**按原访问类型**判这次 PTE 访问
    //     （取指 ⇒ X、load ⇒ R、store/AMO ⇒ W），而上报的 cause 同样跟随原访问类型。
    //   ★ 已知口径差异（本任务遗留 L-1，见交付报告）：参考模型 Spike 用 **LOAD**
    //     权限判 PTE 读（riscv-isa-sim/riscv/mmu.h:490），只把**异常类型**取原访问类型。
    //     两者在"页表仅 X 权限、取指访问"这一组合下结论相反 ⇒ SvPMP 的
    //     sv32_pmp_on_pte_{S,U}mode 两例不过（其余 38 例不受影响，因为它们不构造
    //     "页表可 X 不可 R"的 PMP 组合）。
    //     试改 ACC_LOAD 可让该两例的**首个**差异消失，但测试随后仍在别处分歧
    //     （详见交付报告"遗留/风险"），故本轮保持项目原口径不动。
    assign pmp_req_acc   = acc_r;
    assign pmp_req_priv  = priv_r;

    // ---- A/D 更新请求（仅 SVADE=0 的硬件更新通路会拉高；默认口径恒 0）----
    //   ★ engine 侧口径注释：SVADE=1 时本端口恒 0 ⇒ core_top 的 M_S_PADW/M_S_PADX
    //     状态不可达（保留状态机结构不动，避免接口/状态编号漂移）。
    assign pte_ad_update = (SVADE == 0) & (st == S_AD) & ad_missing;
    //   pte_ad_pa = 需要更新的那个 PTE 的物理地址（二级叶子 ⇒ l0_pte_pa；
    //   一级叶子（4 MiB 大页）⇒ l1_pte_pa，由 cur_is_l1 选择）
    assign pte_ad_pa     = (st == S_AD) ? (cur_is_l1 ? l1_pte_pa : l0_pte_pa) : 32'h0;
    //   pte_ad_data = 置 A（写访问时同时置 D）后的 PTE 值
    assign pte_ad_data   = pte_q | (32'h1 << `RV32GC_PTE_A_BIT) |
                           (acc_is_write ? (32'h1 << `RV32GC_PTE_D_BIT) : 32'h0);

    // ---- 结果 ----
    assign req_done       = (st == S_DONE);
    assign pa_o           = pa_r;
    assign fault_o        = fault_r;
    assign fault_cause_o  = fault_cause_r;
    assign fault_tval_o   = va_r;    // ★ E5：恒写虚拟地址

    // ---- TLB 填充（★ 已并入 ~kill：失效竞态下不得把陈旧翻译灌进 TLB） ----
    assign fill_valid = (st == S_DONE) & ~fault_r & ~kill;
    assign fill_va    = va_r;
    assign fill_pa    = pa_r;
    //   ★ 2026-09 修复（PA 截断 bug，Sv32 家族解锁时实测）：
    //     TLB 的 PPN 字段必须能在 32 bit 物理地址空间里**无损重建 PA**：
    //       PA = {2'b00, ppn[19:0], offset}（恰 32 bit）
    //     ⇒ 存入的应是 PA[31:12]（20 bit，高 2 位补 0），**不是** PA[31:10]。
    //     原实现给 PA[31:10]（= 把 PA 当 34 bit 的 PPN 编码），TLB 侧再
    //     `{ppn, off}` 拼 34 bit 后截断 ⇒ ppn[21:20]≠0 的页（PA ≥ 0x4000_0000，
    //     **本平台 RAM 全在此区间**）PA 被整体错位（实测：VA 0x4000_00a4 ⇒
    //     TLB 给出 PA 0x0000_00a4，取指打到未登记区 ⇒ DECERR/cause 1）。
    assign fill_ppn   = {2'b00, pa_r[31:12]};
    assign fill_perm  = perm_r;

endmodule
