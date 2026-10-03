//==============================================================================
// rtl/back2/back2_params.vh —— 2B-2 乱序后端：参数 + 微操作(uop)位域唯一真源
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2：ROB 64 + 物理寄存器重命名 + 分布式发射队列）
// 规格  : docs/design/03-out-of-order.md §2（ROB 项 / 顺序提交 ≤4）、§3（物理寄存器
//         96/64 + RAT + 变更日志 + 16 检查点）、§4（6 部件 + 分布式 RIQ 深度）、
//         §4.3（唤醒广播 + 最老优先选择 + 单端口）、§5（I2 读 PRF + 旁路）、
//         §8（精确异常与顺序提交）、§8.2（epoch 过滤）；
//         docs/design/02-pipeline.md §3.6–§3.11（D2 重命名 / D3 派发 / I1 选择 /
//         I2 读口 / E1 执行 / W1 提交）、§4.1（停顿源 S3/S4/S5）、§5（衔接三硬规则）；
//         docs/design/01-overview-datapath.md（位宽口径）。
//
// 版本纪律: 本文件是 back2 内部「参数 + uop 位域」的**唯一真源**；改动先改这里，
//           再同步所有使用处（AGENT.md §3.2）。
//
// 风格  : Verilog-2001 兼容；只允许 localparam / `define / `ifdef；无 always、无模块。
//==============================================================================
`ifndef BACK2_PARAMS_VH
`define BACK2_PARAMS_VH

//==============================================================================
// 1. 结构参数（逐项对照 docs/design/03-out-of-order.md）
//==============================================================================
// ---- ROB（§2.1；★ L3 面积杠杆：深度 128→64，条目数由用户裁决降档）----
//   ★ ROB 128→64（2026 面积分析 L3）：只降"在飞指令数上限"，**不改任何指令语义**。
//     `BACK2_ROB_IDX_W` 必须 == log2(ROB_N)：rob.v 的存储表 `nq` 与三张 typed 更新表与
//     `rob_wide_mem` 的 bank 寻址都按 ROB_IDX_W 位宽取模 ⇒ 宽度写错会越界。
//     ROB 深度须为 2 的幂（环形指针截断即取模，见 rob.v §1）。
`define BACK2_ROB_N          64
`define BACK2_ROB_IDX_W      6          // log2(64)

// ---- 物理寄存器（§3.2：整数 96 / 浮点 64，分离 free list）----
`define BACK2_PRF_I_N        96         // 整数物理寄存器数
`define BACK2_PREG_I_W       7          // 整数物理号宽（0–95）
`define BACK2_PRF_F_N        64         // 浮点物理寄存器数
`define BACK2_PREG_F_W       6          // 浮点物理号宽（0–63）
`define BACK2_ARCH_N         32         // 架构寄存器数（x0/x1..x31、f0..f31）
`define BACK2_ARN_W          5
`define BACK2_FREE_I_N       64         // 整数 free list 容量（不含架构基线 32）
`define BACK2_FREE_F_N       32         // 浮点 free list 容量（不含架构基线 32）

// ---- 发射宽度 / 提交宽度（§1：4 发射；提交 ≤4 条/拍）----
`define BACK2_DISP_W         4
`define BACK2_COMMIT_W       4          // ★ 反证实验改这一处（1 ⇒ 变相顺序提交）

// ---- 分支检查点（§3.4：16 个）----
`define BACK2_CKPT_N         16
`define BACK2_CKPT_ID_W      4

// ---- RAT 变更日志（§3.4：history buffer；每拍 4 条一组，指针恒为 4 的倍数）----
`define BACK2_RATLOG_N       64         // = ROB_N（每 ROB 项至多 1 个目的寄存器）
//   指针宽度保持 8 不动：模 256 指针 ⇒ 距离 ≤ 64 仍无歧义（若用模 128 的 7 bit 指针，
//   "距离 64"会与"距离 0"撞车 ⇒ 日志回滚范围误判）。L3 只改 RATLOG_N，不改 PTR_W。
`define BACK2_RATLOG_PTR_W   8          // 模 256 指针 ⇒ 距离无歧义（距离 ≤ 64）
`define BACK2_RATLOG_G       4          // 每拍一组 4 条

// ---- free list 指针（模 256 环形；容量 64/32 ≪ 256）----
`define BACK2_FL_PTR_W       8

