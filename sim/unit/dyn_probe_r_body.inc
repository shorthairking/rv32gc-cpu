//==============================================================================
// sim/unit/dyn_probe_r_body.inc —— 容量探针公共体（供 dyn_probe_r_lockstep / _ipc / _core_top 复用）
//------------------------------------------------------------------------------
// 前提：被 include 的模块里已有
//   · `tb_back2_lockstep_top u_tb ();` / `tb_back2_ipc u_tb ();` / `tb_core_top_2b u_tb ();`
//   · `wire [31:0] dyn_bench;`
//   · `define DYN_FNAME "<输出 CSV 相对路径>"`
//   · `define DYN_BK    <backend_top 实例的层次名>`
// 本文件只做**只读层次引用**与 `dyn_probe_r_core` 例化；**不改任何产品 RTL**。
//
// 纪律：所有读 IW 载荷（`x_i2_uop`）的字段一律先用对应的 valid 门控再输出 —— 未发射队列的
//       BRAM 读回数据可能为 x，直接写盘会让分析器（fail-closed）误判 FAIL。
//==============================================================================

    localparam integer NREG_I = `BACK2_PRF_I_N;   // 96
    localparam integer NREG_F = `BACK2_PRF_F_N;   // 64

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    //--------------------------------------------------------------------------
    // popcount（16 项常量下标拼接 ⇒ 不依赖工具对"数组变量下标层次引用"的支持）
    //--------------------------------------------------------------------------
    function [5:0] pcnt32;
        input [31:0] v;
        integer p;
        begin
            pcnt32 = 6'd0;
            for (p = 0; p < 32; p = p + 1) pcnt32 = pcnt32 + {5'b0, v[p]};
        end
    endfunction

    function [4:0] pcnt16;
        input [15:0] v;
        integer p;
        begin
            pcnt16 = 5'd0;
            for (p = 0; p < 16; p = p + 1) pcnt16 = pcnt16 + {4'b0, v[p]};
        end
    endfunction

    //--------------------------------------------------------------------------
    // 组 R：rename / 检查点 / 回滚
    //--------------------------------------------------------------------------
    wire [7:0]  freei = `DYN_BK.free_i_cnt;      // rename.v:320/322（free_cnt_w）
    wire [7:0]  freef = `DYN_BK.free_f_cnt;
    wire [31:0] nreg_i_w = NREG_I;
    wire [31:0] nreg_f_w = NREG_F;
    wire [8:0]  livei9 = nreg_i_w[8:0] - {1'b0, freei};
    wire [8:0]  livef9 = nreg_f_w[8:0] - {1'b0, freef};
    wire [7:0]  livei = livei9[7:0];
    wire [7:0]  livef = livef9[7:0];

    wire [15:0] ck_i_v = {`DYN_BK.u_ren_i.ck_val[15], `DYN_BK.u_ren_i.ck_val[14],
                          `DYN_BK.u_ren_i.ck_val[13], `DYN_BK.u_ren_i.ck_val[12],
                          `DYN_BK.u_ren_i.ck_val[11], `DYN_BK.u_ren_i.ck_val[10],
                          `DYN_BK.u_ren_i.ck_val[9],  `DYN_BK.u_ren_i.ck_val[8],
                          `DYN_BK.u_ren_i.ck_val[7],  `DYN_BK.u_ren_i.ck_val[6],
                          `DYN_BK.u_ren_i.ck_val[5],  `DYN_BK.u_ren_i.ck_val[4],
                          `DYN_BK.u_ren_i.ck_val[3],  `DYN_BK.u_ren_i.ck_val[2],
                          `DYN_BK.u_ren_i.ck_val[1],  `DYN_BK.u_ren_i.ck_val[0]};
    wire [15:0] ck_f_v = {`DYN_BK.u_ren_f.ck_val[15], `DYN_BK.u_ren_f.ck_val[14],
                          `DYN_BK.u_ren_f.ck_val[13], `DYN_BK.u_ren_f.ck_val[12],
                          `DYN_BK.u_ren_f.ck_val[11], `DYN_BK.u_ren_f.ck_val[10],
                          `DYN_BK.u_ren_f.ck_val[9],  `DYN_BK.u_ren_f.ck_val[8],
                          `DYN_BK.u_ren_f.ck_val[7],  `DYN_BK.u_ren_f.ck_val[6],
                          `DYN_BK.u_ren_f.ck_val[5],  `DYN_BK.u_ren_f.ck_val[4],
                          `DYN_BK.u_ren_f.ck_val[3],  `DYN_BK.u_ren_f.ck_val[2],
                          `DYN_BK.u_ren_f.ck_val[1],  `DYN_BK.u_ren_f.ck_val[0]};
    wire [4:0] cki    = pcnt16(ck_i_v);
    wire [4:0] ckf    = pcnt16(ck_f_v);
    wire [4:0] ckpend = pcnt16(`DYN_BK.ck_pend_q);
    wire [3:0] ckbusy = `DYN_BK.ck_busy_q;      // ★ 只声明了 4 bit（backend_top.v:630）

    wire       snapv  = `DYN_BK.snap_v_w;
    wire [3:0] snapid = snapv ? `DYN_BK.snap_id_w : 4'd0;
    wire       squash   = `DYN_BK.squash_v_w;
    wire       flushall = `DYN_BK.flush_all_w;
    wire       rstck    = `DYN_BK.restore_ck_v_w;
    wire       rstrob   = `DYN_BK.restore_rob_v_w;
    wire       undo     = `DYN_BK.u_ren_i.undo_act;
    //   `squash_age_w` 在**无回滚拍**上可能取 x（`x_i2_rob[2]` 未发射时为 x）⇒ 按 squash 门控；
    //   分析器只在 squash==1 的拍上使用 age（那拍 x_i2_v[2]==1 ⇒ 索引必然有效）。
    wire [5:0] age      = squash ? `DYN_BK.squash_age_w : 6'd0;
    wire [7:0] rob      = `DYN_BK.rob_cnt_w;
    wire [5:0] robhead  = `DYN_BK.rob_head_w[5:0];
    wire [5:0] rbidx    = rstrob ? `DYN_BK.restore_rob_idx_w : 6'd0;
    //   rename free list **重建期**（flush 后的 flush_all 重建 FSM）⇒ free_cnt 是已知过渡态，
    //   该拍的 live 数无意义（rename.v:598-610 自检对此豁免）。分析器据此排除该拍。
    wire [1:0] rbact    = {`DYN_BK.u_ren_i.rb_act, `DYN_BK.u_ren_f.rb_act};

    //--------------------------------------------------------------------------
    // 组 T：TRQ
    //--------------------------------------------------------------------------
    wire [4:0] trqcnt  = `DYN_BK.trq_cnt;       // backend_top.v:2288
    wire [4:0] trqw    = `DYN_BK.trq_w;         // backend_top.v:2287
    wire [4:0] trqr    = `DYN_BK.trq_r;
    wire [1:0] trqacc  = `DYN_BK.trq_acc;       // backend_top.v:2292
    wire       trqfull = `DYN_BK.trq_full;      // backend_top.v:2289
    wire       trqfire = `DYN_BK.train_valid_o & `DYN_BK.train_ready_i;   // backend_top.v:2331
    //   ★ 决定性证据列：`train_pc_o = trq[trq_r][31:0]`（backend_top.v:2332）而 `trq` 只有
    //     TRQ_D=16 项（:2286）却用 **5 bit 指针**索引（mod 32，:2287）⇒ trq_r≥16 时读越界，
    //     iverilog 返回 x。本列 = "本拍训练条目出队且 FIFO 读出口含未捕获位"（0/1，永不 x）。
    wire       tpcx    = trqfire & ((^`DYN_BK.train_pc_o) === 1'bx);

    //--------------------------------------------------------------------------
    // 组 L：LSQ（u_back.u_lsu）
    //--------------------------------------------------------------------------
    wire [15:0] ld_v_v = {`DYN_BK.u_lsu.ld_v[15], `DYN_BK.u_lsu.ld_v[14],
                          `DYN_BK.u_lsu.ld_v[13], `DYN_BK.u_lsu.ld_v[12],
                          `DYN_BK.u_lsu.ld_v[11], `DYN_BK.u_lsu.ld_v[10],
                          `DYN_BK.u_lsu.ld_v[9],  `DYN_BK.u_lsu.ld_v[8],
                          `DYN_BK.u_lsu.ld_v[7],  `DYN_BK.u_lsu.ld_v[6],
                          `DYN_BK.u_lsu.ld_v[5],  `DYN_BK.u_lsu.ld_v[4],
                          `DYN_BK.u_lsu.ld_v[3],  `DYN_BK.u_lsu.ld_v[2],
                          `DYN_BK.u_lsu.ld_v[1],  `DYN_BK.u_lsu.ld_v[0]};
    wire [5:0] stqcnt  = `DYN_BK.u_lsu.stq_used;             // lsq_simple.v:313
    wire [4:0] lqcnt   = pcnt16(ld_v_v);                     // lsq_simple.v:565
    wire       stv     = `DYN_BK.u_lsu.exe_valid & `DYN_BK.u_lsu.exe_is_store;
    wire       ldv     = `DYN_BK.u_lsu.exe_valid & ~`DYN_BK.u_lsu.exe_is_store;
    wire [7:0] fwdhit  = ldv ? `DYN_BK.u_lsu.fwd_hit_w : 8'd0;   // lsq_simple.v:460/553
    wire       fwdall  = ldv ? `DYN_BK.u_lsu.fwd_all_w : 1'b0;   // lsq_simple.v:548
    wire [3:0] stmask  = stv ? `DYN_BK.u_lsu.lmask_w : 4'd0;     // lsq_simple.v:404
    wire [2:0] stsize  = stv ? `DYN_BK.u_lsu.exe_size : 3'd0;    // lsq_simple.v:85
    //   独立交叉核对：直接数 STQ 的 valid 位（stq_v32，lsq_simple.v:286-290），
    //   与设计自算的 stq_used（:313）比对 —— 两者必须逐拍相等。
    wire [5:0] stqv    = pcnt32(`DYN_BK.u_lsu.stq_v32);

    //--------------------------------------------------------------------------
    // 组 F：FPU（u_back.u_fpu）
    //--------------------------------------------------------------------------
    wire       freq    = `DYN_BK.x_i2_v[5];                                  // backend_top.v:1575
    wire [6:0] fpop    = freq ? {1'b0, `DYN_BK.x_i2_uop[5][`BACK2_IW_FPOP_MSB:`BACK2_IW_FPOP_LSB]}
                              : 7'd0;                                        // backend_top.v:312/1366
    wire       fifv    = `DYN_BK.fpu_if_v;                                   // backend_top.v:462
    wire       fdsbusy = `DYN_BK.u_fpu.ds_busy;                              // fpu.v:260
    wire       fbusy   = `DYN_BK.u_fpu.busy;                                 // fpu.v:486
    wire       fdone   = `DYN_BK.fpu_done;                                   // backend_top.v:1567

    //--------------------------------------------------------------------------
    // 前端检查点池（真源 predictor_top.v:179/189/221）—— 后端 ck_busy_q 只 4 bit
    // （backend_top.v:630 越界缺陷），故"活跃检查点"以前端池为准。
    //--------------------------------------------------------------------------
`ifdef DYN_NO_FE
    wire [4:0] feck   = 5'd0;      // 该基准无前端（tb_back2_ipc 直驱后端）
    wire       fefull = 1'b0;
`else
    wire [4:0] feck   = pcnt16(`DYN_FE.ck_valid_v);
    wire       fefull = `DYN_FE.ckpt_full;
`endif

    //--------------------------------------------------------------------------
    // 交叉验证：本拍提交条数（与既有 dyn 探针同口径）
    //--------------------------------------------------------------------------
    //   分支提交突发 = 本拍**已提交**的控制转移条数（rob.v:453 的 cmt_st_branch 再按
    //   backend_top.v:1796 的 commit_valid_o 门控；与 TRQ 入队判据 :2297 同源）
    wire [2:0] nbr = {2'b0, (`DYN_BK.cmt_st_branch[0] & `DYN_BK.commit_valid_o[0])}
                   + {2'b0, (`DYN_BK.cmt_st_branch[1] & `DYN_BK.commit_valid_o[1])}
                   + {2'b0, (`DYN_BK.cmt_st_branch[2] & `DYN_BK.commit_valid_o[2])}
                   + {2'b0, (`DYN_BK.cmt_st_branch[3] & `DYN_BK.commit_valid_o[3])};
    wire [2:0] ncmt = {2'b0, `DYN_BK.commit_valid_o[0]} + {2'b0, `DYN_BK.commit_valid_o[1]}
                    + {2'b0, `DYN_BK.commit_valid_o[2]} + {2'b0, `DYN_BK.commit_valid_o[3]};

    dyn_probe_r_core #(.FNAME(`DYN_FNAME)) u_probe_r (
        .clk(clk), .rst_n(rst_n), .bench(dyn_bench),
        .freei(freei), .freef(freef), .livei(livei), .livef(livef),
        .cki(cki), .ckf(ckf), .ckbusy(ckbusy), .ckpend(ckpend),
        .snapv(snapv), .snapid(snapid),
        .squash(squash), .flushall(flushall), .rstck(rstck), .rstrob(rstrob),
        .undo(undo), .age(age), .rob(rob), .robhead(robhead), .rbidx(rbidx),
        .rbact(rbact),
        .trqcnt(trqcnt), .trqw(trqw), .trqr(trqr), .trqacc(trqacc),
        .trqfull(trqfull), .trqfire(trqfire), .tpcx(tpcx), .nbr(nbr),
        .stqcnt(stqcnt), .lqcnt(lqcnt), .fwdhit(fwdhit), .fwdall(fwdall),
        .stmask(stmask), .stsize(stsize), .stv(stv), .ldv(ldv), .stqv(stqv),
        .fpop(fpop), .freq(freq), .fifv(fifv), .fdsbusy(fdsbusy),
        .fbusy(fbusy), .fdone(fdone), .feck(feck), .fefull(fefull),
        .ncmt(ncmt)
    );
