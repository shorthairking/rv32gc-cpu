//=============================================================================
// rv32gc_defs.vh —— RV32GC 处理器全局宏、编码与位域定义（唯一真源 / single source of truth）
//
// 本文件与以下规格书一一对应，修改时必须同步：
//   docs/design/spec/00-conventions.md   （全局约定、参数、握手/清空协议）
//   docs/design/spec/02-uop-and-decode.md（uop_ctrl_t 位域与各字段编码）
//   docs/design/spec/03-pipeline-regs.md （表项格式、接口 bundle）
//
// 编码风格：Verilog-2001 可综合子集；仅供 `include，不产生任何硬件。
//=============================================================================
`ifndef RV32GC_DEFS_VH
`define RV32GC_DEFS_VH

//-----------------------------------------------------------------------------
// 1. 全局参数（可用 +define+ 覆盖）
//-----------------------------------------------------------------------------
`ifndef CORE_WIDTH
  `define CORE_WIDTH        4          // 取指/译码/重命名/发射/提交宽度（降级配置为 2）
`endif
`ifndef ROB_DEPTH
  `define ROB_DEPTH         128        // ROB 项数（2 的幂）
`endif
`ifndef IQ_INT_DEPTH
  `define IQ_INT_DEPTH      32
`endif
`ifndef IQ_MEM_DEPTH
  `define IQ_MEM_DEPTH      24
`endif
`ifndef IQ_FP_DEPTH
  `define IQ_FP_DEPTH       16
`endif
`ifndef LSQ_LD_DEPTH
  `define LSQ_LD_DEPTH      32
`endif
`ifndef LSQ_ST_DEPTH
  `define LSQ_ST_DEPTH      32
`endif
`ifndef PRF_INT_DEPTH
  `define PRF_INT_DEPTH     128
`endif
`ifndef PRF_FP_DEPTH
  `define PRF_FP_DEPTH      128
`endif
`ifndef WB_PORTS
  `define WB_PORTS          6          // 0=ALU0/BRU 1=ALU1 2=MDU 3=LSU 4=FPU 5=CSR/SYS
`endif
`ifndef CKPT_NUM
  `define CKPT_NUM          4          // 分支 checkpoint 数
`endif
`ifndef RESET_PC
  `define RESET_PC          32'h0000_0000
`endif

`define PREG_IDX_W          7            // 物理寄存器索引位宽（log2(128)）
`define ROB_IDX_W           7            // ROB 索引位宽（log2(128)）
`define LSQ_IDX_W           5            // LSQ 索引位宽（log2(32)）
`define IQ_IDX_W            5            // 发射队列索引位宽（按最大队列 32）
`define XLEN                32
`define VLEN                32
`define FLEN                64
`define PADDR_W             32
`define VADDR_W             32
`define ASID_W              9
`define CACHE_LINE_BYTES    32           // 所有 Cache 行大小（字节）
`define CACHE_LINE_BITS     256
`define CBO_BLOCK_BYTES     32           // Zicbom block size
`define PMP_ENTRIES         16
`define GHR_W               12

// AXI（平台契约：默认 32 位数据；`AXI64/`AXI128 时加宽）
`ifdef AXI128
  `define AXI_DATA_W        128
  `define AXI_STRB_W        16
`else
  `ifdef AXI64
    `define AXI_DATA_W      64
    `define AXI_STRB_W      8
  `else
    `define AXI_DATA_W      32
    `define AXI_STRB_W      4
  `endif
`endif
`define AXI_ADDR_W          32
`define AXI_ID_W            4
`define AXI_LEN_W           4            // 平台实际为 4 位：突发 <= 16 beat
`define AXI_BEATS_PER_LINE  (`CACHE_LINE_BYTES*8/`AXI_DATA_W)

// 各 Cache 参数
`define L1I_SETS            128          // 16 KB / 4 way / 32 B
`define L1I_WAYS            4
`define L1D_SETS            128          // 32 KB / 8 way / 32 B
`define L1D_WAYS            8
`define L2_SETS             1024         // 256 KB / 8 way / 32 B
`define L2_WAYS             8
`define ICACHE_MSHR         2
`define DCACHE_MSHR         8
`define STORE_BUF_DEPTH     16
`define VICTIM_BUF_DEPTH    4

// 分支预测器
`define BTB_ENTRIES         512
`define BTB_WAYS            4
`define GPHT_ENTRIES        4096
`define LPHT_ENTRIES        4096
`define LHT_ENTRIES         1024
`define CPHT_ENTRIES        4096
`define RAS_DEPTH           32
`define FETCH_QUEUE_DEPTH   16
`define STLD_PRED_ENTRIES   1024

