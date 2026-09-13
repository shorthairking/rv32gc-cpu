//=============================================================================
// tb_exec_units.v —— 执行单元单元测试（rv32_alu / rv32_mul_div / rv32_bru）
//
// 覆盖范围
//   ALU : 10 种运算 × 24 组随机向量；16 组边界操作数 × 10 种运算；
//         移位量边界 0/1/15/16/31/32/33/63（验证 RV32 低 5 位截断）；
//         有符号/无符号比较边界（0、-1、INT_MIN、INT_MAX）
//   MDU : 8 种模式（MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU）各 14 组边界
//         + 24 组随机 = 38 组/模式；乘法用 testbench 内 64 位参考乘积比对；
//         除法覆盖除零、INT_MIN/-1、负数、随机；每组都检查 busy/done 时序、
//         延迟拍数、done 单拍、done 拍 busy=0；另有"忙时忽略 start"与
//         "done 同拍背靠背发射"两项协议检查
//   BRU : 6 种条件分支 × 8 组操作数（正反例齐备）+ BR_NONE；
//         jal / jalr（含目标 2 字节对齐、bit0 清零、32 位回绕、保留位不影响）
//
// 期望值全部由本 testbench 独立计算（$signed/$unsigned、64 位扩展乘积、
// 规范特例），不使用被测模块的输出作为期望值。
//
// 时序约定（与 rv32_mul_div.v 头注释一致）：
//   start 被接收的那一拍记为第 0 拍 ⇒ 乘法第 3 拍 done=1、除法第 33 拍 done=1，
//   done 与 result 同拍有效、为单拍脉冲，且 done 拍 busy=0。
//=============================================================================
`timescale 1ns/1ps
`include "rv32gc_defs.vh"

