//==============================================================================
// rtl/mem/lsu.v —— M 级访存顶层（地址生成 / 类型判定 / 异常优先级 / 分流）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 出处    : docs/design/08-baseline-5stage.md §5.4（M 级整表）、§5.5（十项抉择，
//           必须逐条落实）、§6.4（MPRV/SUM/MXR 同拍旁路）、§6.5（CMO/用户裁决）
//           docs/kb/isa-notes.md T1–T8、§3
// 唯一真源: rtl/pkg/rv32_defs.vh（编码/CSR/cause/窗口）、rtl/pkg/core_params.vh（参数）
//           **include 顺序：先 rv32_defs.vh 后 core_params.vh**（AGENT.md §3.2）
//------------------------------------------------------------------------------
// 本模块是**纯判定/译码层**，不实现存储阵列、不发 AXI、不做页表遍历：
//   · L1D 访问：只出**请求接口**（cache 组别实现 l1d.v）
//   · AXI：只出 route/属性与请求描述，**不发协议**（axi 组别实现 axi_master_ctrl.v）
//   · PTW/TLB：由 csr 组别实现（ptw.v/tlb.v），本模块只留 VA/PA 与权限口径端口
//   （禁止写 L1D/axi 控制器/PTW/TLB —— 本次任务范围红线）
//
//------------------------------------------------------------------------------
// §5.5 十项抉择在本模块的落点（**逐条**）：
//  1 非对齐 vs page/access fault：**非对齐优先**（本设计选择）。
//      lsu 先算 misaligned，若命中则**直接**报 cause 4/6，**不看** PMP/PTW 结果。
//  2 取指 PMP 粒度 = 16-bit parcel：属 F 级 fetch_unit，本模块不涉及（取指 PMP 由
//      fetch_unit 调用 pmp_check；lsu 只做**数据侧**拆笔，粒度 = 实际字节数）。
//  3 PMP 整笔边界 + 每笔独立：非对齐访问**拆成多笔**，每笔独立调用 pmp_check。
//      拆笔规则：按「自然对齐单元」切分 —— 若一笔跨 4 B 边界，拆成
//      [首字节..边界) 与 [边界..末字节] 两笔。
//  4 AMO 被 PMP 拒 **恒 cause 7**：AMO/LRSC/CMO 走 `amo_unit`/`cmo_unit`，
//      其 PMP 拒绝统一映射为 cause 7（见 §6 cause 选择）。
//  5 PMP 粒度 G=0 ⇒ NA4 可用：pmp_check 参数直通真源，本模块不做低位掩码。
//  6 无 PMP 匹配：M 成功 / S/U 失败：由 pmp_check 内部按特权级判定（本模块只传 priv）。
//  7 **mtval 恒 VA**（即使物理 access fault）：本模块输出 `mtval_o = mem_va_i`，
//      绝不输出 PA；非对齐时亦写 VA。
//  8 取指 PMP 违例 mepc 指向故障指令起始：属 F 级/trap_ctrl，本模块不涉及。
//  9 陷阱不降级委托：属 trap_ctrl，本模块不涉及。
// 10 MSHR 深度 1：属 l1d/cache 组别，本模块不涉及。
//
//------------------------------------------------------------------------------
// §6.4 MPRV/SUM/MXR 同拍旁路（本模块的**有效特权级**计算）：
//   · MPRV=1 时按 **MPP** 语义做翻译与保护（`mprv_i && mpp_i != M` ⇒ eff_priv = mpp_i）
//   · MPP=M 时 MPRV 等效无效果（仍按 M）—— 实现为 `eff_priv = mprv ? mpp : cur_priv`
//     的**统一表达式**，天然覆盖 MPP=M 的情形（规范 norm:mstatus_mprv_ldst_op）。
//   · **取指的翻译与保护不受 MPRV 影响**（doc §6.4 第 1 条）⇒ 本模块只对**数据侧**
//     应用 MPRV。
//   · SUM 仅影响**页表权限解释**（有效特权级 = S 时才允许访问 U=1 页）——
//     本模块把 `eff_sum_o` 交给 TLB/PTW；**SUM/MXR 不得进入 PMP 路径**
//     （PMP 与页权限独立，doc §6.4 第 2 条）。本模块调用 pmp_check 时**只传 eff_priv**，
//     不传 SUM/MXR。
//   · MXR 只影响**有效特权级 < M 的 load**（允许读 X=1 页）⇒ `eff_mxr_o` 带门控。
//   · "同拍旁路"：`cur_priv_i`/`mprv_i`/`mpp_i` 由 csr 侧在 **W 级提交当拍**给出
//     **旁路后的值**（含同拍 CSR 写结果）⇒ 本模块**不再做二次选择**，直接使用。
//
//------------------------------------------------------------------------------
// 异常优先级（本模块的判定顺序，**固定**）：
//   ① 非对齐（cause 0/4/6）—— 先于 PMP/PTW（抉择 1）
//       · CMO **不产生**非对齐异常（T8）—— CMO 跳过本判定
//   ② PMP 拒（cause 1/5/7）—— 每笔独立
//       · AMO/SC/LRSC 被拒 ⇒ **恒 7**（T4，抉择 4）
//   ③ page fault（cause 12/13/15）—— M2 后由 ptw 返回；本模块直通（**但低于** ① ）
//
// 风格（AGENT.md §4.3）：主体为 `assign` + `function`；唯一 `always` 块用于
//   「拆笔序列一拍推进」（真状态机，且注释理由）——2A 简化：非对齐拆笔用**组合
//   双笔并行**表达（两笔各配一个 pmp_check 实例，见 §5），故**无时序状态**，
//   本文件因此**完全不含 always 块**。
//
// 端口契约（本次只定义本模块对外端口；集成时由 core_top 接线）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module lsu #(
    parameter integer ADDR_W = 32,
    parameter integer PMP_ENTRIES = `RV32GC_PMP_ENTRIES
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // A. 来自 E 级的请求
    //--------------------------------------------------------------------------
    input  wire        req_valid_i,       // 本拍有访存请求
    input  wire [31:0] rs1_i,             // 基址寄存器值
    input  wire [31:0] imm_i,             // 立即数（I 型 / S 型已展开）

    // 访存类型 [本模块内部编码 A_*]
    input  wire [2:0]  mem_kind_i,        // A_LOAD/A_STORE/A_AMO/A_LR/A_SC/A_CBO
    input  wire [1:0]  size_i,            // 字节数编码：0=1B 1=2B 2=4B
    input  wire        unsigned_i,        // load 零扩展（lbu/lhu）
    input  wire [4:0]  amo_f5_i,          // AMO funct5（A_AMO 时有效）
    input  wire [4:0]  cbo_rs2_i,         // cbo 动作码（A_CBO 时有效）
    input  wire [31:0] store_data_i,      // store/SC 数据（rs2）

    //--------------------------------------------------------------------------
    // B. 特权/保护上下文（**已含同拍旁路**，见 §6.4）
    //--------------------------------------------------------------------------
    input  wire [1:0]  cur_priv_i,        // 当前特权级（同拍旁路后）
    input  wire        mprv_i,            // mstatus.MPRV（同拍旁路后）
    input  wire [1:0]  mpp_i,             // mstatus.MPP （同拍旁路后）
    input  wire        sum_i,             // mstatus.SUM （同拍旁路后）
    input  wire        mxr_i,             // mstatus.MXR （同拍旁路后）
    input  wire        inval_downgrade_i, // menvcfg.CBIE=01 ⇒ INVAL→FLUSH（用户裁决）

    //--------------------------------------------------------------------------
    // C. 翻译结果（来自 TLB/PTW；2A 无 MMU 时 PA=VA）
    //--------------------------------------------------------------------------
    input  wire [31:0] ptw_pa_i,          // 翻译后物理地址（Bare 模式 = VA）
    input  wire        ptw_fault_i,       // 翻译失败（页错误）
    input  wire [4:0]  ptw_cause_i,       // 页错误 cause（12/13/15）

    //--------------------------------------------------------------------------
    // D. PMP 配置（16 项平铺，来自 csr_file）
    //--------------------------------------------------------------------------
    input  wire [PMP_ENTRIES*8-1:0]  pmp_cfg_i,
    input  wire [PMP_ENTRIES*32-1:0] pmp_addr_i,

    //--------------------------------------------------------------------------
    // E. 输出：判定结果与下游请求
    //--------------------------------------------------------------------------
    output wire [31:0] mem_va_o,          // 访存虚拟地址（= rs1 + imm）
    output wire [31:0] mem_pa_o,          // 访存物理地址
    output wire [31:0] mem_addr_o,        // 实际发往 L1D 的（拆笔后首笔）地址

    // 异常
    output wire        exc_o,             // 本拍有访存异常
    output wire [4:0]  exc_cause_o,       // cause（0/4/5/6/7/13/15）
    output wire [31:0] mtval_o,           // **恒写 VA**（抉择 7）
    output wire        misaligned_o,      // 该笔非对齐（诊断）
    output wire        pmp_deny_o,        // PMP 拒绝（诊断）

    // 拆笔动作（非对齐 ⇒ 拆两笔，每笔独立过 PMP/分流）
    output wire        split_o,           // 1 ⇒ 本笔需拆成两笔
    output wire [1:0]  num_beats_o,       // 拆笔数（1 或 2）
    output wire [31:0] beat0_addr_o,      // 第 0 笔地址
    output wire [31:0] beat1_addr_o,      // 第 1 笔地址（split_o=0 时无意义）
    output wire [4:0]  beat0_bytes_o,     // 第 0 笔字节数
    output wire [4:0]  beat1_bytes_o,     // 第 1 笔字节数
    output wire        beat0_ok_o,        // 第 0 笔 PMP 放行
    output wire        beat1_ok_o,        // 第 1 笔 PMP 放行

    // 分流（核内 MMIO / XIP / AXI）
    output wire [2:0]  route_o,
    output wire        no_axi_o,          // **绝不发 AXI**（CLINT/PLIC）
    output wire        mmio_clint_plic_o,
    output wire        xip_direct_o,
    output wire        axi_uncached_o,
    output wire        axi_cached_o,

    // 缓存属性（供 axi_req_desc / l1d）
    output wire [3:0]  axi_cache_o,

    // AMO/LRSC 数据通路
    output wire [31:0] amo_rd_old_o,      // 写回 rd 的旧值 / SC 成功标志
    output wire        sc_success_o,      // SC 是否成功
    output wire [31:0] amo_wdata_o,       // AMO/SC 写回内存的新值
    output wire        amo_busy_o,        // AMO 多拍占用

    // CMO 动作
    output wire        cmo_valid_o,
    output wire [1:0]  cmo_action_o,
    output wire [31:0] cmo_block_addr_o,
    output wire [31:0] cmo_block_size_o,

    // 有效特权级与权限解释（供 TLB/PTW）
    output wire [1:0]  eff_priv_o,        // MPRV≠0 时按 MPP（§6.4）
    output wire        eff_sum_o,         // SUM 生效条件
    output wire        eff_mxr_o,         // MXR 生效条件
    output wire [1:0]  need_perm_o        // 本笔所需权限 {R,W,X}
);

    //==========================================================================
    // 1. 本模块内部编码（与 rtl/mem 各子模块的约定一致）
    //==========================================================================
    // 访存类型 mem_kind_i
    localparam [2:0] A_LOAD  = 3'd0;
    localparam [2:0] A_STORE = 3'd1;
    localparam [2:0] A_AMO   = 3'd2;
    localparam [2:0] A_LR    = 3'd3;
    localparam [2:0] A_SC    = 3'd4;
    localparam [2:0] A_CBO   = 3'd5;

    // pmp_check 的访问类型编码（与 pmp_check.v 的 T_* 一致）
    localparam [1:0] PT_LOAD  = 2'd0;
    localparam [1:0] PT_STORE = 2'd1;
    localparam [1:0] PT_EXEC  = 2'd2;
    localparam [1:0] PT_AMO   = 2'd3;

    // 分流编码（与 mmio_route.v 的 ROUTE_* 一致）
    localparam [2:0] ROUTE_NONE  = 3'd0;
    localparam [2:0] ROUTE_CLINT = 3'd1;
    localparam [2:0] ROUTE_PLIC  = 3'd2;
    localparam [2:0] ROUTE_XIP   = 3'd3;
    localparam [2:0] ROUTE_AXI   = 3'd4;

    // 特权级
    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;

    //==========================================================================
    // 2. 地址生成：mem_va = rs1 + imm   [08 §5.4 行为要点 ①]
    //==========================================================================
    wire [31:0] mem_va = rs1_i + imm_i;
    assign mem_va_o = mem_va;

    //==========================================================================
    // 3. 有效特权级（MPRV/MPP）与 SUM/MXR 口径   [08 §6.4]
    //==========================================================================
    // 统一表达式：MPRV=1 ⇒ 用 MPP；MPRV=0 ⇒ 用当前特权级。
    //   规范 norm:mstatus_mprv_ldst_op：MPRV=1 时按 MPP 做翻译与保护
    //   （MPP=M 自然等效 M 权限，无需特判）。
    //   ★ 取指不受 MPRV 影响 —— 本模块只处理数据侧，天然满足。
    wire [1:0] eff_priv = mprv_i ? mpp_i : cur_priv_i;
    assign eff_priv_o = eff_priv;

    // SUM：仅在**有效特权级 == S** 时影响页权限解释（doc §6.4 第 2 条）。
    //   （规范：SUM 在 mprv=1 && mpp=S 时生效；统一表达为 eff_priv==S。）
    wire eff_priv_is_s = (eff_priv == PRIV_S);
    wire eff_priv_is_u = (eff_priv == PRIV_U);
    wire eff_priv_is_m = (eff_priv == PRIV_M);

    assign eff_sum_o = sum_i && eff_priv_is_s;
    // MXR：只影响**有效特权级 < M 的 load**（doc §6.4 第 3 条）
    assign eff_mxr_o = mxr_i && !eff_priv_is_m;

    //==========================================================================
    // 4. 类型判定（组合）与所需权限
    //==========================================================================
    wire is_load  = (mem_kind_i == A_LOAD);
    wire is_store = (mem_kind_i == A_STORE);
    wire is_amo   = (mem_kind_i == A_AMO);
    wire is_lr    = (mem_kind_i == A_LR);
    wire is_sc    = (mem_kind_i == A_SC);
    wire is_cbo   = (mem_kind_i == A_CBO);

    // AMO 族（需要读-改-写，含 LR/SC）
    wire is_atomic = is_amo || is_lr || is_sc;
    // LR 语义上是**读**（PMP 按 load 判权与报 cause 5）；
    // AMO/SC 语义上是**写**（T4：被 PMP 拒恒 cause 7）。
    wire amo_like_pmp = is_amo || is_sc;

    // 访问类型（传给 pmp_check）：
    //   · LR        ⇒ PT_LOAD（读；PMP 拒 ⇒ cause 5）
    //   · AMO/SC/CMO⇒ PT_AMO （T4：恒 cause 7）
    //   · load      ⇒ PT_LOAD
    //   · store     ⇒ PT_STORE
    wire [1:0] pmp_acc_type = is_load ? PT_LOAD :
                              is_store ? PT_STORE :
                              is_lr    ? PT_LOAD :
                              (amo_like_pmp || is_cbo) ? PT_AMO : PT_LOAD;

    // 所需权限（供 TLB/PTW 页权限解释；PMP 侧由 pmp_check 按类型自行判）
    //   LR 需 R；AMO/SC/CMO 需 W（store/AMO 同族）；store 需 W；load 需 R
    assign need_perm_o = is_load ? 2'b10 :              // {R,W}
                         is_store? 2'b01 :
                         is_lr   ? 2'b10 :
                         (amo_like_pmp || is_cbo) ? 2'b01 : 2'b10;

    //==========================================================================
    // 5. 非对齐判定（**先于 PMP**，抉择 1）与拆笔
    //==========================================================================
    // 5.1 本笔字节数与自然对齐要求
    //   size_i: 0=1B(无对齐要求) 1=2B(2 B 对齐) 2=4B(4 B 对齐)
    //   AMO/LR/SC 恒为字宽（4 B，size 由译码给 2）—— 规范要求自然对齐
    //     [zaamo.adoc:17-22 / zalrsc.adoc:75-80]
    //   CMO **不产生**非对齐异常 [T8，cmo.adoc:409-410 norm:no_addr_misaligned_excep]
    //     ⇒ 跳过非对齐判定（cmo_unit 内部向下对齐）
    wire [4:0] acc_bytes = (size_i == 2'd0) ? 5'd1 :
                           (size_i == 2'd1) ? 5'd2 :
                           (size_i == 2'd2) ? 5'd4 : 5'd1;

    // 自然对齐违规判定：地址的低 log2(bytes) 位非零
    //   · 1 B：恒对齐
    //   · 2 B：addr[0] != 0 ⇒ 非对齐
    //   · 4 B：addr[1:0] != 0 ⇒ 非对齐
    // 用 function 表达，避免大 always。
    function misaligned;
        input [31:0] a;
        input [4:0]  b;
        begin
            case (b)
                5'd1    : misaligned = 1'b0;
                5'd2    : misaligned = (a[0] != 1'b0);
                5'd4    : misaligned = (a[1:0] != 2'b00);
                default : misaligned = (a[1:0] != 2'b00);   // 更宽一律按 4 B 判
            endcase
        end
    endfunction

    // CMO 豁免非对齐判定（T8）；其余按自然对齐要求判。
    wire raw_misaligned = misaligned(mem_va, acc_bytes);
    wire any_misalign  = req_valid_i && raw_misaligned && !is_cbo;
    assign misaligned_o = any_misalign;

    // 5.2 拆笔（非对齐 ⇒ 按自然对齐单元切分，每笔独立过 PMP）
    //   [norm:pmpmisalignedaccess_behavior] 每笔独立（08 §5.5 抉择 3）
    //   切分规则：设首字节地址 lo，末字节地址 hi = lo + bytes - 1。
    //     若 lo 与 hi 落在不同的「对齐单元」（4 B 边界）内 ⇒ 拆两笔：
    //        笔0 = [lo .. 该 4 B 边界末]（字节数 = 4 - lo[1:0]）
    //        笔1 = [边界 .. hi]        （字节数 = 总字节数 - 笔0 字节数）
    //      否则单笔。
    //   本实现用组合双笔并行：两笔各例化一个 pmp_check（见 5.4）。
    wire [31:0] lo_addr = mem_va;
    wire [31:0] hi_addr = mem_va + {27'd0, acc_bytes} - 32'd1;

    wire [31:0] lo_unit = {lo_addr[31:2], 2'b00};      // lo 所在 4 B 单元起点
    wire [31:0] hi_unit = {hi_addr[31:2], 2'b00};      // hi 所在 4 B 单元起点
    wire        crosses = (lo_unit != hi_unit);        // 跨 4 B 单元

    // 仅**非对齐且确实跨单元**时才拆（对齐访问恒单笔）
    wire do_split = req_valid_i && crosses && !is_cbo;

    // 笔 0：从 lo 到本单元末
    wire [4:0] beat0_n = 5'd4 - {3'd0, lo_addr[1:0]};
    wire [4:0] beat1_n = acc_bytes - beat0_n;

    assign split_o       = do_split;
    assign num_beats_o   = do_split ? 2'd2 : 2'd1;
    assign beat0_addr_o  = lo_addr;
    assign beat1_addr_o  = hi_unit;                    // 笔 1 从下一个单元起点开始
    assign beat0_bytes_o = do_split ? beat0_n : acc_bytes;
    assign beat1_bytes_o = do_split ? beat1_n : 5'd0;

    assign mem_addr_o    = lo_addr;

    //==========================================================================
    // 6. 物理地址与 PMP 检查
    //==========================================================================
    // ★ 地址翻译口径（08 §5.4 行为要点 ③）：PMP 对**翻译后的 S 级物理地址**做检查
    //   （Sv32 路径：VA → 页表 → S 级 PA → PMP → 机器 PA）。
    //   2A 在 M1/M2 早期 Bare 模式下 PA = VA；有 MMU 后由 ptw_pa_i 给出。
    //   本模块的 2A 简化：`ptw_pa_i` 由上层在 Bare 时接 mem_va。
    wire [31:0] mem_pa = ptw_pa_i;
    assign mem_pa_o    = mem_pa;

    // 6.1 笔 0 的 PA（拆笔时两笔各有自己的 PA）
    //   Bare 模式（PA=VA）下：笔0 PA = lo_addr；笔1 PA = hi_unit。
    //   有 MMU 时上层保证 ptw_pa_i 已按本笔地址给出（拆笔的每笔需各自翻译 ——
    //   2A 简化：跨页的非对齐访问由上层 PTW 多次调用本模块处理；此处按 Bare 口径）。
    wire [31:0] beat0_pa = mem_pa;
    wire [31:0] beat1_pa = hi_unit;                   // 与 beat1_addr_o 同源（Bare）

    // 6.2 PMP 实例 A：本笔（单笔时即为全部；拆笔时为笔 0）
    wire        pmp_a_allow, pmp_a_hit, pmp_a_full;
    wire [3:0]  pmp_a_idx;
    wire [`RV32GC_CAUSE_W-1:0] pmp_a_cause;

    pmp_check #(
        .PMP_ENTRIES (PMP_ENTRIES)
    ) u_pmp_a (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_i          (pmp_cfg_i),
        .addr_i         (pmp_addr_i),
        .acc_pa_i       (beat0_pa),
        .acc_bytes_i    (beat0_bytes_o),
        .acc_priv_i     (eff_priv),
        .acc_type_i     (pmp_acc_type),
        .allow_o        (pmp_a_allow),
        .fault_cause_o  (pmp_a_cause),
        .hit_o          (pmp_a_hit),
        .hit_idx_o      (pmp_a_idx),
        .denied_by_full_o (pmp_a_full)
    );

    // 6.3 PMP 实例 B：笔 1（仅拆笔时有效）
    wire        pmp_b_allow, pmp_b_hit, pmp_b_full;
    wire [3:0]  pmp_b_idx;
    wire [`RV32GC_CAUSE_W-1:0] pmp_b_cause;

    pmp_check #(
        .PMP_ENTRIES (PMP_ENTRIES)
    ) u_pmp_b (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_i          (pmp_cfg_i),
        .addr_i         (pmp_addr_i),
        .acc_pa_i       (beat1_pa),
        .acc_bytes_i    (beat1_bytes_o),
        .acc_priv_i     (eff_priv),
        .acc_type_i     (pmp_acc_type),
        .allow_o        (pmp_b_allow),
        .fault_cause_o  (pmp_b_cause),
        .hit_o          (pmp_b_hit),
        .hit_idx_o      (pmp_b_idx),
        .denied_by_full_o (pmp_b_full)
    );

    assign beat0_ok_o = pmp_a_allow;
    assign beat1_ok_o = pmp_b_allow;

    // 6.4 PMP 汇总：**每笔独立**。任一笔记被拒 ⇒ 整体异常。
    //   本设计口径：非对齐拆笔时，**先**检查笔 0，笔 0 过则笔 1 独立判；
    //   两笔各自的副作用允许部分落地（规范明确允许）。
    wire pmp_deny_any = !pmp_a_allow || (do_split && !pmp_b_allow);
    assign pmp_deny_o = pmp_deny_any;

    //==========================================================================
    // 7. MMIO 分流（核内 CLINT/PLIC **绝不发 AXI**）
    //==========================================================================
    wire        mr_no_axi, mr_clint_plic, mr_xip, mr_unc, mr_cac;
    wire        mr_clint, mr_plic, mr_periph;

    mmio_route #(
        .ADDR_W (ADDR_W)
    ) u_mmio_route (
        .pa_i           (mem_pa),
        .route_o        (route_o),
        .no_axi_o       (mr_no_axi),
        .clint_plic_o   (mr_clint_plic),
        .xip_direct_o   (mr_xip),
        .axi_uncached_o (mr_unc),
        .axi_cached_o   (mr_cac),
        .clint_hit_o    (mr_clint),
        .plic_hit_o     (mr_plic),
        .periph_hit_o   (mr_periph)
    );

    assign no_axi_o         = mr_no_axi;
    assign mmio_clint_plic_o= mr_clint_plic;
    assign xip_direct_o     = mr_xip;
    assign axi_uncached_o   = mr_unc;
    assign axi_cached_o     = mr_cac;

    // 缓存属性：核内 MMIO 与平台外设/XIP ⇒ 非缓存；DDR3 ⇒ 可缓存
    assign axi_cache_o = mr_cac ? `RV32GC_AXI_CACHE_CACHED :
                                  `RV32GC_AXI_CACHE_UNCACHED;

    //==========================================================================
    // 8. AMO / LRSC 数据通路（例化 amo_unit）
    //==========================================================================
    wire [31:0] amo_rd_old, amo_wdata;
    wire        amo_sc_ok, amo_exc;
    wire [4:0]  amo_exc_cause;
    wire        amo_r_req, amo_w_req, amo_busy;
    wire        amo_rsv_valid;
    wire [31:0] amo_rsv_addr;

    // AMO 单元的 PMP 拒绝输入：AMO/SC 被拒（T4 恒 cause 7）。
    //   LR 的 PMP 拒绝**不**走本端口（LR 按 load 报 cause 5，见 §9 cause 选择）。
    wire amo_pmp_deny = req_valid_i && is_atomic && (is_amo || is_sc) &&
                        pmp_deny_any;

    amo_unit u_amo_unit (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid_i    (req_valid_i && is_atomic),
        .is_lr_i        (is_lr),
        .is_sc_i        (is_sc),
        .is_amo_i       (is_amo),
        .amo_f5_i       (amo_f5_i),
        .addr_i         (mem_va),            // AMO 的地址（对齐由 misaligned 门控）
        .misaligned_i   (any_misalign),
        .pmp_deny_i     (amo_pmp_deny),
        .rs2_i          (store_data_i),
        .rdata_i        (32'd0),             // ★ L1D 读返回：由 cache 组别接线（本任务范围外）
        .rdata_valid_i  (1'b0),              // ★ 同上；2A 集成时接 l1d 的 rvalid
        .rd_old_o       (amo_rd_old),
        .sc_success_o   (amo_sc_ok),
        .wdata_o        (amo_wdata),
        .w_req_o        (amo_w_req),
        .r_req_o        (amo_r_req),
        .busy_o         (amo_busy),
        .exc_o          (amo_exc),
        .exc_cause_o    (amo_exc_cause),
        .rsv_valid_o    (amo_rsv_valid),
        .rsv_addr_o     (amo_rsv_addr)
    );

    assign amo_rd_old_o = amo_rd_old;
    assign sc_success_o = amo_sc_ok;
    assign amo_wdata_o  = amo_wdata;
    assign amo_busy_o   = amo_busy;

    //==========================================================================
    // 9. CMO 动作生成（例化 cmo_unit）
    //==========================================================================
    wire        cmo_valid, cmo_cause7;
    wire [1:0]  cmo_action;
    wire [31:0] cmo_blk_addr, cmo_blk_size;

    // CMO 的 PMP 检查按 store/AMO 口径（cmo.adoc:395-405）
    wire cmo_pmp_deny = req_valid_i && is_cbo && pmp_deny_any;

    cmo_unit u_cmo_unit (
        .is_cbo_i          (is_cbo),
        .cbo_rs2_i         (cbo_rs2_i),
        .va_i              (mem_va),
        .inval_downgrade_i (inval_downgrade_i),
        .pmp_deny_i        (cmo_pmp_deny),
        .valid_o           (cmo_valid),
        .action_o          (cmo_action),
        .block_addr_o      (cmo_blk_addr),
        .block_size_o      (cmo_blk_size),
        .cause7_o          (cmo_cause7)
    );

    assign cmo_valid_o       = cmo_valid;
    assign cmo_action_o      = cmo_action;
    assign cmo_block_addr_o  = cmo_blk_addr;
    assign cmo_block_size_o  = cmo_blk_size;

    //==========================================================================
    // 10. 异常优先级与 cause 选择（**固定顺序**，见文件头）
    //==========================================================================
    // ① 非对齐优先（抉择 1 / T3）：先于 PMP 与 page fault。
    //    · load             ⇒ cause 4（load address misaligned）
    //    · store/AMO/LRSC   ⇒ cause 6（store/AMO address misaligned）
    //    · CMO              ⇒ **不产生**（T8）⇒ any_misalign 已对 CMO 门控为 0
    // ② PMP 拒（每笔独立）：
    //    · load             ⇒ cause 5
    //    · store            ⇒ cause 7
    //    · AMO/SC           ⇒ **恒 cause 7**（T4，抉择 4）
    //    · LR               ⇒ cause 5（LR 是读；见 §4 口径说明）
    //    · CMO              ⇒ cause 7（store/AMO 同族）
    // ③ page fault（由 ptw 返回）—— **低于** ①（抉择 1：非对齐优先）
    wire misalign_is_load  = is_load || is_lr;         // load/LR ⇒ cause 4
    wire misalign_is_store = is_store || is_amo || is_sc; // store/AMO/SC ⇒ cause 6

    wire [`RV32GC_CAUSE_W-1:0] mis_cause =
        misalign_is_load  ? `RV32GC_EXC_LOAD_MISALIGNED  :   // 4
        misalign_is_store ? `RV32GC_EXC_STORE_MISALIGNED :   // 6
                            `RV32GC_EXC_LOAD_MISALIGNED;     // 兜底（不应到达）

    // PMP 拒的 cause：按访问类型（pmp_check 已按类型给出，此处复算以保证
    // 与 T4 的「AMO/SC 恒 7」口径显式一致）。
    wire [`RV32GC_CAUSE_W-1:0] pmp_cause =
        is_load ? `RV32GC_EXC_LOAD_ACCESS_FAULT    :          // 5
        is_lr   ? `RV32GC_EXC_LOAD_ACCESS_FAULT    :          // 5（LR 是读）
        (is_store || is_amo || is_sc || is_cbo) ?
                  `RV32GC_EXC_STORE_ACCESS_FAULT   :          // 7（含 T4 的 AMO/SC 恒 7）
                  pmp_a_cause;                                // 兜底用 pmp 给出的

    // CMO 被拒 ⇒ 恒 cause 7（cmo_unit 内部同口径）
    wire [`RV32GC_CAUSE_W-1:0] cmo_fault_cause = `RV32GC_EXC_STORE_ACCESS_FAULT;

    // 页错误 cause（ptw 给出；仅在做翻译时有意义）
    wire [`RV32GC_CAUSE_W-1:0] page_cause = ptw_cause_i;

    // ---- 最终优先级选择 ----
    wire sel_misalign = req_valid_i && any_misalign;
    wire sel_pmp      = req_valid_i && !any_misalign && pmp_deny_any;
    wire sel_page     = req_valid_i && !any_misalign && !pmp_deny_any && ptw_fault_i;

    assign exc_o = sel_misalign || sel_pmp || sel_page;

    assign exc_cause_o = sel_misalign ? mis_cause    :
                         sel_pmp      ? (is_cbo ? cmo_fault_cause : pmp_cause) :
                         sel_page     ? page_cause   :
                                        `RV32GC_EXC_LOAD_ACCESS_FAULT;  // 无异常时无意义

    // ---- mtval：**恒写 VA**（抉择 7；norm:mtvalvaddrnot_paddr） ----
    //   即使异常来自物理内存 access fault，mtval 也写**虚拟地址**。
    //   非对齐异常同样写 VA（norm:mtval_vaddr_wr2 允许）。
    assign mtval_o = mem_va;

endmodule