// ---- epoch（§8.2：2 bit，冲刷递增；RIQ/SQ 出队时比较）----
`define BACK2_EPOCH_W        2

// ---- 分布式发射队列深度（§4.2 原口径：ALU0/1=16、BRU=8、MDU=8、LSU=12、FPU=8）----
//   ★★ C2 面积杠杆（IQ 深度与 ROB 对齐，纯容量缩减）：原总容量
//     16+16+8+8+12+8 = **68 > ROB_N=64**，而每个 IQ 项在提交/发射上都是**某个 ROB 项
//     的从属**（IQ 项 ⊆ ROB 项，1:1 由 rob 索引标识）⇒ 超出 64 的那 4 个槽在满窗口时
//     **结构性不可能被填满**（派发受 ROB 容量阻塞），是死容量。
//     新口径 **12+12+6+6+8+6 = 50**（= ROB_N 64 的 ~78%，按各部件实测占用重定：
//     ALU 12、BRU/MDU/FPU 6、LSU 8），`BACK2_IQ_MAX_D` 16→12 同步收窄实例化上界。
//     **不改任何指令语义**：iq.v / backend_top.v 的存储、写口分配、最老优先选择、
//     冲刷作废、唤醒矩阵全部按 `DEPTH`/`BACK2_IQ_*_D` 参数化（无字面深度）。
//     ⚠ 深度上限 12 ≤ 16 ⇒ `free_cnt`/`cnt_o` 的 5 bit 宽度口径不变；
//       写口数 `BACK2_IQ_WR_PORTS` 保持 4 不动（派发宽度 4 未变）。
`define BACK2_IQ_ALU0_D      12
`define BACK2_IQ_ALU1_D      12
`define BACK2_IQ_BRU_D       6
`define BACK2_IQ_MDU_D       6
`define BACK2_IQ_LSU_D       8
`define BACK2_IQ_FPU_D       6
`define BACK2_IQ_MAX_D       12         // 通用 iq.v 的实例化上界（参数）
`define BACK2_IQ_WR_PORTS    4          // 每队列写口 ≤4/拍（02 §4.2）

// ---- 唤醒/写回总线端口数（6 个执行部件各 1 个写回口）----
`define BACK2_WB_N           6

// ---- LSQ（2B-3：SQ 32 + LQ 32；本文件是容量/位宽唯一真源）----
//   ★ 2B-3 第 6 段第一步：SQ 16→32（索引宽度 4→5），LQ 4→32（在途表 → 32 项 LQ）。
//     `BACK2_STQ_IDX_W` 只被 lsq_simple.v 与 backend_top.v 的 6 处位宽引用使用；
//     LQ 深度改变只牵动 lsq_simple.v 内部与内存标签宽度（见 `BACK2_MEM_TAG_W`）。
//   ★ 2B-5 L5（面积杠杆）：**LQ 32→16**（索引 5→4）——纯容量缩减，只降低"在飞 load
//     数上限"，不改任何指令语义（槽位仍在 D3 派发期分配、提交点释放；转发/请求/响应
//     逐拍逻辑全部按 `OUT_N`/`LQ_IW` 参数化，无字面宽度）。SQ 保持 32 不动。
`define BACK2_STQ_N          32
`define BACK2_STQ_IDX_W      5
`define BACK2_LQ_N           16
`define BACK2_LQ_IDX_W       4
//   标签宽度 = log2(LQ_N) + 1：槽标签用 0..LQ_N-1（最高位恒 0），**store 提交排空的
//   标签取全 1** ⇒ 恰好多留 1 bit 才不会与末号槽撞车（LQ_N=4 时 3 bit 的旧口径只是
//   因为 2 bit 槽号 + 1 bit 分隔位；LQ_N=16 ⇒ 4 bit 槽号 + 1 bit 分隔位 = 5 bit；
//   LQ_N=32 时曾同步为 6 bit）。
`define BACK2_MEM_TAG_W      5
`define BACK2_MEM_OUT_N      `BACK2_LQ_N     // 在途访存槽（MSHR 口径）= LQ 深度
//   提交排空队列（CDQ）深度：rob.v 允许**同拍最多 4 条 store 提交**，而排空口每拍只发一笔
//   ⇒ LSQ 必须能暂存"提交组内的其余 store"，否则它们会被提交却永不落地（2B-3 登记的
//   `遗留 ①`，2B-4 由 p4_fpu 的 8 连 store 实测触发）。深度取 2×W = 8：
//   提交口 ≤4/拍、排空口 1/拍 ⇒ 8 深可吸收"连续两拍满组提交"的突发而无需背压。
`define BACK2_CDQ_N          8

