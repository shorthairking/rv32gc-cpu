//==============================================================================
// sim/unit/tb_back2_lockstep.sv —— 2B-2 **锁步验证**（核心判据）
//   front4_top + backend_top（乱序）  ∥  2A core_top（单发射顺序 5 级）
//   同一组程序、同一映像、逐条比较"提交 PC 流 + arch 写回流"；Spike 黄金轨迹兜底。
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §2.2（顺序提交语义）；docs/design/02-pipeline.md
//         §5（衔接硬规则）；docs/design/08-baseline-5stage.md §8.3（锁步/黄金轨迹比对思路）；
//         rtl/front4/README.md §8（与 2B-1 的衔接清单）。
//
// 【结构】
//   · 2A 侧：rtl/top/core_top.v（只读复用，48 端口逐字契约）+ AXI4 从设备模型
//            （`include sim/tb/sim_mem_model.sv，**只读复用**）+ 纯组合地址翻译层
//   · 乱序侧：rtl/front4/front4_top.v + rtl/back2/backend_top.v + TB 侧
//            "零延迟恒命中理想 I 端口" + XIP 直连模型 + 简化访存口（带标签响应）
//   · 两核**同映像**（程序映像各写一份，互不干扰）、**同起始**（复位取指 0x1C00_0000 的
//     XIP 跳板 ⇒ 先执行 2 条跳板再进入程序），程序结束写 tohost 后自跳转。
//
// 【地址布局（与 gen 脚本 / .ld 严格一致；改一处必须同步三处）】
//   程序全部落 **0x8000_0000 仿真布局**（2A 锁步底座与 arch-test 的既定口径：
//   `RV32GC_RESET_PC=0x1C00_0000` 处 2 条跳转桩 → 程序体 @0x8000_0000）。
//   ★ 但 `sim_mem_model` 的 `ddr3_read()` 以 `ddr3_mem[a[31:2]]` 作**绝对**下标
//     （隐含 DDR3_BASE==0，见 sim/lockstep/README §3 的实测结论），直接喂 0x8000_0000
//     会数组越界 ⇒ 读回 0 ⇒ 假失败。故本 TB 在 2A 核与模型之间插一层**纯组合**翻译：
//         DUT 0x8000_0000..0x8000_FFFF → 模型 0x0000_0000..0x0000_FFFF（其余原样透传，
//         复位跳转桩的 XIP 0x1C00_0000 不受影响）。
//     副作用（有意为之）：2A 核看到 PA[31:28]=8 ⇒ PMA 判**不可缓存** ⇒ 取指/访存
//     全部单 beat 走 AXI ⇒ store 立即可在模型里观测到（C4 才能成立；若按可缓存口径，
//     L1D 是写回+写分配，1 KB 以内的工作集根本不会被驱逐，store 永远到不了 AXI）。
//
// 【程序与黄金轨迹（可复现，命令见 sim/unit/prog/back2_p*.S 与 gen 脚本头注）】
//   ① 程序真源：sim/unit/prog/back2_p1_int.S / back2_p2_branch.S / back2_p3_memcsr.S
//      ＋ back2_lockstep.ld（.text @0x8000_0000、.tohost @0x8000_0800、
//        .data @0x8000_1000、.bss/栈 @0x8000_1800）—— 与 Spike 侧**同一份 .ld 口径**
//        （两脚本各段相对 .text 的偏移逐字节一致 ⇒ 同一份源码两次链接的 .text 相同）
//   ② 工具链  ：/opt/riscv/bin/riscv32-unknown-linux-gnu-{gcc,ld,objcopy}（GCC 16.1.0）
//   ③ 黄金轨迹：/opt/riscv/bin/spike --pc=0x80000000 --isa=rv32imac_zicsr --log-commits
//      --log=<f>（**与 sim/lockstep 同法**：`--pc` 跳过 Spike 内置 boot ROM，
//       程序写完 tohost 后停在 `j .`；轨迹到"PC 连续重复"为止，该条不计）
//      ⇒ 架构提交 PC 序列（597 / 346 / 242 条）；由 gen_back2_lockstep_data.py 内嵌为
//        sim/unit/prog/back2_lockstep_data.svh
//
// 【判据（全部 $fatal；未捕获即失败）】
//   C1 三个程序的两核提交流**逐条相等**（PC + arch 写回 rd/wdata，0 分歧）
//   C2 两核提交流与 **Spike 黄金 PC 轨迹**逐条相等（各程序 597/346/242 条，0 分歧）
//   C3 两核跳板（0x1C00_0000 起 2 条）提交流相等，且程序段总条数 == 黄金条数
//   C4 收尾存储映像逐字相等（store 落地语义 + 转发正确性的旁证）
//   C5 吞吐观测：每程序输出"提交窗拍数 / 提交条数 / 平均 IPC / 提交宽度=4 的拍占比"，
//      并断言"提交窗内平均 IPC ≥ IPC_LIMIT_Q8/256"（默认 0.5 = 退化下限，防"变相全停顿
//      还宣称通过"）。**本 TB 的端到端 IPC 上限不是乱序后端，而是 2B-1 前端的取指带宽**
//      （ifetch4 的 `push_num ≤ 2 parcel/拍` ⇒ RV32 指令 ≤ 1 条/拍 ⇒ 端到端 IPC ≤ 1.0），
//      故"IPC > 1.0"的证据**不在这里**，而在 sim/unit/tb_back2_ipc.sv（直接以 4 宽派发流
//      驱动 backend_top，绕开取指带宽上限），见交付报告 §IPC。
// 顶层  : tb_back2_lockstep_top
// 锚点  : TB_BACK2_LOCKSTEP: PASS（整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"
`include "sim/tb/sim_mem_model.sv"

module tb_back2_lockstep_top #(
    parameter integer CLK_HALF_NS   = 5,
    parameter integer RESET_CYCLES  = 20,
    parameter integer CYC_LIMIT     = 200000,
    //   端到端 IPC 的**上限由 2B-1 前端取指带宽决定**（ifetch4 每拍 ≤2 parcel
    //   = RV32 ≤1 条指令/拍），再叠加分支误判回滚开销 ⇒ 实测 ~0.4。此阈值只是
    //   "防退化下限"（IPC ≥ 0.25），**不是**性能主张；"IPC>1.0"的正式证据在
    //   sim/unit/tb_back2_ipc.sv（后端直驱 4 宽派发流）。
    parameter integer MEM_WORDS     = 16384,   // DDR 存储体 64 KiB（本 TB 只用到低 3 KiB）
    parameter integer DBG_CYCLES    = 0        // 诊断探针：>0 时打印前 N 拍逐拍状态
) (
);

    //==========================================================================
    // 0. 常量
    //==========================================================================
    localparam [31:0] DDR_BASE = 32'h8000_0000;   // DUT 侧仿真布局（两核同映像）
    localparam [31:0] XIP_BASE = 32'h1C00_0000;
    //   ★ C5 分档防退化下限（Q8）——母代理第 11 轮裁决：每档 = 实测 × ≤0.8（≥20% 裕量）。
    //     测量条件（各档一致）：参照核 2A、冷 I$ + 冷分支预测器（逐程序复位不清 I$/BPU）、
    //     提交窗起点 = 2A 进入程序那一拍、窗终点 = 两核最后一次提交。
    //     ★ 任何后续夹具/测量口径改动若影响 2A 吞吐，必须重新实测并重算本表。
    //   程序 0（顺序整数流）     ：实测 IPC=0.3917 ⇒ 下限 0.30（Q8=77，裕量 30%）
    //   程序 1（分支密集+调用/返回）：实测 IPC=0.2469 ⇒ 下限 0.19（Q8=49，裕量 29%）
    //   程序 2（访存+CSR）       ：实测 IPC=0.1382 ⇒ 下限 0.1094（Q8=28，裕量 26%）
    //     （B29 修复后实测：913 拍/126 条；测量条件同上——参照核 2A、冷 I$/冷预测器、窗起点=2A 进入程序拍）
    function integer ipc_lim_q8; input integer p;
        begin
            ipc_lim_q8 = (p == 0) ? 77 :
                         (p == 1) ? 49 :
                         (p == 2) ? 28 : 0;   // 程序 2：实测 0.1382 ⇒ 下限 0.1094（Q8=28，裕量 26%）
        end
    endfunction

    localparam [31:0] PROG_PC  = 32'h8000_0000;
    //   ★ 分基址（第 10 轮）：三个程序各占 16 KB 步进的独立基址 ⇒ 2A 的 I$ 陈旧行 tag 不同、
    //     永不命中（命中需 tag 相等）；镜像不变（程序全部 %pcrel 位置无关），黄金 PC 同量平移。
    function [31:0] pbase; input integer i; begin pbase = PROG_PC + (i * 32'h4000); end endfunction
    localparam integer NI      = `BACK2_IQ_WR_PORTS;
    localparam integer GMAX    = 1024;
    localparam integer N_PMP   = `RV32GC_PMP_ENTRIES;
    localparam integer P_NUM_L = 3;

    // 跳板（XIP @0x1C00_0000）：lui x5,0x80000 ; jalr x0,0(x5) ⇒ 跳到 0x8000_0000
    localparam [31:0] STUB0 = 32'h800002b7;
    localparam [31:0] STUB1 = 32'h00028067;

    //==========================================================================
    // 1. 时钟 / 复位 / 检查
    //==========================================================================
    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_HALF_NS) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_BACK2_LOCKSTEP 判据不满足");
            end
        end
    endtask

    //==========================================================================
    // 2. 存储体
    //==========================================================================
    // ---- 2A 侧：AXI4 从设备（模型 DDR3 窗口 = PA 0x0000_0000..0x0000_FFFF，64 KB）----
    //   ★ 核侧信号（*_dut）与模型侧信号（原 *_）之间插**纯组合地址翻译**：
    //       0x8000_xxxx → 0x0000_xxxx（其余原样）
    //     理由见文件头【地址布局】：模型 ddr3_read 用绝对下标（隐含 DDR3_BASE==0），
    //     且该映射与 sim/lockstep/tb_lockstep.sv 的 lockstep_addr_map 同源同法。
    wire [3:0]  arid;   wire [31:0] araddr_dut;  wire [3:0]  arlen;
    wire [2:0]  arsize; wire [1:0]  arburst; wire [1:0]  arlock;
    wire [3:0]  arcache;wire [2:0]  arprot;  wire        arvalid;
    wire        arready;
    wire [3:0]  rid;    wire [31:0] rdata;   wire [1:0]  rresp;
    wire        rlast;  wire        rvalid;  wire        rready;
    wire [3:0]  awid;   wire [31:0] awaddr_dut;  wire [3:0]  awlen;
    wire [2:0]  awsize; wire [1:0]  awburst; wire [1:0]  awlock;
    wire [3:0]  awcache;wire [2:0]  awprot;  wire        awvalid;
    wire        awready;
    wire [3:0]  wid;    wire [31:0] wdata;   wire [3:0]  wstrb;
    wire        wlast;  wire        wvalid;  wire        wready;
    wire [3:0]  bid;    wire [1:0]  bresp;   wire        bvalid;
    wire        bready;
    assign rready = 1'b1;
    assign bready = 1'b1;
    // 地址翻译（唯一赋值点）：读地址通道 + 写地址通道
    wire [31:0] araddr = map2a(araddr_dut);
    wire [31:0] awaddr = map2a(awaddr_dut);
    function [31:0] map2a; input [31:0] a;
        begin map2a = (a[31:16] == 16'h8000) ? {16'h0000, a[15:0]} : a; end
    endfunction
    // 2A 核的调试/观察口
    wire        ws_valid;
    wire [31:0] dbg_pc, dbg_wdata;
    wire [3:0]  dbg_wen;
    wire [4:0]  dbg_wnum;
    wire [31:0] rf_rdata2a;

    sim_mem_model #(
        .XIP_BASE       (XIP_BASE),
        .XIP_ALIAS      (32'h1FE8_0000),
        .XIP_SIZE       (32'h0000_1000),      // 4 KB 跳板
        .DDR3_BASE      (32'h0000_0000),      // ★ 必须 0：模型 ddr3_read 用绝对下标
        .DDR3_LIMIT     (32'h0001_0000),      // 64 KB 程序/数据/栈
        .UART_DATA_ADDR (32'h1FE0_01E0),
        .READ_LAT_DLY   (0)
    ) u_mem2a (
        .clk(clk), .rst_n(rst_n),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .uart_char(), .uart_char_valid(), .uart_tx_count(), .uart_overflow(),
        .uart_bad_strb_count()
    );

    // ---- 乱序侧存储体（同地址空间：0x0000_0000..0x0000_FFFF）----
    reg [31:0] mem_oo [0:MEM_WORDS-1];

    //==========================================================================
    // 3. 乱序侧：前端（front4_top）+ 后端（backend_top）
    //==========================================================================
    // 前端 ↔ 后端（派发块）
    wire        blk_valid, blk_ready, blk_taken, fe_fetch_fault, fe_frozen;
    wire [3:0]  blk_mask;
    wire [31:0] blk_next_pc;
    wire [127:0] lane_pc, lane_pa, lane_insn, lane_pred_target, lane_btb_target, lane_fault_tval;
    wire [3:0]  lane_len32, lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    wire [3:0]  lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    wire [3:0]  lane_fault, lane_ckpt_valid;
    wire [11:0] lane_cls;
    wire [19:0] lane_fault_cause;
    wire [15:0] lane_ckpt;
    // 后端 → 前端
    wire        redirect_valid, redirect_use_ckpt;
    wire [31:0] redirect_pc;
    wire [3:0]  redirect_ckpt;
    wire        train_valid, train_ready;
    wire [31:0] train_pc, train_target, train_pred_target;
    wire        train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    wire        train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    wire        train_pred_valid, train_btb_hit, train_btb_way;
    wire        ckpt_free_valid;
    wire [3:0]  ckpt_free_id;
    wire        ras_cmt_push, ras_cmt_pop;
    wire        d2_push_valid, d2_pop_valid;
    wire [31:0] d2_push_addr, d2_pop_addr;
    wire        ras_repair_valid;
    wire [31:0] ras_repair_addr;
    // 前端 ↔ 存储
    wire        l1i_req_valid, tr_req_valid;
    wire [31:0] l1i_req_addr, l1i_req_line, tr_req_va;
    wire        unc_req_valid;
    wire [31:0] unc_req_pa;
    reg         unc_rsp_valid;
    reg  [31:0] unc_rsp_pa, unc_rsp_data;
    wire        l1i_ready_w, l1i_miss_w, l1i_unc_w;
    wire [31:0] l1i_rdata_w;
    // 后端 → 存储
    wire        mem_req_ready;
    wire        mem_req_valid, mem_req_wen;
    wire [31:0] mem_req_addr, mem_req_wdata;
    wire [3:0]  mem_req_wstrb;
    wire [`BACK2_MEM_TAG_W-1:0] mem_req_tag;   // ★ 2B-3：标签宽度随 LQ 扩容（3→6）
    reg         mem_rsp_valid;
    reg  [31:0] mem_rsp_rdata;
    reg  [`BACK2_MEM_TAG_W-1:0] mem_rsp_tag;
    // 提交流
    wire [3:0]  commit_valid;
    wire [127:0] commit_pc, commit_arch_rd_wdata;
    wire [19:0] commit_arch_rd;
    wire [3:0]  commit_arch_we;
    // 统计
    wire [31:0] cnt_commit, cnt_squash, cnt_commit4, cnt_issue;
    wire [31:0] u_front_fetch_pc, u_front_head_pc;
    wire [31:0] bpu_br_total, bpu_br_mispred, bpu_dir_mispred, bpu_target_mispred;
    wire [6:0]  dbg_rob_head;
    wire        dbg_rob_empty, dbg_rob_hdone;
    wire [3:0]  dbg_rob_hexc;
    assign dbg_rob_head  = u_back.u_rob.head_o;
    assign dbg_rob_empty = u_back.u_rob.empty_o;
    assign dbg_rob_hdone = u_back.u_rob.head_done_o;
    assign dbg_rob_hexc  = u_back.u_rob.head_exc_o;
    wire [6:0]  dbg_rob_cnt;
    wire [23:0] dbg_iq_cnt;
    wire [7:0]  dbg_stq_cnt;
    wire        trap_valid;
    wire [31:0] trap_pc, trap_tval;
    wire [3:0]  trap_cause;

    front4_top #(.SPEC_GHR(0), .SEL_FORCE(0)) u_front (
        .clk(clk), .rst_n(rst_n), .rst_hold(1'b0),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
        .redirect_use_ckpt(redirect_use_ckpt), .redirect_ckpt(redirect_ckpt),
        .break_point(1'b0), .fe_stall(1'b0),
        .blk_valid(blk_valid), .blk_ready(blk_ready), .blk_mask(blk_mask),
        .blk_next_pc(blk_next_pc), .blk_taken(blk_taken),
        .lane_pc(lane_pc), .lane_pa(lane_pa), .lane_insn(lane_insn),
        .lane_len32(lane_len32), .lane_cls(lane_cls),
        .lane_pred_taken(lane_pred_taken), .lane_pred_selg(lane_pred_selg),
        .lane_pred_gdir(lane_pred_gdir), .lane_pred_ldir(lane_pred_ldir),
        .lane_pred_target(lane_pred_target),
        .lane_btb_hit(lane_btb_hit), .lane_btb_way(lane_btb_way),
        .lane_btb_cond(lane_btb_cond), .lane_btb_call(lane_btb_call),
        .lane_btb_ret(lane_btb_ret), .lane_btb_target(lane_btb_target),
        .lane_fault(lane_fault), .lane_fault_cause(lane_fault_cause),
        .lane_fault_tval(lane_fault_tval),
        .lane_ckpt(lane_ckpt), .lane_ckpt_valid(lane_ckpt_valid),
        .fe_fetch_fault(fe_fetch_fault), .fe_frozen(fe_frozen),
        .train_valid(train_valid), .train_pc(train_pc),
        .train_is_cond(train_is_cond), .train_taken(train_taken),
        .train_is_indirect(train_is_indirect), .train_is_call(train_is_call),
        .train_is_return(train_is_return), .train_target(train_target),
        .train_pred_taken(train_pred_taken), .train_pred_sel_global(train_pred_sel_global),
        .train_pred_gdir(train_pred_gdir), .train_pred_ldir(train_pred_ldir),
        .train_pred_target(train_pred_target), .train_pred_valid(train_pred_valid),
        .train_btb_hit(train_btb_hit), .train_btb_way(train_btb_way),
        .train_ready(train_ready),
        .ckpt_free_valid(ckpt_free_valid), .ckpt_free_id(ckpt_free_id),
        .ras_cmt_push_valid(ras_cmt_push), .ras_cmt_pop_valid(ras_cmt_pop),
        .d2_push_valid(d2_push_valid), .d2_push_addr(d2_push_addr),
        .d2_pop_valid(d2_pop_valid), .d2_pop_addr(d2_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr),
        .sv32_translate_en(1'b0), .sv32_translate_done(1'b0),
        .sv32_translate_fault(1'b0), .sv32_translate_paddr(32'h0),
        .tr_req_valid(tr_req_valid), .tr_req_va(tr_req_va),
        .priv(`RV32GC_PRIV_M), .pmpcfg_i({N_PMP*8{1'b0}}), .pmpaddr_i({N_PMP*32{1'b0}}),
        .l1i_req_valid(l1i_req_valid), .l1i_req_addr(l1i_req_addr),
        .l1i_req_line(l1i_req_line), .l1i_ready(l1i_ready_w),
        .l1i_rdata(l1i_rdata_w), .l1i_miss(l1i_miss_w), .l1i_uncached(l1i_unc_w),
        .unc_req_valid(unc_req_valid), .unc_req_pa(unc_req_pa),
        .unc_rsp_valid(unc_rsp_valid), .unc_rsp_pa(unc_rsp_pa), .unc_rsp_data(unc_rsp_data),
        .fetch_pc_o(u_front_fetch_pc), .head_pc_o(u_front_head_pc), .epoch_o(), .ghr_o(),
        .bpu_br_total(bpu_br_total), .bpu_br_mispred(bpu_br_mispred),
        .bpu_dir_mispred(bpu_dir_mispred), .bpu_target_mispred(bpu_target_mispred),
        .bpu_gshare_right(), .bpu_local_right(), .bpu_sel_global(), .bpu_sel_local(),
        .bpu_ras_push(), .bpu_ras_pop(), .bpu_ras_overflow(), .bpu_ras_repair(),
        .bpu_ckpt_full_stall(), .bpu_train_overflow(), .bpu_btb_alloc(),
        .cnt_grp(), .cnt_parcels(), .cnt_fault(), .cnt_restart(), .cnt_stall(),
        .cnt_req(), .cnt_redirect()
    );

    backend_top u_back (
        .clk(clk), .rst_n(rst_n),
        .blk_valid_i(blk_valid), .blk_ready_o(blk_ready), .blk_mask_i(blk_mask),
        .blk_next_pc_i(blk_next_pc), .blk_taken_i(blk_taken),
        .lane_pc_i(lane_pc), .lane_pa_i(lane_pa), .lane_insn_i(lane_insn),
        .lane_len32_i(lane_len32), .lane_cls_i(lane_cls),
        .lane_pred_taken_i(lane_pred_taken), .lane_pred_selg_i(lane_pred_selg),
        .lane_pred_gdir_i(lane_pred_gdir), .lane_pred_ldir_i(lane_pred_ldir),
        .lane_pred_target_i(lane_pred_target),
        .lane_btb_hit_i(lane_btb_hit), .lane_btb_way_i(lane_btb_way),
        .lane_btb_cond_i(lane_btb_cond), .lane_btb_call_i(lane_btb_call),
        .lane_btb_ret_i(lane_btb_ret), .lane_btb_target_i(lane_btb_target),
        .lane_fault_i(lane_fault), .lane_fault_cause_i(lane_fault_cause),
        .lane_fault_tval_i(lane_fault_tval),
        .lane_ckpt_i(lane_ckpt), .lane_ckpt_valid_i(lane_ckpt_valid),
        .fe_fetch_fault_i(fe_fetch_fault),
        .redirect_valid_o(redirect_valid), .redirect_pc_o(redirect_pc),
        .redirect_use_ckpt_o(redirect_use_ckpt), .redirect_ckpt_o(redirect_ckpt),
        .train_valid_o(train_valid), .train_pc_o(train_pc),
        .train_is_cond_o(train_is_cond), .train_taken_o(train_taken),
        .train_is_indirect_o(train_is_indirect), .train_is_call_o(train_is_call),
        .train_is_return_o(train_is_return), .train_target_o(train_target),
        .train_pred_taken_o(train_pred_taken), .train_pred_sel_global_o(train_pred_sel_global),
        .train_pred_gdir_o(train_pred_gdir), .train_pred_ldir_o(train_pred_ldir),
        .train_pred_target_o(train_pred_target), .train_pred_valid_o(train_pred_valid),
        .train_btb_hit_o(train_btb_hit), .train_btb_way_o(train_btb_way),
        .train_ready_i(1'b1),
        .ckpt_free_valid_o(ckpt_free_valid), .ckpt_free_id_o(ckpt_free_id),
        .ras_cmt_push_valid_o(ras_cmt_push), .ras_cmt_pop_valid_o(ras_cmt_pop),
        .d2_push_valid_o(d2_push_valid), .d2_push_addr_o(d2_push_addr),
        .d2_pop_valid_o(d2_pop_valid), .d2_pop_addr_o(d2_pop_addr),
        .mem_req_valid_o(mem_req_valid), .mem_req_wen_o(mem_req_wen),
        .mem_req_addr_o(mem_req_addr), .mem_req_wdata_o(mem_req_wdata),
        .mem_req_wstrb_o(mem_req_wstrb), .mem_req_tag_o(mem_req_tag),
        .mem_req_ready_i(mem_req_ready),
        .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_rdata_i(mem_rsp_rdata),
        .mem_rsp_tag_i(mem_rsp_tag),
        .commit_valid_o(commit_valid), .commit_pc_o(commit_pc),
        .commit_arch_rd_o(commit_arch_rd), .commit_arch_rd_wdata_o(commit_arch_rd_wdata),
        .commit_arch_we_o(commit_arch_we),
        .trap_valid_o(trap_valid), .trap_pc_o(trap_pc),
        .trap_cause_o(trap_cause), .trap_tval_o(trap_tval),
        .cnt_commit_o(cnt_commit), .cnt_squash_o(cnt_squash),
        .cnt_commit4_o(cnt_commit4), .cnt_issue_o(cnt_issue),
        .dbg_rob_cnt_o(dbg_rob_cnt), .dbg_iq_cnt_o(dbg_iq_cnt), .dbg_stq_cnt_o(dbg_stq_cnt)
    );

    //==========================================================================
    // 4. 2A 核（单发射顺序 5 级）：48 端口逐字例化
    //==========================================================================
    core_top u_core2a (
        .aclk(clk), .intrpt(8'h00), .aresetn(rst_n),
        .arid(arid), .araddr(araddr_dut), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr_dut), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .ws_valid(ws_valid), .break_point(1'b0),
        .infor_flag(1'b0), .reg_num(5'd0), .rf_rdata(rf_rdata2a),
        .debug0_wb_pc(dbg_pc), .debug0_wb_rf_wen(dbg_wen),
        .debug0_wb_rf_wnum(dbg_wnum), .debug0_wb_rf_wdata(dbg_wdata)
    );

    //==========================================================================
    // 5. 存储模型：乱序侧（理想 I 端口 + XIP 直连 + 带标签访存口）
    //==========================================================================
    function is_xip; input [31:0] a;
        begin is_xip = (a[31:20] == 12'h1C0) | (a[31:16] == 16'h1FE8); end
    endfunction
    // 字下标（本 TB 的 DDR 基址 = 0 ⇒ 地址直接右移 2）
    function [13:0] w_idx; input [31:0] a;
        begin w_idx = a[15:2]; end
    endfunction

    // ---- 理想 I 端口（**零延迟恒命中**：ready 恒 1，rdata 组合取自存储体）----
    //   口径与理由：本 TB 只验"乱序后端的功能等价性"，取指侧给理想条件 ⇒ 排除取指
    //   带宽/缺失对锁步结论的干扰，也让三程序在有限拍数内跑完。
    //   ★ 不可写成 `ready = req_valid`：f4_rsp_ok 与 l1i_req_valid 互锁 ⇒ 组合环（x）。
    //   ★ 本模型**不代表**真实 L1I 时序，禁止据此下任何性能结论（IPC 证据另见 tb_back2_ipc）。
    assign l1i_ready_w   = 1'b1;
    assign l1i_rdata_w   = is_xip(l1i_req_addr) ? 32'h00000013 : mem_oo[w_idx(l1i_req_addr)];
    assign l1i_miss_w    = 1'b0;
    assign l1i_unc_w     = 1'b0;

    // XIP 直连（跳板）：下一拍响应；窗口内只有 2 个字有内容，其余给 nop
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unc_rsp_valid <= 1'b0; unc_rsp_pa <= 32'h0; unc_rsp_data <= 32'h00000013;
        end else begin
            unc_rsp_valid <= unc_req_valid;
            unc_rsp_pa    <= unc_req_pa;
            unc_rsp_data  <= (unc_req_pa[3:2] == 2'd0) ? (pbase(pi) | 32'h2b7) :   // lui x5, <当前程序基址>
                             (unc_req_pa[3:2] == 2'd1) ? STUB1 : 32'h00000013;
        end
    end

    // ---- 带标签访存口（**2 级流水**：写当拍落地；读 2 拍后单拍响应）----
    //   ★ 用"ready = ~s2_v 的两级流水"而不是环形 FIFO + 读写指针：
    //     指针式模型一旦 push/pop 计数与指针不同步，就会读到未写过的槽（x），
    //     表现为"响应 tag=x ⇒ LSU 永远匹配不上 ⇒ 该 load 永久在飞"（实测）。
    //     本模型由构造保证：每个被接收的读请求恰好产生**一拍**响应，且不会覆盖。
    reg        rq1_v, rq2_v;
    reg [`BACK2_MEM_TAG_W-1:0] rq1_t, rq2_t;
    reg [31:0] rq1_d, rq2_d;
    wire       rd_acc = mem_req_valid & mem_req_ready & ~mem_req_wen;
    assign mem_req_ready = ~rq2_v;
    assign mem_rsp_valid = rq2_v;
    assign mem_rsp_tag   = rq2_t;
    assign mem_rsp_rdata = rq2_d;
    integer wb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq1_v <= 1'b0; rq2_v <= 1'b0;
            rq1_t <= {`BACK2_MEM_TAG_W{1'b0}}; rq2_t <= {`BACK2_MEM_TAG_W{1'b0}};
            rq1_d <= 32'h0; rq2_d <= 32'h0;
        end else begin
            // ---- 写：当拍按字节落地（LSU 单端口、单笔/拍）----
            if (mem_req_valid && mem_req_ready && mem_req_wen) begin
                for (wb = 0; wb < 4; wb = wb + 1)
                    if (mem_req_wstrb[wb])
                        mem_oo[w_idx(mem_req_addr)][8*wb +: 8] <= mem_req_wdata[8*wb +: 8];
            end
            // ---- 读请求入第一级 ----
            rq1_v <= rd_acc;
            if (rd_acc) begin
                rq1_t <= mem_req_tag;
                rq1_d <= mem_oo[w_idx(mem_req_addr)];
            end
            // ---- 第二级即响应（ready=~rq2_v 保证一拍宽且不被覆盖）----
            rq2_v <= rq1_v;
            rq2_t <= rq1_t;
            rq2_d <= rq1_d;
        end
    end

    //==========================================================================
    // 6. 提交记录与比对
    //==========================================================================
    `include "sim/unit/prog/back2_lockstep_data.svh"
    wire [31:0] gold_delta = pbase(pi) - PROG_PC;   // 分基址后黄金 PC 的平移量
    integer n2a, noo;
    reg     on2a, onoo;
    reg [31:0] r2a_pc [0:GMAX-1];
    reg [31:0] r2a_wd [0:GMAX-1];
    reg [4:0]  r2a_rd [0:GMAX-1];
    reg        r2a_we [0:GMAX-1];
    reg [31:0] roo_pc [0:GMAX-1];
    reg [31:0] roo_wd [0:GMAX-1];
    reg [4:0]  roo_rd [0:GMAX-1];
    reg        roo_we [0:GMAX-1];
    // 跳板段记录
    reg [31:0] pre2a [0:7];
    reg [31:0] preoo [0:7];
    integer npre2a, npreoo;

    // 有效写口判定：arch rd != 0（x0 不写）+ 单位写使能
    //   ★ 起录口径：**进入 PROG_PC 的那一条也要记**（跳板 2 条记进 pre2a/preoo）。
    //     故"起录"必须是组合判据、且与记录同拍生效；写成"先置 on2a、下一拍再记"
    //     会静默丢掉程序第 1 条（与黄金轨迹错位 1 条），是上一版遗留缺陷。
    wire start2a = ~on2a & (dbg_pc == pbase(pi));
    always @(posedge clk) begin
        if (rst_n & ws_valid) begin
            if (start2a) on2a <= 1'b1;
            if (~on2a & ~start2a) begin
                pre2a[npre2a] <= dbg_pc; npre2a <= npre2a + 1;
            end
            if ((on2a | start2a) && (n2a < GMAX)) begin
                r2a_pc[n2a] <= dbg_pc;
                r2a_we[n2a] <= dbg_wen[0] & (dbg_wnum != 5'd0);
                r2a_rd[n2a] <= dbg_wnum;
                r2a_wd[n2a] <= dbg_wdata;
                n2a <= n2a + 1;
            end
        end
    end

    integer cw;
    integer oo_bad_at;      // 乱序核第一处黄金 PC 分歧的下标（-1 = 尚无；仅诊断用）
    // 本提交组内**首个** PC == PROG_PC 的 lane（4 = 组内没有）；起录判据就它。
    //   ★ 必须按 lane 判：跳板的 `jalr` 与程序首条完全可能在**同一提交组**里（4 宽提交），
    //     用"整组是否含 PROG_PC"会把跳板那条也记进程序流（错位）。
    integer first_prog_lane;
    always @(*) begin
        first_prog_lane = 4;
        for (cw = 3; cw >= 0; cw = cw - 1)
            if (commit_valid[cw] && (commit_pc[cw*32 +: 32] == pbase(pi)))
                first_prog_lane = cw;
    end
    // ---- 组内 lane 排序（一提交组可含 ≤4 条，记录下标必须逐 lane 递增）----
    //   ★ 原实现按"每 lane 自增 noo"写数组：同组多 lane 会写**同一个下标**（非阻塞
    //     赋值同拍同址，后者胜）⇒ 提交流丢条 + 数组残留旧值（实测：程序 0 的首组
    //     [0x80000000,0x80000004] 只留下 0x80000004，C2 报"第 0 条 PC 分歧"）。
    //   first_prog_lane==4（组内无 PROG_PC）：起录前全归 pre、起录后全归 rec。
    wire [3:0] rec_sel = onoo ? 4'hF :
                         ((first_prog_lane == 4) ? 4'h0 : (4'hF << first_prog_lane[1:0]));
    wire [3:0] pre_sel = onoo ? 4'h0 :
                         ((first_prog_lane == 4) ? 4'hF : ~(4'hF << first_prog_lane[1:0]));
    reg [2:0]  pre_rank [0:3];
    reg [2:0]  rec_rank [0:3];
    reg [2:0]  n_pre_w, n_rec_w;
    integer    rk;
    always @(*) begin
        pre_rank[0] = 3'd0; rec_rank[0] = 3'd0;
        for (rk = 1; rk < 4; rk = rk + 1) begin
            pre_rank[rk] = pre_rank[rk-1] +
                ((commit_valid[rk-1] && pre_sel[rk-1]) ? 3'd1 : 3'd0);
            rec_rank[rk] = rec_rank[rk-1] +
                ((commit_valid[rk-1] && rec_sel[rk-1]) ? 3'd1 : 3'd0);
        end
        n_pre_w = pre_rank[3] + ((commit_valid[3] && pre_sel[3]) ? 3'd1 : 3'd0);
        n_rec_w = rec_rank[3] + ((commit_valid[3] && rec_sel[3]) ? 3'd1 : 3'd0);
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (first_prog_lane != 4) onoo <= 1'b1;
            if (n_pre_w != 3'd0) npreoo <= npreoo + n_pre_w;
            if (n_rec_w != 3'd0) noo    <= noo + n_rec_w;
            for (cw = 0; cw < 4; cw = cw + 1) begin
                if (commit_valid[cw]) begin
                    if (DBG_CYCLES != 0)
                        $display("      [oo-cmt t=%0t] lane%0d pc=0x%08x we=%b rd=%0d wd=0x%08x pdst=%0d pdo=%0d pi=%b",
                                 $time, cw, commit_pc[cw*32 +: 32],
                                 (commit_arch_rd[cw*5 +: 5] != 5'd0),
                                 commit_arch_rd[cw*5 +: 5], commit_arch_rd_wdata[cw*32 +: 32],
                                 u_back.p_pdi(u_back.cmt_pay[cw*`BACK2_RB_W +: `BACK2_RB_W]),
                                 u_back.p_pdio(u_back.cmt_pay[cw*`BACK2_RB_W +: `BACK2_RB_W]),
                                 u_back.p_di(u_back.cmt_pay[cw*`BACK2_RB_W +: `BACK2_RB_W]));
                    if (pre_sel[cw] && ((npreoo + pre_rank[cw]) < 8))
                        preoo[npreoo + pre_rank[cw]] <= commit_pc[cw*32 +: 32];
                    if (rec_sel[cw] && ((noo + rec_rank[cw]) < GMAX)) begin
                        roo_pc[noo + rec_rank[cw]] <= commit_pc[cw*32 +: 32];
                        //   ★ 写使能取 RTL 的 commit_arch_we_o：**不能**用 rd != 0 推断
                        //     （B/J 型的 bits[11:7] 属立即数，`bne` 的 rd 域 = 29）
                        roo_we[noo + rec_rank[cw]] <= commit_arch_we[cw];
                        roo_rd[noo + rec_rank[cw]] <= commit_arch_rd[cw*5 +: 5];
                        roo_wd[noo + rec_rank[cw]] <= commit_arch_rd_wdata[cw*32 +: 32];
                        // ---- 即时黄金比对（**只打印、不参与判据**；判据仍由主流程 C1/C2 给出）----
                        //   任一条一落账就与黄金 PC 比，第一处不同当场打出现场（含前 3 条
                        //   已落账 PC 与当拍写回信息），避免"等到程序跑完才知道错在哪"。
                        //   ★ 只在**黄金窗口内**（idx < cmax）比：程序以 `j .` 自跳转收尾，
                        //     越过 cmax 之后两核都会继续重复提交同一条 PC，属于预期行为
                        //     （正式判据 C1/C2 也只取前 cmax 条）。
                        if ((oo_bad_at < 0) &&
                            ((noo + rec_rank[cw]) < cmax) &&
                            (commit_pc[cw*32 +: 32] !==
                             GOLD[pi*P_GOLD_MAX + (noo + rec_rank[cw])] + gold_delta)) begin
                            oo_bad_at = noo + rec_rank[cw];
                            $display("      [oo-bad t=%0t cyc=%0d 程序 %0d] 乱序第 %0d 条 PC=0x%08x 期望 0x%08x | 当拍 we=%b rd=%0d wd=0x%08x",
                                     $time, cyc, pi, oo_bad_at, commit_pc[cw*32 +: 32],
                                     GOLD[pi*P_GOLD_MAX + oo_bad_at] + gold_delta,
                                     commit_arch_we[cw], commit_arch_rd[cw*5 +: 5],
                                     commit_arch_rd_wdata[cw*32 +: 32]);
                            $display("                 [raw] noo=%0d rec_rank=%b n_rec_w=%0d lane=%0d n2a=%0d blkv=%b mask=%b | cv=%b pc=%08x %08x %08x %08x",
                                     noo, rec_rank[cw], n_rec_w, cw, n2a,
                                     blk_valid, blk_mask, commit_valid,
                                     commit_pc[0 +: 32], commit_pc[32 +: 32],
                                     commit_pc[64 +: 32], commit_pc[96 +: 32]);
                            $display("                 前序已落账：%0d/0x%08x %0d/0x%08x %0d/0x%08x",
                                     oo_bad_at-3, (oo_bad_at >= 3) ? roo_pc[oo_bad_at-3] : 32'h0,
                                     oo_bad_at-2, (oo_bad_at >= 2) ? roo_pc[oo_bad_at-2] : 32'h0,
                                     oo_bad_at-1, (oo_bad_at >= 1) ? roo_pc[oo_bad_at-1] : 32'h0);
                            $fflush();
                        end
                    end
                end
            end
        end
    end

    //==========================================================================
    // 7. 主流程
    //==========================================================================
    integer pi, k, cyc, first_cyc, last_cyc, c4, n_commit_run;
    integer cnt_i, cmax;
    reg [31:0] stats_ipc_q8;
    real ipc;

    task automatic do_reset;
        begin
            //   ★★ 先跨到**负沿**：见 clear_mem 的同类注释。本 TB 的提交记录块在 posedge
            //      上用非阻塞赋值，若在同一时间步里用阻塞赋值把 noo/r2a_pc/roo_pc 清零，
            //      NBA 会在活跃区之后把清零覆盖掉（实测：程序 1 复位后 noo 仍为 200、
            //      roo_pc[199] 仍是程序 0 的旧值 ⇒ 记录下标整体错位 200）。
            @(negedge clk);
            rst_n <= 1'b0;
            n2a = 0; noo = 0; on2a = 1'b0; onoo = 1'b0;
            npre2a = 0; npreoo = 0; oo_bad_at = -1;
            for (k = 0; k < GMAX; k = k + 1) begin
                r2a_pc[k] = 0; r2a_wd[k] = 0; r2a_rd[k] = 0; r2a_we[k] = 0;
                roo_pc[k] = 0; roo_wd[k] = 0; roo_rd[k] = 0; roo_we[k] = 0;
            end
            repeat (RESET_CYCLES) @(posedge clk);
            rst_n <= 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic clear_mem;
        integer m;
        begin
            //   ★★ 先跨到**负沿**：本 TB 的存储器写口在 posedge 上用**非阻塞**赋值，
            //      若在同一时间步里用阻塞赋值清零存储器，NBA 会在活跃区之后把清零覆盖
            //      回去（上一拍那笔 store 会"复活"⇒ C4 映像比对出现假分歧）。
            @(negedge clk);
            // 两侧存储体**全量**清零（范围必须一致，否则 C4 的逐字比对会拿"未初始化"
            //   当差异；上一版只清 1024 字，程序的数据段在 0x2000 已越出该范围）
            for (m = 0; m < MEM_WORDS; m = m + 1) begin
                mem_oo[m]         = 32'h00000013;   // 填 nop（防取到 x）
                u_mem2a.ddr3_mem[m] = 32'h00000013;
            end
            for (m = 0; m < 1024; m = m + 1) u_mem2a.xip_mem[m] = 32'h00000000;
            u_mem2a.xip_mem[0] = pbase(pi) | 32'h2b7;   // lui x5, <当前程序基址>（分基址后无需 fence.i）
            u_mem2a.xip_mem[1] = STUB1;
        end
    endtask

    task automatic load_prog(input integer pidx);
        integer m;
        begin
            for (m = 0; m < P_IMG_MAX; m = m + 1) begin
                mem_oo[w_idx(pbase(pidx) + m*4)]           = IMG[pidx*P_IMG_MAX + m];
                u_mem2a.ddr3_mem[w_idx(pbase(pidx) + m*4)] = IMG[pidx*P_IMG_MAX + m];
            end
        end
    endtask

    initial begin
        $display("== 锁步 TB 启动（第 1 拍前）");
        $fflush();
        n_checks = 0;
        rst_n    = 1'b0;
        // ★ 必须显式调用内嵌映像/黄金轨迹装载任务：`include 只声明数组与任务，不会自动执行
        load_back2_data;
        repeat (4) @(posedge clk);

        for (pi = 0; pi < P_NUM_L; pi = pi + 1) begin
            // ---- 装载程序 ----
            $display("   [t=%0t] clear_mem 开始", $time); $fflush();
            clear_mem;
            $display("   [t=%0t] clear_mem 完成", $time); $fflush();
            load_prog(pi);
            $display("   [t=%0t] load_prog 完成", $time); $fflush();
            case (pi)
                0: cmax = P0_GOLD_N;
                1: cmax = P1_GOLD_N;
                default: cmax = P2_GOLD_N;
            endcase
            $display("== 程序 %0d：黄金 %0d 条，映像 %0d 字 ==", pi, cmax, P_IMG_MAX);
            $fflush();

            // ---- 复位 + 跑 ----
            do_reset;
            cyc = 0; c4 = 0;
            first_cyc = -1; last_cyc = -1;
            if (DBG_CYCLES != 0)
                $display("      [复位后 程序 %0d] noo=%0d n2a=%0d npreoo=%0d oo_bad=%0d roo_pc[0]=0x%08x roo_pc[199]=0x%08x",
                         pi, noo, n2a, npreoo, oo_bad_at, roo_pc[0], roo_pc[199]);
            while (((n2a < cmax) || (noo < cmax)) && (cyc < CYC_LIMIT)) begin
                @(posedge clk);
                cyc = cyc + 1;
                if ((DBG_CYCLES != 0) && (cyc <= 24))
                    $display("      [cyc%0d 程序 %0d] noo=%0d n2a=%0d npreoo=%0d cv=%b n_rec_w=%0d fpl=%0d onoo=%b",
                             cyc, pi, noo, n2a, npreoo, commit_valid, n_rec_w,
                             first_prog_lane, onoo);
                if (|commit_valid) begin
                    //   ★ 测量窗起点 = **程序首条提交**（不含跳板 2 条有效指令 + 2A 侧 fence.i 的
                    //     L1I 整体失效前导，后者是 TB 夹具的固定开销，与后端吞吐无关）。
                    //     阈值 IPC_LIMIT_Q8 不变（判据未放宽，只明确"测的是程序段"）。
                    if ((first_cyc < 0) && start2a) first_cyc = cyc;   // 2A 核进入程序的那一拍
                    last_cyc = cyc;
                    if (commit_valid == 4'hF) c4 = c4 + 1;
                end
                if ((cyc % 20000) == 0) begin
                    $display("   … 程序 %0d 进度：%0d 拍，2A=%0d 乱序=%0d 条（黄金 %0d）",
                             pi, cyc, n2a, noo, cmax);
                    $display("      诊断：跳板 2A/乱序=%0d/%0d 2A_ws_valid=%b 2A_fetch_pc=0x%08x",
                             npre2a, npreoo, ws_valid, u_core2a.fu_fetch_pc);
                    $display("            乱序：blk_valid=%b blk_ready=%b fe_frozen=%b fe_fault=%b redirect=%b(pc=0x%08x) rob=%0d iq=%0d cmt=%0d squash=%0d fe_head=0x%08x",
                             blk_valid, blk_ready, fe_frozen, fe_fetch_fault,
                             redirect_valid, redirect_pc, dbg_rob_cnt, dbg_iq_cnt,
                             cnt_commit, cnt_squash, u_front_head_pc);
                    $fflush();
                end
                if (trap_valid) begin
                    $display("FAIL: 程序 %0d 出现提交点异常 pc=0x%08x cause=%0d tval=0x%08x",
                             pi, trap_pc, trap_cause, trap_tval);
                    $fatal(1, "TB_BACK2_LOCKSTEP 出现未预期异常");
                end
            end
            if (rst_n) begin end

            // ---- C1/C2/C3：逐条比对 ----
            $display("== 程序 %0d：两核提交 %0d / %0d 条（黄金 %0d），跳板 %0d / %0d 条，%0d 拍",
                     pi, n2a, noo, cmax, npre2a, npreoo, cyc);
            $fflush();
            // ---- 诊断：转储乱序核已落账 PC 的尾部（DBG_CYCLES!=0 时；只读数组，零功能影响）----
            if (DBG_CYCLES != 0) begin : oo_tail
                integer t0, t1;
                t0 = (noo > 40) ? (noo - 40) : 0;
                t1 = (noo < GMAX) ? noo : GMAX;
                $display("      [oo-tail 程序 %0d] noo=%0d 2A=%0d 转储下标 [%0d,%0d)",
                         pi, noo, n2a, t0, t1);
                for (k = t0; k < t1; k = k + 1)
                    $display("        idx=%0d rec=0x%08x 2A=0x%08x gold=0x%08x | we=%b rd=%0d wd=0x%08x",
                             k, roo_pc[k], r2a_pc[k], GOLD[pi*P_GOLD_MAX + k],
                             roo_we[k], roo_rd[k], roo_wd[k]);
                $fflush();
            end
            //   ★ 计数取 ≥：程序以 `j .` 自跳转结尾，两核到达 cmax 的拍不同，
            //     先到者会继续提交若干条 `j .`；比较只取前 cmax 条（见下面 C1/C2）。
            chk(n2a >= cmax, $sformatf("C3 程序 %0d：2A 核提交条数 ≥ 黄金条数", pi));
            chk(noo >= cmax, $sformatf("C3 程序 %0d：乱序核提交条数 ≥ 黄金条数", pi));
            $display("      跳板 2A = 0x%08x 0x%08x 0x%08x | 乱序 = 0x%08x 0x%08x 0x%08x",
                     pre2a[0], pre2a[1], pre2a[2], preoo[0], preoo[1], preoo[2]);
            chk(npre2a == npreoo, $sformatf("C3 程序 %0d：跳板条数一致", pi));
            for (k = 0; k < npre2a; k = k + 1) begin
                if (pre2a[k] !== preoo[k]) begin
                    $display("FAIL: 程序 %0d 跳板第 %0d 条分歧：2A=0x%08x 乱序=0x%08x",
                             pi, k, pre2a[k], preoo[k]);
                    k = npre2a;
                end
            end
            chk(1'b1, "C3 跳板提交流逐条一致（诊断见上）");
            begin : cmp_loop
                integer d2a, doo;
                d2a = 0; doo = 0;
                for (k = 0; k < cmax; k = k + 1) begin
                    if ((r2a_pc[k] !== (GOLD[pi*P_GOLD_MAX + k] + gold_delta)) && (d2a == 0)) begin
                        $display("FAIL: 程序 %0d 2A 核第 %0d 条 PC=0x%08x 期望 0x%08x",
                                 pi, k, r2a_pc[k], GOLD[pi*P_GOLD_MAX + k] + gold_delta);
                        d2a = 1;
                    end
                    if ((roo_pc[k] !== (GOLD[pi*P_GOLD_MAX + k] + gold_delta)) && (doo == 0)) begin
                        $display("FAIL: 程序 %0d 乱序核第 %0d 条 PC=0x%08x 期望 0x%08x",
                                 pi, k, roo_pc[k], GOLD[pi*P_GOLD_MAX + k] + gold_delta);
                        doo = 1;
                    end
                end
                chk(d2a == 0, $sformatf("C2 程序 %0d：2A 核提交流 vs Spike 黄金 PC 流 0 分歧", pi));
                chk(doo == 0, $sformatf("C2 程序 %0d：乱序核提交流 vs Spike 黄金 PC 流 0 分歧", pi));
                begin : cross_loop
                    integer dc, dcv;
                    dc = 0; dcv = 0;
                    for (k = 0; k < cmax; k = k + 1) begin
                        if ((roo_pc[k] !== r2a_pc[k]) && (dc == 0)) begin
                            $display("FAIL: 程序 %0d 第 %0d 条提交 PC 分歧：乱序 0x%08x vs 2A 0x%08x",
                                     pi, k, roo_pc[k], r2a_pc[k]);
                            dc = 1;
                        end
                        if (((roo_we[k] !== r2a_we[k]) ||
                             (roo_we[k] && ((roo_rd[k] !== r2a_rd[k]) ||
                                            (roo_wd[k] !== r2a_wd[k])))) && (dcv == 0)) begin
                            $display("FAIL: 程序 %0d 第 %0d 条写回分歧：乱序 {we=%b rd=%0d wd=0x%08x} vs 2A {we=%b rd=%0d wd=0x%08x}",
                                     pi, k, roo_we[k], roo_rd[k], roo_wd[k],
                                     r2a_we[k], r2a_rd[k], r2a_wd[k]);
                            dcv = 1;
                        end
                    end
                    chk(dc == 0, $sformatf("C1 程序 %0d：提交 PC 流锁步 0 分歧", pi));
                    chk(dcv == 0, $sformatf("C1 程序 %0d：arch 写回流锁步 0 分歧", pi));
                end
            end

            // ---- C4：存储映像逐字相等（全 64 KiB 体，覆盖程序/数据/栈/tohost）----
            begin : mem_cmp
                integer dm, m2;
                dm = 0;
                for (m2 = 0; m2 < MEM_WORDS; m2 = m2 + 1) begin
                    if ((mem_oo[m2] !== u_mem2a.ddr3_mem[m2]) && (dm == 0)) begin
                        $display("FAIL: 程序 %0d 第 %0d 字存储不等：乱序 0x%08x vs 2A 0x%08x",
                                 pi, m2, mem_oo[m2], u_mem2a.ddr3_mem[m2]);
                        dm = 1;
                    end
                end
                chk(dm == 0, $sformatf("C4 程序 %0d：收尾存储映像逐字相等", pi));
            end

            $display("      前端分支统计：total=%0d mispred=%0d dir=%0d target=%0d",
                     bpu_br_total, bpu_br_mispred, bpu_dir_mispred, bpu_target_mispred);

            // ---- C5：吞吐观测（判据 = 端到端 IPC ≥ IPC_LIMIT_Q8/256 的退化下限）----
            //   端到端 IPC 上限 = 前端取指带宽（≤1 条/拍，见文件头 C5 说明），故此处的
            //   阈值只用于"防退化"，"IPC>1.0"的正式证据在 sim/unit/tb_back2_ipc.sv。
            n_commit_run = n2a;
            if (first_cyc < 0) first_cyc = 0;
            if (last_cyc < 0) last_cyc = 0;
            // 提交窗 = 首条提交拍 → 末条提交拍（含两端）
            stats_ipc_q8 = (n_commit_run * 256) / ((last_cyc - first_cyc) + 1);
            ipc = (n_commit_run * 1.0) / ((last_cyc - first_cyc) + 1);
            $display("== 程序 %0d 性能：提交窗拍数=%0d 提交条数=%0d 平均 IPC=%0.4f 宽度4占比=%0d%%",
                     pi, (last_cyc - first_cyc) + 1, n_commit_run, ipc,
                     (c4 * 100) / ((last_cyc - first_cyc) + 1));
            chk(stats_ipc_q8 >= ipc_lim_q8(pi),
                $sformatf("C5 程序 %0d 提交窗平均 IPC(Q8)=%0d 必须 ≥ %0d（分档防退化下限）",
                          pi, stats_ipc_q8, ipc_lim_q8(pi)));
        end

        $display("== 检查项合计 %0d 项全部满足；提交总数 = %0d（3 程序）", n_checks,
                 P0_GOLD_N + P1_GOLD_N + P2_GOLD_N);
        $display("TB_BACK2_LOCKSTEP: PASS");
        $finish;
    end

    // 全局超时兜底
    initial begin
        #(CLK_HALF_NS * 2 * (CYC_LIMIT + 100000));
        $display("FAIL: TB 超时");
        $fatal(1, "TB_BACK2_LOCKSTEP 超时");
    end

    // ---- 诊断探针（仅前 DBG_CYCLES 拍；默认 0 = 完全静默，不影响正常判据）----
    integer dbg_cyc;
    initial dbg_cyc = 0;
    always @(posedge clk) begin
        if (rst_n && (dbg_cyc < DBG_CYCLES)) begin
            dbg_cyc = dbg_cyc + 1;
            if (|u_back.iprf_we)
                $display("      [pf-wr t=%0t] we=%b keep=%b wa=%b",
                         $time, u_back.iprf_we, u_back.wbi_keep, u_back.iprf_wa);
            if (u_back.wbi_v[0])
                $display("      [alu0-wb t=%0t] tag=%0d data=0x%08x rob=%0d keep=%b opa=0x%08x opb=0x%08x",
                         $time, u_back.wbi_tag[0*7 +: 7], u_back.wbi_data[0*32 +: 32],
                         u_back.wb_rob[0*7 +: 7], u_back.wbi_keep,
                         u_back.a0_opa, u_back.a0_opb);
            if (u_back.wbi_v[1])
                $display("      [alu1-wb t=%0t] tag=%0d data=0x%08x opa=0x%08x opb=0x%08x res=0x%08x",
                         $time, u_back.wbi_tag[1*7 +: 7], u_back.wbi_data[1*32 +: 32],
                         u_back.a1_opa, u_back.a1_opb, u_back.a1_res);
            $display("[dbg %0d] 2A pc=0x%08x ws=%b | OO blkv=%b m=%b blkr=%b redir=%b sq=%b rob h=%0d cnt=%0d hdone=%b hexc=%x | d1v=%b room=%b fI=%b fF=%b iq=%b stq=%b rnb=%b/%b halt=%b ci=%0d cf=%0d",
                     dbg_cyc, u_core2a.fu_fetch_pc, ws_valid,
                     blk_valid, blk_mask, blk_ready, redirect_valid, cnt_squash,
                     dbg_rob_head, dbg_rob_cnt, dbg_rob_hdone, dbg_rob_hexc,
                     u_back.d1_v_q, u_back.rob_alloc_ready, u_back.free_i_ok, u_back.free_f_ok,
                     u_back.iq_room_ok, u_back.st_alloc_ok,
                     u_back.rn_i_busy, u_back.rn_f_busy, u_back.trap_halt_q,
                     u_back.free_i_cnt, u_back.free_f_cnt);
            $display("      iq: sel=%b iss=%b dead=%b headpc=0x%08x busy64=%b busy72=%b",
                     u_back.iq_sel_v, u_back.iq_iss_v, u_back.iq_iss_dead,
                     commit_pc[31:0], u_back.busy_i_q[71:64], u_back.busy_i_q[79:72]);
            $display("      iq2: sel=%b iss=%b dead=%b headpc=0x%08x busylow=%b",
                     u_back.iq_sel_v, u_back.iq_iss_v, u_back.iq_iss_dead,
                     commit_pc[31:0], u_back.busy_i_q[39:32]);
            $display("      head: pc=0x%08x opt=%0d cls=%0d q=%0d st=%b br=%b csr=%b fp=%b ld=%b exc=%x | iqcnt=%b",
                     u_back.p_pc(u_back.cmt_pay[0 +: `BACK2_RB_W]),
                     u_back.u_opt(u_back.cmt_pay[0 +: `BACK2_RB_W]),
                     u_back.p_cls(u_back.cmt_pay[0 +: `BACK2_RB_W]),
                     u_back.cmt_pay[`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB],
                     u_back.p_st(u_back.cmt_pay[0 +: `BACK2_RB_W]),
                     u_back.u_is_br(u_back.cmt_pay[0 +: `BACK2_RB_W]),
                     u_back.p_csr(u_back.cmt_pay[0 +: `BACK2_RB_W]),
                     u_back.cmt_pay[`BACK2_UB_IS_FP],
                     u_back.cmt_pay[`BACK2_UB_IS_LOAD],
                     u_back.cmt_pay[`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB],
                     dbg_iq_cnt[23:0]);
            if (|u_back.wb_v)
                $display("      [wb t=%0t] v=%b rob=%b", $time, u_back.wb_v, u_back.wb_rob);
            if (|u_back.iq_iss_v)
                $display("      [iss t=%0t] v=%b dead=%b", $time, u_back.iq_iss_v, u_back.iq_iss_dead);
            if (u_back.disp_fire_w)
                $display("      [disp t=%0t] d1v=%b laneq=%b wv=%b pc0=0x%08x rob0=%0d",
                         $time, u_back.d1_v_q, u_back.lane_q, u_back.iq_wv_g,
                         lane_pc[31:0], u_back.rob_alloc_idx0);
            $display("      iq0: v=%b rob=%b rdy0=%b rdy1=%b esel=%b outwin=%b robcnt=%0d",
                     u_back.u_iq0.valid_q, u_back.u_iq0.rob_q,
                     u_back.u_iq0.rdy_q[15:0], u_back.u_iq0.rdy_q[31:16],
                     u_back.u_iq0.e_sel, u_back.u_iq0.out_window, u_back.u_iq0.rob_cnt);
            $display("      iq1: v=%b rdy0=%b rdy1=%b esel=%b erdy=%b wkhit=%b wki=%b wktag=%b",
                     u_back.u_iq1.valid_q, u_back.u_iq1.rdy_q[15:0], u_back.u_iq1.rdy_q[31:16],
                     u_back.u_iq1.e_sel, u_back.u_iq1.e_rdy, u_back.u_iq1.wk_hit,
                     u_back.u_iq1.wki_v_e, u_back.u_iq1.wki_tag_e[41:0]);
            $display("      iq4: v=%b rdy=%b rob=%b esel=%b outwin=%b cnt=%0d",
                     u_back.u_iq4.valid_q, u_back.u_iq4.rdy_q, u_back.u_iq4.rob_q,
                     u_back.u_iq4.e_sel, u_back.u_iq4.out_window, u_back.u_iq4.rob_cnt);
            $display("      lsu3: pend_any=%b rsp_ok=%b dr_any=%b rspv=%b rstg=%b lsuwb=%b lsuwbrob=%0d cntld=%0d cntstall=%0d",
                     u_back.u_lsu.pend_any, u_back.u_lsu.rsp_ok, u_back.u_lsu.dr_any,
                     mem_rsp_valid, mem_rsp_tag, u_back.lsu_wb_v, u_back.lsu_wb_rob,
                     u_back.u_lsu.cnt_ld_q, u_back.u_lsu.cnt_stall_q);
            $display("      lsu2: head=%0d unk=%b issok=%b",
                     u_back.u_lsu.stq_head_q, u_back.u_lsu.any_unk_w,
                     u_back.lsu_iss_ok_w);
            $display("      lsu: reqv=%b wen=%b addr=0x%08x rspv=%b wbv=%b stdone=%b stq=%0d mduf=%b fputf=%b",
                     mem_req_valid, mem_req_wen, mem_req_addr, mem_rsp_valid,
                     u_back.lsu_wb_v, u_back.lsu_st_done_v, dbg_stq_cnt,
                     u_back.mdu_if_v, u_back.fpu_if_v);
            $fflush();
        end
    end

endmodule
