//==============================================================================
// rtl/back2/back2_params.vh —— 2B-2 乱序后端：参数 + 微操作(uop)位域唯一真源
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2：ROB 128 + 物理寄存器重命名 + 分布式发射队列）
// 规格  : docs/design/03-out-of-order.md §2（ROB 128 项 / 顺序提交 ≤4）、§3（物理寄存器
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
// ---- ROB（§2.1：深度 128 = 32 × 4，与 4 发射 × 32 条窗口对齐）----
`define BACK2_ROB_N          128
`define BACK2_ROB_IDX_W      7          // log2(128)

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
`define BACK2_RATLOG_N       128        // = ROB_N（每 ROB 项至多 1 个目的寄存器）
`define BACK2_RATLOG_PTR_W   8          // 模 256 指针 ⇒ 距离无歧义（距离 ≤ 128）
`define BACK2_RATLOG_G       4          // 每拍一组 4 条

// ---- free list 指针（模 256 环形；容量 64/32 ≪ 256）----
`define BACK2_FL_PTR_W       8

// ---- epoch（§8.2：2 bit，冲刷递增；RIQ/SQ 出队时比较）----
`define BACK2_EPOCH_W        2

// ---- 分布式发射队列深度（§4.2：ALU0/1=16、BRU=8、MDU=8、LSU=12、FPU=8）----
`define BACK2_IQ_ALU0_D      16
`define BACK2_IQ_ALU1_D      16
`define BACK2_IQ_BRU_D       8
`define BACK2_IQ_MDU_D       8
`define BACK2_IQ_LSU_D       12
`define BACK2_IQ_FPU_D       8
`define BACK2_IQ_MAX_D       16         // 通用 iq.v 的实例化上界（参数）
`define BACK2_IQ_WR_PORTS    4          // 每队列写口 ≤4/拍（02 §4.2）

// ---- 唤醒/写回总线端口数（6 个执行部件各 1 个写回口）----
`define BACK2_WB_N           6

// ---- LSQ（2B-3：SQ 32 + LQ 32；本文件是容量/位宽唯一真源）----
//   ★ 2B-3 第 6 段第一步：SQ 16→32（索引宽度 4→5），LQ 4→32（在途表 → 32 项 LQ）。
//     `BACK2_STQ_IDX_W` 只被 lsq_simple.v 与 backend_top.v 的 6 处位宽引用使用；
//     LQ 深度改变只牵动 lsq_simple.v 内部与内存标签宽度（见 `BACK2_MEM_TAG_W`）。
`define BACK2_STQ_N          32
`define BACK2_STQ_IDX_W      5
`define BACK2_LQ_N           32
`define BACK2_LQ_IDX_W       5
//   标签宽度 = log2(LQ_N) + 1：槽标签用 0..LQ_N-1（最高位恒 0），**store 提交排空的
//   标签取全 1** ⇒ 恰好多留 1 bit 才不会与 31 号槽撞车（LQ_N=4 时 3 bit 的旧口径
//   只是因为 2 bit 槽号 + 1 bit 分隔位；LQ 扩到 32 后必须同步 +1）。
`define BACK2_MEM_TAG_W      6
`define BACK2_MEM_OUT_N      `BACK2_LQ_N     // 在途访存槽（MSHR 口径）= LQ 深度

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
// ---- 项内 epoch ----
//   ★ 不占载荷位域：由 rob.v 的独立 2 bit 小数组 `rep_q[]` 承载（原因见 rob.v §0：
//     放进 416 bit 载荷会让"时钟块内 7 端口读"展开成组合读森林，仿真慢 ~12×）。
//     载荷空位 [415:411] 保留 0（5 bit；LQ 若也需上位域可直接用这段空闲位）。
`define BACK2_RB_W           416

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

`endif // BACK2_PARAMS_VH
