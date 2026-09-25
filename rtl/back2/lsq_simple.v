//==============================================================================
// rtl/back2/lsq_simple.v —— LSQ：**SQ 32 + LQ 32**（写回可乱序 / 提交点释放）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-3 第 6 段：SQ 16→32、LQ 4→32、真乱序边界）
// 规格  : docs/design/03-out-of-order.md §6（LSQ 结构与访存序、load→store 转发、提交时
//         释放）；2B-3 两步扩容的落地与实测见 sim/unit/back2_report.md §B3.7。
//
// 【本段口径（最终状态）】
//   · **SQ 32 / LQ 32**：容量与位宽唯一真源 = `back2_params.vh`（`BACK2_STQ_N` /
//     `BACK2_LQ_N`）；STQ 索引同时在 ROB 载荷 [410:406]（4→5 bit，见该文件"位域核对"注）。
//   · **发射**：LSU 单发射口，IQ-LSU 最老就绪优先；`INORD_LOAD`（队列级）与
//     **精确 STQ 闸门**（§2.1）并联：更老 store **未定址** ⇒ 本 load 不可发射；
//     更老 store 均已定址 ⇒ 放行（重叠字节由转发/合并兜住）。
//   · **LQ**：load 在 **D3 派发期**分配槽位（程序序；2B-4 第二步），响应按 `ld_tag` 标签
//     **乱序写回**（`ld_dn` 标记数据已齐），槽位本身**在提交点释放**（§4.4b：
//     `(ld_rob - rob_head) & 7'h7F < cmt_n`，冲刷/陷阱拍 `cmt_n=0`）。
//   · **字节级 load→store 转发**（§6.2）：扫描**更老且地址已确认**的 store（32 候选 ×
//     4 字节道），取**最年轻**的更老匹配者；全部字节命中 ⇒ 不访问存储、次拍直接写回。
//   · **store 提交排空**：地址/数据在 E1 生成后驻留 STQ，**只在 ROB 提交该 store 时**
//     才写入存储（§6.2 / §9：异常回滚不可能双重写）；排空与 load 请求共用单请求口，
//     且**排空拍不发 load 请求**，保证 load 读到的存储内容严格晚于它必须看到的 store 写。
//   · **不做**（留后续段）：未对齐拆笔、PMP/MMU 检查落地、AMO/LR-SC、cbo.*、fence 屏障项、
//     64 bit（fld/fsd）访存；**D3 期 LQ 分配**（放开 load 越过"更老未就绪 load"的前提，
//     见 §B3.7.3③ 的死锁分析）。本模块只做 ≤4 B 的对齐访存。
//   · **地址唯一来源**：STQ/SQ 的地址字段只写一次、只写物理地址（Bare 口径 VA=PA；
//     Sv32 接线留 2B-4）；`stq_rob`（年龄）同样**唯一写点** = 分配期（§4.2）。
//
// 风格  : 组合逻辑用 `assign` + 条件表达式 + 纯函数（`pri_enc`/`ext_load`）；
//         always 块只承载时序元件与阵列更新（STQ/LQ 表、指针、计数器）。
//         ★ 不使用读存储器的 function；★ 归约一律连续赋值（B3.5 的 x 陷阱教训）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module lsq_simple #(
    parameter integer STQ_N    = `BACK2_STQ_N,
    parameter integer STQ_IW   = `BACK2_STQ_IDX_W,
    parameter integer OUT_N    = `BACK2_MEM_OUT_N,   // LQ 深度（32）
    parameter integer LQ_IW    = `BACK2_LQ_IDX_W,    // LQ 下标宽度（5）
    parameter integer TAG_W    = `BACK2_MEM_TAG_W,
    parameter integer ROB_IDX_W= `BACK2_ROB_IDX_W,
    parameter integer PDW_I    = `BACK2_PREG_I_W,
    parameter integer PDW_F    = `BACK2_PREG_F_W,
    parameter integer W        = `BACK2_DISP_W,
    parameter integer CDQ_N    = `BACK2_CDQ_N,       // 提交排空队列深度（≥2×W）
    parameter integer CDQ_PW   = 3,                  // CDQ 指针位宽（log2(CDQ_N)）
    parameter integer DBG = 0              // 1 = 每拍打印 load/store 槽状态（诊断）
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  flush_all,            // trap：全清
    input  wire                  squash,               // 分支误判
    input  wire [ROB_IDX_W-1:0]  squash_idx,
    input  wire [ROB_IDX_W-1:0]  rob_head,

    // ---- D3 派发：为 store 分配 STQ 项（≤4/拍，程序序）----
    input  wire [W-1:0]          alloc_valid,
    input  wire [W*ROB_IDX_W-1:0] alloc_rob,           // ★ 2B-3：随带各 lane 的 ROB 索引
    output wire                  alloc_ok,
    output wire [W*STQ_IW-1:0]   alloc_idx,

    // ---- D3 派发：为 **load** 分配 LQ 项（≤4/拍，程序序；★ 2B-4 第二步）----
    //   槽位在**派发期**确定（=程序序），E1 只是"填地址/数据/转发信息"；
    //   释放点仍在**提交**（§4.4b 的窗口算术，用派发期写入的 `ld_rob`）。
    //   ⇒ load 的槽位序不再依赖发射/执行顺序：年轻 load 不可能抢走更老 load 需要的槽
    //     （这正是 2B-3 里"槽在 E1 分配"必须靠 iq.v 的 INORD_LOAD 防死锁的原因）。
    input  wire [W-1:0]          lalloc_valid,
    input  wire [W*ROB_IDX_W-1:0] lalloc_rob,
    output wire                  lalloc_ok,
    output wire [W*LQ_IW-1:0]    lalloc_idx,

    // ---- E1：LSU 执行（单发射；地址由 backend_top 的 AGU 算好）----
    input  wire                  exe_valid,
    input  wire                  exe_is_store,
    input  wire                  exe_is_fp,
    input  wire [ROB_IDX_W-1:0]  exe_rob,
    input  wire [`BACK2_EPOCH_W-1:0] exe_epoch,
    input  wire [31:0]           exe_addr,
    input  wire [31:0]           exe_wdata,
    input  wire [2:0]            exe_size,
    input  wire                  exe_unsign,
    input  wire                  exe_dst_i,
    input  wire                  exe_dst_f,
    input  wire [PDW_I-1:0]      exe_pdest_i,
    input  wire [PDW_F-1:0]      exe_pdest_f,
    input  wire [STQ_IW-1:0]     exe_stq_idx,
    input  wire [LQ_IW-1:0]      exe_lq_idx,           // ★ 2B-4：本 load 在派发期分到的 LQ 槽

    // ---- 发射前检查（接 IQ 的 iss_ready）----
    input  wire [ROB_IDX_W-1:0]  iss_rob,              // ★ 2B-3：候选（i4_sel）的 ROB 索引
    output wire                  iss_ok,               // 有空余 LQ 槽 且 无更老未定址 store
    //   ★★ 2B-4 内存序缺口修复（修法 1）：**CDQ 空**（已提交 store 全部排空）——
    //     顶层用它把"整机冲刷"推迟到排空完成之后（见 core_top_2b §6b 的 `maint_wait_cdq`）
    output wire                  dr_empty_o,

    // ---- 提交排空入队（ROB 提交组内的**所有** store，≤W/拍、程序序）----
    input  wire [W-1:0]          dr_valid,
    input  wire [W*STQ_IW-1:0]   dr_idx,
    //   提交许可（回送 rob.v 的 `mem_wr_ready`）：CDQ 余量够放**一整组** store 才许可提交。
    //   ★ 不再与"排空口当拍空闲"耦合：提交与排空解耦 ⇒ 同拍多 store 可全部入队、
    //     由排空口逐拍顺序发出（单端口、单笔在途纪律不变）。
    output wire                  dr_room_ok,

    // ---- 提交点释放（LQ 项；★ 2B-3 第 6 段第二步：E1 入队、提交点释放）----
    input  wire [2:0]            cmt_n,                // 本拍提交条数（外部已按 cmt_ok 门控）

    // ---- 访存请求口（单请求；load 带标签）----
    output wire                  mem_req_valid,
    output wire                  mem_req_wen,
    output wire [31:0]           mem_req_addr,
    output wire [31:0]           mem_req_wdata,
    output wire [3:0]            mem_req_wstrb,
    output wire [TAG_W-1:0]      mem_req_tag,
    input  wire                  mem_req_ready,
    input  wire                  mem_rsp_valid,
    input  wire [31:0]           mem_rsp_rdata,
    input  wire [TAG_W-1:0]      mem_rsp_tag,
    //   ★★ 2B-4 第 4b-2b 段：**带错响应**（数据侧翻译/页错误）。顶层适配器在
    //     TLB 权限错 / PTW 故障时以"正常响应 + err=1"的形式回一笔（tag 仍是该 load 的
    //     标签）⇒ 本模块把该 load 标成"已完成但带异常"、**不写回数据**，并把精确异常
    //     （cause 13 = load page fault、tval = 该 load 的 VA）上报给 ROB 的 `upd_exc`。
    input  wire                  mem_rsp_err,

    // ---- 数据侧精确异常上报（→ backend_top → ROB `upd_exc_*`）----
    output wire                  exc_valid_o,
    output wire [ROB_IDX_W-1:0]  exc_rob_o,
    output wire [3:0]            exc_cause_o,
    output wire [31:0]           exc_tval_o,

    // ---- 写回（load 结果）----
    output wire                  wb_valid,
    output wire [ROB_IDX_W-1:0]  wb_rob,
    output wire [`BACK2_EPOCH_W-1:0] wb_epoch,
    output wire                  wb_dst_i,
    output wire                  wb_dst_f,
    output wire [PDW_I-1:0]      wb_pdest_i,
    output wire [PDW_F-1:0]      wb_pdest_f,
    output wire [31:0]           wb_data,

    // ---- store E1 完成（地址+数据就绪 ⇒ ROB done）----
    output wire                  st_done_valid,
    output wire [ROB_IDX_W-1:0]  st_done_rob,
    output wire [`BACK2_EPOCH_W-1:0] st_done_epoch,

    // ---- ★★ (b) store 地址翻译口（PA 化；§B4.24.9 第 2/3 条 + 上下文口径修正）----
    //   动机（根因链 §B4.23/§B4.24 + 本轮实测修正）：旧形态下**已提交 store 的排空**才在
    //   适配器里翻译 ⇒ 一次遍历同时受"维护冲刷"和"翻译上下文取错时刻"两个因素影响
    //   （实测 p13：PTE 更新 store 在排空/预翻译时刻按 **MPRV=1 + MPP=U** 翻译 U=0 的页
    //   ⇒ 页错误 ⇒ 已提交写静默丢失）。改为**执行期/提交期定址**、PA 随 STQ/CDQ 携带
    //   ⇒ 排空口恒用 PA、**排空不再翻译**。
    //   · 方向 ①（本模块 → 顶层适配器）：请求 + VA + 槽号 + **翻译上下文**
    //   · 方向 ②（顶层适配器 → 本模块）：接受拍 / 完成拍 / PA / 故障
    //   · `st_xlate_ctx` = {有效特权级[1:0], SUM, MXR}：**必须随请求携带**——
    //     适配器/PTW 若用"当下"的 CSR 值做 TLB 查询与遍历，结果与该项应得的翻译无关。
    input  wire                  st_xlate_en,        // 本拍执行的 store **需要**翻译（1）
    input  wire [3:0]            st_xlate_ctx,       // 本拍翻译上下文 {priv,SUM,MXR}
    output wire                  st_xlate_valid,     // 翻译请求（**保持**到 done）
    output wire [31:0]           st_xlate_va,        // 该 store 的**虚拟**地址
    output wire [STQ_IW-1:0]     st_xlate_idx,       // 目标下标（STQ 槽 **或** CDQ 项，见 §3.4）
    output wire [3:0]            st_xlate_ctx_o,     // 该请求的翻译上下文（保持到 done）
    input  wire                  st_xlate_ready,     // 适配器**接受**拍（锁存在途项）
    input  wire                  st_xlate_done,      // 完成脉冲（1 拍，PA/故障有效）
    input  wire [31:0]           st_xlate_pa,        // 译后**物理**地址
    input  wire                  st_xlate_fault,     // 1 = 翻译故障（提交拍口径 ⇒ 作废不写）

    // ---- 观测 ----
    output wire [7:0]            stq_cnt_o,
    output wire [31:0]           cnt_load_o,
    output wire [31:0]           cnt_store_o,
    output wire [31:0]           cnt_fwd_o,
    output wire [31:0]           cnt_stq_stall_o
);

    //==========================================================================
    // 0. STQ
    //==========================================================================
    reg                  stq_v   [0:STQ_N-1];
    reg                  stq_av  [0:STQ_N-1];        // 地址已生成（只写一次）
    reg                  stq_dv  [0:STQ_N-1];
    reg  [31:0]          stq_a   [0:STQ_N-1];        // ★ **虚拟地址**（E1 的 AGU 结果；
                                                     //   转发比较 / 翻译请求的 VA 来源）
    reg  [31:0]          stq_d   [0:STQ_N-1];        // 已对位到字内字节道
    reg  [3:0]           stq_msk [0:STQ_N-1];
    reg  [ROB_IDX_W-1:0] stq_rob [0:STQ_N-1];
    reg                  stq_ret [0:STQ_N-1];
    reg  [STQ_IW-1:0]    stq_head_q, stq_tail_q;
    //   ★★ (b) PA 化（§B4.24.9 第 1 条）：`stq_a` **必须保持 VA** —— store→load 转发按
    //     `stq_a[si] == exe_addr` 比较，而 load 侧拿到的是 **VA** ⇒ 物理地址走**独立字段**：
    //       · `stq_pa`：**E1 预翻译**结果（Bare/无需翻译时 = `stq_a`，即 VA=PA）
    //       · `stq_pv`：该预翻译结果有效（E1 判定"无需翻译"⇒ 立即 1；需翻译 ⇒ 等 done）
    //       · `stq_ctx`：该次预翻译使用的**上下文** {priv,SUM,MXR}（提交拍据此判可否沿用）
    //     注：预翻译只是**加速**；**权威判定在提交拍**（见 §3.4 头注），故预翻译失败
    //     （`st_xlate_fault`）**不置任何"坏"位**、只保持 `stq_pv=0`（未定）。
    reg  [31:0]          stq_pa  [0:STQ_N-1];
    reg                  stq_pv  [0:STQ_N-1];
    reg  [3:0]           stq_ctx [0:STQ_N-1];
    //       · `stq_bad`：**提交拍口径**的翻译故障（页错误）—— 该 store 不写、以 cause 15
    //         精确上报（`upd_exc`），并作为"不得提交"的解阻塞位（否则提交门会死等 PA）。
    //         只有 **STQ 源**（= 执行期，见 §3.4/§4.5c）的故障才置位；CDQ 源故障另走 fail-safe。
    reg                  stq_bad [0:STQ_N-1];

    //==========================================================================
    // 0b. ★★ (b2) 新增输入的**悬空净化** + **提交窗"翻译定妥"门**
    //--------------------------------------------------------------------------
    //  · 净化（与 `mem_rsp_err` 同一教训）：本模块被多处**直接驱动**的 TB 例化
    //    （`tb_back2_lsq_fwd`；`tb_back2_lockstep` 经 `backend_top`）不接新口 ⇒ 输入为 z
    //    ⇒ `~st_xlate_en` / `ready` / `done` 参与的条件成 x ⇒ 排空门变 x ⇒ 整核挂死。
    //    口径：只有明确的 1 才算"需要翻译/接受/完成/故障"；z/x/0 一律按 0
    //    （等价于 Bare：PA=VA、无翻译请求）⇒ 与新增端口前逐拍一致。
    //  · **提交门**（store 页错误精确化的必要条件）：ROB 提交窗口（年龄 < W）内凡
    //    "**未按当前上下文定妥**"的 store，一律不得提交 ——
    //      ① 未定妥 ⇒ 等翻译回来（CDQ 余量门 `dr_room_ok` 回送 rob.v 的 `mem_wr_ready`）；
    //      ② 判坏（`stq_bad`）⇒ 解阻塞，让该 ROB 项走到**精确陷阱**（`upd_exc` 已置 EXC ⇒
    //         `slot_ok` 含 `~slot_exc` ⇒ 该 store 不提交、在头部抛 cause 15）；
    //      ③ "按当前上下文"= `~st_xlate_en | (stq_pv & stq_ctx == 当前 ctx)` —— 上下文变了
    //         （更老的 CSR 写已提交）⇒ 判为未定妥 ⇒ 由 §3.4 的 STQ 扫描**按新上下文重译**
    //         （这正是 §B4.25 登记的"E1 上下文偏旧"边界的收口）。
    //    判据只用**寄存器态**（`stq_*`、`rob_head`）⇒ 与 rob.v 的提交链无组合环 ✓
    //==========================================================================
    wire stx_en_w    = (st_xlate_en    === 1'b1);
    wire stx_ready_w = (st_xlate_ready === 1'b1);
    wire stx_dn_w    = (st_xlate_done  === 1'b1);
    wire stx_flt_w   = (st_xlate_fault === 1'b1);

    wire [STQ_N-1:0] stq_win_w;                  // 在提交窗口内（年龄 < W）
    wire [STQ_N-1:0] stq_blk_w;                  // 窗口内且"未按当前上下文定妥/未判坏"
    generate
    for (gv = 0; gv < STQ_N; gv = gv + 1) begin : g_stqblk
        assign stq_win_w[gv] = stq_v[gv] & stq_av[gv] & ~stq_ret[gv] &
                               (((stq_rob[gv] - rob_head) & 7'h7F) < W[7:0]);
        assign stq_blk_w[gv] = stq_win_w[gv] & ~stq_bad[gv] &
                               ~(~stx_en_w | (stq_pv[gv] & (stq_ctx[gv] == st_xlate_ctx)));
    end
    endgenerate
    wire stq_blk_any_w = |stq_blk_w;

    wire [7:0] age_rob  = (exe_rob - rob_head) & 7'h7F;      // E1 项年龄（转发窗口）
    //   ★★ 2B-3 第 6 段第二步：**发射闸门必须按"候选（i4_sel）"判年龄**。
    //     旧实现用 `age_rob`（= 正在 E1 的那条，即上一拍发射的项）⇒ 闸门判的是别人，
    //     只在"load 紧跟在 store 之后发射"这一拍凑巧正确（INORD_LOAD 队列门兜底）。
    //     本段把闸门改为候选年龄 `age_iss`，"更老未定址 store"判定逐条精确。
    wire [7:0] age_iss  = (iss_rob - rob_head) & 7'h7F;      // I1 候选年龄（发射闸门）

    //==========================================================================
    // 1. D3 分配（store 项）
    //==========================================================================
    //   ★★ 2B-3 第 5/6 段（x 隐患根治）：本文件**所有组合归约**一律改为 `assign` 连续赋值。
    //     实测动机：`always @(*)` + `for` 的归约在输入长期恒定时结果停留在 x
    //     （现场：`dr_valid=0000` 而 `dr_any=x` ⇒ `mem_req_valid=x` ⇒ 空闲拍请求口为 x）。
    //     连续赋值恒被求值，不依赖过程块的敏感表推断；语义与原循环逐项等价（下方逐处标注）。
    //   · 口径一次写死 **32 项**（`stq_v32` 高位补 0）⇒ 第 6 段把 STQ_N 从 16 扩到 32 时
    //     本节零改动（只需把高位来源从常量 0 换成 stq_v[16..31]）。
    genvar gv, gb, gk, gj;
    wire [31:0] stq_v32;
    generate
    for (gv = 0; gv < 32; gv = gv + 1) begin : g_v32
        if (gv < STQ_N) assign stq_v32[gv] = stq_v[gv];
        else            assign stq_v32[gv] = 1'b0;
    end
    endgenerate

    // ---- 1.1 占用数 popcount：assign 加法树（32 项口径；6 bit 覆盖 0..32）----
    wire [31:0] stq_l1;                  // 16 × 2 bit 部分和
    wire [23:0] stq_l2;                  //  8 × 3 bit
    wire [15:0] stq_l3;                  //  4 × 4 bit
    wire [9:0]  stq_l4;                  //  2 × 5 bit
    generate
    for (gv = 0; gv < 16; gv = gv + 1) begin : g_pc1
        assign stq_l1[2*gv +: 2] = {1'b0, stq_v32[2*gv]} + {1'b0, stq_v32[2*gv+1]};
    end
    for (gv = 0; gv < 8; gv = gv + 1) begin : g_pc2
        assign stq_l2[3*gv +: 3] = {1'b0, stq_l1[4*gv +: 2]} + {1'b0, stq_l1[4*gv+2 +: 2]};
    end
    for (gv = 0; gv < 4; gv = gv + 1) begin : g_pc3
        assign stq_l3[4*gv +: 4] = {1'b0, stq_l2[6*gv +: 3]} + {1'b0, stq_l2[6*gv+3 +: 3]};
    end
    for (gv = 0; gv < 2; gv = gv + 1) begin : g_pc4
        assign stq_l4[5*gv +: 5] = {1'b0, stq_l3[8*gv +: 4]} + {1'b0, stq_l3[8*gv+4 +: 4]};
    end
    endgenerate
    wire [5:0] stq_used = {1'b0, stq_l4[0 +: 5]} + {1'b0, stq_l4[5 +: 5]};
    wire [5:0] stq_need = {5'b0, alloc_valid[0]} + {5'b0, alloc_valid[1]} +
                          {5'b0, alloc_valid[2]} + {5'b0, alloc_valid[3]};
    assign alloc_ok = ((STQ_N[5:0]) - stq_used) >= stq_need;

    // ---- 1.2 空闲槽分配（原 `for` 扫描的连续赋值等价）----
    //   fr[j] = 序号 < j 的空闲槽数（前缀和链）；第 k 个空闲槽 = 唯一满足
    //   (空闲[j] && fr[j]==k) 的 j ⇒ ai[k] 的每一位 = 该候选向量的或归约
    //   （无需优先级链：候选天然互斥）。口径与"最低序号优先"一致。
    wire [6*(STQ_N+1)-1:0] ai_fr;
    assign ai_fr[0 +: 6] = 6'd0;
    generate
    for (gv = 0; gv < STQ_N; gv = gv + 1) begin : g_fr
        assign ai_fr[6*(gv+1) +: 6] = ai_fr[6*gv +: 6] + {5'b0, ~stq_v32[gv]};
    end
    endgenerate
    wire [W*STQ_IW*STQ_N-1:0] ai_cand;
    generate
    for (gk = 0; gk < W; gk = gk + 1) begin : g_ai_k
        for (gb = 0; gb < STQ_IW; gb = gb + 1) begin : g_ai_b
            for (gj = 0; gj < STQ_N; gj = gj + 1) begin : g_ai_j
                assign ai_cand[((gk*STQ_IW)+gb)*STQ_N + gj] =
                       ~stq_v32[gj] & (ai_fr[6*gj +: 6] == gk[5:0]) & ((gj >> gb) & 1);
            end
            assign alloc_idx[gk*STQ_IW + gb] =
                   |ai_cand[((gk*STQ_IW)+gb)*STQ_N +: STQ_N];
        end
    end
    endgenerate
    //   ★★ 2B-4 修复（锁步 p4_fpu 的 8 连 store 暴露的 **2B-2/2B-3 既有缺陷**）：
    //     队头回收（"队头空闲/已排空 ⇒ 本拍清 stq_v[head] 并把 head 前移"）与**本拍分配**
    //     可能撞在**同一个槽**上；旧实现的保护只比了 **lane 0** 的分配结果
    //     （`alloc_idx[0 +: STQ_IW] == stq_head_q`），若命中的是 lane 1..3 分配的槽，
    //     保护不生效 ⇒ 同拍"新写入 stq_v[head]=1"被"回收清 0"覆盖 ⇒ **新 store 项被静默丢失**
    //     （其 E1 仍会写 av/a/d，但 stq_v=0 ⇒ 转发与排空都看不到它；该槽随后被更年轻的
    //      store 复用并覆盖数据 ⇒ 前一条 store 永不落地）。
    //     实测：p4_fpu 的 `fsw fs8,40(t1)`（0x8000d028）分配到的槽 = 当拍队头 ⇒ 丢失 ⇒
    //     C4 报 0x8000d028 乱序 0x00000013 vs 2A 0x40e00000（该值 5.0）。
    //     修法：**逐 lane** 比较（任一 lane 命中队头即本拍不回收），语义与原注释一致。
    wire [W-1:0] alloc_hits_head_v;
    generate
    for (gv = 0; gv < W; gv = gv + 1) begin : g_ahh
        assign alloc_hits_head_v[gv] = alloc_valid[gv] &
                                       (alloc_idx[gv*STQ_IW +: STQ_IW] == stq_head_q);
    end
    endgenerate
    wire alloc_hits_head = alloc_ok & (|alloc_hits_head_v);

    //==========================================================================
    // 2. 更老未定址 store 检查 + 字节级转发（组合，load 发射拍；全部连续赋值）
    //==========================================================================
    // 2.1 更老未定址 store（阻塞 load 发射）—— **B28 保守闸门（2B-3 第 6 段已精确化）**
    //   · 判据：存在 `stq_v & ~stq_av`（已分配、地址未生成）且**比候选 load 更老**的 store
    //     ⇒ `iss_ok=0` ⇒ 该 load 本轮不可发射（B28 教训：更年轻 load 抢跑会漏转发）。
    //   · 本段两处修正（原实现的两处偏差，均在 2B-2 时以 `INORD_LOAD` 队列级门兜底）：
    //     ① `stq_rob` 改为**分配期**写入（§4.2）⇒ "已分配未执行"的 store 不再是上一占用者的
    //        陈旧年龄（旧实现在 E1 才写 ⇒ 年龄判据在未执行项上不可靠）；
    //     ② 年龄比较的基准由 `age_rob`（**正在 E1 的那条**）改为 `age_iss`（**I1 候选**）
    //        ⇒ 判的是"要发射的这条"而不是"上一拍发射的那条"。
    //   · 与 `iq.v` 的 `INORD_LOAD` **并联**：后者仍保留，作用是**LQ 槽位序的防死锁门**
    //     （见 backend_top 例化处注：LQ 槽在 E1 分配、提交点释放，若容许越过"更老未就绪的
    //     load"，年轻 load 可占满 32 槽而更老那条永远发不出 ⇒ 结构性死锁）。
    //   · 更老 store **均已定址**时本条不阻塞：重叠字节由 §2.2 逐字节转发/合并兜住
    //     （E1 当拍读到的 STQ 快照必然包含所有"更早已发射"的 store —— 单发射口 ⇒
    //      更早发射的 store 至少早一拍完成 E1，`stq_av/stq_a/stq_msk/stq_d` 已全部落地）。
    wire [STQ_N-1:0] unk_v;
    generate
    for (gv = 0; gv < STQ_N; gv = gv + 1) begin : g_unk
        assign unk_v[gv] = stq_v[gv] & ~stq_av[gv] &
                           (((stq_rob[gv] - rob_head) & 7'h7F) < age_iss);
    end
    endgenerate
    wire any_unk_w = |unk_v;

    // 2.2 字节级转发（原 `always @(*)` + 双重 for 的连续赋值等价）
    //   ★★ `exe_size` 的编码是 **log2(字节数)**，不是字节数！唯一真源 `decoder.v`
    //      `mem_size_o`：LB/SB=3'd0、LH/SH=3'd1、LW/SW=3'd2、AMO=3'd2、flw=3'd2、
    //      fld=3'd3（其注释里的"1/2/4 B"是**字节数说明**，不是字段取值）。
    //      本里程碑只做 ≤4 B 对齐访问 ⇒ 用条件链给出字节掩码；
    //      3'd3（8 B，fld/fsd）超出本里程碑范围，按 4 B 处理（2B-3 第 6 段补 64 bit 访存）。
    wire [3:0] lmask_w = (exe_size == 3'd0) ? (4'h1 << exe_addr[1:0]) :
                         (exe_size == 3'd1) ? (4'h3 << exe_addr[1:0]) :
                                              (4'hF << exe_addr[1:0]);
    //   ★★ 转发优先级**口径修正**（2B-3 规格 §6.2 / 本文件头注："取字内**最年轻**的更老匹配者"）：
    //      原循环用 `cur_age <= best_age`（初值 255）⇒ 实际取到 age **最小**者 = **最老** store
    //      —— 与规格相反（同字节两条更老 store 时应取更年轻者）。本段改为"取 age 最大者"
    //      （age = 离 ROB 头的距离 ⇒ 越大越年轻）。用例 C3（同字节 0x11/0x22 ⇒ 期望 0x22）
    //      即验此点。
    //   布局：4 字节 × 32 候选（gj ≥ STQ_N 恒 0）——扩到 32 槽时零改动。
    //   （所有中间网先声明后使用；连续赋值之间的先后次序无关。）
    wire [4*32-1:0]    fw_match;
    wire [4*32*8-1:0]  fw_age_c;             // 匹配 ⇒ 该 store 的 age；否则 0
    wire [4*32*8-1:0]  fw_dat_c;             // 匹配 ⇒ 该字节数据；否则 0
    wire [4*32-1:0]    fw_sel;               // 匹配 且 age == 该字节最优 age
    wire [4*8-1:0]     fw_best;
    wire [4*4*8*8-1:0] fw_ag_ch, fw_wd_ch;
    wire [3:0]         fwd_hit_w;
    wire [31:0]        fwd_data_w;
    generate
    for (gb = 0; gb < 4; gb = gb + 1) begin : g_fw_b
        wire [2:0] bl_w = {1'b0, exe_addr[1:0]} + gb[2:0];   // 字内字节道（3 bit：0..6）
        wire       in_w = lmask_w[gb] & (bl_w < 3'd4);        // 该字节在本次访问内
        for (gj = 0; gj < 32; gj = gj + 1) begin : g_fw_j
            if (gj < STQ_N) begin : g_fw_on
                assign fw_match[gb*32 + gj] =
                       in_w & stq_v[gj] & stq_av[gj] & stq_msk[gj][bl_w] &
                       (stq_a[gj][31:2] == exe_addr[31:2]) &
                       (((stq_rob[gj] - rob_head) & 7'h7F) < age_rob);
                assign fw_age_c[(gb*32+gj)*8 +: 8] =
                       fw_match[gb*32 + gj] ? ((stq_rob[gj] - rob_head) & 7'h7F) : 8'h0;
                assign fw_dat_c[(gb*32+gj)*8 +: 8] =
                       fw_match[gb*32 + gj] ? stq_d[gj][8*bl_w +: 8] : 8'h0;
            end else begin : g_fw_off
                assign fw_match[gb*32 + gj]       = 1'b0;
                assign fw_age_c[(gb*32+gj)*8 +: 8] = 8'h0;
                assign fw_dat_c[(gb*32+gj)*8 +: 8] = 8'h0;
            end
        end
        //   best_age[b] = max over j（4 组 × 组内 8 项串行链 + 组间两级）
        wire [7:0] bs01_w, bs23_w, bs_w;
        assign bs01_w = (fw_ag_ch[((gb*4+0)*8+7)*8 +: 8] >= fw_ag_ch[((gb*4+1)*8+7)*8 +: 8])
                        ? fw_ag_ch[((gb*4+0)*8+7)*8 +: 8] : fw_ag_ch[((gb*4+1)*8+7)*8 +: 8];
        assign bs23_w = (fw_ag_ch[((gb*4+2)*8+7)*8 +: 8] >= fw_ag_ch[((gb*4+3)*8+7)*8 +: 8])
                        ? fw_ag_ch[((gb*4+2)*8+7)*8 +: 8] : fw_ag_ch[((gb*4+3)*8+7)*8 +: 8];
        assign bs_w   = (bs01_w >= bs23_w) ? bs01_w : bs23_w;
        assign fw_best[gb*8 +: 8] = bs_w;
        //   命中位（与 lmask 无关：in_w 已并入 fw_match）
        assign fwd_hit_w[gb] = |fw_match[gb*32 +: 32];
        //   胜者数据（唯一胜者 ⇒ 或归约等价于选择）
        assign fwd_data_w[gb*8 +: 8] =
               fw_wd_ch[((gb*4+0)*8+7)*8 +: 8] | fw_wd_ch[((gb*4+1)*8+7)*8 +: 8] |
               fw_wd_ch[((gb*4+2)*8+7)*8 +: 8] | fw_wd_ch[((gb*4+3)*8+7)*8 +: 8];
    end
    endgenerate
    generate
    for (gb = 0; gb < 4; gb = gb + 1) begin : g_fw_sel
        for (gj = 0; gj < 32; gj = gj + 1) begin : g_fw_selj
            assign fw_sel[gb*32 + gj] = fw_match[gb*32 + gj] &
                                        (fw_age_c[(gb*32+gj)*8 +: 8] == fw_best[gb*8 +: 8]);
        end
    end
    for (gb = 0; gb < 4; gb = gb + 1) begin : g_fw_ch
        for (gk = 0; gk < 4; gk = gk + 1) begin : g_fw_chg
            assign fw_ag_ch[((gb*4+gk)*8 + 0)*8 +: 8] = fw_age_c[(gb*32 + gk*8 + 0)*8 +: 8];
            assign fw_wd_ch[((gb*4+gk)*8 + 0)*8 +: 8] = fw_sel[gb*32 + gk*8 + 0]
                                                        ? fw_dat_c[(gb*32 + gk*8 + 0)*8 +: 8] : 8'h0;
            for (gj = 1; gj < 8; gj = gj + 1) begin : g_fw_chs
                assign fw_ag_ch[((gb*4+gk)*8 + gj)*8 +: 8] =
                       (fw_ag_ch[((gb*4+gk)*8 + gj-1)*8 +: 8] >=
                        fw_age_c[(gb*32 + gk*8 + gj)*8 +: 8])
                       ? fw_ag_ch[((gb*4+gk)*8 + gj-1)*8 +: 8]
                       : fw_age_c[(gb*32 + gk*8 + gj)*8 +: 8];
                assign fw_wd_ch[((gb*4+gk)*8 + gj)*8 +: 8] =
                       fw_wd_ch[((gb*4+gk)*8 + gj-1)*8 +: 8] |
                       (fw_sel[gb*32 + gk*8 + gj] ? fw_dat_c[(gb*32 + gk*8 + gj)*8 +: 8] : 8'h0);
            end
        end
    end
    endgenerate

    wire fwd_all_w = ((fwd_hit_w & lmask_w) == lmask_w);


    //==========================================================================
    // 3. LQ（load queue）：`OUT_N` 项在途表（2B-3 第 6 段第一步：4 → 32 项）
    //==========================================================================
    //   ★ 扩容口径（第 6 段两步的最终状态）：
    //     · 深度 = `OUT_N` =`BACK2_MEM_OUT_N` =`BACK2_LQ_N` = 32（LQ 32）；
    //     · 下标宽度 = `LQ_IW` =`BACK2_LQ_IDX_W` = 5；
    //     · 槽标签 `ld_tag[slot] = slot`（最高位恒 0），**store 排空标签取全 1**
    //       ⇒ `BACK2_MEM_TAG_W` 必须 ≥ LQ_IW+1（已同步 3→6），否则 31 号槽会与
    //       排空标签撞车（响应被误当 load 数据写回）。
    //     · 原实现把 4 个槽的 `ld_free/pend_vec/rsp_vec` **下标字面写死**，
    //       扩容时必须改为 generate + 优先级链（下 §3.2），语义逐项等价（最低序号优先）。
    //     · **第一步**只扩容量/位宽（释放语义保持"响应即释放"）并保全绿；
    //       **第二步**改为真 LSQ 语义：E1 入队（§4.3）、写回可乱序（标签匹配）、
    //       **提交点释放**（§4.4b，`ld_dn` 与 `ld_v` 分离）。
    reg                  ld_v    [0:OUT_N-1];        // 已分配（E1 入队 ⇒ 提交点释放）
    reg                  ld_req  [0:OUT_N-1];        // 请求已发（等响应）
    //   ★★ 2B-3 第 6 段第二步：`ld_dn` = 该 load 的数据已齐（响应到 / 合并完成）。
    //     与 `ld_v` 分离的原因：**提交点释放**要求项在写回之后仍占着 LQ（直到该 load
    //     按程序序提交），而"已完成"必须把它排除出请求口与响应匹配 ⇒ 两个状态位。
    reg                  ld_dn   [0:OUT_N-1];
    //   ★ 2B-4：`ld_ex` = 该 LQ 项已完成 **E1**（地址/掩码/转发信息已填）。
    //     派发期分配后、E1 之前，项存在但地址无效 ⇒ 必须靠本位置把它挡在请求口之外。
    reg                  ld_ex   [0:OUT_N-1];
    reg  [ROB_IDX_W-1:0] ld_rob  [0:OUT_N-1];
    reg  [`BACK2_EPOCH_W-1:0] ld_ep [0:OUT_N-1];
    reg                  ld_di   [0:OUT_N-1];
    reg                  ld_df   [0:OUT_N-1];
    reg  [PDW_I-1:0]     ld_pi   [0:OUT_N-1];
    reg  [PDW_F-1:0]     ld_pf   [0:OUT_N-1];
    reg  [31:0]          ld_addr [0:OUT_N-1];
    reg  [2:0]           ld_size [0:OUT_N-1];
    reg                  ld_uns  [0:OUT_N-1];
    reg  [3:0]           ld_hm   [0:OUT_N-1];
    reg  [31:0]          ld_hd   [0:OUT_N-1];
    reg  [TAG_W-1:0]     ld_tag  [0:OUT_N-1];

    //--------------------------------------------------------------------------
    // 3.1b LQ 分配器（D3 派发期；与 §1.2 的 STQ 分配器**同构**：空闲前缀和 + 候选或归约）
    //   第 k 个空闲槽 = 唯一满足 `(空闲[j] && fr[j]==k)` 的 j；lane k 的索引 = 该候选向量
    //   的按位或归约（候选互斥 ⇒ 无需优先级链）。语义 = "最低序号空闲槽优先"。
    //--------------------------------------------------------------------------
    wire [6*(OUT_N+1)-1:0] lai_fr;
    assign lai_fr[0 +: 6] = 6'd0;
    generate
    for (gv = 0; gv < OUT_N; gv = gv + 1) begin : g_lfr
        assign lai_fr[6*(gv+1) +: 6] = lai_fr[6*gv +: 6] + {5'b0, ~ld_v[gv]};
    end
    endgenerate
    wire [W*LQ_IW*OUT_N-1:0] lai_cand;
    generate
    for (gk = 0; gk < W; gk = gk + 1) begin : g_lai_k
        for (gb = 0; gb < LQ_IW; gb = gb + 1) begin : g_lai_b
            for (gj = 0; gj < OUT_N; gj = gj + 1) begin : g_lai_j
                assign lai_cand[((gk*LQ_IW)+gb)*OUT_N + gj] =
                       ~ld_v[gj] & (lai_fr[6*gj +: 6] == gk[5:0]) & ((gj >> gb) & 1);
            end
            assign lalloc_idx[gk*LQ_IW + gb] =
                   |lai_cand[((gk*LQ_IW)+gb)*OUT_N +: OUT_N];
        end
    end
    endgenerate
    //   ★ 注意：`lai_fr[j]` = 序号 < j 的**空闲**槽数（前缀和加的是 `~ld_v`）
    //     ⇒ `lai_fr[OUT_N]` 就是**空闲总数**（不是占用数！曾把它当成占用数写反，
    //     导致"LQ 越空越不允许派发 load"⇒ 首个带 load 的块永久派发不了，实测程序 1 挂死）。
    wire [5:0] lq_free_w = lai_fr[6*OUT_N +: 6];
    wire [5:0] lalloc_need = {4'b0, lalloc_valid[0]} + {4'b0, lalloc_valid[1]} +
                             {4'b0, lalloc_valid[2]} + {4'b0, lalloc_valid[3]};
    assign lalloc_ok = lq_free_w >= lalloc_need;

    //--------------------------------------------------------------------------
    // 3.2 LQ 打包视角 + 归约（全部连续赋值；深度/位宽参数化）
    //   语义与原 4 项字面实现**逐项等价**：
    //     · `ld_free` = 各槽空闲（原 `~{ld_v[3],…,ld_v[0]}`）；
    //     · `pend_vec` = 已分配且未发请求（原 4 项拼接）；
    //     · `rsp_vec`  = 在等响应且标签命中（原 4 项拼接）；
    //     · `ld_ex`    = 该槽已执行 E1（派发期分配 ⇒ 未执行项不得进请求口）。
    //   优先级编码用**纯函数**（只吃打包向量、不读存储器；本文件禁用"读存储器的 function"）。
    //--------------------------------------------------------------------------
    function [LQ_IW-1:0] pri_enc(input [OUT_N-1:0] v);
        integer pi;
        begin
            pri_enc = {LQ_IW{1'b0}};
            for (pi = OUT_N-1; pi >= 0; pi = pi - 1)
                if (v[pi]) pri_enc = pi[LQ_IW-1:0];
        end
    endfunction

    wire [OUT_N-1:0] ld_free;
    wire [OUT_N-1:0] pend_vec;
    wire [OUT_N-1:0] rsp_vec;
    generate
    for (gv = 0; gv < OUT_N; gv = gv + 1) begin : g_lq_pk
        assign ld_free [gv] = ~ld_v[gv];
        assign pend_vec[gv] = ld_v[gv] & ld_ex[gv] & ~ld_req[gv] & ~ld_dn[gv];
        assign rsp_vec [gv] = ld_v[gv] & ld_req[gv] & (ld_tag[gv] == mem_rsp_tag);
    end
    endgenerate

    wire             pend_any   = |pend_vec;
    wire [LQ_IW-1:0] pend_sel   = pri_enc(pend_vec);
    wire             rsp_ok     = mem_rsp_valid & (|rsp_vec);
    wire [LQ_IW-1:0] rsp_sel    = pri_enc(rsp_vec);
    // 发射许可（★ 2B-4）：槽位已在**派发期**分配 ⇒ 此处只剩"无更老未定址 store"一条件
    //   （旧口径还要求"有空闲 LQ 槽"，那是"槽在 E1 分配"时代的死锁防护，已不需要）。
    //   ★★ 2B-4 内存序缺口修复（修法 1 的精确定位版，见报告 §B4.18）：**再加"CDQ 已排空"**——
    //     本核"已提交未排空"的 store 只能靠 STQ 转发被同地址 load 看见；整机冲刷会清 STQ
    //     （正确的设计），此时若 CDQ 里还有未落地的已提交 store，重新执行的 load 既无转发
    //     也无互锁 ⇒ 直读内存旧值（实测 p12 idx10/12/13 读到 0）。把 load 发射门控到
    //     "CDQ 空"即可：drain 是 FIFO 单笔/拍 ⇒ 代价至多 CDQ 深度拍，且绝大多数拍 CDQ 为空。
    //     （`iss_ok` 的赋值必须移到 CDQ 声明之后，否则 `dr_any` 会成隐式网。）

    //==========================================================================
    // 3.3 提交排空队列（CDQ）—— 逐 lane 收全提交组、逐拍顺序排空
    //==========================================================================
    //   ★★ 2B-4 修复（任务①；2B-3 `遗留 ①` 由锁步 p4_fpu 的 8 连 store 实测触发）：
    //     `rob.v` 允许**同拍最多 4 条 store 提交**，而排空口每拍只发一笔；旧实现直接用
    //     "本拍提交组 + 最低 lane"驱动排空 ⇒ 同组其余 store **被提交却永不落地**
    //     （实测：p4_fpu 的 `fsw fs0,24(t1)` 与相邻 store 同组提交 ⇒ 只排空了前一条，
    //      后续 `flw fs11,24(t1)` 读到 DDR 初值 0x00000013 而非 0x40e00000，C1 第 55 条分歧）。
    //   本队列把**每个提交组内的全部 store**（≤W 笔、程序序）入队，出队按 FIFO 逐拍一笔
    //   ⇒ 仍是**单请求口 / 单笔在途**，只是"提交"与"排空"解耦（可多拍顺序发出）。
    //   · 地址/数据/掩码**随提交拷贝进队列**：STM 项在被排空前仍有效（转发照旧），
    //     而 `flush_all`（陷阱）清 STQ 时已提交的 store 仍能落地（架构上必须可见）。
    //   · 入队余量判据只用**寄存器态**（`cdq_cnt`）⇒ 与 rob.v 的提交链无组合环。
    reg  [STQ_IW-1:0] cdq_idx [0:CDQ_N-1];
    reg  [31:0]       cdq_a   [0:CDQ_N-1];       // ★ (b)：**VA**（E1 值；CDQ 源翻译请求用）
    reg  [31:0]       cdq_pa  [0:CDQ_N-1];       // ★ (b)：**PA**（排空口唯一地址来源）
    reg  [31:0]       cdq_d   [0:CDQ_N-1];
    reg  [3:0]        cdq_m   [0:CDQ_N-1];
    reg  [CDQ_N-1:0]  cdq_v;
    reg  [CDQ_N-1:0]  cdq_pv;                    // ★ (b)：该笔 PA 已定（可排空）
    reg  [CDQ_N-1:0]  cdq_bad;                   // ★ (b)：该笔翻译故障（作废：不写只弹出）
    reg  [3:0]        cdq_ctx [0:CDQ_N-1];       // ★ (b)：该笔的**提交拍**翻译上下文
    reg  [CDQ_PW:0]   cdq_cnt;
    reg  [CDQ_PW-1:0] cdq_head, cdq_tail;

    //   入队许可：余量 ≥ 一整组（W 笔）——保守，且与"本拍出队释放 1 项"无关（无环）
    //   ★★ (b2)：余量门 × **提交窗翻译定妥门**（见 §0b；回送 rob.v 的 `mem_wr_ready`
    //     ⇒ 窗口内有"未定妥"的 store 时，整条提交前缀链在该 store 处停住）
    assign dr_room_ok = (((CDQ_N[CDQ_PW:0]) - cdq_cnt) >= W[CDQ_PW:0]) && !stq_blk_any_w;
    wire [W-1:0] dr_take = dr_valid & {W{dr_room_ok}};
    //   组内压缩序号（rank）：第 k 个被收下的 lane 写到 tail+k
    wire [2*W-1:0] dr_rank;
    generate
    for (gv = 0; gv < W; gv = gv + 1) begin : g_drrank
        if (gv == 0) assign dr_rank[0 +: 2] = 2'd0;
        else         assign dr_rank[2*gv +: 2] = dr_rank[2*(gv-1) +: 2] + {1'b0, dr_take[gv-1]};
    end
    endgenerate
    wire [CDQ_PW:0] dr_push_n = {{CDQ_PW-1{1'b0}}, dr_rank[2*(W-1) +: 2]} + {1'b0, dr_take[W-1]};
    wire [CDQ_PW-1:0] cdq_wp [0:W-1];
    generate
    for (gv = 0; gv < W; gv = gv + 1)
        assign cdq_wp[gv] = cdq_tail + dr_rank[2*gv +: 2];
    endgenerate

    //==========================================================================
    // 3.4 ★★ (b) store 地址翻译引擎（§B4.24.9 第 2/3/5 条 + 上下文口径修正）
    //--------------------------------------------------------------------------
    //  【为什么"上下文"必须随请求携带，且权威判定在**提交拍**】（本段实测根因，报告 §B4.25）
    //    · 一次 store 翻译的正确性取决于三件事：VA 对、**翻译上下文对**、遍历结果可信。
    //      上下文 = {有效特权级, SUM, MXR}。本核 CSR **只在提交点更新**（`csr_file` 写口在
    //      提交级）⇒ 与"该 store 在程序序上那一刻"一致的唯一时刻就是**它的提交拍**。
    //      · 取 **E1 拍**的上下文 ⇒ 偏旧（更老的 CSR 写尚未提交）。实测 p13：
    //        PTE 更新 store（VA 0x80027000）在 `csrw mstatus`（MPRV=0）**之前**投机执行
    //        ⇒ 用 MPRV=1/MPP=U 翻译 ⇒ 该页 U=0 ⇒ 页错误 ⇒ 已提交写被静默丢弃。
    //      · 取 **排空拍**的上下文 ⇒ 偏新（更年轻的 CSR 写已提交）。p13 原始形态即此：
    //        排空时 MPRV 已被后面的 `csrw` 重新置 1 ⇒ 同样错译/丢写。
    //    · ⇒ 本引擎三条口径：
    //      ① **E1 拍发一次"预翻译"请求**（照简化 ③：搭在现成的 `st_done_valid` 拍，
    //         `st_xlate_en=0` 时直接 `stq_pv=1, stq_pa=VA`）；该请求**未当拍被接受即放弃**
    //         （一次性、不重发）——它只是**加速**，结果仅当提交拍上下文一致时才沿用；
    //      ② **提交拍（CDQ 入队）权威判定**：`st_xlate_en`（提交序上下文）为 0 ⇒
    //         `cdq_pa=VA, cdq_pv=1`，**无条件覆盖**预翻译结果；
    //      ③ 提交拍需要翻译而预翻译不可用/上下文不一致 ⇒ `cdq_pv=0`，由 **CDQ 扫描**
    //         用**入队时锁存的 `cdq_ctx`** 重译 —— 这也是"排空永不悬挂"的活性保证
    //         （已提交项无论如何都能拿到 PA；`flush_all` 清 STQ 也不影响 CDQ 项）。
    //    · 来源判别（`stx_src_q`）：STQ 源（只可能来自 ①）⇒ 只写回 `stq_*`；
    //      CDQ 源 ⇒ 只写回该 **CDQ 阵列项**（`stx_idx_q` 即 CDQ 下标）。二者不交叉，
    //      从而不会把"新占用者"的翻译结果写进"旧 CDQ 项"（槽号在 `flush_all` 后会复用）。
    //    · 预翻译**失败不置坏位**（只留 `stq_pv=0`）；只有 **CDQ 源**的故障才置
    //      `cdq_bad`（提交拍口径 ⇒ 可信）⇒ 才走"作废不写"兜底。
    //==========================================================================
    reg  [STQ_IW-1:0] stx_idx_q;                 // 在途目标下标（接受拍锁存）
    reg  [31:0]       stx_va_q;                  // 在途 VA（接受拍锁存）
    reg  [3:0]        stx_ctx_q;                 // 在途翻译上下文（接受拍锁存）
    reg               stx_act_q;                 // 在途标志
    reg               stx_src_q;                 // 0 = 源为 STQ 槽 / 1 = 源为 CDQ 项

    //   ① E1 拍预翻译请求（一次性，优先于 CDQ 候选）
    //   （输入的悬空净化 `stx_*_w` 已上移到 §0b —— 提交门也要用，必须先声明。）
    wire stx_e1_w = exe_valid & exe_is_store & stx_en_w;
    //   ② STQ 扫描：**提交窗内"未定妥"的 store**（= §0b 的 `stq_blk_w`，逐项同式）。
    //      与提交门**同源** ⇒ 既保证"门挡住的项一定有人去翻译"（无死锁），又天然限定为
    //      "马上要提交的那几条"（不做无谓的投机翻译，也不给投机项打投机异常）。
    wire [STQ_N-1:0] stx_s_v = stq_blk_w;
    wire             stx_s_any = |stx_s_v;
    wire [STQ_IW-1:0] stx_s_idx = pri_enc(stx_s_v);
    //   ③ CDQ 候选（已提交、PA 未定、未判坏）—— 提交门之后的 fail-safe/活性兜底
    wire [CDQ_N-1:0] stx_c_v;
    generate
    for (gv = 0; gv < CDQ_N; gv = gv + 1) begin : g_stx_c
        assign stx_c_v[gv] = cdq_v[gv] & ~cdq_pv[gv] & ~cdq_bad[gv];
    end
    endgenerate
    wire              stx_c_any = |stx_c_v;
    //   CDQ 候选复用 `pri_enc`（32 宽口径）：高位补 0 ⇒ 结果即最低有效候选的下标
    wire [OUT_N-1:0]  stx_c_pad = {{(OUT_N-CDQ_N){1'b0}}, stx_c_v};
    wire [STQ_IW-1:0] stx_c_enc = pri_enc(stx_c_pad);
    wire [STQ_IW-1:0] stx_c_idx = {{(STQ_IW-CDQ_PW){1'b0}}, stx_c_enc[CDQ_PW-1:0]};
    //   优先级：E1 预翻译 > **STQ 扫描（提交窗）** > CDQ 扫描
    wire              stx_pick_c  = ~stx_e1_w & ~stx_s_any;  // 选中的是 CDQ 源
    wire              stx_sel_v   = stx_e1_w | stx_s_any | stx_c_any;
    wire              stx_sel_src = stx_pick_c;              // 1 = CDQ 源
    wire [STQ_IW-1:0] stx_sel_idx = stx_e1_w ? exe_stq_idx :
                                    (stx_pick_c ? stx_c_idx : stx_s_idx);
    wire [31:0]       stx_sel_va  = stx_e1_w ? exe_addr :
                                    (stx_pick_c ? cdq_a[stx_c_idx] : stq_a[stx_s_idx]);
    //   STQ 扫描与 E1 预翻译都用**当下**上下文（提交窗内的项 ⇒ 当下上下文即提交序上下文）
    wire [3:0]        stx_sel_ctx = stx_pick_c ? cdq_ctx[stx_c_idx] : st_xlate_ctx;

    assign st_xlate_valid = stx_act_q | stx_sel_v;
    assign st_xlate_idx   = stx_act_q ? stx_idx_q : stx_sel_idx;
    assign st_xlate_va    = stx_act_q ? stx_va_q  : stx_sel_va;
    assign st_xlate_ctx_o = stx_act_q ? stx_ctx_q : stx_sel_ctx;
    //   接受拍（在途时不再接受新的：适配器在翻译期间不会给 ready）
    wire   stx_accept_w   = st_xlate_valid & stx_ready_w & ~stx_act_q;
    //   完成拍（只在"有在途项"时认；冲刷打断后的**迟到 done** 一律忽略）
    wire   stx_done_w     = stx_dn_w & stx_act_q;
    //   ★★ (b2) **精确页错误上报**（cause 15 / mtval = VA / rob = 该 store 的 ROB 项）：
    //     · 只认 **STQ 源**（执行期、项仍在 STQ ⇒ 尚未提交 ⇒ 可以精确）；
    //     · 只认**提交窗内**的项（窗口外是投机项：上下文可能偏旧 ⇒ 不报，等它进窗口再重译）；
    //     · `~stq_ret`：已退役项不再报。CDQ 源的故障 ⇒ 该项**已提交**（提交门失效的兜底）
    //       ⇒ 不报异常，只走 `cdq_bad`（只弹出、不写；口径登记为已知边界）。
    wire   stx_flt_rep_w = stx_done_w & ~stx_src_q & stx_flt_w &
                           stq_v[stx_idx_q] & ~stq_ret[stx_idx_q] & stq_win_w[stx_idx_q];

    //   出队：队首一笔；
    wire              dr_any  = (cdq_cnt != {(CDQ_PW+1){1'b0}});
    //   ★★ (b) 排空握手三态（§B4.24.9 第 5 条的兜底口径）：
    //     · `dr_ok`  ：该笔 PA 已到齐 ⇒ **真发存储写**（地址 = `cdq_pa`，不再翻译）
    //     · `dr_bad` ：该笔翻译故障 ⇒ **只弹出、不写**（等于旧形态的"静默丢弃"，但
    //                  **不悬挂**；store 页错误的精确化是紧随其后的另一步，本步不做）
    //     · 二者皆 0（PA 在途）⇒ **本拍不排空**（`dr_fire=0`），等 PA 到齐再发
    //   `ld_fire` 仍以 `~dr_any` 门控 ⇒ "排空优先、排空未完不发 load"的既有内存序不变。
    wire              dr_ok   = cdq_pv [cdq_head];
    wire              dr_bad  = cdq_bad[cdq_head];
    assign iss_ok = ~any_unk_w;                 // （"CDQ 空"的门控改由顶层在冲刷侧做，见 dr_empty_o）
    assign dr_empty_o = ~dr_any;
    wire [STQ_IW-1:0] dr_sel  = cdq_idx[cdq_head];
    wire              dr_fire = dr_any & mem_req_ready & (dr_ok | dr_bad);   // 离队
    wire              dr_issue= dr_any & mem_req_ready &  dr_ok;             // 真发写
    wire              ld_fire = pend_any & ~dr_any & mem_req_ready;

    assign mem_req_valid = dr_issue | ld_fire;
    assign mem_req_wen   = dr_issue;
    assign mem_req_addr  = dr_issue ? cdq_pa[cdq_head]  : ld_addr[pend_sel];
    assign mem_req_wdata = dr_issue ? cdq_d[cdq_head]   : 32'h0;
    assign mem_req_wstrb = dr_issue ? cdq_m[cdq_head]   : 4'h0;
    assign mem_req_tag   = dr_issue ? {TAG_W{1'b1}}     : ld_tag[pend_sel];

    // ---- 写回：响应到达 或（部分/全部）转发 + 响应 合并 ----
    wire [31:0] wb_word = mem_rsp_rdata;
    wire [31:0] wb_merge = { ld_hm[rsp_sel][3] ? ld_hd[rsp_sel][31:24] : wb_word[31:24],
                             ld_hm[rsp_sel][2] ? ld_hd[rsp_sel][23:16] : wb_word[23:16],
                             ld_hm[rsp_sel][1] ? ld_hd[rsp_sel][15:8]  : wb_word[15:8],
                             ld_hm[rsp_sel][0] ? ld_hd[rsp_sel][7:0]   : wb_word[7:0] };
    function [31:0] ext_load(input [31:0] w, input [1:0] off, input [2:0] sz, input uns);
        reg [7:0]  b0;
        reg [15:0] h0;
        begin
            b0 = w[8*off +: 8];
            h0 = (off[1] == 1'b0) ? w[15:0] : w[31:16];
            //   ★ 同 §2.2：`sz` 是 log2(字节数) ⇒ 0=字节、1=半字、≥2=字（8 B 属 2B-3）
            case (sz)
                3'd0: ext_load = uns ? {24'h0, b0} : {{24{b0[7]}}, b0};
                3'd1: ext_load = uns ? {16'h0, h0} : {{16{h0[15]}}, h0};
                default: ext_load = w;
            endcase
        end
    endfunction

    // 全转发项：E1 次拍直接写回（单寄存器直通）
    reg         fwdp_v;
    reg [ROB_IDX_W-1:0] fwdp_rob;
    reg [`BACK2_EPOCH_W-1:0] fwdp_ep;
    reg         fwdp_di, fwdp_df;
    reg [PDW_I-1:0] fwdp_pi;
    reg [PDW_F-1:0] fwdp_pf;
    reg [31:0]  fwdp_data;
    reg [2:0]   fwdp_size;
    reg [1:0]   fwdp_off;
    reg         fwdp_uns;

    assign wb_valid   = fwdp_v | rsp_ok;
    assign wb_rob     = fwdp_v ? fwdp_rob  : ld_rob[rsp_sel];
    assign wb_epoch   = fwdp_v ? fwdp_ep   : ld_ep[rsp_sel];
    //   ★★ 4b-2b：带错响应**不得写回目的寄存器**（该 load 将以精确异常结束、
    //     永不提交；抑制 PRF 写口是双保险）。转发路径（fwdp_v）不参与本判据。
    //   ★★ 4b-2b-fix（实测回归抓出）：`mem_rsp_err` 必须用 `=== 1'b1` **净化**——
    //     本模块被多处直接驱动 TB 例化，新增输入若在某个 TB 里**未接**（悬空 z），
    //     `rsp_ok & mem_rsp_err` 会成 x ⇒ `wb_dst_i` 的 x 条件把写口变成 x
    //     ⇒ 整核写回失效（实测 `tb_back2_lockstep` 第 1 个程序后停摆 24 条）。
    //     口径：**只有明确的 1 才算"带错响应"**，z/x/0 一律按正常响应处理。
    wire              rsp_err_w = (mem_rsp_err === 1'b1);
    assign wb_dst_i   = fwdp_v ? fwdp_di   : (rsp_ok & rsp_err_w ? 1'b0 : ld_di[rsp_sel]);
    assign wb_dst_f   = fwdp_v ? fwdp_df   : (rsp_ok & rsp_err_w ? 1'b0 : ld_df[rsp_sel]);
    //   ★★ 4b-2b：数据侧精确异常上报。与 `wb_valid`（= 该 load 的 done）**同拍** ⇒
    //     ROB 的 `upd_exc`（异常位）与写回（done 位）在同一沿写入 ⇒ 下一拍 ROB 头部
    //     同时看到 done+exc ⇒ 精确抛陷阱、且该指令**没有**提交（见 rob.v:166/222）。
    //   ★★ (b2)：本通道现在承载**两类**数据侧精确异常，按"store 优先"给出确定优先级
    //     （两者天然互斥：`rsp_ok` 是 load 响应拍、`stx_flt_rep_w` 是 store 翻译完成拍，
    //      而适配器内翻译事务与访存请求串行）：
    //       · cause 13 = load page fault（带错响应；mtval = 该 load 的 VA）
    //       · cause 15 = **store/AMO page fault**（本段新增；mtval = 该 store 的 VA）
    assign exc_valid_o = (rsp_ok & rsp_err_w) | stx_flt_rep_w;
    assign exc_rob_o   = stx_flt_rep_w ? stq_rob[stx_idx_q] : ld_rob[rsp_sel];
    assign exc_cause_o = stx_flt_rep_w ? 4'd15 : 4'd13;
    assign exc_tval_o  = stx_flt_rep_w ? stq_a[stx_idx_q] : ld_addr[rsp_sel];
    assign wb_pdest_i = fwdp_v ? fwdp_pi   : ld_pi[rsp_sel];
    assign wb_pdest_f = fwdp_v ? fwdp_pf   : ld_pf[rsp_sel];
    assign wb_data    = fwdp_v ? ext_load(fwdp_data, fwdp_off, fwdp_size, fwdp_uns)
                               : ext_load(wb_merge, ld_addr[rsp_sel][1:0],
                                          ld_size[rsp_sel], ld_uns[rsp_sel]);

    assign st_done_valid = exe_valid & exe_is_store;
    assign st_done_rob   = exe_rob;
    assign st_done_epoch = exe_epoch;

    //   ★ `stq_used` 现在是 6 bit（32 项口径）⇒ 零扩展到 8 bit；
    //     写 [7:0] 之外的位属于向量外位选，iverilog/Vivado 都返回 x（诊断口观测为 x）。
    assign stq_cnt_o = {2'b0, stq_used};

    //==========================================================================
    // 4. 时序
    //==========================================================================
    reg [31:0] cnt_ld_q, cnt_st_q, cnt_fwd_q, cnt_stall_q;
    integer    si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stq_head_q <= {STQ_IW{1'b0}};
            stq_tail_q <= {STQ_IW{1'b0}};
            cnt_ld_q <= 32'h0; cnt_st_q <= 32'h0; cnt_fwd_q <= 32'h0; cnt_stall_q <= 32'h0;
            cdq_cnt <= {(CDQ_PW+1){1'b0}}; cdq_head <= {CDQ_PW{1'b0}}; cdq_tail <= {CDQ_PW{1'b0}};
            cdq_v   <= {CDQ_N{1'b0}};
            cdq_pv  <= {CDQ_N{1'b0}}; cdq_bad <= {CDQ_N{1'b0}};
            stx_act_q <= 1'b0; stx_src_q <= 1'b0; stx_idx_q <= {STQ_IW{1'b0}};
            stx_va_q  <= 32'h0; stx_ctx_q <= 4'h0;
            fwdp_v <= 1'b0; fwdp_rob <= {ROB_IDX_W{1'b0}}; fwdp_ep <= {`BACK2_EPOCH_W{1'b0}};
            fwdp_di <= 1'b0; fwdp_df <= 1'b0; fwdp_pi <= {PDW_I{1'b0}};
            fwdp_pf <= {PDW_F{1'b0}}; fwdp_data <= 32'h0; fwdp_size <= 3'h0;
            fwdp_off <= 2'h0; fwdp_uns <= 1'b0;
            for (si = 0; si < STQ_N; si = si + 1) begin
                stq_v[si] <= 1'b0; stq_av[si] <= 1'b0; stq_dv[si] <= 1'b0;
                stq_a[si] <= 32'h0; stq_d[si] <= 32'h0; stq_msk[si] <= 4'h0;
                stq_rob[si] <= {ROB_IDX_W{1'b0}}; stq_ret[si] <= 1'b0;
                stq_pa[si] <= 32'h0; stq_pv[si] <= 1'b0; stq_ctx[si] <= 4'h0;
                stq_bad[si] <= 1'b0;
            end
            for (si = 0; si < OUT_N; si = si + 1) begin
                ld_v[si] <= 1'b0; ld_req[si] <= 1'b0; ld_dn[si] <= 1'b0; ld_ex[si] <= 1'b0;
                ld_rob[si] <= {ROB_IDX_W{1'b0}};
                ld_ep[si] <= {`BACK2_EPOCH_W{1'b0}}; ld_di[si] <= 1'b0; ld_df[si] <= 1'b0;
                ld_pi[si] <= {PDW_I{1'b0}}; ld_pf[si] <= {PDW_F{1'b0}};
                ld_addr[si] <= 32'h0; ld_size[si] <= 3'h0; ld_uns[si] <= 1'b0;
                ld_hm[si] <= 4'h0; ld_hd[si] <= 32'h0; ld_tag[si] <= {TAG_W{1'b0}};
            end
        end else if (flush_all) begin
            //   ★★ (b) 收口（本段实测根因，报告 §B4.25）：**已提交 store 的 CDQ 入队
            //     不受整机冲刷影响**。
            //     现象：p13 的 PTE 更新 store 与 `sfence.vma` **同组提交**，提交拍
            //     `be_trp_flush/flush_all=1` ⇒ 旧实现直接走本分支 ⇒ **整个 §4.5 入队被跳过**
            //     （`dr_take` 组合为 1 但 `cdq_cnt/cdq_tail` 不动，实测 t=13512
            //      `take=0001` → t=13513 `cnt=0 t=7`）⇒ 已提交写**从未落地**、`l1[0]` 永为旧 PTE。
            //     论证：`dr_valid`（`backend_top` 的 `cmt_st_drain & ~cmt_hold_w`）在本拍为 1
            //     意味着该 store **已在提交前缀链内**（= 架构上已提交）⇒ 它的写**必须可见**，
            //     与本拍是否同时冲刷无关（`cmt_st_drain` 本身不含任何 flush 门）。
            //     做法：本分支**照做入队**（拷贝读的是本拍仍有效的 STQ 寄存器态 ✓），
            //     然后照旧清 STQ/LQ（已提交项的数据已随 CDQ 带走 ⇒ 不丢）。
            for (si = 0; si < W; si = si + 1) begin
                if (dr_take[si]) begin
                    cdq_v  [cdq_wp[si]] <= 1'b1;
                    cdq_idx[cdq_wp[si]] <= dr_idx[si*STQ_IW +: STQ_IW];
                    cdq_a  [cdq_wp[si]] <= stq_a  [dr_idx[si*STQ_IW +: STQ_IW]];
                    //   PA 判定口径与 §4.5 正常分支**逐字相同**（提交拍权威；见 §3.4 头注）
                    cdq_pa [cdq_wp[si]] <= stx_en_w ? stq_pa [dr_idx[si*STQ_IW +: STQ_IW]]
                                                    : stq_a  [dr_idx[si*STQ_IW +: STQ_IW]];
                    cdq_pv [cdq_wp[si]] <= ~stx_en_w |
                                           (stq_pv[dr_idx[si*STQ_IW +: STQ_IW]] &
                                            (stq_ctx[dr_idx[si*STQ_IW +: STQ_IW]] == st_xlate_ctx));
                    cdq_bad[cdq_wp[si]] <= 1'b0;
                    cdq_ctx[cdq_wp[si]] <= st_xlate_ctx;
                    cdq_d  [cdq_wp[si]] <= stq_d  [dr_idx[si*STQ_IW +: STQ_IW]];
                    cdq_m  [cdq_wp[si]] <= stq_msk[dr_idx[si*STQ_IW +: STQ_IW]];
                end
            end
            if (dr_push_n != {(CDQ_PW+1){1'b0}}) begin
                cdq_tail <= cdq_tail + dr_push_n[CDQ_PW-1:0];
                cdq_cnt  <= cdq_cnt + dr_push_n;
            end
            //   注意：本分支**不**推进 CDQ 出队（下拍照常，`dr_fire` 侧不受影响）——
            //   代价至多 1 拍，换取"最小改动 + 不触碰排空握手"。
            for (si = 0; si < STQ_N; si = si + 1) begin
                stq_v[si] <= 1'b0; stq_av[si] <= 1'b0; stq_dv[si] <= 1'b0; stq_ret[si] <= 1'b0;
            end
            for (si = 0; si < OUT_N; si = si + 1) begin
                ld_v[si] <= 1'b0; ld_req[si] <= 1'b0; ld_dn[si] <= 1'b0; ld_ex[si] <= 1'b0;
            end
            stq_head_q <= {STQ_IW{1'b0}};
            stq_tail_q <= {STQ_IW{1'b0}};
            fwdp_v <= 1'b0;
            //   ★★ (b)：`flush_all` **不清** 在途翻译状态（`stx_act_q/...`）——
            //     被冲刷的那笔翻译可以无害地跑完（STQ 写回有 `stq_v & ~stq_pv` 门，见 §4.5b），
            //     而"已提交但 PA 未到"的项仍靠 **CDQ 源扫描**完成翻译并排空（活性保证）✓。
            //     注意：CDQ 本身不受 `flush_all` 影响（既有设计口径，见 §3.3 头注）✓。
        end else begin
            // ---- 4.1 默认：清全转发直通项 ----
            fwdp_v <= 1'b0;

            // ---- 4.2 派发分配（store 项）----
            if (alloc_ok) begin
                for (si = 0; si < W; si = si + 1) begin
                    if (alloc_valid[si]) begin
                        stq_v  [alloc_idx[si*STQ_IW +: STQ_IW]] <= 1'b1;
                        stq_av [alloc_idx[si*STQ_IW +: STQ_IW]] <= 1'b0;
                        stq_dv [alloc_idx[si*STQ_IW +: STQ_IW]] <= 1'b0;
                        stq_ret[alloc_idx[si*STQ_IW +: STQ_IW]] <= 1'b0;
                        //   ★★ (b)：新项尚无 PA（需翻译时必须等 `st_xlate_done`）；
                        //     `stq_pa/stq_pv` 的真正判定在 E1（§4.3）—— 分配期只清状态。
                        stq_pa [alloc_idx[si*STQ_IW +: STQ_IW]] <= 32'h0;
                        stq_pv [alloc_idx[si*STQ_IW +: STQ_IW]] <= 1'b0;
                        stq_ctx[alloc_idx[si*STQ_IW +: STQ_IW]] <= 4'h0;
                        stq_bad[alloc_idx[si*STQ_IW +: STQ_IW]] <= 1'b0;
                        //   ★★ 2B-3 第 6 段第二步（报告 §B3.6.4 的必办项）：ROB 索引在
                        //     **分配期**即写入 ⇒ `stq_rob` 从这一刻起就是真年龄。
                        //     旧实现在 E1 才写 ⇒ "已分配未执行"的 store 里是上一占用者的
                        //     陈旧值 ⇒ `any_unk_w`（B28 保守闸门）判错年龄。
                        stq_rob[alloc_idx[si*STQ_IW +: STQ_IW]] <=
                                alloc_rob[si*ROB_IDX_W +: ROB_IDX_W];
                    end
                end
            end

            // ---- 4.2b D3 派发：为 load 分配 LQ 项（★ 2B-4 第二步：槽位程序序）----
            //   只写"归属/占用"：`ld_rob`（提交点释放的年龄依据）、`ld_ex=0`、
            //   请求/完成标志清零；地址/掩码/转发信息等 E1（§4.3）再填。
            if (lalloc_ok) begin
                for (si = 0; si < W; si = si + 1) begin
                    if (lalloc_valid[si]) begin
                        ld_v  [lalloc_idx[si*LQ_IW +: LQ_IW]] <= 1'b1;
                        ld_ex [lalloc_idx[si*LQ_IW +: LQ_IW]] <= 1'b0;
                        ld_req[lalloc_idx[si*LQ_IW +: LQ_IW]] <= 1'b0;
                        ld_dn [lalloc_idx[si*LQ_IW +: LQ_IW]] <= 1'b0;
                        ld_rob[lalloc_idx[si*LQ_IW +: LQ_IW]] <=
                                lalloc_rob[si*ROB_IDX_W +: ROB_IDX_W];
                    end
                end
            end

            // ---- 4.3 E1 ----
            if (exe_valid && exe_is_store) begin
                stq_av[exe_stq_idx]  <= 1'b1;
                stq_dv[exe_stq_idx]  <= 1'b1;
                stq_a[exe_stq_idx]   <= exe_addr;                        // ★ VA（转发/翻译源）
                //   ★★ (b)：PA 化在 **E1 这一拍**定夺（§B4.24.9 简化 ③"不需要新增
                //     '何时翻译'的判据"）：
                //       · `st_xlate_en=0`（Bare / M 模式且未置 MPRV）⇒ VA=PA，**立即可排空**；
                //       · `st_xlate_en=1` ⇒ `stq_pv=0`，由 §3.4 的引擎发翻译请求，
                //         `st_xlate_done` 拍写回 `stq_pa` 并置 `stq_pv=1`。
                //     这一步正是"排空期在途翻译"缺陷的消除点：PA 在**执行期**定下来，
                //     排空只搬 PA，不再依赖维护/冲刷时刻的翻译状态。
                stq_pa[exe_stq_idx]  <= exe_addr;
                stq_pv[exe_stq_idx]  <= ~stx_en_w;
                stq_ctx[exe_stq_idx] <= st_xlate_ctx;
                stq_bad[exe_stq_idx] <= 1'b0;
                stq_d[exe_stq_idx]   <= exe_wdata << {exe_addr[1:0], 3'b000};
                stq_msk[exe_stq_idx] <= lmask_w;
                //   `stq_rob` 已在**分配期**写入（§4.2）⇒ 此处不再重复写（唯一写点纪律）。
                //   实测语义：分配期写入的 rob == 该 store 的 E1 rob（同一 ROB 项）。
                cnt_st_q <= cnt_st_q + 32'd1;
                if (any_unk_w) cnt_stall_q <= cnt_stall_q + 32'd1;
            end else if (exe_valid) begin
                cnt_ld_q <= cnt_ld_q + 32'd1;
                if (|fwd_hit_w) cnt_fwd_q <= cnt_fwd_q + 32'd1;
                if (fwd_all_w) begin
                    // 全字节转发 ⇒ 不占表项、不访存，次拍写回
                    fwdp_v    <= 1'b1;
                    fwdp_rob  <= exe_rob;
                    fwdp_ep   <= exe_epoch;
                    fwdp_di   <= exe_dst_i;
                    fwdp_df   <= exe_dst_f;
                    fwdp_pi   <= exe_pdest_i;
                    fwdp_pf   <= exe_pdest_f;
                    fwdp_data <= fwd_data_w;
                    fwdp_size <= exe_size;
                    fwdp_off  <= exe_addr[1:0];
                    fwdp_uns  <= exe_unsign;
                end else begin
                    //   ★ 2B-4：槽号来自**派发期**（`exe_lq_idx`），不再是 E1 现选的 `newslot`；
                    //     全转发的那条在 E1 当拍就把槽还回去（它不需要访存，也不参与提交释放）。
                    ld_v   [exe_lq_idx] <= ~fwd_all_w;
                    ld_ex  [exe_lq_idx] <= ~fwd_all_w;
                    ld_req [exe_lq_idx] <= 1'b0;
                    ld_dn  [exe_lq_idx] <= 1'b0;
                    ld_rob [exe_lq_idx] <= exe_rob;
                    ld_ep  [exe_lq_idx] <= exe_epoch;
                    ld_di  [exe_lq_idx] <= exe_dst_i;
                    ld_df  [exe_lq_idx] <= exe_dst_f;
                    ld_pi  [exe_lq_idx] <= exe_pdest_i;
                    ld_pf  [exe_lq_idx] <= exe_pdest_f;
                    ld_addr[exe_lq_idx] <= exe_addr;
                    ld_size[exe_lq_idx] <= exe_size;
                    ld_uns [exe_lq_idx] <= exe_unsign;
                    ld_hm  [exe_lq_idx] <= fwd_hit_w;
                    ld_hd  [exe_lq_idx] <= fwd_data_w;
                    //   ★ 槽号是 LQ_IW bit（LQ 32 ⇒ 5 bit）⇒ 必须零扩展到 TAG_W=6；
                    //     写 [TAG_W-1:0] 会取到向量外的位 ⇒ tag 为 **x** ⇒ 响应无法匹配（挂死）。
                    //     最高位恒 0 ⇒ 与 store 排空的"全 1"标签天然不撞车。
                    ld_tag [exe_lq_idx] <= {{(TAG_W-LQ_IW){1'b0}}, exe_lq_idx};
                end
            end

            // ---- 4.4 请求 / 响应推进 ----
            //   ★ 2B-3 第 5 段曾按**响应到达**释放 load 槽（修掉"槽永不释放 ⇒ 挂死"），
            //     第 6 段第二步改为真 LSQ 语义：**响应到达只标记 `ld_dn`（数据已齐），
            //     槽本身留到该 load 按程序序提交时释放**（§4.4b）。`ld_dn` 一旦置位，
            //     该项即退出请求口（`pend_vec`）与响应匹配（`rsp_vec` 要 `ld_req`）⇒
            //     写回只发生一次、不会被后到的响应重复触发。
            if (ld_fire) ld_req[pend_sel] <= 1'b1;
            if (rsp_ok) begin
                ld_req[rsp_sel] <= 1'b0;
                ld_dn [rsp_sel] <= 1'b1;
            end
            // ---- 4.4b 提交点释放（LQ 项；★ 2B-3 第 6 段第二步）----
            //   释放条件：该 LQ 项的 ROB 索引落在**本拍提交组** [head, head+cmt_n) 内。
            //   依据：提交组恒为"从 ROB 头起的连续若干项"（rob.v 的前缀链），故用**窗口算术**
            //   `(ld_rob - rob_head) & 7'h7F < cmt_n` 判定（禁掩码写法，B27 口径）；
            //   释放是**幂等**的：不在窗口内的项保持占用，写回后的项靠 `ld_dn` 与请求口隔离。
            //   `cmt_n` 由 backend_top 按 `cmt_ok`（非 squash/flush）门控后送入 ⇒ 冲刷拍恒 0。
            for (si = 0; si < OUT_N; si = si + 1) begin
                if (ld_v[si] & (((ld_rob[si] - rob_head) & 7'h7F) < {5'b0, cmt_n})) begin
                    ld_v  [si] <= 1'b0;
                    ld_req[si] <= 1'b0;
                    ld_dn [si] <= 1'b0;
                    ld_ex [si] <= 1'b0;
                end
            end
            // ---- 4.5 提交排空：入队（全组）→ 出队（逐拍一笔）→ STQ 项回收 ----
            //   ★ 入队与出队在**同一拍**都可能发生：`cdq_cnt` 必须用一条赋值合并，
            //     否则后一条赋值会把前一条顶掉（净计数错 ⇒ 队空/队满判据失效）。
            for (si = 0; si < W; si = si + 1) begin
                if (dr_take[si]) begin
                    cdq_v  [cdq_wp[si]] <= 1'b1;
                    cdq_idx[cdq_wp[si]] <= dr_idx[si*STQ_IW +: STQ_IW];
                    cdq_a  [cdq_wp[si]] <= stq_a  [dr_idx[si*STQ_IW +: STQ_IW]];
                    //   ★★ (b)：PA 三件套随提交拷贝（与 `cdq_a/d/m` 同构），且**提交拍口径
                    //     为权威**（§3.4 头注）：
                    //       · 提交拍 `st_xlate_en=0`（Bare / M 模式）⇒ PA = **VA**（`stq_a`），
                    //         `cdq_pv=1` —— 无条件覆盖 E1 预翻译结果；
                    //       · 提交拍需翻译且 E1 预翻译成功、**上下文一致** ⇒ 沿用 `stq_pa`；
                    //       · 否则 `cdq_pv=0` ⇒ 由 §3.4 的 CDQ 扫描用 `cdq_ctx` 重译。
                    cdq_pa [cdq_wp[si]] <= stx_en_w ? stq_pa [dr_idx[si*STQ_IW +: STQ_IW]]
                                                    : stq_a  [dr_idx[si*STQ_IW +: STQ_IW]];
                    cdq_pv [cdq_wp[si]] <= ~stx_en_w |
                                           (stq_pv[dr_idx[si*STQ_IW +: STQ_IW]] &
                                            (stq_ctx[dr_idx[si*STQ_IW +: STQ_IW]] == st_xlate_ctx));
                    cdq_bad[cdq_wp[si]] <= 1'b0;      // 坏位只由 **CDQ 源**翻译故障置位
                    cdq_ctx[cdq_wp[si]] <= st_xlate_ctx;
                    cdq_d  [cdq_wp[si]] <= stq_d  [dr_idx[si*STQ_IW +: STQ_IW]];
                    cdq_m  [cdq_wp[si]] <= stq_msk[dr_idx[si*STQ_IW +: STQ_IW]];
                end
            end
            if (dr_push_n != {(CDQ_PW+1){1'b0}}) cdq_tail <= cdq_tail + dr_push_n[CDQ_PW-1:0];
            if (dr_fire) begin
                cdq_v[cdq_head] <= 1'b0;
                cdq_pv[cdq_head] <= 1'b0;      // （同拍入队不会撞队头：见 §3.4 的 `cdq_wp` 论证）
                cdq_bad[cdq_head] <= 1'b0;
                cdq_head        <= cdq_head + 1'b1;
            end
            cdq_cnt <= cdq_cnt + dr_push_n - {{CDQ_PW{1'b0}}, dr_fire};
            //   队头回收：已排空（stq_ret）或已作废（冲刷/未执行前被清）⇒ 指针前移。
            //   ★ 若本拍分配器正好要写队头槽（队头无效时才可能），本拍不回收，
            //     否则会把新项顶掉（下拍再回收，不会饿死）。
            if (dr_fire) stq_ret[dr_sel] <= 1'b1;
            if (!alloc_hits_head && (!stq_v[stq_head_q] | stq_ret[stq_head_q])) begin
                stq_v[stq_head_q] <= 1'b0;
                stq_head_q <= stq_head_q + 1'b1;
            end

            // ---- 4.5b ★★ (b) 执行期翻译握手（请求保持 → 接受锁存 → done 写回 PA）----
            if (stx_accept_w) begin
                stx_act_q <= 1'b1;
                stx_idx_q <= stx_sel_idx;
                stx_va_q  <= stx_sel_va;
                stx_ctx_q <= stx_sel_ctx;
                stx_src_q <= stx_sel_src;
            end else if (stx_done_w) begin
                stx_act_q <= 1'b0;
            end
            if (stx_done_w) begin
                if (stx_src_q == 1'b0) begin
                    //   STQ 源（E1 预翻译 / 提交窗扫描）：成功则记 PA **并记下本次用的上下文**
                    //   （提交门按"上下文是否仍一致"判是否需要用新上下文重译）；
                    //   故障 ⇒ 仅在**提交窗内**时判坏（`stq_bad` ⇒ 精确陷阱 + 解提交阻塞），
                    //   窗口外（投机）不判坏、留待进窗后重译（避免用偏旧上下文打投机异常）。
                    if (stq_v[stx_idx_q] & ~stq_ret[stx_idx_q]) begin
                        if (stx_flt_w) begin
                            if (stq_win_w[stx_idx_q]) stq_bad[stx_idx_q] <= 1'b1;
                        end else if (~stq_pv[stx_idx_q]) begin
                            stq_pa [stx_idx_q] <= st_xlate_pa;
                            stq_pv [stx_idx_q] <= 1'b1;
                            stq_ctx[stx_idx_q] <= stx_ctx_q;
                        end else if (stq_ctx[stx_idx_q] != stx_ctx_q) begin
                            //   重译（新上下文）：覆盖既有 PA
                            stq_pa [stx_idx_q] <= st_xlate_pa;
                            stq_ctx[stx_idx_q] <= stx_ctx_q;
                        end
                    end
                end else begin
                    //   CDQ 源（**提交拍口径**）：`stx_idx_q` 即 CDQ **阵列下标** —— 该下标在
                    //   在途期间稳定（`cdq_pv=0` ⇒ 不会被弹出，故不会被新入队覆盖）；
                    //   故障此时才作废（`cdq_bad` ⇒ 只弹出、不写，排空不悬挂）。
                    if (cdq_v[stx_idx_q] & ~cdq_pv[stx_idx_q]) begin
                        cdq_pa [stx_idx_q] <= st_xlate_pa;
                        cdq_pv [stx_idx_q] <= ~stx_flt_w;
                        cdq_bad[stx_idx_q] <=  stx_flt_w;
                    end
                end
            end

            // ---- 4.6 冲刷 ----
            if (squash) begin
                for (si = 0; si < STQ_N; si = si + 1) begin
                    if (stq_v[si] &&
                        (((stq_rob[si] - rob_head) & 7'h7F) > ((squash_idx - rob_head) & 7'h7F)))
                        stq_v[si] <= 1'b0;
                end
                for (si = 0; si < OUT_N; si = si + 1) begin
                    if (ld_v[si] &&
                        (((ld_rob[si] - rob_head) & 7'h7F) > ((squash_idx - rob_head) & 7'h7F))) begin
                        ld_v[si]   <= 1'b0;
                        ld_req[si] <= 1'b0;
                        ld_dn[si]  <= 1'b0;
                        ld_ex[si]  <= 1'b0;
                    end
                end
            end
        end
    end

    assign cnt_load_o    = cnt_ld_q;
    assign cnt_store_o   = cnt_st_q;
    assign cnt_fwd_o     = cnt_fwd_q;
    assign cnt_stq_stall_o = cnt_stall_q;


    // ---- 诊断打印（DBG=1；默认 0 ⇒ 无输出）----
    integer dl;
    always @(posedge clk) begin
        if (DBG && rst_n) begin
            //   ★ B28 判别探针：计数器 + STQ 逐项转储（v/av/dv/msk/a/d/rob）
            $display("[lsu-dbg %m] cnt_ld=%0d cnt_st=%0d cnt_fwd=%0d cnt_stall=%0d stq_head=%0d any_unk=%b iss_ok=%b",
                     cnt_ld_q, cnt_st_q, cnt_fwd_q, cnt_stall_q, stq_head_q, any_unk_w, iss_ok);
            for (dl = 0; dl < STQ_N; dl = dl + 1)
                if (stq_v[dl])
                    $display("[lsu-dbg %m] stq[%0d] v=%b av=%b dv=%b msk=%b a=0x%08x d=0x%08x rob=%0d ret=%b",
                             dl, stq_v[dl], stq_av[dl], stq_dv[dl], stq_msk[dl],
                             stq_a[dl], stq_d[dl], stq_rob[dl], stq_ret[dl]);
            for (dl = 0; dl < OUT_N; dl = dl + 1)
                if (ld_v[dl])
                    $display("[lsu-dbg %m] ld slot=%0d req=%b tag=%0d rob=%0d ep=%0d addr=0x%08x",
                             dl, ld_req[dl], ld_tag[dl], ld_rob[dl], ld_ep[dl], ld_addr[dl]);
            $display("[lsu-dbg %m] pend_any=%b rsp_ok=%b dr_any=%b rspv=%b rsp_tag=%0d stq_head=%0d",
                     pend_any, rsp_ok, dr_any, mem_rsp_valid, mem_rsp_tag, stq_head_q);
            //   ★ B28 判别探针：E1 当拍信息 + pending 槽对每个 STQ 项的**命中条件分解**
            $display("[lsu-dbg %m] E1 exe_valid=%b is_store=%b rob=%0d addr=0x%08x size=%0d | fwd_hit=%b fwd_all=%b lmask=%b lq_idx=%0d",
                     exe_valid, exe_is_store, exe_rob, exe_addr, exe_size,
                     fwd_hit_w, fwd_all_w, lmask_w, exe_lq_idx);
            if (pend_any) begin
                $display("[lsu-dbg %m] PEND sel=%0d addr=0x%08x size=%0d rob=%0d rob_head=%0d age_l=%0d",
                         pend_sel, ld_addr[pend_sel], ld_size[pend_sel], ld_rob[pend_sel],
                         rob_head, ((ld_rob[pend_sel] - rob_head) & 7'h7F));
                for (dl = 0; dl < STQ_N; dl = dl + 1)
                    if (stq_v[dl])
                        $display("[lsu-dbg %m]   stq[%0d] av=%b msk=%b a=0x%08x age_s=%0d addr_eq=%b mskhit=%b age_lt=%b",
                                 dl, stq_av[dl], stq_msk[dl], stq_a[dl],
                                 ((stq_rob[dl] - rob_head) & 7'h7F),
                                 (stq_a[dl][31:2] == ld_addr[pend_sel][31:2]),
                                 stq_msk[dl][ld_addr[pend_sel][1:0]],
                                 (((stq_rob[dl] - rob_head) & 7'h7F) <
                                  ((ld_rob[pend_sel] - rob_head) & 7'h7F)));
            end
        end
    end

endmodule
