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

// ---- LSQ（2B-3：SQ 32 + LQ 8；本文件是容量/位宽唯一真源）----
//   ★ 2B-3 第 6 段第一步：SQ 16→32（索引宽度 4→5），LQ 4→32（在途表 → 32 项 LQ）。
//     `BACK2_STQ_IDX_W` 只被 lsq_simple.v 与 backend_top.v 的 6 处位宽引用使用；
//     LQ 深度改变只牵动 lsq_simple.v 内部与内存标签宽度（见 `BACK2_MEM_TAG_W`）。
//   ★ 2B-5 L5（面积杠杆）：**LQ 32→16**（索引 5→4）——纯容量缩减，只降低"在飞 load
//     数上限"，不改任何指令语义（槽位仍在 D3 派发期分配、提交点释放；转发/请求/响应
//     逐拍逻辑全部按 `OUT_N`/`LQ_IW` 参数化，无字面宽度）。SQ 保持 32 不动。
//   ★★ EXP-R3（LQ 16→8，索引 4→3）——同上口径的第二次纯容量缩减。依据：EXP-R 容量数据
//     （docs/design/11-dynamic-behavior-r.md §1.3）实测 **LQ 高水位仅 6**（16 深有余量；
//     而 SQ 高水位 20 ⇒ SQ 不可砍，LQ 是更安全的一侧）。逐拍逻辑全部参数化 ⇒ 无字面宽度。
`define BACK2_STQ_N          32
`define BACK2_STQ_IDX_W      5
`define BACK2_LQ_N           8
`define BACK2_LQ_IDX_W       3
//   标签宽度 = log2(LQ_N) + 1：槽标签用 0..LQ_N-1（最高位恒 0），**store 提交排空的
//   标签取全 1** ⇒ 恰好多留 1 bit 才不会与末号槽撞车（LQ_N=4 时 3 bit 的旧口径只是
//   因为 2 bit 槽号 + 1 bit 分隔位；LQ_N=8 ⇒ 3 bit 槽号 + 1 bit 分隔位 = 4 bit；
//   LQ_N=16 时为 5 bit、LQ_N=32 时曾为 6 bit）。
`define BACK2_MEM_TAG_W      4
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
// 发射宽载荷布局（★★ C9：`uop[279:0]` 切片 → **215 bit 紧凑布局**）。
//------------------------------------------------------------------------------
// 背景（C9 面积杠杆）：C1 把发射宽载荷定为「uop 的低 280 位」切片（截掉架构源号
//   [303:280]），但该切片里仍有大量**发射/执行路径 0 读**的位（它们只在 D1/D2/D3 或
//   提交/训练路径用，且 D3 之前早已消费完）：
//     · **TVAL(32)**：uop[233:202]。E1 全仓库 0 读（异常 tval 走 ROB 载荷 / nq）；
//     · **ARND(5) / PDIOLD(7) / PDFOLD(6)**：只被 D2 重命名/提交释放读，E1 0 读；
//     · **IMM 之外的全套 E1-无关控制**：OPTYPE/ALUOP 之外……
//     · **BTB(2)**：E1 0 读（训练读的是 ROB 载荷的同名字段）；
//     · **Q(3)**：D3 派发队列归属，D3 当拍已消费；
//     · **PRED[2:0]**：E1 只读 `pred_taken`（1 bit）；
//     · **MEMOP(4)**：无任何访问函数（全仓库 0 读）；
//     · **EXC(4)**：E1 0 读（异常走 nq / ROB 载荷）；
//     · **CSROP(3)**：E1 0 读（提交级 CSR 操作码走 ROB 载荷 `csr_pay`）；
//     · **CSRW/FLAGS 里的 S*_USE/IS_LOAD/IS_ILLEGAL/IS_UNSUP**：仅唤醒/派发/提交用。
//   本段把发射宽载荷重排为「E1 执行 + E1 PRF 读口 + E1 冲刷/检查点恢复」真正读的位并集。
//------------------------------------------------------------------------------
// ★ 为什么 [19:0] 整块照抄 uop（不是偷懒，是硬约束）：
//   `sim/unit/dyn_probe_back2_body.inc`（动态行为探针，docs/design/10-dynamic-behavior.md
//   的真源）按**绝对位**层次引用 `x_i2_uop[*][BACK2_UB_S1_I_USE]`(=6)、`[S2_I_USE]`(=7)、
//   `[S1_F_USE]`(=8)、`[S2_F_USE]`(=9)、`[S3_F_USE]`(=10)、`[IS_CSR]`(=14)。该文件**不在
//   本任务的允许改动范围**（只许动 back2_params/rob/backend_top）⇒ [19:4] 的 FLAGS 块必须
//   逐位保留（因而 [3:0] 也需占位 4 bit，否则整块下移）。代价 = 6 bit 死位（EXC 4 + 块内
//   2 个 0 读标志），有意保留；要再省必须**同步**改该探针文件（后续任务）。
//------------------------------------------------------------------------------
// 新布局（LSB→MSB，**无空洞**）：
//   [3:0]     EXC            占位（E1 0 读；只为 FLAGS 块对齐，见上硬约束）
//   [19:4]    FLAGS          整块照抄 uop [19:4]（`BACK2_UB_*` 位序不变）
//   [23:20]   CKPT           检查点 id（冲刷恢复 `u_ckid`）
//   [26:24]   CLS            分支类别（BRU 误判判定 `u_cls`）
//   [38:27]   CSRADDR        CSR 地址（E1 CSR 读口 `csr_raddr_w`）
//   [44:39]   FPOP           浮点归一化操作码（`fpu.fp_op`）
//   [47:45]   RM             浮点舍入模式（`fpu.rm`）
//   [50:48]   MSIZE          访存宽度（`lsq.exe_size`）
//   [51]      MUNSIGN        load 零扩展（`lsq.exe_unsign`）
//   [54:52]   WBSEL          写回来源（BRU `WB_PC4` 判定）
//   [58:55]   ALUOP          ALU 微操作（`alu.alu_op`）
//   [62:59]   OPTYPE         执行部件类型（JAL/JALR 判定）
//   [67:63]   BROP           控制转移选择（`bru.br_op` / MDU 低 3 位）
//   [69:68]   FMT            浮点 fmt（`fpu.fmt`）
//   [70]      IL32           指令 32 bit（链接值）
//   [71]      RTYPE          R 型（ALU b 取 rs2）
//   [72]      AUIPC          auipc（ALU a 取 pc）
//   [73]      PRED_TAKEN     预测方向（BRU 误判比对）
//   [80:74]   PDI            整数新映射（LSU 写口 / 在途登记）
//   [86:81]   PDF            浮点新映射（同上）
//   [93:87]   PS1I           源 1 整数物理号（E1 PRF 读口）
//   [100:94]  PS2I           源 2 整数物理号
//   [106:101] PS1F           源 1 浮点物理号
//   [112:107] PS2F           源 2 浮点物理号
//   [118:113] PS3F           源 3 浮点物理号（FMA）
//   [150:119] PC             指令 PC（ALU/BRU 链接值/维护重定向）
//   [182:151] IMM            立即数（ALU/BRU/LSU 地址）
//   [214:183] PREDTGT        预测目标（BRU 误判比对）
`define BACK2_IW_EXC_MSB     3
`define BACK2_IW_EXC_LSB     0          // 占位（见上硬约束）
`define BACK2_IW_FLAGS_MSB   19         // ★ 与 uop FLAGS 段同值
`define BACK2_IW_FLAGS_LSB   4
`define BACK2_IW_CKPT_MSB    23
`define BACK2_IW_CKPT_LSB    20
`define BACK2_IW_CLS_MSB     26
`define BACK2_IW_CLS_LSB     24
`define BACK2_IW_CSRADDR_MSB 38
`define BACK2_IW_CSRADDR_LSB 27
`define BACK2_IW_FPOP_MSB    44
`define BACK2_IW_FPOP_LSB    39
`define BACK2_IW_RM_MSB      47
`define BACK2_IW_RM_LSB      45
`define BACK2_IW_MSIZE_MSB   50
`define BACK2_IW_MSIZE_LSB   48
`define BACK2_IW_MUNSIGN     51
`define BACK2_IW_WBSEL_MSB   54
`define BACK2_IW_WBSEL_LSB   52
`define BACK2_IW_ALUOP_MSB   58
`define BACK2_IW_ALUOP_LSB   55
`define BACK2_IW_OPTYPE_MSB  62
`define BACK2_IW_OPTYPE_LSB  59
`define BACK2_IW_BROP_MSB    67
`define BACK2_IW_BROP_LSB    63
`define BACK2_IW_FMT_MSB     69
`define BACK2_IW_FMT_LSB     68
`define BACK2_IW_IL32        70
`define BACK2_IW_RTYPE       71
`define BACK2_IW_AUIPC       72
`define BACK2_IW_PRED_TAKEN  73
`define BACK2_IW_PDI_MSB     80
`define BACK2_IW_PDI_LSB     74
`define BACK2_IW_PDF_MSB     86
`define BACK2_IW_PDF_LSB     81
`define BACK2_IW_PS1I_MSB    93
`define BACK2_IW_PS1I_LSB    87
`define BACK2_IW_PS2I_MSB    100
`define BACK2_IW_PS2I_LSB    94
`define BACK2_IW_PS1F_MSB    106
`define BACK2_IW_PS1F_LSB    101
`define BACK2_IW_PS2F_MSB    112
`define BACK2_IW_PS2F_LSB    107
`define BACK2_IW_PS3F_MSB    118
`define BACK2_IW_PS3F_LSB    113
`define BACK2_IW_PC_MSB      150
`define BACK2_IW_PC_LSB      119
`define BACK2_IW_IMM_MSB     182
`define BACK2_IW_IMM_LSB     151
`define BACK2_IW_PREDTGT_MSB 214
`define BACK2_IW_PREDTGT_LSB 183
`define BACK2_IW_W           215        // ★ C9：280→215（XPM 位宽 ≤216 ⇒ 3 RAMB36/bank）

// ---- ROB 项载荷（★★ C4：416 bit → 229 bit，「存了但谁都不读」的位全部删除）----
//------------------------------------------------------------------------------
// 背景（C4 面积杠杆；只读审计 fpga/scratch/redundancy_audit.md §B-B2 + 本段逐字段复检）：
//   旧布局 = `{LQ(4), STQ(5), FFLAGS(5), TRTAKEN(1), TRTGT(32), TVAL(32), {25'b0,PS1I}(32),
//             uop(304)}` = 416 bit。其中：
//     · uop 的 **[303:280]**（架构源号 SRC1/2/3）唯一读点是 D2 重命名（读 D1 滑板，不读载荷）；
//     · uop 的 **TVAL(233:202)** 与 RB 的 TVAL **同一真值**（rob 只读 RB_TVAL）；
//     · uop 的 **IMM/ARND/PS2I/PS1F/PS2F/PS3F/OPTYPE/ALUOP/MEMOP/MSIZE/MUNSIGN/WBSEL/
//       FPOP/RM/BROP/AUX(RTYPE/AUIPC/FMT/IL32/Q)** = 纯发射/执行期字段，提交路径 0 读
//       （C1 之后它们在 `u_iwmem` 里另有一份，见下 §2.5；本载荷存的是**重复副本**）；
//     · `CSRW [335:304]` = `{25'b0, PS1I}`，自 EXP-B 起 `csr_pay` 直接取载荷 uop.PS1I
//       ⇒ 这 32 bit（其中 25 bit 恒 0）**结构上永不读**；
//     · uop 的 FLAGS 里只有 `IS_FP` 被读（断言用；其余 RD_*/S*_USE/IS_ILLEGAL/IS_UNSUP
//       只在 nq 重建时读，或根本 0 读）。
//   本段把载荷重排为「rob.v 自己 + 提交路径 + `pack_nq` 重建 nq 真正读的位」的并集。
//------------------------------------------------------------------------------
// ★ 为什么 [3:0] 与 [19:4] 保持**逐位不变**（不是偷懒，是硬约束）：
//   `sim/unit/tb_back2_lockstep.sv` 与 `sim/unit/dyn_probe_back2_body.inc` 都按**绝对位**
//   层次引用 ROB 载荷：`cmt_pay[BACK2_UB_IS_FP]`(=15)、`cmt_pay[BACK2_UB_IS_LOAD]`(=11)、
//   `cmt_pay[BACK2_U_EXC_MSB:LSB]`(=[3:0])、`pp[BACK2_UB_IS_BRANCH]`(=13)。这两个文件**不在
//   本任务的允许改动范围**（只许动 back2_params/rob/backend_top）⇒ 载荷的 [19:0] 必须
//   原样保留（EXC 4 bit + FLAGS 16 bit 整块），`BACK2_UB_*` 宏因而在载荷上继续成立。
//   ⚠ 代价 = 7 bit 死位（S2I/S2F/S3F_USE、IS_ILLEGAL、IS_UNSUP 等），有意保留；
//     若要再省，必须**同步**改上面两个 sim 文件（后续任务）。
//------------------------------------------------------------------------------
// 新布局（LSB→MSB，**无空洞**；每行 = [MSB:LSB] 字段（源））：
//   [3:0]     EXC            异常码（uop fl 之外；rob `slot_exc`/`pexc`/`pack_nq`）
//   [19:4]    FLAGS          整块照抄 uop [19:4]（`BACK2_UB_*` 位序不变；见上硬约束）
//   [23:20]   CKPT           检查点 id（提交释放 `p_ckid` + nq）
//   [26:24]   CLS            分支类别（提交训练 `p_cls`）
//   [29:27]   CSROP          CSR 操作（`csr_pay` + nq）
//   [41:30]   CSRADDR        CSR 地址（`csr_pay`）
//   [48:42]   PS1I           源 1 整数物理号（`csr_pay` 的 csrw 段）
//   [55:49]   PDIOLD         整数旧映射（提交释放 `p_pdio`）
//   [61:56]   PDFOLD         浮点旧映射（提交释放 `p_pdfo`）
//   [68:62]   PDIDST         整数新映射（**只为 `pack_nq` 重建 nq**）
//   [73:69]   ARND           目的架构号（**只为 `pack_nq`**）
//   [79:74]   PDFDST         浮点新映射（**只为 `pack_nq`**）
//   [84:80]   STQ            store queue 项索引（`p_stq` 排空 + nq）
//   [88]      保留           （EXP-R3：LQ 16→8 后本字段收窄 1 bit ⇒ 此位恒 0）
//   [87:85]   LQ             load queue 项索引（3 bit；见 §2.5 L5 口径）
//   [120:89]  TVAL           异常附加值 / 原始指令位（`trap_tval` 回落 + `csr_pay`）
//   [152:121] TRTGT          分支实际目标（**占位 0**，输出位置由 `merge_upd` 用 br 表填）
//   [153]     TRTAKEN        分支实际方向（**占位 0**，同上）
//   [158:154] FFLAGS         浮点 flags（**占位 0**，输出位置由 `merge_upd` 用 ff 表填）
//   [190:159] PREDTGT        预测目标（提交训练 `tcp_ptg`）
//   [222:191] PC             指令 PC（提交 PC 流 / 维护重定向 / 训练）
//   [226:223] PRED           {pred_taken,selg,gdir,ldir}（提交训练）
//   [228:227] BTB            {btb_hit,btb_way}（提交训练）
// ★ 为什么 TRTGT/TRTAKEN/FFLAGS 三个「占位」字段仍留在位域里：`merge_upd` 的**输出**就是
//   本向量（位置必须存在，否则 backend_top 的 `p_ff`/`p_trtgt` 无处可读）；把它们挪出载荷
//   需改 rob↔backend_top 的接口，并会使 `ROB-ASSERT-PAY0`（载荷占位恒 0 的前提）失去对象
//   ⇒ 本段选择保留（38 bit，见报告 §3 收益-风险权衡）。
`define BACK2_RB_EXC_MSB     3
`define BACK2_RB_EXC_LSB     0
`define BACK2_RB_FLAGS_MSB   19         // ★ 与 uop 的 FLAGS 段（BACK2_U_FLAGS_MSB）同值
`define BACK2_RB_FLAGS_LSB   4          //   逐位不变的理由见上「硬约束」
`define BACK2_RB_CKPT_MSB    23
`define BACK2_RB_CKPT_LSB    20
`define BACK2_RB_CLS_MSB     26
`define BACK2_RB_CLS_LSB     24
`define BACK2_RB_CSROP_MSB   29
`define BACK2_RB_CSROP_LSB   27
`define BACK2_RB_CSRADDR_MSB 41
`define BACK2_RB_CSRADDR_LSB 30
`define BACK2_RB_PS1I_MSB    48
`define BACK2_RB_PS1I_LSB    42
`define BACK2_RB_PDIOLD_MSB  55
`define BACK2_RB_PDIOLD_LSB  49
`define BACK2_RB_PDFOLD_MSB  61
`define BACK2_RB_PDFOLD_LSB  56
`define BACK2_RB_PDIDST_MSB  68
`define BACK2_RB_PDIDST_LSB  62
`define BACK2_RB_ARND_MSB    73
`define BACK2_RB_ARND_LSB    69
`define BACK2_RB_PDFDST_MSB  79
`define BACK2_RB_PDFDST_LSB  74
`define BACK2_RB_STQ_MSB     84
`define BACK2_RB_STQ_LSB     80         // store queue 项索引（≤16 项）
//   ★★ EXP-R3（LQ 16→8）：本字段收窄 1 bit —— **MSB 88→87、LSB 恒 85**，`[88]` 变为保留位
//     （恒 0）。`BACK2_RB_W` 仍 229：本字段之上的 TVAL/TRTGT/…/BTB 绝对位位置**逐位不变**
//     （与 2B-5 L5 的"顶端收窄留保留位"同一做法）。打包侧 `backend_top.v` 在 `[88]` 补 1 bit 0。
//     ⚠ 本字段当前**无功能读点**（`backend_top.v` 的 `p_lq` 已无调用者；见 D2 报告 §nq 死字段），
//       保留它只为不改动 RB 布局的其余部分；彻底删除属后续 C4 载荷裁剪候选，不在本任务范围。
`define BACK2_RB_LQ_MSB      87         // ★ EXP-R3：88→87（LQ 16→8；[88] 保留）
`define BACK2_RB_LQ_LSB      85         // load queue 项索引（≤8 项，3 bit）
`define BACK2_RB_TVAL_MSB    120
`define BACK2_RB_TVAL_LSB    89         // 异常附加值 / 原始指令位
`define BACK2_RB_TRTGT_MSB   152
`define BACK2_RB_TRTGT_LSB   121        // 分支实际目标（占位 0；merge_upd 用 br 表填）
`define BACK2_RB_TRTAKEN     153        // 分支实际方向（占位 0）
`define BACK2_RB_FFLAGS_MSB  158
`define BACK2_RB_FFLAGS_LSB  154        // 浮点 flags（占位 0；merge_upd 用 ff 表填）
`define BACK2_RB_PREDTGT_MSB 190
`define BACK2_RB_PREDTGT_LSB 159
`define BACK2_RB_PC_MSB      222
`define BACK2_RB_PC_LSB      191
`define BACK2_RB_PRED_MSB    226
`define BACK2_RB_PRED_LSB    223
`define BACK2_RB_BTB_MSB     228
`define BACK2_RB_BTB_LSB     227
// ---- 项内 epoch ----
//   ★ 不占载荷位域：由 rob.v 的窄控制字 `nq` 的 [2:1] 承载（原因见 rob.v §0：
//     放进宽载荷会让"时钟块内 7 端口读"展开成组合读森林，仿真慢 ~12×）。
//     （原独立的 `rep_q[]` 数组已无任何读写 ⇒ EXP-B 一并删除。）
`define BACK2_RB_W           229        // ★ C4：416→229（XPM 位宽 229 ⇒ 3 RAMB36/bank）
//   ★★ EXP-R3（LQ 16→8）：LQ 字段收窄 1 bit 但 `[88]` 转为保留位 ⇒ **RB_W 仍 229**
//     （与 2B-5 L5 收窄顶端字段时 RB_W 恒 416 同理：宁可留 1 bit 保留位，也不动其余字段的
//      绝对位位置）。
//   ★★ 2B-5 第 3 步②（读 lane 数改造）：ROB **窄控制字** `nq` 的宽度与关键位
//     字段布局与 rob.v 的 `pack_nq` 逐位对应（两模块共用，不得各自硬编码）。
//     MSB→LSB： pre{mret, sret, maint_kind[2:0]} | trtaken | pdf[5:0] | pdi[6:0] | arn[4:0] |
//              is_csr | is_fp_wen | is_int_wen | ckpt_valid | is_branch | is_store |
//              exc[3:0] | epoch[1:0] | done
//   ★★ D2（nq 死字段裁剪，2B-5）：删除 `lq[3:0]` / `stq[4:0]` / `csrop[2:0]` 共 12 bit ——
//     三者在 `nq` 里**只被 `pack_nq` 写、全仓库无任何功能读点**（原自检的区间比较只做
//     "nq vs 重新 pack 的 nq" 恒等比对，不构成语义读点）。载荷侧三者各有归属、**未动**：
//     `stq` 仍供提交侧 `p_stq()→lsu_dr_idx`、`csrop` 仍供 `csr_pay`（rob.v §4）、
//     `lq` 在载荷侧亦无功能读点（登记为后续 C4 载荷裁剪候选，见 D2 报告）。
//     裁剪后 `nq` 49→37 bit：`trtaken` 34→31，其上的 `pre` 整段下移 12（MK 44→32、
//     SRET 47→35、MRET 48→36）；`pdf` 及其以下所有字段绝对位位置**逐位不变**。
`define BACK2_NQ_W           37
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
`define BACK2_NQ_TRT         31
`define BACK2_NQ_MK_L        32        // [34:32] maint_kind[2:0]
`define BACK2_NQ_SRET        35
`define BACK2_NQ_MRET        36
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
