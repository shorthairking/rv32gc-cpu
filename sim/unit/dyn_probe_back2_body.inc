//==============================================================================
// sim/unit/dyn_probe_back2_body.inc —— 探针公共体（供 dyn_probe_lockstep / _ipc 复用）
//------------------------------------------------------------------------------
// 前提：被 include 的模块里已有
//   · `tb_back2_lockstep_top u_tb ();` 或 `tb_back2_ipc u_tb ();`（两者都有 u_back）
//   · `wire [31:0] dyn_bench;`（基准编号）
//   · `define DYN_FNAME "<输出 CSV 相对路径>"`
// 本文件只做**只读层次引用**与 `dyn_probe_core` 例化；不改产品 RTL。
//==============================================================================

    localparam integer NQ_W = `BACK2_NQ_W;
    localparam integer RB_W = `BACK2_RB_W;

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    //--------------------------------------------------------------------------
    // 组 1：IQ 行为
    //--------------------------------------------------------------------------
    //   iq_cnt[q] 是 iq.v 的 free_cnt（**剩余空位**），occupancy = depth − free
    wire [29:0] iq_free_p;
    assign iq_free_p[4:0]   = `DYN_BK.iq_cnt[0];
    assign iq_free_p[9:5]   = `DYN_BK.iq_cnt[1];
    assign iq_free_p[14:10] = `DYN_BK.iq_cnt[2];
    assign iq_free_p[19:15] = `DYN_BK.iq_cnt[3];
    assign iq_free_p[24:20] = `DYN_BK.iq_cnt[4];
    assign iq_free_p[29:25] = `DYN_BK.iq_cnt[5];

    wire [23:0] disp_p = `DYN_BK.iq_wv_g;   // 每队列 4 bit 写使能（已 & disp_fire_w）
    wire [5:0]  iss_p  = `DYN_BK.iq_iss_v;

    //   "valid & ready 但本拍未发射" = iq_sel_v[q] & ~iss_ready[q]
    //   iss_ready 真源：backend_top.v:1117/1130/1143/1156/1189/1202
    wire [5:0] blk_p;
    assign blk_p[0] = `DYN_BK.iq_sel_v[0] &  `DYN_BK.al0_csr_blk;
    assign blk_p[1] = 1'b0;
    assign blk_p[2] = 1'b0;
    assign blk_p[3] = `DYN_BK.iq_sel_v[3] & ~`DYN_BK.mdu_free_w;
    assign blk_p[4] = `DYN_BK.iq_sel_v[4] &  `DYN_BK.lsu_ld_block;
    assign blk_p[5] = `DYN_BK.iq_sel_v[5] & ~`DYN_BK.fpu_iss_ok_w;

    //--------------------------------------------------------------------------
    // 组 3：ROB 更新行为
    //--------------------------------------------------------------------------
    wire [7:0] rob_cnt = `DYN_BK.rob_cnt_w;
    wire       utr     = `DYN_BK.upd_tr_v;    // BRU 分支目标/方向回写
    wire       uff     = `DYN_BK.upd_ff_v;    // FPU fflags 回写
    wire       uexc    = `DYN_BK.lsu_exc_v;   // LSU 精确异常回写
    wire       ucsr    = 1'b0;                    // backend_top.v:1793 硬接 1'b0（死口）
    wire       trap    = `DYN_BK.trap_valid_o;

    //--------------------------------------------------------------------------
    // 组 2：PRF 读需求（执行期 / 提交期 / CSR）
    //--------------------------------------------------------------------------
    reg [4:0] iread_r;
    reg [2:0] fread_r, cread_i_r, cread_f_r, ncmt_r, nbr_r, nfp_r, nexc_r;
    reg       csr_read_r, cread_csr_r;
    integer   cc;
    reg [NQ_W-1:0] pn;
    reg [RB_W-1:0] pp;

    always @(*) begin
        iread_r    = 5'd0;
        csr_read_r = 1'b0;

        //   整数执行期读端口 0..9 = ALU0/ALU1/BRU/MDU/LSU 的 {s1i,s2i}
        //   端口 10 = FPU 的 s1i（backend_top.v:1823-1833）
        for (cc = 0; cc < 5; cc = cc + 1) begin
            if (`DYN_BK.x_i2_v[cc]) begin
                iread_r = iread_r
                        + `DYN_BK.x_i2_uop[cc][`BACK2_UB_S1_I_USE]
                        + `DYN_BK.x_i2_uop[cc][`BACK2_UB_S2_I_USE];
                if (`DYN_BK.x_i2_uop[cc][`BACK2_UB_IS_CSR])
                    csr_read_r = csr_read_r
                               + `DYN_BK.x_i2_uop[cc][`BACK2_UB_S1_I_USE];
            end
        end
        if (`DYN_BK.x_i2_v[5])
            iread_r = iread_r + `DYN_BK.x_i2_uop[5][`BACK2_UB_S1_I_USE];

        //   浮点执行期读端口 0..2 = FPU 的 {s1f,s2f,s3f}；端口 3 = LSU 的 s2f
        fread_r = 3'd0;
        if (`DYN_BK.x_i2_v[5])
            fread_r = fread_r
                    + `DYN_BK.x_i2_uop[5][`BACK2_UB_S1_F_USE]
                    + `DYN_BK.x_i2_uop[5][`BACK2_UB_S2_F_USE]
                    + `DYN_BK.x_i2_uop[5][`BACK2_UB_S3_F_USE];
        if (`DYN_BK.x_i2_v[4])
            fread_r = fread_r + `DYN_BK.x_i2_uop[4][`BACK2_UB_S2_F_USE];

        //   提交期读：端口 11..14（整数）/ 4..7（浮点）；判据 = 提交 lane 的 rd_i/rd_f_wen
        //   提交条数与分支/FP/异常频率来自提交 lane 的载荷（cmt_pay 宽载荷 + cmt_narrow 窄表）
        cread_i_r = 3'd0;  cread_f_r = 3'd0;
        ncmt_r    = 3'd0;  nbr_r     = 3'd0;
        nfp_r     = 3'd0;  nexc_r    = 3'd0;
        for (cc = 0; cc < 4; cc = cc + 1) begin
            pn = `DYN_BK.cmt_narrow[cc*NQ_W +: NQ_W];
            pp = `DYN_BK.cmt_pay   [cc*RB_W +: RB_W];
            if (`DYN_BK.commit_valid_o[cc]) begin
                ncmt_r = ncmt_r + 3'd1;
                if (pn[`BACK2_NQ_DI]) cread_i_r = cread_i_r + 3'd1;
                if (pn[`BACK2_NQ_DF]) cread_f_r = cread_f_r + 3'd1;
                if (pp[`BACK2_UB_IS_BRANCH]) nbr_r = nbr_r + 3'd1;
                if (pp[`BACK2_UB_IS_FP])     nfp_r = nfp_r + 3'd1;
                if (pp[`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB] != 4'd0)
                    nexc_r = nexc_r + 3'd1;
            end
        end
        cread_csr_r = `DYN_BK.csr_cmt_we ? 1'b1 : 1'b0;
    end

    dyn_probe_core #(.FNAME(`DYN_FNAME)) u_probe (
        .clk(clk), .rst_n(rst_n), .bench(dyn_bench),
        .iq_free_p(iq_free_p), .disp_p(disp_p), .iss_p(iss_p), .blk_p(blk_p),
        .rob_cnt(rob_cnt), .utr(utr), .uff(uff), .uexc(uexc), .ucsr(ucsr),
        .iread(iread_r), .csrread(csr_read_r),
        .creadi(cread_i_r), .creadcsr(cread_csr_r),
        .fread(fread_r), .creadf(cread_f_r),
        .ncmt(ncmt_r), .nbr(nbr_r), .nfp(nfp_r), .nexc(nexc_r), .trap(trap)
    );
