//=============================================================================
// rv32_imm_gen.v —— RV32GC 立即数生成器（纯组合）
//
// 依据：docs/design/spec/02-uop-and-decode.md §5「立即数生成（imm_gen）」
//
//   imm_type 0 = I         instr[31:20]                          符号扩展
//            1 = S         {instr[31:25], instr[11:7]}          符号扩展
//            2 = B         {instr[31], instr[7], instr[30:25],
//                           instr[11:8], 1'b0}                  符号扩展（13 位）
//            3 = U         {instr[31:12], 12'b0}                低 12 位补 0
//            4 = J         {instr[31], instr[19:12], instr[20],
//                           instr[30:21], 1'b0}                 符号扩展（21 位）
//            5 = SHAMT     {27'b0, instr[24:20]}                零扩展（RV32 只用低 5 位）
//            6 = CSR_ZIMM  {27'b0, instr[19:15]}                零扩展（csrrwi 等 5 位）
//
// 说明：
//   * imm_type 编码值（0..6）由 spec/02 §5 表格顺序固定，rv32_decoder.v 直接使用；
//     imm_type 是 3 位端口，7 为保留值（输出 0，不产生锁存）。
//   * 输入应为 RVC 展开后的 32 位指令（压缩指令的立即数已在展开时拼入 32 位域）。
//   * 本模块无时钟、无复位、无 `initial`/`$display`，纯可综合组合逻辑。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_imm_gen (
  input  wire [31:0] instr,
  input  wire [2:0]  imm_type,
  output reg  [31:0] imm
);

  // 立即数类型编码（与 spec/02 §5 的行序一致）
  localparam [2:0] IMM_I     = 3'd0;
  localparam [2:0] IMM_S     = 3'd1;
  localparam [2:0] IMM_B     = 3'd2;
  localparam [2:0] IMM_U     = 3'd3;
  localparam [2:0] IMM_J     = 3'd4;
  localparam [2:0] IMM_SHAMT = 3'd5;
  localparam [2:0] IMM_CSR   = 3'd6;

  always @(*) begin
    case (imm_type)
      // I 型：符号扩展 instr[31:20]
      IMM_I:     imm = {{20{instr[31]}}, instr[31:20]};
      // S 型：{instr[31:25], instr[11:7]} 符号扩展
      IMM_S:     imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      // B 型：13 位分支偏移（bit0 = 0）
      IMM_B:     imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25],
                        instr[11:8], 1'b0};
      // U 型：高 20 位，低 12 位补 0
      IMM_U:     imm = {instr[31:12], 12'b0};
      // J 型：21 位跳转偏移（bit0 = 0）
      IMM_J:     imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20],
                        instr[30:21], 1'b0};
      // 移位量：零扩展 instr[24:20]
      IMM_SHAMT: imm = {27'b0, instr[24:20]};
      // CSR 立即数（zimm）：零扩展 instr[19:15]
      IMM_CSR:   imm = {27'b0, instr[19:15]};
      // 保留值：输出 0（避免锁存与 x 传播）
      default:   imm = 32'd0;
    endcase
  end

endmodule
