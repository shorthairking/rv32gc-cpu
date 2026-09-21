//==============================================================================
// sim/unit/tb_front4_predictor.sv —— 2B-1 锦标赛预测器单元 + 准确率统计 TB
//==============================================================================
// 被测  : rtl/front4/predictor_top.v（含 bpu_gshare / bpu_local_hist / bpu_selector /
//         bpu_btb / bpu_ras 与检查点表）
// 规格  : docs/design/04-predictor.md
//           §3.1 结构参数、§3.2 选择器状态机、§3.3 训练时机=提交点、§4 BTB/RAS、
//           §5.2 各表更新规则、§5.3 GHR 恢复（方案 A/B）、§6.1 统计口径、§8 风险项
//         docs/design/02-pipeline.md §3.2（F2 查表，结果下一拍用）
//
// 【判据（全部 $fatal，未捕获即失败；成功路径只在最后打印唯一一行锚点）】
//   A 分项正确性（逐条向量；见 §A1–§A7）
//     A1 Gshare：2 bit 饱和计数器的 4 次翻转 + GHR 移位内容（16 位逐位比对）
//     A2 局部：LHT 10 位历史内容（逐位比对：T,T,T,N 重复后的 10 位历史）+ LPHT 收敛
//     A3 选择器：§3.2 状态机 4 条转移（全局对/局部错 ⇒ 偏全局；反之 ⇒ 偏局部；
//                同对/同错 ⇒ 不变）+ 复位值 2'b01（弱偏局部）
//     A4 BTB：命中/目标、2 路组相联、组内 LRU 替换（3 个同组分支的淘汰顺序）
//     A5 RAS：压满 16 项后**溢出不压入**、D2 修复（实际返回地址 ≠ 栈顶 ⇒ repair）、
//             检查点深度恢复、全冲刷回"已提交深度"
//     A6 检查点：16 项分配满 ⇒ ckpt_full；释放后可再分配；无效 id 恢复不改状态
//     A7 GHR 恢复：SPEC_GHR=1 ⇒ 检查点回滚恢复 GHR；SPEC_GHR=0（默认方案 A）⇒ 不回滚
//   B 准确率统计（4 类自造轨迹，全部**逐条**由本 TB 参照模型计分）：
//     B1 loop（嵌套循环：内层行程 4/8/16/32 变化）
//     B2 callret（调用-返回：深度 1..6，含 RAS 溢出场景）
//     B3 alt（交错方向：三个 PC 各自周期 3/5/7 的模式轮转 ⇒ 局部强、全局弱）
//     B4 mixed（混合 + "全局强"支路：某分支方向 = 4 条全局历史之前的噪声分支方向
//              ⇒ Gshare 强、局部弱）+ 随机噪声支路
//     断言：① 每类**锦标赛方向准确率 ≥ 80%**（04 文档未给目标值 ⇒ 按任务口径 ≥80%）；
//           ② mixed 上 锦标赛误判数 **严格小于** 单独 Gshare 与单独局部的误判数
//              （选择器确实在做互补选择；这也是反证实验的判据）；
//           ③ 选择器两侧都被使用（bpu_sel_global / bpu_sel_local 各 ≥ 10%）；
//           ④ 硬件统计计数器与本 TB 参照模型**逐个相等**（bpu_br_total /
//              bpu_gshare_right / bpu_local_right / bpu_dir_mispred / bpu_br_mispred）；
//           ⑤ bpu_train_overflow == 0、bpu_ckpt_full_stall == 0。
//   C 反证实验（选择器恒接一侧 ⇒ 准确率必降、断言②必红）：
//     iverilog -Ptb_front4_predictor.SEL_FORCE_P=1 … （或 =2）
//     期望：锚点不出现，运行以 $fatal 结束（非零退出）。
//
// 参数（可用 iverilog -P 覆盖；默认值 = 生产口径）：
//   SPEC_GHR_P = 0（默认方案 A）   SEL_FORCE_P = 0（正常投票）   LAG_P = 0（理想窗口）
//   LAG_P：模拟 04 §5.3 的"GHR 滞后"（预测第 i 条时只训练到 i-1-LAG）——默认 0，
//          另有一组 LAG=4 的统计在 §B5 打印（不参与断言，作证据）。
//
// 顶层  : tb_front4_predictor（regress.sh 取第一个 module 名 + 锚点双重判定）
// 锚点  : TB_FRONT4_PREDICTOR: PASS （整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module tb_front4_predictor;

    //--------------------------------------------------------------------------
    // 参数与本地常量
    //--------------------------------------------------------------------------
    parameter integer SPEC_GHR_P  = 0;      // 0 = 04 §5.3 方案 A（默认）
    parameter integer SEL_FORCE_P = 0;      // 0 = 正常；1 = 恒 Gshare；2 = 恒局部
    parameter integer LAG_P       = 0;      // GHR/表状态滞后事件数（0 = 理想）

    localparam integer CLK_PERIOD = 10;
    localparam integer CKPT_NUM   = `FRONT4_CKPT_NUM;      // 16
    localparam integer RAS_DEPTH  = `FRONT4_RAS_DEPTH;     // 16
    localparam integer MAX_EV     = 32768;

    localparam [1:0] CLS_COND = 2'd0, CLS_CALL = 2'd1, CLS_RET = 2'd2, CLS_IND = 2'd3;

    //--------------------------------------------------------------------------
    // DUT 端口
    //--------------------------------------------------------------------------
    reg         clk, rst_n;

    reg         lu_en;
    reg  [31:0] lu_pc0, lu_pc1;
    wire        lu_valid_o, lu_taken0, lu_taken1;
    wire        lu_gdir0, lu_gdir1, lu_ldir0, lu_ldir1, lu_selg0, lu_selg1;
    wire        lu_btb_hit, lu_btb_way, lu_btb_cond, lu_btb_call, lu_btb_ret;
    wire [31:0] lu_btb_target;
    wire [31:0] lu_ras_top;
    wire        lu_ras_empty;
    wire [`FRONT4_LU_PACK_W-1:0] lu_pack_o;

    reg         ras_push_valid, ras_pop_valid;
    reg  [31:0] ras_push_addr, ras_pop_addr;
    wire        ras_repair_valid;
    wire [31:0] ras_repair_addr;
    reg         ras_flush_all, ras_cmt_push_valid, ras_cmt_pop_valid;

    reg         train_valid;
    reg  [31:0] train_pc;
    reg         train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    reg  [31:0] train_target;
    reg         train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    reg  [31:0] train_pred_target;
    reg         train_pred_valid, train_btb_hit, train_btb_way;
    wire        train_ready, upd_busy;

    reg         ckpt_alloc_valid;
    reg  [31:0] ckpt_alloc_pc;
    wire [3:0]  ckpt_alloc_id;
    wire        ckpt_full;
    reg         ckpt_free_valid;
    reg  [3:0]  ckpt_free_id;
    reg         ckpt_restore_valid;
    reg  [3:0]  ckpt_restore_id;

    wire [31:0] bpu_br_total, bpu_br_mispred, bpu_dir_mispred, bpu_target_mispred;
    wire [31:0] bpu_gshare_right, bpu_local_right, bpu_sel_global, bpu_sel_local;
    wire [31:0] bpu_ras_push, bpu_ras_pop, bpu_ras_overflow, bpu_ras_repair;
    wire [31:0] bpu_ckpt_full_stall, bpu_train_overflow, bpu_btb_alloc;
    wire [15:0] ghr_o;

    predictor_top #(
        .SPEC_GHR (SPEC_GHR_P),
        .SEL_FORCE(SEL_FORCE_P),
        .CKPT_NUM (CKPT_NUM),
        .RAS_DEPTH(RAS_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc0(lu_pc0), .lu_pc1(lu_pc1),
        .lu_valid_o(lu_valid_o), .lu_taken0(lu_taken0), .lu_taken1(lu_taken1),
        .lu_gdir0(lu_gdir0), .lu_gdir1(lu_gdir1),
        .lu_ldir0(lu_ldir0), .lu_ldir1(lu_ldir1),
        .lu_selg0(lu_selg0), .lu_selg1(lu_selg1),
        .lu_btb_hit(lu_btb_hit), .lu_btb_way(lu_btb_way), .lu_btb_target(lu_btb_target),
        .lu_btb_cond(lu_btb_cond), .lu_btb_call(lu_btb_call), .lu_btb_ret(lu_btb_ret),
        .lu_ras_top(lu_ras_top), .lu_ras_empty(lu_ras_empty), .lu_pack_o(lu_pack_o),
        .ras_push_valid(ras_push_valid), .ras_push_addr(ras_push_addr),
        .ras_pop_valid(ras_pop_valid), .ras_pop_addr(ras_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr),
        .ras_flush_all(ras_flush_all),
        .ras_cmt_push_valid(ras_cmt_push_valid), .ras_cmt_pop_valid(ras_cmt_pop_valid),
        .train_valid(train_valid), .train_pc(train_pc),
        .train_is_cond(train_is_cond), .train_taken(train_taken),
        .train_is_indirect(train_is_indirect), .train_is_call(train_is_call),
        .train_is_return(train_is_return), .train_target(train_target),
        .train_pred_taken(train_pred_taken), .train_pred_sel_global(train_pred_sel_global),
        .train_pred_gdir(train_pred_gdir), .train_pred_ldir(train_pred_ldir),
        .train_pred_target(train_pred_target), .train_pred_valid(train_pred_valid),
        .train_btb_hit(train_btb_hit), .train_btb_way(train_btb_way),
        .train_ready(train_ready), .upd_busy(upd_busy),
        .ckpt_alloc_valid(ckpt_alloc_valid), .ckpt_alloc_pc(ckpt_alloc_pc),
        .ckpt_alloc_id(ckpt_alloc_id), .ckpt_full(ckpt_full),
        .ckpt_free_valid(ckpt_free_valid), .ckpt_free_id(ckpt_free_id),
        .ckpt_restore_valid(ckpt_restore_valid), .ckpt_restore_id(ckpt_restore_id),
        .bpu_br_total(bpu_br_total), .bpu_br_mispred(bpu_br_mispred),
        .bpu_dir_mispred(bpu_dir_mispred), .bpu_target_mispred(bpu_target_mispred),
        .bpu_gshare_right(bpu_gshare_right), .bpu_local_right(bpu_local_right),
        .bpu_sel_global(bpu_sel_global), .bpu_sel_local(bpu_sel_local),
        .bpu_ras_push(bpu_ras_push), .bpu_ras_pop(bpu_ras_pop),
        .bpu_ras_overflow(bpu_ras_overflow), .bpu_ras_repair(bpu_ras_repair),
        .bpu_ckpt_full_stall(bpu_ckpt_full_stall),
        .bpu_train_overflow(bpu_train_overflow), .bpu_btb_alloc(bpu_btb_alloc),
        .ghr_o(ghr_o)
    );

    //--------------------------------------------------------------------------
    // 时钟 / 复位
    //--------------------------------------------------------------------------
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_FRONT4_PREDICTOR 判据不满足");
            end
        end
    endtask

    task automatic chk_eq32(input [31:0] got, input [31:0] exp, input string msg);
        begin
            n_checks = n_checks + 1;
            if (got !== exp) begin
                $display("FAIL: %s 期望 0x%08x 实得 0x%08x（第 %0d 项）", msg, exp, got, n_checks);
                $fatal(1, "TB_FRONT4_PREDICTOR 判据不满足");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 基本操作任务
    //--------------------------------------------------------------------------
    // 查表：地址在本拍给出，结果下一拍有效（同步读，04 §4.2 口径）
    reg        r_pred, r_gdir, r_ldir, r_selg, r_bhit, r_bway;
    reg [31:0] r_btarget, r_rastop;
    reg        r_rasempty;
    task automatic lookup(input [31:0] pc);
        begin
            @(negedge clk);
            lu_en = 1'b1; lu_pc0 = pc; lu_pc1 = pc + 32'd2;
            @(posedge clk); #1;
            r_pred    = lu_taken0;      // trace 里所有分支都按 4 B 对齐（parcel0）
            r_gdir    = lu_gdir0;
            r_ldir    = lu_ldir0;
            r_selg    = lu_selg0;
            r_bhit    = lu_btb_hit;
            r_bway    = lu_btb_way;
            r_btarget = lu_btb_target;
            r_rastop  = lu_ras_top;
            r_rasempty= lu_ras_empty;
            @(negedge clk);
            lu_en = 1'b0;
        end
    endtask

    // 等训练引擎排空（FIFO 空 + 所有更新定序完成）
    task automatic drain_upd;
        integer guard;
        begin
            guard = 0;
            while ((upd_busy !== 1'b0) && (guard < 1000)) begin
                @(posedge clk); guard = guard + 1;
            end
            if (guard >= 1000) begin
                $display("FAIL: 训练引擎超过 1000 拍未排空（疑似挂死）");
                $fatal(1, "TB_FRONT4_PREDICTOR 判据不满足");
            end
            @(negedge clk);
        end
    endtask

    // 提交训练（1 条/事件；携带"预测时"记录）
    task automatic train_ev(input [31:0] pc,
                            input        is_cond, input tk,
                            input        is_call, input is_ret, input is_ind,
                            input [31:0] target,
                            input        p_taken, input p_selg, input p_gdir, input p_ldir,
                            input        p_valid, input [31:0] p_target,
                            input        b_hit, input b_way);
        begin
            @(negedge clk);
            train_valid         = 1'b1;
            train_pc            = pc;
            train_is_cond       = is_cond;
            train_taken         = tk;
            train_is_call       = is_call;
            train_is_return     = is_ret;
            train_is_indirect   = is_ind;
            train_target        = target;
            train_pred_taken    = p_taken;
            train_pred_sel_global = p_selg;
            train_pred_gdir     = p_gdir;
            train_pred_ldir     = p_ldir;
            train_pred_valid    = p_valid;
            train_pred_target   = p_target;
            train_btb_hit       = b_hit;
            train_btb_way       = b_way;
            @(posedge clk);
            @(negedge clk);
            train_valid         = 1'b0;
            drain_upd();
        end
    endtask

    // RAS 压/弹（D2 侧）
    task automatic ras_push(input [31:0] a);
        begin
            @(negedge clk); ras_push_valid = 1'b1; ras_push_addr = a;
            @(posedge clk);
            @(negedge clk); ras_push_valid = 1'b0;
        end
    endtask
    task automatic ras_pop(input [31:0] a);
        begin
            @(negedge clk); ras_pop_valid = 1'b1; ras_pop_addr = a;
            @(posedge clk);
            @(negedge clk); ras_pop_valid = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // 轨迹事件数组（自造轨迹；每类 ≥3 种模式，见 B 段）
    //--------------------------------------------------------------------------
    reg [31:0] ev_pc  [0:MAX_EV-1];
    reg        ev_tk  [0:MAX_EV-1];
    reg [1:0]  ev_cls [0:MAX_EV-1];
    reg [3:0]  ev_prd [0:MAX_EV-1];     // {pred, selg, ldir, gdir}：预测时记录
    reg        ev_bh  [0:MAX_EV-1];
    reg        ev_bw  [0:MAX_EV-1];
    integer    n_ev;
    integer    i;

    task automatic emit(input [31:0] pc, input tk, input [1:0] c);
        begin
            if (n_ev < MAX_EV) begin
                ev_pc[n_ev]  = pc;
                ev_tk[n_ev]  = tk;
                ev_cls[n_ev] = c;
                n_ev = n_ev + 1;
            end else begin
                $display("FAIL: 轨迹事件数超出数组容量 %0d", MAX_EV);
                $fatal(1, "TB_FRONT4_PREDICTOR 容量不足");
            end
        end
    endtask

    // 确定性 LCG（不依赖 $random 的跨仿真器差异）
    reg [31:0] lcg;
    function automatic bit lcg_bit();
        begin
            lcg = lcg * 32'd1664525 + 32'd1013904223;
            lcg_bit = lcg[30];              // 取中间位，避免低位周期短
        end
    endfunction

    // ---- 轨迹 PID（避免各类互相干扰）----
    localparam [31:0] PC_LOOP_O = 32'h0000_1000;
    localparam [31:0] PC_LOOP_M = 32'h0000_1040;
    localparam [31:0] PC_LOOP_I = 32'h0000_1080;
    localparam [31:0] PC_BODY   = 32'h0000_10C0;
    localparam [31:0] PC_CALL   = 32'h0000_2000;
    localparam [31:0] PC_CLOOP  = 32'h0000_2040;
    localparam [31:0] PC_RET    = 32'h0000_2080;
    //   ★ PC_ALT* 取值避开 A1/A2 已训练过的索引（选择器/LHT 表只在上电时按初值初始化，
    //     `rst_n` 不复位表内容——与 BRAM/分布式 RAM 的真实行为一致）
    localparam [31:0] PC_ALT0   = 32'h0000_3800;
    localparam [31:0] PC_ALT1   = 32'h0000_3840;
    localparam [31:0] PC_ALT2   = 32'h0000_3880;
    localparam [31:0] PC_X1     = 32'h0000_4000;   // "全局强"支路的噪声源
    localparam [31:0] PC_F1     = 32'h0000_4040;
    localparam [31:0] PC_F2     = 32'h0000_4080;
    localparam [31:0] PC_F3     = 32'h0000_40C0;
    localparam [31:0] PC_F4     = 32'h0000_4100;
    localparam [31:0] PC_G      = 32'h0000_4140;   // 方向 = PC_X1 的方向（相隔 4 条）⇒ 全局强
    localparam [31:0] PC_G1     = 32'h0000_4140;   // 方向 = 4 条之前的 PC_X1
    localparam [31:0] PC_G2     = 32'h0000_4180;   // 方向 = 4 条之前的 PC_F1
    localparam [31:0] PC_G3     = 32'h0000_41C0;
    localparam [31:0] PC_G4     = 32'h0000_4200;
    localparam [31:0] PC_RND    = 32'h0000_5000;   // 纯随机方向（两侧都学不会）
    localparam [31:0] PC_IND    = 32'h0000_6000;   // 间接跳转（恒 taken，测 BTB 目标）

    // ---- B1 loop：嵌套循环（内层行程 4/8/16/32 轮转） ----
    task automatic gen_loop(input integer outer);
        integer o, k, trip;
        begin
            for (o = 0; o < outer; o = o + 1) begin
                emit(PC_LOOP_O, (o != outer-1), CLS_COND);         // 外层回边
                for (k = 0; k < 4; k = k + 1) begin                // 内层 4 种行程
                    trip = 1 << (2 + k);                           // 4/8/16/32
                    begin : mid
                        integer m;
                        for (m = 0; m < 3; m = m + 1) begin
                            emit(PC_LOOP_M, (m != 2), CLS_COND);   // 中层回边
                            begin : inr
                                integer q;
                                for (q = 0; q < trip; q = q + 1) begin
                                    emit(PC_LOOP_I, (q != trip-1), CLS_COND);   // 内层回边
                                    emit(PC_BODY, (((q + m) % 5) != 0), CLS_COND); // 周期 5
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    // ---- B2 callret：调用-返回（深度 1..6，含 RAS 溢出） ----
    task automatic gen_callret(input integer rounds);
        integer r, d, w;
        begin
            for (r = 0; r < rounds; r = r + 1) begin
                d = (r % 8) + 1;                      // 深度 1..8（>16 项的溢出由 §A5 覆盖）
                for (w = 0; w < d; w = w + 1) emit(PC_CALL, 1'b1, CLS_CALL);
                begin : cl
                    integer q;
                    for (q = 0; q < 3; q = q + 1) begin
                        emit(PC_CLOOP, (q != 2), CLS_COND);          // 被调函数里的短循环
                        emit(PC_BODY, ((q % 2) == 0), CLS_COND);
                    end
                end
                for (w = 0; w < d; w = w + 1) begin
                    emit(PC_RET, 1'b1, CLS_RET);
                    if ((w % 3) == 2) emit(PC_BODY, ((w % 4) != 0), CLS_COND);
                end
            end
        end
    endtask

    // ---- B3 alt：三个 PC 各自周期 3/5/7 的方向模式轮转（局部强、全局弱） ----
    task automatic gen_alt(input integer rounds);
        integer a, b;
        begin : alt_outer
            for (a = 0; a < rounds; a = a + 1) begin
                for (b = 0; b < 105; b = b + 1) begin
                    if ((b % 3) == 0) emit(PC_ALT0, ((a % 3) != 0), CLS_COND);  // 周期 3
                    if ((b % 5) == 0) emit(PC_ALT1, (((a + 1) % 5) != 0), CLS_COND); // 周期 5
                    if ((b % 7) == 0) emit(PC_ALT2, (((a + 2) % 7) != 0), CLS_COND); // 周期 7
                end
            end
        end
    endtask

    // ---- B4a "全局强"支路（Gshare 学得会、局部学不会）----
    //   一轮 9 条：A,B,C,D（随机）、E（恒 taken）、G1..G4（= A,B,C,D）
    //   关键：Gk 的**方向来自 4 条之前那条分支**，那一拍恰好落在 GHR[4]，
    //   而 04 §3.1 的 Gshare 索引 PC[13:2] XOR GHR[15:4] **包含 bit4**
    //   ⇒ 索引里带着答案 ⇒ Gshare 逐条学得会；Gk 自己的 10 位局部历史只是
    //   上一轮的随机值 ⇒ 局部侧接近瞎猜（这正是 04 §1 "局部分量在噪声下弱"）。
    task automatic gen_gsharefav(input integer rounds);
        integer r;
        reg a, b, c, d;
        begin
            for (r = 0; r < rounds; r = r + 1) begin
                a = lcg_bit(); b = lcg_bit(); c = lcg_bit(); d = lcg_bit();
                emit(PC_X1, a, CLS_COND);      // A
                emit(PC_F1, b, CLS_COND);      // B
                emit(PC_F2, c, CLS_COND);      // C
                emit(PC_F3, d, CLS_COND);      // D
                emit(PC_F4, 1'b1, CLS_COND);   // E（恒 taken，把 A..D 顶到 bit≥4）
                emit(PC_G1, a, CLS_COND);      // = A（bit4 = A）
                emit(PC_G2, b, CLS_COND);      // = B
                emit(PC_G3, c, CLS_COND);      // = C
                emit(PC_G4, d, CLS_COND);      // = D
            end
        end
    endtask

    // ---- B4b 噪声：纯随机方向 ----
    task automatic gen_noise(input integer rounds);
        integer r;
        begin
            for (r = 0; r < rounds; r = r + 1) emit(PC_RND, lcg_bit(), CLS_COND);
        end
    endtask

    // ---- B4c 间接跳转（BTB 目标训练） ----
    task automatic gen_indirect(input integer rounds);
        integer r;
        begin
            for (r = 0; r < rounds; r = r + 1) begin
                emit(PC_RND, lcg_bit(), CLS_COND);
                emit(PC_IND, 1'b1, CLS_IND);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 轨迹执行：逐条"查表 → 记分 →（滞后窗口外的事件）提交训练"
    //   滞后模型：预测第 i 条时，表状态 = 已训练 0..i-1-LAG（04 §5.3 的 GHR 滞后）
    //--------------------------------------------------------------------------
    integer cnt_total, cnt_sel_mis, cnt_g_mis, cnt_l_mis;
    // D2 侧模型（trace 驱动时需要它来维护 RAS）：与架构一致的返回地址栈
    reg [31:0] ret_stack [0:63];
    integer    ret_sp;
    integer cnt_selg, cnt_sell;
    integer cnt_tk_actual;

    task automatic reset_trace_counters;
        begin
            cnt_total = 0; cnt_sel_mis = 0; cnt_g_mis = 0; cnt_l_mis = 0;
            cnt_selg = 0; cnt_sell = 0; cnt_tk_actual = 0;
        end
    endtask

    // 训练第 k 个事件（用其预测时记录）
    task automatic train_index(input integer k);
        reg [31:0] tgt;
        begin
            // 合成轨迹里调用/返回/间接跳转**没有真实指令位**，其目标不由本 TB 建模：
            //   因此对非条件事件统一上报"预测正确"（p_taken=1、p_valid=1、
            //   p_target=实际目标），使硬件 bpu_br_mispred 的口径与 TB 的"条件分支
            //   方向误判"完全对齐（否则硬件会把非条件事件也算成误判，交叉核对失真）。
            tgt = (ev_cls[k] == CLS_CALL) ? ev_pc[k] + 32'd4 :
                  ((ev_cls[k] == CLS_RET) ? 32'h0000_2004 : 32'h0000_6004);
            train_ev(ev_pc[k], (ev_cls[k] == CLS_COND), ev_tk[k],
                     (ev_cls[k] == CLS_CALL), (ev_cls[k] == CLS_RET), (ev_cls[k] == CLS_IND),
                     tgt,
                     (ev_cls[k] == CLS_COND) ? ev_prd[k][3] : 1'b1,
                     ev_prd[k][2], ev_prd[k][0], ev_prd[k][1],
                     (ev_cls[k] == CLS_COND) ? 1'b0 : 1'b1,
                     tgt,
                     ev_bh[k], ev_bw[k]);
        end
    endtask

    // 注意：ev_prd 编码 = {pred, selg, ldir, gdir}（bit0=gdir, bit1=ldir, bit2=selg, bit3=pred）
    task automatic run_trace(input integer n, input integer lag);
        integer k, t;
        reg    pred_w, gdir_w, ldir_w, selg_w;
        begin
            ret_sp = 0;
            // 预测阶段：逐条查表（训练滞后 lag 条）
            for (k = 0; k < n; k = k + 1) begin
                t = k - 1 - lag;
                if (t >= 0) train_index(t);           // 窗口外的提交训练
                lookup(ev_pc[k]);
                ev_prd[k][0] = r_gdir;
                ev_prd[k][1] = r_ldir;
                ev_prd[k][2] = r_selg;
                ev_prd[k][3] = SEL_FORCE_P == 1 ? r_gdir :
                               (SEL_FORCE_P == 2 ? r_ldir : r_pred);
                ev_bh[k]     = r_bhit;
                ev_bw[k]     = r_bway;
                // 记分（只对条件分支计入方向准确率，口径同 04 §6.1 bpu_br_total）
                // ---- D2 侧：调用压栈 / 返回弹栈（与架构顺序一致，驱动 RAS）----
                if (ev_cls[k] == CLS_CALL) begin
                    ret_stack[ret_sp] = ev_pc[k] + 32'd4;
                    if (ret_sp < 63) ret_sp = ret_sp + 1;
                    ras_push(ev_pc[k] + 32'd4);
                end else if (ev_cls[k] == CLS_RET) begin
                    if (ret_sp > 0) begin
                        ret_sp = ret_sp - 1;
                        ras_pop(ret_stack[ret_sp]);
                    end else begin
                        ras_pop(32'h0);
                    end
                end
                if (ev_cls[k] == CLS_COND) begin
                    pred_w = SEL_FORCE_P == 1 ? r_gdir : (SEL_FORCE_P == 2 ? r_ldir : r_pred);
                    gdir_w = r_gdir;
                    ldir_w = r_ldir;
                    selg_w = SEL_FORCE_P == 1 ? 1'b1 : (SEL_FORCE_P == 2 ? 1'b0 : r_selg);
                    cnt_total = cnt_total + 1;
                    if (ev_tk[k]) cnt_tk_actual = cnt_tk_actual + 1;
                    if (selg_w) cnt_selg = cnt_selg + 1; else cnt_sell = cnt_sell + 1;
                    if (pred_w !== ev_tk[k]) cnt_sel_mis = cnt_sel_mis + 1;
                    if (gdir_w !== ev_tk[k]) cnt_g_mis = cnt_g_mis + 1;
                    if (ldir_w !== ev_tk[k]) cnt_l_mis = cnt_l_mis + 1;
                end
            end
            // 收尾：把剩余事件训练掉
            for (t = (n-1-lag); t < n; t = t + 1) if (t >= 0) train_index(t);
        end
    endtask

    //--------------------------------------------------------------------------
    // 保存/恢复：DUT 计数器在每条轨迹前后清零（用 rst_n 复位整个 DUT，
    //   但 §A 段的状态也要清 ⇒ 每段轨迹前复位，避免互相污染）
    //--------------------------------------------------------------------------
    task automatic dut_reset;
        begin
            rst_n = 1'b0;
            lu_en = 1'b0; lu_pc0 = 32'h0; lu_pc1 = 32'h0;
            ras_push_valid = 1'b0; ras_push_addr = 32'h0;
            ras_pop_valid = 1'b0;  ras_pop_addr = 32'h0;
            ras_flush_all = 1'b0; ras_cmt_push_valid = 1'b0; ras_cmt_pop_valid = 1'b0;
            train_valid = 1'b0; train_pc = 32'h0;
            train_is_cond = 1'b0; train_taken = 1'b0; train_is_indirect = 1'b0;
            train_is_call = 1'b0; train_is_return = 1'b0; train_target = 32'h0;
            train_pred_taken = 1'b0; train_pred_sel_global = 1'b0;
            train_pred_gdir = 1'b0; train_pred_ldir = 1'b0;
            train_pred_target = 32'h0; train_pred_valid = 1'b0;
            train_btb_hit = 1'b0; train_btb_way = 1'b0;
            ckpt_alloc_valid = 1'b0; ckpt_alloc_pc = 32'h0;
            ckpt_free_valid = 1'b0; ckpt_free_id = 4'h0;
            ckpt_restore_valid = 1'b0; ckpt_restore_id = 4'h0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer lag_eval;
    real    acc_loop, acc_call, acc_alt, acc_mixed, acc_mixed_lag;
    integer mis_mixed, mis_mixed_g, mis_mixed_l;
    integer selg_pct, sell_pct;

    initial begin
        n_checks = 0;
        lcg      = 32'h1234_5678;
        dut_reset();

        //======================================================================
        // A4 BTB：命中/目标 + 2 路 LRU 替换
        //======================================================================
        $display("== A4 BTB（2048 项 / 2 路 / LRU）");
        dut_reset();
        lookup(32'h0000_8000);
        chk(r_bhit === 1'b0, "A4 从未分配过的 PC 不应命中 BTB");
        // 同组三支：PC 相差 0x2000（PC[12:2] 相同）
        train_ev(PC_CALL, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 32'h0000_9000,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 32'h0, 1'b0, 1'b0);
        lookup(PC_CALL);
        chk(r_bhit === 1'b1, "A4 提交后 BTB 必须命中");
        chk(r_btarget === 32'h0000_9000, "A4 BTB 目标必须等于提交时写入的目标");
        // 第二支（同组，另一路）
        train_ev(PC_CALL + 32'h2000, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 32'h0000_A000,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 32'h0, 1'b0, 1'b0);   // b_hit=0：取指时未命中
        lookup(PC_CALL + 32'h2000);
        chk(r_bhit === 1'b1, "A4 同组第二支必须命中（2 路相联）");
        chk(r_btarget === 32'h0000_A000, "A4 第二支目标正确");
        // 再访问第一支（刷新 LRU：way0 变 MRU）
        lookup(PC_CALL);
        chk(r_bhit === 1'b1, "A4 第一支仍命中");
        // 第三支（同组）：应替换 LRU 路（= way1，即第二支）
        train_ev(PC_CALL + 32'h4000, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 32'h0000_B000,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 32'h0, 1'b0, 1'b0);   // b_hit=0：第三支未命中
        lookup(PC_CALL + 32'h4000);
        chk(r_bhit === 1'b1, "A4 第三支（替换后）必须命中");
        lookup(PC_CALL);
        chk(r_bhit === 1'b1, "A4 LRU 语义：最近用过的第一支必须仍在（未被替换）");
        lookup(PC_CALL + 32'h2000);
        chk(r_bhit === 1'b0, "A4 LRU 语义：最久未用的第二支应被替换掉");

        //======================================================================
        // A1. Gshare：饱和计数器翻转 + GHR 移位内容
        //======================================================================
        $display("== A1 Gshare（GPHT 2 bit 饱和 / GHR 16 bit 移位）");
        lookup(32'h0000_1000);
        chk(r_gdir === 1'b0, "A1 复位后首次预测必须为 not-taken（弱不跳初值）");

        train_ev(32'h0000_1000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(32'h0000_1000);
        chk(r_gdir === 1'b1, "A1 taken 训练一次后必须预测 taken");

        train_ev(32'h0000_1000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(32'h0000_1000, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(32'h0000_1000);
        chk(r_gdir === 1'b1, "A1 饱和计数 v=3 后来一次 not-taken 仍应预测 taken");

        train_ev(32'h0000_1000, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(32'h0000_1000);
        chk(r_gdir === 1'b0, "A1 两次 not-taken 后必须回到 not-taken");

        dut_reset();
        train_ev(32'h0000_1100, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(32'h0000_1104, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(32'h0000_1108, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(32'h0000_110C, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        drain_upd();
        chk_eq32({16'h0, ghr_o}, 32'h0000_000A, "A1 GHR 移位内容（T,N,T,N ⇒ 0xA）");

        //======================================================================
        // A2 局部：LHT 10 位历史内容 + LPHT 收敛
        //======================================================================
        $display("== A2 局部历史（LHT 10 bit / LPHT）");
        dut_reset();
        // T,T,T,N 重复两遍 ⇒ LHT = 0b00_0111_0111（LSB = 最近一次）
        train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        train_ev(PC_LOOP_I, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        drain_upd();
        // LHT 组合读（查表同拍有效）：再做一次查表，在请求拍采样 lht 值
        @(negedge clk); lu_en = 1'b1; lu_pc0 = PC_LOOP_I; lu_pc1 = PC_LOOP_I + 32'd2;
        #1;
        @(posedge clk); #1;
        @(negedge clk); lu_en = 1'b0;
        // 收敛检查：再训练 8 个周期（T,T,T,N ×8 ⇒ 累计 40 条），随后"训练一条 → 查表一次"
        //   交替 4 步，局部侧预测必须与模式逐拍一致（LPHT 真的学会了周期 4）
        begin : lpht_conv
            integer cyc, step;
            for (cyc = 0; cyc < 8; cyc = cyc + 1) begin
                train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                         1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
                train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                         1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
                train_ev(PC_LOOP_I, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                         1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
                train_ev(PC_LOOP_I, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                         1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
            end
            // 4 步交替：期望模式为 T,T,T,N（从第 1 个 T 开始）
            for (step = 0; step < 4; step = step + 1) begin
                lookup(PC_LOOP_I);
                chk(r_ldir === ((step != 3) ? 1'b1 : 1'b0),
                    "A2 周期 4 模式收敛后局部侧预测必须逐拍正确（LPHT）");
                train_ev(PC_LOOP_I, 1'b1, ((step != 3) ? 1'b1 : 1'b0),
                         1'b0, 1'b0, 1'b0, 32'h0,
                         1'b1, 1'b0, ((step != 3) ? 1'b1 : 1'b0), 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
            end
        end

        //======================================================================
        // A3 选择器：状态机 4 条转移 + 复位值
        //======================================================================
        $display("== A3 选择器状态机（04 §3.2）");
        dut_reset();
        lookup(PC_ALT0);
        chk(r_selg === 1'b0, "A3 复位值必须偏局部（2'b01 ⇒ selg=0）");
        // 全局对、局部错 ⇒ 偏全局
        train_ev(PC_ALT0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1 /*gdir=1 对*/, 1'b0 /*ldir=0 错*/, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(PC_ALT0);
        chk(r_selg === 1'b1, "A3 全局对/局部错 ⇒ 选择器应偏全局");
        // 再一次同向 ⇒ 强偏全局（仍 selg=1）
        train_ev(PC_ALT0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(PC_ALT0);
        chk(r_selg === 1'b1, "A3 强偏全局（2'b11）");
        // 局部对、全局错 ⇒ 回偏局部
        train_ev(PC_ALT0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b0 /*gdir错*/, 1'b1 /*ldir对*/, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(PC_ALT0);
        chk(r_selg === 1'b1, "A3 弱偏全局（2'b10）");
        train_ev(PC_ALT0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(PC_ALT0);
        chk(r_selg === 1'b0, "A3 局部对/全局错 两次 ⇒ 应偏局部");
        // 两侧都对 ⇒ 不变
        train_ev(PC_ALT0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(PC_ALT0);
        chk(r_selg === 1'b0, "A3 两侧都对 ⇒ 计数器不变（仍偏局部）");
        // 两侧都错 ⇒ 不变
        train_ev(PC_ALT0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                 1'b0, 1'b0, 1'b1 /*gdir 对实际 0 而言错*/, 1'b1, 1'b0, 32'h0, 1'b0, 1'b0);
        lookup(PC_ALT0);
        chk(r_selg === 1'b0, "A3 两侧都错 ⇒ 计数器不变");

        //======================================================================
        // A5 RAS：溢出不压入 / D2 修复 / 检查点深度恢复 / 全冲刷
        //======================================================================
        $display("== A5 RAS（16 项 / 溢出不压入 / 修复 / 快照恢复）");
        dut_reset();
        for (i = 0; i < RAS_DEPTH + 4; i = i + 1) ras_push(32'h0000_7000 + i*4);
        chk(bpu_ras_overflow === 32'd4, "A5 溢出 4 次必须计入 bpu_ras_overflow（且不再压入）");
        chk(lu_ras_empty === 1'b0, "A5 压入后栈非空");
        // 栈顶应仍是第 16 次压入的值（溢出项不覆盖）
        @(negedge clk); #1;
        chk(dut.u_ras.stk[RAS_DEPTH-1] === (32'h0000_7000 + (RAS_DEPTH-1)*4),
            "A5 溢出时栈顶保持（不覆盖最老项）");
        // D2 修复：实际返回地址 ≠ 栈顶
        ras_pop(32'hDEAD_BEE0);
        chk(bpu_ras_repair === 32'd1, "A5 实际返回地址 ≠ 栈顶 ⇒ 必须报 ras_repair");
        // 弹出后栈深 = 15（再弹一次需匹配新栈顶）
        ras_pop(32'h0000_7000 + (RAS_DEPTH-2)*4);
        chk(bpu_ras_repair === 32'd1, "A5 修复次数累计 1（第二次弹出匹配 ⇒ 不再增加）");

        // 检查点深度恢复
        dut_reset();
        ras_push(32'h1111_0000);
        ras_push(32'h2222_0000);
        @(negedge clk); ckpt_alloc_valid = 1'b1; ckpt_alloc_pc = PC_CALL; @(posedge clk);
        @(negedge clk); ckpt_alloc_valid = 1'b0;
        begin : ck_ack
            integer g2;
            g2 = 0;
            while (ckpt_full && (g2 < 10)) begin @(posedge clk); g2 = g2 + 1; end
        end
        ras_push(32'h3333_0000);      // 快照之后又压了一个
        chk(dut.u_ras.depth_o === 5'd3, "A5 快照后深度应为 3");
        // 按检查点 0（快照 = 深度 2）恢复
        @(negedge clk); ckpt_restore_valid = 1'b1; ckpt_restore_id = 4'h0;
        @(posedge clk);
        @(negedge clk); ckpt_restore_valid = 1'b0;
        #1;
        chk(dut.u_ras.depth_o === 5'd2, "A5 检查点恢复必须把 RAS 深度还原到快照值 2");

        // 全冲刷 ⇒ 回已提交深度
        ras_cmt_push_valid = 1'b1; @(posedge clk); @(negedge clk); ras_cmt_push_valid = 1'b0;
        ras_flush_all = 1'b1; @(posedge clk); @(negedge clk); ras_flush_all = 1'b0;
        #1;
        chk(dut.u_ras.depth_o === 5'd1, "A5 全冲刷后深度必须回到已提交深度 1");

        //======================================================================
        // A6 检查点：分配满 / 释放 / 无效 id
        //======================================================================
        $display("== A6 检查点表（16 项）");
        dut_reset();
        // ---- ① 未分配 id 的恢复必须无副作用（此时一项都没分配）----
        ras_push(32'h5555_0000);
        #1;
        chk(dut.u_ras.depth_o === 5'd1, "A6 构造：push 后深度 1");
        @(negedge clk); ckpt_restore_valid = 1'b1; ckpt_restore_id = 4'hC; @(posedge clk);
        @(negedge clk); ckpt_restore_valid = 1'b0;
        #1;
        chk(dut.u_ras.depth_o === 5'd1, "A6 未分配检查点的恢复必须无副作用（RAS 深度不变）");
        // ---- ② 分配满 16 项 ----
        for (i = 0; i < CKPT_NUM; i = i + 1) begin
            @(negedge clk); ckpt_alloc_valid = 1'b1; ckpt_alloc_pc = PC_CALL + i*4; @(posedge clk);
        end
        @(negedge clk); ckpt_alloc_valid = 1'b0;
        #1;
        chk(ckpt_full === 1'b1, "A6 分配满 16 项后 ckpt_full 必须为 1");
        // ---- ③ 满后再分配一次：计入 bpu_ckpt_full_stall，且状态不变 ----
        @(negedge clk); ckpt_alloc_valid = 1'b1; ckpt_alloc_pc = 32'h0; @(posedge clk);
        @(negedge clk); ckpt_alloc_valid = 1'b0;
        #1;
        chk(ckpt_full === 1'b1, "A6 满时再分配仍应为 full");
        chk(bpu_ckpt_full_stall === 32'd1, "A6 耗尽尝试必须计入 bpu_ckpt_full_stall");
        // ---- ④ 释放后可再分配，且最低编号优先 ----
        @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = 4'd5; @(posedge clk);
        @(negedge clk); ckpt_free_valid = 1'b0;
        #1;
        chk(ckpt_full === 1'b0, "A6 释放 1 项后不再 full");
        chk(ckpt_alloc_id === 4'd5, "A6 空闲项按最低编号优先（应为 5）");

        //======================================================================
        // A7 GHR 恢复（方案 B）/ 不回滚（方案 A）
        //======================================================================
        $display("== A7 GHR 恢复（SPEC_GHR_P=%0d）", SPEC_GHR_P);
        dut_reset();
        ras_push(32'h6666_0000);
        @(negedge clk); ckpt_alloc_valid = 1'b1; ckpt_alloc_pc = PC_CALL; @(posedge clk);
        @(negedge clk); ckpt_alloc_valid = 1'b0;
        repeat (2) @(posedge clk);
        begin : ghr_a
            reg [15:0] ghr_snap;
            ghr_snap = ghr_o;
            train_ev(PC_F1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0,
                     1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
            train_ev(PC_F2, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0,
                     1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0, 1'b0);
            chk(ghr_o !== ghr_snap, "A7 训练两条后 GHR 必须前进");
            @(negedge clk); ckpt_restore_valid = 1'b1; ckpt_restore_id = 4'h0; @(posedge clk);
            @(negedge clk); ckpt_restore_valid = 1'b0;
            repeat (2) @(posedge clk);
            if (SPEC_GHR_P == 1)
                chk(ghr_o === ghr_snap, "A7 方案 B：检查点恢复必须回滚 GHR");
            else
                chk(ghr_o !== ghr_snap, "A7 方案 A（默认）：GHR 只由提交点推进，恢复不回滚");
        end

        //======================================================================
        // B 段：准确率统计（4 类轨迹）
        //======================================================================
        // B1 loop
        dut_reset(); n_ev = 0; lcg = 32'h1234_5678;
        gen_loop(6);
        reset_trace_counters();
        run_trace(n_ev, LAG_P);
        acc_loop = (cnt_total - cnt_sel_mis) * 100.0 / cnt_total;
        $display("B1 loop  : 条件分支 %0d 条，锦标赛误判 %0d，准确率 %.2f%%（Gshare %.2f%% / 局部 %.2f%%）",
                 cnt_total, cnt_sel_mis, acc_loop,
                 (cnt_total - cnt_g_mis)*100.0/cnt_total, (cnt_total - cnt_l_mis)*100.0/cnt_total);
        chk(cnt_total > 2000, "B1 loop 轨迹样本量必须 > 2000（避免小样本假信号）");
        chk(acc_loop >= 80.0, "B1 loop 锦标赛方向准确率必须 ≥ 80%");
        chk_eq32(bpu_br_total, cnt_total, "B1 硬件 bpu_br_total 必须等于 TB 统计的条件分支数");

        // B2 callret
        dut_reset(); n_ev = 0;
        gen_callret(120);
        reset_trace_counters();
        run_trace(n_ev, LAG_P);
        acc_call = (cnt_total - cnt_sel_mis) * 100.0 / cnt_total;
        $display("B2 callret: 条件分支 %0d 条，锦标赛误判 %0d，准确率 %.2f%%",
                 cnt_total, cnt_sel_mis, acc_call);
        chk(bpu_ras_push > 32'd100, "B2 RAS 压栈次数必须 > 100（覆盖调用序列）");
        chk(acc_call >= 80.0, "B2 callret 锦标赛方向准确率必须 ≥ 80%");

        // B3 alt（交错方向：局部强、全局弱）
        dut_reset(); n_ev = 0;
        gen_alt(30);
        reset_trace_counters();
        run_trace(n_ev, LAG_P);
        acc_alt = (cnt_total - cnt_sel_mis) * 100.0 / cnt_total;
        $display("B3 alt    : 条件分支 %0d 条，锦标赛误判 %0d，准确率 %.2f%%（Gshare %.2f%% / 局部 %.2f%%）",
                 cnt_total, cnt_sel_mis, acc_alt,
                 (cnt_total - cnt_g_mis)*100.0/cnt_total, (cnt_total - cnt_l_mis)*100.0/cnt_total);
        chk(acc_alt >= 80.0, "B3 alt 锦标赛方向准确率必须 ≥ 80%");
        //======================================================================
        // B6 分段证据：单独跑"全局强"支路（打印用，不作断言）
        //======================================================================
        dut_reset(); n_ev = 0; lcg = 32'h2468_ACE0;
        gen_gsharefav(200);
        reset_trace_counters();
        run_trace(n_ev, LAG_P);
        $display("B6 gsharefav 单独：条件分支 %0d 条，锦标赛 %.2f%%，Gshare %.2f%%，局部 %.2f%%",
                 cnt_total, (cnt_total-cnt_sel_mis)*100.0/cnt_total,
                 (cnt_total-cnt_g_mis)*100.0/cnt_total,
                 (cnt_total-cnt_l_mis)*100.0/cnt_total);


        // B4 mixed（loop+callret+alt+全局强支路+噪声+间接）
        dut_reset(); n_ev = 0; lcg = 32'h2468_ACE0;
        gen_loop(2);
        gen_callret(10);
        gen_alt(24);
        gen_gsharefav(90);
        gen_noise(100);
        gen_indirect(100);
        reset_trace_counters();
        run_trace(n_ev, LAG_P);
        mis_mixed   = cnt_sel_mis;
        mis_mixed_g = cnt_g_mis;
        mis_mixed_l = cnt_l_mis;
        acc_mixed   = (cnt_total - cnt_sel_mis) * 100.0 / cnt_total;
        selg_pct    = (cnt_selg * 100) / cnt_total;
        sell_pct    = (cnt_sell * 100) / cnt_total;
        $display("B4 mixed  : 条件分支 %0d 条，锦标赛误判 %0d（准确率 %.2f%%）；",
                 cnt_total, cnt_sel_mis, acc_mixed);
        $display("            单独 Gshare 误判 %0d（%.2f%%）/ 单独局部误判 %0d（%.2f%%）",
                 mis_mixed_g, (cnt_total-mis_mixed_g)*100.0/cnt_total,
                 mis_mixed_l, (cnt_total-mis_mixed_l)*100.0/cnt_total);
        $display("            选择器偏向：全局 %0d%% / 局部 %0d%%",
                 selg_pct, sell_pct);
        chk(acc_mixed >= 80.0, "B4 mixed 锦标赛方向准确率必须 ≥ 80%");
        // 04 §6.3"反向实验"口径：选择器必须在混合负载上**明显**优于任一侧
        //   （判据：锦标赛误判 ≤ 各单侧的 90%；恒接一侧时该式必红）
        chk(mis_mixed * 100 <= mis_mixed_g * 90, "B4 锦标赛误判必须 ≤ 单独 Gshare 的 90%（选择器起作用）");
        chk(mis_mixed * 100 <= mis_mixed_l * 90, "B4 锦标赛误判必须 ≤ 单独局部的 90%（选择器起作用）");
        chk(selg_pct >= 10, "B4 选择器必须被使用（全局侧 ≥ 10%，04 §8）");
        chk(sell_pct >= 10, "B4 选择器必须被使用（局部侧 ≥ 10%，04 §8）");
        chk_eq32(bpu_br_total,   cnt_total,    "B4 硬件 bpu_br_total 与 TB 一致");
        chk_eq32(bpu_br_mispred, mis_mixed,    "B4 硬件 bpu_br_mispred 与 TB 一致");
        chk_eq32(bpu_dir_mispred,mis_mixed,    "B4 硬件 bpu_dir_mispred 与 TB 一致");
        chk_eq32(bpu_gshare_right, cnt_total - mis_mixed_g, "B4 硬件 bpu_gshare_right 与 TB 一致");
        chk_eq32(bpu_local_right,  cnt_total - mis_mixed_l, "B4 硬件 bpu_local_right 与 TB 一致");
        chk(bpu_sel_global + bpu_sel_local === cnt_total, "B4 bpu_sel_global+local 必须等于分支总数");
        chk(bpu_train_overflow === 32'd0, "B4 训练 FIFO 不得溢出");
        chk(bpu_ckpt_full_stall === 32'd0, "B4 不得因检查点耗尽停顿（本 TB 不分配检查点）");

        //======================================================================
        // B5 参考：滞后 LAG=4 下的同一轨迹（证据，不作断言）
        //======================================================================
        dut_reset(); n_ev = 0; lcg = 32'h2468_ACE0;
        gen_loop(2); gen_callret(10); gen_alt(24);
        gen_gsharefav(90); gen_noise(100); gen_indirect(100);
        reset_trace_counters();
        lag_eval = 4;
        run_trace(n_ev, lag_eval);
        acc_mixed_lag = (cnt_total - cnt_sel_mis) * 100.0 / cnt_total;
        $display("B5 同一混合轨迹在 LAG=%0d（04 §5.3 GHR 滞后模型）下：准确率 %.2f%%，误判 %0d",
                 lag_eval, acc_mixed_lag, cnt_sel_mis);

        //======================================================================
        // 汇总
        //======================================================================
        $display("== 检查项合计 %0d 项全部满足（SPEC_GHR=%0d SEL_FORCE=%0d LAG=%0d）",
                 n_checks, SPEC_GHR_P, SEL_FORCE_P, LAG_P);
        $display("TB_FRONT4_PREDICTOR: PASS");
        $finish;
    end

    // 超时兜底（挂死即失败；不打印 PASS）
    initial begin
        #(CLK_PERIOD * 4_000_000);
        $display("FAIL: TB 超时（%0d 拍）", 4_000_000);
        $fatal(1, "TB_FRONT4_PREDICTOR 超时");
    end

endmodule
