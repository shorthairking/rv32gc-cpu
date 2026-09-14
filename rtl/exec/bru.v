//==============================================================================
// rtl/exec/bru.v —— E 级分支/跳转解析单元（BRU，纯组合，assign / function）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 依据    : docs/design/08-baseline-5stage.md §5.3 E 级表 —— `bru.v`
//             「条件分支判定、jal/jalr 目标计算」；
//             in: rs1, rs2, imm, pc, br_op；out: taken, target；
//             行为要点「E 级解析 → 触发重定向（冲刷 D/M/W 中已取指令）」。
//           §1.2 范围护栏：「2A 的分支处理为**最简单的静态/不预测 + E 级解析**」。
//           AGENT.md §4 红线 3（禁止 `always @(*)` 给多个 reg 赋值）。
// 唯一真源: `RV32GC_BR_*` 编号与 `rtl/pkg/rv32_defs.vh` 的 BRANCH funct3 编号
//           **逐位对齐**（BR_EQ=000..BR_GEU=111，见本文件「编码公约」），
//           使 D 级可直接把 `funct3` 接到 `br_op`，无需再插一级译码表。
//==============================================================================
// 一、功能
//   在 E 级解析条件分支（beq/bne/blt/bge/bltu/bgeu）与无条件跳转（jal/jalr），
//   输出「是否改变控制流」taken 与「目标地址」target。
//   taken=1 ⇒ 提交级之外的前端重定向源；target 送入 F 级 `redirect_pc`。
//   分支条件与目标地址均为**组合产生，与发射拍同拍有效（0 拍延迟）**。
//
// 二、端口
//   rs1    [31:0] : 源寄存器 1（jalr 的基址寄存器；分支时参与比较）
//   rs2    [31:0] : 源寄存器 2（jal/jalr 时无意义，被忽略）
//   imm    [31:0] : 已生成的立即数（B 型 / J 型 / I 型，**已符号扩展**）
//   pc     [31:0] : 本条指令 PC
//   br_op  [4:0]  : 控制选择（见「编码公约」，低位 3 位 = BRANCH 的 funct3）
//   taken         : 是否改变控制流（1 = 重定向）
//   target [31:0] : 跳转目标（taken=0 时也给出 pc+imm，便于预测器/调试观察）
//
// 三、编码公约（br_op[4:0]）
//   ---- 低位 [2:0]：**恒等于 BRANCH 指令的 funct3**（rv32_defs.vh §3.4） ----
//     BR_EQ (3'b000)  BR_NE (3'b001)  BR_LT (3'b100)
//     BR_GE (3'b101)  BR_LTU(3'b110)  BR_GEU(3'b111)   —— 无分支：BR_NONE
//   ---- 高位 [4:3]：跳转类型（与低位正交，可读性优先） ----
//     BRF_J  (bit3) = 该指令是 jal
//     BRF_JR (bit4) = 该指令是 jalr
//   ※ 命名与旧项目 master 的 `BR_*`/`BRF_*` 口径**打通**，便于 2B/锁步比对；
//     但**本文件是真源的使用方**，低位编号严格跟随 funct3（旧项目为自定义编号，
//     本设计改为跟随 funct3，理由：少一级译码、位域改动只需改 pkg）。
//   ★ 关键约束：BR_NONE 必须是「低位非分支码」中**唯一的**无操作编码。
//     实现上对「低位 3 位」做唯一判定，见下 `br_cond` function 的 default 分支。
//
// 四、边界语义 / 优先级（全部按 ISA 定值）
//   * jal  ：taken=1，target = pc + imm。
//       ISA 保证 J 型立即数 bit0=0 ⇒ jal 目标天然 2 B 对齐；
//       本模块**不再额外掩码**（对齐判定归 F/M 级，E 级只算地址；08 §5.3 末句）。
//   * jalr ：taken=1，target = (rs1 + imm) & 32'hFFFF_FFFE（**强制清零 bit0**）。
//       加法按 32 位模 2^32 回绕。bit0 清零是 ISA 硬要求
//       [ISA:riscv-isa-manual/src/unpriv/rv-32-64g.adoc，「The target address is
//        obtained by adding the sign-extended 12-bit I-immediate ... the least-
//        significant bit of the result is always set to zero」]。
//   * 条件分支：taken = 比较结果；target = pc + imm（B 型）。
//       BLT/BGE **有符号**比较（2 的补码）；BLTU/BGEU **无符号**比较；
//       BEQ/BNE 逐位相等/不等。全部覆盖 INT_MIN/INT_MAX 边界。
//   * BR_NONE（普通 ALU/load/store…）：taken=0，target = pc + imm（无副作用，
//      仅供调试观察；消费者**必须**以 taken 为准，不得按 target 重定向）。
//   * jal 与 jalr 同时置位（译码不会产生）：**jal 优先**（本文件给出确定行为）。
//   * 指令地址非对齐异常（cause=0）**不在此模块产生**：本模块只做 bit0 清零；
//     非对齐检测由 F 级在重定向时按目标地址判定（IALIGN=16 ⇒ 检查 bit0）。
//
// 五、实现注记（红线 3 合规声明）
//   * **零 always 块、零 reg**：比较逻辑用 `function`，目标计算用
//     连续 `assign`（08 §7.4；AGENT.md §4 红线 3）。
//   * `$signed()` 显式标注有符号比较，保证 iverilog/Verilator/Vivado
//     三方语义一致（wire [31:0] 默认按无符号比较）。
//   * taken/target 分两条 assign 表达，便于综合与波形定位。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module bru (
    // ---- 操作数 ----
    input  wire [31:0] rs1,        // 源寄存器 1 / jalr 基址
    input  wire [31:0] rs2,        // 源寄存器 2（jal/jalr 忽略）
    input  wire [31:0] imm,        // 立即数（B/J/I 型，已符号扩展）
    input  wire [31:0] pc,         // 本条指令 PC
    // ---- 控制 ----
    input  wire [4:0]  br_op,      // 分支/跳转选择（低 3 位 = BRANCH funct3）
    // ---- 结果 ----
    output wire        taken,      // 1 = 改变控制流（触发重定向）
    output wire [31:0] target      // 目标地址（taken=0 时为 pc+imm）
);

    //--------------------------------------------------------------------------
    // 1. br_op 位域切分（**低 3 位 = BRANCH funct3**，与 pkg §3.4 一致）
    //--------------------------------------------------------------------------
    wire [2:0] br_f3   = br_op[2:0];   // 分支条件码（= 指令 funct3）
    wire       is_jal  = br_op[3];     // 无条件跳转 jal
    wire       is_jalr = br_op[4];     // 无条件跳转 jalr

    //--------------------------------------------------------------------------
    // 2. 条件分支比较（function，纯组合）
    //    ★ 低位 3 位与 funct3 的一一对应关系：
    //       000 beq / 001 bne / 100 blt / 101 bge / 110 bltu / 111 bgeu
    //       010、011 在 BRANCH 中不存在（属 LOAD 等），作为 BR_NONE 的编码。
    //    ★ default ⇒ 0（不跳转）：保证任何未定义编码都不会误触发重定向。
    //--------------------------------------------------------------------------
    localparam [2:0] BR_EQ  = 3'b000;
    localparam [2:0] BR_NE  = 3'b001;
    localparam [2:0] BR_LT  = 3'b100;
    localparam [2:0] BR_GE  = 3'b101;
    localparam [2:0] BR_LTU = 3'b110;
    localparam [2:0] BR_GEU = 3'b111;

    function br_cond;
        input [31:0] f_a;          // rs1
        input [31:0] f_b;          // rs2
        input [2:0]  f_f3;         // 分支条件码
        begin
            case (f_f3)
                BR_EQ : br_cond = (f_a == f_b);
                BR_NE : br_cond = (f_a != f_b);
                // 有符号比较（2 的补码）——必须显式 $signed()
                BR_LT : br_cond = ($signed(f_a) <  $signed(f_b));
                BR_GE : br_cond = ($signed(f_a) >= $signed(f_b));
                // 无符号比较
                BR_LTU: br_cond = (f_a <  f_b);
                BR_GEU: br_cond = (f_a >= f_b);
                // BR_NONE 及保留编码：不跳转（确定行为，防止误重定向）
                default: br_cond = 1'b0;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // 3. 目标地址与 taken（连续 assign）
    //--------------------------------------------------------------------------
    wire [31:0] pc_imm = pc + imm;                          // B 型 / J 型目标
    wire [31:0] jalr_t = (rs1 + imm) & 32'hFFFF_FFFE;       // I 型目标，bit0 清零

    // 条件分支命中（无跳转指令时恒 0）
    wire br_taken = br_cond(rs1, rs2, br_f3);

    // taken：jal > jalr > 条件分支（三选一，互斥；见头注「优先级」）
    assign taken  = is_jal | is_jalr | br_taken;

    // target：jal 与 jalr 均为无条件跳转，二者同时置位时 jal 优先
    assign target = is_jal  ? pc_imm            // jal ：pc + J 型立即数
                  : is_jalr ? jalr_t            // jalr：(rs1 + imm) & ~1
                  :           pc_imm;           // 条件分支 / 非分支：pc + imm

endmodule
