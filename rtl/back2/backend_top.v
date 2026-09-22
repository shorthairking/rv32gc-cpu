//==============================================================================
// rtl/back2/backend_top.v —— 2B-2 乱序后端顶层
//   D1 译码 → D2 重命名 → D3 派发 → I1 选择 → I2 读 PRF → E1 执行 → W1 写回/提交
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md（§2 ROB 顺序提交、§3 重命名/检查点、§4 六部件 +
//         分布式队列、§4.3 唤醒/选择、§5 旁路、§8 精确异常与 epoch）；
//         docs/design/02-pipeline.md §3.5–§3.11（D1…W1 逐级口径）、§4.1（S3/S4/S5：
//         **整块 4 路停顿，不做部分派发**）、§5（衔接三硬规则）、§6（重定向类别 A/C）；
//         rtl/front4/README.md §8（与 2B-1 前端的衔接清单）。
//
// 【与 2B-1 前端的对接】派发块握手；重定向（类别 A 误判 / 类别 C 异常）→ redirect_*；
//   提交训练 train_*（携带**预测时记录**）；检查点释放 ckpt_free_*（提交或冲刷丢弃时都
//   要发，否则前端 S7 停顿）；RAS：call 在派发期压、ret 在 BRU 用**实际返回地址**弹。
//
// 【塌缩说明（如实登记）】02 §3.5–§3.7 把 D1/D2/D3 定义为三级流水；本里程碑把 D1
//   （译码）单独成级、D2/D3（重命名+派发）塌为一个派发周期：两者停顿集合完全相同
//   （派发是"整块 4 路停顿"的唯一边界），差别只在组合深度；拆级与时序收敛属 2B-5。
//
// 【译码复用（红线 4）】4×`rtl/decode/decoder.v`（2A 既有器件，只读复用）。
//
// 【本里程碑边界】不含完整 LSQ（2B-3）；不含完整特权栈与中断委托（2B-4/2C）；
//   访存 Bare 口径（VA=PA）；AMO/LR/SC/cbo/ecall/ebreak/xRET/wfi 判非法（cause 2）。
//
// 风格  : 组合逻辑 `assign` + 条件表达式 + function（**不读存储器**）；
//         always 块用于流水寄存器/存储体/优先级编码（逐处注释理由）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module backend_top #(
    parameter integer ROB_N    = `BACK2_ROB_N,
    parameter integer COMMIT_W = `BACK2_COMMIT_W,
    parameter integer DISP_W   = `BACK2_DISP_W,
    parameter integer CKPT_N   = `BACK2_CKPT_N,
    parameter integer NO_WAKE  = 0,           // 反证实验：1 = ALU1 唤醒广播恒 0（会挂死）
    parameter integer DBG_IQ   = 0,           // 1 = 6 个发射队列每拍打印队内项/唤醒（诊断）
    parameter integer DBG_LSU  = 0,           // 1 = 访存队列每拍打印 load 槽状态（诊断）
    parameter integer DBG_CSR  = 0            // 1 = 打印 CSR 执行/提交现场（B29 诊断）
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 前端派发块 ----
    input  wire        blk_valid_i,
    output wire        blk_ready_o,
    input  wire [3:0]  blk_mask_i,
    input  wire [31:0] blk_next_pc_i,
    input  wire        blk_taken_i,
    input  wire [127:0] lane_pc_i,
    input  wire [127:0] lane_pa_i,
    input  wire [127:0] lane_insn_i,
    input  wire [3:0]  lane_len32_i,
    input  wire [11:0] lane_cls_i,
    input  wire [3:0]  lane_pred_taken_i,
    input  wire [3:0]  lane_pred_selg_i,
    input  wire [3:0]  lane_pred_gdir_i,
    input  wire [3:0]  lane_pred_ldir_i,
    input  wire [127:0] lane_pred_target_i,
    input  wire [3:0]  lane_btb_hit_i,
    input  wire [3:0]  lane_btb_way_i,
    input  wire [3:0]  lane_btb_cond_i,
    input  wire [3:0]  lane_btb_call_i,
    input  wire [3:0]  lane_btb_ret_i,
    input  wire [127:0] lane_btb_target_i,
    input  wire [3:0]  lane_fault_i,
    input  wire [19:0] lane_fault_cause_i,
    input  wire [127:0] lane_fault_tval_i,
    input  wire [15:0] lane_ckpt_i,
    input  wire [3:0]  lane_ckpt_valid_i,
    input  wire        fe_fetch_fault_i,
    // ---- 后端 → 前端 ----
    output wire        redirect_valid_o,
    output wire [31:0] redirect_pc_o,
    output wire        redirect_use_ckpt_o,
    output wire [3:0]  redirect_ckpt_o,
    output wire        train_valid_o,
    output wire [31:0] train_pc_o,
    output wire        train_is_cond_o,
    output wire        train_taken_o,
    output wire        train_is_indirect_o,
    output wire        train_is_call_o,
    output wire        train_is_return_o,
    output wire [31:0] train_target_o,
    output wire        train_pred_taken_o,
    output wire        train_pred_sel_global_o,
    output wire        train_pred_gdir_o,
    output wire        train_pred_ldir_o,
    output wire [31:0] train_pred_target_o,
    output wire        train_pred_valid_o,
    output wire        train_btb_hit_o,
    output wire        train_btb_way_o,
    input  wire        train_ready_i,
    output wire        ckpt_free_valid_o,
    output wire [3:0]  ckpt_free_id_o,
    output wire        ras_cmt_push_valid_o,
    output wire        ras_cmt_pop_valid_o,
    output wire        d2_push_valid_o,
    output wire [31:0] d2_push_addr_o,
    output wire        d2_pop_valid_o,
    output wire [31:0] d2_pop_addr_o,
    // ---- 访存口 ----
    output wire        mem_req_valid_o,
    output wire        mem_req_wen_o,
    output wire [31:0] mem_req_addr_o,
    output wire [31:0] mem_req_wdata_o,
    output wire [3:0]  mem_req_wstrb_o,
    output wire [2:0]  mem_req_tag_o,
    input  wire        mem_req_ready_i,
    input  wire        mem_rsp_valid_i,
    input  wire [31:0] mem_rsp_rdata_i,
    input  wire [2:0]  mem_rsp_tag_i,
    // ---- 提交流（锁步比对）----
    output wire [3:0]  commit_valid_o,
    output wire [127:0] commit_pc_o,
    output wire [19:0] commit_arch_rd_o,
    output wire [127:0] commit_arch_rd_wdata_o,
    //   ★ 每条提交指令"是否真的写架构寄存器"（整数或浮点）。**不能**用 rd != 0 推断：
    //     B 型/J 型指令的 bits[11:7] 是立即数的一部分（如 `bne` 的 rd 域=29），
    //     `commit_arch_rd_o` 因此可能非 0 而不写任何寄存器（实测：C1 在 `bne` 处
    //     误判"乱序多写一次 x29"）。
    output wire [3:0]   commit_arch_we_o,
    // ---- 异常 / 统计 ----
    output wire        trap_valid_o,
    output wire [31:0] trap_pc_o,
    output wire [3:0]  trap_cause_o,
    output wire [31:0] trap_tval_o,
    output wire [31:0] cnt_commit_o,
    output wire [31:0] cnt_squash_o,
    output wire [31:0] cnt_commit4_o,
    output wire [31:0] cnt_issue_o,
    output wire [6:0]  dbg_rob_cnt_o,
    output wire [23:0] dbg_iq_cnt_o,
    output wire [7:0]  dbg_stq_cnt_o
);

    //==========================================================================
    // 0. 局部常量与纯函数
    //==========================================================================
    localparam [3:0] OPT_JAL = 4'd2, OPT_JALR = 4'd3, OPT_FP = 4'd11;
    localparam [2:0] WB_NONE = 3'd0, WB_PC4 = 3'd3;
    localparam       UOPW  = `BACK2_UOP_W;
    localparam       RB_W  = `BACK2_RB_W;
    localparam       WI    = `BACK2_IQ_WR_PORTS;
    localparam       EW    = `BACK2_EPOCH_W;
    localparam       PW_I  = `BACK2_PREG_I_W;
    localparam       PW_F  = `BACK2_PREG_F_W;
    localparam       SRC_N = 5;
    localparam WBP_ALU0 = 0, WBP_ALU1 = 1, WBP_BRU = 2, WBP_MDU = 3,
               WBP_LSU  = 4, WBP_FPU  = 5, WBP_STD = 6;

    function [31:0] u_pc;       input [UOPW-1:0] u; begin u_pc  = u[`BACK2_U_PC_MSB:`BACK2_U_PC_LSB]; end endfunction
    function [31:0] u_imm;      input [UOPW-1:0] u; begin u_imm = u[`BACK2_U_IMM_MSB:`BACK2_U_IMM_LSB]; end endfunction
    function [4:0]  u_arn;      input [UOPW-1:0] u; begin u_arn = u[`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB]; end endfunction
    function [2:0]  u_cls;      input [UOPW-1:0] u; begin u_cls = u[`BACK2_U_CLS_MSB:`BACK2_U_CLS_LSB]; end endfunction
    function [3:0]  u_opt;      input [UOPW-1:0] u; begin u_opt = u[`BACK2_U_OPTYPE_MSB:`BACK2_U_OPTYPE_LSB]; end endfunction
    function [2:0]  u_wbsel;    input [UOPW-1:0] u; begin u_wbsel = u[`BACK2_U_WBSEL_MSB:`BACK2_U_WBSEL_LSB]; end endfunction
    function [2:0]  u_csrop;    input [UOPW-1:0] u; begin u_csrop = u[`BACK2_U_CSROP_MSB:`BACK2_U_CSROP_LSB]; end endfunction
    function [11:0] u_csra;     input [UOPW-1:0] u; begin u_csra = u[`BACK2_U_CSRADDR_MSB:`BACK2_U_CSRADDR_LSB]; end endfunction
    function [6:0]  u_fpop;     input [UOPW-1:0] u; begin u_fpop = u[`BACK2_U_FPOP_MSB:`BACK2_U_FPOP_LSB]; end endfunction
    function [1:0]  u_fmt;      input [UOPW-1:0] u; begin u_fmt = u[`BACK2_UAX_FMT_MSB:`BACK2_UAX_FMT_LSB]; end endfunction
    function u_il32;            input [UOPW-1:0] u; begin u_il32 = u[`BACK2_UAX_IL32]; end endfunction
    function u_rt;              input [UOPW-1:0] u; begin u_rt = u[`BACK2_UAX_RTYPE]; end endfunction
    function u_au;              input [UOPW-1:0] u; begin u_au = u[`BACK2_UAX_AUIPC]; end endfunction
    function u_is_csr;          input [UOPW-1:0] u; begin u_is_csr = u[`BACK2_UB_IS_CSR]; end endfunction
    function u_is_br;           input [UOPW-1:0] u; begin u_is_br = u[`BACK2_UB_IS_BRANCH]; end endfunction
    function u_is_ld;           input [UOPW-1:0] u; begin u_is_ld = u[`BACK2_UB_IS_LOAD]; end endfunction
    function u_is_st;           input [UOPW-1:0] u; begin u_is_st = u[`BACK2_UB_IS_STORE]; end endfunction
    function u_di;              input [UOPW-1:0] u; begin u_di = u[`BACK2_UB_RD_I_WEN]; end endfunction
    function u_df;              input [UOPW-1:0] u; begin u_df = u[`BACK2_UB_RD_F_WEN]; end endfunction
    function u_fpls;            input [UOPW-1:0] u; begin u_fpls = u[`BACK2_UB_IS_FPLS]; end endfunction
    function u_s1i;             input [UOPW-1:0] u; begin u_s1i = u[`BACK2_UB_S1_I_USE]; end endfunction
    function u_s2i;             input [UOPW-1:0] u; begin u_s2i = u[`BACK2_UB_S2_I_USE]; end endfunction
    function u_s1f;             input [UOPW-1:0] u; begin u_s1f = u[`BACK2_UB_S1_F_USE]; end endfunction
    function u_s2f;             input [UOPW-1:0] u; begin u_s2f = u[`BACK2_UB_S2_F_USE]; end endfunction
    function u_s3f;             input [UOPW-1:0] u; begin u_s3f = u[`BACK2_UB_S3_F_USE]; end endfunction
    function [PW_I-1:0] u_ps1i; input [UOPW-1:0] u; begin u_ps1i = u[`BACK2_U_PS1I_MSB:`BACK2_U_PS1I_LSB]; end endfunction
    function [PW_I-1:0] u_pdi;  input [UOPW-1:0] u; begin u_pdi  = u[`BACK2_U_PDIDST_MSB:`BACK2_U_PDIDST_LSB]; end endfunction
    function [PW_I-1:0] u_pdio; input [UOPW-1:0] u; begin u_pdio = u[`BACK2_U_PDIOLD_MSB:`BACK2_U_PDIOLD_LSB]; end endfunction
    function [PW_F-1:0] u_pdf;  input [UOPW-1:0] u; begin u_pdf  = u[`BACK2_U_PDFDST_MSB:`BACK2_U_PDFDST_LSB]; end endfunction
    function [PW_F-1:0] u_pdfo; input [UOPW-1:0] u; begin u_pdfo = u[`BACK2_U_PDFOLD_MSB:`BACK2_U_PDFOLD_LSB]; end endfunction
    function [31:0] u_predtgt; input [UOPW-1:0] u; begin u_predtgt = u[`BACK2_U_PREDTGT_MSB:`BACK2_U_PREDTGT_LSB]; end endfunction
    function [31:0] u_tval;    input [UOPW-1:0] u; begin u_tval = u[`BACK2_U_TVAL_MSB:`BACK2_U_TVAL_LSB]; end endfunction
    function [3:0]  u_exc;     input [UOPW-1:0] u; begin u_exc  = u[`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB]; end endfunction
    function u_ckv;            input [UOPW-1:0] u; begin u_ckv  = u[`BACK2_UB_CKPT_VALID]; end endfunction
    function [3:0]  u_ckid;    input [UOPW-1:0] u; begin u_ckid = u[`BACK2_U_CKPT_MSB:`BACK2_U_CKPT_LSB]; end endfunction
    function [PW_I-1:0] u_ps2i; input [UOPW-1:0] u; begin u_ps2i = u[`BACK2_U_PS2I_MSB:`BACK2_U_PS2I_LSB]; end endfunction
    function [PW_F-1:0] u_ps1f; input [UOPW-1:0] u; begin u_ps1f = u[`BACK2_U_PS1F_MSB:`BACK2_U_PS1F_LSB]; end endfunction
    function [PW_F-1:0] u_ps2f; input [UOPW-1:0] u; begin u_ps2f = u[`BACK2_U_PS2F_MSB:`BACK2_U_PS2F_LSB]; end endfunction
    function [PW_F-1:0] u_ps3f; input [UOPW-1:0] u; begin u_ps3f = u[`BACK2_U_PS3F_MSB:`BACK2_U_PS3F_LSB]; end endfunction
    // ROB 载荷取字段（纯函数）
    function [31:0] p_pc;    input [RB_W-1:0] p; begin p_pc  = p[`BACK2_U_PC_MSB:`BACK2_U_PC_LSB]; end endfunction
    function [4:0]  p_arn;   input [RB_W-1:0] p; begin p_arn = p[`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB]; end endfunction
    function [PW_I-1:0] p_pdi;  input [RB_W-1:0] p; begin p_pdi  = p[`BACK2_U_PDIDST_MSB:`BACK2_U_PDIDST_LSB]; end endfunction
    function [PW_I-1:0] p_pdio; input [RB_W-1:0] p; begin p_pdio = p[`BACK2_U_PDIOLD_MSB:`BACK2_U_PDIOLD_LSB]; end endfunction
    function [PW_F-1:0] p_pdf;  input [RB_W-1:0] p; begin p_pdf  = p[`BACK2_U_PDFDST_MSB:`BACK2_U_PDFDST_LSB]; end endfunction
    function [PW_F-1:0] p_pdfo; input [RB_W-1:0] p; begin p_pdfo = p[`BACK2_U_PDFOLD_MSB:`BACK2_U_PDFOLD_LSB]; end endfunction
    function p_di;  input [RB_W-1:0] p; begin p_di = p[`BACK2_UB_RD_I_WEN]; end endfunction
    function p_df;  input [RB_W-1:0] p; begin p_df = p[`BACK2_UB_RD_F_WEN]; end endfunction
    function p_st;  input [RB_W-1:0] p; begin p_st = p[`BACK2_UB_IS_STORE]; end endfunction
    function p_csr; input [RB_W-1:0] p; begin p_csr = p[`BACK2_UB_IS_CSR]; end endfunction
    function p_ckv; input [RB_W-1:0] p; begin p_ckv = p[`BACK2_UB_CKPT_VALID]; end endfunction
    function [3:0] p_ckid; input [RB_W-1:0] p; begin p_ckid = p[`BACK2_U_CKPT_MSB:`BACK2_U_CKPT_LSB]; end endfunction
    function [2:0] p_cls;  input [RB_W-1:0] p; begin p_cls  = p[`BACK2_U_CLS_MSB:`BACK2_U_CLS_LSB]; end endfunction
    function [3:0] p_stq;  input [RB_W-1:0] p; begin p_stq  = p[`BACK2_RB_STQ_MSB:`BACK2_RB_STQ_LSB]; end endfunction
    function [31:0] p_csrw;input [RB_W-1:0] p; begin p_csrw = p[`BACK2_RB_CSRW_MSB:`BACK2_RB_CSRW_LSB]; end endfunction
    function [11:0] p_csra;input [RB_W-1:0] p; begin p_csra = p[`BACK2_U_CSRADDR_MSB:`BACK2_U_CSRADDR_LSB]; end endfunction
    function [2:0]  p_csrop;input [RB_W-1:0] p;begin p_csrop= p[`BACK2_U_CSROP_MSB:`BACK2_U_CSROP_LSB]; end endfunction
    function [4:0]  p_ff;  input [RB_W-1:0] p; begin p_ff  = p[`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB]; end endfunction
    function [31:0] p_trtgt;input [RB_W-1:0] p;begin p_trtgt=p[`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB]; end endfunction
    function p_trtk;       input [RB_W-1:0] p; begin p_trtk = p[`BACK2_RB_TRTAKEN]; end endfunction

    // 分支类别（front4 README §1 的 lane_cls 编码）
    function t_call; input [2:0] c; begin t_call = (c == 3'd5) | (c == 3'd6); end endfunction
    function t_ret;  input [2:0] c; begin t_ret  = (c == 3'd4); end endfunction
    function t_ind;  input [2:0] c; begin t_ind  = (c == 3'd3) | (c == 3'd6); end endfunction
    function t_cond; input [2:0] c; begin t_cond = (c == 3'd1); end endfunction

    // FP 归一化操作码（与 rtl/exec/fpu.v 头注 §1 的表逐条一致）
    function [6:0] fp_op_map;
        input [31:0] insn;
        reg [4:0] f5, rs2f;
        begin
            f5   = insn[31:27];
            rs2f = insn[24:20];
            case (insn[6:0])
                `RV32GC_OP_MADD : fp_op_map = 7'd26;
                `RV32GC_OP_MSUB : fp_op_map = 7'd27;
                `RV32GC_OP_NMSUB: fp_op_map = 7'd28;
                `RV32GC_OP_NMADD: fp_op_map = 7'd29;
                `RV32GC_OP_FP: case (f5)
                    5'b00000: fp_op_map = 7'd0;
                    5'b00001: fp_op_map = 7'd1;
                    5'b00010: fp_op_map = 7'd2;
                    5'b00011: fp_op_map = 7'd3;
                    5'b01011: fp_op_map = 7'd4;
                    5'b00100: fp_op_map = (rs2f == 5'd0) ? 7'd5 : (rs2f == 5'd1) ? 7'd6 : 7'd7;
                    5'b00101: fp_op_map = (rs2f == 5'd0) ? 7'd8 : 7'd9;
                    5'b10100: fp_op_map = (rs2f == 5'd2) ? 7'd10 : (rs2f == 5'd1) ? 7'd11 : 7'd12;
                    5'b11100: fp_op_map = (rs2f == 5'd1) ? 7'd13 : 7'd14;
                    5'b11110: fp_op_map = 7'd15;
                    5'b01000: fp_op_map = (rs2f == 5'd0) ? 7'd18 : (rs2f == 5'd1) ? 7'd19 :
                                          (rs2f == 5'd2) ? 7'd22 : 7'd23;
                    5'b11000: fp_op_map = (rs2f == 5'd0) ? 7'd16 : (rs2f == 5'd1) ? 7'd17 :
                                          (rs2f == 5'd2) ? 7'd20 : 7'd21;
                    5'b01001: fp_op_map = 7'd24;
                    5'b11001: fp_op_map = 7'd25;
                    default : fp_op_map = 7'd127;
                endcase
                default: fp_op_map = 7'd127;
            endcase
        end
    endfunction

    //==========================================================================
    // 1. 声明（统一前置，避免隐式网）
    //==========================================================================
    // 前端衔接/回滚/部件就绪/CSR 的前置声明（避免隐式 1 bit 网）
    wire        snap_v_w, restore_ck_v_w, restore_rob_v_w;
    wire [3:0]  snap_id_w, restore_ck_id_w;
    wire [1:0]  snap_lane_w;
    wire [6:0]  restore_rob_idx_w;
    wire        mdu_free_w, fpu_free_w, lsu_iss_ok_w;
    wire [31:0] csr_rdata_w;
    wire [2:0]  csr_frm_w;
    wire [4:0]  csr_ff_w;
    wire [3:0]  stq_of_rob_r;
    reg         trap_halt_q;
    reg         mdu_if_v, fpu_if_v;
    reg  [6:0]  mdu_if_rob, fpu_if_rob;
    reg  [EW-1:0] mdu_if_ep, fpu_if_ep;
    reg         mdu_if_di, fpu_if_di, fpu_if_df;
    reg  [PW_I-1:0] mdu_if_pdi, fpu_if_pdi;
    reg  [PW_F-1:0] fpu_if_pdf;
    reg  [3:0]  stq_of_rob [0:127];
    wire [11:0] csr_raddr_w;



    wire [3:0]      d1_lat_v;
    wire [UOPW-1:0] d1_lat_uop [0:DISP_W-1];
    reg  [UOPW-1:0] d1_uop_q   [0:DISP_W-1];
    reg  [DISP_W-1:0] d1_v_q;

    // 重命名请求/结果
    wire [DISP_W-1:0]     rn_v, rn_ndst, rn_ndst_f;
    wire [DISP_W*5-1:0]   rn_darn, rn_darn_f;
    wire [DISP_W*2-1:0]   rn_ni;
    wire [DISP_W*2*5-1:0] rn_si_arn;
    wire [DISP_W*3-1:0]   rn_nf;
    wire [DISP_W*3*5-1:0] rn_sf_arn;
    wire [DISP_W*PW_I-1:0] pd_i_dst, pd_i_old;
    wire [DISP_W*2*PW_I-1:0] pd_i_s;
    wire [DISP_W*PW_F-1:0] pd_f_dst, pd_f_old;
    wire [DISP_W*3*PW_F-1:0] pd_f_s;
    wire free_i_ok, free_f_ok, rn_i_busy, rn_f_busy;
    wire [7:0] free_i_cnt, free_f_cnt;
    wire [DISP_W-1:0]   cmt_i_we, cmt_f_we, rel_i_we, rel_f_we;
    wire [DISP_W*5-1:0] cmt_i_arn, cmt_f_arn;
    wire [DISP_W*PW_I-1:0] cmt_i_pd, rel_i_pd;
    wire [DISP_W*PW_F-1:0] cmt_f_pd, rel_f_pd;

    // 队列归属
    wire [11:0] lane_q;
    reg  [2:0]  q_wr_n [0:5];
    reg  [1:0]  q_ord  [0:3];
    wire [5:0]  iq_free_ok;
    wire [23:0] iq_free_cnt;
    wire [5:0]  iq_iss_v;
    wire [5:0]  iq_sel_v;
    wire [UOPW-1:0] iq_iss_uop [0:5];
    wire [6:0]  iq_iss_rob [0:5];
    wire [EW-1:0] iq_iss_ep [0:5];
    wire [5:0]  iq_iss_dead;
    reg  [6*WI-1:0]          iq_wv;
    reg  [6*WI*UOPW-1:0]     iq_wuop;
    reg  [6*WI*7-1:0]        iq_wrob;
    reg  [6*WI*SRC_N-1:0]    iq_wrdy;
    wire [4:0]  iq_cnt [0:5];

    // 忙碌位图
    reg  [`BACK2_PRF_I_N-1:0] busy_i_q;
    reg  [`BACK2_PRF_F_N-1:0] busy_f_q;
    reg  [`BACK2_PRF_I_N-1:0] busy_i_nx;
    reg  [`BACK2_PRF_F_N-1:0] busy_f_nx;

    // PRF 端口
    wire [14:0]     iprf_re;
    wire [15*PW_I-1:0] iprf_ra;
    wire [15*32-1:0]   iprf_rd;
    wire [5:0]      iprf_we;
    wire [6*PW_I-1:0]  iprf_wa;
    wire [6*32-1:0]    iprf_wd;
    wire [6*EW-1:0]    iprf_we_ep;
    wire [7:0]      fprf_re;
    wire [8*PW_F-1:0]  fprf_ra;
    wire [8*64-1:0]    fprf_rd;
    wire [1:0]      fprf_we;
    wire [2*PW_F-1:0]  fprf_wa;
    wire [2*64-1:0]    fprf_wd;
    wire [2*EW-1:0]    fprf_we_ep;

    // 写回总线（0..5 六部件；6 = store 完成仅置 done）
    wire [6:0]      wb_v;
    wire [7*7-1:0]  wb_rob;
    wire [7*EW-1:0] wb_ep;
    wire [5:0]      wbi_v;              // 整数写回有效（部件 0..5）
    wire [6*PW_I-1:0] wbi_tag;
    wire [6*32-1:0]   wbi_data;
    wire [5:0]      wki_v;              // 整数唤醒（部件 0..5）
    wire [6*PW_I-1:0] wki_tag;
    wire [5:0]      wkf_v;              // 浮点唤醒（0 = LSU，1 = FPU）
    wire [6*PW_F-1:0] wkf_tag;

    // 各部件 I2 寄存器
    reg  [UOPW-1:0] x_i2_uop [0:5];
    reg  [6:0]      x_i2_rob [0:5];
    reg  [EW-1:0]   x_i2_ep  [0:5];
    reg             x_i2_v   [0:5];

    // ROB
    wire        rob_alloc_ready;
    wire [6:0]  rob_alloc_idx0;
    wire [3:0]  cmt_raw, cmt_st_drain, cmt_st_ckpt, cmt_st_branch;
    wire [COMMIT_W*RB_W-1:0] cmt_pay;
    wire        cmt_ok;
    wire [DISP_W*RB_W-1:0] rob_pay_w;
    wire        trap_v_rob, flush_all_w, squash_v_w;
    wire [6:0]  rob_head_w, squash_idx_w;
    wire [7:0]  rob_cnt_w;
    wire [EW-1:0] epoch_w;
    wire [31:0] upd_csrw;
    wire [6:0]  upd_csr_idx;
    wire        upd_csr_v, upd_tr_v, upd_ff_v, upd_exc_v;

    // 提交
    wire [6:0]  cmt_i2;
    wire [3:0]  lsu_dr_valid;
    wire [15:0] lsu_dr_idx;

    // 前端接口
    reg  [31:0] cnt_sq_q, cnt_cmt4_q, cnt_iss_q;
    reg  [3:0]  ck_busy_q;
    reg  [6:0]  ck_rob_q [0:CKPT_N-1];
    reg  [CKPT_N-1:0] ck_pend_q;

    //==========================================================================
    // 2. D1：4×decoder（组合）+ uop 打包
    //==========================================================================
    integer di;
    genvar  g;
    generate
    for (g = 0; g < DISP_W; g = g + 1) begin : g_d1
        wire [31:0] insn = lane_insn_i[g*32 +: 32];
        wire [4:0]  rs1f = insn[19:15];
        wire [4:0]  rs2f = insn[24:20];
        wire [4:0]  f5   = insn[31:27];
        wire [31:0] insn32, tval, imm;
        wire        ill_instr, is_c, is_hint, ctl_xfer, mun, fp_we, fp_ldst;
        wire [4:0]  drs1, drs2, drs3, drd;
        wire [3:0]  opt, aluop, memop;
        wire [2:0]  msize, wbsel, csrop, rm;
        wire [11:0] csraddr;
        wire [5:0]  dfpop;
        wire        csr_ill, csr_zimm, is_amo, fence, fence_i, cbo_valid;
        wire        cbo_gate_ill, cbo_downgrade, ebreak, ecall, mret, sret, wfi, sfence;
        wire [4:0]  cbo_kind;

        decoder u_dec (
            .insn_i(insn), .priv_i(`RV32GC_PRIV_M),
            .menvcfg_cbie_i(2'b00), .menvcfg_cbcfe_i(1'b0),
            .senvcfg_cbie_i(2'b00), .senvcfg_cbcfe_i(1'b0),
            .insn32_o(insn32), .tval_o(tval), .ill_instr_o(ill_instr),
            .is_compressed_o(is_c), .is_hint_o(is_hint), .ctl_xfer_o(ctl_xfer),
            .rs1_o(drs1), .rs2_o(drs2), .rs3_o(drs3), .rd_o(drd), .imm_o(imm),
            .op_type_o(opt), .alu_op_o(aluop), .mem_op_o(memop), .mem_size_o(msize),
            .mem_unsign_o(mun), .wb_sel_o(wbsel), .csr_op_o(csrop), .fp_op_o(dfpop),
            .fp_we_o(fp_we), .fp_ldst_o(fp_ldst), .rm_o(rm), .rv32_is_amo_o(is_amo),
            .csr_addr_o(csraddr), .csr_ill_o(csr_ill), .csr_zimm_o(csr_zimm),
            .cbo_valid_o(cbo_valid), .cbo_kind_o(cbo_kind), .cbo_gate_ill_o(cbo_gate_ill),
            .cbo_downgrade_o(cbo_downgrade), .fence_i_o(fence_i), .fence_o(fence),
            .ebreak_o(ebreak), .ecall_o(ecall), .mret_o(mret), .sret_o(sret),
            .wfi_o(wfi), .sfence_vma_o(sfence)
        );
        assign d1_lat_v[g] = blk_mask_i[g];

        wire is_fma  = (insn[6:0] == `RV32GC_OP_MADD) | (insn[6:0] == `RV32GC_OP_MSUB) |
                       (insn[6:0] == `RV32GC_OP_NMSUB)| (insn[6:0] == `RV32GC_OP_NMADD);
        wire is_opfp = (insn[6:0] == `RV32GC_OP_FP) | is_fma;
        wire fp_src1_int = is_opfp & ~is_fma &
                           ((f5 == 5'b11110) | ((f5 == 5'b01000) & ~rs2f[1]));
        wire unsup   = (opt == 4'd5) | (opt == 4'd8) | (opt == 4'd10) | (opt == 4'd15);
        wire illegal = ill_instr | (opt == 4'd15) | csr_ill | cbo_gate_ill;
        wire kill    = unsup | illegal;

        wire rs1_used = ((opt == 4'd0) | (opt == 4'd1) | (opt == 4'd3) | (opt == 4'd4) |
                         (opt == 4'd6) | (opt == 4'd7) | (opt == 4'd12) | fp_src1_int) &
                        ~kill & ~csr_zimm;
        wire rs2_int  = ((insn[6:0] == `RV32GC_OP_OP) | (opt == 4'd1) |
                         ((opt == 4'd4) & (memop == 4'd2))) & ~kill;
        wire rs1_f    = is_opfp & ~is_fma & ~fp_src1_int & ~kill;
        wire rs2_f    = (is_opfp ? ~is_fma : ((opt == 4'd12) & (memop == 4'd8))) & ~kill;
        wire rs3_f    = is_fma & ~kill;
        wire dst_fp   = fp_we & (drd != 5'd0) & ~kill;
        wire dst_int  = ~fp_we & (drd != 5'd0) & (wbsel != WB_NONE) & ~kill;
        wire is_load_u  = (((opt == 4'd4) & (memop == 4'd1)) |
                           ((opt == 4'd12) & (memop == 4'd7))) & ~kill;
        wire is_store_u = (((opt == 4'd4) & (memop == 4'd2)) |
                           ((opt == 4'd12) & (memop == 4'd8))) & ~kill;
        wire [2:0] oq = (opt == 4'd0) ? ((g[0]) ? `BACK2_Q_ALU1 : `BACK2_Q_ALU0) :
                        (opt == 4'd7) ? `BACK2_Q_ALU0 :
                        (opt == 4'd9) ? `BACK2_Q_ALU0 :
                        (opt == 4'd6) ? `BACK2_Q_MDU :
                        (opt == 4'd1) ? `BACK2_Q_BRU :
                        ((opt == 4'd2) | (opt == 4'd3)) ? `BACK2_Q_BRU :
                        (opt == 4'd11) ? `BACK2_Q_FPU :
                        (opt == 4'd12) ? `BACK2_Q_LSU :
                        (opt == 4'd4)  ? `BACK2_Q_LSU : `BACK2_Q_ALU0;
        wire [3:0] exc_w = lane_fault_i[g] ? {1'b0, lane_fault_cause_i[g*5 +: 4]} :
                           kill ? `BACK2_EXC_ILLEGAL : `BACK2_EXC_NONE;

        // ★ 禁止"整段清零 + 逐段赋值"：wire 上的多条连续赋值是**多驱动**，同位宽
        //   的 0/1 冲突会在 iverilog/Vivado 下解析成 **x**（实测：PC/ARND 等所有含 1
        //   的字段全变 x ⇒ ROB 提交流全 x ⇒ 后端假提交、前端不推进）。本块内
        //   [UOPW-1:0] 的**每一个 bit 恰好被下面一条赋值覆盖一次**（含 AUX/SRC 段；
        //   PSPD 段 [132:75] 由重命名结果在 lane_uop_fin 处显式拼接填入）。
        assign d1_lat_uop[g][`BACK2_U_BTB_MSB:`BACK2_U_BTB_LSB] =
               {lane_btb_hit_i[g], lane_btb_way_i[g]};
        assign d1_lat_uop[g][`BACK2_U_PRED_MSB:`BACK2_U_PRED_LSB] =
               {lane_pred_taken_i[g], lane_pred_selg_i[g], lane_pred_gdir_i[g], lane_pred_ldir_i[g]};
        assign d1_lat_uop[g][`BACK2_U_PC_MSB:`BACK2_U_PC_LSB] = lane_pc_i[g*32 +: 32];
        assign d1_lat_uop[g][`BACK2_U_TVAL_MSB:`BACK2_U_TVAL_LSB] =
               lane_fault_i[g] ? lane_fault_tval_i[g*32 +: 32] : tval;
        assign d1_lat_uop[g][`BACK2_U_PREDTGT_MSB:`BACK2_U_PREDTGT_LSB] =
               lane_pred_target_i[g*32 +: 32];
        assign d1_lat_uop[g][`BACK2_U_IMM_MSB:`BACK2_U_IMM_LSB] = csr_zimm ? {27'b0, rs1f} : imm;
        assign d1_lat_uop[g][`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB] = drd;
        assign d1_lat_uop[g][`BACK2_U_OPTYPE_MSB:`BACK2_U_OPTYPE_LSB] = opt;
        assign d1_lat_uop[g][`BACK2_U_ALUOP_MSB:`BACK2_U_ALUOP_LSB] = aluop;
        assign d1_lat_uop[g][`BACK2_U_MEMOP_MSB:`BACK2_U_MEMOP_LSB] = memop;
        assign d1_lat_uop[g][`BACK2_U_MSIZE_MSB:`BACK2_U_MSIZE_LSB] = msize;
        assign d1_lat_uop[g][`BACK2_U_MUNSIGN] = mun;
        assign d1_lat_uop[g][`BACK2_U_WBSEL_MSB:`BACK2_U_WBSEL_LSB] = wbsel;
        assign d1_lat_uop[g][`BACK2_U_CSROP_MSB:`BACK2_U_CSROP_LSB] = csrop;
        assign d1_lat_uop[g][`BACK2_U_CSRADDR_MSB:`BACK2_U_CSRADDR_LSB] = csraddr;
        assign d1_lat_uop[g][`BACK2_U_FPOP_MSB:`BACK2_U_FPOP_LSB] =
               is_opfp ? fp_op_map(insn) : {1'b0, dfpop};
        assign d1_lat_uop[g][`BACK2_U_RM_MSB:`BACK2_U_RM_LSB] = rm;
        assign d1_lat_uop[g][`BACK2_U_BROP_MSB:`BACK2_U_BROP_LSB] =
               {(opt == 4'd3), (opt == 4'd2), insn[14:12]};
        assign d1_lat_uop[g][`BACK2_U_CLS_MSB:`BACK2_U_CLS_LSB] = lane_cls_i[g*3 +: 3];
        assign d1_lat_uop[g][`BACK2_U_CKPT_MSB:`BACK2_U_CKPT_LSB] = lane_ckpt_i[g*4 +: 4];
        assign d1_lat_uop[g][`BACK2_U_FLAGS_MSB:`BACK2_U_FLAGS_LSB] = {
            (opt == 4'd12),                     // fl15 is_fpls
            unsup,                              // fl14 is_unsup
            lane_ckpt_valid_i[g],               // fl13 ckpt_valid
            illegal,                            // fl12 is_illegal
            (opt == 4'd11) & ~kill,             // fl11 is_fp
            (opt == 4'd7),                      // fl10 is_csr
            (opt == 4'd1) | (opt == 4'd2) | (opt == 4'd3),  // fl9 is_branch
            is_store_u, is_load_u,
            rs3_f, rs2_f, rs1_f, rs2_int, rs1_used,
            dst_fp, dst_int
        };
        assign d1_lat_uop[g][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB] = exc_w;
        assign d1_lat_uop[g][`BACK2_UAX_RTYPE] = (insn[6:0] == `RV32GC_OP_OP);
        assign d1_lat_uop[g][`BACK2_UAX_AUIPC] = (insn[6:0] == `RV32GC_OP_AUIPC);
        assign d1_lat_uop[g][`BACK2_UAX_FMT_MSB:`BACK2_UAX_FMT_LSB] = insn[26:25];
        assign d1_lat_uop[g][`BACK2_UAX_IL32] = lane_len32_i[g];
        assign d1_lat_uop[g][`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB] = oq[2:0];
        assign d1_lat_uop[g][`BACK2_U_SRC1_LSB +: 5] = rs1f;
        assign d1_lat_uop[g][`BACK2_U_SRC2_LSB +: 5] = rs2f;
        assign d1_lat_uop[g][`BACK2_U_SRC3_LSB +: 5] = drs3;
    end
    endgenerate

    //==========================================================================
    // 3. D1 寄存器
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_v_q <= {DISP_W{1'b0}};
            for (di = 0; di < DISP_W; di = di + 1) d1_uop_q[di] <= {UOPW{1'b0}};
        end else if (squash_v_w | flush_all_w) begin
            // ★ 重定向/冲刷拍**必须作废 D1 滑板里的块**：该块是"重定向前取到"的
            //   错路径块（blk_valid/blk_ready 只是握手，前端无法撤回已交付的块）。
            //   不杀它的后果（实测）：它会被一直持有到重命名回滚结束才派发，然后
            //   按程序序**提交**（观测：跳板 `jalr` 之后的错误路径 nop 0x1C00_0008
            //   被提交，跳板流与 2A 基线差 1 条）。
            //   同拍"派发 + 冲刷"的情形无需在此处理：ROB 的 5.4 分支同样以
            //   flush/squash 优先，同拍分配被整块丢弃。
            d1_v_q <= {DISP_W{1'b0}};
        end else if (blk_valid_i & blk_ready_o) begin
            d1_v_q <= blk_mask_i;
            for (di = 0; di < DISP_W; di = di + 1) d1_uop_q[di] <= d1_lat_uop[di];
        end else if (disp_fire_w) begin
            d1_v_q <= {DISP_W{1'b0}};
        end
    end

    //==========================================================================
    // 4. D2/D3：重命名请求 + 资源检查 + 派发
    //==========================================================================
    //   ★ `disp_fire_w` 在下面 §4 的"资源检查"处定义，但本文件更早的地方
    //     （rename 例化 / ROB / IQ / STQ 的写使能）就要用它 ⇒ 在**所有使用点之前**
    //     统一定义，避免 iverilog 生成"隐式 1 bit 网"（-Wall 会报 implicit wire；
    //     真实工程里这是易错的静默陷阱）。
    wire disp_fire_w;
    assign lane_q[2:0]   = d1_uop_q[0][`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB];
    assign lane_q[5:3]   = d1_uop_q[1][`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB];
    assign lane_q[8:6]   = d1_uop_q[2][`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB];
    assign lane_q[11:9]  = d1_uop_q[3][`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB];

    // 每队列写入条数 + lane 的写口序号（组合优先级扫描；只读打包向量）
    integer qi, gi2;
    always @(*) begin
        for (qi = 0; qi < 6; qi = qi + 1) q_wr_n[qi] = 3'd0;
        for (gi2 = 0; gi2 < DISP_W; gi2 = gi2 + 1) q_ord[gi2] = 2'd0;
        for (gi2 = 0; gi2 < DISP_W; gi2 = gi2 + 1) begin
            if (d1_v_q[gi2]) begin
                q_ord[gi2] = q_wr_n[lane_q[gi2*3 +: 3]][1:0];
                q_wr_n[lane_q[gi2*3 +: 3]] = q_wr_n[lane_q[gi2*3 +: 3]] + 3'd1;
            end
        end
    end

    // lane 有效数
    wire [2:0] d1_n_w = {2'b0, d1_v_q[0]} + {2'b0, d1_v_q[1]} +
                        {2'b0, d1_v_q[2]} + {2'b0, d1_v_q[3]};

    // 重命名请求
    assign rn_v[0] = d1_v_q[0];  assign rn_v[1] = d1_v_q[1];
    assign rn_v[2] = d1_v_q[2];  assign rn_v[3] = d1_v_q[3];
    genvar g3;
    generate
    for (g3 = 0; g3 < DISP_W; g3 = g3 + 1) begin : g_rnq
        wire [UOPW-1:0] u = d1_uop_q[g3];
        assign rn_ndst[g3]   = u[`BACK2_UB_RD_I_WEN];
        assign rn_ndst_f[g3] = u[`BACK2_UB_RD_F_WEN];
        assign rn_darn[g3*5 +: 5]   = u_arn(u);
        assign rn_darn_f[g3*5 +: 5] = u_arn(u);
        assign rn_ni[g3*2 + 0] = u_s1i(u);
        assign rn_ni[g3*2 + 1] = u_s2i(u);
        assign rn_si_arn[(g3*2+0)*5 +: 5] = u[`BACK2_U_SRC1_LSB +: 5];
        assign rn_si_arn[(g3*2+1)*5 +: 5] = u[`BACK2_U_SRC2_LSB +: 5];
        assign rn_nf[g3*3 + 0] = u_s1f(u);
        assign rn_nf[g3*3 + 1] = u_s2f(u);
        assign rn_nf[g3*3 + 2] = u_s3f(u);
        assign rn_sf_arn[(g3*3+0)*5 +: 5] = u[`BACK2_U_SRC1_LSB +: 5];
        assign rn_sf_arn[(g3*3+1)*5 +: 5] = u[`BACK2_U_SRC2_LSB +: 5];
        assign rn_sf_arn[(g3*3+2)*5 +: 5] = u[`BACK2_U_SRC3_LSB +: 5];
    end
    endgenerate

    rename #(.W(DISP_W), .NSRC(2), .PDW(PW_I), .NREG(`BACK2_PRF_I_N), .FREE_N(`BACK2_FREE_I_N))
    u_ren_i (
        .clk(clk), .rst_n(rst_n),
        .lane_valid(rn_v), .lane_fire(disp_fire_w),
        .lane_need_dst(rn_ndst), .lane_dst_arn(rn_darn),
        .lane_need_s(rn_ni), .lane_s_arn(rn_si_arn),
        .lane_pd_dst(pd_i_dst), .lane_pd_old(pd_i_old), .lane_pd_s(pd_i_s),
        .free_ok(free_i_ok), .free_cnt_o(free_i_cnt),
        .cmt_we(cmt_i_we), .cmt_arn(cmt_i_arn), .cmt_pd(cmt_i_pd),
        .rel_we(rel_i_we), .rel_preg(rel_i_pd),
        .rob_snap_valid(~rn_i_busy),
        .rob_snap_idx({rob_alloc_idx0 + 7'd3, rob_alloc_idx0 + 7'd2,
                       rob_alloc_idx0 + 7'd1, rob_alloc_idx0}),
        .snap_valid(snap_v_w), .snap_id(snap_id_w), .snap_lane(snap_lane_w),
        .restore_valid(restore_ck_v_w), .restore_id(restore_ck_id_w),
        .restore_rob_valid(restore_rob_v_w), .restore_rob_idx(restore_rob_idx_w),
        .flush_all(flush_all_w), .busy(rn_i_busy), .log_wr_o(), .cnt_restore_o()
    );

    rename #(.W(DISP_W), .NSRC(3), .PDW(PW_F), .NREG(`BACK2_PRF_F_N), .FREE_N(`BACK2_FREE_F_N))
    u_ren_f (
        .clk(clk), .rst_n(rst_n),
        .lane_valid(rn_v), .lane_fire(disp_fire_w),
        .lane_need_dst(rn_ndst_f), .lane_dst_arn(rn_darn_f),
        .lane_need_s(rn_nf), .lane_s_arn(rn_sf_arn),
        .lane_pd_dst(pd_f_dst), .lane_pd_old(pd_f_old), .lane_pd_s(pd_f_s),
        .free_ok(free_f_ok), .free_cnt_o(free_f_cnt),
        .cmt_we(cmt_f_we), .cmt_arn(cmt_f_arn), .cmt_pd(cmt_f_pd),
        .rel_we(rel_f_we), .rel_preg(rel_f_pd),
        .rob_snap_valid(~rn_f_busy),
        .rob_snap_idx({rob_alloc_idx0 + 7'd3, rob_alloc_idx0 + 7'd2,
                       rob_alloc_idx0 + 7'd1, rob_alloc_idx0}),
        .snap_valid(snap_v_w), .snap_id(snap_id_w), .snap_lane(snap_lane_w),
        .restore_valid(restore_ck_v_w), .restore_id(restore_ck_id_w),
        .restore_rob_valid(restore_rob_v_w), .restore_rob_idx(restore_rob_idx_w),
        .flush_all(flush_all_w), .busy(rn_f_busy), .log_wr_o(), .cnt_restore_o()
    );

    // ---- 队列余量 & 停顿（S4/S5/S3/S6：整块停顿，不做部分派发）----
    //   ★ `iq_cnt[q]` 接的是 iq.v 的 **free_cnt（剩余空位）**（见 §5 例化），
    //     `q_wr_n[q]` 是本块要写入该队列的条数 ⇒ "装得下" = q_wr_n ≤ 空位，
    //     此时 `iq_free_ok` 必须为 **1**。旧版三目写反（有空位反而判 0）⇒ 派发
    //     恒被 S4 挡住、后端永不派发（实测：D1 持块、ROB 恒空、一条不提交）。
    assign iq_free_ok[0] = (q_wr_n[0] <= iq_cnt[0]);
    assign iq_free_ok[1] = (q_wr_n[1] <= iq_cnt[1]);
    assign iq_free_ok[2] = (q_wr_n[2] <= iq_cnt[2]);
    assign iq_free_ok[3] = (q_wr_n[3] <= iq_cnt[3]);
    assign iq_free_ok[4] = (q_wr_n[4] <= iq_cnt[4]);
    assign iq_free_ok[5] = (q_wr_n[5] <= iq_cnt[5]);
    wire iq_room_ok = &iq_free_ok;

    // STQ 分配许可（store 项）
    wire [3:0] st_alloc_v;
    assign st_alloc_v[0] = d1_v_q[0] & d1_uop_q[0][`BACK2_UB_IS_STORE];
    assign st_alloc_v[1] = d1_v_q[1] & d1_uop_q[1][`BACK2_UB_IS_STORE];
    assign st_alloc_v[2] = d1_v_q[2] & d1_uop_q[2][`BACK2_UB_IS_STORE];
    assign st_alloc_v[3] = d1_v_q[3] & d1_uop_q[3][`BACK2_UB_IS_STORE];
    wire       st_alloc_ok;
    wire [15:0] st_alloc_idx;
    wire [3:0]  lsu_dr_ok_w;
    wire        disp_ok = (d1_v_q != {DISP_W{1'b0}}) & ~rn_i_busy & ~rn_f_busy &
                          ~squash_v_w & ~flush_all_w & ~trap_halt_q &
                          rob_alloc_ready & free_i_ok & free_f_ok & iq_room_ok & st_alloc_ok;
    assign disp_fire_w = disp_ok;
    assign blk_ready_o = (d1_v_q == {DISP_W{1'b0}}) | disp_fire_w;

    // ---- 最终 uop（填重命名结果）----
    wire [UOPW-1:0] lane_uop_fin [0:DISP_W-1];
    wire [DISP_W*5-1:0] lane_rdy;      // {s1i,s2i,s1f,s2f,s3f}
    genvar g4;
    generate
    for (g4 = 0; g4 < DISP_W; g4 = g4 + 1) begin : g_uopf
        wire [UOPW-1:0] u = d1_uop_q[g4];
        wire [PW_I-1:0] pdi  = pd_i_dst[g4*PW_I +: PW_I];
        wire [PW_I-1:0] pdio = pd_i_old[g4*PW_I +: PW_I];
        wire [PW_F-1:0] pdf  = pd_f_dst[g4*PW_F +: PW_F];
        wire [PW_F-1:0] pdfo = pd_f_old[g4*PW_F +: PW_F];
        wire [PW_I-1:0] p1i  = pd_i_s[(g4*2+0)*PW_I +: PW_I];
        wire [PW_I-1:0] p2i  = pd_i_s[(g4*2+1)*PW_I +: PW_I];
        wire [PW_F-1:0] p1f  = pd_f_s[(g4*3+0)*PW_F +: PW_F];
        wire [PW_F-1:0] p2f  = pd_f_s[(g4*3+1)*PW_F +: PW_F];
        wire [PW_F-1:0] p3f  = pd_f_s[(g4*3+2)*PW_F +: PW_F];

        //   ★ 用**显式拼接**替换 PSPD 段，不用 `u & ~(mask << LSB)`：
        //     `58'h… << 75` 的自决定位宽是 58 ⇒ 移位结果恒 0（掩码失效），且 x|值 = x。
        //     段序（MSB→LSB）必须与 back2_params.vh §2 的 PSPD 段一致：
        //     PDIDST(132:126) PDIOLD(125:119) PDFDST(118:113) PDFOLD(112:107)
        //     PS1I(106:100) PS2I(99:93) PS1F(92:87) PS2F(86:81) PS3F(80:75)
        assign lane_uop_fin[g4] = {u[UOPW-1:`BACK2_U_PSPD_MSB+1],
                                   pdi, pdio, pdf, pdfo, p1i, p2i, p1f, p2f, p3f,
                                   u[`BACK2_U_PSPD_LSB-1:0]};

        //   ★ **同块内前递就绪抑制**（实测缺陷）：`busy_i_q` 是**派发前**的位图，
        //     同一 block 内更早 lane 刚分配的物理号要到下一拍才置忙 ⇒ 本 lane 直接
        //     看 busy 会误判"源已就绪"，于是**越过生产者提前发射**，从 PRF 读到 0
        //     （实测：4 深 WAW 链 `addi→xori→slli→srli` 的 `srli` 提前 2 拍发射，
        //     读到 0 而非 0x1a，C1 锁步分歧）。
        //   修法：本 lane 的源若正是"更早 lane 的新目的物理号"，则该源此刻**不可用**
        //     （等生产者的写回唤醒；IQ 的唤醒/延迟广播会把它置就绪）。
        wire [PW_I-1:0] s1i = pd_i_s[(g4*2+0)*PW_I +: PW_I];
        wire [PW_I-1:0] s2i = pd_i_s[(g4*2+1)*PW_I +: PW_I];
        wire [PW_F-1:0] s1f = pd_f_s[(g4*3+0)*PW_F +: PW_F];
        wire [PW_F-1:0] s2f = pd_f_s[(g4*3+1)*PW_F +: PW_F];
        wire [PW_F-1:0] s3f = pd_f_s[(g4*3+2)*PW_F +: PW_F];
        wire h1i = ((g4 > 0) & d1_v_q[0] & rn_ndst[0] & (pd_i_dst[0*PW_I +: PW_I] == s1i)) |
                   ((g4 > 1) & d1_v_q[1] & rn_ndst[1] & (pd_i_dst[1*PW_I +: PW_I] == s1i)) |
                   ((g4 > 2) & d1_v_q[2] & rn_ndst[2] & (pd_i_dst[2*PW_I +: PW_I] == s1i));
        wire h2i = ((g4 > 0) & d1_v_q[0] & rn_ndst[0] & (pd_i_dst[0*PW_I +: PW_I] == s2i)) |
                   ((g4 > 1) & d1_v_q[1] & rn_ndst[1] & (pd_i_dst[1*PW_I +: PW_I] == s2i)) |
                   ((g4 > 2) & d1_v_q[2] & rn_ndst[2] & (pd_i_dst[2*PW_I +: PW_I] == s2i));
        wire h1f = ((g4 > 0) & d1_v_q[0] & rn_ndst_f[0] & (pd_f_dst[0*PW_F +: PW_F] == s1f)) |
                   ((g4 > 1) & d1_v_q[1] & rn_ndst_f[1] & (pd_f_dst[1*PW_F +: PW_F] == s1f)) |
                   ((g4 > 2) & d1_v_q[2] & rn_ndst_f[2] & (pd_f_dst[2*PW_F +: PW_F] == s1f));
        wire h2f = ((g4 > 0) & d1_v_q[0] & rn_ndst_f[0] & (pd_f_dst[0*PW_F +: PW_F] == s2f)) |
                   ((g4 > 1) & d1_v_q[1] & rn_ndst_f[1] & (pd_f_dst[1*PW_F +: PW_F] == s2f)) |
                   ((g4 > 2) & d1_v_q[2] & rn_ndst_f[2] & (pd_f_dst[2*PW_F +: PW_F] == s2f));
        wire h3f = ((g4 > 0) & d1_v_q[0] & rn_ndst_f[0] & (pd_f_dst[0*PW_F +: PW_F] == s3f)) |
                   ((g4 > 1) & d1_v_q[1] & rn_ndst_f[1] & (pd_f_dst[1*PW_F +: PW_F] == s3f)) |
                   ((g4 > 2) & d1_v_q[2] & rn_ndst_f[2] & (pd_f_dst[2*PW_F +: PW_F] == s3f));
        assign lane_rdy[g4*5 + 0] = ~u_s1i(u) | (~busy_i_q[p1i] & ~h1i);
        assign lane_rdy[g4*5 + 1] = ~u_s2i(u) | (~busy_i_q[p2i] & ~h2i);
        assign lane_rdy[g4*5 + 2] = ~u_s1f(u) | (~busy_f_q[p1f] & ~h1f);
        assign lane_rdy[g4*5 + 3] = ~u_s2f(u) | (~busy_f_q[p2f] & ~h2f);
        assign lane_rdy[g4*5 + 4] = ~u_s3f(u) | (~busy_f_q[p3f] & ~h3f);
    end
    endgenerate

    // ---- IQ 写口组装 ----
    //   ★ 写使能必须与"真正派发"（disp_fire_w）相与：D1 寄存器在等余量时可能连续
    //     多拍持有同一块，若只按 d1_v_q 给 wr_valid，同一块会被反复压入队列
    //     （实测：队列被同一块灌满、后端假提交）。
    wire [6*WI-1:0] iq_wv_g = disp_fire_w ? iq_wv : {(6*WI){1'b0}};
    always @(*) begin
        for (qi = 0; qi < 6; qi = qi + 1) begin
            iq_wv  [qi*WI +: WI]           = {WI{1'b0}};
            iq_wuop[qi*WI*UOPW +: WI*UOPW] = {(WI*UOPW){1'b0}};
            iq_wrob[qi*WI*7 +: WI*7]       = {(WI*7){1'b0}};
            iq_wrdy[qi*WI*SRC_N +: WI*SRC_N] = {(WI*SRC_N){1'b0}};
        end
        for (gi2 = 0; gi2 < DISP_W; gi2 = gi2 + 1) begin
            if (d1_v_q[gi2]) begin
                iq_wv  [lane_q[gi2*3 +: 3]*WI + q_ord[gi2]] = 1'b1;
                iq_wuop[lane_q[gi2*3 +: 3]*WI*UOPW + q_ord[gi2]*UOPW +: UOPW] =
                        lane_uop_fin[gi2];
                iq_wrob[lane_q[gi2*3 +: 3]*WI*7 + q_ord[gi2]*7 +: 7] =
                        rob_alloc_idx0 + gi2[6:0];
                iq_wrdy[lane_q[gi2*3 +: 3]*WI*SRC_N + q_ord[gi2]*SRC_N +: SRC_N] =
                        lane_rdy[gi2*5 +: 5];
            end
        end
    end

    // ---- ROB 载荷组装 ----
    genvar g5;
    generate
    for (g5 = 0; g5 < DISP_W; g5 = g5 + 1) begin : g_rb
        assign rob_pay_w[g5*RB_W +: RB_W] = {
            st_alloc_idx[g5*4 +: 4],                       // STQ 索引
            5'b0,                                          // fflags
            1'b0,                                          // tr_taken（执行期回写）
            32'h0,                                         // tr 实际目标（执行期回写）
            d1_uop_q[g5][`BACK2_U_TVAL_MSB:`BACK2_U_TVAL_LSB],   // 异常 tval
            32'h0,                                         // CSR 新值（执行期回写）
            lane_uop_fin[g5]                               // uop
        };
    end
    endgenerate

    // ---- 检查点快照/释放登记 ----
    reg [1:0] snap_lane_r;
    reg       snap_v_r;
    reg [3:0] snap_id_r;
    integer   ci2;
    always @(*) begin
        snap_v_r    = 1'b0;
        snap_lane_r = 2'd0;
        snap_id_r   = 4'd0;
        for (ci2 = 0; ci2 < DISP_W; ci2 = ci2 + 1) begin
            if (d1_v_q[ci2] && d1_uop_q[ci2][`BACK2_UB_CKPT_VALID] && !snap_v_r) begin
                snap_v_r    = 1'b1;
                snap_lane_r = ci2[1:0];
                snap_id_r   = d1_uop_q[ci2][`BACK2_U_CKPT_MSB:`BACK2_U_CKPT_LSB];
            end
        end
    end

    assign snap_v_w    = snap_v_r & disp_fire_w;
    assign snap_id_w   = snap_id_r;
    assign snap_lane_w = snap_lane_r;

    //==========================================================================
    // 5. 六个发射队列（分布式）
    //==========================================================================
    wire [UOPW-1:0] i0_sel_uop; wire i0_sel_v; wire [6:0] i0_sel_rob;
    wire [UOPW-1:0] i1_sel_uop; wire i1_sel_v; wire [6:0] i1_sel_rob;
    wire [UOPW-1:0] i2_sel_uop; wire i2_sel_v; wire [6:0] i2_sel_rob;
    wire [UOPW-1:0] i3_sel_uop; wire i3_sel_v; wire [6:0] i3_sel_rob;
    wire [UOPW-1:0] i4_sel_uop; wire i4_sel_v; wire [6:0] i4_sel_rob;
    wire [UOPW-1:0] i5_sel_uop; wire i5_sel_v; wire [6:0] i5_sel_rob;
    wire [5:0] wk_i_v_w;
    wire [6*PW_I-1:0] wk_i_tag_w;
    wire [5:0] wk_f_v_w;
    wire [6*PW_F-1:0] wk_f_tag_w;
    // CSR 只在 ALU0、且必须已到 ROB 头（§8.3：读写都按提交序可见）
    wire al0_csr_blk = i0_sel_v & u_is_csr(i0_sel_uop) & (i0_sel_rob != rob_head_w);

    wire [2:0] q0_ready = ~al0_csr_blk;
    wire [2:0] q1_ready = 3'd1;
    wire [2:0] q2_ready = 3'd1;
    wire [2:0] q3_ready = mdu_free_w ? 3'd1 : 3'd0;
    //   ★ LSU 队列的发射门控**只对 load 生效**：`lsu_iss_ok`（来自 lsq_simple）语义是
    //     "STQ 内没有更老的**未定址** store ⇒ load 可安全乱序取数"；对 **store 自身**
    //     必须放行，否则队头 store 永远算不出地址 ⇒ STQ 永远存在未定址项 ⇒ `iss_ok`
    //     恒 0 ⇒ 自锁（实测：程序尾 `sw x31,0(x30)` 停在 ROB 头 `hdone=0`、LSU 队列
    //     `sel=1/iss=0`、`stq=1`、后端永久停顿）。q4_ready 供观察，iss_ready 用新判据。
    wire lsu_ld_block = u_is_ld(i4_sel_uop) & ~lsu_iss_ok_w;
    wire [2:0] q4_ready = ~lsu_ld_block;
    wire [2:0] q5_ready = fpu_free_w ? 3'd1 : 3'd0;

    iq #(.DEPTH(`BACK2_IQ_ALU0_D), .DBG(DBG_IQ)) u_iq0 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[0*WI +: WI]), .wr_uop(iq_wuop[0*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[0*WI*7 +: WI*7]), .wr_rdy(iq_wrdy[0*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[0]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(~al0_csr_blk),
        .iss_valid(iq_iss_v[0]), .iss_uop(iq_iss_uop[0]), .iss_rob(iq_iss_rob[0]),
        .iss_epoch(iq_iss_ep[0]), .iss_dead(iq_iss_dead[0]),
        .o_sel_v(i0_sel_v), .o_sel_uop(i0_sel_uop), .o_sel_rob(i0_sel_rob), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_ALU1_D), .DBG(DBG_IQ)) u_iq1 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[1*WI +: WI]), .wr_uop(iq_wuop[1*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[1*WI*7 +: WI*7]), .wr_rdy(iq_wrdy[1*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[1]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(1'b1),
        .iss_valid(iq_iss_v[1]), .iss_uop(iq_iss_uop[1]), .iss_rob(iq_iss_rob[1]),
        .iss_epoch(iq_iss_ep[1]), .iss_dead(iq_iss_dead[1]),
        .o_sel_v(i1_sel_v), .o_sel_uop(i1_sel_uop), .o_sel_rob(i1_sel_rob), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_BRU_D), .DBG(DBG_IQ)) u_iq2 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[2*WI +: WI]), .wr_uop(iq_wuop[2*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[2*WI*7 +: WI*7]), .wr_rdy(iq_wrdy[2*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[2]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(1'b1),
        .iss_valid(iq_iss_v[2]), .iss_uop(iq_iss_uop[2]), .iss_rob(iq_iss_rob[2]),
        .iss_epoch(iq_iss_ep[2]), .iss_dead(iq_iss_dead[2]),
        .o_sel_v(i2_sel_v), .o_sel_uop(i2_sel_uop), .o_sel_rob(i2_sel_rob), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_MDU_D), .DBG(DBG_IQ)) u_iq3 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[3*WI +: WI]), .wr_uop(iq_wuop[3*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[3*WI*7 +: WI*7]), .wr_rdy(iq_wrdy[3*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[3]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(mdu_free_w),
        .iss_valid(iq_iss_v[3]), .iss_uop(iq_iss_uop[3]), .iss_rob(iq_iss_rob[3]),
        .iss_epoch(iq_iss_ep[3]), .iss_dead(iq_iss_dead[3]),
        .o_sel_v(i3_sel_v), .o_sel_uop(i3_sel_uop), .o_sel_rob(i3_sel_rob), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_LSU_D), .DBG(DBG_IQ), .INORD_LOAD(1)) u_iq4 (   // B28: LSU in-order gate
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[4*WI +: WI]), .wr_uop(iq_wuop[4*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[4*WI*7 +: WI*7]), .wr_rdy(iq_wrdy[4*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[4]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(~lsu_ld_block),
        .iss_valid(iq_iss_v[4]), .iss_uop(iq_iss_uop[4]), .iss_rob(iq_iss_rob[4]),
        .iss_epoch(iq_iss_ep[4]), .iss_dead(iq_iss_dead[4]),
        .o_sel_v(i4_sel_v), .o_sel_uop(i4_sel_uop), .o_sel_rob(i4_sel_rob), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_FPU_D), .DBG(DBG_IQ)) u_iq5 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[5*WI +: WI]), .wr_uop(iq_wuop[5*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[5*WI*7 +: WI*7]), .wr_rdy(iq_wrdy[5*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[5]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(fpu_free_w),
        .iss_valid(iq_iss_v[5]), .iss_uop(iq_iss_uop[5]), .iss_rob(iq_iss_rob[5]),
        .iss_epoch(iq_iss_ep[5]), .iss_dead(iq_iss_dead[5]),
        .o_sel_v(i5_sel_v), .o_sel_uop(i5_sel_uop), .o_sel_rob(i5_sel_rob), .cnt_o()
    );

    // 选择观察口汇总（诊断/外部门控用；旧版只在 §1 声明了 iq_sel_v 却从未驱动
    //   ⇒ 悬空网 z，任何引用都会把 x 传下去。此处补上唯一赋值点。）
    assign iq_sel_v = {i5_sel_v, i4_sel_v, i3_sel_v, i2_sel_v, i1_sel_v, i0_sel_v};

    //==========================================================================
    // 6. I2 寄存器 + E1 执行
    //==========================================================================
    integer xi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (xi = 0; xi < 6; xi = xi + 1) x_i2_v[xi] <= 1'b0;
        end else begin
            for (xi = 0; xi < 6; xi = xi + 1) begin
                x_i2_v[xi] <= iq_iss_v[xi] & ~iq_iss_dead[xi];
                if (iq_iss_v[xi]) begin
                    x_i2_uop[xi] <= iq_iss_uop[xi];
                    x_i2_rob[xi] <= iq_iss_rob[xi];
                    x_i2_ep[xi]  <= iq_iss_ep[xi];
                end
            end
        end
    end

    wire [31:0] a0_opa = u_au(iq_iss_uop[0] ? x_i2_uop[0] : x_i2_uop[0]) ? u_pc(x_i2_uop[0]) : iprf_rd[0*32 +: 32];
    wire [31:0] a0_opb = u_rt(x_i2_uop[0]) ? iprf_rd[1*32 +: 32] : u_imm(x_i2_uop[0]);
    wire [31:0] a0_res;
    alu u_alu0 (.a(a0_opa), .b(a0_opb),
                .alu_op(x_i2_uop[0][`BACK2_U_ALUOP_MSB:`BACK2_U_ALUOP_LSB]),
                .pc(u_pc(x_i2_uop[0])), .result(a0_res));

    wire [31:0] a1_opa = u_au(x_i2_uop[1]) ? u_pc(x_i2_uop[1]) : iprf_rd[2*32 +: 32];
    wire [31:0] a1_opb = u_rt(x_i2_uop[1]) ? iprf_rd[3*32 +: 32] : u_imm(x_i2_uop[1]);
    wire [31:0] a1_res;
    alu u_alu1 (.a(a1_opa), .b(a1_opb),
                .alu_op(x_i2_uop[1][`BACK2_U_ALUOP_MSB:`BACK2_U_ALUOP_LSB]),
                .pc(u_pc(x_i2_uop[1])), .result(a1_res));

    wire [31:0] bru_rs1 = iprf_rd[4*32 +: 32];
    wire [31:0] bru_rs2 = iprf_rd[5*32 +: 32];
    wire        bru_taken;
    wire [31:0] bru_target;
    bru u_bru (.rs1(bru_rs1), .rs2(bru_rs2), .imm(u_imm(x_i2_uop[2])), .pc(u_pc(x_i2_uop[2])),
               .br_op(x_i2_uop[2][`BACK2_U_BROP_MSB:`BACK2_U_BROP_LSB]),
               .taken(bru_taken), .target(bru_target));
    wire        bru_isjal  = (u_opt(x_i2_uop[2]) == OPT_JAL);
    wire        bru_isjalr = (u_opt(x_i2_uop[2]) == OPT_JALR);
    wire        bru_act_tk = bru_isjal | bru_isjalr | bru_taken;
    wire [31:0] bru_ilen   = u_il32(x_i2_uop[2]) ? 32'd4 : 32'd2;
    wire [31:0] bru_link   = u_pc(x_i2_uop[2]) + bru_ilen;
    wire [31:0] bru_npc    = bru_act_tk ? bru_target : bru_link;
    wire [31:0] bru_pred_t = {32{x_i2_uop[2][`BACK2_U_PRED_MSB]}} & u_predtgt(x_i2_uop[2]);
    wire [31:0] bru_pred_n = x_i2_uop[2][`BACK2_U_PRED_MSB] ? u_predtgt(x_i2_uop[2]) : bru_link;
    wire [2:0]  bru_cls    = u_cls(x_i2_uop[2]);
    //   ★ 误判判定必须覆盖**全部控制转移**（cls != 0）：
    //     · 方向：任何控制转移都要与实际方向比（条件分支的条件分支走向是预测出来的，
    //       是最常见的误判源）；
    //     · 目标：只有"前端用 BTB/RAS 预测目标"的类别（jalr 类 3/4/6）才比目标——
    //       直接跳转/条件分支的 taken 目标由前端按 PC+imm 自算，不会与 BRU 的目标不一致。
    //   旧实现把 `bru_cmp` 写成只含 3/4/6 ⇒ **条件分支误判永不被发现**（无重定向、
    //   错路径照常提交）。实测：程序 0 第 26 条起走错路（循环回边未重定向，
    //   提交流出现循环外的 PC 0x8000_0068，与黄金轨迹分歧）。
    wire        bru_is_ctl = (bru_cls != 3'd0);
    wire        bru_cmp_t  = (bru_cls == 3'd3) | (bru_cls == 3'd4) | (bru_cls == 3'd6);
    wire        bru_mis    = bru_is_ctl &
                             ((bru_act_tk != x_i2_uop[2][`BACK2_U_PRED_MSB]) |
                              (bru_act_tk & bru_cmp_t & (bru_target != bru_pred_n)));

    // MDU（至多 1 条在飞；busy/done 握手）
    wire        mdu_busy, mdu_done;
    wire [31:0] mdu_result;
    wire        mdu_go = iq_iss_v[3];
    wire [4:0] mdu_brop = x_i2_uop[3][`BACK2_U_BROP_MSB:`BACK2_U_BROP_LSB];
    mdu u_mdu (.aclk(clk), .aresetn(rst_n), .start(mdu_go), .flush(squash_v_w | flush_all_w),
               .mdu_op(mdu_brop[2:0]),
               .a(iprf_rd[6*32 +: 32]), .b(iprf_rd[7*32 +: 32]),
               .busy(mdu_busy), .done(mdu_done), .result(mdu_result));

    // FPU（至多 1 条在飞）
    wire        fpu_busy, fpu_done, fpu_ffwe;
    wire [63:0] fpu_result;
    wire [4:0]  fpu_ff;
    wire [63:0] fpu_a = u_s1f(x_i2_uop[5]) ? fprf_rd[0*64 +: 64]
                                            : {32'hFFFF_FFFF, iprf_rd[10*32 +: 32]};
    fpu u_fpu (
        .clk(clk), .rst_n(rst_n), .flush(squash_v_w | flush_all_w),
        .req_valid(iq_iss_v[5]), .fp_op(u_fpop(x_i2_uop[5])),
        .fmt(u_fmt(x_i2_uop[5])), .rm(x_i2_uop[5][`BACK2_U_RM_MSB:`BACK2_U_RM_LSB]),
        .frm(csr_frm_w), .a(fpu_a), .b(fprf_rd[1*64 +: 64]), .c(fprf_rd[2*64 +: 64]),
        .busy(fpu_busy), .done(fpu_done), .result(fpu_result),
        .fflags_we(fpu_ffwe), .fflags(fpu_ff)
    );

    // LSU（AGU + 过渡访存队列）
    wire        lsu_wb_v, lsu_wb_di, lsu_wb_df;
    wire [6:0]  lsu_wb_rob;
    wire [EW-1:0] lsu_wb_ep;
    wire [PW_I-1:0] lsu_wb_pdi;
    wire [PW_F-1:0] lsu_wb_pdf;
    wire [31:0] lsu_wb_data;
    wire        lsu_st_done_v;
    wire [6:0]  lsu_st_done_rob;
    wire [EW-1:0] lsu_st_done_ep;
    wire [31:0] lsu_addr = iprf_rd[8*32 +: 32] + u_imm(x_i2_uop[4]);
    wire [63:0] lsu_fpsrc = fprf_rd[3*64 +: 64];
    wire [31:0] lsu_wdata = (u_fpls(x_i2_uop[4]) & u_is_st(x_i2_uop[4])) ?
                            lsu_fpsrc[31:0] : iprf_rd[9*32 +: 32];
    lsq_simple #(.DBG(DBG_LSU)) u_lsu (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w),
        .squash(squash_v_w), .squash_idx(squash_idx_w), .rob_head(rob_head_w),
        .alloc_valid(st_alloc_v & {DISP_W{disp_fire_w}}),
        .alloc_ok(st_alloc_ok), .alloc_idx(st_alloc_idx),
        .exe_valid(x_i2_v[4]), .exe_is_store(u_is_st(x_i2_uop[4])),
        .exe_is_fp(u_fpls(x_i2_uop[4])),
        .exe_rob(x_i2_rob[4]), .exe_epoch(x_i2_ep[4]),
        .exe_addr(lsu_addr), .exe_wdata(lsu_wdata),
        .exe_size(x_i2_uop[4][`BACK2_U_MSIZE_MSB:`BACK2_U_MSIZE_LSB]),
        .exe_unsign(x_i2_uop[4][`BACK2_U_MUNSIGN]),
        .exe_dst_i(u_di(x_i2_uop[4])), .exe_dst_f(u_df(x_i2_uop[4])),
        //   ★ 目的物理号取 **PDIDST**（u_pdi），不是源 1（u_ps1i）；写口/唤醒 tag 同源。
        .exe_pdest_i(u_pdi(x_i2_uop[4])), .exe_pdest_f(u_pdf(x_i2_uop[4])),
        .exe_stq_idx(stq_of_rob_r),
        .iss_ok(lsu_iss_ok_w), 
        .dr_valid(lsu_dr_valid), .dr_idx(lsu_dr_idx),
        .mem_req_valid(mem_req_valid_o), .mem_req_wen(mem_req_wen_o),
        .mem_req_addr(mem_req_addr_o), .mem_req_wdata(mem_req_wdata_o),
        .mem_req_wstrb(mem_req_wstrb_o), .mem_req_tag(mem_req_tag_o),
        .mem_req_ready(mem_req_ready_i),
        .mem_rsp_valid(mem_rsp_valid_i), .mem_rsp_rdata(mem_rsp_rdata_i),
        .mem_rsp_tag(mem_rsp_tag_i),
        .wb_valid(lsu_wb_v), .wb_rob(lsu_wb_rob), .wb_epoch(lsu_wb_ep),
        .wb_dst_i(lsu_wb_di), .wb_dst_f(lsu_wb_df),
        .wb_pdest_i(lsu_wb_pdi), .wb_pdest_f(lsu_wb_pdf), .wb_data(lsu_wb_data),
        .st_done_valid(lsu_st_done_v), .st_done_rob(lsu_st_done_rob),
        .st_done_epoch(lsu_st_done_ep),
        .stq_cnt_o(dbg_stq_cnt_o), .cnt_load_o(), .cnt_store_o(), .cnt_fwd_o(),
        .cnt_stq_stall_o()
    );

    //==========================================================================
    // 7. 写回总线 / 唤醒 / PRF
    //==========================================================================
    assign mdu_free_w = ~mdu_if_v;
    assign fpu_free_w = ~fpu_if_v;
    assign stq_of_rob_r = stq_of_rob[x_i2_rob[4]];
    wire [31:0] a0_wb_data = (csr_v_w & (csr_uop[`BACK2_UAX_Q_MSB:`BACK2_UAX_Q_LSB] == `BACK2_Q_ALU0))
                             ? csr_rdata_w : a0_res;   // ★ B29：按 CSR 实际槽/队列
    wire        a0_wb_i    = u_di(x_i2_uop[0]);
    wire [31:0] a1_wb_data = a1_res;
    wire        a1_wb_i    = u_di(x_i2_uop[1]);
    wire [31:0] bru_wb_data = (u_wbsel(x_i2_uop[2]) == WB_PC4) ? bru_link : bru_target;
    wire        bru_wb_i    = u_di(x_i2_uop[2]);
    wire        mdu_wb_v    = mdu_done & mdu_if_v;
    wire [31:0] mdu_wb_data = mdu_result;
    wire        fpu_wb_v    = fpu_done & fpu_if_v;
    wire        fpu_wb_i    = fpu_if_di;
    wire        fpu_wb_f    = fpu_if_df;
    wire [31:0] fpu_wb_idata= fpu_result[31:0];
    wire [63:0] fpu_wb_fdata= fpu_result;
    wire        lsu_wb_f    = lsu_wb_df;

    assign wb_v[WBP_ALU0] = x_i2_v[0];
    assign wb_v[WBP_ALU1] = x_i2_v[1];
    assign wb_v[WBP_BRU]  = x_i2_v[2];
    assign wb_v[WBP_MDU]  = mdu_wb_v;
    assign wb_v[WBP_LSU]  = lsu_wb_v;
    assign wb_v[WBP_FPU]  = fpu_wb_v;
    assign wb_v[WBP_STD]  = lsu_st_done_v;
    assign wb_rob[WBP_ALU0*7 +: 7] = x_i2_rob[0];
    assign wb_rob[WBP_ALU1*7 +: 7] = x_i2_rob[1];
    assign wb_rob[WBP_BRU*7 +: 7]  = x_i2_rob[2];
    assign wb_rob[WBP_MDU*7 +: 7]  = mdu_if_rob;
    assign wb_rob[WBP_LSU*7 +: 7]  = lsu_wb_rob;
    assign wb_rob[WBP_FPU*7 +: 7]  = fpu_if_rob;
    assign wb_rob[WBP_STD*7 +: 7]  = lsu_st_done_rob;
    assign wb_ep[WBP_ALU0*EW +: EW] = x_i2_ep[0];
    assign wb_ep[WBP_ALU1*EW +: EW] = x_i2_ep[1];
    assign wb_ep[WBP_BRU*EW +: EW]  = x_i2_ep[2];
    assign wb_ep[WBP_MDU*EW +: EW]  = mdu_if_ep;
    assign wb_ep[WBP_LSU*EW +: EW]  = lsu_wb_ep;
    assign wb_ep[WBP_FPU*EW +: EW]  = fpu_if_ep;
    assign wb_ep[WBP_STD*EW +: EW]  = lsu_st_done_ep;

    assign wbi_v = { (fpu_wb_v & fpu_wb_i), (lsu_wb_v & lsu_wb_di), mdu_wb_v,
                     (x_i2_v[2] & bru_wb_i), (x_i2_v[1] & a1_wb_i), (x_i2_v[0] & a0_wb_i) };
    function in_rob_win;
        input [6:0] idx;
        begin
            in_rob_win = ({1'b0, (idx - rob_head_w)} < rob_cnt_w);
        end
    endfunction
    //   ★ 这里**不用 function 调用**（展开为纯表达式）：iverilog 12.0 在把 function
    //     调用放进连续赋值/位拼接时实测会给出错误结果（本文件另一处 generate 内
    //     调用 function 也有同类记录，见 iq.v §1 注）。展开写法与函数语义逐位相同。
    wire [5:0] wbi_keep = {
        ({1'b0, (wb_rob[5*7 +: 7] - rob_head_w)} < rob_cnt_w),
        ({1'b0, (wb_rob[4*7 +: 7] - rob_head_w)} < rob_cnt_w),
        ({1'b0, (wb_rob[3*7 +: 7] - rob_head_w)} < rob_cnt_w),
        ({1'b0, (wb_rob[2*7 +: 7] - rob_head_w)} < rob_cnt_w),
        ({1'b0, (wb_rob[1*7 +: 7] - rob_head_w)} < rob_cnt_w),
        ({1'b0, (wb_rob[0*7 +: 7] - rob_head_w)} < rob_cnt_w) };
    //   ★ 写回 tag = **目的**物理号（PDIDST/PDFDST），供 ① PRF 写口 ② busy 位清零
    //     ③ 唤醒广播 三处共用。旧版误写成源 1（ps1i）⇒ 结果写进源寄存器、目的
    //     busy 位永不清零 ⇒ 消费者永不唤醒（实测：lui 之后的 jalr 永不发射）。
    assign wbi_tag = { u_pdi(x_i2_uop[5]), lsu_wb_pdi, mdu_if_pdi,
                       u_pdi(x_i2_uop[2]), u_pdi(x_i2_uop[1]), u_pdi(x_i2_uop[0]) };
    assign wbi_data = { fpu_wb_idata, lsu_wb_data, mdu_wb_data, bru_wb_data, a1_wb_data, a0_wb_data };

    assign wki_v   = NO_WAKE ? {wbi_v[5], wbi_v[4], wbi_v[3], wbi_v[2], 1'b0, wbi_v[0]} : wbi_v;
    assign wki_tag = wbi_tag;
    assign wk_i_v_w = wki_v;
    assign wk_i_tag_w = wki_tag;
    assign wk_f_v_w   = {{(6-2){1'b0}}, (fpu_wb_v & fpu_wb_f), (lsu_wb_v & lsu_wb_f)};
    assign wk_f_tag_w = {{(6*PW_F - 2*PW_F){1'b0}}, u_pdf(x_i2_uop[5]), lsu_wb_pdf};

    //==========================================================================
    // 8. 忙碌位图（发射就绪判定：物理寄存器的生产者尚未写回）
    //==========================================================================

    integer bi;
    always @(*) begin
        busy_i_nx = busy_i_q;
        busy_f_nx = busy_f_q;
        for (bi = 0; bi < DISP_W; bi = bi + 1) begin
            if (disp_fire_w) begin
                if (rn_ndst[bi])   busy_i_nx[pd_i_dst[bi*PW_I +: PW_I]] = 1'b1;
                if (rn_ndst_f[bi]) busy_f_nx[pd_f_dst[bi*PW_F +: PW_F]] = 1'b1;
            end
        end
        for (bi = 0; bi < 6; bi = bi + 1) begin
            if (wbi_v[bi] && (wb_ep[bi*EW +: EW] == epoch_w))
                busy_i_nx[wbi_tag[bi*PW_I +: PW_I]] = 1'b0;
        end
        if (lsu_wb_v & lsu_wb_df & (lsu_wb_ep == epoch_w)) busy_f_nx[lsu_wb_pdf] = 1'b0;
        if (fpu_wb_v & fpu_wb_f & (fpu_if_ep  == epoch_w)) busy_f_nx[u_pdf(x_i2_uop[5])] = 1'b0;
    end

    //==========================================================================
    // 9. 提交（W1）：写回值读出 / 架构 RAT / 释放 / CSR / store 排空 / 训练 / 检查点
    //==========================================================================
    assign cmt_ok = ~(squash_v_w | flush_all_w);
    assign cmt_i2 = x_i2_rob[2];

    genvar cc;
    generate
    for (cc = 0; cc < COMMIT_W; cc = cc + 1) begin : g_cmt
        wire [RB_W-1:0] p = cmt_pay[cc*RB_W +: RB_W];
        assign commit_valid_o[cc] = cmt_raw[cc] & cmt_ok;
        assign commit_pc_o[cc*32 +: 32] = p_pc(p);
        assign commit_arch_rd_o[cc*5 +: 5] = p_arn(p);
        assign commit_arch_we_o[cc] = p_di(p) | p_df(p);
        wire [63:0] cval_f = fprf_rd[(4+cc)*64 +: 64];
        assign commit_arch_rd_wdata_o[cc*32 +: 32] =
            p_di(p) ? iprf_rd[(11+cc)*32 +: 32] :
            p_df(p) ? cval_f[31:0] : 32'h0;
        assign cmt_i_we[cc]   = cmt_raw[cc] & cmt_ok & p_di(p);
        assign cmt_i_arn[cc*5 +: 5] = p_arn(p);
        assign cmt_i_pd[cc*PW_I +: PW_I] = p_pdi(p);
        assign rel_i_we[cc]   = cmt_raw[cc] & cmt_ok & p_di(p);
        assign rel_i_pd[cc*PW_I +: PW_I] = p_pdio(p);
        assign cmt_f_we[cc]   = cmt_raw[cc] & cmt_ok & p_df(p);
        assign cmt_f_arn[cc*5 +: 5] = p_arn(p);
        assign cmt_f_pd[cc*PW_F +: PW_F] = p_pdf(p);
        assign rel_f_we[cc]   = cmt_raw[cc] & cmt_ok & p_df(p);
        assign rel_f_pd[cc*PW_F +: PW_F] = p_pdfo(p);
        assign lsu_dr_valid[cc] = cmt_st_drain[cc] & cmt_ok;
        assign lsu_dr_idx[cc*4 +: 4] = p_stq(p);
    end
    endgenerate

    // 提交点 CSR 写（同拍至多 1 条：CSR 指令只在 ROB 头执行 ⇒ 至多一条在飞）
    reg        csr_cmt_we;  reg [11:0] csr_cmt_addr; reg [31:0] csr_cmt_data;
    reg        ff_cmt_any;  reg [4:0]  ff_cmt_val;
    integer    cw;
    always @(*) begin
        csr_cmt_we   = 1'b0;
        csr_cmt_addr = 12'h0;
        csr_cmt_data = 32'h0;
        ff_cmt_any   = 1'b0;
        ff_cmt_val   = 5'h0;
        for (cw = COMMIT_W-1; cw >= 0; cw = cw - 1) begin
            if (commit_valid_o[cw]) begin
                if (p_csr(cmt_pay[cw*RB_W +: RB_W])) begin
                    csr_cmt_we   = 1'b1;
                    csr_cmt_addr = p_csra(cmt_pay[cw*RB_W +: RB_W]);
                    csr_cmt_data = p_csrw(cmt_pay[cw*RB_W +: RB_W]);
                end
                if (p_ff(cmt_pay[cw*RB_W +: RB_W]) != 5'h0) begin
                    ff_cmt_any = 1'b1;
                    ff_cmt_val = ff_cmt_val | p_ff(cmt_pay[cw*RB_W +: RB_W]);
                end
            end
        end
    end
    // fflags 累积写入（FPU 结果提交时），与 CSR 写并路：地址 0x001 用"读改写"
    wire        csr_we_w    = csr_cmt_we | ff_cmt_any;
    wire [11:0] csr_waddr_w = csr_cmt_we ? csr_cmt_addr : 12'h001;
    wire [31:0] csr_wdata_w = csr_cmt_we ? (csr_cmt_addr == 12'h001 ?
                              (csr_cmt_data | ff_cmt_val) : csr_cmt_data)
                                         : (csr_ff_w | ff_cmt_val);
    //   ★★ B29 修复：CSR 指令可能落在 I2 的**任意槽**（此前四处硬编码槽 0 ⇒ 取到别的指令的
    //     `x_i2_rob[0]`/读口数据 ⇒ `csrrw` 写入了错误值，实测 mscratch 被写成 1 而非 3）。
    //     CSR 属 ALU0 类（D1 的 oq 分配：CSR 的 opt ⇒ Q_ALU0）⇒ 源操作数取 ALU0 的 rs1 读口。
    wire [2:0] csr_lane = (x_i2_v[0] & u_is_csr(x_i2_uop[0])) ? 3'd0 :
                          (x_i2_v[1] & u_is_csr(x_i2_uop[1])) ? 3'd1 :
                          (x_i2_v[2] & u_is_csr(x_i2_uop[2])) ? 3'd2 :
                          (x_i2_v[3] & u_is_csr(x_i2_uop[3])) ? 3'd3 :
                          (x_i2_v[4] & u_is_csr(x_i2_uop[4])) ? 3'd4 :
                          (x_i2_v[5] & u_is_csr(x_i2_uop[5])) ? 3'd5 : 3'd0;
    wire       csr_v_w  = (x_i2_v[0] & u_is_csr(x_i2_uop[0])) | (x_i2_v[1] & u_is_csr(x_i2_uop[1])) |
                          (x_i2_v[2] & u_is_csr(x_i2_uop[2])) | (x_i2_v[3] & u_is_csr(x_i2_uop[3])) |
                          (x_i2_v[4] & u_is_csr(x_i2_uop[4])) | (x_i2_v[5] & u_is_csr(x_i2_uop[5]));
    wire [UOPW-1:0] csr_uop = x_i2_uop[csr_lane];
    assign csr_raddr_w = u_csra(csr_uop);

    //   B29 诊断：I2 CSR 现场 + CSR 提交现场（默认关）
    always @(posedge clk) begin
        if (DBG_CSR && rst_n && csr_v_w)
            $display("[csr-src t=%0t] lane=%0d csr_ps1i=%0d ra0=%0d rd0=0x%08x ra2=%0d rd2=0x%08x | prf_we=%b wa=%0d wd0=0x%08x",
                     $time, csr_lane, u_ps1i(csr_uop), iprf_ra[0*PW_I +: PW_I], iprf_rd[0*32 +: 32],
                     iprf_ra[2*PW_I +: PW_I], iprf_rd[2*32 +: 32],
                     iprf_we, iprf_wa, iprf_wd[0*32 +: 32]);
        if (DBG_CSR && rst_n && x_i2_v[0] && u_is_csr(x_i2_uop[0]))
            $display("[csr-i2 t=%0t] op=%0d addr=0x%03x s1i=%b imm=0x%08x rdata=0x%08x upd_csrw=0x%08x upd_v=%b",
                     $time, u_csrop(x_i2_uop[0]), u_csra(x_i2_uop[0]),
                     u_s1i(x_i2_uop[0]), u_imm(x_i2_uop[0]), csr_rdata_w, upd_csrw, upd_csr_v);
        if (DBG_CSR && rst_n && csr_we_w)
            $display("[csr-cmt t=%0t] we=%b addr=0x%03x wdata=0x%08x (cmt_we=%b cmt_addr=0x%03x cmt_data=0x%08x) mscratch=0x%08x",
                     $time, csr_we_w, csr_waddr_w, csr_wdata_w,
                     csr_cmt_we, csr_cmt_addr, csr_cmt_data, u_csr.mscratch_q);
    end

    b2_csr u_csr (
        .clk(clk), .rst_n(rst_n),
        .raddr(csr_raddr_w), .rdata(csr_rdata_w), .raddr_ill(),
        .frm_o(csr_frm_w), .fflags_o(csr_ff_w),
        .we(csr_we_w), .waddr(csr_waddr_w), .wdata(csr_wdata_w)
    );

    // ---- ROB ----
    assign upd_tr_v = x_i2_v[2] & u_is_br(x_i2_uop[2]);
    assign upd_csr_v   = csr_v_w & (u_csrop(csr_uop) != 3'd0);
    assign upd_csr_idx = x_i2_rob[csr_lane];                 // ★ B29：用 CSR 自己的 ROB 索引
    assign upd_csrw    = (u_csrop(csr_uop) == 3'd1) ? cb_src_w :
                         (u_csrop(csr_uop) == 3'd2) ? (csr_rdata_w | cb_src_w) :
                                                      (csr_rdata_w & ~cb_src_w);
    assign upd_ff_v    = fpu_done & fpu_if_v;
    //   CSR 源操作数：ALU0 的 rs1 读口（CSR 属 ALU0 类）；csrrwi/csrsi/csrrci 用 imm（zimm）
    wire   cb_src_w = u_s1i(csr_uop) ? iprf_rd[0*32 +: 32] : u_imm(csr_uop);

    rob #(.WB_N(7)) u_rob (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(disp_fire_w), .alloc_n(d1_n_w),
        .alloc_ready(rob_alloc_ready),
        .alloc_idx0(rob_alloc_idx0), .alloc_lane_valid(d1_v_q), .alloc_payload(rob_pay_w),
        .alloc_epoch(epoch_w),
        .wb_valid(wb_v), .wb_rob_idx(wb_rob), .wb_epoch(wb_ep),
        .upd_csr_valid(upd_csr_v), .upd_csr_idx(upd_csr_idx), .upd_csr_wdata(upd_csrw),
        .upd_tr_valid(upd_tr_v), .upd_tr_idx(x_i2_rob[2]),
        .upd_tr_taken(bru_act_tk), .upd_tr_target(bru_target),
        .upd_ff_valid(upd_ff_v), .upd_ff_idx(fpu_if_rob), .upd_ff_flags(fpu_ff),
        .upd_exc_valid(1'b0), .upd_exc_idx(7'd0), .upd_exc_code(4'd0), .upd_exc_tval(32'h0),
        .mem_wr_ready(mem_req_ready_i),
        .cmt_valid(cmt_raw), .cmt_payload(cmt_pay),
        .cmt_st_drain(cmt_st_drain), .cmt_st_ckpt(cmt_st_ckpt), .cmt_st_branch(cmt_st_branch),
        .trap_valid(trap_v_rob), .trap_pc(trap_pc_o), .trap_cause(trap_cause_o),
        .trap_tval(trap_tval_o),
        .squash_valid(squash_v_w), .squash_idx(squash_idx_w), .flush_all(flush_all_w),
        .head_o(rob_head_w), .cnt_o(rob_cnt_w), .empty_o(), .head_done_o(), .head_exc_o(),
        .cmt_cnt_o(cnt_commit_o), .epoch_o(epoch_w)
    );

    //==========================================================================
    // 10. PRF（整数 15 读 6 写 / 浮点 8 读 2 写）
    //==========================================================================
    assign iprf_re = 15'h7FFF;
    assign iprf_ra[0*PW_I +: PW_I]  = u_ps1i(x_i2_uop[0]);
    assign iprf_ra[1*PW_I +: PW_I]  = u_ps2i(x_i2_uop[0]);
    assign iprf_ra[2*PW_I +: PW_I]  = u_ps1i(x_i2_uop[1]);
    assign iprf_ra[3*PW_I +: PW_I]  = u_ps2i(x_i2_uop[1]);
    assign iprf_ra[4*PW_I +: PW_I]  = u_ps1i(x_i2_uop[2]);
    assign iprf_ra[5*PW_I +: PW_I]  = u_ps2i(x_i2_uop[2]);
    assign iprf_ra[6*PW_I +: PW_I]  = u_ps1i(x_i2_uop[3]);
    assign iprf_ra[7*PW_I +: PW_I]  = u_ps2i(x_i2_uop[3]);
    assign iprf_ra[8*PW_I +: PW_I]  = u_ps1i(x_i2_uop[4]);
    assign iprf_ra[9*PW_I +: PW_I]  = u_ps2i(x_i2_uop[4]);
    assign iprf_ra[10*PW_I +: PW_I] = u_ps1i(x_i2_uop[5]);
    assign iprf_ra[11*PW_I +: PW_I] = p_pdi(cmt_pay[0*RB_W +: RB_W]);
    assign iprf_ra[12*PW_I +: PW_I] = p_pdi(cmt_pay[1*RB_W +: RB_W]);
    assign iprf_ra[13*PW_I +: PW_I] = p_pdi(cmt_pay[2*RB_W +: RB_W]);
    assign iprf_ra[14*PW_I +: PW_I] = p_pdi(cmt_pay[3*RB_W +: RB_W]);
    //   ★ PRF 写口判据 = "写回所属 ROB 项仍在 ROB 窗口内"（不能用 epoch，理由见 prf.v）
    //     `(idx - head) mod 128 < cnt`；用 8 bit 比较以正确处理 cnt=128。
    assign iprf_we    = wbi_v & wbi_keep;
    assign iprf_wa    = wbi_tag;
    assign iprf_wd    = wbi_data;
    assign iprf_we_ep = { fpu_if_ep, lsu_wb_ep, mdu_if_ep, x_i2_ep[2], x_i2_ep[1], x_i2_ep[0] };

    prf #(.NW(6), .NRD(15), .NREG(`BACK2_PRF_I_N), .PDW(PW_I), .DW(32)) u_prf_i (
        .clk(clk), .rst_n(rst_n),
        .we(iprf_we), .waddr(iprf_wa), .wdata(iprf_wd), .wepoch(iprf_we_ep), .epoch(epoch_w),
        .wkeep(wbi_keep),
        .re(iprf_re), .raddr(iprf_ra), .rdata(iprf_rd)
    );

    assign fprf_re = 8'hFF;
    assign fprf_ra[0*PW_F +: PW_F] = u_ps1f(x_i2_uop[5]);
    assign fprf_ra[1*PW_F +: PW_F] = u_ps2f(x_i2_uop[5]);
    assign fprf_ra[2*PW_F +: PW_F] = u_ps3f(x_i2_uop[5]);
    assign fprf_ra[3*PW_F +: PW_F] = u_ps2f(x_i2_uop[4]);
    assign fprf_ra[4*PW_F +: PW_F] = p_pdf(cmt_pay[0*RB_W +: RB_W]);
    assign fprf_ra[5*PW_F +: PW_F] = p_pdf(cmt_pay[1*RB_W +: RB_W]);
    assign fprf_ra[6*PW_F +: PW_F] = p_pdf(cmt_pay[2*RB_W +: RB_W]);
    assign fprf_ra[7*PW_F +: PW_F] = p_pdf(cmt_pay[3*RB_W +: RB_W]);
    assign fprf_we    = { (fpu_wb_v & fpu_wb_f & ({1'b0,(fpu_if_rob - rob_head_w)} < rob_cnt_w)),
                          (lsu_wb_v & lsu_wb_f & ({1'b0,(lsu_wb_rob - rob_head_w)} < rob_cnt_w)) };
    assign fprf_wa    = { u_pdf(x_i2_uop[5]), lsu_wb_pdf };
    assign fprf_wd    = { fpu_wb_fdata, {32'hFFFF_FFFF, lsu_wb_data} };  // flw NaN-box
    assign fprf_we_ep = { fpu_if_ep, lsu_wb_ep };

    prf #(.NW(2), .NRD(8), .NREG(`BACK2_PRF_F_N), .PDW(PW_F), .DW(64)) u_prf_f (
        .clk(clk), .rst_n(rst_n),
        .we(fprf_we), .waddr(fprf_wa), .wdata(fprf_wd), .wepoch(fprf_we_ep), .epoch(epoch_w),
        .wkeep({(fpu_wb_v & fpu_wb_f) ? ({1'b0,(fpu_if_rob - rob_head_w)} < rob_cnt_w) : 1'b0,
                (lsu_wb_v & lsu_wb_f) ? ({1'b0,(lsu_wb_rob - rob_head_w)} < rob_cnt_w) : 1'b0}),
        .re(fprf_re), .raddr(fprf_ra), .rdata(fprf_rd)
    );

    //==========================================================================
    // 11. 重定向 / 异常（类别 A / 类别 C）
    //==========================================================================
    assign squash_v_w    = x_i2_v[2] & bru_mis;
    assign squash_idx_w  = x_i2_rob[2];
    assign restore_ck_v_w  = squash_v_w & u_ckv(x_i2_uop[2]);
    assign restore_ck_id_w = u_ckid(x_i2_uop[2]);
    assign restore_rob_v_w = squash_v_w & ~u_ckv(x_i2_uop[2]);
    assign restore_rob_idx_w = x_i2_rob[2];
    assign flush_all_w = trap_v_rob | trap_halt_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) trap_halt_q <= 1'b0;
        else if (trap_v_rob) trap_halt_q <= 1'b1;
    end

    assign redirect_valid_o    = squash_v_w;
    assign redirect_pc_o       = squash_v_w ? bru_npc : 32'h0;
    assign redirect_use_ckpt_o = squash_v_w & u_ckv(x_i2_uop[2]);
    assign redirect_ckpt_o     = u_ckid(x_i2_uop[2]);
    assign trap_valid_o        = trap_v_rob;

    //==========================================================================
    // 12. 提交训练 / 检查点释放 / RAS（前端衔接）
    //==========================================================================
    // ---- 12.1 训练 FIFO（深度 32；提交侧 ≤4/拍入队，前端 1 条/拍出队）----
    localparam integer TRQ_D = 32;
    reg [106:0] trq [0:TRQ_D-1];
    reg [5:0]   trq_w, trq_r;
    reg [6:0]   trq_cnt;
    wire        trq_full = (trq_cnt > (TRQ_D-4));
    reg  [3:0]  trq_ok;
    reg  [1:0]  trq_ord [0:3];
    reg  [1:0]  trq_acc;
    integer     ti;
    always @(*) begin
        trq_acc = 2'd0;
        for (ti = 0; ti < COMMIT_W; ti = ti + 1) begin
            trq_ok[ti] = cmt_st_branch[ti] & cmt_ok;
            trq_ord[ti] = trq_acc;
            if (trq_ok[ti]) trq_acc = trq_acc + 2'd1;
        end
    end
    wire [3:0]  tcp_cond, tcp_tk, tcp_ind, tcp_call, tcp_ret;
    wire [31:0] tcp_tgt [0:3];
    wire [3:0]  tcp_ptk, tcp_psg, tcp_pgd, tcp_pld, tcp_bh, tcp_bw;
    wire [31:0] tcp_ptg [0:3];
    wire [31:0] tcp_pc  [0:3];
    genvar tc;
    generate
    for (tc = 0; tc < COMMIT_W; tc = tc + 1) begin : g_trf
        wire [RB_W-1:0] pp = cmt_pay[tc*RB_W +: RB_W];
        assign tcp_cond[tc] = t_cond(p_cls(pp));
        assign tcp_tk[tc]   = p_trtk(pp);
        assign tcp_ind[tc]  = t_ind(p_cls(pp));
        assign tcp_call[tc] = t_call(p_cls(pp));
        assign tcp_ret[tc]  = t_ret(p_cls(pp));
        assign tcp_tgt[tc]  = p_trtgt(pp);
        assign tcp_ptk[tc]  = pp[`BACK2_U_PRED_MSB];
        assign tcp_psg[tc]  = pp[`BACK2_U_PRED_MSB-1];
        assign tcp_pgd[tc]  = pp[`BACK2_U_PRED_MSB-2];
        assign tcp_pld[tc]  = pp[`BACK2_U_PRED_MSB-3];
        assign tcp_bh[tc]   = pp[`BACK2_U_BTB_MSB];
        assign tcp_bw[tc]   = pp[`BACK2_U_BTB_LSB];
        assign tcp_ptg[tc]  = pp[`BACK2_U_PREDTGT_MSB:`BACK2_U_PREDTGT_LSB];
        assign tcp_pc[tc]   = p_pc(pp);
    end
    endgenerate

    assign train_valid_o = (trq_cnt != 0) & train_ready_i;
    assign train_pc_o    = trq[trq_r][31:0];
    assign train_pred_target_o = trq[trq_r][63:32];
    assign train_btb_way_o     = trq[trq_r][64];
    assign train_btb_hit_o     = trq[trq_r][65];
    assign train_pred_ldir_o   = trq[trq_r][66];
    assign train_pred_gdir_o   = trq[trq_r][67];
    assign train_pred_sel_global_o = trq[trq_r][68];
    assign train_pred_taken_o  = trq[trq_r][69];
    assign train_target_o      = trq[trq_r][101:70];
    assign train_is_return_o   = trq[trq_r][102];
    assign train_is_call_o     = trq[trq_r][103];
    assign train_is_indirect_o = trq[trq_r][104];
    assign train_taken_o       = trq[trq_r][105];
    assign train_is_cond_o     = trq[trq_r][106];
    assign train_pred_valid_o  = 1'b0;

    // ---- 12.2 检查点释放（待释放位图 + 1 条/拍排出）----
    reg [3:0] ck_free_id_r;
    integer   ck_scan;              /* ★ 必须是 integer：4 bit reg 到不了 CKPT_N=16 ⇒ 死循环 */
    always @(*) begin
        ck_free_id_r = 4'd0;
        for (ck_scan = 0; ck_scan < CKPT_N; ck_scan = ck_scan + 1)
            if (ck_pend_q[ck_scan] && (ck_free_id_r == 4'd0)) ck_free_id_r = ck_scan[3:0];
    end
    assign ckpt_free_valid_o = |ck_pend_q;
    assign ckpt_free_id_o    = ck_free_id_r;

    // ---- 12.3 RAS：call 在派发期压、ret 在 BRU 用实际返回地址弹 ----
    reg  [1:0]  ras_push_lane;
    reg         ras_push_v_r;
    reg  [31:0] ras_push_a_r;
    integer     rp;
    always @(*) begin
        ras_push_v_r = 1'b0;
        ras_push_lane = 2'd0;
        ras_push_a_r = 32'h0;
        for (rp = DISP_W-1; rp >= 0; rp = rp - 1) begin
            if (d1_v_q[rp] && t_call(d1_uop_q[rp][`BACK2_U_CLS_MSB:`BACK2_U_CLS_LSB])) begin
                ras_push_v_r  = 1'b1;
                ras_push_lane = rp[1:0];
                ras_push_a_r  = u_pc(d1_uop_q[rp]) +
                                (u_il32(d1_uop_q[rp]) ? 32'd4 : 32'd2);
            end
        end
    end
    assign d2_push_valid_o = ras_push_v_r & disp_fire_w;
    assign d2_push_addr_o  = ras_push_a_r;
    assign d2_pop_valid_o  = x_i2_v[2] & (bru_cls == 3'd4);
    assign d2_pop_addr_o   = bru_rs1;                       // ret 的实际返回地址

    // 提交侧（已提交深度）
    reg        ras_cmt_pv, ras_cmt_pov;
    integer    rq2;
    always @(*) begin
        ras_cmt_pv  = 1'b0;
        ras_cmt_pov = 1'b0;
        for (rq2 = 0; rq2 < COMMIT_W; rq2 = rq2 + 1) begin
            if (cmt_st_branch[rq2] & cmt_ok) begin
                if (t_call(p_cls(cmt_pay[rq2*RB_W +: RB_W]))) ras_cmt_pv  = 1'b1;
                if (t_ret (p_cls(cmt_pay[rq2*RB_W +: RB_W]))) ras_cmt_pov = 1'b1;
            end
        end
    end
    assign ras_cmt_push_valid_o = ras_cmt_pv;
    assign ras_cmt_pop_valid_o  = ras_cmt_pov;

    //==========================================================================
    // 13. 时序：忙碌位图 / 表项 / FIFO / 统计
    //==========================================================================
    integer si2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_i_q  <= {`BACK2_PRF_I_N{1'b0}};
            busy_f_q  <= {`BACK2_PRF_F_N{1'b0}};
            mdu_if_v  <= 1'b0; fpu_if_v <= 1'b0;
            cnt_sq_q  <= 32'h0; cnt_cmt4_q <= 32'h0; cnt_iss_q <= 32'h0;
            ck_busy_q <= {CKPT_N{1'b0}};
            ck_pend_q <= {CKPT_N{1'b0}};
            trq_w <= 6'd0; trq_r <= 6'd0; trq_cnt <= 7'd0;
            mdu_if_rob <= 7'd0; mdu_if_ep <= {EW{1'b0}}; mdu_if_di <= 1'b0;
            mdu_if_pdi <= {PW_I{1'b0}};
            fpu_if_rob <= 7'd0; fpu_if_ep <= {EW{1'b0}}; fpu_if_di <= 1'b0;
            fpu_if_df <= 1'b0; fpu_if_pdi <= {PW_I{1'b0}}; fpu_if_pdf <= {PW_F{1'b0}};
            for (si2 = 0; si2 < CKPT_N; si2 = si2 + 1) ck_rob_q[si2] <= 7'd0;
            for (si2 = 0; si2 < 128; si2 = si2 + 1) stq_of_rob[si2] <= 4'd0;
            for (si2 = 0; si2 < TRQ_D; si2 = si2 + 1) trq[si2] <= 107'h0;
        end else begin
            busy_i_q <= busy_i_nx;
            busy_f_q <= busy_f_nx;

            // ---- MDU/FPU 在途登记 ----
            if (squash_v_w | flush_all_w) begin
                mdu_if_v <= 1'b0;
                fpu_if_v <= 1'b0;
            end else begin
                if (iq_iss_v[3] & ~iq_iss_dead[3]) begin
                    mdu_if_v   <= 1'b1;
                    mdu_if_rob <= iq_iss_rob[3];
                    mdu_if_ep  <= iq_iss_ep[3];
                    mdu_if_di  <= u_di(iq_iss_uop[3]);
                    mdu_if_pdi <= u_pdi(iq_iss_uop[3]);
                end else if (mdu_done) mdu_if_v <= 1'b0;
                if (iq_iss_v[5] & ~iq_iss_dead[5]) begin
                    fpu_if_v   <= 1'b1;
                    fpu_if_rob <= iq_iss_rob[5];
                    fpu_if_ep  <= iq_iss_ep[5];
                    fpu_if_di  <= u_di(iq_iss_uop[5]);
                    fpu_if_df  <= u_df(iq_iss_uop[5]);
                    fpu_if_pdi <= u_pdi(iq_iss_uop[5]);
                    fpu_if_pdf <= u_pdf(iq_iss_uop[5]);
                end else if (fpu_done) fpu_if_v <= 1'b0;
            end

            // ---- STQ 归属表（store 的 ROB 项 → STQ 索引）----
            if (disp_fire_w) begin
                for (si2 = 0; si2 < DISP_W; si2 = si2 + 1)
                    if (st_alloc_v[si2])
                        stq_of_rob[rob_alloc_idx0 + si2[6:0]] <= st_alloc_idx[si2*4 +: 4];
            end

            // ---- 检查点表（登记 / 释放）----
            if (disp_fire_w && snap_v_r) begin
                ck_busy_q[snap_id_r] <= 1'b1;
                ck_rob_q[snap_id_r]  <= rob_alloc_idx0 + snap_lane_r;
            end
            if (squash_v_w) begin
                for (si2 = 0; si2 < CKPT_N; si2 = si2 + 1) begin
                    if (ck_busy_q[si2] &&
                        (((ck_rob_q[si2] - rob_head_w) & 7'h7F) >=
                         ((squash_idx_w - rob_head_w) & 7'h7F))) begin
                        ck_pend_q[si2] <= 1'b1;
                        ck_busy_q[si2] <= 1'b0;
                    end
                end
            end
            if (cmt_ok) begin
                for (si2 = 0; si2 < COMMIT_W; si2 = si2 + 1) begin
                    if (cmt_st_ckpt[si2]) begin
                        ck_pend_q[p_ckid(cmt_pay[si2*RB_W +: RB_W])] <= 1'b1;
                        ck_busy_q[p_ckid(cmt_pay[si2*RB_W +: RB_W])] <= 1'b0;
                    end
                end
            end
            if (ckpt_free_valid_o) ck_pend_q[ck_free_id_r] <= 1'b0;
            if (flush_all_w) ck_busy_q <= {CKPT_N{1'b0}};

            // ---- 训练 FIFO ----
            if (train_valid_o) begin
                trq_r   <= trq_r + 6'd1;
                trq_cnt <= trq_cnt - 7'd1;
            end
            if (disp_fire_w | cmt_ok) begin
                for (si2 = 0; si2 < COMMIT_W; si2 = si2 + 1) begin
                    if (trq_ok[si2] && !trq_full) begin
                        trq[trq_w + {4'b0, trq_ord[si2]}] <= {
                            tcp_cond[si2], tcp_tk[si2], tcp_ind[si2], tcp_call[si2],
                            tcp_ret[si2], tcp_tgt[si2],
                            tcp_ptk[si2], tcp_psg[si2], tcp_pgd[si2], tcp_pld[si2],
                            tcp_bh[si2], tcp_bw[si2], tcp_ptg[si2], tcp_pc[si2]
                        };
                    end
                end
                if (!trq_full) begin
                    trq_w   <= trq_w + {4'b0, trq_acc};
                    trq_cnt <= trq_cnt + {5'b0, trq_acc};
                end
            end

            // ---- 统计 ----
            if (squash_v_w) cnt_sq_q <= cnt_sq_q + 32'd1;
        end
    end

    assign cnt_squash_o  = cnt_sq_q;
    assign cnt_commit4_o = cnt_cmt4_q;
    assign cnt_issue_o   = cnt_iss_q;
    assign dbg_rob_cnt_o = rob_cnt_w;
    assign dbg_iq_cnt_o  = { iq_cnt[0], iq_cnt[1], iq_cnt[2], iq_cnt[3], iq_cnt[4], iq_cnt[5] };

    assign lsu_dr_ok_w = 4'h0;

endmodule
