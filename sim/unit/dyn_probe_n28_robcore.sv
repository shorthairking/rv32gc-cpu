//==============================================================================
// sim/unit/dyn_probe_n28_robcore.sv —— EXP-N28A：ROB 压力定向直驱夹具
//------------------------------------------------------------------------------
// 来源：`sim/unit/n15s_fpstress_core.sv` 的**逐字拷贝 + 宏改名**（N15S_→N28_、
//   module n15s_fpstress_core→n28_robcore），不改功能语义：理想 4 宽前端 +
//   backend_top 直驱 + Spike `--log-commits` 黄金逐条比对 + 逐字节 store 映像比对
//   + N15 让位恒等式/代价记账。加它是为了在**不改 N15 任何文件**的前提下新增
//   ROB 高水位定向负载（长延迟 fdiv/fsqrt、整数 div、store 密集）。
//
// 用途（`rv32gc-cpu/answer.md` §四 N28A 工作集）：为 ROB 64→48 余量判定提供
//   "长延迟执行 / 内存压力"两类压力的**定向**档（分支恢复由锁步 p2_branch /
//   core_top p7_trap+p8_int+p9_trapvec 覆盖）。
//
//   ★ EXP-N28A 新增三档（RTL 侧宏；负载由 fpga/scratch/n28_stress_gen.py 生成）：
//     div(-DN28_VARIANT_DIV)：fdiv/fsqrt 密集（长延迟挂 ROB 头 ⇒ 提交冻结、年轻
//                             指令持续分配）——**ROB 占用高水位主压力档**。
//     rob(-DN28_VARIANT_ROB)：长延迟与独立填充流交替 + 整数 div 密集。
//     st (-DN28_VARIANT_ST) ：整数/浮点 store 密集（笔数 ≲32，避开 iverilog STQ 悬崖）。
//   另保留 N15 原有五档宏（mixed/fma/store/mdu/inj/mixdep）原样不动。
//
// 【判据（全部 $fatal；未捕获即失败）】C1 提交条数 / C2 提交 PC / C3 写回 / C4 store
//   字节映像 / C5 覆盖率（本三档按宏放宽）/ C6 让位恒等式 / C7 让位代价记账。
// 顶层  : n28_robcore
// 锚点  : N28_STRESS: PASS（整行恰好一次）
// 运行  : fpga/scratch/n28_run.sh（cwd = 仓库根；样式 = n15_stress_run.sh）
//==============================================================================
`ifdef N28_VARIANT_DIV
  `define N28_V "n28div"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 0
`elsif N28_VARIANT_ROB
  `define N28_V "n28rob"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 0
`elsif N28_VARIANT_ST
  `define N28_V "n28st"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 0
`elsif N28_VARIANT_FMA
  `define N28_V "fma"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 0
`elsif N28_VARIANT_MIXDEP
  `define N28_V "mixdep"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 1
`elsif N28_VARIANT_STORE
  `define N28_V "store"
  `define N28_REQUIRE_Y5 1
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 1
`elsif N28_VARIANT_MDU
  `define N28_V "mdu"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 1
  `define N28_CHECK_PRESS 0
`elsif N28_VARIANT_INJ
  `define N28_V "inj"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 1
`else
  `define N28_V "n28div"
  `define N28_REQUIRE_Y5 0
  `define N28_REQUIRE_Y3 0
  `define N28_CHECK_PRESS 0
`endif
`ifndef N28_DIR
  `define N28_DIR "fpga/scratch/n28_stress/"