module tb_exec_units;

  //-----------------------------------------------------------------------------
  // 记分与公共信号
  //-----------------------------------------------------------------------------
  integer checks;
  integer errors;
  integer i;
  integer mi;
  integer c0;

  reg clk;
  reg rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // br_flags 组合（{is_ret, is_call, is_jalr, is_jal}）
  localparam [3:0] FL_NONE     = 4'b0000;
  localparam [3:0] FL_JAL      = 4'b0001;
  localparam [3:0] FL_JALR     = 4'b0010;
  localparam [3:0] FL_CALL_JAL = 4'b0101;
  localparam [3:0] FL_CALL_JALR= 4'b0110;
  localparam [3:0] FL_RET      = 4'b1000;
  localparam [3:0] FL_RET_JALR = 4'b1010;

  //-----------------------------------------------------------------------------
  // DUT 端口
  //-----------------------------------------------------------------------------
  reg  [4:0]  alu_op;
  reg  [31:0] alu_a, alu_b;
  wire [31:0] alu_res;

  reg         mdu_start;
  reg  [2:0]  mdu_op;
  reg  [31:0] mdu_a, mdu_b;
  wire        mdu_busy, mdu_done;
  wire [31:0] mdu_res;

  reg  [2:0]  bru_type;
  reg  [3:0]  bru_flags;
  reg  [31:0] bru_a, bru_b, bru_pc, bru_imm;
  wire        bru_taken;
  wire [31:0] bru_target;

  rv32_alu u_alu (
    .alu_op (alu_op),
    .op_a   (alu_a),
    .op_b   (alu_b),
    .result (alu_res)
  );

  rv32_mul_div u_mdu (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (mdu_start),
    .mdu_op (mdu_op),
    .a      (mdu_a),
    .b      (mdu_b),
    .busy   (mdu_busy),
    .done   (mdu_done),
    .result (mdu_res)
  );

  rv32_bru u_bru (
    .br_type  (bru_type),
    .br_flags (bru_flags),
    .op_a     (bru_a),
    .op_b     (bru_b),
    .pc       (bru_pc),
    .imm      (bru_imm),
    .taken    (bru_taken),
    .target   (bru_target)
  );

  //=============================================================================
  // 参考模型（独立于 DUT）
  //=============================================================================
  // ---- ALU ----
  function [31:0] alu_ref;
    input [4:0]  op;
    input [31:0] x;
    input [31:0] y;
    reg   [31:0] r;
    begin
      r = 32'd0;
      case (op)
        `ALU_ADD:  r = x + y;
        `ALU_SUB:  r = x - y;
        `ALU_SLL:  r = x << y[4:0];
        `ALU_SLT:  r = ($signed(x) <  $signed(y)) ? 32'd1 : 32'd0;
        `ALU_SLTU: r = (x <  y) ? 32'd1 : 32'd0;
        `ALU_XOR:  r = x ^ y;
        `ALU_SRL:  r = x >> y[4:0];
        `ALU_SRA:  r = $signed(x) >>> y[4:0];
        `ALU_OR:   r = x | y;
        `ALU_AND:  r = x & y;
        default:   r = 32'd0;
      endcase
      alu_ref = r;
    end
  endfunction

  // ---- MDU ----
  // 乘法：先把操作数扩展到 64 位（有符号则符号扩展、无符号则零扩展）再相乘，
  //       结果取低 64 位后再选半部，与规范定义逐位一致。
  function [31:0] mdu_ref;
    input [2:0]  op;
    input [31:0] x;
    input [31:0] y;
    reg  signed [31:0] sx;
    reg  signed [31:0] sy;
    reg  [63:0] p;
    begin
      sx = x;
      sy = y;
      p  = 64'd0;
      case (op)
        `MDU_MUL: begin
          p = {32'd0, x} * {32'd0, y};
          mdu_ref = p[31:0];
        end
        `MDU_MULH: begin
          p = $signed({{32{x[31]}}, x}) * $signed({{32{y[31]}}, y});
          mdu_ref = p[63:32];
        end
        `MDU_MULHSU: begin
          p = $signed({{32{x[31]}}, x}) * $signed({32'd0, y});
          mdu_ref = p[63:32];
        end
        `MDU_MULHU: begin
          p = {32'd0, x} * {32'd0, y};
          mdu_ref = p[63:32];
        end
        `MDU_DIV: begin
          if (y == 32'd0)
            mdu_ref = 32'hFFFF_FFFF;                                  // 除零：商 = -1
          else if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF)
            mdu_ref = 32'h8000_0000;                                  // 溢出：INT_MIN
          else
            mdu_ref = sx / sy;                                        // 向零取整
        end
        `MDU_DIVU: begin
          if (y == 32'd0) mdu_ref = 32'hFFFF_FFFF;
          else            mdu_ref = x / y;
        end
        `MDU_REM: begin
          if (y == 32'd0)
            mdu_ref = x;                                              // 除零：余 = 被除数
          else if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF)
            mdu_ref = 32'd0;                                          // 溢出：余 = 0
          else
            mdu_ref = sx % sy;                                        // 余数符号同被除数
        end
        `MDU_REMU: begin
          if (y == 32'd0) mdu_ref = x;
          else            mdu_ref = x % y;
        end
        default: mdu_ref = 32'd0;
      endcase
    end
  endfunction

  // ---- BRU ----
  function bru_ref;
    input [2:0]  bt;
    input [31:0] x;
    input [31:0] y;
    begin
      case (bt)
        `BR_EQ:  bru_ref = (x == y);
        `BR_NE:  bru_ref = (x != y);
        `BR_LT:  bru_ref = ($signed(x) <  $signed(y));
        `BR_GE:  bru_ref = ($signed(x) >= $signed(y));
        `BR_LTU: bru_ref = (x <  y);
        `BR_GEU: bru_ref = (x >= y);
        default: bru_ref = 1'b0;
      endcase
    end
  endfunction

  //=============================================================================
  // 检查任务
  //=============================================================================
  task alu_check;
    input [4:0]  op;
    input [31:0] x;
    input [31:0] y;
    reg   [31:0] exp;
    begin
      alu_op = op;
      alu_a  = x;
      alu_b  = y;
      #1;
      exp    = alu_ref(op, x, y);
      checks = checks + 1;
      if (alu_res !== exp) begin
        errors = errors + 1;
        $display("[FAIL] ALU op=%0d a=%08x b=%08x got=%08x exp=%08x",
                 op, x, y, alu_res, exp);
      end
    end
  endtask

  // 16 组边界操作数 × 任意运算
  task alu_bounds;
    input [4:0] op;
    begin
      alu_check(op, 32'h0000_0000, 32'h0000_0000);
      alu_check(op, 32'h0000_0000, 32'hFFFF_FFFF);
      alu_check(op, 32'hFFFF_FFFF, 32'h0000_0000);
      alu_check(op, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
      alu_check(op, 32'h8000_0000, 32'h8000_0000);
      alu_check(op, 32'h8000_0000, 32'hFFFF_FFFF);   // INT_MIN vs -1
      alu_check(op, 32'h7FFF_FFFF, 32'h0000_0001);   // INT_MAX vs 1
      alu_check(op, 32'h8000_0000, 32'h0000_0000);
      alu_check(op, 32'h0000_0001, 32'h8000_0000);
      alu_check(op, 32'h1234_5678, 32'h9ABC_DEF0);
      alu_check(op, 32'h7FFF_FFFF, 32'h7FFF_FFFF);
      alu_check(op, 32'h8000_0000, 32'h7FFF_FFFF);
      alu_check(op, 32'hFFFF_FFFE, 32'h0000_0002);
      alu_check(op, 32'h0000_FFFF, 32'h0001_0000);
      alu_check(op, 32'h5555_5555, 32'hAAAA_AAAA);
      alu_check(op, 32'hAAAA_AAAA, 32'h5555_5555);
    end
  endtask

  // 移位量边界：0/1/15/16/31/32/33/63（32 以上按低 5 位截断）
  task alu_shift_bounds;
    begin
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd0);
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd1);
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd15);
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd16);
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd31);
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd32);   // 截断为 0
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd33);   // 截断为 1
      alu_check(`ALU_SLL, 32'h8000_0001, 32'd63);   // 截断为 31
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd0);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd1);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd15);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd16);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd31);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd32);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd33);
      alu_check(`ALU_SRL, 32'h8000_0001, 32'd63);
      alu_check(`ALU_SRA, 32'h8000_0001, 32'd0);
      alu_check(`ALU_SRA, 32'h8000_0001, 32'd1);
      alu_check(`ALU_SRA, 32'hDEAD_BEEF, 32'd15);
      alu_check(`ALU_SRA, 32'hDEAD_BEEF, 32'd16);
      alu_check(`ALU_SRA, 32'h8000_0001, 32'd31);
      alu_check(`ALU_SRA, 32'h8000_0001, 32'd32);   // 截断为 0（结果 = 原值）
      alu_check(`ALU_SRA, 32'h8000_0001, 32'd33);   // 截断为 1
      alu_check(`ALU_SRA, 32'h8000_0001, 32'd63);   // 截断为 31
    end
  endtask

  // 有符号/无符号比较边界
  task alu_cmp_bounds;
    begin
      alu_check(`ALU_SLT,  32'h0000_0000, 32'h0000_0000);
      alu_check(`ALU_SLT,  32'h0000_0000, 32'hFFFF_FFFF);   // 0 < -1 ?
      alu_check(`ALU_SLT,  32'hFFFF_FFFF, 32'h0000_0000);   // -1 < 0 ?
      alu_check(`ALU_SLT,  32'h8000_0000, 32'h7FFF_FFFF);   // INT_MIN < INT_MAX
      alu_check(`ALU_SLT,  32'h7FFF_FFFF, 32'h8000_0000);
      alu_check(`ALU_SLT,  32'h8000_0000, 32'hFFFF_FFFF);   // INT_MIN < -1
      alu_check(`ALU_SLT,  32'hFFFF_FFFF, 32'h8000_0000);
      alu_check(`ALU_SLT,  32'hFFFF_FFFF, 32'hFFFF_FFFE);   // -1 < -2 ?
      alu_check(`ALU_SLT,  32'h0000_0001, 32'hFFFF_FFFF);
      alu_check(`ALU_SLT,  32'h7FFF_FFFF, 32'h0000_0001);
      alu_check(`ALU_SLTU, 32'h0000_0000, 32'h0000_0000);
      alu_check(`ALU_SLTU, 32'h0000_0000, 32'hFFFF_FFFF);
      alu_check(`ALU_SLTU, 32'hFFFF_FFFF, 32'h0000_0000);
      alu_check(`ALU_SLTU, 32'h8000_0000, 32'h7FFF_FFFF);
      alu_check(`ALU_SLTU, 32'h7FFF_FFFF, 32'h8000_0000);
      alu_check(`ALU_SLTU, 32'h8000_0000, 32'hFFFF_FFFF);
      alu_check(`ALU_SLTU, 32'hFFFF_FFFF, 32'h8000_0000);
      alu_check(`ALU_SLTU, 32'hFFFF_FFFF, 32'hFFFF_FFFE);
      alu_check(`ALU_SLTU, 32'h0000_0001, 32'hFFFF_FFFF);
      alu_check(`ALU_SLTU, 32'h7FFF_FFFF, 32'h0000_0001);
    end
  endtask

  //=============================================================================
  // MDU 检查：一次完整的 start → busy → done → result 事务
  //=============================================================================
  task mdu_check;
    input [2:0]  op;
    input [31:0] x;
    input [31:0] y;
    reg   [31:0] exp;
    integer      n;
    integer      exp_lat;
    begin
      exp     = mdu_ref(op, x, y);
      exp_lat = (op <= `MDU_MULHU) ? 3 : 33;

      @(negedge clk);
      mdu_start = 1'b1;
      mdu_op    = op;
      mdu_a     = x;
      mdu_b     = y;

      @(negedge clk);                      // start 之后第 1 拍
      mdu_start = 1'b0;

      checks = checks + 1;
      if (mdu_busy !== 1'b1) begin
        errors = errors + 1;
        $display("[FAIL] MDU op=%0d: start 之后下一拍 busy 未拉高", op);
      end

      // 等待 done（容错上限 200 拍）
      n = 1;
      while ((mdu_done !== 1'b1) && (n < 200)) begin
        @(negedge clk);
        n = n + 1;
      end

      checks = checks + 1;
      if (mdu_done !== 1'b1) begin
        errors = errors + 1;
        $display("[FAIL] MDU op=%0d a=%08x b=%08x: done 超时", op, x, y);
      end else begin
        // 延迟
        checks = checks + 1;
        if (n !== exp_lat) begin
          errors = errors + 1;
          $display("[FAIL] MDU op=%0d: 延迟 %0d 拍，期望 %0d 拍", op, n, exp_lat);
        end
        // done 与 busy 不同拍：done 拍 busy 必须为 0
        checks = checks + 1;
        if (mdu_busy !== 1'b0) begin
          errors = errors + 1;
          $display("[FAIL] MDU op=%0d: done 拍 busy 应为 0", op);
        end
        // 结果
        checks = checks + 1;
        if (mdu_res !== exp) begin
          errors = errors + 1;
          $display("[FAIL] MDU op=%0d a=%08x b=%08x got=%08x exp=%08x",
                   op, x, y, mdu_res, exp);
        end
        // done 单拍
        @(negedge clk);
        checks = checks + 1;
        if (mdu_done !== 1'b0) begin
          errors = errors + 1;
          $display("[FAIL] MDU op=%0d: done 不是单拍脉冲", op);
        end
      end
    end
  endtask

  // 每种模式的边界向量（14 组）
  task mdu_bounds;
    input [2:0] op;
    begin
      mdu_check(op, 32'h0000_0000, 32'h0000_0000);   // 0 op 0（含除零）
      mdu_check(op, 32'h0000_0000, 32'h0000_0001);
      mdu_check(op, 32'h0000_0001, 32'h0000_0000);   // 除零：被除数非 0
      mdu_check(op, 32'hFFFF_FFFF, 32'hFFFF_FFFF);   // -1 op -1
      mdu_check(op, 32'h8000_0000, 32'hFFFF_FFFF);   // INT_MIN / -1（有符号溢出）
      mdu_check(op, 32'h8000_0000, 32'h0000_0001);   // INT_MIN / 1
      mdu_check(op, 32'h7FFF_FFFF, 32'h7FFF_FFFF);   // INT_MAX
      mdu_check(op, 32'hFFFF_FFF9, 32'h0000_0002);   // -7 / 2  → 商 -3 余 -1
      mdu_check(op, 32'h0000_0007, 32'hFFFF_FFFE);   // 7 / -2  → 商 -3 余 1
      mdu_check(op, 32'hFFFF_FFF9, 32'hFFFF_FFFE);   // -7 / -2 → 商 3 余 -1
      mdu_check(op, 32'h1234_5678, 32'h9ABC_DEF0);
      mdu_check(op, 32'h8000_0000, 32'h8000_0000);
      mdu_check(op, 32'hFFFF_FFFF, 32'h0000_0001);   // -1 / 1
      mdu_check(op, 32'h0000_0001, 32'h8000_0000);
    end
  endtask

  // 忙时忽略 start + done 同拍背靠背发射
  task mdu_protocol;
    reg [31:0] e1, e2;
    integer    n;
    begin
      e1 = mdu_ref(`MDU_MUL, 32'h1122_3344, 32'h0000_0010);
      e2 = mdu_ref(`MDU_MUL, 32'h0000_0003, 32'h0000_0005);

      // (a) busy 期间持续给出 start（并改变 op/a/b），必须被忽略
      @(negedge clk);
      mdu_start = 1'b1; mdu_op = `MDU_MUL;
      mdu_a = 32'h1122_3344; mdu_b = 32'h0000_0010;
      @(negedge clk);                                   // busy=1
      mdu_op = `MDU_DIV; mdu_a = 32'hFFFF_FFFF; mdu_b = 32'h0000_0000;
      @(negedge clk);                                   // busy=1
      mdu_op = `MDU_MUL; mdu_a = 32'hFFFF_FFFF; mdu_b = 32'hFFFF_FFFF;
      mdu_start = 1'b0;
      @(negedge clk);                                   // 第 3 拍：done
      checks = checks + 1;
      if ((mdu_done !== 1'b1) || (mdu_res !== e1)) begin
        errors = errors + 1;
        $display("[FAIL] MDU 协议: busy 期间的 start 未被忽略 (done=%b got=%08x exp=%08x)",
                 mdu_done, mdu_res, e1);
      end

      // (b) done 同拍再次 start（busy=0 → 应被接收），3 拍后出第二个结果
      mdu_start = 1'b1; mdu_op = `MDU_MUL;
      mdu_a = 32'h0000_0003; mdu_b = 32'h0000_0005;
      @(negedge clk);
      mdu_start = 1'b0;
      n = 1;
      while ((mdu_done !== 1'b1) && (n < 20)) begin
        @(negedge clk);
        n = n + 1;
      end
      checks = checks + 1;
      if ((n !== 3) || (mdu_res !== e2)) begin
        errors = errors + 1;
        $display("[FAIL] MDU 协议: 背靠背乘法 延迟=%0d(期望 3) got=%08x exp=%08x",
                 n, mdu_res, e2);
      end
    end
  endtask

  //=============================================================================
  // BRU 检查
  //=============================================================================
  // 条件分支：taken 与 target(=pc+imm) 都要检查
  task bru_cond_check;
    input [2:0]  bt;
    input [31:0] x;
    input [31:0] y;
    input [31:0] pcv;
    input [31:0] immv;
    reg          exp_t;
    reg   [31:0] exp_tgt;
    begin
      bru_type  = bt;
      bru_flags = FL_NONE;
      bru_a     = x;
      bru_b     = y;
      bru_pc    = pcv;
      bru_imm   = immv;
      #1;
      exp_t   = bru_ref(bt, x, y);
      exp_tgt = pcv + immv;

      checks = checks + 1;
      if (bru_taken !== exp_t) begin
        errors = errors + 1;
        $display("[FAIL] BRU type=%0d a=%08x b=%08x: taken=%b exp=%b",
                 bt, x, y, bru_taken, exp_t);
      end
      checks = checks + 1;
      if (bru_target !== exp_tgt) begin
        errors = errors + 1;
        $display("[FAIL] BRU type=%0d a=%08x b=%08x pc=%08x imm=%08x: target=%08x exp=%08x",
                 bt, x, y, pcv, immv, bru_target, exp_tgt);
      end
    end
  endtask

  // 跳转（jal/jalr）：taken、target、目标 2 字节对齐
  task bru_jump_check;
    input [3:0]  fl;
    input [31:0] x;        // jalr 的 rs1（jal 忽略）
    input [31:0] pcv;
    input [31:0] immv;
    input [31:0] exp_tgt;
    begin
      bru_type  = `BR_NONE;
      bru_flags = fl;
      bru_a     = x;
      bru_b     = 32'hDEAD_BEEF;      // jal/jalr 必须忽略 rs2
      bru_pc    = pcv;
      bru_imm   = immv;
      #1;
      checks = checks + 1;
      if (bru_taken !== 1'b1) begin
        errors = errors + 1;
        $display("[FAIL] BRU flags=%b: jal/jalr taken=%b 应为 1", fl, bru_taken);
      end
      checks = checks + 1;
      if (bru_target !== exp_tgt) begin
        errors = errors + 1;
        $display("[FAIL] BRU flags=%b pc=%08x rs1=%08x imm=%08x: target=%08x exp=%08x",
                 fl, pcv, x, immv, bru_target, exp_tgt);
      end
      checks = checks + 1;
      if (bru_target[0] !== 1'b0) begin
        errors = errors + 1;
        $display("[FAIL] BRU flags=%b: 目标 %08x 未 2 字节对齐", fl, bru_target);
      end
    end
  endtask

  //=============================================================================
  // 主流程
  //=============================================================================
  initial begin
    checks = 0;
    errors = 0;

    // 初值与复位（同步复位，低有效）
    alu_op   = `ALU_ADD; alu_a = 32'd0; alu_b = 32'd0;
    mdu_start= 1'b0; mdu_op = `MDU_MUL; mdu_a = 32'd0; mdu_b = 32'd0;
    bru_type = `BR_NONE; bru_flags = FL_NONE;
    bru_a = 32'd0; bru_b = 32'd0; bru_pc = 32'd0; bru_imm = 32'd0;
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    // 复位后 MDU 必须空闲
    checks = checks + 1;
    if (mdu_busy !== 1'b0 || mdu_done !== 1'b0) begin
      errors = errors + 1;
      $display("[FAIL] MDU: 复位后 busy/done 应为 0 (busy=%b done=%b)", mdu_busy, mdu_done);
    end

    //-------------------------------------------------------------------------
    $display("---- ALU ----");
    c0 = checks;
    for (mi = 0; mi < 10; mi = mi + 1) begin
      alu_op = mi[4:0];
      for (i = 0; i < 24; i = i + 1) begin
        alu_check(mi[4:0], $random, $random);          // 每条运算 24 组随机
      end
      alu_bounds(mi[4:0]);                             // + 16 组边界
    end
    alu_shift_bounds();
    alu_cmp_bounds();
    $display("ALU checks = %0d", checks - c0);

    //-------------------------------------------------------------------------
    $display("---- BRU ----");
    c0 = checks;
    // 6 种条件 × 8 组操作数（同一张操作数表，逐条件覆盖正反例；BR_NONE 单独检查）
    for (mi = 1; mi <= 6; mi = mi + 1) begin
      bru_cond_check(mi[2:0], 32'h0000_0005, 32'h0000_0005, 32'h0000_1000, 32'd16);
      bru_cond_check(mi[2:0], 32'h0000_0005, 32'h0000_0006, 32'h0000_1000, 32'd16);
      bru_cond_check(mi[2:0], 32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_1000, 32'hFFFF_FFF0);
      bru_cond_check(mi[2:0], 32'h0000_0000, 32'hFFFF_FFFF, 32'h0000_1000, 32'hFFFF_FFF0);
      bru_cond_check(mi[2:0], 32'h8000_0000, 32'h7FFF_FFFF, 32'h0000_2000, 32'd4);
      bru_cond_check(mi[2:0], 32'h7FFF_FFFF, 32'h8000_0000, 32'h0000_2000, 32'd4);
      bru_cond_check(mi[2:0], 32'h8000_0000, 32'h8000_0000, 32'h8000_0000, 32'h0000_0010);
      bru_cond_check(mi[2:0], 32'h0000_0001, 32'h0000_0000, 32'h8000_0000, 32'h0000_0010);
    end
    // BR_NONE 及保留编码：不跳转，target 仍为 pc+imm
    bru_cond_check(`BR_NONE, 32'h0000_0005, 32'h0000_0005, 32'h0000_1000, 32'd16);
    bru_cond_check(`BR_NONE, 32'h0000_0000, 32'h0000_0000, 32'h0000_2000, 32'hFFFF_FFF0);
    bru_cond_check(3'd7,     32'h0000_0000, 32'h0000_0000, 32'h0000_2000, 32'hFFFF_FFF0);

    // jal：target = pc + imm（含负数偏移与 32 位回绕）
    bru_jump_check(FL_JAL,       32'd0,          32'h0000_1000, 32'h0000_0008, 32'h0000_1008);
    bru_jump_check(FL_JAL,       32'd0,          32'h0000_1000, 32'hFFFF_FFF8, 32'h0000_0FF8);
    bru_jump_check(FL_CALL_JAL,  32'd0,          32'h8000_0000, 32'h0000_1000, 32'h8000_1000);
    bru_jump_check(FL_JAL,       32'd0,          32'hFFFF_FFF8, 32'h0000_0010, 32'h0000_0008);
    bru_jump_check(FL_JAL,       32'd0,          32'h0000_0000, 32'h0000_0000, 32'h0000_0000);
    bru_jump_check(FL_JAL,       32'd0,          32'h0000_2000, 32'h7FFF_FFF0, 32'h8000_1FF0);

    // jalr：target = (rs1 + imm) & ~1（bit0 必须清零，含加法回绕）
    bru_jump_check(FL_JALR,      32'h8000_1001, 32'h0000_0000, 32'h0000_0002, 32'h8000_1002);
    bru_jump_check(FL_JALR,      32'h0000_2001, 32'h0000_0000, 32'h0000_0000, 32'h0000_2000);
    bru_jump_check(FL_CALL_JALR, 32'h0000_1235, 32'h0000_0000, 32'hFFFF_FFF0, 32'h0000_1224);
    bru_jump_check(FL_RET_JALR,  32'h0000_1000, 32'h0000_0000, 32'h0000_0010, 32'h0000_1010);
    bru_jump_check(FL_JALR,      32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_0001, 32'h0000_0000);
    bru_jump_check(FL_JALR,      32'h0000_0003, 32'h0000_0000, 32'h0000_0002, 32'h0000_0004);
    bru_jump_check(FL_JALR,      32'h0000_0002, 32'h0000_0000, 32'h0000_0002, 32'h0000_0004);
    bru_jump_check(FL_JALR,      32'h7FFF_FFFF, 32'h0000_0000, 32'h0000_0003, 32'h8000_0002);
    // br_type 对 jalr 无效（保留位 is_ret/is_call 也不影响 taken/target）
    bru_type  = `BR_EQ; bru_flags = FL_JALR;
    bru_a     = 32'h0000_3001; bru_b = 32'h0000_3001;
    bru_pc    = 32'h0000_0000; bru_imm = 32'h0000_0002;
    #1;
    checks = checks + 1;
    if (bru_taken !== 1'b1 || bru_target !== 32'h0000_3002) begin
      errors = errors + 1;
      $display("[FAIL] BRU: jalr 未忽略 br_type (taken=%b target=%08x)", bru_taken, bru_target);
    end
    // is_ret/is_call 单独置位（非 jal/jalr）不得产生跳转
    bru_type  = `BR_NONE; bru_flags = FL_RET;
    bru_a     = 32'h0000_3001; bru_b = 32'h0000_3001;
    bru_pc    = 32'h0000_0000; bru_imm = 32'h0000_0002;
    #1;
    checks = checks + 1;
    if (bru_taken !== 1'b0) begin
      errors = errors + 1;
      $display("[FAIL] BRU: is_ret 单独置位时 taken=%b 应为 0", bru_taken);
    end
    $display("BRU checks = %0d", checks - c0);

    //-------------------------------------------------------------------------
    $display("---- MDU ----");
    c0 = checks;
    for (mi = 0; mi < 8; mi = mi + 1) begin
      mdu_bounds(mi[2:0]);                             // 14 组边界
      for (i = 0; i < 24; i = i + 1) begin
        mdu_check(mi[2:0], $random, $random);          // + 24 组随机 = 38 组/模式
      end
    end
    // 固定向量补充：-7/2、7/-2、负数随机
    mdu_check(`MDU_DIV,  32'hFFFF_FFF9, 32'h0000_0002);
    mdu_check(`MDU_REM,  32'hFFFF_FFF9, 32'h0000_0002);
    mdu_check(`MDU_DIV,  32'h0000_0007, 32'hFFFF_FFFE);
    mdu_check(`MDU_REM,  32'h0000_0007, 32'hFFFF_FFFE);
    mdu_check(`MDU_DIVU, 32'hFFFF_FFFF, 32'h0000_0002);
    mdu_check(`MDU_REMU, 32'hFFFF_FFFF, 32'h0000_0002);

    // 迭代过程中同步复位：busy/done 必须清零，且复位后可正常复用
    @(negedge clk);
    mdu_start = 1'b1; mdu_op = `MDU_DIV;
    mdu_a = 32'hFFFF_FFF0; mdu_b = 32'h0000_0007;
    @(negedge clk);
    mdu_start = 1'b0;
    repeat (5) @(negedge clk);
    checks = checks + 1;
    if (mdu_busy !== 1'b1) begin
      errors = errors + 1;
      $display("[FAIL] MDU 复位: 复位前应处于 busy (busy=%b)", mdu_busy);
    end
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    checks = checks + 1;
    if ((mdu_busy !== 1'b0) || (mdu_done !== 1'b0)) begin
      errors = errors + 1;
      $display("[FAIL] MDU 复位: busy/done 未清零 (busy=%b done=%b)", mdu_busy, mdu_done);
    end
    rst_n = 1'b1;
    @(negedge clk);
    mdu_check(`MDU_DIV, 32'hFFFF_FFF0, 32'h0000_0007);   // 复位后仍能正确完成
    mdu_protocol();
    $display("MDU checks = %0d", checks - c0);

    //-------------------------------------------------------------------------
    $display("---- 汇总 ----");
    $display("checks = %0d, errors = %0d", checks, errors);
    if (errors == 0) begin
      $display("EXEC_UNIT_TESTS: PASS (%0d checks)", checks);
    end else begin
      $display("EXEC_UNIT_TESTS: FAIL (%0d errors, %0d checks)", errors, checks);
    end
    $finish;
  end

endmodule
