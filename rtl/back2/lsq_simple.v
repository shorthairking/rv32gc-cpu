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
    reg  [31:0]          stq_a   [0:STQ_N-1];        // ★ 物理地址（唯一来源）
    reg  [31:0]          stq_d   [0:STQ_N-1];        // 已对位到字内字节道
    reg  [3:0]           stq_msk [0:STQ_N-1];
    reg  [ROB_IDX_W-1:0] stq_rob [0:STQ_N-1];
    reg                  stq_ret [0:STQ_N-1];
    reg  [STQ_IW-1:0]    stq_head_q, stq_tail_q;

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
    reg  [31:0]       cdq_a   [0:CDQ_N-1];
    reg  [31:0]       cdq_d   [0:CDQ_N-1];
    reg  [3:0]        cdq_m   [0:CDQ_N-1];
    reg  [CDQ_N-1:0]  cdq_v;
    reg  [CDQ_PW:0]   cdq_cnt;
    reg  [CDQ_PW-1:0] cdq_head, cdq_tail;

    //   入队许可：余量 ≥ 一整组（W 笔）——保守，且与"本拍出队释放 1 项"无关（无环）
    assign dr_room_ok = ((CDQ_N[CDQ_PW:0]) - cdq_cnt) >= W[CDQ_PW:0];
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

    //   出队：队首一笔；`dr_fire` = 与存储口的握手拍
    wire              dr_any  = (cdq_cnt != {(CDQ_PW+1){1'b0}});
    //   ★ 发射许可 = 无更老未定址 store 且 **CDQ 已排空**（口径见上）
    assign iss_ok = ~any_unk_w;                 // （"CDQ 空"的门控改由顶层在冲刷侧做，见 dr_empty_o）
    assign dr_empty_o = ~dr_any;
    wire [STQ_IW-1:0] dr_sel  = cdq_idx[cdq_head];
    wire              dr_fire = dr_any & mem_req_ready;
    wire              ld_fire = pend_any & ~dr_any & mem_req_ready;

    assign mem_req_valid = dr_fire | ld_fire;
    assign mem_req_wen   = dr_fire;
    assign mem_req_addr  = dr_fire ? cdq_a[cdq_head]   : ld_addr[pend_sel];
    assign mem_req_wdata = dr_fire ? cdq_d[cdq_head]   : 32'h0;
    assign mem_req_wstrb = dr_fire ? cdq_m[cdq_head]   : 4'h0;
    assign mem_req_tag   = dr_fire ? {TAG_W{1'b1}}     : ld_tag[pend_sel];

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
    assign wb_dst_i   = fwdp_v ? fwdp_di   : ld_di[rsp_sel];
    assign wb_dst_f   = fwdp_v ? fwdp_df   : ld_df[rsp_sel];
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
            fwdp_v <= 1'b0; fwdp_rob <= {ROB_IDX_W{1'b0}}; fwdp_ep <= {`BACK2_EPOCH_W{1'b0}};
            fwdp_di <= 1'b0; fwdp_df <= 1'b0; fwdp_pi <= {PDW_I{1'b0}};
            fwdp_pf <= {PDW_F{1'b0}}; fwdp_data <= 32'h0; fwdp_size <= 3'h0;
            fwdp_off <= 2'h0; fwdp_uns <= 1'b0;
            for (si = 0; si < STQ_N; si = si + 1) begin
                stq_v[si] <= 1'b0; stq_av[si] <= 1'b0; stq_dv[si] <= 1'b0;
                stq_a[si] <= 32'h0; stq_d[si] <= 32'h0; stq_msk[si] <= 4'h0;
                stq_rob[si] <= {ROB_IDX_W{1'b0}}; stq_ret[si] <= 1'b0;
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
            for (si = 0; si < STQ_N; si = si + 1) begin
                stq_v[si] <= 1'b0; stq_av[si] <= 1'b0; stq_dv[si] <= 1'b0; stq_ret[si] <= 1'b0;
            end
            for (si = 0; si < OUT_N; si = si + 1) begin
                ld_v[si] <= 1'b0; ld_req[si] <= 1'b0; ld_dn[si] <= 1'b0; ld_ex[si] <= 1'b0;
            end
            stq_head_q <= {STQ_IW{1'b0}};
            stq_tail_q <= {STQ_IW{1'b0}};
            fwdp_v <= 1'b0;
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
                stq_a[exe_stq_idx]   <= exe_addr;                        // 物理地址唯一来源
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
                    cdq_d  [cdq_wp[si]] <= stq_d  [dr_idx[si*STQ_IW +: STQ_IW]];
                    cdq_m  [cdq_wp[si]] <= stq_msk[dr_idx[si*STQ_IW +: STQ_IW]];
                end
            end
            if (dr_push_n != {(CDQ_PW+1){1'b0}}) cdq_tail <= cdq_tail + dr_push_n[CDQ_PW-1:0];
            if (dr_fire) begin
                cdq_v[cdq_head] <= 1'b0;
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
