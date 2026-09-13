//=============================================================================
// rv32gc_core.v —— RV32GC 顺序 5 级基线核（IF / ID / EX / MEM / WB）
//
// 阶段 2A 第一版实现范围：
//   · RV32I + M + Zicsr + SYS（ecall/ebreak/mret/sret/fence/fence.i/sfence.vma）
//   · 无分支预测（预测不跳转）：JAL 在 ID 解析，条件分支/JALR 在 EX 解析
//   · 转发（旁路）：EX←MEM（ALU 结果）、EX←WB（ALU/load/CSR/pc+4）；load-use 停顿 1 拍
//   · 访存：单拍 AXI 读写；非对齐访问触发地址非对齐异常（后续里程碑改硬件拆分）
//   · CSR/特权/异常：见 rv32_csr.v（无 PMP / 无 MMU 生效 / 无 CLINT / 无 PLIC）
//   · 浮点 F/D：待 FPU 里程碑（当前译码报非法指令）
//
// 停顿：fetch / load-use / MDU 忙 / 访存未完成
// 清空：trap·xret(WB) → 清 ID/EX/MEM；EX 分支跳转 → 清 ID/EX；ID JAL → 清 ID
//=============================================================================
`include "rv32gc_defs.vh"

module rv32gc_core (
  input  wire         clk,
  input  wire         rst_n,

  output wire         if_req_valid,
  output wire [31:0]  if_req_addr,
  input  wire         if_req_ready,
  input  wire         if_rsp_valid,
  input  wire [255:0] if_rsp_data,
  input  wire         if_rsp_err,
  output wire         if_rsp_ready,

  output wire         d_req_valid,
  output wire         d_req_we,
  output wire [31:0]  d_req_addr,
  output wire [31:0]  d_req_wdata,
  output wire [3:0]   d_req_wstrb,
  input  wire         d_req_ready,
  input  wire         d_rsp_valid,
  input  wire [31:0]  d_rsp_rdata,
  input  wire         d_rsp_err,
  output wire         d_rsp_ready,

  input  wire [7:0]   intrpt,

  output wire [31:0]  dbg_commit_pc,
  output wire         dbg_commit_valid,
  output wire         dbg_commit_wen,
  output wire [4:0]   dbg_commit_rd,
  output wire [31:0]  dbg_commit_wdata,
  output wire [1:0]   dbg_priv,
  output wire         dbg_trap,
  output wire [3:0]   dbg_trap_cause,

  // ---- 调试读寄存器（平台 reg_num/rf_rdata） ----
  input  wire [4:0]   dbg_reg_addr,
  output wire [31:0]  dbg_reg_data
);

  // ============================================================ IF 级
  reg  [31:0] pc_q;
  reg         cross_q;
  reg  [15:0] cross_hw0_q;
  wire [31:0] fetch_pc = cross_q ? (pc_q + 32'd2) : pc_q;
  wire [15:0] hw0, hw1;
  wire        line_valid;
  wire        flush_front;

  rv32_ifetch u_ifetch (
    .clk(clk), .rst_n(rst_n),
    .pc(fetch_pc), .hw0(hw0), .hw1(hw1), .line_valid(line_valid),
    .flush(flush_front),
    .if_req_valid(if_req_valid), .if_req_addr(if_req_addr), .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_data(if_rsp_data),
    .if_rsp_err(if_rsp_err), .if_rsp_ready(if_rsp_ready)
  );

  wire        at_line_end = (pc_q[4:1] == 4'd15);
  wire        need_cross  = !cross_q && line_valid && at_line_end && (hw0[1:0] == 2'b11);
  wire [31:0] instr_raw   = cross_q ? {hw0, cross_hw0_q} :
                            (hw0[1:0] == 2'b11) ? {hw1, hw0} : {16'd0, hw0};
  wire [2:0]  ilen_raw    = cross_q ? 3'd4 : ((hw0[1:0] == 2'b11) ? 3'd4 : 3'd2);
  wire        if_ready    = line_valid && !need_cross;

  // ============================================================ IF/ID 寄存器
  reg  [31:0] id_pc_q, id_instr_q;
  reg  [2:0]  id_ilen_q;
  reg         id_valid_q;

  // ============================================================ ID 级
  wire        dec_legal;
  wire [31:0] dec_instr;
  wire [1:0]  dec_ilen;
  wire [4:0]  dec_rs1, dec_rs2, dec_rs3, dec_rd;
  wire [31:0] dec_imm;
  wire [11:0] dec_csr_addr;
  wire [72:0] dec_ctrl;

  rv32_decoder u_decoder (
    .instr_raw(id_instr_q), .pc(id_pc_q),
    .legal(dec_legal), .instr(dec_instr), .ilen(dec_ilen),
    .rs1_arch(dec_rs1), .rs2_arch(dec_rs2), .rs3_arch(dec_rs3), .rd_arch(dec_rd),
    .imm(dec_imm), .csr_addr(dec_csr_addr), .ctrl(dec_ctrl)
  );

  wire [2:0]  c_op_class  = dec_ctrl[`CTRL_OP_CLASS_H   -: `CTRL_OP_CLASS_W];
  wire [4:0]  c_alu_op    = dec_ctrl[`CTRL_ALU_OP_H     -: `CTRL_ALU_OP_W];
  wire [1:0]  c_alu_a_sel = dec_ctrl[`CTRL_ALU_A_SEL_H  -: `CTRL_ALU_A_SEL_W];
  wire [2:0]  c_alu_b_sel = dec_ctrl[`CTRL_ALU_B_SEL_H  -: `CTRL_ALU_B_SEL_W];
  wire [2:0]  c_br_type   = dec_ctrl[`CTRL_BR_TYPE_H    -: `CTRL_BR_TYPE_W];
  wire [3:0]  c_br_flags  = dec_ctrl[`CTRL_BR_FLAGS_H   -: `CTRL_BR_FLAGS_W];
  wire [2:0]  c_mdu_op    = dec_ctrl[`CTRL_MDU_OP_H     -: `CTRL_MDU_OP_W];
  wire [2:0]  c_mem_op    = dec_ctrl[`CTRL_MEM_OP_H     -: `CTRL_MEM_OP_W];
  wire [1:0]  c_mem_size  = dec_ctrl[`CTRL_MEM_SIZE_H   -: `CTRL_MEM_SIZE_W];
  wire [1:0]  c_mem_flags = dec_ctrl[`CTRL_MEM_FLAGS_H  -: `CTRL_MEM_FLAGS_W];
  wire [1:0]  c_csr_op    = dec_ctrl[`CTRL_CSR_OP_H     -: `CTRL_CSR_OP_W];
  wire [2:0]  c_sys_op    = dec_ctrl[`CTRL_SYS_OP_H     -: `CTRL_SYS_OP_W];
  wire        c_csr_imm   = dec_ctrl[`CTRL_CSR_IMM_H];
  wire [2:0]  c_wb_sel    = dec_ctrl[`CTRL_WB_SEL_H     -: `CTRL_WB_SEL_W];
  wire        c_rd_wen    = dec_ctrl[`CTRL_RD_WEN_H];
  wire        c_use_rs1   = dec_ctrl[`CTRL_USE_RS1_H];
  wire        c_use_rs2   = dec_ctrl[`CTRL_USE_RS2_H];
  wire        c_is_serial = dec_ctrl[`CTRL_IS_SERIAL_H];
  wire        c_is_jal    = c_br_flags[`BRF_JAL];
  wire        c_is_jalr   = c_br_flags[`BRF_JALR];
  wire        c_is_br     = (c_br_type != `BR_NONE);

  // 寄存器堆（写 = WB 级）
  wire [31:0] rf_rdata_a, rf_rdata_b;
  wire        wb_wen;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;

  rv32_regfile u_regfile (
    .clk(clk), .rst_n(rst_n),
    .raddr_a(dec_rs1), .rdata_a(rf_rdata_a),
    .raddr_b(dec_rs2), .rdata_b(rf_rdata_b),
    .wen(wb_wen), .waddr(wb_rd), .wdata(wb_wdata),
    .dbg_addr(dbg_reg_addr), .dbg_rdata(dbg_reg_data)
  );

  // CSR
  wire [31:0] csr_rdata;
  wire        csr_legal;
  wire [31:0] trap_vector;
  wire [1:0]  trap_new_priv;
  wire [31:0] xret_pc;
  wire [1:0]  xret_new_priv;
  wire [1:0]  priv_q;
  wire        trap_take, xret_take;
  wire [3:0]  trap_cause_wb;
  wire [31:0] trap_tval_wb;
  wire [31:0] wb_pc;
  wire        wb_csr_wen;
  reg  [11:0] wb_csr_addr_q;   // WB 级 CSR 地址（独立流水寄存器）
  wire [31:0] wb_csr_wdata;
  wire        wb_retire;
  wire        wb_is_sret;

  rv32_csr u_csr (
    .clk(clk), .rst_n(rst_n),
    .csr_raddr(dec_csr_addr), .priv(priv_q), .csr_rdata(csr_rdata), .csr_legal(csr_legal),
    .csr_wen(wb_csr_wen), .csr_waddr(wb_csr_addr_q), .csr_wdata(wb_csr_wdata), .csr_is_fp(1'b0),
    .instret_en(wb_retire),
    .trap_valid(trap_take), .trap_cause(trap_cause_wb), .trap_tval(trap_tval_wb),
    .trap_is_int(1'b0), .trap_epc(wb_pc),
    .trap_vector(trap_vector), .trap_new_priv(trap_new_priv),
    .xret_valid(xret_take), .xret_is_sret(wb_is_sret),
    .xret_pc(xret_pc), .xret_new_priv(xret_new_priv),
    .priv_o(priv_q),
    .mstatus_mie(), .mstatus_sie(), .mstatus_mprv(), .mstatus_mpp(),
    .timer_irq_pending(), .ext_irq_pending()
  );

  // ID 级异常
  wire        id_is_sys = (c_op_class == `OP_SYS);
  wire        id_ecall  = id_is_sys && (c_sys_op == `SYS_ECALL)  && dec_legal;
  wire        id_ebreak = id_is_sys && (c_sys_op == `SYS_EBREAK) && dec_legal;
  wire [3:0]  ecall_cause = (priv_q == `PRV_U) ? `DEXC_ECALL_U :
                            (priv_q == `PRV_S) ? `DEXC_ECALL_S : `DEXC_ECALL_M;
  wire        id_excp_valid = id_valid_q && (!dec_legal || id_ecall || id_ebreak);
  wire [3:0]  id_excp_cause = !dec_legal ? `DEXC_ILLEGAL : id_ebreak ? `DEXC_BREAK : ecall_cause;
  wire [31:0] id_excp_tval  = !dec_legal ? dec_instr : 32'd0;

  // ID 级 JAL
  wire        id_jal_taken  = id_valid_q && dec_legal && c_is_jal;
  wire [31:0] id_jal_target = id_pc_q + dec_imm;

  // ============================================================ ID/EX 寄存器
  reg  [31:0] ex_pc_q, ex_instr_q, ex_imm_q;
  reg  [31:0] ex_rs1_val_q, ex_rs2_val_q;
  reg  [4:0]  ex_rs1_q, ex_rs2_q, ex_rd_q;
  reg  [2:0]  ex_ilen_q;
  reg  [11:0] ex_csr_addr_q;
  reg  [31:0] ex_csr_rdata_q;
  reg  [72:0] ex_ctrl_q;
  reg         ex_valid_q, ex_rd_wen_q, ex_excp_valid_q;
  reg  [3:0]  ex_excp_cause_q;
  reg  [31:0] ex_excp_tval_q;

  // ============================================================ EX 级
  wire [2:0]  e_op_class = ex_ctrl_q[`CTRL_OP_CLASS_H -: `CTRL_OP_CLASS_W];
  wire [4:0]  e_alu_op   = ex_ctrl_q[`CTRL_ALU_OP_H   -: `CTRL_ALU_OP_W];
  wire [1:0]  e_alu_a    = ex_ctrl_q[`CTRL_ALU_A_SEL_H-: `CTRL_ALU_A_SEL_W];
  wire [2:0]  e_alu_b    = ex_ctrl_q[`CTRL_ALU_B_SEL_H-: `CTRL_ALU_B_SEL_W];
  wire [2:0]  e_br_type  = ex_ctrl_q[`CTRL_BR_TYPE_H  -: `CTRL_BR_TYPE_W];
  wire [3:0]  e_br_flags = ex_ctrl_q[`CTRL_BR_FLAGS_H -: `CTRL_BR_FLAGS_W];
  wire [2:0]  e_mdu_op   = ex_ctrl_q[`CTRL_MDU_OP_H   -: `CTRL_MDU_OP_W];
  wire [2:0]  e_mem_op   = ex_ctrl_q[`CTRL_MEM_OP_H   -: `CTRL_MEM_OP_W];
  wire [1:0]  e_mem_size = ex_ctrl_q[`CTRL_MEM_SIZE_H -: `CTRL_MEM_SIZE_W];
  wire [1:0]  e_mem_flags= ex_ctrl_q[`CTRL_MEM_FLAGS_H-: `CTRL_MEM_FLAGS_W];
  wire [2:0]  e_wb_sel   = ex_ctrl_q[`CTRL_WB_SEL_H   -: `CTRL_WB_SEL_W];
  wire [1:0]  e_csr_op   = ex_ctrl_q[`CTRL_CSR_OP_H   -: `CTRL_CSR_OP_W];
  wire [2:0]  e_sys_op   = ex_ctrl_q[`CTRL_SYS_OP_H   -: `CTRL_SYS_OP_W];
  wire        e_is_jalr  = e_br_flags[`BRF_JALR];
  wire        e_is_jal   = e_br_flags[`BRF_JAL];
  wire        e_is_br    = (e_br_type != `BR_NONE);
  wire        e_is_mdu   = (e_op_class == `OP_MDU);
  wire        e_is_lsu   = (e_op_class == `OP_LSU) && (e_mem_op != `MEM_NONE);
  wire        e_is_load  = e_is_lsu && (e_mem_op == `MEM_LOAD);

  // ---- 旁路（转发）网络 ----
  // MEM 级（EX/MEM 寄存器）：仅 ALU 类结果可转发（load 数据要等 WB）
  wire        mem_fwd_en  = mem_valid_q && mem_rd_wen_q && (mem_rd_q != 5'd0) &&
                            (mem_mem_op_q == `MEM_NONE);
  wire [31:0] mem_fwd_val = (mem_wb_sel_q == `WB_PC4) ? (mem_pc_q + {29'd0, mem_ilen_q}) :
                            (mem_wb_sel_q == `WB_CSR) ? mem_csr_rdata_q :
                            mem_alu_q;   // WB_MEM（load）不在 MEM 级转发，见 mem_fwd_en
  // WB 级：只要求"WB 携带有效写回值"，**不要求本拍真的退休**。
  // 关键：流水线冻结拍（mem_stall / mdu_hold / fetch_stall）里 wb_retire=0，但 WB 的值
  // 已经确定；此时若禁止转发，正在 EX 的消费者（如 MDU 在 start 拍锁存操作数）会采到旧值。
  // 历史缺陷：wb_fwd_en = wb_wen（含 advance）导致 M 扩展整组失败（MUL/... 得到旧操作数）。
  wire        wb_fwd_en   = wb_valid_q && !wb_excp_valid_q && wb_rd_wen_q && (wb_rd_q != 5'd0);
  wire [31:0] wb_fwd_val  = wb_wdata;

  wire [31:0] ex_rs1_fwd = (mem_fwd_en && (mem_rd_q == ex_rs1_q)) ? mem_fwd_val :
                           (wb_fwd_en  && (wb_rd_q  == ex_rs1_q)) ? wb_fwd_val  :
                           ex_rs1_val_q;
  wire [31:0] ex_rs2_fwd = (mem_fwd_en && (mem_rd_q == ex_rs2_q)) ? mem_fwd_val :
                           (wb_fwd_en  && (wb_rd_q  == ex_rs2_q)) ? wb_fwd_val  :
                           ex_rs2_val_q;

  wire [31:0] alu_a = (e_alu_a == `ALU_A_PC)   ? ex_pc_q :
                      (e_alu_a == `ALU_A_ZERO) ? 32'd0 : ex_rs1_fwd;
  wire [31:0] alu_b = (e_alu_b == `ALU_B_IMM)    ? ex_imm_q :
                      (e_alu_b == `ALU_B_CONST4) ? 32'd4 :
                      (e_alu_b == `ALU_B_ZERO)   ? 32'd0 :
                      (e_alu_b == `ALU_B_SHAMT)  ? {27'd0, ex_imm_q[4:0]} : ex_rs2_fwd;

  wire [31:0] alu_result;
  rv32_alu u_alu (.alu_op(e_alu_op), .op_a(alu_a), .op_b(alu_b), .result(alu_result));

  wire        br_taken;
  wire [31:0] br_target;
  rv32_bru u_bru (
    .br_type(e_br_type), .br_flags(e_br_flags),
    .op_a(ex_rs1_fwd), .op_b(ex_rs2_fwd),
    .pc(ex_pc_q), .imm(ex_imm_q),
    .taken(br_taken), .target(br_target)
  );

  wire        mdu_busy, mdu_done;
  wire [31:0] mdu_result;
  // MDU 握手（见 rv32_mul_div.v：start 被接收后下一拍 busy=1；乘法第 3 拍、除法第 33 拍
  // done=1 单拍脉冲，且 done 与 result 同拍）。
  // start 条件用 busy/done 即可保证单拍：busy 拍不会再发 start，done 拍已 !done。
  wire        mdu_start = ex_valid_q && e_is_mdu && !mdu_busy && !mdu_done;
  // 占用：从 start 拍起一直保持到 done 拍（含 start 拍），done 拍才放行并采走同拍结果。
  // 历史缺陷：曾在 start 拍不保持（… && !mdu_start），结果尚未算出就流出 EX → M 扩展全错。
  wire        mdu_hold  = ex_valid_q && e_is_mdu && !mdu_done;

  rv32_mul_div u_mdu (
    .clk(clk), .rst_n(rst_n),
    .start(mdu_start), .mdu_op(e_mdu_op),
    .a(ex_rs1_fwd), .b(ex_rs2_fwd),
    .busy(mdu_busy), .done(mdu_done), .result(mdu_result)
  );

  wire [31:0] ex_result  = e_is_mdu ? mdu_result : alu_result;
  wire [31:0] ex_addr    = ex_rs1_fwd + ex_imm_q;         // LSU 地址
  // EX 级分支/JALR 退出条件（原始）。注意：实际重定向必须再用 advance_all 门控，
  // 见下方 ex_br_redirect —— WB→EX 旁路挂在 wb_retire(=…&&advance…) 上，流水线冻结
  // 的那一拍旁路不生效，若此时就用（可能过期的）操作数做决定并重定向，会跳错方向。
  wire        ex_br_exit = ex_valid_q && (e_is_br || e_is_jalr) && br_taken;
  // JALR/分支的指令地址非对齐异常：
  //   本核实现 Zca（C 扩展）→ IALIGN=16。规范明确 "With the addition of the Zca
  //   extension, no instructions can raise instruction-address-misaligned exceptions"
  //   （riscv-isa-manual/src/unpriv/zca.adoc, norm:Zcanomisaligned）。
  //   且 rv32_bru 已按规范把 JALR 目标 bit0 清零。故该项恒不成立。
  //   历史缺陷：曾用 ex_addr[1]（4 字节对齐）判定，导致返回地址为 2 mod 4 时
  //   误报 cause=0 陷阱（arch-test 大量用例因此失败）。
  wire        ex_jalr_bad = 1'b0;

  // EX 级异常合并（ID 级异常随 ex_excp_* 传入）
  wire        ex_excp_valid_final = ex_excp_valid_q || ex_jalr_bad;
  wire [3:0]  ex_excp_cause_final = ex_jalr_bad ? `EXC_INSTR_MISALIGN : ex_excp_cause_q;
  wire [31:0] ex_excp_tval_final  = ex_jalr_bad ? ex_addr : ex_excp_tval_q;

  // ============================================================ EX/MEM 寄存器
  reg  [31:0] mem_pc_q, mem_instr_q, mem_alu_q, mem_addr_q, mem_imm_q, mem_rs1_val_q, mem_rs2_val_q;
  reg  [31:0] mem_csr_rdata_q;
  reg  [4:0]  mem_rd_q;
  reg  [2:0]  mem_ilen_q;
  reg  [11:0] mem_csr_addr_q;
  reg  [2:0]  mem_wb_sel_q, mem_mem_op_q, mem_sys_op_q;
  reg  [4:0]  mem_amo_op_q;
  reg  [1:0]  mem_mem_size_q, mem_mem_flags_q, mem_csr_op_q;
  reg         mem_rd_wen_q, mem_valid_q, mem_csr_imm_q;
  reg         mem_excp_valid_q;
  reg  [3:0]  mem_excp_cause_q;
  reg  [31:0] mem_excp_tval_q;

  // ============================================================ MEM 级访问 FSM
  // 访存 FSM：支持非对齐访问的"两次单拍"拆分（跨 4 字节边界时）
  localparam [2:0] M_IDLE = 3'd0, M_REQ = 3'd1, M_WAIT = 3'd2, M_DONE = 3'd3,
                   M_REQ2 = 3'd4, M_WAIT2 = 3'd5,
                   M_REQ_W = 3'd6, M_WAIT_W = 3'd7;   // 原子指令/SC 的写回阶段
  reg  [2:0]  memst_q;
  reg  [31:0] m_addr_q, m_wdata_q, m_rdata_q, m_rdata2_q, m_excp_tval_q;
  reg  [3:0]  m_wstrb_q, m_wstrb2_q;
  reg         m_we_q, m_err_q, m_split_q;
  reg  [1:0]  m_size_q, m_uns_q, m_shift_q;
  reg  [3:0]  m_excp_cause_q;
  // A 扩展：原子访问类型、amo 操作码、写数据、以及单 hart 保留集（LR/SC）
  reg         m_is_lr_q, m_is_sc_q, m_is_amo_q;
  reg  [4:0]  m_amo_op_q;
  reg  [31:0] m_rs2_q;
  reg         resv_valid_q;
  reg  [31:0] resv_addr_q;

  // MEM 级原子属性（用于 M_IDLE 判断，来自当前 MEM 寄存器而非锁存值）
  wire        mem_is_lr   = (mem_mem_op_q == `MEM_LR);
  wire        mem_is_sc   = (mem_mem_op_q == `MEM_SC);
  wire        mem_is_amo  = (mem_mem_op_q == `MEM_AMO);
  wire        mem_is_atomic = mem_is_lr | mem_is_sc | mem_is_amo;
  wire [4:0]  mem_amo_op  = mem_ctrl_amo_op;

  // AMO 读-改-写的结果值（组合；用已读回的字 m_rdata_q 与 rs2 锁存值 m_rs2_q）
  reg  [31:0] amo_wdata;
  always @(*) begin
    case (m_amo_op_q)
      `AMO_ADD:  amo_wdata = m_rdata_q + m_rs2_q;
      `AMO_SWAP: amo_wdata = m_rs2_q;
      `AMO_XOR:  amo_wdata = m_rdata_q ^ m_rs2_q;
      `AMO_OR:   amo_wdata = m_rdata_q | m_rs2_q;
      `AMO_AND:  amo_wdata = m_rdata_q & m_rs2_q;
      `AMO_MIN:  amo_wdata = ($signed(m_rdata_q) < $signed(m_rs2_q)) ? m_rdata_q : m_rs2_q;
      `AMO_MAX:  amo_wdata = ($signed(m_rdata_q) > $signed(m_rs2_q)) ? m_rdata_q : m_rs2_q;
      `AMO_MINU: amo_wdata = (m_rdata_q < m_rs2_q) ? m_rdata_q : m_rs2_q;
      `AMO_MAXU: amo_wdata = (m_rdata_q > m_rs2_q) ? m_rdata_q : m_rs2_q;
      default:   amo_wdata = m_rs2_q;
    endcase
  end

  // 请求有效须覆盖两次拆分访问：M_REQ（第一次）与 M_REQ2（第二次）。
  // 历史缺陷：只写了 M_REQ，非对齐拆分时第二次访问永不发请求、FSM 卡在 M_REQ2
  // （Zifencei / Zca 等用例里出现非对齐访问即整机停摆）。
  assign d_req_valid = (memst_q == M_REQ) || (memst_q == M_REQ2) || (memst_q == M_REQ_W);
  assign d_req_we    = (memst_q == M_REQ_W) ? 1'b1 : m_we_q;
  assign d_req_addr  = m_addr_q;
  assign d_req_wdata = m_wdata_q;
  assign d_req_wstrb = m_wstrb_q;
  assign d_rsp_ready = 1'b1;

  wire [4:0]  mem_ctrl_amo_op = mem_amo_op_q;
  wire        mem_needs_fsm = mem_valid_q && (mem_mem_op_q != `MEM_NONE);
  wire        mem_done_now  = (memst_q == M_DONE);
  // 拆分判定（组合，基于 MEM 级寄存器）
  wire [2:0]  mem_nbytes = (mem_mem_size_q == `MSZ_BYTE) ? 3'd1 :
                           (mem_mem_size_q == `MSZ_HALF) ? 3'd2 : 3'd4;
  wire [2:0]  mem_shift  = {1'b0, mem_addr_q[1:0]};
  wire        mem_split  = ((mem_shift + mem_nbytes) > 3'd4);
  // 自然对齐检查（按访问宽度）：BYTE 恒对齐；HALF 要求 addr[0]==0；WORD 要求 addr[1:0]==0。
  // 默认（未定义 MISALIGNED_TRAP）非对齐访问由硬件拆成两次单拍完成；
  // 定义 MISALIGNED_TRAP 时改为报 cause 4/6（bring-up / arch-test：参考模型 Spike 默认如此）。
  wire        mem_misaligned = (mem_mem_size_q == `MSZ_WORD) ? (mem_addr_q[1:0] != 2'b00) :
                               (mem_mem_size_q == `MSZ_HALF) ? (mem_addr_q[0]   != 1'b0)  : 1'b0;
  // 第一次访问的字节数与使能
  wire [2:0]  a1_bytes = mem_split ? (3'd4 - mem_shift) : mem_nbytes;
  wire [3:0]  a1_wstrb = (4'hF >> (4 - a1_bytes)) << mem_addr_q[1:0];
  wire [31:0] a1_wdata = mem_rs2_val_q << (8 * mem_addr_q[1:0]);
  // load 数据按字节偏移对齐（第一次访问）
  wire [31:0] m_rdata_shift = m_rdata_q >> (8 * m_shift_q);
  wire [31:0] m_rdata_shift2 = m_rdata2_q << (8 * (4 - m_shift_q));
  wire [31:0] m_merged = m_split_q ? (m_rdata_shift | m_rdata_shift2) : m_rdata_shift;
  wire [31:0] mem_load_data = (m_size_q == `MSZ_BYTE) ?
                                (m_uns_q[`MF_UNSIGNED] ? {24'd0, m_merged[7:0]}
                                                       : {{24{m_merged[7]}}, m_merged[7:0]}) :
                              (m_size_q == `MSZ_HALF) ?
                                (m_uns_q[`MF_UNSIGNED] ? {16'd0, m_merged[15:0]}
                                                       : {{16{m_merged[15]}}, m_merged[15:0]}) :
                                m_merged;

  // ============================================================ MEM/WB 寄存器
  reg  [31:0] wb_pc_q, wb_instr_q, wb_alu_q, wb_imm_q, wb_rs1_val_q, wb_csr_rdata_q, wb_mem_data_q;
  reg  [4:0]  wb_rd_q;
  reg  [2:0]  wb_ilen_q;
  reg  [2:0]  wb_wb_sel_q, wb_sys_op_q;
  reg  [1:0]  wb_csr_op_q;
  reg         wb_rd_wen_q, wb_valid_q, wb_csr_imm_q;
  reg         wb_excp_valid_q;
  reg  [3:0]  wb_excp_cause_q;
  reg  [31:0] wb_excp_tval_q;

  // ============================================================ 停顿/清空
  // 注意 fetch_stall 用 line_valid 而非 if_ready：当 pc 处的 32 位指令跨越 32B 行边界
  // （need_cross=1，见上文）时 if_ready=0，但这不是"无法取指"，而是需要进入跨行拼装
  // 状态（cross_q=1）再去取下一行。若此处用 !if_ready，advance_all 会恒为 0，而 cross_q
  // 的置位又被 advance_all 门控 → 前端永久死锁（arch-test 在行末 32 位指令处必现）。
  wire fetch_stall = !line_valid;
  wire load_use    = ex_valid_q && e_is_load && ex_rd_wen_q && (ex_rd_q != 5'd0) && id_valid_q &&
                     ((c_use_rs1 && (dec_rs1 == ex_rd_q)) ||
                      (c_use_rs2 && (dec_rs2 == ex_rd_q)));
  wire mem_stall   = mem_needs_fsm && !mem_done_now;
  // advance_all：EX/MEM/WB 三级推进（访存未完成 / MDU 忙 / 取指未就绪时冻结）
  wire advance_all = !(fetch_stall || mem_stall || mdu_hold);
  // 分支/JALR 只在流水线真正推进的那一拍才允许重定向：此时 WB 旁路（wb_retire 含 advance）
  // 必然有效，EX 拿到的操作数一定是最新的；冻结拍不重定向，等停摆解除后再判定。
  // 历史缺陷：未门控时会在取指停顿拍用过期操作数判定（load 结果尚未写回），
  // arch-test 的 `c.lw/c.lw/bne` 序列因此跳错方向（I-bne-00 / I-blt-00 失败）。
  wire ex_br_redirect = ex_br_exit && advance_all;
  // CSR/系统指令的顺序性：CSR 写只在 WB 生效，而 CSR 读发生在 ID（组合）。
  // 若更老的指令仍在流水线中，ID 可能读到尚未提交的旧值 → 让该指令等流水线排空后再前进。
  wire id_serial        = id_valid_q && c_is_serial;
  wire csr_order_stall  = id_serial && (ex_valid_q || mem_valid_q || wb_valid_q);
  // load_use：只冻结前端并给 EX 注入气泡，EX 中的 load 仍继续流入 MEM
  wire front_hold  = load_use || csr_order_stall;
  wire advance     = advance_all;                       // 兼容旧名（供提交/CSR 使用）
  wire stall       = !advance_all || front_hold;        // 供调试观察

  assign wb_retire = wb_valid_q && advance && !wb_excp_valid_q;
  assign wb_wen    = wb_retire && wb_rd_wen_q && (wb_rd_q != 5'd0);
  assign wb_rd     = wb_rd_q;
  assign wb_wdata  = (wb_wb_sel_q == `WB_MEM) ? wb_mem_data_q :
                     (wb_wb_sel_q == `WB_PC4) ? (wb_pc_q + {29'd0, wb_ilen_q}) :
                     (wb_wb_sel_q == `WB_CSR) ? wb_csr_rdata_q : wb_alu_q;
  assign wb_pc     = wb_pc_q;

  assign trap_take     = wb_valid_q && advance && wb_excp_valid_q;
  assign trap_cause_wb = wb_excp_cause_q;
  assign trap_tval_wb  = wb_excp_tval_q;
  assign xret_take     = wb_valid_q && advance &&
                         ((wb_sys_op_q == `SYS_MRET) || (wb_sys_op_q == `SYS_SRET));
  assign wb_is_sret    = (wb_sys_op_q == `SYS_SRET);

  wire [31:0] csr_src   = wb_csr_imm_q ? wb_imm_q : wb_rs1_val_q;
  assign wb_csr_wdata   = (wb_csr_op_q == `CSR_RW) ? csr_src :
                          (wb_csr_op_q == `CSR_RS) ? (wb_csr_rdata_q | csr_src) :
                          (wb_csr_op_q == `CSR_RC) ? (wb_csr_rdata_q & ~csr_src) :
                          wb_csr_rdata_q;
  assign wb_csr_wen     = wb_retire && (wb_csr_op_q != `CSR_NONE);

  assign dbg_commit_valid = wb_retire;
  assign dbg_commit_pc    = wb_pc_q;
  assign dbg_commit_wen   = wb_wen;
  assign dbg_commit_rd    = wb_rd_q;
  assign dbg_commit_wdata = wb_wdata;
  assign dbg_priv         = priv_q;
  assign dbg_trap         = trap_take;
  assign dbg_trap_cause   = wb_excp_cause_q;

  wire        redirect_valid = trap_take | xret_take | ex_br_redirect | id_jal_taken;
  wire [31:0] redirect_pc    = trap_take      ? trap_vector :
                               xret_take      ? xret_pc :
                               ex_br_redirect ? br_target : id_jal_target;
  assign flush_front = redirect_valid && (redirect_pc[31:5] != pc_q[31:5]);

  wire sq_id  = redirect_valid;
  wire sq_ex  = trap_take | xret_take | ex_br_redirect;
  wire sq_mem = trap_take | xret_take;

  // ============================================================ WB→ID 旁路
  // 关键：寄存器堆在 posedge 写入、ID 为组合读，若生产者处于 WB 而消费者同拍处于 ID，
  // 消费者会读到旧值（经典的"写优先寄存器堆"漏洞）。此处显式旁路 WB 的写数据。
  // 转发条件同样用 wb_fwd_en（不看是否本拍退休），理由见上
  wire        id_byp_a = wb_fwd_en && (wb_rd_q == dec_rs1) && (dec_rs1 != 5'd0);
  wire        id_byp_b = wb_fwd_en && (wb_rd_q == dec_rs2) && (dec_rs2 != 5'd0);
  wire [31:0] id_rdata_a = id_byp_a ? wb_wdata : rf_rdata_a;
  wire [31:0] id_rdata_b = id_byp_b ? wb_wdata : rf_rdata_b;

  // ============================================================ 时序
  always @(posedge clk) begin
    if (!rst_n) begin
      pc_q <= `RESET_PC;  cross_q <= 1'b0;  cross_hw0_q <= 16'd0;
      id_pc_q <= 32'd0; id_instr_q <= 32'h0000_0013; id_ilen_q <= 3'd4; id_valid_q <= 1'b0;

      ex_pc_q <= 32'd0; ex_instr_q <= 32'd0; ex_imm_q <= 32'd0;
      ex_rs1_val_q <= 32'd0; ex_rs2_val_q <= 32'd0;
      ex_rs1_q <= 5'd0; ex_rs2_q <= 5'd0; ex_rd_q <= 5'd0; ex_ilen_q <= 3'd4;
      ex_csr_addr_q <= 12'd0; ex_csr_rdata_q <= 32'd0;
      ex_ctrl_q <= 73'd0; ex_valid_q <= 1'b0; ex_rd_wen_q <= 1'b0;
      ex_excp_valid_q <= 1'b0; ex_excp_cause_q <= 4'd0; ex_excp_tval_q <= 32'd0;

      mem_pc_q <= 32'd0; mem_instr_q <= 32'd0; mem_alu_q <= 32'd0; mem_addr_q <= 32'd0;
      mem_imm_q <= 32'd0; mem_rs1_val_q <= 32'd0; mem_rs2_val_q <= 32'd0; mem_csr_rdata_q <= 32'd0;
      mem_rd_q <= 5'd0; mem_ilen_q <= 3'd4; mem_csr_addr_q <= 12'd0;
      mem_wb_sel_q <= `WB_ALU; mem_mem_op_q <= `MEM_NONE; mem_sys_op_q <= 3'd0; mem_amo_op_q <= 5'd0;
      mem_mem_size_q <= 2'd0; mem_mem_flags_q <= 2'd0; mem_csr_op_q <= `CSR_NONE;
      mem_rd_wen_q <= 1'b0; mem_valid_q <= 1'b0; mem_csr_imm_q <= 1'b0;
      mem_excp_valid_q <= 1'b0; mem_excp_cause_q <= 4'd0; mem_excp_tval_q <= 32'd0;

      memst_q <= M_IDLE; m_addr_q <= 32'd0; m_wdata_q <= 32'd0; m_rdata_q <= 32'd0;
      m_rdata2_q <= 32'd0; m_wstrb2_q <= 4'd0; m_split_q <= 1'b0;
      m_is_lr_q <= 1'b0; m_is_sc_q <= 1'b0; m_is_amo_q <= 1'b0; m_amo_op_q <= 5'd0; m_rs2_q <= 32'd0;
      resv_valid_q <= 1'b0; resv_addr_q <= 32'd0;
      m_wstrb_q <= 4'd0; m_we_q <= 1'b0; m_err_q <= 1'b0;
      m_size_q <= 2'd0; m_uns_q <= 2'd0; m_excp_cause_q <= 4'd0; m_excp_tval_q <= 32'd0;

      wb_pc_q <= 32'd0; wb_instr_q <= 32'd0; wb_alu_q <= 32'd0; wb_imm_q <= 32'd0;
      wb_rs1_val_q <= 32'd0; wb_csr_rdata_q <= 32'd0; wb_mem_data_q <= 32'd0;
      wb_rd_q <= 5'd0; wb_ilen_q <= 3'd4; wb_csr_addr_q <= 12'd0; wb_wb_sel_q <= `WB_ALU; wb_sys_op_q <= 3'd0; wb_csr_op_q <= `CSR_NONE;
      wb_rd_wen_q <= 1'b0; wb_valid_q <= 1'b0; wb_csr_imm_q <= 1'b0;
      wb_excp_valid_q <= 1'b0; wb_excp_cause_q <= 4'd0; wb_excp_tval_q <= 32'd0;
    end else begin
      // ---------------- PC / 跨行拼装 ----------------
      // 跨行拼装必须在"本行有效"时就允许进入（不能要求 if_ready）：进入 cross_q=1 后
      // fetch_pc 变为 pc_q+2，取指单元才会去取下一行；下一行就绪后 instr_raw 由
      // {hw0(下一行首半字), cross_hw0_q(本行末半字)} 拼成完整 32 位指令。
      if (trap_take) resv_valid_q <= 1'b0;   // 陷阱后保留集失效
      if (redirect_valid) begin
        pc_q  <= redirect_pc;
        cross_q <= 1'b0;
      end else if (advance_all && !front_hold && line_valid) begin
        if (need_cross) begin
          cross_q     <= 1'b1;
          cross_hw0_q <= hw0;
        end else begin
          if (cross_q) cross_q <= 1'b0;
          if (if_ready) pc_q <= pc_q + {29'd0, ilen_raw};
        end
      end

      // ---------------- 访存 FSM（与 stall 并行推进） ----------------
      case (memst_q)
        M_IDLE: if (mem_needs_fsm) begin
`ifdef MISALIGNED_TRAP
            if (mem_misaligned) begin
              // 不做拆分访问：直接进入 M_DONE 并在 WB 级精确报地址非对齐异常
              m_addr_q      <= mem_addr_q;
              m_we_q        <= (mem_mem_op_q == `MEM_STORE);   // 只有普通 store 在本阶段写；LR/AMO 先读，SC/AMO 的写在 M_REQ_W
              m_size_q      <= mem_mem_size_q;
              m_uns_q       <= mem_mem_flags_q;
              m_shift_q     <= mem_addr_q[1:0];
              m_split_q     <= 1'b0;
              m_wdata_q     <= mem_rs2_val_q;
              m_wstrb_q     <= 4'h0;
              m_wstrb2_q    <= 4'h0;
              m_excp_tval_q <= mem_addr_q;
              m_excp_cause_q<= (mem_mem_op_q == `MEM_LOAD) ? `EXC_LOAD_MISALIGN : `EXC_STORE_MISALIGN;
              memst_q       <= M_DONE;
            end else begin
`endif
            m_addr_q      <= mem_addr_q;
            m_we_q        <= (mem_mem_op_q == `MEM_STORE);   // 只有普通 store 在本阶段写；LR/AMO 先读，SC/AMO 的写在 M_REQ_W
            m_size_q      <= mem_mem_size_q;
            m_uns_q       <= mem_mem_flags_q;
            m_shift_q     <= mem_is_atomic ? 2'b00 : mem_addr_q[1:0];
            m_split_q     <= mem_is_atomic ? 1'b0  : mem_split;
            m_wdata_q     <= a1_wdata;
            m_wstrb_q     <= a1_wstrb;
            m_wstrb2_q    <= 4'hF >> (4 - (mem_nbytes - a1_bytes));
            m_is_lr_q     <= mem_is_lr;
            m_is_sc_q     <= mem_is_sc;
            m_is_amo_q    <= mem_is_amo;
            m_amo_op_q    <= mem_amo_op;
            m_rs2_q       <= mem_rs2_val_q;
            m_excp_tval_q <= mem_addr_q;
            m_excp_cause_q<= `EXC_NONE;
            // ---- A 扩展：原子指令（LR/SC/AMO）----
            // 原子操作不可拆分：地址非自然对齐一律报 cause=6（与 MISALIGNED_TRAP 无关）
            if (mem_is_atomic && mem_misaligned) begin
              m_excp_cause_q <= `EXC_STORE_MISALIGN;
              memst_q        <= M_DONE;
            end else if (mem_is_sc) begin
              // SC：保留集有效且地址一致才写；成功 rd=0，失败 rd=1；两种都清保留集
              if (resv_valid_q && (resv_addr_q == mem_addr_q)) begin
                m_wdata_q <= mem_rs2_val_q;
                m_wstrb_q <= 4'hF;
                m_rdata_q <= 32'd0;
                memst_q   <= M_REQ_W;
              end else begin
                m_rdata_q <= 32'd1;
                memst_q   <= M_DONE;
              end
            end else begin
              memst_q <= M_REQ;          // load/store/LR/AMO：发起访问（LR/AMO 为读）
            end
`ifdef MISALIGNED_TRAP
            end
`endif
          end
        M_REQ:  if (d_req_ready) memst_q <= M_WAIT;
        M_WAIT: if (d_rsp_valid) begin
                  m_rdata_q <= d_rsp_rdata;
                  m_err_q   <= d_rsp_err;
                  if (d_rsp_err) begin
                    m_excp_cause_q <= (m_we_q || m_is_amo_q || m_is_sc_q) ? `EXC_STORE_ACCESS : `EXC_LOAD_ACCESS;
                    if (m_is_amo_q || m_is_sc_q) resv_valid_q <= 1'b0;
                    memst_q <= M_DONE;
                  end else if (m_is_lr_q) begin
                    // LR：写保留集，rd = 读回值（已在 m_rdata_q）
                    resv_valid_q <= 1'b1;
                    resv_addr_q  <= m_addr_q;
                    memst_q      <= M_DONE;
                  end else if (m_is_amo_q) begin
                    // AMO：算好新值写回，rd = 旧值（m_rdata_q）；写操作使保留集失效
                    m_wdata_q    <= amo_wdata;
                    m_wstrb_q    <= 4'hF;
                    resv_valid_q <= 1'b0;
                    memst_q      <= M_REQ_W;
                  end else if (m_split_q) begin
                    // 第二次访问：地址 +4（4 字节对齐），字节使能/数据按剩余部分
                    m_addr_q  <= {m_addr_q[31:2], 2'b00} + 32'd4;
                    // 第二次访问的数据：原始 store 数据右移 (4-shift) 字节
                    m_wdata_q <= mem_rs2_val_q >> (8 * (4 - m_shift_q));
                    m_wstrb_q <= m_wstrb2_q;
                    memst_q   <= M_REQ2;
                  end else memst_q <= M_DONE;
                end
        M_REQ2: if (d_req_ready) memst_q <= M_WAIT2;
        M_WAIT2: if (d_rsp_valid) begin
                  m_rdata2_q <= d_rsp_rdata;
                  if (d_rsp_err) m_excp_cause_q <= m_we_q ? `EXC_STORE_ACCESS : `EXC_LOAD_ACCESS;
                  memst_q <= M_DONE;
                end
        M_REQ_W:  if (d_req_ready) memst_q <= M_WAIT_W;
        M_WAIT_W: if (d_rsp_valid) begin
                    // 写响应：出错按 store 访问错误记账（rd 数据对 SC 成功为 0，对齐已保证）
                    if (d_rsp_err) m_excp_cause_q <= `EXC_STORE_ACCESS;
                    memst_q <= M_DONE;
                  end
        M_DONE: memst_q <= M_IDLE;
        default: memst_q <= M_IDLE;
      endcase

      // ---------------- 流水线推进 ----------------
      if (advance_all) begin
        // WB ← MEM
        wb_pc_q        <= mem_pc_q;
        wb_instr_q     <= mem_instr_q;
        wb_alu_q       <= mem_alu_q;
        wb_imm_q       <= mem_imm_q;
        wb_rs1_val_q   <= mem_rs1_val_q;
        wb_csr_rdata_q <= mem_csr_rdata_q;
        wb_csr_addr_q  <= mem_csr_addr_q;
        wb_mem_data_q  <= ((mem_mem_op_q == `MEM_LOAD) || (mem_mem_op_q == `MEM_LR) ||
                           (mem_mem_op_q == `MEM_SC)   || (mem_mem_op_q == `MEM_AMO))
                          ? mem_load_data : mem_alu_q;
        wb_rd_q        <= mem_rd_q;
        wb_ilen_q      <= mem_ilen_q;
        wb_wb_sel_q    <= mem_wb_sel_q;
        wb_sys_op_q    <= mem_sys_op_q;
        wb_csr_op_q    <= mem_csr_op_q;
        wb_rd_wen_q    <= mem_rd_wen_q;
        wb_csr_imm_q   <= mem_csr_imm_q;
        wb_valid_q     <= mem_valid_q && !sq_mem;
        if (mem_needs_fsm && (m_excp_cause_q != `EXC_NONE)) begin
          wb_excp_valid_q <= 1'b1;
          wb_excp_cause_q <= m_excp_cause_q;
          wb_excp_tval_q  <= m_excp_tval_q;
        end else begin
          wb_excp_valid_q <= mem_excp_valid_q;
          wb_excp_cause_q <= mem_excp_cause_q;
          wb_excp_tval_q  <= mem_excp_tval_q;
        end

        // MEM ← EX
        if (sq_mem) begin
          mem_valid_q <= 1'b0;
        end else begin
          mem_pc_q        <= ex_pc_q;
          mem_instr_q     <= ex_instr_q;
          mem_alu_q       <= e_is_lsu ? ex_addr : ex_result;
          mem_addr_q      <= ex_addr;
          mem_imm_q       <= ex_imm_q;
          mem_rs1_val_q   <= ex_rs1_fwd;
          mem_rs2_val_q   <= ex_rs2_fwd;
          mem_csr_rdata_q <= ex_csr_rdata_q;
          mem_rd_q        <= ex_rd_q;
          mem_ilen_q      <= ex_ilen_q;
          mem_csr_addr_q  <= ex_csr_addr_q;
          mem_wb_sel_q    <= e_wb_sel;
          mem_mem_op_q    <= e_mem_op;
          mem_amo_op_q    <= ex_ctrl_q[`CTRL_AMO_OP_H -: `CTRL_AMO_OP_W];
          mem_mem_size_q  <= e_mem_size;
          mem_mem_flags_q <= e_mem_flags;
          mem_sys_op_q    <= e_sys_op;
          mem_csr_op_q    <= e_csr_op;
          mem_rd_wen_q    <= ex_rd_wen_q;
          mem_csr_imm_q   <= ex_ctrl_q[`CTRL_CSR_IMM_H];
          mem_valid_q     <= ex_valid_q;
          mem_excp_valid_q<= ex_excp_valid_final;
          mem_excp_cause_q<= ex_excp_cause_final;
          mem_excp_tval_q <= ex_excp_tval_final;
        end

        // EX ← ID（sq_ex 或前端停顿 → 注入气泡）
        if (sq_ex || front_hold) begin
          ex_valid_q <= 1'b0;
        end else begin
          ex_pc_q        <= id_pc_q;
          ex_instr_q     <= id_instr_q;
          ex_imm_q       <= dec_imm;
          ex_rs1_val_q   <= id_rdata_a;   // 含 WB→ID 旁路
          ex_rs2_val_q   <= id_rdata_b;
          ex_rs1_q       <= dec_rs1;
          ex_rs2_q       <= dec_rs2;
          ex_rd_q        <= dec_rd;
          ex_ilen_q      <= id_ilen_q;   // 指令字节长度（2/4），供 WB 算链接值 pc+ilen
          ex_csr_addr_q  <= dec_csr_addr;
          ex_csr_rdata_q <= csr_rdata;
          ex_ctrl_q      <= dec_ctrl;
          ex_valid_q     <= id_valid_q;   // JAL 在 ID 解析后仍必须流经 EX/WB（要写 rd=ra）
          ex_rd_wen_q    <= c_rd_wen && (dec_rd != 5'd0);
          ex_excp_valid_q<= id_excp_valid;
          ex_excp_cause_q<= id_excp_cause;
          ex_excp_tval_q <= id_excp_tval;
        end

        // ID ← IF（front_hold 时保持原值，等待 load 数据）
        if (sq_id) id_valid_q <= 1'b0;
        else if (front_hold) begin end
        else begin
          id_pc_q    <= pc_q;
          id_instr_q <= instr_raw;
          id_ilen_q  <= ilen_raw;
          id_valid_q <= if_ready;
        end
      end
    end
  end

endmodule
