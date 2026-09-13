//=============================================================================
// rv32_alu.v —— RV32 基础整数 ALU（纯组合，组合逻辑，无时钟/无复位）
//
// 一、功能
//   实现 `rtl/pkg/rv32gc_defs.vh` 中 `ALU_ADD .. `ALU_AND 共 10 种运算，
//   供 EX 级 ALU0/ALU1 以及地址生成（AGU）、分支比较等复用。
//   本模块不做任何操作数选择：op_a / op_b 已由流水级按 `ALU_A_*`/`ALU_B_*`
//   选好（rs1/pc/0 与 rs2/imm/4/0/shamt），本模块只做运算。
//
// 二、端口语义
//   alu_op [4:0]  : 运算选择
//                   `ALU_ADD(0)  `ALU_SUB(1)  `ALU_SLL(2)  `ALU_SLT(3)  `ALU_SLTU(4)
//                   `ALU_XOR(5)  `ALU_SRL(6)  `ALU_SRA(7)  `ALU_OR(8)   `ALU_AND(9)
//                   未定义编码（5'd10 ~ 5'd31）由 default 分支输出 0。
//   op_a   [31:0] : 第一操作数（rs1 / pc / 0）
//   op_b   [31:0] : 第二操作数（rs2 / imm / const4 / 0 / imm_shamt）
//   result [31:0] : 运算结果，与输入同拍组合有效
//
// 三、时序（延迟拍数）
//   纯组合逻辑：0 拍（同拍出结果）。无 clk / rst_n 端口，
//   结果在发射拍即有效，由流水级当拍旁路或写回。
//
// 四、边界语义
//   * SLL/SRL/SRA：移位量取 op_b[4:0]（RV32 移位量 5 位），
//     op_b[31:5] 被忽略 ⇒ 移位量 32 等价于 0、63 等价于 31。
//   * SRA 为算术右移（高位补符号位），SRL 为逻辑右移（高位补 0）。
//   * SLT / SLTU：结果为 32'd1 或 32'd0；SLT 按 2 的补码有符号比较，
//     SLTU 无符号比较（两者都覆盖 INT_MIN/INT_MAX 等边界）。
//   * ADD / SUB：32 位模 2^32 环绕，溢出自然回绕，不产生异常。
//   * 所有运算对 op_a/op_b 无对齐、无掩码要求（地址对齐由 AGU/LSU 负责）。
//   * 本模块无异常输出：非法 alu_op 编码只表现为 result=0。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_alu (
  input  wire [4:0]  alu_op,      // `ALU_ADD..`ALU_AND
  input  wire [31:0] op_a,        // 已由流水级选好（rs1/pc/0）
  input  wire [31:0] op_b,        // 已由流水级选好（rs2/imm/4/shamt）
  output reg  [31:0] result
);

  always @(*) begin
    result = 32'd0;                                   // default：避免 latch，非法编码输出 0
    case (alu_op)
      `ALU_ADD:  result = op_a + op_b;
      `ALU_SUB:  result = op_a - op_b;
      `ALU_SLL:  result = op_a << op_b[4:0];          // RV32：移位量 5 位
      `ALU_SLT:  result = ($signed(op_a) < $signed(op_b)) ? 32'd1 : 32'd0;
      `ALU_SLTU: result = (op_a < op_b) ? 32'd1 : 32'd0;
      `ALU_XOR:  result = op_a ^ op_b;
      `ALU_SRL:  result = op_a >> op_b[4:0];
      `ALU_SRA:  result = $signed(op_a) >>> op_b[4:0];
      `ALU_OR:   result = op_a | op_b;
      `ALU_AND:  result = op_a & op_b;
      // Zicond（Zicond ci：rd = (rs2 == 0) ? 0 : rs1 / rd = (rs2 != 0) ? 0 : rs1）
      `ALU_CZERO_EQZ: result = (op_b == 32'd0) ? 32'd0 : op_a;
      `ALU_CZERO_NEZ: result = (op_b != 32'd0) ? 32'd0 : op_a;
      default:   result = 32'd0;                      // 保留编码
    endcase
  end

endmodule
