//==============================================================================
// rtl/front4/ifetch4.v —— F2/F3/F4：预测查表 → L1I 索引/取字 → 读出拼接 + 4 路分组
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/02-pipeline.md §3.2/§3.3/§3.4（F2/F3/F4 逐级定义）、§4.1
//         （前端停顿 S1/S2）、§4.2（4 路取指资源冲突矩阵）、§6.1（重定向类别 A/D）；
//         docs/design/04-predictor.md §2（F2 查表）/§4（BTB、RAS）；
//         docs/design/08-baseline-5stage.md §4.3/§5.1（2A 取指契约：RESET_PC、
//         XIP 旁路、16 bit parcel、跨行拼接、取指 PMP 逐 parcel）。
//
// 【流水线：F1 → F2 → F3 → F4 → 缓冲 → 对齐器】
//   F1 (pc_gen4)：下一个**取指字**地址（字对齐）。
//   F2（本模块 `f2_*`）：持有该字并用它发起预测查表（predictor_top 同步读）。
//   F3（本模块 `f3_*`）：拿到查表结果；发起 L1I 索引/取字请求（或 XIP 直连请求）。
//   F4（本模块 `f4_*`）：数据回拍 —— 把 32 bit 字拆成 2 个 16 bit parcel 压入缓冲。
//   对齐器（组合）：把 parcel 流按 16/32 bit 边界拼成 **≤4 条指令的块** 交给后端。
//   每一级都可停顿（F2 满/F3 满/F4 等数据/缓冲无位），停顿不丢数据、不重复请求。
//
// 【为什么是 parcel 缓冲 + 对齐器，而不是"一拍读 32 B 行"】
//   2A 的 L1I（rtl/cache/l1i.v，**本任务禁改**）是 cs_req/cs_ready/cs_rdata 的
//   **单字（4 B）** 接口，命中 1 拍返回 1 个 32 bit 字。因此本前端把取指做成
//   "逐字顺序流 + parcel 缓冲"：缓冲吸收上游 1 字/拍 的带宽，对齐器在有数据时
//   一拍可以交出 **4 条**指令（跨行/跨字拼接天然成立：缓冲里就是线性 parcel 流）。
//   ⇒ 与 02 §4.2「L1I 1 次读/拍（32 B）」的差距只在**持续带宽**（1 字/拍 vs 32 B/拍）；
//     32 B/拍 L1I 读口属 2B-2/2C（新 L1I）交付项；分组/终止/重定向/XIP 语义同文档。
//     rtl/front4/README.md §4 有完整取舍说明。
//
// 【五条正确性口径（TB 逐条打）】
//   ① **跨行/跨字拼接**：32 bit 指令的两个 parcel 分处两个字时，必须等第二个 parcel
//      到齐才允许交付；未到齐 ⇒ 该 lane 无效、块在它之前终止（"未捕获即失败"）。
//   ② **跳转组终止**：块的**最后一条**必须是"预测跳转"（条件分支方向预测 taken /
//      直接跳转 / 间接跳转有目标），块尾之后立刻重启取指流到预测目标（`restart_*`），
//      并把缓冲里残留的（已越过的顺序）parcel 全部丢弃。
//   ③ **XIP 旁路**：取指字**物理地址**命中 SPI 窗口（PA[31:20]==12'h1C0 ||
//      PA[31:16]==16'h1FE8）⇒ 不查 L1I（`l1i_req_valid=0`），改走直连通路
//      （`unc_req_*`），返回数据按**地址比对**接收（防陈旧响应）。
//   ④ **回退重定向**：`redirect_valid` 一拍内清空所有在途/缓冲状态，重新从
//      `redirect_pc` 取指（epoch 自增 ⇒ 旧在途响应即使回来也被丢弃）。
//   ⑤ **取指 PMP 逐 parcel**：无 X 权限 ⇒ 该 lane 打 fault（cause=1、tval=故障 parcel
//      的 VA）、块在它终止、前端冻结直到重定向（异常由后端在提交点精确触发）。
//
// 组合逻辑风格（AGENT.md §4 红线 3）：只有"流水寄存器/缓冲/统计"用 always，
//   组合逻辑全部用 assign/function（4 个 lane 显式展开，不用 always @(*)）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module ifetch4 #(
    parameter integer BUF_PARCELS = `FRONT4_BUF_PARCELS,     // 16 个 16 bit parcel
    parameter integer PMP_ENTRIES = `RV32GC_PMP_ENTRIES,     // 16
    parameter integer PMP_ENTRY_W = `RV32GC_PMP_ENTRY_W      // 8
) (
    input  wire        clk,
    input  wire        rst_n,

    //==================================================================
    // F1（pc_gen4）接口
    //==================================================================
    input  wire [31:0] fetch_pc,          // 下一个取指字（字对齐）
    input  wire [31:0] head_pc,           // 缓冲头 parcel 地址（块 PC 口径）
    input  wire [1:0]  epoch,             // 当前流 epoch
    input  wire        freeze_in,         // 冻结（下游反压/断点）
    input  wire        redirect_valid,    // 后端重定向（清 fault 保持）
    input  wire [31:0] redirect_pc,
    output wire        pipe_advance,      // 本拍把 F1 的字收进 F2（F1 顺序 +4）
    output wire        head_adv_valid,    // 本拍消费 k 字节
    output wire [4:0]  head_adv_bytes,
    output wire        restart_valid,     // 预测跳转：重启取指流
    output wire [31:0] restart_pc,

    //==================================================================
    // F2：预测查表（predictor_top）
    //==================================================================
    output wire        lu_en,
    output wire [31:0] lu_pc0,
    output wire [31:0] lu_pc1,
    input  wire [`FRONT4_LU_PACK_W-1:0] lu_pack,
    input  wire [31:0] ras_top,
    input  wire        ras_empty,

    //==================================================================
    // 检查点分配（分支推测点）
    //==================================================================
    output wire        ckpt_alloc_valid,
    input  wire [3:0]  ckpt_alloc_id,
    input  wire        ckpt_full,

    //==================================================================
    // MMU（hook，口径同 2A fetch_unit：翻译未就绪不得发请求；Bare 时 en=0 ⇒ PA=VA）
    //==================================================================
    input  wire        sv32_translate_en,
    input  wire        sv32_translate_done,
    input  wire        sv32_translate_fault,
    input  wire [31:0] sv32_translate_paddr,
    output wire        tr_req_valid,
    output wire [31:0] tr_req_va,

    //==================================================================
    // L1I（2A `l1i` 的 cs_* 契约；cacheable 取字）
    //   `l1i_req_addr` = 查表地址（字地址；2A 在 Sv32 下喂**物理地址** ⇒ PIPT）
    //   `l1i_req_line` = 行基址（填充用；32 B 对齐）
    //==================================================================
    output wire        l1i_req_valid,
    output wire [31:0] l1i_req_addr,
    output wire [31:0] l1i_req_line,
    input  wire        l1i_ready,
    input  wire [31:0] l1i_rdata,
    input  wire        l1i_miss,
    input  wire        l1i_uncached,

    //==================================================================
    // XIP 直连通路（uncached 取字；2A 顶层 XIP 直连的同口径）
    //==================================================================
    output wire        unc_req_valid,
    output wire [31:0] unc_req_pa,
    input  wire        unc_rsp_valid,
    input  wire [31:0] unc_rsp_pa,        // 返回字的地址（地址比对，防陈旧响应）
    input  wire [31:0] unc_rsp_data,

    //==================================================================
    // 取指 PMP（复用 rtl/mem/pmp_check.v）
    //==================================================================
    input  wire [1:0]  priv,
    input  wire [PMP_ENTRIES*PMP_ENTRY_W-1:0] pmpcfg_i,
    input  wire [PMP_ENTRIES*32-1:0]          pmpaddr_i,

    //==================================================================
    // 输出：4 路指令块（2B-2 派发接口）
    //==================================================================
    output wire        blk_valid,
    input  wire        blk_ready,
    output wire [3:0]  blk_mask,          // 有效 lane 位图
    output wire [31:0] blk_next_pc,       // 本块之后的取指 PC（预测目标或顺序地址）
    output wire        blk_taken,         // 块尾是"预测跳转"
    output wire [127:0] lane_pc,          // 4 × 32：指令 VA
    output wire [127:0] lane_pa,          // 4 × 32：指令 PA
    output wire [127:0] lane_insn,        // 4 × 32：指令位（16 bit 时右对齐）
    output wire [3:0]  lane_len32,        // 1 = 32 bit 指令
    output wire [11:0] lane_cls,          // 4 × 3：分支类别
    output wire [3:0]  lane_pred_taken,   // 最终预测方向（实际用于块终止的那个）
    output wire [3:0]  lane_pred_selg,    // 选择器选了全局侧（训练/统计携带）
    output wire [3:0]  lane_pred_gdir,    // Gshare 侧方向（训练携带）
    output wire [3:0]  lane_pred_ldir,    // 局部侧方向（训练携带）
    output wire [127:0] lane_pred_target, // 预测目标（taken 时有效）
    output wire [3:0]  lane_btb_hit,
    output wire [3:0]  lane_btb_way,
    output wire [3:0]  lane_btb_cond,
    output wire [3:0]  lane_btb_call,
    output wire [3:0]  lane_btb_ret,
    output wire [127:0] lane_btb_target,
    output wire [3:0]  lane_fault,        // 取指异常（PMP 无 X）
    output wire [19:0] lane_fault_cause,  // 4 × 5
    output wire [127:0] lane_fault_tval,  // 4 × 32（故障 parcel 的 VA）
    output wire [15:0] lane_ckpt,         // 4 × 4：该 lane 分配的检查点 id
    output wire [3:0]  lane_ckpt_valid,

    //==================================================================
    // 统计
    //==================================================================
    output wire [31:0] cnt_grp,
    output wire [31:0] cnt_parcels,
    output wire [31:0] cnt_fault,
    output wire [31:0] cnt_restart,
    output wire [31:0] cnt_stall,
    output wire [31:0] cnt_req        // L1I 取字请求数（含复位后）
);

    //==========================================================================
    // 0. 常量与缓冲条目布局（单点定义）
    //==========================================================================
    localparam [11:0] XIP_HI20_VAL  = `RV32GC_XIP_HI20_VAL;   // 12'h1C0
    localparam [11:0] XIP_HI20_MSK  = `RV32GC_XIP_HI20_MSK;   // 12'hFFF
    localparam [15:0] XIP_ALIAS_HI16= `RV32GC_SPI_HIT_VAL;    // 16'h1FE8
    localparam [1:0]  T_EXEC = 2'd2;                 // pmp_check：2 = execute（端口 2 bit）

    // 缓冲条目：{valid, data[15:0], va[31:0], pa[31:0], pt, pg, pl, ps,
    //            btb_hit, btb_way, btb_cond, btb_call, btb_ret, btb_target[31:0]}
    localparam integer EW_VALID  = 0;
    localparam integer EW_DATA   = 1;                 // [: 1+15]
    localparam integer EW_VA     = 17;                // [: 17+31]
    localparam integer EW_PA     = 49;                // [: 49+31]
    localparam integer EW_PT     = 81;
    localparam integer EW_PG     = 82;
    localparam integer EW_PL     = 83;
    localparam integer EW_PS     = 84;
    localparam integer EW_BH     = 85;
    localparam integer EW_BW     = 86;
    localparam integer EW_BC     = 87;
    localparam integer EW_BK     = 88;
    localparam integer EW_BR     = 89;
    localparam integer EW_BT     = 90;                // [: 90+31]
    localparam integer ENTRY_W   = 122;

    localparam integer BUF_AW    = 5;                 // 32 项（2 个 L1I 行）

    // 分支类别编码
    localparam [2:0] C_NONE  = 3'd0;
    localparam [2:0] C_COND  = 3'd1;
    localparam [2:0] C_DJMP  = 3'd2;
    localparam [2:0] C_INDIR = 3'd3;
    localparam [2:0] C_RET   = 3'd4;
    localparam [2:0] C_DCALL = 3'd5;
    localparam [2:0] C_ICALL = 3'd6;

    //==========================================================================
    // 1. 纯组合 function（先声明后使用；AGENT.md §4 红线 3）
    //==========================================================================
    function [ENTRY_W-1:0] pack_e;
        input              v;
        input [15:0]       d;
        input [31:0]       va;
        input [31:0]       pa;
        input              pt, pg, pl, ps, bh, bw, bc, bk, br;
        input [31:0]       bt;
        begin
            pack_e           = {ENTRY_W{1'b0}};
            pack_e[EW_VALID] = v;
            pack_e[EW_DATA +: 16] = d;
            pack_e[EW_VA   +: 32] = va;
            pack_e[EW_PA   +: 32] = pa;
            pack_e[EW_PT] = pt;  pack_e[EW_PG] = pg;
            pack_e[EW_PL] = pl;  pack_e[EW_PS] = ps;
            pack_e[EW_BH] = bh;  pack_e[EW_BW] = bw;
            pack_e[EW_BC] = bc;  pack_e[EW_BK] = bk; pack_e[EW_BR] = br;
            pack_e[EW_BT +: 32] = bt;
        end
    endfunction

    function e_valid; input [ENTRY_W-1:0] e; begin e_valid = e[EW_VALID]; end endfunction
    function [15:0] e_data; input [ENTRY_W-1:0] e; begin e_data = e[EW_DATA +: 16]; end endfunction
    function [31:0] e_va; input [ENTRY_W-1:0] e; begin e_va = e[EW_VA +: 32]; end endfunction
    function [31:0] e_pa; input [ENTRY_W-1:0] e; begin e_pa = e[EW_PA +: 32]; end endfunction
    function e_pt; input [ENTRY_W-1:0] e; begin e_pt = e[EW_PT]; end endfunction
    function e_pg; input [ENTRY_W-1:0] e; begin e_pg = e[EW_PG]; end endfunction
    function e_pl; input [ENTRY_W-1:0] e; begin e_pl = e[EW_PL]; end endfunction
    function e_ps; input [ENTRY_W-1:0] e; begin e_ps = e[EW_PS]; end endfunction
    function e_bh; input [ENTRY_W-1:0] e; begin e_bh = e[EW_BH]; end endfunction
    function e_bw; input [ENTRY_W-1:0] e; begin e_bw = e[EW_BW]; end endfunction
    function e_bc; input [ENTRY_W-1:0] e; begin e_bc = e[EW_BC]; end endfunction
    function e_bk; input [ENTRY_W-1:0] e; begin e_bk = e[EW_BK]; end endfunction
    function e_br; input [ENTRY_W-1:0] e; begin e_br = e[EW_BR]; end endfunction
    function [31:0] e_bt; input [ENTRY_W-1:0] e; begin e_bt = e[EW_BT +: 32]; end endfunction

    // 分支类别（只看指令自身的位：16 bit 看整条；32 bit 的 opcode/rd/funct3 全在低半）
    function [2:0] br_cls;
        input [15:0] lo;       // 指令低半（= 16 bit 指令本身）
        input [31:0] insn;     // 完整指令位（16 bit 时右对齐）
        input        len32;
        reg          is_link_rd;
        begin
            is_link_rd = (lo[11:7] == 5'd1) || (lo[11:7] == 5'd5);
            if (len32) begin
                case (lo[6:0])
                    7'b1101111: br_cls = is_link_rd ? C_DCALL : C_DJMP;      // JAL
                    7'b1100111: begin                                       // JALR
                        if ((lo[11:7] == 5'd0) && (insn[31:20] == 12'h000) &&
                            ((insn[19:15] == 5'd1) || (insn[19:15] == 5'd5)))
                            br_cls = C_RET;
                        else if (is_link_rd) br_cls = C_ICALL;
                        else                 br_cls = C_INDIR;
                    end
                    7'b1100011: br_cls = C_COND;                            // BRANCH
                    default:    br_cls = C_NONE;
                endcase
            end else begin
                case (lo[1:0])
                    2'b01: case (lo[15:13])
                               3'b001: br_cls = C_DCALL;       // c.jal  (RV32)
                               3'b101: br_cls = C_DJMP;        // c.j
                               3'b110, 3'b111: br_cls = C_COND; // c.beqz / c.bnez
                               default: br_cls = C_NONE;
                           endcase
                    2'b10: begin
                               if (lo[12] && (lo[11:7] != 5'd0) && (lo[6:2] == 5'd0))
                                   br_cls = C_ICALL;           // c.jalr
                               else if (!lo[12] && (lo[11:7] != 5'd0) && (lo[6:2] == 5'd0))
                                   br_cls = ((lo[11:7] == 5'd1) || (lo[11:7] == 5'd5))
                                            ? C_RET : C_INDIR; // c.jr
                               else br_cls = C_NONE;
                           end
                    default: br_cls = C_NONE;
                endcase
            end
        end
    endfunction

    // 直接跳转/条件分支的目标 = PC + imm（从指令位直接算，不依赖 BTB）
    function [31:0] dir_target;
        input [31:0] pc;
        input [15:0] lo;
        input [31:0] insn;
        input        len32;
        reg   [31:0] imm;
        begin
            imm = 32'h0;
            if (len32) begin
                if (lo[6:0] == 7'b1101111) begin            // JAL（J 型）
                    imm = {{11{insn[31]}}, insn[31], insn[19:12], insn[20],
                           insn[30:21], 1'b0};
                end else if (lo[6:0] == 7'b1100011) begin   // BRANCH（B 型）
                    imm = {{19{insn[31]}}, insn[31], insn[7], insn[30:25],
                           insn[11:8], 1'b0};
                end
            end else begin
                if (lo[1:0] == 2'b01) begin
                    if (lo[15:13] == 3'b101 || lo[15:13] == 3'b001) begin   // c.j / c.jal
                        imm = {{20{lo[12]}}, lo[12], lo[8], lo[10:9], lo[6],
                               lo[7], lo[2], lo[11], lo[5:3], 1'b0};
                    end else if (lo[15:13] == 3'b110 || lo[15:13] == 3'b111) begin // c.beqz/bnez
                        imm = {{23{lo[12]}}, lo[12], lo[6:5], lo[2],
                               lo[11:10], lo[4:3], 1'b0};
                    end
                end
            end
            dir_target = pc + imm;
        end
    endfunction

    //==========================================================================
    // 2. parcel 缓冲（16 × 122 bit ≈ 2 K 触发器：前端在途状态，不是"大表"）
    //==========================================================================
    reg [ENTRY_W-1:0] buf_q [0:BUF_PARCELS-1];

    reg [BUF_AW-1:0]  buf_head_q;      // 头指针（下一个待消费 parcel）
    reg [BUF_AW:0]    buf_cnt_q;       // 有效 parcel 数（0..16）
    reg [31:0]        push_from_q;     // 下一个待压入 parcel 的地址（流内唯一赋值点）

    // 缓冲读：**直接索引存储器**（不写"function 内部读存储器"——iverilog 12.0 对该
    //   形态存在组合求值缺陷，见 predictor_top.v 检查点表的同款说明与实测记录）
    //==========================================================================
    // 3. 流水寄存器（F2/F3/F4）与推进条件
    //==========================================================================
    reg              f2_v_q;
    reg  [31:0]      f2_va_q;
    reg  [1:0]       f2_ep_q;

    reg              f3_v_q;
    reg  [31:0]      f3_va_q;
    reg  [1:0]       f3_ep_q;
    reg  [`FRONT4_LU_PACK_W-1:0] f3_pk_q;

    reg              f4_v_q;
    reg  [31:0]      f4_va_q;
    reg  [31:0]      f4_pa_q;
    reg  [1:0]       f4_ep_q;
    reg  [`FRONT4_LU_PACK_W-1:0] f4_pk_q;
    reg              f4_xip_q;

    reg              fault_hold_q;             // 取指异常后冻结直到重定向

    // ---- F4：数据到手 ----
    wire f4_rsp_ok   = f4_v_q ? (f4_xip_q ? (unc_rsp_valid && (unc_rsp_pa == f4_pa_q))
                                          : l1i_ready) : 1'b0;
    wire [31:0] f4_rsp_data = f4_xip_q ? unc_rsp_data : l1i_rdata;
    wire f4_free     = ~f4_v_q | f4_rsp_ok;

    // ---- F3：翻译是否完成（hook；Bare 时恒完成）----
    wire f3_tr_pending = sv32_translate_en & ~sv32_translate_done;
    wire f3_move       = f3_v_q & f4_free & ~f3_tr_pending;
    wire f3_free       = ~f3_v_q | f3_move;

    // ---- F2：查表结果随字一起下移 ----
    wire f2_move       = f2_v_q & f3_free;
    wire f2_free       = ~f2_v_q | f2_move;

    // ---- 缓冲余量（**入场预约**口径）----
    //   在途的每一个流水级（F2/F3/F4）都可能再压入 **2 个 parcel**，因此接受新字时
    //   必须把"在途全部 + 本字"一起预约；否则缓冲会被在途字挤爆、push_idx 回绕覆盖
    //   缓冲头（TB 的 C1 反压场景就是靠这条打出了该缺陷）。
    wire [4:0] inflight_words = {4'b0, f2_v_q} + {4'b0, f3_v_q} + {4'b0, f4_v_q};
    wire [5:0] room_need_parcels = 6'd2 * ({1'b0, inflight_words} + 6'd1);
    wire       buf_room  = ({1'b0, buf_cnt_q} + room_need_parcels) <= BUF_PARCELS;

    wire freeze_all = freeze_in | fault_hold_q;
    wire f1_accept  = ~freeze_all & f2_free & buf_room & ~redirect_valid;

    assign pipe_advance = f1_accept;

    // ---- 查表请求（F2 持有地址期间持续发；结果下一拍有效并入 f3_pk_q）----
    assign lu_en  = f2_v_q;
    assign lu_pc0 = f2_va_q;
    assign lu_pc1 = f2_va_q + 32'd2;

    // ---- MMU 翻译请求（hook）----
    assign tr_req_valid = f3_v_q & sv32_translate_en;
    assign tr_req_va    = f3_va_q;

    // F3 阶段的有效 PA（翻译开启时用翻译结果；Bare 时 = VA）与 XIP 判定
    wire [31:0] f3_pa_w     = sv32_translate_en ? sv32_translate_paddr : f3_va_q;
    wire        f3_is_xip_w = ((f3_pa_w[31:20] & XIP_HI20_MSK) == XIP_HI20_VAL) |
                              (f3_pa_w[31:16] == XIP_ALIAS_HI16);

    // ---- F4：发起 L1I/直连取字请求（持有直到数据回）----
    wire f4_is_xip = ((f4_pa_q[31:20] & XIP_HI20_MSK) == XIP_HI20_VAL) |
                     (f4_pa_q[31:16] == XIP_ALIAS_HI16);

    assign l1i_req_valid = f4_v_q & ~f4_is_xip & ~f4_rsp_ok & ~fault_hold_q & ~redirect_valid;
    assign l1i_req_addr  = f4_pa_q;                        // PIPT：查表地址 = PA
    assign l1i_req_line  = {f4_pa_q[31:5], 5'b00000};      // 行基址（填充用）
    assign unc_req_valid = f4_v_q &  f4_is_xip & ~f4_rsp_ok & ~fault_hold_q & ~redirect_valid;
    assign unc_req_pa    = f4_pa_q;

    //==========================================================================
    // 4. F4 → parcel 缓冲（过滤：流起点、epoch、重启拍不压）
    //==========================================================================
    wire [31:0] p_va0 = f4_va_q;
    wire [31:0] p_va1 = f4_va_q + 32'd2;
    wire [31:0] p_pa0 = f4_pa_q;
    wire [31:0] p_pa1 = f4_pa_q + 32'd2;

    wire push_lo_ok = f4_v_q & f4_rsp_ok & (f4_ep_q == epoch) & (p_va0 >= push_from_q) &
                      ((buf_cnt_q + 5'd1) <= BUF_PARCELS);
    //   ★ 两个 parcel 各自与 `push_from_q` 比（**不要**给高半加"低半也必须压"的前置条件：
    //     流首落在字高半时低半本来就不该压，加前置条件会把流首 parcel 一起丢掉）。
    wire push_hi_ok = f4_v_q & f4_rsp_ok & (f4_ep_q == epoch) &
                      (p_va1 >= push_from_q) & ((buf_cnt_q + 5'd2) <= BUF_PARCELS);

    // 队尾指针（= head + cnt）与两个 parcel 的**实际写入下标**：
    //   ★ 高半的下标必须紧随"低半是否真的压了"（流首落在字高半时低半不压 ⇒ 高半就写在
    //     队尾本身）。写死 `push_idx0 + 1` 会在奇 parcel 流首时把第一个 parcel 写到
    //     队尾 +1（TB 的 C5 重定向到 2 B 对齐地址打出的缺陷）。
    wire [BUF_AW-1:0] push_idx0 = buf_head_q + buf_cnt_q[BUF_AW-1:0];
    wire [BUF_AW-1:0] push_idx_hi = push_idx0 + {4'b0, push_lo_ok};

    wire [4:0] push_num = {4'b0, push_lo_ok} + {4'b0, push_hi_ok};

    //==========================================================================
    // 5. 对齐器：从缓冲头开始拼 ≤4 条指令（4 个 lane 显式展开）
    //    偏移链：o0=0；o(k+1)=o(k)+（lane k 是 32 bit ? 2 : 1）——无组合环
    //==========================================================================
    //   ★ **有效窗口口径（关键正确性）**：缓冲只有 [head, head+cnt) 内的条目属于**当前
    //     流**；冲刷（重启/重定向）只把 head/cnt 归零、不清数据（省 32×122 触发器），
    //     因此所有有效性判断都必须再与 `buf_cnt_q` 比较——否则 flush 之后的对齐器会
    //     把"上一次流的残留条目"当成有效数据交付（TB 的 C3 跳转重启用例打出过）。
    wire [4:0] o0 = 5'd0;
    wire [ENTRY_W-1:0] e0  = buf_q[buf_head_q];
    wire [ENTRY_W-1:0] e0h = buf_q[buf_head_q + 5'd1];
    wire in_win0 = (5'd0 < buf_cnt_q);
    wire in_win1 = (5'd1 < buf_cnt_q);
    wire [15:0] l0_lo = e_data(e0);
    wire l0_len32 = (l0_lo[1:0] == 2'b11);
    wire l0_pres  = in_win0 & e_valid(e0) & (~l0_len32 | (in_win1 & e_valid(e0h)));

    wire [4:0] o1 = o0 + (l0_len32 ? 5'd2 : 5'd1);
    wire [ENTRY_W-1:0] e1  = buf_q[buf_head_q + o1[BUF_AW-1:0]];
    wire [ENTRY_W-1:0] e1h = buf_q[buf_head_q + o1[BUF_AW-1:0] + 5'd1];
    wire in_win1a = (o1 < {1'b0, buf_cnt_q});
    wire in_win1b = ((o1 + 5'd1) < {1'b0, buf_cnt_q});
    wire [15:0] l1_lo = e_data(e1);
    wire l1_len32 = (l1_lo[1:0] == 2'b11);
    wire l1_pres  = l0_pres & in_win1a & e_valid(e1) &
                    (~l1_len32 | (in_win1b & e_valid(e1h)));

    wire [4:0] o2 = o1 + (l1_len32 ? 5'd2 : 5'd1);
    wire [ENTRY_W-1:0] e2  = buf_q[buf_head_q + o2[BUF_AW-1:0]];
    wire [ENTRY_W-1:0] e2h = buf_q[buf_head_q + o2[BUF_AW-1:0] + 5'd1];
    wire in_win2a = (o2 < {1'b0, buf_cnt_q});
    wire in_win2b = ((o2 + 5'd1) < {1'b0, buf_cnt_q});
    wire [15:0] l2_lo = e_data(e2);
    wire l2_len32 = (l2_lo[1:0] == 2'b11);
    wire l2_pres  = l1_pres & in_win2a & e_valid(e2) &
                    (~l2_len32 | (in_win2b & e_valid(e2h)));

    wire [4:0] o3 = o2 + (l2_len32 ? 5'd2 : 5'd1);
    wire [ENTRY_W-1:0] e3  = buf_q[buf_head_q + o3[BUF_AW-1:0]];
    wire [ENTRY_W-1:0] e3h = buf_q[buf_head_q + o3[BUF_AW-1:0] + 5'd1];
    wire in_win3a = (o3 < {1'b0, buf_cnt_q});
    wire in_win3b = ((o3 + 5'd1) < {1'b0, buf_cnt_q});
    wire [15:0] l3_lo = e_data(e3);
    wire l3_len32 = (l3_lo[1:0] == 2'b11);
    wire l3_pres  = l2_pres & in_win3a & e_valid(e3) &
                    (~l3_len32 | (in_win3b & e_valid(e3h)));

    // ---- 指令位/类别/目标 ----
    wire [31:0] l0_insn = l0_len32 ? {e_data(e0h), e_data(e0)} : {16'h0, e_data(e0)};
    wire [31:0] l1_insn = l1_len32 ? {e_data(e1h), e_data(e1)} : {16'h0, e_data(e1)};
    wire [31:0] l2_insn = l2_len32 ? {e_data(e2h), e_data(e2)} : {16'h0, e_data(e2)};
    wire [31:0] l3_insn = l3_len32 ? {e_data(e3h), e_data(e3)} : {16'h0, e_data(e3)};

    wire [2:0] l0_cls = l0_pres ? br_cls(l0_lo, l0_insn, l0_len32) : C_NONE;
    wire [2:0] l1_cls = l1_pres ? br_cls(l1_lo, l1_insn, l1_len32) : C_NONE;
    wire [2:0] l2_cls = l2_pres ? br_cls(l2_lo, l2_insn, l2_len32) : C_NONE;
    wire [2:0] l3_cls = l3_pres ? br_cls(l3_lo, l3_insn, l3_len32) : C_NONE;

    wire [31:0] l0_dtgt = dir_target(e_va(e0), l0_lo, l0_insn, l0_len32);
    wire [31:0] l1_dtgt = dir_target(e_va(e1), l1_lo, l1_insn, l1_len32);
    wire [31:0] l2_dtgt = dir_target(e_va(e2), l2_lo, l2_insn, l2_len32);
    wire [31:0] l3_dtgt = dir_target(e_va(e3), l3_lo, l3_insn, l3_len32);

    // 预测方向：条件分支取锦标赛投票；跳转/调用"恒 taken"（间接/返回要有目标预测才算）
    wire l0_dirt = (l0_cls == C_COND)  ? e_pt(e0)  :
                   (l0_cls == C_DJMP)  ? 1'b1      :
                   (l0_cls == C_DCALL) ? 1'b1      :
                   (l0_cls == C_RET)   ? (~ras_empty | e_bh(e0))  :
                   (l0_cls == C_INDIR) ? e_bh(e0)  :
                   (l0_cls == C_ICALL) ? e_bh(e0)  : 1'b0;
    wire l1_dirt = (l1_cls == C_COND)  ? e_pt(e1)  :
                   (l1_cls == C_DJMP)  ? 1'b1      :
                   (l1_cls == C_DCALL) ? 1'b1      :
                   (l1_cls == C_RET)   ? (~ras_empty | e_bh(e1))  :
                   (l1_cls == C_INDIR) ? e_bh(e1)  :
                   (l1_cls == C_ICALL) ? e_bh(e1)  : 1'b0;
    wire l2_dirt = (l2_cls == C_COND)  ? e_pt(e2)  :
                   (l2_cls == C_DJMP)  ? 1'b1      :
                   (l2_cls == C_DCALL) ? 1'b1      :
                   (l2_cls == C_RET)   ? (~ras_empty | e_bh(e2))  :
                   (l2_cls == C_INDIR) ? e_bh(e2)  :
                   (l2_cls == C_ICALL) ? e_bh(e2)  : 1'b0;
    wire l3_dirt = (l3_cls == C_COND)  ? e_pt(e3)  :
                   (l3_cls == C_DJMP)  ? 1'b1      :
                   (l3_cls == C_DCALL) ? 1'b1      :
                   (l3_cls == C_RET)   ? (~ras_empty | e_bh(e3))  :
                   (l3_cls == C_INDIR) ? e_bh(e3)  :
                   (l3_cls == C_ICALL) ? e_bh(e3)  : 1'b0;

    // 预测目标：条件/直接跳转 = PC+imm；返回 = RAS 顶（空则 BTB）；间接 = BTB
    wire [31:0] l0_tgt = (l0_cls == C_COND || l0_cls == C_DJMP || l0_cls == C_DCALL)
                         ? l0_dtgt : ((l0_cls == C_RET) ? (ras_empty ? e_bt(e0) : ras_top)
                                                        : e_bt(e0));
    wire [31:0] l1_tgt = (l1_cls == C_COND || l1_cls == C_DJMP || l1_cls == C_DCALL)
                         ? l1_dtgt : ((l1_cls == C_RET) ? (ras_empty ? e_bt(e1) : ras_top)
                                                        : e_bt(e1));
    wire [31:0] l2_tgt = (l2_cls == C_COND || l2_cls == C_DJMP || l2_cls == C_DCALL)
                         ? l2_dtgt : ((l2_cls == C_RET) ? (ras_empty ? e_bt(e2) : ras_top)
                                                        : e_bt(e2));
    wire [31:0] l3_tgt = (l3_cls == C_COND || l3_cls == C_DJMP || l3_cls == C_DCALL)
                         ? l3_dtgt : ((l3_cls == C_RET) ? (ras_empty ? e_bt(e3) : ras_top)
                                                        : e_bt(e3));

    //==========================================================================
    // 6. 跨页规则（02 §3.1：本拍取指块不跨页）
    //   · lane 起始落在另一页 ⇒ 该 lane 不属本块（下一块从它开始）
    //   · lane 结束跨到下页 ⇒ 该 lane 属本块，但块在它之后终止
    //==========================================================================
    wire [31:0] head_page = {head_pc[31:12]};

    wire [31:0] l0_va = e_va(e0);
    wire [31:0] l1_va = e_va(e1);
    wire [31:0] l2_va = e_va(e2);
    wire [31:0] l3_va = e_va(e3);

    wire l0_pg_bad = (l0_va[31:12] != head_page);
    wire l1_pg_bad = (l1_va[31:12] != head_page);
    wire l2_pg_bad = (l2_va[31:12] != head_page);
    wire l3_pg_bad = (l3_va[31:12] != head_page);

    wire [31:0] l0_end = e_va(e0) + (l0_len32 ? 32'd4 : 32'd2) - 32'd1;
    wire [31:0] l1_end = e_va(e1) + (l1_len32 ? 32'd4 : 32'd2) - 32'd1;
    wire [31:0] l2_end = e_va(e2) + (l2_len32 ? 32'd4 : 32'd2) - 32'd1;
    wire [31:0] l3_end = e_va(e3) + (l3_len32 ? 32'd4 : 32'd2) - 32'd1;

    wire l0_pg_end = (l0_end[31:12] != head_page);
    wire l1_pg_end = (l1_end[31:12] != head_page);
    wire l2_pg_end = (l2_end[31:12] != head_page);
    wire l3_pg_end = (l3_end[31:12] != head_page);

    //==========================================================================
    // 7. 取指 PMP（逐 parcel；8 个检查点 = 4 lane × 2 parcel）
    //==========================================================================
    wire [8*32-1:0] chk_pa;
    wire [7:0]      chk_en;
    wire [7:0]      chk_allow;
    wire [8*5-1:0]  chk_cause;

    wire l0_pg_bad_eq0 = ~l0_pg_bad;
    wire l1_pg_bad_eq0 = ~l1_pg_bad;
    wire l2_pg_bad_eq0 = ~l2_pg_bad;
    wire l3_pg_bad_eq0 = ~l3_pg_bad;

    assign chk_en[0] = l0_pres & l0_pg_bad_eq0;
    assign chk_en[1] = l0_pres & l0_len32 & l0_pg_bad_eq0;
    assign chk_en[2] = l1_pres & l1_pg_bad_eq0;
    assign chk_en[3] = l1_pres & l1_len32 & l1_pg_bad_eq0;
    assign chk_en[4] = l2_pres & l2_pg_bad_eq0;
    assign chk_en[5] = l2_pres & l2_len32 & l2_pg_bad_eq0;
    assign chk_en[6] = l3_pres & l3_pg_bad_eq0;
    assign chk_en[7] = l3_pres & l3_len32 & l3_pg_bad_eq0;

    assign chk_pa[0*32 +: 32] = e_pa(e0);
    assign chk_pa[1*32 +: 32] = e_pa(e0) + 32'd2;
    assign chk_pa[2*32 +: 32] = e_pa(e1);
    assign chk_pa[3*32 +: 32] = e_pa(e1) + 32'd2;
    assign chk_pa[4*32 +: 32] = e_pa(e2);
    assign chk_pa[5*32 +: 32] = e_pa(e2) + 32'd2;
    assign chk_pa[6*32 +: 32] = e_pa(e3);
    assign chk_pa[7*32 +: 32] = e_pa(e3) + 32'd2;

    genvar gc;
    generate
        for (gc = 0; gc < 8; gc = gc + 1) begin : g_chk
            pmp_check #(
                .PMP_ENTRIES(PMP_ENTRIES)
            ) u_pmp (
                .clk(clk), .rst_n(rst_n),
                .cfg_i(pmpcfg_i), .addr_i(pmpaddr_i),
                .acc_pa_i(chk_pa[gc*32 +: 32]),
                .acc_bytes_i(5'd2),
                .acc_priv_i(priv),
                .acc_type_i(T_EXEC),
                .allow_o(chk_allow[gc]),
                .fault_cause_o(chk_cause[gc*5 +: 5]),
                .hit_o(), .hit_idx_o(), .denied_by_full_o()
            );
        end
    endgenerate

    wire l0_fault = (chk_en[0] & ~chk_allow[0]) | (chk_en[1] & ~chk_allow[1]);
    wire l1_fault = (chk_en[2] & ~chk_allow[2]) | (chk_en[3] & ~chk_allow[3]);
    wire l2_fault = (chk_en[4] & ~chk_allow[4]) | (chk_en[5] & ~chk_allow[5]);
    wire l3_fault = (chk_en[6] & ~chk_allow[6]) | (chk_en[7] & ~chk_allow[7]);

    //==========================================================================
    // 8. 块组装：有效链 + 终止条件 + next_pc
    //==========================================================================
    wire l0_v = l0_pres & ~l0_pg_bad;
    wire l1_v = l1_pres & ~l1_pg_bad;
    wire l2_v = l2_pres & ~l2_pg_bad;
    wire l3_v = l3_pres & ~l3_pg_bad;

    // 终止：① 预测跳转 ② 跨页尾 ③ 取指异常
    wire s0 = l0_v & (l0_dirt | l0_pg_end | l0_fault);
    wire s1 = l1_v & (l1_dirt | l1_pg_end | l1_fault);
    wire s2 = l2_v & (l2_dirt | l2_pg_end | l2_fault);
    wire s3 = l3_v & (l3_dirt | l3_pg_end | l3_fault);

    wire m0 = l0_v;
    wire m1 = m0 & ~s0 & l1_v;
    wire m2 = m1 & ~s1 & l2_v;
    wire m3 = m2 & ~s2 & l3_v;

    wire [2:0] l0_bytes = l0_len32 ? 3'd4 : 3'd2;
    wire [2:0] l1_bytes = l1_len32 ? 3'd4 : 3'd2;
    wire [2:0] l2_bytes = l2_len32 ? 3'd4 : 3'd2;
    wire [2:0] l3_bytes = l3_len32 ? 3'd4 : 3'd2;

    wire [4:0] grp_bytes = {2'b0, (m0 ? l0_bytes : 3'd0)} +
                           {2'b0, (m1 ? l1_bytes : 3'd0)} +
                           {2'b0, (m2 ? l2_bytes : 3'd0)} +
                           {2'b0, (m3 ? l3_bytes : 3'd0)};
    wire [4:0] grp_parc  = {3'b0, m0} + {3'b0, m1} + {3'b0, m2} + {3'b0, m3} +
                           {3'b0, m0 & l0_len32} + {3'b0, m1 & l1_len32} +
                           {3'b0, m2 & l2_len32} + {3'b0, m3 & l3_len32};

    wire        grp_taken = (m0 & l0_dirt) | (m1 & l1_dirt) |
                            (m2 & l2_dirt) | (m3 & l3_dirt);
    wire [31:0] grp_tgt = m3 ? l3_tgt : m2 ? l2_tgt : m1 ? l1_tgt : l0_tgt;
    wire        grp_fault = (m0 & l0_fault) | (m1 & l1_fault) |
                            (m2 & l2_fault) | (m3 & l3_fault);

    // "还能长大吗"：下一个待消费 parcel 已在缓冲 / 本拍压入会提供它 / F4 本拍到数据
    wire [4:0] grp_parc5 = grp_parc;
    wire [4:0] next_off_v = (o0 + grp_parc5);      // 已消费 parcel 数 = 下一个 lane 起点偏移
    wire [ENTRY_W-1:0] next_parcel_e = buf_q[buf_head_q + next_off_v[BUF_AW-1:0]];
    wire        next_parcel_v = (next_off_v < {1'b0, buf_cnt_q}) & e_valid(next_parcel_e);
    wire [31:0] next_va       = head_pc + {27'b0, grp_bytes};
    wire        push_gives_next = (push_lo_ok & (p_va0 == next_va)) |
                                  (push_hi_ok & (p_va1 == next_va));
    wire        can_grow = next_parcel_v | push_gives_next | f4_rsp_ok;

    wire [3:0] grp_mask = {m3, m2, m1, m0};
    wire       blk_term = s0 | s1 | s2 | s3;
    wire       blk_ready_int = (grp_mask != 4'h0) & (m3 | blk_term | ~can_grow);
    wire       ckpt_stall = blk_ready_int & grp_taken & ckpt_full;

    assign blk_valid    = blk_ready_int & ~ckpt_stall & ~redirect_valid & ~fault_hold_q;
    assign blk_mask     = grp_mask;
    assign blk_taken    = grp_taken & ~ckpt_stall;
    assign blk_next_pc  = grp_taken ? grp_tgt : next_va;

    wire blk_fire = blk_valid & blk_ready;

    assign head_adv_valid = blk_fire;
    assign head_adv_bytes = grp_bytes;

    assign restart_valid = blk_fire & grp_taken;
    assign restart_pc    = grp_tgt;

    assign ckpt_alloc_valid = blk_fire & grp_taken;

    //==========================================================================
    // 9. 输出 lane 明细
    //==========================================================================
    assign lane_pc[31:0]    = e_va(e0);
    assign lane_pc[63:32]   = e_va(e1);
    assign lane_pc[95:64]   = e_va(e2);
    assign lane_pc[127:96]  = e_va(e3);

    assign lane_pa[31:0]    = e_pa(e0);
    assign lane_pa[63:32]   = e_pa(e1);
    assign lane_pa[95:64]   = e_pa(e2);
    assign lane_pa[127:96]  = e_pa(e3);

    assign lane_insn[31:0]   = l0_insn;
    assign lane_insn[63:32]  = l1_insn;
    assign lane_insn[95:64]  = l2_insn;
    assign lane_insn[127:96] = l3_insn;

    assign lane_len32 = {l3_len32, l2_len32, l1_len32, l0_len32};

    assign lane_cls[2:0]   = l0_cls;
    assign lane_cls[5:3]   = l1_cls;
    assign lane_cls[8:6]   = l2_cls;
    assign lane_cls[11:9]  = l3_cls;

    assign lane_pred_taken = {l3_dirt, l2_dirt, l1_dirt, l0_dirt};
    assign lane_pred_selg  = {e_ps(e3), e_ps(e2), e_ps(e1), e_ps(e0)};
    assign lane_pred_gdir  = {e_pg(e3), e_pg(e2), e_pg(e1), e_pg(e0)};
    assign lane_pred_ldir  = {e_pl(e3), e_pl(e2), e_pl(e1), e_pl(e0)};

    assign lane_pred_target[31:0]   = l0_tgt;
    assign lane_pred_target[63:32]  = l1_tgt;
    assign lane_pred_target[95:64]  = l2_tgt;
    assign lane_pred_target[127:96] = l3_tgt;

    assign lane_btb_hit  = {e_bh(e3), e_bh(e2), e_bh(e1), e_bh(e0)};
    assign lane_btb_way  = {e_bw(e3), e_bw(e2), e_bw(e1), e_bw(e0)};
    assign lane_btb_cond = {e_bc(e3), e_bc(e2), e_bc(e1), e_bc(e0)};
    assign lane_btb_call = {e_bk(e3), e_bk(e2), e_bk(e1), e_bk(e0)};
    assign lane_btb_ret  = {e_br(e3), e_br(e2), e_br(e1), e_br(e0)};

    assign lane_btb_target[31:0]   = e_bt(e0);
    assign lane_btb_target[63:32]  = e_bt(e1);
    assign lane_btb_target[95:64]  = e_bt(e2);
    assign lane_btb_target[127:96] = e_bt(e3);

    assign lane_fault = {l3_fault, l2_fault, l1_fault, l0_fault};

    assign lane_fault_cause[4:0]   = (chk_en[0] & ~chk_allow[0]) ? chk_cause[0*5 +: 5]
                                                                 : chk_cause[1*5 +: 5];
    assign lane_fault_cause[9:5]   = (chk_en[2] & ~chk_allow[2]) ? chk_cause[2*5 +: 5]
                                                                 : chk_cause[3*5 +: 5];
    assign lane_fault_cause[14:10] = (chk_en[4] & ~chk_allow[4]) ? chk_cause[4*5 +: 5]
                                                                 : chk_cause[5*5 +: 5];
    assign lane_fault_cause[19:15] = (chk_en[6] & ~chk_allow[6]) ? chk_cause[6*5 +: 5]
                                                                 : chk_cause[7*5 +: 5];

    //   故障 tval = **故障 parcel 的 VA**（与 2A 取指口径一致：逐 parcel 检查）
    assign lane_fault_tval[31:0]   = e_va(e0) +
                                     ((chk_en[0] & ~chk_allow[0]) ? 32'd0 : 32'd2);
    assign lane_fault_tval[63:32]  = e_va(e1) + ((chk_en[2] & ~chk_allow[2]) ? 32'd0 : 32'd2);
    assign lane_fault_tval[95:64]  = e_va(e2) + ((chk_en[4] & ~chk_allow[4]) ? 32'd0 : 32'd2);
    assign lane_fault_tval[127:96] = e_va(e3) + ((chk_en[6] & ~chk_allow[6]) ? 32'd0 : 32'd2);

    assign lane_ckpt_valid = {m3, m2, m1, m0} & {4{grp_taken}};
    assign lane_ckpt[3:0]   = ckpt_alloc_id;
    assign lane_ckpt[7:4]   = ckpt_alloc_id;
    assign lane_ckpt[11:8]  = ckpt_alloc_id;
    assign lane_ckpt[15:12] = ckpt_alloc_id;

    //==========================================================================
    // 10. 时序：F2/F3/F4 推进、缓冲写入/消费、fault 保持、统计
    //==========================================================================
    reg [31:0] c_grp_q, c_parc_q, c_fault_q, c_restart_q, c_stall_q, c_req_q;

    integer bi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_v_q <= 1'b0; f2_va_q <= 32'h0; f2_ep_q <= 2'b0;
            f3_v_q <= 1'b0; f3_va_q <= 32'h0; f3_ep_q <= 2'b0;
            f3_pk_q <= {`FRONT4_LU_PACK_W{1'b0}};
            f4_v_q <= 1'b0; f4_va_q <= 32'h0; f4_pa_q <= 32'h0; f4_ep_q <= 2'b0;
            f4_pk_q <= {`FRONT4_LU_PACK_W{1'b0}}; f4_xip_q <= 1'b0;
            buf_head_q <= {BUF_AW{1'b0}};
            buf_cnt_q  <= {(BUF_AW+1){1'b0}};
            push_from_q<= `RV32GC_RESET_PC;
            fault_hold_q <= 1'b0;
            c_grp_q <= 32'h0; c_parc_q <= 32'h0; c_fault_q <= 32'h0;
            c_restart_q <= 32'h0; c_stall_q <= 32'h0; c_req_q <= 32'h0;
            for (bi = 0; bi < BUF_PARCELS; bi = bi + 1)
                buf_q[bi] <= {ENTRY_W{1'b0}};
        end else if (redirect_valid) begin
            // ---- 回退重定向：清空所有在途与缓冲，从 redirect_pc 重新开始 ----
            f2_v_q <= 1'b0;
            f3_v_q <= 1'b0;
            f4_v_q <= 1'b0;
            buf_head_q  <= {BUF_AW{1'b0}};
            buf_cnt_q   <= {(BUF_AW+1){1'b0}};
            push_from_q <= redirect_pc;
            fault_hold_q<= 1'b0;
        end else begin
            // ---- 缓冲记账（**单点**：消费出块 - 压入 + 重启清零）----
            //   ★ 计数必须"压入 +、消费 -"两侧都在同一处更新：只减不加会让缓冲永远
            //     处于"空"状态、push_idx 停在缓冲头 ⇒ 新数据反复覆盖头（TB C1 反压
            //     场景打出的缺陷）。
            if (restart_valid) begin
                // 顺序取指已越过跳转 ⇒ 缓冲残留全是错误路径，全丢
                buf_head_q  <= {BUF_AW{1'b0}};
                buf_cnt_q   <= {(BUF_AW+1){1'b0}};
                push_from_q <= restart_pc;
            end else begin
                buf_cnt_q <= buf_cnt_q
                             - (blk_fire ? grp_parc : 5'd0)
                             + push_num;
                if (blk_fire) begin
                    buf_head_q <= buf_head_q + grp_parc[BUF_AW-1:0];
                end
                if (push_lo_ok || push_hi_ok) begin
                    push_from_q <= push_from_q + {26'b0, push_num, 1'b0};
                end
            end

            // ---- 缓冲写入（F4；重启拍不压，避免把旧流 parcel 混进新流）----
            if (push_lo_ok && !restart_valid)
                buf_q[push_idx0] <= pack_e(1'b1, f4_rsp_data[15:0], p_va0, p_pa0,
                                           f4_pk_q[`FRONT4_LU_PT0], f4_pk_q[`FRONT4_LU_G0],
                                           f4_pk_q[`FRONT4_LU_L0], f4_pk_q[`FRONT4_LU_S0],
                                           f4_pk_q[`FRONT4_LU_BTB_HIT], f4_pk_q[`FRONT4_LU_BTB_WAY],
                                           f4_pk_q[`FRONT4_LU_BTB_CND], f4_pk_q[`FRONT4_LU_BTB_CALL],
                                           f4_pk_q[`FRONT4_LU_BTB_RET],
                                           f4_pk_q[`FRONT4_LU_BTB_TGT_LO +: 32]);
            if (push_hi_ok && !restart_valid)
                buf_q[push_idx_hi] <= pack_e(1'b1, f4_rsp_data[31:16], p_va1, p_pa1,
                                           f4_pk_q[`FRONT4_LU_PT1], f4_pk_q[`FRONT4_LU_G1],
                                           f4_pk_q[`FRONT4_LU_L1], f4_pk_q[`FRONT4_LU_S1],
                                           f4_pk_q[`FRONT4_LU_BTB_HIT], f4_pk_q[`FRONT4_LU_BTB_WAY],
                                           f4_pk_q[`FRONT4_LU_BTB_CND], f4_pk_q[`FRONT4_LU_BTB_CALL],
                                           f4_pk_q[`FRONT4_LU_BTB_RET],
                                           f4_pk_q[`FRONT4_LU_BTB_TGT_LO +: 32]);

            // ---- F3 ← F2（查表结果随字下移）----
            if (f2_move) begin
                f3_v_q  <= 1'b1;
                f3_va_q <= f2_va_q;
                f3_ep_q <= f2_ep_q;
                f3_pk_q <= lu_pack;
            end else if (f3_move) begin
                f3_v_q  <= 1'b0;
            end

            // ---- F4 ← F3（发起取字请求）----
            if (f3_move) begin
                f4_v_q  <= 1'b1;
                f4_va_q <= f3_va_q;
                f4_pa_q <= f3_pa_w;
                f4_ep_q <= f3_ep_q;
                f4_pk_q <= f3_pk_q;
                // ★ XIP 判定（**物理地址**口径）必须在**进入 F4 时**打拍带上：
                //   f4_xip_q 决定本笔走 L1I 还是走直连；漏掉这一句会让 XIP 取指
                //   永远等 L1I 响应（TB 的 C4 用例打出的缺陷）。
                f4_xip_q <= f3_is_xip_w;
            end else if (f4_rsp_ok) begin
                f4_v_q  <= 1'b0;                 // 数据已收（已压入）
            end

            // ---- F2 ← F1 ----
            if (f1_accept) begin
                f2_v_q  <= 1'b1;
                f2_va_q <= fetch_pc;
                f2_ep_q <= epoch;
            end else if (f2_move) begin
                f2_v_q  <= 1'b0;
            end

            // ---- 取指异常保持（冻结到重定向）----
            if (blk_fire & grp_fault) fault_hold_q <= 1'b1;

            // ---- 统计 ----
            if (blk_fire) begin
                c_grp_q  <= c_grp_q + 32'd1;
                c_parc_q <= c_parc_q + {27'b0, grp_parc};
            end
            if (blk_fire & grp_fault) c_fault_q   <= c_fault_q + 32'd1;
            if (restart_valid)        c_restart_q <= c_restart_q + 32'd1;
            if (freeze_all & ~blk_fire) c_stall_q <= c_stall_q + 32'd1;
            if (l1i_req_valid | unc_req_valid) c_req_q <= c_req_q + 32'd1;
        end
    end

    assign cnt_grp     = c_grp_q;
    assign cnt_parcels = c_parc_q;
    assign cnt_fault   = c_fault_q;
    assign cnt_restart = c_restart_q;
    assign cnt_stall   = c_stall_q;
    assign cnt_req     = c_req_q;

endmodule