//-----------------------------------------------------------------------------
// 2. 地址映射（物理地址；与 docs/kb/01-chiplab-platform.md 一致）
//-----------------------------------------------------------------------------
`define DDR_BASE            32'h0000_0000
`define DDR_SIZE            32'h0800_0000   // 128 MiB
`define SRAM_BASE           32'h1C00_0000
`define SRAM_SIZE           32'h0010_0000   // 1 MiB

// ---- SPI Flash XIP 启动窗口（决策 D16；与 SRAM 窗口同址）----
// 平台把 paddr[31:20]==12'h1C0 接到 SPI 控制器（chiplab `IP/AMBA/axi_mux_syn.v:946`），
// **没有硬件 boot ROM**，复位后的第一条指令就从这个窗口 XIP 执行；另有 0x1FE8_0000 别名窗口。
`define SPI_XIP_BASE        32'h1C00_0000   // 复位取指窗口（= SRAM_BASE，1 MiB，只读 XIP）
`define SPI_XIP_MASK        32'hFFF0_0000   // 1 MiB 窗口判定掩码
`define SPI_XIP_ALIAS_BASE  32'h1FE8_0000   // 同一 SPI 控制器的别名窗口（= SPI_BASE）
`define SPI_XIP_ALIAS_MASK  32'hFFFF_0000   // 64 KiB 窗口判定掩码
// D16② 判定：地址是否落在 SPI-XIP 窗口 —— 取指命中时必须**绕过 I-Cache**
`define IS_SPI_XIP(a)   ((((a) & `SPI_XIP_MASK) == `SPI_XIP_BASE) || \
                         (((a) & `SPI_XIP_ALIAS_MASK) == `SPI_XIP_ALIAS_BASE))
`define CLINT_BASE          32'h1F00_0000   // 核内截获
`define PLIC_BASE           32'h1F10_0000   // 核内截获；实际截获范围 0x1F10_0000–0x1F3F_FFFF
                                        // （SiFive PLIC 1.0.0 的 threshold/claim 在偏移
                                        //  0x20_0000/0x20_1000，1 MiB 窗口覆盖不到）
`define CONFREG_FPGA_BASE   32'h1FD0_0000   // confreg_syn.v
`define CONFREG_SIM_BASE    32'h1FAF_0000   // confreg_sim.v
`define UART_BASE           32'h1FE0_0000   // 寄存器 0x1FE0_01E0
`define UART_REG_BASE       32'h1FE0_01E0
`define NAND_BASE           32'h1FE7_8000
`define NAND_DATA_PORT      32'h1FE7_8040
`define SPI_BASE            32'h1FE8_0000
`define MAC_BASE            32'h1FF0_0000
`define DMA_ORDER_REG       32'h1FD0_1160   // 平台 DMA 门铃（confreg FPGA 窗口内 +0x1160）

// CONFREG 偏移（FPGA / 仿真两套，软件必须区分）
`define CONF_FPGA_LED       16'hF000
`define CONF_FPGA_NUM       16'hF010
`define CONF_FPGA_SWITCH    16'hF020
`define CONF_FPGA_TIMER     16'hE000
`define CONF_SIM_LED        16'hF020
`define CONF_SIM_NUM        16'hF050
`define CONF_SIM_TIMER      16'hE000
`define CONF_SIM_IO_SIMU    16'hFF00
`define CONF_SIM_VUART      16'hFF10
`define CONF_SIM_SIMU_FLAG  16'hFF20

