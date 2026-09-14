//==============================================================================
// rtl/exec/alu.v —— E 级整数 ALU（纯组合，assign / function）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 依据    : docs/design/08-baseline-5stage.md §5.3 E 级表 —— `alu.v`
//             「整数算术/逻辑/移位/比较；lui/auipc」；
//             in: a, b, alu_op, pc；out: result；**纯组合，assign/function 为主**。
//           AGENT.md §4 红线 3（禁止 `always @(*)` 给多个 reg 赋值）。
// 唯一真源: 本模块**不新增任何编码**；`RV32GC_ALU_*` 的编号即
//           `rtl/pkg/rv32_defs.vh` 的 alu_op 编码（见本文件「编码公约」）。
// 引用    : [ISA:riscv-isa-manual/src/unpriv/rv-32-64g.adoc] 整数指令语义；
//           [DOC:docs/kb/isa-notes.md]；[ENC:binutils riscv-opc.h MATCH/MASK]。
//==============================================================================
// 一、功能
//   实现 RV32I 整数 ALU 全部运算：add/sub/sll/slt/sltu/xor/srl/sra/or/and
//   （寄存器型与立即数型共用），以及 `lui`/`auipc` 的立即数装载。
//   本模块**不做任何操作数选择**：a/b 已由 D 级/E 级按 `ALU_A_*`/`ALU_B_*`
//   选好（rs1/pc/0 与 rs2/imm/4），本模块只做「运算」。
//
// 二、端口
//   a      [31:0] : 第一操作数（rs1 / pc）
//   b      [31:0] : 第二操作数（rs2 / imm）
//   alu_op [3:0]  : 运算选择（见下「编码公约」）
//   pc     [31:0] : 本条指令 PC，**仅供 auipc**（result = pc + imm，imm 由 b 传入）
//   result [31:0] : 运算结果，与输入同拍组合有效（0 拍延迟）
//
// 三、编码公约（alu_op，与 rv32_defs.vh 的 ALU 编码一一对应）
//   ALU_ADD(0)  ALU_SUB(1)  ALU_SLL(2)  ALU_SLT(3)  ALU_SLTU(4)
//   ALU_XOR(5)  ALU_SRL(6)  ALU_SRA(7)  ALU_OR(8)   ALU_AND(9)
//   ALU_LUI(10) ALU_AUIPC(11)
//   ※ 未定义编码（12–15）⇒ result = 0（确定行为，无 latch、无异常）。
//   ※ lui/auipc 之所以放在 ALU 而不是别处：二者都是「立即数装载」，
//     与 ALU 共用 E 级单发射口（08 §5.3 首句「共享单发射口，每拍只派一条」）。
//     auipc 必须拿 pc，故本模块**带 pc 输入**（与 08 §5.3 端口表一致）。
//
// 四、边界语义（全部按 ISA 定值，无歧义）
//   * ADD/SUB：32 位模 2^32 回绕，**不产生异常**（溢出由软件判断）。
//   * SLL/SRL/SRA：移位量取 b[4:0]（RV32 移位量 5 位）；
//       b[31:5] 被忽略 ⇒ 移位 32 等价于 0、移位 63 等价于 31（ISA：移位量按
//       XLEN 取模，RV32 即 mod 32）。已覆盖 `slli/srli/srai` 的立即数路径。
//   * SRA 为算术右移（高位补符号位）；SRL 为逻辑右移（高位补 0）。
//   * SLT/SLTU：结果恒为 32'd1 或 32'd0（不是 -1）；
//       SLT 按 2 的补码**有符号**比较，SLTU **无符号**比较；
//       两者均覆盖 INT_MIN/INT_MAX 边界（`$signed()` 显式标注，避免综合器
//       对混合有无符号位宽扩展做出与仿真不同的推断 —— 见下「实现注记」）。
//   * LUI  ：result = b（b 端口由 D 级接入 U 型立即数 imm[31:12]<<12）。
//   * AUIPC：result = pc + b。
//   * 本模块**无异常输出**：地址非对齐（cause 4/6）在 M 级判定（08 §5.3 末句
//     「非对齐：E 级只做地址计算；非对齐判定与优先级在 M 级」）；
//     非法 alu_op 只表现为 result=0。
//
// 五、实现注记（红线 3 合规声明）
//   * **零 `always` 块、零 reg**：全部组合逻辑由 `function` +
//     单条 `assign` 表达（AGENT.md §4 红线 3、08 §7.4）。
//   * 用 `function` 而非 `always @(*)`：function 无状态、无敏感表、不可能
//     综合出 latch，且可在其它模块（如 tb、bru）中复用比较语义。
//   * `$signed()` 的使用：Verilog 中 `a < b` 在两者均为 `wire [31:0]` 时按
//     无符号比较；有符号比较必须显式 `$signed()`（或声明 signed 端口）。
//     本模块显式转换，保证 iverilog/Verilator/Vivado 三方语义一致。
//==============================================================================
`timescale 1ns / 1ps

// ---- include：先 rv32_defs.vh 后 core_params.vh（08 §3.3；pkg 依赖方向固定） ----
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module alu (
    // ---- 操作数 ----
    input  wire [31:0] a,          // 第一操作数：rs1 / pc（auipc）
    input  wire [31:0] b,          // 第二操作数：rs2 / imm
    // ---- 控制 ----
    input  wire [3:0]  alu_op,     // 运算选择（见头注「编码公约」）
    input  wire [31:0] pc,         // 本条指令 PC（仅 auipc 使用）
    // ---- 结果 ----
    output wire [31:0] result      // 组合结果，同拍有效
);

    //--------------------------------------------------------------------------
    // 1. alu_op 局部编码（**与 rv32_defs.vh 的 ALU 编号严格一致**）
    //    这里用 localparam 而非 `define：本文件不是真源，编码真源在 pkg；
    //    此处只做「可读的镜像」，避免在 15 处比较里散落裸数字。
    //--------------------------------------------------------------------------
    localparam [3:0] ALU_ADD   = 4'd0;
    localparam [3:0] ALU_SUB   = 4'd1;
    localparam [3:0] ALU_SLL   = 4'd2;
    localparam [3:0] ALU_SLT   = 4'd3;
    localparam [3:0] ALU_SLTU  = 4'd4;
    localparam [3:0] ALU_XOR   = 4'd5;
    localparam [3:0] ALU_SRL   = 4'd6;
    localparam [3:0] ALU_SRA   = 4'd7;
    localparam [3:0] ALU_OR    = 4'd8;
    localparam [3:0] ALU_AND   = 4'd9;
    localparam [3:0] ALU_LUI   = 4'd10;
    localparam [3:0] ALU_AUIPC = 4'd11;

    //--------------------------------------------------------------------------
    // 2. 组合逻辑：function 实现（无 always、无 reg）
    //    单一 function 覆盖全部运算，最后一条 assign 落地到 result。
    //--------------------------------------------------------------------------
    function [31:0] alu_calc;
        input [31:0] f_a;          // 第一操作数
        input [31:0] f_b;          // 第二操作数
        input [3:0]  f_op;         // 运算选择
        input [31:0] f_pc;         // PC（auipc）
        begin
            case (f_op)
                ALU_ADD  : alu_calc = f_a + f_b;
                ALU_SUB  : alu_calc = f_a - f_b;
                // RV32：移位量仅取低 5 位（移位 32 ≡ 0、63 ≡ 31）
                ALU_SLL  : alu_calc = f_a << f_b[4:0];
                // 有符号比较：结果必须是 0/1（不是全 1）
                ALU_SLT  : alu_calc = ($signed(f_a) < $signed(f_b)) ? 32'd1 : 32'd0;
                ALU_SLTU : alu_calc = (f_a < f_b) ? 32'd1 : 32'd0;
                ALU_XOR  : alu_calc = f_a ^ f_b;
                ALU_SRL  : alu_calc = f_a >> f_b[4:0];
                ALU_SRA  : alu_calc = $signed(f_a) >>> f_b[4:0];
                ALU_OR   : alu_calc = f_a | f_b;
                ALU_AND  : alu_calc = f_a & f_b;
                // lui ：U 型立即数已由 D 级左移 12 位并经 b 端口送入
                ALU_LUI  : alu_calc = f_b;
                // auipc：pc + U 型立即数（同样经 b 端口送入）
                ALU_AUIPC: alu_calc = f_pc + f_b;
                // 未定义编码：确定输出 0（无 latch；译码器保证不出现）
                default  : alu_calc = 32'd0;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // 3. 结果落地：唯一一条 assign（function 为纯组合，无副作用）
    //--------------------------------------------------------------------------
    assign result = alu_calc(a, b, alu_op, pc);

endmodule
