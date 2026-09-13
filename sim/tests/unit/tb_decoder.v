//=============================================================================
// tb_decoder.v —— rv32_decoder + rv32_imm_gen 表驱动单元测试
//
// 向量来源：sim/tests/unit/decoder_vectors.vh（由 gen_decoder_vectors.py 生成；
//           期望值由独立参考模型 + 手写期望表 + as/objdump 交叉验证产生，
//           不使用被测 RTL 的输出）
// 每条向量比对：legal / ilen / instr / ctrl(&mask)；exp_legal=1 时另比对
// rs1 / rs2 / rs3 / rd / imm（legal=0 时这些输出按接口定义为不关心）
// 失败时打印第一个不匹配的字段与位号，并以 FAIL 结束（脚本据此返回非零）。
// 成功时打印：DECODER_UNIT_TESTS: PASS (N vectors)
//=============================================================================
`include "rv32gc_defs.vh"
`include "decoder_vectors.vh"     // 取 DECODER_VEC_NUM / DECODER_VEC_W

module tb_decoder;

  //---------------------------------------------------------------------------
  // 字段偏移（与生成器 VEC_LAYOUT 一致，LSB→MSB）
  //---------------------------------------------------------------------------
  localparam integer F_RAW        = 0;
  localparam integer F_EXP_INSTR  = 32;
  localparam integer F_EXP_IMM    = 64;
  localparam integer F_EXP_CTRL   = 96;
  localparam integer F_EXP_MASK   = 169;
  localparam integer F_EXP_RS1    = 242;
  localparam integer F_EXP_RS2    = 247;
  localparam integer F_EXP_RS3    = 252;
  localparam integer F_EXP_RD     = 257;
  localparam integer F_EXP_ILEN   = 262;
  localparam integer F_EXP_LEGAL  = 264;

  reg  [`DECODER_VEC_W-1:0] vec [0:`DECODER_VEC_NUM-1];

  reg  [31:0] instr_raw;
  wire        legal;
  wire [31:0] instr;
  wire [1:0]  ilen;
  wire [4:0]  rs1_arch, rs2_arch, rs3_arch, rd_arch;
  wire [31:0] imm;
  wire [11:0] csr_addr;
  wire [72:0] ctrl;

  rv32_decoder u_dut (
    .instr_raw (instr_raw),
    .pc        (32'h0000_1000),
    .legal     (legal),
    .instr     (instr),
    .ilen      (ilen),
    .rs1_arch  (rs1_arch),
    .rs2_arch  (rs2_arch),
    .rs3_arch  (rs3_arch),
    .rd_arch   (rd_arch),
    .imm       (imm),
    .csr_addr  (csr_addr),
    .ctrl      (ctrl)
  );

  integer i, b, n_fail, n_legal, n_illegal;
  reg [72:0] diff, exp_ctrl, exp_mask;
  integer    bit_idx;

  task report_fail;
    input [8*24-1:0] field;     // 字段名
    input [31:0]     exp_v;     // 期望值
    input [31:0]     got_v;     // 实际值
    begin
      $display("DECODER_UNIT_TESTS: FAIL vec[%0d] raw=%08x (%s)", i, vec[i][F_RAW+:32],
               (vec[i][F_EXP_LEGAL] ? "legal" : "illegal"));
      if (bit_idx >= 0)
        $display("  field=%0s bit=%0d exp=%08x got=%08x", field, bit_idx, exp_v, got_v);
      else
        $display("  field=%0s exp=%08x got=%08x", field, exp_v, got_v);
      $display("  exp_ctrl=%019h", exp_ctrl);
      $display("  got_ctrl=%019h", ctrl);
      $display("  exp_mask=%019h", exp_mask);
    end
  endtask

  initial begin
    n_fail = 0;
    n_legal = 0;
    n_illegal = 0;
    instr_raw = 32'h0;
    bit_idx = -1;

    // 装载向量表（decoder_vectors.vh 的数据段）
    `define DECODER_VEC_EMIT_DATA
    `include "decoder_vectors.vh"
    `undef DECODER_VEC_EMIT_DATA

    for (i = 0; i < `DECODER_VEC_NUM; i = i + 1) begin
      instr_raw = vec[i][F_RAW+:32];
      #1;                                   // 组合逻辑稳定
      exp_ctrl  = vec[i][F_EXP_CTRL+:73];
      exp_mask  = vec[i][F_EXP_MASK+:73];
      diff      = (ctrl ^ exp_ctrl) & exp_mask;
      bit_idx   = -1;
      for (b = 0; b < 73; b = b + 1)
        if (diff[b] && (bit_idx < 0)) bit_idx = b;

      if (vec[i][F_EXP_LEGAL] !== legal) begin
        n_fail = n_fail + 1;
        report_fail("legal", {31'b0, vec[i][F_EXP_LEGAL]}, {31'b0, legal});
        i = `DECODER_VEC_NUM;                // 只报第一个失败
      end else if (vec[i][F_EXP_ILEN+:2] !== ilen) begin
        n_fail = n_fail + 1;
        report_fail("ilen", {30'b0, vec[i][F_EXP_ILEN+:2]}, {30'b0, ilen});
        i = `DECODER_VEC_NUM;
      end else if (vec[i][F_EXP_INSTR+:32] !== instr) begin
        n_fail = n_fail + 1;
        report_fail("instr", vec[i][F_EXP_INSTR+:32], instr);
        i = `DECODER_VEC_NUM;
      end else if (bit_idx >= 0) begin
        n_fail = n_fail + 1;
        report_fail("ctrl", exp_ctrl[31:0], ctrl[31:0]);
        i = `DECODER_VEC_NUM;
      end else if (vec[i][F_EXP_LEGAL] && (vec[i][F_EXP_RS1+:5] !== rs1_arch)) begin
        n_fail = n_fail + 1;
        report_fail("rs1_arch", {27'b0, vec[i][F_EXP_RS1+:5]}, {27'b0, rs1_arch});
        i = `DECODER_VEC_NUM;
      end else if (vec[i][F_EXP_LEGAL] && (vec[i][F_EXP_RS2+:5] !== rs2_arch)) begin
        n_fail = n_fail + 1;
        report_fail("rs2_arch", {27'b0, vec[i][F_EXP_RS2+:5]}, {27'b0, rs2_arch});
        i = `DECODER_VEC_NUM;
      end else if (vec[i][F_EXP_LEGAL] && (vec[i][F_EXP_RS3+:5] !== rs3_arch)) begin
        n_fail = n_fail + 1;
        report_fail("rs3_arch", {27'b0, vec[i][F_EXP_RS3+:5]}, {27'b0, rs3_arch});
        i = `DECODER_VEC_NUM;
      end else if (vec[i][F_EXP_LEGAL] && (vec[i][F_EXP_RD+:5] !== rd_arch)) begin
        n_fail = n_fail + 1;
        report_fail("rd_arch", {27'b0, vec[i][F_EXP_RD+:5]}, {27'b0, rd_arch});
        i = `DECODER_VEC_NUM;
      end else if (vec[i][F_EXP_LEGAL] && (vec[i][F_EXP_IMM+:32] !== imm)) begin
        n_fail = n_fail + 1;
        report_fail("imm", vec[i][F_EXP_IMM+:32], imm);
        i = `DECODER_VEC_NUM;
      end else begin
        if (vec[i][F_EXP_LEGAL])
          n_legal = n_legal + 1;
        else
          n_illegal = n_illegal + 1;
      end
    end

    if (n_fail == 0)
      $display("DECODER_UNIT_TESTS: PASS (%0d vectors)", `DECODER_VEC_NUM);
    else
      $display("DECODER_UNIT_TESTS: FAIL (%0d vectors, %0d legal, %0d illegal checked before failure)",
               `DECODER_VEC_NUM, n_legal, n_illegal);
    $display("[覆盖] 已检查合法 %0d 条 / 非法 %0d 条 / 合计 %0d 条",
             n_legal, n_illegal, n_legal + n_illegal);
    $finish;
  end

endmodule
