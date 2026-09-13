//======================================================================
// rv32mmu_top.v —— Sv32 地址翻译顶层（ITLB 8 + DTLB 16 + 单个 rv32_ptw）
//----------------------------------------------------------------------
// 职责边界（③ 里程碑计划，见 AGENT.md §7）：
//   · 本模块只做"翻译"：VA → PA + 页错误；**不改写 PTE**（Svade：A/D=0 ⇒ 页错误），
//     不做 Svadu/Svnapot/Svpbmt/Svinval。
//   · 权限（U/SUM/MXR/R/W/X）与 A/D 在**每次访问时 live 判定**，绝不缓存结论：TLB 只存
//     叶子 PTE 的 `perm[7:0]` 原值，于是 `mstatus.SUM/MXR`、特权级变化后无需失效 TLB。
//   · 页表读由本模块**自驱** `ptw_bus_req/addr`（核内把它接到数据总线通道），**绝不经过
//     LSU 的 M_REQ 状态机、也不受 advance_all/fetch_stall/mem_stall 门控**（否则死锁）。
//   · 两个翻译口互相独立、由 PTW 仲裁串行：**D 优先**（数据访问在流水线里更靠后、更急）。
//
// 与 Spike 的逐条对照（参考签名由 Spike 生成，故以它为准）：
//   · 页表基址/索引：tools/spike/riscv/mmu.cc:732,787 `pte_paddr = base + idx*ptesize`，
//     `base = ppn << PGSHIFT`（PGSHIFT=12、ptesize=4）——在 rv32_ptw.v 内实现。
//   · U/SUM：mmu.cc:755 `(pte & PTE_U) ? s_mode && (type == FETCH || !sum) : !s_mode`
//     ⇒ **S 模式取指 U 页必页错误**（SUM 只管 load/store）；U 模式访问 U=0 页必页错误。
//   · R/W/X：mmu.cc:778-780  FETCH 要 X；LOAD 要 R 或（MXR 且 X）；STORE 要 W。
//   · A/D（Svade，`hade=0`）：mmu.cc:781-790 `ad = PTE_A | (type==STORE)*PTE_D`，
//     `(pte & ad) != ad` ⇒ 页错误且**不写回**；A 对取指同样要求。
//   · 页错误 cause：取指 12、load 13、store/AMO/SC 15（由调用方按访问类型取）。
//
// TLB 项：{VALID,G,IS_4M,ASID,VPN_TAG[19:0],PPN[21:0],PERM[7:0]}；
//   命中比较 rv32_tlb.v：IS_4M 时只比 `va[31:22]`（超级页内 `va[21:12]` 可变）。
//   PA 拼装（本设计 PA=32 位、只用 PPN[19:0]，PPN[21:20] 丢弃见 07 文档 §2.3）：
//     4K ：{ppn[19:0], va[11:0]}
//     4M ：{ppn[19:10], va[21:12], va[11:0]}
//======================================================================
`include "rv32gc_defs.vh"

module rv32mmu_top #(
  parameter integer ITLB_ENTRIES = 8,
  parameter integer DTLB_ENTRIES = 16
) (
  input  wire        clk,
  input  wire        rst_n,
  //------------------------------------------------ 模式与 CSR 状态
  input  wire        satp_mode,       // satp[31]：1 = Sv32 生效
  input  wire [21:0] satp_ppn,        // satp[21:0]
  input  wire [8:0]  satp_asid,       // satp[30:22]
  input  wire [1:0]  priv,            // 取指侧特权级（= 当前特权级）
  input  wire [1:0]  d_eff_priv,      // 数据侧有效特权级（MPRV/MPP 已并入）
  input  wire        sum,             // mstatus.SUM（仅数据侧）
  input  wire        mxr,             // mstatus.MXR（仅数据侧）
  input  wire        flush,           // sfence.vma：全清 TLB + 丢弃在途遍历
  //------------------------------------------------ 取指翻译口（组合）
  input  wire [31:0] if_va,
  output wire        if_pa_valid,     // 1 = if_pa 可用（无需翻译 / 命中且权限+AD 通过）
  output wire [31:0] if_pa,
  output wire        if_fault,        // 取指页错误（cause 12）
  output wire        if_fault_is_access,  // 上者的分类：1 = 访问错误（cause 1）：页表读
                                          // 被 PMP 拒绝或总线错误，见 rv32_ptw.v
  //------------------------------------------------ 访存翻译口（组合 + 请求）
  input  wire [31:0] d_va,
  input  wire        d_is_store,      // AMO/SC/CBO.ZERO 亦为 1
  input  wire        d_req,           // 本拍有访存需要翻译（核内：M_IDLE && mem_needs_fsm）
  output wire        d_pa_valid,
  output wire [31:0] d_pa,
  output wire        d_fault,
  output wire [3:0]  d_fault_cause,   // 13 = load 页错误，15 = store/AMO/CBO 页错误
  output wire        d_fault_is_access,   // 1 = 该故障其实是访问错误（页表读 PMP 拒绝/总线
                                          // 错误）⇒ 核内改用 cause 5/7（见 tools/spike/riscv/
                                          // mmu.h:486-497 的 throw_access_exception）
  //------------------------------------------------ 页表读（4 字节）
  output wire        ptw_bus_req,
  output wire [31:0] ptw_bus_addr,
  input  wire [31:0] ptw_bus_rdata,
  input  wire        ptw_bus_ack,
  input  wire        ptw_bus_err,
  input  wire        ptw_bus_deny     // 核内共享 PMP 引擎对本次页表读的结论（1 = 拒绝）
);

  localparam [1:0] PRV_U_ = `PRV_U;
  localparam [1:0] PRV_S_ = `PRV_S;
  localparam [1:0] PRV_M_ = `PRV_M;

  // PTW 互连（显式声明：TLB 例化在前、PTW 例化在后，若靠隐式网络会变成 1 位！）
  wire        ptw_req;         // 由下方 assign 驱动（上升沿启动）
  wire [31:0] ptw_va;
  wire        ptw_busy, ptw_done, ptw_fault, ptw_is_4m;
  wire        ptw_fault_is_access;
  wire [21:0] ptw_ppn;
  wire [7:0]  ptw_perm;
  wire [31:0] ptw_fault_va;

  //================================================== TLB 例化
  wire        i_hit, i_is_4m;
  wire [21:0] i_ppn;
  wire [7:0]  i_perm;
  wire        d_hit, d_is_4m;
  wire [21:0] d_ppn;
  wire [7:0]  d_perm;

  wire        i_fill = i_walk_done;
  wire        d_fill = d_walk_done;

  rv32_tlb #(.ENTRIES(ITLB_ENTRIES)) u_itlb (
    .clk(clk), .rst_n(rst_n),
    .va(if_va), .satp_asid(satp_asid),
    .hit(i_hit), .ppn(i_ppn), .is_4m(i_is_4m), .perm(i_perm),
    .fill_en(i_fill), .fill_va(i_va_q), .fill_asid(satp_asid),
    .fill_g(ptw_perm[5]), .fill_is_4m(ptw_is_4m), .fill_ppn(ptw_ppn), .fill_perm(ptw_perm),
    .flush_all(flush)
  );

  rv32_tlb #(.ENTRIES(DTLB_ENTRIES)) u_dtlb (
    .clk(clk), .rst_n(rst_n),
    .va(d_va), .satp_asid(satp_asid),
    .hit(d_hit), .ppn(d_ppn), .is_4m(d_is_4m), .perm(d_perm),
    .fill_en(d_fill), .fill_va(d_va_q), .fill_asid(satp_asid),
    .fill_g(ptw_perm[5]), .fill_is_4m(ptw_is_4m), .fill_ppn(ptw_ppn), .fill_perm(ptw_perm),
    .flush_all(flush)
  );

  //================================================== PTW 例化 + 仲裁
  rv32_ptw u_ptw (
    .clk(clk), .rst_n(rst_n),
    .req(ptw_req), .va(ptw_va), .satp_ppn(satp_ppn),
    .bus_req(ptw_bus_req), .bus_addr(ptw_bus_addr),
    .bus_rdata(ptw_bus_rdata), .bus_ack(ptw_bus_ack), .bus_err(ptw_bus_err),
    .bus_deny(ptw_bus_deny),
    .busy(ptw_busy), .done(ptw_done), .fault(ptw_fault), .fault_is_access(ptw_fault_is_access),
    .ppn(ptw_ppn), .is_4m(ptw_is_4m), .perm(ptw_perm), .fault_va(ptw_fault_va),
    .abort(flush)
  );

  // ---- 翻译是否启用（Spike：satp.MODE=1 且有效特权级 < M 才翻译）----
  wire i_trans_en = satp_mode && (priv       != PRV_M_);
  wire d_trans_en = satp_mode && (d_eff_priv != PRV_M_);

  // ---- 需要遍历的条件（D 侧由核内 d_req 限定"确实有访存"，避免陈旧地址空走）----
  wire i_need_walk = i_trans_en && !i_hit && !i_fault_sticky;
  wire d_need_walk = d_req && d_trans_en && !d_hit && !d_fault_sticky;

  // ---- 启动/仲裁：D 优先；只在 PTW 空闲时起新遍历（保证 req 是干净上升沿）----
  wire d_start = d_need_walk && !ptw_busy;
  wire i_start = i_need_walk && !ptw_busy && !d_need_walk;
  assign ptw_req = d_start | i_start;
  assign ptw_va  = d_start ? d_va : if_va;
  // 归属：本拍起遍历的是谁（ptw_busy=1 期间由 ptw_owner_q 保持）
  reg  ptw_owner_q;      // 1 = 取指侧，0 = 数据侧

  // ---- I 侧 FSM：等遍历结果（其余判定都是组合的）----
  reg i_wait_q;
  reg [31:0] i_va_q;     // 本次遍历的 VA（供 TLB fill 用）
  reg        i_fault_q;  // 结构性页错误已判定（粘住到 VA 变化/flush）
  reg [31:0] i_fault_va_q;
  reg        i_fault_acc_q;   // 粘性故障的分类：1 = 访问错误（页表读 PMP/总线）

  // ⚠ 归属判定：ptw_owner_q=1 ⇒ 取指侧（见下方 ptw_owner_q <= i_start）
  wire i_walk_done  = i_wait_q && ptw_owner_q && ptw_done;
  wire i_walk_fault = i_wait_q && ptw_owner_q && ptw_fault;
  wire i_fault_sticky = i_fault_q && (i_fault_va_q == if_va);
  assign if_fault    = i_trans_en && ((i_hit && !i_perm_ok) || i_walk_fault || i_fault_sticky);
  // 访问错误只可能来自页表读（PMP 拒绝 / 总线错误）；权限/A-D 失败是页错误
  assign if_fault_is_access = i_trans_en && !(i_hit && !i_perm_ok) &&
                              ((i_walk_fault && ptw_fault_is_access) ||
                               (i_fault_sticky && i_fault_acc_q));
  assign if_pa_valid = !i_trans_en || ((i_hit || i_walk_done) && i_perm_ok);
  assign if_pa       = !i_trans_en ? if_va :
                       make_pa(i_hit ? i_ppn : ptw_ppn, i_hit ? i_is_4m : ptw_is_4m, if_va);

  // ---- D 侧 FSM ----
  reg d_wait_q;
  reg [31:0] d_va_q;
  reg        d_fault_q;
  reg [31:0] d_fault_va_q;
  reg        d_fault_acc_q;

  wire d_walk_done  = d_wait_q && ptw_owner_q == 1'b0 && ptw_done;
  wire d_walk_fault = d_wait_q && ptw_owner_q == 1'b0 && ptw_fault;
  wire d_fault_sticky = d_fault_q && (d_fault_va_q == d_va);
  assign d_fault     = d_trans_en && ((d_hit && !d_perm_ok) || d_walk_fault || d_fault_sticky);
  assign d_fault_cause = d_is_store ? (`EXC_STORE_PAGE_FAULT) : (`EXC_LOAD_PAGE_FAULT);
  assign d_fault_is_access = d_trans_en && !(d_hit && !d_perm_ok) &&
                             ((d_walk_fault && ptw_fault_is_access) ||
                              (d_fault_sticky && d_fault_acc_q));
  assign d_pa_valid  = !d_trans_en || ((d_hit || d_walk_done) && d_perm_ok);
  assign d_pa        = !d_trans_en ? d_va :
                       make_pa(d_hit ? d_ppn : ptw_ppn, d_hit ? d_is_4m : ptw_is_4m, d_va);

  //================================================== 权限 + A/D（live）
  // 取指：X 必需；U 页在 S 模式取指必页错误（SUM 不适用于取指）；A 必需（无 D 要求）
  wire [7:0] i_p = i_hit ? i_perm : ptw_perm;
  wire i_perm_u_fail = (i_p[4] && (priv == PRV_S_)) || (!i_p[4] && (priv == PRV_U_));
  wire i_perm_rwx_ok = i_p[3];
  wire i_perm_ad_ok  = i_p[6];
  wire i_perm_ok     = !i_perm_u_fail && i_perm_rwx_ok && i_perm_ad_ok;

  // 数据：STORE 要 W；LOAD 要 R 或（MXR 且 X）；U 页在 S 模式且 SUM=0 必页错误；
  //       A 必需，STORE 还要求 D（Svade ⇒ 不通过即页错误，绝不写回 PTE）
  wire [7:0] d_p = d_hit ? d_perm : ptw_perm;
  wire d_perm_u_fail = d_p[4] ? ((d_eff_priv == PRV_S_) && !sum) : (d_eff_priv == PRV_U_);
  wire d_perm_rwx_ok = d_is_store ? d_p[2] : (d_p[1] || (mxr && d_p[3]));
  wire d_perm_ad_ok  = d_p[6] && (d_is_store ? d_p[7] : 1'b1);
  wire d_perm_ok     = !d_perm_u_fail && d_perm_rwx_ok && d_perm_ad_ok;

  //================================================== PA 拼装
  function [31:0] make_pa;
    input [21:0] ppn;
    input        is_4m;
    input [31:0] va;
    begin
      make_pa = is_4m ? {ppn[19:10], va[21:12], va[11:0]}
                      : {ppn[19:0],  va[11:0]};
    end
  endfunction

  //================================================== 时序（FSM + 副作用）

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i_wait_q      <= 1'b0;
      d_wait_q      <= 1'b0;
      i_fault_q     <= 1'b0;
      d_fault_q     <= 1'b0;
      i_fault_va_q  <= 32'd0;
      d_fault_va_q  <= 32'd0;
      i_va_q        <= 32'd0;
      d_va_q        <= 32'd0;
      i_fault_acc_q <= 1'b0;
      d_fault_acc_q <= 1'b0;
      ptw_owner_q   <= 1'b0;
    end else if (flush) begin
      // sfence.vma：TLB 已被 flush_all 清空；这里复位两个 FSM 并丢弃在途结果与粘性页错误
      i_wait_q      <= 1'b0;
      d_wait_q      <= 1'b0;
      i_fault_q     <= 1'b0;
      d_fault_q     <= 1'b0;
      ptw_owner_q   <= 1'b0;
    end else begin
      // ---- 起遍历：锁存归属与 VA ----
      if (ptw_req) begin
        ptw_owner_q <= i_start;      // i_start=1 ⇒ 取指；否则数据
        if (i_start) begin
          i_wait_q <= 1'b1;
          i_va_q   <= if_va;
        end else begin
          d_wait_q <= 1'b1;
          d_va_q   <= d_va;
        end
      end
      // ---- 遍历结束：回 IDLE；结构性页错误粘到 VA 变化/flush ----
      if (i_walk_done || i_walk_fault) i_wait_q <= 1'b0;
      if (d_walk_done || d_walk_fault) d_wait_q <= 1'b0;
      if (i_walk_fault) begin
        i_fault_q     <= 1'b1;
        i_fault_va_q  <= i_va_q;
        i_fault_acc_q <= ptw_fault_is_access;
      end
      if (d_walk_fault) begin
        d_fault_q     <= 1'b1;
        d_fault_va_q  <= d_va_q;
        d_fault_acc_q <= ptw_fault_is_access;
      end
      // 粘性页错误只对"同一个 VA"有效；VA 变化即自动失效（无需外部清除）
      if (i_fault_q && (i_fault_va_q != if_va)) i_fault_q <= 1'b0;
      if (d_fault_q && (d_fault_va_q != d_va)) d_fault_q <= 1'b0;
      // 若等待中的那一侧输入的 VA 变了（理论上核内会冻结，这里仍兜底重启遍历）
      if (i_wait_q && (i_va_q != if_va)) i_wait_q <= 1'b0;
      if (d_wait_q && (d_va_q != d_va)) d_wait_q <= 1'b0;
    end
  end

endmodule
