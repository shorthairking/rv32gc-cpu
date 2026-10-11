//==============================================================================
// sim/unit/n12_memstress_lsq.sv —— EXP-N12-STRESS：LSQ store→load **转发压力
//   workload**（定向循环流；非 `tb_` 前缀 ⇒ 不进 regress.sh 的既有回归）
//------------------------------------------------------------------------------
// 项目 : rv32gc-cpu（EXP-N12A 遗留项 answer.md §2.1「额外的 memory stress 测试」）
// 目的 : N12A 报告（fpga/scratch/n12_fwd_demand_report.md §9）指出端到端只有 136 条
//        load-E1、多 store 拼接只有 **1** 条 ⇒ 条件比例 n=11 不可外推。本 workload
//        把「store→load 转发」压成**高密度循环流**，让 N12A 只读探针（
//        sim/unit/dyn_probe_n12_*.sv|inc）能逐拍采到：
//          · 多候选重叠（同一 load 的字节范围被 ≥2 条更老已定址 store 覆盖）
//          · 单条 store 完整覆盖（N12B 的快路）
//          · **多 store 拼接**（并集覆盖但无单条完整覆盖 —— N12B 必须等待的场景）
//          · 部分命中（转发 + 访存合并）
//          · **更老 store 未定址（stq_v & ~stq_av）时 load 被挡**（闸门阻塞拍）
//          · 非对齐 / 跨 4 B word / 各类 load size（LB/LH/LW/FLW/FLD）
//          以及 各类 store size（SB/SH/SW/SD）
//
// 方法学（与 sim/unit/tb_back2_lsq_fwd.sv 同一"LSQ 直驱"夹具形态，只读复用 lsq_simple）：
//   · **不经前端/重命名**：直接以分配/E1/提交信号驱动 `lsq_simple`（与 tb_back2_lsq_fwd
//     同一端口契约），因此每条 load 的 E1 都由本夹具显式决定 ⇒ 采样点确定、可复现。
//   · **程序序模型**：本夹具自己维护 rob 号与提交（rob_head/cmt_n + dr_valid/dr_idx），
//     逐场景：分配更老 store → 分配 load 的 LQ 槽 → E1 全部 store → E1 load →
//     等写回 → 按程序序提交（store 排空、load 提交点释放）→ 等 STQ/LQ/CDQ 全空。
//     ⇒ STQ 转发窗口（`fw_live_e` = v & av & age<age_rob）与产品在真机里的语义一致。
//   · **参考模型**：夹具自带字节级内存像 `memimg`（读响应直接由它产生）与
//     「最年轻匹配更老 store 逐字节覆盖」参考计算 ⇒ 每条被检查 load 的 `wb_data`
//     （8 B 的 `wb_data_hi`/`wb_f64`）都与参考值逐位比对，**不是自证**。
//   · **不判数据的场景**（mode=1，非对齐 LW/LH 的转发形态覆盖）：只检查转发形态
//     （fwa/访存请求/无异常）；数据仅打印诊断（见本文件 §遗留说明与报告）。
//   · **8 B 非对齐 FLD**（mode=2）：产品口径 `va[2:0]!=0 ⇒ cause 4` 且**不发访存**；
//     本夹具按 `exc_valid_o/exc_cause_o=4` + 访存请求数 0 判定。
//
// 判据（全部 fail-closed；任一不满足 ⇒ $fatal，禁止"未捕获即通过"）：
//   A 每条 load 都在有限拍内完成（写回或（8 B 非对齐的）cause 4 异常）
//   B mode=0 场景：`wb_data`/`wb_data_hi`/`wb_f64` 与参考模型逐位相等
//   C 每条 load 的 `fwd_hit_w`/`fwd_all_w` 与本夹具**独立**算出的
//     「字节并集覆盖」/「并集全覆盖」一致（与探针分析器的 I2/I3 互锁）
//   D 全转发（或 8 B 非对齐）⇒ 访存请求数 = 0；否则 ≥1（复刻 C4 口径）
//   E mode=2 ⇒ 恰一次 cause 4、无写回、无访存；其余 mode ⇒ 无异常
//   F load E1 当拍 `iss_ok=1`（闸门有效 ⇒ E1 不会撞上"更老未定址 store"）
//   G mode=3 闸门场景：**确实**观测到 ≥1 拍 `ld_want & ~iss_ok`（更老 store 未定址阻塞）
//   H 每个场景结束后 STQ/LQ/CDQ 全部回到空（槽回收正确、无泄漏）
//   I 产品自带计数器 `cnt_load_o` = 夹具 load 数、`cnt_fwd_o` = 夹具观测的命中 load 数
//   J 全部检查项 0 失败 ⇒ 唯一一行 `N12_MEMSTRESS_LSQ: PASS`
//
// 运行（见 fpga/scratch/n12_stress_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n12_st.vvp -s dyn_probe_n12_stress \
//            $(find rtl -name '*.v'|sort) sim/unit/n12_memstress_lsq.sv \
//            sim/unit/dyn_probe_n12_core.sv sim/unit/dyn_probe_n12_stress.sv && vvp ...
//   -DN12_STRESS_IT=<n> 覆盖迭代数（默认 60；每轮 25 个场景 ⇒ 1500 条 load-E1）
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module n12_memstress_lsq_top;

    localparam integer STQ_N  = `BACK2_STQ_N;
    localparam integer STQ_IW = `BACK2_STQ_IDX_W;
    localparam integer OUT_N  = `BACK2_MEM_OUT_N;
    localparam integer TAG_W  = `BACK2_MEM_TAG_W;
    localparam integer ROBW   = `BACK2_ROB_IDX_W;
    localparam integer PDW_I  = `BACK2_PREG_I_W;
    localparam integer PDW_F  = `BACK2_PREG_F_W;
    localparam integer LQ_IW  = `BACK2_LQ_IDX_W;

