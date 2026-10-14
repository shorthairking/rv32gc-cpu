//==============================================================================
// sim/unit/dyn_probe_n21b_body.inc —— EXP-N21B 探针公共体（被 4 个 wrapper include）
//------------------------------------------------------------------------------
// 前提（wrapper 必须先定义）：
//   `N21B_BK`    = backend_top 的层次路径（如 `u_tb.u_back`）
//   `N21B_FNAME` = 输出 CSV 相对路径
//   `N21B_BENCH` = 基准编号表达式（integer/wire）
//   `N21B_CLK` / `N21B_RST` / `N21B_EN` = 时钟 / 低有效复位 / 采样使能
// 本文件只做**只读层次引用**（含 `x_i2_uop[*][绝对位]`，该口径由
// `rtl/back2/back2_params.vh:319-325` 明文允许）与 `n21b_prf_probe` 例化。
//==============================================================================

    //--------------------------------------------------------------------------
    // 48 bit 观测位向量（逐位定义；分析器 fpga/scratch/n21b_analyze.py 按同一表解包）
    //   [5:0]   x_i2_v[5:0]        E1 各 lane 发射有效（= 本拍 PRF 读口需求真源）
    //   [6]     ALU0 读 P0         `a0_opa` 由 PRF 供数（非 AUIPC、非 CSR）
    //   [7]     ALU0 读 P1         `a0_opb` 取 rs2（R 型）
    //   [8]     FPU s1f            FPU 浮点源 a（Q0）
    //   [9]     FPU s2f            FPU 浮点源 b（Q1）
    //   [10]    FPU s3f            FPU 浮点源 c / FMA（Q2）
    //   [11]    LSU is_store       LSU 需要 wdata（P1/P7）
    //   [12]    LSU is_store&fpls   LSU 浮点 store（Q2）
    //   [13]    cmt slot0 整数写回  `cmt_i_we[0]`（PI8）
    //   [14]    cmt slot1 整数写回  `cmt_i_we[1]`（PI9）
    //   [15]    cmt slot0 浮点写回  `cmt_f_we[0]`（PF3）
    //   [16]    cmt slot1 浮点写回  `cmt_f_we[1]`（PF4）
    //   [17]    CSR 提交源读       `csr_cmt_we`（PI10）
    //   [18]    v5 & is_csr         FPU lane 上的 CSR 指令（诊断用）
    //   [19]    v4 & ~is_store      LSU load（诊断用）
    //   [25:20] iq_iss_v[5:0]       与旧 dyn_probe_core CSV 的 `iss` 列交叉核对
    //   [31:26] iwm_req[5:0]        读口仲裁请求（含基础就绪）
    //   [37:32] iwm_gnt[5:0]        最终获准（含 N15 让位）
    //   [43:38] iwm_gnt_raw[5:0]    未让位获准（N15 让位事件真源）
    //   [47:44] 保留 0
    //--------------------------------------------------------------------------
    wire [47:0] n21b_d;

    assign n21b_d[0]  = `N21B_BK.x_i2_v[0];
    assign n21b_d[1]  = `N21B_BK.x_i2_v[1];
    assign n21b_d[2]  = `N21B_BK.x_i2_v[2];
    assign n21b_d[3]  = `N21B_BK.x_i2_v[3];
    assign n21b_d[4]  = `N21B_BK.x_i2_v[4];
    assign n21b_d[5]  = `N21B_BK.x_i2_v[5];

    //   ALU0 的两个读口是否真被消费（backend_top.v:1545-1546）
    assign n21b_d[6]  = ~`N21B_BK.x_i2_uop[0][`BACK2_IW_AUIPC]
                       & ~`N21B_BK.x_i2_uop[0][`BACK2_UB_IS_CSR];
    assign n21b_d[7]  = `N21B_BK.x_i2_uop[0][`BACK2_IW_RTYPE];

    //   FPU 三个浮点源（backend_top.v:2245-2248）
    assign n21b_d[8]  = `N21B_BK.x_i2_uop[5][`BACK2_UB_S1_F_USE];
    assign n21b_d[9]  = `N21B_BK.x_i2_uop[5][`BACK2_UB_S2_F_USE];
    assign n21b_d[10] = `N21B_BK.x_i2_uop[5][`BACK2_UB_S3_F_USE];

    //   LSU store / 浮点 store（backend_top.v:1657-1660、2248）
    assign n21b_d[11] = `N21B_BK.x_i2_uop[4][`BACK2_UB_IS_STORE];
    assign n21b_d[12] = `N21B_BK.x_i2_uop[4][`BACK2_UB_IS_STORE]
                      & `N21B_BK.x_i2_uop[4][`BACK2_UB_IS_FPLS];

    //   提交级窄读口需求（backend_top.v:1913/1915/1920 的判据逐位等价写法）
    assign n21b_d[13] = `N21B_BK.commit_valid_o[0] & `N21B_BK.cmt_narrow[`BACK2_NQ_DI];
    assign n21b_d[14] = `N21B_BK.commit_valid_o[1] & `N21B_BK.cmt_narrow[`BACK2_NQ_W + `BACK2_NQ_DI];
    assign n21b_d[15] = `N21B_BK.commit_valid_o[0] & `N21B_BK.cmt_narrow[`BACK2_NQ_DF];
    assign n21b_d[16] = `N21B_BK.commit_valid_o[1] & `N21B_BK.cmt_narrow[`BACK2_NQ_W + `BACK2_NQ_DF];
    assign n21b_d[17] = `N21B_BK.csr_cmt_we;

    assign n21b_d[18] = `N21B_BK.x_i2_v[5] & `N21B_BK.x_i2_uop[5][`BACK2_UB_IS_CSR];
    assign n21b_d[19] = `N21B_BK.x_i2_v[4] & ~`N21B_BK.x_i2_uop[4][`BACK2_UB_IS_STORE];

    //   交叉核对 / 让位边界观测
    assign n21b_d[25:20] = `N21B_BK.iq_iss_v[5:0];
    assign n21b_d[31:26] = `N21B_BK.iwm_req[5:0];
    assign n21b_d[37:32] = `N21B_BK.iwm_gnt[5:0];
    assign n21b_d[43:38] = `N21B_BK.iwm_gnt_raw[5:0];
    assign n21b_d[47:44] = 4'h0;

    n21b_prf_probe #(.FNAME(`N21B_FNAME)) u_n21b_probe (
        .clk(`N21B_CLK), .rst_n(`N21B_RST), .en(`N21B_EN), .rs(1'b1),
        .bench(`N21B_BENCH), .d(n21b_d)
    );
