//==============================================================================
// sim/unit/b29_wire_probe.sv —— B29 工具归因最小反证（独立、不依赖全设计）
//------------------------------------------------------------------------------
// 目的（母代理第 32 轮任务 1）：在**最小场景**里检验 iverilog 12.0 是否会出现
//   "同一拍：$display 打印组合 wire → 3，而同拍 NBA 采样同一 wire → 1"。
// 构造与本设计同构（见 rtl/back2/prf.v 的读口）：
//   · 存储阵列 mem + **写优先旁路**（`we ? wd : mem[ra]`）；
//   · 旁路的选通/地址/数据由**同一时间步内更晚的 delta**改变（模拟组合逻辑的固有竞争）；
//   · 一个 always 块里同拍做两件事：`$display` 打印 rd、NBA 把 rd 采样进 rd_q。
// 判据（两种结论都输出 PASS 锚点，本文件是**诊断探针**不是判据用例）：
//   · 采样值 ≠ 打印值 ⇒ **复现**：工具层取值差异成立（B29 归因钉死）；
//   · 相等 ⇒ **未复现**：回到"采样点/采样拍"方向。
// 运行：iverilog -g2012 -o /tmp/b29p.vvp sim/unit/b29_wire_probe.sv && vvp /tmp/b29p.vvp
//==============================================================================
`timescale 1ns / 1ps

module b29_wire_probe;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    // ---- 存储阵列 + 写优先旁路（与 prf.v 读口同构）----
    reg  [31:0] mem [0:7];
    reg  [2:0]  wa, ra;
    reg  [31:0] wd;
    reg         we;
    wire [31:0] rd = we ? wd : mem[ra];

    reg  [31:0] rd_q;         // NBA 采样（下一拍可见）
    reg  [31:0] print_q;      // 同拍 $display 的值（供比对）
    integer     n_cyc = 0;
    integer     n_repro = 0;

    initial begin
        mem[3] = 32'h0000_0003;      // 阵列里是 3（= x11 的正确值）
        ra = 3'd3; wa = 3'd0; wd = 32'h0; we = 1'b0;
    end

    // ---- 竞争源：在同一时间步的**更晚 delta** 里把旁路打开（指向同一读地址，数据=1）----
    always @(posedge clk) begin
        #0;                          // 进入本时间步的后续 delta（模拟组合逻辑的 delta 行为）
        we = 1'b1; wa = 3'd3; wd = 32'h0000_0001;
        #1 we = 1'b0;                // 1 ns 后撤销（不跨时钟沿）
    end

    // ---- 采样与打印**同拍**进行（这是 B29 现象的最小复现条件）----
    always @(posedge clk) begin
        n_cyc <= n_cyc + 1;
        print_q <= rd;                       // 同拍打印值的快照（NBA）
        rd_q    <= rd;                       // 同拍"采样"（NBA）
        if (n_cyc >= 1 && n_cyc <= 3) begin
            $display("[b29-probe cyc=%0d t=%0t] display rd=0x%08x | sampled rd_q=0x%08x",
                     n_cyc, $time, rd, rd_q);
            if (rd_q !== rd) n_repro <= n_repro + 1;
        end
    end

    initial begin
        repeat (6) @(posedge clk);
        if (n_repro > 0)
            $display("B29-PROBE: 复现（同拍打印与采样不一致，次数=%0d）⇒ 工具层取值差异成立", n_repro);
        else
            $display("B29-PROBE: 未复现（同拍打印与采样一致）⇒ 回归采样点/采样拍方向");
        $display("TB_B29_WIRE_PROBE: PASS");
        $finish;
    end
endmodule
