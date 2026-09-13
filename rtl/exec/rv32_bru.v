//=============================================================================
// rv32_bru.v —— 分支/跳转解析单元（BRU，纯组合）
//
// 一、功能
//   在 EX 级解析条件分支（BEQ/BNE/BLT/BGE/BLTU/BGEU）与无条件跳转（JAL/JALR），
//   输出是否跳转 taken 与跳转目标 target，供前端重定向、后端清空（flush）使用。
//   分支条件与目标地址都是组合产生，与发射拍同拍有效（0 拍延迟）。
//
// 二、端口语义
//   br_type [2:0] : `BR_NONE(0) `BR_EQ(1) `BR_NE(2) `BR_LT(3) `BR_GE(4)
//                   `BR_LTU(5) `BR_GEU(6)；未定义编码按不跳转处理。
//   br_flags[3:0] : {is_ret, is_call, is_jalr, is_jal}（位序见 `BRF_RET/CALL/JALR/JAL）
//                   is_ret/is_call 只供返回地址栈（RAS）与预测器使用，
//                   不影响 taken/target 的计算。
//   op_a   [31:0] : rs1（jalr 的基址寄存器；jal/分支时仅用于比较）
//   op_b   [31:0] : rs2（jal/jalr 时无意义，被忽略）
//   pc     [31:0] : 本条指令的 PC
//   imm    [31:0] : 已生成的立即数（J 型 / B 型 / I 型，符号扩展）
//   taken         : 是否改变控制流
//   target[31:0]  : 跳转目标地址（taken=0 的分支也给出 pc+imm，便于预测器/调试）
//
// 三、时序（延迟拍数）
//   纯组合逻辑：0 拍（同拍出结果）；无 clk / rst_n 端口。
//
// 四、边界语义 / 优先级
//   * is_jal  =1：taken=1，target = pc + imm（J 型立即数最低位恒为 0，
//                 因此 JAL 目标天然 2 字节对齐，本模块不再额外掩码）。
//   * is_jalr =1：taken=1，target = (op_a + imm) & 32'hFFFF_FFFE
//                 （强制清零 bit0；加法按 32 位回绕）。
//   * is_jal 优先于 is_jalr（正常译码不会同时置位，此处给出确定行为）。
//   * 条件分支：taken = 比较结果；target = pc + imm。
//       BR_LT/BR_GE  : 有符号比较（2 的补码）
//       BR_LTU/BR_GEU: 无符号比较
//       BR_EQ/BR_NE  : 逐位相等/不等
//   * `BR_NONE 且非 jal/jalr（例如普通 ALU 指令、jal 的 rd=x0 情形之外的
//     非分支指令）：taken=0，target = pc + imm（无副作用）。
//   * 指令地址非对齐异常（cause=0）不在此模块产生：本模块只做 bit0 清零，
//     非对齐检测由 EX 级根据 target[1:0] 与指令类型另行判定。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_bru (
  input  wire [2:0]  br_type,    // `BR_NONE/`BR_EQ/`BR_NE/`BR_LT/`BR_GE/`BR_LTU/`BR_GEU
  input  wire [3:0]  br_flags,   // {is_ret, is_call, is_jalr, is_jal}（位序见 rv32gc_defs.vh 的 BRF_*）
  input  wire [31:0] op_a,       // rs1
  input  wire [31:0] op_b,       // rs2（jal/jalr 时无意义）
  input  wire [31:0] pc,
  input  wire [31:0] imm,
  output reg         taken,
  output reg  [31:0] target
);

  wire        is_jal  = br_flags[`BRF_JAL];
  wire        is_jalr = br_flags[`BRF_JALR];
  wire [31:0] pc_imm = pc + imm;
  wire [31:0] jalr_t = (op_a + imm) & 32'hFFFF_FFFE;   // JALR：bit0 清零

  //-----------------------------------------------------------------------------
  // 条件比较（组合，default 不跳转）
  //-----------------------------------------------------------------------------
  reg cmp;
  always @(*) begin
    cmp = 1'b0;
    case (br_type)
      `BR_EQ:   cmp = (op_a == op_b);
      `BR_NE:   cmp = (op_a != op_b);
      `BR_LT:   cmp = ($signed(op_a) <  $signed(op_b));
      `BR_GE:   cmp = ($signed(op_a) >= $signed(op_b));
      `BR_LTU:  cmp = (op_a <  op_b);
      `BR_GEU:  cmp = (op_a >= op_b);
      default:  cmp = 1'b0;                            // `BR_NONE 及保留编码
    endcase
  end

  //-----------------------------------------------------------------------------
  // taken / target 选择（jal > jalr > 条件分支）
  //-----------------------------------------------------------------------------
  always @(*) begin
    if (is_jal) begin
      taken  = 1'b1;
      target = pc_imm;
    end else if (is_jalr) begin
      taken  = 1'b1;
      target = jalr_t;
    end else begin
      taken  = cmp;
      target = pc_imm;
    end
  end

endmodule