// ---- 统计（§10 风险项口径）----
`define BACK2_STAT_W         32

//==============================================================================
// 2. uop 载荷位域（**唯一布局定义**；iq.v / rob.v / dispatch.v / backend_top.v 共用）
//------------------------------------------------------------------------------
//  说明：uop 在派发周期由「译码（decoder，只读复用 2A 器件）+ 重命名」组装成一个
//        打包向量（UOP_W 位）。发射队列按整条载荷存储；发射时整条交给 I2/E1。
//        ★ 布局一律从 bit0 向上累加，改一处必须同步本表与所有 `BACK2_U_*` 宏。
//==============================================================================
// ---- 异常（ROB 精确异常用；0 = 无异常）----
`define BACK2_U_EXC_MSB      3
`define BACK2_U_EXC_LSB      0          // [3:0]  异常码（mcause 低位映射；2=非法）

// ---- 标志位组 [19:4] ----
`define BACK2_U_FLAGS_MSB   19
`define BACK2_U_FLAGS_LSB    4
//   fl0  = rd_i_wen     写整数架构寄存器
//   fl1  = rd_f_wen     写浮点架构寄存器
//   fl2  = s1_i_use     源 1 取整数物理寄存器（ps1_i）
//   fl3  = s2_i_use     源 2 取整数物理寄存器（ps2_i）
//   fl4  = s1_f_use     源 1 取浮点物理寄存器（ps1_f）
//   fl5  = s2_f_use     源 2 取浮点物理寄存器（ps2_f）
//   fl6  = s3_f_use     源 3 取浮点物理寄存器（ps3_f；FMA）
//   fl7  = is_load      取数（含 FP load）
//   fl8  = is_store     存数（含 FP store）
//   fl9  = is_branch    控制转移（分支/jal/jalr）
//   fl10 = is_csr       CSR 指令（只在 ALU0 执行；§4.1）
//   fl11 = is_fp        FPU 运算（非访存）
//   fl12 = is_illegal   非法指令（提交点抛 cause 2）
//   fl13 = ckpt_valid   该 uop 携带前端检查点 id
//   fl14 = is_unsup     本里程碑不支持（AMO/LR/SC/cbo/ecall/ebreak/xRET/wfi）
//   fl15 = is_fpls      FP 访存（flw/fsw；LSU 内数据源为浮点域）
`define BACK2_FL_RD_I_WEN    0
`define BACK2_FL_RD_F_WEN    1
`define BACK2_FL_S1_I_USE    2
`define BACK2_FL_S2_I_USE    3
`define BACK2_FL_S1_F_USE    4
`define BACK2_FL_S2_F_USE    5
`define BACK2_FL_S3_F_USE    6
`define BACK2_FL_IS_LOAD     7
`define BACK2_FL_IS_STORE    8
`define BACK2_FL_IS_BRANCH   9
`define BACK2_FL_IS_CSR      10
`define BACK2_FL_IS_FP       11
`define BACK2_FL_IS_ILLEGAL  12
`define BACK2_FL_CKPT_VALID  13
`define BACK2_FL_IS_UNSUP    14
`define BACK2_FL_IS_FPLS     15

`define BACK2_U_CKPT_MSB     23
`define BACK2_U_CKPT_LSB     20         // [23:20] 前端检查点 id（4 bit）
`define BACK2_U_CLS_MSB      26
`define BACK2_U_CLS_LSB      24         // [26:24] 前端分支类别（front4 README §1）
`define BACK2_U_BROP_MSB     31
`define BACK2_U_BROP_LSB     27         // [31:27] {is_jalr, is_jal, insn[14:12]}
`define BACK2_U_RM_MSB       34
`define BACK2_U_RM_LSB       32         // [34:32] 浮点舍入模式（funct3）
`define BACK2_U_FPOP_MSB     40
`define BACK2_U_FPOP_LSB     35         // [40:35] 归一化浮点操作码（fpu.v 端口口径）
`define BACK2_U_CSRADDR_MSB  52
`define BACK2_U_CSRADDR_LSB  41         // [52:41] CSR 地址
`define BACK2_U_CSROP_MSB    55
`define BACK2_U_CSROP_LSB    53         // [55:53] CSR 操作（decoder §0：W/S/C）
`define BACK2_U_WBSEL_MSB    58
`define BACK2_U_WBSEL_LSB    56         // [58:56] 写回来源（decoder §0：WB_*）
`define BACK2_U_MUNSIGN      59         // [59]    load 是否零扩展（lbu/lhu）
`define BACK2_U_MSIZE_MSB    62
`define BACK2_U_MSIZE_LSB    60         // [62:60] 访存宽度（1/2/4 B）
`define BACK2_U_MEMOP_MSB    66
`define BACK2_U_MEMOP_LSB    63         // [66:63] 访存类别（decoder §0：MEM_*）
`define BACK2_U_ALUOP_MSB    70
`define BACK2_U_ALUOP_LSB    67         // [70:67] ALU 微操作（alu.v 端口口径）
`define BACK2_U_OPTYPE_MSB   74
`define BACK2_U_OPTYPE_LSB   71         // [74:71] 执行部件类型（decoder §0：OPT_*）
`define BACK2_U_PS3F_MSB     80
`define BACK2_U_PS3F_LSB     75         // [80:75] 源 3 浮点物理号（FMA）
`define BACK2_U_PS2F_MSB     86
`define BACK2_U_PS2F_LSB     81         // [86:81] 源 2 浮点物理号
`define BACK2_U_PS1F_MSB     92
`define BACK2_U_PS1F_LSB     87         // [92:87] 源 1 浮点物理号
`define BACK2_U_PS2I_MSB     99
`define BACK2_U_PS2I_LSB     93         // [99:93] 源 2 整数物理号
`define BACK2_U_PS1I_MSB     106
`define BACK2_U_PS1I_LSB     100        // [106:100] 源 1 整数物理号
`define BACK2_U_PDFOLD_MSB   112
`define BACK2_U_PDFOLD_LSB   107        // [112:107] 浮点旧映射（提交时释放）
`define BACK2_U_PDFDST_MSB   118
`define BACK2_U_PDFDST_LSB   113        // [118:113] 浮点新映射
`define BACK2_U_PDIOLD_MSB   125
`define BACK2_U_PDIOLD_LSB   119        // [125:119] 整数旧映射（提交时释放）
`define BACK2_U_PDIDST_MSB   132
`define BACK2_U_PDIDST_LSB   126        // [132:126] 整数新映射
`define BACK2_U_ARND_MSB     137
`define BACK2_U_ARND_LSB     133        // [137:133] 目的架构寄存器号
`define BACK2_U_IMM_MSB      169
`define BACK2_U_IMM_LSB      138        // [169:138] 立即数（decoder imm_o）
`define BACK2_U_PREDTGT_MSB  201
`define BACK2_U_PREDTGT_LSB  170        // [201:170] 预测目标（训练必须携带）
`define BACK2_U_TVAL_MSB     233
`define BACK2_U_TVAL_LSB     202        // [233:202] 原始指令位（非法指令 mtval）
`define BACK2_U_PC_MSB       265
`define BACK2_U_PC_LSB       234        // [265:234] 指令虚拟地址
`define BACK2_U_PRED_MSB     269
`define BACK2_U_PRED_LSB     266        // [269:266] {pred_taken, pred_selg, pred_gdir, pred_ldir}
`define BACK2_U_BTB_MSB      271
`define BACK2_U_BTB_LSB      270        // [271:270] {btb_hit, btb_way}
// ---- AUX（执行级需要的少量原始位；D1 译码期填好）----
`define BACK2_U_AUX_MSB      279
`define BACK2_U_AUX_LSB      272        // [279:272]
`define BACK2_UAX_RTYPE      272        //  [272]   R 型（OP）⇒ ALU 的 b 取 rs2
`define BACK2_UAX_AUIPC      273        //  [273]   auipc ⇒ ALU 的 a 取 pc
`define BACK2_UAX_FMT_MSB    275
`define BACK2_UAX_FMT_LSB    274        // [275:274] 浮点 fmt = insn[26:25]
`define BACK2_UAX_IL32       276        //  [276]   指令为 32 bit（链接值/顺序 PC 用）
`define BACK2_UAX_Q_MSB      279
`define BACK2_UAX_Q_LSB      277        // [279:277] 目标发射队列（0..5）
`define BACK2_U_SRC_MSB      303
`define BACK2_U_SRC_LSB      280        // [303:280] {9'b0, rs3(5), rs2(5), rs1(5)}（架构号）
`define BACK2_U_SRC1_LSB     280        // rs1 域 [284:280]
`define BACK2_U_SRC2_LSB     285        // rs2 域 [289:285]
`define BACK2_U_SRC3_LSB     290        // rs3 域 [294:290]
`define BACK2_UOP_W          304
// ---- uop 内 ps/pd 字段的整段掩码（派发期填重命名结果用）----
`define BACK2_U_PSPD_MSB     132        // PDIDST 段最高位
`define BACK2_U_PSPD_LSB     75         // PS3F 段最低位

//==============================================================================
// 2.5 ★★ C1（IQ 载荷瘦身）：IQ **窄载荷** 布局 + 发射期**宽载荷回读**宽度
//------------------------------------------------------------------------------
// 背景（C1 面积杠杆，fpga/scratch/redundancy_audit.md §4 C1）：
//   原先每个 IQ 槽存**整条 304 bit uop**（`iq.v` 的 `uop_q[0:DEPTH-1]`）。但 IQ 内部
//   逐槽真正消费的只有两组位：
//     ① 唤醒：5 个源物理号（PS1I/PS2I/PS1F/PS2F/PS3F）+ 5 个 `S*_USE`；
//     ② 发射门控：`IS_LOAD`（LSU 队列的 load 门）、`IS_CSR`（ALU0 的"CSR 只在 ROB 头
//        发射"门）、`RM==7`（FPU 的 DYN 舍入门）。
//   其余（PC/IMM/PREDTGT/ALUOP/… 执行期字段，以及 W1 才用的 CSROP/CSRADDR/CKPT）只在
//   I2/E1 及以后才用 ⇒ 不必逐槽复制。C1 把 IQ 存储改为**窄载荷**（本节的 `BACK2_IQN_*`
//   布局），宽字段在**发射拍按 rob 索引**从一张 4 bank SDP BRAM（`backend_top.v` 的
//   `u_iwmem`，复用 `rob_wide_mem` 结构）读回，**不增加发射级数**：
//     · 第 T 拍：IQ 选出 rob 索引 ⇒ 启动读（同步读 1 拍）；
//     · 第 T+1 拍：BRAM 输出寄存器给出的宽载荷直接作为 I2/E1 的 uop（与改前
//       `x_i2_uop` 寄存器同拍），故 **发射→执行仍是 1 拍**。
//
// ★ 唯一真源：本节是窄载荷布局的唯一真源。改动必须同步：
//     · `iq.v` 的 `pack_iqn()`（打包）与唤醒/门控位选；
//     · `backend_top.v` 的三个门控（is_csr / is_load / rm_dyn）。
// ★ 窄载荷**不含**任何执行期字段：宽载荷由 `BACK2_IW_W` 定义（见下）。
`define BACK2_IQN_PS1I_L    0          // [6:0]   源 1 整数物理号
`define BACK2_IQN_PS2I_L    7          // [13:7]  源 2 整数物理号
`define BACK2_IQN_PS1F_L    14         // [19:14] 源 1 浮点物理号
`define BACK2_IQN_PS2F_L    20         // [25:20] 源 2 浮点物理号
`define BACK2_IQN_PS3F_L    26         // [31:26] 源 3 浮点物理号（FMA）
`define BACK2_IQN_S1I_USE   32         // [32]    源 1 取整数物理寄存器
`define BACK2_IQN_S2I_USE   33         // [33]    源 2 取整数物理寄存器
`define BACK2_IQN_S1F_USE   34         // [34]    源 1 取浮点物理寄存器
`define BACK2_IQN_S2F_USE   35         // [35]    源 2 取浮点物理寄存器
`define BACK2_IQN_S3F_USE   36         // [36]    源 3 取浮点物理寄存器
`define BACK2_IQN_IS_LOAD   37         // [37]    uop 的 fl7（LSU 队列 load 门）
`define BACK2_IQN_IS_CSR    38         // [38]    uop 的 fl10（ALU0 "CSR 只在 ROB 头"门）
`define BACK2_IQN_RM_DYN    39         // [39]    uop 的 RM == 3'b111（FPU DYN 舍入门）
`define BACK2_IQN_W         40         // 窄载荷总宽（bit）
//
// 发射宽载荷宽度：**等于 uop 的低 280 位**（`uop[279:0]`）。
//   为什么可以截掉 [303:280]：那 24 bit 是 `{9'b0, rs3(5), rs2(5), rs1(5)}`（架构源号），
//   全仓库**唯一读点**是 D2 重命名请求（`backend_top.v:794-801`，读的是 D1 滑板里的
//   uop，不是发射载荷）⇒ 发射/执行/写回路径逐位不读它。截断后 `x_i2_uop[303:280]` 恒 0，
//   其下所有字段的**绝对 bit 位置逐位不变**（与 L5 的 STQ/LQ 字段同理）。
//   收益：BRAM 字宽 304→280（每 bank 4 个 RAMB36，而不是 5 个）。
`define BACK2_IW_W          280

// ---- ROB 项载荷 = uop 载荷 + ROB 专用字段（执行期回写）----
`define BACK2_RB_CSRW_MSB    335
`define BACK2_RB_CSRW_LSB    304        // [335:304] CSR 新值（csr_op 按 W/S/C 由 ALU 算好）
`define BACK2_RB_TVAL_MSB    367
`define BACK2_RB_TVAL_LSB    336        // [367:336] 异常附加值（mtval/stval）
`define BACK2_RB_TRTGT_MSB   399
`define BACK2_RB_TRTGT_LSB   368        // [399:368] 分支实际目标（训练用）
`define BACK2_RB_TRTAKEN     400        // [400]     分支实际方向（训练用）
`define BACK2_RB_FFLAGS_MSB  405
`define BACK2_RB_FFLAGS_LSB  401        // [405:401] 浮点 flags 累积（FPU done 时）
//   ★ 2B-3 第 6 段第一步：STQ 索引 4→5 bit。**位域位置必须逐位核对**——
//     本载荷在 backend_top 的组装式 `{stq_idx, 5'b0, 1'b0, 32'h0, tval, {25'b0,ps1i}, uop}`
//     是**右对齐（LSB 对齐）**拼接、高位由赋值零扩展 ⇒ **加宽最顶端的 STQ 字段只会向上
//     生长，其下所有字段（fflags/trtgt/CSRW/uop…）的绝对 bit 位置逐位不变**。
//     故 STQ_MSB 409→410、**STQ_LSB 恒为 406**、`BACK2_RB_W` 恒为 416
//     （顶端保留位由 [415:410] 6 bit 缩为 [415:411] 5 bit）。
//     ⚠ 不可写成 LSB 406→405：那会让 5 bit 字段跨进 [405]（= fflags 最高位），
//       `p_stq` 取值将含 fflags 位而丢掉 STQ 高位。
`define BACK2_RB_STQ_MSB     410
`define BACK2_RB_STQ_LSB     406        // [410:406] store queue 项索引（≤32 项）
//   ★ 2B-4 第二步：**LQ 索引**放入顶端空闲位 [415:411]（5 bit，正好用尽 ⇒ RB_W 仍 416）。
//     与 STQ 字段同理：拼接式右对齐+高位零扩展 ⇒ 加在**最顶端**不影响其下任何字段位置。
//     LQ 在 **D3 派发期**分配（程序序）、提交点释放 ⇒ load 的槽位不再依赖发射/执行顺序，
//     队列级 `INORD_LOAD` 门不再承担"槽位序防死锁"职责（可安全置 0）。
//   ★ 2B-5 L5：LQ 32→16（索引 5→4）⇒ 顶端字段收窄 1 bit：**MSB 415→414、LSB 恒 411**，
//     拼接式仍右对齐+高位零扩展 ⇒ 其下所有字段（STQ/TRTGT/FFLAGS/CSRW/TVAL/uop…）绝对
//     位位置逐位不变；`[415]` 变为保留位，`BACK2_RB_W` 仍 416。
//     ⚠ 不可写成 LSB 411→410：那会让字段跨进 [410]（= STQ 最高位），`p_lq` 取值将含 STQ
//       位而丢掉 LQ 高位。
`define BACK2_RB_LQ_MSB      414
`define BACK2_RB_LQ_LSB      411        // [414:411] load queue 项索引（≤16 项）
// ---- 项内 epoch ----
//   ★ 不占载荷位域：由 rob.v 的窄控制字 `nq` 的 [2:1] 承载（原因见 rob.v §0：
//     放进 416 bit 载荷会让"时钟块内 7 端口读"展开成组合读森林，仿真慢 ~12×）。
//     （原独立的 `rep_q[]` 数组已无任何读写 ⇒ EXP-B 一并删除。）
//     ★ 2B-5 L5 后载荷 [415] 亦成为保留位（LQ 索引收窄为 [414:411]）。
`define BACK2_RB_W           416
//   ★★ 2B-5 第 3 步②（读 lane 数改造）：ROB **窄控制字** `nq` 的宽度与关键位
//     字段布局与 rob.v 的 `pack_nq` 逐位对应（两模块共用，不得各自硬编码）：
//       lq[3:0] stq[4:0] trtaken csrop[2:0] pdf[5:0] pdi[6:0] arn[4:0]
//       is_csr is_fp_wen is_int_wen ckpt_valid is_branch is_store exc[3:0] epoch[1:0] done
//       ── ② 新增： maint_kind[2:0] is_sret is_mret
//   ★ 2B-5 L5：`lq` 字段随 LQ 索引 5→4 bit 收窄 1 bit。`lq` 位于 `stq` **之上** ⇒ 其下
//     所有字段（stq/trtaken/csrop/pdf/pdi/arn/…/done）绝对位位置**逐位不变**；只有
//     `lq` 之上的 `pre`（maint_kind/sret/mret）与 NQ_W 各下移 1：MK 45→44、SRET 48→47、
//     MRET 49→48、**NQ_W 50→49**。（`lq` 自身 LSB 恒 40，字段区间 [43:40]。）
`define BACK2_NQ_W           49
`define BACK2_NQ_DONE        0
`define BACK2_NQ_EP_L        1
`define BACK2_NQ_EXC_L       3
`define BACK2_NQ_STORE       7
`define BACK2_NQ_BR          8
`define BACK2_NQ_CKV         9
`define BACK2_NQ_DI          10
`define BACK2_NQ_DF          11
`define BACK2_NQ_CSR         12
`define BACK2_NQ_ARN_L       13
`define BACK2_NQ_PDI_L       18
`define BACK2_NQ_PDF_L       25
`define BACK2_NQ_CSROP_L     31
`define BACK2_NQ_TRT         34
`define BACK2_NQ_STQ_L       35
`define BACK2_NQ_LQ_L        40        // lq 字段 LSB（2B-5 L5：区间 [43:40]，4 bit）
`define BACK2_NQ_MK_L        44        // [46:44] maint_kind[2:0]
`define BACK2_NQ_SRET        47
`define BACK2_NQ_MRET        48
//   ★ ② 专用单 lane 动态读口（CSR 提交合成）：{tval[31:0], csrw[31:0], csra[11:0], csrop[2:0]}
//     ★★ EXP-B：其中 `csrw` 段（rob 侧）改由**载荷 uop.PS1I** 直接给出（原为 updq.CSRW 的
//        低 7 位）；`tval` 段改由载荷 `BACK2_RB_TVAL`（= 原始指令位）给出 ⇒ 字段布局与宽度不变。
`define BACK2_CMT_CSR_W      79
//   ★★ EXP-B（架构 v0.1 §16–§21）：可更新字段由**一张 102 bit 多写源表 `updq`** 拆成
//     **三张"每表单写源" typed 表**，并删除恒 0 死口 `upd_csr`：
//       · 载荷 [405:304] 的原 102 bit ⇒ br{TRTAKEN,TRTGT} / ff{FFLAGS} / ex{TVAL} 三表；
//         `CSRW` 段（= {25'b0, PS1I}）**不再进更新表**（CSR 源改从载荷 uop.PS1I 取）；
//       · 每表恰好一个写源（BRU / FPU / LSU）⇒ 无共享写口、无仲裁、无多写源写 mux；
//       · 每表自带 {valid, epoch}：提交/陷阱时 `valid && epoch == 项内 epoch` 才采用
//         （epoch 复用项内 2 bit 口径）⇒ flush/squash 无需清 64 项，旧项天然作废。
//     动态依据：`upd_tr/ff/exc` 同拍并发 ≥2 仅 0.02%（3 拍）、`upd_csr_valid` 恒 0
//     （docs/design/10-dynamic-behavior.md §1.3、docs/design/09-...-review.md §1.5）。
`define BACK2_BR_TGT_W      32         // br 表数据：分支实际目标
`define BACK2_BR_TAKEN_W    1          // br 表数据：分支实际方向
`define BACK2_FF_W          5          // ff 表数据：FP flags[4:0]
`define BACK2_EX_TVAL_W     32         // ex 表数据：异常 TVAL（cause 已在 nq.exc，不重复存）
`define BACK2_TBL_EP_W      `BACK2_EPOCH_W   // 三表 {valid, epoch} 的 epoch 宽度（= 项内 epoch）

// ---- 标志位在 uop 内的绝对 bit 位置（= FLAGS_LSB + fl 序号）----
`define BACK2_UB_RD_I_WEN    (`BACK2_U_FLAGS_LSB + `BACK2_FL_RD_I_WEN)
`define BACK2_UB_RD_F_WEN    (`BACK2_U_FLAGS_LSB + `BACK2_FL_RD_F_WEN)
`define BACK2_UB_S1_I_USE    (`BACK2_U_FLAGS_LSB + `BACK2_FL_S1_I_USE)
`define BACK2_UB_S2_I_USE    (`BACK2_U_FLAGS_LSB + `BACK2_FL_S2_I_USE)
`define BACK2_UB_S1_F_USE    (`BACK2_U_FLAGS_LSB + `BACK2_FL_S1_F_USE)
`define BACK2_UB_S2_F_USE    (`BACK2_U_FLAGS_LSB + `BACK2_FL_S2_F_USE)
`define BACK2_UB_S3_F_USE    (`BACK2_U_FLAGS_LSB + `BACK2_FL_S3_F_USE)
`define BACK2_UB_IS_LOAD     (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_LOAD)
`define BACK2_UB_IS_STORE    (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_STORE)
`define BACK2_UB_IS_BRANCH   (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_BRANCH)
`define BACK2_UB_IS_CSR      (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_CSR)
`define BACK2_UB_IS_FP       (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_FP)
`define BACK2_UB_IS_ILLEGAL  (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_ILLEGAL)
`define BACK2_UB_CKPT_VALID  (`BACK2_U_FLAGS_LSB + `BACK2_FL_CKPT_VALID)
`define BACK2_UB_IS_UNSUP    (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_UNSUP)
`define BACK2_UB_IS_FPLS     (`BACK2_U_FLAGS_LSB + `BACK2_FL_IS_FPLS)

// ---- 队列归属（6 个分布式发射队列；§4.1 部件分工）----
`define BACK2_Q_ALU0   3'd0
`define BACK2_Q_ALU1   3'd1
`define BACK2_Q_BRU    3'd2
`define BACK2_Q_MDU    3'd3
`define BACK2_Q_LSU    3'd4
`define BACK2_Q_FPU    3'd5
`define BACK2_Q_NONE   3'd7

// ---- 异常码（与 rv32_defs.vh 的 cause 口径一致，只列本里程碑用到的）----
`define BACK2_EXC_NONE     4'd0
`define BACK2_EXC_ILLEGAL  4'd2          // 非法指令
`define BACK2_EXC_LOAD_MIS 4'd4          // load 非对齐（保留，本里程碑不产生）
`define BACK2_EXC_ST_MIS   4'd6          // store 非对齐（保留）
//   ★ 2B-4 第 4a 段：特权/断点异常码（与 rv32_defs.vh 的 cause 口径一致）
`define BACK2_EXC_BREAK    4'd3          // ebreak（断点）
`define BACK2_EXC_ECALL_U  4'd8          // U 模式 ecall
`define BACK2_EXC_ECALL_S  4'd9          // S 模式 ecall
`define BACK2_EXC_ECALL_M  4'd11         // M 模式 ecall

`endif // BACK2_PARAMS_VH
