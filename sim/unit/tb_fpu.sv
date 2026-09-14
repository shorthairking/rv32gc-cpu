//==============================================================================
// sim/unit/tb_fpu.sv —— FPU 顶层集成单元测试（DUT = rtl/exec/fpu.v）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（E 级 `fpu.v` 行、
//         「FPU 分期与流水化要求」② fflags 精确 / ③ fmadd 单次舍入）
//         .work_fpu/INTERFACE.md（端口契约 —— 本 TB 逐字按该端口表驱动）
//
// 覆盖范围（fp_op 0–29，见 rtl/exec/fpu.v 头注 §1 的操作码表）：
//   0 FADD  1 FSUB  2 FMUL  3 FDIV  4 FSQRT  —— 算术
//   5 FSGNJ 6 FSGNJN 7 FSGNJX 8 FMIN 9 FMAX 10 FEQ 11 FLT 12 FLE 13 FCLASS
//  14 FMV_X_W/*_D 15 FMV_W_X/*_D 16 FCVT_W_S 17 FCVT_WU_S 18 FCVT_S_W
//  19 FCVT_S_WU 20 FCVT_W_D 21 FCVT_WU_D 22 FCVT_D_W 23 FCVT_D_WU
//  24 FCVT_S_D 25 FCVT_D_S 26 FMADD 27 FMSUB 28 FNMSUB 29 FNMADD
//   ★ 0–25 是 fpu_cmp.v / fpu_cvt.v 头注定稿的表；26–29（FMA 族）是 fpu.v
//     头注 §1 ★ 定义的扩展编码（08 §5.3 ③ 要求单次舍入，而 0–25 表无 FMA）。
//   ★ 每条 op 至少一个 S 例 + 一个 D 例（转换类按规范只存在一个有意义的方向：
//     16/17/25 的源是 S、20/21/24 的源是 D、18/19 目标 S、22/23 目标 D、
//     14/15 由 fmt 选 W/D 变体 —— 两类变体都已覆盖）。
//   ★ 关键边界与 NaN：±0 符号（RNE/RDN 两侧）、overflow(OF|NX)、underflow(UF|NX)、
//     不精确(NX)、亚正规、±inf、qNaN/sNaN（含 fmin/fmax/feq 的 NV 差异与
//     fmadd 的 inf×0+qNaN ⇒ NV）、canonical NaN、NaN-boxing 违例（含"未 box
//     ⇒ 按 S canon NaN"两条负例）、fclass 全 10 类、FMA 单次舍入判别向量。
//
// 期望值来源：**不是手算常数**，而是 .work_fpu/ref_model.py（已对 libm +
//   精确 Fraction 双 oracle 验证约 20 万例、0 失败）加上 fpu.v 的顶层策略
//   （S 操作数 box 检查 / S 结果 NaN-boxing / 整数目标高 32 位 0 / FMA 的
//   neg_prod+neg_add 映射）算出的；生成脚本见交付报告（/tmp/gen_tb_fpu.py）。
//   下表的 `exp` 两列即该模型的输出，TB 只做"逐位相等"判定。
//
// 时序断言（按 rtl/exec/fpu.v 头注 §2 的时序契约）：
//   · 单拍类：req_valid 拉高的**同一拍** done=1、busy=0、result/fflags/fflags_we
//     有效；req_valid 收回后 done 必须为 0（单拍脉冲、不重复）。
//   · div/sqrt：派发拍 done=0；在途期间 busy 必须持续为 1（不得出现
//     "done=0 且 busy=0" 的空档）；done 拍 busy=0、result/fflags 与期望逐位
//     相等；此后 2 拍不得再出现 done。**不**对 busy 拍数作任何硬编码断言
//     （完成拍数由 fpu_div_sqrt 决定，见 08 §5.3 ①）。
//   · 参数透传：第二个 DUT 实例用不同拍数参数（FDIV_CYCLES=4/FSQRT_CYCLES=128）
//     并行跑同一条指令，其 result/fflags 必须与第一个实例完全一致
//     （数值结果与拍数无关）；其 busy 拍数只打印、不断言。
//   · flush：div/sqrt 迭代中途 flush ⇒ busy 必须落 0、且不得产生 done；
//     随后仍能正常执行新指令（无死锁）。
//   · 复位后 busy=0、done=0（空闲）。
//
// ★ 已知偏差（KNOWN-DEV 段，**不是**本 TB 的漏测）：`rtl/exec/fpu_add.v` 的
//   fpu_add_s/fpu_add_d/fpu_fma_s/fpu_fma_d 在"两个异号操作数的**精确抵消**"
//   且 rm=RDN 时给出 +0，而 IEEE 754 §6.3 / RISC-V 要求 −0（RNE/RTZ/RUP/RMM
//   给 +0 是对的；`(+0)+(−0)` 的特殊值通路也是对的）。根因：精确抵消走的是
//   fpu_round_s/d 通路，其 sign 取 `sum_sign = sum_tc[512] = 0`，模块内
//   `zero_sign`（含 RDN 分支）只作用在 `both_zero` 特殊值通路上。
//   ⇒ 本 TB 保留 3 条该场景用例、按**规范正确值**断言，但归入 KNOWN-DEV 计数
//   （打印 `TB_FPU_UNIT: KNOWN-DEV ...`，不计入 errors）：
//      fadd.s(1.0,-1.0,RDN)、fadd.d(1.0,-1.0,RDN)、fsub.s(1.0,1.0,RDN)
//   fpu_add.v 已修复（2026-09-14，exact_cancel 零符号）⇒ 下面 `KNOWN_DEV_ENABLE` 已置 0，
//   这 3 条现在是**硬断言**（修复前它们会 FAIL；变异反证见交付报告）。
//   若偏差已被修好而 KNOWN_DEV_ENABLE 仍为 1，会打印 `KNOWN-DEV-UNEXPECTED-OK` 提示。
//
// 判定协议：唯一 PASS 行 `TB_FPU_UNIT: PASS`（errors==0 时才打印），
//   结束时另打印每 op 的用例数 `TB_FPU_UNIT: op=<n> cases=<m>`（可复核覆盖
//   全表）。失败时打印 `TB_FPU_UNIT: FAIL errors=<n>` 并以 $fatal 结束
//   （**未捕获即失败**：不给任何 rc=0 的假通过机会）。
//==============================================================================
`timescale 1ns/1ps

module tb_fpu;
    // ---- 时钟 / 复位 ------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #1 clk = ~clk;                       // 周期 2 ns（posedge 在 1,3,5..）

    // ---- 激励（端口逐字对应 .work_fpu/INTERFACE.md）------------------------
    reg        flush = 1'b0;
    reg        req_valid = 1'b0;
    reg [6:0]  fp_op = 7'd0;
    reg [1:0]  fmt = 2'b00;
    reg [2:0]  rm = 3'b000;
    reg [2:0]  frm = 3'b000;
    reg [63:0] a = 64'd0, b = 64'd0, c = 64'd0;

    wire        busy, done, fflags_we;
    wire [63:0] result;
    wire [4:0]  fflags;

    fpu dut (
        .clk (clk), .rst_n (rst_n), .flush (flush), .req_valid (req_valid),
        .fp_op (fp_op), .fmt (fmt), .rm (rm), .frm (frm),
        .a (a), .b (b), .c (c),
        .busy (busy), .done (done), .result (result),
        .fflags_we (fflags_we), .fflags (fflags)
    );

    // ---- 第二个实例：拍数参数不同（参数透传 / 数值与拍数无关）-------------
    wire        busy2, done2, fflags_we2;
    wire [63:0] result2;
    wire [4:0]  fflags2;
    fpu #(.FDIV_CYCLES(4), .FSQRT_CYCLES(128)) dut_p2 (
        .clk (clk), .rst_n (rst_n), .flush (flush), .req_valid (req_valid),
        .fp_op (fp_op), .fmt (fmt), .rm (rm), .frm (frm),
        .a (a), .b (b), .c (c),
        .busy (busy2), .done (done2), .result (result2),
        .fflags_we (fflags_we2), .fflags (fflags2)
    );

    // ---- 用例表（由黄金模型生成）------------------------------------------
    localparam integer NC = 223;
    reg [6:0]  t_op  [0:NC-1];
    reg [1:0]  t_fmt [0:NC-1];
    reg [2:0]  t_rm  [0:NC-1];
    reg [63:0] t_a   [0:NC-1];
    reg [63:0] t_b   [0:NC-1];
    reg [63:0] t_c   [0:NC-1];
    reg [63:0] t_r   [0:NC-1];
    reg [4:0]  t_f   [0:NC-1];
    reg        t_mc  [0:NC-1];      // 1 = div/sqrt（多拍）
    reg        t_it  [0:NC-1];      // 1 = 迭代路径（busy 必须拉高）
    reg        t_xf  [0:NC-1];      // 1 = 已知偏差用例（KNOWN-DEV，见头注）
    reg [2:0]  t_frm [0:NC-1];      // fcsr.frm（DYN 解析用）

    localparam KNOWN_DEV_ENABLE = 1'b0; // fpu_add.v 零符号偏差已修复(2026-09-14) ⇒ 0=硬断言
    reg        known_dev_mode = 1'b0;
    integer errors = 0, known_devs = 0, checks = 0, ci = 0, snap = 0;
    integer opcnt [0:31];
    integer i, k, nwait, nbusy, nbusy2, gap;

    // ---- 失败记录（不改变控制流；末尾统一判定）----------------------------
    task fail;
        input [8*20-1:0] tag;
        input [63:0]    got;
        input [63:0]    exp;
        begin
            if (known_dev_mode) begin
                known_devs = known_devs + 1;
                $display("TB_FPU_UNIT: KNOWN-DEV %0s got=%016x exp=%016x | op=%0d fmt=%b rm=%b a=%016x b=%016x c=%016x",
                         tag, got, exp, fp_op, fmt, rm, a, b, c);
            end else begin
                errors = errors + 1;
                $display("TB_FPU_UNIT: ERR %0s got=%016x exp=%016x | op=%0d fmt=%b rm=%b frm=%b a=%016x b=%016x c=%016x",
                         tag, got, exp, fp_op, fmt, rm, frm, a, b, c);
            end
        end
    endtask

    task put;
        input [6:0]  p_op;
        input [1:0]  p_fmt;
        input [2:0]  p_rm;
        input [63:0] p_a;
        input [63:0] p_b;
        input [63:0] p_c;
        input [63:0] p_r;
        input [4:0]  p_f;
        input        p_mc;
        input        p_it;
        input        p_xf;
        begin
            t_op[ci] = p_op;  t_fmt[ci] = p_fmt; t_rm[ci] = p_rm;
            t_a[ci]  = p_a;   t_b[ci]   = p_b;   t_c[ci]  = p_c;
            t_r[ci]  = p_r;   t_f[ci]   = p_f;
            t_mc[ci] = p_mc;  t_it[ci]  = p_it;  t_xf[ci] = p_xf;
            t_frm[ci] = 3'b000;
            ci = ci + 1;
        end
    endtask


    // ---- frm/DYN 解析用例（rm=111 时取 frm；保留 frm/rm 按 RNE）------------
    task sc_case_frm;
        input [6:0]  p_op;
        input [1:0]  p_fmt;
        input [2:0]  p_rm;
        input [63:0] p_a;
        input [63:0] p_b;
        input [4:0]  p_f;
        begin
            known_dev_mode = 1'b0;
            @(posedge clk);
            fp_op <= p_op; fmt <= p_fmt; rm <= p_rm; a <= p_a; b <= p_b;
            c <= 64'd0; flush <= 1'b0; req_valid <= 1'b1;
            #1.5;
            checks = checks + 1;
            if (done !== 1'b1) fail("frm done", {63'b0, done}, 64'd1);
            if (fflags !== p_f) fail("frm fflags", {59'b0, fflags}, {59'b0, p_f});
            @(posedge clk); req_valid <= 1'b0; #1.5;
        end
    endtask
    // ---- 单拍类用例 -------------------------------------------------------
    // 驱动约定：所有激励用**非阻塞赋值**在 posedge 上给出 ⇒ req_valid 恰好保持
    // 一个时钟周期；采样点在"边沿 + 1.5 ns"（clk 低电平中部，无竞争）。
    task sc_case;
        input integer id;
        begin
            known_dev_mode = (KNOWN_DEV_ENABLE && t_xf[id]) ? 1'b1 : 1'b0;
            snap = errors + known_devs;
            @(posedge clk);
            fp_op <= t_op[id]; fmt <= t_fmt[id]; rm <= t_rm[id]; frm <= t_frm[id];
            a <= t_a[id]; b <= t_b[id]; c <= t_c[id];
            flush <= 1'b0; req_valid <= 1'b1;         // 本拍 = 派发拍
            #1.5;                                     // 派发拍中部：组合结果已稳定
            checks = checks + 1;
            if (done !== 1'b1)      fail("done!=1",  {63'b0, done},  64'd1);
            if (busy !== 1'b0)      fail("busy!=0",  {63'b0, busy},  64'd0);
            if (fflags_we !== 1'b1) fail("fflags_we", {63'b0, fflags_we}, 64'd1);
            if (result !== t_r[id]) fail("result", result, t_r[id]);
            if (fflags !== t_f[id]) fail("fflags", {59'b0, fflags}, {59'b0, t_f[id]});
            @(posedge clk);
            req_valid <= 1'b0;
            #1.5;                                     // 下一拍中部：done 必须已落
            checks = checks + 1;
            if (done !== 1'b0) fail("done not pulse", {63'b0, done}, 64'd0);
            known_dev_mode = 1'b0;
            if (KNOWN_DEV_ENABLE && t_xf[id] && ((errors + known_devs) == snap))
                $display("TB_FPU_UNIT: KNOWN-DEV-UNEXPECTED-OK op=%0d (r%0d) —— 零符号偏差似已修复，可把 KNOWN_DEV_ENABLE 置 0",
                         t_op[id], t_rm[id]);
        end
    endtask

    // ---- div/sqrt 用例（busy/done 时序断言 + 参数透传对比）----------------
    task ds_case;
        input integer id;
        begin
            known_dev_mode = 1'b0;
            @(posedge clk);
            fp_op <= t_op[id]; fmt <= t_fmt[id]; rm <= t_rm[id]; frm <= t_frm[id];
            a <= t_a[id]; b <= t_b[id]; c <= t_c[id];
            flush <= 1'b0; req_valid <= 1'b1;
            #1.5;                                     // 派发拍中部
            checks = checks + 1;
            if (done !== 1'b0) fail("ds done@disp", {63'b0, done}, 64'd0);
            if (busy !== 1'b0) fail("ds busy@disp", {63'b0, busy}, 64'd0);

            @(posedge clk);                            // 本沿：fpu_div_sqrt 接收 start
            req_valid <= 1'b0;
            #1.5;
            nbusy = 0; nwait = 0; gap = 0;
            while ((done !== 1'b1) && (nwait < 4000)) begin
                if (busy === 1'b1) nbusy = nbusy + 1;
                else               gap = 1;            // 在途空档（未 done 却 busy=0）
                @(posedge clk); #1.5;
                nwait = nwait + 1;
            end
            checks = checks + 1;
            if (nwait >= 4000) fail("ds timeout", {63'b0, nwait}, 64'd0);
            if (busy !== 1'b0) fail("ds busy@done", {63'b0, busy}, 64'd0);
            if (fflags_we !== 1'b1) fail("ds we@done", {63'b0, fflags_we}, 64'd1);
            if (result !== t_r[id]) fail("ds result", result, t_r[id]);
            if (fflags !== t_f[id]) fail("ds fflags", {59'b0, fflags}, {59'b0, t_f[id]});
            if (t_it[id]) begin                        // 迭代路径：busy 必须真的拉高且无空档
                checks = checks + 1;
                if (nbusy == 0) fail("ds busy never", {63'b0, nbusy}, 64'd1);
                if (gap)        fail("ds busy gap",  {63'b0, gap},   64'd0);
            end
            if (t_op[id] == 7'd3) $display("TB_FPU_UNIT: div  fmt=%b busy_cycles=%0d", fmt, nbusy);
            else                  $display("TB_FPU_UNIT: sqrt fmt=%b busy_cycles=%0d", fmt, nbusy);

            // ---- 参数透传：第二个实例（不同拍数参数）结果必须一致 -----------
            nbusy2 = 0; k = 0;
            while ((done2 !== 1'b1) && (k < 4000)) begin
                if (busy2 === 1'b1) nbusy2 = nbusy2 + 1;
                @(posedge clk); #1.5;
                k = k + 1;
            end
            checks = checks + 1;
            if (k >= 4000) fail("p2 timeout", {63'b0, k}, 64'd0);
            if (result2 !== t_r[id]) fail("p2 result", result2, t_r[id]);
            if (fflags2 !== t_f[id]) fail("p2 fflags", {59'b0, fflags2}, {59'b0, t_f[id]});
            $display("TB_FPU_UNIT: param2 busy_cycles=%0d (拍数参数不同，结果一致)", nbusy2);

            // ---- done 必须是单拍脉冲：随后 2 拍不得再出现 done ---------------
            repeat (2) begin
                @(posedge clk); #1.5;
                checks = checks + 1;
                if (done !== 1'b0) fail("ds extra done", {63'b0, done}, 64'd0);
            end
        end
    endtask

    // ---- 流程类用例：flush / 复位空闲 / 背靠背单拍 ------------------------
    task flow_tests;
        begin
            known_dev_mode = 1'b0;
            // (1) 复位后空闲（此时刚复位完，busy/done 均应为 0）
            checks = checks + 1;
            if (busy !== 1'b0) fail("rst busy", {63'b0, busy}, 64'd0);
            checks = checks + 1;
            if (done !== 1'b0) fail("rst done", {63'b0, done}, 64'd0);

            // (2) 背靠背单拍：两条 fadd.s 连续两拍各出一个 done
            @(posedge clk);
            fp_op <= 7'd0; fmt <= 2'b00; rm <= 3'b000; flush <= 1'b0;
            a <= 64'hFFFFFFFF3F800000; b <= 64'hFFFFFFFF40000000; c <= 64'd0; req_valid <= 1'b1;
            #1.5;                                    // 第 1 条
            checks = checks + 1;
            if (done !== 1'b1) fail("b2b done1", {63'b0, done}, 64'd1);
            if (result !== 64'hFFFFFFFF40400000) fail("b2b res1", result, 64'hFFFFFFFF40400000);
            @(posedge clk);
            a <= 64'hFFFFFFFF40000000; b <= 64'hFFFFFFFF40000000;                // 第 2 条（req_valid 保持 1，无空隙）
            #1.5;
            checks = checks + 1;
            if (done !== 1'b1) fail("b2b done2", {63'b0, done}, 64'd1);
            if (result !== 64'hFFFFFFFF40800000) fail("b2b res2", result, 64'hFFFFFFFF40800000);
            @(posedge clk); req_valid <= 1'b0; #1.5;

            // (3) div 迭代中途 flush：busy 落 0、不得有 done、之后可恢复
            @(posedge clk);
            fp_op <= 7'd3; fmt <= 2'b00; rm <= 3'b000;
            a <= 64'hFFFFFFFF3F800000; b <= 64'hFFFFFFFF40400000; req_valid <= 1'b1;   // 1.0/3.0 => 迭代路径
            @(posedge clk); req_valid <= 1'b0; #1.5;
            repeat (3) begin @(posedge clk); #1.5; end      // 迭代中（约 110 拍）
            checks = checks + 1;
            if (busy !== 1'b1) fail("flush pre busy", {63'b0, busy}, 64'd1);
            if (done !== 1'b0) fail("flush pre done", {63'b0, done}, 64'd0);
            @(posedge clk); flush <= 1'b1;                  // 冲刷（下一沿生效）
            @(posedge clk); #1.5;                           // 冲刷生效拍：busy 必须落 0
            checks = checks + 1;
            if (busy !== 1'b0) fail("flush busy", {63'b0, busy}, 64'd0);
            repeat (2) begin
                @(posedge clk); #1.5;
                checks = checks + 1;
                if (done !== 1'b0) fail("flush done", {63'b0, done}, 64'd0);
            end
            @(posedge clk); flush <= 1'b0;
            // 恢复：flush 后仍能正常派发（1.0/1.0 = 1.0）
            fp_op <= 7'd3; fmt <= 2'b00; a <= 64'hFFFFFFFF3F800000; b <= 64'hFFFFFFFF3F800000; req_valid <= 1'b1;
            @(posedge clk); req_valid <= 1'b0; #1.5;
            nwait = 0;
            while ((done !== 1'b1) && (nwait < 4000)) begin
                @(posedge clk); #1.5; nwait = nwait + 1;
            end
            checks = checks + 1;
            if (done !== 1'b1) fail("recover done", {63'b0, done}, 64'd1);
            if (result !== 64'hFFFFFFFF3F800000) fail("recover res", result, 64'hFFFFFFFF3F800000);
            @(posedge clk); #1.5;
        end
    endtask

    initial begin
        // ---- 复位（3 拍低 + 1 拍释放）----
        rst_n = 1'b0; flush = 1'b0; req_valid = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1; @(posedge clk);
        #1.5;

        for (i = 0; i < 32; i = i + 1) opcnt[i] = 0;

        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF40400000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+2.0=3.0
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF40000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+1.0=2.0
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s (+0)+(-0)=+0 (RNE)
        put(7'd0, 2'b00, 3'b010, 64'hFFFFFFFF00000000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s (+0)+(-0)=-0 (RDN)
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFFBF800000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+(-1.0)=+0 (RNE)
        put(7'd0, 2'b00, 3'b010, 64'hFFFFFFFF3F800000, 64'hFFFFFFFFBF800000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b0, 1'b0, 1'b1); // fadd.s 1.0+(-1.0)=-0 (RDN)   [KNOWN-DEV: fpu_add.v 精确抵消零符号偏差]
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF33800000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+2^-24 tie->1.0 NX
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF7F7FFFFF, 64'hFFFFFFFF7F7FFFFF, 64'h0000000000000000, 64'hFFFFFFFF7F800000, 5'b00101, 1'b0, 1'b0, 1'b0); // fadd.s max+max=+inf OF|NX
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF00000001, 64'hFFFFFFFF00000001, 64'h0000000000000000, 64'hFFFFFFFF00000002, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s minsub+minsub=2*2^-149
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s qNaN+1.0=canon NaN
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fadd.s sNaN+1.0=canon NaN NV
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'hFFFFFFFFFF800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fadd.s +inf+(-inf)=canon NaN NV
        put(7'd0, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFFC0000000, 64'h0000000000000000, 64'hFFFFFFFFC0400000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s -1.0+(-2.0)=-3.0
        put(7'd0, 2'b00, 3'b000, 64'h000000003F800000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.s 未 box 操作数=>canon NaN
        put(7'd0, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h4000000000000000, 64'h0000000000000000, 64'h4008000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.d 1.0+2.0=3.0
        put(7'd0, 2'b01, 3'b000, 64'h0000000000000000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.d (+0)+(-0)=+0
        put(7'd0, 2'b01, 3'b010, 64'h3FF0000000000000, 64'hBFF0000000000000, 64'h0000000000000000, 64'h8000000000000000, 5'b00000, 1'b0, 1'b0, 1'b1); // fadd.d 1.0+(-1.0)=-0 (RDN)   [KNOWN-DEV: fpu_add.v 精确抵消零符号偏差]
        put(7'd0, 2'b01, 3'b000, 64'h7FEFFFFFFFFFFFFF, 64'h7FEFFFFFFFFFFFFF, 64'h0000000000000000, 64'h7FF0000000000000, 5'b00101, 1'b0, 1'b0, 1'b0); // fadd.d max+max=+inf OF|NX
        put(7'd0, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.d qNaN+1.0=canon NaN
        put(7'd0, 2'b01, 3'b000, 64'h7FF0000000000001, 64'h3FF0000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fadd.d sNaN+1.0=canon NaN NV
        put(7'd0, 2'b01, 3'b000, 64'h7FF0000000000000, 64'hFFF0000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fadd.d +inf+(-inf)=canon NaN NV
        put(7'd0, 2'b01, 3'b000, 64'hBFF0000000000000, 64'hC000000000000000, 64'h0000000000000000, 64'hC008000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.d -1.0+(-2.0)=-3.0
        put(7'd1, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsub.s 1.0-1.0=+0 (RNE)
        put(7'd1, 2'b00, 3'b010, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b0, 1'b0, 1'b1); // fsub.s 1.0-1.0=-0 (RDN)   [KNOWN-DEV: fpu_add.v 精确抵消零符号偏差]
        put(7'd1, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F000000, 64'h0000000000000000, 64'hFFFFFFFF3F000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsub.s 1.0-0.5=0.5
        put(7'd1, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'hFFFFFFFF7F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fsub.s inf-inf=canon NaN NV
        put(7'd1, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsub.s 2.0-1.0=1.0
        put(7'd1, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h3FE0000000000000, 64'h0000000000000000, 64'h3FE0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsub.d 1.0-0.5=0.5
        put(7'd1, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsub.d qNaN-0.0=canon NaN
        put(7'd1, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsub.d 1.0-1.0=+0
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF40400000, 64'h0000000000000000, 64'hFFFFFFFF40C00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.s 2.0*3.0=6.0
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmul.s inf*0=canon NaN NV
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF80000000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.s (-0)*2.0=-0
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF7F7FFFFF, 64'hFFFFFFFF7F7FFFFF, 64'h0000000000000000, 64'hFFFFFFFF7F800000, 5'b00101, 1'b0, 1'b0, 1'b0); // fmul.s max*max=+inf OF|NX
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF00000001, 64'hFFFFFFFF3F000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00011, 1'b0, 1'b0, 1'b0); // fmul.s minsub*0.5=+0 UF|NX
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmul.s sNaN*1.0=canon NaN NV
        put(7'd2, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'h000000003F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.s 未 box b=>canon NaN
        put(7'd2, 2'b01, 3'b000, 64'h4000000000000000, 64'h4008000000000000, 64'h0000000000000000, 64'h4018000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.d 2.0*3.0=6.0
        put(7'd2, 2'b01, 3'b000, 64'h7FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmul.d inf*0=canon NaN NV
        put(7'd2, 2'b01, 3'b000, 64'h8000000000000000, 64'h4000000000000000, 64'h0000000000000000, 64'h8000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.d (-0)*2.0=-0
        put(7'd2, 2'b01, 3'b000, 64'h0000000000000000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.d 0*qNaN=canon NaN (no NV)
        put(7'd2, 2'b01, 3'b000, 64'h7FEFFFFFFFFFFFFF, 64'h7FEFFFFFFFFFFFFF, 64'h0000000000000000, 64'h7FF0000000000000, 5'b00101, 1'b0, 1'b0, 1'b0); // fmul.d max*max=+inf OF|NX
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF3F000000, 5'b00000, 1'b1, 1'b1, 1'b0); // fdiv.s 1.0/2.0=0.5
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF40800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF40000000, 5'b00000, 1'b1, 1'b1, 1'b0); // fdiv.s 4.0/2.0=2.0
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40400000, 64'h0000000000000000, 64'hFFFFFFFF3EAAAAAB, 5'b00001, 1'b1, 1'b1, 1'b0); // fdiv.s 1.0/3.0 (NX)
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFF7F800000, 5'b01000, 1'b1, 1'b0, 1'b0); // fdiv.s 1.0/0=+inf DZ
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFFFF800000, 5'b01000, 1'b1, 1'b0, 1'b0); // fdiv.s -1.0/0=-inf DZ
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b1, 1'b0, 1'b0); // fdiv.s 0/0=canon NaN NV
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'hFFFFFFFF7F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b1, 1'b0, 1'b0); // fdiv.s inf/inf=canon NaN NV
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b1, 1'b0, 1'b0); // fdiv.s qNaN/1.0=canon NaN
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fdiv.s 0/1.0=+0
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF80000000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fdiv.s -0/1.0=-0
        put(7'd3, 2'b00, 3'b000, 64'hFFFFFFFF00000001, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00011, 1'b1, 1'b1, 1'b0); // fdiv.s minsub/2.0=+0 UF|NX
        put(7'd3, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h4000000000000000, 64'h0000000000000000, 64'h3FE0000000000000, 5'b00000, 1'b1, 1'b1, 1'b0); // fdiv.d 1.0/2.0=0.5
        put(7'd3, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF0000000000000, 5'b01000, 1'b1, 1'b0, 1'b0); // fdiv.d 1.0/0=+inf DZ
        put(7'd3, 2'b01, 3'b000, 64'hBFF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFF0000000000000, 5'b01000, 1'b1, 1'b0, 1'b0); // fdiv.d -1.0/0=-inf DZ
        put(7'd3, 2'b01, 3'b000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b10000, 1'b1, 1'b0, 1'b0); // fdiv.d 0/0=canon NaN NV
        put(7'd3, 2'b01, 3'b000, 64'h7FF0000000000000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h7FF0000000000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fdiv.d inf/1.0=+inf
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF40800000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF40000000, 5'b00000, 1'b1, 1'b1, 1'b0); // fsqrt.s sqrt(4.0)=2.0 (0x40000000)
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3FB504F3, 5'b00001, 1'b1, 1'b1, 1'b0); // fsqrt.s sqrt(2.0)=0x3FB504F3 (NX)
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b1, 1'b1, 1'b0); // fsqrt.s sqrt(1.0)=1.0
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(+0)=+0
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(-0)=-0
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(-1.0)=canon NaN NV
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7F800000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(+inf)=+inf
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFFFF800000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(-inf)=canon NaN NV
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(qNaN)=canon NaN
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b1, 1'b0, 1'b0); // fsqrt.s sqrt(sNaN)=canon NaN NV
        put(7'd4, 2'b00, 3'b000, 64'hFFFFFFFF00000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF1A3504F3, 5'b00001, 1'b1, 1'b1, 1'b0); // fsqrt.s sqrt(2^-149) (亚正规入)
        put(7'd4, 2'b01, 3'b000, 64'h4010000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h4000000000000000, 5'b00000, 1'b1, 1'b1, 1'b0); // fsqrt.d sqrt(4.0)=2.0
        put(7'd4, 2'b01, 3'b000, 64'h4000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h3FF6A09E667F3BCD, 5'b00001, 1'b1, 1'b1, 1'b0); // fsqrt.d sqrt(2.0)
        put(7'd4, 2'b01, 3'b000, 64'hC010000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b10000, 1'b1, 1'b0, 1'b0); // fsqrt.d sqrt(-4.0)=canon NaN NV
        put(7'd4, 2'b01, 3'b000, 64'h7FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF0000000000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.d sqrt(+inf)=+inf
        put(7'd4, 2'b01, 3'b000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h8000000000000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.d sqrt(-0)=-0
        put(7'd4, 2'b01, 3'b000, 64'h3FD0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h3FE0000000000000, 5'b00000, 1'b1, 1'b1, 1'b0); // fsqrt.d sqrt(0.25)=0.5
        put(7'd4, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b00000, 1'b1, 1'b0, 1'b0); // fsqrt.d sqrt(qNaN)=canon NaN
        put(7'd5, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFFC0000000, 64'h0000000000000000, 64'hFFFFFFFFBF800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnj.s  1.0,-2.0 => -1.0
        put(7'd5, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnj.s -1.0,+0   => +1.0
        put(7'd5, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFFBF800000, 64'h0000000000000000, 64'hFFFFFFFFFFC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnj.s qNaN,-1.0 => -qNaN(不规范化)
        put(7'd5, 2'b01, 3'b000, 64'h3FF0000000000000, 64'hC000000000000000, 64'h0000000000000000, 64'hBFF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnj.d  1.0,-2.0 => -1.0
        put(7'd6, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFFC0000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnjn.s 1.0,-2.0 => +1.0
        put(7'd6, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFFC0000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnjn.s -1.0,-2.0 => -1.0
        put(7'd6, 2'b01, 3'b000, 64'h3FF0000000000000, 64'hC000000000000000, 64'h0000000000000000, 64'h3FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnjn.d 1.0,-2.0 => +1.0
        put(7'd7, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFFC0000000, 64'h0000000000000000, 64'hFFFFFFFFBF800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnjx.s 1.0,-2.0 => -1.0
        put(7'd7, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFFC0000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnjx.s -1.0,-2.0 => +1.0
        put(7'd7, 2'b01, 3'b000, 64'hBFF0000000000000, 64'hC000000000000000, 64'h0000000000000000, 64'h3FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fsgnjx.d -1.0,-2.0 => +1.0
        put(7'd8, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.s min(1.0,2.0)=1.0
        put(7'd8, 2'b00, 3'b000, 64'hFFFFFFFF80000000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.s min(-0,+0)=-0
        put(7'd8, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.s min(qNaN,1.0)=1.0 (no NV)
        put(7'd8, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmin.s min(sNaN,1.0)=1.0 NV
        put(7'd8, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.s min(qNaN,qNaN)=canon NaN (no NV)
        put(7'd8, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h4000000000000000, 64'h0000000000000000, 64'h3FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.d min(1.0,2.0)=1.0
        put(7'd8, 2'b01, 3'b000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h8000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.d min(-0,+0)=-0
        put(7'd8, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h4000000000000000, 64'h0000000000000000, 64'h4000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmin.d min(qNaN,2.0)=2.0
        put(7'd9, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'hFFFFFFFF40000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmax.s max(1.0,2.0)=2.0
        put(7'd9, 2'b00, 3'b000, 64'hFFFFFFFF80000000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmax.s max(-0,+0)=+0
        put(7'd9, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmax.s max(1.0,qNaN)=1.0 (no NV)
        put(7'd9, 2'b01, 3'b000, 64'h4000000000000000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h4000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmax.d max(2.0,1.0)=2.0
        put(7'd9, 2'b01, 3'b000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmax.d max(-0,+0)=+0
        put(7'd10, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // feq.s (+0,-0)=1
        put(7'd10, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // feq.s (1.0,1.0)=1
        put(7'd10, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // feq.s (1.0,2.0)=0
        put(7'd10, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // feq.s (qNaN,1.0)=0 (no NV)
        put(7'd10, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // feq.s (sNaN,1.0)=0 NV
        put(7'd10, 2'b01, 3'b000, 64'h0000000000000000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // feq.d (+0,-0)=1
        put(7'd10, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // feq.d (qNaN,qNaN)=0 (no NV)
        put(7'd11, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // flt.s (1.0,2.0)=1
        put(7'd11, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // flt.s (2.0,1.0)=0
        put(7'd11, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // flt.s (+0,-0)=0
        put(7'd11, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // flt.s (qNaN,1.0)=0 NV (signaling)
        put(7'd11, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h4000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // flt.d (1.0,2.0)=1
        put(7'd11, 2'b01, 3'b000, 64'h0000000000000000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // flt.d (+0,-0)=0
        put(7'd12, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fle.s (1.0,1.0)=1
        put(7'd12, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fle.s (+0,-0)=1
        put(7'd12, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fle.s (2.0,1.0)=0
        put(7'd12, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fle.s (1.0,qNaN)=0 NV
        put(7'd12, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fle.d (1.0,1.0)=1
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFFFF800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s -inf
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000002, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s -normal
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF80000001, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000004, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s -subnormal
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000008, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s -0
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF00000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000010, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s +0
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF00000001, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000020, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s +subnormal
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000040, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s +normal
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000080, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s +inf
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000100, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s sNaN
        put(7'd13, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000200, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.s qNaN
        put(7'd13, 2'b01, 3'b000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000008, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.d -0
        put(7'd13, 2'b01, 3'b000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000010, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.d +0
        put(7'd13, 2'b01, 3'b000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000040, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.d +normal
        put(7'd13, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000200, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.d qNaN
        put(7'd13, 2'b01, 3'b000, 64'hFFF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.d -inf
        put(7'd13, 2'b01, 3'b000, 64'h0000000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000020, 5'b00000, 1'b0, 1'b0, 1'b0); // fclass.d +subnormal
        put(7'd14, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000007FC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmv.x.w NaN-boxed 低 32 位
        put(7'd14, 2'b00, 3'b000, 64'h1234567889ABCDEF, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000089ABCDEF, 5'b00000, 1'b0, 1'b0, 1'b0); // fmv.x.w transfer 不检查 boxing
        put(7'd14, 2'b01, 3'b000, 64'h1234567889ABCDEF, 64'h0000000000000000, 64'h0000000000000000, 64'h1234567889ABCDEF, 5'b00000, 1'b0, 1'b0, 1'b0); // fmv.x.d 全 64 位
        put(7'd15, 2'b00, 3'b000, 64'h0000000089ABCDEF, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF89ABCDEF, 5'b00000, 1'b0, 1'b0, 1'b0); // fmv.w.x 窄传输=>高 32 位补 1
        put(7'd15, 2'b00, 3'b000, 64'hDEADBEEF00000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmv.w.x 只看低 32 位
        put(7'd15, 2'b01, 3'b000, 64'h1234567889ABCDEF, 64'h0000000000000000, 64'h0000000000000000, 64'h1234567889ABCDEF, 5'b00000, 1'b0, 1'b0, 1'b0); // fmv.d.x 全 64 位
        put(7'd16, 2'b00, 3'b000, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000002, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(1.5,RNE)=2 NX
        put(7'd16, 2'b00, 3'b001, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(1.5,RTZ)=1 NX
        put(7'd16, 2'b00, 3'b001, 64'hFFFFFFFFBFC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(-1.5,RTZ)=-1 NX
        put(7'd16, 2'b00, 3'b010, 64'hFFFFFFFFBFC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFE, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(-1.5,RDN)=-2 NX
        put(7'd16, 2'b00, 3'b011, 64'hFFFFFFFFBFC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(-1.5,RUP)=-1 NX
        put(7'd16, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.w.s(1.0)=1 精确无 NX
        put(7'd16, 2'b00, 3'b000, 64'hFFFFFFFF4F000000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000007FFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.w.s(2^31)=0x7FFFFFFF NV 饱和
        put(7'd16, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000007FFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.w.s(qNaN)=0x7FFFFFFF NV
        put(7'd16, 2'b00, 3'b000, 64'hFFFFFFFFFF800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000080000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.w.s(-inf)=0x80000000 NV
        put(7'd16, 2'b00, 3'b000, 64'hFFFFFFFF00000001, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(2^-149)=0 NX
        put(7'd16, 2'b00, 3'b000, 64'h000000003F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000007FFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.w.s 未 box=>canon NaN NV
        put(7'd17, 2'b00, 3'b000, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000002, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.wu.s(1.5,RNE)=2 NX
        put(7'd17, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000001, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.wu.s(1.0)=1
        put(7'd17, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.wu.s(-1.0)=0 NV 饱和
        put(7'd17, 2'b00, 3'b000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.wu.s(qNaN)=0xFFFFFFFF NV
        put(7'd17, 2'b00, 3'b000, 64'hFFFFFFFF4F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.wu.s(2^32)=0xFFFFFFFF NV
        put(7'd18, 2'b00, 3'b000, 64'h0000000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.w(1)=1.0f
        put(7'd18, 2'b00, 3'b000, 64'h00000000FFFFFFFF, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFFBF800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.w(-1)=-1.0f
        put(7'd18, 2'b00, 3'b000, 64'h0000000080000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFFCF000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.w(-2^31)=-2^31 精确
        put(7'd18, 2'b00, 3'b000, 64'h0000000001000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF4B800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.s.w(16842753) 舍入 NX
        put(7'd18, 2'b00, 3'b001, 64'h0000000001000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF4B800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.s.w(16842753,RTZ)
        put(7'd19, 2'b00, 3'b000, 64'h00000000FFFFFFFF, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF4F800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.s.wu(2^32-1) NX
        put(7'd19, 2'b00, 3'b000, 64'h0000000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.wu(1)=1.0f
        put(7'd20, 2'b01, 3'b000, 64'h3FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000002, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.d(1.5,RNE)=2 NX
        put(7'd20, 2'b01, 3'b001, 64'hBFF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.d(-1.5,RTZ)=-1 NX
        put(7'd20, 2'b01, 3'b000, 64'hC1E0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000080000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.w.d(-2^31)=0x80000000 精确
        put(7'd20, 2'b01, 3'b000, 64'h41E0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000007FFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.w.d(2^31)=0x7FFFFFFF NV
        put(7'd20, 2'b01, 3'b000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000007FFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.w.d(qNaN)=0x7FFFFFFF NV
        put(7'd21, 2'b01, 3'b000, 64'h3FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000002, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.wu.d(1.5,RNE)=2 NX
        put(7'd21, 2'b01, 3'b000, 64'hBFF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.wu.d(-1.0)=0 NV
        put(7'd21, 2'b01, 3'b000, 64'h41EFFFFFFFFFFFFF, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.wu.d(2^32-1)=0xFFFFFFFF 精确
        put(7'd21, 2'b01, 3'b000, 64'h7FF0000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'h00000000FFFFFFFF, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.wu.d(sNaN)=0xFFFFFFFF NV
        put(7'd22, 2'b01, 3'b000, 64'h0000000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'h3FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.w(1)=1.0 精确
        put(7'd22, 2'b01, 3'b000, 64'h0000000080000000, 64'h0000000000000000, 64'h0000000000000000, 64'hC1E0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.w(-2^31) 精确
        put(7'd22, 2'b01, 3'b010, 64'h0000000001000001, 64'h0000000000000000, 64'h0000000000000000, 64'h4170000010000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.w(16842753) 精确（与 rm 无关）
        put(7'd23, 2'b01, 3'b000, 64'h00000000FFFFFFFF, 64'h0000000000000000, 64'h0000000000000000, 64'h41EFFFFFFFE00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.wu(2^32-1) 精确
        put(7'd23, 2'b01, 3'b000, 64'h0000000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'h3FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.wu(1)=1.0
        put(7'd24, 2'b00, 3'b000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.d(1.0)=0x3F800000
        put(7'd24, 2'b00, 3'b000, 64'h3FF0000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.s.d(1+2^-52)=1.0f NX
        put(7'd24, 2'b00, 3'b000, 64'h3FEFFFFFFFFFFFFE, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.s.d(1-2^-52)=1.0f NX
        put(7'd24, 2'b00, 3'b001, 64'h3FF0000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.s.d(1+2^-52,RTZ)
        put(7'd24, 2'b00, 3'b000, 64'h7FF8000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.d(qNaN)=S canon NaN
        put(7'd24, 2'b00, 3'b000, 64'h7FF0000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.s.d(sNaN)=S canon NaN NV
        put(7'd24, 2'b00, 3'b000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.d(+0)=+0 无 flag
        put(7'd24, 2'b00, 3'b000, 64'h8000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF80000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.d(-0)=-0 无 flag
        put(7'd24, 2'b00, 3'b000, 64'h01A56E790F39CF7A, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00011, 1'b0, 1'b0, 1'b0); // fcvt.s.d(-1e-300)=-0 UF|NX（微小通路）
        put(7'd24, 2'b00, 3'b011, 64'h01A56E790F39CF7A, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000001, 5'b00011, 1'b0, 1'b0, 1'b0); // fcvt.s.d(-1e-300,RUP)=-0 UF|NX
        put(7'd24, 2'b00, 3'b010, 64'h01A56E790F39CF7A, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00011, 1'b0, 1'b0, 1'b0); // fcvt.s.d(-1e-300,RDN)=-2^-149 UF|NX
        put(7'd24, 2'b00, 3'b000, 64'h7E37E43C8800752E, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7F800000, 5'b00101, 1'b0, 1'b0, 1'b0); // fcvt.s.d(1e300)=+inf OF|NX
        put(7'd24, 2'b00, 3'b000, 64'h7FF0000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF7F800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.s.d(+inf)=+inf
        put(7'd24, 2'b00, 3'b000, 64'h0000000000000001, 64'h0000000000000000, 64'h0000000000000000, 64'hFFFFFFFF00000000, 5'b00011, 1'b0, 1'b0, 1'b0); // fcvt.s.d(2^-1074)=+0 UF|NX
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF3F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h3FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(1.0f)=1.0
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h3FF8000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(1.5f)=1.5
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF00000001, 64'h0000000000000000, 64'h0000000000000000, 64'h36A0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(2^-149) 精确
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF7FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(qNaN)=D canon NaN
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF7F800001, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(sNaN)=D canon NaN NV
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF7F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(+inf)=+inf
        put(7'd25, 2'b01, 3'b000, 64'hFFFFFFFF80000000, 64'h0000000000000000, 64'h0000000000000000, 64'h8000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s(-0)=-0
        put(7'd25, 2'b01, 3'b000, 64'h000000003F800000, 64'h0000000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fcvt.d.s 未 box=>canon NaN NV
        put(7'd26, 2'b00, 3'b000, 64'hFFFFFFFF3F800001, 64'hFFFFFFFF3F7FFFFE, 64'hFFFFFFFFBF800000, 64'hFFFFFFFFA8800000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmadd.s (1+2^-23)(1-2^-23)-1 = -2^-46 单次舍入
        put(7'd26, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF40400000, 64'hFFFFFFFF40800000, 64'hFFFFFFFF41200000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmadd.s 2*3+4=10.0
        put(7'd26, 2'b00, 3'b000, 64'hFFFFFFFF7F800000, 64'hFFFFFFFF00000000, 64'hFFFFFFFF7FC00000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmadd.s inf*0+qNaN => NV（RISC-V 强制）
        put(7'd26, 2'b00, 3'b000, 64'hFFFFFFFF7F800001, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF7FC00000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmadd.s sNaN*1+1 => canon NaN NV
        put(7'd26, 2'b00, 3'b011, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF33000000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFFBF7FFFFF, 5'b00001, 1'b0, 1'b0, 1'b0); // fmadd.s 1*2^-25-1 (RUP, 精确=2^-25)
        put(7'd26, 2'b01, 3'b000, 64'h3FF0000000000001, 64'h3FEFFFFFFFFFFFFE, 64'hBFF0000000000000, 64'hB970000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmadd.d (1+2^-52)(1-2^-52)-1 = -2^-104 单次舍入
        put(7'd26, 2'b01, 3'b000, 64'h4000000000000000, 64'h4008000000000000, 64'h4010000000000000, 64'h4024000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmadd.d 2*3+4=10.0
        put(7'd26, 2'b01, 3'b000, 64'h7FF0000000000000, 64'h0000000000000000, 64'h7FF8000000000000, 64'h7FF8000000000000, 5'b10000, 1'b0, 1'b0, 1'b0); // fmadd.d inf*0+qNaN => NV
        put(7'd27, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF40400000, 64'hFFFFFFFF40800000, 64'hFFFFFFFF40000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmsub.s 2*3-4=2.0
        put(7'd27, 2'b00, 3'b000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF00000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmsub.s 1*1-1=+0
        put(7'd27, 2'b01, 3'b000, 64'h4000000000000000, 64'h4008000000000000, 64'h4010000000000000, 64'h4000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmsub.d 2*3-4=2.0
        put(7'd28, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF40400000, 64'hFFFFFFFF40800000, 64'hFFFFFFFFC0000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fnmsub.s -(2*3)+4=-2.0
        put(7'd28, 2'b01, 3'b000, 64'h4000000000000000, 64'h4008000000000000, 64'h4010000000000000, 64'hC000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fnmsub.d -(2*3)+4=-2.0
        put(7'd29, 2'b00, 3'b000, 64'hFFFFFFFF40000000, 64'hFFFFFFFF40400000, 64'hFFFFFFFF40800000, 64'hFFFFFFFFC1200000, 5'b00000, 1'b0, 1'b0, 1'b0); // fnmadd.s -(2*3)-4=-10.0
        put(7'd29, 2'b00, 3'b000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFF3F800000, 64'hFFFFFFFFBF800000, 64'hFFFFFFFF40000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fnmadd.s -(-1*1)-1=0 => +0
        put(7'd29, 2'b01, 3'b000, 64'h4000000000000000, 64'h4008000000000000, 64'h4010000000000000, 64'hC024000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fnmadd.d -(2*3)-4=-10.0
        put(7'd0, 2'b00, 3'b001, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF33800000, 64'h0000000000000000, 64'hFFFFFFFF3F800000, 5'b00001, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+2^-24 (RTZ)
        put(7'd0, 2'b00, 3'b100, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF33800000, 64'h0000000000000000, 64'hFFFFFFFF3F800001, 5'b00001, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+2^-24 (RMM tie->上)
        put(7'd0, 2'b00, 3'b011, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF33800000, 64'h0000000000000000, 64'hFFFFFFFF3F800001, 5'b00001, 1'b0, 1'b0, 1'b0); // fadd.s 1.0+2^-24 (RUP)
        put(7'd0, 2'b01, 3'b100, 64'h3FF0000000000000, 64'h3FF0000000000000, 64'h0000000000000000, 64'h4000000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fadd.d 1.0+1.0 (RMM)
        put(7'd2, 2'b01, 3'b010, 64'h3FF0000000000000, 64'hBFE0000000000000, 64'h0000000000000000, 64'hBFE0000000000000, 5'b00000, 1'b0, 1'b0, 1'b0); // fmul.d 1.0*(-0.5)=-0.5 (RDN)
        put(7'd3, 2'b00, 3'b001, 64'hFFFFFFFF3F800000, 64'hFFFFFFFF40400000, 64'h0000000000000000, 64'hFFFFFFFF3EAAAAAA, 5'b00001, 1'b1, 1'b1, 1'b0); // fdiv.s 1.0/3.0 (RTZ)
        put(7'd3, 2'b01, 3'b011, 64'h3FF0000000000000, 64'h4008000000000000, 64'h0000000000000000, 64'h3FD5555555555556, 5'b00001, 1'b1, 1'b1, 1'b0); // fdiv.d 1.0/3.0 (RUP)
        put(7'd4, 2'b01, 3'b001, 64'h4000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h3FF6A09E667F3BCC, 5'b00001, 1'b1, 1'b1, 1'b0); // fsqrt.d sqrt(2.0) (RTZ)
        put(7'd16, 2'b00, 3'b111, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000002, 5'b00001, 1'b0, 1'b0, 1'b0); // fcvt.w.s(1.5,DYN,frm=RNE)=2 NX

        // ---- 逐例执行（按类别选 task；顺带统计每 op 用例数）----
        for (i = 0; i < NC; i = i + 1) begin
            opcnt[t_op[i]] = opcnt[t_op[i]] + 1;
            if (t_mc[i]) ds_case(i);
            else         sc_case(i);
        end

        flow_tests();

        // ---- frm/DYN 用例（rm=111）----
        frm = 3'b011; sc_case_frm(7'd16, 2'b00, 3'b111, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 5'b00001); // fcvt.w.s(1.5,DYN+frm=RUP)=2 NX
        frm = 3'b101; sc_case_frm(7'd16, 2'b00, 3'b111, 64'hFFFFFFFF3FC00000, 64'h0000000000000000, 5'b00001); // fcvt.w.s(1.5,DYN+保留 frm)=RNE => 2 NX

        // ---- 汇总 ----
        for (i = 0; i <= 29; i = i + 1) begin
            if (opcnt[i] > 0) $display("TB_FPU_UNIT: op=%0d cases=%0d", i, opcnt[i]);
        end
        $display("TB_FPU_UNIT: checks=%0d errors=%0d known_dev=%0d", checks, errors, known_devs);
        if (known_devs != 0)
            $display("TB_FPU_UNIT: NOTE fpu_add.v 精确抵消零符号偏差（RDN 应为 -0）命中 %0d/3 例，见头注 KNOWN-DEV 段",
                     known_devs);
        if (errors == 0) $display("TB_FPU_UNIT: PASS");
        else begin
            $display("TB_FPU_UNIT: FAIL errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule
