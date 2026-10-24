//==============================================================================
// sim/functional/tb_top_control_semantics.sv
//   —— 顶层 Zicntr / mtime / MPP 语义 + minstret 双提交组合 的功能定向 TB
//==============================================================================
// 目的（F4-0/F1-B 顶层接线验收；叶模块 `tb_counter_time` 只证接口合同）:
//   在**真实 top**（core_top / core_top_2b）上跑**真实 RV32 程序**，验证：
//     C1  写 mcycleh → 紧邻读 cycleh（mcycle↔cycle 别名）
//     C2  写 mcycle 低半 → 读 cycle 低半（别名，低半确实被写）
//     C3  mcycle 64 位本体：低半 0xFFFF_FFFE 自然溢出 ⇒ 高半 == 1（进位）
//     C4  写 mcycleh 不动低半（低半继续 tick）、高半精确
//     C5  MMIO 写 CLINT mtime → time/timeh 读到新值窗口；cycleh ≠ timeh（time ≠ cycle）
//     C6  mtime 自由计数：连续两次读 time 严格递增
//     C7  MPP WARL：写 2'b10（保留）读回 2'b01（S）
//     C8  MPP WARL：写 2'b11（M）读回 2'b11
//     C9  MPP WARL：写 2'b00（U）读回 2'b00
//     C10 写 mcycle 低半 → mcycle/cycle 双读都在小窗口内且一致
//     C11 写 minstret 低半 → 读 minstret（2A 精确复读；2B 拍数窗口）
//     C12 写 minstreth → 读 instreth（高半写；低半保持递增）
//     C13 写 minstret 低半 = 0x8000_0000 不得改高半（写低不得伪命中读高）
//     C14（仅 2A）RMW 先后：csrrs 的读必须看到刚写入的 minstret（写替代自身 +1），
//         新值 = old | mask，随后读回 = 新值（两级旁路）。mask 提前备好，
//         避免把"更老指令的 +1"混进期望（那属周期级 oracle 覆盖范围）。
//   另加**周期级 oracle**（TB 侧独立规格模型，逐拍比对本体下一拍值）：
//     · mcycle：先整 64 位 +1，再覆盖被写半字（写高半时低半仍 +1）
//     · minstret：写拍 = older → 半字覆盖（本条 +1 被替代）→ younger；
//                非写拍 = 本体 + 本拍 qualified 提交数
//     · 2B 提交组合：硬断言 lane0=CSR(minstret)+lane1=ALU（older=0,younger=1）真实出现；
//       lane0=ALU+lane1=CSR(minstret)（older=1,younger=0）要求 CSR 不在 ROB 头提交，
//       而当前后端 CSR 仅在 ROB 头执行 ⇒ 实测不可达；出现则计数并由同一 oracle 校验，
//       未出现则打印 `TOP_CONTROL_SEMANTICS_OPEN` 作为未闭项（**不**宣称已覆盖两种）。
//
// 结构:
//   tb_top_control_semantics
//     ├── u_dut_a : core_top     （48 端口契约；仅 +TOP=2a 时释放复位）
//     ├── u_dut_b : core_top_2b  （同上；仅 +TOP=2b 时释放复位）
//     ├── u_mem_a/u_mem_b : sim_mem_model（各自独立存储；XIP + DDR + UART 捕获）
//     └── 结果通道（按 DUT 分路）：
//           · 2A：程序把 32 位结果**按字节写 UART 数据寄存器**（0x1FE0_01E0，
//             非缓存路径）⇒ TB 收字节拼字。
//           · 2B：写 DDR 邮箱字（0x8000_2000 起）+ cbo.flush 写回 ⇒ TB 读存储模型。
//             原因：2B 的 uncached 强副作用 store 重放/竞态尚未闭环（F4-1 未完成项），
//             字节流通道会被重复字节打乱；邮箱字写幂等。
//
// 装载方式（均为 TB 侧存储模型预载 / 端口驱动，不 force DUT 内部状态）:
//   · 程序路径走**编译期参数** `PROG2A` / `PROG2B`（由驱动脚本用 -P 传绝对路径；
//     iverilog 12.0 的 `%s` plusarg 不可靠，项目既有 TB 亦无先例）。
//   · 2A：`load_xip_hex` 载入 XIP @0x1C00_0000（复位取指点）。
//   · 2B：TB 解析 `@0x8000_0000` 起的数据字写入 DDR 模型（该核把 a[31:20]==0x800
//     映射到 0x0000_xxxx，映射在 **TB 侧**做）；XIP[0..1] 放 lui/jalr 跳板到
//     0x8000_0000（与既有 `tb_core_top_2b` 同口径）。
//   · 运行期只用数值 plusarg `+TOP2B=0|1` 选 DUT。
//
// 判据（fail-closed；输出未捕获/超时/溢出/多锚点一律失败）:
//   · 程序结果流 = [MAGIC, NCHK, r1..rNCHK, DONE]，每个 r 必须 == 1；字节数精确。
//   · 周期级 oracle 零不符；2B 两种提交组合计数均 > 0。
//   · 唯一成功行：`TB_TOP_CONTROL_SEMANTICS: PASS`（整行恰好一次）。
//   · 失败行：`FAIL: ...` + `$fatal`（rc≠0），绝不打印成功锚点。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "sim/tb/sim_mem_model.sv"

