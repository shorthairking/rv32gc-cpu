//==============================================================================
// tb_backend_semantics.sv —— F1 后端包语义定向 TB（真实派发/分配/执行/提交全链）
//------------------------------------------------------------------------------
// 目标（触发来源：冻结审计 02-1 / 01 P0-01，见 sim/audit/global-2026-10-18/）：
//   A) 02-1：`f0` 是**合法浮点目的寄存器**，不得沿用整数 x0 的"丢弃写"规则。
//      要求：用真实指令经 backend_top 派发口注入 —— FLW→FP PRF 写→提交读回→
//      由后续消费者指令（FMV.X.W）**真实写后读**；FADD 的源先用真实 FLW 装载成
//      **有限非 NaN 值**（避免未 NaN-box 的默认寄存器把新旧结果都掩成 qNaN）。
//   B) 01 P0-01 / 02-4：decoder 必须吃**实际 priv_i**；U/S 的机器 CSR、U 的
//      MRET/SRET、U 的 SFENCE.VMA 必须 cause 2 且无 CSR 写 / xRET 提交 / 维护提交
//      等副作用；M 下同类指令仍合法。只用现有端口 `priv_i` 表达入口权限，不新增
//      TVM/TSR 常量端口；实际 csr_file 提交合法性/TVM/计数器门控属后续集成边界。
//
// 证据等级（不夸大）：backend 模块级。DUT 内部数组（PRF/rename）**只读**观测，
//   绝不 force / 直写 PRF / RAT —— 全部经真实 D1 派发 → 重命名 → IQ → 执行 → PRF
//   写口 → ROB 提交链。未实例化 csr_file/priv_ctrl/trap_ctrl ⇒ 不声称 mstatus 值
//   已被改写或整核提权发生；只断言"后端发出了何种使能 / 是否上报 cause 2"。
//
// 模式（TB 与源码状态无关，判定交给脚本）：
//   `vvp <vvp> +CASE=<n>` 只跑一个固定向量；TB 对**规范正确期望**自判并打印
//   `VERDICT=OK`（符合规范）/`VERDICT=DEFECT_SIG`（符合已知旧缺陷签名）/
//   `VERDICT=UNEXPECTED` / `VERDICT=XZ`（观测含未知态）。脚本据此在默认模式
//   要求全 OK，在反证模式（201acf61 只读快照）要求触发例 DEFECT_SIG、控制例 OK。
//   ⇒ 同一 TB 既可证明新源码"绿"，也可证明旧源码"红"。
//
// 四态安全（独审 P1-3）：**有效观察窗口内实时判控制/有效线 X/Z**（csr_we/xret/maint/
//   trap_valid/commit_valid/fprf_we 及"已断言才判"的载荷；不要求无效载荷全零）⇒ 任一
//   未知态锁 xz_seen，最终 VERDICT=XZ 而非 OK。另设 `+XINJ=<n>` 只往**私有监测替身**
//   注 X（不 force 真实 DUT 内部、不伪造架构缺陷）用于自证该敏感性。
// 固定非零向量：每条程序/CSR 回读值均为固定非零常量（见下方 per-case 表）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module tb_backend_semantics ();

    localparam integer NINS = 8;
    localparam [31:0]  BASE = 32'h8000_0000;
    localparam [31:0]  CSR_RDATA = 32'h1234_5678;   // 固定非零 CSR 回读值（M 下 csrrw rd 读回）

    //--------------------------------------------------------------------------
    // DUT 输入
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;

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
    reg  [31:0] csr_rdata;
    reg  [2:0]  csr_frm;
    reg  [4:0]  csr_fflags;
    reg  [1:0]  priv;
    reg         maint_rdy;
    reg  [1:0]  cbo_perm;

    //--------------------------------------------------------------------------
    // DUT 输出
    //--------------------------------------------------------------------------
    wire        blk_ready_o;
    wire        mem_req_valid_o, mem_req_wen_o;
    wire [31:0] mem_req_addr_o;
    wire        trap_valid_o, csr_we_o, xret_cmt_o, maint_cmt_o;
    wire [3:0]  trap_cause_o;
    wire [3:0]  commit_valid_o;
    wire [127:0] commit_pc_o;
    wire [19:0] commit_arch_rd_o;
    wire [127:0] commit_arch_rd_wdata_o;
    wire [3:0]  commit_arch_we_o;
    wire        trp_halt_o;   // 未用观测口（保持契约完整）

    // 数据从设备响应（寄存器化，逐拍）
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
        .csr_rdata_i(csr_rdata), .csr_frm_i(csr_frm), .csr_fflags_i(csr_fflags),
        .priv_i(priv), .csr_we_o(csr_we_o),
        .maint_rdy_i(maint_rdy), .cbo_perm_i(cbo_perm), .maint_cmt_o(maint_cmt_o),
        .xret_cmt_o(xret_cmt_o),
