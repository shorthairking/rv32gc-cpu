//==============================================================================
// sim/unit/tb_front4_integration.sv —— 2B-1 前端集成验证：前端指令流 vs 黄金轨迹
//==============================================================================
// 被测  : rtl/front4/front4_top.v（F1–F4 + 锦标赛预测器）
//         + **真 2A L1I**（rtl/cache/l1i.v，只读复用）+ TB 侧行填充模型 + XIP 直连模型
// 规格  : docs/design/02-pipeline.md §3.1–§3.4/§6（F1–F4、重定向）、§5（与后端衔接）；
//         docs/design/04-predictor.md §5（训练时机=提交点、误判恢复）；
//         docs/design/08-baseline-5stage.md §8.3（锁步/黄金轨迹比对思路）。
//
// 【为什么是"黄金轨迹比对"而不是"新前端 + 2A 后端"】
//   2A 的顺序后端与前端**耦合在同一个 248 KB 的 rtl/top/core_top.v 内**（本任务禁改
//   2A 全部文件），无法只替换前端；且 2A 后端是 1 发射顺序 5 级，与本前端的 4 路分组/
//   检查点接口不同构。故按任务书允许的退路取 **方案 B：前端指令流 vs 黄金轨迹 0 分歧**。
//
// 【黄金轨迹来源（可复现，三条命令见 sim/unit/prog/front4_int.S 头注）】
//   ① 程序真源：sim/unit/prog/front4_int.S（+ front4_int.ld，起始 0x8000_0000）
//      —— 两层嵌套循环 + 数据相关交替分支 + 二级调用/返回 + RVC/32 bit 混排；
//   ② 工具链：/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc（GCC 16.1.0）；
//   ③ 黄金轨迹：/opt/riscv/bin/spike --isa=rv32imac_zicsr --pc=0x80000000
//      --log-commits --log=<file> 的 `core 0: <priv> <pc> (<insn>) …` 行 ⇒
//      **架构提交 PC 序列**（248 条）；
//   ④ 数据/轨迹内嵌：sim/unit/prog/gen_front4_int_data.py 生成
//      sim/unit/prog/front4_int_data.svh（程序映像 21 字 + 黄金 PC 248 条）。
//
// 【后端参照模型（TB 侧）：像真后端那样驱动前端】
//   · 块握手：`blk_ready` 常 1（不做反压；反压场景由 tb_front4_frontend 覆盖）
//   · 提交/训练：按黄金顺序提交（带 8 条滞后模拟 ROB 提交滞后），提交时驱动
//     `train_*`（含预测时记录：最终方向/选择器选择/两分量方向/BTB 命中），
//     条件分支训练方向表、调用/返回/间接训练 BTB；
//   · D1/D2 侧：按黄金流识别 call/ret 驱动 RAS 压/弹（TB 维护自己的返回地址栈）；
//   · E1 误判：交付 lane 与黄金不一致时，**必须能归因到更老的真实控制流 owner**
//     （其实际黄金 next ≠ 独立预测 next）；只允许沿该 owner 的预测错误路径短暂偏离，
//     `redirect` 目标 = 该 owner 的**合法黄金后继**（不是任意 g_pc），并把该组剩余
//     lane 全部丢弃；无 owner 的偏离立即失败。
//
// 【判据（全部 $fatal；未捕获即失败）—— 独立黄金，不再拿 DUT 的 blk_next 自洽】
//   C0 **独立解码**：lane 的控制流类别只由**程序映像指令位**按 RV32I/C 解码
//      （cond / jal / jalr-ret / 非控制流），**绝不**用 DUT 的 lane_pred_taken 反推
//      "它是不是分支"。cond/jal 的直接目标由指令立即数独立计算并核对。
//   C1 覆盖：黄金 248 条**逐条按序**被前端交付并匹配（g_idx 走到 g_npc）——顺序、
//      无跳条、无重复（匹配规则保证；断言最终计数相等）
//   C2 **预测流连续（独立期望）**：块首 lane == 上一块末尾 lane 按解码类别+预测方向
//      算出的 next（不是 DUT 的 blk_next_pc）；块内相邻 lane 同样沿上一条的独立
//      next；块尾 `blk_next_pc` 必须等于该独立 next，`blk_taken` 必须等于"尾部是
//      真实控制流且预测 taken"。⇒ 非分支伪 taken / 顺序尾伪 +4 立即红。
//   C3 **分歧只能由更老真实控制流 owner 解释**：只有"真实 branch/jal/jalr/ret 的
//      实际黄金 next ≠ 本次独立预测 next"时，其预测路径上的后继 PC 才允许偏离黄金；
//      重定向目标必须恰等于该 owner 的实际黄金 next（= 当前 g_pc[g_idx]），
//      不允许"任意 goldPC 纠偏"吞掉取指损坏。nonbranch 伪 taken、顺序伪 next 直接红。
//   C4 交付 lane 的**指令位/长度**必须与程序映像逐条一致（跨字/跨行拼接的真值校验）
//   C5 统计交叉核对：bpu_br_total / bpu_br_mispred 与 TB 参照模型一致；
//      bpu_ras_repair == 0（本程序调用/返回结构平衡）；cnt_fault == 0（无取指异常）
//   C6 报告：交付 lane 数 / 错误路径 lane 数 / 误判事件数 / 取指请求数（证据）
//   C7 黄金轨迹自洽：真实 cond/jal 的 g_pc[i+1] 必须等于解码出的 taken/not-taken
//      目标，非控制流必须等于 PC+len（解码错会在此暴露，而不是被"任意纠偏"掩盖）
//
// 顶层  : tb_front4_integration_top
// 锚点  : TB_FRONT4_INTEGRATION: PASS（整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module tb_front4_integration_top;

    localparam integer CLK_PERIOD = 10;
    localparam [31:0]  DDR_BASE   = 32'h8000_0000;
    localparam integer N_PMP      = `RV32GC_PMP_ENTRIES;
    localparam integer MAX_GOLD   = 1024;
    localparam integer RESYNC_MAX = 200;      // 重定向后重新对齐的最大拍数

    //--------------------------------------------------------------------------
    // 时钟/复位/检查
    //--------------------------------------------------------------------------
    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_FRONT4_INTEGRATION 判据不满足");
            end
        end
    endtask
    task automatic chk_eq32(input [31:0] got, input [31:0] exp, input string msg);
        begin
            n_checks = n_checks + 1;
            if (got !== exp) begin
                $display("FAIL: %s 期望 0x%08x 实得 0x%08x（第 %0d 项）", msg, exp, got, n_checks);
                $fatal(1, "TB_FRONT4_INTEGRATION 判据不满足");
            end
        end
    endtask
    // 结构/黄金判据的硬失败：立即报出精确原因（便于变异反证定位），不接受兜底 PASS。
    task automatic fail_now(input string msg);
        begin
            $display("FAIL: %s", msg);
            $fatal(1, "TB_FRONT4_INTEGRATION 判据不满足");
        end
    endtask

    //--------------------------------------------------------------------------
    // 存储体（DDR 走真 L1I + 行填充；XIP 走直连）
    //--------------------------------------------------------------------------
    reg [31:0] mem_ddr [0:65535];
    reg [31:0] mem_xip [0:4095];
    integer j;
    initial begin
        for (j = 0; j < 65536; j = j + 1) mem_ddr[j] = 32'h0000_0013;    // 默认 nop
        for (j = 0; j < 4096;  j = j + 1) mem_xip[j] = 32'h0000_0013;    // 复位首取（XIP）
    end

    // 按**字节地址**写一条指令（IALIGN=16 ⇒ 可能落在奇 parcel 上，两个半字分处相邻字）
    task automatic wr32(input [31:0] pa, input [31:0] v);
        integer w;
        begin
            w = pa[17:2];
            if (pa[1] == 1'b0) mem_ddr[w] = v;
            else begin
                mem_ddr[w]   = {v[15:0], mem_ddr[w][15:0]};
                mem_ddr[w+1] = {mem_ddr[w+1][31:16], v[31:16]};
            end
        end
    endtask

    // 程序映像读取（TB 侧真值：按 parcel 取指令位与长度）
    function automatic [15:0] img_parcel(input [31:0] pa);
        integer w;
        begin
            w = pa[17:2];
            img_parcel = pa[1] ? mem_ddr[w][31:16] : mem_ddr[w][15:0];
        end
    endfunction
    function automatic img_len32(input [31:0] pa);
        reg [15:0] lo;
        begin
            lo = img_parcel(pa);
            img_len32 = (lo[1:0] == 2'b11);
        end
    endfunction
    function automatic [31:0] img_insn(input [31:0] pa);
        reg [15:0] lo, hi;
        begin
            lo = img_parcel(pa);
            hi = img_parcel(pa + 32'd2);
            img_insn = img_len32(pa) ? {hi, lo} : {16'h0, lo};
        end
    endfunction

    //--------------------------------------------------------------------------
    // RV32I/C **独立解码**（真源：ISA 手册；绝不看 DUT 的 predflag 判断控制流）
    //   cf_kind: 0 = 非控制流；1 = 条件分支；2 = 直接跳转(jal/c.jal/c.j)；
    //            3 = 间接跳转(jalr/c.jr/c.jalr；含 ret)
    //--------------------------------------------------------------------------
    function automatic [1:0] cf_kind(input [31:0] pa);
        reg [31:0] insn;
        reg [15:0] lo;
        begin
            insn = img_insn(pa);
            lo   = img_parcel(pa);
            cf_kind = 2'd0;
            if (img_len32(pa)) begin
                case (lo[6:0])
                    7'b1100011: begin                       // B-type
                        if ((lo[14:12] != 3'b010) && (lo[14:12] != 3'b011))
                            cf_kind = 2'd1;
                    end
                    7'b1101111: cf_kind = 2'd2;             // JAL
                    7'b1100111: begin                       // JALR (funct3=000)
                        if (lo[14:12] == 3'b000) cf_kind = 2'd3;
                    end
                    default: cf_kind = 2'd0;
                endcase
            end else begin
                case (lo[1:0])
                    2'b01: case (lo[15:13])
                               3'b001: cf_kind = 2'd2;      // c.jal（RV32）
                               3'b101: cf_kind = 2'd2;      // c.j
                               3'b110: cf_kind = 2'd1;      // c.beqz
                               3'b111: cf_kind = 2'd1;      // c.bnez
                               default: cf_kind = 2'd0;
                           endcase
                    2'b10: begin
                        // CR 格式：只有 funct3==100、rs1!=0、rs2==0 才是 c.jr/c.jalr
                        // （完整按规范判 CR；C.LWSP 等 funct3!=100 的 Q2 指令绝不当 RET）
                        if ((lo[15:13] == 3'b100) && (lo[11:7] != 5'd0) &&
                            (lo[6:2] == 5'd0))
                            cf_kind = 2'd3;
                    end
                    default: cf_kind = 2'd0;
                endcase
            end
            // 防未用告警（insn 在 32bit 分支有用；保留可读性）
            insn = insn;
        end
    endfunction

    // 控制流立即数（cond/jal；间接跳转不使用）
    function automatic [31:0] cf_imm(input [31:0] pa);
        reg [31:0] insn;
        reg [15:0] lo;
        reg [31:0] imm;
        begin
            insn = img_insn(pa);
            lo   = img_parcel(pa);
            imm  = 32'h0;
            if (img_len32(pa)) begin
                case (lo[6:0])
                    // B-type: imm = {sign, i[7], i[30:25], i[11:8], 0}
                    7'b1100011: imm = {{19{insn[31]}}, insn[31], insn[7],
                                       insn[30:25], insn[11:8], 1'b0};
                    // J-type: imm = {sign, i[19:12], i[20], i[30:21], 0}
                    7'b1101111: imm = {{11{insn[31]}}, insn[31], insn[19:12],
                                       insn[20], insn[30:21], 1'b0};
                    default: imm = 32'h0;
                endcase
            end else begin
                case (lo[1:0])
                    2'b01: case (lo[15:13])
                        3'b001, 3'b101:                     // c.jal / c.j
                            imm = {{20{lo[12]}}, lo[12], lo[8], lo[10:9],
                                   lo[6], lo[7], lo[2], lo[11], lo[5:3], 1'b0};
                        3'b110, 3'b111:                     // c.beqz / c.bnez
                            imm = {{23{lo[12]}}, lo[12], lo[6:5], lo[2],
                                   lo[11:10], lo[4:3], 1'b0};
                        default: imm = 32'h0;
                    endcase
                    default: imm = 32'h0;
                endcase
            end
            cf_imm = imm;
        end
    endfunction

    // 独立控制流类别（对照产品 lane_cls 编码：0 NONE/1 COND/2 DJMP/3 INDIR/4 RET/5 DCALL/6 ICALL）
    function automatic [2:0] cf_cls(input [31:0] pa);
        reg [31:0] insn;
        reg [15:0] lo;
        reg [1:0]  k;
        reg [4:0]  rd5, rs15;
        begin
            insn = img_insn(pa); lo = img_parcel(pa); k = cf_kind(pa);
            cf_cls = 3'd0;
            rd5  = img_len32(pa) ? insn[11:7] : 5'd0;
            rs15 = img_len32(pa) ? insn[19:15] : lo[11:7];
            if (k == 2'd1) cf_cls = 3'd1;
            else if (k == 2'd2) begin
                if (img_len32(pa))
                    cf_cls = ((insn[11:7] == 5'd1) || (insn[11:7] == 5'd5)) ? 3'd5 : 3'd2;
                else
                    cf_cls = (lo[15:13] == 3'b001) ? 3'd5 : 3'd2;   // c.jal / c.j
            end else if (k == 2'd3) begin
                if (img_len32(pa)) begin
                    if ((insn[11:7] == 5'd0) && (insn[31:20] == 12'h000) &&
                        ((insn[19:15] == 5'd1) || (insn[19:15] == 5'd5)))
                        cf_cls = 3'd4;                                  // ret
                    else if ((insn[11:7] == 5'd1) || (insn[11:7] == 5'd5))
                        cf_cls = 3'd6;                                  // icall
                    else cf_cls = 3'd3;                                 // indir
                end else begin
                    if (lo[12]) cf_cls = 3'd6;                          // c.jalr
                    else cf_cls = ((rs15 == 5'd1) || (rs15 == 5'd5)) ? 3'd4 : 3'd3;
                end
            end
        end
    endfunction

    // 独立预测 next：预测 taken ⇒ DUT 给出的预测目标；否则按**指令位长度**顺序 +2/+4
    function automatic [31:0] pred_nxt(input [31:0] pa, input tk, input [31:0] tgt);
        begin
            pred_nxt = tk ? tgt : (pa + (img_len32(pa) ? 32'd4 : 32'd2));
        end
    endfunction

    // 黄金轨迹 + 程序映像（脚本生成的内嵌数据）
    reg [31:0] g_pc [0:MAX_GOLD-1];
    integer    g_npc;

    //--------------------------------------------------------------------------
    // DUT 端口
    //--------------------------------------------------------------------------
    reg         rst_hold, redirect_valid, redirect_use_ckpt, break_point, fe_stall, blk_ready;
    reg  [31:0] redirect_pc;
    reg  [3:0]  redirect_ckpt;
    wire        blk_valid, blk_taken, fe_fetch_fault, fe_frozen;
    wire [3:0]  blk_mask;
    wire [31:0] blk_next_pc;
    wire [127:0] lane_pc, lane_pa, lane_insn, lane_pred_target, lane_btb_target, lane_fault_tval;
    wire [3:0]  lane_len32, lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    wire [3:0]  lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    wire [3:0]  lane_fault, lane_ckpt_valid;
    wire [11:0] lane_cls;
    wire [19:0] lane_fault_cause;
    wire [15:0] lane_ckpt;

    reg         train_valid;
    reg  [31:0] train_pc, train_target, train_pred_target;
    reg         train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    reg         train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    reg         train_pred_valid, train_btb_hit, train_btb_way;
    wire        train_ready;

    reg         ckpt_free_valid, ras_cmt_push_valid, ras_cmt_pop_valid;
    reg  [3:0]  ckpt_free_id;
    reg         d2_push_valid, d2_pop_valid;
    reg  [31:0] d2_push_addr, d2_pop_addr;
    wire        ras_repair_valid;
    wire [31:0] ras_repair_addr;

    reg  [1:0]  priv;
    reg  [N_PMP*8-1:0]  pmpcfg_i;
    reg  [N_PMP*32-1:0] pmpaddr_i;

    wire        l1i_req_valid, tr_req_valid;
    wire [31:0] l1i_req_addr, l1i_req_line, tr_req_va;
    wire        unc_req_valid;
    wire [31:0] unc_req_pa;
    reg         unc_rsp_valid;
    reg  [31:0] unc_rsp_pa, unc_rsp_data;

    wire [31:0] bpu_br_total, bpu_br_mispred, bpu_dir_mispred, bpu_target_mispred;
    wire [31:0] bpu_gshare_right, bpu_local_right, bpu_sel_global, bpu_sel_local;
    wire [31:0] bpu_ras_push, bpu_ras_pop, bpu_ras_overflow, bpu_ras_repair;
    wire [31:0] bpu_ckpt_full_stall, bpu_train_overflow, bpu_btb_alloc;
    wire [31:0] cnt_grp, cnt_parcels, cnt_fault, cnt_restart, cnt_stall, cnt_req, cnt_redirect;
    wire [15:0] ghr_o;
    wire [31:0] fetch_pc_o, head_pc_o;
    wire [1:0]  epoch_o;

    //--------------------------------------------------------------------------
    // 真 2A L1I + 行填充
    //--------------------------------------------------------------------------
    wire        l1i_cs_ready, l1i_cs_uncached, l1i_cs_miss, l1i_idle;
    wire [31:0] l1i_cs_rdata;
    wire        l1i_fill_req;
    wire [31:0] l1i_fill_paddr;
    wire [1:0]  l1i_fill_owner;
    wire [4:0]  l1i_fill_beats;
    reg         l1i_fill_accepted, l1i_fill_valid, l1i_fill_done, l1i_inval_all;
    reg  [31:0] l1i_fill_data;
    reg  [4:0]  l1i_fill_word_idx;

    l1i u_l1i (
        .clk(clk), .rst_n(rst_n),
        .cs_req(l1i_req_valid), .cs_paddr(l1i_req_line), .cs_vaddr(l1i_req_addr),
        .cs_ready(l1i_cs_ready), .cs_rdata(l1i_cs_rdata),
        .cs_uncached(l1i_cs_uncached), .cs_miss(l1i_cs_miss),
        .fill_req(l1i_fill_req), .fill_paddr(l1i_fill_paddr),
        .fill_owner(l1i_fill_owner), .fill_beats(l1i_fill_beats),
        .fill_accepted(l1i_fill_accepted), .fill_valid(l1i_fill_valid),
        .fill_data(l1i_fill_data), .fill_word_idx(l1i_fill_word_idx),
        .fill_done(l1i_fill_done), .inval_all(l1i_inval_all), .idle(l1i_idle),
        // ★★ 04-07：无错环境模型 ⇒ 新增错误输入显式接 0（不悬空）
        .fill_err(1'b0), .cs_err(), .fill_fail(), .err_sticky()
    );

    reg     filling;
    initial begin
        l1i_fill_accepted = 1'b0; l1i_fill_valid = 1'b0; l1i_fill_done = 1'b0;
        l1i_fill_data = 32'h0; l1i_fill_word_idx = 5'h0; filling = 1'b0;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1i_fill_accepted <= 1'b0; l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            l1i_fill_word_idx <= 5'h0; filling <= 1'b0;
        end else begin
            l1i_fill_accepted <= l1i_fill_req & ~filling & ~l1i_fill_accepted;
            if (l1i_fill_req & ~filling & ~l1i_fill_accepted) begin
                filling <= 1'b1; l1i_fill_word_idx <= 5'h0;
                l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            end else if (filling) begin
                if (!l1i_fill_valid) begin
                    l1i_fill_valid <= 1'b1;
                    l1i_fill_data <= mem_ddr[l1i_fill_paddr[17:2] + l1i_fill_word_idx];
                    l1i_fill_done <= (l1i_fill_word_idx == 5'd7);
                end else begin
                    l1i_fill_valid <= 1'b0;
                    if (l1i_fill_word_idx == 5'd7) begin
                        filling <= 1'b0; l1i_fill_done <= 1'b1;
                    end else begin
                        l1i_fill_word_idx <= l1i_fill_word_idx + 5'd1;
                        l1i_fill_data <= mem_ddr[l1i_fill_paddr[17:2] + l1i_fill_word_idx + 5'd1];
                        l1i_fill_valid <= 1'b1;
                        l1i_fill_done <= (l1i_fill_word_idx == 5'd6);
                    end
                end
            end else begin
                l1i_fill_valid <= 1'b0; l1i_fill_done <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unc_rsp_valid <= 1'b0; unc_rsp_pa <= 32'h0; unc_rsp_data <= 32'h0;
        end else begin
            unc_rsp_valid <= unc_req_valid & ~unc_rsp_valid;
            unc_rsp_pa    <= unc_req_pa;
            unc_rsp_data  <= mem_xip[unc_req_pa[13:2]];
        end
    end

    //--------------------------------------------------------------------------
    // 前端
    //--------------------------------------------------------------------------
    front4_top #(.SPEC_GHR(0), .SEL_FORCE(0)) u_dut (
        .clk(clk), .rst_n(rst_n), .rst_hold(rst_hold),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
        .redirect_use_ckpt(redirect_use_ckpt), .redirect_ckpt(redirect_ckpt),
        .break_point(break_point), .fe_stall(fe_stall),
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
        .ras_cmt_push_valid(ras_cmt_push_valid), .ras_cmt_pop_valid(ras_cmt_pop_valid),
        .d2_push_valid(d2_push_valid), .d2_push_addr(d2_push_addr),
        .d2_pop_valid(d2_pop_valid), .d2_pop_addr(d2_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr),
        .sv32_translate_en(1'b0), .sv32_translate_done(1'b0),
        .sv32_translate_fault(1'b0), .sv32_translate_fault_af(1'b0),
        .sv32_translate_paddr(32'h0),
        .tr_req_valid(tr_req_valid), .tr_req_va(tr_req_va),
        .priv(priv), .pmpcfg_i(pmpcfg_i), .pmpaddr_i(pmpaddr_i),
        .l1i_req_valid(l1i_req_valid), .l1i_req_addr(l1i_req_addr),
        .l1i_req_line(l1i_req_line), .l1i_ready(l1i_cs_ready),
        .l1i_rdata(l1i_cs_rdata), .l1i_miss(l1i_cs_miss), .l1i_uncached(l1i_cs_uncached),
        .l1i_rsp_err(1'b0), .l1i_rsp_err_pa(32'h0),
        .unc_req_valid(unc_req_valid), .unc_req_pa(unc_req_pa),
        .unc_rsp_valid(unc_rsp_valid), .unc_rsp_pa(unc_rsp_pa), .unc_rsp_data(unc_rsp_data), .unc_rsp_err(1'b0),
        .fetch_pc_o(fetch_pc_o), .head_pc_o(head_pc_o), .epoch_o(epoch_o), .ghr_o(ghr_o),
        .bpu_br_total(bpu_br_total), .bpu_br_mispred(bpu_br_mispred),
        .bpu_dir_mispred(bpu_dir_mispred), .bpu_target_mispred(bpu_target_mispred),
        .bpu_gshare_right(bpu_gshare_right), .bpu_local_right(bpu_local_right),
        .bpu_sel_global(bpu_sel_global), .bpu_sel_local(bpu_sel_local),
        .bpu_ras_push(bpu_ras_push), .bpu_ras_pop(bpu_ras_pop),
        .bpu_ras_overflow(bpu_ras_overflow), .bpu_ras_repair(bpu_ras_repair),
        .bpu_ckpt_full_stall(bpu_ckpt_full_stall),
        .bpu_train_overflow(bpu_train_overflow), .bpu_btb_alloc(bpu_btb_alloc),
        .cnt_grp(cnt_grp), .cnt_parcels(cnt_parcels), .cnt_fault(cnt_fault),
        .cnt_restart(cnt_restart), .cnt_stall(cnt_stall), .cnt_req(cnt_req),
        .cnt_redirect(cnt_redirect)
    );

    //--------------------------------------------------------------------------
    // 内嵌黄金数据（脚本生成）
    //--------------------------------------------------------------------------
    `include "sim/unit/prog/front4_int_data.svh"

    //--------------------------------------------------------------------------
    // 参照模型（TB 侧"后端"）
    //--------------------------------------------------------------------------
    integer g_idx;                 // 下一条期望的黄金指令下标
    integer n_lane_ok;             // 与黄金一致的 lane 数
    integer n_lane_wrongpath;      // 被判为错误路径丢弃的 lane 数
    integer n_div;                 // 错误路径事件数（= 前端误判被后端发现）
    //   ★ G1（2026-10-20）：逐 lane 真值 + **独立**预测流连续性 + 真实控制流 owner
    integer n_bad_insn;            // 交付 lane 指令位与程序映像不一致的次数
    integer n_bad_len;             // 交付 lane 16/32 位长度与映像不一致的次数
    integer n_path_break;          // 独立预测流断裂（块首/块内/块尾）——必须为 0
    integer n_fake_cf;             // 非控制流被预测 taken / 块越过 taken 终止——必须为 0
    integer n_bad_cf;              // 直接控制流立即数/目标与解码不一致——必须为 0
    integer n_gold_cf;             // 黄金轨迹与独立解码不自洽——必须为 0
    reg [31:0] pred_next;          // **独立**期望的下一条 PC（由上一 lane 解码类别+预测算出）
    integer n_unexplained;         // 未解释分歧（必须为 0）
    integer n_grp_seen;
    reg     resync_mode;           // 1 = 刚发过重定向，等重新对齐
    //   固定程序/黄金身份自校（生成端已强校；TB 端再独立校 count/entry/last/校验和）
    integer    gi_id, pc34n, q2n;
    reg [31:0] gsum_id, gxor_id;
    reg [15:0] p16_id;
    //   "更老真实控制流 owner"：最近一条真实 branch/jal/jalr/ret，其**实际黄金 next**
    //   与本次独立预测 next 不同 ⇒ 允许其后继处于预测的（错误）路径上；重定向必须回到
    //   该 owner 的**合法黄金后继**，不得用任意 g_pc 纠偏。
    reg        off_path;           // 1 = 当前正在走某真实 owner 的错误预测路径
    reg [31:0] owner_pc;           // owner 的 PC（证据）
    reg [31:0] owner_pred_next;    // owner 的独立预测 next（错误路径入口）
    reg [31:0] owner_gold_next;    // owner 的实际黄金 next（唯一合法重定向目标）
    integer    n_owner_mispred;    // 真实控制流被预测错的次数（= 允许分歧的 owner 数）
    integer    n_reconverge;       // 从错误路径回到黄金后继的次数

    // ---- 提交/训练流水：{pc, cls(2), taken(1), target(32), pred record} ----
    localparam integer CQ_DEPTH = 64;     // 提交记录队列（模拟 ROB 提交滞后；深度足够不丢记录）
    reg [31:0] cq_pc  [0:CQ_DEPTH-1];
    reg [2:0]  cq_cls [0:CQ_DEPTH-1];     // 0=非分支 1=cond 2=call 3=ret 4=indirect
    reg        cq_tk  [0:CQ_DEPTH-1];
    reg [31:0] cq_tgt [0:CQ_DEPTH-1];
    reg [3:0]  cq_prd [0:CQ_DEPTH-1];     // {pred_taken, selg, ldir, gdir}
    reg        cq_bh  [0:CQ_DEPTH-1];
    reg        cq_bw  [0:CQ_DEPTH-1];
    reg        cq_ckv [0:CQ_DEPTH-1];     // 该条是否携带检查点（块尾预测跳转）
    reg [3:0]  cq_ck  [0:CQ_DEPTH-1];
    integer    cq_wr, cq_rd, cq_cnt;
    integer    n_cond_commit, n_cond_mis_ref;

    // TB 侧返回地址栈（D2 模型：call 压 pc+len，ret 弹）
    reg [31:0] ret_stack [0:63];
    integer    ret_sp;

    // 指令类别（TB 侧参照：与 ifetch4 的规则一致，仅供训练用）
    function automatic [2:0] cls_of(input [31:0] pc);
        reg [31:0] insn;
        reg [15:0] lo;
        begin
            insn = img_insn(pc);
            lo   = img_parcel(pc);
            cls_of = 3'd0;
            if (img_len32(pc)) begin
                case (lo[6:0])
                    7'b1101111: cls_of = ((lo[11:7] == 5'd1) || (lo[11:7] == 5'd5)) ? 3'd2 : 3'd0;
                    7'b1100111: begin
                        if ((lo[11:7] == 5'd0) && (insn[31:20] == 12'h000) &&
                            ((insn[19:15] == 5'd1) || (insn[19:15] == 5'd5))) cls_of = 3'd3;   // ret
                        else cls_of = 3'd4;                                                  // 间接
                    end
                    7'b1100011: cls_of = 3'd1;                                               // cond
                    default:    cls_of = 3'd0;
                endcase
            end else begin
                case (lo[1:0])
                    2'b01: case (lo[15:13])
                               3'b001: cls_of = 3'd2;      // c.jal（调用）
                               3'b101: cls_of = 3'd0;      // c.j
                               3'b110, 3'b111: cls_of = 3'd1;
                               default: cls_of = 3'd0;
                           endcase
                    2'b10: begin
                               // CR：必须 funct3==100，且 rs1!=0、rs2==0；否则非控制流
                               if ((lo[15:13] == 3'b100) && (lo[11:7] != 5'd0) &&
                                   (lo[6:2] == 5'd0)) begin
                                   if (lo[12]) cls_of = 3'd2;             // c.jalr（调用）
                                   else cls_of = ((lo[11:7] == 5'd1) || (lo[11:7] == 5'd5)) ? 3'd3 : 3'd4;
                               end else cls_of = 3'd0;
                           end
                    default: cls_of = 3'd0;
                endcase
            end
        end
    endfunction

    // 入队一条"提交记录"（带提交滞后；训练在出队时进行）
    task automatic commit_push(input [31:0] pc, input [2:0] cls, input tk,
                              input [31:0] tgt, input [3:0] prd, input bh, input bw,
                              input ckv, input [3:0] ck);
        begin
            cq_pc [cq_wr] = pc;   cq_cls[cq_wr] = cls; cq_tk[cq_wr] = tk;
            cq_tgt[cq_wr] = tgt;  cq_prd[cq_wr] = prd;
            cq_bh [cq_wr] = bh;   cq_bw [cq_wr] = bw;
            cq_ckv[cq_wr] = ckv;  cq_ck [cq_wr] = ck;
            cq_wr = (cq_wr + 1) % CQ_DEPTH;
            if (cq_cnt < CQ_DEPTH) begin
                cq_cnt = cq_cnt + 1;
            end else begin
                // 队列满：丢弃最老记录（不阻塞前端）。
                //   ★ 本 TB 的 CQ_DEPTH=64 已大于检查点总数（16），实测**从不丢弃**；
                //     若将来缩小队列，这里必须连带释放被丢记录的检查点（否则检查点泄漏
                //     ⇒ 前端 S7 停顿，本 TB 早期版本正是被这一条打停）。
                cq_rd = (cq_rd + 1) % CQ_DEPTH;
            end
        end
    endtask

    // 释放一个检查点（**2B-2 衔接点**：提交或冲刷丢弃时都要释放，否则前端 S7 停顿）
    task automatic ckpt_free_one(input [3:0] id);
        begin
            @(negedge clk); ckpt_free_valid = 1'b1; ckpt_free_id = id;
            @(posedge clk); @(negedge clk); ckpt_free_valid = 1'b0;
        end
    endtask

    // 一次训练（驱动 DUT 的提交训练口）
    task automatic do_train(input [31:0] pc, input [2:0] cls, input tk,
                            input [31:0] tgt, input [3:0] prd, input bh, input bw);
        begin
            @(negedge clk);
            train_valid = 1'b1;
            train_pc = pc;
            train_is_cond     = (cls == 3'd1);
            train_taken       = tk;
            train_is_call     = (cls == 3'd2);
            train_is_return   = (cls == 3'd3);
            train_is_indirect = (cls == 3'd4);
            train_target      = tgt;
            train_pred_taken  = prd[3];
            train_pred_sel_global = prd[2];
            train_pred_gdir   = prd[0];
            train_pred_ldir   = prd[1];
            train_pred_valid  = 1'b0;
            train_pred_target = 32'h0;
            train_btb_hit     = bh;
            train_btb_way     = bw;
            @(posedge clk);
            @(negedge clk);
            train_valid = 1'b0;
            while (u_dut.u_bpu.upd_busy !== 1'b0) @(posedge clk);
            @(negedge clk);
            if (cls == 3'd1) begin
                n_cond_commit = n_cond_commit + 1;
                if (prd[3] !== tk) n_cond_mis_ref = n_cond_mis_ref + 1;
            end
        end
    endtask

    // 出队一条提交记录（驱动训练 + D2 侧 RAS）
    task automatic commit_pop;
        reg [2:0] cls; reg [31:0] pc, tgt;
        begin
            if (cq_cnt > 0) begin
                pc  = cq_pc[cq_rd];
                cls = cq_cls[cq_rd];
                tgt = cq_tgt[cq_rd];
                if (cls == 3'd5) begin
                    // 仅释放检查点（错误路径被冲刷的记录）
                    if (cq_ckv[cq_rd]) ckpt_free_one(cq_ck[cq_rd]);
                    cq_rd = (cq_rd + 1) % CQ_DEPTH;
                    cq_cnt = cq_cnt - 1;
                    pc = pc;                      // 防未用告警
                end else begin
                // ---- D2 侧：压/弹 RAS ----
                if ((cls == 3'd2) && (ret_sp < 63)) begin
                    ret_stack[ret_sp] = pc + (img_len32(pc) ? 32'd4 : 32'd2);
                    ret_sp = ret_sp + 1;
                    @(negedge clk); d2_push_valid = 1'b1; d2_push_addr = ret_stack[ret_sp-1];
                    @(posedge clk); @(negedge clk); d2_push_valid = 1'b0;
                end else if (cls == 3'd3) begin
                    if (ret_sp > 0) ret_sp = ret_sp - 1;
                    @(negedge clk); d2_pop_valid = 1'b1;
                    d2_pop_addr = (ret_sp < 63) ? ret_stack[ret_sp] : 32'h0;
                    @(posedge clk); @(negedge clk); d2_pop_valid = 1'b0;
                end
                do_train(pc, cls, cq_tk[cq_rd], tgt, cq_prd[cq_rd], cq_bh[cq_rd], cq_bw[cq_rd]);
                if (cq_ckv[cq_rd]) ckpt_free_one(cq_ck[cq_rd]);   // 提交 ⇒ 释放检查点
                cq_rd = (cq_rd + 1) % CQ_DEPTH;
                cq_cnt = cq_cnt - 1;
                end
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 交付检查 + 重定向驱动（**核心判据**）
    //--------------------------------------------------------------------------
    reg        check_on;                 // 复位首取（XIP）不参与比对
    reg        train_stop;               // 训练出队循环停止标志
    reg        div_need;                 // 本拍需要发重定向
    reg [31:0] div_pc;
    integer    rs_wait;                  // 已等待重新对齐的拍数
    integer    i;
    integer    ck_q_cnt;            // （保留计数，恒为 0：检查点释放统一走提交队列）
    //   G1 判据的临时量（**不**从 DUT 的 blk_next 取期望）
    reg [31:0] pnext_l [0:3];       // 每条 lane 的独立预测 next
    reg [31:0] l_pc;
    reg [31:0] l_gn;
    reg [31:0] l_len;
    reg [2:0]  l_kind;
    reg [31:0] l_tk;
    integer    tail;

    always @(posedge clk) begin
        if (rst_n && check_on && blk_valid && blk_ready && (g_idx < g_npc) && !div_need) begin
            n_grp_seen = n_grp_seen + 1;
            tail = 0;
            for (i = 0; i < 4; i = i + 1) if (blk_mask[i]) tail = i;

            //==================================================================
            // A. 独立预测流连续性（块首 / 块内 / 块尾）——不用 DUT blk_next 自洽
            //    期望 next 只由 **指令位解码类别 + 本 lane 的预测方向/目标** 得出：
            //      · 非控制流：只允许 PC+len（伪 taken 直接红）
            //      · 真实控制流：taken ⇒ 预测目标；not-taken ⇒ PC+len
            //    块首必须等于上一块尾的独立 next（或重定向 PC）；块内相邻 lane 必须沿
            //    上一条独立 next；块尾 blk_next_pc 必须等于尾部独立 next，blk_taken 必须
            //    等于"尾部是真实控制流且预测 taken"。顺序尾伪 +4 在此直接红。
            //==================================================================
            if (blk_mask[0] && (lane_pc[31:0] !== pred_next)) begin
                n_path_break = n_path_break + 1;
                fail_now($sformatf(
                    "独立预测流断裂：块首 lane0=0x%08x != 上一块独立 next=0x%08x（g_idx=%0d）",
                    lane_pc[31:0], pred_next, g_idx));
            end
            for (i = 0; i < 4; i = i + 1) begin
                if (blk_mask[i]) begin
                    l_pc = lane_pc[i*32 +: 32];
                    // ---- 逐 lane 指令位/长度真值（对错误路径同样检查）----
                    if (lane_insn[i*32 +: 32] !== img_insn(l_pc)) begin
                        n_bad_insn = n_bad_insn + 1;
                        fail_now($sformatf(
                            "BAD_INSN: lane%0d pc=0x%08x dut=0x%08x img=0x%08x",
                            i, l_pc, lane_insn[i*32 +: 32], img_insn(l_pc)));
                    end
                    if (lane_len32[i] !== img_len32(l_pc)) begin
                        n_bad_len = n_bad_len + 1;
                        fail_now($sformatf(
                            "BAD_LEN: lane%0d pc=0x%08x dut=%0d img=%0d",
                            i, l_pc, lane_len32[i], (img_len32(l_pc) ? 32'd4 : 32'd2)));
                    end
                    // ---- 控制流类别只由指令位解码（RV32I/C），不看 DUT predflag ----
                    l_kind = cf_kind(l_pc);
                    //   ★ 产品 lane_cls 必须与独立解码一致（Q2 load 不得报成 RET/INDIR）
                    if (lane_cls[i*3 +: 3] !== cf_cls(l_pc))
                        fail_now($sformatf(
                            "lane_cls 与独立解码不符：lane%0d pc=0x%08x dut=%0d exp=%0d insn=0x%08x",
                            i, l_pc, lane_cls[i*3 +: 3], cf_cls(l_pc), img_insn(l_pc)));
                    //   ★ 固定映像 PC=0x80000034 是 C.LWSP：必须 NONE/顺序，绝不能被
                    //     伪 RET 化（owner/重定向/RAS 弹）骗过。
                    if (l_pc == 32'h8000_0034) begin
                        if (l_kind !== 2'd0)
                            fail_now($sformatf(
                                "PC34 被伪控制流化：lane%0d kind=%0d（必须 NONE/C.LWSP）",
                                i, l_kind));
                        if (lane_pred_taken[i])
                            fail_now($sformatf(
                                "PC34 C.LWSP 被伪 taken：lane%0d target=0x%08x（必须顺序 +2）",
                                i, lane_pred_target[i*32 +: 32]));
                        if (pred_nxt(l_pc, 1'b0, 32'h0) !== (l_pc + 32'd2))
                            fail_now("PC34 顺序身份错误（内部）");
                    end
                    if (l_kind == 2'd0) begin
                        if (lane_pred_taken[i]) begin
                            n_fake_cf = n_fake_cf + 1;
                            fail_now($sformatf(
                                "非控制流伪 taken：lane%0d pc=0x%08x insn=0x%08x target=0x%08x",
                                i, l_pc, img_insn(l_pc), lane_pred_target[i*32 +: 32]));
                        end
                    end else begin
                        // cond / jal 的直接目标必须等于指令立即数解出的目标
                        if (lane_pred_taken[i] && (l_kind != 2'd3) &&
                            (lane_pred_target[i*32 +: 32] !== (l_pc + cf_imm(l_pc)))) begin
                            n_bad_cf = n_bad_cf + 1;
                            fail_now($sformatf(
                                "直接控制流目标错：lane%0d pc=0x%08x kind=%0d pred=0x%08x imm=0x%08x",
                                i, l_pc, l_kind, lane_pred_target[i*32 +: 32], cf_imm(l_pc)));
                        end
                        // 预测 taken 必须在块尾终止（块内越过 taken ⇒ 取指流损坏）
                        if (lane_pred_taken[i] && (i != tail)) begin
                            n_fake_cf = n_fake_cf + 1;
                            fail_now($sformatf(
                                "预测 taken 未终止块：lane%0d/%0d pc=0x%08x tgt=0x%08x",
                                i, tail, l_pc, lane_pred_target[i*32 +: 32]));
                        end
                    end
                    pnext_l[i] = pred_nxt(l_pc, lane_pred_taken[i], lane_pred_target[i*32 +: 32]);
                    if ((i < 3) && blk_mask[i+1]) begin
                        if (lane_pc[(i+1)*32 +: 32] !== pnext_l[i]) begin
                            n_path_break = n_path_break + 1;
                            fail_now($sformatf(
                                "块内预测流断裂：lane%0d=0x%08x != lane%0d 独立 next=0x%08x（kind=%0d tk=%0d）",
                                i+1, lane_pc[(i+1)*32 +: 32], i, pnext_l[i],
                                l_kind, lane_pred_taken[i]));
                        end
                    end
                end
            end
            if (blk_mask[0] && (blk_next_pc !== pnext_l[tail])) begin
                n_path_break = n_path_break + 1;
                fail_now($sformatf(
                    "块尾独立 next 不一致：blk_next=0x%08x != 尾部 lane%0d 独立 next=0x%08x（pc=0x%08x kind=%0d tk=%0d）",
                    blk_next_pc, tail, pnext_l[tail], lane_pc[tail*32 +: 32],
                    cf_kind(lane_pc[tail*32 +: 32]), lane_pred_taken[tail]));
            end
            if (blk_mask[0] &&
                (blk_taken !== ((cf_kind(lane_pc[tail*32 +: 32]) != 2'd0) &&
                                lane_pred_taken[tail]))) begin
                n_fake_cf = n_fake_cf + 1;
                fail_now($sformatf(
                    "blk_taken 与控制流不符：tail=%0d kind=%0d tk=%0d blk_taken=%0d",
                    tail, cf_kind(lane_pc[tail*32 +: 32]), lane_pred_taken[tail], blk_taken));
            end

            //==================================================================
            // B. 黄金消费 + 更老真实控制流 owner 归因
            //==================================================================
            for (i = 0; i < 4; i = i + 1) begin
                if (blk_mask[i] && !div_need) begin
                    l_pc = lane_pc[i*32 +: 32];
                    if (l_pc === g_pc[g_idx]) begin
                        // ---- 回到/保持在黄金后继 ----
                        if (off_path) begin
                            if (l_pc !== owner_gold_next)
                                fail_now($sformatf(
                                    "错误路径重聚点非法：lane=0x%08x owner=0x%08x gold_next=0x%08x",
                                    l_pc, owner_pc, owner_gold_next));
                            off_path = 1'b0;
                            n_reconverge = n_reconverge + 1;
                        end
                        l_kind = cf_kind(l_pc);
                        l_len  = img_len32(l_pc) ? 32'd4 : 32'd2;
                        // ---- C7：黄金轨迹必须与独立解码自洽（解码错立刻暴露）----
                        if ((g_idx + 1 < g_npc) && (l_kind != 2'd3)) begin
                            l_gn = g_pc[g_idx+1];
                            if (l_kind == 2'd0) begin
                                if (l_gn !== (l_pc + l_len)) begin
                                    n_gold_cf = n_gold_cf + 1;
                                    fail_now($sformatf(
                                        "黄金轨迹与解码不自洽：非控制流 pc=0x%08x next=0x%08x 非顺序 +%0d",
                                        l_pc, l_gn, l_len));
                                end
                            end else if (l_kind == 2'd1) begin
                                if ((l_gn !== (l_pc + cf_imm(l_pc))) &&
                                    (l_gn !== (l_pc + l_len))) begin
                                    n_gold_cf = n_gold_cf + 1;
                                    fail_now($sformatf(
                                        "黄金轨迹与解码不自洽：条件分支 pc=0x%08x next=0x%08x 既非目标 0x%08x 也非顺序 0x%08x",
                                        l_pc, l_gn, l_pc + cf_imm(l_pc), l_pc + l_len));
                                end
                            end else begin // 2'd2 JAL
                                if (l_gn !== (l_pc + cf_imm(l_pc))) begin
                                    n_gold_cf = n_gold_cf + 1;
                                    fail_now($sformatf(
                                        "黄金轨迹与解码不自洽：JAL pc=0x%08x next=0x%08x 目标=0x%08x",
                                        l_pc, l_gn, l_pc + cf_imm(l_pc)));
                                end
                            end
                        end
                        // ---- owner 判定：只有真实控制流的"实际黄金 next ≠ 独立预测 next"
                        //      才建立允许分歧的错误路径；否则后续 PC 偏离立即红 ----
                        if ((l_kind != 2'd0) && (g_idx + 1 < g_npc) &&
                            (pnext_l[i] !== g_pc[g_idx+1])) begin
                            off_path        = 1'b1;
                            owner_pc        = l_pc;
                            owner_pred_next = pnext_l[i];
                            owner_gold_next = g_pc[g_idx+1];
                            n_owner_mispred = n_owner_mispred + 1;
                            $display("OWNER_MISPRED: pc=0x%08x kind=%0d pred_next=0x%08x gold_next=0x%08x idx=%0d",
                                     owner_pc, l_kind, owner_pred_next, owner_gold_next, g_idx);
                        end
                        // ---- 提交训练（taken 由解码类别 + 实际黄金后继独立判定）----
                        l_tk = ((l_kind != 2'd0) && (g_idx + 1 < g_npc)) ?
                               ((g_pc[g_idx+1] !== (l_pc + l_len)) ? 32'd1 : 32'd0) : 32'd0;
                        n_lane_ok = n_lane_ok + 1;
                        commit_push(l_pc, cls_of(l_pc),
                                    l_tk[0],
                                    (g_idx + 1 < g_npc) ? g_pc[g_idx+1] : 32'h0,
                                    {lane_pred_taken[i], lane_pred_selg[i],
                                     lane_pred_ldir[i], lane_pred_gdir[i]},
                                    lane_btb_hit[i], lane_btb_way[i],
                                    lane_ckpt_valid[i], lane_ckpt[i*4 +: 4]);
                        g_idx = g_idx + 1;
                        resync_mode = 1'b0;
                        rs_wait = 0;              // 对齐成功 ⇒ 重新计时（否则跨事件累加会误报）
                    end else begin
                        // ---- 与黄金不一致：**必须**由更老真实控制流 owner 解释 ----
                        if (!off_path) begin
                            n_unexplained = n_unexplained + 1;
                            fail_now($sformatf(
                                "未解释的黄金分歧：lane%0d pc=0x%08x != gold[%0d]=0x%08x，且无更老真实控制流 owner",
                                i, l_pc, g_idx, g_pc[g_idx]));
                        end
                        if (g_pc[g_idx] !== owner_gold_next) begin
                            n_unexplained = n_unexplained + 1;
                            fail_now($sformatf(
                                "重定向目标非法：gold[%0d]=0x%08x != owner(0x%08x) 合法黄金后继=0x%08x",
                                g_idx, g_pc[g_idx], owner_pc, owner_gold_next));
                        end
                        // 当前 lane 必须正是 owner 预测路径上的 flow（块首/块内已核）
                        n_lane_wrongpath = n_lane_wrongpath + 1;
                        if (!div_need) begin
                            n_div = n_div + 1;
                            div_need = 1'b1;
                            div_pc   = owner_gold_next;  // 只回到 owner 的合法黄金后继
                            rs_wait  = 0;
                            blk_ready = 1'b0;            // 重定向前不再吃块（保持/取消由 DUT 处理）
                        end
                        // 检查点随冲刷丢弃 ⇒ 释放（否则检查点泄漏 ⇒ ckpt_full 停顿）
                        if (lane_ckpt_valid[i])
                            commit_push(32'h0, 3'd5, 1'b0, 32'h0, 4'h0, 1'b0, 1'b0,
                                        lane_ckpt_valid[i], lane_ckpt[i*4 +: 4]);
                    end
                end else if (blk_mask[i] && div_need) begin
                    // 错误路径：其检查点随冲刷丢弃 ⇒ 入提交队列（cls=5 = 只释放、不训练），
                    // 否则检查点泄漏 ⇒ 前端 S7 停顿（ckpt_full_stall）
                    n_lane_wrongpath = n_lane_wrongpath + 1;
                    if (lane_ckpt_valid[i])
                        commit_push(32'h0, 3'd5, 1'b0, 32'h0, 4'h0, 1'b0, 1'b0,
                                    lane_ckpt_valid[i], lane_ckpt[i*4 +: 4]);
                end
            end
            pred_next = pnext_l[tail];
        end
    end

    // 发重定向（**下一拍**驱动，保证与交付同拍不冲突）
    always @(negedge clk) begin
        if (rst_n && div_need) begin
            redirect_valid = 1'b1;
            redirect_pc    = div_pc;
            redirect_use_ckpt = 1'b0;
            @(posedge clk);
            @(negedge clk);
            redirect_valid = 1'b0;
            div_need = 1'b0;
            resync_mode = 1'b1;
            pred_next = div_pc;     // 纠偏后预测流从黄金恢复点继续
            rs_wait = 0;
            blk_ready = 1'b1;       // 重定向已消费，恢复块握手
        end else if (rst_n && resync_mode && (g_idx < g_npc)) begin
            rs_wait = rs_wait + 1;
            if (rs_wait > RESYNC_MAX) begin
                $display("FAIL: 重定向后在 %0d 拍内未重新对齐（期望 PC=0x%08x，head=0x%08x）",
                         RESYNC_MAX, g_pc[g_idx], head_pc_o);
                n_unexplained = n_unexplained + 1;
                rs_wait = 0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer w;                            // 提交排空计数
    initial begin
        n_checks = 0;
        g_idx = 0; n_lane_ok = 0; n_lane_wrongpath = 0; n_div = 0;
        n_bad_insn = 0; n_bad_len = 0; n_path_break = 0; pred_next = 32'h0;
        n_fake_cf = 0; n_bad_cf = 0; n_gold_cf = 0;
        n_unexplained = 0; n_grp_seen = 0; resync_mode = 1'b0;
        off_path = 1'b0; owner_pc = 32'h0; owner_pred_next = 32'h0;
        owner_gold_next = 32'h0; n_owner_mispred = 0; n_reconverge = 0;
        cq_wr = 0; cq_rd = 0; cq_cnt = 0; n_cond_commit = 0; n_cond_mis_ref = 0;
        ret_sp = 0; ck_q_cnt = 0;
        div_need = 1'b0; div_pc = 32'h0; rs_wait = 0; check_on = 1'b0;
        train_stop = 1'b0;

        // ---- 初始化 ----
        rst_n = 1'b0; rst_hold = 1'b0;
        redirect_valid = 1'b0; redirect_pc = 32'h0;
        redirect_use_ckpt = 1'b0; redirect_ckpt = 4'h0;
        break_point = 1'b0; fe_stall = 1'b0; blk_ready = 1'b1;
        train_valid = 1'b0; train_pc = 32'h0; train_target = 32'h0;
        train_pred_target = 32'h0;
        train_is_cond = 1'b0; train_taken = 1'b0; train_is_indirect = 1'b0;
        train_is_call = 1'b0; train_is_return = 1'b0;
        train_pred_taken = 1'b0; train_pred_sel_global = 1'b0;
        train_pred_gdir = 1'b0; train_pred_ldir = 1'b0;
        train_pred_valid = 1'b0; train_btb_hit = 1'b0; train_btb_way = 1'b0;
        ckpt_free_valid = 1'b0; ckpt_free_id = 4'h0;
        ras_cmt_push_valid = 1'b0; ras_cmt_pop_valid = 1'b0;
        d2_push_valid = 1'b0; d2_pop_valid = 1'b0;
        d2_push_addr = 32'h0; d2_pop_addr = 32'h0;
        priv = `RV32GC_PRIV_M;
        pmpcfg_i = {N_PMP*8{1'b0}};
        pmpaddr_i = {N_PMP*32{1'b0}};
        l1i_inval_all = 1'b0;
        load_front4_int_image();
        load_front4_int_golden();
        // ---- C0 固定程序/黄金身份：空/短/错程序/错黄金必须立即红 ----
        chk(g_npc == 248, "C0 固定程序黄金必须恰好 248 条提交 PC");
        chk(g_npc <= MAX_GOLD, "C0 黄金条数不得超过 MAX_GOLD");
        chk_eq32(g_pc[0], 32'h8000_0000, "C0 黄金 entry 必须为 0x80000000");
        chk_eq32(g_pc[g_npc-1], 32'h8000_0050, "C0 黄金末 PC 必须为 0x80000050（成功终止身份）");
        gsum_id = 32'h0; gxor_id = 32'h0; pc34n = 0; q2n = 0;
        for (gi_id = 0; gi_id < g_npc; gi_id = gi_id + 1) begin
            gsum_id = gsum_id + g_pc[gi_id];
            gxor_id = gxor_id ^ g_pc[gi_id];
            if (!img_len32(g_pc[gi_id])) begin
                p16_id = img_parcel(g_pc[gi_id]);
                // 所有 Q2 非 CR(funct3!=100) 指令必须解码为 NONE
                if ((p16_id[1:0] == 2'b10) && (p16_id[15:13] != 3'b100)) begin
                    q2n = q2n + 1;
                    chk(cf_kind(g_pc[gi_id]) === 2'd0,
                        $sformatf("C0 Q2 非 CF 解码错：pc=0x%08x parcel=0x%04x",
                                  g_pc[gi_id], p16_id));
                end
            end
            if (g_pc[gi_id] == 32'h8000_0034) begin
                pc34n = pc34n + 1;
                if (gi_id + 1 < g_npc)
                    chk_eq32(g_pc[gi_id+1], 32'h8000_0036,
                             "C0 黄金 0x80000034 后必须顺序到 0x80000036");
            end
        end
        chk_eq32(gsum_id, 32'h0000_1c26, "C0 黄金 PC 和校验（固定程序身份）");
        chk_eq32(gxor_id, 32'h0000_0036, "C0 黄金 PC 异或校验（固定程序身份）");
        chk(q2n > 0, "C0 固定程序必须覆盖至少一条 Q2 非 CR 指令");
        chk(pc34n > 0, "C0 固定程序必须包含 PC=0x80000034（C.LWSP）");
        chk(img_len32(32'h8000_0034) === 1'b0, "C0 PC34 必须是 16 bit");
        p16_id = img_parcel(32'h8000_0034);
        chk((p16_id[1:0] == 2'b10) && (p16_id[15:13] != 3'b100),
            "C0 PC34 必须是 Q2 非 CR 指令（C.LWSP 类）");
        chk(cf_kind(32'h8000_0034) === 2'd0, "C0 PC34 必须解码为 NONE（绝不当 RET）");
        $display("== 集成 TB：程序映像 21 字 + 黄金轨迹 %0d 条（Spike --log-commits）", g_npc);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 复位取指在 XIP（RESET_PC=0x1C00_0000）：先重定向到程序入口（DDR）
        @(negedge clk); redirect_valid = 1'b1; redirect_pc = DDR_BASE;
        @(posedge clk); @(negedge clk); redirect_valid = 1'b0;
        check_on = 1'b1;
        pred_next = g_pc[0];        // 预测流从程序入口开始

        // ---- 跑完整条黄金轨迹（含错误路径纠正）----
        begin : run
            integer c;
            c = 0;
            // 提交队列出队（模拟提交滞后）：每 4 拍训练一条
            fork
                begin : train_loop
                    integer t2;
                    for (t2 = 0; t2 < 200000; t2 = t2 + 1) begin
                        @(posedge clk);
                        if (train_stop) t2 = 200000;          // 退出（下面排空由主流程做）
                        else if (cq_cnt > 0) commit_pop();
                    end
                end
            join_none
            while ((g_idx < g_npc) && (c < 200000)) begin
                @(posedge clk); c = c + 1;
            end
            if (g_idx < g_npc) begin
                $display("FAIL: 黄金轨迹未跑完（%0d/%0d，%0d 拍）", g_idx, g_npc, c);
                $fatal(1, "TB_FRONT4_INTEGRATION 超时");
            end
            $display("== 黄金轨迹已全部覆盖：%0d 条；交付 lane %0d，错误路径 lane %0d，误判事件 %0d",
                     g_npc, n_lane_ok, n_lane_wrongpath, n_div);
        end

        // ---- 排空训练队列（提交滞后）----
        @(posedge clk); @(posedge clk);
        train_stop = 1'b1;
        @(posedge clk); @(posedge clk);
        for (w = 0; w < 64; w = w + 1) begin
            if (cq_cnt > 0) commit_pop();
            else w = 64;
        end
        repeat (4) @(posedge clk);

        // ---- 判据 ----
        $display("== 交叉核对：TB 参照 条件分支 %0d / 方向误判 %0d；硬件 br_total %0d / dir_mis %0d / br_mis %0d / tgt_mis %0d",
                 n_cond_commit, n_cond_mis_ref, bpu_br_total, bpu_dir_mispred,
                 bpu_br_mispred, bpu_target_mispred);
        chk_eq32({16'h0, g_idx}, g_npc, "C1 黄金轨迹必须被逐条覆盖（g_idx == g_npc）");
        chk(n_lane_ok == g_npc, "C1 匹配 lane 数必须等于黄金条数（无重复/无跳条）");
        chk(n_unexplained == 0, "C2/C3 不允许未解释分歧（分歧必须由更老真实控制流 owner 解释）");
        chk(n_bad_insn === 0, "C4 交付 lane 的指令位必须与程序映像逐位一致（含错误路径）");
        chk(n_bad_len  === 0, "C4 交付 lane 的 16/32 位长度必须与程序映像一致");
        chk(n_path_break === 0, "C2 独立预测流必须连续（块首/块内/块尾；禁任意纠偏吞损坏）");
        chk(n_fake_cf === 0, "C2 非控制流不得伪 taken、预测 taken 必须终止块");
        chk(n_bad_cf === 0, "C0 cond/jal 直接目标必须等于指令立即数解码");
        chk(n_gold_cf === 0, "C7 黄金轨迹必须与独立 RV32I/C 解码自洽");
        chk(cnt_fault === 32'd0, "C5 本程序无取指异常（cnt_fault 必须为 0）");
        chk(bpu_ras_repair === 32'd0, "C5 调用/返回结构平衡 ⇒ RAS 修复必须为 0");
        chk(bpu_train_overflow === 32'd0, "C5 训练 FIFO 不得溢出");
        chk_eq32(bpu_br_total, n_cond_commit, "C5 bpu_br_total 必须等于参照模型的条件分支提交数");
        chk_eq32(bpu_br_mispred, n_cond_mis_ref,
                 "C5 bpu_br_mispred 必须等于参照模型的方向误判数");
        $display("== 硬件统计：条件分支 %0d（误判 %0d）、取指请求 %0d、重启 %0d、重定向 %0d",
                 bpu_br_total, bpu_br_mispred, cnt_req, cnt_restart, cnt_redirect);
        $display("== 独立黄金：真实控制流 owner 误预测 %0d、错误路径重聚 %0d",
                 n_owner_mispred, n_reconverge);
        $display("== 交叉核对：lane 指令位坏 %0d / 长度坏 %0d / 预测流断裂 %0d / 伪控制流 %0d / 直接目标错 %0d / 黄金解码错 %0d",
                 n_bad_insn, n_bad_len, n_path_break, n_fake_cf, n_bad_cf, n_gold_cf);
        $display("== 检查项合计 %0d 项全部满足（黄金轨迹 %0d 条 / 0 未解释分歧）",
                 n_checks, g_npc);
        $display("TB_FRONT4_INTEGRATION: PASS");
        $finish;
    end

    // 全局超时兜底
    initial begin
        #(CLK_PERIOD * 2_000_000);
        $display("FAIL: TB 超时");
        $fatal(1, "TB_FRONT4_INTEGRATION 超时");
    end

endmodule