`ifdef N12_STRESS_IT
    localparam integer N_IT = `N12_STRESS_IT;
`else
    localparam integer N_IT = 60;
`endif
    localparam integer N_SC  = 25;      // 场景数（bench 编号 0..24）
    localparam integer MEMSZ = 4096;

    //==========================================================================
    // 0. 时钟 / 复位
    //==========================================================================
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    //==========================================================================
    // 1. LSQ 直驱端口（与 sim/unit/tb_back2_lsq_fwd.sv 同一契约，只读复用）
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
    // 2. 字节级内存像 + 读响应模型（**非旋转**：返回含请求地址的对齐 4 B 字）
    //    · `ext_load(w, off, sz, uns)` 的字节道口径见 lsq_simple §写回段：
    //      LB 取 w[8*off]、LH 取 w[15:0]/w[31:16]、LW 取 w；
    //      ⇒ 与"返回该地址所在的对齐字"一致（a2=0/2 的半字、a2=0 的字）。
    //    · store 落地**不改** `memimg`：本夹具的参考模型与读模型同源（自洽），
    //      目的只测**转发**（真机的 store 落地语义由 lockstep/core_top TB 覆盖）。
    //    · 8 B 访问两拍：首拍 VA、次拍 VA+4（各自对齐字）⇒ 拼成 64 bit 小端。
    //==========================================================================
    integer k_mem;
    reg [7:0] memimg [0:MEMSZ-1];
    reg [11:0] n12_wa;
    reg [31:0] n12_rsp_word;
    always @(*) begin
        n12_wa       = {mem_req_addr[11:2], 2'b00};
        n12_rsp_word = {memimg[n12_wa+3], memimg[n12_wa+2],
                        memimg[n12_wa+1], memimg[n12_wa]};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_tag   <= {TAG_W{1'b0}};
            mem_rsp_rdata <= 32'h0;
        end else begin
            mem_rsp_valid <= mem_req_valid & mem_req_ready & ~mem_req_wen;
            mem_rsp_tag   <= mem_req_tag;
            mem_rsp_rdata <= n12_rsp_word;
        end
    end

    // ---- 观测量：load 访存请求拍数（复刻 C4「全转发不得访存」口径）----
    integer n_ldreq;
    always @(posedge clk) if (rst_n & mem_req_valid & ~mem_req_wen) n_ldreq = n_ldreq + 1;

    // ---- 闸门阻塞观测（供 N12A 探针的 `ldblk` 列；本夹具无 backend_top）----
    //   语义 = 「夹具有一条 load 就绪、而 `iss_ok=0`（存在更老未定址 store）挡着它」
    //   ≡ backend_top.lsu_ld_block 的 `iss_ok=0` 子集（n12 分析器的 `ldblk_iss` 口径）。
    reg  ld_want = 1'b0;
    wire lsu_ld_block = ld_want & ~iss_ok;
    //   探针 `bench` 列 = 场景编号（0..N_SC-1），便于分场景直方图。
    reg [31:0] bench_cur = 32'd0;

    //==========================================================================
    // 3. 检查设施
    //==========================================================================
    integer n_chk = 0, n_fail = 0;
    //   ★ 用 SV `string` 传消息（宽向量 `[8*N-1:0]` 会在长中文串上截断/乱码；
    //     tb_back2_ipc.sv 同口径）。
    task automatic chk(input cond, input string msg);
        begin
            n_chk = n_chk + 1;
            if (!cond) begin
                n_fail = n_fail + 1;
                $display("FAIL[n12-stress]: %s", msg);
            end
        end
    endtask
    task automatic ckfail(input string msg);
        begin $display("FAIL[n12-stress]: %s", msg); n_fail = n_fail + 1; end
    endtask

    function integer lq_occ;
        integer q;
        begin
            lq_occ = 0;
            for (q = 0; q < OUT_N; q = q + 1) if (u_lsq.ld_v[q]) lq_occ = lq_occ + 1;
        end
    endfunction

    //==========================================================================
    // 4. 场景状态（模块级，避免不可综合/TB 差异的局部数组）
    //==========================================================================
    integer        c_nst;
    reg [2:0]      c_stsz  [0:3];
    reg [7:0]      c_stoff [0:3];   // ★ 必须 ≥5 bit：曾用 4 bit 把 16 截成 0
                                    //   （把"不相交 store"变成叠在 base+0 的第 3 个候选）
    reg [31:0]     c_stdat [0:3];
    reg [31:0]     c_stdath[0:3];
    reg [2:0]      c_ldsz;
    reg            c_ldfp;
    reg [3:0]      c_ldoff;
    reg            c_lduns;
    reg [PDW_F-1:0] c_ldpf;
    integer        c_mode;          // 0=全判据 1=只判转发形态 2=8B 非对齐(cause 4) 3=闸门场景

    // 工作数组
    reg [STQ_IW-1:0] w_sslot [0:3];
    reg [ROBW-1:0]   w_srob  [0:3];
    reg [7:0]        w_eb    [0:7];        // load 字节参考值（byte i = load_addr + i）
    reg              w_cov   [0:7];        // 该 load 字节是否被 ≥1 条更老 store 覆盖

    // 观测
    reg [7:0]  obs_lmask, obs_fwh;
    reg        obs_hit, obs_fwa;
    reg        obs_issok;
    reg [31:0] obs_lo, obs_hi;
    reg        obs_f64;
    reg [3:0]  obs_cause;
    reg [31:0] obs_tval;
    reg        obs_wb_dst;
    integer    obs_ldreq;

    // rob 记账
    reg [ROBW-1:0] rob_wr;
    reg [ROBW-1:0] rob_base, rob_load;

    // 统计
    integer n_ld_total, n_ld_checked, n_hit_total, n_fwa_total;
    integer n_gate_blocked;
    integer it_i, sc_i;

    //==========================================================================
    // 5. 驱动任务
    //==========================================================================
    // ---- 分配一条 store（只分配，不 E1；槽号必须在分配拍采样）----
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

    // ---- store E1（地址/数据/掩码入 STQ；`iss_rob` 由调用方先设好）----
    task st_e1(input [STQ_IW-1:0] slot, input [ROBW-1:0] rob,
               input [31:0] a, input [31:0] d, input [31:0] dh, input [2:0] sz);
        begin
            @(negedge clk);
            exe_valid = 1'b1; exe_is_store = 1'b1; exe_is_fp = 1'b0;
            exe_stq_idx = slot; exe_rob = rob;
            exe_addr = a; exe_wdata = d; exe_wdata_hi = dh; exe_size = sz;
            exe_unsign = 1'b0; exe_dst_i = 1'b0; exe_dst_f = 1'b0;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0;
        end
    endtask

    // ---- 分配 load 的 LQ 槽（D3 派发口径）----
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

    // ---- load E1（并在**同一拍组合态**采样转发观测量）----
    task ld_e1(input [LQ_IW-1:0] slot, input [ROBW-1:0] rob, input [31:0] a);
        begin
            @(negedge clk);
            exe_valid = 1'b1; exe_is_store = 1'b0; exe_is_fp = c_ldfp;
            exe_rob = rob; exe_lq_idx = slot; exe_addr = a;
            exe_size = c_ldsz; exe_unsign = c_lduns;
            exe_dst_i = ~c_ldfp; exe_dst_f = c_ldfp;
            exe_pdest_i = {PDW_I{1'b0}} | 6'd7;
            exe_pdest_f = c_ldpf;
            iss_rob = rob;
            #1;
            obs_lmask = u_lsq.lmask_w8;
            obs_fwh   = u_lsq.fwd_hit_w;
            obs_hit   = |u_lsq.fwd_hit_w;
            obs_fwa   = u_lsq.fwd_all_w;
            obs_issok = iss_ok;
            @(posedge clk);
            @(negedge clk); exe_valid = 1'b0; exe_is_store = 1'b0; exe_is_fp = 1'b0;
        end
    endtask

    // ---- 等这条 load 的写回或数据侧异常（有限拍）----
    //   ★ 8 B 非对齐的 `mis_v` 会**同时**给出 `wb_valid`（`wb_dst_*=0`，不写目的寄存器）
    //     与 `exc_valid_o`（cause 4）⇒ 完成判定取"两者任一"，并由调用方按 mode 区分。
    task wait_ld(input [ROBW-1:0] rob, output got_wb, output got_exc);
        integer t;
        begin
            got_wb = 1'b0; got_exc = 1'b0;
            obs_wb_dst = 1'b1;
            for (t = 0; t < 600; t = t + 1) begin
                @(posedge clk);
                if (wb_valid && (wb_rob === rob)) begin
                    obs_lo = wb_data; obs_hi = wb_data_hi; obs_f64 = wb_f64;
                    obs_wb_dst = wb_dst_i | wb_dst_f;
                    got_wb = 1'b1;
                end
                if (exc_valid_o && (exc_rob_o === rob)) begin
                    obs_cause = exc_cause_o; obs_tval = exc_tval_o;
                    got_exc = 1'b1;
                end
                if (got_wb || got_exc) t = 600;
            end
        end
    endtask

    // ---- 提交一条 store（排空：CDQ 余量门要求 CDQ 全空 ⇒ 需重试到被收下）----
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

    // ---- 提交一条 load（提交点释放 LQ 槽）----
    task cmt_load(input [ROBW-1:0] rob);
        begin
            @(negedge clk);
            rob_head = rob; cmt_n = 3'd1;
            @(posedge clk);
            @(negedge clk); cmt_n = 3'd0;
        end
    endtask

    // ---- 等 STQ/LQ/CDQ 全空（槽回收证明；fail-closed）----
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
    // 6. 场景定义（base 为 8 B 对齐；`off` = 相对 base 的字节偏移）
    //    约定：`c_stdat[0]` 最老，序号越大越年轻（重叠时更年轻者胜 —— 与 C3 同口径）
    //==========================================================================
    function [31:0] d32(input integer it, input integer k);
        begin
            d32 = (32'hB7E1_5163 * (it * 4 + k + 1)) ^ 32'h5A5A_1234;
        end
    endfunction

    task set_scen(input integer id);
        integer k;
        begin
            c_nst = 0;
            for (k = 0; k < 4; k = k + 1) begin
                c_stsz[k] = 3'd2; c_stoff[k] = 4'd0;
                c_stdat[k] = 32'h0; c_stdath[k] = 32'h0;
            end
            c_ldsz = 3'd2; c_ldfp = 1'b0; c_ldoff = 4'd0;
            c_lduns = 1'b0; c_ldpf = 6'd0; c_mode = 0;
            case (id)
                //  ---- 单条 store 完整覆盖（N12B 快路）----
                0: begin c_nst=1; c_stsz[0]=2; c_stoff[0]=0;
                          c_ldsz=2; c_ldoff=0; end                       // SW → LW
                1: begin c_nst=1; c_stsz[0]=3; c_stoff[0]=0;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd3; end // SD → FLD（更宽 store）
                13:begin c_nst=1; c_stsz[0]=2; c_stoff[0]=0;
                          c_ldsz=2; c_ldfp=1; c_ldoff=0; c_ldpf=6'd5; end // SW → FLW
                22:begin c_nst=1; c_stsz[0]=2; c_stoff[0]=0;
                          c_ldsz=1; c_ldoff=0; end                       // SW → LH（更窄 load）
                //  ---- 多 store 拼接（N12B 必须等待）----
                2: begin c_nst=2; c_stsz[0]=2; c_stoff[0]=0; c_stsz[1]=2; c_stoff[1]=4;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd7; end // 2×SW → FLD（N12A p14 场景）
                3: begin c_nst=2; c_stsz[0]=2; c_stoff[0]=4; c_stsz[1]=2; c_stoff[1]=0;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd9; end // 同上，程序序逆序
                4: begin c_nst=4; c_stsz[0]=2; c_stoff[0]=0; c_stsz[1]=2; c_stoff[1]=4;
                          c_stsz[2]=2; c_stoff[2]=0; c_stsz[3]=2; c_stoff[3]=4;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd11; end // 4 候选重叠 + 拼接 + 更年轻者胜
                5: begin c_nst=4; c_stsz[0]=0; c_stoff[0]=0; c_stsz[1]=0; c_stoff[1]=1;
                          c_stsz[2]=0; c_stoff[2]=2; c_stsz[3]=0; c_stoff[3]=3;
                          c_ldsz=2; c_ldoff=0; end                       // 4×SB → LW 拼接
                21:begin c_nst=2; c_stsz[0]=1; c_stoff[0]=0; c_stsz[1]=1; c_stoff[1]=2;
                          c_ldsz=2; c_ldoff=0; end                       // 2×SH → LW 拼接
                23:begin c_nst=2; c_stsz[0]=2; c_stoff[0]=0; c_stsz[1]=0; c_stoff[1]=4;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd13; end // SW+SB → FLD（部分命中 5/8）
                18:begin c_nst=3; c_stsz[0]=2; c_stoff[0]=0; c_stsz[1]=2; c_stoff[1]=4;
                          c_stsz[2]=1; c_stoff[2]=6;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd15; end // 拼接 + **3 候选重叠**（SH@+6 更年轻，7/8 字节最年轻者胜）
                //  ---- 部分命中 / 零命中 ----
                6: begin c_nst=2; c_stsz[0]=0; c_stoff[0]=0; c_stsz[1]=0; c_stoff[1]=1;
                          c_ldsz=2; c_ldoff=0; end                       // 2/4 字节
                16:begin c_nst=1; c_stsz[0]=0; c_stoff[0]=0;
                          c_ldsz=2; c_ldoff=0; end                       // 1/4 字节
                17:begin c_nst=1; c_stsz[0]=1; c_stoff[0]=0;
                          c_ldsz=2; c_ldoff=0; end                       // 2/4 字节（半字）
                14:begin c_nst=2; c_stsz[0]=2; c_stoff[0]=0; c_stsz[1]=1; c_stoff[1]=4;
                          c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd17; end // 6/8 字节
                10:begin c_nst=0; c_ldsz=2; c_ldoff=0; end               // 零候选 LW
                11:begin c_nst=0; c_ldsz=3; c_ldfp=1; c_ldoff=0; c_ldpf=6'd19; end // 零候选 FLD（两拍访存）
                12:begin c_nst=1; c_stsz[0]=2; c_stoff[0]=8;
                          c_ldsz=2; c_ldoff=0; end                       // 不相交 → 零命中
                //  ---- 字节/半字偏移（掩码移位轴）----
                7: begin c_nst=1; c_stsz[0]=0; c_stoff[0]=3;
                          c_ldsz=0; c_ldoff=3; c_lduns=1; end            // SB@+3 → LBU@+3
                8: begin c_nst=1; c_stsz[0]=1; c_stoff[0]=2;
                          c_ldsz=1; c_ldoff=2; c_lduns=1; end            // SH@+2 → LHU@+2
                9: begin c_nst=1; c_stsz[0]=0; c_stoff[0]=1;
                          c_ldsz=0; c_ldoff=1; c_lduns=0; end            // SB@+1 → LB@+1
                //  ---- 非对齐 load 的**转发形态**覆盖（mode=1：只判转发，不判数据）----
                19:begin c_nst=4; c_stsz[0]=0; c_stoff[0]=1; c_stsz[1]=0; c_stoff[1]=2;
                          c_stsz[2]=0; c_stoff[2]=3; c_stsz[3]=0; c_stoff[3]=4;
                          c_ldsz=2; c_ldoff=1; c_mode=1; end             // 非对齐 LW（跨 word，4×SB 全转发）
                24:begin c_nst=2; c_stsz[0]=0; c_stoff[0]=1; c_stsz[1]=0; c_stoff[1]=2;
                          c_ldsz=1; c_ldoff=1; c_mode=1; end             // 非对齐 LH（2×SB 全转发）
                //  ---- 8 B 非对齐 FLD ⇒ cause 4、不发访存 ----
                20:begin c_nst=0; c_ldsz=3; c_ldfp=1; c_ldoff=4; c_ldpf=6'd21;
                          c_mode=2; end                                  // a3=1 ⇒ 非对齐
                //  ---- 闸门：更老 store 未定址（stq_v & ~stq_av）挡住 load ----
                15:begin c_nst=1; c_stsz[0]=2; c_stoff[0]=0;
                          c_ldsz=2; c_ldoff=0; c_mode=3; end
                default: begin c_nst=0; c_ldsz=2; c_ldoff=0; c_mode=0; end
            endcase
        end
    endtask

    //==========================================================================
    // 7. 单场景执行
    //==========================================================================
    integer        j, i, nb, sbytes;
    integer        soff, tmo;
    reg [31:0]     base_a, laddr, sa, sd, sdh, exp_lo, exp_hi;
    reg [7:0]      sbyte, expb;
    reg [LQ_IW-1:0] w_lslot;
    reg            ok, ok2, got_wb, got_exc;
    reg            exp_fwa, exp_hit, exp_mem, exp_exc;
    integer        cov_n, full_n;

    task run_case(input integer id, input [31:0] base, input integer it);
        begin
            bench_cur = id[31:0];
            rob_base  = rob_wr;
            rob_load  = rob_wr + c_nst[ROBW-1:0];
            laddr     = base + {28'b0, c_ldoff};
            n_ldreq   = 0;

            // ---- 更老 store 的数据（同一 it 内各 lane 不同 ⇒ 重叠场景"更年轻者胜"可辨）----
            for (i = 0; i < c_nst; i = i + 1) begin
                c_stdat[i]  = d32(it, i);
                c_stdath[i] = d32(it, i + 64);
            end

            // ---- 参考模型：字节并集覆盖 + 最年轻者胜 ----
            nb = 1 << c_ldsz;
            for (i = 0; i < 8; i = i + 1) begin
                w_eb[i] = 8'h0; w_cov[i] = 1'b0;
            end
            for (i = 0; i < nb; i = i + 1)
                w_eb[i] = memimg[laddr[11:0] + i];
            for (i = 0; i < c_nst; i = i + 1) begin
                sa     = base + {28'b0, c_stoff[i]};
                sbytes = 1 << c_stsz[i];
                for (j = 0; j < sbytes; j = j + 1) begin
                    soff = (sa + j) - laddr;
                    if ((soff >= 0) && (soff < nb)) begin
                        case (c_stsz[i])
                            3'd0:    sbyte = c_stdat[i][7:0];
                            3'd1:    sbyte = c_stdat[i][8*j +: 8];
                            3'd2:    sbyte = c_stdat[i][8*j +: 8];
                            default: sbyte = (j < 4) ? c_stdat[i][8*j +: 8]
                                                     : c_stdath[i][8*(j-4) +: 8];
                        endcase
                        w_eb[soff]  = sbyte;      // 更年轻者后写 ⇒ 覆盖更老者
                        w_cov[soff] = 1'b1;
                    end
                end
            end
            cov_n = 0; full_n = 0;
            for (i = 0; i < nb; i = i + 1) begin
                if (w_cov[i]) cov_n = cov_n + 1;
            end
            exp_hit = (cov_n > 0);
            exp_fwa = (cov_n == nb);

            // 参考写回值
            exp_lo = 32'h0; exp_hi = 32'h0;
            if (c_ldsz == 3'd0)      exp_lo = c_lduns ? {24'h0, w_eb[0]} : {{24{w_eb[0][7]}}, w_eb[0]};
            else if (c_ldsz == 3'd1) exp_lo = c_lduns ? {16'h0, w_eb[1], w_eb[0]}
                                                      : {{16{w_eb[1][7]}}, w_eb[1], w_eb[0]};
            else if (c_ldsz == 3'd2) exp_lo = {w_eb[3], w_eb[2], w_eb[1], w_eb[0]};
            else begin
                exp_lo = {w_eb[3], w_eb[2], w_eb[1], w_eb[0]};
                exp_hi = {w_eb[7], w_eb[6], w_eb[5], w_eb[4]};
            end
            exp_mem = exp_fwa ? 1'b0 : ((c_mode == 2) ? 1'b0 : 1'b1);
            exp_exc = (c_mode == 2);

            // ---- 分配更老 store ----
            for (i = 0; i < c_nst; i = i + 1) begin
                w_srob[i] = rob_base + i[ROBW-1:0];
                alloc_st(w_srob[i], w_sslot[i], ok);
                if (!ok) ckfail("A STQ 分配失败（alloc_ok=0）");
            end
            iss_rob = rob_load;

            // ---- mode=3：先让 load 在闸门外等（更老 store 还没定址）----
            //   ★ 这是**构造**的阻塞窗口：夹具有一条 load 就绪、store 的地址尚未解析
            //     （stq_v & ~stq_av）⇒ `iss_ok=0` 挡住它。真机里窗口长度由 AGU/发射时序决定。
            if (c_mode == 3) begin
                @(negedge clk); ld_want = 1'b1;
                tmo = 0;
                n_gate_blocked = 0;
                for (i = 0; i < 4; i = i + 1) begin
                    @(posedge clk);
                    n_gate_blocked = n_gate_blocked + lsu_ld_block;
                end
                @(negedge clk); ld_want = 1'b0;
                chk(n_gate_blocked == 4,
                    "G 闸门场景：4 拍等待窗口内应每拍都被「更老 store 未定址」挡住");
            end

            // ---- store E1（定址）----
            for (i = 0; i < c_nst; i = i + 1)
                st_e1(w_sslot[i], w_srob[i], base + {28'b0, c_stoff[i]},
                      c_stdat[i], c_stdath[i], c_stsz[i]);

            // ---- load：分配 LQ 槽 → E1 ----
            ld_alloc(rob_load, w_lslot, ok2);
            if (!ok2) ckfail("A LQ 分配失败（lalloc_ok=0）");
            n_ldreq = 0;
            ld_e1(w_lslot, rob_load, laddr);
            n_ld_total = n_ld_total + 1;
            if (obs_hit) n_hit_total = n_hit_total + 1;
            if (obs_fwa) n_fwa_total = n_fwa_total + 1;

            // ---- 判据 C：转发形态（独立参考 vs 产品）----
            chk(obs_hit === exp_hit, "C fwd_hit_w 与参考「字节并集覆盖」不一致");
            chk(obs_fwa === exp_fwa, "C fwd_all_w 与参考「并集全覆盖」不一致");
            // ---- 判据 F：E1 当拍闸门有效（不会撞上更老未定址 store）----
            chk(obs_issok === 1'b1, "F load E1 当拍 iss_ok=0（更老 store 未定址竟进入 E1）");

            // ---- 等待完成 ----
            wait_ld(rob_load, got_wb, got_exc);
            obs_ldreq = n_ldreq;
            if (!got_wb && !got_exc) ckfail("A load 未在限期内完成（写回/异常均未出现）");

            // ---- 判据 E：异常口径 ----
            if (exp_exc) begin
                //   ★ 8 B 非对齐：产品**同拍**给 wb_valid（done）+ exc_valid（cause 4），
                //     但 `wb_dst_i/wb_dst_f` 被抑制为 0（不得写目的寄存器）。
                chk(got_exc, "E 8 B 非对齐应报数据侧异常（exc_valid_o）");
                chk(obs_cause === 4'd4, "E 8 B 非对齐 cause 应为 4（load address misaligned）");
                chk(got_wb && (obs_wb_dst === 1'b0),
                    "E 8 B 非对齐不得写目的寄存器（wb_dst_i|wb_dst_f 应 = 0）");
            end else begin
                chk(!got_exc, "E 非预期数据侧异常（本场景不应产生异常）");
                chk(got_wb && (obs_wb_dst === 1'b1), "E 本场景应有写回（且写目的寄存器）");
            end
            // ---- 判据 D：访存请求口径 ----
            if (exp_mem) chk(obs_ldreq >= 1, "D 非全转发 load 应至少发 1 笔访存请求");
            else         chk(obs_ldreq == 0, "D 全转发/非对齐 load 不得发访存请求");
            // ---- 判据 B：数据逐位 ----
            if ((c_mode == 0) || (c_mode == 3)) begin
                n_ld_checked = n_ld_checked + 1;
                if (exp_exc) begin
                    /* mode 2 已在上方判过 */
                end else if (c_ldsz == 3'd3) begin
                    chk(got_wb && (obs_lo === exp_lo) && (obs_hi === exp_hi) && (obs_f64 === 1'b1),
                        "B FLD 写回（wb_data/wb_data_hi/wb_f64）与参考不一致");
                end else begin
                    chk(got_wb && (obs_lo === exp_lo),
                        "B load 写回 wb_data 与参考（最年轻更老 store 逐字节覆盖 + 访存）不一致");
                end
            end else if (c_mode == 1) begin
                // 只判转发形态；数据打印诊断（见文件头 §遗留说明）
                if (got_wb)
                    $display("[n12-stress diag] bench=%0d misaligned-mode sz=%0d off=%0d lmask=0x%02x fwa=%0d memreq=%0d obs=0x%08x isa_ref=0x%08x diff=%0d",
                             id, c_ldsz, c_ldoff, obs_lmask, obs_fwa, obs_ldreq,
                             obs_lo, exp_lo, (obs_lo === exp_lo) ? 0 : 1);
            end

            // ---- 提交（程序序）：全部 store 排空 → load 提交点释放 ----
            for (i = 0; i < c_nst; i = i + 1) begin
                cmt_store(w_sslot[i], w_srob[i], ok);
                if (!ok) ckfail("H store 提交排空未被 CDQ 收下（dr_take=0）");
            end
            cmt_load(rob_load);
            wait_idle(ok);
            if (!ok) ckfail("H 场景结束 STQ/LQ/CDQ 未回空（槽泄漏/排空悬挂）");

            rob_wr = rob_load + 1'b1;
        end
    endtask

    //==========================================================================
    // 8. 主流程
    //==========================================================================
    reg [31:0] m_base;
    integer    t_i, s_i;

    initial begin
        n_ld_total = 0; n_ld_checked = 0; n_hit_total = 0; n_fwa_total = 0;
        n_gate_blocked = 0; n_ldreq = 0;
        for (k_mem = 0; k_mem < MEMSZ; k_mem = k_mem + 1)
            memimg[k_mem] = (k_mem * 8'd37 + 8'd11) & 8'hFF;
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        rob_head = {ROBW{1'b0}}; rob_wr = {ROBW{1'b0}}; iss_rob = {ROBW{1'b0}};

        $display("== N12 memory stress workload（LSQ 直驱；%0d 场景 × %0d 迭代 = %0d load-E1）",
                 N_SC, N_IT, N_SC * N_IT);

        for (t_i = 0; t_i < N_IT; t_i = t_i + 1) begin
            for (s_i = 0; s_i < N_SC; s_i = s_i + 1) begin
                m_base = 32'h100 + ((t_i % 8) * 32);
                set_scen(s_i);
                run_case(s_i, m_base, t_i);
            end
        end

        // ---- 汇总判据 ----
        chk(cnt_load_o === n_ld_total[31:0], "I cnt_load_o ≠ 夹具 load 数（产品计数与观测不一致）");
        chk(cnt_fwd_o  === n_hit_total[31:0], "I cnt_fwd_o ≠ 夹具命中 load 数（产品计数与观测不一致）");
        chk(n_fwa_total > 0, "存在性：应至少有一条全转发 load");
        chk(n_ld_total == N_SC * N_IT, "load 总数 ≠ 场景数×迭代数");

        $display("== 原始计数：load=%0d（判数据 %0d） 命中=%0d 全转发=%0d 闸门阻塞拍=%0d",
                 n_ld_total, n_ld_checked, n_hit_total, n_fwa_total, n_gate_blocked);
        $display("== 产品计数：cnt_load=%0d cnt_store=%0d cnt_fwd=%0d cnt_stall=%0d",
                 cnt_load_o, cnt_store_o, cnt_fwd_o, cnt_stq_stall_o);
        if (n_fail == 0) begin
            $display("== 检查项合计 %0d 项全部满足（转发形态/数据/异常/访存/闸门/槽回收/产品计数互锁）",
                     n_chk);
            $display("N12_MEMSTRESS_LSQ: PASS");
        end else begin
            $display("== 检查项 %0d 项中失败 %0d 项", n_chk, n_fail);
            $display("FAIL: N12_MEMSTRESS_LSQ 判据不满足");
            $fatal(1, "N12_MEMSTRESS_LSQ 失败");
        end
        $finish;
    end

    // 全局超时兜底（fail-closed；每场景 ~120 拍上限）
    initial begin
        #(10 * (200 + N_IT * N_SC * 400));
        $display("FAIL: N12_MEMSTRESS_LSQ 超时");
        $fatal(1, "N12_MEMSTRESS_LSQ 超时");
    end

endmodule
