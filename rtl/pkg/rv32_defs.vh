//==============================================================================
// rv32_defs.vh —— RV32-GC 项目「位域/编码」唯一真源（Unique Source of Truth）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 作用域  : 指令编码常量、CSR 地址全表、异常/中断 cause、mtvec MODE、PMP 常量、
//           AXI 常量、陷阱取值口径宏。
// 风格    : Verilog-2001 兼容；只允许 localparam / `define / `ifdef；
//           **本文件内不得出现任何 always 块与模块/端口声明**（组合逻辑风格红线，
//           AGENT.md §4.3；本文件本就不含行为逻辑）。
// 引用    : 每个段落头写明出处。出处分三类——
//           [ISA:path:line]     = riscv-isa-manual 源文件行号（可复核）
//           [ENC:binutils:pkg]  = 由 riscv-gnu-toolchain/binutils/include/opcode/
//                                 riscv-opc.h 的 MATCH_*/MASK_* 反推（可复核，见 §3 表）
//           [DOC:docs/...]      = 本项目设计文档（口径，非 ISA 真值）
// 版本纪律: 改动先改本文件，再全量同步所有使用处；改完用 grep 核对两侧（AGENT.md §3.2）。
//==============================================================================
`ifndef RV32_DEFS_VH
`define RV32_DEFS_VH

//==============================================================================
// 1. 地址/数据宽度（与平台侧真源 chiplab/chip/soc_demo/loongson/config.h:46-100 一致）
//    [DOC:docs/kb/platform-facts.md §1.3]
//==============================================================================
`define RV32GC_XLEN          32          // RV32：XLEN=32（主参数见 core_params.vh）
`define RV32GC_INSN_W        32          // 32 bit 指令
`define RV32GC_PARCEL_W      16          // 16 bit parcel（压缩指令最小单位）

//==============================================================================
// 2. 指令长度编码（操作数最低 2 位）
//    [ISA:riscv-isa-manual/src/unpriv/intro.adoc:439-460]
//    —— 32 bit 指令最低两位恒为 11；16 bit 压缩指令最低两位 != 11。
//==============================================================================
`define RV32GC_OPCODE_BITS   7           // opcode 段宽

//==============================================================================
// 3. 主操作码（opcode[6:0]）与 funct3/funct7/funct5 常量
//    每条均在注释中给出 [ENC:riscv-opc.h] 的 MATCH/MASK 反推依据。
//    opcode 常量统一命名 RV32GC_OP_*；字段常量按指令族命名。
//==============================================================================

// ---- 3.1 主操作码 [DOC:riscv-isa-manual/src/unpriv/rv-32-64g.adoc:13-23 opcode map] ----
`define RV32GC_OP_LOAD       7'b0000011   // LOAD      ：lb/lh/lw/lbu/lhu
`define RV32GC_OP_MISC_MEM   7'b0001111   // MISC-MEM  ：fence / fence.i / cbo.*
`define RV32GC_OP_IMM        7'b0010011   // OP-IMM    ：addi/slti/…/slli/srli/srai
`define RV32GC_OP_AUIPC      7'b0010111   // AUIPC
`define RV32GC_OP_STORE      7'b0100011   // STORE     ：sb/sh/sw
`define RV32GC_OP_AMO        7'b0101111   // AMO       ：lr.w/sc.w/amo*.w
`define RV32GC_OP_OP         7'b0110011   // OP        ：add/sub/…/(M 扩展 mul/div 族)
`define RV32GC_OP_LUI        7'b0110111   // LUI
`define RV32GC_OP_BRANCH     7'b1100011   // BRANCH    ：beq..bgeu
`define RV32GC_OP_JALR       7'b1100111   // JALR
`define RV32GC_OP_JAL        7'b1101111   // JAL
`define RV32GC_OP_SYSTEM     7'b1110011   // SYSTEM    ：CSR 指令 / ecall / ebreak / xRET / wfi
`define RV32GC_OP_LOAD_FP    7'b0000111   // LOAD-FP   ：flw/fld
`define RV32GC_OP_STORE_FP   7'b0100111   // STORE-FP  ：fsw/fsd
`define RV32GC_OP_MADD       7'b1000011   // MADD      ：fmadd.s/.d
`define RV32GC_OP_MSUB       7'b1000111   // MSUB      ：fmsub.s/.d
`define RV32GC_OP_NMSUB      7'b1001011   // NMSUB     ：fnmsub.s/.d
`define RV32GC_OP_NMADD      7'b1001111   // NMADD     ：fnmadd.s/.d
`define RV32GC_OP_FP         7'b1010011   // OP-FP     ：fadd/fsub/fmul/fdiv/fsqrt/fsgnj/
                                           //             fmin/fmax/fcvt/fmv/fcmp/fclass

// ---- 3.2 LOAD（opcode=0000011）：funct3 选择 [ENC:MATCH_LB=0x03 MASK=0x707f 等] ----
`define RV32GC_F3_LB         3'b000
`define RV32GC_F3_LH         3'b001
`define RV32GC_F3_LW         3'b010
`define RV32GC_F3_LBU        3'b100
`define RV32GC_F3_LHU        3'b101