//-----------------------------------------------------------------------------
// 3. op_class
//-----------------------------------------------------------------------------
`define OP_ALU   3'd0
`define OP_BRU   3'd1
`define OP_MDU   3'd2
`define OP_LSU   3'd3
`define OP_FPU   3'd4
`define OP_CSR   3'd5
`define OP_SYS   3'd6
`define OP_NOP   3'd7

//-----------------------------------------------------------------------------
// 4. alu_op / alu_a_sel / alu_b_sel
//-----------------------------------------------------------------------------
`define ALU_ADD   5'd0
`define ALU_SUB   5'd1
`define ALU_SLL   5'd2
`define ALU_SLT   5'd3
`define ALU_SLTU  5'd4
`define ALU_XOR   5'd5
`define ALU_SRL   5'd6
`define ALU_SRA   5'd7
`define ALU_OR    5'd8
`define ALU_AND   5'd9
// Zicond：条件置零（rd = (rs2 条件) ? 0 : rs1）
`define ALU_CZERO_EQZ 5'd10
`define ALU_CZERO_NEZ 5'd11

`define ALU_A_RS1  2'd0
`define ALU_A_PC   2'd1
`define ALU_A_ZERO 2'd2

`define ALU_B_RS2   3'd0
`define ALU_B_IMM   3'd1
`define ALU_B_CONST4 3'd2
`define ALU_B_ZERO  3'd3
`define ALU_B_SHAMT 3'd4

//-----------------------------------------------------------------------------
// 5. BRU
//-----------------------------------------------------------------------------
`define BR_NONE  3'd0
`define BR_EQ    3'd1
`define BR_NE    3'd2
`define BR_LT    3'd3
`define BR_GE    3'd4
`define BR_LTU   3'd5
`define BR_GEU   3'd6
// br_flags = {is_ret, is_call, is_jalr, is_jal}
`define BRF_RET   3
`define BRF_CALL  2
`define BRF_JALR  1
`define BRF_JAL   0

//-----------------------------------------------------------------------------
// 6. MDU
//-----------------------------------------------------------------------------
`define MDU_MUL     3'd0
`define MDU_MULH    3'd1
`define MDU_MULHSU  3'd2
`define MDU_MULHU   3'd3
`define MDU_DIV     3'd4
`define MDU_DIVU    3'd5
`define MDU_REM     3'd6
`define MDU_REMU    3'd7

//-----------------------------------------------------------------------------
// 7. LSU
//-----------------------------------------------------------------------------
`define MEM_NONE   3'd0
`define MEM_LOAD   3'd1
`define MEM_STORE  3'd2
`define MEM_LR     3'd3
`define MEM_SC     3'd4
`define MEM_AMO    3'd5

`define MSZ_BYTE   2'd0
`define MSZ_HALF   2'd1
`define MSZ_WORD   2'd2
// mem_flags = {mem_fp, mem_unsigned}
`define MF_FP        1
`define MF_UNSIGNED  0
// amo_flags = {amo_rl, amo_aq}
`define AMOF_RL   1
`define AMOF_AQ   0
// amo_op（funct5）
`define AMO_ADD    5'h00
`define AMO_SWAP   5'h01
`define AMO_XOR    5'h04
`define AMO_OR     5'h08
`define AMO_AND    5'h0C
`define AMO_MIN    5'h10
`define AMO_MAX    5'h14
`define AMO_MINU   5'h18
`define AMO_MAXU   5'h1C

//-----------------------------------------------------------------------------
// 8. FPU（fp_op）
//-----------------------------------------------------------------------------
`define FP_FADD      6'd0
`define FP_FSUB      6'd1
`define FP_FMUL      6'd2
`define FP_FDIV      6'd3
`define FP_FSQRT     6'd4
`define FP_FSGNJ     6'd5
`define FP_FSGNJN    6'd6
`define FP_FSGNJX    6'd7
`define FP_FMIN      6'd8
`define FP_FMAX      6'd9
`define FP_FCVT_SD   6'd10
`define FP_FCVT_TO_I 6'd11
`define FP_FCVT_FROM_I 6'd12
`define FP_FMV_X_W   6'd13
`define FP_FMV_W_X   6'd14
`define FP_FEQ       6'd15
`define FP_FLT       6'd16
`define FP_FLE       6'd17
`define FP_FCLASS    6'd18
`define FP_FMADD     6'd19
`define FP_FMSUB     6'd20
`define FP_FNMSUB    6'd21
`define FP_FNMADD    6'd22