`endif

module n28_robcore;

    localparam integer CLK_HALF_NS  = 5;
    localparam integer RESET_CYCLES = 20;
    localparam integer CYC_LIMIT    = 300000;
    localparam integer MAXI         = 4096;    // 黄金/映像数组容量
    localparam integer MAXST        = 8192;    // 黄金 store 字节容量
    localparam [31:0]  BASE         = 32'h8000_0000;

    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_HALF_NS) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "N28_STRESS 判据不满足");
            end
        end
    endtask

    //==========================================================================
    // 0. 黄金/映像数据（$readmemh；文件缺失 ⇒ 数组保持 x ⇒ 判据必然失败，fail-closed）
    //==========================================================================
    reg [31:0] IMG  [0:MAXI-1];
    reg [31:0] GPC  [0:MAXI-1];
    reg [4:0]  GRD  [0:MAXI-1];
    reg        GWE  [0:MAXI-1];
    reg [31:0] GWD  [0:MAXI-1];
    reg [31:0] META [0:3];
    reg [31:0] GSTA [0:MAXST-1];
    reg [7:0]  GSTV [0:MAXST-1];

    integer N_IMG, N_GOLD, N_STB, N_GWE;

    initial begin
        $readmemh({`N28_DIR, `N28_V, "_meta.hex"}, META);
        N_IMG  = META[0];
        N_GOLD = META[1];
        N_STB  = META[2];
        N_GWE  = META[3];
        $readmemh({`N28_DIR, `N28_V, "_img.hex"}, IMG);
        $readmemh({`N28_DIR, `N28_V, "_pc.hex"},  GPC);
        $readmemh({`N28_DIR, `N28_V, "_rd.hex"},  GRD);
        $readmemh({`N28_DIR, `N28_V, "_we.hex"},  GWE);
        $readmemh({`N28_DIR, `N28_V, "_wd.hex"},  GWD);
        // 逐字节黄金存储映像：地址列 + 值列（两文件一一对应）
        $readmemh({`N28_DIR, `N28_V, "_sta.hex"}, GSTA);
        $readmemh({`N28_DIR, `N28_V, "_stv.hex"}, GSTV);
        if ((N_IMG <= 0) || (N_IMG > MAXI) || (N_GOLD <= 0) || (N_GOLD > MAXI) ||
            (N_GOLD > N_IMG) || (N_STB < 0) || (N_STB > MAXST))
            $fatal(1, "N28_STRESS: 元数据非法（img=%0d gold=%0d stb=%0d）",
                   N_IMG, N_GOLD, N_STB);
        $display("== N28-STRESS 负载 `%s`：映像 %0d 字，Spike 黄金 %0d 条（写回 %0d 条），store 字节 %0d",
                 `N28_V, N_IMG, N_GOLD, N_GWE, N_STB);
    end

    //==========================================================================
    // 1. 理想 4 宽前端（与 tb_back2_ipc 同一手法；无分支流 ⇒ cls=0/len32=1）
    //==========================================================================
    reg  [31:0] blk_pc_q;
    reg         blk_valid;
    wire        blk_ready;
    integer     li;
    reg  [127:0] lane_pc, lane_pa, lane_insn;
    reg  [3:0]   lane_len32, lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    reg  [3:0]   lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    reg  [3:0]   lane_fault, lane_ckpt_valid;
    reg  [11:0]  lane_cls;
    reg  [127:0] lane_pred_target, lane_btb_target, lane_fault_tval;   // ★ 逐 lane 32 bit ×4
    reg  [15:0]  lane_ckpt;
    reg  [19:0]  lane_fault_cause;
    reg  [31:0]  blk_next_pc;
    reg          blk_taken;
    reg  [3:0]   blk_mask;
    reg          fe_fetch_fault;

    // 映像字读取（越界 ⇒ nop；程序尾后的 nop 不会进入上半段比对）
    function [31:0] img_word;
        input integer widx;
        begin
            img_word = ((widx >= 0) && (widx < N_IMG)) ? IMG[widx] : 32'h00000013;
        end
    endfunction

    integer wid0;
    always @(*) begin
        wid0 = (blk_pc_q - BASE) >> 2;
        for (li = 0; li < 4; li = li + 1) begin
            lane_pc  [li*32 +: 32] = blk_pc_q + 4*li;
            lane_pa  [li*32 +: 32] = blk_pc_q + 4*li;
            lane_insn[li*32 +: 32] = img_word(wid0 + li);
            lane_len32  [li] = 1'b1;
            lane_cls    [li*3 +: 3]  = 3'd0;      // 无控制转移（负载由生成器保证无分支）
            lane_pred_taken[li] = 1'b0;
            lane_pred_selg [li] = 1'b0;
            lane_pred_gdir [li] = 1'b0;
            lane_pred_ldir [li] = 1'b0;
            lane_pred_target[li*32 +: 32] = 32'h0;
            lane_btb_hit [li] = 1'b0;
            lane_btb_way [li] = 1'b0;
            lane_btb_cond[li] = 1'b0;
            lane_btb_call[li] = 1'b0;
            lane_btb_ret [li] = 1'b0;
            lane_btb_target[li*32 +: 32] = 32'h0;
            lane_fault   [li] = 1'b0;
            lane_ckpt_valid[li] = 1'b0;
            lane_ckpt[li*4 +: 4] = 4'h0;
            lane_fault_tval[li*32 +: 32] = 32'h0;
        end
        blk_next_pc = blk_pc_q + 32'd16;
        blk_taken   = 1'b0;
        blk_mask    = 4'hF;
        lane_fault_cause = 20'h0;
        fe_fetch_fault   = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk_pc_q   <= BASE;
            blk_valid  <= 1'b0;
        end else begin
            if (!blk_valid) blk_valid <= 1'b1;
            if (blk_valid && blk_ready) blk_pc_q <= blk_pc_q + 32'd16;
        end
    end

    //==========================================================================
    // 2. backend_top 例化（端口契约与 tb_back2_ipc.sv 逐字一致）
    //==========================================================================
    wire        redirect_valid, redirect_use_ckpt;
    wire [31:0] redirect_pc;
    wire [3:0]  redirect_ckpt;
    wire        train_valid, train_ready;
    wire [31:0] train_pc, train_target, train_pred_target;
    wire        train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    wire        train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    wire        train_pred_valid, train_btb_hit, train_btb_way;
    wire        ckpt_free_valid;  wire [3:0] ckpt_free_id;
    wire        ras_cmt_push, ras_cmt_pop, d2_push_valid, d2_pop_valid;
    wire [31:0] d2_push_addr, d2_pop_addr;
    wire        mem_req_valid, mem_req_wen;
    wire [31:0] mem_req_addr, mem_req_wdata;
    wire [3:0]  mem_req_wstrb;
    wire [`BACK2_MEM_TAG_W-1:0] mem_req_tag;
    wire [3:0]  commit_valid;
    wire [127:0] commit_pc, commit_arch_rd_wdata;
    wire [19:0]  commit_arch_rd;
    wire [3:0]   commit_arch_we;
    wire        trap_valid;
    wire [31:0] trap_pc, trap_tval;
    wire [3:0]  trap_cause;
    wire [31:0] cnt_commit, cnt_squash, cnt_commit4, cnt_issue;
    wire [6:0]  dbg_rob_cnt;
    wire [23:0] dbg_iq_cnt;
    wire [7:0]  dbg_stq_cnt;
    // 存储模型（带标签 2 级；本夹具只用 store，load 分支保留以对齐契约）
    wire        mem_req_ready;
    wire        mem_rsp_valid;
    wire [31:0] mem_rsp_rdata;
    wire [`BACK2_MEM_TAG_W-1:0] mem_rsp_tag;

    //   CSR 桩连线声明必须早于 backend_top 例化（否则 iverilog 建 1 bit 隐式网）
    wire [11:0] tb_csr_raddr;  wire [31:0] tb_csr_rdata;
    wire        tb_csr_we;     wire [11:0] tb_csr_waddr;  wire [31:0] tb_csr_wdata;
    wire [2:0]  tb_csr_frm;    wire [4:0]  tb_csr_fflags;

    backend_top u_back (
        .clk(clk), .rst_n(rst_n),
        .blk_valid_i(blk_valid), .blk_ready_o(blk_ready), .blk_mask_i(blk_mask),
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
        .lane_fault_tval_i(lane_fault_tval),
        .lane_ckpt_i(lane_ckpt), .lane_ckpt_valid_i(lane_ckpt_valid),
        .fe_fetch_fault_i(fe_fetch_fault),
        .redirect_valid_o(redirect_valid), .redirect_pc_o(redirect_pc),
        .redirect_use_ckpt_o(redirect_use_ckpt), .redirect_ckpt_o(redirect_ckpt),
        .train_valid_o(train_valid), .train_pc_o(train_pc),
        .train_is_cond_o(train_is_cond), .train_taken_o(train_taken),
        .train_is_indirect_o(train_is_indirect), .train_is_call_o(train_is_call),
        .train_is_return_o(train_is_return), .train_target_o(train_target),
        .train_pred_taken_o(train_pred_taken), .train_pred_sel_global_o(train_pred_sel_global),
        .train_pred_gdir_o(train_pred_gdir), .train_pred_ldir_o(train_pred_ldir),
        .train_pred_target_o(train_pred_target), .train_pred_valid_o(train_pred_valid),
        .train_btb_hit_o(train_btb_hit), .train_btb_way_o(train_btb_way),
        .train_ready_i(1'b1),
        .ckpt_free_valid_o(ckpt_free_valid), .ckpt_free_id_o(ckpt_free_id),
        .ras_cmt_push_valid_o(ras_cmt_push), .ras_cmt_pop_valid_o(ras_cmt_pop),
        .d2_push_valid_o(d2_push_valid), .d2_push_addr_o(d2_push_addr),
        .d2_pop_valid_o(d2_pop_valid), .d2_pop_addr_o(d2_pop_addr),
        .mem_req_valid_o(mem_req_valid), .mem_req_wen_o(mem_req_wen),
        .mem_req_addr_o(mem_req_addr), .mem_req_wdata_o(mem_req_wdata),
        .mem_req_wstrb_o(mem_req_wstrb), .mem_req_tag_o(mem_req_tag),
        .mem_req_ready_i(mem_req_ready),
        .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_rdata_i(mem_rsp_rdata),
        .mem_rsp_tag_i(mem_rsp_tag),
        .commit_valid_o(commit_valid), .commit_pc_o(commit_pc),
        .commit_arch_rd_o(commit_arch_rd), .commit_arch_rd_wdata_o(commit_arch_rd_wdata),
        .commit_arch_we_o(commit_arch_we),
        .trp_flush_v_i(1'b0), .trp_redirect_v_i(1'b0), .trp_redirect_pc_i(32'h0),
        .csr_raddr_o(tb_csr_raddr), .csr_rdata_i(tb_csr_rdata),
        .csr_frm_i(tb_csr_frm), .csr_fflags_i(tb_csr_fflags),
        .csr_we_o(tb_csr_we), .csr_waddr_o(tb_csr_waddr), .csr_wdata_o(tb_csr_wdata),
        .xret_kind_o(),
        .trap_valid_o(trap_valid), .trap_pc_o(trap_pc),
        .trap_cause_o(trap_cause), .trap_tval_o(trap_tval),
        .cnt_commit_o(cnt_commit), .cnt_squash_o(cnt_squash),
        .cnt_commit4_o(cnt_commit4), .cnt_issue_o(cnt_issue),
        .dbg_rob_cnt_o(dbg_rob_cnt), .dbg_iq_cnt_o(dbg_iq_cnt), .dbg_stq_cnt_o(dbg_stq_cnt)
    );

    b2_csr u_tb_csr (
        .clk(clk), .rst_n(rst_n),
        .raddr(tb_csr_raddr), .rdata(tb_csr_rdata), .raddr_ill(),
        .frm_o(tb_csr_frm), .fflags_o(tb_csr_fflags),
        .we(tb_csr_we), .waddr(tb_csr_waddr), .wdata(tb_csr_wdata),
        .trp_enter_v(1'b0), .trp_enter_pc(32'h0), .trp_enter_cause(32'h0),
        .trp_enter_tval(32'h0), .trp_exit_v(1'b0), .mtip_i(1'b0),
        .mtvec_o(), .mepc_o(), .mstatus_o(), .mie_o()
    );

    //==========================================================================
    // 3. 只读层次探针（不改 RTL；让位/请求/获准/连续等待）
    //==========================================================================
    reg probe_en;
    n15s_yield_probe u_probe (
        .clk(clk), .rst_n(rst_n), .en(probe_en),
        .iwm_req    (u_back.iwm_req),
        .iwm_gnt    (u_back.iwm_gnt),
        .iwm_gnt_raw(u_back.iwm_gnt_raw),
        .iq_iss_v   (u_back.iq_iss_v),
        .iq_base_rdy(u_back.iq_base_rdy),
        .iq4_cnt    (u_back.u_iq4.cnt_o),
        .iq5_cnt    (u_back.u_iq5.cnt_o)
    );

    //==========================================================================
    // 4. 存储模型：store 当拍逐字节落地（也用于 C4 黄金存储映像比对）
    //==========================================================================
    reg [7:0] dut_b      [0:65535];   // 最终字节值
    reg       dut_b_seen [0:65535];   // 是否被写过
    integer   n_st_txn;               // 被接收的 store 笔数
    integer   wb;
    reg       rd_acc;
    reg       rq1_v, rq2_v;
    reg [`BACK2_MEM_TAG_W-1:0] rq1_t, rq2_t;
    reg [31:0] rq1_d, rq2_d;

`ifdef N28_NOSTC
    //   诊断档：关闭存储字节捕获（只验证功能/让位，不验证 store 数据）
    assign mem_req_ready = 1'b1;
    assign mem_rsp_valid = 1'b0;
    assign mem_rsp_tag   = {`BACK2_MEM_TAG_W{1'b0}};
    assign mem_rsp_rdata = 32'h0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) n_st_txn <= 0;
        else if (mem_req_valid && mem_req_ready && mem_req_wen) n_st_txn <= n_st_txn + 1;
    end
`else
    //   ★ 与 sim/unit/tb_back2_lockstep.sv §5 **同一口径**（唯一正确的一种）：
    //     `ready = ~rq2_v` 是**组合**信号、`rsp_valid = rq2_v` 也是组合 ⇒ 每个被接收的
    //     读请求恰好产生一拍响应、且不会被后来的请求覆盖 tag（"永久在飞"缺陷的根因）。
    //     警告：本模型**不得**把 ready/valid 改成寄存器（实测：寄存器版 ready 晚一拍下降
    //     ⇒ 背靠背两个 load 的第 1 个响应 tag 被覆盖 ⇒ LSU 永远等不到 ⇒ 挂死）。
    assign mem_req_ready = ~rq2_v;
    assign mem_rsp_valid = rq2_v;
    assign mem_rsp_tag   = rq2_t;
    assign mem_rsp_rdata = rq2_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq1_v <= 1'b0; rq2_v <= 1'b0;
            rq1_t <= {`BACK2_MEM_TAG_W{1'b0}}; rq2_t <= {`BACK2_MEM_TAG_W{1'b0}};
            rq1_d <= 32'h0; rq2_d <= 32'h0;
            n_st_txn <= 0;
        end else begin
            // ---- 写：当拍按字节落地（LSU 单发射口 ⇒ 单笔/拍）----
            if (mem_req_valid && mem_req_ready && mem_req_wen) begin
                n_st_txn <= n_st_txn + 1;
                for (wb = 0; wb < 4; wb = wb + 1)
                    if (mem_req_wstrb[wb]) begin
                        dut_b[mem_req_addr[15:0] + wb]      <= mem_req_wdata[8*wb +: 8];
                        dut_b_seen[mem_req_addr[15:0] + wb] <= 1'b1;
                    end
            end
            // ---- 读：入第一级；地址与 tag 同拍锁存 ----
            rd_acc = mem_req_valid && mem_req_ready && ~mem_req_wen;
            rq1_v <= rd_acc;
            if (rd_acc) begin
                rq1_t <= mem_req_tag;
                rq1_d <= dut_b[mem_req_addr[15:0]] | (dut_b[mem_req_addr[15:0]+1] << 8)
                       | (dut_b[mem_req_addr[15:0]+2] << 16) | (dut_b[mem_req_addr[15:0]+3] << 24);
            end
            rq2_v <= rq1_v; rq2_t <= rq1_t; rq2_d <= rq1_d;
        end
    end
`endif

    //==========================================================================
    // 5. 提交捕获 + 黄金比对（全在 always 块内，避免与主流程的时序竞争）
    //==========================================================================
    integer n_cmt;                       // 观察到的提交条数（含程序尾后的 nop）
    integer n_pc_err, n_we_err, n_rd_err, n_wd_err;
    integer cw;
    integer fpc_err, fwe_err, frd_err, fwd_err;
    always @(posedge clk) begin
        if (rst_n) begin
            for (cw = 0; cw < 4; cw = cw + 1) begin
                if (commit_valid[cw]) begin
                    if (n_cmt < N_GOLD) begin
`ifdef N28_INJECT_GOLD
                        // 反证注入①：把中间某条的黄金期望 PC 故意改一位 ⇒ C2 必须报分歧
                        if (n_cmt == (N_GOLD / 2)) begin
                            if (commit_pc[cw*32 +: 32] !== (GPC[n_cmt] ^ 32'h4)) begin
                                n_pc_err = n_pc_err + 1;
                                $display("FAIL: [注入①] 第 %0d 条提交 PC=0x%08x 与（被篡改的）期望 0x%08x 不一致",
                                         n_cmt, commit_pc[cw*32 +: 32], GPC[n_cmt] ^ 32'h4);
                            end
                        end else
`endif
                        if (commit_pc[cw*32 +: 32] !== GPC[n_cmt]) begin
                            n_pc_err = n_pc_err + 1;
                            if (fpc_err == 0) begin
                                fpc_err = 1;
                                $display("FAIL: 第 %0d 条提交 PC=0x%08x ≠ Spike 黄金 0x%08x",
                                         n_cmt, commit_pc[cw*32 +: 32], GPC[n_cmt]);
                            end
                        end
                        if (commit_arch_we[cw] !== GWE[n_cmt]) begin
                            n_we_err = n_we_err + 1;
                            if (fwe_err == 0) begin
                                fwe_err = 1;
                                $display("FAIL: 第 %0d 条 (pc=0x%08x) 写回使能 %b ≠ 黄金 %b",
                                         n_cmt, commit_pc[cw*32 +: 32],
                                         commit_arch_we[cw], GWE[n_cmt]);
                            end
                        end
                        if (commit_arch_we[cw]) begin
                            if (commit_arch_rd[cw*5 +: 5] !== GRD[n_cmt]) begin
                                n_rd_err = n_rd_err + 1;
                                if (frd_err == 0) begin
                                    frd_err = 1;
                                    $display("FAIL: 第 %0d 条 (pc=0x%08x) 写回寄存器 %0d ≠ 黄金 %0d",
                                             n_cmt, commit_pc[cw*32 +: 32],
                                             commit_arch_rd[cw*5 +: 5], GRD[n_cmt]);
                                end
                            end
                            if (commit_arch_rd_wdata[cw*32 +: 32] !== GWD[n_cmt]) begin
                                n_wd_err = n_wd_err + 1;
                                if (fwd_err == 0) begin
                                    fwd_err = 1;
                                    $display("FAIL: 第 %0d 条 (pc=0x%08x rd=%0d) 写回值 0x%08x ≠ 黄金 0x%08x",
                                             n_cmt, commit_pc[cw*32 +: 32],
                                             commit_arch_rd[cw*5 +: 5],
                                             commit_arch_rd_wdata[cw*32 +: 32], GWD[n_cmt]);
                                end
                            end
                        end
                    end
                    n_cmt = n_cmt + 1;
                end
            end
        end
    end

    //==========================================================================
    // 6. 主流程
    //==========================================================================
    integer cyc, k, i;
    integer n_stb_seen, n_stb_bad, n_stb_extra;
    integer first_bad_st;
    integer fpucmt, lsucmt, yldcnt;
    reg     gst_want [0:65535];   // 黄金要求写过的字节位图（避免 O(64k*N) 扫描）

    initial begin
        n_checks = 0;
        n_cmt = 0;
        n_pc_err = 0; n_we_err = 0; n_rd_err = 0; n_wd_err = 0;
        fpc_err = 0; fwe_err = 0; frd_err = 0; fwd_err = 0;
        probe_en = 1'b0;
        for (k = 0; k < 65536; k = k + 1) begin
            dut_b[k] = 8'h00;
            dut_b_seen[k] = 1'b0;
        end
        rst_n = 1'b0;
        repeat (RESET_CYCLES) @(posedge clk);
        rst_n = 1'b1;
        probe_en = 1'b1;
        repeat (2) @(posedge clk);

        cyc = 0;
        while ((n_cmt < N_GOLD) && (cyc < CYC_LIMIT)) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (trap_valid) begin
                $display("FAIL: 出现未预期异常 pc=0x%08x cause=%0d tval=0x%08x",
                         trap_pc, trap_cause, trap_tval);
                $fatal(1, "N28_STRESS 出现异常");
            end
            if ((cyc % 500) == 0) begin
                $display("   … %0d 拍：提交 %0d/%0d ROB=%0d STQ=%0d IQ=%b req=%02x gnt=%02x raw=%02x | 队占 iq4=%0d iq5=%0d",
                         cyc, n_cmt, N_GOLD, dbg_rob_cnt, dbg_stq_cnt, dbg_iq_cnt,
                         u_back.iwm_req, u_back.iwm_gnt, u_back.iwm_gnt_raw,
                         u_back.u_iq4.cnt_o, u_back.u_iq5.cnt_o);
                $display("       rob: head=%0d cnt=%0d done=%b exc=%b | lsu: cdq=%0d stq=%0d drany=%b drok=%b drbad=%b drfire=%b | mem v=%b rdy=%b wen=%b | drm=%b",
                         u_back.u_rob.head_o, u_back.u_rob.cnt_o,
                         u_back.u_rob.head_done_o, u_back.u_rob.head_exc_o,
                         u_back.u_lsu.cdq_cnt, u_back.u_lsu.stq_used,
                         u_back.u_lsu.dr_any, u_back.u_lsu.dr_ok, u_back.u_lsu.dr_bad,
                         u_back.u_lsu.dr_fire,
                         mem_req_valid, mem_req_ready, mem_req_wen,
                         u_back.u_lsu.dr_room_ok);
                $display("       sel: i4sel=%b base_rdy=%b iq4rdy=%b iq5rdy=%b | lsu iss_ok=%b anyunk=%b | stq_blk=%b",
                         u_back.i4_sel_v, u_back.iq_base_rdy,
                         u_back.u_iq4.rdy_q, u_back.u_iq5.rdy_q,
                         u_back.u_lsu.iss_ok, u_back.u_lsu.any_unk_w,
                         u_back.u_lsu.stq_blk_any_w);
                $display("       fpu: if_v=%b done=%b busy=%b i5sel=%b selrob=%0d head=%0d dyn=%b headw=%b csrblk=%b issok=%b x_i2_v5=%b | hpc=0x%08x",
                         u_back.fpu_if_v, u_back.fpu_done, u_back.fpu_busy,
                         u_back.i5_sel_v, u_back.i5_sel_rob, u_back.u_rob.head_o,
                         u_back.fpu_dyn_w, u_back.fpu_head_w, u_back.csr_fp_block_w,
                         u_back.fpu_iss_ok_w, u_back.x_i2_v[5],
                         u_back.p_pc(u_back.cmt_pay[0 +: `BACK2_RB_W]));
                $display("       kill: fpu_kill=%b flush_all=%b squash=%b trap=%b | fpu ds_busy=%b sc_v=%b wb_v=%b if_di=%b",
                         u_back.fpu_kill, u_back.flush_all_w, u_back.squash_v_w, trap_valid,
                         u_back.u_fpu.ds_busy, u_back.u_fpu.sc_v,
                         u_back.fpu_wb_v, u_back.fpu_if_di);
                $fflush();
            end
        end
        // 让尾部 store 落地 + 探针采样收口
        repeat (20) @(posedge clk);
        probe_en = 1'b0;
        repeat (2) @(posedge clk);
        $fclose(u_probe.fcsv);

        // ---- C1 提交条数 ----
        chk(n_cmt >= N_GOLD, $sformatf("C1 提交条数 %0d ≥ 黄金 %0d", n_cmt, N_GOLD));

        // ---- C4 存储映像逐字节 ----
        n_stb_seen = 0; n_stb_bad = 0; n_stb_extra = 0; first_bad_st = -1;
        for (k = 0; k < 65536; k = k + 1) gst_want[k] = 1'b0;
        for (k = 0; k < N_STB; k = k + 1) begin
            gst_want[GSTA[k][15:0]] = 1'b1;
            if (dut_b_seen[GSTA[k][15:0]]) begin
                n_stb_seen = n_stb_seen + 1;
`ifdef N28_INJECT_MEM
                // 反证注入②：把中间某个黄金字节故意取反 ⇒ C4 必须报分歧
                if ((k == (N_STB / 2)) && (N_STB > 0) &&
                    (dut_b[GSTA[k][15:0]] !== (GSTV[k] ^ 8'hFF))) begin
                    n_stb_bad = n_stb_bad + 1;
                    $display("FAIL: [注入②] 存储字节 0x%04x 实测 0x%02x 与（被篡改的）期望 0x%02x 不一致",
                             GSTA[k][15:0], dut_b[GSTA[k][15:0]], GSTV[k] ^ 8'hFF);
                end else
`endif
                if (dut_b[GSTA[k][15:0]] !== GSTV[k]) begin
                    n_stb_bad = n_stb_bad + 1;
                    if (first_bad_st < 0) begin
                        first_bad_st = GSTA[k][15:0];
                        $display("FAIL: 存储字节 0x%04x 实测 0x%02x ≠ 黄金 0x%02x",
                                 GSTA[k][15:0], dut_b[GSTA[k][15:0]], GSTV[k]);
                    end
                end
            end
        end
        for (k = 0; k < 65536; k = k + 1)
            if (dut_b_seen[k] && !gst_want[k]) n_stb_extra = n_stb_extra + 1;
        $display("== C4 存储：黄金字节 %0d，实测命中 %0d，值错 %0d，黄金未要求的写入字节 %0d（store 事务 %0d）",
                 N_STB, n_stb_seen, n_stb_bad, n_stb_extra, n_st_txn);
        chk(n_stb_seen == N_STB, $sformatf("C4 store 字节全覆盖（%0d/%0d）", n_stb_seen, N_STB));
        chk(n_stb_bad == 0, $sformatf("C4 store 逐字节值 0 分歧（错 %0d）", n_stb_bad));
        chk(n_stb_extra == 0, $sformatf("C4 无黄金未要求的存储写入（多余 %0d 字节）", n_stb_extra));

        // ---- C2/C3 提交黄金比对 ----
        $display("== C2/C3 提交比对：PC 错 %0d，写回使能错 %0d，寄存器号错 %0d，值错 %0d（共 %0d 条）",
                 n_pc_err, n_we_err, n_rd_err, n_wd_err, N_GOLD);
        chk(n_pc_err == 0, $sformatf("C2 提交 PC vs Spike 黄金 0 分歧（错 %0d）", n_pc_err));
        chk(n_we_err == 0, $sformatf("C3 写回使能 vs 黄金 0 分歧（错 %0d）", n_we_err));
        chk(n_rd_err == 0, $sformatf("C3 写回寄存器号 vs 黄金 0 分歧（错 %0d）", n_rd_err));
        chk(n_wd_err == 0, $sformatf("C3 写回值 vs 黄金 0 分歧（错 %0d）", n_wd_err));

        // ---- C5 覆盖率（反假 PASS）----
        $display("== C5 压力覆盖：同拍 req4&req5 = %0d 拍；raw5&raw4（真让位）= %0d 拍；",
                 u_probe.both_req_cnt, u_probe.both_raw_cnt);
        $display("           lane 请求/获准/发射：ALU0 %0d/%0d/%0d | ALU1 %0d/%0d/%0d | BRU %0d/%0d/%0d | MDU %0d/%0d/%0d | LSU %0d/%0d/%0d | FPU %0d/%0d/%0d",
                 u_probe.req_cnt[0], u_probe.gnt_cnt[0], u_probe.iss_cnt[0],
                 u_probe.req_cnt[1], u_probe.gnt_cnt[1], u_probe.iss_cnt[1],
                 u_probe.req_cnt[2], u_probe.gnt_cnt[2], u_probe.iss_cnt[2],
                 u_probe.req_cnt[3], u_probe.gnt_cnt[3], u_probe.iss_cnt[3],
                 u_probe.req_cnt[4], u_probe.gnt_cnt[4], u_probe.iss_cnt[4],
                 u_probe.req_cnt[5], u_probe.gnt_cnt[5], u_probe.iss_cnt[5]);
        $display("== 让位：MDU(L3)让 ALU1 = %0d 次（最长连续 %0d 拍）；FPU(L5)让 LSU = %0d 次（最长连续 %0d 拍）",
                 u_probe.y3_cnt, u_probe.y3_max, u_probe.y5_cnt, u_probe.y5_max);
        if (`N28_CHECK_PRESS == 1)
            chk(u_probe.both_req_cnt > 0, "C5 覆盖率：必须出现「LSU 与 FPU 同拍请求合并口」");
        if (`N28_REQUIRE_Y5 == 1)
            chk(u_probe.y5_cnt > 0, "C5 覆盖率：必须出现 FPU(L5) 因 N15 让位而未发射");
        if (`N28_REQUIRE_Y3 == 1)
            chk(u_probe.y3_cnt > 0, "C5 覆盖率：必须出现 MDU(L3) 因 N15 让位而未发射");

        // ---- C6 恒等式（逐拍核对，由探针与分析器双份给出）----
        //   探针内部 expect_gnt 已逐拍可用；这里给一个采样不变式（全窗由分析器核对 CSV）
        chk(u_probe.expect_gnt === u_back.iwm_gnt,
            "C6 让位恒等式（末拍样例）：gnt == raw & ~让位掩码");
        chk((u_back.iwm_gnt & ~u_back.iwm_req) == 6'd0,
            "C6 gnt ⊆ req（获准者必是请求者）");

        // ---- C7 让位代价记账 ----
        fpucmt = u_probe.iss_cnt[5];
        lsucmt = u_probe.iss_cnt[4];
        yldcnt = u_probe.y5_cnt;
        $display("== C7 让位代价记账：FPU 发射 %0d，LSU 发射 %0d，让位 %0d ⇒ 让位 ≤ min(FPU 可发射 %0d, LSU 获准 %0d) = %0d",
                 fpucmt, lsucmt, yldcnt, u_probe.req5_raw_cnt, u_probe.gnt4_cnt,
                 (u_probe.req5_raw_cnt < u_probe.gnt4_cnt) ? u_probe.req5_raw_cnt
                                                           : u_probe.gnt4_cnt);
        chk(yldcnt <= u_probe.req5_raw_cnt, "C7 让位次数 ≤ FPU 本可发射拍数");
        chk(yldcnt <= u_probe.gnt4_cnt,      "C7 让位次数 ≤ LSU 获准拍数");

        // ---- 汇总 ----
        $display("== N28-STRESS 汇总：负载 %s，采样 %0d 拍，提交 %0d 条（黄金 %0d），store 字节 %0d，检查 %0d 项",
                 `N28_V, u_probe.ncyc, n_cmt, N_GOLD, N_STB, n_checks);
        $display("N28_STRESS: PASS");
        $finish;
    end

    // 全局超时兜底
    initial begin
        #(CLK_HALF_NS * 2 * (CYC_LIMIT + 100000));
        $display("FAIL: N28-STRESS TB 超时");
        $fatal(1, "N28_STRESS 超时");
    end

endmodule
