//==============================================================================
// sim/functional/tb_lsq_semantics.sv —— F2 LSQ 本体语义定向功能包（fail-closed）
//------------------------------------------------------------------------------
// 项目 : rv32gc-cpu（阶段二 2B 乱序后端）
// 目标 : 只驱动 `rtl/back2/lsq_simple.v` 的**真实接口**（不经前端/RAT/ROB），按合法
//        生命周期构造用例，覆盖审计 `sim/audit/global-2026-10-18/03-lsq-2b.md` 的
//        F1..F5 五个根因，并配"合法正控"（旧/新两棵树都必须通过的控制向量）。
//
// 方法学（与 prompts/common.md §3 fail-closed 一致）：
//   · 逐向量打印 `VEC <id> <name> checks=<n> fails=<n> defect=<d>`：
//       - `fails` = **对修复后期望的行为判据**的违反数（新树必须 0）；
//       - `defect`=**该根因的结构性旧行为签名**是否出现（新树必须 0；旧树反证时必须 1）。
//     这样同一份 TB 既能给新树绿灯，也能在 201acf61 旧树上给出"红 + 根因签名"。
//   · 只读层次观测（`u_lsq.*`）允许，**绝不 force/改写 DUT 状态**；所有状态推进都经
//     真实输入握手（alloc/exe/dr/cmt/flush/squash/mem_rsp/st_xlate）。
//   · 固定非零向量：存储映像按 `mem[i] = {0x44^i, 0x33^i, 0x22^i, 0x11^i}` 初始化；
//     每笔读的期望值由**独立字节模型**算出，不用 DUT 内部信号当期望。
//   · 四态安全：所有响应/翻译输入由寄存器驱动；DUT 侧新口在本 TB 全部实接。
//
// 根因 → 向量：
//   F1 ROB64 环绕年龄（63→0 释放/提交窗）：v1/v2/v3/v4/v14
//   F2 32 槽 STQ 选择编码器：               v5（槽 0..31 全覆盖 + 高槽落地内容）
//   F3 flush 拍 CDQ 不出队（重复写/死锁）： v7
//   F4 拆笔低字 fire 即退休：               v8/v9
//   F5 跨 4 KB 第二笔必须独立翻译：         v10/v11
//   正控（两树都必须过）：                  v6/v12/v13
//
// 运行（由 sim/functional/test_lsq.sh 调用）：
//   iverilog -g2012 -I <DUT_ROOT> -s tb_lsq_semantics_top -o x.vvp \
//       sim/functional/tb_lsq_semantics.sv <DUT_ROOT>/rtl/back2/lsq_simple.v
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module tb_lsq_semantics_top;
    localparam integer STQ_N  = `BACK2_STQ_N;
    localparam integer STQ_IW = `BACK2_STQ_IDX_W;
    localparam integer OUT_N  = `BACK2_MEM_OUT_N;
    localparam integer LQ_IW  = `BACK2_LQ_IDX_W;
    localparam integer TAG_W  = `BACK2_MEM_TAG_W;
    localparam integer ROBW   = `BACK2_ROB_IDX_W;
    localparam integer PDW_I  = `BACK2_PREG_I_W;
    localparam integer PDW_F  = `BACK2_PREG_F_W;
    localparam integer W      = `BACK2_DISP_W;

    //--------------------------------------------------------------------------
    // 0. 时钟 / 复位 / DUT 端口
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg              flush_all = 0, squash = 0;
    reg [ROBW-1:0]   squash_idx = 0, rob_head = 0;
    reg [W-1:0]      alloc_valid = 0;
    reg [W*ROBW-1:0] alloc_rob = 0;
    wire             alloc_ok;
    wire [W*STQ_IW-1:0] alloc_idx;
    reg [W-1:0]         lalloc_valid = 0;
    reg [W*ROBW-1:0]    lalloc_rob = 0;
    wire                lalloc_ok;
    wire [W*LQ_IW-1:0]  lalloc_idx;
    reg                 exe_valid = 0, exe_is_store = 0, exe_is_fp = 0;
    reg [ROBW-1:0]      exe_rob = 0;
    reg [`BACK2_EPOCH_W-1:0] exe_epoch = 0;
    reg [31:0]          exe_addr = 0, exe_wdata = 0, exe_wdata_hi = 0;
    reg [2:0]           exe_size = 0;
    reg                 exe_unsign = 0, exe_dst_i = 0, exe_dst_f = 0;
    reg [PDW_I-1:0]     exe_pdest_i = 0;
    reg [PDW_F-1:0]     exe_pdest_f = 0;
    reg [STQ_IW-1:0]    exe_stq_idx = 0;
    reg [LQ_IW-1:0]     exe_lq_idx = 0;
    reg [ROBW-1:0]      iss_rob = 0;
    wire                iss_ok, dr_empty_o;
    reg [W-1:0]         dr_valid = 0;
    reg [W*STQ_IW-1:0]  dr_idx = 0;
    wire                dr_room_ok;
    reg [2:0]           cmt_n = 0;

    wire             mem_req_valid, mem_req_wen;
    wire [31:0]      mem_req_addr, mem_req_wdata;
    wire [3:0]       mem_req_wstrb;
    wire [TAG_W-1:0] mem_req_tag;
    reg              mem_req_ready = 0;
    wire             mem_rsp_valid;
    wire [31:0]      mem_rsp_rdata;
    wire [TAG_W-1:0] mem_rsp_tag;
    wire             mem_rsp_err;

    wire             exc_valid_o;
    wire [ROBW-1:0]  exc_rob_o;
    wire [3:0]       exc_cause_o;
    wire [31:0]      exc_tval_o;

    wire             wb_valid;
    wire [ROBW-1:0]  wb_rob;
    wire [`BACK2_EPOCH_W-1:0] wb_epoch;
    wire             wb_dst_i, wb_dst_f;
    wire [PDW_I-1:0] wb_pdest_i;
    wire [PDW_F-1:0] wb_pdest_f;
    wire [31:0]      wb_data, wb_data_hi;
    wire             wb_f64;

    wire             st_done_valid;
    wire [ROBW-1:0]  st_done_rob;
    wire [`BACK2_EPOCH_W-1:0] st_done_epoch;

    reg              st_xlate_en = 0;
    reg [3:0]        st_xlate_ctx = 0;
    wire             st_xlate_valid;
    wire [31:0]      st_xlate_va;
    wire [STQ_IW-1:0] st_xlate_idx;
    wire [3:0]       st_xlate_ctx_o;
    wire             st_xlate_ready;
    wire             st_xlate_done;
    wire [31:0]      st_xlate_pa;
    wire             st_xlate_fault;

    wire [7:0]       stq_cnt_o;
    wire [31:0]      cnt_load_o, cnt_store_o, cnt_fwd_o, cnt_stq_stall_o;

    lsq_simple #(.DBG(0)) u_lsq (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .squash(squash),
        .squash_idx(squash_idx), .rob_head(rob_head),
        .alloc_valid(alloc_valid), .alloc_rob(alloc_rob), .alloc_ok(alloc_ok),
        .alloc_idx(alloc_idx),
        .lalloc_valid(lalloc_valid), .lalloc_rob(lalloc_rob), .lalloc_ok(lalloc_ok),
        .lalloc_idx(lalloc_idx),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch), .exe_addr(exe_addr),
        .exe_wdata(exe_wdata), .exe_wdata_hi(exe_wdata_hi), .exe_size(exe_size),
        .exe_unsign(exe_unsign), .exe_dst_i(exe_dst_i), .exe_dst_f(exe_dst_f),
        .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f),
        .exe_stq_idx(exe_stq_idx), .exe_lq_idx(exe_lq_idx),
        .iss_rob(iss_rob), .iss_ok(iss_ok), .dr_empty_o(dr_empty_o),
        .dr_valid(dr_valid), .dr_idx(dr_idx), .dr_room_ok(dr_room_ok),
        .cmt_n(cmt_n),
        .mem_req_valid(mem_req_valid), .mem_req_wen(mem_req_wen),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_wstrb(mem_req_wstrb), .mem_req_tag(mem_req_tag),
        .mem_req_ready(mem_req_ready), .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_rdata(mem_rsp_rdata), .mem_rsp_tag(mem_rsp_tag),
        .mem_rsp_err(mem_rsp_err),
        .exc_valid_o(exc_valid_o), .exc_rob_o(exc_rob_o),
        .exc_cause_o(exc_cause_o), .exc_tval_o(exc_tval_o),
        .wb_valid(wb_valid), .wb_rob(wb_rob), .wb_epoch(wb_epoch),
        .wb_dst_i(wb_dst_i), .wb_dst_f(wb_dst_f), .wb_pdest_i(wb_pdest_i),
        .wb_pdest_f(wb_pdest_f), .wb_data(wb_data), .wb_data_hi(wb_data_hi),
        .wb_f64(wb_f64),
        .st_done_valid(st_done_valid), .st_done_rob(st_done_rob),
        .st_done_epoch(st_done_epoch),
        .st_xlate_en(st_xlate_en), .st_xlate_ctx(st_xlate_ctx),
        .st_xlate_valid(st_xlate_valid), .st_xlate_va(st_xlate_va),
        .st_xlate_idx(st_xlate_idx), .st_xlate_ctx_o(st_xlate_ctx_o),
        .st_xlate_ready(st_xlate_ready), .st_xlate_done(st_xlate_done),
        .st_xlate_pa(st_xlate_pa), .st_xlate_fault(st_xlate_fault),
        .stq_cnt_o(stq_cnt_o), .cnt_load_o(cnt_load_o), .cnt_store_o(cnt_store_o),
        .cnt_fwd_o(cnt_fwd_o), .cnt_stq_stall_o(cnt_stq_stall_o)
    );

    //==========================================================================
    // 1. 场景存储映像（独立参考模型）+ 访存响应发生器
    //--------------------------------------------------------------------------
    //   · `mem[a[13:2]]` = 一个 32 bit 对齐字（与 L1D 的"响应只回对齐字"口径一致）；
    //     逐字节初值不同（0x11/0x22/0x33/0x44 ^ 字序），可验证字节道。
    //   · 写：按 `mem_req_wstrb` 逐字节写回；读：按请求地址回**对齐字**。
    //   · 响应 1 拍后到达（tag 用请求拍锁存的 `mem_req_tag`），四态安全（全 reg 驱动）。
    //   · 另支持 `rsp_force`（反证"重复响应不得二次写回"）与 `mem_rsp_err` 注入。
    //==========================================================================
    reg [31:0] mem [0:4095];
    integer    mi;
    initial begin
        for (mi = 0; mi < 4096; mi = mi + 1)
            mem[mi] = {8'h44 ^ mi[7:0], 8'h33 ^ mi[7:0], 8'h22 ^ mi[7:0], 8'h11 ^ mi[7:0]};
    end

    function [31:0] mword(input [31:0] a);
        begin
            mword = mem[a[13:2]];
        end
    endfunction

    //   独立字节模型：按 ISA 的 little-endian + 符号扩展算出该访问的期望值。
    function [31:0] exp_load(input [31:0] a, input [2:0] sz, input uns);
        integer bi;
        reg [31:0] acc;
        reg [7:0]  bb;
        begin
            acc = 32'h0;
            for (bi = 0; bi < 4; bi = bi + 1) begin
                if (bi < (1 << sz)) begin
                    bb = mem[(a + bi) >> 2] >> (8 * ((a + bi) & 32'd3));
                    acc[8*bi +: 8] = bb;
                end
            end
            case (sz)
                3'd0: exp_load = uns ? {24'h0, acc[7:0]} : {{24{acc[7]}}, acc[7:0]};
                3'd1: exp_load = uns ? {16'h0, acc[15:0]} : {{16{acc[15]}}, acc[15:0]};
                default: exp_load = acc;
            endcase
        end
    endfunction

    reg        rsp_v_q;
    reg [TAG_W-1:0] rsp_tag_q;
    reg [31:0] rsp_data_q;
    reg        rsp_err_q;
    reg        rsp_force;
    reg [TAG_W-1:0] rsp_force_tag;
    reg [31:0] rsp_force_data;
    reg        rsp_force_err;

    assign mem_rsp_valid = rsp_v_q | rsp_force;
    assign mem_rsp_tag   = rsp_force ? rsp_force_tag  : rsp_tag_q;
    assign mem_rsp_rdata = rsp_force ? rsp_force_data : rsp_data_q;
    assign mem_rsp_err   = rsp_force ? rsp_force_err  : rsp_err_q;

    wire ld_req_fire_w = mem_req_valid & ~mem_req_wen & mem_req_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_v_q <= 1'b0; rsp_tag_q <= 0; rsp_data_q <= 0; rsp_err_q <= 0;
        end else begin
            if (rsp_v_q) rsp_v_q <= 1'b0;
            else if (ld_req_fire_w) begin
                rsp_v_q    <= 1'b1;
                rsp_tag_q  <= mem_req_tag;
                rsp_data_q <= mword(mem_req_addr);
                rsp_err_q  <= 1'b0;
            end
            if (mem_req_valid & mem_req_wen & mem_req_ready) begin
                if (mem_req_wstrb[0]) mem[mem_req_addr[13:2]][7:0]   <= mem_req_wdata[7:0];
                if (mem_req_wstrb[1]) mem[mem_req_addr[13:2]][15:8]  <= mem_req_wdata[15:8];
                if (mem_req_wstrb[2]) mem[mem_req_addr[13:2]][23:16] <= mem_req_wdata[23:16];
                if (mem_req_wstrb[3]) mem[mem_req_addr[13:2]][31:24] <= mem_req_wdata[31:24];
            end
        end
    end

    // ---- 观测：写笔数/地址/数据/掩码；读请求数；写回数 ----
    integer    n_wr, n_ldreq, n_wb;
    reg [31:0] wr_a [0:63];
    reg [31:0] wr_d [0:63];
    reg [3:0]  wr_s [0:63];
    reg [31:0] last_ld_addr;
    reg [31:0] last_wb_data;
    reg [31:0] last_wb_rob;
    always @(posedge clk) begin
        if (rst_n & mem_req_valid & mem_req_wen & mem_req_ready & (n_wr < 64)) begin
            wr_a[n_wr] <= mem_req_addr; wr_d[n_wr] <= mem_req_wdata;
            wr_s[n_wr] <= mem_req_wstrb; n_wr <= n_wr + 1;
        end
        if (rst_n & mem_req_valid & ~mem_req_wen & mem_req_ready) begin
            n_ldreq     <= n_ldreq + 1;
            last_ld_addr<= mem_req_addr;
        end
        if (rst_n & wb_valid) begin
            n_wb        <= n_wb + 1;
            last_wb_data<= wb_data;
            last_wb_rob <= {26'h0, wb_rob};
        end
    end

    //==========================================================================
    // 2. store 翻译适配器行为模型（真实 `st_xlate_*` 接口，单笔在途）
    //--------------------------------------------------------------------------
    //   页映射（固定、非零）：
    //     VA 页 0x00000 → PA 0x3000_0000 | off
    //     VA 页 0x00001 → PA 0x4000_0000 | off
    //   其它页 → PA 0x5000_0000 | off。
    //   `pg1_fault=1` 时**页 1 的任何翻译**返回故障（用于 F5 第二页故障传播）。
    //--------------------------------------------------------------------------
    localparam TB_IDLE = 2'd0, TB_BUSY = 2'd1, TB_WAIT = 2'd2;
    reg [1:0]  tb_st;
    reg [31:0] tb_va;
    reg [3:0]  tb_ctx;
    reg        tb_done;
    reg [31:0] tb_pa;
    reg        tb_flt;
    reg        stx_adapt_en;
    reg        pg1_fault;
    integer    stx_adapt_delay;      // 翻译完成前的人为延迟（0 = 默认 1 拍；仅反证时序用）
    reg [3:0]  tb_dly;

    function [31:0] xlate_pa(input [31:0] va);
        begin
            if      (va[31:12] == 20'h00000) xlate_pa = 32'h30000000 | {20'h0, va[11:0]};
            else if (va[31:12] == 20'h00001) xlate_pa = 32'h40000000 | {20'h0, va[11:0]};
            else                             xlate_pa = 32'h50000000 | {20'h0, va[11:0]};
        end
    endfunction

    function xlate_flt(input [31:0] va);
        begin
            xlate_flt = pg1_fault & (va[31:12] == 20'h00001);
        end
    endfunction

    wire tb_go = (tb_st == TB_IDLE) & stx_adapt_en & st_xlate_valid;
    assign st_xlate_ready = tb_go;
    assign st_xlate_done  = tb_done;
    assign st_xlate_pa    = tb_pa;
    assign st_xlate_fault = tb_flt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_st <= TB_IDLE; tb_done <= 1'b0; tb_pa <= 0; tb_flt <= 0;
            tb_va <= 0; tb_ctx <= 0;
        end else begin
            case (tb_st)
                TB_IDLE: begin
                    tb_done <= 1'b0;
                    if (tb_go) begin
                        tb_va <= st_xlate_va; tb_ctx <= st_xlate_ctx_o;
                        tb_dly <= stx_adapt_delay[3:0];
                        tb_st <= TB_BUSY;
                    end
                end
                TB_BUSY: begin
                    if (tb_dly != 4'd0) begin
                        tb_dly <= tb_dly - 4'd1;
                    end else begin
                        tb_pa   <= xlate_pa(tb_va);
                        tb_flt  <= xlate_flt(tb_va);
                        tb_done <= 1'b1;
                        tb_st   <= TB_WAIT;
                    end
                end
                default: begin                    // TB_WAIT：done 保持 1 拍后撤销
                    tb_done <= 1'b0;
                    tb_st   <= TB_IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // 3. 判定基础设施（fail-closed；stdout 只放 VEC/摘要行）
    //==========================================================================
    integer g_total, g_nonzero, g_checks, g_fails, g_defect;
    integer v_checks, v_fails, v_defect;
    reg [8*32-1:0] v_name;

    task vec_begin(input [8*32-1:0] nm);
        begin
            v_name = nm; v_checks = 0; v_fails = 0; v_defect = 0;
            g_total = g_total + 1;
        end
    endtask

    task vec_end;
        begin
            if (v_checks > 0) g_nonzero = g_nonzero + 1;
            $display("VEC %0d %0s checks=%0d fails=%0d defect=%0d",
                     g_total, v_name, v_checks, v_fails, v_defect);
            g_checks = g_checks + v_checks;
            g_fails  = g_fails  + v_fails;
            g_defect = g_defect + v_defect;
        end
    endtask

    //   ★★ 初审 #2：**四态安全判定** —— `ok` 必须严格为 1'b1；0/X/Z 一律判失败
    //     （旧写法 `if (!ok)` 对 X 求值为 X 而被当作 false ⇒ 未知被静默当通过）。
    task chk(input ok, input [8*64-1:0] what);
        begin
            v_checks = v_checks + 1;
            if (ok !== 1'b1) begin
                v_fails = v_fails + 1;
                $display("CHK_BAD vec=%0d name=%0s what=%0s", g_total, v_name, what);
            end
        end
    endtask

    //   四态谓词：任何 X/Z 位 ⇒ 0（供检查器自证与有效窗口 payload 判定复用）。
    function is_known(input [31:0] v);
        begin
            is_known = (^v !== 1'bx);
        end
    endfunction

    //   结构缺陷签名（旧行为出现时置该向量 defect=1；支持多向量共同指向同一根因）。
    task mark_defect;
        begin
            v_defect = 1;
            $display("DEFECT_SIG vec=%0d name=%0s", g_total, v_name);
        end
    endtask

    //   ★★ 初审 #2：结构判据的四态安全写法 —— 只有**严格成立**才算“无缺陷签名”。
    function two_val(input c);
        begin
            two_val = (c === 1'b1);
        end
    endfunction

    //   全局 X/Z 监视（初审 #2）：**控制输出**不得为 X/Z；**有效窗口内**的 payload 不得含
    //   X/Z（无效窗口的 payload 不作要求，不强制清零）。命中即 `g_xz` 非零：摘要 `xz=` 字段
    //   非零 ⇒ 包装器拒（见 test_lsq.sh 的 xz 判据）。
    integer g_xz;
    reg     xz_hit;
    always @(*) begin
        xz_hit = 1'b0;
        if (rst_n === 1'b1) begin
            if ((mem_req_valid !== 1'b0) && (mem_req_valid !== 1'b1)) xz_hit = 1'b1;
            if ((mem_req_wen   !== 1'b0) && (mem_req_wen   !== 1'b1)) xz_hit = 1'b1;
            if ((mem_rsp_valid !== 1'b0) && (mem_rsp_valid !== 1'b1)) xz_hit = 1'b1;
            if ((wb_valid      !== 1'b0) && (wb_valid      !== 1'b1)) xz_hit = 1'b1;
            if ((st_xlate_valid!== 1'b0) && (st_xlate_valid!== 1'b1)) xz_hit = 1'b1;
            if ((exc_valid_o   !== 1'b0) && (exc_valid_o   !== 1'b1)) xz_hit = 1'b1;
            if ((dr_empty_o    !== 1'b0) && (dr_empty_o    !== 1'b1)) xz_hit = 1'b1;
            if ((mem_req_valid === 1'b1) &&
                (!is_known(mem_req_addr) || !is_known(mem_req_wdata) ||
                 !is_known({28'h0, mem_req_wstrb}) || !is_known({28'h0, mem_req_tag})))
                xz_hit = 1'b1;
            if ((mem_rsp_valid === 1'b1) &&
                (!is_known(mem_rsp_rdata) || !is_known({28'h0, mem_rsp_tag}) ||
                 !is_known({31'h0, mem_rsp_err})))
                xz_hit = 1'b1;
            if ((wb_valid === 1'b1) &&
                (!is_known(wb_data) || !is_known(wb_data_hi) ||
                 !is_known({26'h0, wb_rob}) || !is_known({30'h0, wb_epoch}) ||
                 !is_known({30'h0, wb_pdest_i}) || !is_known({30'h0, wb_pdest_f}) ||
                 !is_known({31'h0, wb_dst_i}) || !is_known({31'h0, wb_dst_f}) ||
                 !is_known({31'h0, wb_f64})))
                xz_hit = 1'b1;
            if ((exc_valid_o === 1'b1) &&
                (!is_known({26'h0, exc_rob_o}) || !is_known({28'h0, exc_cause_o}) ||
                 !is_known(exc_tval_o)))
                xz_hit = 1'b1;
            if ((st_xlate_valid === 1'b1) &&
                (!is_known(st_xlate_va) || !is_known({27'h0, st_xlate_idx}) ||
                 !is_known({28'h0, st_xlate_ctx_o})))
                xz_hit = 1'b1;
        end
    end
    always @(posedge clk) if (xz_hit === 1'b1) g_xz <= g_xz + 1;

    //==========================================================================
    // 4. 真实接口驱动任务（合法生命周期；所有状态推进都经握手）
    //==========================================================================
    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0; flush_all = 0; squash = 0;
            alloc_valid = 0; lalloc_valid = 0; dr_valid = 0;
            exe_valid = 0; exe_is_store = 0; exe_is_fp = 0;
            mem_req_ready = 0; st_xlate_en = 0; st_xlate_ctx = 0;
            stx_adapt_en = 1; pg1_fault = 0; stx_adapt_delay = 0; rsp_force = 0;
            rsp_force_err = 0; rob_head = 0; squash_idx = 0; cmt_n = 0;
            exe_wdata_hi = 0; iss_rob = 0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            n_wr = 0; n_ldreq = 0; n_wb = 0;
            last_ld_addr = 0; last_wb_data = 0; last_wb_rob = 0;
        end
    endtask

    task alloc_store(input [ROBW-1:0] rb, output [STQ_IW-1:0] idx);
        begin
            @(negedge clk);
            alloc_valid = 4'b0001; alloc_rob = rb;
            #1;
            idx = alloc_idx[STQ_IW-1:0];
            @(posedge clk); #1;
            alloc_valid = 4'b0000;
        end
    endtask

    task alloc_load(input [ROBW-1:0] rb, output [LQ_IW-1:0] idx);
        begin
            @(negedge clk);
            lalloc_valid = 4'b0001; lalloc_rob = rb;
            #1;
            idx = lalloc_idx[LQ_IW-1:0];
            @(posedge clk); #1;
            lalloc_valid = 4'b0000;
        end
    endtask

    task exe_store(input [STQ_IW-1:0] slot, input [ROBW-1:0] rb, input [31:0] a,
                   input [31:0] d, input [2:0] sz, input [31:0] dhi);
        begin
            @(negedge clk);
            exe_valid = 1; exe_is_store = 1; exe_stq_idx = slot; exe_rob = rb;
            exe_addr = a; exe_wdata = d; exe_wdata_hi = dhi; exe_size = sz;
            @(posedge clk); #1;
            exe_valid = 0; exe_is_store = 0;
        end
    endtask

    task exe_load(input [LQ_IW-1:0] slot, input [ROBW-1:0] rb, input [31:0] a,
                  input [2:0] sz, input uns, input [PDW_I-1:0] pdi,
                  input [PDW_F-1:0] pdf, input df);
        begin
            @(negedge clk);
            exe_valid = 1; exe_is_store = 0; exe_lq_idx = slot; exe_rob = rb;
            exe_addr = a; exe_size = sz; exe_unsign = uns;
            exe_dst_i = ~df; exe_dst_f = df; exe_pdest_i = pdi; exe_pdest_f = pdf;
            @(posedge clk); #1;
            exe_valid = 0; exe_dst_i = 0; exe_dst_f = 0;
        end
    endtask

    //   提交一拍：按真实契约"仅在余量允许时呈现"（dr_room_ok = mem_wr_ready 回送）。
    task commit_one(input [STQ_IW-1:0] slot);
        integer guard;
        begin
            @(negedge clk);
            dr_valid = 4'b0001; dr_idx = slot;
            guard = 0;
            while ((!dr_room_ok) && (guard < 200)) begin
                @(negedge clk); guard = guard + 1;
            end
            @(posedge clk); #1;
            dr_valid = 4'b0000;
        end
    endtask

    //   单拍排空（mem_req_ready=1 一拍）；用于精确控制"低字先落地、高字被阻塞"。
    task drain_one;
        begin
            @(negedge clk); mem_req_ready = 1;
            @(posedge clk); #1;
            @(negedge clk); mem_req_ready = 0;
        end
    endtask

    //==========================================================================
    // 5. 向量
    //==========================================================================
    integer k, jj, guard, seen, szv;
    reg [7:0] xz_fix;
    reg [STQ_IW-1:0] s_idx, s_idx2;
    reg [LQ_IW-1:0]  l_idx, l_idx2;
    reg [31:0] exc_tval_c, exc_rob_c, exc_cause_c;
    reg        exc_seen;
    reg [31:0] v_addr;
    reg [STQ_IW-1:0] probe;

    initial begin
        g_total = 0; g_nonzero = 0; g_checks = 0; g_fails = 0; g_defect = 0; g_xz = 0;

        //----------------------------------------------------------------------
        // v1（F1）：ROB 63 → 0 环绕的 LQ 提交点释放 —— `head=63, ld_rob=0, cmt_n=2`
        //    修复后 `(0-63) mod 64 = 1 < 2` ⇒ 必须释放；旧实现算成 65 ⇒ 槽泄漏。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f1_lq_release_wrap63");
        rob_head = 63; cmt_n = 0; mem_req_ready = 0;
        alloc_load(6'd0, l_idx);
        chk(l_idx == 3'd0, "alloc load slot0");
        exe_load(l_idx, 6'd0, 32'h0000_1000, 3'd2, 1'b0, 6'd5, 6'd0, 1'b0);
        chk(u_lsq.ld_v[l_idx] == 1'b1, "load live before commit");
        @(negedge clk); cmt_n = 3'd2;
        @(posedge clk); #1;
        chk(u_lsq.ld_v[l_idx] == 1'b0, "LQ released across wrap 63->0");
        if (u_lsq.ld_v[l_idx] !== 1'b0) mark_defect;
        @(negedge clk); cmt_n = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v2（F1 正控）：不在提交窗口内的 LQ 项**不得**被释放（head=10, ld_rob=13, cmt_n=2）
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f1_lq_no_release_neg");
        rob_head = 10; cmt_n = 3'd2; mem_req_ready = 0;
        alloc_load(6'd13, l_idx);
        exe_load(l_idx, 6'd13, 32'h0000_1000, 3'd2, 1'b0, 6'd5, 6'd0, 1'b0);
        @(posedge clk); #1;
        chk(u_lsq.ld_v[l_idx] == 1'b1, "young LQ entry not released");
        @(negedge clk); cmt_n = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v3（F1）：一次提交窗口跨越 63/0/1 三个 LQ 项（head=62, cmt_n=4）⇒ 全部释放。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f1_lq_release_multiwrap");
        rob_head = 62; cmt_n = 0; mem_req_ready = 0;
        alloc_load(6'd63, l_idx);   exe_load(l_idx, 6'd63, 32'h0000_1000, 3'd2, 1'b0, 6'd5, 6'd0, 1'b0);
        alloc_load(6'd0,  l_idx2);  exe_load(l_idx2, 6'd0,  32'h0000_1004, 3'd2, 1'b0, 6'd6, 6'd0, 1'b0);
        alloc_load(6'd1,  probe);   exe_load(probe,  6'd1,  32'h0000_1008, 3'd2, 1'b0, 6'd7, 6'd0, 1'b0);
        @(negedge clk); cmt_n = 3'd4;
        @(posedge clk); #1;
        chk(u_lsq.ld_v[l_idx]  == 1'b0, "wrap entry 63 released");
        chk(u_lsq.ld_v[l_idx2] == 1'b0, "wrap entry 0 released");
        chk(u_lsq.ld_v[probe]  == 1'b0, "wrap entry 1 released");
        if ((u_lsq.ld_v[l_idx] !== 1'b0) || (u_lsq.ld_v[l_idx2] !== 1'b0) || (u_lsq.ld_v[probe] !== 1'b0)) mark_defect;
        @(negedge clk); cmt_n = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v4（F1）：环绕下的 STQ **提交窗翻译门** —— 唯一未定妥 store 在 head=63 前方
        //     一格 ⇒ 必须挡住提交（dr_room_ok=0）并向它的槽发翻译请求。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f1_stq_window_wrap63");
        rob_head = 63; st_xlate_en = 1; st_xlate_ctx = 4'h0; stx_adapt_en = 0;
        alloc_store(6'd0, s_idx);
        chk(s_idx == 5'd0, "store allocated slot0");
        exe_store(s_idx, 6'd0, 32'h0000_1234, 32'hA5A5_0000, 3'd2, 32'h0);
        @(posedge clk); #1;                    // E1 已退；仅剩提交窗扫描
        chk(st_xlate_valid == 1'b1, "wrap window requests translation");
        chk(st_xlate_idx == {STQ_IW{1'b0}} + s_idx, "translation targets wrapped slot");
        chk(st_xlate_va == 32'h0000_1234, "translation VA correct");
        chk(dr_room_ok == 1'b0, "unsettled wrapped store blocks commit");
        if (!((st_xlate_valid === 1'b1) && (st_xlate_idx === s_idx) && (dr_room_ok === 1'b0))) mark_defect;
        do_reset;
        vec_end;

        //----------------------------------------------------------------------
        // v5（F2）：STQ 槽 0..31 **逐槽**验证选择编码器 + 实际高槽分配 + 落地内容。
        //     每槽：先占住 0..k-1（Bare、提交并排空使其让位），再让目标 store 落槽 k
        //     且**唯一**处于提交窗内但翻译未定妥 ⇒ 翻译请求必须精确指向槽 k 与它的 VA
        //     （旧实现把 32 位候选喂给 8 位编码器 ⇒ STQ8..31 索引截断成 0）。
        //     另以槽 20 做"逐条提交 + 排空"的地址/数据/掩码内容验证。
        //----------------------------------------------------------------------
        vec_begin("f2_stq_slot_select32");
        for (k = 0; k < STQ_N; k = k + 1) begin
            do_reset;
            st_xlate_en = 0; stx_adapt_en = 0; mem_req_ready = 1; rob_head = 0;
            for (jj = 0; jj < k; jj = jj + 1) begin
                alloc_store(jj[ROBW-1:0], s_idx);
                exe_store(s_idx, jj[ROBW-1:0], 32'h0000_5000 + (jj * 4),
                          32'hB000_0000 + jj[31:0], 3'd2, 32'h0);
            end
            //   目标：带翻译需求（st_xlate_en=1），rob 远离当前 head ⇒ 暂不入窗。
            st_xlate_en = 1; st_xlate_ctx = 4'h0;
            alloc_store(6'd48, s_idx);
            chk(s_idx == k[STQ_IW-1:0], "store lands at expected slot k");
            exe_store(s_idx, 6'd48, 32'h0000_7000 + (k * 4), 32'hC0DE_0000 + k[31:0],
                      3'd2, 32'h0);
            //   让位：把 0..k-1 的填槽 store 逐条提交并排空（目标不在窗内 ⇒ 不挡提交）。
            for (jj = 0; jj < k; jj = jj + 1) begin
                commit_one(jj[STQ_IW-1:0]);
                drain_one;
            end
            //   只让目标处于提交窗：head = rob-1 = 31。
            @(negedge clk); rob_head = 6'd47;
            @(posedge clk); #1;
            chk(st_xlate_valid == 1'b1, "slot k pending translation");
            chk(st_xlate_idx == k[STQ_IW-1:0], "translation index == slot k");
            chk(st_xlate_va == (32'h0000_7000 + (k * 4)), "translation VA == slot k VA");
            chk(dr_room_ok == 1'b0, "unsettled slot k blocks commit");
            if (!((st_xlate_valid === 1'b1) && (st_xlate_idx === k[STQ_IW-1:0]))) mark_defect;
        end
        vec_end;
        //   ---- 高槽 20 的逐条提交/排空内容验证（合法生命周期：0..20 顺序提交）----
        do_reset;
        vec_begin("f2_high_slot_drain_content");
        st_xlate_en = 0; mem_req_ready = 1; rob_head = 0;
        for (k = 0; k < 21; k = k + 1) begin
            alloc_store(k[ROBW-1:0], s_idx);
            chk(s_idx == k[STQ_IW-1:0], "high-slot content: store lands at slot k");
            exe_store(s_idx, k[ROBW-1:0], 32'h0000_2050 + (k * 4),
                      32'hD000_0000 + k[31:0], 3'd2, 32'h0);
        end
        for (k = 0; k < 21; k = k + 1) begin
            commit_one(k[STQ_IW-1:0]);
            drain_one;
        end
        chk(n_wr == 21, "all 21 stores drained exactly once");
        chk(wr_a[20] == (32'h0000_2050 + (20 * 4)), "slot-20 drain address");
        chk(wr_d[20] == (32'hD000_0000 + 32'd20), "slot-20 drain data");
        chk(wr_s[20] == 4'hF, "slot-20 drain strobe");
        if ((n_wr !== 21) || (wr_a[20] !== (32'h0000_2050 + (20 * 4)))) mark_defect;
        vec_end;

        //----------------------------------------------------------------------
        // v6（F4/F3 正控）：已提交 store 的 CDQ 排空后 `stq_ret` 置位、槽回收；
        //     单笔 store 出队恰好一次写。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f4_single_beat_retire");
        st_xlate_en = 0; mem_req_ready = 0; rob_head = 6'd0;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_5000, 32'h1234_5678, 3'd2, 32'h0);
        commit_one(s_idx);
        @(negedge clk); rob_head = 6'd1;
        chk(u_lsq.stq_ret[s_idx] == 1'b0, "committed store not retired before drain");
        drain_one;
        chk(u_lsq.stq_ret[s_idx] == 1'b1, "single-beat store retires on its only drain");
        chk(n_wr == 1, "single-beat store one write");
        vec_end;

        //----------------------------------------------------------------------
        // v7（F3）：flush 与排空同拍 —— 写恰好一次且 CDQ 记账递减（旧实现重复发送/不减）。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f3_flush_drains_cdq");
        st_xlate_en = 0; mem_req_ready = 0; rob_head = 6'd0;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_6000, 32'hF00D_0001, 3'd2, 32'h0);
        commit_one(s_idx);
        @(negedge clk); rob_head = 6'd1;
        //   连续 3 拍 flush + ready：修复后第 1 拍写一次并出队，后 2 拍 CDQ 已空。
        @(negedge clk); flush_all = 1; mem_req_ready = 1;
        repeat (3) @(posedge clk);
        @(negedge clk); flush_all = 0; mem_req_ready = 0; #1;
        chk(n_wr == 1, "flush cycle writes the committed store exactly once");
        chk(u_lsq.cdq_cnt == 0, "CDQ drains during flush");
        chk(dr_empty_o == 1'b1, "dr_empty_o asserted after flush drain");
        if ((n_wr !== 1) || (u_lsq.cdq_cnt !== 0)) mark_defect;
        //   再给 2 拍 ready：不得出现第二笔写。
        @(negedge clk); mem_req_ready = 1;
        repeat (2) @(posedge clk);
        @(negedge clk); mem_req_ready = 0; #1;
        chk(n_wr == 1, "no duplicate write after flush drain");
        if (n_wr !== 1) mark_defect;
        vec_end;

        //----------------------------------------------------------------------
        // v8（F1/F4）：已提交但未排空的 store 在年轻分支 squash 下**不得被清**
        //     （其写已由 CDQ 携带；且 STQ 槽的 ret 身份必须保留到最后一笔）。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f1_squash_keeps_committed");
        st_xlate_en = 0; mem_req_ready = 0; rob_head = 6'd0;
        alloc_store(6'd5, s_idx);
        exe_store(s_idx, 6'd5, 32'h0000_7000, 32'hAAAA_0005, 3'd2, 32'h0);
        commit_one(s_idx);
        @(negedge clk); rob_head = 6'd6; squash_idx = 6'd10; squash = 1;
        @(posedge clk); #1;
        chk(u_lsq.stq_v[s_idx] == 1'b1, "committed store survives young squash");
        if (u_lsq.stq_v[s_idx] !== 1'b1) mark_defect;
        @(negedge clk); squash = 0;
        drain_one;
        chk(n_wr == 1, "committed store still drains after squash");
        chk(wr_a[0] == 32'h0000_7000, "committed store drain address after squash");
        vec_end;

        //----------------------------------------------------------------------
        // v9（F4）：拆笔 store 低字 fire 后**不得**释放 STQ 槽；高字被长时间背压
        //     （40 拍）后槽不被复用；高字落地才退休，且不得误标新占用者。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f4_split_low_no_release");
        st_xlate_en = 0; mem_req_ready = 0; rob_head = 6'd0;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_1000, 32'hAABB_CCDD, 3'd3, 32'h1122_3344);
        chk(u_lsq.stq_hi[s_idx] == 1'b1, "8B store marked split");
        commit_one(s_idx);
        chk(u_lsq.cdq_cnt == 2, "split store occupies two CDQ entries");
        //   低字出队（一拍 ready），随后长背压。
        drain_one;
        chk(n_wr == 1, "split low beat written once");
        chk(wr_a[0] == 32'h0000_1000, "split low beat address");
        chk(u_lsq.stq_ret[s_idx] == 1'b0, "low beat does NOT retire the store");
        chk(u_lsq.stq_v[s_idx] == 1'b1, "STQ slot held after low beat");
        if ((u_lsq.stq_ret[s_idx] !== 1'b0) || (u_lsq.stq_v[s_idx] !== 1'b1)) mark_defect;
        repeat (40) @(posedge clk);
        //   背压期间尝试分配新 store：绝不允许拿到旧槽。
        alloc_store(6'd1, s_idx2);
        chk(s_idx2 == 5'd1, "new store cannot reuse slot of pending split");
        if (s_idx2 === s_idx) mark_defect;
        //   放行高字。
        drain_one;
        chk(n_wr == 2, "split high beat written once");
        chk(wr_a[1] == 32'h0000_1004, "split high beat address");
        chk(wr_d[1] == 32'h1122_3344, "split high beat data");
        chk(u_lsq.stq_ret[s_idx]  == 1'b1, "store retires only after high beat");
        chk(u_lsq.stq_ret[s_idx2] == 1'b0, "new occupant NOT retired by stale high beat");
        if (u_lsq.stq_ret[s_idx2] !== 1'b0) mark_defect;
        vec_end;

        //----------------------------------------------------------------------
        // v10（F5）：跨 4 KB 的 ≤4B store（`sh @0x0FFF`）—— 高字（**对齐的下一个 4 B
        //      字基址** `(VA&~3)+4 = 0x1000`）必须经现有翻译接口**独立翻译**
        //      （页 1 → PA 0x4000_0000），不得沿用低字 PA+4。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f5_cross_page_indep_pa");
        st_xlate_en = 1; st_xlate_ctx = 4'h0; stx_adapt_en = 1; mem_req_ready = 0;
        pg1_fault = 0; rob_head = 63;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_0FFF, 32'h0000_ABCD, 3'd1, 32'h0);
        chk(u_lsq.stq_hi[s_idx] === 1'b1, "cross-page store marked split");
        //   ★ 独立 oracle：高字首字节地址 = `(VA & ~3) + 4`（不是 VA+4）。
        v_addr = (32'h0000_0FFF & 32'hFFFF_FFFC) + 32'd4;   // = 0x1000
        seen = 0;
        for (k = 0; k < 24; k = k + 1) begin
            @(posedge clk); #1;
            if ((st_xlate_valid === 1'b1) && (st_xlate_va === v_addr) &&
                (st_xlate_idx === s_idx)) seen = 1;
        end
        chk(seen === 1, "high beat translated independently (aligned VA+4 via st_xlate)");
        if (seen !== 1) mark_defect;
        chk(dr_room_ok === 1'b1, "both beats settled -> commit allowed");
        commit_one(s_idx);
        drain_one;
        drain_one;
        chk(n_wr === 2, "cross-page store exactly two writes");
        chk(wr_a[0] === 32'h3000_0FFF, "low beat PA from page0 map");
        chk(wr_a[1] === 32'h4000_0000, "high beat PA from INDEPENDENT page1 map (aligned)");
        chk(wr_d[1] === 32'h0000_00AB, "high beat data (bytes above 0xFFF)");
        chk(wr_s[1] === 4'h1, "high beat byte strobe");
        if ((n_wr !== 2) || (wr_a[1] !== 32'h4000_0000)) mark_defect;
        vec_end;

        //----------------------------------------------------------------------
        // v11（F5）：跨 4 KB 高字**翻译故障**必须在提交前传播 —— 精确 cause 15、
        //      **mtval = 实际故障部分的首字节地址**（独立 oracle：`(VA & ~3) + 4`）、
        //      该 store 不落地、无任何已提交写。
        //      覆盖 `sh@0xFFF` 与 `sw@0xFFD / 0xFFE / 0xFFF`：四者第二页部分首字节
        //      都是 0x1000（旧式 `VA+4` 会分别报 0x1003/0x1001/0x1002/0x1003 的错）。
        //----------------------------------------------------------------------
        vec_begin("f5_cross_page_fault");
        for (k = 0; k < 4; k = k + 1) begin
            do_reset;
            st_xlate_en = 1; st_xlate_ctx = 4'h0; stx_adapt_en = 1; mem_req_ready = 0;
            pg1_fault = 1; rob_head = 63;
            case (k)
                0: begin v_addr = 32'h0000_0FFF; szv = 1; s_idx2 = 5'd0; end  // sh @0xFFF
                1: begin v_addr = 32'h0000_0FFD; szv = 2; s_idx2 = 5'd0; end  // sw @0xFFD
                2: begin v_addr = 32'h0000_0FFE; szv = 2; s_idx2 = 5'd0; end  // sw @0xFFE
                default: begin v_addr = 32'h0000_0FFF; szv = 2; s_idx2 = 5'd0; end // sw @0xFFF
            endcase
            alloc_store(6'd0, s_idx2);
            exe_store(s_idx2, 6'd0, v_addr, 32'hA1B2_C3D4, szv[2:0], 32'h0);
            //   独立 oracle：故障部分首字节 = (VA & ~3) + 4。
            v_addr = {v_addr[31:2], 2'b00} + 32'd4;          // 期望 mtval
            exc_seen = 0; exc_cause_c = 0; exc_tval_c = 0; exc_rob_c = 0;
            for (jj = 0; jj < 24; jj = jj + 1) begin
                @(posedge clk); #1;
                if ((exc_valid_o === 1'b1) && (exc_seen === 0)) begin
                    exc_seen    = 1;
                    exc_cause_c = {28'h0, exc_cause_o};
                    exc_tval_c  = exc_tval_o;
                    exc_rob_c   = {26'h0, exc_rob_o};
                end
            end
            //   旧树没有高字独立翻译 ⇒ 不会报异常：此时按真实"提交排空"路径观察其错写。
            if (exc_seen !== 1) begin
                @(negedge clk); mem_req_ready = 1; dr_valid = 4'b0001; dr_idx = s_idx2;
                repeat (4) @(posedge clk);
                @(negedge clk); dr_valid = 0; mem_req_ready = 0; #1;
            end
            chk(exc_seen === 1, "high-beat fault raises precise exception");
            chk(exc_cause_c === 32'd15, "cause = store page fault (15)");
            chk(exc_tval_c === v_addr, "mtval = first byte of faulting part (aligned+4)");
            chk(exc_rob_c === 32'h0, "exception reports the store ROB index");
            chk(n_wr === 0, "no committed write for faulted cross-page store");
            chk(u_lsq.stq_bad[s_idx2] === 1'b1, "fault marked bad (not committed)");
            if (exc_seen !== 1) mark_defect;
        end
        vec_end;

        // v12（正控·无转发）：更老 store 未落地 ⇒ 依赖 load 不得访存；store 排空后
        //      load 才访存，且写回值来自**存储映像**（不是转发捷径）。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("ctrl_no_forward_policy");
        st_xlate_en = 0; mem_req_ready = 0; rob_head = 0;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_2000, 32'hDEAD_BEEF, 3'd2, 32'h0);
        alloc_load(6'd1, l_idx);
        exe_load(l_idx, 6'd1, 32'h0000_2000, 3'd2, 1'b0, 6'd9, 6'd0, 1'b0);
        chk(u_lsq.ld_dep_v[l_idx] == 1'b1, "load snapshots older-store dependency");
        //   提交前：load 绝不能发请求（无转发快路，且 CDQ 未空）。
        for (k = 0; k < 4; k = k + 1) begin
            @(posedge clk); #1;
            chk(!(mem_req_valid && !mem_req_wen), "no load request before store visible");
        end
        commit_one(s_idx);
        drain_one;                                   // store 落地（写进 mem 映像）
        chk(n_wr == 1, "store written once before load");
        //   现在 load 可发请求；响应来自存储映像。用**边沿锁存的监视器**判定（组合采样
        //   会与握手同拍竞争）。
        @(negedge clk); mem_req_ready = 1;
        for (k = 0; k < 16 && (n_ldreq == 0); k = k + 1) @(posedge clk);
        chk(n_ldreq >= 1, "load issues memory request after store drained");
        chk(last_ld_addr == 32'h0000_2000, "load request address");
        for (k = 0; k < 16 && (n_wb == 0); k = k + 1) @(posedge clk);
        chk(n_wb >= 1, "load writes back");
        chk(last_wb_data == 32'hDEAD_BEEF, "load data comes from memory image (no forwarding)");
        chk(last_wb_rob == 32'h1, "load writeback ROB index");
        @(negedge clk); mem_req_ready = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v13（正控·不把普通 load 串行到 ROB 头）：有依赖的老 load 等待时，更年轻的
        //      **无依赖** load 仍可占用唯一请求口。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("ctrl_young_indep_load");
        st_xlate_en = 0; mem_req_ready = 1; rob_head = 0;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_3000, 32'hCAFE_BABE, 3'd2, 32'h0);
        alloc_load(6'd1, l_idx);
        exe_load(l_idx, 6'd1, 32'h0000_3000, 3'd2, 1'b0, 6'd9, 6'd0, 1'b0);
        alloc_load(6'd2, l_idx2);
        exe_load(l_idx2, 6'd2, 32'h0000_3008, 3'd2, 1'b0, 6'd10, 6'd0, 1'b0);
        //   E1 后的**同一拍**组合检查：老依赖 load 等待，而更年轻的无依赖 load 占口。
        chk(u_lsq.ld_wait[l_idx] == 1'b1, "dependent older load waits");
        chk(mem_req_valid == 1'b1, "young independent load may issue");
        chk(mem_req_addr == 32'h0000_3008, "issued request belongs to independent load");
        if (!((mem_req_valid === 1'b1) && (mem_req_addr === 32'h0000_3008))) mark_defect;
        @(posedge clk); #1;
        chk(n_ldreq == 1, "exactly one load request (no blanket ROB-head serialization)");
        chk(last_ld_addr == 32'h0000_3008, "only the independent load requested");
        @(negedge clk); mem_req_ready = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v14（F1）：flush 后 LQ/STQ 全回收、无泄漏；且重复/迟到的响应不得二次写回。
        //----------------------------------------------------------------------
        do_reset;
        vec_begin("f1_flush_reclaim_no_dup_rsp");
        st_xlate_en = 0; mem_req_ready = 1; rob_head = 4;
        alloc_load(6'd5, l_idx);
        exe_load(l_idx, 6'd5, 32'h0000_1000, 3'd0, 1'b0, 6'd11, 6'd0, 1'b0);
        for (k = 0; k < 16 && (n_wb == 0); k = k + 1) @(posedge clk);
        chk(n_wb == 1, "exactly one writeback for one response");
        chk(n_ldreq == 1, "exactly one load request for one load");
        //   第二次（伪造）响应：标签命中但 `ld_req/ld_v` 已隔离 ⇒ 不得再次写回。
        @(negedge clk); rsp_force = 1; rsp_force_tag = {{(TAG_W-LQ_IW){1'b0}}, l_idx};
        rsp_force_data = 32'hBAD0_BAD0; rsp_force_err = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); rsp_force = 0; #1;
        chk(n_wb == 1, "duplicate response does not write back twice");
        if (n_wb !== 1) mark_defect;
        //   flush：全部回收。
        @(negedge clk); flush_all = 1; mem_req_ready = 0;
        @(posedge clk); #1;
        @(negedge clk); flush_all = 0; #1;
        chk(u_lsq.ld_v[l_idx] == 1'b0, "LQ cleared by flush");
        chk(stq_cnt_o == 8'h0, "STQ empty after flush");
        //   迟到响应（flush 后）：不得写回。
        @(negedge clk); rsp_force = 1; rsp_force_tag = {{(TAG_W-LQ_IW){1'b0}}, l_idx};
        rsp_force_data = 32'hDEAD_DEAD; rsp_force_err = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); rsp_force = 0; #1;
        chk(n_wb == 1, "late response after flush does not write back");
        if (n_wb !== 1) mark_defect;
        //   回收后可再次分配（无泄漏）。
        alloc_store(6'd0, s_idx);
        chk(s_idx == 5'd0, "STQ slot 0 reusable after flush");
        alloc_load(6'd0, l_idx);  exe_load(l_idx, 6'd0, 32'h0000_1000, 3'd0, 1'b0, 6'd12, 6'd0, 1'b0);
        @(negedge clk); rob_head = 63; cmt_n = 3'd2;
        @(posedge clk); #1;
        chk(u_lsq.ld_v[l_idx] == 1'b0, "reallocated LQ entry releases across wrap");
        if (u_lsq.ld_v[l_idx] !== 1'b0) mark_defect;
        @(negedge clk); cmt_n = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v16（初审 跨 flush 代际·同拍 done）：load 响应恰好落在 `flush_all` 拍
        //     ⇒ **不得**再向 ROB/PRF 发写回（该 ROB 项正被冲刷）。
        //----------------------------------------------------------------------
        vec_begin("flush_wb_same_cycle");
        do_reset;
        st_xlate_en = 0; rob_head = 6'd0; mem_req_ready = 1;
        alloc_load(6'd1, l_idx);
        exe_load(l_idx, 6'd1, 32'h0000_1000, 3'd0, 1'b0, 6'd20, 6'd0, 1'b0);
        seen = 0;
        for (k = 0; k < 20 && (seen === 0); k = k + 1) begin
            @(negedge clk);
            if (mem_rsp_valid === 1'b1) begin
                flush_all = 1;              // 响应拍同拍冲刷
                seen = 1;
            end
        end
        @(posedge clk); #1;
        chk(seen === 1, "load response observed on flush cycle");
        chk(n_wb === 0, "no writeback when response coincides with flush");
        chk(u_lsq.ld_v[l_idx] === 1'b0, "load slot reclaimed by flush");
        if (n_wb !== 0) mark_defect;
        @(negedge clk); flush_all = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v17（初审 STQ 翻译 act 跨 flush 代际）：在途翻译被冲刷后，同号槽复用给新
        //     store；**迟到的旧 done 不得把旧 PA 写进新占用者**（本模块在 flush 拍丢弃
        //     在途事务，新项由扫描器按自己的 VA 重译）。
        //----------------------------------------------------------------------
        vec_begin("flush_stq_xlate_act");
        do_reset;
        st_xlate_en = 1; st_xlate_ctx = 4'h0; stx_adapt_en = 1; stx_adapt_delay = 6;
        mem_req_ready = 0; rob_head = 63;
        alloc_store(6'd0, s_idx);
        exe_store(s_idx, 6'd0, 32'h0000_0123, 32'h1111_1111, 3'd2, 32'h0);
        repeat (2) @(posedge clk);
        chk(u_lsq.stx_act_q === 1'b1, "translation in flight before flush");
        @(negedge clk); flush_all = 1;
        @(posedge clk); #1;
        @(negedge clk); flush_all = 0;
        alloc_store(6'd0, s_idx2);
        chk(s_idx2 === 5'd0, "same STQ slot reused after flush");
        exe_store(s_idx2, 6'd0, 32'h0000_0A23, 32'h2222_2222, 3'd2, 32'h0);
        repeat (30) @(posedge clk); #1;
        chk(u_lsq.stq_pa[s_idx2] === 32'h3000_0A23, "reused slot translated from its OWN VA");
        chk(u_lsq.stq_pv[s_idx2] === 1'b1, "reused slot PA settled");
        if (u_lsq.stq_pa[s_idx2] !== 32'h3000_0A23) mark_defect;
        @(negedge clk); stx_adapt_delay = 0;
        vec_end;

        //----------------------------------------------------------------------
        // v18（初审 #2）：**四态检查器自证**（私有 fixture，不 force 真实 DUT 内部）：
        //     在 TB 侧构造一个确定的 X 源，验证 `is_known` 谓词与 `chk`（`!== 1'b1`）
        //     确实把未知判为失败；同时确认本向量窗口内 DUT 控制/有效窗口无 X/Z。
        //----------------------------------------------------------------------
        vec_begin("xz_checker_selfcheck");
        xz_fix = 8'hxx;
        chk(is_known({24'h0, xz_fix}) === 1'b0, "four-state predicate detects X fixture");
        chk(is_known(32'h1234_5678) === 1'b1, "four-state predicate accepts known value");
        @(posedge clk); #1;
        chk(xz_hit === 1'b0, "no X/Z on DUT controls in self-check window");
        vec_end;

        //----------------------------------------------------------------------
        // 汇总（fail-closed）：逐向量 + 唯一摘要行
        //----------------------------------------------------------------------
        $display("LSQ_VECTORS total=%0d nonzero=%0d checks=%0d fails=%0d defect=%0d xz=%0d",
                 g_total, g_nonzero, g_checks, g_fails, g_defect, g_xz);
        //   唯一 PASS 锚点：**只有**零失败、零缺陷签名且无 X/Z 命中才打印
        //   （旧树反证时必然不打印）。
        if ((g_fails == 0) && (g_defect == 0) && (g_xz == 0)) $display("FUNCTIONAL_LSQ: PASS");
        $finish;
    end

    //   兜底：绝不无限挂死（长超时打印可判定的失败摘要，rc 由脚本墙钟处理）。
    initial begin
        #4_000_000;
        $display("LSQ_VECTORS total=%0d nonzero=%0d checks=%0d fails=%0d defect=%0d xz=%0d",
                 g_total, g_nonzero, g_checks, g_fails + 1, g_defect, g_xz);
        $display("LSQ_TIMEOUT");
        $finish;
    end

endmodule
