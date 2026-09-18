//==============================================================================
// rtl/exec/fpu.v —— FPU 顶层（F/D 全部浮点指令：算术 / 比较 / 转换 / 搬移 + FMA）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（E 级 `fpu.v` 行 +
//           「**FPU 分期与流水化要求**」① 拍数可配置 / ② fflags 精确 /
//           ③ `fmadd` 系列单次舍入 / ④ 允许流水化但语义不变）
//         端口契约：.work_fpu/INTERFACE.md（本文件逐字实现该端口表）
//         IEEE-754-2008 binary32/binary64；RISC-V F/D
//         （riscv-isa-manual/src/unpriv/f-st-ext.adoc、d-st-ext.adoc：
//           NaN-boxing `d-st-ext.adoc:24-59`、canonical NaN `f-st-ext.adoc:134-139`）
//
//------------------------------------------------------------------------------
// 1. 指令覆盖与归一化 fp_op[6:0]（子单元分工）
//------------------------------------------------------------------------------
//   ┌─ 算术（例化 fpu_add.v / fpu_mul.v / fpu_div_sqrt.v）────────────────────┐
//   │  0 FADD   1 FSUB   2 FMUL   3 FDIV   4 FSQRT                          │
//   │ 26 FMADD 27 FMSUB 28 FNMSUB 29 FNMADD  ← 本文件定义的扩展编码（见 ★） │
//   ├─ 比较 / 符号注入 / 分类（例化 fpu_cmp.v，纯组合）──────────────────────┤
//   │  5 FSGNJ   6 FSGNJN  7 FSGNJX  8 FMIN   9 FMAX                        │
//   │ 10 FEQ    11 FLT    12 FLE    13 FCLASS                              │
//   ├─ 转换 / 搬移（例化 fpu_cvt.v，纯组合）────────────────────────────────┤
//   │ 14 FMV_X_W / FMV_X_D（fmt=00 / 01）  15 FMV_W_X / FMV_D_X（fmt=00/01）│
//   │ 16 FCVT_W_S   17 FCVT_WU_S   18 FCVT_S_W   19 FCVT_S_WU               │
//   │ 20 FCVT_W_D   21 FCVT_WU_D   22 FCVT_D_W   23 FCVT_D_WU               │
//   │ 24 FCVT_S_D（fmt=00，**目标 S**）  25 FCVT_D_S（fmt=01，**目标 D**）  │
//   └────────────────────────────────────────────────────────────────────────┘
//   ★ 0–25 的表来自 `fpu_cmp.v` / `fpu_cvt.v` 头注（全设计唯一定义，本文件与
//     其**逐条一致**）。该表**没有** FMA 族，而 08 §5.3 「FPU 分期与流水化
//     要求」③ 明确要求 `fmadd/fmsub/fnmadd/fnmsub` 必须单次舍入 ⇒ 本文件把
//     FMA 族作为 **26–29 扩展编码**定义在此（fpu.v 是唯一能承载该扩展的
//     交付文件），并在 tb_fpu.sv / 回归里逐条覆盖：
//       26 FMADD  = (+a×b) + c   neg_prod=0 neg_add=0
//       27 FMSUB  = (+a×b) − c   neg_prod=0 neg_add=1
//       28 FNMSUB = (−a×b) + c   neg_prod=1 neg_add=0
//       29 FNMADD = (−a×b) − c   neg_prod=1 neg_add=1
//     （RISC-V 定义：fmsub = rs1×rs2 − rs3；fnmsub = −(rs1×rs2) + rs3；
//       fnmadd = −(rs1×rs2) − rs3。）
//   ★ 未定义 fp_op（30…127）⇒ 确定行为：result=0、fflags=0、done 照常脉冲，
//     不挂死（译码保证不出现；与 mdu.v「未定义 op 给确定行为」同口径）。
//
//------------------------------------------------------------------------------
// 2. 时序契约（tb_fpu.sv 按此断言；E 级/hazard **必须按 busy/done 消费**，
//             禁止把任何完成拍数硬编码）
//------------------------------------------------------------------------------
//   设 req_valid 与各字段在时钟沿 E0 被采样（须满足 E0 拍 busy==0 且无在途
//   div/sqrt 结果，见第 4 条）：
//     · 单拍类（除 FDIV/FSQRT 外的全部）：结果**纯组合**给出 ⇒ E0 拍
//       done=1（与 req_valid 同拍）、result/fflags 有效；req_valid 收回后
//       done 立即为 0 ⇒ 单拍脉冲。busy 恒 0。
//     · div/sqrt：E0 拍把单拍 start 送给 fpu_div_sqrt；**busy/done 透传**：
//         - 特殊值路径（0/0、1/0、√(−1)…）：done 出现在 E0+1 拍，busy 未拉高；
//         - 迭代路径：busy 在 E0+1 拍拉高，done 与 busy 落低**同拍**
//           （done 拍 busy==0），result/fflags 在该拍有效；
//         - done 恒为单拍脉冲（无重复 done）。
//       ★ busy 拍数完全由 fpu_div_sqrt 决定（默认参数取自 pkg 的
//         `RV32GC_FDIV_CYCLES`/`RV32GC_FSQRT_CYCLES`，见第 5 条「参数透传」），
//         本文件**不推导、不硬编码**任何完成拍数。
//     · div/sqrt 结果尚未被 done 报出期间（内部 divsqrt_pend=1）本模块拒绝
//       新派发（done=0、不产生 start）⇒ 新指令最早可在 done 的**下一拍**派发
//       （done 拍不接收新指令，避免与在途 result 混淆——已写入本契约）。
//     · flush=1：立即撤销在途 div/sqrt（busy 下一拍落 0）、**不**产生 done；
//       单拍类在 flush 拍也不产生 done（该指令被冲刷）。
//     · 单拍类与 div/sqrt **背靠背**：div/sqrt 在 busy=1 期间占住本模块，
//       单拍类在 div/sqrt 的 done 拍之后即可派发，互不干扰。
//
//------------------------------------------------------------------------------
// 3. NaN-boxing / canonical NaN / 保留舍入模式（口径与 INTERFACE.md 一致）
//------------------------------------------------------------------------------
//   ① 非 transfer 的 **S 操作数**必须先做 NaN-boxing 检查：高 32 位不全 1 ⇒
//      该操作数按 S canonical NaN (0x7FC0_0000) 参与运算
//      （d-st-ext.adoc:52-59 norm:FP_nontransfer_instrs_improper_nan-boxed_input）。
//      ⇒ 算术类（FADD/FSUB/FMUL/FMA/FDIV/FSQRT）的 a/b/c 在本文件内统一
//        box_chk() 后再喂给子单元；比较/转换类（fpu_cmp/fpu_cvt）**自带**该
//        检查 ⇒ 本文件给它们**原始**操作数（避免双重替换；fmv.x.w / fcvt.d.s
//        的 D 侧必须见原始 64 位，见 fpu_cvt.v 头注 ④⑥）。
//   ② **S 结果**写回 fregfile 的 64 位视图时高 32 位必须全 1（NaN-boxing）：
//      本文件对 32 位宽的子单元输出（fpu_add_s/fpu_mul_s/fpu_fma_s，
//      fpu_div_sqrt 的 S 路径）统一补高 32 位 1；fpu_cmp/fpu_cvt 的 result
//      已按其头注完成"整数目标高 32 位 0 / 浮点目标 S 补 1 / D 完整 64 位"，
//      本文件原样透传、**不**再补。
//   ③ 算术结果若为 NaN ⇒ canonical NaN（S: 0x7FC0_0000 / D: 0x7FF8_0000_0000_0000），
//      由各子单元保证；含 sNaN ⇒ 同时置 NV。
//   ④ rm 解析（**唯一一处**，与 fpu_cvt.v 的解析式逐位一致）：
//      rm==111(DYN) ⇒ 取 frm；rm=101/110 或 frm 保留值 ⇒ 按 RNE 处理且
//      **不**置 fflags（INTERFACE.md「保留舍入模式的处置」）；解析结果
//      rm_eff 广播给所有子单元（fpu_cvt 内部对非 DYN 的 rm_eff 是恒等变换，
//      所以只解析一次不会改变其行为）。frm 仍接到 fpu_cvt 端口。
//
//------------------------------------------------------------------------------
// 4. fflags / fflags_we
//------------------------------------------------------------------------------
//   `fflags_we = done`：**每条**完成的 FP 指令都随结果给出 5 bit fflags
//   （{NV,DZ,OF,UF,NX}，与 rv32_defs.vh 的 csr_file fflags 位序一致）。
//   fsgnj*/fclass/fmv.* 的 fflags 恒为 0（规范不允许这些指令置位）
//   ⇒ we=1+0 与 we=0 等价，CSR 侧无条件按 we 累积即可（不会多置位）。
//   fflags 精确性由子单元保证（fpu_add.v 的舍入原语已逐位验证）。
//
//------------------------------------------------------------------------------
// 5. 参数透传 / 综合分支（红线 1、2）
//------------------------------------------------------------------------------
//   本模块把 FDIV_CYCLES / FSQRT_CYCLES **原样透传**给 fpu_div_sqrt 的例化
//   （默认值取 `rtl/pkg/core_params.vh` 的唯一真源 `RV32GC_FDIV_CYCLES` /
//   `RV32GC_FSQRT_CYCLES`），不在本文件内做任何拍数换算。
//   `RV32GC_USE_VIVADO_IP`（**只由综合脚本定义**，iverilog/Verilator 回归
//   从不定义——08 §3.3 第 3 条）：div/sqrt 的 Vivado `Floating-Point
//   Operator v7.1`（PG060）IP 例化在 `fpu_div_sqrt.v` 内（其头注已登记该
//   双分支契约：综合走 IP、仿真走逐拍等价行为模型）。IP 的完成时刻由
//   IP 握手（`m_axis_dout_tvalid`）经 `done` 报出、**不**由本文件假定
//   ⇒ 该分支下 FDIV_CYCLES/FSQRT_CYCLES 只是"占位参数"（端口与参数表
//   必须与仿真分支完全一致），本文件据此把默认值置 1；仿真分支保持 pkg
//   默认（32/32）。两分支端口、参数表、握手契约**逐字相同**。
//   ★ 本文件不含任何 FPGA 原语、也不例化 IP（纯位级选通/打包 + 一个 2 bit
//     状态锁存），满足红线 1；算术硬核（DSP/乘除 IP）全部在子单元内。
//
//------------------------------------------------------------------------------
// 6. 实现纪律（红线 3）
//------------------------------------------------------------------------------
//   全部为 `assign` / 条件表达式 / `function`；唯一的 always 块是"在途
//   div/sqrt 结果寄存"的 2 bit 时序锁存（见 §7，理由已就地注释）——
//   它必须跨多拍记住"最近一次派发的是 div/sqrt + 其格式"，否则 done 拍
//   上游可能已把 fp_op/fmt 换成下一条指令，结果的 NaN-boxing 与选通就会错。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

