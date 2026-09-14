//==============================================================================
// rtl/decode/dec_imm.v —— D 级立即数生成（RV32 I/S/B/U/J 型 + RVC 全部变体）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格    : docs/design/08-baseline-5stage.md §5.2（D 级——译码：立即数生成）
// 作用    : 纯组合、无状态。把 32 位指令（或 16 位压缩指令展开后的等效 32 位指令）
//           的立即数字段按类型取出并**符号/零扩展**为 32 位。
// 风格纪律: AGENT.md §4 红线 3 + 08 §7.4 —— 大量组合逻辑用 function/assign 表达；
//           本文件**不含任何 always 块**（无 always @(*) 多 reg 赋值）。
//
// 编码真源: 位域常量一律取自 rtl/pkg/rv32_defs.vh（唯一真源），本文件不硬编码
//           opcode/funct3 数值；立即数的**位拼接**按 ISA 定义书写并在注释中给出
//           可复核出处。
// 引用口径:
//   [ISA] riscv-isa-manual/src/unpriv/rv-32-64g.adoc（I/S/B/U/J 型立即数位段）
//         riscv-isa-manual/src/unpriv/zca.adoc（C 型立即数位段与合法性约束）
//   [ENC] riscv-gnu-toolchain/binutils/include/opcode/riscv.h:60-99
//         （EXTRACT_* 宏：与 binutils 反汇编器逐位一致，可复核）
//   ★ 本文件的 RVC 立即数位拼接与 riscv.h:70-99 的 EXTRACT_* 宏**逐项对应**，
//     对应关系写在各 function 的注释里（复核方法：对照 riscv.h 同名宏）。
//
// 用法    : dec_imm.v 被 decoder.v / compressed_expand.v 共同例化（或直接调用其
//           function）。调用方只依赖 function 的**名与返回语义**，不依赖内部实现。
// include 顺序: rv32_defs.vh（先）→ core_params.vh（后）——见任务书与
//           core_params.vh §1「推荐 include 顺序」。
//==============================================================================
`ifndef RV32GC_DEC_IMM_V
`define RV32GC_DEC_IMM_V

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module dec_imm (
    // ---- 输入：待取立即数的指令（32 位；压缩指令须先由 compressed_expand 展开）----
    input  wire [31:0] insn,
    // ---- 选择：取哪一类立即数（one-hot，来自 decoder 的型别判定）----
    input  wire        sel_i,        // I 型：insn[31:20] 符号扩展
    input  wire        sel_s,        // S 型：insn[31:25]|insn[11:7] 符号扩展
    input  wire        sel_b,        // B 型：散列位 + 低 0
    input  wire        sel_u,        // U 型：insn[31:12] << 12（低 12 位 0）
    input  wire        sel_j,        // J 型：散列位 + 低 0
    input  wire        sel_ishift,   // I 型移位：RV32 shamt = insn[24:20]（零扩展 5 位）
    // ---- 输出 ----
    output wire [31:0] imm_o
);

    //==========================================================================
    // 1. 主 ISA 立即数（用 function 表达；位拼接按 ISA 定义）
    //==========================================================================

    // ---- I 型：imm[11:0] = insn[31:20]，符号扩展至 32 位 ----
    //      [ISA:rv-32-64g.adoc]；[ENC:EXTRACT_ITYPE_IMM  riscv.h:60-61]
    function [31:0] f_imm_i;
        input [31:0] x;
        begin
            f_imm_i = {{20{x[31]}}, x[31:20]};
        end
    endfunction

    // ---- S 型：imm[11:5] = insn[31:25]，imm[4:0] = insn[11:7] ----
    //      [ENC:EXTRACT_STYPE_IMM  riscv.h:62-63]
    function [31:0] f_imm_s;
        input [31:0] x;
        begin
            f_imm_s = {{20{x[31]}}, x[31:25], x[11:7]};
        end
    endfunction

    // ---- B 型：imm[12]=x[31] imm[11]=x[7] imm[10:5]=x[30:25] imm[4:1]=x[11:8] imm[0]=0 ----
    //      [ENC:EXTRACT_BTYPE_IMM  riscv.h:64-65]
    function [31:0] f_imm_b;
        input [31:0] x;
        begin
            f_imm_b = {{19{x[31]}}, x[31], x[7], x[30:25], x[11:8], 1'b0};
        end
    endfunction

    // ---- U 型：imm[31:12] = insn[31:12]，imm[11:0] = 0 ----
    //      [ENC:EXTRACT_UTYPE_IMM  riscv.h:66-67]
    //      注：RV32 下 U 型的「立即数」即该 20 位字段左移 12；不做符号扩展
    //          （符号性由 lui/auipc 的使用方式决定）。
    function [31:0] f_imm_u;
        input [31:0] x;
        begin
            f_imm_u = {x[31:12], 12'b0};
        end
    endfunction

    // ---- J 型：imm[20]=x[31] imm[19:12]=x[19:12] imm[11]=x[20] imm[10:1]=x[30:21] imm[0]=0 ----
    //      [ENC:EXTRACT_JTYPE_IMM  riscv.h:68-69]
    function [31:0] f_imm_j;
        input [31:0] x;
        begin
            f_imm_j = {{11{x[31]}}, x[31], x[19:12], x[20], x[30:21], 1'b0};
        end
    endfunction

    // ---- I 型移位（slli/srli/srai）：RV32 下 shamt 仅 insn[24:20]（5 位，零扩展）----
    //      ★ RV32 真源口径：rv32_defs.vh §3.5 注释「移位立即数在 RV32 上位 5 位必须为 0」
    //        （即 funct7[6:5] 必须为 00）；此处取 5 位零扩展，与 MASK 0xfe00707f 一致。
    function [31:0] f_imm_ishift;
        input [31:0] x;
        begin
            f_imm_ishift = {27'b0, x[24:20]};
        end
    endfunction

    //==========================================================================
    // 2. RVC（压缩）立即数变体
    //    全部按 binutils riscv.h:70-99 的 EXTRACT_* 宏逐位对应实现。
    //    返回值为「已符号/零扩展的 32 位立即数」，供 compressed_expand.v
    //    拼装等效 32 位指令时使用。
    //==========================================================================

    // ---- CI 型 imm（c.addi/c.li/c.slli/c.addi16sp 等共用 6 位立即数）----
    //      imm[5] = insn[12]（符号位）、imm[4:0] = insn[6:2]
    //      [ENC:EXTRACT_CITYPE_IMM  riscv.h:70-71]
    function [31:0] f_c_imm_ci;
        input [15:0] x;
        begin
            f_c_imm_ci = {{26{x[12]}}, x[12], x[6:2]};
        end
    endfunction

    // ---- CIW 型 nzuimm（c.addi4spn）：imm[9:2]，零扩展（无符号，scaled by 4）----
    //      imm[5:4]=x[12:11]  imm[9:6]=x[10:7]  imm[3]=x[6]  imm[2]=x[5]
    //      [ENC:EXTRACT_CIWTYPE_ADDI4SPN_IMM  riscv.h:88-89]
    //      ★ 产物即「已 ×4 后」的字节偏移 (nzuimm[9:2] 拼成的 8 位再补低 2 位 0)。
    function [31:0] f_c_imm_addi4spn;
        input [15:0] x;
        begin
            f_c_imm_addi4spn = {22'b0, x[10:7], x[12:11], x[5], x[6], 2'b00};
        end
    endfunction

    // ---- CI 型 addi16sp nzimm：imm[9:4]，符号扩展，scaled by 16 ----
    //      imm[9]=x[12] imm[8:7]=x[4:3] imm[6]=x[5] imm[5]=x[2] imm[4]=x[6]
    //      [ENC:EXTRACT_CITYPE_ADDI16SP_IMM  riscv.h:74-75]
    function [31:0] f_c_imm_addi16sp;
        input [15:0] x;
        begin
            f_c_imm_addi16sp = {{22{x[12]}}, x[12], x[4:3], x[5], x[2], x[6], 4'b0000};
        end
    endfunction

    // ---- CI 型 lui imm（c.lui）：6 位立即数装入 [17:12]，低 12 位 0，符号扩展到 32 ----
    //      [ENC:EXTRACT_CITYPE_LUI_IMM  riscv.h:72-73 = (CITYPE_IMM << 12)]
    //      CITYPE_IMM 的符号位 x[12] 经 <<12 后落在 bit17，故须补 {14{imm5}} 到 [31:18]。
    function [31:0] f_c_imm_lui;
        input [15:0] x;
        begin
            f_c_imm_lui = {{14{x[12]}}, x[12], x[6:2], 12'b0};
        end
    endfunction

    // ---- CI 型 lwsp offset（c.lwsp）：uimm[7:2]，零扩展，scaled by 4 ----
    //      imm[5]=x[12] imm[4:2]=x[6:4] imm[7:6]=x[3:2]
    //      [ENC:EXTRACT_CITYPE_LWSP_IMM  riscv.h:76-77]
    function [31:0] f_c_imm_lwsp;
        input [15:0] x;
        begin
            f_c_imm_lwsp = {24'b0, x[3:2], x[12], x[6:4], 2'b00};
        end
    endfunction

    // ---- CSS 型 swsp offset（c.swsp）：uimm[7:2]，零扩展，scaled by 4 ----
    //      imm[5:2]=x[12:9] imm[7:6]=x[8:7]
    //      [ENC:EXTRACT_CSSTYPE_SWSP_IMM  riscv.h:82-83]
    function [31:0] f_c_imm_swsp;
        input [15:0] x;
        begin
            f_c_imm_swsp = {24'b0, x[8:7], x[12:9], 2'b00};
        end
    endfunction

    // ---- CL 型 lw offset（c.lw）：uimm[6:2]，零扩展，scaled by 4 ----
    //      imm[6]=x[5] imm[5:3]=x[12:10] imm[2]=x[6]
    //      [ENC:EXTRACT_CLTYPE_LW_IMM  riscv.h:92-93]
    function [31:0] f_c_imm_lw;
        input [15:0] x;
        begin
            f_c_imm_lw = {25'b0, x[5], x[12:10], x[6], 2'b00};
        end
    endfunction

    // ---- CS 型 sw offset（c.sw）：uimm[6:2]，零扩展，scaled by 4 ----
    //      imm[6]=x[5] imm[5:3]=x[12:10] imm[2]=x[6]
    //      [ENC:EXTRACT_CLTYPE_IMM  riscv.h:90-91（CL/CS 同构）]
    function [31:0] f_c_imm_sw;
        input [15:0] x;
        begin
            f_c_imm_sw = {25'b0, x[5], x[12:10], x[6], 2'b00};
        end
    endfunction

    // ---- CB 型 branch offset（c.beqz/c.bnez）：imm[8:1]，符号扩展 ----
    //      imm[8]=x[12] imm[6:5]=x[6:5] imm[4:3]=x[11:10] imm[2:1]=x[4:3] imm[7]=x[2]
    //      [ENC:EXTRACT_CBTYPE_IMM  riscv.h:96-97（返回已含低 0 位的 9 位符号值）]
    function [31:0] f_c_imm_cb;
        input [15:0] x;
        begin
            f_c_imm_cb = {{23{x[12]}}, x[12], x[6:5], x[2], x[11:10], x[4:3], 1'b0};
        end
    endfunction

    // ---- CJ 型 jump offset（c.j/c.jal）：imm[11:1]，符号扩展 ----
    //      imm[11]=x[12] imm[10]=x[8] imm[9:8]=x[10:9] imm[7]=x[6] imm[6]=x[7]
    //      imm[5:3]=x[2] imm[4]... 见 riscv.h:98-99 逐位：
    //      [ENC:EXTRACT_CJTYPE_IMM  riscv.h:98-99]
    //      位拼接（返回 32 位符号扩展值）：
    //        target[11]=x[12] target[10]=x[8] target[9:8]=x[10:9]
    //        target[7]=x[6]  target[6]=x[7]  target[5:3]=x[2:4]... 
    //      按宏展开逐项对应：
    //        RV_X(x,3,3)<<1  ⇒ imm[3:1] = x[5:3]
    //        RV_X(x,11,1)<<4 ⇒ imm[4]   = x[11]
    //        RV_X(x,2,1)<<5  ⇒ imm[5]   = x[2]
    //        RV_X(x,7,1)<<6  ⇒ imm[6]   = x[7]
    //        RV_X(x,6,1)<<7  ⇒ imm[7]   = x[6]
    //        RV_X(x,9,2)<<8  ⇒ imm[9:8] = x[10:9]
    //        RV_X(x,8,1)<<10 ⇒ imm[10]  = x[8]
    //        -RV_X(x,12,1)<<11 ⇒ imm[11] = x[12]（符号位）
    function [31:0] f_c_imm_cj;
        input [15:0] x;
        begin
            f_c_imm_cj = {{20{x[12]}}, x[12], x[8], x[10:9], x[6], x[7], x[2], x[11], x[5:3], 1'b0};
        end
    endfunction

    //==========================================================================
    // 3. 选择网络（assign；sel_* 为 one-hot，优先级：shift > j > b > u > s > i）
    //    优先级只在「多选」这种非法输入下才有定义；正常译码时恰好一项为 1。
    //==========================================================================
    wire [31:0] imm_i = f_imm_i(insn);
    wire [31:0] imm_s = f_imm_s(insn);
    wire [31:0] imm_b = f_imm_b(insn);
    wire [31:0] imm_u = f_imm_u(insn);
    wire [31:0] imm_j = f_imm_j(insn);
    wire [31:0] imm_is = f_imm_ishift(insn);

    assign imm_o = sel_ishift ? imm_is :
                   sel_j      ? imm_j  :
                   sel_b      ? imm_b  :
                   sel_u      ? imm_u  :
                   sel_s      ? imm_s  :
                   sel_i      ? imm_i  :
                                32'b0;

endmodule

`endif // RV32GC_DEC_IMM_V
