//=============================================================================
// rv32_mul_div.v —— RV32M 乘法/除法执行单元（MDU）
//
// 一、功能
//   * 乘法族（`MDU_MUL / `MDU_MULH / `MDU_MULHSU / `MDU_MULHU）：
//     用 32x32 有/无符号乘法（RTL 写法为 `a*b` 风格的 64 位乘积，交由综合器
//     推断 DSP48E1 硬核）实现，取 64 位乘积的对应半部。
//   * 除法族（`MDU_DIV / `MDU_DIVU / `MDU_REM / `MDU_REMU）：
//     自行实现基 2 恢复余数迭代（不例化任何 Xilinx IP），32 拍完成。
//   * 输入操作数 a/b 与 mdu_op 必须在 start 被接收的那一拍有效
//     （在接收时钟沿采样），接收后即可变化。
//
// 二、端口语义
//   clk / rst_n  : 单时钟；rst_n 低有效同步复位（复位回 IDLE，busy=done=0）
//   start        : 单拍脉冲；仅当 !busy 时被接收（busy 期间的 start 被忽略）
//   mdu_op [2:0] : `MDU_MUL(0)=低32位  `MDU_MULH(1)=有符号x有符号 高32位
//                  `MDU_MULHSU(2)=有符号x无符号 高32位
//                  `MDU_MULHU(3)=无符号x无符号 高32位
//                  `MDU_DIV(4) `MDU_DIVU(5) `MDU_REM(6) `MDU_REMU(7)
//   a / b [31:0] : 被除数/除数，或乘法两个操作数
//   busy         : 运算进行中（start 被接收后的下一拍拉高）
//   done         : 结果有效的单拍脉冲，与 result 同拍
//   result [31:0]: 运算结果（done=1 的那一拍有效）
//
// 三、时序（本模块实际采用的延迟，testbench 按此检查）
//   设 start 在时钟沿 E0 被接收（该拍 busy=0），用"拍"表示 E0 之后的第 n 个
//   时钟周期：
//     * E0 的下一拍 busy 拉高；
//     * 乘法族：E0 之后第 3 拍 done=1（3 级流水：乘积寄存器 -> 乘积寄存器 ->
//       结果寄存器），busy 与 done 不同拍：done 的那一拍 busy=0；
//     * 除法族：E0 之后第 33 拍 done=1（32 拍迭代 + 1 拍结果输出），
//       busy 在迭代期间保持 32 拍；
//     * 统一约定：done 与 result 同拍有效，done 为单拍脉冲，且 done 拍 busy=0
//       ⇒ 消费者可在 done 的同拍立刻发起下一次 start（背靠背），
//       乘法背靠背吞吐 = 3 拍/条，除法为阻塞式（迭代期间 busy=1，不接受新 start）。
//     * 除零等特例不改变时序：所有除法一律 32 拍迭代，延迟恒定。
//
// 四、边界语义（RISC-V 规范，全部在 result 组合/末尾修正中处理）
//   (1) 除零：b==0 时 DIV/DIVU 商 = 32'hFFFF_FFFF；REM/REMU 余数 = 被除数 a；
//   (2) 有符号溢出 INT_MIN / -1（a=32'h8000_0000, b=32'hFFFF_FFFF）：
//       DIV 商 = 32'h8000_0000（= INT_MIN），REM 余数 = 0；
//   (3) 有符号除法向零取整，余数符号与被除数相同
//       （由"取绝对值迭代 + 末尾按符号取反"实现）；
//   (4) MUL=乘积低 32 位；MULH=(signed a)x(signed b) 高 32 位；
//       MULHSU=(signed a)x(unsigned b) 高 32 位；MULHU=(unsigned a)x(unsigned b) 高 32 位；
//   (5) 未定义 mdu_op 不会出现（译码保证），若有则按除法路径处理并输出按
//       REMU 语义的结果；本模块不产生异常。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_mul_div (
  input  wire        clk,
  input  wire        rst_n,      // 同步复位，低有效
  input  wire        start,      // 单拍脉冲，仅在 !busy 时被接受
  input  wire [2:0]  mdu_op,     // `MDU_MUL/`MDU_MULH/`MDU_MULHSU/`MDU_MULHU/`MDU_DIV/`MDU_DIVU/`MDU_REM/`MDU_REMU
  input  wire [31:0] a,
  input  wire [31:0] b,
  output reg         busy,       // start 之后拉高，直到 done
  output reg         done,       // 与 result 同拍的单拍脉冲
  output reg  [31:0] result
);

  //-----------------------------------------------------------------------------
  // 状态与流水寄存器
  //-----------------------------------------------------------------------------
  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_MUL  = 2'd1;
  localparam [1:0] S_DIV  = 2'd2;

  reg [1:0]  state_q;

  // 乘法流水线（3 级：mul_p1_q -> mul_p2_q -> result）
  reg [63:0] mul_p1_q;        // 第 1 级：启动沿捕获的 64 位乘积
  reg [63:0] mul_p2_q;        // 第 2 级
  reg        mul_hi_q;        // 与 p1 同拍：1=取乘积高 32 位（MULH/MULHSU/MULHU）
  reg        mul_hi2_q;       // 与 p2 同拍
  reg [1:0]  mul_cnt_q;       // 剩余流水拍数：启动置 1，减到 0 时出结果

  // 除法迭代寄存器（基 2 恢复余数，MSB 先出）
  reg [31:0] div_dvd_q;       // 剩余被除数（每拍左移 1 位）
  reg [31:0] div_rem_q;       // 余数低 32 位（不变式：rem < 除数 <= 2^32-1，故 32 位足够）
  reg [30:0] div_quo_q;       // 商移位寄存器低 31 位（第 32 位由 quo_nx[31] 在末拍产生）
  reg [31:0] div_dvs_q;       // 除数绝对值
  reg [31:0] div_dvd0_q;      // 原始被除数（除零时 REM/REMU 返回它）
  reg        div_sgn_a_q;     // 被除数符号（有符号除）
  reg        div_sgn_b_q;     // 除数符号
  reg        div_signed_q;    // 1=有符号 DIV/REM
  reg        div_is_rem_q;    // 1=REM/REMU
  reg [4:0]  div_cnt_q;       // 剩余迭代次数-1（31..0）

  //-----------------------------------------------------------------------------
  // 命令译码（组合，仅在 start 被接收的那一拍有效）
  //-----------------------------------------------------------------------------
  wire is_mul = (mdu_op == `MDU_MUL)   || (mdu_op == `MDU_MULH) ||
                (mdu_op == `MDU_MULHSU)|| (mdu_op == `MDU_MULHU);

  // 乘法符号扩展：MULH/MULHSU 的 a 视为有符号，MULH 的 b 视为有符号。
  // 先扩展到 64 位再做乘法，避免条件表达式位宽不一致导致的符号位丢失。
  wire               mul_sgn_a = (mdu_op == `MDU_MULH) || (mdu_op == `MDU_MULHSU);
  wire               mul_sgn_b = (mdu_op == `MDU_MULH);
  wire signed [63:0] mul_x = mul_sgn_a ? $signed({{32{a[31]}}, a}) : $signed({32'd0, a});
  wire signed [63:0] mul_y = mul_sgn_b ? $signed({{32{b[31]}}, b}) : $signed({32'd0, b});

  // 除法启动拍取绝对值与符号（INT_MIN 取绝对值后为 32'h8000_0000，仍在 32 位内）
  wire        div_signed = (mdu_op == `MDU_DIV) || (mdu_op == `MDU_REM);
  wire        div_is_rem = (mdu_op == `MDU_REM) || (mdu_op == `MDU_REMU);
  wire        div_sgn_a  = div_signed && a[31];
  wire        div_sgn_b  = div_signed && b[31];
  wire [31:0] div_mag_a  = div_sgn_a ? (~a + 32'd1) : a;
  wire [31:0] div_mag_b  = div_sgn_b ? (~b + 32'd1) : b;

  //-----------------------------------------------------------------------------
  // 除法迭代组合逻辑：{rem,quo,dvd} 的一步恢复余数
  //   rem_sh = rem<<1 | 被除数最高位；rem_sh >= 除数 则减并商 1，否则商 0
  //   位宽说明：比较写成 33 位（rem_sh 比除数多一位），保证移位后与除数同宽比较；
  //   不变式 rem < 除数（余数）且 rem < 2^31（rem 是"已处理前缀 mod 除数"，而
  //   第 k 步前缀值 < 2^k <= 2^31）⇒ 寄存器 32 位足够、rem_sh[32] 恒为 0；
  //   相减在 32 位模 2^32 下进行，真值 < 除数 < 2^32，结果与模运算一致。
  //-----------------------------------------------------------------------------
  wire [32:0] rem_sh = {div_rem_q, div_dvd_q[31]};
  wire        rem_ge = (rem_sh >= {1'b0, div_dvs_q});
  wire [31:0] rem_nx = rem_ge ? (rem_sh[31:0] - div_dvs_q) : rem_sh[31:0];
  wire [31:0] quo_nx = {div_quo_q, rem_ge};

  //-----------------------------------------------------------------------------
  // 除法最终结果：符号修正 + 除零特例
  //-----------------------------------------------------------------------------
  wire        div_zero = (div_dvs_q == 32'd0);
  wire [31:0] rem_mag  = rem_nx;
  wire [31:0] quo_fin  = (div_sgn_a_q ^ div_sgn_b_q) ? (~quo_nx + 32'd1) : quo_nx;
  wire [31:0] rem_fin  = div_sgn_a_q ? (~rem_mag + 32'd1) : rem_mag;
  wire [31:0] div_res  = div_is_rem_q
                       ? (div_zero ? div_dvd0_q : (div_signed_q ? rem_fin : rem_mag))
                       : (div_zero ? 32'hFFFF_FFFF : (div_signed_q ? quo_fin : quo_nx));

  //-----------------------------------------------------------------------------
  // 主状态机（同步复位，低有效 rst_n）
  //-----------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state_q      <= S_IDLE;
      busy         <= 1'b0;
      done         <= 1'b0;
      result       <= 32'd0;
      mul_p1_q     <= 64'd0;
      mul_p2_q     <= 64'd0;
      mul_hi_q     <= 1'b0;
      mul_hi2_q    <= 1'b0;
      mul_cnt_q    <= 2'd0;
      div_dvd_q    <= 32'd0;
      div_rem_q    <= 32'd0;
      div_quo_q    <= 31'd0;
      div_dvs_q    <= 32'd0;
      div_dvd0_q   <= 32'd0;
      div_sgn_a_q  <= 1'b0;
      div_sgn_b_q  <= 1'b0;
      div_signed_q <= 1'b0;
      div_is_rem_q <= 1'b0;
      div_cnt_q    <= 5'd0;
    end else begin
      done <= 1'b0;                                   // done 为单拍脉冲

      case (state_q)
        //---------------------------------------------------------------------
        S_IDLE: begin
          if (start) begin
            busy <= 1'b1;                             // start 之后下一拍 busy=1
            if (is_mul) begin
              state_q   <= S_MUL;
              mul_p1_q  <= mul_x * mul_y;             // 第 1 级：64 位乘积
              mul_hi_q  <= (mdu_op != `MDU_MUL);      // 仅 MUL 取低 32 位
              mul_cnt_q <= 2'd1;                      // 再 2 拍后出结果（共 3 拍）
            end else begin
              state_q      <= S_DIV;
              div_dvd_q    <= div_mag_a;
              div_rem_q    <= 32'd0;
              div_quo_q    <= 31'd0;
              div_dvs_q    <= div_mag_b;
              div_dvd0_q   <= a;
              div_sgn_a_q  <= div_sgn_a;
              div_sgn_b_q  <= div_sgn_b;
              div_signed_q <= div_signed;
              div_is_rem_q <= div_is_rem;
              div_cnt_q    <= 5'd31;                  // 32 拍迭代
            end
          end
        end
        //---------------------------------------------------------------------
        S_MUL: begin
          mul_p2_q  <= mul_p1_q;                      // 第 2 级
          mul_hi2_q <= mul_hi_q;
          if (mul_cnt_q == 2'd0) begin
            result  <= mul_hi2_q ? mul_p2_q[63:32] : mul_p2_q[31:0];  // 第 3 级
            busy    <= 1'b0;
            done    <= 1'b1;
            state_q <= S_IDLE;
          end else begin
            mul_cnt_q <= mul_cnt_q - 2'd1;
          end
        end
        //---------------------------------------------------------------------
        S_DIV: begin
          if (div_cnt_q == 5'd0) begin                // 第 32 次迭代：直接出结果
            result  <= div_res;
            busy    <= 1'b0;
            done    <= 1'b1;
            state_q <= S_IDLE;
          end else begin
            div_cnt_q <= div_cnt_q - 5'd1;
            div_rem_q <= rem_nx;
            div_quo_q <= quo_nx[30:0];      // 最高位在末拍由 quo_nx[31] 产生
            div_dvd_q <= {div_dvd_q[30:0], 1'b0};
          end
        end
        //---------------------------------------------------------------------
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