module fpu #(
`ifdef RV32GC_USE_VIVADO_IP
    // 综合分支：div/sqrt 的完成拍由 Vivado Floating-Point Operator IP 握手决定
    // ⇒ 拍数参数为**占位值**（IP 分支不参与拍数推导），仅保持参数表一致。
    parameter integer FDIV_CYCLES  = 1,
    parameter integer FSQRT_CYCLES = 1
`else
    // 仿真分支（默认）：拍数真源 = rtl/pkg/core_params.vh（唯一真源，只读）
    parameter integer FDIV_CYCLES  = `RV32GC_FDIV_CYCLES,
    parameter integer FSQRT_CYCLES = `RV32GC_FSQRT_CYCLES
`endif
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,        // 冲刷：忙时撤销在途 div/sqrt（异常/重定向）
    // ---- 译码端口（由 exe_ctrl/decoder 驱动）----
    input  wire        req_valid,    // 本拍派发一条 FP 指令
    input  wire [6:0]  fp_op,        // 归一化操作码（表见头注 §1）
    input  wire [1:0]  fmt,          // 00=S(32b) / 01=D(64b)；op14/15 选 W/D、op24/25 选目标格式
    input  wire [2:0]  rm,           // 指令 rm 域（111=DYN）
    input  wire [2:0]  frm,          // fcsr.frm（本模块用于解析 DYN）
    input  wire [63:0] a, b, c,      // 操作数（c=rs3，仅 FMA 用）
    // ---- 结果与握手 ----
    output wire        busy,         // 多拍冻结前端（div/sqrt 在途）
    output wire        done,         // 结果有效（单拍脉冲）
    output wire [63:0] result,       // 写回值（S 结果高 32 位全 1，NaN-boxed）
    output wire        fflags_we,    // = done（见 §4）
    output wire [4:0]  fflags        // {NV,DZ,OF,UF,NX}
);

    //==========================================================================
    // 1. 操作码表（与 fpu_cmp.v / fpu_cvt.v 头注逐条一致；26–29 为本文件扩展）
    //==========================================================================
    localparam [6:0] FP_FADD     = 7'd0;
    localparam [6:0] FP_FSUB     = 7'd1;
    localparam [6:0] FP_FMUL     = 7'd2;
    localparam [6:0] FP_FDIV     = 7'd3;
    localparam [6:0] FP_FSQRT    = 7'd4;
    localparam [6:0] FP_FSGNJ    = 7'd5;
    localparam [6:0] FP_FSGNJN   = 7'd6;
    localparam [6:0] FP_FSGNJX   = 7'd7;
    localparam [6:0] FP_FMIN     = 7'd8;
    localparam [6:0] FP_FMAX     = 7'd9;
    localparam [6:0] FP_FEQ      = 7'd10;
    localparam [6:0] FP_FLT      = 7'd11;
    localparam [6:0] FP_FLE      = 7'd12;
    localparam [6:0] FP_FCLASS   = 7'd13;
    localparam [6:0] FP_FMV_X    = 7'd14;   // fmt=00 fmv.x.w / fmt=01 fmv.x.d
    localparam [6:0] FP_FMV_W_X  = 7'd15;   // fmt=00 fmv.w.x / fmt=01 fmv.d.x
    localparam [6:0] FP_FCVT_W_S  = 7'd16;
    localparam [6:0] FP_FCVT_WU_S = 7'd17;
    localparam [6:0] FP_FCVT_S_W  = 7'd18;
    localparam [6:0] FP_FCVT_S_WU = 7'd19;
    localparam [6:0] FP_FCVT_W_D  = 7'd20;
    localparam [6:0] FP_FCVT_WU_D = 7'd21;
    localparam [6:0] FP_FCVT_D_W  = 7'd22;
    localparam [6:0] FP_FCVT_D_WU = 7'd23;
    localparam [6:0] FP_FCVT_S_D  = 7'd24;  // fmt=00（目标 S）
    localparam [6:0] FP_FCVT_D_S  = 7'd25;  // fmt=01（目标 D）
    // ---- FMA 族（扩展编码，见头注 §1 ★）----
    localparam [6:0] FP_FMADD    = 7'd26;
    localparam [6:0] FP_FMSUB    = 7'd27;
    localparam [6:0] FP_FNMSUB   = 7'd28;
    localparam [6:0] FP_FNMADD   = 7'd29;

    //==========================================================================
    // 2. 类别译码（互斥；一张表一处定义）
    //==========================================================================
    wire is_d      = (fmt == 2'b01);
    wire op_addsub = (fp_op == FP_FADD) | (fp_op == FP_FSUB);
    wire op_mul    = (fp_op == FP_FMUL);
    wire op_fma    = (fp_op >= FP_FMADD) & (fp_op <= FP_FNMADD);
    wire op_div    = (fp_op == FP_FDIV);
    wire op_sqrt   = (fp_op == FP_FSQRT);
    wire op_ds     = op_div | op_sqrt;                       // 多拍类
    wire op_cmp    = (fp_op >= FP_FSGNJ) & (fp_op <= FP_FCLASS);
    wire op_cvt    = (fp_op >= FP_FMV_X) & (fp_op <= FP_FCVT_D_S);
    wire op_fma_np = (fp_op == FP_FNMSUB) | (fp_op == FP_FNMADD);  // 取反积
    wire op_fma_na = (fp_op == FP_FMSUB)  | (fp_op == FP_FNMADD);  // 取反加数

    //==========================================================================
    // 3. 舍入模式解析（唯一一处；口径见头注 §3 ④）
    //==========================================================================
    wire rm_reserved  = (rm == 3'b101) | (rm == 3'b110);
    wire frm_reserved = (frm == 3'b101) | (frm == 3'b110) | (frm == 3'b111);
    wire [2:0] rm_eff = (rm == `RV32GC_RM_DYN) ? (frm_reserved ? `RV32GC_RM_RNE : frm)
                                               : (rm_reserved  ? `RV32GC_RM_RNE : rm);

    //==========================================================================
    // 4. S 操作数 NaN-boxing 检查（仅算术类；比较/转换类自带检查，见头注 §3 ①）
    //==========================================================================
    localparam [31:0] CANON_S = 32'h7FC0_0000;      // S canonical NaN
    localparam [31:0] BOX_HI  = 32'hFFFF_FFFF;      // S 结果的高 32 位（NaN-box）

    function [63:0] box_chk;                        // 非 transfer 的 S 操作数
        input [63:0] x;
        begin
            box_chk = (x[63:32] == BOX_HI) ? x : {BOX_HI, CANON_S};
        end
    endfunction

    wire [63:0] a_ar = is_d ? a : box_chk(a);       // 算术类操作数（S 已 box 检查）
    wire [63:0] b_ar = is_d ? b : box_chk(b);
    wire [63:0] c_ar = is_d ? c : box_chk(c);       // FMA 的 rs3

    //==========================================================================
    // 5. 算术子单元（S/D 双核 + fmt 选择；与 fpu_cmp.v 同风格：以面积换直白）
    //--------------------------------------------------------------------------
    // ★ 仿真吞吐优化（2026-09-17，**语义逐位不变**，只为让 arch-test F 组在
    //   run.sh 的超时内跑完）：**未选中子单元的操作数输入钳到 0**。
    //   本文件按"面积换直白"例化了 S/D 双份算术核（add/mul/fma × S/D + cvt + cmp），
    //   但 §8 的结果选择只会用到 fp_op/fmt 选中的那一份，其余输出**恒被丢弃**。
    //   若照常把 fregfile 的操作数接到所有子单元，iverilog 每拍都要重算全部单元
    //   （D 侧含 8192 bit 移位域 × 6 个舍入原语实例）⇒ F 组用例跑不完。
    //   ★ 2026-09-18 窄域 + sticky 重写后，算术子单元内部域已降到 ≤ 112 bit
    //     （见 fpu_add.v 头注 P1~P6），本文件的钳零机制**保留**：它仍然避免
    //     未选中格式的子单元在 iverilog 事件驱动下被重算。
    //   钳零后未选中单元的输入不再跳变，事件驱动仿真不再重算它们；选中单元的
    //   端口、位宽与位级语义一位不动。
    //   ★ 判据只用 fp_op/fmt（E 级指令字段）——多拍/停顿期间这两个字段保持不变
    //     （E 级被冻结），故结果与钳零前逐位相同；冲刷拍即使变化，结果也会被丢弃。
    //==========================================================================
    wire en_add_s = (op_addsub & ~is_d);
    wire en_add_d = (op_addsub &  is_d);
    wire en_mul_s = (op_mul    & ~is_d);
    wire en_mul_d = (op_mul    &  is_d);
    wire en_fma_s = (op_fma    & ~is_d);
    wire en_fma_d = (op_fma    &  is_d);
    wire en_cmp   =  op_cmp;
    wire en_cvt   =  op_cvt;

    wire [63:0] a_add_s = en_add_s ? a_ar : 64'd0;
    wire [63:0] b_add_s = en_add_s ? b_ar : 64'd0;
    wire [63:0] a_add_d = en_add_d ? a    : 64'd0;
    wire [63:0] b_add_d = en_add_d ? b    : 64'd0;
    wire [63:0] a_mul_s = en_mul_s ? a_ar : 64'd0;
    wire [63:0] b_mul_s = en_mul_s ? b_ar : 64'd0;
    wire [63:0] a_mul_d = en_mul_d ? a    : 64'd0;
    wire [63:0] b_mul_d = en_mul_d ? b    : 64'd0;
    wire [63:0] a_fma_s = en_fma_s ? a_ar : 64'd0;
    wire [63:0] b_fma_s = en_fma_s ? b_ar : 64'd0;
    wire [63:0] c_fma_s = en_fma_s ? c_ar : 64'd0;
    wire [63:0] a_fma_d = en_fma_d ? a    : 64'd0;
    wire [63:0] b_fma_d = en_fma_d ? b    : 64'd0;
    wire [63:0] c_fma_d = en_fma_d ? c    : 64'd0;
    wire [63:0] a_cmp   = en_cmp   ? a    : 64'd0;
    wire [63:0] b_cmp   = en_cmp   ? b    : 64'd0;
    wire [63:0] a_cvt   = en_cvt   ? a    : 64'd0;

    wire [31:0] add_s_r;  wire [63:0] add_d_r;  wire [4:0] add_s_f, add_d_f;
    wire [31:0] mul_s_r;  wire [63:0] mul_d_r;  wire [4:0] mul_s_f, mul_d_f;
    wire [31:0] fma_s_r;  wire [63:0] fma_d_r;  wire [4:0] fma_s_f, fma_d_f;

    fpu_add_s u_add_s (
        .a (a_add_s), .b (b_add_s), .op_sub (fp_op == FP_FSUB), .rm (rm_eff),
        .result (add_s_r), .fflags (add_s_f)
    );
    fpu_add_d u_add_d (
        .a (a_add_d), .b (b_add_d), .op_sub (fp_op == FP_FSUB), .rm (rm_eff),
        .result (add_d_r), .fflags (add_d_f)
    );
    fpu_mul_s u_mul_s (
        .a (a_mul_s), .b (b_mul_s), .rm (rm_eff),
        .result (mul_s_r), .fflags (mul_s_f)
    );
    fpu_mul_d u_mul_d (
        .a (a_mul_d), .b (b_mul_d), .rm (rm_eff),
        .result (mul_d_r), .fflags (mul_d_f)
    );
    // FMA：fpu_fma_s/d 内是"精确积 + 精确对阶 + **一次**舍入"⇒ 单次舍入
    // （08 §5.3 ③；结构上不可能两次舍入，见 fpu_add.v 头注 §2.3）
    fpu_fma_s u_fma_s (
        .a (a_fma_s), .b (b_fma_s), .c (c_fma_s),
        .neg_prod (op_fma_np), .neg_add (op_fma_na),
        .rm (rm_eff), .result (fma_s_r), .fflags (fma_s_f)
    );
    fpu_fma_d u_fma_d (
        .a (a_fma_d), .b (b_fma_d), .c (c_fma_d),
        .neg_prod (op_fma_np), .neg_add (op_fma_na),
        .rm (rm_eff), .result (fma_d_r), .fflags (fma_d_f)
    );

    // ---- 算术结果打包：S 输出补高 32 位 1（NaN-boxing），D 输出完整 64 位 ----
    wire [63:0] arith_r = op_mul ? (is_d ? mul_d_r : {BOX_HI, mul_s_r}) :
                          op_fma ? (is_d ? fma_d_r : {BOX_HI, fma_s_r}) :
                                   (is_d ? add_d_r : {BOX_HI, add_s_r});
    wire [4:0]  arith_f = op_mul ? (is_d ? mul_d_f : mul_s_f) :
                          op_fma ? (is_d ? fma_d_f : fma_s_f) :
                                   (is_d ? add_d_f : add_s_f);

    //==========================================================================
    // 6. 比较/分类（fpu_cmp）与转换/搬移（fpu_cvt）：纯组合，原样透传其 result
    //    （两者的结果定向/NaN-boxing 已在其头注与实现内完成）
    //==========================================================================
    wire [63:0] cmp_r;  wire [4:0] cmp_f;
    fpu_cmp u_cmp (
        .fp_op (fp_op), .fmt (fmt), .a (a_cmp), .b (b_cmp),
        .result (cmp_r), .fflags (cmp_f)
    );

    wire [63:0] cvt_r;  wire [4:0] cvt_f;
    fpu_cvt u_cvt (
        .fp_op (fp_op), .fmt (fmt), .rm (rm_eff), .frm (frm), .a (a_cvt),
        .result (cvt_r), .fflags (cvt_f)
    );

    //==========================================================================
    // 7. div/sqrt：busy/done **透传**（参数原样透传给 fpu_div_sqrt）
    //==========================================================================
    wire        ds_busy, ds_done;
    wire [63:0] ds_r;
    wire [4:0]  ds_f;

    // 在途 div/sqrt 结果寄存（唯一的时序锁存；理由：done 拍上游可能已把
    // fp_op/fmt 换成下一条指令，结果的"选通 + S 结果 NaN-boxing"必须按
    // **派发时**的类别/格式决定，不能看当前输入）。
    reg  ds_pend;       // 1 = 最近派发的是 div/sqrt，结果尚未被 done 报出
    reg  ds_fmt_d;      // 该指令的格式（1=D，0=S）

    wire ds_can_disp = ~ds_busy & ~ds_pend & ~flush;   // 允许新派发的唯一条件
    wire disp_any    = req_valid & ds_can_disp;        // 本条指令被本模块接收
    wire disp_ds     = disp_any & op_ds;               // 送给 fpu_div_sqrt 的 start
    wire disp_sc     = disp_any & ~op_ds;              // 单拍类

    fpu_div_sqrt #(
        .FDIV_CYCLES  (FDIV_CYCLES),      // ★ 参数透传（不在本文件内换算拍数）
        .FSQRT_CYCLES (FSQRT_CYCLES)
    ) u_div_sqrt (
        .clk (clk), .rst_n (rst_n), .flush (flush),
        .start (disp_ds), .is_sqrt (op_sqrt), .fmt_d (is_d),
        .a (a_ar), .b (b_ar), .rm (rm_eff),
        .busy (ds_busy), .done (ds_done), .result (ds_r), .fflags (ds_f)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds_pend  <= 1'b0;
            ds_fmt_d <= 1'b0;
        end else if (flush) begin
            ds_pend  <= 1'b0;           // 在途结果作废（fpu_div_sqrt 同步释放 busy）
        end else if (disp_ds) begin
            ds_pend  <= 1'b1;           // 本拍派发的 div/sqrt 结果待 done 报出
            ds_fmt_d <= is_d;           // 锁存格式 ⇒ S 结果按派发时的格式补 1
        end else if (ds_done) begin
            ds_pend  <= 1'b0;
        end
    end

    // S 结果补高 32 位 1（NaN-boxing）；D 结果完整 64 位
    wire [63:0] ds_r_box = ds_fmt_d ? ds_r : {BOX_HI, ds_r[31:0]};

    //==========================================================================
    // 8. 结果 / fflags / 握手输出
    //==========================================================================
    wire [63:0] sc_r = op_cmp ? cmp_r :
                       op_cvt ? cvt_r :
                                arith_r;        // 含未定义 op ⇒ arith_r（FADD 通路）
    wire [4:0]  sc_f = op_cmp ? cmp_f :
                       op_cvt ? cvt_f :
                                arith_f;

    // 选通：div/sqrt 的 done 拍与在途期间选 div/sqrt 结果（上游 fp_op 已不可信）；
    // 未定义 op 不在任何类别 ⇒ 结果确定 0（不挂死，见头注 §1 ★）
    wire sel_ds  = ds_done | ds_pend;
    wire op_known = (fp_op <= FP_FNMADD);

    assign result    = sel_ds        ? ds_r_box :
                       op_known      ? sc_r     :
                                       64'b0;
    assign fflags    = sel_ds        ? ds_f     :
                       op_known      ? sc_f     :
                                       5'b0;

    // busy：div/sqrt 在途（多拍）⇒ 冻结前端；单拍类恒 0（纯组合，不占拍）
    assign busy      = ds_busy;

    // done：单拍类的完成拍 = 被接收拍（组合结果已就绪）；div/sqrt 透传其 done
    assign done      = ~flush & (ds_done | disp_sc);
    assign fflags_we = done;

endmodule
