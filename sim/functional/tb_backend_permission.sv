//==============================================================================
// tb_backend_permission.sv —— F4-1 后端程序序 CSR/特权权限检查定向 TB
//------------------------------------------------------------------------------
// 目标（本包新增；不改旧 18 向量包黄金）：
//   A) CSR 权限/存在/只读写/counteren/TVM 的**动态**检查必须发生在该项成为 ROB 头
//      （全部更老指令已提交）之后：非法项在提交点 cause 2，tval = 原始指令位，
//      无 CSR 写 / 无 PRF 写 / 无 xRET/maintenance 副作用；更老前缀正常提交，
//      非法项及其年轻后缀不得提交。
//   B) SRET：U 非法（D1 静态，旧包已覆盖）；S 且 mstatus.TSR=1 非法；M 恒合法；
//      SFENCE.VMA：U 非法（D1 静态）；S 且 mstatus.TVM=1 非法；M 恒合法。
//   C) 写只读 CSR：CSRRS/RC 的 rs1=x0 是“无写” ⇒ 合法；rs1≠x0（即使值为 0）是真写
//      ⇒ 非法。`csr_chk_wr_o` 只看编码域，与源值无关。
//   D) 原始候选查询 `csr_chk_valid/addr/wr` 由 ROB **头部安全载荷 + E1 指令 PC 校验**
//      产生，不依赖最终 csr_we/提交允许（无组合环）。
//
// DUT 接法：
//   · 真实 `backend_top` + 真实 `csr_file`（chk_addr ← csr_chk_addr_o；chk_illegal/
//     chk_ro_write 回灌；tsr/tvm 取 mstatus_o 对应位；csr 写口由 DUT 的 csr_we_o 驱动）。
//   · `priv` 由 TB 驱动（本 TB 不实现 priv_ctrl；xret 的特权切换不在本层断言范围）。
//   · setup 阶段用 csr_file 的 wen 口**直接预置** mstatus.TVM/TSR、mcounteren（状态预置，
//     不是被检查动作），随后释放 DUT 程序；检查动作全部经真实派发/执行/提交链。
//
// 旧树反证：编译旧 201 快照时**不定义** `BACKEND_HAS_CSR_CHK`（纯接口宏），同一 TB
//   对同一程序给出“旧缺陷签名”（非法 CSR 照常提交、无 cause 2、TSR/TVM 不拦），
//   脚本要求触发例 DEFECT_SIG、控制例 OK。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module tb_backend_permission ();

    localparam integer NINS = 128;   // 22 例 ROB 环绕流；其余案例只用 0..3
    localparam [31:0]  BASE = 32'h8000_0000;

    //--------------------------------------------------------------------------
    // 时钟/复位
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // DUT 输入
    //--------------------------------------------------------------------------
    reg         blk_valid;
    reg  [3:0]  blk_mask;
    reg  [31:0] blk_next_pc;
    reg         blk_taken;
    reg  [127:0] lane_pc, lane_pa, lane_insn;
    reg  [3:0]  lane_len32;
    reg  [11:0] lane_cls;
    reg  [3:0]  lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    reg  [127:0] lane_pred_target;
    reg  [3:0]  lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    reg  [127:0] lane_btb_target;
    reg  [3:0]  lane_fault;
    reg  [19:0] lane_fault_cause;
    reg  [127:0] lane_fault_tval;
    reg  [15:0] lane_ckpt;
    reg  [3:0]  lane_ckpt_valid;
    reg         fe_fetch_fault;
    reg         train_ready;
    reg         mem_req_ready, mem_rsp_err;
    reg         st_xlate_en, st_xlate_ready, st_xlate_done, st_xlate_fault;
    reg  [3:0]  st_xlate_ctx;
    reg  [31:0] st_xlate_pa;
    reg         trp_flush_v, trp_redirect_v;
    reg  [31:0] trp_redirect_pc;
    wire [31:0] csr_rdata;
    reg  [2:0]  csr_frm;
    reg  [4:0]  csr_fflags;
    reg  [1:0]  priv;
    reg         maint_rdy;
    reg  [1:0]  cbo_perm;

    //--------------------------------------------------------------------------
    // DUT 输出
    //--------------------------------------------------------------------------
    wire        blk_ready_o;
    wire        ras_cmt_push_valid_o, ras_cmt_pop_valid_o;
    wire        ckpt_free_valid_o;
    wire [3:0]  ckpt_free_id_o;
    wire        d2_push_valid_o, d2_pop_valid_o;
    wire [31:0] d2_push_addr_o, d2_pop_addr_o;
    wire        mem_req_valid_o, mem_req_wen_o;
    wire [31:0] mem_req_addr_o;
    wire        trap_valid_o, csr_we_o, xret_cmt_o, maint_cmt_o;
    wire [3:0]  trap_cause_o;
    wire [31:0] trap_pc_o, trap_tval_o;
    wire [3:0]  commit_valid_o;
    wire [127:0] commit_pc_o;
    wire [19:0] commit_arch_rd_o;
    wire [127:0] commit_arch_rd_wdata_o;
    wire [3:0]  commit_arch_we_o;
    wire        trp_halt_o;
    wire [31:0] csr_waddr_o, csr_wdata_o;
    wire        csr_chk_valid_o, csr_chk_wr_o;
    wire [11:0] csr_chk_addr_o;
    wire [11:0] csr_raddr_o;
    wire [31:0] csr_rdata_cf_w;
    wire        csr_chk_illegal_w, csr_chk_ro_wr_w;
    wire [31:0] csr_mstatus_w, csr_satp_w, csr_mcounteren_w, csr_scounteren_w;
    wire [31:0] csr_menvcfg_w, csr_senvcfg_w;
    wire [31:0] csr_mtvec_w, csr_stvec_w, csr_medeleg_w, csr_mideleg_w;
    wire [31:0] csr_mie_w, csr_mip_w, csr_mepc_w, csr_sepc_w;
    wire [127:0] csr_pmp_cfg_w;
    wire [511:0] csr_pmp_addr_w;
    // 真实 CSR 文件接口（声明必须先于 DUT 例化；chk 反馈回灌 backend）
    // 数据从设备（本 TB 不执行 load/store；保持握手确定值）
    reg                    rsp_v;
    reg  [31:0]            rsp_data;
    reg  [`BACK2_MEM_TAG_W-1:0] rsp_tag;

    backend_top u_dut (
        .clk(clk), .rst_n(rst_n),
        .blk_valid_i(blk_valid), .blk_ready_o(blk_ready_o), .blk_mask_i(blk_mask),
        .blk_next_pc_i(blk_next_pc), .blk_taken_i(blk_taken),
        .lane_pc_i(lane_pc), .lane_pa_i(lane_pa), .lane_insn_i(lane_insn),
        .lane_len32_i(lane_len32), .lane_cls_i(lane_cls),
        .lane_pred_taken_i(lane_pred_taken), .lane_pred_selg_i(lane_pred_selg),
        .lane_pred_gdir_i(lane_pred_gdir), .lane_pred_ldir_i(lane_pred_ldir),
        .lane_pred_target_i(lane_pred_target),
        .lane_btb_hit_i(lane_btb_hit), .lane_btb_way_i(lane_btb_way),
        .lane_btb_cond_i(lane_btb_cond), .lane_btb_call_i(lane_btb_call),
        .lane_btb_ret_i(lane_btb_ret), .lane_btb_target_i(lane_btb_target),
        .lane_fault_i(lane_fault), .lane_fault_cause_i(lane_fault_cause),
        .lane_fault_tval_i(lane_fault_tval), .lane_ckpt_i(lane_ckpt),
        .lane_ckpt_valid_i(lane_ckpt_valid), .fe_fetch_fault_i(fe_fetch_fault),
        .train_ready_i(train_ready),
        .ras_cmt_push_valid_o(ras_cmt_push_valid_o), .ras_cmt_pop_valid_o(ras_cmt_pop_valid_o),
        .ckpt_free_valid_o(ckpt_free_valid_o), .ckpt_free_id_o(ckpt_free_id_o),
        .d2_push_valid_o(d2_push_valid_o), .d2_push_addr_o(d2_push_addr_o),
        .d2_pop_valid_o(d2_pop_valid_o), .d2_pop_addr_o(d2_pop_addr_o),
        .mem_req_valid_o(mem_req_valid_o), .mem_req_wen_o(mem_req_wen_o),
        .mem_req_addr_o(mem_req_addr_o),
        .mem_req_ready_i(mem_req_ready),
        .mem_rsp_valid_i(rsp_v), .mem_rsp_rdata_i(rsp_data), .mem_rsp_tag_i(rsp_tag),
        .mem_rsp_err_i(mem_rsp_err),
        .st_xlate_en_i(st_xlate_en), .st_xlate_ctx_i(st_xlate_ctx),
        .st_xlate_ready_i(st_xlate_ready), .st_xlate_done_i(st_xlate_done),
        .st_xlate_pa_i(st_xlate_pa), .st_xlate_fault_i(st_xlate_fault),
        .trp_flush_v_i(trp_flush_v), .trp_redirect_v_i(trp_redirect_v),
        .trp_redirect_pc_i(trp_redirect_pc), .trp_halt_o(trp_halt_o),
        .csr_raddr_o(csr_raddr_o),
        .csr_rdata_i(csr_rdata), .csr_frm_i(csr_frm), .csr_fflags_i(csr_fflags),
        .priv_i(priv), .csr_we_o(csr_we_o), .csr_waddr_o(csr_waddr_o),
        .csr_wdata_o(csr_wdata_o),
        .maint_rdy_i(maint_rdy), .cbo_perm_i(cbo_perm), .maint_cmt_o(maint_cmt_o),
        .xret_cmt_o(xret_cmt_o),
        .trap_valid_o(trap_valid_o), .trap_pc_o(trap_pc_o),
        .trap_tval_o(trap_tval_o), .trap_cause_o(trap_cause_o),
        .commit_valid_o(commit_valid_o), .commit_pc_o(commit_pc_o),
        .commit_arch_rd_o(commit_arch_rd_o),
        .commit_arch_rd_wdata_o(commit_arch_rd_wdata_o),
`ifdef BACKEND_HAS_PMP
        .pmp_cmt_o(pmp_cmt_o), .pmp_cmt_next_pc_o(pmp_cmt_next_pc_o),
`endif
`ifdef BACKEND_HAS_LSQ_F4
        // F4-1 LSQ 透传：本权限 TB 不建模 Top 访存适配器 ⇒ 显式接 0（不靠 Z 净化）。
        .mem_rsp_cause_i(4'h0), .mem_rsp_defer_i(1'b0), .mem_rsp_side_i(1'b0),
        .st_xlate_fault_cause_i(4'h0),
`endif
`ifdef BACKEND_HAS_CSR_CHK
        .csr_chk_valid_o(csr_chk_valid_o), .csr_chk_addr_o(csr_chk_addr_o),
        .csr_chk_wr_o(csr_chk_wr_o),
        .csr_chk_illegal_i(csr_chk_illegal_w),
        .csr_chk_ro_write_i(csr_chk_ro_wr_w),
        .csr_tsr_i(csr_mstatus_w[`RV32GC_MSTATUS_TSR_BIT]),
        .csr_tvm_i(csr_mstatus_w[`RV32GC_MSTATUS_TVM_BIT]),
`endif
        .commit_arch_we_o(commit_arch_we_o)
    );

    //--------------------------------------------------------------------------
    // 真实 CSR 文件（检查反馈真源）
    //--------------------------------------------------------------------------
    reg         setup_we;
    reg  [11:0] setup_addr;
    reg  [31:0] setup_data;
    wire csr_file_we_w = setup_we | csr_we_o;
    wire [11:0] csr_file_waddr_w = setup_we ? setup_addr : csr_waddr_o;
    wire [31:0] csr_file_wdata_w = setup_we ? setup_data : csr_wdata_o;

    csr_file u_csr_file (
        .clk(clk), .rst_n(rst_n),
        .raddr(csr_raddr_o), .rdata(csr_rdata_cf_w),
        .wen(csr_file_we_w), .waddr(csr_file_waddr_w), .wdata(csr_file_wdata_w),
        .w_illegal(1'b0), .rdata_w(),
        .byp_wdata(32'h0), .byp_rdata(),
        .priv(priv), .chk_addr(csr_chk_addr_o),
        .chk_illegal(csr_chk_illegal_w), .chk_ro_write(csr_chk_ro_wr_w),
        .mstatus_o(csr_mstatus_w), .mstatus_set(32'h0), .mstatus_clr(32'h0),
        .trap_we(4'h0), .trap_epc_i(32'h0), .trap_cause_i(32'h0),
        .trap_tval_i(32'h0), .trap_data_i(32'h0),
        .irq_msip(1'b0), .irq_mtip(1'b0), .irq_meip(1'b0),
        .irq_stip(1'b0), .irq_seip(1'b0),
        .cycle_i(64'h0), .instret_i(64'h0),
`ifdef BACKEND_HAS_CSR_CHK
        .mtime_i(64'h0), .mcycle_we_o(), .mcycleh_we_o(),
        .minstret_we_o(), .minstreth_we_o(), .cnt_wdata_o(),
`endif
        .pmp_cfg_o(csr_pmp_cfg_w), .pmp_addr_o(csr_pmp_addr_w),
        .satp_o(csr_satp_w), .menvcfg_o(csr_menvcfg_w), .senvcfg_o(csr_senvcfg_w),
        .mcounteren_o(csr_mcounteren_w), .scounteren_o(csr_scounteren_w),
        .mtvec_o(csr_mtvec_w), .stvec_o(csr_stvec_w),
        .medeleg_o(csr_medeleg_w), .mideleg_o(csr_mideleg_w),
        .mie_o(csr_mie_w), .mip_o(csr_mip_w),
        .mepc_o(csr_mepc_w), .sepc_o(csr_sepc_w)
    );

    assign csr_rdata = csr_rdata_cf_w;

    // 真实前端 RAS：把 backend 的推测/提交协议接到 bpu_ras；PMP 事件经一拍注册
    // 反馈为 flush_all，随后按事件 next-PC 重放（不 force DUT 内部状态）。
    wire [4:0] ras_depth_o;
    wire [31:0] ras_cnt_push, ras_cnt_pop, ras_cnt_ovf, ras_cnt_repair;
    wire pmp_event_for_ras;
    reg ras_flush_feedback;
`ifdef BACKEND_HAS_PMP
    assign pmp_event_for_ras = pmp_cmt_o;
`else
    assign pmp_event_for_ras = 1'b0;
`endif
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ras_flush_feedback <= 1'b0;
        else ras_flush_feedback <= pmp_event_for_ras;
    end
    bpu_ras u_ras (
        .clk(clk), .rst_n(rst_n),
        .push_valid(d2_push_valid_o), .push_addr(d2_push_addr_o),
        .pop_valid(d2_pop_valid_o), .pop_addr(d2_pop_addr_o),
        .repair_valid(), .repair_addr(), .ras_top(), .ras_empty(),
        .depth_o(ras_depth_o), .restore_valid(1'b0), .depth_restore(5'd0),
        .flush_all(trp_flush_v | ras_flush_feedback),
        .cmt_push_valid(ras_cmt_push_valid_o), .cmt_pop_valid(ras_cmt_pop_valid_o),
        .cnt_push(ras_cnt_push), .cnt_pop(ras_cnt_pop),
        .cnt_ovf(ras_cnt_ovf), .cnt_repair(ras_cnt_repair)
    );

    //--------------------------------------------------------------------------
    // 程序 / 规格表
    //--------------------------------------------------------------------------
    reg [31:0] prog   [0:NINS-1];
    reg [3:0]  e_cmt  [0:NINS-1];
    reg [3:0]  d_cmt  [0:NINS-1];
    integer    e_trap, d_trap;          // 陷阱项 index；-1 = 无
    //   ★ 3fd 旧候选（sys_of_rob 12bit 截断）缺陷签名表；+EXPECT_3FD 时覆盖 d_*
    integer    exp_3fd, m_override;
    reg [3:0]  m_cmt [0:NINS-1];
    integer    m_trap, m_cause, m_ld_after, m_sq_mask;
    reg [31:0] m_tval;
    reg        m_xret, m_maint, m_csrwe, m_chkv, m_chkw;
    reg [11:0] m_chka;
    reg [3:0]  e_cause, d_cause;
    reg [31:0] e_tval, d_tval;
    reg        e_xret, d_xret, e_maint, d_maint;
    reg        e_csrwe, d_csrwe;
    reg        e_chkv, d_chkv;
    reg [11:0] e_chka, d_chka;
    reg        e_chkw, d_chkw;
    //   ★★ F4-1 覆盖 P1：pending 生命周期/真实门观察
    //     e/d_ld_after：2=不检查；1=年轻 load 首次请求在“最后一条 CSR 提交”之后；
    //                    0=在它之前/同拍（旧单 pending/无条件清的缺陷签名）
    //     e/d_sq_mask：2=不检查；1=partial squash 后位图 bit1=1/bit3=0
    integer    e_ld_after, d_ld_after, e_sq_mask, d_sq_mask;
    integer    csr_pc_idx;          // 用于 load-order 的“最后一条 CSR”PC 索引
    integer    br_lane;             // 条件分支 lane（-1=无）
    integer    ras_lane;
    integer    ras_seed_lane, ras_pc_idx;
    reg [3:0]  ras_ckpt_id, ras_seed_ckpt_id;
    integer    o_ckpt_free_id1_n, o_ckpt_free_id2_n, o_ckpt_bad_n;
    reg [2:0]  ras_cls, ras_seed_cls;
    reg [31:0] ras_pred_target, ras_seed_target;
    integer    o_ras_push_n, o_ras_pop_n, o_ras_flush_n;
    integer    o_ras_pre_depth, o_ras_post_depth;
    integer    o_ras_pre_cmt_depth, o_ras_post_cmt_depth;
    integer    o_ld_after;
    reg        o_ld_seen;
    integer    o_ld_req_cyc, o_last_csr_cyc, cyc_cnt;
    reg        o_sq_seen, o_sq_bit1, o_sq_bit3;
    reg         o_pmp_seen;
    reg [31:0]  o_pmp_next_pc;
    reg         o_store0_enq, o_store1_enq;
    integer     e_pmp_seen, d_pmp_seen, e_pmp_next_pc, d_pmp_next_pc;
    integer     e_store0_enq, d_store0_enq, e_store1_enq, d_store1_enq;
    integer     o_store_enq_n, o_store_ext_n;
    integer     e_csrwe_early, d_csrwe_early;
    reg         o_csrwe_early;
`ifdef BACKEND_HAS_PMP
    wire        pmp_cmt_o;
    wire [31:0] pmp_cmt_next_pc_o;
`endif
    reg        is_trigger;
    reg [8*32-1:0] cname;
    integer    n_insn, case_i;
    reg [1:0]  case_priv;
    reg [31:0] setup_ms, setup_mc;
    reg        do_ms, do_mc;

    // 观测
    reg [NINS-1:0] o_cmt;   // PC 集合辅助观察；精确验收另用逐 PC 次数
    integer    o_pc_count [0:NINS-1];
    integer    pc_hits;
    reg        o_trap, o_xret, o_maint, o_csrwe, o_chkv, o_chkw, o_prf_side;
    reg [11:0] o_chka;
    reg [3:0]  o_cause;
    reg [31:0] o_tval, o_trappc;
    reg        o_xz;
    reg        mon_en;
    integer    o_cmt_n;

    // 旧树没有新的候选口 ⇒ 观测按 0 处理（端口宏只适配接口，不改黄金）
`ifndef BACKEND_HAS_CSR_CHK
    assign csr_chk_valid_o = 1'b0;
    assign csr_chk_addr_o  = 12'h0;
    assign csr_chk_wr_o    = 1'b0;
`endif

    //--------------------------------------------------------------------------
    // 数据从设备（本 TB 的 load 用例只需要固定字数据；与 18 包同口径）
    //--------------------------------------------------------------------------
    reg [31:0] lmem [0:255];
    integer mi;
    reg [4:0]  slow_cnt;
    reg [`BACK2_MEM_TAG_W-1:0] slow_tag;
    reg [31:0] slow_data;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_v <= 1'b0; rsp_data <= 32'h0; rsp_tag <= {`BACK2_MEM_TAG_W{1'b0}};
        end else begin
            rsp_v <= 1'b0;
            if ((mem_req_valid_o === 1'b1) && (mem_req_ready === 1'b1) &&
                (mem_req_wen_o === 1'b0)) begin
                if (mem_req_addr_o[9:2] == 10'd4) begin
                    // 慢 load（地址 16）：24 拍后才回，制造 true slow-load→CSR 跨组
                    slow_cnt  <= 5'd24;
                    slow_tag  <= u_dut.mem_req_tag_o;
                    slow_data <= lmem[4];
                end else begin
                    rsp_v    <= 1'b1;
                    rsp_tag  <= u_dut.mem_req_tag_o;
                    rsp_data <= lmem[mem_req_addr_o[9:2]];
                end
            end else if (slow_cnt != 5'd0) begin
                slow_cnt <= slow_cnt - 5'd1;
                if (slow_cnt == 5'd1) begin
                    rsp_v    <= 1'b1;
                    rsp_tag  <= slow_tag;
                    rsp_data <= slow_data;
                end
            end
        end
    end

    function isx1(input v); begin isx1 = (v !== 1'b0) && (v !== 1'b1); end endfunction


    integer k, cy;
    always @(posedge clk) begin
        if (mon_en === 1'b1) begin
            cyc_cnt <= cyc_cnt + 1;
            o_cmt_n <= o_cmt_n + commit_valid_o[0] + commit_valid_o[1] +
                       commit_valid_o[2] + commit_valid_o[3];
        end
        if ((rst_n === 1'b1) && (mon_en === 1'b1)) begin
            if (isx1(trap_valid_o) || isx1(csr_we_o) || isx1(xret_cmt_o) ||
                isx1(maint_cmt_o) || isx1(csr_chk_valid_o) || isx1(csr_chk_wr_o) ||
                $isunknown(commit_valid_o))
                o_xz <= 1'b1;
            for (k = 0; k < 4; k = k + 1) begin
                if (commit_valid_o[k] === 1'b1) begin
                    pc_hits = 0;
                    for (cy = 0; cy < NINS; cy = cy + 1) begin
                        if (commit_pc_o[k*32 +: 32] === (BASE + 4*cy)) begin
                            o_cmt[cy] <= 1'b1;
                            o_pc_count[cy] = o_pc_count[cy] + 1;
                            pc_hits = pc_hits + 1;
                        end
                    end
                    if (pc_hits != 1) o_xz <= 1'b1; // 重复/范围外/未知 PC 一律失败
                end
            end
            if (trap_valid_o === 1'b1) begin
                if (!o_trap) begin
                    o_trap   <= 1'b1;
                    o_cause  <= trap_cause_o;
                    o_tval   <= trap_tval_o;
                    o_trappc <= trap_pc_o;
                end
            end
            if (xret_cmt_o === 1'b1) o_xret <= 1'b1;
            if (maint_cmt_o === 1'b1) o_maint <= 1'b1;
            if (csr_we_o === 1'b1) begin
                o_csrwe <= 1'b1;
                if ($isunknown(csr_waddr_o) || $isunknown(csr_wdata_o)) o_xz <= 1'b1;
            end
            if (csr_chk_valid_o === 1'b1) begin
                o_chkv <= 1'b1;
                o_chka <= csr_chk_addr_o;
                o_chkw <= csr_chk_wr_o;
            end
            //   ★★ F4-1 覆盖：最后一条 CSR 提交拍 / 年轻 load 首次请求拍 / squash 位图
            if (commit_valid_o[0] && (commit_pc_o[0*32 +: 32] === (BASE + 4*csr_pc_idx)))
                o_last_csr_cyc <= cyc_cnt;
            if (commit_valid_o[1] && (commit_pc_o[1*32 +: 32] === (BASE + 4*csr_pc_idx)))
                o_last_csr_cyc <= cyc_cnt;
            if (commit_valid_o[2] && (commit_pc_o[2*32 +: 32] === (BASE + 4*csr_pc_idx)))
                o_last_csr_cyc <= cyc_cnt;
            if (commit_valid_o[3] && (commit_pc_o[3*32 +: 32] === (BASE + 4*csr_pc_idx)))
                o_last_csr_cyc <= cyc_cnt;
            if ((mem_req_valid_o === 1'b1) && (mem_req_wen_o === 1'b0) && !o_ld_seen) begin
                o_ld_seen  <= 1'b1;
                o_ld_req_cyc <= cyc_cnt;
            end
            if ((mem_req_valid_o === 1'b1) && (mem_req_wen_o === 1'b1) &&
                (mem_req_ready === 1'b1)) o_store_ext_n = o_store_ext_n + 1;
`ifdef BACKEND_HAS_CSR_CHK
            if (u_dut.squash_v_w === 1'b1) begin
                o_sq_seen <= 1'b1;
                o_sq_bit1 <= u_dut.csr_mask_sq_w[1];
                o_sq_bit3 <= u_dut.csr_mask_sq_w[3];
            end
`endif
            if ((case_i == 25) && (csr_we_o === 1'b1)) begin
                if (!(((commit_valid_o[0] === 1'b1) && (commit_pc_o[31:0] === (BASE+4))) ||
                      ((commit_valid_o[1] === 1'b1) && (commit_pc_o[63:32] === (BASE+4)))))
                    o_csrwe_early <= 1'b1;
            end
`ifdef BACKEND_HAS_PMP
            if ((case_i >= 23) && (isx1(pmp_cmt_o) ||
                isx1(u_dut.lsu_dr_valid[0]) || isx1(u_dut.lsu_dr_valid[1]))) o_xz <= 1'b1;
            if ((case_i >= 31) && (isx1(ras_cmt_push_valid_o) || isx1(ras_cmt_pop_valid_o))) o_xz <= 1'b1;
            if (ras_flush_feedback === 1'b1) o_ras_flush_n = o_ras_flush_n + 1;
            if ((case_i >= 31) && isx1(ckpt_free_valid_o)) o_xz <= 1'b1;
            if ((ckpt_free_valid_o === 1'b1) && (ckpt_free_id_o == 4'd1)) o_ckpt_free_id1_n = o_ckpt_free_id1_n + 1;
            if ((ckpt_free_valid_o === 1'b1) && (ckpt_free_id_o == 4'd2)) o_ckpt_free_id2_n = o_ckpt_free_id2_n + 1;
            if ((case_i >= 31) && (ckpt_free_valid_o === 1'b1) &&
                (ckpt_free_id_o != 4'd1) && (ckpt_free_id_o != 4'd2)) o_ckpt_bad_n = o_ckpt_bad_n + 1;
            if (ras_cmt_push_valid_o === 1'b1) o_ras_push_n = o_ras_push_n + 1;
            if (ras_cmt_pop_valid_o === 1'b1) o_ras_pop_n = o_ras_pop_n + 1;
            if (pmp_cmt_o === 1'b1) begin
                o_pmp_seen   <= 1'b1;
                o_pmp_next_pc <= pmp_cmt_next_pc_o;
            end
            if (u_dut.lsu_dr_valid[0] === 1'b1) o_store0_enq <= 1'b1;
            if (u_dut.lsu_dr_valid[1] === 1'b1) o_store1_enq <= 1'b1;
            if (u_dut.lsu_dr_valid[0] === 1'b1) o_store_enq_n = o_store_enq_n + 1;
            if (u_dut.lsu_dr_valid[1] === 1'b1) o_store_enq_n = o_store_enq_n + 1;
`endif
`ifdef BACKEND_HAS_CSR_CHK
            // 非法候选的 E1 不得产生架构 PRF 写（a0_wb_i 是 ALU0 的体系结构写使能）。
            if ((u_dut.csr_v_w === 1'b1) && (u_dut.csr_chk_ill === 1'b1) &&
                (u_dut.a0_wb_i !== 1'b0)) o_prf_side <= 1'b1;
`endif
        end
    end

    //--------------------------------------------------------------------------
    // 驱动
    //--------------------------------------------------------------------------
    task automatic csr_setup(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk);
            setup_we   = 1'b1;
            setup_addr = a;
            setup_data = d;
            @(posedge clk);
            setup_we   = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic drive_stream(input integer first, input integer count);
        integer b, i, idx, rem;
        begin
            for (b = 0; b < count; b = b + 4) begin
                while ((u_dut.d1_v_q !== 4'b0000) || (blk_ready_o !== 1'b1)) @(posedge clk);
                blk_valid = 1'b0;
                rem = count - b;
                blk_mask = (rem >= 4) ? 4'b1111 : (rem == 3) ? 4'b0111 :
                           (rem == 2) ? 4'b0011 : 4'b0001;
                blk_next_pc = BASE + 4*(first + b + 4);
                for (i = 0; i < 4; i = i + 1) begin
                    idx = first + b + i;
                    lane_pc   [i*32 +: 32] = BASE + 4*idx;
                    lane_pa   [i*32 +: 32] = BASE + 4*idx;
                    lane_insn [i*32 +: 32] = (i < rem) ? prog[idx] : 32'h0000_0013;
                    lane_cls  [i*3 +: 3]   = 3'd0;
                    lane_pred_taken[i] = 1'b0;
                    lane_pred_target[i*32 +: 32] = 32'h0;
                    lane_btb_hit[i] = 1'b0; lane_btb_way[i] = 1'b0;
                    lane_btb_cond[i] = 1'b0; lane_btb_call[i] = 1'b0;
                    lane_btb_ret[i] = 1'b0; lane_btb_target[i*32 +: 32] = 32'h0;
                end
                @(posedge clk);
                blk_valid = 1'b1;
                @(posedge clk);
                blk_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    task automatic drive_pmp_ret_block;
        integer i;
        begin
            while ((u_dut.d1_v_q !== 4'b0000) || (blk_ready_o !== 1'b1)) @(posedge clk);
            blk_valid = 1'b0; blk_mask = 4'b0011; blk_next_pc = BASE + 12;
            for (i = 0; i < 4; i = i + 1) begin
                lane_pc[i*32 +: 32] = BASE + 4*(i+1);
                lane_pa[i*32 +: 32] = lane_pc[i*32 +: 32];
                lane_insn[i*32 +: 32] = (i == 0) ? prog[1] :
                                         (i == 1) ? prog[2] : 32'h0000_0013;
                lane_cls[i*3 +: 3] = (i == 1) ? ras_cls : 3'd0;
                lane_pred_taken[i] = (i == 1);
                lane_pred_target[i*32 +: 32] = (i == 1) ? ras_pred_target : 32'h0;
                lane_ckpt[i*4 +: 4] = (i == 1) ? ras_ckpt_id : 4'd0;
                lane_ckpt_valid[i] = (i == 1);
                lane_btb_hit[i] = 1'b0; lane_btb_way[i] = 1'b0;
                lane_btb_cond[i] = 1'b0; lane_btb_call[i] = 1'b0;
                lane_btb_ret[i] = 1'b0; lane_btb_target[i*32 +: 32] = 32'h0;
            end
            @(posedge clk); blk_valid = 1'b1;
            @(posedge clk); blk_valid = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic drive_ras_replay;
        integer i;
        begin
            while ((u_dut.d1_v_q !== 4'b0000) || (blk_ready_o !== 1'b1)) @(posedge clk);
            blk_valid = 1'b0; blk_mask = 4'b0001; blk_next_pc = BASE + 4*(ras_pc_idx+1);
            for (i = 0; i < 4; i = i + 1) begin
                lane_pc[i*32 +: 32] = (i == 0) ? (BASE + 4*ras_pc_idx) : (BASE + 4*(ras_pc_idx+i));
                lane_pa[i*32 +: 32] = lane_pc[i*32 +: 32];
                lane_insn[i*32 +: 32] = (i == 0) ? prog[ras_pc_idx] : 32'h0000_0013;
                lane_cls[i*3 +: 3] = (i == 0) ? ras_cls : 3'd0;
                lane_pred_taken[i] = (i == 0);
                lane_pred_target[i*32 +: 32] = (i == 0) ? ras_pred_target : 32'h0;
                lane_ckpt[i*4 +: 4] = (i == 0) ? ras_ckpt_id : 4'd0;
                lane_ckpt_valid[i] = (i == 0);
                lane_btb_hit[i] = 1'b0; lane_btb_way[i] = 1'b0;
                lane_btb_cond[i] = 1'b0; lane_btb_call[i] = 1'b0;
                lane_btb_ret[i] = 1'b0; lane_btb_target[i*32 +: 32] = 32'h0;
            end
            @(posedge clk); blk_valid = 1'b1;
            @(posedge clk); blk_valid = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic drive_block(input integer n);
        integer i;
        begin
            // 先等 D1 空，再把块字段稳定**整拍**后才拉 blk_valid（避免与同拍 D1 沿竞争）。
            while (u_dut.d1_v_q !== 4'b0000) @(posedge clk);
            blk_valid   = 1'b0;
            blk_mask    = (n >= 4) ? 4'b1111 : (n == 3) ? 4'b0111 : (n == 2) ? 4'b0011 : 4'b0001;
            blk_next_pc = BASE + 4*n;
            for (i = 0; i < 4; i = i + 1) begin
                lane_pc   [i*32 +: 32] = BASE + 4*i;
                lane_pa   [i*32 +: 32] = BASE + 4*i;
                lane_insn [i*32 +: 32] = (i < n) ? prog[i] : 32'h0000_0013;
                lane_cls  [i*3 +: 3]   = (i == br_lane) ? 3'd1 :
                                          ((i == ras_lane) ? ras_cls :
                                           ((i == ras_seed_lane) ? ras_seed_cls : 3'd0));
                lane_pred_taken[i]     = (i == ras_lane) || (i == ras_seed_lane);
                lane_pred_target[i*32 +: 32] = (i == ras_lane) ? ras_pred_target :
                                                ((i == ras_seed_lane) ? ras_seed_target : 32'h0);
                lane_ckpt[i*4 +: 4] = (i == ras_lane) ? ras_ckpt_id :
                                        ((i == ras_seed_lane) ? ras_seed_ckpt_id : 4'd0);
                lane_ckpt_valid[i] = (i == ras_lane) || (i == ras_seed_lane);
                lane_btb_hit[i] = 1'b0; lane_btb_way[i] = 1'b0;
                lane_btb_cond[i] = 1'b0; lane_btb_call[i] = 1'b0;
                lane_btb_ret[i] = 1'b0; lane_btb_target[i*32 +: 32] = 32'h0;
            end
            @(posedge clk);          // 字段稳定一整拍
            blk_valid = 1'b1;
            @(posedge clk);          // D1 在此沿锁存
            blk_valid = 1'b0;
            @(posedge clk);          // 让 D1/派发推进
        end
    endtask

    integer verdict;
    reg spec_ok, defect_ok, xz_seen, bad_case;
    reg [8*32-1:0] nm;
    integer t;

    initial begin
        case_i = -1; is_trigger = 0; n_insn = 0; case_priv = 2'b11;
        setup_ms = 32'h0; setup_mc = 32'h0; do_ms = 0; do_mc = 0;
        for (t = 0; t < NINS; t = t + 1) begin
            prog[t] = 32'h0; e_cmt[t] = 0; d_cmt[t] = 0;
        end
        e_trap = -1; d_trap = -1; e_cause = 0; d_cause = 3'd2;
        exp_3fd = $test$plusargs("EXPECT_3FD"); m_override = 0;
        m_trap = -1; m_cause = 0; m_tval = 0; m_xret = 0; m_maint = 0;
        m_csrwe = 0; m_chkv = 0; m_chka = 0; m_chkw = 0;
        m_ld_after = 2; m_sq_mask = 2;
        for (t = 0; t < NINS; t = t + 1) m_cmt[t] = 0;
        e_tval = 0; d_tval = 0;
        e_xret = 0; d_xret = 0; e_maint = 0; d_maint = 0; e_csrwe = 0; d_csrwe = 0;
        e_chkv = 0; d_chkv = 0; e_chka = 0; d_chka = 0; e_chkw = 0; d_chkw = 0;
        e_ld_after = 2; d_ld_after = 2; e_sq_mask = 2; d_sq_mask = 2;
        csr_pc_idx = 2; br_lane = -1; ras_lane = -1; ras_seed_lane = -1; ras_pc_idx = -1; ras_ckpt_id = 4'd2; ras_seed_ckpt_id = 4'd1;
        ras_cls = 3'd0; ras_seed_cls = 3'd0; ras_pred_target = 32'h0; ras_seed_target = 32'h0;
        e_pmp_seen = 2; d_pmp_seen = 2; e_pmp_next_pc = 0; d_pmp_next_pc = 0;
        e_store0_enq = 2; d_store0_enq = 2; e_store1_enq = 2; d_store1_enq = 2;
        e_csrwe_early = 2; d_csrwe_early = 2;
        bad_case = 1'b0;

        if (!$value$plusargs("CASE=%d", case_i)) case_i = -1;

        //======================================================================
        // 固定向量表。编码常量：
        //   csrrw x1,mstatus,x0 = 3000_10F3；csrrw x1,satp,x0 = 1800_10F3
        //   csrrs x1,cycle,x0   = C000_20F3；csrrs x1,misa,x0 = 3010_20F3
        //   csrrs x1,misa,x2    = 3011_20F3；sret = 1020_0073；sfence.vma = 1200_0073
        //   addi x5,x0,0x11 = 0110_0293；addi x6,x0,0x22 = 0220_0313
        //======================================================================
        case (case_i)
        0: begin cname="M_CSRRW_MSTATUS_LEGAL"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h3000_10F3;
                 e_cmt[0]=1; e_csrwe=1; e_chkv=1; e_chka=12'h300; e_chkw=1;
                 d_cmt[0]=1; d_csrwe=1; d_chkv=1; d_chka=12'h300; d_chkw=1; end
        1: begin cname="S_TVM_SATP_ILL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_ms=32'h0010_0000; do_ms=1;
                 prog[0]=32'h0110_0293; prog[1]=32'h1800_10F3; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'h1800_10F3;
                 e_chkv=1; e_chka=12'h180; e_chkw=1;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_trap=-1; d_csrwe=1;
                 d_chkv=1; d_chka=12'h180; d_chkw=1; end
        2: begin cname="S_TVM0_SATP_CTRL"; is_trigger=0; n_insn=3; case_priv=2'b01;
                 prog[0]=32'h0110_0293; prog[1]=32'h1800_10F3; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=1;
                 e_chkv=1; e_chka=12'h180; e_chkw=1;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=1;
                 d_chkv=1; d_chka=12'h180; d_chkw=1; end
        3: begin cname="S_CY_CNT_DIS_ILL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_mc=32'h0; do_mc=1;      // mcounteren.CY=0（复位值），显式预置
                 prog[0]=32'h0110_0293; prog[1]=32'hC000_20F3; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'hC000_20F3;
                 e_chkv=1; e_chka=12'hC00; e_chkw=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_trap=-1; d_csrwe=1;
                 d_chkv=1; d_chka=12'hC00; d_chkw=0; end
        4: begin cname="S_CY_CNT_EN_CTRL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_mc=32'h0000_0001; do_mc=1;
                 prog[0]=32'h0110_0293; prog[1]=32'hC000_20F3; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=0;
                 e_chkv=1; e_chka=12'hC00; e_chkw=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=1;
                 d_chkv=1; d_chka=12'hC00; d_chkw=0; end
        5: begin cname="S_TSR_SRET_ILL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_ms=32'h0040_0000; do_ms=1;
                 prog[0]=32'h0110_0293; prog[1]=32'h1020_0073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'h1020_0073;
                 e_chkv=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_trap=-1; d_xret=1; d_chkv=0; end
        6: begin cname="S_TSR0_SRET_CTRL"; is_trigger=0; n_insn=3; case_priv=2'b01;
                 prog[0]=32'h0110_0293; prog[1]=32'h1020_0073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_xret=1; e_chkv=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_xret=1; d_chkv=0; end
        7: begin cname="M_TSR_SRET_LEGAL"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 setup_ms=32'h0040_0000; do_ms=1;
                 prog[0]=32'h1020_0073;
                 e_cmt[0]=1; e_xret=1; e_chkv=0;
                 d_cmt[0]=1; d_xret=1; d_chkv=0; end
        8: begin cname="S_TVM_SFENCE_ILL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_ms=32'h0010_0000; do_ms=1;
                 prog[0]=32'h0110_0293; prog[1]=32'h1200_0073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'h1200_0073;
                 e_chkv=0; e_maint=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_trap=-1; d_maint=1; d_chkv=0; end
        9: begin cname="S_TVM0_SFENCE_CTRL"; is_trigger=0; n_insn=3; case_priv=2'b01;
                 prog[0]=32'h0110_0293; prog[1]=32'h1200_0073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_maint=1; e_chkv=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_maint=1; d_chkv=0; end
        10:begin cname="M_TVM_SFENCE_LEGAL"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 setup_ms=32'h0010_0000; do_ms=1;
                 prog[0]=32'h1200_0073;
                 e_cmt[0]=1; e_maint=1; e_chkv=0;
                 d_cmt[0]=1; d_maint=1; d_chkv=0; end
        11:begin cname="M_MRET_LEGAL"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h3020_0073;
                 e_cmt[0]=1; e_xret=1; e_chkv=0;
                 d_cmt[0]=1; d_xret=1; d_chkv=0; end
        12:begin cname="RO_CSRRS_X0_LEGAL"; is_trigger=1; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h0000_0113; prog[1]=32'hF110_20F3;   // csrrs x1,mvendorid,x0
                 e_cmt[0]=1; e_cmt[1]=1; e_csrwe=0;
                 e_chkv=1; e_chka=12'hF11; e_chkw=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_csrwe=1;
                 d_chkv=1; d_chka=12'hF11; d_chkw=0; end
        13:begin cname="RO_CSRRS_X2_ILL"; is_trigger=0; n_insn=3; case_priv=2'b11;
                 prog[0]=32'h0000_0113; prog[1]=32'hF111_20F3; prog[2]=32'h0220_0313; // csrrs x1,mvendorid,x2
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'hF111_20F3;
                 e_chkv=0;
                 d_cmt[0]=1; d_trap=1; d_cause=3'd2; d_tval=32'hF111_20F3;
                 d_chkv=0; end
        14:begin cname="S_CSRRW_MSTATUS_ILL"; is_trigger=1; n_insn=1; case_priv=2'b01;
                 prog[0]=32'h3000_10F3;
                 e_trap=0; e_cause=3'd2; e_tval=32'h3000_10F3; e_cmt[0]=0;
                 e_chkv=0;
                 // 201 旧树把 decoder 的 priv 硬接 M ⇒ S 下 mstatus 写被放行并提交。
                 d_trap=-1; d_cmt[0]=1; d_csrwe=1; d_chkv=0; end
        15:begin cname="M_CSRRS_X0_NOWRITE"; is_trigger=1; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h3000_20F3;               // csrrs x1,mstatus,x0 ⇒ 无写
                 e_cmt[0]=1; e_csrwe=0; e_chkv=1; e_chka=12'h300; e_chkw=0;
                 d_cmt[0]=1; d_csrwe=1; d_chkv=0; end
        16:begin cname="M_CSRRS_X2_ZERO_WRITE"; is_trigger=0; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h0000_0113; prog[1]=32'h3001_20F3; // addi x2,x0,0; csrrs x1,mstatus,x2
                 e_cmt[0]=1; e_cmt[1]=1; e_csrwe=1; e_chkv=1; e_chka=12'h300; e_chkw=1;
                 d_cmt[0]=1; d_cmt[1]=1; d_csrwe=1; d_chkv=0; end
        //   ★★ F4-1 P1：sfence.vma 的 rs2/rs1 必须原样进 cause2 tval。
        //   17 = x0,x2 (12200073)；18 = x3,x2 (12218073，rs1/rs2 都非 0)。
        17:begin cname="S_TVM_SFENCE_RS2_ILL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_ms=32'h0010_0000; do_ms=1;
                 prog[0]=32'h0110_0293; prog[1]=32'h1220_0073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'h1220_0073;
                 e_chkv=0; e_maint=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_trap=-1; d_maint=1; d_chkv=0;
                 // 3fd 截断：rs2 丢 ⇒ 错 tval 0x12000073
                 m_cmt[0]=1; m_trap=1; m_cause=3'd2; m_tval=32'h1200_0073;
                 m_chkv=0; m_maint=0; m_csrwe=0; m_override=1; end
        18:begin cname="S_TVM_SFENCE_RS1RS2_ILL"; is_trigger=1; n_insn=3; case_priv=2'b01;
                 setup_ms=32'h0010_0000; do_ms=1;
                 prog[0]=32'h0110_0293; prog[1]=32'h1221_8073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_trap=1; e_cause=3'd2; e_tval=32'h1221_8073;
                 e_chkv=0; e_maint=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_trap=-1; d_maint=1; d_chkv=0;
                 // 3fd 截断：rs2 丢、rs1 保留 ⇒ 错 tval 0x12018073
                 m_cmt[0]=1; m_trap=1; m_cause=3'd2; m_tval=32'h1201_8073;
                 m_chkv=0; m_maint=0; m_csrwe=0; m_override=1; end
        19:begin cname="S_TVM0_SFENCE_RS1RS2_CTRL"; is_trigger=0; n_insn=3; case_priv=2'b01;
                 prog[0]=32'h0110_0293; prog[1]=32'h1221_8073; prog[2]=32'h0220_0313;
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_maint=1; e_chkv=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_maint=1; d_chkv=0; end
        //   ★★ F4-1 覆盖 P1：pending 位图/base/age 生命周期（独立程序 + 真实门观察）
        //   20：同块 {写 CSR, no-write CSR, 年轻 load}；no-write 也必须清 pending，
        //       年轻 load 的首笔请求必须晚于最后一条 CSR 提交（201 单 pending 会提前）。
        20:begin cname="MULTI_CSR_NOWRITE_UNLOCK"; is_trigger=1; n_insn=4; case_priv=2'b11;
                 csr_pc_idx=2;                       // 最后一条 CSR = lane2 (PC BASE+8)
                 prog[0]=32'h0000_0293;              // addi x5,x0,0
                 prog[1]=32'h3400_10F3;              // csrrw x1,mscratch,x0（真写）
                 prog[2]=32'h3400_2173;              // csrrs x2,mscratch,x0（无写）
                 prog[3]=32'h0002_A383;              // lw x7,0(x5)（更年轻，必须等 pending 清）
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_cmt[3]=1;
                 e_csrwe=1; e_ld_after=1; e_chkv=1; e_chka=12'h340; e_chkw=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_cmt[3]=1;
                 d_csrwe=1; d_ld_after=0; d_chkv=0; end
        //   21：同块 branch partial squash：老 CSR(lane1) 保、年轻 CSR(lane3) 杀；
        //       x5=1 ⇒ bne taken（预测 not-taken）⇒ squash 点 lane2，lane3 被杀。
        21:begin cname="SQUASH_KEEP_OLD_CSR_KILL_YOUNG"; is_trigger=0; n_insn=4; case_priv=2'b11;
                 br_lane=2; csr_pc_idx=1;
                 prog[0]=32'h0010_0293;              // addi x5,x0,1
                 prog[1]=32'h3400_10F3;              // csrrw x1,mscratch,x0（老 CSR，存活）
                 prog[2]=32'h0002_9463;              // bne x5,x0,+8（实际 taken，预测 not-taken）
                 prog[3]=32'h3401_9173;              // csrrw x2,mscratch,x3（年轻 CSR，应被杀）
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_cmt[3]=0;
                 e_csrwe=1; e_sq_mask=1; e_chkv=1; e_chka=12'h340; e_chkw=1;
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_cmt[3]=0;
                 d_csrwe=1; d_sq_mask=2; d_chkv=0; end
        //   22：128 条流（>ROB_N=64）⇒ head/tail 环绕到 0；在 idx64 放 CSR+load，
        //       验证下一 CSR 块 base 复用/age 仍正确（load 不得被旧 base 卡死）。
        22:begin cname="ROB_WRAP_NEXT_CSR_BLOCK"; is_trigger=0; n_insn=NINS; case_priv=2'b11;
                 csr_pc_idx=64;
                 for (t = 0; t < NINS; t = t + 1) begin
                     prog[t] = 32'h0000_0013;        // nop
                     e_cmt[t] = 1; d_cmt[t] = 1;
                 end
                 prog[64]=32'h3400_10F3;             // csrrw x1,mscratch,x0
                 prog[65]=32'h0002_A383;             // lw x7,0(x0)
                 e_csrwe=1; e_ld_after=1; e_chkv=1; e_chka=12'h340; e_chkw=1;
                 d_csrwe=1; d_ld_after=1; d_chkv=0; end
        //   ★★ F4-1 PMP-Sync：同拍 PMP CSR(lane0)+年轻 store(lane1) ⇒ store 必须被夹掉；
        //      旧树 0011 仍提交/入 CDQ ⇒ 非法落写。
        23:begin cname="PMP_CSR_LANE0_STORE_LANE1"; is_trigger=1; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h3A00_10F3;             // csrrw x1,pmpcfg0,x0（合法 PMP 写）
                 prog[1]=32'h0021_A023;             // sw x2,0(x3)（年轻 store，同组）
                 e_cmt[0]=1; e_cmt[1]=0; e_csrwe=1;
                 e_chkv=1; e_chka=12'h3A0; e_chkw=1;
                 e_pmp_seen=1; e_pmp_next_pc=BASE+4; e_store1_enq=0;
                 d_cmt[0]=1; d_cmt[1]=1; d_csrwe=1; d_chkv=0;
                 d_pmp_seen=0; d_pmp_next_pc=0; d_store1_enq=1; end
        //   24：更老 store(lane0) + PMP CSR(lane1)；老 store 已入 CDQ，不得 retro 撤。
        24:begin cname="OLDER_STORE_LANE0_PMP_CSR_LANE1"; is_trigger=0; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h0021_A023;             // sw x2,0(x3)（更老 store）
                 prog[1]=32'h3A00_10F3;             // csrrw x1,pmpcfg0,x0
                 e_cmt[0]=1; e_cmt[1]=1; e_csrwe=1;
                 e_chkv=1; e_chka=12'h3A0; e_chkw=1;
                 e_pmp_seen=1; e_pmp_next_pc=BASE+8; e_store0_enq=1;
                 d_cmt[0]=1; d_cmt[1]=1; d_csrwe=1; d_chkv=0;
                 d_pmp_seen=0; d_pmp_next_pc=0; d_store0_enq=1; end
        //   ★★ 慢 load→PMP CSR 跨组：load 24 拍后才回；CSR 在 lane1，等 load 退休后
        //      才成为 head 并真提交。raw 候选提前只允许夹年轻 store，actual CSRwe/event
        //      必须等 final commit；event next=CSR PC+4，store CDQ=0。
        25:begin cname="SLOW_LOAD_PMP_CSR_EVENT"; is_trigger=0; n_insn=3; case_priv=2'b11;
                 prog[0]=32'h0100_2283;             // lw x5,16(x0)（慢 24 拍）
                 prog[1]=32'h3A12_9073;             // csrrw x0,pmpcfg1,x5（依赖慢 load）
                 prog[2]=32'h0021_A023;             // sw x2,0(x3)（年轻 store）
                 e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=0; e_csrwe=1;
                 e_chkv=1; e_chka=12'h3A1; e_chkw=1;
                 e_pmp_seen=1; e_pmp_next_pc=BASE+8; e_store1_enq=0;
                 e_csrwe_early=0;
                 // 旧 67c 前的 9947：raw csr_cmt_we 直接写 ⇒ 慢 load 未退休就 csr_we
                 d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=0; d_csrwe=1;
                 d_pmp_seen=1; d_pmp_next_pc=BASE+8; d_store1_enq=0;
                 d_csrwe_early=1; d_chkv=0; end
        26:begin cname="PMP_CSRRS_X0_YOUNG_ALU_STORE"; is_trigger=0; n_insn=3; case_priv=2'b11;
                  prog[0]=32'h3A00_20F3; prog[1]=32'h0110_0293; prog[2]=32'h0021_A023;
                  e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=0;
                  e_chkv=1; e_chka=12'h3A0; e_chkw=0; e_pmp_seen=0;
                  d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=0;
                  d_chkv=1; d_chka=12'h3A0; d_chkw=0; d_pmp_seen=0; end
         27:begin cname="PMP_CSRRC_X0_YOUNG_ALU_STORE"; is_trigger=0; n_insn=3; case_priv=2'b11;
                  prog[0]=32'h3A00_30F3; prog[1]=32'h0110_0293; prog[2]=32'h0021_A023;
                  e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=0;
                  e_chkv=1; e_chka=12'h3A0; e_chkw=0; e_pmp_seen=0;
                  d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=0;
                  d_chkv=1; d_chka=12'h3A0; d_chkw=0; d_pmp_seen=0; end
         28:begin cname="PMP_CSRRSI_ZERO_YOUNG_ALU_STORE"; is_trigger=0; n_insn=3; case_priv=2'b11;
                  prog[0]=32'h3A00_60F3; prog[1]=32'h0110_0293; prog[2]=32'h0021_A023;
                  e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=0;
                  e_chkv=1; e_chka=12'h3A0; e_chkw=0; e_pmp_seen=0;
                  d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=0;
                  d_chkv=1; d_chka=12'h3A0; d_chkw=0; d_pmp_seen=0; end
         29:begin cname="PMP_CSRCI_ZERO_YOUNG_ALU_STORE"; is_trigger=0; n_insn=3; case_priv=2'b11;
                  prog[0]=32'h3A00_70F3; prog[1]=32'h0110_0293; prog[2]=32'h0021_A023;
                  e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=0;
                  e_chkv=1; e_chka=12'h3A0; e_chkw=0; e_pmp_seen=0;
                  d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=0;
                  d_chkv=1; d_chka=12'h3A0; d_chkw=0; end
         30:begin cname="PMP_CSRRS_X2_VALUE_ZERO_TRUEWRITE"; is_trigger=0; n_insn=2; case_priv=2'b11;
                  prog[0]=32'h0000_0113; prog[1]=32'h3A01_20F3; // x2编码非零但值0，仍为真实写
                  e_cmt[0]=1; e_cmt[1]=1; e_csrwe=1; e_chkv=1; e_chka=12'h3A0; e_chkw=1;
                  e_pmp_seen=1; e_pmp_next_pc=BASE+8;
                  d_cmt[0]=1; d_cmt[1]=1; d_csrwe=1; d_chkv=1; d_chka=12'h3A0; d_chkw=1;
                  d_pmp_seen=1; d_pmp_next_pc=BASE+8; end
         31:begin cname="PMP_CUT_YOUNG_CORRECT_CALL_REPLAY"; is_trigger=0; n_insn=2; case_priv=2'b11;
                  ras_lane=1; ras_pc_idx=1; ras_cls=3'd5; ras_pred_target=BASE+4;
                  prog[0]=32'h3A00_1073; prog[1]=32'h0000_00EF; // PMP CSRRW + jal x1,0 正确预测
                  e_cmt[0]=1; e_cmt[1]=1; e_csrwe=1; e_chkv=1; e_chka=12'h3A0; e_chkw=1;
                  e_pmp_seen=1; e_pmp_next_pc=BASE+4;
                  d_cmt[0]=1; d_cmt[1]=1; d_csrwe=1; d_chkv=1; d_chka=12'h3A0; d_chkw=1;
                  d_pmp_seen=1; d_pmp_next_pc=BASE+4; end
         32:begin cname="PMP_CUT_YOUNG_CORRECT_RET_REPLAY"; is_trigger=0; n_insn=3; case_priv=2'b11;
                  ras_seed_lane=0; ras_seed_cls=3'd5; ras_seed_target=BASE+4;
                  ras_lane=1; ras_pc_idx=2; ras_cls=3'd4; ras_pred_target=BASE+4;
                  prog[0]=32'h0040_00EF; prog[1]=32'h3A00_1073; prog[2]=32'h0000_8067;
                  e_cmt[0]=1; e_cmt[1]=1; e_cmt[2]=1; e_csrwe=1; e_chkv=1; e_chka=12'h3A0; e_chkw=1;
                  e_pmp_seen=1; e_pmp_next_pc=BASE+8;
                  d_cmt[0]=1; d_cmt[1]=1; d_cmt[2]=1; d_csrwe=1; d_chkv=1; d_chka=12'h3A0; d_chkw=1;
                  d_pmp_seen=1; d_pmp_next_pc=BASE+8; end
         default: begin cname="BAD_CASE"; bad_case=1'b1; end
        endcase
        // 3fd fixedspec：仅 SFENCE rs-field 截断的 17/18 是该树的两个触发例。
        if (exp_3fd) is_trigger = ((case_i == 17) || (case_i == 18));

        // 3fd 模式：未显式覆盖的案例 m=e（3fd 只差 sys_of_rob 截断）
        if (!m_override) begin
            for (t = 0; t < NINS; t = t + 1) m_cmt[t] = e_cmt[t];
            m_trap = e_trap; m_cause = e_cause; m_tval = e_tval;
            m_xret = e_xret; m_maint = e_maint; m_csrwe = e_csrwe;
            m_chkv = e_chkv; m_chka = e_chka; m_chkw = e_chkw;
            m_ld_after = e_ld_after; m_sq_mask = e_sq_mask;
        end
        if (exp_3fd) begin
            for (t = 0; t < NINS; t = t + 1) d_cmt[t] = m_cmt[t];
            d_trap = m_trap; d_cause = m_cause; d_tval = m_tval;
            d_xret = m_xret; d_maint = m_maint; d_csrwe = m_csrwe;
            d_chkv = m_chkv; d_chka = m_chka; d_chkw = m_chkw;
            d_ld_after = m_ld_after; d_sq_mask = m_sq_mask;
        end

        //======================================================================
        // 初始化
        //======================================================================
        blk_valid=0; blk_mask=4'b0001; blk_next_pc=BASE; blk_taken=0;
        lane_pc=0; lane_pa=0; lane_insn=0; lane_len32=4'b0001; lane_cls=0;
        lane_pred_taken=0; lane_pred_selg=0; lane_pred_gdir=0; lane_pred_ldir=0;
        lane_pred_target=0; lane_btb_hit=0; lane_btb_way=0; lane_btb_cond=0;
        lane_btb_call=0; lane_btb_ret=0; lane_btb_target=0;
        lane_fault=0; lane_fault_cause=0; lane_fault_tval=0;
        lane_ckpt=0; lane_ckpt_valid=0; fe_fetch_fault=0;
        train_ready=1; mem_req_ready=1; mem_rsp_err=0;
        st_xlate_en=0; st_xlate_ctx=0; st_xlate_ready=1; st_xlate_done=0;
        st_xlate_pa=0; st_xlate_fault=0;
        trp_flush_v=0; trp_redirect_v=0; trp_redirect_pc=0;
        csr_frm=0; csr_fflags=0; setup_we=0; setup_addr=0; setup_data=0;
        maint_rdy=1; cbo_perm=2'b11;
        priv = 2'b11;
        rsp_v=0; rsp_data=0; rsp_tag=0;
        for (mi = 0; mi < 256; mi = mi + 1) lmem[mi] = 32'h0;
        lmem[0] = 32'h3FC0_0000;   // 1.5f；lw x7,0(x0) 的固定返回
        lmem[4] = 32'h9898_9818;   // slow load 返回；用于慢 load→PMP CSR
        slow_cnt = 0; slow_tag = 0; slow_data = 0;

        o_cmt = {NINS{1'b0}};
        for (t = 0; t < NINS; t = t + 1) o_pc_count[t] = 0;
        o_trap=0; o_xret=0; o_maint=0; o_csrwe=0;
        o_chkv=0; o_chka=0; o_chkw=0; o_prf_side=0;
        o_cause=0; o_tval=0; o_trappc=0; o_xz=0; o_cmt_n=0;
        o_ld_seen=0; o_ld_after=0; o_ld_req_cyc=0; o_last_csr_cyc=0; cyc_cnt=0;
        o_sq_seen=0; o_sq_bit1=0; o_sq_bit3=0;
        o_pmp_seen=0; o_pmp_next_pc=0; o_store0_enq=0; o_store1_enq=0;
        o_store_enq_n=0; o_store_ext_n=0; o_ras_push_n=0; o_ras_pop_n=0; o_ras_flush_n=0; o_ckpt_free_id1_n=0; o_ckpt_free_id2_n=0; o_ckpt_bad_n=0; o_ras_pre_depth=-1; o_ras_post_depth=-1; o_ras_pre_cmt_depth=-1; o_ras_post_cmt_depth=-1;
        o_csrwe_early=0;
        mon_en=0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 状态预置（不是被检查动作）：直接经 csr_file.wen 写 mstatus/mcounteren
        if (do_ms) csr_setup(`RV32GC_CSR_MSTATUS, setup_ms);
        if (do_mc) csr_setup(`RV32GC_CSR_MCOUNTEREN, setup_mc);
        if (do_ms || do_mc) repeat (2) @(posedge clk);

        priv = case_priv;
        mon_en = 1'b1;
        if (case_i == 32) begin
            drive_block(1);              // 真实提交call先种入RAS与committed depth
            repeat (12) @(posedge clk);
            drive_pmp_ret_block();       // PMP CSR + 年轻、预测正确ret
        end else if (n_insn > 4) drive_stream(0, n_insn);
        else            drive_block(n_insn);

        // 观察窗口：等提交/陷阱稳定；命中 trap 后脉冲 trp_flush_v 让 ROB 退役陷阱项
        for (cy = 0; cy < ((n_insn > 4) ? 2000 : 400); cy = cy + 1) begin
            @(posedge clk);
            if ((trap_valid_o === 1'b1) && (trp_flush_v === 1'b0)) begin
                trp_flush_v = 1'b1;
                @(posedge clk);
                trp_flush_v = 1'b0;
            end
        end
        if ((case_i == 31) || (case_i == 32)) begin
            // Registered PMP feedback drives the real RAS flush; then refetch from the event PC.
            #1; o_ras_pre_depth = ras_depth_o; o_ras_pre_cmt_depth = u_ras.sp_cmt_q;
            drive_ras_replay();
            repeat (80) @(posedge clk);
            #1; o_ras_post_depth = ras_depth_o; o_ras_post_cmt_depth = u_ras.sp_cmt_q;
        end
        mon_en = 1'b0;
        #1;
        o_ld_after = (o_ld_seen && (o_ld_req_cyc > o_last_csr_cyc)) ? 1 : 0;

        //======================================================================
        // 判定
        //======================================================================
        spec_ok = 1'b1; defect_ok = 1'b1; xz_seen = (o_xz === 1'b1);
        for (t = 0; t < NINS; t = t + 1) begin
            if ((e_cmt[t] !== o_cmt[t]) && (t < n_insn)) spec_ok = 1'b0;
            if ((d_cmt[t] !== o_cmt[t]) && (t < n_insn)) defect_ok = 1'b0;
            if (o_pc_count[t] != ((t < n_insn) ? e_cmt[t] : 0)) spec_ok = 1'b0;
            if (o_pc_count[t] != ((t < n_insn) ? d_cmt[t] : 0)) defect_ok = 1'b0;
            if ((t >= n_insn) && (o_cmt[t] !== 1'b0)) spec_ok = 1'b0;
        end
        if (o_trap !== (e_trap >= 0)) spec_ok = 1'b0;
        if (o_trap !== (d_trap >= 0)) defect_ok = 1'b0;
        if (e_trap >= 0) begin
            if (o_cause !== e_cause) spec_ok = 1'b0;
            if (o_tval !== e_tval) spec_ok = 1'b0;
            if (o_trappc !== (BASE + 4*e_trap)) spec_ok = 1'b0;
        end
        if (d_trap >= 0) begin
            if (o_cause !== d_cause) defect_ok = 1'b0;
            if (o_tval !== d_tval) defect_ok = 1'b0;
            if (o_trappc !== (BASE + 4*d_trap)) defect_ok = 1'b0;
        end
        if ((case_i >= 26) && (case_i <= 29)) begin
            if (o_store_enq_n != 1 || o_store_ext_n != 1) spec_ok = 1'b0;
        end
        if ((case_i == 31) && (o_ras_push_n != 1 || o_ras_pop_n != 0 ||
            o_ras_flush_n != 1 || o_ras_pre_depth != 0 || o_ras_post_depth != 1 ||
            o_ras_pre_cmt_depth != 0 || o_ras_post_cmt_depth != 1 ||
            o_ckpt_free_id1_n != 0 || o_ckpt_free_id2_n != 1 || o_ckpt_bad_n != 0)) spec_ok = 1'b0;
        if ((case_i == 32) && (o_ras_push_n != 1 || o_ras_pop_n != 1 ||
            o_ras_flush_n != 1 || o_ras_pre_depth != 1 || o_ras_post_depth != 0 ||
            o_ras_pre_cmt_depth != 1 || o_ras_post_cmt_depth != 0 ||
            o_ckpt_free_id1_n != 1 || o_ckpt_free_id2_n != 1 || o_ckpt_bad_n != 0)) spec_ok = 1'b0;
        if (o_xret  !== e_xret)  spec_ok = 1'b0;
        if (o_maint !== e_maint) spec_ok = 1'b0;
        if (o_csrwe !== e_csrwe) spec_ok = 1'b0;
`ifdef BACKEND_HAS_CSR_CHK
        if (o_chkv  !== e_chkv)  spec_ok = 1'b0;
        if (e_chkv && (o_chka !== e_chka)) spec_ok = 1'b0;
        if (e_chkv && (o_chkw !== e_chkw)) spec_ok = 1'b0;
`endif
        if (o_xret  !== d_xret)  defect_ok = 1'b0;
        if (e_csrwe_early != 2) begin
            if (o_csrwe_early !== e_csrwe_early[0]) spec_ok = 1'b0;
        end
        if (d_csrwe_early != 2) begin
            if (o_csrwe_early !== d_csrwe_early[0]) defect_ok = 1'b0;
        end
        if (o_maint !== d_maint) defect_ok = 1'b0;
        if (o_csrwe !== d_csrwe) defect_ok = 1'b0;
        //   pending 生命周期观察（真实门/时序）
        if (e_ld_after != 2) begin
            if (!o_ld_seen || (o_ld_after !== e_ld_after)) spec_ok = 1'b0;
        end
        if (d_ld_after != 2) begin
            if (!o_ld_seen || (o_ld_after !== d_ld_after)) defect_ok = 1'b0;
        end
`ifdef BACKEND_HAS_PMP
        if (e_pmp_seen != 2) begin
            if (o_pmp_seen !== e_pmp_seen) spec_ok = 1'b0;
            if (o_pmp_seen && (o_pmp_next_pc !== e_pmp_next_pc)) spec_ok = 1'b0;
        end
        if (d_pmp_seen != 2) begin
            if (o_pmp_seen !== d_pmp_seen) defect_ok = 1'b0;
            if (o_pmp_seen && (o_pmp_next_pc !== d_pmp_next_pc)) defect_ok = 1'b0;
        end
        if (e_store0_enq != 2) begin
            if (o_store0_enq !== e_store0_enq[0]) spec_ok = 1'b0;
        end
        if (d_store0_enq != 2) begin
            if (o_store0_enq !== d_store0_enq[0]) defect_ok = 1'b0;
        end
        if (e_store1_enq != 2) begin
            if (o_store1_enq !== e_store1_enq[0]) spec_ok = 1'b0;
        end
        if (d_store1_enq != 2) begin
            if (o_store1_enq !== d_store1_enq[0]) defect_ok = 1'b0;
        end
`endif
`ifdef BACKEND_HAS_CSR_CHK
        if (e_sq_mask != 2) begin
            if (!o_sq_seen || (o_sq_bit1 !== 1'b1) || (o_sq_bit3 !== 1'b0)) spec_ok = 1'b0;
        end
        if (d_sq_mask != 2) begin
            if (!o_sq_seen || (o_sq_bit1 !== 1'b1) || (o_sq_bit3 !== 1'b0)) defect_ok = 1'b0;
        end
`endif
`ifdef BACKEND_HAS_CSR_CHK
        if (o_chkv  !== d_chkv)  defect_ok = 1'b0;
        if (d_chkv && (o_chka !== d_chka)) defect_ok = 1'b0;
        if (d_chkv && (o_chkw !== d_chkw)) defect_ok = 1'b0;
`endif

        if (isx1(o_trap) || isx1(o_xret) || isx1(o_maint) || isx1(o_csrwe) ||
            isx1(o_prf_side) || isx1(o_chkv) || isx1(o_chkw)) xz_seen = 1'b1;
`ifdef BACKEND_HAS_CSR_CHK
        if (o_prf_side !== 1'b0) spec_ok = 1'b0;
`endif

        if (bad_case)                      verdict = 2;
        else if (xz_seen)                  verdict = 3;
        else if (spec_ok)                  verdict = 0;
        else if (is_trigger && defect_ok)  verdict = 1;
        else                               verdict = 2;

        $display("CASE %0d %0s KIND=%0s priv=%b n=%0d setup_ms=0x%08x setup_mc=0x%08x",
                 case_i, cname, is_trigger ? "trigger" : "control", case_priv, n_insn,
                 do_ms ? setup_ms : 32'h0, do_mc ? setup_mc : 32'h0);
        $display("CASE %0d %0s OBS cmt=%b n=%0d trap=%b pc=0x%08x cause=%0d tval=0x%08x xret=%b maint=%b csrwe=%b chkv=%b chka=0x%03x chkw=%b prf_side=%b spec_ok=%b defect_ok=%b xz=%b ldseen=%b ldcyc=%0d lastcsr=%0d ldafter=%0d sqseen=%b sq1=%b sq3=%b",
                 case_i, cname, o_cmt[3:0], o_cmt_n, o_trap, o_trappc, o_cause, o_tval,
                 o_xret, o_maint, o_csrwe, o_chkv, o_chka, o_chkw, o_prf_side,
                 spec_ok, defect_ok, o_xz, o_ld_seen, o_ld_req_cyc, o_last_csr_cyc,
                 o_ld_after, o_sq_seen, o_sq_bit1, o_sq_bit3);
        $display("CASE %0d %0s PMPOBS seen=%b next=0x%08x s0enq=%b s1enq=%b stores_enq=%0d stores_ext=%0d",
                 case_i, cname, o_pmp_seen, o_pmp_next_pc, o_store0_enq, o_store1_enq,
                 o_store_enq_n, o_store_ext_n);
        for (t = 0; t < n_insn; t = t + 1)
            $display("CASE %0d %0s PC_COUNT index=%0d count=%0d", case_i, cname, t, o_pc_count[t]);
        if ((case_i == 31) || (case_i == 32))
            $display("CASE %0d %0s RAS_COMMIT push=%0d pop=%0d flush=%0d pre=%0d/%0d post=%0d/%0d CKPT id1=%0d id2=%0d bad=%0d",
                     case_i, cname, o_ras_push_n, o_ras_pop_n, o_ras_flush_n,
                     o_ras_pre_depth, o_ras_pre_cmt_depth, o_ras_post_depth, o_ras_post_cmt_depth,
                     o_ckpt_free_id1_n, o_ckpt_free_id2_n, o_ckpt_bad_n);
        case (verdict)
            0: $display("CASE %0d %0s VERDICT=OK", case_i, cname);
            1: $display("CASE %0d %0s VERDICT=DEFECT_SIG", case_i, cname);
            2: $display("CASE %0d %0s VERDICT=UNEXPECTED", case_i, cname);
            default: $display("CASE %0d %0s VERDICT=XZ", case_i, cname);
        endcase
        $finish;
    end

    initial begin
        #2_000_000;
        $display("CASE %0d %0s WATCHDOG_END", case_i, cname);
        $finish;
    end

endmodule
