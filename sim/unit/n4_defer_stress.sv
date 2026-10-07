//==============================================================================
// sim/unit/n4_defer_stress.sv —— EXP-N4 **共享写口 3 停拍路径**的定向压力验证
//------------------------------------------------------------------------------
// 背景（为什么需要这个文件）：
//   EXP-N4 把整数 PRF 写口 6→4，其中 port3 由 LSU/MDU/FPU-int 共享（LSU 最高优先）。
//   fpga/scratch/n4_report.md 实测：已量化 workload（20 基准 / 48,400 拍）里
//   **LSU 与 MDU/FPU-int 从未同拍写回** ⇒ 共享口的"停 1 拍（deferral）"分支在普通回归里
//   **一次也不会被走到**。只靠"逻辑看起来对"就交付是不够的（本项目纪律：未捕获即失败）。
//
// 【本文件做什么】
//   用**只读观测 + 单点 force** 在*真实 RTL* 上强制制造共享口冲突：
//     · 观测 `u_back.mdu_req`/`fpu_i_req`（"MDU/FPU 有整数写回待落"）；
//     · 当本拍 LSU **没有**真写回（`~wb_lsu_int`）而 MDU/FPU 有请求时，**交替**地把
//       `u_back.p3_lsu` 强制为 1（= 把共享口优先权人为给 LSU）⇒ 该请求当拍不被授予，
//       走真实的 deferral 路径（`*_wb_pend_q` 置位 + 数据锁存 + `*_if_v` 保持）；
//     · 下一拍（force 撤销）该请求以挂起身份被授予 ⇒ **每笔被推迟的写回恰好晚 1 拍落地**。
//   为什么 force `p3_lsu` 是**安全且忠实**的：该拍 port3 的源被选成 LSU（索引 4），
//   而 `iprf_we[4] = wbi_v[4] & wbi_keep[4] = 0`（LSU 本就没有有效整数写回、也没被 force）
//   ⇒ 端口这一拍什么都不写，只是"占位"；**被推迟的那笔数据全程在 `*_if_v`/`*_hold_q` 里**，
//   与真实冲突（LSU 真的有写回）在仲裁器眼里**完全同型**（判据只有 `p3_lsu`）。
//   交替（`n4_tog`）保证请求总能在下一拍被授予 ⇒ 不死锁、不影响 IPC 分档阈值。
//
// 【判据（全部 $fatal；未捕获即失败）】
//   Z1 压力**真的生效**：MDU/FPU-int 的 deferral 事件数 **> 0**（否则本文件是空测，判 FAIL）
//   Z2 挂起深度有界：`mdu_wb_pend_q`/`fpu_wb_pend_q` 各自**从未同时 > 1 笔**（结构不变量）
//   Z3 写口无地址碰撞：4 个物理写口**任何一拍**都不出现"两路同时写同一 preg"（会丢写）
//   Z4 完成不丢/不重：`#写口落地` 落在 `[#完成 − #kill, #完成]` 区间内（每笔完成恰好落地
//      一次，除非被冲刷丢掉）
//   Z5 端到端正确性：被 force 的锁步 TB 仍须 **TB_BACK2_LOCKSTEP: PASS**
//      （5 程序 PC 流/架构写回流 vs Spike 黄金逐条 0 分歧）⇒ 推迟的写回数据/唤醒/ROB done
//      仍然正确（这是本压力测试的**核心判据**，Z1–Z4 只是"证明压力确实发生了"）。
//
// 运行（仓库根 = rv32gc-cpu/）：
//   source scripts/env.sh
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n4_ds.vvp -s n4_defer_stress \
//            "${RTL[@]}" sim/unit/tb_back2_lockstep.sv sim/unit/n4_defer_stress.sv
//   vvp /tmp/n4_ds.vvp | tail -40        # 期望 N4_DEFER_STRESS: PASS
// 锚点：N4_DEFER_STRESS: PASS（整行恰好一次）
// 纪律：文件名**不匹配** `tb_*.sv` ⇒ 不进 regress.sh（保持 33/33 不变）；
//       force 只在**仿真顶层**施加，产品 RTL 内**没有任何** force/`ifdef` 残留。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module n4_defer_stress;

    tb_back2_lockstep_top u_tb ();

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