// ---- 3.3 STORE（opcode=0100011）[ENC:SB=0x23/SH=0x1023/SW=0x2023 MASK=0x707f] ----
`define RV32GC_F3_SB         3'b000
`define RV32GC_F3_SH         3'b001
`define RV32GC_F3_SW         3'b010

// ---- 3.4 BRANCH（opcode=1100011）[ENC:BEQ=0x63/BNE=0x1063/BLT=0x4063/BGE=0x5063/
//      BLTU=0x6063/BGEU=0x7063 MASK=0x707f] ----
`define RV32GC_F3_BEQ        3'b000
`define RV32GC_F3_BNE        3'b001
`define RV32GC_F3_BLT        3'b100
`define RV32GC_F3_BGE        3'b101
`define RV32GC_F3_BLTU       3'b110
`define RV32GC_F3_BGEU       3'b111

// ---- 3.5 OP-IMM（opcode=0010011）[ENC:ADDI=0x13 MASK=0x707f；SLLI_RV32=0x1013
//      MASK=0xfe00707f(funct7=0000000)；SRLI_RV32=0x5013(funct7=0000000)；
//      SRAI_RV32=0x40005013(funct7=0100000)] —— 移位立即数在 RV32 上位 5 位必须为 0 ----
`define RV32GC_F3_ADDI       3'b000
`define RV32GC_F3_SLTI       3'b010
`define RV32GC_F3_SLTIU      3'b011
`define RV32GC_F3_XORI       3'b100
`define RV32GC_F3_ORI        3'b110
`define RV32GC_F3_ANDI       3'b111
`define RV32GC_F3_SLLI       3'b001
`define RV32GC_F3_SRLI_SRAI  3'b101
`define RV32GC_F7_SRLI       7'b0000000   // RV32 移位立即数上限 shamt[4:0]，funct7[6:5]=00
`define RV32GC_F7_SRAI       7'b0100000

// ---- 3.6 OP（opcode=0110011）[ENC:ADD=0x33/SUB=0x40000033/SLL=0x1033/SLT=0x2033/
//      SLTU=0x3033/XOR=0x4033/SRL=0x5033/SRA=0x40005033/OR=0x6033/AND=0x7033
//      MASK=0xfe00707f] ----
`define RV32GC_F7_OP_ALT     7'b0100000   // sub / sra
`define RV32GC_F7_OP_BASE    7'b0000000
`define RV32GC_F3_ADD_SUB    3'b000
`define RV32GC_F3_SLL        3'b001
`define RV32GC_F3_SLT        3'b010
`define RV32GC_F3_SLTU       3'b011
`define RV32GC_F3_XOR        3'b100
`define RV32GC_F3_SRL_SRA    3'b101
`define RV32GC_F3_OR         3'b110
`define RV32GC_F3_AND        3'b111

// ---- 3.7 M 扩展：乘法/除法（opcode=0110011，funct7=0000001）
//      [ENC:MUL=0x2000033(f3=0)/MULH=0x2001033(1)/MULHSU=0x2002033(2)/MULHU=0x2003033(3)/
//       DIV=0x2004033(4)/DIVU=0x2005033(5)/REM=0x2006033(6)/REMU=0x2007033(7)，MASK=0xfe00707f] ----
`define RV32GC_F7_MULDIV     7'b0000001
`define RV32GC_F3_MUL        3'b000
`define RV32GC_F3_MULH       3'b001
`define RV32GC_F3_MULHSU     3'b010
`define RV32GC_F3_MULHU      3'b011
`define RV32GC_F3_DIV        3'b100
`define RV32GC_F3_DIVU       3'b101
`define RV32GC_F3_REM        3'b110
`define RV32GC_F3_REMU       3'b111

// ---- 3.8 A 扩展（opcode=0101111，funct3=010）
//      [ENC:AMOADD_W=0x202f/AMOSWAP_W=0x800202f/LR_W=0x1000202f/SC_W=0x1800202f/
//       AMOXOR_W=0x2000202f/AMOOR_W=0x4000202f/AMOAND_W=0x6000202f/AMOMIN_W=0x8000202f/
//       AMOMAX_W=0xa000202f/AMOMINU_W=0xc000202f/AMOMAXU_W=0xe000202f；MASK=0xf800707f
//       ⇒ insn[31:27]=funct5、insn[26:25]=aq/rl、insn[24:20]=rs2]
//      注：AMO 家族的 funct5 位于 insn[31:27]，而 rf 的 aq/rl 位于 insn[26:25]，
//          故本文件用 RV32GC_AMO_*（5 位）而非「funct7」，避免与 rf 混用出错。 ----
`define RV32GC_F3_AMO        3'b010
`define RV32GC_AMO_ADD       5'b00000
`define RV32GC_AMO_SWAP      5'b00001
`define RV32GC_AMO_LR        5'b00010   // LR.W（rs2 必须为 00000）
`define RV32GC_AMO_SC        5'b00011   // SC.W
`define RV32GC_AMO_XOR       5'b00100
`define RV32GC_AMO_OR        5'b01000
`define RV32GC_AMO_AND       5'b01100
`define RV32GC_AMO_MIN       5'b10000
`define RV32GC_AMO_MAX       5'b10100
`define RV32GC_AMO_MINU      5'b11000
`define RV32GC_AMO_MAXU      5'b11100
`define RV32GC_AMO_AQ_BIT    25          // insn[25] = AQ
`define RV32GC_AMO_RL_BIT    24          // insn[24] = RL

// ---- 3.9 SYSTEM（opcode=1110011）[ENC:PRIV=0x73 MASK=0x707f；CSR 三条 f3=001/010/011] ----
`define RV32GC_F3_PRIV       3'b000
`define RV32GC_F3_CSRRW      3'b001
`define RV32GC_F3_CSRRS      3'b010
`define RV32GC_F3_CSRRC      3'b011
`define RV32GC_F3_CSRRWI     3'b101
`define RV32GC_F3_CSRRSI     3'b110
`define RV32GC_F3_CSRRCI     3'b111
`define RV32GC_CSR_ZIMM_W    5           // csr[4:0]：立即数形式写 CSR 的 zimm 位宽
// rs2 域（funct3=000 时 insn[24:20]）作为 PRIV 功能码；
// f7=insn[31:25]。以下为完整 32 位 MATCH 值（含 f7/rs2/rs1/rd 全零），可直接比较。
`define RV32GC_INSN_ECALL    32'h0000_0073   // [ENC:MATCH_ECALL=0x73 MASK=0xffffffff]
`define RV32GC_INSN_EBREAK   32'h0010_0073   // [ENC:MATCH_EBREAK=0x100073 MASK=0xffffffff]
`define RV32GC_INSN_URET     32'h0020_0073   // [ENC:MATCH_URET=0x200073 MASK=0xffffffff]
`define RV32GC_INSN_SRET     32'h1020_0073   // [ENC:MATCH_SRET=0x10200073 MASK=0xffffffff]
`define RV32GC_INSN_MRET     32'h3020_0073   // [ENC:MATCH_MRET=0x30200073 MASK=0xffffffff]
`define RV32GC_INSN_WFI      32'h1050_0073   // [ENC:MATCH_WFI=0x10500073 MASK=0xffffffff]

