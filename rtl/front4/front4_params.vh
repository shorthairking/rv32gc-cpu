//==============================================================================
// rtl/front4/front4_params.vh —— 2B-1 四发射顺序前端 + 锦标赛预测器 参数真源
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 依据  : docs/design/04-predictor.md §3.1（结构参数表，**唯一取值来源**）——
//           · Gshare：GPHT 4096 项 × 2 bit；索引 PC[13:2] XOR GHR[15:4]；GHR 16 bit
//           · 局部  ：LHT 1024 项 × 10 bit（索引 PC[11:2]）；LPHT 1024 × 2 bit
//                     （索引 LHT[PC] XOR PC[11:2]）
//           · 选择器：1024 项 × 2 bit（索引 PC[11:2]），复位 2'b01（弱偏局部）
//           · BTB   ：2048 项 2 路（1024 组）；组索引 PC[12:2]（11 bit）；tag 30 bit
//                     （PC[31:2]，即**按 4 B 字**粒度）；target 32 bit +
//                     is_call/is_return/is_cond/valid
//           · RAS   ：16 项，溢出**不压入**
//         docs/design/04-predictor.md §3.2（选择器状态机）、§4（BTB/RAS）、
//         §5（训练时机=提交点）、§6（统计计数器口径）。
//         docs/design/02-pipeline.md §3.1–§3.4（F1–F4 逐级定义）、§4（4 路取指资源
//         冲突与停顿）、§6.2（冲刷信号语义）。
//         AGENT.md §3.2（位域/接口先改唯一真源）、§4 红线 1/2/3。
//
// ★ 为什么参数放这里而不是 rtl/pkg/core_params.vh：
//   core_params.vh §4 明文规定「2B（4 发射乱序、11 级）是后置里程碑，本文件不得
//   预置其参数」⇒ 2B-1 的参数**不得**写进 2A 的 pkg 真源。本文件是 rtl/front4/
//   自己的真源，随 2B-2 落地后再决定是否上提到 core_params.vh。
//
// ★ 与 2A 共享的量（RESET_PC / XIP 窗口 / parcel 宽度 / PMP）**不在这里重复定义**：
//   一律 `include "rtl/pkg/core_params.vh"`（+ rv32_defs.vh）取用，避免两处口径。
//
// 存储实现（AGENT.md §4 红线 1/2；04 §2「存储实现约束」）：
//   所有表（GPHT/LPHT/LHT/选择器/BTB）在**综合分支**（`RV32GC_USE_VIVADO_IP` 定义，
//   由综合脚本给）走 Vivado **XPM 参数化存储宏**（xpm_memory_*，Vivado 原生提供的
//   存储 IP 宏，**不是原语**、也不需要预生成 xci —— 本任务的文件范围禁改
//   fpga/tcl/create_ip.tcl 与 fpga/ip/，故用 XPM 而非 blk_mem_gen_* 预生成 IP）；
//   仿真分支（宏未定义，iverilog/Verilator 默认）走**逐拍等价行为模型**（同步读、
//   读延迟 1 拍、写优先）。双分支端口契约逐位一致，TB 只依赖行为模型。
//==============================================================================

`ifndef FRONT4_PARAMS_VH
`define FRONT4_PARAMS_VH

//------------------------------------------------------------------------------
// 1. 发射宽度与取指缓冲
//------------------------------------------------------------------------------
`define FRONT4_LANES            4        // 4 发射（AGENT.md §1 硬性指标）
//   ★ 缓冲必须**跨行**存得下"低半在上一行最后一个 parcel、高半在下一行第一个 parcel"
//     的 32 bit 指令 ⇒ 容量取 **2 个 32 B 行**（16 字 = 32 个 16 bit parcel）。
//     只留 1 行（16 parcel）时，跨行指令的高半会绕回缓冲头（TB 的 C2 跨行用例打出过）。
`define FRONT4_BUF_WORDS        16       // 取指缓冲 16 字 = 64 B（= 2 × L1I 行大小）
`define FRONT4_BUF_PARCELS      (`FRONT4_BUF_WORDS * 2)   // 32 个 16 bit parcel
`define FRONT4_BUF_INSNS        8        // 指令队列深度（条）
`define FRONT4_LOOKUP_LANES     2        // 每拍做 2 个 parcel 的预测查表（= 1 字）

