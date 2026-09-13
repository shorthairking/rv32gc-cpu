//=============================================================================
// rv32_csr.v —— 基线 CSR 文件 + 陷阱控制（阶段 2A 第一版）
//
// 实现范围（后续阶段扩展）：
//   · M/S/U 三特权级，机器级与监管级 CSR（见 docs/design/spec/07-priv-csr-mmu.md）
//   · 同步异常与中断的进入/返回（mret/sret）、委托 medeleg/mideleg
//   · 计数器 mcycle/minstret（64 位，RV32 高低半）
// 暂未实现（后续里程碑）：PMP、TLB/satp 生效、CLINT/PLIC 外部中断、menvcfg/senvcfg 的
//   CBO 之外字段（FIOM/PMM/DTE 等一律读 0）。menvcfg/senvcfg 目前只实现 Zicbom/Zicboz 的
//   CBCFE/CBIE/CBZE 位（核内 CBO 低特权级许可检查用）。
//
// 读端口：组合；写端口：提交级单拍（csr_wdata 已由核内按 CSR_RW/RS/RC 语义算好）
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_csr (
  input  wire        clk,
  input  wire        rst_n,

  // ---- 执行级读（组合） ----
  input  wire [11:0] csr_raddr,
  input  wire [1:0]  priv,            // 当前特权级
  output reg  [31:0] csr_rdata,
  output reg         csr_legal,       // 0 = 该 CSR 不存在或权限不足（触发非法指令）

  // ---- 提交级写 ----
  input  wire        csr_wen,
  input  wire [11:0] csr_waddr,
  input  wire [31:0] csr_wdata,       // 已算好的最终写入值
  input  wire        csr_is_fp,

  // ---- 计数器 ----
  input  wire        instret_en,      // 提交一条指令（不含 x0 写等，按规范"退休指令数"）

  // ---- 陷阱进入 ----
  input  wire        trap_valid,
  input  wire [3:0]  trap_cause,
  input  wire [31:0] trap_tval,
  input  wire        trap_is_int,
  input  wire [31:0] trap_epc,
  output wire [31:0] trap_vector,
  output wire [1:0]  trap_new_priv,

  // ---- 陷阱返回 ----
  input  wire        xret_valid,
  input  wire        xret_is_sret,
  output wire [31:0] xret_pc,
  output wire [1:0]  xret_new_priv,

  // ---- 状态输出 ----
  output wire [1:0]  priv_o,
  output wire        mstatus_mie,
  output wire        mstatus_sie,
  output wire        mstatus_mprv,
  output wire [1:0]  mstatus_mpp,
  output wire        timer_irq_pending,   // 预留：CLINT 比较器
  output wire        ext_irq_pending,     // 预留：PLIC

  // ---- Zicbom/Zicboz 低特权级执行许可（供核内 CBO 模式检查）----
  // 语义：machine.adoc norm:menvcfgcbcfeop / norm:menvcfgcbiecbo-invaloplead-in；
  //       supervisor.adoc「senvcfg 的 CBCFE/CBIE 控制 U 模式」。
  output wire        menvcfg_cbcfe,       // CBO.CLEAN/CBO.FLUSH 在 <M 模式允许执行
  output wire        menvcfg_cbze,        // CBO.ZERO 在 <M 模式允许执行
  output wire [1:0]  menvcfg_cbie,        // CBO.INVAL 在 <M 模式的使能（0b00=禁用）
  output wire        senvcfg_cbcfe,       // U 模式额外条件
  output wire        senvcfg_cbze,        // U 模式额外条件
  output wire [1:0]  senvcfg_cbie         // U 模式额外条件
);

  // ---------------------------------------------------------------- 状态寄存器
  reg [1:0]  priv_q;          // 当前特权级
  reg [2:0]  mstatus_mie_q, mstatus_mpie_q;   // 单比特用 [0]
  reg [1:0]  mstatus_mpp_q;
  reg [0:0]  mstatus_sie_q, mstatus_spie_q, mstatus_spp_q;
  reg [0:0]  mstatus_mprv_q, mstatus_sum_q, mstatus_mxr_q, mstatus_tw_q, mstatus_tsr_q, mstatus_tvm_q;
  reg [1:0]  mstatus_fs_q;

  reg [31:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
  reg [31:0] medeleg_q, mideleg_q, mie_q, mip_q;
  reg [31:0] mcounteren_q;

  reg [31:0] stvec_q, sscratch_q, sepc_q, scause_q, stval_q;
  reg [31:0] sie_q, sip_q, scounteren_q, satp_q;
  // menvcfg/senvcfg：本核只用到它们的 CBO（Zicbom/Zicboz）低特权级执行许可位。
  // 位域（RV32）：CBIE[5:4]、CBCFE[6]、CBZE[7]（machine.adoc menvcfg / supervisor.adoc senvcfg）。
  // 复位为 0 = 低特权级禁用 CBO，与规范默认一致。
  reg [31:0] menvcfg_q, senvcfg_q;

  reg [63:0] mcycle_q, minstret_q;

  // 常量：本实现支持的异常委托位（0..9,11..13,15 中去除 M 模式 ecall=11 与保留）
  localparam [31:0] MEDELEG_MASK = 32'h0000_B3FF;  // 0,1,2,3,4,5,6,7,8,9,12,13,15
  localparam [31:0] MIDELEG_MASK = 32'h0000_0222;  // 1(SSI),5(STI),9(SEI)

  assign priv_o        = priv_q;
  assign mstatus_mie   = mstatus_mie_q[0];
  assign mstatus_sie   = mstatus_sie_q[0];
  assign mstatus_mprv  = mstatus_mprv_q[0];
  assign mstatus_mpp   = mstatus_mpp_q;
  assign timer_irq_pending = 1'b0;    // 预留
  assign ext_irq_pending   = 1'b0;    // 预留

  // Zicbom/Zicboz 许可位：RV32 位域 CBIE[5:4] / CBCFE[6] / CBZE[7]
  assign menvcfg_cbze   = menvcfg_q[7];
  assign menvcfg_cbcfe  = menvcfg_q[6];
  assign menvcfg_cbie   = menvcfg_q[5:4];
  assign senvcfg_cbze   = senvcfg_q[7];
  assign senvcfg_cbcfe  = senvcfg_q[6];
  assign senvcfg_cbie   = senvcfg_q[5:4];

  // ---------------------------------------------------------------- 特权级判定
  // CSR 地址的 [9:8] 位给出最低可访问特权级：00=U 01=S 11=M
  wire [1:0] csr_priv = csr_raddr[9:8];
  wire       csr_ro   = (csr_raddr[11:10] == 2'b11);   // 只读 CSR

  // ---------------------------------------------------------------- 读端口
  always @(*) begin
    csr_rdata = 32'd0;
    case (csr_raddr)
      // ---- 浮点（基线阶段：只读 0 / 可写 fcsr 影子）----
      `CSR_FFLAGS:  csr_rdata = 32'd0;
      `CSR_FRM:     csr_rdata = 32'd0;
      `CSR_FCSR:    csr_rdata = 32'd0;

      // ---- 机器级 ----
      // mstatus（RV32）位图：31=SD 22=TSR 21=TW 20=TVM 19=MXR 18=SUM 17=MPRV
      //                    16:15=XS 14:13=FS 12:11=MPP 10:9=VS 8=SPP 7=MPIE
      //                    6=UBE 5=SPIE 3=MIE 1=SIE
      `CSR_MSTATUS: csr_rdata = {1'b0,               // 31 SD（FS=0 → SD=0）
                                 8'd0,               // 30:23
                                 mstatus_tsr_q[0],   // 22 TSR
                                 mstatus_tw_q[0],    // 21 TW
                                 mstatus_tvm_q[0],   // 20 TVM
                                 mstatus_mxr_q[0],   // 19 MXR
                                 mstatus_sum_q[0],   // 18 SUM
                                 mstatus_mprv_q[0],  // 17 MPRV
                                 2'b00,              // 16:15 XS
                                 mstatus_fs_q,       // 14:13 FS
                                 mstatus_mpp_q,      // 12:11 MPP
                                 2'b00,              // 10:9  VS
                                 mstatus_spp_q[0],   // 8 SPP
                                 mstatus_mpie_q[0],  // 7 MPIE
                                 1'b0,               // 6 UBE
                                 mstatus_spie_q[0],  // 5 SPIE
                                 1'b0,               // 4
                                 mstatus_mie_q[0],   // 3 MIE
                                 1'b0,               // 2
                                 mstatus_sie_q[0],   // 1 SIE
                                 1'b0};              // 0
      `CSR_MSTATUSH: csr_rdata = 32'd0;
      `CSR_MISA:    csr_rdata = 32'h8014_112D;  // MXL=1(bit31), A(0) C(2) D(3) F(5) I(8) M(12) S(18) U(20)
      `CSR_MEDELEG: csr_rdata = medeleg_q;
      `CSR_MIDELEG: csr_rdata = mideleg_q;
      `CSR_MIE:     csr_rdata = mie_q;
      `CSR_MTVEC:   csr_rdata = mtvec_q;
      `CSR_MCOUNTEREN: csr_rdata = mcounteren_q;
      `CSR_MSCRATCH:csr_rdata = mscratch_q;
      `CSR_MEPC:    csr_rdata = mepc_q;
      `CSR_MCAUSE:  csr_rdata = mcause_q;
      `CSR_MTVAL:   csr_rdata = mtval_q;
      `CSR_MIP:     csr_rdata = mip_q;
      `CSR_MCYCLE:  csr_rdata = mcycle_q[31:0];
      `CSR_MCYCLEH: csr_rdata = mcycle_q[63:32];
      `CSR_MINSTRET:csr_rdata = minstret_q[31:0];
      `CSR_MINSTRETH:csr_rdata= minstret_q[63:32];
      `CSR_MVENDORID: csr_rdata = 32'd0;
      `CSR_MARCHID: csr_rdata = 32'h5256_3332;   // "RV32"
      `CSR_MIMPID:  csr_rdata = 32'h0000_2A01;   // 阶段 2A 版本
      `CSR_MHARTID: csr_rdata = 32'd0;
      `CSR_MCONFIGPTR: csr_rdata = 32'd0;
      `CSR_MENVCFG: csr_rdata = menvcfg_q;

      // ---- 监管级 ----
      // sstatus 是 mstatus 的受限视图（19=MXR 18=SUM 16:15=XS 14:13=FS 8=SPP 5=SPIE 1=SIE）
      `CSR_SSTATUS: csr_rdata = {1'b0,               // 31 SD
                                 11'd0,              // 30:20
                                 mstatus_mxr_q[0],   // 19 MXR
                                 mstatus_sum_q[0],   // 18 SUM
                                 3'd0,               // 17:15
                                 mstatus_fs_q,       // 14:13 FS
                                 4'd0,               // 12:9
                                 mstatus_spp_q[0],   // 8 SPP
                                 2'd0,               // 7:6
                                 mstatus_spie_q[0],  // 5 SPIE
                                 3'd0,               // 4:2
                                 mstatus_sie_q[0],   // 1 SIE
                                 1'b0};              // 0
      `CSR_SIE:     csr_rdata = sie_q & mideleg_q;
      `CSR_STVEC:   csr_rdata = stvec_q;
      `CSR_SCOUNTEREN: csr_rdata = scounteren_q;
      `CSR_SSCRATCH:csr_rdata = sscratch_q;
      `CSR_SEPC:    csr_rdata = sepc_q;
      `CSR_SCAUSE:  csr_rdata = scause_q;
      `CSR_STVAL:   csr_rdata = stval_q;
      `CSR_SIP:     csr_rdata = sip_q & mideleg_q;
      `CSR_SATP:    csr_rdata = satp_q;
      `CSR_SENVCFG: csr_rdata = senvcfg_q;

      // ---- 计数器 ----
      `CSR_CYCLE:   csr_rdata = mcycle_q[31:0];
      `CSR_CYCLEH:  csr_rdata = mcycle_q[63:32];
      `CSR_TIME:    csr_rdata = mcycle_q[31:0];   // 基线：以 mcycle 代替 mtime
      `CSR_TIMEH:   csr_rdata = mcycle_q[63:32];
      `CSR_INSTRET: csr_rdata = minstret_q[31:0];
      `CSR_INSTRETH:csr_rdata = minstret_q[63:32];

      default:      csr_rdata = 32'd0;
    endcase
    // WB→ID 旁路：前一条指令在同拍提交级写同一 CSR 时，读端口返回新值
    // （与寄存器堆的写优先问题同类：写发生在 posedge，而 ID 为组合读）
    if (csr_wen && !csr_is_fp && (csr_waddr == csr_raddr))
      csr_rdata = csr_wdata;
  end

  // 合法性：地址存在 + 特权级足够 + 读不涉及只写
  reg csr_exists;
  always @(*) begin
    case (csr_raddr)
      `CSR_FFLAGS, `CSR_FRM, `CSR_FCSR,
      `CSR_MSTATUS, `CSR_MSTATUSH, `CSR_MISA, `CSR_MEDELEG, `CSR_MIDELEG, `CSR_MIE,
      `CSR_MTVEC, `CSR_MCOUNTEREN, `CSR_MSCRATCH, `CSR_MEPC, `CSR_MCAUSE, `CSR_MTVAL,
      `CSR_MIP, `CSR_MCYCLE, `CSR_MCYCLEH, `CSR_MINSTRET, `CSR_MINSTRETH,
      `CSR_MVENDORID, `CSR_MARCHID, `CSR_MIMPID, `CSR_MHARTID, `CSR_MCONFIGPTR,
      `CSR_SSTATUS, `CSR_SIE, `CSR_STVEC, `CSR_SCOUNTEREN, `CSR_SSCRATCH, `CSR_SEPC,
      `CSR_SCAUSE, `CSR_STVAL, `CSR_SIP, `CSR_SATP,
      `CSR_MENVCFG, `CSR_SENVCFG,
      `CSR_CYCLE, `CSR_CYCLEH, `CSR_TIME, `CSR_TIMEH, `CSR_INSTRET, `CSR_INSTRETH:
        csr_exists = 1'b1;
      default: csr_exists = 1'b0;
    endcase
  end

  // 特权级检查：机器级 CSR 只能 M 访问；监管级 CSR 需 S 或 M
  wire priv_ok = (csr_priv == 2'b00) ? 1'b1 :
                 (csr_priv == 2'b01) ? (priv != `PRV_U) :
                                       (priv == `PRV_M);

  // 计数器读权限：U 模式需 mcounteren/scounteren
  wire is_counter = (csr_raddr == `CSR_CYCLE) || (csr_raddr == `CSR_CYCLEH) ||
                    (csr_raddr == `CSR_TIME)  || (csr_raddr == `CSR_TIMEH) ||
                    (csr_raddr == `CSR_INSTRET)||(csr_raddr == `CSR_INSTRETH);
  // 计数器编号：0=cycle 1=time 2=instret
  wire [4:0] counter_idx = (csr_raddr == `CSR_CYCLE || csr_raddr == `CSR_CYCLEH) ? 5'd0 :
                           (csr_raddr == `CSR_TIME  || csr_raddr == `CSR_TIMEH ) ? 5'd1 : 5'd2;
  wire counter_ok = (priv == `PRV_M) || !is_counter ||
                    ((priv == `PRV_S) && mcounteren_q[counter_idx]) ||
                    ((priv == `PRV_U) && mcounteren_q[counter_idx] && scounteren_q[counter_idx]);

  always @(*) begin
    csr_legal = csr_exists && priv_ok && counter_ok;
  end

  // ---------------------------------------------------------------- 陷阱委托与向量
  wire [1:0]  cause_priv  = trap_is_int ? (mideleg_q[trap_cause] ? `PRV_S : `PRV_M)
                                        : (medeleg_q[trap_cause] ? `PRV_S : `PRV_M);
  wire [31:0] vec_base   = (cause_priv == `PRV_S) ? stvec_q : mtvec_q;
  assign trap_new_priv   = cause_priv;
  // MODE=0 直接模式；MODE=1 向量模式（中断时 base + 4*cause）
  assign trap_vector     = (vec_base[1:0] == 2'b01 && trap_is_int)
                           ? {vec_base[31:2], 2'b00} + {24'd0, trap_cause, 2'b00}
                           : {vec_base[31:2], 2'b00};

  assign xret_pc         = xret_is_sret ? sepc_q : mepc_q;
  assign xret_new_priv   = xret_is_sret ? {1'b0, mstatus_spp_q[0]} : mstatus_mpp_q;

  // ---------------------------------------------------------------- 写端口 + 计数器 + 陷阱
  integer i;
  always @(posedge clk) begin
    if (!rst_n) begin
      priv_q          <= `PRV_M;
      mstatus_mie_q   <= 3'd0;
      mstatus_mpie_q  <= 3'd0;
      mstatus_mpp_q   <= `PRV_U;
      mstatus_sie_q   <= 1'b0;
      mstatus_spie_q  <= 1'b0;
      mstatus_spp_q   <= 1'b0;
      mstatus_mprv_q  <= 1'b0;
      mstatus_sum_q   <= 1'b0;
      mstatus_mxr_q   <= 1'b0;
      mstatus_tw_q    <= 1'b0;
      mstatus_tsr_q   <= 1'b0;
      mstatus_tvm_q   <= 1'b0;
      mstatus_fs_q    <= 2'd0;
      mtvec_q         <= 32'd0;
      mscratch_q      <= 32'd0;
      mepc_q          <= 32'd0;
      mcause_q        <= 32'd0;
      mtval_q         <= 32'd0;
      medeleg_q       <= 32'd0;
      mideleg_q       <= 32'd0;
      mie_q           <= 32'd0;
      mip_q           <= 32'd0;
      mcounteren_q    <= 32'd0;
      stvec_q         <= 32'd0;
      sscratch_q      <= 32'd0;
      sepc_q          <= 32'd0;
      scause_q        <= 32'd0;
      stval_q         <= 32'd0;
      sie_q           <= 32'd0;
      sip_q           <= 32'd0;
      scounteren_q    <= 32'd0;
      menvcfg_q       <= 32'd0;
      senvcfg_q       <= 32'd0;
      satp_q          <= 32'd0;
      mcycle_q        <= 64'd0;
      minstret_q      <= 64'd0;
    end else begin
      // 计数器
      mcycle_q <= mcycle_q + 64'd1;
      if (instret_en) minstret_q <= minstret_q + 64'd1;

      // 陷阱进入（优先级高于 CSR 写；trap 与写不会同拍）
      if (trap_valid) begin
        if (cause_priv == `PRV_S) begin
          sepc_q        <= trap_epc;
          scause_q      <= {trap_is_int, 27'd0, trap_cause};
          stval_q       <= trap_tval;
          mstatus_spie_q<= mstatus_sie_q;
          mstatus_sie_q <= 1'b0;
          mstatus_spp_q <= (priv_q == `PRV_S) ? 1'b1 : 1'b0;
        end else begin
          mepc_q        <= trap_epc;
          mcause_q      <= {trap_is_int, 27'd0, trap_cause};
          mtval_q       <= trap_tval;
          mstatus_mpie_q<= mstatus_mie_q;
          mstatus_mie_q <= 1'b0;
          mstatus_mpp_q <= priv_q;
        end
        priv_q        <= cause_priv;
        mstatus_mprv_q<= 1'b0;
      end
      // 陷阱返回
      else if (xret_valid) begin
        if (xret_is_sret) begin
          mstatus_sie_q <= mstatus_spie_q;
          mstatus_spie_q<= 1'b1;
          mstatus_spp_q <= 1'b0;
          priv_q        <= {1'b0, mstatus_spp_q[0]};
        end else begin
          mstatus_mie_q <= mstatus_mpie_q;
          mstatus_mpie_q<= 1'b1;
          mstatus_mpp_q <= `PRV_U;
          priv_q        <= mstatus_mpp_q;
        end
        // MPRV 仅在返回目标 != M 时清零（规范要求）
        if ((xret_is_sret ? {1'b0, mstatus_spp_q[0]} : mstatus_mpp_q) != `PRV_M)
          mstatus_mprv_q <= 1'b0;
      end
      // CSR 写（提交级）
      else if (csr_wen && !csr_is_fp) begin
        case (csr_waddr)
          `CSR_MSTATUS: begin
            mstatus_mie_q  <= {2'b0, csr_wdata[3]};
            mstatus_mpie_q <= {2'b0, csr_wdata[7]};
            mstatus_mpp_q  <= (csr_wdata[12:11] == 2'b10) ? `PRV_M : csr_wdata[12:11];
            mstatus_sie_q  <= {1'b0, csr_wdata[1]};
            mstatus_spie_q <= {1'b0, csr_wdata[5]};
            mstatus_spp_q  <= {1'b0, csr_wdata[8]};
            mstatus_mprv_q <= {1'b0, csr_wdata[17]};
            mstatus_sum_q  <= {1'b0, csr_wdata[18]};
            mstatus_mxr_q  <= {1'b0, csr_wdata[19]};
            mstatus_tvm_q  <= {1'b0, csr_wdata[20]};
            mstatus_tw_q   <= {1'b0, csr_wdata[21]};
            mstatus_tsr_q  <= {1'b0, csr_wdata[22]};
            mstatus_fs_q   <= csr_wdata[14:13];
          end
          `CSR_MEDELEG: medeleg_q <= csr_wdata & MEDELEG_MASK;
          `CSR_MIDELEG: mideleg_q <= csr_wdata & MIDELEG_MASK;
          `CSR_MIE:     mie_q     <= csr_wdata & (MEDELEG_MASK | MIDELEG_MASK | 32'h0000_0888);
          `CSR_MTVEC:   mtvec_q   <= {csr_wdata[31:2], 2'b00} | {30'd0, csr_wdata[1:0]};
          `CSR_MCOUNTEREN: mcounteren_q <= csr_wdata & 32'h7;
          `CSR_MSCRATCH:mscratch_q<= csr_wdata;
          `CSR_MEPC:    mepc_q    <= {csr_wdata[31:1], 1'b0};
          `CSR_MCAUSE:  mcause_q  <= csr_wdata;
          `CSR_MTVAL:   mtval_q   <= csr_wdata;
          `CSR_MIP:     mip_q     <= csr_wdata & 32'h0000_0888;
          `CSR_MCYCLE:  mcycle_q[31:0]  <= csr_wdata;
          `CSR_MCYCLEH: mcycle_q[63:32] <= csr_wdata;
          `CSR_MINSTRET: minstret_q[31:0]  <= csr_wdata;
          `CSR_MINSTRETH:minstret_q[63:32] <= csr_wdata;

          `CSR_SSTATUS: begin
            mstatus_sie_q  <= {1'b0, csr_wdata[1]};
            mstatus_spie_q <= {1'b0, csr_wdata[5]};
            mstatus_spp_q  <= {1'b0, csr_wdata[8]};
            mstatus_sum_q  <= {1'b0, csr_wdata[18]};
            mstatus_mxr_q  <= {1'b0, csr_wdata[19]};
            mstatus_fs_q   <= csr_wdata[14:13];
          end
          `CSR_SIE:     sie_q     <= csr_wdata & mideleg_q;
          `CSR_STVEC:   stvec_q   <= {csr_wdata[31:2], 2'b00};
          `CSR_SCOUNTEREN: scounteren_q <= csr_wdata & 32'h7;
          `CSR_SSCRATCH:sscratch_q<= csr_wdata;
          `CSR_SEPC:    sepc_q    <= {csr_wdata[31:1], 1'b0};
          `CSR_SCAUSE:  scause_q  <= csr_wdata;
          `CSR_STVAL:   stval_q   <= csr_wdata;
          `CSR_SIP:     sip_q     <= csr_wdata & 32'h0000_0222;
          `CSR_SATP:    satp_q    <= csr_wdata;   // 阶段 2A 暂不生效（MMU 后续里程碑）
          // menvcfg/senvcfg：只保留 CBO 相关位（CBIE[5:4] 的 0b10 保留编码按 WARL 归 0）
          `CSR_MENVCFG: begin
            menvcfg_q[7]   <= csr_wdata[7];
            menvcfg_q[6]   <= csr_wdata[6];
            menvcfg_q[5:4] <= (csr_wdata[5:4] == 2'b10) ? 2'b00 : csr_wdata[5:4];
          end
          `CSR_SENVCFG: begin
            senvcfg_q[7]   <= csr_wdata[7];
            senvcfg_q[6]   <= csr_wdata[6];
            senvcfg_q[5:4] <= (csr_wdata[5:4] == 2'b10) ? 2'b00 : csr_wdata[5:4];
          end
          default: ;
        endcase
      end
    end
  end

endmodule
