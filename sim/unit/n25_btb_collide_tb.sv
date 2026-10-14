//==============================================================================
// sim/unit/n25_btb_collide_tb.sv —— N25 定向反证：BTB 同址同拍读写（NO_CHANGE 分叉可达性）
//------------------------------------------------------------------------------
// 目的（answer.md §五 N25 第 2/3 步的"反证实验"）：
//   ① 正控：证明"同址同拍 写+读"在 BTB 阵列（front4_mem_1r1w，**唯一**综合成 NO_CHANGE
//      的实例族）上**可达**，且探针能把它抓到（col_cnt 必须 == 1，否则 FAIL）；
//   ② 分叉可达性：该拍下 read_first（行为模型/声明口径）与 NO_CHANGE（综合实测口径，
//      见 fpga/out/n25_ipmode_btb_*_ram.rpt）给出**不同的命中判决**：
//        read_first → 读回**旧**条目（tag 命中，hit=1）
//        NO_CHANGE  → 输出寄存器**保持**上一拍那次读的值（tag 不匹配，hit=0）
//      ⇒ hit_rf=1 且 hit_nc=0，分叉可达（本 TB 必须实测到这一对值）；
//   ③ 负控：换成"写索引 ≠ 读索引"的同拍读写 ⇒ col_cnt 不得增加、不得出现分叉。
//   ④ 行为模型口径确认：碰撞拍下一拍读回的必须是**旧**条目（read_first），再下一拍才是新条目。
//
// 纪律：本文件不以 tb_ 开头 ⇒ 不进 scripts/regress.sh；不改任何产品 RTL；
//       只在**全部**判据成立时打印 `N25_INJECT: PASS`（fail-closed，见文件末尾判定）。
//
// 运行（见 fpga/scratch/n25_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n25_inj.vvp -s n25_btb_collide_tb \
//            "${RTL[@]}" sim/unit/n25_btb_collide_tb.sv && vvp /tmp/n25_inj.vvp
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module n25_btb_collide_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst_n = 1'b0;
    reg         lu_en = 1'b0;
    reg  [31:0] lu_pc = 32'h0;
    reg         upd_req = 1'b0;
    reg  [31:0] upd_pc = 32'h0;
    reg  [31:0] upd_target = 32'h0;
    reg         upd_is_cond = 1'b0, upd_is_call = 1'b0, upd_is_return = 1'b0;
    reg         upd_hit = 1'b0, upd_way = 1'b0;
    wire        lu_valid_o, lu_hit_o, lu_way_o;
    wire [31:0] lu_target_o;
    wire        lu_is_cond_o, lu_is_call_o, lu_is_return_o;
    wire [31:0] cnt_alloc;
    wire [31:0] cnt_updhit;

    bpu_btb #() u_dut (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc(lu_pc),
        .lu_valid_o(lu_valid_o), .lu_hit_o(lu_hit_o), .lu_way_o(lu_way_o),
        .lu_target_o(lu_target_o), .lu_is_cond_o(lu_is_cond_o),
        .lu_is_call_o(lu_is_call_o), .lu_is_return_o(lu_is_return_o),
        .upd_req(upd_req), .upd_pc(upd_pc), .upd_target(upd_target),
        .upd_is_cond(upd_is_cond), .upd_is_call(upd_is_call), .upd_is_return(upd_is_return),
        .upd_hit(upd_hit), .upd_way(upd_way), .cnt_alloc(cnt_alloc), .cnt_updhit(cnt_updhit)
    );

    //--------------------------------------------------------------------------
    // 地址（4 B 字地址粒度：索引 = PC[11:2]，tag = PC[31:2]）
    //--------------------------------------------------------------------------
    //  PC_A 与 PC_B **同索引 5**、tag 不同；PC_J 索引 6（用于制造"上一拍读了别的组"）。
    localparam [31:0] PC_A = 32'h8000_0014;   // idx=5, tag=0x2000_0005
    localparam [31:0] PC_B = 32'h8000_1014;   // idx=5, tag=0x2000_0405
    localparam [31:0] PC_J = 32'h8000_0018;   // idx=6, tag=0x2000_0006
    localparam [31:0] TGT_A = 32'h0000_A001;
    localparam [31:0] TGT_B = 32'h0000_B002;
    localparam [31:0] TGT_J = 32'h0000_7003;

    //--------------------------------------------------------------------------
    // 碰撞/分叉检测（与 sim/unit/n25_collision_probe.sv 的 C 族逻辑逐式同源）
    //--------------------------------------------------------------------------
    wire [9:0]  w0_aad = u_dut.u_way0.a_addr;
    wire [9:0]  w0_bad = u_dut.u_way0.b_addr;
    wire [65:0] w0_do  = u_dut.u_way0.b_dout;
    wire [65:0] w1_do  = u_dut.u_way1.b_dout;

    wire [9:0]  w1_aad = u_dut.u_way1.a_addr;
    wire [9:0]  w1_bad = u_dut.u_way1.b_addr;
    wire w0_aen = u_dut.u_way0.a_en;
    wire w0_ben = u_dut.u_way0.b_en;
    wire w1_aen = u_dut.u_way1.a_en;
    wire w1_ben = u_dut.u_way1.b_en;

    wire col_c = (w0_aen & w0_ben & (w0_aad == w0_bad)) | (w1_aen & w1_ben & (w1_aad == w1_bad));

    reg        col_a, rst_a;
    reg [65:0] w0_hd_a, w1_hd_a;
    always @(posedge clk) begin
        col_a  <= col_c;
        rst_a  <= rst_n;
        w0_hd_a <= w0_do;
        w1_hd_a <= w1_do;
    end

    integer col_cnt     = 0;   // 碰撞拍数（全运行）
    integer valdiff_cnt = 0;   // read_first vs NO_CHANGE 读回值不同拍数
    integer hitdiff_cnt = 0;   // 命中判决不同拍数
    integer falsehit_cnt= 0;   // 只可能为 0：NO_CHANGE 命中 ∧ read_first 未命中（本结构不可达）
    reg     hit_rf, hit_nc;

    wire [29:0] tq = u_dut.lu_tag_q;
    wire        tv = u_dut.lu_valid_q;

    always @(posedge clk) if (rst_a) begin
        if (col_a) begin
            col_cnt = col_cnt + 1;
            if (w0_do !== w0_hd_a) valdiff_cnt = valdiff_cnt + 1;
            hit_rf = tv & w0_do[0]     & (w0_do[30:1]     == tq);
            hit_nc = tv & w0_hd_a[0]   & (w0_hd_a[30:1]   == tq);
            if (hit_rf !== hit_nc) hitdiff_cnt = hitdiff_cnt + 1;
            if (hit_nc & ~hit_rf)  falsehit_cnt = falsehit_cnt + 1;
        end
    end

    //--------------------------------------------------------------------------
    // 观测缓存（每个观测点把当拍实际值存下来，最后统一判定）
    //--------------------------------------------------------------------------
    reg        o_hit_m1_valid;      // 碰撞下一拍：read_first 模型命中？
    reg [31:0] o_tgt_m1;            // 碰撞下一拍：read_first 模型目标
    reg [65:0] o_do_m1;             // 碰撞下一拍：read_first 模型读回值（应为旧条目 A）
    reg [65:0] o_do_m2;             // 碰撞后第 2 拍：应已看到新条目 B
    reg [7:0]  col_at_test;
    reg        hit_rf_at_test, hit_nc_at_test;

    // 条目字段（bpu_btb.v:84-91）
    function [29:0] f_tag;  input [65:0] e; begin f_tag = e[30:1]; end endfunction
    function        f_val;  input [65:0] e; begin f_val = e[0];    end endfunction
    function [31:0] f_tgt;  input [65:0] e; begin f_tgt = e[62:31]; end endfunction

    integer i;
    integer errs = 0;
    reg all_ok;

    initial begin
        $display("N25_INJECT: start");
        // ---- 复位 ----
        rst_n = 1'b0; lu_en = 1'b0; upd_req = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 预置：索引 5 ← PC_A/TGT_A（way0，LRU=0）；索引 6 ← PC_J/TGT_J（way0） ----
        @(negedge clk);
        upd_req = 1'b1; upd_pc = PC_A; upd_target = TGT_A; upd_hit = 1'b0; upd_way = 1'b0;
        @(posedge clk); @(negedge clk);
        upd_req = 1'b0;
        repeat (2) @(posedge clk);

        @(negedge clk);
        upd_req = 1'b1; upd_pc = PC_J; upd_target = TGT_J; upd_hit = 1'b0; upd_way = 1'b0;
        @(posedge clk); @(negedge clk);
        upd_req = 1'b0;
        repeat (2) @(posedge clk);

        // ---- 正控 + 分叉：先读索引 6（把"上一拍输出"设成 PC_J 的条目），
        //      再同拍"读 PC_A@索引5 + 写 PC_B@索引5" ----
        @(negedge clk); lu_en = 1'b1; lu_pc = PC_J;    // 上一拍：读别的组（索引 6）
        @(posedge clk);                                // P0：发起对索引 6 的读
        @(negedge clk);
        lu_pc = PC_A;                                  // 本拍：读索引 5（旧条目 = PC_A）
        upd_req = 1'b1; upd_pc = PC_B; upd_target = TGT_B; upd_hit = 1'b1; upd_way = 1'b0;
        @(posedge clk);                                // P1：← 碰撞沿（写 PC_B@5 与读 PC_A@5 同拍）
        @(negedge clk);                                // P1→P2 窗内：read_first 口径的读回结果
        upd_req = 1'b0;                                // 立刻撤写，避免 P2 再撞一次
        o_hit_m1_valid = lu_hit_o; o_tgt_m1 = lu_target_o; o_do_m1 = w0_do;
        @(posedge clk);                                // P2：分叉判决在此沿更新；模型读回**新**条目 B
        @(negedge clk);                                // P2→P3 窗内（避开同沿竞争，稳定取样）
        col_at_test = col_cnt[7:0];
        hit_rf_at_test = hit_rf; hit_nc_at_test = hit_nc;
        o_do_m2 = w0_do;                               // 应为新条目 B
        lu_en = 1'b0;
        repeat (2) @(posedge clk);

        // ---- 负控：写索引 ≠ 读索引（写 PC_B@索引5，读 PC_J@索引6）⇒ 不得算碰撞 ----
        //   注：放在正控之后 —— 正控已把索引 5 的旧条目改掉，负控只关心"不同索引不算碰撞"。
        @(negedge clk);
        lu_en = 1'b1; lu_pc = PC_J;
        upd_req = 1'b1; upd_pc = PC_B; upd_target = TGT_B; upd_hit = 1'b1; upd_way = 1'b0;
        @(posedge clk);                                // 写索引 5 + 读索引 6（不同索引）
        @(negedge clk);
        upd_req = 1'b0;                                // 只留读
        @(posedge clk);                                // 负控观测拍
        @(negedge clk);
        if (col_cnt != col_at_test) begin
            $display("N25_INJECT: 负控失败 —— 不同索引同拍读写被误判为碰撞（%0d -> %0d）", col_at_test, col_cnt);
            errs = errs + 1;
        end
        lu_en = 1'b0;
        repeat (2) @(posedge clk);

        //==========================================================================
        // 判定（fail-closed：逐项列出，全过才 PASS）
        //==========================================================================
        all_ok = 1'b1;
        $display("N25_INJECT: col_cnt=%0d (期望恰好 1；负控拍不计) valdiff=%0d hitdiff=%0d falsehit=%0d",
                 col_cnt, valdiff_cnt, hitdiff_cnt, falsehit_cnt);
        $display("N25_INJECT: 碰撞下一拍 read_first 命中=%b 目标=0x%08x 读回条目{tgt=0x%08x,tag=0x%08x,val=%b}",
                 o_hit_m1_valid, o_tgt_m1, f_tgt(o_do_m1), f_tag(o_do_m1), f_val(o_do_m1));
        $display("N25_INJECT: 再下一拍读回条目{tgt=0x%08x,tag=0x%08x,val=%b}",
                 f_tgt(o_do_m2), f_tag(o_do_m2), f_val(o_do_m2));
        $display("N25_INJECT: 碰撞拍 hit_rf=%b hit_nc=%b （期望 1 / 0）", hit_rf_at_test, hit_nc_at_test);

        if (col_cnt != 1)                       begin $display("N25_INJECT: 判据①失败 碰撞计数 %0d != 1", col_cnt); all_ok = 1'b0; end
        if (valdiff_cnt != 1)                   begin $display("N25_INJECT: 判据②失败 读回值分叉计数 %0d != 1", valdiff_cnt); all_ok = 1'b0; end
        if (hitdiff_cnt != 1)                   begin $display("N25_INJECT: 判据③失败 命中判决分叉计数 %0d != 1", hitdiff_cnt); all_ok = 1'b0; end
        if (falsehit_cnt != 0)                  begin $display("N25_INJECT: 判据④失败 出现 NO_CHANGE 假命中 %0d 次", falsehit_cnt); all_ok = 1'b0; end
        if (hit_rf_at_test !== 1'b1 || hit_nc_at_test !== 1'b0)
                                                begin $display("N25_INJECT: 判据⑤失败 碰撞拍 hit_rf/hit_nc 不是 1/0"); all_ok = 1'b0; end
        //   碰撞下一拍必须命中旧条目 A（read_first），而不是保持上一拍索引 6 的条目 J
        if (!(o_hit_m1_valid && (o_tgt_m1 == TGT_A) && f_val(o_do_m1) && (f_tag(o_do_m1) == PC_A[31:2])))
                                                begin $display("N25_INJECT: 判据⑥失败 模型未按 read_first 返回旧条目 A"); all_ok = 1'b0; end
        //   再下一拍必须能看到新写入的条目 B
        if (!(f_val(o_do_m2) && (f_tag(o_do_m2) == PC_B[31:2]) && (f_tgt(o_do_m2) == TGT_B)))
                                                begin $display("N25_INJECT: 判据⑦失败 再下一拍未看到新条目 B"); all_ok = 1'b0; end
        if (errs != 0)                          all_ok = 1'b0;

        if (all_ok) $display("N25_INJECT: PASS");
        else        $display("N25_INJECT: FAIL");
        $finish;
    end

endmodule
