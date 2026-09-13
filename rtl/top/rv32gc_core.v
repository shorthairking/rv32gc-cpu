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

  // ---- AXI4 数据行填充通道（L1D refill：8 beat 突发 → 256 bit 整行）----
  output wire         dl_req_valid,
  output wire [31:0]  dl_req_addr,
  input  wire         dl_req_ready,
  input  wire         dl_rsp_valid,
  input  wire [255:0] dl_rsp_data,
  input  wire         dl_rsp_err,
  output wire         dl_rsp_ready,

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
  wire        fetch_err;      // 取指总线错误（来自 rv32_ifetch，cause 1）
  wire        fetch_pf;       // 取指页错误（来自 rv32_ifetch，cause 12）
  // ---- MMU（Sv32，③ 里程碑）：取指口 + 访存口 ----
  wire [31:0] mmu_if_pa;
  wire        mmu_if_pa_valid;
  wire        mmu_if_fault;
  wire        mmu_if_fault_is_access;   // 取指故障是"访问错误"（页表读 PMP 拒绝/总线错误）
  wire [31:0] mmu_d_pa;
  wire        mmu_d_pa_valid;
  wire        mmu_d_fault;
  wire        mmu_d_fault_is_access;    // 访存故障是"访问错误"（同上）⇒ cause 5/7 而非 13/15
  wire [3:0]  mmu_d_fault_cause;
  reg  [31:0] id_pa_q;        // ID 级指令的**物理**起始地址（取指侧 PMP 必须按 PA 检查）
  reg  [31:0] cross_pa_q;     // 跨行指令第一 parcel 的 PA（need_cross 拍锁存）

  // ---- D16② SPI-XIP 取指判定点：命中 SPI 窗口必须**绕过 I-Cache** ----
  // 平台复位取指窗口是 0x1C00_0000（SPI Flash XIP，无硬件 boot ROM；另有 0x1FE8_0000 别名），
  // 见 `rv32gc_defs.vh` 的 `IS_SPI_XIP 与 AGENT.md §2 D16。
  // 第 18 轮起取指行请求的下游是 **L1 指令 Cache**（`rtl/frontend/rv32_icache.v`，见下）：
  // 判定点由 `xip_bypass`（本信号，按 **PA** 组合判定，采样进 ifetch.req_xip_q）+
  // `rv32_icache` 内按**在途请求地址**的二次判定共同保证"XIP 行既不命中也不填充"。
  // MMU off（复位后、satp=0）时 PA==VA，两者等价；MMU on 时按 PA 判（窗口是物理属性）。
  wire        if_spi_xip = `IS_SPI_XIP(mmu_if_pa);   // 窗口判定按 **PA**

  // ---- L1 指令 Cache（阶段 2A-④）：插在 rv32_ifetch 与 rv32_axi_master 之间 ----
  // 16 KB = 128 组 × 4 路 × 32 B、VIPT（pa[11:5] 索引 / pa[31:12] 标记）、RR 替换、
  // 单未完成缺失。`fence.i` 提交拍 `fencei_take` 给 invalidate 一个脉冲（整表 1 拍全清）；
  // `sfence.vma` **不**失效它（物理标记 + 页内索引，见 spec/04-frontend.md §4.6）。
  // ENABLE=0 可整体关掉（直通基线），作为回归兜底安全阀。
  wire         ic_req_valid, ic_req_ready, ic_req_xip;
  wire [31:0]  ic_req_addr;
  wire         ic_rsp_valid, ic_rsp_err, ic_rsp_ready;
  wire [255:0] ic_rsp_data;
  wire         ic_alloc_wen;
  wire [31:0]  ic_alloc_addr;

  rv32_ifetch u_ifetch (
    .clk(clk), .rst_n(rst_n),
    .pc(fetch_pc), .hw0(hw0), .hw1(hw1), .line_valid(line_valid),
    .flush(flush_front), .xip_bypass(if_spi_xip), .req_xip(ic_req_xip),
    .pa_valid(mmu_if_pa_valid), .pa(mmu_if_pa), .xlate_fault(mmu_if_fault),
    .xlate_fault_pf(!mmu_if_fault_is_access),
    .if_req_valid(ic_req_valid), .if_req_addr(ic_req_addr), .if_req_ready(ic_req_ready),
    .if_rsp_valid(ic_rsp_valid), .if_rsp_data(ic_rsp_data),
    .if_rsp_err(ic_rsp_err), .if_rsp_ready(ic_rsp_ready),
    .fetch_err(fetch_err), .fetch_pf(fetch_pf)
  );

  wire         fencei_take;    // fence.i 提交拍（见下「sfence.vma / fence.i」段）

  rv32_icache #(.ENABLE(1)) u_icache (
    .clk(clk), .rst_n(rst_n),
    .invalidate(fencei_take),
    .req_valid(ic_req_valid), .req_addr(ic_req_addr), .req_xip(ic_req_xip),
    .req_ready(ic_req_ready),
    .rsp_valid(ic_rsp_valid), .rsp_data(ic_rsp_data), .rsp_err(ic_rsp_err),
    .rsp_ready(ic_rsp_ready),
    .axi_req_valid(if_req_valid), .axi_req_addr(if_req_addr), .axi_req_ready(if_req_ready),
    .axi_rsp_valid(if_rsp_valid), .axi_rsp_data(if_rsp_data), .axi_rsp_err(if_rsp_err),
    .axi_rsp_ready(if_rsp_ready),
    .dbg_alloc_wen(ic_alloc_wen), .dbg_alloc_addr(ic_alloc_addr),
    .dbg_hit(), .dbg_hit_way(), .dbg_set(),
    .perf_access(), .perf_hit(), .perf_miss()
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
  wire [`UOP_CTRL_W-1:0] dec_ctrl;

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
  wire        mstatus_tvm_w;    // TVM：S 模式下 sfence.vma 非法
  wire        mstatus_tsr_w;    // TSR：S 模式下 sret 非法
  wire        mstatus_sum_w;    // SUM（MMU 数据侧 live 权限判定）
  wire        mstatus_mxr_w;    // MXR（同上）
  wire [31:0] satp_w;           // satp {MODE, ASID, PPN}
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
    .trap_valid(trap_take_all),
    .trap_cause(if_err_take ? fetch_fault_cause : trap_cause_wb),
    .trap_tval (if_err_take ? pc_q : trap_tval_wb),
    .trap_is_int(trap_is_int), .trap_epc(if_err_take ? pc_q : trap_epc_w),
    .trap_vector(trap_vector), .trap_new_priv(trap_new_priv),
    .xret_valid(xret_take), .xret_is_sret(wb_is_sret),
    .xret_pc(xret_pc), .xret_new_priv(xret_new_priv),
    .priv_o(priv_q),
    .mstatus_mie(), .mstatus_sie(), .mstatus_mprv(mstatus_mprv_w), .mstatus_mpp(mstatus_mpp_w),
    .mstatus_tvm(mstatus_tvm_w), .mstatus_tsr(mstatus_tsr_w),
    .mstatus_sum(mstatus_sum_w), .mstatus_mxr(mstatus_mxr_w), .satp_o(satp_w),
    .timer_irq_pending(), .ext_irq_pending(),
    .menvcfg_cbcfe(menvcfg_cbcfe), .menvcfg_cbze(menvcfg_cbze), .menvcfg_cbie(menvcfg_cbie),
    .senvcfg_cbcfe(senvcfg_cbcfe), .senvcfg_cbze(senvcfg_cbze), .senvcfg_cbie(senvcfg_cbie),
    .pmpcfg_o(pmpcfg_all), .pmpaddr_o(pmpaddr_all),
    // 中断源：CLINT/PLIC 接入前先置 0（保持行为不变；下一轮换成真实源）
    .clint_msip(clint_msip_w), .clint_mtip(clint_mtip_w),
    .plic_meip(plic_meip_w),   .plic_seip(plic_seip_w),
    .intr_valid(intr_valid), .intr_cause(intr_cause)
  );
  wire        intr_valid;
  wire [3:0]  intr_cause;
  wire        trap_is_int;
  // Zicbom/Zicboz 低特权级执行许可（menvcfg/senvcfg 的 CBCFE/CBIE/CBZE）
  wire menvcfg_cbcfe, menvcfg_cbze;
  wire [1:0] menvcfg_cbie;
  wire senvcfg_cbcfe, senvcfg_cbze;
  wire [1:0] senvcfg_cbie;

  // ============================================================ PMP（阶段 2A：16 项，G=0）
  // 配置来自 `rv32_csr`（pmpcfg0-3 / pmpaddr0-15），匹配与权限由**纯组合**检查器
  // `rv32_pmp` 完成（规范要点见该文件头）。两个检查点：
  //   ① 取指：**ID 级**按指令地址检查 → cause 1，tval = 该指令地址；
  //   ② 访存：**MEM 的 M_IDLE**，在发起任何总线请求**之前**检查；不通过则不拉请求、直接进
  //      M_DONE，由 WB 级精确报 cause 5/7（与 misaligned 同一写法）。
  // ⚠ 关键（本项目已踩过的坑）：**不能用"闸掉总线请求"实现拒绝** —— M_IDLE 不发请求又不回
  //   M_DONE 会让 mem_stall 恒 1 ⇒ advance_all 恒 0 ⇒ 死锁且永不进 trap；取指侧若只是不拉
  //   if_req_valid，则 line_valid 永不置 ⇒ 前端死锁、ID 永远拿不到指令去报错。故取指违例在
  //   ID 报（指令虽已取回但**不执行**：rd/store/CSR 全部无副作用）。
  wire        mstatus_mprv_w;
  wire [1:0]  mstatus_mpp_w;
  wire [`PMP_ENTRIES*8-1:0]  pmpcfg_all;
  wire [`PMP_ENTRIES*32-1:0] pmpaddr_all;
  // 数据侧有效特权级：`mstatus.MPRV=1` 且当前为 M 时用 MPP（machine.adoc MPRV 语义）；
  // 取指**不受 MPRV 影响**（恒用当前特权级）。
  // MPRV/MPP 的**同拍旁路**：`csrs mstatus,(MPRV|MPP=S)` 紧跟 `sw/lw` 时，前一条 csrs 还停在 WB
  // 且因 mem_stall 未提交（此时 wb_csr_wen 为 0！），若直接用寄存器输出会把 M 模式当有效特权级
  // ⇒ 漏报 SMPU 违例（实测 PMPS/PMPU_mprv_check-01）。这里按"WB 待提交的 mstatus 写"取有效值。
  // 注意：**不能用 wb_csr_wen 门控**（停摆拍它是 0），要用 wb_csr_op_q 判"这是 CSR 写"。
  wire        mstat_pend = wb_valid_q && !wb_excp_valid_q && (wb_csr_op_q != `CSR_NONE) &&
                           (wb_csr_addr_q == `CSR_MSTATUS);
  wire        mprv_eff   = mstat_pend ? wb_csr_wdata[17] : mstatus_mprv_w;
  wire [1:0]  mpp_eff    = mstat_pend ? ((wb_csr_wdata[12:11] == 2'b10) ? `PRV_M : wb_csr_wdata[12:11])
                                      : mstatus_mpp_w;
  wire [1:0]  pmp_eff_priv_d = (((priv_q == `PRV_M) && mprv_eff) ? mpp_eff : priv_q);

  // mstatus.SUM/MXR 的**同拍旁路**（与上面 MPRV/MPP 同一类流水线冒险）：`csrs sstatus,(SUM|MXR)`
  // 紧跟 `lhu/lw/...` 时，csrs 与这条 load 分别处在 WB/MEM（程序序相邻 ⇒ 同拍），CSR 寄存器要到
  // 本拍时钟沿才更新，而 MMU 的权限判定是 MEM 级**组合**判定（rv32mmu_top.v:176-179 的
  // d_perm_u_fail/d_perm_rwx_ok 直接用 sum/mxr）⇒ 不做旁路会用旧值判权限、误报页错误。
  // 实测 sv32_exceptions_Zaamo_Umode（其余 Smode/Mmode 用例均通过）：S 模式陷阱处理器
  // `csrr a5,sstatus; lui t2,0xC0000; csrs sstatus,t2; lhu t2,0(s0)` 里那条 `lhu` 读的是
  // U 页（PTE_U=1），需要 SUM=1 才允许，DUT 报 cause 13，参考模型不报 ⇒ 后续陷阱序整段错位。
  // sstatus 只暴露 SUM/MXR（第 18/19 位）且位序与 mstatus 相同，故直接用 wb_csr_wdata 取位。
  wire        sxstat_pend = wb_valid_q && !wb_excp_valid_q && (wb_csr_op_q != `CSR_NONE) &&
                            ((wb_csr_addr_q == `CSR_MSTATUS) || (wb_csr_addr_q == `CSR_SSTATUS));
  wire        sum_eff = sxstat_pend ? wb_csr_wdata[18] : mstatus_sum_w;
  wire        mxr_eff = sxstat_pend ? wb_csr_wdata[19] : mstatus_mxr_w;

  // 访存侧：读相位与写相位各一个检查结果（AMO 先读后写 ⇒ 缺 R 报 cause 5、缺 W 报 cause 7，
  // 与 Spike 的 mmu 调用顺序一致；SC 与普通 store 一样按写检查）
  //
  // ---- Zicbom/Zicboz（MEM_CBO）：PMP 只查**操作数那 1 字节** ----
  // 依据 tools/spike/riscv/mmu.h:237-266：
  //   · cbo_zero()      —— `generate_access_info(addr, STORE, {})` + `translate(info, **1**)`
  //                        ⇒ 权限按 **W**（store 语义）、长度 **1 字节**（不是整块 32 B！）；
  //   · clean_inval()   —— `generate_access_info(addr, LOAD, {.clean_inval=true})` + `translate(info, 1)`
  //                        ⇒ 权限按 **R**（或 MXR&&X，与 LOAD 同规则）、长度 1 字节。
  // 对齐：CBO **无**对齐要求（Spike 的 access_info 不带 require_alignment），故 acc_size 取
  // BYTE 同时也就绕开了核内的非对齐判定（见 mem_misaligned 的 CBO 分支）。
  wire        mem_is_cbo    = (mem_mem_op_q == `MEM_CBO);
  wire        mem_cbo_zero  = mem_is_cbo && (mem_cbo_op_q == `CBO_ZERO);
  // 访存侧 PMP 引擎与 PTW 页表读检查器**共用一份匹配树**（不新增 rv32_pmp 实例：复制整条
  // 16 项 × 2 word 比较树实测让整核 iverilog 仿真慢 3× 以上）。仲裁：MEM 的 M_IDLE 检查拍
  // 优先（该拍必须给出结论），其余拍让给 PTW 的页表读检查。
  wire        mem_pmp_chk   = (memst_q == M_IDLE) && mem_needs_fsm && mem_addr_ready;
  wire        ptw_pmp_sel   = ptw_bus_req && !mem_pmp_chk;
  wire        ptw_pmp_ok    = pmp_d_r_ok;      // PTW 一律按 LOAD 检查（见下方注释）
  wire        ptw_pmp_deny  = ptw_pmp_sel && !ptw_pmp_ok;
  wire [1:0]  mem_pmp_size = mem_is_cbo ? 2'd0 :                     // CBO：只查 1 字节
                             (mem_mem_size_q == `MSZ_BYTE) ? 2'd0 :
                             (mem_mem_size_q == `MSZ_HALF) ? 2'd1 : 2'd2;
  wire        pmp_d_r_ok, pmp_d_w_ok;
  // 数据侧只实例化**一个**匹配引擎：permit 供读相位、permit2 供写相位
  // （AMO 先读后写 ⇒ 缺 R 报 cause 5、缺 W 报 cause 7，与 Spike 一致）。
  // PTW 页表读检查复用同一引擎（两组权限都设成 LOAD）：Spike 的 `pte_load()`
  // （tools/spike/riscv/mmu.h:486-497）对**每一次** PTE 读做
  //   `pmp_ok(pte_paddr, ptesize, LOAD, PRV_S, false)`
  // —— 特权级恒为 **S**（与发起访问的特权级无关），类型 LOAD，长度 4 字节。
  // 拒绝 ⇒ `throw_access_exception` ⇒ **访问错误**，cause 按原访问类型取（取指 1/load 5/
  // store·AMO·CBO 7），tval = 原 VA（pte_load 的 addr 参数传的是 gva，mmu.cc:596）。
  rv32_pmp u_pmp_d (
    .pmpcfg(pmpcfg_all), .pmpaddr(pmpaddr_all),
    .addr(ptw_pmp_sel ? ptw_bus_addr : mem_chk_addr),
    .acc_size(ptw_pmp_sel ? 2'd2 : mem_pmp_size),
    .eff_priv(ptw_pmp_sel ? `PRV_S : pmp_eff_priv_d),
    .need_r(1'b1), .need_w(1'b0), .need_x(1'b0),
    .need_r2(ptw_pmp_sel ? 1'b1 : 1'b0),
    .need_w2(ptw_pmp_sel ? 1'b0 : 1'b1),
    .need_x2(1'b0),
    .permit(pmp_d_r_ok), .permit2(pmp_d_w_ok), .match_any(), .match_all()
  );
  // 取指侧：**按 2 字节 parcel 分别检查**（与参考模型 Spike 一致，见下）。
  // ⚠ MMU 之后必须用**物理地址** `id_pa_q`（PMP 作用在 PA 上）；`tval` 仍取 VA（id_pc_q）。
  rv32_pmp u_pmp_if_a (
    .pmpcfg(pmpcfg_all), .pmpaddr(pmpaddr_all),
    .addr(id_pa_q), .acc_size(2'd1), .eff_priv(priv_q),
    .need_r(1'b0), .need_w(1'b0), .need_x(1'b1),
    .need_r2(1'b0), .need_w2(1'b0), .need_x2(1'b0),
    .permit(pmp_x_ok_a), .permit2(), .match_any(), .match_all()
  );
  rv32_pmp u_pmp_if_b (                 // 第二 parcel（仅 32 位指令用）
    .pmpcfg(pmpcfg_all), .pmpaddr(pmpaddr_all),
    .addr(id_pa_q + 32'd2), .acc_size(2'd1), .eff_priv(priv_q),
    .need_r(1'b0), .need_w(1'b0), .need_x(1'b1),
    .need_r2(1'b0), .need_w2(1'b0), .need_x2(1'b0),
    .permit(pmp_x_ok_b), .permit2(), .match_any(), .match_all()
  );
  // 为什么按 parcel 而不是"整条指令一次查"：`tools/spike/riscv/mmu.cc` 的 `fetch_slow_path`
  // 调 `translate(access_info, sizeof(insn_parcel_t))`，即 **len = 2 字节**；一条 32 位指令分
  // 两个 parcel 各查一次，而 `pmp_lookup` 把访问折算到 **4 字节扇区**（`addr & -gran`、gran=4）。
  // 若改成"整条指令必须被同一项覆盖全部扇区"，就比 Spike 更严 —— 实测在跨扇区/跨区域边界的
  // 指令上多报 cause 1（例：0x…0e 处的 32 位 nop，两个扇区分别由不同项允许时）。
  // `acc_size=1`（2 字节）恰好等价于"只查本 parcel 所在的 4 字节扇区"。

  // ============================================================ 核内 CLINT / PLIC（决策 D5）
  // 平台没有这两个设备窗口 ⇒ 核内实现，并在访存路径**截获**（不产生 AXI 请求）。
  // 地址窗口：CLINT 0x1F00_0000（1 MiB）；PLIC 0x1F10_0000 起 —— SiFive PLIC 1.0.0 的
  // threshold/claim 位于偏移 0x20_0000/0x20_1000，1 MiB 窗口覆盖不到，故取 0x1F10_0000–
  // 0x1F3F_FFFF（addr[31:20] ∈ {1F1,1F2,1F3}）。见 `rv32gc_defs.vh` 与 spec/07 §8。
  wire        mem_clint_hit = (mem_chk_addr[31:20] == 12'h1F0);
  wire        mem_plic_hit  = (mem_chk_addr[31:20] == 12'h1F1) ||
                              (mem_chk_addr[31:20] == 12'h1F2) ||
                              (mem_chk_addr[31:20] == 12'h1F3);
  // ⚠ CBO **不走**核内设备截获：平台在这两个窗口上本来就没有设备（CLINT/PLIC 是核内的），
  // 所以 CBO 落到这里必须交给总线裁决 —— 平台互联会给出 err ⇒ 报 store 访问错误 7，
  // 与 Spike 的 `sim->reservable(paddr)` 判定（设备/未映射区一律 trap_store_access_fault）
  // 一致；若在此截获，cbo.zero 会去写设备寄存器、cbo.clean 还会读到设备寄存器（有副作用）。
  wire        mem_io_hit    = (mem_clint_hit | mem_plic_hit) && !mem_is_cbo;
  wire        io_we    = (mem_mem_op_q == `MEM_STORE) || (mem_mem_op_q == `MEM_SC) ||
                         (mem_mem_op_q == `MEM_AMO);
  // 只在 M_IDLE 那一拍拉高（设备访问单拍完成；PLIC 的 claim 有"每拍都生效"的副作用，
  // 多拍保持会连续 claim —— 子 Agent 已提示）。
  wire        io_req   = (memst_q == M_IDLE) && mem_needs_fsm && mem_io_hit &&
                         !mem_misaligned && !mem_pmp_deny && mem_addr_ready;
  wire [3:0]  io_wstrb = a1_wstrb;
  wire [31:0] io_wdata = a1_wdata;
  wire [31:0] clint_rdata, plic_rdata;
  wire        clint_msip_w, clint_mtip_w, plic_meip_w, plic_seip_w;
  wire [31:0] io_rdata  = mem_clint_hit ? clint_rdata : plic_rdata;

  rv32_clint u_clint (
    .clk(clk), .rst_n(rst_n), .tick(1'b1),          // 仿真里 mtime 直接按核时钟 +1
    .req(io_req && mem_clint_hit), .we(io_we), .addr(mem_chk_addr),
    .wstrb(io_wstrb), .wdata(io_wdata), .rdata(clint_rdata),
    .msip(clint_msip_w), .mtip(clint_mtip_w)
  );
  rv32_plic #(.NSRC(8)) u_plic (
    .clk(clk), .rst_n(rst_n),
    .src({3'b000, intrpt[4:0]}),   // PLIC source 1..5 ← 平台 intrpt[0..4]（source 0 保留）
    .req(io_req && mem_plic_hit), .we(io_we), .addr(mem_chk_addr),
    .wstrb(io_wstrb), .wdata(io_wdata), .rdata(plic_rdata),
    .meip(plic_meip_w), .seip(plic_seip_w)
  );

  wire        pmp_mem_is_amo = (mem_mem_op_q == `MEM_AMO);
  wire        pmp_mem_is_w   = (mem_mem_op_q == `MEM_STORE) || (mem_mem_op_q == `MEM_SC);
  // CBO：ZERO 按写检查（W），CLEAN/FLUSH/INVAL 按读检查（R 或 MXR&&X —— MXR 已并入 MMU，
  // PMP 侧只看 R，与 Spike 的 pmp_ok(..., LOAD, ...) 一致）
  wire        mem_pmp_ok     = mem_is_cbo ? (mem_cbo_zero ? pmp_d_w_ok : pmp_d_r_ok)
                             : pmp_mem_is_amo ? (pmp_d_r_ok && pmp_d_w_ok)
                             : pmp_mem_is_w   ? pmp_d_w_ok
                                              : pmp_d_r_ok;
  // 访问类型（决定 MMU 权限、陷阱 cause 与总线错误口径）
  wire        mem_is_store_like = pmp_mem_is_w || pmp_mem_is_amo || mem_is_cbo;
  wire        mem_mmu_is_store  = pmp_mem_is_w || pmp_mem_is_amo || mem_cbo_zero;
  // AMO 被 PMP 拒绝时**一律**报 cause 7（store/AMO access fault）：Spike 的 `amo()`
  // （tools/spike/riscv/mmu.h:198-212）先走 store 检查，且整体被 convert_load_traps_to_store_traps
  // 包住 —— AMO 内部的 load fault 也会被转成 store fault。实测 PMPZaamo_cfg_wr-00 需要此口径。
  // Zicbom 同理：cbo_zero 本身就是 STORE；clean_inval 虽然按 LOAD 查权限，但它整体被
  // convert_load_traps_to_store_traps（mmu.h:181-194）包住 ⇒ 陷阱 cause 也取 store 变体
  // （页错误 15 / 访问错误 7），与 AMO 同一机制。
  wire [3:0]  mem_pmp_cause  = mem_is_store_like ? `EXC_STORE_ACCESS : `EXC_LOAD_ACCESS;
  // 页错误 cause（结构性 PTE 非法 / 权限 / A-D）：CBO 取 store 变体 15
  wire [3:0]  mem_pf_cause   = mem_is_store_like ? `EXC_STORE_PAGE_FAULT : `EXC_LOAD_PAGE_FAULT;
  // MMU 翻译故障的最终 cause：若是"页表读被 PMP 拒绝/总线错误"（Spike 的
  // `throw_access_exception`，mmu.h:486-497）则取**访问错误** 5/7，而不是页错误 13/15。
  wire [3:0]  mem_xlate_cause = mmu_d_fault_is_access ? mem_pmp_cause : mem_pf_cause;
  // 访存侧拒绝信号：**非对齐优先于 PMP**（与 Spike 一致）。
  // 依据 `tools/spike/riscv/mmu.cc:265-300`（load_slow_path / store_slow_path）：
  //   access_fault 判定 → 非对齐判定（cause 4/6）→ 才轮到（对齐/已拆分的）真正访存里的 PMP 检查
  //   （`pmp_ok` 在 `translate()` 内）。若把 PMP 放在最前面，对"既非对齐又被拒绝"的访问会报 5/7，
  //   而参考期望 4/6（实测 PMPZca_misaligned_{na4,napot,tor} 三例）。
`ifdef MISALIGNED_TRAP
  wire        mem_pmp_deny   = !mem_pmp_ok && !mem_misaligned;
`else
  wire        mem_pmp_deny   = !mem_pmp_ok;
`endif

  // ID 级异常
  wire        id_is_sys = (c_op_class == `OP_SYS);
  wire        id_ecall  = id_is_sys && (c_sys_op == `SYS_ECALL)  && dec_legal;
  wire        id_ebreak = id_is_sys && (c_sys_op == `SYS_EBREAK) && dec_legal;
  wire [3:0]  ecall_cause = (priv_q == `PRV_U) ? `DEXC_ECALL_U :
                            (priv_q == `PRV_S) ? `DEXC_ECALL_S : `DEXC_ECALL_M;
  // ---- Zicbom/Zicboz：低特权级执行许可检查（ID 级，产生非法指令异常）----
  // 规范（machine.adoc / supervisor.adoc）：
  //   · CBO.CLEAN/CBO.FLUSH：priv<M 时要求 menvcfg.CBCFE=1；priv=U 还要求 senvcfg.CBCFE=1；
  //   · CBO.ZERO          ：priv<M 时要求 menvcfg.CBZE=1； priv=U 还要求 senvcfg.CBZE=1；
  //   · CBO.INVAL         ：priv<M 时要求 menvcfg.CBIE∈{01,11}；priv=U 还要求 senvcfg.CBIE∈{01,11}。
  //   M 模式恒可执行。
  // 本核暂无 Cache（CBO 目前只是"走 LSU 的串行空操作"），因此这里只实现**许可与陷阱**语义。
  wire [1:0] id_cbo_op   = dec_ctrl[`CTRL_CBO_OP_H -: `CTRL_CBO_OP_W];
  wire       id_is_cbo   = id_valid_q && dec_legal && dec_ctrl[`CTRL_IS_CBO_H];
  wire       id_cbo_is_m = (priv_q == `PRV_M);
  wire       id_cbo_is_u = (priv_q == `PRV_U);
  // 各级许可（M 恒可执行）
  wire       cbo_clean_flush_ok = menvcfg_cbcfe && (!id_cbo_is_u || senvcfg_cbcfe);
  wire       cbo_zero_ok        = menvcfg_cbze  && (!id_cbo_is_u || senvcfg_cbze);
  wire       cbo_inval_ok       = (menvcfg_cbie == 2'b01 || menvcfg_cbie == 2'b11) &&
                                  (!id_cbo_is_u || (senvcfg_cbie == 2'b01 || senvcfg_cbie == 2'b11));
  wire       id_cbo_denied = id_is_cbo && !id_cbo_is_m &&
                             ((id_cbo_op == `CBO_CLEAN || id_cbo_op == `CBO_FLUSH) ? !cbo_clean_flush_ok :
                              (id_cbo_op == `CBO_ZERO)  ? !cbo_zero_ok  :
                              (id_cbo_op == `CBO_INVAL) ? !cbo_inval_ok  : 1'b0);

  // ---- PMP 取指违例（cause 1）：与"非法指令"同层，在 ID 精确报出 ----
  // 优先级高于非法指令（取指就被拒时 Spike 也是先报取指访问错误）。
  // tval 与 Spike 对齐：**被拒的那个 parcel 的地址**（第一 parcel 被拒 → pc；仅第二 parcel 被拒 → pc+2）。
  wire        id_pmp_x_fail_a = id_valid_q && !pmp_x_ok_a;
  wire        id_pmp_x_fail_b = id_valid_q && (id_ilen_q == 3'd4) && !pmp_x_ok_b;
  wire        id_pmp_x_fail   = id_pmp_x_fail_a || id_pmp_x_fail_b;
  wire [31:0] id_pmp_x_tval   = id_pmp_x_fail_a ? id_pc_q : (id_pc_q + 32'd2);
  // 非法指令的 mtval = **原始指令位**（不是译码器的展开形式）：
  //   Spike 的 `illegal_instruction()` 抛 `trap_illegal_instruction(insn.bits())`，对 16 位指令就是
  //   那 16 位本身（高半字为 0）。此前用 `dec_instr`（c.addi4spn 之类保留编码会被展开成 32 位
  //   `addi`）⇒ mtval 出现 0x00010413 这类"展开值"，与参考签名不符（实测 Tor/Na4 组多例）。
  wire [31:0] id_instr_raw    = (id_ilen_q == 3'd2) ? {16'd0, id_instr_q[15:0]} : id_instr_q;
  // CSR 访问合法性：`rv32_csr` 的 `csr_legal`（地址不存在 / 特权级不足 / 写只读 CSR）此前**从未被核使用**
  // ⇒ S 模式读写 pmpcfg/pmpaddr 会静默提交而不报非法指令（实测 PMPS/PMPU_csr_access 零陷阱）。
  wire        id_csr_ill   = (c_csr_op != `CSR_NONE) && !csr_legal;
  // sfence.vma 的特权级/TVM 检查（machine.adoc "TVM" + supervisor.adoc "SFENCE.VMA"）：
  //   · U 模式执行 sfence.vma **恒**为非法指令（该指令仅 S/M 可执行）；
  //   · S 模式且 mstatus.TVM=1 时非法（TVM 置位时 S 模式不得执行 SFENCE.VMA / 访问 satp）；
  //   · M 模式恒可执行。
  // 本核 sfence.vma 目前只做流水线串行化（无 TLB 可清），真正的失效在 ③ 里程碑接入 MMU 后补。
  wire        id_is_sfence = dec_ctrl[`CTRL_IS_SFENCE_H];
  wire        id_sfence_ill = id_is_sfence &&
                              ((priv_q == `PRV_U) || ((priv_q == `PRV_S) && mstatus_tvm_w));
  // MRET/SRET 的特权级检查（machine.adoc「Trap-Return Instructions」，norm:xretinhigher_mode）：
  //   · xRET 只能在其对应特权级**或更高**特权级执行 —— MRET 仅 M 可执行（S/U 非法）；
  //     SRET 在 U 模式非法，S/M 合法；
  //   · norm:mstatustsrop：TSR=1 时 S 模式执行 SRET 非法（WARL，本核 TVM 同批实现）。
  // 注：WFI 无需检查 —— norm:mstatustwumode_op 允许"在实现特定的有界时间内完成"的实现，
  //     本核 WFI 是立即完成的空操作，因此在 S/U 模式（含 TW=1）均为合法。
  wire        id_is_mret  = id_is_sys && (c_sys_op == `SYS_MRET) && dec_legal;
  wire        id_is_sret  = id_is_sys && (c_sys_op == `SYS_SRET) && dec_legal;
  wire        id_xret_ill = (id_is_mret && (priv_q != `PRV_M)) ||
                            (id_is_sret && ((priv_q == `PRV_U) ||
                                            ((priv_q == `PRV_S) && mstatus_tsr_w)));
  wire        id_illegal   = !dec_legal || id_cbo_denied || id_csr_ill || id_sfence_ill || id_xret_ill;
  wire        id_excp_valid = id_valid_q && (id_illegal || id_ecall || id_ebreak || id_pmp_x_fail);
  wire [3:0]  id_excp_cause = id_pmp_x_fail ? `EXC_INSTR_ACCESS :
                              id_illegal   ? `DEXC_ILLEGAL :
                              id_ebreak    ? `DEXC_BREAK : ecall_cause;
  wire [31:0] id_excp_tval  = id_pmp_x_fail ? id_pmp_x_tval :
                              id_illegal   ? id_instr_raw : 32'd0;

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
  reg  [`UOP_CTRL_W-1:0] ex_ctrl_q;
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
  // MEM 级（EX/MEM 寄存器）：ALU 类结果随时可转发；访存类（LOAD/LR/SC/AMO）的结果在
  // FSM 到达 M_DONE 的那一拍就已经在 mem_load_data 上（提前于 WB 级整整一拍），也必须转发。
  // 历史缺陷（本会话定位，见 AGENTS/AGENT.md 第 7 轮）：
  //   `mem_fwd_en` 曾要求 `mem_mem_op_q == MEM_NONE`，即访存结果在 MEM 级一律不转发，只能等
  //   WB。于是 "load/LR/SC → 紧跟依赖它的分支或运算" 会读到旧值一拍：
  //     sc.w a1,a1,(s0) / bnez a1,fail      → bnez 用错的 a1 判方向（sc.w 成功 rd=0 却当作非零）
  //     lw   t1,0(s0)   / bne t1,t2,fail    → bne 用旧 t1
  //   Lup 等被 load_use 停顿掩盖（EX 级 load 的消费者会被冻结），但 MEM 级访存结果的消费者
  //   不在 load_use 覆盖范围内，故必错。
  wire        mem_fwd_ready = mem_needs_fsm ? mem_done_now : 1'b1;
  wire        mem_fwd_en  = mem_valid_q && mem_rd_wen_q && (mem_rd_q != 5'd0) && mem_fwd_ready;
  wire [31:0] mem_fwd_val = (mem_wb_sel_q == `WB_PC4) ? (mem_pc_q + {29'd0, mem_ilen_q}) :
                            (mem_wb_sel_q == `WB_CSR) ? mem_csr_rdata_q :
                            (mem_wb_sel_q == `WB_MEM) ? mem_load_data : mem_alu_q;
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
  reg  [1:0]  mem_cbo_op_q;    // Zicbom/Zicboz：cbo.* 的操作类型（ZERO 与 CLEAN/FLUSH/INVAL 的
                               // 访问类型/副作用不同，见 mem_is_cbo 附近的说明）
  reg         mem_rd_wen_q, mem_valid_q, mem_csr_imm_q;
  reg         mem_excp_valid_q;
  reg  [3:0]  mem_excp_cause_q;
  reg  [31:0] mem_excp_tval_q;

  // ============================================================ MEM 级访问 FSM
  // 访存 FSM：支持非对齐访问的"两次单拍"拆分（跨 4 字节边界时）
  // M_XLATE（③ 里程碑新增）：Sv32 生效时的**翻译过渡态**。原 8 个状态码已用完，故扩到 4 位。
  // 语义：M_IDLE 发现"需要翻译且尚未翻译" ⇒ 进 M_XLATE 等 mmu_top 给 PA（或页错误），
  //   - 拿到 PA：写回 `m_addr_q`（此后它就是**物理地址**）、置 `m_xlated_q`，回 M_IDLE 走原路径；
  //   - 页错误：复用"不拉请求 + 直接进 M_DONE + 记 cause"的范式（尾随 VA 由 mem_addr_q 提供）；
  //   - 未就绪：停在 M_XLATE（`mem_stall` 已为 1 ⇒ 核内全局冻结，PTW 自驱总线取 PTE，无死锁）。
  localparam [3:0] M_IDLE = 4'd0, M_REQ = 4'd1, M_WAIT = 4'd2, M_DONE = 4'd3,
                   M_REQ2 = 4'd4, M_WAIT2 = 4'd5,
                   M_REQ_W = 4'd6, M_WAIT_W = 4'd7, M_XLATE = 4'd8;
  reg  [3:0]  memst_q;
  reg         m_xlated_q;      // m_addr_q 已由 MMU 翻译成 PA（仅对当前访问有效，M_DONE 时清）
  reg  [31:0] m_addr_q, m_wdata_q, m_rdata_q, m_rdata2_q, m_excp_tval_q;
  reg  [3:0]  m_wstrb_q, m_wstrb2_q;
  reg         m_we_q, m_err_q, m_split_q;
  reg  [1:0]  m_size_q, m_uns_q, m_shift_q;
  reg  [3:0]  m_excp_cause_q;
  // A 扩展：原子访问类型、amo 操作码、写数据、以及单 hart 保留集（LR/SC）
  reg         m_is_lr_q, m_is_sc_q, m_is_amo_q;
  reg  [4:0]  m_amo_op_q;
  reg  [31:0] m_rs2_q;
  // Zicbom/Zicboz：本次访存是否 CBO（决定陷阱 cause 口径）、是否 CBO.ZERO（决定块内写循环）、
  // 以及块内计数器（8 个 4 字节写）
  reg         m_is_cbo_q;
  reg         m_cbo_zero_q;
  reg  [2:0]  m_cbo_cnt_q;
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
  // 读响应当拍要用"即将锁存的 d_rsp_rdata"参与运算：m_rdata_q 与本组合逻辑在同一时钟沿更新，
  // 若直接用 m_rdata_q，M_WAIT 拍算出的新值会退化成 0+rs2（首次 AMO 必错）。
  wire [31:0] amo_base = dc_up_rsp_valid ? dc_up_rsp_rdata : m_rdata_q;
  always @(*) begin
    case (m_amo_op_q)
      `AMO_ADD:  amo_wdata = amo_base + m_rs2_q;
      `AMO_SWAP: amo_wdata = m_rs2_q;
      `AMO_XOR:  amo_wdata = amo_base ^ m_rs2_q;
      `AMO_OR:   amo_wdata = amo_base | m_rs2_q;
      `AMO_AND:  amo_wdata = amo_base & m_rs2_q;
      `AMO_MIN:  amo_wdata = ($signed(amo_base) < $signed(m_rs2_q)) ? amo_base : m_rs2_q;
      `AMO_MAX:  amo_wdata = ($signed(amo_base) > $signed(m_rs2_q)) ? amo_base : m_rs2_q;
      `AMO_MINU: amo_wdata = (amo_base < m_rs2_q) ? amo_base : m_rs2_q;
      `AMO_MAXU: amo_wdata = (amo_base > m_rs2_q) ? amo_base : m_rs2_q;
      default:   amo_wdata = m_rs2_q;
    endcase
  end

  // 请求有效须覆盖两次拆分访问：M_REQ（第一次）与 M_REQ2（第二次）。
  // 历史缺陷：只写了 M_REQ，非对齐拆分时第二次访问永不发请求、FSM 卡在 M_REQ2
  // （Zifencei / Zca 等用例里出现非对齐访问即整机停摆）。
  //
  // ============================ MMU：数据总线通道与 PTW 共用（③ 里程碑）============================
  // PTW 的页表读**必须**有路可走，但**不得**经过本 FSM 的状态机（否则 M_IDLE 等翻译、
  // 翻译又要 M_REQ 发请求 ⇒ 死锁）。做法：在**总线口**这一层做仲裁，MEM 优先、PTW 其次，
  // 且**同一时刻只允许一笔在途事务**（`d_busy_q`）—— 这样响应归属明确、AXI master 的单槽
  // 语义也不被破坏。
  wire        mem_want   = (memst_q == M_REQ) || (memst_q == M_REQ2) || (memst_q == M_REQ_W);
  wire        ptw_bus_req;     // rv32mmu_top 的页表读请求（见下方例化）
  wire [31:0] ptw_bus_addr;
  // PTW 的页表读只有在**共享 PMP 引擎本拍归它**且检查通过时才允许上文总线：
  //   · mem_pmp_chk=1 的拍引擎归 MEM（该拍必须给出 M_IDLE 的放行/拒绝结论）；
  //   · 被拒绝时不发请求，由 ptw_pmp_deny 让 PTW 直接进"访问错误"结果态。
  // 请求"保持到 ack"的语义不受影响：没被总线接收就等下一拍再试（不会丢响应）。
  wire        ptw_want   = ptw_bus_req && !mem_pmp_chk && ptw_pmp_ok;
  wire        d_is_ptw     = ptw_want && !mem_want;
  reg         d_busy_q;        // 有在途事务（直到收到响应）
  reg         d_owner_ptw_q;   // 在途事务归属：1 = PTW 页表读，0 = MEM 访存
  wire        d_req_valid_w = !d_busy_q && (mem_want || ptw_want);

  // ============================ L1D 数据 Cache（阶段 2A-④，第 20 轮新增）============================
  // 插入点：本仲裁点（MEM 优先、PTW 其次、单笔在途）与 rv32_axi_master 的 d 客户端之间。
  // 上游契约与原来的 d 端口逐位一致；`d_busy_q` 保证"接受一笔后在响应交付前不再发新请求"，
  // 因此 rv32_dcache 只需 1 个在途槽。模块内的策略（写直达+不写分配、读分配、VIPT、
  // XIP/PTW/原子/CBO 旁路）与出处见 `rtl/mem/rv32_dcache.v` 头部。
  // 三类旁路判定就在这个仲裁点上取信号，避免在模块里重新猜"这笔请求是谁发的"：
  //   · `dc_up_bypass`：PTW 页表读（页表项会被软件改写 ⇒ 必须每次看内存；且 PTW 读不可缓存的
  //     老坑：缓存的 PTE 在 sfence.vma 后会是陈旧的）；
  //   · `dc_up_atomic`：LR/SC/AMO 整体绕 Cache（保留集/原子性语义不走 Cache）；
  //   · `dc_up_cbo`   ：CBO CLEAN/FLUSH/INVAL 的"探针读"（保持第 17 轮的平台裁决语义不变，
  //     只额外在成功返回时失效该行；CBO.ZERO 不是探针读，它走 8 个普通写 ⇒ 不在此列）。
  wire        dc_up_req_ready;
  wire        dc_up_rsp_valid, dc_up_rsp_err;
  wire [31:0] dc_up_rsp_rdata;
  wire        dc_up_req_valid = d_req_valid_w;
  wire        dc_up_req_we    = mem_want ? ((memst_q == M_REQ_W) ? 1'b1 : m_we_q) : 1'b0;
  wire [31:0] dc_up_req_addr  = mem_want ? m_addr_q : ptw_bus_addr;
  wire [31:0] dc_up_req_wdata = m_wdata_q;
  wire [3:0]  dc_up_req_wstrb = m_wstrb_q;
  wire        dc_up_bypass    = d_is_ptw;
  wire        dc_up_atomic    = mem_want && (m_is_lr_q || m_is_sc_q || m_is_amo_q);
  wire        dc_up_cbo       = mem_want && m_is_cbo_q && !m_cbo_zero_q;

  rv32_dcache #(.ENABLE(1)) u_dcache (
    .clk(clk), .rst_n(rst_n),
    .up_req_valid(dc_up_req_valid), .up_req_we(dc_up_req_we), .up_req_addr(dc_up_req_addr),
    .up_req_wdata(dc_up_req_wdata), .up_req_wstrb(dc_up_req_wstrb),
    .up_req_ready(dc_up_req_ready),
    .up_rsp_valid(dc_up_rsp_valid), .up_rsp_rdata(dc_up_rsp_rdata), .up_rsp_err(dc_up_rsp_err),
    .up_rsp_ready(1'b1),                       // 原 `assign d_rsp_ready = 1'b1;`
    .up_bypass(dc_up_bypass), .up_atomic(dc_up_atomic), .up_cbo(dc_up_cbo),
    .dn_req_valid(d_req_valid), .dn_req_we(d_req_we), .dn_req_addr(d_req_addr),
    .dn_req_wdata(d_req_wdata), .dn_req_wstrb(d_req_wstrb), .dn_req_ready(d_req_ready),
    .dn_rsp_valid(d_rsp_valid), .dn_rsp_rdata(d_rsp_rdata), .dn_rsp_err(d_rsp_err),
    .dn_rsp_ready(d_rsp_ready),
    .dl_req_valid(dl_req_valid), .dl_req_addr(dl_req_addr), .dl_req_ready(dl_req_ready),
    .dl_rsp_valid(dl_rsp_valid), .dl_rsp_data(dl_rsp_data), .dl_rsp_err(dl_rsp_err),
    .dl_rsp_ready(dl_rsp_ready),
    .dbg_hit(), .dbg_hit_way(), .dbg_set(), .dbg_alloc_wen(), .dbg_alloc_addr(),
    .dbg_fill_busy(), .dbg_alloc_store(),
    .perf_access(), .perf_hit(), .perf_miss(), .perf_bypass()
  );

  wire        d_req_take   = dc_up_req_valid && dc_up_req_ready;
  // PTW 的应答（4 字节读）：只有归属 PTW 的响应才回给它
  wire [31:0] ptw_bus_rdata = dc_up_rsp_rdata;
  wire        ptw_bus_ack   = dc_up_rsp_valid && d_owner_ptw_q;
  wire        ptw_bus_err   = dc_up_rsp_err && d_owner_ptw_q;
  // MEM 侧只消费归属自己的响应（不变式：M_WAIT 时 owner 必为 0）
  wire        mem_rsp_valid = dc_up_rsp_valid && !d_owner_ptw_q;

  wire [4:0]  mem_ctrl_amo_op = mem_amo_op_q;
  // ⚠ **已带精确异常（ID 级判定）的指令不得产生访存副作用**：`mem_excp_valid_q` 是非法指令 /
  // ecall / 取指侧 PMP 违例这类 ID 级异常随 ID→EX→MEM 传下来的标志。历史上访存类指令不可能带
  // ID 级异常（那些异常只落在 CSR/SYS 类，mem_op=MEM_NONE），所以此处原先没有门控；CBO 引入后
  // 立刻暴露：`cbo.zero` 因 menvcfg/senvcfg 许可不足在 ID 被判非法（cause 2）后，MEM 级仍会
  // 把 32 字节清零写做完，再在 WB 报陷阱 —— **副作用与陷阱并存**（实测非特权
  // Zicboz-cbo.zero-00 的 cp_custom_cbo word 0 读回被清零而失败；基线把 CBO 译成
  // op_class=SYS/mem_op=NONE 才侥幸没暴露）。
  wire        mem_needs_fsm = mem_valid_q && (mem_mem_op_q != `MEM_NONE) && !mem_excp_valid_q;
  // ---- MMU（③）：翻译启用/就绪/请求 ----
  // 有效特权级 < M 且 satp.MODE=1 才翻译（MPRV/MPP 已并入 pmp_eff_priv_d，与 PMP 同口径）；
  // 非对齐**先于**翻译判定（与 Spike 的 load_slow_path/store_slow_path 一致）。
  wire        mem_trans_en   = satp_w[31] && (pmp_eff_priv_d != `PRV_M);
  // ⚠ 非对齐访问**不需要**翻译就绪：Spike 的 load_slow_path/store_slow_path 里"非对齐判定"先于
  //   `translate()`（tools/spike/riscv/mmu.cc:293-294 在 translate 之前抛 misaligned），且
  //   `mem_xlate_req` 本身也排除了非对齐 —— 若这里不把 misaligned 当作"就绪"，M_IDLE 会等一个
  //   永远不会发出的翻译请求 ⇒ **整核冻结**（实测 sv32_exceptions_Smode：memst=IDLE、ptw 空闲、
  //   零总线流量、pc 冻结在 0x300023a6，VA=0x9040d012 正是非对齐访存）。
  wire        mem_addr_ready = !mem_trans_en || m_xlated_q || mem_misaligned;
  wire        mem_xlate_req  = (memst_q == M_IDLE) && mem_needs_fsm && mem_trans_en &&
                               !m_xlated_q && !mem_misaligned;
  // PMP 与核内设备窗口判定一律用**物理地址**：翻译完成后是 m_addr_q，否则就是 mem_addr_q
  wire [31:0] mem_chk_addr   = m_xlated_q ? m_addr_q : mem_addr_q;

  //============================================================ MMU（Sv32）
  // 取指翻译：输入是**当前取指地址**（fetch_pc，含跨行时的 pc+2），输出 PA/页错误；
  // 访存翻译：输入是 MEM 级地址（VA），`d_req` 只在 M_IDLE 确实有访存时拉高（避免陈旧地址空走）。
  rv32mmu_top #(.ITLB_ENTRIES(8), .DTLB_ENTRIES(16)) u_mmu (
    .clk(clk), .rst_n(rst_n),
    .satp_mode(satp_w[31]), .satp_ppn(satp_w[21:0]), .satp_asid(satp_w[30:22]),
    .priv(priv_q), .d_eff_priv(pmp_eff_priv_d),
    .sum(sum_eff), .mxr(mxr_eff), .flush(sfence_take),
    .if_va(fetch_pc),
    .if_pa_valid(mmu_if_pa_valid), .if_pa(mmu_if_pa), .if_fault(mmu_if_fault),
    .if_fault_is_access(mmu_if_fault_is_access),
    .d_va(mem_addr_q), .d_is_store(mem_mmu_is_store), .d_req(mem_xlate_req),
    .d_pa_valid(mmu_d_pa_valid), .d_pa(mmu_d_pa),
    .d_fault(mmu_d_fault), .d_fault_cause(mmu_d_fault_cause),
    .d_fault_is_access(mmu_d_fault_is_access),
    .ptw_bus_req(ptw_bus_req), .ptw_bus_addr(ptw_bus_addr),
    .ptw_bus_rdata(ptw_bus_rdata), .ptw_bus_ack(ptw_bus_ack), .ptw_bus_err(ptw_bus_err),
    .ptw_bus_deny(ptw_pmp_deny)
  );
  wire        mem_done_now  = (memst_q == M_DONE);
  // 拆分判定（组合，基于 MEM 级寄存器）
  wire [2:0]  mem_nbytes = (mem_mem_size_q == `MSZ_BYTE) ? 3'd1 :
                           (mem_mem_size_q == `MSZ_HALF) ? 3'd2 : 3'd4;
  wire [2:0]  mem_shift  = {1'b0, mem_addr_q[1:0]};
  wire        mem_split  = ((mem_shift + mem_nbytes) > 3'd4);
  // 自然对齐检查（按访问宽度）：BYTE 恒对齐；HALF 要求 addr[0]==0；WORD 要求 addr[1:0]==0。
  // 默认（未定义 MISALIGNED_TRAP）非对齐访问由硬件拆成两次单拍完成；
  // 定义 MISALIGNED_TRAP 时改为报 cause 4/6（bring-up / arch-test：参考模型 Spike 默认如此）。
  // CBO **恒不报非对齐**：Spike 的 cbo_zero()/clean_inval() 走 access_info 时**不带**
  // require_alignment（tools/spike/riscv/mmu.h:237-266），操作数地址任意对齐都合法，
  // 块对齐（addr & ~31）只影响副作用范围、不影响异常。这里直接对 CBO 关掉该判定，
  // 同时下面 CBO 一律用 BYTE 长度做 PMP 检查（对齐/拆分路径都不参与）。
  wire        mem_misaligned = mem_is_cbo ? 1'b0 :
                               (mem_mem_size_q == `MSZ_WORD) ? (mem_addr_q[1:0] != 2'b00) :
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
  // 取指总线错误期间**不冻结流水线**（否则 fetch_stall 恒 1 ⇒ advance_all 恒 0 ⇒ 死锁，错误也永远
  // 取不走）：改为让 advance 继续、IF/ID 自动注入气泡（line_valid=0 ⇒ id_valid_q <= if_ready = 0），
  // 更老的指令照常排空；排空后取陷阱（epc=tval=出错 PC，pc_q 因 line_valid=0 不推进），flush 清错误。
  wire        fetch_err_pending = fetch_err;
  wire        fetch_stall = !line_valid && !fetch_err_pending;
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

  // ---- 陷阱注入：同步异常优先；无同步异常时在指令边界取中断 ----
  // 中断在「WB 级有有效指令、且该指令没有同步异常」的那一拍取出：该指令被 sq_mem 压制、
  // 不提交，mepc = 它的 PC ⇒ mret 后重新执行它 —— 即「在这条指令之前取中断」的经典边界。
  // 规范依据：machine.adoc norm:intrmipmie_op（mip&mie 同位 + mstatus.MIE/SIE + mideleg）。
  // 中断在 **WB 这条指令提交之后** 的边界取：mepc 指向"最老的未提交指令"（MEM→EX→ID→IF），
  // 这些年轻指令被 sq_mem/sq_ex 压制、mret 后重新执行；WB 那条照常提交。
  // 为什么不"在 WB 之前取"：MMIO 写（如 CLINT.msip）在 MEM 级就已落地，若把该 store 压制并让
  // mepc 指向它，mret 后它会重放——不但语义不精确，还可能造成"置位→重放置位"的循环。
  wire [31:0] intr_epc     = mem_valid_q ? mem_pc_q :
                             ex_valid_q  ? ex_pc_q  :
                             id_valid_q  ? id_pc_q  : pc_q;
  // 不要在「MEM 级副作用已落地」的指令上取中断：MEM 阶段的 store/SC/AMO 已把写发出（MMIO 写更是在
  // MEM 拍就生效），若把它当作 mepc 指向的"被打断指令"，mret 后重放会翻倍副作用。等它进入 WB 之后
  // 再取，此时 MEM 里是更年轻的指令（无副作用）⇒ mepc 精确指向下一条待执行指令。
  // CBO.ZERO 也是"副作用已落地"的写（32 字节清零），必须同样抑制（否则 mret 后重放再清一次，
  // 对普通内存无碍但语义不精确；CLEAN/FLUSH/INVAL 无副作用，一并抑制代价极低）。
  wire        mem_sideeff  = mem_valid_q && mem_needs_fsm &&
                             ((mem_mem_op_q == `MEM_STORE) || (mem_mem_op_q == `MEM_SC) ||
                              (mem_mem_op_q == `MEM_AMO)   || (mem_mem_op_q == `MEM_CBO) ||
                              mem_io_hit);
  wire        intr_take    = intr_valid && wb_valid_q && advance && !wb_excp_valid_q &&
                             !xret_take && !mem_sideeff;
  assign      trap_is_int  = intr_take;
  assign      trap_take     = wb_valid_q && advance && (wb_excp_valid_q || intr_take);
  // ---- 取指错误：总线错误（cause 1）或 MMU 页错误（cause 12）----
  // 两者共用同一条"停止取指 + 等流水线排空后取陷阱"的通路（rv32_ifetch 内的粘性错误 + 类型位）；
  // epc/tval 都是**出错取指地址**（pc_q，即当前 VA；页错误的 tval 正是该 VA）。
  wire [3:0]  fetch_fault_cause = fetch_pf ? `EXC_INSTR_PAGE_FAULT : `EXC_INSTR_ACCESS;
  wire        front_empty   = !(wb_valid_q || mem_valid_q || ex_valid_q || id_valid_q);
  wire        if_err_take   = fetch_err_pending && front_empty;
  wire        trap_take_all = trap_take | if_err_take;
  assign      trap_cause_wb = wb_excp_valid_q ? wb_excp_cause_q : intr_cause;
  assign      trap_tval_wb  = wb_excp_valid_q ? wb_excp_tval_q  : 32'd0;
  wire [31:0] trap_epc_w   = trap_is_int ? intr_epc : wb_pc;
  assign xret_take     = wb_valid_q && advance &&
                         ((wb_sys_op_q == `SYS_MRET) || (wb_sys_op_q == `SYS_SRET));
  assign wb_is_sret    = (wb_sys_op_q == `SYS_SRET);
  // ---- sfence.vma：提交拍执行（全清 TLBs + 丢弃在途 PTW + 强制冲刷前端）----
  // 为什么必须强制 `flush_front`：前端按"行号"比对命中，同 PA 不同 VA 时行号可能相同；
  // 且 sfence 之后按规范必须重新取指。S 模式且 TVM=1 时该指令已在 ID 级报非法（见 id_xret_ill 附近）。
  wire        wb_is_sfence = (wb_sys_op_q == `SYS_SFENCE_VMA);
  wire        sfence_take  = wb_valid_q && advance && wb_is_sfence && !wb_excp_valid_q;

  // ---- fence.i：提交拍（WB，is_serial ⇒ 更老的 store 已提交落盘）----
  // 动作：① L1I 整表失效（`u_icache.invalidate`，1 拍全清 512 个 valid 位）；
  //       ② 强制冲刷前端行缓冲（否则同一 32B 行内的自修改代码会继续用缓冲里的旧指令）。
  // 为什么用 `wb_retire`（= 提交拍）而不是 ID 级：fence.i 之前的 store 必须在它之前提交，
  //   本核 `is_serial` 的 `csr_order_stall` 保证 fence.i 离开 ID 时更老的指令已排空。
  // 为什么不在 fence.i 上失效 TLB / 重定向 PC：本设计 VIPT + 页内索引 + **物理**标记，
  //   地址空间切换不改变组号与标记 ⇒ 无需失效（`docs/design/spec/04-frontend.md` §4.6 第 2 行）。
  // 在途填充（AXI 读已发出、响应未回）由 u_icache 自行丢弃并重发，见 rv32_icache.v。
  wire        wb_is_fencei = (wb_sys_op_q == `SYS_FENCE_I);
  assign      fencei_take  = wb_retire && wb_is_fencei;   // 声明见 u_icache 例化处

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
  assign dbg_trap         = trap_take_all;
  assign dbg_trap_cause   = wb_excp_cause_q;

  wire        redirect_valid = trap_take_all | xret_take | ex_br_redirect | id_jal_taken;
  wire [31:0] redirect_pc    = trap_take_all  ? trap_vector :
                               xret_take      ? xret_pc :
                               ex_br_redirect ? br_target : id_jal_target;
  // 取指错误必须在取走陷阱那一拍**强制 flush**：否则若 trap_vector 与出错 PC 落在同一个 32B 行内，
  // 上面的行号比较不成立 ⇒ ifetch 的 err_q 清不掉 ⇒ 反复取同一条错误。
  // `fencei_take` 同样必须**无条件**冲刷（不看行号是否变化）：自修改代码可能就落在当前行缓冲
  // 所覆盖的同一 32B 行内，靠"行号不同"判定不会冲刷 ⇒ 仍会执行旧指令。
  assign flush_front = (redirect_valid && (redirect_pc[31:5] != pc_q[31:5])) ||
                       if_err_take || sfence_take || fencei_take;

  wire sq_id  = redirect_valid;
  wire sq_ex  = trap_take_all | xret_take | ex_br_redirect;
  wire sq_mem = trap_take_all | xret_take;

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
      ex_ctrl_q <= {`UOP_CTRL_W{1'b0}}; ex_valid_q <= 1'b0; ex_rd_wen_q <= 1'b0;
      ex_excp_valid_q <= 1'b0; ex_excp_cause_q <= 4'd0; ex_excp_tval_q <= 32'd0;

      mem_pc_q <= 32'd0; mem_instr_q <= 32'd0; mem_alu_q <= 32'd0; mem_addr_q <= 32'd0;
      mem_imm_q <= 32'd0; mem_rs1_val_q <= 32'd0; mem_rs2_val_q <= 32'd0; mem_csr_rdata_q <= 32'd0;
      mem_rd_q <= 5'd0; mem_ilen_q <= 3'd4; mem_csr_addr_q <= 12'd0;
      mem_wb_sel_q <= `WB_ALU; mem_mem_op_q <= `MEM_NONE; mem_sys_op_q <= 3'd0; mem_amo_op_q <= 5'd0;
      mem_mem_size_q <= 2'd0; mem_mem_flags_q <= 2'd0; mem_csr_op_q <= `CSR_NONE;
      mem_cbo_op_q <= 2'd0;
      mem_rd_wen_q <= 1'b0; mem_valid_q <= 1'b0; mem_csr_imm_q <= 1'b0;
      mem_excp_valid_q <= 1'b0; mem_excp_cause_q <= 4'd0; mem_excp_tval_q <= 32'd0;

      memst_q <= M_IDLE; m_addr_q <= 32'd0; m_wdata_q <= 32'd0; m_rdata_q <= 32'd0;
      m_xlated_q <= 1'b0; d_busy_q <= 1'b0; d_owner_ptw_q <= 1'b0;
      id_pa_q <= 32'd0; cross_pa_q <= 32'd0;
      m_rdata2_q <= 32'd0; m_wstrb2_q <= 4'd0; m_split_q <= 1'b0;
      m_is_lr_q <= 1'b0; m_is_sc_q <= 1'b0; m_is_amo_q <= 1'b0; m_amo_op_q <= 5'd0; m_rs2_q <= 32'd0;
      m_is_cbo_q <= 1'b0; m_cbo_zero_q <= 1'b0; m_cbo_cnt_q <= 3'd0;
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
      // ---- MMU：总线通道归属跟踪（一笔在途事务，响应按归属分派）----
      if (d_req_take) begin
        d_busy_q      <= 1'b1;
        d_owner_ptw_q <= d_is_ptw;
      end else if (dc_up_rsp_valid) begin
        d_busy_q      <= 1'b0;
      end
      if (redirect_valid) begin
        pc_q  <= redirect_pc;
        cross_q <= 1'b0;
      end else if (advance_all && !front_hold && line_valid) begin
        if (need_cross) begin
          cross_q     <= 1'b1;
          cross_hw0_q <= hw0;
          cross_pa_q  <= mmu_if_pa;   // 记下第一 parcel 的 **PA**（此刻 fetch_pc = pc_q）
        end else begin
          if (cross_q) cross_q <= 1'b0;
          if (if_ready) pc_q <= pc_q + {29'd0, ilen_raw};
        end
      end

      // ---------------- 访存 FSM（与 stall 并行推进） ----------------
      case (memst_q)
        M_IDLE: if (mem_needs_fsm) begin
            // ---- MMU 翻译阶段（只为 Sv32 生效且特权级 < M 的访问；非对齐在上面的分支已排除）----
            if (!mem_addr_ready) begin
              if (mmu_d_fault) begin
                // 页错误（cause 13/15）：复用"免请求 + 直接进 M_DONE + 记 cause"范式。
                // tval = **虚拟地址**（mem_addr_q 此刻仍是 VA）。
                m_addr_q      <= mem_chk_addr;
                m_we_q        <= 1'b0;
                m_size_q      <= mem_mem_size_q;
                m_uns_q       <= mem_mem_flags_q;
                m_shift_q     <= mem_addr_q[1:0];
                m_split_q     <= 1'b0;
                m_wdata_q     <= mem_rs2_val_q;
                m_wstrb_q     <= 4'h0;
                m_wstrb2_q    <= 4'h0;
                m_is_lr_q     <= 1'b0;      // 被拒的 LR/SC/AMO 不建立保留集
                m_is_sc_q     <= 1'b0;
                m_is_amo_q    <= 1'b0;
                m_is_cbo_q    <= 1'b0;
                m_cbo_zero_q  <= 1'b0;
                m_cbo_cnt_q   <= 3'd0;
                m_amo_op_q    <= 5'd0;
                m_rs2_q       <= mem_rs2_val_q;
                m_rdata_q     <= 32'd0;
                m_excp_tval_q <= mem_addr_q;
                m_excp_cause_q<= mem_xlate_cause;
                if (mem_is_sc || mem_is_amo) resv_valid_q <= 1'b0;
                memst_q       <= M_DONE;
              end else if (mmu_d_pa_valid) begin
                m_addr_q   <= mmu_d_pa;   // 从此 m_addr_q 就是**物理地址**
                m_xlated_q <= 1'b1;       // 下一拍在 M_IDLE 走原有的 PMP/设备/发起路径
              end
              // else：翻译未就绪 —— 停在 M_IDLE 等（mem_stall 已为 1，PTW 自驱总线，不死锁）
            end else if (mem_pmp_deny) begin
            // 拒绝路径完全复用 misaligned 的"免请求 + 直接进 M_DONE"写法：不拉 d_req_valid、
            // 不写任何字节，由 WB 级精确报 cause 5/7，tval = 出错地址。
            // （此时 mem_chk_addr 已是 **PA**：翻译完成才会走到这里）
              m_addr_q      <= mem_chk_addr;
              m_we_q        <= 1'b0;
              m_size_q      <= mem_mem_size_q;
              m_uns_q       <= mem_mem_flags_q;
              m_shift_q     <= mem_addr_q[1:0];
              m_split_q     <= 1'b0;
              m_wdata_q     <= mem_rs2_val_q;
              m_wstrb_q     <= 4'h0;
              m_wstrb2_q    <= 4'h0;
              m_is_lr_q     <= 1'b0;      // 被拒的 LR/SC/AMO 不建立保留集
              m_is_sc_q     <= 1'b0;
              m_is_amo_q    <= 1'b0;
              m_is_cbo_q    <= 1'b0;
              m_cbo_zero_q  <= 1'b0;
              m_cbo_cnt_q   <= 3'd0;
              m_amo_op_q    <= 5'd0;
              m_rs2_q       <= mem_rs2_val_q;
              m_excp_tval_q <= mem_addr_q;
              m_excp_cause_q<= mem_pmp_cause;
              // 被拒的 SC/AMO 消费保留集（规范：SC 失败 / 任何写访问都使保留集失效）
              if (mem_is_sc || mem_is_amo) resv_valid_q <= 1'b0;
              memst_q       <= M_DONE;
            end else if (mem_is_cbo) begin
            // ================= Zicbom/Zicboz：走 MEM 级访存通路（③ 之后新增）=================
            // 前置条件已满足：翻译完成（mem_chk_addr 是 PA）且 PMP 通过（只查操作数那 1 字节）。
            // 语义与 tools/spike/riscv/mmu.h:237-266 逐条对齐：
            //   · CBO.ZERO：物理块基址 = PA & ~(32-1)，对整块 **真的写 32 个 0**（8 个 4 字节写）。
            //     Spike 是 `paddr = translate(...) - (transformed_addr & (blocksz-1))` 后
            //     `memset(host_addr, 0, blocksz)`；翻译保留页内偏移且 4K/4M 页都满足
            //     `PA - (VA & 31) == PA & ~31`，故这里直接用块基址。
            //   · CLEAN/FLUSH/INVAL：无 Cache ⇒ **无内存副作用**，只做一次读（4 字节、块基址）
            //     让平台裁决"该 PA 是否可访问"：总线 err ⇒ store 访问错误 7
            //     （Spike 用 `sim->reservable(paddr)` 做同一判定，失败抛 trap_store_access_fault）。
            //     块基址与操作数 PA 同属一个 32 B 块，用块基址与 Spike 的判定地址一致。
            // 地址**不做对齐要求**；tval 一律记**操作数 VA**（mem_addr_q 此刻仍是 VA）。
              m_is_cbo_q    <= 1'b1;
              m_cbo_zero_q  <= mem_cbo_zero;
              m_cbo_cnt_q   <= 3'd0;
              m_rdata_q     <= 32'd0;
              m_rdata2_q    <= 32'd0;
              m_is_lr_q     <= 1'b0;
              m_is_sc_q     <= 1'b0;
              m_is_amo_q    <= 1'b0;
              m_amo_op_q    <= 5'd0;
              m_rs2_q       <= mem_rs2_val_q;
              m_excp_tval_q <= mem_addr_q;
              m_excp_cause_q<= `EXC_NONE;
              if (mem_cbo_zero) begin
                m_addr_q   <= {mem_chk_addr[31:5], 5'b0};            // 32 B 块基址
                m_we_q     <= 1'b1;
                m_size_q   <= `MSZ_WORD;
                m_uns_q    <= 2'd0;
                m_shift_q  <= 2'b00;
                m_split_q  <= 1'b0;
                m_wdata_q  <= 32'd0;
                m_wstrb_q  <= 4'hF;
                m_wstrb2_q <= 4'h0;
                memst_q    <= M_REQ_W;       // 8 个 4 字节 0 写，写响应后在 M_WAIT_W 里续写
              end else begin
                m_addr_q   <= {mem_chk_addr[31:5], 5'b0};           // 只读检查，不写
                m_we_q     <= 1'b0;
                m_size_q   <= `MSZ_BYTE;    // 对齐无关；返回值丢弃
                m_uns_q    <= `MF_UNSIGNED;
                m_shift_q  <= 2'b00;
                m_split_q  <= 1'b0;
                m_wdata_q  <= 32'd0;
                m_wstrb_q  <= 4'h0;
                m_wstrb2_q <= 4'h0;
                memst_q    <= M_REQ;
              end
            end else if (mem_io_hit) begin
              // ---- 核内设备（CLINT/PLIC）：单拍完成，不产生 AXI 请求 ----
              if (mem_misaligned) begin
                // 设备寄存器一律要求自然对齐（规范：misaligned access to I/O 必报 misaligned）
                m_excp_tval_q <= mem_addr_q;
                m_excp_cause_q<= (mem_mem_op_q == `MEM_LOAD) ? `EXC_LOAD_MISALIGN
                                                            : `EXC_STORE_MISALIGN;
                memst_q       <= M_DONE;
              end else begin
                m_addr_q      <= mem_chk_addr;
                m_we_q        <= 1'b0;
                m_size_q      <= mem_mem_size_q;
                m_uns_q       <= mem_mem_flags_q;
                m_shift_q     <= mem_addr_q[1:0];
                m_split_q     <= 1'b0;
                m_wdata_q     <= a1_wdata;
                m_wstrb_q     <= a1_wstrb;
                m_wstrb2_q    <= 4'h0;
                m_is_lr_q     <= 1'b0;      // 设备不支持原子访问（LR/SC/AMO 当作普通访问）
                m_is_sc_q     <= 1'b0;
                m_is_amo_q    <= 1'b0;
                m_amo_op_q    <= 5'd0;
                m_rs2_q       <= mem_rs2_val_q;
                m_rdata_q     <= io_rdata;  // 读数据同拍锁存（沿用既有的拆分/扩展逻辑）
                m_rdata2_q    <= 32'd0;
                m_excp_tval_q <= mem_addr_q;
                m_excp_cause_q<= `EXC_NONE;
                memst_q       <= M_DONE;
              end
            end else begin
`ifdef MISALIGNED_TRAP
            if (mem_misaligned) begin
              // 不做拆分访问：直接进入 M_DONE 并在 WB 级精确报地址非对齐异常
              m_addr_q      <= mem_chk_addr;
              m_we_q        <= (mem_mem_op_q == `MEM_STORE);   // 只有普通 store 在本阶段写；LR/AMO 先读，SC/AMO 的写在 M_REQ_W
              m_size_q      <= mem_mem_size_q;
              m_uns_q       <= mem_mem_flags_q;
              m_shift_q     <= mem_addr_q[1:0];
              m_split_q     <= 1'b0;
              m_wdata_q     <= mem_rs2_val_q;
              m_wstrb_q     <= 4'h0;
              m_wstrb2_q    <= 4'h0;
              m_excp_tval_q <= mem_addr_q;
              // cause 按指令自身的访问类型：LOAD/LR 是 load ⇒ 4；STORE/SC/AMO 是 store ⇒ 6。
              // LR 走 Spike 的 `load_reserved`（mmu.h:124 → load 路径，require_alignment）
              // ⇒ load address-misaligned；SC/AMO 走 store 侧（SC 由 `check_load_reservation`
              //  的 store_slow_path、AMO 被 convert_load_traps_to_store_traps 包住）⇒ 6。
              // 实测参考签名 sv32_exceptions_Zalrsc_Smode 前两条 = 4@lr.w + 6@sc.w。
              m_excp_cause_q<= (mem_mem_op_q == `MEM_LOAD || mem_mem_op_q == `MEM_LR)
                              ? `EXC_LOAD_MISALIGN : `EXC_STORE_MISALIGN;
              memst_q       <= M_DONE;
            end else begin
`endif
            m_addr_q      <= mem_chk_addr;
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
            // 原子操作不可拆分：地址非自然对齐一律报地址非对齐异常（与 MISALIGNED_TRAP 无关）。
            // cause 按**指令自身的访问类型**取：LR 是 load ⇒ 4；SC/AMO 是 store ⇒ 6
            // （依据 Spike：LR 走 `load_reserved`→`load(..., {.lr=true,.require_alignment=true})`
            //  ⇒ trap_load_address_misaligned；SC 走 `check_load_reservation` 的
            //  `store_slow_path(..., require_alignment=true)` ⇒ store 侧；AMO 被
            //  convert_load_traps_to_store_traps 包住 ⇒ 6。实测参考签名
            //  sv32_exceptions_Zalrsc_Smode 前两条正是 4@lr.w + 6@sc.w）。
            if (mem_is_atomic && mem_misaligned) begin
              m_excp_cause_q <= mem_is_lr ? `EXC_LOAD_MISALIGN : `EXC_STORE_MISALIGN;
              if (mem_is_sc) resv_valid_q <= 1'b0;   // 失败的 SC 也消费保留集
              memst_q        <= M_DONE;
            end else if (mem_is_sc) begin
              // SC：先按 Spike `mmu_t::check_load_reservation`（tools/spike/riscv/mmu.h:274-292）的顺序做
              // "translate(store) + PMP + 平台 PMA 判定"，**然后**才比较保留集：
              //   · 保留集比较必须用**物理地址**：Spike 的 LR 把 `paddr` 写进 `load_reservation_address`
              //     （mmu.cc:259），SC 用 `paddr` 比较（mmu.h:285）——用 VA 比在开启翻译后必然失配。
              //   · 保留集无效时**仍要把地址送到总线**（写使能被 wstrb=0 抑制）：Spike 在保留集比较之前
              //     先做 `sim->reservable(paddr)`（mmu.h:285-288），未映射/设备区一律 store access fault；
              //     本核没有静态 PMA 表，由平台互连给出同样的裁决（未映射 → SLVERR → cause 7）。
              //     若在这里"直接 rd=1 收工"，sv32_exceptions_Zalrsc 的 Case 3（有效 PTE 指向
              //     RVMODEL_ACCESS_FAULT_ADDRESS）就少了参考签名里的那条 cause 7 陷阱。
              if (resv_valid_q && (resv_addr_q == mem_chk_addr)) begin
                m_wdata_q <= mem_rs2_val_q;
                m_wstrb_q <= 4'hF;
                m_rdata_q <= 32'd0;
              end else begin
                m_wdata_q <= 32'd0;
                m_wstrb_q <= 4'h0;               // 不写任何字节（SC 失败不得改写内存）
                m_rdata_q <= 32'd1;
              end
              resv_valid_q <= 1'b0;              // 成功/失败都消费保留集
              memst_q      <= M_REQ_W;
            end else begin
              // 普通 store / LOAD / AMO 进入 MEM：按 RISC-V 规范（unpriv "Load-Reserved/
              // Store-Conditional"）"the reservation is ... invalidated by any store"，
              // 这里对**发起** store 的拍清保留集。
              // 注意：AMO 的写发生在读之后的 M_REQ_W，故这里只处理 MEM_STORE；
              // AMO/LR 在各自命中路径上处理（见 M_WAIT 分支）。
              // 历史缺陷（本会话定位）：保留集只在 trap / WB 写响应出错时清，普通 store
              // 不清 → LR → sw → SC 会错误地成功（arch-test Zalrsc 的 sc_after_store 类用例）。
              if (mem_mem_op_q == `MEM_STORE) resv_valid_q <= 1'b0;
              memst_q <= M_REQ;          // load/store/LR/AMO：发起访问（LR/AMO 为读）
            end
`ifdef MISALIGNED_TRAP
            end
`endif
            end
          end
        // M_XLATE 理论上不会被用到（翻译等待就地在 M_IDLE 完成），保留作为兜底并把 PA 采纳进来
        M_XLATE: begin
          if (mmu_d_pa_valid) begin m_addr_q <= mmu_d_pa; m_xlated_q <= 1'b1; memst_q <= M_IDLE; end
          else if (mmu_d_fault) begin
            m_excp_tval_q  <= mem_addr_q;
            m_excp_cause_q <= mmu_d_fault_cause;
            m_we_q         <= 1'b0;
            m_split_q      <= 1'b0;
            memst_q        <= M_DONE;
          end
        end
        M_REQ:  if (d_req_take) memst_q <= M_WAIT;
        M_WAIT: if (mem_rsp_valid) begin
                  m_rdata_q <= dc_up_rsp_rdata;
                  m_err_q   <= dc_up_rsp_err;
                  if (dc_up_rsp_err) begin
                    m_excp_cause_q <= (m_we_q || m_is_amo_q || m_is_sc_q || m_is_cbo_q)
                                      ? `EXC_STORE_ACCESS : `EXC_LOAD_ACCESS;
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
        M_REQ2: if (d_req_take) memst_q <= M_WAIT2;
        M_WAIT2: if (mem_rsp_valid) begin
                  m_rdata2_q <= dc_up_rsp_rdata;
                  if (dc_up_rsp_err) m_excp_cause_q <= m_we_q ? `EXC_STORE_ACCESS : `EXC_LOAD_ACCESS;
                  memst_q <= M_DONE;
                end
        M_REQ_W:  if (d_req_take) memst_q <= M_WAIT_W;
        M_WAIT_W: if (mem_rsp_valid) begin
                    // 写响应：出错按 store 访问错误记账（rd 数据对 SC 成功为 0，对齐已保证）
                    if (dc_up_rsp_err) m_excp_cause_q <= `EXC_STORE_ACCESS;
                    // SC 的写完成 → 保留集已被消费；AMO 的写完成 → 同样使保留集失效
                    if (m_is_sc_q || m_is_amo_q) resv_valid_q <= 1'b0;
                    // ---- CBO.ZERO：块内 8 个 4 字节写，写响应后续写下一个字 ----
                    // （Spike 是一次 memset 32 字节；本核按 4 字节总线上限拆成 8 笔，
                    //   任何一笔出错即记 store 访问错误 7 并停止 —— 与 Spike 在
                    //   `sim->addr_to_mem(paddr)==nullptr` 时直接 trap 同类。）
                    if (m_cbo_zero_q && !dc_up_rsp_err && (m_cbo_cnt_q != 3'd7)) begin
                      m_cbo_cnt_q <= m_cbo_cnt_q + 3'd1;
                      m_addr_q    <= m_addr_q + 32'd4;
                      m_wdata_q   <= 32'd0;
                      m_wstrb_q   <= 4'hF;
                      m_size_q    <= `MSZ_WORD;
                      memst_q     <= M_REQ_W;
                    end else begin
                      // ⚠ 必须清掉"块内写循环"标志：否则下一条 SC/AMO 进入 M_WAIT_W 时
                      // 会误判成 CBO.ZERO 的第 2..8 个字继续往 m_addr_q+4 写 0（实测隐患，
                      // cbo.clean（不写内存）后紧跟 amoswap 就会触发）。所有写相位都经此处。
                      m_cbo_zero_q <= 1'b0;
                      memst_q      <= M_DONE;
                    end
                  end
        // M_DONE 必须"linger"到该指令真正离开 MEM：本核允许 MEM 指令在 FSM 完成后仍被前端
        // 停顿（fetch_stall/front_hold 时 advance_all=0）继续占住 MEM 级若干拍。若此时直接回
        // M_IDLE，FSM 会**再次执行同一条指令**——对 SC 是致命的：第一次已把保留集消费掉，
        // 第二次重入即见到 resv=0 → 走失败分支把 rd 改成 1（甚至再发一次写）。
        // 历史缺陷（本会话定位）：Zalrsc 的 SC 在 fetch 停顿下必然 rd=1，且同一地址被写两次。
        M_DONE: if (!mem_valid_q || advance_all) begin
                  memst_q    <= M_IDLE;
                  m_xlated_q <= 1'b0;      // 翻译结果只对本次访问有效
                end
        default: begin memst_q <= M_IDLE; m_xlated_q <= 1'b0; end
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
          mem_cbo_op_q    <= ex_ctrl_q[`CTRL_CBO_OP_H -: `CTRL_CBO_OP_W];
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
          id_pa_q    <= cross_q ? cross_pa_q : mmu_if_pa;   // 指令起始的物理地址（取指 PMP 用）
          id_instr_q <= instr_raw;
          id_ilen_q  <= ilen_raw;
          id_valid_q <= if_ready;
        end
      end
    end
  end

endmodule
