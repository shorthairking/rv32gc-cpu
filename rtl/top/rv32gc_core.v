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
  wire [11:0] wb_csr_addr_q;
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
  wire [31:0] mem_fwd_val = (mem_wb_sel_q == `WB_PC4) ? (mem_pc_q + 32'd4) : mem_alu_q;
  // WB 级：wb_wen 已含 rd!=0 与无异常
  wire        wb_fwd_en   = wb_wen;
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
  reg         mdu_started_q;
  wire        mdu_start = ex_valid_q && e_is_mdu && !mdu_started_q && !mdu_busy && !mdu_done;
  wire        mdu_hold  = ex_valid_q && e_is_mdu && !mdu_done && !mdu_start;

  rv32_mul_div u_mdu (
    .clk(clk), .rst_n(rst_n),
    .start(mdu_start), .mdu_op(e_mdu_op),
    .a(ex_rs1_fwd), .b(ex_rs2_fwd),
    .busy(mdu_busy), .done(mdu_done), .result(mdu_result)
  );

  wire [31:0] ex_result  = e_is_mdu ? mdu_result : alu_result;
  wire [31:0] ex_addr    = ex_rs1_fwd + ex_imm_q;         // LSU 地址
  wire        ex_br_redirect = ex_valid_q && (e_is_br || e_is_jalr) && br_taken;
  // jalr 目标非 2 字节对齐 → 指令地址非对齐异常
  wire        ex_jalr_bad = ex_valid_q && e_is_jalr && (ex_addr[1] == 1'b1);

  // EX 级异常合并（ID 级异常随 ex_excp_* 传入）
  wire        ex_excp_valid_final = ex_excp_valid_q || ex_jalr_bad;
  wire [3:0]  ex_excp_cause_final = ex_jalr_bad ? `EXC_INSTR_MISALIGN : ex_excp_cause_q;
  wire [31:0] ex_excp_tval_final  = ex_jalr_bad ? ex_addr : ex_excp_tval_q;

  // ============================================================ EX/MEM 寄存器
  reg  [31:0] mem_pc_q, mem_instr_q, mem_alu_q, mem_addr_q, mem_imm_q, mem_rs1_val_q, mem_rs2_val_q;
  reg  [31:0] mem_csr_rdata_q;
  reg  [4:0]  mem_rd_q;
  reg  [11:0] mem_csr_addr_q;
  reg  [2:0]  mem_wb_sel_q, mem_mem_op_q, mem_sys_op_q;
  reg  [1:0]  mem_mem_size_q, mem_mem_flags_q, mem_csr_op_q;
  reg         mem_rd_wen_q, mem_valid_q, mem_csr_imm_q;
  reg         mem_excp_valid_q;
  reg  [3:0]  mem_excp_cause_q;
  reg  [31:0] mem_excp_tval_q;

  // ============================================================ MEM 级访问 FSM
  // 访存 FSM：支持非对齐访问的"两次单拍"拆分（跨 4 字节边界时）
  localparam [2:0] M_IDLE = 3'd0, M_REQ = 3'd1, M_WAIT = 3'd2, M_DONE = 3'd3,
                   M_REQ2 = 3'd4, M_WAIT2 = 3'd5;
  reg  [2:0]  memst_q;
  reg  [31:0] m_addr_q, m_wdata_q, m_rdata_q, m_rdata2_q, m_excp_tval_q;
  reg  [3:0]  m_wstrb_q, m_wstrb2_q;
  reg         m_we_q, m_err_q, m_split_q;
  reg  [1:0]  m_size_q, m_uns_q, m_shift_q;
  reg  [3:0]  m_excp_cause_q;

  assign d_req_valid = (memst_q == M_REQ);
  assign d_req_we    = m_we_q;
  assign d_req_addr  = m_addr_q;
  assign d_req_wdata = m_wdata_q;
  assign d_req_wstrb = m_wstrb_q;
  assign d_rsp_ready = 1'b1;

  wire        mem_needs_fsm = mem_valid_q && (mem_mem_op_q != `MEM_NONE);
  wire        mem_done_now  = (memst_q == M_DONE);
  // 拆分判定（组合，基于 MEM 级寄存器）
  wire [2:0]  mem_nbytes = (mem_mem_size_q == `MSZ_BYTE) ? 3'd1 :
                           (mem_mem_size_q == `MSZ_HALF) ? 3'd2 : 3'd4;
  wire [2:0]  mem_shift  = {1'b0, mem_addr_q[1:0]};
  wire        mem_split  = ((mem_shift + mem_nbytes) > 3'd4);
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
  reg  [2:0]  wb_wb_sel_q, wb_sys_op_q;
  reg  [1:0]  wb_csr_op_q;
  reg         wb_rd_wen_q, wb_valid_q, wb_csr_imm_q;
  reg         wb_excp_valid_q;
  reg  [3:0]  wb_excp_cause_q;
  reg  [31:0] wb_excp_tval_q;

  // ============================================================ 停顿/清空
  wire fetch_stall = !if_ready;
  wire load_use    = ex_valid_q && e_is_load && ex_rd_wen_q && (ex_rd_q != 5'd0) && id_valid_q &&
                     ((c_use_rs1 && (dec_rs1 == ex_rd_q)) ||
                      (c_use_rs2 && (dec_rs2 == ex_rd_q)));
  wire mem_stall   = mem_needs_fsm && !mem_done_now;
  // advance_all：EX/MEM/WB 三级推进（访存未完成 / MDU 忙 / 取指未就绪时冻结）
  wire advance_all = !(fetch_stall || mem_stall || mdu_hold);
  // load_use：只冻结前端并给 EX 注入气泡，EX 中的 load 仍继续流入 MEM
  wire front_hold  = load_use;
  wire advance     = advance_all;                       // 兼容旧名（供提交/CSR 使用）
  wire stall       = !advance_all || front_hold;        // 供调试观察

  assign wb_retire = wb_valid_q && advance && !wb_excp_valid_q;
  assign wb_wen    = wb_retire && wb_rd_wen_q && (wb_rd_q != 5'd0);
  assign wb_rd     = wb_rd_q;
  assign wb_wdata  = (wb_wb_sel_q == `WB_MEM) ? wb_mem_data_q :
                     (wb_wb_sel_q == `WB_PC4) ? (wb_pc_q + 32'd4) :
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
  assign wb_csr_addr_q  = mem_csr_addr_q;

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
  wire        id_byp_a = wb_wen && (wb_rd_q == dec_rs1) && (dec_rs1 != 5'd0);
  wire        id_byp_b = wb_wen && (wb_rd_q == dec_rs2) && (dec_rs2 != 5'd0);
  wire [31:0] id_rdata_a = id_byp_a ? wb_wdata : rf_rdata_a;
  wire [31:0] id_rdata_b = id_byp_b ? wb_wdata : rf_rdata_b;

  // ============================================================ 时序
  always @(posedge clk) begin
    if (!rst_n) begin
      pc_q <= `RESET_PC;  cross_q <= 1'b0;  cross_hw0_q <= 16'd0;
      id_pc_q <= 32'd0; id_instr_q <= 32'h0000_0013; id_ilen_q <= 3'd4; id_valid_q <= 1'b0;

      ex_pc_q <= 32'd0; ex_instr_q <= 32'd0; ex_imm_q <= 32'd0;
      ex_rs1_val_q <= 32'd0; ex_rs2_val_q <= 32'd0;
      ex_rs1_q <= 5'd0; ex_rs2_q <= 5'd0; ex_rd_q <= 5'd0;
      ex_csr_addr_q <= 12'd0; ex_csr_rdata_q <= 32'd0;
      ex_ctrl_q <= 73'd0; ex_valid_q <= 1'b0; ex_rd_wen_q <= 1'b0;
      ex_excp_valid_q <= 1'b0; ex_excp_cause_q <= 4'd0; ex_excp_tval_q <= 32'd0;
      mdu_started_q <= 1'b0;

      mem_pc_q <= 32'd0; mem_instr_q <= 32'd0; mem_alu_q <= 32'd0; mem_addr_q <= 32'd0;
      mem_imm_q <= 32'd0; mem_rs1_val_q <= 32'd0; mem_rs2_val_q <= 32'd0; mem_csr_rdata_q <= 32'd0;
      mem_rd_q <= 5'd0; mem_csr_addr_q <= 12'd0;
      mem_wb_sel_q <= `WB_ALU; mem_mem_op_q <= `MEM_NONE; mem_sys_op_q <= 3'd0;
      mem_mem_size_q <= 2'd0; mem_mem_flags_q <= 2'd0; mem_csr_op_q <= `CSR_NONE;
      mem_rd_wen_q <= 1'b0; mem_valid_q <= 1'b0; mem_csr_imm_q <= 1'b0;
      mem_excp_valid_q <= 1'b0; mem_excp_cause_q <= 4'd0; mem_excp_tval_q <= 32'd0;

      memst_q <= M_IDLE; m_addr_q <= 32'd0; m_wdata_q <= 32'd0; m_rdata_q <= 32'd0;
      m_wstrb_q <= 4'd0; m_we_q <= 1'b0; m_err_q <= 1'b0;
      m_size_q <= 2'd0; m_uns_q <= 2'd0; m_excp_cause_q <= 4'd0; m_excp_tval_q <= 32'd0;

      wb_pc_q <= 32'd0; wb_instr_q <= 32'd0; wb_alu_q <= 32'd0; wb_imm_q <= 32'd0;
      wb_rs1_val_q <= 32'd0; wb_csr_rdata_q <= 32'd0; wb_mem_data_q <= 32'd0;
      wb_rd_q <= 5'd0; wb_wb_sel_q <= `WB_ALU; wb_sys_op_q <= 3'd0; wb_csr_op_q <= `CSR_NONE;
      wb_rd_wen_q <= 1'b0; wb_valid_q <= 1'b0; wb_csr_imm_q <= 1'b0;
      wb_excp_valid_q <= 1'b0; wb_excp_cause_q <= 4'd0; wb_excp_tval_q <= 32'd0;
    end else begin
      // ---------------- PC ----------------
      if (redirect_valid) pc_q <= redirect_pc;
      else if (advance_all && if_ready && !front_hold) pc_q <= pc_q + {29'd0, ilen_raw};

      if (redirect_valid) cross_q <= 1'b0;
      else if (advance_all && if_ready && !front_hold) begin
        if (need_cross) begin cross_q <= 1'b1; cross_hw0_q <= hw0; end
        else if (cross_q) cross_q <= 1'b0;
      end

      // ---------------- 访存 FSM（与 stall 并行推进） ----------------
      case (memst_q)
        M_IDLE: if (mem_needs_fsm) begin
            m_addr_q      <= mem_addr_q;
            m_we_q        <= (mem_mem_op_q != `MEM_LOAD);
            m_size_q      <= mem_mem_size_q;
            m_uns_q       <= mem_mem_flags_q;
            m_shift_q     <= mem_addr_q[1:0];
            m_split_q     <= mem_split;
            m_wdata_q     <= a1_wdata;
            m_wstrb_q     <= a1_wstrb;
            m_wstrb2_q    <= 4'hF >> (4 - (mem_nbytes - a1_bytes));
            m_excp_tval_q <= mem_addr_q;
            m_excp_cause_q<= `EXC_NONE;
            memst_q       <= M_REQ;
          end
        M_REQ:  if (d_req_ready) memst_q <= M_WAIT;
        M_WAIT: if (d_rsp_valid) begin
                  m_rdata_q <= d_rsp_rdata;
                  m_err_q   <= d_rsp_err;
                  if (d_rsp_err) begin
                    m_excp_cause_q <= m_we_q ? `EXC_STORE_ACCESS : `EXC_LOAD_ACCESS;
                    memst_q <= M_DONE;
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
        wb_mem_data_q  <= (mem_mem_op_q == `MEM_LOAD) ? mem_load_data : mem_alu_q;
        wb_rd_q        <= mem_rd_q;
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
          mem_csr_addr_q  <= ex_csr_addr_q;
          mem_wb_sel_q    <= e_wb_sel;
          mem_mem_op_q    <= e_mem_op;
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