// ---- 3.10 MISC-MEM（opcode=0001111）[ENC:FENCE=0xf MASK=0x707f；FENCE_I=0x100f
//      MASK=0x707f ⇒ f3=000 fence / f3=001 fence.i] ----
`define RV32GC_F3_FENCE      3'b000
`define RV32GC_F3_FENCE_I    3'b001

// ---- 3.11 Zicbom：cbo.clean / cbo.flush / cbo.inval
//      **2A 范围：只含 Zicbom 的 clean/flush/inval；cbo.zero 属 Zicboz，明确排除**
//      （08-baseline-5stage.md §8.2 排除清单与 §11 R1；
//        任务书口径：Zicboz/cbo.zero 归后续阶段，本真源**不定义其编码**）。
//      [ENC:CBO_INVAL=0x200f(f3=010,f7=0000000,rs2=00000)
//            CBO_CLEAN=0x10200f(rs2=00001)
//            CBO_FLUSH=0x20200f(rs2=00010)
//            MASK=0xfff07fff ⇒ opcode=0001111、funct3=010、funct7=0000000、
//            rs2=insn[24:20] 选择动作，rs1=insn[19:15] 为地址，rd 忽略(应为 x0)]
//      ★ 关键：clean/flush 的 funct7 相同，**只靠 rs2 区分**；而 insn[24:20] 同时是
//        OP-FP 的 fmt(insn[26:25])+rs2 区段的低 5 位，故译码器必须把 (opcode,funct3)
//        与 rs2 一起比较，不得只看 funct7。 ----
`define RV32GC_F3_CBO        3'b010
`define RV32GC_F7_CBO        7'b0000000
`define RV32GC_CBO_INVAL     5'b00000   // cbo.inval  —— 无写回，直接失效
`define RV32GC_CBO_CLEAN     5'b00001   // cbo.clean  —— 写回并保留
`define RV32GC_CBO_FLUSH     5'b00010   // cbo.flush  —— 写回并失效
// `define RV32GC_CBO_ZERO   5'b00100   // (Zicboz) cbo.zero —— **2A 不定义，禁止启用**

// ---- 3.12 LOAD-FP / STORE-FP（flw/fsw 属 F；fld/fsd 属 D）
//      [ENC:FLW=0x2007(f3=010) / FLD=0x3007(f3=011) / FSW=0x2027 / FSD=0x3027，MASK=0x707f] ----
`define RV32GC_F3_FLW        3'b010
`define RV32GC_F3_FLD        3'b011
`define RV32GC_F3_FSW        3'b010
`define RV32GC_F3_FSD        3'b011