`ifdef BACKEND_HAS_CSR_CHK
        // F4-1 新增接口：本 18 向量包只做旧行为回归 ⇒ 检查输入固定 0（不启用新 gate）。
        // 新权限 TB 用自身实例化覆盖；旧 201 源码编译不定义本宏（纯接口适配）。
        .csr_chk_valid_o(), .csr_chk_addr_o(), .csr_chk_wr_o(),
        .csr_chk_illegal_i(1'b0), .csr_chk_ro_write_i(1'b0),
        .csr_tsr_i(1'b0), .csr_tvm_i(1'b0),
`endif
`ifdef BACKEND_HAS_LSQ_F4
        // F4-1 LSQ 透传：旧 basic bench 无 Top 适配器 ⇒ 显式接 0（不靠 Z 净化）。
        .mem_rsp_cause_i(4'h0), .mem_rsp_defer_i(1'b0), .mem_rsp_side_i(1'b0),
        .st_xlate_fault_cause_i(4'h0),
`endif
        .trap_valid_o(trap_valid_o), .trap_cause_o(trap_cause_o),
        .commit_valid_o(commit_valid_o), .commit_pc_o(commit_pc_o),
        .commit_arch_rd_o(commit_arch_rd_o), .commit_arch_rd_wdata_o(commit_arch_rd_wdata_o),
        .commit_arch_we_o(commit_arch_we_o)
    );

    //--------------------------------------------------------------------------
    // 只读数据从设备：按字地址返回固定数据（1.5f=0x3FC00000 @0；2.25f=0x40100000 @4）
    //--------------------------------------------------------------------------
    reg [31:0] lmem [0:255];
    integer mi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_v <= 1'b0; rsp_data <= 32'h0; rsp_tag <= {`BACK2_MEM_TAG_W{1'b0}};
        end else begin
            rsp_v <= 1'b0;
            // 只对 load 请求响应（写排水无需响应）；地址按字对齐取固定数据。
            if ((mem_req_valid_o === 1'b1) && (mem_req_ready === 1'b1) &&
                (mem_req_wen_o === 1'b0)) begin
                rsp_v    <= 1'b1;
                rsp_tag  <= u_dut.mem_req_tag_o;
                rsp_data <= lmem[mem_req_addr_o[9:2]];
            end
        end
    end

    //--------------------------------------------------------------------------
    // per-case 规格表 / 旧缺陷签名表（脚本判定交给自己：OK / DEFECT_SIG / UNEXPECTED / XZ）
    //--------------------------------------------------------------------------
    reg [31:0] prog    [0:NINS-1];
    reg        e_cmt   [0:NINS-1];   // 规范：该指令应提交
    reg        e_we    [0:NINS-1];   // 规范：提交写使能
    reg [4:0]  e_rd    [0:NINS-1];   // 规范：提交架构目的号
    reg [31:0] e_data  [0:NINS-1];   // 规范：提交读回数据
    reg        e_dv    [0:NINS-1];   // 规范：是否校验数据
    reg        e_dfv   [0:NINS-1];   // 规范：是否校验 D1 dst_fp
    reg        e_df    [0:NINS-1];

    reg        d_cmt   [0:NINS-1];   // 已知旧缺陷签名（触发例）
    reg        d_we    [0:NINS-1];
    reg [4:0]  d_rd    [0:NINS-1];
    reg [31:0] d_data  [0:NINS-1];
    reg        d_dv    [0:NINS-1];
    reg        d_dfv   [0:NINS-1];
    reg        d_df    [0:NINS-1];

    reg [8*40-1:0] cname;
    reg        is_trigger;
    integer    n_insn, case_i;
    reg [1:0]  case_priv;

    reg        e_trap2, e_csr, e_xret, e_maint;
    reg        d_trap2, d_csr, d_xret, d_maint;

    // 规范期望：FP PRF 写口出现指定数据（真实写 PRF 证据）
    reg        e_fprf_v;   reg [31:0] e_fprf_data;

    // 观测（由时钟块写入）
    reg        o_cmt   [0:NINS-1];
    reg        o_we    [0:NINS-1];
    reg [4:0]  o_rd    [0:NINS-1];
    reg [31:0] o_data  [0:NINS-1];
    reg        o_df    [0:NINS-1];
    reg        o_dint  [0:NINS-1];
    reg        o_illeg [0:NINS-1];
    reg        o_trap2, o_csr, o_xret, o_maint, o_fprf_wr, o_fprf_hit;

    integer ci, cj;

    //   ★★ 独审 P1-3：被动监测器的**私有观测替身** —— 默认 `+XINJ=0` 时 m_* 逐位等于
    //     真实 DUT 输出；自证模式可 `+XINJ=<n>` 只往**监测路径**注 X（不 force 真实
    //     DUT 内部、不伪造架构缺陷），验证"有效观察窗口内控制/有效线为 X/Z ⇒ VERDICT=XZ"。
    integer xinj;        // 0=不注入 1=csr_we 2=commit_valid 3=fprf_we
    reg     mon_en;      // 有效观察窗口（开始驱动前置 1，判定期前清 0）
    reg     o_xz_ctrl;   // 时钟块：窗口内控制/有效线出现 X/Z
    reg     o_xz_init;   // 初始块：D1 观测替身出现 X/Z
    wire        m_csr_we  = (xinj == 1) ? 1'bx : csr_we_o;
    wire [3:0]  m_cv      = (xinj == 2) ? 4'bxxxx : commit_valid_o;
    wire [1:0]  m_fprf_we = (xinj == 3) ? 2'bxx : u_dut.fprf_we;

    // iverilog 的 `$isunknown(拼接)` 不可靠（全 0 拼接也返回 1）⇒ 逐位/逐向量判 X/Z。
    function isx1;
        input v;
        begin isx1 = (v !== 1'b0) && (v !== 1'b1); end
    endfunction

    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // 观测：提交 / trap / 副作用脉冲 / FP PRF 写口（只读）
    //   有效窗口内：**控制/有效线**必须已知；载荷只在对应有效线断言时判 X
    //   （**不要求无效载荷全零**）。任一 X/Z ⇒ o_xz_ctrl=1 ⇒ 最终 VERDICT=XZ。
    //--------------------------------------------------------------------------
    integer k;
    always @(posedge clk) begin
        if ((rst_n === 1'b1) && (mon_en === 1'b1)) begin
            if (isx1(trap_valid_o) || isx1(m_csr_we) || isx1(xret_cmt_o) ||
                isx1(maint_cmt_o) || $isunknown(m_cv) || $isunknown(m_fprf_we))
                o_xz_ctrl <= 1'b1;
            if ((trap_valid_o === 1'b1) && $isunknown(trap_cause_o))
                o_xz_ctrl <= 1'b1;
            for (k = 0; k < NINS; k = k + 1) begin
                for (ci = 0; ci < 4; ci = ci + 1) begin
                    if ((m_cv[ci] === 1'b1) &&
                        (commit_pc_o[ci*32 +: 32] === (BASE + 4*k))) begin
                        o_cmt[k]  <= 1'b1;
                        o_we[k]   <= commit_arch_we_o[ci];
                        o_rd[k]   <= commit_arch_rd_o[ci*5 +: 5];
                        o_data[k] <= commit_arch_rd_wdata_o[ci*32 +: 32];
                    end
                    if ((m_cv[ci] === 1'b1) &&
                        ($isunknown(commit_arch_we_o[ci]) ||
                         $isunknown(commit_arch_rd_o[ci*5 +: 5]) ||
                         $isunknown(commit_arch_rd_wdata_o[ci*32 +: 32])))
                        o_xz_ctrl <= 1'b1;
                end
            end
            if ((trap_valid_o === 1'b1) && (trap_cause_o === `BACK2_EXC_ILLEGAL))
                o_trap2 <= 1'b1;
            if (m_csr_we    === 1'b1) o_csr   <= 1'b1;
            if (xret_cmt_o  === 1'b1) o_xret  <= 1'b1;
            if (maint_cmt_o === 1'b1) o_maint <= 1'b1;
            // FP PRF 写口：端口 1 = FPU（算术/转换/搬运，64 位数据在 [127:64]），
            //            端口 0 = LSU（FLW，64 位数据在 [63:0]，低 32 位即装载字）
            if (m_fprf_we[1] === 1'b1) begin
                o_fprf_wr <= 1'b1;
                if ($isunknown(u_dut.fprf_wd[127:64])) o_xz_ctrl <= 1'b1;
                if (u_dut.fprf_wd[95:64] === e_fprf_data) o_fprf_hit <= 1'b1;
            end
            if (m_fprf_we[0] === 1'b1) begin
                o_fprf_wr <= 1'b1;
                if ($isunknown(u_dut.fprf_wd[63:0])) o_xz_ctrl <= 1'b1;
                if (u_dut.fprf_wd[31:0] === e_fprf_data) o_fprf_hit <= 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 驱动：单 lane 块（每条指令独立块 ⇒ 严格程序序；跨块依赖走真实重命名/IQ）
    //--------------------------------------------------------------------------
    reg [31:0] pcv;

    task automatic drive_one(input integer idx);
        begin
            // 等 D1 空（上一块已派发），再锁存本块
            while (u_dut.d1_v_q !== 4'b0000) @(posedge clk);
            pcv           = BASE + 4*idx;
            blk_mask      = 4'b0001;
            blk_next_pc   = BASE + 4*idx + 4;
            lane_pc       = {96'b0, pcv};
            lane_insn     = {96'b0, prog[idx]};
            lane_len32    = 4'b0001;
            blk_valid     = 1'b1;
            @(posedge clk);
            // 锁存后读 D1 打包 uop（只读观测：目的写使能 / 非法位）。
            // `#1` 让本拍的非阻塞锁存更新（NBA 区）先落地，避免读到锁存前的旧值。
            #1;
            o_df[idx]    = u_dut.d1_uop_q[0][`BACK2_U_FLAGS_LSB + `BACK2_FL_RD_F_WEN];
            o_dint[idx]  = u_dut.d1_uop_q[0][`BACK2_U_FLAGS_LSB + `BACK2_FL_RD_I_WEN];
            o_illeg[idx] = u_dut.d1_uop_q[0][`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_ILLEGAL];
            // D1 观测替身出现 X/Z —— **只判本 TB 实际观测的字段**（目的写使能/非法/is_fp/
            // is_fpls/架构目的号/异常码）；不要求无关/未使用载荷位全为零。
            if (isx1(o_df[idx]) || isx1(o_dint[idx]) || isx1(o_illeg[idx]) ||
                isx1(u_dut.d1_uop_q[0][`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_FP]) ||
                isx1(u_dut.d1_uop_q[0][`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_FPLS]) ||
                $isunknown(u_dut.d1_uop_q[0][`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB]) ||
                $isunknown(u_dut.d1_uop_q[0][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB]))
                o_xz_init = 1'b1;
            blk_valid = 1'b0;
        end
    endtask

    integer verdict;   // 0=OK 1=DEFECT_SIG 2=UNEXPECTED 3=XZ
    reg spec_ok, defect_ok, xz_seen;
    reg bad_case;      // 未知/缺号 CASE ⇒ 必须判失败（缺例不可静默通过）

    initial begin
        // 默认值
        case_i = -1; cname = "UNSET"; is_trigger = 1'b0; n_insn = 0; case_priv = 2'b11;
        bad_case = 1'b0;
        e_trap2 = 0; e_csr = 0; e_xret = 0; e_maint = 0;
        d_trap2 = 0; d_csr = 0; d_xret = 0; d_maint = 0;
        e_fprf_v = 0; e_fprf_data = 32'h0;
        for (ci = 0; ci < NINS; ci = ci + 1) begin
            prog[ci] = 32'h0; e_cmt[ci]=0; e_we[ci]=0; e_rd[ci]=0; e_data[ci]=0;
            e_dv[ci]=0; e_dfv[ci]=0; e_df[ci]=0;
            d_cmt[ci]=0; d_we[ci]=0; d_rd[ci]=0; d_data[ci]=0;
            d_dv[ci]=0; d_dfv[ci]=0; d_df[ci]=0;
            o_cmt[ci]=0; o_we[ci]=0; o_rd[ci]=0; o_data[ci]=0;
            o_df[ci]=0; o_dint[ci]=0; o_illeg[ci]=0;
        end
        o_trap2=0; o_csr=0; o_xret=0; o_maint=0; o_fprf_wr=0; o_fprf_hit=0;
        mon_en=1'b0; o_xz_ctrl=1'b0; o_xz_init=1'b0; xinj=0;

        if (!$value$plusargs("CASE=%d", case_i)) case_i = -1;
        if (!$value$plusargs("XINJ=%d", xinj)) xinj = 0;

        //======================================================================
        // 固定向量表（每例：指令 + 规范期望 + 已知旧缺陷签名）
        //   指令编码为固定常量；FP 数据 1.5/2.25/3.75 均有限非零（非 NaN）
        //======================================================================
        case (case_i)
        // ---- B 组：特权入口权限（01 P0-01 / 02-4）----
        0: begin cname="M_ILLEGAL_POSCTL"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h0000_0000;              // 全零编码 ⇒ 非法指令
                 e_trap2=1; e_csr=0; e_xret=0; d_trap2=1; end
        1: begin cname="U_CSRRW_MSTATUS"; is_trigger=1; n_insn=1; case_priv=2'b00;
                 prog[0]=32'h3000_10F3;              // csrrw x1,mstatus,x0
                 e_cmt[0]=0; e_trap2=1; e_csr=0; e_xret=0;
                 d_cmt[0]=1; d_we[0]=1; d_rd[0]=5'd1; d_data[0]=CSR_RDATA; d_dv[0]=1;
                 d_trap2=0; d_csr=1; d_xret=0; end
        2: begin cname="S_CSRRW_MSTATUS"; is_trigger=1; n_insn=1; case_priv=2'b01;
                 prog[0]=32'h3000_10F3;
                 e_cmt[0]=0; e_trap2=1; e_csr=0; e_xret=0;
                 d_cmt[0]=1; d_we[0]=1; d_rd[0]=5'd1; d_data[0]=CSR_RDATA; d_dv[0]=1;
                 d_trap2=0; d_csr=1; d_xret=0; end
        3: begin cname="M_CSRRW_MSTATUS"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h3000_10F3;
                 e_cmt[0]=1; e_we[0]=1; e_rd[0]=5'd1; e_data[0]=CSR_RDATA; e_dv[0]=1;
                 e_trap2=0; e_csr=1; e_xret=0; d_cmt[0]=1; d_we[0]=1; d_rd[0]=5'd1;
                 d_data[0]=CSR_RDATA; d_dv[0]=1; end
        4: begin cname="U_MRET"; is_trigger=1; n_insn=1; case_priv=2'b00;
                 prog[0]=32'h3020_0073;
                 e_cmt[0]=0; e_trap2=1; e_csr=0; e_xret=0;
                 d_cmt[0]=1; d_we[0]=0; d_trap2=0; d_csr=0; d_xret=1; end
        5: begin cname="M_MRET"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h3020_0073;
                 e_cmt[0]=1; e_we[0]=0; e_trap2=0; e_csr=0; e_xret=1;
                 d_cmt[0]=1; d_we[0]=0; d_xret=1; end
        6: begin cname="S_SRET"; is_trigger=0; n_insn=1; case_priv=2'b01;
                 prog[0]=32'h1020_0073;
                 e_cmt[0]=1; e_we[0]=0; e_trap2=0; e_csr=0; e_xret=1;
                 d_cmt[0]=1; d_we[0]=0; d_xret=1; end
        7: begin cname="U_SRET"; is_trigger=1; n_insn=1; case_priv=2'b00;
                 prog[0]=32'h1020_0073;
                 e_cmt[0]=0; e_trap2=1; e_csr=0; e_xret=0;
                 d_cmt[0]=1; d_we[0]=0; d_trap2=0; d_xret=1; end
        8: begin cname="M_SRET"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h1020_0073;
                 e_cmt[0]=1; e_we[0]=0; e_trap2=0; e_xret=1;
                 d_cmt[0]=1; d_we[0]=0; d_xret=1; end
        9: begin cname="U_SFENCE"; is_trigger=1; n_insn=1; case_priv=2'b00;
                 prog[0]=32'h1200_0073;
                 e_cmt[0]=0; e_trap2=1; e_csr=0; e_xret=0; e_maint=0;
                 d_cmt[0]=1; d_we[0]=0; d_trap2=0; d_maint=1; end
        10:begin cname="S_SFENCE"; is_trigger=0; n_insn=1; case_priv=2'b01;
                 prog[0]=32'h1200_0073;
                 e_cmt[0]=1; e_we[0]=0; e_trap2=0; e_maint=1;
                 d_cmt[0]=1; d_we[0]=0; d_maint=1; end
        11:begin cname="M_SFENCE"; is_trigger=0; n_insn=1; case_priv=2'b11;
                 prog[0]=32'h1200_0073;
                 e_cmt[0]=1; e_we[0]=0; e_trap2=0; e_maint=1;
                 d_cmt[0]=1; d_we[0]=0; d_maint=1; end
        // ---- A 组：FP 目的 f0 写后读（02-1）----
        12:begin cname="FLW_F0_READ"; is_trigger=1; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h0000_A007;              // flw f0,0(x1)
                 prog[1]=32'hE000_01D3;              // fmv.x.w x3,f0
                 e_cmt[0]=1; e_we[0]=1; e_rd[0]=5'd0; e_data[0]=32'h3FC0_0000; e_dv[0]=1;
                 e_dfv[0]=1; e_df[0]=1;
                 e_cmt[1]=1; e_we[1]=1; e_rd[1]=5'd3; e_data[1]=32'h3FC0_0000; e_dv[1]=1;
                 e_fprf_v=1; e_fprf_data=32'h3FC0_0000;
                 d_cmt[0]=1; d_we[0]=0; d_rd[0]=5'd0; d_dfv[0]=1; d_df[0]=0;
                 d_cmt[1]=1; d_we[1]=1; d_rd[1]=5'd3; d_data[1]=32'h0000_0000; d_dv[1]=1; end
        13:begin cname="FLW_F1_READ"; is_trigger=0; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h0000_A087;              // flw f1,0(x1)
                 prog[1]=32'hE000_81D3;              // fmv.x.w x3,f1
                 e_cmt[0]=1; e_we[0]=1; e_rd[0]=5'd1; e_data[0]=32'h3FC0_0000; e_dv[0]=1;
                 e_dfv[0]=1; e_df[0]=1;
                 e_cmt[1]=1; e_we[1]=1; e_rd[1]=5'd3; e_data[1]=32'h3FC0_0000; e_dv[1]=1;
                 e_fprf_v=1; e_fprf_data=32'h3FC0_0000;
                 d_cmt[0]=1; d_we[0]=1; d_rd[0]=5'd1; d_data[0]=32'h3FC0_0000; d_dv[0]=1;
                 d_cmt[1]=1; d_we[1]=1; d_rd[1]=5'd3; d_data[1]=32'h3FC0_0000; d_dv[1]=1; end
        14:begin cname="FADD_F0_READ"; is_trigger=1; n_insn=4; case_priv=2'b11;
                 prog[0]=32'h0000_A087;              // flw f1,0(x1) = 1.5
                 prog[1]=32'h0040_A107;              // flw f2,4(x1) = 2.25
                 prog[2]=32'h0020_F053;              // fadd.s f0,f1,f2 = 3.75 (rm=dyn;frm=0)
                 prog[3]=32'hE000_0253;              // fmv.x.w x4,f0
                 e_cmt[0]=1; e_we[0]=1; e_rd[0]=5'd1; e_data[0]=32'h3FC0_0000; e_dv[0]=1;
                 e_cmt[1]=1; e_we[1]=1; e_rd[1]=5'd2; e_data[1]=32'h4010_0000; e_dv[1]=1;
                 e_cmt[2]=1; e_we[2]=1; e_rd[2]=5'd0; e_data[2]=32'h4070_0000; e_dv[2]=1;
                 e_dfv[2]=1; e_df[2]=1;
                 e_cmt[3]=1; e_we[3]=1; e_rd[3]=5'd4; e_data[3]=32'h4070_0000; e_dv[3]=1;
                 e_fprf_v=1; e_fprf_data=32'h4070_0000;
                 d_cmt[0]=1; d_we[0]=1; d_rd[0]=5'd1; d_data[0]=32'h3FC0_0000; d_dv[0]=1;
                 d_cmt[1]=1; d_we[1]=1; d_rd[1]=5'd2; d_data[1]=32'h4010_0000; d_dv[1]=1;
                 d_cmt[2]=1; d_we[2]=0; d_rd[2]=5'd0; d_dfv[2]=1; d_df[2]=0;
                 d_cmt[3]=1; d_we[3]=1; d_rd[3]=5'd4; d_data[3]=32'h0000_0000; d_dv[3]=1; end
        15:begin cname="FADD_F1_READ"; is_trigger=0; n_insn=4; case_priv=2'b11;
                 prog[0]=32'h0000_A087;              // flw f1,0(x1)
                 prog[1]=32'h0040_A107;              // flw f2,4(x1)
                 prog[2]=32'h0020_F0D3;              // fadd.s f1,f1,f2 = 3.75
                 prog[3]=32'hE000_8253;              // fmv.x.w x4,f1
                 e_cmt[0]=1; e_we[0]=1; e_rd[0]=5'd1; e_data[0]=32'h3FC0_0000; e_dv[0]=1;
                 e_cmt[1]=1; e_we[1]=1; e_rd[1]=5'd2; e_data[1]=32'h4010_0000; e_dv[1]=1;
                 e_cmt[2]=1; e_we[2]=1; e_rd[2]=5'd1; e_data[2]=32'h4070_0000; e_dv[2]=1;
                 e_cmt[3]=1; e_we[3]=1; e_rd[3]=5'd4; e_data[3]=32'h4070_0000; e_dv[3]=1;
                 e_fprf_v=1; e_fprf_data=32'h4070_0000;
                 d_cmt[2]=1; d_we[2]=1; d_rd[2]=5'd1; d_data[2]=32'h4070_0000; d_dv[2]=1;
                 d_cmt[3]=1; d_we[3]=1; d_rd[3]=5'd4; d_data[3]=32'h4070_0000; d_dv[3]=1; end
        // ---- 整数目的 x0 硬零（正/负控）----
        16:begin cname="INT_X0_ADDI"; is_trigger=0; n_insn=2; case_priv=2'b11;
                 prog[0]=32'h0050_0013;              // addi x0,x0,5
                 prog[1]=32'h0000_02B3;              // add x5,x0,x0 => 0
                 e_cmt[0]=1; e_we[0]=0; e_rd[0]=5'd0;
                 e_cmt[1]=1; e_we[1]=1; e_rd[1]=5'd5; e_data[1]=32'h0; e_dv[1]=1;
                 d_cmt[0]=1; d_we[0]=0; d_rd[0]=5'd0;
                 d_cmt[1]=1; d_we[1]=1; d_rd[1]=5'd5; d_data[1]=32'h0; d_dv[1]=1; end
        17:begin cname="INT_X0_FMV"; is_trigger=0; n_insn=3; case_priv=2'b11;
                 prog[0]=32'h0000_A087;              // flw f1,0(x1) = 1.5（用 f1，隔离出"整数 x0"语义）
                 prog[1]=32'hE000_8053;              // fmv.x.w x0,f1（整数目的 x0 不得写）
                 prog[2]=32'h0000_02B3;              // add x5,x0,x0 => 0
                 e_cmt[0]=1; e_we[0]=1; e_rd[0]=5'd1; e_data[0]=32'h3FC0_0000; e_dv[0]=1;
                 e_cmt[1]=1; e_we[1]=0; e_rd[1]=5'd0;
                 e_cmt[2]=1; e_we[2]=1; e_rd[2]=5'd5; e_data[2]=32'h0; e_dv[2]=1;
                 d_cmt[0]=1; d_we[0]=1; d_rd[0]=5'd1; d_data[0]=32'h3FC0_0000; d_dv[0]=1;
                 d_cmt[1]=1; d_we[1]=0; d_rd[1]=5'd0;
                 d_cmt[2]=1; d_we[2]=1; d_rd[2]=5'd5; d_data[2]=32'h0; d_dv[2]=1; end
        default: begin cname="BAD_CASE"; is_trigger=0; n_insn=0; bad_case=1'b1; end
        endcase

        //======================================================================
        // 初始化、复位、按程序序逐条派发、等待提交/陷阱
        //======================================================================
        blk_valid = 0; blk_mask = 4'b0001; blk_next_pc = BASE; blk_taken = 0;
        lane_pc = 0; lane_pa = 0; lane_insn = 0; lane_len32 = 4'b0001; lane_cls = 0;
        lane_pred_taken=0; lane_pred_selg=0; lane_pred_gdir=0; lane_pred_ldir=0;
        lane_pred_target=0; lane_btb_hit=0; lane_btb_way=0; lane_btb_cond=0;
        lane_btb_call=0; lane_btb_ret=0; lane_btb_target=0;
        lane_fault=0; lane_fault_cause=0; lane_fault_tval=0;
        lane_ckpt=0; lane_ckpt_valid=0; fe_fetch_fault=0;
        train_ready=1; mem_req_ready=1; mem_rsp_err=0;
        st_xlate_en=0; st_xlate_ctx=0; st_xlate_ready=1; st_xlate_done=0;
        st_xlate_pa=0; st_xlate_fault=0;
        trp_flush_v=0; trp_redirect_v=0; trp_redirect_pc=0;
        csr_rdata=CSR_RDATA; csr_frm=0; csr_fflags=0;
        maint_rdy=1; cbo_perm=2'b00;
        priv = case_priv;

        for (mi = 0; mi < 256; mi = mi + 1) lmem[mi] = 32'h0;
        lmem[0] = 32'h3FC0_0000;   // 1.5f
        lmem[1] = 32'h4010_0000;   // 2.25f

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 有效观察窗口：从开始驱动到判定期前（时钟块在此窗口实时判控制线 X/Z）
        mon_en = 1'b1;
        for (cj = 0; cj < n_insn; cj = cj + 1) drive_one(cj);

        repeat (500) @(posedge clk);
        mon_en = 1'b0;
        #1;   // 让最后一批非阻塞观测落地

        //======================================================================
        // 判定
        //======================================================================
        spec_ok = 1'b1; defect_ok = 1'b1; xz_seen = 1'b0;
        if (o_xz_ctrl || o_xz_init) xz_seen = 1'b1;   // 窗口内控制/有效线或 D1 替身出现 X/Z
        for (ci = 0; ci < NINS; ci = ci + 1) begin
            if (isx1(o_cmt[ci]) || isx1(o_we[ci]) || isx1(o_df[ci]) ||
                isx1(o_dint[ci]) || isx1(o_illeg[ci]) ||
                $isunknown(o_rd[ci]) || $isunknown(o_data[ci])) xz_seen = 1'b1;
            if (e_cmt[ci] !== o_cmt[ci]) spec_ok = 1'b0;
            if (e_cmt[ci]) begin
                if (e_we[ci] !== o_we[ci]) spec_ok = 1'b0;
                if (e_we[ci] && (e_rd[ci] !== o_rd[ci])) spec_ok = 1'b0;
                if (e_dv[ci] && (e_data[ci] !== o_data[ci])) spec_ok = 1'b0;
            end
            if (e_dfv[ci] && (e_df[ci] !== o_df[ci])) spec_ok = 1'b0;

            if (d_cmt[ci] !== o_cmt[ci]) defect_ok = 1'b0;
            if (d_cmt[ci]) begin
                if (d_we[ci] !== o_we[ci]) defect_ok = 1'b0;
                if (d_we[ci] && (d_rd[ci] !== o_rd[ci])) defect_ok = 1'b0;
                if (d_dv[ci] && (d_data[ci] !== o_data[ci])) defect_ok = 1'b0;
            end
            if (d_dfv[ci] && (d_df[ci] !== o_df[ci])) defect_ok = 1'b0;
        end
        if (isx1(o_trap2) || isx1(o_csr) || isx1(o_xret) || isx1(o_maint) ||
            isx1(o_fprf_wr) || isx1(o_fprf_hit)) xz_seen = 1'b1;
        if (e_trap2 !== o_trap2) spec_ok = 1'b0;
        if (e_csr   !== o_csr)   spec_ok = 1'b0;
        if (e_xret  !== o_xret)  spec_ok = 1'b0;
        if (e_maint !== o_maint) spec_ok = 1'b0;
        if (e_fprf_v && (o_fprf_hit !== 1'b1)) spec_ok = 1'b0;

        if (d_trap2 !== o_trap2) defect_ok = 1'b0;
        if (d_csr   !== o_csr)   defect_ok = 1'b0;
        if (d_xret  !== o_xret)  defect_ok = 1'b0;
        if (d_maint !== o_maint) defect_ok = 1'b0;

        if (bad_case)                      verdict = 2;
        else if (xz_seen)                  verdict = 3;
        else if (spec_ok)                  verdict = 0;
        else if (is_trigger && defect_ok)  verdict = 1;
        else                               verdict = 2;

        // ---- 报告（固定格式；脚本按 VERDICT 判定）----
        $display("CASE %0d %0s KIND=%0s priv=%b", case_i, cname,
                 is_trigger ? "trigger" : "control", case_priv);
        for (ci = 0; ci < n_insn; ci = ci + 1)
            $display("CASE %0d %0s INS %0d insn=0x%08x cmt=%b we=%b rd=%0d wdata=0x%08x dst_fp=%b dst_int=%b illegal=%b",
                     case_i, cname, ci, prog[ci], o_cmt[ci], o_we[ci], o_rd[ci],
                     o_data[ci], o_df[ci], o_dint[ci], o_illeg[ci]);
        $display("CASE %0d %0s OBS trap2=%b csr_we=%b xret=%b maint=%b fprf_wr=%b fprf_hit=%b spec_ok=%b defect_ok=%b xz_ctrl=%b xz_init=%b xinj=%0d",
                 case_i, cname, o_trap2, o_csr, o_xret, o_maint,
                 o_fprf_wr, o_fprf_hit, spec_ok, defect_ok,
                 o_xz_ctrl, o_xz_init, xinj);
        case (verdict)
            0: $display("CASE %0d %0s VERDICT=OK", case_i, cname);
            1: $display("CASE %0d %0s VERDICT=DEFECT_SIG", case_i, cname);
            2: $display("CASE %0d %0s VERDICT=UNEXPECTED", case_i, cname);
            default: $display("CASE %0d %0s VERDICT=XZ", case_i, cname);
        endcase
        $finish;
    end

    // 墙钟兜底：驱动卡死时结束仿真且**不打印 VERDICT**（脚本按缺锚点失败）
    initial begin
        #2_000_000;
        $display("CASE %0d %0s WATCHDOG_END", case_i, cname);
        $finish;
    end

endmodule