`define FMT_S 2'd0
`define FMT_D 2'd1
// 舍入模式
`define RM_RNE 3'd0
`define RM_RTZ 3'd1
`define RM_RDN 3'd2
`define RM_RUP 3'd3
`define RM_RMM 3'd4
`define RM_DYN 3'd7

//-----------------------------------------------------------------------------
// 9. CSR / SYS / CBO
//-----------------------------------------------------------------------------
`define CSR_NONE 2'd0
`define CSR_RW   2'd1
`define CSR_RS   2'd2
`define CSR_RC   2'd3

`define SYS_ECALL      3'd0
`define SYS_EBREAK     3'd1
`define SYS_MRET       3'd2
`define SYS_SRET       3'd3
`define SYS_WFI        3'd4
`define SYS_FENCE      3'd5
`define SYS_FENCE_I    3'd6
`define SYS_SFENCE_VMA 3'd7

`define CBO_INVAL 2'd0
`define CBO_CLEAN 2'd1
`define CBO_FLUSH 2'd2
`define CBO_ZERO  2'd3

// 写回来源
`define WB_ALU 3'd0
`define WB_MEM 3'd1
`define WB_PC4 3'd2
`define WB_CSR 3'd3
`define WB_FP  3'd4
`define WB_ZERO 3'd5

// 写回口编号
`define WBP_ALU0 0
`define WBP_ALU1 1
`define WBP_MDU  2
`define WBP_LSU  3
`define WBP_FPU  4
`define WBP_SYS  5

//-----------------------------------------------------------------------------
// 10. 异常/中断码（mcause/scause）
//-----------------------------------------------------------------------------
`define EXC_NONE              4'd0
`define EXC_INSTR_MISALIGN    4'd0
`define EXC_INSTR_ACCESS      4'd1
`define EXC_ILLEGAL_INSTR     4'd2
`define EXC_BREAKPOINT        4'd3
`define EXC_LOAD_MISALIGN     4'd4
`define EXC_LOAD_ACCESS       4'd5
`define EXC_STORE_MISALIGN    4'd6
`define EXC_STORE_ACCESS      4'd7
`define EXC_ECALL_U           4'd8
`define EXC_ECALL_S           4'd9
`define EXC_ECALL_M           4'd11
`define EXC_INSTR_PAGE_FAULT  4'd12
`define EXC_LOAD_PAGE_FAULT   4'd13
`define EXC_STORE_PAGE_FAULT  4'd15
// 译码期内部分类（与上面的规范编码对齐；用于 excp_cause 字段）
`define DEXC_NONE             4'd0
`define DEXC_ILLEGAL          4'd2
`define DEXC_ECALL_U          4'd8
`define DEXC_ECALL_S          4'd9
`define DEXC_ECALL_M          4'd11
`define DEXC_BREAK            4'd3
`define DEXC_INSTR_MISALIGN   4'd0
// 中断码（mcause[31]=1）
`define IRQ_S_SOFT   4'd1
`define IRQ_M_SOFT   4'd3
`define IRQ_S_TIMER  4'd5
`define IRQ_M_TIMER  4'd7
`define IRQ_S_EXT    4'd9
`define IRQ_M_EXT    4'd11

