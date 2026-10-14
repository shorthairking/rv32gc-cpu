//==============================================================================
// sim/unit/dyn_probe_n28_body.inc —— EXP-N28A 探针公共体（被 5 个 wrapper include）
//------------------------------------------------------------------------------
// 前提（wrapper 必须先定义）：
//   `N28_BK`    = backend_top 的层次路径（如 `u_tb.u_back`）
//   `N28_FNAME` = 输出 CSV 相对路径
//   `N28_BENCH` = 基准编号表达式（integer/wire）
//   `N28_CLK` / `N28_RST` / `N28_EN` = 时钟 / 低有效复位 / 采样使能
//
// 本文件只做**只读层次引用**（不改任何产品 RTL），逐拍打包 64 bit 观测向量。
//
// 位表（与 fpga/scratch/n28_analyze.py 的 `BIT` 表逐位同源；改这里必须同步那里）：
//   [6:0]   rob_cnt          rob.v `cnt_o`（占用项数 0..64）
//   [12:7]  rob_head         `head_o`（6 bit 有效，上 1 位恒 0）
//   [19:13] squash_idx       `squash_idx_o`（6 bit 有效；仅 squash 拍有意义）
//   [23:20] d1_v             D1 块内 4 lane 有效位
//   [26:24] d1_n             = popcount(d1_v)
//   [28:27] cmt_n            本拍提交条数（0..2）
//   [29]    rob_alloc_ready  rob.v 纯余量判据
//   [30]    disp_fire        backend_top `disp_fire_w`（本拍真派发）
//   [31]    all_other_ok     除 ROB 余量外**全部**派发门控同时成立（与 RTL 1023-1026 同式）
//   [32]    rob_full_stall   = (d1_v!=0) & all_other_ok & ~rob_alloc_ready（ROB 满专属停顿）
//   [33]    cmt_fire         = (cmt_n != 0)
//   [34]    flush_all_w      rob.v `flush_all`（全清：异常/中断退役）
//   [35]    squash_v_w       rob.v `squash_valid`（分支误预测回滚）
//   [36]    trap_v_rob       ROB 头异常请求（陷阱退役）
//   [37]    rn_i_busy        整数重命名忙
//   [38]    rn_f_busy        浮点重命名忙
//   [39]    iq_room_ok       全部 IQ 有余量
//   [40]    st_alloc_ok     STQ 可分配
//   [41]    ld_alloc_ok     LQ 可分配
//   [42]    csr_serial_w    CSR 串行化挡（含未提交 CSR 时的块）
//   [43]    free_i_ok       整数 PRF 空闲口够
//   [44]    free_f_ok       浮点 PRF 空闲口够
//   [45]    mdu_busy        整数乘除单元在飞（长延迟）
//   [46]    fpu_busy        浮点单元在飞（含 fdiv/fsqrt 多拍）
//   [47]    rob_empty       rob_cnt == 0
//   [63:48] 保留 0
//==============================================================================

    wire [63:0] n28_d;

    wire        n28_pending    = (`N28_BK.d1_v_q != {`BACK2_ALLOC_W{1'b0}});
    wire        n28_other_ok   = ~`N28_BK.rn_i_busy & ~`N28_BK.rn_f_busy &
                                 ~`N28_BK.squash_v_w & ~`N28_BK.flush_all_w &
                                 `N28_BK.free_i_ok & `N28_BK.free_f_ok &
                                 `N28_BK.iq_room_ok &
                                 `N28_BK.st_alloc_ok & `N28_BK.ld_alloc_ok &
                                 ~`N28_BK.csr_serial_w;
    wire        n28_ready      = `N28_BK.rob_alloc_ready;
    //   ROB **专属**停顿 = 有派发请求 & 其它门控全开 & ROB 余量不足
    wire        n28_stall      = n28_pending & n28_other_ok & ~n28_ready;

`ifdef N28_INJECT_D1N
    //   反证注入①：把 `d1_n`（派发块有效 lane 数）报成 `d1_n_w + 1`（其余位不动）。
    //   恒等式 I2（`d1_n == popcount(d1_v)`）必然违例 —— 且**与负载无关**（d1_v=0 时
    //   期望 0、报 1 也违例）⇒ 保证"注入必被检出"。不检出 ⇒ 判据不是死判据。
    assign n28_d[26:24] = `N28_BK.d1_n_w + 3'd1;
`else
    assign n28_d[26:24] = `N28_BK.d1_n_w;
`endif

    //   ⚠ 位宽/X 口径：backend_top 的 `rob_head_w` 声明 7 bit 但 rob 的 `head_o` 只有
    //     ROB_IDX_W=6 bit ⇒ 高位悬空；`squash_idx_w` 直接来自**未复位**的 `x_i2_rob[2]`
    //     ⇒ 首次分支发射之前恒为 X。故：head **只取低 6 bit**；squash_idx **仅在本拍
    //     真有 squash（`squash_v_w=1`，此时该寄存器已由 BRU 写入口径保证有效）时才采**，
    //     否则记 0。这不改任何被消费的数据（squash 拍的值原样保留），只去掉无意义 X。
    assign n28_d[6:0]   = `N28_BK.rob_cnt_w[6:0];
    assign n28_d[12:7]  = `N28_BK.rob_head_w[5:0];
    assign n28_d[19:13] = `N28_BK.squash_v_w ? {1'b0, `N28_BK.squash_idx_w[5:0]} : 7'd0;
    assign n28_d[23:20] = `N28_BK.d1_v_q;
    assign n28_d[28:27] = `N28_BK.cmt_n_w;
    assign n28_d[29]    = n28_ready;
    assign n28_d[30]    = `N28_BK.disp_fire_w;
    assign n28_d[31]    = n28_other_ok;
    assign n28_d[32]    = n28_stall;
    assign n28_d[33]    = (`N28_BK.cmt_n_w != 3'd0);
    assign n28_d[34]    = `N28_BK.flush_all_w;
    assign n28_d[35]    = `N28_BK.squash_v_w;
    assign n28_d[36]    = `N28_BK.trap_v_rob;
    assign n28_d[37]    = `N28_BK.rn_i_busy;
    assign n28_d[38]    = `N28_BK.rn_f_busy;
    assign n28_d[39]    = `N28_BK.iq_room_ok;
    assign n28_d[40]    = `N28_BK.st_alloc_ok;
    assign n28_d[41]    = `N28_BK.ld_alloc_ok;
    assign n28_d[42]    = `N28_BK.csr_serial_w;
    assign n28_d[43]    = `N28_BK.free_i_ok;
    assign n28_d[44]    = `N28_BK.free_f_ok;
    assign n28_d[45]    = `N28_BK.mdu_busy;
    assign n28_d[46]    = `N28_BK.fpu_busy;
    assign n28_d[47]    = (`N28_BK.rob_cnt_w == 8'd0);
    assign n28_d[63:48] = 16'h0;

    n28_rob_probe #(.FNAME(`N28_FNAME)) u_n28_probe (
        .clk(`N28_CLK), .rst_n(`N28_RST), .en(`N28_EN),
        .bench(`N28_BENCH), .d(n28_d)
    );
