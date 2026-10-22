//==============================================================================
// sim/unit/n12b_unalign_fwd.sv —— N12-fix **定向正证**：非对齐 load 的转发取数
//   字节道平移（LB/LH/LW/FLW/FLD × a2 = 0..3；全转发与「非对齐 + 部分转发合并」）
//------------------------------------------------------------------------------
// 项目 : rv32gc-cpu（EXP-N12-STRESS §8.1 定位的缺陷修复的独立验收用例）
// 背景 : 转发树按「8 B 窗口的**绝对字节道**」放数据 —— 本次访问的字节 i 落在道 a2+i
//        （a2 = exe_addr[1:0]，见 rtl/back2/lsq_simple.v §2.2/§2.3）。旧 `ext_load`
//        在 a2≠0 时：`sz≥2` 原样返回窗口低 32 bit、`sz=1` 只用 `off[1]` 二选半字
//        ⇒ 写回值整体错位（stress 实测 `lw@+1` obs=0x1df25700 vs isa=0xb81df257）。
//        修复 = 取数前把窗口**右移 a2 字节**（`fwdp_wsh`/`wbw_sh`）。
//
// 方法学（与 sim/unit/tb_back2_lsq_fwd.sv 同一"LSQ 直驱"夹具形态，只读复用 lsq_simple）：
//   · 不经前端/重命名：直接以分配/E1/提交信号驱动 `lsq_simple`；程序序模型自持
//     （rob 号 + `rob_head`/`cmt_n` 提交 + `dr_valid/dr_idx` 排空），逐场景：
//     分配更老 store → 分配 load 的 LQ 槽 → E1 全部 store → E1 load → 等写回 →
//     按程序序提交（store 排空、load 提交点释放）→ 等 STQ/LQ/CDQ 全空。
//   · **参考模型独立**：夹具自带字节级内存像 `memimg`（读响应同源）与
//     「本次访问的字节 i = 地址 base+a2+i 上那条 SB 的第 i 个字节」的逐字节参考
//     ⇒ 每条 load 的 `wb_data`（8 B 另比 `wb_data_hi`/`wb_f64`）与参考**逐位**比对。
//   · 覆盖设计：LB/LBU（a2=0..3）、LH/LHU（a2=0..3）、LW（a2=0..3）、FLW（a2=0..3）、
//     FLD（a2=0，两半组装）、以及**非对齐 + 部分转发合并**（LH@+1 只被 1 条 SB 覆盖，
//     另一字节来自访存响应）——后者同时验证 memory 路径的同一右移口径。
//   · ★★ N12B-cross（2026-10-01）新增覆盖：**≤4 B 非对齐且跨 4 B 对齐字边界**、
//     且跨字字节**需访存提供**的形态（LW@+1/+2/+3、LH/LHU@+3、FLW@+1；覆盖掩码
//     含"只覆盖首字节""只覆盖跨字字节""中间空洞""完全无 store"）——L1D 只回一个
//     `VA&~3` 对齐字，修法是复用 8 B 的**两拍**（首拍 VA、次拍 VA+4）拼 64 bit 窗口
//     后与转发同口径右移 a2 取数。判据 C 对这种形态断言 **恰好 2 笔**访存请求。
//
// 判据（全部 fail-closed；任一不满足 ⇒ $fatal，**绝不**打印 PASS 锚点）：
//   A 写回在有限拍内到达、且不得报数据侧异常
//   B 转发布局口径：`lmask_w8` == ((1<<size)-1)<<a2；逐字节命中掩码 `fwd_hit_w` == 参考
//     覆盖掩码 `exp_cov`；`fwd_all_w` == (命中掩码 ⊇ lmask_w8)（该线网在 N29B 下仅为
//     探针兼容保留，不再参与功能）
//   C ★★ N29B（纯等待变体）：**不再有"全转发 ⇒ 0 笔访存"** —— 有依赖的 load 一律等
//     older store 落地后访存。故"载入访存请求数"判据改为：非跨字 == 1 笔、跨 4 B 字
//     （含 8 B FLD 两拍）== 2 笔（与 N12B-cross 的既有一致；只是不再有 0 笔的情形）。
//     ★ 数据判据（D）不变：写回值仍等于「store 字节 + 内存像字节」的逐字节参考。
//   D `wb_data` == 参考值（逐位）；8 B：`wb_data_hi`/`wb_f64` 同判
//   E 目的寄存器方向正确（整数 load ⇒ wb_dst_i、FP load ⇒ wb_dst_f）
//   F 每个场景结束 STQ/LQ/CDQ 全空（槽回收正确）
//   G 全部检查项 0 失败 ⇒ 唯一一行 `N12B_UNALIGN_FWD: PASS`
//
// 运行（非 `tb_` 前缀 ⇒ 不进 regress.sh 既有回归；入口脚本见
//   fpga/scratch/n12b_unalign_fwd_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n12b_af.vvp -s n12b_unalign_fwd_top \
//            $(find rtl -name '*.v'|sort) sim/unit/n12b_unalign_fwd.sv && vvp /tmp/n12b_af.vvp
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module n12b_unalign_fwd_top;

    localparam integer STQ_N  = `BACK2_STQ_N;
    localparam integer STQ_IW = `BACK2_STQ_IDX_W;
    localparam integer OUT_N  = `BACK2_MEM_OUT_N;
    localparam integer TAG_W  = `BACK2_MEM_TAG_W;
    localparam integer ROBW   = `BACK2_ROB_IDX_W;
    localparam integer PDW_I  = `BACK2_PREG_I_W;
    localparam integer PDW_F  = `BACK2_PREG_F_W;
    localparam integer LQ_IW  = `BACK2_LQ_IDX_W;
    localparam integer MEMSZ  = 4096;

    //==========================================================================
    // 0. 时钟 / 复位
    //==========================================================================
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    //==========================================================================
    // 1. LSQ 直驱端口（与 sim/unit/n12_memstress_lsq.sv 同一契约）
    //==========================================================================
    reg              flush_all = 1'b0, squash = 1'b0;
    reg [ROBW-1:0]   squash_idx = 0, rob_head = 0;
    reg [3:0]        alloc_valid = 0;
    reg [4*ROBW-1:0] alloc_rob = 0;
    wire             alloc_ok;
    wire [4*STQ_IW-1:0] alloc_idx;
    reg [3:0]        lalloc_valid = 0;
    reg [4*ROBW-1:0] lalloc_rob = 0;
    wire             lalloc_ok;
    wire [4*LQ_IW-1:0] lalloc_idx;
    reg [LQ_IW-1:0]  exe_lq_idx = 0;
    reg              exe_valid = 0, exe_is_store = 0, exe_is_fp = 0;
    reg [ROBW-1:0]   exe_rob = 0;
    reg [`BACK2_EPOCH_W-1:0] exe_epoch = 0;
    reg [31:0]       exe_addr = 0, exe_wdata = 0, exe_wdata_hi = 0;
    reg [2:0]        exe_size = 0;
    reg              exe_unsign = 0, exe_dst_i = 0, exe_dst_f = 0;
    reg [PDW_I-1:0]  exe_pdest_i = 0;
    reg [PDW_F-1:0]  exe_pdest_f = 0;
    reg [STQ_IW-1:0] exe_stq_idx = 0;
    reg [ROBW-1:0]   iss_rob = 0;
    wire             iss_ok;
    reg [3:0]        dr_valid = 0;
    reg [4*STQ_IW-1:0] dr_idx = 0;
    reg [2:0]        cmt_n = 0;
    wire             mem_req_valid, mem_req_wen;
    wire [31:0]      mem_req_addr, mem_req_wdata;
    wire [3:0]       mem_req_wstrb;
    wire [TAG_W-1:0] mem_req_tag;
    reg              mem_req_ready = 1'b1;
    reg              mem_rsp_valid = 0;
    reg [31:0]       mem_rsp_rdata = 0;
    reg [TAG_W-1:0]  mem_rsp_tag = 0;
    reg              mem_rsp_err = 0;
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
    wire [7:0]       stq_cnt_o;
    wire [31:0]      cnt_load_o, cnt_store_o, cnt_fwd_o, cnt_stq_stall_o;
    wire             exc_valid_o;
    wire [ROBW-1:0]  exc_rob_o;
    wire [3:0]       exc_cause_o;
    wire [31:0]      exc_tval_o;
    wire             dr_empty_o;
    wire             st_xlate_valid_o;
    wire [31:0]      st_xlate_va_o;
    wire [STQ_IW-1:0] st_xlate_idx_o;
    wire [3:0]       st_xlate_ctx_o;

    lsq_simple #(.DBG(0)) u_lsq (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .squash(squash),
        .squash_idx(squash_idx), .rob_head(rob_head),
        .alloc_valid(alloc_valid), .alloc_rob(alloc_rob),
        .alloc_ok(alloc_ok), .alloc_idx(alloc_idx),
        .lalloc_valid(lalloc_valid), .lalloc_rob(lalloc_rob),
        .lalloc_ok(lalloc_ok), .lalloc_idx(lalloc_idx),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch), .exe_addr(exe_addr),
        .exe_wdata(exe_wdata), .exe_wdata_hi(exe_wdata_hi),
        .exe_size(exe_size), .exe_unsign(exe_unsign), .exe_dst_i(exe_dst_i),
        .exe_dst_f(exe_dst_f), .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f),
        .exe_stq_idx(exe_stq_idx), .exe_lq_idx(exe_lq_idx),
        .iss_rob(iss_rob), .iss_ok(iss_ok), .dr_empty_o(dr_empty_o),
        .dr_valid(dr_valid), .dr_idx(dr_idx), .dr_room_ok(),
        .cmt_n(cmt_n),
        .mem_req_valid(mem_req_valid), .mem_req_wen(mem_req_wen),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_wstrb(mem_req_wstrb), .mem_req_tag(mem_req_tag),
        .mem_req_ready(mem_req_ready), .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_rdata(mem_rsp_rdata), .mem_rsp_tag(mem_rsp_tag),
        .mem_rsp_err(mem_rsp_err),
`ifndef LSQ_LEGACY_IF
        //   ★★ F4：旧直驱夹具显式建模新 active 输入 known 0（禁止 Z 兼容逃生）。
        .mem_rsp_cause(4'd0), .mem_rsp_defer(1'b0), .mem_rsp_side(1'b0),
        .st_xlate_fault_cause(4'd0),
`endif
        .exc_valid_o(exc_valid_o), .exc_rob_o(exc_rob_o),
        .exc_cause_o(exc_cause_o), .exc_tval_o(exc_tval_o),
        .wb_valid(wb_valid), .wb_rob(wb_rob), .wb_epoch(wb_epoch),
        .wb_dst_i(wb_dst_i), .wb_dst_f(wb_dst_f), .wb_pdest_i(wb_pdest_i),
        .wb_pdest_f(wb_pdest_f), .wb_data(wb_data), .wb_data_hi(wb_data_hi),
        .wb_f64(wb_f64),
        .st_done_valid(st_done_valid), .st_done_rob(st_done_rob),
        .st_done_epoch(st_done_epoch),
        .stq_cnt_o(stq_cnt_o), .cnt_load_o(cnt_load_o), .cnt_store_o(cnt_store_o),
        .cnt_fwd_o(cnt_fwd_o), .cnt_stq_stall_o(cnt_stq_stall_o),
        .st_xlate_en(1'b0), .st_xlate_ctx(4'h0),
        .st_xlate_valid(st_xlate_valid_o), .st_xlate_va(st_xlate_va_o),
        .st_xlate_idx(st_xlate_idx_o), .st_xlate_ctx_o(st_xlate_ctx_o),
        .st_xlate_ready(1'b1), .st_xlate_done(1'b0),
        .st_xlate_pa(32'h0), .st_xlate_fault(1'b0)
    );

    //==========================================================================
    // 2. 字节级内存像 + 读响应模型（**非旋转**：返回含请求地址的对齐 4 B 字，
    //    与 rtl/cache/l1d.v 的 `cs_rdata = 对齐字` 同口径）
    //   ★★ N29B（纯等待变体）：**store 落地（CDQ 排空口的写）按 `mem_req_wstrb` 写进
    //     `memimg`** —— 这是"该 store 已对 L1D 真实可见"的夹具侧建模。被覆盖的字节由
    //     store 落地提供、其余字节仍是初值 ⇒ 写回值仍与 N12B 之前的参考**逐位相等**
    //     （数据来源从"转发"改成"落地后的存储映像"）。
    //==========================================================================
    integer k_mem;
    reg [7:0] memimg [0:MEMSZ-1];
    function [31:0] mem_word(input [31:0] a);
        integer wa;
        begin
            wa = {a[11:2], 2'b00};
            mem_word = {memimg[wa+3], memimg[wa+2], memimg[wa+1], memimg[wa]};
        end
    endfunction
    integer mw_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_tag   <= {TAG_W{1'b0}};
            mem_rsp_rdata <= 32'h0;
        end else begin
            mem_rsp_valid <= mem_req_valid & mem_req_ready & ~mem_req_wen;
            mem_rsp_tag   <= mem_req_tag;
            mem_rsp_rdata <= mem_word(mem_req_addr);
            if (mem_req_valid & mem_req_ready & mem_req_wen) begin
                mw_i = {mem_req_addr[11:2], 2'b00};
                if (mem_req_wstrb[0]) memimg[mw_i+0] <= mem_req_wdata[7:0];
                if (mem_req_wstrb[1]) memimg[mw_i+1] <= mem_req_wdata[15:8];
                if (mem_req_wstrb[2]) memimg[mw_i+2] <= mem_req_wdata[23:16];
                if (mem_req_wstrb[3]) memimg[mw_i+3] <= mem_req_wdata[31:24];
            end
        end
    end

    // ---- load 访存请求计数（全转发必须为 0）----
    integer n_ldreq;
    always @(posedge clk) if (rst_n & mem_req_valid & ~mem_req_wen) n_ldreq = n_ldreq + 1;

    //==========================================================================
    // 3. 检查设施（fail-closed）
    //==========================================================================
    integer n_chk = 0, n_fail = 0;
    task automatic chk(input cond, input string msg);
        begin
            n_chk = n_chk + 1;
            if (!cond) begin
                n_fail = n_fail + 1;
                $display("FAIL[n12b-unalign]: %s", msg);
            end
        end
    endtask
    task automatic ckfail(input string msg);
        begin $display("FAIL[n12b-unalign]: %s", msg); n_fail = n_fail + 1; end
    endtask

    function integer lq_occ;
        integer q;
        begin
            lq_occ = 0;
            for (q = 0; q < OUT_N; q = q + 1) if (u_lsq.ld_v[q]) lq_occ = lq_occ + 1;
        end
    endfunction

    //==========================================================================
    // 4. 驱动任务
    //==========================================================================
    reg [ROBW-1:0] rob_wr = {ROBW{1'b0}};

    task alloc_st(input [ROBW-1:0] rob, output [STQ_IW-1:0] slot, output ok);
        begin
            @(negedge clk);
            alloc_valid = 4'h1; alloc_rob[0*ROBW +: ROBW] = rob;
            slot = alloc_idx[0*STQ_IW +: STQ_IW];
            ok = alloc_ok;
            @(posedge clk);
            @(negedge clk);
            alloc_valid = 4'h0;
        end
    endtask

    task st_e1(input [STQ_IW-1:0] slot, input [ROBW-1:0] rob,
               input [31:0] a, input [31:0] d, input [2:0] sz);
        begin
            @(negedge clk);
            exe_valid = 1'b1; exe_is_store = 1'b1; exe_is_fp = 1'b0;
            exe_stq_idx = slot; exe_rob = rob;
            exe_addr = a; exe_wdata = d; exe_wdata_hi = 32'h0; exe_size = sz;
            exe_unsign = 1'b0; exe_dst_i = 1'b0; exe_dst_f = 1'b0;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0;
        end
    endtask

    task ld_alloc(input [ROBW-1:0] rob, output [LQ_IW-1:0] lslot, output ok);
        begin
            @(negedge clk);
            lalloc_valid = 4'h1; lalloc_rob[0*ROBW +: ROBW] = rob;
            lslot = lalloc_idx[0*LQ_IW +: LQ_IW];
            ok = lalloc_ok;
            @(posedge clk);
            @(negedge clk);
            lalloc_valid = 4'h0;
        end
    endtask

    //   load E1：同一拍组合态采样转发观测量（`lmask_w8`/`fwd_all_w`）
    reg [7:0] obs_lmask;
    reg [7:0] obs_fwh;
    reg       obs_fwa;
    task ld_e1(input [LQ_IW-1:0] slot, input [ROBW-1:0] rob, input [31:0] a,
               input [2:0] sz, input uns, input fp);
        begin
            @(negedge clk);
            exe_valid = 1'b1; exe_is_store = 1'b0; exe_is_fp = fp;
            exe_rob = rob; exe_lq_idx = slot; exe_addr = a;
            exe_size = sz; exe_unsign = uns;
            exe_dst_i = ~fp; exe_dst_f = fp;
            exe_pdest_i = 6'd7; exe_pdest_f = 6'd9;
            iss_rob = rob;
            #1;
            obs_lmask = u_lsq.lmask_w8;
            obs_fwh   = u_lsq.fwd_hit_w;
            obs_fwa   = u_lsq.fwd_all_w;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0; exe_is_fp = 1'b0;
        end
    endtask

    reg [31:0] obs_lo, obs_hi;
    reg        obs_f64, obs_dsti, obs_dstf;
    task wait_ld(input [ROBW-1:0] rob, output got_wb, output got_exc);
        integer t;
        begin
            got_wb = 1'b0; got_exc = 1'b0;
            for (t = 0; t < 600; t = t + 1) begin
                @(posedge clk);
                if (wb_valid && (wb_rob === rob)) begin
                    obs_lo = wb_data; obs_hi = wb_data_hi; obs_f64 = wb_f64;
                    obs_dsti = wb_dst_i; obs_dstf = wb_dst_f;
                    got_wb = 1'b1;
                end
                if (exc_valid_o && (exc_rob_o === rob)) got_exc = 1'b1;
                if (got_wb || got_exc) t = 600;
            end
        end
    endtask

    task cmt_store(input [STQ_IW-1:0] slot, input [ROBW-1:0] rob, output ok);
        integer t;
        reg done;
        begin
            done = 1'b0;
            for (t = 0; t < 400 && !done; t = t + 1) begin
                @(negedge clk);
                rob_head = rob; cmt_n = 3'd1;
                dr_valid = 4'h1; dr_idx = {3'b0, slot};
                @(posedge clk);
                if (u_lsq.dr_take[0]) done = 1'b1;
                @(negedge clk);
                dr_valid = 4'h0; cmt_n = 3'd0;
            end
            ok = done;
        end
    endtask

    task cmt_load(input [ROBW-1:0] rob);
        begin
            @(negedge clk);
            rob_head = rob; cmt_n = 3'd1;
            @(posedge clk);
            @(negedge clk); cmt_n = 3'd0;
        end
    endtask

    task wait_idle(output ok);
        integer t;
        begin
            ok = 1'b0;
            for (t = 0; t < 800; t = t + 1) begin
                @(posedge clk);
                if (dr_empty_o && (stq_cnt_o === 8'd0) && (lq_occ() == 0)) begin
                    ok = 1'b1; t = 800;
                end
            end
            @(negedge clk);
        end
    endtask

    //==========================================================================
    // 5. 场景状态
    //==========================================================================
    reg [STQ_IW-1:0] w_sslot [0:7];
    reg [ROBW-1:0]   w_srob  [0:7];
    reg [7:0]        cb      [0:7];      // load 字节参考：byte i = SB@(base+a2+i) 的第 i 字节
    reg [31:0]       m_base;
    reg [ROBW-1:0]   rob_load;
    integer          c_id;

    //   单场景公共部分：逐字节 SB 覆盖 → load E1 → 判据（A..F）→ 提交收尾
    //   `exp_lo`/`exp_hi` 由调用方按参考模型给出（独立于 RTL）
    task automatic do_load(input [2:0] sz, input [1:0] off, input uns, input fp,
                           input [7:0] exp_cov,
                           input [31:0] exp_lo, input [31:0] exp_hi, input exp_f64,
                           input integer exp_req, input string nm);
        integer i, nst, nsize;
        reg ok, got_wb, got_exc;
        reg [LQ_IW-1:0] lslot;
        begin
            nsize = 1 << sz;
            nst   = nsize;
            // ---- 更老 store：逐字节 SB（序号越大越年轻）----
            for (i = 0; i < nst; i = i + 1) begin
                rob_wr = rob_wr + 1'b1;
                w_srob[i] = rob_wr;
                alloc_st(w_srob[i], w_sslot[i], ok);
                if (!ok) ckfail({nm, "：store 分配失败"});
                st_e1(w_sslot[i], w_srob[i], m_base + off + i, {24'h0, cb[i]}, 3'd0);
            end
            // ---- load ----
            rob_wr = rob_wr + 1'b1;
            rob_load = rob_wr;
            n_ldreq = 0;
            ld_alloc(rob_load, lslot, ok);
            if (!ok) ckfail({nm, "：LQ 分配失败"});
            ld_e1(lslot, rob_load, m_base + off, sz, uns, fp);
            chk(obs_lmask === (((8'h01 << nsize) - 8'h01) << off), {nm, "：lmask_w8 与 size/a2 口径不符"});
            chk(obs_fwh === exp_cov, {nm, "：逐字节命中掩码 fwd_hit_w 与参考覆盖不符"});
            chk(obs_fwa === ((exp_cov & obs_lmask) == obs_lmask), {nm, "：fwd_all_w 与命中口径不符"});
            //   ★★ N29B：**先让更老 store 按程序序提交排空**（= 对 L1D 可见），load 才能
            //     通过等待闸门发出访存。旧顺序（先 wait_ld 再提交）在纯等待变体下必然超时。
            for (i = 0; i < nst; i = i + 1) begin
                cmt_store(w_sslot[i], w_srob[i], ok);
                if (!ok) ckfail({nm, "：store 排空未被 CDQ 收下"});
            end
            wait_ld(rob_load, got_wb, got_exc);
            chk(got_wb, {nm, "：load 未在限期内写回"});
            chk(!got_exc, {nm, "：本场景不应有数据侧异常"});
            chk(n_ldreq == exp_req, {nm, "：访存请求数与口径不符（有依赖 ⇒ 必访存）"});
            chk(obs_lo === exp_lo, {nm, "：wb_data 与逐字节参考不一致"});
            if (sz == 3'd3) begin
                chk(obs_hi === exp_hi, {nm, "：wb_data_hi 与参考不一致"});
                chk(obs_f64 === exp_f64, {nm, "：wb_f64 与参考不一致"});
            end
            if (fp) chk(obs_dstf === 1'b1, {nm, "：FP load 应写 FP 目的口"});
            else    chk(obs_dsti === 1'b1, {nm, "：整数 load 应写整数目的口"});
            // ---- 收尾：load 提交点释放 → 全空 ----
            cmt_load(rob_load);
            wait_idle(ok);
            if (!ok) ckfail({nm, "：场景结束 STQ/LQ/CDQ 未回空（槽泄漏/排空悬挂）"});
        end
    endtask

    //   全转发场景：load 的全部字节都被逐字节 SB 覆盖（⇒ 不访存）
    task automatic run_full(input integer id, input [2:0] sz, input [1:0] off,
                            input uns, input fp);
        integer i, nsize;
        reg [15:0] hh;
        reg [31:0] elo, ehi;
        begin
            c_id   = id;
            m_base = 32'h8000_2000 + (id << 5);          // 每场景独立 8 B 对齐块
            nsize  = 1 << sz;
            for (i = 0; i < nsize; i = i + 1)
                cb[i] = 8'h80 | ((id*8'd7 + i*8'd5 + 8'd1) & 8'h7F);   // 高位恒 1：同时判有符号/零扩展
            elo = 32'h0; ehi = 32'h0;
            case (sz)
                3'd0: elo = uns ? {24'h0, cb[0]} : {{24{cb[0][7]}}, cb[0]};
                3'd1: begin
                          hh  = {cb[1], cb[0]};
                          elo = uns ? {16'h0, hh} : {{16{hh[15]}}, hh};
                      end
                3'd2: elo = {cb[3], cb[2], cb[1], cb[0]};
                3'd3: begin
                          elo = {cb[3], cb[2], cb[1], cb[0]};
                          ehi = {cb[7], cb[6], cb[5], cb[4]};
                      end
            endcase
            //   ★★ N29B：全字节覆盖不再意味着"0 笔访存" —— 有依赖一律等待后访存。
            //     访存笔数 = 1（字内）/ 2（跨 4 B 对齐字：8 B FLD、LW@a2≠0、LH@a2=3）。
            do_load(sz, off, uns, fp, ((8'h01 << nsize) - 8'h01) << off,
                    elo, ehi, (sz == 3'd3),
                    ((sz == 3'd3) || ((sz == 3'd2) && (off != 2'd0)) ||
                     ((sz == 3'd1) && (off == 2'd3))) ? 2 : 1,
                    $sformatf("case#%0d(sz=%0d,a2=%0d,uns=%0d,fp=%0d,全字节覆盖)",
                              id, sz, off, uns, fp));
        end
    endtask

    //   非对齐 + **部分**转发（非跨字）：LH@+1 只被 1 条 SB 覆盖，另一字节来自访存响应
    //   ⇒ 同时验证 memory 路径的右移口径（`wbw_sh`）。`lane` = 被覆盖的字节序号（1 或 2）。
    task automatic run_part(input integer id, input integer lane);
        integer i;
        reg [31:0] mw;
        reg [15:0] hh;
        reg [31:0] elo;
        begin
            c_id   = id;
            m_base = 32'h8000_2000 + (id << 5);
            mw     = mem_word(m_base);                   // 参考 = 同一份内存像
            for (i = 0; i < 8; i = i + 1) cb[i] = 8'hA0 | i;
            //   只发一条 SB：地址 base+lane（lane=1 ⇒ 覆盖 load 字节 0；lane=2 ⇒ 字节 1）
            rob_wr = rob_wr + 1'b1;
            w_srob[0] = rob_wr;
            begin : part
                reg ok, got_wb, got_exc;
                reg [LQ_IW-1:0] lslot;
                alloc_st(w_srob[0], w_sslot[0], ok);
                if (!ok) ckfail($sformatf("case#%0d：store 分配失败", id));
                st_e1(w_sslot[0], w_srob[0], m_base + lane, {24'h0, cb[lane]}, 3'd0);
                rob_wr = rob_wr + 1'b1;
                rob_load = rob_wr;
                n_ldreq = 0;
                ld_alloc(rob_load, lslot, ok);
                if (!ok) ckfail($sformatf("case#%0d：LQ 分配失败", id));
                ld_e1(lslot, rob_load, m_base + 2'd1, 3'd1, 1'b0, 1'b0);
                chk(obs_lmask === 8'h06, $sformatf("case#%0d：lmask_w8 应为 0x06(a2=1,LH)", id));
                chk(obs_fwa === 1'b0, $sformatf("case#%0d：部分命中不得判全转发", id));
                //   参考：LH@+1 = {对齐字 byte2, byte1}，其中 lane 字节来自 store；
                //   本场景是 **有符号** LH（uns=0）⇒ 必须按 bit15 符号扩展
                hh  = (lane == 1) ? {mw[23:16], cb[1]} : {cb[2], mw[15:8]};
                elo = {{16{hh[15]}}, hh};
                //   ★★ N29B：先提交该更老 store（落地进 memimg），load 才能访存
                cmt_store(w_sslot[0], w_srob[0], ok);
                if (!ok) ckfail($sformatf("case#%0d：store 排空未被 CDQ 收下", id));
                wait_ld(rob_load, got_wb, got_exc);
                chk(got_wb, $sformatf("case#%0d：load 未写回", id));
                chk(!got_exc, $sformatf("case#%0d：不应有异常", id));
                chk(n_ldreq >= 1, $sformatf("case#%0d(部分转发)：应发访存", id));
                chk(obs_lo === elo, $sformatf("case#%0d(LH@+1 部分转发, lane=%0d)：wb_data 与参考不一致", id, lane));
                chk(obs_dsti === 1'b1, $sformatf("case#%0d：整数 load 应写整数目的口", id));
                cmt_load(rob_load);
                wait_idle(ok);
                if (!ok) ckfail($sformatf("case#%0d：场景结束 STQ/LQ/CDQ 未回空", id));
            end
        end
    endtask

    //   非对齐 + **跨 4 B 对齐字边界**的 ≤4 B load（N12B-cross 修复点）：
    //   `covmask` 的 bit i = load 字节 i 被一条更老 SB 覆盖，其余字节**必须由访存提供**。
    //   跨字 ⇒ 对齐字 A（道 0..3）与对齐字 A+4（道 4..7）各需一笔 ⇒ **两拍访存**
    //   （`exp_req` = 2）。参考模型 = 逐字节「被覆盖 ⇒ SB 数据；否则 ⇒ 内存像字节」。
    task automatic run_cross(input integer id, input [2:0] sz, input [1:0] off,
                             input uns, input fp, input [7:0] covmask,
                             input integer exp_req, input string nm);
        integer i, nsize, nst;
        reg [LQ_IW-1:0] lslot;
        reg ok, got_wb, got_exc;
        reg [7:0]  bb [0:7];
        reg [7:0]  efwh;
        reg [31:0] a_i, elo;
        reg [15:0] hh;
        begin
            m_base = 32'h8000_2000 + (id << 5);
            nsize  = 1 << sz;
            for (i = 0; i < 8; i = i + 1) cb[i] = 8'h90 | i[7:0];   // SB 数据（高位恒 1）
            // ---- 独立参考：逐字节 ----
            //   `fwd_hit_w` 的位号 = **窗口字节号**（本次访问的字节 i 落在 gb = off + i），
            //   而 `covmask` 的位号 = **访问内字节序号** i ⇒ 期望掩码必须按 off 移位。
            efwh = 8'h00;
            for (i = 0; i < nsize; i = i + 1) begin
                a_i  = m_base + {30'b0, off} + i[31:0];
                bb[i] = covmask[i] ? cb[i] : memimg[a_i[11:0]];
                if (covmask[i]) efwh[off + i] = 1'b1;   // 整数加法（i 可达 7 ⇒ gb 可达 7）
            end
            elo = 32'h0; hh = 16'h0;
            case (sz)
                3'd0: elo = uns ? {24'h0, bb[0]} : {{24{bb[0][7]}}, bb[0]};
                3'd1: begin hh  = {bb[1], bb[0]};
                            elo = uns ? {16'h0, hh} : {{16{hh[15]}}, hh}; end
                default: elo = {bb[3], bb[2], bb[1], bb[0]};
            endcase
            // ---- 更老 store：每个被覆盖字节一条 SB ----
            nst = 0;
            for (i = 0; i < nsize; i = i + 1) begin
                if (covmask[i]) begin
                    rob_wr = rob_wr + 1'b1;
                    w_srob[nst] = rob_wr;
                    alloc_st(w_srob[nst], w_sslot[nst], ok);
                    if (!ok) ckfail({nm, "：store 分配失败"});
                    st_e1(w_sslot[nst], w_srob[nst], m_base + {30'b0, off} + i[31:0],
                          {24'h0, cb[i]}, 3'd0);
                    nst = nst + 1;
                end
            end
            // ---- load ----
            rob_wr = rob_wr + 1'b1;
            rob_load = rob_wr;
            n_ldreq = 0;
            ld_alloc(rob_load, lslot, ok);
            if (!ok) ckfail({nm, "：LQ 分配失败"});
            ld_e1(lslot, rob_load, m_base + {30'b0, off}, sz, uns, fp);
            chk(obs_lmask === (((8'h01 << nsize) - 8'h01) << off),
                {nm, "：lmask_w8 与 size/a2 口径不符"});
            chk(obs_fwh === efwh,
                {nm, "：逐字节命中掩码 fwd_hit_w 与参考覆盖不符"});
            chk(obs_fwa === 1'b0, {nm, "：部分命中不得判全转发"});
            //   ★★ N29B：先按程序序提交更老 store（落地进 memimg），load 才能访存
            for (i = 0; i < nst; i = i + 1) begin
                cmt_store(w_sslot[i], w_srob[i], ok);
                if (!ok) ckfail({nm, "：store 排空未被 CDQ 收下"});
            end
            wait_ld(rob_load, got_wb, got_exc);
            chk(got_wb, {nm, "：load 未在限期内写回"});
            chk(!got_exc, {nm, "：≤4 B 非对齐不得有数据侧异常（cause 4 只属 8 B）"});
            chk(n_ldreq == exp_req,
                {nm, "：跨 4 B 字边界应发两拍访存（对齐字 A 与 A+4）"});
            chk(obs_lo === elo, {nm, "：wb_data 与逐字节参考不一致"});
            if (fp) chk(obs_dstf === 1'b1, {nm, "：FP load 应写 FP 目的口"});
            else    chk(obs_dsti === 1'b1, {nm, "：整数 load 应写整数目的口"});
            // ---- 收尾：load 提交点释放 ----
            cmt_load(rob_load);
            wait_idle(ok);
            if (!ok) ckfail({nm, "：场景结束 STQ/LQ/CDQ 未回空"});
        end
    endtask

    //==========================================================================
    // 6. 主流程
    //==========================================================================
    initial begin
        $display("== N12-fix 定向正证：非对齐 load 转发取数（LB/LH/LW/FLW/FLD × a2，全转发 + 部分转发合并）");
        for (k_mem = 0; k_mem < MEMSZ; k_mem = k_mem + 1)
            memimg[k_mem] = (k_mem * 8'd37 + 8'd11) & 8'hFF;
        rst_n = 1'b0; repeat (8) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        rob_head = {ROBW{1'b0}}; rob_wr = {ROBW{1'b0}};

        // ---- LB / LBU：a2 = 0..3 ----
        run_full(0,  3'd0, 2'd0, 1'b0, 1'b0);
        run_full(1,  3'd0, 2'd1, 1'b0, 1'b0);
        run_full(2,  3'd0, 2'd2, 1'b0, 1'b0);
        run_full(3,  3'd0, 2'd3, 1'b0, 1'b0);
        run_full(4,  3'd0, 2'd0, 1'b1, 1'b0);
        run_full(5,  3'd0, 2'd1, 1'b1, 1'b0);
        run_full(6,  3'd0, 2'd2, 1'b1, 1'b0);
        run_full(7,  3'd0, 2'd3, 1'b1, 1'b0);
        // ---- LH / LHU：a2 = 0..3 ----
        run_full(8,  3'd1, 2'd0, 1'b0, 1'b0);
        run_full(9,  3'd1, 2'd1, 1'b0, 1'b0);
        run_full(10, 3'd1, 2'd2, 1'b0, 1'b0);
        run_full(11, 3'd1, 2'd3, 1'b0, 1'b0);
        run_full(12, 3'd1, 2'd1, 1'b1, 1'b0);
        run_full(13, 3'd1, 2'd3, 1'b1, 1'b0);
        // ---- LW：a2 = 0..3 ----
        run_full(14, 3'd2, 2'd0, 1'b0, 1'b0);
        run_full(15, 3'd2, 2'd1, 1'b0, 1'b0);
        run_full(16, 3'd2, 2'd2, 1'b0, 1'b0);
        run_full(17, 3'd2, 2'd3, 1'b0, 1'b0);
        // ---- FLW：a2 = 0..3（FP 目的）----
        run_full(18, 3'd2, 2'd0, 1'b0, 1'b1);
        run_full(19, 3'd2, 2'd1, 1'b0, 1'b1);
        run_full(20, 3'd2, 2'd2, 1'b0, 1'b1);
        run_full(21, 3'd2, 2'd3, 1'b0, 1'b1);
        // ---- FLD：a2=0（8 B 两半组装）----
        run_full(22, 3'd3, 2'd0, 1'b0, 1'b1);
        // ---- 非对齐 + 部分转发合并（LH@+1，1 条 SB；另一字节来自访存）----
        run_part(23, 1);
        run_part(24, 2);
        // ---- ★★ 非对齐 **跨 4 B 对齐字边界** + 需访存（N12B-cross 修复点）----
        //   covmask = 被更老 SB 覆盖的 load 字节集合；其余字节必须由访存提供。
        //   · LW@+1/+2/+3、LH@+3、FLW@+1：部分覆盖 / 完全不覆盖（两拍取齐）
        run_cross(25, 3'd2, 2'd1, 1'b0, 1'b0, 8'b0000_0001, 2,
                  "case#25(LW@+1, 只覆盖字节0)");
        run_cross(26, 3'd2, 2'd1, 1'b0, 1'b0, 8'b0000_0000, 2,
                  "case#26(LW@+1, 无 store 全访存)");
        run_cross(27, 3'd2, 2'd2, 1'b0, 1'b0, 8'b0000_0001, 2,
                  "case#27(LW@+2, 只覆盖字节0)");
        run_cross(28, 3'd2, 2'd2, 1'b0, 1'b0, 8'b0000_0000, 2,
                  "case#28(LW@+2, 无 store 全访存)");
        run_cross(29, 3'd2, 2'd3, 1'b0, 1'b0, 8'b0000_0001, 2,
                  "case#29(LW@+3, 只覆盖字节0)");
        run_cross(30, 3'd2, 2'd3, 1'b0, 1'b0, 8'b0000_0000, 2,
                  "case#30(LW@+3, 无 store 全访存)");
        run_cross(31, 3'd1, 2'd3, 1'b0, 1'b0, 8'b0000_0001, 2,
                  "case#31(LH@+3, 有符号, 只覆盖字节0)");
        run_cross(32, 3'd1, 2'd3, 1'b0, 1'b0, 8'b0000_0000, 2,
                  "case#32(LH@+3, 有符号, 无 store)");
        run_cross(33, 3'd1, 2'd3, 1'b1, 1'b0, 8'b0000_0000, 2,
                  "case#33(LHU@+3, 无符号, 无 store)");
        run_cross(34, 3'd2, 2'd1, 1'b0, 1'b1, 8'b0000_0000, 2,
                  "case#34(FLW@+1, 无 store, FP 目的)");
        //   **跨字那一笔的转发**：只覆盖字节 3（地址 base+4，属对齐字 A+4）
        run_cross(35, 3'd2, 2'd1, 1'b0, 1'b0, 8'b0000_1000, 2,
                  "case#35(LW@+1, 只覆盖跨字字节3)");
        run_cross(36, 3'd2, 2'd2, 1'b0, 1'b0, 8'b0000_0011, 2,
                  "case#36(LW@+2, 覆盖字节0-1)");
        run_cross(37, 3'd1, 2'd3, 1'b0, 1'b0, 8'b0000_0010, 2,
                  "case#37(LH@+3, 只覆盖跨字字节1)");
        //   低字内**中间空洞**：字 A 的字节 2 来自访存、字节 3 属字 A+4 也来自访存
        run_cross(38, 3'd2, 2'd1, 1'b0, 1'b0, 8'b0000_0101, 2,
                  "case#38(LW@+1, 覆盖字节0/2, 中间空洞)");

        // ---- 汇总（fail-closed：0 失败才打印 PASS 锚点）----
        $display("== 检查项合计 %0d 项，失败 %0d 项", n_chk, n_fail);
        if (n_fail == 0) begin
            $display("N12B_UNALIGN_FWD: PASS");
        end else begin
            $display("FAIL: N12B_UNALIGN_FWD 判据不满足");
            $fatal(1, "N12B_UNALIGN_FWD 失败");
        end
        $finish;
    end

    // 全局超时兜底（fail-closed）
    initial begin
        #400000;
        $display("FAIL: N12B_UNALIGN_FWD 超时");
        $fatal(1, "N12B_UNALIGN_FWD 超时");
    end
endmodule
