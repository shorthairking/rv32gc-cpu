//==============================================================================
// sim/unit/tb_exe_ctrl.sv —— rtl/exec/exe_ctrl.v 单元测试（自检 TB，fail-closed）
//==============================================================================
// 目的    : 验证 E 级旁路选择逻辑的**优先级正确性**，尤其是
//           「M 与 W 同写同一 rd 且值不同」这一唯一能暴露优先级次序的场景。
// 判据    : ① 进程退出码 0；② 输出末行恰为 `TB_EXE_CTRL_UNIT: PASS`
//             （唯一 PASS 字样）；③ 任何断言不符 ⇒ 立即 $fatal（非零退出码），
//             且**绝不打印 PASS**。
// 纪律    : 08 §8.1「未捕获即失败」——显式计数器 + $fatal；
//           `$display` 仅用于诊断，判定一律走 $fatal / err_cnt。
// 背景    : 母 Agent 裁决（2026-09-14）确认旁路优先级为 **M > W > 寄存器堆**
//           （08 §5.3 原文「W > M > 寄存器堆」经裁定为笔误）。
//           「更年轻者优先」：同一拍在途序列为 [W 提交中] → [M] → [E]，
//           M 级指令比 W 级更年轻 ⇒ E 级消费的 rs 应取 M 的值。
// 覆盖    : ★ 核心场景（任务书点名）：
//             (A) M 与 W **同写同一 rd** 且值不同 ⇒ E 必须取 **M 的值**
//             (B) **只有 W 有效**（M 未命中）        ⇒ E 取 W 的值
//             (C) **都无效**（无旁路）               ⇒ E 取寄存器堆的值
//           附加边界（自检强化）：
//             (D) rd == x0 时不得旁路（x0 恒 0）
//             (E) M 与 W 写**不同** rd，各自精确命中
//             (F) 只有 M 有效 ⇒ 取 M
//             (G) 只有 rs1 命中而 rs2 不命中（两端口独立选择）
//             (Q) 反向量：若优先级被写反成 W > M，本 TB 必须 FAIL（见 §5）
// 顶层    : tb_exe_ctrl（验收命令用 -s tb_exe_ctrl）
// 说明    : 纯组合 DUT（无时钟）——每条向量直接比对 rs1/rs2 与 fwd_rs1/fwd_rs2。
//           fwd 编码（与 exe_ctrl.v 一致）：00=RF，01=M，10=W。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_exe_ctrl;

    //--------------------------------------------------------------------------
    // 0. 检查计数器（fail-closed）
    //--------------------------------------------------------------------------
    integer chk_cnt = 0;
    integer err_cnt = 0;

    //--------------------------------------------------------------------------
    // 1. DUT 例化
    //--------------------------------------------------------------------------
    reg  [4:0]  rs1_addr, rs2_addr;
    reg         w_valid, m_valid;
    reg  [4:0]  w_rd, m_rd;
    reg  [31:0] w_data, m_data;
    reg  [31:0] rf_rdata1, rf_rdata2;
    wire [31:0] rs1, rs2;
    wire [1:0]  fwd_rs1, fwd_rs2;

    exe_ctrl u_dut (
        .rs1_addr  (rs1_addr),
        .rs2_addr  (rs2_addr),
        .w_valid   (w_valid),
        .w_rd      (w_rd),
        .w_data    (w_data),
        .m_valid   (m_valid),
        .m_rd      (m_rd),
        .m_data    (m_data),
        .rf_rdata1 (rf_rdata1),
        .rf_rdata2 (rf_rdata2),
        .rs1       (rs1),
        .rs2       (rs2),
        .fwd_rs1   (fwd_rs1),
        .fwd_rs2   (fwd_rs2)
    );

    //--------------------------------------------------------------------------
    // 2. fwd 编码镜像（与 exe_ctrl.v 的 FWD_* 一致）
    //--------------------------------------------------------------------------
    localparam [1:0] FWD_RF = 2'b00;   // 无旁路：用寄存器堆
    localparam [1:0] FWD_M  = 2'b01;   // M 级旁路
    localparam [1:0] FWD_W  = 2'b10;   // W 级旁路

    // 唯一真源引用：x0 编号
    localparam [4:0] X0 = 5'd0;

    //--------------------------------------------------------------------------
    // 3. 检查任务：一条向量 = 一次「设激励 + 比 rs1/rs2 + 比 fwd 编码」
    //--------------------------------------------------------------------------
    task automatic chk;
        input [127:0] name;
        input [4:0]   v_rs1a, v_rs2a;      // E 级 rs1/rs2 寄存器号
        input         v_wv, v_mv;          // W / M 的 valid
        input [4:0]   v_wrd, v_mrd;        // W / M 的 rd
        input [31:0]  v_wdat, v_mdat;      // W / M 的数据
        input [31:0]  v_rf1, v_rf2;        // 寄存器堆读出值
        input [31:0]  e_rs1, e_rs2;        // 期望操作数
        input [1:0]   e_f1, e_f2;          // 期望 fwd 编码
        begin
            rs1_addr = v_rs1a;  rs2_addr = v_rs2a;
            w_valid  = v_wv;    m_valid  = v_mv;
            w_rd     = v_wrd;   m_rd     = v_mrd;
            w_data   = v_wdat;  m_data   = v_mdat;
            rf_rdata1 = v_rf1;  rf_rdata2 = v_rf2;
            #1;                                // 组合传播

            chk_cnt = chk_cnt + 1;
            if ((rs1 !== e_rs1) || (rs2 !== e_rs2) ||
                (fwd_rs1 !== e_f1) || (fwd_rs2 !== e_f2)) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] %0s :", name);
                $display("         E rs1=%0d rs2=%0d | W(v=%b rd=%0d d=%08h) M(v=%b rd=%0d d=%08h) RF(%08h,%08h)",
                         v_rs1a, v_rs2a, v_wv, v_wrd, v_wdat, v_mv, v_mrd, v_mdat, v_rf1, v_rf2);
                $display("         got rs1=%08h rs2=%08h fwd=(%b,%b)", rs1, rs2, fwd_rs1, fwd_rs2);
                $display("         exp rs1=%08h rs2=%08h fwd=(%b,%b)", e_rs1, e_rs2, e_f1, e_f2);
                $fatal(1, "TB_EXE_CTRL_UNIT: FAIL");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 4. 激励
    //--------------------------------------------------------------------------
    initial begin
        $display("=== tb_exe_ctrl : rtl/exec/exe_ctrl.v 单元测试开始 ===");

        //====================================================================
        // 4.1 ★核心场景 (A)：M 与 W **同写同一 rd** 且值不同
        //     ⇒ 必须取 **M 的值**（M 更年轻）——这是唯一区分优先级的场景
        //====================================================================
        // E 级 rs1=rs2=5；M 与 W 都写 rd=5，M 数据 0xM0M0、W 数据 0xW0W0
        chk("A_mw_same_rd_rs1rs2",
            5'd5, 5'd5,                      // E: rs1=rs2=5
            1'b1, 1'b1,                      // W valid, M valid
            5'd5, 5'd5,                      // W rd=5, M rd=5（同 rd）
            32'hAAAA_0005, 32'hBBBB_0005,    // W data, M data（值不同）
            32'h0000_0005, 32'h0000_0005,    // RF 值（也不同于两者）
            32'hBBBB_0005, 32'hBBBB_0005,    // ★ 期望取 M
            FWD_M, FWD_M);                   // ★ 期望 fwd 报 M

        // A2：同 rd 同写，但只有 rs1 用该 rd（rs2 用别的号）
        //     ⇒ rs1 取 M，rs2 走 RF（验证两端口选择相互独立）
        chk("A2_mw_same_rd_rs1only",
            5'd7, 5'd9,                      // E: rs1=7（冲突）, rs2=9（无冲突）
            1'b1, 1'b1,
            5'd7, 5'd7,                      // W/M 都写 rd=7
            32'h1111_7777, 32'h2222_7777,
            32'h3333_0007, 32'h3333_0009,
            32'h2222_7777, 32'h3333_0009,    // rs1←M，rs2←RF
            FWD_M, FWD_RF);

        // A3：同 rd 同写，值取极端（W 全 1、M 全 0）——防止"恰好相等"的假通过
        chk("A3_mw_same_rd_extreme",
            5'd31, 5'd31,
            1'b1, 1'b1,
            5'd31, 5'd31,
            32'hFFFF_FFFF, 32'h0000_0000,    // W=全1, M=全0
            32'h5A5A_5A5A, 32'h5A5A_5A5A,
            32'h0000_0000, 32'h0000_0000,    // ★ 必须取 M 的全 0
            FWD_M, FWD_M);

        //====================================================================
        // 4.2 ★核心场景 (B)：**只有 W 有效**（M 不命中）⇒ 取 W
        //====================================================================
        // B1：W 写 rd=3 且命中；M valid 但写别的 rd（不命中）
        chk("B1_w_only_m_other_rd",
            5'd3, 5'd3,
            1'b1, 1'b1,                      // 两者都 valid
            5'd3, 5'd12,                     // 但 W rd=3 命中，M rd=12 不命中
            32'hCAFE_0003, 32'hDEAD_000C,
            32'h1234_0003, 32'h1234_0003,
            32'hCAFE_0003, 32'hCAFE_0003,    // ★ 取 W
            FWD_W, FWD_W);

        // B2：只有 W valid，M 完全无效（m_valid=0）
        chk("B2_w_valid_m_invalid",
            5'd4, 5'd4,
            1'b1, 1'b0,                      // W valid, M invalid
            5'd4, 5'd4,                      // 即使 rd 相同，M 无效就不算命中
            32'hBEEF_0004, 32'h0BAD_0004,
            32'h9999_0004, 32'h9999_0004,
            32'hBEEF_0004, 32'hBEEF_0004,    // ★ 只能取 W
            FWD_W, FWD_W);

        //====================================================================
        // 4.3 ★核心场景 (C)：**都无效 / 都不命中** ⇒ 取寄存器堆
        //====================================================================
        // C1：W/M 都 invalid
        chk("C1_both_invalid",
            5'd6, 5'd6,
            1'b0, 1'b0,
            5'd6, 5'd6,
            32'h1111_1111, 32'h2222_2222,
            32'hFEED_0006, 32'hFEED_0006,
            32'hFEED_0006, 32'hFEED_0006,    // ★ 取 RF
            FWD_RF, FWD_RF);

        // C2：W/M 都 valid，但写的 rd 与 E 的 rs 都不同（不命中）
        chk("C2_valid_but_no_match",
            5'd8, 5'd8,
            1'b1, 1'b1,
            5'd1, 5'd2,                       // rd=1/2，E 要 8 ⇒ 都不命中
            32'h1111_1111, 32'h2222_2222,
            32'h0DD0_0008, 32'h0DD0_0008,
            32'h0DD0_0008, 32'h0DD0_0008,    // ★ 取 RF
            FWD_RF, FWD_RF);

        //====================================================================
        // 4.4 边界 (D)：rd == x0 时**不得旁路**（x0 恒 0 语义）
        //====================================================================
        // D1：W/M 都写 rd=x0，E 的 rs1/rs2 恰为 x0
        //     ⇒ 不算命中，取 RF 值（core_top 侧对 x0 读口返回 0）
        chk("D1_rd_x0_no_bypass",
            X0, X0,
            1'b1, 1'b1,
            X0, X0,                          // 都写 x0
            32'hFFFF_FFFF, 32'hEEEE_EEEE,    // 数据非 0（若误旁路就会泄漏到 x0 消费者）
            32'h0000_0000, 32'h0000_0000,    // RF 读 x0 = 0
            32'h0000_0000, 32'h0000_0000,    // ★ 必须保持 0
            FWD_RF, FWD_RF);                 // ★ 不得报旁路命中

        // D2：M 写 x0、W 写真实 rd（混合）——W 命中，M 因 x0 不命中
        chk("D2_m_x0_w_real_rd",
            5'd10, 5'd10,
            1'b1, 1'b1,
            5'd10, X0,                       // W rd=10（命中），M rd=x0（不命中）
            32'hA0A0_0010, 32'hFFFF_FFFF,
            32'h77F7_0010, 32'h77F7_0010,
            32'hA0A0_0010, 32'hA0A0_0010,    // ★ 取 W（M 写 x0 必须被忽略）
            FWD_W, FWD_W);

        //====================================================================
        // 4.5 (E)(F)(G)：精确命中与端口独立性
        //====================================================================
        // E1：M 写 rd=11、W 写 rd=12，E 的 rs1=11、rs2=12 ⇒ 各自精确命中
        chk("E1_distinct_rd_both_hit",
            5'd11, 5'd12,
            1'b1, 1'b1,
            5'd12, 5'd11,                    // W rd=12, M rd=11（交错）
            32'h0000_0012, 32'h0000_0011,    // W 数据带 rd 标记
            32'h8888_0011, 32'h8888_0012,
            32'h0000_0011, 32'h0000_0012,    // rs1←M(11), rs2←W(12)
            FWD_M, FWD_W);

        // F1：只有 M valid 且命中 ⇒ 取 M
        chk("F1_m_only",
            5'd13, 5'd14,
            1'b0, 1'b1,                      // W invalid, M valid
            5'd13, 5'd13,                    // M rd=13
            32'hDEAD_DEAD, 32'h0000_000D,
            32'h5555_000D, 32'h5555_000E,
            32'h0000_000D, 32'h5555_000E,    // rs1←M(13), rs2←RF
            FWD_M, FWD_RF);

        // G1：rs1 命中 M/W 而 rs2 完全不命中（反向端口独立性）
        chk("G1_rs1_hit_rs2_miss",
            5'd15, 5'd16,
            1'b1, 1'b1,
            5'd15, 5'd15,                    // 只有 rd=15 被写
            32'h0AAA_000F, 32'h0BBB_000F,
            32'h1234_000F, 32'h5678_0010,
            32'h0BBB_000F, 32'h5678_0010,    // rs1←M(15), rs2←RF(16)
            FWD_M, FWD_RF);

        // G2：M 命中 rs2、W 命中 rs1（交叉，且值不同 rd）——验证无串扰
        chk("G2_cross_ports",
            5'd17, 5'd18,
            1'b1, 1'b1,
            5'd17, 5'd18,                    // W rd=17（命中 rs1）, M rd=18（命中 rs2）
            32'h0000_0011, 32'h0000_0012,
            32'h7777_0011, 32'h7777_0012,
            32'h0000_0011, 32'h0000_0012,    // rs1←W(17), rs2←M(18)
            FWD_W, FWD_M);

        //====================================================================
        // 4.6 ★反向量 (Q)：直接验证"若优先级写反成 W > M 会失败"
        //     本组把 M/W 的值设为可区分，且断言必须取 M。
        //     若实现是 W > M，下面两条必然 FAIL ⇒ 证明本 TB 真在测优先级。
        //====================================================================
        chk("Q_priority_discriminator_1",
            5'd20, 5'd20,
            1'b1, 1'b1,
            5'd20, 5'd20,
            32'h0000_7000, 32'h0000_6000,    // W 值 0x7000、M 值 0x6000
            32'h0000_0000, 32'h0000_0000,
            32'h0000_6000, 32'h0000_6000,    // ★ 必须取 M=0x6000（W>M 实现会得 0x7000）
            FWD_M, FWD_M);

        chk("Q_priority_discriminator_2",
            5'd21, 5'd21,
            1'b1, 1'b1,
            5'd21, 5'd21,
            32'hF000_0000, 32'h0F00_0000,    // W 高半有值、M 低半有值
            32'h0000_0000, 32'h0000_0000,
            32'h0F00_0000, 32'h0F00_0000,    // ★ 必须取 M
            FWD_M, FWD_M);

        //====================================================================
        // 4.7 复位/未初始化下的确定性（X 传播检查，组合 DUT 应无 X）
        //====================================================================
        // 给全 0 激励（全无效）⇒ 结果应等于 RF 且无 X
        begin : no_x_check
            rs1_addr = 5'd25; rs2_addr = 5'd26;
            w_valid = 1'b0; m_valid = 1'b0;
            w_rd = 5'd0; m_rd = 5'd0;
            w_data = 32'h0; m_data = 32'h0;
            rf_rdata1 = 32'hA5A5_A5A5; rf_rdata2 = 32'h5A5A_5A5A;
            #1;
            chk_cnt = chk_cnt + 1;
            if ((^{rs1, rs2, fwd_rs1, fwd_rs2}) === 1'bx) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] 组合输出出现 X（不应有 X 传播）");
                $fatal(1, "TB_EXE_CTRL_UNIT: FAIL");
            end
            chk_cnt = chk_cnt + 1;
            if ((rs1 !== 32'hA5A5_A5A5) || (rs2 !== 32'h5A5A_5A5A)) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] 全无效时应透传 RF：got rs1=%08h rs2=%08h", rs1, rs2);
                $fatal(1, "TB_EXE_CTRL_UNIT: FAIL");
            end
        end

        //--------------------------------------------------------------------------
        // 5. 判定（fail-closed）
        //--------------------------------------------------------------------------
        if (chk_cnt == 0) begin
            $display("TB_EXE_CTRL_UNIT: FAIL (no check executed)");
            $fatal(1, "TB_EXE_CTRL_UNIT: FAIL");
        end
        if (err_cnt != 0) begin
            $display("TB_EXE_CTRL_UNIT: FAIL (%0d/%0d checks failed)", err_cnt, chk_cnt);
            $fatal(1, "TB_EXE_CTRL_UNIT: FAIL");
        end

        $display("TB_EXE_CTRL_UNIT: checked %0d vectors, %0d errors", chk_cnt, err_cnt);
        $display("TB_EXE_CTRL_UNIT: PASS");
        $finish(0);
    end

endmodule