//------------------------------------------------------------------------------
// 2. 全局分量 Gshare（04 §3.1）
//------------------------------------------------------------------------------
`define FRONT4_GHR_BITS         16       // 全局历史寄存器 GHR 位宽
`define FRONT4_GPHT_ENTRIES     4096     // 全局 PHT 项数
`define FRONT4_GPHT_IDX_BITS    12       // log2(4096)
`define FRONT4_GPHT_HASH_LO     4        // GHR[15:4] 参与 XOR（04 §3.1 明文）
`define FRONT4_CTR_BITS         2        // 饱和计数器位宽（2 bit；04 §3.1 取舍）

//------------------------------------------------------------------------------
// 3. 局部分量（LHT + LPHT，04 §3.1）
//------------------------------------------------------------------------------
`define FRONT4_LHT_ENTRIES      1024     // 局部历史表项数
`define FRONT4_LHT_IDX_BITS     10       // log2(1024)（索引 PC[11:2]）
`define FRONT4_LHT_BITS         10       // 每项历史位宽（近 10 次方向）
`define FRONT4_LPHT_ENTRIES     1024     // 局部 PHT 项数
`define FRONT4_LPHT_IDX_BITS    10

//------------------------------------------------------------------------------
// 4. 选择器（04 §3.1/§3.2）
//------------------------------------------------------------------------------
`define FRONT4_SEL_ENTRIES      1024
`define FRONT4_SEL_IDX_BITS     10
`define FRONT4_SEL_INIT         2'b01    // 复位 = WEAK_LOCAL（弱偏局部；04 §3.2）
`define FRONT4_SEL_GLOBAL_BIT   1        // 计数器高位 = 1 ⇒ 选 Gshare（04 §3.2 投票）

//------------------------------------------------------------------------------
// 5. BTB（04 §4.1）
//------------------------------------------------------------------------------
`define FRONT4_BTB_ENTRIES      2048     // 项数
`define FRONT4_BTB_WAYS         2        // 2 路组相联
`define FRONT4_BTB_SETS         1024     // 组数 = 2048/2
//   ★ 口径澄清（文档不自洽，唯一解释处）：docs/design/04-predictor.md §4.1 同时写了
//     「2048 项、2 路组相联（1024 组）」与「组索引 PC[12:2]（11 bit）」——11 bit 索引
//     ⇒ 2048 组 ⇒ 4096 项，与「2048 项」矛盾。**按项数/相联度优先**（硬指标是"2048 项"）：
//     1024 组 × 2 路 ⇒ 索引取 PC[11:2]（10 bit）；tag 仍按文档明文取 PC[31:2]（30 bit，
//     含索引位，作**全字地址校验**，与文档"tag 30 bit"一致）。已记入 README §3 口径表。
`define FRONT4_BTB_IDX_BITS     10       // 组索引 PC[11:2]（1024 组 × 2 路 = 2048 项）
`define FRONT4_BTB_TAG_BITS     30       // tag = PC[31:2]（**按 4 B 字**粒度）

//------------------------------------------------------------------------------
// 6. RAS 与检查点（04 §4.2/§5.3；03 §3.4 检查点数量 16）
//------------------------------------------------------------------------------
`define FRONT4_RAS_DEPTH        16       // 返回地址栈深度（溢出 = 不压入）
`define FRONT4_RAS_PTR_BITS     5        // 深度 16 ⇒ 深度计数 0..16 需 5 bit
`define FRONT4_CKPT_NUM         16       // 分支检查点个数（03 §3.4）

//------------------------------------------------------------------------------
// 7. 计数器复位值 / 口径常量
//------------------------------------------------------------------------------
`define FRONT4_CTR_INIT         2'b01    // PHT 复位 = 弱不跳（预测 taken 判 ctr[1]）
`define FRONT4_TRAIN_FIFO_DEPTH 8        // 提交侧训练事件 FIFO 深度（吸收 4 条/拍突发）


//------------------------------------------------------------------------------
// 8. 预测查表结果打包（predictor_top → ifetch4；**位段唯一定义处**）
//    一次查表 = 1 个取指字 = 2 个 parcel；BTB 信息是**字粒度**（两个 parcel 共享），
//    方向/选择器信息是**parcel 粒度**（分支可能落在任一半）。
//------------------------------------------------------------------------------
`define FRONT4_LU_PT0        0        // 锦标赛最终方向（parcel 0）
`define FRONT4_LU_PT1        1        // 锦标赛最终方向（parcel 1）
`define FRONT4_LU_G0         2        // Gshare 侧方向
`define FRONT4_LU_G1         3
`define FRONT4_LU_L0         4        // 局部侧方向
`define FRONT4_LU_L1         5
`define FRONT4_LU_S0         6        // 选择器选了全局侧
`define FRONT4_LU_S1         7
`define FRONT4_LU_BTB_HIT    8
`define FRONT4_LU_BTB_WAY    9
`define FRONT4_LU_BTB_CND   10
`define FRONT4_LU_BTB_CALL  11
`define FRONT4_LU_BTB_RET   12
`define FRONT4_LU_BTB_TGT_LO 13       // target[31:0] → [44:13]
`define FRONT4_LU_PACK_W    45

`endif // FRONT4_PARAMS_VH
