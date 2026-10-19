//==============================================================================
// sim/functional/tb_decode_semantics.sv —— F1 译码包功能定向测试
//==============================================================================
// 目的 : 对 rtl/decode/{compressed_expand.v,decoder.v} 的**语义级**行为做
//        fail-closed 定向验证，覆盖三组已复现缺陷与逐字段正反控制：
//          A. Zca CA/CB 的 rd′/rs1′ 域（c.srli/c.srai/c.andi/c.sub/c.xor/c.or/c.and）
//          B. c.ebreak / c.jr / c.jalr 的合法性（9002 / 8002 / 8282 / 9282 …）
//          C. OP-FP 保留/不支持字段（FSQRT rs2=0、RV32 FCVT 仅 W/WU、
//             F↔D 配对、FMV/FCLASS 的 rs2=0 与 fmt/f3 mask；非法组额外核 fp_we=0）
//          D. 上述各族的**合法对照**（逐字段：展开值、rd/rs1/rs2、fp_op/fp_we/wb_sel）
//          E. RV32I/立即数 + CSR 权限与非法编码的 tval（cause 2 口径 T1）
//
// 冻结规格（TB 本体自判，与 test_decode.sh 的 SPEC_* 同步）:
//   SPEC_TOTAL=80、SPEC_NONZERO=79、SPEC_CHECKS=260。
//   每个向量至少 1 项检查（v_end 守卫）；末尾再核对三项总数，
//   任一不符 ⇒ 直接 FAIL（防止删向量/删整段断言后"自洽"通过）。
//
// 期望值来源（独立 oracle，非 RTL 直读；日志见 build/functional/decode/gen/）：
//   · 16 位压缩编码与 32 位等效展开：riscv32-unknown-linux-gnu-{as,objdump} 实测
//     （probe.S / probe2.S / probe5.S，-march=rv32imafdc_zca）；
//   · 32 位字段级重算：gen/ref_enc.py（纯位域组装，无 RTL 依赖）；
//   · 保留/RV64-only 判据：riscv-isa-manual/src/unpriv/{zca.adoc,rv-32-64g.adoc}
//     编码表（FSQRT/FMV/FCLASS 的 rs2 列固定 00000；L/LU 与 FMV.X.D/FMV.D.X
//     列在「RV64F/RV64D Standard Extension (in addition to RV32…)」表），并由
//     `as -march=rv32imafdc` 拒绝对应助记符作为负向 oracle。
//
// 判定 : 逐向量累计检查数/失败数；任一失败只登记不提前退出，跑完全部向量后
//        若 fails≠0（或向量数/非零向量数/检查数为 0）⇒ $fatal 非零退出；
//        全部通过才在最后一行打印**唯一整行** `FUNCTIONAL_DECODE: PASS`。
//        顶层 : tb_decode_semantics_top（-s tb_decode_semantics_top）。
//
// 项目口径（不是 ISA 断言，勿混）：
//   rm=101/110 属保留舍入模式；本项目沿用既有严格译码之外的「接受全部 rm」策略，
//   本 TB 以 PROJ_CTL_* 控制例锁定该**项目现状**，不宣称规范强制在此 trap。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_decode_semantics_top;

    //--------------------------------------------------------------------------
    // DUT 端口镜像（decoder）
    //--------------------------------------------------------------------------
    reg  [31:0] insn_i;
    reg  [1:0]  priv_i;
    reg  [1:0]  menvcfg_cbie_i;
    reg         menvcfg_cbcfe_i;
    reg  [1:0]  senvcfg_cbie_i;
    reg         senvcfg_cbcfe_i;

    wire [31:0] insn32_o, tval_o, imm_o;
    wire        ill_instr_o, is_compressed_o, is_hint_o, ctl_xfer_o;
    wire [4:0]  rs1_o, rs2_o, rs3_o, rd_o, cbo_kind_o;
    wire [3:0]  op_type_o, alu_op_o, mem_op_o;
    wire [2:0]  mem_size_o, wb_sel_o, csr_op_o, rm_o;
    wire        mem_unsign_o, fp_we_o, fp_ldst_o, csr_ill_o, csr_zimm_o;
    wire        cbo_valid_o, cbo_gate_ill_o, cbo_downgrade_o;
    wire        fence_i_o, fence_o, ebreak_o, ecall_o, mret_o, sret_o, wfi_o;
    wire [5:0]  fp_op_o;
    wire        rv32_is_amo_o;
    wire [11:0] csr_addr_o;
    wire        sfence_vma_o;

    decoder u_dec (
        .insn_i           (insn_i),
        .priv_i           (priv_i),
        .menvcfg_cbie_i   (menvcfg_cbie_i),
        .menvcfg_cbcfe_i  (menvcfg_cbcfe_i),
        .senvcfg_cbie_i   (senvcfg_cbie_i),
        .senvcfg_cbcfe_i  (senvcfg_cbcfe_i),
        .insn32_o         (insn32_o),
        .tval_o           (tval_o),
        .ill_instr_o      (ill_instr_o),
        .is_compressed_o  (is_compressed_o),
        .is_hint_o        (is_hint_o),
        .ctl_xfer_o       (ctl_xfer_o),
        .rs1_o            (rs1_o),
        .rs2_o            (rs2_o),
        .rs3_o            (rs3_o),
        .rd_o             (rd_o),
        .imm_o            (imm_o),
        .op_type_o        (op_type_o),
        .alu_op_o         (alu_op_o),
        .mem_op_o         (mem_op_o),
        .mem_size_o       (mem_size_o),
        .mem_unsign_o     (mem_unsign_o),
        .wb_sel_o         (wb_sel_o),
        .csr_op_o         (csr_op_o),
        .fp_op_o          (fp_op_o),
        .fp_we_o          (fp_we_o),
        .fp_ldst_o        (fp_ldst_o),
        .rm_o             (rm_o),
        .rv32_is_amo_o    (rv32_is_amo_o),
        .csr_addr_o       (csr_addr_o),
        .csr_ill_o        (csr_ill_o),
        .csr_zimm_o       (csr_zimm_o),
        .cbo_valid_o      (cbo_valid_o),
        .cbo_kind_o       (cbo_kind_o),
        .cbo_gate_ill_o   (cbo_gate_ill_o),
        .cbo_downgrade_o  (cbo_downgrade_o),
        .fence_i_o        (fence_i_o),
        .fence_o          (fence_o),
        .ebreak_o         (ebreak_o),
        .ecall_o          (ecall_o),
        .mret_o           (mret_o),
        .sret_o           (sret_o),
        .wfi_o            (wfi_o),
        .sfence_vma_o     (sfence_vma_o)
    );

    //--------------------------------------------------------------------------
    // 独立参照：compressed_expand（直接断言 16 位展开，绕开 decoder 包装）
    //--------------------------------------------------------------------------
    reg  [15:0] cexp_in;
    wire [31:0] cexp_insn32;
    wire        cexp_ill, cexp_hint, cexp_ctl;
    compressed_expand u_cexp_ref (
        .c_insn     (cexp_in),
        .insn32_o   (cexp_insn32),
        .ill16_o    (cexp_ill),
        .is_hint_o  (cexp_hint),
        .ctl_xfer_o (cexp_ctl)
    );

    //--------------------------------------------------------------------------
    // 计数器与断言宏（fail-closed：向量数/非零向量数/检查数必须 > 0）
    //--------------------------------------------------------------------------
    integer n_vec;       // 向量总数
    integer n_nonzero;   // 输入位非全零的向量数（"非零向量数"）
    integer n_check;     // 累计检查数
    integer n_fail;      // 累计失败数
    integer v_check;     // 本向量检查数
    integer v_fail;      // 本向量失败数
    reg [8*40:1] v_name; // 本向量名（<=39 字符）

    // ---- 本包冻结规格（TB **本体**自判，不依赖包装器 test_decode.sh）----
    //   与 sim/functional/test_decode.sh 的 SPEC_* 常量同步：
    //   任一向量被删/整段断言被删/新增向量或断言未同步 ⇒ 本 TB 直接 FAIL。
    localparam integer SPEC_TOTAL   = 80;
    localparam integer SPEC_NONZERO = 79;
    localparam integer SPEC_CHECKS  = 260;

    `define CHK(cond, msg) \
        begin \
            n_check = n_check + 1; \
            v_check = v_check + 1; \
            if (!(cond)) begin \
                n_fail = n_fail + 1; \
                v_fail = v_fail + 1; \
                $display("CHECK_FAIL vec=%0d %0s : %s", n_vec, v_name, msg); \
            end \
        end

    // ---- 逐向量驱动：envcfg 全关（复位默认值）----
    //   c16：压缩向量传 16 位原始编码（同时驱动 cexp；32 位向量该参数无意义）
    task v_begin_priv;
        input [31:0] insn;
        input [15:0] c16;
        input [1:0]  priv;
        begin
            insn_i          = insn;
            priv_i          = priv;
            menvcfg_cbie_i  = 2'b00;
            menvcfg_cbcfe_i = 1'b0;
            senvcfg_cbie_i  = 2'b00;
            senvcfg_cbcfe_i = 1'b0;
            cexp_in         = c16;
            n_vec           = n_vec + 1;
            if (insn != 32'd0) n_nonzero = n_nonzero + 1;
            v_check = 0;
            v_fail  = 0;
            #1;   // 组合逻辑建立（TB 驱动纪律，非 RTL 时序问题）
        end
    endtask

    task v_begin;
        input [31:0] insn;
        input [15:0] c16;
        begin
            v_begin_priv(insn, c16, `RV32GC_PRIV_M);
        end
    endtask

    task v_end;
        begin
            // ★ 每个向量至少 1 项检查：防止"删掉某向量全部断言"仍整体 PASS。
            //   该守卫计入 n_fail（不计入 n_check，避免与冻结的 checks 计数纠缠）。
            if (v_check == 0) begin
                n_fail = n_fail + 1;
                v_fail = v_fail + 1;
                $display("CHECK_FAIL vec=%0d %0s : vector has no check (v_check=0)", n_vec, v_name);
            end
            $display("VEC %0d %0s checks=%0d fails=%0d", n_vec, v_name, v_check, v_fail);
        end
    endtask

    //==========================================================================
    // 主检查流程
    //==========================================================================
    initial begin
        n_vec = 0; n_nonzero = 0; n_check = 0; n_fail = 0;
        v_check = 0; v_fail = 0; v_name = "";
        insn_i = 32'd0;
        priv_i = `RV32GC_PRIV_M;
        menvcfg_cbie_i = 2'b00; menvcfg_cbcfe_i = 1'b0;
        senvcfg_cbie_i = 2'b00; senvcfg_cbcfe_i = 1'b0;
        cexp_in = 16'd0;
        #1;

        $display("---- decode semantics (F1) : compressed_expand + decoder ----");

        //======================================================================
        // A. Zca CA/CB 的 rd′/rs1′ 域（缺陷 F05-01）
        //    CA/CB：rd′/rs1′ = c[9:7]，rs2′ = c[4:2]；旧实现误用 c[4:2] 作 rd/rs1。
        //======================================================================

        // ---- c.srli x8, 5 ⇒ 0x8015 ⇒ srli x8,x8,5 = 0x00545413 ----
        v_name = "C_SRLI_X8_5";
        v_begin(32'h0000_8015, 16'h8015);
        `CHK(cexp_ill === 1'b0,             "c.srli 不应判保留")
        `CHK(cexp_insn32 === 32'h00545413,  "c.srli 应展开为 srli x8,x8,5")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(insn32_o === 32'h00545413,     "decoder insn32 应为 0x00545413")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8（c[9:7]）")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8（c[9:7]）")
        `CHK(is_compressed_o === 1'b1,      "应标记压缩指令")
        `CHK(ctl_xfer_o === 1'b0,           "非控制转移")
        v_end;

        // ---- c.srai x8, 5 ⇒ 0x8415 ⇒ srai x8,x8,5 = 0x40545413 ----
        v_name = "C_SRAI_X8_5";
        v_begin(32'h0000_8415, 16'h8415);
        `CHK(cexp_ill === 1'b0,             "c.srai 不应判保留")
        `CHK(cexp_insn32 === 32'h40545413,  "c.srai 应展开为 srai x8,x8,5")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(insn32_o === 32'h40545413,     "decoder insn32 应为 0x40545413")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8")
        v_end;

        // ---- c.andi x8, 5 ⇒ 0x8815 ⇒ andi x8,x8,5 = 0x00547413 ----
        v_name = "C_ANDI_X8_5";
        v_begin(32'h0000_8815, 16'h8815);
        `CHK(cexp_ill === 1'b0,             "c.andi 不应判保留")
        `CHK(cexp_insn32 === 32'h00547413,  "c.andi 应展开为 andi x8,x8,5")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(insn32_o === 32'h00547413,     "decoder insn32 应为 0x00547413")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8")
        v_end;

        // ---- c.sub x8, x9 ⇒ 0x8c05 ⇒ sub x8,x8,x9 = 0x40940433 ----
        v_name = "C_SUB_X8_X9";
        v_begin(32'h0000_8c05, 16'h8c05);
        `CHK(cexp_ill === 1'b0,             "c.sub 不应判保留")
        `CHK(cexp_insn32 === 32'h40940433,  "c.sub 应展开为 sub x8,x8,x9")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(insn32_o === 32'h40940433,     "decoder insn32 应为 0x40940433")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8")
        `CHK(rs2_o === 5'd9,                "rs2 应为 x9（c[4:2]）")
        v_end;

        // ---- c.xor x8, x9 ⇒ 0x8c25 ⇒ xor x8,x8,x9 = 0x00944433 ----
        v_name = "C_XOR_X8_X9";
        v_begin(32'h0000_8c25, 16'h8c25);
        `CHK(cexp_insn32 === 32'h00944433,  "c.xor 应展开为 xor x8,x8,x9")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8")
        `CHK(rs2_o === 5'd9,                "rs2 应为 x9")
        v_end;

        // ---- c.or x8, x9 ⇒ 0x8c45 ⇒ or x8,x8,x9 = 0x00946433 ----
        v_name = "C_OR_X8_X9";
        v_begin(32'h0000_8c45, 16'h8c45);
        `CHK(cexp_insn32 === 32'h00946433,  "c.or 应展开为 or x8,x8,x9")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs2_o === 5'd9,                "rs2 应为 x9")
        v_end;

        // ---- c.and x8, x9 ⇒ 0x8c65 ⇒ and x8,x8,x9 = 0x00947433 ----
        v_name = "C_AND_X8_X9";
        v_begin(32'h0000_8c65, 16'h8c65);
        `CHK(cexp_insn32 === 32'h00947433,  "c.and 应展开为 and x8,x8,x9")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs2_o === 5'd9,                "rs2 应为 x9")
        v_end;

        // ---- 控制（rd′=rs2′）：c.sub x8, x8 ⇒ 0x8c01 ⇒ sub x8,x8,x8 = 0x40840433 ----
        //   旧实现两种取法同值 ⇒ 基线亦应通过，用于排除"夹具/期望常量错"。
        v_name = "CTL_C_SUB_X8_X8";
        v_begin(32'h0000_8c01, 16'h8c01);
        `CHK(cexp_ill === 1'b0,             "c.sub(rd=rs2) 不应判保留")
        `CHK(cexp_insn32 === 32'h40840433,  "c.sub x8,x8 应展开为 sub x8,x8,x8")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(insn32_o === 32'h40840433,     "decoder insn32 应为 0x40840433")
        v_end;

        // ---- 控制（rd′≠rs2′ 且 rd′ 非默认）：c.sub x15, x8 ⇒ 0x8f81 ----
        //   旧实现会把 rd/rs1 取成 8+rs2′=x8、rd 也 x8 ⇒ 展开值不同。
        v_name = "CTL_C_SUB_X15_X8";
        v_begin(32'h0000_8f81, 16'h8f81);
        `CHK(cexp_insn32 === 32'h408787b3,  "c.sub x15,x8 应展开为 sub x15,x15,x8")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd15,                "rd 应为 x15")
        `CHK(rs2_o === 5'd8,                "rs2 应为 x8")
        v_end;

        // ---- CB 非默认 rd′：c.srli x15, 1 ⇒ 0x8385 ⇒ srli x15,x15,1 = 0x0017d793 ----
        v_name = "CTL_C_SRLI_X15_1";
        v_begin(32'h0000_8385, 16'h8385);
        `CHK(cexp_insn32 === 32'h0017d793,  "c.srli x15,1 应展开为 srli x15,x15,1")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd15,                "rd 应为 x15")
        v_end;

        // ---- CB：c.srai x15, 3 ⇒ 0x878d ⇒ srai x15,x15,3 = 0x4037d793 ----
        v_name = "CTL_C_SRAI_X15_3";
        v_begin(32'h0000_878d, 16'h878d);
        `CHK(cexp_insn32 === 32'h4037d793,  "c.srai x15,3 应展开为 srai x15,x15,3")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd15,                "rd 应为 x15")
        v_end;

        // ---- CB：c.andi x15, -1 ⇒ 0x9bfd ⇒ andi x15,x15,-1 = 0xfff7f793 ----
        v_name = "CTL_C_ANDI_X15_M1";
        v_begin(32'h0000_9bfd, 16'h9bfd);
        `CHK(cexp_insn32 === 32'hfff7f793,  "c.andi x15,-1 应展开为 andi x15,x15,-1")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(rd_o === 5'd15,                "rd 应为 x15")
        v_end;

        // ---- 非 MISC-ALU 的 C 目的域不得被本次修复波及 ----
        //   c.addi x5, 3 ⇒ 0x028d ⇒ addi x5,x5,3 = 0x00328293（CI，rd = c[11:7]）
        v_name = "CTL_C_ADDI_X5_3";
        v_begin(32'h0000_028d, 16'h028d);
        `CHK(cexp_ill === 1'b0,             "c.addi 不应判保留")
        `CHK(cexp_insn32 === 32'h00328293,  "c.addi 应展开为 addi x5,x5,3")
        `CHK(rd_o === 5'd5,                 "rd 应为 x5")
        v_end;

        //   c.addi4spn x8, sp, 8 ⇒ 0x0020 ⇒ addi x8,x2,8 = 0x00810413（CIW，rd′ = c[4:2]）
        v_name = "CTL_C_ADDI4SPN_X8_8";
        v_begin(32'h0000_0020, 16'h0020);
        `CHK(cexp_ill === 1'b0,             "c.addi4spn 不应判保留")
        `CHK(cexp_insn32 === 32'h00810413,  "c.addi4spn 应展开为 addi x8,x2,8")
        `CHK(rd_o === 5'd8,                 "rd 应为 x8")
        `CHK(rs1_o === 5'd2,                "rs1 应为 x2(sp)")
        v_end;

        //   c.lw x9, 4(x8) ⇒ 0x4044 ⇒ lw x9,4(x8) = 0x00442483（CL：rd′ = c[4:2]）
        v_name = "CTL_C_LW_X9_4_X8";
        v_begin(32'h0000_4044, 16'h4044);
        `CHK(cexp_ill === 1'b0,             "c.lw 不应判保留")
        `CHK(cexp_insn32 === 32'h00442483,  "c.lw 应展开为 lw x9,4(x8)")
        `CHK(rd_o === 5'd9,                 "rd 应为 x9（c[4:2]）")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8（c[9:7]）")
        `CHK(imm_o === 32'd4,               "imm 应为 4")
        v_end;

        //   c.sw x9, 4(x8) ⇒ 0xc044 ⇒ sw x9,4(x8) = 0x00942223（CS：rs1′/rs2′ 双域）
        v_name = "CTL_C_SW_X9_4_X8";
        v_begin(32'h0000_c044, 16'hc044);
        `CHK(cexp_ill === 1'b0,             "c.sw 不应判保留")
        `CHK(cexp_insn32 === 32'h00942223,  "c.sw 应展开为 sw x9,4(x8)")
        `CHK(rs1_o === 5'd8,                "rs1 应为 x8")
        `CHK(rs2_o === 5'd9,                "rs2 应为 x9")
        v_end;

        //   c.mv x0, x5（HINT）⇒ 0x8016 ⇒ add x0,x0,x5 = 0x00500033，合法且 is_hint
        v_name = "HINT_C_MV_X0_X5";
        v_begin(32'h0000_8016, 16'h8016);
        `CHK(cexp_ill === 1'b0,             "c.mv(rd=x0) HINT 应可展开")
        `CHK(cexp_hint === 1'b1,            "c.mv(rd=x0) 应标记 HINT")
        `CHK(cexp_insn32 === 32'h00500033,  "c.mv x0,x5 应展开为 add x0,x0,x5")
        `CHK(ill_instr_o === 1'b0,          "HINT 不应非法")
        `CHK(is_hint_o === 1'b1,            "decoder 应标记 HINT")
        v_end;

        //   c.nop ⇒ 0x0001 ⇒ addi x0,x0,0 = 0x00000013
        v_name = "CTL_C_NOP";
        v_begin(32'h0000_0001, 16'h0001);
        `CHK(cexp_ill === 1'b0,             "c.nop 应合法")
        `CHK(cexp_insn32 === 32'h00000013,  "c.nop 应展开为 addi x0,x0,0")
        `CHK(ill_instr_o === 1'b0,          "c.nop 不应非法")
        v_end;

        //======================================================================
        // B. c.ebreak / c.jr / c.jalr 合法性（缺陷 F05-03）
        //======================================================================

        // ---- c.ebreak ⇒ 0x9002 ⇒ ebreak = 0x00100073；合法（旧实现误判 ill16）----
        v_name = "C_EBREAK_9002";
        v_begin(32'h0000_9002, 16'h9002);
        `CHK(cexp_ill === 1'b0,             "c.ebreak 应合法（不得误判保留）")
        `CHK(cexp_insn32 === 32'h00100073,  "c.ebreak 应展开为 ebreak")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(insn32_o === 32'h00100073,     "decoder insn32 应为 0x00100073")
        `CHK(ebreak_o === 1'b1,             "ebreak 标志应为 1")
        v_end;

        // ---- c.jr x5 ⇒ 0x8282 ⇒ jalr x0,0(x5) = 0x00028067 ----
        v_name = "C_JR_X5";
        v_begin(32'h0000_8282, 16'h8282);
        `CHK(cexp_ill === 1'b0,             "c.jr x5 应合法")
        `CHK(cexp_insn32 === 32'h00028067,  "c.jr x5 应展开为 jalr x0,0(x5)")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        `CHK(ctl_xfer_o === 1'b1,           "c.jr 应为控制转移")
        v_end;

        // ---- c.jalr x5 ⇒ 0x9282 ⇒ jalr x1,0(x5) = 0x000280e7（与 c.jr 区分）----
        v_name = "C_JALR_X5";
        v_begin(32'h0000_9282, 16'h9282);
        `CHK(cexp_ill === 1'b0,             "c.jalr x5 应合法")
        `CHK(cexp_insn32 === 32'h000280e7,  "c.jalr x5 应展开为 jalr x1,0(x5)")
        `CHK(ill_instr_o === 1'b0,          "decoder 不应非法")
        v_end;

        // ---- c.jr x1 ⇒ 0x8082 ⇒ jalr x0,0(x1) = 0x00008067 ----
        v_name = "C_JR_X1";
        v_begin(32'h0000_8082, 16'h8082);
        `CHK(cexp_ill === 1'b0,             "c.jr x1 应合法")
        `CHK(cexp_insn32 === 32'h00008067,  "c.jr x1 应展开为 jalr x0,0(x1)")
        v_end;

        // ---- c.jalr x1 ⇒ 0x9082 ⇒ jalr x1,0(x1) = 0x000080e7 ----
        v_name = "C_JALR_X1";
        v_begin(32'h0000_9082, 16'h9082);
        `CHK(cexp_ill === 1'b0,             "c.jalr x1 应合法")
        `CHK(cexp_insn32 === 32'h000080e7,  "c.jalr x1 应展开为 jalr x1,0(x1)")
        v_end;

        // ---- c.jr x0 ⇒ 0x8002：保留 ⇒ 必须判非法（旧实现放行为 jalr x0,0(x0)）----
        v_name = "C_JR_X0_RESERVED";
        v_begin(32'h0000_8002, 16'h8002);
        `CHK(cexp_ill === 1'b1,             "c.jr x0 应判保留（ill16=1）")
        `CHK(ill_instr_o === 1'b1,          "decoder 应判非法")
        `CHK(tval_o === 32'h0000_8002,      "tval 应为原始 16 位编码（T1）")
        v_end;

        // ---- 32 位 ebreak ⇒ 0x00100073；合法（对照：非压缩路径不受影响）----
        v_name = "CTL_EBREAK_32";
        v_begin(32'h00100073, 16'h0073);
        `CHK(ill_instr_o === 1'b0,          "32 位 ebreak 不应非法")
        `CHK(ebreak_o === 1'b1,             "32 位 ebreak 标志应为 1")
        `CHK(is_compressed_o === 1'b0,      "32 位 ebreak 不应标记压缩")
        v_end;

        // ---- 全零 16 位（唯一零输入向量）：永久保留 ----
        v_name = "ILL_ALL_ZERO";
        v_begin(32'h0000_0000, 16'h0000);
        `CHK(cexp_ill === 1'b1,             "全零 16 位应判保留")
        `CHK(ill_instr_o === 1'b1,          "decoder 应判非法")
        `CHK(tval_o === 32'h0000_0000,      "tval 应为 0")
        v_end;

        //======================================================================
        // C. OP-FP 保留/不支持字段（缺陷 F05-04）：ill=1 且 tval=原始 32 位
        //======================================================================

        // ---- FSQRT 的 rs2≠0（rs2 域固定 00000）----
        v_name = "FP_FSQRT_RS2_NZ";
        v_begin(32'h58100053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fsqrt.s rs2=1 应判非法（保留）")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        `CHK(tval_o === 32'h58100053,       "tval 应为原始 32 位")
        v_end;

        // ---- RV32 FCVT：L/LU 属 RV64 ⇒ 非法 ----
        v_name = "FP_FCVT_L_S";
        v_begin(32'hc0200053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.l.s 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        `CHK(tval_o === 32'hc0200053,       "tval 应为原始 32 位")
        v_end;
        v_name = "FP_FCVT_S_L";
        v_begin(32'hd0200053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.s.l 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_LU_S";
        v_begin(32'hc0300053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.lu.s 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_S_LU";
        v_begin(32'hd0300053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.s.lu 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_L_D";
        v_begin(32'hc2200053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.l.d 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_D_L";
        v_begin(32'hd2200053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.d.l 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;

        // ---- FMV/FCLASS：rs2 域必须为 0 ----
        v_name = "FP_FMV_X_W_RS2_NZ";
        v_begin(32'he0100053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fmv.x.w rs2=1 应判非法（保留）")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FMV_W_X_RS2_NZ";
        v_begin(32'hf0100053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fmv.w.x rs2=1 应判非法（保留）")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCLASS_S_RS2_NZ";
        v_begin(32'he0101053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fclass.s rs2=1 应判非法（保留）")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FMV_W_X_F3_NZ";
        v_begin(32'hf0001053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fmv.w.x f3=001 应判非法（保留）")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;

        // ---- RV64-only 的 FMV.X.D / FMV.D.X（fmt=D）----
        v_name = "FP_FMV_X_D_RV64";
        v_begin(32'he2000053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fmv.x.d 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FMV_D_X_RV64";
        v_begin(32'hf2000053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fmv.d.x 在 RV32 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;

        // ---- F↔D 源/目标配对（fcvt.s.d 与 fcvt.d.s 的两组精确 match）----
        v_name = "FP_FCVT_SD_RS2_0";
        v_begin(32'h40000053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.s.d rs2=0（配对错）应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_DS_RS2_1";
        v_begin(32'h42100053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.d.s rs2=1（配对错）应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_SD_RS2_2";
        v_begin(32'h40200053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt.s.d rs2=2（保留）应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;

        // ---- W/WU 之外的 rs2[4:2]≠0 亦保留 ----
        v_name = "FP_FCVT_RS2_4_OUT";
        v_begin(32'hc0400053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt(出口) rs2=4 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;
        v_name = "FP_FCVT_RS2_4_IN";
        v_begin(32'hd0400053, 16'h0053);
        `CHK(ill_instr_o === 1'b1,          "fcvt(入口) rs2=4 应判非法")
        `CHK(fp_we_o === 1'b0,          "非法 FP 不应发出 FP 写请求（fp_we_o=0）")
        v_end;

        //======================================================================
        // D. OP-FP 合法对照（逐字段：fp_op / fp_we / wb_sel / 寄存器域）
        //======================================================================

        // ---- fsqrt.s f0,f1,rne ⇒ 0x58008053（rs2=0）----
        v_name = "OK_FSQRT_S";
        v_begin(32'h58008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fsqrt.s rs2=0 不应非法")
        `CHK(op_type_o === 4'd11,           "fsqrt.s op_type 应为 OPT_FP")
        `CHK(fp_op_o === 6'd5,              "fsqrt.s fp_op 应为 FP_SQRT")
        `CHK(fp_we_o === 1'b1,              "fsqrt.s 应写 FP 寄存器")
        `CHK(rs1_o === 5'd1,                "fsqrt.s rs1 应为 f1")
        v_end;

        // ---- fsqrt.d f0,f1,rne ⇒ 0x5a008053（fmt=D、rs2=0）----
        v_name = "OK_FSQRT_D";
        v_begin(32'h5a008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fsqrt.d rs2=0 不应非法")
        `CHK(fp_op_o === 6'd5,              "fsqrt.d fp_op 应为 FP_SQRT")
        v_end;

        // ---- fcvt.w.s x0,f1,rne ⇒ 0xc0008053（rs2=0，出口写整数）----
        v_name = "OK_FCVT_W_S";
        v_begin(32'hc0008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.w.s rs2=0 不应非法")
        `CHK(fp_op_o === 6'd9,              "fcvt.w.s fp_op 应为 FP_CVT")
        `CHK(fp_we_o === 1'b0,              "fcvt.w.s 写整数，不应写 FP")
        `CHK(wb_sel_o === 3'd5,             "fcvt.w.s 写回应为 WB_FP")
        v_end;

        // ---- fcvt.wu.s x0,f1,rne ⇒ 0xc0108053（rs2=1 = WU）----
        v_name = "OK_FCVT_WU_S";
        v_begin(32'hc0108053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.wu.s rs2=1 不应非法")
        `CHK(fp_we_o === 1'b0,              "fcvt.wu.s 不应写 FP")
        `CHK(wb_sel_o === 3'd5,             "fcvt.wu.s 写回应为 WB_FP")
        v_end;

        // ---- fcvt.s.w f0,x1,rne ⇒ 0xd0008053（rs2=0，入口写 FP）----
        v_name = "OK_FCVT_S_W";
        v_begin(32'hd0008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.s.w rs2=0 不应非法")
        `CHK(fp_we_o === 1'b1,              "fcvt.s.w 应写 FP 寄存器")
        `CHK(wb_sel_o === 3'd0,             "fcvt.s.w 写回应为 WB_NONE")
        v_end;

        // ---- fcvt.s.wu f0,x1,rne ⇒ 0xd0108053（rs2=1）----
        v_name = "OK_FCVT_S_WU";
        v_begin(32'hd0108053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.s.wu rs2=1 不应非法")
        `CHK(fp_we_o === 1'b1,              "fcvt.s.wu 应写 FP")
        v_end;

        // ---- fcvt.wu.d x0,f1,rne ⇒ 0xc2108053（D 出口 WU）----
        v_name = "OK_FCVT_WU_D";
        v_begin(32'hc2108053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.wu.d rs2=1 不应非法")
        `CHK(fp_we_o === 1'b0,              "fcvt.wu.d 不应写 FP")
        v_end;

        // ---- fcvt.d.wu f0,x1 ⇒ 0xd2108053（D 入口 WU）----
        v_name = "OK_FCVT_D_WU";
        v_begin(32'hd2108053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.d.wu rs2=1 不应非法")
        `CHK(fp_we_o === 1'b1,              "fcvt.d.wu 应写 FP")
        v_end;

        // ---- F↔D 合法配对：fcvt.s.d f0,f1,rne ⇒ 0x40108053（fmt=S, rs2=1）----
        v_name = "OK_FCVT_S_D";
        v_begin(32'h40108053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.s.d 不应非法（真源宏 5'b01000 回归锚点）")
        `CHK(fp_op_o === 6'd9,              "fcvt.s.d fp_op 应为 FP_CVT")
        `CHK(fp_we_o === 1'b1,              "F↔D 写 FP 寄存器")
        `CHK(rs1_o === 5'd1,                "fcvt.s.d rs1 应为 f1")
        v_end;

        // ---- F↔D 合法配对：fcvt.d.s f0,f1 ⇒ 0x42008053（fmt=D, rs2=0）----
        v_name = "OK_FCVT_D_S";
        v_begin(32'h42008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.d.s 不应非法（真源宏 5'b01000 回归锚点）")
        `CHK(fp_op_o === 6'd9,              "fcvt.d.s fp_op 应为 FP_CVT")
        v_end;

        // ---- fcvt.w.d x0,f1,rne ⇒ 0xc2008053 ----
        v_name = "OK_FCVT_W_D";
        v_begin(32'hc2008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.w.d 不应非法")
        `CHK(fp_we_o === 1'b0,              "fcvt.w.d 不应写 FP")
        `CHK(wb_sel_o === 3'd5,             "fcvt.w.d 写回应为 WB_FP")
        v_end;

        // ---- fcvt.d.w f0,x1 ⇒ 0xd2008053 ----
        v_name = "OK_FCVT_D_W";
        v_begin(32'hd2008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fcvt.d.w 不应非法")
        `CHK(fp_we_o === 1'b1,              "fcvt.d.w 应写 FP")
        v_end;

        // ---- fmv.x.w x0,f1 ⇒ 0xe0008053（rs2=0, f3=000, fmt=S）----
        v_name = "OK_FMV_X_W";
        v_begin(32'he0008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fmv.x.w rs2=0 不应非法")
        `CHK(fp_op_o === 6'd10,             "fmv.x.w fp_op 应为 FP_MV_X")
        `CHK(fp_we_o === 1'b0,              "fmv.x.w 写整数，不应写 FP")
        `CHK(wb_sel_o === 3'd5,             "fmv.x.w 写回应为 WB_FP")
        `CHK(rs1_o === 5'd1,                "fmv.x.w rs1 应为 f1")
        v_end;

        // ---- fclass.s x0,f1 ⇒ 0xe0009053（f3=001, fmt=S）----
        v_name = "OK_FCLASS_S";
        v_begin(32'he0009053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fclass.s rs2=0 不应非法")
        `CHK(fp_op_o === 6'd10,             "fclass.s fp_op 应为 FP_MV_X")
        `CHK(fp_we_o === 1'b0,              "fclass.s 不应写 FP")
        v_end;

        // ---- fclass.d x0,f1 ⇒ 0xe2009053（f3=001, fmt=D：RV32D 合法）----
        v_name = "OK_FCLASS_D";
        v_begin(32'he2009053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fclass.d 不应非法（RV32D 定义）")
        `CHK(fp_op_o === 6'd10,             "fclass.d fp_op 应为 FP_MV_X")
        `CHK(fp_we_o === 1'b0,              "fclass.d 不应写 FP")
        v_end;

        // ---- fmv.w.x f0,x1 ⇒ 0xf0008053（f3=000, rs2=0, fmt=S）----
        v_name = "OK_FMV_W_X";
        v_begin(32'hf0008053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fmv.w.x rs2=0 不应非法")
        `CHK(fp_op_o === 6'd11,             "fmv.w.x fp_op 应为 FP_MV_W")
        `CHK(fp_we_o === 1'b1,              "fmv.w.x 应写 FP 寄存器")
        v_end;

        // ---- fadd.s f0,f1,f2,rne ⇒ 0x00208053（rs2 是操作数，非保留域）----
        v_name = "OK_FADD_S";
        v_begin(32'h00208053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fadd.s rs2≠0 不应非法（rs2 是操作数）")
        `CHK(fp_op_o === 6'd1,              "fadd.s fp_op 应为 FP_ADD")
        `CHK(fp_we_o === 1'b1,              "fadd.s 应写 FP")
        `CHK(rs1_o === 5'd1,                "fadd.s rs1 应为 f1")
        `CHK(rs2_o === 5'd2,                "fadd.s rs2 应为 f2")
        `CHK(rd_o === 5'd0,                 "fadd.s rd 应为 f0")
        v_end;

        // ---- fsgnj.s f0,f1,f2 ⇒ 0x20208053 ----
        v_name = "OK_FSGNJ_S";
        v_begin(32'h20208053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fsgnj.s 不应非法")
        `CHK(fp_op_o === 6'd6,              "fsgnj.s fp_op 应为 FP_SGNJ")
        v_end;

        // ---- fmin.s f0,f1,f2 ⇒ 0x28208053 ----
        v_name = "OK_FMIN_S";
        v_begin(32'h28208053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "fmin.s 不应非法")
        `CHK(fp_op_o === 6'd7,              "fmin.s fp_op 应为 FP_MIN")
        v_end;

        // ---- feq.s x0,f1,f2 ⇒ 0xa020a053（比较写整数）----
        v_name = "OK_FEQ_S";
        v_begin(32'ha020a053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "feq.s 不应非法")
        `CHK(fp_op_o === 6'd12,             "feq.s fp_op 应为 FP_CMP")
        `CHK(fp_we_o === 1'b0,              "feq.s 写整数，不应写 FP")
        `CHK(wb_sel_o === 3'd5,             "feq.s 写回应为 WB_FP")
        v_end;

        // ---- 项目口径控制：fadd.s 用保留 rm=101（0x0020d053）----
        //   ★ 这是**项目现状**锁定（既有实现接受全部 rm），不是 ISA 断言：
        //     规范把 rm=101/110 记为保留，本 TB 不据此要求 trap，也不允许
        //     在未裁决前静默改变该策略（08 §5.2 / 05 报告 F05-04 遗留项）。
        v_name = "PROJ_CTL_FADD_RM5";
        v_begin(32'h0020d053, 16'h0053);
        `CHK(ill_instr_o === 1'b0,          "项目口径：fadd.s rm=101 仍接受（非 ISA 断言）")
        `CHK(fp_op_o === 6'd1,              "fadd.s rm=101 fp_op 仍应为 FP_ADD")
        `CHK(rm_o === 3'd5,                 "rm 域应原样透传为 101")
        v_end;

        //======================================================================
        // E. RV32I/C 译码 + 立即数 + 权限/非法编码的期望 trap（包覆盖说明对齐
        //    sim/functional/manifest.tsv 的 test_decode.sh 条目）
        //    判据 = 译码合法性 + tval（cause 2 口径 T1）+ CSR 权限预判；不测执行。
        //======================================================================

        // ---- addi x5, x6, 100 ⇒ 0x06430293 ----
        v_name = "RV32I_ADDI";
        v_begin(32'h06430293, 16'h0293);
        `CHK(ill_instr_o === 1'b0,          "addi 不应非法")
        `CHK(op_type_o === 4'd0,            "addi op_type 应为 OPT_ALU")
        `CHK(rd_o === 5'd5,                 "addi rd 应为 x5")
        `CHK(rs1_o === 5'd6,                "addi rs1 应为 x6")
        `CHK(imm_o === 32'd100,             "addi imm 应为 100")
        v_end;

        // ---- lw x7, 8(x8) ⇒ 0x00842383 ----
        v_name = "RV32I_LW";
        v_begin(32'h00842383, 16'h2383);
        `CHK(ill_instr_o === 1'b0,          "lw 不应非法")
        `CHK(op_type_o === 4'd4,            "lw op_type 应为 OPT_LSU")
        `CHK(mem_op_o === 4'd1,             "lw mem_op 应为 MEM_LOAD")
        `CHK(mem_size_o === 3'd2,           "lw 宽度应为 4B")
        `CHK(imm_o === 32'd8,               "lw imm 应为 8")
        `CHK(rs1_o === 5'd8,                "lw rs1 应为 x8")
        `CHK(rd_o === 5'd7,                 "lw rd 应为 x7")
        v_end;

        // ---- sw x9, 12(x10) ⇒ 0x00952623 ----
        v_name = "RV32I_SW";
        v_begin(32'h00952623, 16'h2623);
        `CHK(ill_instr_o === 1'b0,          "sw 不应非法")
        `CHK(mem_op_o === 4'd2,             "sw mem_op 应为 MEM_STORE")
        `CHK(mem_size_o === 3'd2,           "sw 宽度应为 4B")
        `CHK(imm_o === 32'd12,              "sw imm 应为 12")
        `CHK(rs2_o === 5'd9,                "sw rs2 应为 x9")
        `CHK(rs1_o === 5'd10,               "sw rs1 应为 x10")
        v_end;

        // ---- beq x1, x2, +20 ⇒ 0x00208a63 ----
        v_name = "RV32I_BEQ";
        v_begin(32'h00208a63, 16'h0a63);
        `CHK(ill_instr_o === 1'b0,          "beq 不应非法")
        `CHK(op_type_o === 4'd1,            "beq op_type 应为 OPT_BRU")
        `CHK(imm_o === 32'd20,              "beq imm 应为 20")
        `CHK(ctl_xfer_o === 1'b1,           "beq 应为控制转移")
        v_end;

        // ---- jal x1, +36 ⇒ 0x024000ef ----
        v_name = "RV32I_JAL";
        v_begin(32'h024000ef, 16'h00ef);
        `CHK(ill_instr_o === 1'b0,          "jal 不应非法")
        `CHK(op_type_o === 4'd2,            "jal op_type 应为 OPT_JAL")
        `CHK(imm_o === 32'd36,              "jal imm 应为 36")
        `CHK(rd_o === 5'd1,                 "jal rd 应为 x1")
        v_end;

        // ---- lui x5, 0x12345 ⇒ 0x123452b7 ----
        v_name = "RV32I_LUI";
        v_begin(32'h123452b7, 16'h52b7);
        `CHK(ill_instr_o === 1'b0,          "lui 不应非法")
        `CHK(imm_o === 32'h12345000,        "lui imm 应为 0x12345000")
        `CHK(rd_o === 5'd5,                 "lui rd 应为 x5")
        v_end;

        // ---- 未定义 opcode ⇒ 非法 + tval = 原始指令位 ----
        v_name = "ILL_OPCODE_7F";
        v_begin(32'h0000007f, 16'h007f);
        `CHK(ill_instr_o === 1'b1,          "未定义 opcode 应判非法")
        `CHK(tval_o === 32'h0000007f,       "tval 应为原始指令位")
        v_end;

        // ---- OP-IMM 移位保留：slli shamt[5]=1 ⇒ 非法 ----
        v_name = "ILL_SLLI_SHAMT5";
        v_begin(32'h02031293, 16'h1293);
        `CHK(ill_instr_o === 1'b1,          "slli shamt[5]=1 应判非法")
        `CHK(tval_o === 32'h02031293,       "tval 应为原始指令位")
        v_end;

        // ---- cbo.zero（Zicboz 未实现）⇒ 非法 ----
        v_name = "ILL_CBO_ZERO";
        v_begin(32'h0044200f, 16'h200f);
        `CHK(ill_instr_o === 1'b1,          "cbo.zero 应判非法（无 Zicboz）")
        `CHK(tval_o === 32'h0044200f,       "tval 应为原始指令位")
        v_end;

        // ---- csrrw x5, mstatus, x6 ⇒ 0x300312f3（M 模式合法）----
        v_name = "CSR_MSTATUS_RW_M";
        v_begin(32'h300312f3, 16'h12f3);
        `CHK(ill_instr_o === 1'b0,          "csrrw mstatus 在 M 模式不应非法")
        `CHK(csr_addr_o === `RV32GC_CSR_MSTATUS, "csr 地址应为 mstatus(0x300)")
        `CHK(csr_op_o === 3'd1,             "csrrw csr_op 应为 CSRN_W")
        `CHK(csr_ill_o === 1'b0,            "csrrw mstatus 权限应通过")
        `CHK(rd_o === 5'd5,                 "csrrw rd 应为 x5")
        v_end;

        // ---- U 模式写只读 CSR(cycle) ⇒ 非法（期望 cause 2，tval=指令位）----
        v_name = "CSR_RO_WRITE_U";
        v_begin_priv(32'hc00312f3, 16'h12f3, `RV32GC_PRIV_U);
        `CHK(csr_ill_o === 1'b1,            "U 写只读 CSR 应判非法")
        `CHK(ill_instr_o === 1'b1,          "U 写只读 CSR 应整体非法")
        `CHK(tval_o === 32'hc00312f3,       "tval 应为原始指令位")
        v_end;

        // ---- U 模式读只读 CSR(cycle) ⇒ 合法 ----
        v_name = "CSR_RO_READ_U";
        v_begin_priv(32'hc00022f3, 16'h22f3, `RV32GC_PRIV_U);
        `CHK(csr_ill_o === 1'b0,            "U 读 cycle 应合法")
        `CHK(ill_instr_o === 1'b0,          "U 读 cycle 不应整体非法")
        v_end;

        // ---- U 模式访问 M 专属 CSR(mstatus) ⇒ 非法 ----
        v_name = "CSR_M_CSR_IN_U";
        v_begin_priv(32'h300022f3, 16'h22f3, `RV32GC_PRIV_U);
        `CHK(csr_ill_o === 1'b1,            "U 访问 mstatus 应判非法")
        `CHK(ill_instr_o === 1'b1,          "U 访问 mstatus 应整体非法")
        v_end;

        // ---- S 模式访问 S 专属 CSR(satp) ⇒ 合法 ----
        v_name = "CSR_SATP_IN_S";
        v_begin_priv(32'h180022f3, 16'h22f3, `RV32GC_PRIV_S);
        `CHK(csr_ill_o === 1'b0,            "S 访问 satp 应合法")
        `CHK(ill_instr_o === 1'b0,          "S 访问 satp 不应整体非法")
        v_end;

        // ---- 未实现 CSR 地址（0x7c0 自定义区）⇒ 非法 ----
        v_name = "CSR_UNIMPL_7C0_M";
        v_begin_priv(32'h7c0022f3, 16'h22f3, `RV32GC_PRIV_M);
        `CHK(csr_ill_o === 1'b1,            "未实现 CSR 地址应判非法")
        `CHK(ill_instr_o === 1'b1,          "未实现 CSR 地址应整体非法")
        v_end;

        //======================================================================
        // 汇总判定（fail-closed）
        //======================================================================
        // ---- 冻结规格自判（TB 本体，防止删向量/删整段断言后"自洽"通过）----
        if (n_vec != SPEC_TOTAL) begin
            n_fail = n_fail + 1;
            $display("CHECK_FAIL global : vectors=%0d expect=%0d", n_vec, SPEC_TOTAL);
        end
        if (n_nonzero != SPEC_NONZERO) begin
            n_fail = n_fail + 1;
            $display("CHECK_FAIL global : nonzero_insn=%0d expect=%0d", n_nonzero, SPEC_NONZERO);
        end
        if (n_check != SPEC_CHECKS) begin
            n_fail = n_fail + 1;
            $display("CHECK_FAIL global : checks=%0d expect=%0d", n_check, SPEC_CHECKS);
        end

        $display("DECODE_VECTORS total=%0d nonzero_insn=%0d checks=%0d fails=%0d",
                 n_vec, n_nonzero, n_check, n_fail);
        if (n_check == 0) begin
            $display("FUNCTIONAL_DECODE: FAIL reason=no_checks_executed");
            $fatal(1, "decode semantics FAIL: no checks executed");
        end
        if (n_vec == 0 || n_nonzero == 0) begin
            $display("FUNCTIONAL_DECODE: FAIL reason=no_nonzero_vectors total=%0d nonzero_insn=%0d",
                     n_vec, n_nonzero);
            $fatal(1, "decode semantics FAIL: no nonzero vectors");
        end
        if (n_fail != 0) begin
            $display("FUNCTIONAL_DECODE: FAIL reason=checks_failed fails=%0d", n_fail);
            $fatal(1, "decode semantics FAIL: %0d check(s) failed", n_fail);
        end
        $display("FUNCTIONAL_DECODE: PASS");
        $finish;
    end

endmodule
