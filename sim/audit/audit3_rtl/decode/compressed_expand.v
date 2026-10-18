//==============================================================================
// rtl/decode/compressed_expand.v —— RVC（Zca, RV32C）16 位 → 32 位等效指令展开
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格    : docs/design/08-baseline-5stage.md §5.2 行为要点⑤
//           「C 展开：把 16 位压缩指令展开为 32 位等效指令后再走主线译码
//             （口径统一、便于 2B 复用）」
// 作用    : 输入一条 16 位压缩指令（及配置位），输出**等效 32 位指令**；
//           若该编码为保留/非法，则置 ill16=1 并**原样传递** 16 位编码位
//           （供 mtval 口径 T1：写 faulting instruction bits）。
//
// 关键设计口径（与 08 §5.2 / zca.adoc 一致）：
//   1. **统一展开路径**：所有 C 指令（含 c.nop / c.ebreak）都展开成 32 位再译码，
//      主线译码表因此只需覆盖 32 位编码空间（避免两套译码表口径漂移）。
//   2. **链接地址口径**：c.jal / c.jalr 的链接值为 **pc+2**，而基准 ISA 的
//      jal/jalr 链接值为 pc+4。本模块**只做编码展开**（产出 jal/jalr 编码），
//      链接值差异由 E 级的 pc 计算按「本指令长度」处理（见下「本模块不改写」）。
//      为避免歧义：本模块**不**在展开结果里编码 "pc+2" —— 32 位 jal/jalr 的
//      rd=x1 语义由 E 级用**取指到的原始指令长度**决定。此点在文件中显式声明。
//   3. **rs1/rd 隐式零检查**：c.lwsp/c.swsp/c.addi16sp 的 x2 基址、c.jr/c.jalr 的 x0
//      等隐式寄存器在展开时**写入等效指令的 rs1/rd 字段**，不依赖调用方补充。
//   4. **合法性**：保留编码（含全零 16 位、c.lui 的 imm=0、c.addi4spn 的 nzuimm=0、
//      c.lwsp 的 rd=x0、c.jr/c.jalr 的 rs1=x0 等）⇒ ill16=1；HINT 编码按规范
//      「不改变架构状态」处理：展开为等效指令并置 is_hint=1（由 D 级照常执行，
//      HINT 的 rd=x0 自然不写寄存器）。
//
// 风格纪律: AGENT.md §4 红线 3 + 08 §7.4 —— 纯 assign/function 组合逻辑，
//           本文件**不含任何 always 块**。
//
// 编码真源（可复核）：
//   [ISA] riscv-isa-manual/src/unpriv/zca.adoc（各指令语义与合法性、寄存器映射）
//   [ENC] riscv-gnu-toolchain/binutils/include/opcode/riscv-opc.h:660-745
//         （MATCH_*/MASK_C_* —— 本文件的 match 常量注释给出对应值）
//   立即数位拼接复用 dec_imm.v 的 function（唯一实现处，避免重复推导）。
//
// 寄存器映射（zca.adoc「Registers specified by the three-bit rs1'/rs2'/rd' fields」）：
//   rv[2:0] = 000..111  ⇒  x8,x9,x10,x11,x12,x13,x14,x15
//   ⇒ 实际寄存器号 = 8 + rv[2:0]
//==============================================================================
`ifndef RV32GC_COMPRESSED_EXPAND_V
`define RV32GC_COMPRESSED_EXPAND_V

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module compressed_expand (
    // ---- 输入：16 位压缩指令 ----
    input  wire [15:0] c_insn,
    // ---- 输出：32 位等效指令（ill16=1 时无意义，调用方应改用 c_insn 作 tval）----
    output wire [31:0] insn32_o,
    // ---- 是否可展开（0 ⇒ 保留/非法编码）----
    output wire        ill16_o,
    // ---- 是否为 HINT 编码（不改变架构状态；照常展开执行）----
    output wire        is_hint_o,
    // ---- 展开出的指令是否为控制转移（供 E 级按 pc+2 计算链接值）----
    output wire        ctl_xfer_o
);

    //==========================================================================
    // 1. 字段提取（assign；quadrant = insn[1:0]，funct3 = insn[15:13]）
    //==========================================================================
    wire [1:0]  q      = c_insn[1:0];
    wire [2:0]  f3     = c_insn[15:13];

    // 5 位寄存器号（CI/CR/CSS 型：insn[11:7]）
    wire [4:0]  rs1_5  = c_insn[11:7];
    wire [4:0]  rs2_5  = {2'b00, c_insn[6:2]};      // CR/CSS：insn[6:2] 为 5 位
    wire [4:0]  rd_5   = c_insn[11:7];
    // 3 位压缩寄存器号（CIW/CL/CS/CA/CB 型）
    wire [2:0]  rs1_3  = c_insn[9:7];
    wire [2:0]  rd_3   = c_insn[4:2];
    wire [2:0]  rs2_3  = c_insn[4:2];
    // 3 位域 → 实际 5 位寄存器号（+8）
    wire [4:0]  rs1_p  = {2'b01, rs1_3};            // 8 + rs1'
    wire [4:0]  rd_p   = {2'b01, rd_3};             // 8 + rd'
    wire [4:0]  rs2_p  = {2'b01, rs2_3};            // 8 + rs2'

    //==========================================================================
    // 2. RVC 立即数（本地 function）
    //    ★ 重复实现说明：Verilog-2001 的 `function` 不跨模块可见，而 dec_imm.v 的
    //      C 型 function 需要在**本模块**内用于位拼接，故本文件保留一份同源实现。
    //      两者位拼接**逐位一致**（出处同为 binutils riscv.h:70-99），并由
    //      sim/unit/tb_decoder.sv 用同一组激励对拍 dec_imm 与 compressed_expand，
    //      保证不会出现两份漂移（若将来要消除重复，需把 function 放进一个
    //      `include 的 .vh，但本任务的文件范围只允许这 5 个文件，故保留并在
    //      TB 中做等价性约束）。
    //==========================================================================

    // ---- CI 型（c.addi/c.li 等）：imm[5]=c[12]，imm[4:0]=c[6:2]，符号扩展 ----
    function [31:0] ci_imm;
        input [15:0] x;
        begin
            ci_imm = {{26{x[12]}}, x[12], x[6:2]};
        end
    endfunction

    // ---- CIW 型（c.addi4spn）：uimm[5:4]=c[12:11] uimm[9:6]=c[10:7]
    //      uimm[3]=c[6] uimm[2]=c[5]，零扩展，已 ×4 ----
    function [31:0] addi4spn_imm;
        input [15:0] x;
        begin
            addi4spn_imm = {22'b0, x[10:7], x[12:11], x[5], x[6], 2'b00};
        end
    endfunction

    // ---- CI 型（c.addi16sp）：nzimm[9]=c[12] [8:7]=c[4:3] [6]=c[5] [5]=c[2]
    //      [4]=c[6]，符号扩展，已 ×16 ----
    function [31:0] addi16sp_imm;
        input [15:0] x;
        begin
            addi16sp_imm = {{22{x[12]}}, x[12], x[4:3], x[5], x[2], x[6], 4'b0000};
        end
    endfunction

    // ---- CI 型（c.lui）：6 位立即数装入 [17:12]，低 12 位 0，符号扩展 ----
    function [31:0] lui6_imm;
        input [15:0] x;
        begin
            lui6_imm = {{14{x[12]}}, x[12], x[6:2], 12'b0};
        end
    endfunction

    // ---- CI 型（c.lwsp）：uimm[5]=c[12] [4:2]=c[6:4] [7:6]=c[3:2]，零扩展，×4 ----
    function [31:0] lwsp_imm;
        input [15:0] x;
        begin
            lwsp_imm = {24'b0, x[3:2], x[12], x[6:4], 2'b00};
        end
    endfunction

    // ---- CSS 型（c.swsp）：uimm[5:2]=c[12:9] [7:6]=c[8:7]，零扩展，×4 ----
    function [31:0] swsp_imm;
        input [15:0] x;
        begin
            swsp_imm = {24'b0, x[8:7], x[12:9], 2'b00};
        end
    endfunction

    // ---- CL 型（c.lw）：uimm[6]=c[5] [5:3]=c[12:10] [2]=c[6]，零扩展，×4 ----
    function [31:0] lw_imm;
        input [15:0] x;
        begin
            lw_imm = {25'b0, x[5], x[12:10], x[6], 2'b00};
        end
    endfunction

    // ---- CS 型（c.sw）：同 CL（uimm[6]=c[5] [5:3]=c[12:10] [2]=c[6]）----
    function [31:0] sw_imm;
        input [15:0] x;
        begin
            sw_imm = {25'b0, x[5], x[12:10], x[6], 2'b00};
        end
    endfunction

    // ---- CB 型（c.beqz/c.bnez）：imm[8]=c[12] [6:5]=c[6:5] [4:3]=c[11:10]
    //      [2:1]=c[4:3] [7]=c[2]，符号扩展 ----
    function [31:0] cb_imm;
        input [15:0] x;
        begin
            cb_imm = {{23{x[12]}}, x[12], x[6:5], x[2], x[11:10], x[4:3], 1'b0};
        end
    endfunction

    // ---- CJ 型（c.j/c.jal）：符号扩展的 imm[11:1] ----
    function [31:0] cj_imm;
        input [15:0] x;
        begin
            cj_imm = {{20{x[12]}}, x[12], x[8], x[10:9], x[6], x[7], x[2],
                      x[11], x[5:3], 1'b0};
        end
    endfunction

    // ---- 立即数实体（先落 wire 再切片：Verilog 不允许对 function 调用结果直接切片）----
    wire [31:0] im_addi4spn = addi4spn_imm(c_insn);
    wire [31:0] im_addi16sp = addi16sp_imm(c_insn);
    wire [31:0] im_lui6     = lui6_imm(c_insn);
    wire [31:0] im_lwsp     = lwsp_imm(c_insn);
    wire [31:0] im_swsp     = swsp_imm(c_insn);
    wire [31:0] im_lw       = lw_imm(c_insn);
    wire [31:0] im_sw       = sw_imm(c_insn);
    wire [31:0] im_cb       = cb_imm(c_insn);
    wire [31:0] im_cj       = cj_imm(c_insn);
    wire [31:0] im_ci       = ci_imm(c_insn);

    //==========================================================================
    // 3. 合法性判定（reserved ⇒ ill16）
    //    依据 zca.adoc 各 norm:*_rsv 条文；MATCH/MASK 见 riscv-opc.h:660-745。
    //==========================================================================
    // ---- 全零 16 位：永久保留为非法指令（norm:Zca_illegal）----
    wire c_is_zero      = (c_insn == 16'h0000);
    // ---- c.addi4spn：nzuimm==0 保留（norm:c-addi4spn_rsv）----
    wire c_addi4spn_ok  = (im_addi4spn != 32'b0);
    // ---- c.lui：imm==0 保留（norm:c-lui_rsv）；rd=x2 且 imm!=0 ⇒ c.addi16sp ----
    wire c_lui_imm_nz   = (c_insn[12:2] != 11'b0);
    wire c_lui_rd_x2    = (rd_5 == 5'd2);
    // ---- c.addi16sp：nzimm==0 保留（norm:c-addi16sp_rsv）----
    wire c_addi16sp_ok  = (im_addi16sp != 32'b0);
    // ---- c.lwsp：rd!=x0（norm:c-lwsp_rsv）----
    wire c_lwsp_ok      = (rd_5 != 5'd0);
    // ---- c.jr / c.jalr：rs1!=x0（norm:c-jr_rsv / c-jalr_ebreak）----
    //      insn[12]=0 且 rs2=0：insn[12]=1 ⇒ jalr，=0 ⇒ jr；rs1=x0 时分别是
    //      c.jalr 的保留点与 c.jr 的保留点（j[12]=1,rs1=0,rs2=0 是 c.ebreak）。
    wire c_is_cr_jr     = (f3 == 3'b100) && (c_insn[12] == 1'b0) && (rs2_5 == 5'd0);
    wire c_is_cr_jalr   = (f3 == 3'b100) && (c_insn[12] == 1'b1) && (rs2_5 == 5'd0);
    wire c_jr_ok        = (rs1_5 != 5'd0);

    // ---- c.slli/c.srli/c.srai：XLEN=32 时 shamt[5] 必须为 0
    //      （norm:c-slli_shamt5 / c-srli_shamt5）；否则为 custom（本设计不支持）----
    wire c_shamt_ok     = (c_insn[12] == 1'b0);

    //==========================================================================
    // 4. 展开（assign；按 quadrant + funct3 选择等效 32 位编码）
    //    每条等效指令的 opcode/funct3/funct7 全部取自 rv32_defs.vh。
    //==========================================================================
    // ---- 默认：非法 ----
    wire [31:0] insn32;
    wire        ill16;
    wire        is_hint;
    wire        ctl_xfer;

    // 说明：为遵守「大量组合逻辑用 assign/function、禁止大 always @(*) 多 reg 赋值」
    // 红线，此处用**条件表达式嵌套**的 assign 逐条选择。为可读性，先按象限算出
    // 各条候选，再用最终三目链选择——所有中间量都是 wire。

    //--------------------------------------------------------------------------
    // 4.1 Quadrant 0（q=00）：CIW/CL/CS 型
    //--------------------------------------------------------------------------
    // c.addi4spn → addi rd', x2, nzuimm  (I 型)
    //   [ENC:C_ADDI4SPN=0x0 MASK=0xe003（riscv-opc.h:660-661）]
    //   ★ I 型规范字段序（MSB→LSB）：imm[11:0] | rs1[4:0] | funct3 | rd | opcode
    wire [31:0] q0_addi4spn = {im_addi4spn[11:0], 5'd2, `RV32GC_F3_ADDI,
                               rd_p, `RV32GC_OP_IMM};
    // c.lw → lw rd', offset(rs1')  (I 型)
    //   [ENC:C_LW=0x4000 MASK=0xe003（riscv-opc.h:664-665）]
    wire [31:0] q0_lw = {im_lw[11:0], rs1_p, `RV32GC_F3_LW,
                         rd_p, `RV32GC_OP_LOAD};
    // c.sw → sw rs2', offset(rs1')  (S 型)
    //   [ENC:C_SW=0xc000 MASK=0xe003（riscv-opc.h:670-671）]
    //   ★ S 型规范字段序：imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
    wire [31:0] q0_sw = {im_sw[11:5], rs2_p, rs1_p, `RV32GC_F3_SW,
                         im_sw[4:0], `RV32GC_OP_STORE};

    wire [31:0] q0_insn = (f3 == 3'b000) ? q0_addi4spn :
                          (f3 == 3'b010) ? q0_lw       :
                          (f3 == 3'b110) ? q0_sw       :
                                           32'b0;
    wire q0_valid = (f3 == 3'b000) || (f3 == 3'b010) || (f3 == 3'b110);
    wire q0_special_ok = (f3 == 3'b000) ? c_addi4spn_ok : 1'b1;
    // RV32 下 q0 的 f3=001(FLD)/011(FLW)/101(FSD)/111(FSW)：
    //   本设计实现了 F/D ⇒ **FLW(011)/FSW(111) 属 2A 范围外**（2A 只做 L1D 整数侧，
    //   浮点访存由 flw/fsw 的 32 位编码承载；RVC 的 c.flw/c.fsw 是 RV32 的压缩形态，
    //   RV32FC 已并入 Zcf）。**本设计按 08 §1.1 的扩展集合 RV32IMAFDC(Zca) 判定**：
    //   2A **不实现 Zcf**（压缩浮点），故 q0/q2 中的浮点压缩编码 ⇒ 保留（非法）。
    //   依据：core_params.vh §10 的 ISA 字符串 = RV32IMAFDCZicsr_Zifencei_Zicntr_Zicbom，
    //   不含 Zcf/Zcd；zca.adoc 的 RV32 表中 FLW/LD 等是 RV64/RV32FC 旧口径。
    //   ⇒ 此处的 q0 浮点分支一律置为**不可展开**，与 08 §5.2「不支持的扩展编码 ⇒ ill_instr」一致。

    //--------------------------------------------------------------------------
    // 4.2 Quadrant 1（q=01）：CI/CB/CJ/CR 型（常数生成、ALU、分支、跳转）
    //--------------------------------------------------------------------------
    // c.nop / c.addi → addi rd, rd, imm  (I 型)
    //   [ENC:C_ADDI=0x1 MASK=0xe003；C_NOP=0x1 MASK=0xffff（riscv-opc.h:674-675,730-731）]
    wire [31:0] q1_addi = {im_ci[11:0], rs1_5, `RV32GC_F3_ADDI,
                           rd_5, `RV32GC_OP_IMM};
    //   c.nop = c.addi x0, x0, 0（rd=rs1=x0, imm=0）
    wire c_is_nop = (rd_5 == 5'd0) && (rs1_5 == 5'd0) && (im_ci == 32'b0);
    // c.jal (RV32-only) → jal x1, offset  (J 型)
    //   [ENC:C_JAL=0x2001 MASK=0xe003（riscv-opc.h:676-677）]
    //   ★ J 型规范字段序：imm[20|10:1|11|19:12] | rd | opcode
    wire [31:0] q1_jal = {im_cj[20], im_cj[10:1], im_cj[11], im_cj[19:12],
                          5'd1, `RV32GC_OP_JAL};
    // c.li → addi rd, x0, imm  (I 型)
    //   [ENC:C_LI=0x4001 MASK=0xe003（riscv-opc.h:678-679）]
    wire [31:0] q1_li = {im_ci[11:0], 5'd0, `RV32GC_F3_ADDI,
                         rd_5, `RV32GC_OP_IMM};
    // c.lui → lui rd, imm   ; c.addi16sp → addi x2, x2, nzimm
    //   [ENC:C_LUI=0x6001 MASK=0xe003；C_ADDI16SP=0x6101 MASK=0xef83
    //        （riscv-opc.h:680-681,732-733）]
    //   ★ U 型规范字段序：imm[31:12] | rd | opcode
    wire [31:0] q1_lui     = {im_lui6[31:12], rd_5, `RV32GC_OP_LUI};
    wire [31:0] q1_addi16sp= {im_addi16sp[11:0], 5'd2, `RV32GC_F3_ADDI,
                              5'd2, `RV32GC_OP_IMM};
    wire [31:0] q1_f3_011  = c_lui_rd_x2 ? q1_addi16sp : q1_lui;
    wire        q1_f3_011_ok = c_lui_rd_x2 ? c_addi16sp_ok : c_lui_imm_nz;

    // MISC-ALU（f3=100）：
    //   c.srli/c.srai/c.andi（CB，rd'）与 c.sub/c.xor/c.or/c.and（CA，rd'）
    //   [ENC:C_SRLI=0x8001 MASK=0xec03；C_SRAI=0x8401 MASK=0xec03；
    //        C_ANDI=0x8801 MASK=0xec03；C_SUB=0x8c01 MASK=0xfc63；
    //        C_XOR=0x8c21 MASK=0xfc63；C_OR=0x8c41 MASK=0xfc63；
    //        C_AND=0x8c61 MASK=0xfc63（riscv-opc.h:682-699）]
    //   c.srli → srli rd', rd', shamt  = OP-IMM f3=101 f7=0000000
    //   ★ I 型移位：imm[11:5]=funct7、shamt[4:0]=imm[4:0]
    wire [31:0] q1_srli = {`RV32GC_F7_SRLI, c_insn[6:2], rd_p,
                           `RV32GC_F3_SRLI_SRAI, rd_p, `RV32GC_OP_IMM};
    //   c.srai → srai rd', rd', shamt  = OP-IMM f3=101 f7=0100000
    wire [31:0] q1_srai = {`RV32GC_F7_SRAI, c_insn[6:2], rd_p,
                           `RV32GC_F3_SRLI_SRAI, rd_p, `RV32GC_OP_IMM};
    //   c.andi → andi rd', rd', imm[5:0]
    wire [31:0] q1_andi = {im_ci[11:0], rd_p, `RV32GC_F3_ANDI,
                           rd_p, `RV32GC_OP_IMM};
    //   c.sub → sub rd', rd', rs2'  = OP f7=0100000 f3=000
    //   ★ R 型规范字段序：funct7 | rs2 | rs1 | funct3 | rd | opcode
    wire [31:0] q1_sub = {`RV32GC_F7_OP_ALT, rs2_p, rd_p, `RV32GC_F3_ADD_SUB,
                          rd_p, `RV32GC_OP_OP};
    //   c.xor → xor rd', rd', rs2'  = OP f7=0000000 f3=100
    wire [31:0] q1_xor = {`RV32GC_F7_OP_BASE, rs2_p, rd_p, `RV32GC_F3_XOR,
                          rd_p, `RV32GC_OP_OP};
    //   c.or  → or  rd', rd', rs2'  = OP f7=0000000 f3=110
    wire [31:0] q1_or  = {`RV32GC_F7_OP_BASE, rs2_p, rd_p, `RV32GC_F3_OR,
                          rd_p, `RV32GC_OP_OP};
    //   c.and → and rd', rd', rs2'  = OP f7=0000000 f3=111
    wire [31:0] q1_and = {`RV32GC_F7_OP_BASE, rs2_p, rd_p, `RV32GC_F3_AND,
                          rd_p, `RV32GC_OP_OP};

    // f3=100 的选择：insn[11:10] 区分 CB(shift/andi, 00/01/10) 与 CA(100)
    wire [1:0] misc_h2 = c_insn[11:10];
    wire [31:0] q1_misc_alu =
        (misc_h2 == 2'b00) ? q1_srli :
        (misc_h2 == 2'b01) ? q1_srai :
        (misc_h2 == 2'b10) ? q1_andi :
        (misc_h2 == 2'b11) ? ((c_insn[6:5] == 2'b00) ? q1_sub :
                              (c_insn[6:5] == 2'b01) ? q1_xor :
                              (c_insn[6:5] == 2'b10) ? q1_or  :
                                                       q1_and) :
                             32'b0;
    // c.srli/c.srai 在 RV32 下 shamt[5] 必须为 0（否则 custom ⇒ 本设计非法）
    wire q1_misc_ok = (misc_h2 == 2'b00) ? c_shamt_ok :
                      (misc_h2 == 2'b01) ? c_shamt_ok :
                                           1'b1;

    // c.j → jal x0, offset
    //   [ENC:C_J=0xa001 MASK=0xe003（riscv-opc.h:704-705）]
    wire [31:0] q1_j = {im_cj[20], im_cj[10:1], im_cj[11], im_cj[19:12],
                        5'd0, `RV32GC_OP_JAL};
    // c.beqz → beq rs1', x0, offset   ; c.bnez → bne rs1', x0, offset
    //   [ENC:C_BEQZ=0xc001 / C_BNEZ=0xe001 MASK=0xe003（riscv-opc.h:706-709）]
    //   ★ B 型规范字段序：imm[12|10:5] | rs2 | rs1 | funct3 | imm[4:1|11] | opcode
    wire [31:0] q1_beqz = {im_cb[12], im_cb[10:5], 5'd0, rs1_p,
                           `RV32GC_F3_BEQ, im_cb[4:1], im_cb[11], `RV32GC_OP_BRANCH};
    wire [31:0] q1_bnez = {im_cb[12], im_cb[10:5], 5'd0, rs1_p,
                           `RV32GC_F3_BNE, im_cb[4:1], im_cb[11], `RV32GC_OP_BRANCH};

    wire [31:0] q1_insn =
        (f3 == 3'b000) ? q1_addi      :
        (f3 == 3'b001) ? q1_jal       :
        (f3 == 3'b010) ? q1_li        :
        (f3 == 3'b011) ? q1_f3_011    :
        (f3 == 3'b100) ? q1_misc_alu  :
        (f3 == 3'b101) ? q1_j         :
        (f3 == 3'b110) ? q1_beqz      :
        (f3 == 3'b111) ? q1_bnez      :
                         32'b0;
    // RV32 下 q1 全部 8 个 funct3 都已定义 ⇒ valid 恒真（合法性由子项约束给）
    wire q1_valid = 1'b1;
    wire q1_special_ok =
        (f3 == 3'b000) ? 1'b1            :   // c.addi（含 c.nop）恒合法
        (f3 == 3'b001) ? 1'b1            :   // c.jal
        (f3 == 3'b010) ? 1'b1            :   // c.li
        (f3 == 3'b011) ? q1_f3_011_ok    :   // c.lui / c.addi16sp
        (f3 == 3'b100) ? q1_misc_ok      :   // MISC-ALU
                         1'b1;

    //--------------------------------------------------------------------------
    // 4.3 Quadrant 2（q=10）：CI/CSS/CR 型
    //--------------------------------------------------------------------------
    // c.slli → slli rd, rd, shamt  (OP-IMM f3=001 f7=0000000)
    //   [ENC:C_SLLI=0x2 MASK=0xe003（riscv-opc.h:710-711）]
    wire [31:0] q2_slli = {`RV32GC_F7_SRLI, c_insn[6:2], rd_5,
                           `RV32GC_F3_SLLI, rd_5, `RV32GC_OP_IMM};
    // c.lwsp → lw rd, offset(x2)  (I 型)  ；rd!=x0
    //   [ENC:C_LWSP=0x4002 MASK=0xe003（riscv-opc.h:716-717）]
    wire [31:0] q2_lwsp = {im_lwsp[11:0], 5'd2, `RV32GC_F3_LW,
                           rd_5, `RV32GC_OP_LOAD};
    // c.jr/c.mv/c.add/c.jalr/c.ebreak（CR，f3=100）
    //   [ENC:C_MV=0x8002 MASK=0xf003；C_ADD=0x9002 MASK=0xf003；
    //        C_JR=0x8002 MASK=0xf07f；C_JALR=0x9002 MASK=0xf07f；
    //        C_EBREAK=0x9002 MASK=0xffff（riscv-opc.h:720-738）]
    //   c.mv  → add rd, x0, rs2      = OP f7=0000000 f3=000 rs1=x0
    wire [31:0] q2_mv  = {`RV32GC_F7_OP_BASE, rs2_5, 5'd0, `RV32GC_F3_ADD_SUB,
                          rd_5, `RV32GC_OP_OP};
    //   c.add → add rd, rd, rs2      = OP f7=0000000 f3=000
    wire [31:0] q2_add = {`RV32GC_F7_OP_BASE, rs2_5, rd_5, `RV32GC_F3_ADD_SUB,
                          rd_5, `RV32GC_OP_OP};
    //   c.jr  → jalr x0, 0(rs1)      = JALR f3=000 rd=x0 imm=0
    wire [31:0] q2_jr  = {12'b0, rs1_5, `RV32GC_F3_ADDI,
                          5'd0, `RV32GC_OP_JALR};
    //   c.jalr→ jalr x1, 0(rs1)      = JALR f3=000 rd=x1 imm=0
    wire [31:0] q2_jalr= {12'b0, rs1_5, `RV32GC_F3_ADDI,
                          5'd1, `RV32GC_OP_JALR};
    //   c.ebreak → ebreak            = SYSTEM 全零 + insn[20]=1
    wire [31:0] q2_ebreak = `RV32GC_INSN_EBREAK;
    //   f3=100 选择：insn[12]=0 时是 c.jr（rs2=0）/c.mv（rs2!=0）；
    //                insn[12]=1 时是 c.jalr/c.ebreak（rs2=0，rd=0 ⇒ ebreak）
    wire [31:0] q2_cr_lo = (rs2_5 == 5'd0) ? q2_jr  : q2_mv;
    wire [31:0] q2_cr_hi = (rs2_5 == 5'd0) ? ((rd_5 == 5'd0) ? q2_ebreak : q2_jalr)
                                           : q2_add;
    wire [31:0] q2_cr    = c_insn[12] ? q2_cr_hi : q2_cr_lo;
    //   c.ebreak 判定必须在 q2_cr_hi 之前（rs2=0,rd=0）
    wire        c_is_ebreak = (f3 == 3'b100) && (c_insn[12] == 1'b1) &&
                              (rs2_5 == 5'd0) && (rd_5 == 5'd0);

    // c.swsp → sw rs2, offset(x2)  (S 型)
    //   [ENC:C_SWSP=0xc002 MASK=0xe003（riscv-opc.h:726-727）]
    wire [31:0] q2_swsp = {im_swsp[11:5], rs2_5, 5'd2, `RV32GC_F3_SW,
                           im_swsp[4:0], `RV32GC_OP_STORE};

    wire [31:0] q2_insn =
        (f3 == 3'b000) ? q2_slli  :
        (f3 == 3'b010) ? q2_lwsp  :
        (f3 == 3'b100) ? q2_cr    :
        (f3 == 3'b110) ? q2_swsp  :
                         32'b0;
    // q2 的 f3=001(FLDSP)/011(FLWSP)/101(FSDSP)/111(FSWSP) 为浮点压缩（Zcd/Zcf）
    //   ⇒ 2A 不实现（同 4.1 说明）⇒ 保留。
    wire q2_valid = (f3 == 3'b000) || (f3 == 3'b010) ||
                    (f3 == 3'b100) || (f3 == 3'b110);
    wire q2_special_ok =
        (f3 == 3'b000) ? c_shamt_ok  :   // c.slli：RV32 的 shamt[5] 必须为 0
        (f3 == 3'b010) ? c_lwsp_ok   :   // c.lwsp：rd != x0
        (f3 == 3'b100) ? ((c_insn[12] && rs2_5 == 5'd0) ? c_jr_ok : 1'b1) :
                         1'b1;

    //==========================================================================
    // 5. 象限选择 + HINT 判定
    //==========================================================================
    wire [31:0] q_insn =
        (q == 2'b00) ? q0_insn :
        (q == 2'b01) ? q1_insn :
        (q == 2'b10) ? q2_insn :
                       32'b0;          // q=11 ⇒ 非 16 位指令（调用方不应走本模块）

    wire q_valid = (q == 2'b00) ? (q0_valid && q0_special_ok) :
                   (q == 2'b01) ? (q1_valid && q1_special_ok) :
                   (q == 2'b10) ? (q2_valid && q2_special_ok) :
                                  1'b0;

    // ---- HINT 判定（zca.adoc「ext:zca[] HINT instructions」表）----
    //      这些编码**不改变架构状态**：照常展开为等效指令，rd=x0 自然不写回。
    //      仅登记 is_hint 供上层统计/探针使用，不改变执行语义。
    wire hint_addi0   = (q == 2'b01) && (f3 == 3'b000) &&
                        (rd_5 != 5'd0) && (im_ci == 32'b0);
    wire hint_li_x0   = (q == 2'b01) && (f3 == 3'b010) && (rd_5 == 5'd0);
    wire hint_lui_x0  = (q == 2'b01) && (f3 == 3'b011) &&
                        (rd_5 == 5'd0) && c_lui_imm_nz;
    wire hint_mv_x0   = (q == 2'b10) && (f3 == 3'b100) && (c_insn[12] == 1'b0) &&
                        (rd_5 == 5'd0) && (rs2_5 != 5'd0);
    wire hint_add_x0  = (q == 2'b10) && (f3 == 3'b100) && (c_insn[12] == 1'b1) &&
                        (rs2_5 != 5'd0) && (rd_5 == 5'd0);
    wire hint_slli    = (q == 2'b10) && (f3 == 3'b000) &&
                        ((rd_5 == 5'd0) || (c_insn[6:2] == 5'b0));
    wire hint_nop_imm = c_is_nop && (im_ci != 32'b0);   // c.nop 且 imm!=0
    wire hint_any     = hint_addi0 || hint_li_x0 || hint_lui_x0 || hint_mv_x0 ||
                        hint_add_x0 || hint_slli || hint_nop_imm;

    //==========================================================================
    // 6. 输出
    //==========================================================================
    assign insn32_o   = q_insn;
    assign ill16_o    = c_is_zero | ~q_valid;
    assign is_hint_o  = hint_any & ~ill16_o;
    // 控制转移：jal/jalr/分支（供 E 级按本指令长度算链接值 pc+2）
    assign ctl_xfer_o = (q_insn[6:0] == `RV32GC_OP_JAL)  |
                        (q_insn[6:0] == `RV32GC_OP_JALR) |
                        (q_insn[6:0] == `RV32GC_OP_BRANCH);

endmodule

`endif // RV32GC_COMPRESSED_EXPAND_V
