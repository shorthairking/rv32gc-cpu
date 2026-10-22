//==============================================================================
// rtl/back2/rob.v —— 重排序缓冲（ROB，ROB_N 项；★ L3 由 128 降为 64）：顺序提交 ≤4 条/拍 + 精确异常
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §2.1（字段与环形组织）、§2.2（顺序提交关键路径：
//         ① !done 必须停 ② 异常在头部精确触发 ③ 提交宽度是上限）、§8.1（E1/E2/E3 精确性
//         要点）、§8.2（epoch）；
//         docs/design/02-pipeline.md §3.7（D3 派发：ROB 余量不足 ⇒ 整块停顿 S5）、
//         §3.11（W1 提交）、§5（衔接硬规则 1：ROB 项连续分配）。
//
// 【组织】环形缓冲：head = 提交点、tail = 派发点；`cnt_q` = 有效项数（0..ROB_N）。
//   · 项有效性由 (idx - head) mod ROB_N < cnt 派生（★ L3：ROB_IDX_W 恒 == log2(ROB_N)） ⇒ **不需要 valid 位数组**，冲刷只需
//     改 cnt（03 §8.1 E6 的"分布式删除"问题的 ROB 侧解法）。
//   · `done` 位由各写回口置位；非法项由 ALU0 以 no-op 执行后置位（保证头部不会永久卡住）。
//   · `exc != 0` 的项到达头部 ⇒ 本拍不提交、拉高 trap_valid（精确异常点）。
//   · store 项在头部提交时**同时**向简化访存队列发排空（本里程碑口径：store 只在提交后
//     写存储，保证异常回滚不会双重写，03 §6.2/§9）。
//
// 【载荷】每项 = BACK2_RB_W 位打包向量（`back2_params.vh` §2 为唯一布局真源）：
//   ★★ C4（416→229 bit；★ EXP-R2 再 229→225）：只保留「rob.v 自己 + 提交路径 + `pack_nq`
//   重建 nq」真正读的位；
//     旧的 uop(304) 全量副本（其中 IMM/ARND/源物理号/控制码/TVAL 重复副本…）与 CSRW(32)
//     全部删除。字段表与逐字段证据见 `back2_params.vh` §2 的 C4 段注释。
//
// ★★ EXP-B（架构 v0.1 §16–§21）：**可更新字段从"一张 102 bit 多写源表 `updq`"拆成
//    三张"每表单写源"typed 表**：
//      · `br_q`（分支结果：taken + tgt）  —— 唯一写源 **BRU**（`upd_tr`）
//      · `ff_q`（FP flags[4:0]）           —— 唯一写源 **FPU**（`upd_ff`）
//      · `ex_q`（异常 TVAL[31:0]）         —— 唯一写源 **LSU**（`upd_exc`）
//      · 死口 `upd_csr` 整条删除（动态实测恒 0）；CSR 提交期源改从载荷 `uop.PS1I` 取。
//    每表自带 {valid, epoch}（epoch 复用项内 2 bit 口径）：提交/陷阱时
//    `valid && epoch == 项内 epoch` 才采用 ⇒ flush/squash 不必清 64 项（旧项天然作废）。
//    对外接口（`cmt_payload`/`cmt_narrow`/`cmt_st_*`/`trap_*`/`csr_pay`）**逐位不变**。
//    动态依据：`upd_tr/ff/exc` 同拍并发 ≥2 仅 0.02%（3 拍）、`upd_csr_valid` 恒 0
//    （docs/design/10-dynamic-behavior.md §1.3）。
//
// ★★ EXP-N3（本轮 A 优先级，answer.md §五）：**头部退休窗口 8 槽 → `WIN_N = 2` 项（lane 对齐）**：
//     · 事实依据：提交宽度已是 `COMMIT_W = 2` ⇒ 每拍只消费 2 项（`slot_ok[gi]` 只看 `head+gi`），
//       原 8 槽窗口（槽号 = `idx[2:0]`）里其余 6 项**从不被任何 lane 读**；
//     · 新口径：**槽号 = 组内 lane 号**（槽 0 = 预测的下一拍 head、槽 1 = head+1）
//       ⇒ 提交读 `win_rd[gi] = win_q[gi]` **零 mux**（原 2 lane × 8:1 × RB_W 读 mux 整体消失）；
//     · 预取读侧仍 = 4 bank（PF_W=4，**不是**浪费）：BRAM 写侧 4 口按 `bank = idx[1:0]` bank 化
//       ⇒ 读口必须也是 4 个 bank；且"读命令 T 拍发出、数据 T+1 拍到、填窗在 T+1→T+2 沿"
//       意味着填窗目标（T+2 的 head = 本拍 `hpred`）与读命令基址（T 拍 `hpred`）相差
//       `cmt_n ∈ {0,1,2}` ⇒ 只能一次读回 4 个连续项再把其中 2 项选进窗口（2 个 4:1 选择）。
//     · 语义等价保障：全索引标签 + valid 命中判定保留（失配 ⇒ 插气泡，绝不交付错数据）、
//       `read_first` 同址危险丢弃保留、`flush_all` 清窗保留、`squash_valid` 拍**不覆盖**
//       （该拍 head 不前进 ⇒ 旧窗口内容仍是下一拍的正确组）。
//
// 风格  : 组合逻辑全部 `assign`/函数（红线 3）；always 块只用于存储体与指针（时序元件）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module rob #(
    parameter integer ROB_N      = `BACK2_ROB_N,
    parameter integer ROB_IDX_W  = `BACK2_ROB_IDX_W,
    //   ★★ EXP-N1：**分配宽度与提交宽度彻底分离**（原来两者共用 `COMMIT_W`）。
    //     · ALLOC_W  = 派发/分配宽度（4，保持不动）——决定 `alloc_*` 口与 BRAM 写口数；
    //     · COMMIT_W = 提交/退休宽度（2）——决定退休选择/前缀链/架构更新/输出口宽度。
    //     两者分离后"4 发射 + 2 提交"在结构上才成立（只改一个共用宏无法表达）。
    parameter integer ALLOC_W    = `BACK2_ALLOC_W,
    parameter integer COMMIT_W   = `BACK2_COMMIT_W,
    parameter integer RB_W       = `BACK2_RB_W,
    parameter integer WB_N       = `BACK2_WB_N,
    parameter integer DBG_CSR    = 0        // B29 定案探针
) (
    input  wire                    clk,
    input  wire                    rst_n,

    //==================================================================
    // 派发（D3）：连续 ALLOC_W 项（lane 0 最老）
    //   ★★ EXP-N1：本组口的宽度是 **ALLOC_W**（= 4，派发宽度未变），不是 COMMIT_W。
    //==================================================================
    input  wire                    alloc_valid,
    input  wire [2:0]              alloc_n,          // 1..ALLOC_W
    output wire                    alloc_ready,      // 余量 ≥ alloc_n
    output wire [ROB_IDX_W-1:0]    alloc_idx0,       // 本块首项索引
    input  wire [ALLOC_W-1:0]      alloc_lane_valid,
    input  wire [ALLOC_W*RB_W-1:0] alloc_payload,
    input  wire [`BACK2_EPOCH_W-1:0] alloc_epoch,     // 本块分配时的流世代（存入项内）

    //==================================================================
    // 完成（写回口）：置 done
    //==================================================================
    input  wire [WB_N-1:0]                 wb_valid,
    input  wire [WB_N*ROB_IDX_W-1:0]       wb_rob_idx,
    input  wire [WB_N*`BACK2_EPOCH_W-1:0]  wb_epoch,     // §8.2 epoch：过期写回不得置 done

    //==================================================================
    // 执行期字段回写（每张 typed 表**恰好一个写源**；本里程碑够用）
    //   ★ EXP-B：原 `upd_csr_*` 三口已删（`backend_top.v` 早已硬接 1'b0；动态实测恒 0）
    //==================================================================
    input  wire                    upd_tr_valid,
    input  wire [ROB_IDX_W-1:0]    upd_tr_idx,
    input  wire                    upd_tr_taken,
    input  wire [31:0]             upd_tr_target,
    input  wire                    upd_ff_valid,
    input  wire [ROB_IDX_W-1:0]    upd_ff_idx,
    input  wire [4:0]              upd_ff_flags,
    input  wire                    upd_exc_valid,
    input  wire [ROB_IDX_W-1:0]    upd_exc_idx,
    input  wire [3:0]              upd_exc_code,
    input  wire [31:0]             upd_exc_tval,

    //==================================================================
    // 提交（W1）：环境（存储排空口可发射 ⇒ store 才能提交）
    //==================================================================
    input  wire                    mem_wr_ready,
    output wire [COMMIT_W-1:0]     cmt_valid,        // 本拍按程序序提交的槽（前缀连续）
    output wire [COMMIT_W*RB_W-1:0] cmt_payload,
    //   ★★ 2B-5 第 3 步①（窄位先行）：**每 lane 的窄控制字**（组合读、零延迟）
    //     —— 供第 2/3 步把宽字段改成 BRAM 同步读（+1 拍）后，提交决策/前缀链/排空选择
    //     等**延迟敏感路径**仍走 FF 组合读。
    output wire [COMMIT_W*NQ_W-1:0] cmt_narrow,
    //   ★★ 2B-5 第 3 步②：派发期**预译码标志**（每 lane 5 bit：{mret, sret, maint_kind[2:0]}）
    //     ⇒ 提交侧不再需读 4 lane 的 32 bit 指令字去译码 xRET/维护操作。
    //   ★★ EXP-N1：本口是**派发侧**数据 ⇒ 宽度 = ALLOC_W*5（不是 COMMIT_W*5）。
    input  wire [ALLOC_W*5-1:0] alloc_pre,
    //   ★ ② CSR 提交合成的**单 lane 动态读口**（索引 = 提交组内 CSR lane 的绝对 ROB 索引）
    input  wire [ROB_IDX_W-1:0]  csr_lane_idx,
    output wire [`BACK2_CMT_CSR_W-1:0] csr_pay,
    output wire [COMMIT_W-1:0]     cmt_st_drain,     // 该槽为 store 且本拍排空
    output wire [COMMIT_W-1:0]     cmt_st_ckpt,      // 该槽携带检查点（释放用）
    output wire [COMMIT_W-1:0]     cmt_st_branch,    // 该槽是控制转移（训练用）

    //==================================================================
    // 精确异常（提交点）
    //==================================================================
    output wire                    trap_valid,
    output wire [31:0]             trap_pc,
    output wire [3:0]              trap_cause,
    output wire [31:0]             trap_tval,

    //==================================================================
    // ★★ P1（ROB 窗口语义根修）：**头部 PC 本拍可安全用于 trap/interrupt**
    //==================================================================
    //   1 = 「当前 `trap_pc`（= `win_q[0]` 的 PC 段）就是当前 ROB 头项、且该载荷
    //       不可能是旧世代/预取旧数据」⇒ 架构状态（中断 mepc / 异常 EPC / 提交 PC）
    //       本拍可以安全采样它。
    //   0 = 不得采样 `trap_pc`：可能是"ROB 空/未分配"、窗口标签失配、或载荷读取
    //       与该项分配存在跨拍竞争（本拍重填尚未完成）。此时中断应保持 pending
    //       （`cnt==0` 时本核 `trap_ctrl` 也不会取中断），下一拍再看。
    //   ★ 判据 = 真活性（`cnt_q != 0`，不是"窗口非空"）× 窗口全索引标签命中
    //     （`win_lane_ok[0]`，其 `win_val` 已在 §5.35 由 `e_ok/ e_bad` 守卫）。
    output wire                    head_pc_valid_o,

    //==================================================================
    // 冲刷：squash_idx 及其**之后（更年轻）**的项全部作废（含该项保留）
    //        flush_all = 全清（异常/中断；head 不动）
    //==================================================================
    input  wire                    squash_valid,
    input  wire [ROB_IDX_W-1:0]    squash_idx,
    input  wire                    flush_all,
    //   ★ 2B-4 第 4a 段：**陷阱退役**（无副作用弹出头部异常项）。
    //     陷阱在头部被精确抛出（`trap_valid`）时，该指令**不得提交**（`slot_ok` 已含 `~slot_exc`），
    //     但硬件处理程序已接管 ⇒ 它必须从此消失，否则 `flush_all` 保留头部 ⇒ 重取后又立刻再陷阱
    //     （死循环）。本信号与 `trp_flush_v_i` 同拍：head 前移 1、cnt 保持 0。
    input  wire                    trap_retire,

    //==================================================================
    // 观测
    //==================================================================
    output wire [ROB_IDX_W-1:0]    head_o,
    output wire [ROB_IDX_W:0]      cnt_o,
    //   ★★ C8：**统一年龄输出**（"距 ROB 头距离"的全核唯一计算点）——
    //     `squash_age_o = (squash_idx − head_q) mod ROB_N`
    //     全核所有"更年轻 ⇔ age(项) > age(冲刷点)"判据一律改用它：`iq.v` ×6
    //     （冲刷作废掩码）、`backend_top.v` 的 MDU/FPU/I2 杀链与 CSR 追踪表、
    //     以及本模块 §5 的 `cnt_q` 重建。**语义与各站点的本地重算逐位一致**
    //     （两侧都是 ROB_IDX_W 位的模 ROB_N 减法，见 §1.1）。
    output wire [ROB_IDX_W-1:0]    squash_age_o,
    output wire                    empty_o,
    output wire                    head_done_o,
    output wire [3:0]              head_exc_o,
    output wire [31:0]             cmt_cnt_o,       // 累计提交条数（性能统计）
    output wire [`BACK2_EPOCH_W-1:0] epoch_o
);

    //==========================================================================
    // 0. 存储体与指针
    //==========================================================================
    //   ★★ B2：`pl_q` 已删（宽载荷改由 `rob_wide_mem` 承担：写侧每表项 mux 塔缩为每 bank 1 个 4:1 选择）
    //   ★★ B2/B3：**预取宽度口径** `PF_W` = BRAM bank 数 = 预取读口数（本设计恒 4）：
    //     · **由写侧决定**：派发重命名宽度 `ALLOC_W = 4`、4 条 lane 索引连续 ⇒ 宽载荷按
    //       `bank = idx[1:0]` 分成 4 个 bank（每 bank 每拍至多 1 写，无仲裁；见 `rob_wide_mem`）
    //       ⇒ 读口也只能是这 4 个 bank（XPM SDP 每实例 1W1R）。
    //     · **不是**"窗口宽度"：EXP-N3 后窗口只剩 2 项（见下），但一次读回仍是 4 个连续项
    //       （`rsel[k] = k - hpred[1:0]` 把 bank 对齐到索引），因为"读命令 T 拍发出、数据 T+1 拍到、
    //       填窗在 T+1→T+2 沿"⇒ 填窗目标（T+2 的 head = 本拍 `hpred`）与本次读命令的基址
    //       （T 拍 `hpred`）相差 `cmt_n ∈ {0,1,2}` ⇒ 必须 4 选 2（见 §1.5 的 `fhit/fdat` 与 §5.35）。
    //     · 若把 PF_W 直接缩到 2：写侧 4 lane 无处可写（bank 化前提被破坏），且 4 选 2 退化成
    //       动态 bank 选择的地址+数据双 mux，**更贵**。故 PF_W 恒 4，收窄的是窗口存储（WIN_N）。
    localparam integer PF_W = 4;
    //   ★★ EXP-N3：**退休窗口 = WIN_N = COMMIT_W 项（槽号 = 组内 lane 号）**。
    //     · 原 8 槽窗口按 `idx[2:0]` 寻址，提交侧每拍只读 head/head+1 ⇒ 6 槽是纯冗余 FF + mux；
    //     · 新窗口槽 0 恒为"下一拍 head"、槽 1 恒为"head+1" ⇒ 提交读是**寄存器直连**（零 mux）。
    //     · 预取读侧仍是 PF_W = 4 bank（bank 化写口的固有宽度，见 §1.5/§5.35 的口径说明）。
    localparam integer WIN_N = COMMIT_W;
    reg  [RB_W-1:0]      win_q   [0:WIN_N-1]; // ★ EXP-N3：头部窗口（C4 后 RB_W=229；★ EXP-R2 后 225）
    reg  [ROB_IDX_W-1:0] win_idx [0:WIN_N-1]; // 每槽全索引标签（命中校验 ⇒ 绝不交付 stale 载荷）
    reg                  win_val [0:WIN_N-1]; // 每槽有效（复位/冲刷清零；read_first 危险拍丢弃）
    reg  [ROB_IDX_W-1:0] e_of_r_q[0:PF_W-1];  // 预取读地址的**打拍版**（读数据下一拍到达时用它定标签）
    //   ★★ P1 根修：预取读命令**发出那一拍**的"该目标索引是否已在 ROB 内分配"与
    //     "该拍是否 flush_all"必须随 `e_of_r_q` 一起打拍，作为窗口填充的采信条件。
    //     理由（确定性证据见 build/functional/c8-review：p8 的 0x8000802c）：
    //       · BRAM 同步读在 T 拍发命令、T+1 拍数据到达、T+1→T+2 沿填窗；读回值是
    //         **T 拍沿之前**的存储内容（read_first）；
    //       · 若目标索引在 T 拍**尚未分配**（ROB 空/尾后/已 flush），T+1 读回的只是
    //         上一程序/旧世代的残留载荷；旧实现只比 `win_idx == 目标`（`fhit`）就把
    //         `win_val` 置 1 ⇒ 下一拍该槽再被 alloc 命中时，提交/中断直接吃旧 PC；
    //       · `e_ok_q[k]` = 读命令拍 K 的 `live(e_rd_idx[k])`（`0 <= age < cnt`）
    //         ⇒ 只有"K 拍前已分配 ≥1 拍"的项，读回才一定是**本次分配之后**写入的
    //         载荷（write 在 K-1 沿或更早完成，K 沿读可见）；
    //       · `e_bad_q` = T 拍为 `flush_all` ⇒ 该拍发出的读命令穿越了世代边界
    //         （head 会被复位/前移），T+1 读回值不得给新 head 重新贴标签。
    //     两者都只走 1 拍寄存器，不进入提交组合链。
    reg  [PF_W-1:0]      e_ok_q;              // 读命令拍：目标索引已分配（live）
    reg                  e_bad_q;             // 读命令拍：处于 flush_all（世代边界）
    //   危险修正（p11 实测）：BRAM 为 `read_first` ⇒ "同拍被写的项，当拍读到旧值"。
    //     若预取地址正好是本拍刚分配的项（ROB 近空：清洗后 head≈tail），窗口会被填入**旧载荷**
    //     但标签恰好命中 ⇒ 会交付错误 PC。修法：记下**上一拍的分配索引**，填充时若命中则
    //     **丢弃本次填充并把该槽置为无效**（下一拍重读即可）；冲刷时也全部置无效。
    reg  [ROB_IDX_W-1:0] alloc_idx_q[0:PF_W-1];
    reg  [PF_W-1:0]      alloc_idx_v_q;
    wire [RB_W-1:0]      pl_rdata[0:PF_W-1];  // PF_W bank 同步读回数据
    wire [1:0]           wsel    [0:PF_W-1];  // 写轮转：bank i 对应的 lane 序号 = (i - tail[1:0]) & 3
    wire [1:0]           rsel    [0:PF_W-1];  // 读轮转：读口 i 对应的项序号 = (i - head_pred[1:0]) & 3
    //   ★★ 2B-5 第 3 步①：**窄控制表** `nq`（FF 阵列，组合读）
    //     · 收编原 `done_q` + `rep_q`（epoch）+ 提交/前缀链/排空/陷阱判定所需的控制位与索引；
    //     · **宽字段（PC/TVAL/CSRW/TRTGT/FFLAGS 等）仍在 `pl_q`**，本步不动；
    //     · 本步将 rob.v **自用的关键读**（done/exc/is_store/ckpt/is_branch/trap_cause/epoch）
    //       全部改走 `nq`（行为逐位等价），并导出 `cmt_narrow` 供下一步改造 backend_top。
    //     ★★ EXP-N35B 后字段布局（MSB→LSB，**13 bit**，真源 = back2_params.vh §2）：
    //       pre{mret,sret,maint_kind[2:0]} trtaken exc[3:0] epoch[1:0] done
    //       被删的 23 bit（旧布局里 pre/trtaken 之下的 pdf/pdi/arn/is_csr/is_fp_wen/
    //       is_int_wen/ckpt_valid/is_branch/is_store）改从**载荷窗口**读，见 §0.1。
    //     ★★ D2：原 `lq[3:0] stq[4:0] csrop[2:0]`（12 bit）在 `nq` 里**只写不读**（唯一"读"
    //       是 §5 自检对 nq/nq_chk 的恒等区间比对）⇒ 已删，`NQ_W` 49→37；
    //       布局真源 = back2_params.vh §2，本文件不得另存一份位号。
    //     ★★ EXP-R2：`pdi` 由 `PREG_I_W` 定宽（7→6）⇒ `NQ_W` 37→36，其上整段下移 1。
    //     ★★ EXP-N35B：`NQ_W` 36→**13**（沿 N35A §7.3：36 bit 里 **23 bit = 宽载荷逐位重复**）：
    //       · 删 23 bit = FLAGS 6（is_store/is_branch/ckpt_valid/rd_i_wen/rd_f_wen/is_csr）
    //         + PDIDST/PDFDST 12 + ARND 5 —— 它们在派发同拍由 `pack_nq` 从载荷抄写、
    //         此后无第二写源 ⇒ 提交链改读 `win_rd[gi]`（= `win_q[gi]` **直连 FF**，
    //         本就是提交载荷来源，**零新增 mux**）；`backend_top` 侧改吃**已存在**的
    //         `p_arn/p_pdi/p_pdf/p_di/p_df/p_csr`（对载荷取字段）。
    //       · 留 13 bit = pre{mret,sret,maint_kind} 5（派发期前置译码，载荷里没有）
    //         + trtaken 1 + exc 4 + epoch 2 + done 1（**8 bit 真动态**，各有独立写源）。
    //       ⚠ 位号真源 = back2_params.vh §2；本文件不得另存一份位号。
    localparam integer NQ_W      = `BACK2_NQ_W;
    localparam integer NQ_DONE   = `BACK2_NQ_DONE;
    localparam integer NQ_EP_L   = `BACK2_NQ_EP_L;
    localparam integer NQ_EXC_L  = `BACK2_NQ_EXC_L;
    localparam integer NQ_STORE  = `BACK2_NQ_STORE;
    localparam integer NQ_BR     = `BACK2_NQ_BR;
    localparam integer NQ_CKV    = `BACK2_NQ_CKV;
    localparam integer NQ_TRT    = `BACK2_NQ_TRT;
    localparam integer NQ_MK_L   = `BACK2_NQ_MK_L;
    //   ★★ EXP-N35B：下列 6 个旧位号宏已删除（20 bit 不再存于 `nq`），此处同步删除
    //     `NQ_DI/NQ_DF/NQ_CSR/NQ_ARN_L/NQ_PDI_L/NQ_PDF_L` 局部别名 —— 任何残留引用都会在
    //     编译期报错（fail-closed，不静默取错位）。被删 20 bit 的读取口径（唯一真源）：
    //       rd_i_wen / rd_f_wen / is_csr         → `p_di/p_df/p_csr(cmt_pay)`（backend_top）
    //       pdi / pdf / arn                      → `p_pdi/p_pdf/p_arn(cmt_pay)`（backend_top）
    //     `NQ_STORE/NQ_BR/NQ_CKV` **保留**（理由见 back2_params.vh §2 的 N35B 段）。
    reg  [NQ_W-1:0]      nq    [0:ROB_N-1];
    //   ★★ EXP-B（架构 v0.1 §16–§19）：**三张 typed 单写源更新表**（替代原 102 bit `updq`）
    //     · 动机：原 `updq` 每表项有 8 个写源（4 派发 lane + CSR/BRU/FPU/LSU 四口）⇒
    //       每表项一个多写源写 mux（面积探针实测 ≈11 k LUT，docs/design/09 §2.3 第 3 行）；
    //       动态实测 `upd_tr/ff/exc` 同拍并发 ≥2 仅 0.02% ⇒ **无需共享写口**，
    //       三张表各留一个写源即可，写侧退化为"每表一次索引译码 + 数据直连"。
    //     · 每表 {valid, epoch}：写口在**目标项自己的 epoch**（`nq[idx].epoch`）下置位；
    //       提交/陷阱时 `valid && epoch == 项内 epoch` 才采用 ⇒ 索引被复用/跨冲刷的旧表项
    //       epoch 不同，天然作废（不必在 flush/squash 清 64 项）。
    //     · 数据数组不置复位（valid=0 时被 merge 的回落支路屏蔽，无 x 传播）；
    //       valid/epoch 数组复位清零（仿真下不会出现 x 判定）。
    reg                          br_v_q  [0:ROB_N-1];
    reg  [`BACK2_TBL_EP_W-1:0]   br_ep_q [0:ROB_N-1];
    //   ★★ EXP-N34B3：四张数据数组显式钉在分布式 RAM（64 深 < BRAM 最小深度，属性只把
    //      推断目标写死；能否推断取决于下方 §5.3b 写进程的敏感性表）。
    (* ram_style = "distributed" *) reg [`BACK2_BR_TGT_W-1:0]   br_tgt_q[0:ROB_N-1];
    (* ram_style = "distributed" *) reg [`BACK2_BR_TAKEN_W-1:0] br_taken_q[0:ROB_N-1];
    reg                          ff_v_q  [0:ROB_N-1];
    reg  [`BACK2_TBL_EP_W-1:0]   ff_ep_q [0:ROB_N-1];
    (* ram_style = "distributed" *) reg [`BACK2_FF_W-1:0]       ff_q    [0:ROB_N-1];
    reg                          ex_v_q  [0:ROB_N-1];
    reg  [`BACK2_TBL_EP_W-1:0]   ex_ep_q [0:ROB_N-1];
    (* ram_style = "distributed" *) reg [`BACK2_EX_TVAL_W-1:0]  ex_tval_q[0:ROB_N-1];

    //   拼接：载荷的不可更新部分 + 三张 typed 表的命中值（纯布线 + 单层选择，无多写源 mux）
    //     命中判据由调用方给出（`*_use` = 表 valid && 表 epoch == 项内 epoch && 该字段真被读）；
    //     未命中回落到"该字段在载荷里的原值"（br/ff 的原值恒 0 ⇒ 直接用常量，见下）
    //   ★★ EXP-B 回落支路口径（与综合面积直接相关，勿随手改）：
    //     · br/ff 两个回落支路用**常量 0**：载荷的 [405:401]/[400]/[399:368] 由
    //       `backend_top.v` 的 ROB 载荷组装式**恒写 `5'b0 / 1'b0 / 32'h0`**（"执行期回写"
    //       占位，且载荷只有派发一个写源）⇒ 与读 `pl[...]` **逐位等价**；本文件 §6 的
    //       `ROB-ASSERT-PAY0` 自检在仿真里逐拍钉死该前提。
    //       为何不读 `pl[...]`：那会让 BRAM 的**读数据位宽**多出 38 bit ⇒ 实测每 bank
    //       从 5 个 RAMB36 撑到 6 个（全核 +4 RAMB36、u_wmem +1.5 k LUT 的**假成本**）。
    //     · ex（TVAL）的回落支路**必须**读 `pl[367:336]`：非法指令/取指异常的 mtval
    //       就存在那里（唯一真源，见 §3 `trap_tval`）。
    function [RB_W-1:0] merge_upd;
        input [RB_W-1:0]              pl;
        input                         br_use; input [`BACK2_BR_TAKEN_W-1:0] br_tk;
        input [`BACK2_BR_TGT_W-1:0]   br_tgt;
        input                         ff_use; input [`BACK2_FF_W-1:0]       ff_d;
        input                         ex_use; input [`BACK2_EX_TVAL_W-1:0]  ex_tv;
        begin
            //   ★★ C4：字段序随新布局（见 back2_params.vh §2 的位域表）。结构**未变**：
            //     · FFLAGS / TRTAKEN / TRTGT 三段仍是「表命中值 or 常量 0」的占位；
            //     · TVAL 段仍是「ex 表命中值 or 载荷原值」；
            //     · TVAL 以下（LQ/STQ/PDFDST/…/EXC）整段直通载荷。
            //   ⚠ CSRW 段（旧 [335:304]）已从载荷删除（EXP-B 起 `csr_pay` 直接取载荷
            //     uop.PS1I）⇒ 本式的最后一段下移到 `RB_TVAL_LSB-1`。
            merge_upd = { pl[RB_W-1:`BACK2_RB_FFLAGS_MSB+1],
                          ff_use ? ff_d : {`BACK2_FF_W{1'b0}},
                          br_use ? br_tk : {`BACK2_BR_TAKEN_W{1'b0}},
                          br_use ? br_tgt : {`BACK2_BR_TGT_W{1'b0}},
                          ex_use ? ex_tv : pl[`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB],
                          pl[`BACK2_RB_TVAL_LSB-1:0] };
        end
    endfunction

    //   打包：从宽载荷 + epoch + done 生成窄字（分配与一致性自检共用）
    //   ★★ C4：本函数从载荷取的每个字段都必须用 **`BACK2_RB_*`（载荷布局）** 宏 ——
    //     旧版直接借用 `BACK2_U_*`（uop 布局）只是因为旧载荷的低 304 位恰好就是 uop；
    //     载荷重排后两者不再重合（唯一仍然重合的是 [19:0] 的 EXC+FLAGS 块，见参数表）。
    //   ★★ D2：删除 `lq[3:0]/stq[4:0]/csrop[2:0]` 三段（只写不读）；其余字段与
    //     `BACK2_NQ_*` 位号一一对应（位号真源在 back2_params.vh）。
    //   ★★ EXP-N35B：只打包**保留的 13 bit**（位号由 back2_params.vh §2 定）。被删的 23 bit
    //     是宽载荷的逐位副本（`is_store/is_branch/ckpt_valid/rd_i_wen/rd_f_wen/is_csr` +
    //     `pdi/pdf/arn`），提交链直接从 `win_rd` 取（见 §0.1 的读取口径）——**不再抄一份**。
    //     `trtaken` 仍打包（其载荷占位恒 0，真值由 BRU `upd_tr` 动态写 `nq`）。
    function [NQ_W-1:0] pack_nq;
        input [RB_W-1:0] p; input [`BACK2_EPOCH_W-1:0] ep; input dn; input [4:0] pre;
        begin
            pack_nq = { pre,                                           // [15:11] {mret,sret,maint_kind}
                        p[`BACK2_RB_TRTAKEN],                          // [10]
                        p[`BACK2_UB_CKPT_VALID],                       // [9]
                        p[`BACK2_UB_IS_BRANCH],                        // [8]
                        p[`BACK2_UB_IS_STORE],                         // [7]
                        p[`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB],        // [6:3]
                        ep,                                            // [2:1]
                        dn };                                          // [0]
        end
    endfunction
    //   ★ 项内 epoch 由 `nq` 的 [2:1] 承载（原独立的 `rep_q` 数组已无任何读写 ⇒ 删除；
    //     原因仍是"不要把 epoch 塞进 416 bit 载荷"：载荷内的字段要在时钟块里按 7 个
    //     写回索引读 ⇒ iverilog 会展开成 7×(ROB_N×416) 的组合读森林，仿真慢 ~12×）。
    reg  [ROB_IDX_W-1:0] head_q;
    reg  [ROB_IDX_W:0]   cnt_q;              // 0..ROB_N（8 bit）
    reg  [31:0]          cmt_cnt_q;
    reg  [`BACK2_EPOCH_W-1:0] epoch_q;       // §8.2：冲刷递增；过期写回被过滤

    //==========================================================================
    // 1. 索引派生与余量
    //==========================================================================
    // 环形指针增量：ROB_N 恒为 2 的幂（L3 后 = 64）⇒ 截断即取模
    function [ROB_IDX_W-1:0] idx_add(input [ROB_IDX_W-1:0] a, input [ROB_IDX_W:0] d);
        begin idx_add = a + d[ROB_IDX_W-1:0]; end
    endfunction

    wire [ROB_IDX_W-1:0] tail_w = idx_add(head_q, cnt_q);

    //==========================================================================
    // 1.1 ★★ C8：年龄（"距头距离"）的唯一计算点
    //==========================================================================
    //   口径（与 `iq.v` §2/§5、`backend_top.v` 的杀链**逐位一致**，勿改宽度）：
    //     · ROB_N = 2^ROB_IDX_W ⇒ `ROB_IDX_W` 位无符号减法**天然取模**：
    //       `squash_idx - head_q` 在 ROB_IDX_W 位上下文里就是 `(squash_idx − head_q) mod ROB_N`
    //       （与 `idx_add()` 的"截断即取模"同一口径）；
    //     · 消费侧一律**零扩展**到 `rob_cnt` 的位宽（ROB_IDX_W+1）再比较 ——
    //       `rob_cnt = ROB_N` 时在 ROB_IDX_W 位里表示为 0，窄位比较会把"满窗口"
    //       误判成"空窗口"（`iq.v` §5 有实测注释）。
    //   ★ 本线是"更年轻 ⇔ age(项) > age(冲刷点)"这套模 N 语义在全核的**唯一实现**；
    //     各消费模块不再各自重算 `squash_idx − rob_head`（原 9 份：rob 1 + iq 6 +
    //     backend_top 1 + lsq 1）。
    wire [ROB_IDX_W-1:0] age_sq_w = squash_idx - head_q;
    assign squash_age_o = age_sq_w;

    //==========================================================================
    // 1.5 ★ B2/B3：BRAM 写/读轮转 + 头部窗口
    //==========================================================================
    //   派发 ALLOC_W 条 lane 索引连续（tail..tail+ALLOC_W-1），提交 ≤COMMIT_W 项索引也连续。
    //   ⇒ 两边都是 "{0,1,2,3} 的旋转"，bank=i 的写/读只需选择对应那一项。
    //   ★★ EXP-N1：`PF_W` 已在 §0 声明（预取宽度，见那里的口径说明）。
    wire [ROB_IDX_W-1:0] hpred_w = idx_add(head_q, {{(ROB_IDX_W-3){1'b0}}, cmt_n_w});
    genvar gw;
    generate
    for (gw = 0; gw < PF_W; gw = gw + 1) begin : g_rot
        assign wsel[gw] = gw[1:0] - tail_w[1:0];
        assign rsel[gw] = gw[1:0] - hpred_w[1:0];
    end
    endgenerate

    //==========================================================================
    // 1.2 ★★ P1 根修：预取读命令拍的"已分配（live）"判定
    //==========================================================================
    //   ★ 时序对齐（最容易写错的一格，必须与 `e_of_r_q` **同沿同源**）：
    //     · 读命令在拍 K 的组合 `e_rd_idx[k]` 上发出、在 K 沿被 BRAM 采样；
    //       读回数据在 K+1 拍可见，K+1 沿填窗（用 K+1 拍沿前的 `e_of_r_q/
    //       e_ok_q` —— 两者都在 K 沿与 `e_rd_idx` 一起锁存）。
    //     · 因此 live 判定必须用**同一个 K 拍 `e_rd_idx`** + **K 拍沿前**的
    //       `head_q/cnt_q`（也就是"发出读命令那一刻"的 ROB 活性），不能拿
    //       `e_of_r_q`（K 拍沿后才变成 `e_rd_idx[K]`，早一拍）或 K+1 拍的
    //       指针去判（会把"读后才 alloc"误判成 live）。
    //   口径与全核 `(idx - head) mod ROB_N < cnt` **逐位同源**（C8 年龄的唯一实现）：
    //     · 先按 ROB_IDX_W 位做模 N 减法（截断即取模），再**零扩展**到 cnt_q 的
    //       ROB_IDX_W+1 位比较（cnt=N 时窄位比较会把满窗误判成空窗，见 §1.1）。
    //   ★ 该判定**只在填窗时**使用（§5.35），不进提交关键路径。
    wire [PF_W*ROB_IDX_W-1:0] e_rd_idx_flat;   // 本拍读命令的 4 个目标索引（与 bw_roff 同源）
    wire [PF_W-1:0]           e_live_w;
    genvar gl;
    generate
    for (gl = 0; gl < PF_W; gl = gl + 1) begin : g_live
        assign e_rd_idx_flat[gl*ROB_IDX_W +: ROB_IDX_W] =
            idx_add(hpred_w, {{5{1'b0}}, rsel[gl]});
        wire [ROB_IDX_W-1:0] e_age_w =
            e_rd_idx_flat[gl*ROB_IDX_W +: ROB_IDX_W] - head_q;   // mod ROB_N
        assign e_live_w[gl] = ({1'b0, e_age_w} < cnt_q);
    end
    endgenerate

    //   窗口读（**零 mux**：槽号 = lane 号）+ 命中判定
    //   ★★ EXP-N3：窗口槽号 = 组内 lane 号 ⇒ `win_rd[gi] = win_q[gi]` **直连**，
    //     原 2 lane × 8:1 × RB_W 的窗口读 mux 与按 `idx[2:0]` 的动态索引整体消失。
    //     命中判定保留（全索引标签 + valid）：填窗只在"预测正确"时进行，标签失配
    //     ⇒ 该 lane 本拍不提交（插气泡；**绝不交付错误 PC/tval**）。
    wire [RB_W-1:0] win_rd [0:COMMIT_W-1];
    wire [COMMIT_W-1:0] win_lane_ok;
    generate
    for (gw = 0; gw < COMMIT_W; gw = gw + 1) begin : g_winrd
        wire [ROB_IDX_W-1:0] ei = idx_add(head_q, gw[ROB_IDX_W-1:0]);
        assign win_rd[gw]      = win_q[gw];
        assign win_lane_ok[gw] = win_val[gw] & (win_idx[gw] == ei);
    end
    endgenerate

    //   BRAM 实例（B1 交付的模块：4 bank × SDP，同步读）
    //   ★★ EXP-N1：**写侧 4 口**（= ALLOC_W，派发宽度未变）、**读侧 PF_W=4 口**（预取口径，
    //     见上）。两者都不随 COMMIT_W 变化 ⇒ 本段结构不变；提交侧只是少消费 2 个 lane。
    wire [PF_W-1:0]        bw_we;
    wire [PF_W*5-1:0]      bw_woff, bw_roff;
    wire [PF_W*RB_W-1:0]   bw_wdata, bw_rdata;
    generate
    for (gw = 0; gw < PF_W; gw = gw + 1) begin : g_bw
        //   （函数返回值不能直接做位选（iverilog）⇒ 先存临时线）
        wire [ROB_IDX_W-1:0] wt = idx_add(tail_w,  {{5{1'b0}}, wsel[gw]});
        wire [ROB_IDX_W-1:0] rt = e_rd_idx_flat[gw*ROB_IDX_W +: ROB_IDX_W];
        //   `wsel[gw]` 是 2 bit（bank = idx[1:0]）⇒ 恒 < 4 = ALLOC_W，索引天然合法
        assign bw_we[gw]   = alloc_fire & alloc_lane_valid[wsel[gw]] & (wsel[gw] < alloc_n);
        assign bw_woff[gw*5 +: 5] = wt[ROB_IDX_W-1:2];
        assign bw_wdata[gw*RB_W +: RB_W] = alloc_payload[wsel[gw]*RB_W +: RB_W];
        assign bw_roff[gw*5 +: 5] = rt[ROB_IDX_W-1:2];
        assign pl_rdata[gw] = bw_rdata[gw*RB_W +: RB_W];
    end
    endgenerate

    rob_wide_mem #(.NW(PF_W), .BW(32), .DW(RB_W), .AW(ROB_IDX_W), .OW(5), .CHK(0)) u_wmem (
        .clk(clk), .rst_n(rst_n),
        .we(bw_we), .woff(bw_woff), .wdata(bw_wdata),
        .re({PF_W{1'b1}}),  .roff(bw_roff), .rdata(bw_rdata));

    //   ★ B3「read_first 同址危险」判据（纯 `assign` 展开，供 §5.35 的窗口填充使用）：
    //     `dang_hit[k]` = 预取口 k 的目标索引 `e_of_r_q[k]` 是否命中**上一拍刚分配的槽**
    //     （命中 ⇒ 本次读回的是旧载荷，必须丢弃并把该窗口槽置无效，下一拍重读）。
    //   ★★ EXP-N1：预取口数 = PF_W，分配槽数 = ALLOC_W（两者均不随 COMMIT_W 变化）。
    wire [ALLOC_W-1:0] dang_hit [0:PF_W-1];
    genvar gz, gk;
    generate
    for (gz = 0; gz < PF_W; gz = gz + 1) begin : g_dang
        for (gk = 0; gk < ALLOC_W; gk = gk + 1) begin : g_dangk
            assign dang_hit[gz][gk] = alloc_idx_v_q[gk] & (alloc_idx_q[gk] == e_of_r_q[gz]);
        end
    end
    endgenerate

    //   ★★ EXP-N3：**填窗选择**（纯 `assign`）—— 本拍读回的 4 个 bank 里，哪两个是"下一拍退休组"。
    //     · 读口 k 恒携带 **bank k** 的项（`rsel[k] = k - hpred[1:0]` 把 4 个连续项铺到 4 个 bank）
    //       ⇒ "索引 X 在哪个口" 只看 `X[1:0]`；`e_of_r_q[k]` 是权威标签（与 `pl_rdata[k]` 同源同拍）。
    //     · `fhit*` = 口内数据的全索引 == 目标索引（读命令基址与当前 head 脱节时失配 ⇒ 不填）；
    //       `fdang*` = `read_first` 同址危险（该地址恰在发出读命令的那一拍被分配写入 ⇒ 读回旧载荷）。
    //     · 目标索引 = `hpred_w`（= 本拍 `head + cmt_n`）= **下一拍 head**（正常推进分支逐位相等）
    //       ⇒ 槽 0 ← `hpred`、槽 1 ← `hpred+1`，与"槽号 = lane 号"的提交读口径严格对齐。
    wire [ROB_IDX_W-1:0] fidx1_w  = hpred_w + {{(ROB_IDX_W-1){1'b0}}, 1'b1};
    wire [1:0]           fsel0_w  = hpred_w[1:0];
    wire [1:0]           fsel1_w  = hpred_w[1:0] + 2'd1;
    wire                 fhit0_w  = (e_of_r_q[fsel0_w] == hpred_w);
    wire                 fhit1_w  = (e_of_r_q[fsel1_w] == fidx1_w);
    wire                 fdang0_w = |dang_hit[fsel0_w];
    wire                 fdang1_w = |dang_hit[fsel1_w];
    wire [RB_W-1:0]      fdat0_w  = pl_rdata[fsel0_w];
    wire [RB_W-1:0]      fdat1_w  = pl_rdata[fsel1_w];

    // 提交链（先算，用于同拍释放余量）
    //   ★★ EXP-N1：以下**全部**是提交侧 ⇒ 宽度 = COMMIT_W（= 2），4 份复制变 2 份。
    wire [COMMIT_W-1:0] slot_in_range;
    wire [COMMIT_W-1:0] slot_done;
    wire [COMMIT_W-1:0] slot_exc;
    wire [COMMIT_W-1:0] slot_store;
    wire [COMMIT_W-1:0] slot_st_ok;
    wire [COMMIT_W-1:0] slot_ok;

    //   ★★ EXP-N1：退休选择从 `head0/head1/head2/head3` 收窄为 `head0/head1`
    //     （`slot_idx[gi] = (head + gi) mod ROB_N`，gi < COMMIT_W）。
    wire [ROB_IDX_W-1:0] slot_idx [0:COMMIT_W-1];
    genvar gsi;
    generate
    for (gsi = 0; gsi < COMMIT_W; gsi = gsi + 1) begin : g_slot
        assign slot_idx[gsi] = idx_add(head_q, gsi[ROB_IDX_W:0]);
    end
    endgenerate

    genvar gi;
    //   ★★ EXP-B：三张 typed 表在提交组 4 个 lane 上的"采用判据"（模块级数组：断言块也要看）
    wire [COMMIT_W-1:0] slot_is_br;
    wire [COMMIT_W-1:0] slot_is_fp;
    wire [COMMIT_W-1:0] br_use, ff_use, ex_use;
    generate
    for (gi = 0; gi < COMMIT_W; gi = gi + 1) begin : g_cmt
        assign slot_in_range[gi] = (cnt_q > gi);
        assign slot_done[gi]     = nq[slot_idx[gi]][NQ_DONE];
        assign slot_exc[gi]      = |nq[slot_idx[gi]][NQ_EXC_L +: 4];
        //   ★★ EXP-N35B：`is_store` **保留在 `nq`**（不改读窗口）——它是被删位里唯一进入
        //     rob **自身状态演化**的位（`slot_st_ok → slot_ok → cmt_n_w → head/cnt/hpred`）；
        //     实测反例见 back2_params.vh §2 的 N35B 段与 n35b_report §6.3。
        assign slot_store[gi]    = nq[slot_idx[gi]][NQ_STORE];
        assign slot_st_ok[gi]    = ~slot_store[gi] | mem_wr_ready;
        //   ★ B3：窗口未命中 ⇒ 本 lane 不可提交（插一拍气泡；**绝不交付错误 PC/tval**）
        assign slot_ok[gi]       = slot_in_range[gi] & slot_done[gi] & ~slot_exc[gi] & slot_st_ok[gi]
                                 & win_lane_ok[gi];

        //   ★★ EXP-B：typed 表采用判据 = 表 valid && 表 epoch == **本项项内 epoch** && 本项真消费该字段
        //     · `is_branch` 取 `nq`（= 载荷 IS_BRANCH，同源）；`is_fp` 只存在载荷里 ⇒ 取窗口读回值；
        //     · ex 的判据：`exc` **派发期为空、现在非空** ⇒ 该异常只可能由 LSU 的 `upd_exc`
        //       回写而来（`nq.exc` 全文只有两个写源：派发 `pack_nq` 与 `upd_exc`）⇒ 此时才吃 ex 表；
        //       派发期异常（非法/ecall/ebreak/取指异常）的 mtval 必须回落**载荷 TVAL**。
        wire [`BACK2_EPOCH_W-1:0] ep_gi   = nq[slot_idx[gi]][NQ_EP_L +: `BACK2_EPOCH_W];
        wire [3:0]                exc_gi  = nq[slot_idx[gi]][NQ_EXC_L +: 4];
        //   ★★ C4：载荷的 EXC/FLAGS 两段按硬约束**保持 uop 原绝对位**（见 back2_params §2
        //     的位域表），故这里 `BACK2_U_EXC_*` / `BACK2_UB_IS_FP` 在载荷上仍逐位成立。
        wire [3:0]                pexc_gi = win_rd[gi][`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB];
        //   ★★ EXP-N35B：`is_branch` 同样**保留在 `nq`**（它喂 `br_use → merge_upd →
        //     cmt_payload[TRTGT/TRTAKEN]`，即 rob 的对外载荷；保留 ⇒ rob 边界逐字节一致）。
        //     `slot_is_fp` 保持"读 `win_rd`"原状（改前即如此，属既有设计口径）。
        assign slot_is_br[gi] = nq[slot_idx[gi]][NQ_BR];
        assign slot_is_fp[gi] = win_rd[gi][`BACK2_UB_IS_FP];
        assign br_use[gi] = br_v_q[slot_idx[gi]] & (br_ep_q[slot_idx[gi]] == ep_gi) & slot_is_br[gi];
        assign ff_use[gi] = ff_v_q[slot_idx[gi]] & (ff_ep_q[slot_idx[gi]] == ep_gi) & slot_is_fp[gi];
        assign ex_use[gi] = ex_v_q[slot_idx[gi]] & (ex_ep_q[slot_idx[gi]] == ep_gi)
                          & (|exc_gi) & (pexc_gi == 4'd0);
    end
    endgenerate

    // 前缀链：第 i 槽可提交 ⇒ 前面所有槽都可提交
    wire [COMMIT_W-1:0] cmt_chain;
    assign cmt_chain[0] = slot_ok[0];
    generate
    for (gi = 1; gi < COMMIT_W; gi = gi + 1) begin : g_chain
        assign cmt_chain[gi] = cmt_chain[gi-1] & slot_ok[gi];
    end
    endgenerate
    assign cmt_valid = cmt_chain;

    // 提交条数
    reg [2:0] cmt_n_w;
    integer   ci;
    always @(*) begin
        cmt_n_w = 3'd0;
        for (ci = 0; ci < COMMIT_W; ci = ci + 1) begin
            if (cmt_chain[ci]) cmt_n_w = cmt_n_w + 3'd1;
        end
    end

    //==========================================================================
    // 2. 余量（提交与派发同拍：先释放再分配）
    //==========================================================================
    //   ★ `alloc_ready` 是**纯余量判据**（与端口注释一致），**不得**含 alloc_valid：
    //     派发侧的 `disp_ok` 要用它做本轮能否派发的判据，而 `alloc_valid` 正是由
    //     `disp_ok` 派生的（D3 fire）——把 alloc_valid 卷进来会形成组合环
    //     （旧版即如此，为了绕环又把 alloc_valid 接成"D1 有块就分配"，导致同一块
    //     每拍重复分配、ROB 提交流全为重复项；实测现象：前端不推进、ROB cnt 恒定）。
    wire alloc_fire = alloc_valid & (room_free >= {5'b0, alloc_n});
    wire [ROB_IDX_W:0] cnt_after_cmt = cnt_q - {5'b0, cmt_n_w};
    wire [ROB_IDX_W:0] room_free     = ROB_N[ROB_IDX_W:0] - cnt_after_cmt;
    assign alloc_ready = (room_free >= {5'b0, alloc_n});
    assign alloc_idx0  = tail_w;

    //==========================================================================
    // 3. 提交载荷/异常输出
    //==========================================================================
    generate
    for (gi = 0; gi < COMMIT_W; gi = gi + 1) begin : g_cmtout
        assign cmt_payload[gi*RB_W +: RB_W] =
            merge_upd(win_rd[gi],
                      br_use[gi], br_taken_q[slot_idx[gi]], br_tgt_q[slot_idx[gi]],
                      ff_use[gi], ff_q[slot_idx[gi]],
                      ex_use[gi], ex_tval_q[slot_idx[gi]]);
        assign cmt_narrow[gi*NQ_W +: NQ_W]  = nq[slot_idx[gi]];
        assign cmt_st_drain[gi] = cmt_chain[gi] & slot_store[gi];
        //   ★★ EXP-N35B：`ckpt_valid` 同样**保留在 `nq`**（喂 `cmt_st_ckpt` 对外输出）。
        assign cmt_st_ckpt[gi]  = cmt_chain[gi] & nq[slot_idx[gi]][NQ_CKV];
        assign cmt_st_branch[gi]= cmt_chain[gi] & slot_is_br[gi];
    end
    endgenerate

    // 异常：仅当该槽已完成且为头部（slot 0）
    //   ★★ EXP-N3：槽 0 恒为 head 项（填窗目标 = 下一拍 head，`win_lane_ok[0]` 已校验标签）
    //     ⇒ 不再按 `slot_idx[0][2:0]` 动态索引窗口（原 8:1 mux 消失）。
    assign trap_valid = slot_in_range[0] & slot_done[0] & slot_exc[0] & win_lane_ok[0];
    assign trap_pc    = win_q[0][`BACK2_RB_PC_MSB:`BACK2_RB_PC_LSB];
    assign trap_cause = nq[slot_idx[0]][NQ_EXC_L +: 4];
    //   ★★ EXP-B：mtval 取 ex 表（LSU 数据侧异常）或**载荷 TVAL**（派发期异常：非法指令的
    //     原始指令位 / 取指异常的故障 VA）——判据与提交侧 `ex_use` 同源（`ex_use[0]`）。
    assign trap_tval  = ex_use[0] ? ex_tval_q[slot_idx[0]]
                                  : win_q[0][`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB];

    //==========================================================================
    // 3b. ★★ P1 根修：头部 PC 安全指示（组合，供中断/trap EPC 采样门控）
    //==========================================================================
    //   语义（唯一口径，勿简化成 `win_val[0]`）：
    //     · `cnt_q != 0`：头项真的在 ROB 内（未分配/已 flush/被 kill 的 index 不算）；
    //     · `win_lane_ok[0]`：窗口槽 0 有效 + **全索引标签等于当前 head**，且它的
    //       `win_val` 已在 §5.35 通过 `e_ok_q/e_bad_q`（读命令拍已分配/未跨 flush）筛过；
    //   ⇒ 为 1 时 `trap_pc` 一定是当前头项分配之后写入的 PC；为 0 时中断必须保持
    //     pending（不得用 `trap_pc` 写 mepc），异常侧 `trap_valid` 本身已含同一窗口门。
    assign head_pc_valid_o = (cnt_q != {(ROB_IDX_W+1){1'b0}}) & win_lane_ok[0];

    //==========================================================================
    // 4. 观测输出
    //==========================================================================
    //   ★ ② CSR 提交合成**单 lane 动态读口**：只读被选中的那一项（而非 4 lane 全读）
    //   ★★ EXP-B：`tval` 段（= 原始指令位，判 zimm 形式用）改从**载荷 `BACK2_RB_TVAL`** 取；
    //      `csrw` 段（其低 PW_I 位 = 该 CSR 指令自己的 PS1I）改从**载荷 uop.PS1I** 取 ——
    //      两者在拆分前分别等于 `updq.TVAL` 与 `updq.CSRW`（后者从不被回写，恒为派发期
    //      `{25'b0, PS1I}`）⇒ 对外 79 bit 布局与语义**逐位不变**，且不再需要 64 项 32 bit 表。
    //   ★★ EXP-R2：`csrw` 段仍是**零扩展的 32 bit 字段** —— 填充宽度由 `BACK2_PREG_I_W`
    //      算出（不再写死 25'b0）。若仍写 25'b0，整条 79 bit 拼接会缩短 1 bit ⇒
    //      tval/csra/csrop 全体错位（backend_top 按 [78:47]/[46:15]/[14:3]/[2:0] 取段）。
    //   ★★ EXP-N3：槽号 = lane 号 ⇒ 动态索引退化为**组内 2:1 位置选择**
    //      （`backend_top` 的 `csr_dyn_idx_w = head + csr_cmt_lane`，`csr_cmt_lane ∈ {0,1}`）。
    //      字段抽取做成函数（红线 3：组合逻辑用函数，不写 always），79 bit 拼接只做一次。
    function [`BACK2_CMT_CSR_W-1:0] pack_csr_pay;
        input [RB_W-1:0] p;
        begin
            pack_csr_pay = { p[`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB],
                             {{(32-`BACK2_PREG_I_W){1'b0}},
                              p[`BACK2_RB_PS1I_MSB:`BACK2_RB_PS1I_LSB]},
                             p[`BACK2_RB_CSRADDR_MSB:`BACK2_RB_CSRADDR_LSB],
                             p[`BACK2_RB_CSROP_MSB:`BACK2_RB_CSROP_LSB] };
        end
    endfunction
    wire csr_win_lane1_w = (csr_lane_idx != head_q);   // 索引 ∈ {head, head+1} ⇒ 非 head 即为 lane 1
    assign csr_pay = csr_win_lane1_w ? pack_csr_pay(win_q[1]) : pack_csr_pay(win_q[0]);

    assign head_o      = head_q;
    assign cnt_o       = cnt_q;
    assign empty_o     = (cnt_q == 0);
    assign head_done_o = nq[head_q][NQ_DONE];
    assign head_exc_o  = nq[head_q][NQ_EXC_L +: 4];
    assign cmt_cnt_o   = cmt_cnt_q;
    assign epoch_o     = epoch_q;

    //==========================================================================
    // 5. 时序：分配 / 完成 / 字段回写 / 提交 / 冲刷
    //==========================================================================
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q    <= {ROB_IDX_W{1'b0}};
            cnt_q     <= {(ROB_IDX_W+1){1'b0}};
            cmt_cnt_q <= 32'h0;
            epoch_q   <= {`BACK2_EPOCH_W{1'b0}};
            for (k = 0; k < WIN_N; k = k + 1) begin
                win_q[k]   <= {RB_W{1'b0}};
                win_idx[k] <= {ROB_IDX_W{1'b0}};
                win_val[k] <= 1'b0;
            end
            for (k = 0; k < PF_W; k = k + 1) e_of_r_q[k] <= {ROB_IDX_W{1'b0}};
            //   ★★ P1 根修：read-command 采信条件（live / flush 世代）复位后一律不采信
            //     （复位后的第一次读命令也必须等"目标已分配 ≥1 拍"才允许填窗）。
            e_ok_q  <= {PF_W{1'b0}};
            e_bad_q <= 1'b0;
            for (k = 0; k < ROB_N; k = k + 1) begin
                nq[k]     <= {NQ_W{1'b0}};
                //   ★★ EXP-B：三张 typed 表只复位 {valid, epoch}（数据数组在 valid=0 时被
                //     merge 的回落支路屏蔽 ⇒ 无 x 传播；不置复位也让综合更容易落 LUTRAM）
                br_v_q[k]  <= 1'b0;  br_ep_q[k]  <= {`BACK2_TBL_EP_W{1'b0}};
                ff_v_q[k]  <= 1'b0;  ff_ep_q[k]  <= {`BACK2_TBL_EP_W{1'b0}};
                ex_v_q[k]  <= 1'b0;  ex_ep_q[k]  <= {`BACK2_TBL_EP_W{1'b0}};
            end
        end else begin
            // ---- 5.1 派发写入（新项：done 清零；仅真正派发拍 = alloc_fire）----
            //   ★★ EXP-N1：本循环是**分配侧** ⇒ 上界 = ALLOC_W（=4，派发宽度未变）。
            if (alloc_fire) begin
                for (k = 0; k < ALLOC_W; k = k + 1) begin
                    if (alloc_lane_valid[k] & (k < alloc_n)) begin
`ifndef RV32GC_USE_VIVADO_IP
                        //   ★ C4：CSRW 段已从载荷删除 ⇒ 探针改打「CSR 源」= 载荷 PS1I
                        //     （提交级 `csr_pay` 的 csrw 段正是由它拼出，语义等价）。
                        if (DBG_CSR) $display("[rob-alloc t=%0t] k=%0d idx=%0d pay_ps1i=0x%02x", $time, k, idx_add(tail_w, k[ROB_IDX_W:0]), alloc_payload[k*RB_W + `BACK2_RB_PS1I_LSB +: `BACK2_PREG_I_W]);
`endif
                        nq[idx_add(tail_w, k[ROB_IDX_W:0])] <=
                            pack_nq(alloc_payload[k*RB_W +: RB_W], alloc_epoch, 1'b0,
                                    alloc_pre[k*5 +: 5]);
                        //   ★★ EXP-B：派发期**不再**把可更新字段复制进更新表 —— 三张 typed 表
                        //     只由各自的执行部件写（BRU/FPU/LSU），派发写只落 `nq` 与 BRAM 载荷。
                        //   ★★ EXP-N35B：被删 23 bit 的**仿真影子**（综合侧此段不存在）——
                        //     与真载荷同源同拍写入，供 §5.6 的提交侧比对。
`ifndef RV32GC_USE_VIVADO_IP
                        nq20_sh[idx_add(tail_w, k[ROB_IDX_W:0])] <=
                            grp20(alloc_payload[k*RB_W +: RB_W]);
`endif
                    end
                end
            end

            // ---- 5.2 写回置 done ----
            //   ★ epoch 过滤必须比**项内记录的分配时 epoch**，而不是全局当前 epoch：
            //     冲刷（squash）会保留"比分支更老"的项，而这些项可能**正在执行中**
            //     （已在 IQ 发射、1~2 拍后写回）。它们的写回带的是**发射时**的 epoch，
            //     若拿全局 epoch 比就会全部被过滤 ⇒ 这些项永远不 done ⇒ ROB 头卡死
            //     且无任何在飞指令（实测：head pc=0x8000_0044、hdone=0、IQ 全空、永久停顿）。
            //   按项内 epoch 比较同时保留原目标：索引被新项复用后，旧写回 epoch 与新项
            //     epoch 不同 ⇒ 不会给新项误置 done（03 §8.2）。
            for (k = 0; k < WB_N; k = k + 1) begin
                if (wb_valid[k] &&
                    (wb_epoch[k*`BACK2_EPOCH_W +: `BACK2_EPOCH_W] ==
                     nq[wb_rob_idx[k*ROB_IDX_W +: ROB_IDX_W]][NQ_EP_L +: `BACK2_EPOCH_W]))
                    nq[wb_rob_idx[k*ROB_IDX_W +: ROB_IDX_W]][NQ_DONE] <= 1'b1;
            end

            // ---- 5.3 ★★ EXP-B：三张 typed 表写入（**每表恰好一个写源** ⇒ 无共享写口/无仲裁）----
            //   写口与该项的写回（5.2 置 done）**同沿**：此时该项尚未提交 ⇒ 索引不可能被复用
            //   ⇒ `nq[idx].epoch` 就是该项自己的 epoch（写入口径 == 提交比对口径）。
            //   ★★ EXP-N34B3：**数据数组**（br_tgt/br_taken/ff/ex_tval）的写口已移出本块，
            //     见下方 §5.3b 的独立无复位写进程；本块只留 `nq` 与三张表的 {valid, epoch}
            //     （它们**必须**扛复位：复位后 `*_v_q=0` 是读路径的唯一门控，见 §5.3b 头注）。
            if (upd_tr_valid) begin
                nq[upd_tr_idx][NQ_TRT]   <= upd_tr_taken;   // 提交侧 `tcp_tk` 仍吃 nq（保持原状）
                br_v_q[upd_tr_idx]       <= 1'b1;
                br_ep_q[upd_tr_idx]      <= nq[upd_tr_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            end
            if (upd_ff_valid) begin
                ff_v_q[upd_ff_idx]       <= 1'b1;
                ff_ep_q[upd_ff_idx]      <= nq[upd_ff_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            end
            if (upd_exc_valid) begin
                nq[upd_exc_idx][NQ_EXC_L +: 4] <= upd_exc_code;
                ex_v_q[upd_exc_idx]      <= 1'b1;
                ex_ep_q[upd_exc_idx]     <= nq[upd_exc_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            end

            // ---- 5.35 ★ B3/EXP-N3：头部窗口填充（上一拍发出的预取读在本拍到达）----
            //   ★★ EXP-N3：窗口只剩 `WIN_N = 2` 槽且**槽号 = lane 号** ⇒ 本步做的是
            //     "把 4 个 bank 读回值里对应当前预测组 `{hpred_w, hpred_w+1}` 的两项选进槽 0/1"。
            //     · 目标 `hpred_w`（= 本拍 `head + cmt_n`）**逐位等于下一拍的 head**
            //       （正常推进分支 `head_q <= head_q + cmt_n_w`）⇒ 填进去的正是下一拍要提交的组；
            //     · **只在 `~flush_all & ~squash_valid` 拍填**：这两拍 head 都不按 `cmt_n_w`
            //       前进（flush 另行把窗口清零；squash 保 head 不动 ⇒ 旧窗口内容仍是下一拍的
            //       正确组），照常填反而会用"错的预测索引"覆盖掉正确项（2 槽没有冗余空间）。
            //     · `fhit`（读命令基址与当前 head 脱节）与 `fdang`（`read_first` 同址）失配
            //       ⇒ 该槽置无效，下一拍凭新读回值重填（插一拍气泡；**绝不交付错 PC/tval**）。
            if (!flush_all && !squash_valid) begin
                win_q  [0] <= fdat0_w;
                win_idx[0] <= hpred_w;
                //   ★★ P1 根修：除"标签命中（fhit）+ 同址危险（fdang）"外，还必须
                //     **读命令发出那拍目标已分配（e_ok_q）且未穿越 flush 世代（e_bad_q）**。
                //     · e_ok_q=0 的反例：ROB 空/尾后索引的读回值只是旧程序残留；旧实现
                //       会把它当有效窗口，随后 alloc 命中同 index 时提交/中断吃旧 PC；
                //     · e_bad_q=1 的反例：flush 拍发出的读命令，T+1 读回的是旧 head 世代
                //       的载荷；若只清窗口而不拦这一拍填充，新 head=0（或 head+1）可能
                //       被旧数据重新贴上"匹配"标签。
                //   ⇒ 未分配项最多多等 1~2 拍重读（插气泡，不串行化提交），**绝不交付
                //     旧载荷**；fdang 保留为同拍读写的第二道保险。
                win_val[0] <= fhit0_w & ~fdang0_w & e_ok_q[fsel0_w] & ~e_bad_q;
                win_q  [1] <= fdat1_w;
                win_idx[1] <= fidx1_w;
                win_val[1] <= fhit1_w & ~fdang1_w & e_ok_q[fsel1_w] & ~e_bad_q;
            end
            //   预取地址打拍（下一拍用它给读回的数据定标签）
            //   ★ 与 §1.2 的 `e_rd_idx_flat` 同源（同拍、同一组地址），e_ok_q 与它
            //     同沿锁存 ⇒ 填窗时"标签 + live 判定"严格指向同一个读命令。
            for (k = 0; k < PF_W; k = k + 1)
                e_of_r_q[k] <= e_rd_idx_flat[k*ROB_IDX_W +: ROB_IDX_W];
            //   ★★ P1 根修：与 `e_of_r_q` **同拍同沿**锁存"读命令拍的 live / flush 世代"；
            //     下一沿填窗时使用的正是这一组（非阻塞赋值 ⇒ 填窗读旧值，标签/条件严格对齐）。
            e_ok_q  <= e_live_w;
            e_bad_q <= flush_all;
            //   记下本拍分配的索引（下一拍用于上面的危险判定）
            //   ★★ EXP-N1：分配槽数 = ALLOC_W（派发宽度，未变）。
            for (k = 0; k < ALLOC_W; k = k + 1) begin
                alloc_idx_q[k]   <= idx_add(tail_w, k[ROB_IDX_W-1:0]);
                alloc_idx_v_q[k] <= alloc_fire & alloc_lane_valid[k] & (k < alloc_n);
            end

            // ---- 5.4 指针推进（提交 / 冲刷 / 分配）----
            if (flush_all) begin
                for (k = 0; k < WIN_N; k = k + 1) win_val[k] <= 1'b0;   // ★ 冲刷后窗口不可信
                cnt_q   <= {(ROB_IDX_W+1){1'b0}};
                //   ★ 陷阱退役：头部异常项**弹出**（其余全清）；否则只清 cnt（原口径）
                head_q  <= trap_retire ? idx_add(head_q, {{ROB_IDX_W-1{1'b0}}, 1'b1})
                                       : {ROB_IDX_W{1'b0}};
                epoch_q <= epoch_q + 1'b1;
            end else if (squash_valid) begin
                epoch_q <= epoch_q + 1'b1;
                // 保留 [head, squash_idx]（含分支自身）
                //   ★ C8：改用 §1.1 的唯一年龄计算点（原为就地重算 `squash_idx - head_q`）
                cnt_q <= {1'b0, age_sq_w} + {{ROB_IDX_W{1'b0}}, 1'b1};
            end else begin
                head_q <= idx_add(head_q, cmt_n_w);
                cnt_q  <= cnt_q - {5'b0, cmt_n_w}
                          + (alloc_fire ? {5'b0, alloc_n} : {(ROB_IDX_W+1){1'b0}});
                if (cmt_chain[0]) cmt_cnt_q <= cmt_cnt_q + {29'b0, cmt_n_w};
            end
        end
    end

    //==========================================================================
    // 5.3b ★★ EXP-N34B3：三张 typed 表的**数据数组**写口（独立无复位写进程）
    //==========================================================================
    //   根因（与 N34B-1 的 `lht_mem` 完全同源）：改前 `br_tgt_q/br_taken_q/ff_q/ex_tval_q`
    //   的写口与 `nq`/`*_v_q`/`*_ep_q` 共用 §5 的 `always @(posedge clk or negedge rst_n)`。
    //   Vivado 的 RAM 推断要求存储阵列的写进程敏感性表**不含异步复位**，否则整表被判为
    //   "带异步复位的 RAM"并退化成触发器阵列 —— 基线日志 `synth_2b_n34b1_...vivado.log`
    //   `:1046/1050/1054/1058` 的 reason 字符串逐条明写
    //   `RAM is sensitive to asynchronous reset signal. this RTL style is not supported.`
    //
    //   ★★ 复位语义审计（逐阵，结论：四阵全部可搬）：
    //     · 四张数据数组**从未**在复位分支里被赋值（§5 的 `if (!rst_n)` 只清 `nq` 与
    //       三张表的 `{valid, epoch}` 以及窗口/指针）⇒ 搬家不改复位行为；
    //     · 四阵的**全部**读点都在 `merge_upd(...)`（`:525-527`）与陷阱口 `trap_tval`
    //       （`:543`），命中判据 `br_use/ff_use/ex_use` 恒含 `*_v_q[idx]`：
    //         `br_use[gi] = br_v_q[idx] & (br_ep_q[idx] == ep_gi) & slot_is_br[gi]`
    //         `ff_use[gi] = ff_v_q[idx] & (ff_ep_q[idx] == ep_gi) & slot_is_fp[gi]`
    //         `ex_use[gi] = ex_v_q[idx] & (ex_ep_q[idx] == ep_gi) & …`
    //       而 `*_v_q` 在复位分支被清 0 ⇒ 复位后 `*_use ≡ 0`（4 态下 `0 & x = 0`，无 x 传播）
    //       ⇒ `merge_upd` 走常量 0 回落支路、`trap_tval` 走载荷支路
    //       ⇒ **复位后的任何读都被有效位严格门控**，LUTRAM 无复位不引入可观测差异。
    //       该前提在源码头注 `:238-239` 已声明（"数据数组不置复位（valid=0 时被 merge 的
    //       回落支路屏蔽，无 x 传播）；valid/epoch 数组复位清零"），本步只是把该声明
    //       与综合推断所要求的**写进程形态**对齐。
    //     · `rst_n` 作为**同步**使能保留在写条件里 ⇒ 与改前逐位同语义（改前 rst_n=0 的拍
    //       在 `if (!rst_n)` 分支，不写；新块在 `if (rst_n)` 门内，同样不写）。
    //     · 每张数组在本块内**恰好一个写语句**（br_tgt/br_taken 同属 `upd_tr_valid`，
    //       但它们是两张独立数组、各一个写口；ff/ex 各自一个）⇒ Vivado 的单写口要求满足。
    //     · 写条件与 §5.3 的三个 `if` **逐字同源**，同一拍采样同一组输入，无先后竞争
    //       （新块不读 `nq`，§5.3 里的 `br_ep_q <= nq[...]` 与本块无变量交叠）。
    always @(posedge clk) begin
        if (rst_n) begin
            if (upd_tr_valid) begin
                br_tgt_q[upd_tr_idx]   <= upd_tr_target;
                br_taken_q[upd_tr_idx] <= upd_tr_taken;
            end
            if (upd_ff_valid)  ff_q[upd_ff_idx]       <= upd_ff_flags;
            if (upd_exc_valid) ex_tval_q[upd_exc_idx] <= upd_exc_tval;
        end
    end

    //   ★★ EXP-N35B 自检（**取代**原"窄表 `nq` vs 宽载荷"恒等自检）：被删的 23 bit 在 `nq`
    //     之外再存一份**仿真专属影子副本**，在提交同拍把"从载荷窗口读出的 23 bit"与影子
    //     逐位比对。
    //     · 影子由**派发写口**（`alloc_payload`，与真载荷同源同拍）写入；
    //     · 比对侧读**载荷窗口**（`win_rd[gi]` = BRAM 读回 → 窗口 FF）——正是改动后提交链的
    //       真实数据来源；
    //     ⇒ 覆盖"这 23 bit 经 BRAM+窗口往返 + 槽位映射 + 位域抽取"的全部新增风险，与改前
    //       那把尺子（nq vs 载荷）**等效**，只是尺子本身不再进硬件。
    //     `RV32GC_USE_VIVADO_IP` 由综合入口 `synth_design` 显式定义（fpga/tcl/synth.tcl:62）
    //     ⇒ 影子数组与比较逻辑**整体不进网表**（对 N35B 的面积结论零影响）。
    //   ⚠ 改前那条自检的对象是"`nq` 里 23 bit 的**重复副本**"；本改动把重复副本删除后，
    //     该对象在硬件里已不存在（单一真源），故此处改为"影子验证被删位的**新读路径**"。
`ifndef RV32GC_USE_VIVADO_IP
    reg [19:0] nq20_sh [0:ROB_N-1];
    //   20 bit 抽取（顺序 = 旧 `nq` 布局 MSB→LSB：arn | is_csr | df | di | pdf | pdi）
    function [19:0] grp20;
        input [RB_W-1:0] p;
        begin
            grp20 = { p[`BACK2_RB_ARND_MSB:`BACK2_RB_ARND_LSB],
                      p[`BACK2_UB_IS_CSR],
                      p[`BACK2_UB_RD_F_WEN],
                      p[`BACK2_UB_RD_I_WEN],
                      p[`BACK2_RB_PDFDST_MSB:`BACK2_RB_PDFDST_LSB],
                      p[`BACK2_RB_PDIDST_MSB:`BACK2_RB_PDIDST_LSB] };
        end
    endfunction
    integer gk23;
    always @(posedge clk) begin
        if (rst_n) begin
            for (gk23 = 0; gk23 < COMMIT_W; gk23 = gk23 + 1) begin
                //   只在"该项本拍真的可提交"时比对（`cmt_valid` 已含 `win_lane_ok` 与
                //   `slot_in_range` ⇒ 该索引必已被派发写过 ⇒ 影子有效，不会读到 x）。
                if (cmt_valid[gk23] &&
                    (grp20(win_rd[gk23]) !== nq20_sh[slot_idx[gk23]]))
                    $display("ROB-N35B-CHK MISMATCH: lane=%0d idx=%0d win=0x%05x sh=0x%05x",
                             gk23, slot_idx[gk23], grp20(win_rd[gk23]),
                             nq20_sh[slot_idx[gk23]]);
            end
        end
    end
`endif

    //==========================================================================
    // 6. ★★ EXP-B §29：typed 表 assertion（仿真专属；`ifndef RV32GC_USE_VIVADO_IP`）
    //==========================================================================
    //   ① 写口自检（单写源正确性）：上一拍的三个写口必须**逐位落到对应表**（valid/epoch/数据）。
    //      —— 三张表各只有一个写源（`br_q`←upd_tr / `ff_q`←upd_ff / `ex_q`←upd_exc），
    //      故同拍 br/ff/exc 写**不同表绝不冲突**（结构上各自独立写口，无需任何仲裁）；
    //      本自检即该不变式的逐拍证据（含"同拍多表写同一索引"的边界拍）。
    //   ② 采用不变式：提交的分支必有 br 表命中；提交的 FP 必有 ff 表命中；
    //      头部陷阱且"派发期无异常、现异常"（⇒ 异常由 LSU 回写）必有 ex 表命中。
    //      ⚠ `commit_exc → ex_v_q` 不能用 `cmt_valid` 作前件：`slot_ok` 已含 `~slot_exc`
    //        ⇒ 带异常项**永不提交**，其断言锚点只能是 `trap_valid`（头部精确陷阱点）。
    //   失败打印一律带 `ROB-ASSERT` 字样（判定脚本按该字样判失败，兜底文案不含 PASS）。
`ifndef RV32GC_USE_VIVADO_IP
    integer bk;
    reg                    w_br_v, w_ff_v, w_ex_v;
    reg [ROB_IDX_W-1:0]    w_br_i, w_ff_i, w_ex_i;
    reg [`BACK2_BR_TAKEN_W-1:0] w_br_tk;
    reg [`BACK2_BR_TGT_W-1:0]   w_br_tg;
    reg [`BACK2_FF_W-1:0]       w_ff_d;
    reg [`BACK2_EX_TVAL_W-1:0]  w_ex_tv;
    reg [`BACK2_EPOCH_W-1:0]    w_br_ep, w_ff_ep, w_ex_ep;
    //   ⚠ 本块的"写口影子"必须**随异步复位清零**：否则复位前采到的写口会在复位后的
    //     第一个 posedge 与（已被复位清零的）表内容比对 ⇒ 程序边界的假失败（实测过）。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_br_v <= 1'b0; w_ff_v <= 1'b0; w_ex_v <= 1'b0;
        end else begin
            // ---- ① 写口自检（核对上一拍的写）----
            if (w_br_v) begin
                if (br_v_q[w_br_i]   !== 1'b1)          $display("ROB-ASSERT-BR FAIL: valid  idx=%0d", w_br_i);
                if (br_ep_q[w_br_i]  !== w_br_ep)       $display("ROB-ASSERT-BR FAIL: epoch  idx=%0d", w_br_i);
                if (br_tgt_q[w_br_i] !== w_br_tg)       $display("ROB-ASSERT-BR FAIL: tgt    idx=%0d", w_br_i);
                if (br_taken_q[w_br_i] !== w_br_tk)     $display("ROB-ASSERT-BR FAIL: taken  idx=%0d", w_br_i);
            end
            if (w_ff_v) begin
                if (ff_v_q[w_ff_i]   !== 1'b1)          $display("ROB-ASSERT-FF FAIL: valid  idx=%0d", w_ff_i);
                if (ff_ep_q[w_ff_i]  !== w_ff_ep)       $display("ROB-ASSERT-FF FAIL: epoch  idx=%0d", w_ff_i);
                if (ff_q[w_ff_i]     !== w_ff_d)        $display("ROB-ASSERT-FF FAIL: flags  idx=%0d", w_ff_i);
            end
            if (w_ex_v) begin
                if (ex_v_q[w_ex_i]   !== 1'b1)          $display("ROB-ASSERT-EX FAIL: valid  idx=%0d", w_ex_i);
                if (ex_ep_q[w_ex_i]  !== w_ex_ep)       $display("ROB-ASSERT-EX FAIL: epoch  idx=%0d", w_ex_i);
                if (ex_tval_q[w_ex_i] !== w_ex_tv)      $display("ROB-ASSERT-EX FAIL: tval   idx=%0d", w_ex_i);
            end
            // ---- ② 采用不变式（提交组 4 lane）----
            for (bk = 0; bk < COMMIT_W; bk = bk + 1) begin
                if (cmt_valid[bk] & slot_is_br[bk] & ~br_use[bk])
                    $display("ROB-ASSERT-BR FAIL: commit branch without br table t=%0t lane=%0d idx=%0d",
                             $time, bk, slot_idx[bk]);
                if (cmt_valid[bk] & slot_is_fp[bk] & ~ff_use[bk])
                    $display("ROB-ASSERT-FF FAIL: commit fp without ff table t=%0t lane=%0d idx=%0d",
                             $time, bk, slot_idx[bk]);
            end
            if (trap_valid & (|nq[slot_idx[0]][NQ_EXC_L +: 4])
                           & (win_rd[0][`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB] == 4'd0)
                           & ~ex_use[0])
                $display("ROB-ASSERT-EX FAIL: trap with LSU exc but no ex table t=%0t idx=%0d",
                         $time, slot_idx[0]);
            // ---- 采样本拍三个写口（下一拍核对）----
            w_br_v  <= upd_tr_valid;
            w_br_i  <= upd_tr_idx;
            w_br_ep <= nq[upd_tr_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            w_br_tg <= upd_tr_target;
            w_br_tk <= upd_tr_taken;
            w_ff_v  <= upd_ff_valid;
            w_ff_i  <= upd_ff_idx;
            w_ff_ep <= nq[upd_ff_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            w_ff_d  <= upd_ff_flags;
            w_ex_v  <= upd_exc_valid;
            w_ex_i  <= upd_exc_idx;
            w_ex_ep <= nq[upd_exc_idx][NQ_EP_L +: `BACK2_EPOCH_W];
            w_ex_tv <= upd_exc_tval;
        end
    end

    //   ★★ EXP-B：载荷占位字段恒 0 自检 —— `merge_upd` 的 br/ff 回落支路用**常量 0**
    //     的前提（载荷 [405:401]/[400]/[399:368] 只有派发一个写源、恒写 5'b0/1'b0/32'h0，
    //     见 `backend_top.v` 的 ROB 载荷组装式）。口径与上面的 nq 自检一致：只在"该索引
    //     非本拍/上拍刚分配"且"在 ROB 当前范围内"时比对（否则读到的是无效/旧值）。
    integer zk;
    always @(posedge clk) begin
        if (rst_n) begin
            for (zk = 0; zk < 4; zk = zk + 1) begin
                if (!(alloc_idx_v_q[0] & (alloc_idx_q[0] == e_of_r_q[zk]) |
                      alloc_idx_v_q[1] & (alloc_idx_q[1] == e_of_r_q[zk]) |
                      alloc_idx_v_q[2] & (alloc_idx_q[2] == e_of_r_q[zk]) |
                      alloc_idx_v_q[3] & (alloc_idx_q[3] == e_of_r_q[zk])) &&
                    (((e_of_r_q[zk] - head_q) & 7'h7F) < cnt_q)) begin
                    if ((pl_rdata[zk][`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB] !== 5'h0) ||
                        (pl_rdata[zk][`BACK2_RB_TRTAKEN] !== 1'b0) ||
                        (pl_rdata[zk][`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB] !== 32'h0))
                        $display("ROB-ASSERT-PAY0 FAIL: 载荷占位字段非 0（merge 回落常量前提被破坏）idx=%0d fflags=%b trtaken=%b trtgt=0x%08x",
                                 e_of_r_q[zk],
                                 pl_rdata[zk][`BACK2_RB_FFLAGS_MSB:`BACK2_RB_FFLAGS_LSB],
                                 pl_rdata[zk][`BACK2_RB_TRTAKEN],
                                 pl_rdata[zk][`BACK2_RB_TRTGT_MSB:`BACK2_RB_TRTGT_LSB]);
                end
            end
        end
    end
`endif

endmodule