// ---- 3.13 OP-FP：fmt 位段（insn[26:25]）
//      [ENC:FADD_S=0x53(fmt=00)/FADD_D=0x2000053(fmt=01)
//           FSGNJ_D=0x22000053/MASK=0xfe00707f ⇒ insn[26:25]=fmt、insn[31:27]=funct5]
//      ★ 注意：OP-FP 的 funct7 = {funct5[6:0], fmt[1:0]} 的低 7 位，
//        即 OP-FP 的「funct7 低 2 位」就是 fmt，**不是** funct7[1:0] 的独立编码；
//        译码时必须把 fmt 与 funct5 分开比较，禁止把 fmt 塞进 funct7 常量。 ----
`define RV32GC_FMT_S         2'b00       // 单精度
`define RV32GC_FMT_D         2'b01       // 双精度
// funct5（insn[31:27]）[ENC 见上行 MATCH 值]
`define RV32GC_FP_F5_FADD    5'b00000
`define RV32GC_FP_F5_FSUB    5'b00001
`define RV32GC_FP_F5_FMUL    5'b00010
`define RV32GC_FP_F5_FDIV    5'b00011
`define RV32GC_FP_F5_FSQRT   5'b01011
`define RV32GC_FP_F5_FSGNJ   5'b00100   // fsgnj/fsgnjn/fsgnjx 由 funct3 区分
`define RV32GC_FP_F5_FMINMAX 5'b00101   // fmin/fmax 由 funct3 区分
`define RV32GC_FP_F5_FCVT    ('h8 >> 3) // = 5'b01000（fcvt.T.S/D）
`define RV32GC_FP_F5_FMV_CMP 5'b11100   // fmv.x.w/fclass（funct3 区分）
`define RV32GC_FP_F5_FMV_X_W 5'b11100   // 同组别名（可读性）
`define RV32GC_FP_F5_FMV_W_X 5'b11110   // fmv.w.x
`define RV32GC_FP_F5_FCMP    5'b10100   // fle/flt/feq（funct3 区分）
// funct3
`define RV32GC_FP_F3_FSGNJ   3'b000
`define RV32GC_FP_F3_FSGNJN  3'b001
`define RV32GC_FP_F3_FSGNJX  3'b010
`define RV32GC_FP_F3_FMIN    3'b000
`define RV32GC_FP_F3_FMAX    3'b001
`define RV32GC_FP_F3_FLE     3'b000
`define RV32GC_FP_F3_FLT     3'b001
`define RV32GC_FP_F3_FEQ     3'b010
`define RV32GC_FP_F3_FCLASS  3'b001   // fmt 位（insn[26:25]）选择 S/D 视图，funct3=001
// rs2 变体选择（与 fmt 正交）
`define RV32GC_FP_RS2_X0     5'b00000   // fcvt.T.W / fcvt.D.S 等（有符号/窄源）
`define RV32GC_FP_RS2_X1     5'b00001   // fcvt.T.WU
//      fcvt.fmt.fmt 的转换矩阵 [ENC:FCVT_S_D=0x40100053(fmt=00,入口 rs2=00001)
//           FCVT_D_S=0x42000053(fmt=01,入口 rs2=00000)
//           FCVT_W_S=0xc0000053(出口 fmt=00,rs2=00000)  FCVT_WU_S=0xc0100053(rs2=00001)
//           FCVT_W_D=0xc2000053(出口 fmt=01)           FCVT_WU_D=0xc2100053(rs2=00001)
//           FCVT_S_W=0xd0000053(入口 fmt=00)           FCVT_S_WU=0xd0100053(rs2=00001)
//           FCVT_D_W=0xd2000053(入口 fmt=01)           FCVT_D_WU=0xd2100053(rs2=00001)]
//      出口口径（写整数）：源 fmt 由 insn[26:25] 给出、rs2[0] 选 W/WU。
//      入口口径（写 FP）  ：目标 fmt 由 insn[26:25] 给出、rs2[0] 选 W/WU。
//      F↔D 互转           ：目标 fmt 由 insn[26:25] 给出、rs2 = 源 fmt（S=0/D=1）。

// ---- 3.14 FMA 族（fmadd/fmsub/fnmsub/fnmadd）
//      [ENC:FMADD_S=0x43/MASK=0x600007f；FMADD_D=0x2000043 ⇒ fmt=insn[26:25]]
//      rd/rs1/rs2/rs3（insn[31:27]）为标准 R4 型；funct3 恒 000（RM 位）。 ----
`define RV32GC_RM_RNE        3'b000       // round to nearest, ties to even
`define RV32GC_RM_RTZ        3'b001       // round towards zero
`define RV32GC_RM_RDN        3'b010       // round down (−inf)
`define RV32GC_RM_RUP        3'b011       // round up (+inf)
`define RV32GC_RM_RMM        3'b100       // round to nearest, ties to max magnitude
`define RV32GC_RM_DYN        3'b111       // 使用 fcsr.frm

//==============================================================================
// 4. CSR 地址全表（12 bit）
//    [ISA:riscv-isa-manual/src/priv/csrs.adoc:131-523 「CSR Listing」逐行核对]
//    每条后 [csrs.adoc:NNN] 给出该表行号。
//    访问权限由地址高 4 位编码：csr[11:10]=读写属性、csr[9:8]=最低可访问特权级
//    [ISA:csrs.adoc:25-49]。
//    ★ 规格纠偏：docs/design/08-baseline-5stage.md §6.2 把 mepc/mcause/mtval/mip
//      写成 0x340/0x342/0x343/0x344（错位一格）；规范真值为 0x341/0x342/0x343/0x344，
//      0x340 是 mscratch。本真源一律用**规范值**。
//==============================================================================

// ---- 4.1 CSR 地址权限编码 [ISA:csrs.adoc:25-49] ----
`define RV32GC_CSR_RW_BITS  2           // csr[11:10]：00/01/10=读写，11=只读
`define RV32GC_CSR_PRIV_LSB  8           // csr[9:8]：00=U/User、01=S、10=H、11=M

// ---- 4.2 非特权：FP 与计数器 [ISA:csrs.adoc:145-190] ----
`define RV32GC_CSR_FFLAGS     12'h001
`define RV32GC_CSR_FRM        12'h002
`define RV32GC_CSR_FCSR       12'h003
`define RV32GC_CSR_CYCLE      12'hC00   // [csrs.adoc:176] URO
`define RV32GC_CSR_TIME       12'hC01   // [csrs.adoc:177] URO
`define RV32GC_CSR_INSTRET    12'hC02   // [csrs.adoc:178] URO
`define RV32GC_CSR_CYCLEH     12'hC80   // [csrs.adoc:183] RV32 only
`define RV32GC_CSR_TIMEH      12'hC81   // [csrs.adoc:184] RV32 only
`define RV32GC_CSR_INSTRETH   12'hC82   // [csrs.adoc:185] RV32 only

// ---- 4.3 S 模式 [ISA:csrs.adoc:195-270] ----
`define RV32GC_CSR_SSTATUS    12'h100   // [csrs.adoc:204]
`define RV32GC_CSR_SIE        12'h104   // [csrs.adoc:205]
`define RV32GC_CSR_STVEC      12'h105   // [csrs.adoc:206]
`define RV32GC_CSR_SCOUNTEREN 12'h106   // [csrs.adoc:207]
`define RV32GC_CSR_SENVCFG    12'h10A   // [csrs.adoc:212]
`define RV32GC_CSR_SSCRATCH   12'h140   // [csrs.adoc:220]
`define RV32GC_CSR_SEPC       12'h141   // [csrs.adoc:221]
`define RV32GC_CSR_SCAUSE     12'h142   // [csrs.adoc:222]
`define RV32GC_CSR_STVAL      12'h143   // [csrs.adoc:223]
`define RV32GC_CSR_SIP        12'h144   // [csrs.adoc:224]
`define RV32GC_CSR_SATP       12'h180   // [csrs.adoc:242] MODE(1)|ASID(9)|PPN(22)
// 未实现（2A 不落地，仅登记以免误用）：
//   sieh 0x114 / scountinhibit 0x120 / siph 0x154 / scountovf 0xDA0
//   等高半部/扩展 CSR 不在 2A 范围（[ISA:csrs.adoc:208,216,225,227]）。

// ---- 4.4 M 模式：信息寄存器 [ISA:csrs.adoc:383-389] ----
`define RV32GC_CSR_MVENDORID 12'hF11   // MRO
`define RV32GC_CSR_MARCHID   12'hF12   // MRO
`define RV32GC_CSR_MIMPID    12'hF13   // MRO
`define RV32GC_CSR_MHARTID   12'hF14   // MRO（本设计硬连 0）

// ---- 4.5 M 模式：陷阱设置 [ISA:csrs.adoc:391-407] ----
`define RV32GC_CSR_MSTATUS    12'h300   // [csrs.adoc:393]
`define RV32GC_CSR_MISA       12'h301   // [csrs.adoc:394]
`define RV32GC_CSR_MEDELEG    12'h302   // [csrs.adoc:395]
`define RV32GC_CSR_MIDELEG    12'h303   // [csrs.adoc:396]
`define RV32GC_CSR_MIE        12'h304   // [csrs.adoc:397]
`define RV32GC_CSR_MTVEC      12'h305   // [csrs.adoc:398]
`define RV32GC_CSR_MCOUNTEREN 12'h306   // [csrs.adoc:399]
`define RV32GC_CSR_MSTATUSH   12'h310   // [csrs.adoc:402] RV32 必需；soc 无 MBE/SBE ⇒ 读 0
`define RV32GC_CSR_MEDELEGH   12'h312   // [csrs.adoc:403] RV32 高半别名（见 §6 口径）
`define RV32GC_CSR_MIDELEGH   12'h313   // [csrs.adoc:404] RV32 高半别名

// ---- 4.6 M 模式：环境配置 [ISA:csrs.adoc:432-437] ----
`define RV32GC_CSR_MENVCFG    12'h30A   // [csrs.adoc:434] FIOM/CBIE/CBCFE/CBZE
`define RV32GC_CSR_MENVCFGH   12'h31A   // [csrs.adoc:435] RV32 高半（2A 保留，读 0）

// ---- 4.7 M 模式：陷阱处理 [ISA:csrs.adoc:409-420] ----
`define RV32GC_CSR_MSCRATCH   12'h340   // [csrs.adoc:411]
`define RV32GC_CSR_MEPC       12'h341   // [csrs.adoc:412]
`define RV32GC_CSR_MCAUSE     12'h342   // [csrs.adoc:413]
`define RV32GC_CSR_MTVAL      12'h343   // [csrs.adoc:414]
`define RV32GC_CSR_MIP        12'h344   // [csrs.adoc:415]

// ---- 4.8 M 模式：PMP 配置/地址寄存器 [ISA:csrs.adoc:439-451] ----
// RV32 下 pmpcfg0..3 覆盖 16 项（每 CSR 4 项 × 8 bit）；
// pmpcfg4..15 是 RV64 的 64 项形态（本设计 16 项，不使用）。
`define RV32GC_CSR_PMPCFG0    12'h3A0   // [csrs.adoc:441] 项 0-3
`define RV32GC_CSR_PMPCFG1    12'h3A1   // [csrs.adoc:442] 项 4-7   （RV32 only）
`define RV32GC_CSR_PMPCFG2    12'h3A2   // [csrs.adoc:443] 项 8-11
`define RV32GC_CSR_PMPCFG3    12'h3A3   // [csrs.adoc:444] 项 12-15 （RV32 only）
`define RV32GC_CSR_PMPADDR0   12'h3B0   // [csrs.adoc:448]
// pmpaddr1..15 = 0x3B1..0x3BF（等距，逐项定义以便静态查表）
`define RV32GC_CSR_PMPADDR1   12'h3B1
`define RV32GC_CSR_PMPADDR2   12'h3B2
`define RV32GC_CSR_PMPADDR3   12'h3B3
`define RV32GC_CSR_PMPADDR4   12'h3B4
`define RV32GC_CSR_PMPADDR5   12'h3B5
`define RV32GC_CSR_PMPADDR6   12'h3B6
`define RV32GC_CSR_PMPADDR7   12'h3B7
`define RV32GC_CSR_PMPADDR8   12'h3B8
`define RV32GC_CSR_PMPADDR9   12'h3B9
`define RV32GC_CSR_PMPADDR10  12'h3BA
`define RV32GC_CSR_PMPADDR11  12'h3BB
`define RV32GC_CSR_PMPADDR12  12'h3BC
`define RV32GC_CSR_PMPADDR13  12'h3BD
`define RV32GC_CSR_PMPADDR14  12'h3BE
`define RV32GC_CSR_PMPADDR15  12'h3BF

// ---- 4.9 M 模式：计数器 [ISA:csrs.adoc:471-500] ----
`define RV32GC_CSR_MCYCLE     12'hB00   // [csrs.adoc:473]
`define RV32GC_CSR_MINSTRET   12'hB02   // [csrs.adoc:474]
`define RV32GC_CSR_MCOUNTINHIBIT 12'h320 // [csrs.adoc:488]
//      ★ arch-test 新版启动代码**无条件**写 mcountinhibit 与 mhpmevent3..31
//        （riscv-arch-test/tests/env/rvtest_setup.h:1059-1129）⇒ 2A 的 csr_file
//        必须让 mcountinhibit（0x320）与 mhpmevent3..31（0x323..0x33F）可写
//        （WARL 吞写或部分实现），否则回归会在启动阶段挂死。详见报告「遗留/风险」。
`define RV32GC_CSR_MCYCLEH    12'hB80   // [csrs.adoc:479] RV32 only（预留登记）
`define RV32GC_CSR_MINSTRETH  12'hB82   // [csrs.adoc:480] RV32 only（预留登记）
`define RV32GC_CSR_MHPMEVENT3  12'h323  // [csrs.adoc:491]
`define RV32GC_CSR_MHPMEVENT31 12'h33F  // [csrs.adoc:494]

// ---- 4.10 U 模式 CSR [ENC:binutils riscv-opc.h:4289-4296 / DECLARE_CSR:5610-5617] ----
//      ★ 版本敏感声明（必须如实标注）：
//        本工作区手册版本为 20250508（riscv-isa-manual/src/unpriv/preface.adoc:208），
//        该版本 **csrs.adoc 的 CSR Listing 已不含 ustatus/uie/utvec/uscratch/uepc/
//        ucause/utval/uip 表**（检索 csrs.adoc 全文无 ustatus），
//        machine.adoc:152 仅以 misa 的 "User mode implemented" 位表达 U 模式存在；
//        binutils 亦把这一组标注为 PRIV_SPEC_CLASS_1P10 起、1P12 移除
//        （riscv-opc.h:5610-5617 的第三个参数 = PRIV_SPEC_CLASS_1P12）。
//        工程口径：本设计实现 M/S/U 三特权级模型，按任务要求给出这一组地址常量
//        （"完整 M/S/U 模型"），但**必须**在 csr_file.v 里以
//        `RV32GC_IMPLEMENT_U_MODE_CSRS` 开关统一控制是否真正落地/暴露。
//        地址值出自 binutils（1P10 口径），不可作为 1P12 之后的合规依据。
`define RV32GC_CSR_USTATUS    12'h000   // 1P10 口径
`define RV32GC_CSR_UIE        12'h004   // 1P10 口径
`define RV32GC_CSR_UTVEC      12'h005   // 1P10 口径
`define RV32GC_CSR_USCRATCH   12'h040   // 1P10 口径
`define RV32GC_CSR_UEPC       12'h041   // 1P10 口径
`define RV32GC_CSR_UCAUSE     12'h042   // 1P10 口径
`define RV32GC_CSR_UTVAL      12'h043   // 1P10 口径
`define RV32GC_CSR_UIP        12'h044   // 1P10 口径

//==============================================================================
// 5. mstatus / sstatus / mcause / mtvec 位域
//    [DOC:docs/design/06-csr-privilege.md §3；ISA:riscv-isa-manual/src/priv/machine.adoc]
//==============================================================================
`define RV32GC_MSTATUS_UIE_BIT     0
`define RV32GC_MSTATUS_SIE_BIT     1
`define RV32GC_MSTATUS_MIE_BIT     3
`define RV32GC_MSTATUS_SPIE_BIT    5
`define RV32GC_MSTATUS_UBE_BIT     6
`define RV32GC_MSTATUS_MPIE_BIT    7
`define RV32GC_MSTATUS_SPP_BIT     8
`define RV32GC_MSTATUS_VS_LSB      9     // [9:10]
`define RV32GC_MSTATUS_VS_MSK      2'b11
`define RV32GC_MSTATUS_MPP_LSB     11    // [12:11]
`define RV32GC_MSTATUS_MPP_MSK     2'b11
`define RV32GC_MSTATUS_FS_LSB      13    // [14:13]
`define RV32GC_MSTATUS_FS_MSK      2'b11
`define RV32GC_MSTATUS_XS_LSB      15    // [16:15]（只读 0）
`define RV32GC_MSTATUS_MPRV_BIT    17
`define RV32GC_MSTATUS_SUM_BIT     18
`define RV32GC_MSTATUS_MXR_BIT     19
`define RV32GC_MSTATUS_TVM_BIT     20
`define RV32GC_MSTATUS_TW_BIT      21
`define RV32GC_MSTATUS_TSR_BIT     22
`define RV32GC_MSTATUS_SD_BIT      31    // 只读汇总位（FS/VS/XS 任一为 Dirty）
// FS 字段编码
`define RV32GC_FS_OFF         2'b00
`define RV32GC_FS_INITIAL     2'b01
`define RV32GC_FS_CLEAN       2'b10
`define RV32GC_FS_DIRTY       2'b11

// ---- 5.2 特权级编码（与 mstatus.MPP 同编码） ----
`define RV32GC_PRIV_U         2'b00
`define RV32GC_PRIV_S         2'b01
`define RV32GC_PRIV_M         2'b11

// ---- 5.3 mtvec / stvec（BASE + MODE） ----
//      [ISA:riscv-isa-manual/src/priv/machine.adoc] BASE 4 B 对齐（低 2 位 0）；
//      MODE：0=Direct、1=Vectored（Vectored 要求 BASE 256 B 对齐，低 8 位 0）。
//      用户口径：**实现 Vectored**（08-baseline-5stage.md §6.5）。
`define RV32GC_TVEC_MODE_LSB   0
`define RV32GC_TVEC_MODE_MSK   2'b11
`define RV32GC_TVEC_MODE_DIRECT   2'b00
`define RV32GC_TVEC_MODE_VECTORED 2'b01
`define RV32GC_TVEC_BASE_ALIGN_DIRECT    2    // Direct  ：BASE 低 2 位为 0
`define RV32GC_TVEC_BASE_ALIGN_VECTORED  8    // Vectored：BASE 低 8 位为 0
`define RV32GC_TVEC_BASE_MSK             12'hFFF_FFFC  // Direct 下 BASE 提取掩码

// ---- 5.4 mepc / sepc 对齐（IALIGN=16 ⇒ 只有 bit0 恒 0；bit1 可写） ----
//      [ISA:riscv-isa-manual/src/priv/machine.adoc:1689-1696  norm:mepc_align]
`define RV32GC_EPC_LSB         1     // IALIGN=16 时 epc[0]=0（bit1 可写）

//==============================================================================
// 6. 异常/中断 cause 编码
//    [ISA:riscv-isa-manual/src/priv/machine.adoc；DOC:docs/kb/isa-notes.md T1-T8；
//     DOC:docs/design/08-baseline-5stage.md §6.3]
//==============================================================================
`define RV32GC_CAUSE_W         5       // cause 码位宽（不含 Interrupt 位）
`define RV32GC_MCAUSE_INT_BIT  31      // [ISA] mcause[31]=1 表示中断
`define RV32GC_MCAUSE_INT_MSK  (32'h1 << RV32GC_MCAUSE_INT_BIT)

// ---- 6.1 异常（Interrupt=0）：2A 实现 0/1/2/3/4/5/6/7/8/9/11/12/13/15 ----
//      08 §6.2 明确「medeleg 不实现 10/11/14」中的 10/14 为保留项；
//      11 (mecall) 作为 M→(delegated target) 的 ecall 码保留定义。
`define RV32GC_EXC_INSN_MISALIGNED       5'd0    // instruction address misaligned
`define RV32GC_EXC_INSN_ACCESS_FAULT     5'd1    // instruction access fault（取指 PMP 拒，T2）
`define RV32GC_EXC_ILLEGAL_INSN          5'd2    // illegal instruction
`define RV32GC_EXC_BREAKPOINT            5'd3    // breakpoint（ebreak）
`define RV32GC_EXC_LOAD_MISALIGNED       5'd4    // load address misaligned（T3：非对齐优先）
`define RV32GC_EXC_LOAD_ACCESS_FAULT     5'd5    // load access fault（PMP load 拒）
`define RV32GC_EXC_STORE_MISALIGNED      5'd6    // store/AMO address misaligned
`define RV32GC_EXC_STORE_ACCESS_FAULT    5'd7    // store/AMO access fault（T4：AMO 被 PMP 拒恒 7）
`define RV32GC_EXC_ECALL_U               5'd8    // environment call from U-mode
`define RV32GC_EXC_ECALL_S               5'd9    // environment call from S-mode
`define RV32GC_EXC_ECALL_M               5'd11   // environment call from M-mode
`define RV32GC_EXC_INSN_PAGE_FAULT       5'd12   // instruction page fault
`define RV32GC_EXC_LOAD_PAGE_FAULT       5'd13   // load page fault
`define RV32GC_EXC_STORE_PAGE_FAULT      5'd15   // store/AMO page fault
// 说明：cause 10/14 为保留（Reserved），2A 不产生。

// ---- 6.2 中断（Interrupt=1）：M 专属 3/7/11，S 级 1/5/9 ----
`define RV32GC_IRQ_S_SOFTWARE            5'd1    // SSI
`define RV32GC_IRQ_M_SOFTWARE            5'd3    // MSI（CLINT msip）
`define RV32GC_IRQ_S_TIMER               5'd5    // STI
`define RV32GC_IRQ_M_TIMER               5'd7    // MTI（CLINT mtimecmp）
`define RV32GC_IRQ_S_EXTERNAL            5'd9    // SEI（PLIC context 1）
`define RV32GC_IRQ_M_EXTERNAL            5'd11   // MEI（PLIC context 0）
// 便捷掩码（mip/mie 的位位置即 cause 码）
`define RV32GC_MIP_MSIP_BIT   3
`define RV32GC_MIP_MTIP_BIT   7
`define RV32GC_MIP_MEIP_BIT   11
`define RV32GC_MIP_SSIP_BIT   1
`define RV32GC_MIP_STIP_BIT   5
`define RV32GC_MIP_SEIP_BIT   9
`define RV32GC_MIDELEG_IMPL_MSK 32'h0000_0222   // bit 1|5|9（08 §6.2）
`define RV32GC_MEDELEG_IMPL_MSK 32'h0000_B3FF   // bit 0-9|12|13|15（08 §6.2）

//==============================================================================
// 7. PMP 常量（16 项，粒度 G=0）
//    [ISA:riscv-isa-manual/src/priv/machine.adoc（PMP CSRs / Priority and Matching Logic）；
//     DOC:docs/kb/isa-notes.md §3；DOC:docs/design/08-baseline-5stage.md §5.5 抉择 5/6]
//==============================================================================
`define RV32GC_PMP_ENTRIES    16          // 项数（主参数别名，见 core_params.vh）
`define RV32GC_PMP_CFG_W      8           // 每项 pmpcfg 字段宽
`define RV32GC_PMP_CFG_PER_CSR 4          // RV32：每 4 项打包进一个 pmpcfg CSR
`define RV32GC_PMP_GRANULARITY 0          // G=0 ⇒ 4 B 粒度，NA4 可用，pmpaddr 不做低位掩码
// ---- pmpcfg 位域 [ISA:3A0 描述] ----
`define RV32GC_PMP_R_BIT      0
`define RV32GC_PMP_W_BIT      1
`define RV32GC_PMP_X_BIT      2
`define RV32GC_PMP_A_LSB      3
`define RV32GC_PMP_A_MSK      2'b11
`define RV32GC_PMP_L_BIT      7
// ---- A 字段编码 ----
`define RV32GC_PMP_A_OFF      2'b00
`define RV32GC_PMP_A_TOR      2'b01
`define RV32GC_PMP_A_NA4      2'b10       // G=0 下可用
`define RV32GC_PMP_A_NAPOT    2'b11
// ---- 匹配语义常量（供 pmp_check.v 使用） ----
`define RV32GC_PMP_PPN_BITS   30          // pmpaddr 有效位数（pmpaddr[29:0] ⇔ PA[33:4] 的 RV32 截取）
`define RV32GC_PMP_ADDR_BITS  32

//==============================================================================
// 8. Sv32（satp.MODE / PTE 字段）
//    [ISA:riscv-isa-manual/src/priv/supervisor.adoc；DOC:docs/kb/isa-notes.md §2]
//==============================================================================
`define RV32GC_SATP_MODE_BIT     31       // RV32 satp：MODE 1 bit（0=Bare,1=Sv32）
`define RV32GC_SATP_ASID_LSB     22       // ASID[8:0]
`define RV32GC_SATP_PPN_LSB      0        // PPN[21:0]
`define RV32GC_SATP_MODE_BARE    1'b0
`define RV32GC_SATP_MODE_SV32    1'b1
`define RV32GC_SV32_LEVELS       2        // 两级页表
`define RV32GC_SV32_PTESIZE      4        // PTE 4 B
`define RV32GC_SV32_PAGESIZE_LSB 12       // 页 4 KiB
`define RV32GC_SV32_VPN_BITS     10       // 每级 VPN 10 bit
`define RV32GC_SV32_PPN_BITS     22
`define RV32GC_PTE_V_BIT         0
`define RV32GC_PTE_R_BIT         1
`define RV32GC_PTE_W_BIT         2
`define RV32GC_PTE_X_BIT         3
`define RV32GC_PTE_U_BIT         4
`define RV32GC_PTE_G_BIT         5
`define RV32GC_PTE_A_BIT         6
`define RV32GC_PTE_D_BIT         7
`define RV32GC_PTE_PPN_LSB       10

//==============================================================================
// 9. AXI4 常量（核内主端口控制器用）
//    [DOC:docs/kb/platform-facts.md §1.3；DOC:docs/design/05-cache-memory.md §4.2；
//     DOC:docs/design/08-baseline-5stage.md §7.2]
//==============================================================================
`define RV32GC_AXI_ID_W       4           // 平台 config.h:50/78：4 bit ID
`define RV32GC_AXI_ADDR_W     32
`define RV32GC_AXI_DATA_W     32          // 平台为 32 位数据（AXI128/AXI64 未定义时）
`define RV32GC_AXI_STRB_W     4
`define RV32GC_AXI_LEN_W      4           // 4 bit ⇒ 突发 ≤16 beat
`define RV32GC_AXI_SIZE_W     3
`define RV32GC_AXI_BURST_W    2
`define RV32GC_AXI_LOCK_W     2
`define RV32GC_AXI_CACHE_W    4
`define RV32GC_AXI_PROT_W     3
`define RV32GC_AXI_RESP_W     2
// ---- size：3'b010 = 4 B（=2^2） ----
`define RV32GC_AXI_SIZE_1B    3'b000
`define RV32GC_AXI_SIZE_2B    3'b001
`define RV32GC_AXI_SIZE_4B    3'b010       // 本设计固定值
// ---- len：4 bit，最大 16 beat ----
`define RV32GC_AXI_LEN_MAX    4'd15
// ---- burst ----
`define RV32GC_AXI_BURST_FIXED 2'b00
`define RV32GC_AXI_BURST_INCR  2'b01       // 默认
`define RV32GC_AXI_BURST_WRAP  2'b10       // 仅行填充对齐使用
// ---- lock：平台只接 arlock[0:0]/awlock[0:0] ⇒ 核内高位必须显式置 0 ----
`define RV32GC_AXI_LOCK_NORMAL 2'b00
// ---- cache/prot（08 §7.1 要点 4） ----
`define RV32GC_AXI_CACHE_CACHED   4'b1111  // 行填充（可缓存）
`define RV32GC_AXI_CACHE_UNCACHED 4'b0000  // MMIO / XIP
`define RV32GC_AXI_PROT_DATA      3'b010   // 非特权、非安全、数据访问
// ---- resp ----
`define RV32GC_AXI_RESP_OKAY    2'b00
`define RV32GC_AXI_RESP_EXOKAY  2'b01
`define RV32GC_AXI_RESP_SLVERR  2'b10
`define RV32GC_AXI_RESP_DECERR  2'b11
// ---- 4 KiB 边界（控制器必须在描述符生成时拆分） ----
`define RV32GC_AXI_4K_MSK     12'hFFF       // 低 12 位为 4 K 内偏移
`define RV32GC_AXI_4K_BYTES   32'h0000_1000

//==============================================================================
// 10. 陷阱取值口径开关与平台窗口常量（供取值/译码共用，避免各处硬编码）
//     窗口值 [DOC:docs/kb/platform-facts.md §2；DOC:docs/design/05-cache-memory.md §5.1]
//==============================================================================
// mtval 写「故障指令位」：**本设计选择实现**（规范为可选）
// [ISA:riscv-isa-manual/src/priv/machine.adoc:2039-2094；DOC:docs/kb/isa-notes.md T1]
`define RV32GC_MTVAL_INSTR_BITS      1
// 取指 PMP 检查粒度 = 16-bit parcel：**本设计选择**（规范未明说）
// [DOC:docs/kb/isa-notes.md T2；DOC:docs/design/08-baseline-5stage.md §5.5 抉择 2]
`define RV32GC_FETCH_PMP_PER_PARCEL  1
// 非对齐 vs page/access fault：**本设计选择非对齐优先** [DOC:docs/kb/isa-notes.md T3]
`define RV32GC_MISALIGN_PRIORITY_HIGH 1
// 2A 不实现 Zicboz（cbo.zero）—— 保留位域不保留逻辑
// [DOC:docs/design/08-baseline-5stage.md §11 R1；DOC:docs/design/06-csr-privilege.md §7]
`define RV32GC_IMPLEMENT_ZICBOZ      0
// U 模式专用 CSR（ustatus 等）是否落地：见 §4.10 的版本敏感声明
`define RV32GC_IMPLEMENT_U_MODE_CSRS 0
// ---- 核内 MMIO 窗口（取指/访存译码共用；核内截获，绝不发 AXI） ----
//      每个窗口都给出「(mask,value)」二元组，比较形式统一为 ((PA & mask) == value)；
//      mask 的位宽 = 该处比较所用的地址位段宽（16 或 12）。
`define RV32GC_HIT_HI16_MSK   16'hFFFF     // PA[31:16] 全比较（窗口高 16 位）
`define RV32GC_CLINT_HIT_MSK  `RV32GC_HIT_HI16_MSK
`define RV32GC_CLINT_HIT_VAL  16'h1F00      // (PA[31:16] == 0x1F00) ⇒ 核内 CLINT
`define RV32GC_PLIC_HIT_VAL   16'h1F10      // (PA[31:16] == 0x1F10) ⇒ 核内 PLIC
// ---- 平台从设备窗口（同上口径，供 mmio_route/axi_req_desc 共用一份译码） ----
`define RV32GC_SPI_HIT_VAL    16'h1FE8      // (PA[31:16] == 0x1FE8) ⇒ SPI 别名窗口
`define RV32GC_APB_UART_VAL   16'h1FE0      // ⇒ UART
`define RV32GC_APB_NAND_VAL   16'h1FE7      // ⇒ NAND
`define RV32GC_CONF_SYN_VAL   16'h1FD0      // ⇒ confreg_syn（上板）
`define RV32GC_CONF_SIM_VAL   16'h1FAF      // ⇒ confreg_sim（仿真）
`define RV32GC_MAC_HIT_VAL    16'h1FF0      // ⇒ MAC（不用）
// ---- XIP 主窗口位段（`RV32GC_XIP_HI20_MSK` / `RV32GC_XIP_HI20_VAL` / `RV32GC_XIP_HI20`）----
//      ★ 已于 2026-09-14 迁出本文件：这组宏现在**唯一定义在 `rtl/pkg/core_params.vh` §2**，
//        以避免 core_params.vh 反向依赖 rv32_defs.vh（依赖方向固定为
//        `rv32_defs.vh → core_params.vh`，两者互不反向引用）。

`endif // RV32_DEFS_VH
