//==============================================================================
// rtl/decode/decoder.v —— D 级全译码表（RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格    : docs/design/08-baseline-5stage.md §5.2（D 级——译码）
// 覆盖集合: **RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom**（08 §1.1；core_params.vh §10
//           的 ISA 字符串 RV32IMAFDCZicsr_Zifencei_Zicntr_Zicbom）。
//           ★ 不支持 Zb*/Zk*/向量/其它扩展 ⇒ 一律 ill_instr（08 §5.2 行为要点①）。
//
// 结构（三段，全部纯组合）：
//   ① **C 展开**：insn[1:0]!=2'b11 ⇒ 经 compressed_expand 展成 32 位等效指令；
//      ill16=1（含全零 16 位）⇒ 直接 ill_instr。
//   ② **主线译码**：对（等效）32 位指令按 (opcode, funct3, funct7/funct5/fmt, rs2)
//      逐族比较，产生控制信号组。
//   ③ **CSR / cbo 子译码**：例化 dec_csr 做地址/权限/门控预判；立即数走 dec_imm。
//
// 关键口径（必须与真源一致，改动前先改 rtl/pkg/*.vh）：
//   * OP-FP 的 **fmt 在 insn[26:25]**（不是 funct7[1:0] 的独立编码），
//     funct5 在 insn[31:27]；F/D 由 fmt 区分。见 rv32_defs.vh §3.13 的「★ 注意」。
//   * AMO 家族的 **funct5 在 insn[31:27]**、aq/rl 在 insn[26:25]；
//     常量用 RV32GC_AMO_*（5 位）。见 rv32_defs.vh §3.8。
//   * Zicbom 的 **cbo.clean/flush/inval 靠 rs2 区分**（funct7 相同）——
//     **不得只看 funct7**。见 rv32_defs.vh §3.11 的「★ 关键」。
//   * **funct7/funct5 判别一律先限定主 opcode 家族**：同一 f7 值在不同族下语义不同
//     （典型：OP 的 sub 用 f7=0100000；而 OP-IMM 的 addi 其 imm[11:5] 恰好也落在
//     insn[31:25] ⇒ f7=0100000，跨族判据会把 imm∈[0x400,0x41F] 的 addi 误译成 sub）。
//     本文件的口径：每个 f7/funct5 判据都写成 `is_<族> & (f7 == ...)`（见 §4/§7）。
//   * 非法指令 ⇒ `ill_instr=1` 且 **tval_o = 原始指令位**（16 位压缩指令也右对齐、
//     高位清零）——口径 T1（本设计选择实现，右对齐、高位清零）。
//   * **写只读 CSR ⇒ 非法指令**（Zicsr）；`CSRRS/CSRRC` 且 rs1=x0 **不写** CSR。
//
// 风格纪律: AGENT.md §4 红线 3 + 08 §7.4 —— 译码表用 assign/function 表达，
//           **禁止**大 `always @(*)` 多 reg 赋值。本文件**不含任何 always 块**。
//
// 引用    : [ENC] riscv-gnu-toolchain/binutils/include/opcode/riscv-opc.h（MATCH/MASK）
//            [ISA] riscv-isa-manual/src/unpriv/*.adoc、src/priv/csrs.adoc
//            [DOC] docs/design/08-baseline-5stage.md §5.2/§6、docs/design/06-csr-privilege.md
//            [SRC] rtl/pkg/rv32_defs.vh（全部编码常量）、rtl/pkg/core_params.vh（参数）
//==============================================================================
`ifndef RV32GC_DECODER_V
`define RV32GC_DECODER_V

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module decoder (
    //==========================================================================
    // 输入
    //==========================================================================
    input  wire [31:0] insn_i,        // 取指到的**原始**指令（含 16 位压缩形态）
    input  wire [1:0]  priv_i,        // 当前特权级（**旁路后**有效值）
    input  wire [1:0]  menvcfg_cbie_i,
    input  wire        menvcfg_cbcfe_i,
    input  wire [1:0]  senvcfg_cbie_i,
    input  wire        senvcfg_cbcfe_i,
    //==========================================================================
    // 输出：指令基本形态
    //==========================================================================
    output wire [31:0] insn32_o,      // 译码所用指令（C 展开后的 32 位等效指令）
    output wire [31:0] tval_o,        // 非法指令时 = 原始指令位（T1；右对齐、高位清零）
    output wire        ill_instr_o,   // 非法指令（⇒ cause 2）
    output wire        is_compressed_o,// 原始指令为 16 位压缩形态
    output wire        is_hint_o,     // Zca HINT 编码（不改变架构状态）
    output wire        ctl_xfer_o,    // 本指令为控制转移（分支/跳转/jalr）
    //==========================================================================
    // 输出：操作数与寄存器号
    //==========================================================================
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,
    output wire [4:0]  rs3_o,         // FMA 族的 rs3（insn[31:27]）
    output wire [4:0]  rd_o,
    output wire [31:0] imm_o,         // 立即数（I/S/B/U/J 或 C 型；已符号/零扩展）
    //==========================================================================
    // 输出：控制信号组（D→E 接口契约；编码见本文件 §0 的 localparam）
    //==========================================================================
    output wire [3:0]  op_type_o,     // 执行部件类型（ALU/BRU/JUMP/LUI/AUIPC/…）
    output wire [3:0]  alu_op_o,      // ALU 微操作
    output wire [3:0]  mem_op_o,      // 访存操作（load/store/AMO/LRSC/cbo/fence）
    output wire [2:0]  mem_size_o,    // 访存宽度（1/2/4 B；AMO 恒 3'b010）
    output wire        mem_unsign_o,  // load 是否零扩展（lbu/lhu）
    output wire [2:0]  wb_sel_o,      // 写回来源选择
    output wire [2:0]  csr_op_o,      // CSR 操作（NONE/W/R/S/…）
    output wire [5:0]  fp_op_o,       // FP 操作（F/D 全部指令族）
    output wire        fp_we_o,       // 写浮点寄存器
    output wire        fp_ldst_o,     // 浮点 load/store（flw/fsw）
    output wire [2:0]  rm_o,          // 舍入模式（funct3；FMA 族同字段）
    output wire        rv32_is_amo_o, // 该指令为 AMO/LRSC 族
    //==========================================================================
    // 输出：CSR / Zicbom / fence 相关
    //==========================================================================
    output wire [11:0] csr_addr_o,    // insn[31:20]
    output wire        csr_ill_o,     // CSR 地址/权限/只读写 违规 ⇒ 非法
    output wire        csr_zimm_o,     // CSR 用 zimm（rs1 字段即 5 位立即数）
    output wire        cbo_valid_o,   // 这是一条 cbo.*
    output wire [4:0]  cbo_kind_o,    // 门控后的实际动作码（clean/flush/inval）
    output wire        cbo_gate_ill_o,// cbo 门控不满足 ⇒ 非法
    output wire        cbo_downgrade_o,// INVAL 被降级为 FLUSH
    output wire        fence_i_o,     // fence.i（Zifencei）
    output wire        fence_o,       // fence
    output wire        ebreak_o,      // ebreak（cause 3）
    output wire        ecall_o,       // ecall（cause 8/9/11 视 priv）
    output wire        mret_o,
    output wire        sret_o,
    output wire        wfi_o
);

    //==========================================================================
    // 0. D→E 接口枚举（本文件 localparam；D 级输出的**唯一编码定义处**）
    //    说明：这些是「核内控制信号」而非 ISA 编码，故不放入 rtl/pkg/*.vh
    //    （真源只收 ISA/平台位域）。E 级模块必须按本表解释这些端口。
    //==========================================================================
    // ---- op_type：执行部件类型 ----
    localparam [3:0] OPT_ALU   = 4'd0;  // 整数 ALU（含 lui/auipc 的常量生成）
    localparam [3:0] OPT_BRU   = 4'd1;  // 条件分支（beq..bgeu）
    localparam [3:0] OPT_JAL   = 4'd2;  // jal（J 型直接跳转）
    localparam [3:0] OPT_JALR  = 4'd3;  // jalr（寄存器间接跳转）
    localparam [3:0] OPT_LSU   = 4'd4;  // load/store
    localparam [3:0] OPT_AMO   = 4'd5;  // AMO 与 LR/SC
    localparam [3:0] OPT_MDU   = 4'd6;  // 乘除（M 扩展）
    localparam [3:0] OPT_CSR   = 4'd7;  // CSR 读写（Zicsr）
    localparam [3:0] OPT_SYS   = 4'd8;  // 特权指令（ecall/ebreak/xRET/wfi）
    localparam [3:0] OPT_FENCE = 4'd9;  // fence / fence.i
    localparam [3:0] OPT_CBO   = 4'd10; // cbo.clean/flush/inval（Zicbom）
    localparam [3:0] OPT_FP    = 4'd11; // 浮点计算
    localparam [3:0] OPT_FPLD  = 4'd12; // 浮点 load/store
    localparam [3:0] OPT_ILL   = 4'd15; // 非法（占位）

    // ---- alu_op：ALU 微操作 ----
    localparam [3:0] ALU_ADD  = 4'd0;
    localparam [3:0] ALU_SUB  = 4'd1;
    localparam [3:0] ALU_SLL  = 4'd2;
    localparam [3:0] ALU_SLT  = 4'd3;
    localparam [3:0] ALU_SLTU = 4'd4;
    localparam [3:0] ALU_XOR  = 4'd5;
    localparam [3:0] ALU_SRL  = 4'd6;
    localparam [3:0] ALU_SRA  = 4'd7;
    localparam [3:0] ALU_OR   = 4'd8;
    localparam [3:0] ALU_AND  = 4'd9;
    localparam [3:0] ALU_PASSB= 4'd10;  // 直接传 b（lui/auipc 的 U 型立即数）
    localparam [3:0] ALU_NONE = 4'd15;

    // ---- mem_op：访存类别 ----
    localparam [3:0] MEM_NONE   = 4'd0;
    localparam [3:0] MEM_LOAD   = 4'd1;
    localparam [3:0] MEM_STORE  = 4'd2;
    localparam [3:0] MEM_AMO    = 4'd3;   // amo*.w
    localparam [3:0] MEM_LR     = 4'd4;   // lr.w
    localparam [3:0] MEM_SC     = 4'd5;   // sc.w
    localparam [3:0] MEM_CBO    = 4'd6;   // cbo.*
    localparam [3:0] MEM_FLOAD  = 4'd7;   // flw/fld
    localparam [3:0] MEM_FSTORE = 4'd8;   // fsw/fsd

    // ---- wb_sel：写回来源 ----
    localparam [2:0] WB_NONE = 3'd0;
    localparam [2:0] WB_ALU  = 3'd1;
    localparam [2:0] WB_MEM  = 3'd2;
    localparam [2:0] WB_PC4  = 3'd3;  // jal/jalr 的链接值（pc+2 或 pc+4，由 E 级按指令长度定）
    localparam [2:0] WB_CSR  = 3'd4;  // CSR 旧值
    localparam [2:0] WB_FP   = 3'd5;  // 浮点结果转为整数（fmv.x.w / fclass / fcvt 出口）
    localparam [2:0] WB_MDU  = 3'd6;

    // ---- csr_op：CSR 操作 ----
    localparam [2:0] CSRN_NONE  = 3'd0;
    localparam [2:0] CSRN_W     = 3'd1;  // csrrw / csrrwi
    localparam [2:0] CSRN_S     = 3'd2;  // csrrs / csrrsi
    localparam [2:0] CSRN_C     = 3'd3;  // csrrc / csrrci
    localparam [2:0] CSRN_PRIV  = 3'd4;  // ecall/ebreak/xRET/wfi

    // ---- fp_op：浮点操作族（6 位）----
    localparam [5:0] FP_NONE = 6'd0;
    localparam [5:0] FP_ADD  = 6'd1;
    localparam [5:0] FP_SUB  = 6'd2;
    localparam [5:0] FP_MUL  = 6'd3;
    localparam [5:0] FP_DIV  = 6'd4;
    localparam [5:0] FP_SQRT = 6'd5;
    localparam [5:0] FP_SGNJ = 6'd6;
    localparam [5:0] FP_MIN  = 6'd7;
    localparam [5:0] FP_MAX  = 6'd8;
    localparam [5:0] FP_CVT  = 6'd9;
    localparam [5:0] FP_MV_X = 6'd10;  // fmv.x.w / fclass
    localparam [5:0] FP_MV_W = 6'd11;  // fmv.w.x
    localparam [5:0] FP_CMP  = 6'd12;  // fle/flt/feq
    localparam [5:0] FP_FMA  = 6'd13;  // fmadd/fmsub/fnmsub/fnmadd

    //==========================================================================
    // 1. C 展开：insn[1:0]!=11 ⇒ 16 位压缩指令
    //==========================================================================
    wire is_c16 = (insn_i[1:0] != 2'b11);
    wire [15:0] c_insn = insn_i[15:0];

    wire [31:0] c_insn32;
    wire        c_ill16;
    wire        c_hint;
    wire        c_ctl_xfer;

    compressed_expand u_cexp (
        .c_insn     (c_insn),
        .insn32_o   (c_insn32),
        .ill16_o    (c_ill16),
        .is_hint_o  (c_hint),
        .ctl_xfer_o (c_ctl_xfer)
    );

    // ---- 译码所用指令：压缩形态取展开结果，否则取原始 32 位 ----
    wire [31:0] insn = is_c16 ? c_insn32 : insn_i;

    //==========================================================================
    // 2. 字段提取
    //==========================================================================
    wire [6:0] opcode = insn[6:0];
    wire [2:0] f3     = insn[14:12];
    wire [6:0] f7     = insn[31:25];
    wire [4:0] rs1_f  = insn[19:15];
    wire [4:0] rs2_f  = insn[24:20];
    wire [4:0] rd_f   = insn[11:7];

    // ---- OP-FP：fmt = insn[26:25]，funct5 = insn[31:27] ----
    //      ★ 真源 §3.13「★ 注意」：禁止把 fmt 塞进 funct7 常量。
    wire [1:0] fp_fmt = insn[26:25];
    wire [4:0] fp_f5  = insn[31:27];
    // ---- AMO：funct5 = insn[31:27]，aq=insn[26]，rl=insn[25] ----
    wire [4:0] amo_f5 = insn[31:27];
    wire       amo_aq = insn[26];
    wire       amo_rl = insn[25];
    // ---- Zicbom：动作码 = rs2 域（insn[24:20]），funct7 必须为 0 ----
    wire [4:0] cbo_rs2 = insn[24:20];

    // ---- 是否为 RV32（fmt=S 的 F 指令）/D 指令（fmt=D）----
    wire fp_is_d = (fp_fmt == `RV32GC_FMT_D);

    //==========================================================================
    // 3. 按 opcode 分族识别
    //==========================================================================
    wire is_load    = (opcode == `RV32GC_OP_LOAD);
    wire is_store   = (opcode == `RV32GC_OP_STORE);
    wire is_opimm   = (opcode == `RV32GC_OP_IMM);
    wire is_op      = (opcode == `RV32GC_OP_OP);
    wire is_branch  = (opcode == `RV32GC_OP_BRANCH);
    wire is_jal     = (opcode == `RV32GC_OP_JAL);
    wire is_jalr    = (opcode == `RV32GC_OP_JALR);
    wire is_lui     = (opcode == `RV32GC_OP_LUI);
    wire is_auipc   = (opcode == `RV32GC_OP_AUIPC);
    wire is_amo     = (opcode == `RV32GC_OP_AMO);
    wire is_system  = (opcode == `RV32GC_OP_SYSTEM);
    wire is_miscmem = (opcode == `RV32GC_OP_MISC_MEM);
    wire is_loadfp  = (opcode == `RV32GC_OP_LOAD_FP);
    wire is_storefp = (opcode == `RV32GC_OP_STORE_FP);
    wire is_opfp    = (opcode == `RV32GC_OP_FP);
    wire is_fma     = (opcode == `RV32GC_OP_MADD)  | (opcode == `RV32GC_OP_MSUB) |
                      (opcode == `RV32GC_OP_NMSUB)| (opcode == `RV32GC_OP_NMADD);

    //==========================================================================
    // 4. 各族的合法性 + 控制信号
    //==========================================================================

    //--------------------------------------------------------------------------
    // 4.1 LOAD：f3 = 000/001/010/100/101（sb/sh/sw 之外全非法）
    //--------------------------------------------------------------------------
    wire ld_ok = (f3 == `RV32GC_F3_LB)  | (f3 == `RV32GC_F3_LH)  |
                 (f3 == `RV32GC_F3_LW)  | (f3 == `RV32GC_F3_LBU) |
                 (f3 == `RV32GC_F3_LHU);
    wire [2:0] ld_size = (f3 == `RV32GC_F3_LB || f3 == `RV32GC_F3_LBU) ? 3'd0 :
                         (f3 == `RV32GC_F3_LH || f3 == `RV32GC_F3_LHU) ? 3'd1 :
                                                                         3'd2;
    wire ld_unsign = (f3 == `RV32GC_F3_LBU) | (f3 == `RV32GC_F3_LHU);

    //--------------------------------------------------------------------------
    // 4.2 STORE：f3 = 000/001/010
    //--------------------------------------------------------------------------
    wire st_ok = (f3 == `RV32GC_F3_SB) | (f3 == `RV32GC_F3_SH) |
                 (f3 == `RV32GC_F3_SW);
    wire [2:0] st_size = (f3 == `RV32GC_F3_SB) ? 3'd0 :
                         (f3 == `RV32GC_F3_SH) ? 3'd1 : 3'd2;

    //--------------------------------------------------------------------------
    // 4.3 OP-IMM：addi/slti/sltiu/xori/ori/andi + slli/srli/srai
    //     ★ 移位类必须**同时**校验 funct7（RV32 的 shamt[5]=insn[25] 必须为 0 ⇒
    //       f7 = 0000000 或 0100000），否则 slli 的 insn[25]=1 是非法编码。
    //--------------------------------------------------------------------------
    wire opimm_arith = (f3 == `RV32GC_F3_ADDI)  | (f3 == `RV32GC_F3_SLTI) |
                       (f3 == `RV32GC_F3_SLTIU) | (f3 == `RV32GC_F3_XORI) |
                       (f3 == `RV32GC_F3_ORI)   | (f3 == `RV32GC_F3_ANDI);
    wire opimm_slli_ok = (f3 == `RV32GC_F3_SLLI) && (f7 == `RV32GC_F7_SRLI);
    wire opimm_srxi_ok = (f3 == `RV32GC_F3_SRLI_SRAI) &&
                         ((f7 == `RV32GC_F7_SRLI) || (f7 == `RV32GC_F7_SRAI));
    wire opimm_ok = opimm_arith | opimm_slli_ok | opimm_srxi_ok;

    //--------------------------------------------------------------------------
    // 4.4 OP：RV32I 整数 + M 扩展
    //--------------------------------------------------------------------------
    wire op_i_base = (f7 == `RV32GC_F7_OP_BASE) | (f7 == `RV32GC_F7_OP_ALT);
    //   base f7 下 f3=000 是 add/sub（由 f7 区分），000..111 全部合法；
    //   alt f7（0100000）下只有 f3=000（sub）与 f3=101（sra）合法。
    wire op_i_ok = (f7 == `RV32GC_F7_OP_BASE) ?
                      1'b1 :
                   (f7 == `RV32GC_F7_OP_ALT) ?
                      ((f3 == `RV32GC_F3_ADD_SUB) || (f3 == `RV32GC_F3_SRL_SRA)) :
                      1'b0;
    //   M 扩展：f7=0000001，f3=000..111 全部合法
    wire op_m_ok = (f7 == `RV32GC_F7_MULDIV);
    wire op_ok   = op_i_ok | op_m_ok;

    //--------------------------------------------------------------------------
    // 4.5 BRANCH：f3 = 000/001/100/101/110/111（010/011 非法）
    //--------------------------------------------------------------------------
    wire br_ok = (f3 == `RV32GC_F3_BEQ)  | (f3 == `RV32GC_F3_BNE)  |
                 (f3 == `RV32GC_F3_BLT)  | (f3 == `RV32GC_F3_BGE)  |
                 (f3 == `RV32GC_F3_BLTU) | (f3 == `RV32GC_F3_BGEU);

    //--------------------------------------------------------------------------
    // 4.6 JAL / JALR / LUI / AUIPC
    //--------------------------------------------------------------------------
    //   JAL：f3 必须为 000（其它为保留）
    wire jal_ok  = (f3 == `RV32GC_F3_ADDI);
    //   JALR：f3 必须为 000（其它为保留）
    wire jalr_ok = (f3 == `RV32GC_F3_ADDI);

    //--------------------------------------------------------------------------
    // 4.7 AMO（A 扩展）：f3=010，funct5∈{00000,00001,00010(LR),00011(SC),00100,
    //     01000,01100,10000,10100,11000,11100}
    //     ★ funct5 在 insn[31:27]；LR.W 要求 rs2=00000。
    //--------------------------------------------------------------------------
    wire amo_f3_ok = (f3 == `RV32GC_F3_AMO);
    wire amo_is_lr = (amo_f5 == `RV32GC_AMO_LR);
    wire amo_is_sc = (amo_f5 == `RV32GC_AMO_SC);
    wire amo_act_ok = (amo_f5 == `RV32GC_AMO_ADD)  | (amo_f5 == `RV32GC_AMO_SWAP) |
                      (amo_f5 == `RV32GC_AMO_LR)   | (amo_f5 == `RV32GC_AMO_SC)   |
                      (amo_f5 == `RV32GC_AMO_XOR)  | (amo_f5 == `RV32GC_AMO_OR)   |
                      (amo_f5 == `RV32GC_AMO_AND)  | (amo_f5 == `RV32GC_AMO_MIN)  |
                      (amo_f5 == `RV32GC_AMO_MAX)  | (amo_f5 == `RV32GC_AMO_MINU) |
                      (amo_f5 == `RV32GC_AMO_MAXU);
    //   LR.W 的 rs2 必须为 0（[ENC:LR_W=0x1000202f]）；SC/其它 AMO 无此约束
    wire amo_ok = amo_f3_ok & amo_act_ok & (amo_is_lr ? (rs2_f == 5'd0) : 1'b1);

    //--------------------------------------------------------------------------
    // 4.8 MISC-MEM：fence（f3=000）与 cbo.*（f3=010）；fence.i 由 SYSTEM? 否——
    //     fence.i 属 MISC-MEM 的 f3=001（Zifencei）
    //--------------------------------------------------------------------------
    wire is_fence   = is_miscmem && (f3 == `RV32GC_F3_FENCE);
    wire is_fence_i = is_miscmem && (f3 == `RV32GC_F3_FENCE_I);
    //   cbo.*：opcode=MISC-MEM、f3=010、f7=0000000、rs2 ∈ {inval,clean,flush}
    //     ★ **不得只看 funct7**：clean/flush 的 funct7 相同，靠 rs2 区分（真源 §3.11）
    wire is_cbo_enc = is_miscmem && (f3 == `RV32GC_F3_CBO) && (f7 == `RV32GC_F7_CBO);
    wire cbo_known_act = (cbo_rs2 == `RV32GC_CBO_INVAL) |
                         (cbo_rs2 == `RV32GC_CBO_CLEAN) |
                         (cbo_rs2 == `RV32GC_CBO_FLUSH);
    //   2A **不实现 Zicboz**：cbo.zero（rs2=00100）⇒ 非法（core_params.vh §10
    //     RV32GC_IMPLEMENTS_ZICBOZ=0；rv32_defs.vh §3.11 明确禁止启用）
    wire is_cbo = is_cbo_enc & cbo_known_act;
    //   fence.i 的合法编码要求 rs1/rd 域为 0（[ENC:FENCE_I=0x100f MASK=0x707f]
    //     仅约束 opcode+f3；ISA 未强制 rs1/rd 为 0，但 rd/rs1 非 0 属保留 ⇒ 本设计
    //     按「f3=001 即在范围内」处理，不做额外约束，交由 E/M 级忽略其字段。

    //--------------------------------------------------------------------------
    // 4.9 SYSTEM：CSR 三条（f3=001/010/011/101/110/111）与特权指令（f3=000）
    //--------------------------------------------------------------------------
    wire is_csr_rw   = is_system && (f3 == `RV32GC_F3_CSRRW);
    wire is_csr_rs   = is_system && (f3 == `RV32GC_F3_CSRRS);
    wire is_csr_rc   = is_system && (f3 == `RV32GC_F3_CSRRC);
    wire is_csr_rwi  = is_system && (f3 == `RV32GC_F3_CSRRWI);
    wire is_csr_rsi  = is_system && (f3 == `RV32GC_F3_CSRRSI);
    wire is_csr_rci  = is_system && (f3 == `RV32GC_F3_CSRRCI);
    wire is_csr_any  = is_csr_rw  | is_csr_rs  | is_csr_rc |
                       is_csr_rwi | is_csr_rsi | is_csr_rci;
    // ---- 立即数形式（rs1 域即 5 位 zimm）----
    wire csr_zimm = is_csr_rwi | is_csr_rsi | is_csr_rci;

    // ---- 该 CSR 指令**是否会写**目标 CSR ----
    //   Zicsr 语义：CSRRW/CSRRWI 恒写；CSRRS/CSRRC/CSRRSI/CSRRCI 仅当
    //   源操作数（rs1 或 zimm）**非零**时才写。写只读 CSR 且**会写** ⇒ 非法指令。
    wire csr_src_nz = csr_zimm ? (rs1_f != 5'd0) : (rs1_f != 5'd0);
    wire csr_will_wr = is_csr_rw | is_csr_rwi |
                       ((is_csr_rs  | is_csr_rc  | is_csr_rsi | is_csr_rci) & csr_src_nz);

    // ---- 特权指令（f3=000）：完整 32 位 MATCH 比较（真源 §3.9 给出全零域 MATCH 值）----
    wire is_ecall  = (insn == `RV32GC_INSN_ECALL);
    wire is_ebreak = (insn == `RV32GC_INSN_EBREAK);
    wire is_uret   = (insn == `RV32GC_INSN_URET);
    wire is_sret   = (insn == `RV32GC_INSN_SRET);
    wire is_mret   = (insn == `RV32GC_INSN_MRET);
    wire is_wfi    = (insn == `RV32GC_INSN_WFI);
    wire sys_priv_ok = is_ecall | is_ebreak | is_uret | is_sret | is_mret | is_wfi;
    //   ★ 本设计 2A 不实现 U 模式返回（uret 属 N 扩展/U 模式陷阱处理，2A 不落地
    //     U 模式 CSR ⇒ 与 08 §6.2 裁决一致）⇒ uret 按非法指令处理。
    wire sys_priv_impl = is_ecall | is_ebreak | is_sret | is_mret | is_wfi;

    //--------------------------------------------------------------------------
    // 4.10 LOAD-FP / STORE-FP：flw/fld（f3=010/011）、fsw/fsd（f3=010/011）
    //--------------------------------------------------------------------------
    wire flw_ok = is_loadfp  && ((f3 == `RV32GC_F3_FLW) || (f3 == `RV32GC_F3_FLD));
    wire fsw_ok = is_storefp && ((f3 == `RV32GC_F3_FSW) || (f3 == `RV32GC_F3_FSD));

    //--------------------------------------------------------------------------
    // 4.11 OP-FP：按 (funct5, fmt, funct3) 逐族判定
    //      ★ fmt 在 insn[26:25]、funct5 在 insn[31:27]（真源 §3.13）
    //      ★ fmt 必须 ∈ {S(00), D(01)}；RV32 下 fmt=10/11 为保留 ⇒ 非法
    //--------------------------------------------------------------------------
    wire fmt_ok = (fp_fmt == `RV32GC_FMT_S) || (fp_fmt == `RV32GC_FMT_D);

    // fadd/fsub/fmul/fdiv/fsqrt：f3 = rm（任意，2A 接受全部 rm 编码）
    wire fp_arith5_ok = (fp_f5 == `RV32GC_FP_F5_FADD) |
                        (fp_f5 == `RV32GC_FP_F5_FSUB) |
                        (fp_f5 == `RV32GC_FP_F5_FMUL) |
                        (fp_f5 == `RV32GC_FP_F5_FDIV) |
                        (fp_f5 == `RV32GC_FP_F5_FSQRT);
    // fsgnj/fsgnjn/fsgnjx：f3 = 000/001/010
    wire fp_sgnj_f3_ok = (f3 == `RV32GC_FP_F3_FSGNJ)  |
                         (f3 == `RV32GC_FP_F3_FSGNJN) |
                         (f3 == `RV32GC_FP_F3_FSGNJX);
    // fmin/fmax：f3 = 000/001
    wire fp_minmax_f3_ok = (f3 == `RV32GC_FP_F3_FMIN) | (f3 == `RV32GC_FP_F3_FMAX);
    // fcvt：**三个 funct5** 覆盖全部转换方向（真源 §3.13 的转换矩阵；
    //   已用 binutils MATCH 值逐条解码核实，riscv-opc.h:346-458）：
    //     funct5=01000（`RV32GC_FP_F5_FCVT`）：F↔D 互转（FCVT_S_D=0x40100053
    //         fmt=S rs2=00001；FCVT_D_S=0x42000053 fmt=D rs2=00000）
    //     funct5=11000（FCVT_W_S=0xc0000053 等）：**出口**，写**整数**；fmt=源精度，
    //         rs2[0]=0 ⇒ W、=1 ⇒ WU
    //     funct5=11010（FCVT_S_W=0xd0000053 等）：**入口**，写 **FP**；fmt=目标精度，
    //         rs2[0]=0 ⇒ W、=1 ⇒ WU
    //   ⇒ 本设计按上述三组识别；rs2[4:2] 必须为 0（其余编码保留）。
    //
    //   历史沿革（绕行已回收）：
    //     真源 rtl/pkg/rv32_defs.vh:212 的 `RV32GC_FP_F5_FCVT` 原写作 `('h8 >> 3)`，
    //     注释声称 5'b01000 但实际求值为 5'b00001（0x8>>3=1），会使
    //     fcvt.s.d(0x401574d3)/fcvt.d.s(0x420605d3) 被误判为非法指令。
    //     **真源已于 2026-09-14 修复为 `5'b01000`，且 sim/unit/pkg_check.v 已补
    //     取值断言**（pkg_check.v:358）。此处原先的 localparam 绕行已回收，
    //     现**直接使用真源宏** `` `RV32GC_FP_F5_FCVT ``，不再保留任何本地副本。
    localparam [4:0] FP_F5_FCVT_OUT = 5'b11000;   // 写整数（出口）
    localparam [4:0] FP_F5_FCVT_IN  = 5'b11010;   // 写 FP（入口）
    wire fp_cvt_rs2_ok  = (rs2_f[4:2] == 3'b000);
    wire fp_cvt_f5_fd   = (fp_f5 == `RV32GC_FP_F5_FCVT);   // F↔D（真源宏，2026-09-14 修复）
    wire fp_cvt_f5_out  = (fp_f5 == FP_F5_FCVT_OUT);  // → 整数
    wire fp_cvt_f5_in   = (fp_f5 == FP_F5_FCVT_IN);   // → FP
    wire fp_cvt_any_ok  = (fp_cvt_f5_fd | fp_cvt_f5_out | fp_cvt_f5_in) &
                          fp_cvt_rs2_ok;
    //   F↔D 互转：rs2 表示源精度（S=0/D=1），目标精度由 fmt 给出
    wire fp_cvt_fd_ok   = fp_cvt_f5_fd & fp_cvt_rs2_ok & (rs2_f[1:0] <= 2'b01);
    // fmv.x.w/fclass：funct5=11100，f3 = 001（fmt 位选择 S/D 视图）
    wire fp_mvx_f5_ok  = (fp_f5 == `RV32GC_FP_F5_FMV_CMP);
    // fmv.w.x：funct5=11110
    wire fp_mvw_f5_ok  = (fp_f5 == `RV32GC_FP_F5_FMV_W_X);
    // feq/flt/fle（fmv.x.w/fclass 的 fmt=? 二者 funct5 相同，靠 fmt 区分 S/D）
    //   ★ 依据真源：FCMP 的 funct5=10100；MV_X_W/CLASS 的 funct5=11100
    wire fp_cmp_f5_ok  = (fp_f5 == `RV32GC_FP_F5_FCMP);
    wire fp_cmp_f3_ok  = (f3 == `RV32GC_FP_F3_FLE) | (f3 == `RV32GC_FP_F3_FLT) |
                         (f3 == `RV32GC_FP_F3_FEQ);
    // fmv.x.w/fclass 的 f3：fclass=001，fmv.x.w=000（真源 §3.13 把 f3=001 记为
    //   FCLASS；fmv.x.w 实际为 f3=000，见 [ENC:FMV_X_W=0xe0000053]）
    wire fp_mvx_f3_ok  = (f3 == 3'b000) | (f3 == `RV32GC_FP_F3_FCLASS);

    wire fp_ok = fmt_ok & (
                    fp_arith5_ok |
                    ((fp_f5 == `RV32GC_FP_F5_FSGNJ)  & fp_sgnj_f3_ok)  |
                    ((fp_f5 == `RV32GC_FP_F5_FMINMAX) & fp_minmax_f3_ok) |
                    fp_cvt_any_ok |
                    (fp_mvx_f5_ok & fp_mvx_f3_ok) |
                    fp_mvw_f5_ok |
                    (fp_cmp_f5_ok & fp_cmp_f3_ok)
                 );

    //--------------------------------------------------------------------------
    // 4.12 FMA 族：funct3 = rm；funct5 由 opcode 决定；fmt = insn[26:25]
    //--------------------------------------------------------------------------
    wire fma_ok = is_fma & fmt_ok;

    //==========================================================================
    // 5. 非法指令汇总（任何未覆盖的编码 ⇒ ill）
    //==========================================================================
    // ---- 各族的「编码合法」谓词（与 opcode 一一对应）----
    wire fam_ok =
        (is_load    & ld_ok)    |
        (is_store   & st_ok)    |
        (is_opimm   & opimm_ok) |
        (is_op      & op_ok)    |
        (is_branch  & br_ok)    |
        (is_jal     & jal_ok)   |
        (is_jalr    & jalr_ok)  |
        (is_lui)                |          // LUI：f3 忽略
        (is_auipc)              |          // AUIPC：f3 忽略
        (is_amo     & amo_ok)   |
        (is_system  & (is_csr_any | sys_priv_impl)) |
        (is_miscmem & (is_fence | is_fence_i | is_cbo)) |
        (is_loadfp  & flw_ok)   |
        (is_storefp & fsw_ok)   |
        (is_opfp    & fp_ok)    |
        (is_fma     & fma_ok);

    // ---- 未被任何已知 opcode 命中 ⇒ 该 opcode 不在 2A 集合内 ----
    wire opcode_known = is_load | is_store | is_opimm | is_op | is_branch | is_jal |
                        is_jalr | is_lui | is_auipc | is_amo | is_system |
                        is_miscmem | is_loadfp | is_storefp | is_opfp | is_fma;

    // ---- CSR 子译码（地址/权限/只读写）----
    wire csr_exists, csr_ill_sub, cbo_gate_ill, cbo_downgrade;
    wire [4:0] cbo_kind;
    wire [11:0] csr_addr = insn[31:20];

    dec_csr u_dcsr (
        .csr_addr          (csr_addr),
        .priv              (priv_i),
        .is_csr_wr        (csr_will_wr),
        .menvcfg_cbie      (menvcfg_cbie_i),
        .menvcfg_cbcfe     (menvcfg_cbcfe_i),
        .senvcfg_cbie      (senvcfg_cbie_i),
        .senvcfg_cbcfe     (senvcfg_cbcfe_i),
        .cbo_valid         (is_cbo),
        .cbo_rs2           (cbo_rs2),
        .csr_exists_o      (csr_exists),
        .csr_ill_o         (csr_ill_sub),
        .cbo_gate_ill_o    (cbo_gate_ill),
        .cbo_downgrade_o   (cbo_downgrade),
        .cbo_kind_o        (cbo_kind)
    );

    // ---- 指令级非法：编码未覆盖 / CSR 违规 / C 展开失败 / cbo 门控不满足 ----
    wire fam_ok_gated = fam_ok &
                        (is_csr_any ? ~csr_ill_sub : 1'b1) &
                        (is_cbo     ? ~cbo_gate_ill : 1'b1);

    assign ill_instr_o = (is_c16 & c_ill16) | ~opcode_known | ~fam_ok_gated;

    //==========================================================================
    // 6. 立即数（例化 dec_imm；sel 由本层的型别判定给出）
    //==========================================================================
    wire sel_i = (is_load | is_jalr | (is_opimm & ~opimm_slli_ok & ~opimm_srxi_ok) |
                  is_csr_any) |
                 // C 展开后的等效 lw/addi/jalr 已在对应 opcode 上，无需单独处理
                 1'b0;
    wire sel_s = is_store;
    wire sel_b = is_branch;
    wire sel_u = is_lui | is_auipc;
    wire sel_j = is_jal;
    wire sel_ishift = (is_opimm & (opimm_slli_ok | opimm_srxi_ok));

    wire [31:0] imm;
    dec_imm u_dimm (
        .insn      (insn),
        .sel_i     (sel_i),
        .sel_s     (sel_s),
        .sel_b     (sel_b),
        .sel_u     (sel_u),
        .sel_j     (sel_j),
        .sel_ishift(sel_ishift),
        .imm_o     (imm)
    );

    //==========================================================================
    // 7. 控制信号生成（assign；按族的优先级选择）
    //==========================================================================
    // ---- 注意：以下选择链的优先级只在「多族同时命中」的非法/异常输入下才有定义，
    //      正常译码时恰好一族命中。为避免优先级掩盖非法判定，ill_instr_o 已独立
    //      由 fam_ok/opcode_known 判定，与此处的控制信号无关。

    assign op_type_o =
        ill_instr_o    ? OPT_ILL :
        is_load        ? OPT_LSU :
        is_store       ? OPT_LSU :
        is_loadfp      ? OPT_FPLD :
        is_storefp     ? OPT_FPLD :
        is_amo         ? OPT_AMO :
        is_branch      ? OPT_BRU :
        is_jal         ? OPT_JAL :
        is_jalr        ? OPT_JALR :
        is_lui         ? OPT_ALU :
        is_auipc       ? OPT_ALU :
        is_opimm       ? OPT_ALU :
        (is_op & op_m_ok) ? OPT_MDU :
        is_op          ? OPT_ALU :
        is_csr_any     ? OPT_CSR :
        (is_system & sys_priv_impl) ? OPT_SYS :
        is_fence       ? OPT_FENCE :
        is_fence_i     ? OPT_FENCE :
        is_cbo         ? OPT_CBO :
        (is_opfp | is_fma) ? OPT_FP :
                           OPT_ILL;

    // ---- ALU 微操作 ----
    assign alu_op_o =
        ill_instr_o ? ALU_NONE :
        // OP-IMM / OP / LUI / AUIPC 的算术
        ((is_lui)              ? ALU_PASSB :  // lui：结果 = imm（U 型已 <<12）
        (is_auipc)             ? ALU_ADD   :  // auipc：pc + imm（b 端由 E 级给 imm）
        (is_op | is_opimm)     ? (
            // 移位类：由 f3 区分
            (f3 == `RV32GC_F3_SLLI || f3 == `RV32GC_F3_SLL) ? ALU_SLL :
            (f3 == `RV32GC_F3_SRLI_SRAI || f3 == `RV32GC_F3_SRL_SRA) ? (
                // ★ **必须分域**：OP-IMM 的 srai 用 F7_SRAI、OP 的 sra 用 F7_OP_ALT。
                //   两者数值同为 7'b0100000，但判据各自只在其主 opcode 家族内有效；
                //   不得写成「f7 命中任一常量即 SRA」的跨族判据（见下 add/sub 的同族缺陷）。
                ((is_opimm & (f7 == `RV32GC_F7_SRAI)) |
                 (is_op    & (f7 == `RV32GC_F7_OP_ALT))) ? ALU_SRA :
                                                           ALU_SRL
            ) :
            (f3 == `RV32GC_F3_ADD_SUB) ? (
                // sub 只在 **OP**（f3=000 且 f7=0100000）成立；OP-IMM 的 addi 恒 ADD。
                //   ★ 禁止只看 f7：addi 的 imm[11:5] 就是 insn[31:25]（=f7 域），
                //     imm ∈ [0x400,0x41F] ⇒ f7=0100000 ⇒ 旧代码误判为 sub
                //     （2026-09-15 修复；穷举扫描 16384 例仅此 1 处跨族误判）。
                (is_op & (f7 == `RV32GC_F7_OP_ALT)) ? ALU_SUB : ALU_ADD
            ) :
            (f3 == `RV32GC_F3_SLTI)  ? ALU_SLT  :
            (f3 == `RV32GC_F3_SLTIU) ? ALU_SLTU :
            (f3 == `RV32GC_F3_XORI || f3 == `RV32GC_F3_XOR) ? ALU_XOR :
            (f3 == `RV32GC_F3_ORI  || f3 == `RV32GC_F3_OR)  ? ALU_OR  :
            (f3 == `RV32GC_F3_ANDI || f3 == `RV32GC_F3_AND) ? ALU_AND :
                                                              ALU_NONE
        ) :
        // jal/jalr/branch 的地址计算（加）由 BRU/JUMP 部件处理，ALU 不参与
        (is_jal | is_jalr | is_branch) ? ALU_ADD :
        (is_load | is_store | is_amo | is_loadfp | is_storefp | is_cbo) ? ALU_ADD :
                                          ALU_NONE);

    // ---- 访存类别 ----
    assign mem_op_o =
        (is_load)    ? MEM_LOAD  :
        (is_store)   ? MEM_STORE :
        (is_loadfp)  ? MEM_FLOAD :
        (is_storefp) ? MEM_FSTORE:
        (is_amo & amo_is_lr) ? MEM_LR :
        (is_amo & amo_is_sc) ? MEM_SC :
        (is_amo)     ? MEM_AMO   :
        (is_cbo)     ? MEM_CBO   :
                       MEM_NONE;

    assign mem_size_o =
        (is_load)   ? ld_size :
        (is_store)  ? st_size :
        (is_loadfp | is_storefp) ? (f3 == `RV32GC_F3_FLW ? 3'd2 : 3'd3) : // flw=4B, fld=8B
        (is_amo)    ? 3'd2 :   // AMO 恒 4 B（RV32A 只有 .W）
                     3'd0;
    assign mem_unsign_o = ld_unsign;

    // ---- FP 出口/入口判定（**先算成 wire，供 wb_sel 与 fp_we 共用**）----
    //   出口（写**整数**寄存器 rd 的 FP 指令）：
    //     * fmv.x.w：funct5=11100、f3=000
    //     * fclass ：funct5=11100、f3=001
    //     * fcvt.*.w / fcvt.*.wu（把 FP 转成整数）：funct5=01000，
    //       **rs2[1]=1 表示"出口"**（真源 §3.13 转换矩阵：
    //         FCVT_W_S =0xc0000053 ⇒ funct5=11000（w 出口，写整数）
    //         FCVT_S_W =0xd0000053 ⇒ funct5=11010（w 入口，写 FP）
    //       注意：fcvt 的**入口/出口由 funct5 的 bit0 与 rs2 共同表达**，
    //       本设计按真源「出口口径（写整数）：源 fmt 由 insn[26:25] 给出」实现，
    //       并用 rs2[1] 区分出口/入口（rs2[1]=1 ⇒ 出口）。)
    //   入口（写 **FP** 寄存器）：fcvt.w.s 之外的全部 fcvt 方向 + 其余 FP 计算。
    wire fp_is_fmvx  = is_opfp & (fp_f5 == `RV32GC_FP_F5_FMV_CMP) & fp_mvx_f3_ok;
    wire fp_is_fcmp  = is_opfp & (fp_f5 == `RV32GC_FP_F5_FCMP);
    //   fcvt 出口：funct5=01000 且 rs2[1]=1（见上；rs2[0] 选 W/WU）
    //   出口 = funct5=11000（写整数）；入口 = funct5=11010（写 FP）
    wire fp_is_cvt_out = is_opfp & fp_cvt_f5_out & fp_cvt_rs2_ok;
    //   写整数寄存器（FP → 整数）：fmv.x.w / fclass / fcmp / fcvt 出口
    wire fp_to_int = fp_is_fmvx | fp_is_fcmp | fp_is_cvt_out;

    // ---- 写回来源 ----
    assign wb_sel_o =
        (is_load)    ? WB_MEM :
        (is_loadfp)  ? WB_NONE :      // 写 FP 寄存器堆，不走整数写回
        (is_amo)     ? WB_MEM :       // AMO/LR/SC 结果写回（按 AMO 语义）
        (is_jal | is_jalr)    ? WB_PC4 :
        (is_csr_any)          ? WB_CSR :
        fp_to_int             ? WB_FP  :
        (is_op & op_m_ok)     ? WB_MDU :
        (is_system)           ? WB_NONE :
        (is_fence | is_fence_i | is_cbo | is_store | is_storefp | is_branch) ? WB_NONE :
                                 WB_ALU;

    // ---- CSR 操作 ----
    assign csr_op_o =
        (is_csr_rw  | is_csr_rwi) ? CSRN_W :
        (is_csr_rs  | is_csr_rsi) ? CSRN_S :
        (is_csr_rc  | is_csr_rci) ? CSRN_C :
        (is_system & sys_priv_impl) ? CSRN_PRIV :
                                     CSRN_NONE;
    assign csr_addr_o = csr_addr;
    assign csr_ill_o  = is_csr_any & csr_ill_sub;
    assign csr_zimm_o = csr_zimm;

    // ---- Zicbom ----
    assign cbo_valid_o     = is_cbo;
    assign cbo_kind_o      = cbo_kind;
    assign cbo_gate_ill_o  = cbo_gate_ill;
    assign cbo_downgrade_o = cbo_downgrade;

    // ---- fence / 特权指令 ----
    assign fence_o   = is_fence;
    assign fence_i_o = is_fence_i;
    assign ebreak_o  = is_ebreak;
    assign ecall_o   = is_ecall;
    assign mret_o    = is_mret;
    assign sret_o    = is_sret;
    assign wfi_o     = is_wfi;

    // ---- 浮点 ----
    assign rm_o     = f3;   // OP-FP 与 FMA 族：rm 均在 funct3
    assign fp_ldst_o= is_loadfp | is_storefp;
    assign fp_op_o  =
        (is_fma) ? FP_FMA :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FADD)   ? FP_ADD :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FSUB)   ? FP_SUB :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FMUL)   ? FP_MUL :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FDIV)   ? FP_DIV :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FSQRT)  ? FP_SQRT :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FSGNJ)  ? FP_SGNJ :
        (is_opfp & fp_f5 == `RV32GC_FP_F5_FMINMAX) ? (f3 == `RV32GC_FP_F3_FMIN ? FP_MIN : FP_MAX) :
        (is_opfp & fp_cvt_any_ok)                 ? FP_CVT :
        (is_opfp & fp_mvx_f5_ok)                  ? FP_MV_X :
        (is_opfp & fp_mvw_f5_ok)                  ? FP_MV_W :
        (is_opfp & fp_cmp_f5_ok)                  ? FP_CMP :
                                                    FP_NONE;
    // ---- 写 FP 寄存器：写 FP 的浮点计算（含 FMA）与 flw（load-FP）；
    //      **出口**（fmv.x.w/fclass/fcmp/fcvt 出口）写整数，不写 FP ----
    assign fp_we_o = is_loadfp | ((is_opfp | is_fma) & ~fp_to_int);

    assign rv32_is_amo_o = is_amo;

    //==========================================================================
    // 8. 操作数与原始指令位
    //==========================================================================
    assign rs1_o = rs1_f;
    assign rs2_o = rs2_f;
    // FMA 族的 rs3 在 insn[31:27]；其它指令该域无 rs3 语义
    assign rs3_o = is_fma ? insn[31:27] : 5'd0;
    assign rd_o  = rd_f;
    assign imm_o = imm;

    assign insn32_o        = insn;
    assign is_compressed_o = is_c16;
    assign is_hint_o       = is_c16 & c_hint;
    // 控制转移：分支/跳转/jalr（C 展开后的 ctl_xfer 与本层判定取或）
    assign ctl_xfer_o = is_branch | is_jal | is_jalr | (is_c16 & c_ctl_xfer);

    //==========================================================================
    // 9. tval 口径（T1）：非法指令 ⇒ 写**原始指令位**，右对齐、高位清零。
    //    ★ 16 位压缩指令写其 16 位编码（高位清零）；32 位写 32 位。
    //      [ISA:machine.adoc:2039-2053；DOC:docs/kb/isa-notes.md T1]
    //==========================================================================
    assign tval_o = is_c16 ? {16'b0, c_insn} : insn_i;

endmodule

`endif // RV32GC_DECODER_V
