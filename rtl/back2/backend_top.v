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
    output wire [`BACK2_MEM_TAG_W-1:0] mem_req_tag_o,   // ★ 2B-3 扩 3→6 bit；2B-5 L5 LQ 16 ⇒ 5 bit；EXP-R3 LQ 8 ⇒ 4 bit
    input  wire        mem_req_ready_i,
    input  wire        mem_rsp_valid_i,
    input  wire [31:0] mem_rsp_rdata_i,
    input  wire [`BACK2_MEM_TAG_W-1:0] mem_rsp_tag_i,
    // ---- ★★ (b) 执行期 store 地址翻译口（LSQ ↔ 顶层适配器；§B4.24.9 透传）----
    //   本层只做**透传**（LSQ 在 `u_lsu`，适配器在 `core_top_2b`）：
    //   · `_i` 方向 = 顶层 → LSQ；`_o` 方向 = LSQ → 顶层
    //   · 「排空不翻译」的判据在顶层（`d_xlat_need_w &= ~lsu_req_we`），本层不参与
    input  wire        st_xlate_en_i,        // 本拍（E1/提交拍）该 store 需要翻译（顶层口径）
    input  wire [3:0]  st_xlate_ctx_i,       // 翻译上下文 {priv[1:0], SUM, MXR}（顶层口径）
    output wire        st_xlate_valid_o,     // 翻译请求（保持到 done）
    output wire [31:0] st_xlate_va_o,        // 该 store 的 VA
    output wire [`BACK2_STQ_IDX_W-1:0] st_xlate_idx_o,   // 目标下标（STQ 槽 / CDQ 项）
    output wire [3:0]  st_xlate_ctx_o,       // 该请求的翻译上下文（随请求携带）
    input  wire        st_xlate_ready_i,     // 适配器接受拍
    input  wire        st_xlate_done_i,      // 完成脉冲
    input  wire [31:0] st_xlate_pa_i,        // 译后 PA
    input  wire        st_xlate_fault_i,     // 翻译故障（本步兜底：作废不写）
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
    //   ★ 2B-4 第 4a 段：**特权路径外部接口**（顶层 trap FSM ↔ 后端）
    //     · trp_flush_v_i     ：外部请求冲刷（陷阱进入 / xRET 恢复；同拍退役头部异常项）
    //     · trp_redirect_v/pc ：外部重定向（优先于内部 squash）——陷阱→mtvec、xRET→mepc
    //     · trp_halt_o        ：观测（本轮之后不再用于"陷阱即停机"）
    //     · xret_cmt_o        ：提交组 lane 0 是 mret/sret（顶层据此做特权恢复 + 重定向）
    input  wire        trp_flush_v_i,
    input  wire        trp_redirect_v_i,
    input  wire [31:0] trp_redirect_pc_i,
    output wire        trp_halt_o,
    output wire        xret_cmt_o,
    //--------------------------------------------------------------------------
    //   ★★ 2B-4 第 4b-1a 段：**CSR 文件搬到顶层**（行为等价重构，判据必须 79/79 不变）
    //--------------------------------------------------------------------------
    //   本模块从此只保留三类 CSR 接口（不再内含 `b2_csr`）：
    //     · 读口：`csr_raddr_o` → 顶层 CSR 文件 → `csr_rdata_i`（组合，执行拍）
    //     · 写口：`csr_we_o/csr_waddr_o/csr_wdata_o`（提交点合成值，见 §B29/D5a/D5b）
    //     · 陷阱写口：`csr_trp_*`（4a 自造的"进入/退出"事件；4b-1b 换 `trap_ctrl` 后删除）
    //   另需回灌两个**读侧派生量**：`csr_frm_i`（FPU 舍入模式）、`csr_fflags_i`（fcsr.fflags）
    output wire [11:0] csr_raddr_o,
    input  wire [31:0] csr_rdata_i,
    input  wire [2:0]  csr_frm_i,
    input  wire [4:0]  csr_fflags_i,
    //   ★★ 4b-3(2/2)：当前特权级（来自 `priv_ctrl`）——用于 **ecall 的 cause 按 priv 生成**
    //     （ISA：8 = U / 9 = S / 11 = M；见 §7 的 `ecall_cause_w`）
    input  wire [1:0]  priv_i,
    output wire        csr_we_o,
    output wire [11:0] csr_waddr_o,
    output wire [31:0] csr_wdata_o,
    output wire [1:0]  xret_kind_o,
    //--------------------------------------------------------------------------
    //   ★★ 2B-4 第 4b-2a 段：**维护操作（fence.i / sfence.vma / cbo.\*）**
    //--------------------------------------------------------------------------
    //   · `cbo_perm_i = {cbcfe, cbie_nonzero}`（由顶层从 `csr_file.menvcfg_o` 译出，
    //     照 2A `dec_csr.v:222-237` 的口径：CBIE=00 ⇒ cbo.inval 非法；CBCFE=0 ⇒
    //     cbo.clean/flush 非法；CBIE=01 的 INVAL⇒FLUSH 降级本段不实现，见报告 §B4.9.4）
    //   · `maint_kind_o`：**提交点 lane 0** 的维护动作码（载荷 TVAL = 原始指令位）
    //       1=fence.i、2=sfence.vma、3=cbo.inval、4=cbo.clean、5=cbo.flush、0=非维护
    //   · `maint_cmt_o`：本拍 lane 0 的维护操作**正在提交**（顶层据此驱动维护口 + 冲刷重定向）
    //   ★★ 2B-4 p12 收口：`maint_rdy_i` = 维护动作可以启动（顶层给 `l1d_idle`）。
    //     cbo.* 的 L1D 维护扫描**必须等 L1D 空闲**：否则会与在途 store 排空/行填充相撞
    //     （实测 p12：cbo 后 4 次 load 仅 1 次读到期望值）。sfence（只刷 TLB）与
    //     fence.i（走 L1I 扫掠、自身等待）不受此门控。
    input  wire        maint_rdy_i,
    input  wire [1:0]  cbo_perm_i,
    output wire [2:0]  maint_kind_o,
    output wire        maint_cmt_o,
    output wire [31:0] maint_pc_o,          // 维护操作**自己**的 PC（重定向目标 = 它 +4）
    //   （原 `mtip_i`/`irq_mti_o`/`mtvec_o`/`mepc_o` 四个端口随 `b2_csr` 外移而删除；
    //     中断判定在 4b-1a 由顶层用 `csr_*_o` 复刻，4b-1b 起交给 `trap_ctrl`。）
    output wire [31:0] trap_valid_o_pc,       // 别名（保持 trap_valid_o 契约不变）
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
    output wire [7:0]  dbg_stq_cnt_o,
    //   ★ 2B-4 修法 1：CDQ 空（已提交 store 全部落地）—— 顶层据此推迟整机冲刷
    output wire        cdq_empty_o,
    //   ★★ 2B-4 第 4b-2b 段：数据侧访存响应**带错**（TLB 权限错 / PTW 故障）——
    //     顶层适配器以"正常响应 + err=1"回一笔 ⇒ LSQ 标 done+异常 ⇒ ROB `upd_exc`
    input  wire        mem_rsp_err_i
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
    localparam       ROBW  = `BACK2_ROB_IDX_W;   // ROB 索引位宽（= 真源 BACK2_ROB_IDX_W = log2(ROB_N)）
    //   ★ L3（ROB 128→64）：ROB 索引一律取 **ROBW 位模 ROB_N 算术**（与 rob.v/iq.v 的
    //     "age = (idx - head) mod N" 口径一致）。**不得**再用 7 bit / `& 7'h7F` 的模 128
    //     写法：索引值只到 63，模 128 会把"回绕后的在窗项"算成 65..127 ⇒ 误判为窗外。
    //     年龄判序也**不得**再用"N/2 半分窗"近似（N=64 时半窗只有 32 ⇒ 更老项会被误判），
    //     改为"两侧各自相对 ROB 头的精确年龄比较"（见 §5 的 load/FP→CSR 可见性门）。
    localparam       LDW   = `BACK2_LQ_IDX_W;   // LQ 索引位宽
    //   ★★ C1（IQ 载荷瘦身）：IQ 窄载荷宽度 与 发射宽载荷（回读）宽度
    localparam       IQNW  = `BACK2_IQN_W;      // IQ 窄载荷（唤醒+门控）
    localparam       IWW   = `BACK2_IW_W;       // ★ EXP-R2：发射宽载荷 = 212 bit 紧凑布局（back2_params §2.5）
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
    //   ★★ C4：**一律改用 `BACK2_RB_*`（载荷布局）宏** —— 旧版借用 `BACK2_U_*`（uop 布局）
    //     只是因为旧载荷的低 304 位恰好等于 uop；载荷重排后两者不再重合。唯一仍重合的是
    //     [19:0] 的 EXC+FLAGS 块（硬约束，见 back2_params §2）⇒ 该块仍用 `BACK2_UB_*`。
    //   ⚠ 这些函数被 `sim/unit/tb_back2_lockstep.sv` 按层次名调用（p_pc/p_pdi/p_pdio/p_di/
    //     p_cls/p_st/p_csr）⇒ **名字与签名不得改**，只改函数体里的位域宏。
    function [31:0] p_pc;    input [RB_W-1:0] p; begin p_pc  = p[`BACK2_RB_PC_MSB:`BACK2_RB_PC_LSB]; end endfunction
    function [4:0]  p_arn;   input [RB_W-1:0] p; begin p_arn = p[`BACK2_RB_ARND_MSB:`BACK2_RB_ARND_LSB]; end endfunction
    function [PW_I-1:0] p_pdi;  input [RB_W-1:0] p; begin p_pdi  = p[`BACK2_RB_PDIDST_MSB:`BACK2_RB_PDIDST_LSB]; end endfunction
    function [PW_I-1:0] p_pdio; input [RB_W-1:0] p; begin p_pdio = p[`BACK2_RB_PDIOLD_MSB:`BACK2_RB_PDIOLD_LSB]; end endfunction
    function [PW_F-1:0] p_pdf;  input [RB_W-1:0] p; begin p_pdf  = p[`BACK2_RB_PDFDST_MSB:`BACK2_RB_PDFDST_LSB]; end endfunction
    function [PW_F-1:0] p_pdfo; input [RB_W-1:0] p; begin p_pdfo = p[`BACK2_RB_PDFOLD_MSB:`BACK2_RB_PDFOLD_LSB]; end endfunction
    function p_di;  input [RB_W-1:0] p; begin p_di = p[`BACK2_UB_RD_I_WEN]; end endfunction
    function p_df;  input [RB_W-1:0] p; begin p_df = p[`BACK2_UB_RD_F_WEN]; end endfunction
    function p_st;  input [RB_W-1:0] p; begin p_st = p[`BACK2_UB_IS_STORE]; end endfunction
    function p_csr; input [RB_W-1:0] p; begin p_csr = p[`BACK2_UB_IS_CSR]; end endfunction
    function p_ckv; input [RB_W-1:0] p; begin p_ckv = p[`BACK2_UB_CKPT_VALID]; end endfunction
    function [3:0] p_ckid; input [RB_W-1:0] p; begin p_ckid = p[`BACK2_RB_CKPT_MSB:`BACK2_RB_CKPT_LSB]; end endfunction
    function [2:0] p_cls;  input [RB_W-1:0] p; begin p_cls  = p[`BACK2_RB_CLS_MSB:`BACK2_RB_CLS_LSB]; end endfunction
    function [`BACK2_STQ_IDX_W-1:0] p_stq; input [RB_W-1:0] p; begin p_stq = p[`BACK2_RB_STQ_MSB:`BACK2_RB_STQ_LSB]; end endfunction
    //   ★ EXP-R3：本函数当前**无调用者**（LQ 索引在提交侧无功能读点，见 back2_params.vh
    //     RB_LQ 注）；保留定义仅为"位域真源"完整。LQ 16→8 后返回 3 bit（p[87:85]）。
    function [`BACK2_LQ_IDX_W-1:0]  p_lq;  input [RB_W-1:0] p; begin p_lq  = p[`BACK2_RB_LQ_MSB:`BACK2_RB_LQ_LSB];  end endfunction
    function [11:0] p_csra;input [RB_W-1:0] p; begin p_csra = p[`BACK2_RB_CSRADDR_MSB:`BACK2_RB_CSRADDR_LSB]; end endfunction
    function [2:0]  p_csrop;input [RB_W-1:0] p;begin p_csrop= p[`BACK2_RB_CSROP_MSB:`BACK2_RB_CSROP_LSB]; end endfunction
    //   ★ 2B-4 第 4a 段：载荷里的**原始指令位**（`decoder.tval_o = insn_i`，norvc）
    //     —— xRET 识别与 CSR 立即数形式都靠它
    function [31:0] p_tval;  input [RB_W-1:0] p;begin p_tval = p[`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB]; end endfunction
    function [4:0]  p_ff;  input [RB_W-1:0] p; begin p_ff  = p[`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB]; end endfunction
    function [31:0] p_trtgt;input [RB_W-1:0] p;begin p_trtgt=p[`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB]; end endfunction
    function p_trtk;       input [RB_W-1:0] p; begin p_trtk = p[`BACK2_RB_TRTAKEN]; end endfunction
    //   ★★ C9：发射宽载荷取字段（纯函数；`x_i2_uop` = `u_iwmem` 同步读回的紧凑布局，
    //     ★ EXP-R2 后为 **212 bit**，见 back2_params.vh §2.5）。这些 `w_*` 函数只用于 E1
    //     及其后的发射路径；D1/D2/D3 仍用 `u_*`（uop 300 bit 布局，契约不变）。
    function [31:0] w_pc;    input [IWW-1:0] w; begin w_pc  = w[`BACK2_IW_PC_MSB:`BACK2_IW_PC_LSB]; end endfunction
    function [31:0] w_imm;   input [IWW-1:0] w; begin w_imm = w[`BACK2_IW_IMM_MSB:`BACK2_IW_IMM_LSB]; end endfunction
    function [31:0] w_predtgt;input [IWW-1:0] w;begin w_predtgt = w[`BACK2_IW_PREDTGT_MSB:`BACK2_IW_PREDTGT_LSB]; end endfunction
    function [2:0]  w_cls;   input [IWW-1:0] w; begin w_cls = w[`BACK2_IW_CLS_MSB:`BACK2_IW_CLS_LSB]; end endfunction
    function [3:0]  w_opt;   input [IWW-1:0] w; begin w_opt = w[`BACK2_IW_OPTYPE_MSB:`BACK2_IW_OPTYPE_LSB]; end endfunction
    function [2:0]  w_wbsel; input [IWW-1:0] w; begin w_wbsel = w[`BACK2_IW_WBSEL_MSB:`BACK2_IW_WBSEL_LSB]; end endfunction
    function [11:0] w_csra;  input [IWW-1:0] w; begin w_csra = w[`BACK2_IW_CSRADDR_MSB:`BACK2_IW_CSRADDR_LSB]; end endfunction
    function [6:0]  w_fpop;  input [IWW-1:0] w; begin w_fpop = w[`BACK2_IW_FPOP_MSB:`BACK2_IW_FPOP_LSB]; end endfunction
    function [1:0]  w_fmt;   input [IWW-1:0] w; begin w_fmt  = w[`BACK2_IW_FMT_MSB:`BACK2_IW_FMT_LSB]; end endfunction
    function [2:0]  w_rm;    input [IWW-1:0] w; begin w_rm   = w[`BACK2_IW_RM_MSB:`BACK2_IW_RM_LSB]; end endfunction
    function [2:0]  w_msize; input [IWW-1:0] w; begin w_msize= w[`BACK2_IW_MSIZE_MSB:`BACK2_IW_MSIZE_LSB]; end endfunction
    function [4:0]  w_brop;  input [IWW-1:0] w; begin w_brop = w[`BACK2_IW_BROP_MSB:`BACK2_IW_BROP_LSB]; end endfunction
    function [3:0]  w_aluop; input [IWW-1:0] w; begin w_aluop= w[`BACK2_IW_ALUOP_MSB:`BACK2_IW_ALUOP_LSB]; end endfunction
    function w_il32;         input [IWW-1:0] w; begin w_il32 = w[`BACK2_IW_IL32]; end endfunction
    function w_rt;           input [IWW-1:0] w; begin w_rt   = w[`BACK2_IW_RTYPE]; end endfunction
    function w_au;           input [IWW-1:0] w; begin w_au   = w[`BACK2_IW_AUIPC]; end endfunction
    function w_pred_tk;      input [IWW-1:0] w; begin w_pred_tk = w[`BACK2_IW_PRED_TAKEN]; end endfunction
    function w_munsign;      input [IWW-1:0] w; begin w_munsign = w[`BACK2_IW_MUNSIGN]; end endfunction
    function w_is_csr;       input [IWW-1:0] w; begin w_is_csr = w[`BACK2_UB_IS_CSR]; end endfunction
    function w_is_br;        input [IWW-1:0] w; begin w_is_br = w[`BACK2_UB_IS_BRANCH]; end endfunction
    function w_is_st;        input [IWW-1:0] w; begin w_is_st = w[`BACK2_UB_IS_STORE]; end endfunction
    function w_di;           input [IWW-1:0] w; begin w_di = w[`BACK2_UB_RD_I_WEN]; end endfunction
    function w_df;           input [IWW-1:0] w; begin w_df = w[`BACK2_UB_RD_F_WEN]; end endfunction
    function w_fpls;         input [IWW-1:0] w; begin w_fpls = w[`BACK2_UB_IS_FPLS]; end endfunction
    function w_s1i;          input [IWW-1:0] w; begin w_s1i = w[`BACK2_UB_S1_I_USE]; end endfunction
    function w_s1f;          input [IWW-1:0] w; begin w_s1f = w[`BACK2_UB_S1_F_USE]; end endfunction
    function w_ckv;          input [IWW-1:0] w; begin w_ckv = w[`BACK2_UB_CKPT_VALID]; end endfunction
    function [3:0]  w_ckid;  input [IWW-1:0] w; begin w_ckid = w[`BACK2_IW_CKPT_MSB:`BACK2_IW_CKPT_LSB]; end endfunction
    function [PW_I-1:0] w_pdi;  input [IWW-1:0] w; begin w_pdi  = w[`BACK2_IW_PDI_MSB:`BACK2_IW_PDI_LSB]; end endfunction
    function [PW_F-1:0] w_pdf;  input [IWW-1:0] w; begin w_pdf  = w[`BACK2_IW_PDF_MSB:`BACK2_IW_PDF_LSB]; end endfunction
    function [PW_I-1:0] w_ps1i; input [IWW-1:0] w; begin w_ps1i = w[`BACK2_IW_PS1I_MSB:`BACK2_IW_PS1I_LSB]; end endfunction
    function [PW_I-1:0] w_ps2i; input [IWW-1:0] w; begin w_ps2i = w[`BACK2_IW_PS2I_MSB:`BACK2_IW_PS2I_LSB]; end endfunction
    function [PW_F-1:0] w_ps1f; input [IWW-1:0] w; begin w_ps1f = w[`BACK2_IW_PS1F_MSB:`BACK2_IW_PS1F_LSB]; end endfunction
    function [PW_F-1:0] w_ps2f; input [IWW-1:0] w; begin w_ps2f = w[`BACK2_IW_PS2F_MSB:`BACK2_IW_PS2F_LSB]; end endfunction
    function [PW_F-1:0] w_ps3f; input [IWW-1:0] w; begin w_ps3f = w[`BACK2_IW_PS3F_MSB:`BACK2_IW_PS3F_LSB]; end endfunction
    //   打包：uop(300) → 发射宽载荷(212)（D3 派发写口用；与上面的 w_* 逐位互逆）
    function [IWW-1:0] pack_iw; input [UOPW-1:0] u;
        begin
            pack_iw = { u[`BACK2_U_PREDTGT_MSB:`BACK2_U_PREDTGT_LSB],
                        u[`BACK2_U_IMM_MSB:`BACK2_U_IMM_LSB],
                        u[`BACK2_U_PC_MSB:`BACK2_U_PC_LSB],
                        u[`BACK2_U_PS3F_MSB:`BACK2_U_PS3F_LSB],
                        u[`BACK2_U_PS2F_MSB:`BACK2_U_PS2F_LSB],
                        u[`BACK2_U_PS1F_MSB:`BACK2_U_PS1F_LSB],
                        u[`BACK2_U_PS2I_MSB:`BACK2_U_PS2I_LSB],
                        u[`BACK2_U_PS1I_MSB:`BACK2_U_PS1I_LSB],
                        u[`BACK2_U_PDFDST_MSB:`BACK2_U_PDFDST_LSB],
                        u[`BACK2_U_PDIDST_MSB:`BACK2_U_PDIDST_LSB],
                        u[`BACK2_U_PRED_MSB],
                        u[`BACK2_UAX_AUIPC], u[`BACK2_UAX_RTYPE], u[`BACK2_UAX_IL32],
                        u[`BACK2_UAX_FMT_MSB:`BACK2_UAX_FMT_LSB],
                        u[`BACK2_U_BROP_MSB:`BACK2_U_BROP_LSB],
                        u[`BACK2_U_OPTYPE_MSB:`BACK2_U_OPTYPE_LSB],
                        u[`BACK2_U_ALUOP_MSB:`BACK2_U_ALUOP_LSB],
                        u[`BACK2_U_WBSEL_MSB:`BACK2_U_WBSEL_LSB],
                        u[`BACK2_U_MUNSIGN], u[`BACK2_U_MSIZE_MSB:`BACK2_U_MSIZE_LSB],
                        u[`BACK2_U_RM_MSB:`BACK2_U_RM_LSB], u[`BACK2_U_FPOP_MSB:`BACK2_U_FPOP_LSB],
                        u[`BACK2_U_CSRADDR_MSB:`BACK2_U_CSRADDR_LSB],
                        u[`BACK2_U_CLS_MSB:`BACK2_U_CLS_LSB],
                        u[`BACK2_U_CKPT_MSB:`BACK2_U_CKPT_LSB],
                        u[`BACK2_U_FLAGS_MSB:`BACK2_U_FLAGS_LSB],
                        u[`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB] };
        end
    endfunction

    // 分支类别（front4 README §1 的 lane_cls 编码）
    function t_call; input [2:0] c; begin t_call = (c == 3'd5) | (c == 3'd6); end endfunction
    function t_ret;  input [2:0] c; begin t_ret  = (c == 3'd4); end endfunction
    function t_ind;  input [2:0] c; begin t_ind  = (c == 3'd3) | (c == 3'd6); end endfunction
    function t_cond; input [2:0] c; begin t_cond = (c == 3'd1); end endfunction

    // FP 归一化操作码（与 rtl/exec/fpu.v 头注 §1 的表逐条一致）
    //   ★★ 2B-4 修复（锁步 p4_fpu 暴露，**3 组系统性错位**）：本函数必须与
    //     `rtl/top/core_top.v` 的 `fp_op_map(de_fp_op, insn)` **逐条等价**（2A 核即按
    //     那个映射执行，arch-test F/D 已全绿、且是锁步的比对基准）。旧实现按"自创"的
    //     字段切法解码，三处错：
    //       ① FSGNJ / FMIN-FMAX / FEQ-FLT-FLE 的**组内选择位取错**：这三族的变体由
    //          **funct3（insn[14:12]）** 区分（`fsgnj.s/fsgnjn.s/fsgnjx.s` 与
    //          `fmin.s/fmax.s`、`fle.s/flt.s/feq.s` 都是 rm 字段编码），旧实现却拿
    //          **rs2 寄存器号**去选 ⇒ `fmin.s f14,f1,f4`（rs2=f4≠0）被当成 **FMAX**，
    //          实测锁步第 27 条：乱序给 0x3f800000（max）而 Spike/2A 给 0xbf000000（min）。
    //       ② `fcvt.s.w/wu/l/lu` 族的 funct5 = **11010**，旧实现写成 `01000` ⇒ 该族落到
    //          `default 127`（fpu.v 对未定义 op 给"result=0、done 照常"）⇒ 静默错值。
    //       ③ `01000` 实为 **F↔D 互转**（fcvt.s.d / fcvt.d.s），旧实现当成
    //          `fcvt.s.w` 族 ⇒ 同样错值。
    //     本段改为**照抄 2A 的映射**（含 funct3/fmt/rs2[0] 选择与 FMA 26–29）。
    //   ★ F↔D 互转的组内选择：`insn[20]`（rs2 最低位）⇒ fcvt.s.d=24 / fcvt.d.s=25。
    function [6:0] fp_cvt_map;
        input [31:0] insn;
        reg          is_d;
        begin
            is_d = (insn[26:25] == `RV32GC_FMT_D);
            case (insn[31:27])
                5'b01000: fp_cvt_map = insn[20] ? 7'd24 : 7'd25;              // F↔D
                5'b11000: fp_cvt_map = is_d ? (insn[20] ? 7'd21 : 7'd20)      // →W/WU
                                            : (insn[20] ? 7'd17 : 7'd16);
                5'b11010: fp_cvt_map = is_d ? (insn[20] ? 7'd23 : 7'd22)      // →S/D
                                            : (insn[20] ? 7'd19 : 7'd18);
                default:  fp_cvt_map = 7'd0;
            endcase
        end
    endfunction

    function [6:0] fp_op_map;
        input [31:0] insn;
        reg [2:0] f3;
        begin
            f3 = insn[14:12];
            case (insn[6:0])
                `RV32GC_OP_MADD : fp_op_map = 7'd26;
                `RV32GC_OP_MSUB : fp_op_map = 7'd27;
                `RV32GC_OP_NMSUB: fp_op_map = 7'd28;
                `RV32GC_OP_NMADD: fp_op_map = 7'd29;
                `RV32GC_OP_FP: case (insn[31:27])
                    `RV32GC_FP_F5_FADD   : fp_op_map = 7'd0;
                    `RV32GC_FP_F5_FSUB   : fp_op_map = 7'd1;
                    `RV32GC_FP_F5_FMUL   : fp_op_map = 7'd2;
                    `RV32GC_FP_F5_FDIV   : fp_op_map = 7'd3;
                    `RV32GC_FP_F5_FSQRT  : fp_op_map = 7'd4;
                    `RV32GC_FP_F5_FSGNJ  : fp_op_map = (f3 == `RV32GC_FP_F3_FSGNJ)  ? 7'd5 :
                                                        (f3 == `RV32GC_FP_F3_FSGNJN) ? 7'd6 : 7'd7;
                    `RV32GC_FP_F5_FMINMAX: fp_op_map = (f3 == `RV32GC_FP_F3_FMIN) ? 7'd8 : 7'd9;
                    `RV32GC_FP_F5_FCMP   : fp_op_map = (f3 == `RV32GC_FP_F3_FEQ) ? 7'd10 :
                                                        (f3 == `RV32GC_FP_F3_FLT) ? 7'd11 : 7'd12;
                    `RV32GC_FP_F5_FMV_CMP: fp_op_map = (f3 == `RV32GC_FP_F3_FCLASS) ? 7'd13 : 7'd14;
                    `RV32GC_FP_F5_FMV_W_X: fp_op_map = 7'd15;
                    //   ★ 转换族三组都要进 `fp_cvt_map`：01000 = F↔D 互转、
                    //     11000 = →W/WU（fcvt.w.s 等）、11010 = →S/D（fcvt.s.w 等）。
                    //     （2A 侧由 decoder 的 `fp_cvt_any_ok` 归为一族后交给同一张表。）
                    5'b01000, 5'b11000, 5'b11010
                                         : fp_op_map = fp_cvt_map(insn);
                    default              : fp_op_map = 7'd127;
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
    //   ★ 2B-4：LSQ 提交排空队列（CDQ）余量 —— rob.v 的 store 提交门（`mem_wr_ready`）。
    //     语义变更：store 提交**不再**要求"排空口当拍空闲"，只要求 CDQ 放得下一整组
    //     （≤4 笔）；排空口按 FIFO 逐拍把已提交的 store 落地（单端口、单笔在途不变）。
    wire        lsu_dr_room_w;
    //   ★ 4b-1a：CSR 文件在顶层 ⇒ 下面三个量改由端口驱动（内部使用点**零改动**）
    wire [31:0] csr_rdata_w = csr_rdata_i;
    wire [2:0]  csr_frm_w   = csr_frm_i;
    wire [4:0]  csr_ff_w    = csr_fflags_i;
    wire [`BACK2_STQ_IDX_W-1:0] stq_of_rob_r;
    reg         trap_halt_q;
    reg         mdu_if_v, fpu_if_v;
    reg  [6:0]  mdu_if_rob, fpu_if_rob;
    reg  [EW-1:0] mdu_if_ep, fpu_if_ep;
    reg         mdu_if_di, fpu_if_di, fpu_if_df;
    reg  [PW_I-1:0] mdu_if_pdi, fpu_if_pdi;
    reg  [PW_F-1:0] fpu_if_pdf;
    //   ★ L3：深度 = ROB_N（原硬编码 128；索引现在是模 ROB_N 的 ROBW 位值）
    reg  [`BACK2_STQ_IDX_W-1:0] stq_of_rob [0:ROB_N-1];
    //   ★ 2B-4 第二步：LQ 槽在 **D3 派发期**分配（load 项、程序序）⇒ 需要"ROB 项 → LQ 槽"
    //     登记表供 E1 取用（与 store 的 `stq_of_rob` 同构）。
    reg  [`BACK2_LQ_IDX_W-1:0]  lq_of_rob  [0:ROB_N-1];
    wire [`BACK2_LQ_IDX_W-1:0]  lq_of_rob_r;
    wire [11:0] csr_raddr_w;
    assign csr_raddr_o = csr_raddr_w;
    //   ★ 4b-1a：写口与陷阱写口引出（`csr_we_w/csr_waddr_w/csr_wdata_w` 见 §7 提交级合成）
    assign csr_we_o    = csr_we_w;
    assign csr_waddr_o = csr_waddr_w;
    assign csr_wdata_o = csr_wdata_w;




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
    //   ★★ C1：IQ 的**窄载荷**选择观察口（发射门控真源）；`iq_iss_uop`/`sel_uop` 已废弃
    //     （IQ 不再持宽字段 ⇒ backend_top 不再消费宽 uop 端口）。
    wire [IQNW-1:0] iq_sel_nq [0:5];
    //   ★★ C1：发射宽载荷存储（4 bank SDP，写口=派发、读口=发射仲裁）—— 见 §5.5
    //   ⚠ 偏移位宽 = NW × OW = 4 × 4 = 16 bit（OW=4：每 bank 16 深 ⇒ 偏移 = rob 索引 [5:2]）
    wire [3:0]       iwm_we;              // 每 bank 写使能（派发，4 lane 天然各占 1 bank）
    wire [4*4-1:0]   iwm_woff;            // 每 bank 写偏移（= rob 索引 [5:2]）
    wire [4*IWW-1:0] iwm_wdata;
    wire [3:0]       iwm_re;              // 每 bank 读使能（发射，每 bank ≤1/拍）
    wire [4*4-1:0]   iwm_roff;
    wire [4*IWW-1:0] iwm_rdata;           // 同步读（1 拍）
    reg  [2:0]       iwm_own_q [0:3];     // 上一拍各 bank 读回数据属于哪个队列（6=无）
    wire [2:0]       iwm_own_nx [0:3];
    wire [11:0]      iwm_rbank;           // 各队列读请求的 bank（= rob 索引低 2 位；6×2bit）
    wire [5:0]       iwm_req;             // 发射读请求（未门控选择口 ∧ 基础就绪）
    wire [5:0]       iwm_gnt;             // 读口仲裁结果（固定优先级；每 bank ≤1）
    wire [5:0]       iq_base_rdy;         // 各队列**基础**发射许可（不含读口仲裁）
    wire [6:0]  iq_iss_rob [0:5];
    wire [EW-1:0] iq_iss_ep [0:5];
    wire [5:0]  iq_iss_dead;
    reg  [6*WI-1:0]          iq_wv;
    reg  [6*WI*UOPW-1:0]     iq_wuop;
    reg  [6*WI*ROBW-1:0]     iq_wrob;      // ★ L3：字段宽 = ROBW（与 iq.wr_rob 端口逐位对齐）
    reg  [6*WI*SRC_N-1:0]    iq_wrdy;
    wire [4:0]  iq_cnt [0:5];

    // 忙碌位图
    reg  [`BACK2_PRF_I_N-1:0] busy_i_q;
    reg  [`BACK2_PRF_F_N-1:0] busy_f_q;
    reg  [`BACK2_PRF_I_N-1:0] busy_i_nx;
    reg  [`BACK2_PRF_F_N-1:0] busy_f_nx;

    // PRF 端口
    wire [15:0]     iprf_re;
    wire [16*PW_I-1:0] iprf_ra;      // ★ B29：+1 路提交级 CSR 源读口
    wire [16*32-1:0]   iprf_rd;
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
    wire [7*ROBW-1:0] wb_rob;   // ★ L3：字段宽 = ROBW
    wire [COMMIT_W*`BACK2_NQ_W-1:0] cmt_narrow;  // ★ ROB 窄控制字（第 1 步已导出；本步接线并作为提交判定唯一依据）
    wire [`BACK2_CMT_CSR_W-1:0] csr_pay_w;     // ★ ② 单 lane 动态 CSR 读口数据
    wire [ROBW-1:0] csr_dyn_idx_w;            // ★ ② 其索引（提交组内 CSR lane 的绝对 ROB 索引；L3：模 ROB_N）
    wire [7*EW-1:0] wb_ep;
    wire [5:0]      wbi_v;              // 整数写回有效（部件 0..5）
    wire [6*PW_I-1:0] wbi_tag;
    wire [6*32-1:0]   wbi_data;
    wire [5:0]      wki_v;              // 整数唤醒（部件 0..5）
    wire [6*PW_I-1:0] wki_tag;
    wire [5:0]      wkf_v;              // 浮点唤醒（0 = LSU，1 = FPU）
    wire [6*PW_F-1:0] wkf_tag;

    // 各部件 I2 寄存器
    //   ★★ C1：`x_i2_uop` 由**寄存器**改为**组合线**（源 = `u_iwmem` 的同步读输出 +
    //     4:1 交叉开关）—— BRAM 输出寄存器恰好承担了原 `x_i2_uop` 的"发射拍→执行拍"
    //     寄存作用 ⇒ **发射→执行仍是 1 拍**（无新增级数，见 §5.5/§6）。
    //   ★★ C9：`x_i2_uop` 现在是 **IWW(212) 位紧凑发射载荷**（不再是 uop 的切片）⇒ 读取
    //     一律走 `w_*` 访问函数（见 §0）；`u_*` 只用于 D1/D2/D3 的 uop(300)。
    wire [IWW-1:0] x_i2_uop [0:5];
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
    //   ★★ C8：ROB 的**统一年龄输出**（"距头距离"唯一真源，见 `rob.v` §1.1）——
    //     = `(squash_idx_w − rob_head_w) mod ROB_N`。本文件的全部"更年轻"判据
    //     （I2 发射杀、MDU/FPU 杀、CSR 跟踪表冲刷、检查点回滚登记）一律改用它，
    //     不再各自重算 `squash_idx_w − rob_head_w`（原 4 处就地重算）。
    wire [ROBW-1:0] squash_age_w;
    wire [7:0]  rob_cnt_w;
    wire [EW-1:0] epoch_w;
    //   ★★ EXP-B：`upd_csr_*`（含 `upd_csrw`/`upd_csr_idx`/`upd_csr_v`）整条路径已删除
    //      —— 它原本就硬接 `1'b0`（动态实测恒 0），CSR 提交期源改从载荷 `uop.PS1I` 取
    //      （见下方 `csr_cmt_ps1i` ← rob 的 `csr_pay`，其 `csrw` 段现由 rob 从载荷 PS1I 给出）。
    wire        upd_tr_v, upd_ff_v, upd_exc_v;

    // 提交
    wire [6:0]  cmt_i2;
    wire [3:0]  lsu_dr_valid;
    wire [DISP_W*`BACK2_STQ_IDX_W-1:0] lsu_dr_idx;
    //   ★ 2B-3 第 6 段第二步：STQ 分配随带的 ROB 索引（年龄在分配期写入）
    wire [DISP_W*ROBW-1:0] st_alloc_rob;
    //   ★ L3：D3 派发块内各 lane 的 ROB 索引（lane 0 最老；块"自 lane0 连续"⇒ idx = idx0+lane），
    //     统一 **ROBW 位（模 ROB_N）**。7 bit 的 `rob_alloc_idx0` 在此截断为模 64：
    //     直接写 `rob_alloc_idx0 + 7'dk` 会得到 [0,66] 的非模值（head=63、k=3 时 66 而非 2）
    //     ⇒ 跨 64 回绕后所有年龄/窗口比较都会错。
    wire [ROBW-1:0] rb_ix_w [0:DISP_W-1];
    assign rb_ix_w[0] = rob_alloc_idx0;
    assign rb_ix_w[1] = rob_alloc_idx0 + 7'd1;
    assign rb_ix_w[2] = rob_alloc_idx0 + 7'd2;
    assign rb_ix_w[3] = rob_alloc_idx0 + 7'd3;
    //   本拍提交条数（LQ 提交点释放的窗口宽度；已按 cmt_ok 门控）
    wire [2:0]  cmt_n_w;

    // 前端接口
    reg  [31:0] cnt_sq_q, cnt_cmt4_q, cnt_iss_q;
    //   ★ EXP-R3a（D2 修复）：原 `reg [3:0]` 却按 `ck_busy_q[snap_id_r]`（id 0..15）与
    //     `for (si2<CKPT_N=16)` 访问 ⇒ id≥4 的登记被丢弃、读取返回 x（实测 62 拍 snapid≥4）。
    //     改为与 `ck_pend_q` 同宽（CKPT_N 位）。
    reg  [CKPT_N-1:0] ck_busy_q;
    reg  [ROBW-1:0] ck_rob_q [0:CKPT_N-1];   // ★ L3：模 ROB_N
    reg  [CKPT_N-1:0] ck_pend_q;

    //==========================================================================
    // 2. D1：4×decoder（组合）+ uop 打包
    //==========================================================================
    integer di;
    genvar  g;
    generate
    //   ★ ecall 的 cause（按当前特权级；ISA：8=U / 9=S / 11=M）——放在 generate 之外，
    //     供各 lane 的 `exc_w` 引用（同一时刻所有 lane 的 priv 相同）。
    wire [3:0] ecall_cause_w = (priv_i == `RV32GC_PRIV_M) ? `BACK2_EXC_ECALL_M :
                               (priv_i == `RV32GC_PRIV_S) ? `BACK2_EXC_ECALL_S :
                                                            `BACK2_EXC_ECALL_U;
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
        //   ★★ 2B-4 修复（锁步 p4_fpu 暴露）：**"源 1 是整数寄存器"的 FP 指令集合**必须与
        //     2A 逐条一致（core_top §7.5：`e_fp_a_is_int = (e_fp_op==15)|(18)|(19)|(22)|(23)`）
        //       · fmv.w.x / fmv.d.x（funct5=11110）      ⇒ op 15
        //       · fcvt.s.w / .wu / fcvt.d.w / .wu（**11010**）⇒ op 18/19/22/23
        //     旧实现把 `11110` 与 **`01000`**（= F↔D 互转，源是 **FP** 寄存器！）当成整数源、
        //     又漏掉 `11010` ⇒ `fcvt.s.w` 既没被标成"整数源"（`rs1_used`=0）又被当成 FP 源
        //     （`s1f`=1）⇒ 实测 `fcvt.s.w fs8,a4` 得 0xce820000（读的是 FP 口的垃圾），
        //     而 Spike/2A 得 0x40a00000（5.0）。
        wire fp_src1_int = is_opfp & ((f5 == `RV32GC_FP_F5_FMV_W_X) | (f5 == 5'b11010));
        //   ★★ 2B-4 第 4a 段：**ecall/ebreak/mret/sret 从 `unsup` 摘出**
        //     · ecall/ebreak ⇒ 不再走"非法指令（cause 2）"，而在 `exc_w` 里带**真实 cause**
        //       （11 = M 模式 ecall / 3 = breakpoint），提交点精确抛出（rob.v 头部 trap）；
        //     · mret/sret ⇒ 不非法；执行期是 no-op，**提交点特权动作**由顶层 trap FSM 做
        //       （读 mepc/mstatus + 重定向），识别方式见 `xret_cmt_o`；
        //     · wfi 仍留 unsup（本里程碑不需要）。
        //   ★ 4b-2a：`sfence.vma` 归 `OPT_SYS`，加进白名单（2A 只对 U 模式判非法；
        //     本核 priv 恒 M ⇒ 直接放行）
        wire is_sys_ok = ecall | ebreak | mret | sret | sfence;
        //   ★ 4b-2a：`cbo.*`（opt 10）**摘出 `unsup`**；其合法性改由 `cbo_perm_i`
        //     按动作码精确判定（不再用译码器内部的 `cbo_gate_ill` —— 本核前端未接
        //     menvcfg/senvcfg 到译码器，那两位是悬空 ⇒ 直接用会引入 x）
        wire unsup   = ((opt == 4'd8) & ~is_sys_ok) |
                       (opt == 4'd5) | (opt == 4'd15);
        //   ★★ p12 修正：cbo 的**动作码在 imm12[1:0]（bits[21:20]）**，funct3 恒为 010
        //      （不是 000/001/010 —— 旧式把 `cbo.inval` 也当成"需 CBCFE"的 clean/flush）
        //      ⇒ menvcfg.CBIE=01 且 CBCFE=0 时，**合法的 `cbo.inval` 会被误判非法**。
        //      p12 因 `menvcfg=0x70`（CBIE=11、CBCFE=1 两位全开）未暴露该偏差，本段一并修正。
        wire [1:0] cbo_op = tval[21:20];
        wire cbo_ill_perm = cbo_valid &
                            ((cbo_op == 2'b00) ? ~cbo_perm_i[0]      // inval：需 CBIE≠0
                                               : ~cbo_perm_i[1]);    // clean/flush：需 CBCFE=1
        //   ★ 4b-2a：cbo 指令的 `ill_instr` 必须屏蔽掉——译码器内部的 `cbo_gate_ill` 由
        //     menvcfg/senvcfg 驱动，而本核前端未接那两位（悬空 z）⇒ 它会给出 x；
        //     本核改用 `cbo_ill_perm`（由顶层从 `csr_file.menvcfg_o` 译出的两位许可）判。
        //     `ill_instr & ~cbo_valid`：cbo 时恒 0（x & 0 = 0），非 cbo 时原样通过 ✓
        wire illegal = (ill_instr & ~cbo_valid) | (opt == 4'd15) | csr_ill | cbo_ill_perm;
        wire kill    = unsup | illegal;

        wire rs1_used = ((opt == 4'd0) | (opt == 4'd1) | (opt == 4'd3) | (opt == 4'd4) |
                         (opt == 4'd6) | (opt == 4'd7) | (opt == 4'd12) | fp_src1_int) &
                        ~kill & ~csr_zimm;
        wire rs2_int  = ((insn[6:0] == `RV32GC_OP_OP) | (opt == 4'd1) |
                         ((opt == 4'd4) & (memop == 4'd2))) & ~kill;
        //   ★★ 2B-4 修复（锁步 p4_fpu 暴露）：**FMA 的三个操作数都是 FP 源**。
        //     旧实现写成 `rs1_f/rs2_f = is_opfp & ~is_fma`（只有 rs3 是 FP 源）⇒ 重命名
        //     只查/只唤醒第三个源，`pd_f_s[0]/[1]`（= FPU 的 a/b）停留在未映射值
        //     ⇒ 实测 `fmadd.s fs3,ft2,ft3,ft1` 得 0x3f800000（= c）而 Spike/2A 给
        //     0x41000000（2×3.5+1=8.0）。源槽映射见 §2 组装：s1←rs1、s2←rs2、s3←rs3，
        //     与 fpu.v 的 `.a/.b/.c` 端口一一对应 ⇒ 三者都必须置位。
        wire rs1_f    = is_opfp & ~fp_src1_int & ~kill;
        //   ★ 源 2 只有"双 FP 源"的族（算术/符号注入/min-max/比较）+ FMA + FP store 才存在：
        //     fsqrt / fmv.x.w / fclass / fcvt.* 的源 2 域是**变体选择位**，不是寄存器号
        //     ⇒ 置位会凭空多出一个 FP 依赖（性能假停顿，且 fp_op_map 之外无任何用处）。
        wire fp_two_fp_src = is_opfp & ~is_fma &
                             ((f5 == `RV32GC_FP_F5_FADD)   | (f5 == `RV32GC_FP_F5_FSUB) |
                              (f5 == `RV32GC_FP_F5_FMUL)   | (f5 == `RV32GC_FP_F5_FDIV) |
                              (f5 == `RV32GC_FP_F5_FSGNJ)  | (f5 == `RV32GC_FP_F5_FMINMAX) |
                              (f5 == `RV32GC_FP_F5_FCMP));
        wire rs2_f    = (fp_two_fp_src | is_fma |
                         ((opt == 4'd12) & (memop == 4'd8))) & ~kill;
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
        //   ecall 的 cause（按当前特权级；见下）
        //   异常码优先级（提交点语义，AGENT.md §3.3）：**取指异常 > ecall/ebreak > 非法指令**。
        //   （本段 priv 恒 M ⇒ ecall cause = 11；S/U 的 9/8 待 4b 接 csr_file 后按 priv 生成。）
        //   ★★ 4b-3(2/2)：`ecall` 的 cause 由 **priv** 决定（ISA：8 = U / 9 = S / 11 = M）。
        //     ⚠ 口径更正：任务书写"S 下 ecall ⇒ scause=8"与 ISA 相反 —— `EXC_ECALL_U=8`（U 模式）、
        //       `EXC_ECALL_S=9`（S 模式）；本实现按 ISA。
        //     为什么可在**派发期**取 priv：priv 只在 trap/xret 提交点变化，而 `priv_ctrl` 对
        //     "priv 变化"发 `flush_req`（`priv_ctrl.v:155`）⇒ 任何跨越 priv 变化的年轻指令都会被
        //     冲掉 ⇒ 能活到提交的 ecall，其派发期 priv == 提交期 priv ✓（无需提交点重算）。
        wire [3:0] exc_w = lane_fault_i[g] ? {1'b0, lane_fault_cause_i[g*5 +: 4]} :
                           ecall  ? ecall_cause_w :
                           ebreak ? `BACK2_EXC_BREAK :
                           kill   ? `BACK2_EXC_ILLEGAL : `BACK2_EXC_NONE;

        // ★ 禁止"整段清零 + 逐段赋值"：wire 上的多条连续赋值是**多驱动**，同位宽
        //   的 0/1 冲突会在 iverilog/Vivado 下解析成 **x**（实测：PC/ARND 等所有含 1
        //   的字段全变 x ⇒ ROB 提交流全 x ⇒ 后端假提交、前端不推进）。本块内
        //   [UOPW-1:0] 的**每一个 bit 恰好被下面一条赋值覆盖一次**（含 AUX/SRC 段；
        //   PSPD 段 [PDIDST_MSB:PS3F_LSB] 由重命名结果在 lane_uop_fin 处显式拼接填入）。
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
        .rob_snap_idx({rb_ix_w[3], rb_ix_w[2], rb_ix_w[1], rb_ix_w[0]}),
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
        .rob_snap_idx({rb_ix_w[3], rb_ix_w[2], rb_ix_w[1], rb_ix_w[0]}),
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
    wire [DISP_W*`BACK2_STQ_IDX_W-1:0] st_alloc_idx;
    //   ★ 2B-4 第二步：LQ 在 D3 派发期为 **load** lane 分配（槽位 = 程序序）
    wire [DISP_W-1:0] ld_alloc_v;
    wire       ld_alloc_ok;
    wire [DISP_W*LDW-1:0] ld_alloc_idx;
    assign ld_alloc_v[0] = d1_v_q[0] & u_is_ld(d1_uop_q[0]);
    assign ld_alloc_v[1] = d1_v_q[1] & u_is_ld(d1_uop_q[1]);
    assign ld_alloc_v[2] = d1_v_q[2] & u_is_ld(d1_uop_q[2]);
    assign ld_alloc_v[3] = d1_v_q[3] & u_is_ld(d1_uop_q[3]);
    //   ★ STQ 分配同时把各 lane 的 ROB 索引送进 LSQ：ROB 项与 lane 一一对应
    //     （同一块内 lane 0 最老：ROB 索引 = rob_alloc_idx0 + lane，与 §IQ 写口同式）。
    assign st_alloc_rob = {rb_ix_w[3], rb_ix_w[2], rb_ix_w[1], rb_ix_w[0]};
    wire [3:0]  lsu_dr_ok_w;
    //   ★★ 4c(2/3)：**CSR 串行化**（本核 CSR 只在 ROB 头发射、提交点写 ⇒ 同一时刻只应有一条
    //     "未提交 CSR"在飞）。原实现的待提交跟踪 `csr_pend_q` 只记**一条**（派发时
    //     `~csr_pend_q` 才登记）⇒ **连续多条 CSR**（p16 的 `fsflags/frflags/fsrmi/frrm/frcsr`
    //     序列）只有第一条被跟踪，后续 CSR 的"CSR→FP/load 可见性窗"完全失守（实测 p16：
    //     `fsrm frm,0(RNE)` 在飞时，紧随的 `fcvt.w.s` 已按**旧 frm=RTZ** 执行 ⇒ 得 3 而非 4
    //     ⇒ 自检跳 fail）。修法：**含 CSR 的块在"有未提交 CSR"期间不得派发** ⇒ 不变式
    //     "至多一条未提交 CSR"成立，`csr_pend_q` 的年龄窗（load/FP 门）才可靠。
    //     （死锁性：在飞的 CSR 一定比 D1 里的块**更老**，其发射不受本门影响 ⇒ 它提交后门即开。）
    reg        csr_pend_q;      // 有"最老未提交 CSR 指令"
    reg  [ROBW-1:0] csr_pend_rob_q;  // 它的 ROB 索引（年龄窗原点；L3：模 ROB_N）
    wire       blk_has_csr_w = (d1_v_q[0] & u_is_csr(d1_uop_q[0])) |
                               (d1_v_q[1] & u_is_csr(d1_uop_q[1])) |
                               (d1_v_q[2] & u_is_csr(d1_uop_q[2])) |
                               (d1_v_q[3] & u_is_csr(d1_uop_q[3]));
    wire       csr_serial_w  = blk_has_csr_w & csr_pend_q;
    wire        disp_ok = (d1_v_q != {DISP_W{1'b0}}) & ~rn_i_busy & ~rn_f_busy &
                          ~squash_v_w & ~flush_all_w &
                          rob_alloc_ready & free_i_ok & free_f_ok & iq_room_ok &
                          st_alloc_ok & ld_alloc_ok & ~csr_serial_w;
    assign disp_fire_w = disp_ok;
    //   ★★ 2B-5 第 3 步②：**派发期预译码** xRET/维护标志（每 lane 5 bit）送给 ROB 存入 `nq`；
    //     提交侧因此**不再需要**读 4 lane 的 32 bit 指令字来译码（那是 4×32=128 bit 的 128:1 mux）。
    //     译码真源仍是本文件的 `is_xret_f/xret_kind_f/maint_kind_f`（与提交侧原来逐字一致）。
    wire [4:0] lane_pre [0:DISP_W-1];
    genvar gp5;
    generate
    for (gp5 = 0; gp5 < DISP_W; gp5 = gp5 + 1) begin : g_pre
        wire [31:0] t5 = u_tval(lane_uop_fin[gp5]);
        assign lane_pre[gp5] = { is_xret_f(t5) & (xret_kind_f(t5) == 2'd1),   // mret
                                 is_xret_f(t5) & (xret_kind_f(t5) != 2'd1),   // sret
                                 maint_kind_f(t5) };
    end
    endgenerate
    wire [COMMIT_W*5-1:0] alloc_pre_w = { lane_pre[3], lane_pre[2], lane_pre[1], lane_pre[0] };
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
        //     段序（MSB→LSB）必须与 back2_params.vh §2 的 PSPD 段一致（★ EXP-R2 后的位号）：
        //     PDIDST(128:123) PDIOLD(122:117) PDFDST(116:111) PDFOLD(110:105)
        //     PS1I(104:99) PS2I(98:93) PS1F(92:87) PS2F(86:81) PS3F(80:75)
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
            iq_wrob[qi*WI*ROBW +: WI*ROBW] = {(WI*ROBW){1'b0}};
            iq_wrdy[qi*WI*SRC_N +: WI*SRC_N] = {(WI*SRC_N){1'b0}};
        end
        for (gi2 = 0; gi2 < DISP_W; gi2 = gi2 + 1) begin
            if (d1_v_q[gi2]) begin
                iq_wv  [lane_q[gi2*3 +: 3]*WI + q_ord[gi2]] = 1'b1;
                iq_wuop[lane_q[gi2*3 +: 3]*WI*UOPW + q_ord[gi2]*UOPW +: UOPW] =
                        lane_uop_fin[gi2];
                iq_wrob[lane_q[gi2*3 +: 3]*WI*ROBW + q_ord[gi2]*ROBW +: ROBW] =
                        rb_ix_w[gi2];
                iq_wrdy[lane_q[gi2*3 +: 3]*WI*SRC_N + q_ord[gi2]*SRC_N +: SRC_N] =
                        lane_rdy[gi2*5 +: 5];
            end
        end
    end

    // ---- ROB 载荷组装 ----
    //   ★★ C4：按 `back2_params.vh` §2 的**新位域表**逐字段拼接（MSB→LSB，无空洞）。
    //      ★ EXP-R2：整数字段收窄后 RB_W 229→225，位置注释已同步。
    //     与旧版的差别只有「删掉谁都不读的位」：uop 全量副本（IMM/ARND/源物理号/控制码/
    //     uop.TVAL/架构源号）与 CSRW 段不再进载荷；其余字段（PC/PREDTGT/PRED/BTB/CLS/CKPT/
    //     PDIOLD/PDFOLD/TVAL/PS1I/CSRADDR/CSROP/STQ/LQ）逐位保留、语义不变。
    //   ⚠ 拼接顺序必须与参数表的 MSB→LSB 一致；改一处必须两处同步（唯一真源纪律）。
    //   ⚠⚠ 每个 lane 的**源切片**用 `BACK2_U_*`（uop 布局，因为源是 `lane_uop_fin`），
    //      而注释里的 `[a:b]` 是**目标位置**（`BACK2_RB_*`）—— 两者**不可混用**：
    //      初版误用 RB_* 去切 uop（如 PDIOLD 切到 [55:49]）⇒ 提交释放的旧物理号全错
    //      ⇒ 实测 tb_core_top_2b 出现大量 `RENAME-CHK DUP/自环`。
    //   ★★ EXP-R2：三个整数字段（PS1I/PDIOLD/PDIDST）随 `BACK2_PREG_I_W` 收窄 1 bit ⇒
    //      其上整段下移 3，EXP-R3 的 `[88]` 保留位被**回收给 LQ**（本拼接不再补那 1 bit 0）。
    //      拼接总宽 = `BACK2_RB_W`（225）；源切片全用 `BACK2_U_*`，目标位置全用 `BACK2_RB_*`。
    genvar g5;
    generate
    for (g5 = 0; g5 < DISP_W; g5 = g5 + 1) begin : g_rb
        assign rob_pay_w[g5*RB_W +: RB_W] = {
            lane_uop_fin[g5][`BACK2_U_BTB_MSB:`BACK2_U_BTB_LSB],           // → [224:223] BTB
            lane_uop_fin[g5][`BACK2_U_PRED_MSB:`BACK2_U_PRED_LSB],         // → [222:219] PRED
            lane_uop_fin[g5][`BACK2_U_PC_MSB:`BACK2_U_PC_LSB],             // → [218:187] PC
            lane_uop_fin[g5][`BACK2_U_PREDTGT_MSB:`BACK2_U_PREDTGT_LSB],   // → [186:155] PREDTGT
            5'b0,                                                          // [154:150] fflags（占位）
            1'b0,                                                          // [149]     trtaken（占位）
            32'h0,                                                         // [148:117] tr 目标（占位）
            d1_uop_q[g5][`BACK2_U_TVAL_MSB:`BACK2_U_TVAL_LSB],             // [116:85]  异常 tval
            ld_alloc_idx[g5*LDW +: LDW],                                   // [84:82]   LQ 索引（3 bit）
            st_alloc_idx[g5*`BACK2_STQ_IDX_W +: `BACK2_STQ_IDX_W],         // [81:77]   STQ 索引
            lane_uop_fin[g5][`BACK2_U_PDFDST_MSB:`BACK2_U_PDFDST_LSB],   // → [76:71]   浮点新映射
            lane_uop_fin[g5][`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB],       // → [70:66]   目的架构号
            lane_uop_fin[g5][`BACK2_U_PDIDST_MSB:`BACK2_U_PDIDST_LSB],   // → [65:60]   整数新映射
            lane_uop_fin[g5][`BACK2_U_PDFOLD_MSB:`BACK2_U_PDFOLD_LSB],   // → [59:54]   浮点旧映射
            lane_uop_fin[g5][`BACK2_U_PDIOLD_MSB:`BACK2_U_PDIOLD_LSB],   // → [53:48]   整数旧映射
            lane_uop_fin[g5][`BACK2_U_PS1I_MSB:`BACK2_U_PS1I_LSB],       // → [47:42]   源 1 物理号
            lane_uop_fin[g5][`BACK2_U_CSRADDR_MSB:`BACK2_U_CSRADDR_LSB], // → [41:30]   CSR 地址
            lane_uop_fin[g5][`BACK2_U_CSROP_MSB:`BACK2_U_CSROP_LSB],     // → [29:27]   CSR 操作
            lane_uop_fin[g5][`BACK2_U_CLS_MSB:`BACK2_U_CLS_LSB],         // → [26:24]   分支类别
            lane_uop_fin[g5][`BACK2_U_CKPT_MSB:`BACK2_U_CKPT_LSB],       // → [23:20]   检查点 id
            lane_uop_fin[g5][`BACK2_U_FLAGS_MSB:`BACK2_U_FLAGS_LSB],     // → [19:4]    FLAGS 整块
            lane_uop_fin[g5][`BACK2_U_EXC_MSB:`BACK2_U_EXC_LSB]          // → [3:0]     异常码
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
    //   ★★ C1：不再有 `i*_sel_uop`（IQ 不持宽字段）；门控改读窄载荷 `iq_sel_nq[q]`
    wire i0_sel_v; wire [6:0] i0_sel_rob;
    wire i1_sel_v; wire [6:0] i1_sel_rob;
    wire i2_sel_v; wire [6:0] i2_sel_rob;
    wire i3_sel_v; wire [6:0] i3_sel_rob;
    wire i4_sel_v; wire [6:0] i4_sel_rob;
    wire i5_sel_v; wire [6:0] i5_sel_rob;
    wire [5:0] wk_i_v_w;
    wire [6*PW_I-1:0] wk_i_tag_w;
    wire [5:0] wk_f_v_w;
    wire [6*PW_F-1:0] wk_f_tag_w;
    // CSR 只在 ALU0、且必须已到 ROB 头（§8.3：读写都按提交序可见）
    wire al0_csr_blk = i0_sel_v & iq_sel_nq[0][`BACK2_IQN_IS_CSR] & (i0_sel_rob != rob_head_w);

    wire [2:0] q0_ready = ~al0_csr_blk;
    wire [2:0] q1_ready = 3'd1;
    wire [2:0] q2_ready = 3'd1;
    wire [2:0] q3_ready = mdu_free_w ? 3'd1 : 3'd0;
    //   ★ LSU 队列的发射门控**只对 load 生效**：`lsu_iss_ok`（来自 lsq_simple）语义是
    //     "STQ 内没有更老的**未定址** store ⇒ load 可安全乱序取数"；对 **store 自身**
    //     必须放行，否则队头 store 永远算不出地址 ⇒ STQ 永远存在未定址项 ⇒ `iss_ok`
    //     恒 0 ⇒ 自锁（实测：程序尾 `sw x31,0(x30)` 停在 ROB 头 `hdone=0`、LSU 队列
    //     `sel=1/iss=0`、`stq=1`、后端永久停顿）。q4_ready 供观察，iss_ready 用新判据。
    //   ★★ 4b-2c 收尾（CSR 可见性 load 侧根治）：**更老的未提交 CSR 指令在途时，年轻 load
    //     不得发射**。机理：CSR 只在提交点更新，而访存的翻译上下文在执行期读取；CSR 指令虽
    //     "只在 ROB 头执行"（`al0_csr_blk`），但年轻 load 可以在它执行**之前**就发射（两者属
    //     不同队列、无数据依赖）⇒ load 会按旧的 MPRV/priv 翻译（实测 p14：误报 cause 13）。
    //     判据：`csr_pend_q`（有未提交 CSR）+ 候选 load 的 ROB 比它**更年轻**（年龄窗口算术，
    //     B27 口径：`(a-b)&0x7F` ∈ (0, 64) 即"a 在 b 之后、且未绕环"）。
    //     跟踪寄存器/组合信号在此声明（driver 见 §12 后的 CSR 提交区）。

    //   ★ L3（ROB 128→64）：判据改为**精确年龄序**（原半分窗写法在 N=64 下会误挡更老项）。
    //     原写法 `(候选 − CSR) & 0x7F ∈ (0, N/2)` 只在两者距离 < N/2 时正确；N=64 后
    //     N/2=32，距离 ≥33 的**更老**候选会被误判为"更年轻"而挡下 —— 这与本段注释声明的
    //     "更老项不受影响（无死锁）"矛盾：更老项若卡在 ROB 头，年轻 CSR 永不成为头 ⇒ 永久停顿。
    //     精确性依据：候选与在飞 CSR **都必在 ROB 窗内**（iq.v 的 out_window 保证在飞项
    //     age < rob_cnt；CSR 未提交/未冲刷则 csr_pend_q 恒有效）⇒ 二者相对 ROB 头的模 N 年龄
    //     就是真实偏移（唯一），`age(候选) > age(CSR)` 即精确的"候选更年轻"，且更老项永不被挡。
    wire [ROBW-1:0] csr_pend_age_w = csr_pend_rob_q - rob_head_w[ROBW-1:0];
    wire [ROBW-1:0] csr_age_w      = i4_sel_rob[ROBW-1:0] - rob_head_w[ROBW-1:0];
    wire       csr_cand_win_w = ({1'b0, csr_age_w} < rob_cnt_w);   // 候选确在窗内才判序
    wire       csr_ld_block_w = csr_pend_q & csr_cand_win_w & (csr_age_w > csr_pend_age_w);
    wire lsu_ld_block = iq_sel_nq[4][`BACK2_IQN_IS_LOAD] & (~lsu_iss_ok_w | csr_ld_block_w);
    //   ★★ 4c(2/3)：**CSR→FP 可见性互锁**（与上面的 load 门同构、同一窗算术）——
    //     FP 指令读的是**组合回灌**的 `csr_frm_w`（fcsr.frm，供 DYN 舍入解析）+ 提交点累积
    //     fflags 的 RMW 基值 `csr_ff_w`；而 CSR 写只在**提交点**生效 ⇒ 若一条比该 CSR
    //     **更年轻**的 FP 指令在它提交前发射/执行，就会用**旧 frm**（实测 p16：
    //     `fsrmi frm,1(RTZ)` → `fcvt.w.s 3.5`(经 frm=RTZ)=3 ✓ → `fsrm frm,0(RNE)` →
    //     紧随的 `fcvt.w.s` **仍按 RTZ 执行** ⇒ 得 3 而非 4 ⇒ 自检跳 fail、黄金在 #40 分歧）。
    //     判据与 load 门同构（**精确年龄序**，见 §5 该门的 L3 说明）；更老的项不受影响 ⇒
    //     CSR 仍能提交、窗清空后 FP 恢复发射（**无死锁**：CSR 在 ROB 里更老且其发射不受 FP 影响）。
    //   ★ L3：与 load 门同构（精确年龄序，阈值/半分窗近似问题见上），仅换到 i5 的候选。
    wire [ROBW-1:0] csr_fp_age_w   = i5_sel_rob[ROBW-1:0] - rob_head_w[ROBW-1:0];
    wire       csr_fp_win_w = ({1'b0, csr_fp_age_w} < rob_cnt_w);
    wire       csr_fp_block_w = csr_pend_q & csr_fp_win_w & (csr_fp_age_w > csr_pend_age_w);
    //   ★★ 4c(2/3)：**DYN 舍入的 FP 项只在 ROB 头发射** —— `rm=111(DYN)` 时 FPU 的舍入模式
    //     取自 `csr_frm_w`（fcsr.frm 的**提交点**回灌），而上面的年龄窗门只能挡住"年龄窗内
    //     登记过的那条 CSR"；一个派发块可含**多条** CSR（p16 实测 `{fsrmi,frrm,frcsr}` 同块）
    //     且"更老 CSR 仍在飞、更年轻 CSR 已登记"的交错会让窗失效 ⇒ 更年轻的 FP 项仍可能
    //     用**旧 frm** 执行。最稳且与 2A 顺序语义一致的判据：DYN 项**等到它成为 ROB 头**
    //     才发射 ⇒ 届时所有更老指令（含任何 CSR 写）都已提交 ⇒ 读到的 frm 必为已提交值 ✓
    //     （无死锁：更老指令不依赖 FP 队列；静态 rm 的 FP 项不受此门限制）
    wire       fpu_dyn_w   = iq_sel_nq[5][`BACK2_IQN_RM_DYN];   // ★ C1：RM==7 由 IQ 窄载荷直接给出
    wire       fpu_head_w  = (i5_sel_rob == rob_head_w);
    wire       fpu_iss_ok_w = fpu_free_w & ~csr_fp_block_w & (~fpu_dyn_w | fpu_head_w);
    wire [2:0] q4_ready = ~lsu_ld_block;
    //   注：`q5_ready` 是**派发侧容量**（只反映队列余量），**不得**并入发射门 ——
    //   它会经写口仲裁影响派发，实测并入后 p16 第 12 条出现多余整数写回。
    wire [2:0] q5_ready = fpu_free_w ? 3'd1 : 3'd0;

    //   ★★ C1：各队列的**基础**发射许可（= C1 之前 `iss_ready` 的全部判据，逐位不变）。
    //     最终 `iss_ready` = 基础许可 ∧ **读口获准**（`iwm_gnt`）⇒ 拿不到读口的队列本拍
    //     不出队、下一拍重试（宽载荷要到手才能进 E1）。顺序：{q5,q4,q3,q2,q1,q0}
    assign iq_base_rdy = { fpu_iss_ok_w, ~lsu_ld_block, mdu_free_w, 1'b1, 1'b1, ~al0_csr_blk };

    iq #(.DEPTH(`BACK2_IQ_ALU0_D), .DBG(DBG_IQ)) u_iq0 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w), .squash_age(squash_age_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[0*WI +: WI]), .wr_uop(iq_wuop[0*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[0*WI*ROBW +: WI*ROBW]), .wr_rdy(iq_wrdy[0*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[0]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(iq_base_rdy[0] & iwm_gnt[0]),
        .iss_valid(iq_iss_v[0]), .iss_rob(iq_iss_rob[0]),   // ★ C1：不接宽 uop
        .iss_epoch(iq_iss_ep[0]), .iss_dead(iq_iss_dead[0]),
        .o_sel_v(i0_sel_v), .o_sel_rob(i0_sel_rob), .o_sel_nq(iq_sel_nq[0]), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_ALU1_D), .DBG(DBG_IQ)) u_iq1 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w), .squash_age(squash_age_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[1*WI +: WI]), .wr_uop(iq_wuop[1*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[1*WI*ROBW +: WI*ROBW]), .wr_rdy(iq_wrdy[1*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[1]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(iq_base_rdy[1] & iwm_gnt[1]),
        .iss_valid(iq_iss_v[1]), .iss_rob(iq_iss_rob[1]),   // ★ C1：不接宽 uop
        .iss_epoch(iq_iss_ep[1]), .iss_dead(iq_iss_dead[1]),
        .o_sel_v(i1_sel_v), .o_sel_rob(i1_sel_rob), .o_sel_nq(iq_sel_nq[1]), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_BRU_D), .DBG(DBG_IQ)) u_iq2 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w), .squash_age(squash_age_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[2*WI +: WI]), .wr_uop(iq_wuop[2*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[2*WI*ROBW +: WI*ROBW]), .wr_rdy(iq_wrdy[2*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[2]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(iq_base_rdy[2] & iwm_gnt[2]),
        .iss_valid(iq_iss_v[2]), .iss_rob(iq_iss_rob[2]),   // ★ C1：不接宽 uop
        .iss_epoch(iq_iss_ep[2]), .iss_dead(iq_iss_dead[2]),
        .o_sel_v(i2_sel_v), .o_sel_rob(i2_sel_rob), .o_sel_nq(iq_sel_nq[2]), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_MDU_D), .DBG(DBG_IQ)) u_iq3 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w), .squash_age(squash_age_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[3*WI +: WI]), .wr_uop(iq_wuop[3*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[3*WI*ROBW +: WI*ROBW]), .wr_rdy(iq_wrdy[3*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[3]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(iq_base_rdy[3] & iwm_gnt[3]),
        .iss_valid(iq_iss_v[3]), .iss_rob(iq_iss_rob[3]),   // ★ C1：不接宽 uop
        .iss_epoch(iq_iss_ep[3]), .iss_dead(iq_iss_dead[3]),
        .o_sel_v(i3_sel_v), .o_sel_rob(i3_sel_rob), .o_sel_nq(iq_sel_nq[3]), .cnt_o()
    );
    //   ★★ 2B-3 第 6 段第二步（**真乱序的边界**）：`INORD_LOAD` **保持 1**，但它的角色
    //     从"唯一兜底"变为"**LQ 槽位序的防死锁门**"，与精确的 STQ 闸门**并联**：
    //       · STQ 闸门（`lsq_simple` §2.1，`iss_ok`）：更老 store **未定址** ⇒ 阻塞本 load
    //         （B28 保守语义；年龄按**候选** `i4_sel_rob` 判定、`stq_rob` 在**分配期**写入
    //         ⇒ 判定逐条精确）；更老 store **均已定址** ⇒ 放行，重叠字节由 §2.2 逐字节
    //         转发/合并兜住（同字节取**最年轻**的更老匹配者）。
    //       · INORD_LOAD（队列级）：更老的 LSU 项未就绪 ⇒ 本 load 不可选。
    //     ★ **为何不能简单地把 INORD_LOAD 置 0**（本段实测 + 结构分析，记为 2B-3 遗留）：
    //       LQ 槽在 **E1（发射后一拍）**分配，释放点在**提交**。若容许 load 越过"更老未就绪
    //       的 load"，则年轻 load 可以先占满 32 个 LQ 槽并完成，而更老那条 load 因
    //       `ld_slot_ok=0` 永远发不出去 ⇒ 它不 done ⇒ ROB 头无法越过它 ⇒ 那些年轻人的槽
    //       也永不释放 ⇒ **结构性死锁**（实测程序 0/1/2 未触发：LQ 峰值占用仅 2，但该形态
    //       对一般程序可达）。真要放开，必须把 LQ 分配改到 **D3 派发期**（程序序分配、
    //       提交点释放，天然无此环）—— ROB 载荷 [415:411] 恰有 5 bit 空闲位可用（见
    //       `back2_params.vh` §2 的空位注），留作后续段。
    //   ★★ 2B-4 第二步：LQ 槽已改为 **D3 派发期**分配（程序序）⇒ 2B-3 里"槽在 E1 分配"
    //     造成的**结构性死锁**（年轻 load 占满 32 槽 ⇒ 更老 load 永不发射 ⇒ ROB 头卡死
    //     ⇒ 槽永不释放）从根上消失：任何人都不可能抢走更老指令已分到的槽。
    //     故队列级门撤销（`INORD_LOAD=0`），"更老未定址 store"的保守语义由 §2.1 的
    //     精确 STQ 闸门（`iss_ok`）独立承担 —— 实测五个程序逐位不变（见报告 §B4.1）。
    iq #(.DEPTH(`BACK2_IQ_LSU_D), .DBG(DBG_IQ), .INORD_LOAD(0)) u_iq4 (   // 2B-4: LQ 派发期分配 ⇒ 可放开
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w), .squash_age(squash_age_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[4*WI +: WI]), .wr_uop(iq_wuop[4*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[4*WI*ROBW +: WI*ROBW]), .wr_rdy(iq_wrdy[4*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[4]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(iq_base_rdy[4] & iwm_gnt[4]),
        .iss_valid(iq_iss_v[4]), .iss_rob(iq_iss_rob[4]),   // ★ C1：不接宽 uop
        .iss_epoch(iq_iss_ep[4]), .iss_dead(iq_iss_dead[4]),
        .o_sel_v(i4_sel_v), .o_sel_rob(i4_sel_rob), .o_sel_nq(iq_sel_nq[4]), .cnt_o()
    );
    iq #(.DEPTH(`BACK2_IQ_FPU_D), .DBG(DBG_IQ)) u_iq5 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w), .squash(squash_v_w), .squash_idx(squash_idx_w), .squash_age(squash_age_w),
        .rob_cnt(rob_cnt_w),
        .epoch(epoch_w),
        .wr_valid(iq_wv_g[5*WI +: WI]), .wr_uop(iq_wuop[5*WI*UOPW +: WI*UOPW]),
        .wr_rob(iq_wrob[5*WI*ROBW +: WI*ROBW]), .wr_rdy(iq_wrdy[5*WI*SRC_N +: WI*SRC_N]),
        .free_cnt(iq_cnt[5]),
        .wki_v(wk_i_v_w), .wki_tag(wk_i_tag_w), .wkf_v(wk_f_v_w), .wkf_tag(wk_f_tag_w),
        .rob_head(rob_head_w), .iss_ready(iq_base_rdy[5] & iwm_gnt[5]),
        .iss_valid(iq_iss_v[5]), .iss_rob(iq_iss_rob[5]),   // ★ C1：不接宽 uop
        .iss_epoch(iq_iss_ep[5]), .iss_dead(iq_iss_dead[5]),
        .o_sel_v(i5_sel_v), .o_sel_rob(i5_sel_rob), .o_sel_nq(iq_sel_nq[5]), .cnt_o()
    );

    // 选择观察口汇总（诊断/外部门控用；旧版只在 §1 声明了 iq_sel_v 却从未驱动
    //   ⇒ 悬空网 z，任何引用都会把 x 传下去。此处补上唯一赋值点。）
    assign iq_sel_v = {i5_sel_v, i4_sel_v, i3_sel_v, i2_sel_v, i1_sel_v, i0_sel_v};

    //==========================================================================
    // 5.5 ★★ C1：发射宽载荷（IQ 已不存宽字段）—— 4 bank SDP 存储 + 读口仲裁 + 4:1 交叉开关
    //==========================================================================
    // 【为什么另起一份 4 bank SDP，而不是复用 `rob.v` 里 `rob_wide_mem` 的读口】
    //   · ROB 那份读口被**提交头部窗口预取**占满（rob.v §1.5 的 `re(4'hF)`：每拍 4 读，
    //     把 head..head+3 的 416 bit 载荷预取进 8 槽 FF 窗口）；
    //   · 发射读的需求是"任意 rob 索引、每拍最多 4 个不同 bank"。若与预取共用同一份读口，
    //     发射最多 **1 读/拍**（且会让提交窗口饿死 ⇒ 提交宽度掉到 ≤1）—— 那是"用 IPC 换面积"，
    //     与本任务"不改变 4-wide 派发/提交"的口径冲突；实测口径见交付报告 §C1 读路径量化。
    //   · 故为发射路径**单独实例化一份同构 4 bank SDP**（`u_iwmem`，复用 `rob_wide_mem`
    //     模块本体 ⇒ 零新增模块文件）：写口与 ROB 载荷同源、同拍、同索引分解
    //     （bank = idx[1:0]，偏移 = idx[5:2]）⇒ 每拍 4 lane 写天然各占 1 bank、无需仲裁；
    //     读口 4 个 bank 各 1 个，仲裁后每 bank ≤1 读 ⇒ 每拍最多 4 个队列同时拿到宽载荷。
    // 【为什么"不增加发射级数"】同步读 1 拍：第 T 拍 IQ 选出 rob 索引 ⇒ 发起读；第 T+1 拍
    //   BRAM 的输出寄存器给出的宽载荷**直接**作为 E1 的 `x_i2_uop`（与改前的 `x_i2_uop`
    //   触发器完全同拍）⇒ **发射→执行仍是 1 拍**（IPC 不因本改动结构性下降）。
    //   ★★ C9 后硬成本 = **12 个 RAMB36**（DW=215 ≤ 216 ⇒ 3/bank；改前 DW=280 ⇒ 4/bank）。
    //     ★ EXP-R2：DW 215→212，仍 ≤ 216 ⇒ 仍是 3/bank（RAMB 数不变，只省读出位宽）。
    // 【写口】D3 派发 4 lane 的 rob 索引连续 ⇒ bank=gw 对应的 lane = (gw - idx0[1:0]) mod 4
    //   （与 rob.v §1.5 的 `wsel` 逐位同式），写数据 = `pack_iw(lane_uop_fin[lane])`
    //   （= 从**同一条** uop 抽取 E1 真正读的字段，见 back2_params §2.5）。
    genvar gw_iwm;
    generate
    for (gw_iwm = 0; gw_iwm < 4; gw_iwm = gw_iwm + 1) begin : g_iwmw
        wire [1:0] lw = gw_iwm[1:0] - rob_alloc_idx0[1:0];
        assign iwm_we[gw_iwm] = disp_fire_w & d1_v_q[lw];
        assign iwm_woff[gw_iwm*4 +: 4] = rb_ix_w[lw][5:2];
        //   ★★ C9：写数据 = `pack_iw(uop)`（字段抽取，纯布线）；不再是 `uop[IWW-1:0]` 切片。
        assign iwm_wdata[gw_iwm*IWW +: IWW] = pack_iw(lane_uop_fin[lw]);
    end
    endgenerate
    rob_wide_mem #(.NW(4), .BW(16), .DW(IWW), .AW(ROBW), .OW(4), .CHK(0)) u_iwmem (
        .clk(clk), .rst_n(rst_n),
        .we(iwm_we), .woff(iwm_woff), .wdata(iwm_wdata),
        .re(iwm_re), .roff(iwm_roff), .rdata(iwm_rdata));

    // ---- 读口仲裁（组合、固定优先级 ALU0 > ALU1 > BRU > MDU > LSU > FPU）----
    //   请求源用**未门控**的选择观察口（`i*_sel_v`/`i*_sel_rob`）⇒ 与 `iss_ready` 无组合环
    //   （`iss_ready` ⊃ `iwm_gnt`，而 `iwm_gnt` 只依赖观察口与**基础**许可 `iq_base_rdy`）。
    //   每 bank 至多 1 个获准者 ⇒ 与 4 bank 的读口数一一对应；被抢的队列只是"本拍不出队"，
    //   下一拍重试。无饥饿：更高优先级队列的在飞项数有限（程序有限），且每拍最多 4 个 bank
    //   同时获准 ⇒ ROB 头项不会永久拿不到读口（有界等待）。
    assign iwm_req   = { i5_sel_v, i4_sel_v, i3_sel_v, i2_sel_v, i1_sel_v, i0_sel_v } & iq_base_rdy;
    assign iwm_rbank = { i5_sel_rob[1:0], i4_sel_rob[1:0], i3_sel_rob[1:0],
                         i2_sel_rob[1:0], i1_sel_rob[1:0], i0_sel_rob[1:0] };
    function [5:0] iwm_arb;
        input [5:0]  rq;
        input [11:0] bk;
        integer      a, c;
        reg [5:0]    g;
        begin
            g = 6'd0;
            for (a = 0; a < 6; a = a + 1)
                if (rq[a]) begin
                    g[a] = 1'b1;
                    for (c = 0; c < a; c = c + 1)
                        if (rq[c] && (bk[c*2 +: 2] == bk[a*2 +: 2])) g[a] = 1'b0;
                end
            iwm_arb = g;
        end
    endfunction
    assign iwm_gnt = iwm_arb(iwm_req, iwm_rbank);

    //   bank 级读命令与数据归属：每个 bank 的获准队列（唯一）+ 它的 rob 索引 [5:2]
    genvar gb_iwm;
    generate
    for (gb_iwm = 0; gb_iwm < 4; gb_iwm = gb_iwm + 1) begin : g_iwmr
        wire [5:0] hit = iwm_gnt & { (iwm_rbank[11:10] == gb_iwm[1:0]),
                                     (iwm_rbank[9:8]  == gb_iwm[1:0]),
                                     (iwm_rbank[7:6]  == gb_iwm[1:0]),
                                     (iwm_rbank[5:4]  == gb_iwm[1:0]),
                                     (iwm_rbank[3:2]  == gb_iwm[1:0]),
                                     (iwm_rbank[1:0]  == gb_iwm[1:0]) };
        assign iwm_re[gb_iwm] = |hit;
        assign iwm_roff[gb_iwm*4 +: 4] =
               (hit[0] ? i0_sel_rob[5:2] : 4'h0) |
               (hit[1] ? i1_sel_rob[5:2] : 4'h0) |
               (hit[2] ? i2_sel_rob[5:2] : 4'h0) |
               (hit[3] ? i3_sel_rob[5:2] : 4'h0) |
               (hit[4] ? i4_sel_rob[5:2] : 4'h0) |
               (hit[5] ? i5_sel_rob[5:2] : 4'h0);
        assign iwm_own_nx[gb_iwm] = hit[0] ? 3'd0 : hit[1] ? 3'd1 : hit[2] ? 3'd2 :
                                    hit[3] ? 3'd3 : hit[4] ? 3'd4 : hit[5] ? 3'd5 : 3'd6;
    end
    endgenerate

    // ---- E1 拍：把"上一拍读回的 4 bank 数据"按归属路由到 6 个队列（4:1 mux ×6）----
    //   注：`x_i2_v[xi]`（= 上一拍发射有效，见 §6）与读回数据严格同拍 ⇒ 未发射队列的 mux
    //   输出即使来自别的 bank 也没有消费者（下游全部由 `x_i2_v` 门控）。
    genvar gx_iwm;
    generate
    for (gx_iwm = 0; gx_iwm < 6; gx_iwm = gx_iwm + 1) begin : g_xbar
        wire [1:0] os = (iwm_own_q[0] == gx_iwm[2:0]) ? 2'd0 :
                        (iwm_own_q[1] == gx_iwm[2:0]) ? 2'd1 :
                        (iwm_own_q[2] == gx_iwm[2:0]) ? 2'd2 : 2'd3;
        assign x_i2_uop[gx_iwm] = iwm_rdata[os*IWW +: IWW];
    end
    endgenerate

    //==========================================================================
    // 6. I2 寄存器 + E1 执行
    //==========================================================================
    integer xi;
    //   ★★ 4c①（G4 收口登记的遗留 1）：**squash 拍同拍发射的"年轻项"必须一并作废** ——
    //     与 G4⑤ 的 `flush_all_w` 门同理，只是作废范围限于"**年轻于 squash 点**"：
    //     `iq.iss_valid` 是组合输出（`valid_q` 在时钟沿才被 `squash_kill` 清），故 squash 拍
    //     仍可能选中一项；旧实现把它无条件装进 I2 ⇒ 下一拍该**错路径控制转移**在 I2 里复活，
    //     其 `bru_mis` 会在重定向后一拍**再发一次重定向**（把前端拉到错路径取指）。
    //     年龄判据照抄 `iq.v` 的 `squash_kill`：以 **ROB 头为原点**取模年龄，
    //     "更年轻" ⇔ `age(项) > age(squash_idx)`；比较**零扩展到 8 bit**
    //     （`rob_cnt=ROB_N` 时在 ROB_IDX_W 位里表示为 0 ⇒ 窄位比较会把"满窗口"误判成
    //      "空窗口"，见 `iq.v:279-287` 的实测注释）。更老的项（含正在提交的前缀）不受影响 ✓
    //   ★ L3：年龄统一为 **ROBW 位模 ROB_N**（与 iq.v §5 的 `age = idx - head` 逐位同口径）；
    //     两侧年龄都只有 0..ROB_N-1 ⇒ 零扩展到 8 bit 后与 rob_cnt(≤ROB_N) 比较仍然正确。
    function i2_sq_kill_f;
        input [ROBW-1:0] iss_rob;
        begin
            i2_sq_kill_f = squash_v_w &
                           ({1'b0, (iss_rob - rob_head_w[ROBW-1:0])} >
                            {1'b0, squash_age_w});
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (xi = 0; xi < 6; xi = xi + 1) x_i2_v[xi] <= 1'b0;
        end else begin
            //   ★★ G4⑤ 缺陷修正（p15 实测抓出）：**整机冲刷拍（`flush_all_w`）同拍发射的 uop
            //     必须一并作废**。`iq.iss_valid` 是**组合**输出（`valid_q` 在时钟沿才被 `flush_all`
            //     清空）⇒ 冲刷拍仍可能选中一项；旧实现无条件把它装进 I2（`x_i2_v<=iq_iss_v`），
            //     下一拍该错路径项就在 I2 里"复活"：
            //       · 若它是**控制转移**且判定误判 ⇒ `squash_v_w` 再发一次重定向，**盖掉**陷阱/中断
            //         刚发出的 mtvec 重定向 ⇒ 前端被拉回被冲刷的旧路径、处理程序永不执行
            //         （实测 p15：c=2506 `trp=1/trp_redirect=1` 目标 mtvec=0x8002_c0a8，同拍
            //          `iq_iss_v=000100`；c=2507 `x_i2_v[2]=1` ⇒ `squash=1`、前端 PC 被改回
            //          0x8002_c08c ⇒ MEI 的 mcause/mepc/mstatus 已写但**跳不进 handler**）。
            //       · 非控制转移项同样属"冲刷点之后"的年轻项，按精确异常口径一律作废。
            //     口径与 IQ 入队侧一致（`iq.v` §5.3 "冲刷拍不接受新项"），只是补上**出队侧**。
            for (xi = 0; xi < 6; xi = xi + 1) begin
                x_i2_v[xi] <= iq_iss_v[xi] & ~iq_iss_dead[xi] & ~flush_all_w &
                              ~i2_sq_kill_f(iq_iss_rob[xi]);
                if (iq_iss_v[xi] & ~flush_all_w & ~i2_sq_kill_f(iq_iss_rob[xi])) begin
                    //   ★★ C1：`x_i2_uop[xi]` 不再在此寄存 —— 宽载荷由 §5.5 的 `u_iwmem`
                    //     同步读输出（同拍）+ 4:1 交叉开关组合给出，与这里的 `x_i2_v` 同拍。
                    x_i2_rob[xi] <= iq_iss_rob[xi];
                    x_i2_ep[xi]  <= iq_iss_ep[xi];
                end
            end
        end
    end

    wire [31:0] a0_opa = w_au(x_i2_uop[0]) ? w_pc(x_i2_uop[0]) : iprf_rd[0*32 +: 32];
    wire [31:0] a0_opb = w_rt(x_i2_uop[0]) ? iprf_rd[1*32 +: 32] : w_imm(x_i2_uop[0]);
    wire [31:0] a0_res;
    alu u_alu0 (.a(a0_opa), .b(a0_opb),
                .alu_op(w_aluop(x_i2_uop[0])),
                .pc(w_pc(x_i2_uop[0])), .result(a0_res));

    wire [31:0] a1_opa = w_au(x_i2_uop[1]) ? w_pc(x_i2_uop[1]) : iprf_rd[2*32 +: 32];
    wire [31:0] a1_opb = w_rt(x_i2_uop[1]) ? iprf_rd[3*32 +: 32] : w_imm(x_i2_uop[1]);
    wire [31:0] a1_res;
    alu u_alu1 (.a(a1_opa), .b(a1_opb),
                .alu_op(w_aluop(x_i2_uop[1])),
                .pc(w_pc(x_i2_uop[1])), .result(a1_res));

    wire [31:0] bru_rs1 = iprf_rd[4*32 +: 32];
    wire [31:0] bru_rs2 = iprf_rd[5*32 +: 32];
    wire        bru_taken;
    wire [31:0] bru_target;
    bru u_bru (.rs1(bru_rs1), .rs2(bru_rs2), .imm(w_imm(x_i2_uop[2])), .pc(w_pc(x_i2_uop[2])),
               .br_op(w_brop(x_i2_uop[2])),
               .taken(bru_taken), .target(bru_target));
    wire        bru_isjal  = (w_opt(x_i2_uop[2]) == OPT_JAL);
    wire        bru_isjalr = (w_opt(x_i2_uop[2]) == OPT_JALR);
    wire        bru_act_tk = bru_isjal | bru_isjalr | bru_taken;
    wire [31:0] bru_ilen   = w_il32(x_i2_uop[2]) ? 32'd4 : 32'd2;
    wire [31:0] bru_link   = w_pc(x_i2_uop[2]) + bru_ilen;
    wire [31:0] bru_npc    = bru_act_tk ? bru_target : bru_link;
    wire [31:0] bru_pred_t = {32{w_pred_tk(x_i2_uop[2])}} & w_predtgt(x_i2_uop[2]);
    wire [31:0] bru_pred_n = w_pred_tk(x_i2_uop[2]) ? w_predtgt(x_i2_uop[2]) : bru_link;
    wire [2:0]  bru_cls    = w_cls(x_i2_uop[2]);
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
                             ((bru_act_tk != w_pred_tk(x_i2_uop[2])) |
                              (bru_act_tk & bru_cmp_t & (bru_target != bru_pred_n)));

    // MDU（至多 1 条在飞；busy/done 握手）
    //   ★★ 2B-4 修复（锁步 p5_mdu 暴露）：`start` 必须取 **E1 有效**（`x_i2_v[3]`），
    //     不能取 **发射拍**（`iq_iss_v[3]`）——mdu.v/fpu.v 的端口契约是
    //     "`start`/`req_valid` 与操作数在**同一拍**被采样"（2A 侧即 `e_mdu_go`/`e_fp_go`
    //     与 `e_rs1_byp`/`e_fp_src*` 同拍）。而本后端的操作数走 **E1**（`iprf_ra[6..10]`
    //     = `w_ps1i(x_i2_uop[3/5])`，见 §PRF 读口），发射拍的操作数尚不在 `x_i2_*` 里
    //     ⇒ 旧接法把"发射拍"当启动、却把"上一拍的 x_i2 内容"当操作数：
    //     该 FP/MDU 指令**永远不启动** ⇒ `done` 不来 ⇒ `fpu_if_v/mdu_if_v` 恒 1
    //     ⇒ 队列永久停摆（锁步实测：p4_fpu 第 20 条 `fadd.s` 处挂死，探针
    //     `fpu_busy=0 拍 / fpu_done=0 拍` 而 `x_i2_v[5]` 已脉冲 1 拍）。
    wire        mdu_busy, mdu_done;
    wire [31:0] mdu_result;
    wire        mdu_go = x_i2_v[3];
    //   ★★ 2B-4 修复（锁步 p4_fpu 暴露）：**年龄限定冲刷** —— squash 只能杀"比 squash 点
    //     更年轻"的在飞工作。旧实现把 `flush(squash_v_w | flush_all_w)` **无条件**送进
    //     mdu/fpu，同时又无条件清 `*_if_v`：若在飞项**比 squash 点更老**（典型：它正是
    //     ROB 头，前端口一次误判回滚时它并不在作废范围内），它的 ROB 项不会被作废，但执行
    //     被冲掉 ⇒ `done` 永不再来 ⇒ ROB 头永久卡住（实测：p4_fpu 第 40 条 `fmv.x.w`
    //     在 c=493 被 `squash_idx=66` 的冲刷打掉，`fpu_if_rob=42=rob_head`，
    //     之后 200000 拍 ROB 头 hdone 恒 0、IQ-5 仍在发更年轻的 FP 指令）。
    //     判据与 ROB/LSU 同口径（无掩码窗口算术，B27 纪律）：
    //       age(在飞项) > age(squash 点) ⇒ 该项更年轻 ⇒ 本次冲刷该杀它。
    wire        mdu_kill = flush_all_w |
                           (squash_v_w & ((mdu_if_rob[ROBW-1:0] - rob_head_w[ROBW-1:0]) >
                                          squash_age_w));
    wire        fpu_kill = flush_all_w |
                           (squash_v_w & ((fpu_if_rob[ROBW-1:0] - rob_head_w[ROBW-1:0]) >
                                          squash_age_w));
    wire [4:0] mdu_brop = w_brop(x_i2_uop[3]);
    mdu u_mdu (.aclk(clk), .aresetn(rst_n), .start(mdu_go), .flush(mdu_kill),
               .mdu_op(mdu_brop[2:0]),
               .a(iprf_rd[6*32 +: 32]), .b(iprf_rd[7*32 +: 32]),
               .busy(mdu_busy), .done(mdu_done), .result(mdu_result));

    // FPU（至多 1 条在飞）
    wire        fpu_busy, fpu_done, fpu_ffwe;
    wire [63:0] fpu_result;
    wire [4:0]  fpu_ff;
    wire [63:0] fpu_a = w_s1f(x_i2_uop[5]) ? fprf_rd[0*64 +: 64]
                                            : {32'hFFFF_FFFF, iprf_rd[10*32 +: 32]};
    fpu u_fpu (
        .clk(clk), .rst_n(rst_n), .flush(fpu_kill),
        //   ★★ 2B-4 同上：`req_valid` 取 **E1 有效**（与 `.a/.b/.c` 同拍）
        .req_valid(x_i2_v[5]), .fp_op(w_fpop(x_i2_uop[5])),
        .fmt(w_fmt(x_i2_uop[5])), .rm(w_rm(x_i2_uop[5])),
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
    //   ★★ 4c(3/3)：8 B 装载（fld）的高 4 B 与“64 bit 装载”标志
    wire [31:0] lsu_wb_data_hi;
    wire        lsu_wb_f64;
    wire        lsu_st_done_v;
    wire [6:0]  lsu_st_done_rob;
    wire [EW-1:0] lsu_st_done_ep;
    //   ★★ 4b-2b：数据侧精确异常（页错误）—— LSQ → ROB `upd_exc`
    wire        lsu_exc_v;
    wire [6:0]  lsu_exc_rob;
    wire [3:0]  lsu_exc_cause;
    wire [31:0] lsu_exc_tval;
    wire [31:0] lsu_addr = iprf_rd[8*32 +: 32] + w_imm(x_i2_uop[4]);
    wire [63:0] lsu_fpsrc = fprf_rd[3*64 +: 64];
    wire [31:0] lsu_wdata = (w_fpls(x_i2_uop[4]) & w_is_st(x_i2_uop[4])) ?
                            lsu_fpsrc[31:0] : iprf_rd[9*32 +: 32];
    //   ★★ 4c(3/3)：FP store 的**高 4 B**（fsd 的 64 bit 数据上半）；非 FP store 恒 0
    wire [31:0] lsu_wdata_hi = (w_fpls(x_i2_uop[4]) & w_is_st(x_i2_uop[4])) ?
                               lsu_fpsrc[63:32] : 32'h0;
    lsq_simple #(.DBG(DBG_LSU)) u_lsu (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all_w),
        .squash(squash_v_w), .squash_idx(squash_idx_w), .rob_head(rob_head_w),
        .alloc_valid(st_alloc_v & {DISP_W{disp_fire_w}}),
        .alloc_rob(st_alloc_rob),
        .lalloc_valid(ld_alloc_v & {DISP_W{disp_fire_w}}),
        .lalloc_rob(st_alloc_rob),
        .lalloc_ok(ld_alloc_ok), .lalloc_idx(ld_alloc_idx),
        .alloc_ok(st_alloc_ok), .alloc_idx(st_alloc_idx),
        .exe_valid(x_i2_v[4]), .exe_is_store(w_is_st(x_i2_uop[4])),
        .exe_is_fp(w_fpls(x_i2_uop[4])),
        .exe_rob(x_i2_rob[4]), .exe_epoch(x_i2_ep[4]),
        .exe_addr(lsu_addr), .exe_wdata(lsu_wdata), .exe_wdata_hi(lsu_wdata_hi),
        .exe_size(w_msize(x_i2_uop[4])),
        .exe_unsign(w_munsign(x_i2_uop[4])),
        .exe_dst_i(w_di(x_i2_uop[4])), .exe_dst_f(w_df(x_i2_uop[4])),
        //   ★ 目的物理号取 **PDIDST**（u_pdi），不是源 1（u_ps1i）；写口/唤醒 tag 同源。
        .exe_pdest_i(w_pdi(x_i2_uop[4])), .exe_pdest_f(w_pdf(x_i2_uop[4])),
        .exe_stq_idx(stq_of_rob_r), .exe_lq_idx(lq_of_rob_r),
        //   ★ 发射闸门按**候选**（i4_sel）的 ROB 索引判年龄；iss_ok 即接 IQ 的 iss_ready。
        .iss_rob(i4_sel_rob),
        .iss_ok(lsu_iss_ok_w), 
        .dr_valid(lsu_dr_valid), .dr_idx(lsu_dr_idx),
        .cmt_n(cmt_n_w),
        //   ★ 2B-4：CDQ 余量回送 ROB 的 store 提交门（见 §7 的 `mem_wr_ready` 接线）
        .dr_room_ok(lsu_dr_room_w),
        .mem_req_valid(mem_req_valid_o), .mem_req_wen(mem_req_wen_o),
        .mem_req_addr(mem_req_addr_o), .mem_req_wdata(mem_req_wdata_o),
        .mem_req_wstrb(mem_req_wstrb_o), .mem_req_tag(mem_req_tag_o),
        .mem_req_ready(mem_req_ready_i),
        .mem_rsp_valid(mem_rsp_valid_i), .mem_rsp_rdata(mem_rsp_rdata_i),
        .mem_rsp_tag(mem_rsp_tag_i), .mem_rsp_err(mem_rsp_err_i),
        //   ★★ (b)：执行期 store 翻译口（透传到 `core_top_2b` 的数据适配器）
        .st_xlate_en(st_xlate_en_i), .st_xlate_ctx(st_xlate_ctx_i),
        .st_xlate_valid(st_xlate_valid_o), .st_xlate_va(st_xlate_va_o),
        .st_xlate_idx(st_xlate_idx_o), .st_xlate_ctx_o(st_xlate_ctx_o),
        .st_xlate_ready(st_xlate_ready_i), .st_xlate_done(st_xlate_done_i),
        .st_xlate_pa(st_xlate_pa_i), .st_xlate_fault(st_xlate_fault_i),
        .exc_valid_o(lsu_exc_v), .exc_rob_o(lsu_exc_rob),
        .exc_cause_o(lsu_exc_cause), .exc_tval_o(lsu_exc_tval),
        .wb_valid(lsu_wb_v), .wb_rob(lsu_wb_rob), .wb_epoch(lsu_wb_ep),
        .wb_dst_i(lsu_wb_di), .wb_dst_f(lsu_wb_df),
        .wb_pdest_i(lsu_wb_pdi), .wb_pdest_f(lsu_wb_pdf), .wb_data(lsu_wb_data),
        .wb_data_hi(lsu_wb_data_hi), .wb_f64(lsu_wb_f64),
        .st_done_valid(lsu_st_done_v), .st_done_rob(lsu_st_done_rob),
        .st_done_epoch(lsu_st_done_ep),
        .stq_cnt_o(dbg_stq_cnt_o), .cnt_load_o(), .cnt_store_o(), .cnt_fwd_o(),
        .dr_empty_o(cdq_empty_o),
        .cnt_stq_stall_o()
    );

    //==========================================================================
    // 7. 写回总线 / 唤醒 / PRF
    //==========================================================================
    assign mdu_free_w = ~mdu_if_v;
    assign fpu_free_w = ~fpu_if_v;
    assign stq_of_rob_r = stq_of_rob[x_i2_rob[4]];
    //   ★ 2B-4：E1 的 load 取"派发期分到的 LQ 槽"（组合读 `lq_of_rob`，与 stq_of_rob 同法）
    assign lq_of_rob_r  = lq_of_rob[x_i2_rob[4]];
    //   ★ B29：CSR 指令的写回值 = CSR 读回值（而非 ALU 结果）。
    //   ★★ C9：判据由「`csr_uop[Q] == Q_ALU0`」改为「**CSR 落在 ALU0 的发射槽（lane 0）**」。
    //     等价性论证（不是放松，是等价且更严）：
    //       · CSR 指令的队列归属由译码器 `oq` 固定为 `Q_ALU0`（§4.1「CSR 只在 ALU0 执行」）
    //         ⇒ 旧式读的是 **CSR uop 自己的 Q 字段**，而它**恒等于 Q_ALU0** ⇒ 旧式实际退化为
    //         `csr_v_w ? csr_rdata_w : a0_res`；
    //       · `x_i2_uop[0]` 就是 ALU0 队列本拍发射的那条 ⇒ `csr_lane == 0` 精确表达
    //         「本拍 ALU0 槽里是那条 CSR」；若 CSR 出现在别的槽（构造上不可能：只有 ALU0
    //         队列会取到 Q=ALU0 的 uop），新式给出 `a0_res`（不把 CSR 数据错塞进 lane 0）。
    //       · 发射宽载荷（IW）因此不必再存 3 bit 的 Q 字段（其唯一消费点就是本判据）。
    wire [31:0] a0_wb_data = (csr_v_w & (csr_lane == 3'd0)) ? csr_rdata_w : a0_res;
    wire        a0_wb_i    = w_di(x_i2_uop[0]);
    wire [31:0] a1_wb_data = a1_res;
    wire        a1_wb_i    = w_di(x_i2_uop[1]);
    wire [31:0] bru_wb_data = (w_wbsel(x_i2_uop[2]) == WB_PC4) ? bru_link : bru_target;
    wire        bru_wb_i    = w_di(x_i2_uop[2]);
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
    assign wb_rob[WBP_ALU0*ROBW +: ROBW] = x_i2_rob[0];
    assign wb_rob[WBP_ALU1*ROBW +: ROBW] = x_i2_rob[1];
    assign wb_rob[WBP_BRU*ROBW +: ROBW]  = x_i2_rob[2];
    assign wb_rob[WBP_MDU*ROBW +: ROBW]  = mdu_if_rob;
    assign wb_rob[WBP_LSU*ROBW +: ROBW]  = lsu_wb_rob;
    assign wb_rob[WBP_FPU*ROBW +: ROBW]  = fpu_if_rob;
    assign wb_rob[WBP_STD*ROBW +: ROBW]  = lsu_st_done_rob;
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
        input [ROBW-1:0] idx;
        begin
            in_rob_win = ({1'b0, (idx - rob_head_w[ROBW-1:0])} < rob_cnt_w);
        end
    endfunction
    //   ★ 这里**不用 function 调用**（展开为纯表达式）：iverilog 12.0 在把 function
    //     调用放进连续赋值/位拼接时实测会给出错误结果（本文件另一处 generate 内
    //     调用 function 也有同类记录，见 iq.v §1 注）。展开写法与函数语义逐位相同。
    wire [5:0] wbi_keep = {
        ({1'b0, (wb_rob[5*ROBW +: ROBW] - rob_head_w[ROBW-1:0])} < rob_cnt_w),
        ({1'b0, (wb_rob[4*ROBW +: ROBW] - rob_head_w[ROBW-1:0])} < rob_cnt_w),
        ({1'b0, (wb_rob[3*ROBW +: ROBW] - rob_head_w[ROBW-1:0])} < rob_cnt_w),
        ({1'b0, (wb_rob[2*ROBW +: ROBW] - rob_head_w[ROBW-1:0])} < rob_cnt_w),
        ({1'b0, (wb_rob[1*ROBW +: ROBW] - rob_head_w[ROBW-1:0])} < rob_cnt_w),
        ({1'b0, (wb_rob[0*ROBW +: ROBW] - rob_head_w[ROBW-1:0])} < rob_cnt_w) };
    //   ★ 写回 tag = **目的**物理号（PDIDST/PDFDST），供 ① PRF 写口 ② busy 位清零
    //     ③ 唤醒广播 三处共用。旧版误写成源 1（ps1i）⇒ 结果写进源寄存器、目的
    //     busy 位永不清零 ⇒ 消费者永不唤醒（实测：lui 之后的 jalr 永不发射）。
    assign wbi_tag = { fpu_if_pdi, lsu_wb_pdi, mdu_if_pdi,
                       w_pdi(x_i2_uop[2]), w_pdi(x_i2_uop[1]), w_pdi(x_i2_uop[0]) };
    assign wbi_data = { fpu_wb_idata, lsu_wb_data, mdu_wb_data, bru_wb_data, a1_wb_data, a0_wb_data };

    assign wki_v   = NO_WAKE ? {wbi_v[5], wbi_v[4], wbi_v[3], wbi_v[2], 1'b0, wbi_v[0]} : wbi_v;
    assign wki_tag = wbi_tag;
    assign wk_i_v_w = wki_v;
    assign wk_i_tag_w = wki_tag;
    assign wk_f_v_w   = {{(6-2){1'b0}}, (fpu_wb_v & fpu_wb_f), (lsu_wb_v & lsu_wb_f)};
    assign wk_f_tag_w = {{(6*PW_F - 2*PW_F){1'b0}}, fpu_if_pdf, lsu_wb_pdf};

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
        //   ★★ EXP-R3a 第 4 处（busy 表 epoch 过滤缺陷，2026-10-06 母 Agent 批准落地）：
        //     原判据 `wb_ep[bi] == epoch_w` 用**全局当前 epoch** 过滤在飞写回 ⇒ 跨冲刷
        //     存活的生产者（已被发射、1~2 拍后写回）带的是**发射时** epoch，其写回被误
        //     过滤 ⇒ `busy` 位永不清零 ⇒ 消费者入队时就绪位恒 0、而 IQ 唤醒是一拍脉冲早
        //     已过去 ⇒ 该 ROB 项永不 done ⇒ ROB 头卡死、前端检查点池饱和（实测 p13
        //     `bne x19,x5` 卡在 BRU 队：ps1i=40 恒 rdy=0，`busy_i_q[40]` 永为 1）。
        //     **与 rob.v §5.2 同口径**：rob 侧早已把 done 过滤改为比"项内记录的分配时
        //     epoch"，并留下同型教训注释；此处改用 **`wbi_keep`**（写回项仍在 ROB 窗口内
        //     ⇒ 属于存活项）等价表达同一语义，且天然排除索引被复用/已冲刷的旧写回。
        //     ⚠ 不能简单删掉过滤：窗口判据同时承担"旧写回不得误清新分配项"的原目标。
        for (bi = 0; bi < 6; bi = bi + 1) begin
            if (wbi_v[bi] && wbi_keep[bi])
                busy_i_nx[wbi_tag[bi*PW_I +: PW_I]] = 1'b0;
        end
        //   ★★ 同上，浮点 busy 表两处同型潜伏缺陷一并按"在窗"口径修（`wbi_keep[WBP_LSU]`
        //     = bit4 ↔ `lsu_wb_rob`、`wbi_keep[WBP_FPU]` = bit5 ↔ `fpu_if_rob`；与 2105-2106
        //     行浮点 PRF 写口既有的 `wkeep` 表达式**同一语义**，非另起口径）。
        if (lsu_wb_v & lsu_wb_df & wbi_keep[WBP_LSU]) busy_f_nx[lsu_wb_pdf] = 1'b0;
        if (fpu_wb_v & fpu_wb_f  & wbi_keep[WBP_FPU]) busy_f_nx[fpu_if_pdf] = 1'b0;
    end

    //==========================================================================
    // 9. 提交（W1）：写回值读出 / 架构 RAT / 释放 / CSR / store 排空 / 训练 / 检查点
    //==========================================================================
    //   ★★ 2B-4 第 4a 段：**xRET 的"提交上报"例外**。
    //     实测口径（/opt/riscv/bin/spike --log-commits，本段 §B4.4.2 登记）：
    //       · 抛陷阱的那条指令（ecall/ebreak/非法）**不进**提交日志（Spike 只记
    //         "exception ... epc"行）⇒ 本核也不上报（`slot_ok` 含 `~slot_exc`）；
    //       · `mret` **进**提交日志（它正常退役）⇒ 本核必须上报那一拍，
    //         否则提交 PC 流少一条、与黄金逐条比对必然分歧。
    //     xret 拍 `flush_all` 同时为 1（冲刷年轻工作）⇒ 这里开一个"仅上报"的口子：
    //     只放开 `cmt_ok`，所有**副作用**仍由各自的 `p_di/p_df/cmt_st_drain` 门控
    //     （mret/sret 无目的寄存器、非访存 ⇒ 无副作用可泄漏）。
    //   ★ 4b-2a：维护操作与 xRET 一样——它们**自己触发冲刷**（把更年轻的工作清掉），
    //     但那条指令本身必须照常计入提交流 ⇒ 口子扩为 (xret | maint)
    assign cmt_ok = ~squash_v_w & (~flush_all_w | ((xret_cmt_o | maint_cmt_o) & trp_flush_v_i));
    //   ★ LQ 提交点释放的窗口宽度：`cmt_raw` 是 rob.v 的**前缀连续**提交链（第 i 槽可提交 ⇒
    //     前面全可提交）⇒ 条数 = popcount；冲刷/陷阱拍强制 0（不得释放未提交项）。
    assign cmt_n_w = cmt_ok ? ({2'b0, cmt_raw[0]} + {2'b0, cmt_raw[1]} +
                               {2'b0, cmt_raw[2]} + {2'b0, cmt_raw[3]}) : 3'd0;
    assign cmt_i2 = x_i2_rob[2];

    genvar cc;
    generate
    for (cc = 0; cc < COMMIT_W; cc = cc + 1) begin : g_cmt
        wire [RB_W-1:0] p = cmt_pay[cc*RB_W +: RB_W];
        //   ★★ 2B-5 第 3 步②-b：**窄字段改吃 `cmt_narrow`**（第 1 步已导出）。
        //     `di/df/arn/pdi/pdf` 均在 `nq`（FF 窄表、组合读）⇒ 宽载荷的这些位**不再被读**，
        //     Vivado 可相应裁掉其 128:1 读 mux 与存储（存储/mux 均只保留 `nq` 一份）。
        wire [`BACK2_NQ_W-1:0] pn = cmt_narrow[cc*`BACK2_NQ_W +: `BACK2_NQ_W];
        assign commit_valid_o[cc] = cmt_raw_m[cc] & cmt_ok;
        assign commit_pc_o[cc*32 +: 32] = p_pc(p);
        assign commit_arch_rd_o[cc*5 +: 5] = pn[`BACK2_NQ_ARN_L +: 5];
        assign commit_arch_we_o[cc] = pn[`BACK2_NQ_DI] | pn[`BACK2_NQ_DF];
        wire [63:0] cval_f = fprf_rd[(4+cc)*64 +: 64];
        assign commit_arch_rd_wdata_o[cc*32 +: 32] =
            pn[`BACK2_NQ_DI] ? iprf_rd[(11+cc)*32 +: 32] :
            pn[`BACK2_NQ_DF] ? cval_f[31:0] : 32'h0;
        assign cmt_i_we[cc]   = cmt_raw_m[cc] & cmt_ok & pn[`BACK2_NQ_DI];
        assign cmt_i_arn[cc*5 +: 5] = pn[`BACK2_NQ_ARN_L +: 5];
        assign cmt_i_pd[cc*PW_I +: PW_I] = pn[`BACK2_NQ_PDI_L +: PW_I];
        assign rel_i_we[cc]   = cmt_raw_m[cc] & cmt_ok & pn[`BACK2_NQ_DI];
        assign rel_i_pd[cc*PW_I +: PW_I] = p_pdio(p);
        assign cmt_f_we[cc]   = cmt_raw_m[cc] & cmt_ok & pn[`BACK2_NQ_DF];
        assign cmt_f_arn[cc*5 +: 5] = pn[`BACK2_NQ_ARN_L +: 5];
        assign cmt_f_pd[cc*PW_F +: PW_F] = pn[`BACK2_NQ_PDF_L +: PW_F];
        assign rel_f_we[cc]   = cmt_raw_m[cc] & cmt_ok & pn[`BACK2_NQ_DF];
        assign rel_f_pd[cc*PW_F +: PW_F] = p_pdfo(p);
        //   ★★ 4b-2c(2/2) 根因修复：**维护/陷阱/xRET 的整机冲刷不得抑制"更老 store"
        //     的 CDQ 排空入队**（否则已提交写静默丢失——实测 p13：PTE 更新 store 与紧随的
        //     `sfence.vma` 同组/相邻，store 已提交但从未进 CDQ ⇒ l1[0] 仍是旧 PTE）。
        //     口径：入队许可 = "在本拍提交前缀内（`cmt_st_drain`）× 未被维护 lane 掩码
        //     挡住（`~cmt_hold_w`，只掩**更年轻** lane）× 未被 squash"，**不再无条件乘
        //     `cmt_ok`**；`cmt_ok` 仅在"维护/xRET 冻结窗口"里为 0，而那正是更老 store
        //     仍可能需要入队的拍。
        //   ★★ 定案（逐拍探针 + 代码定案）：抑制点就是**本式的 `cmt_ok`/`~squash_v_w`**。
        //     `cmt_st_drain[cc] = cmt_chain[cc] & slot_store[cc]`（rob.v:213）而 `cmt_chain`
        //     只是 `slot_ok` 的**前缀链**、**不含任何 flush/squash 门** ⇒ 维护/陷阱/xRET 拍
        //     `cmt_st_drain` 对"更老的已提交 store"仍为 1；是 `cmt_ok`（含 `~squash_v_w`
        //     与 `~flush_all_w`）把这次入队抹掉了 ⇒ 已提交写静默丢失（p13 的 PTE 更新
        //     store 即此形态：轨迹可见提交、适配器侧从未出现）。
        //     修法：**排空入队只看"前缀链里的 store"与"不被维护 lane 掩码挡住"**——
        //     `cmt_st_drain` 天然只含已提交前缀项，冲刷不可能让更老项变成未提交 ⇒ 安全。
        //     覆盖面：维护 / 陷阱 / xRET 触发的整机冲刷拍全部包含在内。
        assign lsu_dr_valid[cc] = cmt_st_drain[cc] & ~cmt_hold_w[cc];
        assign lsu_dr_idx[cc*`BACK2_STQ_IDX_W +: `BACK2_STQ_IDX_W] = p_stq(p);
    end
    endgenerate

    // 提交点 CSR 写（同拍至多 1 条：CSR 指令只在 ROB 头执行 ⇒ 至多一条在飞）
    reg        csr_cmt_we;  reg [11:0] csr_cmt_addr; reg [31:0] csr_cmt_data;
    reg [2:0]  csr_cmt_op;   // ★ B29：提交级 CSR 操作码
    reg        ff_cmt_any;  reg [4:0]  ff_cmt_val;
    reg [ROBW-1:0] csr_cmt_idx;              // ★ 4c(2/3)：本拍提交的 CSR 的 ROB 索引（L3：模 ROB_N）
    reg [31:0] csr_cmt_insn;                 // 该 CSR 指令的原始编码（判 zimm 形式）
    reg [PW_I-1:0] csr_cmt_ps1i;             // 该 CSR 指令自己的 rs1 物理号（B29 残留清理）
    //   ★★ 2B-5 第 3 步②：CSR lane 在提交组内的位置（供**单 lane 动态读口**索引）
    reg [1:0]  csr_cmt_lane;
    integer    cw;
    always @(*) begin
        csr_cmt_we   = 1'b0;
        csr_cmt_addr = 12'h0;
        csr_cmt_data = 32'h0; csr_cmt_op = 3'd0; csr_cmt_insn = 32'h0;
        csr_cmt_ps1i = {PW_I{1'b0}};
        ff_cmt_any   = 1'b0;
        ff_cmt_val   = 5'h0;
        csr_cmt_idx  = {ROBW{1'b0}};
        csr_cmt_lane = 2'd0;
        for (cw = COMMIT_W-1; cw >= 0; cw = cw - 1) begin
            if (commit_valid_o[cw]) begin
                //   ★ ②：判定改吃 `cmt_narrow` 的 `is_csr`（FF 组合读）；
                //     宽字段（tval/csrw/csra/csrop）改由 rob.v 的**单 lane 动态读口** `csr_pay_w` 提供
                if (cmt_narrow[cw*`BACK2_NQ_W + `BACK2_NQ_CSR]) begin
                    csr_cmt_we   = 1'b1;
                    csr_cmt_lane = cw[1:0];
                    csr_cmt_addr = csr_pay_w[14:3];
                    csr_cmt_data = csr_pay_w[46:15];
                    csr_cmt_op   = csr_pay_w[2:0];
                    csr_cmt_insn = csr_pay_w[78:47];
                    csr_cmt_ps1i = csr_pay_w[15 +: PW_I];   // ★ EXP-B：该字段现由 rob 从**载荷 uop.PS1I** 拼出（原为 updq.CSRW 低 PW_I 位，逐位等价）
                    csr_cmt_idx  = rob_head_w[ROBW-1:0] + cw[1:0];      // ★ L3：模 ROB_N（cw ≤ 3）
                end
                if (p_ff(cmt_pay[cw*RB_W +: RB_W]) != 5'h0) begin
                    ff_cmt_any = 1'b1;
                    ff_cmt_val = ff_cmt_val | p_ff(cmt_pay[cw*RB_W +: RB_W]);
                end
            end
        end
    end
    //   ★ ②：单 lane 动态读口索引 = 提交组内 CSR lane 的**绝对 ROB 索引**
    assign csr_dyn_idx_w = rob_head_w[ROBW-1:0] + csr_cmt_lane;   // ★ L3：模 ROB_N

    // fflags 累积写入（FPU 结果提交时），与 CSR 写并路：地址 0x001 用"读改写"
    //   ★★ CSR 可见性互锁的**跟踪**（见 §9 发射门处的声明/说明）
    //     · 派发（`disp_ok` 块内 lane 0 最老）：本块有 CSR 且当前无在途 ⇒ 记下它的 ROB 索引；
    //     · 清除：整机冲刷 / 该 CSR 被 squash / 它**已提交**（CSR 状态已更新 ⇒ 年轻访存可放行）；
    //     · 同一拍"清 + 派发"：后面的派发赋值覆盖 ⇒ 取新的那条（块内最老）✓
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_pend_q     <= 1'b0;
            csr_pend_rob_q <= {ROBW{1'b0}};
        end else begin
            if (flush_all_w) begin
                csr_pend_q <= 1'b0;
            end else if (squash_v_w && csr_pend_q &&
                         ((csr_pend_rob_q[ROBW-1:0] - rob_head_w[ROBW-1:0]) >
                          squash_age_w)) begin
                csr_pend_q <= 1'b0;                     // 该 CSR 在冲刷点之后 ⇒ 已不存在
            end else if (csr_cmt_we) begin
                //   ★★ 4c(2/3)：**只有"被跟踪的那条 CSR"提交才清** —— 一个派发块可含**多条**
                //     CSR（实测 p16 的 `{fsrmi,frrm,frcsr}` 三连同块），更老的 CSR 提交时
                //     若无条件清，会把"更年轻的在飞 CSR"的窗一起抹掉（实测：`frcsr` 在
                //     c=210 提交 ⇒ 把 c=208 登记的 `fsrm` 窗清掉 ⇒ 紧随的 `fcvt.w.s` 用旧
                //     frm 执行）。索引比较用提交级算出的 `csr_cmt_idx`（CSR 可在提交组任意 lane）。
                csr_pend_q <= 1'b0;                     // 该 CSR 已提交 ⇒ CSR 状态已更新
            end
            if (disp_ok) begin
                //   ★★ 4c(2/3) 缺陷修复（p16 实测抓出）：**登记条件不得含 `~csr_pend_q`** ——
                //     它读的是"本拍之前"的寄存器值 ⇒ 在"**同一拍：老 CSR 提交（清）+ 新 CSR 块派发**"
                //     的边界上，新 CSR **不会被登记**（旧值仍为 1）⇒ 紧随其后的 FP/load 可见性窗
                //     完全失守（实测 p16：`fsrm frm,0` 与更老的 `frcsr` 提交同拍派发 ⇒ 未登记 ⇒
                //     紧随的 `fcvt.w.s` 用**旧 frm=RTZ** 执行 ⇒ 得 3 而非 4 ⇒ 自检跳 fail）。
                //     现在改为**无条件登记**（块内 lane 0 最老优先；后面的赋值天然覆盖前面的
                //     ⇒ "清 + 派发"同拍取新登记的那条 ✓）。配合上面的 `csr_serial_w`
                //     不变式（含 CSR 的块在有未提交 CSR 时不派发 ⇒ 至多一条未提交 CSR），
                //     登记值不会被更年轻的 CSR 覆盖 ⇒ 年龄窗可靠。
                //   ★ 4c(2/3)：**取块内"最年轻"的 CSR**（lane 3→0 扫描；lane 0 最老）——
                //     一个块可含多条 CSR，只登记最老的那条会让块内更年轻的 CSR 完全不被
                //     覆盖（实测 p16 的 `{fsrmi,frrm,frcsr}` 块）。登记最年轻者 + "只有它提交
                //     才清" ⇒ 在其提交前，所有更年轻的 FP 项都被挡在发射口外 ✓（保守但正确：
                //     块内更老的 CSR 也一定更早提交）。
                if (d1_v_q[0] & u_is_csr(d1_uop_q[0])) begin
                    csr_pend_q <= 1'b1; csr_pend_rob_q <= rb_ix_w[0];
                end else if (d1_v_q[1] & u_is_csr(d1_uop_q[1])) begin
                    csr_pend_q <= 1'b1; csr_pend_rob_q <= rb_ix_w[1];
                end else if (d1_v_q[2] & u_is_csr(d1_uop_q[2])) begin
                    csr_pend_q <= 1'b1; csr_pend_rob_q <= rb_ix_w[2];
                end else if (d1_v_q[3] & u_is_csr(d1_uop_q[3])) begin
                    csr_pend_q <= 1'b1; csr_pend_rob_q <= rb_ix_w[3];
                end
            end
        end
    end

    wire        csr_we_w    = csr_cmt_we | ff_cmt_any;
    wire [11:0] csr_waddr_w = csr_cmt_we ? csr_cmt_addr : 12'h001;
    //   ★★ 2B-4 第 4a 段缺陷修复：**CSR 立即数形式（csrrwi/csrsi/csrrci）的源**。
    //     载荷 `p_csrw` 存的是"被当成 rs1 重命名"的物理号，而立即数形式的 insn[19:15]
    //     是 **zimm**（5 位立即数，不是寄存器号）⇒ 提交点从 PRF 读回的是**无关寄存器**
    //     的内容：实测 `csrsi mstatus, 8`（p8_int）把 s0=mtvec 的值 0x8001_007c 写进了
    //     mstatus（0x8001_00fc），MIE 位纯属巧合才对。
    //     修法：用载荷 TVAL（原始指令位）判 funct3 —— `insn[14:13] != 0` 即 101/110/111
    //     （csrrwi/csrsi/csrrci）⇒ 源取 `insn[19:15]` 零扩展。**不改 2A 译码器**。
    //   ★★ 2B-4 第 4b-1 段缺陷修正 **D5a**（由新增的 `back2_p10_csr.S` CSR 轨迹判据实测抓住）：
    //     立即数形式的判据必须是 **funct3 的最高位 `insn[14]`**（101/110/111 = csrrwi/csrrsi/csrrci），
    //     而 4a 段误写成 `|insn[14:13]` —— `csrrs`(funct3=010) 与 `csrrc`(011) 的
    //     `insn[14:13] = 2'b01` 也非零 ⇒ **寄存器形式被误判成立即数形式**，
    //     源操作数取成"寄存器号"而非寄存器值（实测：`csrrc s5,mscratch,t3` 用 0x1C 当源值，
    //     落盘 `0x0F0F0F03`，而 Spike 黄金是 `0x0F0F0F00`）。
    wire        csr_cmt_zimm = (csr_cmt_insn[6:0] == 7'b1110_011) & csr_cmt_insn[14];
    wire [31:0] csr_cmt_src_e= csr_cmt_zimm ? {27'b0, csr_cmt_insn[19:15]} : csr_cmt_src;
    //   ★ B29：提交级合成（W→src；S→old|src；C→old&~src）
    wire [31:0] csr_cmt_new = (csr_cmt_op == 3'd1) ? csr_cmt_src_e :
                              (csr_cmt_op == 3'd2) ? (csr_rdata_w | csr_cmt_src_e) :
                                                     (csr_rdata_w & ~csr_cmt_src_e);
    wire [31:0] csr_wdata_w = csr_cmt_we ? (csr_cmt_addr == 12'h001 ?
                              (csr_cmt_new | ff_cmt_val) : csr_cmt_new)
                                         : (csr_ff_w | ff_cmt_val);
    //   ★★ B29 修复：CSR 指令可能落在 I2 的**任意槽**（此前四处硬编码槽 0 ⇒ 取到别的指令的
    //     `x_i2_rob[0]`/读口数据 ⇒ `csrrw` 写入了错误值，实测 mscratch 被写成 1 而非 3）。
    //     CSR 属 ALU0 类（D1 的 oq 分配：CSR 的 opt ⇒ Q_ALU0）⇒ 源操作数取 ALU0 的 rs1 读口。
    wire [2:0] csr_lane = (x_i2_v[0] & w_is_csr(x_i2_uop[0])) ? 3'd0 :
                          (x_i2_v[1] & w_is_csr(x_i2_uop[1])) ? 3'd1 :
                          (x_i2_v[2] & w_is_csr(x_i2_uop[2])) ? 3'd2 :
                          (x_i2_v[3] & w_is_csr(x_i2_uop[3])) ? 3'd3 :
                          (x_i2_v[4] & w_is_csr(x_i2_uop[4])) ? 3'd4 :
                          (x_i2_v[5] & w_is_csr(x_i2_uop[5])) ? 3'd5 : 3'd0;
    wire       csr_v_w  = (x_i2_v[0] & w_is_csr(x_i2_uop[0])) | (x_i2_v[1] & w_is_csr(x_i2_uop[1])) |
                          (x_i2_v[2] & w_is_csr(x_i2_uop[2])) | (x_i2_v[3] & w_is_csr(x_i2_uop[3])) |
                          (x_i2_v[4] & w_is_csr(x_i2_uop[4])) | (x_i2_v[5] & w_is_csr(x_i2_uop[5]));
    wire [IWW-1:0] csr_uop = x_i2_uop[csr_lane];   // ★ C9：发射载荷宽 = IWW
    //   ★★ B29 修法（第 34 轮，按母代理更正）：提交点现算 CSR 写数据 —— 源操作数取
    //   **该 CSR 指令自己的 rs1 物理号（PS1I）**，提交拍直接 `PRF[ps1i]` 取值；不再从
    //   `p_imm[19:15]` 反推（那是 CSR 地址 0x340，[19:15]=6 ⇒ ARAT[6] 恰为值 1 的寄存器，
    //   正是第 33 轮仍为 1 的原因）。
    //   ★★ EXP-B：PS1I 的**载体**由 `updq.CSRW`（102 bit 表里那 32 bit）改为**载荷 uop.PS1I**
    //     —— rob 的 `csr_pay` 的 `csrw` 段现在直接由窗口读回的载荷 PS1I 拼出（见 rob.v §4），
    //     故这里 `csr_cmt_ps1i` 的取值口径**逐位不变**（仍是 PW_I 位物理号）。
    wire [31:0] csr_cmt_src = iprf_rd[15*32 +: 32];
    //   ★ 4b-1：端口 15 的读地址取**该 CSR 指令自己**的 ps1i（4a 曾固定用 lane 0 的载荷
    //     ⇒ CSR 指令不在 lane 0 时会读到无关寄存器；与 B29 同类，一并清掉）
    assign iprf_ra[15*PW_I +: PW_I] = csr_cmt_ps1i;
    wire [31:0] csr_cmt_src_sel = csr_cmt_we ? csr_cmt_src : csr_cmt_src;   // 占位保持可读性
    assign csr_raddr_w = csr_cmt_we ? csr_cmt_addr : w_csra(csr_uop);

    //   B29 诊断：I2 CSR 现场 + CSR 提交现场（默认关）
    //   ★ EXP-B：`cb_src`/`upd_csrw`/`upd_csr_v`/`upd_csr_idx` 随死口删除（CSR 源只走
    //     端口 15 的 PRF 读 + 提交级合成 `csr_cmt_new`），本块只保留仍在用的观测。
    always @(posedge clk) begin
        if (DBG_CSR && rst_n && (|iprf_we))
            $display("[prf-w t=%0t] we=%b wa=%0d,%0d,%0d,%0d,%0d,%0d wd0=0x%08x wd1=0x%08x",
                     $time, iprf_we,
                     iprf_wa[0*PW_I +: PW_I], iprf_wa[1*PW_I +: PW_I], iprf_wa[2*PW_I +: PW_I],
                     iprf_wa[3*PW_I +: PW_I], iprf_wa[4*PW_I +: PW_I], iprf_wa[5*PW_I +: PW_I],
                     iprf_wd[0*32 +: 32], iprf_wd[1*32 +: 32]);
        if (DBG_CSR && rst_n && csr_v_w)
            //   ★ C9：CSROP 已不存于发射载荷（提交级操作码走 ROB 载荷 `csr_pay`）
            //     ⇒ 本行只打发射侧的 PS1I。
            $display("[csr-r t=%0t] ra15=%0d rd15=0x%08x ps1i=%0d",
                     $time, iprf_ra[15*PW_I +: PW_I], csr_cmt_src, csr_cmt_ps1i);
        if (DBG_CSR && rst_n && csr_v_w)
            $display("[csr-uop t=%0t] lane=%0d ps1i=%0d s1i=%b imm=0x%08x | rdata=0x%08x",
                     $time, csr_lane, w_ps1i(csr_uop), w_s1i(csr_uop), w_imm(csr_uop),
                     csr_rdata_w);
        if (DBG_CSR && rst_n && x_i2_v[0] && w_is_csr(x_i2_uop[0]))
            $display("[csr-i2 t=%0t] addr=0x%03x s1i=%b imm=0x%08x rdata=0x%08x",
                     $time, w_csra(x_i2_uop[0]),
                     w_s1i(x_i2_uop[0]), w_imm(x_i2_uop[0]), csr_rdata_w);
        if (DBG_CSR && rst_n && csr_we_w)
            $display("[csr-cmt t=%0t] we=%b addr=0x%03x wdata=0x%08x (cmt_we=%b cmt_addr=0x%03x cmt_data=0x%08x) mscratch=0x%08x",
                     $time, csr_we_w, csr_waddr_w, csr_wdata_w,
                     csr_cmt_we, csr_cmt_addr, csr_cmt_data);
    end

    //   ★ 4b-1a：`b2_csr` 已搬到 `core_top_2b`（CSR 文件不再内嵌于后端）

    // ---- ROB ----
    assign upd_tr_v = x_i2_v[2] & w_is_br(x_i2_uop[2]);
    assign upd_ff_v    = fpu_done & fpu_if_v;


    rob #(.WB_N(7), .DBG_CSR(DBG_CSR)) u_rob (   // B29 定案探针透传
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(disp_fire_w), .alloc_n(d1_n_w),
        .alloc_ready(rob_alloc_ready),
        .alloc_idx0(rob_alloc_idx0), .alloc_lane_valid(d1_v_q), .alloc_payload(rob_pay_w),
        .alloc_pre(alloc_pre_w), .csr_lane_idx(csr_dyn_idx_w), .csr_pay(csr_pay_w),
        .cmt_narrow(cmt_narrow),
        .alloc_epoch(epoch_w),
        .wb_valid(wb_v), .wb_rob_idx(wb_rob), .wb_epoch(wb_ep),
        //   ★★ EXP-B：`upd_csr_*` 三口已删（rob 侧端口同步移除）——它本就硬接 1'b0
        .upd_tr_valid(upd_tr_v), .upd_tr_idx(x_i2_rob[2]),
        .upd_tr_taken(bru_act_tk), .upd_tr_target(bru_target),
        .upd_ff_valid(upd_ff_v), .upd_ff_idx(fpu_if_rob), .upd_ff_flags(fpu_ff),
        .upd_exc_valid(lsu_exc_v), .upd_exc_idx(lsu_exc_rob),
        .upd_exc_code(lsu_exc_cause), .upd_exc_tval(lsu_exc_tval),
        //   ★ 2B-4：store 提交门 = LSQ 的 CDQ 余量（不再是"排空口空闲"）——
        //     同拍多 store 提交组全部入队、逐拍顺序排空；`mem_req_ready_i` 仍作为排空口
        //     本身的握手（在 lsq_simple 内使用）。
        .mem_wr_ready(lsu_dr_room_w),
        .cmt_valid(cmt_raw), .cmt_payload(cmt_pay),
        .cmt_st_drain(cmt_st_drain), .cmt_st_ckpt(cmt_st_ckpt), .cmt_st_branch(cmt_st_branch),
        .trap_valid(trap_v_rob), .trap_pc(trap_pc_o), .trap_cause(trap_cause_o),
        .trap_tval(trap_tval_o),
        .squash_valid(squash_v_w), .squash_idx(squash_idx_w), .flush_all(flush_all_w),
        .trap_retire(trap_v_rob & trp_flush_v_i),
        .head_o(rob_head_w), .cnt_o(rob_cnt_w), .empty_o(), .head_done_o(), .head_exc_o(),
        .squash_age_o(squash_age_w),   // ★ C8：统一年龄（距头距离）输出
        .cmt_cnt_o(cnt_commit_o), .epoch_o(epoch_w)
    );

    //==========================================================================
    // 10. PRF（整数 15 读 6 写 / 浮点 8 读 2 写）
    //==========================================================================
    assign iprf_re = 16'hFFFF;
    assign iprf_ra[0*PW_I +: PW_I]  = w_ps1i(x_i2_uop[0]);
    assign iprf_ra[1*PW_I +: PW_I]  = w_ps2i(x_i2_uop[0]);
    assign iprf_ra[2*PW_I +: PW_I]  = w_ps1i(x_i2_uop[1]);
    assign iprf_ra[3*PW_I +: PW_I]  = w_ps2i(x_i2_uop[1]);
    assign iprf_ra[4*PW_I +: PW_I]  = w_ps1i(x_i2_uop[2]);
    assign iprf_ra[5*PW_I +: PW_I]  = w_ps2i(x_i2_uop[2]);
    assign iprf_ra[6*PW_I +: PW_I]  = w_ps1i(x_i2_uop[3]);
    assign iprf_ra[7*PW_I +: PW_I]  = w_ps2i(x_i2_uop[3]);
    assign iprf_ra[8*PW_I +: PW_I]  = w_ps1i(x_i2_uop[4]);
    assign iprf_ra[9*PW_I +: PW_I]  = w_ps2i(x_i2_uop[4]);
    assign iprf_ra[10*PW_I +: PW_I] = w_ps1i(x_i2_uop[5]);
    assign iprf_ra[11*PW_I +: PW_I] = cmt_narrow[0*`BACK2_NQ_W + `BACK2_NQ_PDI_L +: PW_I];
    assign iprf_ra[12*PW_I +: PW_I] = cmt_narrow[1*`BACK2_NQ_W + `BACK2_NQ_PDI_L +: PW_I];
    assign iprf_ra[13*PW_I +: PW_I] = cmt_narrow[2*`BACK2_NQ_W + `BACK2_NQ_PDI_L +: PW_I];
    assign iprf_ra[14*PW_I +: PW_I] = cmt_narrow[3*`BACK2_NQ_W + `BACK2_NQ_PDI_L +: PW_I];
    //   ★ PRF 写口判据 = "写回所属 ROB 项仍在 ROB 窗口内"（不能用 epoch，理由见 prf.v）
    //     `(idx - head) mod ROB_N < cnt`；比较零扩展到 cnt 的宽度以正确处理 cnt=ROB_N。
    assign iprf_we    = wbi_v & wbi_keep;
    assign iprf_wa    = wbi_tag;
    assign iprf_wd    = wbi_data;
    assign iprf_we_ep = { fpu_if_ep, lsu_wb_ep, mdu_if_ep, x_i2_ep[2], x_i2_ep[1], x_i2_ep[0] };

    prf #(.NW(6), .NRD(16), .NREG(`BACK2_PRF_I_N), .PDW(PW_I), .DW(32)) u_prf_i (
        .clk(clk), .rst_n(rst_n),
        .we(iprf_we), .waddr(iprf_wa), .wdata(iprf_wd), .wepoch(iprf_we_ep), .epoch(epoch_w),
        .wkeep(wbi_keep),
        .re(iprf_re), .raddr(iprf_ra), .rdata(iprf_rd)
    );

    assign fprf_re = 8'hFF;
    assign fprf_ra[0*PW_F +: PW_F] = w_ps1f(x_i2_uop[5]);
    assign fprf_ra[1*PW_F +: PW_F] = w_ps2f(x_i2_uop[5]);
    assign fprf_ra[2*PW_F +: PW_F] = w_ps3f(x_i2_uop[5]);
    assign fprf_ra[3*PW_F +: PW_F] = w_ps2f(x_i2_uop[4]);
    assign fprf_ra[4*PW_F +: PW_F] = cmt_narrow[0*`BACK2_NQ_W + `BACK2_NQ_PDF_L +: PW_F];
    assign fprf_ra[5*PW_F +: PW_F] = cmt_narrow[1*`BACK2_NQ_W + `BACK2_NQ_PDF_L +: PW_F];
    assign fprf_ra[6*PW_F +: PW_F] = cmt_narrow[2*`BACK2_NQ_W + `BACK2_NQ_PDF_L +: PW_F];
    assign fprf_ra[7*PW_F +: PW_F] = cmt_narrow[3*`BACK2_NQ_W + `BACK2_NQ_PDF_L +: PW_F];
    assign fprf_we    = { (fpu_wb_v & fpu_wb_f & ({1'b0,(fpu_if_rob[ROBW-1:0] - rob_head_w[ROBW-1:0])} < rob_cnt_w)),
                          (lsu_wb_v & lsu_wb_f & ({1'b0,(lsu_wb_rob[ROBW-1:0] - rob_head_w[ROBW-1:0])} < rob_cnt_w)) };
    assign fprf_wa    = { fpu_if_pdf, lsu_wb_pdf };
    //   ★★ 4c(3/3)：**FLD 不做 NaN-box** —— 8 B 装载写满 FLEN（ISA：只有 FLW 才 box）；
    //     ≤4 B 装载保持 NaN-box ⇒ 既有 flw/整数装载零回归。
    assign fprf_wd    = { fpu_wb_fdata,
                          (lsu_wb_f & lsu_wb_f64) ? {lsu_wb_data_hi, lsu_wb_data}
                                                  : {32'hFFFF_FFFF, lsu_wb_data} };
    assign fprf_we_ep = { fpu_if_ep, lsu_wb_ep };

    prf #(.NW(2), .NRD(8), .NREG(`BACK2_PRF_F_N), .PDW(PW_F), .DW(64)) u_prf_f (
        .clk(clk), .rst_n(rst_n),
        .we(fprf_we), .waddr(fprf_wa), .wdata(fprf_wd), .wepoch(fprf_we_ep), .epoch(epoch_w),
        .wkeep({(fpu_wb_v & fpu_wb_f) ? ({1'b0,(fpu_if_rob[ROBW-1:0] - rob_head_w[ROBW-1:0])} < rob_cnt_w) : 1'b0,
                (lsu_wb_v & lsu_wb_f) ? ({1'b0,(lsu_wb_rob[ROBW-1:0] - rob_head_w[ROBW-1:0])} < rob_cnt_w) : 1'b0}),
        .re(fprf_re), .raddr(fprf_ra), .rdata(fprf_rd)
    );

    //==========================================================================
    // 11. 重定向 / 异常（类别 A / 类别 C）
    //==========================================================================
    assign squash_v_w    = x_i2_v[2] & bru_mis;
    assign squash_idx_w  = x_i2_rob[2];
    assign restore_ck_v_w  = squash_v_w & w_ckv(x_i2_uop[2]);
    assign restore_ck_id_w = w_ckid(x_i2_uop[2]);
    assign restore_rob_v_w = squash_v_w & ~w_ckv(x_i2_uop[2]);
    assign restore_rob_idx_w = x_i2_rob[2];
    //   ★★ 2B-4 第 4a 段：**陷阱不再等于停机**。旧实现 `flush_all_w = trap_v_rob | trap_halt_q`
    //     且 `trap_halt_q` 一经陷阱永久置位 ⇒ 无法进入 mtvec 处理程序（§B4.4.1 B1）。
    //     新口径：陷阱拍由**顶层 trap FSM** 接管（记录 CSR + 重定向到 mtvec + 退役该项），
    //     后端只负责"冲刷 + 重定向"两件事；`trap_halt_q` 保留为**观测**（不再参与 flush）。
    assign flush_all_w = trap_v_rob | trp_flush_v_i;
    assign trp_halt_o  = trap_halt_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) trap_halt_q <= 1'b0;
        else if (trap_v_rob) trap_halt_q <= 1'b1;      // 仅作观测（历史行为痕迹）
    end

    //   外部重定向优先于内部分支误判重定向（陷阱/xRET 与分支同拍时以特权路径为准，
    //   见 AGENT.md §3.3"陷阱在副作用已落地指令之后取"与 2A `core_top`:1715 的 kill_young 口径）
    assign redirect_valid_o    = trp_redirect_v_i | squash_v_w;
    assign redirect_pc_o       = trp_redirect_v_i ? trp_redirect_pc_i :
                                 (squash_v_w ? bru_npc : 32'h0);
    assign redirect_use_ckpt_o = ~trp_redirect_v_i & squash_v_w & w_ckv(x_i2_uop[2]);
    assign redirect_ckpt_o     = w_ckid(x_i2_uop[2]);
    assign trap_valid_o        = trap_v_rob;
    assign trap_valid_o_pc     = trap_pc_o;

    //   ★★ 2B-4 第 4b-1c 段：4a 自造的"陷阱 CSR 事件组装"（`trp_is_*`/`trp_csr_*`）**已删净**——
    //     陷阱 CSR（mepc/mcause/mtval/mstatus）的落地全部改由顶层 `trap_ctrl.trap_we/
    //     trap_epc_i/trap_cause_i/trap_tval_i` → `csr_file` 承担（2A 口径，含委托判定）。
    //     本模块只保留：精确陷阱**观测输出**（trap_*_o）、xRET 提交点识别（xret_cmt_o/
    //     xret_kind_o）、以及"外部冲刷 + 重定向"骨架（trp_flush_v_i/trp_redirect_*_i）。

    //   ★ 提交点 xRET 识别：载荷 TVAL 字段 = **原始指令位**（decoder `tval_o = insn_i`，norvc）
    //     ⇒ 直接按编码判定 mret(0x3020_0073) / sret(0x1020_0073)，**不需要新增载荷位**。
    //   ★★ C4：原 lane-0 单点探针线 `cmt0_tval = cmt_pay[U_TVAL]` 已删 —— ① 它**全仓库 0 读**
    //     （4b-2a 之后改为逐 lane 扫描）；② 新载荷里 uop 的 TVAL 段已不存在（真值在
    //     `BACK2_RB_TVAL`，逐 lane 扫描用的就是 `p_pc/p_cls` + `nq` 预译码标志）。
    //   ★★ 4b-2a 缺陷修正（实测抓出）：xRET 与维护操作**可以在提交组的任意 lane**
    //     （4a/4b 原实现只看 lane 0 的 `cmt0_tval` ⇒ 只要它们不在 lane 0 就识别不到：
    //      实测 p11 的 `fence.i` 与 lane 0 的另一条指令同拍提交 ⇒ `maint_cmt` 恒 0）。
    //     修法：**逐 lane 扫描提交组**（由高到低 ⇒ 最老者胜），用该 lane 自己的
    //     载荷 TVAL 判定，并取出它自己的 PC 供重定向用。
    //   ★★ G4 修复（4b-3(2/2)，报告 §B4.34/§B4.35）：`xret_kind` 的**权威编码 = 2A 口径**
    //     （`core_top.v:1418/1679/1694/1709` 与 `tb_csr_file:68` 一致）：**01 = mret / 00 = sret**。
    //     旧式把 sret 编成 `2'd2` ✗ ⇒ 2A `priv_ctrl`（按 00=sret 解码）把真 sret 落进 default
    //     = **PRIV_U**：`sret` 恒回 U、SPP/SPIE 恢复与 SIE 还原全不做（实测 p15：委托 ecall 后
    //     sret 回 U ⇒ 同一条 ecall 以 cause 8 重入 M）。修法：sret → **2'd0**（与 2A 一致）。
    //     注：`2'd0` 同时是"非 xret"的默认值 —— 与 2A `e_xret_kind = de_mret ? 01 : 00` 同构，
    //     `kind` 只在 `xret_valid=1` 时被消费 ✓
    function [1:0] xret_kind_f; input [31:0] t;
        begin xret_kind_f = (t == 32'h3020_0073) ? 2'd1 :      // mret
                            (t == 32'h1020_0073) ? 2'd0 : 2'd0;  // sret（2A 口径）
        end
    endfunction
    //   ★★ G4③（报告 §B4.35）：xRET 的**识别**必须与 **kind 编码**分离 ——
    //     2A 口径下 `sret` 的 kind = `2'd0`（见 `xret_kind_f` 注），故"`kind != 0`"**不能**
    //     当识别判据：否则 `sret` 完全不被识别（既不重定向 ⇒ 顺延 PC+4 撞到非法指令，
    //     也不做特权级/CSR 更新）。2A 的同构做法是"`de_mret/de_sret` 识别 + `kind` 只作数据"
    //     （`core_top.v:1418` `e_xret_kind = de_mret ? 01 : 00`）⇒ 这里补一个纯识别函数。
    function is_xret_f; input [31:0] t;
        begin is_xret_f = (t == 32'h3020_0073) | (t == 32'h1020_0073); end
    endfunction

    function [2:0] maint_kind_f; input [31:0] t;
        begin
            maint_kind_f =
                (t[6:0] == 7'h0F) & (t[14:12] == 3'b001) & (t[19:15] == 5'd0) & (t[31:20] == 12'h000)
                    ? 3'd1 :                               // fence.i（0x0000_100F）
                (t[6:0] == 7'h73) & (t[14:12] == 3'b000) & (t[31:25] == 7'b0001_001)
                    ? 3'd2 :                               // sfence.vma（0x1200_0073 起）
                //   ★★ 2B-4 内存序缺口修复（p12 波形定位，**本段根因**）：
                //      `cbo.*` 的**真实编码**是 `funct3 = 010`（bits[14:12]），
                //      **动作码在 imm12[1:0] = bits[21:20]**（0=inval / 1=clean / 2=flush，
                //      bits[31:22] = 0）。工具链实证（`objdump -d` 三条 cbo）：
                //        cbo.inval(s0)=0x0004_200F  cbo.clean(s0)=0x0014_200F
                //        cbo.flush(s0)=0x0024_200F  —— 三者 funct3 **全为 010**。
                //      旧实现误按 `funct3 = 000/001/010` 区分动作 ⇒ 三条 cbo **全部**落进
                //      "flush" 分支（kind=5）⇒ 顶层对每次 cbo 同时拉 `inval_all`+`clean_all`
                //      ⇒ 2A L1D 走 inval 优先（`maint_clean_q = clean_all & ~inval_all`）
                //      ⇒ **整个 L1D 被"无写回失效"** ⇒ p12 的已提交 store 数据丢失
                //      （实测波形：三次 cbo 的维护脉冲全是 `inv=1 cln=1`，见报告 §B4.18）。
                (t[6:0] == 7'h0F) & (t[14:12] == 3'b010) & (t[19:15] != 5'd0) &
                (t[31:22] == 10'b0) & (t[21:20] == 2'b00)
                    ? 3'd3 :                               // cbo.inval（imm12=0）
                (t[6:0] == 7'h0F) & (t[14:12] == 3'b010) & (t[19:15] != 5'd0) &
                (t[31:22] == 10'b0) & (t[21:20] == 2'b01)
                    ? 3'd4 :                               // cbo.clean（imm12=1）
                (t[6:0] == 7'h0F) & (t[14:12] == 3'b010) & (t[19:15] != 5'd0) &
                (t[31:22] == 10'b0) & (t[21:20] == 2'b10)
                    ? 3'd5 : 3'd0;                         // cbo.flush（imm12=2）
        end
    endfunction
    reg  [3:0]  xret_lane_oh, maint_lane_oh;
    reg  [1:0]  xret_lane_idx, maint_lane_idx;
    reg  [1:0]  xret_kind_sel;
    reg  [2:0]  maint_kind_sel;
    reg  [31:0] maint_pc_sel;
    integer     mw2;
    //   ★ 组合环警告：本扫描**不得**用 `cmt_ok` 做门控 —— `cmt_ok` 里含
    //     `(xret_cmt_o | maint_cmt_o)` 的"上报口子"，而那两个信号正是本扫描的输出
    //     ⇒ 成环（实测：扫描看不到维护操作、重定向 PC 变 0）。
    //     只用 `cmt_raw & ~squash_v_w`（前缀提交链 + 无分支误判冲刷）即可：
    //     陷阱拍 `cmt_raw` 在异常槽及其后全 0 ⇒ 不会误识别更年轻的 xRET/维护操作。
    always @(*) begin
        xret_lane_oh = 4'h0;   xret_kind_sel  = 2'd0; xret_lane_idx  = 2'd0;
        maint_lane_oh = 4'h0;  maint_kind_sel = 3'd0; maint_pc_sel = 32'h0;
        maint_lane_idx = 2'd0;
        for (mw2 = COMMIT_W-1; mw2 >= 0; mw2 = mw2 - 1) begin
            if (cmt_raw[mw2] & ~squash_v_w) begin
                //   ★ ②：预解码标志改吃 `nq`（每 lane 5 bit）—— 不再读 4 lane 的 32 bit 指令字去译码。
                if (cmt_narrow[mw2*`BACK2_NQ_W + `BACK2_NQ_MRET] |
                    cmt_narrow[mw2*`BACK2_NQ_W + `BACK2_NQ_SRET]) begin
                    xret_lane_oh  = 4'h1 << mw2[1:0];
                    xret_lane_idx = mw2[1:0];
                    xret_kind_sel = cmt_narrow[mw2*`BACK2_NQ_W + `BACK2_NQ_MRET] ? 2'd1 : 2'd0;
                end
                if (cmt_narrow[mw2*`BACK2_NQ_W + `BACK2_NQ_MK_L +: 3] != 3'd0) begin
                    maint_lane_oh  = 4'h1 << mw2[1:0];
                    maint_lane_idx = mw2[1:0];
                    maint_kind_sel = cmt_narrow[mw2*`BACK2_NQ_W + `BACK2_NQ_MK_L +: 3];
                    maint_pc_sel   = p_pc(cmt_pay[mw2*RB_W +: RB_W]);
                end
            end
        end
    end
    assign xret_kind_o  = xret_kind_sel;
    assign maint_kind_o = maint_kind_sel;
    assign maint_pc_o   = maint_pc_sel;
    assign xret_cmt_o  = |xret_lane_oh;
    wire        maint_is_cbo_w = (maint_kind_sel == 3'd3) | (maint_kind_sel == 3'd4) |
                                 (maint_kind_sel == 3'd5);
    assign maint_cmt_o = |maint_lane_oh & (~maint_is_cbo_w | maint_rdy_i);
    //   ★★ 4b-2a 缺陷修正（实测抓出）：触发冲刷的维护/xRET 操作**通常与更年轻的指令同组提交**
    //     ——它们会被本次冲刷丢掉并**重新执行**，但 `cmt_ok` 的口子让整组都"上报提交"
    //     ⇒ 那些更年轻的槽在 PC 流里出现**两次**（实测 p11 连续两条 `fence.i`：
    //     第 17 条 `0x8001c03c` 重复出现）。
    //     修法：比该槽更年轻的 lane **不上报、不回写、不更新 ARAT、不进训练 FIFO**
    //     （它们在冲刷后重新执行；ROB 指针由 `flush_all` 分支接管，不受本掩码影响）。
    //   ★★ K1 根因（本段一步判定实验实测）：**移位量在 2 bit 上下文中回绕**。
    //     原式 `4'hF << (maint_lane_idx + 2'd1)`：`maint_lane_idx` 只有 2 bit（0..3），
    //     与 `2'd1` 相加仍是 2 bit ⇒ **lane 3 时 3+1 回绕成 0** ⇒ 掩码 = `4'hF`
    //     ⇒ **整组（含更老的 lane 与维护指令本身）全被 hold** ⇒ 含维护指令的那一块
    //     从提交流里整块消失（实测 `[k1m] kind=2 pc=0x…5c lane=3 cmt_raw=1111 cmt_raw_m=0000`，
    //     正是 K1 的"丢一个 4 宽块"症状）。lane 0/1/2 的移位 1/2/3 正确 ⇒ 只有"维护指令
    //     恰好落在第 4 个 lane"时才触发 ⇒ 与实测失败点（满 4 宽组）完全吻合。
    //     修法：把移位量扩到 3 bit（最大 4）⇒ lane 3 时移位 4 ⇒ 掩码 0（不 hold 任何 lane）。
    wire [2:0] maint_hold_sh = {1'b0, maint_lane_idx} + 3'd1;
    wire [2:0] xret_hold_sh  = {1'b0, xret_lane_idx}  + 3'd1;
    wire [3:0] cmt_hold_w = (|maint_lane_oh) ? (4'hF << maint_hold_sh) :
                            (|xret_lane_oh)  ? (4'hF << xret_hold_sh)  : 4'h0;
    wire [3:0] cmt_raw_m  = cmt_raw & ~cmt_hold_w;

    //==========================================================================
    // 12. 提交训练 / 检查点释放 / RAS（前端衔接）
    //==========================================================================
    // ---- 12.1 训练 FIFO（深度 16；提交侧 ≤4/拍入队，前端 1 条/拍出队）----
    //   ★ 2B-5 C7（面积杠杆）：深度 32→16（107 bit × 16 项，减半）。训练是 **best-effort**：
    //     `trq_full` 只 gate 入队（丢弃本拍训练条目），**不反压提交**——它不参与
    //     `cmt_ok`/派发门控（消费方只有本段训练 FIFO 入队的两处 `if`）⇒ 深度减半只降低
    //     "在飞训练条数上限"，不改训练语义/预测器接口/4 宽提交。
    //   ★ 位宽口径（按原设计"指针 = 2×深度"成比例收窄 ⇒ 行为同型、不改训练语义）：
    //       原：TRQ_D=32 ⇒ 指针 6 bit（mod 64）、cnt 7 bit（0..32）
    //       本段：TRQ_D=16 ⇒ 指针 **5 bit**（mod 32）、cnt **5 bit**（0..16；满判据保持原式
    //             `cnt > TRQ_D-4` ⇒ 13 项起判满，单拍最多 +4 ⇒ 12+4=16 恰在界内，不溢出）
    //   ★★ EXP-R3a（D1b 修复）：原设计指针宽度 > log2(深度) ⇒ 指针 ≥ 深度 时 `trq[...]`
    //     下标越界（iverilog 语义 = 读回 x、写被丢弃）。**索引改为低 4 bit**（`trq_w[3:0]` /
    //     `trq_r[3:0]`，即真·mod 16 环形缓冲）——5 bit 指针寄存器保留（只作"已写条数"的
    //     无歧义计数，便于 `cnt == (trq_w−trq_r) mod 32` 自检），深度 16 是 C7 已定口径。
    //   ★★ EXP-R3a（D1 修复）：`trq_cnt` 由**同块两次赋值**（后写覆盖前写）改为**单一赋值**
    //     `cnt − deq_n + enq_n`，见 §13 时序块。原写法在"出队 + 派发/提交"同拍恒把那次 −1
    //     抹掉（`trq_acc==0` 时 `+0` 覆盖）⇒ cnt 长期虚高不归零 ⇒ `train_valid_o` 恒 1 ⇒
    //     `trq_r` 空转跑飞（EXP-R 实测出队 39251 vs 入队 4359）。
    //   ⚠ 遗留（EXP-R3a 登记的 `trq_acc` 2 bit 回绕）——**本段（EXP-R3b）已随结构重构消除**：
    //     新结构没有 `trq_acc`，入队条数不再由累加器计数（4 lane 全中时 acc 回绕为 0 的老坑
    //     自然消失），见下。
    //
    //==========================================================================
    //   ★★ EXP-R3b（P0 面积杠杆）：结构重构为「4 槽提交暂存 + 1W/1R 16 深 FIFO」
    //==========================================================================
    //   动机：旧结构 = 「4 个**任意**写口 × 107 bit × 16 项」——每个 FIFO 项都要一套
    //   4:1 数据 mux ＋ 四路写地址译码，是"多写口 mux"大户（历史定位 ~9.8k LUT）。
    //
    //        commit 4-wide（lane 0..3 = 程序序）
    //             ↓   槽 i ← lane i（**单源写 ⇒ 数据口零 mux**）
    //        4 槽 staging（stg[0:3] / stg_v[0:3]）
    //             ↓   每拍排空 1 条（取**最低有效槽**）
    //        1W/1R FIFO（深 16；写口 = 单一 107 bit 数据总线 ＋ 4→16 写使能译码）
    //             ↓   1 条/拍
    //        BPU training
    //
    //   面积机理：FIFO 每项不再需要数据 mux（写数据是**总线** `trq_wdata`，各槽只多一条
    //   "写指针相等"的写使能 ⇒ 落成带 CE 的触发器，几乎零 LUT）；4:1 数据选择只剩
    //   staging→FIFO 的**一处**。
    //   ★ 次序正确性（不靠"恰好顺序对"）：staging 槽号 = lane 号 = 程序序；排空取最低有效槽。
    //     新 lane i 仅当"排在**本拍排空后**仍挂起的最高槽之后"才允许写入（`stg_mask_hi`）——
    //     排空自低向高 ⇒ 槽 i 一旦写入就必然晚于所有挂起项进 FIFO ⇒ **不重排**。被拒的新
    //     lane 就地处丢弃（best-effort，与旧 `trq_full` 丢弃同契约，不反压提交）。
    //   ★ 容量：staging 4 ＋ FIFO 16 ⇒ 在飞 ≤20（旧口径 `cnt>12` 起丢弃）；丢弃率不升反降。
    //   ★ `disp_fire_w` 从入队条件中删除：旧式 `(disp_fire_w | cmt_ok) & ~trq_full` 中写数据/
    //     写使能全部来自提交 lane（`trq_ok` 已含 `cmt_ok`）⇒ `disp_fire_w` 分支在旧码里即
    //     **空转**（acc=0、无 lane 写、指针 +0）；本段按真源只保留提交驱动。
    localparam integer TRQ_D  = 16;          // 单写口 FIFO 深度（沿用 C7 口径）
    localparam integer TRQ_SD = 4;           // staging 槽数（= COMMIT_W=4，4 宽提交是结构前提）
    localparam integer TRQW   = 107;         // 训练条目位宽（与旧 FIFO 逐位同布局）

    // ---- 1W/1R FIFO（mod-16 环形，**单写口**）----
    reg  [TRQW-1:0] trq [0:TRQ_D-1];
    reg  [3:0]      trq_w, trq_r;            // ★ 4 bit（真 mod 16；旧 5 bit 指针已废）
    reg  [4:0]      trq_cnt;                 // 0..16
    wire            trq_pop  = train_valid_o;                          // FIFO 出队 = training 出队
    wire            trq_room = ((trq_cnt - {4'b0, trq_pop}) < 5'd16);  // 本拍可写 1 条

    // ---- 4 槽 staging（槽 i ← lane i：单源写 ⇒ 数据口零 mux）----
    reg  [TRQW-1:0]  stg [0:TRQ_SD-1];
    reg  [TRQ_SD-1:0] stg_v;                 // 各槽有效位
    //   提交侧训练申请（唯一真源）：本拍哪些 lane 是"可上报的控制转移"
    wire [3:0]      trq_ok = cmt_st_branch & {4{cmt_ok}} & ~cmt_hold_w;

    //   排空槽 = 最低有效槽；`trq_room` 保证不覆盖 FIFO 中未出队项
    wire [1:0]      stg_drain_slot = stg_v[0] ? 2'd0 : stg_v[1] ? 2'd1 :
                                     stg_v[2] ? 2'd2 : 2'd3;
    wire            stg_drain_v    = (|stg_v) & trq_room;
    wire [3:0]      stg_v_after    = stg_v & ~(stg_drain_v ? (4'd1 << stg_drain_slot) : 4'd0);
    wire            stg_any_after  = |stg_v_after;
    wire [1:0]      stg_hi_after   = stg_v_after[3] ? 2'd3 : stg_v_after[2] ? 2'd2 :
                                     stg_v_after[1] ? 2'd1 : 2'd0;
    //   "排在所有挂起项之后"的 lane 掩码（lane 号 = 槽号）：hi_after 的下一槽起全 1。
    //   `hi_after+1 == 4` 时 `4'd1<<4` 截断为 0 ⇒ `0-1=4'hF` ⇒ 取反全 0（lane 3 也拒）✓
    wire [3:0]      stg_mask_hi    = stg_any_after ? ~((4'd1 << (stg_hi_after + 2'd1)) - 4'd1)
                                                   : 4'hF;
    wire [3:0]      stg_acc        = trq_ok & stg_mask_hi;

    //   staging → FIFO 的**唯一** 4:1 数据选择（旧结构是每个 FIFO 项一套）
    wire [TRQW-1:0] trq_wdata      = stg[stg_drain_slot];

    wire [3:0]  tcp_cond, tcp_tk, tcp_ind, tcp_call, tcp_ret;
    wire [31:0] tcp_tgt [0:3];
    wire [3:0]  tcp_ptk, tcp_psg, tcp_pgd, tcp_pld, tcp_bh, tcp_bw;
    wire [31:0] tcp_ptg [0:3];
    wire [31:0] tcp_pc  [0:3];
    //   ★ EXP-R3b：每 lane 打成**一条 107 bit 训练条目**（与旧 FIFO 项逐位同布局），
    //     staging 槽 i 直接吞 `tcp_data[i]`（单源写）。
    wire [TRQW-1:0] tcp_data [0:3];
    genvar tc;
    generate
    for (tc = 0; tc < COMMIT_W; tc = tc + 1) begin : g_trf
        wire [RB_W-1:0] pp = cmt_pay[tc*RB_W +: RB_W];
        assign tcp_cond[tc] = t_cond(p_cls(pp));
        //   ★ ③：`trtaken` 改吃 `nq`（每 lane 1 bit）；`trtgt` 与预测元数据保留 4 lane
        //     （一个提交组可含**最多 4 条分支** ⇒ 单 lane 动态读口不能覆盖，见报告 §B4.48）
        assign tcp_tk[tc]   = cmt_narrow[tc*`BACK2_NQ_W + `BACK2_NQ_TRT +: 1];
        assign tcp_ind[tc]  = t_ind(p_cls(pp));
        assign tcp_call[tc] = t_call(p_cls(pp));
        assign tcp_ret[tc]  = t_ret(p_cls(pp));
        assign tcp_tgt[tc]  = p_trtgt(pp);
        //   ★★ C4：预测元数据改用**载荷布局**宏（`BACK2_RB_*`）；字段仍在载荷里，语义不变。
        assign tcp_ptk[tc]  = pp[`BACK2_RB_PRED_MSB];
        assign tcp_psg[tc]  = pp[`BACK2_RB_PRED_MSB-1];
        assign tcp_pgd[tc]  = pp[`BACK2_RB_PRED_MSB-2];
        assign tcp_pld[tc]  = pp[`BACK2_RB_PRED_MSB-3];
        assign tcp_bh[tc]   = pp[`BACK2_RB_BTB_MSB];
        assign tcp_bw[tc]   = pp[`BACK2_RB_BTB_LSB];
        assign tcp_ptg[tc]  = pp[`BACK2_RB_PREDTGT_MSB:`BACK2_RB_PREDTGT_LSB];
        assign tcp_pc[tc]   = p_pc(pp);
        //   ★ EXP-R3b：位拼接顺序 = 旧 FIFO 写口顺序（MSB→LSB），逐位等价
        assign tcp_data[tc] = {
            tcp_cond[tc], tcp_tk[tc], tcp_ind[tc], tcp_call[tc], tcp_ret[tc], tcp_tgt[tc],
            tcp_ptk[tc], tcp_psg[tc], tcp_pgd[tc], tcp_pld[tc], tcp_bh[tc], tcp_bw[tc],
            tcp_ptg[tc], tcp_pc[tc]
        };
    end
    endgenerate

    //   ★ EXP-R3b：staging 槽 i 的单源写（`stg_acc[i]` 为写使能 ⇒ 带 CE 触发器，数据口零 mux）。
    //     复位把数据槽清零（与旧 `trq[]` 全清零同口径，避免 iverilog 下未初始化 x 进入
    //     `trq_wdata` 组合路径）。
    genvar sg;
    generate
    for (sg = 0; sg < TRQ_SD; sg = sg + 1) begin : g_stg
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) stg[sg] <= {TRQW{1'b0}};
            else if (stg_acc[sg]) stg[sg] <= tcp_data[sg];
        end
    end
    endgenerate

    assign train_valid_o = (trq_cnt != 0) & train_ready_i;
    //   ★ EXP-R3b：读索引 = 4 bit 读指针（真 mod 16）
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
            trq_w <= 4'd0; trq_r <= 4'd0; trq_cnt <= 5'd0;   // ★ EXP-R3b：4 bit 环形指针（mod 16）
            stg_v <= 4'd0;                                   // ★ EXP-R3b：staging 槽全空（数据槽在 g_stg 内复位）
            mdu_if_rob <= 7'd0; mdu_if_ep <= {EW{1'b0}}; mdu_if_di <= 1'b0;
            mdu_if_pdi <= {PW_I{1'b0}};
            fpu_if_rob <= 7'd0; fpu_if_ep <= {EW{1'b0}}; fpu_if_di <= 1'b0;
            fpu_if_df <= 1'b0; fpu_if_pdi <= {PW_I{1'b0}}; fpu_if_pdf <= {PW_F{1'b0}};
            for (si2 = 0; si2 < CKPT_N; si2 = si2 + 1) ck_rob_q[si2] <= {ROBW{1'b0}};
            //   ★★ C1：发射读回数据的 bank 归属（E1 拍做 4:1 路由用）复位为"无归属"
            for (si2 = 0; si2 < 4; si2 = si2 + 1) iwm_own_q[si2] <= 3'd6;
            for (si2 = 0; si2 < ROB_N; si2 = si2 + 1) stq_of_rob[si2] <= {`BACK2_STQ_IDX_W{1'b0}};
            for (si2 = 0; si2 < ROB_N; si2 = si2 + 1) lq_of_rob[si2]  <= {`BACK2_LQ_IDX_W{1'b0}};
            for (si2 = 0; si2 < TRQ_D; si2 = si2 + 1) trq[si2] <= {TRQW{1'b0}};
        end else begin
            busy_i_q <= busy_i_nx;
            busy_f_q <= busy_f_nx;
            //   ★★ C1：发射读回数据的 bank 归属打拍（与 §5.5 的 `u_iwmem` 同步读同沿）
            for (si2 = 0; si2 < 4; si2 = si2 + 1) iwm_own_q[si2] <= iwm_own_nx[si2];

            // ---- MDU/FPU 在途登记（★ 只清"被本次冲刷杀掉的"在飞项，见 mdu_kill/fpu_kill）
            if (mdu_kill) begin
                mdu_if_v <= 1'b0;
            end else begin
                if (iq_iss_v[3] & ~iq_iss_dead[3]) begin
                    mdu_if_v   <= 1'b1;
                    mdu_if_rob <= iq_iss_rob[3];
                    mdu_if_ep  <= iq_iss_ep[3];
                end else if (mdu_done) mdu_if_v <= 1'b0;
            end
            if (fpu_kill) begin
                fpu_if_v <= 1'b0;
            end else begin
                if (iq_iss_v[5] & ~iq_iss_dead[5]) begin
                    fpu_if_v   <= 1'b1;
                    fpu_if_rob <= iq_iss_rob[5];
                    fpu_if_ep  <= iq_iss_ep[5];
                end else if (fpu_done) fpu_if_v <= 1'b0;
            end
            //   ★★ C1：`di/pdi/df/pdf` 改在 **E1 拍**（= 宽载荷 `x_i2_uop` 到手的那一拍）登记 ——
            //     比原"发射拍"晚 1 拍；这几个字段只在**写回拍**（`mdu_done`/`fpu_done`，至少再晚
            //     1 拍）被消费（`wbi_tag`/`wbi_data`/`fprf_wa`/`busy_f_nx`），故语义等价。
            //     注意 `rob/ep` 仍与"在途标志"同拍登记：`mdu_kill`/`fpu_kill` 的年龄判据
            //     在登记后的**下一拍**就要用到它们，不能晚。
            if (x_i2_v[3]) begin
                mdu_if_di  <= w_di(x_i2_uop[3]);
                mdu_if_pdi <= w_pdi(x_i2_uop[3]);
            end
            if (x_i2_v[5]) begin
                fpu_if_di  <= w_di(x_i2_uop[5]);
                fpu_if_df  <= w_df(x_i2_uop[5]);
                fpu_if_pdi <= w_pdi(x_i2_uop[5]);
                fpu_if_pdf <= w_pdf(x_i2_uop[5]);
            end

            // ---- STQ 归属表（store 的 ROB 项 → STQ 索引）----
            if (disp_fire_w) begin
                for (si2 = 0; si2 < DISP_W; si2 = si2 + 1) begin
                    if (st_alloc_v[si2])
                        stq_of_rob[rb_ix_w[si2]] <= st_alloc_idx[si2*`BACK2_STQ_IDX_W +: `BACK2_STQ_IDX_W];
                    if (ld_alloc_v[si2])
                        lq_of_rob[rb_ix_w[si2]]  <= ld_alloc_idx[si2*LDW +: LDW];
                end
            end

            // ---- 检查点表（登记 / 释放）----
            if (disp_fire_w && snap_v_r) begin
                ck_busy_q[snap_id_r] <= 1'b1;
                ck_rob_q[snap_id_r]  <= rb_ix_w[snap_lane_r];
            end
            if (squash_v_w) begin
                for (si2 = 0; si2 < CKPT_N; si2 = si2 + 1) begin
                    if (ck_busy_q[si2] &&
                        ((ck_rob_q[si2] - rob_head_w[ROBW-1:0]) >=
                         squash_age_w)) begin
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

            // ---- 训练 FIFO（EXP-R3b：单写口 + 4 槽 staging）----
            //   ① FIFO：出队 / 单写口入队 / 计数（**单一赋值**，同拍出队+入队都计入）
            trq_cnt <= trq_cnt - {4'b0, trq_pop} + {4'b0, stg_drain_v};
            if (trq_pop) trq_r <= trq_r + 4'd1;
            if (stg_drain_v) begin
                trq[trq_w] <= trq_wdata;            // 写数据 = staging 头（**FIFO 项无数据 mux**）
                trq_w      <= trq_w + 4'd1;
            end
            //   ② staging 有效位：被接收的置 1；其余按"排空后仍挂起"保持（两者互斥）
            stg_v <= stg_acc | stg_v_after;

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