module tb_top_control_semantics #(
    parameter integer CLK_HALF_NS  = 5,
    parameter integer RESET_CYCLES = 20,
    parameter integer MAX_CYCLES   = 60000,
    parameter integer DRAIN_CYCLES = 300,
    // 程序 hex 路径（由驱动脚本用 -P 传入绝对路径；空串 = 该模式不可用）
    parameter [8*512-1:0] PROG2A = "",
    parameter [8*512-1:0] PROG2B = ""
) ();

    localparam [31:0] MAGIC = 32'h5443_3031;   // "TC01"
    localparam [31:0] DONE  = 32'hDEAD_BEEF;
    localparam [31:0] MAGIC2 = 32'h5443_494E;   // 2A C15 info 魔数 "TCIN"

    //==========================================================================
    // 0. 选择 DUT / 程序路径 / 时钟复位
    //==========================================================================
    reg     use_2b;
    integer pa_top2b;

    // ★ 只用数值 plusarg 选择 DUT；程序路径走编译期参数（iverilog 的 %s plusarg
    //   在 12.0 上不可靠，项目既有 TB 亦无 %s 先例）
    initial begin
        use_2b = 1'b0;
        if ($value$plusargs("TOP2B=%d", pa_top2b)) use_2b = (pa_top2b != 0);
    end

    reg clk;
    reg rst_a_n, rst_b_n;
    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    //==========================================================================
    // 1. AXI 连线（两个 DUT 各一套；未选中的 DUT 保持复位，不驱动有效请求）
    //==========================================================================
    wire [3:0]  a_arid,  a_awid,  a_wid;
    wire [31:0] a_araddr, a_awaddr, a_wdata;
    wire [3:0]  a_arlen, a_awlen, a_wstrb;
    wire [2:0]  a_arsize, a_awsize, a_arprot, a_awprot;
    wire [1:0]  a_arburst, a_awburst, a_arlock, a_awlock;
    wire [3:0]  a_arcache, a_awcache;
    wire        a_arvalid, a_arready, a_awvalid, a_awready;
    wire        a_wlast, a_wvalid, a_wready, a_bvalid, a_bready;
    wire [3:0]  a_rid, a_bid;
    wire [31:0] a_rdata;
    wire [1:0]  a_rresp, a_bresp;
    wire        a_rlast, a_rvalid, a_rready;
    wire        a_ws_valid, a_rf_rdata;
    wire [31:0] a_dbg_pc, a_dbg_wdata;
    wire [3:0]  a_dbg_wen;
    wire [4:0]  a_dbg_wnum;

    wire [3:0]  b_arid,  b_awid,  b_wid;
    wire [31:0] b_araddr, b_awaddr, b_wdata;
    wire [3:0]  b_arlen, b_awlen, b_wstrb;
    wire [2:0]  b_arsize, b_awsize, b_arprot, b_awprot;
    wire [1:0]  b_arburst, b_awburst, b_arlock, b_awlock;
    wire [3:0]  b_arcache, b_awcache;
    wire        b_arvalid, b_arready, b_awvalid, b_awready;
    wire        b_wlast, b_wvalid, b_wready, b_bvalid, b_bready;
    wire [3:0]  b_rid, b_bid;
    wire [31:0] b_rdata;
    wire [1:0]  b_rresp, b_bresp;
    wire        b_rlast, b_rvalid, b_rready;
    wire        b_ws_valid, b_rf_rdata;
    wire [31:0] b_dbg_pc, b_dbg_wdata;
    wire [3:0]  b_dbg_wen;
    wire [4:0]  b_dbg_wnum;

    // 未接的调试输入（TB 驱动常量；端口契约要求）
    wire [31:0] rf_rdata_a_unused, rf_rdata_b_unused;

    //==========================================================================
    // 2. DUT 例化（48 端口逐字契约；端口名以两 top 声明为准）
    //==========================================================================
    core_top u_dut_a (
        .aclk(clk), .intrpt(8'h00), .aresetn(rst_a_n),
        .arid(a_arid), .araddr(a_araddr), .arlen(a_arlen), .arsize(a_arsize),
        .arburst(a_arburst), .arlock(a_arlock), .arcache(a_arcache), .arprot(a_arprot),
        .arvalid(a_arvalid), .arready(a_arready),
        .rid(a_rid), .rdata(a_rdata), .rresp(a_rresp), .rlast(a_rlast),
        .rvalid(a_rvalid), .rready(a_rready),
        .awid(a_awid), .awaddr(a_awaddr), .awlen(a_awlen), .awsize(a_awsize),
        .awburst(a_awburst), .awlock(a_awlock), .awcache(a_awcache), .awprot(a_awprot),
        .awvalid(a_awvalid), .awready(a_awready),
        .wid(a_wid), .wdata(a_wdata), .wstrb(a_wstrb), .wlast(a_wlast),
        .wvalid(a_wvalid), .wready(a_wready),
        .bid(a_bid), .bresp(a_bresp), .bvalid(a_bvalid), .bready(a_bready),
        .ws_valid(a_ws_valid), .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0),
        .rf_rdata(rf_rdata_a_unused),
        .debug0_wb_pc(a_dbg_pc), .debug0_wb_rf_wen(a_dbg_wen),
        .debug0_wb_rf_wnum(a_dbg_wnum), .debug0_wb_rf_wdata(a_dbg_wdata)
    );

    core_top_2b u_dut_b (
        .aclk(clk), .intrpt(8'h00), .aresetn(rst_b_n),
        .arid(b_arid), .araddr(b_araddr), .arlen(b_arlen), .arsize(b_arsize),
        .arburst(b_arburst), .arlock(b_arlock), .arcache(b_arcache), .arprot(b_arprot),
        .arvalid(b_arvalid), .arready(b_arready),
        .rid(b_rid), .rdata(b_rdata), .rresp(b_rresp), .rlast(b_rlast),
        .rvalid(b_rvalid), .rready(b_rready),
        .awid(b_awid), .awaddr(b_awaddr), .awlen(b_awlen), .awsize(b_awsize),
        .awburst(b_awburst), .awlock(b_awlock), .awcache(b_awcache), .awprot(b_awprot),
        .awvalid(b_awvalid), .awready(b_awready),
        .wid(b_wid), .wdata(b_wdata), .wstrb(b_wstrb), .wlast(b_wlast),
        .wvalid(b_wvalid), .wready(b_wready),
        .bid(b_bid), .bresp(b_bresp), .bvalid(b_bvalid), .bready(b_bready),
        .ws_valid(b_ws_valid), .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0),
        .rf_rdata(rf_rdata_b_unused),
        .debug0_wb_pc(b_dbg_pc), .debug0_wb_rf_wen(b_dbg_wen),
        .debug0_wb_rf_wnum(b_dbg_wnum), .debug0_wb_rf_wdata(b_dbg_wdata)
    );

    //==========================================================================
    // 3. 存储模型（每 DUT 一套，互不干扰）
    //==========================================================================
    wire [7:0] uart_ch_a, uart_ch_b;
    wire       uart_v_a, uart_v_b;

    sim_mem_model #(
        .XIP_BASE(32'h1C00_0000), .XIP_ALIAS(`RV32GC_XIP_ALIAS), .XIP_SIZE(32'h0000_4000),
        .DDR3_BASE(32'h0000_0000), .DDR3_LIMIT(32'h0001_0000),
        .UART_DATA_ADDR(32'h1FE0_01E0), .READ_LAT_DLY(0)
    ) u_mem_a (
        .clk(clk), .rst_n(rst_a_n),
        .arid(a_arid), .araddr(a_araddr), .arlen(a_arlen), .arsize(a_arsize),
        .arburst(a_arburst), .arlock(a_arlock), .arcache(a_arcache), .arprot(a_arprot),
        .arvalid(a_arvalid), .arready(a_arready),
        .rid(a_rid), .rdata(a_rdata), .rresp(a_rresp), .rlast(a_rlast),
        .rvalid(a_rvalid), .rready(a_rready),
        .awid(a_awid), .awaddr(a_awaddr), .awlen(a_awlen), .awsize(a_awsize),
        .awburst(a_awburst), .awlock(a_awlock), .awcache(a_awcache), .awprot(a_awprot),
        .awvalid(a_awvalid), .awready(a_awready),
        .wid(a_wid), .wdata(a_wdata), .wstrb(a_wstrb), .wlast(a_wlast),
        .wvalid(a_wvalid), .wready(a_wready),
        .bid(a_bid), .bresp(a_bresp), .bvalid(a_bvalid), .bready(a_bready),
        .uart_char(uart_ch_a), .uart_char_valid(uart_v_a),
        .uart_tx_count(), .uart_overflow(), .uart_bad_strb_count()
    );

    //   ★ 2B 程序地址别名：DUT 发 a[31:20]==0x800 ⇒ 存储模型看 a[19:0]
    //     （与 `tb_core_top_2b` 的 map_addr 同口径；**必须在 TB 侧做**，
    //      否则存储模型把 0x8000_0000 当未登记区域读 0 ⇒ 程序跑飞）。
    function [31:0] b_map_addr; input [31:0] a;
        begin b_map_addr = (a[31:20] == 12'h800) ? {12'h000, a[19:0]} : a; end
    endfunction
    wire [31:0] b_araddr_m = b_map_addr(b_araddr);
    wire [31:0] b_awaddr_m = b_map_addr(b_awaddr);

    sim_mem_model #(
        .XIP_BASE(32'h1C00_0000), .XIP_ALIAS(`RV32GC_XIP_ALIAS), .XIP_SIZE(32'h0000_1000),
        .DDR3_BASE(32'h0000_0000), .DDR3_LIMIT(32'h0004_0000),
        .UART_DATA_ADDR(32'h1FE0_01E0), .READ_LAT_DLY(0)
    ) u_mem_b (
        .clk(clk), .rst_n(rst_b_n),
        .arid(b_arid), .araddr(b_araddr_m), .arlen(b_arlen), .arsize(b_arsize),
        .arburst(b_arburst), .arlock(b_arlock), .arcache(b_arcache), .arprot(b_arprot),
        .arvalid(b_arvalid), .arready(b_arready),
        .rid(b_rid), .rdata(b_rdata), .rresp(b_rresp), .rlast(b_rlast),
        .rvalid(b_rvalid), .rready(b_rready),
        .awid(b_awid), .awaddr(b_awaddr_m), .awlen(b_awlen), .awsize(b_awsize),
        .awburst(b_awburst), .awlock(b_awlock), .awcache(b_awcache), .awprot(b_awprot),
        .awvalid(b_awvalid), .awready(b_awready),
        .wid(b_wid), .wdata(b_wdata), .wstrb(b_wstrb), .wlast(b_wlast),
        .wvalid(b_wvalid), .wready(b_wready),
        .bid(b_bid), .bresp(b_bresp), .bvalid(b_bvalid), .bready(b_bready),
        .uart_char(uart_ch_b), .uart_char_valid(uart_v_b),
        .uart_tx_count(), .uart_overflow(), .uart_bad_strb_count()
    );

    //==========================================================================
    // 4. 程序装载（TB 侧存储模型预载；不碰 DUT 内部状态）
    //==========================================================================
    //   2B 的地址映射与 `tb_core_top_2b` 同口径：DUT 发 a[31:20]==0x800 的地址，
    //   存储模型看到 a[19:0]（即 0x8000_0000+n ⇒ 0x0000_0000+n）。
    task automatic load_ddr_hex;
        input [8*512-1:0] path;
        input [31:0]      ddr_base;   // 程序链接基址（0x8000_0000）
        integer fd, c, v, cur, i;
        reg [31:0] addr;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FAIL: 打不开 2B 程序文件 %0s", path);
                $fatal(1, "TB_TOP_CONTROL_SEMANTICS 装载失败");
            end
            addr = ddr_base;
            c = $fgetc(fd);
            while (c != -1) begin
                if (c == "@") begin
                    c = $fgetc(fd); v = 0;
                    while (((c >= "0") && (c <= "9")) ||
                           ((c >= "a") && (c <= "f")) ||
                           ((c >= "A") && (c <= "F"))) begin
                        if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                        else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                        else                               v = (v << 4) | (c - "A" + 10);
                        c = $fgetc(fd);
                    end
                    addr = v[31:0];
                end else if (((c >= "0") && (c <= "9")) ||
                             ((c >= "a") && (c <= "f")) ||
                             ((c >= "A") && (c <= "F"))) begin
                    v = 0;
                    while (((c >= "0") && (c <= "9")) ||
                           ((c >= "a") && (c <= "f")) ||
                           ((c >= "A") && (c <= "F"))) begin
                        if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                        else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                        else                               v = (v << 4) | (c - "A" + 10);
                        c = $fgetc(fd);
                    end
                    if (addr < ddr_base) begin
                        $display("FAIL: 2B 程序地址 0x%08h 低于基址 0x%08h", addr, ddr_base);
                        $fatal(1, "TB_TOP_CONTROL_SEMANTICS 装载失败");
                    end
                    u_mem_b.ddr3_mem[(addr - ddr_base) >> 2] = v[31:0];
                    addr = addr + 32'd4;
                end else begin
                    c = $fgetc(fd);
                end
            end
            $fclose(fd);
            for (i = 0; i < 1024; i = i + 1) u_mem_b.xip_mem[i] = 32'h0000_0013;
            //   跳板：lui x5, 0x80000 ; jalr x0, 0(x5)
            u_mem_b.xip_mem[0] = 32'h8000_02b7;
            u_mem_b.xip_mem[1] = 32'h0002_8067;
            $display("[tb_top_control_semantics] 2B 程序装载 path=%0s base=0x%08h", path, ddr_base);
        end
    endtask

    //   2A DDR 驻留装载：程序链接基址 0x1C00_0000，运行基址 0x1000（物理 DDR=0）。
    //   XIP 头两指令跳板：lui t0,0x1 ; jalr x0,0(t0) ⇒ 跳到 0x1000，之后全在 DDR 执行，
    //   L1I 可缓存 ⇒ 相邻指令可 1 拍/条（C15 的写/读交叠窗口由此可达）。
    task automatic load_ddr_hex_a;
        input [8*512-1:0] path;
        input [31:0]      link_base;
        input [31:0]      run_base;
        integer fd, c, v, xw;
        reg [31:0] addr, cur;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FAIL: 打不开 2A 程序文件 %0s", path);
                $fatal(1, "TB_TOP_CONTROL_SEMANTICS 装载失败");
            end
            addr = link_base; cur = run_base;
            c = $fgetc(fd);
            while (c != -1) begin
                if (c == "@") begin
                    c = $fgetc(fd); v = 0;
                    while (((c >= "0") && (c <= "9")) ||
                           ((c >= "a") && (c <= "f")) ||
                           ((c >= "A") && (c <= "F"))) begin
                        if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                        else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                        else                               v = (v << 4) | (c - "A" + 10);
                        c = $fgetc(fd);
                    end
                    addr = v[31:0];
                    cur  = run_base + (addr - link_base);
                end else if (((c >= "0") && (c <= "9")) ||
                             ((c >= "a") && (c <= "f")) ||
                             ((c >= "A") && (c <= "F"))) begin
                    v = 0;
                    while (((c >= "0") && (c <= "9")) ||
                           ((c >= "a") && (c <= "f")) ||
                           ((c >= "A") && (c <= "F"))) begin
                        if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                        else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                        else                               v = (v << 4) | (c - "A" + 10);
                        c = $fgetc(fd);
                    end
                    u_mem_a.ddr3_mem[cur >> 2] = v[31:0];
                    cur = cur + 32'd4;
                end else begin
                    c = $fgetc(fd);
                end
            end
            $fclose(fd);
            for (xw = 0; xw < 1024; xw = xw + 1) u_mem_a.xip_mem[xw] = 32'h0000_0013;
            u_mem_a.xip_mem[0] = 32'h0000_12b7;   // lui  t0, 0x1  (=0x1000)
            u_mem_a.xip_mem[1] = 32'h0002_8067;   // jalr x0, 0(t0)
            $display("[tb_top_control_semantics] 2A DDR 程序装载 path=%0s run_base=0x%08h (trampoline@XIP)",
                     path, run_base);
        end
    endtask

    integer lc;
    initial begin
        ddr2a_en = 0;
        if ($value$plusargs("DDR2A=%d", ddr2a_en)) ddr2a_en = (ddr2a_en != 0);
        rst_a_n = 1'b0;
        rst_b_n = 1'b0;
        // 2B 程序区/跳板先全填 nop，再装载（与既有 2B TB 同口径）
        for (lc = 0; lc < 8192; lc = lc + 1) u_mem_b.ddr3_mem[lc] = 32'h0000_0013;
        for (lc = 0; lc < 1024; lc = lc + 1) u_mem_b.xip_mem[lc]  = 32'h0000_0013;
        load_ddr_hex(PROG2B, 32'h8000_0000);
        if (ddr2a_en != 0) begin
            load_ddr_hex_a(PROG2A, 32'h1C00_0000, 32'h0000_1000);
        end else begin
            u_mem_a.load_xip_hex(PROG2A);
        end
        if ((ddr2a_en == 0) && (u_mem_a.load_err != 0)) begin
            $display("FAIL: 2A 程序装载失败 err=%0d path=%0s", u_mem_a.load_err, PROG2A);
            $fatal(1, "TB_TOP_CONTROL_SEMANTICS 装载失败");
        end
        #(RESET_CYCLES * 2 * CLK_HALF_NS);
        if (use_2b) rst_b_n = 1'b1;
        else        rst_a_n = 1'b1;
    end

    //==========================================================================
    // 5. 结果字节流（程序：32 位字按字节写 UART；TB 拼字）
    //==========================================================================
    wire sel_char_valid = use_2b ? uart_v_b : uart_v_a;
    wire [7:0] sel_char  = use_2b ? uart_ch_b : uart_ch_a;

    //  2A：结果经 UART 字节流（程序按字节写，TB 拼 32 位字）。
    //  2B：结果经 DDR **邮箱字**（0x8000_2000 → 存储模型 0x2000）+ cbo.flush 写回。
    //      理由：2B 的 uncached 强副作用 store 竞态/重放尚未闭环（F4-1 未完成项）
    //      ⇒ **不能**用"一个字节一条 uncached store"的结果通道；邮箱字写是
    //      幂等的（重放写同址同值），且 flush 后 TB 直接读存储模型判据。
    localparam integer MBW = 32'h0000_2000 >> 2;   // 邮箱字下标（2B）

    reg [7:0]  rx [0:4095];
    reg [31:0] res_w [0:47];
    integer    rx_n;
    integer    n_words;
    integer    nchk;
    integer    bad_magic, bad_done, bad_nchk;
    integer    info_n;              // 2A C15 info 字数（0 或 5）
    reg [31:0] info_d, info_t1, info_t2, info_t3;
    integer    bad_idx, bad_val;
    integer    done_seen;
    reg [31:0] w_sh;
    integer    mi;

    initial begin
        rx_n = 0; n_words = 0; nchk = 0;
        bad_magic = 0; bad_done = 0; bad_nchk = 0; bad_idx = 0; bad_val = 0;
        info_n = 0; info_d = 32'h0; info_t1 = 32'h0; info_t2 = 32'h0; info_t3 = 32'h0;
        done_seen = 0; w_sh = 0;
        for (mi = 0; mi < 48; mi = mi + 1) res_w[mi] = 32'h0;
    end

    // ---- 2A：UART 字节流 → 字 ----
    always @(posedge clk) begin
        if ((!use_2b) && sel_char_valid) begin
            rx[rx_n] = sel_char;
            rx_n     = rx_n + 1;
            if ((rx_n % 4) == 0) begin
                res_w[n_words] = {rx[rx_n-1], rx[rx_n-2], rx[rx_n-3], rx[rx_n-4]};
                n_words = n_words + 1;
                if (res_w[n_words-1] === DONE) done_seen = 1;
            end
        end
    end

    //==========================================================================
    // 5b. 诊断（默认关；+DIAG=1 打开进度打印；超时必打最后一次提交 PC 环）
    //==========================================================================
    integer diag_en;
    integer c15p_en;
    integer n_c15_ovl;              // C15 真实交叠：读 C80 在 E 且 写 B00 在同拍 M/W
    integer ddr2a_en;               // C15：2A 程序改由 DDR（L1I 缓存）驻留执行
    initial begin
        diag_en = 0;
        if ($value$plusargs("DIAG=%d", diag_en)) diag_en = (diag_en != 0);
        c15p_en = 0;
        if ($value$plusargs("C15P=%d", c15p_en)) c15p_en = (c15p_en != 0);
        ddr2a_en = 0;
        if ($value$plusargs("DDR2A=%d", ddr2a_en)) ddr2a_en = (ddr2a_en != 0);
        n_c15_ovl = 0;
    end
    reg [31:0] pc_ring [0:15];
    integer    pc_n;
    integer    dbg_cyc;
    integer    k;
    initial begin
        pc_n = 0; dbg_cyc = 0;
        for (k = 0; k < 16; k = k + 1) pc_ring[k] = 32'h0;
    end
    reg [31:0] aw_ring [0:7];
    integer    aw_n;
    initial begin
        aw_n = 0;
        for (k = 0; k < 8; k = k + 1) aw_ring[k] = 32'h0;
    end
    always @(posedge clk) begin
        if (use_2b && rst_b_n) begin
            if (u_mem_b.awvalid && u_mem_b.awready) begin
                aw_ring[aw_n % 8] <= u_mem_b.awaddr;
                aw_n <= aw_n + 1;
            end
            if (u_dut_b.commit_valid[0]) begin pc_ring[pc_n % 16] <= u_dut_b.commit_pc[31:0];  pc_n <= pc_n + 1; end
            if (u_dut_b.commit_valid[1]) begin pc_ring[pc_n % 16] <= u_dut_b.commit_pc[63:32]; pc_n <= pc_n + 1; end
            dbg_cyc <= dbg_cyc + 1;
            if (diag_en && ((dbg_cyc % 5000) == 0))
                $display("[diag] cyc=%0d words=%0d pc0=%08x ws=%b rob=%0d csr_we=%b wa=%03x wd=%08x trap=%b cause=%0d",
                         dbg_cyc, n_words, u_dut_b.debug0_wb_pc, u_dut_b.ws_valid,
                         u_dut_b.dbg_rob_cnt_w, u_dut_b.csr_we_w, u_dut_b.csr_waddr_w,
                         u_dut_b.csr_wdata_w, u_dut_b.trap_valid_w, u_dut_b.trap_cause_w);
        end
    end
    task automatic dump_pc_ring;
        integer j;
        begin
            $display("DIAG last committed PCs (oldest -> newest):");
            for (j = 0; j < 16; j = j + 1)
                $display("  ring[%0d] = 0x%08x", j, pc_ring[(pc_n + j) % 16]);
            $display("DIAG 2B: dbg_pc=%08x ws=%b rob_cnt=%0d csr_we=%b waddr=%03x wdata=%08x trap=%b cause=%0d priv=%0d",
                     u_dut_b.debug0_wb_pc, u_dut_b.ws_valid, u_dut_b.dbg_rob_cnt_w,
                     u_dut_b.csr_we_w, u_dut_b.csr_waddr_w, u_dut_b.csr_wdata_w,
                     u_dut_b.trap_valid_w, u_dut_b.trap_cause_w, u_dut_b.csr_priv_2);
            $display("DIAG 2B: rob_any=%b cmt_valid=%b cmt_pc=%08x %08x %08x %08x",
                     u_dut_b.rob_any_w, u_dut_b.commit_valid,
                     u_dut_b.commit_pc[31:0], u_dut_b.commit_pc[63:32],
                     u_dut_b.commit_pc[95:64], u_dut_b.commit_pc[127:96]);
            $display("DIAG mem: first_ar_seen=%b first_ar_addr=0x%08x ok=%b ar_count=%0d aw=%0d w=%0d",
                     u_mem_b.first_ar_seen, u_mem_b.first_ar_addr, u_mem_b.first_ar_ok,
                     u_mem_b.ar_count, u_mem_b.aw_count, u_mem_b.w_beat_count);
            $display("DIAG xip stub: [0]=%08x [1]=%08x  ddr[0..3]=%08x %08x %08x %08x",
                     u_mem_b.xip_mem[0], u_mem_b.xip_mem[1],
                     u_mem_b.ddr3_mem[0], u_mem_b.ddr3_mem[1],
                     u_mem_b.ddr3_mem[2], u_mem_b.ddr3_mem[3]);
            $display("DIAG mailbox @%0d:", MBW);
            for (j = 0; j < 20; j = j + 1)
                $display("  mb[%0d] = 0x%08x", j, u_mem_b.ddr3_mem[MBW+j]);
            $display("DIAG last 8 AW addrs (mapped):");
            for (j = 0; j < 8; j = j + 1)
                $display("  aw[%0d] = 0x%08x", j, aw_ring[j]);
        end
    endtask

    //==========================================================================
    // 6. 周期级 oracle（TB 侧独立规格模型）
    //==========================================================================
    //  采样（posedge，blocking ⇒ 读到的是本拍上升沿**前**的 DUT 值）
    reg        s_valid;
    reg [63:0] s_cyc, s_ins;
    reg        s_mc_we, s_mch_we, s_mi_we, s_mih_we, s_retire;
    reg [31:0] s_wdata;
    reg [3:0]  s_cv;
    reg [1:0]  s_lane;
    reg [2:0]  s_ncmt;
    reg [2:0]  s_older, s_younger;
    integer    n_cyc_err, n_ins_err;
    integer    n_b_l0csr_l1alu, n_b_l0alu_l1csr;
    integer    n_lane1_csr_any;
    integer    lane1_without_older;

    wire [2:0] b_cmt_num = {2'b0, u_dut_b.commit_valid[0]} + {2'b0, u_dut_b.commit_valid[1]} +
                           {2'b0, u_dut_b.commit_valid[2]} + {2'b0, u_dut_b.commit_valid[3]};
    wire [2:0] b_older =
        ({2'b00, u_dut_b.commit_valid[0]} & {2'b00, (u_dut_b.csr_cmt_lane_w > 2'd0)}) +
        ({2'b00, u_dut_b.commit_valid[1]} & {2'b00, (u_dut_b.csr_cmt_lane_w > 2'd1)}) +
        ({2'b00, u_dut_b.commit_valid[2]} & {2'b00, (u_dut_b.csr_cmt_lane_w > 2'd2)}) +
        ({2'b00, u_dut_b.commit_valid[3]} & {2'b00, (u_dut_b.csr_cmt_lane_w > 2'd3)});
    wire [2:0] b_younger =
        ({2'b00, u_dut_b.commit_valid[0]} & {2'b00, (u_dut_b.csr_cmt_lane_w < 2'd0)}) +
        ({2'b00, u_dut_b.commit_valid[1]} & {2'b00, (u_dut_b.csr_cmt_lane_w < 2'd1)}) +
        ({2'b00, u_dut_b.commit_valid[2]} & {2'b00, (u_dut_b.csr_cmt_lane_w < 2'd2)}) +
        ({2'b00, u_dut_b.commit_valid[3]} & {2'b00, (u_dut_b.csr_cmt_lane_w < 2'd3)});

    initial begin
        s_valid = 0; s_cyc = 0; s_ins = 0; s_wdata = 0;
        s_mc_we = 0; s_mch_we = 0; s_mi_we = 0; s_mih_we = 0; s_retire = 0;
        s_cv = 0; s_lane = 0; s_ncmt = 0; s_older = 0; s_younger = 0;
        n_cyc_err = 0; n_ins_err = 0;
        n_b_l0csr_l1alu = 0; n_b_l0alu_l1csr = 0; n_lane1_csr_any = 0; lane1_without_older = 0;
    end

    always @(posedge clk) begin
        if (use_2b) begin
            s_valid   = rst_b_n;
            s_cyc     = u_dut_b.cycle_cnt;
            s_ins     = u_dut_b.instret_cnt;
            s_mc_we   = u_dut_b.mcycle_we_w;
            s_mch_we  = u_dut_b.mcycleh_we_w;
            s_mi_we   = u_dut_b.minstret_we_w;
            s_mih_we  = u_dut_b.minstreth_we_w;
            s_wdata   = u_dut_b.cnt_wdata_w;
            s_cv      = u_dut_b.commit_valid;
            s_lane    = u_dut_b.csr_cmt_lane_w;
            s_ncmt    = b_cmt_num;
            s_older   = b_older;
            s_younger = b_younger;
            s_retire  = 1'b0;
            if (rst_b_n && (u_dut_b.minstret_we_w | u_dut_b.minstreth_we_w)) begin
                //   两种可达 2 提交组合的出现次数（同拍 CSR 写 + 更老/更年轻 ALU）
                if ((u_dut_b.csr_cmt_lane_w == 2'd0) && u_dut_b.commit_valid[1])
                    n_b_l0csr_l1alu = n_b_l0csr_l1alu + 1;
                if ((u_dut_b.csr_cmt_lane_w == 2'd1) && u_dut_b.commit_valid[0])
                    n_b_l0alu_l1csr = n_b_l0alu_l1csr + 1;
                if (u_dut_b.csr_cmt_lane_w == 2'd1) begin
                    n_lane1_csr_any = n_lane1_csr_any + 1;
                    //   结构不变式：lane1 的 CSR 写必须有更老的 lane0 提交（提交前缀链）
                    if (!u_dut_b.commit_valid[0]) lane1_without_older = 1;
                end
            end
        end else begin
            s_valid   = rst_a_n;
            s_cyc     = u_dut_a.cycle_cnt;
            s_ins     = u_dut_a.instret_cnt;
            s_mc_we   = u_dut_a.mcycle_we_w;
            s_mch_we  = u_dut_a.mcycleh_we_w;
            s_mi_we   = u_dut_a.minstret_we_w;
            s_mih_we  = u_dut_a.minstreth_we_w;
            s_wdata   = u_dut_a.cnt_wdata_w;
            s_cv      = 4'h0;
            s_lane    = 2'd0;
            s_ncmt    = {2'b0, (u_dut_a.mw_valid & ~u_dut_a.trap_exc)};
            s_older   = 3'd0;
            s_younger = 3'd0;
            s_retire  = u_dut_a.mw_valid & ~u_dut_a.trap_exc;
        end
    end

    //==========================================================================
    // 6b. Zicntr 更新算术：两份**独立**实现 + 表驱动对照
    //--------------------------------------------------------------------------
    //   · model_next：组合式（本 TB 逐拍 oracle 用；与 RTL 口径同源但独立书写）。
    //   · ref_next  ：**逐条程序序步骤**的参考模型（先 older 每条 +1 → 半字替换 →
    //                 再 younger 每条 +1；mcycle 先整 64 位 +1 再半字替换）。
    //   CPU 上 lane1=CSR 组合在本实现不可达（CSR 只在 ROB 头执行）⇒ 通用
    //   older→write→younger 算术必须由这份**表驱动对照**（覆盖 older/younger 0..2、
    //   低/高半写、进位边界、ncmt）独立验证，不能只靠可达的 lane0 组合。
    //==========================================================================
    function [63:0] model_next;
        input        is_2b;
        input        is_mcycle;
        input [63:0] body;
        input        we_lo, we_hi;
        input [31:0] wdata;
        input integer older, younger, ncmt;
        input        retire;
        reg [63:0] v;
        begin
            if (is_mcycle) begin
                v = body + 64'd1;                    // tick 与写无关
                if (we_lo)      v[31:0]  = wdata;
                else if (we_hi) v[63:32] = wdata;
            end else if (we_lo || we_hi) begin
                v = body + older;                    // 更老先退休
                if (we_lo) v[31:0] = wdata;          // 半字替换（本条 +1 被替代）
                else       v[63:32] = wdata;
                v = v + younger;                     // 更年轻后退休
            end else if (is_2b) begin
                v = body + ncmt;                     // 非写拍：本拍 qualified 提交数
            end else begin
                v = body + (retire ? 64'd1 : 64'd0); // 2A 单退休
            end
            model_next = v;
        end
    endfunction

    function [63:0] ref_next;
        input        is_2b;
        input        is_mcycle;
        input [63:0] body;
        input        we_lo, we_hi;
        input [31:0] wdata;
        input integer older, younger, ncmt;
        input        retire;
        reg [63:0] v;
        integer i;
        begin
            v = body;
            if (is_mcycle) begin
                v = v + 64'd1;                       // 步骤 1：整 64 位 tick
                if (we_lo)      for (i = 0; i < 1; i = i + 1) v[31:0]  = wdata;
                else if (we_hi) for (i = 0; i < 1; i = i + 1) v[63:32] = wdata;
            end else if (we_lo || we_hi) begin
                for (i = 0; i < older; i = i + 1) v = v + 64'd1;   // 步骤 1：older
                if (we_lo) v[31:0] = wdata; else v[63:32] = wdata; // 步骤 2：覆盖半字
                for (i = 0; i < younger; i = i + 1) v = v + 64'd1; // 步骤 3：younger
            end else if (is_2b) begin
                for (i = 0; i < ncmt; i = i + 1) v = v + 64'd1;
            end else if (retire) begin
                v = v + 64'd1;
            end
            ref_next = v;
        end
    endfunction

    //  比对（negedge：上升沿后的稳定值）
    reg [63:0] e_cyc, e_ins;
    reg [63:0] t_cyc_inc, t_ins_pre, t_ins_mid, t_ins;
    always @(negedge clk) begin
        if (s_valid) begin
            // ---- 两份独立模型：mcycle（tick 后覆盖半字）/ minstret（older→覆盖→younger）----
            e_cyc = model_next(use_2b, 1'b1, s_cyc, s_mc_we, s_mch_we, s_wdata,
                               s_older, s_younger, s_ncmt, s_retire);
            t_ins = model_next(use_2b, 1'b0, s_ins, s_mi_we, s_mih_we, s_wdata,
                               s_older, s_younger, s_ncmt, s_retire);

            if (use_2b) begin
                if (u_dut_b.cycle_cnt !== e_cyc) begin
                    n_cyc_err = n_cyc_err + 1;
                    if (n_cyc_err <= 8)
                        $display("FAIL: 2B mcycle 下一拍 0x%016h != 模型 0x%016h (pre=0x%016h we=%b%b data=0x%08h)",
                                 u_dut_b.cycle_cnt, e_cyc, s_cyc, s_mc_we, s_mch_we, s_wdata);
                end
                if (u_dut_b.instret_cnt !== t_ins) begin
                    n_ins_err = n_ins_err + 1;
                    if (n_ins_err <= 8)
                        $display("FAIL: 2B minstret 下一拍 0x%016h != 模型 0x%016h (pre=0x%016h we=%b%b lane=%0d cv=%b older=%0d younger=%0d data=0x%08h)",
                                 u_dut_b.instret_cnt, t_ins, s_ins, s_mi_we, s_mih_we,
                                 s_lane, s_cv, s_older, s_younger, s_wdata);
                end
            end else begin
                if (u_dut_a.cycle_cnt !== e_cyc) begin
                    n_cyc_err = n_cyc_err + 1;
                    if (n_cyc_err <= 8)
                        $display("FAIL: 2A mcycle 下一拍 0x%016h != 模型 0x%016h (pre=0x%016h we=%b%b data=0x%08h)",
                                 u_dut_a.cycle_cnt, e_cyc, s_cyc, s_mc_we, s_mch_we, s_wdata);
                end
                if (u_dut_a.instret_cnt !== t_ins) begin
                    n_ins_err = n_ins_err + 1;
                    if (n_ins_err <= 8)
                        $display("FAIL: 2A minstret 下一拍 0x%016h != 模型 0x%016h (pre=0x%016h we=%b%b retire=%b data=0x%08h)",
                                 u_dut_a.instret_cnt, t_ins, s_ins, s_mi_we, s_mih_we,
                                 s_retire, s_wdata);
                end
            end
        end
    end

    //==========================================================================
    // 7. 主判定
    //==========================================================================
    integer n_checks;
    integer i, cyc;
    //   算术表（独立对照用；覆盖进位/高半边界）
    reg [63:0] arith_body  [0:7];
    reg [31:0] arith_wdata [0:4];
    integer    arith_cases, arith_fails;
    integer    ai, bi, oi, yi, ni, wi, ti, ci;
    initial begin
        arith_body[0] = 64'h0000_0000_0000_0000;
        arith_body[1] = 64'h0000_0000_0000_0001;
        arith_body[2] = 64'h0000_0000_FFFF_FFFF;
        arith_body[3] = 64'h0000_0000_FFFF_FFFE;
        arith_body[4] = 64'h0000_0001_FFFF_FFFF;
        arith_body[5] = 64'hFFFF_FFFF_FFFF_FFFF;
        arith_body[6] = 64'h8000_0000_0000_0000;
        arith_body[7] = 64'h0000_0000_8000_0000;
        arith_wdata[0] = 32'h0000_0000;
        arith_wdata[1] = 32'h0000_0001;
        arith_wdata[2] = 32'hFFFF_FFFF;
        arith_wdata[3] = 32'h8000_0000;
        arith_wdata[4] = 32'h1234_5678;
        arith_cases = 0; arith_fails = 0;
    end
    integer exp_words;
    reg [31:0] tmpw;

    //   C15 交叠覆盖：**读 mcycleh/cycleh 在 E** 且 **写 mcycle 低半在同拍 M 或 W**
    //   （这才是"写 W 沿 + 读高同拍"的真实 hazard 窗口；仅 body 进位不算覆盖）。
    always @(posedge clk) if (!use_2b && rst_a_n &&
        u_dut_a.de_valid && (u_dut_a.de_csr_addr == 12'hC80) &&
        (((u_dut_a.em_valid && u_dut_a.em_csr_we && ~u_dut_a.em_exc_valid) &&
          (u_dut_a.em_csr_addr == 12'hB00)) ||
         ((u_dut_a.csr_wen_w) && (u_dut_a.mw_csr_addr == 12'hB00))))
        n_c15_ovl <= n_c15_ovl + 1;

    //   C15 探针（+C15P=1）：打印"读 cycleh（B）在 E"那一拍并存的 M/W CSR 槽，
    //   用来判定 写 mcycle 低半（0xB00）的 W 沿与 B 的 E 是否同拍。
    always @(posedge clk) if (!use_2b && (c15p_en != 0) && u_dut_a.de_valid &&
                              (u_dut_a.de_csr_addr == 12'hC80)) begin
        $display("[C15P] t=%0d B.de=C80 | em=%03h ev=%b ewe=%b | mw=%03h wwe=%b | body=%08h_%08h",
                 dbg_cyc, u_dut_a.em_csr_addr, u_dut_a.em_valid, u_dut_a.em_csr_we,
                 u_dut_a.mw_csr_addr, u_dut_a.csr_wen_w,
                 u_dut_a.cycle_cnt[63:32], u_dut_a.cycle_cnt[31:0]);
    end

    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_TOP_CONTROL_SEMANTICS 判据不满足");
            end
        end
    endtask

    initial begin
        n_checks = 0;
        @(posedge clk);
        //   等复位释放（选定 DUT）
        wait ((use_2b && rst_b_n) || (!use_2b && rst_a_n));
        for (cyc = 0; (cyc < MAX_CYCLES) && !done_seen; cyc = cyc + 1) begin
            @(posedge clk);
            if (use_2b) begin
                // 2B 邮箱：等 DONE 字出现（DONE 最后写、flush 后可见）
                if (u_mem_b.ddr3_mem[MBW] == MAGIC) begin
                    mi = u_mem_b.ddr3_mem[MBW + 1];
                    if ((mi == 13) &&
                        (u_mem_b.ddr3_mem[MBW + 2 + mi] == DONE)) begin
                        n_words = mi + 3;
                        for (i = 0; i < 48; i = i + 1) res_w[i] = 32'h0;
                        for (i = 0; i < n_words; i = i + 1)
                            res_w[i] = u_mem_b.ddr3_mem[MBW + i];
                        done_seen = 1;
                        $display("[tb_top_control_semantics] 2B 邮箱完成：words=%0d", n_words);
                    end
                end
            end
        end
        if (!done_seen) dump_pc_ring;
        chk(done_seen != 0, "超时：未收到结果流的 DONE 标记");
        repeat (DRAIN_CYCLES) @(posedge clk);

        // ---- 结果流完整性（2A 字节流 / 2B 邮箱字，统一在 res_w 上判定）----
        if (n_words < 2) begin
            $display("FAIL: 结果字数 %0d 不足（至少 MAGIC+NCHK）", n_words);
            bad_magic = 1;
        end else begin
            nchk = res_w[1];
            if (res_w[0] !== MAGIC) begin
                bad_magic = 1;
                $display("FAIL: 结果流首字 0x%08h != MAGIC 0x%08h", res_w[0], MAGIC);
            end
            if ((use_2b && (nchk != 13)) || (!use_2b && (nchk != 32))) begin
                bad_nchk = 1;
                $display("FAIL: %0s NCHK=%0d（2B 固定 13；2A 固定 32）",
                         (use_2b ? "2B" : "2A"), nchk);
            end
            for (i = 2; (i <= (nchk + 1)) && (i < n_words); i = i + 1) begin
                if (res_w[i] !== 32'd1) begin
                    bad_idx = i - 1;
                    bad_val = res_w[i];
                    $display("FAIL: 检查项 C%0d = 0x%08h（期望 1）", i - 1, res_w[i]);
                end
            end
            //   2A 的跨半 carry 扫描在结果后带 5 字 info：[MAGIC2, d, B读high, A后low, 写后body high]
            info_n = (nchk == 32) ? 5 : 0;
            if ((info_n != 0) && (n_words >= (nchk + 3 + info_n))) begin
                if (res_w[nchk + 2] !== MAGIC2) begin
                    bad_done = 1;
                    $display("FAIL: C15 info 魔数 0x%08h != 0x%08h", res_w[nchk + 2], MAGIC2);
                end else begin
                    info_d  = res_w[nchk + 3];
                    info_t1 = res_w[nchk + 4];
                    info_t2 = res_w[nchk + 5];
                    info_t3 = res_w[nchk + 6];
                    $display("[C15] 跨半 carry 扫描：命中 d=%0d | 写后 body high=%0d low=%0d | 后条读 high=%0d",
                             info_d, info_t3, info_t2, info_t1);
                end
            end
            if ((n_words > (nchk + 2 + info_n)) && (res_w[nchk + 2 + info_n] !== DONE)) begin
                bad_done = 1;
                $display("FAIL: 结束标记 0x%08h != DONE 0x%08h", res_w[nchk + 2 + info_n], DONE);
            end
        end
        chk(bad_magic == 0, "结果流 MAGIC 正确");
        chk(bad_nchk == 0,  "结果流 NCHK 合法");
        chk(nchk != 0,      "NCHK 被程序写出");
        chk(n_words == (nchk + 3 + info_n), "结果字个数 == NCHK + 3 + info（无多余/缺失字）");
        if (!use_2b) chk(rx_n == 4 * (nchk + 3 + info_n), "结果字节数 == 4 × 字数（无半字/重发）");
        if (nchk == 32) begin
            chk(info_d < 16,                    "C15 命中 d 在扫描范围 0..15");
            chk(info_t3 == 32'd3,               "C15 写后 body high==3（确已发生 carry）");
            chk(info_t1 == 32'd3,               "C15 后条跨半读 high==3（未漏 carry）");
            $display("[C15] E/M/W 真实交叠覆盖 = %0d 拍（读 high 在 E 且写 low 在同拍 M/W）", n_c15_ovl);
            //   ★ 母口径（2026-10-20）：**没触发就不算覆盖** —— 交叠窗口为 0 必须红，
            //     不得以"body 已进位、后条读=3"冒充 hazard 已覆盖。
            if (ddr2a_en == 0) begin
                $display("[C15] XIP 模式：扫描仅作功能采样（写后 body/后条读），**覆盖率判据只在 +DDR2A=1 的 DDR/L1I 驻留运行**（该模式保证相邻指令可 1 拍/条）。");
            end else begin
                chk(n_c15_ovl > 0, "C15 写低→读高 E/M/W 真实交叠覆盖 >0（DDR/L1I 模式；未触发即不覆盖）");
            end
        end
        chk(bad_idx == 0,   "所有程序自检结果 == 1");
        chk(bad_done == 0,  "结束标记 == DONE");

        // ---- 周期级 oracle ----
        chk(n_cyc_err == 0, "mcycle 周期级语义（+1 后覆盖半字）零不符");
        chk(n_ins_err == 0, "minstret 周期级语义（older→覆盖→younger）零不符");

        // ---- 通用 older→write→younger 算术：表驱动独立对照（与可达性无关）----
        //   覆盖 body 边界（0/1/低半满/高半满/全 1/...）× 写值 × 低/高/无写 ×
        //   older/younger 0..2 × ncmt 0..2 × 2A/2B × mcycle/minstret。
        //   ★ 这是 CPU 上不可达组合（lane1=CSR）的**算术**证据，不冒充动态覆盖。
        arith_cases = 0; arith_fails = 0;
        for (ai = 0; ai < 8; ai = ai + 1) begin
            for (bi = 0; bi < 5; bi = bi + 1) begin
                for (oi = 0; oi < 3; oi = oi + 1) begin
                    for (yi = 0; yi < 3; yi = yi + 1) begin
                        for (ni = 0; ni < 3; ni = ni + 1) begin
                            for (wi = 0; wi < 3; wi = wi + 1) begin
                                for (ti = 0; ti < 2; ti = ti + 1) begin
                                    for (ci = 0; ci < 2; ci = ci + 1) begin
                                        arith_cases = arith_cases + 1;
                                        if (model_next(ti, ci, arith_body[ai],
                                                       (wi == 1), (wi == 2), arith_wdata[bi],
                                                       oi, yi, ni, 1'b1) !==
                                            ref_next  (ti, ci, arith_body[ai],
                                                       (wi == 1), (wi == 2), arith_wdata[bi],
                                                       oi, yi, ni, 1'b1)) begin
                                            arith_fails = arith_fails + 1;
                                            if (arith_fails <= 4)
                                                $display("FAIL: 算术表对照不符 body=0x%016h wdata=0x%08h we=%0d older=%0d younger=%0d ncmt=%0d 2b=%0d mcyc=%0d",
                                                         arith_body[ai], arith_wdata[bi], wi,
                                                         oi, yi, ni, ti, ci);
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        $display("TOP_CONTROL_SEMANTICS_ARITH cases=%0d fails=%0d", arith_cases, arith_fails);
        chk(arith_fails == 0, "Zicntr older→write→younger 算术表对照（独立逐条模型，含不可达组合）");

        $display("TOP_CONTROL_SEMANTICS mode=%0s checks=%0d words=%0d nchk=%0d cyc_err=%0d ins_err=%0d combo_a=%0d combo_b=%0d lane1_csr_any=%0d",
                 (use_2b ? "2b" : "2a"), n_checks, n_words, nchk, n_cyc_err, n_ins_err,
                 n_b_l0csr_l1alu, n_b_l0alu_l1csr, n_lane1_csr_any);

        // ---- 2B 提交组合契约（母 2026-10-20 裁定）----
        //   · lane0=CSR(minstret)+lane1=ALU（older=0/younger=1）可达 ⇒ 硬断言。
        //   · lane0=ALU+lane1=CSR（older=1/younger=0）：要求 CSR 非 ROB 头提交；本实现
        //     "CSR 只在 ROB 头执行" ⇒ csr_cmt_lane 恒 0，该组合**不可达**。契约：
        //     本实现头 CSR 条件下不可达；**若将来 lane1 出现，必须转入完整检查**
        //     （逐拍 oracle 已对每次写覆盖 older/younger）。不伪造、不删检查：
        //     出现即计数并要求结构不变式；未出现打印说明行（OPEN），不冒充已覆盖。
        if (use_2b) begin
            chk(n_b_l0csr_l1alu > 0, "2B 出现 lane0=CSR(minstret)+lane1=ALU 提交组合");
            chk(lane1_without_older == 0, "lane1 CSR 写必有更老 lane0 提交（提交前缀链）");
            if (n_b_l0alu_l1csr > 0) begin
                $display("TOP_CONTROL_SEMANTICS combo_b observed=%0d (完整检查已由逐拍 oracle 覆盖)",
                         n_b_l0alu_l1csr);
            end else begin
                $display("TOP_CONTROL_SEMANTICS_OPEN: combo_b(lane0=ALU+lane1=CSR) 在当前实现（CSR 只在 ROB 头执行）下不可达；lane1_csr_any=%0d。契约：将来 lane1 出现即转完整检查；通用 older→write→younger 算术已由 ARITH 表对照独立验证。",
                         n_lane1_csr_any);
            end
        end
        $display("TB_TOP_CONTROL_SEMANTICS: PASS");
        $finish;
    end

endmodule