// 特权级
`define PRV_U 2'b00
`define PRV_S 2'b01
`define PRV_M 2'b11

//-----------------------------------------------------------------------------
// 11. CSR 地址
//-----------------------------------------------------------------------------
`define CSR_USTATUS   12'h000
`define CSR_FFLAGS    12'h001
`define CSR_FRM       12'h002
`define CSR_FCSR      12'h003
`define CSR_SSTATUS   12'h100
`define CSR_SIE       12'h104
`define CSR_STVEC     12'h105
`define CSR_SCOUNTEREN 12'h106
`define CSR_SENVCFG   12'h10A
`define CSR_SENVCFGH  12'h11A
`define CSR_SSCRATCH  12'h140
`define CSR_SEPC      12'h141
`define CSR_SCAUSE    12'h142
`define CSR_STVAL     12'h143
`define CSR_SIP       12'h144
`define CSR_SATP      12'h180
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MEDELEG   12'h302
`define CSR_MIDELEG   12'h303
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MCOUNTEREN 12'h306
`define CSR_MHPMEVENT3  12'h323
`define CSR_MHPMEVENT31 12'h33F
`define CSR_MENVCFG   12'h30A
`define CSR_MSTATUSH  12'h310
`define CSR_MENVCFGH  12'h31A
`define CSR_MCOUNTINHIBIT 12'h320
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_PMPCFG0   12'h3A0
`define CSR_PMPCFG1   12'h3A1
`define CSR_PMPCFG2   12'h3A2
`define CSR_PMPCFG3   12'h3A3
`define CSR_PMPADDR0  12'h3B0
`define CSR_PMPADDR1  12'h3B1
`define CSR_PMPADDR2  12'h3B2
`define CSR_PMPADDR3  12'h3B3
`define CSR_PMPADDR4  12'h3B4
`define CSR_PMPADDR5  12'h3B5
`define CSR_PMPADDR6  12'h3B6
`define CSR_PMPADDR7  12'h3B7
`define CSR_PMPADDR8  12'h3B8
`define CSR_PMPADDR9  12'h3B9
`define CSR_PMPADDR10 12'h3BA
`define CSR_PMPADDR11 12'h3BB
`define CSR_PMPADDR12 12'h3BC
`define CSR_PMPADDR13 12'h3BD
`define CSR_PMPADDR14 12'h3BE
`define CSR_PMPADDR15 12'h3BF
// PMP 窗口的"整段"判定（rv32_csr 与核内检查共用；RV32：cfg 4 个字 × 每字 4 项 = 16 项）
//   0x3A0-0x3A3 → pmpcfg0-3；0x3A4-0x3AF 不存在（访问须报非法指令）
//   0x3B0-0x3BF → pmpaddr0-15
// 用法：实参必须是**裸标识符**（Verilog 不允许对带括号的表达式做 part-select）
`define IS_PMPCFG_ADDR(a)  (a[11:2] == 10'h0E8)
`define IS_PMPADDR_ADDR(a) (a[11:4] == 8'h3B)
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MCYCLEH   12'hB80
`define CSR_MINSTRETH 12'hB82
`define CSR_CYCLE     12'hC00
`define CSR_TIME      12'hC01
`define CSR_INSTRET   12'hC02
`define CSR_CYCLEH    12'hC80
`define CSR_TIMEH     12'hC81
`define CSR_INSTRETH  12'hC82
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13
`define CSR_MHARTID   12'hF14
`define CSR_MCONFIGPTR 12'hF15

//-----------------------------------------------------------------------------
// 12. uop_ctrl_t 位域（72 位，见 docs/design/spec/02-uop-and-decode.md §2）
//     打包：ctrl = {is_serial, is_sfence, is_fencei, is_fence, excp_cause[3:0],
//                   excp_valid, use_rs2, use_rs1, rd_is_fp, rd_wen, wb_sel[2:0],
//                   cbo_op[1:0], csr_imm, sys_op[2:0], csr_op[1:0], fp_rm[2:0],
//                   fp_fmt[1:0], fp_op[5:0], amo_op[4:0], amo_flags[1:0],
//                   mem_flags[1:0], mem_size[1:0], mem_op[2:0], mdu_op[2:0],
//                   br_flags[3:0], br_type[2:0], alu_b_sel[2:0], alu_a_sel[1:0],
//                   alu_op[4:0], op_class[2:0], use_rs3, is_cbo}
//-----------------------------------------------------------------------------
`define UOP_CTRL_W   74   // [72]=use_rs3（FMA 第三源）, [73]=is_cbo（Zicbom 用途判别）
// 各字段在 ctrl 中的高位下标（低位 = 下标 - 宽度 + 1）
`define CTRL_OP_CLASS_H    2
`define CTRL_ALU_OP_H      7
`define CTRL_ALU_A_SEL_H   9
`define CTRL_ALU_B_SEL_H   12
`define CTRL_BR_TYPE_H     15
`define CTRL_BR_FLAGS_H    19
`define CTRL_MDU_OP_H      22
`define CTRL_MEM_OP_H      25
`define CTRL_MEM_SIZE_H    27
`define CTRL_MEM_FLAGS_H   29
`define CTRL_AMO_FLAGS_H   31
`define CTRL_AMO_OP_H      36
`define CTRL_FP_OP_H       42
`define CTRL_FP_FMT_H      44
`define CTRL_FP_RM_H       47
`define CTRL_CSR_OP_H      49
`define CTRL_SYS_OP_H      52
`define CTRL_CSR_IMM_H     53
`define CTRL_CBO_OP_H      55
`define CTRL_WB_SEL_H      58
`define CTRL_RD_WEN_H      59
`define CTRL_RD_IS_FP_H    60
`define CTRL_USE_RS1_H     61
`define CTRL_USE_RS2_H     62
`define CTRL_EXCP_VALID_H  63
`define CTRL_EXCP_CAUSE_H  67
`define CTRL_IS_FENCE_H    68
`define CTRL_IS_FENCEI_H   69
`define CTRL_IS_SFENCE_H   70
`define CTRL_IS_SERIAL_H   71
`define CTRL_USE_RS3_H     72
`define CTRL_IS_CBO_H      73

// 字段抽取宏：CTRL_GET(ctrl, FIELD)
`define CTRL_GET(ctrl, name)  (ctrl[`CTRL_``name``_H -: `CTRL_``name``_W])

`define CTRL_OP_CLASS_W    3
`define CTRL_ALU_OP_W      5
`define CTRL_ALU_A_SEL_W   2
`define CTRL_ALU_B_SEL_W   3
`define CTRL_BR_TYPE_W     3
`define CTRL_BR_FLAGS_W    4
`define CTRL_MDU_OP_W      3
`define CTRL_MEM_OP_W      3
`define CTRL_MEM_SIZE_W    2
`define CTRL_MEM_FLAGS_W   2
`define CTRL_AMO_FLAGS_W   2
`define CTRL_AMO_OP_W      5
`define CTRL_FP_OP_W       6
`define CTRL_FP_FMT_W      2
`define CTRL_FP_RM_W       3
`define CTRL_CSR_OP_W      2
`define CTRL_SYS_OP_W      3
`define CTRL_CSR_IMM_W     1
`define CTRL_CBO_OP_W      2
`define CTRL_WB_SEL_W      3
`define CTRL_RD_WEN_W      1
`define CTRL_RD_IS_FP_W    1
`define CTRL_USE_RS1_W     1
`define CTRL_USE_RS2_W     1
`define CTRL_EXCP_VALID_W  1
`define CTRL_EXCP_CAUSE_W  4
`define CTRL_IS_FENCE_W    1
`define CTRL_IS_FENCEI_W   1
`define CTRL_IS_SFENCE_W   1
`define CTRL_IS_SERIAL_W   1
`define CTRL_USE_RS3_W     1
`define CTRL_IS_CBO_W      1

//-----------------------------------------------------------------------------
// 13. 物理寄存器约定
//-----------------------------------------------------------------------------
`define PREG_ZERO  7'd0    // 恒 0，不分配/不回收/不唤醒

//-----------------------------------------------------------------------------
// 14. 环形年龄比较（ROB 128 项）
//     is_younger(a, b) == 1 表示 a 比 b 年轻（a 在 b 之后分配）
//     注意：ROB_DEPTH 固定 128（ROB_HALF_DEPTH=64）；若改深度必须同步改此常量与位宽
//-----------------------------------------------------------------------------
`define ROB_HALF_DEPTH    7'd64
`define ROB_DELTA(a, b)   (((a) - (b)) & {`ROB_IDX_W{1'b1}})
`define IS_YOUNGER(a, b)  ((`ROB_DELTA(a, b) != {`ROB_IDX_W{1'b0}}) && \
                           (`ROB_DELTA(a, b) < `ROB_HALF_DEPTH))

`endif // RV32GC_DEFS_VH