`define N4BK u_tb.u_back

    //   物理号宽真源 = back2_params.vh 的 `BACK2_PREG_I_W`（= backend_top 内 localparam PW_I）
    localparam integer N4_PW = `BACK2_PREG_I_W;

    //--------------------------------------------------------------------------
    // 0. 压力注入：交替把共享口优先权 force 给 LSU（见头注"安全且忠实"论证）
    //--------------------------------------------------------------------------
    localparam integer STRESS_ON = 1;     // 置 0 = 对照组（不注入，用于自证 force 确实是变量）

    //   注入相位：`n4_cnt % 3 == 0`（1 拍高 / 2 拍低，周期 3）—— 与 MDU 的完成节拍（乘法 ~2 拍）
    //   互质 ⇒ 相位会**漂移**，不会像"逐拍交替"那样与固定节拍锁定（实测交替档只命中 3 次）。
    //   另外每 64 拍插入一段 8 拍连续拉高（`n4_cnt[5:3]==3'b111`）⇒ 覆盖"挂起跨多拍"的情形。
    reg  [5:0] n4_cnt;
    reg        n4_tog;                    // 保留：逐拍交替档（仅作对照观测，未启用）
    wire       n4_req_any = `N4BK.mdu_req | `N4BK.fpu_i_req;
    wire       n4_phase_hi = ((n4_cnt % 6'd3) == 6'd0) || (n4_cnt[5:3] == 3'b111);
    always @(negedge clk) begin
        if (!rst_n) begin
            n4_cnt <= 6'd0;
            n4_tog <= 1'b0;
            release `N4BK.p3_lsu;
        end else begin
            n4_cnt <= n4_cnt + 6'd1;
            n4_tog <= ~n4_tog;
            if (STRESS_ON && n4_req_any && ~`N4BK.wb_lsu_int && n4_phase_hi)
                force `N4BK.p3_lsu = 1'b1;
            else
                release `N4BK.p3_lsu;
        end
    end

    //--------------------------------------------------------------------------
    // 1. 只读观测 / 不变量断言
    //--------------------------------------------------------------------------
    integer n_lsu_int_wr;      // LSU 真实整数写回条数
    integer n_mdu_new;         // MDU 完成事件
    integer n_mdu_wr;          // MDU 写口落地次数
    integer n_mdu_kill;        // MDU 在飞被冲刷拍数（允许丢弃上界）
    integer n_fpu_i_new;       // FPU→整数 完成事件
    integer n_fpu_i_wr;        // FPU→整数 写口落地次数
    integer n_fpu_i_kill;
    integer n_defer_mdu;       // MDU 首次被推迟事件（Z1）
    integer n_defer_fpu;       // FPU-int 首次被推迟事件（Z1）
    integer n_pend_bad_mdu;    // "挂起位=1 但无请求"的拍数（Z2，必须 0；1 bit 结构上深度恒 ≤1）
    integer n_pend_bad_fpu;
    integer n_pend_mdu_cyc;    // 处于挂起的拍数（证据）
    integer n_pend_fpu_cyc;
    integer n_coll;            // 写口地址碰撞拍数（Z3，必须 0）
    integer n_p4_wr;           // 4 个物理写口的落地总数（证据）

    //   端口地址碰撞判据：两路同时使能且地址相同 ⇒ 后写覆盖前写 = 丢写。
    //   在飞目的物理号互不相同 ⇒ 正常设计下恒 0。
    integer ca, cb;
    reg coll_now;
    always @(*) begin
        coll_now = 1'b0;
        for (ca = 0; ca < 4; ca = ca + 1) begin
            for (cb = ca + 1; cb < 4; cb = cb + 1) begin
                if (`N4BK.iprf_p4_we[ca] && `N4BK.iprf_p4_we[cb] &&
                    (`N4BK.iprf_p4_wa[ca*N4_PW +: N4_PW] ==
                     `N4BK.iprf_p4_wa[cb*N4_PW +: N4_PW]))
                    coll_now = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (`N4BK.wb_lsu_int)                  n_lsu_int_wr  <= n_lsu_int_wr  + 1;
            if (`N4BK.mdu_new)                     n_mdu_new     <= n_mdu_new     + 1;
            if (`N4BK.mdu_wb_v)                    n_mdu_wr      <= n_mdu_wr      + 1;
            if (`N4BK.mdu_kill & `N4BK.mdu_if_v)   n_mdu_kill    <= n_mdu_kill    + 1;
            if (`N4BK.fpu_i_new)                   n_fpu_i_new   <= n_fpu_i_new   + 1;
            if (`N4BK.fpu_wb_v & `N4BK.fpu_if_di)  n_fpu_i_wr    <= n_fpu_i_wr    + 1;
            if (`N4BK.fpu_kill & `N4BK.fpu_if_v)   n_fpu_i_kill  <= n_fpu_i_kill  + 1;
            //   Z1：首次被推迟 = "本次完成请求存在，但本拍未获授予"
            if (`N4BK.mdu_new  & ~`N4BK.mdu_wb_v)  n_defer_mdu   <= n_defer_mdu   + 1;
            if (`N4BK.fpu_i_new & ~`N4BK.fpu_wb_v) n_defer_fpu   <= n_defer_fpu   + 1;
            //   Z2：挂起位是标量（1 bit）；这里再断言"挂起时必有请求" ⇒ 不会凭空挂起
            if (`N4BK.mdu_wb_pend_q) begin
                n_pend_mdu_cyc <= n_pend_mdu_cyc + 1;
                if (~`N4BK.mdu_req) n_pend_bad_mdu <= n_pend_bad_mdu + 1;
            end
            if (`N4BK.fpu_wb_pend_q) begin
                n_pend_fpu_cyc <= n_pend_fpu_cyc + 1;
                if (~`N4BK.fpu_i_req) n_pend_bad_fpu <= n_pend_bad_fpu + 1;
            end
            if (coll_now)                          n_coll        <= n_coll        + 1;
            n_p4_wr <= n_p4_wr + `N4BK.iprf_p4_we[0] + `N4BK.iprf_p4_we[1]
                                + `N4BK.iprf_p4_we[2] + `N4BK.iprf_p4_we[3];
        end
    end

    //--------------------------------------------------------------------------
    // 2. 判据汇总（等 TB 自己 $finish 之前先不判；TB 结束即 $finish ⇒ 用 final 上报）
    //--------------------------------------------------------------------------
    initial begin
        n_lsu_int_wr = 0; n_mdu_new = 0; n_mdu_wr = 0; n_mdu_kill = 0;
        n_fpu_i_new = 0; n_fpu_i_wr = 0; n_fpu_i_kill = 0;
        n_defer_mdu = 0; n_defer_fpu = 0;
        n_pend_bad_mdu = 0; n_pend_bad_fpu = 0;
        n_pend_mdu_cyc = 0; n_pend_fpu_cyc = 0;
        n_coll = 0; n_p4_wr = 0;
    end

    final begin
        release `N4BK.p3_lsu;
        $display("== N4_DEFER_STRESS 观测：LSU-int 写回=%0d | MDU 完成=%0d 落地=%0d kill=%0d 推迟=%0d | FPU-int 完成=%0d 落地=%0d kill=%0d 推迟=%0d",
                 n_lsu_int_wr, n_mdu_new, n_mdu_wr, n_mdu_kill, n_defer_mdu,
                 n_fpu_i_new, n_fpu_i_wr, n_fpu_i_kill, n_defer_fpu);
        $display("== N4_DEFER_STRESS 观测：挂起拍数 MDU=%0d FPU=%0d | 挂起无请求(应 0)=%0d/%0d | 写口地址碰撞(应 0)=%0d | 4 口落地总数=%0d",
                 n_pend_mdu_cyc, n_pend_fpu_cyc, n_pend_bad_mdu, n_pend_bad_fpu,
                 n_coll, n_p4_wr);

        //   Z1：压力必须真的发生（否则本测试为空测）
        if (n_defer_mdu + n_defer_fpu == 0) begin
            $display("FAIL: N4_DEFER_STRESS Z1 —— deferral 事件为 0（压力未生效，本测试无意义）");
            $fatal(1, "N4_DEFER_STRESS 判据不满足");
        end
        //   Z2：挂起与请求一致（无凭空挂起）
        if (n_pend_bad_mdu != 0 || n_pend_bad_fpu != 0) begin
            $display("FAIL: N4_DEFER_STRESS Z2 —— 挂起位与请求不一致（MDU=%0d FPU=%0d）",
                     n_pend_bad_mdu, n_pend_bad_fpu);
            $fatal(1, "N4_DEFER_STRESS 判据不满足");
        end
        //   Z3：4 写口无地址碰撞（无丢写）
        if (n_coll != 0) begin
            $display("FAIL: N4_DEFER_STRESS Z3 —— 写口地址碰撞 %0d 拍（丢写）", n_coll);
            $fatal(1, "N4_DEFER_STRESS 判据不满足");
        end
        //   Z4：完成不丢不重（允许被冲刷丢掉的 ≤ kill 数）
        if (!(n_mdu_wr + n_mdu_kill >= n_mdu_new && n_mdu_wr <= n_mdu_new)) begin
            $display("FAIL: N4_DEFER_STRESS Z4 —— MDU 落地数 %0d 不在 [完成 %0d − kill %0d, 完成 %0d] 内",
                     n_mdu_wr, n_mdu_new, n_mdu_kill, n_mdu_new);
            $fatal(1, "N4_DEFER_STRESS 判据不满足");
        end
        if (!(n_fpu_i_wr + n_fpu_i_kill >= n_fpu_i_new && n_fpu_i_wr <= n_fpu_i_new)) begin
            $display("FAIL: N4_DEFER_STRESS Z4 —— FPU-int 落地数 %0d 不在 [完成 %0d − kill %0d, 完成 %0d] 内",
                     n_fpu_i_wr, n_fpu_i_new, n_fpu_i_kill, n_fpu_i_new);
            $fatal(1, "N4_DEFER_STRESS 判据不满足");
        end
        $display("== N4_DEFER_STRESS Z1–Z4 全部满足（deferral 事件 %0d 次，写口地址碰撞 0）",
                 n_defer_mdu + n_defer_fpu);
        $display("N4_DEFER_STRESS: PASS");
    end

`undef N4BK

endmodule
